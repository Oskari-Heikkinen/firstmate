. /tmp/fmlive/rig.sh
for which in prefix fixed; do
  if [ $which = prefix ]; then BIN=/tmp/fmlive/prefix/bin; else BIN=$ROOT/bin; fi
  echo "===== S9 [$which: $BIN] AWAY MODE: real fm-supervise-daemon.sh (runs fm-watch.sh as child), secondmate lane paused on PR #6"
  rig_reset s9-$which; lane a 'paused: waiting for review on https://github.com/Oskari-Heikkinen/firstmate/pull/6' secondmate
  printf 'pr=https://github.com/Oskari-Heikkinen/firstmate/pull/6\n' >> "$S/a.meta"
  tmux new-window -d -t fmlab: -n sup "cat > /dev/null"
  date +%s > "$S/.afk"
  env FM_HOME="$H" FM_STATE_OVERRIDE="$S" FM_CONFIG_OVERRIDE="$H/config" FM_SUPERVISOR_BACKEND=tmux FM_SUPERVISOR_TARGET=fmlab:sup \
    FM_DAEMON_PRIMARY_HARNESS=claude FM_ESCALATE_BATCH_SECS=999999 FM_MAX_DEFER_SECS=0 FM_PAUSE_RESURFACE_SECS=15 \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_HOME_SUMMARY_INTERVAL=999999 \
    "$BIN/fm-supervise-daemon.sh" > "$LAB/$CASE/daemon.out" 2>&1 &
  DPID=$!
  i=0; while [ ! -e "$S/.subsuper-paused-a" ] && [ $i -lt 400 ]; do sleep 0.1; i=$((i+1)); done
  i=0; while ! sed -n 2p "$S/.recheck-fp-fmlab_fm-a" 2>/dev/null | grep -q 'pr=OPEN' && [ $i -lt 400 ]; do sleep 0.1; i=$((i+1)); done
  echo "--- baseline recorded: $(sed -n 2p "$S/.recheck-fp-fmlab_fm-a" | sed 's/status=[^ ]* //')"
  echo "--- daemon began tracking the wait at $(date +%T) (marker exists: $([ -e "$S/.subsuper-paused-a" ] && echo yes || echo no))"
  sed -i 's#^pr=.*#pr=https://github.com/Oskari-Heikkinen/firstmate/pull/3#' "$S/a.meta"
  echo "--- lane changed: its PR now reads MERGED (repointed to merged PR #3) at $(date +%T); waiting 45s"
  sleep 45
  kill -9 $DPID 2>/dev/null; pkill -9 -f "$BIN/fm-watch.sh" 2>/dev/null; wait $DPID 2>/dev/null
  echo "--- daemon log (fingerprint / pause lines):"; grep -E 'paused|fingerprint|escalat|self-handle' "$S/.supervise-daemon.log" | sed 's/^/  /' | tail -20
  echo "--- watcher triage log (recheck lines):"; grep -E 'recheck|resurface|re-surface' "$S/.watch-triage.log" 2>/dev/null | sed 's/^/  /' | tail -10
  echo "--- .recheck-surfaced stamped by watcher? $(ls "$S"/.recheck-surfaced-* 2>/dev/null || echo no)"
  echo "--- buffered captain escalations (.subsuper-escalations):"; cat "$S/.subsuper-escalations" 2>/dev/null || echo "  (none)"
  if grep -q 'lane changed since its wait was last shown' "$S/.subsuper-escalations" 2>/dev/null; then echo "RESULT S9 [$which]: change ESCALATED to captain"; else echo "RESULT S9 [$which]: change NOT escalated"; fi
done
