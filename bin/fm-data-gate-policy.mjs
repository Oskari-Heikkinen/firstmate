#!/usr/bin/env node
// Decision owner for the data gate: does one agent tool call recursively scan
// bulk run data, a Firstmate home root, the user's home, or a whole drive?
//
// bin/fm-data-gate.sh is the stable harness entry point; it owns the mode,
// the cheap prefilter, the time bound, the error fallback, and the per-harness
// deny rendering. This module owns everything else: payload extraction, shell
// parsing, target resolution, the protected-root set, home discovery, the roots
// cache, and the decision log. See docs/data-gate.md for the contract.
//
// The shell tokenizer and command-position analysis are imported from
// bin/fm-arm-command-policy.mjs, the sole owner of firstmate's shell lexing.
// Nothing here ever evaluates, expands through a shell, or runs any byte of the
// submitted command, and nothing here walks a directory tree: target
// resolution uses realpath, stat, and single-directory reads for glob segments
// only, each bounded.
//
// CLI:
//   fm-data-gate-policy.mjs decide --harness H --mode M [--stdin | --command C |
//       --tool grep|glob --path P [--pattern G]] [--cwd DIR]
//     prints `allow` or `block<TAB>tool<TAB>target` and appends one JSONL
//     decision record for every scan-shaped call.
//   fm-data-gate-policy.mjs refresh
//     rediscovers homes and bulk paths and rewrites the roots cache.
//   fm-data-gate-policy.mjs roots
//     prints the effective protected roots (cache or live), one per line.

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

