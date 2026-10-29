#!/usr/bin/env bash
# Tests for bin/fm-ci-push.sh, the push guard for a task's CI branches, with a
# local bare origin and a stubbed gh that serves recorded run, job and log
# fixtures and filters runs by branch and head sha the way the API does.
#
# The guarantees under test, each refusal with a case that fails when that
# refusal alone is removed:
#   - try pushes HEAD to ci/try/<task>; land pushes to ci/<task> only when
#     HEAD contains origin/main; both refuse a dirty worktree.
#   - A push whose content (tree, commit authors and messages) already ran on
#     a CI branch in scope is refused with that run's URL; a message-only
#     change, or a try run seen by land, is not the same content.
#   - A repeat call with the target already at HEAD pushes nothing, exit 0.
#   - A non-fast-forward refusal deletes the task's own CI branch and pushes
#     again, never forcing.
#   - land --full pushes ci/full/<task> only when HEAD's ci/<task> run's plan
#     job chose the ci layout and the run is not red.
#   - land --rebased-from allows a fast-forward only when the commit list,
#     each commit's verbatim patch id, the tested run and the main run all
#     pass, and names every condition that failed.
#   - rerun-infra reruns failed jobs once when the classifier classes them
#     all infra, refuses otherwise or without a classifier, refuses while the
#     run is going, and raises a blocked line for a job that already reran.
#   - Unreadable or failed gh output refuses; every gh call names the repo.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PUSH="$ROOT/bin/fm-ci-push.sh"
REPO=own/repo
T=tk1

unset FM_HOME FM_CI_PUSH_ERRORS_BIN
fm_git_identity fmtest fmtest@example.com

TMP_ROOT=$(fm_test_tmproot fm-ci-push-tests)
FAKEBIN="$TMP_ROOT/fakebin"
mkdir -p "$FAKEBIN"

# The fake gh records every call and answers from $FAKE_GH_DIR: runs.json is
# the workflow's whole run list, jobs-<run>.json and joblog-<job>.txt the job
# listings and logs. A `fail` file makes it exit 1; a `broken` file makes it
# print a non-JSON page.
cat >"$FAKEBIN/gh" <<'EOF'
#!/usr/bin/env bash
d=$FAKE_GH_DIR
printf '%s\n' "$*" >>"$d/calls.log"
if [ -e "$d/fail" ]; then echo "gh: HTTP 502" >&2; exit 1; fi
if [ -e "$d/broken" ]; then echo "<html>rate limited</html>"; exit 0; fi
case "$1:${2:-}" in
  api:repos/*/actions/workflows/*/runs\?*)
    branch= sha=
    IFS='&' read -r -a kv <<<"${2#*\?}"
    for p in "${kv[@]}"; do
      case "$p" in
        branch=*) branch=${p#branch=} ;;
        head_sha=*) sha=${p#head_sha=} ;;
      esac
    done
    jq --arg b "$branch" --arg s "$sha" \
      '{workflow_runs: [.workflow_runs[] | select(($b == "" or .head_branch == $b) and ($s == "" or .head_sha == $s))]}' \
      "$d/runs.json"
    ;;
  api:repos/*/actions/runs/*/jobs*)
    id=${2#*/actions/runs/}
    cat "$d/jobs-${id%%/*}.json"
    ;;
  api:repos/*/actions/runs/*)
    jq --argjson id "${2##*/}" '.workflow_runs[] | select(.id == $id)' "$d/runs.json"
    ;;
  run:view) cat "$d/joblog-$4.txt" ;;
  run:rerun) printf '%s\n' "$3" >>"$d/reruns.log" ;;
  *) echo "fake gh: unexpected call: $*" >&2; exit 1 ;;
esac
EOF
chmod +x "$FAKEBIN/gh"

