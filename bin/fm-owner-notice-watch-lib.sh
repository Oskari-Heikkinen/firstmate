#!/usr/bin/env bash
# Sourced by fm-watch.sh. Fast tick never reads a producer path and does no
# per-binding work. runner_start_status in fm_owner_notice_runtime.py is the
# single slow-sweep start-history reader, also used by the handoff adapter.
# Requires the watcher's wake/classify libraries and age_of_to.

OWNER_NOTICE_RUNNER_PID=
OWNER_NOTICE_RUNNER_SPAWNED=0
OWNER_NOTICE_TERM_SENT=
OWNER_NOTICE_FORCE_DRAIN=0
OWNER_NOTICE_ATTEMPT=
OWNER_NOTICE_RESPAWN_AFTER=0
OWNER_NOTICE_LOOP=15
OWNER_NOTICE_BOUND=65
OWNER_NOTICE_INITIALIZED=0
OWNER_NOTICE_ALARM_PID=
OWNER_NOTICE_ALARM_START=
OWNER_NOTICE_ALARM_AFTER=0
OWNER_NOTICE_ALARM_PROBLEM=0
OWNER_NOTICE_ALARM_SPAWNED=0
OWNER_NOTICE_ALARM_LIMIT=0
OWNER_NOTICE_ALARM_GRACE=0
OWNER_NOTICE_ALARM_STOP=0
OWNER_NOTICE_ALARM_KILL_AT=0
OWNER_NOTICE_RUNTIME=unchecked
OWNER_NOTICE_RUNTIME_PROBLEM=0
OWNER_NOTICE_RUNTIME_PUBLICATION_PROBLEM=0
OWNER_NOTICE_RECOVERY=unchecked
OWNER_NOTICE_RECOVERY_NEEDS=-

owner_notice_recovery_call() {
  local result='' phase='' needed='' extra=''
  result=$(python3 "$SCRIPT_DIR/fm_owner_notice_store.py" runner-recovery --home "$FM_HOME" "$@") || result='unknown -'
  read -r phase needed extra <<< "$result" || phase=unknown
  case "$phase" in clear|pending|ready) ;; *) phase=unknown ;; esac
  if [ "$result" != "$phase $needed" ] || [ -n "$extra" ]; then phase=unknown; fi
  OWNER_NOTICE_RECOVERY=$phase
  OWNER_NOTICE_RECOVERY_NEEDS=$needed
  if [ "$phase" = unknown ]; then
    owner_notice_alarm assert runner-respawn-failing 'runner recovery record unavailable; repair .runner-recovery without discarding its source history'
    return 1
  fi
}

owner_notice_recovery_load() {
  local keys='' args=()
  if [ -e "$STATE/owner-notices/runner-alert-store.json" ] || [ -L "$STATE/owner-notices/runner-alert-store.json" ]; then
    if keys=$(fm_alert_store_active_keys "$STATE/owner-notices/runner-alert-store.json"); then
      case $'\n'"$keys"$'\n' in *$'\nrunner-respawn-failing\n'*) args=(--held) ;; esac
    else
      args=(--held)  # Unknown ownership is never proof of healthy absence.
    fi
  fi
  owner_notice_recovery_call status ${args[@]+"${args[@]}"}
}

owner_notice_source_failed() {  # <fixed-source> <reason>
  owner_notice_recovery_call fail --source "$1" --reason "$2" || true
  owner_notice_alarm assert runner-respawn-failing "$2"
}

owner_notice_source_repaired() {  # A successful source operation, not health.
  owner_notice_recovery_call repair --source "$1"
}

owner_notice_recovery_finish() {
  owner_notice_recovery_call advance || return 1
  [ "$OWNER_NOTICE_RECOVERY" = ready ] || return 0
  [ "$OWNER_NOTICE_COUNT_VALID" -eq 1 ] || return 1
  # Prove persistence even when the old count is zero. A write refusal
  # invalidates proof; its successful retry must get later work, rather than
  # this function treating the old readiness as authority.
  owner_notice_write_count 0 0 || return 1
  OWNER_NOTICE_COUNT=0
  owner_notice_alarm clear runner-respawn-failing 'recorded failure sources recovered through later validated work' || return 1
  owner_notice_recovery_call cleared
}

