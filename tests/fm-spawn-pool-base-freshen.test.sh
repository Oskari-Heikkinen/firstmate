#!/usr/bin/env bash
# Regression tests for fm-spawn's pooled-worktree base refresh.
#
# A treehouse pool can return a clean detached worktree whose origin/main was
# advanced after the worktree was allocated.
# These tests drive the real spawn path with a fake terminal, then prove it
# starts the worker from the fetched origin tip, launches a clean origin-less
# pool as-is, or stops when a configured origin is unusable.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
# shellcheck source=tests/suspend-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/suspend-helpers.sh"

TMP_ROOT=$(fm_test_tmproot fm-spawn-pool-base-freshen)

# The fake pane reports its path at once, so the worktree poll's one-second
# confirmation wait and the launch settle waits only add wall time here. Every
# case reads them at zero except test_stale_pool_base_refreshes_before_branching,
# which keeps fm-spawn's own real timers.
export FM_SPAWN_WORKTREE_POLL_SECS=0 FM_SPAWN_LAUNCH_SETTLE_SECS=0

make_case() {
  local name=$1 id=$2 default=${3:-main} case_dir home project origin pool publisher fakebin initial
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  project="$case_dir/project"
  origin="$case_dir/origin.git"
  pool="$case_dir/pool"
  publisher="$case_dir/publisher"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")

  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config"
  printf 'codex\n' > "$home/config/crew-harness"
  fm_test_spawn_brief "$home" "$id"
  touch "$home/state/.last-watcher-beat"

  git init --quiet -b "$default" "$project"
  printf 'base\n' > "$project/README.md"
  git -C "$project" add README.md
  git -C "$project" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm initial
  git clone --quiet --bare "$project" "$origin"
  git -C "$project" remote add origin "file://$origin"
  initial=$(git -C "$project" rev-parse HEAD)
  git -C "$project" worktree add --quiet --detach "$pool" "$initial"

  git clone --quiet "file://$origin" "$publisher"
  printf 'must survive a newly spawned branch\n' > "$publisher/advanced-main.txt"
  git -C "$publisher" add advanced-main.txt
  git -C "$publisher" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm advance-main
  git -C "$publisher" push --quiet origin "$default"

  printf '%s\n' "$case_dir|$home|$project|$pool|$fakebin|$initial|$default"
}

read_case_record() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJECT_DIR POOL_DIR FAKEBIN_DIR INITIAL_SHA DEFAULT_BRANCH <<EOF
$1
EOF
}

run_spawn() {
  local id=$1
  shift
  fm_test_run_spawn "$HOME_DIR" "$POOL_DIR" "$FAKEBIN_DIR" \
    "$id" "$PROJECT_DIR" "$@"
}

test_remote_seeded_home_spawns_from_treehouse_pool() {
  local rec id out status lock
  id='pool-remote-seeded-r13'
  rec=$(make_case remote-seeded "$id")
  read_case_record "$rec"
  cat > "$HOME_DIR/.fm-secondmate-parent" <<'REC'
schema=fm-secondmate-parent.v1
route=remote
parent_host=parent-machine
REC

  out=$(run_spawn "$id" --scout)
  status=$?
  expect_code 0 "$status" \
    "a remote-seeded secondmate home should allocate and launch from its Treehouse pool"$'\n'"$out"
  assert_contains "$out" "spawned $id" \
    "the remote-seeded spawn did not report success"
  assert_grep "worktree=$POOL_DIR" "$HOME_DIR/state/$id.meta" \
    "the remote-seeded spawn did not publish its allocated pool worktree"
  lock=$(FM_HOME="$HOME_DIR" bash -c '. "$1"; fm_treehouse_project_lock_path "$2"' _ \
    "$ROOT/bin/fm-wake-lib.sh" "$PROJECT_DIR") \
    || fail "the launched remote-seeded home could not resolve its Treehouse project lock"
  case "$lock" in
    "$HOME_DIR/state/"*) ;;
    *) fail "the remote-seeded spawn anchored its lock outside its local root: $lock" ;;
  esac
  if [ "${FM_TEST_EVIDENCE:-0}" = 1 ]; then
    printf '# remote-seeded Treehouse spawn command\n'
    printf '$ FM_HOME=%s bin/fm-spawn.sh %s %s --scout\n%s\nexit=%s\n' \
      "$HOME_DIR" "$id" "$PROJECT_DIR" "$out" "$status"
    printf 'published worktree=%s\nresolved project lock=%s\n' "$POOL_DIR" "$lock"
  fi
  pass "a remote-seeded secondmate home allocates and launches from its Treehouse pool"
}

# One case per returned path, so the three refusals that poll the whole
# worktree window run beside each other in the case pool.
linked_spawning_home_case() {  # <returned>
  local rec id out status returned=$1 primary spawning before_reflog
  id="pool-linked-${returned}-r12"
  rec=$(make_case "linked-$returned" "$id")
  read_case_record "$rec"
  primary=$PROJECT_DIR
  spawning="$CASE_DIR/secondmate"
  git -C "$primary" worktree add --quiet --detach "$spawning" HEAD
  PROJECT_DIR=$spawning
  case "$returned" in
    primary) POOL_DIR=$primary ;;
    primary-alias)
      ln -s "$primary" "$CASE_DIR/primary-alias"
      POOL_DIR="$CASE_DIR/primary-alias"
      ;;
    spawning) POOL_DIR=$spawning ;;
  esac
  before_reflog=$(git -C "$primary" reflog)
  # The assertion concerns identity, not how long an unchanged cwd is polled.
  fm_test_fake_sleep_noop "$FAKEBIN_DIR"

  out=$(run_spawn "$id" --scout)
  status=$?
  if [ "${FM_TEST_EVIDENCE:-0}" = 1 ]; then
    printf '# evidence begin: linked-home spawn, returned=%s\n' "$returned"
    printf '$ bin/fm-spawn.sh %s %s --scout\n%s\nexit=%s\n' "$id" "$PROJECT_DIR" "$out" "$status"
    printf 'primary HEAD before=%s after=%s\n' "$INITIAL_SHA" "$(git -C "$primary" rev-parse HEAD)"
    printf 'primary reflog before:\n%s\nprimary reflog after:\n%s\n' "$before_reflog" "$(git -C "$primary" reflog)"
    if [ -e "$primary/.git/FETCH_HEAD" ]; then
      printf 'FETCH_HEAD:\n'; cat "$primary/.git/FETCH_HEAD"
    else
      printf 'FETCH_HEAD absent\n'
    fi
    if [ -e "$HOME_DIR/state/$id.meta" ]; then
      printf 'saved task metadata:\n'; cat "$HOME_DIR/state/$id.meta"
      printf 'worker HEAD=%s origin/main=%s\n' "$(git -C "$POOL_DIR" rev-parse HEAD)" "$(git -C "$POOL_DIR" rev-parse origin/main)"
    else
      printf 'task metadata absent\n'
    fi
    printf '# evidence end\n'
  fi
  if [ "$returned" = scout ]; then
    expect_code 0 "$status" "a genuine scout copy from a linked home should launch"$'\n'"$out"
    assert_grep "worktree=$POOL_DIR" "$HOME_DIR/state/$id.meta" \
      "spawn did not record the genuine scout copy"
    [ "$(git -C "$POOL_DIR" rev-parse HEAD)" = "$(git -C "$POOL_DIR" rev-parse origin/main)" ] \
      || fail "spawn did not refresh the genuine scout copy"
  else
    [ "$status" -ne 0 ] || fail "linked spawning home accepted $returned as a disposable copy"
    # None of these is an isolated copy, so the worktree poll never adopts one
    # and the wait runs out instead: the spawning directory fails the poll's
    # own project comparison, and the repository primary (named directly or
    # through a symlink) fails the isolation screen the poll shares with the
    # guard. The refusal names the last path the pane reported.
    assert_contains "$out" "did not yield an isolated worktree" \
      "spawn did not explain its isolation refusal"
    assert_contains "$out" "resolved" "refusal did not name the acquired path"
    [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "refused spawn published task metadata"
    [ ! -e "$primary/.git/FETCH_HEAD" ] || fail "refused spawn fetched before proving isolation"
  fi
  [ "$(git -C "$primary" rev-parse HEAD)" = "$INITIAL_SHA" ] \
    || fail "spawn reset the repository primary from a linked home"
  [ "$(git -C "$primary" reflog)" = "$before_reflog" ] \
    || fail "spawn touched the primary reflog from a linked home"
  pass "linked spawning home: $returned preserves the primary before any refresh"
}

test_linked_spawning_home_returns_primary() { linked_spawning_home_case primary; }
test_linked_spawning_home_returns_primary_alias() { linked_spawning_home_case primary-alias; }
test_linked_spawning_home_returns_spawning() { linked_spawning_home_case spawning; }
test_linked_spawning_home_returns_scout() { linked_spawning_home_case scout; }

test_stale_pool_base_refreshes_before_branching() {
  local rec id out status current branch_head
  # The real-time case: both spawns run on fm-spawn's default poll and settle
  # waits. The pool runs each case in its own subshell, so this stays local.
  unset FM_SPAWN_WORKTREE_POLL_SECS FM_SPAWN_LAUNCH_SETTLE_SECS
  id='pool-current-base-r1'
  rec=$(make_case current-base "$id")
  read_case_record "$rec"

  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "spawn should refresh a stale pooled worktree"
  assert_contains "$out" "spawned $id" "spawn did not report success"
  current=$(git -C "$POOL_DIR" rev-parse origin/main)
  branch_head=$(git -C "$POOL_DIR" rev-parse HEAD)
  [ "$branch_head" = "$current" ] || fail "spawn left the pooled worktree on stale history"
  [ "$branch_head" != "$INITIAL_SHA" ] || fail "fixture did not prove origin/main advanced past the pool base"
  if [ "${FM_TEST_EVIDENCE:-0}" = 1 ]; then
    printf '# observed spawn: %s\n' "$(printf '%s\n' "$out" | tail -n 1)"
    printf '# observed base: HEAD=%s origin/main=%s advanced-main=%s\n' \
      "$branch_head" "$current" "$(cat "$POOL_DIR/advanced-main.txt")"
  fi

  id='pool-current-base-repeat-r1'
  fm_test_spawn_brief "$HOME_DIR" "$id"
  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "repeating the base refresh should be idempotent"
  [ "$(git -C "$POOL_DIR" rev-parse HEAD)" = "$current" ] \
    || fail "an idempotent repeat moved the pool away from current origin/main"

  git -C "$POOL_DIR" checkout --quiet -b "fm/$id"
  git -C "$POOL_DIR" diff --exit-code origin/main...HEAD >/dev/null \
    || fail "a branch created after spawn differs from current origin/main"
  assert_grep 'must survive a newly spawned branch' "$POOL_DIR/advanced-main.txt" \
    "the branch created after spawn omitted advanced-main content"
  pass "a stale pooled worktree refreshes to current origin/main before a crew branch is created"
}

test_non_main_default_branch_refreshes_before_branching() {
  local rec id out status current branch_head
  id='pool-current-trunk-r2'
  rec=$(make_case current-trunk "$id" trunk)
  read_case_record "$rec"

  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "spawn should refresh a stale pooled worktree on a non-main default branch"
  current=$(git -C "$POOL_DIR" rev-parse "origin/$DEFAULT_BRANCH")
  branch_head=$(git -C "$POOL_DIR" rev-parse HEAD)
  [ "$branch_head" = "$current" ] || fail "spawn did not refresh to current origin/$DEFAULT_BRANCH"
  [ "$branch_head" != "$INITIAL_SHA" ] || fail "fixture did not prove origin/$DEFAULT_BRANCH advanced past the pool base"
  pass "a stale pooled worktree resolves and refreshes a non-main default branch"
}

make_originless_case() {  # <name> <id>
  local name=$1 id=$2 case_dir home project pool fakebin initial
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  project="$case_dir/project"
  pool="$case_dir/pool"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")

  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config"
  printf 'codex\n' > "$home/config/crew-harness"
  fm_test_spawn_brief "$home" "$id"
  touch "$home/state/.last-watcher-beat"

  git init --quiet -b main "$project"
  printf 'base\n' > "$project/README.md"
  git -C "$project" add README.md
  git -C "$project" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm initial
  initial=$(git -C "$project" rev-parse HEAD)
  git -C "$project" worktree add --quiet --detach "$pool" "$initial"

  printf '%s\n' "$case_dir|$home|$project|$pool|$fakebin|$initial|main"
}

