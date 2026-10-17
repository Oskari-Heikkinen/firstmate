#!/usr/bin/env bash
# fm-loop.sh - read-only view of the experiment loop: request stages, stall alerts and lead time.
#
# Usage:
#   fm-loop.sh status [--json] [--all] [--home DIR] [--now EPOCH]
#   fm-loop.sh alerts [--new] [--home DIR] [--now EPOCH]
#   fm-loop.sh ack <alert-id> [--home DIR]
#   fm-loop.sh leadtime [--json] [--weeks N] [--home DIR] [--now EPOCH]
#   fm-loop.sh arm [--home DIR]
#   fm-loop.sh disarm [--home DIR]
#   fm-loop.sh --help
#
# status prints each open request's stage, age in that stage, last event and
# the reason it waits, joined from submit receipts, the hand-off queue,
# operator pickups, collected records, batch registrations and analyses, the
# TETJET snapshot, the ledger catalog, captain-held backlog rows and parks.
# --all also lists closed and analysed requests. TETJET's own capacity alerts
# (tj-lane-refused, tj-idle, tj-capacity-unread) are shown beside the stages,
# never re-raised. A missing or unreadable source reads as unknown for what it
# feeds and never fails the command.
#
# status and alerts both sync the stall alerts: one durable record per alert
# under <home>/state/loop-alerts/<alert-id>.json, with a plain-language event
# log in <home>/state/loop-alerts/log. An alert prints until `ack`; one that
# clears after its ack is raised again if it recurs. alerts prints one line per
# unacknowledged alert and nothing otherwise.
#
# alerts --new is the watcher check's mode: one line per alert raised (or
# raised again after clearing) since this mode last reported it, nothing
# otherwise. Its cursor is <home>/state/loop-alerts/reported.cursor; the first
# run seeds it with every current alert and prints nothing. Acknowledged and
# source-unreadable alerts never print here. It is capped at FM_CHECK_TIMEOUT
# less 5 s (default 25 s); a failed or timed-out run prints one line, once per
# distinct failure, kept in <home>/state/loop-alerts/check-failure.
# arm seeds the cursor when it is absent, writes <home>/state/loop-alerts.check.sh
# to run alerts --new, and binds it with fm-check-register.sh; rerunning it is
# safe. disarm removes the check, its trust binding and the cursor, so a later
# arm seeds afresh. Neither writes outside <home>/state.
# leadtime prints, per request family, ACCEPTED to launch-ready and to first
# result, then the median per-stage lead time by ISO week (default 8 weeks).
#
# Sources, alert thresholds and defaults come from <home>/config/loop-sources
# (docs/configuration.md "Loop sources"); bin/fm-loop.py owns the stage rules
# and alert conditions, and docs/loop-status.md explains them. Every source is
# only read: nothing is woken, consumed or acknowledged. The home defaults to
# FM_HOME, else this code root. Runs under nice -n 19 ionice -c3, capped at 60 s.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CODE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
RUN_CAP=60
CHECK_ID=loop-alerts

usage() { sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]}" | sed -e '$d' -e 's/^# \{0,1\}//'; }
die() { printf 'fm-loop: %s\n' "$*" >&2; exit 1; }

case "${1:-}" in
  status|alerts|ack|leadtime|arm|disarm) cmd=$1; shift ;;
  -h|--help) usage; exit 0 ;;
  '') die "missing command (see --help)" ;;
  *) die "unknown command: $1 (see --help)" ;;
esac

home=${FM_HOME:-$CODE_ROOT}
args=()
alert_id=
new=
while [ $# -gt 0 ]; do
  case "$1" in
    --home) [ $# -ge 2 ] || die "--home needs a directory"; home=$2; shift 2 ;;
    --now) [ $# -ge 2 ] || die "--now needs an epoch"; case "$2" in ''|*[!0-9]*) die "--now must be an integer epoch" ;; esac
      args+=(--now "$2"); shift 2 ;;
    --weeks) [ "$cmd" = leadtime ] || die "--weeks is for leadtime"; [ $# -ge 2 ] || die "--weeks needs a number"
      case "$2" in ''|*[!0-9]*) die "--weeks must be a positive integer" ;; esac
      args+=(--weeks "$2"); shift 2 ;;
    --json) case "$cmd" in status|leadtime) args+=(--json); shift ;; *) die "--json is for status and leadtime" ;; esac ;;
    --all) [ "$cmd" = status ] || die "--all is for status"; args+=(--all); shift ;;
    --new) [ "$cmd" = alerts ] || die "--new is for alerts"; new=1; args+=(--new); shift ;;
    -h|--help) usage; exit 0 ;;
    -*) die "unknown argument: $1 (see --help)" ;;
    *) if [ "$cmd" != ack ] || [ -n "$alert_id" ]; then die "unexpected argument: $1 (see --help)"; fi
      alert_id=$1; shift ;;
  esac
