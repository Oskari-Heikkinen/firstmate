#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2016
# Behavior tests for bin/fm-pack.sh (docs/storage.md "Packing cold data").
#
# Every case packs a small fixture tree into a plain directory standing in for
# the D: publication, behind the same PATH-shimmed df and stat that
# tests/fm-disk-room.test.sh uses, so nothing touches real drives or data.
# The member check runs through FM_PACK_MOUNT=unsquashfs; the default
# squashfuse mount path runs only where /dev/fuse can actually mount, and is
# skipped elsewhere.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

for tool in mksquashfs unsquashfs jq sha256sum; do
  command -v "$tool" >/dev/null 2>&1 || { echo "skip: $tool is not installed"; exit 0; }
done

unset FM_DISK_ROOM_VHDX FM_DISK_ROOM_DEV_SIZE FM_DISK_ROOM_MARGIN FM_DISK_ROOM_NOW FM_DISK_ROOM_STATE \
  FM_DISK_ROOM_WEVTUTIL FM_DISK_ROOM_POWERSHELL FM_DISK_ROOM_RESULTS_ROOT FM_DISK_ROOM_SAMPLES \
  FM_DISK_ROOM_C_FREE_MIN FM_DISK_ROOM_D_FREE_MIN FM_DISK_ROOM_BULK_MARGIN FM_STORAGE_MNT FM_STORAGE_CONFIG \
  FM_STORAGE_MOUNTINFO FM_STORAGE_RESULTS_ROOT FM_PACK_MOUNT FM_PACK_TEST_BEFORE_RECHECK
TMP_ROOT=$(fm_test_tmproot fm-pack)
PACK="$ROOT/bin/fm-pack.sh"
GIB=1073741824
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
DFDIR="$TMP_ROOT/df"
HOSTDIR="$TMP_ROOT/c"
LINUXDIR="$TMP_ROOT/root"
CFG="$TMP_ROOT/storage"
MP="$TMP_ROOT/mnt/d"
R="$MP/lattice-data/tetjet-results/job"
SRC="$TMP_ROOT/src/unit-a"
mkdir -p "$DFDIR" "$HOSTDIR" "$LINUXDIR" "$CFG" "$MP/lattice-data/tetjet-results"

cat >"$FAKEBIN/df" <<'SH'
#!/usr/bin/env bash
# df -B1 --output=FIELD -- PATH: sizes come from $FAKE_DF/<path with / as _>.<field>
field='' path=''
for a in "$@"; do
  case "$a" in
    --output=*) field=${a#--output=} ;;
    -*) ;;
    *) path=$a ;;
  esac
done
f="$FAKE_DF/$(printf '%s' "$path" | tr / _).$field"
[ -r "$f" ] || { echo "df: $path: No such file or directory" >&2; exit 1; }
printf '%s\n' "$field"
cat "$f"
SH
chmod +x "$FAKEBIN/df"
cat >"$FAKEBIN/stat" <<SH
#!/usr/bin/env bash
if [ "\$1 \$2" = '-c %d' ]; then
  case "\${!#}" in "\$FAKE_BULK_MNT/d"|"\$FAKE_BULK_MNT/d/"*) printf '%s\\n' 999; exit ;; esac
fi
exec $(command -v stat) "\$@"
SH
chmod +x "$FAKEBIN/stat"

key() { printf '%s' "$1" | tr / _; }

# set_linux_free BYTES: Linux root free space as df reports it.
set_linux_free() { printf '%s\n' "$1" >"$DFDIR/$(key "$LINUXDIR").avail"; }

printf '%s\n' $((60 * GIB)) >"$DFDIR/$(key "$HOSTDIR").avail"
printf '%s\n' $((400 * GIB)) >"$DFDIR/$(key "$LINUXDIR").used"
printf '%s\n' $((1000 * GIB)) >"$DFDIR/$(key "$LINUXDIR").size"
set_linux_free $((600 * GIB))
printf '%s\n' $((100 * GIB)) >"$DFDIR/$(key "$MP/lattice-data/tetjet-results").avail"

