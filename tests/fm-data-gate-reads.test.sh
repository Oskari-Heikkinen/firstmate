#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2016
# Behavior tests for the data gate's read log and daily report (docs/data-gate.md).
#
# bin/fm-data-gate.sh passes every read-shaped call to bin/fm-data-gate-reads.mjs,
# which appends rows to reads-<date>.jsonl; bin/fm-data-gate-report.sh summarizes one
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

build_fixture() {
  mkdir -p "$MAIN/bin" "$MAIN/data/big" "$MAIN/data/other" "$MAIN/state" "$WT"
  : >"$MAIN/AGENTS.md"
  : >"$MAIN/state/wt-task.status"
  seq 1 1000 >"$MAIN/data/big/lines.txt"
  truncate -s 20M "$MAIN/data/big/table.jsonl"
  truncate -s 300M "$MAIN/data/big/huge.csv"
  printf '# summary\n' >"$MAIN/data/big/DIGEST.md"
  git -C "$WT" init -q -b fm/wt-task
  printf 'x\n' >"$WT/notes.md"
}

gate() {  # <args...>: both rules in log mode, no inherited task or home attribution
  HOME="$FAKE_HOME" LATTICE_DATA_GATE=log LATTICE_DATA_GATE_SIZE=log env -u FM_TASK_ID -u FM_HOME "$GATE" "$@"
}

field() {  # <row> <js expression over r>
  node -e 'const r = JSON.parse(process.argv[1]); process.stdout.write(String(eval(process.argv[2])))' "$1" "$2"
}

all_rows() {  # every read log, oldest day first
  cat "$STATE"/reads-*.jsonl 2>/dev/null
}

last_row() {
  all_rows | tail -n 1
}

rows() {
  all_rows | wc -l | tr -d ' '
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
  assert_equals "20971520|0|true|false" "$(field "$row" '[r.bytes_requested, r.bytes_returned_est, r.whole_file, r.size_rule_would_block].join("|")')" \
    "an unbounded Read requests the whole file, and Claude returns nothing above 256 KB"
  assert_present "$STATE/reads-$(date +%F).jsonl" "reads go to the day's read log"
  pass "the Claude Read tool is logged, allowed and silent"
}

