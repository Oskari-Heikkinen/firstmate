#!/usr/bin/env bash
# Opt-in credentialed Claude live regression for the Stop-owned auto-arm
# (bin/fm-claude-stop-autoarm.sh + bin/fm-turnend-guard.sh --claude).
# Proves, against the real installed Claude Code and the real tracked hook
# registration: a fresh session with in-flight work, no watcher, and a stale
# session lock receives the full session-start digest through the tracked
# SessionStart hook; session start reclaims the dead owner; at least two
# tokenless auto-arm and rewake cycles then complete with zero model-issued arm
# commands, each with its handling successor; the real hook's live claim owner
# descends from the session-lock pid and reads as open in every Stop-owned
# cycle; and the cooperative guard consumes no forced continuation while the
# hook's launch is healthy.
# The project and FM_HOME are isolated; Claude keeps using its existing managed
# authentication. No live fleet home, worktree, or session is touched.
# shellcheck disable=SC2016 # the model, not this test shell, reads the prompt text
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate opt-in FM_CLAUDE_LIVE_E2E claude

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

LAB="$ROOT/.claude-autoarm-live-e2e.$$"
PROJECT="$LAB/project"
HOME_DIR="$LAB/fmhome"
LIVE_OWNER_HOME="$LAB/live-owner-home"
TRANSCRIPT="$LAB/claude.jsonl"
CLAUDE_VERSION=$(claude --version)

cleanup() {
  rm -rf "$LAB"
}
trap cleanup EXIT

mkdir -p "$LAB"
# git clone of this worktree carries only committed state, so copy the
# working-tree surfaces under test (same pattern as the continuity live E2E).
git clone -q "$ROOT" "$PROJECT"
cp -R "$ROOT/bin/." "$PROJECT/bin/"
cp "$ROOT/.claude/settings.json" "$PROJECT/.claude/settings.json"
# The lab keeps the real tracked .claude/settings.json SessionStart run hook,
# Stop guard, and asyncRewake auto-arm registration.
# The only local hook records model-issued Bash calls without acquiring the
# session lock or otherwise changing lifecycle behavior.
cat > "$PROJECT/.claude/settings.local.json" <<'JSON'
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          { "type": "command", "command": "\"$CLAUDE_PROJECT_DIR\"/bin/tool-logger.sh" }
        ]
      }
    ]
  }
}
JSON

cat > "$PROJECT/bin/tool-logger.sh" <<'SH'
#!/usr/bin/env bash
P=$(cat 2>/dev/null || true)
printf '%s\n' "$P" | jq -r '.tool_input.command // "unknown"' >> "$FM_HOME/state/tool-calls.log" 2>/dev/null
exit 0
SH
chmod +x "$PROJECT/bin/tool-logger.sh"

mkdir -p "$HOME_DIR/state" "$HOME_DIR/config" "$HOME_DIR/data"
# This guard counts the plain arm's runs, so the home opts out of the
# supervision host a Claude home otherwise runs by default.
: > "$HOME_DIR/config/supervision-host-off"
printf 'project=fixture\nwindow=fixture\nbackend=tmux\n' > "$HOME_DIR/state/task.meta"
# A numeric pid above the supported OS pid range is a demonstrably dead prior
# harness owner under fm_harness_pid_alive, matching the reproduced incident.
printf '9999999\n' > "$HOME_DIR/state/.lock"

# Rapid-death arm fixture: started plus an immediate actionable reason, the
# exact spent-Stop edge shape. Stop-owned runs 1-2 close actionable; run 3
# closes clean so a misbehaving session can never loop forever. The handling
# successor the hook starts after each actionable close (it carries
# FM_WATCH_PREDECESSOR_ARM_PID) is logged apart and only confirms a watcher.
# Each Stop-owned run also records, from inside the real hook's process tree,
# whether the claim owner descends from the session-lock pid and whether the
# live claim reads as open, so the claim reachability predicate is proven
# against the real harness rather than the fake-claude fixture.
cat > "$PROJECT/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
if [ -n "${FM_WATCH_PREDECESSOR_ARM_PID:-}" ]; then
  echo "successor pid=$$ predecessor=$FM_WATCH_PREDECESSOR_ARM_PID" >> "$FM_HOME/state/successor-ran"
  printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
  exit 0
