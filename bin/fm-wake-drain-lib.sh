# shellcheck shell=bash
# The wake drain's status-presentation and wake-annotation helpers: the cursor
# commit (status_commit_presentation_snapshot), the annotation printer
# (fm_wake_print_annotations), and the bounded batch reads and admission guards
# the drain's native presentation path validates before it selects any output.
# Usage: . bin/fm-wake-lib.sh; . bin/fm-classify-lib.sh; . bin/fm-wake-drain-lib.sh
#
# Sourced only by bin/fm-wake-drain.sh, after bin/fm-wake-lib.sh and
# bin/fm-classify-lib.sh, whose identity, signature, cursor and marker owners
# these functions call. It sources nothing and defines functions only.
# It lives apart from those two libraries because nearly every script sources
# them: bin/fm-spawn.sh's full ShellCheck analysis follows both and sits at
# CI's per-root memory cap, so drain-only code belongs here, not there.

# Optional GNU-stat batch for explicitly selected native drain reads. Preserve
# the existing strong birth-time identity owner, not Python's device/inode-only
# observation identity. No cursor, marker or status byte is written here.
# Unsupported platforms/overrides, oversized inventories and any malformed or
# incomplete stat result refuse with NO output so the caller can recapture the
# entire snapshot through status_presentation_snapshot before native selection.
status_presentation_snapshot_batch() {  # <state> [mtime]
  local state=$1 capture_mode=${2:-} f task exclude packet row mode size devino epoch birth extra ident result=''
  local mtime format=$'%f\t%s\t%d:%i\t%W\t%w'
  case "$capture_mode" in ''|mtime) ;; *) return 1 ;; esac
  if [ "$capture_mode" = mtime ]; then format+=$'\t%Y'; fi
  local index=0 count=0
  local -a snapshot_batch_files=() snapshot_batch_tasks=()
  [ "$_FM_CLASSIFY_UNAME_S" = Linux ] && [ -z "${FM_STATUS_SIZE_READER:-}" ] \
    && [ -z "${FM_STATUS_IDENTITY_READER:-}" ] || return 1
  exclude=$(status_scan_parent_channel_exclude "$state") || return 1
  for f in "$state"/*.status; do
    [ -e "$f" ] || continue
    [ "$f" = "$exclude" ] && continue
    [ -f "$f" ] && [ -r "$f" ] && [ ! -L "$f" ] || continue
    # This is only an optional bounded read; the legacy owner retains larger
    # inventories rather than truncating or changing its existing admission.
    [ "$count" -lt 256 ] || return 1
    task=${f##*/}; task=${task%.status}
    case "$task" in ''|[!A-Za-z0-9]*|*[!A-Za-z0-9._-]*) return 1 ;; esac
    [ "${#task}" -le 128 ] || return 1
    snapshot_batch_files[count]=$f snapshot_batch_tasks[count]=$task
    count=$((count + 1))
  done
  [ "$count" -gt 0 ] || return 0
  # One stat observes every selected path, in argument order, without putting
  # filenames into the packet. A final-component symlink race is nonregular.
  { packet=$(LC_ALL=C exec stat -c "$format" -- "${snapshot_batch_files[@]}"); } 2>/dev/null || return 1
  while IFS= read -r row; do
    [ "$index" -lt "$count" ] || return 1
    # read's whitespace-IFS collapsing must not admit missing/extra columns.
    case "$row" in *$'\t\t'*|$'\t'*|*$'\t') return 1 ;; esac
    mtime=''
    if [ "$capture_mode" = mtime ]; then
      IFS=$'\t' read -r mode size devino epoch birth mtime extra <<EOF
$row
EOF
      case "$mtime" in ''|*[!0-9]*) return 1 ;; esac
    else
      IFS=$'\t' read -r mode size devino epoch birth extra <<EOF
$row
EOF
    fi
    [ -z "$extra" ] && [ -n "$birth" ] || return 1
    case "$mode" in ''|*[!0-9a-f]*|?????????*) return 1 ;; esac
    [ "$((16#$mode & 61440))" -eq 32768 ] || return 1
    case "$size" in ''|*[!0-9]*) return 1 ;; esac
    case "$devino" in *:*) ;; *) return 1 ;; esac
    case "${devino%%:*}" in ''|*[!0-9]*) return 1 ;; esac
    case "${devino#*:}" in ''|*[!0-9]*) return 1 ;; esac
    case "${epoch#-}" in ''|*[!0-9]*) return 1 ;; esac
    _fm_file_ident_compose_to ident "$devino" "$epoch" "$birth" || return 1
    # Recheck eligibility, like the legacy capture. The existing transaction
    # still verifies this exact identity/endpoint at its commit boundary.
    f=${snapshot_batch_files[$index]}
    [ -f "$f" ] && [ -r "$f" ] && [ ! -L "$f" ] || return 1
    result="$result${snapshot_batch_tasks[$index]}"$'\t'"$size"$'\t'"$ident"
    if [ "$capture_mode" = mtime ]; then result+=$'\t'"$mtime"; fi
    result+=$'\n'
    index=$((index + 1))
  done <<EOF
