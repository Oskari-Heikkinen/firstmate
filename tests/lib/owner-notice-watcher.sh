#!/usr/bin/env bash
# Fixture owner of the real watcher library, for bounded automation tests.
# No harness/backend or real home. Its identity is checked by the real front.
set -u
SCRIPT_DIR=$1
STATE=$FM_HOME/state
CHECK_INTERVAL=${FM_CHECK_INTERVAL:-3}
# shellcheck source=/dev/null
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/fm-alert-store-lib.sh"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/fm-owner-notice-watch-lib.sh"
age_of_to() { fm_path_age_to "$1" "$2"; }
if [ "${FM_TEST_ALARM_ONLY:-0}" -eq 1 ]; then
  config=$(python3 "$SCRIPT_DIR/fm_owner_notice_store.py" runner-config --home "$FM_HOME") || exit 1
  # shellcheck disable=SC2034 # The sourced production pump consumes this period.
  read -r OWNER_NOTICE_LOOP _ _ _ _ <<< "$config"
fi
if [ "${FM_TEST_ALARM_TRACE:-0}" -eq 1 ]; then
  kill() { printf '%s\n' "$*" >> "$STATE/.fixture-alarm-signals"; builtin kill "$@"; }
fi
fm_lock_acquire_wait_bounded "$STATE/.watch.lock" 5 || exit 1
trap 'fm_lock_release "$STATE/.watch.lock"' EXIT
trap 'exit 143' TERM
printf '%s\n' "$FM_HOME" > "$STATE/.watch.lock/fm-home"
printf '%s\n' "$SCRIPT_DIR/fm-watch.sh" > "$STATE/.watch.lock/watcher-path"
identity=''
fm_pid_identity_to identity "$$"
printf '%s\n' "$identity" > "$STATE/.watch.lock/pid-identity"
if [ "${FM_TEST_START_ONLY:-0}" -eq 1 ]; then
  # Unsetting removes Bash's special clock behavior. Test mailbox commands
  # now control this shell's retry clock without changing production code.
  unset SECONDS
  SECONDS=0
