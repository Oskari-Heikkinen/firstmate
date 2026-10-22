#!/usr/bin/env bash
# fm-away-watch.sh - the away watchdog: an active alert when away-mode
# supervision has stopped and nothing inside the session can say so.
#
# Usage:
#   fm-away-watch.sh run [--home DIR] [--now EPOCH]   check once and alert (the timer runs this)
#   fm-away-watch.sh install-timer [--home DIR]       write and enable the systemd user timer
#   fm-away-watch.sh uninstall-timer [--home DIR]     disable and remove that home's timer
#   fm-away-watch.sh --help
#
# It runs outside every agent session, so it still runs when main cannot run
# turns at all: a quota or limit pause, a dialog waiting for input, or a dead
# session. docs/supervision-host.md "Failure direction" owns why it exists and
# docs/configuration.md "Away watchdog" owns its settings.
#
# run does nothing unless this home holds an away record that is not quiet
# mode's (bin/fm-afk-contract.sh fm_afk_contract_away_present). Otherwise it
# checks five conditions and alerts on each that holds:
#   host    the home runs the supervision host (config/supervision-host), no
#           host process is live under the identity state/.supervision-host
#           records, and no main or host activity is newer than the host
#           threshold (default 30 minutes). Activity is the newest of the host
#           ledger's last line and the mtimes of the away record, the session
#           lock, the host record, the Stop-hook arm ledger, and the dialog
#           mirror. No signal says a main turn is under way, so a main turn
#           that runs longer than the threshold with no host also alerts;
#   lock    the session lock's recorded owner is dead, or no session holds it;
#   latch   the host's broken-session latch, kept under the current main
#           session, has held past one cooldown (a probe failed and doubled it,
#           or its cooldown ended with no probe yet);
#   queue   a row of the durable wake queue has waited unacknowledged longer
#           than the queue threshold (default 60 minutes);
#   autoarm the Stop hook's auto-arm failure markers
#           (state/.claude-autoarm-failure-notified or -alarmed) exist.
# Each condition alerts at most once per re-alert interval (default an hour).
# The alerts that are due go out as one summary through the channels
# config/wedge-alarm names (bin/fm-alert-lib.sh, docs/wedge-alarm.md). The
# text carries only the home name (the second mate's id, or main), each
# condition and its duration, never task titles, decisions or report text,
# since a channel may be a public topic.
#
# The durable marker state/.away-watch-alert records every condition that
# alerted in the current away window: a first line "window\t<entered_epoch>"
# naming the away record, then one row per condition,
# "<condition>\t<first-epoch>\t<last-epoch>\t<count>\t<text>". A new away
# window starts a new marker. The marker is also the rate-limit store, and the
# return brief (bin/fm-afk-return.sh) turns its rows into one health line.
# Each run logs to state/.away-watch.log (bounded).
#
# install-timer writes fm-away-watch-<id>.service and fm-away-watch-<id>.timer
# into ${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user, where <id> is the
# cksum of the selected home's path, so each home gets its own pair. The
# service is pinned to this code root and that home and carries the
# installer's PATH (and HERDR_SOCKET_PATH when set), so herdr and command:
# channels resolve as they do in a session. It then runs
# `systemctl --user daemon-reload` and `systemctl --user enable --now` on the
# timer. The timer runs every 5 minutes and is Persistent=true; the service is
# a oneshot capped at 2 minutes. uninstall-timer disables the selected home's
# timer and removes both its units; neither touches the marker or the log.
#
# Thresholds, each in seconds, from the environment or else from the local
# config/away-watch (one key=value per line, read every run):
#   FM_AWAY_WATCH_HOST_SECS    host_secs     default 1800
#   FM_AWAY_WATCH_QUEUE_SECS   queue_secs    default 3600
#   FM_AWAY_WATCH_REALERT_SECS realert_secs  default 3600
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CODE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

usage() { sed -n '2,/^set -u$/p' "${BASH_SOURCE[0]}" | sed -e '$d' -e 's/^# \{0,1\}//'; }
die() { printf 'fm-away-watch: %s\n' "$*" >&2; exit 2; }

