#!/usr/bin/env bash
# Live driver: runs the real data gate hooks against a throwaway HOME and prints the read log rows.
set -u
REPO=/home/oskari/.no-mistakes/worktrees/ca1b14ddd4b9/01M3SJFHJB9C8T2AXATYWSMJDA
T=$(mktemp -d /tmp/fm-dg-live.XXXX); H=$T/home; MAIN=$H/Tools/firstmate; ST=$H/.local/state/lattice-data-gate
mkdir -p "$MAIN/bin" "$MAIN/data/big" "$MAIN/data/small" "$MAIN/state" "$H/real"
: >"$MAIN/AGENTS.md"
seq 1 1000 >"$MAIN/data/big/lines.txt"
truncate -s 20M "$MAIN/data/big/table.jsonl"
truncate -s 300M "$MAIN/data/big/huge.csv"
truncate -s 300M "$H/real/huge.csv"; ln -s real "$H/link"
printf '# summary\n' >"$MAIN/data/big/DIGEST.md"
printf '# summary\n' >"$MAIN/data/small/DIGEST.md"
WT=$T/pool/1/project; mkdir -p "$WT"; git -C "$WT" init -q -b fm/demo-task; seq 1 50 >"$WT/notes.md"
GATE=$REPO/bin/fm-data-gate.sh
g() { HOME="$H" env -u FM_TASK_ID -u FM_HOME "$@"; }
show() { tail -n1 "$ST/reads-$(date +%F).jsonl" | node -e 'const r=JSON.parse(require("fs").readFileSync(0));console.log(JSON.stringify({tool:r.tool,path:r.path.replace(process.argv[1],"~"),size:r.size,bounded:r.bounded,bytes_requested:r.bytes_requested,bytes_returned_est:r.bytes_returned_est,whole_file:r.whole_file,size_rule_would_block:r.size_rule_would_block,is_digest:r.is_digest,harness:r.harness,task:r.task,home:r.home&&r.home.replace(process.argv[1],"~"),session:r.session}))' "$H"; }
run() { echo; echo "\$ $*"; out=$("$@" 2>&1); echo "exit=$? output=[${out:0:200}]"; }
count() { cat "$ST"/reads-*.jsonl 2>/dev/null | wc -l; }

echo "== S1 Claude Read tool hook (stdin PreToolUse JSON), log mode =="
P=$(node -e 'console.log(JSON.stringify({session_id:"sess-A",cwd:process.argv[1],tool_name:"Read",tool_input:{file_path:"data/big/lines.txt",offset:10,limit:100}}))' "$MAIN")
run g LATTICE_DATA_GATE=log LATTICE_DATA_GATE_SIZE=log bash -c 'printf %s "$0" | "$1" --harness claude' "$P" "$GATE"; show
P=$(node -e 'console.log(JSON.stringify({session_id:"sess-A",cwd:process.argv[1],tool_name:"Read",tool_input:{file_path:"data/big/table.jsonl"}}))' "$MAIN")
run g LATTICE_DATA_GATE=log LATTICE_DATA_GATE_SIZE=log bash -c 'printf %s "$0" | "$1" --harness claude' "$P" "$GATE"; show

echo; echo "== S2 size rule enforce: unbounded Read of 300 MB is refused AND logged with would_block=true =="
P=$(node -e 'console.log(JSON.stringify({session_id:"sess-B",cwd:process.argv[1],tool_name:"Read",tool_input:{file_path:"data/big/huge.csv"}}))' "$MAIN")
run g LATTICE_DATA_GATE=log LATTICE_DATA_GATE_SIZE=enforce bash -c 'printf %s "$0" | "$1" --harness claude' "$P" "$GATE"; show

echo; echo "== S3 shell reads via pi/opencode --command, log mode =="
for c in 'cat data/big/lines.txt' 'head -n 5 data/big/huge.csv' 'tail -n +2 data/big/huge.csv' 'head -c 1000 data/big/huge.csv' 'grep foo data/big/table.jsonl | head -n 20' 'sort data/big/table.jsonl | head -n 3' 'head -n 5 < data/big/huge.csv' 'grep x data/big/lines.txt 3< data/big/huge.csv | head -n 2' "python3 -c \"open('data/big/huge.csv').read()\"" 'cat link/huge.csv'; do
  cwd=$MAIN; [ "$c" = 'cat link/huge.csv' ] && cwd=$H
  before=$(count)
  run g LATTICE_DATA_GATE=log LATTICE_DATA_GATE_SIZE=log "$GATE" --harness pi --cwd "$cwd" --command "$c"
  after=$(count); echo "rows added: $((after-before))"
  cat "$ST/reads-$(date +%F).jsonl" | tail -n $((after-before)) | node -e 'for (const l of require("fs").readFileSync(0,"utf8").trim().split("\n")){const r=JSON.parse(l);console.log("  ",JSON.stringify({path:r.path.split("/").slice(-2).join("/"),size:r.size,bounded:r.bounded,bytes_requested:r.bytes_requested,whole_file:r.whole_file,size_rule_would_block:r.size_rule_would_block}))}'
