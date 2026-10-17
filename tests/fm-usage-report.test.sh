#!/usr/bin/env bash
# Behavior tests for bin/fm-usage-report.sh (docs/disk-room.md "Usage report").
#
# The D: line reads only growth output, here from a stand-in fm-disk-room.sh
# printing fixture lines; tests/fm-disk-room.test.sh feeds it the real growth
# report.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

unset FM_USAGE_DISK_ROOM FM_USAGE_NOW FM_USAGE_LATTICE_CONFIG FM_USAGE_PACK_INDEX FM_USAGE_CENSUS \
  FM_USAGE_RESULTS_ROOT FM_USAGE_RECEIPTS FM_USAGE_LEDGER_CATALOG FM_USAGE_LEDGER_ROOT FM_USAGE_D_ROOT FM_USAGE_C_ROOT
TMP_ROOT=$(fm_test_tmproot fm-usage-report)
USAGE="$ROOT/bin/fm-usage-report.sh"
NOW=1792195200 # 2026-10-17 00:00 UTC

cat >"$TMP_ROOT/disk-room" <<'SH'
#!/usr/bin/env bash
case "$1" in
  growth) [ -r "$FAKE_GROWTH" ] || exit 1; cat "$FAKE_GROWTH" ;;
  status) printf '{"linux_free":%s}\n' "${FAKE_LINUX_FREE:-0}" ;;
  *) exit 2 ;;
esac
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

# One fixture of every record the report reads. D: is $F/d; HOME holds the
# treehouse homes. Each record that a path dedupe should drop names a path an
# earlier source already counted.
report_fixture() {
  F="$TMP_ROOT/report"
  local d="$F/d" h="$F/home/.treehouse/fm-a/1/firstmate"
  mkdir -p "$d/store" "$d/results/task/fetch-1" "$d/results/task/fetch-2" "$d/packs" "$F/conf" \
    "$F/receipts" "$h/data/pkg" "$F/home/lattice-ledger"
  printf '{"stores":[{"root":"%s"},{"root":"%s"}]}\n' "$d/store" "$F/absent-store" >"$F/conf/config.json"
  {
    printf '{"id":"a","kind":"ledger-recording","path":"%s/rec/a","bytes":1,"state":"verified","recorded_at":"2026-10-16T12:00:00Z"}\n' "$d"
    printf '{"id":"a","kind":"ledger-recording","path":"%s/rec/a","bytes":%s,"state":"verified","owner_home":"%s","recorded_at":"2026-10-16T12:00:00Z"}\n' "$d" $((2 << 30)) "$h"
    printf '{"id":"gone","kind":"ledger-recording","path":"%s/rec/gone","bytes":9,"state":"deleted"}\n' "$d"
    printf '{"id":"s","kind":"tetjet-slice","path":"%s/views/s","bytes":%s,"state":"verified","recorded_at":"2026-10-01T00:00:00Z","pack":{"image":"%s/store/s.sqfs"}}\n' "$F/home" $((1 << 30)) "$d"
  } >"$d/store/catalog.jsonl"
  printf '{"logical_bytes":%s,"image":"%s/packs/unit.sqfs","owner_home":"%s","verified_at":"2026-10-12T00:00:00Z"}\n' $((3 << 30)) "$d" "$h" >"$d/packs/unit.json"
  {
    printf 'original_path\tarchive_path\tsource_allocated_bytes\tpayload_bytes\tfile_count\tsha256_list\tmoved_at_utc\towner_home\tconfirming_corr\tsymlinks_json\tstate\n'
    printf '%s\t%s\t%s\t%s\t5\tx\t2026-10-12T00:00:00+00:00\t%s\tc\t{}\tmoved\n' "$h/data/old" "$d/store/old" 1 $((3 << 30)) "$h"
    printf '%s\t%s\t%s\t%s\t5\tx\t2026-10-12T00:00:00+00:00\t%s\tc\t{}\tcopied-not-removed\n' "$h/data/kept" "$d/store/kept" $((5 << 29)) $((1 << 29)) "$h"
  } >"$d/store/MANIFEST.tsv"
  {
    printf 'original_path\tarchive_path\timage_path\tmember_path\tfile_count\timage_sha256\tunit_sidecar\tverified_at\tsource_checked_at\tearliest_raw_removal_at\tsha256_list\n'
    printf '%s\t%s\t%s\told\t5\tx\t%s\t1\t1\t1\tx\n' "$h/data/old" "$d/store/old" "$d/packs/unit.sqfs" "$d/packs/unit.json"
  } >"$d/store/MANIFEST.packed.tsv"
  {
    printf '| unit | pack path | image sha256 | members | logical bytes | image bytes | verify | verify time UTC | raw allocated (st_blocks) | wall s | fetch MANIFEST |\n|---|---|---|---:|---:|---:|---|---|---:|---:|---|\n'
    printf '| task/fetch-1 | %s/packs/fetch-1.sqfs | x | 10 | %s | 1 | PASS | 2026-10-17T00:00:00Z | %s | 1 | m |\n' "$d" $((4 << 30)) $((8 << 30))
  } >"$F/index.md"
  {
    printf '    10s task/fetch-1: 10 files 9.00 GiB alloc 9.00 GiB\n'
    printf '    20s task/fetch-2: 10 files 1.50 GiB alloc 6.00 GiB\n'
    printf '    30s task/missing: 10 files 7.00 GiB alloc 7.00 GiB\nSTOP file present at 2026-10-17T00:00:00Z\n'
  } >"$F/census.log"
  printf '{"kind":"tj-package","results_path":"%s","recorded_at":"2026-10-15T00:00:00Z","verification":{"bytes":%s}}\n' \
    "$h/data/pkg" $((6 << 30)) >"$F/receipts/one.json"
  printf '{"kind":"tj-package","results_path":"%s","verification":{"bytes":1}}\n' "$d/results/task/fetch-2" >"$F/receipts/dup.json"
  printf '{"kind":"tj-package","results_path":"%s/moved-away","verification":{"bytes":1}}\n' "$d" >"$F/receipts/moved.json"
  python3 - "$F/home/lattice-ledger/catalog.sqlite" <<'PY' || fail "build the ledger catalog fixture"
import sqlite3, sys
db = sqlite3.connect(sys.argv[1])
db.execute("CREATE TABLE runs (entry_id TEXT PRIMARY KEY, started_utc TEXT)")
db.execute("CREATE TABLE kept (entry_id TEXT, step TEXT, files INTEGER, bytes INTEGER)")
db.execute("INSERT INTO runs VALUES ('e1', '2026-09-01T00:00:00Z')")
db.executemany("INSERT INTO kept VALUES (?, ?, 1, ?)", [("e1", "a", 1 << 29), ("e1", "b", 1 << 29), ("e2", "a", 0)])
db.commit()
PY
  printf '%s\n' 'Linux used: 10.0 GiB at x; last day +2.0 GiB over 1.0 days (2.00 GiB/day); last week unknown' \
    '/mnt/c free: 50.0 GiB; used last day unknown, last week unknown' \
    'D: free 100.0 GiB (live), reserved 0.0 GiB, after reservations 100.0 GiB; free last day -10.0 GiB over 1.0 days (-10.00 GiB/day); last week unknown' \
    >"$F/growth.txt"
}

