#!/usr/bin/env bash
# tests/fm-reimport-rekey.test.sh - behavior tests for bin/fm-reimport-rekey.sh,
# which carries a home's identity-keyed status cursors across a distro
# re-import. Each case builds a fixture home with every cursor family, records
# it, copies it with cp -a (a real copy, so every file gets a new inode and
# birth time, as an import does), runs apply on the copy and drives the real
# drain and the public library readers over the result.
# shellcheck disable=SC2016 # the single-quoted scripts expand in the harness shell
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

DRAIN="$ROOT/bin/fm-wake-drain.sh"
OUTCOMES="$ROOT/bin/fm-branch-outcome.sh"
REKEY="$ROOT/bin/fm-reimport-rekey.sh"

TMP_ROOT=$(fm_test_tmproot fm-reimport-rekey-tests)

# The outcome backstop is presented only on a home that does not run the
# supervision host (see tests/fm-wake-file-ident-renumber.test.sh).
mkdir -p "$TMP_ROOT/config"
: > "$TMP_ROOT/config/supervision-host-off"
export FM_CONFIG_OVERRIDE="$TMP_ROOT/config"

# An identity reader that composes the weak form a file system without birth
# times produces, so the weak case runs on every platform.
WEAK_READER="$TMP_ROOT/weak-reader"
cat > "$WEAK_READER" <<'SH'
#!/usr/bin/env bash
if [ "$(uname -s)" = Darwin ]; then
  LC_ALL=C /usr/bin/stat -f 'weak:%d:%i' "$1"
else
  LC_ALL=C stat -c 'weak:%d:%i' "$1"
fi
SH
chmod +x "$WEAK_READER"

lib() {  # <shell-text> [args...]: run text with the wake and classify libraries loaded
  local text=$1
  shift
  bash -c '. "$1/bin/fm-wake-lib.sh"; _fm_wake_require_classify || exit 97; shift; '"$text" _ "$ROOT" "$@"
}

current_ident() {  # <file>
  lib '_fm_open_decisions_file_ident "$1"' "$1"
}

set_mtime() {  # <epoch> <file>
  perl -e 'utime($ARGV[0], $ARGV[0], $ARGV[1]) or exit 1' "$1" "$2"
}

expect_out() {  # <file> <text>: the fixed text appears in the output file
  assert_grep "$2" "$1" "expected '$2' in ${1##*/}: $(cat "$1")"
}

reject_out() {  # <file> <text>: the fixed text does not appear in the output file
  assert_no_grep "$2" "$1" "unexpected '$2' in ${1##*/}: $(cat "$1")"
}

cursor_digest() {  # <state>: one digest over every cursor file's name and bytes
  (cd "$1" && for f in .*cursor* .seen-* .hb-surfaced-* .subsuper-seen-status-* .*.home-appends .*.branch-outcome-index; do
    [ -f "$f" ] || continue
    printf '%s\n' "$f"
    cat "$f"
  done) | cksum
}

# seed_task <state> <task>: a log with an open decision, a note and a keyless
# captain event, carried through every cursor family: a branch outcome, the
# drain's fold, manifest and backstop, the watcher's seen marker, a home-append
# range, the heartbeat and away-daemon markers and the snapshot fold cursor.
seed_task() {
  local state=$1 task=$2
  printf 'needs-decision [key=target]: choose the release target\nnote: release context attached\ndone: delivered the build\n' \
    > "$state/$task.status"
  set_mtime $(( $(date +%s) - 20 )) "$state/$task.status"
  FM_STATE_OVERRIDE="$state" "$OUTCOMES" append --task "$task" --verdict captain \
    --summary 'build reached main' >/dev/null || fail "$task: could not record a branch outcome"
}