publish_d() {
  printf 'volume-d\n' >"$MP/lattice-data/.lattice-storage-id"
  printf 'uniqueid=volume-d\n' >"$CFG/ssd-identity"
  printf '1 2 0:1 / %s rw - 9p D: rw\n' "$MP" >"$TMP_ROOT/mountinfo"
  printf '%s/lattice-data/tetjet-results/{task}\nformat=lattice-storage-results-root/v1\nactive=ssd\nstate=ok\nssd_letter=D\nssd_fs=exFAT\nssd_id=volume-d\nssd_marker=%s/lattice-data/.lattice-storage-id\nssd_device=999\nchecked_at=%s\n' \
    "$MP" "$MP" "$(date +%s)" >"$CFG/results-root"
}

run_pack() {
  PATH="$FAKEBIN:$PATH" FAKE_DF="$DFDIR" FAKE_BULK_MNT="$TMP_ROOT/mnt" \
    FM_STORAGE_CONFIG="$CFG" FM_STORAGE_MNT="$TMP_ROOT/mnt" FM_STORAGE_MOUNTINFO="$TMP_ROOT/mountinfo" \
    FM_DISK_ROOM_STATE="$TMP_ROOT/state" FM_DISK_ROOM_RESULTS_ROOT="$CFG/results-root" \
    FM_DISK_ROOM_HOST="$HOSTDIR" FM_DISK_ROOM_ROOT="$LINUXDIR" FM_DISK_ROOM_POWERSHELL='' FM_DISK_ROOM_WEVTUTIL='' \
    FM_DISK_ROOM_SAMPLES="$TMP_ROOT/no-samples" FM_DISK_ROOM_C_FREE_MIN=off FM_DISK_ROOM_MB_GROUPS="$TMP_ROOT/no-mb-groups" \
    FM_DISK_ROOM_VHDX="$TMP_ROOT/no-vhdx" FM_DISK_ROOM_DEV_SIZE=$((1000 * GIB)) FM_DISK_ROOM_MARGIN=1G \
    FM_DISK_ROOM_BULK_MARGIN=1G FM_PACK_MOUNT="${FM_PACK_MOUNT-unsquashfs}" FM_HOME="$TMP_ROOT/home" \
    bash "$PACK" "$@"
}

# make_src DIR: six regular files (one empty, one with a space, a hard-linked
# pair, and one also linked from outside DIR), plus a symlink and a nested dir.
make_src() {
  mkdir -p "$1/nested/deep"
  printf 'hello world' >"$1/nested/deep/file.txt"
  : >"$1/empty"
  ln -s nested/deep/file.txt "$1/link"
  printf 'abcd' >"$1/with space.txt"
  head -c 3000 /dev/zero | tr '\0' a >"$1/hl1"
  ln "$1/hl1" "$1/hl2"
  head -c 5000 /dev/zero | tr '\0' b >"$1/shared"
  ln "$1/shared" "$TMP_ROOT/outside-$(basename "$1")"
}

snapshot() { (cd "$1" && find . -printf '%y %s %m %n %T@ %l %p\n' | LC_ALL=C sort && find . -type f -exec sha256sum {} + | LC_ALL=C sort); }

pack_reservations() { find "$TMP_ROOT/state" -path '*reservations-d*' -name '*pack-*' 2>/dev/null; }

receipt_field() { printf '%s\n' "$1" | tr ' ' '\n' | sed -n "s/^$2=//p"; }

make_src "$SRC"
SNAP=$(snapshot "$SRC")

test_no_publication_waits() {
  local out rc
  out=$(run_pack pack job unit-a "$SRC" 2>&1); rc=$?
  expect_code 75 "$rc" "no D: publication is a wait"
  assert_absent "$R" "a refused pack writes nothing on D:"
  assert_equals "" "$(pack_reservations)" "a refused pack holds no reservation"
  assert_equals "$SNAP" "$(snapshot "$SRC")" "the source is untouched"
  pass "pack waits with 75 and writes nothing when D: is not published"
}

