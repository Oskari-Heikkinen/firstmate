#!/usr/bin/env bash
# fm-reimport-rekey.sh - carry a home's status cursors across a distro re-import.
#
# A re-import (export, unregister, import) gives every file a new inode and
# birth time, so every stored file identity stops matching its status log and
# the first session start resets every cursor and rescans every log from byte
# 0. This tool records each identity-keyed cursor before the export and, after
# the import, rewrites a cursor's stored identity to the log's new one only
# where the log provably still holds the bytes the cursor vouches for.
# docs/disk-room.md "Re-importing the distro" owns when the operator runs it.
#
# Usage:
#   fm-reimport-rekey.sh record   with the fleet parked, before the export
#   fm-reimport-rekey.sh apply    after the import, before the first session start
#
# The home is FM_HOME (default: this checkout) and its state directory
# FM_STATE_OVERRIDE (default: $FM_HOME/state), resolved by bin/fm-wake-lib.sh.
# Run each home's own copy.
#
# CONTRACT (this header is the one owner of the record format).
#   Cursor families, one per identity-keyed status cursor, each read from the
#   path its owner's library computes for every regular, non-symlink
#   $STATE/<task>.status:
#     odc       .<task>.open-decisions-cursor (bin/fm-classify-lib.sh)
#     osc       .<task>.snapshot-open-decisions-cursor (same owner)
#     seen      .seen-<task>_status watcher marker (status_signal_seen_marker_path)
#     hb        .hb-surfaced-<task> heartbeat marker (status_heartbeat_seen_marker_path)
#     daemon    .subsuper-seen-status-<task> away-daemon marker (status_daemon_seen_marker_path)
#     appends   .<task>.home-appends ledger (status_home_appends_path)
#     outcome   .<task>.branch-outcome-index (bin/fm-branch-outcome.sh)
#     manifest  the <task> row of .status-presentation-cursor (bin/fm-classify-lib.sh)
#   Record: $STATE/.reimport-rekey.record, mode 0600, replaced atomically on
#   every `record`. Line 1 is `fm-reimport-rekey-record-v1<TAB><epoch>`; each
#   further line is one cursor:
#     family<TAB>task<TAB>cursor<TAB>guard<TAB>identity<TAB>offset<TAB>size<TAB>prefix
#   cursor is the cursor file's name in $STATE, guard is the sha256 of the cursor file's bytes (of the row's text for
#   manifest), identity the stored file identity, offset the furthest log
#   offset the cursor vouches for, size the log's size and prefix the sha256 of
#   the log's first <offset> bytes, all at record time. A cursor is recorded
#   only when its identity already matches the log (bin/fm-classify-lib.sh
#   _fm_file_ident_same) and its offset is within the log, so a stale cursor is
#   never carried forward.
#   apply, per recorded cursor, in this order:
#     skipped          the log or the cursor file is gone
#     already current  the cursor's identity already matches the log, so a
#                      second apply, or an owner that rewrote it, changes nothing
#     left for reset   the cursor changed since the record, or the log's size
#                      or prefix hash differs; the owner's normal reset handles it
#     rekeyed          otherwise: only the identity is rewritten, every other
#                      byte and the file mode kept, through a same-directory
#                      atomic rename
#   A marker's reported signature is rewritten only when it still equals the
#   signature the log produces under the old identity; otherwise only its
#   classified field moves and the watcher re-reports once.
#   Locks: apply refuses (exit 3) unless the session lock ($STATE/.lock) reads
#   free or stale (bin/fm-session-lock-lib.sh), then takes, without waiting and
#   in this order, the session claim, watcher, away-daemon, wake-queue,
#   presentation and branch-outcome locks, refusing if any is held by a live
#   process, and each ledger's own lock around its rewrite. record takes no lock
#   and only warns when the session lock or watcher is live, because apply's
#   guards leave any cursor that moved afterwards to the normal reset.
#   Log: one line per cursor and a summary go to stdout and are appended to
#   $STATE/.reimport-rekey.log with the UTC time.
#   Exit: 0 done (some cursors may be left for reset), 1 failure (no or
#   invalid record, an unreadable log, a failed write), 2 usage, 3 refused.

