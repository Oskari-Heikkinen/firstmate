#!/usr/bin/env bash
# Opt-in credentialed live guard for the wake-triage replay's engine turns
# (bin/fm-wake-triage-replay.sh "Engines").
#
# Proves against each installed real engine, with no stub: a replay of two
# recorded check:loop-alerts rows (one whose alert cleared before the row, one
# still raised) runs one classify-only turn per row, the replay reads each
# turn's answer and cost from the engine's real JSON output, no turn used a
# tool (the replay refuses claude's num_turns above 1 and a pi tool call), and
# the row whose probe failed is relayed. The rows' engines run under their
# existing logins; no live home is touched.
#
# FM_WAKE_TRIAGE_REPLAY_LIVE_E2E=1 (or FM_LIVE=1) runs it.
# FM_WAKE_TRIAGE_LIVE_CLAUDE_MODEL picks the claude model (default
# claude-sonnet-5-5); FM_PI_LIVE_MODEL picks the pi model (fm_pi_live_model).
# An absent engine is reported, and a run that checked no engine fails.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate opt-in FM_WAKE_TRIAGE_REPLAY_LIVE_E2E python3

TR="$ROOT/bin/fm-wake-triage-replay.sh"
LAB=$(fm_test_tmproot fm-wake-triage-replay-live)
H="$LAB/home"
mkdir -p "$H/state/loop-alerts"
unset FM_WAKE_TRIAGE_CLAUDE_BIN FM_WAKE_TRIAGE_PI_BIN

# 2026-10-29T00:00:00Z is 1793232000. h2's alert cleared 20 s after the row;
# h3's was raised again and never cleared.
{
  printf '1793232000\tstart\tgen=host-1-1793232000\tprimary=claude\n'
  printf '1793239200\tpass-through\tattended\tmain-only\tcheck: %s/state/loop-alerts.check.sh: source-unreadable--batches since 2026-10-29T01:59:50Z: batches source is unreadable\n' "$H"
  printf '1793242800\tpass-through\tattended\tmain-only\tcheck: %s/state/loop-alerts.check.sh: source-unreadable--batches since 2026-10-29T02:59:50Z: batches source is unreadable\n' "$H"
} > "$H/state/.supervision-host.log"
cat > "$H/state/loop-alerts/log" <<'EOF'
2026-10-29T01:59:50Z raised again source-unreadable--batches: batches source is unreadable
2026-10-29T02:00:10Z cleared source-unreadable--batches: the condition no longer holds
2026-10-29T02:59:50Z raised again source-unreadable--batches: batches source is unreadable
EOF
printf 'check:loop-alerts\n' > "$LAB/settle"

field() {  # <file> <seq> <key>: the key's value on that seq's line
  awk -F'\t' -v s="seq=$2" -v k="$3=" '$2 == s { for (i = 3; i <= NF; i++) if (index($i, k) == 1) print substr($i, length(k) + 1) }' "$1"
}

checked=0
check_engine() {  # <engine> <model>
  local engine=$1 model=$2 version out rc=0 seq
  if ! command -v "$engine" >/dev/null 2>&1; then
    printf '# %s absent: its replay turn is unverified on this host\n' "$engine"
    return 0
  fi
  version=$("$engine" --version 2>/dev/null | head -n 1)
  out="$LAB/$engine.tsv"
  "$TR" replay --home "$H" --day 2026-10-29 --engine "$engine" --model "$model" --effort high \
    --settle-list "$LAB/settle" --out "$out" > "$LAB/$engine.out" 2>&1 || rc=$?
  [ "$rc" -eq 0 ] || fail "$engine $version: the replay exited $rc: $(cat "$LAB/$engine.out") $(cat "$out.log" 2>/dev/null)"
  assert_equals 2 "$(wc -l < "$out" | tr -d ' ')" "$engine $version: one line per row"
  assert_no_grep "error=" "$out" "$engine $version: no turn failed, used a tool or went unparsed"
  for seq in h2 h3; do
    assert_equals engine "$(field "$out" "$seq" route)" "$engine $version: $seq took an engine turn"
    [ -n "$(field "$out" "$seq" cost)" ] || fail "$engine $version: $seq has no cost read"
  done
  assert_equals relay "$(field "$out" h3 action)" "$engine $version: the row whose probe failed is relayed"
  printf '# %s %s, %s: h2 (pass) %s, h3 (fail) relay, costs %s and %s\n' "$engine" "$version" "$model" \
    "$(field "$out" h2 action)" "$(field "$out" h2 cost)" "$(field "$out" h3 cost)"
  checked=$((checked + 1))
}

check_engine claude "${FM_WAKE_TRIAGE_LIVE_CLAUDE_MODEL:-claude-sonnet-5-5}"
if command -v pi >/dev/null 2>&1; then
  fm_pi_live_model
  check_engine pi "$PI_LIVE_MODEL"
else
  check_engine pi unused
fi
[ "$checked" -gt 0 ] || fail "no replay engine (claude, pi) is installed, so nothing was checked"
pass "the replay's real engine turns parse, use no tool and relay a failed probe ($checked engine(s))"
echo "# all fm-wake-triage-replay-live-e2e checks passed"
