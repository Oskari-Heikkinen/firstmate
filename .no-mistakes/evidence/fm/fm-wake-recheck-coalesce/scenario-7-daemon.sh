#!/usr/bin/env bash
# Away-mode mirror, driven through the real bin/fm-supervise-daemon.sh (which runs the real
# watcher as its child) with state/.afk present:
# D1: unchanged paused lanes m and o are self-handled at their due rechecks (no escalation);
# D2: lane n's agent crashes under its still-declared wait -> escalated naming `agent`;
# D3: at the standing-waits ceiling, m and o are escalated together in one pass.
# Escalations are held in the batch buffer (state/.subsuper-escalations) by a long batch window
# so they can be read; the supervisor pane is a `cat` in the isolated lab.
export LAB=/tmp/fmlive-s7; rm -rf $LAB
source /home/oskari/.no-mistakes/evidence/01M3970VYSRKKD65VXP6R9VMW6/live-lib.sh
lab_init
tmux new-window -d -t "$SESSION" -n sup cat
lane m 'paused: waiting for vendor reply on the API quota'
lane n 'paused: waiting for the upstream release'
lane o 'paused: waiting for the design review'
date +%s > "$STATE/.afk"
sleep 1
env FM_SUPERVISOR_BACKEND=tmux FM_SUPERVISOR_TARGET="$SESSION:sup" FM_POLL=1 FM_SIGNAL_GRACE=1 \
  FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_HEARTBEAT_SCAN_SECS=999999 FM_HOUSEKEEPING_TICK=2 \
  FM_ESCALATE_BATCH_SECS=100000 FM_MAX_DEFER_SECS=0 FM_WEDGE_ALARM_CHANNEL=off \
  FM_PAUSE_RESURFACE_SECS=30 FM_STANDING_WAITS_CEILING_SECS=95 \
  "$ROOT/bin/fm-supervise-daemon.sh" > "$LAB/daemon.out" 2>&1 &
DPID=$!
say "daemon started pid=$DPID (afk on); lanes m n o declared paused"
sleep 12
say "lane n's agent crashes (age $(age_of_status n)s)"
pkill -P "$(tmux list-panes -t "$SESSION:fm-n" -F '#{pane_pid}')" claude
sleep 1; echo "agent states: m=$(bash -c "source $ROOT/bin/fm-backend.sh; fm_backend_agent_state tmux $SESSION:fm-m") n=$(bash -c "source $ROOT/bin/fm-backend.sh; fm_backend_agent_state tmux $SESSION:fm-n")"
wait_age m 60
say "at lane age $(age_of_status m)s (two recheck cadences in): escalation buffer"
cat "$STATE/.subsuper-escalations" 2>/dev/null | sed 's/^/  buffered: /'
say "daemon log so far (pause handling)"
grep -E 'paused|fingerprint|self-handle' "$STATE/.supervise-daemon.log" | sed 's/^/  /'
wait_age m 105
say "at lane age $(age_of_status m)s (past the 95s standing-waits ceiling): escalation buffer"
cat "$STATE/.subsuper-escalations" 2>/dev/null | sed 's/^/  buffered: /'
say "daemon log (pause handling, whole run)"
grep -E 'paused|fingerprint|self-handle' "$STATE/.supervise-daemon.log" | sed 's/^/  /'
kill "$DPID"; wait "$DPID" 2>/dev/null
lab_teardown