settle_home() {  # <state> <task>...
  local state=$1 task out
  shift
  out="$state/../drain.out"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "first drain failed"
  for task in "$@"; do
    grep -F "$task note: release context attached" "$out" >/dev/null \
      || fail "the first drain did not present $task's note: $(cat "$out")"
    lib '
      f=$1/$2.status
      start=$(printf "needs-decision [key=target]: choose the release target\n" | LC_ALL=C wc -c)
      end=$(printf "note: release context attached\n" | LC_ALL=C wc -c)
      start=${start//[[:space:]]/}; end=$((start + ${end//[[:space:]]/}))
      status_home_appends_record "$f" "$start" "$end" || exit 1
      printf "%s\t%s\n" "$start" "$end" > "$1/.test-range-$2"
      fm_wake_status_mark_current "$1" "$f" || exit 1
      size=$(_fm_status_file_size "$f"); size=${size//[[:space:]]/}
      ident=$(_fm_open_decisions_file_ident "$f")
      status_presentation_marker_commit "$(status_heartbeat_seen_marker_path "$1" "$2")" "$f" "$size" "$ident" || exit 1
      status_presentation_marker_commit "$(status_daemon_seen_marker_path "$1" "$2")" "$f" "$size" "$ident" || exit 1
      status_open_decisions_incremental "$f" "$size" exact >/dev/null || exit 1
    ' "$state" "$task" || fail "could not mark every cursor of $task"
  done
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "settling drain failed"
}

# assert_rekeyed <label> <state> <task>: every family now names the copy's
# identity and the watcher, ledger and marker readers still apply.
assert_rekeyed() {
  local label=$1 state=$2 task=$3 ident range
  ident=$(current_ident "$state/$task.status")
  grep -Fx "ident=$ident" "$state/.$task.open-decisions-cursor" >/dev/null \
    || fail "$label: the OPEN DECISIONS cursor was not rekeyed: $(cat "$state/.$task.open-decisions-cursor")"
  grep -Fx "ident=$ident" "$state/.$task.snapshot-open-decisions-cursor" >/dev/null \
    || fail "$label: the snapshot cursor was not rekeyed"
  [ "$(awk -F '\t' -v t="$task" '$1 == t { print $2 }' "$state/.status-presentation-cursor")" = "$ident" ] \
    || fail "$label: the presentation manifest row was not rekeyed"
  [ "$(awk -F '\t' '{ print $4 }' "$state/.$task.branch-outcome-index")" = "$ident" ] \
    || fail "$label: the branch-outcome index was not rekeyed"
  [ "$(stat_mode "$state/.$task.branch-outcome-index")" = 600 ] \
    || fail "$label: the branch-outcome index lost its private mode"
  range=$(cat "$state/.test-range-$task")
  lib '
    f=$1/$2.status
    fm_wake_signal_reported_current "$1" "$f" || { echo "reported marker no longer current"; exit 1; }
    fm_wake_signal_seen_current "$1" "$f" || { echo "seen marker no longer current"; exit 1; }
    status_home_appends_covers "$f" "${3%%	*}" "${3#*	}" || { echo "home-append ledger discarded"; exit 1; }
    for m in "$(status_heartbeat_seen_marker_path "$1" "$2")" "$(status_daemon_seen_marker_path "$1" "$2")"; do
      [ "$(status_presentation_marker_offset "$m" "$f")" = "$(_fm_status_file_size "$f")" ] \
        || { echo "marker $m no longer applies"; exit 1; }
    done
  ' "$state" "$task" "$range" > "$state/.test-lib.out" 2>&1 \
    || fail "$label: $(cat "$state/.test-lib.out")"
}

stat_mode() {  # <file>
  case "$(uname -s)" in Darwin) stat -f '%Lp' "$1" ;; *) stat -c '%a' "$1" ;; esac
}

copy_home() {  # <case-dir> <copy-name>: a real copy, so every identity changes
  rm -rf "${1:?}/$2"
  cp -a "$1/state" "$1/$2" || fail "could not copy the fixture home"
}

check_rekey_reads_only_new_bytes() {  # <label> [<identity-reader>]
  local label=$1 reader=${2:-} dir state copy out probe old_ident new_ident added
  dir=$(make_case "copy-$label"); state="$dir/state"; out="$dir/drain.out"; probe="$dir/fold-probe"
  export FM_STATUS_IDENTITY_READER="$reader"
  seed_task "$state" keep
  settle_home "$state" keep
  FM_STATE_OVERRIDE="$state" "$REKEY" record > "$dir/record.out" || fail "$label: record failed: $(cat "$dir/record.out")"
  expect_out "$dir/record.out" "record done: 8 cursors recorded, 0 not recorded"
  [ "$(stat_mode "$state/.reimport-rekey.record")" = 600 ] || fail "$label: the record is not private"

  copy_home "$dir" copy
  copy="$dir/copy"
  old_ident=$(current_ident "$state/keep.status")
  new_ident=$(current_ident "$copy/keep.status")
  [ "$old_ident" != "$new_ident" ] || fail "$label: the copy kept the identity $old_ident"

  FM_STATE_OVERRIDE="$copy" "$REKEY" apply > "$dir/apply.out" || fail "$label: apply failed: $(cat "$dir/apply.out")"
  expect_out "$dir/apply.out" "apply done: 8 rekeyed, 0 already current, 0 left for reset, 0 skipped, 0 failed"
  assert_rekeyed "$label" "$copy" keep
  [ ! -e "$copy/.lock.acquire" ] && [ ! -e "$copy/.watch.lock" ] && [ ! -e "$copy/.status-presentation-lock" ] \
    || fail "$label: apply left a lock behind"

  added='note: written after the import'
  printf '%s\n' "$added" >> "$copy/keep.status"
  FM_OPEN_DECISIONS_READ_PROBE="$probe" FM_STATE_OVERRIDE="$copy" "$DRAIN" > "$out" \
    || fail "$label: drain after apply failed"
  [ "$(cat "$probe")" = "$copy/keep.status	$(( ${#added} + 1 ))" ] \
    || fail "$label: the OPEN DECISIONS fold read more than the new line: $(cat "$probe")"
  expect_out "$out" "keep $added"
  reject_out "$out" "release context attached"
  reject_out "$out" "STATUS OUTCOME BACKSTOP ("
  if ! grep -F 'OPEN DECISIONS' "$out" >/dev/null \
    || ! grep -F keep "$out" | grep -F '[key=target]' | grep -F 'choose the release target' >/dev/null; then
    fail "$label: the open decision was lost: $(cat "$out")"
  fi
  unset FM_STATUS_IDENTITY_READER
  pass "$label identities: after a copy to new inodes, apply rekeys every cursor family and the drain reads only the new bytes"
}

