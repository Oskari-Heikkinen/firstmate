#!/usr/bin/env bash
# Live validation driver for fm/fm-secondmate-line-typing.
# Stands up an isolated FM_HOME whose second mate "mate" is a real pane in a
# private tmux server, then drives the real
# bin/fm-send.sh, bin/fm-watch.sh and bin/fm-wake-drain.sh against it.
set -u
ROOT=${ROOT:?}
EVID=${EVID:?}
# The Herdr lab helper refuses to provision while the default Herdr session is
# not running, so the mate pane lives in a private tmux server instead: an
# isolated TMUX_TMPDIR means every tmux call the product makes reaches only it.
unset TMUX TMUX_PANE HERDR_ENV HERDR_PANE_ID HERDR_TAB_ID HERDR_WORKSPACE_ID HERDR_SOCKET_PATH HERDR_SESSION
export FM_GATE_REFUSE_BYPASS=1 FM_BACKEND=tmux
TMP=$(mktemp -d /tmp/fm-live-secondmate.XXXXXX)
export TMUX_TMPDIR="$TMP/tmux"; mkdir -p "$TMUX_TMPDIR"
H="$TMP/home"; S="$H/state"
mkdir -p "$S"
RESULTS="$EVID/live-results.txt"; : > "$RESULTS"
res() { printf '%s | %s\n' "$1" "$2" | tee -a "$RESULTS"; }
say() { printf '\n### %s\n' "$*"; }
cleanup() {
  [ -n "${WPID:-}" ] && kill "$WPID" 2>/dev/null
  tmux kill-server 2>/dev/null && echo "private tmux server stopped"
  rm -rf "$EVID/final-state"; cp -r "$S" "$EVID/final-state" 2>/dev/null
  rm -rf "$TMP"
}
trap cleanup EXIT
say "start private tmux server with the mate pane"
tmux new-session -d -s fmlive -n fm-mate -x 160 -y 40 "bash --norc --noprofile" || exit 1
tmux new-window -d -t fmlive -n fm-crew "bash --norc --noprofile"
tmux list-windows -t fmlive
PANE_TARGET=fmlive:fm-mate
cat > "$S/mate.meta" <<EOF
window=fmlive:fm-mate
endpoint_task_id=mate
worktree=$H
project=$H
harness=echo
kind=secondmate
mode=secondmate
yolo=off
home=$H
projects=alpha
EOF
cat > "$S/crew.meta" <<EOF
window=fmlive:fm-crew
endpoint_task_id=crew
worktree=$H
project=$H
harness=echo
kind=ship
mode=no-mistakes
yolo=off
EOF

export FM_HOME="$H" FM_ROOT_OVERRIDE="$H" FM_STATE_OVERRIDE="$S" FM_SEND_SETTLE=0
. "$ROOT/bin/fm-pending-reply-lib.sh"
send() { "$ROOT/bin/fm-send.sh" "$@"; }
corr_of_inbox() { bash -c '. "$1"; fm_task_inbox_body "$2"' _ "$ROOT/bin/fm-task-inbox-lib.sh" "$1" | grep -oE 'corr=[0-9a-f]+' | head -1 | cut -d= -f2; }
rec_field() { fm_pending_reply_get "$(fm_pending_reply_path "$S" "$1")" "$2"; }

say "S1 fm-send --expect ack / default to the live mate pane"
send mate --expect ack "standing note: prefer small PRs"; echo "rc=$?"
ACK=$(corr_of_inbox "$S/mate.inbox/001.msg")
send mate "what did the ledger audit find"; echo "rc=$?"
ANS=$(corr_of_inbox "$S/mate.inbox/002.msg")
echo "ack corr=$ACK expect=$(rec_field "$ACK" expect) delivered=$(rec_field "$ACK" delivered_epoch) phase=$(rec_field "$ACK" phase)"
echo "answer corr=$ANS expect=$(rec_field "$ANS" expect) delivered=$(rec_field "$ANS" delivered_epoch) phase=$(rec_field "$ANS" phase)"
sleep 1
echo "--- live mate pane (tmux capture) ---"
tmux capture-pane -p -t "$PANE_TARGET" | grep -v "^$" | tail -8
[ "$(rec_field "$ACK" expect)" = ack ] && [ "$(rec_field "$ANS" expect)" = answer ] \
  && res S1-expect-persisted pass || res S1-expect-persisted fail

