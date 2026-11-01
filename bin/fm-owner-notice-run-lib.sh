#!/usr/bin/env bash
# Sourced by the owner front and its bounded publication command, after the
# wake library. run --watcher-pid W --attempt TOKEN is watcher-only; runner
# locks, health and shutdown live here. docs/owner-notice.md owns the contract.
# shellcheck source=/dev/null # Already reached via wake -> classify for lint.
. "$SCRIPT_DIR/fm-alert-store-lib.sh"

RUN_CHILD=
RUN_SLEEP=
RUN_START_RECORD=

runner_stop() {
  local end
  # Signal first: do not read a state record before stopping our own child.
  [ -z "$RUN_SLEEP" ] || kill -TERM "$RUN_SLEEP" 2>/dev/null || true
  RUN_SLEEP=
  if [ -n "$RUN_CHILD" ]; then
    kill -TERM "$RUN_CHILD" 2>/dev/null || true
    end=$((SECONDS + 5))
    while kill -0 "$RUN_CHILD" 2>/dev/null && [ "$SECONDS" -lt "$end" ]; do
      sleep 0.1
    done
    kill -KILL "$RUN_CHILD" 2>/dev/null || true
    if ! kill -0 "$RUN_CHILD" 2>/dev/null; then
      wait "$RUN_CHILD" 2>/dev/null || true
    fi
    RUN_CHILD=
  fi
  [ -z "$RUN_START_RECORD" ] || rm -f -- "$RUN_START_RECORD"
}

owner_notice_initialize_store() {  # <store> <id>, same lock as the native CLI
  local code=0
  fm_lock_acquire_wait_max "$1.lock" 10 || return 70
  fm_alert_store_initialize "$1" "$2" || code=70
  fm_lock_release "$1.lock"
  if [ "$code" -ne 0 ]; then printf '%s\n' "$FM_ALERT_PROBLEM" >&2; fi
  return "$code"
}

owner_notice_status_file() {  # Create only genuine absence, never append through an alias.
  if [ ! -e "$1" ] && [ ! -L "$1" ]; then
    # A concurrent creator may win; validate its file below without writing
    # through it. A failed create with no valid winner is still a refusal.
    (set -C; : > "$1") 2>/dev/null || true
  fi
  if [ -L "$1" ] || [ ! -f "$1" ] || [ ! -r "$1" ] || [ ! -w "$1" ]; then
    printf 'owner-notice status path is unreadable or nonregular: %s\n' "$1" >&2
    return 70
  fi
}

# Runtime prerequisites cannot use the SQLite FIFO. Use the same native
# writer/lock as its publisher, on a separate key; never sync the whole store.
# The caller bounds this complete command, including initialization/registration.
owner_notice_runtime_level() {  # <assert|clear> <reason> <watcher-pid> <watcher-start>
  local path="$FM_HOME/state/owner-notices/runner-alert-store.json" directory current='' keys='' code=0 needed=1
  case "$1" in assert|clear) ;; *) return 70 ;; esac
  for directory in "$FM_HOME/state" "$FM_HOME/state/owner-notices"; do
    if [ -L "$directory" ] || [ ! -d "$directory" ] || [ ! -r "$directory" ] || [ ! -w "$directory" ] || [ ! -x "$directory" ]; then
      printf 'owner-notice runtime level directory unavailable: %s\n' "$directory" >&2
      return 70
    fi
  done
  # Healthy first activation has no runtime level to clear. A dangling alias
  # is not absence and must reach the native initializer's refusal.
  if [ "$1" = clear ] && [ ! -e "$path" ] && [ ! -L "$path" ] &&
    [ ! -e "$path.lock" ] && [ ! -L "$path.lock" ]; then return 0; fi
  fm_lock_acquire_wait_max "$path.lock" 10 || return 70
  # Check authority AFTER serialization. A surviving old watcher command must
  # not publish a late assertion after its replacement already cleared it.
  if ! fm_watcher_healthy "$FM_HOME/state" "$SCRIPT_DIR/fm-watch.sh" || [ "$FM_WATCHER_HEALTHY_PID" != "$3" ]; then
    code=70
  elif ! fm_pid_start_time_to current "$3" || [ -z "$4" ] || [ "$current" != "$4" ]; then
    code=70
  fi
  if [ "$code" -eq 0 ]; then
    owner_notice_status_file "$FM_HOME/state/owner-notice-runner.status" || code=70
  fi
  if [ "$code" -eq 0 ]; then fm_alert_store_initialize "$path" owner-notice-runner || code=70; fi
  if [ "$code" -eq 0 ] && [ "$1" = clear ]; then
    if keys=$(fm_alert_store_active_keys "$path"); then
      case $'\n'"$keys"$'\n' in
        *$'\nrunner-runtime-unavailable\n'*) needed=1 ;;
        *) needed=0 ;;
      esac
    else
      code=70
    fi
  fi
  if [ "$code" -eq 0 ] && [ "$needed" -eq 1 ]; then
    # These are the native writer's operations, under its normal store lock.
    case "$1" in
      assert) fm_alert_store_assert "$path" owner-notice-runner runner-runtime-unavailable "$2" || code=70 ;;
      clear) fm_alert_store_clear "$path" owner-notice-runner runner-runtime-unavailable "$2" || code=70 ;;
    esac
  fi
  fm_lock_release "$path.lock"
  if [ "$code" -ne 0 ]; then
    printf 'owner-notice runtime level could not be published: authority or native store unavailable: %s\n' "${FM_ALERT_PROBLEM:-}" >&2
    return "$code"
  fi
  [ "$needed" -eq 1 ] || return 0
  "$SCRIPT_DIR/fm-alert-store.sh" register "$path" owner-notice-runner owner-notice-runner.status owner-notice >/dev/null
}

