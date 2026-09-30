#!/usr/bin/env node
// Read log and daily report for the data gate's measurement layer.
//
// bin/fm-data-gate.sh calls `log` for every read-shaped tool call its hooks
// see; bin/fm-data-gate-report.sh calls `report`. This module owns the read
// record, the bytes-requested estimate, home and task attribution, digest
// hit/miss, and the report. docs/data-gate.md owns the operator contract.
//
// `log` never blocks and never prints: it stats each named file once (plus one
// bounded head sample for a line-bounded read or a Read tool call) and appends
// one JSONL row per existing regular file to the day's
// ~/.local/state/lattice-data-gate/reads-YYYY-MM-DD.jsonl. It never walks a
// directory, never expands a glob, and never runs any byte of the submitted
// command; the shell lexing comes from bin/fm-arm-command-policy.mjs,
// firstmate's sole shell lexer. `report` deletes read logs older than
// LATTICE_DATA_GATE_READS_KEEP_DAYS days (default 60).
//
// CLI:
//   fm-data-gate-reads.mjs log --harness H [--stdin | --command C |
//       --tool read --path P [--offset N] [--limit N]] [--cwd DIR]
//       [--size-limit BYTES]
//   fm-data-gate-reads.mjs report [--date YYYY-MM-DD] [--baseline FILE]
//     (usage and output: bin/fm-data-gate-report.sh)
//
// Read row: {ts, harness, home, task, session, cwd, tool, path, size, bounded,
// bytes_requested, bytes_returned_est, whole_file, size_rule_would_block,
// is_digest} plus `lines` and `bytes_estimated` on a line-bounded read.
// bytes_requested counts an unlimited Read as the whole file, as the
// transcript baseline (data/fm-read-baseline/) does, so before and after
// compare; bytes_returned_est applies the harness's own Read caps.
// size_rule_would_block is the size rule's own verdict for the call
// (bin/fm-data-gate-policy.mjs sizeVerdicts, at the gate's --size-limit).

import { Lexer, splitProgram, commandPosition } from "./fm-arm-command-policy.mjs";
import { DEFAULT_SIZE_LIMIT, discover, recognizeReads, sizeVerdicts } from "./fm-data-gate-policy.mjs";
import { appendFileSync, closeSync, createReadStream, existsSync, mkdirSync, openSync, readFileSync, readSync, readdirSync, renameSync, statSync, unlinkSync, writeFileSync } from "node:fs";
import { basename, dirname, isAbsolute, join, resolve } from "node:path";
import { createInterface } from "node:readline";

const MAX_PATHS = 32;
const MAX_DEPTH = 4;
const SAMPLE_BYTES = 64 * 1024;
const DEFAULT_LINES = 10;
const BIG_FILE_BYTES = 10 * 1000 * 1000;
// A DIGEST.md read is a miss when a big file in its folder is read within this
// many minutes by the same session (docs/data-gate.md).
const DIGEST_WINDOW_MIN = 30;
const TOP_READS = 5;
const KEEP_DAYS = 60;
// Read tool caps per harness: default line window, a hard line and byte cap,
// and the size above which an unlimited Read is refused.
const READ_CAPS = {
  claude: { lines: 2000, refuseAbove: 256 * 1024 },
  opencode: { lines: 2000 },
  pi: { lines: 2000, maxLines: 2000, maxBytes: 50 * 1024 },
  omp: { lines: 2000, maxLines: 2000, maxBytes: 50 * 1024 },
};

const gateHome = () => process.env.HOME || "/";
export const stateDir = () => join(gateHome(), ".local", "state", "lattice-data-gate");
export const readsPath = (date) => join(stateDir(), `reads-${date}.jsonl`);

function readText(path) {
  try {
    return readFileSync(path, "utf8");
  } catch {
    return "";
  }
}

function fileSize(path) {
  try {
    const stat = statSync(path);
    return stat.isFile() ? stat.size : null;
  } catch {
    return null;
  }
}

