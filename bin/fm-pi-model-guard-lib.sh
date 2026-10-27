#!/usr/bin/env bash
# fm-pi-model-guard-lib.sh - the single owner of the rule that Claude work
# never runs through Pi: Pi bills Anthropic subscription use as per-token extra
# usage, so a pi or pi-signed launch refuses a Claude or Anthropic model.
#
# The guard is unconditional. It needs no config/pi-account and never reads,
# writes, or requires one; where that pin exists, bin/fm-worker-account-lib.sh
# keeps its own provider check, which runs after this one.
#
# Sourced by bin/fm-spawn.sh (every spawn, relaunch, restore, local and remote
# secondmate), bin/fm-control.sh (a relaunch, before the old agent stops, which
# covers park resume and reboot relaunch), bin/fm-dispatch-resolve.sh (a
# Claude-on-Pi profile is never eligible), and bin/fm-harness.sh
# (`validate-pi-model`, the operator-facing check).
#
# A model names Claude when, case-insensitively, any provider path segment is
# exactly `anthropic` (anthropic/<id>, openrouter/anthropic/<id>), or the model
# text holds one of the tokens claude, anthropic, opus, opusplan, sonnet,
# haiku, or fable, bounded by a non-letter or the ends of the text. The bare
# family names matter because Pi resolves `--model sonnet` by fuzzy match to a
# Claude model; the token rule also covers Claude Code aliases such as
# `opus[1m]`, Bedrock ids such as `us.anthropic.claude-...`, and a Pi
# `:<thinking>` suffix. A Claude model refuses under every provider, including
# gateways that bill elsewhere, so the rule never depends on a provider list.
#
# A Pi launch must name its model. With no model, `default`, or `-` (the
# remote secondmate spelling of none), and no --model or --models in a raw
# command, Pi would pick its own start model (a session's saved model, settings
# defaultModel, or the first authenticated provider's default, which can be
# Claude), so the guard refuses that launch too.

FM_PI_MODEL_GUARD_REASON='Claude work never runs through Pi, because Pi bills Anthropic subscription use as per-token extra usage'

# fm_pi_model_is_claude <model>
# Returns 0 when the model text names a Claude or Anthropic model, else 1.
fm_pi_model_is_claude() {
  local model segment
  model=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  [ -n "$model" ] || return 1
  case "$model" in
  */*)
    segment=$model
    while [ "${segment#*/}" != "$segment" ]; do
      [ "${segment%%/*}" != anthropic ] || return 0
      segment=${segment#*/}
    done
    ;;
  esac
  [[ "$model" =~ (^|[^a-z])(claude|anthropic|opus|opusplan|sonnet|haiku|fable)([^a-z]|$) ]]
}

# fm_pi_model_guard <harness> <model> [<raw-command>]
# Returns 0 for a harness other than pi or pi-signed, and for a Pi launch that
# names a model and whose model and raw-command --model, --models, and
# --provider values name nothing Claude. Otherwise prints one refusal naming
# the model, or its absence, and the reason, and returns 1.
fm_pi_model_guard() {
  local harness=$1 model=${2:-} raw=${3:-} word next='' value has_model=0
  local -a named=()
  case "$harness" in
  pi | pi-signed) ;;
  *) return 0 ;;
  esac
  case "$model" in
  '' | default | -) ;;
  *) named+=("--model $model") ;;
  esac
  for word in $raw; do
    if [ -n "$next" ]; then
      named+=("$next $word")
      next=
      continue
    fi
    case "$word" in
    --model | --models | --provider) next=$word ;;
    --model=* | --models=* | --provider=*) named+=("${word%%=*} ${word#*=}") ;;
    esac
  done
  for word in ${named[@]+"${named[@]}"}; do
    case "$word" in --model\ * | --models\ *) has_model=1 ;; esac
  done
  if [ "$has_model" -eq 0 ]; then
    echo "error: refusing to launch $harness with no model: Pi would pick its own start model, which can be Claude; $FM_PI_MODEL_GUARD_REASON; give Pi a non-Claude --model <provider>/<id>" >&2
    return 1
  fi
  for word in "${named[@]}"; do
    value=${word#* }
    if [ "${word%% *}" = --provider ]; then
      [ "$(printf '%s' "$value" | tr '[:upper:]' '[:lower:]')" = anthropic ] || continue
    elif ! fm_pi_model_is_claude "$value"; then
      continue
    fi
    echo "error: refusing to launch $harness with $word: $FM_PI_MODEL_GUARD_REASON; run Claude work with --harness claude, or give Pi a non-Claude --model <provider>/<id>" >&2
    return 1
  done
  return 0
}