owner_notice_recovery_revalidate() {
  local config=''
  case ",$OWNER_NOTICE_RECOVERY_NEEDS," in
    *,configuration,*)
      config=$(python3 "$SCRIPT_DIR/fm_owner_notice_store.py" runner-config --home "$FM_HOME") || {
        [ -z "$config" ] || printf '%s\n' "$config" >&2
        owner_notice_source_failed configuration 'runner configuration unavailable; inspect owner runtime and watcher.log'
        return 1
      }
      owner_notice_source_repaired configuration || return 1 ;;
  esac
  case ",$OWNER_NOTICE_RECOVERY_NEEDS," in
    *,counter-write,*)
      [ "$OWNER_NOTICE_COUNT_VALID" -eq 1 ] || return 1
      owner_notice_write_count "$OWNER_NOTICE_COUNT" "$OWNER_NOTICE_LAST_CODE" || return 1 ;;
  esac
  owner_notice_recovery_finish
}

owner_notice_runtime_publish() {  # <assert|clear> <accurate runtime diagnosis>
  local start='' code=0
  _fm_wake_require_timeout
  fm_pid_start_time_to start "$$" || code=70
  if [ "$code" -eq 0 ]; then
    # This third, prerequisite key is a native level, never a FIFO request.
    # Synchronous bounded reconciliation means no busy-PID transition drop.
    # fm_exec_timed execs its watchdog: isolate it so reconciliation returns
    # to this same watcher instead of replacing the supervision process.
    # shellcheck disable=SC2016 # Positional arguments belong to the bounded child.
    (fm_exec_timed "${FM_CHECK_TIMEOUT:-30}" 5 bash -c '
      SCRIPT_DIR=$1; FM_HOME=$2; STATE=$2/state
      . "$1/fm-wake-lib.sh"
      . "$1/fm-owner-notice-run-lib.sh"
      owner_notice_runtime_level "$3" "$4" "$5" "$6"
    ' _ "$SCRIPT_DIR" "$FM_HOME" "$1" "$2" "$$" "$start") || code=$?
  fi
  if [ "$code" -ne 0 ]; then
    if [ "$OWNER_NOTICE_RUNTIME_PUBLICATION_PROBLEM" -eq 0 ]; then
      fm_wake_append check owner-notice-runtime-publication "$2; runtime level publication failed (exit $code); inspect the native runner alert store and watcher.log" || return 1
      OWNER_NOTICE_RUNTIME_PUBLICATION_PROBLEM=1
    fi
    return 1
  fi
  if [ "$OWNER_NOTICE_RUNTIME_PUBLICATION_PROBLEM" -eq 1 ]; then
    fm_wake_append check owner-notice-runtime-publication 'owner-notice native runtime level reconciled' || return 1
  fi
  OWNER_NOTICE_RUNTIME_PUBLICATION_PROBLEM=0
}

# Probe once on activation and on each slow sweep, not every fast tick. No
# owner state is read by the probe; an old runtime is not a queue corruption.
owner_notice_runtime_ready() {  # [force-probe: 0|1]
  local code=0 detail='' valid=1
  if [ "${1:-0}" -eq 0 ] && [ "$OWNER_NOTICE_RUNTIME" != unchecked ]; then
    [ "$OWNER_NOTICE_RUNTIME" = ready ]; return $?
  fi
  _fm_wake_require_timeout
  detail=$(
    set -o pipefail
    fm_exec_timed "${FM_CHECK_TIMEOUT:-30}" 5 python3 "$SCRIPT_DIR/fm_owner_notice_runtime.py" --check | {
      # Bound the stream BEFORE command substitution can strip NULs/newlines.
      # read succeeds only on a NUL or the cap, neither of which is a verdict.
      raw=''
      if IFS= read -r -d '' -n 1024 raw; then exit 76; fi
      case "$raw" in *$'\n') raw=${raw%$'\n'} ;; *) exit 76 ;; esac
      case "$raw" in *$'\n'*|*$'\r'*) exit 76 ;; esac
      printf '%s' "$raw"
    }
  ) || code=$?
  if [ "$code" -eq 0 ] && [ "$detail" = ready ]; then
    OWNER_NOTICE_RUNTIME=ready
    # Reconcile on forced/slow probes, even after replacement. A healthy cold
    # admission must not wait for the native writer; its first slow sweep will
    # clear an earlier runtime level. Unsupported activation still asserts.
    if [ "${1:-0}" -eq 1 ] && owner_notice_runtime_publish clear 'owner-notice owner runtime recovered; automation checks resumed'; then
      if [ "$OWNER_NOTICE_RUNTIME_PROBLEM" -eq 1 ]; then
        fm_wake_append check owner-notice-runtime 'owner-notice owner runtime recovered; automation checks resumed' || return 1
      fi
      OWNER_NOTICE_RUNTIME_PROBLEM=0
    fi
    return 0
  fi
  OWNER_NOTICE_RUNTIME=unavailable
  case "$detail" in
    'owner-notice unsupported runtime: Python '*) ;;
    *) valid=0 ;;
  esac
  case "$detail" in *$'\n'*|*$'\r'*) valid=0 ;; esac
  [ "${#detail}" -le 512 ] && [ "$code" -eq 78 ] || valid=0
  if [ "$valid" -eq 0 ]; then
    detail='owner-notice runtime check failed (interpreter version unavailable); require Python 3.11+ with SQLite Connection.setlimit/getlimit; inspect watcher.log'
  fi
  owner_notice_runtime_publish assert "$detail" || return 1
  OWNER_NOTICE_RUNTIME_PROBLEM=1
  return 1
}

