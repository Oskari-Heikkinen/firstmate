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
  local err want
  reset_case
  enable
  printf 'blocked [at=1000] [key=api]: help\n' > "$STATE/worker.status"
  FM_OPEN_DECISION_OVERDUE_SECS=0 open_decision_reminder_check 1200 || fail "an invalid setting stopped the check"
  expect_wakes 1 "an invalid env threshold did not raise exactly one alarm"
  [ "$(queue_keys)" = 'check open-decision-reminders' ] || fail "the alarm was not a check row: $(queue_keys)"
  case "$OPEN_DECISION_REMINDER" in
    'check: open-decision reminders failed: FM_OPEN_DECISION_OVERDUE_SECS=0 is not a positive whole number of seconds; reminder delivery is incomplete until it is fixed') ;;
    *) fail "the alarm did not name the setting: $OPEN_DECISION_REMINDER" ;;
  esac
  [ -f "$STATE/.open-decision-reminders.error" ] || fail "the alarm left no marker"
  FM_OPEN_DECISION_OVERDUE_SECS=0 open_decision_reminder_check 1300 || fail "a repeated invalid setting stopped the check"
  expect_wakes 1 "the same failure alarmed again"
  [ -z "$OPEN_DECISION_REMINDER" ] || fail "a repeated failure still asked for a wake: $OPEN_DECISION_REMINDER"

  FM_OPEN_DECISION_BACKOFF_MAX_SECS=99 open_decision_reminder_check 1400 || fail "a low cap stopped the check"
  expect_wakes 2 "a cap below the threshold did not raise its own alarm"

  # Each value is refused by its own guard, named exactly, with nothing on stderr.
  for err in 'soon' '' ' 0 ' '1234567890'; do
    printf '%s\n' "$err" > "$CONFIG/open-decision-overdue-secs"
    want="setting file $CONFIG/open-decision-overdue-secs does not hold a positive whole number of seconds"
    [ "$err" != 1234567890 ] || want='open-decision reminder setting 1234567890 has more than nine digits'
    FM_OPEN_DECISION_OVERDUE_SECS='' open_decision_reminder_tick 1500 2> "$TMP_ROOT/setting.err" \
      && fail "the setting file holding '$err' was accepted"
    [ "$OPEN_DECISION_ERROR" = "$want" ] || fail "the setting file holding '$err' was refused for another reason: $OPEN_DECISION_ERROR"
    [ ! -s "$TMP_ROOT/setting.err" ] || fail "the setting file holding '$err' printed: $(cat "$TMP_ROOT/setting.err")"
  done
  rm -f "$CONFIG/open-decision-overdue-secs"
  # Both values are ten digits, so the cap guard passes and only the length guard can refuse.
  FM_OPEN_DECISION_OVERDUE_SECS=1234567890 FM_OPEN_DECISION_BACKOFF_MAX_SECS=1234567890 \
    open_decision_reminder_tick 1500 && fail "ten-digit settings were accepted"
  [ "$OPEN_DECISION_ERROR" = 'open-decision reminder setting 1234567890 has more than nine digits' ] \
    || fail "ten-digit settings were not refused for their length: $OPEN_DECISION_ERROR"
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
  open_decision_reminder_check 1300 2> "$TMP_ROOT/ledger.err" || fail "a malformed ledger row stopped the check"
  [ ! -s "$TMP_ROOT/ledger.err" ] || fail "a malformed ledger row reached arithmetic: $(cat "$TMP_ROOT/ledger.err")"
  [ "$OPEN_DECISION_REMINDER" = 'check: open decision overdue: worker key=api age=300s' ] \
    || fail "a malformed ledger row was not treated as no reminder yet: $OPEN_DECISION_REMINDER"
  [ "$(cat "$STATE/.open-decision-reminders")" = $'worker\tapi\t1000\t1300\t100' ] \
    || fail "the rebuilt ledger kept a malformed row: $(cat "$STATE/.open-decision-reminders")"
  pass "an unreadable ledger alarms, and a malformed row counts as no reminder yet and is dropped"
}

test_own_parent_channel_is_not_reminded() {
  # A remote mate home's outbound parent channel is mirrored into the parent
  # home, so its decisions are the parent's to age, not this home's.
  reset_case
  enable
  printf 'mate\n' > "$UNIT_HOME/.fm-secondmate-home"
  printf 'schema=fm-secondmate-parent.v1\nroute=remote\nparent_host=remote.example\n' \
    > "$UNIT_HOME/.fm-secondmate-parent"
  printf 'needs-decision [at=1000] [key=merge]: merge the green PR?\n' > "$STATE/parent-replies.status"
  printf 'blocked [at=1000] [key=api]: help\n' > "$STATE/worker.status"
  [ "$(status_scan_parent_channel_exclude "$STATE")" = "$STATE/parent-replies.status" ] \
    || fail "the fixture is not a remote mate home with an outbound parent channel"
  open_decision_reminder_check 1200 || fail "a remote mate home stopped the check"
  [ "$(queue_keys)" = 'check open-decision:worker:api' ] \
    || fail "the home reminded itself of its own parent channel: $(queue_keys)"
  rm -f "$UNIT_HOME/.fm-secondmate-home" "$UNIT_HOME/.fm-secondmate-parent"

  # Without the remote mate shape the same file is an ordinary task log.
  reset_case
  enable
  printf 'needs-decision [at=1000] [key=merge]: merge the green PR?\n' > "$STATE/parent-replies.status"
  open_decision_reminder_check 1200 || fail "a plain home stopped the check"
  [ "$(queue_keys)" = 'check open-decision:parent-replies:merge' ] \
    || fail "a plain home's parent-replies log was not reminded: $(queue_keys)"
  pass "a remote mate home never reminds itself of its own outbound parent channel, and any other home does"
}

