#!/usr/bin/env bash
# fm-park-churn.sh - alarm when a parked task keeps resuming within the hour.
#
# Usage:
#   fm-park-churn.sh record <task-id> [<epoch>]
#   fm-park-churn.sh check
#   fm-park-churn.sh sync
#   fm-park-churn.sh disarm
#   fm-park-churn.sh --help
#
# Every park resume relaunches a fresh session that re-reads its whole
# context, so a task that parks and resumes several times within an hour pays
# far more than waiting live would (fm-park.sh --help, "Live waits"). This
# script raises that pattern once, as a wake of this home's supervisor.
#
# `record` is run by `fm-park.sh resume` after each successful relaunch. It
# keeps the task's last three resume epochs in state/.park-churn/<task-id>
# (one epoch per line, oldest first, then `alarmed=<UTC day number>` once
# raised). Three resumes within 3600 seconds are a crossing; the first
# crossing of a UTC day writes state/.park-churn/<task-id>.new holding the
# alarm line, and later crossings that day are recorded silently. A record
# that exists but is not a readable regular file, or holds a line that is
# neither an epoch nor `alarmed=<day>`, is a failed reading: record refuses
# with exit 1 and writes the .new alarm naming the file, never starting over.
#
# `check` is the watcher check: it prints each .new line once and removes the
# file, so only new crossings wake. No directory, or one with no .new file, is
# silent. A .new file it cannot read or remove, or a churn path that is not a
# directory, prints a line naming it.
#
# `sync` installs state/park-churn.check.sh, bound with fm-check-register.sh
# --from before it becomes visible, and is idempotent and silent when nothing
# changes; session start runs it. `disarm` retires the check.
#
# Environment:
#   FM_PARK_CHURN_NOW  the epoch `record` uses when none is given (tests)
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CHECK_ID=park-churn
CHURN="$STATE/.park-churn"
WINDOW=3600
KEEP=3

usage() { sed -n '2,/^set -u$/{/^set -u$/d;s/^# \{0,1\}//;p;}' "$0"; }

die() { printf 'fm-park-churn: %s\n' "$1" >&2; exit 1; }

utc_iso() {  # <epoch>
  date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ
}

# publish <file> <text>: replace <file> with <text> by rename.
publish() {
  local tmp
  tmp=$(mktemp "$CHURN/.publish.XXXXXX") || return 1
  if ! printf '%s' "$2" > "$tmp" || ! mv -f -- "$tmp" "$1"; then
    rm -f -- "$tmp"
    return 1
  fi
}

cmd_record() {
  local id=${1-} now=${2-} rec line alarmed='' day first n=0 kept='' iso='' e
  local -a epochs=()
  # shellcheck source=bin/fm-pr-lib.sh
  . "$SCRIPT_DIR/fm-pr-lib.sh"
  fm_task_id_path_safe "$id" || die "not a valid task id: '$id'"
  [ -n "$now" ] || now=${FM_PARK_CHURN_NOW:-$(date +%s)}
  case "$now" in ''|*[!0-9]*) die "not an epoch: $now" ;; esac
  if [ ! -d "$CHURN" ] || [ -L "$CHURN" ]; then
    { [ ! -e "$CHURN" ] && [ ! -L "$CHURN" ]; } || die "$CHURN is not a directory"
    mkdir -p "$CHURN" || die "cannot create $CHURN"
  fi
  rec="$CHURN/$id"
  if [ -e "$rec" ] || [ -L "$rec" ]; then
    if [ ! -f "$rec" ] || [ -L "$rec" ] || [ ! -r "$rec" ]; then
      publish "$rec.new" "park-churn: task $id: its resume record $rec is not a readable regular file; fix or remove it so resume churn is counted again"$'\n' || true
      die "$rec is not a readable regular file"
    fi
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in
        alarmed=*[!0-9]*|alarmed=) line=bad ;;
        alarmed=*) alarmed=${line#alarmed=}; continue ;;
      esac
      case "$line" in
        ''|*[!0-9]*)
          publish "$rec.new" "park-churn: task $id: its resume record $rec holds an unreadable line; fix or remove it so resume churn is counted again"$'\n' || true
          die "$rec holds a line that is not an epoch" ;;
      esac
      epochs+=("$line")
    done < "$rec"
  fi
  epochs+=("$now")
  [ "${#epochs[@]}" -le "$KEEP" ] || epochs=("${epochs[@]:${#epochs[@]}-KEEP}")
  for e in "${epochs[@]}"; do kept="$kept$e"$'\n'; done
  n=${#epochs[@]}
  first=${epochs[0]}
  day=$((now / 86400))
  if [ "$n" -ge "$KEEP" ] && [ $((now - first)) -lt "$WINDOW" ] && [ "$alarmed" != "$day" ]; then
    for e in "${epochs[@]}"; do iso="$iso${iso:+, }$(utc_iso "$e")"; done
    publish "$rec.new" "park-churn: task $id resumed from park $n times within an hour ($iso); each resume re-reads the whole session, so steer it to wait live on waits expected within the live-wait threshold (fm-park.sh --help, \"Live waits\")"$'\n' \
      || die "cannot write the churn alarm $rec.new"
    alarmed=$day
  fi
  [ -z "$alarmed" ] || kept="${kept}alarmed=$alarmed"$'\n'
  publish "$rec" "$kept" || die "cannot write $rec"
}

