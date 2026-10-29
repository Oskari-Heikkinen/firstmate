#!/usr/bin/env bash
# fm-ci-errors.sh: one run with many failed shards lists a row for every failed
# job and every failing test, each classed infra (no runner, cancelled before
# its first step, runner lost), flaky (on the flake list), real or unknown
# (log unreadable, empty, no failure in it, an unparsable marker), with its
# evidence and job URL; an unfinished run waits with 75, an unreadable or
# partial reading refuses with 1 and replaces nothing, and a rerun rewrites the
# same list. The forge is a fake gh serving fixture files.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
T=$(fm_test_tmproot fm-ci-errors)
TOOL=$ROOT/bin/fm-ci-errors.sh
REPO=acme/widgets
unset FM_HOME

mkdir -p "$T/fakebin"
cat > "$T/fakebin/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FAKE_GH/calls"
d=$FAKE_GH
case "$*" in
  "api repos/$FAKE_REPO/actions/runs/"*/jobs*)
    [ ! -f "$d/jobs.fail" ] || { echo 'gh: Server Error (HTTP 502)' >&2; exit 1; }
    cat "$d/jobs.json" ;;
  "api --paginate repos/$FAKE_REPO/actions/runs/"*/jobs*)
    [ ! -f "$d/jobs.fail" ] || { echo 'gh: Server Error (HTTP 502)' >&2; exit 1; }
    cat "$d/jobs.json" ;;
  "api repos/$FAKE_REPO/actions/runs/"*)
    [ ! -f "$d/run.fail" ] || { echo 'gh: Not Found (HTTP 404)' >&2; exit 1; }
    cat "$d/run.json" ;;
  "api repos/$FAKE_REPO/check-runs/"*/annotations)
    j=${2#repos/"$FAKE_REPO"/check-runs/}; j=${j%/annotations}
    if [ -f "$d/ann-$j.json" ]; then cat "$d/ann-$j.json"; else echo '[]'; fi ;;
  "run view --job "*" --log -R $FAKE_REPO")
    [ ! -f "$d/log-$4.fail" ] || { echo 'failed to get run log: log not found' >&2; exit 1; }
    cat "$d/log-$4" ;;
  *) echo "fake gh: unexpected call: $*" >&2; exit 9 ;;
esac
SH
chmod +x "$T/fakebin/gh"
export PATH="$T/fakebin:$PATH" FAKE_REPO=$REPO

URL=https://github.com/$REPO/actions/runs/100
STEPS_RAN='[{"name":"Set up job","number":1,"status":"completed","conclusion":"success","started_at":"t"},
  {"name":"Run tests","number":2,"status":"completed","conclusion":"failure","started_at":"t"}]'

new_world() {
  F=$T/$1
  mkdir -p "$F"
  : >"$F/jobs.ndjson"
  : >"$F/calls"
  export FAKE_GH=$F
  run_json completed failure
}

run_json() {  # <status> <conclusion>
  printf '{"id":100,"run_attempt":2,"status":"%s","conclusion":"%s","name":"CI","head_branch":"ci/t","head_sha":"abc","html_url":"%s"}\n' \
    "$1" "$2" "$URL" >"$F/run.json"
}

job() {  # <id> <name> <conclusion> <runner> [steps-json]
  jq -nc --argjson id "$1" --arg name "$2" --arg c "$3" --arg r "$4" --argjson steps "${5:-$STEPS_RAN}" \
    --arg url "$URL/job/$1" \
    '{id: $id, name: $name, status: "completed", conclusion: $c, runner_name: $r, steps: $steps, html_url: $url}' \
    >>"$F/jobs.ndjson"
}

# Two pages, as `gh api --paginate` prints them: concatenated objects, each
# with the run's total_count.
pages() {  # [total_count]
  local total
  total=${1:-$(wc -l <"$F/jobs.ndjson" | tr -d ' ')}
  jq -sc --argjson t "$total" '{total_count: $t, jobs: .[0:2]}, {total_count: $t, jobs: .[2:]}' \
    "$F/jobs.ndjson" >"$F/jobs.json"
}

