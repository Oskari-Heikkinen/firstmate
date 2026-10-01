#!/usr/bin/env bash
# Opt-in live guard for fm-control's answer to Claude Code's "Background work is
# running" exit dialog, run against the installed Claude Code in a private tmux
# server. A real agent gets a real background shell through bash mode and
# Ctrl+B (no model turn is submitted), then the real bin/fm-control.sh exit runs
# against a task record for that pane. It proves the adapter's rendered dialog
# signals and focus proof still match the installed version: either the
# dialog offered "Move to background and exit" and the agent stopped while the
# background shell kept running, or it did not offer it and the exit was
# refused by name with the agent and the shell both still running. A plain stop
# without the dialog fails, so a renamed or vanished dialog cannot pass as
# checked. Claude keeps its existing authentication and trusts one temporary
# folder.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

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

cleanup() {
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
  "stopped background-work=kept $ID harness=claude"*)
    expect_code 0 "$rc" "exit through the background option should succeed"$'\n'"$out"
    pgrep -x -f "sleep $SLEEP_ARG" >/dev/null \
      || fail "Move to background and exit should leave the background shell running"
    pass "Claude Code $CLAUDE_VERSION: fm-control exit answered the background-work dialog and kept the shell"
    ;;
  *"'Background work is running' dialog"*"Chose Stay with Escape"*)
    expect_code 1 "$rc" "a refused exit should fail"
    assert_contains "$out" "offers no 'Move to background and exit' option" \
      "the only verified refusal is a dialog without the background option"
    wait_screen 'for shortcuts' 'its composer again after Stay'
    screen | grep -qF 'Background work is running' \
      && fail "the refused exit should leave the dialog closed"
    pgrep -x -f "sleep $SLEEP_ARG" >/dev/null \
      || fail "a refused exit must leave the background shell running"
    pass "Claude Code $CLAUDE_VERSION: fm-control exit refused the background-work dialog without its background option by name"
    ;;
  *)
    printf '%s\n' "$(screen)" >&2
    fail "Claude Code $CLAUDE_VERSION: fm-control exit did not meet the background-work dialog it expected (rc=$rc): $out"
    ;;
esac