test_originless_pool_launches_without_a_freshness_fetch() {
  local rec id out status before
  id='pool-originless-r6'
  rec=$(make_originless_case originless "$id")
  read_case_record "$rec"
  ! git -C "$POOL_DIR" remote get-url origin >/dev/null 2>&1 \
    || fail "fixture unexpectedly configured an origin remote"
  before=$(git -C "$POOL_DIR" rev-parse HEAD)

  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "spawn should launch a local-only pooled worktree with no origin"$'\n'"$out"
  assert_contains "$out" "spawned $id" "spawn did not report success for the origin-less pool"
  assert_not_contains "$out" "could not fetch origin" \
    "spawn attempted a freshness fetch against a nonexistent origin"
  [ ! -e "$POOL_DIR/.git/FETCH_HEAD" ] || fail "spawn fetched against a pooled worktree with no origin"
  [ "$(git -C "$POOL_DIR" rev-parse HEAD)" = "$before" ] \
    || fail "spawn moved HEAD on an origin-less pooled worktree that had nothing to refresh against"
  if [ "${FM_TEST_EVIDENCE:-0}" = 1 ]; then
    printf '# observed origin-less launch: %s\n' "$(printf '%s\n' "$out" | tail -n 1)"
  fi
  pass "an origin-less pooled worktree launches as-is, skipping the freshness gate"
}

test_originless_dirty_pool_refuses_without_discarding_work() {
  local rec id out status before
  id='pool-originless-dirty-r1'
  rec=$(make_originless_case originless-dirty "$id")
  read_case_record "$rec"
  before=$(git -C "$POOL_DIR" rev-parse HEAD)
  printf 'keep this local work\n' > "$POOL_DIR/uncommitted.txt"

  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "spawn succeeded despite a dirty origin-less pooled worktree"
  assert_contains "$out" "is not clean" \
    "spawn did not clearly refuse a dirty origin-less pooled worktree"
  [ "$(git -C "$POOL_DIR" rev-parse HEAD)" = "$before" ] \
    || fail "spawn moved HEAD while refusing a dirty origin-less pooled worktree"
  assert_grep 'keep this local work' "$POOL_DIR/uncommitted.txt" \
    "spawn discarded local work from an origin-less pool"
  pass "a dirty origin-less pooled worktree is refused without discarding its local work"
}

