#!/usr/bin/env bash
# fm-alert-store.sh - raise, clear and acknowledge alerts in an owned alert
# store, register a store with a home, and run the re-assertion tick.
#
# Usage:
#   fm-alert-store.sh assert <store> <store-id> <key> <reason> [<kind>] [<subject>]
#   fm-alert-store.sh clear <store> <store-id> <key> <reason>
#   fm-alert-store.sh ack <store> <store-id> <key> <seconds> <by> <reason>
#   fm-alert-store.sh register <store> <store-id> <status-name> [<owner>]
#   fm-alert-store.sh unregister <store-id>
#   fm-alert-store.sh tick
#   fm-alert-store.sh --help
#
# docs/alert-store.md owns the store and registration formats, the projection
# rule and the adoption steps. This header owns the commands.
#
# assert, clear and ack are level operations on <store> (an absolute path):
# assert raises <key> once and refreshes it when it is already active, clear
# drops it and any acknowledgement, and ack hides an active key from the status
# projection for 1 to 604800 seconds. Each takes <store>.lock, rewrites the
# store through a temporary file and a rename, and prints one line saying what
# happened.
#
# register writes state/alert-stores/<store-id>.reg in this home, binding the
# store to state/<status-name> (for example tetjet-mate.status); unregister
# removes it and closes every blocker in that status file the store has named,
# with "<key>: alert store <id> unregistered". A tool in another home may write
# or remove the same file itself instead.
#
# tick is the re-assertion step bin/fm-watch.sh runs on its slow-check cadence
# (FM_CHECK_INTERVAL) when state/alert-stores/ holds a registration. For each
# registration it folds the bound status file and appends
#   blocked [key=<key>] [at=<epoch>]: <key>: <reason> (alert store <id>)
# for every wanted key the fold does not hold open as blocked, and
#   resolved [key=<key>] [at=<epoch>]: <key>: cleared in alert store <id>
# (or "acknowledged by <by> until <until>") for every open blocker the store
# names but no longer wants. A key the store has never named is left alone.
# It prints one line per problem (an invalid registration, an unreadable store,
# an acknowledgement it ignores, a missing status file, a failed append) on every tick until the problem is
# gone, and nothing when all is well. Actions, and problems when they change,
# go to state/alert-stores.log in plain language; a quiet tick writes nothing.
#
# Environment: FM_HOME (default: this checkout), FM_STATE_OVERRIDE,
# FM_CONFIG_OVERRIDE. FM_ALERT_STORE_TICK_MARK=1 makes tick end with the line
# "alert-store tick: complete", which bin/fm-watch.sh strips; a watcher tick
# without it did not finish and is reported as a problem.
#
# Exit status: 0 done (tick: even with problems, which it prints), 1 the
# operation failed, 2 usage error.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
REG_DIR="$STATE/alert-stores"
LOG="$STATE/alert-stores.log"
LOCK_SECONDS=10

# shellcheck source=bin/fm-wake-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-wake-lib.sh"
# fm-classify-lib.sh: the status fold, and through it fm-alert-store-lib.sh.
# shellcheck source=bin/fm-classify-lib.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/fm-classify-lib.sh"

usage() {
  sed -n '2,/^set -u$/{ /^set -u$/d; s/^# \{0,1\}//; p; }' "$0"
}

die_usage() {
  printf 'fm-alert-store.sh: %s\n' "$1" >&2
  exit 2
}

fail() {
  printf 'fm-alert-store.sh: %s\n' "$1" >&2
  exit 1
}

log_line() {  # <sentence>
  printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" >> "$LOG" 2>/dev/null || true
}

