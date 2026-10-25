#!/usr/bin/env bash
# The watcher's dated-rule step (docs/dated-rule-schedule.md). Drill V-j: a
# rule 14 days out reaches its owner on the same watcher pass, because the
# check raises it in the owner store just before the alert-store tick projects
# it onto state/dated-rules.status, whose new line wakes the home. A problem of
# the check itself (here an unusable parent record) wakes as check: dated-rules.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECKPOINT="$ROOT/bin/fm-watch-checkpoint.sh"
TMP_ROOT=$(fm_test_tmproot fm-watch-dated-rules-tests)

# make_home <name> <home-id> <days-out>: a home whose schedule holds one rule
# <days-out> UTC days from today.
make_home() {
  local home="$TMP_ROOT/$1" date
  mkdir -p "$home/state/dated-rules" "$home/config"
  date=$(python3 -c 'import datetime,sys; print(datetime.datetime.now(datetime.timezone.utc).date() + datetime.timedelta(days=int(sys.argv[1])))' "$3")
  cat > "$home/state/dated-rules/main.json" <<EOF
{"format": "dated-rule-schedule/v1", "home": "$2", "publisher": "test", "revision": 1,
 "published_at": "2026-10-01T00:00:00Z",
 "rows": [{"id": "grace.1", "rule": "grace", "owner": "$2", "date": "$date",
           "what": "the grace period ends", "state": "scheduled"}]}
EOF
  printf '%s\n' "$home"
}

run_checkpoint() {  # <home> <seconds>
  env FM_HOME="$1" FM_CHECK_TIMEOUT=30 FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=1 \
    "$CHECKPOINT" --seconds "$2" > "$1/checkpoint.out" 2>"$1/checkpoint.err"
}

test_rule_14_days_out_reaches_the_owner_in_one_pass() {
  local home status=0
  home=$(make_home vj main 14)
  run_checkpoint "$home" 15 || status=$?
  expect_code 0 "$status" "watcher checkpoint exit"
  assert_contains "$(cat "$home/state/dated-rules.status" 2>/dev/null)" "blocked [key=dated-rule.grace.1.14d]" \
    "the 14-day alarm was not projected onto the owner's status file"
  assert_contains "$(cat "$home/checkpoint.out")" "dated-rules" "the watcher did not wake on the projected alarm"
  pass "a rule 14 days out reaches its owner on the same watcher pass (V-j)"
}

test_watcher_wakes_on_a_check_problem() {
  local home status=0
  home=$(make_home problem mate-x 30)
  printf 'mate-x\n' > "$home/.fm-secondmate-home"
  run_checkpoint "$home" 15 || status=$?
  expect_code 0 "$status" "watcher checkpoint exit"
  assert_contains "$(cat "$home/checkpoint.out")" "check: dated-rules: " "the watcher did not wake on the check's problem"
  assert_contains "$(cat "$home/checkpoint.out")" "fm-secondmate-parent is missing or unusable" "the wake did not say what is wrong"
  pass "the watcher wakes on a dated-rules check problem"
}

test_recording_invalidation_and_dated_rule_problem_share_the_problem_wake() {
  local home status=0 out
  home=$(make_home problem-with-recording mate-x 30)
  printf 'mate-x\n' > "$home/.fm-secondmate-home"
  printf 'fixture-invalid\n' > "$home/state/.supervision-ticks.error"
  run_checkpoint "$home" 15 || status=$?
  expect_code 0 "$status" 'co-due recording and dated-rule checkpoint exit'
  out=$(cat "$home/checkpoint.out")
  assert_contains "$out" 'supervision tick recording invalid' 'dated-rule problem replaced the recording notice'
  assert_contains "$out" 'check: dated-rules: ' 'recording notice replaced the dated-rule problem'
  assert_contains "$out" 'fm-secondmate-parent is missing or unusable' 'combined wake lost the dated-rule diagnostic'
  assert_grep $'\tcheck\tsupervision-tick-recording\t' "$home/state/.wake-queue" 'recording notice was not durably queued'
  assert_grep $'\tcheck\tdated-rules\t' "$home/state/.wake-queue" 'dated-rule notice was not durably queued'
  pass 'co-due recording and dated-rule failures retain both queued notices and both printed reasons'
}

test_rule_14_days_out_reaches_the_owner_in_one_pass
test_watcher_wakes_on_a_check_problem
test_recording_invalidation_and_dated_rule_problem_share_the_problem_wake