test_origin_config_without_url_refuses_pool() {
  local rec id out status before
  id='pool-origin-without-url-r1'
  rec=$(make_originless_case origin-without-url "$id")
  read_case_record "$rec"
  git -C "$POOL_DIR" config remote.origin.fetch '+refs/heads/*:refs/remotes/origin/*'
  before=$(git -C "$POOL_DIR" rev-parse HEAD)

  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "spawn succeeded despite an origin configuration with no URL"
  assert_contains "$out" "could not fetch origin" \
    "spawn did not refuse an origin configuration with no URL as unusable"
  [ "$(git -C "$POOL_DIR" rev-parse HEAD)" = "$before" ] \
    || fail "spawn moved HEAD after finding an unusable origin configuration"
  [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "refused spawn published task metadata"
  pass "an origin configuration without a URL refuses the pooled worktree"
}

test_empty_origin_config_section_refuses_pool() {
  local rec id out status before config
  id='pool-empty-origin-section-r1'
  rec=$(make_originless_case empty-origin-section "$id")
  read_case_record "$rec"
  config=$(git -C "$POOL_DIR" rev-parse --path-format=absolute --git-path config)
  printf '\n[remote "origin"]\n' >> "$config"
  before=$(git -C "$POOL_DIR" rev-parse HEAD)

  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "spawn succeeded despite an empty origin configuration section"
  assert_contains "$out" "could not fetch origin" \
    "spawn did not refuse an empty origin configuration section as unusable"
  [ "$(git -C "$POOL_DIR" rev-parse HEAD)" = "$before" ] \
    || fail "spawn moved HEAD after finding an empty origin configuration section"
  [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "refused spawn published task metadata"
  pass "an empty origin configuration section refuses the pooled worktree"
}

test_empty_only_included_origin_config_section_launches_pool() {
  local rec id out status before config included
  id='pool-empty-only-included-origin-section-r1'
  rec=$(make_originless_case empty-only-included-origin-section "$id")
  read_case_record "$rec"
  config=$(git -C "$POOL_DIR" rev-parse --path-format=absolute --git-path config)
  included=$(dirname "$config")/empty-origin.inc
  printf '[remote "origin"]\n' > "$included"
  git -C "$POOL_DIR" config include.path "$(basename "$included")"
  before=$(git -C "$POOL_DIR" rev-parse HEAD)

  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "spawn should proceed when an included empty origin section is not enumerable"$'\n'"$out"
  assert_contains "$out" "spawned $id" "spawn did not report success for the undetectable included section"
  assert_not_contains "$out" "could not fetch origin" \
    "spawn treated an undetectable included empty section as a configured origin"
  [ "$(git -C "$POOL_DIR" rev-parse HEAD)" = "$before" ] \
    || fail "spawn moved HEAD despite treating the included empty section as origin-less"
  pass "an empty-only included origin section documents the accepted detection boundary"
}

test_inactive_conditional_origin_include_launches_pool() {
  local rec id out status before config included
  id='pool-inactive-origin-include-r1'
  rec=$(make_originless_case inactive-origin-include "$id")
  read_case_record "$rec"
  config=$(git -C "$POOL_DIR" rev-parse --path-format=absolute --git-path config)
  included=$(dirname "$config")/inactive-origin.inc
  printf '[fm-test]\n\tmarker = true\n[remote "origin"]\n' > "$included"
  git -C "$POOL_DIR" config 'includeIf.gitdir:/never/matches/this/worktree/.path' "$included"
  before=$(git -C "$POOL_DIR" rev-parse HEAD)

  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "spawn should ignore an inactive conditional origin include"$'\n'"$out"
  assert_contains "$out" "spawned $id" "spawn did not report success with an inactive origin include"
  [ "$(git -C "$POOL_DIR" rev-parse HEAD)" = "$before" ] \
    || fail "spawn moved HEAD despite having no effective origin"
  pass "an inactive conditional origin include leaves the pooled worktree origin-less"
}

test_unreachable_origin_refuses_stale_pool_base() {
  local rec id out status before after
  id='pool-unreachable-origin-r2'
  rec=$(make_case unreachable-origin "$id")
  read_case_record "$rec"
  git -C "$POOL_DIR" remote set-url origin "file://$CASE_DIR/missing-origin.git"
  before=$(git -C "$POOL_DIR" rev-parse HEAD)

  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "spawn succeeded despite an unreachable origin"
  assert_contains "$out" "could not fetch origin" \
    "spawn did not clearly refuse an unreachable origin"
  after=$(git -C "$POOL_DIR" rev-parse HEAD)
  [ "$after" = "$before" ] || fail "spawn changed the pooled worktree after origin became unreachable"
  if [ "${FM_TEST_EVIDENCE:-0}" = 1 ]; then
    printf '# observed unreachable-origin refusal: %s\n' "$(printf '%s\n' "$out" | tail -n 1)"
  fi
  pass "an unreachable origin refuses a potentially stale pooled worktree"
}

test_direct_pr_and_scout_refresh_before_launch() {
  local rec id out status contract current
  for contract in direct-pr scout; do
    id="pool-${contract}-r3"
    rec=$(make_case "$contract" "$id")
    read_case_record "$rec"
    if [ "$contract" = scout ]; then
      out=$(run_spawn "$id" --scout)
    else
      out=$(run_spawn "$id" --mode direct-PR --yolo off)
    fi
    status=$?
    expect_code 0 "$status" "$contract spawn should refresh a stale pooled worktree"
    current=$(git -C "$POOL_DIR" rev-parse origin/main)
    [ "$(git -C "$POOL_DIR" rev-parse HEAD)" = "$current" ] \
      || fail "$contract spawn did not start at current origin/main"
    assert_grep 'must survive a newly spawned branch' "$POOL_DIR/advanced-main.txt" \
      "$contract spawn omitted advanced-main content"
    if [ "${FM_TEST_EVIDENCE:-0}" = 1 ]; then
      printf '# observed %s spawn: %s\n' "$contract" "$(printf '%s\n' "$out" | tail -n 1)"
    fi
  done
  pass "direct-PR ships and scouts both refresh stale pooled worktrees before launch"
}

test_dirty_pool_refuses_without_discarding_work() {
  local rec id out status before
  id='pool-dirty-refusal-r4'
  rec=$(make_case dirty-refusal "$id")
  read_case_record "$rec"
  before=$(git -C "$POOL_DIR" rev-parse HEAD)
  printf 'keep this local work\n' > "$POOL_DIR/uncommitted.txt"

  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "spawn succeeded despite a dirty pooled worktree"
  assert_contains "$out" "is not clean" "spawn did not clearly refuse a dirty pooled worktree"
  [ "$(git -C "$POOL_DIR" rev-parse HEAD)" = "$before" ] \
    || fail "spawn moved HEAD while refusing a dirty pooled worktree"
  assert_grep 'keep this local work' "$POOL_DIR/uncommitted.txt" \
    "spawn discarded uncommitted work while refusing the pool"
  if [ "${FM_TEST_EVIDENCE:-0}" = 1 ]; then
    printf '# observed dirty refusal: %s; preserved=%s\n' \
      "$(printf '%s\n' "$out" | tail -n 1)" "$(cat "$POOL_DIR/uncommitted.txt")"
  fi
  pass "a dirty pooled worktree is refused without discarding its local work"
}

test_unresolved_remote_default_refuses_pool() {
  local rec id out status before
  id='pool-unresolved-default-r5'
  rec=$(make_case unresolved-default "$id")
  read_case_record "$rec"
  git --git-dir="$CASE_DIR/origin.git" symbolic-ref HEAD refs/heads/missing-default
  before=$(git -C "$POOL_DIR" rev-parse HEAD)

  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "spawn succeeded despite an unresolved remote default branch"
  assert_contains "$out" "could not resolve origin's current default branch" \
    "spawn did not clearly refuse an unresolved remote default branch"
  [ "$(git -C "$POOL_DIR" rev-parse HEAD)" = "$before" ] \
    || fail "spawn moved HEAD after failing to resolve the remote default branch"
  if [ "${FM_TEST_EVIDENCE:-0}" = 1 ]; then
    printf '# observed unresolved-default refusal: %s\n' "$(printf '%s\n' "$out" | tail -n 1)"
  fi
  pass "an unresolved remote default branch refuses the pooled worktree"
}

# A slot left on a stale submodule pin is the field failure this diagnosis exists
# for: a refresh moved the superproject and left the submodule behind, so the
# refusal fires a spawn later, on a slot whose own `git status` looks clean to the
# operator. Nothing here is converged - the gate only has to say why. The fixture
# only builds the repositories; the residue itself is produced by a real spawn, so
# these tests cover the reset that actually strands the submodule.
make_submodule_case() {  # <name> <id>
  local name=$1 id=$2 case_dir home project origin pool publisher fakebin sub subpin1 subpin2 advanced
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  project="$case_dir/project"
  origin="$case_dir/origin.git"
  pool="$case_dir/pool"
  publisher="$case_dir/publisher"
  sub="$case_dir/sub-origin"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")

  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config"
  printf 'codex\n' > "$home/config/crew-harness"
  fm_test_spawn_brief "$home" "$id"
  touch "$home/state/.last-watcher-beat"

  git init --quiet -b main "$sub"
  printf 'pin one\n' > "$sub/lib.txt"
  git -C "$sub" add lib.txt
  git -C "$sub" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm sub-one
  subpin1=$(git -C "$sub" rev-parse HEAD)
  printf 'pin two\n' > "$sub/lib.txt"
  git -C "$sub" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qam sub-two
  subpin2=$(git -C "$sub" rev-parse HEAD)
  git -C "$sub" checkout --quiet "$subpin1"

  git init --quiet -b main "$project"
  printf 'base\n' > "$project/README.md"
  git -C "$project" add README.md
  git -C "$project" -c protocol.file.allow=always -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
    submodule --quiet add "file://$sub" ui
  git -C "$project" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm initial
  git clone --quiet --bare "$project" "$origin"
  git -C "$project" remote add origin "file://$origin"
  git -C "$project" worktree add --quiet --detach "$pool" HEAD
  git -C "$pool" -c protocol.file.allow=always submodule --quiet update --init

  # Advance origin and move the submodule pin, exactly as the field incident did.
  git clone --quiet "file://$origin" "$publisher"
  git -C "$publisher" -c protocol.file.allow=always submodule --quiet update --init
  git -C "$publisher/ui" checkout --quiet "$subpin2"
  git -C "$publisher" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qam advance-pin
  git -C "$publisher" push --quiet origin main
  advanced=$(git -C "$publisher" rev-parse HEAD)

  printf '%s\n' "$case_dir|$home|$project|$pool|$fakebin|$subpin1|$subpin2|$advanced"
}

read_submodule_case() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJECT_DIR POOL_DIR FAKEBIN_DIR SUBPIN1 SUBPIN2 ADVANCED_SHA <<EOF
$1
EOF
}

# The first of two consecutive spawns: it succeeds, resets the superproject onto
# the base that moved the pin, and leaves the submodule checkout on the pin the
# old base recorded. That reset is what strands the slot, so every case below
# starts from residue this code path actually produced rather than a hand-built one.
strand_submodule_pin_via_spawn() {  # <seed-id>
  local id=$1 out status
  fm_test_spawn_brief "$HOME_DIR" "$id"
  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  expect_code 0 "$status" "the spawn that moves the submodule pin should succeed"
  assert_contains "$out" "spawned $id" "the spawn that moves the submodule pin did not report success"
  [ "$(git -C "$POOL_DIR" rev-parse HEAD)" = "$ADVANCED_SHA" ] \
    || fail "the first spawn did not move the pooled base across the moved submodule pin"
  [ "$(git -C "$POOL_DIR/ui" rev-parse HEAD)" = "$SUBPIN1" ] \
    || fail "the first spawn did not strand the submodule on the pin the old base recorded"
}

test_stale_submodule_pin_explains_itself() {
  local rec id out status before before_sub
  id='pool-stale-pin-r7'
  rec=$(make_submodule_case stale-pin "$id")
  read_submodule_case "$rec"
  strand_submodule_pin_via_spawn 'pool-stale-pin-seed-r7'
  git -C "$POOL_DIR" remote remove origin
  before=$(git -C "$POOL_DIR" rev-parse HEAD)
  before_sub=$(git -C "$POOL_DIR/ui" rev-parse HEAD)

  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "the second spawn launched from a slot carrying a stale submodule pin"
  assert_contains "$out" "stale submodule checkout" \
    "refusal did not name the cause as a stale submodule checkout"
  assert_contains "$out" "submodule 'ui'" "refusal did not name the submodule"
  assert_contains "$out" "$SUBPIN1" "refusal did not report the pin the slot actually has"
  assert_contains "$out" "$SUBPIN2" "refusal did not report the pin the base records"
  # No remedy is printed on purpose: the containment check reads local refs only,
  # so a stale remote-tracking ref can make an unpushed commit look contained, and
  # a checkout command on that judgement could cost the operator a commit.
  assert_not_contains "$out" "submodule update --checkout" \
    "refusal printed a remedy command the containment check cannot stand behind"
  assert_not_contains "$out" "refusing to discard uncommitted work" \
    "a stale pin was misreported as uncommitted work"
  [ "$(git -C "$POOL_DIR" rev-parse HEAD)" = "$before" ] \
    || fail "spawn moved HEAD while refusing a stale submodule pin"
  [ "$(git -C "$POOL_DIR/ui" rev-parse HEAD)" = "$before_sub" ] \
    || fail "spawn converged the submodule; this gate must never touch the slot"
  if [ "${FM_TEST_EVIDENCE:-0}" = 1 ]; then
    printf '# observed stale-pin refusal: %s\n' "$(printf '%s\n' "$out" | grep 'submodule' | head -n 1)"
  fi
  pass "an origin-less pool with a stale submodule pin refuses while naming both pins and no remedy"
}

test_unpushed_submodule_commit_is_still_uncommitted_work() {
  local rec id out status unpushed before before_sub
  id='pool-sub-unpushed-r10'
  rec=$(make_submodule_case sub-unpushed "$id")
  read_submodule_case "$rec"
  strand_submodule_pin_via_spawn 'pool-sub-unpushed-seed-r10'
  # A commit made inside the submodule and never pushed leaves the submodule work
  # tree clean and the pins different - the same two facts a stale pin shows. Any
  # checkout of the recorded pin would move HEAD off this commit and leave it
  # unreferenced, so this case must keep the conservative refusal.
  printf 'unlanded submodule work\n' > "$POOL_DIR/ui/unlanded.txt"
  git -C "$POOL_DIR/ui" add unlanded.txt
  git -C "$POOL_DIR/ui" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
    commit -qm unlanded-submodule-work
  unpushed=$(git -C "$POOL_DIR/ui" rev-parse HEAD)
  [ -z "$(git -C "$POOL_DIR/ui" status --porcelain)" ] \
    || fail "fixture did not leave the submodule work tree clean"
  [ "$unpushed" != "$(git -C "$POOL_DIR" rev-parse "HEAD:ui")" ] \
    || fail "fixture did not leave the recorded pin different from what is checked out"
  before=$(git -C "$POOL_DIR" rev-parse HEAD)
  before_sub=$unpushed

  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "spawn launched from a slot holding an unpushed submodule commit"
  assert_contains "$out" "refusing to discard uncommitted work" \
    "an unpushed submodule commit was not refused as uncommitted work"
  assert_not_contains "$out" "stale submodule checkout" \
    "an unpushed submodule commit was misreported as a stale pin"
  assert_not_contains "$out" "is checked out at" \
    "an unpushed submodule commit still drew the stale-pin diagnosis"
  [ "$(git -C "$POOL_DIR/ui" rev-parse HEAD)" = "$before_sub" ] \
    || fail "spawn moved the submodule off its unpushed commit"
  git -C "$POOL_DIR/ui" cat-file -e "$unpushed^{commit}" \
    || fail "the unpushed submodule commit did not survive the refusal"
  assert_grep 'unlanded submodule work' "$POOL_DIR/ui/unlanded.txt" \
    "spawn discarded the unpushed submodule work while refusing the pool"
  [ "$(git -C "$POOL_DIR" rev-parse HEAD)" = "$before" ] \
    || fail "spawn moved HEAD while refusing a slot holding an unpushed submodule commit"
  pass "an unpushed submodule commit keeps the uncommitted-work refusal and survives it"
}

test_work_inside_submodule_is_still_uncommitted_work() {
  local rec id out status
  id='pool-sub-work-r8'
  rec=$(make_submodule_case sub-work "$id")
  read_submodule_case "$rec"
  strand_submodule_pin_via_spawn 'pool-sub-work-seed-r8'
  # Put the submodule back on the pin the base records, so the ONLY deviation is
  # real work inside it. This must never be softened into a stale-pin diagnosis.
  git -C "$POOL_DIR/ui" checkout --quiet "$SUBPIN2"
  printf 'work that must survive\n' > "$POOL_DIR/ui/keep-me.txt"

  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "spawn launched from a slot holding work inside a submodule"
  assert_contains "$out" "refusing to discard uncommitted work" \
    "work inside a submodule was not refused as uncommitted work"
  assert_not_contains "$out" "stale submodule checkout" \
    "real work inside a submodule was misreported as a stale pin"
  assert_grep 'work that must survive' "$POOL_DIR/ui/keep-me.txt" \
    "spawn discarded work inside the submodule while refusing the pool"
  pass "work inside a submodule is still refused as uncommitted work, not called stale"
}

test_stale_pin_carrying_real_work_is_not_called_stale() {
  local rec id out status
  id='pool-sub-both-r9'
  rec=$(make_submodule_case sub-both "$id")
  read_submodule_case "$rec"
  strand_submodule_pin_via_spawn 'pool-sub-both-seed-r9'
  # Stale pin AND real work inside it: calling this merely stale would be wrong, so
  # the refusal must stay the conservative one.
  printf 'work that must survive\n' > "$POOL_DIR/ui/keep-me.txt"

  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "spawn launched from a slot with a stale pin and work inside it"
  assert_contains "$out" "refusing to discard uncommitted work" \
    "a stale pin carrying real work was not refused as uncommitted work"
  assert_not_contains "$out" "stale submodule checkout" \
    "a submodule holding real work was reported as merely stale"
  assert_grep 'work that must survive' "$POOL_DIR/ui/keep-me.txt" \
    "spawn discarded work inside the submodule while refusing the pool"
  pass "a stale pin carrying real work is refused conservatively, never called stale"
}

test_stale_pin_beside_other_dirt_reports_one_verdict() {
  local rec id out status
  id='pool-sub-mixed-r11'
  rec=$(make_submodule_case sub-mixed "$id")
  read_submodule_case "$rec"
  strand_submodule_pin_via_spawn 'pool-sub-mixed-seed-r11'
  # Git sorts status paths, so the stale 'ui' entry is scanned before this file.
  # The conservative verdict must not arrive contradicted by a stale-pin line.
  printf 'notes the operator still wants\n' > "$POOL_DIR/zz-notes.txt"

  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "spawn launched from a slot with a stale pin beside an untracked file"
  assert_contains "$out" "refusing to discard uncommitted work" \
    "a stale pin beside an untracked file was not refused as uncommitted work"
  assert_not_contains "$out" "stale submodule checkout" \
    "a slot carrying more than a stale pin was reported as merely stale"
  assert_not_contains "$out" "is checked out at" \
    "the stale-pin diagnosis was printed alongside the conservative refusal"
  assert_grep 'notes the operator still wants' "$POOL_DIR/zz-notes.txt" \
    "spawn discarded the untracked file while refusing the pool"
  pass "a stale pin beside other dirt yields the conservative refusal alone, with no stale-pin line"
}

# Re-lay a case's pooled worktree as a managed Treehouse slot: <pool>/<slot>/<repo>
# with the pool's state file beside the slot, which is the shape fm-spawn claims
# for its task. Rewrites POOL_DIR to the relocated checkout.
lay_out_as_pool_slot() {
  local slot_root="$CASE_DIR/slots"
  mkdir -p "$slot_root/1"
  git -C "$PROJECT_DIR" worktree move "$POOL_DIR" "$slot_root/1/project"
  printf '{"worktrees":[{"name":"1","path":"%s"}]}\n' "$slot_root/1/project" \
    > "$slot_root/treehouse-state.json"
  POOL_DIR="$slot_root/1/project"
  SLOT_CLAIM="$slot_root/1/.fm-slot-owner"
}

# The spawn side of the slot-owner claim that bin/fm-teardown.sh later reads:
# a launched task's claim names it, a slot that cannot be claimed refuses before
# anything is published; a clean abort returns its exact reservation, while a
# dirty abort retains the reservation and reports the evidence to its owner.
test_pool_slot_claim_follows_the_spawn_outcome() {
  local rec id out status before

  id='pool-slot-claim-r1'
  rec=$(make_case slot-claim "$id")
  read_case_record "$rec"
  lay_out_as_pool_slot
  out=$(run_spawn "$id" --scout)
  status=$?
  expect_code 0 "$status" "spawn from a Treehouse slot should launch"$'\n'"$out"
  assert_grep "worktree=$POOL_DIR" "$HOME_DIR/state/$id.meta" \
    "spawn did not publish the relocated slot as its worktree"
  [ -f "$SLOT_CLAIM" ] || fail "spawn left its Treehouse slot unclaimed: $out"
  grep -Fxq -- "task=$id" "$SLOT_CLAIM" \
    || fail "the slot claim does not name the spawned task: $(cat "$SLOT_CLAIM")"
  grep -Fxq -- "home=$HOME_DIR" "$SLOT_CLAIM" \
    || fail "the slot claim does not name the spawning home: $(cat "$SLOT_CLAIM")"

  id='pool-slot-unclaimable-r1'
  rec=$(make_case slot-unclaimable "$id")
  read_case_record "$rec"
  lay_out_as_pool_slot
  mkdir -p "$SLOT_CLAIM"
  before=$(git -C "$POOL_DIR" rev-parse HEAD)
  out=$(run_spawn "$id" --scout)
  status=$?
  [ "$status" -ne 0 ] || fail "spawn launched a worker on a slot it could not claim"
  assert_contains "$out" "durably reserved" \
    "spawn did not protect the unsafe reservation before allocation"
  [ -d "$SLOT_CLAIM" ] || fail "spawn replaced the directory blocking its slot claim"
  [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "spawn published a record for an unclaimable slot"
  [ "$(git -C "$POOL_DIR" rev-parse HEAD)" = "$before" ] \
    || fail "spawn moved the slot's HEAD after failing to claim it"

  id='pool-slot-claim-aborted-r1'
  rec=$(make_originless_case slot-claim-aborted "$id")
  read_case_record "$rec"
  lay_out_as_pool_slot
  git -C "$POOL_DIR" config remote.origin.fetch '+refs/heads/*:refs/remotes/origin/*'
  out=$(run_spawn "$id" --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "spawn succeeded despite an unusable origin on the slot"
  assert_contains "$out" "could not fetch origin" \
    "the aborted spawn did not refuse on its unusable origin"
  [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "the aborted spawn published task metadata"
  [ ! -e "$SLOT_CLAIM" ] && [ ! -L "$SLOT_CLAIM" ] \
    || fail "the aborted spawn left a slot claim naming a task with no record: $(cat "$SLOT_CLAIM")"
  jq -e '.worktrees[0] | (.leased // false) == false' "$CASE_DIR/slots/treehouse-state.json" >/dev/null \
    || fail "unpublished clean spawn did not return its exact durable lease"
  id=claimabortevidence1
  rec=$(make_case claim-abort-retained-evidence "$id")
  read_case_record "$rec"
  lay_out_as_pool_slot
  mkdir -p "$POOL_DIR/workspace/study"
  printf 'ignored evidence\n' > "$POOL_DIR/workspace/study/result"
  printf 'workspace/\n' >> "$(git -C "$POOL_DIR" rev-parse --path-format=absolute --git-common-dir)/info/exclude"
  printf 'uncommitted work\n' > "$POOL_DIR/uncommitted"
  out=$(run_spawn "$id" --mode no-mistakes --yolo off); status=$?
  [ "$status" -ne 0 ] || fail "spawn accepted an uncommitted slot"
  assert_contains "$out" "is not clean" "dirty abort did not reach the content guard"
  assert_absent "$HOME_DIR/state/$id.meta" "dirty aborted spawn published metadata"
  assert_grep "task=$id" "$CASE_DIR/slots/1/.fm-slot-owner" "dirty rollback removed retained claim"
  jq -e '.worktrees[0].leased == true' "$CASE_DIR/slots/treehouse-state.json" >/dev/null || fail "dirty abort released its reservation"
  assert_grep 'ignored evidence' "$POOL_DIR/workspace/study/result" "dirty abort lost evidence"
  assert_grep 'uncommitted work' "$POOL_DIR/uncommitted" "dirty abort lost work"
  assert_grep 'lease_id=fixture-1' "$HOME_DIR/state/$id.status" "dirty abort omitted its durable acquisition identity"
  pass "claims refuse conflicts; clean unpublished leases roll back, while dirty copies retain their evidence and reservation"
}

test_legacy_reservations_refuse_before_get() {
  local rec id out status marker_before head_before old_wt case_kind old=retained-study
  for case_kind in marker markerless unlanded; do
    id="legacy-$case_kind"
    rec=$(make_case "$id" "$id")
    read_case_record "$rec"
    lay_out_as_pool_slot
    mkdir -p "$POOL_DIR/workspace/$old"
    printf 'irreplaceable experiment\n' > "$POOL_DIR/workspace/$old/result.json"
    printf 'workspace/\n' >> "$(git -C "$PROJECT_DIR" rev-parse --path-format=absolute --git-common-dir)/info/exclude"
    fm_write_meta "$HOME_DIR/state/$old.meta" "kind=scout" "worktree=$POOL_DIR" \
      "project=$PROJECT_DIR" "park_state=parked"
    if [ "$case_kind" != markerless ]; then
      printf 'task=%s\nhome=%s\n' "$old" "$HOME_DIR" > "$SLOT_CLAIM"
    fi
    if [ "$case_kind" = unlanded ]; then
      printf 'unlanded implementation\n' > "$POOL_DIR/unlanded.txt"
      git -C "$POOL_DIR" add unlanded.txt
      git -C "$POOL_DIR" -c user.name=test -c user.email=test@example.invalid commit -qm unlanded
    fi
    marker_before=$(cat "$SLOT_CLAIM" 2>/dev/null || true)
    head_before=$(git -C "$POOL_DIR" rev-parse HEAD)
    old_wt=$POOL_DIR
    mkdir -p "$CASE_DIR/slots/2"
    git -C "$PROJECT_DIR" worktree add --quiet --detach "$CASE_DIR/slots/2/project" "$INITIAL_SHA"
    jq --arg p "$CASE_DIR/slots/2/project" '.worktrees += [{name:"2",path:$p}]' "$CASE_DIR/slots/treehouse-state.json" > "$CASE_DIR/state.new"
    mv "$CASE_DIR/state.new" "$CASE_DIR/slots/treehouse-state.json"
    POOL_DIR="$CASE_DIR/slots/2/project"
    out=$(FM_FAKE_TREEHOUSE_LOG="$CASE_DIR/get.log" run_spawn "$id" --scout)
    status=$?
    expect_code 0 "$status" "legacy $case_kind slot should not block the free slot: $out"
    assert_contains "$out" "durably reserved" "legacy slot was not excluded"
    assert_grep ' lease ' "$CASE_DIR/get.log" "intake did not reserve before get"
    assert_grep "worktree=$POOL_DIR" "$HOME_DIR/state/$id.meta" "spawn allocated the retained slot"
    POOL_DIR=$old_wt
    jq -e '.worktrees[0].leased==true' "$CASE_DIR/slots/treehouse-state.json" >/dev/null || fail "legacy slot lost its exclusion"
    [ "$(git -C "$POOL_DIR" rev-parse HEAD)" = "$head_before" ] || fail "legacy HEAD moved"
    [ "$(cat "$SLOT_CLAIM" 2>/dev/null || true)" = "$marker_before" ] || fail "legacy claim changed"
    assert_grep 'irreplaceable experiment' "$POOL_DIR/workspace/$old/result.json" "ignored evidence was lost"
    assert_present "$HOME_DIR/state/$old.meta" "legacy record was edited/removed"
  done
  pass "retained legacy claims, markerless records and clean unlanded heads are excluded while a free slot launches"
}

test_preclaim_acquisition_rollback_and_preservation() {
  local rec id case_kind out rc head_before real_mv
  for case_kind in write-failure foreign-marker ambiguous-marker distinct-record foreign-holder; do
    id="preclaim-$case_kind"
    rec=$(make_case "$id" "$id")
    read_case_record "$rec"
    lay_out_as_pool_slot
    head_before=$(git -C "$POOL_DIR" rev-parse HEAD)
    cat > "$CASE_DIR/after-get" <<'SH'
#!/usr/bin/env bash
set -eu
wt=$1 holder=$2
marker="$(dirname "$wt")/.fm-slot-owner"
case "$FM_TREEHOUSE_TEST_CASE" in
  foreign-marker) printf 'task=retained\nhome=%s\n' "$FM_TREEHOUSE_TEST_HOME" > "$marker" ;;
  ambiguous-marker) printf 'task=retained\ntask=another\nhome=%s\n' "$FM_TREEHOUSE_TEST_HOME" > "$marker" ;;
  distinct-record) printf 'kind=scout\nworktree=%s\n' "$wt" > "$FM_TREEHOUSE_TEST_HOME/state/retained.meta" ;;
  foreign-holder)
    state="$(dirname "$(dirname "$wt")")/treehouse-state.json"
    jq '.worktrees[0].lease_holder="foreign-owner"' "$state" > "$state.new"
    mv "$state.new" "$state" ;;
esac
SH
    chmod +x "$CASE_DIR/after-get"
    if [ "$case_kind" = write-failure ]; then
      real_mv=$(command -v mv)
      cat > "$FAKEBIN_DIR/mv" <<SH
#!/usr/bin/env bash
case "\$*" in *'/.fm-slot-owner') exit 1 ;; esac
exec '$real_mv' "\$@"
SH
      chmod +x "$FAKEBIN_DIR/mv"
    fi
    out=$(FM_FAKE_TREEHOUSE_AFTER_GET="$CASE_DIR/after-get" FM_TREEHOUSE_TEST_CASE="$case_kind" \
      FM_TREEHOUSE_TEST_HOME="$HOME_DIR" FM_FAKE_TREEHOUSE_LOG="$CASE_DIR/get.log" run_spawn "$id" --scout)
    rc=$?
    [ "$rc" -ne 0 ] || fail "preclaim $case_kind was accepted"
    assert_absent "$HOME_DIR/state/$id.meta" "preclaim $case_kind published task metadata"
    assert_grep 'get --lease --lease-holder firstmate:' "$CASE_DIR/get.log" "test never acquired a durable lease"
    [ "$(git -C "$POOL_DIR" rev-parse HEAD)" = "$head_before" ] || fail "preclaim refusal changed HEAD"
    if [ "$case_kind" = write-failure ]; then
      assert_grep 'return --force --if-lease-holder firstmate:' "$CASE_DIR/get.log" "unclaimed clean acquisition was not rolled back"
      assert_grep '--if-lease-id fixture-1' "$CASE_DIR/get.log" "rollback did not bind its acquisition id"
      jq -e '.worktrees[0] | (.leased // false) == false' "$CASE_DIR/slots/treehouse-state.json" >/dev/null || fail "clean lease leaked before claim publication"
      assert_absent "$SLOT_CLAIM" "failed publication left a claim"
    else
      assert_no_grep 'return ' "$CASE_DIR/get.log" "conflicting acquisition was returned"
      jq -e '.worktrees[0].leased == true' "$CASE_DIR/slots/treehouse-state.json" >/dev/null || fail "conflicting lease was released"
      assert_grep 'lease_id=fixture-1' "$HOME_DIR/state/$id.status" "preserved acquisition has no durable identity report"
      assert_grep "worktree=$POOL_DIR" "$HOME_DIR/state/$id.status" "preserved acquisition has no recorded path"
      case "$case_kind" in
        foreign-marker) assert_grep 'task=retained' "$SLOT_CLAIM" "foreign marker changed" ;;
        ambiguous-marker) [ "$(grep -c '^task=' "$SLOT_CLAIM")" = 2 ] || fail "ambiguous marker changed" ;;
        distinct-record) assert_grep "worktree=$POOL_DIR" "$HOME_DIR/state/retained.meta" "distinct record changed" ;;
        foreign-holder) assert_grep 'observed_holder=foreign-owner' "$HOME_DIR/state/$id.status" "foreign holder identity lost" ;;
      esac
    fi
  done
  pass "preclaim acquisition failures return only clean exclusive own leases, otherwise preserve and durably report identity"
}

