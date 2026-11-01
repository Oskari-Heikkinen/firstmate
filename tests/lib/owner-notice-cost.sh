#!/usr/bin/env bash
# Namespace/ns_last_pid measurement used by the lean-supervision harness.
# Called only in the CI fixture's isolated PID namespace, never a live home.
set -eu
SCRIPT_DIR=$1
STATE=$2
# shellcheck source=/dev/null
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/fm-alert-store-lib.sh"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/fm-owner-notice-watch-lib.sh"
# Available to the named per-binding-stat counterfactual, not used by the guard.
stat_mtime() { stat -c %Y "$1"; }
mkdir -p "$STATE/owner-notices"
: > "$STATE/outbox"
for n in 0 1 30; do
  : > "$STATE/owner-notices/.bindings.list"
  i=0
  while [ "$i" -lt "$n" ]; do
    printf 'x%s\t%s\n' "$i" "$STATE/outbox" >> "$STATE/owner-notices/.bindings.list"
    i=$((i + 1))
  done
  OWNER_NOTICE_RUNNER_PID=$$
  # shellcheck disable=SC2034 # Read by the sourced production watcher function.
  [ "$n" -ne 0 ] || OWNER_NOTICE_RUNNER_PID=''
  IFS= read -r before < /proc/sys/kernel/ns_last_pid
  i=0
  while [ "$i" -lt 10 ]; do
    owner_notice_alarm_pump
    owner_notice_runner_detached
    i=$((i + 1))
  done
  IFS= read -r after < /proc/sys/kernel/ns_last_pid
  printf 'quiet bindings=%s forks=%s\n' "$n" "$((after - before))"
  [ "$after" -eq "$before" ] || exit 1
done
for shape in valid invalid; do
  if [ "$shape" = valid ]; then
    printf '%s\n' '{"schema":"fm-alert-store/v1","active":{"held":{}},"acks":{},"events":[]}' > "$STATE/store"
  else
    printf '{}\n' > "$STATE/store"
  fi
  IFS= read -r before < /proc/sys/kernel/ns_last_pid
  rc=0
  fm_alert_store_active_keys "$STATE/store" > "$STATE/keys" || rc=$?
  IFS= read -r after < /proc/sys/kernel/ns_last_pid
  printf 'active-keys shape=%s forks=%s rc=%s\n' "$shape" "$((after - before))" "$rc"
  [ "$((after - before))" -eq 1 ] || exit 1
  if [ "$shape" = valid ]; then
    [ "$rc" -eq 0 ] || exit 1
  else
    [ "$rc" -eq 1 ] && [ -n "$FM_ALERT_PROBLEM" ] || exit 1
  fi
done