// Bytes per line from one bounded head read, so a line bound becomes bytes.
function bytesPerLine(path, size) {
  let fd;
  try {
    fd = openSync(path, "r");
    const buffer = Buffer.alloc(Math.min(SAMPLE_BYTES, size));
    const n = readSync(fd, buffer, 0, buffer.length, 0);
    let lines = 0;
    for (let i = 0; i < n; i += 1) if (buffer[i] === 10) lines += 1;
    return lines ? n / lines : n || 1;
  } catch {
    return 100;
  } finally {
    if (fd !== undefined) closeSync(fd);
  }
}

// ---------------------------------------------------------------------------
// Attribution.

function gitTask(cwd) {
  let dir = cwd;
  for (let i = 0; i < 32; i += 1) {
    const dotgit = join(dir, ".git");
    if (existsSync(dotgit)) {
      let gitDir = dotgit;
      const pointer = readText(dotgit).match(/^gitdir: (.+)$/m);
      if (pointer) gitDir = resolve(dir, pointer[1].trim());
      const head = readText(join(gitDir, "HEAD")).match(/^ref: refs\/heads\/fm\/(.+)$/m);
      return head ? head[1].trim() : null;
    }
    const parent = dirname(dir);
    if (parent === dir) break;
    dir = parent;
  }
  return null;
}

// The gate's roots cache (any age), else a live discovery that is not cached.
function knownHomes() {
  try {
    const homes = JSON.parse(readText(join(stateDir(), "roots.json")))?.homes;
    if (Array.isArray(homes)) return homes.filter((h) => typeof h === "string");
  } catch {
    // no usable cache
  }
  return discover().homes;
}

// Task: FM_TASK_ID (set in every spawned worker's pane), else the fm/<id>
// branch of the cwd's worktree. Home: FM_HOME, else the discovered home that
// contains the cwd, else the discovered home holding state/<task>.status.
export function attribute(cwd) {
  const task = process.env.FM_TASK_ID || gitTask(cwd);
  let home = process.env.FM_HOME || null;
  const homes = home ? [] : knownHomes();
  if (!home) {
    for (const h of homes) if ((cwd === h || cwd.startsWith(`${h}/`)) && h.length > (home || "").length) home = h;
  }
  if (!home && task) home = homes.find((h) => existsSync(join(h, "state", `${task}.status`))) || null;
  return { home, task: task || null };
}

// ---------------------------------------------------------------------------
// Read extraction. Each command spec names its short options that consume the
// next word and how many leading operands are not files.

