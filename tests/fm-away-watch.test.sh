#!/usr/bin/env bash
# The away watchdog (bin/fm-away-watch.sh): the alert that fires from outside
# every agent session when away-mode supervision has stopped.
#
# Each case builds a home, runs `fm-away-watch.sh run` against it, and reads
# what reached the alert channels through the FM_WEDGE_ALARM_EXEC recorder that
# tests/wake-helpers.sh installs (the channel functions live in
# bin/fm-alert-lib.sh, shared with the supervise daemon). The channel comes from
# the home's own config/wedge-alarm, so the cases also pin that the watchdog
# reads the same configuration as the daemon's wedge alarm.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

TMP_ROOT=$(fm_test_tmproot fm-away-watch-tests)
WATCH="$ROOT/bin/fm-away-watch.sh"
SLEEPERS=()

cleanup() {
  local pid
  for pid in ${SLEEPERS[@]+"${SLEEPERS[@]}"}; do
    kill "$pid" 2>/dev/null || true
  done
  fm_test_cleanup
}
trap cleanup EXIT INT TERM

# make_home <name>: an away home with no supervision host configured. The test
# shell owns the session lock, so the lock reads as held by a live process that
# is not a harness (the lock condition stays silent) and the main-session key
# exists for the latch.
make_home() {
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state" "$home/config"
  printf 'herdr\n' > "$home/config/wedge-alarm"
  printf '%s\n' "$$" > "$home/state/.lock"
  printf 'lab-session\n' > "$home/state/.lock-session"
  : > "$home/alerts.log"
  printf '%s\n' "$home"
}

# away <home> [mode]: write the away-posture record the watchdog keys on.
away() {
  {
    printf 'entered_epoch: %s\n' "${3:-1000}"
    [ -z "${2:-}" ] || printf 'mode: %s\n' "$2"
  } > "$1/state/.afk-contract"
}

run_watch() {  # <home> [--now EPOCH] -> output; the recorder logs to <home>/alerts.log
  local home=$1
  shift
  FM_WEDGE_ALARM_LOG="$home/alerts.log" "$WATCH" run --home "$home" "$@" 2>&1
}

alerts() { cat "$1/alerts.log"; }
alert_count() { wc -l < "$1/alerts.log" | tr -d ' '; }

# A host home whose recorded activity ended at <last-epoch>.
host_home() {  # <home> <last-epoch>
  local home=$1 f
  printf 'claude sonnet\n' > "$home/config/supervision-host"
  for f in "$home/state/.lock" "$home/state/.lock-session" "$home/state/.afk-contract"; do
    fm_touch_epoch "$2" "$f"
  done
}

start_sleeper() {
  sleep 600 &
  SLEEPERS+=("$!")
  LAST_SLEEPER=$!
}

engine_identity() {  # <pid>
  # shellcheck disable=SC2016 # expands in the child shell
  FM_STATE_OVERRIDE="$TMP_ROOT" bash -c '. "$1/fm-wake-lib.sh" && . "$1/fm-supervision-engine-lib.sh" && _fm_engine_identity "$2"' \
    _ "$ROOT/bin" "$1"
}

test_silent_when_attended_or_quiet() {
  local home out
  home=$(make_home attended)
  rm -f "$home/state/.lock"
  : > "$home/state/.claude-autoarm-failure-notified"
  out=$(run_watch "$home") || fail "attended run failed: $out"
  assert_equals 0 "$(alert_count "$home")" "an attended home alerted"
  assert_equals '' "$out" "an attended home printed output"
  assert_absent "$home/state/.away-watch-alert" "an attended home wrote the marker"

  away "$home" quiet
  out=$(run_watch "$home") || fail "quiet run failed: $out"
  assert_equals 0 "$(alert_count "$home")" "quiet mode alerted"
  assert_absent "$home/state/.away-watch-alert" "quiet mode wrote the marker"
  pass "the watchdog is silent with no away record and under quiet mode"
}

