#!/usr/bin/env bash
# Tests for bin/fm-lean-review.sh: the lean pre-push review of a risky-path
# commit, driven by a fake reviewer command so no real model is ever called.
#
# The guarantees under test:
#   - A commit that changes no risky-area script, or already carries its
#     matching receipt, needs no review and calls no reviewer.
#   - The reviewer receives the commit message, the extra intent file, the
#     diff, and the four questions on stdin.
#   - A strict PASS amends only HEAD's message with the Lean-Review trailer
#     that bin/fm-safety-guard.sh receipts accepts, leaving the tree and any
#     staged change alone; --print-only or a non-HEAD commit prints the
#     trailer instead.
#   - FIX findings exit 1 and DECIDE findings exit 3, recording nothing.
#   - An answer outside the strict form, a failed reviewer, or a reviewer that
#     hits its bound exits 2 and records nothing.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

REVIEW="$ROOT/bin/fm-lean-review.sh"
GUARD="$ROOT/bin/fm-safety-guard.sh"

fm_git_identity fmtest fmtest@example.com

TMP_ROOT=$(fm_test_tmproot fm-lean-review-tests)

# The fake reviewer saves its stdin, counts its calls, prints the answer file,
# and exits with FAKE_RC.
export FAKE_DIR="$TMP_ROOT/fake"
mkdir -p "$FAKE_DIR"
cat >"$FAKE_DIR/reviewer" <<'EOF'
#!/usr/bin/env bash
cat >"$FAKE_DIR/prompt"
n=$(cat "$FAKE_DIR/calls" 2>/dev/null || echo 0)
echo $((n + 1)) >"$FAKE_DIR/calls"
cat "$FAKE_DIR/answer"
exit "${FAKE_RC:-0}"
EOF
chmod +x "$FAKE_DIR/reviewer"
FM_LEAN_REVIEW_CMD=$(printf '%q' "$FAKE_DIR/reviewer")
export FM_LEAN_REVIEW_CMD

answer() { printf '%b' "$1" >"$FAKE_DIR/answer"; }
calls() { cat "$FAKE_DIR/calls" 2>/dev/null || echo 0; }

# A repo whose base commit holds the risky-area list, one risky script, and
# its test; HEAD then changes <files> with message <msg>. Echoes the repo dir.
new_repo() { # <name> <msg> <file>...
  local r="$TMP_ROOT/$1" msg=$2 f
  shift 2
  mkdir -p "$r/bin" "$r/tests"
  git -C "$r" init -q -b main
  printf 'cleanup script bin/fm-park.sh\ncleanup test tests/fm-park*.test.sh\n' >"$r/tests/risky-areas.list"
  printf 'p1\n' >"$r/bin/fm-park.sh"
  printf 't1\n' >"$r/tests/fm-park.test.sh"
  printf 'x1\n' >"$r/README"
  git -C "$r" add -A
  git -C "$r" commit -qm base
  for f in "$@"; do printf 'change\n' >>"$r/$f"; done
  git -C "$r" add -A
  git -C "$r" commit -qm "$msg"
  printf '%s\n' "$r"
}

review() { # <repo> [args...]
  local r=$1
  shift
  (cd "$r" && "$REVIEW" "$@")
}

test_no_review_needed() {
  local r out before
  r=$(new_repo plain "docs only" README)
  answer 'VERDICT: PASS\n'
  before=$(calls)
  out=$(review "$r" 2>&1) || fail "a non-risky commit must pass: $out"
  assert_contains "$out" "changes no risky-area script; no review needed" "the skip is reported"
  assert_equals "$before" "$(calls)" "a non-risky commit calls no reviewer"
  pass "a commit that changes no risky-area script needs no review"
}

test_pass_amends_head_with_a_receipt() {
  local r out tree head before
  r=$(new_repo pass "park: name the lock" bin/fm-park.sh tests/fm-park.test.sh)
  printf 'Captain asked for the lock path in the refusal.\n' >"$TMP_ROOT/intent"
  printf 'staged\n' >>"$r/README"
  git -C "$r" add README
  tree=$(git -C "$r" rev-parse 'HEAD^{tree}')
  head=$(git -C "$r" rev-parse HEAD)
  answer '\nVERDICT: PASS\n\n'
  out=$(review "$r" --intent-file "$TMP_ROOT/intent" 2>&1) || fail "a PASS must succeed: $out"
  assert_contains "$out" "passed; HEAD is now" "the amend is reported"
  assert_not_equals "$head" "$(git -C "$r" rev-parse HEAD)" "HEAD is amended"
  assert_equals "$tree" "$(git -C "$r" rev-parse 'HEAD^{tree}')" "the amend leaves HEAD's tree alone"
  assert_equals "README" "$(git -C "$r" diff --cached --name-only)" "the staged change stays staged, not committed"
  assert_contains "$(git -C "$r" log -1 --format=%B)" "Lean-Review: $(cd "$r" && "$GUARD" receipt-id HEAD)" "the trailer names HEAD's receipt id"
  out=$(cd "$r" && "$GUARD" receipts --before "$(git rev-parse HEAD~1)" --head "$(git rev-parse HEAD)" 2>&1) \
    || fail "the CI receipt rule must accept the written trailer: $out"

  out=$(cat "$FAKE_DIR/prompt")
  assert_contains "$out" "park: name the lock" "the prompt carries the commit message"
  assert_contains "$out" "Captain asked for the lock path in the refusal." "the prompt carries the intent file"
  assert_contains "$out" "+change" "the prompt carries the diff"
  assert_contains "$out" "Q2 Weakened guards" "the prompt asks the weakened-guards question"
  assert_contains "$out" "Q3 Runtime assumptions" "the prompt asks the runtime-assumptions question"

  before=$(calls)
  out=$(review "$r" 2>&1) || fail "a reviewed commit must pass again: $out"
  assert_contains "$out" "already carries its matching receipt" "the receipt is recognised"
  assert_equals "$before" "$(calls)" "a reviewed commit calls no reviewer again"
  pass "a PASS amends only HEAD's message with a receipt CI accepts"
}

