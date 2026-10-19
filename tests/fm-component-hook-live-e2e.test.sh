#!/usr/bin/env bash
# Opt-in credentialed live check for the component hook that bin/fm-spawn.sh
# installs (docs/component-skills.md), once per harness wiring. For each case
# the real fm-spawn writes a fixture crewmate worktree's hook wiring against a
# fake tmux pane: Claude's .claude/settings.local.json, or Pi's per-task
# extension state/<id>.pi-ext.ts. A real `claude -p`, or a real Pi session
# driven over `pi --mode rpc` so it can also compact, then reads a mapped file
# in that worktree, and its transcript must show the component goal arriving
# through the installed wiring: a nonce that exists only in the component
# skill's goal reaches the model (Claude repeats it; Pi's read result carries
# it), without the skill file itself ever being read.
# FM_COMPONENT_HOOK_LIVE_HARNESSES picks the cases (default "claude pi"); a
# requested harness that is not installed fails rather than skips.
# The project, home and hook records are isolated; each harness keeps using its
# existing authentication and default model. No live fleet home, worktree, or
# session is touched.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

fm_live_gate opt-in FM_COMPONENT_HOOK_LIVE_E2E jq

LAB=$(fm_test_tmproot fm-component-hook-live-e2e)
NONCE="nonce-$$-$(date +%s)"
export FM_COMPONENT_STATE_DIR="$LAB/component-state"
PROMPT='Use the read tool exactly once, on src/ledger/store.py. Use no other tool and read no other file. Then reply with only the token that follows LEDGER-NONCE= in any component goal your context received after that read, or NONE if none arrived.'

# spawn_case <harness>: a spawn home, a mapped project and a worktree of it,
# spawned for <harness>. Sets HOME_DIR, WT and ID.
spawn_case() {
  local harness=$1 proj fakebin out
  HOME_DIR="$LAB/$harness/home"
  proj="$LAB/$harness/project"
  ID="comp-live-$harness"
  fakebin=$(make_spawn_fakebin "$LAB/$harness/fake" "$harness")
  fm_test_spawn_home "$HOME_DIR" "$harness"
  fm_git_init_commit "$proj"
  mkdir -p "$proj/docs" "$proj/.agents/skills/ledger" "$proj/src/ledger"
  cat >"$proj/.agents/skills/ledger/SKILL.md" <<EOF
---
name: ledger
description: Load before changing the ledger. One owner.
---

# ledger

## Goal and operating principle
The ledger is append-only. LEDGER-NONCE=$NONCE-$harness

## Refuse
- Rewriting a past entry.

## Review
1. Is every change an append?
EOF
  printf '%s\n' '{"schema":"component-map/v1","components":[{"id":"ledger","skill":"ledger","paths":["src/ledger/**"]}]}' \
    >"$proj/docs/component-map.json"
  printf 'entries = []\n' >"$proj/src/ledger/store.py"
  git -C "$proj" add -A
  git -C "$proj" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm map
  fm_git_add_origin "$proj" "$proj.origin.git"
  git -C "$proj" worktree add --quiet -b "wt-live-$harness" "$LAB/$harness/wt"
  WT=$(cd "$LAB/$harness/wt" && pwd -P)
  fm_test_spawn_brief "$HOME_DIR" "$ID"
  out=$(fm_test_run_spawn "$HOME_DIR" "$WT" "$fakebin" "$ID" "$proj" --mode no-mistakes --yolo off) \
    || fail "$harness fixture spawn failed: $out"
  assert_grep '## Component skills' "$HOME_DIR/data/$ID/launch-brief.md" "$harness spawn did not append the component section"
}

# check_reads <harness> <reads>: the model made exactly one tool call, a read
# of src/ledger/store.py; <reads> is one "name<TAB>path" line per call.
check_reads() {
  case $2 in
    *$'\n'* | '') fail "$1: the model must make exactly one tool call, a read of src/ledger/store.py; got: $2" ;;
    [Rr]ead$'\t'*src/ledger/store.py) ;;
    *) fail "$1: the model's one tool call must be a read of src/ledger/store.py; got: $2" ;;
  esac
}

live_claude() {
  local transcript="$LAB/claude.jsonl" reads result version
  spawn_case claude
  assert_present "$WT/.claude/settings.local.json" "spawn did not write the worktree's Claude settings"
  (
    cd "$WT" || exit 1
    FM_HOME="$HOME_DIR" CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false CLAUDE_CODE_SEND_FEEDBACK=0 \
      claude -p "$PROMPT" --dangerously-skip-permissions --settings '{"feedbackDrafts":"off"}' \
      --effort low --output-format stream-json --verbose
  ) >"$transcript" 2>&1 || fail "claude session failed: $(tail -20 "$transcript")"
  reads=$(jq -r 'select(.type == "assistant") | .message.content[]? | select(.type == "tool_use") | "\(.name)\t\(.input.file_path // "")"' \
    "$transcript" 2>/dev/null)
  check_reads claude "$reads"
  result=$(jq -r 'select(.type == "result") | .result' "$transcript" 2>/dev/null)
  version=$(claude --version)
  assert_contains "$result" "$NONCE-claude" "the component goal did not reach claude through the installed hook (claude $version)"
  pass "a real claude -p in a spawned crewmate worktree receives the component goal through the installed hook (claude $version)"
}