# A job log as `gh run view --job --log` prints it: job and step columns, a
# BOM before the first line, a timestamp on each line.
glog() {  # <job-id> <job-name> <step>; lines on stdin
  local first=1 line
  while IFS= read -r line; do
    if [ "$first" = 1 ]; then
      printf '%s\t%s\t\357\273\2772026-10-29T16:35:05.1234567Z %s\r\n' "$2" "$3" "$line"
      first=0
    else
      printf '%s\t%s\t2026-10-29T16:35:06.1234567Z %s\r\n' "$2" "$3" "$line"
    fi
  done >>"$F/log-$1"
}

run_tool() {  # <args...>
  set +e
  OUTPUT=$("$TOOL" "$@" 2>"$T/stderr")
  RC=$?
  set -e
}

field() {  # <jq filter over errors.json>
  jq -r "$1" "$OUT/errors.json"
}

row_of() {  # <kind> <job> [test] -> "class reason"
  jq -r --arg k "$1" --arg j "$2" --arg t "${3:-}" \
    '[.rows[] | select(.kind == $k and .job == $j and .test == $t) | "\(.class) \(.reason)"] | join(";")' \
    "$OUT/errors.json"
}

# --- one run, every class, several shards ---------------------------------

new_world all
job 1 'Plan the tiered run' success 'GitHub Actions 1'
job 2 'Herdr' skipped ''
# --jobs 4: both scripts begin, then each one's output is replayed right
# before its own FM_TEST_END.
job 11 'Behavior shard 1' failure 'GitHub Actions 11'
glog 11 'Behavior shard 1' 'Run tests' <<'EOF'
##[group]Run bin/fm-test-run.sh --shard 1/8
bin/fm-test-run.sh --shard 1/8
##[endgroup]
FM_TEST_BEGIN 2026-10-29T16:35:05Z tests/fm-a.test.sh family=x expected_gate_skip=none
FM_TEST_BEGIN 2026-10-29T16:35:05Z tests/fm-b.test.sh family=x expected_gate_skip=none
ok - b one
not ok - b output that belongs to b only
FM_TEST_END 2026-10-29T16:35:06Z tests/fm-b.test.sh exit=0 duration_ms=5 gate_skip=false
ok - a first
not ok - a lost its receipt (expected '1', got '2')
FM_TEST_END 2026-10-29T16:35:07Z tests/fm-a.test.sh exit=1 duration_ms=9 gate_skip=false
FM_TEST_SUMMARY total=2 failed=1 skipped_gate=0 duration_ms=14
##[error]Process completed with exit code 1.
EOF
job 12 'Behavior shard 2' failure 'GitHub Actions 12'
glog 12 'Behavior shard 2' 'Run tests' <<'EOF'
FM_TEST_BEGIN 2026-10-29T16:35:05Z tests/fm-watcher-lock.test.sh family=x expected_gate_skip=none
not ok - the lock holder was not seen in time
FM_TEST_END 2026-10-29T16:35:06Z tests/fm-watcher-lock.test.sh exit=1 duration_ms=5 gate_skip=false
##[error]Process completed with exit code 1.
EOF
job 13 'Behavior shard 3' failure 'GitHub Actions 13'
glog 13 'Behavior shard 3' 'Run tests' <<'EOF'
FM_TEST_BEGIN 2026-10-29T16:35:05Z tests/fm-supervision-host.test.sh family=x expected_gate_skip=none
not ok - host beacon late
FM_TEST_END 2026-10-29T16:35:06Z tests/fm-supervision-host.test.sh exit=1 duration_ms=5 gate_skip=false
FM_TEST_BEGIN 2026-10-29T16:35:06Z tests/fm-views.test.sh family=x expected_gate_skip=none
ok - first case
FAIL: test_summary_equals_legacy (checks.Compat.test_summary_equals_legacy)
    self.assertEqual(a, b)
AssertionError: Lists differ: [] != ['mate']
FM_TEST_END 2026-10-29T16:35:07Z tests/fm-views.test.sh exit=1 duration_ms=5 gate_skip=false
##[error]Process completed with exit code 1.
EOF
job 14 'Native summary stat (Darwin)' cancelled '' '[]'
job 15 'Behavior shard 4' cancelled 'GitHub Actions 15' \
  '[{"name":"Set up job","number":1,"status":"completed","conclusion":"success","started_at":"t"},
    {"name":"Run actions/checkout@v6","number":2,"status":"queued","conclusion":null,"started_at":null}]'
job 16 'Behavior shard 5' failure 'GitHub Actions 16'
printf '[{"annotation_level":"failure","message":"The hosted runner: GitHub Actions 16 lost communication with the server."}]\n' \
  >"$F/ann-16.json"