CASE_N=0
# new_case: a fresh origin with one main commit, a task clone of it, a home
# whose state holds the task's status file, and an empty run list.
new_case() {
  CASE_N=$((CASE_N + 1))
  C="$TMP_ROOT/case$CASE_N"
  mkdir -p "$C"
  fm_git_init_commit "$C/seed" >/dev/null
  git clone -q --bare "$C/seed" "$C/origin.git"
  git -C "$C/origin.git" config uploadpack.allowAnySHA1InWant true
  git clone -q "$C/origin.git" "$C/work"
  git -C "$C/work" checkout -q -b "fm/$T"
  git clone -q "$C/origin.git" "$C/other"
  WORK="$C/work"
  BARE="$C/origin.git"
  HOMEDIR="$C/home"
  GHD="$C/gh"
  mkdir -p "$HOMEDIR/state" "$HOMEDIR/config" "$GHD"
  : >"$HOMEDIR/state/$T.status"
  printf '{"workflow_runs": []}\n' >"$GHD/runs.json"
  RUN_CLOCK=0
}

commit_file() {  # <file> <content> <message>
  printf '%s\n' "$2" >"$WORK/$1"
  git -C "$WORK" add "$1"
  git -C "$WORK" commit -q -m "$3"
}

advance_main() {  # <file>: lands an unrelated commit on origin's main
  git -C "$C/other" pull -q --ff-only origin main
  printf 'main change\n' >"$C/other/$1"
  git -C "$C/other" add "$1"
  git -C "$C/other" commit -q -m "main: $1"
  git -C "$C/other" push -q origin HEAD:main
  git -C "$WORK" fetch -q origin
}

# add_run <id> <branch> <sha> <status> <conclusion|null> [attempt]
add_run() {
  local tree created
  tree=$(git -C "$WORK" rev-parse "$3^{tree}")
  RUN_CLOCK=$((RUN_CLOCK + 1))
  created=$(printf '2026-10-29T10:%02d:00Z' "$RUN_CLOCK")
  jq --argjson id "$1" --arg b "$2" --arg sha "$3" --arg tree "$tree" --arg st "$4" \
    --argjson concl "$(if [ "$5" = null ]; then echo null; else printf '"%s"' "$5"; fi)" \
    --argjson att "${6:-1}" --arg created "$created" --arg repo "$REPO" \
    '.workflow_runs += [{id: $id, head_branch: $b, head_sha: $sha, head_commit: {id: $sha, tree_id: $tree},
      status: $st, conclusion: $concl, html_url: "https://github.com/\($repo)/actions/runs/\($id)",
      created_at: $created, event: "push", run_attempt: $att, head_repository: {full_name: $repo}}]' \
    "$GHD/runs.json" >"$GHD/runs.json.new"
  mv "$GHD/runs.json.new" "$GHD/runs.json"
}

run_push() {  # <args...>: sets RC, OUT, ERR
  local rc=0
  (cd "$WORK" && PATH="$FAKEBIN:$PATH" FAKE_GH_DIR="$GHD" FM_HOME="$HOMEDIR" \
    "$PUSH" "$@" --repo "$REPO") >"$C/out" 2>"$C/err" || rc=$?
  RC=$rc
  OUT=$(cat "$C/out")
  ERR=$(cat "$C/err")
}

remote_sha() {  # <branch>
  git -C "$BARE" rev-parse -q --verify "refs/heads/$1" 2>/dev/null || true
}

head_sha() {
  git -C "$WORK" rev-parse HEAD
}

gh_calls_name_repo() {  # every recorded gh call names $REPO, in an API path or with -R
  local call calls
  calls=$(cat "$GHD/calls.log")
  [ -n "$calls" ] || fail "no gh call was recorded"
  while IFS= read -r call; do
    case "$call" in
      "api repos/$REPO/"*|*" -R $REPO"|*" -R $REPO "*) ;;
      *) fail "a gh call does not name $REPO: $call" ;;
    esac
  done <<<"$calls"
}

# --- try ----------------------------------------------------------------------