test_task_duration_lease_and_relaunch() {
  local rec id=duration-owner next=duration-next out status holder lease marker head slot2 mismatch
  rec=$(make_case duration "$id")
  read_case_record "$rec"
  lay_out_as_pool_slot
  out=$(run_spawn "$id" --scout); status=$?
  expect_code 0 "$status" "durable owner spawn failed: $out"
  holder=$(sed -n 's/^treehouse_lease_holder=//p' "$HOME_DIR/state/$id.meta")
  lease=$(sed -n 's/^treehouse_lease_id=//p' "$HOME_DIR/state/$id.meta")
  [ -n "$holder" ] && [ -n "$lease" ] || fail "spawn omitted durable lease identity"
  jq -e --arg h "$holder" --arg l "$lease" '.worktrees[0] | .leased==true and .lease_holder==$h and .lease_id==$l' \
    "$CASE_DIR/slots/treehouse-state.json" >/dev/null || fail "task has no durable lease"
  mkdir -p "$POOL_DIR/workspace/$id"
  printf 'retained\n' > "$POOL_DIR/workspace/$id/evidence"
  printf 'workspace/\n' >> "$(git -C "$PROJECT_DIR" rev-parse --path-format=absolute --git-common-dir)/info/exclude"
  printf 'park_state=parked\n' >> "$HOME_DIR/state/$id.meta"
  marker=$(cat "$SLOT_CLAIM")
  head=$(git -C "$POOL_DIR" rev-parse HEAD)
  # A process-independent reservation survives a stopped/parked worker.
  slot2="$CASE_DIR/slots/2/project"
  mkdir -p "$(dirname "$slot2")"
  git -C "$PROJECT_DIR" worktree add --quiet --detach "$slot2" "$INITIAL_SHA"
  jq --arg p "$slot2" '.worktrees += [{name:"2",path:$p}]' "$CASE_DIR/slots/treehouse-state.json" > "$CASE_DIR/state.new"
  mv "$CASE_DIR/state.new" "$CASE_DIR/slots/treehouse-state.json"
  fm_test_spawn_brief "$HOME_DIR" "$next"
  POOL_DIR=$slot2
  out=$(run_spawn "$next" --scout); status=$?
  expect_code 0 "$status" "another task should get a different leased copy: $out"
  [ "$(cat "$SLOT_CLAIM")" = "$marker" ] || fail "parked task marker overwritten"
  [ "$(git -C "$CASE_DIR/slots/1/project" rev-parse HEAD)" = "$head" ] || fail "parked HEAD changed"
  assert_grep retained "$CASE_DIR/slots/1/project/workspace/$id/evidence" "parked evidence removed"
  POOL_DIR="$CASE_DIR/slots/1/project"
  FM_HOME="$HOME_DIR" bash -c '. "$1"; fm_treehouse_relaunch_reservation "$2" "$3" "$4" "$5" "$6"' _ \
    "$ROOT/bin/fm-wake-lib.sh" "$PROJECT_DIR" "$HOME_DIR/state" "$HOME_DIR/state/$id.meta" "$id" "$HOME_DIR" \
    || fail "own same-lease relaunch proof should succeed"
  assert_grep "treehouse_lease_id=$lease" "$HOME_DIR/state/$id.meta" "relaunch proof changed acquisition identity"
  # Recovery must prove BOTH home/task holder and acquisition, even when the
  # other identity axis still matches and the parked endpoint is dead.
  cp "$CASE_DIR/slots/treehouse-state.json" "$CASE_DIR/lease.before"
  cp "$HOME_DIR/state/$id.meta" "$CASE_DIR/meta.before"
  for mismatch in lease_holder lease_id; do
    jq --arg key "$mismatch" '.worktrees[0][$key]="replacement"' "$CASE_DIR/lease.before" > "$CASE_DIR/slots/treehouse-state.json"
    cp "$CASE_DIR/slots/treehouse-state.json" "$CASE_DIR/conflict.before"
    if FM_HOME="$HOME_DIR" bash -c '. "$1"; fm_treehouse_relaunch_reservation "$2" "$3" "$4" "$5" "$6"' _ \
      "$ROOT/bin/fm-wake-lib.sh" "$PROJECT_DIR" "$HOME_DIR/state" "$HOME_DIR/state/$id.meta" "$id" "$HOME_DIR"; then
      fail "relaunch accepted a different $mismatch"
    fi
    cmp -s "$CASE_DIR/meta.before" "$HOME_DIR/state/$id.meta" || fail "refused recovery rewrote its record"
    cmp -s "$CASE_DIR/conflict.before" "$CASE_DIR/slots/treehouse-state.json" || fail "refused recovery changed the conflicting lease"
    [ "$(cat "$SLOT_CLAIM")" = "$marker" ] || fail "refused recovery changed its claim"
    [ "$(git -C "$POOL_DIR" rev-parse HEAD)" = "$head" ] || fail "refused recovery reset unfinished work"
    assert_grep retained "$POOL_DIR/workspace/$id/evidence" "refused recovery removed ignored evidence"
  done
  pass "park/exit occupancy cannot free a task-duration lease and relaunch requires its exact identity"
}