done
[ "$cmd" != ack ] || [ -n "$alert_id" ] || die "ack needs an alert id (see alerts)"
[ -d "$home" ] || die "home not found: $home"
home=$(cd "$home" && pwd -P)
state=$home/state
shim=$state/$CHECK_ID.check.sh

shim_content() {
  printf '%s\n' '#!/usr/bin/env bash' \
    '# Written by fm-loop.sh arm: new loop alerts as a watcher check.' \
    "exec $(printf '%q' "$SCRIPT_DIR/fm-loop.sh") alerts --new --home $(printf '%q' "$home")"
}

# A shim without a matching trust binding is rejected on every watcher cycle,
# so a failed arm leaves neither behind.
arm() {
  local want tmp
  [ -d "$state" ] && [ ! -L "$state" ] || die "state directory is unavailable: $state"
  if [ -L "$shim" ] || { [ -e "$shim" ] && [ ! -f "$shim" ]; }; then die "refusing a non-regular $shim"; fi
  if [ ! -e "$state/loop-alerts/reported.cursor" ]; then
    "$SCRIPT_DIR/fm-loop.sh" alerts --new --home "$home" >/dev/null
    [ -f "$state/loop-alerts/reported.cursor" ] || die "could not seed the reported cursor"
  fi
  want=$(shim_content)
  if [ ! -f "$shim" ] || [ "$(cat "$shim")" != "$want" ]; then
    tmp=$(umask 077; mktemp "$state/.fm-loop-arm.XXXXXX") || die "could not write $shim"
    if ! printf '%s\n' "$want" > "$tmp" || ! chmod 0700 "$tmp" || ! mv -f -- "$tmp" "$shim"; then
      rm -f -- "$tmp"; die "could not write $shim"
    fi
  fi
  if ! env -u FM_STATE_OVERRIDE -u FM_ROOT_OVERRIDE FM_HOME="$home" "$SCRIPT_DIR/fm-check-register.sh" "$CHECK_ID" >/dev/null; then
    rm -f -- "$shim" "$state/$CHECK_ID.check-trust"
    die "could not register $shim; it was removed"
  fi
  printf 'armed: state/%s.check.sh\n' "$CHECK_ID"
}

disarm() {
  env -u FM_STATE_OVERRIDE -u FM_ROOT_OVERRIDE FM_HOME="$home" "$SCRIPT_DIR/fm-check-unregister.sh" "$CHECK_ID" >/dev/null \
    || die "could not unregister $shim"
  rm -f -- "$state/loop-alerts/reported.cursor" "$state/loop-alerts/check-failure"
  printf 'disarmed: state/%s.check.sh\n' "$CHECK_ID"
}

case "$cmd" in
  arm) arm; exit 0 ;;
  disarm) disarm; exit 0 ;;
esac

cap=$RUN_CAP
if [ -n "$new" ]; then
  cap=${FM_CHECK_TIMEOUT:-30}
  case "$cap" in ''|*[!0-9]*) cap=30 ;; esac
  cap=$((cap - 5))
  [ "$cap" -ge 5 ] || cap=5
fi
prefix=()
command -v nice >/dev/null 2>&1 && prefix+=(nice -n 19)
command -v ionice >/dev/null 2>&1 && prefix+=(ionice -c3)
command -v timeout >/dev/null 2>&1 && prefix=(timeout -k 5 "$cap" "${prefix[@]}")
rc=0
if [ -z "$new" ]; then
  "${prefix[@]}" python3 "$SCRIPT_DIR/fm-loop.py" "$cmd" ${alert_id:+"$alert_id"} --home "$home" "${args[@]}" || rc=$?
  [ "$rc" -ne 124 ] || die "passed the ${cap}s cap; nothing was changed"
  exit "$rc"
fi

# The watcher discards stderr and wakes on stdout, so a failure prints one
# stdout line, only when it differs from the last failure, and exits 0.
failure=$state/loop-alerts/check-failure
exec 3>&1
err=$("${prefix[@]}" python3 "$SCRIPT_DIR/fm-loop.py" alerts --home "$home" "${args[@]}" 2>&1 1>&3) || rc=$?
exec 3>&-
if [ "$rc" -eq 0 ]; then
  rm -f -- "$failure"
  exit 0
fi
if [ "$rc" -eq 124 ]; then
  line="loop alerts check passed its ${cap}s cap"
else
  line="loop alerts check failed (rc=$rc): $(printf '%s\n' "$err" | awk 'NF { last = $0 } END { print substr(last, 1, 200) }')"
fi
if [ "$(cat "$failure" 2>/dev/null)" != "$line" ]; then
  printf '%s\n' "$line"
  mkdir -p "$state/loop-alerts" && printf '%s\n' "$line" > "$failure" || true
fi
exit 0
