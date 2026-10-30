#!/usr/bin/env bash
# Tests for bin/fm-wake-triage-replay.sh: the offline replay of recorded
# main-only wake rows through the wake-triage contract, and its score against
# main's recorded handling.
#
# The guarantees under test:
#   - Only one UTC day's `pass-through attended main-only` lines are rows, each
#     named h<log line>, and each gets exactly one shadow log line.
#   - A row whose class is not on the settle list is fast-relayed by code with
#     no engine turn; a listed row gets one tool-less engine turn, whose message
#     carries the probe result read from recorded state as of the row time plus
#     the lag (a loop alert cleared before or after it; a stuck-busy message
#     handled by then, or a target that did or did not write status after the
#     message was queued, the last pass marked proxy=yes).
#   - A failed engine turn (an error, a timeout, a pi stop on error, a turn
#     that used a tool, or no answer line for the row) is written as relay
#     with error= and exit 1, and a rerun retries only those rows; a
#     finished rerun runs no engine turn.
#   - A rerun under another model or other settings refuses.
#   - A missing or malformed settle list, one naming a class that always goes
#     to main, a missing host log and an --out from another model refuse,
#     naming them.
#   - --audit-fast-relay asks about code-routed rows without changing their
#     action, and a signal row's message carries its status span.
#   - The engine's system prompt carries the skill named by --skill (default
#     .agents/skills/wake-triage/SKILL.md), and an unreadable one refuses.
#   - The pi engine's JSON event stream is read.
#   - score types main's wake turns and states the exit test met or not met.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TR="$ROOT/bin/fm-wake-triage-replay.sh"
TMP_ROOT=$(fm_test_tmproot fm-wake-triage-replay-tests)
H="$TMP_ROOT/home"
mkdir -p "$H/state/loop-alerts" "$H/state/beta.inbox"
STUB_DIR="$TMP_ROOT/stub"
mkdir -p "$STUB_DIR"
export STUB_DIR

# 2026-10-29T00:00:00Z is 1793232000. Lines 2-8 are that day's main-only rows.
LOG="$H/state/.supervision-host.log"
{
  printf '1793232000\tstart\tgen=host-1-1793232000\tprimary=claude\n'
  printf '1793235600\tpass-through\tattended\tmain-only\tsignal: %s/state/alpha.status\n' "$H"
  printf '1793235700\tpass-through\tattended\tmain-only\tcheck: %s/state/mem-guard.check.sh: memory guard critical\n' "$H"
  printf '1793239200\tpass-through\tattended\tmain-only\tcheck: %s/state/loop-alerts.check.sh: source-unreadable--batches since 2026-10-29T01:59:50Z: batches source is unreadable\n' "$H"
  printf '1793242800\tpass-through\tattended\tmain-only\tcheck: %s/state/loop-alerts.check.sh: source-unreadable--batches since 2026-10-29T02:59:50Z: batches source is unreadable\n' "$H"
  printf '1793246400\tpass-through\tattended\tmain-only\tstale: firstmate:w1:p1 (unread firstmate instruction: stuck-busy after 2 consecutive busy-deferred due doorbells; %s/state/beta.inbox/7.msg stays unhandled and no doorbell was typed; inspect the worker)\n' "$H"
  printf '1793250000\tpass-through\tattended\tmain-only\tstale: firstmate:w1:p1 (unread firstmate instruction: stuck-busy after 2 consecutive busy-deferred due doorbells; %s/state/beta.inbox/8.msg stays unhandled and no doorbell was typed; inspect the worker)\n' "$H"
  printf '1793253600\tpass-through\tattended\tmain-only\tcheck: rearm-resurface\n'
  printf '1793253700\tpass-through\ta close without a wake\t\n'
  printf '1793318500\tpass-through\tattended\tmain-only\tcheck: rearm-resurface\n'
} > "$LOG"
cat > "$H/state/loop-alerts/log" <<'EOF'
2026-10-29T01:59:50Z raised again source-unreadable--batches: batches source is unreadable
2026-10-29T02:00:10Z cleared source-unreadable--batches: the condition no longer holds
2026-10-29T02:59:50Z raised again source-unreadable--batches: batches source is unreadable
2026-10-29T03:05:00Z cleared source-unreadable--batches: the condition no longer holds
EOF
printf 'schema=fm-task-inbox.v1\nat=2026-10-29T03:58:00Z\n--\nbody\n' > "$H/state/beta.inbox/7.msg"
printf 'schema=fm-task-inbox.v1\nat=2026-10-29T04:58:00Z\n--\nbody\n' > "$H/state/beta.inbox/8.msg"
printf 'working [at=1793245000]: before the message\nworking [at=1793246340]: still on the unit after the message\n' > "$H/state/beta.status"
printf 'working [at=1793230000]: before the day\nneeds-decision [at=1793235500]: pick A or B\n' > "$H/state/alpha.status"
printf '# test settle list\nstale:stuck-busy-inbox\ncheck:loop-alerts\ncheck:rearm-resurface\n' > "$TMP_ROOT/settle"

