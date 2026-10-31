#!/usr/bin/env bash
# Behavior tests for bin/fm-park-churn.sh: three park resumes within an hour
# raise one alarm per task per UTC day, the check prints only new crossings,
# an unreadable record alarms instead of starting over, and sync installs the
# watcher check bound before it appears. Each case runs in its own fixture home.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-park-churn-tests)
CHURN="$ROOT/bin/fm-park-churn.sh"
DAY=86400

new_home() {  # <name>: a fixture home with a state directory, in $H
  H="$TMP_ROOT/$1"
  mkdir -p "$H/state"
}
churn() { FM_HOME="$H" "$CHURN" "$@"; }

case_crossing_alarms_once_a_day() {
  local base=$((20000 * DAY + 3600)) out e
  new_home crossing
  churn record t1 "$base" || fail "the first resume was not recorded"
  churn record t1 $((base + 1200)) || fail "the second resume was not recorded"
  assert_equals "" "$(churn check)" "two resumes within an hour are not churn"
  churn record t1 $((base + 2400)) || fail "the third resume was not recorded"
  out=$(churn check)
  assert_contains "$out" "park-churn: task t1 resumed from park 3 times within an hour" "three resumes within an hour alarm"
  assert_contains "$out" "fm-park.sh --help, \"Live waits\"" "the alarm points at the live-wait rule"
  assert_equals "" "$(churn check)" "the check prints a crossing only once"
  churn record t1 $((base + 3000)) || fail "a later resume was not recorded"
  assert_equals "" "$(churn check)" "a second crossing the same UTC day stays silent"
  churn record t1 $((base + DAY)) || fail "the next day's resume was not recorded"
  churn record t1 $((base + DAY + 60)) || fail "the next day's resume was not recorded"
  assert_equals "" "$(churn check)" "the next day needs its own three resumes"
  churn record t1 $((base + DAY + 120)) || fail "the next day's resume was not recorded"
  assert_contains "$(churn check)" "task t1 resumed from park 3 times" "a crossing on a new UTC day alarms again"
  pass "three resumes within an hour alarm once per task per UTC day, and the check prints only new crossings"

  new_home spaced
  for e in "$base" $((base + 1800)) $((base + 3600)); do
    churn record t2 "$e" || fail "a spaced resume was not recorded"
  done
  assert_equals "" "$(churn check)" "three resumes spanning a full hour are not churn"
  for e in "$base" $((base + 10)); do
    churn record t3 "$e" || fail "another task's resume was not recorded"
  done
  assert_equals "" "$(churn check)" "resumes of different tasks are counted apart"
  pass "resumes spread over an hour or across tasks do not alarm"
}

case_bad_records_alarm() {
  local base=$((20000 * DAY)) rc shape
  for shape in garbage dir; do
    new_home "bad-$shape"
    mkdir -p "$H/state/.park-churn"
    case "$shape" in
      garbage) printf 'not an epoch\n' > "$H/state/.park-churn/tb" ;;
      dir) mkdir "$H/state/.park-churn/tb" ;;
    esac
    rc=0; churn record tb "$base" 2>/dev/null || rc=$?
    expect_code 1 "$rc" "a $shape resume record refuses"
    assert_contains "$(churn check)" "park-churn: task tb: its resume record $H/state/.park-churn/tb" "a $shape resume record alarms, naming the file"
  done
  new_home bad-path
  printf 'x\n' > "$H/state/.park-churn"
  rc=0; churn record tb "$base" 2>/dev/null || rc=$?
  expect_code 1 "$rc" "a churn path that is not a directory refuses the record"
  assert_contains "$(churn check)" "$H/state/.park-churn is not a directory" "the check names a churn path that is not a directory"
  new_home empty
  assert_equals "" "$(churn check)" "a home with no resumes yet is silent"
  mkdir -p "$H/state/.park-churn"
  assert_equals "" "$(churn check)" "an empty churn directory is silent"
  : > "$H/state/.park-churn/te.new"
  assert_contains "$(churn check)" "cannot read the churn alarm $H/state/.park-churn/te.new" "an empty alarm file is reported, not dropped"
  pass "an unreadable record or churn path alarms, and an empty one is silent"
}

case_sync_installs_bound_check() {
  local out base=$((20000 * DAY)) e
  new_home sync
  out=$(churn sync 2>&1) || fail "sync failed: $out"
  assert_present "$H/state/park-churn.check.sh" "sync installs the check"
  assert_present "$H/state/park-churn.check-trust" "sync registers the check"
  out=$(churn sync 2>&1) || fail "a repeated sync failed: $out"
  assert_equals "" "$out" "a repeated sync is silent"
  assert_equals "" "$("$H/state/park-churn.check.sh")" "the installed check is silent with no churn"
  for e in "$base" $((base + 1)) $((base + 2)); do
    churn record t1 "$e" || fail "a resume was not recorded"
  done
  assert_contains "$("$H/state/park-churn.check.sh")" "task t1 resumed from park 3 times" "the installed check prints a new crossing"
  churn disarm || fail "disarm failed"
  assert_absent "$H/state/park-churn.check.sh" "disarm retires the check"
  pass "sync installs and registers the watcher check, and disarm retires it"
}

case_crossing_alarms_once_a_day
case_bad_records_alarm
case_sync_installs_bound_check
