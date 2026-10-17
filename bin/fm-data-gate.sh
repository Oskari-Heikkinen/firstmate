#!/usr/bin/env bash
# fm-data-gate.sh - user-level PreToolUse data gate for every agent harness.
#
# One harness-neutral entry point for two rules. The scan rule: is an agent
# tool call a recursive scan (grep -r, rg, ugrep, ag, find, du, tree, ls -R,
# the Grep and Glob tools, or any of those over ssh) whose target is, or is an
# ancestor of, a protected root: the bulk store, a Firstmate home root or its
# data/ root, a generated bulk path, the ledger's bulk folders, ~, /, /mnt/c,
# or ~/.cache. The size rule: does it read one named regular file larger than
# the size limit whole (the Read tool without offset or limit, cat, grep, sed,
# awk, a python open() and the other readers docs/data-gate.md lists)?
# bin/fm-data-gate-policy.mjs owns both decisions; this wrapper owns the modes,
# the size limit, the cheap prefilter, the time bound, the error fallback, and
# the per-harness deny rendering. docs/data-gate.md owns the contract.
#
# Usage:
#   <PreToolUse JSON on stdin> | fm-data-gate.sh --harness claude|codex|grok
#   fm-data-gate.sh --harness opencode|pi|omp --command '<cmd>' [--cwd DIR]
#   fm-data-gate.sh --harness H --tool grep|glob [--path P] [--pattern G] [--cwd DIR]
#   fm-data-gate.sh --harness H --tool read --path P [--offset N] [--limit N] [--cwd DIR]
#   fm-data-gate.sh mode [scan|size]  print a rule's effective mode (default scan)
#   fm-data-gate.sh size-limit        print the effective size limit in bytes
#   fm-data-gate.sh refresh   rediscover homes and bulk paths into the roots cache
#   fm-data-gate.sh roots     print the effective protected roots and bulk patterns
#
# Modes, one per rule, from ~/.config/lattice-data-gate/mode:
#   scan - LATTICE_DATA_GATE, else the file's first word, else log.
#   size - LATTICE_DATA_GATE_SIZE, else the file's `size log|enforce` line,
#          else enforce.
# An unknown value means log.
#   log     - always allow; scan-shaped calls and reads of files over the size
#             limit append one JSONL record {ts, harness, cwd, cmd, verdict,
#             would_block, would_block_rules, ...} to
#             ~/.local/state/lattice-data-gate/decisions.jsonl.
#   enforce - refuse a call this rule would block with the refusal text below;
#             still logs.
# Size limit: LATTICE_DATA_GATE_SIZE_LIMIT, else the file's `size-limit N[K|M|G]`
# line (binary units; a bare number is bytes), else 200M. Invalid means 200M.
#
# Read log: in every mode a read-shaped call (the Read tool, or a shell command
# naming a reader such as cat, head, tail, jq, sed, grep or python -c open) is
# also passed to bin/fm-data-gate-reads.mjs, which appends one row per named
# file to ~/.local/state/lattice-data-gate/reads-<date>.jsonl. That path never blocks,
# never prints, and is bounded to two seconds. LATTICE_DATA_GATE_READS=off
# turns it off.
#
# Time limit: the policy gets LATTICE_DATA_GATE_TIMEOUT seconds (1-7, default
# 6), so the read log and the decision fit the hooks' 10-second budget.
#
# Exit/output contract:
#   ALLOW - exit 0, no output.
#   DENY (a rule in enforce) - exit 2 and the refusal on stderr; --harness grok
#     also gets {"decision":"deny","reason":...} on stdout. Claude needs stdout empty.
#   TIMEOUT - the policy did not answer within the time limit. When a rule in
#     enforce would have checked the call (the prefilter matched it), DENY with
#     the timeout refusal, so a slow check never silently allows; otherwise
#     allow. Either way append an error record with "timeout":true.
#   INTERNAL ERROR - allow (exit 0, no output) and append an error record.
set -u

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
POLICY="$HERE/fm-data-gate-policy.mjs"
STATE_DIR="${HOME:-/}/.local/state/lattice-data-gate"
MODE_FILE="${HOME:-/}/.config/lattice-data-gate/mode"
LOG="$STATE_DIR/decisions.jsonl"
SCAN_WORDS='(^|[^A-Za-z0-9_])(grep|egrep|fgrep|rg|ugrep|ug|ag|find|du|tree|ls|glob)([^A-Za-z0-9_]|$)'
# What the size rule can see as a whole-file read: the policy's READERS, python
# and a < redirect. head and tail are bounded and never need Node.
READ_WORDS='(^|[^A-Za-z0-9_])(cat|tac|nl|less|more|bat|awk|gawk|mawk|sed|wc|sort|uniq|cut|paste|jq|diff|cmp|strings|base64|sha(1|224|256|384|512)sum|md5sum|b2sum|cksum|xxd|od|hexdump|g?zcat|xzcat|bzcat|zstdcat|gzip|gunzip|xz|zstd|bzip2|dd|python[0-9.]*)([^A-Za-z0-9_]|$)|<'
DEFAULT_SIZE_LIMIT=209715200
READS="$HERE/fm-data-gate-reads.mjs"
# What the read log records: every reader, bounded or not, and the Read tool.
LOG_READ_WORDS='(^|[^A-Za-z0-9_])(cat|tac|head|tail|less|more|nl|wc|uniq|cut|sort|bat|md5sum|sha1sum|sha256sum|zcat|xxd|od|strings|diff|cmp|grep|egrep|fgrep|rg|ugrep|ag|sed|awk|jq|python[0-9.]*)([^A-Za-z0-9_]|$)|[^<]<[^<(&]|"tool_name" *: *"Read"'

