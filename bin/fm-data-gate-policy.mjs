#!/usr/bin/env node
// Decision owner for the data gate's two rules: does one agent tool call
// recursively scan bulk run data, a Firstmate home root, the user's home, or a
// whole drive (scan rule), or read one named file over the size limit whole
// (size rule)?
//
// bin/fm-data-gate.sh is the stable harness entry point; it owns the per-rule
// modes, the size limit, the cheap prefilter, the time bound, the error fallback, and the per-harness
// deny rendering. This module owns everything else: payload extraction, shell
// parsing, target resolution, the protected-root set, read recognition
// (recognizeReads, reusable by other consumers), home discovery, the roots
// cache, and the decision log. See docs/data-gate.md for the contract.
//
// The shell tokenizer and command-position analysis are imported from
// bin/fm-arm-command-policy.mjs, the sole owner of firstmate's shell lexing.
// Nothing here ever evaluates, expands through a shell, or runs any byte of the
// submitted command, and nothing here walks a directory tree: target
// resolution uses realpath, stat, and single-directory reads for glob segments
// only, each bounded; the size rule costs one stat per named file.
//
// CLI:
//   fm-data-gate-policy.mjs decide --harness H --mode M [--size-mode M]
//       [--size-limit BYTES] [--stdin | --command C |
//       --tool grep|glob --path P [--pattern G] |
//       --tool read --path P [--offset N] [--limit N]] [--cwd DIR]
//     prints `allow`, `block<TAB>scan<TAB>tool<TAB>target`, or
//     `block<TAB>size<TAB>tool<TAB>target<TAB>size MiB<TAB>limit MiB` for the
//     first enforced rule that blocks, and appends one JSONL
//     decision record for every scan-shaped call or read of a file over the
//     limit.
//   fm-data-gate-policy.mjs refresh
//     rediscovers homes and bulk paths and rewrites the roots cache.
//   fm-data-gate-policy.mjs roots
//     prints the store, the effective protected roots, and the bulk patterns
//     (cache or live), one per line.

import { Lexer, splitProgram, commandPosition } from "./fm-arm-command-policy.mjs";
import {
  appendFileSync,
  existsSync,
  mkdirSync,
  readFileSync,
  readdirSync,
  realpathSync,
  renameSync,
  statSync,
  writeFileSync,
} from "node:fs";
import { dirname, isAbsolute, join, normalize, posix, resolve, sep } from "node:path";
import { fileURLToPath } from "node:url";

const MAX_DEPTH = 6;
const MAX_GLOB_MATCHES = 256;
const MAX_HOMES = 64;
const CACHE_MAX_AGE_MS = 6 * 60 * 60 * 1000;
const CMD_LOG_LIMIT = 4000;
// The size rule's default whole-file read limit; bin/fm-data-gate.sh owns the
// configured value and passes it as --size-limit.
export const DEFAULT_SIZE_LIMIT = 200 * 1024 * 1024;

// The one definition of a home's bulk directories, relative to its data/.
// bin/fm-data-gate-install.sh generates it into each home's data/bulk-paths.txt,
// which feeds both the protected set below and the .ignore/.rgignore files.
export const DEFAULT_BULK = ["rolling-runs-*/slices/", "*/tetjet-results/", "shell-contact-first-runs/runs*/"];

export function gateHome() {
  return process.env.HOME || "/";
}

export function stateDir() {
  return join(gateHome(), ".local", "state", "lattice-data-gate");
}

export function logPath() {
  return join(stateDir(), "decisions.jsonl");
}

export function cachePath() {
  return join(stateDir(), "roots.json");
}

function basename(value) {
  return value.split("/").filter(Boolean).at(-1) || value;
}

function isFile(path) {
  try {
    return statSync(path).isFile();
  } catch {
    return false;
  }
}

function isDir(path) {
  try {
    return statSync(path).isDirectory();
  } catch {
    return false;
  }
}

function readText(path) {
  try {
    return readFileSync(path, "utf8");
  } catch {
    return "";
  }
}

// realpath for an existing path; for a missing one, realpath of the longest
// existing ancestor plus the lexical remainder.
export function realish(path) {
  let current = normalize(path);
  const rest = [];
  for (let i = 0; i < 64; i += 1) {
    try {
      const real = realpathSync(current);
      return rest.length ? join(real, ...rest.reverse()) : real;
    } catch {
      const parent = dirname(current);
      if (parent === current) break;
      rest.push(basename(current));
      current = parent;
    }
  }
  return normalize(path);
}

// ---------------------------------------------------------------------------
// Home discovery: named files only, never a recursive scan.

function secondmateHomes(home) {
  const text = readText(join(home, "data", "secondmates.md"));
  const found = [];
  for (const match of text.matchAll(/\(home: ([^;)]+)[;)]/g)) found.push(match[1].trim());
  return found;
}

function poolHomes(home) {
  const treehouse = join(home, ".treehouse");
  let entries = [];
  try {
    entries = readdirSync(treehouse, { withFileTypes: true });
  } catch {
    return [];
  }
  const found = [];
  for (const entry of entries) {
    if (!entry.isDirectory()) continue;
    const text = readText(join(treehouse, entry.name, "treehouse-state.json"));
    if (!text) continue;
    let state;
    try {
      state = JSON.parse(text);
    } catch {
      continue;
    }
    for (const worktree of Array.isArray(state?.worktrees) ? state.worktrees : []) {
      const path = typeof worktree?.path === "string" ? worktree.path : "";
      if (path && existsSync(join(path, ".fm-secondmate-home"))) found.push(path);
    }
  }
  return found;
}

function isFirstmateHome(path) {
  return isFile(join(path, "AGENTS.md")) && isDir(join(path, "bin")) && isDir(join(path, "data"));
}

