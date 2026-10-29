#!/usr/bin/env bash
# Behavior tests for bin/fm-repack.sh (docs/disk-room.md "Repacking cold trees").
#
# Every case works on fixture trees in its own temporary home. Admission and
# the I/O cap are stand-ins that log their arguments and run the command (or
# refuse with 75), so no case reserves room or needs a delegated io
# controller.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

if [ "$(uname -s)" != Linux ] || ! command -v python3 >/dev/null 2>&1; then
  echo "skip: fm-repack needs Linux (file leases, renameat2) and python3"
  exit 0
fi

unset FM_REPACK_NOW FM_REPACK_DISK_ROOM FM_IO_CAP FM_REPACK_TEST_CRASH FM_REPACK_TEST_DURING_COPY FM_PACK_SLOT_LOCK
TMP_ROOT=$(fm_test_tmproot fm-repack)
REPACK="$ROOT/bin/fm-repack.sh"
NOW=1793000000 # 2026-10-26 09:33 UTC
OLD=$((NOW - 10 * 86400))

cat >"$TMP_ROOT/disk-room" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FAKE_LOG"
[ "$1" = run ] || exit 2
if [ -n "${FAKE_REFUSE:-}" ]; then
  echo "fm-disk-room: refused $3: low room (fixture)" >&2
  exit 75
fi
while [ "$1" != -- ]; do shift; done
shift
"$@"
SH
cat >"$TMP_ROOT/io-cap" <<'SH'
#!/usr/bin/env bash
printf 'io-cap %s\n' "$*" >>"$FAKE_LOG"
[ "$1" = --strict ] && [ "$2" = -- ] || exit 3
shift 2
exec "$@"
SH
chmod +x "$TMP_ROOT/disk-room" "$TMP_ROOT/io-cap"

# new_home NAME -> a home with config/ and the trees named in TREES
new_home() {
  local h="$TMP_ROOT/$1"
  mkdir -p "$h/config" "$h/state"
  : >"$h.log"
  printf '%s\n' "$h"
}

repack() {
  FAKE_LOG="$H.log" FM_REPACK_NOW=$NOW FM_REPACK_DISK_ROOM="$TMP_ROOT/disk-room" FM_IO_CAP="$TMP_ROOT/io-cap" \
    FM_PACK_SLOT_LOCK="$H.slot" "$REPACK" "$@" --home "$H"
}

# cold PATH [BYTES] [AGE_DAYS]: a file of BYTES random bytes with mtime and
# atime AGE_DAYS (default 10) before NOW, at a nonzero nanosecond.
cold() {
  mkdir -p "$(dirname "$1")"
  head -c "${2:-5000}" /dev/urandom >"$1"
  touch -d "@$((NOW - ${3:-10} * 86400)).123456789" "$1"
}

ino() { stat -c %i "$1"; }
temps() { find "$1" -name '.fm-repack-*.tmp' | wc -l | tr -d ' '; }

test_nothing_to_do() {
  local out
  H=$(new_home nothing)
  mkdir -p "$H/data"
  cold "$H/data/a"
  out=$(repack plan) || fail "plan exits 0 without config/repack-trees"
  assert_contains "$out" "nothing to do" "plan says there is nothing to do"
  out=$(repack run) || fail "run exits 0 without config/repack-trees"
  assert_contains "$out" "nothing to do" "run says there is nothing to do"
  printf '# no trees yet\n\n' >"$H/config/repack-trees"
  out=$(repack run) || fail "run exits 0 with a comment-only config/repack-trees"
  assert_contains "$out" "nothing to do" "an empty list is nothing to do"
  assert_absent "$H/state/fm-repack" "nothing to do writes no state"
  [ -s "$H.log" ] && fail "nothing to do asks no admission"
  pass "an absent or empty config/repack-trees is nothing to do"
}

test_refusals() {
  local out rc=0
  H=$(new_home refusals)
  printf 'missing\n' >"$H/config/repack-trees"
  out=$(repack plan 2>&1) || rc=$?
  expect_code 2 "$rc" "a tree that is not a directory"
  assert_contains "$out" "repack-trees line 1: missing is not a directory" "the refusal names the line"
  mkdir -p "$H/state/x"
  printf '# trees\nstate/x\n' >"$H/config/repack-trees"
  rc=0
  out=$(repack run 2>&1) || rc=$?
  expect_code 2 "$rc" "a tree inside state/"
  assert_contains "$out" "line 2: state/x is inside a state/ directory" "the refusal names the state tree"
  rc=0
  out=$(FM_REPACK_NOW=$NOW "$REPACK" run --home "$TMP_ROOT/not-a-home" 2>&1) || rc=$?
  expect_code 2 "$rc" "a home without config/"
  rc=0
  "$REPACK" pack >/dev/null 2>&1 || rc=$?
  expect_code 2 "$rc" "an unknown command"
  pass "a bad tree line, a state/ tree, a missing home and misuse refuse with exit 2"
}

