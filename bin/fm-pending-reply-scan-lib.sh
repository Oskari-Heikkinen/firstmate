#!/usr/bin/env bash
# fm-pending-reply-scan-lib.sh - disposable incremental correlation scan cache.
# Sourced lazily by fm-pending-reply-lib.sh; no standalone invocation.
# _fm_pending_reply_scan <record> <status> <corr> <expect> returns the first
# matching line and comma-separated physical line numbers in _fm_pr_scan_first
# and _fm_pr_scan_matches. The pending-reply library remains the policy owner.
# Hidden .scan-<corr>-<path-checksum> siblings of the record persist the input
# identity, consumed bytes, unfinished line and matches atomically. Removing or
# damaging one forces one full read; a bounded 128-byte boundary witness also
# detects truncate/regrow across ticks. Cached matches are evidence, not delivery
# authority. Existing resolve/restatement/sighting owners perform idempotent
# effects, so a crash on either side of a cache commit cannot lose a reply.
# Reads use the existing seek-based status span reader, at most 64 KiB at once.
# Progress is reported only after completed input/parser work through the tick's
# dynamically scoped _fm_pending_reply_on_progress callback, never by a timer.
# FM_PENDING_REPLY_SCAN_PROBE (tests only) logs path, start, length per span.
# Status logs are append-only; shrink, identity change, or a metadata change
# without growth resets the cache. As with the existing status cursors, arbitrary
# same-inode prefix edits concurrent with an append are not an append operation.
# Preserve the parent reader's linked-file policy by resolving a final symlink
# before the no-follow span reader. Signatures still observe the original path's
# target, so retarget/replacement resets rather than reusing the old endpoint.

_fm_pending_reply_scan_body() {
  printf '%s\n' 'pending-reply-scan.v1' "$_prs_key" "$_prs_ident" "$_prs_signature" \
    "$_prs_offset" "$_prs_lines" "$_prs_matches" "$_prs_first" "$_prs_partial" "$_prs_anchor" \
    "$_prs_result_first" "$_prs_result_matches"
}

_fm_pending_reply_scan_anchor() {  # <file> <endpoint>
  local start=0 length=$2
  if [ "$length" -gt 128 ]; then start=$((length - 128)); length=128; fi
  # This is bounded input work even for an unchanged log, and is included in
  # the same probe as the new-byte spans, not hidden by the performance test.
  [ -z "${FM_PENDING_REPLY_SCAN_PROBE:-}" ] || printf '%s\t%s\t%s\n' \
    "$1" "$start" "$length" >> "$FM_PENDING_REPLY_SCAN_PROBE"
  # pipefail prevents a failed read from becoming the checksum of empty bytes.
  (set -o pipefail; _fm_status_read_span "$1" "$start" "$length" | cksum)
}

# Dynamic locals belong to _fm_pending_reply_scan, keeping the per-line path
# entirely in-process. A partial final line has the same physical number when
# completed later; re-observing it must not create another sighting.
_fm_pending_reply_scan_line() {
  fm_pending_reply_line_resolves "$_prs_line" "$_prs_corr" "$_prs_expect" || return 0
  [ -n "$_prs_first" ] || _prs_first=$_prs_line
  case ",$_prs_matches," in *",$_prs_number,"*) return 0 ;; esac
  _prs_matches=${_prs_matches:+$_prs_matches,}$_prs_number
}

# An unterminated line is observable, as in the legacy reader, but its match
# is provisional: an append can change its token boundary or receipt grammar.
# Persist only complete-line matches and re-evaluate the saved unfinished line.
_fm_pending_reply_scan_result() {
  local _prs_first=$_prs_first _prs_matches=$_prs_matches _prs_line _prs_number
  if [ -n "$_prs_partial" ]; then
    _prs_line=$_prs_partial _prs_number=$((_prs_lines + 1))
    _fm_pending_reply_scan_line
    [ -z "${_fm_pending_reply_on_progress:-}" ] || "$_fm_pending_reply_on_progress" >/dev/null || true
  fi
  _fm_pr_scan_first=$_prs_first _fm_pr_scan_matches=$_prs_matches _fm_pr_scan_signature=$_prs_signature
}