test_silent_with_live_host() {
  local home now identity
  home=$(make_home live-host)
  away "$home"
  now=$(date +%s)
  host_home "$home" $((now - 7200))
  start_sleeper
  identity=$(engine_identity "$LAST_SLEEPER") || fail "could not read the stand-in host identity"
  printf 'host\t%s\t%s\n' "$LAST_SLEEPER" "$identity" > "$home/state/.supervision-host"
  fm_touch_epoch $((now - 7200)) "$home/state/.supervision-host"
  run_watch "$home" --now "$now" >/dev/null || fail "live-host run failed"
  assert_equals 0 "$(alert_count "$home")" "a live host alerted: $(alerts "$home")"

  # The same record whose process has gone is a dead host.
  kill "$LAST_SLEEPER" 2>/dev/null
  wait "$LAST_SLEEPER" 2>/dev/null
  run_watch "$home" --now "$now" >/dev/null || fail "dead-host run failed"
  assert_equals 1 "$(alert_count "$home")" "a dead host past the threshold did not alert"
  assert_contains "$(alerts "$home")" 'no live supervision host and no main or host activity for 120 minutes' "the dead-host alert did not name the duration"
  pass "a live host keeps the watchdog silent and the same host dead past the threshold alerts"
}

test_host_threshold() {
  local home now out
  home=$(make_home host-threshold)
  away "$home"
  now=$(date +%s)
  host_home "$home" $((now - 600))
  out=$(run_watch "$home" --now "$now") || fail "recent-activity run failed: $out"
  assert_equals 0 "$(alert_count "$home")" "a dead host inside the threshold alerted"
  # The threshold comes from config/away-watch.
  printf 'host_secs=300\n' > "$home/config/away-watch"
  out=$(run_watch "$home" --now "$now") || fail "configured-threshold run failed: $out"
  assert_equals 1 "$(alert_count "$home")" "a configured host threshold was not honored"
  assert_contains "$(alerts "$home")" 'for 10 minutes' "the host alert did not name the duration"
  pass "the host condition waits for its threshold, which config/away-watch sets"
}

test_dead_lock_owner() {
  local home pid out
  home=$(make_home dead-lock)
  away "$home"
  start_sleeper
  pid=$LAST_SLEEPER
  kill "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null
  printf '%s\n' "$pid" > "$home/state/.lock"
  out=$(run_watch "$home") || fail "dead-lock run failed: $out"
  assert_equals 1 "$(alert_count "$home")" "a dead lock owner did not alert"
  assert_contains "$(alerts "$home")" "herdr	" "the alert did not go to the channel config/wedge-alarm names"
  assert_contains "$(alerts "$home")" "the main session's lock owner (pid $pid) is dead" "the alert did not name the dead lock owner"
  assert_contains "$out" "fm-away-watch: the main session's lock owner (pid $pid) is dead" "the run did not print its alert"

  rm -f "$home/state/.lock" "$home/state/.away-watch-alert"
  run_watch "$home" >/dev/null || fail "free-lock run failed"
  assert_contains "$(alerts "$home")" 'no main session holds the session lock' "a free session lock did not alert"
  pass "a dead or missing session-lock owner alerts"
}

seed_latch() {  # <home> <cooldown> <retry-after>
  local home=$1 key
  # shellcheck disable=SC2016 # expands in the child shell
  key=$(FM_HOME="$home" bash -c '. "$1/fm-wake-lib.sh" && . "$1/fm-supervision-engine-lib.sh" \
    && fm_supervision_host_config "$2" claude && fm_supervision_host_health_key "$3"' _ \
    "$ROOT/bin" "$home/config" "$home/state") || fail "could not compute the latch key"
  printf 'key=%s\nerrors=2\ncooldown=%s\nretry_after=%s\n' "$key" "$2" "$3" > "$home/state/.supervision-host-health"
}

