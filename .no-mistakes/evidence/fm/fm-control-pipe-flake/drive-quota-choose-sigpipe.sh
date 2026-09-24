#!/usr/bin/env bash
# Drives the real bin/fm-quota-choose.sh CLI (the failing CI case: "trailing empty
# model returned") with SIGPIPE ignored, as on GitHub Actions runners, and counts
# runs whose output differs from the single expected error line.
# usage: drive-quota-choose-sigpipe.sh <bin-dir> <snapshot> <iterations-per-worker> <workers>
set -u
BIN=$1 SNAP=$2 N=$3 W=$4
trap '' PIPE
worker() {
  local i out bad=0
  for ((i = 0; i < N; i++)); do
    out=$("$BIN/fm-quota-choose.sh" --snapshot "$SNAP" --candidate claude:default --candidate 'claude:' 2>&1)
    if [ "$out" != "error: invalid candidate: claude:" ]; then
      bad=$((bad + 1)); printf 'UNEXPECTED: %s\n' "$out" | head -3 >&2
    fi
  done
  echo "$bad"
}
tot=0
for ((w = 0; w < W; w++)); do worker > "/tmp/fm-drive.$$.$w" & done
wait
for ((w = 0; w < W; w++)); do tot=$((tot + $(cat "/tmp/fm-drive.$$.$w"))); rm -f "/tmp/fm-drive.$$.$w"; done
echo "bin=$BIN runs=$((N * W)) unexpected_output_runs=$tot"