set -eu
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
_fm_wake_require_classify
# shellcheck source=bin/fm-session-lock-lib.sh
. "$SCRIPT_DIR/fm-session-lock-lib.sh"

RECORD="$STATE/.reimport-rekey.record"
LOG="$STATE/.reimport-rekey.log"
MANIFEST="$STATE/.status-presentation-cursor"
RECORD_VERSION=fm-reimport-rekey-record-v1
FAMILIES='odc osc seen hb daemon appends outcome manifest'
MODE=
RUN_TMP=
HELD_LOCKS=()
TAB=$(printf '\t')

usage() {
  echo "usage: fm-reimport-rekey.sh record|apply" >&2
  exit 2
}

say() {  # <line>
  printf '%s\n' "$1"
  printf '%s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$1" >> "$LOG" 2>/dev/null || true
}

cleanup() {
  local i=${#HELD_LOCKS[@]}
  while [ "$i" -gt 0 ]; do
    i=$((i - 1))
    fm_lock_release "${HELD_LOCKS[$i]}" || true
  done
  HELD_LOCKS=()
  [ -z "$RUN_TMP" ] || rm -rf -- "$RUN_TMP"
}

# sha256 of a file's bytes: `file`, its first <n> bytes: `prefix <n>` (a short
# read fails), or its one line whose first tab field is <key>: `row <key>`.
rekey_sha() {  # <file|prefix|row> <path> [<n>|<key>]
  perl -MFcntl=:DEFAULT -MDigest::SHA -e '
    my ($mode, $path, $arg) = @ARGV;
    sysopen(my $f, $path, O_RDONLY | O_NOFOLLOW) or exit 1;
    binmode $f;
    my $sha = Digest::SHA->new(256);
    if ($mode eq "prefix") {
      my $left = $arg;
      while ($left > 0) {
        my $n = sysread($f, my $buf, $left > 65536 ? 65536 : $left);
        defined($n) && $n > 0 or exit 1;
        $sha->add($buf);
        $left -= $n;
      }
    } elsif ($mode eq "file") {
      while (1) {
        my $n = sysread($f, my $buf, 65536);
        defined($n) or exit 1;
        last unless $n;
        $sha->add($buf);
      }
    } else {
      local $/;
      my $data = <$f>;
      $data = "" unless defined $data;
      my @rows = grep { (split /\t/, $_, -1)[0] eq $arg } split /\n/, $data;
      @rows == 1 or exit 1;
      $sha->add($rows[0]);
    }
    print $sha->hexdigest;
  ' "$@"
}

# Replace one value in a cursor file and rename the result over it, keeping
# every other byte and the file mode. <select> is `all` (the whole content is
# <old>), `n:<line>` or `k:<key>` (the one line whose first tab field is <key>);
# <field> is 0 for the whole line or a 1-based tab field. Exit 4 means the file
# no longer holds <old> there.
rekey_rewrite() {  # <path> <select> <field> <old> <new>
  perl -MFcntl=:DEFAULT,:mode -e '
    my ($path, $tmpdir, $select, $field, $old, $new) = @ARGV;
    sysopen(my $in, $path, O_RDONLY | O_NOFOLLOW) or exit 3;
    my @st = stat($in) or exit 3;
    S_ISREG($st[2]) or exit 3;
    binmode $in;
    my $data = do { local $/; <$in> };
    $data = "" unless defined $data;
    close $in;
    my $out;
    if ($select eq "all") {
      $data eq $old or exit 4;
      $out = $new;
    } else {
      my @lines = split /(?<=\n)/, $data, -1;
      my @hit;
      if ($select =~ /\An:([0-9]+)\z/) {
        @hit = ($1 - 1) if $1 >= 1 && $1 <= @lines;
      } elsif ($select =~ /\Ak:(.+)\z/s) {
        my $key = $1;
        @hit = grep { my $l = $lines[$_]; $l =~ s/\n\z//; (split /\t/, $l, -1)[0] eq $key } 0 .. $#lines;
      }
      @hit == 1 or exit 4;
      my $line = $lines[$hit[0]];
      my $nl = ($line =~ s/\n\z//) ? "\n" : "";
      if ($field == 0) {
        $line eq $old or exit 4;
        $line = $new;
      } else {
        my @f = split /\t/, $line, -1;
        $field <= @f && $f[$field - 1] eq $old or exit 4;
        $f[$field - 1] = $new;
        $line = join "\t", @f;
      }
      $lines[$hit[0]] = $line . $nl;
      $out = join "", @lines;
    }
    my $tmp = "$tmpdir/rewrite";
    unlink $tmp;
    sysopen(my $o, $tmp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0600) or exit 5;
    binmode $o;
    (print {$o} $out) && close($o) or exit 5;
    chmod(S_IMODE($st[2]), $tmp) or exit 5;
    rename($tmp, $path) or exit 5;
  ' "$1" "$RUN_TMP" "$2" "$3" "$4" "$5"
}

regular_file() {  # <path>
  [ -f "$1" ] && [ -r "$1" ] && [ ! -L "$1" ]
}

cursor_path_to() {  # <output-variable> <family> <task> <status-file>
  local _cp_path
  case "$2" in
    odc) _cp_path=$(_fm_open_decisions_cursor_path "$4") ;;
    osc) _cp_path=$(_fm_open_decisions_snapshot_cursor_path "$4") ;;
    seen) _cp_path=$(status_signal_seen_marker_path "$STATE" "$3") ;;
    hb) _cp_path=$(status_heartbeat_seen_marker_path "$STATE" "$3") ;;
    daemon) _cp_path=$(status_daemon_seen_marker_path "$STATE" "$3") ;;
    appends) _cp_path=$(status_home_appends_path "$4") ;;
    outcome) _cp_path="$STATE/.$3.branch-outcome-index" ;;
    manifest) _cp_path=$MANIFEST ;;
    *) return 1 ;;
  esac
  printf -v "$1" '%s' "$_cp_path"
}