$packet
EOF
  [ "$index" -eq "$count" ] || return 1
  printf '%s' "$result"
}

# Independent admission guard for a read service's suggested presentation
# endpoints. The caller holds .status-presentation-lock and has not selected
# native output yet. Read the owner's cursor ONCE for the entire captured
# snapshot, not once per row; never trust a service's own claimed lower bound
# as the authority to rewind it. Identity/size resets retain legacy semantics.
# This does not commit a cursor or change the legacy presentation transaction.
# Read a presentation manifest once and project only its identity field through
# the existing identity owner. The batch guards consume this via stdin, not an
# argv document or a second interpretation of old strong identities in awk.
# This is an ephemeral observation, never a cursor migration or record write.
_status_presentation_manifest_canonical() {  # <manifest-path>
  local _pmc_raw _pmc_line _pmc_task _pmc_rest _pmc_ident _pmc_current
  if [ ! -e "$1" ] && [ ! -L "$1" ]; then return 0; fi
  [ -f "$1" ] && [ -r "$1" ] && [ ! -L "$1" ] || return 1
  # Keep malformed binary bytes malformed: a Bash text reader would discard
  # NULs before the guard could reject them. One bounded regular-file read
  # supplies the whole inventory; canonicalization below stays in its owner.
  _pmc_raw=$(LC_ALL=C perl -e '
    use Fcntl qw(O_RDONLY O_NOFOLLOW O_NONBLOCK S_ISREG);
    sysopen(my $file, $ARGV[0], O_RDONLY | O_NOFOLLOW | O_NONBLOCK) or exit 1;
    my @before = stat($file);
    @before && S_ISREG($before[2]) && $before[7] <= 4194304 or exit 1;
    my $data = "";
    while (1) {
      my $read = sysread($file, my $part, 65536);
      defined($read) or exit 1;
      last if $read == 0;
      $data .= $part;
      length($data) <= 4194304 or exit 1;
    }
    index($data, "\0") < 0 or exit 1;
    my @after = stat($file);
    my @path = lstat($ARGV[0]);
    @after && @path && length($data) == $before[7] or exit 1;
    for my $index (0, 1, 2, 7, 9, 10) {
      $before[$index] == $after[$index] && $after[$index] == $path[$index] or exit 1;
    }
    close($file) or exit 1;
    print $data or exit 1;
  ' "$1") || return 1
  while IFS= read -r _pmc_line; do
    [ -n "$_pmc_line" ] || continue
    case "$_pmc_line" in *$'\t'*) ;; *) return 1 ;; esac
    _pmc_task=${_pmc_line%%$'\t'*}; _pmc_rest=${_pmc_line#*$'\t'}
    case "$_pmc_rest" in *$'\t'*) ;; *) return 1 ;; esac
    _pmc_ident=${_pmc_rest%%$'\t'*}
    _fm_file_ident_canon_to _pmc_current "$_pmc_ident"
    printf '%s\t%s\t%s\n' "$_pmc_task" "$_pmc_current" "${_pmc_rest#*$'\t'}" || return 1
  done <<EOF
$_pmc_raw
EOF
}

status_presentation_suggestions_valid() {  # <state> <captured-snapshot> <suggestions>
  local state=$1 snapshot=$2 suggestions=$3 manifest task endpoint ident canonical
  manifest="$state/.status-presentation-cursor"
  if [ -e "$manifest" ] || [ -L "$manifest" ]; then
    [ -f "$manifest" ] && [ -r "$manifest" ] && [ ! -L "$manifest" ] || return 1
  else
    # Only the legacy owner can interpret its migration cursor. The service
    # also refuses that format; independently retain the same boundary here.
    while IFS=$'\t' read -r task endpoint ident; do
      [ -n "$task" ] || continue
      case "$task" in *[!A-Za-z0-9._-]*) return 1 ;; esac
      [ ! -e "$state/.$task.open-decisions-cursor" ] && [ ! -L "$state/.$task.open-decisions-cursor" ] || return 1
    done <<EOF