test_held_latch() {
  local home now
  home=$(make_home latch)
  away "$home"
  now=$(date +%s)
  # Inside its first cooldown: silent.
  seed_latch "$home" 300 $((now + 200))
  run_watch "$home" --now "$now" >/dev/null || fail "fresh-latch run failed"
  assert_equals 0 "$(alert_count "$home")" "a latch inside its first cooldown alerted: $(alerts "$home")"
  # Its cooldown ended with no probe yet.
  seed_latch "$home" 300 $((now - 10))
  run_watch "$home" --now "$now" >/dev/null || fail "held-latch run failed"
  assert_equals 1 "$(alert_count "$home")" "a latch past its cooldown did not alert"
  assert_contains "$(alerts "$home")" "broken-session latch has held past one cooldown (now 300s" "the latch alert did not name the cooldown"
  # A doubled cooldown is a failed probe, held past one cooldown.
  rm -f "$home/state/.away-watch-alert"
  seed_latch "$home" 600 $((now + 500))
  run_watch "$home" --now "$now" >/dev/null || fail "doubled-latch run failed"
  assert_equals 2 "$(alert_count "$home")" "a doubled latch cooldown did not alert"
  # A latch kept under another main session is not this session's.
  rm -f "$home/state/.away-watch-alert"
  printf 'key=1:2:3|claude|sonnet\nerrors=2\ncooldown=600\nretry_after=1\n' > "$home/state/.supervision-host-health"
  run_watch "$home" --now "$now" >/dev/null || fail "foreign-latch run failed"
  assert_equals 2 "$(alert_count "$home")" "a latch from another main session alerted"
  pass "the broken-session latch alerts once it has held past one cooldown"
}

test_aged_queue_row() {
  local home now
  home=$(make_home queue)
  away "$home"
  now=$(date +%s)
  printf '%s\t1\tcheck\tk1\tpayload\n' $((now - 600)) > "$home/state/.wake-queue"
  run_watch "$home" --now "$now" >/dev/null || fail "young-queue run failed"
  assert_equals 0 "$(alert_count "$home")" "a young queue row alerted"
  printf '%s\t1\tcheck\tk1\tpayload\n%s\t2\tcheck\tk2\tpayload\n' $((now - 4000)) $((now - 60)) > "$home/state/.wake-queue"
  run_watch "$home" --now "$now" >/dev/null || fail "aged-queue run failed"
  assert_equals 1 "$(alert_count "$home")" "an aged queue row did not alert"
  assert_contains "$(alerts "$home")" 'a queued wake has waited 66 minutes unacknowledged' "the queue alert did not name the age"
  assert_not_contains "$(alerts "$home")" 'payload' "the queue alert carried wake content"
  pass "a queued wake unacknowledged past the queue threshold alerts, without its content"
}

