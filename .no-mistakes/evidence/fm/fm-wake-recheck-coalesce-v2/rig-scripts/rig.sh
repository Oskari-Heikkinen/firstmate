# Live rig: real bin/fm-watch.sh over a private tmux server, real fm-crew-state.sh, real git task copies.
set -u
ROOT=/home/oskari/.no-mistakes/worktrees/ca1b14ddd4b9/01M39CQCHTWJ1P4P2CA1T0Y9SH
EV=/home/oskari/.no-mistakes/evidence/01M39CQCHTWJ1P4P2CA1T0Y9SH
BIN=${BIN:-$ROOT/bin}
LAB=/tmp/fmlive
export TMUX_TMPDIR=$LAB/tmux
unset TMUX TMUX_PANE
mkdir -p "$TMUX_TMPDIR" "$LAB/agentbin"
ln -sf /usr/bin/sleep "$LAB/agentbin/claude"

rig_reset() {  # <case>
  CASE=$1; H=$LAB/$CASE/home; S=$H/state
  tmux kill-server 2>/dev/null || true
  rm -rf "$LAB/$CASE"; mkdir -p "$S" "$H/config"
  tmux new-session -d -s fmlab -x 120 -y 30 -n base
}
lane() {  # <task> [status-line] [kind]
  local t=$1 line=${2:-paused: waiting on the upstream release} kind=${3:-ship} wt=$LAB/$CASE/wt-$1
  git init -q "$wt"; git -C "$wt" -c user.email=l@l -c user.name=l commit -q --allow-empty -m init
  tmux new-window -d -t fmlab: -n "fm-$t" -c "$wt" "bash --norc --noprofile"
  sleep 0.3
  tmux send-keys -t "fmlab:fm-$t" "PS1='$ ' ; clear; $LAB/agentbin/claude 999999" Enter
  printf 'window=fmlab:fm-%s\nbackend=tmux\nkind=%s\nworktree=%s\n' "$t" "$kind" "$wt" > "$S/$t.meta"
  printf '%s\n' "$line" > "$S/$t.status"
  mark_seen "$t"
}
mark_seen() { FM_STATE_OVERRIDE="$S" bash -c '. "$1"; fm_wake_status_mark_current "$2" "$3"' _ "$BIN/fm-wake-lib.sh" "$S" "$S/$1.status"; }
age_status() { touch -m -d "@$(( $(date +%s) - $2 ))" "$S/$1.status"; }
watch_start() {  # [VAR=value]...
  env FM_HOME="$H" FM_STATE_OVERRIDE="$S" FM_CONFIG_OVERRIDE="$H/config" FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_HOME_SUMMARY_INTERVAL=999999 "$@" "$BIN/fm-watch.sh" > "$LAB/$CASE/watch.out" 2>&1 &
  WPID=$!
}
wait_exit() {  # <secs>
  local i=0; while kill -0 "$WPID" 2>/dev/null && [ $i -lt $(( $1 * 10 )) ]; do sleep 0.1; i=$((i+1)); done
  ! kill -0 "$WPID" 2>/dev/null
}
watch_stop() { kill "$WPID" 2>/dev/null; wait "$WPID" 2>/dev/null; true; }
drain_ack() {
  local err=$LAB/$CASE/drain.err out seq gen
  out=$(FM_STATE_OVERRIDE="$S" "$BIN/fm-wake-drain.sh" 2>"$err"); printf '%s\n' "$out"
  seq=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9]*\) .*/\1/p' "$err")
  gen=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--recovery-generation \([A-Za-z0-9._-]*\)$/\1/p' "$err")
  [ -n "$seq" ] && FM_STATE_OVERRIDE="$S" "$BIN/fm-wake-drain.sh" --ack-through "$seq" --recovery-generation "$gen" >/dev/null 2>&1
  true
}
show() { echo "--- watcher stdout:"; cat "$LAB/$CASE/watch.out"; echo "--- triage log:"; cat "$S/.watch-triage.log" 2>/dev/null | sed 's/^/  /'; }
