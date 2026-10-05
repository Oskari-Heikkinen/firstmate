#!/usr/bin/env bash
# Tests for bin/fm-safety-guard.sh: the CI guards that keep Firstmate's
# safety-core tests present and make risky-script changes carry a test.
#
# The guarantees under test:
#   - core passes when every listed test exists and a CI lane selects it, and
#     fails on a missing entry, an entry no CI lane selects, or a risky area
#     with no test line.
#   - commits fails a commit that changes a risky script without adding or
#     modifying a test in that area, judging every commit in the range rather
#     than the tip, and passes it with a test change or a `no-test-needed:`
#     line. Deleting a test never satisfies the rule.
#   - commits fails a commit that drops a safety-core entry or deletes the list,
#     and passes it with a `safety-core-removal:` line.
#   - A new or rewritten branch is judged from its merge base with the default
#     ref, and the risky areas come from the range base, so a push cannot
#     weaken the rule it is judged by.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

GUARD="$ROOT/bin/fm-safety-guard.sh"
ZERO=0000000000000000000000000000000000000000

fm_git_identity fmtest fmtest@example.com

TMP_ROOT=$(fm_test_tmproot fm-safety-guard-tests)

# A repo whose main holds the two lists, one risky script, and its test, plus
# an origin/main ref for the merge-base fallback. Echoes the repo dir.
new_repo() {
  local r="$TMP_ROOT/$1"
  mkdir -p "$r/bin" "$r/tests"
  git -C "$r" init -q -b main
  cat >"$r/tests/risky-areas.list" <<'EOF'
# area kind glob
watcher script bin/fm-watch*.sh
watcher test tests/fm-watch*.test.sh
cleanup script bin/fm-park.sh
cleanup test tests/fm-park*.test.sh
EOF
  printf '%s\n' '# core' tests/fm-watch-a.test.sh tests/fm-watch-b.test.sh >"$r/tests/safety-core.list"
  printf 'w1\n' >"$r/bin/fm-watch.sh"
  printf 'p1\n' >"$r/bin/fm-park.sh"
  printf 'a1\n' >"$r/tests/fm-watch-a.test.sh"
  printf 'b1\n' >"$r/tests/fm-watch-b.test.sh"
  printf 'x1\n' >"$r/README"
  git -C "$r" add -A
  git -C "$r" commit -qm base
  git -C "$r" update-ref refs/remotes/origin/main main
  printf '%s\n' "$r"
}

# Append <text> to <file> and commit with message <msg>.
change() { # <repo> <msg> <file>...
  local r=$1 msg=$2 f
  shift 2
  for f in "$@"; do printf 'change\n' >>"$r/$f"; done
  git -C "$r" add -A
  git -C "$r" commit -qm "$msg"
}

sha() { git -C "$1" rev-parse "$2"; }

run_commits() { # <repo> <before> [head]
  local r=$1 before=$2 head=${3:-HEAD}
  (cd "$r" && "$GUARD" commits --before "$before" --head "$(git rev-parse "$head")")
}

test_core_passes_and_fails() {
  local r out rc
  r="$TMP_ROOT/core"
  mkdir -p "$r/tests"
  printf 'x\n' >"$r/tests/fm-watch-triage.test.sh"
  printf 'x\n' >"$r/tests/lib.sh"
  printf 'demo script bin/x.sh\ndemo test tests/x.test.sh\n' >"$r/tests/risky-areas.list"
  printf '%s\n' '# core' tests/fm-watch-triage.test.sh >"$r/tests/safety-core.list"
  out=$(cd "$r" && "$GUARD" core 2>&1) || fail "core must pass on a present, CI-selected entry: $out"
  assert_contains "$out" "1 safety-core tests present and selected by CI" "core counts the entry"

  printf '%s\n' tests/fm-watch-triage.test.sh tests/fm-gone.test.sh >"$r/tests/safety-core.list"
  out=$(cd "$r" && "$GUARD" core 2>&1); rc=$?
  expect_code 1 "$rc" "a missing safety-core test fails"
  assert_contains "$out" "safety-core test tests/fm-gone.test.sh is missing" "missing entry is named"

  printf '%s\n' tests/lib.sh >"$r/tests/safety-core.list"
  out=$(cd "$r" && "$GUARD" core 2>&1); rc=$?
  expect_code 1 "$rc" "a safety-core file no CI lane selects fails"
  assert_contains "$out" "tests/lib.sh is not selected by any CI lane" "unselected entry is named"

  printf '%s\n' tests/fm-watch-triage.test.sh >"$r/tests/safety-core.list"
  printf 'demo script bin/x.sh\n' >"$r/tests/risky-areas.list"
  out=$(cd "$r" && "$GUARD" core 2>&1); rc=$?
  expect_code 1 "$rc" "a risky area without a test line fails"
  assert_contains "$out" "area demo has no test line" "the incomplete area is named"
  pass "core passes a present selected entry and fails missing, unselected, or incomplete lists"
}