cmd=
case "${1:-}" in
  run|install-timer|uninstall-timer) cmd=$1; shift ;;
  -h|--help|'') usage; exit 0 ;;
  *) die "unknown command: $1 (see --help)" ;;
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
UNIT="fm-away-watch-$(printf '%s' "$home" | cksum | cut -d' ' -f1)"

unit_dir() { printf '%s/systemd/user\n' "${XDG_CONFIG_HOME:-$HOME/.config}"; }

# systemd unit lines get these paths verbatim, so only plain path characters pass.
safe_path() { [[ "$1" =~ ^/[A-Za-z0-9._/@+-]+$ ]]; }

# unit_env NAME VALUE: one quoted Environment= line, escaped for a unit file.
unit_env() {
  local value=$2
  case "$value" in *$'\n'*) die "$1 holds a newline a unit file cannot carry" ;; esac
  value=${value//\\/\\\\}
  value=${value//\"/\\\"}
  value=${value//%/%%}
  printf 'Environment="%s=%s"\n' "$1" "$value"
}

install_timer() {
  local dir env_lines
  safe_path "$CODE_ROOT" || die "code root has characters a unit file cannot carry: $CODE_ROOT"
  safe_path "$home" || die "home has characters a unit file cannot carry: $home"
  env_lines=$(unit_env PATH "$PATH") || exit 2
  if [ -n "${HERDR_SOCKET_PATH:-}" ]; then
    env_lines+=$'\n'$(unit_env HERDR_SOCKET_PATH "$HERDR_SOCKET_PATH") || exit 2
  fi
  dir=$(unit_dir)
  mkdir -p "$dir" || die "cannot create $dir"
  cat > "$dir/$UNIT.service.tmp" <<EOF
[Unit]
Description=Firstmate away watchdog check for $home

[Service]
Type=oneshot
TimeoutStartSec=120
Environment=FM_HOME=$home
$env_lines
ExecStart=/usr/bin/env bash $CODE_ROOT/bin/fm-away-watch.sh run --home $home
EOF
  cat > "$dir/$UNIT.timer.tmp" <<EOF
[Unit]
Description=Run the Firstmate away watchdog every 5 minutes

[Timer]
OnBootSec=5min
OnCalendar=*:0/5
Persistent=true
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

case "$cmd" in
  install-timer) install_timer; exit 0 ;;
  uninstall-timer) uninstall_timer; exit 0 ;;
esac

# --- run ---------------------------------------------------------------------

export FM_HOME=$home
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
MARKER="$STATE/.away-watch-alert"
LOG="$STATE/.away-watch.log"

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-session-lock-lib.sh
. "$SCRIPT_DIR/fm-session-lock-lib.sh"
# shellcheck source=bin/fm-supervision-engine-lib.sh
. "$SCRIPT_DIR/fm-supervision-engine-lib.sh"
# shellcheck source=bin/fm-afk-contract.sh
. "$SCRIPT_DIR/fm-afk-contract.sh"
# shellcheck source=bin/fm-parent-channel-lib.sh
. "$SCRIPT_DIR/fm-parent-channel-lib.sh"
# shellcheck source=bin/fm-alert-lib.sh
. "$SCRIPT_DIR/fm-alert-lib.sh"
WEDGE_ALARM_TITLE="firstmate: away watchdog"

[ -n "$now" ] || now=$(date +%s)

# Append one line to the bounded run log; never fails the run.
log() {
  local tmp
  printf '%s\t%s\n' "$now" "$*" >> "$LOG" 2>/dev/null || return 0
  if [ "$(wc -l < "$LOG" 2>/dev/null | tr -d ' ')" -gt 600 ] 2>/dev/null; then
    tmp=$(mktemp "$LOG.tmp.XXXXXX" 2>/dev/null) || return 0
    tail -n 400 "$LOG" > "$tmp" 2>/dev/null && mv -f "$tmp" "$LOG" 2>/dev/null
    rm -f "$tmp" 2>/dev/null || true
  fi
  return 0
}

# setting <env-value> <config-key> <default>: a positive integer from the
# environment, else from config/away-watch, else the default.
setting() {
  local value=$1
  [ -n "$value" ] || value=$(sed -n "s/^[[:space:]]*$2[[:space:]]*=[[:space:]]*//p" "$CONFIG/away-watch" 2>/dev/null | tail -n 1 | tr -d '[:space:]')
  case "$value" in ''|0*|*[!0-9]*) printf '%s\n' "$3" ;; *) printf '%s\n' "$value" ;; esac
}