test_rewrite_keeps_content_and_metadata() {
  local out f before xattr=no
  H=$(new_home meta)
  f="$H/data/cold.bin"
  cold "$f" 3145728
  chmod 0640 "$f"
  if python3 -c 'import os, sys; os.setxattr(sys.argv[1], "user.fm-test", b"kept")' "$f" 2>/dev/null; then xattr=yes; fi
  cp -p "$f" "$TMP_ROOT/meta.orig"
  before=$(stat -c '%a %u %g %s %y %x' "$f")
  printf 'data\n' >"$H/config/repack-trees"
  local old_ino
  old_ino=$(ino "$f")
  out=$(repack run) || fail "run exits 0: $out"
  assert_contains "$out" "run done: repacked 1 files, 3145728 bytes" "the run reports what it rewrote"
  assert_not_equals "$old_ino" "$(ino "$f")" "the path holds a new inode"
  assert_equals "$before" "$(stat -c '%a %u %g %s %y %x' "$f")" "mode, owner, size, mtime and atime are kept to the nanosecond"
  cmp -s "$f" "$TMP_ROOT/meta.orig" || fail "the content is unchanged"
  if [ "$xattr" = yes ]; then
    assert_equals kept "$(python3 -c 'import os, sys; print(os.getxattr(sys.argv[1], "user.fm-test").decode())' "$f")" "xattrs are kept"
  fi
  assert_equals 0 "$(temps "$H/data")" "no temporary file is left"
  assert_grep "run --name fm-repack-" "$H.log" "the batch is admitted under its name"
  assert_grep "--expect-write 3145728 -- $TMP_ROOT/io-cap --strict --" "$H.log" "admission is sized to the batch and wraps the I/O cap"
  assert_grep "io-cap --strict -- " "$H.log" "the batch runs under fm-io-cap --strict"
  assert_grep "run done: repacked 1 files" "$H/state/fm-repack/log" "the log records the run"
  pass "a run rewrites a cold file in place with its bytes, mode, owner, times and xattrs (xattrs checked: $xattr)"
}

test_rerun_is_noop() {
  local out after calls
  H=$(new_home rerun)
  cold "$H/data/a"
  cold "$H/data/b"
  printf 'data\n' >"$H/config/repack-trees"
  repack run >/dev/null || fail "first run exits 0"
  after="$(ino "$H/data/a") $(ino "$H/data/b")"
  calls=$(wc -l <"$H.log")
  out=$(repack run) || fail "rerun exits 0"
  assert_contains "$out" "nothing to repack" "the rerun finds nothing"
  assert_contains "$out" "repacked 2" "the rerun counts the files it already repacked"
  assert_equals "$after" "$(ino "$H/data/a") $(ino "$H/data/b")" "the rerun rewrites nothing"
  assert_equals "$calls" "$(wc -l <"$H.log")" "the rerun asks no admission"
  pass "a rerun is a no-op for files already repacked"
}

test_skip_classes() {
  local out d keep f
  H=$(new_home skips)
  d="$H/data"
  cold "$d/plain"
  cold "$d/young" 5000 1
  cold "$d/linked"
  ln "$d/linked" "$d/linked2"
  cold "$d/db.sqlite"
  cold "$d/db.sqlite-wal"
  cold "$d/j.db"
  cold "$d/j.db-journal"
  cold "$d/state/s"
  cold "$d/sub/state/s2"
  cold "$d/repo/.git/objects/aa/obj"
  cold "$d/bare.git/objects/bb/obj"
  cold "$d/bare.git/HEAD"
  mkdir -p "$d/bare.git/refs"
  cold "$d/held"
  : >"$d/empty"
  touch -d "@$OLD" "$d/empty"
  printf 'data\n' >"$H/config/repack-trees"
  keep=""
  for f in young linked linked2 db.sqlite db.sqlite-wal j.db j.db-journal state/s sub/state/s2 \
    repo/.git/objects/aa/obj bare.git/objects/bb/obj held empty; do
    keep="$keep $f:$(ino "$d/$f")"
  done
  exec 3<"$d/held"
  out=$(repack run) || fail "run exits 0 with skips: $out"
  exec 3<&-
  assert_contains "$out" "repacked 2 files" "only the plain file and the bare repository's HEAD are rewritten"
  assert_contains "$out" "young 1" "a file under 7 days old is skipped"
  assert_contains "$out" "empty 1" "an empty file is skipped"
  assert_contains "$out" "hard-linked 2" "both names of a hard-linked file are skipped"
  assert_contains "$out" "sqlite 4" "SQLite files with -wal or -journal, and those files, are skipped"
  assert_contains "$out" "open 1" "a file another process holds open is skipped"
  assert_contains "$out" "state dirs 2" "every directory named state is skipped"
  assert_contains "$out" "git dirs 2" "a .git directory and a bare repository's objects are skipped"
  for f in $keep; do
    assert_equals "${f#*:}" "$(ino "$d/${f%%:*}")" "${f%%:*} keeps its inode"
  done
  assert_equals 0 "$(temps "$d")" "no temporary file is left"
  pass "every skip class leaves its files untouched and is counted"
}