# A claude stand-in: settles when the probe passed, relays otherwise.
cat > "$STUB_DIR/claude" <<'EOF'
#!/bin/sh
msg=$2
printf '[%s]' "$@" > "$STUB_DIR/args"
prev=
for a in "$@"; do
  [ "$prev" = --system-prompt-file ] && cp "$a" "$STUB_DIR/system-prompt"
  prev=$a
done
seq=$(printf '%s\n' "$msg" | sed -n 's/^seq=\([^ ]*\) .*/\1/p' | head -n 1)
printf '%s\n' "$msg" > "$STUB_DIR/$seq.msg"
echo "$seq" >> "$STUB_DIR/calls"
case "${STUB_MODE:-}" in
  fail)
    printf '{"result":"boom","is_error":true,"total_cost_usd":0}'
    exit 1
    ;;
  otherseq)
    printf '{"result":"seq=h999 action=settle probe=x:pass note=n","total_cost_usd":0.01,"is_error":false}'
    exit 0
    ;;
  prose)
    printf '{"result":"I would settle this one.","total_cost_usd":0.01,"is_error":false}'
    exit 0
    ;;
  slow) exec sleep 5 ;;
  tool)
    printf '{"result":"seq=%s action=settle probe=x:pass note=n","total_cost_usd":0.01,"is_error":false,"num_turns":2}' "$seq"
    exit 0
    ;;
esac
case "$msg" in
  *result=pass*) a=settle p=probe:pass ;;
  *) a=relay p=none ;;
esac
printf '{"result":"seq=%s action=%s probe=%s note=stub answer","total_cost_usd":0.01,"is_error":false}' "$seq" "$a" "$p"
EOF
# A pi stand-in: relays every row through pi's JSON event stream.
cat > "$STUB_DIR/pi" <<'EOF'
#!/bin/sh
for a in "$@"; do msg=$a; done
seq=$(printf '%s\n' "$msg" | sed -n 's/^seq=\([^ ]*\) .*/\1/p' | head -n 1)
echo "$seq" >> "$STUB_DIR/pi-calls"
if [ "${STUB_MODE:-}" = error ]; then
  printf '{"type":"agent_end","messages":[{"role":"assistant","content":[{"type":"text","text":"seq=%s action=settle probe=x:pass note=n"}],"usage":{"cost":{"total":0}},"stopReason":"error","errorMessage":"rate limited"}]}\n' "$seq"
  exit 0
fi
if [ "${STUB_MODE:-}" = tool ]; then
  printf '{"type":"agent_end","messages":[{"role":"assistant","content":[{"type":"toolCall","name":"read"}]},{"role":"toolResult","content":[{"type":"text","text":"x"}]},{"role":"assistant","content":[{"type":"text","text":"seq=%s action=settle probe=x:pass note=n"}],"usage":{"cost":{"total":0.001}},"stopReason":"stop"}]}\n' "$seq"
  exit 0