job 17 'Behavior shard 6' cancelled 'GitHub Actions 17'
printf '[{"annotation_level":"failure","message":"The job running on runner GitHub Actions 17 has exceeded the maximum execution time of 30 minutes."},
  {"annotation_level":"failure","message":"Process completed with exit code 1."}]\n' >"$F/ann-17.json"
glog 17 'Behavior shard 6' 'Run tests' <<'EOF'
FM_TEST_BEGIN 2026-10-29T16:35:05Z tests/fm-hang.test.sh family=x expected_gate_skip=none
FM_TEST_BEGIN 2026-10-29T16:35:05Z tests/fm-quick.test.sh family=x expected_gate_skip=none
ok - quick
FM_TEST_END 2026-10-29T16:35:06Z tests/fm-quick.test.sh exit=0 duration_ms=5 gate_skip=false
##[error]The operation was canceled.
EOF
job 18 'Lint changed' failure 'GitHub Actions 18'
printf '\033[36;1mx\033[0m\n' | glog 18 'Lint changed' 'Set up job'
glog 18 'Lint changed' 'Lint changed' <<'EOF'
##[group]Run bin/fm-lint.sh --changed
bin/fm-lint.sh --changed
shell: /usr/bin/bash -e {0}
##[endgroup]
fm-lint.sh: ShellCheck 0.11.0 (pinned 0.11.0)

In bin/fm-x.sh line 3:
  echo x | other
       ^-- SC2086 (info): Double quote to prevent globbing and word splitting.
##[error]Process completed with exit code 1.
EOF
job 19 'Behavior shard 7' failure 'GitHub Actions 19'
: >"$F/log-19.fail"
job 20 'Behavior shard 8' failure 'GitHub Actions 20'
glog 20 'Behavior shard 8' 'Run tests' <<'EOF'
FM_TEST_BEGIN 2026-10-29T16:35:05Z tests/fm-c.test.sh family=x expected_gate_skip=none
ok - c
FM_TEST_END 2026-10-29T16:35:06Z tests/fm-c.test.sh exit=0 duration_ms=5 gate_skip=false
the log stops here
EOF
job 21 'Behavior shard 9' failure 'GitHub Actions 21'
glog 21 'Behavior shard 9' 'Run tests' <<'EOF'
FM_TEST_BEGIN 2026-10-29T16:35:05Z tests/fm-d.test.sh family=x expected_gate_skip=none
FM_TEST_END 2026-10-29T16:35:06Z tests/fm-d.test.sh exit= duration_ms=5 gate_skip=false
##[error]Process completed with exit code 1.
EOF
job 22 'Behavior shard 10' failure 'GitHub Actions 22'
: >"$F/log-22"
pages
# A fixture flake list, so the repository's own list can shrink as flakes are
# fixed without changing this case.
printf '%s\n' 'tests/fm-watcher-lock.test.sh fixture flake' \
  'tests/fm-supervision-host.test.sh fixture flake' >"$T/flakes"

OUT=$T/out-all
run_tool --repo "$REPO" --out "$OUT" --flakes "$T/flakes" 100
expect_code 0 "$RC" "all classes: exit"
assert_equals "fm-ci-errors/v1 run=100 attempt=2 rows=18 real=7 flaky=3 infra=3 unknown=5 list=$OUT/errors.md" \
  "$OUTPUT" "all classes: summary line"
assert_equals '' "$(cat "$T/stderr")" "all classes: stderr stays empty"
assert_equals 'fm-ci-errors/v1 100 2' "$(field '"\(.schema) \(.run.id) \(.run.attempt)"')" "all classes: schema and run"
pass "a run with every class lists all 18 rows and prints one summary line"

assert_equals 'real tests-failed' "$(row_of job 'Behavior shard 1')" "shard 1 job"
assert_equals 'real test-failed' "$(row_of test 'Behavior shard 1' tests/fm-a.test.sh)" "shard 1 test a"
assert_equals '' "$(row_of test 'Behavior shard 1' tests/fm-b.test.sh)" "a passing script gets no row"
assert_equals "exit=1|not ok - a lost its receipt (expected '1', got '2')" \
  "$(field '.rows[] | select(.test == "tests/fm-a.test.sh") | .evidence | join("|")')" \
  "a script's evidence is its own replayed output, never another script's"