# The size and identity fields of an r1 reported signature
# (status_observed_signature_to): the hex of each field, joined by 00.
r1_size_ident() {  # <r1-signature>; sets R1_SIZE R1_IDENT
  local hex=${1#r1:} i=0 byte field=0 cur=''
  R1_SIZE=
  R1_IDENT=
  while [ "$i" -lt "${#hex}" ] && [ "$field" -lt 2 ]; do
    byte=${hex:$i:2}
    i=$((i + 2))
    if [ "$byte" = 00 ]; then
      printf -v cur '%b' "$cur"
      if [ "$field" -eq 0 ]; then R1_SIZE=$cur; else R1_IDENT=$cur; fi
      field=$((field + 1))
      cur=''
    else
      cur="$cur\\x$byte"
    fi
  done
  case "$R1_SIZE" in ''|*[!0-9]*) R1_SIZE=; R1_IDENT=; return 1 ;; esac
  [ -n "$R1_IDENT" ]
}

# Split a size@identity or offset@identity field.
at_field() {  # <field>; sets AT_NUM AT_IDENT
  AT_NUM=${1%%@*}
  AT_IDENT=${1#*@}
  case "$1" in *@*) ;; *) AT_NUM=; AT_IDENT=; return 1 ;; esac
  case "$AT_NUM" in ''|*[!0-9]*) AT_NUM=; AT_IDENT=; return 1 ;; esac
  [ -n "$AT_IDENT" ]
}

