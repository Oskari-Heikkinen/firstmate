#!/usr/bin/env bash
# Live scenario: the observed long single step - fm_pending_reply_tick walking a
# parent home with ~1200 resolved records (plus open escalated ones that make
# the scan outlast the grace). The beacon must stay fresh, a mid-scan re-arm
# must attach, the watchdog must leave the watcher alone, and the per-record
# beat must not fork a `touch` per record (throttled to <= ~1/s).
# usage: scenario-pending-reply-scan.sh <code-root> <lab-home>
set -u
CODE=$1 HOME_DIR=$2
export FM_HOME=$HOME_DIR
STATE=$HOME_DIR/state
export FM_GUARD_GRACE=5 FM_POLL=2 FM_WATCHER_WATCHDOG_INTERVAL=1 FM_HEARTBEAT=999999 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_ARM_CONFIRM_TIMEOUT=6
D=$STATE/pending-replies; mkdir -p "$D"
now=$(date +%s)
for i in $(seq 1 1200); do
  c=$(printf 'res%013d' "$i")
  printf 'schema=fm-pending-reply.v1\ncorr_id=%s\ntask_id=old-mate\nphase=resolved\ncreated_epoch=%s\ndelivered_epoch=%s\nresolved_epoch=%s\n' "$c" "$now" "$now" "$now" > "$D/$c"
done
OPEN=${OPEN_RECORDS:-120}
for i in $(seq 1 "$OPEN"); do
  c=$(printf 'esc%013d' "$i")
  printf 'schema=fm-pending-reply.v1\ncorr_id=%s\ntask_id=gone-mate\nphase=escalated\ncreated_epoch=1\ndelivered_epoch=1\nescalated_epoch=1\n' "$c" > "$D/$c"
done
echo "seeded $(ls "$D" | wc -l) pending-reply records (1200 resolved, $OPEN open escalated)"
mkdir -p "$HOME_DIR/shim"; : > "$HOME_DIR/touch.log"
cat > "$HOME_DIR/shim/touch" <<SH
#!/usr/bin/env bash
case "\$*" in *last-watcher-beat*) printf '%s\n' "\$(date +%s.%N)" >> "$HOME_DIR/touch.log" ;; esac
exec /usr/bin/touch "\$@"
SH
chmod +x "$HOME_DIR/shim/touch"
PATH="$HOME_DIR/shim:$PATH" "$CODE/bin/fm-watch-arm.sh" > "$HOME_DIR/arm1.out" 2>&1 &
ARM1=$!
i=0; while [ "$i" -lt 50 ] && [ ! -s "$STATE/.last-watcher-beat" ]; do sleep 0.2; i=$((i+1)); done
WPID=$(cat "$STATE/.watch.lock/pid" 2>/dev/null)
start=$(date +%s); maxage=0; rearm=''
echo "arm #1: $(head -1 "$HOME_DIR/arm1.out")"
while :; do
  c=$(head -1 "$STATE/.last-watcher-beat" 2>/dev/null)
  el=$(( $(date +%s) - start ))
  age=$(( $(date +%s) - $(stat -c %Y "$STATE/.last-watcher-beat") ))
  [ "$age" -gt "$maxage" ] && maxage=$age
  echo "t=${el}s cycle_stamp=$c beacon_age=${age}s watcher_alive=$(kill -0 "$WPID" 2>/dev/null && echo yes || echo no)"
  if [ -z "$rearm" ] && [ "$c" = 1 ] && [ "$el" -ge 7 ]; then
    rearm=$(timeout 4 "$CODE/bin/fm-watch-arm.sh" 2>&1 | head -1)
    echo "   mid-scan re-arm at ${el}s into cycle 1 (grace 5s): $rearm"
  fi
  [ "$c" != 1 ] && break
  [ "$el" -ge 240 ] && { echo "scan did not finish in 240s"; break; }
  sleep 1
done
cyc1=$(( $(date +%s) - start ))
touches=$(wc -l < "$HOME_DIR/touch.log")
echo "RESULT: cycle 1 (pending-reply scan) took ~${cyc1}s, > grace 5s; max beacon age seen=${maxage}s"
echo "RESULT: watcher_beat 'touch' processes during cycle 1 ~= $touches for $(ls "$D" | wc -l) records (throttle: at most ~1 per second)"
echo "RESULT: mid-scan re-arm said: $rearm"
echo "watchdog lines: $(grep -c watchdog "$STATE/.watch-triage.log" 2>/dev/null || echo 0)"
echo "watcher $WPID alive after scan: $(kill -0 "$WPID" 2>/dev/null && echo yes || echo no)"
kill -TERM "$ARM1" "$WPID" 2>/dev/null; sleep 2