cmd_check() {
  local f line
  if [ ! -e "$CHURN" ] && [ ! -L "$CHURN" ]; then return 0; fi
  if [ ! -d "$CHURN" ] || [ -L "$CHURN" ]; then
    printf 'park-churn: %s is not a directory, so resume churn cannot be counted; remove it\n' "$CHURN"
    return 0
  fi
  for f in "$CHURN"/*.new; do
    [ -e "$f" ] || [ -L "$f" ] || continue
    line=
    if [ -f "$f" ] && [ ! -L "$f" ]; then
      { IFS= read -r line < "$f" || [ -n "$line" ]; } 2>/dev/null || line=
    fi
    if [ -z "$line" ]; then
      printf 'park-churn: cannot read the churn alarm %s; read and remove it by hand\n' "$f"
      continue
    fi
    if rm -f -- "$f"; then
      printf '%s\n' "$line"
    else
      printf 'park-churn: cannot remove the churn alarm %s after reading it: %s\n' "$f" "$line"
    fi
  done
}

check_body() {
  printf '#!/bin/sh\n# Generated by bin/fm-park-churn.sh sync: park resume churn alarm.\nexec env FM_HOME=%s %s check\n' \
    "$(printf '%q' "$FM_HOME")" "$(printf '%q' "$FM_ROOT/bin/fm-park-churn.sh")"
}

cmd_sync() {
  local check="$STATE/$CHECK_ID.check.sh" body tmp
  [ -d "$STATE" ] || die "state directory $STATE is missing"
  body=$(check_body)
  if [ -f "$check" ] && [ "$(cat "$check")" = "$body" ] && [ -f "$STATE/$CHECK_ID.check-trust" ]; then
    return 0
  fi
  # The register binds the staged bytes before renaming them onto the check, so
  # a watcher sweep never finds the new check unbound.
  tmp=$(umask 077 && mktemp "$STATE/.fm-park-churn-check.XXXXXX") || die "could not write state/$CHECK_ID.check.sh"
  if ! { printf '%s\n' "$body" > "$tmp" && chmod 0700 "$tmp"; }; then
    rm -f -- "$tmp"
    die "could not write state/$CHECK_ID.check.sh"
  fi
  if ! FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/fm-check-register.sh" "$CHECK_ID" --from "$tmp" >/dev/null; then
    rm -f -- "$tmp"
    die "could not register state/$CHECK_ID.check.sh"
  fi
}

cmd_disarm() {
  [ -e "$STATE/$CHECK_ID.check.sh" ] || [ -e "$STATE/$CHECK_ID.check-trust" ] || return 0
  FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/fm-check-unregister.sh" "$CHECK_ID" >/dev/null \
    || die "could not retire state/$CHECK_ID.check.sh"
}

case "${1-}" in
  record) shift; [ "$#" -ge 1 ] && [ "$#" -le 2 ] || { usage >&2; exit 2; }; cmd_record "$@" ;;
  check) shift; [ "$#" -eq 0 ] || { usage >&2; exit 2; }; cmd_check ;;
  sync) shift; [ "$#" -eq 0 ] || { usage >&2; exit 2; }; cmd_sync ;;
  disarm) shift; [ "$#" -eq 0 ] || { usage >&2; exit 2; }; cmd_disarm ;;
  -h|--help|help) usage ;;
  *) usage >&2; exit 2 ;;
esac