test_pack_round_trip() {
  local out rc img json now
  publish_d
  out=$(run_pack pack job unit-a "$SRC"); rc=$?
  expect_code 0 "$rc" "pack commits"
  img="$R/unit-a.sqfs" json="$R/unit-a.json"
  assert_equals 1 "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" "pack prints one line"
  assert_contains "$out" "fm-pack-receipt/v1 image=$img " "receipt names the image"
  assert_equals 6 "$(receipt_field "$out" files)" "six regular files"
  assert_equals 11015 "$(receipt_field "$out" logical)" "logical bytes count every link"
  assert_equals 3015 "$(receipt_field "$out" frees)" "frees skips a file linked from outside and counts a pair once"
  assert_equals "$json" "$(receipt_field "$out" sidecar)" "receipt names the sidecar"
  assert_equals "$(cut -d' ' -f1 <"$R/unit-a.sqfs.sha256")" "$(receipt_field "$out" sha256)" "receipt sha256 is the image's"
  assert_equals "$(sha256sum <"$img" | cut -d' ' -f1)" "$(receipt_field "$out" sha256)" "the sha256 file matches the image"
  for f in sqfs.sha256 members.sha256 tree.tsv json; do assert_present "$R/unit-a.$f" "sidecar $f committed"; done
  assert_absent "$R/.incoming" "no staging left"
  assert_equals 6 "$(wc -l <"$R/unit-a.members.sha256" | tr -d ' ')" "members list has six lines"
  assert_equals fm-pack-unit/v1 "$(jq -r .format "$json")" "sidecar format"
  assert_equals unit-a "$(jq -r .dir "$json")" "sidecar records the directory name"
  assert_equals "$TMP_ROOT/home" "$(jq -r .owner_home "$json")" "sidecar records the owner home"
  assert_equals "$(receipt_field "$out" verified_at)" "$(jq -r .verified_at "$json")" "sidecar verified_at matches the receipt"
  now=$(date +%s)
  [ "$(jq -r .packed_at "$json")" -le "$(jq -r .verified_at "$json")" ] && [ "$(jq -r .verified_at "$json")" -le "$now" ] ||
    fail "packed_at <= verified_at <= now"
  assert_equals unsquashfs "$(jq -r .verify_method "$json")" "sidecar names the verify path"
  assert_equals "" "$(pack_reservations)" "the pack reservation is released"
  assert_contains "$(unsquashfs -lls "$img")" "squashfs-root/unit-a/link -> nested/deep/file.txt" "the image keeps the symlink"
  out=$(run_pack verify "$img"); rc=$?
  expect_code 0 "$rc" "verify passes"
  assert_contains "$out" "verified $img (6 files, unsquashfs)" "verify names the count and path"
  out=$(run_pack verify "$img" --against "$SRC"); rc=$?
  expect_code 0 "$rc" "verify --against an unchanged source passes"
  assert_contains "$out" "source unchanged" "verify --against says so"
  assert_equals "$SNAP" "$(snapshot "$SRC")" "the source is untouched"
  pass "pack commits a verified image with its sidecars and one receipt line"
}

test_against_changed_source() {
  local out rc copy="$TMP_ROOT/changed/unit-a"
  mkdir -p "$TMP_ROOT/changed"
  cp -a "$SRC" "$copy"
  printf 'more' >>"$copy/with space.txt"
  out=$(run_pack verify "$R/unit-a.sqfs" --against "$copy" 2>&1); rc=$?
  expect_code 1 "$rc" "verify --against a changed source fails"
  assert_contains "$out" "no longer matches" "the failure names the tree list"
  pass "verify --against refuses a source that changed after packing"
}

test_source_change_refuses() {
  local out rc src_b="$TMP_ROOT/src/unit-b" snap_b
  make_src "$src_b"
  snap_b=$(snapshot "$src_b")
  out=$(FM_PACK_TEST_BEFORE_RECHECK="touch -d @1 '$src_b/empty'" run_pack pack job unit-b "$src_b" 2>&1); rc=$?
  expect_code 1 "$rc" "a source change during the pack refuses"
  assert_contains "$out" "changed while it was packed" "the refusal names the change"
  for f in sqfs sqfs.sha256 members.sha256 tree.tsv json; do assert_absent "$R/unit-b.$f" "nothing committed: $f"; done
  assert_absent "$R/.incoming" "this run's staging is removed"
  assert_equals "" "$(pack_reservations)" "the reservation is released on refusal"
  assert_present "$R/unit-a.sqfs" "an earlier unit is untouched"
  assert_equals "$SNAP" "$(snapshot "$SRC")" "the other source is untouched"
  [ "$snap_b" != "$(snapshot "$src_b")" ] || fail "the hook changed unit-b"
  pass "pack refuses with 1 and commits nothing when the source changes"
}