fm_afk_contract_away_present "$STATE" || exit 0

HOST_SECS=$(setting "${FM_AWAY_WATCH_HOST_SECS:-}" host_secs 1800)
QUEUE_SECS=$(setting "${FM_AWAY_WATCH_QUEUE_SECS:-}" queue_secs 3600)
REALERT_SECS=$(setting "${FM_AWAY_WATCH_REALERT_SECS:-}" realert_secs 3600)

clock() { fm_supervision_host_clock "$1"; }

# Newer of a running maximum and one file's mtime.
newest_mtime() {  # <current> <file>...
  local best=$1 file m
  shift
  for file in "$@"; do
    m=$(fm_path_mtime "$file") || continue
    case "$m" in ''|*[!0-9]*) continue ;; esac
    [ "$m" -le "$best" ] || best=$m
  done
  printf '%s\n' "$best"
}

# 0 when a process of the host record's identity is live.
host_live() {
  local role pid identity current
  [ -f "$STATE/.supervision-host" ] || return 1
  IFS=$'\t' read -r role pid identity < "$STATE/.supervision-host" 2>/dev/null || [ -n "${role:-}" ] || return 1
  [ "$role" = host ] && [ -n "$identity" ] || return 1
  fm_pid_alive "$pid" || return 1
  _fm_engine_identity_to current "$pid" 2>/dev/null && [ "$current" = "$identity" ]
}

check_host() {
  local last line
  fm_supervision_host_enabled "$CONFIG" || return 0
  host_live && return 0
  last=0
  line=$(tail -n 1 "$STATE/.supervision-host.log" 2>/dev/null) || line=
  line=${line%%$'\t'*}
  case "$line" in ''|*[!0-9]*) ;; *) last=$line ;; esac
  last=$(newest_mtime "$last" "$(fm_afk_contract_path "$STATE")" "$STATE/.lock" "$STATE/.supervision-host" \
    "$STATE/.claude-autoarm-epoch" "$STATE/.host-mirror.jsonl")
  [ $((now - last)) -ge "$HOST_SECS" ] || return 0
  if [ "$last" -gt 0 ]; then
    due host "no live supervision host and no main or host activity for $(( (now - last) / 60 )) minutes (last at $(clock "$last"))"
  else
    due host "no live supervision host and no record of main or host activity"
  fi
}

check_lock() {
  fm_session_lock_inspect "$STATE"
  case "$FM_LOCK_INSPECT_STATE" in
    stale) due lock "the main session's lock owner (pid $FM_LOCK_INSPECT_PID) is dead" ;;
    free) due lock "no main session holds the session lock" ;;
  esac
}

check_latch() {
  local file="$STATE/.supervision-host-health" key main cooldown retry
  [ -f "$file" ] || return 0
  main=$(fm_supervision_host_main_key "$STATE" 2>/dev/null) || return 0
  key=$(sed -n 's/^key=//p' "$file" 2>/dev/null | head -n 1)
  case "$key" in "$main|"*) ;; *) return 0 ;; esac
  cooldown=$(sed -n 's/^cooldown=//p' "$file" 2>/dev/null | head -n 1)
  retry=$(sed -n 's/^retry_after=//p' "$file" 2>/dev/null | head -n 1)
  case "$cooldown" in ''|*[!0-9]*) return 0 ;; esac
  case "$retry" in ''|*[!0-9]*) return 0 ;; esac
  [ "$cooldown" -gt 0 ] || return 0
  if [ "$cooldown" -gt "$FM_SUPERVISION_HOST_COOLDOWN" ] || [ "$now" -ge "$retry" ]; then
    due latch "the supervision host's broken-session latch has held past one cooldown (now ${cooldown}s, next probe from $(clock "$retry"))"
  fi
}

