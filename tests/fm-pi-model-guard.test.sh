#!/usr/bin/env bash
# tests/fm-pi-model-guard.test.sh - the model-identity table for the rule that
# Claude work never runs through Pi (bin/fm-pi-model-guard-lib.sh), driven
# through its public check, `bin/fm-harness.sh validate-pi-model`.
#
# Each launch path's own suite proves the refusal reaches it: fm-spawn
# (tests/fm-spawn-dispatch-profile.test.sh), fm-control relaunch
# (tests/fm-control-relaunch.test.sh), reboot relaunch
# (tests/fm-reboot-relaunch.test.sh), a remote secondmate
# (tests/fm-remote-secondmate-trace-context.test.sh), a worker account pin
# (tests/fm-worker-account.test.sh), dispatch resolution
# (tests/fm-dispatch-resolve.test.sh), and bootstrap's CREW_DISPATCH check
# (tests/fm-bootstrap.test.sh).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

HARNESS="$ROOT/bin/fm-harness.sh"

# Claude names under every spelling the repo uses: provider paths, Claude Code
# aliases, family names Pi fuzzy-matches, gateway and Bedrock ids, thinking
# suffixes, and any letter case.
for model in anthropic/claude-sonnet-5 claude-opus-5-5 claude-fable-5-1 sonnet opus haiku fable opusplan \
  'opus[1m]' sonnet:high ANTHROPIC/x Claude-Sonnet-5 openrouter/anthropic/claude-sonnet-5 \
  us.anthropic.claude-opus-4-6-v1 amazon-bedrock/us.anthropic.claude-opus-4-6-v1 \
  github-copilot/claude-sonnet-4; do
  for harness in pi pi-signed; do
    out=$("$HARNESS" validate-pi-model "$harness" "$model" 2>&1) && fail "$harness accepted Claude model '$model'"
    assert_contains "$out" "error: refusing to launch $harness with --model $model: Claude work never runs through Pi, because Pi bills Anthropic subscription use as per-token extra usage" \
      "the refusal should name '$model' and the reason"
  done
done
pass "pi and pi-signed refuse every Claude spelling, naming the model and the reason"

for model in openai-codex/gpt-6-luna openai-codex/gpt-5.6-sol codex-native/gpt-6-astra google/gemini-3-pro \
  openrouter/gpt-5.5 gpt-5.5; do
  out=$("$HARNESS" validate-pi-model pi "$model" 2>&1) || fail "pi refused non-Claude model '$model': $out"
  [ -z "$out" ] || fail "an accepted model must print nothing: $out"
done
pass "pi accepts non-Claude models"

# With no model Pi picks its own start model, which can be Claude, so no
# model, `default`, or `-` (the remote secondmate spelling of none) refuses.
for model in '' default -; do
  for harness in pi pi-signed; do
    out=$("$HARNESS" validate-pi-model "$harness" "$model" 2>&1) && fail "$harness accepted no model: '$model'"
    assert_contains "$out" "error: refusing to launch $harness with no model: Pi would pick its own start model, which can be Claude; Claude work never runs through Pi" \
      "the no-model refusal should name the absence and the reason: '$model'"
    assert_contains "$out" "give Pi a non-Claude --model <provider>/<id>" \
      "the no-model refusal should say how to pass a model: '$model'"
  done
done
pass "pi and pi-signed refuse a launch with no model or default"

for harness in claude codex opencode omp; do
  for model in anthropic/claude-sonnet-5 default; do
    "$HARNESS" validate-pi-model "$harness" "$model" >/dev/null 2>&1 \
      || fail "$harness must not be governed by the Pi model guard: '$model'"
  done
done
pass "only pi and pi-signed are governed by the guard"

# Every live Pi guard takes its model from fm_pi_live_model (tests/lib.sh), and
# FM_PI_LIVE_MODEL passes the same guard as any launch.
model=$(unset FM_PI_LIVE_MODEL; fm_pi_live_model; printf '%s' "$PI_LIVE_MODEL") \
  || fail "the default live Pi model must pass the guard"
[ "$model" = openai-codex/gpt-6.1-sol ] || fail "the default live Pi model changed: $model"
model=$(FM_PI_LIVE_MODEL=openai-codex/gpt-5.6-sol; fm_pi_live_model; printf '%s' "$PI_LIVE_MODEL") \
  || fail "a non-Claude FM_PI_LIVE_MODEL must pass the guard"
[ "$model" = openai-codex/gpt-5.6-sol ] || fail "FM_PI_LIVE_MODEL was not honored: $model"
for model in anthropic/claude-sonnet-5 sonnet; do
  out=$(FM_PI_LIVE_MODEL=$model; fm_pi_live_model 2>&1) && fail "a Claude FM_PI_LIVE_MODEL must fail: '$model'"
  assert_contains "$out" "FM_PI_LIVE_MODEL: refusing to launch pi with --model $model: Claude work never runs through Pi" \
    "the live model refusal should name the variable, the model and the reason: '$model'"
done
pass "FM_PI_LIVE_MODEL overrides the live Pi model and a Claude model there refuses"

echo "# all fm-pi-model-guard tests passed"