$snapshot
EOF
  fi
  canonical=$(_status_presentation_manifest_canonical "$manifest") || return 1
  LC_ALL=C awk -F '\t' '
    function uint(value) { return value ~ /^[0-9]+$/ && length(value) <= 16 }
    BEGIN { section=0 }
    $0 == "@snapshot" { if (section != 0) { bad=1; exit }; section=1; next }
    section == 0 && NF != 0 {
      if ((NF != 3 && NF != 4) || $1 == "" || $2 == "" || !uint($3) ||
          (NF == 4 && $4 != "" && !uint($4)) || ($1 in offsets)) { bad=1; exit }
      identities[$1]=$2; offsets[$1]=$3; next
    }
    $0 == "@suggestions" { if (section != 1) { bad=1; exit }; section=2; next }
    NF == 0 { next }
    section == 1 {
      if (NF != 3 || $1 !~ /^[A-Za-z0-9][A-Za-z0-9._-]*$/ || !uint($2) || $3 == "" || ($1 in ends)) { bad=1; exit }
      # Current transaction captures use canonical strong identities. An old
      # device-bearing CAPTURE needs its legacy owner, not a zero cursor floor.
      if ($3 ~ /^strong:[0-9]+:[0-9]+:/) { bad=1; exit }
      ends[$1]=$2; proofs[$1]=$3; count++
      floor[$1]=(identities[$1] == $3 && offsets[$1] + 0 <= $2 + 0) ? offsets[$1] + 0 : 0
      next
    }
    section == 2 {
      if (NF != 3 || !($1 in ends) || ($1 in seen) || !uint($2) || $3 != proofs[$1] ||
          $2 + 0 < floor[$1] || $2 + 0 > ends[$1] + 0) { bad=1; exit }
      seen[$1]=1; suggested++; next
    }
    { bad=1; exit }
    END { if (bad || section != 2 || suggested != count) exit 1 }
  ' <<EOF
$canonical
@snapshot
$snapshot
@suggestions
$suggestions
EOF
}

# Avoid issuing a native backstop request for an already-deferred captured
# endpoint. The post-reply guard below still supplies independent fresh proof.
status_backstop_inputs_current() {  # <state> <captured-snapshot>
  local current
  current=$(status_presentation_snapshot_batch "$1" mtime) || return 1
  LC_ALL=C awk -F '\t' '
    $0 == "@current" { if (section) { bad=1; exit }; section=1; next }
    NF == 0 { next }
    !section {
      if (NF != 3 || ($1 in ends)) { bad=1; exit }
      ends[$1]=$2; proofs[$1]=$3; count++; next
    }
    {
      if (NF != 4 || ($1 in seen)) { bad=1; exit }
      seen[$1]=1
      if ($1 in ends) {
        if ($2 != ends[$1] || $3 != proofs[$1]) { bad=1; exit }
        matched++
      }
    }
    END { if (bad || !section || !count || matched != count) exit 1 }
  ' <<EOF
$2
@current
$current
EOF
}

# Independent late-phase admission for optional read-service backstop facts.
# The original presentation lock is held. One fresh strong snapshot and one
# manifest read prove ALL rows before selection; any uncertainty keeps the
# complete original backstop reader, never per-row repair or partial output.
status_backstop_facts_current() {  # <state> <captured-snapshot> <facts>
  local state=$1 snapshot=$2 facts=$3 fresh manifest canonical
  manifest="$state/.status-presentation-cursor"
  canonical=$(_status_presentation_manifest_canonical "$manifest") || return 1
  fresh=$(status_presentation_snapshot_batch "$state" mtime) || return 1
  LC_ALL=C awk -F '\t' '
    function uint(value) { return value ~ /^[0-9]+$/ && length(value) <= 16 && value + 0 <= 9007199254740991 }
    BEGIN { section=0 }
    $0 == "@snapshot" { if (section != 0) { bad=1; exit }; section=1; next }
    section == 0 && NF != 0 {
      if ((NF != 3 && NF != 4) || $1 == "" || $2 == "" || !uint($3) ||
          (NF == 4 && $4 != "" && !uint($4)) || ($1 in ids)) { bad=1; exit }
      ids[$1]=$2; receipts[$1]=($4 == "" ? 0 : $4 + 0); next
    }
    $0 == "@facts" { if (section != 1) { bad=1; exit }; section=2; next }
    $0 == "@fresh" { if (section != 2) { bad=1; exit }; section=3; next }
    NF == 0 { next }
    section == 1 {
      if (NF != 3 || $1 !~ /^[A-Za-z0-9][A-Za-z0-9._-]*$/ || !uint($2) || $3 == "" || ($1 in ends)) { bad=1; exit }
      if ($3 ~ /^strong:[0-9]+:[0-9]+:/) { bad=1; exit }
      order[++count]=$1; ends[$1]=$2; proofs[$1]=$3; next
    }
    section == 2 {
      if (NF < 7 || $1 != order[++selected] || $2 != ends[$1] || $3 != proofs[$1] ||
          !uint($4) || !uint($5) || !uint($6) || $4 + 0 > $2 + 0 || $6 + 0 > $2 + 0) { bad=1; exit }
      receipt=(ids[$1] == $3 && receipts[$1] <= $2 + 0) ? receipts[$1] : 0
      if ($4 + 0 != receipt) { bad=1; exit }
      packed=$0
      for (i=1; i<=6; i++) sub(/^[^\t]*\t/, "", packed)
      if (($6 + 0 == 0 && packed != ".") || ($6 + 0 != 0 && (packed !~ /^l:.*:l$/ ||
          length(packed) <= 4 || length(packed) - 4 > $6 + 0 || length(packed) - 4 > 65536))) { bad=1; exit }
      times[$1]=$5; next
    }
    section == 3 {
      if (NF != 4 || ($1 in seen) || !uint($2) || $3 == "" || !uint($4)) { bad=1; exit }
      seen[$1]=1
      if ($1 in ends) {
        if ($2 != ends[$1] || $3 != proofs[$1] || $4 != times[$1]) { bad=1; exit }
        matched++
      }
      next
    }
    { bad=1; exit }
    END { if (bad || section != 3 || count != selected || count != matched) exit 1 }
  ' <<EOF
$canonical
@snapshot
$snapshot
@facts
$facts
@fresh
$fresh
EOF
}