test_claim_publication_keeps_foreign_identity() {
  local rec id=claim-identity other home rc before
  rec=$(make_case claim-identity "$id")
  read_case_record "$rec"
  lay_out_as_pool_slot
  mkdir -p "$CASE_DIR/other-home"
  for other in another-task "$id"; do
    home=$HOME_DIR
    [ "$other" != "$id" ] || home="$CASE_DIR/other-home"
    printf 'task=%s\nhome=%s\n' "$other" "$home" > "$SLOT_CLAIM"
    before=$(cat "$SLOT_CLAIM")
    bash -c '. "$1"; fm_treehouse_slot_owner_claim "$2" "$3" "$4"' _ \
      "$ROOT/bin/fm-wake-lib.sh" "$POOL_DIR" "$id" "$HOME_DIR"
    rc=$?
    [ "$rc" -ne 0 ] || fail "claim replaced distinct task/home"
    [ "$(cat "$SLOT_CLAIM")" = "$before" ] || fail "conflicting marker changed"
  done
  printf 'task=%s\nhome=%s\n' "$id" "$HOME_DIR" > "$SLOT_CLAIM"
  bash -c '. "$1"; fm_treehouse_slot_owner_claim "$2" "$3" "$4"' _ \
    "$ROOT/bin/fm-wake-lib.sh" "$POOL_DIR" "$id" "$HOME_DIR" || fail "identical claim was not idempotent"
  printf 'task=%s\ntask=%s\nhome=%s\n' "$id" "$id" "$HOME_DIR" > "$SLOT_CLAIM"
  if bash -c '. "$1"; fm_treehouse_slot_owner_claim "$2" "$3" "$4"' _ \
    "$ROOT/bin/fm-wake-lib.sh" "$POOL_DIR" "$id" "$HOME_DIR"; then
    fail "ambiguous marker was overwritten"
  fi
  pass "claim publication refuses another task, same id in another home, and ambiguous markers"
}

# Exercise the owner-run command through its CLI, with native-tool responses.
make_adoption_case() {
  local rec id=$1 root
  rec=$(make_case "adopt-$id" "$id")
  read_case_record "$rec"
  root="$CASE_DIR/.treehouse/project-fixture"
  mkdir -p "$root/1"
  git -C "$PROJECT_DIR" worktree move "$POOL_DIR" "$root/1/project"
  POOL_DIR="$root/1/project"
  SLOT_CLAIM="$root/1/.fm-slot-owner"
  printf '{"worktrees":[{"name":"1","path":"%s","owner_pid":0}]}\n' "$POOL_DIR" > "$root/treehouse-state.json"
  printf 'kind=scout\nproject=%s\nworktree=%s\nwindow=retained\n' "$PROJECT_DIR" "$POOL_DIR" > "$HOME_DIR/state/$id.meta"
  cat > "$FAKEBIN_DIR/treehouse" <<'STUB'
#!/usr/bin/env bash
set -eu
case "$*" in 'lease --help') exit 0 ;; esac
printf '%s\n' "$*" >> "$ADOPT_LOG"
[ "$1" = --root ] && shift 2
case "$1" in
  status)
    jq --arg status "${ADOPT_STATUS:-dirty}" --arg wt "${ADOPT_WRONG_PATH:-}" --argjson p "${ADOPT_PROCESS_PID:-0}" '
      [.worktrees[] | {name,path:(if $wt=="" then .path else $wt end),status:$status,processes:(if $p==0 then [] else [{pid:$p,name:"bash"}] end)}]' "$ADOPT_STATE" ;;
  lease)
    [ "$3" = --lease-holder ]
    jq --arg h "$4" '.worktrees[0] |= (. + {leased:true,lease_holder:$h,lease_id:"adopt-acquisition",owner_pid:0})' "$ADOPT_STATE" > "$ADOPT_STATE.new"
    mv "$ADOPT_STATE.new" "$ADOPT_STATE"
    jq '.worktrees[0] | {path,lease_holder,lease_id}' "$ADOPT_STATE" ;;
  *) exit 70 ;;
esac
STUB
  chmod +x "$FAKEBIN_DIR/treehouse"
}

run_adoption() {
  env PATH="$FAKEBIN_DIR:$PATH" FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
    ADOPT_LOG="$CASE_DIR/adopt.log" ADOPT_STATE="$(dirname "$(dirname "$POOL_DIR")")/treehouse-state.json" \
    "$ROOT/bin/fm-treehouse-adopt.sh" 2>&1
}

test_owner_adoption_preserves_work_and_is_idempotent() {
  local id=owner-adopt out status before head state meta claim sibling
  make_adoption_case "$id"
  state="$(dirname "$(dirname "$POOL_DIR")")/treehouse-state.json"
  printf 'retained uncommitted work\n' >> "$POOL_DIR/README.md"
  printf 'untracked evidence\n' > "$POOL_DIR/evidence.txt"
  head=$(git -C "$POOL_DIR" rev-parse HEAD)
  before=$(git -C "$POOL_DIR" diff)
  sibling="$CASE_DIR/other-home"
  mkdir -p "$sibling/state" "$sibling/data"
  printf -- '- other - Other domain (home: %s; scope: other; projects: ; added 2026-10-12)\n' "$sibling" > "$HOME_DIR/data/secondmates.md"
  printf 'kind=scout\nproject=%s\nworktree=%s\n' "$PROJECT_DIR" "$CASE_DIR/not-this-copy" > "$sibling/state/foreign.meta"
  cp "$sibling/state/foreign.meta" "$CASE_DIR/foreign.before"
  out=$(run_adoption); status=$?
  expect_code 0 "$status" "owner adoption failed: $out"
  assert_contains "$out" 'adopted:' 'owner command did not publish reservation'
  assert_grep 'treehouse_lease_id=adopt-acquisition' "$HOME_DIR/state/$id.meta" 'adoption omitted exact acquisition'
  [ "$(git -C "$POOL_DIR" rev-parse HEAD)" = "$head" ] || fail 'adoption moved HEAD'
  [ "$(git -C "$POOL_DIR" diff)" = "$before" ] || fail 'adoption reset uncommitted work'
  assert_grep 'untracked evidence' "$POOL_DIR/evidence.txt" 'adoption cleaned evidence'
  cmp "$sibling/state/foreign.meta" "$CASE_DIR/foreign.before" || fail 'adoption changed foreign home'
  meta=$(cat "$HOME_DIR/state/$id.meta"); claim=$(cat "$SLOT_CLAIM"); before=$(cat "$state")
  out=$(run_adoption); status=$?
  expect_code 0 "$status" "adoption rerun failed: $out"
  assert_contains "$out" 'already protected:' 'rerun was not a no-op'
  [ "$meta" = "$(cat "$HOME_DIR/state/$id.meta")" ] && [ "$claim" = "$(cat "$SLOT_CLAIM")" ] && \
    [ "$before" = "$(cat "$state")" ] || fail 'idempotent rerun changed reservation'
  [ "$(grep -c ' lease ' "$CASE_DIR/adopt.log")" -eq 1 ] || fail 'rerun leased again'
  pass 'owner CLI adopts in place, preserves contents/foreign records and reruns without mutation'
}

test_owner_adoption_saved_custody_is_never_authority() {
  local phase id out rc meta state head before
  for phase in released release-prepared restore-prepared; do
    id="saved-adopt-$phase"
    make_adoption_case "$id"
    meta="$HOME_DIR/state/$id.meta"
    state="$(dirname "$(dirname "$POOL_DIR")")/treehouse-state.json"
    printf 'copy_state=%s\n' "$phase" >> "$meta"
    printf 'task=%s\nhome=%s\n' "$id" "$CASE_DIR/foreign-home" > "$SLOT_CLAIM"
    printf 'foreign uncommitted contents\n' >> "$POOL_DIR/README.md"
    printf 'keep untracked contents\n' > "$POOL_DIR/foreign-evidence"
    head=$(git -C "$POOL_DIR" rev-parse HEAD); before=$(git -C "$POOL_DIR" diff)
    cp "$meta" "$CASE_DIR/meta.before"; cp "$state" "$CASE_DIR/pool.before"
    cp "$SLOT_CLAIM" "$CASE_DIR/claim.before"
    # Neither saved state may inspect the historical Git copy. The native
    # dependency's help probe is harmless; status/lease mutations are not.
    cat > "$FAKEBIN_DIR/git" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$ADOPT_LOG.git"
exit 9
SH
    chmod +x "$FAKEBIN_DIR/git"
    rc=0; out=$(run_adoption) || rc=$?
    if [ "$phase" = released ]; then
      expect_code 0 "$rc" "released record was not skipped: $out"
    else
      expect_code 1 "$rc" "interrupted record was not refused: $out"
      assert_contains "$out" 'interrupted copy custody' 'interrupted refusal lost its reason'
    fi
    assert_absent "$CASE_DIR/adopt.log" 'saved adoption inspected/leased a native slot'
    assert_absent "$CASE_DIR/adopt.log.git" 'saved adoption inspected the historical Git copy'
    cmp "$meta" "$CASE_DIR/meta.before" || fail 'saved adoption mutated task metadata'
    cmp "$state" "$CASE_DIR/pool.before" || fail 'saved adoption mutated native custody'
    cmp "$SLOT_CLAIM" "$CASE_DIR/claim.before" || fail 'saved adoption replaced a foreign claim'
    assert_equals "$head" "$(git -C "$POOL_DIR" rev-parse HEAD)" 'saved adoption moved HEAD'
    assert_equals "$before" "$(git -C "$POOL_DIR" diff)" 'saved adoption changed foreign working files'
    assert_grep 'keep untracked contents' "$POOL_DIR/foreign-evidence" 'saved adoption removed foreign evidence'
    pass "owner adoption preserves $phase records and never adopts their historical slot"
  done
}

