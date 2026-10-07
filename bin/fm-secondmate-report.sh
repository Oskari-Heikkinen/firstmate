#!/usr/bin/env bash
# fm-secondmate-report.sh - optional helper to append a correlated parent report.
#
# A secondmate answering a marked from-firstmate request must report on the
# parent status channel with the request's corr=<id> token. This helper makes
# that easy, but correctness must not depend on using it: a plain echo of a
# status line that includes the same corr token is equally valid
# (bin/fm-pending-reply-lib.sh).
#
# The write destination is mechanical: this helper never takes a status path.
# It resolves the parent channel through fm_parent_channel_destination
# (bin/fm-parent-channel-lib.sh): a local mate writes the parent home's
# state/<id>.status, and a remote mate writes this home's
# state/parent-replies.status. Call it from the secondmate home with FM_HOME
# set to that home.
#
# Usage:
#   fm-secondmate-report.sh <verb> <corr_id> <note...>
#   fm-secondmate-report.sh --doc <verb> <corr_id> <doc-path> <note...>
#   fm-secondmate-report.sh --receipt <corr_id> [<corr_id>...]
#
# --receipt explicitly acknowledges request uptake, not acceptance or an answer.
# It emits one canonical note with all correlations and no caller-supplied text.
# Local requests must all belong to this mate and expect ack; remote receipts
# are validated by the parent's pending-reply owner when mirrored. An answer
# expectation is never settled by a typed receipt and still needs a real reply.
# Raw ack verbs and free-form/mixed reports are not normalized or suppressed.
#
# Examples:
#   fm-secondmate-report.sh done abcdef0123456789 "audit clean"
#   fm-secondmate-report.sh --doc done abcdef0123456789 data/x/report.md "see report"
set -eu

CALLER_FM_HOME=${FM_HOME:-}
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-pending-reply-lib.sh
. "$SCRIPT_DIR/fm-pending-reply-lib.sh"
# shellcheck source=bin/fm-parent-channel-lib.sh
. "$SCRIPT_DIR/fm-parent-channel-lib.sh"

usage() {
  cat <<'EOF' >&2
Usage:
  fm-secondmate-report.sh <verb> <corr_id> <note...>
  fm-secondmate-report.sh --doc <verb> <corr_id> <doc-path> <note...>
  fm-secondmate-report.sh --receipt <corr_id> [<corr_id>...]
EOF
  exit 2
}

# A receipt has no prose argument: a producer cannot accidentally hide a
# limitation or refusal behind a routine acknowledgement.
if [ "${1:-}" = --receipt ]; then
  shift
  [ "$#" -gt 0 ] && [ -n "$CALLER_FM_HOME" ] || usage
  receipt_destination=$(fm_parent_channel_destination "$CALLER_FM_HOME" "${FM_STATE_OVERRIDE:-$CALLER_FM_HOME/state}") || exit 1
  receipt_id=$(fm_parent_channel_home_id "$CALLER_FM_HOME") || exit 1
  fm_secondmate_parent_record_parse "$CALLER_FM_HOME/.fm-secondmate-parent" || exit 1
  receipt_line='note [receipt=ack]'
  for receipt_corr in "$@"; do
    receipt_corr=${receipt_corr#corr=}
    [[ "$receipt_corr" =~ ^[a-f0-9]{16}$ ]] || usage
    if [ "$FM_SECONDMATE_PARENT_ROUTE" = local ]; then
      receipt_record=$(fm_pending_reply_path "${receipt_destination%/*}" "$receipt_corr")
      if [ ! -f "$receipt_record" ] || [ -L "$receipt_record" ] \
        || [ "$(fm_pending_reply_get "$receipt_record" task_id)" != "$receipt_id" ] \
        || [ "$(fm_pending_reply_expect_of "$receipt_record")" != ack ]; then
        echo "error: receipt requires this mate's known ack expectation: $receipt_corr" >&2
        exit 1
      fi
    fi
    receipt_line="$receipt_line [corr=$receipt_corr]"
  done
  receipt_line="$receipt_line: request received (via-helper)"
  fm_parent_channel_append_once "$receipt_destination" "$(status_stamp_line "$receipt_line")"
  exit $?
fi

DOC_MODE=0
if [ "${1:-}" = "--doc" ]; then
  DOC_MODE=1
  shift
fi

[ $# -ge 2 ] || usage
VERB=$1
CORR=$2
shift 2
if [ "$DOC_MODE" = 1 ]; then
  [ $# -ge 1 ] && [ -n "$1" ] || usage
else
  [ $# -ge 1 ] && [ -n "$*" ] || usage
fi

case "$CORR" in
  corr=*) CORR=${CORR#corr=} ;;
esac
case "$CORR" in
  [a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9][a-fA-F0-9]) ;;
  *)
    echo "error: corr_id must be 16 hex characters (got '$CORR')" >&2
    exit 1
    ;;
esac

HOME_DIR=$CALLER_FM_HOME
case "$HOME_DIR" in
  '')
    echo "error: FM_HOME is required so the helper can resolve the parent channel" >&2
    exit 1
    ;;
esac
STATE_DIR="${FM_STATE_OVERRIDE:-$HOME_DIR/state}"

DESTINATION=
DEST_RC=0
DESTINATION=$(fm_parent_channel_destination "$HOME_DIR" "$STATE_DIR") || DEST_RC=$?
if [ "$DEST_RC" -ne 0 ] || [ -z "$DESTINATION" ]; then
  echo "error: cannot resolve the parent channel from this home (not a seeded secondmate?)" >&2
  exit 1
fi
mkdir -p "$(dirname "$DESTINATION")" 2>/dev/null || true
if [ ! -d "$(dirname "$DESTINATION")" ]; then
  echo "error: cannot create parent directory for status file '$DESTINATION'" >&2
  exit 1
fi

token=$(fm_pending_reply_corr_token "$CORR")
if [ "$DOC_MODE" = 1 ]; then
  DOC_PATH=$1
  shift
  NOTE=$*
  if [ -n "$NOTE" ]; then
    printf -v line '%s [%s]: %s (%s via-helper)' "$VERB" "$token" "$NOTE" "$DOC_PATH"
  else
    printf -v line '%s [%s]: %s (via-helper)' "$VERB" "$token" "$DOC_PATH"
  fi
else
  NOTE=$*
  printf -v line '%s [%s]: %s (via-helper)' "$VERB" "$token" "$NOTE"
fi
printf '%s\n' "$(status_stamp_line "$line")" >> "$DESTINATION"
