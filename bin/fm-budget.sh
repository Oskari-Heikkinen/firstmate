#!/usr/bin/env bash
# fm-budget.sh - standing budgets: show one, check a request against it,
# record spend in this home's ledger, and open an over-budget gate row.
#
# Usage:
#   fm-budget.sh show <budget-id>
#   fm-budget.sh check <budget-id> --core-hours <N> --disk-bytes <N> --date YYYY-MM-DD \
#     [--request <request-id>] [--spend-file <path>]... [--json]
#   fm-budget.sh spend <budget-id> --request <request-id> --core-hours <N> --disk-bytes <N>
#   fm-budget.sh open-gate <budget-id> --request <request-id> --requester <owner> \
#     --core-hours <N> --disk-bytes <N> --date YYYY-MM-DD \
#     [--spend-file <path>]... [--evidence <text>]... [--run <run-id>]... \
#     [--repo <repo>] [--origin <origin-id>]
#   fm-budget.sh shadow-log <budget-id>
#
# bin/fm-budget-lib.sh owns the budget record (config/budgets/<id>.budget),
# the spend ledger, the shadow log, and the check arithmetic; docs/budgets.md
# describes them. This script never writes a budget record: a budget is
# written once by hand with the quote that approved it, and a record with no
# quote is refused by every command.
#
# `show` prints the validated record. `check` is read-only: it prints whether
# the request's stated cost (core-hours, disk bytes, and the date it runs) is
# inside or over the budget, which cap is exceeded, and each cap's remaining
# amount before the request (`--json` prints one fm-budget-check.v1 object).
# The spend already recorded comes from the `--spend-file` records given, or,
# when none is given, from this home's own ledger; it never reads another
# home's state. It exits 0 for either verdict, so read the verdict, not the
# status.
#
# `spend` appends one request's spend to this home's ledger once; a repeat
# with the same values is a no-op and different values are refused.
#
# `open-gate` runs the same check for an over-budget request and opens its
# gate row: a captain-held task `budget-gate-<budget-id>-<request-id>`
# through bin/fm-captain-hold.sh hold, with a decision packet (question,
# approve and refuse options, the budget's over-budget default as the
# recommendation, `authority: budget.<budget-id>`, the check as evidence, and
# the requester as prerequisite owner) whose default and deadline come from
# the budget record. The default applies only through
# `fm-captain-hold.sh apply-defaults`, logs as `defaulted`, and stays
# reversible. A request inside budget opens nothing, and a gate already open
# with its packet is left as it is.
#
# SHADOW MODE (`shadow: on`, the default for a record without the key): `check`
# and `open-gate` print their verdict, append what would have happened to
# data/budgets/<id>.shadow.jsonl, and open nothing - no task, no packet, no
# ledger write. `shadow-log` prints that log.
#
# FM_CAPTAIN_HOLD_NOW (UTC YYYY-MM-DDTHH:MM:SSZ) overrides the clock, as it does
# for bin/fm-captain-hold.sh.
# Exit status: 0 on success (either verdict), 1 on a refused record, request,
# or write, 2 for bad usage.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

# shellcheck source=bin/fm-wake-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-budget-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-budget-lib.sh"

CAPTAIN_HOLD="$SCRIPT_DIR/fm-captain-hold.sh"
PACKET_TMP=''
LEDGER_LOCK_HELD=''
budget_cleanup() {
  [ -z "$PACKET_TMP" ] || rm -f -- "$PACKET_TMP"
  [ -z "$LEDGER_LOCK_HELD" ] || fm_lock_release "$LEDGER_LOCK_HELD" || true
}
trap budget_cleanup EXIT

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

fail() {
  printf 'fm-budget: %s\n' "$*" >&2
  exit 1
}

validate_slug() {  # <label> <value>
  case "$2" in
    ''|*[!A-Za-z0-9._-]*) fail "$1 must be a non-empty slug: $2" ;;
  esac
}

budget_now() {
  local now=${FM_CAPTAIN_HOLD_NOW:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}
  case "$now" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z) : ;;
    *) fail "FM_CAPTAIN_HOLD_NOW must be a UTC YYYY-MM-DDTHH:MM:SSZ timestamp" ;;
  esac
  printf '%s' "$now"
}

