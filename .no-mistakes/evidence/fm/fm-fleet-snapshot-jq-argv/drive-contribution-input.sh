#!/usr/bin/env bash
# usage: drive.sh <bindir> <home> <bulk-count>
set -u
BIN=$1 H=$2 N=$3
rm -rf "$H"; mkdir -p "$H/data" "$H/state" "$H/config" "$H/projects" "$H/fakebin"
printf '#!/bin/sh\nexit 1\n' > "$H/fakebin/tmux"; printf '#!/bin/sh\nexit 0\n' > "$H/fakebin/no-mistakes"; chmod +x "$H/fakebin/"*
{ printf '# Backlog\n\n## Queued\n'
  printf -- '- [ ] delivery - Contribution delivery https://github.com/o/r/pull/9 (repo: sample) (kind: ship)\n'
  awk -v n="$N" 'BEGIN { for (i = 1; i <= n; i++) printf "- [ ] bulk-%04d - Bulk item %04d with a title long enough to grow the backlog past one argument (repo: sample) (kind: ship)\n", i, i }'
} > "$H/data/backlog.md"
mkdir -p "$H/data/delivery"
PATH="$H/fakebin:$PATH" FM_HOME="$H" FM_ROOT_OVERRIDE="$H/root" FM_STATE_OVERRIDE="$H/state" \
  FM_DATA_OVERRIDE="$H/data" FM_CONFIG_OVERRIDE="$H/config" "$BIN/fm-fleet-snapshot.sh" --contribution-input > "$H/out.json" 2> "$H/err.txt"
echo "exit=$?"