test_risky_change_needs_a_test() {
  local r base out rc
  r=$(new_repo touch)
  base=$(sha "$r" HEAD)
  change "$r" "watch only" bin/fm-watch.sh
  out=$(run_commits "$r" "$base" 2>&1); rc=$?
  expect_code 1 "$rc" "a risky script change without a test fails"
  assert_contains "$out" "changes watcher risky script(s): bin/fm-watch.sh" "violation names area and script"
  assert_contains "$out" "no-test-needed: <reason>" "violation names the override"

  r=$(new_repo touch-ok)
  base=$(sha "$r" HEAD)
  change "$r" "watch with test" bin/fm-watch.sh tests/fm-watch-a.test.sh
  printf 'new\n' >"$r/tests/fm-park-new.test.sh"
  change "$r" "park with new test" bin/fm-park.sh
  change "$r" "docs only" README
  out=$(run_commits "$r" "$base" 2>&1) || fail "risky changes with tests must pass: $out"
  assert_contains "$out" "3 commit(s) keep risky-area tests" "every commit is judged"

  r=$(new_repo touch-wrong-area)
  base=$(sha "$r" HEAD)
  change "$r" "park with a watcher test" bin/fm-park.sh tests/fm-watch-a.test.sh
  out=$(run_commits "$r" "$base" 2>&1); rc=$?
  expect_code 1 "$rc" "a test in another area does not count"
  assert_contains "$out" "changes cleanup risky script(s)" "the uncovered area is named"
  pass "a risky script change needs a test in its own area"
}

test_each_commit_is_judged_not_the_tip() {
  local r base out rc
  r=$(new_repo per-commit)
  base=$(sha "$r" HEAD)
  change "$r" "script first" bin/fm-watch.sh
  change "$r" "test later" tests/fm-watch-a.test.sh
  out=$(run_commits "$r" "$base" 2>&1); rc=$?
  expect_code 1 "$rc" "a test in a later commit does not cover an earlier one"
  assert_contains "$out" "script first changes watcher" "the uncovered commit is named"
  pass "each pushed commit is judged, not only the tip"
}

test_deleting_a_test_does_not_count() {
  local r base out rc
  r=$(new_repo delete-test)
  base=$(sha "$r" HEAD)
  printf 'more\n' >>"$r/bin/fm-watch.sh"
  git -C "$r" rm -q tests/fm-watch-b.test.sh
  git -C "$r" commit -qam "drop a test with the script change
safety-core-removal: covered elsewhere"
  out=$(run_commits "$r" "$base" 2>&1); rc=$?
  expect_code 1 "$rc" "deleting a test does not satisfy the test-touch rule"
  assert_contains "$out" "changes watcher risky script(s)" "the deletion is not a test touch"
  pass "deleting a test never counts as touching one"
}

test_no_test_needed_override() {
  local r base out
  r=$(new_repo override)
  base=$(sha "$r" HEAD)
  printf 'more\n' >>"$r/bin/fm-watch.sh"
  git -C "$r" commit -qam "comment fix

no-test-needed: header comment only"
  out=$(run_commits "$r" "$base" 2>&1) || fail "the no-test-needed line must pass: $out"

  r=$(new_repo override-empty)
  base=$(sha "$r" HEAD)
  printf 'more\n' >>"$r/bin/fm-watch.sh"
  git -C "$r" commit -qam "comment fix

no-test-needed:"
  out=$(run_commits "$r" "$base" 2>&1)
  expect_code 1 "$?" "an override with no reason does not count"
  pass "no-test-needed with a reason overrides the test-touch rule"
}