say "S1b adversarial send refusals"
send crew --expect ack "fix the test"; r1=$?
send mate --expect maybe "bad kind"; r2=$?
send mate --fire-and-forget 0123456789abcdef --expect ack "fyi"; r3=$?
FM_PENDING_REPLY_EXISTING_CORR=$ACK send mate --expect answer "resend with conflicting kind"; r4=$?
echo "crew=$r1 badkind=$r2 fireandforget=$r3 conflicting-resend=$r4"
[ -e "$S/mate.inbox/003.msg" ] && echo "UNEXPECTED 003.msg enqueued"
{ [ $r1 -ne 0 ] && [ $r2 -ne 0 ] && [ $r3 -ne 0 ] && [ $r4 -ne 0 ] && [ ! -e "$S/mate.inbox/003.msg" ]; } \
  && res S1b-expect-refusals pass || res S1b-expect-refusals fail

rm -f "$S/crew.meta"; tmux kill-window -t fmlive:fm-crew
. "$ROOT/bin/fm-wake-lib.sh"
printf 'note: bootstrap\n' > "$S/mate.status"
fm_wake_status_mark_current "$S" "$S/mate.status"

WOUT="$TMP/watch.out"
# One watcher runs across absorbed lines (an absorbing watcher keeps polling);
# a new one is started only after the previous one exited on a real wake and
# that wake was drained and acknowledged, exactly as the supervisor loop does.
ensure_watch() {
  if [ -n "${WPID:-}" ] && kill -0 "$WPID" 2>/dev/null; then return 0; fi
  : > "$WOUT"
  FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    "$ROOT/bin/fm-watch.sh" > "$WOUT" 2>>"$EVID/watch.stderr.txt" &
  WPID=$!
  sleep 2
}
# absorbed: watcher stays alive, logs a new 'absorbed benign', classified offset == size
expect_absorbed() {  # <scenario> <line...>
  local name=$1 i=0 before; shift
  ensure_watch
  before=$(grep -c 'absorbed benign' "$S/.watch-triage.log" 2>/dev/null); before=${before:-0}
  printf '%s\n' "$@" >> "$S/mate.status"
  while [ $i -lt 100 ]; do
    now=$(grep -c 'absorbed benign' "$S/.watch-triage.log" 2>/dev/null); [ "${now:-0}" -gt "$before" ] && break
    kill -0 "$WPID" 2>/dev/null || break
    sleep 0.1; i=$((i+1))
  done
  sleep 1
  local alive=0; kill -0 "$WPID" 2>/dev/null && alive=1
  echo "watcher alive=$alive stdout=[$(cat "$WOUT")] queue=[$(cat "$S/.wake-queue" 2>/dev/null)]"
  echo "classified(seen)=$(fm_wake_signal_seen_size "$S" "$S/mate.status") size=$(wc -c < "$S/mate.status")"
  grep 'absorbed benign' "$S/.watch-triage.log" | tail -1
  if [ $alive = 1 ] && [ ! -s "$WOUT" ] && [ ! -s "$S/.wake-queue" ] \
    && [ "$(grep -c 'absorbed benign' "$S/.watch-triage.log")" -gt "$before" ] \
    && [ "$(fm_wake_signal_seen_size "$S" "$S/mate.status")" = "$(wc -c < "$S/mate.status" | tr -d ' ')" ]; then
    res "$name" pass
  else res "$name" fail; fi
}
expect_wake() {  # <scenario> <line...>
  local name=$1 i=0; shift
  ensure_watch
  printf '%s\n' "$@" >> "$S/mate.status"
  while [ $i -lt 150 ] && kill -0 "$WPID" 2>/dev/null; do sleep 0.1; i=$((i+1)); done
  local alive=0; kill -0 "$WPID" 2>/dev/null && alive=1
  [ $alive = 0 ] && { wait "$WPID" 2>/dev/null; WPID=; }
  echo "watcher alive=$alive stdout=[$(cat "$WOUT")]"
  echo "queue=[$(tail -1 "$S/.wake-queue" 2>/dev/null)]"
  if [ $alive = 0 ] && grep -qF "signal: $S/mate.status" "$WOUT"; then res "$name" pass; else res "$name" fail; fi
}
drain_and_ack() {  # <outfile>
  "$ROOT/bin/fm-wake-drain.sh" > "$1" 2> "$1.err"
  cat "$1"
  local seq gen
  seq=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation.*/\1/p' "$1.err")
  gen=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--recovery-generation \([A-Za-z0-9._-]*\)$/\1/p' "$1.err")
  [ -n "$seq" ] && "$ROOT/bin/fm-wake-drain.sh" --ack-through "$seq" --recovery-generation "$gen" >/dev/null 2>&1 && echo "(acked through $seq)"
}

