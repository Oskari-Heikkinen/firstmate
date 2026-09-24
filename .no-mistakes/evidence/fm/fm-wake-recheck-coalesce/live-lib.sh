# Live harness for declared-wait recheck validation: real bin/fm-watch.sh,
# real bin/fm-wake-drain.sh, real bin/fm-crew-state.sh, real tmux (isolated
# server via TMUX_TMPDIR), real git task copies, a process named `claude` as the
# agent in each pane.
ROOT=/home/oskari/.no-mistakes/worktrees/ca1b14ddd4b9/01M3970VYSRKKD65VXP6R9VMW6
LAB=${LAB:-/tmp/fmlive-$$}
export TMUX_TMPDIR="$LAB/tmux"
unset TMUX
export FM_HOME="$LAB/home"
STATE="$FM_HOME/state"
SESSION=fmlive
lab_init() {
  mkdir -p "$TMUX_TMPDIR" "$STATE" "$FM_HOME/config" "$LAB/bin" "$LAB/wt"
  cp /bin/sleep "$LAB/bin/claude"
  tmux new-session -d -s "$SESSION" -n boot -x 120 -y 30 bash --norc --noprofile
}
# lane <task> <status-line>: a tmux window running a `claude` process, a git task copy, meta, status.
lane() {
  local task=$1 line=$2 wt="$LAB/wt/$1"
  git init -q "$wt"; git -C "$wt" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
  tmux new-window -d -t "$SESSION" -n "fm-$task" bash --norc --noprofile
  tmux send-keys -t "$SESSION:fm-$task" "clear; PS1='$ '; $LAB/bin/claude 1000000" Enter
  printf 'window=%s:fm-%s\nbackend=tmux\nkind=ship\nworktree=%s\n' "$SESSION" "$task" "$wt" > "$STATE/$task.meta"
  printf '%s\n' "$line" >> "$STATE/$task.status"
}
backdate() { touch -m -d "@$(( $(date +%s) - $1 ))" "$2"; }
watch_start() {  # [VAR=value]...
  env FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$@" \
    "$ROOT/bin/fm-watch.sh" >> "$LAB/watch.out" 2>&1 &
  WPID=$!
  echo "--- watcher armed pid=$WPID $* ---" >> "$LAB/watch.out"
}
# wait for watcher exit up to N seconds; returns 0 if it exited (a wake).
watch_wait() { local n=$(( $1 * 10 )) i=0; while kill -0 "$WPID" 2>/dev/null && [ $i -lt $n ]; do sleep 0.1; i=$((i+1)); done; ! kill -0 "$WPID" 2>/dev/null; }
watch_stop() { kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null; }
drain_ack() {
  local err="$LAB/drain.err" seq gen
  "$ROOT/bin/fm-wake-drain.sh" > "$LAB/drain.out" 2> "$err"; cat "$LAB/drain.out"
  seq=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation.*/\1/p' "$err")
  gen=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--recovery-generation \([A-Za-z0-9._-]*\)$/\1/p' "$err")
  [ -n "$seq" ] && "$ROOT/bin/fm-wake-drain.sh" --ack-through "$seq" --recovery-generation "$gen" >/dev/null 2>&1
}
lab_teardown() { tmux kill-server 2>/dev/null; rm -rf "$LAB"; }
say() { printf '\n=== [%s] %s\n' "$(date +%T)" "$*"; }
# Deliver and acknowledge the initial status signals (what a supervisor turn does), then
# run one quiet first-sight pass so the stale scan has seen every lane.
prime() {  # [VAR=value]...
  local i
  for i in 1 2 3 4; do
    watch_start "$@"
    if watch_wait 8; then echo "prime: $(tail -1 $LAB/watch.out)"; drain_ack >/dev/null; else break; fi
  done
}
age_of_status() { echo $(( $(date +%s) - $(stat -c %Y "$STATE/$1.status") )); }
wait_age() { while [ "$(age_of_status "$1")" -lt "$2" ]; do sleep 1; done; }
stale_rows() { awk -F '\t' -v w="$1" '$3=="stale" && $4==w {n++} END {print n+0}' "$STATE/.wake-queue" 2>/dev/null; }