# Fresh regular-file signatures in argument order. The annotation owner calls
# this only at rendering time, never reuses its earlier presentation snapshot.
# Unsupported/uncertain inputs refuse the whole optional read with no output.
status_observed_signatures_batch() {  # <file>...
  local packet row group='' field=0 index=0 f path_state size ident mode sig result=''
  local -a signature_batch_files=("$@")
  [ "$_FM_CLASSIFY_UNAME_S" = Linux ] && [ "$_FM_CLASSIFY_HEX_BYTEWISE" = 1 ] \
    && [ -z "${FM_STATUS_SIZE_READER:-}" ] && [ -z "${FM_STATUS_IDENTITY_READER:-}" ] || return 1
  [ "$#" -le 256 ] || return 1
  [ "$#" -gt 0 ] || return 0
  for f in "$@"; do
    [ -f "$f" ] && [ -r "$f" ] && [ ! -L "$f" ] || return 1
  done
  { packet=$(LC_ALL=C exec stat -c $'%F:%f\n%s\n%d:%i\n%W\n%w' -- "$@"); } 2>/dev/null || return 1
  while IFS= read -r row; do
    [ "$index" -lt "$#" ] || return 1
    if [ "$field" -eq 0 ]; then group=$row; else group="$group"$'\n'"$row"; fi
    field=$((field + 1))
    [ "$field" -eq 5 ] || continue
    _status_observed_stat_parse_to path_state size ident "$group" || return 1
    case "$path_state" in 'regular file:'*|'regular empty file:'*) ;; *) return 1 ;; esac
    mode=${path_state##*:}
    [ "$((16#$mode & 61440))" -eq 32768 ] || return 1
    f=${signature_batch_files[$index]}
    [ -f "$f" ] && [ -r "$f" ] && [ ! -L "$f" ] || return 1
    _status_observed_signature_compose_to sig "$size" "$ident" "$path_state" - readable readable || return 1
    result="$result$sig"$'\n'
    index=$((index + 1)); field=0
  done <<EOF
$packet
EOF
  [ "$index" -eq "$#" ] && [ "$field" -eq 0 ] || return 1
  printf '%s' "$result"
}

