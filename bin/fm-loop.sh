#!/usr/bin/env bash
# fm-loop.sh - read-only view of the experiment loop: request stages, stall alerts and lead time.
#
# Usage:
#   fm-loop.sh status [--json] [--all] [--home DIR] [--now EPOCH]
#   fm-loop.sh alerts [--home DIR] [--now EPOCH]
#   fm-loop.sh ack <alert-id> [--home DIR]
#   fm-loop.sh leadtime [--json] [--weeks N] [--home DIR] [--now EPOCH]
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
# unacknowledged alert and nothing otherwise, so a watcher check can use it.
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

usage() { sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]}" | sed -e '$d' -e 's/^# \{0,1\}//'; }
die() { printf 'fm-loop: %s\n' "$*" >&2; exit 1; }

case "${1:-}" in
  status|alerts|ack|leadtime) cmd=$1; shift ;;
  -h|--help) usage; exit 0 ;;
  '') die "missing command (see --help)" ;;
  *) die "unknown command: $1 (see --help)" ;;
esac

home=${FM_HOME:-$CODE_ROOT}
args=()
alert_id=
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
    -h|--help) usage; exit 0 ;;
    -*) die "unknown argument: $1 (see --help)" ;;
    *) if [ "$cmd" != ack ] || [ -n "$alert_id" ]; then die "unexpected argument: $1 (see --help)"; fi
      alert_id=$1; shift ;;
  esac
done
[ "$cmd" != ack ] || [ -n "$alert_id" ] || die "ack needs an alert id (see alerts)"
[ -d "$home" ] || die "home not found: $home"
home=$(cd "$home" && pwd -P)

prefix=()
command -v nice >/dev/null 2>&1 && prefix+=(nice -n 19)
command -v ionice >/dev/null 2>&1 && prefix+=(ionice -c3)
command -v timeout >/dev/null 2>&1 && prefix=(timeout -k 5 "$RUN_CAP" "${prefix[@]}")
rc=0
"${prefix[@]}" python3 "$SCRIPT_DIR/fm-loop.py" "$cmd" ${alert_id:+"$alert_id"} --home "$home" "${args[@]}" || rc=$?
[ "$rc" -ne 124 ] || die "passed the ${RUN_CAP}s cap; nothing was changed"
exit "$rc"