_fm_pending_reply_scan() {  # <record> <status-file> <corr> <expect>
  local _prs_rec=$1 _prs_file=$2 _prs_corr=$3 _prs_expect=$4
  local _prs_key _prs_digest _prs_cursor _prs_tmp='' _prs_chunk
  local _prs_version='' _prs_saved_key='' _prs_saved_ident='' _prs_saved_signature=''
  local _prs_checksum='' _prs_actual='' _prs_extra='' _prs_valid=0
  local _prs_ident _prs_signature _prs_fresh_signature _prs_after _prs_size _prs_after_size _prs_read_file
  local _prs_offset=0 _prs_lines=0 _prs_matches='' _prs_first='' _prs_partial='' _prs_anchor='' _prs_boundary
  local _prs_result_first='' _prs_result_matches=''
  local _prs_line _prs_number _prs_length _prs_read_size _prs_start
  # Offsets come from stat/read byte counts, not character lengths. Keep the
  # caller's locale for the policy's whole-token [:alnum:] boundaries.
  _fm_pr_scan_first='' _fm_pr_scan_matches='' _fm_pr_scan_signature=''
  [ -f "$_prs_file" ] && [ -r "$_prs_file" ] || return 1
  _prs_read_file=$_prs_file
  if [ -L "$_prs_file" ]; then
    _prs_read_file=$(perl -MCwd=abs_path -e '
      my $path = abs_path($ARGV[0]); defined($path) or exit 1; print $path;
    ' "$_prs_file") || return 1
    [ -f "$_prs_read_file" ] && [ -r "$_prs_read_file" ] || return 1
  fi
  _prs_key=$(fm_pending_reply_sighting_encode "$_prs_file" 0) || return 1
  _prs_key="$_prs_corr:$_prs_expect:$_prs_key"
  _prs_digest=$(printf '%s' "$_prs_key" | cksum) || return 1
  _prs_digest=${_prs_digest// /-}
  _prs_cursor="${_prs_rec%/*}/.scan-${_prs_rec##*/}-$_prs_digest"
  _prs_signature=$(fm_pending_reply_file_signature "$_prs_file") || return 1
  case "$_prs_signature" in missing|unreadable|'') return 1 ;; esac
  if [ "$_prs_read_file" != "$_prs_file" ] \
    && [ "$(fm_pending_reply_file_signature "$_prs_read_file")" != "$_prs_signature" ]; then
    return 1
  fi
  _prs_ident=${_prs_signature%:*:*:*}
  _prs_size=${_prs_signature#*:*:}; _prs_size=${_prs_size%%:*}
  case "$_prs_size" in ''|*[!0-9]*) return 1 ;; esac
  if [ -f "$_prs_cursor" ] && [ -r "$_prs_cursor" ] && [ ! -L "$_prs_cursor" ]; then
    # Fixed arity plus a checksum makes truncated/garbled cache state disposable,
    # including a plausible but damaged offset. No eval or sourced cache bytes.
    if {
      IFS= read -r _prs_version && IFS= read -r _prs_saved_key \
        && IFS= read -r _prs_saved_ident && IFS= read -r _prs_saved_signature \
        && IFS= read -r _prs_offset && IFS= read -r _prs_lines \
        && IFS= read -r _prs_matches && IFS= read -r _prs_first \
        && IFS= read -r _prs_partial && IFS= read -r _prs_anchor \
        && IFS= read -r _prs_result_first && IFS= read -r _prs_result_matches && IFS= read -r _prs_checksum \
        && ! IFS= read -r _prs_extra
    } < "$_prs_cursor"; then
      if [ "$_prs_version" = pending-reply-scan.v1 ] && [ "$_prs_saved_key" = "$_prs_key" ] \
        && [ "$_prs_saved_ident" = "$_prs_ident" ]; then
        case "$_prs_offset:$_prs_lines:$_prs_matches" in
          *[!0-9:,]*|:*|*::* ) ;;
          *)
            # Verify with the saved signature, before adopting the fresh one.
            _prs_fresh_signature=$_prs_signature
            _prs_signature=$_prs_saved_signature
            _prs_actual=$(_fm_pending_reply_scan_body | cksum)
            _prs_signature=$_prs_fresh_signature
            [ "$_prs_actual" != "$_prs_checksum" ] || _prs_valid=1
            ;;
        esac
      fi
    fi
  fi
  if [ "$_prs_valid" = 1 ]; then
    if [ "$_prs_offset" -gt "$_prs_size" ] \
      || { [ "$_prs_offset" -eq "$_prs_size" ] && [ "$_prs_signature" != "$_prs_saved_signature" ]; }; then
      _prs_valid=0
    fi
  fi
  if [ "$_prs_valid" = 1 ]; then
    _prs_boundary=$(_fm_pending_reply_scan_anchor "$_prs_read_file" "$_prs_offset") || return 1
    [ "$_prs_boundary" = "$_prs_anchor" ] || _prs_valid=0
  fi
  if [ "$_prs_valid" != 1 ]; then
    _prs_offset=0 _prs_lines=0 _prs_matches='' _prs_first='' _prs_partial=''
  elif [ "$_prs_offset" -eq "$_prs_size" ]; then
    _fm_pr_scan_first=$_prs_result_first _fm_pr_scan_matches=$_prs_result_matches _fm_pr_scan_signature=$_prs_signature
    return 0
  fi
  _prs_anchor=$(_fm_pending_reply_scan_anchor "$_prs_read_file" "$_prs_size") || return 1
  _prs_tmp=$(mktemp "$_prs_cursor.tmp.XXXXXXXX") || return 1
  _prs_chunk="$_prs_tmp.chunk"
  _prs_start=$_prs_offset
  while [ "$_prs_offset" -lt "$_prs_size" ]; do
    _prs_length=$((_prs_size - _prs_offset))
    [ "$_prs_length" -le 65536 ] || _prs_length=65536
    if ! _fm_status_read_span "$_prs_read_file" "$_prs_offset" "$_prs_length" > "$_prs_chunk"; then
      rm -f -- "$_prs_tmp" "$_prs_chunk"
      return 1
    fi
    _prs_read_size=$(wc -c < "$_prs_chunk") || _prs_read_size=0
    if [ "$_prs_read_size" -ne "$_prs_length" ]; then
      rm -f -- "$_prs_tmp" "$_prs_chunk"
      return 1
    fi
    [ -z "${FM_PENDING_REPLY_SCAN_PROBE:-}" ] || printf '%s\t%s\t%s\n' \
      "$_prs_file" "$_prs_offset" "$_prs_length" >> "$FM_PENDING_REPLY_SCAN_PROBE"
    while :; do
      if IFS= read -r _prs_line; then
        _prs_line=$_prs_partial$_prs_line
        _prs_partial=''
        _prs_lines=$((_prs_lines + 1))
        _prs_number=$_prs_lines
        _fm_pending_reply_scan_line
        [ -z "${_fm_pending_reply_on_progress:-}" ] || "$_fm_pending_reply_on_progress" >/dev/null || true
      else
        _prs_partial=$_prs_partial$_prs_line
        break
      fi
    done < "$_prs_chunk"
    _prs_offset=$((_prs_offset + _prs_length))
    [ -z "${_fm_pending_reply_on_progress:-}" ] || "$_fm_pending_reply_on_progress" >/dev/null || true
  done
  # A concurrent append remains unread at the captured endpoint. Replacement,
  # shrink or a non-growing rewrite during the read cannot publish a cursor.
  _prs_after=$(fm_pending_reply_file_signature "$_prs_file")
  _prs_after_size=${_prs_after#*:*:}; _prs_after_size=${_prs_after_size%%:*}
  case "$_prs_after_size" in ''|*[!0-9]*) _prs_after_size=0 ;; esac
  _prs_boundary=$(_fm_pending_reply_scan_anchor "$_prs_read_file" "$_prs_size") || _prs_boundary=''
  local _prs_read_after=$_prs_after
  if [ "$_prs_read_file" != "$_prs_file" ]; then
    _prs_read_after=$(fm_pending_reply_file_signature "$_prs_read_file")
  fi
  if [ "$_prs_boundary" != "$_prs_anchor" ] \
    || [ "${_prs_read_after%:*:*:*}" != "$_prs_ident" ] \
    || [ "${_prs_after%:*:*:*}" != "$_prs_ident" ] || [ "$_prs_after_size" -lt "$_prs_size" ] \
    || { [ "$_prs_after_size" -eq "$_prs_size" ] && [ "$_prs_after" != "$_prs_signature" ]; }; then
    rm -f -- "$_prs_tmp" "$_prs_chunk"
    return 1
  fi
  _fm_pending_reply_scan_result
  _prs_result_first=$_fm_pr_scan_first _prs_result_matches=$_fm_pr_scan_matches
  if ! { _fm_pending_reply_scan_body; _fm_pending_reply_scan_body | cksum; } > "$_prs_tmp" \
    || ! mv -f -- "$_prs_tmp" "$_prs_cursor"; then
    rm -f -- "$_prs_tmp" "$_prs_chunk"
    return 1
  fi
  rm -f -- "$_prs_chunk"
  # _prs_start is useful to fixtures observing a reset with an empty input too.
  [ -z "${FM_PENDING_REPLY_SCAN_PROBE:-}" ] || [ "$_prs_start" != "$_prs_size" ] \
    || printf '%s\t%s\t0\n' "$_prs_file" "$_prs_start" >> "$FM_PENDING_REPLY_SCAN_PROBE"
  return 0
}