test_rekey_strong_or_native() {
  check_rekey_reads_only_new_bytes native
}

test_rekey_weak() {
  check_rekey_reads_only_new_bytes weak "$WEAK_READER"
}

test_mismatch_and_missing_are_left_alone() {
  local dir state copy before_edit before_grow
  dir=$(make_case mismatch); state="$dir/state"
  seed_task "$state" edit
  seed_task "$state" grow
  seed_task "$state" gone
  settle_home "$state" edit grow gone
  FM_STATE_OVERRIDE="$state" "$REKEY" record > "$dir/record.out" || fail "record failed: $(cat "$dir/record.out")"
  copy_home "$dir" copy
  copy="$dir/copy"
  # Same size, one byte changed; a line appended; a deleted log.
  perl -pi -e 's/choose/Choose/' "$copy/edit.status"
  printf 'note: appended after the record\n' >> "$copy/grow.status"
  rm -f "$copy/gone.status"
  before_edit=$(cat "$copy/.edit.open-decisions-cursor" "$copy/.seen-edit_status" "$copy/.edit.home-appends")
  before_grow=$(cat "$copy/.grow.open-decisions-cursor" "$copy/.seen-grow_status" "$copy/.grow.home-appends")

  FM_STATE_OVERRIDE="$copy" "$REKEY" apply > "$dir/apply.out" || fail "apply failed: $(cat "$dir/apply.out")"
  expect_out "$dir/apply.out" "apply odc edit left for reset: the log's first"
  expect_out "$dir/apply.out" "apply odc grow left for reset: the log is"
  expect_out "$dir/apply.out" "apply odc gone skipped: the status log is gone"
  expect_out "$dir/apply.out" "apply done: 0 rekeyed, 0 already current, 16 left for reset, 8 skipped, 0 failed"
  [ "$before_edit" = "$(cat "$copy/.edit.open-decisions-cursor" "$copy/.seen-edit_status" "$copy/.edit.home-appends")" ] \
    || fail "a hash mismatch still rewrote a cursor"
  [ "$before_grow" = "$(cat "$copy/.grow.open-decisions-cursor" "$copy/.seen-grow_status" "$copy/.grow.home-appends")" ] \
    || fail "a size mismatch still rewrote a cursor"
  pass "a size or hash mismatch is left for the normal reset and a missing log is skipped"
}

test_second_apply_is_noop() {
  local dir state copy digest
  dir=$(make_case twice); state="$dir/state"
  seed_task "$state" again
  settle_home "$state" again
  FM_STATE_OVERRIDE="$state" "$REKEY" record > "$dir/record.out" || fail "record failed"
  copy_home "$dir" copy
  copy="$dir/copy"
  FM_STATE_OVERRIDE="$copy" "$REKEY" apply > "$dir/apply.out" || fail "first apply failed: $(cat "$dir/apply.out")"
  digest=$(cursor_digest "$copy")
  FM_STATE_OVERRIDE="$copy" "$REKEY" apply > "$dir/apply2.out" || fail "second apply failed: $(cat "$dir/apply2.out")"
  expect_out "$dir/apply2.out" "apply done: 0 rekeyed, 8 already current, 0 left for reset, 0 skipped, 0 failed"
  [ "$digest" = "$(cursor_digest "$copy")" ] || fail "a second apply changed a cursor"
  pass "a second apply changes nothing"
}

