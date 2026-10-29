#!/usr/bin/env bash
# Contract tests for bin/fm-ci-plan.sh - the CI plan job's layout choice and
# outputs for every trigger: the try layout's trailer selection and its
# never-widening changed-file fallback, and the ci, ci/full, main (run or
# skip) and weekly layouts. Each case runs the script in a fixture repository
# with its own tier map, stand-in tests and a stub gh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PLAN="$ROOT/bin/fm-ci-plan.sh"

assert_present "$PLAN" "bin/fm-ci-plan.sh is missing"
[ -x "$PLAN" ] || fail "bin/fm-ci-plan.sh must be executable"
command -v jq >/dev/null 2>&1 || fail "jq is required: the main layout's prior-run lookup reads gh output with it"

TMP=$(fm_test_tmproot fm-ci-plan)
REPO="$TMP/repo"
STUB_BIN="$TMP/bin"

fixture_git() {
  git -C "$REPO" -c user.name=test -c user.email=test@example.invalid "$@"
}

# The fixture: the plan script and the runner, a tier map, two real-Herdr
# tests (gate and full), and 31 tier-2 tests so a change can pass the ci
# layout's 30-test bound. Branch base is the diff base every case uses.
init_fixture() {
  local name i
  mkdir -p "$REPO/bin" "$REPO/tests" "$REPO/src" "$STUB_BIN"
  cp "$PLAN" "$REPO/bin/fm-ci-plan.sh"
  cp "$ROOT/bin/fm-test-run.sh" "$REPO/bin/fm-test-run.sh"
  cp "$ROOT/tests/git-config-helpers.sh" "$REPO/tests/"
  chmod +x "$REPO/bin/fm-ci-plan.sh" "$REPO/bin/fm-test-run.sh"
  {
    printf 'static tests/fm-static-probe.test.sh\n'
    printf 'gate tests/fm-gate-probe.test.sh\n'
    printf 'full tests/fm-a.test.sh\n'
    printf 'full tests/fm-b.test.sh\n'
    printf 'weekly tests/fm-c.test.sh\n'
    printf 'gate tests/fm-backend-herdr-presentation-e2e.test.sh\n'
    printf 'full tests/fm-backend-herdr-launcher-workspace-e2e.test.sh\n'
    for i in $(seq -w 1 31); do printf 'full tests/fm-many-%s.test.sh\n' "$i"; done
  } >"$REPO/tests/tiers.list"
  while read -r _ name; do
    printf '#!/usr/bin/env bash\necho "ok - %s"\n' "$name" >"$REPO/$name"
  done <"$REPO/tests/tiers.list"
  : >"$REPO/src/unmapped.ts"
  cat >"$STUB_BIN/gh" <<'SH'
#!/usr/bin/env bash
# Stub gh: the run's workflow id, then the successful runs of that workflow.
[ -z "${FAKE_GH_FAIL:-}" ] || exit 1
case "$2" in
  */actions/runs/*) printf '7\n' ;;
  */actions/workflows/7/runs*) cat "$FAKE_GH_RUNS" ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$STUB_BIN/gh"
  git -C "$REPO" init -q
  fixture_git add .
  fixture_git commit -qm baseline
  git -C "$REPO" branch base
}

# Start a case from the baseline on branch work.
fresh_work() {
  git -C "$REPO" checkout -q -B work base
}

# Commit every change with the message on stdin.
commit_msg() {
  fixture_git add -A
  fixture_git commit -q --allow-empty -F -
}

# Run the plan: plan_run <name> <args>... writes <name>.out (outputs),
# <name>.sum (the step summary) and <name>.log (stdout and stderr).
plan_run() {
  local name=$1
  shift
  rm -f "$TMP/$name.out" "$TMP/$name.sum"
  (cd "$REPO" && PATH="$STUB_BIN:$PATH" GITHUB_OUTPUT='' GITHUB_STEP_SUMMARY='' \
    bin/fm-ci-plan.sh --base base --output "$TMP/$name.out" --summary "$TMP/$name.sum" "$@") \
    >"$TMP/$name.log" 2>&1
}