# Read one cursor's stored identity and the furthest log offset it vouches for.
# Returns 1 when the cursor is absent, 2 when it holds no usable identity.
# Markers also set the parsed fields the rewrite needs.
cursor_read() {  # <family> <task> <path>
  local family=$1 task=$2 path=$3 data line rest row_task ident offset backstop extra start end
  C_IDENT=
  C_OFFSET=
  M_LEGACY=0 M_REP='' M_CLS='' M_REP_KIND='' M_REP_NUM='' M_REP_IDENT='' M_CLS_NUM='' M_CLS_IDENT=''
  [ -e "$path" ] || [ -L "$path" ] || return 1
  regular_file "$path" || return 2
  data=$(LC_ALL=C command cat "$path" 2>/dev/null) || return 2
  case "$family" in
    odc|osc)
      case "$data" in version=*$'\n'*) ;; *) return 2 ;; esac
      rest=${data#*$'\n'}
      line=${rest%%$'\n'*}
      case "$line" in offset=*) C_OFFSET=${line#offset=} ;; *) return 2 ;; esac
      case "$rest" in *$'\n'*) rest=${rest#*$'\n'} ;; *) return 2 ;; esac
      line=${rest%%$'\n'*}
      case "$line" in ident=*) C_IDENT=${line#ident=} ;; *) return 2 ;; esac
      ;;
    seen|hb|daemon)
      status_presentation_marker_parse "$data" || return 2
      M_REP=$STATUS_PRESENTATION_REPORTED
      M_CLS=$STATUS_PRESENTATION_CLASSIFIED
      case "$data" in v2"$TAB"*) ;; *) M_LEGACY=1 ;; esac
      if [ "$M_CLS" != - ] && at_field "$M_CLS"; then
        M_CLS_NUM=$AT_NUM
        M_CLS_IDENT=$AT_IDENT
      fi
      case "$M_REP" in
        r1:*) r1_size_ident "$M_REP" && { M_REP_KIND='r1'; M_REP_NUM=$R1_SIZE; M_REP_IDENT=$R1_IDENT; } ;;
        unverifiable) ;;
        *) at_field "$M_REP" && { M_REP_KIND='at'; M_REP_NUM=$AT_NUM; M_REP_IDENT=$AT_IDENT; } ;;
      esac
      C_IDENT=${M_CLS_IDENT:-$M_REP_IDENT}
      [ -n "$C_IDENT" ] || return 2
      C_OFFSET=0
      if [ -n "$M_CLS_IDENT" ] && _fm_file_ident_same "$M_CLS_IDENT" "$C_IDENT"; then C_OFFSET=$M_CLS_NUM; fi
      if [ -n "$M_REP_IDENT" ] && _fm_file_ident_same "$M_REP_IDENT" "$C_IDENT" \
        && [ "$M_REP_NUM" -gt "$C_OFFSET" ]; then
        C_OFFSET=$M_REP_NUM
      fi
      ;;
    appends)
      case "$data" in v1$'\n'ident=*) ;; *) return 2 ;; esac
      line=${data#v1$'\n'}
      C_IDENT=${line%%$'\n'*}; C_IDENT=${C_IDENT#ident=}
      C_OFFSET=0
      case "$line" in *$'\n'*) line=${line#*$'\n'} ;; *) line= ;; esac
      while IFS=$TAB read -r start end extra; do
        [ -n "$start" ] || continue
        case "$end" in ''|*[!0-9]*) continue ;; esac
        [ "$end" -le "$C_OFFSET" ] || C_OFFSET=$end
      done <<EOF
$line
EOF
      ;;
    outcome)
      case "$data" in *$'\n'*) return 2 ;; esac
      IFS=$TAB read -r line _ offset ident extra <<EOF
$data
EOF
      [ "$line" = fm-branch-outcome-index-v1 ] && [ -z "$extra" ] || return 2
      [ "$ident" != - ] || return 2
      C_IDENT=$ident
      C_OFFSET=$offset
      ;;
    manifest)
      while IFS=$TAB read -r row_task ident offset backstop extra; do
        [ "$row_task" = "$task" ] || continue
        [ -z "$C_IDENT" ] || return 2
        [ -z "$extra" ] || return 2
        case "$offset:${backstop:-0}" in *[!0-9:]*|:*) return 2 ;; esac
        C_IDENT=$ident
        C_OFFSET=$offset
        [ "${backstop:-0}" -le "$C_OFFSET" ] || C_OFFSET=$backstop
      done <<EOF
$data
EOF
      [ -n "$C_IDENT" ] || return 1
      ;;
  esac
  case "$C_OFFSET" in ''|*[!0-9]*) return 2 ;; esac
  [ -n "$C_IDENT" ] || return 2
  case "$C_IDENT" in *"$TAB"*) return 2 ;; esac
}