new_case
commit_file a.txt one "task: add a"
run_push try "$T"
expect_code 0 "$RC" "try pushes a fresh head"
assert_equals "$(head_sha)" "$(remote_sha "ci/try/$T")" "try puts HEAD on ci/try/<task>"
assert_contains "$OUT" "pushed $(head_sha) to ci/try/$T" "try reports the push"
assert_grep "pushed $(head_sha) to ci/try/$T" "$HOMEDIR/state/$T.ci-push.log" "the push is logged"
assert_grep "api repos/$REPO/actions/workflows/ci.yml/runs?branch=ci/$T&" "$GHD/calls.log" "the task's runs are read"
gh_calls_name_repo
pass "try pushes HEAD to ci/try/<task>, logs it, and names the repo on every gh call"

run_push try "$T"
expect_code 0 "$RC" "a repeat try is nothing to do"
assert_contains "$OUT" "nothing to push" "a repeat try says so"
pass "a repeat try with the branch already at HEAD pushes nothing"

new_case
commit_file a.txt one "task: add a"
printf 'scratch\n' >"$WORK/untracked.txt"
run_push try "$T"
expect_code 1 "$RC" "try refuses a dirty worktree"
assert_contains "$ERR" "the worktree is dirty" "the dirty refusal is named"
assert_equals "" "$(remote_sha "ci/try/$T")" "nothing is pushed from a dirty worktree"
assert_grep "refused: the worktree is dirty" "$HOMEDIR/state/$T.ci-push.log" "the refusal is logged"
pass "try refuses a dirty worktree"

new_case
commit_file a.txt one "task: add a"
add_run 101 "ci/$T" "$(head_sha)" completed failure
run_push try "$T"
expect_code 1 "$RC" "try refuses a commit that already ran on a ci branch"
assert_contains "$ERR" "already ran in https://github.com/$REPO/actions/runs/101" "the earlier run is cited"
assert_equals "" "$(remote_sha "ci/try/$T")" "the already-run commit is not pushed"
pass "try refuses HEAD when it already ran on another ci/** branch"

new_case
commit_file a.txt one "task: add a"
old=$(head_sha)
git -C "$WORK" push -q origin "HEAD:refs/heads/ci/$T"
add_run 102 "ci/$T" "$old" completed failure
GIT_COMMITTER_DATE='2030-01-01T00:00:00Z' git -C "$WORK" commit -q --amend --no-edit
assert_not_equals "$old" "$(head_sha)" "the amend made a new commit"
run_push try "$T"
expect_code 1 "$RC" "try refuses the same tree and messages under a new sha"
assert_contains "$ERR" "runs/102" "the same-content run is cited"
assert_equals "" "$(remote_sha "ci/try/$T")" "same content is not pushed again"
git -C "$WORK" commit -q --amend -m "task: add a" -m "no-test-needed: fixture"
run_push try "$T"
expect_code 0 "$RC" "a changed commit message is new content"
assert_equals "$(head_sha)" "$(remote_sha "ci/try/$T")" "the message change is pushed"
pass "content is the tree plus commit messages: a date-only amend is refused, a message change is not"

# --- land ---------------------------------------------------------------------

new_case
commit_file a.txt one "task: add a"
add_run 103 "ci/try/$T" "$(head_sha)" completed success
run_push land "$T"
expect_code 0 "$RC" "land pushes a head that only has a try run"
assert_equals "$(head_sha)" "$(remote_sha "ci/$T")" "land puts HEAD on ci/<task>"
pass "land ignores try runs, which are never a landing proof"

run_push land "$T"
expect_code 0 "$RC" "a repeat land is nothing to do"
assert_contains "$OUT" "nothing to push" "a repeat land says so"
pass "a repeat land pushes nothing"

new_case
commit_file a.txt one "task: add a"
advance_main b.txt
run_push land "$T"
expect_code 1 "$RC" "land refuses a head without origin/main"
assert_contains "$ERR" "HEAD does not contain origin/main" "the rebase refusal is named"
assert_equals "" "$(remote_sha "ci/$T")" "a stale head is not pushed"
pass "land refuses a head that does not contain origin/main"

