#!/usr/bin/env bash
# Behavior tests for bin/fm-rereview-brief.sh: a filled re-review scout brief
# copies the first report's Verdict and Findings verbatim, pins digests from the
# landed commit rather than the working tree, marks the brief a review of the
# fixes' range, separates default closure review from explicit cutover review,
# passes fm-spawn's brief checks, and refuses without writing anything when it
# would have to guess.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-dod-lib.sh
. "$ROOT/bin/fm-dod-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-rereview-brief)
SCRIPT="$ROOT/bin/fm-rereview-brief.sh"

sha256_file() {
  if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'; else sha256sum "$1" | awk '{print $1}'; fi
}

# new_world <name>: a fresh home with a first-review report and a project clone
# holding one landed commit; prints the home path.
new_world() {
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/data/first-review" "$home/projects"
  fm_git_init_commit "$home/projects/proj" >/dev/null
  mkdir -p "$home/projects/proj/scripts"
  printf '#!/bin/sh\necho fixed\n' > "$home/projects/proj/scripts/handoff.sh"
  git -C "$home/projects/proj" add scripts/handoff.sh
  git -C "$home/projects/proj" -c user.name=t -c user.email=t@example.invalid commit -qm fixes
  cat > "$home/data/first-review/report.md" <<'EOF'
# Independent review: handoff candidate

## Verdict: safe to cut over once two small fixes are in (F1 and F2)

The HANDOFF line stays backward compatible.

## What I did

- Ran things that are not findings.

## Findings

### F1. The dossier machinery can hang a handoff

Reproduced with a hanging inventory.

```
## Not a heading inside a fence
```

### F2. A foreign checkout's run_tests.py executes

Reproduced from another checkout.

## Recommended exact cutover steps

1. Rollback copy first.
EOF
  printf '%s\n' "$home"
}

run_script() {  # <home> <args...>
  local home=$1
  shift
  FM_HOME="$home" "$SCRIPT" "$@"
}

test_fills_brief_from_report_and_commit() {
  local home out rc brief sha want
  home=$(new_world fill)
  # A dirty working tree must not leak into the pinned digest.
  printf 'uncommitted\n' >> "$home/projects/proj/scripts/handoff.sh"
  out=$(run_script "$home" rr proj --first first-review --commit HEAD --cutover \
    --file scripts/handoff.sh --heavy-slot /opt/heavy-slot.sh \
    --context 'The live adapter is still sha256 abc.' --spec 'Never touch ~/.cache/queue.' 2>&1); rc=$?
  expect_code 0 "$rc" "fill should succeed: $out"
  brief="$home/data/rr/brief.md"
  assert_contains "$out" "filled: $brief" "prints the filled brief path"
  sha=$(git -C "$home/projects/proj" rev-parse HEAD)
  git -C "$home/projects/proj" show HEAD:scripts/handoff.sh > "$TMP_ROOT/committed-blob"
  want=$(sha256_file "$TMP_ROOT/committed-blob")
  assert_not_equals "$want" "$(sha256_file "$home/projects/proj/scripts/handoff.sh")" "fixture working tree differs from the commit"
  assert_grep "\`scripts/handoff.sh\` sha256 \`$want\`" "$brief" "digest comes from the landed commit"
  assert_grep "$sha" "$brief" "full landed sha is named"
  assert_equals "$(git -C "$home/projects/proj" rev-parse HEAD~1)...$sha" "$(fm_brief_review_ranges "$brief")" \
    "the brief's one review range runs from the commit's parent to the commit"
  assert_grep '> **safe to cut over once two small fixes are in (F1 and F2)**' "$brief" "verdict heading text is carried"
  assert_grep '> The HANDOFF line stays backward compatible.' "$brief" "verdict body is quoted verbatim"
  assert_grep '> ### F1. The dossier machinery can hang a handoff' "$brief" "F1 is quoted"
  assert_grep '> ### F2. A foreign checkout' "$brief" "F2 after a fenced pseudo-heading is still in the findings"
  assert_grep '> ## Not a heading inside a fence' "$brief" "a fenced pseudo-heading does not end the findings"
  assert_no_grep 'Ran things that are not findings' "$brief" "other sections are not copied"
  assert_no_grep 'Rollback copy first' "$brief" "sections after findings are not copied"
  assert_grep 'The live adapter is still sha256 abc.' "$brief" "context is appended to the intent"
  assert_grep 'Never touch ~/.cache/queue.' "$brief" "extra spec line is kept"
  # shellcheck disable=SC2016 # Literal Markdown code span, not command substitution.
  assert_grep 'nice 19 and ionice -c3 through `/opt/heavy-slot.sh --validate`' "$brief" "heavy-slot rule names the helper"
  assert_grep 'safe to cut over / safe with named fixes / not safe' "$brief" "report shape asks for the verdict"
  assert_grep 'final cutover steps pinned to the digests above' "$brief" "cutover steps stay digest-pinned"
  assert_grep 'pre-check that the live copy is still the reviewed baseline' "$brief" "cutover keeps the live-baseline pre-check"
  assert_grep 'rollback copy' "$brief" "report shape asks for rollback"
  assert_grep 'Apply lean-review and the selected risk tier.' "$brief" "cutover still applies lean-review"
  assert_grep 'This is a SCOUT task' "$brief" "scaffolded as a scout"
  if fm_brief_task_placeholders_present "$brief"; then fail "placeholders left in the brief"; fi
  fm_brief_task_content_valid "$brief" || fail "fm-spawn would reject the brief's task content"
  if fm_brief_intent_address_line "$brief" >/dev/null; then fail "intent has an operator-address line"; fi
  pass "fm-rereview-brief: fills intent and spec from the report and pins commit digests"
}

