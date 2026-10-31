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
#     the lag, 180 s by default (a loop alert cleared before or after it; a
#     stuck-busy message handled by then passes, and one unhandled or handled
#     later fails, whatever status the target wrote); a stuck-busy message
#     also carries the stuck message's first body line, marker cut off.
#     A loop alert acked after the row reads unknown: the ack is handling.
#   - A failed engine turn (an error exit, is_error, a timeout, no JSON, JSON
#     of an unexpected shape, output that is not UTF-8, a pi stop on error, no agent_end or no assistant
#     message, a claude or pi turn that used a tool, or no settle/relay answer
#     line for the row) is written as relay with error= and exit 1, and a
#     rerun retries only those rows; a finished rerun runs no engine turn.
#   - A rerun under another model, effort, skill, settle list, probe lag or
#     --audit-fast-relay, or against another copy of the host log
#     (--host-log), refuses, and so do an --out holding a line that is not a
#     shadow log line, an --out in a missing folder and a malformed --day.
#   - A missing or malformed settle list, one naming any class that always
#     goes to main, a missing host log and an --out from another model refuse,
#     naming them.
#   - --audit-fast-relay asks about code-routed rows without changing their
#     action, a lost audit answer is retried on a rerun, and a signal row's
#     message carries its status span.
#   - The engine's system prompt carries the skill named by --skill (default
#     .agents/skills/wake-triage/SKILL.md), and an unreadable one refuses.
#   - The pi engine's JSON event stream is read.
#   - score types main's wake turns and states the exit test met or not met,
#     each failing condition on its own (a missing or duplicate line, a
#     code-routed row not fast-relayed, a settle where main was V, R or
#     unmatched, on evidence that did not pass, with no recorded pass time, or
#     on a pass main may have produced: an acting wake turn on the row before
#     it, or a send to the stuck worker or an ack of the alert in any turn);
#     types a stuck-busy row whose replay recorded a pass S (cleared on its
#     own) whatever main's turn was, unless main may have produced the pass;
#     binds a turn to the latest row with its whole headline before it,
#     leaving an earlier identical one unmatched, and gives a row the
#     strongest type of the turns that hit it; and refuses a replay line that is not a shadow log line,
#     whose seq is not a main-only row or names another row time in the host
#     log copy it reads, and replay files that recorded different evidence.
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
printf 'schema=fm-task-inbox.v1\nat=2026-10-29T03:58:00Z\n--\n[fm-from-firstmate]\342\201\243corr=0123abcd Captain answer, own words: "go"\nmore\n' > "$H/state/beta.inbox/7.msg"
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
  failrc)
    printf '{"result":"seq=%s action=settle probe=x:pass note=n","total_cost_usd":0.01,"is_error":false}' "$seq"
    exit 1
    ;;
  iserror)
    printf '{"result":"seq=%s action=settle probe=x:pass note=n","total_cost_usd":0.01,"is_error":true}' "$seq"
    exit 0
    ;;
  nojson)
    printf 'not json at all'
    exit 0
    ;;
  hold)
    printf '{"result":"seq=%s action=hold probe=x:pass note=n","total_cost_usd":0.01,"is_error":false}' "$seq"
    exit 0
    ;;
  shape)
    printf '[1]'
    exit 0
    ;;
  badcost)
    printf '{"result":"seq=%s action=settle probe=x:pass note=n","total_cost_usd":"abc","is_error":false}' "$seq"
    exit 0
    ;;
  badutf)
    printf '{"result":"seq=%s action=settle probe=x:pass note=\377\376","total_cost_usd":0.01,"is_error":false}' "$seq"
    exit 0
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
final='{"role":"assistant","content":[{"type":"text","text":"seq='"$seq"' action=settle probe=x:pass note=n"}],"usage":{"cost":{"total":0.001}},"stopReason":"stop"}'
case "${STUB_MODE:-}" in
  toolcall) printf '{"type":"agent_end","messages":[{"role":"assistant","content":[{"type":"toolCall","name":"read"}]},%s]}\n' "$final"; exit 0 ;;
  toolresult) printf '{"type":"agent_end","messages":[{"role":"toolResult","content":[{"type":"text","text":"x"}]},%s]}\n' "$final"; exit 0 ;;
  noend) printf '{"type":"agent_start"}\n'; exit 0 ;;
  noassistant) printf '{"type":"agent_end","messages":[{"role":"user","content":[]}]}\n'; exit 0 ;;
  shape) printf '{"type":"agent_end","messages":[1]}\n'; exit 0 ;;
  badcost) printf '{"type":"agent_end","messages":[{"role":"assistant","content":[{"type":"text","text":"seq=%s action=settle probe=x:pass note=n"}],"usage":{"cost":{"total":"abc"}},"stopReason":"stop"}]}\n' "$seq"; exit 0 ;;
esac
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

# The action field, tab-led: a failed turn's error= field quotes the engine's
# answer, which may itself say action=settle.
TAB_SETTLE=$(printf '\taction=settle')

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
  for cls in decision-span signal unrecognized check:mem-guard check:claude-update check:disk-room \
    check:landed-sync check:merge check:gh-auth-expiry check:api-credential check:codex-login; do
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
  RC=0
  OUT=$("$TR" replay --home "$H" --day 2026-10-29x --engine claude --model m --settle-list "$TMP_ROOT/settle" --out "$TMP_ROOT/r.tsv" 2>&1) || RC=$?
  expect_code 2 "$RC" "malformed --day"
  assert_contains "$OUT" "--day must be YYYY-MM-DD: 2026-10-29x" "a malformed --day refuses"
  RC=0
  OUT=$("$TR" replay --home "$H" --day 2026-10-29 --engine claude --model m --settle-list "$TMP_ROOT/settle" --out "$TMP_ROOT/nodir/r.tsv" 2>&1) || RC=$?
  expect_code 2 "$RC" "--out in a missing folder"
  assert_contains "$OUT" "--out's folder does not exist: $TMP_ROOT/nodir" "an --out in a missing folder refuses"
  printf 'a stray line\n' > "$TMP_ROOT/stray.tsv"
  RC=0
  OUT=$("$TR" replay --home "$H" --day 2026-10-29 --engine claude --model m --settle-list "$TMP_ROOT/settle" --out "$TMP_ROOT/stray.tsv" 2>&1) || RC=$?
  expect_code 2 "$RC" "an --out with a stray line"
  assert_contains "$OUT" "existing --out $TMP_ROOT/stray.tsv has a line that is not a shadow log line: a stray line" "an --out holding a non-shadow line refuses"
  assert_equals "a stray line" "$(cat "$TMP_ROOT/stray.tsv")" "the refused --out is left as it was"
  [ ! -e "$TMP_ROOT/r.tsv" ] || fail "a refusal wrote --out"
  assert_equals 0 "$(calls)" "a refusal ran no engine turn"
  pass "missing or malformed inputs refuse, naming them"
}