# Optional preparation inside the EXISTING presentation commit owner. Capture
# current strong identities/sizes afresh AFTER stdout, never reuse service
# evidence or the pre-presentation snapshot. Join the cursor/backstop records
# once in linear work; any unsupported/uncertain packet retains the entire
# original commit path below. This helper writes no record or partial output.
_status_presentation_commit_rows_batch() {  # <state> <snapshot>
  local state=$1 snapshot=$2 current manifest canonical
  current=$(status_presentation_snapshot_batch "$state") || return 1
  manifest="$state/.status-presentation-cursor"
  canonical=$(_status_presentation_manifest_canonical "$manifest") || return 1
  LC_ALL=C awk -F '\t' '
    function uint(value) { return value ~ /^[0-9]+$/ && length(value) <= 15 }
    function taskid(value) { return value ~ /^[A-Za-z0-9][A-Za-z0-9._-]*$/ && length(value) <= 128 }
    BEGIN { section=0 }
    $0 == "@current" { if (section != 0) { bad=1; exit }; section=1; next }
    section == 0 && NF != 0 {
      if (++old_count > 256 || (NF != 3 && NF != 4) || !taskid($1) || $2 == "" ||
          !uint($3) || (NF == 4 && !uint($4)) || ($1 in old_ids)) { bad=1; exit }
      old_ids[$1]=$2; old_backstop[$1]=(NF == 4 ? $4 : 0); next
    }
    $0 == "@selected" { if (section != 1) { bad=1; exit }; section=2; next }
    $0 == "@backstops" { if (section != 2) { bad=1; exit }; section=3; next }
    $0 == "" { next }
    section == 1 {
      if (NF != 3 || !taskid($1) || !uint($2) || $3 == "" || ($1 in current_ids) || ++current_count > 256) { bad=1; exit }
      current_ids[$1]=$3; sizes[$1]=$2; next
    }
    section == 2 {
      if (NF != 3 || !taskid($1) || !uint($2) || $3 == "" || ($1 in selected_ids) || ++selected_count > 256 ||
          !($1 in current_ids) || $3 != current_ids[$1] || $2 + 0 > sizes[$1] + 0) { bad=1; exit }
      order[selected_count]=$1; selected_ids[$1]=$3; endpoints[$1]=$2
      backstops[$1]=(old_ids[$1] == $3 && old_backstop[$1] + 0 <= sizes[$1] + 0) ? old_backstop[$1] : 0
      next
    }
    section == 3 {
      if (NF != 2 || !taskid($1) || !uint($2) || ++ack_count > 256) { bad=1; exit }
      if ($1 in selected_ids) backstops[$1]=$2
      next
    }
    { bad=1; exit }
    END {
      if (bad || section != 3) exit 1
      for (i=1; i<=selected_count; i++) {
        task=order[i]
        if (backstops[task] + 0 > sizes[task] + 0) exit 1
      }
      for (i=1; i<=selected_count; i++) {
        task=order[i]
        printf "%s\t%s\t%s\t%s\n", task, selected_ids[task], endpoints[task], backstops[task]
      }
    }
  ' <<EOF
$canonical
@current
$current
@selected
$snapshot
@backstops
${STATUS_OUTCOME_BACKSTOP_ACKNOWLEDGED:-}
EOF
}

status_commit_presentation_snapshot() {  # <state> <snapshot> [batch]
  local state=$1 snapshot=$2 task endpoint ident f cur_ident size tmp backstop acknowledged_task acknowledged_endpoint
  local prepared_commit_rows
  tmp="$state/.status-presentation-cursor.tmp.$$"
  : > "$tmp" || return 1
  if [ "${3:-}" = batch ] && prepared_commit_rows=$(_status_presentation_commit_rows_batch "$state" "$snapshot"); then
    if [ -n "$prepared_commit_rows" ]; then
      printf '%s\n' "$prepared_commit_rows" > "$tmp" || { rm -f "$tmp"; return 1; }
    fi
  else
    if [ "${3:-}" = batch ]; then
      printf 'status commit: batch verification refused; using complete legacy commit\n' >&2
    fi
    while IFS=$(printf '\t') read -r task endpoint ident; do
      [ -n "$task" ] || continue
      case "$endpoint" in ''|*[!0-9]*) rm -f "$tmp"; return 1 ;; esac
      [ -n "$ident" ] || { rm -f "$tmp"; return 1; }
      f="$state/$task.status"
      [ -f "$f" ] && [ -r "$f" ] && [ ! -L "$f" ] || { rm -f "$tmp"; return 1; }
      cur_ident=$(_fm_open_decisions_file_ident "$f") || { rm -f "$tmp"; return 1; }
      size=$(_fm_status_file_size "$f") || { rm -f "$tmp"; return 1; }
      size=${size//[[:space:]]/}
      case "$size" in ''|*[!0-9]*) rm -f "$tmp"; return 1 ;; esac
      [ "$cur_ident" = "$ident" ] && [ "$endpoint" -le "$size" ] \
        || { rm -f "$tmp"; return 1; }
      backstop=$(status_outcome_backstop_cursor_offset "$f") || { rm -f "$tmp"; return 1; }
      while IFS=$(printf '\t') read -r acknowledged_task acknowledged_endpoint; do
        if [ "$acknowledged_task" = "$task" ]; then backstop=$acknowledged_endpoint; fi
      done <<EOF