test_owner_adoption_lists_conflicts_without_leasing() {
  local variant id out status state before meta
  for variant in duplicate foreign-home foreign-marker ambiguous-marker live-pid in-use unverified wrong-path replaced-lease; do
    id="owner-$variant"
    make_adoption_case "$id"
    state="$(dirname "$(dirname "$POOL_DIR")")/treehouse-state.json"
    case "$variant" in
      duplicate) cp "$HOME_DIR/state/$id.meta" "$HOME_DIR/state/other.meta" ;;
      foreign-home)
        mkdir -p "$CASE_DIR/foreign/state" "$CASE_DIR/foreign/data"
        printf -- '- other - Other domain (home: %s; scope: other; projects: ; added 2026-10-12)\n' "$CASE_DIR/foreign" > "$HOME_DIR/data/secondmates.md"
        cp "$HOME_DIR/state/$id.meta" "$CASE_DIR/foreign/state/other.meta" ;;
      foreign-marker) printf 'task=other\nhome=%s\n' "$HOME_DIR" > "$SLOT_CLAIM" ;;
      ambiguous-marker) printf 'task=%s\ntask=%s\nhome=%s\n' "$id" "$id" "$HOME_DIR" > "$SLOT_CLAIM" ;;
      live-pid) jq --argjson p "$$" '.worktrees[0].owner_pid=$p' "$state" > "$state.new"; mv "$state.new" "$state" ;;
      replaced-lease) printf 'treehouse_lease_holder=old\ntreehouse_lease_id=lost\n' >> "$HOME_DIR/state/$id.meta" ;;
    esac
    before=$(cat "$state"); meta=$(cat "$HOME_DIR/state/$id.meta")
    case "$variant" in
      in-use|unverified) out=$(ADOPT_STATUS="$variant" run_adoption) ;;
      wrong-path) out=$(ADOPT_WRONG_PATH="$CASE_DIR/not-this-slot" run_adoption) ;;
      *) out=$(run_adoption) ;;
    esac
    status=$?
    [ "$status" -ne 0 ] || fail "owner command accepted $variant"
    assert_contains "$out" 'refused:' "owner command did not list $variant conflict"
    [ "$before" = "$(cat "$state")" ] && [ "$meta" = "$(cat "$HOME_DIR/state/$id.meta")" ] || fail "$variant changed protected records"
    if [ -f "$CASE_DIR/adopt.log" ] && grep -q ' lease ' "$CASE_DIR/adopt.log"; then fail "$variant called lease"; fi
  done
  pass 'owner CLI refuses duplicate/foreign records, conflicting markers, live holders and uncertain native identity'
}

publish_feature_branch() { # <branch>
  git -C "$CASE_DIR/publisher" checkout --quiet -b "$1"
  printf 'only on %s\n' "$1" > "$CASE_DIR/publisher/feature-only.txt"
  git -C "$CASE_DIR/publisher" add feature-only.txt
  git -C "$CASE_DIR/publisher" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm feature
  git -C "$CASE_DIR/publisher" push --quiet origin "$1"
}

brief_with_base() { # <id> <base> [<intent>]
  fm_test_spawn_brief "$HOME_DIR" "$1" ${3:+"$3"}
  printf '\n# Setup\nYou are in a disposable git worktree of project, at a detached HEAD on a clean copy of its base branch.\nBase branch: %s\n' "$2" >> "$HOME_DIR/data/$1/brief.md"
}

test_named_base_branch_starts_from_that_branch() {
  local rec id out status kind
  for kind in ship scout; do
    id="pool-named-base-$kind-r1"
    rec=$(make_case "named-base-$kind" "$id")
    read_case_record "$rec"
    publish_feature_branch feature/hub
    brief_with_base "$id" feature/hub
    if [ "$kind" = ship ]; then
      out=$(run_spawn "$id" --mode direct-PR --yolo off --base-branch feature/hub)
    else
      out=$(run_spawn "$id" --scout --base-branch feature/hub)
    fi
    status=$?
    expect_code 0 "$status" "a $kind spawn with a matching base branch should launch"$'\n'"$out"
    [ "$(git -C "$POOL_DIR" rev-parse HEAD)" = "$(git -C "$POOL_DIR" rev-parse origin/feature/hub)" ] \
      || fail "the $kind copy did not start from origin/feature/hub"
    assert_grep 'only on feature/hub' "$POOL_DIR/feature-only.txt" \
      "the $kind copy is missing the base branch content"
    assert_grep 'base_branch=feature/hub' "$HOME_DIR/state/$id.meta" \
      "the $kind spawn did not record its base branch"
  done

  id='pool-named-base-missing-r1'
  rec=$(make_case named-base-missing "$id")
  read_case_record "$rec"
  brief_with_base "$id" feature/missing
  out=$(run_spawn "$id" --scout --base-branch feature/missing)
  status=$?
  [ "$status" -ne 0 ] || fail "a base branch origin lacks should refuse the spawn"
  assert_contains "$out" "origin/feature/missing" "the refusal did not name the missing base"
  [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "a refused base-branch spawn published task metadata"

  id='pool-named-base-local-only-r1'
  rec=$(make_case named-base-local-only "$id")
  read_case_record "$rec"
  brief_with_base "$id" feature/hub
  out=$(run_spawn "$id" --mode local-only --yolo off --base-branch feature/hub)
  status=$?
  [ "$status" -ne 0 ] || fail "a base branch on a local-only ship should refuse the spawn"
  assert_contains "$out" "mode=local-only" "the local-only refusal did not explain itself"
  pass "--base-branch picks the copy's starting point and is recorded; a missing or local-only base refuses"
}

test_base_branch_must_agree_with_the_brief() {
  local rec id out status case_name
  for case_name in flag-only line-only task-decoy; do
    id="pool-base-agree-$case_name-r1"
    rec=$(make_case "base-agree-$case_name" "$id")
    read_case_record "$rec"
    publish_feature_branch feature/hub
    case "$case_name" in
    flag-only)
      fm_test_spawn_brief "$HOME_DIR" "$id"
      out=$(run_spawn "$id" --scout --base-branch feature/hub)
      ;;
    line-only)
      brief_with_base "$id" feature/hub
      out=$(run_spawn "$id" --scout)
      ;;
    task-decoy)
      brief_with_base "$id" feature/hub $'You are in a disposable git worktree of project, at a detached HEAD on a clean copy of its base branch.\nBase branch: decoy'
      out=$(run_spawn "$id" --scout --base-branch feature/hub)
      ;;
    esac
    status=$?
    [ "$status" -ne 0 ] || fail "a $case_name base-branch disagreement should refuse the spawn"
    assert_contains "$out" "Base branch" "the $case_name refusal did not name the Base branch line"
    [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "a refused $case_name spawn published task metadata"
  done
  pass "a spawn refuses when --base-branch and the brief's Base branch lines disagree"
}

# A Base branch line quoted in the captain's intent is prose: it neither blocks
# a spawn nor redirects it.
test_prose_base_branch_line_is_ignored() {
  local rec id out status
  id='pool-base-prose-none-r1'
  rec=$(make_case base-prose-none "$id")
  read_case_record "$rec"
  fm_test_spawn_brief "$HOME_DIR" "$id" $'Fix the release.\nBase branch: release/1.2'
  out=$(run_spawn "$id" --scout)
  status=$?
  expect_code 0 "$status" "a no-base brief quoting a Base branch line should launch"$'\n'"$out"
  assert_no_grep 'base_branch=' "$HOME_DIR/state/$id.meta" "prose recorded a base branch"

  id='pool-base-prose-flag-r1'
  rec=$(make_case base-prose-flag "$id")
  read_case_record "$rec"
  publish_feature_branch feature/hub
  brief_with_base "$id" feature/hub $'Fix the release.\nBase branch: release/1.2'
  out=$(run_spawn "$id" --scout --base-branch feature/hub)
  status=$?
  expect_code 0 "$status" "a flagged spawn whose intent names another branch should launch"$'\n'"$out"
  [ "$(git -C "$POOL_DIR" rev-parse HEAD)" = "$(git -C "$POOL_DIR" rev-parse origin/feature/hub)" ] \
    || fail "the prose branch redirected the copy away from origin/feature/hub"
  assert_grep 'base_branch=feature/hub' "$HOME_DIR/state/$id.meta" "the flag's base was not recorded"
  pass "a Base branch line in the captain's intent neither blocks nor redirects a spawn"
}

