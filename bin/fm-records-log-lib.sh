# shellcheck shell=bash
# fm-records-log-lib.sh - the handled-record log: one compressed, append-only
# log per record tree that holds handled records after their separate files are
# removed.
# Usage: . bin/fm-records-log-lib.sh
#   The lock helpers (fm_records_log_lock_try, fm_records_log_unlock) also need
#   bin/fm-wake-lib.sh; the readers need only tar, gzip, awk and perl.
#
# ONE owner of the log format and of the append protocol. Record owners read a
# record that is no longer a separate file only through fm_records_log_has,
# fm_records_log_cat, fm_records_log_names and fm_records_log_extract, and
# bin/fm-records-consolidate.sh is the only writer.
#
# Why it exists: ext4 places each small file in a shared 1 MiB block, so a tree
# of thousands of tiny handled records keeps many otherwise empty MiBs in use
# on the WSL disk file. One log per tree holds the same bytes in a few blocks.
#
# Layout under <tree> (a directory of separate record files):
#   <tree>/.records-log/               mode 0700; the dot name keeps it out of
#                                      every owner's *.result and *.msg glob
#   <tree>/.records-log/index          the commit record: a first line
#                                      `schema=fm-records-log.v1`, then one line
#                                      `<record-name>\t<segment>` per stored
#                                      record; the last line for a name wins
#   <tree>/.records-log/<segment>.tgz  an immutable gzip tar of `./<record-name>`
#                                      members, never rewritten or removed once
#                                      the index names it
#   <tree>/.records-log/.lock          the consolidation lock (fm-wake-lib)
#   <tree>/.records-log/.run.*         one run's scratch, removed by its run or
#                                      by the next run under the lock
#
# Append protocol (fm_records_log_commit), in this order:
#   1. write the segment to the run directory and fsync it;
#   2. rename it into the log directory and fsync the directory;
#   3. read every member back and compare it byte for byte with its file;
#      a mismatch removes the uncommitted segment and fails;
#   4. write the old index plus one line per member to a temporary file, fsync
#      it, rename it over the index and fsync the directory - the commit point;
#   5. only then may the caller remove the separate files.
# A crash before step 4 leaves every record as a file and at most a segment the
# index does not name, which the next run removes. A crash after step 4 leaves
# each record in the log, as a file, or both, and a rerun finds the identical
# logged copy and only removes the file, so nothing is stored twice.
#
# Readers take no lock: the index changes only by an atomic rename, and a
# segment it names never changes. A record whose name the index lists but whose
# segment cannot be read is a failed read (status 2), never an absent record.
# Record names are limited to [A-Za-z0-9._-], must not start with a dot, and
# carry no path.

FM_RECORDS_LOG_SCHEMA='fm-records-log.v1'

fm_records_log_dir_to() {  # <output-variable> <tree>
  printf -v "$1" '%s/.records-log' "$2"
}

fm_records_log_name_valid() {  # <record-name>
  case "${1-}" in
    ''|.*|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
  [ "${#1}" -le 255 ]
}

# fsync each named file or directory. Shell has no fsync; perl does.
fm_records_log_sync() {  # <path>...
  perl -MIO::Handle -e '
    for my $p (@ARGV) {
      sysopen(my $fh, $p, 0) or exit 1;
      $fh->sync or exit 1;
      close($fh);
    }' "$@"
}

# 0 = the index is present and valid, 1 = no log yet, 2 = unreadable or not
# this schema.
fm_records_log_index_state() {  # <tree>
  local log first
  fm_records_log_dir_to log "$1"
  [ -e "$log/index" ] || [ -L "$log/index" ] || return 1
  [ -f "$log/index" ] && [ ! -L "$log/index" ] || return 2
  { IFS= read -r first < "$log/index"; } 2>/dev/null || return 2
  [ "$first" = "schema=$FM_RECORDS_LOG_SCHEMA" ] || return 2
}