${STATUS_OUTCOME_BACKSTOP_ACKNOWLEDGED:-}
EOF
      case "$backstop" in ''|*[!0-9]*) rm -f "$tmp"; return 1 ;; esac
      [ "$backstop" -le "$size" ] || { rm -f "$tmp"; return 1; }
      printf '%s\t%s\t%s\t%s\n' "$task" "$ident" "$endpoint" "$backstop" >> "$tmp" \
        || { rm -f "$tmp"; return 1; }
    done <<EOF
$snapshot
EOF
  fi
  mv -f "$tmp" "$state/.status-presentation-cursor" || { rm -f "$tmp"; return 1; }
}

# Private captured-line contract: byte-sorted task groups, preserving line
# bytes after the first tab. Validate before selecting native presentation so
# any malformed client output retains the complete legacy fallback.
fm_wake_captured_lines_valid() {  # <captured-lines>
  local line task previous='' LC_ALL=C
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    case "$line" in *$'\t'*) ;; *) return 1 ;; esac
    task=${line%%$'\t'*}
    case "$task" in ''|[!A-Za-z0-9]*|*[!A-Za-z0-9._-]*) return 1 ;; esac
    [ "${#task}" -le 128 ] || return 1
    if [ -n "$previous" ] && [ "$previous" != "$task" ] && [[ ! "$previous" < "$task" ]]; then return 1; fi
    previous=$task
  done <<EOF
$1
EOF
}

# Private classification evidence is required once per captured task, in the
# owner's snapshot order. Validate before native selection; a malformed local
# client packet must retain the COMPLETE legacy presentation before stdout.
fm_wake_classification_markers_valid() {  # <snapshot> <marker-evidence>
  LC_ALL=C awk -F '\t' '
    $0 == "@markers" { if (section) { bad=1; exit }; section=1; next }
    NF == 0 { next }
    !section { tasks[++count]=$1; next }
    {
      if (NF != 2 || ++seen > count || $1 != tasks[seen] ||
          ($2 != "-" && ($2 !~ /^h:[0-9a-f]*$/ || length($2) > 8194 || length($2) % 2))) { bad=1; exit }
    }
    END { if (bad || !section || seen != count) exit 1 }
  ' <<EOF
$1
@markers
$2
EOF
}

# At the original post-annotation acknowledgement-preparation boundary, keep
# native suggestions only while ALL evidenced classification markers remain
# supported and equal. The caller already validated inventory/bindings. This
# reads through existing owners, without per-row subprocesses on the admitted
# path; uncertainty returns the WHOLE acknowledgement batch to its legacy owner.
fm_wake_classification_markers_current() {  # <state> <validated-marker-evidence>
  local state=$1 task proof extra marker raw encoded LC_ALL=C
  _fm_wake_require_classify || return 1
  [ "$_FM_CLASSIFY_HEX_BYTEWISE" = 1 ] || return 1
  while IFS=$'\t' read -r task proof extra; do
    [ -n "$task" ] || continue
    [ -z "$extra" ] || return 1
    case "$task" in [!A-Za-z0-9]*|*[!A-Za-z0-9._-]*) return 1 ;; esac
    fm_wake_signal_seen_path_to marker "$state" "$state/$task.status"
    if [ "$proof" = - ]; then
      [ ! -e "$marker" ] && [ ! -L "$marker" ] || return 1
    else
      [ -f "$marker" ] && [ -r "$marker" ] && [ ! -L "$marker" ] || return 1
      fm_file_text_to raw "$marker" || return 1
      status_presentation_marker_parse "$raw" || return 1
      _status_observed_hex_c_to encoded "$raw" 2>/dev/null || return 1
      [ "$proof" = "h:$encoded" ] || return 1
    fi
  done <<EOF
$2
EOF
}

# Fresh annotation-time admission for the WHOLE captured inventory, not a
# per-row repair. Reuse the strong-identity owner in one bounded stat capture;
# allow growth beyond the captured ends but reject replacement, truncation,
# missing/nonregular/unreadable paths and uncertain or changed inventories.
# This never reads a cursor or span and never writes authoritative state.
fm_wake_annotation_paths_current() {  # <state> <presentation-snapshot>
  local state=$1 snapshot=$2 current
  [ -n "$snapshot" ] || return 1
  _fm_wake_require_classify || return 1
  current=$(status_presentation_snapshot_batch "$state") || return 1
  LC_ALL=C awk -F '\t' '
    BEGIN { section=0 }
    $0 == "@current" { if (section) { bad=1; exit }; section=1; next }
    NF == 0 { next }
    {
      if (NF != 3 || $1 !~ /^[A-Za-z0-9][A-Za-z0-9._-]*$/ || length($1) > 128 ||
          $2 !~ /^[0-9]+$/ || $3 == "" || seen[section, $1]++ || ++count[section] > 256) {
        bad=1; exit
      }
      if (!section) { ends[$1]=$2; identities[$1]=$3 }
      else if (!($1 in ends) || identities[$1] != $3 || $2 + 0 < ends[$1] + 0) { bad=1; exit }
    }
    END { if (bad || !section || !count[0] || count[0] != count[1]) exit 1 }
  ' <<EOF
$snapshot
@current
$current
EOF
}