fi
N=$(cat "$FM_HOME/state/arm-count" 2>/dev/null || echo 0); N=$((N+1)); echo "$N" > "$FM_HOME/state/arm-count"
echo "arm-run=$N pid=$$" >> "$FM_HOME/state/arm-ran"
FM_STATE_OVERRIDE="$FM_HOME/state" bash -c '
  . "$1/fm-wake-lib.sh" || exit 1
  lock_pid=$(head -n 1 "$FM_STATE_OVERRIDE/.lock" 2>/dev/null)
  fm_autoarm_ledger_read "$FM_STATE_OVERRIDE" || { echo "claim-probe run=$2 ledger=unreadable"; exit 0; }
  descends=no; fm_pid_descends_from "$FM_AUTOARM_OWNER" "$lock_pid" && descends=yes
  open=no; fm_autoarm_claim_open "$FM_STATE_OVERRIDE" && open=yes
  echo "claim-probe run=$2 owner=$FM_AUTOARM_OWNER lock=$lock_pid descends=$descends open=$open"
' _ "$(cd "$(dirname "$0")" && pwd)" "$N" >> "$FM_HOME/state/claim-probe" 2>&1
if [ "$N" -ge 3 ]; then
  rm -f "$FM_HOME/state/task.meta"
  printf 'watcher: attached pid=%s (beacon 2s)\n' "$$"
  exit 0
fi
printf 'pending:downtime:fixture-generation-%s\n' "$N" > "$FM_HOME/state/.watcher-down"
touch "$FM_HOME/state/.last-watcher-beat"
printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
printf 'stale: fixture-rapid-%s\n' "$N"
exit 0
SH
# Drain fixture: session start invokes it once, then the model invokes it once
# per rewake. The third total drain ends the in-flight need after two complete
# Stop-owned cycles.
cat > "$PROJECT/bin/fm-wake-drain.sh" <<'SH'
#!/usr/bin/env bash
N=$(cat "$FM_HOME/state/drain-count" 2>/dev/null || echo 0); N=$((N+1)); echo "$N" > "$FM_HOME/state/drain-count"
echo "drain-run=$N" >> "$FM_HOME/state/drain-ran"
if [ "$N" -ge 3 ]; then
  rm -f "$FM_HOME/state/task.meta"
fi
printf 'stale: fixture-rapid drained\n'
SH
chmod +x "$PROJECT/bin/fm-watch-arm.sh" "$PROJECT/bin/fm-wake-drain.sh"

PROMPT='After reading the complete session-start digest, reply with exactly CYCLE0 and stop. Whenever a Stop hook feedback message wakes you, run exactly `bin/fm-wake-drain.sh` once with Bash, then reply with exactly ACK and stop. Never run bin/fm-watch-arm.sh or any other arm command, and never use any other tool.'

(
  cd "$PROJECT" || exit 1
  FM_HOME="$HOME_DIR" CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false CLAUDE_CODE_SEND_FEEDBACK=0 \
    claude -p "$PROMPT" --dangerously-skip-permissions --settings '{"feedbackDrafts":"off"}' \
    --effort low --output-format stream-json --verbose
) > "$TRANSCRIPT" 2>&1 || fail "Claude credentialed auto-arm session failed: $(tail -20 "$TRANSCRIPT")"

# The evidence is printed before any assertion, so it survives the lab's
# EXIT-trap cleanup whatever the verdict.
for evidence in arm-ran successor-ran claim-probe; do
  sed "s/^/evidence $evidence: /" "$HOME_DIR/state/$evidence" 2>/dev/null || printf 'evidence %s: (none)\n' "$evidence"
done
for evidence in .claude-autoarm-epoch .turnend-claude-blocks; do
  sed "s/^/evidence $evidence: /" "$HOME_DIR/state/$evidence" 2>/dev/null || printf 'evidence %s: (none)\n' "$evidence"