test_report_path_and_default_heavy_rule() {
  local home out rc brief
  home=$(new_world path)
  out=$(run_script "$home" rr2 proj --first "$home/data/first-review/report.md" \
    --commit HEAD --file scripts/handoff.sh --repo-dir "$home/projects/proj" 2>&1); rc=$?
  expect_code 0 "$rc" "report path form should succeed: $out"
  brief="$home/data/rr2/brief.md"
  assert_grep 'nice 19 and ionice -c3.' "$brief" "heavy rule without a helper"
  assert_no_grep 'validate`' "$brief" "no helper named when none was given"
  assert_grep 'Short independent closure-and-delta review of the named blocker/major fixes' "$brief" "default asks for closure review"
  assert_grep 'Apply lean-review and the selected risk tier.' "$brief" "default applies lean-review"
  assert_grep 'Report: a clear verdict (PASS / PASS with minors / FAIL under lean-review)' "$brief" "default verdict is not cutover approval"
  assert_grep 'each first-review finding marked closed or still open with exact-head evidence (commit, commands, output, file:line)' "$brief" "default keeps findings and exact-head evidence"
  assert_grep 'anything new broken' "$brief" "default checks the delta"
  assert_grep 'not a cutover gate' "$brief" "default explicitly avoids a cutover gate"
  assert_no_grep 'safe to cut over / safe with named fixes / not safe' "$brief" "default does not request a cutover verdict"
  assert_no_grep 'final cutover steps' "$brief" "default requests no cutover steps"
  assert_no_grep 'pre-check that the live copy is still the reviewed baseline' "$brief" "default requests no live-baseline pre-check"
  assert_no_grep 'rollback copy' "$brief" "default requests no rollback copy"
  pass "fm-rereview-brief: default closure review accepts a report path and no cutover paperwork"
}