cursor_guard_to() {  # <output-variable> <family> <task> <path>
  local _cg
  if [ "$2" = manifest ]; then
    _cg=$(rekey_sha row "$4" "$3") || return 1
  else
    _cg=$(rekey_sha file "$4") || return 1
  fi
  printf -v "$1" '%s' "$_cg"
}

log_size_ident() {  # <status-file>; sets L_SIZE L_IDENT
  L_SIZE=$(_fm_status_file_size "$1") || return 1
  L_SIZE=${L_SIZE//[[:space:]]/}
  case "$L_SIZE" in ''|*[!0-9]*) return 1 ;; esac
  L_IDENT=$(_fm_open_decisions_file_ident "$1") || return 1
  [ -n "$L_IDENT" ]
}

warn_if_live() {
  fm_session_lock_inspect "$STATE"
  case "$FM_LOCK_INSPECT_STATE" in
    free|stale) ;;
    *) say "record warning: the session lock reads $FM_LOCK_INSPECT_STATE (pid ${FM_LOCK_INSPECT_PID:--}); cursors that move after this record are left for the normal reset" ;;
  esac
  if ! fm_watcher_lock_unheld "$STATE"; then
    say "record warning: the watcher lock is present; cursors that move after this record are left for the normal reset"
  fi
}

do_record() {
  local f task family path rc tmp body='' count=0 unrecorded=0 guard prefix_key='' prefix_hash=''
  warn_if_live
  for f in "$STATE"/*.status; do
    regular_file "$f" || continue
    task=${f##*/}; task=${task%.status}
    case "$task" in ''|*"$TAB"*|*$'\n'*) continue ;; esac
    log_size_ident "$f" || { say "record failed: cannot read size and identity of $task.status"; return 1; }
    for family in $FAMILIES; do
      [ "$family" != outcome ] || case "$task" in *[!A-Za-z0-9._-]*) continue ;; esac
      cursor_path_to path "$family" "$task" "$f"
      rc=0
      cursor_read "$family" "$task" "$path" || rc=$?
      [ "$rc" -ne 1 ] || continue
      if [ "$rc" -ne 0 ]; then
        say "record $family $task not recorded: the cursor holds no identity it can carry"
        unrecorded=$((unrecorded + 1))
        continue
      fi
      if ! _fm_file_ident_same "$C_IDENT" "$L_IDENT" || [ "$C_OFFSET" -gt "$L_SIZE" ]; then
        say "record $family $task not recorded: the cursor already does not match its log, so the normal reset owns it"
        unrecorded=$((unrecorded + 1))
        continue
      fi
      cursor_guard_to guard "$family" "$task" "$path" || { say "record failed: cannot hash the $family cursor of $task"; return 1; }
      if [ "$prefix_key" != "$task:$C_OFFSET" ]; then
        prefix_hash=$(rekey_sha prefix "$f" "$C_OFFSET") || { say "record failed: cannot hash $task.status up to $C_OFFSET"; return 1; }
        prefix_key="$task:$C_OFFSET"
      fi
      body="$body$family$TAB$task$TAB${path##*/}$TAB$guard$TAB$C_IDENT$TAB$C_OFFSET$TAB$L_SIZE$TAB$prefix_hash"$'\n'
      count=$((count + 1))
    done
  done
  tmp=$(umask 077 && mktemp "$STATE/.reimport-rekey.record.XXXXXX") || { say "record failed: cannot create a record in $STATE"; return 1; }
  chmod 0600 "$tmp" || { rm -f -- "$tmp"; say "record failed: cannot make the record private"; return 1; }
  if ! printf '%s\t%s\n%s' "$RECORD_VERSION" "$(date +%s)" "$body" > "$tmp" || ! mv -f -- "$tmp" "$RECORD"; then
    rm -f -- "$tmp"
    say "record failed: cannot write $RECORD"
    return 1
  fi
  say "record done: $count cursors recorded, $unrecorded not recorded; next: export, import, then fm-reimport-rekey.sh apply before the first session start"
}