test_unwritable_marker_says_it_repeats() {
  reset_case
  enable
  printf 'blocked [at=1000] [key=api]: help\n' > "$STATE/worker.status"
  mkdir "$STATE/.open-decision-reminders.error"
  FM_OPEN_DECISION_OVERDUE_SECS=0 open_decision_reminder_check 1200 || fail "an unwritable marker stopped the check"
  case "$OPEN_DECISION_REMINDER" in
    *", and $STATE/.open-decision-reminders.error could not be written, so this repeats every tick; reminder delivery is incomplete until it is fixed") ;;
    *) fail "the alarm did not say its marker could not be written: $OPEN_DECISION_REMINDER" ;;
  esac
  [ -z "$(ls -A "$STATE/.open-decision-reminders.error")" ] || fail "the marker write went into the directory in its place"
  FM_OPEN_DECISION_OVERDUE_SECS=0 open_decision_reminder_check 1300 || fail "a repeated unwritable marker stopped the check"
  expect_wakes 2 "an alarm that cannot be remembered did not repeat as it said"
  rmdir "$STATE/.open-decision-reminders.error"
  pass "a directory in the marker's place is reported as unwritable and the alarm says it repeats"
}

test_alarm_retries_failed_publication() {
  local fault
  for fault in queue sequence recovery; do
    reset_case
    enable
    case "$fault" in
      queue) mkdir "$FM_WAKE_QUEUE" ;;
      sequence) mkdir "$STATE/.wake-queue.seq" ;;
      recovery) mkdir "$STATE/.watcher-down" ;;
    esac
    FM_OPEN_DECISION_OVERDUE_SECS=0 open_decision_reminder_check 1200 2>/dev/null \
      && fail "$fault failure was accepted"
    [ ! -e "$STATE/.open-decision-reminders.error" ] || fail "$fault failure suppressed an undelivered alarm"
    case "$fault" in
      queue) rmdir "$FM_WAKE_QUEUE" ;;
      sequence) rmdir "$STATE/.wake-queue.seq" ;;
      recovery) rmdir "$STATE/.watcher-down" ;;
    esac
    OPEN_DECISION_TICK_LAST=
    FM_OPEN_DECISION_OVERDUE_SECS=0 open_decision_reminder_check 1201 || fail "$fault recovery failed"
    FM_OPEN_DECISION_OVERDUE_SECS=0 open_decision_reminder_check 1301 || fail "$fault repeat failed"
    expect_wakes 1 "$fault did not eventually deliver exactly one alarm"
  done
  pass "failed queue, sequence and recovery publication never commit alarm suppression"
}

test_alarm_interrupted_receipt_retries() {
  reset_case
  enable
  # Terminate after queue publication but before its receipt, as an interrupted
  # watcher would. Delivery is at-least-once, never silently lost.
  (
    # shellcheck disable=SC2329 # Called by the sourced watcher's receipt write.
    _fm_atomic_replace() {
      [ "$2" != "$STATE/.open-decision-reminders.error" ] || exit 73
      command mv -f -- "$1" "$2"
    }
    FM_OPEN_DECISION_OVERDUE_SECS=0 open_decision_reminder_check 1200
  ) && fail "the interrupted receipt returned success"
  expect_wakes 1 "the interruption was not after delivery"
  [ ! -e "$STATE/.open-decision-reminders.error" ] || fail "interrupted receipt was committed"
  FM_OPEN_DECISION_OVERDUE_SECS=0 open_decision_reminder_check 1300 || fail "interruption recovery failed"
  FM_OPEN_DECISION_OVERDUE_SECS=0 open_decision_reminder_check 1400 || fail "repeat failed"
  expect_wakes 2 "interrupted receipt did not retry once and then deduplicate"
  pass "an interruption between alarm publication and receipt retries instead of suppressing"
}

test_timed_read_failures_are_unknown() {
  local fault prior cursor ledger
  local bad="$TMP_ROOT/bad-reader"
  printf '#!/bin/sh\nexit 1\n' > "$bad"
  chmod +x "$bad"
  for fault in identity size span short; do
    for prior in empty open; do
      reset_case
      enable
      printf 'note: empty\n' > "$STATE/worker.status"
      [ "$prior" != open ] || printf 'blocked [at=1000] [key=api]: help\n' >> "$STATE/worker.status"
      open_decision_reminder_tick 1050 || fail "seed failed"
      cursor=$(cat "$STATE/.worker.timed-open-decisions-cursor")
      ledger=$(cat "$STATE/.open-decision-reminders" 2>/dev/null || true)
      if [ "$prior" = open ]; then
        printf 'resolved [key=api]: answer\n' >> "$STATE/worker.status"
      else
        printf 'blocked [at=1000] [key=api]: help\n' >> "$STATE/worker.status"
      fi
      case "$fault" in
        identity) FM_STATUS_IDENTITY_READER="$bad" open_decision_reminder_check 1200 ;;
        size) FM_STATUS_SIZE_READER="$bad" open_decision_reminder_check 1200 ;;
        span) FM_STATUS_SPAN_READER="$bad" open_decision_reminder_check 1200 ;;
        short) FM_STATUS_SPAN_READER=true open_decision_reminder_check 1200 ;;
      esac
      [ "$(queue_keys)" = 'check open-decision-reminders' ] || fail "$fault/$prior did not alarm"
      [ "$cursor" = "$(cat "$STATE/.worker.timed-open-decisions-cursor")" ] || fail "$fault/$prior changed the cursor"
      [ "$ledger" = "$(cat "$STATE/.open-decision-reminders" 2>/dev/null || true)" ] || fail "$fault/$prior changed the ledger"
      open_decision_reminder_check 1300 || fail "$fault/$prior recovery failed"
      [ ! -e "$STATE/.open-decision-reminders.error" ] || fail "$fault/$prior kept its error"
      if [ "$prior" = open ]; then
        expect_wakes 1 "$fault reminded a resolved decision"
        [ ! -s "$STATE/.open-decision-reminders" ] || fail "resolved row survived recovery"
      else
        expect_wakes 2 "$fault lost the new decision"
      fi
    done
  done
  pass "identity, size, failed and short span reads preserve state and alarm for empty and nonempty sets"
}

