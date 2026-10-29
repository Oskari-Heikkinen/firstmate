#!/usr/bin/env bash
# fm-records-consolidate.sh - move handled records older than 7 days out of
# their separate files and into each tree's handled-record log, so thousands of
# tiny files stop holding otherwise empty 1 MiB blocks on the WSL disk file.
#
# Usage:
#   fm-records-consolidate.sh [--dry-run] --state <state-dir> [--state <state-dir>]...
#
# Nothing schedules this command; a person runs it against a home's state
# directory. It never chooses a home by itself: every state directory is named.
# --dry-run changes nothing and prints, per tree, the records it would move:
#   tree=<path> kind=<kind> files=<n> bytes=<n> mib<=<n> (<method>)
# mib<= is an upper bound on the 1 MiB blocks emptied: the distinct MiBs those
# files' data sit in, read with filefrag where it can map them, and otherwise
# one per non-empty file. A MiB empties only when nothing else lives in it.
# A run prints the same line per tree and then `moved=<n>` and `skipped=<n>`.
#
# Trees, under each <state-dir>:
#   procevent-inbox       kind=procevent: a captured result's .result, .adapter
#                         and .extension files, once its .handled marker is
#                         older than the age limit. The zero-byte marker stays,
#                         because it holds no data block and every reader and
#                         sequence allocator keys on it (bin/fm-procevent-lib.sh),
#                         and so does each source's newest result, which the
#                         land-after and observe readers look up as a file.
#   <task>.inbox/handled  kind=task-inbox: an acknowledged steering record
#                         (bin/fm-task-inbox-lib.sh), the same for a mate's inbox.
# The captain's notes inbox (state/inbox) and the operational inbox have no
# per-record acknowledgement this tool can prove, so it leaves them alone.
#
# Age: a record is eligible once now minus the newer of its handled file's
# mtime and ctime is at least the limit (7 days). For a task-inbox record that
# file is the record itself, whose ctime moves with the acknowledging rename.
# Unhandled records, a source's newest result, and records younger than the
# limit are never touched.
#
# Order of work per tree, under the tree's consolidation lock: remove what an
# interrupted earlier run left, store the eligible records by the log's append
# protocol (bin/fm-records-log-lib.sh owns it), then, holding each record
# owner's own lock (the procevent source lock, or the inbox .seq.lock), compare
# every file with its verified logged copy once more and remove only an
# identical one. A busy owner lock skips those records until the next run.
# A rerun finds records already in the log and only removes their files.
#
# Log: one plain line per event is appended to <state-dir>/records-consolidate.log
# (UTC time, tree, what happened, why, what next).
#
# Exit: 0 every tree done or nothing to do; 1 a tree failed or was locked by
# another run (named on stderr and in the log; rerun after fixing it); 2 usage.
#
# Environment:
#   FM_RECORDS_CONSOLIDATE_NOW       epoch seconds used as now (clock seam)
#   FM_PROCEVENT_CLAIM_ROOT          procevent source lock root (fm-procevent-lib.sh)
# The command runs at nice 19 and, where ionice exists, idle I/O class.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ "${FM_RECORDS_CONSOLIDATE_NICED:-}" != 1 ]; then
  export FM_RECORDS_CONSOLIDATE_NICED=1
  if command -v ionice >/dev/null 2>&1; then
    exec nice -n 19 ionice -c3 bash "$SCRIPT_DIR/fm-records-consolidate.sh" "$@"
  fi
  exec nice -n 19 bash "$SCRIPT_DIR/fm-records-consolidate.sh" "$@"
fi

unset FM_PROCEVENT_CAPTURE_PINNED_INBOX FM_PROCEVENT_CAPTURE_ABSOLUTE_INBOX

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# fm-procevent-lib.sh also brings fm-records-log-lib.sh.
# shellcheck source=bin/fm-procevent-lib.sh
. "$SCRIPT_DIR/fm-procevent-lib.sh"

