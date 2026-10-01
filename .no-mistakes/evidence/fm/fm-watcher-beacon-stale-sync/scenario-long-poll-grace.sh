#!/usr/bin/env bash
# Live scenario: a long-poll home (FM_POLL=600, no FM_GUARD_GRACE) whose healthy
# watcher sits in its terminal wait with a 400s-old beacon - legitimately inside
# its own poll-derived grace max(300, 600+60)=660s. A re-arm (what the Stop hook
# runs) must attach, not refuse against the historical fixed 300s.
# usage: scenario-long-poll-grace.sh <code-root> <lab-home>
set -u
CODE=$1 HOME_DIR=$2
export FM_HOME=$HOME_DIR; STATE=$HOME_DIR/state
unset FM_GUARD_GRACE FM_WATCHER_STALE_GRACE
export FM_POLL=600 FM_HEARTBEAT=999999 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_ARM_CONFIRM_TIMEOUT=6
echo "code: $(cat "$CODE/.commit" 2>/dev/null || git -C "$CODE" rev-parse --short HEAD)"
"$CODE/bin/fm-watch-arm.sh" > "$HOME_DIR/arm1.out" 2>&1 & ARM1=$!
sleep 4
WPID=$(cat "$STATE/.watch.lock/pid")
echo "arm #1: $(head -1 "$HOME_DIR/arm1.out")"
touch -d "@$(( $(date +%s) - 400 ))" "$STATE/.last-watcher-beat"
touch -d "@$(( $(date +%s) - 1000 ))" "$STATE/.watch.lock"
echo "beacon age now $(( $(date +%s) - $(stat -c %Y "$STATE/.last-watcher-beat") ))s, watcher $WPID in its 600s terminal wait"
echo "re-arm: $(timeout 20 "$CODE/bin/fm-watch-arm.sh" 2>&1 | head -1)"
kill -TERM "$ARM1" "$WPID" 2>/dev/null; sleep 2; kill -KILL "$WPID" 2>/dev/null; true
