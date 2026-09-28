#!/usr/bin/env bash
# fm-board.sh - build the read-only fleet board, or install its 5-minute timer.
#
# Usage:
#   fm-board.sh [--home DIR] [--now EPOCH]    build the board once
#   fm-board.sh install-timer [--home DIR]    write and enable the systemd user timer
#   fm-board.sh uninstall-timer               disable and remove that timer
#   fm-board.sh --help
#
# Build reads published summaries only and writes <home>/state/board/board.json
# and <home>/state/board/index.html atomically; bin/fm-board.py owns the item
# shape, panels and blind-spot rules, and bin/fm_board_tokens.py owns the token
# reader that runs inside the same build (tokens.json, its cursor and fm-usage.v1
# rows under state/board/). The home defaults to FM_HOME, else this code root.
# Homes are main plus every local record in main's data/secondmates.md, parsed
# with bin/fm-secondmate-registry-lib.sh; a remote record is shown as not read.
# Project feeds, detector thresholds and session roots come from
# <home>/config/board-feeds (docs/configuration.md "Fleet board feeds").
# The whole build runs under nice -n 19 ionice -c3 and is capped at 60 seconds.
#
# install-timer writes fm-board.service and fm-board.timer into
# ${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user, pinned to this code root and
# the selected home, then runs `systemctl --user daemon-reload` and
# `systemctl --user enable --now fm-board.timer`. The service is a oneshot with
# Nice=19, IOSchedulingClass=idle, MemoryMax=512M and TimeoutStartSec=75 (the
# build caps itself at 60 s). uninstall-timer disables the timer and removes
# both units. Neither touches the board's output.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CODE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
RUN_CAP=60
UNIT=fm-board

usage() { sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]}" | sed -e '$d' -e 's/^# \{0,1\}//'; }
die() { printf 'fm-board: %s\n' "$*" >&2; exit 1; }

cmd=build
case "${1:-}" in
  install-timer|uninstall-timer) cmd=$1; shift ;;
  -h|--help) usage; exit 0 ;;
esac

home=${FM_HOME:-$CODE_ROOT}
now=
while [ $# -gt 0 ]; do
  case "$1" in
    --home) [ $# -ge 2 ] || die "--home needs a directory"; home=$2; shift 2 ;;
    --now) [ $# -ge 2 ] || die "--now needs an epoch"; now=$2; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1 (see --help)" ;;
  esac
done
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
Description=Firstmate fleet board rebuild (read-only)

[Service]
Type=oneshot
Nice=19
IOSchedulingClass=idle
MemoryMax=512M
TimeoutStartSec=75
Environment=FM_HOME=$home
ExecStart=/usr/bin/env bash $CODE_ROOT/bin/fm-board.sh --home $home
EOF
  cat > "$dir/$UNIT.timer.tmp" <<EOF
[Unit]
Description=Rebuild the Firstmate fleet board every 5 minutes

[Timer]
OnBootSec=2min
OnUnitActiveSec=5min
AccuracySec=30s

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
  printf 'enabled %s.timer; the page is %s/state/board/index.html\n' "$UNIT" "$home"
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

# Main first, then every local second mate; a remote record keeps its row so the
# board can name it as not read.
list_homes() {
  local registry line
  printf 'main\t%s\t0\n' "$home"
  registry="$home/data/secondmates.md"
  [ -f "$registry" ] || return 0
  # shellcheck source=bin/fm-secondmate-registry-lib.sh
  . "$SCRIPT_DIR/fm-secondmate-registry-lib.sh"
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in '- '*) ;; *) continue ;; esac
    secondmate_registry_parse_line "$line" || continue
    [ -n "$SECONDMATE_REGISTRY_ID" ] || continue
    printf '%s\t%s\t%s\n' "$SECONDMATE_REGISTRY_ID" "$SECONDMATE_REGISTRY_HOME" "$SECONDMATE_REGISTRY_REMOTE"
  done < "$registry"
}

BUILD_TMP=
build() {
  local rc=0 prefix=()
  BUILD_TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-board.XXXXXX")
  trap 'rm -rf "$BUILD_TMP"' EXIT
  list_homes > "$BUILD_TMP/homes.tsv"
  command -v nice >/dev/null 2>&1 && prefix+=(nice -n 19)
  command -v ionice >/dev/null 2>&1 && prefix+=(ionice -c3)
  command -v timeout >/dev/null 2>&1 && prefix=(timeout -k 5 "$RUN_CAP" "${prefix[@]}")
  "${prefix[@]}" python3 "$SCRIPT_DIR/fm-board.py" --home "$home" --homes "$BUILD_TMP/homes.tsv" \
    --budget "$RUN_CAP" ${now:+--now "$now"} || rc=$?
  [ "$rc" -ne 124 ] || die "build passed the ${RUN_CAP}s cap; the previous page stays in place"
  return "$rc"
}

case "$cmd" in
  build) build ;;
  install-timer) install_timer ;;
  uninstall-timer) uninstall_timer ;;
esac
