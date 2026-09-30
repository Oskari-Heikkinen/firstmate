#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2016
# Behavior tests for the data gate's read log and daily report (docs/data-gate.md).
#
# bin/fm-data-gate.sh passes every read-shaped call to bin/fm-data-gate-reads.mjs,
# which appends rows to reads.jsonl; bin/fm-data-gate-report.sh summarizes one
# day. Every case runs against a fake HOME, so nothing here reads or writes the
# real ~.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-data-gate-reads)
FAKE_HOME="$TMP_ROOT/home"
GATE="$ROOT/bin/fm-data-gate.sh"
REPORT="$ROOT/bin/fm-data-gate-report.sh"
MAIN="$FAKE_HOME/Tools/firstmate"
WT="$TMP_ROOT/pool/1/project"
STATE="$FAKE_HOME/.local/state/lattice-data-gate"
READS="$STATE/reads.jsonl"

build_fixture() {
  mkdir -p "$MAIN/bin" "$MAIN/data/big" "$MAIN/data/other" "$MAIN/state" "$WT"
  : >"$MAIN/AGENTS.md"
  : >"$MAIN/state/wt-task.status"
  seq 1 1000 >"$MAIN/data/big/lines.txt"
  truncate -s 20M "$MAIN/data/big/table.jsonl"
  printf '# summary\n' >"$MAIN/data/big/DIGEST.md"
  git -C "$WT" init -q -b fm/wt-task
  printf 'x\n' >"$WT/notes.md"
}

gate() {  # <args...>: log mode, no inherited task or home attribution
  HOME="$FAKE_HOME" LATTICE_DATA_GATE=log env -u FM_TASK_ID -u FM_HOME "$GATE" "$@"
}

field() {  # <row> <js expression over r>
  node -e 'const r = JSON.parse(process.argv[1]); process.stdout.write(String(eval(process.argv[2])))' "$1" "$2"
}

last_row() {
  tail -n 1 "$READS"
}

rows() {
  if [ -f "$READS" ]; then wc -l <"$READS" | tr -d ' '; else echo 0; fi
}

test_claude_read_tool() {
  local row payload out
  payload=$(node -e 'process.stdout.write(JSON.stringify({session_id:"s1",cwd:process.argv[1],tool_name:"Read",tool_input:{file_path:"data/big/lines.txt",offset:10,limit:100}}))' "$MAIN")
  out=$(printf '%s' "$payload" | gate --harness claude 2>&1)
  expect_code 0 $? "a Read call is allowed"
  assert_equals "" "$out" "a Read call prints nothing"
  row=$(last_row)
  assert_equals "claude|s1|$MAIN|$MAIN/data/big/lines.txt|3893|true|false|100|true" \
    "$(field "$row" '[r.harness, r.session, r.home, r.path, r.size, r.bounded, r.whole_file, r.lines, r.bytes_estimated].join("|")')" \
    "a line-bounded Read records harness, session, home, path, size and bounds"
  assert_equals 389 "$(field "$row" 'r.bytes_requested')" "100 lines become bytes from the file's own bytes per line"
  payload=$(node -e 'process.stdout.write(JSON.stringify({cwd:process.argv[1],tool_name:"Read",tool_input:{file_path:process.argv[1]+"/data/big/table.jsonl"}}))' "$MAIN")
  printf '%s' "$payload" | gate --harness claude
  row=$(last_row)
  assert_equals "20971520|true|false" "$(field "$row" '[r.bytes_requested, r.whole_file, r.size_rule_would_block].join("|")')" \
    "an unbounded Read requests the whole file"
  pass "the Claude Read tool is logged, allowed and silent"
}