test_changed_during_copy() {
  local out f old_ino
  H=$(new_home changed)
  f="$H/data/moving"
  cold "$f"
  printf 'data\n' >"$H/config/repack-trees"
  cat >"$TMP_ROOT/touch-it" <<'SH'
#!/usr/bin/env bash
exec touch -c -m -d @1700000000 "$1"
SH
  chmod +x "$TMP_ROOT/touch-it"
  old_ino=$(ino "$f")
  out=$(FM_REPACK_TEST_DURING_COPY="$TMP_ROOT/touch-it" repack run) || fail "run exits 0 when a file changes: $out"
  assert_contains "$out" "repacked 0 files" "the changed file is not rewritten"
  assert_contains "$out" "changed 1" "the change is counted"
  assert_equals "$old_ino" "$(ino "$f")" "the changed file keeps its inode"
  assert_equals 1700000000 "$(stat -c %Y "$f")" "the change itself stands"
  assert_equals 0 "$(temps "$H/data")" "the copy is removed"
  assert_grep "skipped $f: changed: during the copy" "$H/state/fm-repack/log" "the log names the changed file"
  pass "a file whose mtime changes during the copy is left as it is"
}

test_crash_before_swap_keeps_original() {
  local out rc=0 f old_ino
  H=$(new_home crash1)
  f="$H/data/a"
  cold "$f" 200000
  cp -p "$f" "$TMP_ROOT/crash1.orig"
  printf 'data\n' >"$H/config/repack-trees"
  old_ino=$(ino "$f")
  out=$(FM_REPACK_TEST_CRASH=before-swap repack run 2>&1) || rc=$?
  expect_code 1 "$rc" "a batch killed between copy and exchange"
  assert_contains "$out" "every path holds its original or its verified copy" "the failure says no path lost its data"
  assert_equals "$old_ino" "$(ino "$f")" "the path keeps the original"
  cmp -s "$f" "$TMP_ROOT/crash1.orig" || fail "the original's bytes are intact"
  assert_equals 1 "$(temps "$H/data")" "the kill leaves the copy behind"
  out=$(repack run) || fail "the rerun exits 0: $out"
  assert_contains "$out" "recovered 1 temporary file" "the rerun removes the copy"
  assert_contains "$out" "repacked 1 files" "the rerun repacks the file"
  assert_equals 0 "$(temps "$H/data")" "no temporary file is left"
  cmp -s "$f" "$TMP_ROOT/crash1.orig" || fail "the bytes are intact after the rerun"
  pass "a crash between copy and exchange keeps the original, and the rerun cleans up"
}

test_crash_after_swap_keeps_copy() {
  local out rc=0 f new_ino
  H=$(new_home crash2)
  f="$H/data/a"
  cold "$f" 200000
  cp -p "$f" "$TMP_ROOT/crash2.orig"
  printf 'data\n' >"$H/config/repack-trees"
  out=$(FM_REPACK_TEST_CRASH=after-swap repack run 2>&1) || rc=$?
  expect_code 1 "$rc" "a batch killed after the exchange"
  new_ino=$(ino "$f")
  cmp -s "$f" "$TMP_ROOT/crash2.orig" || fail "the path holds the verified copy"
  assert_equals 1 "$(temps "$H/data")" "the original is left under the temporary name"
  out=$(repack run) || fail "the rerun exits 0: $out"
  assert_contains "$out" "recovered 1 temporary file" "the rerun removes the original's old name"
  assert_contains "$out" "nothing to repack" "the copy is not rewritten again"
  assert_equals "$new_ino" "$(ino "$f")" "the copy stays"
  assert_equals 0 "$(temps "$H/data")" "no temporary file is left"
  pass "a crash after the exchange keeps the verified copy, and the rerun does not redo it"
}