usage() {
  sed -n '2,/^set -u/p' "$0" | sed 's/^# \{0,1\}//; /^set -u/d'
}

# The second word of the mode file's first line whose first word is $1.
mode_file_value() {
  local key value
  [ -r "$MODE_FILE" ] || return 0
  while read -r key value _ || [ -n "$key" ]; do
    if [ "$key" = "$1" ]; then
      printf '%s' "$value"
      return 0
    fi
  done <"$MODE_FILE"
}

gate_mode() {  # [scan|size]
  local mode
  if [ "${1:-scan}" = size ]; then
    mode="${LATTICE_DATA_GATE_SIZE:-}"
    [ -n "$mode" ] || mode=$(mode_file_value size)
    [ -n "$mode" ] || mode=enforce
  else
    mode="${LATTICE_DATA_GATE:-}"
    if [ -z "$mode" ] && [ -r "$MODE_FILE" ]; then
      read -r mode _ <"$MODE_FILE" || true
    fi
  fi
  case "$mode" in
    enforce) printf '%s\n' "$mode" ;;
    *) printf 'log\n' ;;
  esac
}

size_limit() {
  local raw="${LATTICE_DATA_GATE_SIZE_LIMIT:-}" number
  [ -n "$raw" ] || raw=$(mode_file_value size-limit)
  if [[ "$raw" =~ ^([0-9]{1,15})([KkMmGg]?)$ ]]; then
    number=$((10#${BASH_REMATCH[1]}))
    case "${BASH_REMATCH[2]}" in
      K|k) number=$((number * 1024)) ;;
      M|m) number=$((number * 1048576)) ;;
      G|g) number=$((number * 1073741824)) ;;
    esac
    printf '%s\n' "$number"
  else
    printf '%s\n' "$DEFAULT_SIZE_LIMIT"
  fi
}

# Size in bytes of a regular file, nothing for anything else: one stat.
file_size() {
  [ -f "$1" ] || return 0
  stat -c %s -- "$1" 2>/dev/null || stat -f %z -- "$1" 2>/dev/null || true
}