# All-or-nothing optional historical replay filter. Marker reads and signature
# policy stay with their current owners; no owned-append or cursor test belongs
# here. The caller stages this result before printing any annotation.
_fm_wake_annotation_unreported_batch() {  # <deduplicated-manifest>
  local manifest=$1 key mode sig signatures rest result='' count=0
  local -a annotation_batch_paths=()
  while IFS=$'\t' read -r key mode; do
    [ -n "$key" ] || continue
    case "$key" in *.status) ;; *) return 1 ;; esac
    # shellcheck disable=SC2153  # STATE is assigned by bin/fm-wake-lib.sh, sourced first.
    case "$mode" in
      direct) ;;
      historical) annotation_batch_paths[count]="$STATE/$key"; count=$((count + 1)) ;;
      *) return 1 ;;
    esac
  done <<EOF
$manifest
EOF
  if [ "$count" -eq 0 ]; then printf '%s' "$manifest"; return 0; fi
  _fm_wake_require_classify || return 1
  signatures=$(status_observed_signatures_batch "${annotation_batch_paths[@]}") || return 1
  rest=$signatures
  while IFS=$'\t' read -r key mode; do
    [ -n "$key" ] || continue
    if [ "$mode" = historical ]; then
      [ -n "$rest" ] || return 1
      sig=${rest%%$'\n'*}
      case "$rest" in *$'\n'*) rest=${rest#*$'\n'} ;; *) rest='' ;; esac
      fm_wake_signal_reported_current "$STATE" "$STATE/$key" "$sig" && continue
    fi
    result="$result$key"$'\t'"$mode"$'\n'
  done <<EOF
$manifest
EOF
  [ -z "$rest" ] || return 1
  printf '%s' "$result"
}