fi
printf '{"type":"agent_start"}\n'
printf '{"type":"agent_end","messages":[{"role":"user","content":[]},{"role":"assistant","content":[{"type":"text","text":"seq=%s action=relay probe=none note=pi stub"}],"usage":{"cost":{"total":0.002}},"stopReason":"stop"}]}\n' "$seq"
EOF
chmod +x "$STUB_DIR/claude" "$STUB_DIR/pi"
export FM_WAKE_TRIAGE_CLAUDE_BIN="$STUB_DIR/claude" FM_WAKE_TRIAGE_PI_BIN="$STUB_DIR/pi"

replay() {  # <out> <args>...: sets OUT and RC
  local out=$1
  shift
  RC=0
  OUT=$("$TR" replay --home "$H" --day 2026-10-29 --settle-list "$TMP_ROOT/settle" --out "$out" --jobs 2 "$@" 2>&1) || RC=$?
}

calls() { if [ -f "$STUB_DIR/calls" ]; then wc -l < "$STUB_DIR/calls" | tr -d ' '; else echo 0; fi; }

field() {  # <file> <seq> <key>: the key's value on that seq's line
  awk -F'\t' -v s="seq=$2" -v k="$3=" '$2 == s { for (i = 3; i <= NF; i++) if (index($i, k) == 1) print substr($i, length(k) + 1) }' "$1"
}

test_refusals() {
  RC=0
  OUT=$("$TR" replay --home "$H" --day 2026-10-29 --engine claude --model m --settle-list "$TMP_ROOT/none" --out "$TMP_ROOT/r.tsv" 2>&1) || RC=$?
  expect_code 2 "$RC" "missing settle list"
  assert_contains "$OUT" "settle list $TMP_ROOT/none is unreadable" "a missing settle list is named"
  printf 'check:loop-alerts\nNot A Token\n' > "$TMP_ROOT/bad-settle"
  RC=0
  OUT=$("$TR" replay --home "$H" --day 2026-10-29 --engine claude --model m --settle-list "$TMP_ROOT/bad-settle" --out "$TMP_ROOT/r.tsv" 2>&1) || RC=$?
  expect_code 2 "$RC" "malformed settle list"
  assert_contains "$OUT" "settle list $TMP_ROOT/bad-settle line 2 is not a class token" "a malformed line is named by file and line"
  local cls
  for cls in check:mem-guard check:merge decision-span check:gh-auth-expiry; do
    printf 'check:loop-alerts\n%s\n' "$cls" > "$TMP_ROOT/main-settle"
    RC=0
    OUT=$("$TR" replay --home "$H" --day 2026-10-29 --engine claude --model m --settle-list "$TMP_ROOT/main-settle" --out "$TMP_ROOT/r.tsv" 2>&1) || RC=$?
    expect_code 2 "$RC" "settle list naming $cls"
    assert_contains "$OUT" "settle list $TMP_ROOT/main-settle line 2 names $cls, which always goes to main" "an always-to-main class ($cls) on the list refuses"
  done
  RC=0
  OUT=$("$TR" replay --home "$TMP_ROOT/nohome" --day 2026-10-29 --engine claude --model m --settle-list "$TMP_ROOT/settle" --out "$TMP_ROOT/r.tsv" 2>&1) || RC=$?
  expect_code 2 "$RC" "missing host log"
  assert_contains "$OUT" "host log $TMP_ROOT/nohome/state/.supervision-host.log is unreadable" "a missing host log is named"
  [ ! -e "$TMP_ROOT/r.tsv" ] || fail "a refusal wrote --out"
  assert_equals 0 "$(calls)" "a refusal ran no engine turn"
  pass "missing or malformed inputs refuse, naming them"
}