new_case
commit_file a.txt one "task: add a"
printf 'edit\n' >>"$WORK/a.txt"
run_push land "$T"
expect_code 1 "$RC" "land refuses a dirty worktree"
assert_equals "" "$(remote_sha "ci/$T")" "nothing is pushed from a dirty worktree"
pass "land refuses a dirty worktree"

new_case
commit_file a.txt one "task: add a"
add_run 104 "ci/full/$T" "$(head_sha)" completed success
run_push land "$T"
expect_code 1 "$RC" "land refuses a commit whose full run exists"
assert_contains "$ERR" "runs/104" "the full run is cited"
assert_equals "" "$(remote_sha "ci/$T")" "the proven commit is not pushed again"
pass "land refuses a commit that already ran on ci/full/<task>"

new_case
commit_file a.txt one "task: add a"
git -C "$WORK" push -q origin "HEAD:refs/heads/ci/$T"
git -C "$WORK" reset -q --hard HEAD~1
commit_file a.txt two "task: add a differently"
run_push land "$T"
expect_code 0 "$RC" "land replaces a diverged head on its own ci branch"
assert_equals "$(head_sha)" "$(remote_sha "ci/$T")" "the new head is on ci/<task>"
assert_grep "refused as non-fast-forward" "$HOMEDIR/state/$T.ci-push.log" "the delete-and-push is logged"
pass "a non-fast-forward refusal deletes the task's own ci branch and pushes again"

# --- land --full --------------------------------------------------------------

plan_fixture() {  # <run-id> <job-id> <layout>
  printf '{"jobs": [{"id": %s, "name": "Plan the tiered run", "status": "completed", "conclusion": "success", "run_attempt": 1}]}\n' \
    "$2" >"$GHD/jobs-$1.json"
  {
    # The step's source echo, which must not count as a stated layout.
    # shellcheck disable=SC2016
    printf 'Plan the tiered run\tChoose the layout for this trigger\t2026-10-29T10:00:01Z   summary "Layout: $layout (event $EVENT, ref $REF)"\n'
    printf 'Plan the tiered run\tChoose the layout for this trigger\t2026-10-29T10:00:02Z Layout: %s (event push, ref refs/heads/ci/%s)\n' "$3" "$T"
  } >"$GHD/joblog-$2.txt"
}

new_case
commit_file a.txt one "task: add a"
run_push land "$T" --full
expect_code 1 "$RC" "--full refuses without a ci/<task> run"
assert_contains "$ERR" "has no ci/$T run yet" "the missing proof run is named"
assert_equals "" "$(remote_sha "ci/full/$T")" "no full push without a ci run"
pass "land --full refuses a head with no ci/<task> run"

new_case
commit_file a.txt one "task: add a"
add_run 105 "ci/$T" "$(head_sha)" in_progress null
plan_fixture 105 9105 full
run_push land "$T" --full
expect_code 1 "$RC" "--full refuses when the ci run already runs the full layout"
assert_contains "$ERR" "already runs the full layout" "the full layout is named"
assert_equals "" "$(remote_sha "ci/full/$T")" "no second full run"
pass "land --full refuses when the ci/<task> run planned the full layout"

new_case
commit_file a.txt one "task: add a"
add_run 106 "ci/$T" "$(head_sha)" completed failure
plan_fixture 106 9106 ci
run_push land "$T" --full
expect_code 1 "$RC" "--full refuses a red ci run"
assert_contains "$ERR" "is red" "the red run is named"
assert_equals "" "$(remote_sha "ci/full/$T")" "no full run on a red head"
pass "land --full refuses when the ci/<task> run is red"