take_lock() {  # <lock> <name>
  if fm_lock_try_acquire "$1"; then
    HELD_LOCKS[${#HELD_LOCKS[@]}]=$1
    return 0
  fi
  say "apply refused: the $2 lock $1 is held${FM_LOCK_HELD_PID:+ by live pid $FM_LOCK_HELD_PID}; park the fleet and stop it, then rerun apply"
  return 1
}

session_lock_free() {
  fm_session_lock_inspect "$STATE"
  case "$FM_LOCK_INSPECT_STATE" in
    free|stale) return 0 ;;
  esac
  say "apply refused: the session lock $STATE/.lock reads $FM_LOCK_INSPECT_STATE (pid ${FM_LOCK_INSPECT_PID:--}); end the session (bin/fm-lock.sh status shows it), then rerun apply"
  return 1
}

# Rewrite one marker's identity fields; prints nothing, returns like rekey_rewrite.
rewrite_marker() {  # <path> <status-file> <old-ident> <new-ident> <raw>
  local path=$1 f=$2 old=$3 new=$4 raw=$5 rep=$M_REP cls=$M_CLS sig_old sig_new canon_a canon_b
  if [ -n "$M_CLS_IDENT" ] && _fm_file_ident_same "$M_CLS_IDENT" "$old"; then
    cls="$M_CLS_NUM@$new"
  fi
  if [ -n "$M_REP_IDENT" ] && _fm_file_ident_same "$M_REP_IDENT" "$old"; then
    case "$M_REP_KIND" in
      at) rep="$M_REP_NUM@$new" ;;
      r1)
        sig_old=$(status_observed_signature "$f" "$M_REP_NUM" "$M_REP_IDENT") || sig_old=
        if [ -n "$sig_old" ] && _status_signature_canon_to canon_a "$sig_old" \
          && _status_signature_canon_to canon_b "$M_REP" && [ "$canon_a" = "$canon_b" ]; then
          sig_new=$(status_observed_signature "$f" "$M_REP_NUM" "$new") || return 5
          rep=$sig_new
        fi
        ;;
    esac
  fi
  if [ "$M_LEGACY" -eq 1 ]; then
    rekey_rewrite "$path" all 0 "$raw" "$cls"
  else
    rekey_rewrite "$path" all 0 "$raw" "v2$TAB$rep$TAB$cls"
  fi
}

rewrite_cursor() {  # <family> <task> <path> <status-file> <old-ident> <new-ident>
  local family=$1 task=$2 path=$3 f=$4 old=$5 new=$6 raw rc=0
  case "$family" in
    odc|osc) rekey_rewrite "$path" n:3 0 "ident=$old" "ident=$new" || rc=$? ;;
    seen|hb|daemon)
      raw=$(LC_ALL=C command cat "$path" 2>/dev/null) || return 3
      rewrite_marker "$path" "$f" "$old" "$new" "$raw" || rc=$?
      ;;
    appends)
      fm_lock_try_acquire "$path.lock" || return 6
      HELD_LOCKS[${#HELD_LOCKS[@]}]="$path.lock"
      rekey_rewrite "$path" n:2 0 "ident=$old" "ident=$new" || rc=$?
      fm_lock_release "$path.lock" || true
      unset "HELD_LOCKS[$((${#HELD_LOCKS[@]} - 1))]"
      ;;
    outcome) rekey_rewrite "$path" n:1 4 "$old" "$new" || rc=$? ;;
    manifest) rekey_rewrite "$path" "k:$task" 2 "$old" "$new" || rc=$? ;;
  esac
  return "$rc"
}

