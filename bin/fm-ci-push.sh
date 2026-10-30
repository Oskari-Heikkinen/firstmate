#!/usr/bin/env bash
# fm-ci-push.sh - the push guard for a Firstmate-fork task's CI branches.
#
# A worker pushes to ci/** only through this script, which refuses a push CI
# would spend a run on for nothing and checks the rebased-landing rule, so
# neither depends on the worker remembering it.
#
# Usage (inside the task's worktree, with FM_HOME naming the supervising home):
#   fm-ci-push.sh try <task> [--repo <owner/repo>]
#     Pushes HEAD to ci/try/<task>, a run that is never a landing proof.
#   fm-ci-push.sh land <task> [--repo <owner/repo>]
#     Pushes HEAD to ci/<task>, the landing proof. HEAD must contain the
#     current origin/main. Before the push it runs the candidate-time consumer
#     notice, `fm-helper-consumers.sh pending --candidate HEAD`, and prints and
#     logs its `helper-candidate:` lines; they never change the outcome.
#   fm-ci-push.sh land <task> --full [--repo <owner/repo>]
#     Pushes HEAD to ci/full/<task>, only when HEAD's own ci/<task> run's plan
#     job chose the changed-area `ci` layout and that run has not gone red.
#   fm-ci-push.sh land <task> --rebased-from <tested-sha> [--repo <owner/repo>]
#     Pushes nothing. It checks that HEAD may fast-forward main without a new
#     run because it is <tested-sha> rebased onto a green main unchanged:
#       commit-list   origin/main..HEAD has the same commits as the tested
#                     range (merge-base of <tested-sha> and origin/main up to
#                     <tested-sha>): same count, order, author and message;
#       patch-id      each commit's `git patch-id --verbatim` (the stable id,
#                     without its whitespace folding) equals the tested one's;
#       tested-run    <tested-sha> has a green CI run on ci/<task>;
#       main-run      origin/main's own CI run is green.
#     It prints "fast-forward allowed without a new run" with the tested run's
#     URL, after the same candidate-time notice as land, or refuses naming
#     every condition that failed.
#   fm-ci-push.sh rerun-infra <run-id> [--flaky-ok] [--repo <owner/repo>]
#     Reruns a finished ci/** run's failed jobs once (`gh run rerun --failed`)
#     when bin/fm-ci-errors.sh classes every failure infra (or flaky too, with
#     --flaky-ok, which asserts the change does not touch what the flaky test
#     tests). It refuses while the run is still going, so a repeat call never
#     reruns twice, and when a failed job already is a rerun it appends a
#     `blocked` line to the task's status file instead.
#
# try and land refuse a dirty worktree, and refuse a push whose content
# already has a CI run: content is HEAD's tree plus the author and message of
# each commit not on origin/main, since CI's safety guard reads commit
# messages. try looks at runs on every ci/** branch, land at every one but
# ci/try/**, and --full at ci/full/**. A run on HEAD's exact commit on the
# target branch, or the target already at HEAD, is nothing to do: the script
# prints that run and exits 0. The runs searched are the newest 100 on each of
# the task's three CI branches and the newest 100 on the workflow.
# A plain push refused as non-fast-forward deletes the task's own CI branch and
# pushes again, which docs say to do by hand; it never forces.
#
# rerun-infra reads the classes from bin/fm-ci-errors.sh (fm-ci-errors/v1):
#   fm-ci-errors.sh --repo <owner/repo> --out $FM_HOME/data/ci-errors/<run-id> <run-id>
# which must exit 0 (75 means the run is still going) and write errors.json in
# that directory: schema fm-ci-errors/v1, run.id and run.attempt this run's,
# and one row per failed job and failing test, each with a numeric job_id and
# a class, one of infra, flaky, real, unknown. A missing classifier, any other
# exit, a list of another run or attempt, a failed job with no row, a row
# naming a job that did not fail, or any other class refuses. The list stays
# in that directory for the worker to read.
#
# Every gh call names the repository: --repo, else origin's GitHub URL. A gh
# call that fails or prints anything but the JSON expected refuses; no state
# GitHub did not confirm is taken as healthy.
#
# Log: one line per event (UTC time, what, why, what next) is appended to
# $FM_HOME/state/<task>.ci-push.log; a log that cannot be written refuses
# before anything is pushed.
#
# Environment:
#   FM_HOME                 required; the home whose state/ holds the log
#                           and the task's status file.
#   FM_CI_PUSH_ERRORS_BIN   the classifier, default bin/fm-ci-errors.sh next
#                           to this script (a test seam).
#   FM_TEST_HELPER_NOTICE_TIMEOUT  shortens the candidate-time notice's 60 s
#                           bound (a test seam).
#
# Exit status: 0 pushed, allowed, or nothing to do; 1 refused (the reason is
# on stderr and in the log); 2 usage error.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"

