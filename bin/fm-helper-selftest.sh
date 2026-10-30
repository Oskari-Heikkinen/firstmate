#!/usr/bin/env bash
# fm-helper-selftest.sh - the CI gate that runs every interface version a
# pinned helper serves through the helper's own --self-test, so a new byte
# version cannot land without passing each contract it still claims.
# docs/helper-consumers.md says why the gate exists; this header owns the
# commands, the helper protocol and the gated table.
#
# Usage:
#   fm-helper-selftest.sh select [--base <ref>] [--sha <rev>] [--all]
#   fm-helper-selftest.sh run <helper>...
#   fm-helper-selftest.sh -h | --help
#
# select prints, one per line, each gated helper (the table below) whose
# trigger paths differ between the merge base of <ref> (default origin/main)
# and <rev> (default HEAD) and <rev> itself; --all prints every gated helper.
# A change to this script counts as a change to every helper, so the gate
# itself is exercised whenever it changes. It exits 0, printing nothing when
# no trigger path changed, and 1 when the diff cannot be read, so a caller can
# fail closed and run every helper. bin/fm-ci-plan.sh calls it for the plan's
# helpers output.
#
# run checks each <helper> path, in order, and every version it serves:
#   1. <helper> --interface must exit 0 with one line <name>/v<N>, the latest
#      version it serves.
#   2. For each K from 1 to N, <helper> --interface vK must either exit 0 with
#      exactly <name>/vK (served) or exit 1 (not served: dropped, which the
#      helper-consumer gate treats as a planned migration). Any other answer
#      is a failure.
#   3. Each served vK runs <helper> --self-test vK, which must exit 0.
# The versions come from the helper itself, never from a list kept here.
# Every call runs hermetically: an empty environment but PATH, with HOME,
# FM_HOME, TMPDIR and the XDG directories in one fresh temp directory and
# that directory's work/ as the working directory, so no site policy, home
# config or caller setting reaches the helper. Each call is bounded by 300 s
# where timeout(1) exists. A helper run also fails when it leaves anything in
# its TMPDIR or changes the git checkout that holds it (git status, ignored
# files included), because a self-test must use temp state only.
# It prints one line per version and outcome, an ::error:: line for each
# failure (GitHub annotates the run), and appends the same lines to
# $GITHUB_STEP_SUMMARY when set. Exit 0 when every served version of every
# helper passed, 1 when any failed (each failing helper and version named),
# 2 on a usage error.
#
# The gated table: one line per helper, "<helper> <trigger path>...". The
# triggers are the helper and every file whose bytes it loads under a pin.
# A helper joins the gate by adding a line here, once it serves the protocol
# above (--interface [vK] and --self-test vK).
GATED='
bin/fm-disk-room.sh bin/fm-disk-room.sh bin/fm-storage-admission-lib.sh bin/fm-vhdx-bat.py
'
set -u
# Table fields and helper lists are split on whitespace; none is a glob.
set -f

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SELF_PATH=bin/fm-helper-selftest.sh
CALL_BOUND=300
SUMMARY=${GITHUB_STEP_SUMMARY:-}

usage() {
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
}

die_usage() {
  printf 'fm-helper-selftest: %s\n' "$*" >&2
  exit 2
}

report() {
  printf '%s\n' "$1"
  [ -z "$SUMMARY" ] || printf '%s\n' "$1" >>"$SUMMARY"
}

cmd_select() {
  local base=origin/main sha=HEAD all=0 merge changed line helper path
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --base|--sha)
        [ "$#" -gt 1 ] || die_usage "$1 requires a value"
        case "$1" in --base) base=$2 ;; --sha) sha=$2 ;; esac
        shift 2 ;;
      --all) all=1; shift ;;
      *) die_usage "select: unknown argument: $1" ;;
    esac
  done
  if [ "$all" -eq 1 ]; then
    printf '%s\n' "$GATED" | awk 'NF { print $1 }'
    return 0
  fi
  merge=$(git -C "$ROOT" merge-base "$base" "$sha" 2>/dev/null) || {
    printf 'fm-helper-selftest: cannot find the merge base of %s and %s\n' "$base" "$sha" >&2
    return 1
  }
  changed=$(git -C "$ROOT" diff --name-only --no-renames "$merge" "$sha" -- 2>/dev/null) || {
    printf 'fm-helper-selftest: cannot list the files changed between %s and %s\n' "$merge" "$sha" >&2
    return 1
  }
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    # shellcheck disable=SC2086 # a table line is a word list.
    set -- $line
    helper=$1
    shift
    for path in "$SELF_PATH" "$@"; do
      if grep -qxF -e "$path" <<<"$changed"; then
        printf '%s\n' "$helper"
        break
      fi
    done
  done <<<"$GATED"
}