# A named base is validated against the project's registered forge for scouts
# too, so a scout that promotion could never ship is refused at spawn.
test_scout_base_branch_refused_on_gerrit_forge() {
  local rec id out status
  id='pool-base-gerrit-scout-r1'
  rec=$(make_case base-gerrit-scout "$id")
  read_case_record "$rec"
  publish_feature_branch feature/hub
  printf '%s\n' '- project [no-mistakes forge=gerrit] - fixture (added 2026-01-01)' > "$HOME_DIR/data/projects.md"
  brief_with_base "$id" feature/hub
  out=$(run_spawn "$id" --scout --base-branch feature/hub)
  status=$?
  [ "$status" -ne 0 ] || fail "a based scout on a forge=gerrit project should refuse the spawn"
  assert_contains "$out" "forge=gerrit" "the gerrit refusal did not explain itself"
  [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "a refused gerrit scout spawn published task metadata"
  pass "a based scout on a forge=gerrit project is refused at spawn"
}

# Publish a component map and its skill on origin's default branch, then a
# feature branch that changes a mapped path and rewrites the skill's checklist,
# so a review pack read from the reviewed head would carry the rewrite.
publish_mapped_review_fixture() { # <branch>
  local pub="$CASE_DIR/publisher"
  mkdir -p "$pub/docs" "$pub/.agents/skills/demo-comp" "$pub/src"
  printf '%s\n' '{"schema": "component-map/v1", "components": [{"id": "demo", "skill": "demo-comp", "paths": ["src/**"]}]}' \
    > "$pub/docs/component-map.json"
  printf '%s\n' '---' 'name: demo-comp' 'description: Load when touching src. Keeps the demo component whole.' '---' '' \
    '## Goal and operating principle' 'Keep the demo whole.' '' '## Refuse' '- Partial demos.' '' \
    '## Review' '1. Does the change keep the demo whole? (fixture-trusted-check)' \
    > "$pub/.agents/skills/demo-comp/SKILL.md"
  printf 'base\n' > "$pub/src/demo.txt"
  git -C "$pub" add docs .agents src
  git -C "$pub" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm map
  git -C "$pub" push --quiet origin "$DEFAULT_BRANCH"
  git -C "$pub" checkout --quiet -b "$1"
  printf 'changed\n' > "$pub/src/demo.txt"
  sed -i 's/fixture-trusted-check/fixture-head-rewrite/' "$pub/.agents/skills/demo-comp/SKILL.md"
  git -C "$pub" add src .agents
  git -C "$pub" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm feature
  git -C "$pub" push --quiet origin "$1"
}

# A ship or scout whose brief names a Review range over a mapped repo gets the
# touched components' review checklists, read from its starting commit, in its
# launch brief; a non-review task and an unmapped repo get none.
test_review_range_appends_component_review_pack() {
  local rec id out status kind launch
  for kind in ship scout; do
    id="pool-review-pack-$kind-r1"
    rec=$(make_case "review-pack-$kind" "$id")
    read_case_record "$rec"
    publish_mapped_review_fixture feature/review
    fm_test_spawn_brief "$HOME_DIR" "$id"
    printf '\n# Setup\nYou are in a disposable git worktree of project, at a detached HEAD on a clean default branch.\nReview range: origin/main...origin/feature/review\n' >> "$HOME_DIR/data/$id/brief.md"
    if [ "$kind" = ship ]; then
      out=$(run_spawn "$id" --mode direct-PR --yolo off)
    else
      out=$(run_spawn "$id" --scout)
    fi
    status=$?
    expect_code 0 "$status" "a $kind review spawn over a mapped repo should launch"$'\n'"$out"
    launch="$HOME_DIR/data/$id/launch-brief.md"
    assert_grep '^# Component review checklists$' "$launch" "the $kind review launch brief has no component review section"
    assert_grep '^## Component demo$' "$launch" "the $kind review pack did not name the touched component"
    assert_grep 'Changed paths: .*src/demo.txt' "$launch" "the $kind review pack did not list the changed path"
    assert_grep 'fixture-trusted-check' "$launch" "the $kind review pack did not carry the default branch's checklist"
    assert_no_grep 'fixture-head-rewrite' "$launch" "the $kind review pack read the checklist from the reviewed head"
  done

  id='pool-review-pack-plain-r1'
  rec=$(make_case review-pack-plain "$id")
  read_case_record "$rec"
  publish_mapped_review_fixture feature/review
  out=$(run_spawn "$id" --scout)
  status=$?
  expect_code 0 "$status" "a non-review scout over a mapped repo should launch"$'\n'"$out"
  assert_no_grep 'Component review checklists' "$HOME_DIR/data/$id/launch-brief.md" "a non-review task got a component review section"
  [ ! -e "$HOME_DIR/data/$id/review-pack.md" ] || fail "a non-review task saved a review pack"

  id='pool-review-pack-unmapped-r1'
  rec=$(make_case review-pack-unmapped "$id")
  read_case_record "$rec"
  publish_feature_branch feature/review
  fm_test_spawn_brief "$HOME_DIR" "$id"
  printf '\n# Setup\nYou are in a disposable git worktree of project, at a detached HEAD on a clean default branch.\nReview range: origin/main...origin/feature/review\n' >> "$HOME_DIR/data/$id/brief.md"
  out=$(run_spawn "$id" --scout)
  status=$?
  expect_code 0 "$status" "a review scout over an unmapped repo should launch"$'\n'"$out"
  assert_no_grep 'Component review checklists' "$HOME_DIR/data/$id/launch-brief.md" "an unmapped repo's review got a component review section"
  pass "a review range appends the default branch's component review checklists; a non-review task or unmapped repo gets none"
}

# A review range that does not resolve, or a brief with two, refuses the spawn
# before any task metadata is published.
test_bad_review_range_refuses() {
  local rec id out status case_name
  for case_name in unresolved duplicate malformed; do
    id="pool-review-bad-$case_name-r1"
    rec=$(make_case "review-bad-$case_name" "$id")
    read_case_record "$rec"
    fm_test_spawn_brief "$HOME_DIR" "$id"
    printf '\n# Setup\nYou are in a disposable git worktree of project, at a detached HEAD on a clean default branch.\n' >> "$HOME_DIR/data/$id/brief.md"
    case "$case_name" in
    unresolved) printf 'Review range: origin/main...origin/feature/missing\n' ;;
    duplicate) printf 'Review range: origin/main...HEAD\nReview range: origin/main...HEAD~1\n' ;;
    malformed) printf 'Review range: origin/main..HEAD\n' ;;
    esac >> "$HOME_DIR/data/$id/brief.md"
    out=$(run_spawn "$id" --scout)
    status=$?
    [ "$status" -ne 0 ] || fail "a $case_name review range should refuse the spawn"
    case "$case_name" in
    unresolved) assert_contains "$out" "origin/feature/missing" "the unresolved refusal did not name the revision" ;;
    duplicate) assert_contains "$out" "more than one Review range" "the duplicate refusal did not name the Review range lines" ;;
    malformed) assert_contains "$out" "<base>...<head>" "the malformed refusal did not name the range form" ;;
    esac
    [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "a refused $case_name review spawn published task metadata"
  done
  pass "an unresolved, duplicated or malformed review range refuses the spawn"
}

# A relaunch re-appends the fresh launch's saved pack unchanged instead of
# reading a map or checklist the worker has since changed in its copy.
test_review_pack_survives_relaunch_unchanged() {
  local rec id=pool-review-relaunch-r1 out status launch saved
  rec=$(make_case review-relaunch "$id")
  read_case_record "$rec"
  lay_out_as_pool_slot
  publish_mapped_review_fixture feature/review
  fm_test_spawn_brief "$HOME_DIR" "$id"
  printf '\n# Setup\nYou are in a disposable git worktree of project, at a detached HEAD on a clean default branch.\nReview range: origin/main...origin/feature/review\n' >> "$HOME_DIR/data/$id/brief.md"
  out=$(run_spawn "$id" --scout); status=$?
  expect_code 0 "$status" "the review scout fixture should launch"$'\n'"$out"
  saved="$CASE_DIR/review-pack.before"
  cp "$HOME_DIR/data/$id/review-pack.md" "$saved" || fail "the fresh review launch saved no review pack"
  sed -i 's/fixture-trusted-check/fixture-worker-edit/' "$POOL_DIR/.agents/skills/demo-comp/SKILL.md"
  mv "$FAKEBIN_DIR/tmux" "$FAKEBIN_DIR/tmux-original"
  cat > "$FAKEBIN_DIR/tmux" <<SH
#!/usr/bin/env bash
case "\$*" in
  *'#{pane_current_command}'*) printf 'bash\n'; exit 0 ;;
esac
case "\$1" in list-windows) printf 'fm-%s\n' '$id'; exit 0 ;; esac
exec '$FAKEBIN_DIR/tmux-original' "\$@"
SH
  chmod +x "$FAKEBIN_DIR/tmux"
  out=$(fm_test_run_spawn "$HOME_DIR" "$POOL_DIR" "$FAKEBIN_DIR" "$id" --relaunch --harness codex); status=$?
  expect_code 0 "$status" "the review scout should relaunch"$'\n'"$out"
  launch="$HOME_DIR/data/$id/launch-brief.md"
  cmp -s "$saved" "$HOME_DIR/data/$id/review-pack.md" || fail "the relaunch rebuilt the saved review pack"
  [ "$(grep -c '^# Component review checklists$' "$launch")" -eq 1 ] || fail "the relaunch brief does not carry the review pack exactly once"
  assert_grep 'fixture-trusted-check' "$launch" "the relaunch brief lost the saved checklist"
  assert_no_grep 'fixture-worker-edit' "$launch" "the relaunch brief read the worker's edited checklist"
  pass "a relaunch re-appends the saved review pack unchanged"
}

# An unusable map refuses a review launch; a checklist that cannot be read
# launches with a warning and a block that says why.
test_review_pack_failures() {
  local rec id out status
  id='pool-review-badmap-r1'
  rec=$(make_case review-badmap "$id")
  read_case_record "$rec"
  publish_mapped_review_fixture feature/review
  git -C "$CASE_DIR/publisher" checkout --quiet "$DEFAULT_BRANCH"
  printf 'not json\n' > "$CASE_DIR/publisher/docs/component-map.json"
  git -C "$CASE_DIR/publisher" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qam break-map
  git -C "$CASE_DIR/publisher" push --quiet origin "$DEFAULT_BRANCH"
  fm_test_spawn_brief "$HOME_DIR" "$id"
  printf '\n# Setup\nYou are in a disposable git worktree of project, at a detached HEAD on a clean default branch.\nReview range: origin/main...origin/feature/review\n' >> "$HOME_DIR/data/$id/brief.md"
  out=$(run_spawn "$id" --scout); status=$?
  [ "$status" -ne 0 ] || fail "a review over an unusable map should refuse the spawn"
  assert_contains "$out" "component review pack" "the unusable-map refusal did not name the review pack"
  [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "a refused unusable-map review spawn published task metadata"

  id='pool-review-noreview-r1'
  rec=$(make_case review-noreview "$id")
  read_case_record "$rec"
  publish_mapped_review_fixture feature/review
  git -C "$CASE_DIR/publisher" checkout --quiet "$DEFAULT_BRANCH"
  sed -i '/^## Review$/,$d' "$CASE_DIR/publisher/.agents/skills/demo-comp/SKILL.md"
  git -C "$CASE_DIR/publisher" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qam drop-review
  git -C "$CASE_DIR/publisher" push --quiet origin "$DEFAULT_BRANCH"
  fm_test_spawn_brief "$HOME_DIR" "$id"
  printf '\n# Setup\nYou are in a disposable git worktree of project, at a detached HEAD on a clean default branch.\nReview range: origin/main...origin/feature/review\n' >> "$HOME_DIR/data/$id/brief.md"
  out=$(run_spawn "$id" --scout); status=$?
  expect_code 0 "$status" "a review whose checklist cannot be read should still launch"$'\n'"$out"
  assert_contains "$out" "could not be read" "the unreadable-checklist launch printed no warning"
  assert_grep '^## Component demo$' "$HOME_DIR/data/$id/launch-brief.md" "the unreadable-checklist block is missing"
  assert_grep 'Review checklist unavailable' "$HOME_DIR/data/$id/launch-brief.md" "the block does not say the checklist is unavailable"
  assert_grep 'marked unavailable is itself a finding' "$HOME_DIR/data/$id/launch-brief.md" "the brief does not tell the reviewer to report the gap"
  pass "an unusable map refuses a review launch; an unreadable checklist launches with its gap named"
}

test_owner_adoption_real_idle_shell() {
  local id=owner-idle-shell pid keeper out status variant backend
  command -v python3 >/dev/null 2>&1 || { skip 'idle-shell process regression requires python3'; return; }
  for variant in own other-pane child own-job tmux-own-job tmux-other-pane zellij-own-job zellij-other-pane cmux-own-job cmux-other-pane; do
    make_adoption_case "$id-$variant"
    backend=herdr
    case "$variant" in tmux-*) backend=tmux ;; zellij-*) backend=zellij ;; cmux-*) backend=cmux ;; esac
    printf 'backend=%s\nherdr_pane_id=task-pane\nzellij_pane_id=task-pane\ncmux_surface_id=task-pane\n' "$backend" >> "$HOME_DIR/state/$id-$variant.meta"
    if [ "$backend" = tmux ]; then
      cat > "$FAKEBIN_DIR/tmux" <<'SH'
#!/usr/bin/env bash
[ "$*" = 'list-panes -t retained -F #{pane_id}' ] || exit 1
printf 'task-pane\n'
SH
      chmod +x "$FAKEBIN_DIR/tmux"
    fi
    cat > "$CASE_DIR/shell.py" <<'PY'
import os, pty, select, signal, sys, time
pid, fd = pty.fork()
if pid == 0:
    os.chdir(sys.argv[1])
    env = dict(os.environ, HERDR_PANE_ID=sys.argv[3], TMUX_PANE=sys.argv[3],
               ZELLIJ_PANE_ID=sys.argv[3], CMUX_SURFACE_ID=sys.argv[3])
    if sys.argv[4] == 'own-job' or sys.argv[4].startswith(('tmux-', 'zellij-', 'cmux-')):
        env['FM_TASK_ID'] = sys.argv[5]
    else:
        env.pop('FM_TASK_ID', None)
    os.execve('/bin/bash', ['/bin/bash', '-i', '-l'], env)
try:
    # A bash comm alone can still mean login startup is running a profile child.
    # Read a builtin's output (not its echoed command) before publishing the PID.
    os.write(fd, b"printf '\\136fixture-ready\\136\\n'\n")
    output = b''
    deadline = time.monotonic() + 10
    while b'^fixture-ready^' not in output:
        if time.monotonic() >= deadline:
            raise RuntimeError('login shell did not finish startup')
        if select.select([fd], [], [], .1)[0]:
            output += os.read(fd, 4096)
    if sys.argv[4] == 'child' or sys.argv[4].endswith('own-job'):
        os.write(fd, b'sleep 300\n')
    with open(sys.argv[2], 'w') as f:
        f.write(str(pid))
    while os.path.exists(sys.argv[2]):
        time.sleep(.1)
