#!/usr/bin/env bash
# CI-only finite fixture scopes for actual source entrypoints. Never a live home.
# Usage: calibration-tick.sh CHECKOUT watch|supervision-host|spawn|control
set -eu
[ "${GITHUB_ACTIONS:-}" = true ] && [ "${RUNNER_ENVIRONMENT:-}" = github-hosted ] || exit 2
root=$1
family=$2
case "$family" in
  watch)
    # A first-iteration queued-result wake, not a quiet/steady watcher price.
    exec /bin/bash "$root/bin/fm-watch.sh"
    ;;
  supervision-host)
    # Load real finite wait functions only; the source guard forbids activation.
    # shellcheck source=/dev/null
    . "$root/bin/fm-supervision-host.sh" park
    # shellcheck disable=SC2034 # Consumed by the sourced real interval function.
    ARM_PID=$$
    # shellcheck disable=SC2034 # Consumed by the sourced readiness probe.
    READY_PENDING=0
    # shellcheck disable=SC2034 # Consumed by the sourced bounded wait loop.
    POLL=1
    # The self identity models a stable private arm; no arm/backend is started.
    fixture_identity=''
    _fm_engine_identity_to fixture_identity "$$"
    printf 'arm\t%s\t%s\tfixture\n' "$$" "$fixture_identity" > "$HOST_RECORD"
    prepare_park_wait
    fm_supervision_tick_loop_init "$STATE" "$CONFIG" "$STATE/.supervision-host-ticks" supervision-host half-second-wait-v1
    host_wait_interval
    exec 9>&-
    ;;
  spawn|control)
    # Admission refusals, never successful lifecycle transactions. This price
    # applies only to the reviewed matching refusal mix, not ordinary launches.
    rc=0
    if [ "$family" = spawn ]; then
      # The invalid id remains an unconditional admission barrier, with enough
      # operands to reach it. Skip only the ordinary pre-spawn guard (no home
      # actor is under test); never try to repair/arm a watcher from this scope.
      output=$(FM_SPAWN_NO_GUARD=1 /bin/bash "$root/bin/fm-spawn.sh" \
        bad/id "$FM_PROJECTS_OVERRIDE/missing" --mode local-only --yolo off 2>&1) || rc=$?
      expected='invalid task id'
    else
      output=$(/bin/bash "$root/bin/fm-control.sh" 2>&1) || rc=$?
      expected='Usage:'
    fi
    [ "$rc" -eq 2 ] && [[ "$output" = *"$expected"* ]] || { printf '%s\n' "$output" >&2; exit 2; }
    # Refusal must not publish a task or successful start. The logger's one
    # matching invocation is checked separately in both calibration phases.
    [ ! -e "$FM_STATE_OVERRIDE/spawn-starts.jsonl" ] || exit 2
    for meta in "$FM_STATE_OVERRIDE/"*.meta; do [ ! -e "$meta" ] || exit 2; done
    ;;
  *) exit 2 ;;
esac
