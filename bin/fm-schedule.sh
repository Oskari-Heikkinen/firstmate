#!/usr/bin/env bash
# fm-schedule.sh - captain-approved scheduled runs: file a backlog task on a calendar.
#
# Usage:
#   fm-schedule.sh scan [--home DIR] [--now EPOCH]     fire due schedules once (the timer runs this)
#   fm-schedule.sh list [--home DIR] [--now EPOCH] [--json]
#                                                     print every schedule across homes
#   fm-schedule.sh validate [--home DIR]              check every schedule file; exit 1 if any is refused
#   fm-schedule.sh resume <home-area> <name> [--home DIR] [--now EPOCH]
#                                                     un-pause a schedule; its next slot is from now
#   fm-schedule.sh install-timer [--home DIR]         write and enable the systemd user timer
#   fm-schedule.sh uninstall-timer                    disable and remove that timer
#   fm-schedule.sh --help
#
# A schedule is one file <home>/config/schedules.d/<name>.conf in main or in any
# local home listed in main's data/secondmates.md; docs/configuration.md
# "Scheduled runs" owns that format, the run record and the fm-schedule-result/v1
# run-summary format. A file that fails validation is refused and shown by
# `list`, `validate` and the board, never fired and never guessed at.
# The calendar is a systemd OnCalendar expression in this machine's local time,
# evaluated with systemd-analyze.
#
# scan, per valid schedule:
#   - a new or changed calendar only records its next slot (nothing fires);
#   - an open task from the previous run is checked through that home's own
#     bin/fm-tasks-axi.sh; once it is done (or gone) the run-summary file is read
#     and exactly one line goes to main firstmate - from a second-mate home
#     through bin/fm-parent-channel-lib.sh, from main through main's own
#     bin/fm-inbox.sh note - naming the schedule, home, time used, and whether
#     and why the run was cut short ("no run summary" with the task's open and
#     close times when no file was written);
#   - a due slot whose previous task is still open is recorded as skipped and
#     notified, and nothing is filed;
#   - otherwise the task sched-<name>-<YYYYMMDDHHMM local slot> is added Queued
#     through that home's bin/fm-tasks-axi.sh (a re-run of the same slot is a
#     no-op) and the home is woken through its durable inbox with
#     `bin/fm-inbox.sh note --request-id <task-id>`, saying this is a
#     captain-approved scheduled run;
#   - the next slot is always the next elapse after now, so after downtime a
#     schedule catches up once, never in a burst, and the run is marked caught up;
#   - two failed runs in a row (a failed or invalid run summary, or a task that
#     could not be filed) pause the schedule and send a blocked line to the
#     home's parent; `resume` clears it.
# scan also writes <main>/state/schedules/summary.json (fm-schedule-summary/v1),
# which the fleet board's Scheduled runs panel reads. Overlapping scans are
# serialized by a lock in that directory. `list` and `validate` change nothing.
#
# install-timer writes fm-schedule.service and fm-schedule.timer into
# ${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user, pinned to this code root and
# the selected home, then runs `systemctl --user daemon-reload` and
# `systemctl --user enable --now fm-schedule.timer`. The timer scans every 15
# minutes and is Persistent=true; the service is a niced oneshot capped at 5
# minutes. uninstall-timer disables the timer and removes both units; neither
# touches schedules or run records.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CODE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
UNIT=fm-schedule

usage() { sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]}" | sed -e '$d' -e 's/^# \{0,1\}//'; }
die() { printf 'fm-schedule: %s\n' "$*" >&2; exit 2; }

cmd=
case "${1:-}" in
  scan|list|validate|resume|install-timer|uninstall-timer) cmd=$1; shift ;;
  -h|--help|'') usage; exit 0 ;;
  *) die "unknown command: $1 (see --help)" ;;
esac