export function bulkEntries(text) {
  return (text || "").split("\n").map((raw) => raw.replace(/#.*/, "").trim()).filter(Boolean);
}

// Bulk patterns stay patterns (static prefix realpath'd) and are expanded per
// decision, so a bulk directory created after discovery is protected without
// waiting for a refresh.
function bulkPatternsOf(home) {
  const data = join(home, "data");
  return bulkEntries(readText(join(data, "bulk-paths.txt"))).map((line) => {
    const parts = (isAbsolute(line) ? line : join(data, line)).split("/").filter(Boolean);
    const firstGlob = parts.findIndex((part) => /[*?[]/.test(part));
    const cut = firstGlob === -1 ? parts.length : firstGlob;
    return join(realish(`/${parts.slice(0, cut).join("/")}`), ...parts.slice(cut));
  });
}

export function discover() {
  const home = gateHome();
  const seeds = [join(home, "Tools", "firstmate"), ...poolHomes(home)];
  const homes = [];
  const seen = new Set();
  const queue = [...seeds];
  while (queue.length && homes.length < MAX_HOMES) {
    const candidate = queue.shift();
    if (!candidate || !isFirstmateHome(candidate)) continue;
    const real = realish(candidate);
    if (seen.has(real)) continue;
    seen.add(real);
    homes.push(real);
    queue.push(...secondmateHomes(real));
  }
  const bulk = homes.flatMap((h) => bulkPatternsOf(h));
  return { generated_at: new Date().toISOString(), homes, bulk };
}

export function writeCache(roots) {
  mkdirSync(stateDir(), { recursive: true });
  const tmp = `${cachePath()}.tmp.${process.pid}`;
  writeFileSync(tmp, `${JSON.stringify(roots, null, 2)}\n`);
  renameSync(tmp, cachePath());
}

function loadRoots() {
  try {
    const stat = statSync(cachePath());
    if (Date.now() - stat.mtimeMs < CACHE_MAX_AGE_MS) {
      const cached = JSON.parse(readFileSync(cachePath(), "utf8"));
      if (Array.isArray(cached?.homes) && Array.isArray(cached?.bulk)) return cached;
    }
  } catch {
    // missing or unreadable cache: rediscover below
  }
  const roots = discover();
  try {
    writeCache(roots);
  } catch {
    // a read-only state dir only costs the next call another discovery
  }
  return roots;
}

// The protected set. `exact` roots are refused when the target is the root or
// one of its ancestors; scanning inside one (below it) is allowed. Bulk
// patterns are matched against each target by bulkHit, and all their existing
// matches (uncapped: no `**`, one readdir per segment) also join `exact`
// realpath'd, so a symlinked bulk dir counts however it is reached.
export function protectedRoots(roots = loadRoots()) {
  const home = realish(gateHome());
  const exact = new Set(["/", home, "/mnt/c", join(home, ".cache")]);
  exact.add(realish(join(home, "lattice-ledger", "search-recording")));
  exact.add(realish(join(home, "lattice-ledger", "diagnostics")));
  for (const h of roots.homes) {
    exact.add(h);
    exact.add(realish(join(h, "data")));
  }
  for (const pattern of roots.bulk) {
    for (const match of globExpand(pattern, Infinity)) if (existsSync(match)) exact.add(realish(match));
  }
  return { exact: [...exact], bulk: roots.bulk, store: realish(join(home, "lattice-store")), home };
}

function isAncestorOrSelf(target, root) {
  if (target === root) return true;
  if (target === "/") return true;
  return root.startsWith(target.endsWith(sep) ? target : target + sep);
}

// The store is listable only through the catalog: the store root and its kind
// or bucket directories are refused, one named item (and anything inside it)
// is allowed.
function storeVerdict(target, store) {
  if (!(target === store || target.startsWith(store + sep))) return null;
  const parts = target.slice(store.length).split(sep).filter(Boolean);
  if (parts[0] === "items" && parts.length >= 3) return "allow";
  if ((parts[0] === "quarantine" || parts[0] === "archive") && parts.length >= 2) return "allow";
  return "block";
}

// A path is a bulk directory, or an ancestor of an existing one, when its
// segments match the pattern's leading segments and, if it stops short, the
// rest of the pattern has a match below it. No cap: a capped expansion of the
// rest returns the path itself, which then counts as a match.
function bulkHit(path, pattern) {
  const want = pattern.split("/").filter(Boolean);
  const have = path.split("/").filter(Boolean);
  if (have.length > want.length) return false;
  for (let i = 0; i < have.length; i += 1) if (!segmentRegex(want[i]).test(have[i])) return false;
  if (have.length === want.length) return true;
  return globExpand(join(path, ...want.slice(have.length))).some((p) => existsSync(p));
}

export function classifyTarget(target, roots, lexical = target) {
  if (isFile(target)) return "allow";
  const store = storeVerdict(target, roots.store);
  if (store) return store;
  if (isAncestorOrSelf(target, roots.store)) return "block";
  for (const root of roots.exact) if (isAncestorOrSelf(target, root)) return "block";
  for (const pattern of roots.bulk) if (bulkHit(target, pattern) || bulkHit(lexical, pattern)) return "block";
  return "allow";
}

// ---------------------------------------------------------------------------
// Target resolution: tilde, $HOME, relative-to-cwd, globs, symlinks.

// `vars` holds literal assignments made earlier in the same command; only the
// size rule passes them, so the scan rule's resolution is unchanged.
function expandHomeVars(word, vars = null) {
  const home = gateHome();
  let value = word.value;
  if (!word.literal) {
    value = value.replace(/^\$\{HOME\}(?=\/|$)/, home).replace(/^\$HOME(?=\/|$)/, home);
    if (vars) value = value.replace(/\$\{([A-Za-z_][A-Za-z0-9_]*)\}|\$([A-Za-z_][A-Za-z0-9_]*)/g, (all, a, b) => (Object.hasOwn(vars, a || b) ? vars[a || b] : all));
    if (value.includes("$") || word.subs.length) return null;
  }
  if (value === "~" || value.startsWith("~/")) return home + value.slice(1);
  const user = value.match(/^~([A-Za-z0-9_.-]+)(\/.*)?$/);
  if (user) return `/home/${user[1]}${user[2] || ""}`;
  return value;
}

function braceExpand(pattern) {
  const match = pattern.match(/^(.*?)\{([^{}]*,[^{}]*)\}(.*)$/);
  if (!match) return [pattern];
  const out = [];
  for (const alt of match[2].split(",")) out.push(...braceExpand(`${match[1]}${alt}${match[3]}`));
  return out.slice(0, MAX_GLOB_MATCHES);
}

function segmentRegex(segment) {
  let out = "^";
  for (let i = 0; i < segment.length; i += 1) {
    const char = segment[i];
    if (char === "*") out += "[^/]*";
    else if (char === "?") out += "[^/]";
    else if (char === "[") {
      const end = segment.indexOf("]", i + 1);
      if (end === -1) out += "\\[";
      else {
        out += `[${segment.slice(i + 1, end).replace(/^!/, "^").replace(/\\/g, "\\\\")}]`;
        i = end;
      }
    } else out += char.replace(/[.+^${}()|\\]/g, "\\$&");
  }
  return new RegExp(`${out}$`);
}

// Expand one absolute glob pattern one directory level at a time. A `**`
// segment stands for everything below its static prefix, so the prefix itself
// becomes the target. Too many matches collapse to the static prefix too.
function globExpand(pattern, cap = MAX_GLOB_MATCHES) {
  const parts = pattern.split("/");
  let paths = [parts[0] === "" ? "/" : parts[0]];
  for (let i = 1; i < parts.length; i += 1) {
    const segment = parts[i];
    if (segment === "") continue;
    if (segment === "**") return paths;
    if (!/[*?[]/.test(segment)) {
      paths = paths.map((p) => join(p, segment));
      continue;
    }
    const regex = segmentRegex(segment);
    const next = [];
    for (const dir of paths) {
      let names = [];
      try {
        names = readdirSync(dir);
      } catch {
        continue;
      }
      for (const name of names) {
        if (name.startsWith(".") && !segment.startsWith(".")) continue;
        if (regex.test(name)) next.push(join(dir, name));
        if (next.length > cap) return paths;
      }
    }
    if (next.length === 0) return [pattern];
    paths = next;
  }
  return paths;
}

function resolveTargets(word, cwd, vars = null) {
  const value = typeof word === "string" ? expandHomeVars({ value: word, literal: true, subs: [] }) : expandHomeVars(word, vars);
  if (value === null) return null;
  const absolute = isAbsolute(value) ? value : resolve(cwd, value);
  const globbed = typeof word === "string" ? /[*?[{]/.test(value) : word.unquotedExpansion;
  const candidates = globbed ? braceExpand(absolute).flatMap((p) => globExpand(p)) : [absolute];
  return candidates.map((p) => ({ target: realish(p), lexical: p }));
}

// ---------------------------------------------------------------------------
// Per-tool argument parsing. Each returns { scan: bool, paths: [words] }.

function operandsAfterOptions(words, { shortArg = "", longArg = [], stopAtFirstOperand = false } = {}) {
  const options = [];
  const operands = [];
  let endOfOptions = false;
  for (let i = 0; i < words.length; i += 1) {
    const word = words[i];
    const value = word.value;
    if (!endOfOptions && value === "--") {
      endOfOptions = true;
      continue;
    }
    if (!endOfOptions && value.startsWith("--") && value.length > 2) {
      const name = value.slice(2).split("=")[0];
      options.push({ name, value: value.includes("=") ? value.slice(value.indexOf("=") + 1) : null, long: true });
      if (!value.includes("=") && longArg.includes(name) && i + 1 < words.length) {
        options.at(-1).value = words[i + 1].value;
        i += 1;
      }
      continue;
    }
    if (!endOfOptions && value.startsWith("-") && value.length > 1 && !/^-\d+$/.test(value)) {
      for (let j = 1; j < value.length; j += 1) {
        const letter = value[j];
        if (shortArg.includes(letter)) {
          const rest = value.slice(j + 1);
          if (rest) options.push({ name: letter, value: rest });
          else {
            options.push({ name: letter, value: words[i + 1]?.value ?? "" });
            i += 1;
          }
          break;
        }
        options.push({ name: letter, value: null });
      }
      continue;
    }
    operands.push(word);
    if (stopAtFirstOperand) endOfOptions = true;
  }
  return { options, operands };
}

const has = (options, ...names) => options.some((o) => names.includes(o.name));

function grepLike(args, alwaysRecursive) {
  const { options, operands } = operandsAfterOptions(args, {
    shortArg: "efmABCdDX",
    longArg: ["regexp", "file", "max-count", "after-context", "before-context", "context", "include", "exclude", "exclude-dir", "exclude-from", "label", "directories", "devices", "binary-files"],
  });
  const recursive = alwaysRecursive
    || has(options, "r", "R", "recursive", "dereference-recursive")
    || options.some((o) => (o.name === "d" || o.name === "directories") && o.value === "recurse");
  if (!recursive) return { scan: false, paths: [] };
  const patternGiven = has(options, "e", "f", "regexp", "file");
  return { scan: true, paths: patternGiven ? operands : operands.slice(1) };
}

function rgArgs(args) {
  const { options, operands } = operandsAfterOptions(args, {
    shortArg: "ABCEMTdefgjmrt",
    longArg: ["after-context", "before-context", "context", "encoding", "max-columns", "type-not", "max-depth", "maxdepth", "regexp", "file", "glob", "iglob", "threads", "max-count", "replace", "type", "colors", "context-separator", "field-context-separator", "field-match-separator", "path-separator", "pre", "pre-glob", "sort", "sortr", "type-add", "type-clear", "max-filesize", "dfa-size-limit", "regex-size-limit", "engine", "hostname-bin", "hyperlink-format", "ignore-file", "generate"],
  });
  if (has(options, "help", "h", "version", "V", "type-list", "generate")) return { scan: false, paths: [] };
  const patternLess = has(options, "files", "e", "f", "regexp", "file");
  return { scan: true, paths: patternLess ? operands : operands.slice(1) };
}

function agArgs(args) {
  const { options, operands } = operandsAfterOptions(args, { shortArg: "ABCGgmpW", longArg: ["after", "before", "context", "file-search-regex", "max-count", "path-to-ignore", "depth", "pager", "width"] });
  if (has(options, "help", "h", "version", "V", "list-file-types")) return { scan: false, paths: [] };
  return { scan: true, paths: has(options, "g") ? operands : operands.slice(1) };
}

function findArgs(args) {
  let i = 0;
  while (i < args.length && /^-[HLP]$|^-O\d$/.test(args[i].value)) i += 1;
  if (args[i]?.value === "-D") i += 2;
  const paths = [];
  while (i < args.length && !/^[-(!]/.test(args[i].value) && args[i].value !== ",") {
    paths.push(args[i]);
    i += 1;
  }
  for (let j = i; j < args.length; j += 1) {
    if (args[j].value === "-maxdepth" && /^[01]$/.test(args[j + 1]?.value || "")) return { scan: false, paths: [] };
  }
  return { scan: true, paths };
}

function duArgs(args) {
  const { options, operands } = operandsAfterOptions(args, { shortArg: "BdtX", longArg: ["block-size", "max-depth", "threshold", "exclude-from", "time-style", "files0-from"] });
  if (has(options, "help", "version")) return { scan: false, paths: [] };
  return { scan: true, paths: operands };
}

function treeArgs(args) {
  const { options, operands } = operandsAfterOptions(args, { shortArg: "LPIoH", longArg: ["charset", "filelimit", "timefmt", "sort", "hintro", "houtro"] });
  if (has(options, "help", "version")) return { scan: false, paths: [] };
  if (options.some((o) => o.name === "L" && /^[01]$/.test(o.value || ""))) return { scan: false, paths: [] };
  return { scan: true, paths: operands };
}

function lsArgs(args) {
  const { options, operands } = operandsAfterOptions(args, { shortArg: "IwT", longArg: ["ignore", "hide", "width", "tabsize", "block-size", "format", "sort", "time", "time-style", "quoting-style", "indicator-style"] });
  if (!has(options, "R", "recursive")) return { scan: false, paths: [] };
  return { scan: true, paths: operands };
}

const SCANNERS = {
  grep: (a) => grepLike(a, false),
  egrep: (a) => grepLike(a, false),
  fgrep: (a) => grepLike(a, false),
  ugrep: (a) => grepLike(a, true),
  ug: (a) => grepLike(a, true),
  rg: rgArgs,
  ag: agArgs,
  find: findArgs,
  du: duArgs,
  tree: treeArgs,
  ls: lsArgs,
};

// Wrappers that run their operand command in the same effective cwd. The value
// lists short options that consume the next word.
const PASS_THROUGH = {
  nice: "n",
  ionice: "cnpt",
  stdbuf: "ioe",
  time: "fo",
  xargs: "adEeIiLlnPs",
  doas: "Cu",
  chrt: "",
  taskset: "",
  unbuffer: "",
  flock: "wEc",
};

const SSH_ARG_OPTIONS = "BbcDEeFIiJLlmOopQRSWw";

function skipOptions(words, index, argLetters) {
  let i = index;
  while (words[i] && words[i].value.startsWith("-") && words[i].value !== "-") {
    const value = words[i].value;
    if (value === "--") return i + 1;
    if (!value.startsWith("--") && value.length === 2 && argLetters.includes(value[1])) i += 2;
    else i += 1;
  }
  return i;
}

// ---------------------------------------------------------------------------
// Command analysis.

function remotePath(cwd, raw) {
  if (/^(\/|~|\$HOME|\$\{HOME\})/.test(raw)) return raw;
  return posix.join(cwd, raw);
}

function remoteVerdict(tool, words, cwd) {
  const targets = words.length ? words.map((w) => remotePath(cwd, w.value)) : [cwd];
  for (const raw of targets) {
    const t = raw.replace(/\/+$/, "") || "/";
    if (["/", "~", ".", "$HOME", "${HOME}", "/home", "/mnt", "/mnt/c", "/root"].includes(t)) return { tool: `ssh ${tool}`, target: `remote:${raw}` };
    if (/^\/home\/[^/]+$/.test(t)) return { tool: `ssh ${tool}`, target: `remote:${raw}` };
  }
  return null;
}

function analyzeSsh(words, index, depth) {
  let i = index + 1;
  while (words[i] && words[i].value.startsWith("-")) {
    const value = words[i].value;
    const last = value[value.length - 1];
    i += value.length === 2 && SSH_ARG_OPTIONS.includes(last) ? 2 : 1;
  }
  i += 1;
  const remote = words.slice(i).map((w) => w.value).join(" ");
  if (!remote.trim()) return { scans: [] };
  return analyze(remote, "~", depth + 1, true);
}

// Pathless searches that read stdin, not the cwd, when it is a pipe or redirect.
const STDIN_READERS = new Set(["rg", "ag", "ugrep", "ug"]);

// One node's command after its wrappers, plus whether it runs at nice 19 and
// the idle I/O class (both wrappers present), the size rule's niced one-off read.
function commandCore(tokens) {
  const position = commandPosition(tokens);
  const words = position.words;
  let index = position.index;
  let nice19 = false;
  let ioIdle = false;
  for (let guard = 0; guard < 16 && words[index]; guard += 1) {
    const name = basename(words[index].value);
    if (name in PASS_THROUGH) {
      const end = skipOptions(words, index + 1, PASS_THROUGH[name]);
      const opts = words.slice(index + 1, end).map((w) => w.value).join(" ");
      if (name === "nice" && /(^|\s)(-n\s*|--adjustment=|-)19(\s|$)/.test(opts)) nice19 = true;
      if (name === "ionice" && /(^|\s)(-c\s*|--class[= ])(3|idle)(\s|$)/.test(opts)) ioIdle = true;
      index = end;
      if (name === "flock" && words[index]) index += 1;
      if (name === "taskset" && words[index]) index += 1;
      if (name === "chrt" && words[index]) index += 1;
      continue;
    }
    if (["sudo", "env", "timeout", "gtimeout", "exec", "nohup", "command"].includes(name)) {
      const inner = commandPosition(words.slice(index));
      if (inner.index === 0) break;
      index += inner.index;
      continue;
    }
    break;
  }
  return { position, words, index, niced: nice19 && ioIdle };
}

function analyzeNode(tokens, state, depth, remote, context) {
  const out = { scans: [], reads: [] };
  const nest = (source, cwd, isRemote, niced = false) => {
    const inner = analyze(source, cwd, depth + 1, isRemote, { vars: state.vars, niced: state.niced || niced });
    out.scans.push(...inner.scans);
    out.reads.push(...(inner.reads || []));
  };
  for (const token of tokens) {
    if (token.type === "group") nest(token.content, state.cwd, remote);
    for (const sub of token.subs || []) nest(sub.content, state.cwd, remote);
  }
  const { position, words, index, niced } = commandCore(tokens);
  if (!words[position.index]) {
    if (!remote) rememberAssignments(words.slice(0, position.prefixAssignments), state);
    return out;
  }
  if (position.wrappers.includes("command") && words.slice(0, position.index).some((w) => /^-[^-]*[vV]/.test(w.value))) return out;
  const command = words[index];
  if (!command) return out;
  const name = basename(command.value);
  const args = words.slice(index + 1);
  if (!remote) out.reads.push(...readsOfNode(name, args, tokens, state, { niced: state.niced || niced, pipedToHead: context.pipedToHead }));

  if (name === "cd" || name === "pushd") {
    const dest = args.find((w) => !w.value.startsWith("-") || w.value === "-");
    if (dest?.value === "-") return out;
    if (remote) state.cwd = dest ? remotePath(state.cwd, dest.value) : "~";
    else if (!dest) state.cwd = realish(gateHome());
    else {
      const value = expandHomeVars(dest);
      if (value !== null) state.cwd = realish(isAbsolute(value) ? value : resolve(state.cwd, value));
    }
    return out;
  }
  if (["bash", "sh", "zsh", "dash", "ksh"].includes(name)) {
    for (let i = 0; i < args.length; i += 1) {
      if (/^-[A-Za-z]*c[A-Za-z]*$/.test(args[i].value)) {
        const payload = args[i + 1]?.value === "--" ? args[i + 2] : args[i + 1];
        if (payload) nest(payload.value, state.cwd, remote, niced);
        break;
      }
      if (!args[i].value.startsWith("-")) break;
    }
    return out;
  }
  if (name === "ssh" && !remote) {
    out.scans.push(...analyzeSsh(words, index, depth).scans);
    return out;
  }
  const scanner = SCANNERS[name];
  if (!scanner) return out;
  const parsed = scanner(args);
  if (!parsed.scan) return out;
  const viaXargs = words.slice(position.index, index).some((w) => basename(w.value) === "xargs");
  if (remote) {
    const hit = remoteVerdict(name, parsed.paths, state.cwd);
    if (hit) out.scans.push({ ...hit, verdict: "block" });
    else out.scans.push({ tool: `ssh ${name}`, target: `remote:${parsed.paths.map((w) => remotePath(state.cwd, w.value)).join(" ") || state.cwd}`, verdict: "allow" });
    return out;
  }
  if (parsed.paths.length === 0) {
    const stdinRedirect = tokens.some((t) => t.type === "redir" && t.value.startsWith("<"));
    if (viaXargs) out.scans.push({ tool: name, target: "(paths from stdin)", verdict: "allow", unresolved: true });
    else if (STDIN_READERS.has(name) && (context.pipedStdin || stdinRedirect)) out.scans.push({ tool: name, target: "(stdin)", verdict: "allow" });
    else out.scans.push({ tool: name, target: state.cwd, verdict: null });
    return out;
  }
  for (const word of parsed.paths) {
    const targets = resolveTargets(word, state.cwd);
    if (targets === null) {
      out.scans.push({ tool: name, target: word.value, verdict: "allow", unresolved: true });
      continue;
    }
    for (const resolved of targets) out.scans.push({ tool: name, ...resolved, verdict: null });
  }
  return out;
}

function nodeCommandName(tokens) {
  const { words, index } = commandCore(tokens);
  return words[index] ? basename(words[index].value) : "";
}

// Scans (the scan rule) and whole-file reads (the size rule) in one command.
// `context` carries literal assignments and the niced wrapper into nested
// shells, subshells and substitutions.
export function analyze(command, cwd, depth = 0, remote = false, context = {}) {
  if (depth > MAX_DEPTH) return { scans: [], reads: [] };
  const lexed = new Lexer(command.replace(/\\\r?\n/g, "")).tokenize();
  if (lexed.error) return { scans: [], reads: [], error: lexed.error };
  const { nodes, separators } = splitProgram(lexed.tokens);
  const state = { cwd, vars: { ...(context.vars || {}) }, niced: Boolean(context.niced) };
  const scans = [];
  const reads = [];
  nodes.forEach((node, i) => {
    const pipedStdin = i > 0 && (separators[i - 1] === "|" || separators[i - 1] === "|&");
    const pipedToHead = (separators[i] === "|" || separators[i] === "|&") && nodes[i + 1] && nodeCommandName(nodes[i + 1]) === "head";
    const result = analyzeNode(node, state, depth, remote, { pipedStdin, pipedToHead });
    scans.push(...result.scans);
    reads.push(...result.reads);
  });
  return { scans, reads };
}

// ---------------------------------------------------------------------------
// Read recognition: which named files one call reads, and whether each read is
// bounded. The size rule stats these; the read log (fm-data-gate-metrics) can
// call recognizeReads for the same answer. Nothing here opens a file.

function rememberAssignments(words, state) {
  for (const word of words) {
    const match = word.value.match(/^([A-Za-z_][A-Za-z0-9_]*)=(.*)$/s);
    if (!match) continue;
    const value = expandHomeVars({ ...word, value: match[2] }, state.vars);
    if (value === null || word.subs.length) delete state.vars[match[1]];
    else state.vars[match[1]] = value;
  }
}

// Streamers emit output as they read, so piping them into head stops the read.
const STREAMERS = new Set(["cat", "tac", "nl", "zcat", "gzcat", "xzcat", "bzcat", "zstdcat", "xxd", "od", "hexdump", "strings", "base64"]);

const optionValue = (options, ...names) => options.find((o) => names.includes(o.name))?.value;

function plainReader(shortArg = "", longArg = []) {
  return (args) => ({ files: operandsAfterOptions(args, { shortArg, longArg }).operands });
}

function grepReader(args) {
  const { options, operands } = operandsAfterOptions(args, {
    shortArg: "efmABCdDX",
    longArg: ["regexp", "file", "max-count", "after-context", "before-context", "context", "include", "exclude", "exclude-dir", "exclude-from", "label", "directories", "devices", "binary-files"],
  });
  return { files: has(options, "e", "f", "regexp", "file") ? operands : operands.slice(1) };
}

function rgReader(args) {
  const { options, operands } = operandsAfterOptions(args, {
    shortArg: "ABCEMTdefgjmrt",
    longArg: ["after-context", "before-context", "context", "encoding", "max-columns", "type-not", "max-depth", "maxdepth", "regexp", "file", "glob", "iglob", "threads", "max-count", "replace", "type", "sort", "sortr", "type-add", "max-filesize", "engine", "pre", "pre-glob", "ignore-file"],
  });
  return { files: has(options, "files", "e", "f", "regexp", "file") ? operands : operands.slice(1) };
}

function sedReader(args) {
  const { options, operands } = operandsAfterOptions(args, { shortArg: "efl", longArg: ["expression", "file", "line-length"] });
  const scripts = options.filter((o) => o.name === "e" || o.name === "expression").map((o) => o.value || "");
  const scriptGiven = scripts.length > 0 || has(options, "f", "file");
  if (!scriptGiven && operands.length) scripts.push(operands[0].value);
  const quits = scripts.some((s) => /(^|[;{}\n]|\s)(\d+|\$|\/[^/]*\/)?\s*[qQ]\s*\d*\s*($|[;}\n])/.test(s));
  return { files: scriptGiven ? operands : operands.slice(1), bounded: quits };
}

function awkReader(args) {
  const { options, operands } = operandsAfterOptions(args, { shortArg: "Ffv", longArg: ["field-separator", "file", "assign"] });
  const rest = has(options, "f", "file") ? operands : operands.slice(1);
  return { files: rest.filter((w) => !/^[A-Za-z_][A-Za-z0-9_]*=/.test(w.value)) };
}

function jqReader(args) {
  const { options, operands } = operandsAfterOptions(args, { shortArg: "fL", longArg: ["from-file", "indent", "tab"] });
  const fromFile = has(options, "f", "from-file");
  // --arg/--argjson/--slurpfile/--rawfile take two words; drop them.
  const files = [];
  for (let i = fromFile ? 0 : 1; i < operands.length; i += 1) files.push(operands[i]);
  const skip = new Set();
  args.forEach((w, i) => {
    if (["--arg", "--argjson", "--slurpfile", "--rawfile"].includes(w.value)) {
      skip.add(args[i + 1]);
      skip.add(args[i + 2]);
    }
  });
  return { files: files.filter((w) => !skip.has(w)) };
}

function ddReader(args) {
  const files = [];
  let bounded = false;
  for (const word of args) {
    if (word.value.startsWith("if=")) files.push({ ...word, value: word.value.slice(3) });
    if (/^count=/.test(word.value)) bounded = true;
  }
  return { files, bounded };
}

function boundedBy(shortArg, bound, longArg = [], longBound = []) {
  return (args) => {
    const { options, operands } = operandsAfterOptions(args, { shortArg, longArg });
    return { files: operands, bounded: has(options, ...bound, ...longBound) };
  };
}

function compressor(args) {
  const { options, operands } = operandsAfterOptions(args, { shortArg: "S", longArg: ["suffix"] });
  return { files: has(options, "c", "stdout", "t", "test", "l", "list") ? operands : [] };
}

// Whole-file readers of their named file operands. Each returns
// { files: [words], bounded?: bool }.
const READERS = {
  cat: plainReader(),
  tac: plainReader("s", ["separator"]),
  nl: plainReader("bdfhilnsvw"),
  less: plainReader("bhjkoOpPtTxyz#"),
  more: plainReader("n"),
  bat: (args) => {
    const { options, operands } = operandsAfterOptions(args, { shortArg: "lHrm", longArg: ["language", "highlight-line", "line-range", "map-syntax", "theme", "style", "tabs", "wrap", "terminal-width", "color", "paging", "pager", "decorations"] });
    return { files: operands, bounded: has(options, "r", "line-range") };
  },
  grep: grepReader,
  egrep: grepReader,
  fgrep: grepReader,
  rg: rgReader,
  ag: (args) => ({ files: operandsAfterOptions(args, { shortArg: "ABCGgmpW" }).operands.slice(1) }),
  ugrep: grepReader,
  ug: grepReader,
  awk: awkReader,
  gawk: awkReader,
  mawk: awkReader,
  sed: sedReader,
  wc: plainReader(),
  sort: plainReader("koSTt", ["key", "output", "buffer-size", "temporary-directory", "field-separator", "parallel", "files0-from"]),
  uniq: plainReader("fsw", ["skip-fields", "skip-chars", "check-chars"]),
  cut: plainReader("bcdf", ["bytes", "characters", "delimiter", "fields", "output-delimiter"]),
  paste: plainReader("d", ["delimiters"]),
  jq: jqReader,
  diff: plainReader("CUFIxX", ["context", "unified", "label", "exclude", "exclude-from", "ignore-matching-lines", "from-file", "to-file"]),
  cmp: boundedBy("in", ["n"], ["ignore-initial", "bytes"], ["bytes"]),
  strings: plainReader("nte", ["bytes", "radix", "encoding"]),
  base64: plainReader("w", ["wrap"]),
  sha1sum: plainReader(),
  sha224sum: plainReader(),
  sha256sum: plainReader(),
  sha384sum: plainReader(),
  sha512sum: plainReader(),
  md5sum: plainReader(),
  b2sum: plainReader("l", ["length"]),
  cksum: plainReader("a", ["algorithm", "length"]),
  xxd: boundedBy("lscgo", ["l"], ["len", "seek", "cols", "groupsize"], ["len"]),
  od: boundedBy("NjAtwS", ["N"], ["read-bytes", "skip-bytes", "address-radix", "format", "width", "strings"], ["read-bytes"]),
  hexdump: boundedBy("nsef", ["n"], ["length", "skip", "format", "format-file"], ["length"]),
  zcat: plainReader(),
  gzcat: plainReader(),
  xzcat: plainReader(),
  bzcat: plainReader(),
  zstdcat: plainReader(),
  gzip: compressor,
  gunzip: compressor,
  xz: compressor,
  zstd: compressor,
  bzip2: compressor,
  dd: ddReader,
};

// head and tail read a bounded amount from the start or end of what they are fed.
const BOUNDED_STDIN = new Set(["head", "tail"]);

// Literal paths a Python -c or stdin script opens whole. A script that seeks or
// reads a counted amount is a bounded read.
function pythonReads(code) {
  const bounded = /\.seek\(|\.read\(\s*\d|readline\(|islice\(|mmap\./.test(code);
  const paths = [];
  const pattern = /\b(?:open|Path)\(\s*(?:[rfbu]{0,2})?(["'])([^"'\n]+)\1/g;
  for (const match of code.matchAll(pattern)) if (!/[{}]/.test(match[2])) paths.push(match[2]);
  return { paths, bounded };
}

function pythonReader(args, tokens) {
  const words = args;
  for (let i = 0; i < words.length; i += 1) {
    const value = words[i].value;
    if (value === "-c") return words[i + 1] && words[i + 1].literal ? pythonReads(words[i + 1].value) : { paths: [], bounded: false };
    if (value === "-m") return { paths: [], bounded: false };
    if (value === "-" || !value.startsWith("-")) {
      if (value !== "-") return { paths: [], bounded: false };
      break;
    }
  }
  const heredoc = tokens.find((t) => t.type === "redir" && typeof t.heredoc === "string");
  return heredoc ? pythonReads(heredoc.heredoc) : { paths: [], bounded: false };
}

function readsOfNode(name, args, tokens, state, flags) {
  const found = [];
  const add = (tool, word, bounded) => {
    if (word.value === "-" || word.value === "") return;
    const targets = resolveTargets(word, state.cwd, state.vars);
    if (targets === null) return;
    for (const resolved of targets) found.push({ tool, ...resolved, bounded: Boolean(bounded), niced: flags.niced });
  };
  if (name === "export") rememberAssignments(args, state);
  const reader = READERS[name];
  if (reader) {
    const parsed = reader(args);
    const bounded = parsed.bounded || (flags.pipedToHead && STREAMERS.has(name));
    for (const word of parsed.files) add(name, word, bounded);
  }
  if (name === "python" || name === "python3" || /^python3\.\d+$/.test(name)) {
    const parsed = pythonReader(args, tokens);
    for (const path of parsed.paths) add(name, { value: path, literal: true, subs: [], unquotedExpansion: false }, parsed.bounded);
  }
  for (let i = 0; i < tokens.length; i += 1) {
    const token = tokens[i];
    if (token.type !== "redir" || token.value !== "<" || token.fd !== 0 || token.inlineTarget) continue;
    const target = tokens[i + 1];
    if (target?.type === "word") add(`${name} <`, target, BOUNDED_STDIN.has(name) || (name === "dd" && args.some((w) => /^count=/.test(w.value))));
  }
  return found;
}

// Every named-file read in one call: [{ tool, target, lexical, bounded, niced }].
// A Read tool call is bounded when it names an offset or a limit.
export function recognizeReads(call) {
  if (call.kind === "read") {
    if (typeof call.path !== "string" || !call.path) return [];
    const cwd = realish(call.cwd);
    const targets = resolveTargets(call.path, cwd) || [];
    const bounded = call.offset != null || call.limit != null;
    return targets.map((resolved) => ({ tool: "Read", ...resolved, bounded, niced: false }));
  }
  if (call.kind === "bash") return analyze(call.command, realish(call.cwd)).reads || [];
  return [];
}

// Path patterns (segment globs, absolute after ~ expansion) whose whole-file
// reads the size rule allows at any size. Each entry is a reviewed false block
// with a test row in tests/fm-data-gate.test.sh.
export const SIZE_ALLOW = [];

function sizeAllowed(path) {
  return SIZE_ALLOW.some((raw) => {
    const pattern = raw.startsWith("~/") ? join(gateHome(), raw.slice(2)) : raw;
    const want = pattern.split("/").filter(Boolean);
    const have = path.split("/").filter(Boolean);
    return want.length === have.length && want.every((segment, i) => segmentRegex(segment).test(have[i]));
  });
}

function fileSize(path) {
  try {
    const stat = statSync(path);
    return stat.isFile() ? stat.size : null;
  } catch {
    return null;
  }
}

// The size rule: one stat per read target. Returns the reads of regular files
// over the limit, each with its verdict (block only for an unbounded, un-niced,
// not allow-listed read).
export function sizeVerdicts(reads, limit) {
  const over = [];
  for (const read of reads) {
    const size = fileSize(read.target);
    if (size === null || size <= limit) continue;
    let verdict = "block";
    let why;
    if (read.bounded) [verdict, why] = ["allow", "bounded"];
    else if (read.niced) [verdict, why] = ["allow", "niced"];
    else if (sizeAllowed(read.target)) [verdict, why] = ["allow", "allow-rule"];
    over.push({ ...read, size, verdict, ...(why ? { why } : {}) });
  }
  return over;
}

// The Grep and Glob tools both walk their path, or the cwd when they have none;
// an absolute or ~-rooted Glob pattern walks from its static prefix instead.
function toolTargets(kind, path, pattern, cwd) {
  let base = path;
  if (kind === "glob" && typeof pattern === "string" && (isAbsolute(pattern) || pattern === "~" || pattern.startsWith("~/"))) {
    const parts = pattern.split("/");
    const firstGlob = parts.findIndex((part) => /[*?[{]/.test(part));
    base = (firstGlob === -1 ? parts : parts.slice(0, firstGlob)).join("/") || "/";
  }
  return base ? (resolveTargets(base, cwd) || [{ target: resolve(cwd, base) }]) : [{ target: cwd }];
}

// Decide one call under both rules. Returns { verdict, scans, tool, target,
// note } for the scan rule plus `size`: { verdict, reads, tool, target, bytes }
// for the size rule, whose `reads` lists only reads of files over the limit.
export function decide(call, roots = protectedRoots(), { sizeLimit = DEFAULT_SIZE_LIMIT } = {}) {
  let scans = [];
  let reads = [];
  let note;
  const cwd = realish(call.cwd);
  if (call.kind === "bash") {
    const result = analyze(call.command, cwd);
    scans = result.scans;
    reads = result.reads || [];
    if (result.error) note = `unparsed: ${result.error}`;
  } else if (call.kind === "read") {
    reads = recognizeReads(call);
  } else {
    const tool = call.kind === "glob" ? "Glob" : "Grep";
    scans = toolTargets(call.kind, call.path, call.pattern, cwd).map((resolved) => ({ tool, ...resolved, verdict: null }));
  }
  for (const scan of scans) if (!scan.verdict) scan.verdict = classifyTarget(scan.target, roots, scan.lexical);
  const over = sizeVerdicts(reads, sizeLimit);
  const tooBig = over.find((r) => r.verdict === "block");
  const size = tooBig
    ? { verdict: "block", reads: over, tool: tooBig.tool, target: tooBig.target, bytes: tooBig.size }
    : { verdict: "allow", reads: over };
  const blocked = scans.find((s) => s.verdict === "block");
  if (blocked) return { verdict: "block", scans, tool: blocked.tool, target: blocked.target, note, size };
  return { verdict: "allow", scans, note, size };
}

// ---------------------------------------------------------------------------
// Payload extraction and logging.

function extractPayload(harness, raw) {
  const payload = JSON.parse(raw);
  const input = payload.tool_input || payload.toolInput || {};
  const toolName = String(payload.tool_name || payload.toolName || "Bash");
  const cwd = typeof payload.cwd === "string" && payload.cwd ? payload.cwd : process.cwd();
  if (typeof input.command === "string") return { kind: "bash", command: input.command, cwd };
  if (/^grep$/i.test(toolName)) return { kind: "grep", path: input.path, pattern: input.pattern, cwd };
  if (/^glob$/i.test(toolName)) return { kind: "glob", path: input.path, pattern: input.pattern, cwd };
  if (/^read$/i.test(toolName)) return { kind: "read", path: input.file_path ?? input.filePath ?? input.path, offset: input.offset ?? undefined, limit: input.limit ?? undefined, cwd };
  void harness;
  return null;
}

function describe(call) {
  if (call.kind === "bash") return call.command;
  if (call.kind === "read") return `Read path=${call.path ?? ""}${call.offset != null ? ` offset=${call.offset}` : ""}${call.limit != null ? ` limit=${call.limit}` : ""}`;
  const tool = call.kind === "glob" ? "Glob" : "Grep";
  return `${tool} path=${call.path ?? ""} pattern=${call.pattern ?? ""}`;
}

export function appendLog(record) {
  try {
    mkdirSync(stateDir(), { recursive: true });
    appendFileSync(logPath(), `${JSON.stringify(record)}\n`);
  } catch {
    // logging must never turn into a block
  }
}

function parseArguments(argv) {
  const args = { sub: argv[0] || "", harness: "unknown", mode: "log", sizeMode: "log", sizeLimit: DEFAULT_SIZE_LIMIT, stdin: false };
  for (let i = 1; i < argv.length; i += 1) {
    const name = argv[i];
    const value = argv[i + 1];
    switch (name) {
      case "--harness": args.harness = value; i += 1; break;
      case "--mode": args.mode = value; i += 1; break;
      case "--size-mode": args.sizeMode = value; i += 1; break;
      case "--size-limit": args.sizeLimit = Number(value); i += 1; break;
      case "--offset": args.offset = value; i += 1; break;
      case "--limit": args.limit = value; i += 1; break;
      case "--command": args.command = value; i += 1; break;
      case "--tool": args.tool = value; i += 1; break;
      case "--path": args.path = value; i += 1; break;
      case "--pattern": args.pattern = value; i += 1; break;
      case "--cwd": args.cwd = value; i += 1; break;
      case "--stdin": args.stdin = true; break;
      default: throw new Error(`unknown argument: ${name}`);
    }
  }
  return args;
}

function runDecide(args) {
  let call;
  if (args.stdin) {
    call = extractPayload(args.harness, readFileSync(0, "utf8"));
    if (call && args.cwd) call.cwd = args.cwd;
  } else if (args.command !== undefined) {
    call = { kind: "bash", command: args.command, cwd: args.cwd || process.cwd() };
  } else if (/^read$/i.test(args.tool || "")) {
    call = { kind: "read", path: args.path || undefined, offset: args.offset || undefined, limit: args.limit || undefined, cwd: args.cwd || process.cwd() };
  } else if (args.tool) {
    const kind = /^glob$/i.test(args.tool) ? "glob" : "grep";
    call = { kind, path: args.path || undefined, pattern: args.pattern, cwd: args.cwd || process.cwd() };
  }
  if (!Number.isFinite(args.sizeLimit) || args.sizeLimit < 0) throw new Error(`bad --size-limit: ${args.sizeLimit}`);
  if (!call) {
    process.stdout.write("allow\n");
    return;
  }
  const result = decide(call, protectedRoots(), { sizeLimit: args.sizeLimit });
  const scanBlocks = result.verdict === "block";
  const sizeBlocks = result.size.verdict === "block";
  const enforcedScan = scanBlocks && args.mode === "enforce";
  const enforcedSize = sizeBlocks && args.sizeMode === "enforce";
  if (result.scans.length > 0 || result.size.reads.length > 0 || result.note) {
    const record = {
      ts: new Date().toISOString(),
      harness: args.harness,
      cwd: call.cwd,
      cmd: describe(call).slice(0, CMD_LOG_LIMIT),
      verdict: enforcedScan || enforcedSize ? "block" : "allow",
      would_block: scanBlocks || sizeBlocks,
      would_block_rules: [...(scanBlocks ? ["scan"] : []), ...(sizeBlocks ? ["size"] : [])],
      mode: args.mode,
      size_mode: args.sizeMode,
      size_limit: args.sizeLimit,
      targets: [
        ...result.scans.map((s) => ({ rule: "scan", tool: s.tool, target: s.target, verdict: s.verdict, ...(s.unresolved ? { unresolved: true } : {}) })),
        ...result.size.reads.map((r) => ({ rule: "size", tool: r.tool, target: r.target, size: r.size, verdict: r.verdict, ...(r.why ? { why: r.why } : {}) })),
      ],
    };
    if (result.note) record.note = result.note;
    appendLog(record);
  }
  if (enforcedScan) process.stdout.write(`block\tscan\t${result.tool}\t${result.target}\n`);
  else if (enforcedSize) process.stdout.write(`block\tsize\t${result.size.tool}\t${result.size.target}\t${mib(result.size.bytes)}\t${mib(args.sizeLimit)}\n`);
  else process.stdout.write("allow\n");
}

function mib(bytes) {
  const value = bytes / 1048576;
  return `${Number.isInteger(value) ? value : value.toFixed(1)} MiB`;
}

function invokedDirectly() {
  const entry = process.argv[1];
  if (!entry) return false;
  try {
    return realpathSync(entry) === realpathSync(fileURLToPath(import.meta.url));
  } catch {
    return false;
  }
}

if (invokedDirectly()) {
  try {
    const args = parseArguments(process.argv.slice(2));
    if (args.sub === "decide") runDecide(args);
    else if (args.sub === "refresh") {
      const roots = discover();
      writeCache(roots);
      process.stdout.write(`homes=${roots.homes.length} bulk=${roots.bulk.length} cache=${cachePath()}\n`);
    } else if (args.sub === "roots") {
      const roots = protectedRoots();
      process.stdout.write(`store ${roots.store}\n`);
      for (const root of roots.exact) process.stdout.write(`root ${root}\n`);
      for (const pattern of roots.bulk) process.stdout.write(`bulk ${pattern}\n`);
    } else throw new Error(`unknown subcommand: ${args.sub}`);
  } catch (error) {
    process.stderr.write(`${error.message}\n`);
    process.exitCode = 1;
  }
}