RECORD=''
load_budget() {  # <budget-id>; sets RECORD
  local out
  out=$(fm_budget_load "$CONFIG" "$1" 2>&1) || fail "$out"
  RECORD=$out
}

# Append one shadow record: what <command> would have done, and nothing else.
shadow_append() {  # <budget-id> <command> <request> <verdict> <exceeded> <would> [<task> <default> <deadline-offset>]
  fm_budget_shadow_append "$DATA" "$(budget_now)" "$@" \
    || fail "could not append to the shadow log $(fm_budget_shadow_path "$DATA" "$1")"
}

# Parsed request options, shared by check, spend, and open-gate.
REQ_ID='' REQ_CH='' REQ_DISK='' REQ_DATE='' REQ_JSON=0 REQUESTER='' REPO='' ORIGIN=''
SPEND_FILES=() EVIDENCE=() RUNS=()
parse_request_options() {  # <allowed-option>...; then -- <args>
  local allowed=" " opt
  while [ "$1" != -- ]; do allowed="$allowed$1 "; shift; done
  shift
  while [ "$#" -gt 0 ]; do
    opt=$1
    case "$allowed" in *" $opt "*) : ;; *) usage >&2; exit 2 ;; esac
    case "$opt" in
      --json) REQ_JSON=1; shift; continue ;;
    esac
    [ "$#" -ge 2 ] || { usage >&2; exit 2; }
    case "$opt" in
      --request) REQ_ID=$2 ;;
      --core-hours) REQ_CH=$2 ;;
      --disk-bytes) REQ_DISK=$2 ;;
      --date) REQ_DATE=$2 ;;
      --spend-file) SPEND_FILES+=("$2") ;;
      --requester) REQUESTER=$2 ;;
      --evidence) EVIDENCE+=("$2") ;;
      --run) RUNS+=("$2") ;;
      --repo) REPO=$2 ;;
      --origin) ORIGIN=$2 ;;
    esac
    shift 2
  done
  [ -z "$REQ_ID" ] || validate_slug request-id "$REQ_ID"
}

CHECK_OUT=''
run_check() {  # <budget-id> <json:0|1>
  local out path ledger sources=()
  [ -n "$REQ_CH" ] || fail "--core-hours is required"
  [ -n "$REQ_DISK" ] || fail "--disk-bytes is required"
  [ -n "$REQ_DATE" ] || fail "--date is required"
  # The spend a check counts: the records given, or this home's own ledger.
  if [ "${#SPEND_FILES[@]}" -gt 0 ]; then
    for path in "${SPEND_FILES[@]}"; do
      [ -f "$path" ] || fail "spend file does not exist: $path"
      sources+=("$path")
    done
  else
    ledger=$(fm_budget_ledger_path "$DATA" "$1")
    [ ! -f "$ledger" ] || sources+=("$ledger")
  fi
  out=$(fm_budget_check "$RECORD" "${REQ_ID:--}" "$REQ_CH" "$REQ_DISK" "$REQ_DATE" "$(budget_now)" "$2" \
    "${sources[@]}" 2>&1) || fail "check of budget $1 refused: $out"
  CHECK_OUT=$out
}

check_line() {  # <key>; from a text check
  printf '%s\n' "$CHECK_OUT" | sed -n "s/^$1: //p" | head -1
}

command_show() {
  [ "$#" -eq 1 ] || { usage >&2; exit 2; }
  load_budget "$1"
  printf '%s\n' "$RECORD"
}

command_check() {
  local id=${1:-} verdict exceeded text
  [ "$#" -ge 1 ] || { usage >&2; exit 2; }
  shift
  parse_request_options --request --core-hours --disk-bytes --date --spend-file --json -- "$@"
  load_budget "$id"
  run_check "$id" 0
  text=$CHECK_OUT
  verdict=$(check_line verdict)
  exceeded=$(check_line exceeded)
  if [ "$REQ_JSON" = 1 ]; then
    run_check "$id" 1
  fi
  if [ "$(fm_budget_field "$RECORD" shadow)" = on ]; then
    if [ "$verdict" = inside ]; then
      shadow_append "$id" check "${REQ_ID:--}" "$verdict" "$exceeded" route
    else
      shadow_append "$id" check "${REQ_ID:--}" "$verdict" "$exceeded" open-gate
    fi
  fi
  [ "$REQ_JSON" = 1 ] || CHECK_OUT=$text
  printf '%s\n' "$CHECK_OUT"
}

