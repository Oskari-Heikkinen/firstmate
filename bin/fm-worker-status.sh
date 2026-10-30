#!/usr/bin/env bash
# fm-worker-status.sh - append one status line for a ship or scout worker.
#
# bin/fm-brief.sh renders this command, with the task's own status file and
# its home's config directory filled in, as the one way a worker reports
# status. A worker runs it with no firstmate environment, so both paths are
# arguments.
#
# Usage:
#   fm-worker-status.sh <status-file> <config-dir> '<state> [tags] [at=<epoch>]: <note>'
#
# The line is the template the brief shows, for example
# 'blocked [at=<epoch>]: need a token' or
# 'needs-decision [at=<epoch>] [key=nm-1-review]: ask-user findings=...'.
# A literal <epoch> becomes the current Unix time; a line with no time tag is
# stamped (status_stamp_line in bin/fm-classify-lib.sh), and a line that
# already carries digits keeps them. <state> must be working, needs-decision,
# blocked, done, failed, resolved, note, or the configured declared-wait verb
# (FM_CLASSIFY_PAUSED_VERB), and the line must be one line with a colon.
#
# On a declared-wait line, a wait tag the supervisor cannot check (an unknown
# kind, a malformed or repeated tag, a process tag without its start token and
# time) reads as a lapsed wait and wakes the supervisor, and a line with no wait
# tag at all keeps the periodic recheck because nothing can check when it ends.
# Either line is still appended exactly as it would be otherwise, and one
# warning on stderr names the problem and the valid kinds (FM_WAIT_KINDS in
# bin/fm-classify-lib.sh, which owns them). Other verbs never warn.
#
#   fm-worker-status.sh --process-tag <pid> <UTC|+seconds>
# prints the [wait=process:<pid>:<start>:<UTC>] tag for a long command the
# worker started (`cmd & pid=$!`), with the time it must end by as
# <YYYY-MM-DDTHH:MM[:SS]Z> or as seconds from now. It exits 1 when no such
# process runs and 2 on a malformed or past time.
#
# After the append, when <config-dir>/fleet-ledger exists, the line is
# recorded at once in the opt-in fleet ledger (docs/fleet-ledger.md); a ledger
# failure never changes the exit status, and the watcher capture is the
# backstop.
#
# Exit status: 0 when the line was appended, 2 on a usage error, 1 when the
# append failed (nothing is recorded in the ledger then).
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"

usage() {
  echo "usage: fm-worker-status.sh <status-file> <config-dir> '<state> [at=<epoch>]: <note>'" >&2
  exit 2
}

case "${1:-}" in
  -h|--help) sed -n '2,/^set -u$/{ /^set -u$/d; s/^# \{0,1\}//; p; }' "$0"; exit 0 ;;
  --process-tag)
    [ "$#" -eq 3 ] || { echo "usage: fm-worker-status.sh --process-tag <pid> <UTC|+seconds>" >&2; exit 2; }
    until=$3
    case "$until" in
      +*)
        case "${until#+}" in ''|*[!0-9]*) echo "error: '+<seconds>' needs digits (got '$until')" >&2; exit 2 ;; esac
        [ "${#until}" -le 9 ] || { echo "error: '$until' is too far ahead" >&2; exit 2; }
        epoch=$(( $(date +%s) + 10#${until#+} ))
        until=$(date -u -r "$epoch" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
          || date -u -d "@$epoch" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null) \
          || { echo "error: cannot format the time $epoch" >&2; exit 2; }
        ;;
    esac
    rc=0
    status_wait_process_tag "$2" "$until" || rc=$?
    case "$rc" in
      0) printf '\n'; exit 0 ;;
      1) echo "error: no running process has pid '$2'" >&2; exit 1 ;;
      *) echo "error: '$until' is not a future <YYYY-MM-DDTHH:MM[:SS]Z> time" >&2; exit 2 ;;
    esac
    ;;
esac
[ "$#" -ge 3 ] && [ -n "$1" ] && [ -n "$2" ] || usage
status_file=$1
config_dir=$2
shift 2
line=$*
case "$line" in
  *$'\n'*|*$'\r'*) echo "error: a status line must be a single line" >&2; exit 2 ;;
  *:*) ;;
  *) echo "error: a status line needs '<state>: <note>' (got '$line')" >&2; exit 2 ;;
esac
state=${line%%[ :]*}
case "$state" in
  working|needs-decision|blocked|done|failed|resolved|note|"${FM_CLASSIFY_PAUSED_VERB:-$FM_CLASSIFY_PAUSED_VERB_DEFAULT}") ;;
  *) echo "error: unknown state '$state'" >&2; exit 2 ;;
esac

if epoch=$(date +%s); then
  line=${line//<epoch>/$epoch}
fi
line=$(status_stamp_line "$line")

if ! printf '%s\n' "$line" >> "$status_file"; then
  echo "error: cannot append to '$status_file'" >&2
  exit 1
fi
if ! status_is_paused "$line"; then
  :
elif problem=$(status_wait_tag_problem "$line"); then
  printf 'warning: recorded as written, but the supervisor cannot check this wait, so it wakes the supervisor as lapsed: %s\n' "$problem" >&2
elif status_wait_untagged "$line"; then
  printf 'warning: recorded as written, but this wait has no [wait=<kind>:<arg>] tag, so the supervisor cannot check when it ends and rechecks it on the periodic cadence; add one when a machine can check the wait (valid kinds: %s)\n' "$FM_WAIT_KINDS" >&2
fi
if [ -e "$config_dir/fleet-ledger" ]; then
  "$SCRIPT_DIR/fm-fleet-ledger.sh" appended "$config_dir" "$status_file" >/dev/null 2>&1 || true
fi
exit 0
