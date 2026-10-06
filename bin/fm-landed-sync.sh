#!/usr/bin/env bash
# Refresh the main home's clone of a project after a landing on its default branch.
#
# Usage: fm-landed-sync.sh <project-dir-or-name>
#
# Called by every landing path so no agent has to remember it: a confirmed PR
# merge (bin/fm-merge-outcome-lib.sh, detached), task cleanup (bin/fm-teardown.sh),
# and a clean merge-queue landing (bin/fm-procevent-merge-queue.sh).
#
# The main home is this home's root, resolved through fm_firstmate_root_home in
# bin/fm-wake-lib.sh (a secondmate on a remote route is its own root). The clone
# is <main home>/projects/<basename of the argument>; in the main home an
# existing argument directory is refreshed directly, preserving registered
# clones outside projects/. A project the main home does not hold is skipped
# silently. When the argument names a clone in this
# home and this home is not the main one, that clone is refreshed first, exactly
# as before, with bin/fm-fleet-sync.sh.
#
# The main clone is refreshed only through bin/fm-fleet-sync.sh, the one guarded
# path: fast-forward only, never forced, never stashed, and a dirty, diverged,
# or off-default clone is left untouched. This script adds two things on top:
#
#   - Stale index lock. Before the refresh, a .git/index.lock (resolved with
#     `git rev-parse --git-path`) that bin/fm-lock-lib.sh proves stale - no
#     process holds it or the clone, and it is at least
#     FM_LANDED_SYNC_LOCK_AGE_MINS (default 10) minutes old - is reported and the
#     refresh is skipped. The lock is never removed here; a person or an agent
#     with the captain's word removes it. A lock that is young or held is left to
#     its owner and the refresh runs as usual.
#   - Report once. A stale lock, a STUCK refresh (dirty, diverged, or off the
#     default branch), and a failed fetch or fast-forward each append one
#     `check:` wake with key landed-sync-<project> to the main home's durable wake
#     queue. The report is recorded in <main home>/state/landed-sync/<project>.reported
#     and is not repeated while the same kind of problem persists; the next
#     successful or already-current refresh clears it. Benign skips (local-only,
#     no origin, not a clone) report nothing.
#
# Output: the fleet-sync lines, then `landed-sync: <project>: <result>`.
# Exit status is 0 unless the arguments are invalid (2); a refresh problem is a
# report, not a failure, so a landing path never stops on it.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
FLEET_SYNC_BIN="$SCRIPT_DIR/fm-fleet-sync.sh"
LOCK_AGE_MINS=${FM_LANDED_SYNC_LOCK_AGE_MINS:-10}
case "$LOCK_AGE_MINS" in ''|*[!0-9]*) LOCK_AGE_MINS=10 ;; esac

usage() {
  sed -n '2,38p' "$0" | sed 's/^# \{0,1\}//'
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac
if [ $# -ne 1 ] || [ -z "$1" ]; then
  echo "usage: fm-landed-sync.sh <project-dir-or-name>" >&2
  exit 2
fi
ARG=$1
NAME=$(basename -- "${ARG%/}")
case "$NAME" in
  ''|.|..|*[!A-Za-z0-9._-]*)
    echo "fm-landed-sync: invalid project name '$NAME'" >&2
    exit 2
    ;;
esac

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-lock-lib.sh
. "$SCRIPT_DIR/fm-lock-lib.sh"
FM_LOCK_LOG_PREFIX=landed-sync

HOME_ABS=$(cd "$FM_HOME" 2>/dev/null && pwd -P) || HOME_ABS=$FM_HOME
MAIN=$(fm_firstmate_root_home "$FM_HOME" 2>/dev/null) || MAIN=
if [ -z "$MAIN" ]; then
  echo "landed-sync: $NAME: skipped: cannot resolve the main home from $FM_HOME"
  exit 0
fi

# This home's own clone, refreshed as before when it is not the main one.
if [ "$MAIN" != "$HOME_ABS" ] && [ -d "$ARG" ]; then
  FM_HOME=$FM_HOME "$FLEET_SYNC_BIN" "$ARG" || true
fi

CLONE="$MAIN/projects/$NAME"
if [ "$MAIN" = "$HOME_ABS" ] && [ -d "$ARG" ]; then
  CLONE=$(cd "$ARG" && pwd -P) || exit 2
fi
if [ ! -d "$CLONE" ]; then
  echo "landed-sync: $NAME: skipped: the main home holds no clone of it"
  exit 0
fi

REPORT_DIR="$MAIN/state/landed-sync"
MARKER="$REPORT_DIR/$NAME.reported"

# report_once <kind> <message>: one main-home wake per episode of <kind>.
report_once() {
  local kind=$1 message=$2 previous='' status=0
  mkdir -p "$REPORT_DIR" || return 1
  fm_lock_acquire_wait "$REPORT_DIR/$NAME.lock" || return 1
  previous=$(head -1 "$MARKER" 2>/dev/null) || previous=
  if [ "$previous" = "$kind" ]; then
    fm_lock_release "$REPORT_DIR/$NAME.lock"
    echo "landed-sync: $NAME: $kind already reported"
    return 0
  fi
  (
    STATE="$MAIN/state"
    FM_WAKE_QUEUE="$STATE/.wake-queue"
    FM_WAKE_QUEUE_LOCK="$STATE/.wake-queue.lock"
    fm_wake_append check "landed-sync-$NAME" "check: landed-sync $NAME: $message"
  ) || status=1
  if [ "$status" -eq 0 ]; then
    printf '%s\n%s\n' "$kind" "$message" > "$MARKER" || status=1
  fi
  fm_lock_release "$REPORT_DIR/$NAME.lock"
  echo "landed-sync: $NAME: reported $kind to the main home"
  return "$status"
}

clear_report() {
  [ -e "$MARKER" ] || return 0
  rm -f "$MARKER"
}

if [ "$(git -C "$CLONE" rev-parse --show-toplevel 2>/dev/null)" = "$(cd "$CLONE" && pwd -P)" ]; then
  LOCK=$(git -C "$CLONE" rev-parse --path-format=absolute --git-path index.lock 2>/dev/null) || LOCK=
  if [ -n "$LOCK" ] && [ -e "$LOCK" ] \
      && fm_lock_is_provably_stale "$LOCK" "$CLONE" "$((LOCK_AGE_MINS * 60))"; then
    age=$(fm_lock_age "$LOCK") || age=0
    report_once stale-lock "the main clone $CLONE was not refreshed: stale git lock $LOCK ($((age / 60)) minutes old, no process holds it) left in place" || true
    exit 0
  fi
fi

OUT=$(FM_HOME=$MAIN "$FLEET_SYNC_BIN" "$CLONE" 2>&1) || true
[ -z "$OUT" ] || printf '%s\n' "$OUT"
problem=$(printf '%s\n' "$OUT" | grep -m1 -E ': STUCK: ') || problem=
if [ -n "$problem" ]; then
  report_once stuck "the main clone was not refreshed: ${problem#*: STUCK: }" || true
  exit 0
fi
problem=$(printf '%s\n' "$OUT" | grep -m1 -E ': skipped: (fetch failed|fast-forward failed)') || problem=
if [ -n "$problem" ]; then
  report_once failed "the main clone was not refreshed: ${problem#*: skipped: }" || true
  exit 0
fi
if printf '%s\n' "$OUT" | grep -qE ': (synced |already current|recovered:|coalesced refresh)'; then
  clear_report
  echo "landed-sync: $NAME: main clone current"
fi
exit 0
