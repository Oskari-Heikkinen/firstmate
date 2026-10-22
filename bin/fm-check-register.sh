#!/usr/bin/env bash
# Bind an intentional custom watcher check to its current bytes.
# Usage: fm-check-register.sh <id> [--from <staged-file>] [--no-handoff <reason>]
# Retire with fm-check-unregister.sh <id>; do not hand-compose an rm.
#
# Before binding, the shared handoff install check (bin/fm-handoff-actors-lib.sh,
# rules in docs/handoff-coverage.md "Installed tools") must allow fm-check:<id>:
# a fragment stage owned by this home lists it, it is declared as reading and
# writing no handoff, or it is grandfathered. --no-handoff <reason> records that
# declaration first, for a check that touches no handoff record. A refusal
# exits 1 and binds nothing.
#
# A watcher sweep rejects, and wakes on, a state/<id>.check.sh it finds without
# a matching binding, so a check written in place is exposed from that write
# until this script returns. To install a new or changed check, write it to a
# staged file instead and pass --from: the staged bytes are bound, the binding
# is published, and only then is the staged file renamed to
# state/<id>.check.sh, so a sweep finds no check or a bound one. Replacing
# other bytes leaves only the instant between the two renames, where a sweep
# can pair the old bytes with the new binding. The staged file must be a
# hidden (dot-named) private mode-0700 single-link file directly in the state
# directory, which no watcher glob matches. On success it has become the
# check. A refusal or a failed rename leaves it in place, with the check and
# its binding as they were. On either path, a check whose bytes change before
# the final verification is left unbound, and the script exits 1.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-check-lib.sh
. "$SCRIPT_DIR/fm-check-lib.sh"
# shellcheck source=bin/fm-handoff-actors-lib.sh
. "$SCRIPT_DIR/fm-handoff-actors-lib.sh"

NO_HANDOFF=
STAGED=
ID=${1-}
[ "$#" -eq 0 ] || shift
while [ "$#" -gt 0 ]; do
  case "$1" in
    --no-handoff)
      [ "$#" -ge 2 ] && [ -n "$2" ] && [ -z "$NO_HANDOFF" ] || { ID=; break; }
      NO_HANDOFF=$2
      ;;
    --from)
      [ "$#" -ge 2 ] && [ -n "$2" ] && [ -z "$STAGED" ] || { ID=; break; }
      STAGED=$2
      ;;
    *) ID=; break ;;
  esac
  shift 2
done
if ! fm_pr_task_id_valid "$ID"; then
  echo "error: invalid custom check registration" >&2
  exit 2
fi

CHECK="$STATE/$ID.check.sh"
TRUST="$STATE/$ID.check-trust"
SOURCE=$CHECK
[ -d "$STATE" ] && [ ! -L "$STATE" ] || { echo "error: state directory is unavailable" >&2; exit 1; }
if [ -n "$STAGED" ]; then
  SOURCE=$STAGED
  case "$STAGED" in
    */*) STAGED_DIR=${STAGED%/*} ;;
    *) STAGED_DIR=. ;;
  esac
  case "${STAGED##*/}" in
    .*) ;;
    *) echo "error: the staged custom check must be a hidden file in the state directory" >&2; exit 1 ;;
  esac
  [ "${STAGED_DIR:-/}" -ef "$STATE" ] \
    || { echo "error: the staged custom check must be a hidden file in the state directory" >&2; exit 1; }
fi
[ -f "$SOURCE" ] && [ ! -L "$SOURCE" ] || { echo "error: custom check is unavailable" >&2; exit 1; }
STATE_DEVICE=$(fm_pr_file_device "$STATE") || exit 1
fm_pr_private_file_valid "$SOURCE" 700 "$STATE_DEVICE" \
  || { echo "error: custom check is unavailable" >&2; exit 1; }
if [ -n "$STAGED" ]; then
  fm_pr_regular_destination_on_device_or_absent "$CHECK" "$STATE_DEVICE" \
    || { echo "error: custom check path is unavailable" >&2; exit 1; }
fi
fm_pr_regular_destination_on_device_or_absent "$TRUST" "$STATE_DEVICE" \
  || { echo "error: custom check trust path is unavailable" >&2; exit 1; }
if [ -n "$NO_HANDOFF" ] && ! fm_handoff_actor_declare_none "$FM_HOME" "$STATE" "fm-check:$ID" "$NO_HANDOFF"; then
  echo "error: could not declare fm-check:$ID as touching no handoff: $FM_HANDOFF_ACTOR_WHY" >&2
  exit 1
fi
if ! fm_handoff_actor_install_check "$FM_HOME" "$STATE" "fm-check:$ID"; then
  echo "error: custom check $ID is not registered: $FM_HANDOFF_ACTOR_WHY; a check that touches no handoff registers with --no-handoff <reason>" >&2
  exit 1
fi
HASH=$(fm_custom_check_sha256 "$SOURCE") || { echo "error: custom check hash is unavailable" >&2; exit 1; }
# The binding a failed install puts back; none when the check had no valid one.
PRIOR_HASH=
if [ -n "$STAGED" ] && fm_custom_check_trust_read "$STATE" "$ID"; then
  PRIOR_HASH=$FM_CUSTOM_CHECK_HASH
fi

# Publish a binding to <hash> by one rename, so a sweep reads one whole binding.
trust_publish() {  # <hash>
  TMP=$(mktemp "$STATE/.fm-custom-check-trust.XXXXXX") || return 1
  printf '%s\n%s\n' fm-custom-check-v1 "$1" > "$TMP" || return 1
  chmod 0600 "$TMP" || return 1
  fm_pr_regular_destination_on_device_or_absent "$TRUST" "$STATE_DEVICE" || return 1
  mv -f -- "$TMP" "$TRUST" || return 1
  TMP=
}

umask 077
TMP=
trap '[ -z "$TMP" ] || rm -f -- "$TMP"' EXIT HUP INT TERM
trust_publish "$HASH" || exit 1
if [ -n "$STAGED" ] && ! mv -f -- "$STAGED" "$CHECK"; then
  if [ -z "$PRIOR_HASH" ] || ! trust_publish "$PRIOR_HASH"; then
    rm -f -- "$TRUST"
  fi
  echo "error: could not install the staged custom check as state/$ID.check.sh" >&2
  exit 1
fi
fm_custom_check_registered "$STATE" "$ID" || { rm -f -- "$TRUST"; exit 1; }
printf 'registered: state/%s.check.sh\n' "$ID"