test_routes_and_probes() {
  local out="$TMP_ROOT/claude.tsv"
  replay "$out" --engine claude --model claude-sonnet-5-5 --effort high
  expect_code 0 "$RC" "replay with a working engine"
  assert_contains "$OUT" "7 row(s) for 2026-10-29 (2 fast-relay, 3 relay, 2 settle), 0 engine error(s)" "outcome line"
  assert_equals 7 "$(wc -l < "$out" | tr -d ' ')" "one line per main-only row of the day"
  assert_equals "h2 h3 h4 h5 h6 h7 h8" "$(cut -f2 "$out" | sed 's/seq=//' | tr '\n' ' ' | sed 's/ $//')" "rows are the day's main-only lines, in order"
  assert_equals 5 "$(calls)" "one engine turn per listed row, none for the others"
  assert_contains "$(field "$out" h2 class)/$(field "$out" h2 action)/$(field "$out" h2 model)" "decision-span/fast-relay/code" "a main-only signal row is a decision span, fast-relayed by code"
  assert_contains "$(field "$out" h3 class)/$(field "$out" h3 action)" "check:mem-guard/fast-relay" "an unlisted check is fast-relayed"
  assert_equals "pass settle" "$(field "$out" h4 evidence) $(field "$out" h4 action)" "an alert cleared before the probe time passes"
  assert_equals "fail relay" "$(field "$out" h5 evidence) $(field "$out" h5 action)" "an alert cleared after the probe time fails"
  assert_equals "pass settle yes" "$(field "$out" h6 evidence) $(field "$out" h6 action) $(field "$out" h6 proxy)" "a target that wrote status after the message was queued passes, as a proxy"
  assert_equals "" "$(field "$out" h4 proxy)$(field "$out" h7 proxy)" "a pass on the probe's own reading, or a fail, is not a proxy"
  assert_equals "fail relay" "$(field "$out" h7 evidence) $(field "$out" h7 action)" "a silent target with an unhandled message fails"
  assert_equals "unknown" "$(field "$out" h8 evidence)" "rearm-resurface is unknown from records"
  assert_equals "claude/claude-sonnet-5-5 engine" "$(field "$out" h4 model) $(field "$out" h4 route)" "a listed row names its model"
  assert_contains "$(cat "$STUB_DIR/h5.msg")" "result=fail; source-unreadable--batches was still raised at 2026-10-29T03:00:30Z" "the message carries the probe result at row time + 30 s"
  assert_contains "$(cat "$STUB_DIR/args")" "[--tools][][--model][claude-sonnet-5-5]" "the engine turn has no tools"
  assert_contains "$(cat "$STUB_DIR/args")" "[--effort][high]" "the effort is passed"
  assert_grep "replay start: day 2026-10-29, 7 main-only row(s)" "$out.log" "the log says what the run did"
  replay "$out" --engine claude --model claude-sonnet-5-5 --effort high
  expect_code 0 "$RC" "rerun"
  assert_equals 5 "$(calls)" "a finished rerun runs no engine turn"
  assert_equals 7 "$(wc -l < "$out" | tr -d ' ')" "a rerun doubles nothing"
  replay "$out" --engine claude --model another-model
  expect_code 2 "$RC" "another model's --out"
  assert_contains "$OUT" "was written by model claude/claude-sonnet-5-5, not claude/another-model" "an --out from another model refuses"
  replay "$out" --engine claude --model claude-sonnet-5-5 --effort high --probe-lag 60
  expect_code 2 "$RC" "another probe lag"
  assert_contains "$OUT" "was written under other settings" "an --out from another probe lag refuses"
  printf 'check:loop-alerts\n' > "$TMP_ROOT/settle-short"
  RC=0
  OUT=$("$TR" replay --home "$H" --day 2026-10-29 --settle-list "$TMP_ROOT/settle-short" --out "$out" --engine claude --model claude-sonnet-5-5 --effort high 2>&1) || RC=$?
  expect_code 2 "$RC" "another settle list"
  assert_contains "$OUT" "was written under other settings" "an --out from another settle list refuses"
  assert_equals 5 "$(calls)" "a settings refusal runs no engine turn"
  pass "unlisted rows are fast-relayed by code and listed rows judged on recorded probes"
}