fi
n=0
last=-999
second=''
first_sweep=1
while :; do
  n=$((n + 1))
  printf '%s\ncycle-start\n' "$n" > "$STATE/.last-watcher-beat"
  if [ ! -e "$STATE/.fixture-alarm-pump-paused" ]; then owner_notice_alarm_pump; fi
  if [ "${FM_TEST_ALARM_TRACE:-0}" -eq 1 ] && [ "$OWNER_NOTICE_ALARM_STOP" -eq 1 ] && [ ! -e "$STATE/.fixture-alarm-term" ]; then
    while IFS= read -r row; do
      case "$row" in SigPnd:*|ShdPnd:*) printf '%s\n' "$row" ;; esac
    done < "/proc/$OWNER_NOTICE_ALARM_PID/status" > "$STATE/.fixture-alarm-term.$$"
    mv "$STATE/.fixture-alarm-term.$$" "$STATE/.fixture-alarm-term"
  fi
  if [ -f "$STATE/.fixture-command" ]; then
    IFS=' ' read -r token verb action key reason < "$STATE/.fixture-command"
    code=0
    case "$verb" in
      enqueue) owner_notice_alarm "$action" "$key" "$reason" || code=$? ;;
      sweep) owner_notice_runner_sweep || code=$? ;;
      runtime-check) owner_notice_runtime_ready 1 || code=$? ;;
      recovery)
        args=()
        case "$action" in
          fail) args=(--source "$key" --reason "$reason") ;;
          repair) args=(--source "$key") ;;
          status) [ "$key" != held ] || args=(--held) ;;
        esac
        python3 "$SCRIPT_DIR/fm_owner_notice_store.py" runner-recovery --home "$FM_HOME" "$action" ${args[@]+"${args[@]}"} > "$STATE/.fixture-recovery-output" || code=$? ;;
      start-proof)
        attempt=$(python3 "$SCRIPT_DIR/fm_owner_notice_store.py" reserve-run --home "$FM_HOME") || exit 2
        bash "$FM_TEST_START_PROOF" "$SCRIPT_DIR" "$$" "$attempt" "$action" > "$STATE/.fixture-start-proof-output" || code=$? ;;
      handoff)
        fm_lock_release "$STATE/.watch.lock"
        rm "$STATE/.fixture-command"
        : > "$STATE/.fixture-handoff.reached"
        IFS= read -r _ < "$STATE/.fixture-handoff" || true
        exit 0 ;;
      advance) python3 "$SCRIPT_DIR/fm_owner_notice_alarm.py" --home "$FM_HOME" advance || code=$? ;;
      queue-only) python3 "$SCRIPT_DIR/fm_owner_notice_alarm.py" --home "$FM_HOME" enqueue "$action" "$key" "$reason" || code=$? ;;
      reserve) python3 "$SCRIPT_DIR/fm_owner_notice_store.py" reserve-run --home "$FM_HOME" > "$STATE/.fixture-reserve-output" || code=$? ;;
      pump-next)
        [ "${FM_TEST_START_ONLY:-0}" -eq 1 ] || exit 2
        [ "$SECONDS" -ge "$OWNER_NOTICE_ALARM_AFTER" ] || SECONDS=$OWNER_NOTICE_ALARM_AFTER ;;
      startup)
        [ "${FM_TEST_START_ONLY:-0}" -eq 1 ] || exit 2
        SECONDS=$action
        owner_notice_runner_detached || code=$?
        printf '%s %s %s\n' "$OWNER_NOTICE_RESPAWN_AFTER" "$OWNER_NOTICE_INITIALIZED" "${OWNER_NOTICE_RUNNER_PID:--}" > "$STATE/.fixture-startup-state" ;;
      *) exit 2 ;;
    esac
    printf '%s\n' "$code" > "$STATE/.fixture-command.$token.code"
    mv "$STATE/.fixture-command" "$STATE/.fixture-command.$token.done"
  fi
  if [ "${FM_TEST_ALARM_ONLY:-0}" -eq 0 ] && [ "${FM_TEST_START_ONLY:-0}" -eq 0 ] && { owner_notice_wanted || [ -n "$OWNER_NOTICE_RUNNER_PID" ]; }; then
    owner_notice_runner_detached || true
  fi
  if [ -f "$STATE/second-run" ] && [ -z "$second" ]; then
    token=$(python3 "$SCRIPT_DIR/fm_owner_notice_store.py" reserve-run --home "$FM_HOME") || exit 1
    "$SCRIPT_DIR/fm-owner-notice.sh" run --watcher-pid "$$" --attempt "$token" > "$STATE/second-run.log" 2>&1 &
    second=$!
    printf '%s\n' "$second" > "$STATE/second-pid"
  fi
  if [ -n "$second" ] && [ ! -f "$STATE/second-exit" ] && ! kill -0 "$second" 2>/dev/null; then
    rc=0
    wait "$second" || rc=$?
    printf '%s\n' "$rc" > "$STATE/second-exit"
  fi
  if [ "$((SECONDS - last))" -ge "$CHECK_INTERVAL" ]; then
    if [ "${FM_TEST_ALARM_ONLY:-0}" -eq 0 ] && [ "${FM_TEST_START_ONLY:-0}" -eq 0 ]; then owner_notice_runner_sweep; fi
    "$SCRIPT_DIR/fm-alert-store.sh" tick >/dev/null
    : > "$STATE/.last-check"
    if [ "$first_sweep" -eq 1 ] && [ -p "$STATE/.fixture-first-sweep" ]; then
      # Test-only observable barrier: finish real alarm publication before
      # examining the first empty-demand sweep, then release via this FIFO.
      while [ -n "$OWNER_NOTICE_ALARM_PID" ]; do
        owner_notice_alarm_pump || true
        [ -z "$OWNER_NOTICE_ALARM_PID" ] || sleep 0.05
      done
      "$SCRIPT_DIR/fm-alert-store.sh" tick >/dev/null
      : > "$STATE/.fixture-first-sweep.reached"
      IFS= read -r _ < "$STATE/.fixture-first-sweep" || true
    fi
    first_sweep=0
    last=$SECONDS
  fi
  sleep 0.2 &
  wait "$!" || true
done