test_base_sets_the_review_range() {
  local home out rc root sha
  home=$(new_world base)
  printf 'more\n' >> "$home/projects/proj/scripts/handoff.sh"
  git -C "$home/projects/proj" -c user.name=t -c user.email=t@example.invalid commit -qam 'more fixes'
  root=$(git -C "$home/projects/proj" rev-parse HEAD~2)
  sha=$(git -C "$home/projects/proj" rev-parse HEAD)
  out=$(run_script "$home" rr3 proj --first first-review --commit HEAD --base HEAD~2 \
    --file scripts/handoff.sh 2>&1); rc=$?
  expect_code 0 "$rc" "--base form should succeed: $out"
  assert_equals "$root...$sha" "$(fm_brief_review_ranges "$home/data/rr3/brief.md")" \
    "the review range starts at --base, resolved to a full sha"
  pass "fm-rereview-brief: --base sets where the reviewed range starts"
}

expect_refusal() {  # <home> <task-id> <message-fragment> <label> <args...>
  local home=$1 id=$2 frag=$3 label=$4 out rc
  shift 4
  out=$(run_script "$home" "$id" proj "$@" 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "$label: expected refusal, got success"
  assert_contains "$out" "$frag" "$label: refusal names the problem"
  assert_absent "$home/data/$id" "$label: nothing is scaffolded"
}

test_refuses_rather_than_guessing() {
  local home report
  home=$(new_world refuse)
  report="$home/data/first-review/report.md"

  sed 's/^## Verdict.*/## Summary/' "$report" > "$TMP_ROOT/no-verdict.md"
  expect_refusal "$home" r1 "no 'Verdict' heading" "missing verdict" \
    --first "$TMP_ROOT/no-verdict.md" --commit HEAD --file scripts/handoff.sh

  sed 's/^## Findings/## Notes/' "$report" > "$TMP_ROOT/no-findings.md"
  expect_refusal "$home" r2 "no 'Findings' heading" "missing findings" \
    --first "$TMP_ROOT/no-findings.md" --commit HEAD --file scripts/handoff.sh

  printf '# R\n\n## Verdict\n\nNot safe.\n\n## Findings\n\n## Next\n\nx\n' > "$TMP_ROOT/empty-findings.md"
  expect_refusal "$home" r3 "'Findings' section" "empty findings" \
    --first "$TMP_ROOT/empty-findings.md" --commit HEAD --file scripts/handoff.sh

  { cat "$report"; printf '\n## Verdict (again)\n\nSafe.\n'; } > "$TMP_ROOT/two-verdicts.md"
  expect_refusal "$home" r4 "more than one 'Verdict' heading" "ambiguous verdict" \
    --first "$TMP_ROOT/two-verdicts.md" --commit HEAD --file scripts/handoff.sh

  expect_refusal "$home" r5 "not found" "missing report" \
    --first no-such-review --commit HEAD --file scripts/handoff.sh

  expect_refusal "$home" r6 "commit deadbeef not found" "unknown commit" \
    --first first-review --commit deadbeef --file scripts/handoff.sh

  expect_refusal "$home" r7 "is not a file" "missing candidate file" \
    --first first-review --commit HEAD --file scripts/absent.sh

  expect_refusal "$home" r8 "--file" "no candidate files" \
    --first first-review --commit HEAD

  expect_refusal "$home" r9 "has no parent; pass --base" "root commit without --base" \
    --first first-review --commit HEAD~1 --file scripts/handoff.sh

  expect_refusal "$home" r10 "base deadbeef not found" "unknown base" \
    --first first-review --commit HEAD --base deadbeef --file scripts/handoff.sh
  pass "fm-rereview-brief: refuses and writes nothing when it would have to guess"
}

test_help_describes_modes() {
  local out rc
  out=$("$SCRIPT" --help 2>&1); rc=$?
  expect_code 0 "$rc" "help should succeed: $out"
  assert_contains "$out" '--cutover' "help documents cutover opt-in"
  assert_contains "$out" 'Default: closure-and-delta review with exact-head evidence' "help documents default mode"
  assert_contains "$out" 'never an automatic second round' "help documents conditional invocation"
  pass "fm-rereview-brief: help explains default and explicit cutover modes"
}

test_fills_brief_from_report_and_commit
test_report_path_and_default_heavy_rule
test_help_describes_modes
test_base_sets_the_review_range
test_refuses_rather_than_guessing