do_apply() {
  local header version family task cursor guard ident offset size prefix extra f path rc now_guard
  local rekeyed=0 current=0 reset=0 skipped=0 failed=0 why
  if ! regular_file "$RECORD"; then
    say "apply failed: no readable record at $RECORD; run record before the export"
    return 1
  fi
  header=$(LC_ALL=C sed -n 1p "$RECORD" 2>/dev/null) || header=
  version=${header%%"$TAB"*}
  if [ "$version" != "$RECORD_VERSION" ]; then
    say "apply failed: $RECORD is not a $RECORD_VERSION record"
    return 1
  fi
  session_lock_free || return 3
  take_lock "$STATE/.lock.acquire" "session claim" || return 3
  session_lock_free || return 3
  take_lock "$STATE/.watch.lock" watcher || return 3
  take_lock "$STATE/.supervise-daemon.lock" away-daemon || return 3
  take_lock "$FM_WAKE_QUEUE_LOCK" wake-queue || return 3
  take_lock "$STATE/.status-presentation-lock" presentation || return 3
  take_lock "$STATE/.branch-outcomes.lock" branch-outcome || return 3
  RUN_TMP=$(mktemp -d "$STATE/.reimport-rekey.run.XXXXXX") || { say "apply failed: cannot create a run directory in $STATE"; return 1; }
  while IFS=$TAB read -r family task cursor guard ident offset size prefix extra; do
    [ -n "$family" ] || continue
    case " $FAMILIES " in *" $family "*) ;; *) say "apply failed: unknown family '$family' in $RECORD"; failed=$((failed + 1)); continue ;; esac
    if [ -n "$extra" ] || [ -z "$prefix" ]; then
      say "apply failed: malformed $family row for $task in $RECORD"
      failed=$((failed + 1))
      continue
    fi
    f="$STATE/$task.status"
    if ! regular_file "$f"; then
      say "apply $family $task skipped: the status log is gone"
      skipped=$((skipped + 1))
      continue
    fi
    cursor_path_to path "$family" "$task" "$f"
    if [ "${path##*/}" != "$cursor" ]; then
      say "apply failed: the $family row for $task names $cursor, but its owner keeps that cursor at ${path##*/}"
      failed=$((failed + 1))
      continue
    fi
    rc=0
    cursor_read "$family" "$task" "$path" || rc=$?
    if [ "$rc" -eq 1 ]; then
      say "apply $family $task skipped: the cursor is gone"
      skipped=$((skipped + 1))
      continue
    fi
    if ! log_size_ident "$f"; then
      say "apply failed: cannot read size and identity of $task.status"
      failed=$((failed + 1))
      continue
    fi
    if [ "$rc" -eq 0 ] && _fm_file_ident_same "$C_IDENT" "$L_IDENT"; then
      say "apply $family $task already current"
      current=$((current + 1))
      continue
    fi
    why=
    if [ "$rc" -ne 0 ] || ! cursor_guard_to now_guard "$family" "$task" "$path" || [ "$now_guard" != "$guard" ]; then
      why="the cursor changed since the record"
    elif [ "$L_SIZE" != "$size" ]; then
      why="the log is $L_SIZE bytes, recorded $size"
    elif [ "$(rekey_sha prefix "$f" "$offset" 2>/dev/null || true)" != "$prefix" ]; then
      why="the log's first $offset bytes differ from the record"
    fi
    if [ -n "$why" ]; then
      say "apply $family $task left for reset: $why"
      reset=$((reset + 1))
      continue
    fi
    rc=0
    rewrite_cursor "$family" "$task" "$path" "$f" "$ident" "$L_IDENT" || rc=$?
    case "$rc" in
      0) say "apply $family $task rekeyed: offset $offset carried to the new identity"; rekeyed=$((rekeyed + 1)) ;;
      4) say "apply $family $task left for reset: the cursor changed during apply"; reset=$((reset + 1)) ;;
      6) say "apply $family $task left for reset: its ledger lock is held"; reset=$((reset + 1)) ;;
      *) say "apply failed: cannot rewrite the $family cursor of $task (exit $rc)"; failed=$((failed + 1)) ;;
    esac
  done <<EOF
$(LC_ALL=C sed 1d "$RECORD")
EOF
  say "apply done: $rekeyed rekeyed, $current already current, $reset left for reset, $skipped skipped, $failed failed"
  [ "$failed" -eq 0 ]
}

[ "$#" -eq 1 ] || usage
MODE=$1
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
case "$MODE" in
  record) do_record ;;
  apply) do_apply ;;
  -h|--help) sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  *) usage ;;
esac
