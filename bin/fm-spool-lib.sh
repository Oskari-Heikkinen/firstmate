#!/usr/bin/env bash
# Checked spool protocol is owned by fm_spool.py. Never use shell EOF as its
# success condition: each loop has its own completion variable, even nested
# loops, and must check it before succeeding. No state grows with row count.
fm_spool() { python3 "${BASH_SOURCE[0]%/*}/fm_spool.py" "$@"; }

# <destination-variable> <completion-variable>; stdin is `fm_spool read FILE`.
# The producer prefixes data, so a filename cannot impersonate completion.
fm_spool_next() {
  local _fm_spool_frame
  if ! IFS= read -r -d '' _fm_spool_frame; then return 1; fi
  case "$_fm_spool_frame" in
    D*) printf -v "$1" '%s' "${_fm_spool_frame#D}" || return 1; return 0 ;;
    E) printf -v "$2" '%s' 1; return 1 ;;
    *) echo 'REFUSED: invalid checked spool frame' >&2; return 1 ;;
  esac
}

fm_spool_end() {
  [ "$1" = 1 ] && return 0
  echo "REFUSED: checked spool did not complete: $2" >&2
  return 2
}

# Capture only a scalar after a complete checked read; unlike -s, this cannot
# silently turn a missing/unreadable/non-regular spool into healthy emptiness.
fm_spool_inspect() {
  # shellcheck disable=SC2034 # Public result, read by the calling predicate.
  FM_SPOOL_NONEMPTY=$(fm_spool inspect "$1") || return 1
}