test_autoarm_markers_and_rate_limit() {
  local home now out marker
  home=$(make_home autoarm)
  away "$home" '' 4242
  now=$(date +%s)
  : > "$home/state/.claude-autoarm-failure-notified"
  : > "$home/state/.claude-autoarm-failure-alarmed"
  run_watch "$home" --now "$now" >/dev/null || fail "autoarm run failed"
  assert_equals 1 "$(alert_count "$home")" "auto-arm markers did not alert"
  assert_contains "$(alerts "$home")" 'state/.claude-autoarm-failure-notified and state/.claude-autoarm-failure-alarmed' "the alert did not name both markers"
  assert_contains "$(alerts "$home")" 'away supervision stalled in home main: ' "the alert did not name the home"
  assert_contains "$(alerts "$home")" ' - see state/.away-watch-alert' "the alert did not point at the marker"
  assert_not_contains "$(alerts "$home")" "$home" "the alert carried a local path"

  marker="$home/state/.away-watch-alert"
  assert_equals "window	4242" "$(sed -n 1p "$marker")" "the marker did not name the away window"
  assert_contains "$(sed -n 2p "$marker")" "autoarm	$now	$now	1	the Stop hook could not arm supervision" "the marker row is wrong"

  # Inside the hour a held condition stays quiet, and a new one alerts alone.
  out=$(run_watch "$home" --now $((now + 300))) || fail "rerun failed"
  assert_equals 1 "$(alert_count "$home")" "a held condition re-alerted inside the hour"
  assert_equals '' "$out" "a rate-limited run printed output"
  rm -f "$home/state/.lock"
  run_watch "$home" --now $((now + 600)) >/dev/null || fail "new-condition run failed"
  assert_equals 2 "$(alert_count "$home")" "a new condition was held back by another's rate limit"
  assert_not_contains "$(sed -n 2p "$home/alerts.log")" 'Stop hook' "the rate-limited condition rode along with the new one"

  # Once each condition's hour has passed, both alert again in one summary.
  run_watch "$home" --now $((now + 4300)) >/dev/null || fail "re-alert run failed"
  assert_equals 3 "$(alert_count "$home")" "conditions did not re-alert after the hour"
  assert_contains "$(sed -n 3p "$home/alerts.log")" 'Stop hook' "the re-alert missed the auto-arm condition"
  assert_contains "$(sed -n 3p "$home/alerts.log")" 'no main session holds' "the re-alert missed the lock condition"
  assert_contains "$(grep '^autoarm' "$marker")" "autoarm	$now	$((now + 4300))	2	" "the marker did not count the re-alert"

  # A new away window starts a new marker.
  away "$home" '' 5000
  run_watch "$home" --now $((now + 4400)) >/dev/null || fail "new-window run failed"
  assert_equals 4 "$(alert_count "$home")" "a new away window inherited the old rate limit"
  assert_equals "window	5000" "$(sed -n 1p "$marker")" "the marker kept the old window"
  pass "auto-arm markers alert, each condition alerts once an hour, and a new window resets the marker"
}

test_timer_install_and_uninstall() {
  local dir home fakebin out
  dir="$TMP_ROOT/timer"
  home=$(make_home timer-home)
  fakebin="$dir/fakebin"
  mkdir -p "$fakebin" "$dir/xdg"
  cat > "$fakebin/systemctl" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$dir/systemctl.log"
SH
  chmod +x "$fakebin/systemctl"
  out=$(PATH="$fakebin:$PATH" XDG_CONFIG_HOME="$dir/xdg" "$WATCH" install-timer --home "$home" 2>&1) \
    || fail "install-timer failed: $out"
  assert_grep "ExecStart=/usr/bin/env bash $ROOT/bin/fm-away-watch.sh run --home $(cd "$home" && pwd -P)" \
    "$dir/xdg/systemd/user/fm-away-watch.service" "the service does not run the watchdog for the home"
  assert_grep 'OnCalendar=*:0/5' "$dir/xdg/systemd/user/fm-away-watch.timer" "the timer does not run every 5 minutes"
  assert_grep '--user enable --now fm-away-watch.timer' "$dir/systemctl.log" "install-timer did not enable the timer"
  out=$(PATH="$fakebin:$PATH" XDG_CONFIG_HOME="$dir/xdg" "$WATCH" uninstall-timer 2>&1) \
    || fail "uninstall-timer failed: $out"
  assert_absent "$dir/xdg/systemd/user/fm-away-watch.service" "uninstall-timer left the service"
  assert_absent "$dir/xdg/systemd/user/fm-away-watch.timer" "uninstall-timer left the timer"
  assert_grep '--user disable --now fm-away-watch.timer' "$dir/systemctl.log" "uninstall-timer did not disable the timer"
  pass "install-timer writes and enables a 5-minute user timer and uninstall-timer removes it"
}

test_silent_when_attended_or_quiet
test_silent_with_live_host
test_host_threshold
test_dead_lock_owner
test_held_latch
test_aged_queue_row
test_autoarm_markers_and_rate_limit
test_timer_install_and_uninstall
