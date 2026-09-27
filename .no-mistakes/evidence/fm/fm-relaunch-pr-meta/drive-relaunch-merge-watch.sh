#!/usr/bin/env bash
# Live drive: a task with an armed PR merge-watch is relaunched through the real
# bin/fm-control.sh on a private, real tmux server, then one real bin/fm-watch.sh
# cycle checks whether the merge-watch is still accepted.
#
# Usage: drive-relaunch-merge-watch.sh <firstmate-root> <label> <trace on|off> [relaunch count]
# Isolation: scratch FM_HOME, git repo, HOME, and a private tmux socket under a
# mktemp dir; the only forge access is a local `gh` stub.
set -u
ROOT=$1 LABEL=$2 TRACE=$3 RELAUNCHES=${4:-1}
S=$(mktemp -d "/tmp/fm-live-relaunch-$LABEL.XXXXXX")
ID=rl$((RANDOM % 900 + 100))
SOCK="$S/tmux.sock"
HOME_DIR="$S/home"; STATE="$HOME_DIR/state"
PROJ="$S/proj"; WT="$S/wt"; FB="$S/fakebin"; WFB="$S/watchbin"
mkdir -p "$STATE" "$HOME_DIR/data/$ID" "$FB" "$WFB" "$S/user-home"
cleanup() { /usr/bin/tmux -S "$SOCK" kill-server 2>/dev/null; rm -rf "$S" "/tmp/fm-$ID"; }
trap cleanup EXIT

# Real project repo + task worktree.
git init -q -b main "$PROJ"
git -C "$PROJ" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
git init -q --bare "$PROJ.origin.git"; git -C "$PROJ" remote add origin "$PROJ.origin.git"
git -C "$PROJ" push -q origin main
git -C "$PROJ" worktree add -q -b "task-$ID" "$WT"
git -C "$WT" -c user.name=t -c user.email=t@t commit -q --allow-empty -m work
HEAD_SHA=$(git -C "$WT" rev-parse HEAD)

# Real tmux, private socket.
cat > "$FB/tmux" <<EOF
#!/bin/bash
exec /usr/bin/tmux -S "$SOCK" "\$@"
EOF
# Stand-in claude TUI: a bordered composer with the cursor inside; /exit quits.
cat > "$S/claude-impl" <<'EOF'
# Like the real TUI, an Escape key press is consumed, not echoed as input.
stty -echoctl 2>/dev/null
while :; do
  printf '\033[2J\033[H╭──────────────╮\n│              │\n╰──────────────╯\033[1A\033[3G'
  IFS= read -r l || exit 0
  l=${l//$'\e'/}
  [ "$l" = /exit ] && exit 0
done
EOF
cat > "$FB/claude" <<EOF
#!/bin/bash
exec -a claude /bin/bash "$S/claude-impl" "\$@"
EOF
# Forge stub: the only non-local dependency of fm-pr-check.sh and the poll.
cat > "$FB/gh" <<EOF
#!/bin/bash
case "\$*" in
  *'--json isDraft'*) echo '{"isDraft":false}' ;;
  *'--json headRefOid'*) echo "$HEAD_SHA" ;;
  *'--json state'*) echo "\${FM_TEST_GH_STATE:-OPEN}" ;;
  *) exit 1 ;;