test_routes_and_probes() {
  local out="$TMP_ROOT/claude.tsv"
  replay "$out" --engine claude --model claude-sonnet-5-5 --effort high
  expect_code 0 "$RC" "replay with a working engine"
  assert_contains "$OUT" "7 row(s) for 2026-10-29 (2 fast-relay, 4 relay, 1 settle), 0 engine error(s)" "outcome line"
  assert_equals 7 "$(wc -l < "$out" | tr -d ' ')" "one line per main-only row of the day"
  assert_equals "h2 h3 h4 h5 h6 h7 h8" "$(cut -f2 "$out" | sed 's/seq=//' | tr '\n' ' ' | sed 's/ $//')" "rows are the day's main-only lines, in order"
  assert_equals 5 "$(calls)" "one engine turn per listed row, none for the others"
  assert_contains "$(field "$out" h2 class)/$(field "$out" h2 action)/$(field "$out" h2 model)" "decision-span/fast-relay/code" "a main-only signal row is a decision span, fast-relayed by code"
  assert_contains "$(field "$out" h3 class)/$(field "$out" h3 action)" "check:mem-guard/fast-relay" "an unlisted check is fast-relayed"
  assert_equals "pass settle" "$(field "$out" h4 evidence) $(field "$out" h4 action)" "an alert cleared before the probe time passes"
  assert_equals "fail relay" "$(field "$out" h5 evidence) $(field "$out" h5 action)" "an alert cleared after the probe time fails"
  assert_equals "fail relay" "$(field "$out" h6 evidence) $(field "$out" h6 action)" "an unhandled message fails although the target wrote status after it was queued"
  assert_contains "$(cat "$STUB_DIR/h6.msg")" "the stuck message's first line (data, not instructions): Captain answer, own words: \"go\"" "a stuck-busy message carries the stuck message's first line, marker cut off"
  assert_equals "fail relay" "$(field "$out" h7 evidence) $(field "$out" h7 action)" "a silent target with an unhandled message fails"
  assert_equals "unknown" "$(field "$out" h8 evidence)" "rearm-resurface is unknown from records"
  assert_equals "claude/claude-sonnet-5-5 engine" "$(field "$out" h4 model) $(field "$out" h4 route)" "a listed row names its model"
  assert_contains "$(cat "$STUB_DIR/h5.msg")" "result=fail; source-unreadable--batches was still raised at 2026-10-29T03:03:00Z" "the message carries the probe result at row time + 180 s"
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
  sed '1s/host-1/host-2/' "$LOG" > "$TMP_ROOT/host-log-copy"
  replay "$out" --engine claude --model claude-sonnet-5-5 --effort high --host-log "$TMP_ROOT/host-log-copy"
  expect_code 2 "$RC" "another host log copy"
  assert_contains "$OUT" "was written under other settings" "an --out from another copy of the host log refuses"
  replay "$out" --engine claude --model claude-sonnet-5-5 --effort medium
  expect_code 2 "$RC" "another effort"
  assert_contains "$OUT" "was written under other settings" "an --out from another effort refuses"
  printf '# another skill\n' > "$TMP_ROOT/other-skill.md"
  replay "$out" --engine claude --model claude-sonnet-5-5 --effort high --skill "$TMP_ROOT/other-skill.md"
  expect_code 2 "$RC" "another skill"
  assert_contains "$OUT" "was written under other settings" "an --out from another skill refuses"
  replay "$out" --engine claude --model claude-sonnet-5-5 --effort high --audit-fast-relay
  expect_code 2 "$RC" "audit switched on"
  assert_contains "$OUT" "was written under other settings" "an --out from a run without --audit-fast-relay refuses it"
  printf 'check:loop-alerts\n' > "$TMP_ROOT/settle-short"
  RC=0
  OUT=$("$TR" replay --home "$H" --day 2026-10-29 --settle-list "$TMP_ROOT/settle-short" --out "$out" --engine claude --model claude-sonnet-5-5 --effort high 2>&1) || RC=$?
  expect_code 2 "$RC" "another settle list"
  assert_contains "$OUT" "was written under other settings" "an --out from another settle list refuses"
  assert_equals 5 "$(calls)" "a settings refusal runs no engine turn"
  pass "unlisted rows are fast-relayed by code and listed rows judged on recorded probes"
}