test_handled_message_passes() {
  local h2="$TMP_ROOT/home2" out="$TMP_ROOT/handled.tsv" now day iso
  mkdir -p "$h2/state/gamma.inbox/handled"
  now=$(date +%s)
  iso=$(python3 -c 'import sys, time; print(time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(int(sys.argv[1]) - 60)))' "$now")
  printf 'schema=fm-task-inbox.v1\nat=%s\n--\nbody\n' "$iso" > "$h2/state/gamma.inbox/handled/3.msg"
  printf 'working [at=%s]: before the message\n' "$((now - 120))" > "$h2/state/gamma.status"
  # The row is stamped after the handled record exists, so the record's ctime
  # is at or before the row time plus the lag.
  now=$(date +%s)
  day=$(python3 -c 'import sys, time; print(time.strftime("%Y-%m-%d", time.gmtime(int(sys.argv[1]))))' "$now")
  printf '%s\tpass-through\tattended\tmain-only\tstale: firstmate:w2:p1 (unread firstmate instruction: stuck-busy after 2 consecutive busy-deferred due doorbells; %s/state/gamma.inbox/3.msg stays unhandled and no doorbell was typed; inspect the worker)\n' "$now" "$h2" > "$h2/state/.supervision-host.log"
  RC=0
  OUT=$("$TR" replay --home "$h2" --day "$day" --settle-list "$TMP_ROOT/settle" --out "$out" --engine claude --model m 2>&1) || RC=$?
  expect_code 0 "$RC" "replay of a handled message"
  assert_equals "pass settle " "$(field "$out" h1 evidence) $(field "$out" h1 action) $(field "$out" h1 proxy)" "a message handled by the probe time passes on its own reading"
  assert_contains "$(cat "$STUB_DIR/h1.msg")" "gamma handled inbox 3.msg by" "the message says the inbox record was handled"
  pass "a stuck-busy message handled by the probe time passes without a proxy"
}

test_engine_failure_is_relay_and_retried() {
  local out="$TMP_ROOT/fail.tsv"
  : > "$STUB_DIR/calls"
  STUB_MODE=fail replay "$out" --engine claude --model m
  expect_code 1 "$RC" "a failed engine turn"
  assert_equals 5 "$(grep -c 'error=' "$out")" "each failed turn is a line with error="
  assert_no_grep "action=settle" "$out" "a failed turn never settles"
  assert_equals "relay" "$(field "$out" h4 action)" "a failed turn relays"
  replay "$out" --engine claude --model m
  expect_code 0 "$RC" "rerun after failures"
  assert_equals 10 "$(calls)" "the rerun retried exactly the failed rows"
  assert_no_grep "error=" "$out" "the retried rows replaced their error lines"
  assert_equals 7 "$(wc -l < "$out" | tr -d ' ')" "still one line per row"
  pass "a failed engine turn is a relay with error= and a rerun retries it"
}

test_engine_failure_modes() {
  local mode want out
  for mode in otherseq prose slow tool; do
    case "$mode" in
      otherseq) want="no valid answer line for h4: seq=h999" ;;
      prose) want="no valid answer line for h4: I would settle this one." ;;
      slow) want="engine turn timed out after 1s" ;;
      tool) want="claude used a tool (num_turns=2)" ;;
    esac
    out="$TMP_ROOT/mode-$mode.tsv"
    STUB_MODE=$mode replay "$out" --engine claude --model m --turn-timeout 1
    expect_code 1 "$RC" "engine turns failing as $mode"
    assert_contains "$(field "$out" h4 action) $(field "$out" h4 error)" "relay $want" "a $mode turn is a relay with its error"
    assert_no_grep "action=settle" "$out" "a $mode turn never settles"
  done
  out="$TMP_ROOT/mode-pi-error.tsv"
  STUB_MODE=error replay "$out" --engine pi --model p
  expect_code 1 "$RC" "pi turns stopping on error"
  assert_contains "$(field "$out" h4 action) $(field "$out" h4 error)" "relay pi rc=0 stop=error: rate limited" "a pi stop on error is a relay with its error"
  assert_no_grep "action=settle" "$out" "a pi stop on error never settles"
  out="$TMP_ROOT/mode-pi-tool.tsv"
  STUB_MODE=tool replay "$out" --engine pi --model p
  expect_code 1 "$RC" "pi turns that used a tool"
  assert_contains "$(field "$out" h4 action) $(field "$out" h4 error)" "relay pi used a tool" "a pi turn that used a tool is a relay with its error"
  assert_no_grep "action=settle" "$out" "a pi turn that used a tool never settles"
  pass "every way an engine turn fails is a relay with error=, never a settle"
}