# Print supplemental drain-time context only after the caller has committed the
# raw queue consumption and released the append lock.
fm_wake_print_annotations() {  # <deduped-raw-rows> [<presentation-snapshot> [<captured-lines>]]
  local rows=$1 snapshot=${2:-} manifest status_key mode path prefix line task endpoint
  local captured_lines=${3-} use_captured=${3+x} captured_task captured_line
  local captured_count=0 capture_index=0 left right middle historical_batch=0 filtered_manifest
  local -a captured_tasks=() captured_texts=()
  local snapshot_task snapshot_endpoint _snapshot_ident offset last_event event_line
  local LC_ALL=C

  # The private client supplies byte-sorted task groups. Index each group once
  # so queue-order rendering does not scan every task's lines for every row.
  if [ "$use_captured" = x ]; then
    fm_wake_captured_lines_valid "$captured_lines" || return 1
    while IFS= read -r captured_line; do
      [ -n "$captured_line" ] || continue
      captured_task=${captured_line%%$'\t'*}
      event_line=${captured_line#*$'\t'}
      if [ "$captured_count" -eq 0 ] || [ "${captured_tasks[$capture_index]}" != "$captured_task" ]; then
        capture_index=$captured_count
        captured_tasks[capture_index]=$captured_task
        captured_texts[capture_index]=''
        captured_count=$((captured_count + 1))
      fi
      captured_texts[capture_index]="${captured_texts[$capture_index]}$event_line"$'\n'
    done <<EOF
$captured_lines
EOF
  fi

  manifest=$(fm_wake_annotation_manifest "$rows" | awk -F '\t' '
    {
      key = $1
      if (!(key in seen)) {
        order[++count] = key
        seen[key] = 1
        mode[key] = $2
      } else if ($2 == "direct") {
        mode[key] = "direct"
      }
    }
    END {
      for (i = 1; i <= count; i++) print order[i] "\t" mode[order[i]]
    }
  ') || return 0

  # Test-only latency seam for proving that queue appends remain independent of
  # a slow best-effort annotation phase.
  case "${FM_WAKE_ENRICH_TEST_DELAY:-0}" in
    0) ;;
    ''|*[!0-9]*) ;;
    *) sleep "$FM_WAKE_ENRICH_TEST_DELAY" ;;
  esac

  # Revalidate ALL captured paths after the actual enrichment seam, covering
  # direct as well as historical annotations. On uncertainty discard the entire
  # annotation selection before printing even an unaffected row. The existing
  # legacy owner below then decides every annotation on the same snapshot.
  if [ "$use_captured" = x ] && [ -n "$manifest" ] \
    && ! fm_wake_annotation_paths_current "$STATE" "$snapshot"; then
    printf 'wake annotation: captured paths changed or unsupported; using complete legacy annotations\n' >&2
    use_captured=''
    captured_tasks=() captured_texts=()
  fi

  # Observe after the enrichment seam, not from the earlier captured span: a
  # concurrent append or marker update must affect historical replay suppression.
  if [ "$use_captured" = x ]; then
    if filtered_manifest=$(_fm_wake_annotation_unreported_batch "$manifest"); then
      manifest=$filtered_manifest
      historical_batch=1
    else
      printf 'wake annotation: signature batch refused; using complete legacy replay checks\n' >&2
    fi
  fi

  while IFS=$'\t' read -r status_key mode; do
    [ -n "$status_key" ] || continue
    path="$STATE/$status_key"
    # A turn-ended-only (historical) row's annotation would show unread status
    # lines even when those bytes are fully covered by the seen marker - already
    # surfaced to firstmate or deliberately absorbed by the signal triage.
    # Presenting such an already-announced line again makes a bare turn-end look
    # like fresh progress, so skip the annotation when the status file's
    # signature still matches its marker (a proven replay). Any uncertainty -
    # missing marker, unreadable signature - keeps the annotation with its
    # existing historical caveat. A direct status row is annotated for every
    # still-unread line since the last drain presentation; already-presented
    # bytes are not replayed.
    if [ "$historical_batch" = 0 ] && [ "$mode" = historical ] && fm_wake_signal_reported_current "$STATE" "$path"; then
      continue
    fi
    if [ "$use_captured" = x ]; then
      # The bounded read client validated these task/line records against the
      # same snapshot used by the fold. Do not reread a row or cursor here.
      task=${status_key%.status}
      FM_WAKE_UNREAD_LINES=''
      left=0 right=$((captured_count - 1))
      while [ "$left" -le "$right" ]; do
        middle=$(((left + right) / 2))
        if [ "${captured_tasks[$middle]}" = "$task" ]; then
          FM_WAKE_UNREAD_LINES=${captured_texts[$middle]}
          break
        elif [[ "$task" < "${captured_tasks[$middle]}" ]]; then
          right=$((middle - 1))
        else
          left=$((middle + 1))
        fi
      done
      [ -n "$FM_WAKE_UNREAD_LINES" ] || continue
      last_event=${FM_WAKE_UNREAD_LINES%$'\n'}
      last_event=${last_event##*$'\n'}
      last_event=${last_event//$'\t'/ }
      last_event=${last_event//$'\r'/ }
    else
      offset=$(fm_wake_status_cursor_offset "$path") || return 1
      endpoint=
      if [ -n "$snapshot" ]; then
        task=${status_key%.status}
        while IFS=$(printf '\t') read -r snapshot_task snapshot_endpoint _snapshot_ident; do
          if [ "$snapshot_task" = "$task" ]; then endpoint=$snapshot_endpoint; break; fi
        done <<EOF
$snapshot
EOF
        [ -n "$endpoint" ] || continue
      fi
      if [ -n "$endpoint" ] && [ "$offset" -ge "$endpoint" ]; then continue; fi
      if ! fm_wake_unread_events "$path" 0 "$offset" "$endpoint"; then
        # Annotation enrichment is supplemental to the already-printed durable
        # wake rows. A file that disappears, rotates, or becomes unreadable after
        # the snapshot must not suppress annotations for other status files; the
        # presentation commit will reject a changed snapshot identity.
        continue
      fi
      last_event=$FM_WAKE_EVENT_LINE
    fi
    while IFS= read -r event_line || [ -n "$event_line" ]; do
      [ -n "$event_line" ] || continue
      event_line=${event_line//$'\t'/ }
      event_line=${event_line//$'\r'/ }
      prefix="wake annotation: latest wake-EVENT observed at drain, not current state"
      if [ "$event_line" != "$last_event" ]; then
        prefix="wake annotation: unread wake-EVENT since last drain, not current state"
      fi
      if [ "$mode" = historical ]; then
        prefix="$prefix; historical / not necessarily the triggering event"
      fi
      line="$prefix: $status_key: $event_line"
      printf '%s\n' "$line" || return 1
    done <<EOF
$FM_WAKE_UNREAD_LINES
EOF
  done <<EOF
$manifest
EOF

  return 0
}
