#!/usr/bin/env bash
# fm-data-gate.sh - user-level PreToolUse data gate for every agent harness.
#
# One harness-neutral entry point that decides whether an agent tool call is a
# recursive scan (grep -r, rg, ugrep, ag, find, du, tree, ls -R, the Grep and
# Glob tools, or any of those over ssh) whose target is, or is an ancestor of,
# a protected root: the bulk store, a Firstmate home root or its data/ root, a
# generated bulk path, the ledger's bulk folders, ~, /, /mnt/c, or ~/.cache.
# bin/fm-data-gate-policy.mjs owns that decision; this wrapper owns the mode,
# the cheap prefilter, the time bound, the error fallback, and the per-harness
# deny rendering. docs/data-gate.md owns the contract.
#
# Usage:
#   <PreToolUse JSON on stdin> | fm-data-gate.sh --harness claude|codex|grok
#   fm-data-gate.sh --harness opencode|pi|omp --command '<cmd>' [--cwd DIR]
#   fm-data-gate.sh --harness H --tool grep|glob [--path P] [--pattern G] [--cwd DIR]
#   fm-data-gate.sh mode      print the effective mode
#   fm-data-gate.sh refresh   rediscover homes and bulk paths into the roots cache
#   fm-data-gate.sh roots     print the effective protected roots and bulk patterns
#
# Mode: LATTICE_DATA_GATE (log|enforce), else the first word of
# ~/.config/lattice-data-gate/mode, else log. An unknown value means log.
#   log     - always allow; scan-shaped calls append one JSONL record
#             {ts, harness, cwd, cmd, verdict, would_block, ...} to
#             ~/.local/state/lattice-data-gate/decisions.jsonl.
#   enforce - refuse a would-block call with the refusal text below; still logs.
#
# Exit/output contract:
#   ALLOW - exit 0, no output.
#   DENY (enforce only) - exit 2 and the refusal on stderr; --harness grok also
#     gets {"decision":"deny","reason":...} on stdout. Claude needs stdout empty.
#   INTERNAL ERROR - allow (exit 0, no output) and append an error record.
set -u

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
POLICY="$HERE/fm-data-gate-policy.mjs"
STATE_DIR="${HOME:-/}/.local/state/lattice-data-gate"
LOG="$STATE_DIR/decisions.jsonl"
SCAN_WORDS='(^|[^A-Za-z0-9_])(grep|egrep|fgrep|rg|ugrep|ug|ag|find|du|tree|ls|glob)([^A-Za-z0-9_]|$)'

usage() {
  sed -n '2,/^set -u/p' "$0" | sed 's/^# \{0,1\}//; /^set -u/d'
}

gate_mode() {
  local mode="${LATTICE_DATA_GATE:-}"
  if [ -z "$mode" ] && [ -r "${HOME:-/}/.config/lattice-data-gate/mode" ]; then
    read -r mode _ <"${HOME:-/}/.config/lattice-data-gate/mode" || true
  fi
  case "$mode" in
    enforce) printf '%s\n' "$mode" ;;
    *) printf 'log\n' ;;
  esac
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

log_error() {
  local harness=$1 message=$2 cmd=$3
  mkdir -p "$STATE_DIR" 2>/dev/null || return 0
  printf '{"ts":"%s","harness":"%s","cwd":"%s","cmd":"%s","verdict":"allow","would_block":false,"error":"%s"}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(json_escape "$harness")" "$(json_escape "$PWD")" \
    "$(json_escape "${cmd:0:4000}")" "$(json_escape "$message")" >>"$LOG" 2>/dev/null || true
}

refusal() {
  cat <<EOF
BLOCKED (data gate): recursive $1 over $2 would scan bulk run data.
Use:  lattice-data find --task|--batch|--slice|--entry …   (catalog: ~/lattice-store/catalog.jsonl)
      lattice-data grep <item-id> PATTERN                   (search inside one item)
      ~/lattice-ledger/index.json and runs/<entry_id>.md    (run results)
See skill data-access. Override for a named small folder: search that folder directly.
EOF
}

run_policy() {
  if command -v timeout >/dev/null 2>&1; then
    timeout 5 node "$POLICY" "$@"
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
case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  mode) gate_mode; exit 0 ;;
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
    *) shift ;;
  esac
done

MODE=$(gate_mode)

args=(decide --harness "$HARNESS" --mode "$MODE")
[ -n "$CWD" ] && args+=(--cwd "$CWD")
PAYLOAD=""
if [ "$CMD_SET" = 1 ]; then
  printf '%s' "$CMD" | grep -qiE "$SCAN_WORDS" || exit 0
  args+=(--command "$CMD")
  DESC=$CMD
elif [ -n "$TOOL" ]; then
  args+=(--tool "$TOOL")
  [ -n "$TPATH" ] && args+=(--path "$TPATH")
  [ -n "$PATTERN" ] && args+=(--pattern "$PATTERN")
  DESC="$TOOL path=$TPATH pattern=$PATTERN"
else
  [ -t 0 ] && exit 0
  PAYLOAD=$(cat 2>/dev/null || true)
  [ -n "$PAYLOAD" ] || exit 0
  printf '%s' "$PAYLOAD" | grep -qiE "$SCAN_WORDS" || exit 0
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
  0:block$'\t'*) ;;
  *)
    log_error "$HARNESS" "policy failed (exit $STATUS): ${OUT:0:500}" "$DESC"
    exit 0
    ;;
esac

[ "$MODE" = enforce ] || exit 0
IFS=$'\t' read -r _ BTOOL BTARGET <<<"$OUT"
REASON=$(refusal "$BTOOL" "$BTARGET")
printf '%s\n' "$REASON" >&2
if [ "$HARNESS" = grok ]; then
  printf '{"decision":"deny","reason":"%s"}\n' "$(json_escape "$REASON")"
fi
exit 2
