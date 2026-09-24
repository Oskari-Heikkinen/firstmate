# Shared lab environment for the second-mate line-typing live validation.
# Source with LAB set to a throwaway directory.
export ROOT=/home/oskari/.no-mistakes/worktrees/ca1b14ddd4b9/01M39ESJP0ZM9FTFR78S03HSCW
export PARENT="$LAB/parent" MATE="$LAB/mate"
export TMUX_TMPDIR="$LAB/tmux"
unset TMUX TMUX_PANE HERDR_ENV HERDR_PANE_ID HERDR_SESSION
lab_setup() {
  mkdir -p "$PARENT/state" "$PARENT/config" "$MATE/state" "$TMUX_TMPDIR"
  git -C "$PARENT" init -q 2>/dev/null || true
  tmux new-session -d -s lab -n fm-mate -x 160 -y 40 'bash --noprofile --norc'
  tmux new-window -d -t lab -n fm-other 'bash --noprofile --norc'
  cat > "$PARENT/state/mate.meta" <<M
window=lab:fm-mate
endpoint_task_id=mate
worktree=$MATE
project=$MATE
harness=claude
kind=secondmate
mode=secondmate
yolo=off
home=$MATE
projects=alpha
M
  cat > "$PARENT/state/other.meta" <<M
window=lab:fm-other
endpoint_task_id=other
worktree=$LAB/other
project=$LAB/other
harness=claude
kind=ship
mode=no-mistakes
yolo=off
M
  printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$PARENT" > "$MATE/.fm-secondmate-parent"
  printf 'mate\n' > "$MATE/.fm-secondmate-home"
}
# Parent-side commands, exactly as the parent firstmate runs them.
p_send()  { FM_GATE_REFUSE_BYPASS=1 FM_HOME="$PARENT" FM_ROOT_OVERRIDE="$PARENT" FM_SEND_SETTLE=0 "$ROOT/bin/fm-send.sh" "$@"; }
p_drain() { FM_HOME="$PARENT" FM_ROOT_OVERRIDE="$PARENT" "$ROOT/bin/fm-wake-drain.sh" "$@"; }
p_watch() { FM_HOME="$PARENT" FM_ROOT_OVERRIDE="$PARENT" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$ROOT/bin/fm-watch.sh" "$@"; }
# Mate-side reply, exactly as a secondmate answers a marked request.
m_report() { FM_HOME="$MATE" "$ROOT/bin/fm-secondmate-report.sh" "$@"; }
rec_of() { printf '%s/state/pending-replies/%s' "$PARENT" "$1"; }
# Watcher lifecycle: start in the background, then wait for its exit (a wake) or
# for it to stay alive through several full polls (nothing woke).
# exec so $! is the watcher process itself (a function in & would leave it orphaned on kill).
w_start() { : > "$LAB/watch.out"; ( exec env FM_GATE_REFUSE_BYPASS=1 FM_HOME="$PARENT" FM_ROOT_OVERRIDE="$PARENT" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$ROOT/bin/fm-watch.sh" ) > "$LAB/watch.out" 2> "$LAB/watch.err" & echo $! > "$LAB/watch.pid"; }
# Wait until the running watcher has classified every byte of mate.status (idle, caught up).
w_caught_up() { local i=0; while [ "$i" -lt 150 ]; do kill -0 "$(w_pid)" 2>/dev/null || return 1; [ "$(seen_size)" = "$(wc -c < "$PARENT/state/mate.status")" ] && { sleep 1.5; return 0; }; sleep 0.1; i=$((i+1)); done; return 1; }
w_pid() { cat "$LAB/watch.pid"; }
w_wait() {  # <seconds> -> 0 when the watcher exited (woke), 1 when still running
  local i=0 lim=$(( $1 * 10 ))
  while [ "$i" -lt "$lim" ]; do kill -0 "$(w_pid)" 2>/dev/null || return 0; sleep 0.1; i=$((i+1)); done
  return 1
}
w_stop() { kill "$(w_pid)" 2>/dev/null; wait "$(w_pid)" 2>/dev/null; true; }
# Drain as the parent does at a wake, then acknowledge it.
p_drain_ack() {
  local err="$LAB/drain.err" seq gen
  p_drain 2> "$err"; cat "$err" | grep -v '^WAKE_ACK_REQUIRED' >&2
  seq=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation .*/\1/p' "$err")
  gen=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--recovery-generation \([A-Za-z0-9._-]*\)$/\1/p' "$err")
  [ -n "$seq" ] && p_drain --ack-through "$seq" --recovery-generation "$gen" >/dev/null 2>&1
  true
}
queue_rows() { [ -s "$PARENT/state/.wake-queue" ] && cat "$PARENT/state/.wake-queue" | sed "s#$LAB#\$LAB#g" || echo '(wake queue empty)'; }
phase_of() { grep '^phase=' "$(rec_of "$1")"; }
# One watcher round: start it, run the mate-side append, report whether the
# parent woke and what the wake and its drain show.
round() {  # <title> <expect wake|absorb> <command...>
  local title=$1 want=$2; shift 2
  echo "### $title  (expected: $want)"
  w_start
  if ! w_caught_up; then echo "HARNESS: watcher not caught up before append (exited: $(sed "s#$LAB#\$LAB#g" "$LAB/watch.out"))"; p_drain_ack >/dev/null 2>&1; w_stop; w_start; w_caught_up || { echo "HARNESS: still not caught up"; }; fi
  offsets
  echo "\$ (mate) $*"
  "$@"
  if w_wait 15; then
    echo "RESULT: parent WOKEN. watcher stdout: $(sed "s#$LAB#\$LAB#g" "$LAB/watch.out")"
    echo '$ fm-wake-drain.sh'; p_drain_ack 2>&1 | sed "s#$LAB#\$LAB#g" | grep -v '^WARNING: queued'
  else
    w_stop
    echo "RESULT: parent NOT woken (watcher alive through 15s of 1s polls); queue: $(queue_rows)"
    grep -F 'absorbed benign signal' "$PARENT/state/.watch-triage.log" | tail -1 | sed "s#$LAB#\$LAB#g"
  fi
  echo
}
mate_line() { printf '%s\n' "$@" >> "$PARENT/state/mate.status"; }
# The mate acknowledging every steering record it has read (bin/fm-task-inbox-lib.sh: the mv IS the ack).
m_take_inbox() { local r; for r in "$PARENT"/state/mate.inbox/*.msg; do [ -f "$r" ] && mv "$r" "$PARENT/state/mate.inbox/handled/"; done; true; }
seen_size() { sed -n 's/.*\t\([0-9]*\)@.*/\1/p' "$PARENT/state/.seen-mate_status" 2>/dev/null; }
offsets() { echo "  [mate.status size=$(wc -c < "$PARENT/state/mate.status") classified(.seen)=$(seen_size)]"; }
# Stronger readiness: the watcher's beacon (touched at the top of every poll)
# must advance at least twice, so a whole poll cycle completed after startup.
beat_m() { stat -c %Y "$PARENT/state/.last-watcher-beat" 2>/dev/null; }
w_caught_up() {
  local i=0 seen_changes=0 last now
  rm -f "$PARENT/state/.last-watcher-beat"; last=
  while [ "$i" -lt 200 ]; do
    kill -0 "$(w_pid)" 2>/dev/null || return 1
    now=$(beat_m)
    if [ -n "$now" ] && [ "$now" != "$last" ]; then seen_changes=$((seen_changes+1)); last=$now; fi
    if [ "$seen_changes" -ge 3 ] && [ "$(seen_size)" = "$(wc -c < "$PARENT/state/mate.status")" ]; then return 0; fi
    sleep 0.1; i=$((i+1))
  done
  return 1
}
# Absorb any one-shot restart bookkeeping wake left by a killed watcher, so the
# next start begins from a quiet home.
quiesce() { local n=0; while [ "$n" -lt 4 ]; do w_start; if w_wait 5; then p_drain_ack >/dev/null 2>&1; n=$((n+1)); else w_stop; return 0; fi; done; }
# Kill + immediately quiesce leaves a rearm marker again, so the probe starts right after the quiet watcher is stopped
# Production-shaped lifecycle: a watcher runs until it wakes; the parent then
# drains, acknowledges, and re-arms it. Nothing is killed mid-sequence.
ensure_watcher() { kill -0 "$(w_pid 2>/dev/null)" 2>/dev/null || w_start; }
step() {  # <label> <expect> <delay-after-(re)arm> <command...>
  local label=$1 want=$2 delay=$3 pre; shift 3
  ensure_watcher; sleep "$delay"
  pre="classified=$(seen_size) size=$(wc -c < "$PARENT/state/mate.status")"
  "$@"
  if w_wait 8; then
    echo "[$label] expected=$want [$pre] -> WOKE: $(sed "s#$LAB#\$LAB#g" "$LAB/watch.out")"
    p_drain_ack 2>&1 | sed "s#$LAB#\$LAB#g" | grep -v '^WARNING' | sed 's/^/    /'
    w_start   # re-arm
  else
    echo "[$label] expected=$want [$pre] -> not woken (watcher still polling)"
  fi
}
# Mate-home publishers, through the real channel owner (bin/fm-parent-channel-lib.sh).
m_publish() { bash -c '. "$1/bin/fm-classify-lib.sh"; . "$1/bin/fm-parent-channel-lib.sh"; fm_parent_channel_report "$2" "$2/state" "$3"' _ "$ROOT" "$MATE" "$1"; }
m_merged() { bash -c '. "$1/bin/fm-classify-lib.sh"; . "$1/bin/fm-merge-outcome-lib.sh"; fm_merge_outcome_report "$2" "$2/state" "$3" "$4" poll' _ "$ROOT" "$MATE" "$1" "$2"; }
