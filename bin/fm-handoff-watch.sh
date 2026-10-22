#!/usr/bin/env bash
# fm-handoff-watch.sh - the registry-driven handoff coverage watcher.
#
# Usage:
#   fm-handoff-watch.sh tick [--home DIR] [--root DIR] [--now EPOCH]
#   fm-handoff-watch.sh check [--home DIR]
#   fm-handoff-watch.sh arm [--home DIR]
#   fm-handoff-watch.sh disarm [--home DIR]
#   fm-handoff-watch.sh --help
#
# docs/handoff-coverage.md owns the formats, the checks, the routing and the
# alert keys; bin/fm-handoff-watch.py owns how one pass applies them. A pass
# reads every handoff-registry/v1 fragment on the homes this machine sees, the
# outboxes and places of the stages this home owns, the dated rules of the
# protocols it owns and the heartbeats it watches, and makes one alert store
# per target equal the alarms it wants there. The stores live in
# <home>/state/handoff-watch/stores/<target>.json under store id
# handoff-watch.<home id>, registered in each target home's
# state/alert-stores/ against its state/handoff-watch.status; that home's
# alert-store tick projects them as blocked lines. Cursors, the per-stage
# state, the heartbeat and an append-only log of raised and cleared alarms
# (state/handoff-watch/log) stay under <home>/state/handoff-watch/.
#
# tick runs one pass and prints only alarms it cannot deliver, once per
# occurrence. --root DIR treats every directory under DIR named like a home id
# as that home, for drills in a scratch root; --home must then be one of them.
# check is the watcher check's mode: a tick capped at FM_CHECK_TIMEOUT less 5 s
# (default 25 s) that also prints one line, once per distinct failure, when the
# pass fails or passes its cap (kept in state/handoff-watch/check-failure).
# arm runs a first pass (which writes the first heartbeat), writes
# <home>/state/handoff-watch.check.sh to run check, and binds it with
# fm-check-register.sh; rerunning it is safe. disarm removes the check and its
# trust binding, unregisters this watcher's stores from every home it sees
# (closing their blockers) and removes the heartbeat, so main does not read a
# disarmed watcher as silent. Arm only a home that should watch; drills arm
# nothing.
#
# The home defaults to FM_HOME, else this code root. Runs under nice -n 19
# ionice -c3, capped at 60 s outside check.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CODE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
RUN_CAP=60
CHECK_ID=handoff-watch

usage() { sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]}" | sed -e '$d' -e 's/^# \{0,1\}//'; }
die() { printf 'fm-handoff-watch: %s\n' "$*" >&2; exit 1; }

case "${1:-}" in
  tick|check|arm|disarm) cmd=$1; shift ;;
  -h|--help) usage; exit 0 ;;
  '') die "missing command (see --help)" ;;
  *) die "unknown command: $1 (see --help)" ;;
esac

home=${FM_HOME:-$CODE_ROOT}
args=()
while [ $# -gt 0 ]; do
  case "$1" in
    --home) [ $# -ge 2 ] || die "--home needs a directory"; home=$2; shift 2 ;;
    --root) [ "$cmd" = tick ] || die "--root is for tick"; [ $# -ge 2 ] || die "--root needs a directory"
      [ -d "$2" ] || die "root not found: $2"; args+=(--root "$2"); shift 2 ;;
    --now) [ "$cmd" = tick ] || die "--now is for tick"; [ $# -ge 2 ] || die "--now needs an epoch"
      case "$2" in ''|*[!0-9]*) die "--now must be an integer epoch" ;; esac
      args+=(--now "$2"); shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1 (see --help)" ;;
  esac
done
[ -d "$home" ] || die "home not found: $home"
home=$(cd "$home" && pwd -P)
state=$home/state
shim=$state/$CHECK_ID.check.sh

prefix=()
command -v nice >/dev/null 2>&1 && prefix+=(nice -n 19)
command -v ionice >/dev/null 2>&1 && prefix+=(ionice -c3)