assert_equals "$URL/job/11" "$(field '.rows[] | select(.test == "tests/fm-a.test.sh") | .url')" "test row URL"
assert_equals 'tests/fm-a.test.sh' \
  "$(field '.rows[] | select(.kind == "job" and .job == "Behavior shard 1") | .evidence[0]' | sed 's/^failing tests: //')" \
  "the job row names its failing tests"
pass "a failing test is real, with its own not ok line as evidence, under --jobs interleaving"

assert_equals 'flaky tests-failed' "$(row_of job 'Behavior shard 2')" "flake-only job"
assert_equals 'flaky known-flake' "$(row_of test 'Behavior shard 2' tests/fm-watcher-lock.test.sh)" "flake test"
assert_equals 'real tests-failed' "$(row_of job 'Behavior shard 3')" "a real failure beside a flake makes the job real"
assert_equals 'flaky known-flake' "$(row_of test 'Behavior shard 3' tests/fm-supervision-host.test.sh)" "second flake"
assert_equals 'real test-failed' "$(row_of test 'Behavior shard 3' tests/fm-views.test.sh)" "unittest failure"
assert_equals 'exit=1|FAIL: test_summary_equals_legacy (checks.Compat.test_summary_equals_legacy)|AssertionError: Lists differ: [] != ['"'mate'"']' \
  "$(field '.rows[] | select(.test == "tests/fm-views.test.sh") | .evidence | join("|")')" \
  "unittest FAIL and AssertionError lines are the evidence"
pass "a test on the flake list is flaky, and a job with a real failure beside it stays real"

assert_equals 'infra no-runner' "$(row_of job 'Native summary stat (Darwin)')" "Darwin job with no runner"
assert_equals 'infra cancelled-before-first-step' "$(row_of job 'Behavior shard 4')" "cancelled before first step"
assert_equals 'infra runner-lost' "$(row_of job 'Behavior shard 5')" "runner lost"
assert_equals 'The hosted runner: GitHub Actions 16 lost communication with the server.' \
  "$(field '.rows[] | select(.job == "Behavior shard 5") | .evidence | join("|")')" "runner-lost evidence"
for j in 14 15 16; do
  assert_no_grep "run view --job $j " "$F/calls" "infra job $j: its log is not fetched"
done
pass "a job with no runner, one cancelled before its first step and a lost runner are infra"

assert_equals 'real tests-failed' "$(row_of job 'Behavior shard 6')" "timed-out job"
assert_equals 'real test-cut-off' "$(row_of test 'Behavior shard 6' tests/fm-hang.test.sh)" "cut-off script"
assert_equals '' "$(row_of test 'Behavior shard 6' tests/fm-quick.test.sh)" "a finished script in a timed-out job gets no row"
assert_contains "$(field '.rows[] | select(.kind == "job" and .job == "Behavior shard 6") | .evidence | join("|")')" \
  'exceeded the maximum execution time' "timeout annotation is the job's evidence"
pass "a job that ran out of time is real and lists the script it cut off"

assert_equals 'real step-failed' "$(row_of job 'Lint changed')" "lint job"
assert_equals 'fm-lint.sh: ShellCheck 0.11.0 (pinned 0.11.0)|In bin/fm-x.sh line 3:|  echo x | other|       ^-- SC2086 (info): Double quote to prevent globbing and word splitting.|##[error]Process completed with exit code 1.' \
  "$(field '.rows[] | select(.job == "Lint changed") | .evidence | join("|")')" \
  "a step failure's evidence is that step's own output, colour codes and headers stripped"
pass "a job that failed outside tests is real, with its failing step's output"

assert_equals 'unknown log-unreadable' "$(row_of job 'Behavior shard 7')" "unreadable log"
assert_contains "$(field '.rows[] | select(.job == "Behavior shard 7") | .evidence | join("|")')" \
  'log not found' "unreadable-log evidence names the forge error"
assert_equals 'unknown failure-not-in-log' "$(row_of job 'Behavior shard 8')" "no failure in log"
assert_equals 'unknown tests-failed' "$(row_of job 'Behavior shard 9')" "unparsable marker job"
assert_equals 'unknown unparsable-marker' "$(row_of test 'Behavior shard 9' tests/fm-d.test.sh)" "unparsable marker test"
assert_equals 'unknown log-empty' "$(row_of job 'Behavior shard 10')" "empty log"
assert_equals '' "$(row_of job 'Plan the tiered run')$(row_of job Herdr)" "success and skipped jobs get no row"
pass "an unreadable or empty log, a log with no failure and an unparsable marker are unknown, never skipped"