MAIN_BRANCH=main
MAIN_REF=refs/remotes/origin/main
WORKFLOW=ci.yml
PLAN_JOB='Plan the tiered run'

MODE=
TASK=
REPO=
LOG=
GH_OUT=
RUNS=
HEAD_SHA=
HEAD_TREE=
HEAD_KEY=
MAIN_SHA=
MATCH=

usage() {
  echo "usage: fm-ci-push.sh try <task> | land <task> [--full | --rebased-from <sha>] | rerun-infra <run-id> [--flaky-ok]  [--repo <owner/repo>]" >&2
  exit 2
}

log_event() {  # <line>
  [ -n "$LOG" ] || return 0
  printf '%s %s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$MODE" "$1" >> "$LOG"
}

refuse() {  # <reason>
  printf 'fm-ci-push: refused: %s\n' "$1" >&2
  log_event "refused: $1" 2>/dev/null || printf 'fm-ci-push: warning: could not log to %s\n' "$LOG" >&2
  exit 1
}

finish() {  # <line>: the stage's success outcome
  printf 'fm-ci-push: %s\n' "$1"
  log_event "$1" || printf 'fm-ci-push: warning: could not log to %s\n' "$LOG" >&2
  exit 0
}

open_log() {  # <task>
  [ -n "${FM_HOME:-}" ] || refuse "FM_HOME is not set; run as FM_HOME=<home> fm-ci-push.sh ..."
  [ -d "$FM_HOME/state" ] || refuse "FM_HOME has no state directory: $FM_HOME/state"
  LOG="$FM_HOME/state/$1.ci-push.log"
  if ! log_event "start: head ${HEAD_SHA:-n/a} in $PWD" 2>/dev/null; then
    LOG=
    refuse "cannot append to the log $FM_HOME/state/$1.ci-push.log"
  fi
}

repo_from_origin() {
  local url path
  url=$(git remote get-url origin 2>/dev/null) || return 1
  case "$url" in
    https://github.com/*) path=${url#https://github.com/} ;;
    git@github.com:*) path=${url#git@github.com:} ;;
    ssh://git@github.com/*) path=${url#ssh://git@github.com/} ;;
    *) return 1 ;;
  esac
  path=${path%/}
  path=${path%.git}
  printf '%s\n' "$path"
}