new_case
commit_file a.txt one "task: add a"
add_run 107 "ci/$T" "$(head_sha)" in_progress null
plan_fixture 107 9107 ci
run_push land "$T" --full
expect_code 0 "$RC" "--full pushes after a ci-layout plan"
assert_equals "$(head_sha)" "$(remote_sha "ci/full/$T")" "HEAD is on ci/full/<task>"
gh_calls_name_repo
pass "land --full pushes when the ci/<task> run planned the ci layout"

new_case
commit_file a.txt one "task: add a"
add_run 108 "ci/$T" "$(head_sha)" in_progress null
printf '{"jobs": []}\n' >"$GHD/jobs-108.json"
run_push land "$T" --full
expect_code 1 "$RC" "--full refuses before the plan job is done"
assert_equals "" "$(remote_sha "ci/full/$T")" "no full push without a known layout"
pass "land --full refuses while the plan job has not finished"

# --- land --rebased-from ------------------------------------------------------

# rebased_case: two tested commits proven green on ci/<task>, then main moves
# on an unrelated file and the task rebases onto it with no conflict.
rebased_case() {
  new_case
  commit_file a.txt 'alpha beta' "task: add a"
  commit_file c.txt gamma "task: add c"
  TESTED=$(head_sha)
  add_run 201 "ci/$T" "$TESTED" completed "${1:-success}"
  advance_main b.txt
  git -C "$WORK" rebase -q origin/main
  MAIN=$(git -C "$WORK" rev-parse origin/main)
  add_run 202 main "$MAIN" completed "${2:-success}"
}

rebased_case
run_push land "$T" --rebased-from "$TESTED"
expect_code 0 "$RC" "a clean rebase of a green patch onto a green main is allowed"
assert_contains "$OUT" "fast-forward allowed without a new run: https://github.com/$REPO/actions/runs/201" "the tested run is named"
assert_equals "" "$(remote_sha "ci/$T")" "--rebased-from pushes nothing"
assert_grep "fast-forward allowed without a new run" "$HOMEDIR/state/$T.ci-push.log" "the verdict is logged"
pass "land --rebased-from allows an unchanged rebase onto a green main"

rebased_case
git -C "$WORK" commit -q --amend -m "task: add c, reworded"
run_push land "$T" --rebased-from "$TESTED"
expect_code 1 "$RC" "a reworded commit is refused"
assert_contains "$ERR" "commit-list FAILED" "the commit-list condition is named"
assert_contains "$OUT" "patch-id ok" "the content is still the same"
pass "land --rebased-from refuses a changed commit list (a reworded message)"

rebased_case
printf 'gamma delta\n' >"$WORK/c.txt"
git -C "$WORK" commit -q -a --amend --no-edit
run_push land "$T" --rebased-from "$TESTED"
expect_code 1 "$RC" "a changed patch is refused"
assert_contains "$ERR" "patch-id FAILED" "the patch-id condition is named"
assert_contains "$OUT" "commit-list ok" "the commit list is still the same"
pass "land --rebased-from refuses a commit whose patch changed in the rebase"

rebased_case
git -C "$WORK" reset -q --hard HEAD~1
printf 'alpha  beta\n' >"$WORK/a.txt"
git -C "$WORK" commit -q -a --amend --no-edit
git -C "$WORK" cherry-pick "$TESTED" >/dev/null
run_push land "$T" --rebased-from "$TESTED"
expect_code 1 "$RC" "a whitespace-only change is refused"
assert_contains "$ERR" "patch-id FAILED: commit 1 of 2" "the whitespace change is caught by the verbatim patch id"
pass "land --rebased-from compares patch ids verbatim, so whitespace changes count"

rebased_case failure
run_push land "$T" --rebased-from "$TESTED"
expect_code 1 "$RC" "a red tested run is refused"
assert_contains "$ERR" "tested-run FAILED" "the tested-run condition is named"
assert_contains "$OUT" "patch-id ok" "the patch is unchanged"
pass "land --rebased-from refuses a tested sha whose ci/<task> run is not green"