done
# The turn order, one line per message or hook response, so a guard block or an
# extra cycle can be placed against the arms above after the lab is gone.
jq -r '
  if .type == "user" then
    "user: " + ([.message.content[]? | select(.type == "text") | .text | split("\n")[0:3] | join(" / ")] | join(" | "))
  elif .type == "assistant" then
    "assistant: " + ([.message.content[]? | if .type == "text" then .text elif .type == "tool_use" then "tool " + (.input.command // .name) else empty end] | join(" | "))
  elif .type == "system" and .subtype == "hook_response" then
    "hook " + (.hook_event // "?") + " " + (.hook_name // "") + " exit=" + ((.exit_code // "?") | tostring)
  else empty end
' "$TRANSCRIPT" 2>/dev/null | cut -c1-240 | sed 's/^/evidence turns: /'
ARM_RUNS=$(wc -l < "$HOME_DIR/state/arm-ran" 2>/dev/null | tr -d ' ')
[ "$ARM_RUNS" = 2 ] || fail "expected exactly 2 Stop-owned arm cycles, got $ARM_RUNS: $(cat "$HOME_DIR/state/arm-ran" 2>/dev/null)"
SUCCESSOR_RUNS=$(wc -l < "$HOME_DIR/state/successor-ran" 2>/dev/null | tr -d ' ')
[ "$SUCCESSOR_RUNS" = 2 ] || fail "expected one handling successor per actionable cycle (2), got ${SUCCESSOR_RUNS:-0}"
[ "$(grep -c 'descends=yes open=yes$' "$HOME_DIR/state/claim-probe" 2>/dev/null)" = 2 ] \
  || fail "the real Stop hook's live claim was not reachable from the session-lock pid in every Stop-owned cycle: $(cat "$HOME_DIR/state/claim-probe" 2>/dev/null)"
DRAIN_RUNS=$(wc -l < "$HOME_DIR/state/drain-ran" 2>/dev/null | tr -d ' ')
[ "$DRAIN_RUNS" = 3 ] || fail "expected one session-start drain plus two model wake drains, got $DRAIN_RUNS drains"
REWAKES=$(jq -r '
  select(.type == "user")
  | .message.content[]?
  | select(.type == "text")
  | .text
' "$TRANSCRIPT" 2>/dev/null | awk '/^Stop hook feedback:/{count++} END{print count+0}')
[ "$REWAKES" -ge 2 ] || fail "expected at least 2 exit-2 rewake deliveries, got $REWAKES"
grep -q 'stale: fixture-rapid-1' "$TRANSCRIPT" || fail "first rapid rewake reason missing from the transcript"
grep -q 'stale: fixture-rapid-2' "$TRANSCRIPT" || fail "second rapid rewake reason missing from the transcript"
[ -s "$HOME_DIR/state/tool-calls.log" ] \
  || fail "Claude emitted no logged Bash tool calls"
! grep -q 'fm-session-start.sh' "$HOME_DIR/state/tool-calls.log" \
  || fail "model issued a redundant session-start command: $(cat "$HOME_DIR/state/tool-calls.log")"
DIGEST_EVENTS=$(jq -c --arg heading "SESSION START - $HOME_DIR" '
  select(.type == "system" and .subtype == "hook_response" and .hook_event == "SessionStart")
  | select(.stdout | contains($heading))
' "$TRANSCRIPT" 2>/dev/null)
[ "$(printf '%s' "$DIGEST_EVENTS" | jq -s 'length')" = 1 ] \
  || fail "expected exactly one SessionStart hook_response carrying the session-start digest"
DIGEST=$(printf '%s' "$DIGEST_EVENTS" | jq -r '.stdout')
printf '%s' "$DIGEST" | grep -q '^lock acquired: harness pid [0-9][0-9]*$' \
  || fail "SessionStart hook digest lacks the stale-lock reclaim"
! printf '%s' "$DIGEST" | grep -q '^●  STARTUP TRUNCATED - ' \
  || fail "SessionStart hook digest was truncated"
printf '%s' "$DIGEST" | grep -qx 'END OF SESSION START DIGEST' \
  || fail "SessionStart hook digest lacks its completion marker"
[ "$(cat "$HOME_DIR/state/.lock" 2>/dev/null)" != 9999999 ] \
  || fail "session start did not reclaim the stale dead-owner lock"
if [ -f "$HOME_DIR/state/tool-calls.log" ]; then
  ! grep -q 'fm-watch-arm.sh' "$HOME_DIR/state/tool-calls.log" \
    || fail "model issued an arm command despite Stop-owned continuity: $(cat "$HOME_DIR/state/tool-calls.log")"
  ! grep -q '&' "$HOME_DIR/state/tool-calls.log" \
    || fail "model used a shell ampersand: $(cat "$HOME_DIR/state/tool-calls.log")"
fi
! grep -q 'TURN WOULD END BLIND' "$TRANSCRIPT" \
  || fail "cooperative guard consumed a forced continuation while the auto-arm launch was healthy"
[ "$(sed -n 's/^.*outcome=\([a-z][a-z]*\) .*$/\1/p' "$HOME_DIR/state/.claude-autoarm-epoch" 2>/dev/null)" = rewake ] \
  || fail "auto-arm epoch ledger must record the rewake outcome"
[ ! -e "$HOME_DIR/state/.claude-autoarm.lock" ] || fail "auto-arm owner lock was left behind"

# Live-owner negative control: a separate supported-harness process owns a
# second isolated home while another Stop hook fires from the same primary
# project. The competing hook must not replace the session lock, arm, write an
# epoch, or rewake. The owner lives until the hook has returned (a 60 s cap is
# only a hang guard): an owner that exits first leaves a stale lock, which the
# hook rightly recovers when this test runs under a real harness ancestry.
FAKE_CLAUDE="$LAB/claude"
ln -s /bin/bash "$FAKE_CLAUDE"
mkdir -p "$LIVE_OWNER_HOME/state" "$LIVE_OWNER_HOME/config"
: > "$LIVE_OWNER_HOME/config/supervision-host-off"
printf 'project=fixture\n' > "$LIVE_OWNER_HOME/state/task.meta"
# shellcheck disable=SC2016 # Expanded by the owner shell, not here.
LIVE_OWNER_RELEASE="$LAB/live-owner-release" "$FAKE_CLAUDE" -c '
  for _ in $(seq 1 600); do [ -e "$LIVE_OWNER_RELEASE" ] && break; sleep 0.1; done' &
LIVE_OWNER_PID=$!
printf '%s\n' "$LIVE_OWNER_PID" > "$LIVE_OWNER_HOME/state/.lock"
LIVE_OWNER_RC=0
printf '%s\n' '{"session_id":"live-owner-control"}' \
  | FM_HOME="$LIVE_OWNER_HOME" FM_ROOT_OVERRIDE="$PROJECT" "$FAKE_CLAUDE" -c '"$FM_ROOT_OVERRIDE/bin/fm-claude-stop-autoarm.sh"' \
      >"$LAB/live-owner.out" 2>"$LAB/live-owner.err" || LIVE_OWNER_RC=$?
LIVE_OWNER_ALIVE=no
kill -0 "$LIVE_OWNER_PID" 2>/dev/null && LIVE_OWNER_ALIVE=yes
: > "$LAB/live-owner-release"
printf 'evidence live-owner: rc=%s owner=%s alive-after-hook=%s lock=%s\n' \
  "$LIVE_OWNER_RC" "$LIVE_OWNER_PID" "$LIVE_OWNER_ALIVE" "$(cat "$LIVE_OWNER_HOME/state/.lock" 2>/dev/null)"
cat "$LAB/live-owner.out" "$LAB/live-owner.err" 2>/dev/null | cut -c1-240 | sed 's/^/evidence live-owner output: /'
[ "$LIVE_OWNER_ALIVE" = yes ] || fail "the live-owner control's owner exited before its hook returned, so the control proved nothing"
[ "$LIVE_OWNER_RC" -eq 0 ] || fail "competing Stop hook returned $LIVE_OWNER_RC while another live session owned the home"
[ "$(cat "$LIVE_OWNER_HOME/state/.lock")" = "$LIVE_OWNER_PID" ] || fail "competing Stop hook replaced the live session owner"
[ ! -e "$LIVE_OWNER_HOME/state/arm-ran" ] || fail "competing Stop hook armed while another live session owned the home"
[ ! -e "$LIVE_OWNER_HOME/state/.claude-autoarm-epoch" ] || fail "competing Stop hook wrote an epoch while another live session owned the home"
[ ! -s "$LAB/live-owner.out" ] && [ ! -s "$LAB/live-owner.err" ] || fail "competing Stop hook produced a rewake while another live session owned the home"
wait "$LIVE_OWNER_PID"

printf 'ok - Claude %s live E2E reclaimed a stale session lock through session start, completed two tokenless Stop-owned rewake cycles, and preserved the competing-live-owner boundary\n' "$CLAUDE_VERSION"