test_admission_refusal_holds_batch() {
  local out rc=0 a b
  H=$(new_home held)
  cold "$H/data/a" 2000000
  cold "$H/data/b" 2000000
  printf 'data\n' >"$H/config/repack-trees"
  a=$(ino "$H/data/a")
  b=$(ino "$H/data/b")
  out=$(FAKE_REFUSE=1 repack run 2>&1) || rc=$?
  expect_code 75 "$rc" "a refused admission"
  assert_contains "$out" "held: admission refused the batch (4194304 bytes): fm-disk-room: refused" "the hold quotes the refusal"
  assert_equals "$a $b" "$(ino "$H/data/a") $(ino "$H/data/b")" "nothing is rewritten"
  assert_grep "--expect-write 4194304 " "$H.log" "the whole batch is declared in one admission"
  assert_grep "held: admission refused the batch" "$H/state/fm-repack/log" "the log records the hold"
  assert_equals "" "$(find "$H/state/fm-repack" -name 'run-*')" "the held run leaves no run directory"
  out=$(repack run) || fail "the run after the hold exits 0: $out"
  assert_contains "$out" "repacked 2 files" "the batch runs once admitted"
  pass "a refused admission holds the whole batch with exit 75"
}

test_one_batch_in_time_order() {
  local out
  H=$(new_home order)
  cold "$H/a/x" 5000 9
  cold "$H/b/y" 5000 20
  cold "$H/a/z" 5000 15
  printf 'a\n%s/b\n' "$H" >"$H/config/repack-trees"
  out=$(repack run) || fail "run exits 0: $out"
  assert_contains "$out" "repacked 3 files" "both trees are covered"
  assert_equals 1 "$(grep -c '^run ' "$H.log")" "one admission covers both trees"
  assert_equals "$(ino "$H/b/y") $(ino "$H/a/z") $(ino "$H/a/x")" "$(cut -f1 "$H/state/fm-repack/repacked.tsv" | tr '\n' ' ' | sed 's/ $//')" \
    "the files are rewritten oldest first across trees"
  pass "every listed tree is rewritten in one batch, oldest mtime first"
}

test_lock_and_baseline() {
  local out rc=0 a
  H=$(new_home lockbase)
  cold "$H/data/a"
  printf 'data\n' >"$H/config/repack-trees"
  a=$(ino "$H/data/a")
  repack baseline --at "$(($(date +%s) + 60))" >/dev/null || fail "baseline exits 0"
  out=$(repack run) || fail "run exits 0 under a baseline"
  assert_contains "$out" "baseline 1" "a file unchanged since the baseline is skipped"
  if command -v flock >/dev/null 2>&1; then
    exec 4>"$H/state/fm-repack/lock"
    flock 4
    out=$(repack run 2>&1) || rc=$?
    exec 4>&-
    expect_code 75 "$rc" "a run while another holds the lock"
    assert_contains "$out" "another fm-repack run for this home is active" "the hold names the lock"
  fi
  repack baseline --at 1 >/dev/null || fail "baseline moves back"
  out=$(repack run) || fail "run exits 0 after the baseline moves"
  assert_contains "$out" "repacked 1 files" "the file is repacked once the baseline is older"
  assert_not_equals "$a" "$(ino "$H/data/a")" "the file was rewritten"
  pass "a baseline skips densely written files, and a held lock holds the run"
}

