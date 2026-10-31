#!/usr/bin/env bash
# tests/fm-watch-open-decisions.test.sh - the opt-in overdue open-decision
# reminder (bin/fm-watch.sh open_decision_reminder_tick and its main-loop entry
# open_decision_reminder_check), driven through the watcher's own functions and
# the real watch checkpoint. The reminder reads the shared fold's timed view
# (bin/fm-classify-lib.sh status_open_decisions_incremental ... timed) and
# queues check rows through the real wake queue. No endpoint, harness process,
# model call or remote host is needed. docs/configuration.md "Open-decision
# reminders" owns the switch and its settings.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-watch-open-decisions)
mkdir -p "$TMP_ROOT"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)
# A fresh non-git root keeps the watcher's tangle and code-root checks inert in
# this disposable worktree, as tests/fm-parent-channel-scan-exclusion.test.sh does.
FM_ROOT_OVERRIDE="$(fm_test_tmproot fm-watch-open-decisions-root)"
export FM_ROOT_OVERRIDE
mkdir -p "$FM_ROOT_OVERRIDE"

cleanup() { rm -rf -- "$TMP_ROOT"; }
trap cleanup EXIT

UNIT_HOME="$TMP_ROOT/unit"
mkdir -p "$UNIT_HOME/state" "$UNIT_HOME/config"
export FM_HOME="$UNIT_HOME" FM_STATE_OVERRIDE="$UNIT_HOME/state" FM_CONFIG_OVERRIDE="$UNIT_HOME/config"
# Source the watcher once; its source guard returns before the lock and the
# loop, so only the functions load.
# Production modules are independently linted canonical roots. Keep this test's
# ShellCheck context local while preserving its unchanged runtime source path.
# shellcheck source=/dev/null
. "$ROOT/bin/fm-watch.sh"

export FM_OPEN_DECISION_OVERDUE_SECS=100
export FM_OPEN_DECISION_BACKOFF_MAX_SECS=400

# The unit cases never consult the real captain-call reader; the exemption case
# swaps in its own.
# shellcheck disable=SC2329 # invoked indirectly through open_decision_reminder_tick
task_captain_call_open() { return 1; }

