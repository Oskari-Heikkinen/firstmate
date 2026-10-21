#!/usr/bin/env bash
# Bind an intentional custom watcher check to its current bytes.
# Usage: fm-check-register.sh <id> [--no-handoff <reason>]
# Retire with fm-check-unregister.sh <id>; do not hand-compose an rm.
#
# Before binding, the shared handoff install check (bin/fm-handoff-actors-lib.sh,
# rules in docs/handoff-coverage.md "Installed tools") must allow fm-check:<id>:
# a fragment stage owned by this home lists it, it is declared as reading and
# writing no handoff, or it is grandfathered. --no-handoff <reason> records that
# declaration first, for a check that touches no handoff record. A refusal
# exits 1 and binds nothing.
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
if [ "$#" -eq 3 ] && [ "$2" = --no-handoff ] && [ -n "$3" ]; then
  NO_HANDOFF=$3
elif [ "$#" -ne 1 ]; then
  set -- ''
fi
if ! fm_pr_task_id_valid "$1"; then
  echo "error: invalid custom check registration" >&2
  exit 2
fi

ID=$1
CHECK="$STATE/$ID.check.sh"
TRUST="$STATE/$ID.check-trust"
[ -d "$STATE" ] && [ ! -L "$STATE" ] || { echo "error: state directory is unavailable" >&2; exit 1; }
[ -f "$CHECK" ] && [ ! -L "$CHECK" ] || { echo "error: custom check is unavailable" >&2; exit 1; }
STATE_DEVICE=$(fm_pr_file_device "$STATE") || exit 1
fm_pr_private_file_valid "$CHECK" 700 "$STATE_DEVICE" \
  || { echo "error: custom check is unavailable" >&2; exit 1; }
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
HASH=$(fm_custom_check_sha256 "$CHECK") || { echo "error: custom check hash is unavailable" >&2; exit 1; }
umask 077
TMP=$(mktemp "$STATE/.fm-custom-check-trust.XXXXXX") || exit 1
trap '[ -z "$TMP" ] || rm -f -- "$TMP"' EXIT HUP INT TERM
printf '%s\n%s\n' fm-custom-check-v1 "$HASH" > "$TMP" || exit 1
chmod 0600 "$TMP" || exit 1
fm_pr_regular_destination_on_device_or_absent "$TRUST" "$STATE_DEVICE" || exit 1
mv -f -- "$TMP" "$TRUST" || exit 1
TMP=
fm_custom_check_registered "$STATE" "$ID" || { rm -f -- "$TRUST"; exit 1; }
printf 'registered: state/%s.check.sh\n' "$ID"
