#!/usr/bin/env bash
# Builds a throwaway fake HOME for live data-gate validation.
set -eu
F=$1
rm -rf "$F"; mkdir -p "$F"
M="$F/Tools/firstmate"
mkdir -p "$M/bin" "$M/config" "$M/data/task1" "$M/data/rolling-runs-v11/slices/s1" "$M/data/exp2/tetjet-results/t1" \
  "$M/data/tetjet-offload/results/r1" "$F/.claude" "$F/.claude-work" "$F/.claude-acct" "$F/.codex" "$F/.grok" \
  "$F/.config/opencode" "$F/.pi/agent" "$F/.omp/agent" "$F/lattice-store/items/tetjet-slice/s1" \
  "$F/lattice-ledger/runs" "$F/lattice-ledger/search-recording/r1" "$F/lattice-ledger/diagnostics" "$F/.cache/pip" "$F/off/tr"
: > "$M/AGENTS.md"
printf 'report foo\n' > "$M/data/task1/report.md"
printf '{}\n' > "$M/data/tetjet-offload/results/r1/receipt.json"
printf 'foo slice\n' > "$M/data/rolling-runs-v11/slices/s1/x.txt"
printf 'foo\n' > "$F/lattice-store/items/tetjet-slice/s1/a.json"
: > "$F/lattice-store/catalog.jsonl"; : > "$F/lattice-ledger/index.json"; : > "$F/lattice-ledger/runs/E1.md"
printf 'acct claude ~/.claude-acct 1\n' > "$M/config/accounts"
printf '{\n  "theme": "dark",\n  "hooks": {"SessionStart": [{"matcher": "", "hooks": [{"type": "command", "command": "gh-axi"}]}]}\n}\n' > "$F/.claude/settings.json"
printf 'model = "x"\n' > "$F/.codex/config.toml"
# >256 task folders plus a symlinked bulk dir created after install
for i in $(seq 1 300); do mkdir -p "$M/data/many$i"; done
