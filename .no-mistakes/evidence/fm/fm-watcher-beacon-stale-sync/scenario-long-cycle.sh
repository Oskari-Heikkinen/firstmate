#!/usr/bin/env bash
# Live scenario: a healthy watcher whose one poll cycle (three slow registered
# checks, 4s each) outlasts the guard grace (8s). Mid-cycle, a Stop-hook style
# re-arm (bin/fm-watch-arm.sh with FM_GUARD_GRACE) must attach, not refuse.
# usage: scenario-long-cycle.sh <code-root> <lab-home>
set -u
CODE=$1 HOME_DIR=$2
export FM_HOME=$HOME_DIR
STATE=$HOME_DIR/state
export FM_GUARD_GRACE=8 FM_POLL=2 FM_CHECK_INTERVAL=1 FM_CHECK_TIMEOUT=600 FM_HEARTBEAT=999999 FM_SIGNAL_GRACE=1 FM_ARM_CONFIRM_TIMEOUT=6
echo "code root: $CODE   (commit: $(cat "$CODE/.commit" 2>/dev/null || git -C "$CODE" rev-parse --short HEAD))"
for id in slowa slowb slowc; do
  printf '#!/usr/bin/env bash\nsleep 4\n' > "$STATE/$id.check.sh"; chmod 700 "$STATE/$id.check.sh"
  "$CODE/bin/fm-check-register.sh" "$id" >/dev/null || echo "register $id failed"
done
"$CODE/bin/fm-watch-arm.sh" > "$HOME_DIR/arm1.out" 2>&1 &
ARM1=$!
sleep 3
WPID=$(cat "$STATE/.watch.lock/pid" 2>/dev/null)
echo "first arm: $(head -1 "$HOME_DIR/arm1.out")  watcher pid=$WPID"
last=''; cyc_start=$(date +%s); rearms=0; refused=0; attached=0
for t in $(seq 1 40); do
  c=$(cat "$STATE/.last-watcher-beat" 2>/dev/null | head -1)
  # base code writes no cycle stamp: fall back to the mtime (touched only at cycle top there)
  [ -n "$c" ] || c="mtime:$(stat -c %Y "$STATE/.last-watcher-beat" 2>/dev/null)"
  now=$(date +%s)
  if [ "$c" != "$last" ]; then last=$c; cyc_start=$now; fi
  age=$(( now - $(stat -c %Y "$STATE/.last-watcher-beat") ))
  incycle=$(( now - cyc_start ))
  line="t=${t}s cycle_stamp=${c:-<empty>} seconds_into_cycle=$incycle beacon_age=${age}s"
  if [ "$incycle" -ge 9 ] && [ "$rearms" -lt 3 ]; then
    rearms=$((rearms+1))
    out=$(timeout 8 "$CODE/bin/fm-watch-arm.sh" 2>&1 | head -1)
    line="$line  RE-ARM -> $out"
    case "$out" in *attached*) attached=$((attached+1)) ;; *) refused=$((refused+1)) ;; esac
  fi
  echo "$line"
  sleep 1
done
echo "RESULT: mid-cycle re-arms=$rearms attached=$attached refused=$refused"
kill -0 "$WPID" 2>/dev/null && echo "watcher pid $WPID still alive at end" || echo "watcher pid $WPID gone at end"
grep -h 'watchdog' "$STATE/.watch-triage.log" 2>/dev/null || echo "no watchdog stop logged"
kill -TERM "$ARM1" "$WPID" 2>/dev/null; sleep 2
kill -0 "$WPID" 2>/dev/null && kill -KILL "$WPID"; true