# The value of output <key> from <name>.out.
output_of() {
  sed -n "s/^$2=//p" "$TMP/$1.out"
}

expect_output() {  # <name> <key> <value>
  local got
  got=$(output_of "$1" "$2")
  [ "$got" = "$3" ] || fail "$1: output $2 must be '$3', got '$got' ($(cat "$TMP/$1.log"))"
}

expect_layout() {  # <name> <layout> <tiers> <shards> <lint>
  expect_output "$1" layout "$2"
  expect_output "$1" tiers "$3"
  expect_output "$1" shards "$4"
  expect_output "$1" lint "$5"
}

try_push() {  # <name> - a ci/try push of the current HEAD
  plan_run "$1" --event push --ref refs/heads/ci/try/demo
}

test_weekly_and_full_layouts() {
  fresh_work
  plan_run weekly --event schedule || fail "schedule plan failed: $(cat "$TMP/weekly.log")"
  expect_layout weekly weekly weekly,live '[1,2,3,4,5]' '[]'
  plan_run dispatch --event workflow_dispatch || fail "dispatch plan failed"
  expect_output dispatch layout weekly
  plan_run cifull --event push --ref refs/heads/ci/full/demo || fail "ci/full plan failed"
  expect_layout cifull full gate,full '[1,2,3,4,5,6,7]' '["changed","1of3","2of3","3of3"]'
  expect_output cifull try_list ''
  expect_output cifull herdr_paths ''
  assert_grep "$TMP/cifull.sum" "Layout: full (event push, ref refs/heads/ci/full/demo)" "the summary must name the layout"
  pass "schedule and dispatch run weekly; ci/full runs the main layout"
}

test_main_skips_only_after_a_ci_full_pass() {
  local sha
  fresh_work
  sha=$(git -C "$REPO" rev-parse HEAD)
  runs_json() {  # <branch> <run id>
    jq -n --arg sha "$sha" --arg branch "$1" --argjson id "$2" '{workflow_runs: [{
      id: $id, head_sha: $sha, event: "push", conclusion: "success", workflow_id: 7,
      head_branch: $branch, run_started_at: "2026-10-29T00:00:00Z",
      html_url: "https://example.invalid/runs/\($id)",
      head_repository: {full_name: "o/r"}}]}' >"$TMP/runs.json"
  }
  runs_json ci/full/demo 41
  FAKE_GH_RUNS="$TMP/runs.json" plan_run mainskip --event push --ref refs/heads/main --sha "$sha" \
    --repo o/r --run-id 42 || fail "main plan failed: $(cat "$TMP/mainskip.log")"
  expect_layout mainskip skip '' '[]' '[]'
  assert_grep "$TMP/mainskip.sum" "Suites skipped: https://example.invalid/runs/41 (ci/full/demo) already passed this workflow on \`$sha\`." \
    "a skip must name the run it trusts"

  runs_json ci/demo 41
  FAKE_GH_RUNS="$TMP/runs.json" plan_run mainci --event push --ref refs/heads/main --sha "$sha" \
    --repo o/r --run-id 42 || fail "main plan failed"
  expect_layout mainci full gate,full '[1,2,3,4,5,6,7]' '["1of3","2of3","3of3"]'
  runs_json ci/try/demo 41
  FAKE_GH_RUNS="$TMP/runs.json" plan_run maintry --event push --ref refs/heads/main --sha "$sha" \
    --repo o/r --run-id 42 || fail "main plan failed"
  expect_output maintry layout full
  runs_json ci/full/demo 42
  FAKE_GH_RUNS="$TMP/runs.json" plan_run mainself --event push --ref refs/heads/main --sha "$sha" \
    --repo o/r --run-id 42 || fail "main plan failed"
  expect_output mainself layout full
  FAKE_GH_FAIL=1 plan_run mainerr --event push --ref refs/heads/main --sha "$sha" \
    --repo o/r --run-id 42 || fail "main plan must run its suites when gh fails"
  expect_output mainerr layout full
  pass "main skips only after a ci/full pass of the same commit; ci, try, its own run and an API error run the suites"
}