home=${FM_HOME:-$CODE_ROOT}
now=
json=
positional=()
while [ $# -gt 0 ]; do
  case "$1" in
    --home) [ $# -ge 2 ] || die "--home needs a directory"; home=$2; shift 2 ;;
    --now) [ $# -ge 2 ] || die "--now needs an epoch"; now=$2; shift 2 ;;
    --json) [ "$cmd" = list ] || die "--json is for list only"; json=--json; shift ;;
    -h|--help) usage; exit 0 ;;
    -*) die "unknown argument: $1 (see --help)" ;;
    *) positional+=("$1"); shift ;;
  esac
done
case "$cmd" in
  resume) [ "${#positional[@]}" -eq 2 ] || die "resume needs <home-area> <name>" ;;
  *) [ "${#positional[@]}" -eq 0 ] || die "unexpected argument: ${positional[0]}" ;;
esac
[ -d "$home" ] || die "home not found: $home"
home=$(cd "$home" && pwd -P)
case "$now" in ''|*[!0-9]*) [ -z "$now" ] || die "--now must be an integer epoch" ;; esac

unit_dir() { printf '%s/systemd/user\n' "${XDG_CONFIG_HOME:-$HOME/.config}"; }

# systemd unit lines get these paths verbatim, so only plain path characters pass.
safe_path() { [[ "$1" =~ ^/[A-Za-z0-9._/@+-]+$ ]]; }

install_timer() {
  local dir
  safe_path "$CODE_ROOT" || die "code root has characters a unit file cannot carry: $CODE_ROOT"
  safe_path "$home" || die "home has characters a unit file cannot carry: $home"
  dir=$(unit_dir)
  mkdir -p "$dir"
  cat > "$dir/$UNIT.service.tmp" <<EOF
[Unit]
Description=Firstmate scheduled-run scan

[Service]
Type=oneshot
Nice=10
IOSchedulingClass=idle
TimeoutStartSec=300
Environment=FM_HOME=$home
ExecStart=/usr/bin/env bash $CODE_ROOT/bin/fm-schedule.sh scan --home $home
EOF
  cat > "$dir/$UNIT.timer.tmp" <<EOF
[Unit]
Description=Scan Firstmate scheduled runs every 15 minutes

[Timer]
OnBootSec=3min
OnCalendar=*:0/15
Persistent=true
AccuracySec=1min

[Install]
WantedBy=timers.target
EOF
  mv -f "$dir/$UNIT.service.tmp" "$dir/$UNIT.service"
  mv -f "$dir/$UNIT.timer.tmp" "$dir/$UNIT.timer"
  printf 'wrote %s/%s.service and %s.timer (home %s)\n' "$dir" "$UNIT" "$UNIT" "$home"
  command -v systemctl >/dev/null 2>&1 \
    || die "systemctl not found; enable later with: systemctl --user daemon-reload && systemctl --user enable --now $UNIT.timer"
  systemctl --user daemon-reload
  systemctl --user enable --now "$UNIT.timer"
  printf 'enabled %s.timer\n' "$UNIT"
}

uninstall_timer() {
  local dir
  dir=$(unit_dir)
  if command -v systemctl >/dev/null 2>&1; then
    systemctl --user disable --now "$UNIT.timer" 2>/dev/null || true
  fi
  rm -f "$dir/$UNIT.service" "$dir/$UNIT.timer"
  if command -v systemctl >/dev/null 2>&1; then
    systemctl --user daemon-reload 2>/dev/null || true
  fi
  printf 'removed %s.timer and %s.service from %s\n' "$UNIT" "$UNIT" "$dir"
}

# Main first, then every second mate; the engine never reads a remote record.
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

engine() {
  local tmp rc=0
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-schedule.XXXXXX")
  trap 'rm -rf "$tmp"' EXIT
  list_homes > "$tmp/homes.tsv"
  python3 "$SCRIPT_DIR/fm-schedule.py" "$cmd" ${positional[@]+"${positional[@]}"} \
    --home "$home" --homes "$tmp/homes.tsv" --code-root "$CODE_ROOT" ${now:+--now "$now"} ${json:+"$json"} || rc=$?
  return "$rc"
}

case "$cmd" in
  install-timer) install_timer ;;
  uninstall-timer) uninstall_timer ;;
  *) engine ;;
esac