const READERS = {
  cat: {}, tac: {}, less: {}, more: {}, nl: {}, wc: {}, uniq: {}, cut: { args: "bcdf" },
  sort: { args: "kotST" }, bat: { args: "lmrH" }, md5sum: {}, sha1sum: {}, sha256sum: {},
  zcat: {}, xxd: { args: "cgls" }, od: { args: "AjNtw" }, strings: { args: "nt" }, diff: {}, cmp: {},
  grep: { args: "efmABCdDX", pattern: true }, egrep: { args: "efmABCdDX", pattern: true },
  fgrep: { args: "efmABCdDX", pattern: true }, rg: { args: "ABCEMTdefgjmrt", pattern: true },
  ugrep: { args: "efmABCdDX", pattern: true }, ag: { args: "ABCGgmpW", pattern: true },
  sed: { args: "elf", pattern: true, patternFlags: "ef" }, awk: { args: "fvF", pattern: true, patternFlags: "f" },
  jq: { args: "f", pattern: true, patternFlags: "f", pairs: ["--arg", "--argjson", "--slurpfile", "--rawfile"] },
  head: { head: true }, tail: { head: true },
};
// Readers that stop reading when a downstream `| head` closes the pipe; the
// rest (sort, tac, wc, checksums, diff) consume their whole input first.
const STREAMING = new Set(["cat", "less", "more", "nl", "cut", "bat", "zcat", "xxd", "od", "strings", "grep", "egrep", "fgrep", "rg", "ugrep", "ag", "sed", "awk", "jq"]);
const PATTERN_LONG = ["--regexp", "--file", "--expression", "--files"];
const WRAPPERS = { nice: "n", ionice: "cnpt", stdbuf: "ioe", time: "fo", chrt: "", taskset: "", flock: "wEc", xargs: "adEeIiLlnPs" };
const PYTHON_OPEN = /\b(?:open|read_csv|read_json|read_parquet|read_table|loadtxt|load)\(\s*(?:r|rb)?(['"])([^'"\n]+)\1/g;

function parseCount(text) {
  const match = String(text ?? "").match(/^[+-]?(\d+)([kKmMgG]?)[bB]?$/);
  if (!match) return null;
  const scale = { "": 1, k: 1024, m: 1024 ** 2, g: 1024 ** 3 }[match[2].toLowerCase()];
  return Number(match[1]) * scale;
}

// head/tail bounds: {lines}, {bytes}, or null when the count reads to the end
// (`tail -n +N`, `head -n -N`); files are the non-option operands.
function headArgs(words, tail = false) {
  let bound = { lines: DEFAULT_LINES };
  const files = [];
  const count = (unit, text) => {
    const raw = String(text ?? "");
    if (raw.startsWith(tail ? "+" : "-")) return null;
    return { [unit]: parseCount(raw) ?? (unit === "lines" ? DEFAULT_LINES : 0) };
  };
  for (let i = 0; i < words.length; i += 1) {
    const value = words[i].value;
    if (/^-\d+$/.test(value)) bound = { lines: Number(value.slice(1)) };
    else if (value === "-n" || value === "--lines") bound = count("lines", words[(i += 1)]?.value);
    else if (value === "-c" || value === "--bytes") bound = count("bytes", words[(i += 1)]?.value);
    else if (/^-n/.test(value)) bound = count("lines", value.slice(2));
    else if (/^-c/.test(value)) bound = count("bytes", value.slice(2));
    else if (value.startsWith("--lines=")) bound = count("lines", value.slice(8));
    else if (value.startsWith("--bytes=")) bound = count("bytes", value.slice(8));
    else if (value.startsWith("-") && value !== "-") continue;
    else files.push(words[i]);
  }
  return { bound, files };
}

function readerOperands(spec, words) {
  const operands = [];
  let patternGiven = false;
  let endOfOptions = false;
  for (let i = 0; i < words.length; i += 1) {
    const value = words[i].value;
    if (!endOfOptions && value === "--") {
      endOfOptions = true;
      continue;
    }
    if (!endOfOptions && spec.pairs?.includes(value)) {
      i += 2;
      continue;
    }
    if (!endOfOptions && value.startsWith("--") && value.length > 2) {
      if (PATTERN_LONG.some((name) => value === name || value.startsWith(`${name}=`))) patternGiven = true;
      if (!value.includes("=") && PATTERN_LONG.includes(value)) i += 1;
      continue;
    }
    if (!endOfOptions && value.startsWith("-") && value.length > 1) {
      for (let j = 1; j < value.length; j += 1) {
        const letter = value[j];
        if ((spec.patternFlags ?? "ef").includes(letter) && spec.pattern) patternGiven = true;
        if ((spec.args || "").includes(letter)) {
          if (j === value.length - 1) i += 1;
          break;
        }
      }
      continue;
    }
    operands.push(words[i]);
  }
  return spec.pattern && !patternGiven ? operands.slice(1) : operands;
}

function expandPath(word, cwd) {
  let value = word.value;
  if (!word.literal) {
    value = value.replace(/^\$\{HOME\}(?=\/|$)/, gateHome()).replace(/^\$HOME(?=\/|$)/, gateHome());
    if (value.includes("$") || word.subs?.length) return null;
  }
  if (word.unquotedExpansion) return null;
  if (!value || value === "-") return null;
  if (value === "~" || value.startsWith("~/")) value = gateHome() + value.slice(1);
  return isAbsolute(value) ? value : resolve(cwd, value);
}

function pipeBound(node) {
  const position = commandPosition(node);
  if (!position.command || basename(position.command.value) !== "head") return null;
  const parsed = headArgs(position.words.slice(position.index + 1));
  return parsed.files.length ? null : parsed.bound;
}

function nodeReads(tokens, state, depth, out) {
  for (const token of tokens) {
    if (token.type === "group") analyzeReads(token.content, state.cwd, depth + 1, out);
    for (const sub of token.subs || []) analyzeReads(sub.content, state.cwd, depth + 1, out);
  }
  const stdin = [];
  for (let i = 0; i < tokens.length; i += 1) {
    if (tokens[i].type === "redir" && /^\d*<$/.test(tokens[i].value) && tokens[i + 1]?.type === "word") {
      const read = { tool: "redirect", word: tokens[i + 1], cwd: state.cwd, bound: null };
      out.push(read);
      if (/^0?<$/.test(tokens[i].value)) stdin.push(read);
    }
  }
  const position = commandPosition(tokens);
  const words = position.words;
  let index = position.index;
  for (let guard = 0; guard < 8 && words[index]; guard += 1) {
    const name = basename(words[index].value);
    if (!(name in WRAPPERS)) break;
    index += 1;
    while (words[index]?.value.startsWith("-")) index += words[index].value.length === 2 && WRAPPERS[name].includes(words[index].value[1]) ? 2 : 1;
    if (["flock", "taskset", "chrt"].includes(name) && words[index]) index += 1;
  }
  const command = words[index];
  if (!command) return;
  const name = basename(command.value);
  const args = words.slice(index + 1);
  if (name === "cd" && args[0] && args[0].value !== "-") {
    const dest = expandPath(args[0], state.cwd);
    if (dest) state.cwd = dest;
    return;
  }
  if (["bash", "sh", "zsh", "dash"].includes(name)) {
    const flag = args.findIndex((w) => /^-[A-Za-z]*c[A-Za-z]*$/.test(w.value));
    if (flag !== -1 && args[flag + 1]) analyzeReads(args[flag + 1].value, state.cwd, depth + 1, out);
    return;
  }
  if (/^python\d?(\.\d+)?$/.test(name)) {
    const flag = args.findIndex((w) => w.value === "-c");
    const code = flag === -1 ? "" : args[flag + 1]?.value || "";
    for (const match of code.matchAll(PYTHON_OPEN)) out.push({ tool: name, word: { value: match[2], literal: true }, cwd: state.cwd, bound: null });
    return;
  }
  const spec = READERS[name];
  if (!spec) return;
  if (spec.head) {
    const parsed = headArgs(args, name === "tail");
    for (const read of stdin) read.bound = parsed.bound;
    for (const word of parsed.files) out.push({ tool: name, word, cwd: state.cwd, bound: parsed.bound });
    return;
  }
  for (const read of stdin) read.pipeable = STREAMING.has(name);
  for (const word of readerOperands(spec, args)) out.push({ tool: name, word, cwd: state.cwd, bound: null, pipeable: STREAMING.has(name) });
}

function analyzeReads(command, cwd, depth, out) {
  if (depth > MAX_DEPTH) return;
  const lexed = new Lexer(command.replace(/\\\r?\n/g, "")).tokenize();
  if (lexed.error) return;
  const { nodes, separators } = splitProgram(lexed.tokens);
  const state = { cwd };
  nodes.forEach((node, i) => {
    const start = out.length;
    nodeReads(node, state, depth, out);
    const bound = separators[i] === "|" && nodes[i + 1] ? pipeBound(nodes[i + 1]) : null;
    if (bound) for (let j = start; j < out.length; j += 1) if (out[j].pipeable) out[j].bound = bound;
  });
}

export function extractReads(call) {
  if (call.kind === "read") {
    const bound = call.limit ? { lines: call.limit } : null;
    return [{ tool: call.tool || "Read", word: { value: call.path, literal: true }, cwd: call.cwd, bound, readTool: true }];
  }
  const out = [];
  analyzeReads(call.command, call.cwd, 0, out);
  return out;
}

function toRow(read, call, who) {
  const path = expandPath(read.word, read.cwd);
  if (!path) return null;
  const size = fileSize(path);
  if (size === null) return null;
  let perLine;
  const lineBytes = (lines) => Math.min(size, Math.round(lines * (perLine ??= bytesPerLine(path, size))));
  const row = {
    ts: new Date().toISOString(),
    harness: call.harness,
    home: who.home,
    task: who.task,
    session: call.session || null,
    cwd: call.cwd,
    tool: read.tool,
    path,
    size,
    bounded: Boolean(read.bound),
    bytes_requested: size,
    bytes_returned_est: size,
    whole_file: !read.bound,
    size_rule_would_block: false,
    is_digest: /^digest\.md$/i.test(basename(path)),
  };
  if (read.bound?.bytes !== undefined) row.bytes_requested = Math.min(size, read.bound.bytes);
  else if (read.bound?.lines !== undefined) {
    row.lines = read.bound.lines;
    row.bytes_requested = lineBytes(read.bound.lines);
    row.bytes_estimated = true;
  }
  row.bytes_returned_est = row.bytes_requested;
  if (read.readTool) {
    const cap = READ_CAPS[call.harness] || READ_CAPS.opencode;
    if (!read.bound && cap.refuseAbove && size > cap.refuseAbove) row.bytes_returned_est = 0;
    else row.bytes_returned_est = Math.min(lineBytes(Math.min(read.bound?.lines ?? cap.lines, cap.maxLines ?? Infinity)), cap.maxBytes ?? Infinity);
  }
  return row;
}

function payloadCall(raw) {
  const payload = JSON.parse(raw);
  const input = payload.tool_input || payload.toolInput || {};
  const toolName = String(payload.tool_name || payload.toolName || "");
  const cwd = typeof payload.cwd === "string" && payload.cwd ? payload.cwd : process.cwd();
  const session = payload.session_id || payload.sessionId || null;
  if (typeof input.command === "string") return { kind: "bash", command: input.command, cwd, session };
  if (/^read$/i.test(toolName) && typeof (input.file_path || input.path) === "string") {
    return { kind: "read", path: input.file_path || input.path, offset: input.offset ?? null, limit: Number(input.limit) || null, cwd, session };
  }
  return null;
}

function runLog(argv) {
  const args = { harness: "unknown", sizeLimit: DEFAULT_SIZE_LIMIT };
  for (let i = 0; i < argv.length; i += 1) {
    const value = argv[i + 1];
    switch (argv[i]) {
      case "--harness": args.harness = value; i += 1; break;
      case "--command": args.command = value; i += 1; break;
      case "--tool": args.tool = value; i += 1; break;
      case "--path": args.path = value; i += 1; break;
      case "--offset": args.offset = value; i += 1; break;
      case "--limit": args.limit = Number(value) || null; i += 1; break;
      case "--cwd": args.cwd = value; i += 1; break;
      case "--stdin": args.stdin = true; break;
      case "--size-limit": args.sizeLimit = Number(value); i += 1; break;
      default: break;
    }
  }
  let call = null;
  if (args.stdin) call = payloadCall(readFileSync(0, "utf8"));
  else if (args.command !== undefined) call = { kind: "bash", command: args.command };
  else if (args.tool === "read" && args.path) call = { kind: "read", path: args.path, offset: args.offset ?? null, limit: args.limit };
  if (!call) return;
  call.harness = args.harness;
  if (args.cwd || !call.cwd) call.cwd = args.cwd || process.cwd();
  const who = attribute(call.cwd);
  const rows = extractReads(call).slice(0, MAX_PATHS).map((read) => toRow(read, call, who)).filter(Boolean);
  if (!rows.length) return;
  // Only a file over the limit can be refused, so only then ask the rule.
  const over = rows.filter((row) => row.size > args.sizeLimit);
  if (over.length) {
    const blocked = new Set(sizeVerdicts(recognizeReads(call), args.sizeLimit).filter((r) => r.verdict === "block").map((r) => r.target));
    for (const row of over) row.size_rule_would_block = blocked.has(row.path);
  }
  mkdirSync(stateDir(), { recursive: true });
  appendFileSync(readsPath(localDate(new Date())), rows.map((row) => `${JSON.stringify(row)}\n`).join(""));
}

// ---------------------------------------------------------------------------
// Daily report.

function localDate(date) {
  const pad = (n) => String(n).padStart(2, "0");
  return `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())}`;
}

export function fmtBytes(bytes) {
  const abs = Math.abs(bytes);
  const sign = bytes < 0 ? "-" : "";
  for (const [unit, scale] of [["TB", 1e12], ["GB", 1e9], ["MB", 1e6], ["kB", 1e3]]) {
    if (abs >= scale) return `${sign}${(abs / scale).toFixed(abs >= 100 * scale ? 0 : 1)} ${unit}`;
  }
  return `${sign}${abs} B`;
}

const signed = (bytes) => (bytes >= 0 ? `+${fmtBytes(bytes)}` : fmtBytes(bytes));

// Streams one JSONL file; onRecord returning false stops the pass.
async function eachJson(path, onRecord) {
  if (!existsSync(path)) return;
  const input = createReadStream(path);
  try {
    for await (const line of createInterface({ input, crlfDelay: Infinity })) {
      if (!line) continue;
      let record;
      try {
        record = JSON.parse(line);
      } catch {
        continue;
      }
      if (onRecord(record) === false) break;
    }
  } finally {
    input.destroy();
  }
}

const tsMs = (ts) => (typeof ts === "number" ? ts * 1000 : Date.parse(ts));

// The day's read log, then the next day's up to the digest window, so a
// DIGEST.md read just before midnight can still turn into a miss.
async function readStats(date, nextDate, start, end, windowMs) {
  const stats = { reads: 0, bytes: 0, returned: 0, whole: 0, big: 0, sizeWould: 0, byHarness: {}, top: [], digests: 0, misses: 0 };
  const pending = new Map();
  const onRow = (row) => {
    const t = tsMs(row.ts);
    if (!(t >= start && t < end + windowMs)) return;
    const key = `${row.harness}:${row.session || row.task || row.cwd}`;
    if (row.size > BIG_FILE_BYTES) {
      for (const digest of pending.get(key) || []) {
        if (!digest.miss && digest.dir === dirname(row.path) && t >= digest.t && t - digest.t <= windowMs) digest.miss = true;
      }
    }
    if (t >= end) return;
    const bytes = Number(row.bytes_requested) || 0;
    stats.reads += 1;
    stats.bytes += bytes;
    stats.returned += Number(row.bytes_returned_est ?? bytes) || 0;
    if (row.whole_file) stats.whole += 1;
    if (row.size > BIG_FILE_BYTES) stats.big += 1;
    if (row.size_rule_would_block) stats.sizeWould += 1;
    stats.byHarness[row.harness] = (stats.byHarness[row.harness] || 0) + bytes;
    if (stats.top.length < TOP_READS || bytes > stats.top.at(-1).bytes) {
      stats.top.push({ bytes, path: row.path, tool: row.tool, harness: row.harness, task: row.task });
      stats.top.sort((a, b) => b.bytes - a.bytes);
      stats.top.length = Math.min(stats.top.length, TOP_READS);
    }
    if (row.is_digest) {
      stats.digests += 1;
      const list = (pending.get(key) || []).filter((d) => t - d.t <= windowMs || d.miss);
      list.push({ dir: dirname(row.path), t, miss: false });
      pending.set(key, list);
    }
  };
  await eachJson(readsPath(date), onRow);
  await eachJson(readsPath(nextDate), (row) => (tsMs(row.ts) < end + windowMs ? onRow(row) : false));
  for (const list of pending.values()) for (const digest of list) if (digest.miss) stats.misses += 1;
  return stats;
}

async function decisionStats(path, start, end) {
  const byRule = { scan: { seen: 0, would: 0, blocked: 0 }, size: { seen: 0, would: 0, blocked: 0 } };
  let errors = 0;
  await eachJson(path, (record) => {
    const t = tsMs(record.ts);
    if (!(t >= start && t < end)) return;
    if (record.error) {
      errors += 1;
      return;
    }
    // A record from before the size rule has no would_block_rules and no
    // target rule; it is the scan rule's.
    const rules = Array.isArray(record.would_block_rules) ? record.would_block_rules : record.would_block ? ["scan"] : [];
    const named = Array.isArray(record.targets) ? record.targets.map((t) => t.rule || "scan") : [];
    for (const rule of new Set([...(named.length ? named : ["scan"]), ...rules])) {
      byRule[rule] ??= { seen: 0, would: 0, blocked: 0 };
      byRule[rule].seen += 1;
      if (!rules.includes(rule)) continue;
      byRule[rule].would += 1;
      if (record.verdict === "block" && (rule === "size" ? record.size_mode : record.mode) === "enforce") byRule[rule].blocked += 1;
    }
  });
  return { byRule, errors };
}

const PSI_KEYS = ["io_some_avg60", "io_full_avg60", "memory_some_avg60", "memory_full_avg60"];

async function sampleStats(path, start, end) {
  const stats = { samples: 0, first: null, last: null, written: 0, readBytes: 0, sums: {}, maxIoSome: 0 };
  let previous = null;
  await eachJson(path, (sample) => {
    const t = tsMs(sample.ts);
    if (!(t >= start && t < end)) return;
    stats.samples += 1;
    stats.first ??= sample;
    stats.last = sample;
    for (const key of PSI_KEYS) if (typeof sample[key] === "number") stats.sums[key] = (stats.sums[key] || 0) + sample[key];
    if (typeof sample.io_some_avg60 === "number") stats.maxIoSome = Math.max(stats.maxIoSome, sample.io_some_avg60);
    if (previous) {
      const written = sample.disk_write_bytes - previous.disk_write_bytes;
      const read = sample.disk_read_bytes - previous.disk_read_bytes;
      if (written > 0) stats.written += written;
      if (read > 0) stats.readBytes += read;
    }
    previous = sample;
  });
  const mean = (key) => (stats.samples ? (stats.sums[key] || 0) / stats.samples : null);
  const delta = (key) => (stats.first && typeof stats.first[key] === "number" && typeof stats.last[key] === "number" ? stats.last[key] - stats.first[key] : null);
  return { ...stats, mean, rootGrowth: delta("root_used"), mntcGrowth: delta("mntc_used") };
}

function baselineHeadline(path) {
  const match = readText(path).match(/^\*\*Headline: (.+?)\*\*/m);
  return match ? match[1].replace(/\.$/, "") : null;
}

function defaultBaseline() {
  const home = process.env.FM_HOME || join(gateHome(), "Tools", "firstmate");
  return join(home, "data", "fm-read-baseline", "report.md");
}

export async function buildReport(options) {
  const [y, m, d] = options.date.split("-").map(Number);
  const start = new Date(y, m - 1, d).getTime();
  const end = new Date(y, m - 1, d + 1).getTime();
  const windowMs = DIGEST_WINDOW_MIN * 60 * 1000;
  const reads = await readStats(options.date, localDate(new Date(end)), start, end, windowMs);
  const decisions = await decisionStats(join(stateDir(), "decisions.jsonl"), start, end);
  const samples = await sampleStats(join(stateDir(), "samples.jsonl"), start, end);
  const baseline = baselineHeadline(options.baseline);
  const hits = reads.digests - reads.misses;
  const rate = reads.digests ? `${Math.round((100 * hits) / reads.digests)}%` : "n/a";
  const pct = (value) => (value === null ? "n/a" : `${value.toFixed(1)}%`);
  const rule = (name) => decisions.byRule[name] || { seen: 0, would: 0, blocked: 0 };
  const largest = reads.top[0] ? `largest ${fmtBytes(reads.top[0].bytes)} ${basename(reads.top[0].path)}` : "none";
  const disk = samples.samples
    ? `disk root ${signed(samples.rootGrowth ?? 0)}, /mnt/c ${samples.mntcGrowth === null ? "n/a" : signed(samples.mntcGrowth)}, written ${fmtBytes(samples.written)}; IO PSI some ${pct(samples.mean("io_some_avg60"))} full ${pct(samples.mean("io_full_avg60"))}`
    : "no disk/PSI samples";
  const relay = [
    `Data gate ${options.date}: agents read ${fmtBytes(reads.bytes)} in ${reads.reads} reads (est. returned ${fmtBytes(reads.returned)}; ${largest})`,
    `scans would-block ${rule("scan").would}, blocked ${rule("scan").blocked}`,
    `size would-block ${rule("size").would}, blocked ${rule("size").blocked}; >200 MB whole-file reads ${reads.sizeWould}`,
    `digests ${reads.digests} read, hit rate ${rate}`,
    `${disk}${baseline ? `; baseline ${baseline.replace(/^agents requested on average /, "")}` : ""}`,
  ].join("; ");

  const lines = [
    `# Data gate report ${options.date}`,
    "",
    "| Measure | Value |",
    "|---|---:|",
    `| Bytes requested by agents | ${fmtBytes(reads.bytes)} in ${reads.reads} reads (${reads.whole} whole-file, ${reads.big} of files > 10 MB) |`,
    `| Bytes returned (est., harness Read caps) | ${fmtBytes(reads.returned)} |`,
    `| By harness | ${Object.entries(reads.byHarness).sort((a, b) => b[1] - a[1]).map(([h, b]) => `${h} ${fmtBytes(b)}`).join(", ") || "none"} |`,
    `| Whole-file reads > 200 MB (size rule would block) | ${reads.sizeWould} |`,
    ...Object.entries(decisions.byRule).map(([name, r]) => `| Gate ${name} decisions | ${r.seen} logged, ${r.would} would-block, ${r.blocked} blocked |`),
    `| Gate errors (allowed) | ${decisions.errors} |`,
    `| DIGEST.md reads | ${reads.digests}: ${hits} hit, ${reads.misses} miss (${rate}; miss = a > 10 MB file in the same folder read within ${DIGEST_WINDOW_MIN} min) |`,
    `| Disk growth | root ${samples.rootGrowth === null ? "n/a" : signed(samples.rootGrowth)}, /mnt/c ${samples.mntcGrowth === null ? "n/a" : signed(samples.mntcGrowth)} |`,
    `| Disk IO | ${fmtBytes(samples.readBytes)} read, ${fmtBytes(samples.written)} written (${samples.samples} samples) |`,
    `| PSI mean avg60 | io some ${pct(samples.mean("io_some_avg60"))} (peak ${pct(samples.samples ? samples.maxIoSome : null)}), io full ${pct(samples.mean("io_full_avg60"))}, memory some ${pct(samples.mean("memory_some_avg60"))}, memory full ${pct(samples.mean("memory_full_avg60"))} |`,
    ...(baseline ? [`| Baseline (before) | ${baseline} |`] : []),
    "",
    "Largest reads:",
    "",
    ...(reads.top.length ? reads.top.map((r) => `- ${fmtBytes(r.bytes)} ${r.tool} ${r.path} (${r.harness}${r.task ? `, ${r.task}` : ""})`) : ["- none"]),
    "",
    `Relay: ${relay}`,
    "",
  ];
  return { relay, markdown: lines.join("\n") };
}

// Deletes read logs dated more than LATTICE_DATA_GATE_READS_KEEP_DAYS days ago.
function pruneReads() {
  const keep = Number(process.env.LATTICE_DATA_GATE_READS_KEEP_DAYS);
  const cutoff = new Date();
  cutoff.setDate(cutoff.getDate() - (Number.isInteger(keep) && keep > 0 ? keep : KEEP_DAYS));
  const oldest = localDate(cutoff);
  let names = [];
  try {
    names = readdirSync(stateDir());
  } catch {
    return;
  }
  for (const name of names) {
    const date = name.match(/^reads-(\d{4}-\d{2}-\d{2})\.jsonl$/)?.[1];
    if (date && date < oldest) unlinkSync(join(stateDir(), name));
  }
}

async function runReport(argv) {
  const yesterday = new Date();
  yesterday.setDate(yesterday.getDate() - 1);
  const options = { date: localDate(yesterday), baseline: defaultBaseline() };
  for (let i = 0; i < argv.length; i += 1) {
    const value = argv[i + 1];
    switch (argv[i]) {
      case "--date": options.date = value; i += 1; break;
      case "--baseline": options.baseline = value; i += 1; break;
      default: throw new Error(`unknown argument: ${argv[i]}`);
    }
  }
  if (!/^\d{4}-\d{2}-\d{2}$/.test(options.date || "")) throw new Error(`--date must be YYYY-MM-DD: ${options.date}`);
  const { relay, markdown } = await buildReport(options);
  const dir = join(stateDir(), "reports");
  mkdirSync(dir, { recursive: true });
  const target = join(dir, `${options.date}.md`);
  writeFileSync(`${target}.tmp.${process.pid}`, markdown);
  renameSync(`${target}.tmp.${process.pid}`, target);
  pruneReads();
  process.stdout.write(`${relay}\n`);
}

const [sub, ...rest] = process.argv.slice(2);
if (sub === "log") {
  try {
    runLog(rest);
  } catch {
    // the read log must never turn into a block or a visible error
  }
} else if (sub === "report") {
  runReport(rest).catch((error) => {
    process.stderr.write(`fm-data-gate-report: ${error.message}\n`);
    process.exitCode = 1;
  });
} else if (sub !== undefined) {
  process.stderr.write(`fm-data-gate-reads: unknown subcommand: ${sub} (expected log|report)\n`);
  process.exitCode = 2;
}