MIN_AGE=604800
DRY_RUN=0
STATES=()
FAILED=0
LOG=

usage() { sed -n '2,/^set -u$/{/^set -u$/d;s/^# \{0,1\}//;p}' "$0"; }
die() { printf 'fm-records-consolidate: %s\n' "$*" >&2; exit 2; }

log_line() {  # <tree> <text>
  [ -n "$LOG" ] || return 0
  printf '%s %s: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$2" >> "$LOG" 2>/dev/null || true
}

# A tree failed: say what, where and what next, on stderr and in the log.
tree_failed() {  # <tree> <text>
  FAILED=1
  printf 'fm-records-consolidate: %s: %s\n' "$1" "$2" >&2
  log_line "$1" "$2"
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --state)
      [ "$#" -ge 2 ] && [ -n "$2" ] || die '--state needs a directory'
      STATES+=("$2"); shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1 (see --help)" ;;
  esac
done
[ "${#STATES[@]}" -gt 0 ] || die 'name at least one --state <state-dir> (see --help)'

NOW=${FM_RECORDS_CONSOLIDATE_NOW:-$(date +%s)}
case "$NOW" in ''|*[!0-9]*) die "FM_RECORDS_CONSOLIDATE_NOW must be epoch seconds: $NOW" ;; esac
CUTOFF=$((NOW - MIN_AGE))

# Eligible procevent records in <tree>: one line `<id>\t<seq>\t<has-result>`
# per old regular zero-byte marker whose result is not its source's newest.
procevent_candidates() {  # <tree>
  perl -e '
    my ($dir, $cut) = @ARGV;
    opendir(my $dh, $dir) or exit 2;
    my @names = readdir($dh);
    closedir($dh);
    my (%max, %result);
    for my $n (@names) {
      next unless $n =~ /\A(.+)\.(0|[1-9][0-9]*)\.result\z/;
      next if -l "$dir/$n" || !-f _;
      $result{"$1.$2"} = 1;
      $max{$1} = $2 if !defined $max{$1} || $2 > $max{$1};
    }
    for my $n (sort @names) {
      next unless $n =~ /\A(.+)\.(0|[1-9][0-9]*)\.handled\z/;
      my ($id, $seq) = ($1, $2);
      my @st = lstat("$dir/$n") or next;
      next if -l _ || !-f _ || $st[7] != 0;
      my $at = $st[9] > $st[10] ? $st[9] : $st[10];
      next if $at > $cut;
      my $has = $result{"$id.$seq"} ? 1 : 0;
      next if $has && $seq >= $max{$id};
      print "$id\t$seq\t$has\n";
    }' "$1" "$CUTOFF"
}

# Eligible task-inbox records in <tree> (a handled/ directory), one name a line.
task_inbox_candidates() {  # <tree>
  perl -e '
    my ($dir, $cut) = @ARGV;
    opendir(my $dh, $dir) or exit 2;
    for my $n (sort readdir($dh)) {
      next unless $n =~ /\A[0-9]+\.msg\z/;
      my @st = lstat("$dir/$n") or next;
      next if -l _ || !-f _;
      my $at = $st[9] > $st[10] ? $st[9] : $st[10];
      print "$n\n" if $at <= $cut;
    }' "$1" "$CUTOFF"
}