check_queue() {
  local oldest
  oldest=$(awk -F '\t' 'NF >= 5 && $1 ~ /^[0-9]+$/ && (min == "" || $1 + 0 < min + 0) { min = $1 } END { print min }' \
    "$FM_WAKE_QUEUE" 2>/dev/null) || oldest=
  case "$oldest" in ''|*[!0-9]*) return 0 ;; esac
  [ $((now - oldest)) -gt "$QUEUE_SECS" ] || return 0
  due queue "a queued wake has waited $(( (now - oldest) / 60 )) minutes unacknowledged (since $(clock "$oldest"))"
}

check_autoarm() {
  local found=
  [ ! -e "$STATE/.claude-autoarm-failure-notified" ] || found="state/.claude-autoarm-failure-notified"
  [ ! -e "$STATE/.claude-autoarm-failure-alarmed" ] || found="${found:+$found and }state/.claude-autoarm-failure-alarmed"
  [ -z "$found" ] || due autoarm "the Stop hook could not arm supervision ($found)"
}

# Collect one holding condition as "<condition>\t<text>".
DUE=
due() {  # <condition> <text>
  DUE="$DUE$1	$(printf '%s' "$2" | tr '\t\n' '  ')
"
}

check_host
check_lock
check_latch
check_queue
check_autoarm

[ -n "$DUE" ] || exit 0

# Start a new marker for a new away window, then fold in the conditions that
# hold, alerting on each whose last alert is older than the re-alert interval.
window=$(fm_afk_contract_read_field "$(fm_afk_contract_path "$STATE")" entered_epoch 2>/dev/null) || window=
[ -n "$window" ] || window=unknown
rows=
if [ "$(awk -F '\t' 'NR == 1 && $1 == "window" { print $2 }' "$MARKER" 2>/dev/null)" = "$window" ]; then
  rows=$(sed -n '2,$p' "$MARKER" 2>/dev/null) || rows=
fi
summary=
while IFS=$'\t' read -r cond text; do
  [ -n "$cond" ] || continue
  prev=$(printf '%s\n' "$rows" | awk -F '\t' -v c="$cond" '$1 == c { print; exit }')
  first=$now last=0 count=0
  if [ -n "$prev" ]; then
    IFS=$'\t' read -r _ first last count _ <<<"$prev"
  fi
  case "$last" in ''|*[!0-9]*) last=0 ;; esac
  case "$count" in ''|*[!0-9]*) count=0 ;; esac
  case "$first" in ''|*[!0-9]*) first=$now ;; esac
  if [ "$last" -gt 0 ] && [ $((now - last)) -lt "$REALERT_SECS" ]; then
    continue
  fi
  summary="${summary:+$summary; }$text"
  rows=$(printf '%s\n' "$rows" | awk -F '\t' -v c="$cond" 'NF && $1 != c')
  rows="${rows:+$rows
}$cond	$first	$now	$((count + 1))	$text"
done <<EOF
$DUE
EOF

[ -n "$summary" ] || exit 0
tmp=$(mktemp "$MARKER.tmp.XXXXXX") || exit 1
printf 'window\t%s\n%s\n' "$window" "$rows" > "$tmp" && mv -f "$tmp" "$MARKER"
rm -f "$tmp" 2>/dev/null || true
log "alert	$summary"
printf 'fm-away-watch: %s\n' "$summary"
# The alert may reach a public channel, so it names only the home, the
# conditions and their durations, and the marker by its home-relative path.
home_name=$(fm_parent_channel_home_id "$FM_HOME" 2>/dev/null) || home_name=main
wedge_alarm_notify "away supervision stalled in home $home_name: $summary - see state/.away-watch-alert" "$MARKER"
exit 0