done

echo; echo "== S4 task attribution from fm/<id> worktree branch (opencode) =="
run g LATTICE_DATA_GATE=log "$GATE" --harness opencode --cwd "$WT" --command 'cat notes.md'; show

echo; echo "== S5 Codex shell payload on stdin =="
P=$(node -e 'console.log(JSON.stringify({session_id:"sess-C",cwd:process.argv[1],tool_name:"Bash",tool_input:{command:"wc -l data/big/lines.txt"}}))' "$MAIN")
run g LATTICE_DATA_GATE=log bash -c 'printf %s "$0" | "$1" --harness codex' "$P" "$GATE"; show

echo; echo "== S6 digest hit then miss (Claude, session sess-D reads digest then the 300 MB file; sess-E only the small digest) =="
for spec in "sess-D data/big/DIGEST.md" "sess-D data/big/huge.csv 100" "sess-E data/small/DIGEST.md"; do
  set -- $spec
  P=$(node -e 'const i={file_path:process.argv[3]}; if(process.argv[4]) i.limit=+process.argv[4]; console.log(JSON.stringify({session_id:process.argv[2],cwd:process.argv[1],tool_name:"Read",tool_input:i}))' "$MAIN" "$1" "$2" "${3:-}")
  g LATTICE_DATA_GATE=log LATTICE_DATA_GATE_SIZE=log bash -c 'printf %s "$0" | "$1" --harness claude' "$P" "$GATE"; show
done

echo; echo "== S7 guard: LATTICE_DATA_GATE_READS=off records nothing; non-read command records nothing =="
before=$(count); g LATTICE_DATA_GATE=log LATTICE_DATA_GATE_READS=off "$GATE" --harness pi --cwd "$MAIN" --command 'cat data/big/lines.txt'
g LATTICE_DATA_GATE=log "$GATE" --harness pi --cwd "$MAIN" --command 'echo hello > /dev/null'
g LATTICE_DATA_GATE=log "$GATE" --harness pi --cwd "$MAIN" --command 'cat data/big/missing.txt data/big'
echo "rows added: $(( $(count) - before ))"

echo; echo "== S8 guard: read log cannot block — unwritable state dir still allows silently =="
chmod 500 "$ST"; run g LATTICE_DATA_GATE=log LATTICE_DATA_GATE_SIZE=log "$GATE" --harness pi --cwd "$MAIN" --command 'cat data/big/lines.txt'; chmod 700 "$ST"
s=$(date +%s%N); g LATTICE_DATA_GATE=log "$GATE" --harness pi --cwd "$MAIN" --command 'cat data/big/lines.txt'; echo "hook latency ms: $(( ($(date +%s%N)-s)/1000000 ))"

echo; echo "== S9 daily report =="
TODAY=$(date +%F)
# fm-io-sample shaped samples and an old read log to prune
now=$(date +%s)
for i in 0 1 2; do node -e 'const [t,i]=process.argv.slice(1).map(Number);console.log(JSON.stringify({ts:new Date((t-3600*(3-i))*1000).toISOString(),io_some_avg60:1+i,io_full_avg60:0.5,memory_some_avg60:0.2,memory_full_avg60:0.1,root_used:1e9+i*5e8,mntc_used:2e9+i*1e8,disk_read_bytes:1e6*(i+1),disk_write_bytes:5e7*(i+1)}))' "$now" "$i" >>"$ST/samples.jsonl"; done
: >"$ST/reads-2020-01-01.jsonl"; : >"$ST/reads-$(date -d '-10 days' +%F).jsonl"
mkdir -p "$MAIN/data/fm-read-baseline"; printf '# Baseline\n\n**Headline: agents requested on average 1.2 GB per day.**\n' >"$MAIN/data/fm-read-baseline/report.md"
echo "\$ fm-data-gate-report.sh --date $TODAY"
HOME="$H" env -u FM_HOME "$REPO/bin/fm-data-gate-report.sh" --date "$TODAY"; echo "exit=$?"
echo "--- $ST/reports/$TODAY.md:"; sed "s#$H#~#g" "$ST/reports/$TODAY.md"
echo "--- read logs after prune:"; ls "$ST" | grep '^reads-'
echo "\$ fm-data-gate-report.sh --today (removed flag)"; HOME="$H" "$REPO/bin/fm-data-gate-report.sh" --today; echo "exit=$?"
echo "\$ fm-data-gate-report.sh --date 2026-13"; HOME="$H" "$REPO/bin/fm-data-gate-report.sh" --date 2026-13; echo "exit=$?"
echo "\$ fm-data-gate-report.sh (default yesterday, no reads)"; HOME="$H" env -u FM_HOME "$REPO/bin/fm-data-gate-report.sh"; echo "exit=$?"; ls "$ST/reports"
cp "$ST/reports/$TODAY.md" "${EVID:-/tmp}/report-$TODAY.md" 2>/dev/null; sed -i "s#$H#~#g" "${EVID:-/tmp}/report-$TODAY.md" 2>/dev/null
rm -rf "$T"
