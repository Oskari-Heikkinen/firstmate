#!/usr/bin/env bash
# Opt-in live guard for fm-control's answer to Claude Code's "Background work is
# running" exit dialog, and for its check that no session of the old agent
# survives the exit, run against the installed Claude Code in a private tmux
# server. A real agent gets a real background shell through bash mode and
# Ctrl+B (no model turn is submitted), then the real bin/fm-control.sh exit runs
# against a task record for that pane. It proves the adapter's rendered dialog
# signals still match the installed version: the exit is refused by name with
# the dialog closed and the agent and its shell still running. It then proves
# the session-record signal the survivor check reads: the running agent's own
# record must classify as a proven live session in its copy. When the dialog
# offers "Move to background and exit", the guard picks it by hand, requires
# the detached session to classify as live, and requires fm-control exit to
# stop it. A plain stop without the dialog fails, so a renamed or vanished
# dialog cannot pass as checked. Claude keeps its existing authentication and
# trusts one temporary folder.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-control-lib.sh
. "$ROOT/bin/fm-control-lib.sh"

fm_live_gate opt-in FM_CLAUDE_EXIT_DIALOG_LIVE_E2E claude tmux

CLAUDE_VERSION=$(claude --version 2>/dev/null || true)
[ -n "$CLAUDE_VERSION" ] || fail "claude is installed but reports no version"
LAB=$(fm_test_tmproot fm-control-claude-exit-live)
mkdir -p "$LAB"
LAB=$(cd "$LAB" && pwd)
# A private tmux server: fm-control's tmux backend and this test both reach it
# through the default socket under TMUX_TMPDIR, never the operator's server.
export TMUX_TMPDIR="$LAB/tmux"
unset TMUX
mkdir -p "$TMUX_TMPDIR"
SESSION=fmlive
ID=t1
TARGET="$SESSION:fm-$ID"
WT="$LAB/wt"
HOME_DIR="$LAB/home"
# Unique so the background shell is found, and cleaned up, by its exact argv.
SLEEP_ARG="9$$"
SESSIONS="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/sessions"

live_sessions() {
  fm_control_claude_live_sessions "$SESSIONS" "$WT"
}

cleanup() {
  local verdict pid rest
  # A detached session this guard created by hand must not outlive it; only
  # sessions whose cwd is this lab's copy are ever listed.
  while IFS=$'\t' read -r verdict pid rest; do
    [ "$verdict" = proven ] && kill "$pid" 2>/dev/null
  done < <(live_sessions 2>/dev/null)
  tmux kill-server 2>/dev/null || true
  pkill -x -f "sleep $SLEEP_ARG" 2>/dev/null || true
  rm -rf "$LAB" 2>/dev/null || true
  fm_test_cleanup
}
trap cleanup EXIT

fm_git_worktree "$LAB/proj" "$WT" "task-$ID"
mkdir -p "$HOME_DIR/state" "$HOME_DIR/data/$ID"
printf '# brief for %s\n' "$ID" > "$HOME_DIR/data/$ID/brief.md"
cat > "$HOME_DIR/state/$ID.meta" <<EOF
window=$TARGET
endpoint_task_id=$ID
worktree=$WT
project=$LAB/proj
harness=claude
kind=ship
mode=no-mistakes
yolo=off
model=default
effort=default
EOF
[ -z "${CLAUDE_CONFIG_DIR:-}" ] \
  || printf 'claude_config_dir=%s\n' "$CLAUDE_CONFIG_DIR" >> "$HOME_DIR/state/$ID.meta"

screen() {
  tmux capture-pane -p -t "$TARGET" 2>/dev/null || true
}

# Claude Code refuses to nest inside another Claude session.
unset_inherited() {
  local name
  while IFS= read -r name; do
    printf -- '-u %s ' "$name"
  done < <(env | grep -E '^(CLAUDECODE|CLAUDE_CODE_[A-Z_]+)=' | cut -d= -f1 | sort -u)
}

# Wait for <text>, answering the folder-trust dialog (focused on "No, exit")
# by moving onto the trusting option before Enter.
wait_screen() {  # <text> <what>
  local i=0 shot
  while [ "$i" -lt 240 ]; do
    shot=$(screen)
    case "$shot" in
      *'Yes, I trust this folder'*)
        if printf '%s\n' "$shot" | grep -F '❯' | grep -qF 'Yes, I trust this folder'; then
          tmux send-keys -t "$TARGET" Enter
        else
          tmux send-keys -t "$TARGET" Down
        fi
        ;;
      *"$1"*) return 0 ;;
    esac
    sleep 0.25
    i=$((i + 1))
  done
  printf '%s\n' "$(screen)" >&2
  fail "Claude Code $CLAUDE_VERSION never showed $2"
}

