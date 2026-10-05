#!/usr/bin/env bash
# Tests for bin/fm-green-pointer.sh: the fast-forward-only advance of the green
# pointer branch that running homes follow instead of raw main.
#
# The guarantees under test:
#   - An absent pointer is created at the passing commit, and a pointer behind
#     it is fast-forwarded to it.
#   - An older passing commit that completes after a newer one never rewinds
#     the pointer (out-of-order completions).
#   - A commit that is not on main is never published.
#   - A pointer on another line of history is refused (non-zero exit), never
#     forced, and left where it was.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

GREEN="$ROOT/bin/fm-green-pointer.sh"

fm_git_identity fmtest fmtest@example.com

TMP_ROOT=$(fm_test_tmproot fm-green-pointer-tests)

# A bare origin whose main holds three commits, plus a runner clone that plays
# the workflow's checkout. Echoes the world dir.
new_world() {
  local w="$TMP_ROOT/$1" i
  git init -q --bare "$w/origin.git"
  git -C "$w/origin.git" symbolic-ref HEAD refs/heads/main
  git clone -q "$w/origin.git" "$w/seed" 2>/dev/null
  git -C "$w/seed" symbolic-ref HEAD refs/heads/main
  for i in 1 2 3; do
    printf 'c%s\n' "$i" > "$w/seed/file"
    git -C "$w/seed" add file
    git -C "$w/seed" commit -qm "c$i"
  done
  git -C "$w/seed" push -q origin main
  git clone -q "$w/origin.git" "$w/runner"
  printf '%s\n' "$w"
}

sha_of() { git -C "$1/seed" rev-parse "$2"; }
green_of() { git -C "$1/origin.git" rev-parse --verify --quiet refs/heads/green; }
run_green() { local w=$1; shift; (cd "$w/runner" && "$GREEN" "$@"); }

test_creates_then_fast_forwards() {
  local w out c2 c3
  w=$(new_world create)
  c2=$(sha_of "$w" main~1)
  c3=$(sha_of "$w" main)
  out=$(run_green "$w" "$c2") || fail "creating the pointer failed: $out"
  assert_contains "$out" "green-pointer: created at $c2" "an absent pointer is created"
  assert_equals "$c2" "$(green_of "$w")" "pointer created at the passing commit"
  out=$(run_green "$w" "$c3") || fail "advancing the pointer failed: $out"
  assert_contains "$out" "green-pointer: advanced $c2..$c3" "a pointer behind the passing commit advances"
  assert_equals "$c3" "$(green_of "$w")" "pointer fast-forwarded to the passing commit"
  out=$(run_green "$w" "$c3") || fail "re-running at the pointer failed: $out"
  assert_contains "$out" "green-pointer: already at $c3" "a pointer already at the commit stays"
  pass "absent pointer is created and then fast-forwarded"
}

test_older_completion_never_rewinds() {
  local w out c1 c3
  w=$(new_world older)
  c1=$(sha_of "$w" main~2)
  c3=$(sha_of "$w" main)
  run_green "$w" "$c3" >/dev/null || fail "seeding the pointer failed"
  out=$(run_green "$w" "$c1") || fail "an older completion must not fail: $out"
  assert_contains "$out" "skipped: green is already at newer green commit $c3" "older completion is skipped"
  assert_equals "$c3" "$(green_of "$w")" "an older completion never rewinds the pointer"
  pass "an older passing commit completing late never rewinds the pointer"
}

test_commit_off_main_is_not_published() {
  local w out side
  w=$(new_world offmain)
  git -C "$w/seed" checkout -q -b side main~1
  printf 'side\n' > "$w/seed/file"
  git -C "$w/seed" commit -qam side
  git -C "$w/seed" push -q origin side
  side=$(git -C "$w/seed" rev-parse side)
  out=$(run_green "$w" "$side") || fail "an off-main commit must be skipped, not fail: $out"
  assert_contains "$out" "skipped: $side is not on origin/main" "off-main commit is skipped"
  [ -z "$(green_of "$w")" ] || fail "an off-main commit must never create the pointer"
  pass "a commit that is not on main is never published"
}

test_diverged_pointer_is_refused() {
  local w out rc side c3
  w=$(new_world diverged)
  c3=$(sha_of "$w" main)
  git -C "$w/seed" checkout -q -b side main~1
  printf 'side\n' > "$w/seed/file"
  git -C "$w/seed" commit -qam side
  side=$(git -C "$w/seed" rev-parse side)
  git -C "$w/seed" push -q origin "$side:refs/heads/green"
  out=$(run_green "$w" "$c3" 2>&1); rc=$?
  expect_code 1 "$rc" "a pointer on another line of history is refused"
  assert_contains "$out" "refusing to move it onto another line of history" "refusal names the divergence"
  assert_equals "$side" "$(green_of "$w")" "a refused pointer is left where it was"
  pass "a pointer on another line of history is refused, never forced"
}

test_rejects_malformed_sha() {
  local w out rc
  w=$(new_world malformed)
  out=$(run_green "$w" main 2>&1); rc=$?
  expect_code 2 "$rc" "a ref name instead of a full sha is refused"
  assert_contains "$out" "is not a full lowercase commit sha" "refusal names the malformed sha"
  [ -z "$(green_of "$w")" ] || fail "a malformed request must not create the pointer"
  pass "a non-sha argument is refused"
}

test_creates_then_fast_forwards
test_older_completion_never_rewinds
test_commit_off_main_is_not_published
test_diverged_pointer_is_refused
test_rejects_malformed_sha

echo "# all fm-green-pointer tests passed"