test_audit_and_span() {
  local out="$TMP_ROOT/audit.tsv"
  : > "$STUB_DIR/calls"
  replay "$out" --engine claude --model m --audit-fast-relay
  expect_code 0 "$RC" "audit run"
  assert_equals 7 "$(calls)" "audit asks about every row"
  assert_equals "fast-relay relay:stub answer" "$(field "$out" h2 action) $(field "$out" h2 audit)" "an audited row keeps its fast relay"
  assert_contains "$(cat "$STUB_DIR/h2.msg")" "needs-decision [at=1793235500]: pick A or B" "a signal row's message carries its span"
  assert_not_contains "$(cat "$STUB_DIR/h2.msg")" "before the day" "status lines before the span window are left out"
  pass "audit asks about code-routed rows without changing them"
}

test_pi_engine() {
  local out="$TMP_ROOT/pi.tsv"
  replay "$out" --engine pi --model openai-codex/gpt-6.1-sol --effort high
  expect_code 0 "$RC" "pi run"
  assert_equals 5 "$(wc -l < "$STUB_DIR/pi-calls" | tr -d ' ')" "pi ran the listed rows"
  assert_equals "relay pi/openai-codex/gpt-6.1-sol 0.0020" "$(field "$out" h4 action) $(field "$out" h4 model) $(field "$out" h4 cost)" "pi's answer and cost are read"
  pass "the pi engine's event stream is read"
}

test_skill_file() {
  local out="$TMP_ROOT/skill.tsv"
  printf '# a fixture triage skill\nFIXTURE-SKILL-RULE settle nothing\n' > "$TMP_ROOT/skill.md"
  replay "$out" --engine claude --model m --skill "$TMP_ROOT/skill.md"
  expect_code 0 "$RC" "replay with a named skill"
  assert_grep "FIXTURE-SKILL-RULE settle nothing" "$STUB_DIR/system-prompt" "the engine's system prompt carries the named skill"
  RC=0
  OUT=$("$TR" replay --home "$H" --day 2026-10-29 --engine claude --model m --settle-list "$TMP_ROOT/settle" --skill "$TMP_ROOT/no-skill.md" --out "$TMP_ROOT/skill2.tsv" 2>&1) || RC=$?
  expect_code 2 "$RC" "missing skill"
  assert_contains "$OUT" "skill $TMP_ROOT/no-skill.md is unreadable" "an unreadable skill refuses, naming it"
  [ ! -e "$TMP_ROOT/skill2.tsv" ] || fail "a skill refusal wrote --out"
  pass "the engine turn carries the skill --skill names"
}

wake_json() {  # <iso> <headline> <assistant text> <tool calls>
  local i=0
  printf '{"type":"user","timestamp":"%s","message":{"role":"user","content":"Stop hook: firstmate watcher wake - one supervision event needs a handling turn now.\\n%s\\nRun bin/fm-wake-drain.sh first."}}\n' "$1" "$2"
  while [ "$i" -lt "$4" ]; do
    printf '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"bin/fm-peek.sh beta"}}]}}\n'
    i=$((i + 1))
  done
  printf '{"type":"assistant","message":{"content":[{"type":"text","text":"%s"}]}}\n' "$3"
  printf '{"type":"user","timestamp":"%s","message":{"role":"user","content":"next"}}\n' "$1"
}