command_spend() {
  local id=${1:-} ledger line existing
  [ "$#" -ge 1 ] || { usage >&2; exit 2; }
  shift
  parse_request_options --request --core-hours --disk-bytes -- "$@"
  [ -n "$REQ_ID" ] || fail "--request is required"
  load_budget "$id"
  [ -n "$REQ_CH" ] || fail "--core-hours is required"
  [ -n "$REQ_DISK" ] || fail "--disk-bytes is required"
  # The check validates both amounts, so a malformed one is never recorded.
  line=$(fm_budget_check "$RECORD" "$REQ_ID" "$REQ_CH" "$REQ_DISK" "$(fm_budget_field "$RECORD" end-date)" \
    "$(budget_now)" 0 2>&1) || fail "spend for budget $id refused: $line"
  ledger=$(fm_budget_ledger_path "$DATA" "$id")
  (umask 077; mkdir -p "${ledger%/*}") || fail "could not create ${ledger%/*}"
  line=$(perl -MJSON::PP -e '
    my ($schema, $at, $budget, $request, $ch, $disk) = @ARGV;
    print JSON::PP->new->canonical->encode({schema => $schema, at => $at, budget => $budget,
      request => $request, core_hours => $ch, disk_bytes => $disk + 0});
  ' -- "$FM_BUDGET_SPEND_SCHEMA" "$(budget_now)" "$id" "$REQ_ID" "$REQ_CH" "$REQ_DISK") \
    || fail "could not build the spend record"
  fm_lock_acquire_wait "$STATE/.budget-$id.lock" || fail "could not lock the ledger of budget $id"
  LEDGER_LOCK_HELD="$STATE/.budget-$id.lock"
  existing=''
  if [ -f "$ledger" ]; then
    existing=$(perl -MJSON::PP -ne '
      BEGIN { $rid = pop @ARGV; }
      my $r = eval { JSON::PP->new->decode($_) } or next;
      if (($r->{request} // "") eq $rid) { print "$r->{core_hours} $r->{disk_bytes}\n"; last; }
    ' "$ledger" "$REQ_ID")
  fi
  if [ -n "$existing" ]; then
    [ "$existing" = "$REQ_CH $REQ_DISK" ] \
      || fail "request $REQ_ID already records spend $existing in budget $id"
    printf 'spend: %s %s already recorded\n' "$id" "$REQ_ID"
    return 0
  fi
  printf '%s\n' "$line" >> "$ledger" || fail "could not append to the ledger $ledger"
  printf 'spend: %s %s\n' "$id" "$REQ_ID"
}

# The decision packet of one gate row; every field but the evidence and runs
# comes from the budget record and the check.
write_gate_packet() {  # <path> <budget-id> <exceeded>
  local path=$1 id=$2 exceeded=$3 default offset item
  default=$(fm_budget_field "$RECORD" over-budget-default)
  offset=$(fm_budget_field "$RECORD" deadline-offset)
  {
    printf 'question: Request %s exceeds standing budget %s (%s) on %s. Run it over budget?\n' \
      "$REQ_ID" "$id" "$(fm_budget_field "$RECORD" covers)" "$exceeded"
    printf 'option: approve Run request %s over standing budget %s\n' "$REQ_ID" "$id"
    printf 'option: refuse Do not run request %s; it waits for a raised budget or a smaller request\n' "$REQ_ID"
    printf 'recommendation: %s\n' "$default"
    printf 'authority: %s%s\n' "$FM_BUDGET_AUTHORITY_PREFIX" "$id"
    printf 'evidence: core-hours: %s\n' "$(check_line core-hours)"
    printf 'evidence: disk-bytes: %s\n' "$(check_line disk-bytes)"
    printf 'evidence: end-date: %s\n' "$(check_line end-date)"
    printf 'evidence: standing budget %s approved at %s, quote in config/budgets/%s.budget\n' \
      "$id" "$(fm_budget_field "$RECORD" approved-at)" "$id"
    for item in "${EVIDENCE[@]}"; do printf 'evidence: %s\n' "$item"; done
    for item in "${RUNS[@]}"; do printf 'run: %s\n' "$item"; done
    printf 'prerequisite: %s hold request %s until this call is answered or its default applies\n' \
      "$REQUESTER" "$REQ_ID"
    printf 'deadline: %s\n' "$offset"
    printf 'default: %s\n' "$default"
  } > "$path"
}

command_open_gate() {
  local id=${1:-} verdict exceeded task default offset rc show_out hold_args=()
  [ "$#" -ge 1 ] || { usage >&2; exit 2; }
  shift
  parse_request_options --request --requester --core-hours --disk-bytes --date --spend-file \
    --evidence --run --repo --origin -- "$@"
  [ -n "$REQ_ID" ] || fail "--request is required"
  [ -n "$REQUESTER" ] || fail "--requester is required"
  validate_slug requester "$REQUESTER"
  [ -z "$ORIGIN" ] || validate_slug origin-id "$ORIGIN"
  load_budget "$id"
  run_check "$id" 0
  verdict=$(check_line verdict)
  exceeded=$(check_line exceeded)
  task="budget-gate-$id-$REQ_ID"
  default=$(fm_budget_field "$RECORD" over-budget-default)
  offset=$(fm_budget_field "$RECORD" deadline-offset)
  if [ "$(fm_budget_field "$RECORD" shadow)" = on ]; then
    if [ "$verdict" = inside ]; then
      shadow_append "$id" open-gate "$REQ_ID" "$verdict" "$exceeded" no-gate
      printf 'shadow: %s %s is inside budget; no gate would open\n' "$id" "$REQ_ID"
    else
      shadow_append "$id" open-gate "$REQ_ID" "$verdict" "$exceeded" open-gate "$task" "$default" "$offset"
      printf 'shadow: would open gate %s (over on %s; default %s after %s)\n' "$task" "$exceeded" "$default" "$offset"
    fi
    return 0
  fi
  if [ "$verdict" = inside ]; then
    printf 'inside: %s %s; no gate opened\n' "$id" "$REQ_ID"
    return 0
  fi
  # A gate already open with its packet stays as it is, so a retry never
  # restarts the deadline; one interrupted before its packet gets it now.
  rc=0
  "$CAPTAIN_HOLD" open "$task" >/dev/null 2>&1 || rc=$?
  if [ "$rc" -eq 0 ]; then
    show_out=$("$CAPTAIN_HOLD" packet show "$task" 2>/dev/null) || show_out=''
    if [ -n "$show_out" ] && ! printf '%s\n' "$show_out" | head -1 | grep -F 'inactive:' >/dev/null; then
      printf 'gate: %s already open\n' "$task"
      return 0
    fi
  fi
  hold_args=(--title "Over budget $id: request $REQ_ID"
    --reason "request $REQ_ID exceeds standing budget $id on $exceeded; default $default applies after $offset")
  [ -z "$REPO" ] || hold_args+=(--repo "$REPO")
  [ -z "$ORIGIN" ] || hold_args+=(--origin "$ORIGIN")
  "$CAPTAIN_HOLD" hold "$task" "${hold_args[@]}" >/dev/null \
    || fail "could not open the gate row $task"
  PACKET_TMP=$(mktemp "${TMPDIR:-/tmp}/fm-budget-packet.XXXXXX") || fail "could not create a packet file"
  write_gate_packet "$PACKET_TMP" "$id" "$exceeded"
  "$CAPTAIN_HOLD" packet "$task" --packet-file "$PACKET_TMP" >/dev/null \
    || fail "gate row $task is open but its decision packet was refused; rerun open-gate"
  printf 'gate: %s (over on %s; default %s after %s)\n' "$task" "$exceeded" "$default" "$offset"
}

command_shadow_log() {
  local log
  [ "$#" -eq 1 ] || { usage >&2; exit 2; }
  fm_budget_id_valid "$1" || fail "budget id must match [A-Za-z0-9_-]+: $1"
  log=$(fm_budget_shadow_path "$DATA" "$1")
  [ ! -f "$log" ] || cat "$log"
}

case "${1:-}" in
  show) shift; command_show "$@" ;;
  check) shift; command_check "$@" ;;
  spend) shift; command_spend "$@" ;;
  open-gate) shift; command_open_gate "$@" ;;
  shadow-log) shift; command_shadow_log "$@" ;;
  -h|--help) usage ;;
  *) usage >&2; exit 2 ;;
esac