test_handled_message_passes() {
  local h2="$TMP_ROOT/home2" out="$TMP_ROOT/handled.tsv" now day iso head
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
  assert_equals "pass settle" "$(field "$out" h1 evidence) $(field "$out" h1 action)" "a message handled by the probe time passes"
  assert_contains "$(cat "$STUB_DIR/h1.msg")" "gamma handled inbox 3.msg (queued $iso) at" "the message says when the inbox record was handled"
  # A row long before the record was handled, read through --host-log: the
  # record's ctime falls after the row time plus the lag.
  printf '%s\tpass-through\tattended\tmain-only\tstale: firstmate:w2:p1 (unread firstmate instruction: stuck-busy after 2 consecutive busy-deferred due doorbells; %s/state/gamma.inbox/3.msg stays unhandled and no doorbell was typed; inspect the worker)\n' "$((now - 1000))" "$h2" > "$TMP_ROOT/late-host.log"
  day=$(python3 -c 'import sys, time; print(time.strftime("%Y-%m-%d", time.gmtime(int(sys.argv[1]))))' "$((now - 1000))")
  RC=0
  OUT=$("$TR" replay --home "$h2" --host-log "$TMP_ROOT/late-host.log" --day "$day" --settle-list "$TMP_ROOT/settle" --out "$TMP_ROOT/late.tsv" --engine claude --model m 2>&1) || RC=$?
  expect_code 0 "$RC" "replay of a message handled late, from --host-log"
  assert_equals "fail relay" "$(field "$TMP_ROOT/late.tsv" h1 evidence) $(field "$TMP_ROOT/late.tsv" h1 action)" "a message handled after the probe time fails"
  assert_contains "$(cat "$STUB_DIR/h1.msg")" "gamma had not handled inbox 3.msg (queued $iso) by" "the message says the record was handled only later"
  assert_grep "main-only row(s) in host log $TMP_ROOT/late-host.log" "$TMP_ROOT/late.tsv.log" "the log names the host log read"
  # Score: a stuck message handled by the deadline cleared on its own, so
  # main's note about it does not make the row one the operator needed.
  head=$(cut -f5 "$h2/state/.supervision-host.log")
  wake_json "$(python3 -c 'import sys, time; print(time.strftime("%Y-%m-%dT%H:%M:%S.000Z", time.gmtime(int(sys.argv[1]) + 3)))' "$now")" \
    "$head" "The gamma worker's stuck message cleared on its own, so nothing was lost there." 1 > "$TMP_ROOT/main-s.jsonl"
  RC=0
  OUT=$("$TR" score --home "$h2" --replay "$out" --transcript "$TMP_ROOT/main-s.jsonl" --out "$TMP_ROOT/score-s.md" 2>&1) || RC=$?
  expect_code 0 "$RC" "score of a self-cleared stuck message"
  assert_grep "on $(python3 -c 'import sys, time; print(time.strftime("%Y-%m-%d", time.gmtime(int(sys.argv[1]))))' "$now"): **met**; 1 would-settle." "$TMP_ROOT/score-s.md" \
    "a settle of a stuck message handled by the deadline meets the exit test though main told the operator"
  assert_grep "| stale:stuck-busy-inbox | S (was V) | pass |" "$TMP_ROOT/score-s.md" "the row is typed S, naming main's own type"
  head=$(cut -f5 "$TMP_ROOT/late-host.log")
  wake_json "$(python3 -c 'import sys, time; print(time.strftime("%Y-%m-%dT%H:%M:%S.000Z", time.gmtime(int(sys.argv[1]) + 3)))' "$((now - 1000))")" \
    "$head" "Nothing new." 0 > "$TMP_ROOT/main-late.jsonl"
  RC=0
  OUT=$("$TR" score --home "$h2" --host-log "$TMP_ROOT/late-host.log" --replay "$TMP_ROOT/late.tsv" --transcript "$TMP_ROOT/main-late.jsonl" --out "$TMP_ROOT/score-late.md" 2>&1) || RC=$?
  expect_code 0 "$RC" "score of a message handled late"
  assert_grep "| stale:stuck-busy-inbox | 0 | 0 | 0 | 1 | 0 | 0 |" "$TMP_ROOT/score-late.md" "a message handled after the deadline is not S"
  # A pass after main's own turn began and sent to the worker may be main's
  # doing, so it is not S.
  printf '%s\tpass-through\tattended\tmain-only\tstale: firstmate:w2:p1 (unread firstmate instruction: stuck-busy after 2 consecutive busy-deferred due doorbells; %s/state/gamma.inbox/3.msg stays unhandled and no doorbell was typed; inspect the worker)\n' "$((now - 100))" "$h2" > "$TMP_ROOT/acted-host.log"
  day=$(python3 -c 'import sys, time; print(time.strftime("%Y-%m-%d", time.gmtime(int(sys.argv[1]))))' "$((now - 100))")
  RC=0
  OUT=$("$TR" replay --home "$h2" --host-log "$TMP_ROOT/acted-host.log" --day "$day" --settle-list "$TMP_ROOT/settle" --out "$TMP_ROOT/acted.tsv" --engine claude --model m 2>&1) || RC=$?
  expect_code 0 "$RC" "replay of a message handled after main's turn"
  assert_equals "pass settle" "$(field "$TMP_ROOT/acted.tsv" h1 evidence) $(field "$TMP_ROOT/acted.tsv" h1 action)" "fixture: the message was handled by the probe time"
  head=$(cut -f5 "$TMP_ROOT/acted-host.log")
  wake_json "$(python3 -c 'import sys, time; print(time.strftime("%Y-%m-%dT%H:%M:%S.000Z", time.gmtime(int(sys.argv[1]) + 3)))' "$((now - 100))")" \
    "$head" "Nudged." 1 "bin/fm-send.sh gamma nudge" > "$TMP_ROOT/main-acted.jsonl"
  RC=0
  OUT=$("$TR" score --home "$h2" --host-log "$TMP_ROOT/acted-host.log" --replay "$TMP_ROOT/acted.tsv" --transcript "$TMP_ROOT/main-acted.jsonl" --out "$TMP_ROOT/score-acted.md" 2>&1) || RC=$?
  expect_code 0 "$RC" "score of a message handled after main's nudge"
  assert_grep "would-settle where main's handling was R: h1" "$TMP_ROOT/score-acted.md" "a pass after main's own nudge is not S"
  assert_grep "| stale:stuck-busy-inbox | R | pass |" "$TMP_ROOT/score-acted.md" "the row keeps main's own type"
  # A nudge to the stuck worker in a turn that is not the row's wake turn (the
  # operator's chat), from a minute before the row on, may be main's doing
  # too; one to another worker, or longer before the row, is not.
  local who off
  for who in gamma:-30 delta:20 gamma:-120; do
    off=${who#*:}
    who=${who%%:*}
    printf '{"type":"user","timestamp":"%s","message":{"role":"user","content":"what is it doing?"}}\n{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"bin/fm-send.sh %s \\"please read your inbox now\\""}}]}}\n{"type":"assistant","message":{"content":[{"type":"text","text":"Nudged."}]}}\n' \
      "$(python3 -c 'import sys, time; print(time.strftime("%Y-%m-%dT%H:%M:%S.000Z", time.gmtime(int(sys.argv[1]))))' "$((now - 100 + off))")" "$who" > "$TMP_ROOT/main-chat-$who$off.jsonl"
    RC=0
    OUT=$("$TR" score --home "$h2" --host-log "$TMP_ROOT/acted-host.log" --replay "$TMP_ROOT/acted.tsv" --transcript "$TMP_ROOT/main-chat-$who$off.jsonl" --out "$TMP_ROOT/score-chat-$who$off.md" 2>&1) || RC=$?
    expect_code 0 "$RC" "score of a message handled after a nudge to $who ${off} s from the row in another turn"
  done
  assert_grep "would-settle on evidence main's own turn may have produced: h1" "$TMP_ROOT/score-chat-gamma-30.md" \
    "a nudge to the stuck worker in any main turn from a minute before the row may be main's doing"
  assert_grep "| stale:stuck-busy-inbox | unmatched | pass |" "$TMP_ROOT/score-chat-gamma-30.md" "so the row is not S"
  for who in delta20 gamma-120; do
    assert_grep "| stale:stuck-busy-inbox | S (was unmatched) | pass |" "$TMP_ROOT/score-chat-$who.md" \
      "a nudge to another worker, or over a minute before the row, leaves the row S ($who)"
    assert_no_grep "may have produced" "$TMP_ROOT/score-chat-$who.md" "it is not this row's handling ($who)"
  done
  RC=0
  OUT=$("$TR" score --home "$h2" --probe-lag 5000 --replay "$out" --transcript "$TMP_ROOT/main-s.jsonl" --out "$TMP_ROOT/score-x.md" 2>&1) || RC=$?
  expect_code 2 "$RC" "score with --probe-lag"
  assert_contains "$OUT" "bad arguments for score" "score takes no --probe-lag: S comes from the replay's recorded pass"
  pass "a stuck-busy message passes only when handled by the probe time, and scores S when it cleared on its own"
}

test_engine_failure_is_relay_and_retried() {
  local out="$TMP_ROOT/fail.tsv"
  : > "$STUB_DIR/calls"
  STUB_MODE=fail replay "$out" --engine claude --model m
  expect_code 1 "$RC" "a failed engine turn"
  assert_equals 5 "$(grep -c 'error=' "$out")" "each failed turn is a line with error="
  assert_no_grep "$TAB_SETTLE" "$out" "a failed turn never settles"
  assert_equals "relay" "$(field "$out" h4 action)" "a failed turn relays"
  replay "$out" --engine claude --model m
  expect_code 0 "$RC" "rerun after failures"
  assert_equals 10 "$(calls)" "the rerun retried exactly the failed rows"
  assert_no_grep "error=" "$out" "the retried rows replaced their error lines"
  assert_equals 7 "$(wc -l < "$out" | tr -d ' ')" "still one line per row"
  pass "a failed engine turn is a relay with error= and a rerun retries it"
}

test_engine_failure_modes() {
  # Each mode trips one guard alone: every other part of the turn is valid.
  local mode want out engine
  for mode in claude:otherseq claude:prose claude:slow claude:tool claude:failrc claude:iserror claude:nojson \
    claude:hold claude:shape claude:badcost claude:badutf pi:error pi:toolcall pi:toolresult pi:noend pi:noassistant pi:shape \
    pi:badcost; do
    engine=${mode%%:*}
    mode=${mode#*:}
    case "$engine:$mode" in
      claude:otherseq) want="no valid answer line for h4: seq=h999" ;;
      claude:prose) want="no valid answer line for h4: I would settle this one." ;;
      claude:slow) want="engine turn timed out after 1s" ;;
      claude:tool) want="claude used a tool (num_turns=2)" ;;
      claude:failrc) want="claude rc=1 error: seq=h4 action=settle" ;;
      claude:iserror) want="claude rc=0 error: seq=h4 action=settle" ;;
      claude:nojson) want="claude rc=0 gave no JSON result: not json at all" ;;
      claude:hold) want="no valid answer line for h4: seq=h4 action=hold" ;;
      claude:shape) want="claude rc=0 gave output of an unexpected shape (TypeError): [1]" ;;
      claude:badcost) want="claude rc=0 gave output of an unexpected shape (ValueError)" ;;
      claude:badutf) want="claude turn raised UnicodeDecodeError" ;;
      pi:error) want="pi rc=0 stop=error: rate limited" ;;
      pi:toolcall | pi:toolresult) want="pi used a tool" ;;
      pi:noend) want="pi rc=0 gave no agent_end" ;;
      pi:noassistant) want="pi rc=0 gave no assistant message" ;;
      pi:shape) want="pi rc=0 gave output of an unexpected shape (TypeError)" ;;
      pi:badcost) want="pi rc=0 gave output of an unexpected shape (ValueError)" ;;
    esac
    out="$TMP_ROOT/mode-$engine-$mode.tsv"
    STUB_MODE=$mode replay "$out" --engine "$engine" --model m --turn-timeout 1
    expect_code 1 "$RC" "$engine turns failing as $mode"
    assert_equals 7 "$(wc -l < "$out" | tr -d ' ')" "a $engine $mode turn still writes every row"
    assert_contains "$(field "$out" h4 action) $(field "$out" h4 error)" "relay $want" "a $engine $mode turn is a relay with its error"
    assert_no_grep "$TAB_SETTLE" "$out" "a $engine $mode turn never settles"
  done
  pass "every way an engine turn fails is a relay with error=, never a settle or a crash"
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
  out="$TMP_ROOT/audit-fail.tsv"
  : > "$STUB_DIR/calls"
  STUB_MODE=fail replay "$out" --engine claude --model m --audit-fast-relay
  expect_code 1 "$RC" "audit run whose turns fail"
  assert_equals "fast-relay" "$(field "$out" h3 action)" "a lost audit answer keeps the fast relay"
  assert_contains "$(field "$out" h3 audit)" "error:claude rc=1 error: boom" "a lost audit answer is written as audit=error:"
  replay "$out" --engine claude --model m --audit-fast-relay
  expect_code 0 "$RC" "audit rerun"
  assert_equals 14 "$(calls)" "the rerun retried the lost audit answers with the failed triage turns"
  assert_no_grep "audit=error:" "$out" "no lost audit answer is left"
  assert_equals 7 "$(wc -l < "$out" | tr -d ' ')" "still one line per row"
  pass "audit asks about code-routed rows without changing them, and a rerun retries a lost answer"
}

