#!/usr/bin/env bash
# Behavior tests for bin/fm-usage-report.sh (docs/disk-room.md "Usage report").
#
# The D: line reads only growth output, here from a stand-in fm-disk-room.sh
# printing fixture lines; tests/fm-disk-room.test.sh feeds it the real growth
# report.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

unset FM_USAGE_DISK_ROOM FM_USAGE_NOW
TMP_ROOT=$(fm_test_tmproot fm-usage-report)
USAGE="$ROOT/bin/fm-usage-report.sh"
NOW=1792195200 # 2026-10-17 00:00 UTC

cat >"$TMP_ROOT/disk-room" <<'SH'
#!/usr/bin/env bash
[ "$1" = growth ] || exit 2
[ -r "$FAKE_GROWTH" ] || exit 1
cat "$FAKE_GROWTH"
SH
chmod +x "$TMP_ROOT/disk-room"

d_line() {
  printf '%s\n' "$1" >"$TMP_ROOT/growth.txt"
  FAKE_GROWTH="$TMP_ROOT/growth.txt" FM_USAGE_DISK_ROOM="$TMP_ROOT/disk-room" FM_USAGE_NOW=$NOW "$USAGE" d-line
}

test_d_line_days_to_full() {
  local out
  out=$(d_line 'Linux used: 365.8 GiB at 2026-10-17 19:42 UTC; last day unknown; last week unknown
D: free 447.6 GiB (live), reserved 0.0 GiB, after reservations 447.6 GiB; free last day -113.3 GiB over 1.0 days (-116.11 GiB/day); last week -351.7 GiB over 3.3 days (-106.71 GiB/day)
ok d runway') || fail "d-line exits 0"
  assert_equals "D: 447.6 GiB free (live) at 2026-10-17 00:00 UTC; last day -116.11 GiB/day: full in 3.9 days (2026-10-20); last week -106.71 GiB/day over 3.3 days: full in 4.2 days (2026-10-21)" \
    "$out" "each rate gives days to full and the date"
  pass "the D: line gives days to full at the daily and weekly rate"
}

test_d_line_unknown_and_not_filling() {
  local out
  out=$(d_line 'D: free 500.0 GiB (published), reserved 50.0 GiB, after reservations 450.0 GiB; free last day unknown; last week +4.0 GiB over 2.0 days (2.00 GiB/day)') ||
    fail "d-line exits 0 on an unknown window"
  assert_equals "D: 500.0 GiB free (published) at 2026-10-17 00:00 UTC; last day unknown; last week 2.00 GiB/day over 2.0 days: not filling" \
    "$out" "an unknown window reads unknown and a rising free space is not filling"
  out=$(d_line 'D: not measured (no publication); reserved 0.0 GiB') || fail "d-line exits 0 when D: is not measured"
  assert_equals "D: unknown (not measured: no publication)" "$out" "an unmeasured D: reads unknown"
  pass "unknown growth and an unmeasured D: read unknown, never an estimate"
}

test_d_line_failures() {
  local rc=0 out
  out=$(d_line 'Linux used: no sampler readings' 2>&1) || rc=$?
  expect_code 1 "$rc" "growth output without a D: line"
  assert_contains "$out" "growth output has no D: line" "the refusal names the missing line"
  rc=0
  FAKE_GROWTH="$TMP_ROOT/absent" FM_USAGE_DISK_ROOM="$TMP_ROOT/disk-room" "$USAGE" d-line >/dev/null 2>&1 || rc=$?
  expect_code 1 "$rc" "a failed growth report"
  rc=0
  out=$(printf 'D: free 1.0 GiB (live), reserved 0.0 GiB, after reservations 1.0 GiB; free last day -1.0 GiB over 1.0 days (-1.00 GiB/day); last week unknown\n' |
    FM_USAGE_NOW=$NOW "$USAGE" d-line --from -) || rc=$?
  expect_code 0 "$rc" "--from - reads saved growth output"
  assert_contains "$out" "last day -1.00 GiB/day: full in 1.0 days (2026-10-18); last week unknown" "saved output gives the same line"
  rc=0
  "$USAGE" d-line --bogus >/dev/null 2>&1 || rc=$?
  expect_code 2 "$rc" "an unknown argument is misuse"
  pass "a missing D: line or failed report exits 1, misuse exits 2"
}

test_d_line_days_to_full
test_d_line_unknown_and_not_filling
test_d_line_failures