# Print `<bytes> <mib-upper-bound> <method>` for the files named in <list>.
measure() {  # <tree> <list-file>
  local tree=$1 list=$2 bytes mapped
  bytes=$(cd "$tree" && perl -e 'my $t = 0; while (my $n = <STDIN>) { chomp $n; my @s = lstat($n); $t += $s[7] if @s; } print "$t\n";' < "$list") || return 1
  mapped=''
  if command -v filefrag >/dev/null 2>&1 && [ -s "$list" ]; then
    # Physical extents in MiB units; a file whose extents filefrag cannot place
    # (delayed allocation, inline data, no mapping) counts one MiB if non-empty.
    mapped=$(cd "$tree" && tr '\n' '\0' < "$list" | xargs -0 filefrag -v -b1048576 2>/dev/null | perl -e '
      my (%mib, $unplaced, $file, $size, $placed);
      sub done { $unplaced++ if defined $file && $size > 0 && !$placed; }
      while (<STDIN>) {
        if (/^File size of (.*) is (\d+) /) { done(); ($file, $size, $placed) = ($1, $2, 0); next; }
        next unless /^\s*\d+:\s*\d+\.\.\s*\d+:\s*(\d+)\.\.\s*(\d+):/;
        my ($a, $b) = ($1, $2);
        next if /unknown_loc|inline|delalloc/;
        $placed = 1;
        $mib{$_} = 1 for $a .. $b;
      }
      done();
      print scalar(keys %mib) + ($unplaced // 0), "\n";') || mapped=''
  fi
  if [ -n "$mapped" ]; then
    printf '%s %s filefrag\n' "$bytes" "$mapped"
  else
    mapped=$(cd "$tree" && perl -e 'my $c = 0; while (my $n = <STDIN>) { chomp $n; my @s = lstat($n); $c++ if @s && $s[7] > 0; } print "$c\n";' < "$list") || return 1
    printf '%s %s one-per-file\n' "$bytes" "$mapped"
  fi
}

# Collect one tree's eligible files into <run>/files (every file to remove) and
# <run>/records (the record keys the owner-lock phase walks).
collect() {  # <kind> <tree> <run>
  local kind=$1 tree=$2 run=$3 rows id seq has suffix name
  : > "$run/files" && : > "$run/records" || return 2
  case "$kind" in
    procevent)
      rows=$(procevent_candidates "$tree") || return 2
      while IFS=$'\t' read -r id seq has; do
        [ -n "$id" ] || continue
        fm_procevent_source_id_valid "$id" || continue
        if [ "$has" = 0 ]; then
          # Only an interrupted run leaves sidecars behind a removed result,
          # and that run logged the result first.
          [ -e "$tree/$id.$seq.adapter" ] || [ -e "$tree/$id.$seq.extension" ] || continue
          fm_records_log_has "$tree" "$id.$seq.result" || {
            log_line "$tree" "left $id.$seq: its sidecars have no result file and no logged result; inspect them"
            continue
          }
        fi
        for suffix in result adapter extension; do
          name="$id.$seq.$suffix"
          [ -f "$tree/$name" ] && [ ! -L "$tree/$name" ] || continue
          printf '%s\n' "$name" >> "$run/files" || return 2
        done
        printf '%s\t%s\n' "$id" "$seq" >> "$run/records" || return 2
      done <<< "$rows"
      ;;
    task-inbox)
      rows=$(task_inbox_candidates "$tree") || return 2
      while IFS= read -r name; do
        [ -n "$name" ] || continue
        printf '%s\n' "$name" >> "$run/files" || return 2
        printf '%s\n' "$name" >> "$run/records" || return 2
      done <<< "$rows"
      ;;
  esac
}

# Remove one file once it is identical to its verified logged copy.
# 0 removed or already gone, 1 left because it differs.
remove_if_logged() {  # <tree> <run> <name>
  [ -e "$1/$3" ] || [ -L "$1/$3" ] || return 0
  [ -f "$1/$3" ] && [ ! -L "$1/$3" ] && cmp -s "$2/logged/$3" "$1/$3" || return 1
  rm -f -- "$1/$3"
}