# tamper_copy NAME: a copy of unit-a's image and sidecars under NAME/.
tamper_copy() {
  local d="$TMP_ROOT/$1" f
  mkdir -p "$d"
  for f in sqfs sqfs.sha256 members.sha256 tree.tsv json; do cp "$R/unit-a.$f" "$d/unit-a.$f"; done
  printf '%s\n' "$d"
}

# flip_first_hash FILE: change the first hex digit of FILE's first line.
flip_first_hash() { sed -i '1s/^0/1/;t;1s/^./0/' "$1"; }

test_tampering_fails_verify() {
  local out rc d size
  d=$(tamper_copy flipped)
  size=$(stat -c %s "$d/unit-a.sqfs")
  printf '\377' | dd of="$d/unit-a.sqfs" bs=1 seek=$((size / 2)) conv=notrunc status=none
  out=$(run_pack verify "$d/unit-a.sqfs" 2>&1); rc=$?
  expect_code 1 "$rc" "a flipped image byte fails verify"
  assert_contains "$out" "does not match" "the failure names the image sha256"
  d=$(tamper_copy edited)
  flip_first_hash "$d/unit-a.members.sha256"
  out=$(run_pack verify "$d/unit-a.sqfs" 2>&1); rc=$?
  expect_code 1 "$rc" "an edited members line fails verify"
  assert_contains "$out" "FAILED" "the failure names the member"
  d=$(tamper_copy short)
  sed -i '$d' "$d/unit-a.members.sha256"
  out=$(run_pack verify "$d/unit-a.sqfs" 2>&1); rc=$?
  expect_code 1 "$rc" "a members list missing a file fails verify"
  pass "verify fails on a changed image byte or members list"
}

test_repack_refuses() {
  local out rc before
  before=$(sha256sum <"$R/unit-a.sqfs")
  out=$(run_pack pack job unit-a "$SRC" 2>&1); rc=$?
  expect_code 2 "$rc" "packing an existing unit is misuse"
  assert_contains "$out" "never overwritten" "the refusal says why"
  assert_equals "$before" "$(sha256sum <"$R/unit-a.sqfs")" "the image is unchanged"
  assert_equals "" "$(pack_reservations)" "the reservation is released"
  out=$(run_pack pack job ../escape "$SRC" 2>&1); rc=$?
  expect_code 2 "$rc" "a unit name with a slash is misuse"
  assert_equals "$SNAP" "$(snapshot "$SRC")" "the source is untouched"
  pass "pack never overwrites a unit"
}

# no_fuse_path: a PATH dir holding only what pack and verify need before the
# reader check, so squashfuse and fusermount3 are missing.
no_fuse_path() {
  local d="$TMP_ROOT/no-fuse-bin" t
  mkdir -p "$d"
  for t in bash dirname mksquashfs unsquashfs sha256sum jq; do ln -sf "$(command -v "$t")" "$d/$t"; done
  printf '%s\n' "$d"
}

test_reader_mode_refuses() {
  local out rc nofuse mode
  nofuse=$(no_fuse_path)
  out=$(FM_PACK_MOUNT='' PATH="$nofuse" run_pack pack job unit-n "$SRC" 2>&1); rc=$?
  expect_code 2 "$rc" "pack without a usable FUSE mount in the default mode is refused"
  assert_contains "$out" "no usable FUSE mount" "the refusal names the missing mount"
  out=$(FM_PACK_MOUNT='' PATH="$nofuse" run_pack verify "$R/unit-a.sqfs" 2>&1); rc=$?
  expect_code 2 "$rc" "verify without a usable FUSE mount in the default mode is refused"
  assert_contains "$out" "no usable FUSE mount" "the verify refusal names the missing mount"
  for mode in on off auto; do
    out=$(FM_PACK_MOUNT=$mode run_pack pack job unit-n "$SRC" 2>&1); rc=$?
    expect_code 2 "$rc" "pack with FM_PACK_MOUNT=$mode is misuse"
    assert_contains "$out" "FM_PACK_MOUNT must be mount or unsquashfs" "the refusal names the variable"
    out=$(FM_PACK_MOUNT=$mode run_pack verify "$R/unit-a.sqfs" 2>&1); rc=$?
    expect_code 2 "$rc" "verify with FM_PACK_MOUNT=$mode is misuse"
    out=$(FM_PACK_MOUNT=$mode run_pack restore "$R/unit-a.sqfs" "$TMP_ROOT/restore-$mode" 2>&1); rc=$?
    expect_code 2 "$rc" "restore with FM_PACK_MOUNT=$mode is misuse"
    assert_absent "$TMP_ROOT/restore-$mode" "a misused restore writes nothing"
  done
  for f in sqfs sqfs.sha256 members.sha256 tree.tsv json; do assert_absent "$R/unit-n.$f" "nothing written: $f"; done
  assert_absent "$R/.incoming" "no staging created"
  assert_equals "" "$(pack_reservations)" "no reservation is held"
  assert_equals "$SNAP" "$(snapshot "$SRC")" "the source is untouched"
  pass "pack and verify refuse with 2 before any work on an unknown or unusable reader"
}