esac
EOF
cp "$FB/gh" "$WFB/gh"
printf '#!/bin/bash\nexit 0\n' > "$WFB/tmux"
chmod +x "$FB"/* "$WFB"/*

cat > "$HOME_DIR/data/$ID/brief.md" <<EOF
# Task
## Captain's intent
Live relaunch with a recorded PR.

## Firstmate spec
Keep the merge-watch valid.
EOF
cat > "$STATE/$ID.meta" <<EOF
window=fmses:fm-$ID
endpoint_task_id=$ID
worktree=$WT
project=$PROJ
harness=claude
kind=ship
mode=no-mistakes
yolo=off
tasktmp=/tmp/fm-$ID
model=default
effort=default
EOF

# Real agent pane: session fmses, window fm-<id>, running the stand-in claude.
env -u TMUX PATH="$FB:$PATH" HOME="$S/user-home" /usr/bin/tmux -S "$SOCK" -f /dev/null \
  new-session -d -s fmses -n "fm-$ID" -x 160 -y 40 -c "$WT" "bash --norc -i"
sleep 0.5
/usr/bin/tmux -S "$SOCK" send-keys -t "fmses:fm-$ID" 'claude' Enter
sleep 0.7

if [ "$TRACE" = on ]; then
  printf '%s\n' "$$" > "$STATE/.lock"
  printf '%s on\n' "$$" > "$STATE/.trace-context-effective"
fi

URL="https://github.com/example/repo/pull/${ID#rl}"
common_env=(env -u TMUX -u NO_MISTAKES_GATE -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_SESSION -u HERDR_SOCKET_PATH
  -u HERDR_TAB_ID -u HERDR_WORKSPACE_ID PATH="$FB:$PATH" FM_HOME="$HOME_DIR"
  HOME="$S/user-home" CLAUDE_CONFIG_DIR='' FM_SPAWN_NO_GUARD=1
  # Documented sandbox escape (bin/fm-gate-refuse-lib.sh): this runs inside a
  # no-mistakes gate, against a throwaway fleet on a private tmux socket.
  FM_GATE_REFUSE_BYPASS=1)

echo "== [$LABEL trace=$TRACE] fm-pr-check.sh $ID $URL"
"${common_env[@]}" "$ROOT/bin/fm-pr-check.sh" "$ID" "$URL" 2>&1 | sed 's/^/  /'
# The contribution observer is a separate check on the same PR; it is removed so
# the watcher cycle reports on the merge-watch alone.
rm -f "$STATE/contributions.check.sh"
echo "== meta before relaunch"; sed 's/^/  /' "$STATE/$ID.meta"

# The watcher exits on its first wake of any kind; unrelated wakes (downtime
# re-surface, signals) are printed and the next cycle runs, until the cycle that
# reports on this task's own PR poll.
watch_once() {
  local i out
  for i in 1 2 3 4 5 6; do
    rm -f "$STATE/.last-check"
    out=$(timeout 60 env -u NO_MISTAKES_GATE FM_GATE_REFUSE_BYPASS=1 FM_HOME="$HOME_DIR" \
      FM_ROOT_OVERRIDE="$ROOT" FM_CHECK_INTERVAL=0 \
      FM_POLL=0.02 FM_HEARTBEAT=999999 FM_SIGNAL_GRACE=0 FM_TEST_GH_STATE=MERGED \
      PATH="$WFB:$PATH" "$ROOT/bin/fm-watch.sh" 2>/dev/null | head -3)
    printf '%s\n' "$out" | sed "s/^/  watcher cycle $i: /"
    case "$out" in *"$ID.check.sh"*) return 0 ;; esac
  done
}
artifacts_check() {
  ( . "$ROOT/bin/fm-pr-lib.sh"
    if fm_pr_poll_artifacts_valid "$STATE" "$ID" "$ROOT/bin/fm-pr-poll.sh"; then
      echo "== fm_pr_poll_artifacts_valid ($1): ACCEPTED"
    else
      echo "== fm_pr_poll_artifacts_valid ($1): REJECTED"
    fi )
}
artifacts_check "before relaunch"

echo "== pane before relaunch: $(/usr/bin/tmux -S "$SOCK" display-message -p -t "fmses:fm-$ID" '#{pane_current_command}')"
for n in $(seq 1 "$RELAUNCHES"); do
  echo "== fm-control.sh $ID relaunch --note ... (#$n)"
  "${common_env[@]}" "$ROOT/bin/fm-control.sh" "$ID" relaunch --note "waiting on the PR merge" 2>&1 | sed 's/^/  /'
  echo "  rc=${PIPESTATUS[0]}"
  sleep 1
  echo "  pane after relaunch #$n:"
  /usr/bin/tmux -S "$SOCK" capture-pane -p -t "fmses:fm-$ID" | grep -v '^$' | tail -5 | cut -c1-150 | sed 's/^/    | /'
  if [ "$n" -lt "$RELAUNCHES" ]; then
    # The stand-in agent reads one line per submit; submit whatever the launch
    # left in its input so its composer is empty, as a real idle agent's would be.
    /usr/bin/tmux -S "$SOCK" send-keys -t "fmses:fm-$ID" Enter
    sleep 0.5
  fi
done
echo "== pane after relaunch: $(/usr/bin/tmux -S "$SOCK" display-message -p -t "fmses:fm-$ID" '#{pane_current_command}')"
echo "== meta after relaunch"; sed 's/^/  /' "$STATE/$ID.meta"

artifacts_check "after relaunch"
echo "== watcher cycle after relaunch (PR reported MERGED)"; watch_once