test_safety_core_removal() {
  local r base out rc
  r=$(new_repo removal)
  base=$(sha "$r" HEAD)
  printf '%s\n' tests/fm-watch-a.test.sh >"$r/tests/safety-core.list"
  change "$r" "trim the core"
  out=$(run_commits "$r" "$base" 2>&1); rc=$?
  expect_code 1 "$rc" "dropping a safety-core entry fails"
  assert_contains "$out" "drops safety-core test(s) from tests/safety-core.list: tests/fm-watch-b.test.sh" "the dropped entry is named"

  r=$(new_repo removal-file)
  base=$(sha "$r" HEAD)
  git -C "$r" rm -q tests/safety-core.list
  git -C "$r" commit -qm "drop the list"
  out=$(run_commits "$r" "$base" 2>&1); rc=$?
  expect_code 1 "$rc" "deleting the safety-core list fails"
  assert_contains "$out" "tests/fm-watch-a.test.sh tests/fm-watch-b.test.sh" "every entry counts as dropped"

  r=$(new_repo removal-ok)
  base=$(sha "$r" HEAD)
  printf '%s\n' tests/fm-watch-a.test.sh tests/fm-watch-c.test.sh >"$r/tests/safety-core.list"
  git -C "$r" commit -qam "retire b

safety-core-removal: b merged into a"
  printf '%s\n' tests/fm-watch-a.test.sh tests/fm-watch-c.test.sh '# comment' >"$r/tests/safety-core.list"
  change "$r" "comment only"
  out=$(run_commits "$r" "$base" 2>&1) || fail "a removal with its override line, and a comment edit, must pass: $out"
  pass "dropping a safety-core entry fails unless the commit says why"
}

test_range_fallback_and_base_areas() {
  local r base out rc
  r=$(new_repo fallback)
  change "$r" "landed with test" bin/fm-watch.sh tests/fm-watch-a.test.sh
  git -C "$r" update-ref refs/remotes/origin/main main
  git -C "$r" checkout -q -b ci/x
  change "$r" "branch only" bin/fm-watch.sh
  out=$(run_commits "$r" "$ZERO" 2>&1); rc=$?
  expect_code 1 "$rc" "a new branch is judged from its merge base"
  assert_contains "$out" "judging $(sha "$r" main)..$(sha "$r" HEAD)" "range starts at the merge base"
  out=$(run_commits "$r" "$(sha "$r" main~1)" 2>&1); rc=$?
  expect_code 1 "$rc" "an ancestor --before is used as given"
  assert_contains "$out" "judging $(sha "$r" main~1)" "range starts at the given before"

  git -C "$r" checkout -q -b rewritten main
  change "$r" "rewritten tip" README
  out=$(run_commits "$r" "$(sha "$r" ci/x)" 2>&1) || fail "a non-ancestor before falls back to the merge base: $out"
  assert_contains "$out" "1 commit(s) keep" "only the rewritten branch's own commit is judged"

  r=$(new_repo base-areas)
  base=$(sha "$r" HEAD)
  printf 'cleanup script bin/fm-park.sh\ncleanup test tests/fm-park*.test.sh\n' >"$r/tests/risky-areas.list"
  change "$r" "unlist watcher and change it" bin/fm-watch.sh
  out=$(run_commits "$r" "$base" 2>&1); rc=$?
  expect_code 1 "$rc" "the risky areas come from the range base"
  pass "new and rewritten branches use the merge base, and areas come from the base"
}

test_core_passes_and_fails
test_risky_change_needs_a_test
test_each_commit_is_judged_not_the_tip
test_deleting_a_test_does_not_count
test_no_test_needed_override
test_safety_core_removal
test_range_fallback_and_base_areas

echo "# all fm-safety-guard tests passed"