test_shell_reads() {  # table: <command> => <tool:path-suffix:bytes_requested,...>
  local before line cmd expected got
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    cmd=${line%% =>*}
    expected=${line#*=>}
    expected=${expected# }
    before=$(rows)
    gate --harness pi --cwd "$MAIN" --command "$cmd" || fail "a read command must be allowed: $cmd"
    got=$(tail -n "+$((before + 1))" "$READS" 2>/dev/null | node -e '
      const lines = require("fs").readFileSync(0, "utf8").split("\n").filter(Boolean).map(JSON.parse);
      process.stdout.write(lines.map((r) => `${r.tool}:${r.path.split("/").slice(-2).join("/")}:${r.bytes_requested}`).join(","));')
    assert_equals "$expected" "$got" "rows for: $cmd"
  done <<'EOF'
cat data/big/lines.txt => cat:big/lines.txt:3893
head -c 100 data/big/table.jsonl => head:big/table.jsonl:100
head -n 5 data/big/lines.txt => head:big/lines.txt:19
tail -3 data/big/lines.txt => tail:big/lines.txt:12
head data/big/lines.txt => head:big/lines.txt:39
cat data/big/lines.txt | head -c 7 => cat:big/lines.txt:7
nice -n 19 ionice -c3 wc -l data/big/lines.txt => wc:big/lines.txt:3893
grep -n foo data/big/lines.txt data/big => grep:big/lines.txt:3893
grep -e foo data/big/lines.txt => grep:big/lines.txt:3893
rg -g '*.txt' foo data/big/lines.txt => rg:big/lines.txt:3893
sed -n '1,5p' data/big/lines.txt => sed:big/lines.txt:3893
awk -F, '{print $1}' data/big/lines.txt => awk:big/lines.txt:3893
jq --arg a b . data/big/DIGEST.md => jq:big/DIGEST.md:10
python3 -c "print(open('data/big/lines.txt').read())" => python3:big/lines.txt:3893
wc -l < data/big/lines.txt => redirect:big/lines.txt:3893
cd data/big && cat DIGEST.md => cat:big/DIGEST.md:10
bash -c 'cat ~/Tools/firstmate/data/big/lines.txt' => cat:big/lines.txt:3893
cat data/big/missing.txt =>
cat data/big =>
cat data/big/*.txt =>
ls data/big =>
echo hello =>
EOF
  pass "shell read commands record each named file with its requested bytes"
}

test_digest_flag_and_attribution() {
  local row
  gate --harness pi --cwd "$WT" --command 'cat notes.md'
  row=$(last_row)
  assert_equals "wt-task|$MAIN|false" "$(field "$row" '[r.task, r.home, r.is_digest].join("|")')" \
    "a worktree read takes its task from the fm/ branch and its home from that task's status file"
  HOME="$FAKE_HOME" FM_TASK_ID=env-task FM_HOME=/somewhere "$GATE" --harness pi --cwd "$WT" --command 'cat notes.md'
  row=$(last_row)
  assert_equals "env-task|/somewhere" "$(field "$row" '[r.task, r.home].join("|")')" "FM_TASK_ID and FM_HOME win"
  gate --harness opencode --cwd "$MAIN" --tool read --path data/big/DIGEST.md --limit 20
  row=$(last_row)
  assert_equals "opencode|true|true" "$(field "$row" '[r.harness, r.is_digest, r.bounded].join("|")')" "a DIGEST.md read through --tool read is flagged"
  pass "digest reads are flagged and reads are attributed to a home and task"
}

test_never_blocks() {
  local before out
  before=$(rows)
  out=$(printf '%s' '{"tool_name":"Read","tool_input":{"file_path":"/"}}' | HOME="$FAKE_HOME" LATTICE_DATA_GATE=enforce "$GATE" --harness claude 2>&1)
  expect_code 0 $? "a Read of a directory is allowed in enforce mode"
  assert_equals "" "$out" "and prints nothing"
  LATTICE_DATA_GATE_READS=off gate --harness pi --cwd "$MAIN" --command 'cat data/big/lines.txt'
  assert_equals "$before" "$(rows)" "LATTICE_DATA_GATE_READS=off logs nothing"
  HOME="$FAKE_HOME" LATTICE_DATA_GATE=enforce "$GATE" --harness pi --cwd "$MAIN" --command 'cat data/big/lines.txt; rg foo' >/dev/null 2>&1
  expect_code 2 $? "a scan in the same command is still refused in enforce mode"
  assert_equals "$((before + 1))" "$(rows)" "and its read is still logged"
  mv "$READS" "$READS.keep"
  mkdir "$READS"
  out=$(gate --harness pi --cwd "$MAIN" --command 'cat data/big/lines.txt' 2>&1)
  expect_code 0 $? "an unwritable read log still allows"
  assert_equals "" "$out" "and prints nothing"
  rmdir "$READS"
  mv "$READS.keep" "$READS"
  pass "the read log never blocks, never prints, and can be turned off"
}

epoch_of() {  # <local date> <HH:MM>
  date -d "$1 $2" +%s
}

iso_of() {  # <local date> <HH:MM>
  date -u -d "$1 $2" +%Y-%m-%dT%H:%M:%SZ
}

test_report() {
  local h="$TMP_ROOT/rhome" day=2026-09-20 state out relay md big="/d/big" small="/d/small"
  state="$h/.local/state/lattice-data-gate"
  mkdir -p "$state" "$h/base"
  row() {  # <time> <session> <path> <size> <bytes> [digest] [whole]
    printf '{"ts":"%s","harness":"claude","session":"%s","task":"t1","cwd":"/d","tool":"Read","path":"%s","size":%s,"bytes_requested":%s,"is_digest":%s,"whole_file":%s,"size_rule_would_block":%s}\n' \
      "$(iso_of "$day" "$1")" "$2" "$3" "$4" "$5" "${6:-false}" "${7:-true}" "$([ "${7:-true}" = true ] && [ "$4" -gt 200000000 ] && echo true || echo false)"
  }
  {
    row 09:00 s1 "$big/DIGEST.md" 100 100 true
    row 09:10 s1 "$big/table.jsonl" 50000000 1000 false false
    row 10:00 s2 "$big/DIGEST.md" 100 100 true
    row 10:05 s2 "$small/other.jsonl" 50000000 50000000
    row 11:00 s3 "$big/DIGEST.md" 100 100 true
    row 11:50 s3 "$big/table.jsonl" 300000000 300000000
    row 12:00 s4 "$big/DIGEST.md" 100 100 true
    row 12:05 s5 "$big/table.jsonl" 50000000 2000 false false
    printf '{"ts":"%s","harness":"pi","session":null,"task":null,"cwd":"/d","tool":"cat","path":"/d/prev.txt","size":9,"bytes_requested":9,"whole_file":true}\n' "$(iso_of 2026-09-19 12:00)"
  } >"$state/reads.jsonl"
  {
    printf '{"ts":"%s","verdict":"block","would_block":true,"mode":"enforce","targets":[]}\n' "$(iso_of "$day" 09:00)"
    printf '{"ts":"%s","verdict":"allow","would_block":true,"mode":"log","targets":[]}\n' "$(iso_of "$day" 09:30)"
    printf '{"ts":"%s","verdict":"allow","would_block":false,"mode":"log","targets":[]}\n' "$(iso_of "$day" 10:00)"
    printf '{"ts":"%s","rule":"size","verdict":"allow","would_block":true,"mode":"log"}\n' "$(iso_of "$day" 10:30)"
    printf '{"ts":"%s","verdict":"allow","would_block":false,"error":"node not found"}\n' "$(iso_of "$day" 11:00)"
    printf '{"ts":"%s","verdict":"block","would_block":true,"mode":"enforce","targets":[]}\n' "$(iso_of 2026-09-21 09:00)"
  } >"$state/decisions.jsonl"
  {
    printf '{"ts":%s,"io_some_avg60":4.0,"io_full_avg60":1.0,"memory_some_avg60":2.0,"memory_full_avg60":0.5,"root_used":1000000000,"mntc_used":5000000000,"disk_read_bytes":100,"disk_write_bytes":1000000000}\n' "$(epoch_of "$day" 00:05)"
    printf '{"ts":%s,"io_some_avg60":8.0,"io_full_avg60":3.0,"memory_some_avg60":4.0,"memory_full_avg60":1.5,"root_used":2500000000,"mntc_used":5000000000,"disk_read_bytes":300,"disk_write_bytes":3000000000}\n' "$(epoch_of "$day" 12:00)"
    printf '{"ts":%s,"io_some_avg60":6.0,"io_full_avg60":2.0,"memory_some_avg60":3.0,"memory_full_avg60":1.0,"root_used":3000000000,"mntc_used":4000000000,"disk_read_bytes":50,"disk_write_bytes":500000000}\n' "$(epoch_of "$day" 23:55)"
  } >"$state/samples.jsonl"
  printf '# Baseline\n\n**Headline: agents requested on average 2.2 GB of file reads per day** (details).\n' >"$h/base/report.md"

  out=$(HOME="$h" "$REPORT" --date "$day" --baseline "$h/base/report.md")
  expect_code 0 $? "the report runs"
  assert_equals 1 "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" "the report prints exactly one relay line"
  relay="Data gate $day: agents read 350 MB in 8 reads (largest 300 MB table.jsonl); scans would-block 2, blocked 1; size would-block 1, blocked 0; >200 MB whole-file reads 1; digests 4 read, hit rate 75%; disk root +2.0 GB, /mnt/c -1.0 GB, written 2.0 GB; IO PSI some 6.0% full 2.0%; baseline 2.2 GB of file reads per day"
  assert_equals "$relay" "$out" "the relay line carries bytes, largest read, blocks, digest hit rate, disk and PSI"
  md="$state/reports/$day.md"
  assert_present "$md" "the report file is written under the gate's state dir"
  assert_grep "| DIGEST.md reads | 4: 3 hit, 1 miss" "$md" "a same-session big read in the digest's folder inside the window is a miss"
  assert_grep "| Gate errors (allowed) | 1 |" "$md" "gate errors are counted"
  assert_grep "| Baseline (before) | agents requested on average 2.2 GB of file reads per day |" "$md" "the baseline headline is included"
  assert_grep "- 300 MB Read /d/big/table.jsonl (claude, t1)" "$md" "the largest reads are listed"
  [ "$(wc -l <"$md")" -le 30 ] || fail "the report fits one screen"
  rm -f "$md"
  out=$(HOME="$h" "$REPORT" --date "$day" --no-write --baseline "$h/none" --digest-window-min 120)
  assert_contains "$out" "digests 4 read, hit rate 50%" "a wider window turns a later big read into a miss"
  assert_not_contains "$out" "baseline" "an absent baseline is left out"
  assert_absent "$md" "--no-write writes no report file"
  out=$(HOME="$TMP_ROOT/empty" "$REPORT" --date "$day" --no-write)
  assert_equals "Data gate $day: agents read 0 B in 0 reads (none); scans would-block 0, blocked 0; size would-block 0, blocked 0; >200 MB whole-file reads 0; digests 0 read, hit rate n/a; no disk/PSI samples" \
    "$out" "missing inputs report as empty"
  HOME="$h" "$REPORT" --date 20-09-2026 >/dev/null 2>&1
  expect_code 1 $? "a malformed date is refused"
  pass "the daily report summarizes reads, decisions, digests, disk and PSI for one local day"
}

build_fixture
test_claude_read_tool
test_shell_reads
test_digest_flag_and_attribution
test_never_blocks
test_report