test_timed_failure_after_checkpoint_resumes() {
  local ledger calls=0
  reset_case
  enable
  printf 'blocked [at=1000] [key=api]: help\n' > "$STATE/worker.status"
  open_decision_reminder_tick 1050 || fail "seed failed"
  ledger=$(cat "$STATE/.open-decision-reminders")
  # 29 + 36 bytes: a 30-byte step checkpoints after the resolution line, then
  # the next chunk read fails.
  printf 'resolved [key=api]: answered\nblocked [at=1100] [key=other]: help\n' >> "$STATE/worker.status"
  eval "$(declare -f _fm_status_read_span | command sed '1s/_fm_status_read_span/real_read_span/')"
  # shellcheck disable=SC2329 # Called by the sourced watcher's status reader.
  _fm_status_read_span() {
    calls=$((calls + 1))
    [ "$calls" -le 1 ] || return 1
    real_read_span "$@"
  }
  FM_OPEN_DECISIONS_CHECKPOINT_BYTES=30 open_decision_reminder_check 1200 || fail "failed fold stopped check"
  [ "$(queue_keys)" = 'check open-decision-reminders' ] || fail "later chunk failure was not unknown: $(queue_keys)"
  [ "$ledger" = "$(cat "$STATE/.open-decision-reminders")" ] || fail "failed fold changed ledger"
  eval "$(declare -f real_read_span | command sed '1s/real_read_span/_fm_status_read_span/')"
  : > "$TMP_ROOT/read-probe"
  FM_OPEN_DECISIONS_READ_PROBE="$TMP_ROOT/read-probe" open_decision_reminder_check 1300 || fail "recovery failed"
  [ "$(cut -f2 "$TMP_ROOT/read-probe")" = 36 ] \
    || fail "recovery did not resume from the complete-line checkpoint: $(cat "$TMP_ROOT/read-probe")"
  [ "$(queue_keys)" = 'check open-decision-reminders
check open-decision:worker:other' ] || fail "recovery did not converge: $(queue_keys)"
  [ "$(cat "$STATE/.open-decision-reminders")" = $'worker\tother\t1100\t1300\t100' ] \
    || fail "recovery ledger is wrong: $(cat "$STATE/.open-decision-reminders")"
  pass "a timed fold failing after a checkpoint alarms, keeps the ledger and resumes from complete lines"
}

test_deduplicated_alarm_still_wakes_for_queued_keys() {
  reset_case
  enable
  printf 'blocked [at=1000] [key=api]: help\n' > "$STATE/worker.status"
  printf '%s\n' "ledger $STATE/.open-decision-reminders could not be written" > "$STATE/.open-decision-reminders.error"
  # The preflight succeeds; the commit after the key reached the queue fails
  # with the error already alarmed, so only the key's own wake remains owed.
  # shellcheck disable=SC2329 # Called by the sourced watcher's ledger write.
  _fm_atomic_replace() {
    if [ "$2" = "$STATE/.open-decision-reminders" ]; then
      case "$(queue_keys)" in *'open-decision:worker:api'*) return 1 ;; esac
    fi
    command mv -f -- "$1" "$2"
  }
  open_decision_reminder_check 1200 || fail "the failed commit stopped the check"
  [ "$(queue_keys)" = 'check open-decision:worker:api' ] || fail "the alarm was not deduplicated: $(queue_keys)"
  [ "$OPEN_DECISION_REMINDER" = 'check: open decision overdue: worker key=api age=200s' ] \
    || fail "a queued key lost its wake behind a deduplicated alarm: $OPEN_DECISION_REMINDER"
  pass "a deduplicated failure alarm still wakes for the keys its tick queued"
}