# Owner-lock phase. Prints `<moved> <skipped>`.
remove_logged() {  # <kind> <tree> <run>
  local kind=$1 tree=$2 run=$3 id seq name lock prev='' held=0 moved=0 skipped=0 suffix ok
  case "$kind" in
    procevent)
      while IFS=$'\t' read -r id seq; do
        [ -n "$id" ] || continue
        if [ "$id" != "$prev" ]; then
          [ "$held" = 0 ] || fm_procevent_source_lock_release "$prev"
          held=0; prev=$id
          if fm_procevent_source_lock_try_acquire "$id"; then
            held=1
          else
            log_line "$tree" "skipped source $id: its source lock is busy; the next run retries"
          fi
        fi
        [ "$held" = 1 ] || { skipped=$((skipped + 1)); continue; }
        if ! fm_procevent_is_handled "$(dirname "$tree")" "$id" "$seq"; then
          skipped=$((skipped + 1)); continue
        fi
        ok=1
        # The result goes first, so an interrupted removal leaves only
        # sidecars that the next run recognizes by the logged result.
        for suffix in result adapter extension; do
          name="$id.$seq.$suffix"
          [ -e "$tree/$name" ] || [ -L "$tree/$name" ] || continue
          [ -e "$run/logged/$name" ] || { ok=0; break; }
          remove_if_logged "$tree" "$run" "$name" || { ok=0; break; }
        done
        if [ "$ok" = 1 ]; then moved=$((moved + 1)); else
          skipped=$((skipped + 1))
          log_line "$tree" "left $id.$seq: a file differs from its logged copy or is not logged; inspect it"
        fi
      done < "$run/records"
      [ "$held" = 0 ] || fm_procevent_source_lock_release "$prev"
      ;;
    task-inbox)
      # The inbox's sequence lock, the one every writer and the idempotent
      # dedup hold (bin/fm-task-inbox-lib.sh).
      lock="${tree%/handled}/.seq.lock"
      if ! fm_lock_try_acquire "$lock"; then
        log_line "$tree" "skipped: the inbox sequence lock is busy; the next run retries"
        printf '0 %s\n' "$(wc -l < "$run/records" | tr -d ' ')"
        return 0
      fi
      while IFS= read -r name; do
        [ -n "$name" ] || continue
        if [ -e "$run/logged/$name" ] && remove_if_logged "$tree" "$run" "$name"; then
          moved=$((moved + 1))
        else
          skipped=$((skipped + 1))
          log_line "$tree" "left $name: it differs from its logged copy or is not logged; inspect it"
        fi
      done < "$run/records"
      fm_lock_release "$lock"
      ;;
  esac
  printf '%s %s\n' "$moved" "$skipped"
}

# Plan in a throwaway directory: dry runs never create the log directory.
plan_tree() {  # <kind> <tree>
  local kind=$1 tree=$2 run m files bytes mib method
  run=$(mktemp -d "${TMPDIR:-/tmp}/fm-records-plan.XXXXXX") || { tree_failed "$tree" 'cannot make a scratch directory; nothing changed'; return; }
  if ! collect "$kind" "$tree" "$run"; then
    rm -rf -- "$run"
    tree_failed "$tree" 'cannot read the tree; nothing changed'
    return
  fi
  files=$(wc -l < "$run/files" | tr -d ' ')
  m=$(measure "$tree" "$run/files") || m='? ? unmeasured'
  read -r bytes mib method <<< "$m"
  printf 'tree=%s kind=%s files=%s bytes=%s mib<=%s (%s)\n' "$tree" "$kind" "$files" "$bytes" "$mib" "$method"
  rm -rf -- "$run"
}