test_score() {
  local out="$TMP_ROOT/claude.tsv" h4 h6
  h4=$(sed -n 4p "$LOG" | cut -f5)
  h6=$(sed -n 6p "$LOG" | cut -f5)
  { wake_json 2026-10-29T02:00:04.000Z "$h4" "Nothing new." 1
    wake_json 2026-10-29T04:00:03.000Z "$h6" "beta looked stuck on the inbox; I checked it and it is working through the message, so nothing for you." 1
  } > "$TMP_ROOT/main-v.jsonl"
  RC=0
  OUT=$("$TR" score --home "$H" --replay "$out" --transcript "$TMP_ROOT/main-v.jsonl" --out "$TMP_ROOT/score-v.md" 2>&1) || RC=$?
  expect_code 0 "$RC" "score"
  assert_grep "**claude/claude-sonnet-5-5** on 2026-10-29: **not met** (would-settle where main's handling was V: h6); 2 would-settle." "$TMP_ROOT/score-v.md" \
    "a settle where main showed the operator something fails the exit test"
  { wake_json 2026-10-29T02:00:04.000Z "$h4" "Nothing new." 1
    wake_json 2026-10-29T04:00:03.000Z "$h6" "Cleared." 3
    wake_json 2026-10-29T06:00:05.000Z "check: rearm-resurface" "Already covered." 0
  } > "$TMP_ROOT/main-m.jsonl"
  RC=0
  OUT=$("$TR" score --home "$H" --replay "$out" --transcript "$TMP_ROOT/main-m.jsonl" --out "$TMP_ROOT/score-m.md" 2>&1) || RC=$?
  expect_code 0 "$RC" "score"
  assert_grep "**claude/claude-sonnet-5-5** on 2026-10-29: **met**; 2 would-settle." "$TMP_ROOT/score-m.md" "settles only where main was M or N meet the exit test"
  assert_grep "| check:loop-alerts | 0 | 0 | 0 | 1 | 1 |" "$TMP_ROOT/score-m.md" "main's handling is typed per class"
  assert_grep "| stale:stuck-busy-inbox | 0 | 0 | 1 | 0 | 1 |" "$TMP_ROOT/score-m.md" "more than 2 tool calls is M"
  assert_grep "| claude.tsv | claude/claude-sonnet-5-5 | h6 settle |" "$TMP_ROOT/score-m.md" "the proxy-pass rows are listed per run"
  awk -F'\t' 'BEGIN { OFS = "\t" } $2 == "seq=h4" { for (i = 3; i <= NF; i++) if ($i == "evidence=pass") $i = "evidence=fail" } { print }' "$out" > "$TMP_ROOT/unproven.tsv"
  assert_equals "fail settle" "$(field "$TMP_ROOT/unproven.tsv" h4 evidence) $(field "$TMP_ROOT/unproven.tsv" h4 action)" "fixture: a settle on failing evidence"
  RC=0
  OUT=$("$TR" score --home "$H" --replay "$TMP_ROOT/unproven.tsv" --transcript "$TMP_ROOT/main-m.jsonl" --out "$TMP_ROOT/score-u.md" 2>&1) || RC=$?
  expect_code 0 "$RC" "score"
  assert_grep "**claude/claude-sonnet-5-5** on 2026-10-29: **not met** (would-settle without passing evidence: h4); 2 would-settle." "$TMP_ROOT/score-u.md" \
    "a settle on evidence that did not pass fails the exit test even where main was N"
  pass "score types main's turns and states the exit test"
}

test_refusals
test_routes_and_probes
test_handled_message_passes
test_engine_failure_is_relay_and_retried
test_engine_failure_modes
test_audit_and_span
test_skill_file
test_pi_engine
test_score

echo "# all fm-wake-triage-replay tests passed"