tmux new-session -d -s "$SESSION" -n "fm-$ID" -x 160 -y 44 -c "$WT"
tmux send-keys -t "$TARGET" -l "env $(unset_inherited) claude --model haiku"
tmux send-keys -t "$TARGET" Enter
wait_screen '? for shortcuts' 'its composer'
sleep 1

# A background shell without a model turn: bash mode, then Ctrl+B twice.
tmux send-keys -t "$TARGET" -l "!sleep $SLEEP_ARG"
sleep 0.5
tmux send-keys -t "$TARGET" Enter
wait_screen 'to run in background' 'the running bash-mode command'
tmux send-keys -t "$TARGET" C-b
sleep 0.3
tmux send-keys -t "$TARGET" C-b
wait_screen 'manually backgrounded' 'the backgrounded shell'
sleep 1
pgrep -x -f "sleep $SLEEP_ARG" >/dev/null \
  || fail "the background shell is not running before exit"

out=$(env FM_HOME="$HOME_DIR" "$ROOT/bin/fm-control.sh" "$ID" exit 2>&1); rc=$?
case "$out" in
  *"'Background work is running' dialog"*"Chose Stay with Escape"*) ;;
  *)
    printf '%s\n' "$(screen)" >&2
    fail "Claude Code $CLAUDE_VERSION: fm-control exit did not refuse the background-work dialog it expected (rc=$rc): $out"
    ;;
esac
expect_code 1 "$rc" "a refused exit should fail"
wait_screen 'for shortcuts' 'its composer again after Stay'
screen | grep -qF 'Background work is running' \
  && fail "the refused exit should leave the dialog closed"
pgrep -x -f "sleep $SLEEP_ARG" >/dev/null \
  || fail "a refused exit must leave the background shell running"
pass "Claude Code $CLAUDE_VERSION: fm-control exit dismissed the background-work dialog and refused by name"

rows=$(live_sessions) || fail "the session records in $SESSIONS could not be read"
case "$rows" in
  proven*) ;;
  *) fail "Claude Code $CLAUDE_VERSION wrote no session record in $SESSIONS that proves the running agent in $WT (got: ${rows:-none}), so the survivor check would be blind" ;;
esac
pass "Claude Code $CLAUDE_VERSION: the running agent's session record classifies as a proven live session in its copy"

# Reproduce what the survivor check exists for: answer the dialog by hand with
# its background option, then fm-control exit must stop the session left behind.
tmux send-keys -t "$TARGET" -l "/exit"
sleep 0.5
tmux send-keys -t "$TARGET" Enter
wait_screen 'Background work is running' 'its exit dialog again'
if ! screen | grep -qF 'Move to background and exit'; then
  tmux send-keys -t "$TARGET" Escape
  pass "Claude Code $CLAUDE_VERSION: its exit dialog offers no 'Move to background and exit', so no detached session can be reproduced"
  exit 0
fi
i=0
until screen | grep -F '❯' | grep -qF 'Move to background and exit'; do
  [ "$i" -lt 8 ] || fail "Claude Code $CLAUDE_VERSION: focus never reached 'Move to background and exit'"
  tmux send-keys -t "$TARGET" Down
  sleep 0.5
  i=$((i + 1))
done
tmux send-keys -t "$TARGET" Enter
i=0
while screen | grep -qF 'Background work is running'; do
  [ "$i" -lt 120 ] || fail "Claude Code $CLAUDE_VERSION did not close its exit dialog after Move to background and exit"
  sleep 0.25
  i=$((i + 1))
done
sleep 2
rows=$(live_sessions)
pid=$(printf '%s\n' "$rows" | awk -F'\t' '$1 == "proven" { print $2; exit }')
[ -n "$pid" ] \
  || fail "Claude Code $CLAUDE_VERSION: no proven live session survives Move to background and exit (got: ${rows:-none}); the detached session no longer reproduces or its record changed, so re-check the survivor check against this version"
out=$(env FM_HOME="$HOME_DIR" "$ROOT/bin/fm-control.sh" "$ID" exit 2>&1); rc=$?
expect_code 0 "$rc" "exit should stop the detached session"$'\n'"$out"
assert_contains "$out" "session-stopped=$pid $ID harness=claude" \
  "exit should report the detached session it stopped"
rows=$(live_sessions)
[ -z "$rows" ] || fail "a live session of the old agent remains in $WT after exit: $rows"
pass "Claude Code $CLAUDE_VERSION: fm-control exit stopped the session that Move to background and exit left running"