test_pack_slot_waits_and_holds() {
  local out rc=0 a pid start
  if ! command -v flock >/dev/null 2>&1; then
    echo "skip: test_pack_slot_waits_and_holds needs flock(1)"
    return 0
  fi
  H=$(new_home slot)
  cold "$H/data/a"
  printf 'data\n' >"$H/config/repack-trees"
  a=$(ino "$H/data/a")
  cat >"$TMP_ROOT/slot-probe" <<'SH'
#!/usr/bin/env bash
if flock -n "$SLOT" true; then echo free; else echo held; fi >>"$SLOT.probe"
SH
  chmod +x "$TMP_ROOT/slot-probe"
  exec 5>"$H.slot"
  flock 5
  # 5>&-: the run must not inherit the fd that holds the slot.
  SLOT="$H.slot" FM_REPACK_TEST_DURING_COPY="$TMP_ROOT/slot-probe" repack run >"$H.out" 2>&1 5>&- &
  pid=$!
  start=$SECONDS
  until grep -qF "waiting: another pack or repack holds the machine-wide pack slot $H.slot" "$H.out"; do
    kill -0 "$pid" 2>/dev/null || break
    [ $((SECONDS - start)) -lt 60 ] || break
    sleep 0.1
  done
  assert_grep "waiting: another pack or repack holds the machine-wide pack slot" "$H.out"
  kill -0 "$pid" 2>/dev/null || fail "the run waits while another holds the pack slot"
  assert_equals "" "$(cat "$H.log")" "no admission is asked while the slot is held"
  assert_equals "$a" "$(ino "$H/data/a")" "nothing is rewritten while the slot is held"
  exec 5>&-
  wait "$pid" || rc=$?
  out=$(cat "$H.out")
  expect_code 0 "$rc" "the run once the slot is free: $out"
  assert_contains "$out" "repacked 1 files" "the run goes on once the slot is free"
  assert_not_equals "$a" "$(ino "$H/data/a")" "the file was rewritten"
  assert_equals held "$(cat "$H.slot.probe")" "the slot stays held while the batch copies"
  pass "a run waits for the machine-wide pack slot and holds it through its batch"
}

test_plan() {
  local out f sample m c per
  H=$(new_home plan)
  f="$H/data/p"
  cold "$f" 8192
  cold "$H/data/young" 5000 1
  printf 'data\n' >"$H/config/repack-trees"
  out=$(repack plan) || fail "plan exits 0: $out"
  assert_contains "$out" "tree $H/data: 1 files, 8192 bytes (0.00 GiB); MiBs emptied unknown" "the tree line without a sample"
  assert_contains "$out" "all trees, one batch: 1 files, 8192 bytes" "the joint line"
  assert_contains "$out" "skipped: young 1" "the skip line"
  assert_absent "$H/state/fm-repack" "plan writes no state"
  sync
  sample=$(python3 - "$f" <<'PY'
import fcntl, os, struct, sys
fd = os.open(sys.argv[1], os.O_RDONLY)
bs = os.statvfs(sys.argv[1]).f_frsize
buf = bytearray(struct.pack("=QQIIII", 0, 2**64 - 1, 1, 0, 8, 0) + bytes(56 * 8))
try:
    fcntl.ioctl(fd, 0xC020660B, buf, True)
except OSError:
    sys.exit(0)
if struct.unpack_from("=I", buf, 20)[0] < 1:
    sys.exit(0)
ph, ln = struct.unpack_from("=QQQ", buf, 32)[1:3]
per = (1 << 20) // bs
b0, b1 = ph // bs, (ph + ln + bs - 1) // bs
m = b0 // per
print(m, min(b1, (m + 1) * per) - b0, per)
PY
)
  if [ -z "$sample" ]; then
    pass "plan prints per-tree and joint lines (no extent map here, so the sample case is skipped)"
    return 0
  fi
  read -r m c per <<<"$sample"
  {
    echo "00:00:00 bitmaps read: 1000 partly used 1 MiB blocks, 2 sampled"
    echo "00:00:01 sample block $((m * per)) mib $m holes $((per - c)) inode 12"
    echo "00:00:01 sample block $(((m + 7) * per)) mib $((m + 7)) holes 100 inode 13"
  } >"$TMP_ROOT/sample.out"
  out=$(repack plan --sample "$TMP_ROOT/sample.out") || fail "plan with a sample exits 0: $out"
  assert_contains "$out" "tree $H/data: 1 files, 8192 bytes (0.00 GiB); MiBs emptied ~500 (95% CI " \
    "the estimate scales the sampled MiBs the file fills"
  assert_contains "$out" "1 of 2 sampled), 0.49 GiB; holes cleared" "the estimate counts the sampled MiB the file fills"
  assert_contains "$out" "(2 of 1000 partly used MiBs, taken " "the sample and its age are named"
  pass "plan prints per-tree and joint lines, with the F1 estimate from a block sample"
}

test_nothing_to_do
test_refusals
test_rewrite_keeps_content_and_metadata
test_rerun_is_noop
test_skip_classes
test_changed_during_copy
test_crash_before_swap_keeps_original
test_crash_after_swap_keeps_copy
test_admission_refusal_holds_batch
test_one_batch_in_time_order
test_lock_and_baseline
test_pack_slot_waits_and_holds
test_plan