finally:
    os.kill(pid, signal.SIGKILL)
    os.waitpid(pid, 0)
PY
    local pane=task-pane
    case "$variant" in *other-pane) pane=foreign-pane ;; esac
    python3 "$CASE_DIR/shell.py" "$POOL_DIR" "$CASE_DIR/shell.pid" "$pane" "$variant" "$id-$variant" &
    keeper=$!
    for _ in $(seq 1 100); do [ -s "$CASE_DIR/shell.pid" ] && break; sleep 0.1; done
    pid=$(cat "$CASE_DIR/shell.pid")
    local child=''
    if [ "$variant" = child ] || [[ "$variant" = *own-job ]]; then
      for _ in $(seq 1 100); do
        child=$(ps -e -o pid= -o ppid= | awk -v p="$pid" '$2==p {print $1}')
        [ -z "$child" ] || break
        sleep 0.1
      done
      [ -n "$child" ] || fail 'child-bearing-shell regression would be vacuous'
    fi
    for _ in $(seq 1 50); do
      [ "$(ps -p "$pid" -o comm= | tr -d '[:space:]')" = bash ] && break
      sleep 0.1
    done
    out=$(ADOPT_PROCESS_PID="$pid" ADOPT_STATUS=in-use run_adoption); status=$?
    [ -z "$child" ] || kill "$child"
    rm -f "$CASE_DIR/shell.pid"
    wait "$keeper" || fail 'could not clean up portable shell fixture'
    if [ "$variant" = own ] || [[ "$variant" = *own-job ]]; then
      expect_code 0 "$status" "own idle shell prevented adoption: $out"
      assert_grep 'treehouse_lease_id=adopt-acquisition' "$HOME_DIR/state/$id-$variant.meta" 'idle-shell lease not published'
    else
      [ "$status" -ne 0 ] || fail "adoption ignored $variant holder"
      assert_no_grep 'treehouse_lease_id=' "$HOME_DIR/state/$id-$variant.meta" 'refused holder was adopted'
    fi
  done
  pass 'real process evidence adopts own idle Herdr panes and live Herdr/tmux/zellij/cmux task jobs, never another pane or unrelated children'
}

test_direct_spawn_relaunch_adopts_legacy_record() {
  local rec id=spawn-legacy-relaunch out rc state head
  rec=$(make_case spawn-legacy-relaunch "$id")
  read_case_record "$rec"
  lay_out_as_pool_slot
  out=$(run_spawn "$id" --scout); rc=$?
  expect_code 0 "$rc" "initial spawn fixture failed: $out"
  state="$CASE_DIR/slots/treehouse-state.json"
  jq '.worktrees[0] |= (del(.leased,.lease_holder,.lease_id) + {owner_pid:0})' "$state" > "$state.new"
  mv "$state.new" "$state"
  awk '!/^treehouse_lease_holder=/ && !/^treehouse_lease_id=/' "$HOME_DIR/state/$id.meta" > "$HOME_DIR/state/$id.meta.new"
  mv "$HOME_DIR/state/$id.meta.new" "$HOME_DIR/state/$id.meta"
  mv "$FAKEBIN_DIR/tmux" "$FAKEBIN_DIR/tmux-original"
  cat > "$FAKEBIN_DIR/tmux" <<SH
#!/usr/bin/env bash
case "\$*" in
  *'#{pane_current_command}'*) printf 'bash\n'; exit 0 ;;
esac
case "\$1" in list-windows) printf 'fm-%s\n' '$id'; exit 0 ;; esac
exec '$FAKEBIN_DIR/tmux-original' "\$@"
SH
  chmod +x "$FAKEBIN_DIR/tmux"
  head=$(git -C "$POOL_DIR" rev-parse HEAD)
  printf 'retained relaunch work\n' > "$POOL_DIR/retained"
  out=$(fm_test_run_spawn "$HOME_DIR" "$POOL_DIR" "$FAKEBIN_DIR" "$id" --relaunch --harness codex); rc=$?
  expect_code 0 "$rc" "direct --relaunch failed to adopt legacy reservation under its held locks: $out"
  assert_grep 'treehouse_lease_id=fixture-1' "$HOME_DIR/state/$id.meta" 'direct relaunch did not publish the adopted acquisition'
  jq -e '.worktrees[0].leased==true' "$state" >/dev/null || fail 'direct relaunch left its retained slot allocatable'
  [ "$(git -C "$POOL_DIR" rev-parse HEAD)" = "$head" ] || fail 'direct relaunch reset HEAD'
  assert_grep 'retained relaunch work' "$POOL_DIR/retained" 'direct relaunch lost uncommitted contents'
  pass 'direct spawn --relaunch adopts an exclusive legacy record while both locks are held and preserves unfinished work'
}

test_saved_head_restores_under_a_fresh_lease() {
  local dir meta head wt count
  dir=$(suspend_case "$TMP_ROOT" restore-fresh) || fail 'saved fixture failed'
  suspend_saved "$dir" restore-fresh || fail 'save fixture failed'
  meta="$dir/home/state/restore-fresh.meta"
  head=$(git -C "$dir/project" rev-parse fm/restore-fresh)
  suspend_lib "$dir" fm_suspend_allocate "$meta" restore-fresh "$dir/home" "$dir/home/data" "$dir/home/state" || fail 'fresh restore allocation failed'
  wt="$dir/.treehouse/pool/1/project"
  assert_equals "$head" "$(git -C "$wt" rev-parse HEAD)" 'restoration rebased/reset the saved head'
  suspend_assert_matches '^treehouse_lease_id=new-lease$' "$meta" 'restoration reused the historical acquisition'
  suspend_assert_matches '^copy_state=restore-prepared$' "$meta" 'allocation was not durably claimed'
  assert_present "$dir/.treehouse/pool/1/.fm-slot-owner" 'restoration is unclaimed'
  assert_present "$dir/home/data/restore-fresh/suspension.bundle" 'restoration consumed the bundle'
  assert_equals "$head" "$(git -C "$dir/project" rev-parse fm/restore-fresh)" 'restoration rewrote the kept branch'
  count=$(wc -l < "$dir/calls" | tr -d ' ')
  suspend_lib "$dir" fm_suspend_allocate "$meta" restore-fresh "$dir/home" "$dir/home/data" "$dir/home/state" && fail 'duplicate restore allocated a second copy'
  assert_equals "$count" "$(wc -l < "$dir/calls" | tr -d ' ')" 'duplicate restore invoked the allocator'
  pass 'saved head restores under a fresh exclusive lease, including same-path reuse, without rebase or duplicate allocation'
}

test_saved_head_restores_in_a_different_slot() {
  local dir meta head old new
  dir=$(suspend_case "$TMP_ROOT" restore-other-slot) || fail 'different-slot fixture failed'
  suspend_saved "$dir" restore-other-slot || fail 'different-slot save failed'
  meta="$dir/home/state/restore-other-slot.meta"
  head=$(git -C "$dir/project" rev-parse fm/restore-other-slot)
  old="$dir/.treehouse/pool/1/project"
  printf 'not this task any more\n' > "$old/file"
  : > "$dir/different-slot"
  suspend_lib "$dir" fm_suspend_allocate "$meta" restore-other-slot "$dir/home" "$dir/home/data" "$dir/home/state" || fail 'a different selected physical slot could not restore the kept branch'
  new=$(sed -n 's/^worktree=//p' "$meta")
  [ "$new" != "$old" ] || fail 'fixture did not select a different physical slot'
  assert_equals "$head" "$(git -C "$new" rev-parse HEAD)" 'different-slot restoration lost the exact saved head'
  assert_equals 'not this task any more' "$(cat "$old/file")" 'different-slot restoration used historical working files'
  assert_equals false "$(jq -r .worktrees[0].leased "$dir/.treehouse/pool/treehouse-state.json")" 'restore re-reserved the historical slot'
  pass 'an allocator-selected different physical slot restores the kept branch without historical-path authority or re-reservation'
}

test_failed_restore_allocation_refuses_blind_retry() {
  local dir meta
  dir=$(suspend_case "$TMP_ROOT" restore-crash) || fail 'saved fixture failed'
  suspend_saved "$dir" restore-crash || fail 'save fixture failed'
  meta="$dir/home/state/restore-crash.meta"
  : > "$dir/fail-get"
  suspend_lib "$dir" fm_suspend_allocate "$meta" restore-crash "$dir/home" "$dir/home/data" "$dir/home/state" && fail 'failed allocation reported success'
  suspend_assert_matches '^copy_state=restore-prepared$' "$meta" 'failed attempt lost its durable claim'
  assert_present "$dir/home/data/restore-crash/suspension.bundle" 'failed attempt lost saved commits'
  rm "$dir/fail-get"
  suspend_lib "$dir" fm_suspend_allocate "$meta" restore-crash "$dir/home" "$dir/home/data" "$dir/home/state" && fail 'interrupted attempt blindly reacquired'
  assert_equals 1 "$(grep -c '^get ' "$dir/calls")" 'interrupted allocation replayed get'
  pass 'allocation failure preserves saved custody and refuses blind retry'
}

# Every case builds its own fixture under its own TMP_ROOT subdirectory and uses
# task ids no other case uses (fm-spawn keys a per-task /tmp directory by id),
# so the cases run through fm_run_case_pool (tests/lib.sh). The longest cases
# are listed first so they start first. FM_SPAWN_POOL_BASE_FRESHEN_CASE_JOBS
# overrides the concurrency, which defaults to the host's processor count capped
# at four; 1 runs the cases serially.
case_jobs=$(fm_case_pool_jobs "${FM_SPAWN_POOL_BASE_FRESHEN_CASE_JOBS:-}")
fm_run_case_pool "$case_jobs" "$TMP_ROOT/.case-logs" \
  test_owner_adoption_real_idle_shell \
  test_owner_adoption_lists_conflicts_without_leasing \
  test_preclaim_acquisition_rollback_and_preservation \
  test_linked_spawning_home_returns_primary \
  test_linked_spawning_home_returns_primary_alias \
  test_linked_spawning_home_returns_spawning \
  test_pool_slot_claim_follows_the_spawn_outcome \
  test_named_base_branch_starts_from_that_branch \
  test_legacy_reservations_refuse_before_get \
  test_base_branch_must_agree_with_the_brief \
  test_stale_pool_base_refreshes_before_branching \
  test_task_duration_lease_and_relaunch \
  test_owner_adoption_saved_custody_is_never_authority \
  test_direct_spawn_relaunch_adopts_legacy_record \
  test_owner_adoption_preserves_work_and_is_idempotent \
  test_remote_seeded_home_spawns_from_treehouse_pool \
  test_claim_publication_keeps_foreign_identity \
  test_linked_spawning_home_returns_scout \
  test_prose_base_branch_line_is_ignored \
  test_review_range_appends_component_review_pack \
  test_bad_review_range_refuses \
  test_review_pack_survives_relaunch_unchanged \
  test_review_pack_failures \
  test_scout_base_branch_refused_on_gerrit_forge \
  test_non_main_default_branch_refreshes_before_branching \
  test_direct_pr_and_scout_refresh_before_launch \
  test_dirty_pool_refuses_without_discarding_work \
  test_unresolved_remote_default_refuses_pool \
  test_unreachable_origin_refuses_stale_pool_base \
  test_originless_pool_launches_without_a_freshness_fetch \
  test_originless_dirty_pool_refuses_without_discarding_work \
  test_origin_config_without_url_refuses_pool \
  test_empty_origin_config_section_refuses_pool \
  test_empty_only_included_origin_config_section_launches_pool \
  test_inactive_conditional_origin_include_launches_pool \
  test_stale_submodule_pin_explains_itself \
  test_unpushed_submodule_commit_is_still_uncommitted_work \
  test_work_inside_submodule_is_still_uncommitted_work \
  test_stale_pin_carrying_real_work_is_not_called_stale \
  test_stale_pin_beside_other_dirt_reports_one_verdict \
  test_saved_head_restores_under_a_fresh_lease \
  test_saved_head_restores_in_a_different_slot \
  test_failed_restore_allocation_refuses_blind_retry \
  || fail 'one or more fm-spawn-pool-base-freshen cases failed'

echo "# all fm-spawn-pool-base-freshen tests passed"
