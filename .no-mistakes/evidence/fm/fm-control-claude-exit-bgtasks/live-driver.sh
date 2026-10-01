#!/usr/bin/env bash
# Live driver: real Claude Code in a private tmux server, real bin/fm-control.sh
# against a marked disposable lab home. Usage: drive.sh <scenario> <bg:0|1> <quote:0|1> <verb>
set -u
SC=$1 BG=$2 QUOTE=$3 VERB=$4
REPO=/home/oskari/.no-mistakes/worktrees/ca1b14ddd4b9/01M3VT9YF7QBK605KNV9SH05WC
EV=/home/oskari/.no-mistakes/evidence/01M3VT9YF7QBK605KNV9SH05WC
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
"$REPO/bin/fm-lab-home.sh" create "$LAB" >/dev/null || exit 9
export TMUX_TMPDIR=$("$REPO/bin/fm-lab-home.sh" tmux-dir "$LAB")
unset TMUX
ID=t1 SESSION=fmlive; TARGET="$SESSION:fm-$ID"
WT=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab-wt.XXXXXX")
SLEEP_ARG="8$$"
LOG="$EV/$SC.transcript.txt"; FR="$EV/$SC.frames.txt"
: > "$LOG"; : > "$FR"
say() { printf '%s\n' "$*" | tee -a "$LOG"; }
cleanup() {
  [ -n "${RECPID:-}" ] && kill "$RECPID" 2>/dev/null
  tmux kill-server 2>/dev/null || true
  "$REPO/bin/fm-lab-home.sh" teardown "$LAB" >/dev/null 2>&1 || true
  pkill -x -f "sleep $SLEEP_ARG" 2>/dev/null || true
  rm -rf "$LAB" "$WT" "$WT.proj"
}
trap cleanup EXIT
git init -q "$WT.proj" && git -C "$WT.proj" commit -q --allow-empty -m init
rmdir "$WT"; git -C "$WT.proj" worktree add -q -b "task-$ID" "$WT"
mkdir -p "$LAB/data/$ID"; printf '# Task\n<!-- %s -->\n## Captain'"'"'s intent\n\nLive lab check only.\n\n## Firstmate spec\n\nReply with one word, hi, and do nothing else.\n' "$ID" > "$LAB/data/$ID/brief.md"
cat > "$LAB/state/$ID.meta" <<M
window=$TARGET
endpoint_task_id=$ID
worktree=$WT
project=$WT.proj
harness=claude
kind=ship
mode=no-mistakes
yolo=off
model=default
effort=default
M
screen() { tmux capture-pane -p -t "$TARGET" 2>/dev/null || true; }
wait_screen() {
  local i=0 shot
  while [ $i -lt 240 ]; do
    shot=$(screen)
    case "$shot" in
      *'Yes, I trust this folder'*)
        if printf '%s\n' "$shot" | grep -F '❯' | grep -qF 'Yes, I trust this folder'; then tmux send-keys -t "$TARGET" Enter; else tmux send-keys -t "$TARGET" Down; fi ;;
      *"$1"*) return 0 ;;
    esac
    sleep 0.25; i=$((i+1))
  done
  say "TIMEOUT waiting for $1"; screen >> "$LOG"; exit 1
}
unset_inherited() { env | grep -E '^(CLAUDECODE|CLAUDE_CODE_[A-Z_]+)=' | cut -d= -f1 | sort -u | sed 's/^/-u /' | tr '\n' ' '; }
tmux new-session -d -s "$SESSION" -n "fm-$ID" -x 160 -y 44 -c "$WT"
tmux send-keys -t "$TARGET" -l "env $(unset_inherited) claude --model haiku"; tmux send-keys -t "$TARGET" Enter
wait_screen '? for shortcuts'; sleep 1
if [ "$QUOTE" = 1 ]; then
  printf '   Background work is running\n   The following will stop when you exit:\n   shell · sleep 900\n   ❯ 1. Exit and stop tasks\n     2. Move to background and exit\n     3. Stay\n   Enter to confirm · Esc to cancel\n' > "$WT.quote"
  tmux send-keys -t "$TARGET" -l "!cat $WT.quote"; sleep 0.5; tmux send-keys -t "$TARGET" Enter
  wait_screen 'Move to background and exit'; sleep 1.5
fi
if [ "$BG" = 1 ]; then
  tmux send-keys -t "$TARGET" -l "!sleep $SLEEP_ARG"; sleep 0.5; tmux send-keys -t "$TARGET" Enter
  wait_screen 'to run in background'; tmux send-keys -t "$TARGET" C-b; sleep 0.3; tmux send-keys -t "$TARGET" C-b
  wait_screen 'manually backgrounded'; sleep 1
fi
say "== scenario $SC  (claude $(claude --version 2>/dev/null); background-shell=$BG quoted-dialog-in-transcript=$QUOTE verb=$VERB)"
say "== pane before: current_command=$(tmux display -p -t "$TARGET" '#{pane_current_command}')  bg-sleep-running=$(pgrep -x -f "sleep $SLEEP_ARG" >/dev/null && echo yes || echo no)"
say "== viewport before fm-control:"; screen | sed '/^$/d' | tee -a "$LOG"
( prev=; while :; do s=$(screen); if [ "$s" != "$prev" ]; then printf '\n----- frame %s -----\n%s\n' "$(date +%T.%N | cut -c1-12)" "$(printf '%s\n' "$s" | sed '/^$/d')" >> "$FR"; prev=$s; fi; sleep 0.1; done ) & RECPID=$!
start=$(date +%s.%N)
if [ "$VERB" = relaunch ]; then
  out=$(cd "$REPO" && env FM_HOME="$LAB" FM_ADMISSION=off bin/fm-control.sh "$ID" relaunch --note "live check: background shell running" 2>&1); rc=$?
else
  out=$(cd "$REPO" && env FM_HOME="$LAB" bin/fm-control.sh "$ID" "$VERB" 2>&1); rc=$?
fi
end=$(date +%s.%N)
sleep 2
kill "$RECPID" 2>/dev/null; RECPID=
say "== \$ FM_HOME=\$LAB bin/fm-control.sh $ID $VERB   (took $(awk -v a=$start -v b=$end 'BEGIN{printf "%.1fs", b-a}'))"
say "$out"; say "rc=$rc"
say "== pane after: current_command=$(tmux display -p -t "$(awk -F= '/^window=/{print $2}' "$LAB/state/$ID.meta")" '#{pane_current_command}' 2>/dev/null)  bg-sleep-running=$(pgrep -x -f "sleep $SLEEP_ARG" >/dev/null && echo yes || echo no)"
say "== dialog frames seen: $(grep -c 'Background work is running' "$FR")"
say "== viewport after:"; screen | sed '/^$/d' | tail -25 | tee -a "$LOG"
[ "$VERB" = relaunch ] && { say "== journal:"; cat "$LAB/state/$ID.control-relaunch" 2>/dev/null | tee -a "$LOG"; say "== meta after:"; cat "$LAB/state/$ID.meta" | tee -a "$LOG"; ls "$LAB/state" | tee -a "$LOG"; }
