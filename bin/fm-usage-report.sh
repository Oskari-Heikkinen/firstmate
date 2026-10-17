#!/usr/bin/env bash
# fm-usage-report.sh - read-only storage usage readouts. It writes, moves,
# deletes, reserves and schedules nothing, and runs no du walk.
# docs/disk-room.md "Usage report" owns what each readout means; this header
# owns the mechanics.
#
# Usage:
#   fm-usage-report.sh d-line [--from FILE]
#       Print one D: days-to-full line computed only from the output of
#       fm-disk-room.sh growth (or FILE holding that output; - is stdin):
#         D: <free> GiB free (<live|published>) at <UTC time>; last day <rate>
#         GiB/day: full in <N> days (<date>); last week <rate> GiB/day over
#         <span> days: full in <N> days (<date>)
#       A window growth reads as unknown prints "<window> unknown"; a window
#       whose free space did not fall prints "not filling". D: not measured
#       prints "D: unknown (<reason>)". Exit 0 when a line printed, 1 when the
#       growth report failed or holds no D: line, 2 on misuse.
#
#   fm-usage-report.sh report [--json]
#       Print recorded usage per tier (Linux, C:, D:) x owner x kind x age
#       (<1d, 1-7d, 7-30d, >30d, unknown): item count, logical GiB and
#       allocated GiB, under each tier's free space and days to full at the
#       last day's and last week's rate from fm-disk-room.sh growth. A sum any
#       of whose records lacks the size prints "unknown"; the sources section
#       names each source as read, absent, unreadable or not configured.
#       --json prints the fm-usage-report/v1 object (bytes, null for unknown).
#       bin/fm-usage-report.py does the reading, at nice 19 and idle I/O.
#       Exit 0 when the report printed, 2 on misuse.
#
# Environment (all optional):
#   FM_USAGE_DISK_ROOM      the fm-disk-room.sh run for growth and status
#                           (default: the one beside this script)
#   FM_USAGE_LATTICE_CONFIG lattice-data config naming the stores whose
#                           catalog.jsonl, MANIFEST.tsv and MANIFEST.packed.tsv
#                           are read (default ~/.config/lattice-data/config.json)
#   FM_USAGE_PACK_INDEX     TETJET pack index.md (default: not read)
#   FM_USAGE_CENSUS         colon-separated TETJET census logs (default: none)
#   FM_USAGE_RESULTS_ROOT   root the pack index and census units sit under
#                           (default /mnt/d/lattice-data/tetjet-results)
#   FM_USAGE_RECEIPTS       folder of tetjet-collected/v1 receipts (default:
#                           not read)
#   FM_USAGE_LEDGER_CATALOG research catalog.sqlite whose kept table is read
#                           (default ~/lattice-ledger/catalog.sqlite)
#   FM_USAGE_LEDGER_ROOT    where kept steps live (default: that file's folder)
#   FM_USAGE_D_ROOT         paths under this are on D: (default /mnt/d); paths
#   FM_USAGE_C_ROOT         under this are on C: (default /mnt/c); the rest is
#                           Linux
#   FM_USAGE_NOW            epoch override for tests
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() { sed -n '2,/^set -u$/{/^set -u$/d;s/^# \{0,1\}//;p}' "$0"; }
die() { printf 'fm-usage-report: %s\n' "$*" >&2; exit 2; }
now() { printf '%s\n' "${FM_USAGE_NOW:-$(date +%s)}"; }

# window LABEL TEXT FREE_GIB -> one window's part of the line. TEXT is the
# window's words from growth: "<change> GiB over <span> days (<rate> GiB/day)"
# or "unknown".
window() {
  local label=$1 text=$2 free=$3 rate span t
  case "$text" in
    *' GiB over '*' days ('*' GiB/day)'*) ;;
    *) printf '%s unknown' "$label"; return 0 ;;
  esac
  span=${text#* GiB over }; span=${span%% days*}
  rate=${text##*(}; rate=${rate%% GiB/day*}
  printf '%s %s GiB/day' "$label" "$rate"
  [ "$label" = 'last week' ] && printf ' over %s days' "$span"
  t=$(awk -v f="$free" -v r="$rate" -v n="$(now)" 'BEGIN {
    if (r + 0 >= 0) { print "-"; exit }
    d = f / -r; printf "%.1f %d\n", d, n + d * 86400 }')
  if [ "$t" = - ]; then
    printf ': not filling'
  else
    printf ': full in %s days (%s)' "${t% *}" "$(date -u -d "@${t#* }" +%Y-%m-%d)"
  fi
}

cmd_d_line() {
  local from='' out line rest free src day week
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --from) [ "$#" -ge 2 ] || die "--from needs a file"; from=$2; shift 2 ;;
      *) die "d-line: unknown argument: $1" ;;
    esac
  done
  if [ -n "$from" ]; then
    out=$(cat -- "$from") || { echo "fm-usage-report: cannot read $from" >&2; exit 1; }
  else
    out=$("${FM_USAGE_DISK_ROOM:-$SCRIPT_DIR/fm-disk-room.sh}" growth) ||
      { echo "fm-usage-report: fm-disk-room.sh growth failed" >&2; exit 1; }
  fi
  line=$(printf '%s\n' "$out" | grep -m 1 '^D: ')
  case "$line" in
    'D: not measured ('*)
      rest=${line#D: not measured (}
      printf 'D: unknown (not measured: %s)\n' "${rest%%)*}"
      return 0 ;;
    'D: free '*' GiB ('*'), reserved '*'; free last day '*'; last week '*) ;;
    *) echo "fm-usage-report: growth output has no D: line" >&2; exit 1 ;;
  esac
  free=${line#D: free }; free=${free%% GiB*}
  src=${line#* GiB (}; src=${src%%)*}
  day=${line#*; free last day }; day=${day%%; last week *}
  week=${line##*; last week }
  printf 'D: %s GiB free (%s) at %s; %s; %s\n' "$free" "$src" \
    "$(date -u -d "@$(now)" '+%Y-%m-%d %H:%M UTC')" \
    "$(window 'last day' "$day" "$free")" "$(window 'last week' "$week" "$free")"
}

case "${1:-}" in
  d-line) shift; cmd_d_line "$@" ;;
  report)
    shift
    if command -v ionice >/dev/null 2>&1; then
      exec nice -n 19 ionice -c3 python3 "$SCRIPT_DIR/fm-usage-report.py" "$@"
    fi
    exec nice -n 19 python3 "$SCRIPT_DIR/fm-usage-report.py" "$@" ;;
  -h|--help|help) usage ;;
  '') usage >&2; exit 2 ;;
  *) die "unknown command: $1 (see --help)" ;;
esac
