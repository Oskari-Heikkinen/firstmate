#!/usr/bin/env bash
# fm-handoff-actors-lib.sh - the shared handoff install check for installers.
#
# Sourced, never executed. docs/handoff-coverage.md ("Installed tools") owns
# the rule: an installer refuses a custom check, timer or service unless a
# handoff-registry/v1 fragment the home sees lists it as a stage actor, or it is
# declared as reading or writing no handoff, or it is grandfathered.
# bin/fm-handoff-actors.py owns the decision; these functions only call it, so
# a shell installer in any home adopts the check by sourcing this file.
#
#   fm_handoff_actor_install_check <home> <state> <actor>
#       0 when <actor> may be installed; 1 when it is refused or cannot be
#       decided (unreadable fragment, missing python3). Sets
#       FM_HANDOFF_ACTOR_VERDICT (declared, none, grandfathered, refused,
#       unknown or error) and FM_HANDOFF_ACTOR_WHY (one sentence).
#   fm_handoff_actor_declare_none <home> <state> <actor> <reason>
#       records <actor> as reading and writing no handoff in <state>; 0 when
#       written or already so, 1 otherwise with FM_HANDOFF_ACTOR_WHY set.
#
# <state> is the home's state directory (normally <home>/state). An actor is
# <kind>:<name>, such as fm-check:disk-room or systemd-timer:tj-sched.timer.

# shellcheck disable=SC2034 # FM_HANDOFF_ACTOR_* are read by callers.
FM_HANDOFF_ACTORS_LIB_DIR="$(d=${BASH_SOURCE[0]%/*}; [ "$d" != "${BASH_SOURCE[0]}" ] || d=.; cd "${d:-/}" && pwd)"
FM_HANDOFF_ACTOR_VERDICT=
FM_HANDOFF_ACTOR_WHY=

fm_handoff_actor_install_check() {  # <home> <state> <actor>
  local out rc
  FM_HANDOFF_ACTOR_VERDICT=error
  FM_HANDOFF_ACTOR_WHY="python3 is not available, so the handoff install check cannot run"
  command -v python3 >/dev/null 2>&1 || return 1
  out=$(python3 "$FM_HANDOFF_ACTORS_LIB_DIR/fm-handoff-actors.py" check --home "$1" --state "$2" -- "$3" 2>&1)
  rc=$?
  case "$out" in
    *$'\t'*$'\t'*)
      FM_HANDOFF_ACTOR_VERDICT=${out%%$'\t'*}
      FM_HANDOFF_ACTOR_WHY=${out#*$'\t'*$'\t'}
      ;;
    *) FM_HANDOFF_ACTOR_WHY="the handoff install check failed (exit $rc): ${out:-no output}" ;;
  esac
  [ "$rc" -eq 0 ]
}

fm_handoff_actor_declare_none() {  # <home> <state> <actor> <reason>
  local out
  FM_HANDOFF_ACTOR_WHY="python3 is not available, so the no-handoff declaration cannot be written"
  command -v python3 >/dev/null 2>&1 || return 1
  out=$(python3 "$FM_HANDOFF_ACTORS_LIB_DIR/fm-handoff-actors.py" declare --home "$1" --state "$2" \
    --none --reason "$4" -- "$3" 2>&1) || { FM_HANDOFF_ACTOR_WHY=${out:-the declaration was not written}; return 1; }
  FM_HANDOFF_ACTOR_WHY=
}