# Pi runs over its RPC mode with only the spawned extension loaded (no context
# files, skills or discovered extensions) and only the read tool, so the goal
# can arrive only through the extension's tool_result handler. Three reads
# cover what the hook's once-per-session record depends on: the first read's
# result carries the goal, a second read's stays silent, and after a real
# compaction (the extension's session_compact handler) a third read's carries
# it again. The record directory must be named by the session id Pi reports.
pi_send() { printf '%s\n' "$1" >&7; }

# pi_wait <jq-filter> <count>: wait up to 300s for <count> transcript records
# matching <jq-filter>.
pi_wait() {
  local i=0 n
  while [ "$i" -lt 600 ]; do
    n=$(jq -c "select($1)" "$PI_TRANSCRIPT" 2>/dev/null | grep -c .)
    [ "$n" -ge "$2" ] && return 0
    kill -0 "$PI_PID" 2>/dev/null || fail "pi exited early: $(tail -20 "$PI_TRANSCRIPT")"
    sleep 0.5
    i=$((i + 1))
  done
  fail "pi timed out waiting for $2 x $1: $(tail -20 "$PI_TRANSCRIPT")"
}

pi_read() {  # <settled-count-after>
  pi_send "$(jq -nc --arg m 'Use the read tool exactly once, on src/ledger/store.py. Use no other tool and read no other file. Then reply with only DONE.' '{type:"prompt", message:$m}')"
  pi_wait '.type == "agent_settled"' "$1"
}

live_pi() {
  local ext reads results session version
  PI_TRANSCRIPT="$LAB/pi.jsonl"
  spawn_case pi
  ext="$HOME_DIR/state/$ID.pi-ext.ts"
  assert_present "$ext" "spawn did not write the per-task Pi extension"
  mkfifo "$LAB/pi.in"
  (
    cd "$WT" || exit 1
    exec env FM_HOME="$HOME_DIR" pi --mode rpc --session-dir "$LAB/pi-sessions" --no-context-files \
      --no-extensions --no-skills --tools read -e "$ext"
  ) <"$LAB/pi.in" >"$PI_TRANSCRIPT" 2>&1 &
  PI_PID=$!
  exec 7>"$LAB/pi.in"
  trap 'exec 7>&-; kill "$PI_PID" 2>/dev/null; fm_test_cleanup' EXIT
  pi_read 1
  pi_read 2
  pi_send '{"type":"compact"}'
  pi_wait '.type == "response" and .command == "compact"' 1
  jq -e 'select(.type == "response" and .command == "compact") | .success' "$PI_TRANSCRIPT" >/dev/null \
    || fail "pi compaction failed: $(tail -20 "$PI_TRANSCRIPT")"
  pi_read 3
  pi_send '{"type":"get_state"}'
  pi_wait '.type == "response" and .command == "get_state"' 1
  session=$(jq -r 'select(.type == "response" and .command == "get_state") | .data.sessionId // ""' "$PI_TRANSCRIPT")
  exec 7>&-
  wait "$PI_PID" 2>/dev/null
  trap fm_test_cleanup EXIT

  reads=$(jq -r 'select(.type == "tool_execution_start") | "\(.toolName)\t\(.args.path // "")"' "$PI_TRANSCRIPT" 2>/dev/null)
  [ "$(printf '%s\n' "$reads" | grep -c .)" = 3 ] || fail "pi: the model must make exactly three tool calls, one read per prompt; got: $reads"
  while IFS= read -r line; do check_reads pi "$line"; done <<<"$reads"
  results=$(jq -c 'select(.type == "message_end" and .message.role == "toolResult") | [.message.content[]? | select(.type == "text") | .text] | join("\n")' \
    "$PI_TRANSCRIPT" 2>/dev/null)
  version=$(pi --version 2>&1)
  [ "$(printf '%s\n' "$results" | grep -c .)" = 3 ] || fail "pi: expected three read results, got: $results"
  assert_contains "$(sed -n 1p <<<"$results")" "$NONCE-pi" "the first read's result did not carry the component goal through the spawned extension (pi $version)"
  case $(sed -n 2p <<<"$results") in
    *"$NONCE-pi"*) fail "a second read in the same Pi session repeated the component goal: the session id did not hold (pi $version)" ;;
  esac
  assert_contains "$(sed -n 3p <<<"$results")" "$NONCE-pi" "the goal did not return after a real Pi compaction: session_compact did not reset the record (pi $version)"
  [ -n "$session" ] || fail "pi get_state reported no session id"
  [ -d "$FM_COMPONENT_STATE_DIR/$(printf '%s' "$session" | LC_ALL=C tr -c 'A-Za-z0-9._-' '_' | cut -c1-120)" ] \
    || fail "the hook's record is not keyed by Pi's session id $session: $(ls "$FM_COMPONENT_STATE_DIR")"
  pass "a real Pi session in a spawned crewmate worktree gets the component goal once per session id and again after compaction (pi $version)"
}

for harness in ${FM_COMPONENT_HOOK_LIVE_HARNESSES:-claude pi}; do
  case $harness in
    claude | pi) ;;
    *) fail "FM_COMPONENT_HOOK_LIVE_HARNESSES: unknown harness '$harness' (expected claude or pi)" ;;
  esac
  command -v "$harness" >/dev/null 2>&1 \
    || fail "FM_COMPONENT_HOOK_LIVE_E2E requested the $harness case but $harness is not installed"
  "live_$harness"
done