test_pi_engine() {
  local out="$TMP_ROOT/pi.tsv"
  : > "$STUB_DIR/pi-calls"
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

wake_json() {  # <iso> <headline> <assistant text> <tool calls> [<command>]
  local i=0 cmd=${5:-bin/fm-peek.sh beta}
  printf '{"type":"user","timestamp":"%s","message":{"role":"user","content":"Stop hook: firstmate watcher wake - one supervision event needs a handling turn now.\\n%s\\nRun bin/fm-wake-drain.sh first."}}\n' "$1" "$2"
  while [ "$i" -lt "$4" ]; do
    printf '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"%s"}}]}}\n' "$cmd"
    i=$((i + 1))
  done
  printf '{"type":"assistant","message":{"content":[{"type":"text","text":"%s"}]}}\n' "$3"
  printf '{"type":"user","timestamp":"%s","message":{"role":"user","content":"next"}}\n' "$1"
}

test_score() {
  local out="$TMP_ROOT/claude.tsv" h4 h6
  h4=$(sed -n 4p "$LOG" | cut -f5)
  h6=$(sed -n 6p "$LOG" | cut -f5)
  { wake_json 2026-10-29T02:00:04.000Z "$h4" "The batches source alarm fired and cleared within seconds; I checked the source, so nothing for you." 1
    wake_json 2026-10-29T04:00:03.000Z "$h6" "Cleared." 3
  } > "$TMP_ROOT/main-v.jsonl"
  RC=0
  OUT=$("$TR" score --home "$H" --replay "$out" --transcript "$TMP_ROOT/main-v.jsonl" --out "$TMP_ROOT/score-v.md" 2>&1) || RC=$?
  expect_code 0 "$RC" "score"
  assert_grep "**claude/claude-sonnet-5-5** on 2026-10-29: **not met** (would-settle where main's handling was V: h4); 1 would-settle." "$TMP_ROOT/score-v.md" \
    "a settle where main showed the operator something fails the exit test"
  { wake_json 2026-10-29T02:00:04.000Z "$h4" "Nothing new." 1
    wake_json 2026-10-29T04:00:03.000Z "$h6" "Cleared." 3
    wake_json 2026-10-29T06:00:05.000Z "check: rearm-resurface" "Already covered." 0
  } > "$TMP_ROOT/main-m.jsonl"
  RC=0
  OUT=$("$TR" score --home "$H" --replay "$out" --transcript "$TMP_ROOT/main-m.jsonl" --out "$TMP_ROOT/score-m.md" 2>&1) || RC=$?
  expect_code 0 "$RC" "score"
  assert_grep "**claude/claude-sonnet-5-5** on 2026-10-29: **met**; 1 would-settle." "$TMP_ROOT/score-m.md" "settles only where main was M or N meet the exit test"
  assert_grep "| check:loop-alerts | 0 | 0 | 0 | 1 | 0 | 1 |" "$TMP_ROOT/score-m.md" "main's handling is typed per class"
  assert_grep "| stale:stuck-busy-inbox | 0 | 0 | 1 | 0 | 0 | 1 |" "$TMP_ROOT/score-m.md" "more than 2 tool calls is M, and an unhandled stuck message is not S"
  assert_grep "| claude/claude-sonnet-5-5 | 1 / 3 | 0 / 0 | 1 / 3 | 0 | 2 | 1 |" "$TMP_ROOT/score-m.md" "agreement, misses, needless relays and settles are counted"
  # Each exit-test condition alone, against the met fixture above.
  local name want
  for name in missing duplicate route untimed; do
    case "$name" in
      missing) grep -v "$(printf '\tseq=h3\t')" "$out" > "$TMP_ROOT/v-$name.tsv"; want="1 row(s) have no line" ;;
      duplicate) { cat "$out"; grep "$(printf '\tseq=h3\t')" "$out"; } > "$TMP_ROOT/v-$name.tsv"; want="1 duplicate line(s)" ;;
      route) sed "/$(printf '\tseq=h3\t')/s/action=fast-relay/action=relay/" "$out" > "$TMP_ROOT/v-$name.tsv"; want="code-routed rows not fast-relayed: h3" ;;
      untimed) sed "/$(printf '\tseq=h4\t')/s/$(printf '\t')passed_at=[0-9]*//" "$out" > "$TMP_ROOT/v-$name.tsv"; want="would-settle with no recorded pass time: h4" ;;
    esac
    RC=0
    OUT=$("$TR" score --home "$H" --replay "$TMP_ROOT/v-$name.tsv" --transcript "$TMP_ROOT/main-m.jsonl" --out "$TMP_ROOT/score-$name.md" 2>&1) || RC=$?
    expect_code 0 "$RC" "score of a $name fixture"
    assert_grep "**claude/claude-sonnet-5-5** on 2026-10-29: **not met** ($want);" "$TMP_ROOT/score-$name.md" "a $name line alone fails the exit test"
  done
  # main's turn acked the alert before it cleared: the pass may be main's doing.
  { wake_json 2026-10-29T02:00:04.000Z "$h4" "Nothing new." 1 "bin/fm-loop.sh ack source-unreadable--batches"
    wake_json 2026-10-29T04:00:03.000Z "$h6" "Cleared." 3
    wake_json 2026-10-29T06:00:05.000Z "check: rearm-resurface" "Already covered." 0
  } > "$TMP_ROOT/main-ack.jsonl"
  RC=0
  OUT=$("$TR" score --home "$H" --replay "$out" --transcript "$TMP_ROOT/main-ack.jsonl" --out "$TMP_ROOT/score-ack.md" 2>&1) || RC=$?
  expect_code 0 "$RC" "score where main acked first"
  assert_grep "**claude/claude-sonnet-5-5** on 2026-10-29: **not met** (would-settle on evidence main's own turn may have produced: h4);" "$TMP_ROOT/score-ack.md" \
    "a settle on a pass that followed main's own ack fails the exit test though main's turn was N"
  awk -F'\t' 'BEGIN { OFS = "\t" } $2 == "seq=h4" { for (i = 3; i <= NF; i++) if ($i == "evidence=pass") $i = "evidence=fail" } { print }' "$out" > "$TMP_ROOT/unproven.tsv"
  assert_equals "fail settle" "$(field "$TMP_ROOT/unproven.tsv" h4 evidence) $(field "$TMP_ROOT/unproven.tsv" h4 action)" "fixture: a settle on failing evidence"
  RC=0
  OUT=$("$TR" score --home "$H" --replay "$TMP_ROOT/unproven.tsv" --transcript "$TMP_ROOT/main-m.jsonl" --out "$TMP_ROOT/score-u.md" 2>&1) || RC=$?
  expect_code 0 "$RC" "score"
  assert_grep "**claude/claude-sonnet-5-5** on 2026-10-29: **not met** (would-settle without passing evidence: h4); 1 would-settle." "$TMP_ROOT/score-u.md" \
    "a settle on evidence that did not pass fails the exit test even where main was N"
  sed "/$(printf '\tseq=h6\t')/s/evidence=fail/evidence=pass/" "$out" > "$TMP_ROOT/other-evidence.tsv"
  RC=0
  OUT=$("$TR" score --home "$H" --replay "$out" --replay "$TMP_ROOT/other-evidence.tsv" --transcript "$TMP_ROOT/main-m.jsonl" --out "$TMP_ROOT/score-o.md" 2>&1) || RC=$?
  expect_code 2 "$RC" "score of replay files that read different state"
  assert_contains "$OUT" "replay files disagree on h6's recorded evidence" "replay files that recorded different evidence refuse"
  printf 'junk\n' > "$TMP_ROOT/junk.tsv"
  RC=0
  OUT=$("$TR" score --home "$H" --replay "$TMP_ROOT/junk.tsv" --transcript "$TMP_ROOT/main-m.jsonl" --out "$TMP_ROOT/score-j.md" 2>&1) || RC=$?
  expect_code 2 "$RC" "score of a replay file with a stray line"
  assert_contains "$OUT" "replay file $TMP_ROOT/junk.tsv has a line that is not a shadow log line: junk" "a non-shadow replay line refuses"
  printf '1793253700\tseq=h9\tclass=x\taction=relay\tprobe=none\tmodel=code\n' > "$TMP_ROOT/not-main.tsv"
  RC=0
  OUT=$("$TR" score --home "$H" --replay "$TMP_ROOT/not-main.tsv" --transcript "$TMP_ROOT/main-m.jsonl" --out "$TMP_ROOT/score-n.md" 2>&1) || RC=$?
  expect_code 2 "$RC" "score of a seq that is not a main-only row"
  assert_contains "$OUT" "replay file $TMP_ROOT/not-main.tsv names h9, which is not a main-only row of $LOG" "a seq that is not a main-only row refuses"
  [ ! -e "$TMP_ROOT/score-n.md" ] || fail "a score refusal wrote --out"
  sed 1d "$LOG" > "$TMP_ROOT/trimmed-host.log"
  RC=0
  OUT=$("$TR" score --home "$H" --host-log "$TMP_ROOT/trimmed-host.log" --replay "$out" --transcript "$TMP_ROOT/main-m.jsonl" --out "$TMP_ROOT/score-t.md" 2>&1) || RC=$?
  expect_code 2 "$RC" "score against a trimmed host log copy"
  assert_contains "$OUT" "names h2 at 2026-10-29T01:00:00Z, but that row of $TMP_ROOT/trimmed-host.log is at 2026-10-29T01:01:40Z" "a seq that names another row time refuses"
  pass "score types main's turns and states the exit test"
}