need_store_path() {  # <store> <store-id>
  case "$1" in /*) ;; *) die_usage "the store path must be absolute: $1" ;; esac
  fm_alert_slug_ok "$2" || die_usage "the store id must be a [A-Za-z0-9._-] slug: $2"
  [ -d "${1%/*}" ] || fail "the store's directory ${1%/*} does not exist"
}

# Run one library write under the store lock.
locked_write() {  # <store> <function> <args...>
  local store=$1 fn=$2 rc=0
  shift 2
  fm_lock_acquire_wait_max "$store.lock" "$LOCK_SECONDS" || fail "store $store is locked by another writer"
  "$fn" "$store" "$@" || rc=$?
  fm_lock_release "$store.lock"
  [ "$rc" -eq 0 ] || fail "$FM_ALERT_PROBLEM"
}

cmd_assert() {
  [ "$#" -ge 4 ] && [ "$#" -le 6 ] || die_usage "assert needs <store> <store-id> <key> <reason> [<kind>] [<subject>]"
  need_store_path "$1" "$2"
  locked_write "$1" fm_alert_store_assert "${@:2}"
  printf 'alert %s is active in store %s\n' "$3" "$2"
}

cmd_clear() {
  [ "$#" -eq 4 ] || die_usage "clear needs <store> <store-id> <key> <reason>"
  need_store_path "$1" "$2"
  locked_write "$1" fm_alert_store_clear "${@:2}"
  printf 'alert %s is clear in store %s\n' "$3" "$2"
}

cmd_ack() {
  [ "$#" -eq 6 ] || die_usage "ack needs <store> <store-id> <key> <seconds> <by> <reason>"
  need_store_path "$1" "$2"
  [ -n "$5" ] || die_usage "ack needs a non-empty <by>"
  locked_write "$1" fm_alert_store_ack "$2" "$3" "$5" "$4" "$6"
  printf 'alert %s in store %s is acknowledged for %s seconds\n' "$3" "$2" "$4"
}

cmd_register() {
  local store=$1 id=$2 status=${3:-} owner=${4:-unnamed} reg tmp
  [ "$#" -ge 3 ] && [ "$#" -le 4 ] || die_usage "register needs <store> <store-id> <status-name> [<owner>]"
  need_store_path "$store" "$id"
  case "$status" in
    ''|.*|*/*|*[!A-Za-z0-9._-]*) die_usage "the status name must be a file name in state/, such as tetjet-mate.status" ;;
    *.status) ;;
    *) die_usage "the status name must end in .status" ;;
  esac
  case "$owner" in *$'\n'*) die_usage "the owner must be one line" ;; esac
  mkdir -p "$REG_DIR" || fail "cannot create $REG_DIR"
  reg="$REG_DIR/$id.reg"
  tmp=$(mktemp "$REG_DIR/.$id.reg.XXXXXX") || fail "cannot write in $REG_DIR"
  if ! printf 'schema=%s\nstore=%s\npath=%s\nstatus=%s\nowner=%s\n' \
      "$FM_ALERT_REGISTRATION_SCHEMA" "$id" "$store" "$status" "$owner" > "$tmp" \
    || ! mv -f "$tmp" "$reg"; then
    rm -f "$tmp"
    fail "cannot write $reg"
  fi
  log_line "registered alert store $id ($store) for $status, owner $owner"
  printf 'registered alert store %s for %s\n' "$id" "$status"
}