test_returned_bytes_and_size_rule() {  # table: <harness> <path> [limit] => <requested>|<returned>|<size rule would block>
  local line harness path limit expected
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    expected=${line#*=> }
    read -r harness path limit <<<"${line%% =>*}"
    gate --harness "$harness" --cwd "$MAIN" --tool read --path "$path" ${limit:+--limit "$limit"}
    assert_equals "$expected" "$(field "$(last_row)" '[r.bytes_requested, r.bytes_returned_est, r.size_rule_would_block].join("|")')" \
      "$harness Read of $path${limit:+ limit $limit}"
  done <<'EOF'
claude data/big/lines.txt => 3893|3893|false
claude data/big/huge.csv => 314572800|0|true
claude data/big/huge.csv 1 => 65536|65536|false
pi data/big/lines.txt => 3893|3893|false
pi data/big/table.jsonl => 20971520|51200|false
opencode data/big/huge.csv => 314572800|131072000|true
EOF
  gate --harness pi --cwd "$MAIN" --command 'tail -n +2 data/big/huge.csv'
  assert_equals "314572800|true|false" "$(field "$(last_row)" '[r.bytes_requested, r.whole_file, r.size_rule_would_block].join("|")')" \
    "a tail to the end of a file over the limit is a whole-file read the size rule does not refuse"
  gate --harness pi --cwd "$MAIN" --command 'cat data/big/huge.csv'
  assert_equals "314572800|true|true" "$(field "$(last_row)" '[r.bytes_requested, r.whole_file, r.size_rule_would_block].join("|")')" \
    "a cat of a file over the limit is one the size rule refuses"
  gate --harness pi --cwd "$MAIN" --command 'nice -n 19 ionice -c3 cat data/big/huge.csv'
  assert_equals "true|false" "$(field "$(last_row)" '[r.whole_file, r.size_rule_would_block].join("|")')" \
    "a niced whole-file read is one the size rule lets through"
  LATTICE_DATA_GATE_SIZE_LIMIT=400M gate --harness pi --cwd "$MAIN" --command 'cat data/big/huge.csv'
  assert_equals false "$(field "$(last_row)" 'r.size_rule_would_block')" "the configured size limit is the rule's"
  pass "Read rows estimate the harness-capped bytes returned and carry the size rule's decision"
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
    got=$(all_rows | tail -n "+$((before + 1))" | node -e '
      const lines = require("fs").readFileSync(0, "utf8").split("\n").filter(Boolean).map(JSON.parse);
      process.stdout.write(lines.map((r) => `${r.tool}:${r.path.split("/").slice(-2).join("/")}:${r.bytes_requested}`).join(","));')
    assert_equals "$expected" "$got" "rows for: $cmd"
  done <<'EOF'
cat data/big/lines.txt => cat:big/lines.txt:3893
head -c 100 data/big/table.jsonl => head:big/table.jsonl:100
head -n 5 data/big/lines.txt => head:big/lines.txt:19
tail -3 data/big/lines.txt => tail:big/lines.txt:12
tail -n -3 data/big/lines.txt => tail:big/lines.txt:12
tail -n +2 data/big/lines.txt => tail:big/lines.txt:3893
tail -c +5 data/big/lines.txt => tail:big/lines.txt:3893
head -n -5 data/big/lines.txt => head:big/lines.txt:3893
head --lines=-5 data/big/lines.txt => head:big/lines.txt:3893
head data/big/lines.txt => head:big/lines.txt:39
cat data/big/lines.txt | head -c 7 => cat:big/lines.txt:7
grep foo data/big/lines.txt | head -n 5 => grep:big/lines.txt:19
cat data/big/lines.txt | head -n -5 => cat:big/lines.txt:3893
sort -u data/big/lines.txt | head => sort:big/lines.txt:3893
wc -l data/big/lines.txt | head -1 => wc:big/lines.txt:3893
sha256sum data/big/lines.txt | head -c 64 => sha256sum:big/lines.txt:3893
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
  local before out today
  before=$(rows)
  out=$(printf '%s' '{"tool_name":"Read","tool_input":{"file_path":"/"}}' | HOME="$FAKE_HOME" LATTICE_DATA_GATE=enforce "$GATE" --harness claude 2>&1)
  expect_code 0 $? "a Read of a directory is allowed in enforce mode"
  assert_equals "" "$out" "and prints nothing"
  LATTICE_DATA_GATE_READS=off gate --harness pi --cwd "$MAIN" --command 'cat data/big/lines.txt'
  assert_equals "$before" "$(rows)" "LATTICE_DATA_GATE_READS=off logs nothing"
  HOME="$FAKE_HOME" LATTICE_DATA_GATE=enforce "$GATE" --harness pi --cwd "$MAIN" --command 'cat data/big/lines.txt; rg foo' >/dev/null 2>&1
  expect_code 2 $? "a scan in the same command is still refused in enforce mode"
  assert_equals "$((before + 1))" "$(rows)" "and its read is still logged"
  today="$STATE/reads-$(date +%F).jsonl"
  mv "$today" "$today.keep"
  mkdir "$today"
  out=$(gate --harness pi --cwd "$MAIN" --command 'cat data/big/lines.txt' 2>&1)
  expect_code 0 $? "an unwritable read log still allows"
  assert_equals "" "$out" "and prints nothing"
  rmdir "$today"
  mv "$today.keep" "$today"
  pass "the read log never blocks, never prints, and can be turned off"
}

epoch_of() {  # <local date> <HH:MM>
  date -d "$1 $2" +%s
}

iso_of() {  # <local date> <HH:MM>
  date -u -d "@$(epoch_of "$1" "$2")" +%Y-%m-%dT%H:%M:%SZ
}

test_report() {
  local h="$TMP_ROOT/rhome" day prev next state out relay md big="/d/big" small="/d/small" old kept
  day=$(date -d '-3 days' +%F)
  prev=$(date -d "$day -1 day" +%F)
  next=$(date -d "$day +1 day" +%F)
  old=$(date -d '-61 days' +%F)
  kept=$(date -d '-59 days' +%F)
  state="$h/.local/state/lattice-data-gate"
  mkdir -p "$state" "$h/base"
  row() {  # <date> <time> <session> <path> <size> <bytes> [digest] [whole] [returned]
    printf '{"ts":"%s","harness":"claude","session":"%s","task":"t1","cwd":"/d","tool":"Read","path":"%s","size":%s,"bytes_requested":%s,"bytes_returned_est":%s,"is_digest":%s,"whole_file":%s,"size_rule_would_block":%s}\n' \
      "$(iso_of "$1" "$2")" "$3" "$4" "$5" "$6" "${9:-$6}" "${7:-false}" "${8:-true}" "$([ "${8:-true}" = true ] && [ "$5" -gt 200000000 ] && echo true || echo false)"
  }
  {
    row "$day" 09:00 s1 "$big/DIGEST.md" 100 100 true
    row "$day" 09:10 s1 "$big/table.jsonl" 50000000 1000 false false
    row "$day" 10:00 s2 "$big/DIGEST.md" 100 100 true
    row "$day" 10:05 s2 "$small/other.jsonl" 50000000 50000000
    row "$day" 11:00 s3 "$big/DIGEST.md" 100 100 true
    row "$day" 11:50 s3 "$big/table.jsonl" 300000000 300000000 false true 0
    row "$day" 12:00 s4 "$big/DIGEST.md" 100 100 true
    row "$day" 12:05 s5 "$big/table.jsonl" 50000000 2000 false false
    row "$day" 23:50 s6 "$big/DIGEST.md" 100 100 true
  } >"$state/reads-$day.jsonl"
  {
    row "$next" 00:10 s6 "$big/table.jsonl" 50000000 50000000
    row "$next" 09:00 s7 "$big/table.jsonl" 50000000 50000000
  } >"$state/reads-$next.jsonl"
  printf '{"ts":"%s","harness":"pi","session":null,"task":null,"cwd":"/d","tool":"cat","path":"/d/prev.txt","size":9,"bytes_requested":9,"whole_file":true}\n' "$(iso_of "$prev" 12:00)" \
    >"$state/reads-$prev.jsonl"
  : >"$state/reads-$old.jsonl"
  : >"$state/reads-$kept.jsonl"
  {
    printf '{"ts":"%s","verdict":"block","would_block":true,"mode":"enforce","targets":[]}\n' "$(iso_of "$day" 09:00)"
    printf '{"ts":"%s","verdict":"allow","would_block":true,"mode":"log","targets":[]}\n' "$(iso_of "$day" 09:30)"
    printf '{"ts":"%s","verdict":"allow","would_block":false,"mode":"log","targets":[]}\n' "$(iso_of "$day" 10:00)"
    printf '{"ts":"%s","verdict":"allow","would_block":true,"would_block_rules":["size"],"mode":"enforce","size_mode":"log","targets":[{"rule":"size","size":314572800,"verdict":"block"}]}\n' "$(iso_of "$day" 10:30)"
    printf '{"ts":"%s","verdict":"block","would_block":true,"would_block_rules":["size"],"mode":"log","size_mode":"enforce","targets":[{"rule":"size","size":314572800,"verdict":"block"}]}\n' "$(iso_of "$day" 10:45)"
    printf '{"ts":"%s","verdict":"allow","would_block":false,"error":"node not found"}\n' "$(iso_of "$day" 11:00)"
    printf '{"ts":"%s","verdict":"block","would_block":true,"mode":"enforce","targets":[]}\n' "$(iso_of "$next" 09:00)"
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
  relay="Data gate $day: agents read 350 MB in 9 reads (est. returned 50.0 MB; largest 300 MB table.jsonl); scans would-block 2, blocked 1; size would-block 2, blocked 1; >200 MB whole-file reads 1; digests 5 read, hit rate 60%; disk root +2.0 GB, /mnt/c -1.0 GB, written 2.0 GB; IO PSI some 6.0% full 2.0%; baseline 2.2 GB of file reads per day"
  assert_equals "$relay" "$out" "the relay line carries bytes requested and returned, largest read, blocks, digest hit rate, disk and PSI"
  md="$state/reports/$day.md"
  assert_present "$md" "the report file is written under the gate's state dir"
  assert_grep "| DIGEST.md reads | 5: 3 hit, 2 miss" "$md" "a same-session big read in the digest's folder inside the window, even past midnight, is a miss"
  assert_grep "| Bytes returned (est., harness Read caps) | 50.0 MB |" "$md" "the harness-capped estimate is shown beside bytes requested"
  assert_grep "| Gate errors (allowed) | 1 |" "$md" "gate errors are counted"
  assert_grep "| Baseline (before) | agents requested on average 2.2 GB of file reads per day |" "$md" "the baseline headline is included"
  assert_grep "- 300 MB Read /d/big/table.jsonl (claude, t1)" "$md" "the largest reads are listed"
  [ "$(wc -l <"$md")" -le 30 ] || fail "the report fits one screen"
  assert_absent "$state/reads-$old.jsonl" "a read log older than 60 days is deleted"
  assert_present "$state/reads-$kept.jsonl" "a read log inside 60 days is kept"
  out=$(HOME="$h" LATTICE_DATA_GATE_READS_KEEP_DAYS=30 "$REPORT" --date "$day" --baseline "$h/none")
  assert_not_contains "$out" "baseline" "an absent baseline is left out"
  assert_absent "$state/reads-$kept.jsonl" "LATTICE_DATA_GATE_READS_KEEP_DAYS shortens the retention"
  assert_present "$state/reads-$day.jsonl" "the reported day's log is kept"
  out=$(HOME="$TMP_ROOT/empty" "$REPORT" --date "$day")
  assert_equals "Data gate $day: agents read 0 B in 0 reads (est. returned 0 B; none); scans would-block 0, blocked 0; size would-block 0, blocked 0; >200 MB whole-file reads 0; digests 0 read, hit rate n/a; no disk/PSI samples" \
    "$out" "missing inputs report as empty"
  HOME="$h" "$REPORT" --date 20-09-2026 >/dev/null 2>&1
  expect_code 1 $? "a malformed date is refused"
  for flag in --today --no-write --digest-window-min; do
    HOME="$h" "$REPORT" "$flag" >/dev/null 2>&1
    expect_code 1 $? "$flag is not an option"
  done
  pass "the daily report summarizes reads, decisions, digests, disk and PSI for one local day"
}

build_fixture
test_claude_read_tool
test_returned_bytes_and_size_rule
test_shell_reads
test_digest_flag_and_attribution
test_never_blocks
test_report
