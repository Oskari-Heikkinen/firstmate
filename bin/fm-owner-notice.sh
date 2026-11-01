#!/usr/bin/env bash
# fm-owner-notice.sh - the owner front of fm-owner-notice/v1: bind a producer
# outbox, ingest its envelopes into owner custody, and consume, acknowledge,
# retire, show and list them.
#
# Usage:
#   fm-owner-notice.sh bind <id> --outbox <path> --producer-actor <actor>
#       --producer-uid <uid> --kinds <kind>[,<kind>...] --max-bytes <n>
#       --consume-bound-seconds <s>
#   fm-owner-notice.sh ingest <id>
#   fm-owner-notice.sh reconcile <id>
#   fm-owner-notice.sh consume <id> <key> [--note <text>]
#   fm-owner-notice.sh ack-refusal <id> <key> --note <text>
#   fm-owner-notice.sh ack-vanished <id> <name> --note <text>
#   fm-owner-notice.sh retire <id>
#   fm-owner-notice.sh purge <id>
#   fm-owner-notice.sh show <id> <key>
#   fm-owner-notice.sh list [--archived] [<id>]
#   fm-owner-notice.sh status
#   fm-owner-notice.sh --help
#
# docs/owner-notice.md owns the protocol, the state layout under
# state/owner-notices/, the lock order and the crash table; this header owns the
# commands. The producer side is bin/fm-owner-notice-client.py.
#
# Each command prints the engine's one JSON line (bin/fm_owner_notice_store.py).
# After committed work, a routing failure preserves that result, then prints a
# named JSON diagnostic on stderr and exits 70 (docs/owner-notice.md Alarms).
# Otherwise it exits with its code: 0 success or idempotent replay, 2 usage, 65 a refusal
# (its code is in the JSON), 69 unavailable (for example not bound), 70 unknown
# or inconsistent state, 75 busy (a lock held past 5 s, the holder named on
# stderr) or an outbox that did not answer within its bound.
#
# ingest stages the outbox with no lock held, in a bounded recorded child, then
# takes <id>/.lock and runs ingest-staged. Every command that takes <id>/.lock
# then runs the announce step under the wake-queue lock: one check wake keyed
# owner-notice:<id>:<key> for each final key not yet announced, consumed or
# queued, the queue fsynced, then the key's .announced marker. Mutating commands
# finish by syncing the owner-notice alert store
# (state/owner-notices/alert-store.json) under its independent projection lock,
# after releasing all mutation locks. When
# the command itself succeeded but a later step failed, stderr says which step
# and the exit is 70.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
export FM_HOME
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

ENGINE="$SCRIPT_DIR/fm_owner_notice_store.py"
ROOT="$FM_HOME/state/owner-notices"
BINDINGS_LOCK="$ROOT/.bindings.lock"
ALERT_STORE="$ROOT/alert-store.json"
LOCK_WAIT=5
HELD_LOCKS=()
SCRATCH=

usage() {
  sed -n '2,/^$/{s/^# \{0,1\}//;p;}' "$0"
}

# result <exit> <state> [<code> [<detail>]]: a front-made result line.
result() {
  jq -nc --argjson exit "$1" --arg state "$2" --arg code "${3:-}" --arg detail "${4:-}" \
    '{exit: $exit, state: $state} + (if $code != "" then {code: $code} else {} end)
      + (if $detail != "" then {detail: $detail} else {} end)'
  return "$1"
}

die_usage() {
  result 2 usage "" "$1"
  exit 2
}

valid_name() {
  case "$1" in
    ''|[!a-z0-9]*|*[!a-z0-9._-]*) return 1 ;;
  esac
  [ "${#1}" -le 128 ]
}

