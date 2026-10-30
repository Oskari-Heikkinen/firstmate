#!/usr/bin/env bash
# Every systemd service file Firstmate ships as a tracked file sets a finite
# TimeoutStartSec in its [Service] section.
#
# A oneshot service without one has no start limit: a run that hangs stays
# "activating" for good, and every later timer tick for it is skipped, so the
# job stops running with nothing to say so. Units a script writes at install
# time are covered by that script's own test (fm-storage, fm-board,
# fm-schedule, fm-away-watch).
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/git-config-helpers.sh
. "$ROOT/tests/git-config-helpers.sh"

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

pass() {
  printf 'ok - %s\n' "$1"
}

# start_limit FILE: print the [Service] section's TimeoutStartSec value; exit 1
# when there is none, or it is empty, zero or infinity (no limit).
start_limit() {
  awk '
    /^[[:space:]]*\[/ { in_service = ($0 ~ /^[[:space:]]*\[Service\][[:space:]]*$/); next }
    in_service && /^[[:space:]]*TimeoutStartSec[[:space:]]*=/ {
      v = $0
      sub(/^[^=]*=[[:space:]]*/, "", v)
      sub(/[[:space:]]+$/, "", v)
      last = v
    }
    END {
      if (last == "" || last == "0" || last == "infinity") exit 1
      print last
    }
  ' "$1"
}

test_checker_refuses_a_unit_without_a_limit() {
  local tmp
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/fm-systemd-units.XXXXXX") || fail "cannot make a temp dir"
  printf '[Unit]\nDescription=x\n\n[Service]\nType=oneshot\nExecStart=/bin/true\n' >"$tmp/none.service"
  printf '[Unit]\nTimeoutStartSec=5min\n\n[Service]\nType=oneshot\n' >"$tmp/wrong-section.service"
  printf '[Service]\nType=oneshot\nTimeoutStartSec=infinity\n' >"$tmp/infinite.service"
  printf '[Service]\nType=oneshot\nTimeoutStartSec=20min\n' >"$tmp/bounded.service"
  ! start_limit "$tmp/none.service" >/dev/null || fail "a service without TimeoutStartSec passes"
  ! start_limit "$tmp/wrong-section.service" >/dev/null || fail "TimeoutStartSec outside [Service] passes"
  ! start_limit "$tmp/infinite.service" >/dev/null || fail "TimeoutStartSec=infinity passes"
  [ "$(start_limit "$tmp/bounded.service")" = 20min ] || fail "a bounded service is refused"
  rm -rf "$tmp"
  pass "the check refuses a missing, misplaced or infinite start limit"
}

test_every_tracked_service_has_a_start_limit() {
  local units f n=0
  units=$(git -C "$ROOT" ls-files -- '*.service') || fail "git ls-files failed"
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    n=$((n + 1))
    start_limit "$ROOT/$f" >/dev/null || fail "$f has no finite TimeoutStartSec in [Service]"
  done <<<"$units"
  [ "$n" -gt 0 ] || fail "no tracked .service files found"
  pass "every tracked service file ($n) sets a finite TimeoutStartSec"
}

test_checker_refuses_a_unit_without_a_limit
test_every_tracked_service_has_a_start_limit