repo_valid() {
  local LC_ALL=C
  case "$1" in
    */*/*|/*|*/|.*|*/.*) return 1 ;;
    *[!A-Za-z0-9._/-]*) return 1 ;;
    */*) return 0 ;;
  esac
  return 1
}

# gh_json <what> <jq-check> <gh args...>: GH_OUT is gh's stdout, refused unless
# gh exits 0 and the output passes <jq-check>.
gh_json() {
  local what=$1 check=$2
  shift 2
  GH_OUT=$(gh "$@") || refuse "gh failed reading $what (gh $*)"
  printf '%s' "$GH_OUT" | jq -e "$check" >/dev/null 2>&1 \
    || refuse "unreadable gh output for $what (gh $*)"
}

# Run lines, newest first: id, branch, sha, tree, status, conclusion, url,
# created; callers keep the first seven fields.
RUN_CHECK='(.workflow_runs | type == "array") and all(.workflow_runs[];
  (.id | type == "number") and (.head_branch | type == "string")
  and (.head_sha | type == "string") and (.status | type == "string")
  and (.html_url | type == "string") and (.created_at | type == "string"))'
# shellcheck disable=SC2016 # a jq program; $repo is a jq variable.
RUN_ROWS='[.workflow_runs[]
  | select(.event == "push" and .head_repository.full_name == $repo)]
  | sort_by(.created_at) | reverse | .[]
  | [.id, .head_branch, .head_sha, (.head_commit.tree_id // "-"), .status,
     ((.conclusion // "-") | if . == "" then "-" else . end), .html_url,
     .created_at]
  | @tsv'

runs_query() {  # <query>: prints run lines, with created, for one runs listing
  gh_json "CI runs ($1)" "$RUN_CHECK" api "repos/$REPO/actions/workflows/$WORKFLOW/runs?$1"
  printf '%s' "$GH_OUT" | jq -r --arg repo "$REPO" "$RUN_ROWS" \
    || refuse "could not parse CI runs ($1)"
}

collect_task_runs() {  # sets RUNS: the task's three CI branches and the newest workflow runs
  local all q rows
  all=
  for q in "branch=ci/$TASK&event=push&per_page=100" \
    "branch=ci/try/$TASK&event=push&per_page=100" \
    "branch=ci/full/$TASK&event=push&per_page=100" \
    "event=push&per_page=100"; do
    rows=$(runs_query "$q") || exit 1
    [ -z "$rows" ] || all+=$rows$'\n'
  done
  RUNS=$(printf '%s' "$all" | LC_ALL=C sort -t "$(printf '\t')" -k8,8r | cut -f 1-7 | awk -F '\t' '!seen[$1]++')
}

commit_key() {  # <sha>: tree plus author and message of each commit not on main
  local sha=$1 base
  base=$(git merge-base "$sha" "$MAIN_REF") || return 1
  git rev-parse "$sha^{tree}" || return 1
  git log --reverse --format='%an <%ae>%n%B%x01' "$base..$sha"
}

have_commit() {  # <sha>: present locally, fetching it from origin if needed
  git cat-file -e "$1^{commit}" 2>/dev/null && return 0
  git fetch -q --no-tags origin "$1" 2>/dev/null && git cat-file -e "$1^{commit}" 2>/dev/null
}

branch_in_scope() {  # <scope> <branch>
  case "$1:$2" in
    try:ci/*) return 0 ;;
    land:ci/try/*) return 1 ;;
    land:ci/*) return 0 ;;
    full:ci/full/*) return 0 ;;
  esac
  return 1
}

# content_match <scope>: MATCH is the newest in-scope run whose content is
# HEAD's, as its run line; empty when none.
content_match() {
  local scope=$1 id branch sha tree status conclusion url key
  MATCH=
  while IFS=$'\t' read -r id branch sha tree status conclusion url; do
    [ -n "$id" ] || continue
    branch_in_scope "$scope" "$branch" || continue
    [ "$tree" = "$HEAD_TREE" ] || continue
    if [ "$sha" != "$HEAD_SHA" ]; then
      have_commit "$sha" \
        || refuse "run $url ran HEAD's tree on $sha, which cannot be fetched to compare its commit messages"
      key=$(commit_key "$sha") || refuse "cannot read the commits of $sha"
      [ "$key" = "$HEAD_KEY" ] || continue
    fi
    MATCH="$id"$'\t'"$branch"$'\t'"$sha"$'\t'"$tree"$'\t'"$status"$'\t'"$conclusion"$'\t'"$url"
    return 0
  done <<< "$RUNS"
}

run_desc() {  # <run line>
  local id branch sha tree status conclusion url
  IFS=$'\t' read -r id branch sha tree status conclusion url <<< "$1"
  if [ "$status" = completed ]; then
    printf '%s (%s on %s, %s)' "$url" "$conclusion" "$branch" "$sha"
  else
    printf '%s (%s on %s, %s)' "$url" "$status" "$branch" "$sha"
  fi
}

require_clean() {
  local dirty
  dirty=$(git status --porcelain) || refuse "cannot read the worktree status"
  [ -z "$dirty" ] || refuse "the worktree is dirty (commit or remove first): $(sed -n '1,3p' <<< "$dirty" | tr '\n' ' ')"
}

fetch_main() {
  git fetch -q --no-tags origin "+refs/heads/$MAIN_BRANCH:$MAIN_REF" \
    || refuse "cannot fetch origin/$MAIN_BRANCH"
  MAIN_SHA=$(git rev-parse --verify -q "$MAIN_REF^{commit}") || refuse "cannot read origin/$MAIN_BRANCH"
}

require_on_main() {
  git merge-base --is-ancestor "$MAIN_REF" HEAD \
    || refuse "HEAD does not contain origin/$MAIN_BRANCH ($MAIN_SHA); rebase onto it first"
}

remote_head() {  # <branch>: prints the branch's sha on origin, empty when absent
  local out
  out=$(git ls-remote origin "refs/heads/$1") || refuse "cannot read origin's $1"
  printf '%s\n' "${out%%[[:space:]]*}"
}

# already_there <target>: exits 0 when origin's <target> is HEAD already.
already_there() {
  local target=$1 id branch sha tree status conclusion url remote
  remote=$(remote_head "$target") || exit 1
  [ "$remote" = "$HEAD_SHA" ] || return 0
  while IFS=$'\t' read -r id branch sha tree status conclusion url; do
    if [ "$branch" = "$target" ] && [ "$sha" = "$HEAD_SHA" ]; then
      finish "nothing to push: $target is already at $HEAD_SHA, run $(run_desc "$id"$'\t'"$branch"$'\t'"$sha"$'\t'"$tree"$'\t'"$status"$'\t'"$conclusion"$'\t'"$url")"
    fi
  done <<< "$RUNS"
  finish "nothing to push: $target is already at $HEAD_SHA and its run is not listed yet; list it with gh run list -R $REPO --branch $target --commit $HEAD_SHA"
}

push_head() {  # <target>
  local target=$1 out
  if out=$(git push origin "HEAD:refs/heads/$target" 2>&1); then
    finish "pushed $HEAD_SHA to $target; wait for its run with gh run list -R $REPO --branch $target --commit $HEAD_SHA, at most every 2 minutes"
  fi
  case "$out" in
    *'[rejected]'*) ;;
    *) refuse "push of $HEAD_SHA to $target failed: $(printf '%s' "$out" | tr '\n' ' ')" ;;
  esac
  log_event "push to $target was refused as non-fast-forward; deleting the task's own $target and pushing again"
  out=$(git push origin --delete "refs/heads/$target" 2>&1) \
    || refuse "cannot delete $target after a non-fast-forward refusal: $(printf '%s' "$out" | tr '\n' ' ')"
  out=$(git push origin "HEAD:refs/heads/$target" 2>&1) \
    || refuse "push of $HEAD_SHA to $target failed after deleting it: $(printf '%s' "$out" | tr '\n' ' ')"
  finish "pushed $HEAD_SHA to $target (an older head there was deleted first); wait for its run with gh run list -R $REPO --branch $target --commit $HEAD_SHA, at most every 2 minutes"
}

# The candidate-time consumer notice (docs/helper-consumers.md): a declared
# Firstmate helper whose bytes HEAD changes and a consumer has not accepted gets
# its pending record and its owner's note before the landing push. Its lines
# are printed and logged; it never changes this script's outcome. It may fetch
# from origin, so it is bounded, and a stop or failure is one more line.
HELPER_NOTICE_TIMEOUT=${FM_TEST_HELPER_NOTICE_TIMEOUT:-60}
candidate_notice() {
  local top out line rc=0 nl=$'\n'
  top=$(git rev-parse --show-toplevel 2>/dev/null) || top=$PWD
  out=$(fm_run_timed "$HELPER_NOTICE_TIMEOUT" env FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-helper-consumers.sh" pending \
    --repo "$top" --candidate HEAD 2>&1) || rc=$?
  if fm_timed_out "$rc"; then
    out="${out:+$out$nl}helper-candidate: notice stopped after ${HELPER_NOTICE_TIMEOUT}s; the landing goes ahead, and the post-landing record still runs"
  elif [ "$rc" -ne 0 ]; then
    out="${out:+$out$nl}helper-candidate: notice failed (exit $rc); the landing goes ahead, and the post-landing record still runs"
  fi
  [ -n "$out" ] || return 0
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    printf '%s\n' "$line"
    log_event "$line" || printf 'fm-ci-push: warning: could not log to %s\n' "$LOG" >&2
  done <<< "$out"
}

read_head() {
  HEAD_SHA=$(git rev-parse --verify -q 'HEAD^{commit}') || refuse "not inside a git worktree with a commit"
}

prepare_push() {  # <scope> <target>
  local scope=$1 target=$2
  require_clean
  fetch_main
  [ "$scope" = try ] || require_on_main
  [ "$scope" != land ] || candidate_notice
  HEAD_TREE=$(git rev-parse 'HEAD^{tree}') || refuse "cannot read HEAD's tree"
  HEAD_KEY=$(commit_key HEAD) || refuse "cannot read HEAD's commits"
  collect_task_runs
  already_there "$target"
  content_match "$scope"
  [ -z "$MATCH" ] || refuse "HEAD's content already ran in $(run_desc "$MATCH"); cite that run instead of pushing it again"
}

mode_try() {
  prepare_push try "ci/try/$TASK"
  push_head "ci/try/$TASK"
}

mode_land() {
  prepare_push land "ci/$TASK"
  push_head "ci/$TASK"
}

# plan_layout <run-id>: prints the layout the run's plan job chose.
plan_layout() {
  local run_id=$1 job layouts
  gh_json "the jobs of run $run_id" '(.jobs | type == "array")' \
    api "repos/$REPO/actions/runs/$run_id/jobs?per_page=100"
  job=$(printf '%s' "$GH_OUT" | jq -r --arg name "$PLAN_JOB" \
    '[.jobs[] | select(.name == $name and .status == "completed" and .conclusion == "success")] | .[0].id // empty') \
    || refuse "could not parse the jobs of run $run_id"
  [ -n "$job" ] || refuse "run $run_id has no finished, green '$PLAN_JOB' job yet; wait for it"
  GH_OUT=$(gh run view --job "$job" --log -R "$REPO") || refuse "gh failed reading the plan job log of run $run_id"
  # The plan step's own summary line, e.g. "Layout: ci (event push, ref refs/heads/ci/x)".
  layouts=$(printf '%s\n' "$GH_OUT" | sed -n 's/.*Layout: \([a-z][a-z]*\) (event push, ref refs\/heads\/.*/\1/p' | LC_ALL=C sort -u)
  case "$layouts" in
    ''|*$'\n'*) refuse "the plan job log of run $run_id does not state one layout" ;;
  esac
  printf '%s\n' "$layouts"
}