# Engine-side proof, independent of the public front's checks. The starting
# marker precedes the runner lock; installation cannot precede its ownership.
owner_notice_start_authority() {  # <front-pid> <watcher-pid> <install: 0|1> [loop-watcher-identity]
  local held='' actual='' holder=''
  fm_watcher_healthy "$FM_HOME/state" "$SCRIPT_DIR/fm-watch.sh" || return 70
  [ "$FM_WATCHER_HEALTHY_PID" = "$2" ] || return 70
  if [ "$#" -eq 4 ] && [ "$FM_WATCHER_HEALTHY_IDENTITY" != "$4" ]; then return 70; fi
  if [ "$3" -eq 1 ]; then
    { fm_file_text_to holder "$FM_HOME/state/owner-notices/.runner.lock/pid" && [ "$holder" = "$1" ]; } || return 71
    { fm_file_text_to held "$FM_HOME/state/owner-notices/.runner.lock/pid-start" &&
      fm_pid_start_time_to actual "$1" && [ -n "$held" ] && [ "$held" = "$actual" ]; } || return 71
  fi
}

runner_register() {
  local id path
  for id in owner-notice owner-notice-runner; do
    path=$ALERT_STORE
    [ "$id" != owner-notice-runner ] || path="$ROOT/runner-alert-store.json"
    # Conditional initialization is under the writer lock: a concurrent
    # publisher cannot assert between an absence check and an empty sync.
    owner_notice_initialize_store "$path" "$id" || return 70
    owner_notice_status_file "$FM_HOME/state/$id.status" || return 70
    "$SCRIPT_DIR/fm-alert-store.sh" register "$path" "$id" "$id.status" owner-notice >/dev/null || return 70
  done
}

cmd_run() {
  local watcher='' attempt='' loop lock_wait forced_exit delay line start code=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --watcher-pid)
        [ "$#" -ge 2 ] || die_usage '--watcher-pid requires a value'
        watcher=$2; shift 2 ;;
      --attempt)
        [ "$#" -ge 2 ] || die_usage '--attempt requires a value'
        attempt=$2; shift 2 ;;
      *) die_usage "run needs --watcher-pid W --attempt TOKEN" ;;
    esac
  done
  if [ "$PPID" != "$watcher" ] || ! fm_watcher_healthy "$FM_HOME/state" "$SCRIPT_DIR/fm-watch.sh" \
    || [ "$FM_WATCHER_HEALTHY_PID" != "$watcher" ]; then
    result 70 unknown not-watcher-child || true
    exit 70
  fi
  [ -n "$attempt" ] || die_usage 'run requires a reserved attempt'
  line=$(python3 "$ENGINE" runner-config --home "$FM_HOME") || exit 2
  read -r loop lock_wait forced_exit delay _ <<< "$line"
  case "$forced_exit" in -) ;; *) exit "$forced_exit" ;; esac
  engine start-run --home "$FM_HOME" --pid "$$" --watcher-pid "$watcher" --attempt "$attempt" >/dev/null || exit 70
  fm_pid_start_time_to start "$$" || exit 70
  RUN_START_RECORD="$ROOT/.runner-starting/$$-${start#proc-starttime=}"
  trap 'runner_stop; exit 143' TERM
  trap 'runner_stop; exit 130' INT
  LOCK_WAIT=$lock_wait
  take_lock "$ROOT/.runner.lock" || exit 75
  # shellcheck disable=SC2034 # take_lock in the sourcing front reads this.
  LOCK_WAIT=5
  engine start-run --home "$FM_HOME" --pid "$$" --watcher-pid "$watcher" --attempt "$attempt" --install >/dev/null || exit 70
  RUN_START_RECORD=
  # Registration belongs to the recorded projection child: a broken alert
  # store/status/registration source must not prevent independent binding work.
  FM_OWNER_NOTICE_FRONT_PID=$$ python3 "$ENGINE" runner-loop --home "$FM_HOME" --lock "$ROOT/.runner.lock" \
    --watcher-pid "$watcher" --watcher-identity "$FM_WATCHER_HEALTHY_IDENTITY" &
  RUN_CHILD=$!
  while kill -0 "$RUN_CHILD" 2>/dev/null; do
    sleep "${delay:-$loop}" &
    RUN_SLEEP=$!
    wait "$RUN_SLEEP" || true
    RUN_SLEEP=
    delay=$loop
    if ! fm_watcher_healthy "$FM_HOME/state" "$SCRIPT_DIR/fm-watch.sh" \
      || [ "$FM_WATCHER_HEALTHY_PID" != "$watcher" ]; then
      runner_stop
      exit 0
    fi
  done
  wait "$RUN_CHILD" || code=$?
  RUN_CHILD=
  exit "$code"
}