rebased_case success failure
run_push land "$T" --rebased-from "$TESTED"
expect_code 1 "$RC" "a red main is refused"
assert_contains "$ERR" "main-run FAILED" "the main-run condition is named"
assert_contains "$OUT" "tested-run ok" "the tested run is green"
pass "land --rebased-from refuses when main's run is red"

rebased_case
add_run 203 main "$MAIN" in_progress null
run_push land "$T" --rebased-from "$TESTED"
expect_code 1 "$RC" "a main run still going is refused"
assert_contains "$ERR" "main-run FAILED: not green" "a running main run is not green"
pass "land --rebased-from judges main by its newest run"

rebased_case
git -C "$WORK" reset -q --hard HEAD~1
run_push land "$T" --rebased-from "$TESTED"
expect_code 1 "$RC" "a dropped commit is refused"
assert_contains "$ERR" "commit-list FAILED: the tested range has 2 commits" "the count mismatch is named"
pass "land --rebased-from refuses a range with a different commit count"

# --- unreadable gh ------------------------------------------------------------

new_case
commit_file a.txt one "task: add a"
: >"$GHD/broken"
run_push land "$T"
expect_code 1 "$RC" "unreadable gh output refuses"
assert_contains "$ERR" "unreadable gh output" "the unreadable reading is named"
assert_equals "" "$(remote_sha "ci/$T")" "nothing is pushed on an unreadable reading"
rm -f "$GHD/broken"
: >"$GHD/fail"
run_push try "$T"
expect_code 1 "$RC" "a failed gh call refuses"
assert_contains "$ERR" "gh failed reading" "the failed reading is named"
assert_equals "" "$(remote_sha "ci/try/$T")" "nothing is pushed on a failed reading"
pass "unreadable or failed gh output refuses before any push"

new_case
commit_file a.txt one "task: add a"
rc=0
(cd "$WORK" && PATH="$FAKEBIN:$PATH" FAKE_GH_DIR="$GHD" "$PUSH" land "$T" --repo "$REPO") >/dev/null 2>"$C/err" || rc=$?
expect_code 1 "$rc" "no FM_HOME refuses"
assert_grep "FM_HOME is not set" "$C/err" "the missing home is named"
assert_equals "" "$(remote_sha "ci/$T")" "nothing is pushed without a log"
pass "a missing FM_HOME refuses before any push"

# --- rerun-infra --------------------------------------------------------------

# infra_case <job-attempt>: a finished red ci/<task> run with one green and two
# failed jobs, and a classifier that writes an fm-ci-errors/v1 errors.json
# with one job row per `<job-id>\t<class>` line of $GHD/classes, edited by the
# jq filter in $GHD/edit; a $GHD/classifier-exit file makes it exit with that.
infra_case() {
  new_case
  commit_file a.txt one "task: add a"
  add_run 301 "ci/$T" "$(head_sha)" completed failure "${1:-1}"
  printf '{"jobs": [
    {"id": 1, "name": "Plan the tiered run", "status": "completed", "conclusion": "success", "run_attempt": 1},
    {"id": 2, "name": "Behavior shard 1", "status": "completed", "conclusion": "failure", "run_attempt": %s},
    {"id": 3, "name": "Supervision calibration", "status": "completed", "conclusion": "cancelled", "run_attempt": %s}]}\n' \
    "${1:-1}" "${1:-1}" >"$GHD/jobs-301.json"
  printf '%s\n' "${1:-1}" >"$GHD/attempt"
  printf '.\n' >"$GHD/edit"
  cat >"$C/classifier" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FAKE_GH_DIR/classifier.log"
[ ! -f "$FAKE_GH_DIR/classifier-exit" ] || exit "$(cat "$FAKE_GH_DIR/classifier-exit")"
out='' run=''
while [ $# -gt 0 ]; do
  case $1 in
    --out) out=$2; shift 2 ;;
    --repo) shift 2 ;;
    *) run=$1; shift ;;
  esac