function bulkPathsOf(home) {
  const data = join(home, "data");
  const out = [];
  for (const line of bulkEntries(readText(join(data, "bulk-paths.txt")))) {
    const pattern = isAbsolute(line) ? line : join(data, line);
    if (/[*?[]/.test(pattern)) out.push(...globExpand(pattern).filter((p) => existsSync(p)));
    else out.push(pattern);
  }
  return out;
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
  const bulk = [];
  for (const h of homes) for (const path of bulkPathsOf(h)) bulk.push(realish(path));
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
// one of its ancestors; scanning inside one (below it) is allowed.
export function protectedRoots(roots = loadRoots()) {
  const home = realish(gateHome());
  const exact = new Set(["/", home, "/mnt/c", join(home, ".cache")]);
  exact.add(realish(join(home, "lattice-ledger", "search-recording")));
  exact.add(realish(join(home, "lattice-ledger", "diagnostics")));
  for (const h of roots.homes) {
    exact.add(h);
    exact.add(realish(join(h, "data")));
  }
  for (const b of roots.bulk) exact.add(b);
  return { exact: [...exact], store: realish(join(home, "lattice-store")), home };
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

export function classifyTarget(target, roots) {
  if (isFile(target)) return "allow";
  const store = storeVerdict(target, roots.store);
  if (store) return store;
  if (isAncestorOrSelf(target, roots.store)) return "block";
  for (const root of roots.exact) if (isAncestorOrSelf(target, root)) return "block";
  return "allow";
}

// ---------------------------------------------------------------------------
// Target resolution: tilde, $HOME, relative-to-cwd, globs, symlinks.

function expandHomeVars(word) {
  const home = gateHome();
  let value = word.value;
  if (!word.literal) {
    value = value.replace(/^\$\{HOME\}(?=\/|$)/, home).replace(/^\$HOME(?=\/|$)/, home);
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
function globExpand(pattern) {
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
        if (next.length > MAX_GLOB_MATCHES) return paths;
      }
    }
    if (next.length === 0) return [pattern];
    paths = next;
  }
  return paths;
}

function resolveTargets(word, cwd) {
  const value = typeof word === "string" ? expandHomeVars({ value: word, literal: true, subs: [] }) : expandHomeVars(word);
  if (value === null) return null;
  const absolute = isAbsolute(value) ? value : resolve(cwd, value);
  const globbed = typeof word === "string" ? /[*?[{]/.test(value) : word.unquotedExpansion;
  const candidates = globbed ? braceExpand(absolute).flatMap((p) => globExpand(p)) : [absolute];
  return candidates.map((p) => realish(p));
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

function analyzeNode(tokens, state, depth, remote, pipedStdin) {
  const scans = [];
  for (const token of tokens) {
    if (token.type === "group") scans.push(...analyze(token.content, state.cwd, depth + 1, remote).scans);
    for (const sub of token.subs || []) scans.push(...analyze(sub.content, state.cwd, depth + 1, remote).scans);
  }
  const position = commandPosition(tokens);
  const words = position.words;
  let index = position.index;
  if (!words[index]) return scans;
  if (position.wrappers.includes("command") && words.slice(0, index).some((w) => /^-[^-]*[vV]/.test(w.value))) return scans;

  for (let guard = 0; guard < 16 && words[index]; guard += 1) {
    const name = basename(words[index].value);
    if (name in PASS_THROUGH) {
      index = skipOptions(words, index + 1, PASS_THROUGH[name]);
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
  const command = words[index];
  if (!command) return scans;
  const name = basename(command.value);
  const args = words.slice(index + 1);

  if (name === "cd" || name === "pushd") {
    const dest = args.find((w) => !w.value.startsWith("-") || w.value === "-");
    if (dest?.value === "-") return scans;
    if (remote) state.cwd = dest ? remotePath(state.cwd, dest.value) : "~";
    else if (!dest) state.cwd = realish(gateHome());
    else {
      const value = expandHomeVars(dest);
      if (value !== null) state.cwd = realish(isAbsolute(value) ? value : resolve(state.cwd, value));
    }
    return scans;
  }
  if (["bash", "sh", "zsh", "dash", "ksh"].includes(name)) {
    for (let i = 0; i < args.length; i += 1) {
      if (/^-[A-Za-z]*c[A-Za-z]*$/.test(args[i].value)) {
        const payload = args[i + 1]?.value === "--" ? args[i + 2] : args[i + 1];
        if (payload) scans.push(...analyze(payload.value, state.cwd, depth + 1, remote).scans);
        break;
      }
      if (!args[i].value.startsWith("-")) break;
    }
    return scans;
  }
  if (name === "ssh" && !remote) {
    scans.push(...analyzeSsh(words, index, depth).scans);
    return scans;
  }
  const scanner = SCANNERS[name];
  if (!scanner) return scans;
  const parsed = scanner(args);
  if (!parsed.scan) return scans;
  const viaXargs = words.slice(position.index, index).some((w) => basename(w.value) === "xargs");
  if (remote) {
    const hit = remoteVerdict(name, parsed.paths, state.cwd);
    if (hit) scans.push({ ...hit, verdict: "block" });
    else scans.push({ tool: `ssh ${name}`, target: `remote:${parsed.paths.map((w) => remotePath(state.cwd, w.value)).join(" ") || state.cwd}`, verdict: "allow" });
    return scans;
  }
  if (parsed.paths.length === 0) {
    const stdinRedirect = tokens.some((t) => t.type === "redir" && t.value.startsWith("<"));
    if (viaXargs) scans.push({ tool: name, target: "(paths from stdin)", verdict: "allow", unresolved: true });
    else if (STDIN_READERS.has(name) && (pipedStdin || stdinRedirect)) scans.push({ tool: name, target: "(stdin)", verdict: "allow" });
    else scans.push({ tool: name, target: state.cwd, verdict: null });
    return scans;
  }
  for (const word of parsed.paths) {
    const targets = resolveTargets(word, state.cwd);
    if (targets === null) {
      scans.push({ tool: name, target: word.value, verdict: "allow", unresolved: true });
      continue;
    }
    for (const target of targets) scans.push({ tool: name, target, verdict: null });
  }
  return scans;
}

export function analyze(command, cwd, depth = 0, remote = false) {
  if (depth > MAX_DEPTH) return { scans: [] };
  const lexed = new Lexer(command.replace(/\\\r?\n/g, "")).tokenize();
  if (lexed.error) return { scans: [], error: lexed.error };
  const { nodes, separators } = splitProgram(lexed.tokens);
  const state = { cwd };
  const scans = [];
  nodes.forEach((node, i) => {
    const pipedStdin = i > 0 && (separators[i - 1] === "|" || separators[i - 1] === "|&");
    scans.push(...analyzeNode(node, state, depth, remote, pipedStdin));
  });
  return { scans };
}

// The Grep and Glob tools both walk their path, or the cwd when they have none.
function toolTargets(path, cwd) {
  return path ? (resolveTargets(path, cwd) || [resolve(cwd, path)]) : [cwd];
}

// Decide one call. Returns { verdict, scans, tool, target, note }.
export function decide(call, roots = protectedRoots()) {
  let scans;
  let note;
  const cwd = realish(call.cwd);
  if (call.kind === "bash") {
    const result = analyze(call.command, cwd);
    scans = result.scans;
    if (result.error) note = `unparsed: ${result.error}`;
  } else {
    const tool = call.kind === "glob" ? "Glob" : "Grep";
    scans = toolTargets(call.path, cwd).map((target) => ({ tool, target, verdict: null }));
  }
  for (const scan of scans) if (!scan.verdict) scan.verdict = classifyTarget(scan.target, roots);
  const blocked = scans.find((s) => s.verdict === "block");
  if (blocked) return { verdict: "block", scans, tool: blocked.tool, target: blocked.target, note };
  return { verdict: "allow", scans, note };
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
  void harness;
  return null;
}

function describe(call) {
  if (call.kind === "bash") return call.command;
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
  const args = { sub: argv[0] || "", harness: "unknown", mode: "log", stdin: false };
  for (let i = 1; i < argv.length; i += 1) {
    const name = argv[i];
    const value = argv[i + 1];
    switch (name) {
      case "--harness": args.harness = value; i += 1; break;
      case "--mode": args.mode = value; i += 1; break;
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
  } else if (args.tool) {
    const kind = /^glob$/i.test(args.tool) ? "glob" : "grep";
    call = { kind, path: args.path || undefined, pattern: args.pattern, cwd: args.cwd || process.cwd() };
  }
  if (!call) {
    process.stdout.write("allow\n");
    return;
  }
  const result = decide(call);
  if (result.scans.length > 0 || result.note) {
    const wouldBlock = result.verdict === "block";
    const record = {
      ts: new Date().toISOString(),
      harness: args.harness,
      cwd: call.cwd,
      cmd: describe(call).slice(0, CMD_LOG_LIMIT),
      verdict: wouldBlock && args.mode === "enforce" ? "block" : "allow",
      would_block: wouldBlock,
      mode: args.mode,
      targets: result.scans.map((s) => ({ tool: s.tool, target: s.target, verdict: s.verdict, ...(s.unresolved ? { unresolved: true } : {}) })),
    };
    if (result.note) record.note = result.note;
    appendLog(record);
  }
  if (result.verdict === "block") process.stdout.write(`block\t${result.tool}\t${result.target}\n`);
  else process.stdout.write("allow\n");
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
    } else throw new Error(`unknown subcommand: ${args.sub}`);
  } catch (error) {
    process.stderr.write(`${error.message}\n`);
    process.exitCode = 1;
  }
}