# The test seams are inert outside a test root holding this home; the engine
# applies the same gate to every path it touches.
seam_gate() {
  local root real
  [ -n "${FM_OWNER_NOTICE_FAULT:-}${FM_OWNER_NOTICE_FSYNC_SPY:-}${FM_OWNER_NOTICE_OPEN_COUNT:-}${FM_OWNER_NOTICE_NOW:-}" ] || return 0
  root=${FM_OWNER_NOTICE_TEST_ROOT:-}
  [ -n "$root" ] || die_usage "FM_OWNER_NOTICE_* seams need FM_OWNER_NOTICE_TEST_ROOT"
  root=$(cd -P "$root" 2>/dev/null && pwd -P) || die_usage "FM_OWNER_NOTICE_TEST_ROOT is not a directory"
  [ "$root" != / ] || die_usage "FM_OWNER_NOTICE_TEST_ROOT may not be /"
  # The marker means the environment alone cannot turn a seam on.
  if [ ! -f "$root/.fm-owner-notice-test-root" ] || [ -L "$root/.fm-owner-notice-test-root" ]; then
    die_usage "FM_OWNER_NOTICE_TEST_ROOT has no regular .fm-owner-notice-test-root file"
  fi
  real=$(cd -P "$FM_HOME" 2>/dev/null && pwd -P) || die_usage "FM_HOME is not a directory"
  case "$real/" in
    "$root"/*) ;;
    *) die_usage "seam path outside FM_OWNER_NOTICE_TEST_ROOT: $FM_HOME" ;;
  esac
}

# fault <point>: the front's own FM_OWNER_NOTICE_FAULT points (kill, pause=<fifo>
# or errno=<E>, which fails the step).
fault() {
  local item act rest
  rest=${FM_OWNER_NOTICE_FAULT:-}
  [ -n "$rest" ] || return 0
  while [ -n "$rest" ]; do
    item=${rest%%,*}
    [ "$item" != "$rest" ] && rest=${rest#*,} || rest=
    case "$item" in
      "$1":*) act=${item#"$1":} ;;
      *) continue ;;
    esac
    case "$act" in
      kill) kill -KILL "$$" ;;
      pause=/*)
        printf '%s %s\n' "$1" "$$" >> "${act#pause=}.reached"
        : < "${act#pause=}"
        ;;
      errno=*) printf 'fm-owner-notice: seam %s: %s\n' "$1" "${act#errno=}" >&2; return 1 ;;
    esac
  done
  return 0
}

# The engine runs as this shell's direct child, never inside $(...), so its
# parent pid is the pid every lock taken here records.
engine() {
  python3 "$ENGINE" "$@"
}

release_all() {
  local i
  i=${#HELD_LOCKS[@]}
  while [ "$i" -gt 0 ]; do
    i=$((i - 1))
    fm_lock_release "${HELD_LOCKS[$i]}" || true
  done
  HELD_LOCKS=()
}

on_exit() {
  release_all
  [ -z "$SCRATCH" ] || rm -rf -- "$SCRATCH"
}
trap on_exit EXIT
trap 'exit 143' TERM
trap 'exit 130' INT

take_lock() {  # <lockdir>
  local rc=0 why
  fm_lock_acquire_wait_bounded "$1" "$LOCK_WAIT" || rc=$?
  if [ "$rc" -eq 0 ]; then
    HELD_LOCKS+=("$1")
    return 0
  fi
  fm_lock_wait_failure_to why "$1" "$LOCK_WAIT" "$rc"
  printf 'fm-owner-notice: busy: %s\n' "$why" >&2
  result 75 busy busy "$why" || true
  return 75
}

drop_lock() {  # <lockdir>: release the most recently taken lock
  local last
  last=$((${#HELD_LOCKS[@]} - 1))
  fm_lock_release "$1" || true
  if [ "$last" -ge 0 ] && [ "${HELD_LOCKS[$last]}" = "$1" ]; then
    unset "HELD_LOCKS[$last]"
  fi
}

# A per-run scratch directory named <pid>-<starttime>-<hex>, so the engine's temp
# reaper keeps it exactly while this front lives.
scratch() {
  local line st
  [ -z "$SCRATCH" ] || return 0
  st=
  if { read -r line < "/proc/$$/stat"; } 2>/dev/null; then
    line=${line##*) }
    # shellcheck disable=SC2086 # Split the stat fields after the command name.
    set -- $line
    st=${20:-}
  else
    line=$(LC_ALL=C ps -o lstart= -p "$$" 2>/dev/null) || line=
    # shellcheck disable=SC2086 # Join ps's words with dashes, as the engine does.
    set -- $line
    st=$(IFS=-; printf '%s' "$*")
  fi
  [ -n "$st" ] || st=0
  SCRATCH="$ROOT/.tmp/$$-$st-$(printf '%04x%04x%04x' "$RANDOM" "$RANDOM" "$RANDOM")"
  { mkdir -p "$ROOT/.tmp" && mkdir "$SCRATCH"; } || {
    SCRATCH=
    result 70 unknown scratch-unwritable "$ROOT/.tmp" || true
    return 70
  }
}

json_true() {  # <file> <jq-expression>
  jq -e "$2" "$1" >/dev/null 2>&1
}

require_bound() {  # <id>
  valid_name "$1" || die_usage "binding id must match [a-z0-9][a-z0-9._-]{0,127}: $1"
  if [ ! -d "$ROOT/$1" ] || [ -L "$ROOT/$1" ]; then
    result 69 unavailable not-bound "$ROOT/$1"
    exit 69
  fi
}

# announce <id>: the announce step, with <id>/.lock held.
announce() {
  local id=$1 lock="$ROOT/$1/.lock" out rows queued key kind outcome consumed wkey rc=0
  local marks=() synced=0 need_sync=0
  scratch || return 70
  out="$SCRATCH/announce.json"
  engine announce-list --home "$FM_HOME" --lock "$lock" "$id" > "$out" || return 70
  rows=$(jq -r '.rows[] | [.key, .kind, .outcome, (if .consumed then "1" else "0" end)] | @tsv' "$out") || return 70
  [ -n "$rows" ] || return 0
  take_lock "$FM_WAKE_QUEUE_LOCK" > /dev/null || return 75
  queued=$(fm_wake_queued_keys_locked check)
  while IFS=$'\t' read -r key kind outcome consumed; do
    [ -n "$key" ] || continue
    marks+=("$key")
    [ "$consumed" = 0 ] || continue
    # A key still queued from an earlier pass needs no second row, but its
    # marker must still wait for a queue fsync, so the row it relies on is durable.
    need_sync=1
    wkey="owner-notice:$id:$key"
    case $'\n'"$queued"$'\n' in
      *$'\n'"$wkey"$'\n'*) continue ;;
    esac
    fm_wake_append_locked check "$wkey" "owner-notice: $id/$key $kind $outcome" || { rc=70; break; }
  done <<< "$rows"
  if [ "$rc" -eq 0 ]; then
    fault announce:after-append || rc=70
  fi
  if [ "$rc" -eq 0 ] && [ "$need_sync" -eq 1 ]; then
    engine fsync-file "$FM_WAKE_QUEUE" > /dev/null && synced=1 || rc=70
  fi
  if [ "$rc" -eq 0 ] && [ "${#marks[@]}" -gt 0 ] && { [ "$need_sync" -eq 0 ] || [ "$synced" -eq 1 ]; }; then
    engine mark-announced --home "$FM_HOME" --lock "$lock" "$id" "${marks[@]}" > /dev/null || rc=70
  fi
  drop_lock "$FM_WAKE_QUEUE_LOCK"
  return "$rc"
}

# repair_lists <result-file>: rebuild .bindings.list and .retired.list under the
# bindings lock when a binding-locked command found them stale.
repair_lists() {
  json_true "$1" '(.lists_stale // []) | length > 0' || return 0
  take_lock "$BINDINGS_LOCK" > /dev/null || return 75
  engine lists --home "$FM_HOME" --bindings-lock "$BINDINGS_LOCK" > /dev/null
  local rc=$?
  drop_lock "$BINDINGS_LOCK"
  return "$rc"
}

# sync_alarms: project the engine's wanted levels into the owner-notice alert
# store, under the independent projection lock and no mutation lock. When a source could not be read the
# wanted set is incomplete, so each wanted key is asserted and nothing is
# cleared; the whole-set sync runs only on a complete set.
sync_alarms() {
  local rc=0
  [ "${#HELD_LOCKS[@]}" -eq 0 ] || return 70
  # Serialize snapshot-through-sync, separately from all mutation locks. An
  # older complete snapshot must not clear a newer incomplete snapshot's levels.
  take_lock "$ROOT/.alarm-sync.lock" > /dev/null || return 70
  sync_alarms_held || rc=$?
  drop_lock "$ROOT/.alarm-sync.lock"
  return "$rc"
}

sync_alarms_held() {
  local rows akey kind subject reason
  scratch || return 70
  engine alarms --home "$FM_HOME" --out "$SCRATCH/wanted.json" > "$SCRATCH/alarms.json" || return 70
  fault alarms:after-snapshot || return 70
  if json_true "$SCRATCH/alarms.json" '.complete == true'; then
    "$SCRIPT_DIR/fm-alert-store.sh" sync "$ALERT_STORE" owner-notice "$SCRATCH/wanted.json" \
      "no longer wanted by fm-owner-notice" > /dev/null || return 70
    return 0
  fi
  rows=$(jq -r 'to_entries[] | [.key, .value.kind, .value.subject, .value.reason] | @tsv' \
    "$SCRATCH/wanted.json") || return 70
  while IFS=$'\t' read -r akey kind subject reason; do
    [ -n "$akey" ] || continue
    "$SCRIPT_DIR/fm-alert-store.sh" assert "$ALERT_STORE" owner-notice "$akey" "$reason" "$kind" "$subject" \
      > /dev/null || return 70
  done <<< "$rows"
}

# finish <rc> <result-file> [<step-failures>...]: print the command's result and
# exit, turning a success into 70 when a later step failed.
finish() {
  local rc=$1 file=$2 step
  shift 2
  cat "$file"
  if [ -n "$SCRATCH" ] && [ -f "$SCRATCH/engine.err" ]; then
    cat "$SCRATCH/engine.err" >&2
  fi
  for step in "$@"; do
    printf 'fm-owner-notice: %s failed; run the command again or reconcile\n' "$step" >&2
    [ "$rc" -ne 0 ] || rc=70
  done
  exit "$rc"
}

# locked <id> <step> <engine-args...>: run one binding-locked engine command and
# the announce step, then the list repair and alarm sync.
locked() {
  local id=$1 out rc=0 failed=()
  shift
  require_bound "$id"
  scratch || exit 70
  out="$SCRATCH/result.json"
  take_lock "$ROOT/$id/.lock" || exit 75
  engine "$@" --home "$FM_HOME" --lock "$ROOT/$id/.lock" > "$out" 2> "$SCRATCH/engine.err" || rc=$?
  announce "$id" || failed+=(announce)
  release_all
  repair_lists "$out" || failed+=(list-repair)
  sync_alarms || failed+=(alarm-sync)
  finish "$rc" "$out" ${failed[@]+"${failed[@]}"}
}

cmd_bind() {
  local id=${1:-} out dev ino rc=0 failed=()
  [ "$#" -ge 1 ] || die_usage "bind needs <id> and its options"
  valid_name "$id" || die_usage "binding id must match [a-z0-9][a-z0-9._-]{0,127}: $id"
  shift
  scratch || exit 70
  out="$SCRATCH/result.json"
  # Inspect the outbox with no lock held: only the bounded child touches it.
  engine bind-inspect --home "$FM_HOME" "$id" "$@" > "$SCRATCH/inspect.json" || rc=$?
  if [ "$rc" -ne 0 ]; then
    cat "$SCRATCH/inspect.json"
    exit "$rc"
  fi
  dev=$(jq -r '.outbox_dev // empty' "$SCRATCH/inspect.json") || dev=
  ino=$(jq -r '.outbox_ino // empty' "$SCRATCH/inspect.json") || ino=
  [ -n "$dev" ] && [ -n "$ino" ] || { cat "$SCRATCH/inspect.json"; exit 70; }
  take_lock "$BINDINGS_LOCK" || exit 75
  engine bind --home "$FM_HOME" --lock "$BINDINGS_LOCK" "$id" "$@" --outbox-dev "$dev" --outbox-ino "$ino" \
    > "$out" 2> "$SCRATCH/engine.err" || rc=$?
  release_all
  sync_alarms || failed+=(alarm-sync)
  finish "$rc" "$out" ${failed[@]+"${failed[@]}"}
}

cmd_ingest() {
  local id=${1:-} stage run rc=0 out failed=()
  [ "$#" -eq 1 ] || die_usage "ingest needs <id>"
  require_bound "$id"
  scratch || exit 70
  stage="$SCRATCH/stage.json"
  out="$SCRATCH/result.json"
  # Stage with no lock held: the outbox is only ever read in the bounded child.
  engine fg-stage --home "$FM_HOME" --origin ingest "$id" > "$stage" || rc=$?
  if [ "$rc" -ne 0 ]; then
    cat "$stage"
    exit "$rc"
  fi
  run=$(jq -r '.run // empty' "$stage") || run=
  [ -n "$run" ] || { cat "$stage"; exit 70; }
  take_lock "$ROOT/$id/.lock" || exit 75
  engine ingest-staged --home "$FM_HOME" --lock "$ROOT/$id/.lock" "$id" "$run" > "$out" 2> "$SCRATCH/engine.err" || rc=$?
  announce "$id" || failed+=(announce)
  release_all
  repair_lists "$out" || failed+=(list-repair)
  sync_alarms || failed+=(alarm-sync)
  if ! json_true "$stage" '.state == "staged"'; then
    failed+=("stage ($(jq -r '.state' "$stage"))")
  fi
  finish "$rc" "$out" ${failed[@]+"${failed[@]}"}
}

cmd_retire_or_purge() {  # <retire|purge> <id>
  local what=$1 id=${2:-} out rc=0 failed=()
  [ "$#" -eq 2 ] || die_usage "$what needs <id>"
  require_bound "$id"
  scratch || exit 70
  out="$SCRATCH/result.json"
  take_lock "$BINDINGS_LOCK" || exit 75
  take_lock "$ROOT/$id/.lock" || exit 75
  engine "$what" --home "$FM_HOME" --lock "$ROOT/$id/.lock" --bindings-lock "$BINDINGS_LOCK" "$id" > "$out" 2> "$SCRATCH/engine.err" || rc=$?
  # A refused retire may name an unannounced key; purge leaves nothing to announce.
  if [ "$what" = retire ]; then
    announce "$id" || failed+=(announce)
  fi
  release_all
  repair_lists "$out" || failed+=(list-repair)
  sync_alarms || failed+=(alarm-sync)
  finish "$rc" "$out" ${failed[@]+"${failed[@]}"}
}

[ "$#" -ge 1 ] || die_usage "a command is required"
cmd=$1
shift
case "$cmd" in
  -h|--help|help) usage; exit 0 ;;
esac
seam_gate
case "$cmd" in
  bind) cmd_bind "$@" ;;
  ingest) cmd_ingest "$@" ;;
  reconcile)
    [ "$#" -eq 1 ] || die_usage "reconcile needs <id>"
    locked "$1" reconcile "$1"
    ;;
  consume)
    [ "$#" -ge 2 ] || die_usage "consume needs <id> <key> [--note <text>]"
    locked "$1" consume "$@"
    ;;
  ack-refusal|ack-vanished)
    [ "$#" -ge 2 ] || die_usage "$cmd needs <id> <key-or-name> --note <text>"
    locked "$1" "$cmd" "$@"
    ;;
  retire|purge) cmd_retire_or_purge "$cmd" "$@" ;;
  show)
    [ "$#" -eq 2 ] || die_usage "show needs <id> <key>"
    exec python3 "$ENGINE" show --home "$FM_HOME" "$@"
    ;;
  list) exec python3 "$ENGINE" list --home "$FM_HOME" "$@" ;;
  status)
    [ "$#" -eq 0 ] || die_usage "status takes no arguments"
    exec python3 "$ENGINE" status --home "$FM_HOME"
    ;;
  *) die_usage "unknown command: $cmd" ;;
esac