test_root_overlap_refuses() {
  local out rc before parent="$MP/lattice-data/tetjet-results" stage="$R/.incoming/inner"
  before=$(snapshot "$parent")
  out=$(run_pack pack job job-raw "$R" 2>&1); rc=$?
  expect_code 2 "$rc" "packing the task's own results root is refused"
  assert_contains "$out" "the D: root $R is $R or inside it" "the refusal names both paths"
  out=$(run_pack pack job job-up "$parent" 2>&1); rc=$?
  expect_code 2 "$rc" "packing a tree that holds the results root is refused"
  assert_contains "$out" "the D: root $R is $parent or inside it" "the refusal names both paths"
  assert_equals "$before" "$(snapshot "$parent")" "a refused overlap writes nothing on D:"
  assert_equals "" "$(pack_reservations)" "no reservation is held"
  mkdir -p "$stage"
  printf 'x' >"$stage/f"
  out=$(run_pack pack job job-in "$stage" 2>&1); rc=$?
  expect_code 2 "$rc" "packing a tree inside the staging is refused"
  assert_contains "$out" "$stage is inside the staging of the D: root $R" "the refusal names both paths"
  assert_equals "" "$(pack_reservations)" "no reservation is held"
  assert_equals x "$(cat "$stage/f")" "the staged source is untouched"
  rm -rf "$R/.incoming"
  pass "pack refuses with 2 when the D: root and SRC overlap"
}

test_restore() {
  local out rc dest="$TMP_ROOT/restored"
  out=$(run_pack restore "$R/unit-a.sqfs" "$dest" 2>&1); rc=$?
  expect_code 0 "$rc" "restore succeeds"
  assert_contains "$out" "checked 6 files" "restore checks every member"
  assert_equals "$(cd "$SRC" && find . -type f -exec sha256sum {} + | LC_ALL=C sort)" \
    "$(cd "$dest/unit-a" && find . -type f -exec sha256sum {} + | LC_ALL=C sort)" "restored contents match"
  assert_equals nested/deep/file.txt "$(readlink "$dest/unit-a/link")" "the symlink is restored"
  assert_equals "$(stat -c %i "$dest/unit-a/hl1")" "$(stat -c %i "$dest/unit-a/hl2")" "the hard-linked pair is restored"
  out=$(run_pack restore "$R/unit-a.sqfs" "$dest" 2>&1); rc=$?
  expect_code 2 "$rc" "restore never writes into an existing path"
  set_linux_free "$GIB"
  out=$(run_pack restore "$R/unit-a.sqfs" "$TMP_ROOT/low" 2>&1); rc=$?
  set_linux_free $((600 * GIB))
  expect_code 75 "$rc" "restore with no Linux room is refused"
  assert_contains "$out" "refused restore-unit-a" "the refusal names the job"
  assert_absent "$TMP_ROOT/low" "a refused restore writes nothing"
  assert_equals "$SNAP" "$(snapshot "$SRC")" "the source is untouched"
  pass "restore unpacks and checks the unit, and waits for room"
}