# Assign the segment that holds <record-name>'s current copy.
# 0 = found, 1 = not in the log, 2 = the index cannot be read.
fm_records_log_lookup_to() {  # <output-variable> <tree> <record-name>
  local _fm_rll_log _fm_rll_seg _fm_rll_rc=0
  fm_records_log_name_valid "$3" || return 1
  fm_records_log_index_state "$2" || _fm_rll_rc=$?
  [ "$_fm_rll_rc" -eq 0 ] || return "$_fm_rll_rc"
  fm_records_log_dir_to _fm_rll_log "$2"
  _fm_rll_seg=$(awk -F '\t' -v n="$3" 'NR > 1 && $1 == n { s = $2 } END { print s }' "$_fm_rll_log/index") \
    || return 2
  [ -n "$_fm_rll_seg" ] || return 1
  case "$_fm_rll_seg" in ''|.*|*/*) return 2 ;; esac
  printf -v "$1" '%s' "$_fm_rll_seg"
}

# 0 = the log holds <record-name>, 1 = it does not, 2 = the index cannot be read.
fm_records_log_has() {  # <tree> <record-name>
  local seg
  fm_records_log_lookup_to seg "$1" "$2"
}

# Print <record-name>'s logged bytes.
# 0 = printed, 1 = not in the log, 2 = the log cannot be read.
fm_records_log_cat() {  # <tree> <record-name>
  local log seg rc=0
  fm_records_log_lookup_to seg "$1" "$2" || rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  fm_records_log_dir_to log "$1"
  [ -f "$log/$seg" ] && [ ! -L "$log/$seg" ] || return 2
  tar -xzOf "$log/$seg" "./$2" 2>/dev/null || return 2
}

# Print every record name the log holds, once each.
# 0 = printed (possibly nothing), 2 = the index cannot be read.
fm_records_log_names() {  # <tree>
  local log rc=0
  fm_records_log_index_state "$1" || rc=$?
  [ "$rc" -ne 1 ] || return 0
  [ "$rc" -eq 0 ] || return 2
  fm_records_log_dir_to log "$1"
  awk -F '\t' 'NR > 1 && !seen[$1]++ { print $1 }' "$log/index" || return 2
}

# Write each logged record's current copy into <dest-dir> under its own name.
# Segments are applied in index order, so a later copy of a name replaces an
# earlier one, which is the index's last-line-wins rule.
# 0 = done (possibly nothing), 2 = the log cannot be read.
fm_records_log_extract() {  # <tree> <dest-dir>
  local log rc=0 segs seg
  fm_records_log_index_state "$1" || rc=$?
  [ "$rc" -ne 1 ] || return 0
  [ "$rc" -eq 0 ] || return 2
  fm_records_log_dir_to log "$1"
  segs=$(awk -F '\t' 'NR > 1 && !seen[$2]++ { print $2 }' "$log/index") || return 2
  while IFS= read -r seg; do
    [ -n "$seg" ] || continue
    case "$seg" in .*|*/*) return 2 ;; esac
    [ -f "$log/$seg" ] && [ ! -L "$log/$seg" ] || return 2
    (umask 077; tar -xzf "$log/$seg" -C "$2") 2>/dev/null || return 2
  done <<< "$segs"
}

# Take the tree's consolidation lock without waiting; creates the log directory.
# 0 = held, 1 = another run holds it, 2 = the log directory cannot be made.
fm_records_log_lock_try() {  # <tree>
  local log
  fm_records_log_dir_to log "$1"
  if [ ! -d "$log" ] || [ -L "$log" ]; then
    (umask 077; mkdir "$log") 2>/dev/null || [ -d "$log" ] || return 2
    [ ! -L "$log" ] || return 2
  fi
  fm_lock_try_acquire "$log/.lock" || return 1
}

fm_records_log_unlock() {  # <tree>
  local log
  fm_records_log_dir_to log "$1"
  fm_lock_release "$log/.lock"
}