mode_land_full() {
  local target="ci/full/$TASK" proof id branch sha tree status conclusion url layout
  prepare_push full "$target"
  proof=
  while IFS=$'\t' read -r id branch sha tree status conclusion url; do
    if [ "$branch" = "ci/$TASK" ] && [ "$sha" = "$HEAD_SHA" ]; then
      proof="$id"$'\t'"$branch"$'\t'"$sha"$'\t'"$tree"$'\t'"$status"$'\t'"$conclusion"$'\t'"$url"
      break
    fi
  done <<< "$RUNS"
  [ -n "$proof" ] || refuse "HEAD has no ci/$TASK run yet; run land first, and --full only if its plan chose the ci layout"
  IFS=$'\t' read -r id branch sha tree status conclusion url <<< "$proof"
  case "$status:$conclusion" in
    completed:success) ;;
    completed:*) refuse "HEAD's ci/$TASK run is red: $(run_desc "$proof"); fix it before a full run" ;;
  esac
  layout=$(plan_layout "$id") || exit 1
  case "$layout" in
    ci) ;;
    full) refuse "HEAD's ci/$TASK run already runs the full layout: $url; it is the full pass" ;;
    *) refuse "HEAD's ci/$TASK run planned layout '$layout', not ci: $url" ;;
  esac
  log_event "ci/$TASK run $url planned the ci layout; pushing the full layout"
  push_head "$target"
}

