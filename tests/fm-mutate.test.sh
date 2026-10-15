#!/usr/bin/env bash
# Tests for bin/fm-mutate.sh: the mutation tester behind the sampled audit and
# the non-blocking changed-lines check.
#
# The guarantees under test:
#   - list is deterministic, never mutates comments or heredoc bodies, and
#     every mutant it prints applies and passes `bash -n`.
#   - apply finds the mutant's original line after the file shifts, and
#     refuses (exit 3) when that line is gone.
#   - tests picks the tests that name the script, and a tier filter keeps a
#     subset of the default set.
#   - run records a kill or a survivor per test and always restores the file.
#   - report counts kills, discounts a test failing its sanity run, and says
#     whether parity with the old safety core held.
#   - changed mutates only changed lines of risky-area scripts and reports
#     survivors without failing.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

MUTATE="$ROOT/bin/fm-mutate.sh"

fm_git_identity fmtest fmtest@example.com

TMP_ROOT=$(fm_test_tmproot fm-mutate-tests)

# A tiny repository with one risky script, a test that guards its refusal, a
# weak test that only checks the happy path, and a stub test runner that
# prints the real runner's FM_TEST_END markers. Echoes the root.
new_root() {
  local r="$TMP_ROOT/$1"
  mkdir -p "$r/bin" "$r/tests"
  cat >"$r/bin/guard.sh" <<'EOF_GUARD'
#!/usr/bin/env bash
# refuse a negative number: exit 1 here is a comment
n=$1
if [ "$n" -lt 0 ]; then
  echo refused >&2
  exit 3
fi
cat <<EOF_TEXT
exit 1 in a heredoc is text
EOF_TEXT
echo ok
EOF_GUARD
  cat >"$r/tests/guard.test.sh" <<'EOF_T'
out=$(bash bin/guard.sh -1 2>&1); rc=$?
[ "$rc" -eq 3 ] && [ "$out" = refused ] || exit 1
[ "$(bash bin/guard.sh 1 | tail -n 1)" = ok ]
EOF_T
  cat >"$r/tests/weak.test.sh" <<'EOF_T'
[ "$(bash bin/guard.sh 1 | tail -n 1)" = ok ]
EOF_T
  cat >"$r/bin/fm-test-run.sh" <<'EOF_RUN'
#!/usr/bin/env bash
[ "$1" = --list ] && exit 0
[ "$1" = --per-script-timeout-secs ] && shift 2
for t in "$@"; do
  bash "$t" >/dev/null 2>&1
  printf 'FM_TEST_END 2026-01-01T00:00:00Z %s exit=%s duration_ms=5 gate_skip=false\n' "$t" "$?"
done
EOF_RUN
  chmod +x "$r/bin/fm-test-run.sh"
  printf 'gate tests/guard.test.sh\nfull tests/weak.test.sh\n' >"$r/tests/tiers.list"
  printf 'guard script bin/guard.sh\nguard test tests/*.test.sh\n' >"$r/tests/risky-areas.list"
  printf 'tests/guard.test.sh\n' >"$r/tests/safety-core.list"
  git -C "$r" init -q
  git -C "$r" add -A
  git -C "$r" commit -qm base
  printf '%s\n' "$r"
}

mut() { local r=$1; shift; FM_MUTATE_ROOT=$r "$MUTATE" "$@"; }

test_list_is_valid_and_skips_text() {
  local r rows again row
  r=$(new_root list)
  rows=$(mut "$r" list bin/guard.sh --max 50) || fail "list failed"
  again=$(mut "$r" list bin/guard.sh --max 50)
  assert_equals "$rows" "$again" "list is deterministic"
  assert_contains "$rows" "bin/guard.sh:6:exit0:1" "the refusal's exit code is a mutant"
  assert_contains "$rows" "bin/guard.sh:4:cmp:1" "the guard's comparison is a mutant"
  assert_not_contains "$rows" "bin/guard.sh:2:" "a comment is never mutated"
  assert_not_contains "$rows" "bin/guard.sh:9:" "a heredoc body is never mutated"
  while IFS= read -r row; do
    cp "$r/bin/guard.sh" "$r/copy.sh"
    mut "$r" apply copy.sh "$row" || fail "listed mutant does not apply: $row"
    bash -n "$r/copy.sh" || fail "listed mutant breaks syntax: $row"
  done <<<"$rows"
  assert_equals 2 "$(mut "$r" list bin/guard.sh --max 2 | grep -c .)" "--max caps the sample"
  pass "list is deterministic, valid, and leaves comments and heredocs alone"
}

test_apply_follows_a_shifted_line() {
  local r row rc
  r=$(new_root apply)
  row=$(mut "$r" list bin/guard.sh --max 50 | grep -F 'bin/guard.sh:6:exit0:1')
  { printf '#!/usr/bin/env bash\n# a new header line\n'; tail -n +2 "$r/bin/guard.sh"; } >"$r/shifted.sh"
  mut "$r" apply shifted.sh "$row" || fail "apply did not follow the shifted line"
  assert_grep '  exit 0' "$r/shifted.sh" "the shifted refusal now exits 0"
  printf 'echo nothing\n' >"$r/other.sh"
  mut "$r" apply other.sh "$row"; rc=$?
  expect_code 3 "$rc" "a missing original line is reported absent"
  assert_equals "echo nothing" "$(cat "$r/other.sh")" "an absent mutant leaves the file alone"
  pass "apply follows a shifted line and refuses a missing one"
}

