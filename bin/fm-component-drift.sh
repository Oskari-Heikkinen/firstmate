#!/usr/bin/env bash
# fm-component-drift.sh - run the component-skill drift check across homes and
# file one backlog item per drifted skill to that skill's owner home.
#
# Usage:
#   fm-component-drift.sh run [--home DIR] [--now EPOCH]
#   fm-component-drift.sh --help
#
# It is the daily drift run docs/component-map.md ("Drift run") describes,
# started by the user timer in docs/examples/component-drift/; --now pins the
# clock for tests. --home is main firstmate's home (default $FM_HOME, else the
# code root).
#
# run, in order:
#   - homes are main plus every local home in main's data/secondmates.md
#     (a remote home is skipped: its files are not on this machine);
#   - in each home it collects the repository maps (the home's own checkout
#     and every <home>/projects/<name> that is a repository top level with a
#     docs/component-map.json) and the home map <home>/config/component-map.json;
#   - a repository checked out in several homes is checked once, in the
#     checkout whose HEAD commit is newest; a checkout's repository is its
#     origin URL, else its real path;
#   - drift is detected only by `fm-component-map.sh drift` on each map; a map
#     it cannot read (exit 2 or 3) fails the run and is named in the summary;
#   - the drift lines are grouped per skill; a skill is identified by its
#     repository and repository-relative path, so two checkouts of one skill
#     are one skill;
#   - the owner home is the skill's frontmatter metadata.owner (a home id
#     from main's data/secondmates.md, or "main"); without one, a skill named
#     by a home map is owned by that home; anything else, including an owner
#     that names no local home, goes to main, and the item says why;
#   - a skill has at most one open item: with none open, one item is added
#     Queued in the owner home through that home's bin/fm-tasks-axi.sh, and
#     the home is woken through its bin/fm-inbox.sh note with the task id as
#     request id;
#   - the drift fingerprint is every changed source with its pinned hash
#     (not its current one, so editing a drifted source again is the same
#     drift), and every vanished or unreadable source;
#   - while the item is open, an unchanged drift does nothing and a changed
#     drift rewrites that item's title and body in place (tasks-axi update
#     --archive-body) and wakes its home again, each rewrite with the task id
#     plus its rewrite count as request id; once the item is done or gone,
#     the next run with drift adds a new item; a skill that no longer drifts
#     is forgotten;
#   - an item whose home is no longer a registered local home (retired from
#     main's data/secondmates.md) counts as gone, so the next item goes to the
#     owner the rule names now;
#   - a failed add, rewrite or wake is retried on the next run; a task state
#     it cannot read in a registered home is treated as open and fails the run;
#   - tasks-axi, and the node it runs on, must be on the run's PATH (a user
#     timer's PATH lacks both unless its service sets one); a run where
#     `tasks-axi --version` fails checks nothing and fails.
# Once the engine starts, a failed run (exit 1, or exit 2 when it crashed or
# was refused because another run holds the lock) wakes main
# through main's bin/fm-inbox.sh note with the summary and the log; an alarm
# main's inbox has not taken is kept and resent by the next run. A usage error
# or a --home that does not exist exits 2 before then and reaches only stderr
# (the journal, under the timer), since there is no home to alarm.
# A stop on request (SIGTERM or SIGINT, to this script or the engine, as
# `systemctl --user stop` sends) is not a failure: the engine saves the
# ledger, logs "stopped on request" and exits 128+signal with no alarm, and
# the next run resolves an add it cut short and retries its wakes.
# The run bounds itself: FM_COMPONENT_DRIFT_MAX_SECS (default 3000, 50 min,
# under the example unit's 1 h TimeoutStartSec, so the start limit's SIGTERM
# never ends a run first) is the longest a run may take once it holds the
# lock. A run that reaches it saves the ledger, logs it and fails with exit 1
# and the usual alarm; a value that is set but not a whole number above 0 is
# a failed reading that does nothing, alarms main and exits 2 (the accepted
# range is 1 to 999999999).
#
# State is <home>/state/component-drift/ of the --home: ledger.json (one entry
# per drifted skill: its drift fingerprint, task and owner home), log (one
# plain line per event, UTC), alarms/ (alarms not yet delivered) and a lock
# that serializes overlapping runs. The ledger is saved after every add,
# rewrite and wake, and an add is recorded before it starts, so a run stopped
# at any point never files an item twice.
# It runs at nice 19 and ionice -c3. It never edits a skill, map or source.
#
# Exit codes: 0 ran and nothing failed (items may have been filed); 1 ran but
# tasks-axi was missing, a map could not be checked, a task state could not
# be read, an add, rewrite or wake failed, or the run reached its bound; 2
# usage error, no such home, crashed, a bad FM_COMPONENT_DRIFT_MAX_SECS, or
# another run holds the lock; 143 (130 for SIGINT) stopped on
# request.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CODE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

usage() { sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]}" | sed -e '$d' -e 's/^# \{0,1\}//'; }
die() { printf 'fm-component-drift: %s\n' "$*" >&2; exit 2; }

case "${1:-}" in
  run) shift ;;
  -h|--help|'') usage; exit 0 ;;
  *) die "unknown command: $1 (see --help)" ;;
esac

home=${FM_HOME:-$CODE_ROOT}
now=
while [ $# -gt 0 ]; do
  case "$1" in
    --home) [ $# -ge 2 ] || die "--home needs a directory"; home=$2; shift 2 ;;
    --now) [ $# -ge 2 ] || die "--now needs an epoch"; now=$2; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1 (see --help)" ;;
  esac
done
[ -d "$home" ] || die "home not found: $home"
home=$(cd "$home" && pwd -P)
case "$now" in ''|*[!0-9]*) [ -z "$now" ] || die "--now must be an integer epoch" ;; esac

# Main first, then every second mate, as bin/fm-schedule.sh lists them.
list_homes() {
  local registry line
  printf 'main\t%s\t0\n' "$home"
  registry="$home/data/secondmates.md"
  [ -f "$registry" ] || return 0
  # shellcheck source=bin/fm-secondmate-registry-lib.sh disable=SC1091
  . "$SCRIPT_DIR/fm-secondmate-registry-lib.sh"
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in '- '*) ;; *) continue ;; esac
    secondmate_registry_parse_line "$line" || continue
    [ -n "$SECONDMATE_REGISTRY_ID" ] || continue
    printf '%s\t%s\t%s\n' "$SECONDMATE_REGISTRY_ID" "$SECONDMATE_REGISTRY_HOME" "$SECONDMATE_REGISTRY_REMOTE"
  done < "$registry"
}

TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-component-drift.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
list_homes > "$TMP/homes.tsv"
low=(nice -n 19)
command -v ionice >/dev/null 2>&1 && low+=(ionice -c3)
"${low[@]}" python3 "$SCRIPT_DIR/fm-component-drift.py" --home "$home" --homes "$TMP/homes.tsv" \
  --code-root "$CODE_ROOT" ${now:+--now "$now"} \
  ${FM_COMPONENT_DRIFT_MAX_SECS+--max-secs "$FM_COMPONENT_DRIFT_MAX_SECS"} &
engine=$!
# A stop sent to this script reaches the engine, and the exit is the engine's
# own: a signal only interrupts wait, so wait again until one returns unbroken.
stop=''
trap 'stop=1; kill -TERM "$engine" 2>/dev/null || :' TERM INT HUP
while :; do
  stop='' rc=0
  wait "$engine" || rc=$?
  [ -n "$stop" ] || break
done
exit "$rc"