test_mount_verify() {
  local probe out rc d
  probe=$(mktemp -d "$TMP_ROOT/probe.XXXXXX")
  if ! command -v squashfuse >/dev/null 2>&1 || ! command -v fusermount3 >/dev/null 2>&1 ||
    ! squashfuse -o ro "$R/unit-a.sqfs" "$probe" 2>/dev/null; then
    echo "skip: no usable squashfuse mount here; the unsquashfs path covers verify"
    return 0
  fi
  fusermount3 -u "$probe"
  out=$(FM_PACK_MOUNT='' run_pack verify "$R/unit-a.sqfs" --against "$SRC"); rc=$?
  expect_code 0 "$rc" "verify through a fresh mount passes"
  assert_contains "$out" "(6 files, mount), source unchanged" "verify names the mount path"
  d=$(tamper_copy mount-edited)
  flip_first_hash "$d/unit-a.members.sha256"
  out=$(FM_PACK_MOUNT='' run_pack verify "$d/unit-a.sqfs" 2>&1); rc=$?
  expect_code 1 "$rc" "an edited members line fails the mount verify"
  assert_equals "" "$(grep fm-pack-verify /proc/self/mounts)" "no verify mount is left behind"
  pass "verify reads the image through a fresh squashfuse mount"
}

SRC_R="$TMP_ROOT/src/unit-r"
IMG_R="$R/unit-r.sqfs"
ASIDE_R="$TMP_ROOT/src/.unit-r.fm-pack-release"
OUT_R="$TMP_ROOT/outside-unit-r"
SNAP_R=''

test_release_setup() {
  local out rc
  make_src "$SRC_R"
  out=$(run_pack pack job unit-r "$SRC_R"); rc=$?
  expect_code 0 "$rc" "the release fixture packs"
  SNAP_R=$(snapshot "$SRC_R")
}

# expect_release_refused CODE WHY PATTERN ARGS...: releasing unit-r with ARGS
# exits CODE naming PATTERN and deletes nothing.
expect_release_refused() {
  local code=$1 why=$2 pattern=$3 out rc
  shift 3
  out=$(run_pack release "$IMG_R" "$SRC_R" "$@" 2>&1); rc=$?
  expect_code "$code" "$rc" "$why"
  assert_contains "$out" "$pattern" "$why: the refusal says why"
  assert_equals "$SNAP_R" "$(snapshot "$SRC_R")" "$why: the source is untouched"
  assert_present "$OUT_R" "$why: the outside name is untouched"
  assert_absent "$R/unit-r.release.json" "$why: no release record"
  assert_absent "$ASIDE_R" "$why: no aside left"
}

# wait_link LINK TARGET: wait up to 5 s until the symlink LINK reads TARGET.
wait_link() {
  local _
  for _ in $(seq 50); do
    [ "$(readlink "$1" 2>/dev/null)" = "$2" ] && return 0
    sleep 0.1
  done
  fail "$1 never pointed at $2"
}