test_bad_status_paths_alarm() {
  local shape
  for shape in directory fifo dangling symlink unreadable; do
    reset_case
    enable
    case "$shape" in
      directory) mkdir "$STATE/worker.status" ;;
      fifo) mkfifo "$STATE/worker.status" ;;
      dangling) ln -s "$TMP_ROOT/absent" "$STATE/worker.status" ;;
      symlink) : > "$TMP_ROOT/target"; ln -s "$TMP_ROOT/target" "$STATE/worker.status" ;;
      unreadable)
        : > "$STATE/worker.status"; chmod 000 "$STATE/worker.status"
        if [ -r "$STATE/worker.status" ]; then continue; fi ;;
    esac
    open_decision_reminder_check 1200 || fail "$shape stopped the check"
    [ "$(queue_keys)" = 'check open-decision-reminders' ] || fail "$shape was treated as healthy empty"
    case "$OPEN_DECISION_REMINDER" in *'timed open-decision fold'*'failed'*) ;; *) fail "$shape did not name the fold" ;; esac
  done
  reset_case
  enable
  open_decision_reminder_check 1200 || fail "no logs was not healthy"
  : > "$STATE/empty.status"
  printf ' \t\n' > "$STATE/white.status"
  open_decision_reminder_check 1300 || fail "empty logs were not healthy"
  expect_wakes 0 "healthy empty input alarmed"
  pass "non-regular and unreadable status paths alarm while absent and empty logs stay quiet"
}

test_unlistable_state_dir_alarms() {
  local seed queued marker rc=0
  reset_case
  enable
  printf 'blocked [at=1000] [key=api]: help\n' > "$STATE/worker.status"
  open_decision_reminder_tick 1200 || fail "seed failed: $OPEN_DECISION_ERROR"
  seed=$(cat "$STATE/.open-decision-reminders")
  # Searchable and writable, but not listable: the ledger and every named
  # child still read, while the listing itself fails. The key is due.
  chmod 0300 "$STATE"
  if [ -r "$STATE" ]; then
    chmod 0700 "$STATE"
    pass "unlistable state directory skipped: this user can list a mode-0300 directory"
    return 0
  fi
  OPEN_DECISION_TICK_LAST=
  open_decision_reminder_check 1300 || rc=$?
  chmod 0700 "$STATE"
  [ "$rc" -eq 0 ] || fail "an unlistable state directory stopped the check"
  queued=$(queue_keys)
  marker=$(cat "$STATE/.open-decision-reminders.error" 2>/dev/null || true)
  [ "$queued" = 'check open-decision:worker:api
check open-decision-reminders' ] || fail "an unlistable state directory did not alarm, or reminded: $queued"
  [ "$marker" = "state directory $STATE cannot be listed" ] || fail "the alarm did not name the unlistable directory: $marker"
  [ "$seed" = "$(cat "$STATE/.open-decision-reminders")" ] || fail "an unlistable state directory erased the ledger's backoff"
  OPEN_DECISION_TICK_LAST=
  open_decision_reminder_check 1350 || fail "recovery failed"
  expect_wakes 3 "recovery did not deliver the due key exactly once"
  assert_grep $'worker\tapi\t1000\t1350\t200' "$STATE/.open-decision-reminders" "recovery lost the key's backoff"
  [ ! -e "$STATE/.open-decision-reminders.error" ] || fail "recovery kept its error"
  pass "a state directory that cannot be listed alarms and keeps the ledger, and recovery keeps the backoff"
}

# Directory access checks pass and named children stay readable; only the
# listing fails, after some output or none, or claims success with an
# unterminated name. The first reminder was queued at 1200, so the key is due.
test_failed_state_listing_alarms() {
  local shape seed queued marker
  eval "$(declare -f open_decision_state_ls | command sed '1s/open_decision_state_ls/real_state_ls/')"
  for shape in partial silent unterminated; do
    reset_case
    enable
    printf 'blocked [at=1000] [key=api]: help\n' > "$STATE/worker.status"
    open_decision_reminder_tick 1200 || fail "$shape seed failed: $OPEN_DECISION_ERROR"
    seed=$(cat "$STATE/.open-decision-reminders")
    fm_wake_append check unrelated 'check: preserve me' || fail "$shape seed queue failed"
    # shellcheck disable=SC2329 # Called by the sourced watcher's listing.
    case "$shape" in
      partial) open_decision_state_ls() { printf 'worker.status\n'; return 2; } ;;
      silent) open_decision_state_ls() { return 2; } ;;
      unterminated) open_decision_state_ls() { printf 'worker.status'; } ;;
    esac
    OPEN_DECISION_TICK_LAST=
    open_decision_reminder_check 1300 || fail "a $shape listing stopped the check"
    queued=$(queue_keys)
    marker=$(cat "$STATE/.open-decision-reminders.error" 2>/dev/null || true)
    [ "$queued" = 'check open-decision:worker:api
check unrelated
check open-decision-reminders' ] || fail "a $shape listing did not alarm, or reminded: $queued"
    [ "$marker" = "state directory $STATE cannot be listed" ] || fail "a $shape listing alarm did not name the directory: $marker"
    [ "$seed" = "$(cat "$STATE/.open-decision-reminders")" ] || fail "a $shape listing changed the ledger"
    eval "$(declare -f real_state_ls | command sed '1s/real_state_ls/open_decision_state_ls/')"
    # shellcheck disable=SC2034 # Read by the sourced watcher's check.
    OPEN_DECISION_TICK_LAST=
    open_decision_reminder_check 1350 || fail "$shape recovery failed"
    expect_wakes 4 "$shape recovery did not deliver the due key exactly once"
    assert_grep $'worker\tapi\t1000\t1350\t200' "$STATE/.open-decision-reminders" "$shape recovery lost the key's backoff"
    [ ! -e "$STATE/.open-decision-reminders.error" ] || fail "$shape recovery kept its error"
  done
  pass "a state listing that fails or is incomplete alarms and keeps the ledger, and recovery keeps the backoff"
}