# newest_run <query> <branch> <sha>: prints the newest run line on <branch> at <sha>.
newest_run() {
  local rows
  rows=$(runs_query "$1") || exit 1
  awk -F '\t' -v b="$2" -v s="$3" '$2 == b && $3 == s { print; exit }' <<< "$rows" | cut -f 1-7
}

commit_ident() {  # <sha>
  git log -1 --format='%an <%ae>%n%B' "$1"
}

commit_patch_id() {  # <sha>: the verbatim patch id, or "empty" for no diff
  local diff id
  diff=$(git diff-tree -p --root --no-commit-id --no-renames --binary --full-index \
    --no-ext-diff --no-textconv --no-color "$1") || return 1
  [ -n "$diff" ] || { printf 'empty\n'; return 0; }
  id=$(printf '%s\n' "$diff" | git patch-id --verbatim) || return 1
  id=${id%% *}
  [ -n "$id" ] || return 1
  printf '%s\n' "$id"
}

mode_land_rebased() {
  local tested_arg=$1 tested tested_base n_t n_h i t h failed run main_run list_t list_h
  require_clean
  fetch_main
  require_on_main
  git patch-id --verbatim </dev/null >/dev/null 2>&1 \
    || refuse "this git ($(git --version)) has no patch-id --verbatim"
  have_commit "$tested_arg" || refuse "tested commit $tested_arg is neither local nor fetchable from origin"
  tested=$(git rev-parse --verify -q "$tested_arg^{commit}") || refuse "cannot resolve $tested_arg"
  tested_base=$(git merge-base "$tested" "$MAIN_REF") || refuse "$tested shares no history with origin/$MAIN_BRANCH"
  [ -z "$(git rev-list --merges "$tested_base..$tested")" ] || refuse "the tested range $tested_base..$tested has a merge commit"
  [ -z "$(git rev-list --merges "$MAIN_REF..HEAD")" ] || refuse "origin/$MAIN_BRANCH..HEAD has a merge commit"
  list_t=$(git rev-list --reverse "$tested_base..$tested") || refuse "cannot list the tested range"
  list_h=$(git rev-list --reverse "$MAIN_REF..HEAD") || refuse "cannot list origin/$MAIN_BRANCH..HEAD"
  [ -n "$list_t" ] || refuse "the tested range $tested_base..$tested is empty: $tested is already on origin/$MAIN_BRANCH"
  [ -n "$list_h" ] || refuse "origin/$MAIN_BRANCH..HEAD is empty"
  n_t=$(printf '%s\n' "$list_t" | grep -c .)
  n_h=$(printf '%s\n' "$list_h" | grep -c .)
  failed=

  if [ "$n_t" != "$n_h" ]; then
    failed+=" commit-list"
    printf 'fm-ci-push: commit-list FAILED: the tested range has %s commits, origin/%s..HEAD has %s\n' "$n_t" "$MAIN_BRANCH" "$n_h" >&2
  else
    i=1
    while [ "$i" -le "$n_t" ]; do
      t=$(printf '%s\n' "$list_t" | sed -n "${i}p")
      h=$(printf '%s\n' "$list_h" | sed -n "${i}p")
      if [ "$(commit_ident "$t")" != "$(commit_ident "$h")" ]; then
        failed+=" commit-list"
        printf 'fm-ci-push: commit-list FAILED: commit %s of %s, %s, has a different author or message than tested %s\n' "$i" "$n_h" "$h" "$t" >&2
        break
      fi
      i=$((i + 1))
    done
  fi
  case "$failed" in *commit-list*) ;; *) printf 'fm-ci-push: commit-list ok: %s commits, same authors and messages\n' "$n_h" ;; esac

  i=1
  while [ "$i" -le "$n_t" ] && [ "$i" -le "$n_h" ]; do
    t=$(printf '%s\n' "$list_t" | sed -n "${i}p")
    h=$(printf '%s\n' "$list_h" | sed -n "${i}p")
    t=$(commit_patch_id "$t") || refuse "cannot compute the patch id of tested commit $i"
    h=$(commit_patch_id "$h") || refuse "cannot compute the patch id of commit $i of HEAD"
    if [ "$t" != "$h" ]; then
      failed+=" patch-id"
      printf 'fm-ci-push: patch-id FAILED: commit %s of %s changed in the rebase (patch id %s, tested %s)\n' "$i" "$n_h" "$h" "$t" >&2
      break
    fi
    i=$((i + 1))
  done
  if [ "$n_t" != "$n_h" ]; then
    case "$failed" in *patch-id*) ;; *) failed+=" patch-id"; printf 'fm-ci-push: patch-id FAILED: the ranges have different commit counts\n' >&2 ;; esac
  fi
  case "$failed" in *patch-id*) ;; *) printf 'fm-ci-push: patch-id ok: every commit keeps its patch id\n' ;; esac

  run=$(newest_run "branch=ci/$TASK&head_sha=$tested&event=push&per_page=100" "ci/$TASK" "$tested") || exit 1
  if [ -z "$run" ]; then
    failed+=" tested-run"
    printf 'fm-ci-push: tested-run FAILED: %s has no CI run on ci/%s\n' "$tested" "$TASK" >&2
  else
    case "$(printf '%s' "$run" | cut -f 5,6)" in
      completed$'\t'success) printf 'fm-ci-push: tested-run ok: %s\n' "$(run_desc "$run")" ;;
      *) failed+=" tested-run"; printf 'fm-ci-push: tested-run FAILED: not green: %s\n' "$(run_desc "$run")" >&2 ;;
    esac
  fi

  main_run=$(newest_run "branch=$MAIN_BRANCH&head_sha=$MAIN_SHA&event=push&per_page=100" "$MAIN_BRANCH" "$MAIN_SHA") || exit 1
  if [ -z "$main_run" ]; then
    failed+=" main-run"
    printf 'fm-ci-push: main-run FAILED: origin/%s %s has no CI run yet\n' "$MAIN_BRANCH" "$MAIN_SHA" >&2
  else
    case "$(printf '%s' "$main_run" | cut -f 5,6)" in
      completed$'\t'success) printf 'fm-ci-push: main-run ok: %s\n' "$(run_desc "$main_run")" ;;
      *) failed+=" main-run"; printf 'fm-ci-push: main-run FAILED: not green: %s\n' "$(run_desc "$main_run")" >&2 ;;
    esac
  fi

  [ -z "$failed" ] || refuse "HEAD $HEAD_SHA is not $tested rebased onto a green main unchanged; failed:$failed; push it with land for a new run"
  candidate_notice
  finish "fast-forward allowed without a new run: $(printf '%s' "$run" | cut -f 7) proved $tested, and HEAD $HEAD_SHA replays its $n_h commits unchanged onto green origin/$MAIN_BRANCH $MAIN_SHA ($(printf '%s' "$main_run" | cut -f 7)); land with git push origin HEAD:$MAIN_BRANCH"
}

