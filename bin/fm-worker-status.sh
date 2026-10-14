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
if [ -e "$config_dir/fleet-ledger" ]; then
  "$SCRIPT_DIR/fm-fleet-ledger.sh" appended "$config_dir" "$status_file" >/dev/null 2>&1 || true
fi
exit 0