say "S2 mate working: line is absorbed"
expect_absorbed S2-working-absorbed 'working: auditing the release notes'

say "S3 correlated note acknowledging the ack-typed request is absorbed and resolves the record"
expect_absorbed S3-ack-absorbed "note [corr=$ACK]: taken up, will follow the standing note"
i=0; while [ $i -lt 100 ] && [ "$(rec_field "$ACK" phase)" != resolved ]; do sleep 0.1; i=$((i+1)); done
echo "ack record phase=$(rec_field "$ACK" phase) resolved_line=$(rec_field "$ACK" resolved_line 2>/dev/null)"
echo "watcher still alive after resolving: $(kill -0 "$WPID" 2>/dev/null && echo yes || echo no); stdout=[$(cat "$WOUT")] queue=[$(cat "$S/.wake-queue" 2>/dev/null)]"
[ "$(rec_field "$ACK" phase)" = resolved ] && kill -0 "$WPID" 2>/dev/null && [ ! -s "$WOUT" ] && res S3b-ack-record-resolved pass || res S3b-ack-record-resolved fail

say "S4 correlated reply to the answer-typed request wakes main"
expect_wake S4-answer-wakes "note [corr=$ANS]: the ledger audit found 3 drifted entries"
echo "answer record phase=$(rec_field "$ANS" phase)"

say "S5 the drain at that real wake presents the absorbed working + ack lines (UNREAD STATUS)"
drain_and_ack "$EVID/drain-after-answer.txt"
if grep -qF 'mate working: auditing the release notes' "$EVID/drain-after-answer.txt" \
  && grep -qF "mate note [corr=$ACK]: taken up" "$EVID/drain-after-answer.txt"; then
  res S5-absorbed-lines-presented-at-next-wake pass; else res S5-absorbed-lines-presented-at-next-wake fail; fi

say "S6 untagged note still wakes"
expect_wake S6-untagged-note-wakes 'note: the vendor changed their API'
drain_and_ack "$EVID/drain-after-untagged-note.txt"
if grep -qF 'the vendor changed their API' "$EVID/drain-after-untagged-note.txt" \
  && ! grep -qF 'auditing the release notes' "$EVID/drain-after-untagged-note.txt"; then
  res S6b-presented-once-not-reprinted pass; else res S6b-presented-once-not-reprinted fail; fi

say "S7 adversarial: working line followed by failed: in one span wakes"
expect_wake S7-working-then-failed-wakes 'working: retrying' 'failed: child kid CI broke on main'
drain_and_ack "$TMP/d7.txt" >/dev/null

say "S8 adversarial: one note answering both the ack and a fresh answer request wakes"
send mate "second question: which PRs are stale"; ANS2=$(corr_of_inbox "$S/mate.inbox/003.msg")
send mate --expect ack "fyi: rotate the logs"; ACK2=$(corr_of_inbox "$S/mate.inbox/004.msg")
expect_wake S8-mixed-corr-note-wakes "note: corr=$ACK2 noted; corr=$ANS2 two PRs are stale"
drain_and_ack "$TMP/d8.txt" >/dev/null

URL=https://github.com/o/r/pull/7
READY="done [key=child-pr-kid]: child kid PR ready: $URL mode=no-mistakes yolo=off"
OUTCOME="done [key=child-outcome-kid-done-0123abcd]: child kid done: shipped pr=$URL mode=no-mistakes yolo=off"
say "S9 first PR-ready done line wakes"
expect_wake S9-first-pr-ready-wakes "$READY"
drain_and_ack "$TMP/d9.txt" >/dev/null
say "S10 ledger done line repeating the same PR fact is absorbed"
expect_absorbed S10-duplicate-done-absorbed "$OUTCOME"
say "S11 adversarial: a repeat carrying report= wakes"
expect_wake S11-duplicate-with-report-wakes "$OUTCOME report=data/kid/report.md"
drain_and_ack "$TMP/d11.txt" >/dev/null
say "S12 adversarial: a merge for a different PR wakes"
expect_wake S12-different-pr-merge-wakes "done [key=merged-kid]: merged kid https://github.com/o/r/pull/8"
drain_and_ack "$TMP/d12.txt" >/dev/null

echo; echo "=== RESULTS ==="; cat "$RESULTS"