raise_blocked() {  # <note>
  local status_file="$FM_HOME/state/$TASK.status"
  if [ -f "$status_file" ] \
    && "$SCRIPT_DIR/fm-worker-status.sh" "$status_file" "$FM_HOME/config" "blocked [at=<epoch>]: $1"; then
    log_event "raised blocked in $status_file: $1"
    printf 'fm-ci-push: appended a blocked line to %s\n' "$status_file" >&2
  else
    printf 'fm-ci-push: could not append to %s; report it yourself: blocked: %s\n' "$status_file" "$1" >&2
  fi
}

mode_rerun_infra() {
  local run_id=$1 flaky_ok=$2 branch status conclusion url attempt run_attempt jobs failed errors_bin
  local errors_dir rc rows jid class name n_failed ok_classes bad seen
  gh_json "run $run_id" '(.id | type == "number") and (.head_branch | type == "string") and (.status | type == "string") and (.html_url | type == "string") and (.run_attempt | type == "number")' \
    api "repos/$REPO/actions/runs/$run_id"
  IFS=$'\t' read -r branch status conclusion url attempt <<< "$(printf '%s' "$GH_OUT" \
    | jq -r '[.head_branch, .status, (.conclusion // "-"), .html_url, .run_attempt] | @tsv')"
  case "$branch" in
    ci/try/*) TASK=${branch#ci/try/} ;;
    ci/full/*) TASK=${branch#ci/full/} ;;
    ci/*) TASK=${branch#ci/} ;;
    *) refuse "run $run_id is on $branch, not a ci/** branch" ;;
  esac
  fm_task_id_path_safe "$TASK" || refuse "run $run_id's branch $branch names no valid task id"
  open_log "$TASK"
  [ "$status" = completed ] || refuse "run $url is $status (attempt $attempt); a rerun waits until it finishes"
  [ "$conclusion" != success ] || finish "nothing to rerun: run $url is green"
  run_attempt=$attempt

  gh_json "the jobs of run $run_id" '(.jobs | type == "array") and all(.jobs[]; (.id | type == "number") and (.name | type == "string") and (.status | type == "string") and (.run_attempt | type == "number"))' \
    api "repos/$REPO/actions/runs/$run_id/jobs?per_page=100&filter=latest"
  jobs=$(printf '%s' "$GH_OUT" | jq -r '.jobs[] | [.id, .status, (.conclusion // "-"), .run_attempt, .name] | @tsv') \
    || refuse "could not parse the jobs of run $run_id"
  failed=
  n_failed=0
  while IFS=$'\t' read -r jid status conclusion attempt name; do
    [ -n "$jid" ] || continue
    [ "$status" = completed ] || refuse "job '$name' of $url is $status in a finished run"
    case "$conclusion" in
      success|skipped|neutral) continue ;;
    esac
    if [ "$attempt" -ge 2 ]; then
      raise_blocked "CI job '$name' failed again after its one infra rerun (attempt $attempt) in $url"
      refuse "job '$name' already had its one rerun and failed again (attempt $attempt): $url"
    fi
    failed+="$jid"$'\t'"$name"$'\n'
    n_failed=$((n_failed + 1))
  done <<< "$jobs"
  [ "$n_failed" -gt 0 ] || refuse "run $url concluded $conclusion with no failed job listed; classify it by hand"

  errors_bin=${FM_CI_PUSH_ERRORS_BIN:-$SCRIPT_DIR/fm-ci-errors.sh}
  [ -x "$errors_bin" ] \
    || refuse "the classifier $errors_bin (bin/fm-ci-errors.sh) is not on this base; classify every failed job of $url by hand, and only when all are infra run gh run rerun $run_id --failed -R $REPO once"
  errors_dir=$FM_HOME/data/ci-errors/$run_id
  rc=0
  "$errors_bin" --repo "$REPO" --out "$errors_dir" "$run_id" >/dev/null || rc=$?
  case "$rc" in
    0) ;;
    75) refuse "$errors_bin says run $url has not completed; rerun-infra once it has" ;;
    *) refuse "$errors_bin could not classify run $url (exit $rc)" ;;
  esac
  rows=$(jq -r --argjson id "$run_id" --argjson attempt "$run_attempt" '
    if .schema == "fm-ci-errors/v1" and .run.id == $id and .run.attempt == $attempt
      and (.rows | type == "array")
      and all(.rows[]; (.job_id | type == "number") and (.class | type == "string"))
    then .rows[] | [.job_id, .class] | @tsv
    else error("not the list of this run attempt") end' "$errors_dir/errors.json" 2>/dev/null) \
    || refuse "$errors_dir/errors.json is not an fm-ci-errors/v1 list for attempt $run_attempt of $url"
  ok_classes=' infra '
  [ "$flaky_ok" = 0 ] || ok_classes=' infra flaky '
  bad=
  seen=' '
  while IFS=$'\t' read -r jid class; do
    [ -n "$jid" ] || continue
    case "$class" in infra|flaky|real|unknown) ;; *) refuse "unrecognized class '$class' for job $jid in $errors_dir/errors.json" ;; esac
    case "$failed" in
      "$jid"$'\t'*|*$'\n'"$jid"$'\t'*) ;;
      *) refuse "the classifier names job $jid, which did not fail in $url" ;;
    esac
    seen+="$jid "
    case "$ok_classes" in *" $class "*) ;; *) bad+=" $jid:$class" ;; esac
  done <<< "$rows"
  while IFS=$'\t' read -r jid name; do
    [ -n "$jid" ] || continue
    case "$seen" in *" $jid "*) ;; *) refuse "the classifier gave failed job '$name' ($jid) no row" ;; esac
  done <<< "$failed"
  [ -z "$bad" ] || refuse "not every failure of $url is infra:$bad; read $errors_dir/errors.md and fix the real ones"
  log_event "every failed job of $url is classed${ok_classes% }; rerunning $n_failed failed jobs"
  gh run rerun "$run_id" --failed -R "$REPO" >/dev/null || refuse "gh run rerun $run_id --failed failed"
  finish "reran the $n_failed failed jobs of $url once (attempt $((run_attempt + 1))); a second failure of the same job is a blocker"
}

case "${1:-}" in
  -h|--help) sed -n '2,/^set -u$/{ /^set -u$/d; s/^# \{0,1\}//; p; }' "$0"; exit 0 ;;
  try|land|rerun-infra) MODE=$1 ;;
  *) usage ;;
esac
shift
[ "$#" -ge 1 ] || usage
target_arg=$1
shift
full=0
rebased_from=
flaky_ok=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo) [ "$#" -ge 2 ] || usage; REPO=$2; shift 2 ;;
    --full) [ "$MODE" = land ] || usage; full=1; shift ;;
    --rebased-from) [ "$MODE" = land ] && [ "$#" -ge 2 ] && [ -n "$2" ] || usage; rebased_from=$2; shift 2 ;;
    --flaky-ok) [ "$MODE" = rerun-infra ] || usage; flaky_ok=1; shift ;;
    *) usage ;;
  esac
done
[ "$full" = 0 ] || [ -z "$rebased_from" ] || usage
if [ -z "$REPO" ]; then
  REPO=$(repo_from_origin) || { echo "fm-ci-push: origin is not a GitHub URL; pass --repo <owner/repo>" >&2; exit 2; }
fi
repo_valid "$REPO" || { echo "fm-ci-push: not an owner/repo: $REPO" >&2; exit 2; }

if [ "$MODE" = rerun-infra ]; then
  case "$target_arg" in ''|*[!0-9]*) usage ;; esac
  mode_rerun_infra "$target_arg" "$flaky_ok"
fi

TASK=$target_arg
fm_task_id_path_safe "$TASK" || { echo "fm-ci-push: not a valid task id: $TASK" >&2; exit 2; }
read_head
open_log "$TASK"
if [ -n "$rebased_from" ]; then
  mode_land_rebased "$rebased_from"
elif [ "$full" = 1 ]; then
  mode_land_full
elif [ "$MODE" = try ]; then
  mode_try
else
  mode_land
fi