done
mkdir -p "$out" || exit 1
jq -R -s --argjson id "$run" --argjson attempt "$(cat "$FAKE_GH_DIR/attempt")" '
  {schema: "fm-ci-errors/v1", run: {id: $id, attempt: $attempt},
   rows: [split("\n")[] | select(length > 0) | split("\t")
          | {kind: "job", job_id: (.[0] | tonumber), class: .[1]}]}' "$FAKE_GH_DIR/classes" \
  | jq "$(cat "$FAKE_GH_DIR/edit")" >"$out/errors.json"
EOF
  chmod +x "$C/classifier"
  printf '2\tinfra\n3\tinfra\n' >"$GHD/classes"
}

run_infra() {  # <args...>
  local rc=0
  (cd "$WORK" && PATH="$FAKEBIN:$PATH" FAKE_GH_DIR="$GHD" FM_HOME="$HOMEDIR" \
    FM_CI_PUSH_ERRORS_BIN="${CLASSIFIER-$C/classifier}" "$PUSH" rerun-infra "$@" --repo "$REPO") \
    >"$C/out" 2>"$C/err" || rc=$?
  RC=$rc
  OUT=$(cat "$C/out")
  ERR=$(cat "$C/err")
}

infra_case
run_infra 301
expect_code 0 "$RC" "an all-infra run is rerun"
assert_grep "301" "$GHD/reruns.log" "gh run rerun was called"
assert_grep "--repo $REPO --out $HOMEDIR/data/ci-errors/301 301" "$GHD/classifier.log" "the classifier gets the run, repo and list directory"
assert_contains "$OUT" "reran the 2 failed jobs" "the rerun is reported"
assert_grep "reran the 2 failed jobs" "$HOMEDIR/state/$T.ci-push.log" "the rerun is logged"
assert_grep "run rerun 301 --failed -R $REPO" "$GHD/calls.log" "the rerun names the repo"
gh_calls_name_repo
pass "rerun-infra reruns a run whose every failure is infra"

infra_case
CLASSIFIER="$C/no-such-classifier" run_infra 301
expect_code 1 "$RC" "no classifier refuses"
assert_contains "$ERR" "bin/fm-ci-errors.sh) is not on this base" "the missing classifier is named"
assert_absent "$GHD/reruns.log" "nothing is rerun"
pass "rerun-infra refuses without bin/fm-ci-errors.sh"

infra_case
printf '2\tinfra\n3\treal\n' >"$GHD/classes"
run_infra 301
expect_code 1 "$RC" "a real failure refuses"
assert_contains "$ERR" "not every failure of https://github.com/$REPO/actions/runs/301 is infra: 3:real" "the non-infra row is named"
assert_contains "$ERR" "$HOMEDIR/data/ci-errors/301/errors.md" "the list to read is named"
assert_absent "$GHD/reruns.log" "nothing is rerun"
pass "rerun-infra refuses when any failure is not infra"

infra_case
printf '2\tflaky\n3\tinfra\n' >"$GHD/classes"
run_infra 301
expect_code 1 "$RC" "a flaky failure refuses without --flaky-ok"
assert_absent "$GHD/reruns.log" "nothing is rerun"
run_infra 301 --flaky-ok
expect_code 0 "$RC" "--flaky-ok accepts a flaky failure"
assert_grep "301" "$GHD/reruns.log" "the flaky run is rerun with --flaky-ok"
pass "rerun-infra accepts a known flake only with --flaky-ok"

infra_case
printf '2\tinfra\n' >"$GHD/classes"
run_infra 301
expect_code 1 "$RC" "a failed job with no row refuses"
assert_contains "$ERR" "gave failed job 'Supervision calibration' (3) no row" "the unclassified job is named"
assert_absent "$GHD/reruns.log" "nothing is rerun"
pass "rerun-infra refuses a failed job the classifier did not classify"