owner_notice_wanted() {
  [ "$OWNER_NOTICE_FORCE_DRAIN" -eq 0 ] || return 0
  local path
  for path in "$STATE/owner-notices/.bindings.list" "$STATE/owner-notices/.retired.list"; do
    # Test the link before any following test. Invalid routing is work for the
    # bounded runner's diagnostic path, never a healthy empty routing set.
    if [ -L "$path" ] || [ -e "$path" ]; then
      { [ ! -L "$path" ] && [ -f "$path" ] && [ -r "$path" ]; } || return 0
      [ ! -s "$path" ] || return 0
    fi
  done
  return 1
}

owner_notice_alarm_failed() {
  # Re-probe on an actual failure, including an interpreter replaced between
  # slow sweeps. A runtime outage must never acquire a queue/store diagnosis.
  owner_notice_runtime_ready 1 || return 0
  if [ "$OWNER_NOTICE_ALARM_PROBLEM" -eq 0 ]; then
    fm_wake_append check owner-notice-runner 'owner-notice runner alarm publication failed; inspect owner-notices/watcher.log for its runtime, metadata or writer cause' || return 1
    OWNER_NOTICE_ALARM_PROBLEM=1
  fi
}

owner_notice_alarm_pump() {  # [force-probe: 0|1], slow sweep repairs stale hints
  local code=0 observed='' result='' outcome='' limit='' grace='' extra='' number='' prefix=(nice -n 19)
  if [ -n "$OWNER_NOTICE_ALARM_PID" ]; then
    fm_pid_start_time_to observed "$OWNER_NOTICE_ALARM_PID" || observed=''
    if [ -n "$OWNER_NOTICE_ALARM_START" ] && [ "$observed" = "$OWNER_NOTICE_ALARM_START" ]; then
      if [ "$OWNER_NOTICE_ALARM_STOP" -eq 0 ] && [ "$((SECONDS - OWNER_NOTICE_ALARM_SPAWNED))" -gt "$OWNER_NOTICE_ALARM_LIMIT" ]; then
        kill -TERM "$OWNER_NOTICE_ALARM_PID" 2>/dev/null || true
        OWNER_NOTICE_ALARM_STOP=1
        OWNER_NOTICE_ALARM_KILL_AT=$((SECONDS + OWNER_NOTICE_ALARM_GRACE))
        owner_notice_alarm_failed
      elif [ "$OWNER_NOTICE_ALARM_STOP" -eq 1 ] && [ "$SECONDS" -ge "$OWNER_NOTICE_ALARM_KILL_AT" ]; then
        kill -KILL "$OWNER_NOTICE_ALARM_PID" 2>/dev/null || true
        OWNER_NOTICE_ALARM_STOP=2
      fi
      return 0
    fi
    if [ -z "$observed" ] && ! kill -0 "$OWNER_NOTICE_ALARM_PID" 2>/dev/null; then
      wait "$OWNER_NOTICE_ALARM_PID" 2>/dev/null || code=$?
    else
      code=70  # Unknown/reused PID is not permission to wait for another process.
    fi
    OWNER_NOTICE_ALARM_PID=
    OWNER_NOTICE_ALARM_START=
    case "$code" in
      0) OWNER_NOTICE_ALARM_PROBLEM=0 ;;
      75) OWNER_NOTICE_ALARM_AFTER=$((SECONDS + OWNER_NOTICE_LOOP)) ;;
      *) owner_notice_alarm_failed; OWNER_NOTICE_ALARM_AFTER=$((SECONDS + CHECK_INTERVAL)) ;;
    esac
  fi
  [ "$SECONDS" -ge "$OWNER_NOTICE_ALARM_AFTER" ] || return 0
  if [ ! -e "$STATE/owner-notices/.runner-alarms.pending" ] && [ ! -L "$STATE/owner-notices/.runner-alarms.pending" ]; then
    [ "${1:-0}" -eq 1 ] || return 0
    { [ -e "$STATE/owner-notices/.runner-alarms.sqlite3" ] || [ -L "$STATE/owner-notices/.runner-alarms.sqlite3" ]; } || return 0
  fi
  owner_notice_runtime_ready || return 0
  if [ -L "$STATE/owner-notices/watcher.log" ] ||
    { [ -e "$STATE/owner-notices/watcher.log" ] && { [ ! -f "$STATE/owner-notices/watcher.log" ] || [ ! -w "$STATE/owner-notices/watcher.log" ]; }; }; then
    owner_notice_alarm_failed
    OWNER_NOTICE_ALARM_AFTER=$((SECONDS + CHECK_INTERVAL))
    return 1
  fi
  # Only this watcher mutates the queue. Result consumption uses the lease,
  # but admission never waits on a publisher or its metadata read snapshot.
  result=$(python3 "$SCRIPT_DIR/fm_owner_notice_alarm.py" --home "$FM_HOME" advance) || code=$?
  case "$code" in
    0) ;;
    75) OWNER_NOTICE_ALARM_AFTER=$((SECONDS + OWNER_NOTICE_LOOP)); return 0 ;;
    *) owner_notice_alarm_failed; OWNER_NOTICE_ALARM_AFTER=$((SECONDS + CHECK_INTERVAL)); return 1 ;;
  esac
  read -r outcome limit grace extra <<< "$result" || outcome=unknown
  if [ "$result" != "$outcome $limit $grace" ] || [ -n "$extra" ]; then outcome=unknown; fi
  for number in "$limit" "$grace"; do
    case "$number" in ''|*[!0-9]*) outcome=unknown ;; esac
  done
  if [ "${#limit}" -gt 8 ] || [ "${#grace}" -gt 8 ]; then outcome=unknown; fi
  case "$outcome" in
    idle|pending)
      OWNER_NOTICE_ALARM_LIMIT=$((10#$limit)); OWNER_NOTICE_ALARM_GRACE=$((10#$grace))
      if [ "$OWNER_NOTICE_ALARM_LIMIT" -lt 1 ] || [ "$OWNER_NOTICE_ALARM_GRACE" -lt 1 ]; then outcome=unknown; fi ;;
    *) outcome=unknown ;;
  esac
  if [ "$outcome" = idle ]; then OWNER_NOTICE_ALARM_PROBLEM=0; return 0; fi
  if [ "$outcome" = unknown ]; then
    owner_notice_alarm_failed
    OWNER_NOTICE_ALARM_AFTER=$((SECONDS + CHECK_INTERVAL))
    return 1
  fi
  # One oldest request per dispatch. The inherited lease also covers an older
  # watcher's surviving writer descendants.
  if command -v ionice >/dev/null 2>&1; then prefix+=(ionice -c3); fi
  "${prefix[@]}" python3 "$SCRIPT_DIR/fm_owner_notice_alarm.py" --home "$FM_HOME" dispatch \
    </dev/null &
  OWNER_NOTICE_ALARM_PID=$!
  OWNER_NOTICE_ALARM_SPAWNED=$SECONDS
  OWNER_NOTICE_ALARM_STOP=0
  fm_pid_start_time_to OWNER_NOTICE_ALARM_START "$OWNER_NOTICE_ALARM_PID" || OWNER_NOTICE_ALARM_START=''
}