cmd_unregister() {
  local reg status_file known='' open key verb note resolve closed=0 now
  [ "$#" -eq 1 ] || die_usage "unregister needs <store-id>"
  fm_alert_slug_ok "$1" || die_usage "the store id must be a [A-Za-z0-9._-] slug: $1"
  reg="$REG_DIR/$1.reg"
  if [ ! -e "$reg" ] && [ ! -L "$reg" ]; then
    printf 'alert store %s is not registered\n' "$1"
    return 0
  fi
  # Hold the tick lock so no tick re-posts a key between the close and the removal.
  fm_lock_acquire_wait_max "$REG_DIR/.tick.lock" "$LOCK_SECONDS" || fail "cannot take $REG_DIR/.tick.lock"
  status_file=''
  if fm_alert_registration_read "$reg"; then
    status_file="$STATE/$FM_ALERT_REG_STATUS"
    known=$(fm_alert_store_known_keys "$FM_ALERT_REG_PATH" 2>/dev/null) || known=''
  fi
  if ! rm -f "$reg"; then
    fm_lock_release "$REG_DIR/.tick.lock"
    fail "cannot remove $reg"
  fi
  log_line "unregistered alert store $1"
  # Close the blockers the store raised, so none outlives its registration.
  # An unreadable store names no keys; its leftovers close by hand.
  if [ -n "$known" ] && [ -f "$status_file" ] && [ ! -L "$status_file" ]; then
    open=$(status_open_decisions_incremental "$status_file")
    resolve=${FM_CLASSIFY_RESOLVE_VERB:-$FM_CLASSIFY_RESOLVE_VERB_DEFAULT}
    now=$(date +%s)
    while IFS=$'\t' read -r key verb note; do
      [ "$verb" = blocked ] || continue
      case $'\n'"$known"$'\n' in *$'\n'"$key"$'\n'*) ;; *) continue ;; esac
      if append_status "$status_file" "$resolve [key=$key] [at=$now]: $key: alert store $1 unregistered"; then
        log_line "closed alert $key in ${status_file##*/}: alert store $1 unregistered"
        closed=$((closed + 1))
      else
        printf 'could not close %s in %s\n' "$key" "$status_file" >&2
      fi
    done <<EOF
$open
EOF
  fi
  fm_lock_release "$REG_DIR/.tick.lock"
  printf 'unregistered alert store %s, closed %s open alert(s)\n' "$1" "$closed"
}

# Append one status line the way fm-worker-status.sh does: stamped, appended,
# then recorded in the fleet ledger when this home keeps one. A plain append is
# deliberate: the watcher must see it as new status and wake on the blocker.
append_status() {  # <status-file> <line>
  local line
  line=$(status_stamp_line "$2")
  printf '%s\n' "$line" >> "$1" 2>/dev/null || return 1
  if [ -e "$CONFIG/fleet-ledger" ]; then
    "$SCRIPT_DIR/fm-fleet-ledger.sh" appended "$CONFIG" "$1" >/dev/null 2>&1 || true
  fi
}

TICK_PROBLEMS=''
problem() {  # <sentence>
  TICK_PROBLEMS="${TICK_PROBLEMS}$1"$'\n'
}

# Bring one registration's status file in line with its store.
tick_registration() {  # <reg-file>
  local reg=$1 status_file open wanted known now key verb note reason ack by until resolve
  if ! fm_alert_registration_read "$reg"; then
    problem "$FM_ALERT_PROBLEM"
    return 0
  fi
  status_file="$STATE/$FM_ALERT_REG_STATUS"
  if [ -L "$status_file" ] || [ ! -f "$status_file" ]; then
    problem "alert store $FM_ALERT_REG_STORE posts to $status_file, which does not exist"
    return 0
  fi
  now=$(date +%s)
  # Readability is checked here, not inside the substitution below, so the
  # reason in FM_ALERT_PROBLEM survives into the problem line.
  if ! fm_alert_store_readable "$FM_ALERT_REG_PATH" \
    || ! wanted=$(fm_alert_store_wanted "$FM_ALERT_REG_PATH" "$now"); then
    problem "alert store $FM_ALERT_REG_STORE: $FM_ALERT_PROBLEM; its alerts are held open until it reads again"
    return 0
  fi
  known=$(fm_alert_store_known_keys "$FM_ALERT_REG_PATH") || known=''
  while IFS= read -r key; do
    [ -n "$key" ] && problem "alert store $FM_ALERT_REG_STORE: the acknowledgement of $key is ignored, because its at or until does not parse, at is in the future, or until is more than $FM_ALERT_ACK_MAX_SECONDS seconds after at"
  done <<EOF
$(fm_alert_store_bad_acks "$FM_ALERT_REG_PATH" "$now")
EOF
  open=$(status_open_decisions_incremental "$status_file")
  resolve=${FM_CLASSIFY_RESOLVE_VERB:-$FM_CLASSIFY_RESOLVE_VERB_DEFAULT}

  while IFS=$'\t' read -r key reason; do
    [ -n "$key" ] || continue
    case $'\n'"$open" in *$'\n'"$key"$'\t'blocked$'\t'*) continue ;; esac
    reason=${reason:-active in alert store $FM_ALERT_REG_STORE}
    if append_status "$status_file" "blocked [key=$key] [at=$now]: $key: $reason (alert store $FM_ALERT_REG_STORE)"; then
      log_line "re-posted alert $key from store $FM_ALERT_REG_STORE to $FM_ALERT_REG_STATUS"
    else
      problem "alert store $FM_ALERT_REG_STORE could not re-post $key to $status_file"
    fi
  done <<EOF
