#!/usr/bin/env bash
# fm-component-drift.sh - run the component-skill drift check across homes and
# file one backlog item per drifted skill to that skill's owner home.
#
# Usage:
#   fm-component-drift.sh run [--home DIR] [--result PATH] [--now EPOCH]
#   fm-component-drift.sh --help
#
# It is the body of the daily scheduled run docs/component-map.md ("Drift run")
# describes; docs/examples/component-drift/ holds the schedule file and brief.
# --home is main firstmate's home (default $FM_HOME, else the code root).
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
#   - one item per drifted skill is added Queued in the owner home through
#     that home's bin/fm-tasks-axi.sh, and the home is woken through its
#     bin/fm-inbox.sh note with the task id as request id;
#   - a skill whose drift (every changed, vanished or unreadable source and its
#     hashes) is unchanged since its last item, while that item is still open,
#     files nothing; once that item is done or gone, a still-unchanged drift
#     files a new item; a changed drift files a new item that names the open
#     one; a skill that no longer drifts is forgotten;
#   - a failed add or wake is retried on the next run; a task state it cannot
#     read is treated as open and fails the run.
# With --result it writes the scheduled run's fm-schedule-result/v1 summary
# there (docs/configuration.md "Scheduled runs"): outcome complete or failed,
# carried_over the adds and wakes left to retry, and the log as report.
#
# State is <home>/state/component-drift/ of the --home: ledger.json (one entry
# per drifted skill: its drift fingerprint, task and owner home), log (one
# plain line per event, UTC) and a lock that serializes overlapping runs.
# It runs at nice 19 and ionice -c3. It never edits a skill, map or source.
#
# Exit codes: 0 ran and nothing failed (items may have been filed); 1 ran but
# a map could not be checked, a task state could not be read, or an add or
# wake failed; 2 usage error or could not run.
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
result=
now=
while [ $# -gt 0 ]; do
  case "$1" in
    --home) [ $# -ge 2 ] || die "--home needs a directory"; home=$2; shift 2 ;;
    --result) [ $# -ge 2 ] || die "--result needs a path"; result=$2; shift 2 ;;
    --now) [ $# -ge 2 ] || die "--now needs an epoch"; now=$2; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1 (see --help)" ;;
  esac
done
[ -d "$home" ] || die "home not found: $home"
home=$(cd "$home" && pwd -P)
case "$now" in ''|*[!0-9]*) [ -z "$now" ] || die "--now must be an integer epoch" ;; esac
case "$result" in ''|/*) ;; *) result="$PWD/$result" ;; esac

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
rc=0
"${low[@]}" python3 "$SCRIPT_DIR/fm-component-drift.py" --home "$home" --homes "$TMP/homes.tsv" \
  --code-root "$CODE_ROOT" ${result:+--result "$result"} ${now:+--now "$now"} || rc=$?
exit "$rc"