test_release_refusals() {
  local also=(--also "$OUT_R") ok=(--accepted-by tetjet-mate --also "$OUT_R") out rc copy d pid m
  expect_release_refused 2 "a release without acceptance" "no acceptance, no release" "${also[@]}"
  expect_release_refused 2 "an acceptance that is not a name" "--accepted-by must be" --accepted-by 'two words' "${also[@]}"
  expect_release_refused 2 "a window that is not seconds" "whole seconds" "${ok[@]}" --window 7d

  copy="$TMP_ROOT/copy/unit-r"
  mkdir -p "$TMP_ROOT/copy"
  cp -a "$SRC_R" "$copy"
  out=$(run_pack release "$IMG_R" "$copy" "${ok[@]}" 2>&1); rc=$?
  expect_code 2 "$rc" "releasing a copy of the source is misuse"
  assert_contains "$out" "is not the source" "the refusal names the recorded source"
  assert_present "$copy/hl1" "the copy is untouched"

  expect_release_refused 75 "a window not yet passed" "release window of 604800 s ends at" "${ok[@]}" --window 604800
  FM_PACK_RELEASE_WINDOW=604800 expect_release_refused 75 "a configured window not yet passed" "release window of 604800 s" "${ok[@]}"
  assert_contains "$(tail -n1 "$R/fm-pack-release.log")" "waits unit-r $SRC_R" "the wait is logged"

  printf 'tree: %s\n' "$SRC_R" >"$TMP_ROOT/ledger.txt"
  expect_release_refused 1 "a ledger that still names the source" "$TMP_ROOT/ledger.txt still names $SRC_R" \
    "${ok[@]}" --ref "$TMP_ROOT/ledger.txt"
  assert_contains "$(tail -n1 "$R/fm-pack-release.log")" "refused unit-r $SRC_R" "the refusal is logged"
  expect_release_refused 2 "an unreadable reference" "is not a readable file" "${ok[@]}" --ref "$TMP_ROOT/no-ledger"

  printf '36 1 0:5 / %s rw - tmpfs tmpfs rw\n' "$SRC_R/nested" >"$TMP_ROOT/mountinfo-r"
  FM_PACK_MOUNTINFO="$TMP_ROOT/mountinfo-r" expect_release_refused 1 "a mount inside the source" \
    "$SRC_R/nested is a mount point" "${ok[@]}"

  (cd "$SRC_R/nested" && exec sleep 30) &
  pid=$!
  wait_link "/proc/$pid/cwd" "$SRC_R/nested"
  expect_release_refused 1 "a process working in the source" "process $pid (sleep) uses $SRC_R/nested" "${ok[@]}"
  kill "$pid"; wait "$pid" 2>/dev/null
  (exec 3<"$SRC_R/with space.txt" && exec sleep 30) &
  pid=$!
  wait_link "/proc/$pid/fd/3" "$SRC_R/with space.txt"
  expect_release_refused 1 "a file open in the source" "uses $SRC_R/with space.txt" "${ok[@]}"
  kill "$pid"; wait "$pid" 2>/dev/null
  (exec 3<"$OUT_R" && exec sleep 30) &
  pid=$!
  wait_link "/proc/$pid/fd/3" "$OUT_R"
  expect_release_refused 1 "an open --also name" "uses $OUT_R" "${ok[@]}"
  kill "$pid"; wait "$pid" 2>/dev/null

  mkdir -p "$TMP_ROOT/state/reservations" "$TMP_ROOT/state/reservations-d/999"
  printf 'bytes=1\nexpires=%s\n' $(( $(date +%s) + 3600 )) >"$TMP_ROOT/state/reservations/unit-r"
  expect_release_refused 1 "a live Linux reservation named for the unit" "reservations/unit-r is live" "${ok[@]}"
  printf 'bytes=1\nexpires=1\n' >"$TMP_ROOT/state/reservations/unit-r"
  printf 'bytes=1\npid=%s\n' "$$" >"$TMP_ROOT/state/reservations-d/999/pack-unit-r"
  expect_release_refused 1 "a live D: reservation for the unit's pack" "reservations-d/999/pack-unit-r is live" "${ok[@]}"
  rm -f "$TMP_ROOT/state/reservations-d/999/pack-unit-r"

  expect_release_refused 1 "a hard link left outside the source" \
    "$SRC_R/shared has 1 more hard-link name(s) outside $SRC_R" --accepted-by tetjet-mate
  expect_release_refused 2 "an --also that is no link of the source" "is not a link of a file in" \
    "${ok[@]}" --also "$TMP_ROOT/ledger.txt"
  expect_release_refused 2 "an --also inside the source" "is inside $SRC_R" "${ok[@]}" --also "$SRC_R/hl2"

  d="$TMP_ROOT/flipped-r"
  mkdir -p "$d"
  for f in sqfs sqfs.sha256 members.sha256 tree.tsv json; do cp "$R/unit-r.$f" "$d/unit-r.$f"; done
  printf '\377' | dd of="$d/unit-r.sqfs" bs=1 seek=$(( $(stat -c %s "$d/unit-r.sqfs") / 2 )) conv=notrunc status=none
  out=$(run_pack release "$d/unit-r.sqfs" "$SRC_R" "${ok[@]}" 2>&1); rc=$?
  expect_code 1 "$rc" "an image that fails verify refuses the release"
  assert_contains "$out" "does not match" "the refusal names the image sha256"
  assert_absent "$d/unit-r.release.json" "no release record for the failed image"
  assert_equals "$SNAP_R" "$(snapshot "$SRC_R")" "the source is untouched after a failed verify"

  m=$(find "$SRC_R/empty" -printf '%T@')
  touch -d @1 "$SRC_R/empty"
  out=$(run_pack release "$IMG_R" "$SRC_R" "${ok[@]}" 2>&1); rc=$?
  touch -d "@$m" "$SRC_R/empty"
  expect_code 1 "$rc" "a changed source refuses the release"
  assert_contains "$out" "no longer matches unit-r.tree.tsv" "the refusal names the tree list"
  assert_equals "$SNAP_R" "$(snapshot "$SRC_R")" "the source is back as it was"

  out=$(FM_PACK_TEST_BEFORE_RECHECK="touch -d @1 '$ASIDE_R/empty'" run_pack release "$IMG_R" "$SRC_R" "${ok[@]}" 2>&1); rc=$?
  expect_code 1 "$rc" "a change while renamed aside refuses the release"
  assert_contains "$out" "changed while it was renamed aside" "the refusal names the aside re-check"
  assert_present "$SRC_R/hl1" "the source is renamed back after the aside re-check"
  assert_absent "$ASIDE_R" "no aside is left after the aside re-check"
  assert_absent "$R/unit-r.release.json" "the pending record is removed after the aside re-check"
  touch -d "@$m" "$SRC_R/empty"
  assert_equals "$SNAP_R" "$(snapshot "$SRC_R")" "the renamed-back source is whole"
  pass "release refuses on every guard and deletes nothing"
}

