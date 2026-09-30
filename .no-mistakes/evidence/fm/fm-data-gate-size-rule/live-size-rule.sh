#!/usr/bin/env bash
# Live drive of bin/fm-data-gate.sh as a harness hook against a throwaway HOME.
set -u
GATE=${GATE:?}
T=$(mktemp -d /tmp/fm-gate-live.XXXXXX); export HOME=$T/home; mkdir -p $HOME/data
truncate -s 300M $HOME/data/big.jsonl; printf 'x\n' >$HOME/data/small.jsonl
CONF=$HOME/.config/lattice-data-gate/mode; LOG=$HOME/.local/state/lattice-data-gate/decisions.jsonl
mkdir -p $(dirname $CONF)
run() { # label, then args; stdin passthrough
  local label=$1; shift
  echo "\$ $label"; out=$("$GATE" "$@" 2>&1); code=$?; echo "exit=$code"; [ -n "$out" ] && printf '%s\n' "$out" | sed 's/^/  | /'; echo
}
claude_read() { printf '{"session_id":"s","cwd":"%s","tool_name":"Read","tool_input":%s}' "$HOME" "$1"; }
claude_bash() { node -e 'process.stdout.write(JSON.stringify({session_id:"s",cwd:process.argv[1],tool_name:"Bash",tool_input:{command:process.argv[2]}}))' "$HOME" "$1"; }
echo "== default: no mode file (size rule enforce by default, scan log) =="
echo "mode scan=$("$GATE" mode) size=$("$GATE" mode size) limit=$("$GATE" size-limit)"; echo
echo "== Claude Read hook payloads =="
claude_read "{\"file_path\":\"$HOME/data/big.jsonl\"}" | run "Claude Read big.jsonl (300 MiB, no offset/limit)" --harness claude
claude_read "{\"file_path\":\"$HOME/data/big.jsonl\",\"offset\":1,\"limit\":200}" | run "Claude Read big.jsonl offset=1 limit=200" --harness claude
claude_read "{\"file_path\":\"$HOME/data/small.jsonl\"}" | run "Claude Read small.jsonl" --harness claude
echo "== Claude Bash hook payloads =="
for c in "cat ~/data/big.jsonl" "jq length ~/data/big.jsonl" "python3 -c \"import json; json.load(open('$HOME/data/big.jsonl'))\"" \
  "head -c 1048576 ~/data/big.jsonl | wc -l" "tail -n 50 ~/data/big.jsonl" "sed -n '1,20p;20q' ~/data/big.jsonl" \
  "wc -c ~/data/big.jsonl" "dd if=~/data/big.jsonl bs=1M skip=2 count=1 status=none | xxd | head" \
  "zcat ~/data/big.jsonl | head -100" "nice -n 19 ionice -c3 sha256sum ~/data/big.jsonl" "sha256sum ~/data/big.jsonl" \
  "python3 -c \"from pathlib import Path; print(Path('$HOME/data/big.jsonl').stat().st_size)\"" \
  "D=~/data; grep -c foo \$D/big.jsonl" "grep -c foo \$SOMEVAR/big.jsonl" "cat ~/data/small.jsonl"; do
  claude_bash "$c" | run "Claude Bash: $c" --harness claude
done
echo "== Codex/Pi/OpenCode transports =="
printf '{"cwd":"%s","tool_name":"Bash","tool_input":{"command":"cat %s"}}' "$HOME" "$HOME/data/big.jsonl" | run "codex stdin: cat big" --harness codex
run "pi --tool read big" --harness pi --cwd "$HOME" --tool read --path "$HOME/data/big.jsonl"
run "opencode --command 'awk 1 big'" --harness opencode --cwd "$HOME" --command "awk 1 $HOME/data/big.jsonl"
echo "== 48h log-only window: mode file 'enforce' + 'size log' (last line without newline) =="
printf 'enforce\nsize log' >$CONF; rm -f $LOG
echo "mode scan=$("$GATE" mode) size=$("$GATE" mode size)"
claude_bash "cat ~/data/big.jsonl" | run "Claude Bash: cat big (size log)" --harness claude
claude_bash "rg -n foo ~" | run "Claude Bash: rg -n foo ~ (scan enforce)" --harness claude
echo "would-block log lines:"; cat $LOG | node -e 'for (const l of require("fs").readFileSync(0,"utf8").split("\n").filter(Boolean)) { const r=JSON.parse(l); console.log("  ", JSON.stringify({verdict:r.verdict,would_block:r.would_block,rules:r.would_block_rules,mode:r.mode,size_mode:r.size_mode,cmd:r.cmd,targets:(r.targets||[]).map(t=>({rule:t.rule,tool:t.tool,size:t.size,verdict:t.verdict}))})) }'
echo
echo "== configurable limit: size-limit 1G =="
printf 'enforce\nsize enforce\nsize-limit 1G\n' >$CONF
echo "limit=$("$GATE" size-limit)"
claude_bash "cat ~/data/big.jsonl" | run "Claude Bash: cat big (300 MiB < 1G)" --harness claude
LATTICE_DATA_GATE_SIZE_LIMIT=100M bash -c "$(declare -f claude_bash); claude_bash 'cat ~/data/big.jsonl'" | LATTICE_DATA_GATE_SIZE_LIMIT=100M run "env LATTICE_DATA_GATE_SIZE_LIMIT=100M: cat big" --harness claude
rm -rf "$T"