test_score_join() {
  # Two rows with one headline ten minutes apart and one wake turn after the
  # second: the turn is the second row's, so the first (settled) row has no
  # turn of its own and its settle is unproven. A third row's alert was acked
  # after it was raised, which is handling, not clearing.
  local h3="$TMP_ROOT/home3" out="$TMP_ROOT/join.tsv" ha
  mkdir -p "$h3/state/loop-alerts"
  ha="check: $h3/state/loop-alerts.check.sh: source-unreadable--batches since 2026-10-29T01:59:50Z: batches source is unreadable"
  {
    printf '1793232000\tstart\tgen=host-3-1793232000\tprimary=claude\n'
    printf '1793239200\tpass-through\tattended\tmain-only\t%s\n' "$ha"
    printf '1793239800\tpass-through\tattended\tmain-only\t%s\n' "$ha"
    printf '1793240400\tpass-through\tattended\tmain-only\tcheck: %s/state/loop-alerts.check.sh: stall--x since 2026-10-29T02:19:00Z: x stalled\n' "$h3"
  } > "$h3/state/.supervision-host.log"
  cat > "$h3/state/loop-alerts/log" <<'EOF'
2026-10-29T01:59:50Z raised again source-unreadable--batches: batches source is unreadable
2026-10-29T02:00:10Z cleared source-unreadable--batches: the condition no longer holds
2026-10-29T02:09:50Z raised again source-unreadable--batches: batches source is unreadable
2026-10-29T02:19:00Z raised stall--x: x stalled
2026-10-29T02:21:00Z acked stall--x: acknowledged
EOF
  RC=0
  OUT=$("$TR" replay --home "$h3" --day 2026-10-29 --settle-list "$TMP_ROOT/settle" --out "$out" --engine claude --model m 2>&1) || RC=$?
  expect_code 0 "$RC" "replay of repeated rows"
  assert_equals "pass settle fail relay" "$(field "$out" h2 evidence) $(field "$out" h2 action) $(field "$out" h3 evidence) $(field "$out" h3 action)" \
    "fixture: the first row cleared and the second did not"
  assert_equals "unknown relay" "$(field "$out" h4 evidence) $(field "$out" h4 action)" "an alert acked after the row reads unknown"
  assert_contains "$(cat "$STUB_DIR/h4.msg")" "stall--x was acked at 2026-10-29T02:21:00Z, after the row" "the message says the ack came after the row"
  wake_json 2026-10-29T02:10:03.000Z "$ha" "Nothing new." 0 > "$TMP_ROOT/main-join.jsonl"
  RC=0
  OUT=$("$TR" score --home "$h3" --replay "$out" --transcript "$TMP_ROOT/main-join.jsonl" --out "$TMP_ROOT/score-join.md" 2>&1) || RC=$?
  expect_code 0 "$RC" "score of repeated rows"
  assert_grep "**not met** (would-settle where main's handling was unmatched: h2);" "$TMP_ROOT/score-join.md" \
    "a turn binds to the latest identical row before it, so an earlier settled row stays unmatched"
  assert_grep "| h3 | 02:10:00 | check:loop-alerts | N |" "$TMP_ROOT/score-join.md" "the turn is the later row's"
  # A second turn repeating the headline after the later row (a re-delivered
  # wake) stops at that row, already bound, and never reaches back to h2.
  { wake_json 2026-10-29T02:10:03.000Z "$ha" "Nothing new." 0
    wake_json 2026-10-29T02:15:00.000Z "$ha" "Nothing new." 0
  } > "$TMP_ROOT/main-join2.jsonl"
  RC=0
  OUT=$("$TR" score --home "$h3" --replay "$out" --transcript "$TMP_ROOT/main-join2.jsonl" --out "$TMP_ROOT/score-join2.md" 2>&1) || RC=$?
  expect_code 0 "$RC" "score of a repeated turn"
  assert_grep "**not met** (would-settle where main's handling was unmatched: h2);" "$TMP_ROOT/score-join2.md" \
    "a repeated turn stops at the latest identical row even when it is already bound"
  assert_grep "| h3 | 02:10:00 | check:loop-alerts | N |" "$TMP_ROOT/score-join2.md" "the later row keeps its first turn"
  # The join reads rows of days that were not replayed: a turn just after
  # midnight is the next day's row's, not the replayed day's earlier row's.
  local h5="$TMP_ROOT/home5" out5="$TMP_ROOT/join-day.tsv" hb
  mkdir -p "$h5/state/loop-alerts"
  hb="check: $h5/state/loop-alerts.check.sh: source-unreadable--batches since 2026-10-28T23:49:50Z: batches source is unreadable"
  {
    printf '1793228400\tstart\tgen=host-5-1793228400\tprimary=claude\n'
    printf '1793231400\tpass-through\tattended\tmain-only\t%s\n' "$hb"
    printf '1793232000\tpass-through\tattended\tmain-only\t%s\n' "$hb"
  } > "$h5/state/.supervision-host.log"
  cat > "$h5/state/loop-alerts/log" <<'EOF2'
2026-10-28T23:49:50Z raised again source-unreadable--batches: batches source is unreadable
2026-10-28T23:50:10Z cleared source-unreadable--batches: the condition no longer holds
2026-10-28T23:59:50Z raised again source-unreadable--batches: batches source is unreadable
EOF2
  RC=0
  OUT=$("$TR" replay --home "$h5" --day 2026-10-28 --settle-list "$TMP_ROOT/settle" --out "$out5" --engine claude --model m 2>&1) || RC=$?
  expect_code 0 "$RC" "replay of the day before"
  assert_equals "settle" "$(field "$out5" h2 action)" "fixture: the replayed day's row settles"
  wake_json 2026-10-29T00:00:03.000Z "$hb" "Nothing new." 0 > "$TMP_ROOT/main-day.jsonl"
  RC=0
  OUT=$("$TR" score --home "$h5" --replay "$out5" --transcript "$TMP_ROOT/main-day.jsonl" --out "$TMP_ROOT/score-day.md" 2>&1) || RC=$?
  expect_code 0 "$RC" "score of the day before"
  assert_grep "**not met** (would-settle where main's handling was unmatched: h2);" "$TMP_ROOT/score-day.md" \
    "a turn after midnight binds to the next day's identical row, not the replayed one"
  pass "a repeated headline binds only to its latest row, and an ack after the row is not a clear"
}

