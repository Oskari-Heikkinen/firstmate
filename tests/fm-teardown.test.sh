#!/usr/bin/env bash
# Tests for bin/fm-teardown.sh's landed-work safety and stale-lock recovery.
#
# The check refuses to tear down a worktree whose work has not LANDED, because
# treehouse return hard-resets the worktree. "Landed" means reachable from a remote
# OR - for a normal ship task whose commits are not so reachable - its PR is merged
# and GitHub reports a PR head that contains the current local work, or every branch
# commit was replayed onto the up-to-date default branch, or its content is already
# in that default branch.
#
# Covers three fixes:
#   - local-only fork-remote: a fork IS a remote, so fork-pushed upstream-
#     contribution PRs are teardown-eligible (the pre-fix code false-refused them).
#   - squash-merge-then-delete-branch: the branch's own commits live nowhere on a
#     remote after a squash merge deletes the head branch, yet the change is fully in
#     main. Reachability alone false-refused this common GitHub flow; the check now
#     recognizes a merged PR head containing the local work (or the content already
#     in main) as landed.
#   - teardown-lock-race: a killed crew process can leave a transient worktree
#     git index.lock that blocks teardown. The return path retries on the lock
#     error signature (even if the lock self-clears mid-check), then only removes a
#     provably stale lock before re-running safety checks.
#
# Matrix:
#   (a) local-only + HEAD on a fork remote-tracking branch     -> ALLOW  (fork fix)
#   (b) local-only + truly unpushed work (no remote, not main) -> REFUSE (safety)
#   (c) local-only + merged into local main, no remote         -> ALLOW  (no regression)
#   (d) no-mistakes + HEAD on origin remote-tracking branch    -> ALLOW  (no regression)
#   (e) no-mistakes + unpushed, no PR, content not in default  -> REFUSE (safety)
#   (f) local-only + truly unpushed + --force                  -> ALLOW  (escape hatch)
#   (g) no-mistakes + squash-merged PR, exact PR head          -> ALLOW  (squash fix)
#   (h) no-mistakes + no PR but content already in default     -> ALLOW  (content fallback)
#   (i) no-mistakes + dirty worktree, even when work landed     -> REFUSE (dirty wins)
#   (j) no-mistakes + gh lookup errors + content not in default -> REFUSE (fail-safe)
#   (k) no-mistakes + merged PR but HEAD moved afterward        -> REFUSE (stale PR)
#   (l) no-mistakes + stale origin/main but fetched content     -> ALLOW  (fresh fetch)
#   (m) no-mistakes + local HEAD ancestor of merged PR head     -> ALLOW  (lagging local)
#   (n) no-mistakes + replayed unpushed patch in merged PR head -> ALLOW  (replayed local)
#   (o) fm-pr-check rerun after HEAD moved                      -> no stale pr_head
#   (p) fm-pr-check when local HEAD lags                        -> record remote PR head
#   (q) no-mistakes + NO pr= recorded, PR discovered by branch  -> ALLOW  (yolo/no-CI merge)
#   (q2) no-mistakes + squash-merged, local followed pipeline rebase -> ALLOW
#   (q3) no-mistakes + squash-merged, same file, different content   -> REFUSE
#   (q4) no-mistakes + squash-merged rebased local plus extra commit -> REFUSE
#   (q5) gh down + squash-merged stale local, content not in default -> REFUSE
#   (q6) train replayed every commit onto main, branch deleted       -> ALLOW
#   (q7) train replay plus one extra local commit                    -> REFUSE
#   (q8) same file as a main commit, different patch                 -> REFUSE
#   (q9) every commit replayed but worktree dirty                    -> REFUSE
#   (q10) every commit replayed, untracked .claude/ scratch present  -> ALLOW
#
# Also covers backlog teardown-lock-race: a git index.lock left in the worktree by a
# killed crew process (bin/fm-teardown.sh's teardown_treehouse_return).
#   (r) provably-stale index.lock (old mtime, no live holder) -> lock removed, ALLOW
#   (s) index.lock with a live holder, any age                -> lock kept, REFUSE
#   (t) lsof error while checking index.lock                  -> lock kept, REFUSE
#   (u) dirty worktree after stale lock cleanup               -> lock removed, REFUSE
#   (v) non-linked repo index.lock                            -> lock removed, ALLOW
#   (w) index.lock mtime read failure                         -> lock kept, REFUSE
#   (x) transient lock cleared after first failed return      -> retry ALLOW
#   (y) persistent lock (never clears, not provably stale)    -> REFUSE loudly
#
# Nested repositories survive Treehouse's own `git clean -fd`:
#   (z1) scout + nested clone + scratch file                 -> no untracked entries
#   (z2) ship + nested clone, no --force                     -> REFUSE, bytes unchanged
#   (z3) return leaves residue                               -> lost-slot warning, cleanup, exit 4
#   (z3b) residue, then a later step refuses                 -> lost-slot warning still printed
#   (z3c) forced secondmate + child scout nested clone       -> child copy returns clean
#   (z3d) forced secondmate + child return leaves residue    -> warning, retirement completes, exit 4
#   (z3e) return removes the copy                            -> cannot-verify warning, exit 4
#   (z4) scout + ignored file                                -> ignored file survives
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

TEARDOWN="$ROOT/bin/fm-teardown.sh"
PR_CHECK="$ROOT/bin/fm-pr-check.sh"
TMP_ROOT=$(fm_test_tmproot fm-teardown-tests)
REAL_GIT_FOR_TEST=$(command -v git)
export REAL_GIT_FOR_TEST
REAL_PS_FOR_TEST=$(command -v ps)
export REAL_PS_FOR_TEST
REAL_LSOF_FOR_TEST=$(command -v lsof)
export REAL_LSOF_FOR_TEST
# The leaked-process cases assert what is reaped, not how long TERM is given,
# so a short grace keeps them from each waiting out a second per pass. The one
# case that needs a TERM handler to run during the grace pins the default.
export FM_TEARDOWN_REAP_GRACE_SECS=0.2

GIT_WORLD_TEMPLATE="$TMP_ROOT/.git-world-template"

# Build the shared git world under <dir>: a bare origin seeded with one commit,
# a project clone of it with origin/HEAD, and a task worktree on fm/task-x1.
build_git_world() {
  local dir=$1
  mkdir -p "$dir"
  # Bare origin so the clone has an `origin` remote and origin/HEAD.
  git init -q --bare "$dir/origin.git"
  git -C "$dir/origin.git" symbolic-ref HEAD refs/heads/main
  # Seed origin with one commit BEFORE cloning so the clone is not empty.
  git clone -q "$dir/origin.git" "$dir/_seed" 2>/dev/null
  git -C "$dir/_seed" -c user.email=t@t -c user.name=t \
    commit -q --allow-empty -m "origin baseline"
  git -C "$dir/_seed" push -q origin main
  rm -rf "$dir/_seed"
  # Clone as the project; give it a `main` branch and an origin/HEAD.
  git clone -q "$dir/origin.git" "$dir/project"
  git -C "$dir/project" remote set-head origin main 2>/dev/null || true
  # Add a worktree on a fresh task branch; that branch is where the crewmate commits.
  git -C "$dir/project" worktree add -q -b fm/task-x1 "$dir/wt" main
}
build_git_world "$GIT_WORLD_TEMPLATE"

# Build a fresh sandbox for one test case. Sets up:
#   $CASE/state/        - firstmate state dir (with a fresh watcher beacon)
#   $CASE/fakebin/      - mocks for treehouse, tmux (PATH-prepended by caller)
#   $CASE/origin.git/   - bare upstream repo (so the project clone has origin)
#   $CASE/project/      - clone of origin; acts as the firstmate project dir
#   $CASE/wt/           - a worktree of the project (the task worktree)
# Echoes the case dir.
make_case() {
  local name=$1 case_dir fakebin
  case_dir="$TMP_ROOT/$name"
  fakebin="$case_dir/fakebin"
  mkdir -p "$case_dir/state" "$case_dir/config" "$case_dir/data" "$fakebin"

  # Mocks for the post-check teardown steps. Refuse logic exits before these
  # run; the ALLOW cases need them so the script can complete cleanly.
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
# `treehouse return --force <wt>`: succeed silently.
exit 0
SH
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
# tmux kill-window etc.: succeed silently.
exit 0
SH
  # Default gh-axi mock: no PR is associated with the branch, and viewing any PR
  # number fails. This keeps the landed-work check hermetic (never reaching the real
  # gh-axi) and represents the common "no GitHub PR" baseline. Tests that need a
  # merged PR or a lookup error override this file with the helpers below.
  cat > "$fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "pr list") printf '%s\n' "count: 0 (showing first 0)" "pull_requests[]: []" ; exit 0 ;;
  "pr view") echo "error: pull request not found" >&2 ; exit 1 ;;
esac
exit 0
SH
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "pr view") echo "error: pull request not found" >&2 ; exit 1 ;;
esac
exit 0
SH
  # Default hermetic no-mistakes stub: `axi status` answers FM_FAKE_AXI_STATUS
  # verbatim (empty by default, i.e. no active run - the pre-teardown run-abort
  # step is then a no-op), `axi abort` appends one line to
  # FM_FAKE_NM_ABORT_LOG when set, the top-level `runs` listing answers
  # FM_FAKE_NM_RUNS_LIST verbatim (the real `no-mistakes runs --limit N` is
  # plain text with no run id and no quoting - see the ledger fixtures below),
  # and `runs` appends its own invocation to FM_FAKE_NM_RUNS_LOG when set, so
  # a test can prove whether the ledger fallback ever engaged.
  # The bare `axi` overview answers FM_FAKE_AXI_OVERVIEW verbatim (empty by
  # default, so no repository resolves and the pipeline-spend record is
  # written as unavailable).
  # This keeps every case hermetic - without it, `command -v no-mistakes`
  # would fall through to whatever real binary happens to be on the test
  # runner's own PATH. Tests exercising the run-abort path override
  # FM_FAKE_AXI_STATUS/FM_FAKE_NM_ABORT_LOG/FM_FAKE_NM_RUNS_LIST before
  # run_teardown.
  cat > "$fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  axi)
    shift
    case "${1:-}" in
      '')
        printf '%s\n' "${FM_FAKE_AXI_OVERVIEW:-}" ;;
      status)
        shift
        run_id=""
        if [ "${1:-}" = --run ]; then run_id=${2:-}; fi
        if [ -n "${FM_FAKE_NM_ABORT_LOG:-}" ] \
           && grep -Fxq "abort --run $run_id" "$FM_FAKE_NM_ABORT_LOG" 2>/dev/null \
           && [ "${FM_FAKE_NM_ABORT_NOOP:-0}" != 1 ]; then
          if [ "${FM_FAKE_NM_NOT_FOUND_AFTER_ABORT:-0}" = 1 ]; then
            printf 'error: "run \\"%s\\" not found"\n' "$run_id" >&2
            exit 1
          elif [ "${FM_FAKE_NM_EMPTY_AFTER_ABORT:-0}" = 1 ]; then
            exit 0
          elif [ -n "${FM_FAKE_AXI_STATUS_AFTER_ABORT:-}" ]; then
            printf '%s\n' "$FM_FAKE_AXI_STATUS_AFTER_ABORT"
          else
            printf 'run:\n  id: "%s"\n  outcome: cancelled\n' "$run_id"
          fi
        else
          printf '%s\n' "${FM_FAKE_AXI_STATUS:-}"
        fi
        ;;
      abort)
        shift
        [ -z "${FM_FAKE_NM_ABORT_LOG:-}" ] || printf 'abort %s\n' "$*" >> "$FM_FAKE_NM_ABORT_LOG"
        exit 0 ;;
    esac
    ;;
  runs)
    [ -z "${FM_FAKE_NM_RUNS_LOG:-}" ] || printf 'runs %s\n' "$*" >> "$FM_FAKE_NM_RUNS_LOG"
    printf '%s\n' "${FM_FAKE_NM_RUNS_LIST:-}" ;;
esac
exit 0
SH
  chmod +x "$fakebin/treehouse" "$fakebin/tmux" "$fakebin/gh-axi" "$fakebin/gh" "$fakebin/no-mistakes"

  # The git world is identical for every case, so it is built once, before the
  # concurrent cases start, and copied; the copy is then re-pointed at its own
  # origin and both worktree link files are rewritten to the copy's paths (git
  # worktree repair would keep the links into the still-valid template), leaving
  # every case with private repositories exactly as a fresh build would.
  cp -a "$GIT_WORLD_TEMPLATE/origin.git" "$GIT_WORLD_TEMPLATE/project" "$GIT_WORLD_TEMPLATE/wt" "$case_dir/"
  git -C "$case_dir/project" remote set-url origin "$case_dir/origin.git"
  printf 'gitdir: %s\n' "$case_dir/project/.git/worktrees/wt" > "$case_dir/wt/.git"
  printf '%s\n' "$case_dir/wt/.git" > "$case_dir/project/.git/worktrees/wt/gitdir"

  # Fresh watcher beacon so fm-guard stays quiet.
  touch "$case_dir/state/.last-watcher-beat"

  printf '%s\n' "$case_dir"
}

# Write a meta file for the task. Args: case_dir mode kind [worktree]
write_meta() {
  local case_dir=$1 mode=$2 kind=$3
  local wt=${4:-$case_dir/wt}
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=firstmate:fm-task-x1" \
    "endpoint_task_id=task-x1" \
    "worktree=$wt" \
    "project=$case_dir/project" \
    "kind=$kind" \
    "mode=$mode" \
    "spawn_gen=teardown-test-task-x1"
}

# Commit something on the worktree's task branch. Args: case_dir [message]
wt_commit() {
  local case_dir=$1 msg=${2:-wt work}
  git -C "$case_dir/wt" -c user.email=t@t -c user.name=t \
    commit -q --allow-empty -m "$msg"
}

# Add a fork bare repo and register it as a remote on the project, then push
# the worktree's task branch to it and fetch into the project so the worktree
# sees the remote-tracking ref. Args: case_dir
add_fork_with_pushed_branch() {
  local case_dir=$1
  git init -q --bare "$case_dir/fork.git"
  git -C "$case_dir/project" remote add fork "$case_dir/fork.git"
  # Push the task branch from the worktree to the fork, then fetch into project
  # so refs/remotes/fork/fm-task-x1 is visible from the worktree (shared object db).
  git -C "$case_dir/wt" push -q fork fm/task-x1
  git -C "$case_dir/project" fetch -q fork
}

# Commit a real file change on the worktree's task branch (unlike wt_commit, which
# makes an empty commit). A non-empty tree is what the content-in-default check
# inspects. Args: case_dir file content [message]
wt_commit_file() {
  local case_dir=$1 file=$2 content=$3 msg=${4:-add $2}
  printf '%s\n' "$content" > "$case_dir/wt/$file"
  git -C "$case_dir/wt" add -- "$file"
  git -C "$case_dir/wt" -c user.email=t@t -c user.name=t commit -q -m "$msg"
}

# Land <file>=<content> as a single commit on origin's default branch, simulating a
# squash merge whose net change matches the task branch but whose commit differs.
# After this, the branch's content is in origin/main even though the branch's own
# commits are not reachable from it. Args: case_dir file content
land_on_origin_main() {
  local case_dir=$1 file=$2 content=$3 tmp
  tmp="$case_dir/_land"
  git clone -q "$case_dir/origin.git" "$tmp"
  printf '%s\n' "$content" > "$tmp/$file"
  git -C "$tmp" add -- "$file"
  git -C "$tmp" -c user.email=t@t -c user.name=t commit -q -m "squash $file"
  git -C "$tmp" push -q origin HEAD:main
  rm -rf "$tmp"
}

# Override GitHub lookups to report PR 7 as merged with the supplied head.
add_gh_pr_merged_for_head() {
  local case_dir=$1 head=$2
  cat > "$case_dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "pr list")
    printf '%s\n' "count: 1 (showing first 1)" "pull_requests[1]{number,state}:" "  7,merged" ; exit 0 ;;
  "pr view")
    printf '%s\n' "pull_request:" "  number: 7" "  state: merged" '  merged: "2026-06-26T00:00:00Z"' ; exit 0 ;;
esac
exit 0
SH
  cat > "$case_dir/fakebin/gh" <<SH
#!/usr/bin/env bash
case "\${1:-} \${2:-}" in
  "pr view")
    case " \$* " in
      *"state,headRefOid,url"*) printf '%s\t%s\t%s\n' 'MERGED' '$head' 'https://github.com/example/repo/pull/7' ; exit 0 ;;
      *"headRefOid"*) printf '%s\n' '$head' ; exit 0 ;;
    esac
    ;;
esac
echo "error: pull request not found" >&2
exit 1
SH
  chmod +x "$case_dir/fakebin/gh-axi" "$case_dir/fakebin/gh"
}

# Squash-merged history whose pipeline rebased the branch onto a newer main that
# edited the same shared file. A local copy left behind by that rebase holds
# different content for the shared file, so its per-commit patch ids against the
# PR head differ and merge-tree against main conflicts; teardown refuses it on
# purpose rather than reading a shared path as proof the local content landed.
# local_mode: rebased | stale | rebased-plus-unlanded
# Echoes: <pr_head>
setup_squash_rebased_history() {
  local case_dir=$1 local_mode=$2 tmp local_head pr_head
  tmp="$case_dir/_shared_base"
  git clone -q "$case_dir/origin.git" "$tmp"
  printf '%s\n' base > "$tmp/shared.txt"
  git -C "$tmp" add -- shared.txt
  git -C "$tmp" -c user.email=t@t -c user.name=t commit -q -m "shared base"
  git -C "$tmp" push -q origin main
  git -C "$case_dir/wt" fetch -q origin
  git -C "$case_dir/wt" reset -q --hard origin/main
  rm -rf "$tmp"

  wt_commit_file "$case_dir" feature.txt hello "add feature"
  printf '%s\n' base feature-edit > "$case_dir/wt/shared.txt"
  git -C "$case_dir/wt" add -- shared.txt
  git -C "$case_dir/wt" -c user.email=t@t -c user.name=t \
    commit -q -m "edit shared from feature"
  local_head=$(git -C "$case_dir/wt" rev-parse HEAD)

  tmp="$case_dir/_main_move"
  git clone -q "$case_dir/origin.git" "$tmp"
  printf '%s\n' base main-edit > "$tmp/shared.txt"
  git -C "$tmp" add -- shared.txt
  git -C "$tmp" -c user.email=t@t -c user.name=t commit -q -m "main edits shared"
  git -C "$tmp" push -q origin main
  rm -rf "$tmp"

  tmp="$case_dir/_pipeline"
  git clone -q "$case_dir/origin.git" "$tmp"
  git -C "$tmp" checkout -q -b fm/task-x1
  printf '%s\n' hello > "$tmp/feature.txt"
  git -C "$tmp" add -- feature.txt
  git -C "$tmp" -c user.email=t@t -c user.name=t commit -q -m "add feature"
  printf '%s\n' base main-edit feature-edit > "$tmp/shared.txt"
  git -C "$tmp" add -- shared.txt
  git -C "$tmp" -c user.email=t@t -c user.name=t \
    commit -q -m "edit shared from feature"
  pr_head=$(git -C "$tmp" rev-parse HEAD)
  git -C "$tmp" push -q origin "HEAD:refs/pull/7/head"
  git -C "$tmp" checkout -q main
  git -C "$tmp" merge -q --squash fm/task-x1 >/dev/null
  git -C "$tmp" -c user.email=t@t -c user.name=t commit -q -m "feat: squash (#7)"
  git -C "$tmp" push -q origin main
  rm -rf "$tmp"

  git -C "$case_dir/project" fetch -q origin
  git -C "$case_dir/wt" fetch -q origin "refs/pull/7/head:refs/fm-test/pr-head"
  case "$local_mode" in
    rebased)
      git -C "$case_dir/wt" reset -q --hard "$pr_head"
      ;;
    stale)
      git -C "$case_dir/wt" reset -q --hard "$local_head"
      ;;
    rebased-plus-unlanded)
      git -C "$case_dir/wt" reset -q --hard "$pr_head"
      wt_commit_file "$case_dir" later.txt local-only "local follow-up"
      ;;
    *)
      fail "setup_squash_rebased_history: unknown local_mode $local_mode"
      ;;
  esac
  printf '%s\n' "$pr_head"
}

# A refusal must leave every recovery route intact: the isolated copy, its task
# branch still at the unlanded commit, and the durable task record. A completed
# teardown detaches and deletes that branch and removes the record, so these hold
# only while nothing destructive ran before the refusal was reported.
# Args: case_dir label head-before-teardown
assert_refusal_retained_task_state() {
  local case_dir=$1 label=$2 head=$3
  [ -d "$case_dir/wt" ] || fail "$label: refusal removed the isolated copy"
  [ "$(git -C "$case_dir/wt" rev-parse --abbrev-ref HEAD 2>/dev/null)" = fm/task-x1 ] \
    || fail "$label: refusal dropped the task branch"
  [ "$(git -C "$case_dir/wt" rev-parse HEAD 2>/dev/null)" = "$head" ] \
    || fail "$label: refusal moved the task branch off the unlanded commit"
  [ -e "$case_dir/state/task-x1.meta" ] \
    || fail "$label: refusal erased the durable task record"
}

append_pr_meta_for_current_head() {
  local case_dir=$1 head
  head=$(git -C "$case_dir/wt" rev-parse HEAD)
  printf '%s\n' \
    'pr=https://github.com/example/repo/pull/7' \
    "pr_head=$head" >> "$case_dir/state/task-x1.meta"
}

append_pr_meta_url() {
  local case_dir=$1
  printf '%s\n' 'pr=https://github.com/example/repo/pull/7' >> "$case_dir/state/task-x1.meta"
}

commit_tree_from_wt_head() {
  local case_dir=$1 parent=$2 msg=$3 tree
  tree=$(git -C "$case_dir/wt" rev-parse "$parent^{tree}") || return 1
  printf '%s\n' "$msg" | git -C "$case_dir/wt" commit-tree "$tree" -p "$parent"
}

land_equivalent_patch_on_origin_branch() {
  local case_dir=$1 branch=$2 file=$3 content=$4 msg=$5 tmp
  tmp="$case_dir/_equiv"
  git clone -q "$case_dir/origin.git" "$tmp"
  printf '%s\n' "$content" > "$tmp/$file"
  git -C "$tmp" add -- "$file"
  git -C "$tmp" -c user.email=t@t -c user.name=t commit -q -m "$msg"
  git -C "$tmp" push -q origin "HEAD:refs/heads/$branch"
  git -C "$case_dir/project" fetch -q origin "$branch"
  rm -rf "$tmp"
  git -C "$case_dir/project" rev-parse "refs/remotes/origin/$branch"
}

# Override gh-axi so every call fails, simulating an API/network error.
add_gh_axi_error() {
  local case_dir=$1
  cat > "$case_dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
echo "error: gh-axi unavailable" >&2
exit 1
SH
  cat > "$case_dir/fakebin/gh" <<'SH'
#!/usr/bin/env bash
echo "error: gh unavailable" >&2
exit 1
SH
  chmod +x "$case_dir/fakebin/gh-axi" "$case_dir/fakebin/gh"
}

# Override fakebin/treehouse so `treehouse return --force <wt>` fails with a
# git "file exists" lock error whenever the worktree's real index.lock is
# present, and succeeds once it is gone. This drives the lock through
# fm-teardown.sh's own retry-then-stale-cleanup logic (teardown_treehouse_return
# in bin/fm-teardown.sh) rather than hand-simulating that logic in the test.
add_lock_aware_treehouse() {
  local case_dir=$1
  cat > "$case_dir/fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = return ]; then
  shift
  wt=""
  for a in "$@"; do
    case "$a" in
      --force) ;;
      *) wt=$a ;;
    esac
  done
  lock=$(git -C "$wt" rev-parse --git-path index.lock 2>/dev/null || true)
  case "$lock" in
    /*|'') ;;
    *) lock="$wt/$lock" ;;
  esac
  if [ -n "$lock" ] && [ -e "$lock" ]; then
    echo "fatal: Unable to create '$lock': File exists." >&2
    exit 128
  fi
  exit 0
fi
exit 0
SH
  chmod +x "$case_dir/fakebin/treehouse"
}

# treehouse return fails once with the index.lock signature, then clears the lock
# (simulating a dying crew git process finishing) so the next retry succeeds.
# The first failure always reports the lock path even if the file is removed in
# the same attempt - matching the production race where the lock self-clears
# between the failed return and the supervisor's existence check.
add_transient_lock_treehouse() {
  local case_dir=$1
  cat > "$case_dir/fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = return ]; then
  shift
  wt=""
  for a in "$@"; do
    case "$a" in
      --force) ;;
      *) wt=$a ;;
    esac
  done
  lock=$(git -C "$wt" rev-parse --git-path index.lock 2>/dev/null || true)
  case "$lock" in
    /*|'') ;;
    *) lock="$wt/$lock" ;;
  esac
  count_file="${TREEHOUSE_ATTEMPT_FILE:?}"
  count=0
  if [ -f "$count_file" ]; then
    count=$(cat "$count_file")
  fi
  count=$(( count + 1 ))
  printf '%s\n' "$count" > "$count_file"
  if [ "$count" -eq 1 ]; then
    # Emit the real git signature, then drop the lock so a lock-existence-only
    # recovery path would wrongly abort without retrying.
    if [ -n "$lock" ]; then
      echo "fatal: Unable to create '$lock': File exists." >&2
      rm -f "$lock"
    else
      echo "fatal: Unable to create 'index.lock': File exists." >&2
    fi
    exit 128
  fi
  exit 0
fi
exit 0
SH
  chmod +x "$case_dir/fakebin/treehouse"
}

# treehouse return always fails with the lock signature while the lock file
# remains; used to assert exhausted retries still refuse loudly.
add_persistent_lock_treehouse() {
  local case_dir=$1
  cat > "$case_dir/fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = return ]; then
  shift
  wt=""
  for a in "$@"; do
    case "$a" in
      --force) ;;
      *) wt=$a ;;
    esac
  done
  lock=$(git -C "$wt" rev-parse --git-path index.lock 2>/dev/null || true)
  case "$lock" in
    /*|'') ;;
    *) lock="$wt/$lock" ;;
  esac
  if [ -z "$lock" ]; then
    lock="index.lock"
  fi
  echo "fatal: Unable to create '$lock': File exists." >&2
  exit 128
fi
exit 0
SH
  chmod +x "$case_dir/fakebin/treehouse"
}

git_index_lock_path() {
  local dir=$1 lock abs_dir
  lock=$(git -C "$dir" rev-parse --git-path index.lock)
  case "$lock" in
    /*) printf '%s\n' "$lock" ;;
    *)
      abs_dir=$(cd "$dir" && pwd -P)
      printf '%s/%s\n' "$abs_dir" "$lock"
      ;;
  esac
}

# fakebin/lsof stub: no process ever holds anything open (lsof's not-found exit
# code), so a lock's staleness is decided by age alone. The cwd scan is a
# separate successful empty query.
add_lsof_no_holder() {
  local case_dir=$1
  cat > "$case_dir/fakebin/lsof" <<'SH'
#!/usr/bin/env bash
case " $* " in
  *" -d cwd "*) exit 0 ;;
esac
exit 1
SH
  chmod +x "$case_dir/fakebin/lsof"
}

# fakebin/lsof stub: a live process holds every queried path open, so a lock is
# never judged stale regardless of its age.
add_lsof_live_holder() {
  local case_dir=$1
  cat > "$case_dir/fakebin/lsof" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$case_dir/fakebin/lsof"
}

add_lsof_error() {
  local case_dir=$1
  cat > "$case_dir/fakebin/lsof" <<'SH'
#!/usr/bin/env bash
echo "lsof: simulated failure for ${1:-unknown}" >&2
exit 2
SH
  chmod +x "$case_dir/fakebin/lsof"
}

add_stat_error() {
  local case_dir=$1
  cat > "$case_dir/fakebin/stat" <<'SH'
#!/usr/bin/env bash
echo "stat: simulated failure" >&2
exit 1
SH
  chmod +x "$case_dir/fakebin/stat"
}

add_git_status_lock_failure() {
  local case_dir=$1
  cat > "$case_dir/fakebin/git" <<'SH'
#!/usr/bin/env bash
real=${REAL_GIT_FOR_TEST:?}
dir=
args=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    -C)
      dir=$2
      args+=("$1" "$2")
      shift 2
      ;;
    *)
      args+=("$1")
      shift
      ;;
  esac
done
if [ -n "$dir" ] && [ "${args[2]:-}" = status ] && [ "${args[3]:-}" = --porcelain ]; then
  lock=$("$real" -C "$dir" rev-parse --git-path index.lock 2>/dev/null || true)
  case "$lock" in
    /*|'') ;;
    *) lock="$dir/$lock" ;;
  esac
  if [ -n "$lock" ] && [ -e "$lock" ]; then
    echo "fatal: Unable to create '$lock': File exists." >&2
    exit 128
  fi
fi
exec "$real" "${args[@]}"
SH
  chmod +x "$case_dir/fakebin/git"
}

# Run teardown with PATH mocking. Args: case_dir [extra args...]
run_teardown() {
  local case_dir=$1; shift
  # FM_DATA_OVERRIDE is pinned to the case dir because teardown closes this
  # home's backlog item itself; without it $DATA would resolve to the real
  # repo's own home and a test could mutate live records.
  # Teardown's advisory fm-guard pass (stale-watcher and tangle warnings, owned
  # by the guard's own tests) is skipped through its existing knob, because it
  # costs a harness-detection process walk per run and no case here asserts on
  # it; test_local_only_fork_remote_allows sets 0 to keep one real pass.
  FM_TEARDOWN_GUARD_DONE="${FM_TEARDOWN_GUARD_DONE:-1}" \
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  FM_DATA_OVERRIDE="$case_dir/data" \
  FM_CONFIG_OVERRIDE="$case_dir/config" \
  PATH="$case_dir/fakebin:${FM_TEARDOWN_TEST_PATH:-$PATH}" \
    "$TEARDOWN" task-x1 "$@"
}

# Seed a real backlog carrying task-x1 as In flight, so a teardown in this case
# has a row to close. Uses the real tasks-axi (the fixture's default fakebin has
# no tasks-axi stub, so PATH resolves the installed one).
seed_backlog_in_flight() {
  local case_dir=$1 kind=${2:-ship}
  mkdir -p "$case_dir/data"
  printf '%s\n' '# Backlog' '' '## In flight' '' '## Queued' '' '## Done' \
    > "$case_dir/data/backlog.md"
  tasks-axi add task-x1 "teardown fixture task" --kind "$kind" \
    --file "$case_dir/data/backlog.md" >/dev/null
  tasks-axi start task-x1 --file "$case_dir/data/backlog.md" >/dev/null
}

backlog_row_state() {
  local case_dir=$1
  tasks-axi show task-x1 --file "$case_dir/data/backlog.md" 2>/dev/null |
    sed -n 's/^  state: *//p' | head -1
}

# Build the teardown test's executable search path without lsof, regardless of
# whether the host installs it in /usr/bin, /usr/sbin, or a package-manager bin.
make_path_without_lsof() {  # <case-dir>
  local case_dir=$1 path_dir="$1/path-without-lsof" cmd resolved
  mkdir -p "$path_dir"
  for cmd in awk bash basename cat chmod cp cut date dirname env find git grep head hostname id ln \
    mkdir mktemp mv perl ps readlink realpath rm sed sh sleep sort stat tail timeout tr uname wc xargs; do
    resolved=$(command -v "$cmd" 2>/dev/null) || continue
    case "$resolved" in /*) ln -sf "$resolved" "$path_dir/$cmd" ;; esac
  done
  printf '%s\n' "$path_dir"
}

test_local_only_fork_remote_allows() {
  local case_dir rc
  case_dir=$(make_case fork-allow)
  write_meta "$case_dir" local-only ship
  wt_commit "$case_dir" "fix the thing"
  add_fork_with_pushed_branch "$case_dir"
  # The supervision branch's bounded per-task outcome cache is a footprint of
  # the retired task, not a record anything reads after it is gone.
  printf 'fm-branch-outcome-index-v1\t5\t0\t-\n' > "$case_dir/state/.task-x1.branch-outcome-index"
  # The spawn start record is home-wide history that token attribution joins
  # on after the task is gone, so cleanup must leave it intact.
  printf '%s\n' '{"schema":"fm-spawn-start.v1","task":"task-x1","spawn_epoch":1}' \
    > "$case_dir/state/spawn-starts.jsonl"

  set +e
  FM_TEARDOWN_GUARD_DONE=0 run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "fork-allow: teardown should succeed when HEAD is on a fork remote"
  grep -q '"task":"task-x1"' "$case_dir/state/spawn-starts.jsonl" \
    || fail "fork-allow: teardown removed the task's durable spawn start record"
  ! grep -q REFUSED "$case_dir/stderr" || fail "fork-allow: teardown printed a REFUSED line"
  [ ! -e "$case_dir/state/.task-x1.branch-outcome-index" ] \
    || fail "fork-allow: teardown left the task's branch outcome index behind"
  # The supervision branch reports the teardown it just performed AFTER the
  # task's records are gone (bin/fm-branch-prompt.sh); that report must be
  # stored, must publish its ready sequence, and must not recreate the index.
  post_seq=$(FM_STATE_OVERRIDE="$case_dir/state" "$ROOT/bin/fm-branch-outcome.sh" append \
    --task task-x1 --verdict captain --summary 'PR merged and cleaned up') \
    || fail "fork-allow: post-teardown branch report was refused"
  [ "$post_seq" = 1 ] || fail "fork-allow: post-teardown branch report got seq $post_seq, expected 1"
  grep -q '"task":"task-x1"' "$case_dir/state/branch-outcomes.jsonl" \
    || fail "fork-allow: post-teardown branch report was not stored"
  [ ! -e "$case_dir/state/.task-x1.branch-outcome-index" ] \
    || fail "fork-allow: post-teardown branch report recreated the retired task index"
  [ "$(cat "$case_dir/state/.branch-outcome-index-ready")" = 1 ] \
    || fail "fork-allow: post-teardown branch report did not publish its ready sequence"
  jq -e --arg id task-x1 '
    .schema == "fm-secondmate-home-summary.v1"
    and all(.endpoints[]; .id != $id)
  ' "$case_dir/state/home-summary.json" >/dev/null \
    || fail "successful task teardown did not publish the task's removal from the home summary ledger"
  pass "local-only worktree with HEAD on a fork remote is torn down and the home summary is refreshed"
}

test_teardown_closes_the_backlog_item_itself() {
  local case_dir out
  case_dir=$(make_case tasks-axi-close)
  write_meta "$case_dir" no-mistakes ship
  printf '%s\n' 'pr=https://github.com/example/repo/pull/7' >> "$case_dir/state/task-x1.meta"
  seed_backlog_in_flight "$case_dir"

  out=$(run_teardown "$case_dir") || fail "teardown failed with a real backlog"
  [ "$(backlog_row_state "$case_dir")" = "done" ] \
    || fail "teardown returned success while its backlog item was still open: $(backlog_row_state "$case_dir")"
  assert_grep 'https://github.com/example/repo/pull/7' "$case_dir/data/backlog.md" \
    "closed backlog item did not record the task's PR"
  assert_absent "$case_dir/state/task-x1.backlog-close" \
    "a landed close left its pending-close record behind"
  printf '%s\n' "$out" | grep -F 'bin/fm-tasks-axi.sh ready' >/dev/null \
    || fail "teardown dropped the dependency-cleared follow-up: $out"
  printf '%s\n' "$out" | grep -F 'check date gates' >/dev/null \
    || fail "teardown did not preserve date-gate check: $out"
  printf '%s\n' "$out" | grep -F 'Run tasks-axi done' >/dev/null \
    && fail "teardown still asked a later turn to close the item it already closed: $out"
  pass "teardown closes its own backlog item before reporting success"
}

test_teardown_closes_a_gerrit_task_with_its_change_url_as_a_note() {
  local case_dir out real_tasks_axi gerrit_url=https://gerrit.example.com/c/project/+/12345
  case_dir=$(make_case tasks-axi-close-gerrit)
  write_meta "$case_dir" no-mistakes ship
  printf 'pr=%s\n' "$gerrit_url" >> "$case_dir/state/task-x1.meta"
  seed_backlog_in_flight "$case_dir"
  # Pin the refusal tasks-axi applies to a --pr link that is not a canonical
  # GitHub pull request, so this case keeps reproducing whatever the installed
  # release accepts.
  real_tasks_axi=$(command -v tasks-axi)
  cat > "$case_dir/fakebin/tasks-axi" <<SH
#!/usr/bin/env bash
previous=
for arg in "\$@"; do
  if [ "\$previous" = --pr ] && ! [[ "\$arg" =~ ^https://github\.com/[^/]+/[^/]+/pull/[0-9]+\$ ]]; then
    echo "error: \"Task pr link must be a canonical pull request URL\""
    exit 1
  fi
  previous=\$arg
done
exec "$real_tasks_axi" "\$@"
SH
  chmod +x "$case_dir/fakebin/tasks-axi"

  out=$(run_teardown "$case_dir" 2>&1) || fail "teardown of a landed Gerrit task failed: $out"
  [ "$(backlog_row_state "$case_dir")" = "done" ] \
    || fail "teardown left a landed Gerrit task's backlog item at $(backlog_row_state "$case_dir"): $out"
  tasks-axi show task-x1 --file "$case_dir/data/backlog.md" --full \
    | grep -F "body: \"Gerrit change $gerrit_url\"" >/dev/null \
    || fail "closed Gerrit backlog item did not record its change URL as a note"
  assert_absent "$case_dir/state/task-x1.backlog-close" \
    "a landed Gerrit close left its pending-close record behind"

  case_dir=$(make_case tasks-axi-close-github-under-refusal)
  write_meta "$case_dir" no-mistakes ship
  printf '%s\n' 'pr=https://github.com/example/repo/pull/7' >> "$case_dir/state/task-x1.meta"
  seed_backlog_in_flight "$case_dir"
  cp "$TMP_ROOT/tasks-axi-close-gerrit/fakebin/tasks-axi" "$case_dir/fakebin/tasks-axi"
  out=$(run_teardown "$case_dir" 2>&1) || fail "teardown of a landed GitHub task failed: $out"
  tasks-axi show task-x1 --file "$case_dir/data/backlog.md" \
    | grep -F 'links: "pr:https://github.com/example/repo/pull/7"' >/dev/null \
    || fail "a GitHub pull request no longer closed as the item's pr link"
  pass "teardown closes a landed Gerrit task with its change URL as a note and a GitHub task with --pr"
}

test_teardown_manual_backend_leaves_the_backlog_to_the_operator() {
  local case_dir out backlog_path
  case_dir=$(make_case tasks-axi-manual-optout)
  write_meta "$case_dir" no-mistakes ship
  printf '%s\n' 'pr=https://github.com/example/repo/pull/7' >> "$case_dir/state/task-x1.meta"
  printf '%s\n' manual > "$case_dir/config/backlog-backend"
  seed_backlog_in_flight "$case_dir"

  out=$(run_teardown "$case_dir") || fail "teardown failed with manual backlog backend"
  [ "$(backlog_row_state "$case_dir")" = in_flight ] \
    || fail "manual backlog backend was mutated by teardown anyway"
  backlog_path=$(cd "$case_dir/data" && pwd -P)/backlog.md
  printf '%s\n' "$out" | grep -F "Update $backlog_path - move task-x1 to Done" >/dev/null \
    || fail "teardown did not prompt manual backlog update under opt-out: $out"
  pass "teardown honors config/backlog-backend=manual and still finishes cleanly"
}

test_local_only_truly_unpushed_refuses() {
  local case_dir rc
  case_dir=$(make_case truly-unpushed)
  write_meta "$case_dir" local-only ship
  wt_commit "$case_dir" "unpushed work"
  # Refused cleanup must preserve recovery records with the unlanded work.
  printf 'exited=1\n' > "$case_dir/state/task-x1.control-exit"
  printf 'key=boot:test\nresult=relaunched\n' > "$case_dir/state/task-x1.reboot-relaunch"
  # No fork, no push to origin, not merged into main.

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "truly-unpushed: teardown should refuse"
  grep -q REFUSED "$case_dir/stderr" || fail "truly-unpushed: no REFUSED line in stderr"
  assert_present "$case_dir/state/task-x1.control-exit" "refused cleanup lost the deliberate-exit record"
  assert_present "$case_dir/state/task-x1.reboot-relaunch" "refused cleanup lost the reboot-relaunch record"
  pass "local-only worktree with truly unpushed work is refused (safety preserved)"
}

test_local_only_merged_to_local_main_allows() {
  local case_dir rc
  case_dir=$(make_case merged-main)
  write_meta "$case_dir" local-only ship
  wt_commit "$case_dir" "merged work"
  # Fast-forward the project's main to the worktree's HEAD commit so HEAD is
  # reachable from main. update-ref works whether or not main is checked out,
  # and the worktree shares the project's object db so the commit is visible.
  local wt_head
  wt_head=$(git -C "$case_dir/wt" rev-parse HEAD)
  git -C "$case_dir/project" update-ref refs/heads/main "$wt_head"
  printf 'exited=1\n' > "$case_dir/state/task-x1.control-exit"
  printf 'key=boot:test\nresult=relaunched\n' > "$case_dir/state/task-x1.reboot-relaunch"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "merged-main: teardown should succeed when work is merged into local main"
  ! grep -q REFUSED "$case_dir/stderr" || fail "merged-main: teardown printed a REFUSED line"
  assert_absent "$case_dir/state/task-x1.control-exit" "cleanup left the deliberate-exit record"
  assert_absent "$case_dir/state/task-x1.reboot-relaunch" "cleanup left the reboot-relaunch record"
  pass "local-only worktree with work merged into local main is torn down (no regression)"
}

test_no_mistakes_origin_remote_allows() {
  local case_dir rc
  case_dir=$(make_case nm-origin)
  write_meta "$case_dir" no-mistakes ship
  wt_commit "$case_dir" "shippable work"
  # Push the task branch to origin and fetch so the worktree sees it.
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/project" fetch -q origin

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "nm-origin: teardown should succeed when HEAD is on origin"
  ! grep -q REFUSED "$case_dir/stderr" || fail "nm-origin: teardown printed a REFUSED line"
  grep -F 'blockers are gone and date is due' "$case_dir/stdout" >/dev/null \
    || fail "nm-origin: teardown manual prompt did not preserve date-gate check"
  pass "no-mistakes worktree with HEAD on origin is torn down (no regression)"
}

test_no_mistakes_truly_unpushed_refuses() {
  local case_dir rc
  case_dir=$(make_case nm-unpushed)
  write_meta "$case_dir" no-mistakes ship
  # Real content that is not pushed, has no PR (default gh-axi mock), and never
  # landed on origin/main: genuinely unlanded work that must still refuse.
  wt_commit_file "$case_dir" feature.txt hello "unpushed work"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "nm-unpushed: teardown should refuse"
  grep -q REFUSED "$case_dir/stderr" || fail "nm-unpushed: no REFUSED line in stderr"
  pass "no-mistakes worktree with genuinely unlanded work is refused (safety preserved)"
}

test_direct_push_landed_on_origin_main_allows() {
  local case_dir rc
  case_dir=$(make_case direct-push-landed)
  write_meta "$case_dir" direct-push ship
  seed_backlog_in_flight "$case_dir"
  wt_commit_file "$case_dir" feature.txt landed "direct-push work"
  # The worker landed by fast-forwarding origin's default branch itself: no PR
  # exists and none is recorded, and the push updates the shared origin/main.
  git -C "$case_dir/wt" push -q origin HEAD:main
  # Exercise the real post-landing hook for an explicitly passed clone outside
  # projects/, preserving the old cleanup path's registered-location support.
  local landed_head
  landed_head=$(git -C "$case_dir/wt" rev-parse HEAD)

  set +e
  FM_HOME="$case_dir" run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "direct-push-landed: teardown should succeed when HEAD is on origin/main with no PR"
  assert_equals "$landed_head" "$(git -C "$case_dir/project" rev-parse HEAD)" \
    "direct-push-landed: cleanup refreshes the main home's clone"
  assert_absent "$case_dir/state/landed-sync/project.reported" \
    "direct-push-landed: a successful refresh needs no report"
  ! grep -q REFUSED "$case_dir/stderr" || fail "direct-push-landed: teardown printed a REFUSED line"
  [ "$(backlog_row_state "$case_dir")" = "done" ] \
    || fail "direct-push-landed: backlog item was not closed: $(backlog_row_state "$case_dir")"
  pass "direct-push worktree whose head landed on origin/main is torn down with no PR recorded"
}

test_direct_push_unlanded_refuses() {
  local case_dir rc
  case_dir=$(make_case direct-push-unlanded)
  write_meta "$case_dir" direct-push ship
  wt_commit_file "$case_dir" feature.txt unlanded "direct-push work not pushed"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "direct-push-unlanded: teardown should refuse"
  grep -q REFUSED "$case_dir/stderr" || fail "direct-push-unlanded: no REFUSED line in stderr"
  pass "direct-push worktree with work not on origin is refused"
}

# Override gh-axi so an OPEN PR is listed on the task branch only when the
# lookup asks for open PRs, matching how the forge filters by state.
add_gh_axi_open_pr_on_branch() {
  local case_dir=$1
  cat > "$case_dir/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "pr list")
    case " $* " in
      *" --state open"*" --head fm/task-x1 "*)
        printf '%s\n' "count: 1 (showing first 1)" "pull_requests[1]{number,state}:" "  9,open" ; exit 0 ;;
    esac
    printf '%s\n' "count: 0 (showing first 0)" "pull_requests[]: []" ; exit 0 ;;
  "pr view") echo "error: pull request not found" >&2 ; exit 1 ;;
esac
exit 0
SH
  chmod +x "$case_dir/fakebin/gh-axi"
}

# A direct-push task switched to a PR mid-flight pushed its branch and opened a
# PR, so the branch counts as landed; cleanup must still refuse while that PR is
# open, because the record is the only thing tracking it.
test_direct_push_with_open_pr_refuses() {
  local case_dir rc head
  case_dir=$(make_case direct-push-open-pr)
  write_meta "$case_dir" direct-push ship
  wt_commit_file "$case_dir" feature.txt pr "work shipped as a PR"
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/project" fetch -q origin
  head=$(git -C "$case_dir/wt" rev-parse HEAD)
  add_gh_axi_open_pr_on_branch "$case_dir"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "direct-push-open-pr: teardown should refuse"
  grep -q 'REFUSED: task task-x1 records mode=direct-push, but PR #9 is open' "$case_dir/stderr" \
    || fail "direct-push-open-pr: refusal did not name the open PR: $(cat "$case_dir/stderr")"
  grep -qF 'bin/fm-promote.sh task-x1 --switch-mode' "$case_dir/stderr" \
    || fail "direct-push-open-pr: refusal did not name the mode switch"
  assert_refusal_retained_task_state "$case_dir" direct-push-open-pr "$head"
  pass "direct-push task whose pushed branch has an open PR is refused, keeping its record"
}

# The open-PR refusal is confined to direct-push: a PR-mode task whose branch
# was pushed to a fork for an upstream contribution still tears down as landed
# while that contribution PR is open.
test_pr_mode_fork_branch_with_open_pr_allows() {
  local case_dir rc
  case_dir=$(make_case fork-open-pr)
  write_meta "$case_dir" direct-PR ship
  wt_commit "$case_dir" "upstream contribution"
  add_fork_with_pushed_branch "$case_dir"
  add_gh_axi_open_pr_on_branch "$case_dir"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "fork-open-pr: teardown should succeed for a fork-pushed PR-mode branch"
  ! grep -q REFUSED "$case_dir/stderr" || fail "fork-open-pr: teardown printed a REFUSED line"
  pass "PR-mode task pushed to a fork with an open PR is still torn down as landed"
}

# Simulate a merge train landing the task branch: push it to origin, replay
# (cherry-pick) every branch commit onto origin's default branch after one
# unrelated main commit so the landed SHAs differ, then change the replayed
# file again on main so a 3-way content merge with the local head conflicts
# (the content-in-default fallback alone cannot prove these landed), and finally
# delete the branch from origin and prune it from the project. Args: case_dir
train_land_branch_and_delete() {
  local case_dir=$1 tmp base
  tmp="$case_dir/_train"
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git clone -q "$case_dir/origin.git" "$tmp"
  printf '%s\n' unrelated > "$tmp/unrelated.txt"
  git -C "$tmp" add -- unrelated.txt
  git -C "$tmp" -c user.email=t@t -c user.name=t commit -q -m "unrelated main work"
  base=$(git -C "$tmp" merge-base HEAD origin/fm/task-x1)
  git -C "$tmp" -c user.email=train@t -c user.name=train \
    cherry-pick "$base..origin/fm/task-x1" >/dev/null
  printf '%s\n' "later main edit" > "$tmp/feature.txt"
  git -C "$tmp" add -- feature.txt
  git -C "$tmp" -c user.email=t@t -c user.name=t commit -q -m "later main edit"
  git -C "$tmp" push -q origin HEAD:main
  git -C "$tmp" push -q origin --delete fm/task-x1
  rm -rf "$tmp"
  git -C "$case_dir/project" fetch -q --prune origin
}

test_train_replayed_branch_deleted_allows() {
  local case_dir rc
  case_dir=$(make_case train-replayed)
  write_meta "$case_dir" no-mistakes ship
  wt_commit_file "$case_dir" feature.txt hello "add feature"
  wt_commit_file "$case_dir" second.txt two "add second"
  train_land_branch_and_delete "$case_dir"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "train-replayed: teardown should succeed when every commit was replayed onto main"$'\n'"$(cat "$case_dir/stderr")"
  ! grep -q REFUSED "$case_dir/stderr" || fail "train-replayed: teardown printed a REFUSED line"
  pass "branch whose commits a merge train replayed onto main, then deleted, is torn down"
}

test_train_replayed_plus_extra_local_commit_refuses() {
  local case_dir rc local_head
  case_dir=$(make_case train-replayed-extra)
  write_meta "$case_dir" no-mistakes ship
  wt_commit_file "$case_dir" feature.txt hello "add feature"
  train_land_branch_and_delete "$case_dir"
  wt_commit_file "$case_dir" extra.txt extra "unlanded follow-up"
  local_head=$(git -C "$case_dir/wt" rev-parse HEAD)

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "train-replayed-extra: teardown should refuse an extra local commit not on main"
  grep -q REFUSED "$case_dir/stderr" || fail "train-replayed-extra: no REFUSED line in stderr"
  assert_refusal_retained_task_state "$case_dir" train-replayed-extra "$local_head"
  pass "replayed branch plus one unlanded local commit still refuses"
}

test_train_same_file_different_patch_refuses() {
  local case_dir rc local_head tmp
  case_dir=$(make_case train-same-file-diverged)
  write_meta "$case_dir" no-mistakes ship
  wt_commit_file "$case_dir" feature.txt local-version "add feature"
  local_head=$(git -C "$case_dir/wt" rev-parse HEAD)
  # Main carries a commit touching the same file with the same message but a
  # different patch, then a later conflicting edit; the branch is deleted.
  git -C "$case_dir/wt" push -q origin fm/task-x1
  tmp="$case_dir/_diverge"
  git clone -q "$case_dir/origin.git" "$tmp"
  printf '%s\n' main-version > "$tmp/feature.txt"
  git -C "$tmp" add -- feature.txt
  git -C "$tmp" -c user.email=t@t -c user.name=t commit -q -m "add feature"
  git -C "$tmp" push -q origin HEAD:main
  git -C "$tmp" push -q origin --delete fm/task-x1
  rm -rf "$tmp"
  git -C "$case_dir/project" fetch -q --prune origin

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "train-same-file-diverged: teardown should refuse a different patch to the same file"
  grep -q REFUSED "$case_dir/stderr" || fail "train-same-file-diverged: no REFUSED line in stderr"
  assert_refusal_retained_task_state "$case_dir" train-same-file-diverged "$local_head"
  pass "local commit touching the same file as a main commit with a different patch refuses"
}

test_train_replayed_with_claude_scratch_allows() {
  local case_dir rc
  case_dir=$(make_case train-replayed-claude-scratch)
  write_meta "$case_dir" no-mistakes ship
  wt_commit_file "$case_dir" feature.txt hello "add feature"
  train_land_branch_and_delete "$case_dir"
  mkdir -p "$case_dir/wt/.claude"
  printf '%s\n' '{}' > "$case_dir/wt/.claude/settings.local.json"
  [ -n "$(git -C "$case_dir/wt" status --porcelain -- .claude)" ] \
    || fail "train-replayed-claude-scratch: .claude/ scratch should be visible to git status"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "train-replayed-claude-scratch: teardown should succeed with only .claude/ scratch untracked"$'\n'"$(cat "$case_dir/stderr")"
  ! grep -q REFUSED "$case_dir/stderr" || fail "train-replayed-claude-scratch: teardown printed a REFUSED line"
  pass "replayed branch with untracked .claude/ scratch is torn down"
}

test_train_replayed_dirty_worktree_refuses() {
  local case_dir rc local_head
  case_dir=$(make_case train-replayed-dirty)
  write_meta "$case_dir" no-mistakes ship
  wt_commit_file "$case_dir" feature.txt hello "add feature"
  train_land_branch_and_delete "$case_dir"
  local_head=$(git -C "$case_dir/wt" rev-parse HEAD)
  printf '%s\n' uncommitted > "$case_dir/wt/feature.txt"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "train-replayed-dirty: teardown should refuse a dirty worktree"
  grep -q REFUSED "$case_dir/stderr" || fail "train-replayed-dirty: no REFUSED line in stderr"
  assert_refusal_retained_task_state "$case_dir" train-replayed-dirty "$local_head"
  pass "dirty worktree refuses even when every commit was replayed onto main"
}

test_squash_merged_branch_deleted_allows() {
  local case_dir rc pr_head
  case_dir=$(make_case squash-merged)
  write_meta "$case_dir" no-mistakes ship
  # Real branch content that is NOT pushed and NOT on origin/main: a squash merge
  # rewrote it into a different commit on main and auto-deleted the head branch, so
  # HEAD is unreachable from every remote-tracking branch. The matching merged PR is
  # the only signal that the work landed.
  wt_commit_file "$case_dir" feature.txt hello "add feature"
  append_pr_meta_for_current_head "$case_dir"
  pr_head=$(git -C "$case_dir/wt" rev-parse HEAD)
  add_gh_pr_merged_for_head "$case_dir" "$pr_head"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "squash-merged: teardown should succeed when the PR is merged"
  ! grep -q REFUSED "$case_dir/stderr" || fail "squash-merged: teardown printed a REFUSED line"
  pass "squash-merged + deleted-branch worktree (PR merged) is torn down (the fix)"
}

test_squash_merged_pr_allows_when_head_ancestor_of_pr_head() {
  local case_dir rc local_head pr_head
  case_dir=$(make_case squash-ancestor)
  write_meta "$case_dir" no-mistakes ship
  wt_commit_file "$case_dir" feature.txt hello "add feature"
  append_pr_meta_url "$case_dir"
  local_head=$(git -C "$case_dir/wt" rev-parse HEAD)
  pr_head=$(commit_tree_from_wt_head "$case_dir" "$local_head" "no-mistakes follow-up")
  add_gh_pr_merged_for_head "$case_dir" "$pr_head"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "squash-ancestor: teardown should succeed when local HEAD is in the merged PR head"
  ! grep -q REFUSED "$case_dir/stderr" || fail "squash-ancestor: teardown printed a REFUSED line"
  pass "squash-merged PR accepts a local HEAD that is an ancestor of the final PR head"
}

test_no_pr_recorded_discovers_merged_pr_by_branch_allows() {
  local case_dir rc local_head pr_head
  case_dir=$(make_case no-pr-branch-discovery)
  write_meta "$case_dir" no-mistakes ship
  # Reproduces the real false-refusal report exactly, with NO pr=/pr_head=
  # recorded in meta at all (fm-pr-check.sh was never run, e.g. a yolo merge on
  # a repo with no PR CI so the "checks green" trigger that fires it never
  # happened): a branch with a commit, a no-mistakes auto-fix commit pushed on
  # top that never made it back into the local worktree, a squash merge onto
  # main under a brand-new SHA, and the head branch deleted (simulated here by
  # never pushing fm/task-x1 at all, so no refs/remotes/origin/fm/task-x1
  # exists to make HEAD "reachable").
  wt_commit_file "$case_dir" feature.txt hello "add feature"
  local_head=$(git -C "$case_dir/wt" rev-parse HEAD)
  pr_head=$(commit_tree_from_wt_head "$case_dir" "$local_head" "no-mistakes auto-fix")
  land_on_origin_main "$case_dir" feature.txt hello
  add_gh_pr_merged_for_head "$case_dir" "$pr_head"
  seed_backlog_in_flight "$case_dir"
  # No append_pr_meta_* call: state/task-x1.meta has no pr= or pr_head= line.

  ! grep -qE '^(pr|pr_head)=' "$case_dir/state/task-x1.meta" \
    || fail "no-pr-branch-discovery: test setup bug, meta unexpectedly has a pr= line"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "no-pr-branch-discovery: teardown should succeed by discovering the merged PR from the branch name"
  ! grep -q REFUSED "$case_dir/stderr" || fail "no-pr-branch-discovery: teardown printed a REFUSED line"
  assert_grep 'https://github.com/example/repo/pull/7' "$case_dir/data/backlog.md" \
    "no-pr-branch-discovery: resolved PR URL was not recorded on completion"
  pass "teardown discovers a merged PR by branch name and tears down when no pr= was ever recorded"
}

test_squash_merged_pr_allows_replayed_unpushed_patch() {
  local case_dir rc parent_head pr_head
  case_dir=$(make_case squash-replayed-patch)
  write_meta "$case_dir" no-mistakes ship
  wt_commit_file "$case_dir" local-parent.txt parent "local parent"
  parent_head=$(git -C "$case_dir/wt" rev-parse HEAD)
  git -C "$case_dir/wt" push -q origin "$parent_head:refs/heads/fm/task-x1"
  git -C "$case_dir/project" fetch -q origin fm/task-x1
  wt_commit_file "$case_dir" feature.txt hello "add feature"
  append_pr_meta_url "$case_dir"
  pr_head=$(land_equivalent_patch_on_origin_branch "$case_dir" pr-head feature.txt hello "add feature")
  add_gh_pr_merged_for_head "$case_dir" "$pr_head"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "squash-replayed-patch: teardown should succeed when unpushed local patch is in the merged PR head"
  ! grep -q REFUSED "$case_dir/stderr" || fail "squash-replayed-patch: teardown printed a REFUSED line"
  pass "squash-merged PR accepts replayed unpushed local patches contained in the PR head"
}

test_merged_pr_with_later_local_commit_refuses() {
  local case_dir rc pr_head
  case_dir=$(make_case stale-pr-head)
  write_meta "$case_dir" no-mistakes ship
  wt_commit_file "$case_dir" feature.txt hello "add feature"
  append_pr_meta_for_current_head "$case_dir"
  pr_head=$(git -C "$case_dir/wt" rev-parse HEAD)
  wt_commit_file "$case_dir" later.txt local-only "local follow-up"
  add_gh_pr_merged_for_head "$case_dir" "$pr_head"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "stale-pr-head: teardown should refuse when HEAD moved after PR recording"
  grep -q REFUSED "$case_dir/stderr" || fail "stale-pr-head: no REFUSED line in stderr"
  pass "merged PR does not allow teardown after a later local commit"
}

test_squash_merged_rebased_branch_allows() {
  local case_dir rc pr_head
  case_dir=$(make_case squash-rebased)
  write_meta "$case_dir" no-mistakes ship
  pr_head=$(setup_squash_rebased_history "$case_dir" rebased)
  printf '%s\n' \
    'pr=https://github.com/example/repo/pull/7' \
    "pr_head=$pr_head" >> "$case_dir/state/task-x1.meta"
  add_gh_pr_merged_for_head "$case_dir" "$pr_head"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "squash-rebased: teardown should succeed when the worktree followed the pipeline rebase"$'\n'"$(cat "$case_dir/stderr")"
  ! grep -q REFUSED "$case_dir/stderr" || fail "squash-rebased: teardown printed a REFUSED line"
  pass "squash-merged task whose local branch followed the pipeline rebase is torn down"
}

# Override tea to answer one login for git.example.org and a pull request
# read through "tea api" with the supplied merged flag and head.
add_tea_pull_for_head() {
  local case_dir=$1 merged=$2 head=$3
  cat > "$case_dir/fakebin/tea" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$case_dir/tea.log"
if [ "\${1:-} \${2:-}" = "login list" ]; then
  printf '[\n  {\n    "name": "fj",\n    "url": "https://git.example.org"\n  }\n]\n'
  exit 0
fi
[ "\${1:-}" = api ] || exit 1
printf '{"state":"closed","merged":%s,"head":{"sha":"%s"}}\n' '$merged' '$head'
SH
  chmod +x "$case_dir/fakebin/tea"
}

# A Forgejo task whose default branch moved on after the squash merge, editing
# the same lines, leaves the content check inconclusive, so only the forge's
# merged record can prove the work landed. With the record merged teardown
# proceeds; with it unmerged the same history refuses.
test_squash_merged_forgejo_pr_allows_when_main_moved_on() {
  local case_dir rc pr_head tmp merged expected
  for merged in true false; do
    case_dir=$(make_case "forgejo-merged-$merged")
    write_meta "$case_dir" no-mistakes ship
    pr_head=$(setup_squash_rebased_history "$case_dir" rebased)
    tmp="$case_dir/_main_later"
    git clone -q "$case_dir/origin.git" "$tmp"
    printf '%s\n' base main-edit feature-edit-reworded > "$tmp/shared.txt"
    git -C "$tmp" add -- shared.txt
    git -C "$tmp" -c user.email=t@t -c user.name=t commit -q -m "main rewords shared"
    git -C "$tmp" push -q origin main
    rm -rf "$tmp"
    printf '%s\n' \
      'pr=https://git.example.org/team/repo/pulls/7' \
      "pr_head=$pr_head" >> "$case_dir/state/task-x1.meta"
    add_gh_axi_error "$case_dir"
    add_tea_pull_for_head "$case_dir" "$merged" "$pr_head"

    set +e
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
    rc=$?
    set -e

    expected=1
    [ "$merged" = false ] || expected=0
    expect_code "$expected" "$rc" "forgejo-merged-$merged: teardown exit"$'\n'"$(cat "$case_dir/stderr")"
    grep -qF -- 'api --login fj --repo team/repo /repos/{owner}/{repo}/pulls/7' "$case_dir/tea.log" \
      || fail "forgejo-merged-$merged: teardown did not read the Forgejo pull request through tea"
  done
  pass "teardown proves a Forgejo task landed from the merged pull request when the content check is inconclusive"
}

test_squash_merged_same_file_different_content_refuses() {
  local case_dir rc pr_head local_head
  case_dir=$(make_case squash-same-path-diverged)
  write_meta "$case_dir" no-mistakes ship
  # The pipeline rebase produced a different blob for shared.txt than the stale
  # local still holds, then squash-merged. Same path is not proof the local
  # content landed.
  pr_head=$(setup_squash_rebased_history "$case_dir" stale)
  local_head=$(git -C "$case_dir/wt" rev-parse HEAD)
  printf '%s\n' \
    'pr=https://github.com/example/repo/pull/7' \
    "pr_head=$pr_head" >> "$case_dir/state/task-x1.meta"
  add_gh_pr_merged_for_head "$case_dir" "$pr_head"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "squash-same-path-diverged: teardown should refuse when the same file has different content"$'\n'"$(cat "$case_dir/stderr")"
  grep -q REFUSED "$case_dir/stderr" || fail "squash-same-path-diverged: no REFUSED line in stderr"
  assert_refusal_retained_task_state "$case_dir" squash-same-path-diverged "$local_head"
  pass "squash-merged same-path different content still refuses"
}

# The local branch followed the pipeline rebase, so without later.txt this is the
# q2 ALLOW case exactly. The one unlanded follow-up commit is the sole difference
# and must be the sole reason teardown refuses.
test_squash_merged_rebased_local_with_unlanded_commit_refuses() {
  local case_dir rc pr_head local_head
  case_dir=$(make_case squash-rebased-unlanded)
  write_meta "$case_dir" no-mistakes ship
  pr_head=$(setup_squash_rebased_history "$case_dir" rebased-plus-unlanded)
  local_head=$(git -C "$case_dir/wt" rev-parse HEAD)
  printf '%s\n' \
    'pr=https://github.com/example/repo/pull/7' \
    "pr_head=$pr_head" >> "$case_dir/state/task-x1.meta"
  add_gh_pr_merged_for_head "$case_dir" "$pr_head"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "squash-rebased-unlanded: teardown should refuse extra local commits that never landed"$'\n'"$(cat "$case_dir/stderr")"
  grep -q REFUSED "$case_dir/stderr" || fail "squash-rebased-unlanded: no REFUSED line in stderr"
  assert_refusal_retained_task_state "$case_dir" squash-rebased-unlanded "$local_head"
  pass "squash-merged rebased local still refuses a genuinely unlanded follow-up commit"
}

test_squash_merged_stale_local_refuses_when_forge_unreachable() {
  local case_dir rc pr_head local_head
  case_dir=$(make_case squash-stale-offline)
  write_meta "$case_dir" no-mistakes ship
  pr_head=$(setup_squash_rebased_history "$case_dir" stale)
  local_head=$(git -C "$case_dir/wt" rev-parse HEAD)
  printf '%s\n' \
    'pr=https://github.com/example/repo/pull/7' \
    "pr_head=$pr_head" >> "$case_dir/state/task-x1.meta"
  add_gh_axi_error "$case_dir"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "squash-stale-offline: teardown should refuse when the forge is down and trees conflict"$'\n'"$(cat "$case_dir/stderr")"
  grep -q REFUSED "$case_dir/stderr" || fail "squash-stale-offline: no REFUSED line in stderr"
  assert_refusal_retained_task_state "$case_dir" squash-stale-offline "$local_head"
  pass "squash-merged stale local still refuses when the forge is unreachable"
}

test_pr_check_does_not_refresh_stale_pr_head() {
  local case_dir rc pr_head new_head count
  case_dir=$(make_case pr-check-stale)
  write_meta "$case_dir" no-mistakes ship
  wt_commit_file "$case_dir" feature.txt hello "add feature"
  pr_head=$(git -C "$case_dir/wt" rev-parse HEAD)
  add_gh_pr_merged_for_head "$case_dir" "$pr_head"

  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  PATH="$case_dir/fakebin:$PATH" \
    "$PR_CHECK" task-x1 https://github.com/example/repo/pull/7 >/dev/null

  wt_commit_file "$case_dir" later.txt local-only "local follow-up"
  new_head=$(git -C "$case_dir/wt" rev-parse HEAD)

  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  PATH="$case_dir/fakebin:$PATH" \
    "$PR_CHECK" task-x1 https://github.com/example/repo/pull/7 >/dev/null

  count=$(grep -c '^pr_head=' "$case_dir/state/task-x1.meta" || true)
  expect_code 1 "$count" "pr-check-stale: stale rerun should not append a second pr_head"
  ! grep -qxF "pr_head=$new_head" "$case_dir/state/task-x1.meta" \
    || fail "pr-check-stale: stale rerun recorded the later local HEAD"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "pr-check-stale: teardown should refuse after a later local commit"
  grep -q REFUSED "$case_dir/stderr" || fail "pr-check-stale: no REFUSED line in stderr"
  pass "fm-pr-check does not refresh PR head after HEAD moves"
}

test_pr_check_records_remote_head_when_local_lags() {
  local case_dir local_head pr_head
  case_dir=$(make_case pr-check-local-lags)
  write_meta "$case_dir" no-mistakes ship
  wt_commit_file "$case_dir" feature.txt hello "add feature"
  local_head=$(git -C "$case_dir/wt" rev-parse HEAD)
  pr_head=$(commit_tree_from_wt_head "$case_dir" "$local_head" "no-mistakes follow-up")
  add_gh_pr_merged_for_head "$case_dir" "$pr_head"

  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  PATH="$case_dir/fakebin:$PATH" \
    "$PR_CHECK" task-x1 https://github.com/example/repo/pull/7 >/dev/null

  grep -qxF "pr_head=$pr_head" "$case_dir/state/task-x1.meta" \
    || fail "pr-check-local-lags: did not record GitHub PR head"
  ! grep -qxF "pr_head=$local_head" "$case_dir/state/task-x1.meta" \
    || fail "pr-check-local-lags: recorded local HEAD instead of remote PR head"
  pass "fm-pr-check records the remote PR head when the local worktree lags"
}

test_content_in_default_fallback_allows() {
  local case_dir rc
  case_dir=$(make_case content-landed)
  write_meta "$case_dir" no-mistakes ship
  # No pr= recorded and the default gh-axi mock reports no PR, so the merged-PR path
  # cannot fire and the content check must carry it. The branch adds feature.txt, and
  # the same net change has independently landed on origin/main via a squash commit.
  wt_commit_file "$case_dir" feature.txt hello "add feature"
  land_on_origin_main "$case_dir" feature.txt hello
  cat > "$case_dir/fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" > "${FM_TEST_TREEHOUSE_LOG:?}"
exit 0
SH
  chmod +x "$case_dir/fakebin/treehouse"

  set +e
  FM_TEST_TREEHOUSE_LOG="$case_dir/treehouse.log" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "content-landed: teardown should succeed when content is already in the default branch"
  ! grep -q REFUSED "$case_dir/stderr" || fail "content-landed: teardown printed a REFUSED line"
  assert_present "$case_dir/treehouse.log" \
    "content-landed: teardown never reached destructive worktree cleanup"
  assert_absent "$case_dir/state/task-x1.meta" \
    "content-landed: teardown left task metadata after destructive cleanup"
  pass "worktree whose content already landed in the default branch is torn down (content fallback)"
}

# A task recording base_branch= landed when its content reached that branch, not
# the default branch: a squash merge into the base branch is the landing.
test_content_fallback_uses_recorded_base_branch() {
  local case_dir rc landed tmp
  for landed in base default; do
    case_dir=$(make_case "content-base-$landed")
    write_meta "$case_dir" direct-PR ship
    printf 'base_branch=feature/hub\n' >> "$case_dir/state/task-x1.meta"
    tmp="$case_dir/_hub"
    git clone -q "$case_dir/origin.git" "$tmp"
    git -C "$tmp" push -q origin HEAD:refs/heads/feature/hub
    rm -rf "$tmp"
    wt_commit_file "$case_dir" feature.txt hello "add feature"
    if [ "$landed" = base ]; then
      tmp="$case_dir/_land"
      git clone -q "$case_dir/origin.git" "$tmp"
      git -C "$tmp" checkout -q feature/hub
      printf 'hello\n' > "$tmp/feature.txt"
      git -C "$tmp" add feature.txt
      git -C "$tmp" -c user.email=t@t -c user.name=t commit -q -m "squash feature.txt"
      git -C "$tmp" push -q origin HEAD:feature/hub
      rm -rf "$tmp"
    else
      land_on_origin_main "$case_dir" feature.txt hello
    fi
    cat > "$case_dir/fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
exit 0
SH
    chmod +x "$case_dir/fakebin/treehouse"

    set +e
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
    rc=$?
    set -e
    if [ "$landed" = base ]; then
      expect_code 0 "$rc" "content-base: content squashed into the recorded base branch should count as landed"
      assert_absent "$case_dir/state/task-x1.meta" "content-base: teardown kept the record of landed work"
    else
      [ "$rc" -ne 0 ] || fail "content-base: content only on the default branch passed for a task based on feature/hub"
      assert_present "$case_dir/state/task-x1.meta" "content-base: a refused teardown removed the task record"
    fi
  done
  pass "the content-landed fallback checks a task's recorded base branch, not the default branch"
}

test_content_fallback_refreshes_stale_origin_ref() {
  local case_dir rc
  case_dir=$(make_case content-stale-ref)
  write_meta "$case_dir" no-mistakes ship
  wt_commit_file "$case_dir" feature.txt hello "add feature"
  git -C "$case_dir/project" config --unset-all remote.origin.fetch
  git -C "$case_dir/project" config --add remote.origin.fetch '+refs/heads/not-main:refs/remotes/origin/not-main'
  land_on_origin_main "$case_dir" feature.txt hello

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "content-stale-ref: teardown should use the freshly fetched default branch"
  ! grep -q REFUSED "$case_dir/stderr" || fail "content-stale-ref: teardown printed a REFUSED line"
  pass "content fallback refreshes origin default before comparing trees"
}

test_dirty_worktree_refuses() {
  local case_dir rc pr_head
  case_dir=$(make_case dirty-wt)
  write_meta "$case_dir" no-mistakes ship
  printf '%s\n' 'pr=https://github.com/example/repo/pull/7' >> "$case_dir/state/task-x1.meta"
  # The committed work has fully landed (merged PR + content in default), but an
  # uncommitted edit remains. Dirtiness must refuse regardless: the reset would
  # discard those changes.
  wt_commit_file "$case_dir" feature.txt hello "add feature"
  land_on_origin_main "$case_dir" feature.txt hello
  pr_head=$(git -C "$case_dir/wt" rev-parse HEAD)
  add_gh_pr_merged_for_head "$case_dir" "$pr_head"
  printf '%s\n' "uncommitted edit" > "$case_dir/wt/feature.txt"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "dirty-wt: teardown should refuse a dirty worktree even when the committed work has landed"
  grep -q REFUSED "$case_dir/stderr" || fail "dirty-wt: no REFUSED line in stderr"
  grep -q "uncommitted changes" "$case_dir/stderr" || fail "dirty-wt: refusal did not cite uncommitted changes"
  pass "dirty worktree is refused even when its committed work has landed (dirty always wins)"
}

assert_dirty_diagnostic() {
  local kind=$1 mode=$2 case_dir rc before n
  case_dir=$(make_case "dirty-$kind-$mode")
  write_meta "$case_dir" "$mode" ship
  wt_commit_file "$case_dir" feature.txt hello
  # Exercise both dirty refusal sites: remote-reachable work and local-only
  # work merged into local main but absent from every remote.
  if [ "$mode" = local-only ]; then
    git -C "$case_dir/project" merge -q --ff-only fm/task-x1
  else
    git -C "$case_dir/wt" push -q origin fm/task-x1
  fi
  if [ "$kind" != untracked ]; then
    printf '%s\n' 'uncommitted edit' > "$case_dir/wt/feature.txt"
    # Cover index edits as well as unstaged edits.
    [ "$mode" != local-only ] || git -C "$case_dir/wt" add feature.txt
  fi
  if [ "$kind" != tracked ]; then
    mkdir "$case_dir/wt/00 proof scratch"
    printf '%s\n' 'manual server log' > "$case_dir/wt/00 proof scratch/server.log"
    for n in 01 02 03 04 05 06 07 08 09 10 11; do
      touch "$case_dir/wt/$n-scratch.txt"
    done
    # Preserve the existing exemptions without counting them as leftovers.
    mkdir "$case_dir/wt/.claude"
    touch "$case_dir/wt/.claude/settings.local.json" "$case_dir/wt/.fm-grok-turnend"
  fi
  before=$(git -C "$case_dir/wt" status --porcelain)
  rc=0
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 1 "$rc" "$kind/$mode: dirty teardown must still refuse"
  grep -q REFUSED "$case_dir/stderr" || fail "$kind/$mode: no refusal"
  if [ "$kind" = untracked ]; then
    grep -Fq 'uncommitted changes present (untracked-only leftovers)' "$case_dir/stderr" \
      || fail "$kind/$mode: missing untracked-only classification"
    ! grep -q 'includes tracked edits' "$case_dir/stderr" || fail "$kind/$mode: misclassified as tracked"
  else
    grep -Fq 'uncommitted changes present (includes tracked edits)' "$case_dir/stderr" \
      || fail "$kind/$mode: missing tracked-edit classification"
    ! grep -q 'untracked-only' "$case_dir/stderr" || fail "$kind/$mode: misclassified as untracked-only"
  fi
  if [ "$kind" != tracked ]; then
    grep -Fq '00 proof scratch/' "$case_dir/stderr" || fail "$kind/$mode: scratch folder not named"
    grep -Fxq '  09-scratch.txt' "$case_dir/stderr" || fail "$kind/$mode: tenth path missing"
    ! grep -q '10-scratch.txt\|11-scratch.txt\|\.claude/\|\.fm-grok-turnend' "$case_dir/stderr" \
      || fail "$kind/$mode: path list exceeded its bound or included exempt files"
    grep -Fq 'additional untracked paths omitted' "$case_dir/stderr" || fail "$kind/$mode: no truncation notice"
  else
    ! grep -q 'untracked paths' "$case_dir/stderr" || fail "$kind/$mode: invented untracked paths"
  fi
  [ -f "$case_dir/state/task-x1.meta" ] || fail "$kind/$mode: task metadata removed"
  [ "$before" = "$(git -C "$case_dir/wt" status --porcelain)" ] || fail "$kind/$mode: worktree changed"
  pass "$kind/$mode: dirty refusal classifies leftovers and preserves work"
}

test_untracked_only_refusal_diagnostic() {
  assert_dirty_diagnostic untracked no-mistakes
  assert_dirty_diagnostic untracked local-only
}

test_tracked_edit_refusal_diagnostic() {
  assert_dirty_diagnostic tracked no-mistakes
  assert_dirty_diagnostic tracked local-only
}

test_mixed_refusal_diagnostic() {
  assert_dirty_diagnostic mixed no-mistakes
  assert_dirty_diagnostic mixed local-only
}

# Treehouse's return runs `git clean -fd` (one -f). A nested repository stays.
add_treehouse_clean_fd() {
  local case_dir=$1
  cat > "$case_dir/fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = return ]; then
  shift
  wt=
  for a in "$@"; do
    case "$a" in
      --force) ;;
      *) wt=$a ;;
    esac
  done
  if [ -n "$wt" ]; then
    git -C "$wt" clean -fdq || true
  fi
fi
exit 0
SH
  chmod +x "$case_dir/fakebin/treehouse"
}

# Return succeeds, then plants a nested repository the pre-return scrub cannot
# have removed. The post-return check must name that residue.
add_treehouse_that_leaves_residue() {
  local case_dir=$1
  cat > "$case_dir/fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = return ]; then
  shift
  wt=
  for a in "$@"; do
    case "$a" in
      --force) ;;
      *) wt=$a ;;
    esac
  done
  if [ -n "$wt" ]; then
    git -C "$wt" clean -fdq || true
    git init -q "$wt/left-behind-clone"
    git -C "$wt/left-behind-clone" commit -q --allow-empty -m residue
  fi
fi
exit 0
SH
  chmod +x "$case_dir/fakebin/treehouse"
}

prepare_scout_teardown() {
  local case_dir=$1
  mkdir -p "$case_dir/data/task-x1"
  printf '%s\n' 'Scout report.' > "$case_dir/data/task-x1/report.md"
  printf '%s\n' 'decisions_reviewed=1' >> "$case_dir/state/task-x1.meta"
}

# Clone a nested repository into the copy and add one plain scratch file.
seed_nested_clone_and_scratch() {
  local case_dir=$1 wt=$2
  git init -q "$case_dir/nested-src"
  printf 'payload\n' > "$case_dir/nested-src/payload.txt"
  git -C "$case_dir/nested-src" add payload.txt
  git -C "$case_dir/nested-src" -c user.email=t@t -c user.name=t commit -q -m payload
  git clone -q "$case_dir/nested-src" "$wt/scratch-clone"
  printf 'scratch\n' > "$wt/scratch.txt"
}

# Move the case worktree to pool/<slot>/repo so teardown sees a Treehouse slot.
move_case_to_pool_slot() {
  local case_dir=$1 slot=$2 dest
  dest="$case_dir/pool/$slot/repo"
  mkdir -p "$case_dir/pool/$slot"
  git -C "$case_dir/project" worktree move "$case_dir/wt" "$dest"
  printf '{"worktrees":[{"name":"%s","path":"%s"}]}\n' "$slot" "$dest" \
    > "$case_dir/pool/treehouse-state.json"
  printf '%s\n' "$dest"
}

test_scout_archived_decision_requires_recorded_answer() {
  local case_dir rc before
  case_dir=$(make_case scout-archived-decision)
  write_meta "$case_dir" no-mistakes scout
  prepare_scout_teardown "$case_dir"
  seed_backlog_in_flight "$case_dir" scout
  printf 'decision_keys=scratch-call\n' >> "$case_dir/state/task-x1.meta"
  cat > "$case_dir/data/done-archive.md" <<'EOF'
## Archived 2026-10-13
- [x] scratch-call - Decide scratch cleanup (kind: captain) (done 2026-10-05)
  No recorded answer.
EOF
  before=$(cksum "$case_dir/data/done-archive.md")
  rc=0
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 1 "$rc" 'archived decision without an answer must refuse'
  assert_present "$case_dir/state/task-x1.meta" 'refusal removed scout metadata'
  [ "$before" = "$(cksum "$case_dir/data/done-archive.md")" ] \
    || fail 'refusal mutated archived decision'
  cat > "$case_dir/data/done-archive.md" <<'EOF'
## Archived 2026-10-13
- [x] scratch-call - Decide scratch cleanup (kind: captain) (done 2026-10-05)
  Resolution recorded by fm-captain-hold.
  Decision digest: 22364d0a8d619c9e28cb5f2d82753a0e1e8187f8aa07a6382b53e37283842e0c
  Resolution mode: released

  Captain decision:
  Delete only the approved scratch.

  Captain hold origin: task-x1
EOF
  rc=0
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 0 "$rc" "archived answered decision should allow cleanup: $(cat "$case_dir/stderr")"
  assert_absent "$case_dir/state/task-x1.meta" 'answered archive did not permit cleanup'
  assert_grep 'Delete only the approved scratch' "$case_dir/data/done-archive.md" \
    'cleanup lost the archived answer'
  pass 'scout cleanup requires recorded resolution even when its decision is archived'
}

test_scout_nested_clone_returns_with_no_untracked_entries() {
  local case_dir wt rc
  case_dir=$(make_case scout-nested-clean)
  wt="$case_dir/wt"
  write_meta "$case_dir" no-mistakes scout
  prepare_scout_teardown "$case_dir"
  seed_nested_clone_and_scratch "$case_dir" "$wt"
  add_treehouse_clean_fd "$case_dir"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "scout-nested-clean: teardown should return the scratch copy"
  [ -z "$(git -C "$wt" status --porcelain --untracked-files=all)" ] \
    || fail "scout-nested-clean: untracked entries remain: $(git -C "$wt" status --porcelain --untracked-files=all)"
  assert_absent "$wt/scratch-clone" "scout-nested-clean: nested clone survived return"
  assert_absent "$wt/scratch.txt" "scout-nested-clean: scratch file survived return"
  pass "scout copy with a nested clone and a scratch file returns with no untracked entries"
}

test_ship_nested_clone_is_refused_and_bytes_stay() {
  local case_dir wt rc head before after
  case_dir=$(make_case ship-nested-refuse)
  wt="$case_dir/wt"
  write_meta "$case_dir" no-mistakes ship
  seed_nested_clone_and_scratch "$case_dir" "$wt"
  before=$(cksum "$wt/scratch-clone/payload.txt")
  head=$(git -C "$wt" rev-parse HEAD)
  : > "$case_dir/treehouse.log"
  cat > "$case_dir/fakebin/treehouse" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$case_dir/treehouse.log"
exit 0
EOF
  chmod +x "$case_dir/fakebin/treehouse"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "ship-nested-refuse: teardown should refuse a nested clone"
  assert_grep "REFUSED" "$case_dir/stderr" "ship-nested-refuse: no REFUSED line"
  assert_grep "uncommitted changes" "$case_dir/stderr" \
    "ship-nested-refuse: refusal did not cite uncommitted changes"
  after=$(cksum "$wt/scratch-clone/payload.txt")
  [ "$before" = "$after" ] || fail "ship-nested-refuse: nested clone bytes changed"
  assert_present "$wt/scratch-clone/.git" "ship-nested-refuse: nested repository was removed"
  assert_present "$wt/scratch.txt" "ship-nested-refuse: scratch file was removed"
  [ ! -s "$case_dir/treehouse.log" ] \
    || fail "ship-nested-refuse: refusal returned the copy: $(cat "$case_dir/treehouse.log")"
  assert_refusal_retained_task_state "$case_dir" "ship-nested-refuse" "$head"
  pass "ship copy with a nested clone is refused and its bytes stay"
}

test_dirty_return_warns_which_slot_was_lost() {
  local case_dir wt rc
  case_dir=$(make_case dirty-return)
  wt=$(move_case_to_pool_slot "$case_dir" 9)
  write_meta "$case_dir" no-mistakes scout "$wt"
  prepare_scout_teardown "$case_dir"
  add_treehouse_that_leaves_residue "$case_dir"

  set +e
  FM_HOME="$case_dir" run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 4 "$rc" "dirty-return: a lost slot should exit 4 after cleanup"
  assert_grep "pool slot 9" "$case_dir/stderr" "dirty-return: warning did not name the slot"
  assert_grep "left-behind-clone" "$case_dir/stderr" "dirty-return: warning did not name the remaining path"
  assert_grep "lost this slot" "$case_dir/stderr" "dirty-return: warning did not say the pool lost the slot"
  assert_no_grep "teardown task-x1 complete" "$case_dir/stdout" \
    "dirty-return: stdout still reported a clean return"
  assert_grep "Backlog: task-x1" "$case_dir/stdout" \
    "dirty-return: the finished teardown skipped its backlog reminder"
  assert_absent "$case_dir/state/task-x1.meta" "dirty-return: task record was not removed"
  pass "a return that leaves residue names the lost slot and the remaining paths"
}

test_dirty_return_warns_even_when_a_later_step_refuses() {
  local case_dir wt rc
  case_dir=$(make_case dirty-return-later-refusal)
  wt=$(move_case_to_pool_slot "$case_dir" 8)
  write_meta "$case_dir" no-mistakes scout "$wt"
  prepare_scout_teardown "$case_dir"
  add_treehouse_that_leaves_residue "$case_dir"
  cat > "$case_dir/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  kill-window) exit 1 ;;
  list-windows) printf '%s\n' fm-task-x1 ;;
esac
exit 0
SH
  chmod +x "$case_dir/fakebin/tmux"

  set +e
  FM_HOME="$case_dir" run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "dirty-return-later-refusal: the endpoint refusal should fail teardown"
  assert_grep "could not be closed" "$case_dir/stderr" \
    "dirty-return-later-refusal: fixture did not reach the endpoint close refusal"
  assert_grep "pool slot 8" "$case_dir/stderr" \
    "dirty-return-later-refusal: a later refusal dropped the lost-slot warning"
  assert_grep "left-behind-clone" "$case_dir/stderr" \
    "dirty-return-later-refusal: a later refusal dropped the remaining paths"
  pass "a dirty return is reported even when a later teardown step refuses"
}

test_forced_secondmate_child_scout_nested_clone_returns_clean() {
  local case_dir home child_wt rc
  case_dir=$(make_case secondmate-child-nested-clean)
  write_meta "$case_dir" local-only secondmate
  home="$case_dir/secondmate-home"
  mkdir -p "$home/state" "$home/data" "$home/config" "$home/projects"
  printf '%s\n' task-x1 > "$home/.fm-secondmate-home"
  printf '%s\n' "home=$home" >> "$case_dir/state/task-x1.meta"
  child_wt="$case_dir/child-scout-wt"
  git -C "$case_dir/project" worktree add -q -b fm/child-scout "$child_wt" main
  fm_write_meta "$home/state/child-scout.meta" \
    "window=firstmate:fm-child-scout" \
    "endpoint_task_id=child-scout" \
    "worktree=$child_wt" \
    "project=$case_dir/project" \
    "kind=scout" \
    "mode=local-only"
  seed_nested_clone_and_scratch "$case_dir" "$child_wt"
  add_treehouse_clean_fd "$case_dir"

  rc=0
  run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 0 "$rc" "secondmate-child-nested-clean: forced secondmate teardown should succeed"
  [ -z "$(git -C "$child_wt" status --porcelain --untracked-files=all)" ] \
    || fail "secondmate-child-nested-clean: untracked entries remain: $(git -C "$child_wt" status --porcelain --untracked-files=all)"
  assert_absent "$child_wt/scratch-clone" "secondmate-child-nested-clean: nested clone survived return"
  assert_absent "$child_wt/scratch.txt" "secondmate-child-nested-clean: scratch file survived return"
  assert_no_grep "lost this slot" "$case_dir/stderr" \
    "secondmate-child-nested-clean: a clean child return was reported as a lost slot"
  pass "a forced secondmate teardown returns a child scout copy with a nested clone clean"
}

# Return succeeds but leaves no readable worktree behind to verify.
add_treehouse_that_removes_copy() {
  local case_dir=$1
  cat > "$case_dir/fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = return ]; then
  for a in "$@"; do wt=$a; done
  rm -f "$wt/.git"
fi
exit 0
SH
  chmod +x "$case_dir/fakebin/treehouse"
}

# The remote host runs exactly this forced secondmate teardown for
# `fm-remote-secondmate-control.sh retire --force`; the local side finishes the
# route, record, and reply-source cleanup when it exits 0 or 4 (lost slot).
test_forced_secondmate_dirty_child_return_warns_and_completes() {
  local case_dir home child_wt rc
  case_dir=$(make_case secondmate-child-dirty-return)
  write_meta "$case_dir" local-only secondmate
  home="$case_dir/secondmate-home"
  mkdir -p "$home/state" "$home/data" "$home/config" "$home/projects"
  printf '%s\n' task-x1 > "$home/.fm-secondmate-home"
  printf '%s\n' "home=$home" >> "$case_dir/state/task-x1.meta"
  child_wt="$case_dir/pool/6/repo"
  mkdir -p "$case_dir/pool/6"
  git -C "$case_dir/project" worktree add -q -b fm/child-scout "$child_wt" main
  printf '{"worktrees":[{"name":"6","path":"%s"}]}\n' "$child_wt" \
    > "$case_dir/pool/treehouse-state.json"
  fm_write_meta "$home/state/child-scout.meta" \
    "window=firstmate:fm-child-scout" \
    "endpoint_task_id=child-scout" \
    "worktree=$child_wt" \
    "project=$case_dir/project" \
    "kind=scout" \
    "mode=local-only"
  add_treehouse_that_leaves_residue "$case_dir"

  rc=0
  run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 4 "$rc" "secondmate-child-dirty-return: a lost child slot should exit 4 after retirement"
  assert_grep "lost this slot" "$case_dir/stderr" \
    "secondmate-child-dirty-return: no lost-slot warning for the dirty child return"
  assert_grep "left-behind-clone" "$case_dir/stderr" \
    "secondmate-child-dirty-return: warning did not name the remaining path"
  assert_absent "$case_dir/state/task-x1.meta" "secondmate-child-dirty-return: task record was not removed"
  assert_absent "$home" "secondmate-child-dirty-return: secondmate home was not removed"
  pass "a forced secondmate teardown warns about a dirty child return and still completes"
}

test_return_that_removes_copy_warns_cannot_verify() {
  local case_dir wt rc
  case_dir=$(make_case return-removes-copy)
  wt=$(move_case_to_pool_slot "$case_dir" 7)
  write_meta "$case_dir" no-mistakes scout "$wt"
  prepare_scout_teardown "$case_dir"
  add_treehouse_that_removes_copy "$case_dir"

  rc=0
  FM_HOME="$case_dir" run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 4 "$rc" "return-removes-copy: an unverified slot should exit 4 after cleanup"
  assert_grep "lost this slot" "$case_dir/stderr" "return-removes-copy: no lost-slot warning"
  assert_grep "cannot verify" "$case_dir/stderr" "return-removes-copy: warning did not say the slot is unverified"
  assert_grep "$wt" "$case_dir/stderr" "return-removes-copy: warning did not name the copy"
  assert_no_grep "teardown task-x1 complete" "$case_dir/stdout" \
    "return-removes-copy: stdout still reported a clean return"
  assert_absent "$case_dir/state/task-x1.meta" "return-removes-copy: task record was not removed"
  pass "a return that leaves no readable copy reports the slot as unverified, not clean"
}

test_scout_ignored_files_survive_scratch_clean() {
  local case_dir wt rc
  case_dir=$(make_case scout-ignored-survives)
  wt="$case_dir/wt"
  write_meta "$case_dir" no-mistakes scout
  prepare_scout_teardown "$case_dir"
  printf '%s\n' 'ignored-cache/' > "$wt/.gitignore"
  git -C "$wt" add .gitignore
  git -C "$wt" -c user.email=t@t -c user.name=t commit -q -m "ignore cache"
  mkdir -p "$wt/ignored-cache"
  printf 'keep-me\n' > "$wt/ignored-cache/blob"
  printf 'scratch\n' > "$wt/scratch.txt"
  add_treehouse_clean_fd "$case_dir"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "scout-ignored: teardown should succeed"
  [ "$(cat "$wt/ignored-cache/blob")" = "keep-me" ] \
    || fail "scout-ignored: ignored file was removed or changed"
  assert_absent "$wt/scratch.txt" "scout-ignored: scratch file survived"
  [ -z "$(git -C "$wt" status --porcelain --untracked-files=all)" ] \
    || fail "scout-ignored: untracked entries remain: $(git -C "$wt" status --porcelain --untracked-files=all)"
  pass "ignored files survive the scratch clean and plain scratch does not"
}

test_gh_error_and_content_absent_refuses() {
  local case_dir rc
  case_dir=$(make_case gh-error)
  write_meta "$case_dir" no-mistakes ship
  printf '%s\n' 'pr=https://github.com/example/repo/pull/7' >> "$case_dir/state/task-x1.meta"
  # Real content not pushed, the PR lookup errors, and origin/main never gained the
  # content. The fail-safe must refuse rather than allow on a transient gh failure.
  wt_commit_file "$case_dir" feature.txt hello "add feature"
  add_gh_axi_error "$case_dir"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "gh-error: teardown should refuse when the PR lookup errors and content is not landed"
  grep -q REFUSED "$case_dir/stderr" || fail "gh-error: no REFUSED line in stderr"
  pass "gh lookup error with content not in default refuses (fail-safe)"
}

# Write a meta that predates the spawn_gen field entirely. Args: case_dir mode kind
write_legacy_meta() {
  local case_dir=$1 mode=$2 kind=$3
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=firstmate:fm-task-x1" \
    "endpoint_task_id=task-x1" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    "kind=$kind" \
    "mode=$mode" \
    "harness=codex"
}

# Count spawn_gen fields in the task's meta, so a refusal can prove it left the
# record byte-equivalent rather than stamped.
legacy_meta_gen_count() {
  local case_dir=$1
  awk -F= '$1 == "spawn_gen" { count++ } END { print count + 0 }' \
    "$case_dir/state/task-x1.meta" 2>/dev/null || printf '0\n'
}

# Override fakebin/tmux so the recovery-grade classifier reads the endpoint as
# unreadable (a session inventory failure it cannot attribute), never dead.
add_unreadable_tmux() {
  local case_dir=$1
  cat > "$case_dir/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  list-windows) echo "error connecting to fixture: permission denied" >&2 ; exit 1 ;;
esac
exit 0
SH
  chmod +x "$case_dir/fakebin/tmux"
}

test_legacy_record_without_the_flag_refuses() {
  local case_dir rc
  case_dir=$(make_case legacy-noflag)
  write_legacy_meta "$case_dir" no-mistakes ship
  seed_backlog_in_flight "$case_dir"
  wt_commit "$case_dir" "landed legacy work"
  add_fork_with_pushed_branch "$case_dir"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "legacy-noflag: a record without spawn_gen must refuse without --legacy-record"
  grep -q -- '--legacy-record' "$case_dir/stderr" \
    || fail "legacy-noflag: the refusal did not name the --legacy-record path"
  [ "$(legacy_meta_gen_count "$case_dir")" = 0 ] \
    || fail "legacy-noflag: the refusal stamped a spawn generation into the record"
  [ "$(backlog_row_state "$case_dir")" = in_flight ] \
    || fail "legacy-noflag: the refusal closed the backlog item anyway"
  assert_present "$case_dir/state/task-x1.meta" \
    "legacy-noflag: the refusal removed the task record"
  pass "a record predating spawn_gen refuses teardown until --legacy-record is passed"
}

write_windowless_legacy_meta() {
  local case_dir=$1 mode=$2 kind=$3 worktree
  worktree=${4:-$case_dir/wt}
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "worktree=$worktree" \
    "project=$case_dir/project" \
    "kind=$kind" \
    "mode=$mode" \
    "harness=codex"
}

test_windowless_legacy_record_with_gone_worktree_tears_down() {
  local case_dir out
  case_dir=$(make_case windowless-gone)
  write_windowless_legacy_meta "$case_dir" no-mistakes ship "$case_dir/missing-wt"
  seed_backlog_in_flight "$case_dir"

  out=$(run_teardown "$case_dir") \
    || fail "windowless-gone: teardown refused a leftover with no window, no spawn_gen, and no worktree"
  printf '%s\n' "$out" | grep -Fq 'legacy record accepted without spawn_gen: endpoint missing' \
    || fail "windowless-gone: the teardown line did not log the missing-endpoint leftover: $out"
  printf '%s\n' "$out" | grep -Fq 'window none' \
    || fail "windowless-gone: the teardown line did not say there was no window: $out"
  [ "$(backlog_row_state "$case_dir")" = "done" ] \
    || fail "windowless-gone: teardown returned success with its backlog item still open"
  assert_absent "$case_dir/state/task-x1.meta" \
    "windowless-gone: teardown left the leftover record"
  pass "a windowless leftover with no spawn_gen and no worktree tears down without --legacy-record"
}

test_windowless_legacy_record_tears_down_with_the_legacy_flag() {
  local case_dir out
  case_dir=$(make_case windowless-flag)
  write_windowless_legacy_meta "$case_dir" no-mistakes ship "$case_dir/missing-wt"
  seed_backlog_in_flight "$case_dir"

  out=$(run_teardown "$case_dir" --legacy-record) \
    || fail "windowless-flag: --legacy-record refused a leftover with no window and no spawn_gen"
  printf '%s\n' "$out" | grep -Fq 'legacy record accepted without spawn_gen: endpoint missing' \
    || fail "windowless-flag: the teardown line did not log the missing-endpoint leftover: $out"
  assert_absent "$case_dir/state/task-x1.meta" \
    "windowless-flag: teardown left the leftover record"
  [ "$(backlog_row_state "$case_dir")" = "done" ] \
    || fail "windowless-flag: teardown returned success with its backlog item still open"
  pass "a windowless leftover with no spawn_gen also tears down when --legacy-record is passed"
}

test_windowless_legacy_record_still_refuses_unlanded_work() {
  local case_dir rc before
  case_dir=$(make_case windowless-unlanded)
  write_windowless_legacy_meta "$case_dir" no-mistakes ship
  seed_backlog_in_flight "$case_dir"
  wt_commit_file "$case_dir" feature.txt unique-windowless-content "real unlanded work"
  before=$(cksum "$case_dir/state/task-x1.meta" | awk '{print $1, $2}')

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "windowless-unlanded: a still-present unlanded worktree must refuse"
  grep -q REFUSED "$case_dir/stderr" \
    || fail "windowless-unlanded: no REFUSED line for unlanded windowless work"
  [ "$(cksum "$case_dir/state/task-x1.meta" | awk '{print $1, $2}')" = "$before" ] \
    || fail "windowless-unlanded: the unlanded refusal modified the task record"
  [ "$(backlog_row_state "$case_dir")" = in_flight ] \
    || fail "windowless-unlanded: the unlanded refusal closed the backlog item anyway"
  pass "a windowless leftover still refuses while its worktree holds unlanded work"
}

assert_windowless_record_refuses() {  # <case-dir> <description> <refusal>
  local case_dir=$1 description=$2 refusal=$3 rc before
  before=$(cksum "$case_dir/state/task-x1.meta" | awk '{print $1, $2}')
  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "$description: a windowless record outside the leftover class must refuse"
  grep -Fq "$refusal" "$case_dir/stderr" \
    || fail "$description: the refusal was not '$refusal': $(cat "$case_dir/stderr")"
  [ "$(cksum "$case_dir/state/task-x1.meta" | awk '{print $1, $2}')" = "$before" ] \
    || fail "$description: the refusal modified the task record"
}

test_windowless_record_outside_the_leftover_class_still_refuses() {
  local case_dir
  case_dir=$(make_case windowless-spawn-gen)
  write_windowless_legacy_meta "$case_dir" no-mistakes ship "$case_dir/missing-wt"
  printf '%s\n' 'spawn_gen=s1700000000.1.abc' >> "$case_dir/state/task-x1.meta"
  seed_backlog_in_flight "$case_dir"
  assert_windowless_record_refuses "$case_dir" windowless-spawn-gen "missing, empty, or ambiguous window endpoint"

  case_dir=$(make_case windowless-orca)
  write_windowless_legacy_meta "$case_dir" no-mistakes ship "$case_dir/missing-wt"
  printf '%s\n' 'backend=orca' 'terminal=term-7' >> "$case_dir/state/task-x1.meta"
  seed_backlog_in_flight "$case_dir"
  assert_windowless_record_refuses "$case_dir" windowless-orca "no spawn_gen that identifies one exact incarnation"

  case_dir=$(make_case windowless-no-backlog)
  write_windowless_legacy_meta "$case_dir" no-mistakes ship "$case_dir/missing-wt"
  assert_windowless_record_refuses "$case_dir" windowless-no-backlog "missing, empty, or ambiguous window endpoint"

  case_dir=$(make_case windowless-dup-project)
  write_windowless_legacy_meta "$case_dir" no-mistakes ship "$case_dir/missing-wt"
  printf '%s\n' "project=$case_dir/other-project" >> "$case_dir/state/task-x1.meta"
  seed_backlog_in_flight "$case_dir"
  assert_windowless_record_refuses "$case_dir" windowless-dup-project "no spawn_gen that identifies one exact incarnation"
  case_dir=$(make_case windowless-foreign-binding)
  write_windowless_legacy_meta "$case_dir" no-mistakes ship "$case_dir/missing-wt"
  printf '%s\n' 'endpoint_task_id=task-other' >> "$case_dir/state/task-x1.meta"
  seed_backlog_in_flight "$case_dir"
  assert_windowless_record_refuses "$case_dir" windowless-foreign-binding "no spawn_gen that identifies one exact incarnation"

  case_dir=$(make_case windowless-terminal)
  write_windowless_legacy_meta "$case_dir" no-mistakes ship "$case_dir/missing-wt"
  printf '%s\n' 'terminal=term-7' >> "$case_dir/state/task-x1.meta"
  seed_backlog_in_flight "$case_dir"
  assert_windowless_record_refuses "$case_dir" windowless-terminal "no spawn_gen that identifies one exact incarnation"

  case_dir=$(make_case windowless-herdr-identity)
  write_windowless_legacy_meta "$case_dir" no-mistakes ship "$case_dir/missing-wt"
  printf '%s\n' 'backend=tmux' 'herdr_session=s1' 'herdr_pane_id=p1' >> "$case_dir/state/task-x1.meta"
  seed_backlog_in_flight "$case_dir"
  assert_windowless_record_refuses "$case_dir" windowless-herdr-identity "no spawn_gen that identifies one exact incarnation"

  case_dir=$(make_case windowless-cmux-identity)
  write_windowless_legacy_meta "$case_dir" no-mistakes ship "$case_dir/missing-wt"
  printf '%s\n' 'cmux_surface_id=surface-1' >> "$case_dir/state/task-x1.meta"
  seed_backlog_in_flight "$case_dir"
  assert_windowless_record_refuses "$case_dir" windowless-cmux-identity "no spawn_gen that identifies one exact incarnation"

  case_dir=$(make_case windowless-control-char)
  write_windowless_legacy_meta "$case_dir" no-mistakes ship "$case_dir/missing"$'\t'"wt"
  seed_backlog_in_flight "$case_dir"
  assert_windowless_record_refuses "$case_dir" windowless-control-char "no spawn_gen that identifies one exact incarnation"
  pass "a windowless record with a spawn_gen, a non-tmux backend or endpoint identity, no backlog validation, or ambiguous, foreign, or malformed identity still refuses"
}

test_windowless_leftover_retries_its_retained_legacy_stamp_without_the_flag() {
  local case_dir rc out
  case_dir=$(make_case windowless-retry)
  write_windowless_legacy_meta "$case_dir" no-mistakes ship "$case_dir/missing-wt"
  printf '%s\n' 'pr=not-a-valid-url' >> "$case_dir/state/task-x1.meta"
  seed_backlog_in_flight "$case_dir"
  add_failing_truncate_perl "$case_dir"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" "windowless-retry: an unrecordable close must fail the first attempt"
  [ "$(legacy_meta_gen_count "$case_dir")" = 1 ] \
    || fail "windowless-retry: the failed attempt did not leave its legacy stamp on the record"

  rm -f "$case_dir/fakebin/perl"
  sed -i.bak '/^pr=/d' "$case_dir/state/task-x1.meta" && rm -f "$case_dir/state/task-x1.meta.bak"
  out=$(run_teardown "$case_dir") \
    || fail "windowless-retry: the flag-less retry refused the retained legacy stamp"
  printf '%s\n' "$out" | grep -Fq 'legacy record accepted without spawn_gen: endpoint missing' \
    || fail "windowless-retry: the retry did not accept the missing-endpoint leftover: $out"
  assert_absent "$case_dir/state/task-x1.meta" \
    "windowless-retry: the retry left the leftover record"
  [ "$(backlog_row_state "$case_dir")" = "done" ] \
    || fail "windowless-retry: the retry returned success with its backlog item still open"
  pass "a windowless leftover retries its retained legacy stamp without --legacy-record"
}

test_legacy_record_teardown_completes_when_landed_and_endpoint_dead() {
  local case_dir out
  case_dir=$(make_case legacy-allow)
  write_legacy_meta "$case_dir" no-mistakes ship
  seed_backlog_in_flight "$case_dir"
  wt_commit "$case_dir" "landed legacy work"
  add_fork_with_pushed_branch "$case_dir"
  # The default fakebin tmux answers every query with success and no output, so
  # the classifier reads the recorded window as authoritatively missing.

  out=$(run_teardown "$case_dir" --legacy-record) \
    || fail "legacy-allow: teardown refused a landed legacy record with a dead endpoint"
  [ "$(backlog_row_state "$case_dir")" = "done" ] \
    || fail "legacy-allow: teardown returned success with its backlog item still open"
  printf '%s\n' "$out" | grep -Fq 'legacy record accepted without spawn_gen: endpoint missing, incarnation legacy-' \
    || fail "legacy-allow: the teardown line did not log the accepted legacy incarnation: $out"
  assert_absent "$case_dir/state/task-x1.backlog-close" \
    "legacy-allow: a landed legacy close left its pending-close record behind"
  assert_absent "$case_dir/state/task-x1.meta" \
    "legacy-allow: teardown left the task record behind"
  pass "a landed legacy record with a dead endpoint tears down and logs its accepted incarnation"
}

test_legacy_record_teardown_refuses_unlanded_work() {
  local case_dir rc before
  case_dir=$(make_case legacy-unlanded)
  write_legacy_meta "$case_dir" no-mistakes ship
  seed_backlog_in_flight "$case_dir"
  # Real content committed but pushed nowhere and merged nowhere.
  wt_commit_file "$case_dir" feature.txt unique-legacy-content "real unlanded work"
  before=$(cksum "$case_dir/state/task-x1.meta" | awk '{print $1, $2}')

  set +e
  run_teardown "$case_dir" --legacy-record > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "legacy-unlanded: --legacy-record must not relax the unlanded-work refusal"
  grep -q REFUSED "$case_dir/stderr" \
    || fail "legacy-unlanded: no REFUSED line for unlanded legacy work"
  [ "$(legacy_meta_gen_count "$case_dir")" = 0 ] \
    || fail "legacy-unlanded: the unlanded refusal stamped a spawn generation into the record"
  [ "$(cksum "$case_dir/state/task-x1.meta" | awk '{print $1, $2}')" = "$before" ] \
    || fail "legacy-unlanded: the unlanded refusal modified the task record"
  [ "$(backlog_row_state "$case_dir")" = in_flight ] \
    || fail "legacy-unlanded: the unlanded refusal closed the backlog item anyway"
  pass "--legacy-record never relaxes the unlanded-work refusal"
}

test_legacy_record_teardown_refuses_an_ambiguous_endpoint() {
  local case_dir rc before
  case_dir=$(make_case legacy-ambiguous)
  write_legacy_meta "$case_dir" no-mistakes ship
  seed_backlog_in_flight "$case_dir"
  wt_commit "$case_dir" "landed legacy work"
  add_fork_with_pushed_branch "$case_dir"
  add_unreadable_tmux "$case_dir"
  before=$(cksum "$case_dir/state/task-x1.meta" | awk '{print $1, $2}')

  set +e
  run_teardown "$case_dir" --legacy-record > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "legacy-ambiguous: an unreadable endpoint must refuse the legacy acceptance"
  grep -q "not confidently dead or agent-less" "$case_dir/stderr" \
    || fail "legacy-ambiguous: the refusal did not name the endpoint state"
  [ "$(cksum "$case_dir/state/task-x1.meta" | awk '{print $1, $2}')" = "$before" ] \
    || fail "legacy-ambiguous: the endpoint refusal modified the task record"
  [ "$(backlog_row_state "$case_dir")" = in_flight ] \
    || fail "legacy-ambiguous: the endpoint refusal closed the backlog item anyway"
  pass "an endpoint that cannot be confidently read as dead refuses --legacy-record teardown"
}

test_legacy_record_rolls_the_stamp_back_when_the_marker_write_fails() {
  local case_dir rc before
  case_dir=$(make_case legacy-stamp-rollback)
  write_legacy_meta "$case_dir" no-mistakes ship
  printf '%s\n' 'pr=not-a-valid-url' >> "$case_dir/state/task-x1.meta"
  seed_backlog_in_flight "$case_dir"
  wt_commit "$case_dir" "landed legacy work"
  add_fork_with_pushed_branch "$case_dir"
  before=$(cksum "$case_dir/state/task-x1.meta" | awk '{print $1, $2}')

  set +e
  run_teardown "$case_dir" --legacy-record > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" \
    "legacy-stamp-rollback: an unrecordable close must fail the teardown after accepting the legacy record"
  [ "$(cksum "$case_dir/state/task-x1.meta" | awk '{print $1, $2}')" = "$before" ] \
    || fail "legacy-stamp-rollback: the failed marker write left the record modified"
  grep -q "rolled back" "$case_dir/stderr" \
    || fail "legacy-stamp-rollback: the refusal did not report the rolled-back stamp"
  [ "$(backlog_row_state "$case_dir")" = in_flight ] \
    || fail "legacy-stamp-rollback: the failed teardown closed the backlog item anyway"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout2" 2> "$case_dir/stderr2"
  rc=$?
  set -e
  expect_code 1 "$rc" \
    "legacy-stamp-rollback: the flag-less retry must not sail past the endpoint gate on the rolled-back record"
  grep -q -- '--legacy-record' "$case_dir/stderr2" \
    || fail "legacy-stamp-rollback: the retry refusal did not name the flag path"
  [ "$(cksum "$case_dir/state/task-x1.meta" | awk '{print $1, $2}')" = "$before" ] \
    || fail "legacy-stamp-rollback: the flag-less retry modified the record"
  pass "--legacy-record teardown rolls its stamp back when the close marker write fails"
}

# Override fakebin/perl so ONLY the stamp rollback's truncate fails; every other
# perl call in the lifecycle still runs the real interpreter, so the abandoned
# attempt leaves its stamp behind for exactly the reason under test.
add_failing_truncate_perl() {
  local case_dir=$1 real
  real=$(command -v perl)
  cat > "$case_dir/fakebin/perl" <<SH
#!/usr/bin/env bash
case "\$*" in
  *truncate*) exit 1 ;;
esac
exec "$real" "\$@"
SH
  chmod +x "$case_dir/fakebin/perl"
}

test_retained_legacy_stamp_still_faces_the_endpoint_gate() {
  local case_dir rc stamped
  case_dir=$(make_case legacy-stamp-retained)
  write_legacy_meta "$case_dir" no-mistakes ship
  printf '%s\n' 'pr=not-a-valid-url' >> "$case_dir/state/task-x1.meta"
  seed_backlog_in_flight "$case_dir"
  wt_commit "$case_dir" "landed legacy work"
  add_fork_with_pushed_branch "$case_dir"
  add_failing_truncate_perl "$case_dir"

  set +e
  run_teardown "$case_dir" --legacy-record > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 1 "$rc" \
    "legacy-stamp-retained: an unrecordable close must fail the teardown after accepting the legacy record"
  grep -q "could not be rolled back" "$case_dir/stderr" \
    || fail "legacy-stamp-retained: the fixture did not exercise a failed rollback"
  [ "$(legacy_meta_gen_count "$case_dir")" = 1 ] \
    || fail "legacy-stamp-retained: the abandoned attempt did not leave its stamp on the record"
  stamped=$(cksum "$case_dir/state/task-x1.meta" | awk '{print $1, $2}')

  # The stamp the failed rollback left behind is the whole risk: a retry must
  # not read it as an incarnation some spawn published and sail past the
  # dead-or-agent-less endpoint gate onto a reused endpoint.
  add_unreadable_tmux "$case_dir"
  set +e
  run_teardown "$case_dir" --legacy-record > "$case_dir/stdout2" 2> "$case_dir/stderr2"
  rc=$?
  set -e
  expect_code 1 "$rc" \
    "legacy-stamp-retained: the retry must re-run the endpoint gate on the retained stamp"
  grep -q "not confidently dead or agent-less" "$case_dir/stderr2" \
    || fail "legacy-stamp-retained: the retry skipped the dead-or-agent-less endpoint gate"
  [ "$(legacy_meta_gen_count "$case_dir")" = 1 ] \
    || fail "legacy-stamp-retained: the retry stamped a second incarnation into the record"
  [ "$(cksum "$case_dir/state/task-x1.meta" | awk '{print $1, $2}')" = "$stamped" ] \
    || fail "legacy-stamp-retained: the endpoint refusal modified the task record"
  [ "$(backlog_row_state "$case_dir")" = in_flight ] \
    || fail "legacy-stamp-retained: the endpoint refusal closed the backlog item anyway"

  set +e
  run_teardown "$case_dir" > "$case_dir/stdout3" 2> "$case_dir/stderr3"
  rc=$?
  set -e
  expect_code 1 "$rc" \
    "legacy-stamp-retained: a flag-less retry must refuse the retained legacy stamp"
  grep -q -- '--legacy-record' "$case_dir/stderr3" \
    || fail "legacy-stamp-retained: the flag-less refusal did not name the flag path"
  [ "$(cksum "$case_dir/state/task-x1.meta" | awk '{print $1, $2}')" = "$stamped" ] \
    || fail "legacy-stamp-retained: the flag-less refusal modified the task record"
  pass "a legacy stamp a failed rollback left behind still faces the endpoint gate"
}

test_legacy_record_never_accepts_a_corrupt_spawn_gen() {
  local case_dir rc
  case_dir=$(make_case legacy-corrupt)
  write_legacy_meta "$case_dir" no-mistakes ship
  printf 'spawn_gen=one\nspawn_gen=two\n' >> "$case_dir/state/task-x1.meta"
  seed_backlog_in_flight "$case_dir"
  wt_commit "$case_dir" "landed legacy work"
  add_fork_with_pushed_branch "$case_dir"

  set +e
  run_teardown "$case_dir" --legacy-record > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "legacy-corrupt: an ambiguous spawn_gen must refuse even with --legacy-record"
  grep -q "unreadable spawn_gen" "$case_dir/stderr" \
    || fail "legacy-corrupt: the refusal did not name the unreadable spawn_gen"
  [ "$(legacy_meta_gen_count "$case_dir")" = 2 ] \
    || fail "legacy-corrupt: the refusal rewrote the corrupt record"
  [ "$(backlog_row_state "$case_dir")" = in_flight ] \
    || fail "legacy-corrupt: the refusal closed the backlog item anyway"
  pass "a corrupt spawn_gen is never accepted as a legacy record"
}

test_stale_index_lock_cleared_and_teardown_succeeds() {
  local case_dir rc lock
  case_dir=$(make_case stale-index-lock)
  write_meta "$case_dir" no-mistakes ship
  wt_commit "$case_dir" "shippable work"
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/project" fetch -q origin

  add_lock_aware_treehouse "$case_dir"
  add_lsof_no_holder "$case_dir"

  lock=$(git_index_lock_path "$case_dir/wt")
  mkdir -p "$(dirname "$lock")"
  : > "$lock"
  touch -t 200001010000 "$lock"

  set +e
  FM_STALE_WORKTREE_LOCK_RETRY_WAIT_SECS=0 FM_STALE_WORKTREE_LOCK_AGE_SECS=1 \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "stale-index-lock: teardown should succeed after clearing the provably stale lock"
  assert_grep "removed provably-stale git lock" "$case_dir/stderr" \
    "stale-index-lock: teardown did not report clearing the stale lock"
  assert_absent "$lock" "stale-index-lock: stale lock file should have been removed"
  pass "provably-stale worktree index.lock (old, no live holder) is cleared and teardown succeeds"
}

test_live_index_lock_is_never_removed_and_teardown_refuses() {
  local case_dir rc lock
  case_dir=$(make_case live-index-lock)
  write_meta "$case_dir" no-mistakes ship
  wt_commit "$case_dir" "shippable work"
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/project" fetch -q origin

  add_lock_aware_treehouse "$case_dir"
  add_lsof_live_holder "$case_dir"

  lock=$(git_index_lock_path "$case_dir/wt")
  mkdir -p "$(dirname "$lock")"
  : > "$lock"
  # Even an old mtime must not be enough on its own: a live holder always wins.
  touch -t 200001010000 "$lock"

  set +e
  FM_STALE_WORKTREE_LOCK_RETRY_WAIT_SECS=0 FM_STALE_WORKTREE_LOCK_AGE_SECS=1 \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "live-index-lock: teardown should refuse when the lock has a live holder"
  assert_grep "not provably stale" "$case_dir/stderr" \
    "live-index-lock: teardown did not explain the refusal"
  assert_not_contains "$(cat "$case_dir/stderr")" "removed provably-stale git lock" \
    "live-index-lock: teardown removed a lock with a live holder"
  [ -e "$lock" ] || fail "live-index-lock: live-held lock file was removed"
  pass "live-held worktree index.lock is never removed and teardown refuses"
}

test_lsof_error_never_clears_index_lock() {
  local case_dir rc lock
  case_dir=$(make_case lsof-error-index-lock)
  write_meta "$case_dir" no-mistakes ship
  wt_commit "$case_dir" "shippable work"
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/project" fetch -q origin

  add_lock_aware_treehouse "$case_dir"
  add_lsof_error "$case_dir"

  lock=$(git_index_lock_path "$case_dir/wt")
  mkdir -p "$(dirname "$lock")"
  : > "$lock"
  touch -t 200001010000 "$lock"

  set +e
  FM_STALE_WORKTREE_LOCK_RETRY_WAIT_SECS=0 FM_STALE_WORKTREE_LOCK_AGE_SECS=1 \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "lsof-error-index-lock: teardown should refuse when lsof errors"
  assert_grep "REFUSED: cannot determine leaked processes" "$case_dir/stderr" \
    "lsof-error-index-lock: teardown did not report the lsof failure"
  assert_not_contains "$(cat "$case_dir/stderr")" "removed provably-stale git lock" \
    "lsof-error-index-lock: teardown removed a lock after lsof failed"
  [ -e "$lock" ] || fail "lsof-error-index-lock: lock file was removed after lsof failed"
  pass "lsof errors leave worktree index.lock in place and refuse teardown"
}

test_stale_index_lock_cleanup_rechecks_dirty_worktree() {
  local case_dir rc lock
  case_dir=$(make_case stale-lock-dirty-recheck)
  write_meta "$case_dir" no-mistakes ship
  wt_commit_file "$case_dir" feature.txt landed "landed work"
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/project" fetch -q origin
  printf '%s\n' dirty > "$case_dir/wt/feature.txt"

  add_lock_aware_treehouse "$case_dir"
  add_lsof_no_holder "$case_dir"
  add_git_status_lock_failure "$case_dir"

  lock=$(git_index_lock_path "$case_dir/wt")
  mkdir -p "$(dirname "$lock")"
  : > "$lock"
  touch -t 200001010000 "$lock"

  set +e
  FM_STALE_WORKTREE_LOCK_RETRY_WAIT_SECS=0 FM_STALE_WORKTREE_LOCK_AGE_SECS=1 \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "stale-lock-dirty-recheck: teardown should refuse dirty work after clearing the stale lock"
  assert_grep "removed provably-stale git lock" "$case_dir/stderr" \
    "stale-lock-dirty-recheck: teardown did not report clearing the stale lock"
  assert_grep "uncommitted changes present" "$case_dir/stderr" \
    "stale-lock-dirty-recheck: teardown did not re-run the dirty check"
  assert_absent "$lock" "stale-lock-dirty-recheck: stale lock file should have been removed"
  [ -f "$case_dir/state/task-x1.meta" ] || fail "stale-lock-dirty-recheck: teardown completed despite dirty work"
  pass "stale lock cleanup rechecks and refuses dirty worktree before return"
}

test_non_linked_index_lock_path_is_checked_from_worktree() {
  local case_dir rc lock
  case_dir=$(make_case non-linked-index-lock)
  git -C "$case_dir/project" worktree remove --force "$case_dir/wt"
  git clone -q "$case_dir/origin.git" "$case_dir/wt"
  git -C "$case_dir/wt" checkout -q -b fm/task-x1
  write_meta "$case_dir" no-mistakes ship
  wt_commit "$case_dir" "shippable normal clone work"
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/wt" fetch -q origin

  add_lock_aware_treehouse "$case_dir"
  add_lsof_no_holder "$case_dir"

  lock=$(git_index_lock_path "$case_dir/wt")
  mkdir -p "$(dirname "$lock")"
  : > "$lock"
  touch -t 200001010000 "$lock"

  set +e
  FM_STALE_WORKTREE_LOCK_RETRY_WAIT_SECS=0 FM_STALE_WORKTREE_LOCK_AGE_SECS=1 \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "non-linked-index-lock: teardown should clear a normal repo index.lock"
  assert_grep "removed provably-stale git lock" "$case_dir/stderr" \
    "non-linked-index-lock: teardown did not report clearing the stale lock"
  assert_absent "$lock" "non-linked-index-lock: stale lock file should have been removed"
  pass "normal repo index.lock is resolved from the worktree and cleared when stale"
}

test_index_lock_mtime_read_failure_refuses() {
  local case_dir rc lock
  # The mtime fault is injected by a fake stat on PATH; on Darwin the lock
  # helper now calls /usr/bin/stat directly, so the fake can never fire there.
  # Skip the Darwin run of this case.
  if [ "$(uname)" = Darwin ]; then
    pass "index-lock mtime fault injection is PATH-based; skipped on Darwin where stat is /usr/bin/stat"
    return
  fi
  case_dir=$(make_case mtime-error-index-lock)
  write_meta "$case_dir" no-mistakes ship
  wt_commit "$case_dir" "shippable work"
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/project" fetch -q origin

  add_lock_aware_treehouse "$case_dir"
  add_lsof_no_holder "$case_dir"
  add_stat_error "$case_dir"

  lock=$(git_index_lock_path "$case_dir/wt")
  mkdir -p "$(dirname "$lock")"
  : > "$lock"
  touch -t 200001010000 "$lock"

  set +e
  FM_STALE_WORKTREE_LOCK_RETRY_WAIT_SECS=0 FM_STALE_WORKTREE_LOCK_AGE_SECS=1 \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "mtime-error-index-lock: teardown should refuse when lock mtime cannot be read"
  assert_grep "cannot read mtime for git lock" "$case_dir/stderr" \
    "mtime-error-index-lock: teardown did not report the mtime read failure"
  assert_grep "not provably stale" "$case_dir/stderr" \
    "mtime-error-index-lock: teardown did not explain the refusal"
  assert_not_contains "$(cat "$case_dir/stderr")" "removed provably-stale git lock" \
    "mtime-error-index-lock: teardown removed a lock after mtime read failed"
  [ -e "$lock" ] || fail "mtime-error-index-lock: lock file was removed after mtime read failed"
  pass "lock mtime read failures leave worktree index.lock in place and refuse teardown"
}

test_transient_index_lock_clears_after_first_attempt_and_retry_succeeds() {
  local case_dir rc lock attempt_file
  case_dir=$(make_case transient-index-lock-retry)
  write_meta "$case_dir" no-mistakes ship
  wt_commit "$case_dir" "shippable work"
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/project" fetch -q origin

  add_transient_lock_treehouse "$case_dir"
  add_lsof_no_holder "$case_dir"

  lock=$(git_index_lock_path "$case_dir/wt")
  mkdir -p "$(dirname "$lock")"
  : > "$lock"
  # Fresh lock: not old enough for the force-remove path; patience must win.
  touch "$lock"

  attempt_file="$case_dir/treehouse-attempts"
  : > "$attempt_file"

  set +e
  TREEHOUSE_ATTEMPT_FILE="$attempt_file" \
  FM_TREEHOUSE_RETURN_LOCK_RETRIES=2 \
  FM_TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS=0 \
  FM_STALE_WORKTREE_LOCK_AGE_SECS=3600 \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "transient-index-lock: teardown should succeed on retry after lock self-clears"
  assert_grep "succeeded on retry" "$case_dir/stderr" \
    "transient-index-lock: teardown did not report success on retry"
  assert_not_contains "$(cat "$case_dir/stderr")" "removed provably-stale git lock" \
    "transient-index-lock: teardown force-removed a lock that only needed patience"
  [ "$(cat "$attempt_file")" = 2 ] \
    || fail "transient-index-lock: expected exactly 2 treehouse return attempts, got $(cat "$attempt_file")"
  assert_absent "$lock" "transient-index-lock: lock should remain cleared after success"
  pass "transient index.lock cleared after first failed return is retried successfully without force-remove"
}

test_persistent_index_lock_exhausts_retries_and_refuses_loudly() {
  local case_dir rc lock
  case_dir=$(make_case persistent-index-lock)
  write_meta "$case_dir" no-mistakes ship
  wt_commit "$case_dir" "shippable work"
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/project" fetch -q origin

  add_persistent_lock_treehouse "$case_dir"
  # Fresh lock with a live holder: never provably stale, never force-removed.
  add_lsof_live_holder "$case_dir"

  lock=$(git_index_lock_path "$case_dir/wt")
  mkdir -p "$(dirname "$lock")"
  : > "$lock"
  touch "$lock"

  set +e
  FM_TREEHOUSE_RETURN_LOCK_RETRIES=2 \
  FM_TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS=0 \
  FM_STALE_WORKTREE_LOCK_AGE_SECS=3600 \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "persistent-index-lock: teardown should refuse when the lock never clears"
  assert_grep "persisted across" "$case_dir/stderr" \
    "persistent-index-lock: teardown did not mention the exhausted retry window"
  assert_grep "not provably stale" "$case_dir/stderr" \
    "persistent-index-lock: teardown did not explain the refusal"
  assert_not_contains "$(cat "$case_dir/stderr")" "removed provably-stale git lock" \
    "persistent-index-lock: teardown removed a non-stale lock"
  [ -e "$lock" ] || fail "persistent-index-lock: lock file was removed"
  [ -f "$case_dir/state/task-x1.meta" ] \
    || fail "persistent-index-lock: teardown completed despite persistent lock"
  pass "persistent index.lock exhausts retries and refuses without force-removing the lock"
}

test_empty_retry_wait_uses_default_without_aborting() {
  local case_dir rc lock attempt_file
  case_dir=$(make_case empty-retry-wait)
  write_meta "$case_dir" no-mistakes ship
  wt_commit "$case_dir" "shippable work"
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/project" fetch -q origin

  add_transient_lock_treehouse "$case_dir"
  add_lsof_no_holder "$case_dir"

  lock=$(git_index_lock_path "$case_dir/wt")
  mkdir -p "$(dirname "$lock")"
  : > "$lock"

  attempt_file="$case_dir/treehouse-attempts"
  : > "$attempt_file"

  set +e
  TREEHOUSE_ATTEMPT_FILE="$attempt_file" \
  FM_TREEHOUSE_RETURN_LOCK_RETRIES=1 \
  FM_TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS='' \
  FM_STALE_WORKTREE_LOCK_RETRY_WAIT_SECS='' \
  FM_STALE_WORKTREE_LOCK_AGE_SECS=3600 \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "empty-retry-wait: teardown should fall back to the default wait"
  assert_grep "waiting 1s and retrying" "$case_dir/stderr" \
    "empty-retry-wait: teardown did not use the default retry wait"
  [ "$(cat "$attempt_file")" = 2 ] \
    || fail "empty-retry-wait: expected exactly 2 treehouse return attempts, got $(cat "$attempt_file")"
  pass "empty retry wait overrides use the default without aborting teardown"
}

test_fractional_legacy_retry_wait_refuses_without_arithmetic_error() {
  local case_dir rc lock
  case_dir=$(make_case fractional-legacy-retry-wait)
  write_meta "$case_dir" no-mistakes ship
  wt_commit "$case_dir" "shippable work"
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/project" fetch -q origin

  add_persistent_lock_treehouse "$case_dir"
  add_lsof_live_holder "$case_dir"

  lock=$(git_index_lock_path "$case_dir/wt")
  mkdir -p "$(dirname "$lock")"
  : > "$lock"

  set +e
  FM_TREEHOUSE_RETURN_LOCK_RETRIES=1 \
  FM_TREEHOUSE_RETURN_LOCK_RETRY_WAIT_SECS='' \
  FM_STALE_WORKTREE_LOCK_RETRY_WAIT_SECS=0.1 \
  FM_STALE_WORKTREE_LOCK_AGE_SECS=3600 \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 1 "$rc" "fractional-legacy-retry-wait: teardown should fail only for the persistent lock"
  assert_grep "waiting 0.1s each" "$case_dir/stderr" \
    "fractional-legacy-retry-wait: teardown did not preserve the legacy fractional wait"
  assert_not_contains "$(cat "$case_dir/stderr")" "syntax error" \
    "fractional-legacy-retry-wait: teardown hit an arithmetic error"
  pass "fractional legacy retry wait remains supported without arithmetic"
}

test_local_only_force_overrides_unpushed() {
  local case_dir rc
  case_dir=$(make_case force-override)
  write_meta "$case_dir" local-only ship
  wt_commit "$case_dir" "unpushed work"

  set +e
  run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "force-override: --force should bypass the unpushed-work check"
  ! grep -q REFUSED "$case_dir/stderr" || fail "force-override: REFUSED printed despite --force"
  pass "local-only worktree with unpushed work is torn down under --force (escape hatch)"
}

# Mark the case's home as a secondmate home bound to a parent: teardown and
# fm-pr-check run with FM_HOME="$case_dir/home" so the parent-channel
# publishers resolve that binding while the task state stays in $case_dir/state.
configure_secondmate_home() {  # <case-dir> <local|remote> [<parent-home>]
  local case_dir=$1 route=$2 parent=${3:-} home="$1/home"
  mkdir -p "$home"
  printf 'mate-x\n' > "$home/.fm-secondmate-home"
  {
    printf 'schema=fm-secondmate-parent.v1\nroute=%s\n' "$route"
    [ "$route" != local ] || printf 'parent_home=%s\n' "$parent"
  } > "$home/.fm-secondmate-parent"
  if [ "$route" = local ]; then
    # A local parent registers the mate; teardown resolves that registration.
    mkdir -p "$parent/state" "$parent/data"
    fm_write_secondmate_meta "$parent/state/mate-x.meta" "$home"
    printf -- '- mate-x - fixture scope (home: %s; scope: fixture; projects: alpha; added 2026-07-14)\n' \
      "$home" > "$parent/data/secondmates.md"
  fi
}

# Registering a PR inside a secondmate home publishes the child's ready line
# with the canonical URL on the parent channel from fm-pr-check itself, once;
# a main home publishes nothing.
test_secondmate_pr_registration_publishes_ready_line() {
  local case_dir pr_head channel url
  url=https://github.com/example/repo/pull/7
  case_dir=$(make_case mate-pr-ready)
  configure_secondmate_home "$case_dir" local "$case_dir/parent"
  mkdir -p "$case_dir/parent/state"
  channel="$case_dir/parent/state/mate-x.status"
  write_meta "$case_dir" no-mistakes ship
  wt_commit_file "$case_dir" feature.txt hello "add feature"
  pr_head=$(git -C "$case_dir/wt" rev-parse HEAD)
  add_gh_pr_merged_for_head "$case_dir" "$pr_head"

  FM_HOME="$case_dir/home" FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$case_dir/state" \
    PATH="$case_dir/fakebin:$PATH" "$PR_CHECK" task-x1 "$url" > "$case_dir/pr-check.out" 2> "$case_dir/pr-check.err" \
    || fail "mate-pr-ready: fm-pr-check failed: $(cat "$case_dir/pr-check.err")"
  grep -q '^armed:' "$case_dir/pr-check.out" || fail "mate-pr-ready: poll was not armed"
  assert_grep "done [key=child-pr-task-x1]: child task-x1 PR ready: $url mode=no-mistakes" <(sed -E 's/ \[at=[0-9]+\]//' "$channel") \
    "mate-pr-ready: the ready line did not reach the parent channel"
  ! grep -q '^actionable:' "$case_dir/pr-check.err" \
    || fail "mate-pr-ready: registration reported a channel problem: $(cat "$case_dir/pr-check.err")"
  FM_HOME="$case_dir/home" FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$case_dir/state" \
    PATH="$case_dir/fakebin:$PATH" "$PR_CHECK" task-x1 "$url" >/dev/null 2>&1 \
    || fail "mate-pr-ready: re-registration failed"
  [ "$(grep -c 'child-pr-task-x1' "$channel")" -eq 1 ] \
    || fail "mate-pr-ready: re-registration duplicated the ready line"

  case_dir=$(make_case main-pr-ready)
  write_meta "$case_dir" no-mistakes ship
  wt_commit_file "$case_dir" feature.txt hello "add feature"
  add_gh_pr_merged_for_head "$case_dir" "$(git -C "$case_dir/wt" rev-parse HEAD)"
  FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$case_dir/state" \
    PATH="$case_dir/fakebin:$PATH" "$PR_CHECK" task-x1 "$url" >/dev/null 2> "$case_dir/pr-check.err" \
    || fail "main-pr-ready: fm-pr-check failed"
  ! grep -q '^actionable:' "$case_dir/pr-check.err" \
    || fail "main-pr-ready: a main home reported a channel problem"
  [ ! -e "$case_dir/state/parent-replies.status" ] || fail "main-pr-ready: a main home wrote a parent reply"
  pass "fm-pr-check publishes the PR-ready line on a secondmate's parent channel once"
}

# Tearing a child down inside a secondmate home delivers the child's final
# ledger line to the parent before the record goes, and refuses (retaining
# every record) while the parent channel cannot be written; a rerun after the
# repair delivers and completes.
test_secondmate_home_teardown_delivers_final_line_or_refuses() {
  local case_dir rc channel wt_head err seq generation

  case_dir=$(make_case mate-teardown-delivers)
  configure_secondmate_home "$case_dir" local "$case_dir/parent"
  mkdir -p "$case_dir/parent/state"
  channel="$case_dir/parent/state/mate-x.status"
  write_meta "$case_dir" local-only ship
  wt_commit "$case_dir" "merged work"
  wt_head=$(git -C "$case_dir/wt" rev-parse HEAD)
  git -C "$case_dir/project" update-ref refs/heads/main "$wt_head"
  printf 'working: shipping\ndone: PR https://github.com/example/repo/pull/9 checks green\n' \
    > "$case_dir/state/task-x1.status"
  set +e
  FM_HOME="$case_dir/home" run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  expect_code 0 "$rc" "mate-teardown-delivers: teardown should succeed: $(cat "$case_dir/stderr")"
  sed -E 's/ \[at=[0-9]+\]//' "$channel" | grep -Eq '^done \[key=child-outcome-task-x1-done-[0-9a-f]{8}\]: child task-x1 done: PR https://github.com/example/repo/pull/9 checks green pr=https://github.com/example/repo/pull/9 mode=local-only$' \
    || fail "mate-teardown-delivers: the final ledger line did not reach the parent: $(cat "$channel" 2>/dev/null)"
  [ ! -e "$case_dir/state/task-x1.meta" ] || fail "mate-teardown-delivers: teardown left the task record"

  case_dir=$(make_case mate-teardown-refuses)
  configure_secondmate_home "$case_dir" local "$case_dir/parent"
  # The channel path is occupied by a directory, so no line can be appended.
  mkdir -p "$case_dir/parent/state/mate-x.status"
  channel="$case_dir/parent/state/mate-x.status"
  write_meta "$case_dir" local-only ship
  mkdir -p "$case_dir/tasktmp"
  printf '!\n' > "$case_dir/state/task-x1.grok-turnend-token"
  printf '!\n' > "$case_dir/state/task-x1.kimi-turnend-token"
  printf 'tasktmp=%s\n' "$case_dir/tasktmp" >> "$case_dir/state/task-x1.meta"
  wt_commit "$case_dir" "merged work"
  wt_head=$(git -C "$case_dir/wt" rev-parse HEAD)
  git -C "$case_dir/project" update-ref refs/heads/main "$wt_head"
  printf 'done: PR https://github.com/example/repo/pull/9 checks green\n' > "$case_dir/state/task-x1.status"
  set +e
  FM_HOME="$case_dir/home" run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "mate-teardown-refuses: teardown proceeded with an undelivered final line"
  grep -q 'has not reached the parent channel' "$case_dir/stderr" \
    || fail "mate-teardown-refuses: refusal did not name the parent channel: $(cat "$case_dir/stderr")"
  [ -f "$case_dir/state/task-x1.meta" ] && [ -f "$case_dir/state/task-x1.status" ] \
    || fail "mate-teardown-refuses: refusal did not retain the task records"
  [ -f "$case_dir/state/task-x1.grok-turnend-token" ] \
    && [ -f "$case_dir/state/task-x1.kimi-turnend-token" ] \
    && [ -d "$case_dir/tasktmp" ] \
    || fail "mate-teardown-refuses: refusal removed endpoint records before parent delivery"
  rmdir "$channel"
  err=$(FM_HOME="$case_dir/home" FM_STATE_OVERRIDE="$case_dir/state" \
    "$ROOT/bin/fm-wake-drain.sh" 2>&1 >/dev/null)
  seq=$(printf '%s\n' "$err" | sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation .*/\1/p')
  generation=$(printf '%s\n' "$err" | sed -n 's/^WAKE_ACK_REQUIRED:.*--recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p')
  [ -z "$seq" ] || FM_HOME="$case_dir/home" FM_STATE_OVERRIDE="$case_dir/state" \
    "$ROOT/bin/fm-wake-drain.sh" --ack-through "$seq" --recovery-generation "$generation" >/dev/null
  set +e
  FM_HOME="$case_dir/home" run_teardown "$case_dir" > "$case_dir/stdout2" 2> "$case_dir/stderr2"
  rc=$?
  set -e
  expect_code 0 "$rc" "mate-teardown-refuses: rerun after repair should succeed: $(cat "$case_dir/stderr2")"
  sed -E 's/ \[at=[0-9]+\]//' "$channel" | grep -Eq '^done \[key=child-outcome-task-x1-done-[0-9a-f]{8}\]: child task-x1 done: PR https://github.com/example/repo/pull/9 checks green' \
    || fail "mate-teardown-refuses: the rerun did not deliver the final line"
  [ ! -e "$case_dir/state/task-x1.meta" ] || fail "mate-teardown-refuses: rerun left the task record"
  pass "a secondmate home's teardown delivers the child's final line or refuses until it can"
}

test_teardown_missing_busy_sidecar_completes() {
  local case_dir gen rc
  case_dir=$(make_case missing-busy-sidecar)
  write_meta "$case_dir" local-only ship
  gen=$("$ROOT/bin/fm-busy-event.sh" arm "$case_dir/state" task-x1)
  printf 'busy_gen=%s\n' "$gen" >> "$case_dir/state/task-x1.meta"
  rm -f "$case_dir/state/task-x1.busy-gen"

  set +e
  run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr"
  rc=$?
  set -e

  expect_code 0 "$rc" "missing-busy-sidecar: teardown should treat the incarnation as already retired"
  assert_absent "$case_dir/state/task-x1.busy-state" \
    "missing-busy-sidecar: teardown left the orphan busy record"
  assert_absent "$case_dir/state/task-x1.meta" \
    "missing-busy-sidecar: teardown remained incomplete"
  pass "teardown completes when an exact busy-state sidecar is already absent"
}

test_herdr_teardown_clears_escalation_marker() {
  local case_dir marker
  case_dir=$(make_case herdr-marker-cleanup)
  write_meta "$case_dir" local-only ship
  sed -i.bak 's/^window=.*/window=default:wG:pQ/' "$case_dir/state/task-x1.meta"
  rm -f "$case_dir/state/task-x1.meta.bak"
  printf '%s\n' \
    'backend=herdr' \
    'herdr_session=default' \
    'herdr_workspace_id=wG' \
    'herdr_tab_id=wG:tQ' \
    'herdr_pane_id=wG:pQ' >> "$case_dir/state/task-x1.meta"
  # A reachable session whose exact pane is already structurally gone: the
  # locked close is a no-op and the record gate sees a confirmed-gone pane.
  cat > "$case_dir/fakebin/herdr" <<SH
#!/usr/bin/env bash
case "\${1:-} \${2:-}" in
  "session list") printf '%s\n' '{"sessions":[{"name":"default","running":true,"socket_path":"$case_dir/herdr.sock"}]}' ;;
  "status --json") printf '%s\n' '{"server":{"running":true}}' ;;
  "pane get") printf '%s\n' '{"error":{"code":"pane_not_found"}}'; exit 1 ;;
  *) exit 0 ;;
esac
SH
  chmod +x "$case_dir/fakebin/herdr"
  marker="$case_dir/state/.herdr-escalated-default_wG_pQ"
  : > "$marker"

  run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "herdr-marker-cleanup: forced teardown failed: $(cat "$case_dir/stderr")"
  [ ! -e "$marker" ] || fail "herdr-marker-cleanup: teardown left the pane's escalation marker behind"
  pass "herdr teardown removes pane-owned escalation dedupe state"
}

# Flat (non-projected) Herdr endpoint whose fake pane exists until a locked
# close removes it. The socket path is case-local so the derived presentation
# lock never collides with another test or a real fleet session.
configure_flat_herdr_teardown_case() {  # <case-dir>
  local case_dir=$1
  sed -i.bak 's/^window=.*/window=default:wG:pQ/' "$case_dir/state/task-x1.meta"
  rm -f "$case_dir/state/task-x1.meta.bak"
  printf '%s\n' \
    'backend=herdr' \
    'herdr_session=default' \
    'herdr_workspace_id=wG' \
    'herdr_tab_id=wG:tQ' \
    'herdr_pane_id=wG:pQ' >> "$case_dir/state/task-x1.meta"
  cat > "$case_dir/fakebin/herdr" <<SH
#!/usr/bin/env bash
set -u
printf '%s\n' "\$*" >> "\${FM_FAKE_HERDR_LOG:?}"
case "\${1:-} \${2:-}" in
  "workspace list")
    printf '%s\n' '{"result":{"workspaces":[{"workspace_id":"wH","active_tab_id":"wH:t1","focused":true},{"workspace_id":"wG","active_tab_id":"wG:tQ","focused":false}]}}'
    ;;
  "tab list")
    case "\$*" in
      *"--workspace wH"*) printf '%s\n' '{"result":{"tabs":[{"tab_id":"wH:t1","focused":true}]}}' ;;
      *"--workspace wG"*) printf '%s\n' '{"result":{"tabs":[{"tab_id":"wG:tQ","workspace_id":"wG"}]}}' ;;
      *) printf '%s\n' '{"result":{"tabs":[]}}' ;;
    esac
    ;;
  "pane list")
    printf '%s\n' '{"result":{"panes":[{"pane_id":"wG:pQ","tab_id":"wG:tQ"}]}}'
    ;;
  "status --json")
    printf '%s\n' '{"server":{"running":true}}'
    ;;
  "session list")
    if [ "\${FM_FAKE_HERDR_SESSION_LIST_GARBAGE:-0}" = 1 ]; then
      printf '%s\n' 'not-json'
    else
      printf '%s\n' '{"sessions":[{"name":"default","running":true,"socket_path":"$case_dir/herdr.sock"}]}'
    fi
    ;;
  "pane close")
    [ "\${FM_FAKE_HERDR_CLOSE_REFUSE:-0}" != 1 ] || exit 1
    : > "\${FM_FAKE_HERDR_CLOSED:?}"
    ;;
  "pane get")
    if [ "\${FM_FAKE_HERDR_PANE_GET_GARBAGE:-0}" = 1 ]; then
      printf '%s\n' 'not-json'
      exit 0
    fi
    if [ -e "\${FM_FAKE_HERDR_CLOSED:?}" ]; then
      printf '%s\n' '{"error":{"code":"pane_not_found"}}' >&2
      exit 1
    fi
    printf '%s\n' '{"result":{"pane":{"pane_id":"wG:pQ","tab_id":"wG:tQ","workspace_id":"wG"}}}'
    ;;
  "agent get")
    printf '%s\n' '{"error":{"code":"agent_not_found"}}' >&2
    exit 1
    ;;
esac
SH
  chmod +x "$case_dir/fakebin/herdr"
}

test_herdr_flat_teardown_refuses_orphaning_records_then_retry_completes() {
  local case_dir log closed lock ready release holder_pid rc thlog
  case_dir=$(make_case herdr-orphan-refusal)
  write_meta "$case_dir" local-only ship
  configure_flat_herdr_teardown_case "$case_dir"
  log="$case_dir/herdr.log"; : > "$log"
  closed="$case_dir/closed"
  : > "$case_dir/state/task-x1.status"
  : > "$case_dir/state/task-x1.turn-ended"
  # Record every treehouse invocation: the contended-lock refusal must fire
  # BEFORE the isolated copy is returned, so phase 1 may not invoke it at all.
  thlog="$case_dir/treehouse.log"; : > "$thlog"
  cat > "$case_dir/fakebin/treehouse" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$thlog"
exit 0
SH
  chmod +x "$case_dir/fakebin/treehouse"

  lock=$(FM_FAKE_HERDR_LOG="$log" FM_FAKE_HERDR_CLOSED="$closed" PATH="$case_dir/fakebin:$PATH" \
    bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_presentation_session_lock_path default' "$ROOT") \
    || fail "herdr-orphan-refusal: could not resolve the fixture presentation lock path"
  ready="$case_dir/lock-ready"; release="$case_dir/lock-release"
  ROOT="$ROOT" LOCK="$lock" READY="$ready" RELEASE="$release" bash -c '
    . "$ROOT/bin/fm-wake-lib.sh"
    fm_lock_try_acquire "$LOCK" || exit 1
    : > "$READY"
    while [ ! -e "$RELEASE" ]; do sleep 0.1; done
    fm_lock_release "$LOCK"
  ' &
  holder_pid=$!
  local waited=0
  while [ ! -e "$ready" ] && [ "$waited" -lt 50 ]; do sleep 0.1; waited=$((waited + 1)); done
  [ -e "$ready" ] || fail "herdr-orphan-refusal: the contending lock holder never started"

  rc=0
  FM_FAKE_HERDR_LOG="$log" FM_FAKE_HERDR_CLOSED="$closed" \
    run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  if [ "$rc" -eq 0 ]; then
    : > "$release"; wait "$holder_pid" 2>/dev/null || true
    fail "herdr-orphan-refusal: teardown reported success while the exact pane still existed under lock contention"
  fi
  [ -e "$case_dir/state/task-x1.meta" ] || { : > "$release"; fail "herdr-orphan-refusal: refusal erased the durable endpoint metadata"; }
  [ -e "$case_dir/state/task-x1.status" ] || { : > "$release"; fail "herdr-orphan-refusal: refusal erased the task status record"; }
  [ -e "$case_dir/state/task-x1.turn-ended" ] || { : > "$release"; fail "herdr-orphan-refusal: refusal erased the turn-end record"; }
  assert_grep "presentation lock is contended" "$case_dir/stderr" \
    "herdr-orphan-refusal: the pre-return refusal was not explained visibly"
  if [ -s "$thlog" ]; then
    : > "$release"; fail "herdr-orphan-refusal: the contended refusal still returned the isolated copy: $(cat "$thlog")"
  fi
  [ -d "$case_dir/wt" ] || { : > "$release"; fail "herdr-orphan-refusal: the contended refusal removed the isolated copy"; }
  if [ "$(git -C "$case_dir/wt" rev-parse --abbrev-ref HEAD 2>/dev/null)" != "fm/task-x1" ]; then
    : > "$release"; fail "herdr-orphan-refusal: the contended refusal dropped the task branch before refusing"
  fi
  if grep -q "teardown task-x1 complete" "$case_dir/stdout"; then
    : > "$release"; fail "herdr-orphan-refusal: refusal still reported cleanup complete"
  fi
  if grep -q "^pane close" "$log"; then
    : > "$release"; fail "herdr-orphan-refusal: an unlocked pane close was attempted under contention"
  fi

  : > "$release"
  wait "$holder_pid" 2>/dev/null || true
  FM_FAKE_HERDR_LOG="$log" FM_FAKE_HERDR_CLOSED="$closed" FM_BACKEND_HERDR_IDLE_SHELL_PROOF_POLLS=1 \
    run_teardown "$case_dir" --force > "$case_dir/stdout2" 2> "$case_dir/stderr2" \
    || fail "herdr-orphan-refusal: the retry after lock release failed: $(cat "$case_dir/stderr2")"
  [ -e "$closed" ] || fail "herdr-orphan-refusal: the retry never closed the pane under the lock"
  [ -s "$thlog" ] || fail "herdr-orphan-refusal: the successful retry never returned the isolated copy"
  [ ! -e "$case_dir/state/task-x1.meta" ] || fail "herdr-orphan-refusal: the successful retry left the metadata behind"
  [ ! -e "$case_dir/state/task-x1.status" ] || fail "herdr-orphan-refusal: the successful retry left the status record behind"
  grep -q "teardown task-x1 complete" "$case_dir/stdout2" \
    || fail "herdr-orphan-refusal: the successful retry did not report completion"
  pass "herdr flat teardown refuses before returning the isolated copy under lock contention and the retry completes cleanly"
}

test_herdr_close_precedes_reap_and_return() {
  local case_dir log closed rc
  case_dir=$(make_case herdr-close-before-reap)
  write_meta "$case_dir" local-only ship
  configure_flat_herdr_teardown_case "$case_dir"
  log="$case_dir/herdr.log"; : > "$log"
  closed="$case_dir/closed"
  # Observe the production cwd-rooted reap interface, not source ordering.
  # Returning no matching PIDs is safe; an attempted scan before confirmed
  # endpoint closure fails and records the exact regression.
  cat > "$case_dir/fakebin/lsof" <<SH
#!/usr/bin/env bash
case "\$*" in
  '-a -d cwd -Fpn')
    printf '%s\n' reap >> "$case_dir/lifecycle.log"
    [ -e "$closed" ] || { : > "$case_dir/reap-before-close"; exit 1; }
    ;;
esac
exit 0
SH
  cat > "$case_dir/fakebin/treehouse" <<SH
#!/usr/bin/env bash
printf '%s\n' return >> "$case_dir/lifecycle.log"
[ -e "$closed" ] || exit 1
[ ! -e "$case_dir/reap-before-close" ] || exit 1
exit 0
SH
  chmod +x "$case_dir/fakebin/lsof" "$case_dir/fakebin/treehouse"
  cp "$case_dir/state/task-x1.meta" "$case_dir/meta.before"
  rc=0
  FM_FAKE_HERDR_LOG="$log" FM_FAKE_HERDR_CLOSED="$closed" FM_FAKE_HERDR_CLOSE_REFUSE=1 \
    FM_BACKEND_HERDR_IDLE_SHELL_PROOF_POLLS=1 \
    run_teardown "$case_dir" --force > "$case_dir/refused.out" 2> "$case_dir/refused.err" || rc=$?
  [ "$rc" -ne 0 ] || fail "herdr-close-before-reap: refused endpoint close still completed cleanup"
  assert_grep 'not confirmed gone' "$case_dir/refused.err" \
    "herdr-close-before-reap: refusal did not explain the retained endpoint"
  cmp -s "$case_dir/meta.before" "$case_dir/state/task-x1.meta" \
    || fail "herdr-close-before-reap: failed close changed endpoint metadata"
  [ -d "$case_dir/wt" ] || fail "herdr-close-before-reap: failed close removed the copy"
  [ "$(git -C "$case_dir/wt" rev-parse --abbrev-ref HEAD)" = fm/task-x1 ] \
    || fail "herdr-close-before-reap: failed close dropped the branch"
  [ ! -e "$case_dir/lifecycle.log" ] \
    || fail "herdr-close-before-reap: refused close reached reap or native return"

  FM_FAKE_HERDR_LOG="$log" FM_FAKE_HERDR_CLOSED="$closed" FM_BACKEND_HERDR_IDLE_SHELL_PROOF_POLLS=1 \
    run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "herdr-close-before-reap: retry failed: $(cat "$case_dir/stderr")"
  [ -e "$closed" ] && [ ! -e "$case_dir/reap-before-close" ] \
    || fail "herdr-close-before-reap: cleanup reached reap before exact endpoint closure"
  awk 'NR == 1 && $0 != "reap" { bad=1 } $0 == "return" { returned=1 } END { exit(bad || !returned) }' \
    "$case_dir/lifecycle.log" || fail "herdr-close-before-reap: missing reap-before-return sequence"
  assert_absent "$case_dir/state/task-x1.meta" "herdr-close-before-reap: successful cleanup retained metadata"
  pass "herdr closes the exact endpoint before cwd-rooted reap/return; a refused close preserves the copy and records"
}

test_herdr_flat_teardown_refuses_records_on_unparseable_presence() {
  local case_dir log closed rc
  case_dir=$(make_case herdr-garbage-presence)
  write_meta "$case_dir" local-only ship
  configure_flat_herdr_teardown_case "$case_dir"
  log="$case_dir/herdr.log"; : > "$log"
  closed="$case_dir/closed"
  : > "$case_dir/state/task-x1.status"
  rc=0
  FM_FAKE_HERDR_LOG="$log" FM_FAKE_HERDR_CLOSED="$closed" FM_FAKE_HERDR_PANE_GET_GARBAGE=1 \
    FM_BACKEND_HERDR_IDLE_SHELL_PROOF_POLLS=1 \
    run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  [ "$rc" -ne 0 ] \
    || fail "herdr-garbage-presence: teardown erased records on an unparseable pane presence"
  [ -e "$case_dir/state/task-x1.meta" ] \
    || fail "herdr-garbage-presence: ambiguous presence erased the durable endpoint metadata"
  [ -e "$case_dir/state/task-x1.status" ] \
    || fail "herdr-garbage-presence: ambiguous presence erased the task status record"
  assert_grep "ambiguous structured presence" "$case_dir/stderr" \
    "herdr-garbage-presence: the ambiguity refusal was not explained visibly"
  pass "herdr flat teardown never erases records when pane presence is unparseable"
}

assert_herdr_teardown_preflight_refuses_before_changes() {
  local mode=$1 case_dir log closed rc thlog teardown_bin
  case_dir=$(make_case "herdr-preflight-$mode")
  write_meta "$case_dir" local-only ship
  configure_flat_herdr_teardown_case "$case_dir"
  log="$case_dir/herdr.log"; : > "$log"
  closed="$case_dir/closed"
  : > "$case_dir/state/task-x1.status"
  : > "$case_dir/state/task-x1.turn-ended"
  thlog="$case_dir/treehouse.log"; : > "$thlog"
  cat > "$case_dir/fakebin/treehouse" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$thlog"
exit 0
SH
  chmod +x "$case_dir/fakebin/treehouse"

  teardown_bin=$TEARDOWN
  case "$mode" in
    missing-adapter|missing-parser|missing-explicit-close-helper)
      mkdir -p "$case_dir/test-root"
      cp -R "$ROOT/bin" "$case_dir/test-root/bin"
      if [ "$mode" = missing-adapter ]; then
        rm -f "$case_dir/test-root/bin/backends/herdr.sh"
      elif [ "$mode" = missing-explicit-close-helper ]; then
        sed -i.bak 's/^fm_backend_herdr_explicit_close_pane_confirmed()/fm_backend_herdr_explicit_close_pane_confirmed_unavailable()/' \
          "$case_dir/test-root/bin/backends/herdr.sh"
        rm -f "$case_dir/test-root/bin/backends/herdr.sh.bak"
      else
        sed -i.bak 's/^fm_backend_herdr_parse_target()/fm_backend_herdr_parse_target_unavailable()/' \
          "$case_dir/test-root/bin/backends/herdr.sh"
        rm -f "$case_dir/test-root/bin/backends/herdr.sh.bak"
      fi
      teardown_bin="$case_dir/test-root/bin/fm-teardown.sh"
      ;;
  esac
  rc=0
  FM_TEARDOWN_GUARD_DONE=1 FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$case_dir/state" FM_DATA_OVERRIDE="$case_dir/data" \
    FM_CONFIG_OVERRIDE="$case_dir/config" FM_FAKE_HERDR_LOG="$log" FM_FAKE_HERDR_CLOSED="$closed" \
    FM_FAKE_HERDR_SESSION_LIST_GARBAGE="$([ "$mode" = unresolvable-lock ] && printf 1 || printf 0)" \
    PATH="$case_dir/fakebin:$PATH" \
    "$teardown_bin" task-x1 --force > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  [ "$rc" -ne 0 ] || fail "herdr-preflight-$mode: teardown continued without its required preflight"
  assert_grep "nothing was changed" "$case_dir/stderr" \
    "herdr-preflight-$mode: the retryable pre-return refusal was not explained visibly"
  [ -d "$case_dir/wt" ] || fail "herdr-preflight-$mode: refusal removed the isolated copy"
  [ "$(git -C "$case_dir/wt" rev-parse --abbrev-ref HEAD 2>/dev/null)" = "fm/task-x1" ] \
    || fail "herdr-preflight-$mode: refusal dropped the task branch"
  [ -e "$case_dir/state/task-x1.meta" ] \
    || fail "herdr-preflight-$mode: refusal erased the durable endpoint metadata"
  [ -e "$case_dir/state/task-x1.status" ] \
    || fail "herdr-preflight-$mode: refusal erased the task status record"
  [ -e "$case_dir/state/task-x1.turn-ended" ] \
    || fail "herdr-preflight-$mode: refusal erased the turn-end record"
  [ ! -s "$thlog" ] || fail "herdr-preflight-$mode: refusal returned the isolated copy"
  [ ! -e "$closed" ] || fail "herdr-preflight-$mode: refusal attempted an unlocked pane close"
}

test_herdr_flat_teardown_preflight_refuses_before_changes() {
  assert_herdr_teardown_preflight_refuses_before_changes unresolvable-lock
  assert_herdr_teardown_preflight_refuses_before_changes missing-adapter
  assert_herdr_teardown_preflight_refuses_before_changes missing-parser
  assert_herdr_teardown_preflight_refuses_before_changes missing-explicit-close-helper
  pass "herdr flat teardown preflight refuses before every destructive change"
}

# The Herdr presentation-lock namespace is named per OS account. These cases
# act as a fixture account uid (via an `id -u` shim) so they never touch the
# real account's namespace or the old shared /tmp/firstmate-herdr-presentation,
# and every directory the fixture account resolves is really owned by the
# running account, i.e. by another uid from the fixture account's view.
# FM_FAKE_NS_STAT names one path whose owner and mode the `stat` shim reports
# instead; the adapter reads ownership through a PATH `stat` only on its non-
# Darwin branch, so the arms that need it run only there.
herdr_lock_ns_fake_uid() {
  printf '%s' "$((3000000000 + $$ % 1000000))"
}

configure_herdr_lock_ns_shims() {  # <case-dir>
  local case_dir=$1 real_id real_stat
  real_id=$(command -v id); real_stat=$(command -v stat)
  cat > "$case_dir/fakebin/id" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = -u ] && [ "\$#" -eq 1 ] && [ -n "\${FM_FAKE_ACCOUNT_UID:-}" ]; then
  printf '%s\n' "\$FM_FAKE_ACCOUNT_UID"
  exit 0
fi
exec "$real_id" "\$@"
SH
  cat > "$case_dir/fakebin/stat" <<SH
#!/usr/bin/env bash
if [ "\$#" -eq 3 ] && [ "\$1" = -c ] && [ -n "\${FM_FAKE_NS_STAT:-}" ] \\
  && [ "\$3" = "\${FM_FAKE_NS_STAT%%:*}" ]; then
  rest=\${FM_FAKE_NS_STAT#*:}
  case "\$2" in
    %u) printf '%s\n' "\${rest%%:*}"; exit 0 ;;
    %a) printf '%s\n' "\${rest#*:}"; exit 0 ;;
  esac
fi
exec "$real_stat" "\$@"
SH
  chmod +x "$case_dir/fakebin/id" "$case_dir/fakebin/stat"
}

herdr_lock_ns_path_state() {  # <path>
  if [ -e "$1" ] || [ -L "$1" ]; then
    # A fixed, known path: ls is the portable way to read mode and numeric owner.
    # shellcheck disable=SC2012
    ls -ldn "$1" 2>/dev/null | awk '{print $1, $3, $4}'
  else
    printf 'absent'
  fi
}

run_herdr_lock_ns_teardown() {  # <case-dir> <fake-uid> [stat-spec]
  local case_dir=$1 fake_uid=$2 stat_spec=${3:-} rc=0
  FM_FAKE_ACCOUNT_UID="$fake_uid" FM_FAKE_NS_STAT="$stat_spec" \
    FM_FAKE_HERDR_LOG="$case_dir/herdr.log" FM_FAKE_HERDR_CLOSED="$case_dir/closed" \
    FM_BACKEND_HERDR_IDLE_SHELL_PROOF_POLLS=1 \
    run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  return "$rc"
}

new_herdr_lock_ns_case() {  # <name>
  local case_dir
  case_dir=$(make_case "$1")
  write_meta "$case_dir" local-only ship
  configure_flat_herdr_teardown_case "$case_dir"
  configure_herdr_lock_ns_shims "$case_dir"
  : > "$case_dir/herdr.log"
  : > "$case_dir/state/task-x1.status"
  printf '%s' "$case_dir"
}

assert_herdr_lock_ns_refused() {  # <case-dir> <label>
  local case_dir=$1 label=$2
  assert_grep "presentation lock could not be resolved" "$case_dir/stderr" \
    "$label: the namespace refusal was not explained visibly"
  [ -e "$case_dir/state/task-x1.meta" ] || fail "$label: refusal erased the durable endpoint metadata"
  [ -d "$case_dir/wt" ] || fail "$label: refusal removed the isolated copy"
  [ ! -e "$case_dir/closed" ] || fail "$label: refusal attempted a pane close without the lock"
}

test_herdr_teardown_presentation_lock_namespace_is_per_account() {
  local fake_uid own_ns legacy legacy_before legacy_after own_before case_dir rc lock linux_arms=0
  fake_uid=$(herdr_lock_ns_fake_uid)
  [ "$fake_uid" != "$(id -u)" ] || fail "herdr-lock-ns: fixture account uid collides with the running account"
  own_ns="/tmp/firstmate-herdr-presentation-$fake_uid"
  legacy=/tmp/firstmate-herdr-presentation
  [ ! -e "$own_ns" ] && [ ! -L "$own_ns" ] \
    || fail "herdr-lock-ns: fixture namespace $own_ns already exists; refusing to reuse it"
  printf '%s\n' "$own_ns" >> "$FM_TEST_CLEANUP_REGISTRY"
  mkdir -m 700 "$own_ns" || fail "herdr-lock-ns: could not stage $own_ns"
  legacy_before=$(herdr_lock_ns_path_state "$legacy")

  # This account's own name, really owned by another uid, is still refused and
  # is left exactly as it was.
  own_before=$(herdr_lock_ns_path_state "$own_ns")
  case_dir=$(new_herdr_lock_ns_case herdr-lock-ns-foreign-owner)
  rc=0; run_herdr_lock_ns_teardown "$case_dir" "$fake_uid" || rc=$?
  [ "$rc" -ne 0 ] || fail "herdr-lock-ns-foreign-owner: teardown adopted a namespace another uid owns"
  assert_herdr_lock_ns_refused "$case_dir" herdr-lock-ns-foreign-owner
  [ "$(herdr_lock_ns_path_state "$own_ns")" = "$own_before" ] \
    || fail "herdr-lock-ns-foreign-owner: refusal changed the foreign-owned namespace: $(herdr_lock_ns_path_state "$own_ns")"

  if [ "$(uname -s)" != Darwin ]; then
    linux_arms=1
    # The old shared name is owned by another uid whenever it exists here, as
    # on a host where a second account created it first; this account's
    # teardown no longer consults it and completes in its own namespace.
    case_dir=$(new_herdr_lock_ns_case herdr-lock-ns-other-account)
    run_herdr_lock_ns_teardown "$case_dir" "$fake_uid" "$own_ns:$fake_uid:700" \
      || fail "herdr-lock-ns-other-account: teardown was blocked: $(cat "$case_dir/stderr")"
    [ -e "$case_dir/closed" ] || fail "herdr-lock-ns-other-account: the pane was not closed under the lock"
    [ ! -e "$case_dir/state/task-x1.meta" ] || fail "herdr-lock-ns-other-account: teardown left the metadata behind"
    grep -q "teardown task-x1 complete" "$case_dir/stdout" \
      || fail "herdr-lock-ns-other-account: teardown did not report completion"
    lock=$(FM_FAKE_ACCOUNT_UID="$fake_uid" FM_FAKE_NS_STAT="$own_ns:$fake_uid:700" \
      FM_FAKE_HERDR_LOG="$case_dir/herdr.log" FM_FAKE_HERDR_CLOSED="$case_dir/closed" \
      PATH="$case_dir/fakebin:$PATH" \
      bash -c '. "$0/bin/backends/herdr.sh"; fm_backend_herdr_presentation_session_lock_path default' "$ROOT") \
      || fail "herdr-lock-ns-other-account: could not resolve the fixture account's lock path"
    case "$lock" in
      "$own_ns"/order-*.lock) ;;
      *) fail "herdr-lock-ns-other-account: the lock is not in this account's namespace: $lock" ;;
    esac

    # This account's own name with the right owner but the wrong mode is refused.
    case_dir=$(new_herdr_lock_ns_case herdr-lock-ns-wrong-mode)
    rc=0; run_herdr_lock_ns_teardown "$case_dir" "$fake_uid" "$own_ns:$fake_uid:755" || rc=$?
    [ "$rc" -ne 0 ] || fail "herdr-lock-ns-wrong-mode: teardown adopted a namespace that is not mode 700"
    assert_herdr_lock_ns_refused "$case_dir" herdr-lock-ns-wrong-mode
    [ -d "$own_ns" ] || fail "herdr-lock-ns-wrong-mode: refusal removed the namespace"
  fi

  legacy_after=$(herdr_lock_ns_path_state "$legacy")
  [ "$legacy_after" = "$legacy_before" ] \
    || fail "herdr-lock-ns: teardown changed the old shared namespace: $legacy_before -> $legacy_after"
  rm -rf "$own_ns"
  if [ "$linux_arms" = 1 ]; then
    pass "herdr teardown takes its lock in a per-account namespace another account cannot block, and still refuses a foreign-owned or wrong-mode one"
  else
    pass "herdr teardown refuses a foreign-owned per-account namespace (owner-shim arms need the non-Darwin stat branch; skipped on Darwin)"
  fi
}

configure_secondmate_with_herdr_child() {  # <case-dir>
  local case_dir=$1 home="$1/secondmate-home"
  mkdir -p "$home/state" "$home/data" "$home/config" "$home/projects"
  printf '%s\n' task-x1 > "$home/.fm-secondmate-home"
  printf '%s\n' "home=$home" >> "$case_dir/state/task-x1.meta"
  fm_write_meta "$home/state/child-herdr.meta" \
    "window=childsession:wC:p1" \
    "endpoint_task_id=child-herdr" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    "kind=ship" \
    "mode=local-only" \
    "backend=herdr" \
    "herdr_session=childsession" \
    "herdr_workspace_id=wC" \
    "herdr_tab_id=wC:t1" \
    "herdr_pane_id=wC:p1"
  : > "$home/state/child-herdr.status"
  : > "$home/state/child-herdr.turn-ended"
  cat > "$case_dir/fakebin/herdr" <<SH
#!/usr/bin/env bash
set -u
printf '%s\n' "\$*" >> "\${FM_FAKE_HERDR_LOG:?}"
case "\${1:-} \${2:-}" in
  "session list")
    if [ "\${FM_FAKE_HERDR_SESSION_LIST_GARBAGE:-0}" = 1 ]; then
      printf '%s\n' 'not-json'
    else
      printf '%s\n' '{"sessions":[{"name":"childsession","running":true,"socket_path":"$case_dir/child.sock"}]}'
    fi
    ;;
  "workspace list") exit 1 ;;
  "pane get")
    if [ -e "\${FM_FAKE_HERDR_CLOSED:?}" ]; then
      if [ "\${FM_FAKE_HERDR_PRESENCE_UNKNOWN:-0}" = 1 ]; then
        printf '%s\n' 'not-json'
      else
        printf '%s\n' '{"error":{"code":"pane_not_found"}}' >&2
        exit 1
      fi
    else
      printf '%s\n' '{"result":{"pane":{"pane_id":"wC:p1","tab_id":"wC:t1","workspace_id":"wC"}}}'
    fi
    ;;
  "pane close") : > "\${FM_FAKE_HERDR_CLOSED:?}" ;;
esac
SH
  chmod +x "$case_dir/fakebin/herdr"
}

test_forced_secondmate_herdr_child_preflight_refuses_before_changes() {
  local case_dir home log closed rc thlog
  case_dir=$(make_case herdr-child-preflight)
  write_meta "$case_dir" local-only secondmate
  configure_secondmate_with_herdr_child "$case_dir"
  home="$case_dir/secondmate-home"
  log="$case_dir/herdr.log"; closed="$case_dir/closed"; thlog="$case_dir/treehouse.log"
  : > "$log"; : > "$thlog"
  cat > "$case_dir/fakebin/treehouse" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$thlog"
exit 0
SH
  chmod +x "$case_dir/fakebin/treehouse"
  rc=0
  FM_FAKE_HERDR_LOG="$log" FM_FAKE_HERDR_CLOSED="$closed" \
    FM_FAKE_HERDR_SESSION_LIST_GARBAGE=1 \
    run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  [ "$rc" -ne 0 ] || fail "herdr-child-preflight: teardown continued through an unresolvable child lock"
  [ -e "$case_dir/state/task-x1.meta" ] || fail "herdr-child-preflight: refusal erased the parent record"
  [ -e "$home/state/child-herdr.meta" ] || fail "herdr-child-preflight: refusal erased the child record"
  [ -e "$home/state/child-herdr.status" ] || fail "herdr-child-preflight: refusal erased child status"
  [ -d "$home" ] || fail "herdr-child-preflight: refusal removed the secondmate home"
  [ ! -s "$thlog" ] || fail "herdr-child-preflight: refusal returned work before child preflight"
  [ ! -e "$closed" ] || fail "herdr-child-preflight: refusal attempted a child close"
  assert_grep "nothing was changed" "$case_dir/stderr" \
    "herdr-child-preflight: refusal did not explain its non-mutating boundary"
  pass "forced secondmate teardown preflights every Herdr child before cleanup mutation"
}

configure_secondmate_with_tmux_children() {  # <case-dir>
  local case_dir=$1 home="$1/secondmate-home" child child_wt
  mkdir -p "$home/state" "$home/data" "$home/config" "$home/projects"
  printf '%s\n' task-x1 > "$home/.fm-secondmate-home"
  printf '%s\n' "home=$home" >> "$case_dir/state/task-x1.meta"
  for child in child-a child-b; do
    child_wt="$case_dir/$child-wt"
    git -C "$case_dir/project" worktree add -q -b "fm/$child" "$child_wt" main
    fm_write_meta "$home/state/$child.meta" \
      "window=firstmate:fm-$child" \
      "endpoint_task_id=$child" \
      "worktree=$child_wt" \
      "project=$case_dir/project" \
      "kind=ship" \
      "mode=local-only"
    : > "$home/state/$child.status"
  done
}

test_forced_secondmate_teardown_holds_descendant_lifecycle_locks() {
  local case_dir home lock ready release holder_pid rc waited=0 child
  case_dir=$(make_case descendant-locks)
  write_meta "$case_dir" local-only secondmate
  configure_secondmate_with_tmux_children "$case_dir"
  home="$case_dir/secondmate-home"
  : > "$case_dir/kill.log"
  : > "$case_dir/treehouse.log"
  cat > "$case_dir/fakebin/tmux" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$case_dir/kill.log"
exit 0
SH
  cat > "$case_dir/fakebin/treehouse" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$case_dir/treehouse.log"
exit 0
SH
  chmod +x "$case_dir/fakebin/tmux" "$case_dir/fakebin/treehouse"

  lock="$home/state/.control-child-b.lock"
  ready="$case_dir/lock-ready"
  release="$case_dir/lock-release"
  ROOT="$ROOT" LOCK="$lock" READY="$ready" RELEASE="$release" \
    HOME_STATE="$home/state" OWNER_PID="$$" bash -c '
    export FM_STATE_OVERRIDE="$HOME_STATE"
    . "$ROOT/bin/fm-wake-lib.sh"
    fm_lock_try_acquire "$LOCK" || exit 1
    : > "$READY"
    while [ ! -e "$RELEASE" ] && kill -0 "$OWNER_PID" 2>/dev/null; do sleep 0.1; done
    fm_lock_release "$LOCK"
  ' &
  holder_pid=$!
  while [ ! -e "$ready" ] && [ "$waited" -lt 50 ]; do
    sleep 0.1
    waited=$((waited + 1))
  done
  [ -e "$ready" ] || fail "descendant-locks: the contending lifecycle action never acquired its lock"

  rc=0
  run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  if [ "$rc" -eq 0 ]; then
    : > "$release"
    wait "$holder_pid" 2>/dev/null || true
    fail "descendant-locks: forced teardown ignored a descendant lifecycle lock"
  fi
  assert_grep "descendant task child-b has a lifecycle action in flight" "$case_dir/stderr" \
    "descendant-locks: refusal did not name the contended descendant"
  [ ! -e "$home/state/.control-child-a.lock" ] \
    && [ ! -e "$home/state/.meta-child-a.lock" ] \
    || { : > "$release"; wait "$holder_pid" 2>/dev/null || true; fail "descendant-locks: refusal leaked earlier descendant locks"; }
  [ ! -s "$case_dir/kill.log" ] \
    || { : > "$release"; wait "$holder_pid" 2>/dev/null || true; fail "descendant-locks: refusal killed an endpoint"; }
  [ ! -s "$case_dir/treehouse.log" ] \
    || { : > "$release"; wait "$holder_pid" 2>/dev/null || true; fail "descendant-locks: refusal returned a worktree"; }
  [ -e "$case_dir/state/task-x1.meta" ] && [ -d "$home" ] \
    || { : > "$release"; wait "$holder_pid" 2>/dev/null || true; fail "descendant-locks: refusal removed parent state"; }
  for child in child-a child-b; do
    [ -e "$home/state/$child.meta" ] && [ -d "$case_dir/$child-wt" ] \
      || { : > "$release"; wait "$holder_pid" 2>/dev/null || true; fail "descendant-locks: refusal removed $child state or worktree"; }
  done

  : > "$release"
  wait "$holder_pid" 2>/dev/null || true
  rc=0
  run_teardown "$case_dir" --force > "$case_dir/retry.stdout" 2> "$case_dir/retry.stderr" || rc=$?
  expect_code 0 "$rc" "descendant-locks: uncontended retry should complete"
  [ ! -e "$case_dir/state/task-x1.meta" ] && [ ! -d "$home" ] \
    || fail "descendant-locks: uncontended retry retained retired task state"
  [ -s "$case_dir/kill.log" ] && [ -s "$case_dir/treehouse.log" ] \
    || fail "descendant-locks: uncontended retry did not perform endpoint and worktree cleanup"
  pass "forced secondmate teardown holds every descendant lifecycle and metadata lock"
}

test_forced_secondmate_herdr_child_retains_records_when_close_unconfirmed() {
  local case_dir home log closed rc
  case_dir=$(make_case herdr-child-unconfirmed-close)
  write_meta "$case_dir" local-only secondmate
  configure_secondmate_with_herdr_child "$case_dir"
  home="$case_dir/secondmate-home"
  log="$case_dir/herdr.log"; closed="$case_dir/closed"; : > "$log"
  rc=0
  FM_FAKE_HERDR_LOG="$log" FM_FAKE_HERDR_CLOSED="$closed" FM_FAKE_HERDR_PRESENCE_UNKNOWN=1 \
    run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  [ "$rc" -ne 0 ] || fail "herdr-child-unconfirmed-close: teardown erased records after an ambiguous close"
  [ -e "$closed" ] || fail "herdr-child-unconfirmed-close: fixture did not attempt the child close"
  [ -e "$home/state/child-herdr.meta" ] || fail "herdr-child-unconfirmed-close: ambiguous close erased child metadata"
  [ -e "$home/state/child-herdr.status" ] || fail "herdr-child-unconfirmed-close: ambiguous close erased child status"
  [ -e "$case_dir/state/task-x1.meta" ] || fail "herdr-child-unconfirmed-close: failed child cleanup erased parent metadata"
  [ -d "$home" ] || fail "herdr-child-unconfirmed-close: failed child cleanup removed the secondmate home"
  assert_grep "retaining that child's durable identity records" "$case_dir/stderr" \
    "herdr-child-unconfirmed-close: refusal did not explain child record retention"
  pass "forced secondmate teardown retains Herdr child identity until exact pane disappearance"
}

configure_nested_secondmate_with_herdr_grandchild() {  # <case-dir>
  local case_dir=$1 home="$1/secondmate-home" nested_home="$1/secondmate-home/nested-home"
  mkdir -p "$home/state" "$home/data" "$home/config" "$home/projects"
  mkdir -p "$nested_home/state" "$nested_home/data" "$nested_home/config" "$nested_home/projects"
  printf '%s\n' task-x1 > "$home/.fm-secondmate-home"
  printf '%s\n' nested-sm > "$nested_home/.fm-secondmate-home"
  printf '%s\n' "home=$home" >> "$case_dir/state/task-x1.meta"
  fm_write_meta "$home/state/nested-sm.meta" \
    "window=firstmate:fm-nested-sm" \
    "endpoint_task_id=nested-sm" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    "kind=secondmate" \
    "mode=local-only" \
    "home=$nested_home"
  fm_write_meta "$nested_home/state/grandchild-herdr.meta" \
    "window=grandchildsession:wG:p1" \
    "endpoint_task_id=grandchild-herdr" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    "kind=ship" \
    "mode=local-only" \
    "backend=herdr" \
    "herdr_session=grandchildsession" \
    "herdr_workspace_id=wG" \
    "herdr_tab_id=wG:t1" \
    "herdr_pane_id=wG:p1"
  : > "$nested_home/state/grandchild-herdr.status"
  : > "$nested_home/state/grandchild-herdr.turn-ended"
  cat > "$case_dir/fakebin/herdr" <<SH
#!/usr/bin/env bash
set -u
printf '%s\n' "\$*" >> "\${FM_FAKE_HERDR_LOG:?}"
case "\${1:-} \${2:-}" in
  "session list")
    printf '%s\n' '{"sessions":[{"name":"grandchildsession","running":true,"socket_path":"$case_dir/grandchild.sock"}]}'
    ;;
  "workspace list") exit 1 ;;
  "pane get")
    if [ -e "\${FM_FAKE_HERDR_CLOSED:?}" ]; then
      printf '%s\n' 'not-json'
    else
      printf '%s\n' '{"result":{"pane":{"pane_id":"wG:p1","tab_id":"wG:t1","workspace_id":"wG"}}}'
    fi
    ;;
  "pane close") : > "\${FM_FAKE_HERDR_CLOSED:?}" ;;
esac
SH
  chmod +x "$case_dir/fakebin/herdr"
}

test_forced_teardown_retains_nested_secondmate_home_when_grandchild_close_unconfirmed() {
  local case_dir home nested_home log closed rc
  case_dir=$(make_case herdr-grandchild-unconfirmed-close)
  write_meta "$case_dir" local-only secondmate
  configure_nested_secondmate_with_herdr_grandchild "$case_dir"
  home="$case_dir/secondmate-home"; nested_home="$home/nested-home"
  log="$case_dir/herdr.log"; closed="$case_dir/closed"; : > "$log"
  rc=0
  FM_FAKE_HERDR_LOG="$log" FM_FAKE_HERDR_CLOSED="$closed" \
    run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  [ "$rc" -ne 0 ] \
    || fail "herdr-grandchild-unconfirmed-close: teardown erased records after an ambiguous grandchild close"
  [ -e "$closed" ] \
    || fail "herdr-grandchild-unconfirmed-close: fixture did not attempt the grandchild close"
  [ -d "$nested_home" ] \
    || fail "herdr-grandchild-unconfirmed-close: the recursive failure still removed the nested secondmate home"
  [ -e "$nested_home/state/grandchild-herdr.meta" ] \
    || fail "herdr-grandchild-unconfirmed-close: ambiguous close erased the grandchild's metadata"
  [ -e "$nested_home/state/grandchild-herdr.status" ] \
    || fail "herdr-grandchild-unconfirmed-close: ambiguous close erased the grandchild's status record"
  [ -e "$home/state/nested-sm.meta" ] \
    || fail "herdr-grandchild-unconfirmed-close: the recursive failure erased the nested secondmate's own record"
  [ -e "$case_dir/state/task-x1.meta" ] \
    || fail "herdr-grandchild-unconfirmed-close: the recursive failure erased the top-level secondmate's record"
  pass "forced teardown retains a nested secondmate home and its grandchild's Herdr identity when the grandchild close is unconfirmed"
}

configure_herdr_projection_teardown_case() {  # <case-dir>
  local case_dir=$1 token=AbCdEfGhIjKlMnOpQrStUv
  sed -i.bak 's/^window=.*/window=fmtest:w1:p2/' "$case_dir/state/task-x1.meta"
  rm -f "$case_dir/state/task-x1.meta.bak"
  printf '%s\n' \
    'backend=herdr' \
    'herdr_session=fmtest' \
    'herdr_workspace_id=w1' \
    'herdr_tab_id=w1:t2' \
    'herdr_pane_id=w1:p2' >> "$case_dir/state/task-x1.meta"
  printf '%s\n' \
    'version=1' \
    'task_id=task-x1' \
    "projection_id=$token" > "$case_dir/state/task-x1.herdr-presentation"
  cat > "$case_dir/fakebin/herdr" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "${FM_FAKE_HERDR_LOG:?}"
case "${1:-} ${2:-}" in
  "workspace list")
    if [ -e "${FM_FAKE_HERDR_RESTORED:?}" ]; then
      printf '%s\n' '{"result":{"workspaces":[{"workspace_id":"w2","active_tab_id":"w2:t2","label":"2ndmate-bravo","focused":true},{"workspace_id":"w3","active_tab_id":"w3:t1","label":"2ndmate-alpha","focused":false}]}}'
    elif [ -e "${FM_FAKE_HERDR_CLOSED:?}" ]; then
      printf '%s\n' '{"result":{"workspaces":[{"workspace_id":"w2","active_tab_id":"w2:t2","label":"2ndmate-bravo","focused":false},{"workspace_id":"w3","active_tab_id":"w3:t1","label":"2ndmate-alpha","focused":true}]}}'
    else
      printf '%s\n' '{"result":{"workspaces":[{"workspace_id":"w1","active_tab_id":"w1:t2","label":"firstmate/task-x1 · p:AbCdEfGhIjKlMnOpQrStUv","focused":false},{"workspace_id":"w2","active_tab_id":"w2:t2","label":"2ndmate-bravo","focused":true},{"workspace_id":"w3","active_tab_id":"w3:t1","label":"2ndmate-alpha","focused":false}]}}'
    fi
    ;;
  "tab list")
    case "$*" in
      *"--workspace w2"*) printf '%s\n' '{"result":{"tabs":[{"tab_id":"w2:t2","focused":true}]}}' ;;
      *"--workspace w3"*) printf '%s\n' '{"result":{"tabs":[{"tab_id":"w3:t1","focused":true}]}}' ;;
      *) printf '%s\n' '{"result":{"tabs":[]}}' ;;
    esac
    ;;
  "status --json")
    printf '%s\n' '{"server":{"running":true}}'
    ;;
  "session list")
    # Session+socket defines the lock identity. Distinct fake cases must not
    # contend merely because they reuse the illustrative session name.
    jq -nc --arg socket "${FM_FAKE_HERDR_LOG%/*}/herdr.sock" \
      '{sessions:[{name:"fmtest",running:true,socket_path:$socket}]}'
    ;;
  "pane close")
    if [ "${FM_FAKE_HERDR_CLOSE_FAIL:-0}" = 1 ]; then
      exit 1
    fi
    : > "${FM_FAKE_HERDR_CLOSED:?}"
    ;;
  "pane get")
    if [ -e "${FM_FAKE_HERDR_CLOSED:?}" ]; then
      if [ "${FM_FAKE_HERDR_PRESENCE_UNKNOWN:-0}" = 1 ]; then
        printf '%s\n' '{"error":{"code":"internal"}}' >&2
        exit 1
      fi
      printf '%s\n' '{"error":{"code":"pane_not_found"}}' >&2
      exit 1
    fi
    printf '%s\n' '{"result":{"pane":{"pane_id":"w1:p2","tab_id":"w1:t2","workspace_id":"w1"}}}'
    ;;
  "tab get")
    printf '%s\n' '{"result":{"tab":{"tab_id":"w2:t2","workspace_id":"w2"}}}'
    ;;
  "tab focus")
    if [ "${FM_FAKE_HERDR_RESTORE_FAIL:-0}" = 1 ]; then
      exit 1
    fi
    : > "${FM_FAKE_HERDR_RESTORED:?}"
    printf '%s\n' '{"result":{"tab":{"tab_id":"w2:t2","workspace_id":"w2","focused":true}}}'
    ;;
  "agent get")
    printf '%s\n' '{"error":{"code":"agent_not_found"}}' >&2
    exit 1
    ;;
esac
SH
  chmod +x "$case_dir/fakebin/herdr"
}

test_herdr_projection_teardown_retires_journal_only_after_confirmed_close() {
  local case_dir log closed restored
  case_dir=$(make_case herdr-projection-confirmed-close)
  write_meta "$case_dir" local-only ship
  configure_herdr_projection_teardown_case "$case_dir"
  log="$case_dir/herdr.log"; closed="$case_dir/closed"; restored="$case_dir/restored"; : > "$log"

  FM_FAKE_HERDR_LOG="$log" FM_FAKE_HERDR_CLOSED="$closed" FM_FAKE_HERDR_RESTORED="$restored" \
    run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "herdr-projection-confirmed-close: forced teardown failed"
  [ ! -e "$case_dir/state/task-x1.herdr-presentation" ] \
    || fail "confirmed exact-pane close did not retire the presentation journal"
  assert_not_contains "$(cat "$log")" "workspace close" \
    "projected teardown must never call workspace close"
  assert_contains "$(cat "$log")" "tab focus w2:t2" \
    "projected teardown did not restore the exact pre-close active tab"
  pass "herdr projection teardown retires its journal only after confirming the exact recorded pane is gone"
}

test_herdr_projection_teardown_retains_journal_when_close_unconfirmed() {
  local case_dir log closed restored
  case_dir=$(make_case herdr-projection-unconfirmed-close)
  write_meta "$case_dir" local-only ship
  configure_herdr_projection_teardown_case "$case_dir"
  log="$case_dir/herdr.log"; closed="$case_dir/closed"; restored="$case_dir/restored"; : > "$log"
  cp "$case_dir/state/task-x1.meta" "$case_dir/meta.before"
  cp "$case_dir/state/task-x1.herdr-presentation" "$case_dir/journal.before"
  local head_before
  head_before=$(git -C "$case_dir/wt" rev-parse HEAD)
  cat > "$case_dir/fakebin/lsof" <<SH
#!/usr/bin/env bash
printf '%s\n' reap >> "$case_dir/lifecycle.log"
exit 0
SH
  cat > "$case_dir/fakebin/treehouse" <<SH
#!/usr/bin/env bash
printf '%s\n' return >> "$case_dir/lifecycle.log"
exit 0
SH
  chmod +x "$case_dir/fakebin/lsof" "$case_dir/fakebin/treehouse"

  local rc=0
  FM_FAKE_HERDR_LOG="$log" FM_FAKE_HERDR_CLOSED="$closed" FM_FAKE_HERDR_RESTORED="$restored" FM_FAKE_HERDR_PRESENCE_UNKNOWN=1 \
    run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  [ "$rc" -ne 0 ] \
    || fail "herdr-projection-unconfirmed-close: teardown reported success after an unknown post-close presence read"
  [ -e "$closed" ] \
    || fail "herdr-projection-unconfirmed-close: regression did not exercise an attempted close"
  [ -e "$case_dir/state/task-x1.herdr-presentation" ] \
    || fail "unconfirmed task-pane close incorrectly retired the presentation journal"
  [ -e "$case_dir/state/task-x1.meta" ] \
    || fail "unconfirmed task-pane close erased the durable endpoint metadata"
  if ! cmp -s "$case_dir/meta.before" "$case_dir/state/task-x1.meta" \
     || ! cmp -s "$case_dir/journal.before" "$case_dir/state/task-x1.herdr-presentation"; then
    fail "unconfirmed task-pane close changed its retained metadata or journal"
  fi
  [ -d "$case_dir/wt" ] \
    && [ "$(git -C "$case_dir/wt" rev-parse HEAD)" = "$head_before" ] \
    && [ "$(git -C "$case_dir/wt" branch --show-current)" = fm/task-x1 ] \
    || fail "unconfirmed task-pane close removed or reset its retained copy"
  [ ! -e "$case_dir/lifecycle.log" ] \
    || fail "unconfirmed task-pane close reached process reap or native return"
  assert_grep "close could not be confirmed" "$case_dir/stderr" \
    "unconfirmed projected close did not explain why the journal was retained"
  assert_grep "not confirmed gone" "$case_dir/stderr" \
    "unconfirmed projected close did not explain why the records were retained"
  assert_not_contains "$(cat "$log")" "workspace close" \
    "unconfirmed projected close must not escalate to workspace cleanup"
  pass "herdr projection teardown retains every record when post-close presence is unknown"
}

test_herdr_projection_teardown_surfaces_restore_failure_without_blocking_cleanup() {
  local case_dir log closed restored
  case_dir=$(make_case herdr-projection-restore-failure)
  write_meta "$case_dir" local-only ship
  configure_herdr_projection_teardown_case "$case_dir"
  log="$case_dir/herdr.log"; closed="$case_dir/closed"; restored="$case_dir/restored"; : > "$log"

  FM_FAKE_HERDR_LOG="$log" FM_FAKE_HERDR_CLOSED="$closed" FM_FAKE_HERDR_RESTORED="$restored" \
    FM_FAKE_HERDR_RESTORE_FAIL=1 \
    run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "herdr-projection-restore-failure: a confirmed close with a failed focus restore blocked teardown"
  [ -e "$closed" ] \
    || fail "herdr-projection-restore-failure: regression did not exercise the exact projected-pane close"
  [ ! -e "$case_dir/state/task-x1.herdr-presentation" ] \
    || fail "herdr-projection-restore-failure: confirmed closure did not retire the presentation journal"
  assert_grep "exact-tab restoration failed" "$case_dir/stderr" \
    "herdr-projection-restore-failure: teardown swallowed the focus helper's restore warning"
  pass "herdr projection teardown surfaces failed focus restoration without turning confirmed cleanup into a hard failure"
}

# Retire only this task's watcher markers. A v2 journal without a validated
# workspace correlation remains quarantined even when its bound pane is gone;
# the same shape arises after recovery delivery abort.
seed_watcher_markers() {  # <case-dir> <task-id>
  local state="$1/state" id=$2
  printf '0:0\n' > "$state/.seen-${id}_status"
  printf '0:0\n' > "$state/.seen-${id}_turn-ended"
  printf '0\n' > "$state/.hb-surfaced-$id"
}

test_teardown_retires_task_watcher_markers_but_quarantines_unmatched_journal() {
  local case_dir log closed restored marker
  case_dir=$(make_case retire-watcher-markers)
  write_meta "$case_dir" local-only ship
  configure_herdr_projection_teardown_case "$case_dir"
  log="$case_dir/herdr.log"; closed="$case_dir/closed"; restored="$case_dir/restored"; : > "$log"
  # The workspace and pane are gone, but no authoritative pre-close workspace
  # correlation exists. Gone-pane matching must not erase abort quarantine.
  # Override only this case's legacy v1 constructor: v1 token absence is an
  # independently preserved retirement path, not the v2 abort scenario.
  printf '%s\n' 'version=2' 'task_id=task-x1' 'projection_id=AbCdEfGhIjKlMnOpQrStUv' \
    "home=$case_dir" 'session=fmtest' 'workspace_id=w1' 'tab_id=w1:t2' 'pane_id=w1:p2' \
    'parent_workspace_id=w0' 'parent_label=firstmate' \
    'workspace_label=└ task-x1 · p:AbCdEfGhIjKlMnOpQrStUv' 'task_label=fm-task-x1' \
    > "$case_dir/state/task-x1.herdr-presentation"
  : > "$closed"
  cp "$case_dir/state/task-x1.herdr-presentation" "$case_dir/journal.before"
  seed_watcher_markers "$case_dir" task-x1
  seed_watcher_markers "$case_dir" task-y2
  seed_watcher_markers "$case_dir" task-x1_extra
  printf '%s\n' 'version=1' 'task_id=task-y2' 'projection_id=ZyXwVuTsRqPoNmLkJiHgFe' \
    > "$case_dir/state/task-y2.herdr-presentation"

  FM_FAKE_HERDR_LOG="$log" FM_FAKE_HERDR_CLOSED="$closed" FM_FAKE_HERDR_RESTORED="$restored" \
    run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "retire-watcher-markers: teardown failed: $(cat "$case_dir/stderr")"
  for marker in .seen-task-x1_status .seen-task-x1_turn-ended .hb-surfaced-task-x1; do
    assert_absent "$case_dir/state/$marker" "teardown left the torn-down task's $marker behind"
  done
  for marker in .seen-task-y2_status .seen-task-y2_turn-ended .hb-surfaced-task-y2 task-y2.herdr-presentation \
    .seen-task-x1_extra_status .seen-task-x1_extra_turn-ended .hb-surfaced-task-x1_extra; do
    assert_present "$case_dir/state/$marker" "teardown removed another task's $marker"
  done
  cmp -s "$case_dir/journal.before" "$case_dir/state/task-x1.herdr-presentation" \
    || fail "gone-pane matching erased or changed an uncorrelated v2 journal"
  assert_grep 'remains quarantined; no workspace cleanup was attempted' "$case_dir/stderr" \
    "teardown did not explain its abort-quarantine boundary"
  assert_not_contains "$(cat "$log")" 'workspace close' \
    "an uncorrelated journal authorized workspace cleanup"
  pass "teardown retires only its own watcher markers while preserving uncorrelated journal quarantine"
}

test_teardown_retains_journal_bound_to_another_pane() {
  local case_dir log closed restored
  case_dir=$(make_case retain-drifted-journal)
  write_meta "$case_dir" local-only ship
  configure_herdr_projection_teardown_case "$case_dir"
  log="$case_dir/herdr.log"; closed="$case_dir/closed"; restored="$case_dir/restored"; : > "$log"
  : > "$closed"
  # A version 2 binding that advanced to a replacement pane the metadata never
  # recorded may still name a live quarantined space; only the sweep may judge it.
  printf '%s\n' 'version=2' 'task_id=task-x1' 'projection_id=AbCdEfGhIjKlMnOpQrStUv' \
    "home=$case_dir" 'session=fmtest' 'workspace_id=w1' 'tab_id=w1:t2' 'pane_id=w1:p9' \
    'parent_workspace_id=w0' 'parent_label=firstmate' \
    'workspace_label=└ task-x1 · p:AbCdEfGhIjKlMnOpQrStUv' 'task_label=fm-task-x1' \
    > "$case_dir/state/task-x1.herdr-presentation"

  FM_FAKE_HERDR_LOG="$log" FM_FAKE_HERDR_CLOSED="$closed" FM_FAKE_HERDR_RESTORED="$restored" \
    run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "retain-drifted-journal: teardown failed: $(cat "$case_dir/stderr")"
  assert_present "$case_dir/state/task-x1.herdr-presentation" \
    "teardown retired a journal bound to a pane it never proved gone"
  assert_absent "$case_dir/state/task-x1.meta" "retain-drifted-journal: teardown did not complete"
  assert_grep "retaining herdr presentation journal" "$case_dir/stderr" \
    "teardown kept the drifted journal without saying why"
  pass "teardown retains a presentation journal bound to a pane other than the closed endpoint"
}

# A version 1 attempt journal binds no pane, so proving the recorded task pane
# gone does not prove its token-bearing projected workspace gone. When the v2
# bind never landed (RETIRE_CANDIDATE stays 0 because the metadata workspace no
# longer matches the drifted token workspace), teardown may retire the journal
# only after the session's workspace list confirms the token workspace is gone;
# while it is still present the session-start sweep alone owns it.
configure_herdr_v1_orphan_workspace_case() {  # <case-dir>
  local case_dir=$1 token=AbCdEfGhIjKlMnOpQrStUv
  sed -i.bak 's/^window=.*/window=fmtest:w1:p2/' "$case_dir/state/task-x1.meta"
  rm -f "$case_dir/state/task-x1.meta.bak"
  printf '%s\n' \
    'backend=herdr' \
    'herdr_session=fmtest' \
    'herdr_workspace_id=w9' \
    'herdr_tab_id=w1:t2' \
    'herdr_pane_id=w1:p2' >> "$case_dir/state/task-x1.meta"
  printf '%s\n' \
    'version=1' \
    'task_id=task-x1' \
    "projection_id=$token" > "$case_dir/state/task-x1.herdr-presentation"
  cat > "$case_dir/fakebin/herdr" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >> "${FM_FAKE_HERDR_LOG:?}"
case "${1:-} ${2:-}" in
  "workspace list")
    if [ "${FM_FAKE_HERDR_WS_MALFORMED:-0}" = 1 ]; then
      # A non-object entry before a live token-bearing workspace: the token query
      # is ambiguous, so teardown must treat it as unknown and keep the journal.
      printf '%s\n' '{"result":{"workspaces":[42,{"workspace_id":"w1","active_tab_id":"w1:t2","label":"firstmate/task-x1 · p:AbCdEfGhIjKlMnOpQrStUv","focused":false}]}}'
    elif [ "${FM_FAKE_HERDR_WS_COLLAPSED:-0}" = 1 ]; then
      printf '%s\n' '{"result":{"workspaces":[{"workspace_id":"w2","active_tab_id":"w2:t2","label":"2ndmate-bravo","focused":true}]}}'
    else
      printf '%s\n' '{"result":{"workspaces":[{"workspace_id":"w1","active_tab_id":"w1:t2","label":"firstmate/task-x1 · p:AbCdEfGhIjKlMnOpQrStUv","focused":false},{"workspace_id":"w2","active_tab_id":"w2:t2","label":"2ndmate-bravo","focused":true}]}}'
    fi
    ;;
  "status --json")
    printf '%s\n' '{"server":{"running":true}}'
    ;;
  "session list")
    jq -nc --arg socket "${FM_FAKE_HERDR_LOG%/*}/herdr.sock" \
      '{sessions:[{name:"fmtest",running:true,socket_path:$socket}]}'
    ;;
  "pane close")
    : > "${FM_FAKE_HERDR_CLOSED:?}"
    ;;
  "pane get")
    printf '%s\n' '{"error":{"code":"pane_not_found"}}' >&2
    exit 1
    ;;
  "agent get")
    printf '%s\n' '{"error":{"code":"agent_not_found"}}' >&2
    exit 1
    ;;
esac
SH
  chmod +x "$case_dir/fakebin/herdr"
}

test_teardown_retires_v1_journal_when_projected_workspace_gone() {
  local case_dir log closed
  case_dir=$(make_case retire-v1-journal-workspace-gone)
  write_meta "$case_dir" local-only ship
  configure_herdr_v1_orphan_workspace_case "$case_dir"
  log="$case_dir/herdr.log"; closed="$case_dir/closed"; : > "$log"

  FM_FAKE_HERDR_LOG="$log" FM_FAKE_HERDR_CLOSED="$closed" FM_FAKE_HERDR_WS_COLLAPSED=1 \
    run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "retire-v1-journal-workspace-gone: teardown failed: $(cat "$case_dir/stderr")"
  assert_absent "$case_dir/state/task-x1.herdr-presentation" \
    "a v1 journal whose token workspace is confirmed gone was not retired"
  assert_absent "$case_dir/state/task-x1.meta" \
    "retire-v1-journal-workspace-gone: teardown did not complete"
  assert_not_contains "$(cat "$log")" "workspace close" \
    "retire-v1-journal-workspace-gone: teardown must never call workspace close"
  pass "teardown retires a v1 presentation journal once its token workspace is confirmed gone"
}

test_teardown_retains_v1_journal_when_projected_workspace_present() {
  local case_dir log closed
  case_dir=$(make_case retain-v1-journal-workspace-present)
  write_meta "$case_dir" local-only ship
  configure_herdr_v1_orphan_workspace_case "$case_dir"
  log="$case_dir/herdr.log"; closed="$case_dir/closed"; : > "$log"

  FM_FAKE_HERDR_LOG="$log" FM_FAKE_HERDR_CLOSED="$closed" \
    run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "retain-v1-journal-workspace-present: teardown failed: $(cat "$case_dir/stderr")"
  assert_present "$case_dir/state/task-x1.herdr-presentation" \
    "a v1 journal whose token workspace is still present was wrongly retired, stranding the workspace"
  assert_absent "$case_dir/state/task-x1.meta" \
    "retain-v1-journal-workspace-present: teardown did not complete"
  assert_grep "retaining herdr presentation journal" "$case_dir/stderr" \
    "teardown retained the v1 journal without saying why"
  assert_not_contains "$(cat "$log")" "workspace close" \
    "retain-v1-journal-workspace-present: teardown must not escalate to workspace cleanup"
  pass "teardown retains a v1 presentation journal while its token workspace is still present"
}

test_teardown_retains_v1_journal_when_workspace_query_ambiguous() {
  local case_dir log closed
  case_dir=$(make_case retain-v1-journal-workspace-ambiguous)
  write_meta "$case_dir" local-only ship
  configure_herdr_v1_orphan_workspace_case "$case_dir"
  log="$case_dir/herdr.log"; closed="$case_dir/closed"; : > "$log"

  # A malformed workspace-list entry makes the token query ambiguous: teardown
  # cannot prove the token workspace gone, so it must keep the journal.
  FM_FAKE_HERDR_LOG="$log" FM_FAKE_HERDR_CLOSED="$closed" FM_FAKE_HERDR_WS_MALFORMED=1 \
    run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr" \
    || fail "retain-v1-journal-workspace-ambiguous: teardown failed: $(cat "$case_dir/stderr")"
  assert_present "$case_dir/state/task-x1.herdr-presentation" \
    "a v1 journal was retired even though the workspace query was ambiguous"
  assert_absent "$case_dir/state/task-x1.meta" \
    "retain-v1-journal-workspace-ambiguous: teardown did not complete"
  assert_grep "retaining herdr presentation journal" "$case_dir/stderr" \
    "teardown retained the v1 journal without saying why"
  assert_not_contains "$(cat "$log")" "workspace close" \
    "retain-v1-journal-workspace-ambiguous: teardown must not escalate to workspace cleanup"
  pass "teardown retains a v1 presentation journal when the workspace query is ambiguous"
}

# --- Fix 1: conclude/abort the task's own parked no-mistakes run before the
# worker is removed, and Fix 2: reap leaked descendant processes rooted under
# the task's own worktree/tasktmp - both exercised through the real teardown
# path (bin/fm-teardown.sh), never by matching its source text. ------------

# A parked-at-a-gate `axi status` TOON payload for <branch>/<head>, matching
# the shape no-mistakes actually emits (see tests/fm-crew-state.test.sh's
# run_parked fixture, the same shape bin/fm-crew-state.sh's own tests pin).
parked_axi_status_toon() {  # <branch> <head> [run-id]
  cat <<EOF
run:
  id: "${3:-01RUN}"
  branch: $1
  status: awaiting_approval
  awaiting_agent: parked 2m10s
  head: "$2"
  pr: ""
  findings: none
gate: review
EOF
}

running_axi_status_toon() {  # <branch> <head> [run-id]
  cat <<EOF
run:
  id: "${3:-01RUN}"
  branch: $1
  status: running
  head: "$2"
  pr: ""
steps[1]{step,status,findings,summary}:
  test,running,0,"agent under way"
EOF
}

# One row of the real `no-mistakes runs` ledger: plain text, newest-first,
# no run id, no quoting - "<status> <branch> <short-sha> <date> <time> [<pr-url>]"
# (the same shape tests/fm-crew-state.test.sh's runs-list fixtures pin).
ledger_row() {  # <status> <branch> <short-sha> <date> <time> [pr-url]
  printf '  %-10s %-24s %-8s  %s %s' "$1" "$2" "$3" "$4" "$5"
  [ -z "${6:-}" ] || printf '  %s' "$6"
  printf '\n'
}

# Commit <n> pipeline fix rounds on top of the task branch in a separate
# clone of origin that the task copy NEVER fetches from, mirroring how the
# no-mistakes daemon commits fix rounds in its own gate-repo clone. Echoes
# the newest short sha, which is genuinely absent from the task worktree's
# object store. Args: case_dir [rounds]
make_unfetched_pipeline_heads() {
  local case_dir=$1 rounds=${2:-1} i
  git clone -q "$case_dir/origin.git" "$case_dir/pipeline-clone"
  git -C "$case_dir/pipeline-clone" checkout -q fm/task-x1
  for i in $(seq 1 "$rounds"); do
    git -C "$case_dir/pipeline-clone" -c user.email=t@t -c user.name=t \
      commit -q --allow-empty -m "pipeline fix round $i"
  done
  git -C "$case_dir/pipeline-clone" rev-parse --short=7 HEAD
}

assert_head_absent_from_worktree() {  # <worktree> <short-sha> <label>
  [ -z "$(git -C "$1" rev-parse --verify --quiet "${2}^{commit}" 2>/dev/null)" ] \
    || fail "$3: fixture broke - the pipeline head resolved in the task copy"
}

# Land a shippable commit on the task branch and push it to origin, the same
# "definitely landed, teardown must ALLOW" shape test_no_mistakes_origin_remote_allows
# uses, so these new cases exercise the abort/reap steps on a real successful
# teardown rather than a refusal path.
land_shippable_commit() {
  local case_dir=$1
  wt_commit "$case_dir" "shippable work"
  git -C "$case_dir/wt" push -q origin fm/task-x1
  git -C "$case_dir/project" fetch -q origin
}

# Cleanup keeps the task's no-mistakes pipeline spend in this home's records
# (bin/fm-pipeline-spend.sh) while the task branch that attributes its runs and
# the task record still exist, then removes both as before.
test_teardown_records_the_task_pipeline_spend() {
  local case_dir rc=0 ledger
  case_dir=$(make_case pipeline-spend)
  write_meta "$case_dir" no-mistakes ship
  : > "$case_dir/config/pipeline-spend"
  land_shippable_commit "$case_dir"
  mkdir -p "$case_dir/nm"
  python3 - "$case_dir/nm/state.sqlite" "$case_dir/project" "$(date +%s)" <<'PY'
import sqlite3
import sys

database, project, created = sys.argv[1], sys.argv[2], int(sys.argv[3])
db = sqlite3.connect(database)
db.executescript("""
    CREATE TABLE repos (id TEXT PRIMARY KEY, working_path TEXT NOT NULL UNIQUE);
    CREATE TABLE runs (id TEXT PRIMARY KEY, repo_id TEXT NOT NULL, branch TEXT NOT NULL,
                       status TEXT NOT NULL, created_at INTEGER NOT NULL);
    CREATE TABLE agent_invocations (id TEXT, run_id TEXT, purpose TEXT, session_mode TEXT,
        started_at INTEGER, exit_status TEXT, duration_ms INTEGER, input_tokens INTEGER,
        output_tokens INTEGER, cache_read_tokens INTEGER, cache_creation_tokens INTEGER,
        delta_input_tokens INTEGER, delta_output_tokens INTEGER, delta_cache_read_tokens INTEGER);
""")
db.execute("INSERT INTO repos VALUES ('r1', ?)", (project,))
db.execute("INSERT INTO runs VALUES ('01RUN', 'r1', 'fm/task-x1', 'completed', ?)", (created,))
db.execute("INSERT INTO agent_invocations VALUES ('i1', '01RUN', 'review', 'cold', ?, 'ok', 100, 7, 8, 9, 10, 7, 8, 9)",
           (created,))
db.execute("INSERT INTO agent_invocations VALUES ('i2', '01RUN', 'review', 'cold', ?, 'cancelled', 50, "
           "NULL, NULL, NULL, NULL, NULL, NULL, NULL)", (created + 1,))
db.commit()
PY
  (
    export NM_HOME="$case_dir/nm" FM_FAKE_AXI_OVERVIEW="repo: $case_dir/project"
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr"
  ) || rc=$?

  expect_code 0 "$rc" "pipeline-spend: teardown should succeed"
  ledger=$case_dir/data/pipeline-spend.jsonl
  assert_present "$ledger" "pipeline-spend: teardown left no pipeline spend record"
  jq -e '
    .task == "task-x1" and .spawn_gen == "teardown-test-task-x1"
    and .source == "no-mistakes-state" and .branch == "fm/task-x1"
    and [.runs[].id] == ["01RUN"]
    and .total.invocations == 2 and .total.exit == {"ok": 1, "cancelled": 1}
    and .total.input_tokens == {"total": 7, "unknown": 1}
  ' "$ledger" >/dev/null || fail "pipeline-spend: the recorded spend is wrong: $(cat "$ledger")"
  assert_absent "$case_dir/state/task-x1.meta" "pipeline-spend: teardown kept the task record"
  ! git -C "$case_dir/project" show-ref --verify --quiet refs/heads/fm/task-x1 \
    || fail "pipeline-spend: teardown kept the task branch"
  pass "teardown records the task's pipeline spend before removing its branch and record"
}

test_teardown_skips_pipeline_spend_when_disabled() {
  local case_dir rc=0
  case_dir=$(make_case pipeline-spend-disabled)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 0 "$rc" "pipeline-spend-disabled: teardown should succeed"
  assert_absent "$case_dir/data/pipeline-spend.jsonl" \
    "pipeline-spend-disabled: teardown created a spend ledger without opt-in"
  assert_absent "$case_dir/state/task-x1.meta" \
    "pipeline-spend-disabled: teardown kept the task record"
  pass 'teardown skips all pipeline-spend recording when the home has not opted in'
}

# An owned ship task whose local copy is already gone still leaves a durable
# account: the recorder writes an unavailable-source line before the record goes.
test_teardown_records_unavailable_spend_for_a_gone_worktree() {
  local case_dir rc=0 ledger
  case_dir=$(make_case pipeline-spend-gone)
  write_windowless_legacy_meta "$case_dir" no-mistakes ship "$case_dir/missing-wt"
  : > "$case_dir/config/pipeline-spend"
  seed_backlog_in_flight "$case_dir"
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 0 "$rc" "pipeline-spend-gone: teardown should succeed"
  ledger=$case_dir/data/pipeline-spend.jsonl
  assert_present "$ledger" "pipeline-spend-gone: teardown left no pipeline spend record"
  jq -e '.task == "task-x1" and .source == "unavailable" and .total == null
    and (.reason | contains("is gone"))' "$ledger" >/dev/null \
    || fail "pipeline-spend-gone: the recorded spend is wrong: $(cat "$ledger")"
  assert_absent "$case_dir/state/task-x1.meta" "pipeline-spend-gone: teardown kept the task record"
  pass "teardown records unavailable pipeline spend for an owned ship task whose copy is gone"
}

test_parked_own_run_is_aborted_before_teardown() {
  local case_dir rc head
  case_dir=$(make_case parked-run-abort)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  head=$(git -C "$case_dir/wt" rev-parse HEAD)

  local rc=0
  FM_FAKE_AXI_STATUS="$(parked_axi_status_toon fm/task-x1 "$head")" \
  FM_FAKE_NM_ABORT_LOG="$case_dir/nm-abort.log" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 0 "$rc" "parked-run-abort: teardown should still succeed"
  assert_present "$case_dir/nm-abort.log" \
    "parked-run-abort: no-mistakes axi abort was never invoked for the task's own parked run"
  assert_grep "abort --run 01RUN" "$case_dir/nm-abort.log" \
    "parked-run-abort: no-mistakes axi abort did not target the verified run id"
  assert_grep "parked at a gate; aborting" "$case_dir/stderr" \
    "parked-run-abort: teardown did not report aborting the parked run before removing the worker"
  pass "a task's own parked no-mistakes run is aborted, not orphaned, before the worker is removed"
}

# An abort can race a concurrent gate response: the run finishes with a
# passing-but-not-clean outcome (an explicitly approved Test/CI exception)
# instead of landing on `cancelled`. That is still a terminal, finished run,
# so teardown must conclude cleanly rather than refuse as still-parked.
test_parked_own_run_concludes_on_passed_with_override_after_abort() {
  local case_dir rc head
  case_dir=$(make_case parked-run-abort-passed-with-override)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  head=$(git -C "$case_dir/wt" rev-parse HEAD)

  local rc=0
  FM_FAKE_AXI_STATUS="$(parked_axi_status_toon fm/task-x1 "$head")" \
  FM_FAKE_NM_ABORT_LOG="$case_dir/nm-abort.log" \
  FM_FAKE_AXI_STATUS_AFTER_ABORT='run:
  id: "01RUN"
  outcome: passed-with-override
ci_override_reason: "live checks not all passed: Lint (fail)"' \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 0 "$rc" "parked-run-abort-passed-with-override: teardown should still succeed"
  assert_no_grep "REFUSED" "$case_dir/stderr" \
    "parked-run-abort-passed-with-override: a passing override outcome must not be reported as still parked"
  pass "a run that lands on passed-with-override after abort is still recognized as terminal"
}

# The same race, landing on the other automatic passing-but-not-clean outcome:
# publication or CI verification was skipped instead of an explicit override.
# That is still a terminal, finished run.
test_parked_own_run_concludes_on_passed_with_skips_after_abort() {
  local case_dir rc head
  case_dir=$(make_case parked-run-abort-passed-with-skips)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  head=$(git -C "$case_dir/wt" rev-parse HEAD)

  local rc=0
  FM_FAKE_AXI_STATUS="$(parked_axi_status_toon fm/task-x1 "$head")" \
  FM_FAKE_NM_ABORT_LOG="$case_dir/nm-abort.log" \
  FM_FAKE_AXI_STATUS_AFTER_ABORT='run:
  id: "01RUN"
  outcome: passed-with-skips
automatic_skips: "publication skipped: no-mistakes.yaml pr.enabled=false"' \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 0 "$rc" "parked-run-abort-passed-with-skips: teardown should still succeed"
  assert_no_grep "REFUSED" "$case_dir/stderr" \
    "parked-run-abort-passed-with-skips: a passing skips outcome must not be reported as still parked"
  pass "a run that lands on passed-with-skips after abort is still recognized as terminal"
}

# The pipeline advanced the parked run past the submitted head in its own
# repo, so the run head object does not exist in the task copy at all and the
# strict object-local identity rule cannot bind the run. The daemon's own
# runs ledger is what still proves the run is this task's continuation: its
# newest fm/task-x1 row is active at the unfetched head, anchored by the
# immediately older fm/task-x1 row ending exactly at this worktree's HEAD.
# Teardown must conclude the run instead of orphaning a parked gate wait that
# would otherwise hold a fleet slot forever (observed 2026-09-03). Foreign
# branches' rows interleaved in the ledger must not matter.
test_parked_run_advanced_past_unfetched_head_is_still_aborted() {
  local case_dir rc advanced_short anchor_short
  case_dir=$(make_case parked-run-pipeline-advanced-unfetched)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  anchor_short=$(git -C "$case_dir/wt" rev-parse --short=7 HEAD)
  advanced_short=$(make_unfetched_pipeline_heads "$case_dir")
  assert_head_absent_from_worktree "$case_dir/wt" "$advanced_short" "parked-run-pipeline-advanced-unfetched"

  rc=0
  FM_FAKE_AXI_STATUS="$(parked_axi_status_toon fm/task-x1 "$advanced_short")" \
  FM_FAKE_NM_RUNS_LIST="$(cat <<EOF
$(ledger_row running fm/other-task aaaaaaa 2026-09-03 22:10)
$(ledger_row running fm/task-x1 "$advanced_short" 2026-09-03 07:55)
$(ledger_row failed fm/task-x1 "$anchor_short" 2026-09-02 06:36)
$(ledger_row completed fm/third-task bbbbbbb 2026-09-01 11:00)
EOF
)" \
  FM_FAKE_NM_ABORT_LOG="$case_dir/nm-abort.log" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 0 "$rc" "parked-run-pipeline-advanced-unfetched: teardown should still succeed"
  assert_grep "abort --run 01RUN" "$case_dir/nm-abort.log" \
    "parked-run-pipeline-advanced-unfetched: teardown did not abort the parked run the ledger proves is this task's continuation"
  assert_grep "parked at a gate; aborting" "$case_dir/stderr" \
    "parked-run-pipeline-advanced-unfetched: teardown did not report aborting the parked run"
  pass "a parked run the pipeline advanced past the task copy is still concluded from the runs ledger, not orphaned"
}

test_parked_run_with_mismatched_ledger_head_is_never_aborted() {
  local case_dir rc advanced_short anchor_short
  case_dir=$(make_case parked-run-mismatched-ledger-head)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  anchor_short=$(git -C "$case_dir/wt" rev-parse --short=7 HEAD)
  advanced_short=$(make_unfetched_pipeline_heads "$case_dir")
  assert_head_absent_from_worktree "$case_dir/wt" "$advanced_short" "parked-run-mismatched-ledger-head"

  rc=0
  FM_FAKE_AXI_STATUS="$(parked_axi_status_toon fm/task-x1 "$advanced_short")" \
  FM_FAKE_NM_RUNS_LIST="$(cat <<EOF
$(ledger_row running fm/task-x1 deadbee 2026-09-03 07:55)
$(ledger_row failed fm/task-x1 "$anchor_short" 2026-09-02 06:36)
EOF
)" \
  FM_FAKE_NM_ABORT_LOG="$case_dir/nm-abort.log" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 0 "$rc" "parked-run-mismatched-ledger-head: teardown should still succeed"
  assert_absent "$case_dir/nm-abort.log" \
    "parked-run-mismatched-ledger-head: teardown aborted a ledger run with a different head"
  pass "a ledger row for a different head never authorizes a parked-run abort"
}

test_parked_run_with_malformed_ledger_row_is_never_aborted() {
  local case_dir rc advanced_short anchor_short
  case_dir=$(make_case parked-run-malformed-ledger-row)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  anchor_short=$(git -C "$case_dir/wt" rev-parse --short=7 HEAD)
  advanced_short=$(make_unfetched_pipeline_heads "$case_dir")
  assert_head_absent_from_worktree "$case_dir/wt" "$advanced_short" "parked-run-malformed-ledger-row"

  rc=0
  FM_FAKE_AXI_STATUS="$(parked_axi_status_toon fm/task-x1 "$advanced_short")" \
  FM_FAKE_NM_RUNS_LIST="$(cat <<EOF
running fm/task-x1 $advanced_short
$(ledger_row failed fm/task-x1 "$anchor_short" 2026-09-02 06:36)
EOF
)" \
  FM_FAKE_NM_ABORT_LOG="$case_dir/nm-abort.log" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 0 "$rc" "parked-run-malformed-ledger-row: teardown should still succeed"
  assert_absent "$case_dir/nm-abort.log" \
    "parked-run-malformed-ledger-row: teardown aborted from a malformed ledger row"
  pass "a malformed ledger row never authorizes a parked-run abort"
}

test_parked_run_with_impossible_ledger_date_is_never_aborted() {
  local case_dir rc advanced_short anchor_short
  case_dir=$(make_case parked-run-impossible-ledger-date)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  anchor_short=$(git -C "$case_dir/wt" rev-parse --short=7 HEAD)
  advanced_short=$(make_unfetched_pipeline_heads "$case_dir")
  assert_head_absent_from_worktree "$case_dir/wt" "$advanced_short" "parked-run-impossible-ledger-date"

  rc=0
  FM_FAKE_AXI_STATUS="$(parked_axi_status_toon fm/task-x1 "$advanced_short")" \
  FM_FAKE_NM_RUNS_LIST="$(cat <<EOF
$(ledger_row running fm/task-x1 "$advanced_short" 2026-02-31 07:55)
$(ledger_row failed fm/task-x1 "$anchor_short" 2026-02-28 06:36)
EOF
)" \
  FM_FAKE_NM_RUNS_LOG="$case_dir/nm-runs.log" \
  FM_FAKE_NM_ABORT_LOG="$case_dir/nm-abort.log" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 0 "$rc" "parked-run-impossible-ledger-date: teardown should still succeed"
  assert_present "$case_dir/nm-runs.log" \
    "parked-run-impossible-ledger-date: fixture broke - the ledger fallback never engaged"
  assert_absent "$case_dir/nm-abort.log" \
    "parked-run-impossible-ledger-date: teardown aborted from an impossible ledger date"
  pass "an impossible ledger date never authorizes a parked-run abort"
}

test_terminal_status_with_gate_never_queries_or_aborts_ledger_fallback() {
  local case_dir rc advanced_short anchor_short terminal_status
  case_dir=$(make_case parked-run-terminal-status-gate)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  anchor_short=$(git -C "$case_dir/wt" rev-parse --short=7 HEAD)
  advanced_short=$(make_unfetched_pipeline_heads "$case_dir")
  assert_head_absent_from_worktree "$case_dir/wt" "$advanced_short" "parked-run-terminal-status-gate"
  terminal_status=$(parked_axi_status_toon fm/task-x1 "$advanced_short")
  terminal_status=${terminal_status/status: awaiting_approval/status: completed}

  rc=0
  FM_FAKE_AXI_STATUS="$terminal_status" \
  FM_FAKE_NM_RUNS_LIST="$(cat <<EOF
$(ledger_row running fm/task-x1 "$advanced_short" 2026-09-03 07:55)
$(ledger_row failed fm/task-x1 "$anchor_short" 2026-09-02 06:36)
EOF
)" \
  FM_FAKE_NM_RUNS_LOG="$case_dir/nm-runs.log" \
  FM_FAKE_NM_ABORT_LOG="$case_dir/nm-abort.log" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 0 "$rc" "parked-run-terminal-status-gate: teardown should still succeed"
  assert_absent "$case_dir/nm-runs.log" \
    "parked-run-terminal-status-gate: terminal status queried the ledger fallback"
  assert_absent "$case_dir/nm-abort.log" \
    "parked-run-terminal-status-gate: terminal status with a stale gate aborted"
  pass "a terminal status with a stale gate never reaches ledger cleanup"
}

# Counterfactual twin of the unfetched defect above: the SAME parked-run shape
# with the pipeline's advanced fix head FETCHED into the task copy (objects
# only - no ref moves) resolves through the strict object-local rule alone,
# because a fix round's commits descend from this worktree's submitted HEAD.
# With an EMPTY ledger, teardown must still abort - and must never query the
# ledger at all - proving the fallback stays dormant whenever the run head's
# object is present locally (no ledger dependency on the strict-rule path).
test_parked_run_advanced_head_locally_fetched_is_still_aborted() {
  local case_dir rc advanced_short
  case_dir=$(make_case parked-run-advanced-fetched)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  advanced_short=$(make_unfetched_pipeline_heads "$case_dir")
  # The one changed condition vs the defect case: fetch the fix commits into
  # the project clone's object store (shared with the task worktree) without
  # moving any ref, so fm_nm_resolve_commit sees the head again.
  git -C "$case_dir/project" fetch -q "$case_dir/pipeline-clone" fm/task-x1
  [ -n "$(git -C "$case_dir/wt" rev-parse --verify --quiet "${advanced_short}^{commit}" 2>/dev/null)" ] \
    || fail "parked-run-advanced-fetched: fixture broke - the pipeline head never reached the task copy"

  rc=0
  FM_FAKE_AXI_STATUS="$(parked_axi_status_toon fm/task-x1 "$advanced_short")" \
  FM_FAKE_NM_RUNS_LIST="" \
  FM_FAKE_NM_RUNS_LOG="$case_dir/nm-runs.log" \
  FM_FAKE_NM_ABORT_LOG="$case_dir/nm-abort.log" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 0 "$rc" "parked-run-advanced-fetched: teardown should still succeed"
  assert_grep "abort --run 01RUN" "$case_dir/nm-abort.log" \
    "parked-run-advanced-fetched: teardown did not abort the parked run the strict object-local rule binds"
  assert_absent "$case_dir/nm-runs.log" \
    "parked-run-advanced-fetched: the ledger fallback fired even though the advanced head resolves locally"
  pass "an advanced head present locally aborts through the strict rule alone - the ledger fallback stays dormant"
}

# No anchor: the unresolvable active row is the branch's ONLY row, so nothing
# proves the run ever touched this worktree's head - a branch-name coincidence
# or an arbitrary daemon-side run must not be concluded.
test_parked_advanced_run_without_anchor_is_never_aborted() {
  local case_dir rc advanced_short
  case_dir=$(make_case parked-run-advanced-no-anchor)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  advanced_short=$(make_unfetched_pipeline_heads "$case_dir")
  assert_head_absent_from_worktree "$case_dir/wt" "$advanced_short" "parked-run-advanced-no-anchor"

  rc=0
  FM_FAKE_AXI_STATUS="$(parked_axi_status_toon fm/task-x1 "$advanced_short")" \
  FM_FAKE_NM_RUNS_LIST="$(cat <<EOF
$(ledger_row running fm/other-task aaaaaaa 2026-09-03 22:10)
$(ledger_row running fm/task-x1 "$advanced_short" 2026-09-03 07:55)
$(ledger_row completed fm/third-task bbbbbbb 2026-09-01 11:00)
EOF
)" \
  FM_FAKE_NM_ABORT_LOG="$case_dir/nm-abort.log" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 0 "$rc" "parked-run-advanced-no-anchor: teardown should still succeed"
  assert_absent "$case_dir/nm-abort.log" \
    "parked-run-advanced-no-anchor: teardown aborted an unanchored run it cannot prove is its own"
  pass "an unresolvable active row with no same-branch anchor is never concluded (conservative refusal)"
}

# The anchor row resolves but to an OLDER commit: the worktree advanced past
# it since the run was submitted, so exact-equality fails and the run is not
# provably this worktree's submission. Ancestor-only anchors must never bind.
test_parked_advanced_run_ancestor_anchor_is_never_aborted() {
  local case_dir rc advanced_short parent_short
  case_dir=$(make_case parked-run-advanced-ancestor-anchor)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  parent_short=$(git -C "$case_dir/wt" rev-parse --short=7 HEAD~1)
  advanced_short=$(make_unfetched_pipeline_heads "$case_dir")
  assert_head_absent_from_worktree "$case_dir/wt" "$advanced_short" "parked-run-advanced-ancestor-anchor"

  rc=0
  FM_FAKE_AXI_STATUS="$(parked_axi_status_toon fm/task-x1 "$advanced_short")" \
  FM_FAKE_NM_RUNS_LIST="$(cat <<EOF
$(ledger_row running fm/task-x1 "$advanced_short" 2026-09-03 07:55)
$(ledger_row failed fm/task-x1 "$parent_short" 2026-09-02 06:36)
EOF
)" \
  FM_FAKE_NM_ABORT_LOG="$case_dir/nm-abort.log" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 0 "$rc" "parked-run-advanced-ancestor-anchor: teardown should still succeed"
  assert_absent "$case_dir/nm-abort.log" \
    "parked-run-advanced-ancestor-anchor: teardown aborted on an ancestor-only anchor"
  pass "an ancestor-only anchor never binds an advanced parked run to this task"
}

# The branch's newest same-branch row is TERMINAL at an unfetched head: a
# finished run is history, never the branch's current run, and the anchored
# older row never answers for it. Teardown must not conclude a run from a
# stale terminal row.
test_parked_terminal_unfetched_row_is_never_aborted() {
  local case_dir rc advanced_short anchor_short
  case_dir=$(make_case parked-run-terminal-unfetched)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  anchor_short=$(git -C "$case_dir/wt" rev-parse --short=7 HEAD)
  advanced_short=$(make_unfetched_pipeline_heads "$case_dir")
  assert_head_absent_from_worktree "$case_dir/wt" "$advanced_short" "parked-run-terminal-unfetched"

  rc=0
  FM_FAKE_AXI_STATUS="$(parked_axi_status_toon fm/task-x1 "$advanced_short")" \
  FM_FAKE_NM_RUNS_LIST="$(cat <<EOF
$(ledger_row failed fm/task-x1 "$advanced_short" 2026-09-03 08:20)
$(ledger_row failed fm/task-x1 "$anchor_short" 2026-09-02 06:36)
EOF
)" \
  FM_FAKE_NM_ABORT_LOG="$case_dir/nm-abort.log" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 0 "$rc" "parked-run-terminal-unfetched: teardown should still succeed"
  assert_absent "$case_dir/nm-abort.log" \
    "parked-run-terminal-unfetched: teardown concluded a run from a terminal unfetched row"
  pass "a terminal unfetched-head row is stale history and never concludes a run"
}

# The crafted d15 boundary, tightened deliberately: the axi-reported head is
# unresolvable and the branch's newest ledger row is TERMINAL at exactly this
# worktree's head - a perfectly anchored, already-finished run. A finished run
# is history, so the ledger fallback authorizes cleanup only when its proved
# answer is the explicitly active word (`running`): a terminal newest row,
# even anchored at this head, never authorizes an abort. The runs log proves
# the fallback actually engaged, so the refusal is this tightened boundary
# and not an earlier guard.
test_parked_run_terminal_newest_row_at_own_head_is_never_aborted() {
  local case_dir rc advanced_short anchor_short
  case_dir=$(make_case parked-run-terminal-newest-at-head)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  anchor_short=$(git -C "$case_dir/wt" rev-parse --short=7 HEAD)
  advanced_short=$(make_unfetched_pipeline_heads "$case_dir")
  assert_head_absent_from_worktree "$case_dir/wt" "$advanced_short" "parked-run-terminal-newest-at-head"

  rc=0
  FM_FAKE_AXI_STATUS="$(parked_axi_status_toon fm/task-x1 "$advanced_short")" \
  FM_FAKE_NM_RUNS_LIST="$(cat <<EOF
$(ledger_row running fm/other-task aaaaaaa 2026-09-03 22:10)
$(ledger_row failed fm/task-x1 "$anchor_short" 2026-09-03 06:36)
EOF
)" \
  FM_FAKE_NM_RUNS_LOG="$case_dir/nm-runs.log" \
  FM_FAKE_NM_ABORT_LOG="$case_dir/nm-abort.log" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 0 "$rc" "parked-run-terminal-newest-at-head: teardown should still succeed"
  assert_present "$case_dir/nm-runs.log" \
    "parked-run-terminal-newest-at-head: fixture broke - the ledger fallback never engaged"
  assert_absent "$case_dir/nm-abort.log" \
    "parked-run-terminal-newest-at-head: teardown aborted a run whose newest anchored ledger row is terminal"
  pass "a terminal newest row anchored at this worktree's head never authorizes an abort"
}

# The branch's newest row resolves in this copy to a head that DIVERGED from
# this worktree's HEAD (the branch was rewritten or moved on by a newer run
# from another worktree of the same project): not equal, not a descendant,
# so the shared rule answers nothing and every older row - including this
# task's parked run - stays stale history. Neither this task's run nor the
# unrelated newer run may be concluded here.
test_parked_run_behind_diverged_newer_row_is_never_aborted() {
  local case_dir rc advanced_short diverged_short
  case_dir=$(make_case parked-run-behind-newer-row)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  advanced_short=$(make_unfetched_pipeline_heads "$case_dir")
  assert_head_absent_from_worktree "$case_dir/wt" "$advanced_short" "parked-run-behind-newer-row"
  # A newer fm/task-x1 head that THIS copy resolves but that diverged from
  # the worktree's HEAD: rewritten from origin/main and pushed over the
  # branch (the fixture origin allows the non-fast-forward rewrite), then
  # fetched into the project clone (shared object store).
  git -C "$case_dir/origin.git" config receive.denyNonFastForwards false
  git clone -q "$case_dir/origin.git" "$case_dir/newer-clone"
  git -C "$case_dir/newer-clone" checkout -q origin/main
  git -C "$case_dir/newer-clone" -c user.email=t@t -c user.name=t \
    commit -q --allow-empty -m "newer run's diverged work"
  git -C "$case_dir/newer-clone" push -q --force origin HEAD:fm/task-x1
  git -C "$case_dir/project" fetch -q origin
  diverged_short=$(git -C "$case_dir/wt" rev-parse --short=7 origin/fm/task-x1)
  git -C "$case_dir/wt" merge-base --is-ancestor HEAD "$diverged_short" \
    && fail "parked-run-behind-newer-row: fixture broke - the newer row is a descendant, not diverged"

  rc=0
  FM_FAKE_AXI_STATUS="$(parked_axi_status_toon fm/task-x1 "$advanced_short")" \
  FM_FAKE_NM_RUNS_LIST="$(cat <<EOF
$(ledger_row running fm/task-x1 "$diverged_short" 2026-09-03 09:00)
$(ledger_row failed fm/task-x1 "$advanced_short" 2026-09-03 07:55)
EOF
)" \
  FM_FAKE_NM_ABORT_LOG="$case_dir/nm-abort.log" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 0 "$rc" "parked-run-behind-newer-row: teardown should still succeed"
  assert_absent "$case_dir/nm-abort.log" \
    "parked-run-behind-newer-row: teardown concluded this task from another run's ledger row"
  pass "a resolvable diverged newer same-branch row makes every older row stale history; no run is concluded"
}

# Two consecutive unresolvable running rows for the branch: the ledger cannot
# prove which row is current or where the submission boundary is. Ambiguity
# must refuse, never guess.
test_parked_advanced_run_ambiguous_rows_are_never_aborted() {
  local case_dir rc advanced_short anchor_short
  case_dir=$(make_case parked-run-advanced-ambiguous)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  anchor_short=$(git -C "$case_dir/wt" rev-parse --short=7 HEAD)
  advanced_short=$(make_unfetched_pipeline_heads "$case_dir" 2)
  assert_head_absent_from_worktree "$case_dir/wt" "$advanced_short" "parked-run-advanced-ambiguous"

  rc=0
  FM_FAKE_AXI_STATUS="$(parked_axi_status_toon fm/task-x1 "$advanced_short")" \
  FM_FAKE_NM_RUNS_LIST="$(cat <<EOF
$(ledger_row running fm/task-x1 "$advanced_short" 2026-09-03 08:30)
$(ledger_row failed fm/other-task ccccccc 2026-09-03 08:10)
$(ledger_row running fm/task-x1 ddddddd 2026-09-03 07:55)
$(ledger_row failed fm/task-x1 "$anchor_short" 2026-09-02 06:36)
EOF
)" \
  FM_FAKE_NM_ABORT_LOG="$case_dir/nm-abort.log" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 0 "$rc" "parked-run-advanced-ambiguous: teardown should still succeed"
  assert_absent "$case_dir/nm-abort.log" \
    "parked-run-advanced-ambiguous: teardown guessed through ambiguous ledger rows"
  pass "consecutive unresolvable rows are ambiguous and never conclude a run"
}

# The ledger proves the continuation, but the run is NOT parked at a gate -
# it is autonomously running/fixing against the daemon's own clone. Teardown
# must leave that work alone even when the attribution proof would bind it.
test_ledger_proven_continuation_never_aborts_active_run() {
  local case_dir rc advanced_short anchor_short
  case_dir=$(make_case parked-run-ledger-active)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  anchor_short=$(git -C "$case_dir/wt" rev-parse --short=7 HEAD)
  advanced_short=$(make_unfetched_pipeline_heads "$case_dir")
  assert_head_absent_from_worktree "$case_dir/wt" "$advanced_short" "parked-run-ledger-active"

  rc=0
  FM_FAKE_AXI_STATUS="$(running_axi_status_toon fm/task-x1 "$advanced_short")" \
  FM_FAKE_NM_RUNS_LIST="$(cat <<EOF
$(ledger_row running fm/task-x1 "$advanced_short" 2026-09-03 07:55)
$(ledger_row failed fm/task-x1 "$anchor_short" 2026-09-02 06:36)
EOF
)" \
  FM_FAKE_NM_ABORT_LOG="$case_dir/nm-abort.log" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 0 "$rc" "parked-run-ledger-active: teardown should still succeed"
  assert_absent "$case_dir/nm-abort.log" \
    "parked-run-ledger-active: teardown aborted an actively running run the ledger happened to bind"
  pass "a ledger-proven continuation is still left alone while the run is autonomously active"
}

test_mismatched_run_after_abort_refuses_unconfirmed() {
  local case_dir rc head
  case_dir=$(make_case parked-run-replaced)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  head=$(git -C "$case_dir/wt" rev-parse HEAD)

  rc=0
  FM_FAKE_AXI_STATUS="$(parked_axi_status_toon fm/task-x1 "$head" 01RUN)" \
  FM_FAKE_AXI_STATUS_AFTER_ABORT="$(parked_axi_status_toon fm/task-x1 "$head" 02RUN)" \
  FM_FAKE_NM_ABORT_LOG="$case_dir/nm-abort.log" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 1 "$rc" "parked-run-replaced: a different run does not confirm the targeted abort"
  assert_grep "abort --run 01RUN" "$case_dir/nm-abort.log" \
    "parked-run-replaced: teardown did not abort only the verified run"
  assert_present "$case_dir/wt" "parked-run-replaced: teardown removed the worktree without confirmation"
  pass "a different run cannot confirm the targeted abort"
}

test_empty_status_after_abort_refuses_unconfirmed() {
  local case_dir rc head
  case_dir=$(make_case parked-run-empty-confirmation)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  head=$(git -C "$case_dir/wt" rev-parse HEAD)

  rc=0
  FM_FAKE_AXI_STATUS="$(parked_axi_status_toon fm/task-x1 "$head")" \
  FM_FAKE_NM_ABORT_LOG="$case_dir/nm-abort.log" \
  FM_FAKE_NM_EMPTY_AFTER_ABORT=1 \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 1 "$rc" "parked-run-empty-confirmation: empty status should refuse"
  assert_present "$case_dir/wt" "parked-run-empty-confirmation: teardown removed the worktree"
  pass "empty post-abort status is not accepted as confirmation"
}

test_not_found_status_after_abort_confirms_completion() {
  local case_dir rc head
  case_dir=$(make_case parked-run-not-found-confirmation)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  head=$(git -C "$case_dir/wt" rev-parse HEAD)

  rc=0
  FM_FAKE_AXI_STATUS="$(parked_axi_status_toon fm/task-x1 "$head")" \
  FM_FAKE_NM_ABORT_LOG="$case_dir/nm-abort.log" \
  FM_FAKE_NM_NOT_FOUND_AFTER_ABORT=1 \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 0 "$rc" "parked-run-not-found-confirmation: explicit not-found should confirm completion"
  pass "the CLI's exact run-not-found signal confirms completion"
}

test_parked_own_run_refuses_when_abort_is_unconfirmed() {
  local case_dir rc head pid
  case_dir=$(make_case parked-run-abort-unconfirmed)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  head=$(git -C "$case_dir/wt" rev-parse HEAD)
  ( cd "$case_dir/wt" && exec sleep 300 ) &
  pid=$!
  disown

  cat > "$case_dir/fakebin/treehouse" <<EOF
#!/usr/bin/env bash
printf 'return\n' >> "$case_dir/treehouse.log"
EOF
  chmod +x "$case_dir/fakebin/treehouse"

  rc=0
  FM_FAKE_AXI_STATUS="$(parked_axi_status_toon fm/task-x1 "$head")" \
  FM_FAKE_NM_ABORT_LOG="$case_dir/nm-abort.log" \
  FM_FAKE_NM_ABORT_NOOP=1 \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 1 "$rc" "parked-run-abort-unconfirmed: teardown should refuse"
  assert_grep "REFUSED: no-mistakes run for task-x1 is still parked after axi abort" "$case_dir/stderr" \
    "parked-run-abort-unconfirmed: teardown did not explain the parked-run refusal"
  assert_present "$case_dir/wt" \
    "parked-run-abort-unconfirmed: teardown removed the worktree after refusing"
  assert_present "$case_dir/state/task-x1.meta" \
    "parked-run-abort-unconfirmed: teardown removed task metadata after refusing"
  assert_absent "$case_dir/treehouse.log" \
    "parked-run-abort-unconfirmed: teardown returned the worktree after refusing"
  kill -0 "$pid" 2>/dev/null || fail "parked-run-abort-unconfirmed: process reap ran before refusal"
  kill -KILL "$pid" 2>/dev/null || true
  pass "teardown refuses before reap or removal when a task-owned run remains parked"
}

test_another_branchs_parked_run_is_never_touched() {
  local case_dir rc
  case_dir=$(make_case parked-run-not-ours)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"

  local rc=0
  # A parked run reported for a DIFFERENT branch - e.g. another crew's task
  # still validating on the shared gate - must never be aborted by this task's
  # teardown.
  FM_FAKE_AXI_STATUS="$(parked_axi_status_toon fm/some-other-task deadbeef)" \
  FM_FAKE_NM_ABORT_LOG="$case_dir/nm-abort.log" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 0 "$rc" "parked-run-not-ours: teardown should still succeed"
  assert_absent "$case_dir/nm-abort.log" \
    "parked-run-not-ours: teardown called axi abort for a run on another branch"
  assert_not_contains "$(cat "$case_dir/stderr")" "aborting" \
    "parked-run-not-ours: teardown reported aborting a run it does not own"
  pass "a parked run on another branch is never aborted by this task's teardown (ownership is precise)"
}

test_own_autonomous_run_is_left_alone() {
  local case_dir rc head
  case_dir=$(make_case autonomous-run-left-alone)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  head=$(git -C "$case_dir/wt" rev-parse HEAD)

  rc=0
  FM_FAKE_AXI_STATUS="$(running_axi_status_toon fm/task-x1 "$head")" \
  FM_FAKE_NM_ABORT_LOG="$case_dir/nm-abort.log" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 0 "$rc" "autonomous-run-left-alone: teardown should still succeed"
  assert_absent "$case_dir/nm-abort.log" \
    "autonomous-run-left-alone: teardown aborted a task-owned autonomous run"
  assert_not_contains "$(cat "$case_dir/stderr")" "aborting" \
    "autonomous-run-left-alone: teardown reported aborting an autonomous run"
  pass "a task-owned autonomous running step is left alone rather than aborted"
}

test_leaked_worktree_process_is_reaped() {
  local case_dir rc pid
  case_dir=$(make_case leaked-process-reap)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"

  # A backgrounded, disowned process rooted (by cwd) under the task's own
  # worktree - the same shape the observed incident's leaked `go test`
  # binaries took (reparented to init, no live task meta to attribute them
  # to once an unpatched teardown had already run).
  ( cd "$case_dir/wt" && exec sleep 300 ) &
  pid=$!
  disown
  sleep 0.3
  kill -0 "$pid" 2>/dev/null || fail "leaked-process-reap: setup sleeper did not start"

  rc=0
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 0 "$rc" "leaked-process-reap: teardown should still succeed"
  if kill -0 "$pid" 2>/dev/null; then
    kill -KILL "$pid" 2>/dev/null || true
    fail "leaked-process-reap: leaked worktree process survived teardown"
  fi
  assert_grep "reaping leaked worktree process" "$case_dir/stderr" \
    "leaked-process-reap: teardown did not report reaping the leaked process"
  pass "a leaked descendant process rooted under the task's worktree is reaped by teardown, not left surviving"
}

test_leaked_tasktmp_process_is_reaped() {
  local case_dir rc pid
  case_dir=$(make_case leaked-tasktmp-reap)
  write_meta "$case_dir" no-mistakes ship
  printf '%s\n' "tasktmp=$case_dir/tasktmp" >> "$case_dir/state/task-x1.meta"
  mkdir -p "$case_dir/tasktmp"
  land_shippable_commit "$case_dir"

  ( cd "$case_dir/tasktmp" && exec sleep 300 ) &
  pid=$!
  disown
  sleep 0.3
  kill -0 "$pid" 2>/dev/null || fail "leaked-tasktmp-reap: setup sleeper did not start"

  rc=0
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 0 "$rc" "leaked-tasktmp-reap: teardown should still succeed"
  if kill -0 "$pid" 2>/dev/null; then
    kill -KILL "$pid" 2>/dev/null || true
    fail "leaked-tasktmp-reap: leaked tasktmp process survived teardown"
  fi
  assert_grep "reaping leaked worktree process" "$case_dir/stderr" \
    "leaked-tasktmp-reap: teardown did not report reaping the leaked tasktmp process"
  pass "a leaked descendant process rooted under the task's per-task tasktmp is reaped by teardown too"
}

test_lsof_absent_reaps_tmux_process_group() {
  local case_dir rc pid path_without_lsof
  case_dir=$(make_case lsof-absent-process-group-reap)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  path_without_lsof=$(make_path_without_lsof "$case_dir")
  PATH="$path_without_lsof" command -v lsof >/dev/null 2>&1 \
    && fail "lsof-absent-process-group-reap: fixture path unexpectedly exposes lsof"

  perl -e 'setpgrp(0, 0); chdir shift or die; exec "sleep", "300"' "$case_dir/wt" &
  pid=$!
  disown
  sleep 0.3
  kill -0 "$pid" 2>/dev/null || fail "lsof-absent-process-group-reap: setup sleeper did not start"
  cat > "$case_dir/fakebin/tmux" <<EOF
#!/usr/bin/env bash
if [ "\${1:-}" = display-message ] && [ "\${*: -1}" = '#{pane_pid}' ]; then
  printf '%s\n' '$pid'
fi
exit 0
EOF
  chmod +x "$case_dir/fakebin/tmux"

  rc=0
  FM_TEARDOWN_TEST_PATH="$path_without_lsof" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 0 "$rc" "lsof-absent-process-group-reap: teardown should succeed"
  if kill -0 "$pid" 2>/dev/null; then
    kill -KILL "$pid" 2>/dev/null || true
    fail "lsof-absent-process-group-reap: tmux process group survived teardown"
  fi
  assert_grep "reaping leaked worktree process group" "$case_dir/stderr" \
    "lsof-absent-process-group-reap: teardown did not use the process-group fallback"
  pass "missing lsof falls back to reaping the tmux pane process group"
}

test_lsof_error_refuses_before_removal() {
  local case_dir rc
  case_dir=$(make_case lsof-error-refusal)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  cat > "$case_dir/fakebin/lsof" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  cat > "$case_dir/fakebin/treehouse" <<EOF
#!/usr/bin/env bash
printf 'return\n' >> "$case_dir/treehouse.log"
EOF
  chmod +x "$case_dir/fakebin/lsof" "$case_dir/fakebin/treehouse"

  rc=0
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 1 "$rc" "lsof-error-refusal: teardown should refuse"
  assert_grep "REFUSED: cannot determine leaked processes under $case_dir/wt for task-x1 (lsof failed)" "$case_dir/stderr" \
    "lsof-error-refusal: teardown did not explain the lsof refusal"
  assert_present "$case_dir/wt" "lsof-error-refusal: teardown removed the worktree"
  assert_present "$case_dir/state/task-x1.meta" "lsof-error-refusal: teardown removed task metadata"
  assert_absent "$case_dir/treehouse.log" "lsof-error-refusal: teardown returned the worktree"
  pass "an erroring lsof scan refuses teardown and preserves the task"
}

test_reused_pid_identity_is_not_force_killed() {
  local case_dir rc pid
  case_dir=$(make_case reused-pid-identity)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"

  perl -e '$SIG{TERM} = "IGNORE"; sleep 300' &
  pid=$!
  disown
  sleep 0.2
  cat > "$case_dir/fakebin/lsof" <<EOF
#!/usr/bin/env bash
count=0
[ ! -f '$case_dir/lsof-count' ] || count=\$(cat '$case_dir/lsof-count')
count=\$((count + 1))
printf '%s\n' "\$count" > '$case_dir/lsof-count'
if [ "\$count" -le 3 ]; then printf 'p%s\nfcwd\nn%s\n' '$pid' '$case_dir/wt'; fi
EOF
  cat > "$case_dir/fakebin/ps" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = -p ] && [ "${2:-}" = "${FM_FAKE_REUSED_PID:-}" ] \
   && [ "${3:-}" = -o ] && [ "${4:-}" = lstart= ]; then
  count=0
  [ ! -f "$FM_FAKE_PS_COUNT" ] || count=$(cat "$FM_FAKE_PS_COUNT")
  count=$((count + 1))
  printf '%s\n' "$count" > "$FM_FAKE_PS_COUNT"
  if [ "$count" -le 2 ]; then printf 'Tue Aug  4 10:00:00 2026\n'
  else printf 'Tue Aug  4 10:00:01 2026\n'; fi
  exit 0
fi
exec "$REAL_PS_FOR_TEST" "$@"
SH
  chmod +x "$case_dir/fakebin/lsof" "$case_dir/fakebin/ps"

  rc=0
  FM_PROC_ROOT_OVERRIDE="$case_dir/no-proc" \
  FM_FAKE_REUSED_PID="$pid" FM_FAKE_PS_COUNT="$case_dir/ps-count" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 0 "$rc" "reused-pid-identity: teardown should skip the replacement process"
  if ! kill -0 "$pid" 2>/dev/null; then
    fail "reused-pid-identity: teardown force-killed a process whose start time changed"
  fi
  kill -KILL "$pid" 2>/dev/null || true
  pass "a reused pid with a different start time is never force-killed"
}

test_exec_changed_process_is_still_reaped() {
  local case_dir rc pid marker done_flag survived=0
  case_dir=$(make_case exec-changed-process)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  marker="$case_dir/exec-now"
  done_flag="$case_dir/exec-done"

  ( cd "$case_dir/wt" && exec perl -e '
      my ($marker, $done) = @ARGV;
      until (-e $marker) { select undef, undef, undef, 0.01; }
      open my $fh, ">", $done or die "open";
      close $fh;
      exec "perl", "-e", '\''$SIG{TERM} = "IGNORE"; sleep 300'\'';
    ' "$marker" "$done_flag" ) &
  pid=$!
  disown
  sleep 0.2
  cat > "$case_dir/fakebin/ps" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = -p ] && [ "${2:-}" = "${FM_FAKE_EXEC_PID:-}" ] \
   && [ "${3:-}" = -o ] && [ "${4:-}" = lstart= ]; then
  out=$("$REAL_PS_FOR_TEST" "$@") || exit $?
  [ -e "$FM_FAKE_EXEC_MARKER" ] || : > "$FM_FAKE_EXEC_MARKER"
  printf '%s\n' "$out"
  exit 0
fi
exec "$REAL_PS_FOR_TEST" "$@"
SH
  cat > "$case_dir/fakebin/lsof" <<'SH'
#!/usr/bin/env bash
count=0
[ ! -f "$FM_FAKE_LSOF_COUNT" ] || count=$(cat "$FM_FAKE_LSOF_COUNT")
count=$((count + 1))
printf '%s\n' "$count" > "$FM_FAKE_LSOF_COUNT"
if [ "$count" -eq 2 ]; then
  i=0
  while [ "$i" -lt 100 ]; do
    [ ! -e "$FM_FAKE_EXEC_DONE" ] || break
    sleep 0.01
    i=$((i + 1))
  done
fi
exec "$REAL_LSOF_FOR_TEST" "$@"
SH
  chmod +x "$case_dir/fakebin/ps" "$case_dir/fakebin/lsof"

  rc=0
  FM_PROC_ROOT_OVERRIDE="$case_dir/no-proc" \
  FM_FAKE_EXEC_PID="$pid" FM_FAKE_EXEC_MARKER="$marker" \
  FM_FAKE_EXEC_DONE="$done_flag" FM_FAKE_LSOF_COUNT="$case_dir/lsof-count" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  if kill -0 "$pid" 2>/dev/null; then
    survived=1
    kill -KILL "$pid" 2>/dev/null || true
  fi
  expect_code 0 "$rc" "exec-changed-process: teardown should succeed"
  [ "$survived" -eq 0 ] || fail "exec-changed-process: exec-changed leaked process survived teardown"
  pass "an exec change preserves birth identity and the process is reaped"
}

test_process_spawned_during_grace_is_reaped_on_later_pass() {
  local case_dir rc pid child_file child_pid="" parent_survived=0 child_survived=0
  case_dir=$(make_case grace-spawn-convergence)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  child_file="$case_dir/child.pid"

  ( cd "$case_dir/wt" && exec perl -e '
      my $file = shift;
      $SIG{TERM} = sub {
        my $child = fork();
        die "fork" unless defined $child;
        if (!$child) { exec "sleep", "300"; }
        open my $fh, ">", $file or die "open";
        print {$fh} "$child\n";
        close $fh;
        exit 0;
      };
      sleep 300;
    ' "$child_file" ) &
  pid=$!
  disown
  sleep 0.2

  rc=0
  FM_TEARDOWN_REAP_GRACE_SECS=1 \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  if [ -f "$child_file" ]; then child_pid=$(cat "$child_file"); fi
  if [ -n "$child_pid" ] && kill -0 "$child_pid" 2>/dev/null; then
    child_survived=1
    kill -KILL "$child_pid" 2>/dev/null || true
  fi
  if kill -0 "$pid" 2>/dev/null; then
    parent_survived=1
    kill -KILL "$pid" 2>/dev/null || true
  fi
  expect_code 0 "$rc" "grace-spawn-convergence: teardown should converge"
  assert_present "$child_file" "grace-spawn-convergence: TERM handler did not spawn a child"
  [ "$child_survived" -eq 0 ] || fail "grace-spawn-convergence: spawned child survived"
  [ "$parent_survived" -eq 0 ] || fail "grace-spawn-convergence: original process survived"
  pass "a process spawned during grace is reaped on a later pass"
}

test_persistent_scan_refuses_after_bounded_retries() {
  local case_dir rc wt_path fake_pid=99999999
  case_dir=$(make_case persistent-reap-refusal)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  wt_path=$(cd "$case_dir/wt" && pwd -P)
  cat > "$case_dir/fakebin/lsof" <<EOF
#!/usr/bin/env bash
printf 'p%s\nfcwd\nn%s\n' '$fake_pid' '$wt_path'
EOF
  cat > "$case_dir/fakebin/ps" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = -p ] && [ "${2:-}" = "${FM_FAKE_PERSISTENT_PID:-}" ] \
   && [ "${3:-}" = -o ] && [ "${4:-}" = lstart= ]; then
  printf 'Tue Aug  4 10:00:00 2026\n'
  exit 0
fi
exec "$REAL_PS_FOR_TEST" "$@"
SH
  chmod +x "$case_dir/fakebin/lsof" "$case_dir/fakebin/ps"

  rc=0
  FM_PROC_ROOT_OVERRIDE="$case_dir/no-proc" FM_FAKE_PERSISTENT_PID="$fake_pid" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 1 "$rc" "persistent-reap-refusal: teardown should refuse"
  assert_grep "remain after 3 reap attempts" "$case_dir/stderr" \
    "persistent-reap-refusal: teardown did not report bounded non-convergence"
  assert_present "$case_dir/wt" "persistent-reap-refusal: teardown removed the worktree"
  assert_present "$case_dir/state/task-x1.meta" "persistent-reap-refusal: teardown removed task metadata"
  pass "persistent leaked processes refuse teardown after bounded retries"
}

test_process_exit_during_identity_lookup_does_not_refuse() {
  local case_dir rc wt_path fake_pid=99999998
  case_dir=$(make_case identity-exit-convergence)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  wt_path=$(cd "$case_dir/wt" && pwd -P)
  cat > "$case_dir/fakebin/lsof" <<EOF
#!/usr/bin/env bash
count=0
[ ! -f "$case_dir/lsof-count" ] || count=\$(cat "$case_dir/lsof-count")
count=\$((count + 1))
printf '%s\n' "\$count" > "$case_dir/lsof-count"
if [ "\$count" -eq 1 ]; then
  printf 'p%s\nfcwd\nn%s\n' '$fake_pid' '$wt_path'
fi
EOF
  cat > "$case_dir/fakebin/ps" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = -p ] && [ "${2:-}" = "${FM_FAKE_EXITED_PID:-}" ]; then
  exit 1
fi
exec "$REAL_PS_FOR_TEST" "$@"
SH
  cat > "$case_dir/fakebin/treehouse" <<EOF
#!/usr/bin/env bash
printf 'returned\n' > "$case_dir/treehouse.log"
EOF
  chmod +x "$case_dir/fakebin/lsof" "$case_dir/fakebin/ps" "$case_dir/fakebin/treehouse"

  rc=0
  FM_PROC_ROOT_OVERRIDE="$case_dir/no-proc" FM_FAKE_EXITED_PID="$fake_pid" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?

  expect_code 0 "$rc" "identity-exit-convergence: teardown should succeed"
  assert_present "$case_dir/treehouse.log" \
    "identity-exit-convergence: teardown did not reach worktree return"
  ! grep -q REFUSED "$case_dir/stderr" || \
    fail "identity-exit-convergence: a disappeared process caused teardown refusal"
  pass "a process exiting during identity lookup does not block teardown"
}

test_run_abort_precedes_process_reap_precedes_worktree_removal() {
  local case_dir rc head pid abort_log
  case_dir=$(make_case abort-then-reap-then-remove-order)
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  head=$(git -C "$case_dir/wt" rev-parse HEAD)
  abort_log="$case_dir/nm-abort.log"

  ( cd "$case_dir/wt" && exec sleep 300 ) &
  pid=$!
  disown
  sleep 0.3
  kill -0 "$pid" 2>/dev/null || fail "abort-then-reap-then-remove-order: setup sleeper did not start"

  # A treehouse fake that snapshots, at the exact moment the destructive
  # worktree return runs, whether the run was already aborted and whether the
  # leaked process was already reaped - direct causal proof of ordering from
  # real observed state, not a source-text or line-number correlation.
  cat > "$case_dir/fakebin/treehouse" <<EOF
#!/usr/bin/env bash
if [ -s "$abort_log" ]; then echo "abort-already-happened" >> "$case_dir/order.log"; fi
if ! kill -0 $pid 2>/dev/null; then echo "reap-already-happened" >> "$case_dir/order.log"; fi
exit 0
EOF
  chmod +x "$case_dir/fakebin/treehouse"

  rc=0
  FM_FAKE_AXI_STATUS="$(parked_axi_status_toon fm/task-x1 "$head")" \
  FM_FAKE_NM_ABORT_LOG="$abort_log" \
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 0 "$rc" "abort-then-reap-then-remove-order: teardown should still succeed"
  kill -0 "$pid" 2>/dev/null && { kill -KILL "$pid" 2>/dev/null || true; }

  assert_present "$case_dir/order.log" \
    "abort-then-reap-then-remove-order: the destructive worktree return was never invoked"
  assert_grep "abort-already-happened" "$case_dir/order.log" \
    "abort-then-reap-then-remove-order: the run was not yet aborted when the worktree return ran"
  assert_grep "reap-already-happened" "$case_dir/order.log" \
    "abort-then-reap-then-remove-order: the leaked process was not yet reaped when the worktree return ran"
  pass "the run abort and the leaked-process reap both complete before the destructive worktree return"
}

# A symlink mirror of the public teardown script tree, built once before the
# concurrent cases start: linking each of bin/'s couple of hundred entries is
# hundreds of process starts, so each case copies the mirror's links in one
# step instead and then edits only its own copy.
TEARDOWN_SOURCE_TEMPLATE="$TMP_ROOT/.teardown-source-template"
build_teardown_source_template() {  # <dest>
  local dest=$1 f base s
  mkdir -p "$dest/backends"
  for f in "$ROOT"/bin/*; do
    base=${f##*/}
    if [ -d "$f" ]; then
      mkdir -p "$dest/$base"
      for s in "$f"/*; do
        ln -s "$s" "$dest/$base/${s##*/}"
      done
    else
      ln -s "$f" "$dest/$base"
    fi
  done
}
build_teardown_source_template "$TEARDOWN_SOURCE_TEMPLATE/bin"

# Copy the public teardown script tree, then drop or blank one required file.
# Symlinks keep the copy cheap; an unreadable case replaces one link with a
# real mode-000 file so the probe is of the file itself.
prepare_teardown_source_copy() {  # <case-dir>
  local case_dir=$1
  mkdir -p "$case_dir/test-root"
  cp -a "$TEARDOWN_SOURCE_TEMPLATE/bin" "$case_dir/test-root/bin"
  printf 'manual\n' > "$case_dir/config/backlog-backend"
  cat > "$case_dir/fakebin/treehouse" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$case_dir/treehouse.log"
exit 0
SH
  chmod +x "$case_dir/fakebin/treehouse"
  : > "$case_dir/treehouse.log"
  : > "$case_dir/state/task-x1.status"
}

run_copied_teardown() {  # <case-dir> [args...]
  local case_dir=$1
  shift
  FM_TEARDOWN_GUARD_DONE=1 \
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  FM_DATA_OVERRIDE="$case_dir/data" \
  FM_CONFIG_OVERRIDE="$case_dir/config" \
  PATH="$case_dir/fakebin:$PATH" \
    "$case_dir/test-root/bin/fm-teardown.sh" task-x1 "$@"
}

assert_source_refusal_preserved_state() {  # <case-dir> <label> <stderr-needle>
  local case_dir=$1 label=$2 needle=$3
  [ "$rc" -ne 0 ] || fail "$label: teardown reported success after a required source disappeared"
  assert_grep "$needle" "$case_dir/stderr" "$label: the refusal did not name the missing source"
  [ -e "$case_dir/state/task-x1.meta" ] || fail "$label: the refusal erased task metadata"
  [ -e "$case_dir/state/task-x1.status" ] || fail "$label: the refusal erased the task status record"
  [ ! -s "$case_dir/treehouse.log" ] || fail "$label: the refusal returned the local copy: $(cat "$case_dir/treehouse.log")"
  if grep -q "teardown task-x1 complete" "$case_dir/stdout"; then
    fail "$label: the refusal still reported cleanup complete"
  fi
}

test_missing_startup_source_refuses_before_cleanup() {
  local case_dir rc
  case_dir=$(make_case missing-startup-source)
  write_meta "$case_dir" local-only ship
  prepare_teardown_source_copy "$case_dir"
  rm -f "$case_dir/test-root/bin/fm-nm-run-lib.sh"
  rc=0
  run_copied_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  assert_source_refusal_preserved_state "$case_dir" "missing-startup-source" "required source fm-nm-run-lib.sh"
  pass "a missing teardown startup source refuses before cleanup"
}

test_unreadable_startup_source_refuses_before_cleanup() {
  local case_dir rc
  case_dir=$(make_case unreadable-startup-source)
  write_meta "$case_dir" local-only ship
  prepare_teardown_source_copy "$case_dir"
  rm -f "$case_dir/test-root/bin/fm-nm-run-lib.sh"
  cp "$ROOT/bin/fm-nm-run-lib.sh" "$case_dir/test-root/bin/fm-nm-run-lib.sh"
  chmod 000 "$case_dir/test-root/bin/fm-nm-run-lib.sh"
  if [ -r "$case_dir/test-root/bin/fm-nm-run-lib.sh" ]; then
    pass "unreadable startup source skipped: this user can read mode-000 files"
    return 0
  fi
  rc=0
  run_copied_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  assert_source_refusal_preserved_state "$case_dir" "unreadable-startup-source" "required source fm-nm-run-lib.sh"
  pass "an unreadable teardown startup source refuses before cleanup"
}

test_missing_adapter_sibling_refuses_before_cleanup() {
  local case_dir rc
  case_dir=$(make_case missing-adapter-sibling)
  write_meta "$case_dir" local-only ship
  prepare_teardown_source_copy "$case_dir"
  rm -f "$case_dir/test-root/bin/fm-session-lock-lib.sh"
  rc=0
  run_copied_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  assert_source_refusal_preserved_state "$case_dir" "missing-adapter-sibling" "required tmux source"
  pass "a missing adapter sibling refuses before cleanup"
}

test_forced_child_missing_adapter_sibling_refuses_before_cleanup() {
  local case_dir home rc
  case_dir=$(make_case missing-child-adapter-sibling)
  write_meta "$case_dir" local-only secondmate
  configure_secondmate_with_herdr_child "$case_dir"
  home="$case_dir/secondmate-home"
  prepare_teardown_source_copy "$case_dir"
  rm -f "$case_dir/test-root/bin/fm-transition-lib.sh"
  rc=0
  run_copied_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  assert_source_refusal_preserved_state "$case_dir" "missing-child-source" "required herdr source"
  [ -e "$home/state/child-herdr.meta" ] || fail "missing-child-source: the refusal erased the child record"
  [ -d "$home" ] || fail "missing-child-source: the refusal removed the secondmate home"
  pass "a forced descendant with a missing adapter sibling refuses before cleanup"
}

test_forced_secondmate_own_missing_adapter_sibling_refuses_before_child_cleanup() {
  local case_dir home rc
  case_dir=$(make_case missing-own-adapter-sibling)
  fm_write_meta "$case_dir/state/task-x1.meta" \
    "window=zs:3" \
    "endpoint_task_id=task-x1" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    "kind=secondmate" \
    "mode=local-only" \
    "backend=zellij" \
    "zellij_session=zs" \
    "zellij_tab_id=1" \
    "zellij_pane_id=3" \
    "spawn_gen=teardown-test-task-x1"
  home="$case_dir/secondmate-home"
  mkdir -p "$home/state" "$home/data" "$home/config" "$home/projects"
  printf '%s\n' task-x1 > "$home/.fm-secondmate-home"
  printf '%s\n' "home=$home" >> "$case_dir/state/task-x1.meta"
  fm_write_meta "$home/state/child-tmux.meta" \
    "window=childsession:fm-child-tmux" \
    "endpoint_task_id=child-tmux" \
    "worktree=$case_dir/wt" \
    "project=$case_dir/project" \
    "kind=ship" \
    "mode=local-only"
  : > "$home/state/child-tmux.status"
  prepare_teardown_source_copy "$case_dir"
  cat > "$case_dir/fakebin/tmux" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$case_dir/tmux.log"
exit 0
SH
  chmod +x "$case_dir/fakebin/tmux"
  : > "$case_dir/tmux.log"
  rm -f "$case_dir/test-root/bin/fm-backend-hometag-lib.sh"
  rc=0
  run_copied_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  assert_source_refusal_preserved_state "$case_dir" "missing-own-source" "required zellij source"
  [ -e "$home/state/child-tmux.meta" ] || fail "missing-own-source: the refusal erased the child record"
  [ -e "$home/state/child-tmux.status" ] || fail "missing-own-source: the refusal erased the child status"
  [ -d "$home" ] || fail "missing-own-source: the refusal removed the secondmate home"
  if grep -q "kill" "$case_dir/tmux.log"; then
    fail "missing-own-source: the refusal killed the child endpoint: $(cat "$case_dir/tmux.log")"
  fi
  pass "a forced secondmate with a missing own adapter sibling refuses before child cleanup"
}

test_retained_sources_still_reach_the_ordinary_refusal() {
  local case_dir rc
  case_dir=$(make_case retained-sources)
  prepare_teardown_source_copy "$case_dir"
  rc=0
  FM_TEARDOWN_GUARD_DONE=1 \
  FM_ROOT_OVERRIDE="$ROOT" \
  FM_STATE_OVERRIDE="$case_dir/state" \
  FM_DATA_OVERRIDE="$case_dir/data" \
  FM_CONFIG_OVERRIDE="$case_dir/config" \
  PATH="$case_dir/fakebin:$PATH" \
    "$case_dir/test-root/bin/fm-teardown.sh" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  [ "$rc" -eq 2 ] || fail "retained-sources: a present source tree should still reject a request with no task id (rc=$rc)"
  assert_grep "invalid teardown request" "$case_dir/stderr" \
    "retained-sources: the ordinary refusal was replaced"
  pass "present required sources still reach the ordinary teardown refusal"
}

# Evidence preservation (bin/fm-task-evidence-lib.sh): declared evidence is
# copied out of the copy and the task's temp folder with a verified sha256
# manifest before cleanup, and a record under data/<id>/ that still points at an
# existing undeclared path inside either refuses cleanup before anything is changed.
# Evidence normally lives in ignored scratch, which the dirty-copy refusal does
# not count as uncommitted work.
ignore_workspace() {  # <case-dir>
  printf 'workspace/\n' >> "$(git -C "$1/wt" rev-parse --git-common-dir)/info/exclude"
}

evidence_manifest_verifies() {  # <evidence-dir>, including link-only snapshots
  local ev=$1 line path text actual
  [ -f "$ev/MANIFEST.sha256" ] || return 1
  if [ -s "$ev/MANIFEST.sha256" ]; then
    if command -v sha256sum >/dev/null 2>&1; then
      (cd "$ev" && sha256sum -c --quiet MANIFEST.sha256) || return 1
    else
      (cd "$ev" && shasum -a 256 -c --quiet MANIFEST.sha256) || return 1
    fi
  else
    [ -s "$ev/MANIFEST.sha256.links" ] || return 1
  fi
  [ -f "$ev/MANIFEST.sha256.links" ] || return 0
  while IFS= read -r line; do
    path=${line#*  }
    [ -L "$ev/$path" ] || return 1
    text=$(readlink "$ev/$path" && printf .) || return 1
    text=${text%.}
    if command -v sha256sum >/dev/null 2>&1; then
      actual=$(printf '%s' "$text" | sha256sum) || return 1
    else
      actual=$(printf '%s' "$text" | shasum -a 256) || return 1
    fi
    [ "${actual%% *}" = "${line%%  *}" ] || return 1
  done < "$ev/MANIFEST.sha256.links"
}

test_declared_evidence_is_copied_out_with_a_verified_manifest() {
  local case_dir rc ev
  case_dir=$(make_case evidence-copied)
  ignore_workspace "$case_dir"
  write_meta "$case_dir" no-mistakes ship
  printf '%s\n' "tasktmp=$case_dir/tasktmp" >> "$case_dir/state/task-x1.meta"
  land_shippable_commit "$case_dir"
  mkdir -p "$case_dir/wt/workspace/merge" "$case_dir/tasktmp/scratch" "$case_dir/data/task-x1"
  printf 'merge evidence\n' > "$case_dir/wt/workspace/merge/result.txt"
  printf 'clean reference\n' > "$case_dir/wt/workspace/clean-ref.txt"
  printf 'scratch log\n' > "$case_dir/tasktmp/scratch/run.log"
  printf '%s\n' '# evidence for the report' workspace \
    "$case_dir/tasktmp/scratch/run.log" > "$case_dir/data/task-x1/evidence.list"
  printf 'See %s:42 and %s:5:3.\n' "$case_dir/wt/workspace/merge/result.txt" \
    "$case_dir/tasktmp/scratch/run.log" > "$case_dir/data/task-x1/report.md"

  rc=0
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 0 "$rc" "evidence-copied: teardown should succeed: $(cat "$case_dir/stderr")"
  ev="$case_dir/data/task-x1/evidence"
  [ "$(cat "$ev/copy/workspace/merge/result.txt")" = "merge evidence" ] \
    || fail "evidence-copied: the declared copy directory was not copied out"
  [ "$(cat "$ev/copy/workspace/clean-ref.txt")" = "clean reference" ] \
    || fail "evidence-copied: a file under the declared directory was not copied out"
  [ "$(cat "$ev/tmp/scratch/run.log")" = "scratch log" ] \
    || fail "evidence-copied: the declared temp-folder file was not copied out"
  [ "$(wc -l < "$ev/MANIFEST.sha256" | tr -d ' ')" = 3 ] \
    || fail "evidence-copied: manifest should list exactly the three copied files: $(cat "$ev/MANIFEST.sha256")"
  evidence_manifest_verifies "$ev" || fail "evidence-copied: the manifest does not verify the copied evidence"
  assert_absent "$case_dir/state/task-x1.meta" "evidence-copied: teardown left the task record"
  pass "declared evidence in the copy and the task's temp folder is copied out with a verifying sha256 manifest"
}

test_prose_apostrophes_do_not_open_evidence_quotes() {
  local case_dir rc ev
  case_dir=$(make_case evidence-prose-apostrophes)
  ignore_workspace "$case_dir"
  write_meta "$case_dir" no-mistakes ship
  printf 'tasktmp=%s/tasktmp\n' "$case_dir" >> "$case_dir/state/task-x1.meta"
  land_shippable_commit "$case_dir"
  mkdir -p "$case_dir/wt/workspace" "$case_dir/tasktmp" "$case_dir/data/task-x1"
  printf 'copy evidence\n' > "$case_dir/wt/workspace/log.txt"
  printf 'temp evidence\n' > "$case_dir/tasktmp/log.txt"
  printf '%s\n' workspace/log.txt "$case_dir/tasktmp/log.txt" > "$case_dir/data/task-x1/evidence.list"
  {
    printf "The agent's log is at %s/log.txt\n" "$case_dir/tasktmp"
    printf "Don't lose %s/workspace/log.txt\n" "$case_dir/wt"
    printf "The agent's log is at '%s/log.txt'\n" "$case_dir/tasktmp"
    printf 'The agent\047s log is at "%s/log.txt"\n' "$case_dir/tasktmp"
    printf "The agent's log is at \`%s/log.txt\`\n" "$case_dir/tasktmp"
  } > "$case_dir/data/task-x1/report.md"
  rc=0
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 0 "$rc" "prose apostrophes must not make declared paths ambiguous: $(cat "$case_dir/stderr")"
  ev="$case_dir/data/task-x1/evidence"
  [ "$(cat "$ev/tmp/log.txt")" = 'temp evidence' ] || fail 'prose citation lost tasktmp evidence'
  [ "$(cat "$ev/copy/workspace/log.txt")" = 'copy evidence' ] || fail 'prose citation lost copy evidence'
  evidence_manifest_verifies "$ev" || fail 'prose citation evidence does not verify'
  assert_absent "$case_dir/state/task-x1.meta" 'prose citation prevented teardown'
  pass 'word-internal prose apostrophes allow declared tasktmp and copy citations, including actual quoted paths'
}

test_undeclared_reference_into_the_copy_refuses_then_declaring_it_proceeds() {
  local case_dir rc
  case_dir=$(make_case evidence-dangling)
  ignore_workspace "$case_dir"
  write_meta "$case_dir" no-mistakes ship
  printf '%s\n' "tasktmp=$case_dir/tasktmp" >> "$case_dir/state/task-x1.meta"
  land_shippable_commit "$case_dir"
  mkdir -p "$case_dir/wt/workspace" "$case_dir/tasktmp" "$case_dir/data/task-x1/notes"
  printf 'unique\n' > "$case_dir/wt/workspace/review.txt"
  printf 'scratch\n' > "$case_dir/tasktmp/out.txt"
  printf 'Evidence: %s:42.\n' "$case_dir/wt/workspace/review.txt" > "$case_dir/data/task-x1/report.md"
  printf 'log (%s:5:3)\n' "$case_dir/tasktmp/out.txt" > "$case_dir/data/task-x1/notes/n.md"
  # A mention of the copy's root itself names no file inside it.
  printf 'Worked in %s/ today.\n' "$case_dir/wt" > "$case_dir/data/task-x1/brief.md"

  for flag in "" --force; do
    rc=0
    run_teardown "$case_dir" ${flag:+"$flag"} > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
    [ "$rc" -ne 0 ] || fail "evidence-dangling: teardown ${flag:-without --force} proceeded with a dangling reference"
    assert_grep "references $case_dir/wt/workspace/review.txt," "$case_dir/stderr" \
      "evidence-dangling: refusal did not name the copy reference: $(cat "$case_dir/stderr")"
    assert_grep "references $case_dir/tasktmp/out.txt," "$case_dir/stderr" \
      "evidence-dangling: refusal did not name the temp-folder reference: $(cat "$case_dir/stderr")"
    if grep -qF "references $case_dir/wt/ " "$case_dir/stderr" \
       || grep -qF "references $case_dir/wt," "$case_dir/stderr"; then
      fail "evidence-dangling: a mention of the copy root itself was treated as a dangling reference"
    fi
    assert_present "$case_dir/state/task-x1.meta" "evidence-dangling: refusal removed the task record"
    assert_present "$case_dir/wt/workspace/review.txt" "evidence-dangling: refusal touched the copy"
    assert_absent "$case_dir/data/task-x1/evidence" "evidence-dangling: refusal installed a partial evidence copy"
  done

  printf '%s\n' workspace/review.txt "$case_dir/tasktmp/out.txt" > "$case_dir/data/task-x1/evidence.list"
  rc=0
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 0 "$rc" "evidence-dangling: teardown should proceed once the references are declared: $(cat "$case_dir/stderr")"
  [ "$(cat "$case_dir/data/task-x1/evidence/copy/workspace/review.txt")" = unique ] \
    || fail "evidence-dangling: the declared reference was not copied out"
  pass "a record referencing an undeclared path inside the copy or temp folder refuses cleanup (even with --force) until it is declared"
}

test_html_entities_delimit_declared_evidence_references() {
  local case_dir rc entity path
  case_dir=$(make_case evidence-html-declared)
  ignore_workspace "$case_dir"
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  mkdir -p "$case_dir/wt/workspace" "$case_dir/data/task-x1"
  printf 'html evidence\n' > "$case_dir/wt/workspace/x"
  printf '%s\n' workspace/x > "$case_dir/data/task-x1/evidence.list"
  for entity in '&quot;' '&amp;' '&lt;' '&gt;' '&apos;' '&#34;' '&#x22;' '&#X2A;'; do
    printf '<pre>H=%s%s/workspace/x%s</pre>\n' "$entity" "$case_dir/wt" "$entity"
    printf '<pre>%s%s/workspace/x:42:5%s</pre>\n' "$entity" "$case_dir/wt" "$entity"
  done > "$case_dir/data/task-x1/report.html"
  # A literal ampersand or an incomplete/invalid entity remains part of a path.
  for path in 'x&literal' 'x&quot' 'x&#xZZ'; do
    printf 'literal evidence\n' > "$case_dir/wt/workspace/$path"
    printf 'workspace/%s\n' "$path" >> "$case_dir/data/task-x1/evidence.list"
    printf '<pre>H=&quot;%s/workspace/%s&quot;</pre>\n' "$case_dir/wt" "$path" \
      >> "$case_dir/data/task-x1/report.html"
  done
  rc=0
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 0 "$rc" "html-declared: escaped references should be covered: $(cat "$case_dir/stderr")"
  [ "$(cat "$case_dir/data/task-x1/evidence/copy/workspace/x")" = 'html evidence' ] \
    || fail "html-declared: referenced evidence was not preserved"
  evidence_manifest_verifies "$case_dir/data/task-x1/evidence" \
    || fail "html-declared: preserved evidence does not verify"
  assert_absent "$case_dir/state/task-x1.meta" "html-declared: teardown left the task record"
  pass "named and numeric HTML entities delimit declared paths without truncating literal ampersands"
}

test_html_entities_do_not_hide_undeclared_evidence_references() {
  local case_dir rc entity flag n=0
  case_dir=$(make_case evidence-html-undeclared)
  ignore_workspace "$case_dir"
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  mkdir -p "$case_dir/wt/workspace" "$case_dir/data/task-x1"
  printf 'declared\n' > "$case_dir/wt/workspace/x"
  printf '%s\n' workspace/x > "$case_dir/data/task-x1/evidence.list"
  for entity in '&quot;' '&amp;' '&lt;' '&gt;' '&apos;' '&#34;' '&#x22;' '&#X2A;'; do
    n=$((n + 1))
    printf 'uncovered\n' > "$case_dir/wt/workspace/uncovered-$n"
    printf '<pre>H=%s%s/workspace/uncovered-%s%s</pre>\n' "$entity" "$case_dir/wt" "$n" "$entity"
  done > "$case_dir/data/task-x1/report.html"
  for flag in '' --force; do
    rc=0
    run_teardown "$case_dir" ${flag:+"$flag"} > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
    [ "$rc" -ne 0 ] || fail "html-undeclared: escaped dangling references allowed cleanup ${flag:-without --force}"
    for n in 1 2 3 4 5 6 7 8; do
      assert_grep "references $case_dir/wt/workspace/uncovered-$n," "$case_dir/stderr" \
        "html-undeclared: refusal did not name the path without its entity suffix"
      assert_present "$case_dir/wt/workspace/uncovered-$n" "html-undeclared: refusal touched evidence"
    done
    assert_present "$case_dir/state/task-x1.meta" "html-undeclared: refusal removed the task record"
    assert_absent "$case_dir/data/task-x1/evidence" "html-undeclared: refusal installed a partial snapshot"
  done
  pass "HTML-escaped uncovered paths still refuse cleanup, including with --force"
}

test_clean_tracked_source_citations_need_no_evidence_declaration() {
  local case_dir rc
  case_dir=$(make_case evidence-tracked-clean)
  write_meta "$case_dir" no-mistakes ship
  wt_commit_file "$case_dir" source.c 'int main(void) { return 0; }'
  land_shippable_commit "$case_dir"
  mkdir -p "$case_dir/data/task-x1"
  printf 'Source: %s:42 and %s:5:3.\n' "$case_dir/wt/source.c" "$case_dir/wt/source.c" \
    > "$case_dir/data/task-x1/report.md"
  rc=0
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 0 "$rc" "clean tracked citations should not require declarations: $(cat "$case_dir/stderr")"
  assert_absent "$case_dir/state/task-x1.meta" "clean citations left task record"
  assert_absent "$case_dir/data/task-x1/evidence" "clean citations should not create snapshots"
  pass "clean tracked source file:line and file:line:column citations do not block cleanup"
}

test_unrecoverable_copy_citations_still_refuse_even_with_force() {
  local case_dir rc variant file
  for variant in modified assume-unchanged skip-worktree staged-add untracked ignored; do
    case_dir=$(make_case "evidence-unrecoverable-$variant")
    write_meta "$case_dir" no-mistakes ship
    wt_commit_file "$case_dir" source.c 'original source'
    land_shippable_commit "$case_dir"
    file=source.c
    case "$variant" in
      modified) printf 'local change\n' > "$case_dir/wt/$file" ;;
      assume-unchanged|skip-worktree)
        git -C "$case_dir/wt" update-index "--$variant" -- "$file"
        printf 'hidden local change\n' > "$case_dir/wt/$file"
        ;;
      staged-add|untracked)
        file=new.c
        printf 'new source\n' > "$case_dir/wt/$file"
        [ "$variant" != staged-add ] || git -C "$case_dir/wt" add -- "$file"
        ;;
      ignored)
        ignore_workspace "$case_dir"
        file=workspace/review.txt
        mkdir -p "$case_dir/wt/workspace"
        printf 'unique review\n' > "$case_dir/wt/$file"
        ;;
    esac
    mkdir -p "$case_dir/data/task-x1"
    printf 'Evidence: %s/%s:42:3.\n' "$case_dir/wt" "$file" > "$case_dir/data/task-x1/report.md"
    rc=0
    run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
    [ "$rc" -ne 0 ] || fail "$variant source citation bypassed evidence refusal"
    assert_grep "references $case_dir/wt/$file," "$case_dir/stderr" \
      "$variant source citation should refuse as undeclared evidence: $(cat "$case_dir/stderr")"
    assert_present "$case_dir/state/task-x1.meta" "$variant refusal removed task record"
    assert_absent "$case_dir/data/task-x1/evidence" "$variant refusal installed a snapshot"
  done
  pass "untracked, ignored, added and modified source citations refuse, including hidden modifications and --force"
}

test_evidence_declaration_outside_the_task_roots_refuses() {
  local case_dir rc entry
  case_dir=$(make_case evidence-outside)
  ignore_workspace "$case_dir"
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  mkdir -p "$case_dir/data/task-x1" "$case_dir/elsewhere"
  printf 'x\n' > "$case_dir/elsewhere/f"
  mkdir -p "$case_dir/wt/workspace"
  for entry in "$case_dir/elsewhere/f" "workspace/../../elsewhere/f" workspace/missing.txt; do
    printf '%s\n' "$entry" > "$case_dir/data/task-x1/evidence.list"
    rc=0
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
    [ "$rc" -ne 0 ] || fail "evidence-outside: teardown accepted the evidence entry '$entry'"
    grep -q '^REFUSED: .*evidence' "$case_dir/stderr" \
      || fail "evidence-outside: refusal for '$entry' did not name the evidence entry: $(cat "$case_dir/stderr")"
    assert_present "$case_dir/state/task-x1.meta" "evidence-outside: refusal removed the task record"
  done
  pass "an evidence entry outside the copy or temp folder, escaping by .., or a missing path refuses cleanup"
}

test_missing_evidence_citations_warn_and_allow_cleanup() {
  local case_dir rc variant flag copy_cite
  for variant in scratch deleted; do
    case_dir=$(make_case "evidence-missing-$variant")
    write_meta "$case_dir" no-mistakes ship
    printf 'tasktmp=%s/tasktmp\n' "$case_dir" >> "$case_dir/state/task-x1.meta"
    wt_commit_file "$case_dir" source.c original
    land_shippable_commit "$case_dir"
    flag=
    copy_cite="$case_dir/wt/workspace/gone.log"
    if [ "$variant" = deleted ]; then
      rm "$case_dir/wt/source.c"; flag=--force; copy_cite="$case_dir/wt/source.c"
    fi
    mkdir -p "$case_dir/data/task-x1"
    printf 'See %s:42:3 and %s:2.\n' "$copy_cite" "$case_dir/tasktmp/gone.log" \
      > "$case_dir/data/task-x1/report.md"
    printf 'Also "%s/quoted missing,(proof).txt"\n' "$case_dir/tasktmp" >> "$case_dir/data/task-x1/report.md"
    rc=0
    run_teardown "$case_dir" ${flag:+"$flag"} > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
    expect_code 0 "$rc" "missing citations should not refuse: $(cat "$case_dir/stderr")"
    assert_grep "record $case_dir/data/task-x1/report.md references missing path $case_dir/tasktmp/gone.log; there is nothing left to save" \
      "$case_dir/stderr" "missing citation warning should name record and path"
    assert_grep "references missing path $copy_cite; there is nothing left to save" \
      "$case_dir/stderr" "missing scratch or deleted tracked citation should warn too"
    assert_grep "references missing path $case_dir/tasktmp/quoted missing,(proof).txt; there is nothing left to save" \
      "$case_dir/stderr" 'complete missing quoted path should warn'
    assert_absent "$case_dir/state/task-x1.meta" "missing citations left task metadata"
  done
  pass "missing copy and tasktmp citations warn with record and path instead of refusing"
}

test_declared_evidence_links_are_preserved_without_following() {
  local case_dir rc ev name
  case_dir=$(make_case evidence-links)
  ignore_workspace "$case_dir"
  write_meta "$case_dir" no-mistakes ship
  printf 'tasktmp=%s/tasktmp\n' "$case_dir" >> "$case_dir/state/task-x1.meta"
  wt_commit_file "$case_dir" source.c original
  land_shippable_commit "$case_dir"
  mkdir -p "$case_dir/wt/workspace/links" "$case_dir/tasktmp" "$case_dir/outside" "$case_dir/data/task-x1"
  printf 'target\n' > "$case_dir/wt/workspace/target"
  mkdir -p "$case_dir/wt/workspace/target-dir"
  printf 'directory member\n' > "$case_dir/wt/workspace/target-dir/member"
  ln -s "$case_dir/wt/workspace/target" "$case_dir/outside/intermediate"
  ln -s "$case_dir/outside/intermediate" "$case_dir/wt/workspace/links/chain"
  ln -s ../target-dir "$case_dir/wt/workspace/links/directory"
  printf 'temp target\n' > "$case_dir/tasktmp/target"
  printf 'outside\n' > "$case_dir/outside/target"
  ln -s ../target "$case_dir/wt/workspace/links/relative"
  ln -s "$case_dir/tasktmp/target" "$case_dir/wt/workspace/links/temp"
  ln -s "$case_dir/outside/target" "$case_dir/wt/workspace/links/outside"
  ln -s "$case_dir/wt/source.c" "$case_dir/wt/workspace/links/tracked"
  ln -s absent "$case_dir/wt/workspace/links/dangling"
  ln -s / "$case_dir/wt/workspace/links/filesystem-root"
  ln -s "$case_dir/outside/target" "$case_dir/wt/workspace/top-link"
  ln -s absent "$case_dir/wt/workspace/top-dangling"
  printf '%s\n' workspace/links workspace/top-link workspace/top-dangling workspace/target workspace/target-dir "$case_dir/tasktmp/target" \
    > "$case_dir/data/task-x1/evidence.list"
  rc=0
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 0 "$rc" "safe evidence links should allow cleanup: $(cat "$case_dir/stderr")"
  ev="$case_dir/data/task-x1/evidence"
  for name in relative temp outside tracked dangling chain directory filesystem-root; do
    [ -L "$ev/copy/workspace/links/$name" ] || fail "evidence link $name was followed or lost"
    assert_grep "preserving evidence symlink $case_dir/wt/workspace/links/$name as a link" \
      "$case_dir/stderr" "link warning should name $name"
  done
  [ "$(readlink "$ev/copy/workspace/links/relative")" = ../target ] || fail "relative link text changed"
  [ "$(readlink "$ev/copy/workspace/links/temp")" = "$case_dir/tasktmp/target" ] || fail "absolute link text changed"
  [ -L "$ev/copy/workspace/top-link" ] || fail "directly declared link was not preserved"
  [ -L "$ev/copy/workspace/top-dangling" ] || fail "directly declared dangling link was not preserved"
  [ "$(cat "$ev/copy/workspace/target")" = target ] || fail "declared link target not preserved"
  [ "$(cat "$ev/tmp/target")" = 'temp target' ] || fail "temp target not preserved"
  [ "$(cat "$ev/copy/workspace/target-dir/member")" = 'directory member' ] || fail 'declared directory target not preserved'
  [ "$(wc -l < "$ev/MANIFEST.sha256.links" | tr -d ' ')" = 10 ] || fail "link manifest missing entries"
  evidence_manifest_verifies "$ev" || fail "regular manifest should verify without following links"
  pass "declared directory and standalone symlinks preserve link text, warn, and never copy outside targets"
}

# A copied directory link is not a snapshot of anything reached through it.
# Both callers must classify the actual surviving object, not a lexical prefix.
# Each force mode gets a fresh fixture because successful teardown consumes it.
test_citation_and_link_target_coverage_requires_surviving_objects() {
  local case_dir root_name mode variant flag base target citation rc ev expected label head_blob
  for root_name in copy tmp; do
    for mode in citation link-target; do
      for variant in undeclared declared declared-alias tracked outside; do
        for flag in '' --force; do
          case_dir=$(make_case "evidence-object-$root_name-$mode-$variant-${flag:-normal}")
          ignore_workspace "$case_dir"
          write_meta "$case_dir" no-mistakes ship
          printf 'tasktmp=%s/tasktmp\n' "$case_dir" >> "$case_dir/state/task-x1.meta"
          wt_commit_file "$case_dir" source.c original
          land_shippable_commit "$case_dir"
          head_blob=$(git -C "$case_dir/wt" rev-parse HEAD:source.c)
          mkdir -p "$case_dir/wt/workspace" "$case_dir/tasktmp" "$case_dir/outside" "$case_dir/data/task-x1"
          if [ "$root_name" = copy ]; then
            base="$case_dir/wt/workspace"; label=copy/workspace
          else
            base="$case_dir/tasktmp"; label=tmp
          fi
          mkdir -p "$base/links" "$base/content"
          printf 'unique target\n' > "$base/content/proof"
          printf 'outside target\n' > "$case_dir/outside/proof"
          target="$base/content/proof"
          expected='unique target'
          case "$variant" in
            tracked) target="$case_dir/wt/source.c"; expected=original ;;
            outside) target="$case_dir/outside/proof"; expected='outside target' ;;
          esac
          ln -s / "$base/links/filesystem-root"
          citation="$base/links/filesystem-root$target"
          printf '%s\n' "$base/links" > "$case_dir/data/task-x1/evidence.list"
          case "$variant" in
            declared) printf '%s\n' "$target" >> "$case_dir/data/task-x1/evidence.list" ;;
            declared-alias)
              # An independently copied alias/file really does preserve bytes,
              # unlike declaring the directory link itself or its ancestor.
              ln -s content "$base/alias"
              printf '%s\n' "$base/alias/proof" >> "$case_dir/data/task-x1/evidence.list" ;;
          esac
          if [ "$mode" = citation ]; then
            printf 'See %s\n' "$citation" > "$case_dir/data/task-x1/report.md"
          else
            ln -s "$citation" "$base/links/indirect"
          fi
          rc=0
          run_teardown "$case_dir" ${flag:+"$flag"} > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
          ev="$case_dir/data/task-x1/evidence"
          if [ "$variant" = undeclared ]; then
            if [ "$rc" -eq 0 ]; then
              printf 'Unexpected coverage success: %s %s %s\n' "$root_name" "$mode" "${flag:-normal}" >&2
              cat "$case_dir/stdout" "$case_dir/stderr" >&2
              fail "$root_name $mode ${flag:-normal}: declared link ancestry covered an unpreserved target"
            fi
            if [ "$mode" = citation ]; then
              assert_grep "references $citation, which cleanup would destroy" "$case_dir/stderr" 'traversed citation must refuse'
            else
              assert_grep "evidence symlink $base/links/indirect resolves to $target, which cleanup would destroy" \
                "$case_dir/stderr" 'indirect link target must refuse'
            fi
            assert_present "$case_dir/state/task-x1.meta" 'object coverage refusal removed metadata'
            assert_absent "$ev" 'object coverage refusal installed partial evidence'
          else
            expect_code 0 "$rc" "$root_name $mode $variant ${flag:-normal}: preserved/outside target refused: $(cat "$case_dir/stderr")"
            [ -L "$ev/$label/links/filesystem-root" ] || fail 'filesystem-root link was followed or lost'
            [ "$(readlink "$ev/$label/links/filesystem-root")" = / ] || fail 'filesystem-root link text changed'
            assert_grep "preserving evidence symlink $base/links/filesystem-root as a link" "$case_dir/stderr" 'preserved link must warn'
            if [ "$mode" = link-target ]; then
              [ -L "$ev/$label/links/indirect" ] || fail 'indirect link was lost'
              [ "$(readlink "$ev/$label/links/indirect")" = "$citation" ] || fail 'indirect link text changed'
            fi
            case "$variant" in
              declared) [ "$(cat "$ev/$label/content/proof")" = "$expected" ] || fail 'declared target bytes lost' ;;
              declared-alias) [ "$(cat "$ev/$label/alias/proof")" = "$expected" ] || fail 'separately declared alias content lost' ;;
              outside) [ "$(cat "$target")" = "$expected" ] || fail 'outside target changed' ;;
              tracked) [ "$(git -C "$case_dir/project" cat-file blob "$head_blob")" = "$expected" ] || fail 'tracked source not recoverable' ;;
            esac
            evidence_manifest_verifies "$ev" || fail "$root_name $mode $variant ${flag:-normal}: object coverage snapshot does not verify"
            assert_absent "$case_dir/state/task-x1.meta" 'safe target left task metadata'
          fi
        done
      done
    done
  done
  pass 'citations and link targets require actual preserved content or git recovery, across both roots and force modes'
}

test_empty_evidence_roots_do_not_claim_the_working_directory() {
  local case_dir missing target_kind copy_root tmp_root root target rc ev
  for missing in copy tmp; do
    for target_kind in directory file; do
      case_dir=$(make_case "evidence-empty-$missing-$target_kind")
      copy_root="$case_dir/wt"
      tmp_root="$case_dir/tasktmp"
      if [ "$missing" = copy ]; then
        copy_root=; root=$tmp_root
      else
        tmp_root=; root=$copy_root
      fi
      mkdir -p "$root/workspace" "$case_dir/outside" "$case_dir/data/task-x1"
      printf 'outside target\n' > "$case_dir/outside/target"
      target="$case_dir/outside"
      [ "$target_kind" = directory ] || target="$target/target"
      ln -s "$target" "$root/workspace/link"
      printf '%s\n' "$root/workspace/link" > "$case_dir/data/task-x1/evidence.list"
      rc=0
      # Some supported bash versions accept cd "" as a no-op. Exercise that
      # behavior deterministically even when this runner's bash rejects it.
      bash -c '
        cd() { if [ "${3-unset}" = "" ]; then return 0; fi; builtin cd "$@"; }
        builtin cd "$5" || exit 1
        . "$1"
        fm_task_evidence_preserve task-x1 "$2" "$3" 1 "$4"
      ' _ "$ROOT/bin/fm-task-evidence-lib.sh" "$case_dir/data" "$copy_root" "$tmp_root" "$case_dir/outside" \
        > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
      expect_code 0 "$rc" "empty $missing root claimed outside $target_kind: $(cat "$case_dir/stderr")"
      if [ "$missing" = copy ]; then ev=tmp; else ev=copy; fi
      ev="$case_dir/data/task-x1/evidence/$ev/workspace/link"
      [ -L "$ev" ] || fail "empty $missing root lost preserved link"
      [ "$(readlink "$ev")" = "$target" ] || fail 'outside link text changed'
      assert_grep "preserving evidence symlink $root/workspace/link as a link" "$case_dir/stderr" 'outside link must warn'
      [ "$(cat "$case_dir/outside/target")" = 'outside target' ] || fail 'outside target changed'
    done
  done
  pass 'an absent copy or temp root never claims cwd or its descendants as disposable link targets'
}

test_unsafe_evidence_links_and_fifos_refuse_even_with_force() {
  local case_dir rc variant flag
  for variant in copy tmp fifo dangling-citation; do
    case_dir=$(make_case "evidence-unsafe-$variant")
    ignore_workspace "$case_dir"
    write_meta "$case_dir" no-mistakes ship
    printf 'tasktmp=%s/tasktmp\n' "$case_dir" >> "$case_dir/state/task-x1.meta"
    land_shippable_commit "$case_dir"
    mkdir -p "$case_dir/wt/workspace/links" "$case_dir/tasktmp" "$case_dir/data/task-x1"
    printf '%s\n' workspace/links > "$case_dir/data/task-x1/evidence.list"
    case "$variant" in
      copy)
        printf 'unique\n' > "$case_dir/wt/workspace/uncovered"
        ln -s ../uncovered "$case_dir/wt/workspace/links/link" ;;
      tmp)
        printf 'unique\n' > "$case_dir/tasktmp/uncovered"
        ln -s "$case_dir/tasktmp/uncovered" "$case_dir/wt/workspace/links/link" ;;
      fifo) mkfifo "$case_dir/wt/workspace/links/pipe" ;;
      dangling-citation)
        ln -s absent "$case_dir/wt/workspace/uncovered"
        printf 'See %s\n' "$case_dir/wt/workspace/uncovered" > "$case_dir/data/task-x1/report.md" ;;
    esac
    for flag in '' --force; do
      rc=0
      run_teardown "$case_dir" ${flag:+"$flag"} > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
      [ "$rc" -ne 0 ] || fail "$variant evidence guard bypassed ${flag:-without force}"
      case "$variant" in
        copy|tmp)
          assert_grep "evidence symlink $case_dir/wt/workspace/links/link resolves to" \
            "$case_dir/stderr" "unsafe target refusal must name link"
          assert_grep 'uncovered, which cleanup would destroy' \
            "$case_dir/stderr" "unsafe target refusal must name target" ;;
        fifo) assert_grep 'not a regular file or directory' "$case_dir/stderr" "fifo should refuse" ;;
        dangling-citation) assert_grep "references $case_dir/wt/workspace/uncovered," \
          "$case_dir/stderr" "dangling symlink must not count as missing" ;;
      esac
      assert_present "$case_dir/state/task-x1.meta" "unsafe evidence removed task metadata"
      assert_absent "$case_dir/data/task-x1/evidence" "unsafe evidence installed a partial snapshot"
    done
  done
  pass "existing undeclared copy and tmp link targets, fifos and undeclared dangling links refuse even with force"
}

test_link_only_evidence_installs_a_snapshot() {
  local case_dir rc ev
  case_dir=$(make_case evidence-link-only)
  ignore_workspace "$case_dir"
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  mkdir -p "$case_dir/wt/workspace" "$case_dir/data/task-x1" "$case_dir/outside"
  ln -s "$case_dir/outside" "$case_dir/wt/workspace/link"
  printf '%s\n' workspace/link > "$case_dir/data/task-x1/evidence.list"
  rc=0
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 0 "$rc" "link-only declaration should install evidence: $(cat "$case_dir/stderr")"
  ev="$case_dir/data/task-x1/evidence"
  [ -L "$ev/copy/workspace/link" ] || fail "empty regular manifest discarded link-only evidence"
  [ "$(readlink "$ev/copy/workspace/link")" = "$case_dir/outside" ] || fail "directory target was followed"
  [ -s "$ev/MANIFEST.sha256.links" ] || fail "link-only evidence has no link manifest"
  [ ! -s "$ev/MANIFEST.sha256" ] || fail "directory symlink should not hash target files"
  pass "a standalone directory symlink installs verified link-only evidence without following its target"
}

test_retried_cleanup_verifies_link_only_evidence() {
  local case_dir rc ev hash flag
  case_dir=$(make_case evidence-carry-link)
  ignore_workspace "$case_dir"
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  ev="$case_dir/data/task-x1/evidence"
  mkdir -p "$ev/copy/workspace" "$case_dir/wt/workspace"
  ln -s "$case_dir/wt/workspace/uncovered" "$ev/copy/workspace/link"
  hash=$(readlink "$ev/copy/workspace/link" | { sha256sum 2>/dev/null || shasum -a 256; } | awk '{print $1}')
  : > "$ev/MANIFEST.sha256"
  printf '%s  copy/workspace/link\n' "$hash" > "$ev/MANIFEST.sha256.links"
  printf '%s\n' workspace/link > "$case_dir/data/task-x1/evidence.list"
  mv "$ev/MANIFEST.sha256.links" "$case_dir/prior-links"
  : > "$ev/MANIFEST.sha256.links"
  for flag in '' --force; do
    rc=0
    run_teardown "$case_dir" ${flag:+"$flag"} > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
    [ "$rc" -ne 0 ] || fail 'unmanifested prior link was accepted'
    assert_grep 'no verified earlier copy' "$case_dir/stderr" 'prior key needs a matching manifest entry'
    [ -L "$ev/copy/workspace/link" ] || fail 'unmanifested prior refusal removed earlier link'
    assert_present "$case_dir/state/task-x1.meta" 'unmanifested prior refusal removed metadata'
  done
  mv "$case_dir/prior-links" "$ev/MANIFEST.sha256.links"
  printf 'still exists\n' > "$case_dir/wt/workspace/uncovered"
  rc=0
  run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  [ "$rc" -ne 0 ] || fail "carried link orphaned an existing target"
  assert_grep 'uncovered, which cleanup would destroy' "$case_dir/stderr" "carried link should check its original target"
  rm "$case_dir/wt/workspace/uncovered" "$ev/copy/workspace/link"
  ln -s tampered "$ev/copy/workspace/link"
  rc=0
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  [ "$rc" -ne 0 ] || fail "tampered carried link was accepted"
  assert_grep 'no verified earlier copy' "$case_dir/stderr" "tampered link should fail verification"
  rm "$ev/copy/workspace/link"
  ln -s "$case_dir/wt/workspace/uncovered" "$ev/copy/workspace/link"
  rc=0
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 0 "$rc" "verified link-only evidence should survive retry: $(cat "$case_dir/stderr")"
  [ -L "$ev/copy/workspace/link" ] || fail "retry lost the prior dangling link"
  [ "$(readlink "$ev/copy/workspace/link")" = "$case_dir/wt/workspace/uncovered" ] || fail "retry changed prior link text"
  assert_grep 'preserving earlier evidence symlink' "$case_dir/stderr" "carried link should warn"
  pass "link-only evidence carries forward only while its link text verifies and no undeclared target is at risk"
}

# An exact entry must win over presentation suffixes, and quoted entries must
# never degrade to an absent whitespace/delimiter prefix. Exercise both roots.
# Each suffix cut must check the numeric-colon filename, not jump to a
# missing or already-covered shorter base. The matching declaration is the
# smallest success counterfactual; genuine missing numeric citations still warn.
test_numeric_citation_suffixes_check_intermediate_entries() {
  local case_dir root_name shorter suffix flag base path label rc ev
  for root_name in copy tmp; do
    for shorter in missing covered; do
      for suffix in :3 :3:9 :3:9. ':3&amp;' '&amp;' '&#34;' '&#x22;'; do
        for flag in '' --force; do
          # Keep presentation syntax out of the root itself: a colon in an
          # absent unquoted filename is deliberately ambiguous to the parser.
          case_dir=$(make_case "evidence-numeric-$root_name-$shorter-${suffix//[^a-zA-Z0-9]/_}-${flag:-normal}")
          ignore_workspace "$case_dir"
          write_meta "$case_dir" no-mistakes ship
          printf 'tasktmp=%s/tasktmp\n' "$case_dir" >> "$case_dir/state/task-x1.meta"
          land_shippable_commit "$case_dir"
          mkdir -p "$case_dir/wt/workspace" "$case_dir/tasktmp" "$case_dir/data/task-x1"
          if [ "$root_name" = copy ]; then base="$case_dir/wt/workspace"; label=copy/workspace
          else base="$case_dir/tasktmp"; label=tmp; fi
          path="$base/proof:42"
          printf 'numeric name\n' > "$path"
          : > "$case_dir/data/task-x1/evidence.list"
          if [ "$shorter" = covered ]; then
            printf 'short base\n' > "$base/proof"
            printf '%s\n' "$base/proof" >> "$case_dir/data/task-x1/evidence.list"
          fi
          printf 'See %s%s\n' "$path" "$suffix" > "$case_dir/data/task-x1/report.md"
          rc=0
          run_teardown "$case_dir" ${flag:+"$flag"} > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
          [ "$rc" -ne 0 ] || fail "$root_name $shorter $suffix ${flag:-normal}: skipped numeric filename"
          assert_grep "references $path, which cleanup would destroy" "$case_dir/stderr" 'intermediate numeric entry must refuse'
          if grep -q 'there is nothing left to save' "$case_dir/stderr"; then fail 'existing numeric citation warned missing'; fi
          [ "$(cat "$path")" = 'numeric name' ] || fail 'numeric refusal changed source'
          assert_present "$case_dir/state/task-x1.meta" 'numeric refusal removed metadata'
          ev="$case_dir/data/task-x1/evidence"
          assert_absent "$ev" 'numeric refusal installed partial evidence'
          printf '%s\n' "$path" >> "$case_dir/data/task-x1/evidence.list"
          printf 'See %s/absent:42:3.\n' "$base" >> "$case_dir/data/task-x1/report.md"
          rc=0
          run_teardown "$case_dir" ${flag:+"$flag"} > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
          expect_code 0 "$rc" "declared numeric name refused: $(cat "$case_dir/stderr")"
          [ "$(cat "$ev/$label/proof:42")" = 'numeric name' ] || fail 'declared numeric bytes lost'
          assert_grep "missing path $base/absent; there is nothing left to save" "$case_dir/stderr" 'missing numeric control must warn'
          evidence_manifest_verifies "$ev" || fail 'numeric snapshot does not verify'
          assert_absent "$case_dir/state/task-x1.meta" 'numeric success left metadata'
        done
      done
    done
  done
  pass 'every numeric suffix cut checks intermediate entries before a missing or covered base'
}

# Reach the shared object resolver, not the earlier link-target reader.
# The declaration case injects at pwd only after copy-out; the linked list is
# outside the record scan so a separate citation cannot mask that refusal.
test_object_resolution_failures_preserve_source_and_prior_snapshot() {
  local case_dir root_name variant base citation target physical_parent flag rc ev real_cp
  real_cp=$(command -v cp)
  for root_name in copy tmp; do
    for variant in citation declaration identity; do
      case_dir=$(make_case "evidence-object-failure-$root_name-$variant")
      ignore_workspace "$case_dir"
      write_meta "$case_dir" no-mistakes ship
      printf 'tasktmp=%s/tasktmp\n' "$case_dir" >> "$case_dir/state/task-x1.meta"
      land_shippable_commit "$case_dir"
      ev="$case_dir/data/task-x1/evidence"
      mkdir -p "$case_dir/wt/workspace" "$case_dir/tasktmp" "$ev"
      printf 'prior snapshot\n' > "$ev/sentinel"
      if [ "$root_name" = copy ]; then base="$case_dir/wt/workspace"; else base="$case_dir/tasktmp"; fi
      if [ "$variant" = citation ]; then
        target="$base/physical"$'\n'
        mkdir -p "$target"
        printf 'unpreserved target\n' > "$target/proof"
        ln -s "$target" "$base/alias"
        citation="$base/alias/proof"
      elif [ "$variant" = identity ]; then
        target=$base
        printf 'unpreserved target\n' > "$target/proof"
        citation="$target/proof"
        physical_parent=$(cd -P -- "$target" && pwd -P)
        # A broken pwd result must not be normalized into an outside object.
        # This sibling path is deliberately absent and outside both roots.
        cat > "$case_dir/pwd-fault.sh" <<SH
if [ "\${0##*/}" = fm-teardown.sh ]; then
  pwd() {
    if [ "\$PWD" = "$physical_parent" ]; then
      : > "$case_dir/fault-seen"
      printf '/%s/unresolvable\\n' "$case_dir"
    else builtin pwd "\$@"; fi
  }
fi
SH
      else
        mkdir -p "$base/declared-parent"
        target="$base/declared-parent"
        printf 'declared bytes\n' > "$target/proof"
        printf 'unpreserved target\n' > "$base/uncovered"
        citation="$base/uncovered"
        printf '%s\n' "$target/proof" > "$case_dir/declarations"
        ln -s "$case_dir/declarations" "$case_dir/data/task-x1/evidence.list"
        physical_parent=$(cd -P -- "$target" && pwd -P)
        cat > "$case_dir/fakebin/cp" <<SH
#!/usr/bin/env bash
"$real_cp" "\$@" || exit \$?
case "\${!#}" in *'.evidence.new.'*) : > "$case_dir/staged" ;; esac
SH
        cat > "$case_dir/pwd-fault.sh" <<SH
if [ "\${0##*/}" = fm-teardown.sh ]; then
  pwd() {
    if [ "\$PWD" = "$physical_parent" ] && [ -f "$case_dir/staged" ] && [ ! -e "$case_dir/fault-seen" ]; then
      : > "$case_dir/fault-seen"
      builtin pwd "\$@" && printf '\\n'
    else builtin pwd "\$@"; fi
  }
fi
SH
        chmod +x "$case_dir/fakebin/cp"
      fi
      printf 'See %s\n' "$citation" > "$case_dir/data/task-x1/report.md"
      for flag in '' --force; do
        rm -f "$case_dir/staged" "$case_dir/fault-seen"
        rc=0
        if [ "$variant" != citation ]; then
          BASH_ENV="$case_dir/pwd-fault.sh" run_teardown "$case_dir" ${flag:+"$flag"} \
            > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
          assert_present "$case_dir/fault-seen" "$variant physical-object fault was not reached"
        else
          run_teardown "$case_dir" ${flag:+"$flag"} > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
        fi
        [ "$rc" -ne 0 ] || fail "$root_name $variant ${flag:-normal}: object resolution failure became survival"
        assert_grep "references $citation, which cleanup would destroy" "$case_dir/stderr" 'object resolution failure must refuse'
        if grep -q 'there is nothing left to save' "$case_dir/stderr"; then fail 'resolution failure became missing'; fi
        if [ "$variant" = citation ]; then
          [ -L "$base/alias" ] || fail 'object refusal removed source alias'
          [ "$(readlink "$base/alias"; printf .)" = "$target"$'\n.' ] || fail 'object refusal changed alias text'
          [ "$(cat "$target/proof")" = 'unpreserved target' ] || fail 'object refusal changed source'
        elif [ "$variant" = identity ]; then
          [ "$(cat "$citation")" = 'unpreserved target' ] || fail 'identity refusal changed source'
        else
          [ "$(cat "$target/proof")" = 'declared bytes' ] || fail 'object refusal changed declared source'
          [ "$(cat "$citation")" = 'unpreserved target' ] || fail 'object refusal changed uncovered source'
        fi
        [ "$(cat "$ev/sentinel")" = 'prior snapshot' ] || fail 'object refusal replaced prior evidence'
        assert_absent "$ev/copy" 'object refusal installed partial copy evidence'
        assert_absent "$ev/tmp" 'object refusal installed partial tmp evidence'
        assert_present "$case_dir/state/task-x1.meta" 'object refusal removed metadata'
      done
    done
  done
  pass 'citation, declaration and physical-identity failures refuse in both roots and force modes without replacing prior evidence'
}

test_existing_unusual_citations_never_become_missing() {
  local case_dir root_name base variant path citation flag rc
  for root_name in copy tmp; do
    case_dir=$(make_case "evidence-citation-bytes-$root_name")
    ignore_workspace "$case_dir"
    write_meta "$case_dir" no-mistakes ship
    printf 'tasktmp=%s/tasktmp\n' "$case_dir" >> "$case_dir/state/task-x1.meta"
    land_shippable_commit "$case_dir"
    mkdir -p "$case_dir/wt/workspace" "$case_dir/tasktmp" "$case_dir/data/task-x1"
    if [ "$root_name" = copy ]; then base="$case_dir/wt/workspace"; else base="$case_dir/tasktmp"; fi
    for variant in period period-citation colon comma spaced unquoted-spaced unquoted-spaced-prose apostrophe-spaced single-inner double-inner backtick-inner less-than less-than-dangling spaced-dangling delimited dangling-slash unmatched escaped context prose-context escaped-space adjacent; do
      case "$variant" in
        period) path="$base/proof."; citation=$path ;;
        period-citation) path="$base/proof."; citation="$path:42:3." ;;
        colon) path="$base/proof:42"; citation=$path ;;
        comma) path="$base/proof,more"; citation=$path ;;
        spaced) path="$base/my proof.txt"; citation="\"$path\"" ;;
        unquoted-spaced) path="$base/my proof.txt"; citation=$path ;;
        unquoted-spaced-prose) path="$base/my proof.txt"; citation="$path:42:3. was recorded" ;;
        apostrophe-spaced) path="$base/my proof.txt"; citation="'it's $path'" ;;
        single-inner) path="$base/agent's notes.txt"; citation="'$path'" ;;
        double-inner) path="$base/agent\"s notes.txt"; citation="\"$path\"" ;;
        backtick-inner) path="$base/agent\`s notes.txt"; citation="\`$path\`" ;;
        less-than) path="$base/a<b.txt"; citation=$path ;;
        less-than-dangling) path="$base/a<b.txt"; citation=$path ;;
        spaced-dangling) path="$base/my proof.txt"; citation="$path///" ;;
        delimited) path="$base/proof,(part)[one]"; citation="\`$path\`" ;;
        dangling-slash) path="$base/link"; citation="$path///" ;;
        unmatched) path="$base/my proof.txt"; citation="\"$path" ;;
        escaped) path="$base/proof"; citation="\"$base/proof\\\"tail\"" ;;
        context) path="$base/my proof.txt"; citation="\"command $path\"" ;;
        prose-context) path="$base/my proof.txt"; citation="The agent's log: \"command $path\"" ;;
        escaped-space) path="$base/my proof.txt"; citation="$base/my\\ proof.txt" ;;
        adjacent) path="$base/proof"; citation="$path,$base/other" ;;
      esac
      case "$variant" in
        dangling-slash|spaced-dangling|less-than-dangling) ln -s absent "$path" ;;
        *) printf 'unique\n' > "$path" ;;
      esac
      printf 'See %s\n' "$citation" > "$case_dir/data/task-x1/report.md"
      for flag in '' --force; do
        rc=0
        run_teardown "$case_dir" ${flag:+"$flag"} > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
        [ "$rc" -ne 0 ] || fail "$root_name/$variant citation became missing ${flag:-without force}"
        assert_grep 'REFUSED:' "$case_dir/stderr" 'ambiguous/existing citation must refuse'
        if grep -q 'there is nothing left to save' "$case_dir/stderr"; then
          fail "$root_name/$variant cited entry was incorrectly reported missing"
        fi
        [ -e "$path" ] || [ -L "$path" ] || fail 'citation refusal removed source'
        assert_present "$case_dir/state/task-x1.meta" 'citation refusal removed metadata'
        assert_absent "$case_dir/data/task-x1/evidence" 'citation refusal installed a snapshot'
      done
      rm "$path"
    done
  done
  pass 'exact punctuation names, quoted and unquoted spaced names, ambiguous extraction and dangling links refuse in both roots'
}

# Every existing whitespace interpretation uses the normal coverage guard;
# neither a covered first match nor a missing short prefix may hide another.
test_unquoted_spaced_citations_check_every_existing_interpretation() {
  local case_dir root_name base declaration flag rc
  for root_name in copy tmp; do
    case_dir=$(make_case "evidence-spaced-coverage-$root_name")
    ignore_workspace "$case_dir"
    write_meta "$case_dir" no-mistakes ship
    printf 'tasktmp=%s/tasktmp\n' "$case_dir" >> "$case_dir/state/task-x1.meta"
    land_shippable_commit "$case_dir"
    mkdir -p "$case_dir/wt/workspace" "$case_dir/tasktmp" "$case_dir/data/task-x1"
    if [ "$root_name" = copy ]; then base="$case_dir/wt/workspace"; else base="$case_dir/tasktmp"; fi
    printf 'short\n' > "$base/my"
    printf 'middle\n' > "$base/my proof"
    printf 'long\n' > "$base/my proof final.txt"
    printf '%s\n' "$base/my" "$base/my proof" > "$case_dir/data/task-x1/evidence.list"
    printf 'See %s/my proof final.txt:42. in the log\n' "$base" > "$case_dir/data/task-x1/report.md"
    for flag in '' --force; do
      rc=0
      run_teardown "$case_dir" ${flag:+"$flag"} > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
      [ "$rc" -ne 0 ] || fail 'covered shorter interpretations hid an undeclared longer citation'
      assert_grep "references $base/my proof final.txt," "$case_dir/stderr" 'longer existing interpretation must refuse'
      assert_present "$case_dir/state/task-x1.meta" 'spaced citation refusal removed metadata'
      assert_absent "$case_dir/data/task-x1/evidence" 'spaced citation refusal installed a snapshot'
      [ "$(cat "$base/my proof final.txt")" = long ] || fail 'spaced citation refusal changed source bytes'
    done
    # An exact longer interpretation is allowed when it too is declared.
    # Missing unquoted citations followed by prose still only warn.
    printf '%s\n' "$base/my proof final.txt" >> "$case_dir/data/task-x1/evidence.list"
    printf 'See %s/absent proof.txt in the log\n' "$base" >> "$case_dir/data/task-x1/report.md"
    rc=0
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
    expect_code 0 "$rc" "declared whitespace interpretations should pass: $(cat "$case_dir/stderr")"
    if [ "$root_name" = copy ]; then declaration=copy/workspace; else declaration=tmp; fi
    [ "$(cat "$case_dir/data/task-x1/evidence/$declaration/my proof final.txt")" = long ] \
      || fail 'declared longer interpretation was not preserved'
    assert_grep "record $case_dir/data/task-x1/report.md references missing path $base/absent; there is nothing left to save" \
      "$case_dir/stderr" 'a truly missing unquoted citation should still warn'
    assert_absent "$case_dir/state/task-x1.meta" 'covered spaced citations prevented teardown'
  done
  pass 'all existing unquoted whitespace interpretations need coverage while missing citations still warn'
}

# Covered short tokens must not hide existing undeclared longer entries at
# quote/markup boundaries, just as at the whitespace boundaries above.
test_every_citation_boundary_checks_longer_existing_interpretations() {
  local case_dir root_name variant base path citation rc flag label initial uncovered
  for root_name in copy tmp; do
    for variant in single double backtick markup normalized; do
      case_dir=$(make_case "evidence-boundary-$root_name-$variant")
      ignore_workspace "$case_dir"
      write_meta "$case_dir" no-mistakes ship
      printf 'tasktmp=%s/tasktmp\n' "$case_dir" >> "$case_dir/state/task-x1.meta"
      land_shippable_commit "$case_dir"
      mkdir -p "$case_dir/wt/workspace" "$case_dir/tasktmp" "$case_dir/data/task-x1"
      if [ "$root_name" = copy ]; then base="$case_dir/wt/workspace"; label=copy/workspace
      else base="$case_dir/tasktmp"; label=tmp; fi
      case "$variant" in
        single) path="$base/proof'long.txt"; citation="'$path'" ;;
        double) path="$base/proof\"long.txt"; citation="\"$path\"" ;;
        backtick) path="$base/proof\`long.txt"; citation="\`$path\`" ;;
        markup) path="$base/proof<long.txt"; citation="<pre>$path</pre>" ;;
        normalized) path="$base/proof:42'long.txt"; citation="'$path'" ;;
      esac
      printf 'short\n' > "$base/proof"
      printf 'unique\n' > "$path"
      initial="$base/proof"; uncovered=$path
      # A declared longer entry must not suppress an existing undeclared
      # shorter interpretation merely because its raw token ends in :42.
      if [ "$variant" = normalized ]; then initial=$path; uncovered="$base/proof"; fi
      printf '%s\n' "$initial" > "$case_dir/data/task-x1/evidence.list"
      printf 'See %s\n' "$citation" > "$case_dir/data/task-x1/report.md"
      for flag in '' --force; do
        rc=0
        run_teardown "$case_dir" ${flag:+"$flag"} > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
        [ "$rc" -ne 0 ] || fail "$root_name/$variant covered prefix hid an undeclared longer entry"
        assert_grep "references $uncovered," "$case_dir/stderr" 'boundary refusal must name uncovered interpretation'
        if grep -q 'there is nothing left to save' "$case_dir/stderr"; then
          fail 'an existing boundary interpretation was reported missing'
        fi
        assert_present "$case_dir/state/task-x1.meta" 'boundary refusal removed metadata'
        assert_absent "$case_dir/data/task-x1/evidence" 'boundary refusal installed a partial snapshot'
        [ "$(cat "$path")" = unique ] || fail 'boundary refusal changed source bytes'
      done
      printf '%s\n' "$uncovered" >> "$case_dir/data/task-x1/evidence.list"
      rc=0
      run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
      expect_code 0 "$rc" "declared boundary interpretations should pass: $(cat "$case_dir/stderr")"
      [ "$(cat "$case_dir/data/task-x1/evidence/$label/${path##*/}")" = unique ] \
        || fail 'declared longer boundary interpretation was lost'
      evidence_manifest_verifies "$case_dir/data/task-x1/evidence" || fail 'boundary evidence does not verify'
      assert_absent "$case_dir/state/task-x1.meta" 'covered boundary citation prevented cleanup'
    done
  done
  pass 'every quote/markup boundary checks all longer existing entries even when its short token is covered'
}

test_genuinely_absent_markup_citations_warn_in_both_roots_and_force_modes() {
  local case_dir root_name flag base rc variant name
  for root_name in copy tmp; do
    for variant in plain forced; do
      case_dir=$(make_case "evidence-absent-markup-$root_name-$variant")
      write_meta "$case_dir" no-mistakes ship
      printf 'tasktmp=%s/tasktmp\n' "$case_dir" >> "$case_dir/state/task-x1.meta"
      land_shippable_commit "$case_dir"
      mkdir -p "$case_dir/data/task-x1"
      if [ "$root_name" = copy ]; then base="$case_dir/wt/workspace"; else base="$case_dir/tasktmp"; fi
      {
        printf '<pre>%s/absent</pre>\n' "$base"
        printf "See '%s/single missing.txt'\n" "$base"
        printf 'See "%s/double missing.txt"\n' "$base"
        printf 'See %s\n' "\`$base/backtick missing.txt\`"
        printf 'See %s/space missing.txt in the log\n' "$base"
      } > "$case_dir/data/task-x1/report.md"
      flag=; [ "$variant" != forced ] || flag=--force
      rc=0
      run_teardown "$case_dir" ${flag:+"$flag"} > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
      expect_code 0 "$rc" "genuinely absent markup citations should pass: $(cat "$case_dir/stderr")"
      for name in absent 'single missing.txt' 'double missing.txt' 'backtick missing.txt' space; do
        assert_grep "record $case_dir/data/task-x1/report.md references missing path $base/$name; there is nothing left to save" \
          "$case_dir/stderr" 'genuinely absent boundary citation must warn with record and path'
      done
      assert_absent "$case_dir/state/task-x1.meta" 'absent markup citation prevented cleanup'
    done
  done
  pass 'genuinely absent markup and quoted citations still warn in both roots with and without force'
}

test_reassigned_evidence_citations_only_warn_without_interpreting() {
  local case_dir rc
  case_dir=$(make_case evidence-reassigned-citations)
  mkdir -p "$case_dir/data/task-x1" "$case_dir/wt/workspace"
  printf 'foreign work\n' > "$case_dir/wt/workspace/proof."
  printf 'See %s/workspace/proof.\nAlso "command %s/workspace/my proof\n' "$case_dir/wt" "$case_dir/wt" \
    > "$case_dir/data/task-x1/report.md"
  cat > "$case_dir/foreign-tripwire.sh" <<'SH'
. "$1"
foreign=$3
tripwire=$4
foreign_access() {
  local arg
  for arg in "$@"; do
    case "$arg" in "$foreign"|"$foreign"/*) printf '%s\n' "$*" >> "$tripwire" ;; esac
  done
}
cd() { foreign_access "$@"; builtin cd "$@"; }
pwd() { foreign_access "$PWD"; builtin pwd "$@"; }
stat() { foreign_access "$@"; command stat "$@"; }
function [ {
  case "${1:-}" in
    -e|-L|-d|-f|-r|-w|-x|-s|-b|-c|-p|-S) foreign_access "${2:-}" ;;
    *) case "${2:-}" in -ef|-nt|-ot) foreign_access "${1:-}" "${3:-}" ;; esac ;;
  esac
  builtin [ "$@"
}
fm_task_evidence_preserve task-x1 "$2" "$foreign" 0 "${5:-}"
SH
  rc=0
  bash "$case_dir/foreign-tripwire.sh" "$ROOT/bin/fm-task-evidence-lib.sh" \
    "$case_dir/data" "$case_dir/wt" "$case_dir/foreign-access" \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 0 "$rc" 'reassigned-copy citations cannot cause a refusal'
  assert_absent "$case_dir/foreign-access" 'evidence preservation inspected an unowned foreign root'
  assert_grep 'inside a copy already reassigned to another task' "$case_dir/stderr" 'reassigned citation must warn'
  assert_grep "record $case_dir/data/task-x1/report.md" "$case_dir/stderr" 'foreign warning lost record identity'
  assert_grep "See $case_dir/wt/workspace/proof." "$case_dir/stderr" 'foreign warning lost exact punctuation citation'
  assert_grep "Also \"command $case_dir/wt/workspace/my proof" "$case_dir/stderr" 'foreign warning lost ambiguous lexical citation'
  if grep -qE 'REFUSED:|there is nothing left to save' "$case_dir/stderr"; then
    fail 'foreign citation was interpreted as owned evidence'
  fi
  [ "$(cat "$case_dir/wt/workspace/proof.")" = 'foreign work' ] || fail 'foreign work was changed'
  assert_absent "$case_dir/data/task-x1/evidence" 'foreign work was copied as task evidence'
  # A previously saved copy-owned link must also bypass target inspection.
  local ev hash
  ev="$case_dir/data/task-x1/evidence"
  mkdir -p "$ev/copy/workspace"
  ln -s "$case_dir/wt/workspace/proof." "$ev/copy/workspace/link"
  hash=$(readlink "$ev/copy/workspace/link" | { sha256sum 2>/dev/null || shasum -a 256; } | awk '{print $1}')
  : > "$ev/MANIFEST.sha256"
  printf '%s  copy/workspace/link\n' "$hash" > "$ev/MANIFEST.sha256.links"
  printf 'workspace/link\n' > "$case_dir/data/task-x1/evidence.list"
  rc=0
  bash "$case_dir/foreign-tripwire.sh" "$ROOT/bin/fm-task-evidence-lib.sh" \
    "$case_dir/data" "$case_dir/wt" "$case_dir/foreign-access" \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 0 "$rc" 'carried foreign-copy links must survive without target inspection'
  assert_absent "$case_dir/foreign-access" 'carried link inspection touched a foreign slot'
  [ -L "$ev/copy/workspace/link" ] || fail 'foreign-copy carry lost prior link'
  evidence_manifest_verifies "$ev" || fail 'foreign-copy carried link does not verify'
  # An owned tmp link may resolve into the foreign copy. Its survival is not
  # conditional on that copy being git-recoverable or declared by this task.
  mkdir -p "$case_dir/tasktmp"
  ln -s "$case_dir/wt/workspace/proof." "$case_dir/tasktmp/link"
  printf '%s\n' "$case_dir/tasktmp/link" > "$case_dir/data/task-x1/evidence.list"
  rc=0
  bash -c '
    . "$1"
    tripwire=$5
    git() { printf "git lookup\\n" >> "$tripwire"; command git "$@"; }
    fm_task_evidence_preserve task-x1 "$2" "$3" 0 "$4"
  ' _ "$ROOT/bin/fm-task-evidence-lib.sh" "$case_dir/data" "$case_dir/wt" "$case_dir/tasktmp" "$case_dir/foreign-git-access" \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 0 "$rc" "a tmp link into a foreign copy must survive: $(cat "$case_dir/stderr")"
  assert_absent "$case_dir/foreign-git-access" 'survival queried git in a foreign copy'
  [ -L "$ev/tmp/link" ] || fail 'tmp link into a foreign copy was lost'
  evidence_manifest_verifies "$ev" || fail 'tmp foreign-target link does not verify'
  [ "$(cat "$case_dir/wt/workspace/proof.")" = 'foreign work' ] || fail 'foreign link checks changed foreign bytes'
  pass 'reassigned-copy citations and carried links do not inspect foreign contents or demand foreign git recovery'
}

test_link_resolution_refuses_every_unpreserved_disposable_target() {
  local case_dir variant target flag rc ev
  for variant in chain directory copy-root tmp-root dotdot alias tmp-tracked-collision newline-copy newline-tmp newline-chain; do
    case_dir=$(make_case "evidence-resolve-$variant")
    ignore_workspace "$case_dir"
    write_meta "$case_dir" no-mistakes ship
    printf 'tasktmp=%s/tasktmp\n' "$case_dir" >> "$case_dir/state/task-x1.meta"
    wt_commit_file "$case_dir" uncovered original
    land_shippable_commit "$case_dir"
    ev="$case_dir/data/task-x1/evidence"
    mkdir -p "$case_dir/wt/workspace/links" "$case_dir/tasktmp" "$case_dir/outside" "$ev"
    printf 'prior snapshot\n' > "$ev/sentinel"
    target="$case_dir/wt/workspace/uncovered"
    case "$variant" in
      directory) mkdir -p "$target"; printf 'unique\n' > "$target/member" ;;
      copy-root) target="$case_dir/wt" ;;
      tmp-root) target="$case_dir/tasktmp" ;;
      dotdot) mkdir -p "$case_dir/wt/workspace/subdir"; target="$case_dir/wt/workspace/subdir/.." ;;
      tmp-tracked-collision) target="$case_dir/tasktmp/uncovered"; printf 'original\n' > "$target" ;;
      newline-copy|newline-chain) target="$target"$'\n'; printf 'unique\n' > "$target" ;;
      newline-tmp) target="$case_dir/tasktmp/uncovered"$'\n'; printf 'unique\n' > "$target" ;;
      *) printf 'unique\n' > "$target" ;;
    esac
    case "$variant" in
      chain|newline-chain)
        ln -s "$target" "$case_dir/outside/intermediate"
        target="$case_dir/outside/intermediate" ;;
      alias)
        ln -s "$case_dir/wt" "$case_dir/outside/alias"
        target="$case_dir/outside/alias/workspace/uncovered" ;;
    esac
    # A safe first sorted link must not terminate the remaining target checks.
    ln -s "$case_dir/outside" "$case_dir/wt/workspace/links/a-safe"
    ln -s "$target" "$case_dir/wt/workspace/links/z-unsafe"
    printf '%s\n' workspace/links > "$case_dir/data/task-x1/evidence.list"
    for flag in '' --force; do
      rc=0
      run_teardown "$case_dir" ${flag:+"$flag"} > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
      [ "$rc" -ne 0 ] || fail "$variant target guard bypassed ${flag:-without force}"
      case "$variant" in
        newline-*) assert_grep 'unsupported newline text' "$case_dir/stderr" 'newline link text must refuse losslessly' ;;
        *) assert_grep 'which cleanup would destroy' "$case_dir/stderr" 'existing target must refuse' ;;
      esac
      [ -L "$case_dir/wt/workspace/links/z-unsafe" ] || fail 'target refusal removed source link'
      [ -e "$target" ] || fail 'target refusal removed target'
      [ "$(cat "$ev/sentinel")" = 'prior snapshot' ] || fail 'target refusal replaced earlier snapshot'
      assert_absent "$ev/copy" 'target refusal installed a partial snapshot'
      assert_present "$case_dir/state/task-x1.meta" 'target refusal removed metadata'
    done
  done
  pass 'chains, directory/root targets, aliases, tmp/git collisions and newline link text cannot orphan existing evidence'
}

test_evidence_link_faults_preserve_source_and_prior_snapshot() {
  local case_dir variant flag rc ev real_readlink real_cp
  real_readlink=$(command -v readlink)
  real_cp=$(command -v cp)
  for variant in fresh-mismatch final-mismatch source-not-link readlink-failure resolver-error resolver-chain-error; do
    case_dir=$(make_case "evidence-link-fault-$variant")
    ignore_workspace "$case_dir"
    write_meta "$case_dir" no-mistakes ship
    land_shippable_commit "$case_dir"
    ev="$case_dir/data/task-x1/evidence"
    mkdir -p "$case_dir/wt/workspace" "$case_dir/outside" "$ev"
    printf 'prior snapshot\n' > "$ev/sentinel"
    if [ "$variant" = resolver-chain-error ]; then
      mkdir -p "$case_dir/outside/target"
      ln -s "$case_dir/outside/target" "$case_dir/outside/intermediate"
      ln -s "$case_dir/outside/intermediate" "$case_dir/wt/workspace/link"
    else
      ln -s "$case_dir/outside" "$case_dir/wt/workspace/link"
    fi
    printf '%s\n' workspace/link > "$case_dir/data/task-x1/evidence.list"
    # Inject only at a known public utility boundary, never change the library.
    # Source, fresh staging hash, final staging hash, resolver are separate reads.
    cat > "$case_dir/fakebin/readlink" <<SH
#!/usr/bin/env bash
if [ "$variant" = resolver-chain-error ] && [ "\$1" = "$case_dir/outside/intermediate" ]; then exit 1; fi
case "\$1" in
  *'.evidence.new.'*)
    n=0; [ ! -f "$case_dir/read-count" ] || read -r n < "$case_dir/read-count"
    n=\$((n + 1)); printf '%s\\n' "\$n" > "$case_dir/read-count"
    case "$variant:\$n" in
      final-mismatch:2) rm -- "\$1"; ln -s changed -- "\$1" ;;
      readlink-failure:1|resolver-error:3) exit 1 ;;
    esac
    ;;
esac
exec "$real_readlink" "\$@"
SH
    cat > "$case_dir/fakebin/cp" <<SH
#!/usr/bin/env bash
"$real_cp" "\$@" || exit \$?
dest=\${!#}
case "$variant:\$dest" in
  fresh-mismatch:*'.evidence.new.'*) rm -- "\$dest"; ln -s changed -- "\$dest" ;;
  source-not-link:*'.evidence.new.'*) rm -- "\$dest"; printf 'not a link\\n' > "\$dest" ;;
esac
SH
    chmod +x "$case_dir/fakebin/readlink" "$case_dir/fakebin/cp"
    for flag in '' --force; do
      rm -f "$case_dir/read-count"
      rc=0
      run_teardown "$case_dir" ${flag:+"$flag"} > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
      [ "$rc" -ne 0 ] || fail "$variant accepted a bad link ${flag:-without force}"
      case "$variant" in
        fresh-mismatch) assert_grep 'does not match its source' "$case_dir/stderr" 'fresh link comparison must refuse' ;;
        final-mismatch) assert_grep 'staged evidence copy/workspace/link for task-x1 failed verification' "$case_dir/stderr" 'final link verification must refuse' ;;
        resolver-error|resolver-chain-error) assert_grep 'cannot resolve evidence symlink' "$case_dir/stderr" 'resolver error must not become absence' ;;
        *) assert_grep 'could not copy and verify' "$case_dir/stderr" 'link hash/type failure must refuse' ;;
      esac
      [ -L "$case_dir/wt/workspace/link" ] || fail 'fault removed source link'
      if [ "$variant" = resolver-chain-error ]; then
        [ "$("$real_readlink" "$case_dir/wt/workspace/link")" = "$case_dir/outside/intermediate" ] || fail 'fault changed chained source link'
      else
        [ "$("$real_readlink" "$case_dir/wt/workspace/link")" = "$case_dir/outside" ] || fail 'fault changed source link'
      fi
      [ "$(cat "$ev/sentinel")" = 'prior snapshot' ] || fail 'fault replaced earlier evidence'
      assert_absent "$ev/copy" 'fault installed new evidence'
      assert_present "$case_dir/state/task-x1.meta" 'fault removed metadata'
    done
  done
  pass 'fresh/final link corruption, non-link substitution, readlink failures and resolver errors refuse before changing prior evidence'
}

# The outer declared link is read, not followed, before the manual resolver.
# Exactly forty further links exercise its final bound on the Linux CI runner.
test_evidence_link_resolution_exhaustion_has_a_resolvable_control() {
  local case_dir root_name flag length base target ev rc n next outer
  for root_name in copy tmp; do
    for flag in '' --force; do
      for length in 40 2; do
        case_dir=$(make_case "evidence-bound-$root_name-${flag:-normal}-$length")
        ignore_workspace "$case_dir"
        write_meta "$case_dir" no-mistakes ship
        printf 'tasktmp=%s/tasktmp\n' "$case_dir" >> "$case_dir/state/task-x1.meta"
        land_shippable_commit "$case_dir"
        ev="$case_dir/data/task-x1/evidence"
        mkdir -p "$case_dir/wt/workspace" "$case_dir/tasktmp" "$case_dir/outside" "$ev"
        printf 'prior snapshot\n' > "$ev/sentinel"
        if [ "$root_name" = copy ]; then base="$case_dir/wt/workspace"; else base="$case_dir/tasktmp"; fi
        target="$base/terminal"
        printf 'terminal bytes\n' > "$target"
        next=$target; n=$length
        while [ "$n" -gt 0 ]; do
          ln -s "$next" "$case_dir/outside/hop-$n"
          next="$case_dir/outside/hop-$n"; n=$((n - 1))
        done
        outer="$case_dir/wt/workspace/outer"
        ln -s "$next" "$outer"
        # Only the outer link is declared; no durable citation names terminal.
        printf 'workspace/outer\n' > "$case_dir/data/task-x1/evidence.list"
        [ -e "$next" ] || fail 'CI filesystem cannot resolve the boundary chain input'
        rc=0
        run_teardown "$case_dir" ${flag:+"$flag"} > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
        [ "$rc" -ne 0 ] || fail "$root_name $length ${flag:-normal}: resolver lost an undeclared terminal"
        if [ "$length" = 40 ]; then
          assert_grep "cannot resolve existing evidence link $outer" "$case_dir/stderr" 'final resolver bound was not reached'
          assert_grep "cannot resolve evidence symlink $outer" "$case_dir/stderr" 'resolver exhaustion must propagate refusal'
        else
          assert_grep "resolves to $target, which cleanup would destroy" "$case_dir/stderr" 'short control must resolve the actual terminal'
          if grep -q 'cannot resolve' "$case_dir/stderr"; then fail 'short chain failed before coverage'; fi
        fi
        [ -L "$outer" ] && [ "$(readlink "$outer")" = "$next" ] || fail 'resolver refusal changed source link'
        [ "$(cat "$target")" = 'terminal bytes' ] || fail 'resolver refusal changed terminal'
        [ "$(cat "$ev/sentinel")" = 'prior snapshot' ] || fail 'resolver refusal replaced prior snapshot'
        assert_absent "$ev/copy" 'resolver refusal installed partial copy evidence'
        assert_absent "$ev/tmp" 'resolver refusal installed partial tmp evidence'
        assert_present "$case_dir/state/task-x1.meta" 'resolver refusal removed metadata'
        if [ "$length" = 2 ]; then
          printf '%s\n' "$target" >> "$case_dir/data/task-x1/evidence.list"
          rc=0
          run_teardown "$case_dir" ${flag:+"$flag"} > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
          expect_code 0 "$rc" "declared short-chain terminal must pass: $(cat "$case_dir/stderr")"
          [ -L "$ev/copy/workspace/outer" ] || fail 'short chain was followed during copy'
          evidence_manifest_verifies "$ev" || fail 'short-chain snapshot does not verify'
          assert_absent "$case_dir/state/task-x1.meta" 'short-chain control left metadata'
        fi
      done
    done
  done
  pass 'resolver exhaustion refuses at forty hops while shorter chains resolve and preserve declared terminals in both roots and force modes'
}

test_completed_prose_quotes_allow_missing_and_declared_citations() {
  local case_dir root_name flag base ev rc quote label quote_name
  for root_name in copy tmp; do
    for flag in '' --force; do
      for quote in "'" '"' '`'; do
        case "$quote" in "'") quote_name=single ;; '"') quote_name=double ;; *) quote_name=backtick ;; esac
        case_dir=$(make_case "evidence-completed-prose-$root_name-${flag:-normal}-$quote_name")
        ignore_workspace "$case_dir"
        write_meta "$case_dir" no-mistakes ship
        printf 'tasktmp=%s/tasktmp\n' "$case_dir" >> "$case_dir/state/task-x1.meta"
        land_shippable_commit "$case_dir"
        mkdir -p "$case_dir/wt/workspace" "$case_dir/tasktmp" "$case_dir/data/task-x1"
        if [ "$root_name" = copy ]; then base="$case_dir/wt/workspace"; label=copy/workspace
        else base="$case_dir/tasktmp"; label=tmp; fi
        printf 'declared bytes\n' > "$base/proof"
        printf '%s\n' "$base/proof" > "$case_dir/data/task-x1/evidence.list"
        # A quote embedded between word characters still opens a larger
        # context unless it is an apostrophe, which is ordinary prose.
        if [ "$quote" != "'" ]; then
          printf 'The a%sb cited %s/absent\n' "$quote" "$base" > "$case_dir/data/task-x1/report.md"
          rc=0
          run_teardown "$case_dir" ${flag:+"$flag"} > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
          [ "$rc" -ne 0 ] || fail 'word-internal double/backtick quote was treated as a prose apostrophe'
          assert_grep 'ambiguous quoted context' "$case_dir/stderr" 'word-internal non-apostrophe quote must open context'
          assert_present "$case_dir/state/task-x1.meta" 'word-internal quote refusal removed metadata'
          assert_absent "$case_dir/data/task-x1/evidence" 'word-internal quote refusal installed evidence'
        fi
        # Mismatched and embedded quote contexts must not become missing paths.
        printf 'The %srun cited %s/absent" in prose\n' "$quote" "$base" > "$case_dir/data/task-x1/report.md"
        rc=0
        run_teardown "$case_dir" ${flag:+"$flag"} > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
        [ "$rc" -ne 0 ] || fail 'larger quoted context was silently accepted'
        assert_grep 'ambiguous quoted context' "$case_dir/stderr" 'context tracking must remain active'
        assert_present "$case_dir/state/task-x1.meta" 'quoted-context refusal removed metadata'
        assert_absent "$case_dir/data/task-x1/evidence" 'quoted-context refusal installed evidence'
        [ "$(cat "$base/proof")" = 'declared bytes' ] || fail 'quoted-context refusal changed source'
        {
          printf 'The %srun%s cited %s/absent\n' "$quote" "$quote" "$base"
          printf 'The %srun%s cited %s/proof\n' "$quote" "$quote" "$base"
        } > "$case_dir/data/task-x1/report.md"
        rc=0
        run_teardown "$case_dir" ${flag:+"$flag"} > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
        expect_code 0 "$rc" "completed prose quotes must close: $(cat "$case_dir/stderr")"
        assert_grep "record $case_dir/data/task-x1/report.md references missing path $base/absent; there is nothing left to save" \
          "$case_dir/stderr" 'completed prose missing citation lost its warning'
        ev="$case_dir/data/task-x1/evidence"
        [ "$(cat "$ev/$label/proof")" = 'declared bytes' ] || fail 'completed prose lost declared evidence'
        evidence_manifest_verifies "$ev" || fail 'completed prose snapshot does not verify'
        assert_absent "$case_dir/state/task-x1.meta" 'completed prose citation prevented cleanup'
      done
    done
  done
  pass 'completed single/double/backtick prose quotes allow missing and declared citations without accepting larger quoted contexts'
}

test_missing_markup_short_interpretations_respect_quote_mode() {
  local case_dir root_name base path flag rc ev label
  for root_name in copy tmp; do
    for flag in '' --force; do
      case_dir=$(make_case "evidence-short-markup-$root_name-${flag:-normal}")
      ignore_workspace "$case_dir"
      write_meta "$case_dir" no-mistakes ship
      printf 'tasktmp=%s/tasktmp\n' "$case_dir" >> "$case_dir/state/task-x1.meta"
      land_shippable_commit "$case_dir"
      mkdir -p "$case_dir/wt/workspace" "$case_dir/tasktmp" "$case_dir/data/task-x1"
      if [ "$root_name" = copy ]; then base="$case_dir/wt/workspace"; label=copy/workspace
      else base="$case_dir/tasktmp"; label=tmp; fi
      # Isolate the report's quote mode: declaration bytes are not another
      # unquoted citation in a scanned regular record.
      ln -s "$case_dir/declarations" "$case_dir/data/task-x1/evidence.list"
      path="$base/proof:tag longer"
      printf 'long bytes\n' > "$path"
      printf '%s\n' "$path" > "$case_dir/declarations"
      printf 'See %s\n' "$path" > "$case_dir/data/task-x1/report.md"
      rc=0
      run_teardown "$case_dir" ${flag:+"$flag"} > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
      [ "$rc" -ne 0 ] || fail 'declared longer interpretation hid ambiguous unquoted short markup'
      assert_grep "ambiguous unquoted evidence citation in $case_dir/data/task-x1/report.md: $base/proof:tag" \
        "$case_dir/stderr" 'short markup refusal was not reached'
      assert_present "$case_dir/state/task-x1.meta" 'markup refusal removed metadata'
      assert_absent "$case_dir/data/task-x1/evidence" 'markup refusal installed partial evidence'
      [ "$(cat "$path")" = 'long bytes' ] || fail 'markup refusal changed source evidence'
      # The same missing short token is unambiguous when explicitly quoted.
      path="$base/proof:tag' longer"
      printf 'quoted long bytes\n' > "$path"
      printf '%s\n' "$path" > "$case_dir/declarations"
      printf "See '%s/proof:tag' longer\n" "$base" > "$case_dir/data/task-x1/report.md"
      rc=0
      run_teardown "$case_dir" ${flag:+"$flag"} > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
      expect_code 0 "$rc" "quoted missing short interpretation should pass: $(cat "$case_dir/stderr")"
      if grep -q 'there is nothing left to save' "$case_dir/stderr"; then fail 'covered longer entry did not suppress missing quoted short token'; fi
      ev="$case_dir/data/task-x1/evidence"
      [ "$(cat "$ev/$label/proof:tag' longer")" = 'quoted long bytes' ] || fail 'quoted markup control lost declared bytes'
      evidence_manifest_verifies "$ev" || fail 'quoted markup evidence does not verify'
      assert_absent "$case_dir/state/task-x1.meta" 'quoted markup control left metadata'
    done
  done
  pass 'missing short markup interpretations retain quoted versus unquoted ambiguity rules despite declared longer entries'
}

test_final_directory_resolution_failure_has_a_success_control() {
  local case_dir root_name base ev rc flag
  for root_name in copy tmp; do
    for flag in '' --force; do
      case_dir=$(make_case "evidence-final-directory-$root_name-${flag:-normal}")
      ignore_workspace "$case_dir"
      write_meta "$case_dir" no-mistakes ship
      printf 'tasktmp=%s/tasktmp\n' "$case_dir" >> "$case_dir/state/task-x1.meta"
      land_shippable_commit "$case_dir"
      ev="$case_dir/data/task-x1/evidence"
      mkdir -p "$case_dir/wt/workspace" "$case_dir/tasktmp" "$ev"
      if [ "$root_name" = copy ]; then base="$case_dir/wt/workspace"; else base="$case_dir/tasktmp"; fi
      mkdir -p "$base/directory"
      printf 'directory bytes\n' > "$base/directory/proof"
      printf 'prior snapshot\n' > "$ev/sentinel"
      printf '%s\n' "$base/directory" > "$case_dir/declarations"
      ln -s "$case_dir/declarations" "$case_dir/data/task-x1/evidence.list"
      printf 'See %s/directory\n' "$base" > "$case_dir/data/task-x1/report.md"
      cat > "$case_dir/pwd-fault.sh" <<SH
if [ "\${0##*/}" = fm-teardown.sh ]; then
  pwd() {
    if [ "\$PWD" = "$base/directory" ]; then
      : > "$case_dir/fault-seen"
      return 1
    fi
    builtin pwd "\$@"
  }
fi
SH
      rc=0
      BASH_ENV="$case_dir/pwd-fault.sh" run_teardown "$case_dir" ${flag:+"$flag"} \
        > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
      [ "$rc" -ne 0 ] || fail 'final-directory resolution error became survival'
      assert_present "$case_dir/fault-seen" 'final-directory pwd fault was not reached'
      assert_grep "references $base/directory, which cleanup would destroy" "$case_dir/stderr" 'final-directory failure must reach citation coverage'
      [ "$(cat "$base/directory/proof")" = 'directory bytes' ] || fail 'directory refusal changed source'
      [ "$(cat "$ev/sentinel")" = 'prior snapshot' ] || fail 'directory refusal replaced prior snapshot'
      assert_absent "$ev/copy" 'directory refusal installed partial copy evidence'
      assert_absent "$ev/tmp" 'directory refusal installed partial tmp evidence'
      assert_present "$case_dir/state/task-x1.meta" 'directory refusal removed metadata'
      rc=0
      run_teardown "$case_dir" ${flag:+"$flag"} > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
      expect_code 0 "$rc" "resolvable declared directory must pass: $(cat "$case_dir/stderr")"
      evidence_manifest_verifies "$ev" || fail 'directory success snapshot does not verify'
      assert_absent "$case_dir/state/task-x1.meta" 'directory success control left metadata'
    done
  done
  pass 'final-directory physical lookup failure refuses while the resolvable declared control succeeds'
}

test_missing_staged_directory_cannot_cover_existing_source() {
  local case_dir root_name base ev flag rc real_sort
  real_sort=$(command -v sort)
  for root_name in copy tmp; do
    case_dir=$(make_case "evidence-missing-staged-member-$root_name")
    ignore_workspace "$case_dir"
    write_meta "$case_dir" no-mistakes ship
    printf 'tasktmp=%s/tasktmp\n' "$case_dir" >> "$case_dir/state/task-x1.meta"
    land_shippable_commit "$case_dir"
    ev="$case_dir/data/task-x1/evidence"
    mkdir -p "$case_dir/wt/workspace" "$case_dir/tasktmp" "$ev"
    if [ "$root_name" = copy ]; then base="$case_dir/wt/workspace"; else base="$case_dir/tasktmp"; fi
    mkdir -p "$base/empty"
    printf 'prior snapshot\n' > "$ev/sentinel"
    printf '%s\n' "$base/empty" > "$case_dir/declarations"
    ln -s "$case_dir/declarations" "$case_dir/data/task-x1/evidence.list"
    printf 'See %s/empty\n' "$base" > "$case_dir/data/task-x1/report.md"
    # Empty directories have no file/link manifest rows. Remove this member
    # at the last verification boundary, not the source or earlier snapshot.
    cat > "$case_dir/fakebin/sort" <<SH
#!/usr/bin/env bash
"$real_sort" "\$@" || exit \$?
case "\${!#}" in
  *'.evidence.new.'*/MANIFEST.sha256.links)
    stage=\${!#}; stage=\${stage%/*}
    if [ "$root_name" = copy ]; then key=copy/workspace/empty; else key=tmp/empty; fi
    rmdir -- "\$stage/\$key" || exit 1
    : > "$case_dir/fault-seen" ;;
esac
SH
    chmod +x "$case_dir/fakebin/sort"
    for flag in '' --force; do
      rm -f "$case_dir/fault-seen"
      rc=0
      run_teardown "$case_dir" ${flag:+"$flag"} > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
      [ "$rc" -ne 0 ] || fail 'missing staged member covered existing source'
      assert_present "$case_dir/fault-seen" 'missing staged member fault was not reached'
      assert_grep "references $base/empty, which cleanup would destroy" "$case_dir/stderr" 'missing staged member must refuse citation'
      assert_present "$base/empty" 'staged-member refusal changed source'
      [ "$(cat "$ev/sentinel")" = 'prior snapshot' ] || fail 'staged-member refusal replaced prior evidence'
      assert_absent "$ev/copy" 'staged-member refusal installed copy evidence'
      assert_absent "$ev/tmp" 'staged-member refusal installed tmp evidence'
      assert_present "$case_dir/state/task-x1.meta" 'staged-member refusal removed metadata'
    done
  done
  pass 'a missing staged empty-directory member cannot cover its still-existing declared source'
}

# These use the public preservation entry point only, with fixture-owned data.
# This call has its own watchdog and successful-completion assertion. Scanner
# mutants need an isolated public-entry run too: other pooled cases can hang.
test_unreadable_evidence_records_skip_with_one_warning() {
  local flag case_dir file dir rc path log
  for flag in normal force; do
    case_dir=$(make_case "evidence-unreadable-$flag")
    write_meta "$case_dir" local-only ship
    ignore_workspace "$case_dir"
    land_shippable_commit "$case_dir"
    mkdir -p "$case_dir/wt/workspace" "$case_dir/data/task-x1/hidden"
    printf proof > "$case_dir/wt/workspace/proof"
    file="$case_dir/data/task-x1/unreadable.md"
    dir="$case_dir/data/task-x1/hidden"
    printf '%s/workspace/proof\n' "$case_dir/wt" > "$file"
    printf '%s/workspace/proof\n' "$case_dir/wt" > "$dir/report.md"
    printf '%s/workspace/proof\n' "$case_dir/wt" > "$case_dir/data/task-x1/readable.md"
    chmod 000 "$file" "$dir"
    if [ -r "$file" ] || [ -r "$dir" ]; then
      chmod 700 "$dir"; chmod 600 "$file"
      printf 'SKIP: unreadable-record permissions are bypassed by this user\n'
      return
    fi
    rc=0
    # shellcheck disable=SC2016 # Child positional parameters.
    bash -c '. "$1"; fm_task_evidence_preserve task-x1 "$2" "$3" 1 ""' \
      _ "$ROOT/bin/fm-task-evidence-lib.sh" "$case_dir/data" "$case_dir/wt" \
      > "$case_dir/preserve.out" 2> "$case_dir/preserve.err" || rc=$?
    # Keep running through both checks so a skip never hides a readable record.
    printf '%s\n' "$rc" > "$case_dir/preserve.rc"
    rm "$case_dir/data/task-x1/readable.md"
    rc=0
    if [ "$flag" = force ]; then
      run_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
    else
      run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
    fi
    chmod 700 "$dir"; chmod 600 "$file"
    expect_code 1 "$(cat "$case_dir/preserve.rc")" 'unreadable records must not hide a readable uncovered citation'
    assert_grep "references $case_dir/wt/workspace/proof, which cleanup would destroy" \
      "$case_dir/preserve.err" 'readable record classification changed after a grep read error'
    expect_code 0 "$rc" "unreadable records must keep their non-blocking skip policy ($flag): $(cat "$case_dir/stderr")"
    for log in "$case_dir/preserve.err" "$case_dir/stderr"; do
      for path in "$file" "$dir"; do
        [ "$(grep -Fc "WARNING: skipping unreadable evidence record or directory $path" "$log")" = 1 ] \
          || fail "skip should warn exactly once for $path in $log"
      done
    done
    assert_absent "$case_dir/state/task-x1.meta" 'unreadable records blocked cleanup'
  done
  pass 'unreadable evidence records and directories skip non-blockingly with one warning per path, without hiding readable citations'
}

test_evidence_bulk_scan_reads_each_record_once() {
  local case_dir n rc calls
  case_dir=$(make_case evidence-bulk-scan)
  mkdir -p "$case_dir/data/task-x1/records" "$case_dir/tasktmp"
  for ((n=0; n<1200; n++)); do
    printf '%02048d\n' "$n" > "$case_dir/data/task-x1/records/$n.md"
  done
  printf '%s\n' "$case_dir/wt/uncovered" "$case_dir/tasktmp/uncovered" \
    > "$case_dir/data/task-x1/report.md"
  printf proof > "$case_dir/wt/uncovered"
  printf proof > "$case_dir/tasktmp/uncovered"
  cat > "$case_dir/fakebin/grep" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = -IHZF ]; then
  printf 'batch\n' >> "$case_dir/batches"
  for arg in "\$@"; do
    case "\$arg" in "$case_dir/data/task-x1/"*) printf '%s\n' "\$arg" >> "$case_dir/reads" ;; esac
  done
fi
exec "$(command -v grep)" "\$@"
SH
  chmod +x "$case_dir/fakebin/grep"
  rc=0
  # shellcheck disable=SC2016 # Child positional parameters.
  PATH="$case_dir/fakebin:$PATH" bash -c \
    '. "$1"; fm_task_evidence_preserve task-x1 "$2" "$3" 1 "$4"' \
    _ "$ROOT/bin/fm-task-evidence-lib.sh" "$case_dir/data" "$case_dir/wt" "$case_dir/tasktmp" \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 1 "$rc" 'bulk scan must still refuse uncovered references in both roots'
  assert_grep "references $case_dir/wt/uncovered, which cleanup would destroy" "$case_dir/stderr" 'copy classification changed'
  assert_grep "references $case_dir/tasktmp/uncovered, which cleanup would destroy" "$case_dir/stderr" 'tmp classification changed'
  [ "$(wc -l < "$case_dir/reads" | tr -d ' ')" = 1201 ] || fail 'not every durable record was read once'
  [ -z "$(sort "$case_dir/reads" | uniq -d)" ] || fail 'a record was read more than once'
  calls=$(wc -l < "$case_dir/batches" | tr -d ' ')
  [ "$calls" -le 20 ] || fail "bulk scan spawned $calls grep processes for 1201 records"
  pass 'one bulk content pass covers both roots with bounded grep batches, not per-record processes'
}

test_evidence_text_scan_is_outside_project_lock_and_changes_refuse() {
  local variant case_dir wt rc
  for variant in stable edit add remove replace declaration during-scan during-copy meta-worktree meta-tasktmp meta-kind; do
    case_dir=$(make_case "evidence-unlocked-$variant")
    wt=$(move_case_to_pool_slot "$case_dir" 1)
    write_meta "$case_dir" local-only ship "$wt"
    mkdir -p "$case_dir/data/task-x1"
    printf 'plain durable record\n' > "$case_dir/data/task-x1/report.md"
    printf proof > "$wt/proof"
    printf 'proof\n' > "$case_dir/data/task-x1/evidence.list"
    cat > "$case_dir/fakebin/grep" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = -IHZF ]; then
  for lock in "$case_dir/state/".treehouse-project-*.lock; do
    [ ! -e "\$lock" ] || { echo 'text scan held project lock' >&2; exit 2; }
  done
  printf 'unlocked\n' >> "$case_dir/scan-state"
  if [ "$variant" = during-scan ]; then
    "$(command -v grep)" "\$@"
    rc=\$?
    printf 'concurrent edit\n' >> "$case_dir/data/task-x1/report.md"
    exit "\$rc"
  fi
fi
exec "$(command -v grep)" "\$@"
SH
    cat > "$case_dir/fakebin/cp" <<SH
#!/usr/bin/env bash
case "\$*" in
  *'.evidence.new.'*'/copy/proof')
    held=0
    for lock in "$case_dir/state/".treehouse-project-*.lock; do
      [ ! -d "\$lock" ] || held=1
    done
    [ "\$held" = 1 ] || { echo 'evidence copy lacked project lock' >&2; exit 1; }
    : > "$case_dir/copied-locked"
    "$(command -v cp)" "\$@" || exit
    if [ "$variant" = during-copy ]; then
      printf 'concurrent edit\n' >> "$case_dir/data/task-x1/report.md"
    fi
    exit 0 ;;
esac
exec "$(command -v cp)" "\$@"
SH
    cat > "$case_dir/fakebin/mkdir" <<SH
#!/usr/bin/env bash
case "\$*" in
  *'.treehouse-project-'*'.lock'*)
    if [ ! -e "$case_dir/mutated" ]; then
      : > "$case_dir/mutated"
      case "$variant" in
        edit) printf 'changed\n' >> "$case_dir/data/task-x1/report.md" ;;
        add) printf 'new record\n' > "$case_dir/data/task-x1/new.md" ;;
        remove) rm "$case_dir/data/task-x1/report.md" ;;
        replace) mv "$case_dir/data/task-x1/report.md" "$case_dir/old"; printf 'plain durable record\n' > "$case_dir/data/task-x1/report.md" ;;
        declaration) printf '# changed declarations\n' > "$case_dir/data/task-x1/evidence.list" ;;
        meta-worktree)
          sed 's#^worktree=.*#worktree=$wt/#' "$case_dir/state/task-x1.meta" > "$case_dir/meta.new"
          mv "$case_dir/meta.new" "$case_dir/state/task-x1.meta" ;;
        meta-tasktmp) printf 'tasktmp=$case_dir/tasktmp\n' >> "$case_dir/state/task-x1.meta" ;;
        meta-kind)
          sed 's/^kind=ship$/kind=scout/' "$case_dir/state/task-x1.meta" > "$case_dir/meta.new"
          mv "$case_dir/meta.new" "$case_dir/state/task-x1.meta" ;;
      esac
    fi ;;
esac
exec "$(command -v mkdir)" "\$@"
SH
    cat > "$case_dir/fakebin/treehouse" <<SH
#!/usr/bin/env bash
for lock in "$case_dir/state/".treehouse-project-*.lock; do
  if [ -d "\$lock" ]; then : > "$case_dir/returned-locked"; exit 0; fi
done
echo 'return lacked project lock' >&2
exit 1
SH
    chmod +x "$case_dir/fakebin/grep" "$case_dir/fakebin/cp" "$case_dir/fakebin/mkdir" "$case_dir/fakebin/treehouse"
    rc=0
    FM_HOME="$case_dir" run_teardown "$case_dir" --force \
      > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
    assert_present "$case_dir/scan-state" 'bulk text prefilter did not run unlocked'
    if [ "$variant" != during-scan ]; then
      assert_present "$case_dir/mutated" 'test did not reach project-lock acquisition'
    fi
    if [ "$variant" = stable ]; then
      expect_code 0 "$rc" "unchanged records should clean up: $(cat "$case_dir/stderr")"
      assert_present "$case_dir/returned-locked" 'destructive return did not hold the project lock'
      assert_present "$case_dir/copied-locked" 'evidence preservation did not hold the project lock'
      evidence_manifest_verifies "$case_dir/data/task-x1/evidence" || fail 'unlocked prefilter changed preserved manifest'
    else
      expect_code 1 "$rc" "changed $variant records must refuse even under --force"
      if [ "$variant" = during-scan ]; then
        assert_grep 'durable records changed during the unlocked scan' "$case_dir/stderr" 'scan-time edit did not refuse'
      else
        case "$variant" in
          meta-*) assert_grep 'task evidence roots changed since the unlocked scan' "$case_dir/stderr" 'metadata-root drift did not refuse' ;;
          *) assert_grep 'durable records changed since the unlocked scan' "$case_dir/stderr" 'inventory change did not refuse' ;;
        esac
      fi
      if [ "$variant" = during-copy ]; then
        assert_present "$case_dir/copied-locked" 'test did not mutate during locked preservation'
      fi
      assert_present "$case_dir/state/task-x1.meta" 'inventory refusal removed task metadata'
      assert_absent "$case_dir/returned-locked" 'inventory refusal returned the copy'
    fi
  done
  pass 'text scans run unlocked; record edits, membership, replacement and declarations are rechecked under the destructive lock'
}

test_evidence_citation_scan_completes_for_a_plain_missing_path() {
  local case_dir rc
  case_dir=$(make_case evidence-bounded-citation)
  mkdir -p "$case_dir/data/task-x1"
  printf '%s/absent\n' "$case_dir/wt" > "$case_dir/data/task-x1/report.md"
  # shellcheck source=bin/fm-timeout-lib.sh disable=SC1091
  . "$ROOT/bin/fm-timeout-lib.sh"
  rc=0
  # shellcheck disable=SC2016 # Positional parameters belong to the child bash.
  fm_run_timed 30 bash -c '. "$1"; fm_task_evidence_preserve task-x1 "$2" "$3" 1 ""' \
    _ "$ROOT/bin/fm-task-evidence-lib.sh" "$case_dir/data" "$case_dir/wt" \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 0 "$rc" 'plain missing citation must finish its bounded scan'
  assert_grep "references missing path $case_dir/wt/absent; there is nothing left to save" \
    "$case_dir/stderr" 'bounded scan must deliver its missing-path warning'
  assert_absent "$case_dir/data/task-x1/evidence" 'missing citation invented an evidence snapshot'
  pass 'a plain missing citation at the start and end of a line terminates and warns'
}

test_evidence_physical_root_aliases_do_not_hide_existing_citations() {
  local case_dir root_name root rc
  for root_name in copy tmp; do
    case_dir=$(make_case "evidence-physical-root-$root_name")
    mkdir -p "$case_dir/data/task-x1" "$case_dir/actual"
    ln -s actual "$case_dir/alias"
    printf 'uncovered bytes\n' > "$case_dir/actual/proof"
    printf 'See %s/alias/proof\n' "$case_dir" > "$case_dir/data/task-x1/report.md"
    root="$case_dir/alias"
    rc=0
    if [ "$root_name" = copy ]; then
      bash -c '. "$1"; fm_task_evidence_preserve task-x1 "$2" "$3" 1 ""' \
        _ "$ROOT/bin/fm-task-evidence-lib.sh" "$case_dir/data" "$root" \
        > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
    else
      bash -c '. "$1"; fm_task_evidence_preserve task-x1 "$2" "" 1 "$3"' \
        _ "$ROOT/bin/fm-task-evidence-lib.sh" "$case_dir/data" "$root" \
        > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
    fi
    [ "$rc" -ne 0 ] || fail "$root_name physical alias hid an existing undeclared citation"
    assert_grep "references $root/proof, which cleanup would destroy" "$case_dir/stderr" 'alias must reach the coverage refusal'
    [ "$(cat "$case_dir/actual/proof")" = 'uncovered bytes' ] || fail 'alias refusal changed source bytes'
    assert_absent "$case_dir/data/task-x1/evidence" 'alias refusal installed evidence'
  done
  pass 'physical aliases of either recorded root cannot make existing disposable objects look outside'
}

test_evidence_link_physical_failures_and_dangling_newlines_refuse() {
  local case_dir root_name variant flag base target fault ev rc
  for root_name in copy tmp; do
    for variant in dangling-newline physical-newline parent-pwd final-pwd; do
      for flag in '' --force; do
        case_dir=$(make_case "evidence-extra-link-$root_name-$variant-${flag:-normal}")
        ignore_workspace "$case_dir"
        write_meta "$case_dir" no-mistakes ship
        printf 'tasktmp=%s/tasktmp\n' "$case_dir" >> "$case_dir/state/task-x1.meta"
        land_shippable_commit "$case_dir"
        mkdir -p "$case_dir/wt/workspace" "$case_dir/tasktmp" "$case_dir/outside/parent" "$case_dir/data/task-x1"
        if [ "$root_name" = copy ]; then base="$case_dir/wt/workspace"; else base="$case_dir/tasktmp"; fi
        target="$case_dir/outside/parent/directory"
        mkdir -p "$target"
        printf 'outside bytes\n' > "$target/proof"
        fault="$case_dir/outside/parent"
        case "$variant" in
          dangling-newline) target="$case_dir/outside/absent"$'\n' ;;
          physical-newline)
            mkdir -p "$case_dir/outside/parent"$'\n'
            ln -s "parent"$'\n' "$case_dir/outside/plain-parent"
            target="$case_dir/outside/plain-parent/proof"
            printf 'outside bytes\n' > "$target" ;;
          final-pwd) fault=$target ;;
        esac
        ln -s "$target" "$base/link"
        printf '%s\n' "$base/link" > "$case_dir/data/task-x1/evidence.list"
        ev="$case_dir/data/task-x1/evidence"
        mkdir -p "$ev"; printf 'prior bytes\n' > "$ev/sentinel"
        cat > "$case_dir/pwd-fault.sh" <<SH
if [ "\${0##*/}" = fm-teardown.sh ]; then
  pwd() {
    if [ "\$PWD" = "$fault" ]; then : > "$case_dir/fault-seen"; return 1; fi
    builtin pwd "\$@"
  }
fi
SH
        rc=0
        case "$variant" in
          *-pwd)
            BASH_ENV="$case_dir/pwd-fault.sh" run_teardown "$case_dir" ${flag:+"$flag"} \
              > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$? ;;
          *) run_teardown "$case_dir" ${flag:+"$flag"} > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$? ;;
        esac
        [ "$rc" -ne 0 ] || fail "$root_name $variant ${flag:-normal}: unsupported link resolution passed"
        case "$variant" in
          dangling-newline) assert_grep 'unsupported newline text' "$case_dir/stderr" 'a missing target does not permit unsupported link text' ;;
          *) assert_grep 'cannot resolve evidence symlink' "$case_dir/stderr" 'physical failure must not become link survival' ;;
        esac
        case "$variant" in *-pwd) assert_present "$case_dir/fault-seen" 'target physical lookup injection was not reached' ;; esac
        [ -L "$base/link" ] || fail 'physical refusal removed source link'
        [ "$(cat "$ev/sentinel")" = 'prior bytes' ] || fail 'physical refusal replaced prior snapshot'
        assert_absent "$ev/copy" 'physical refusal installed a partial snapshot'
        assert_present "$case_dir/state/task-x1.meta" 'physical refusal removed metadata'
        case "$variant" in
          *-pwd)
            rc=0
            run_teardown "$case_dir" ${flag:+"$flag"} > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
            expect_code 0 "$rc" "resolvable outside directory control must pass: $(cat "$case_dir/stderr")"
            evidence_manifest_verifies "$ev" || fail 'resolvable control snapshot does not verify'
            [ "$(cat "$target/proof")" = 'outside bytes' ] || fail 'outside control target changed' ;;
        esac
      done
    done
  done
  pass 'dangling newline text and initial/final physical lookup errors refuse, with resolvable outside controls'
}

test_evidence_copy_errors_cannot_replace_an_earlier_snapshot() {
  local case_dir root_name variant flag base label ev hash rc
  for root_name in copy tmp; do
    for variant in fresh prior; do
      for flag in '' --force; do
        case_dir=$(make_case "evidence-copy-error-$root_name-$variant-${flag:-normal}")
        ignore_workspace "$case_dir"
        write_meta "$case_dir" no-mistakes ship
        printf 'tasktmp=%s/tasktmp\n' "$case_dir" >> "$case_dir/state/task-x1.meta"
        land_shippable_commit "$case_dir"
        mkdir -p "$case_dir/wt/workspace" "$case_dir/tasktmp"
        if [ "$root_name" = copy ]; then base="$case_dir/wt/workspace"; label=copy/workspace; else base="$case_dir/tasktmp"; label=tmp; fi
        ev="$case_dir/data/task-x1/evidence"
        mkdir -p "$ev/$label"
        printf 'prior bytes\n' > "$ev/$label/proof"
        hash=$({ sha256sum "$ev/$label/proof" 2>/dev/null || shasum -a 256 "$ev/$label/proof"; } | awk '{print $1}')
        printf '%s  %s/proof\n' "$hash" "$label" > "$ev/MANIFEST.sha256"
        if [ "$variant" = fresh ]; then printf 'fresh bytes\n' > "$base/proof"; fi
        # Isolate copy refusal from the independent absolute-citation guard.
        printf '%s\n' "$base/proof" > "$case_dir/declarations"
        ln -s "$case_dir/declarations" "$case_dir/data/task-x1/evidence.list"
        cat > "$case_dir/fakebin/cp" <<SH
#!/usr/bin/env bash
: > "$case_dir/fault-seen"
exit 1
SH
        chmod +x "$case_dir/fakebin/cp"
        rc=0
        run_teardown "$case_dir" ${flag:+"$flag"} > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
        [ "$rc" -ne 0 ] || fail "$variant copy failure was accepted ${flag:-without force}"
        assert_present "$case_dir/fault-seen" 'copy failure boundary was not reached'
        if [ "$variant" = fresh ]; then
          assert_grep 'could not copy and verify' "$case_dir/stderr" 'fresh copy failure must propagate'
          [ "$(cat "$base/proof")" = 'fresh bytes' ] || fail 'fresh copy failure changed source'
        else
          assert_grep 'no verified earlier copy' "$case_dir/stderr" 'carry copy failure must propagate'
        fi
        [ "$(cat "$ev/$label/proof")" = 'prior bytes' ] || fail 'copy failure replaced earlier evidence'
        assert_present "$case_dir/state/task-x1.meta" 'copy failure removed metadata'
      done
    done
  done
  pass 'fresh and carried copy failures refuse without replacing earlier evidence in either root or force mode'
}

# Fail the printf write boundary itself, after copy/hash success. No filesystem
# permission assumption (CI may be root) or production helper override is needed.
# The unfaulted unsafe-target refusal and safe-target success are separate controls.
test_evidence_link_manifest_append_errors_refuse_without_discarding() {
  local case_dir root_name variant flag base label key source ev target hash rc
  for root_name in copy tmp; do
    for variant in fresh-link fresh-directory prior; do
      for flag in '' --force; do
        case_dir=$(make_case "evidence-link-append-$root_name-$variant-${flag:-normal}")
        ignore_workspace "$case_dir"
        write_meta "$case_dir" no-mistakes ship
        printf 'tasktmp=%s/tasktmp\n' "$case_dir" >> "$case_dir/state/task-x1.meta"
        land_shippable_commit "$case_dir"
        mkdir -p "$case_dir/wt/workspace" "$case_dir/tasktmp" "$case_dir/outside" "$case_dir/data/task-x1"
        if [ "$root_name" = copy ]; then base="$case_dir/wt/workspace"; label=copy/workspace
        else base="$case_dir/tasktmp"; label=tmp; fi
        key="$label/link"; source="$base/link"
        ev="$case_dir/data/task-x1/evidence"
        target="$case_dir/tasktmp/uncovered"
        printf 'undeclared target bytes\n' > "$target"
        if [ "$variant" = prior ]; then
          mkdir -p "$ev/$label"
          ln -s "$target" "$ev/$key"
          hash=$(readlink "$ev/$key" | { sha256sum 2>/dev/null || shasum -a 256; } | awk '{print $1}')
          : > "$ev/MANIFEST.sha256"
          printf '%s  %s\n' "$hash" "$key" > "$ev/MANIFEST.sha256.links"
          cp "$ev/MANIFEST.sha256.links" "$case_dir/prior-links"
          printf 'prior snapshot\n' > "$ev/sentinel"
          printf '%s\n' "$source" > "$case_dir/declarations"
        else
          if [ "$variant" = fresh-directory ]; then
            mkdir -p "$base/links"
            source="$base/links/link"; key="$label/links/link"
            printf '%s\n' "$base/links" > "$case_dir/declarations"
          else
            printf '%s\n' "$source" > "$case_dir/declarations"
          fi
          ln -s "$case_dir/outside" "$source"
        fi
        # A symlinked declaration record avoids unrelated absolute-reference
        # refusals masking a failed copy/carry return under a counterfactual.
        ln -s "$case_dir/declarations" "$case_dir/data/task-x1/evidence.list"
        cat > "$case_dir/append-fault.sh" <<'SH'
if [ "${0##*/}" = fm-teardown.sh ]; then
  printf() {
    case "$FM_APPEND_KIND:${1-}" in
      fresh*:'%s  %s%s\n')
        if [ "${3-}${4-}" = "$FM_APPEND_KEY" ]; then
          : > "$FM_APPEND_SEEN"
          return 1
        fi ;;
      prior:'%s\n')
        case "${2-}" in
          *"  $FM_APPEND_KEY") : > "$FM_APPEND_SEEN"; return 1 ;;
        esac ;;
    esac
    builtin printf "$@"
  }
fi
SH
        rc=0
        FM_APPEND_KIND="$variant" FM_APPEND_KEY="$key" FM_APPEND_SEEN="$case_dir/fault-seen" \
          BASH_ENV="$case_dir/append-fault.sh" run_teardown "$case_dir" ${flag:+"$flag"} \
          > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
        [ "$rc" -ne 0 ] || fail "$root_name $variant ${flag:-normal}: failed link-manifest append was accepted"
        assert_present "$case_dir/fault-seen" 'link-manifest append injection was not reached'
        if [ "$variant" = prior ]; then
          assert_grep 'no verified earlier copy' "$case_dir/stderr" 'carried link-manifest failure must propagate'
          cmp -s "$case_dir/prior-links" "$ev/MANIFEST.sha256.links" || fail 'append failure changed prior manifest'
          [ ! -s "$ev/MANIFEST.sha256" ] || fail 'append failure changed prior regular manifest'
          [ "$(cat "$ev/sentinel")" = 'prior snapshot' ] || fail 'append failure replaced prior tree'
          [ -L "$ev/$key" ] && [ "$(readlink "$ev/$key")" = "$target" ] || fail 'append failure changed prior link'
          assert_absent "$source" 'append failure recreated the absent original'
        else
          assert_grep 'could not copy and verify' "$case_dir/stderr" 'fresh link-manifest failure must propagate'
          assert_absent "$ev" 'failed fresh append installed or falsely discarded a snapshot'
          [ -L "$source" ] && [ "$(readlink "$source")" = "$case_dir/outside" ] || fail 'append failure changed source link'
        fi
        [ "$(cat "$target")" = 'undeclared target bytes' ] || fail 'append refusal destroyed undeclared target'
        assert_present "$case_dir/state/task-x1.meta" 'append refusal removed task metadata'

        # Without the write fault, a complete manifest must reach target safety.
        if [ "$variant" != prior ]; then rm "$source"; ln -s "$target" "$source"; fi
        rc=0
        run_teardown "$case_dir" ${flag:+"$flag"} > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
        [ "$rc" -ne 0 ] || fail 'unfaulted link to undeclared target escaped safety'
        assert_grep "$target, which cleanup would destroy" "$case_dir/stderr" 'unfaulted control must reach target refusal'
        [ "$(cat "$target")" = 'undeclared target bytes' ] || fail 'target refusal destroyed undeclared target'
        assert_present "$case_dir/state/task-x1.meta" 'target refusal removed metadata'
        if [ "$variant" = prior ]; then
          cmp -s "$case_dir/prior-links" "$ev/MANIFEST.sha256.links" || fail 'target refusal replaced prior manifest'
          [ "$(cat "$ev/sentinel")" = 'prior snapshot' ] || fail 'target refusal replaced prior tree'
          # Preserve the existing target rather than deleting it for success.
          printf '%s\n' "$target" >> "$case_dir/declarations"
        else
          assert_absent "$ev" 'target refusal installed a partial snapshot'
          rm "$source"; ln -s "$case_dir/outside" "$source"
        fi
        rc=0
        run_teardown "$case_dir" ${flag:+"$flag"} > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
        expect_code 0 "$rc" "unfaulted safe link must preserve evidence: $(cat "$case_dir/stderr")"
        [ -L "$ev/$key" ] || fail 'safe link-only control discarded its snapshot'
        [ -s "$ev/MANIFEST.sha256.links" ] || fail 'safe link has no manifest row'
        evidence_manifest_verifies "$ev" || fail 'safe append control snapshot does not verify'
        if [ "$variant" = prior ]; then
          [ "$(cat "$ev/tmp/uncovered")" = 'undeclared target bytes' ] || fail 'declared target was not preserved'
        fi
        assert_absent "$case_dir/state/task-x1.meta" 'safe append control retained metadata'
      done
    done
  done
  pass 'fresh standalone/nested and carried link-manifest append failures refuse; unfaulted safety and success controls hold'
}

# One public teardown scenario, also callable in isolation by remote mutation
# proofs. The write fault is below the production helpers, after copying/hashing.
regular_manifest_append_case() {  # <root> <variant> <flag> <snapshot> [ownership] [fault|control]
  local root_name=$1 variant=$2 flag=$3 snapshot=$4 ownership=${5:-owned}
  local case_dir base label key source declaration ev hash rc
  case_dir=$(make_case "regular-append-$root_name-$variant-${flag:-normal}-$snapshot-$ownership")
  ignore_workspace "$case_dir"
  land_shippable_commit "$case_dir"
  if [ "$ownership" = reassigned ]; then
    # Fixture-only pool identity, not a real Treehouse allocation or lifecycle.
    mkdir -p "$case_dir/pool/1"
    mv "$case_dir/wt" "$case_dir/pool/1/project"
    ln -s pool/1/project "$case_dir/wt"
    printf '%s\n' "$case_dir/pool/1/project/.git" > "$case_dir/project/.git/worktrees/wt/gitdir"
    printf '{"worktrees":[{"name":"1","path":"%s"}]}\n' \
      "$case_dir/pool/1/project" > "$case_dir/pool/treehouse-state.json"
    printf 'task=successor\nhome=%s\n' "$case_dir" > "$case_dir/pool/1/.fm-slot-owner"
    cp "$case_dir/pool/1/.fm-slot-owner" "$case_dir/claim-before"
  fi
  write_meta "$case_dir" no-mistakes ship
  printf 'tasktmp=%s/tasktmp\n' "$case_dir" >> "$case_dir/state/task-x1.meta"
  cp "$case_dir/state/task-x1.meta" "$case_dir/meta-before"
  mkdir -p "$case_dir/wt/workspace" "$case_dir/tasktmp" "$case_dir/data/task-x1"
  if [ "$root_name" = copy ]; then base="$case_dir/wt/workspace"; label=copy/workspace
  else base="$case_dir/tasktmp"; label=tmp; fi
  if [ "$variant" = fresh-directory ]; then
    source="$base/proofs/proof"; key="$label/proofs/proof"; declaration="$base/proofs"
  else
    source="$base/proof"; key="$label/proof"; declaration=$source
  fi
  ev="$case_dir/data/task-x1/evidence"
  if [ "$snapshot" = prior ]; then
    mkdir -p "$ev/${key%/*}"
    printf 'prior evidence bytes\n' > "$ev/$key"
    hash=$({ sha256sum "$ev/$key" 2>/dev/null || shasum -a 256 "$ev/$key"; } | awk '{print $1}')
    printf '%s  %s\n' "$hash" "$key" > "$ev/MANIFEST.sha256"
    : > "$ev/MANIFEST.sha256.links"
    printf 'prior tree sentinel\n' > "$ev/sentinel"
    evidence_manifest_verifies "$ev" || fail 'regular append prior fixture does not verify'
    cp -RPp "$ev" "$case_dir/prior-tree"
  fi
  if [ "$variant" != prior ]; then
    mkdir -p "${source%/*}"
    printf 'fresh evidence bytes\n' > "$source"
    if [ "$variant" = fresh-directory ]; then
      printf 'later directory member\n' > "${source%/*}/zz-after"
    fi
  elif [ "$ownership" = reassigned ]; then
    printf 'foreign evidence bytes\n' > "$source"
  fi
  # Keep absolute-citation scanning from independently masking a failed append.
  printf '%s\n' "$declaration" > "$case_dir/declarations"
  ln -s "$case_dir/declarations" "$case_dir/data/task-x1/evidence.list"
  cat > "$case_dir/append-fault.sh" <<'SH'
if [ "${0##*/}" = fm-teardown.sh ]; then
  # A failed first row must not be masked by a successful later directory row.
  find() {
    if [ "$FM_APPEND_KIND" = fresh-directory ] && [ "${2-} ${3-}" = '-type f' ]; then
      command find "$@" | LC_ALL=C sort
    else
      command find "$@"
    fi
  }
  printf() {
    case "$FM_APPEND_KIND:${1-}" in
      fresh-directory:'%s  %s%s\n')
        if [ "${3-}${4-}" = "$FM_APPEND_KEY" ]; then
          : > "$FM_APPEND_SEEN"; return 1
        fi ;;
      fresh-file:'%s  %s\n')
        if [ "${3-}" = "$FM_APPEND_KEY" ]; then
          : > "$FM_APPEND_SEEN"; return 1
        fi ;;
      prior:'%s\n')
        case "${2-}" in *"  $FM_APPEND_KEY") : > "$FM_APPEND_SEEN"; return 1 ;; esac ;;
    esac
    builtin printf "$@"
  }
fi
SH
  if [ "${6:-fault}" = fault ]; then
  rc=0
  FM_HOME="$case_dir" FM_APPEND_KIND="$variant" FM_APPEND_KEY="$key" FM_APPEND_SEEN="$case_dir/fault-seen" \
    BASH_ENV="$case_dir/append-fault.sh" run_teardown "$case_dir" ${flag:+"$flag"} \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 1 "$rc" "$root_name $variant ${flag:-normal} $snapshot $ownership: failed regular-manifest append was accepted"
  assert_present "$case_dir/fault-seen" 'regular-manifest append fault was not reached'
  if [ "$ownership" = reassigned ]; then
    assert_grep 'REFUSED: could not stage verified earlier evidence' "$case_dir/stderr" 'carry staging failure became old-source-loss warning'
  elif [ "$variant" = prior ]; then
    assert_grep 'no verified earlier copy' "$case_dir/stderr" 'owned carry append failure did not propagate'
  else
    assert_grep 'could not copy and verify' "$case_dir/stderr" 'fresh regular append failure did not propagate'
  fi
  cmp -s "$case_dir/meta-before" "$case_dir/state/task-x1.meta" || fail 'regular append refusal changed metadata bytes'
  if [ "$snapshot" = prior ]; then
    diff -r "$case_dir/prior-tree" "$ev" || fail 'regular append refusal changed prior tree or manifest bytes'
    evidence_manifest_verifies "$ev" || fail 'regular append refusal damaged prior proof'
  else
    assert_absent "$ev" 'regular append failure installed an incomplete snapshot'
  fi
  if [ "$ownership" = reassigned ]; then
    [ "$(cat "$source")" = 'foreign evidence bytes' ] || fail 'regular carry refusal changed foreign bytes'
    cmp -s "$case_dir/claim-before" "$case_dir/pool/1/.fm-slot-owner" || fail 'regular carry refusal changed successor claim'
  elif [ "$variant" = prior ]; then
    assert_absent "$source" 'regular carry refusal recreated absent source'
  else
    [ "$(cat "$source")" = 'fresh evidence bytes' ] || fail 'regular append refusal changed source bytes'
    if [ "$variant" = fresh-directory ]; then
      [ "$(cat "${source%/*}/zz-after")" = 'later directory member' ] || fail 'directory append refusal changed later member'
    fi
  fi
  fi
  # The exact same fixture must succeed without the fault, through teardown.
  # Remote counterfactuals also call this control independently, so an early
  # failure cannot hide a success-path behavioral discriminator.
  rc=0
  FM_HOME="$case_dir" run_teardown "$case_dir" ${flag:+"$flag"} > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 0 "$rc" "unfaulted regular append retry failed: $(cat "$case_dir/stderr")"
  evidence_manifest_verifies "$ev" || fail 'regular append retry snapshot does not verify'
  grep -Fq "  $key" "$ev/MANIFEST.sha256" || fail 'regular append retry omitted promised row'
  if [ "$variant" = prior ]; then
    [ "$(cat "$ev/$key")" = 'prior evidence bytes' ] || fail 'carry retry lost prior evidence'
    cmp -s "$case_dir/prior-tree/MANIFEST.sha256" "$ev/MANIFEST.sha256" || fail 'carry retry changed regular manifest bytes'
    cmp -s "$case_dir/prior-tree/MANIFEST.sha256.links" "$ev/MANIFEST.sha256.links" || fail 'carry retry changed link manifest bytes'
  else
    [ "$(cat "$ev/$key")" = 'fresh evidence bytes' ] || fail 'fresh retry saved wrong bytes'
    if [ "$variant" = fresh-directory ]; then
      [ "$(cat "$ev/${key%/*}/zz-after")" = 'later directory member' ] || fail 'directory retry omitted later member'
      grep -Fq "  ${key%/*}/zz-after" "$ev/MANIFEST.sha256" || fail 'directory retry omitted later row'
    fi
  fi
  if [ "$ownership" = reassigned ]; then
    [ "$(cat "$source")" = 'foreign evidence bytes' ] || fail 'carry retry touched successor content'
    cmp -s "$case_dir/claim-before" "$case_dir/pool/1/.fm-slot-owner" || fail 'carry retry changed successor claim'
    assert_grep 'was reassigned to task successor' "$case_dir/stderr" 'retry did not exercise reassigned-copy caller'
  fi
  assert_absent "$case_dir/state/task-x1.meta" 'regular append retry left metadata'
}

test_regular_manifest_append_errors_refuse_without_discarding() {
  local root_name variant flag snapshot
  for root_name in copy tmp; do
    for flag in '' --force; do
      for variant in fresh-directory fresh-file prior; do
        for snapshot in absent prior; do
          # Carry needs a verified snapshot; missing proof has separate coverage.
          [ "$variant:$snapshot" != prior:absent ] || continue
          regular_manifest_append_case "$root_name" "$variant" "$flag" "$snapshot"
        done
      done
    done
  done
  for flag in '' --force; do
    regular_manifest_append_case copy prior "$flag" prior reassigned
  done
  pass 'all regular-manifest append boundaries refuse intact in both roots/force modes; unfaulted retries verify, including reassigned copy carry'
}

# Isolated public-entry fixture for a destructive sort -o write failure, not
# an unreadable row or a production-helper override. Also used by remote proof.
manifest_sort_case() {  # <root> <regular|link> <flag> <fresh|carry> <absent|prior> [ownership] [fault|control]
  local root_name=$1 kind=$2 flag=$3 variant=$4 snapshot=$5 ownership=${6:-owned}
  local case_dir base label key source ev name hash rc staged
  case_dir=$(make_case "manifest-sort-$root_name-$kind-${flag:-normal}-$variant-$snapshot-$ownership")
  ignore_workspace "$case_dir"
  land_shippable_commit "$case_dir"
  if [ "$ownership" = reassigned ]; then
    # Fixture-only pool identity, never a real pool allocation or lifecycle.
    mkdir -p "$case_dir/pool/1"
    mv "$case_dir/wt" "$case_dir/pool/1/project"
    ln -s pool/1/project "$case_dir/wt"
    printf '%s\n' "$case_dir/pool/1/project/.git" > "$case_dir/project/.git/worktrees/wt/gitdir"
    printf '{"worktrees":[{"name":"1","path":"%s"}]}\n' \
      "$case_dir/pool/1/project" > "$case_dir/pool/treehouse-state.json"
    printf 'task=successor\nhome=%s\n' "$case_dir" > "$case_dir/pool/1/.fm-slot-owner"
    cp "$case_dir/pool/1/.fm-slot-owner" "$case_dir/claim-before"
  fi
  write_meta "$case_dir" no-mistakes ship
  printf 'tasktmp=%s/tasktmp\n' "$case_dir" >> "$case_dir/state/task-x1.meta"
  cp "$case_dir/state/task-x1.meta" "$case_dir/meta-before"
  mkdir -p "$case_dir/wt/workspace" "$case_dir/tasktmp" "$case_dir/outside" "$case_dir/data/task-x1"
  printf 'outside target bytes\n' > "$case_dir/outside/target"
  if [ "$root_name" = copy ]; then base="$case_dir/wt/workspace"; label=copy/workspace
  else base="$case_dir/tasktmp"; label=tmp; fi
  key="$label/proof"; source="$base/proof"
  name=MANIFEST.sha256
  [ "$kind" != link ] || name=$name.links
  ev="$case_dir/data/task-x1/evidence"
  if [ "$snapshot" = prior ]; then
    mkdir -p "$ev/$label"
    : > "$ev/MANIFEST.sha256"
    : > "$ev/MANIFEST.sha256.links"
    if [ "$kind" = link ]; then
      ln -s "$case_dir/outside/target" "$ev/$key"
      hash=$(readlink "$ev/$key" | { sha256sum 2>/dev/null || shasum -a 256; } | awk '{print $1}')
    else
      printf 'prior evidence bytes\n' > "$ev/$key"
      hash=$({ sha256sum "$ev/$key" 2>/dev/null || shasum -a 256 "$ev/$key"; } | awk '{print $1}')
    fi
    printf '%s  %s\n' "$hash" "$key" > "$ev/$name"
    printf 'prior tree sentinel\n' > "$ev/sentinel"
    evidence_manifest_verifies "$ev" || fail 'manifest sort prior fixture does not verify'
    cp -RPp "$ev" "$case_dir/prior-tree"
  fi
  if [ "$ownership" = reassigned ]; then
    printf 'foreign evidence bytes\n' > "$source"
  elif [ "$variant" = fresh ]; then
    if [ "$kind" = link ]; then ln -s "$case_dir/outside/target" "$source"
    else printf 'fresh evidence bytes\n' > "$source"; fi
  fi
  # No independent absolute-citation refusal may mask a swallowed sort error.
  printf '%s\n' "$source" > "$case_dir/declarations"
  ln -s "$case_dir/declarations" "$case_dir/data/task-x1/evidence.list"
  cat > "$case_dir/sort-fault.sh" <<'SH'
if [ "${0##*/}" = fm-teardown.sh ]; then
  sort() {
    case "${3-}" in
      "$FM_SORT_DIR"/.evidence.new.*/"$FM_SORT_NAME")
        if [ "${1-} ${2-}" = '-k2 -o' ] && [ "${4-}" = "${3-}" ]; then
          : > "$FM_SORT_SEEN"
          : > "$3"
          return 1
        fi ;;
    esac
    command sort "$@"
  }
fi
SH
  if [ "${7:-fault}" = fault ]; then
    rc=0
    FM_HOME="$case_dir" FM_SORT_DIR="$case_dir/data/task-x1" FM_SORT_NAME="$name" \
      FM_SORT_SEEN="$case_dir/fault-seen" BASH_ENV="$case_dir/sort-fault.sh" \
      run_teardown "$case_dir" ${flag:+"$flag"} > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
    expect_code 1 "$rc" "$root_name $kind ${flag:-normal} $variant $snapshot $ownership: failed manifest sort was accepted"
    assert_present "$case_dir/fault-seen" 'manifest sort write fault was not reached'
    grep -E "^REFUSED: could not sort staged evidence manifest .*/${name//./[.]} for task-x1$" \
      "$case_dir/stderr" >/dev/null || fail 'manifest sort failure did not name its refusal'
    cmp -s "$case_dir/meta-before" "$case_dir/state/task-x1.meta" || fail 'manifest sort refusal changed metadata bytes'
    if [ "$snapshot" = prior ]; then
      diff -r "$case_dir/prior-tree" "$ev" || fail 'manifest sort refusal changed prior tree or manifest bytes'
      evidence_manifest_verifies "$ev" || fail 'manifest sort refusal damaged prior proof'
    else
      assert_absent "$ev" 'manifest sort failure installed an incomplete snapshot'
    fi
    for staged in "$case_dir/data/task-x1"/.evidence.new.* "$case_dir/data/task-x1"/.evidence.old.*; do
      assert_absent "$staged" 'manifest sort refusal left a staging or replacement tree'
    done
    if [ "$ownership" = reassigned ]; then
      [ "$(cat "$source")" = 'foreign evidence bytes' ] || fail 'manifest sort refusal changed foreign source bytes'
      cmp -s "$case_dir/claim-before" "$case_dir/pool/1/.fm-slot-owner" || fail 'manifest sort refusal changed successor claim'
    elif [ "$variant" = carry ]; then
      assert_absent "$source" 'manifest sort refusal recreated absent source'
    elif [ "$kind" = link ]; then
      [ -L "$source" ] && [ "$(readlink "$source")" = "$case_dir/outside/target" ] || fail 'manifest sort refusal changed source link'
    else
      [ "$(cat "$source")" = 'fresh evidence bytes' ] || fail 'manifest sort refusal changed source bytes'
    fi
    [ "$(cat "$case_dir/outside/target")" = 'outside target bytes' ] || fail 'manifest sort refusal changed target bytes'
  fi
  # Same fixture retries unfaulted; control mode also reaches this independently.
  rc=0
  FM_HOME="$case_dir" run_teardown "$case_dir" ${flag:+"$flag"} > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 0 "$rc" "unfaulted manifest sort retry failed: $(cat "$case_dir/stderr")"
  evidence_manifest_verifies "$ev" || fail 'manifest sort retry snapshot does not verify'
  grep -Fq "  $key" "$ev/$name" || fail 'manifest sort retry omitted promised row'
  if [ "$kind" = link ]; then
    [ -L "$ev/$key" ] && [ "$(readlink "$ev/$key")" = "$case_dir/outside/target" ] || fail 'manifest sort retry lost link text'
  elif [ "$variant" = carry ]; then
    [ "$(cat "$ev/$key")" = 'prior evidence bytes' ] || fail 'manifest sort retry lost carried bytes'
  else
    [ "$(cat "$ev/$key")" = 'fresh evidence bytes' ] || fail 'manifest sort retry saved wrong bytes'
  fi
  if [ "$variant" = carry ]; then
    cmp -s "$case_dir/prior-tree/MANIFEST.sha256" "$ev/MANIFEST.sha256" || fail 'sort carry retry changed regular manifest bytes'
    cmp -s "$case_dir/prior-tree/MANIFEST.sha256.links" "$ev/MANIFEST.sha256.links" || fail 'sort carry retry changed link manifest bytes'
  fi
  if [ "$ownership" = reassigned ]; then
    [ "$(cat "$source")" = 'foreign evidence bytes' ] || fail 'manifest sort retry changed successor content'
    cmp -s "$case_dir/claim-before" "$case_dir/pool/1/.fm-slot-owner" || fail 'manifest sort retry changed successor claim'
    assert_grep 'was reassigned to task successor' "$case_dir/stderr" 'sort retry did not exercise reassigned-copy caller'
  fi
  [ "$(cat "$case_dir/outside/target")" = 'outside target bytes' ] || fail 'manifest sort retry changed outside target'
  assert_absent "$case_dir/state/task-x1.meta" 'manifest sort retry left metadata'
}

test_manifest_sort_errors_refuse_without_discarding() {
  local root_name kind flag snapshot
  for root_name in copy tmp; do
    for kind in regular link; do
      for flag in '' --force; do
        for snapshot in absent prior; do
          manifest_sort_case "$root_name" "$kind" "$flag" fresh "$snapshot"
        done
        manifest_sort_case "$root_name" "$kind" "$flag" carry prior
      done
    done
  done
  for kind in regular link; do
    for flag in '' --force; do
      manifest_sort_case copy "$kind" "$flag" carry prior reassigned
    done
  done
  pass 'truncating sort failures refuse both manifests in both roots/force modes, preserving prior/absent snapshots and sources; fresh/carry/reassigned retries verify'
}

# Exercise the public preservation entry with copy_owned=0, as the reassigned
# slot path in teardown does. Never inspect that slot, even after a carry fault.
test_reassigned_evidence_staging_errors_preserve_prior_snapshot() {
  local case_dir fault ev key target hash rc
  for fault in mkdir cp append; do
    case_dir=$(make_case "evidence-reassigned-staging-$fault")
    ev="$case_dir/data/task-x1/evidence"
    key=copy/workspace/link
    target="$case_dir/wt/workspace/foreign-target"
    mkdir -p "$ev/copy/workspace" "$case_dir/wt/workspace"
    printf 'foreign bytes\n' > "$target"
    ln -s "$target" "$ev/$key"
    hash=$(readlink "$ev/$key" | { sha256sum 2>/dev/null || shasum -a 256; } | awk '{print $1}')
    : > "$ev/MANIFEST.sha256"
    printf '%s  %s\n' "$hash" "$key" > "$ev/MANIFEST.sha256.links"
    printf 'prior snapshot\n' > "$ev/sentinel"
    cp "$ev/MANIFEST.sha256" "$case_dir/prior-regular"
    cp "$ev/MANIFEST.sha256.links" "$case_dir/prior-links"
    # The second declaration was never saved; it must still warn, not refuse.
    printf 'workspace/link\nworkspace/never-saved\n' > "$case_dir/data/task-x1/evidence.list"
    cat > "$case_dir/preserve-with-tripwire.sh" <<'SH'
. "$1"
foreign=$3
tripwire=$4
fault=$5
seen=$6
foreign_access() {
  local arg
  for arg in "$@"; do
    case "$arg" in "$foreign"|"$foreign"/*) builtin printf '%s\n' "$*" >> "$tripwire" ;; esac
  done
}
cd() { foreign_access "$@"; builtin cd "$@"; }
pwd() { foreign_access "$PWD"; builtin pwd "$@"; }
stat() { foreign_access "$@"; command stat "$@"; }
readlink() { foreign_access "$@"; command readlink "$@"; }
find() { foreign_access "$@"; command find "$@"; }
function [ {
  case "${1:-}" in
    -e|-L|-d|-f|-r|-w|-x|-s|-b|-c|-p|-S) foreign_access "${2:-}" ;;
    *) case "${2:-}" in -ef|-nt|-ot) foreign_access "${1:-}" "${3:-}" ;; esac ;;
  esac
  builtin [ "$@"
}
mkdir() {
  foreign_access "$@"
  case "$fault:$*" in mkdir:*'/.evidence.new.'*'/copy/workspace') : > "$seen"; return 1 ;; esac
  command mkdir "$@"
}
cp() {
  foreign_access "$@"
  case "$fault:$*" in cp:*'/.evidence.new.'*'/copy/workspace/link') : > "$seen"; return 1 ;; esac
  command cp "$@"
}
printf() {
  case "$fault:${1-}:${2-}" in
    append:'%s\n':*'  copy/workspace/link') : > "$seen"; return 1 ;;
  esac
  builtin printf "$@"
}
fm_task_evidence_preserve task-x1 "$2" "$foreign" 0 ''
SH
    rc=0
    bash "$case_dir/preserve-with-tripwire.sh" "$ROOT/bin/fm-task-evidence-lib.sh" \
      "$case_dir/data" "$case_dir/wt" "$case_dir/foreign-access" "$fault" "$case_dir/fault-seen" \
      > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
    [ "$rc" -ne 0 ] || fail "$fault: reassigned-copy staging failure was accepted"
    assert_present "$case_dir/fault-seen" "$fault: reassigned-copy staging injection was not reached"
    assert_grep 'REFUSED: could not stage verified earlier evidence' "$case_dir/stderr" 'staging failure must not become an old-source-loss warning'
    assert_absent "$case_dir/foreign-access" 'staging refusal inspected the reassigned slot'
    cmp -s "$case_dir/prior-regular" "$ev/MANIFEST.sha256" || fail 'staging refusal changed prior regular manifest'
    cmp -s "$case_dir/prior-links" "$ev/MANIFEST.sha256.links" || fail 'staging refusal changed prior link manifest'
    [ -L "$ev/$key" ] && [ "$(readlink "$ev/$key")" = "$target" ] || fail 'staging refusal changed prior link bytes'
    [ "$(cat "$ev/sentinel")" = 'prior snapshot' ] || fail 'staging refusal replaced the prior tree'
    evidence_manifest_verifies "$ev" || fail 'staging refusal damaged the verified prior snapshot'
    rc=0
    bash "$case_dir/preserve-with-tripwire.sh" "$ROOT/bin/fm-task-evidence-lib.sh" \
      "$case_dir/data" "$case_dir/wt" "$case_dir/foreign-access" none "$case_dir/fault-seen" \
      > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
    expect_code 0 "$rc" "unfaulted reassigned carried-link success must preserve evidence: $(cat "$case_dir/stderr")"
    assert_absent "$case_dir/foreign-access" 'unfaulted carry inspected the reassigned slot'
    cmp -s "$case_dir/prior-regular" "$ev/MANIFEST.sha256" || fail 'retry changed regular manifest bytes'
    cmp -s "$case_dir/prior-links" "$ev/MANIFEST.sha256.links" || fail 'retry changed link manifest bytes'
    [ -L "$ev/$key" ] && [ "$(readlink "$ev/$key")" = "$target" ] || fail 'retry changed carried link bytes'
    evidence_manifest_verifies "$ev" || fail 'unfaulted carried snapshot does not verify'
    assert_grep "warning: declared evidence $case_dir/wt/workspace/never-saved for task-x1 was not copied out before its pool slot was reassigned; it is lost" \
      "$case_dir/stderr" 'already-lost foreign source must retain its warning'
    [ "$(cat "$target")" = 'foreign bytes' ] || fail 'reassigned-copy carry changed foreign contents'
  done
  pass 'reassigned-copy staging failures preserve verified prior links; unfaulted retry and old-source-loss warning remain safe'
}

test_evidence_staging_ancestor_links_cannot_cover_source_content() {
  local case_dir root_name base label ev flag rc real_sort
  real_sort=$(command -v sort)
  for root_name in copy tmp; do
    case_dir=$(make_case "evidence-staged-ancestor-$root_name")
    ignore_workspace "$case_dir"
    write_meta "$case_dir" no-mistakes ship
    printf 'tasktmp=%s/tasktmp\n' "$case_dir" >> "$case_dir/state/task-x1.meta"
    land_shippable_commit "$case_dir"
    if [ "$root_name" = copy ]; then base="$case_dir/wt/workspace"; label=copy/workspace; else base="$case_dir/tasktmp"; label=tmp; fi
    mkdir -p "$base/container/empty"
    ev="$case_dir/data/task-x1/evidence"
    mkdir -p "$ev"; printf 'prior bytes\n' > "$ev/sentinel"
    printf '%s\n' "$base/container" > "$case_dir/declarations"
    ln -s "$case_dir/declarations" "$case_dir/data/task-x1/evidence.list"
    printf 'See %s/container/empty\n' "$base" > "$case_dir/data/task-x1/report.md"
    cat > "$case_dir/fakebin/sort" <<SH
#!/usr/bin/env bash
"$real_sort" "\$@" || exit \$?
case "\${!#}" in
  *'.evidence.new.'*/MANIFEST.sha256.links)
    stage=\${!#}; stage=\${stage%/*}
    mv -- "\$stage/$label/container" "$case_dir/moved-content" || exit 1
    ln -s "$case_dir/moved-content" "\$stage/$label/container" || exit 1
    : > "$case_dir/fault-seen" ;;
esac
SH
    chmod +x "$case_dir/fakebin/sort"
    for flag in '' --force; do
      rm -rf "$case_dir/moved-content"
      rm -f "$case_dir/fault-seen"
      rc=0
      run_teardown "$case_dir" ${flag:+"$flag"} > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
      [ "$rc" -ne 0 ] || fail 'a staged ancestor link covered source content'
      assert_present "$case_dir/fault-seen" 'staging ancestor replacement was not reached'
      assert_grep "references $base/container/empty, which cleanup would destroy" "$case_dir/stderr" 'ancestor link must not prove coverage'
      [ -d "$base/container/empty" ] && [ ! -L "$base/container" ] || fail 'staging fault changed source content'
      [ "$(cat "$ev/sentinel")" = 'prior bytes' ] || fail 'staging fault replaced prior snapshot'
      assert_present "$case_dir/state/task-x1.meta" 'staging fault removed metadata'
    done
  done
  pass 'verified staging cannot prove coverage by following an ancestor link'
}

test_missing_prior_sources_do_not_mask_later_preserved_content() {
  local case_dir root_name flag base label ev hash rc
  for root_name in copy tmp; do
    for flag in '' --force; do
      case_dir=$(make_case "evidence-missing-prior-parent-$root_name-${flag:-normal}")
      ignore_workspace "$case_dir"
      write_meta "$case_dir" no-mistakes ship
      printf 'tasktmp=%s/tasktmp\n' "$case_dir" >> "$case_dir/state/task-x1.meta"
      land_shippable_commit "$case_dir"
      if [ "$root_name" = copy ]; then base="$case_dir/wt/workspace"; label=copy/workspace; else base="$case_dir/tasktmp"; label=tmp; fi
      mkdir -p "$base"
      ev="$case_dir/data/task-x1/evidence"
      mkdir -p "$ev/$label/gone"
      printf 'prior bytes\n' > "$ev/$label/gone/proof"
      hash=$({ sha256sum "$ev/$label/gone/proof" 2>/dev/null || shasum -a 256 "$ev/$label/gone/proof"; } | awk '{print $1}')
      printf '%s  %s/gone/proof\n' "$hash" "$label" > "$ev/MANIFEST.sha256"
      printf 'live bytes\n' > "$base/live"
      printf '%s\n' "$base/gone/proof" "$base/live" > "$case_dir/data/task-x1/evidence.list"
      printf 'See %s/live\n' "$base" > "$case_dir/data/task-x1/report.md"
      rc=0
      run_teardown "$case_dir" ${flag:+"$flag"} > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
      expect_code 0 "$rc" "verified missing prior source must not block live coverage: $(cat "$case_dir/stderr")"
      [ "$(cat "$ev/$label/gone/proof")" = 'prior bytes' ] || fail 'missing source lost its prior bytes'
      [ "$(cat "$ev/$label/live")" = 'live bytes' ] || fail 'live declaration lost its bytes'
      evidence_manifest_verifies "$ev" || fail 'combined prior/live snapshot does not verify'
      assert_absent "$case_dir/state/task-x1.meta" 'verified prior/live control left metadata'
    done
  done
  pass 'a missing carried source with an absent parent cannot prevent later declarations from proving live coverage'
}

test_evidence_prior_manifest_file_types_are_respected() {
  local case_dir variant ev hash rc flag
  # shellcheck source=bin/fm-timeout-lib.sh disable=SC1091
  . "$ROOT/bin/fm-timeout-lib.sh"
  for variant in missing-regular optional-fifo; do
    case_dir=$(make_case "evidence-prior-manifest-$variant")
    ignore_workspace "$case_dir"
    write_meta "$case_dir" no-mistakes ship
    land_shippable_commit "$case_dir"
    ev="$case_dir/data/task-x1/evidence"
    mkdir -p "$ev/copy/workspace"
    printf 'workspace/proof\n' > "$case_dir/data/task-x1/evidence.list"
    if [ "$variant" = missing-regular ]; then
      ln -s absent "$ev/copy/workspace/proof"
      hash=$(readlink "$ev/copy/workspace/proof" | { sha256sum 2>/dev/null || shasum -a 256; } | awk '{print $1}')
      printf '%s  copy/workspace/proof\n' "$hash" > "$ev/MANIFEST.sha256.links"
      for flag in '' --force; do
        rc=0
        run_teardown "$case_dir" ${flag:+"$flag"} > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
        [ "$rc" -ne 0 ] || fail 'a missing mandatory regular manifest was accepted'
        assert_grep 'no verified earlier copy' "$case_dir/stderr" 'missing mandatory manifest must refuse'
        [ -L "$ev/copy/workspace/proof" ] || fail 'missing-manifest refusal removed prior link'
        assert_present "$case_dir/state/task-x1.meta" 'missing-manifest refusal removed metadata'
      done
    else
      printf 'prior bytes\n' > "$ev/copy/workspace/proof"
      hash=$({ sha256sum "$ev/copy/workspace/proof" 2>/dev/null || shasum -a 256 "$ev/copy/workspace/proof"; } | awk '{print $1}')
      printf '%s  copy/workspace/proof\n' "$hash" > "$ev/MANIFEST.sha256"
      mkfifo "$ev/MANIFEST.sha256.links"
      rc=0
      # shellcheck disable=SC2016 # Positional parameters belong to the child bash.
      fm_run_timed 30 bash -c '. "$1"; fm_task_evidence_preserve task-x1 "$2" "$3" 1 ""' \
        _ "$ROOT/bin/fm-task-evidence-lib.sh" "$case_dir/data" "$case_dir/wt" \
        > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
      expect_code 0 "$rc" 'an optional nonregular manifest must not be opened or block preservation'
      [ "$(cat "$ev/copy/workspace/proof")" = 'prior bytes' ] || fail 'optional-manifest control lost verified prior bytes'
      evidence_manifest_verifies "$ev" || fail 'optional-manifest control installed unverified bytes'
    fi
  done
  pass 'the regular manifest is mandatory, and an optional nonregular manifest is never read'
}

test_dangling_links_do_not_resolve_an_empty_target_as_a_disposable_root() {
  local case_dir rc ev
  case_dir=$(make_case evidence-dangling-root-alias)
  mkdir -p "$case_dir/wt/workspace" "$case_dir/data/task-x1"
  # This alias is only an input to the nondestructive public preservation API.
  # No teardown metadata or declaration ever asks to copy/remove this root.
  ln -s / "$case_dir/filesystem-root"
  ln -s absent "$case_dir/wt/workspace/link"
  printf 'workspace/link\n' > "$case_dir/data/task-x1/evidence.list"
  rc=0
  bash -c '. "$1"; fm_task_evidence_preserve task-x1 "$2" "$3" 1 "$4"' \
    _ "$ROOT/bin/fm-task-evidence-lib.sh" "$case_dir/data" "$case_dir/wt" "$case_dir/filesystem-root" \
    > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 0 "$rc" "a dangling link has no resolved target to classify: $(cat "$case_dir/stderr")"
  ev="$case_dir/data/task-x1/evidence"
  [ -L "$ev/copy/workspace/link" ] && [ "$(readlink "$ev/copy/workspace/link")" = absent ] || fail 'dangling link text was lost'
  evidence_manifest_verifies "$ev" || fail 'dangling root-alias snapshot does not verify'
  pass 'a dangling link never treats an empty resolver result as the filesystem-root object'
}

test_own_task_temp_folder_is_removed_and_nothing_else() {
  local case_dir rc id own
  case_dir=$(make_case evidence-own-tmp)
  id="task-ev$$-$RANDOM"
  own="/tmp/fm-$id"
  [ ! -e "$own" ] || fail "evidence-own-tmp: fixture temp folder $own already exists"
  land_shippable_commit "$case_dir"
  mkdir -p "$own/gotmp" "$case_dir/other-tmp"
  fm_write_meta "$case_dir/state/$id.meta" \
    "window=firstmate:fm-$id" "endpoint_task_id=$id" "worktree=$case_dir/wt" \
    "project=$case_dir/project" "kind=ship" "mode=no-mistakes" \
    "spawn_gen=teardown-test-$id" "tasktmp=$own"
  rc=0
  FM_TEARDOWN_GUARD_DONE=1 FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$case_dir/state" FM_DATA_OVERRIDE="$case_dir/data" \
    FM_CONFIG_OVERRIDE="$case_dir/config" PATH="$case_dir/fakebin:$PATH" \
    "$TEARDOWN" "$id" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  if [ -e "$own" ]; then rm -rf "$own"; fail "evidence-own-tmp: the task's own temp folder survived cleanup (rc=$rc): $(cat "$case_dir/stderr")"; fi
  expect_code 0 "$rc" "evidence-own-tmp: teardown should succeed: $(cat "$case_dir/stderr")"

  case_dir=$(make_case evidence-foreign-tmp)
  write_meta "$case_dir" no-mistakes ship
  printf '%s\n' "tasktmp=$case_dir/other-tmp" >> "$case_dir/state/task-x1.meta"
  mkdir -p "$case_dir/other-tmp"
  land_shippable_commit "$case_dir"
  rc=0
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 0 "$rc" "evidence-foreign-tmp: teardown should succeed: $(cat "$case_dir/stderr")"
  assert_present "$case_dir/other-tmp" "evidence-foreign-tmp: cleanup removed a recorded temp folder that is not the task's own"
  assert_grep "not its own /tmp/fm-task-x1 folder" "$case_dir/stderr" \
    "evidence-foreign-tmp: cleanup did not name the temp folder it left in place"
  pass "cleanup removes the task's own /tmp/fm-<id> folder and leaves any other recorded temp path in place"
}

test_symlinked_own_task_temp_folder_is_left_in_place() {
  local case_dir id own rc
  case_dir=$(make_case evidence-linked-tmp)
  id="task-ev-link$$-$RANDOM"
  own="/tmp/fm-$id"
  [ ! -e "$own" ] && [ ! -L "$own" ] || fail "fixture temp path $own already exists"
  land_shippable_commit "$case_dir"
  mkdir -p "$case_dir/foreign-tmp"
  printf 'keep\n' > "$case_dir/foreign-tmp/sentinel"
  ln -s "$case_dir/foreign-tmp" "$own"
  fm_write_meta "$case_dir/state/$id.meta" \
    "window=firstmate:fm-$id" "endpoint_task_id=$id" "worktree=$case_dir/wt" \
    "project=$case_dir/project" "kind=ship" "mode=no-mistakes" \
    "spawn_gen=teardown-test-$id" "tasktmp=$own"
  rc=0
  FM_TEARDOWN_GUARD_DONE=1 FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$case_dir/state" FM_DATA_OVERRIDE="$case_dir/data" \
    FM_CONFIG_OVERRIDE="$case_dir/config" PATH="$case_dir/fakebin:$PATH" \
    "$TEARDOWN" "$id" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  if [ ! -L "$own" ]; then fail "cleanup removed the symlinked task temp path"; fi
  rm -- "$own"
  expect_code 0 "$rc" "symlinked task temp path should be left in place: $(cat "$case_dir/stderr")"
  [ "$(cat "$case_dir/foreign-tmp/sentinel")" = keep ] || fail "cleanup changed the symlink target"
  assert_grep "left in place" "$case_dir/stderr" "cleanup should warn about the symlinked temp path"
  pass "cleanup never removes a symlinked own task temp folder or its target"
}

test_overlapping_evidence_declarations_refuse() {
  local case_dir rc entries
  case_dir=$(make_case evidence-overlap)
  ignore_workspace "$case_dir"
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  mkdir -p "$case_dir/wt/workspace" "$case_dir/data/task-x1"
  printf 'kept\n' > "$case_dir/wt/workspace/review.txt"
  for entries in $'workspace/review.txt\nworkspace/review.txt' \
    $'workspace\nworkspace/review.txt' $'workspace/review.txt\nworkspace'; do
    printf '%s\n' "$entries" > "$case_dir/data/task-x1/evidence.list"
    rc=0
    run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
    [ "$rc" -ne 0 ] || fail "cleanup accepted overlapping evidence declarations"
    assert_grep "overlaps another entry" "$case_dir/stderr" "refusal should name the overlap"
    assert_present "$case_dir/state/task-x1.meta" "overlap refusal removed task record"
    assert_present "$case_dir/wt/workspace/review.txt" "overlap refusal touched evidence"
    assert_absent "$case_dir/data/task-x1/evidence" "overlap refusal installed a partial snapshot"
  done
  pass "cleanup refuses duplicate and nested evidence declarations in either order"
}

test_failed_final_staged_verification_refuses_without_replacing_prior_evidence() {
  local case_dir rc real_shasum ev
  case_dir=$(make_case evidence-final-verify)
  ignore_workspace "$case_dir"
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  ev="$case_dir/data/task-x1/evidence"
  mkdir -p "$case_dir/wt/workspace" "$ev"
  printf 'new evidence\n' > "$case_dir/wt/workspace/review.txt"
  printf 'prior snapshot\n' > "$ev/sentinel"
  printf '%s\n' workspace/review.txt > "$case_dir/data/task-x1/evidence.list"
  real_shasum=$(command -v shasum) || fail "shasum needed for final-verification fixture"
  # The first staging hash agrees with the source; a second staging hash
  # disagrees to exercise the final verification independently of copy-out.
  cat > "$case_dir/fakebin/shasum" <<SH
#!/usr/bin/env bash
case "\$3" in
  *'.evidence.new.'*)
    if [ -e "$case_dir/staging-hashed" ]; then
      printf '%064d  %s\\n' 0 "\$3"
      exit 0
    fi
    : > "$case_dir/staging-hashed"
    ;;
esac
exec "$real_shasum" "\$@"
SH
  chmod +x "$case_dir/fakebin/shasum"
  rc=0
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  [ "$rc" -ne 0 ] || fail "cleanup accepted a staged snapshot whose final hash changed"
  assert_grep "staged evidence copy/workspace/review.txt for task-x1 failed verification" \
    "$case_dir/stderr" "refusal should identify final verification: $(cat "$case_dir/stderr")"
  [ "$(cat "$ev/sentinel")" = 'prior snapshot' ] || fail "verification failure replaced earlier evidence"
  assert_absent "$ev/copy/workspace/review.txt" "verification failure installed new evidence"
  assert_present "$case_dir/state/task-x1.meta" "verification failure removed task record"
  assert_present "$case_dir/wt/workspace/review.txt" "verification failure removed source"
  pass "failed final staged verification preserves the source and earlier evidence snapshot"
}

test_retried_cleanup_keeps_a_verified_earlier_evidence_copy() {
  local case_dir rc ev hash
  case_dir=$(make_case evidence-carry)
  ignore_workspace "$case_dir"
  write_meta "$case_dir" no-mistakes ship
  land_shippable_commit "$case_dir"
  ev="$case_dir/data/task-x1/evidence"
  mkdir -p "$ev/copy/workspace"
  printf 'kept\n' > "$ev/copy/workspace/gone.txt"
  hash=$(cd "$ev" && { sha256sum copy/workspace/gone.txt 2>/dev/null || shasum -a 256 copy/workspace/gone.txt; } | awk '{print $1}')
  printf '%s  copy/workspace/gone.txt\n' "$hash" > "$ev/MANIFEST.sha256"
  printf '%s\n' workspace/gone.txt > "$case_dir/data/task-x1/evidence.list"

  printf 'tampered\n' > "$ev/copy/workspace/gone.txt"
  rc=0
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  [ "$rc" -ne 0 ] || fail "evidence-carry: teardown accepted an earlier copy that no longer verifies"
  assert_grep "no verified earlier copy" "$case_dir/stderr" \
    "evidence-carry: refusal did not explain the unverifiable earlier copy: $(cat "$case_dir/stderr")"

  printf 'kept\n' > "$ev/copy/workspace/gone.txt"
  rc=0
  run_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 0 "$rc" "evidence-carry: teardown should keep the verified earlier copy: $(cat "$case_dir/stderr")"
  [ "$(cat "$ev/copy/workspace/gone.txt")" = kept ] || fail "evidence-carry: the earlier copy was not kept"
  evidence_manifest_verifies "$ev" || fail "evidence-carry: the kept copy's manifest does not verify"
  pass "a retried cleanup whose declared source is already gone keeps the earlier copy only while it still verifies"
}

test_teardown_retires_park_without_relocking_meta() {
  local case_dir mode sid rc head release_name
  # Both real paths execute while teardown holds the task's meta lock. Bound
  # the command so accidentally calling park cancel cannot hang the CI lane.
  # shellcheck source=bin/fm-timeout-lib.sh disable=SC1091
  . "$ROOT/bin/fm-timeout-lib.sh"
  for mode in ordinary queue; do
    case_dir=$(make_case "park-retirement-$mode")
    release_name=
    write_meta "$case_dir" local-only ship
    printf 'manual\n' > "$case_dir/config/backlog-backend"
    printf 'park_state=parked\n' >> "$case_dir/state/task-x1.meta"
    head=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
    if [ "$mode" = queue ]; then
      sid=merge-queue-task-x1-aaaaaaaa
      printf 'park_source=%s\n' "$sid" >> "$case_dir/state/task-x1.meta"
      FM_HOME="$case_dir" FM_PROCEVENT_CLAIM_ROOT="$case_dir/claims" \
        "$ROOT/bin/fm-procevent.sh" register merge-queue "$sid" -- \
        "$ROOT/bin/fm-procevent-merge-queue.sh" watch task-x1 "$head" >/dev/null \
        || fail "could not seed adopted queue source"
    else
      sid=when-park-task-x1
      FM_HOME="$case_dir" FM_PROCEVENT_CLAIM_ROOT="$case_dir/claims" \
        "$ROOT/bin/fm-procevent.sh" register when "$sid" -- /usr/bin/true >/dev/null \
        || fail "could not seed ordinary park source"
      release_name=$(bash -c '. "$1/bin/fm-pr-lib.sh"; . "$1/bin/fm-suspend-lib.sh"; fm_suspend_release_source_name "$2" task-x1 p1' _ "$ROOT" "$case_dir") || fail 'release source name failed'
      printf 'park_token=p1\npark_release_source=when-%s\n' "$release_name" >> "$case_dir/state/task-x1.meta"
      FM_HOME="$case_dir" FM_PROCEVENT_CLAIM_ROOT="$case_dir/claims" \
        "$ROOT/bin/fm-procevent-when.sh" arm "$release_name" --condition /usr/bin/false --action /usr/bin/true >/dev/null || fail 'release source registration failed'
    fi
    rc=0
    fm_run_timed 30 env FM_HOME="$case_dir" FM_ROOT_OVERRIDE="$ROOT" \
      FM_STATE_OVERRIDE="$case_dir/state" FM_DATA_OVERRIDE="$case_dir/data" \
      FM_CONFIG_OVERRIDE="$case_dir/config" FM_TEARDOWN_GUARD_DONE=1 \
      FM_PROCEVENT_CLAIM_ROOT="$case_dir/claims" PATH="$case_dir/fakebin:$PATH" \
      "$TEARDOWN" task-x1 > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
    expect_code 0 "$rc" "park-$mode: real teardown must complete without a recursive meta lock"
    assert_absent "$case_dir/state/task-x1.meta" "park-$mode: task record cleaned up"
    assert_absent "$case_dir/state/procevent/$sid.source" "park-$mode: registered park source retired"
    [ -z "$release_name" ] || assert_absent "$case_dir/state/procevent/when-$release_name.source" 'terminal cleanup orphaned its registered release action'
  done
  pass "real cleanup retires ordinary and adopted park watches without re-locking its task record"
}

test_queue_settlement_real_cleanup_leaves_no_orphan_status() {
  local case_dir head rc queue adapter
  case_dir=$(make_case queue-real-settlement)
  write_meta "$case_dir" direct-push ship
  seed_backlog_in_flight "$case_dir"
  head=$(git -C "$case_dir/wt" rev-parse HEAD)
  queue="$case_dir/queue"
  adapter="$ROOT/bin/fm-procevent-merge-queue.sh"
  mkdir -p "$queue"
  printf 'dir=%s\n' "$queue" > "$case_dir/config/merge-queue"
  printf 'RESULT t head=%s outcome=landed main=%s files=1 identical=1 differ=- dropped=- evidence=/evidence/real-cleanup\n' \
    "$head" "$head" > "$queue/queue.log"
  FM_HOME="$case_dir" "$adapter" watch task-x1 "$head" > "$case_dir/result" \
    || fail "could not capture the fake queue result through the public watch"
  # shellcheck source=bin/fm-timeout-lib.sh disable=SC1091
  . "$ROOT/bin/fm-timeout-lib.sh"
  rc=0
  fm_run_timed 30 env FM_HOME="$case_dir" FM_ROOT_OVERRIDE="$ROOT" \
    FM_STATE_OVERRIDE="$case_dir/state" FM_DATA_OVERRIDE="$case_dir/data" \
    FM_CONFIG_OVERRIDE="$case_dir/config" FM_TEARDOWN_GUARD_DONE=1 \
    FM_MERGE_QUEUE_TEARDOWN_BIN="$TEARDOWN" PATH="$case_dir/fakebin:$PATH" \
    "$adapter" settle "$case_dir/result" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  expect_code 0 "$rc" "queue-real-settlement: real guarded cleanup succeeds"
  assert_absent "$case_dir/state/task-x1.meta" "queue-real-settlement: task record cleaned up"
  assert_absent "$case_dir/state/task-x1.status" "queue-real-settlement: no post-cleanup orphan status log"
  assert_equals "done" "$(backlog_row_state "$case_dir")" "queue-real-settlement: cleanup closes the backlog itself"
  FM_HOME="$case_dir" "$ROOT/bin/fm-tasks-axi.sh" show task-x1 --full > "$case_dir/task-note"
  assert_grep 'files=1 identical=1, evidence /evidence/real-cleanup' "$case_dir/task-note" \
    "queue-real-settlement: per-file proof remains in the completed task note"
  pass "real queue settlement leaves its proof in the task note but never recreates a cleaned-up status log"
}

test_cleanup_without_release_record_needs_no_release_owner() {
  local case_dir phase setting rc combination
  for combination in absent-off retained-off absent-on retained-on; do
    phase=${combination%-*}; setting=${combination##*-}
    case_dir=$(make_case "no-release-$combination")
    write_meta "$case_dir" local-only ship
    prepare_teardown_source_copy "$case_dir"
    rm -f "$case_dir/test-root/bin/fm-park.sh"
    [ "$phase" != retained ] || printf 'copy_state=retained\n' >> "$case_dir/state/task-x1.meta"
    printf '%s\n' "$setting" > "$case_dir/config/park-release"
    rc=0
    run_copied_teardown "$case_dir" > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
    expect_code 0 "$rc" 'ordinary cleanup depended on the absent release owner'
    assert_absent "$case_dir/state/task-x1.meta" 'ordinary cleanup did not retire its task'
    assert_grep 'teardown task-x1 complete' "$case_dir/stdout" 'ordinary cleanup did not complete'
  done
  pass 'cleanup without release custody or a release source needs no release owner'
}

test_cleanup_release_record_still_requires_owner_when_disabled() {
  local case_dir rc
  case_dir=$(make_case release-owner-required)
  write_meta "$case_dir" local-only ship
  prepare_teardown_source_copy "$case_dir"
  rm -f "$case_dir/test-root/bin/fm-park.sh"
  printf 'copy_state=retained\npark_release_source=when-pending-release\n' >> "$case_dir/state/task-x1.meta"
  printf 'off\n' > "$case_dir/config/park-release"
  rc=0
  run_copied_teardown "$case_dir" --force > "$case_dir/stdout" 2> "$case_dir/stderr" || rc=$?
  assert_source_refusal_preserved_state "$case_dir" 'release-owner-required' 'fm-park.sh'
  pass 'disabling release never bypasses cleanup of an existing release source'
}

test_saved_copy_custody_never_runs_terminal_cleanup() {
  local case_dir phase rc before
  for phase in released release-prepared restore-prepared; do
    case_dir=$(make_case "saved-$phase")
    write_meta "$case_dir" direct-push ship
    printf 'copy_state=%s\n' "$phase" >> "$case_dir/state/task-x1.meta"
    printf 'other task work\n' > "$case_dir/wt/other-work"
    mkdir -p "$case_dir/state/task-x1.inbox"
    printf 'pending answer\n' > "$case_dir/state/task-x1.inbox/001.msg"
    before=$(git -C "$case_dir/wt" rev-parse HEAD)
    rc=0; run_teardown "$case_dir" --force > "$case_dir/out" 2>&1 || rc=$?
    expect_code 1 "$rc" 'saved/interrupted custody was treated as discard/terminal authority'
    assert_grep 'restore/reconcile it before terminal cleanup' "$case_dir/out" 'cleanup lost its concrete saved-custody refusal'
    assert_present "$case_dir/state/task-x1.meta" 'cleanup erased saved task identity'
    assert_present "$case_dir/state/task-x1.inbox/001.msg" 'cleanup erased pending instructions'
    assert_equals 'other task work' "$(cat "$case_dir/wt/other-work")" 'cleanup touched a historical returned slot'
    assert_equals "$before" "$(git -C "$case_dir/wt" rev-parse HEAD)" 'cleanup changed the historical head'
    [ ! -s "$case_dir/treehouse.log" ] || fail 'saved-custody cleanup called native return'
  done
  pass 'terminal cleanup never treats saved custody as landing/discard authority or touches historical slots'
}

# Every case builds its own sandbox under a name of its own from the shared
# read-only git world template, and reaps or signals only processes rooted in
# its own worktree or started by itself, so no case depends on another or on
# their order; they run through fm_run_case_pool (tests/lib.sh), longest first.
# FM_TEARDOWN_CASE_JOBS overrides the concurrency, which defaults to the host's
# processor count capped at four; 1 runs the cases serially.
case_jobs=$(fm_case_pool_jobs "${FM_TEARDOWN_CASE_JOBS:-}")
fm_run_case_pool "$case_jobs" "$TMP_ROOT/.case-logs" \
  test_cleanup_without_release_record_needs_no_release_owner \
  test_cleanup_release_record_still_requires_owner_when_disabled \
  test_saved_copy_custody_never_runs_terminal_cleanup \
  test_herdr_flat_teardown_refuses_orphaning_records_then_retry_completes \
  test_windowless_record_outside_the_leftover_class_still_refuses \
  test_process_spawned_during_grace_is_reaped_on_later_pass \
  test_missing_startup_source_refuses_before_cleanup \
  test_unreadable_startup_source_refuses_before_cleanup \
  test_missing_adapter_sibling_refuses_before_cleanup \
  test_forced_child_missing_adapter_sibling_refuses_before_cleanup \
  test_forced_secondmate_own_missing_adapter_sibling_refuses_before_child_cleanup \
  test_retained_sources_still_reach_the_ordinary_refusal \
  test_local_only_fork_remote_allows \
  test_teardown_closes_the_backlog_item_itself \
  test_teardown_manual_backend_leaves_the_backlog_to_the_operator \
  test_teardown_retires_park_without_relocking_meta \
  test_queue_settlement_real_cleanup_leaves_no_orphan_status \
  test_local_only_truly_unpushed_refuses \
  test_local_only_merged_to_local_main_allows \
  test_no_mistakes_origin_remote_allows \
  test_no_mistakes_truly_unpushed_refuses \
  test_direct_push_landed_on_origin_main_allows \
  test_direct_push_unlanded_refuses \
  test_direct_push_with_open_pr_refuses \
  test_pr_mode_fork_branch_with_open_pr_allows \
  test_local_only_force_overrides_unpushed \
  test_secondmate_pr_registration_publishes_ready_line \
  test_secondmate_home_teardown_delivers_final_line_or_refuses \
  test_teardown_missing_busy_sidecar_completes \
  test_herdr_teardown_clears_escalation_marker \
  test_herdr_close_precedes_reap_and_return \
  test_herdr_flat_teardown_refuses_records_on_unparseable_presence \
  test_herdr_flat_teardown_preflight_refuses_before_changes \
  test_forced_secondmate_herdr_child_preflight_refuses_before_changes \
  test_forced_secondmate_teardown_holds_descendant_lifecycle_locks \
  test_forced_secondmate_herdr_child_retains_records_when_close_unconfirmed \
  test_forced_teardown_retains_nested_secondmate_home_when_grandchild_close_unconfirmed \
  test_herdr_projection_teardown_retires_journal_only_after_confirmed_close \
  test_herdr_projection_teardown_retains_journal_when_close_unconfirmed \
  test_herdr_projection_teardown_surfaces_restore_failure_without_blocking_cleanup \
  test_squash_merged_branch_deleted_allows \
  test_squash_merged_pr_allows_when_head_ancestor_of_pr_head \
  test_no_pr_recorded_discovers_merged_pr_by_branch_allows \
  test_squash_merged_pr_allows_replayed_unpushed_patch \
  test_merged_pr_with_later_local_commit_refuses \
  test_squash_merged_rebased_branch_allows \
  test_squash_merged_same_file_different_content_refuses \
  test_train_replayed_branch_deleted_allows \
  test_train_replayed_plus_extra_local_commit_refuses \
  test_train_same_file_different_patch_refuses \
  test_train_replayed_with_claude_scratch_allows \
  test_train_replayed_dirty_worktree_refuses \
  test_squash_merged_rebased_local_with_unlanded_commit_refuses \
  test_squash_merged_stale_local_refuses_when_forge_unreachable \
  test_pr_check_does_not_refresh_stale_pr_head \
  test_pr_check_records_remote_head_when_local_lags \
  test_content_in_default_fallback_allows \
  test_content_fallback_refreshes_stale_origin_ref \
  test_dirty_worktree_refuses \
  test_gh_error_and_content_absent_refuses \
  test_legacy_record_without_the_flag_refuses \
  test_windowless_legacy_record_with_gone_worktree_tears_down \
  test_windowless_legacy_record_tears_down_with_the_legacy_flag \
  test_windowless_legacy_record_still_refuses_unlanded_work \
  test_windowless_leftover_retries_its_retained_legacy_stamp_without_the_flag \
  test_legacy_record_teardown_completes_when_landed_and_endpoint_dead \
  test_legacy_record_teardown_refuses_unlanded_work \
  test_legacy_record_teardown_refuses_an_ambiguous_endpoint \
  test_legacy_record_rolls_the_stamp_back_when_the_marker_write_fails \
  test_retained_legacy_stamp_still_faces_the_endpoint_gate \
  test_legacy_record_never_accepts_a_corrupt_spawn_gen \
  test_stale_index_lock_cleared_and_teardown_succeeds \
  test_live_index_lock_is_never_removed_and_teardown_refuses \
  test_lsof_error_never_clears_index_lock \
  test_stale_index_lock_cleanup_rechecks_dirty_worktree \
  test_non_linked_index_lock_path_is_checked_from_worktree \
  test_index_lock_mtime_read_failure_refuses \
  test_transient_index_lock_clears_after_first_attempt_and_retry_succeeds \
  test_persistent_index_lock_exhausts_retries_and_refuses_loudly \
  test_empty_retry_wait_uses_default_without_aborting \
  test_fractional_legacy_retry_wait_refuses_without_arithmetic_error \
  test_parked_own_run_is_aborted_before_teardown \
  test_parked_own_run_concludes_on_passed_with_override_after_abort \
  test_parked_own_run_concludes_on_passed_with_skips_after_abort \
  test_parked_run_advanced_past_unfetched_head_is_still_aborted \
  test_parked_run_with_mismatched_ledger_head_is_never_aborted \
  test_parked_run_with_malformed_ledger_row_is_never_aborted \
  test_parked_run_with_impossible_ledger_date_is_never_aborted \
  test_terminal_status_with_gate_never_queries_or_aborts_ledger_fallback \
  test_parked_run_advanced_head_locally_fetched_is_still_aborted \
  test_parked_advanced_run_without_anchor_is_never_aborted \
  test_parked_advanced_run_ancestor_anchor_is_never_aborted \
  test_parked_terminal_unfetched_row_is_never_aborted \
  test_parked_run_terminal_newest_row_at_own_head_is_never_aborted \
  test_parked_run_behind_diverged_newer_row_is_never_aborted \
  test_parked_advanced_run_ambiguous_rows_are_never_aborted \
  test_ledger_proven_continuation_never_aborts_active_run \
  test_parked_own_run_refuses_when_abort_is_unconfirmed \
  test_mismatched_run_after_abort_refuses_unconfirmed \
  test_empty_status_after_abort_refuses_unconfirmed \
  test_not_found_status_after_abort_confirms_completion \
  test_another_branchs_parked_run_is_never_touched \
  test_own_autonomous_run_is_left_alone \
  test_leaked_worktree_process_is_reaped \
  test_leaked_tasktmp_process_is_reaped \
  test_lsof_absent_reaps_tmux_process_group \
  test_lsof_error_refuses_before_removal \
  test_reused_pid_identity_is_not_force_killed \
  test_exec_changed_process_is_still_reaped \
  test_persistent_scan_refuses_after_bounded_retries \
  test_process_exit_during_identity_lookup_does_not_refuse \
  test_run_abort_precedes_process_reap_precedes_worktree_removal \
  test_unreadable_evidence_records_skip_with_one_warning \
  test_evidence_bulk_scan_reads_each_record_once \
  test_evidence_text_scan_is_outside_project_lock_and_changes_refuse \
  test_evidence_citation_scan_completes_for_a_plain_missing_path \
  test_evidence_physical_root_aliases_do_not_hide_existing_citations \
  test_evidence_link_physical_failures_and_dangling_newlines_refuse \
  test_evidence_copy_errors_cannot_replace_an_earlier_snapshot \
  test_evidence_link_manifest_append_errors_refuse_without_discarding \
  test_regular_manifest_append_errors_refuse_without_discarding \
  test_manifest_sort_errors_refuse_without_discarding \
  test_reassigned_evidence_staging_errors_preserve_prior_snapshot \
  test_evidence_staging_ancestor_links_cannot_cover_source_content \
  test_missing_prior_sources_do_not_mask_later_preserved_content \
  test_evidence_prior_manifest_file_types_are_respected \
  test_dangling_links_do_not_resolve_an_empty_target_as_a_disposable_root \
  test_declared_evidence_is_copied_out_with_a_verified_manifest \
  test_prose_apostrophes_do_not_open_evidence_quotes \
  test_evidence_link_resolution_exhaustion_has_a_resolvable_control \
  test_completed_prose_quotes_allow_missing_and_declared_citations \
  test_missing_markup_short_interpretations_respect_quote_mode \
  test_final_directory_resolution_failure_has_a_success_control \
  test_missing_staged_directory_cannot_cover_existing_source \
  test_undeclared_reference_into_the_copy_refuses_then_declaring_it_proceeds \
  test_html_entities_delimit_declared_evidence_references \
  test_html_entities_do_not_hide_undeclared_evidence_references \
  test_clean_tracked_source_citations_need_no_evidence_declaration \
  test_unrecoverable_copy_citations_still_refuse_even_with_force \
  test_evidence_declaration_outside_the_task_roots_refuses \
  test_missing_evidence_citations_warn_and_allow_cleanup \
  test_declared_evidence_links_are_preserved_without_following \
  test_citation_and_link_target_coverage_requires_surviving_objects \
  test_empty_evidence_roots_do_not_claim_the_working_directory \
  test_unsafe_evidence_links_and_fifos_refuse_even_with_force \
  test_link_only_evidence_installs_a_snapshot \
  test_retried_cleanup_verifies_link_only_evidence \
  test_numeric_citation_suffixes_check_intermediate_entries \
  test_object_resolution_failures_preserve_source_and_prior_snapshot \
  test_existing_unusual_citations_never_become_missing \
  test_unquoted_spaced_citations_check_every_existing_interpretation \
  test_every_citation_boundary_checks_longer_existing_interpretations \
  test_genuinely_absent_markup_citations_warn_in_both_roots_and_force_modes \
  test_reassigned_evidence_citations_only_warn_without_interpreting \
  test_link_resolution_refuses_every_unpreserved_disposable_target \
  test_evidence_link_faults_preserve_source_and_prior_snapshot \
  test_own_task_temp_folder_is_removed_and_nothing_else \
  test_symlinked_own_task_temp_folder_is_left_in_place \
  test_overlapping_evidence_declarations_refuse \
  test_failed_final_staged_verification_refuses_without_replacing_prior_evidence \
  test_retried_cleanup_keeps_a_verified_earlier_evidence_copy \
  test_teardown_closes_a_gerrit_task_with_its_change_url_as_a_note \
  test_herdr_teardown_presentation_lock_namespace_is_per_account \
  test_teardown_retires_task_watcher_markers_but_quarantines_unmatched_journal \
  test_teardown_retains_journal_bound_to_another_pane \
  test_teardown_retires_v1_journal_when_projected_workspace_gone \
  test_teardown_retains_v1_journal_when_projected_workspace_present \
  test_teardown_retains_v1_journal_when_workspace_query_ambiguous \
  test_squash_merged_forgejo_pr_allows_when_main_moved_on \
  test_content_fallback_uses_recorded_base_branch \
  test_untracked_only_refusal_diagnostic \
  test_tracked_edit_refusal_diagnostic \
  test_mixed_refusal_diagnostic \
  test_scout_archived_decision_requires_recorded_answer \
  test_scout_nested_clone_returns_with_no_untracked_entries \
  test_ship_nested_clone_is_refused_and_bytes_stay \
  test_dirty_return_warns_which_slot_was_lost \
  test_dirty_return_warns_even_when_a_later_step_refuses \
  test_forced_secondmate_child_scout_nested_clone_returns_clean \
  test_forced_secondmate_dirty_child_return_warns_and_completes \
  test_return_that_removes_copy_warns_cannot_verify \
  test_scout_ignored_files_survive_scratch_clean \
  test_teardown_records_the_task_pipeline_spend \
  test_teardown_skips_pipeline_spend_when_disabled \
  test_teardown_records_unavailable_spend_for_a_gone_worktree