infra_case
printf '2\tinfra\n3\tinfra\n1\tinfra\n' >"$GHD/classes"
run_infra 301
expect_code 1 "$RC" "a row for a green job refuses"
assert_contains "$ERR" "names job 1, which did not fail" "the stray row is named"
assert_absent "$GHD/reruns.log" "nothing is rerun"
printf '2\tinfrastructure\n3\tinfra\n' >"$GHD/classes"
run_infra 301
expect_code 1 "$RC" "an unknown class refuses"
assert_contains "$ERR" "unrecognized class 'infrastructure' for job 2" "the bad class is named"
printf '2\ttest-defect\n3\tinfra\n' >"$GHD/classes"
run_infra 301
expect_code 1 "$RC" "a class fm-ci-errors/v1 does not emit refuses"
assert_contains "$ERR" "unrecognized class 'test-defect'" "the foreign class is named"
printf '2\tinfra\n3\tinfra\n' >"$GHD/classes"
printf '.schema = "fm-ci-errors/v2"\n' >"$GHD/edit"
run_infra 301
expect_code 1 "$RC" "another schema refuses"
assert_contains "$ERR" "is not an fm-ci-errors/v1 list for attempt 1" "the bad list is named"
printf '.run.id = 302\n' >"$GHD/edit"
run_infra 301
expect_code 1 "$RC" "another run's list refuses"
printf '.run.attempt = 2\n' >"$GHD/edit"
run_infra 301
expect_code 1 "$RC" "another attempt's list refuses"
printf '.rows[0].job_id = "2"\n' >"$GHD/edit"
run_infra 301
expect_code 1 "$RC" "a non-numeric job id refuses"
printf '.rows = {}\n' >"$GHD/edit"
run_infra 301
expect_code 1 "$RC" "rows that are not a list refuse"
assert_absent "$GHD/reruns.log" "nothing is rerun"
printf '.\n' >"$GHD/edit"
printf '75\n' >"$GHD/classifier-exit"
run_infra 301
expect_code 1 "$RC" "a classifier exit 75 refuses"
assert_contains "$ERR" "has not completed" "the unfinished run is named"
printf '1\n' >"$GHD/classifier-exit"
run_infra 301
expect_code 1 "$RC" "a failed classifier refuses"
assert_contains "$ERR" "could not classify run https://github.com/$REPO/actions/runs/301 (exit 1)" "the failure is named"
assert_absent "$GHD/reruns.log" "nothing is rerun"
pass "rerun-infra refuses classifier output it does not recognize"

infra_case 2
run_infra 301
expect_code 1 "$RC" "a job that already reran refuses"
assert_contains "$ERR" "already had its one rerun" "the second failure is named"
assert_absent "$GHD/reruns.log" "nothing is rerun"
assert_grep "blocked [at=" "$HOMEDIR/state/$T.status" "a blocked line is raised"
assert_grep "failed again after its one infra rerun (attempt 2) in https://github.com/$REPO/actions/runs/301" \
  "$HOMEDIR/state/$T.status" "the blocked line names the run"
pass "rerun-infra raises a blocked line instead of a second rerun"

infra_case
jq '.workflow_runs[0].status = "queued" | .workflow_runs[0].conclusion = null' "$GHD/runs.json" >"$GHD/runs.json.new"
mv "$GHD/runs.json.new" "$GHD/runs.json"
run_infra 301
expect_code 1 "$RC" "a run still going refuses"
assert_contains "$ERR" "is queued" "the run's state is named"
assert_absent "$GHD/reruns.log" "nothing is rerun"
pass "rerun-infra refuses while the run (or its requested rerun) is going"

infra_case
: >"$GHD/broken"
run_infra 301
expect_code 1 "$RC" "unreadable run output refuses"
assert_contains "$ERR" "unreadable gh output" "the unreadable run is named"
assert_absent "$GHD/reruns.log" "nothing is rerun"
pass "rerun-infra refuses an unreadable run"