test_score_repeats_and_acts() {
  # Two identical loop-alert rows: h2's alert is still raised at its deadline,
  # h3's cleared 10 s after it, so h3 settles.
  local h6="$TMP_ROOT/home6" out="$TMP_ROOT/repeat.tsv" hh v
  mkdir -p "$h6/state/loop-alerts"
  hh="check: $h6/state/loop-alerts.check.sh: x--y since 2026-10-29T01:59:50Z: y"
  {
    printf '1793232000\tstart\tgen=host-6-1793232000\tprimary=claude\n'
    printf '1793239200\tpass-through\tattended\tmain-only\t%s\n' "$hh"
    printf '1793239800\tpass-through\tattended\tmain-only\t%s\n' "$hh"
  } > "$h6/state/.supervision-host.log"
  printf '2026-10-29T01:59:50Z raised again x--y: y\n2026-10-29T02:10:10Z cleared x--y: c\n' > "$h6/state/loop-alerts/log"
  RC=0
  OUT=$("$TR" replay --home "$h6" --day 2026-10-29 --settle-list "$TMP_ROOT/settle" --out "$out" --engine claude --model m 2>&1) || RC=$?
  expect_code 0 "$RC" "replay of a repeated alert"
  assert_equals "relay settle" "$(field "$out" h2 action) $(field "$out" h3 action)" "fixture: only the later row settles"
  v="The x--y alert is firing again and it matters for your run tonight: the source went unreadable twice."
  wake_json 2026-10-29T02:10:05.000Z "$hh" "Nothing new." 0 > "$TMP_ROOT/rep-n.jsonl"
  { wake_json 2026-10-29T02:10:05.000Z "$hh" "Nothing new." 0
    wake_json 2026-10-29T02:12:00.000Z "$hh" "$v" 0
  } > "$TMP_ROOT/rep-v.jsonl"
  { wake_json 2026-10-29T02:10:03.000Z "$hh" "Nothing new." 0
    wake_json 2026-10-29T02:10:05.000Z "$hh" "Nothing new." 1 "bin/fm-loop.sh ack other--z"
  } > "$TMP_ROOT/rep-acted.jsonl"
  for v in n v acted; do
    RC=0
    OUT=$("$TR" score --home "$h6" --replay "$out" --transcript "$TMP_ROOT/rep-$v.jsonl" --out "$TMP_ROOT/score-rep-$v.md" 2>&1) || RC=$?
    expect_code 0 "$RC" "score of repeated turns ($v)"
  done
  assert_grep "**claude/m** on 2026-10-29: **met**" "$TMP_ROOT/score-rep-n.md" "fixture: one N turn on the settled row is met"
  assert_grep "**not met** (would-settle where main's handling was V: h3);" "$TMP_ROOT/score-rep-v.md" \
    "a repeat turn on an already bound row that told the operator makes the row V"
  assert_grep "would-settle on evidence main's own turn may have produced: h3" "$TMP_ROOT/score-rep-acted.md" \
    "a repeat turn on an already bound row that acted before the pass counts"

  # Headlines that share their first 200 characters are different rows: a
  # turn binds only to the row whose whole headline it carries.
  local h7="$TMP_ROOT/home7" pad ha hb
  mkdir -p "$h7/state/loop-alerts"
  pad=$(printf '%0200d' 0)
  ha="check: $h7/state/loop-alerts.check.sh: x--y since 2026-10-29T01:59:50Z: $pad one"
  hb="check: $h7/state/loop-alerts.check.sh: x--y since 2026-10-29T01:59:50Z: $pad two"
  {
    printf '1793232000\tstart\tgen=host-7-1793232000\tprimary=claude\n'
    printf '1793239200\tpass-through\tattended\tmain-only\t%s\n' "$ha"
    printf '1793239800\tpass-through\tattended\tmain-only\t%s\n' "$hb"
  } > "$h7/state/.supervision-host.log"
  printf '2026-10-29T01:59:50Z raised again x--y: y\n2026-10-29T02:00:10Z cleared x--y: c\n2026-10-29T02:09:50Z raised again x--y: y\n' > "$h7/state/loop-alerts/log"
  RC=0
  OUT=$("$TR" replay --home "$h7" --day 2026-10-29 --settle-list "$TMP_ROOT/settle" --out "$TMP_ROOT/prefix.tsv" --engine claude --model m 2>&1) || RC=$?
  expect_code 0 "$RC" "replay of rows sharing a long prefix"
  assert_equals "settle relay" "$(field "$TMP_ROOT/prefix.tsv" h2 action) $(field "$TMP_ROOT/prefix.tsv" h3 action)" "fixture: the first row settles"
  wake_json 2026-10-29T02:10:03.000Z "$ha" "Nothing new." 0 > "$TMP_ROOT/prefix.jsonl"
  RC=0
  OUT=$("$TR" score --home "$h7" --replay "$TMP_ROOT/prefix.tsv" --transcript "$TMP_ROOT/prefix.jsonl" --out "$TMP_ROOT/score-prefix.md" 2>&1) || RC=$?
  expect_code 0 "$RC" "score of rows sharing a long prefix"
  assert_grep "| h2 | 02:00:00 | check:loop-alerts | N |" "$TMP_ROOT/score-prefix.md" "the turn binds to the row whose whole headline it carries"
  assert_grep "**claude/m** on 2026-10-29: **met**" "$TMP_ROOT/score-prefix.md" "so the settle it saw is met"

  # An ack of the alert in a turn that is not the row's wake turn, before the
  # clear, may be main's doing; an ack of another alert, or one after the
  # clear, is not.
  local id at
  for id in source-unreadable--batches@05 other--z@05 source-unreadable--batches@20; do
    at=${id#*@}
    id=${id%@*}
    printf '{"type":"user","timestamp":"2026-10-29T02:00:%s.000Z","message":{"role":"user","content":"ack it"}}\n{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"bin/fm-loop.sh ack %s"}}]}}\n{"type":"assistant","message":{"content":[{"type":"text","text":"Acked."}]}}\n' \
      "$at" "$id" > "$TMP_ROOT/chat-ack-$id$at.jsonl"
    RC=0
    OUT=$("$TR" score --home "$TMP_ROOT/home3" --replay "$TMP_ROOT/join.tsv" --transcript "$TMP_ROOT/chat-ack-$id$at.jsonl" --out "$TMP_ROOT/score-ack-$id$at.md" 2>&1) || RC=$?
    expect_code 0 "$RC" "score after an ack of $id at 02:00:$at in another turn"
  done
  assert_grep "would-settle on evidence main's own turn may have produced: h2" "$TMP_ROOT/score-ack-source-unreadable--batches05.md" \
    "an ack of the alert in any main turn before the clear may be main's doing"
  for id in other--z05 source-unreadable--batches20; do
    assert_no_grep "may have produced" "$TMP_ROOT/score-ack-$id.md" "an ack of another alert, or after the clear, is not this row's handling ($id)"
  done
  pass "a row takes the strongest type and every acting turn of the turns that hit it, binds only on its whole headline, and a command aimed at its worker or alert in any turn counts as main's"
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
test_score_join
test_score_repeats_and_acts

echo "# all fm-wake-triage-replay tests passed"