assert_grep "- Run: $URL" "$OUT/errors.md" "errors.md names the run URL"
assert_grep '- Rows: 18 (real 7, flaky 3, infra 3, unknown 5)' "$OUT/errors.md" "errors.md counts"
assert_grep '- Next: read every real and unknown row' "$OUT/errors.md" "errors.md next step"
assert_grep "| test | Behavior shard 1 | tests/fm-a.test.sh | real | test-failed | exit=1<br>not ok - a lost its receipt (expected '1', got '2') | $URL/job/11 |" \
  "$OUT/errors.md" "errors.md test row"
assert_grep '  echo x \| other' "$OUT/errors.md" "a pipe in evidence is escaped in the table"
assert_equals 18 "$(grep -c "| $URL/job/" "$OUT/errors.md")" "errors.md has one table row per row"
assert_equals 'job test' "$(grep -F '| Behavior shard 1 |' "$OUT/errors.md" | cut -d'|' -f2 | tr -d ' ' | tr '\n' ' ' | sed 's/ $//')" \
  "a job's row comes before its test rows"
[ -s "$OUT/logs/11.log" ] || fail "the fetched log of job 11 is kept"
while IFS= read -r call; do
  case $call in
    *"repos/$REPO/"*|*"-R $REPO") ;;
    *) fail "a gh call does not name the repository: $call" ;;
  esac
done <"$F/calls"
pass "errors.md carries the header, counts, next step and one escaped row per entry; every gh call names the repo"

# --- a rerun rewrites the same list ---------------------------------------

jq -S 'del(.run.read_at)' "$OUT/errors.json" >"$T/first.json"
run_tool --repo "$REPO" --out "$OUT" --flakes "$T/flakes" 100
expect_code 0 "$RC" "rerun: exit"
assert_equals "$(cat "$T/first.json")" "$(jq -S 'del(.run.read_at)' "$OUT/errors.json")" "rerun: same rows"
assert_equals 2 "$(grep -c ' written: rows=18 ' "$OUT/fm-ci-errors.log")" "rerun: the log gains one written line per run"
[ -z "$(find "$OUT" -name '.work.*')" ] || fail "rerun: no work directory is left behind"
pass "a rerun rewrites the same list and appends its own log lines"

# --- infra only, nothing failed -------------------------------------------

new_world infra
job 14 'Native summary stat (Darwin)' cancelled '' '[]'
job 1 'Native summary stat (Linux)' success 'GitHub Actions 1'
printf '[{"annotation_level":"failure","message":"The job was not acquired by Runner of type hosted even after multiple attempts"}]\n' \
  >"$F/ann-14.json"
pages
OUT=$T/out-infra
run_tool --repo "$REPO" --out "$OUT" 100
expect_code 0 "$RC" "infra only: exit"
assert_equals 'infra no-runner' "$(row_of job 'Native summary stat (Darwin)')" "infra only: Darwin row"
assert_grep "- Next: infra only: \`gh run rerun 100 --failed -R $REPO\` once, with no new push." "$OUT/errors.md" \
  "infra only: the next step is one rerun of the failed jobs"
pass "an infra-only run names the one rerun as its next step"

new_world green
run_json completed success
job 1 'Static checks' success 'GitHub Actions 1'
pages
OUT=$T/out-green
run_tool --repo "$REPO" --out "$OUT" 100
expect_code 0 "$RC" "green: exit"
assert_equals 0 "$(field .counts.rows)" "green: no rows"
assert_grep '- Next: nothing failed.' "$OUT/errors.md" "green: next step"
assert_no_grep '| Kind |' "$OUT/errors.md" "green: no table"
pass "a run with no failed job writes an empty list"

# --- waits and refusals replace nothing -----------------------------------

new_world refuse
job 11 'Behavior shard 1' failure 'GitHub Actions 11'
: >"$F/log-11"
pages
OUT=$T/out-refuse
mkdir -p "$OUT"
printf 'earlier list\n' >"$OUT/errors.md"