# A state path that is not a directory has no names to list, so it can never
# read as a home with no logs.
test_state_path_not_a_directory_alarms() {
  local dir=$STATE shape
  for shape in file fifo; do
    reset_case
    enable
    rm -f -- "$TMP_ROOT/state-path"
    case "$shape" in
      file) : > "$TMP_ROOT/state-path" ;;
      fifo) mkfifo "$TMP_ROOT/state-path" ;;
    esac
    STATE="$TMP_ROOT/state-path"
    OPEN_DECISION_ERROR=
    if open_decision_reminder_tick 1200; then
      STATE=$dir
      fail "a state path that is a $shape was listed as an empty directory"
    fi
    [ "$OPEN_DECISION_ERROR" = "state directory $STATE cannot be listed" ] || {
      STATE=$dir
      fail "a $shape state path did not name the directory: $OPEN_DECISION_ERROR"
    }
    STATE=$dir
  done
  rm -f -- "$TMP_ROOT/state-path"
  pass "a state path that is not a directory refuses before any fold"
}

# A listed log whose lookup fails is unknown, never absent; one that a fresh
# listing no longer names is gone.
test_listed_log_lookup_failure_alarms() {
  local seed queued marker calls
  eval "$(declare -f open_decision_state_ls | command sed '1s/open_decision_state_ls/real_state_ls/')"
  reset_case
  enable
  printf 'blocked [at=1000] [key=api]: help\n' > "$STATE/worker.status"
  open_decision_reminder_tick 1200 || fail "seed failed: $OPEN_DECISION_ERROR"
  seed=$(cat "$STATE/.open-decision-reminders")
  fm_wake_append check unrelated 'check: preserve me' || fail "seed queue failed"
  # shellcheck disable=SC2329 # Called by the sourced watcher's listing.
  open_decision_state_ls() { real_state_ls "$@" && printf 'ghost.status\n'; }
  OPEN_DECISION_TICK_LAST=
  open_decision_reminder_check 1300 || fail "an unresolvable listed log stopped the check"
  queued=$(queue_keys)
  marker=$(cat "$STATE/.open-decision-reminders.error" 2>/dev/null || true)
  [ "$queued" = 'check open-decision:worker:api
check unrelated
check open-decision-reminders' ] || fail "an unresolvable listed log did not alarm, or reminded: $queued"
  [ "$marker" = "$STATE/ghost.status is listed but cannot be looked up" ] || fail "the alarm did not name the listed log: $marker"
  [ "$seed" = "$(cat "$STATE/.open-decision-reminders")" ] || fail "an unresolvable listed log changed the ledger"
  # Gone by the second listing: a log removed mid-scan is absent, not an alarm.
  calls="$TMP_ROOT/ls-calls"
  : > "$calls"
  # shellcheck disable=SC2329 # Called by the sourced watcher's listing.
  open_decision_state_ls() {
    printf x >> "$calls"
    real_state_ls "$@" || return
    [ "$(cat "$calls")" != x ] || printf 'ghost.status\n'
  }
  OPEN_DECISION_TICK_LAST=
  open_decision_reminder_check 1350 || fail "recovery failed"
  expect_wakes 4 "a log removed mid-scan alarmed, or the due key was not delivered exactly once"
  assert_grep $'worker\tapi\t1000\t1350\t200' "$STATE/.open-decision-reminders" "recovery lost the key's backoff"
  [ ! -e "$STATE/.open-decision-reminders.error" ] || fail "recovery kept its error"
  [ "$(cat "$calls")" = xx ] || fail "a missing listed log was not listed again: $(cat "$calls")"
  # A listable but unsearchable directory: every named lookup fails for real.
  reset_case
  enable
  printf 'blocked [at=1000] [key=api]: help\n' > "$STATE/worker.status"
  eval "$(declare -f real_state_ls | command sed '1s/real_state_ls/open_decision_state_ls/')"
  chmod 0400 "$STATE"
  if [ -e "$STATE/worker.status" ]; then
    chmod 0700 "$STATE"
    pass "a listed log whose lookup fails alarms, and one gone from a fresh listing is absent (unsearchable case skipped: this user can search a mode-0400 directory)"
    return 0
  fi
  OPEN_DECISION_ERROR=
  if open_decision_reminder_tick 1300; then
    chmod 0700 "$STATE"
    fail "an unsearchable state directory's logs were read as absent"
  fi
  chmod 0700 "$STATE"
  [ "$OPEN_DECISION_ERROR" = "$STATE/worker.status is listed but cannot be looked up" ] \
    || fail "an unsearchable state directory did not name its log: $OPEN_DECISION_ERROR"
  pass "a listed log whose lookup fails alarms, and one gone from a fresh listing is absent"
}

# The ledger is dot-named, so it reaches the listing only through -A; a listed
# ledger whose lookup fails would otherwise restart every key's backoff.
test_listed_ledger_lookup_failure_alarms() {
  local queued marker
  eval "$(declare -f open_decision_state_ls | command sed '1s/open_decision_state_ls/real_state_ls/')"
  reset_case
  enable
  printf 'blocked [at=1000] [key=api]: help\n' > "$STATE/worker.status"
  fm_wake_append check unrelated 'check: preserve me' || fail "seed queue failed"
  # shellcheck disable=SC2329 # Called by the sourced watcher's listing.
  open_decision_state_ls() { real_state_ls "$@" && printf '.open-decision-reminders\n'; }
  OPEN_DECISION_TICK_LAST=
  open_decision_reminder_check 1200 || fail "an unresolvable listed ledger stopped the check"
  queued=$(queue_keys)
  marker=$(cat "$STATE/.open-decision-reminders.error" 2>/dev/null || true)
  [ "$queued" = 'check unrelated
check open-decision-reminders' ] || fail "an unresolvable listed ledger did not alarm, or reminded: $queued"
  [ "$marker" = "$STATE/.open-decision-reminders is listed but cannot be looked up" ] || fail "the alarm did not name the ledger: $marker"
  [ ! -e "$STATE/.open-decision-reminders" ] || fail "an unresolvable listed ledger was replaced"
  eval "$(declare -f real_state_ls | command sed '1s/real_state_ls/open_decision_state_ls/')"
  OPEN_DECISION_TICK_LAST=
  open_decision_reminder_check 1250 || fail "recovery failed"
  expect_wakes 3 "recovery did not deliver the due key exactly once"
  assert_grep $'worker\tapi\t1000\t1250\t100' "$STATE/.open-decision-reminders" "recovery did not commit the key"
  [ ! -e "$STATE/.open-decision-reminders.error" ] || fail "recovery kept its error"
  # A real ledger in a listable but unsearchable directory.
  chmod 0400 "$STATE"
  if [ -e "$STATE/.open-decision-reminders" ]; then
    chmod 0700 "$STATE"
    pass "a listed ledger whose lookup fails alarms without replacing it (unsearchable case skipped: this user can search a mode-0400 directory)"
    return 0
  fi
  OPEN_DECISION_ERROR=
  if open_decision_reminder_tick 1300; then
    chmod 0700 "$STATE"
    fail "an unsearchable state directory's ledger was read as absent"
  fi
  chmod 0700 "$STATE"
  [ "$OPEN_DECISION_ERROR" = "$STATE/.open-decision-reminders is listed but cannot be looked up" ] \
    || fail "an unsearchable state directory did not name its ledger: $OPEN_DECISION_ERROR"
  pass "a listed ledger whose lookup fails alarms without replacing it"
}

test_timed_split_records() {
  local record cut full expected actual size
  # Byte splits cover verbs, time and key tokens, UTF-8 and embedded NULs.
  # Complete-fold output is the oracle; no implementation text is inspected.
  for record in opening resolution; do
    printf 'blocked [at=1000] [key=api]: caf\303\251\000 ok\n' > "$TMP_ROOT/open-line"
    if [ "$record" = opening ]; then
      cp "$TMP_ROOT/open-line" "$TMP_ROOT/line"
    else
      printf 'resolved [at=1200] [key=api]: caf\303\251\000 ok\n' > "$TMP_ROOT/line"
    fi
    size=$(wc -c < "$TMP_ROOT/line")
    cut=1
    while [ "$cut" -lt "$size" ]; do
      reset_case
      : > "$STATE/worker.status"
      [ "$record" != resolution ] || cat "$TMP_ROOT/open-line" >> "$STATE/worker.status"
      dd if="$TMP_ROOT/line" bs=1 count="$cut" 2>/dev/null >> "$STATE/worker.status"
      actual=$(status_open_decisions_incremental "$STATE/worker.status" '' timed) || fail "split fold failed"
      if [ "$record" = opening ]; then
        [ -z "$actual" ] || fail "partial opening acted before newline at $cut"
      else
        [ -n "$actual" ] || fail "partial resolution acted before newline at $cut"
      fi
      dd if="$TMP_ROOT/line" bs=1 skip="$cut" 2>/dev/null >> "$STATE/worker.status"
      actual=$(status_open_decisions_incremental "$STATE/worker.status" '' timed) || fail "completion failed"
      full=$(status_open_decisions "$STATE/worker.status")
      expected=$(printf '%s' "$actual" | cut -f1,2,4-)
      [ "$expected" = "$full" ] || fail "$record split $cut disagreed with complete fold: $actual / $full"
      assert_grep "offset=$(wc -c < "$STATE/worker.status" | tr -d ' ')" "$STATE/.worker.timed-open-decisions-cursor" "$record split $cut did not advance the timed cursor to the end"
      cut=$((cut + 1))
    done
  done
  pass "every byte split of openings and resolutions retains incomplete UTF-8/NUL tails and converges"
}

test_old_timed_cursor_is_refolded() {
  reset_case
  printf 'blocked [at=1000] [key=api]: help\n' > "$STATE/worker.status"
  # A v1 timed cursor could have skipped an opening and falsely held no keys.
  printf 'version=%s:%s:timed\noffset=%s\nident=%s\n' "$FM_OPEN_DECISIONS_FOLD_VERSION" \
    "$(_fm_status_kind "$STATE/worker.status")" "$(wc -c < "$STATE/worker.status" | tr -d ' ')" \
    "$(_fm_open_decisions_file_ident "$STATE/worker.status")" > "$STATE/.worker.timed-open-decisions-cursor"
  [ "$(status_open_decisions_incremental "$STATE/worker.status" '' timed)" = $'api\tblocked\t1000\thelp' ] \
    || fail "old damaged timed cursor was trusted"
  pass "the old timed cursor format is invalidated and reconstructed"
}

test_ledger_failure_cannot_flood() {
  local now failed=0
  reset_case
  enable
  printf 'blocked [at=1000] [key=api]: help\n' > "$STATE/worker.status"
  fm_wake_append check unrelated 'check: preserve me' || fail "seed queue failed"
  # The first ledger write (preflight) succeeds; replacement becomes persistently
  # unavailable only AFTER the due wake has reached the real queue.
  # shellcheck disable=SC2329 # Called by the sourced watcher's ledger write.
  _fm_atomic_replace() {
    if [ "$2" = "$STATE/.open-decision-reminders" ]; then
      [ "$failed" = 0 ] || return 1
      case "$(queue_keys)" in *'open-decision:worker:api'*) failed=1; return 1 ;; esac
    fi
    command mv -f -- "$1" "$2"
  }
  for now in 1200 1300 1400; do
    OPEN_DECISION_TICK_LAST=
    open_decision_reminder_check "$now" || fail "ledger failure stopped other checks"
  done
  expect_wakes 3 "persistent replacement failure flooded reminders or lost the alarm"
  [ "$(queue_keys)" = 'check unrelated
check open-decision:worker:api
check open-decision-reminders' ] || fail "unrelated wakes were changed"
  # Repair storage. At-least-once publication permits one duplicate of the
  # uncommitted last key on recovery, then its normal backoff applies.
  # shellcheck disable=SC2329 # Called by the sourced watcher's ledger write.
  _fm_atomic_replace() { command mv -f -- "$1" "$2"; }
  OPEN_DECISION_TICK_LAST=
  open_decision_reminder_check 1450 || fail "ledger recovery failed"
  expect_wakes 4 "recovery did not deliver the uncommitted key"
  open_decision_reminder_tick 1549 || fail "backoff tick failed"
  expect_wakes 4 "recovery lost first backoff"
  open_decision_reminder_tick 1550 || fail "due tick failed"
  expect_wakes 5 "backoff did not resume"
  assert_grep $'worker\tapi\t1000\t1550\t200' "$STATE/.open-decision-reminders" "recovered backoff was not committed to the ledger"
  pass "persistent ledger replacement failure is visible and cannot flood even across restarts"
}

test_partial_queue_failure_preserves_backoff() {
  reset_case
  enable
  printf 'blocked [at=1000] [key=one]: help\nblocked [at=1010] [key=two]: help\n' > "$STATE/worker.status"
  # Keep the actual queue implementation, but fail publication of the second
  # key at the public queue boundary. Alarm publication remains available.
  eval "$(declare -f fm_wake_append | command sed '1s/fm_wake_append/real_wake_append/')"
  # shellcheck disable=SC2329 # Called by open_decision_reminder_check.
  fm_wake_append() {
    [ "$2" != open-decision:worker:two ] || return 1
    real_wake_append "$@"
  }
  open_decision_reminder_check 1200 || fail "partial publication stopped the check"
  expect_wakes 2 "first key or failure alarm missing"
  assert_grep $'worker\tone\t1000\t1200\t100' "$STATE/.open-decision-reminders" "the delivered first key lost its committed backoff"
  # shellcheck disable=SC2329 # Called by open_decision_reminder_check.
  fm_wake_append() { real_wake_append "$@"; }
  # shellcheck disable=SC2034 # read by open_decision_reminder_check
  OPEN_DECISION_TICK_LAST=
  open_decision_reminder_check 1250 || fail "partial queue recovery failed"
  expect_wakes 3 "already delivered first key was repeated"
  assert_grep $'worker\ttwo\t1010\t1250\t100' "$STATE/.open-decision-reminders" "the recovered second key was not committed with its own backoff"
  pass "a later queue failure retains earlier keys' committed backoff"
}

test_enlarged_ledger_write_cannot_flood() {
  local growth seed start now recover next want_recovered want_next
  # Model an allocation boundary: ledger bytes no longer than the committed
  # ledger still write, a larger post-delivery ledger never does. Queue appends
  # and every other write stay available.
  eval "$(declare -f open_decision_ledger_prepare | command sed '1s/open_decision_ledger_prepare/real_ledger_prepare/')"
  fault_enlarged_ledger() {
    # shellcheck disable=SC2329 # Called by the sourced watcher's ledger write.
    open_decision_ledger_prepare() {
      if [ -f "$1" ] && [ "${#2}" -gt "$(wc -c < "$1")" ]; then
        OPEN_DECISION_ERROR="ledger $1 could not be written"
        return 1
      fi
      real_ledger_prepare "$@"
    }
  }
  for growth in timestamp delay; do
    reset_case
    enable
    printf 'blocked [at=1000] [key=api]: help\n' > "$STATE/worker.status"
    if [ "$growth" = timestamp ]; then
      # A first reminder turns last=0 into a ten-digit-scale epoch.
      export FM_OPEN_DECISION_BACKOFF_MAX_SECS=400
      open_decision_reminder_tick 1050 || fail "$growth seed failed: $OPEN_DECISION_ERROR"
      start=1200; recover=1450; next=1550
      want_recovered=$'worker\tapi\t1000\t1450\t100'; want_next=$'worker\tapi\t1000\t1550\t200'
    else
      # A capped doubling turns delay=800 into 1600.
      export FM_OPEN_DECISION_BACKOFF_MAX_SECS=1600
      printf 'worker\tapi\t1000\t1200\t800\n' > "$STATE/.open-decision-reminders"
      start=2000; recover=2250; next=3850
      want_recovered=$'worker\tapi\t1000\t2250\t1600'; want_next=$'worker\tapi\t1000\t3850\t1600'
    fi
    seed=$(cat "$STATE/.open-decision-reminders")
    fm_wake_append check unrelated 'check: preserve me' || fail "$growth seed queue failed"
    fault_enlarged_ledger
    # Each tick is a fresh watcher process: no memory but the ledger and cursor.
    for now in "$start" $((start + 100)) $((start + 200)); do
      OPEN_DECISION_TICK_LAST=
      open_decision_reminder_check "$now" || fail "$growth ledger failure stopped other checks"
    done
    [ "$(queue_keys)" = 'check unrelated
check open-decision-reminders' ] || fail "$growth: an unwritable post-delivery ledger reissued the reminder: $(queue_keys)"
    [ "$seed" = "$(cat "$STATE/.open-decision-reminders")" ] || fail "$growth changed the ledger while failing"
    case "$(cat "$STATE/.open-decision-reminders.error")" in
      "ledger $STATE/.open-decision-reminders could not be written") ;;
      *) fail "$growth did not record its ledger failure: $(cat "$STATE/.open-decision-reminders.error")" ;;
    esac
    # Storage recovers: the reminder is delivered once and its backoff resumes.
    # shellcheck disable=SC2034 # Read by the sourced watcher's check.
    OPEN_DECISION_TICK_LAST=
    eval "$(declare -f real_ledger_prepare | command sed '1s/real_ledger_prepare/open_decision_ledger_prepare/')"
    open_decision_reminder_check "$recover" || fail "$growth recovery failed"
    expect_wakes 3 "$growth recovery did not deliver the reminder exactly once"
    assert_grep "$want_recovered" "$STATE/.open-decision-reminders" "$growth recovery did not commit the delivered reminder"
    [ ! -e "$STATE/.open-decision-reminders.error" ] || fail "$growth recovery kept its error"
    open_decision_reminder_tick $((next - 1)) || fail "$growth backoff tick failed: $OPEN_DECISION_ERROR"
    expect_wakes 3 "$growth recovery lost its backoff"
    open_decision_reminder_tick "$next" || fail "$growth due tick failed: $OPEN_DECISION_ERROR"
    expect_wakes 4 "$growth backoff did not resume"
    assert_grep "$want_next" "$STATE/.open-decision-reminders" "$growth resumed backoff was not committed"
  done
  pass "a ledger that fails only for its larger post-delivery bytes never reissues a reminder, across restarts, and recovers with backoff"
}

test_tick_beats_per_log() {
  # A cold tick folds every log from byte 0, so it must keep the wedge
  # watchdog's beacon fresh between logs. This runs in run_case's subshell,
  # so the counting beat stays inside this case.
  local beats=0
  # shellcheck disable=SC2329 # invoked indirectly through open_decision_reminder_tick
  count_beat() { beats=$((beats + 1)); }
  reset_case
  enable
  printf 'blocked [at=1000] [key=one]: help\n' > "$STATE/a.status"
  printf 'note: nothing open\n' > "$STATE/b.status"
  printf 'blocked [at=1000] [key=two]: help\n' > "$STATE/c.status"
  open_decision_reminder_tick 1200 count_beat || fail "a cold three-log tick failed: $OPEN_DECISION_ERROR"
  [ "$beats" -ge 3 ] || fail "a cold three-log tick beat $beats times, want one per log"
  pass "a tick beats the watcher beacon once per status log it folds"
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

# An expansion error such as $((10#soon)) makes bash abandon the whole
# top-level command it ran in, so a case that hit one would end silently and
# the file would still exit 0. Each case runs in its own subshell, and one that
# ends without passing fails the file.
run_case() {  # <case>
  local rc=0
  ( "$1" ) || rc=$?
  [ "$rc" -eq 0 ] || fail "$1 ended without passing (rc=$rc)"
}

run_case test_disabled
run_case test_every_due_key_and_backoff
run_case test_due_keys_queue_oldest_first
run_case test_backoff_survives_a_restart
run_case test_numeric_keys_are_distinct
run_case test_numeric_tasks_are_distinct
run_case test_resolution_and_reopen
run_case test_wait_exemptions
run_case test_hold_reader_cannot_eat_the_open_set
run_case test_unknown_times_and_keyless
run_case test_timed_fold_is_incremental_and_leaves_the_drain_cursor
run_case test_invalid_settings_alarm_once
run_case test_unreadable_ledger_alarms
run_case test_unwritable_marker_says_it_repeats
run_case test_own_parent_channel_is_not_reminded
run_case test_alarm_retries_failed_publication
run_case test_alarm_interrupted_receipt_retries
run_case test_timed_read_failures_are_unknown
run_case test_timed_failure_after_checkpoint_resumes
run_case test_deduplicated_alarm_still_wakes_for_queued_keys
run_case test_bad_status_paths_alarm
run_case test_unlistable_state_dir_alarms
run_case test_failed_state_listing_alarms
run_case test_state_path_not_a_directory_alarms
run_case test_listed_log_lookup_failure_alarms
run_case test_listed_ledger_lookup_failure_alarms
run_case test_timed_split_records
run_case test_old_timed_cursor_is_refolded
run_case test_ledger_failure_cannot_flood
run_case test_partial_queue_failure_preserves_backoff
run_case test_enlarged_ledger_write_cannot_flood
run_case test_tick_beats_per_log
run_case test_cadence_gate
run_case test_timed_cursor_retirement
run_case test_real_watcher_wakes_on_an_overdue_key