test_tests_selects_by_name_and_tier() {
  local r
  r=$(new_root tests)
  assert_equals "$(printf 'tests/guard.test.sh\ntests/weak.test.sh')" "$(mut "$r" tests bin/guard.sh)" "gate and full tests that name the script"
  assert_equals "tests/guard.test.sh" "$(mut "$r" tests bin/guard.sh --tier gate)" "the gate filter keeps the gate test"
  assert_equals "tests/guard.test.sh" "$(mut "$r" tests bin/guard.sh --from-list tests/safety-core.list)" "a list pool keeps its entries"
  pass "tests picks the script's tests and filters by tier"
}

test_run_kills_survives_and_restores() {
  local r row out before
  r=$(new_root run)
  before=$(cat "$r/bin/guard.sh")
  row=$(mut "$r" list bin/guard.sh --max 50 | grep -F 'bin/guard.sh:6:exit0:1')
  out=$(mut "$r" run bin/guard.sh "$row" tests/guard.test.sh tests/weak.test.sh) || fail "run failed: $out"
  assert_contains "$out" "$(printf 'bin/guard.sh:6:exit0:1\ttests/guard.test.sh\tkilled')" "the guarding test kills the mutant"
  assert_contains "$out" "$(printf 'bin/guard.sh:6:exit0:1\ttests/weak.test.sh\tsurvived')" "the weak test lets it survive"
  assert_equals "$before" "$(cat "$r/bin/guard.sh")" "the script is restored after the run"
  out=$(mut "$r" run bin/guard.sh "$row" --stop-on-kill tests/guard.test.sh tests/weak.test.sh)
  assert_not_contains "$out" "weak.test.sh" "--stop-on-kill stops at the first kill"
  out=$(mut "$r" run bin/guard.sh - tests/guard.test.sh)
  assert_contains "$out" "$(printf 'bin/guard.sh:unmutated\ttests/guard.test.sh\tsurvived')" "the sanity row runs the unmutated script"
  pass "run records kills and survivors and restores the script"
}

test_report_counts_and_judges_parity() {
  local r d out
  r=$(new_root report)
  d="$TMP_ROOT/report-data"
  mkdir -p "$d"
  {
    printf 'bin/guard.sh:unmutated\ttests/guard.test.sh\tsurvived\t5\n'
    printf 'bin/guard.sh:unmutated\ttests/weak.test.sh\tkilled\t5\n'
    printf 'bin/guard.sh:6:exit0:1\ttests/guard.test.sh\tkilled\t5\n'
    printf 'bin/guard.sh:6:exit0:1\ttests/weak.test.sh\tsurvived\t5\n'
    printf 'bin/guard.sh:4:cmp:1\ttests/guard.test.sh\tsurvived\t5\n'
    printf 'bin/guard.sh:4:cmp:1\ttests/weak.test.sh\tkilled\t5\n'
  } >"$d/a.current.tsv"
  {
    printf 'bin/guard.sh:6:exit0:1\ttests/guard.test.sh\tkilled\t5\n'
    printf 'bin/guard.sh:4:cmp:1\ttests/guard.test.sh\tkilled\t5\n'
  } >"$d/a.baseline.tsv"
  out=$(mut "$r" report "$d") || fail "report failed"
  assert_contains "$out" "Parity: FAILED (1 of 2" "a broken weak test is no killer, so one kill is lost"
  assert_contains "$out" "| \`bin/guard.sh:6:exit0:1\` | guard* | killed | killed | kept |" "a gate kill keeps parity"
  printf 'bin/guard.sh:4:cmp:1@current\ttests/guard.test.sh\tkilled\t5\n' >"$d/a.rerun.tsv"
  out=$(mut "$r" report "$d")
  assert_contains "$out" "Parity: held (0 of 2" "a rerun kill by the gate restores parity"
  pass "report counts kills, discounts broken tests, and judges parity"
}

test_changed_mutates_changed_lines_only() {
  local r out base
  r=$(new_root changed)
  base=$(git -C "$r" rev-parse HEAD)
  out=$(mut "$r" changed --base "$base") || fail "changed failed with no change"
  assert_contains "$out" "No mutable changed lines" "no change means nothing to mutate"
  sed 's/^  exit 3$/  exit 4/' "$r/bin/guard.sh" >"$r/g" && cat "$r/g" >"$r/bin/guard.sh" && rm "$r/g"
  sed 's/-eq 3/-eq 4/' "$r/tests/guard.test.sh" >"$r/g" && cat "$r/g" >"$r/tests/guard.test.sh" && rm "$r/g"
  git -C "$r" commit -qam change
  assert_equals "bin/guard.sh" "$(mut "$r" changed --base "$base" --scripts-only)" "the changed risky script is found"
  out=$(mut "$r" changed --base "$base") || fail "changed failed: $out"
  assert_contains "$out" "bin/guard.sh:6:" "the changed line is mutated"
  assert_not_contains "$out" "bin/guard.sh:4:" "an unchanged line is not"
  assert_contains "$out" "| killed | tests/guard.test.sh |" "the gate test kills the changed guard"
  pass "changed mutates only the changed lines of a risky script"
}

test_list_is_valid_and_skips_text
test_apply_follows_a_shifted_line
test_tests_selects_by_name_and_tier
test_run_kills_survives_and_restores
test_report_counts_and_judges_parity
test_changed_mutates_changed_lines_only

echo "# all fm-mutate tests passed"