report() {
  HOME="$F/home" FAKE_GROWTH="$F/growth.txt" FAKE_LINUX_FREE=$((20 << 30)) FM_USAGE_DISK_ROOM="$TMP_ROOT/disk-room" \
    FM_USAGE_LATTICE_CONFIG="$F/conf/config.json" FM_USAGE_PACK_INDEX="$F/index.md" FM_USAGE_CENSUS="$F/census.log:$F/absent.log" \
    FM_USAGE_RESULTS_ROOT="$F/d/results" FM_USAGE_RECEIPTS="$F/receipts" FM_USAGE_D_ROOT="$F/d" FM_USAGE_NOW=$NOW "$USAGE" report "$@"
}

test_report_rows_and_runway() {
  local out
  report_fixture
  out=$(report) || fail "report exits 0"
  assert_contains "$out" "D: free 100.00 GiB; last day -10.00 GiB/day full in 10.0 days (2026-10-27); last week unknown" "D: carries days to full from growth"
  assert_contains "$out" "Linux free 20.00 GiB; last day -2.00 GiB/day full in 10.0 days (2026-10-27)" "Linux free falls as Linux used grows"
  assert_contains "$out" "C: free 50.00 GiB; last day unknown; last week unknown" "an unknown window stays unknown"
  python3 - "$(report --json)" <<'PY' || fail "the JSON rows match the fixture records"
import json, sys
rep = json.loads(sys.argv[1])
rows = {(r["tier"], r["owner"], r["kind"], r["age"]): (r["items"], r["logical_bytes"], r["allocated_bytes"]) for r in rep["rows"]}
G = 1 << 30
want = {
    ("D:", "fm-a/1", "ledger-recording", "<1d"): (1, 2 * G, None),
    ("D:", "lattice-data", "tetjet-slice", "7-30d"): (1, G, None),
    ("D:", "fm-a/1", "cold-archive-image", "1-7d"): (1, 3 * G, None),
    ("D:", "fm-a/1", "cold-archive-tree", "1-7d"): (1, G // 2, None),
    ("Linux", "fm-a/1", "cold-archive-source", "1-7d"): (1, G // 2, 5 * G // 2),
    ("D:", "tetjet", "tetjet-pack", "<1d"): (1, 4 * G, None),
    ("D:", "tetjet", "tetjet-fetch", "<1d"): (1, 4 * G, 8 * G),
    ("D:", "tetjet", "tetjet-fetch", "unknown"): (1, int(1.5 * G), 6 * G),
    ("Linux", "fm-a/1", "tj-package", "1-7d"): (1, 6 * G, None),
    ("Linux", "research", "ledger-kept", ">30d"): (1, G, None),
}
assert rows == want, json.dumps(sorted(map(str, rows.items())), indent=1)
d = rep["tiers"]["D:"]
assert d["free_bytes"] == 100 * G and d["day"]["days_to_full"] == 10.0 and d["week"] is None, d
states = {(s["source"], s["state"]) for s in rep["sources"]}
assert ("lattice-data catalog", "absent") in states and ("TETJET pack census", "absent") in states, states
PY
  pass "report rows count each recorded path once, with unknown where a record has no size"
}

test_report_sources_and_misuse() {
  local out rc=0
  out=$(HOME="$TMP_ROOT/empty" FM_USAGE_DISK_ROOM="$TMP_ROOT/absent-disk-room" FM_USAGE_NOW=$NOW "$USAGE" report) || fail "report exits 0 with no sources"
  assert_contains "$out" "TETJET pack index: not configured" "an unset source is named"
  assert_contains "$out" "lattice-data config: unreadable" "an absent config is named"
  assert_contains "$out" "D: free unknown; last day unknown; last week unknown" "no growth report reads unknown"
  "$USAGE" report --bogus >/dev/null 2>&1 || rc=$?
  expect_code 2 "$rc" "an unknown report argument is misuse"
  pass "missing sources are named, never fatal, and misuse exits 2"
}

test_d_line_days_to_full
test_d_line_unknown_and_not_filling
test_d_line_failures
test_report_rows_and_runway
test_report_sources_and_misuse