test_ci_layout_and_its_escalations() {
  local i
  fresh_work
  printf '\n' >>"$REPO/tests/fm-a.test.sh"
  printf '\n' >>"$REPO/tests/fm-backend-herdr-launcher-workspace-e2e.test.sh"
  commit_msg <<<"change a"
  plan_run ci --event push --ref refs/heads/ci/demo || fail "ci plan failed: $(cat "$TMP/ci.log")"
  expect_layout ci ci gate '[1,2,3]' '["changed"]'
  expect_output ci changed true
  expect_output ci herdr_paths 'tests/fm-backend-herdr-launcher-workspace-e2e.test.sh tests/fm-backend-herdr-presentation-e2e.test.sh '
  expect_output ci try_list ''
  assert_grep "$TMP/ci.sum" "Changed-area tier-2 tests: 2" "the ci summary must count the changed area"

  printf '\n' >>"$REPO/src/unmapped.ts"
  commit_msg <<<"unmapped"
  plan_run ciunmapped --event push --ref refs/heads/ci/demo || fail "ci plan failed"
  expect_output ciunmapped layout full
  assert_grep "$TMP/ciunmapped.sum" "Changed files include a path the test map cannot place: running the main layout." \
    "an unmapped path must escalate a ci push"

  fresh_work
  for i in $(seq -w 1 31); do printf '\n' >>"$REPO/tests/fm-many-$i.test.sh"; done
  commit_msg <<<"wide"
  plan_run ciwide --event push --ref refs/heads/ci/demo || fail "ci plan failed"
  expect_output ciwide layout full
  assert_grep "$TMP/ciwide.sum" "Changed files select more than 30 tier-2 tests: running the main layout." \
    "a wide change must escalate a ci push"
  pass "a ci push runs the changed area and escalates on an unmapped path or a wide change"
}

test_try_named_by_one_trailer() {
  fresh_work
  printf '\n' >>"$REPO/src/unmapped.ts"
  commit_msg <<'MSG'
try one script

Fm-Try: fm-a.test.sh
MSG
  try_push tryone || fail "try plan failed: $(cat "$TMP/tryone.log")"
  expect_layout tryone try '' '[1]' '["changed"]'
  expect_output tryone try_list tests/fm-a.test.sh
  expect_output tryone herdr_paths ''
  expect_output tryone changed false
  assert_grep "$TMP/tryone.sum" "Try selection from Fm-Try trailers: 1 tests in 1 shards, 0 in the Herdr job." \
    "the summary must name the selection source and size"
  pass "a try push naming one script runs one shard with just that script"
}

test_try_named_by_several_trailers() {
  fresh_work
  commit_msg <<'MSG'
try several

Fm-Try: tests/fm-a.test.sh, fm-b.test.sh
Fm-Try-Only: fm-c.test.sh:test_one_case
fm-try: fm-backend-herdr-presentation-e2e.test.sh fm-many-01.test.sh
MSG
  try_push trymany || fail "try plan failed: $(cat "$TMP/trymany.log")"
  expect_output trymany layout try
  expect_output trymany shards '[1,2,3]'
  expect_output trymany herdr_paths tests/fm-backend-herdr-presentation-e2e.test.sh
  local list
  list=$(output_of trymany try_list)
  for entry in tests/fm-a.test.sh tests/fm-b.test.sh tests/fm-c.test.sh:test_one_case tests/fm-many-01.test.sh; do
    case " $list " in *" $entry "*) ;; *) fail "try_list must hold $entry: $list" ;; esac
  done

  fresh_work
  commit_msg <<'MSG'
try a family

Fm-Try: real-herdr-gated
MSG
  try_push tryfamily || fail "try plan failed: $(cat "$TMP/tryfamily.log")"
  expect_output tryfamily shards '[]'
  expect_output tryfamily try_list ''
  expect_output tryfamily herdr_paths 'tests/fm-backend-herdr-launcher-workspace-e2e.test.sh tests/fm-backend-herdr-presentation-e2e.test.sh'
  pass "several trailers, case trailers and a family combine into the try shards and the Herdr job"
}

