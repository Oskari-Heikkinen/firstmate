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

TMP_ROOT=$(fm_test_tmproot fm-spawn-pool-base-freshen)

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

test_linked_spawning_home_rejects_primary_before_refresh() {
  local rec id out status returned primary spawning before_reflog
  for returned in primary primary-alias spawning scout; do
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
  done
}

test_stale_pool_base_refreshes_before_branching() {
  local rec id out status current branch_head
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
  assert_contains "$out" "refusing intake" \
    "spawn did not refuse the unsafe reservation before allocation"
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
  out=$(run_spawn "$id"); status=$?
  [ "$status" -ne 0 ] || fail "spawn accepted an uncommitted slot"
  assert_absent "$HOME_DIR/state/$id.meta" "dirty aborted spawn published metadata"
  assert_grep "task=$id" "$CASE_DIR/slots/1/.fm-slot-owner" "dirty rollback removed retained claim"
  jq -e '.worktrees[0].leased == true' "$CASE_DIR/slots/treehouse-state.json" >/dev/null || fail "dirty abort released its reservation"
  assert_grep 'ignored evidence' "$POOL_DIR/workspace/study/result" "dirty abort lost evidence"
  assert_grep 'uncommitted work' "$POOL_DIR/uncommitted" "dirty abort lost work"
  assert_grep 'lease_id=fixture-1' "$HOME_DIR/state/$id.status" "dirty abort omitted its durable acquisition identity"
  pass "claims refuse conflicts; clean unpublished leases roll back, while dirty copies retain their evidence and reservation"
}

test_legacy_reservations_refuse_before_get() {
  local rec id out status marker_before head_before case_kind old=retained-study
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
    out=$(FM_FAKE_TREEHOUSE_LOG="$CASE_DIR/get.log" run_spawn "$id" --scout)
    status=$?
    [ "$status" -ne 0 ] || fail "legacy $case_kind reservation was allocated"
    assert_contains "$out" "conflicting legacy reservation" "legacy refusal omitted its owner"
    [ ! -s "$CASE_DIR/get.log" ] || fail "legacy refusal occurred after get prepared the copy"
    [ "$(git -C "$POOL_DIR" rev-parse HEAD)" = "$head_before" ] || fail "legacy HEAD moved"
    [ "$(cat "$SLOT_CLAIM" 2>/dev/null || true)" = "$marker_before" ] || fail "legacy claim changed"
    assert_grep 'irreplaceable experiment' "$POOL_DIR/workspace/$old/result.json" "ignored evidence was lost"
    assert_present "$HOME_DIR/state/$old.meta" "legacy record was edited/removed"
    assert_absent "$HOME_DIR/state/$id.meta" "new record published despite refusal"
  done
  pass "retained legacy claims, markerless records and clean unlanded heads refuse before get"
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
  local rec id=duration-owner next=duration-next out status holder lease marker head slot2
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
  # A reused path must not be adopted just because the old endpoint is dead.
  jq '.worktrees[0].lease_id="replacement"' "$CASE_DIR/slots/treehouse-state.json" > "$CASE_DIR/state.new"
  mv "$CASE_DIR/state.new" "$CASE_DIR/slots/treehouse-state.json"
  if FM_HOME="$HOME_DIR" bash -c '. "$1"; fm_treehouse_relaunch_reservation "$2" "$3" "$4" "$5" "$6"' _ \
    "$ROOT/bin/fm-wake-lib.sh" "$PROJECT_DIR" "$HOME_DIR/state" "$HOME_DIR/state/$id.meta" "$id" "$HOME_DIR"; then
    fail "relaunch accepted a different acquisition"
  fi
  assert_grep "treehouse_lease_id=$lease" "$HOME_DIR/state/$id.meta" "refused relaunch rewrote its reservation"
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
    jq --arg status "${ADOPT_STATUS:-dirty}" --arg wt "${ADOPT_WRONG_PATH:-}" '
      [.worktrees[] | {name,path:(if $wt=="" then .path else $wt end),status:$status,processes:[]}]' "$ADOPT_STATE" ;;
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

test_owner_adoption_preserves_work_and_is_idempotent
test_owner_adoption_lists_conflicts_without_leasing
test_remote_seeded_home_spawns_from_treehouse_pool
test_legacy_reservations_refuse_before_get
test_preclaim_acquisition_rollback_and_preservation
test_task_duration_lease_and_relaunch
test_claim_publication_keeps_foreign_identity
test_pool_slot_claim_follows_the_spawn_outcome
test_linked_spawning_home_rejects_primary_before_refresh
test_stale_pool_base_refreshes_before_branching
test_non_main_default_branch_refreshes_before_branching
test_direct_pr_and_scout_refresh_before_launch
test_dirty_pool_refuses_without_discarding_work
test_unresolved_remote_default_refuses_pool
test_unreachable_origin_refuses_stale_pool_base
test_originless_pool_launches_without_a_freshness_fetch
test_originless_dirty_pool_refuses_without_discarding_work
test_origin_config_without_url_refuses_pool
test_empty_origin_config_section_refuses_pool
test_empty_only_included_origin_config_section_launches_pool
test_inactive_conditional_origin_include_launches_pool
test_stale_submodule_pin_explains_itself
test_unpushed_submodule_commit_is_still_uncommitted_work
test_work_inside_submodule_is_still_uncommitted_work
test_stale_pin_carrying_real_work_is_not_called_stale
test_stale_pin_beside_other_dirt_reports_one_verdict

echo "# all fm-spawn-pool-base-freshen tests passed"