# A read-tool call exits here, allowed and unlogged, when it cannot break the
# size rule: bounded by an offset or limit, no path, not a regular file, or
# within the limit. It returns only when the policy must decide: a relative or
# escaped path, or a file over the limit.
read_fast_path() {  # <path> <bounded 0|1>
  local size
  [ "$2" = 1 ] && exit 0
  [ -n "$1" ] || exit 0
  case "$1" in /*) ;; *) return 0 ;; esac
  size=$(file_size "$1")
  [ -n "$size" ] || exit 0
  [ "$size" -gt "$SIZE_LIMIT" ] || exit 0
}

json_escape() {
  local s=$1
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\n'/\\n}
  s=${s//$'\r'/\\r}
  s=${s//$'\t'/\\t}
  printf '%s' "$s" | tr -d '\000-\010\013\014\016-\037'
}

log_error() {  # <harness> <message> <cmd> [verdict] [extra JSON fields]
  local harness=$1 message=$2 cmd=$3 verdict=${4:-allow} extra=${5:-}
  mkdir -p "$STATE_DIR" 2>/dev/null || return 0
  printf '{"ts":"%s","harness":"%s","cwd":"%s","cmd":"%s","verdict":"%s","would_block":false,"error":"%s"%s}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(json_escape "$harness")" "$(json_escape "$PWD")" \
    "$(json_escape "${cmd:0:4000}")" "$verdict" "$(json_escape "$message")" "$extra" >>"$LOG" 2>/dev/null || true
}

decide_seconds() {
  local raw="${LATTICE_DATA_GATE_TIMEOUT:-}"
  if [[ "$raw" =~ ^[1-7]$ ]]; then printf '%s\n' "$raw"; else printf '6\n'; fi
}

scan_refusal() {  # <tool> <target>
  cat <<EOF
BLOCKED (data gate): recursive $1 over $2 would scan bulk run data.
Use:  lattice-data find --task|--batch|--slice|--entry …   (catalog: ~/lattice-store/catalog.jsonl)
      lattice-data grep <item-id> PATTERN                   (search inside one item)
      ~/lattice-ledger/index.json and runs/<entry_id>.md    (run results)
See skill data-access. Override for a named small folder: search that folder directly.
EOF
}

size_refusal() {  # <tool> <file> <size> <limit>
  cat <<EOF
BLOCKED (data gate): $1 would read all of $2 ($3; the whole-file limit is $4).
Use:  the file's DIGEST.md or its catalog entry first         (lattice-data find …)
      a bounded window: Read with offset and limit, head -c, tail -c, sed -n 'A,Bp;Bq'
      a niced one-off read: nice -n 19 ionice -c3 <command>, recorded in your report
See skill data-access, section "Blocked large read". If none of these fits, ask main.
EOF
}

timeout_refusal() {  # <seconds>
  cat <<EOF
BLOCKED (data gate): the gate's check of this call did not finish within $1 s (the machine is busy), so the call did not run.
Nothing was found against it: retry the same call. If it keeps timing out, run smaller commands or ask main.
EOF
}

# Log-only: never blocks, never prints, bounded, allows on any error.
log_reads() {
  [ "${LATTICE_DATA_GATE_READS:-on}" != off ] || return 0
  command -v node >/dev/null 2>&1 || return 0
  if command -v timeout >/dev/null 2>&1; then
    timeout 2 node "$READS" log --size-limit "$SIZE_LIMIT" "$@" >/dev/null 2>&1 || true
  else
    node "$READS" log --size-limit "$SIZE_LIMIT" "$@" >/dev/null 2>&1 || true
  fi
}

run_policy() {
  if command -v timeout >/dev/null 2>&1; then
    timeout -k 1 "$DECIDE_SECONDS" node "$POLICY" "$@"
  else
    node "$POLICY" "$@"
  fi
}

HARNESS=unknown
CMD=""
CMD_SET=0
TOOL=""
TPATH=""
PATTERN=""
CWD=""
OFFSET=""
LIMIT=""
case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  mode) gate_mode "${2:-scan}"; exit 0 ;;
  size-limit) size_limit; exit 0 ;;
  refresh|roots) exec node "$POLICY" "$1" ;;
esac
while [ "$#" -gt 0 ]; do
  case "$1" in
    --harness) HARNESS=${2:-unknown}; shift 2 ;;
    --command) CMD=${2:-}; CMD_SET=1; shift 2 ;;
    --tool) TOOL=${2:-}; shift 2 ;;
    --path) TPATH=${2:-}; shift 2 ;;
    --pattern) PATTERN=${2:-}; shift 2 ;;
    --cwd) CWD=${2:-}; shift 2 ;;
    --offset) OFFSET=${2:-}; shift 2 ;;
    --limit) LIMIT=${2:-}; shift 2 ;;
    *) shift ;;
  esac
done

MODE=$(gate_mode scan)
SIZE_MODE=$(gate_mode size)
SIZE_LIMIT=$(size_limit)
DECIDE_SECONDS=$(decide_seconds)
# Which rules the prefilter says could apply; a timeout refuses only for these.
SCAN_SHAPED=0
READ_SHAPED=0

args=(decide --harness "$HARNESS" --mode "$MODE" --size-mode "$SIZE_MODE" --size-limit "$SIZE_LIMIT")
[ -n "$CWD" ] && args+=(--cwd "$CWD")
PAYLOAD=""
if [ "$CMD_SET" = 1 ]; then
  ! printf '%s' "$CMD" | grep -qE "$LOG_READ_WORDS" || log_reads --harness "$HARNESS" ${CWD:+--cwd "$CWD"} --command "$CMD"
  ! printf '%s' "$CMD" | grep -qiE "$SCAN_WORDS" || SCAN_SHAPED=1
  ! printf '%s' "$CMD" | grep -qiE "$READ_WORDS" || READ_SHAPED=1
  [ "$SCAN_SHAPED$READ_SHAPED" != 00 ] || exit 0
  args+=(--command "$CMD")
  DESC=$CMD
elif [ "$TOOL" = read ]; then
  [ -n "$TPATH" ] && log_reads --harness "$HARNESS" ${CWD:+--cwd "$CWD"} --tool read --path "$TPATH" ${OFFSET:+--offset "$OFFSET"} ${LIMIT:+--limit "$LIMIT"}
  bounded=0
  [ -n "$OFFSET$LIMIT" ] && bounded=1
  fpath=$TPATH
  case "$fpath" in
    /*|'') ;;
    \~|\~/*) fpath="${HOME:-/}${fpath#\~}" ;;
    \~*) fpath=relative ;;
    *) [ -n "$CWD" ] && fpath="$CWD/$fpath" ;;
  esac
  read_fast_path "$fpath" "$bounded"
  READ_SHAPED=1
  args+=(--tool read --path "$TPATH")
  [ -n "$OFFSET" ] && args+=(--offset "$OFFSET")
  [ -n "$LIMIT" ] && args+=(--limit "$LIMIT")
  DESC="read path=$TPATH"
elif [ -n "$TOOL" ]; then
  SCAN_SHAPED=1
  args+=(--tool "$TOOL")
  [ -n "$TPATH" ] && args+=(--path "$TPATH")
  [ -n "$PATTERN" ] && args+=(--pattern "$PATTERN")
  DESC="$TOOL path=$TPATH pattern=$PATTERN"
else
  [ -t 0 ] && exit 0
  PAYLOAD=$(cat 2>/dev/null || true)
  [ -n "$PAYLOAD" ] || exit 0
  ! printf '%s' "$PAYLOAD" | grep -qE "$LOG_READ_WORDS" || printf '%s' "$PAYLOAD" | log_reads --harness "$HARNESS" --stdin ${CWD:+--cwd "$CWD"}
  if [[ "$PAYLOAD" =~ \"tool_?[Nn]ame\"[[:space:]]*:[[:space:]]*\"[Rr]ead\" ]]; then
    bounded=0
    [[ "$PAYLOAD" =~ \"(offset|limit)\"[[:space:]]*:[[:space:]]*[0-9] ]] && bounded=1
    fpath=""
    if [[ "$PAYLOAD" =~ \"(file_path|filePath|path)\"[[:space:]]*:[[:space:]]*\"([^\"\\]*)(.) ]]; then
      fpath=${BASH_REMATCH[2]}
      # An escaped path is left to the policy's JSON parser.
      [ "${BASH_REMATCH[3]}" = '"' ] || fpath=escaped
    fi
    read_fast_path "$fpath" "$bounded"
    READ_SHAPED=1
  else
    ! printf '%s' "$PAYLOAD" | grep -qiE "$SCAN_WORDS" || SCAN_SHAPED=1
    ! printf '%s' "$PAYLOAD" | grep -qiE "$READ_WORDS" || READ_SHAPED=1
    [ "$SCAN_SHAPED$READ_SHAPED" != 00 ] || exit 0
  fi
  args+=(--stdin)
  DESC=$PAYLOAD
fi

if ! command -v node >/dev/null 2>&1; then
  log_error "$HARNESS" "node not found" "$DESC"
  exit 0
fi
if [ -n "$PAYLOAD" ]; then
  OUT=$(printf '%s' "$PAYLOAD" | run_policy "${args[@]}" 2>&1)
else
  OUT=$(run_policy "${args[@]}" </dev/null 2>&1)
fi
STATUS=$?
case "$STATUS:$OUT" in
  0:allow) exit 0 ;;
  0:block$'\t'scan$'\t'*|0:block$'\t'size$'\t'*) ;;
  124:*|137:*)
    if { [ "$MODE" = enforce ] && [ "$SCAN_SHAPED" = 1 ]; } || { [ "$SIZE_MODE" = enforce ] && [ "$READ_SHAPED" = 1 ]; }; then
      log_error "$HARNESS" "policy timed out after ${DECIDE_SECONDS}s (exit $STATUS)" "$DESC" block ',"timeout":true'
      OUT=timeout
    else
      log_error "$HARNESS" "policy timed out after ${DECIDE_SECONDS}s (exit $STATUS)" "$DESC" allow ',"timeout":true'
      exit 0
    fi
    ;;
  *)
    log_error "$HARNESS" "policy failed (exit $STATUS): ${OUT:0:500}" "$DESC"
    exit 0
    ;;
esac

IFS=$'\t' read -r _ BRULE BTOOL BTARGET BSIZE BLIMIT <<<"$OUT"
if [ "$OUT" = timeout ]; then
  REASON=$(timeout_refusal "$DECIDE_SECONDS")
elif [ "$BRULE" = size ]; then
  [ "$SIZE_MODE" = enforce ] || exit 0
  REASON=$(size_refusal "$BTOOL" "$BTARGET" "$BSIZE" "$BLIMIT")
else
  [ "$MODE" = enforce ] || exit 0
  REASON=$(scan_refusal "$BTOOL" "$BTARGET")
fi
printf '%s\n' "$REASON" >&2
if [ "$HARNESS" = grok ]; then
  printf '{"decision":"deny","reason":"%s"}\n' "$(json_escape "$REASON")"
fi
exit 2
