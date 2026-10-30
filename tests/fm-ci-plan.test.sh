#!/usr/bin/env bash
# Contract tests for bin/fm-ci-plan.sh - the CI plan job's layout choice and
# outputs for every trigger: the try layout's trailer selection and its
# never-widening changed-file fallback, and the ci, ci/full, main (run or
# skip) and weekly layouts; and the plan record each run writes, which a main
# push reads back to skip only after a full-layout ci/** pass (never
# ci/try/**) and fails closed on any unreadable answer. Each case runs the
# script in a fixture repository with its own tier map, stand-in tests and a
# fake gh.
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
  cp "$ROOT/bin/fm-helper-selftest.sh" "$REPO/bin/fm-helper-selftest.sh"
  cp "$ROOT/tests/git-config-helpers.sh" "$REPO/tests/"
  chmod +x "$REPO/bin/fm-ci-plan.sh" "$REPO/bin/fm-test-run.sh" "$REPO/bin/fm-helper-selftest.sh"
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
  # Fake gh: serves $FAKE_GH_DIR/run.json, runs.json and plans/<id>.json
  # (as the fm-ci-plan artifact of run <id>), and logs each call to calls.
  cat >"$STUB_BIN/gh" <<'SH'
#!/usr/bin/env bash
d=$FAKE_GH_DIR
printf '%s\n' "$*" >>"$d/calls"
case "$1" in
  api)
    case "$2" in
      */actions/runs/*)
        [ -f "$d/run.json" ] || { echo "HTTP 502: run read failed" >&2; exit 1; }
        cat "$d/run.json" ;;
      */actions/workflows/*/runs\?*)
        [ -f "$d/runs.json" ] || { echo "HTTP 500: run list failed" >&2; exit 1; }
        cat "$d/runs.json" ;;
      *) echo "fake gh: unexpected api path $2" >&2; exit 3 ;;
    esac ;;
  run)
    [ "$2" = download ] || exit 3
    id=$3 dest=
    shift 3
    while [ $# -gt 0 ]; do
      case "$1" in
        -D) dest=$2; shift 2 ;;
        *) shift ;;
      esac
    done
    [ -f "$d/plans/$id.json" ] || { echo "no artifact matches any of the names or patterns provided" >&2; exit 1; }
    mkdir -p "$dest" && cp "$d/plans/$id.json" "$dest/plan.json" ;;
  *) exit 3 ;;
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
  expect_output weekly helpers bin/fm-disk-room.sh
  plan_run dispatch --event workflow_dispatch || fail "dispatch plan failed"
  expect_output dispatch layout weekly
  plan_run cifull --event push --ref refs/heads/ci/full/demo || fail "ci/full plan failed"
  expect_layout cifull full gate,full '[1,2,3,4,5,6,7]' '["changed","1of3","2of3","3of3"]'
  expect_output cifull try_list ''
  expect_output cifull herdr_paths ''
  expect_output cifull helpers bin/fm-disk-room.sh
  assert_grep "Layout: full (event push, ref refs/heads/ci/full/demo)" "$TMP/cifull.sum" "the summary must name the layout"
  pass "schedule and dispatch run weekly; ci/full runs the main layout"
}

# A main-push case world: the fake gh's answers and call log, a scratch TMPDIR,
# and TEMPLATE, a full-layout record of ci/full/x run 100 at SHA written by
# the script itself. Sets W.
new_world() {
  W="$TMP/world-$1"
  rm -rf "$W"
  mkdir -p "$W/plans" "$W/tmp"
  : >"$W/calls"
  jq -n '{id: 900, workflow_id: 7}' >"$W/run.json"
  FAKE_GH_DIR=$W plan_run "$1-template" --event push --ref refs/heads/ci/full/x --sha "$SHA" \
    --run-id 100 --record "$W/template.json" || fail "writing the template record failed: $(cat "$TMP/$1-template.log")"
}

# run_entry <id> <branch> [conclusion] [started] [sha] [workflow-id] [repo]
run_entry() {
  jq -cn --argjson id "$1" --arg branch "$2" --arg conclusion "${3:-success}" \
    --arg started "${4:-2026-10-29T10:00:00Z}" --arg sha "${5:-$SHA}" \
    --argjson wid "${6:-7}" --arg repo "${7:-o/r}" '
    {id: $id, head_branch: $branch, head_sha: $sha, event: "push",
     conclusion: $conclusion, workflow_id: $wid, run_started_at: $started,
     html_url: "https://github.com/\($repo)/actions/runs/\($id)",
     head_repository: {full_name: $repo}}'
}

# set_runs <entry>...: the successful-run list the API answers.
set_runs() {
  printf '%s\n' "$@" | jq -s '{total_count: length, workflow_runs: .}' >"$W/runs.json"
}

# set_plan <id> <layout> [branch] [run-id]: run <id>'s record, the template
# with its layout, ref and run id changed.
set_plan() {
  jq --arg layout "$2" --arg ref "refs/heads/${3:-ci/x}" --argjson rid "${4:-$1}" \
    '.layout = $layout | .ref = $ref | .run_id = $rid' "$W/template.json" >"$W/plans/$1.json" \
    || fail "writing the fixture record of run $1 failed"
}

# main_push <name>: plan a main push of SHA as run 900 of o/r.
main_push() {
  FAKE_GH_DIR=$W TMPDIR=$W/tmp plan_run "$1" --event push --ref refs/heads/main --sha "$SHA" \
    --repo o/r --run-id 900 || fail "main plan failed: $(cat "$TMP/$1.log")"
  [ -z "$(ls -A "$W/tmp")" ] || fail "$1: the plan left scratch behind in $W/tmp"
}

test_record_format() {
  local rc
  fresh_work
  SHA=$(git -C "$REPO" rev-parse HEAD)
  new_world record
  assert_equals '{"schema":"fm-ci-plan/v1","layout":"full","sha":"'"$SHA"'","ref":"refs/heads/ci/full/x","event":"push","run_id":100}' \
    "$(jq -c . "$W/template.json")" "the record holds exactly the schema fields"
  assert_grep "Plan record: layout full at $W/template.json" "$TMP/record-template.sum" "the summary names the record"
  FAKE_GH_DIR=$W plan_run recordci --event push --ref refs/heads/ci/demo --run-id 101 --record "$W/ci.json" \
    || fail "ci plan failed: $(cat "$TMP/recordci.log")"
  assert_equals ci "$(jq -r .layout "$W/ci.json")" "the record holds the layout the run chose"
  FAKE_GH_DIR=$W plan_run recordweekly --event schedule --ref refs/heads/main --run-id 102 --record "$W/weekly.json" \
    || fail "weekly plan failed: $(cat "$TMP/recordweekly.log")"
  assert_equals 'weekly schedule' "$(jq -r '"\(.layout) \(.event)"' "$W/weekly.json")" "a scheduled run records its event"
  rc=0
  plan_run recordbad --event push --ref refs/heads/ci/full/x --run-id 103 --record "$W/missing/plan.json" || rc=$?
  expect_code 1 "$rc" "an unwritable record fails the plan"
  assert_grep "::error::fm-ci-plan: could not write the plan record $W/missing/plan.json" "$TMP/recordbad.log" \
    "the failure annotates the run"
  pass "every run records its layout, commit, ref, event and id; an unwritable record fails the plan"
}

test_main_skips_after_a_full_ci_pass() {
  new_world fullci
  set_runs "$(run_entry 101 ci/x)"
  set_plan 101 full ci/x
  main_push fullci
  expect_layout fullci skip '' '[]' '[]'
  expect_output fullci helpers ''
  assert_grep "Suites skipped: https://github.com/o/r/actions/runs/101 (ci/x) already passed this workflow on the full layout at \`$SHA\`." \
    "$TMP/fullci.sum" "a skip must name the run it trusts"
  assert_grep "run download 101 -R o/r -n fm-ci-plan" "$W/calls" "the record is read from the named repository's artifact"

  new_world fullcifull
  set_runs "$(run_entry 102 ci/full/x)"
  set_plan 102 full ci/full/x
  main_push fullcifull
  expect_output fullcifull layout skip
  pass "a full-layout ci/** pass of the same commit lets main skip"
}

test_main_runs_after_a_ci_layout_or_try_pass() {
  new_world cilayout
  set_runs "$(run_entry 103 ci/x)"
  set_plan 103 ci ci/x
  main_push cilayout
  expect_layout cilayout full gate,full '[1,2,3,4,5,6,7]' '["1of3","2of3","3of3"]'
  assert_grep 'Not counted: https://github.com/o/r/actions/runs/103 (ci/x): it used the "ci" layout.' "$TMP/cilayout.sum" \
    "the rejection must name the layout"
  assert_grep "Suites run: no earlier successful full-layout ci/** run of \`$SHA\`." "$TMP/cilayout.sum" \
    "the verdict must run the suites"

  new_world try
  set_runs "$(run_entry 104 ci/try/x)"
  set_plan 104 full ci/try/x
  main_push try
  expect_output try layout full
  assert_grep "ci/try/** never counts" "$TMP/try.sum" "the verdict must say why"
  assert_no_grep "run download" "$W/calls" "a ci/try/** run's record is never read"
  pass "a ci-layout pass and a ci/try/** pass, even with a full record, run the suites"
}

test_main_runs_on_any_unreadable_answer() {
  new_world apierr
  rm -f "$W/run.json"
  main_push apierr
  expect_output apierr layout full
  assert_grep "could not read this run's workflow (HTTP 502: run read failed)" "$TMP/apierr.sum" "the verdict must carry the API error"

  new_world nowid
  printf '{"message":"Not Found"}\n' >"$W/run.json"
  main_push nowid
  expect_output nowid layout full
  assert_grep "names no workflow id" "$TMP/nowid.sum" "an answer without a workflow id is unreadable"

  new_world listerr
  main_push listerr
  expect_output listerr layout full
  assert_grep "(HTTP 500: run list failed)" "$TMP/listerr.sum" "the verdict must carry the list error"

  new_world listshape
  printf '{"message":"API rate limit exceeded"}\n' >"$W/runs.json"
  main_push listshape
  expect_output listshape layout full
  assert_grep "was unreadable" "$TMP/listshape.sum" "a list without workflow_runs is unreadable, not empty"

  new_world listjunk
  printf 'not json\n' >"$W/runs.json"
  main_push listjunk
  expect_output listjunk layout full
  assert_grep "was unreadable" "$TMP/listjunk.sum" "a non-JSON list is unreadable"

  rm -f "$W/calls"
  FAKE_GH_DIR=$W plan_run nolookup --event push --ref refs/heads/main --sha "$SHA" \
    || fail "main plan failed: $(cat "$TMP/nolookup.log")"
  expect_output nolookup layout full
  assert_grep "Suites run: no --repo and --run-id" "$TMP/nolookup.sum" "a main push without a lookup must say why it runs"
  assert_absent "$W/calls" "a main push without --repo and --run-id calls no API"
  pass "every unreadable API answer, and a missing lookup, runs the suites"
}

test_main_never_counts_ineligible_runs() {
  local id
  new_world ineligible
  set_runs \
    "$(run_entry 900 ci/x)" \
    "$(run_entry 105 main)" \
    "$(run_entry 106 ci/x success 2026-10-29T10:00:00Z 2222222222222222222222222222222222222222)" \
    "$(run_entry 107 ci/x success 2026-10-29T10:00:00Z "$SHA" 8)" \
    "$(run_entry 108 ci/x success 2026-10-29T10:00:00Z "$SHA" 7 fork/r)" \
    "$(run_entry 109 feature/x)" \
    "$(run_entry 110 ci/x failure)"
  for id in 900 105 106 107 108 109 110; do set_plan "$id" full ci/x; done
  main_push ineligible
  expect_output ineligible layout full
  assert_no_grep "run download" "$W/calls" "no ineligible run's record is read"
  pass "the run itself, main, another commit, workflow, repository or branch, and a failure never count"
}

test_main_judges_each_record_on_its_own() {
  local id
  new_world mixed
  set_runs \
    "$(run_entry 111 ci/x success 2026-10-29T09:00:00Z)" \
    "$(run_entry 112 ci/full/x success 2026-10-29T11:00:00Z)"
  set_plan 111 full ci/x
  main_push mixed
  expect_output mixed layout skip
  assert_grep "Not counted: https://github.com/o/r/actions/runs/112 (ci/full/x) has no readable fm-ci-plan artifact (no artifact matches" \
    "$TMP/mixed.sum" "a newer run without a record is reported, not trusted by its branch name"
  assert_grep "Suites skipped: https://github.com/o/r/actions/runs/111 (ci/x)" "$TMP/mixed.sum" "the older valid run proves the pass"

  new_world norecord
  set_runs "$(run_entry 113 ci/full/x)"
  main_push norecord
  expect_output norecord layout full

  new_world mismatch
  set_runs "$(run_entry 120 ci/x)" "$(run_entry 121 ci/x)" "$(run_entry 122 ci/x)" \
    "$(run_entry 123 ci/x)" "$(run_entry 124 ci/x)" "$(run_entry 125 ci/x)" \
    "$(run_entry 126 ci/x)" "$(run_entry 127 ci/x)"
  set_plan 120 full ci/x
  jq '.sha = "2222222222222222222222222222222222222222"' "$W/plans/120.json" >"$W/p" && mv "$W/p" "$W/plans/120.json"
  set_plan 121 full ci/x 999
  set_plan 122 full ci/other
  printf '{"schema":"fm-ci-plan/v1",' >"$W/plans/123.json"
  set_plan 124 full ci/x
  cat "$W/plans/124.json" "$W/plans/124.json" >"$W/p" && mv "$W/p" "$W/plans/124.json"
  set_plan 125 full ci/x
  jq '.schema = "fm-ci-plan/v0"' "$W/plans/125.json" >"$W/p" && mv "$W/p" "$W/plans/125.json"
  printf '[]\n' >"$W/plans/126.json"
  set_plan 127 full ci/x
  jq '.event = "workflow_dispatch"' "$W/plans/127.json" >"$W/p" && mv "$W/p" "$W/plans/127.json"
  main_push mismatch
  expect_output mismatch layout full
  assert_grep 'names commit "2222222222222222222222222222222222222222"' "$TMP/mismatch.sum" "a record of another commit is rejected"
  assert_grep "names run 999" "$TMP/mismatch.sum" "a record of another run is rejected"
  assert_grep 'names "push" on "refs/heads/ci/other"' "$TMP/mismatch.sum" "a record of another branch is rejected"
  assert_grep "is not valid JSON" "$TMP/mismatch.sum" "a truncated record is rejected"
  assert_grep "is not one JSON object" "$TMP/mismatch.sum" "a doubled or non-object record is rejected"
  assert_grep 'schema is "fm-ci-plan/v0"' "$TMP/mismatch.sum" "a record of another schema is rejected"
  assert_grep 'names "workflow_dispatch" on "refs/heads/ci/x"' "$TMP/mismatch.sum" "a record of another event is rejected"
  for id in 120 121 122 123 124 125 126 127; do
    assert_grep "run download $id " "$W/calls" "candidate $id must be read"
  done
  pass "each record is judged on its own: a missing, mismatched or malformed one never counts or hides a valid one"
}

test_main_reads_at_most_ten_candidates() {
  local i entries=()
  new_world bounded
  for i in 10 11 12 13 14 15 16 17 18 19 20; do
    entries+=("$(run_entry "1$i" ci/x success "2026-10-29T$i:00:00Z")")
    set_plan "1$i" ci ci/x
  done
  # The oldest is the only full one, and it is past the bound.
  set_plan 110 full ci/x
  set_runs "${entries[@]}"
  main_push bounded
  expect_output bounded layout full
  assert_grep "Not read: candidates past the newest 10." "$TMP/bounded.sum" "the bound must be reported"
  assert_grep "run download 120 " "$W/calls" "the newest candidate is read first"
  assert_no_grep "run download 110 " "$W/calls" "the eleventh candidate is never read"
  pass "only the newest ten candidates are read"
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
  expect_output ci helpers ''
  assert_grep "Changed-area tier-2 tests: 2" "$TMP/ci.sum" "the ci summary must count the changed area"
  assert_grep "Helper contract self-tests: none (no gated helper changed)" "$TMP/ci.sum" \
    "the summary must say no helper self-test runs"

  printf '\n' >>"$REPO/src/unmapped.ts"
  commit_msg <<<"unmapped"
  plan_run ciunmapped --event push --ref refs/heads/ci/demo || fail "ci plan failed"
  expect_output ciunmapped layout full
  assert_grep "Changed files include a path the test map cannot place: running the main layout." "$TMP/ciunmapped.sum" \
    "an unmapped path must escalate a ci push"

  fresh_work
  for i in $(seq -w 1 31); do printf '\n' >>"$REPO/tests/fm-many-$i.test.sh"; done
  commit_msg <<<"wide"
  plan_run ciwide --event push --ref refs/heads/ci/demo || fail "ci plan failed"
  expect_output ciwide layout full
  assert_grep "Changed files select more than 30 tier-2 tests: running the main layout." "$TMP/ciwide.sum" \
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
  assert_grep "Try selection from Fm-Try trailers: 1 tests in 1 shards, 0 in the Herdr job." "$TMP/tryone.sum" \
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
    assert_grep "::error::" "$TMP/$name.log" "a refusal must annotate the run: ${msg%%$'\n'*}"
    assert_grep "Refused: " "$TMP/$name.sum" "a refusal must reach the summary: ${msg%%$'\n'*}"
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
  assert_grep "Try selection from changed files against base: 31 tests in 3 shards" "$TMP/trywide.sum" \
    "the summary must name the changed-file source"
  assert_grep "Unmapped changed path, skipped (a try run never widens): \`src/unmapped.ts\`" "$TMP/trywide.sum" \
    "the summary must list the unmapped path"

  fresh_work
  printf '\n' >>"$REPO/src/unmapped.ts"
  commit_msg <<<"only unmapped"
  try_push tryempty || fail "try plan failed: $(cat "$TMP/tryempty.log")"
  expect_layout tryempty try '' '[]' '["changed"]'
  expect_output tryempty herdr_paths ''
  assert_grep "No tests selected: only the static checks and changed-file lint run." "$TMP/tryempty.sum" \
    "an empty try selection must say what still runs"
  pass "a try push without trailers runs its changed area, skips unmapped paths and never escalates"
}

test_helpers_follow_the_change() {
  fresh_work
  printf 'one\n' >"$REPO/bin/fm-disk-room.sh"
  commit_msg <<<"helper"
  try_push tryhelper || fail "try plan failed: $(cat "$TMP/tryhelper.log")"
  expect_output tryhelper helpers bin/fm-disk-room.sh
  assert_grep "Helper contract self-tests: bin/fm-disk-room.sh" "$TMP/tryhelper.sum" "the summary must name the helper"
  plan_run cihelper --event push --ref refs/heads/ci/demo || fail "ci plan failed: $(cat "$TMP/cihelper.log")"
  expect_output cihelper helpers bin/fm-disk-room.sh

  fresh_work
  printf 'one\n' >"$REPO/bin/fm-storage-admission-lib.sh"
  commit_msg <<<"pinned sibling"
  try_push trysibling || fail "try plan failed: $(cat "$TMP/trysibling.log")"
  expect_output trysibling helpers bin/fm-disk-room.sh

  # A selector that cannot read the diff but can list the table.
  fresh_work
  printf '#!/usr/bin/env bash\ncase "$*" in *--all*) echo bin/fm-disk-room.sh ;; *) exit 1 ;; esac\n' \
    >"$REPO/bin/fm-helper-selftest.sh"
  commit_msg <<<"unreadable diff"
  try_push trybaddiff || fail "try plan failed: $(cat "$TMP/trybaddiff.log")"
  expect_output trybaddiff helpers bin/fm-disk-room.sh
  assert_grep "Could not read which pinned helpers changed: every helper's contract self-tests run." "$TMP/trybaddiff.sum" \
    "an unreadable diff must run every helper and say so"
  pass "the helpers output names a changed gated helper or its pinned sibling, and every helper when the diff is unreadable"
}

test_usage_errors() {
  local rc args
  local -a cases=(
    '--ref refs/heads/main'
    '--event push --bogus'
    '--event push --ref refs/heads/main --repo o --run-id 900'
    '--event push --ref refs/heads/main --repo o/r/x --run-id 900'
    '--event push --ref refs/heads/main --repo o/r --run-id 12x'
    '--event push --ref refs/heads/ci/x --record plan.json'
    '--event schedule --run-id 900 --record plan.json'
  )
  new_world usage
  for args in "${cases[@]}"; do
    rc=0
    # shellcheck disable=SC2086 # each case is a word list.
    (cd "$REPO" && FAKE_GH_DIR=$W PATH="$STUB_BIN:$PATH" bin/fm-ci-plan.sh $args) >"$TMP/usage.log" 2>&1 || rc=$?
    [ "$rc" -eq 2 ] || fail "'$args' must be a usage error (got $rc): $(cat "$TMP/usage.log")"
  done
  assert_no_grep "api" "$W/calls" "a usage error makes no API call"
  assert_absent "$REPO/plan.json" "a usage error writes no record"
  pass "usage errors exit 2 before any API call or record"
}

init_fixture
test_weekly_and_full_layouts
test_record_format
test_main_skips_after_a_full_ci_pass
test_main_runs_after_a_ci_layout_or_try_pass
test_main_runs_on_any_unreadable_answer
test_main_never_counts_ineligible_runs
test_main_judges_each_record_on_its_own
test_main_reads_at_most_ten_candidates
test_ci_layout_and_its_escalations
test_try_named_by_one_trailer
test_try_named_by_several_trailers
test_try_refuses_malformed_trailers
test_try_without_trailers_never_widens
test_helpers_follow_the_change
test_usage_errors
