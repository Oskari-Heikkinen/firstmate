. /tmp/fmlive/rig.sh
echo "===== S10 AWAY MODE: real daemon, two unchanged secondmate waits, cadence 15s, ceiling 50s"
rig_reset s10; lane a 'paused: waiting on the upstream release' secondmate; lane b 'paused: waiting on vendor reply' secondmate
tmux new-window -d -t fmlab: -n sup "cat > /dev/null"
date +%s > "$S/.afk"; age_status b 6
env FM_HOME="$H" FM_STATE_OVERRIDE="$S" FM_CONFIG_OVERRIDE="$H/config" FM_SUPERVISOR_BACKEND=tmux FM_SUPERVISOR_TARGET=fmlab:sup \
  FM_DAEMON_PRIMARY_HARNESS=claude FM_ESCALATE_BATCH_SECS=999999 FM_MAX_DEFER_SECS=0 FM_PAUSE_RESURFACE_SECS=15 FM_STANDING_WAITS_CEILING_SECS=50 \
  FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_HOME_SUMMARY_INTERVAL=999999 \
  "$ROOT/bin/fm-supervise-daemon.sh" > "$LAB/$CASE/daemon.out" 2>&1 &
DPID=$!; sleep 70
kill -9 $DPID; pkill -9 -f "$ROOT/bin/fm-watch.sh"; wait $DPID 2>/dev/null
echo "--- daemon log:"; grep -E 'fingerprint|standing|escalat' "$S/.supervise-daemon.log" | sed 's/^/  /'
echo "--- buffered captain escalations:"; cat "$S/.subsuper-escalations" 2>/dev/null || echo "  (none)"