test_release() {
  local out rc rec="$R/unit-r.release.json"
  printf 'tree: %s\n' "$TMP_ROOT/src/unit-other" >"$TMP_ROOT/ledger-clean.txt"
  out=$(run_pack release "$IMG_R" "$SRC_R" --accepted-by tetjet-mate --note 'the ledger reads the image' \
    --ref "$TMP_ROOT/ledger-clean.txt" --also "$OUT_R"); rc=$?
  expect_code 0 "$rc" "release succeeds when every guard holds"
  assert_equals 1 "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" "release prints one line"
  assert_contains "$out" "fm-pack-release/v1 image=$IMG_R src=$SRC_R " "the receipt names the image and source"
  assert_equals 8015 "$(receipt_field "$out" freed)" "freed counts each inode once, the outside name included"
  assert_equals tetjet-mate "$(receipt_field "$out" accepted_by)" "the receipt names who accepted"
  assert_equals "$rec" "$(receipt_field "$out" record)" "the receipt names the record"
  assert_equals fm-pack-release/v1 "$(jq -r .format "$rec")" "record format"
  assert_equals released "$(jq -r .state "$rec")" "the record says released"
  assert_equals 8015 "$(jq -r .freed_bytes "$rec")" "the record keeps the freed bytes"
  assert_equals 6 "$(jq -r .files "$rec")" "the record keeps the file count"
  assert_equals "the ledger reads the image" "$(jq -r .note "$rec")" "the record keeps the acceptance note"
  assert_equals "$OUT_R" "$(jq -r '.also[0]' "$rec")" "the record names the released outside name"
  assert_equals 0 "$(jq -r .window_seconds "$rec")" "the default window is zero"
  assert_equals "$(receipt_field "$out" released_at)" "$(jq -r .released_at "$rec")" "record and receipt agree on released_at"
  assert_equals STORED.md "$(ls -A "$SRC_R")" "only the stub is left at the source"
  assert_contains "$(cat "$SRC_R/STORED.md")" "image: $IMG_R" "the stub names the image"
  assert_absent "$OUT_R" "the outside name is released too"
  assert_absent "$ASIDE_R" "no aside is left"
  assert_contains "$(tail -n1 "$R/fm-pack-release.log")" "released unit-r $SRC_R: freed 8015 bytes" "the release is logged"
  out=$(run_pack verify "$IMG_R"); rc=$?
  expect_code 0 "$rc" "the image still verifies after the release"
  out=$(run_pack release "$IMG_R" "$SRC_R" --accepted-by tetjet-mate 2>&1); rc=$?
  expect_code 2 "$rc" "a second release is misuse"
  assert_contains "$out" "already released" "the second release says so"
  pass "release removes a verified, accepted source and leaves a receipt, a record and a stub"
}

test_no_publication_waits
test_pack_round_trip
test_against_changed_source
test_source_change_refuses
test_tampering_fails_verify
test_repack_refuses
test_reader_mode_refuses
test_root_overlap_refuses
test_restore
test_mount_verify
test_release_setup
test_release_refusals
test_release