test_cursor_changed_since_record_is_left() {
  local dir state copy
  dir=$(make_case changed); state="$dir/state"
  seed_task "$state" moved
  settle_home "$state" moved
  FM_STATE_OVERRIDE="$state" "$REKEY" record > "$dir/record.out" || fail "record failed"
  copy_home "$dir" copy
  copy="$dir/copy"
  perl -pi -e 's/^offset=\d+/offset=0/' "$copy/.moved.open-decisions-cursor"
  FM_STATE_OVERRIDE="$copy" "$REKEY" apply > "$dir/apply.out" || fail "apply failed: $(cat "$dir/apply.out")"
  expect_out "$dir/apply.out" "apply odc moved left for reset: the cursor changed since the record"
  expect_out "$dir/apply.out" "apply seen moved rekeyed"
  pass "a cursor that changed after the record is left for the normal reset"
}

test_stale_cursor_is_not_recorded() {
  local dir state
  dir=$(make_case stale); state="$dir/state"
  seed_task "$state" old
  settle_home "$state" old
  # Replace the log: every cursor now names a file that no longer exists.
  cp "$state/old.status" "$state/old.status.new"
  mv -f "$state/old.status.new" "$state/old.status"
  FM_STATE_OVERRIDE="$state" "$REKEY" record > "$dir/record.out" || fail "record failed: $(cat "$dir/record.out")"
  expect_out "$dir/record.out" "record odc old not recorded: the cursor already does not match its log"
  expect_out "$dir/record.out" "record done: 0 cursors recorded, 8 not recorded"
  pass "a cursor that already does not match its log is never carried forward"
}

test_apply_refuses_while_home_is_live() {
  local dir state copy holder digest rc
  dir=$(make_case live); state="$dir/state"
  seed_task "$state" busy
  settle_home "$state" busy
  FM_STATE_OVERRIDE="$state" "$REKEY" record > "$dir/record.out" || fail "record failed"
  copy_home "$dir" copy
  copy="$dir/copy"
  digest=$(cursor_digest "$copy")
  # This shell stays alive for the whole case and is no harness, so the session
  # lock reads it as a live owner of unknown kind.
  holder=$$

  printf '%s\n' "$holder" > "$copy/.lock"
  rc=0; FM_STATE_OVERRIDE="$copy" "$REKEY" apply > "$dir/apply.out" 2>&1 || rc=$?
  [ "$rc" -eq 3 ] || fail "apply with a live session lock exited $rc: $(cat "$dir/apply.out")"
  expect_out "$dir/apply.out" "apply refused: the session lock"
  rm -f "$copy/.lock"

  mkdir "$copy/.watch.lock"
  printf '%s\n' "$holder" > "$copy/.watch.lock/pid"
  rc=0; FM_STATE_OVERRIDE="$copy" "$REKEY" apply > "$dir/apply.out" 2>&1 || rc=$?
  [ "$rc" -eq 3 ] || fail "apply with a live watcher exited $rc: $(cat "$dir/apply.out")"
  expect_out "$dir/apply.out" "apply refused: the watcher lock"
  [ ! -e "$copy/.lock.acquire" ] || fail "a refused apply left the session claim lock behind"
  [ "$digest" = "$(cursor_digest "$copy")" ] || fail "a refused apply changed a cursor"

  # A reaped child's pid stands for a watcher that died holding the lock.
  sh -c 'exit 0' &
  holder=$!
  wait "$holder" 2>/dev/null || true
  printf '%s\n' "$holder" > "$copy/.watch.lock/pid"
  FM_STATE_OVERRIDE="$copy" "$REKEY" apply > "$dir/apply.out" 2>&1 || fail "apply after the holder exited failed: $(cat "$dir/apply.out")"
  expect_out "$dir/apply.out" "apply done: 8 rekeyed"
  pass "apply refuses while a session or watcher holds the home's lock, and proceeds once it is stale"
}

test_apply_without_record_fails() {
  local dir rc=0
  dir=$(make_case norecord)
  FM_STATE_OVERRIDE="$dir/state" "$REKEY" apply > "$dir/apply.out" 2>&1 || rc=$?
  [ "$rc" -eq 1 ] || fail "apply without a record exited $rc"
  expect_out "$dir/apply.out" "apply failed: no readable record"
  rc=0
  FM_STATE_OVERRIDE="$dir/state" "$REKEY" > /dev/null 2>&1 || rc=$?
  [ "$rc" -eq 2 ] || fail "no mode exited $rc, not 2"
  pass "apply without a record fails, and a missing mode is a usage error"
}

test_rekey_strong_or_native
test_rekey_weak
test_mismatch_and_missing_are_left_alone
test_second_apply_is_noop
test_cursor_changed_since_record_is_left
test_stale_cursor_is_not_recorded
test_apply_refuses_while_home_is_live
test_apply_without_record_fails