$wanted
EOF

  while IFS=$'\t' read -r key verb note; do
    [ "$verb" = blocked ] || continue
    case $'\n'"$known"$'\n' in *$'\n'"$key"$'\n'*) ;; *) continue ;; esac
    case $'\n'"$wanted" in *$'\n'"$key"$'\t'*) continue ;; esac
    ack=$(fm_alert_store_ack_of "$FM_ALERT_REG_PATH" "$key" "$now")
    if [ -n "$ack" ]; then
      by=${ack%%$'\t'*}
      until=${ack#*$'\t'}
      note="$key: acknowledged by $by until $until in alert store $FM_ALERT_REG_STORE"
    else
      note="$key: cleared in alert store $FM_ALERT_REG_STORE"
    fi
    if append_status "$status_file" "$resolve [key=$key] [at=$now]: $note"; then
      log_line "closed alert $key in $FM_ALERT_REG_STATUS: ${note#"$key: "}"
    else
      problem "alert store $FM_ALERT_REG_STORE could not close $key in $status_file"
    fi
  done <<EOF
$open
EOF
}

# The last line of a watcher tick (FM_ALERT_STORE_TICK_MARK=1); bin/fm-watch.sh
# matches the same text.
TICK_DONE='alert-store tick: complete'
tick_done() {
  [ "${FM_ALERT_STORE_TICK_MARK:-0}" != 1 ] || printf '%s\n' "$TICK_DONE"
}

cmd_tick() {
  local reg last='' seen="$REG_DIR/.last-problems"
  [ "$#" -eq 0 ] || die_usage "tick takes no arguments"
  [ -d "$REG_DIR" ] || { tick_done; return 0; }
  if ! fm_lock_acquire_wait_max "$REG_DIR/.tick.lock" "$LOCK_SECONDS"; then
    # A tick that cannot run is unknown, not quiet: say so, so the watcher wakes.
    printf 'alert-store tick could not take %s within %ss, so no store was checked\n' "$REG_DIR/.tick.lock" "$LOCK_SECONDS"
    log_line "problem: the tick could not take its lock within ${LOCK_SECONDS}s"
    tick_done
    return 0
  fi
  for reg in "$REG_DIR"/*.reg; do
    [ -e "$reg" ] || [ -L "$reg" ] || continue
    tick_registration "$reg"
  done
  [ -f "$seen" ] && last=$(cat "$seen" 2>/dev/null)
  if [ "$TICK_PROBLEMS" != "${last:+$last$'\n'}" ]; then
    if [ -n "$TICK_PROBLEMS" ]; then
      while IFS= read -r reg; do
        [ -n "$reg" ] && log_line "problem: $reg"
      done <<EOF
$TICK_PROBLEMS
EOF
      printf '%s' "$TICK_PROBLEMS" > "$seen" 2>/dev/null || true
    else
      log_line "every registered alert store reads cleanly again"
      rm -f "$seen"
    fi
  fi
  fm_lock_release "$REG_DIR/.tick.lock"
  printf '%s' "$TICK_PROBLEMS"
  tick_done
}

[ "$#" -ge 1 ] || { usage >&2; exit 2; }
sub=$1
shift
case "$sub" in
  -h|--help|help) usage ;;
  assert) cmd_assert "$@" ;;
  clear) cmd_clear "$@" ;;
  ack) cmd_ack "$@" ;;
  register) cmd_register "$@" ;;
  unregister) cmd_unregister "$@" ;;
  tick) cmd_tick "$@" ;;
  *) die_usage "unknown command '$sub' (see --help)" ;;
esac