# Remove what an interrupted run left: its scratch directories and any segment
# the index does not name (written before a commit that never happened).
# Caller holds the lock. Prints one line per removed segment.
fm_records_log_recover() {  # <tree>
  local log path base rc=0 named=''
  fm_records_log_dir_to log "$1"
  for path in "$log"/.run.*; do
    [ -e "$path" ] || continue
    rm -rf -- "$path" || return 2
  done
  fm_records_log_index_state "$1" || rc=$?
  [ "$rc" -ne 2 ] || return 2
  if [ "$rc" -eq 0 ]; then
    named=$(awk -F '\t' 'NR > 1 && !seen[$2]++ { print $2 }' "$log/index") || return 2
  fi
  for path in "$log"/*.tgz; do
    [ -e "$path" ] || continue
    base=${path##*/}
    case $'\n'"$named"$'\n' in *$'\n'"$base"$'\n'*) continue ;; esac
    rm -f -- "$path" || return 2
    printf '%s\n' "$base"
  done
}

# Make a private scratch directory for one run and assign its path.
fm_records_log_run_dir_to() {  # <output-variable> <tree>
  local _fm_rlr_log _fm_rlr_dir
  fm_records_log_dir_to _fm_rlr_log "$2"
  _fm_rlr_dir=$(umask 077; mktemp -d "$_fm_rlr_log/.run.XXXXXX") || return 2
  printf -v "$1" '%s' "$_fm_rlr_dir"
}

# Store the records named in <list-file> (one name per line, each a regular
# file directly in <tree>) by the append protocol above. Afterwards every listed
# record's verified copy is at <run-dir>/logged/<name>, beside the copies of
# records already in the log, so the caller can compare a file once more under
# its owner's lock before removing it. Caller holds the lock.
# 0 = committed (or nothing to store), 2 = failed with the index unchanged.
fm_records_log_commit() {  # <tree> <list-file> <run-dir>
  local tree=$1 list=$2 run=$3 log name seg rc=0
  fm_records_log_dir_to log "$tree"
  fm_records_log_index_state "$tree" || rc=$?
  [ "$rc" -ne 2 ] || return 2
  : > "$run/members" || return 2
  while IFS= read -r name; do
    fm_records_log_name_valid "$name" || return 2
    [ -f "$tree/$name" ] && [ ! -L "$tree/$name" ] || return 2
    printf './%s\n' "$name" >> "$run/members" || return 2
  done < "$list"
  [ -s "$run/members" ] || return 0
  # Names start with ./ so neither tar reads a name beginning with - as an
  # option; COPYFILE_DISABLE keeps macOS tar from adding ._ metadata members.
  (cd "$tree" && umask 077 && COPYFILE_DISABLE=1 tar -czf "$run/segment" -T "$run/members") 2>/dev/null \
    || return 2
  fm_records_log_sync "$run/segment" || return 2
  seg="$(date -u +%Y%m%dT%H%M%SZ)-${BASHPID:-$$}-$RANDOM.tgz"
  [ ! -e "$log/$seg" ] && [ ! -L "$log/$seg" ] || return 2
  mv -- "$run/segment" "$log/$seg" || return 2
  if ! fm_records_log_sync "$log"; then
    rm -f -- "$log/$seg"
    return 2
  fi
  mkdir -p "$run/logged" || { rm -f -- "$log/$seg"; return 2; }
  if ! (umask 077; tar -xzf "$log/$seg" -C "$run/logged") 2>/dev/null; then
    rm -f -- "$log/$seg"
    return 2
  fi
  while IFS= read -r name; do
    cmp -s "$run/logged/$name" "$tree/$name" && continue
    rm -f -- "$log/$seg"
    return 2
  done < "$list"
  if ! {
    if [ "$rc" -eq 0 ]; then
      cat "$log/index"
    else
      printf 'schema=%s\n' "$FM_RECORDS_LOG_SCHEMA"
    fi
    while IFS= read -r name; do
      printf '%s\t%s\n' "$name" "$seg"
    done < "$list"
  } > "$run/index" || ! chmod 0600 "$run/index" || ! fm_records_log_sync "$run/index"; then
    rm -f -- "$log/$seg"
    return 2
  fi
  if ! mv -f -- "$run/index" "$log/index"; then
    rm -f -- "$log/$seg"
    return 2
  fi
  # The rename is the commit; a failed directory fsync after it leaves the
  # files in place, and the next run finds the identical logged copies.
  fm_records_log_sync "$log" || return 2
}