owner_notice_alarm() {  # <assert|clear> <key> <reason>
  owner_notice_runtime_ready || return 1
  if ! python3 "$SCRIPT_DIR/fm_owner_notice_alarm.py" --home "$FM_HOME" enqueue "$@"; then
    owner_notice_alarm_failed
    return 1
  fi
  owner_notice_alarm_pump
}

owner_notice_count() {
  OWNER_NOTICE_COUNT_VALID=1
  OWNER_NOTICE_COUNT=0
  OWNER_NOTICE_LAST_CODE=0
  local path="$STATE/owner-notices/.runner-respawns" row='' valid=1
  if [ -L "$path" ] || [ -e "$path" ]; then
    if [ ! -L "$path" ] && [ -f "$path" ] && [ -r "$path" ]; then
      # EOF is the only success shape: a NUL delimiter or the byte/character
      # cap ends read successfully and is refused. Keep the final newline.
      if IFS= read -r -d '' -n 64 row < "$path"; then valid=0; fi
      case "$row" in *$'\n') row=${row%$'\n'} ;; *) valid=0 ;; esac
      case "$row" in *$'\n'*) valid=0 ;; esac
      read -r OWNER_NOTICE_COUNT OWNER_NOTICE_LAST_CODE <<< "$row" || valid=0
    else
      valid=0
    fi
    case "$OWNER_NOTICE_COUNT" in ''|*[!0-9]*) valid=0 ;; esac
    case "$OWNER_NOTICE_LAST_CODE" in ''|*[!0-9]*) valid=0 ;; esac
    [ "${#OWNER_NOTICE_COUNT}" -le 9 ] && [ "${#OWNER_NOTICE_LAST_CODE}" -le 3 ] || valid=0
    if [ "$valid" -eq 1 ]; then
      OWNER_NOTICE_COUNT=$((10#$OWNER_NOTICE_COUNT))
      OWNER_NOTICE_LAST_CODE=$((10#$OWNER_NOTICE_LAST_CODE))
      [ "$OWNER_NOTICE_LAST_CODE" -le 255 ] || valid=0
    fi
    if [ "$valid" -eq 0 ]; then
      OWNER_NOTICE_COUNT_VALID=0
      OWNER_NOTICE_COUNT=3; OWNER_NOTICE_LAST_CODE=70
      owner_notice_source_failed counter-read 'runner respawn history unreadable; repair .runner-respawns'
    fi
  fi
  if [ "$OWNER_NOTICE_COUNT_VALID" -eq 1 ]; then owner_notice_source_repaired counter-read || true; fi
}

owner_notice_backoff() {
  local n=$OWNER_NOTICE_COUNT
  OWNER_NOTICE_DELAY=$OWNER_NOTICE_LOOP
  while [ "$n" -gt 0 ] && [ "$OWNER_NOTICE_DELAY" -lt "$CHECK_INTERVAL" ]; do
    OWNER_NOTICE_DELAY=$((OWNER_NOTICE_DELAY * 2))
    n=$((n - 1))
  done
  [ "$OWNER_NOTICE_DELAY" -le "$CHECK_INTERVAL" ] || OWNER_NOTICE_DELAY=$CHECK_INTERVAL
}

owner_notice_write_count() {
  if python3 "$SCRIPT_DIR/fm_owner_notice_store.py" runner-count --home "$FM_HOME" \
    --count "$1" --code "$2" >/dev/null; then
    owner_notice_source_repaired counter-write
    return $?
  fi
  owner_notice_source_failed counter-write 'cannot persist runner failure history; repair .runner-respawns'
  return 1
}

owner_notice_runner_exited() {  # <code>
  local progress count old
  # Any refused bookkeeping must leave a retry deadline, not a fast-tick
  # respawn loop. Validated progress/count handling below may replace it.
  OWNER_NOTICE_RESPAWN_AFTER=$((SECONDS + CHECK_INTERVAL))
  owner_notice_count
  old=$OWNER_NOTICE_COUNT
  if [ "$OWNER_NOTICE_COUNT_VALID" -eq 0 ]; then
    return 1  # Unknown failure history is not overwritten by a guessed count.
  fi
  progress=$(python3 "$SCRIPT_DIR/fm_owner_notice_store.py" runner-progress --home "$FM_HOME" \
    --attempt "$OWNER_NOTICE_ATTEMPT" --pid "$OWNER_NOTICE_RUNNER_PID") || progress=no
  if [ "$progress" = yes ]; then
    owner_notice_recovery_call advance || true
    case "$OWNER_NOTICE_RECOVERY" in clear|ready) OWNER_NOTICE_COUNT=0 ;; esac
  else
    OWNER_NOTICE_COUNT=$((OWNER_NOTICE_COUNT + 1))
  fi
  count=$OWNER_NOTICE_COUNT
  if [ "$count" -ne 0 ] || [ "$old" -ne 0 ]; then
    owner_notice_write_count "$count" "$1" || return 1
  fi
  if [ "$count" -gt 0 ]; then
    owner_notice_backoff
    OWNER_NOTICE_RESPAWN_AFTER=$((SECONDS + OWNER_NOTICE_DELAY))
  else
    OWNER_NOTICE_RESPAWN_AFTER=$SECONDS
  fi
  if [ "$count" -ge 3 ]; then
    owner_notice_source_failed failed-start "runner failed before its first beat $count times; last exit $1; inspect owner-notices/log"
  fi
  owner_notice_recovery_finish
}

owner_notice_runner_detached() {
  local code=0 config age remaining final
  if [ -n "$OWNER_NOTICE_RUNNER_PID" ]; then
    kill -0 "$OWNER_NOTICE_RUNNER_PID" 2>/dev/null && return 0
    wait "$OWNER_NOTICE_RUNNER_PID" 2>/dev/null || code=$?
    owner_notice_runner_exited "$code"
    if [ "$OWNER_NOTICE_FORCE_DRAIN" -eq 1 ]; then
      final=$(python3 "$SCRIPT_DIR/fm_owner_notice_store.py" runner-health --home "$FM_HOME") || final=unknown
      if [ "$final" = 'drained clear empty' ] && [ "$OWNER_NOTICE_RECOVERY" = clear ]; then OWNER_NOTICE_FORCE_DRAIN=0; fi
    fi
    OWNER_NOTICE_RUNNER_PID=
  fi
  owner_notice_wanted || return 0
  owner_notice_runtime_ready || return 0
  # This gate must precede configuration too: an unsupported runtime never
  # reaches INITIALIZED, but still must not fork on every fast tick.
  [ "$SECONDS" -ge "$OWNER_NOTICE_RESPAWN_AFTER" ] || return 0
  owner_notice_recovery_load || true
  if [ "$OWNER_NOTICE_INITIALIZED" -eq 0 ]; then
    config=$(python3 "$SCRIPT_DIR/fm_owner_notice_store.py" runner-config --home "$FM_HOME") || {
      OWNER_NOTICE_RESPAWN_AFTER=$((SECONDS + CHECK_INTERVAL))
      [ -z "$config" ] || printf '%s\n' "$config" >&2
      owner_notice_source_failed configuration 'runner configuration unavailable; inspect owner runtime and watcher.log'
      return 1
    }
    read -r OWNER_NOTICE_LOOP _ _ _ OWNER_NOTICE_BOUND <<< "$config"
    owner_notice_source_repaired configuration || true
    owner_notice_count
    if [ "$OWNER_NOTICE_COUNT" -gt 0 ]; then
      owner_notice_backoff
      age_of_to age "$STATE/owner-notices/.runner-respawns"
      remaining=$((OWNER_NOTICE_DELAY - age))
      [ "$remaining" -le 0 ] || OWNER_NOTICE_RESPAWN_AFTER=$((SECONDS + remaining))
    fi
    OWNER_NOTICE_INITIALIZED=1
  fi
  [ "$SECONDS" -ge "$OWNER_NOTICE_RESPAWN_AFTER" ] || return 0
  # Reservation is durable BEFORE fork, including the spawn-before-record
  # window and a launching watcher that disappears before seeing the exit.
  OWNER_NOTICE_ATTEMPT=$(python3 "$SCRIPT_DIR/fm_owner_notice_store.py" reserve-run --home "$FM_HOME") || {
    OWNER_NOTICE_RESPAWN_AFTER=$((SECONDS + CHECK_INTERVAL))
    [ -z "$OWNER_NOTICE_ATTEMPT" ] || printf '%s\n' "$OWNER_NOTICE_ATTEMPT" >&2
    owner_notice_source_failed reservation 'attempt reservation failed; inspect owner runtime, start history and watcher.log'
    return 1
  }
  owner_notice_source_repaired reservation || true
  owner_notice_source_repaired failed-start || true
  # Revalidate persistence before the new attempt can publish its first beat.
  # Even zero is not proof that a previously refused write now works.
  case ",$OWNER_NOTICE_RECOVERY_NEEDS," in
    *,counter-write,*)
      if [ "$OWNER_NOTICE_COUNT_VALID" -eq 1 ]; then
        owner_notice_write_count "$OWNER_NOTICE_COUNT" "$OWNER_NOTICE_LAST_CODE" || true
      fi ;;
  esac
  if command -v ionice >/dev/null 2>&1; then
    FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" nice -n 19 ionice -c3 \
      "$SCRIPT_DIR/fm-owner-notice.sh" run --watcher-pid "$$" --attempt "$OWNER_NOTICE_ATTEMPT" \
      </dev/null >> "$STATE/owner-notices/runner.log" 2>&1 &
  else
    FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" nice -n 19 \
      "$SCRIPT_DIR/fm-owner-notice.sh" run --watcher-pid "$$" --attempt "$OWNER_NOTICE_ATTEMPT" \
      </dev/null >> "$STATE/owner-notices/runner.log" 2>&1 &
  fi
  OWNER_NOTICE_RUNNER_PID=$!
  OWNER_NOTICE_RUNNER_SPAWNED=$SECONDS
  OWNER_NOTICE_TERM_SENT=
}

owner_notice_runner_sweep() {
  local health projection demand result extra valid keys keys_ok=1 notice_keys='' notice_ok=1
  local start='' age progress overdue=0 action args=()
  [ -e "$STATE/owner-notices" ] || [ -L "$STATE/owner-notices" ] || return 0
  owner_notice_runtime_ready 1 || return 0
  if [ -n "$OWNER_NOTICE_RUNNER_PID" ] && fm_pid_start_time_to start "$OWNER_NOTICE_RUNNER_PID"; then
    args=(--spawned-pid "$OWNER_NOTICE_RUNNER_PID" --spawned-start "${start#proc-starttime=}" --attempt "$OWNER_NOTICE_ATTEMPT")
  fi
  result=$(python3 "$SCRIPT_DIR/fm_owner_notice_store.py" runner-health --home "$FM_HOME" ${args[@]+"${args[@]}"}) || result='unknown unknown unknown'
  valid=1
  read -r health projection demand extra <<< "$result" || valid=0
  [ "$result" = "$health $projection $demand" ] && [ -z "$extra" ] || valid=0
  case "$health" in fresh|stale|unknown|drained|idle) ;; *) valid=0 ;; esac
  case "$projection" in clear|failed|unknown) ;; *) valid=0 ;; esac
  case "$demand" in work|empty|unknown) ;; *) valid=0 ;; esac
  if { [ "$health" = drained ] || [ "$health" = idle ]; } && [ "$projection:$demand" != clear:empty ]; then valid=0; fi
  if [ "$valid" -eq 0 ]; then health=unknown; projection=unknown; demand=unknown; fi
  keys=''
  if [ -e "$STATE/owner-notices/runner-alert-store.json" ] || [ -L "$STATE/owner-notices/runner-alert-store.json" ]; then
    keys=$(fm_alert_store_active_keys "$STATE/owner-notices/runner-alert-store.json") || { keys=''; keys_ok=0; }
  fi
  owner_notice_recovery_load || true
  owner_notice_count
  owner_notice_recovery_revalidate || true
  # A never-used empty owner may still hold an unfinished U1 projection.
  # Use its owner's reader, never another parser for the alert-store format.
  if [ "$health" = idle ] && { [ -e "$STATE/owner-notices/alert-store.json" ] || [ -L "$STATE/owner-notices/alert-store.json" ]; }; then
    notice_keys=$(fm_alert_store_active_keys "$STATE/owner-notices/alert-store.json") || notice_ok=0
  fi
  OWNER_NOTICE_FORCE_DRAIN=1
  if [ "$health" = drained ] && [ "$OWNER_NOTICE_RECOVERY:$OWNER_NOTICE_COUNT_VALID:$OWNER_NOTICE_COUNT" = clear:1:0 ]; then
    OWNER_NOTICE_FORCE_DRAIN=0
  elif [ "$health" = idle ] && [ "$OWNER_NOTICE_RECOVERY" = clear ] && [ "$keys_ok:$notice_ok:$OWNER_NOTICE_COUNT_VALID:$OWNER_NOTICE_COUNT" = 1:1:1:0 ] &&
    [ -z "$keys" ] && [ -z "$notice_keys" ]; then
    OWNER_NOTICE_FORCE_DRAIN=0
  fi
  # Recovery authority is independent of the aggregate held alarm. A previous
  # projector alarm must neither kill a fresh loop nor mask a later stale one.
  age=$((SECONDS - OWNER_NOTICE_RUNNER_SPAWNED))
  if [ "$health" = stale ] && [ -n "$OWNER_NOTICE_RUNNER_PID" ] && [ -n "$start" ] &&
    [ "$age" -gt "$OWNER_NOTICE_BOUND" ]; then overdue=1; fi
  if [ "$overdue" -eq 1 ] && [ "$OWNER_NOTICE_TERM_SENT" != "$OWNER_NOTICE_RUNNER_PID" ]; then
    kill -TERM "$OWNER_NOTICE_RUNNER_PID" 2>/dev/null || true
    OWNER_NOTICE_TERM_SENT=$OWNER_NOTICE_RUNNER_PID
  fi
  action=assert
  case "$health:$projection:$demand" in
    fresh:clear:work|drained:clear:empty) action=clear ;;
    idle:clear:empty|fresh:clear:empty) action=hold ;;
    stale:clear:empty) [ "$overdue" -eq 1 ] || action=hold ;;
  esac
  if [ "$keys_ok:$notice_ok" != 1:1 ]; then action=assert; fi
  case "$action" in
    clear) owner_notice_alarm clear runner-beat-stale 'loop progress and projection recovered' ;;
    assert) owner_notice_alarm assert runner-beat-stale "loop=$health projection=$projection demand=$demand stores=$keys_ok/$notice_ok; inspect owner-notices start history, root .stall and runner.log" ;;
  esac
  if { [ "$health" = fresh ] || [ "$health" = drained ]; } && [ "$OWNER_NOTICE_COUNT_VALID" -eq 1 ] &&
    { [ "$OWNER_NOTICE_RECOVERY" = clear ] || [ "$OWNER_NOTICE_RECOVERY" = ready ]; }; then
      if [ "$OWNER_NOTICE_COUNT" -gt 0 ] && { [ -n "$OWNER_NOTICE_RUNNER_PID" ] || [ "$health" = drained ]; }; then
        # A start grace is not progress. Only this attempt's actual beat ends
        # its predecessors' failure streak while the new runner stays alive.
        progress=no
        if [ "$OWNER_NOTICE_RECOVERY" = ready ]; then
          progress=yes  # Durable source-recovery proof, not historical health.
        elif [ -n "$OWNER_NOTICE_RUNNER_PID" ]; then
          progress=$(python3 "$SCRIPT_DIR/fm_owner_notice_store.py" runner-progress --home "$FM_HOME" \
            --attempt "$OWNER_NOTICE_ATTEMPT" --pid "$OWNER_NOTICE_RUNNER_PID") || progress=no
        fi
        if [ "$progress" = yes ]; then
          owner_notice_write_count 0 0 || return 1
          OWNER_NOTICE_COUNT=0
        fi
      fi
      owner_notice_recovery_finish || true
  fi
  owner_notice_alarm_pump 1
}