# call <name> ARG...: the helper run hermetically in $WORLD; sets OUT (stdout
# and stderr) and RC.
call() {
  local name=$1
  shift
  local -a bound=()
  if command -v timeout >/dev/null 2>&1; then
    bound=(timeout --kill-after=10 "$CALL_BOUND")
  fi
  RC=0
  OUT=$(cd "$WORLD/work" && env -i PATH="$PATH" HOME="$WORLD/home" FM_HOME="$WORLD/home" \
    TMPDIR="$WORLD/tmp" XDG_CONFIG_HOME="$WORLD/config" XDG_STATE_HOME="$WORLD/state" \
    XDG_DATA_HOME="$WORLD/data" XDG_CACHE_HOME="$WORLD/cache" LC_ALL=C \
    ${bound[@]+"${bound[@]}"} "$HELPER" "$@" 2>&1) || RC=$?
  case "$RC" in
    124|137) OUT="timed out after ${CALL_BOUND} s ($name)" ;;
  esac
}

# fail_version <label> <why>: one failure line and its annotation.
fail_version() {
  FAILED="${FAILED:+$FAILED; }$1"
  report "FAIL $1: $2"
  printf '::error::fm-helper-selftest: %s: %s\n' "$1" "$2"
}

# checkout_state: the git status of the checkout that holds HELPER, or empty
# outside a checkout.
checkout_state() {
  [ -n "$TOP" ] || return 0
  git -C "$TOP" status --porcelain=v1 --ignored --untracked-files=all 2>&1
}

check_helper() {
  local label=$1 latest name n k served before after first left
  HELPER=$1
  case "$HELPER" in /*) ;; *) HELPER=$PWD/$HELPER ;; esac
  if [ ! -f "$HELPER" ] || [ ! -x "$HELPER" ]; then
    fail_version "$label" "not an executable file"
    return
  fi
  TOP=$(git -C "${HELPER%/*}" rev-parse --show-toplevel 2>/dev/null) || TOP=
  WORLD=$(mktemp -d "${TMPDIR:-/tmp}/fm-helper-selftest.XXXXXX") || {
    fail_version "$label" "cannot create a temp directory"
    return
  }
  mkdir -p "$WORLD/home" "$WORLD/tmp" "$WORLD/work" "$WORLD/config" "$WORLD/state" \
    "$WORLD/data" "$WORLD/cache" || {
    fail_version "$label" "cannot create the hermetic world in $WORLD"
    rm -rf -- "$WORLD"
    return
  }
  before=$(checkout_state)

  call --interface --interface
  IFS= read -r latest <<<"$OUT"
  case "$RC:$latest" in
    0:*/v[1-9]|0:*/v[1-9][0-9]) ;;
    *)
      fail_version "$label" "--interface did not print <name>/v<N> (exit $RC: ${latest:-no output})"
      rm -rf -- "$WORLD"
      return ;;
  esac
  if [ "$OUT" != "$latest" ]; then
    fail_version "$label" "--interface printed more than one line"
    rm -rf -- "$WORLD"
    return
  fi
  name=${latest%/v*}
  n=${latest##*/v}
  report "$label serves $latest (latest)"
  served=0
  k=1
  while [ "$k" -le "$n" ]; do
    call "--interface v$k" --interface "v$k"
    IFS= read -r first <<<"$OUT"
    if [ "$RC" -eq 1 ]; then
      report "$label $name/v$k: not served (${first:-no output})"
    elif [ "$RC" -ne 0 ] || [ "$OUT" != "$name/v$k" ]; then
      fail_version "$label $name/v$k" "--interface v$k answered neither $name/v$k nor exit 1 (exit $RC: ${first:-no output})"
    else
      served=$((served + 1))
      call "--self-test v$k" --self-test "v$k"
      IFS= read -r first <<<"$OUT"
      if [ "$RC" -eq 0 ]; then
        report "pass $label $name/v$k: ${first:-no output}"
      else
        fail_version "$label $name/v$k" "--self-test v$k exited $RC: ${first:-no output}"
      fi
    fi
    k=$((k + 1))
  done
  [ "$served" -gt 0 ] || fail_version "$label" "serves none of v1 to v$n, not even its latest"
  left=$(find "$WORLD/tmp" -mindepth 1 -maxdepth 1 -print 2>&1 | head -n 5)
  [ -z "$left" ] || fail_version "$label" "not hermetic: left temp state in its TMPDIR: $(printf '%s' "$left" | tr '\n' ' ')"
  after=$(checkout_state)
  if [ "$before" != "$after" ]; then
    fail_version "$label" "not hermetic: changed the checkout $TOP (git status differs)"
  fi
  rm -rf -- "$WORLD"
}

cmd_run() {
  local helper
  [ "$#" -gt 0 ] || die_usage "run needs at least one helper path"
  FAILED=
  for helper in "$@"; do
    check_helper "$helper"
  done
  if [ -n "$FAILED" ]; then
    report "fm-helper-selftest: failed: $FAILED"
    return 1
  fi
  report "fm-helper-selftest: every served version passed: $*"
}

case "${1:-}" in
  select) shift; cmd_select "$@" ;;
  run) shift; cmd_run "$@" ;;
  -h|--help) usage ;;
  '') die_usage "needs a command (see --help)" ;;
  *) die_usage "unknown command: $1 (see --help)" ;;
esac