run_json in_progress ''
run_tool --repo "$REPO" --out "$OUT" 100
expect_code 75 "$RC" "in progress: exit"
assert_equals '' "$OUTPUT" "in progress: stdout"
assert_contains "$(cat "$T/stderr")" 'run 100 is in_progress; rerun once it has completed' "in progress: stderr"
assert_equals 'earlier list' "$(cat "$OUT/errors.md")" "in progress: errors.md untouched"
pass "an unfinished run waits with exit 75 and writes no list"

run_json completed failure
: >"$F/run.fail"
run_tool --repo "$REPO" --out "$OUT" 100
expect_code 1 "$RC" "run unreadable: exit"
assert_contains "$(cat "$T/stderr")" 'cannot read the run from acme/widgets: gh: Not Found (HTTP 404)' "run unreadable: stderr"
rm "$F/run.fail"
printf 'not json\n' >"$F/run.json"
run_tool --repo "$REPO" --out "$OUT" 100
expect_code 1 "$RC" "run malformed: exit"
assert_contains "$(cat "$T/stderr")" 'is not a run object' "run malformed: stderr"
run_json completed failure

: >"$F/jobs.fail"
run_tool --repo "$REPO" --out "$OUT" 100
expect_code 1 "$RC" "jobs unreadable: exit"
assert_contains "$(cat "$T/stderr")" "cannot read the run's jobs" "jobs unreadable: stderr"
rm "$F/jobs.fail"
pages 3
run_tool --repo "$REPO" --out "$OUT" 100
expect_code 1 "$RC" "partial jobs: exit"
assert_contains "$(cat "$T/stderr")" 'fewer jobs than its total_count' "partial jobs: stderr"
assert_equals 'earlier list' "$(cat "$OUT/errors.md")" "refusals: errors.md untouched"
assert_grep 'refused: ' "$OUT/fm-ci-errors.log" "refusals are logged"
pass "an unreadable, malformed or partial run or job reading refuses with exit 1 and replaces nothing"

pages
printf 'tests/fm-a.test.sh\n' >"$T/flakes-noreason"
printf 'fm-a reason\n' >"$T/flakes-badpath"
for bad in "$T/flakes-noreason" "$T/flakes-badpath" "$T/flakes-missing"; do
  run_tool --repo "$REPO" --out "$OUT" --flakes "$bad" 100
  expect_code 1 "$RC" "flake list $bad: exit"
  assert_contains "$(cat "$T/stderr")" "flake list $bad" "flake list $bad: stderr names it"
done
assert_equals 'earlier list' "$(cat "$OUT/errors.md")" "bad flake lists: errors.md untouched"
pass "a missing or malformed flake list refuses with exit 1"

for args in '' 'abc' '1 2' '--repo bad 100' '--bogus 100'; do
  # shellcheck disable=SC2086
  run_tool $args
  expect_code 2 "$RC" "usage '$args': exit"
done
run_tool --help
expect_code 0 "$RC" "--help: exit"
assert_contains "$OUTPUT" 'fm-ci-errors.sh [--repo OWNER/REPO]' "--help prints the usage"
pass "usage errors exit 2 and --help prints the header"

# --- defaults: the origin repository and FM_HOME --------------------------

C=$T/checkout
mkdir -p "$C/bin" "$C/tests"
cp "$TOOL" "$C/bin/"
cp "$ROOT/tests/known-flakes.list" "$C/tests/"
git -C "$C" init -q
git -C "$C" remote add origin git@github.com:acme/widgets.git
new_world defaults
job 11 'Behavior shard 1' failure 'GitHub Actions 11'
: >"$F/log-11"
pages
set +e
OUTPUT=$(FM_HOME=$T/home "$C/bin/fm-ci-errors.sh" 100 2>"$T/stderr")
RC=$?
set -e
expect_code 0 "$RC" "defaults: exit"
assert_contains "$OUTPUT" "list=$T/home/data/ci-errors/100/errors.md" "defaults: the list goes under FM_HOME"
assert_grep "run view --job 11 --log -R acme/widgets" "$F/calls" "defaults: the origin repository is named"
git -C "$C" remote set-url origin https://example.test/acme/widgets.git
set +e
"$C/bin/fm-ci-errors.sh" 100 >/dev/null 2>"$T/stderr"
RC=$?
set -e
expect_code 2 "$RC" "non-GitHub origin: exit"
assert_contains "$(cat "$T/stderr")" 'name the repository with --repo' "non-GitHub origin: stderr"
pass "the default repository is origin's github.com owner/repo, and the default list goes under FM_HOME"