reset_case() {
  rm -rf -- "${STATE:?}"/* "$STATE"/.[!.]* "${CONFIG:?}"/*
  OPEN_DECISION_REMINDER=
  OPEN_DECISION_ERROR=
  OPEN_DECISION_TICK_LAST=
}

enable() { : > "$CONFIG/open-decision-reminders"; }

count_wakes() {
  local n=0 _row
  [ -f "$FM_WAKE_QUEUE" ] || { printf 0; return; }
  while IFS= read -r _row; do n=$((n + 1)); done < "$FM_WAKE_QUEUE"
  printf '%s' "$n"
}

queue_keys() {  # the key column of every queued row, in queue order
  [ -f "$FM_WAKE_QUEUE" ] || return 0
  awk -F '\t' '{ print $3 " " $4 }' "$FM_WAKE_QUEUE"
}

expect_wakes() {  # <count> <what>
  local got
  got=$(count_wakes)
  [ "$got" = "$1" ] || fail "$2 (queued $got, want $1): $(queue_keys)"
}

test_disabled() {
  reset_case
  printf 'needs-decision [at=1000] [key=api]: choose\n' > "$STATE/worker.status"
  open_decision_reminder_tick 1200 || fail "a disabled tick failed: $OPEN_DECISION_ERROR"
  expect_wakes 0 "the absent flag queued a reminder"
  [ -z "$OPEN_DECISION_REMINDER" ] || fail "the absent flag set a reminder: $OPEN_DECISION_REMINDER"
  [ ! -e "$STATE/.worker.timed-open-decisions-cursor" ] || fail "the absent flag folded status"
  [ ! -e "$STATE/.open-decision-reminders" ] || fail "the absent flag wrote a ledger"
  pass "with the flag absent nothing is folded, written or queued"
}

test_every_due_key_and_backoff() {
  reset_case
  enable
  printf 'needs-decision [at=1000] [key=older]: choose\nworking: continuing\n' > "$STATE/z-worker.status"
  printf 'blocked [at=1050] [key=newer]: help\n' > "$STATE/a-worker.status"
  open_decision_reminder_tick 1099 || fail "tick failed: $OPEN_DECISION_ERROR"
  expect_wakes 0 "a key short of the threshold queued a reminder"
  open_decision_reminder_tick 1200 || fail "tick failed: $OPEN_DECISION_ERROR"
  expect_wakes 2 "every overdue key did not get its own row"
  [ "$OPEN_DECISION_REMINDER" = 'check: open decision overdue: z-worker key=older age=200s (+1 more queued)' ] \
    || fail "the wake did not name the oldest decision and the count behind it: $OPEN_DECISION_REMINDER"
  [ "$(queue_keys)" = "check open-decision:z-worker:older
check open-decision:a-worker:newer" ] || fail "the rows were not queued oldest first: $(queue_keys)"
  open_decision_reminder_tick 1299 || fail "tick failed: $OPEN_DECISION_ERROR"
  expect_wakes 2 "a key repeated before its first backoff"
  [ -z "$OPEN_DECISION_REMINDER" ] || fail "a quiet tick still set a reminder: $OPEN_DECISION_REMINDER"
  open_decision_reminder_tick 1300 || fail "tick failed: $OPEN_DECISION_ERROR"
  expect_wakes 4 "the first repeat did not come due one threshold after the reminder"
  open_decision_reminder_tick 1499 || fail "tick failed: $OPEN_DECISION_ERROR"
  expect_wakes 4 "the repeat interval did not double"
  open_decision_reminder_tick 1500 || fail "tick failed: $OPEN_DECISION_ERROR"
  expect_wakes 6 "the doubled interval did not expire"
  open_decision_reminder_tick 1899 || fail "tick failed: $OPEN_DECISION_ERROR"
  expect_wakes 6 "the capped interval fired early"
  open_decision_reminder_tick 1900 || fail "tick failed: $OPEN_DECISION_ERROR"
  open_decision_reminder_tick 2299 || fail "tick failed: $OPEN_DECISION_ERROR"
  expect_wakes 8 "the interval grew past its cap"
  open_decision_reminder_tick 2300 || fail "tick failed: $OPEN_DECISION_ERROR"
  expect_wakes 10 "the interval did not stay at its cap"
  pass "every overdue key is queued oldest first in one wake, and each key's backoff doubles up to its cap"
}

test_due_keys_queue_oldest_first() {
  reset_case
  enable
  # Scan order is a, m, z and the newest key of z's log comes first in its file,
  # so only a sort by opening time gives m:old, z:mid, m:new, a:late.
  printf 'blocked [at=1060] [key=late]: help\n' > "$STATE/a.status"
  printf 'needs-decision [at=1000] [key=old]: choose\nblocked [at=1040] [key=new]: help\n' > "$STATE/m.status"
  printf 'blocked [at=1020] [key=mid]: help\n' > "$STATE/z.status"
  open_decision_reminder_tick 1200 || fail "tick failed: $OPEN_DECISION_ERROR"
  [ "$(queue_keys)" = "check open-decision:m:old
check open-decision:z:mid
check open-decision:m:new
check open-decision:a:late" ] || fail "the due keys were not queued oldest first: $(queue_keys)"
  [ "$OPEN_DECISION_REMINDER" = 'check: open decision overdue: m key=old age=200s (+3 more queued)' ] \
    || fail "the wake did not name the oldest decision: $OPEN_DECISION_REMINDER"
  pass "every due key is queued by opening time, oldest first, across and within status logs"
}

test_backoff_survives_a_restart() {
  reset_case
  enable
  printf 'needs-decision [at=1000] [key=api]: choose\n' > "$STATE/worker.status"
  open_decision_reminder_tick 1200 || fail "tick failed: $OPEN_DECISION_ERROR"
  # A new watcher process starts with no memory but the ledger and cursor.
  OPEN_DECISION_TICK_LAST=
  open_decision_reminder_check 1250 || fail "a check after a restart failed"
  expect_wakes 1 "a restarted watcher repeated a reminder inside its backoff"
  rm -f "$STATE/.worker.timed-open-decisions-cursor"
  OPEN_DECISION_TICK_LAST=
  open_decision_reminder_check 1260 || fail "a check after a cursor loss failed"
  expect_wakes 1 "a re-fold from offset 0 lost the key's backoff"
  pass "the ledger carries each key's backoff across a restart and a re-fold"
}

assert_distinct_identities() {  # <task-a> <key-a> <task-b> <key-b>
  reset_case
  enable
  printf 'needs-decision [at=1000] [key=%s]: choose\n' "$2" > "$STATE/$1.status"
  printf 'blocked [at=1050] [key=%s]: help\n' "$4" >> "$STATE/$3.status"
  open_decision_reminder_tick 1200 || fail "tick failed: $OPEN_DECISION_ERROR"
  [ "$(queue_keys)" = "check open-decision:$1:$2
check open-decision:$3:$4" ] || fail "$1/$2 and $3/$4 did not get separate rows: $(queue_keys)"
  printf 'resolved [key=%s]: answered\n' "$2" >> "$STATE/$1.status"
  open_decision_reminder_tick 1300 || fail "tick failed: $OPEN_DECISION_ERROR"
  expect_wakes 3 "resolving $1/$2 also silenced $3/$4"
  [ "$OPEN_DECISION_REMINDER" = "check: open decision overdue: $3 key=$4 age=250s" ] \
    || fail "the remaining identity did not keep its own backoff: $OPEN_DECISION_REMINDER"
}

test_numeric_keys_are_distinct() {
  assert_distinct_identities worker 1 worker 01
  pass "keys 1 and 01 get separate reminders and separate backoff"
}

test_numeric_tasks_are_distinct() {
  assert_distinct_identities 1 api 01 api
  pass "tasks 1 and 01 get separate reminders and separate backoff"
}

test_resolution_and_reopen() {
  reset_case
  enable
  printf 'needs-decision [at=1000] [key=api]: choose\n' > "$STATE/worker.status"
  open_decision_reminder_tick 1200 || fail "tick failed: $OPEN_DECISION_ERROR"
  printf 'resolved [at=1201] [key=api]: answered\n' >> "$STATE/worker.status"
  open_decision_reminder_tick 1600 || fail "tick failed: $OPEN_DECISION_ERROR"
  expect_wakes 1 "a resolved key kept its reminders"
  [ ! -s "$STATE/.open-decision-reminders" ] || fail "a resolved key kept its ledger row: $(cat "$STATE/.open-decision-reminders")"
  printf 'blocked [at=1600] [key=api]: new episode\n' >> "$STATE/worker.status"
  open_decision_reminder_tick 1700 || fail "tick failed: $OPEN_DECISION_ERROR"
  expect_wakes 2 "a reopened key inherited the resolved episode's backoff"
  # Resolved and reopened between two ticks: only the opening time tells the
  # new episode from the old one's ledger row.
  printf 'resolved [key=api]: answered\nblocked [at=1650] [key=api]: third episode\n' >> "$STATE/worker.status"
  open_decision_reminder_tick 1750 || fail "tick failed: $OPEN_DECISION_ERROR"
  expect_wakes 3 "a key reopened within one tick inherited the previous episode's backoff"
  [ "$(cat "$STATE/.open-decision-reminders")" = $'worker\tapi\t1650\t1750\t100' ] \
    || fail "the reopened episode did not start a fresh ledger row: $(cat "$STATE/.open-decision-reminders")"
  pass "a resolution stops reminders at once and a reopened key starts fresh, even within one tick"
}

test_wait_exemptions() {
  reset_case
  enable
  printf 'needs-decision [at=1000] [key=api]: choose\npaused [at=1050]: validation in flight\n' > "$STATE/paused.status"
  printf 'needs-decision [at=1000] [key=api]: choose\ncaptain-held [at=1050]: transferred\n' > "$STATE/held.status"
  printf 'needs-decision [at=1000] [key=api]: choose\n' > "$STATE/backlog-held.status"
  # shellcheck disable=SC2329 # invoked indirectly through open_decision_reminder_tick
  task_captain_call_open() { [ "$1" = backlog-held ]; }
  open_decision_reminder_tick 1200 || fail "tick failed: $OPEN_DECISION_ERROR"
  expect_wakes 0 "a declared wait, a captain hold or an open captain call queued a reminder"
  printf 'working [at=1201]: resumed\n' >> "$STATE/paused.status"
  open_decision_reminder_tick 1201 || fail "tick failed: $OPEN_DECISION_ERROR"
  expect_wakes 1 "ending a pause hid the still-open key"
  [ "$(queue_keys)" = 'check open-decision:paused:api' ] || fail "the wrong key was reminded: $(queue_keys)"
  grep -Fx "$(printf 'held\tapi\t1000\t0\t100')" "$STATE/.open-decision-reminders" >/dev/null \
    || fail "an exempt key's ledger row was not kept as it was: $(cat "$STATE/.open-decision-reminders")"
  # shellcheck disable=SC2329 # invoked indirectly through open_decision_reminder_tick
  task_captain_call_open() { return 1; }
  pass "paused waits, captain-held transfers and open captain calls are exempt and keep their rows"
}

test_hold_reader_cannot_eat_the_open_set() {
  reset_case
  enable
  printf 'needs-decision [at=1000] [key=one]: choose\nblocked [at=1010] [key=two]: help\n' > "$STATE/worker.status"
  # A hold reader that drains its stdin must not consume the keys after it.
  # shellcheck disable=SC2329 # invoked indirectly through open_decision_reminder_tick
  task_captain_call_open() { cat > /dev/null; return 1; }
  open_decision_reminder_tick 1200 || fail "tick failed: $OPEN_DECISION_ERROR"
  # shellcheck disable=SC2329 # invoked indirectly through open_decision_reminder_tick
  task_captain_call_open() { return 1; }
  expect_wakes 2 "the hold reader consumed the rest of the open set"
  pass "the captain-call reader cannot read the open set from the tick's stdin"
}

test_unknown_times_and_keyless() {
  reset_case
  enable
  printf 'needs-decision [key=missing]: choose\nblocked [at=bad] [key=bad]: help\nblocked [at=1000]: legacy\n' > "$STATE/worker.status"
  open_decision_reminder_tick 1200 2> "$TMP_ROOT/unknown.err" || fail "tick failed: $OPEN_DECISION_ERROR"
  expect_wakes 0 "a decision with no known opening time or no explicit key was aged"
  [ ! -s "$TMP_ROOT/unknown.err" ] || fail "an unknown opening time printed errors: $(cat "$TMP_ROOT/unknown.err")"
  pass "only explicitly keyed decisions with a readable opening time are aged"
}

test_timed_fold_is_incremental_and_leaves_the_drain_cursor() {
  local probe="$TMP_ROOT/fold.reads"
  reset_case
  enable
  printf 'needs-decision [at=1000] [key=api]: choose\n' > "$STATE/worker.status"
  : > "$probe"
  FM_OPEN_DECISIONS_READ_PROBE="$probe" open_decision_reminder_tick 1200 || fail "tick failed: $OPEN_DECISION_ERROR"
  FM_OPEN_DECISIONS_READ_PROBE="$probe" open_decision_reminder_tick 1201 || fail "tick failed: $OPEN_DECISION_ERROR"
  [ "$(wc -l < "$probe" | tr -d ' ')" = 1 ] || fail "an unchanged log was read again: $(cat "$probe")"
  printf 'resolved [key=api]: answered\n' >> "$STATE/worker.status"
  FM_OPEN_DECISIONS_READ_PROBE="$probe" open_decision_reminder_tick 1202 || fail "tick failed: $OPEN_DECISION_ERROR"
  [ "$(tail -n 1 "$probe" | cut -f2)" = 29 ] || fail "the fold read more than the new bytes: $(cat "$probe")"
  expect_wakes 1 "an incremental resolution left the reminder live"
  [ ! -e "$STATE/.worker.open-decisions-cursor" ] || fail "the reminder moved the drain's cursor"
  [ ! -e "$STATE/.worker.snapshot-open-decisions-cursor" ] || fail "the reminder moved the snapshot cursor"
  pass "the timed fold reads only new bytes and never touches the drain or snapshot cursor"
}

test_invalid_settings_alarm_once() {
  local err
  reset_case
  enable
  printf 'blocked [at=1000] [key=api]: help\n' > "$STATE/worker.status"
  FM_OPEN_DECISION_OVERDUE_SECS=0 open_decision_reminder_check 1200 || fail "an invalid setting stopped the check"
  expect_wakes 1 "an invalid env threshold did not raise exactly one alarm"
  [ "$(queue_keys)" = 'check open-decision-reminders' ] || fail "the alarm was not a check row: $(queue_keys)"
  case "$OPEN_DECISION_REMINDER" in
    'check: open-decision reminders failed: FM_OPEN_DECISION_OVERDUE_SECS=0 is not a positive whole number of seconds; no reminder is sent until it is fixed') ;;
    *) fail "the alarm did not name the setting: $OPEN_DECISION_REMINDER" ;;
  esac
  [ -f "$STATE/.open-decision-reminders.error" ] || fail "the alarm left no marker"
  FM_OPEN_DECISION_OVERDUE_SECS=0 open_decision_reminder_check 1300 || fail "a repeated invalid setting stopped the check"
  expect_wakes 1 "the same failure alarmed again"
  [ -z "$OPEN_DECISION_REMINDER" ] || fail "a repeated failure still asked for a wake: $OPEN_DECISION_REMINDER"

  FM_OPEN_DECISION_BACKOFF_MAX_SECS=99 open_decision_reminder_check 1400 || fail "a low cap stopped the check"
  expect_wakes 2 "a cap below the threshold did not raise its own alarm"

  for err in 'soon' '' ' 0 ' '1234567890'; do
    printf '%s\n' "$err" > "$CONFIG/open-decision-overdue-secs"
    OPEN_DECISION_TICK_LAST=
    rm -f "$STATE/.open-decision-reminders.error"
    FM_OPEN_DECISION_OVERDUE_SECS='' open_decision_reminder_tick 1500 \
      && fail "the setting file holding '$err' was accepted"
  done
  rm -f "$CONFIG/open-decision-overdue-secs"
  mkdir "$CONFIG/open-decision-overdue-secs"
  FM_OPEN_DECISION_OVERDUE_SECS='' open_decision_reminder_tick 1500 && fail "a directory setting file was accepted"
  case "$OPEN_DECISION_ERROR" in
    "setting file $CONFIG/open-decision-overdue-secs is not a readable regular file") ;;
    *) fail "a directory setting file was not named: $OPEN_DECISION_ERROR" ;;
  esac
  rmdir "$CONFIG/open-decision-overdue-secs"
  printf '150\n' > "$TMP_ROOT/linked-setting"
  ln -s "$TMP_ROOT/linked-setting" "$CONFIG/open-decision-overdue-secs"
  FM_OPEN_DECISION_OVERDUE_SECS='' open_decision_reminder_tick 1500 && fail "a symlinked setting file was accepted"
  case "$OPEN_DECISION_ERROR" in
    "setting file $CONFIG/open-decision-overdue-secs is not a readable regular file") ;;
    *) fail "a symlinked setting file was not named: $OPEN_DECISION_ERROR" ;;
  esac
  rm -f "$CONFIG/open-decision-overdue-secs"
  expect_wakes 2 "a refused tick queued a reminder"

  printf ' 150 \n' > "$CONFIG/open-decision-overdue-secs"
  printf 'stale failure\n' > "$STATE/.open-decision-reminders.error"
  FM_OPEN_DECISION_OVERDUE_SECS='' open_decision_reminder_check 1600 || fail "a good setting file stopped the check"
  [ ! -e "$STATE/.open-decision-reminders.error" ] || fail "a good tick did not clear the failure marker"
  [ "$OPEN_DECISION_REMINDER" = 'check: open decision overdue: worker key=api age=600s' ] \
    || fail "the setting file's threshold did not apply: $OPEN_DECISION_REMINDER"
  grep -Fx $'worker\tapi\t1000\t1600\t150' "$STATE/.open-decision-reminders" >/dev/null \
    || fail "the ledger did not take the file's threshold as the first delay: $(cat "$STATE/.open-decision-reminders")"
  pass "invalid settings raise one alarm per distinct failure, a setting file is read every tick, and a good tick clears the marker"
}

test_unreadable_ledger_alarms() {
  reset_case
  enable
  printf 'blocked [at=1000] [key=api]: help\n' > "$STATE/worker.status"
  mkdir "$STATE/.open-decision-reminders"
  open_decision_reminder_tick 1200 && fail "a directory in the ledger's place was accepted"
  expect_wakes 0 "an unreadable ledger still queued a reminder"
  open_decision_reminder_check 1200 || fail "an unreadable ledger stopped the check"
  case "$OPEN_DECISION_REMINDER" in
    "check: open-decision reminders failed: ledger $STATE/.open-decision-reminders is not a readable regular file;"*) ;;
    *) fail "the ledger failure was not named: $OPEN_DECISION_REMINDER" ;;
  esac
  rmdir "$STATE/.open-decision-reminders"
  : > "$TMP_ROOT/linked-ledger"
  ln -s "$TMP_ROOT/linked-ledger" "$STATE/.open-decision-reminders"
  open_decision_reminder_tick 1200 && fail "a symlink in the ledger's place was accepted"
  [ "$OPEN_DECISION_ERROR" = "ledger $STATE/.open-decision-reminders is not a readable regular file" ] \
    || fail "the symlinked ledger was not named: $OPEN_DECISION_ERROR"
  expect_wakes 1 "a symlinked ledger still queued a reminder"
  rm -f "$STATE/.open-decision-reminders"
  printf 'garbage\nworker\tapi\t1000\tx\t100\n' > "$STATE/.open-decision-reminders"
  # shellcheck disable=SC2034 # read by open_decision_reminder_check
  OPEN_DECISION_TICK_LAST=
  open_decision_reminder_check 1300 || fail "a malformed ledger row stopped the check"
  [ "$OPEN_DECISION_REMINDER" = 'check: open decision overdue: worker key=api age=300s' ] \
    || fail "a malformed ledger row was not treated as no reminder yet: $OPEN_DECISION_REMINDER"
  [ "$(cat "$STATE/.open-decision-reminders")" = $'worker\tapi\t1000\t1300\t100' ] \
    || fail "the rebuilt ledger kept a malformed row: $(cat "$STATE/.open-decision-reminders")"
  pass "an unreadable ledger alarms, and a malformed row counts as no reminder yet and is dropped"
}

test_unwritable_marker_says_it_repeats() {
  reset_case
  enable
  printf 'blocked [at=1000] [key=api]: help\n' > "$STATE/worker.status"
  mkdir "$STATE/.open-decision-reminders.error"
  FM_OPEN_DECISION_OVERDUE_SECS=0 open_decision_reminder_check 1200 || fail "an unwritable marker stopped the check"
  case "$OPEN_DECISION_REMINDER" in
    *", and $STATE/.open-decision-reminders.error could not be written, so this repeats every tick; no reminder is sent until it is fixed") ;;
    *) fail "the alarm did not say its marker could not be written: $OPEN_DECISION_REMINDER" ;;
  esac
  [ -z "$(ls -A "$STATE/.open-decision-reminders.error")" ] || fail "the marker write went into the directory in its place"
  FM_OPEN_DECISION_OVERDUE_SECS=0 open_decision_reminder_check 1300 || fail "a repeated unwritable marker stopped the check"
  expect_wakes 2 "an alarm that cannot be remembered did not repeat as it said"
  rmdir "$STATE/.open-decision-reminders.error"
  pass "a directory in the marker's place is reported as unwritable and the alarm says it repeats"
}

test_cadence_gate() {
  reset_case
  enable
  printf 'needs-decision [at=1000] [key=one]: choose\n' > "$STATE/worker.status"
  open_decision_reminder_check 1200 || fail "the first check failed"
  expect_wakes 1 "the first check of a process did not run the tick"
  printf 'blocked [at=1000] [key=two]: help\n' >> "$STATE/worker.status"
  open_decision_reminder_check 1259 || fail "a gated check failed"
  expect_wakes 1 "a check inside the cadence ran the tick"
  [ -z "$OPEN_DECISION_REMINDER" ] || fail "a gated check kept the last reminder: $OPEN_DECISION_REMINDER"
  open_decision_reminder_check 1260 || fail "a due check failed"
  expect_wakes 2 "a check one cadence later did not run the tick"
  printf 'blocked [at=1000] [key=three]: help\n' >> "$STATE/worker.status"
  open_decision_reminder_check 1100 || fail "a check after the clock stepped back failed"
  expect_wakes 3 "a clock that stepped back held the tick"
  pass "the tick runs on a process's first check and then at most once a cadence, even when the clock steps back"
}

test_timed_cursor_retirement() {
  reset_case
  enable
  printf 'blocked [at=1000] [key=api]: help\n' > "$STATE/worker.status"
  open_decision_reminder_tick 1200 || fail "tick failed: $OPEN_DECISION_ERROR"
  [ -f "$STATE/.worker.timed-open-decisions-cursor" ] || fail "the tick left no timed cursor"
  status_retire_presentation_task "$STATE" worker || fail "retirement failed"
  [ ! -e "$STATE/.worker.timed-open-decisions-cursor" ] || fail "retirement left the timed cursor"
  rm -f "$STATE/worker.status"
  open_decision_reminder_tick 1600 || fail "tick failed: $OPEN_DECISION_ERROR"
  expect_wakes 1 "a retired task kept its reminders"
  [ ! -s "$STATE/.open-decision-reminders" ] || fail "a retired task kept its ledger row"
  pass "retirement removes the timed cursor and the next tick drops the task's ledger row"
}

make_fakebin() {  # <dir>
  local fakebin
  fakebin=$(fm_fakebin "$1")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  display-message) printf 'firstmate\n' ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  printf '%s\n' "$fakebin"
}

test_real_watcher_wakes_on_an_overdue_key() {
  local dir="$TMP_ROOT/watcher-loop" out rc rows fakebin
  mkdir -p "$dir/state" "$dir/config" "$dir/data" "$dir/projects" "$dir/user-home"
  fm_test_track_watcher_state "$dir/state"
  fakebin=$(make_fakebin "$dir")
  printf '%s\n' "$$" > "$dir/state/.lock"
  touch "$dir/state/.last-watcher-beat"
  : > "$dir/config/open-decision-reminders"
  : > "$dir/state/home-summary.json"
  printf 'needs-decision [at=1000] [key=api]: choose\n' > "$dir/state/worker.status"
  FM_STATE_OVERRIDE="$dir/state" fm_wake_status_mark_current "$dir/state" "$dir/state/worker.status" \
    || fail "could not mark the fixture status as seen"
  rc=0
  # The bound is only a hang guard: the checkpoint returns on the first wake.
  out=$(env -u FM_TRACE_CONTEXT FM_ROOT_OVERRIDE='' FM_HOME="$dir" \
    HOME="$dir/user-home" CLAUDE_CONFIG_DIR='' \
    FM_STATE_OVERRIDE="$dir/state" FM_DATA_OVERRIDE="$dir/data" \
    FM_PROJECTS_OVERRIDE="$dir/projects" FM_CONFIG_OVERRIDE="$dir/config" \
    TMUX="fake,1,0" PATH="$fakebin:$PATH" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 \
    FM_OPEN_DECISION_OVERDUE_SECS=100 FM_OPEN_DECISION_BACKOFF_MAX_SECS=400 \
    "$ROOT/bin/fm-watch-checkpoint.sh" --seconds 60 2>&1) || rc=$?
  [ "$rc" -eq 0 ] || fail "the watcher did not wake on an overdue key (rc=$rc): $out"
  case "$out" in
    *'check: open decision overdue: worker key=api age='*) ;;
    *) fail "the watcher woke without the reminder: $out" ;;
  esac
  rows=$(awk -F '\t' '{ print $3 " " $4 }' "$dir/state/.wake-queue")
  [ "$rows" = 'check open-decision:worker:api' ] || fail "the watcher did not queue exactly the reminder row: $rows"
  pass "the real watcher wakes on an overdue key with no pane recorded, through one check row"
}

test_disabled
test_every_due_key_and_backoff
test_due_keys_queue_oldest_first
test_backoff_survives_a_restart
test_numeric_keys_are_distinct
test_numeric_tasks_are_distinct
test_resolution_and_reopen
test_wait_exemptions
test_hold_reader_cannot_eat_the_open_set
test_unknown_times_and_keyless
test_timed_fold_is_incremental_and_leaves_the_drain_cursor
test_invalid_settings_alarm_once
test_unreadable_ledger_alarms
test_unwritable_marker_says_it_repeats
test_cadence_gate
test_timed_cursor_retirement
test_real_watcher_wakes_on_an_overdue_key