pass() {  # <cap> <command> [args...]
  local cap=$1
  shift
  if command -v timeout >/dev/null 2>&1; then
    timeout -k 5 "$cap" "${prefix[@]}" python3 "$SCRIPT_DIR/fm-handoff-watch.py" "$@"
  else
    "${prefix[@]}" python3 "$SCRIPT_DIR/fm-handoff-watch.py" "$@"
  fi
}

shim_content() {
  printf '%s\n' '#!/usr/bin/env bash' \
    '# Written by fm-handoff-watch.sh arm: the handoff coverage watcher as a watcher check.' \
    "exec $(printf '%q' "$SCRIPT_DIR/fm-handoff-watch.sh") check --home $(printf '%q' "$home")"
}

# A shim without a matching trust binding is rejected on every watcher cycle,
# so new or changed bytes are staged in a hidden file that the register's
# --from binds before it becomes the shim, and a failed arm leaves neither
# behind.
arm() {
  local want tmp=
  [ -d "$state" ] && [ ! -L "$state" ] || die "state directory is unavailable: $state"
  if [ -L "$shim" ] || { [ -e "$shim" ] && [ ! -f "$shim" ]; }; then die "refusing a non-regular $shim"; fi
  pass "$RUN_CAP" tick --home "$home" || die "the first pass failed; nothing was armed"
  want=$(shim_content)
  if [ ! -f "$shim" ] || [ "$(cat "$shim")" != "$want" ]; then
    tmp=$(umask 077; mktemp "$state/.fm-handoff-watch-arm.XXXXXX") || die "could not write $shim"
    if ! printf '%s\n' "$want" > "$tmp" || ! chmod 0700 "$tmp"; then
      rm -f -- "$tmp"; die "could not write $shim"
    fi
  fi
  if ! env -u FM_STATE_OVERRIDE -u FM_ROOT_OVERRIDE FM_HOME="$home" "$SCRIPT_DIR/fm-check-register.sh" "$CHECK_ID" ${tmp:+--from "$tmp"} >/dev/null; then
    rm -f -- ${tmp:+"$tmp"} "$shim" "$state/$CHECK_ID.check-trust"
    die "could not register $shim; it was removed"
  fi
  printf 'armed: state/%s.check.sh\n' "$CHECK_ID"
}

disarm() {
  env -u FM_STATE_OVERRIDE -u FM_ROOT_OVERRIDE FM_HOME="$home" "$SCRIPT_DIR/fm-check-unregister.sh" "$CHECK_ID" >/dev/null \
    || die "could not unregister $shim"
  pass "$RUN_CAP" release --home "$home" || die "the check is removed, but some stores could not be unregistered"
  rm -f -- "$state/handoff-watch/check-failure"
  printf 'disarmed: state/%s.check.sh\n' "$CHECK_ID"
}

case "$cmd" in
  arm) arm; exit 0 ;;
  disarm) disarm; exit 0 ;;
  tick)
    rc=0
    pass "$RUN_CAP" tick --home "$home" "${args[@]}" || rc=$?
    [ "$rc" -ne 124 ] || die "passed the ${RUN_CAP}s cap"
    exit "$rc" ;;
esac

# check: the watcher discards stderr and wakes on stdout, so a failure prints
# one stdout line, only when it differs from the last failure, and exits 0.
cap=${FM_CHECK_TIMEOUT:-30}
case "$cap" in ''|*[!0-9]*) cap=30 ;; esac
cap=$((cap - 5))
[ "$cap" -ge 5 ] || cap=5
failure=$state/handoff-watch/check-failure
rc=0
exec 3>&1
err=$(pass "$cap" tick --home "$home" 2>&1 1>&3) || rc=$?
exec 3>&-
if [ "$rc" -eq 0 ]; then
  rm -f -- "$failure"
  exit 0
fi
if [ "$rc" -eq 124 ]; then
  line="handoff watch check passed its ${cap}s cap"
else
  line="handoff watch check failed (rc=$rc): $(printf '%s\n' "$err" | awk 'NF { last = $0 } END { print substr(last, 1, 200) }')"
fi
if [ "$(cat "$failure" 2>/dev/null)" != "$line" ]; then
  printf '%s\n' "$line"
  mkdir -p "$state/handoff-watch" && printf '%s\n' "$line" > "$failure" || true
fi
exit 0