test_try_refuses_malformed_trailers() {
  local name msg
  local -a messages=(
    $'misspelled\n\nFm-Try fm-a.test.sh'
    $'outside the trailer block\n\nFm-Try: fm-a.test.sh\n\nbody after'
    $'unknown script\n\nFm-Try: fm-nosuch.test.sh'
    $'unknown family\n\nFm-Try: no-such-family'
    $'case without a case\n\nFm-Try-Only: fm-a.test.sh'
    $'bad case name\n\nFm-Try-Only: fm-a.test.sh:bad-name'
    $'whole and case\n\nFm-Try: fm-a.test.sh\nFm-Try-Only: fm-a.test.sh:test_x'
  )
  for msg in "${messages[@]}"; do
    fresh_work
    printf '%s\n' "$msg" | commit_msg
    name=refused
    if try_push "$name"; then
      fail "a try push must refuse '${msg%%$'\n'*}': $(cat "$TMP/$name.log")"
    fi
    [ ! -s "$TMP/$name.out" ] || fail "a refused plan must write no outputs: ${msg%%$'\n'*}"
    assert_grep "$TMP/$name.log" "::error::" "a refusal must annotate the run: ${msg%%$'\n'*}"
    assert_grep "$TMP/$name.sum" "Refused: " "a refusal must reach the summary: ${msg%%$'\n'*}"
  done
  pass "a try push refuses misspelled, misplaced, unknown, caseless and conflicting trailers"
}

test_try_without_trailers_never_widens() {
  local i
  fresh_work
  for i in $(seq -w 1 31); do printf '\n' >>"$REPO/tests/fm-many-$i.test.sh"; done
  printf '\n' >>"$REPO/tests/fm-static-probe.test.sh"
  printf '\n' >>"$REPO/src/unmapped.ts"
  commit_msg <<<"wide and unmapped"
  try_push trywide || fail "try plan failed: $(cat "$TMP/trywide.log")"
  expect_layout trywide try '' '[1,2,3]' '["changed"]'
  [ "$(output_of trywide try_list | wc -w)" -eq 31 ] \
    || fail "a try push must keep the whole changed selection: $(output_of trywide try_list)"
  assert_grep "$TMP/trywide.sum" "Try selection from changed files against base: 31 tests in 3 shards" \
    "the summary must name the changed-file source"
  assert_grep "$TMP/trywide.sum" "Unmapped changed path, skipped (a try run never widens): \`src/unmapped.ts\`" \
    "the summary must list the unmapped path"

  fresh_work
  printf '\n' >>"$REPO/src/unmapped.ts"
  commit_msg <<<"only unmapped"
  try_push tryempty || fail "try plan failed: $(cat "$TMP/tryempty.log")"
  expect_layout tryempty try '' '[]' '["changed"]'
  expect_output tryempty herdr_paths ''
  assert_grep "$TMP/tryempty.sum" "No tests selected: only the static checks and changed-file lint run." \
    "an empty try selection must say what still runs"
  pass "a try push without trailers runs its changed area, skips unmapped paths and never escalates"
}

test_usage_errors() {
  local rc=0
  (cd "$REPO" && bin/fm-ci-plan.sh --ref refs/heads/main) >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 2 ] || fail "a missing --event must be a usage error (got $rc)"
  rc=0
  (cd "$REPO" && bin/fm-ci-plan.sh --event push --bogus) >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 2 ] || fail "an unknown argument must be a usage error (got $rc)"
  pass "usage errors exit 2"
}

init_fixture
test_weekly_and_full_layouts
test_main_skips_only_after_a_ci_full_pass
test_ci_layout_and_its_escalations
test_try_named_by_one_trailer
test_try_named_by_several_trailers
test_try_refuses_malformed_trailers
test_try_without_trailers_never_widens
test_usage_errors