consolidate_tree() {  # <kind> <tree>
  local kind=$1 tree=$2 run rc=0 files m logged name new counts recovered bytes mib method moved skipped
  fm_records_log_lock_try "$tree" || rc=$?
  case "$rc" in
    0) ;;
    1) tree_failed "$tree" 'another consolidation holds this tree; nothing changed, rerun after it ends'; return ;;
    *) tree_failed "$tree" 'cannot make the log directory; nothing changed'; return ;;
  esac
  if ! recovered=$(fm_records_log_recover "$tree"); then
    fm_records_log_unlock "$tree"
    tree_failed "$tree" 'cannot clear an earlier run; nothing changed, inspect .records-log'
    return
  fi
  [ -z "$recovered" ] || log_line "$tree" "removed uncommitted segment(s) an interrupted run left: ${recovered//$'\n'/ }"
  if ! fm_records_log_run_dir_to run "$tree"; then
    fm_records_log_unlock "$tree"
    tree_failed "$tree" 'cannot make a run directory; nothing changed'
    return
  fi
  if ! collect "$kind" "$tree" "$run"; then
    rm -rf -- "$run"; fm_records_log_unlock "$tree"
    tree_failed "$tree" 'cannot read the tree; nothing changed'
    return
  fi
  files=$(wc -l < "$run/files" | tr -d ' ')
  if [ "$files" = 0 ]; then
    rm -rf -- "$run"; fm_records_log_unlock "$tree"
    printf 'tree=%s kind=%s files=0 bytes=0 mib<=0 (none) moved=0 skipped=0\n' "$tree" "$kind"
    log_line "$tree" 'nothing eligible; nothing changed'
    return
  fi
  m=$(measure "$tree" "$run/files") || m='? ? unmeasured'
  # Records already in the log (an interrupted removal, or a rerun) are only
  # removed; the rest are appended as one new segment.
  logged="$run/logged"
  mkdir -p "$logged" || { rm -rf -- "$run"; fm_records_log_unlock "$tree"; tree_failed "$tree" 'cannot make a run directory; nothing changed'; return; }
  if ! fm_records_log_extract "$tree" "$logged"; then
    rm -rf -- "$run"; fm_records_log_unlock "$tree"
    tree_failed "$tree" 'cannot read the existing log; nothing changed, inspect .records-log'
    return
  fi
  new="$run/new"
  : > "$new"
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    [ -f "$logged/$name" ] && cmp -s "$logged/$name" "$tree/$name" && continue
    printf '%s\n' "$name" >> "$new"
  done < "$run/files"
  if ! fm_records_log_commit "$tree" "$new" "$run"; then
    rm -rf -- "$run"; fm_records_log_unlock "$tree"
    tree_failed "$tree" 'cannot store the records in the log (write, read-back or commit failed); every record is still a file, rerun after fixing the cause'
    return
  fi
  log_line "$tree" "logged $(wc -l < "$new" | tr -d ' ') new file(s); removing $files file(s) under their owners' locks"
  counts=$(remove_logged "$kind" "$tree" "$run")
  rm -rf -- "$run"
  fm_records_log_unlock "$tree"
  read -r bytes mib method <<< "$m"
  read -r moved skipped <<< "$counts"
  printf 'tree=%s kind=%s files=%s bytes=%s mib<=%s (%s) moved=%s skipped=%s\n' "$tree" "$kind" "$files" "$bytes" "$mib" "$method" "$moved" "$skipped"
  log_line "$tree" "moved $moved record(s) into the log, left $skipped for the next run"
}

for state in "${STATES[@]}"; do
  [ -d "$state" ] && [ ! -L "$state" ] || { printf 'fm-records-consolidate: %s: not a state directory\n' "$state" >&2; FAILED=1; continue; }
  state=$(cd -P "$state" && pwd -P) || { FAILED=1; continue; }
  LOG=
  [ "$DRY_RUN" = 1 ] || LOG="$state/records-consolidate.log"
  if [ -d "$state/procevent-inbox" ] && [ ! -L "$state/procevent-inbox" ]; then
    if [ "$DRY_RUN" = 1 ]; then plan_tree procevent "$state/procevent-inbox"
    else consolidate_tree procevent "$state/procevent-inbox"; fi
  fi
  for inbox in "$state"/*.inbox; do
    [ -d "$inbox/handled" ] && [ ! -L "$inbox/handled" ] && [ ! -L "$inbox" ] || continue
    if [ "$DRY_RUN" = 1 ]; then plan_tree task-inbox "$inbox/handled"
    else consolidate_tree task-inbox "$inbox/handled"; fi
  done
done
exit "$FAILED"
