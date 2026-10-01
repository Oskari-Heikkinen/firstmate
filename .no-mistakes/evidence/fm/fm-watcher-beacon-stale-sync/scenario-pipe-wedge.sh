#!/usr/bin/env bash
# Live scenario: the watcher's pane capture leaves a detached process holding
# the command-substitution pipe (the 2026-09-27 pipe_read hang). The watcher's
# own watchdog must stop it past the grace without a manual kill, and the owner
# path (bin/fm-watch-arm.sh, what the Stop hook runs) must then start a fresh
# watcher instead of refusing a stale heartbeat.
# usage: scenario-pipe-wedge.sh <code-root> <lab-home>   (run inside the lab tmux)
set -u
CODE=$1 HOME_DIR=$2
export FM_HOME=$HOME_DIR
STATE=$HOME_DIR/state
export FM_GUARD_GRACE=8 FM_POLL=2 FM_WATCHER_WATCHDOG_INTERVAL=2 FM_HEARTBEAT=999999 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_ARM_CONFIRM_TIMEOUT=6
REAL_TMUX=$(command -v tmux)
mkdir -p "$HOME_DIR/shim"
cat > "$HOME_DIR/shim/tmux" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = capture-pane ]; then
  "$REAL_TMUX" "\$@"
  sleep 600 &
  printf '%s\n' "\$!" > "$HOME_DIR/holder.pid"
  exit 0
fi
exec "$REAL_TMUX" "\$@"
SH
chmod +x "$HOME_DIR/shim/tmux"
"$REAL_TMUX" new-window -d -n fm-hang 'bash --norc'
SESSION=$("$REAL_TMUX" display-message -p '#S')
printf 'window=%s\nkind=ship\n' "$SESSION:fm-hang" > "$STATE/hang.meta"
echo "lab tmux window: $SESSION:fm-hang  (pane capture shim leaves a detached 'sleep 600' holding the capture pipe)"
PATH="$HOME_DIR/shim:$PATH" "$CODE/bin/fm-watch-arm.sh" > "$HOME_DIR/arm1.out" 2>&1 &
ARM1=$!
i=0; while [ "$i" -lt 50 ] && [ ! -s "$HOME_DIR/holder.pid" ]; do sleep 0.2; i=$((i+1)); done
WPID=$(cat "$STATE/.watch.lock/pid" 2>/dev/null)
HOLDER=$(cat "$HOME_DIR/holder.pid" 2>/dev/null)
echo "arm #1: $(head -1 "$HOME_DIR/arm1.out")   watcher pid=$WPID  pipe holder pid=$HOLDER"
for t in $(seq 1 25); do
  if kill -0 "$WPID" 2>/dev/null && [ "$(awk '{print $3}' /proc/$WPID/stat 2>/dev/null)" != Z ]; then
    wchan=$(cat /proc/$WPID/wchan 2>/dev/null)
    fd1=$(for f in /proc/$WPID/fd/*; do readlink "$f"; done 2>/dev/null | grep pipe | tr '\n' ' ')
    kids=$(pgrep -P "$WPID" | tr '\n' ' ')
    age=$(( $(date +%s) - $(stat -c %Y "$STATE/.last-watcher-beat") ))
    echo "t=${t}s watcher $WPID alive wchan=$wchan beacon_age=${age}s children=[${kids}] pipes=[${fd1}]"
  else
    echo "t=${t}s watcher $WPID is GONE (no manual kill was sent)"; break
  fi
  sleep 1
done
echo "--- triage log (watchdog lines) ---"; grep watchdog "$STATE/.watch-triage.log"
echo "--- arm #1 output ---"; cat "$HOME_DIR/arm1.out"
wait "$ARM1" 2>/dev/null; echo "arm #1 exit=$?"
echo "pipe holder $HOLDER still alive: $(kill -0 "$HOLDER" 2>/dev/null && echo yes || echo no)"
echo "--- lock after stop: $(cat "$STATE/.watch.lock/pid" 2>/dev/null || echo '<no lock>')"
echo "--- owner-path recovery: fm-watch-arm.sh (no shim, as the Stop hook would run it) ---"
rm -f "$STATE/hang.meta"
"$CODE/bin/fm-watch-arm.sh" > "$HOME_DIR/arm2.out" 2>&1 &
ARM2=$!
i=0; while [ "$i" -lt 50 ] && [ ! -s "$HOME_DIR/arm2.out" ]; do sleep 0.2; i=$((i+1)); done
echo "arm #2: $(head -1 "$HOME_DIR/arm2.out")"
W2=$(cat "$STATE/.watch.lock/pid" 2>/dev/null)
echo "new watcher pid=$W2 (old=$WPID)"
echo "--- cycle-exit ledger ---"; cat "$STATE/.watch-cycle-exits.log" 2>/dev/null
kill -TERM "$ARM2" "$W2" 2>/dev/null; kill "$HOLDER" 2>/dev/null; sleep 3
echo "--- leftover processes referencing this lab home after teardown ---"
for p in /proc/[0-9]*; do grep -qs "$HOME_DIR" "$p/environ" 2>/dev/null && [ "${p#/proc/}" != $$ ] && echo "$(basename $p) $(tr '\0' ' ' < $p/cmdline)"; done | grep -v scenario-pipe-wedge || echo "(none)"