test_pass_prints_without_amending() {
  local r out head id
  r=$(new_repo print "park change" bin/fm-park.sh tests/fm-park.test.sh)
  head=$(git -C "$r" rev-parse HEAD)
  id=$(cd "$r" && "$GUARD" receipt-id HEAD)
  answer 'VERDICT: PASS\n'
  out=$(review "$r" --print-only 2>&1) || fail "--print-only PASS must succeed: $out"
  assert_contains "$out" "Lean-Review: $id" "--print-only prints the trailer"
  assert_equals "$head" "$(git -C "$r" rev-parse HEAD)" "--print-only leaves HEAD alone"

  printf 'more\n' >>"$r/README"
  git -C "$r" commit -qam "docs after"
  head=$(git -C "$r" rev-parse HEAD)
  out=$(review "$r" --commit HEAD~1 2>&1) || fail "a non-HEAD PASS must succeed: $out"
  assert_contains "$out" "Lean-Review: $id" "a non-HEAD commit gets the trailer printed"
  assert_equals "$head" "$(git -C "$r" rev-parse HEAD)" "a non-HEAD review leaves HEAD alone"
  pass "a PASS prints the trailer for --print-only or a non-HEAD commit"
}

test_findings_record_nothing() {
  local r out rc head
  r=$(new_repo findings "park change" bin/fm-park.sh)
  head=$(git -C "$r" rev-parse HEAD)
  answer 'VERDICT: FINDINGS\nFINDING: Q2 FIX bin/fm-park.sh drops the lock check\nFINDING: Q4 FIX bin/fm-park.sh has no test\n'
  out=$(review "$r" 2>&1); rc=$?
  expect_code 1 "$rc" "FIX findings"
  assert_contains "$out" "has 2 finding(s)" "the findings are counted"
  assert_contains "$out" "FINDING: Q2 FIX bin/fm-park.sh drops the lock check" "each finding is shown"

  answer 'VERDICT: FINDINGS\nFINDING: Q1 DECIDE bin/fm-park.sh also renames the flag\nFINDING: Q4 FIX bin/fm-park.sh has no test\n'
  out=$(review "$r" 2>&1); rc=$?
  expect_code 3 "$rc" "a DECIDE finding"
  assert_contains "$out" "needs-decision" "a DECIDE finding is routed to firstmate"
  assert_equals "$head" "$(git -C "$r" rev-parse HEAD)" "findings leave HEAD alone"
  pass "findings exit 1 for FIX and 3 for DECIDE and record nothing"
}

test_bad_answers_record_nothing() {
  local r out rc head bad
  r=$(new_repo strict "park change" bin/fm-park.sh)
  head=$(git -C "$r" rev-parse HEAD)
  for bad in \
    'Looks fine.\nVERDICT: PASS\n' \
    'VERDICT: PASS\nThe change is safe.\n' \
    'VERDICT: FINDINGS\n' \
    'VERDICT: FINDINGS\nFINDING: Q5 FIX out of range\n' \
    'VERDICT: FINDINGS\nFINDING: Q1 MAYBE unclear\n' \
    '~~~\nVERDICT: PASS\n~~~\n' \
    'verdict: pass\n' \
    ''; do
    answer "$bad"
    out=$(review "$r" 2>&1); rc=$?
    expect_code 2 "$rc" "answer '$bad'"
    assert_contains "$out" "did not answer in the strict verdict form" "answer '$bad' is reported"
  done

  answer 'VERDICT: PASS\n'
  out=$(FAKE_RC=7 review "$r" 2>&1); rc=$?
  expect_code 2 "$rc" "a failed reviewer call"
  assert_contains "$out" "failed with status 7" "the reviewer failure is named"

  out=$(FM_LEAN_REVIEW_CMD='sleep 5' FM_LEAN_REVIEW_TIMEOUT=1 review "$r" 2>&1); rc=$?
  expect_code 2 "$rc" "a reviewer past its bound"
  assert_contains "$out" "hit its 1s bound" "the bound is named"
  assert_equals "$head" "$(git -C "$r" rev-parse HEAD)" "no bad answer touches HEAD"
  pass "an answer outside the strict form, a failed call, or a timeout records nothing"
}

test_no_review_needed
test_pass_amends_head_with_a_receipt
test_pass_prints_without_amending
test_findings_record_nothing
test_bad_answers_record_nothing

echo "# all fm-lean-review tests passed"
