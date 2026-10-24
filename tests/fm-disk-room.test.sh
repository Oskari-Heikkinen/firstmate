#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2016
# Behavior tests for bin/fm-disk-room.sh (docs/disk-room.md).
#
# Every case runs against a PATH-shimmed df that reports fixture sizes for a
# fake Windows drive and a fake Linux root, a sparse VHDX fixture with a known
# block table standing in for ext4.vhdx, a fixture ext4 mb_groups table, a
# stub wevtutil that prints fixture volsnap events, and a stub powershell that
# prints a fixture shadow storage reading, so nothing reads the real disk, the
# Windows log or WMI.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

unset FM_DISK_ROOM_VHDX FM_DISK_ROOM_DEV_SIZE FM_DISK_ROOM_MARGIN FM_DISK_ROOM_NOW FM_DISK_ROOM_COMPACT_RESULT FM_DISK_ROOM_STATE \
  FM_DISK_ROOM_SHADOW_RECORD FM_DISK_ROOM_SHADOW_MAX FM_DISK_ROOM_WEVTUTIL FM_DISK_ROOM_POWERSHELL FM_DISK_ROOM_RESULTS_ROOT \
  FM_DISK_ROOM_SAMPLES FM_DISK_ROOM_GROWTH_MAX FM_DISK_ROOM_C_FREE_MIN FM_DISK_ROOM_D_FREE_MIN FM_STORAGE_MNT \
  FM_DISK_ROOM_WSLCONFIG FM_DISK_ROOM_MEMINFO FM_DISK_ROOM_WRITE_PROC FM_CONFIG_OVERRIDE FM_INHERITABLE_CONFIG
TMP_ROOT=$(fm_test_tmproot fm-disk-room)
DISK_ROOM="$ROOT/bin/fm-disk-room.sh"
GIB=1073741824
LINUX_SIZE=0
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
DFDIR="$TMP_ROOT/df"
HOSTDIR="$TMP_ROOT/c"
LINUXDIR="$TMP_ROOT/root"
mkdir -p "$DFDIR" "$HOSTDIR/Users/u/AppData/Local/wsl/{g}" "$LINUXDIR"
VHDX="$HOSTDIR/Users/u/AppData/Local/wsl/{g}/ext4.vhdx"

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
  case "\${!#}" in "\$FAKE_BULK_MNT/d"|"\$FAKE_BULK_MNT/d/"*) printf '%s\\n' "\${FAKE_BULK_DEVICE:-999}"; exit ;; esac
fi
exec $(command -v stat) "\$@"
SH
chmod +x "$FAKEBIN/stat"

# wevtutil stub: prints $FAKE_EVENTS (an XML fixture) and counts its calls.
cat >"$FAKEBIN/wevtutil-stub" <<'SH'
#!/usr/bin/env bash
printf 'x\n' >>"$FAKE_EVENTS.calls"
[ -r "$FAKE_EVENTS" ] || exit 1
cat "$FAKE_EVENTS"
SH
chmod +x "$FAKEBIN/wevtutil-stub"
EVENTS="$TMP_ROOT/events.xml"

# powershell stub: prints $FAKE_SHADOW_LIVE (the live reading's lines) and
# counts its calls; without the fixture it fails like a timed-out call.
cat >"$FAKEBIN/powershell-stub" <<'SH'
#!/usr/bin/env bash
printf 'x\n' >>"$FAKE_SHADOW_LIVE.calls"
[ -r "$FAKE_SHADOW_LIVE" ] || exit 1
cat "$FAKE_SHADOW_LIVE"
SH
chmod +x "$FAKEBIN/powershell-stub"
SHADOW_LIVE="$TMP_ROOT/shadow-live.txt"

# write_shadow_live MAX_GIB ALLOCATED_GIB USED_GIB: what the live
# Win32_ShadowStorage reading prints, with Windows line endings.
write_shadow_live() {
  printf 'SHADOW|%s|%s|%s\r\nEND\r\n' $(( $1 * GIB )) $(( $2 * GIB )) $(( $3 * GIB )) >"$SHADOW_LIVE"
}

live_calls() { if [ -r "$SHADOW_LIVE.calls" ]; then wc -l <"$SHADOW_LIVE.calls" | tr -d ' '; else echo 0; fi; }

# write_events ID...: one volsnap event per id, as wevtutil /f:xml prints them.
write_events() {
  local id
  : >"$EVENTS"
  for id in "$@"; do
    printf '<Event xmlns="http://schemas.microsoft.com/win/2004/08/events/event"><System><Provider Name="volsnap"/><EventID Qualifiers="49158">%s</EventID></System></Event>\r\n' "$id" >>"$EVENTS"
  done
}

key() { printf '%s' "$1" | tr / _; }

# set_sizes HOST_FREE_GIB LINUX_FREE_GIB LINUX_USED_GIB: the Linux df total is
# free plus used, and the block device defaults to that size (no ext4 metadata).
set_sizes() {
  printf '%s\n' $(( $1 * GIB )) >"$DFDIR/$(key "$HOSTDIR").avail"
  printf '%s\n' $(( $2 * GIB )) >"$DFDIR/$(key "$LINUXDIR").avail"
  printf '%s\n' $(( $3 * GIB )) >"$DFDIR/$(key "$LINUXDIR").used"
  LINUX_SIZE=$(( ($2 + $3) * GIB ))
  printf '%s\n' "$LINUX_SIZE" >"$DFDIR/$(key "$LINUXDIR").size"
}

# mb_groups FRAG_GIB: one group per GiB of free 4 KiB blocks in 2^0 buddies
# (fragmented), plus one group of whole 1 MiB buddies that must not count.
write_mb_groups() {
  local i
  {
    printf '#group: free  frags first [ 2^0   2^1   2^2   2^3   2^4   2^5   2^6   2^7   2^8   2^9   2^10  2^11  2^12  2^13  ]\n'
    for ((i = 0; i < $1; i++)); do
      printf '#%d    : 262144 262144 0 [ 262144 0 0 0 0 0 0 0 0 0 0 0 0 0 ]\n' "$i"
    done
    printf '#%d    : 32768 1 0 [ 0 0 0 0 0 0 0 0 0 0 0 0 0 4 ]\n' "$1"
  } >"$TMP_ROOT/mb_groups"
}

# add_whole_groups FIRST COUNT: append COUNT mb_groups lines from group FIRST
# on, each wholly free (4 buddies of 2^13 4 KiB blocks, 128 MiB).
add_whole_groups() {
  local i
  for ((i = $1; i < $1 + $2; i++)); do
    printf '#%d    : 32768 1 0 [ 0 0 0 0 0 0 0 0 0 0 0 0 0 4 ]\n' "$i"
  done >>"$TMP_ROOT/mb_groups"
}

run_room() {
  FM_HOME="${TEST_FM_HOME-$TMP_ROOT/home-unset}" \
  PATH="$FAKEBIN:$PATH" FAKE_DF="$DFDIR" FAKE_BULK_MNT="$TMP_ROOT/mnt" \
    FM_STORAGE_CONFIG="$TMP_ROOT/storage" FM_STORAGE_MNT="$TMP_ROOT/mnt" \
    FM_STORAGE_MOUNTINFO="$TMP_ROOT/mountinfo" \
    FM_DISK_ROOM_HOST="${TEST_HOST-$HOSTDIR}" FM_DISK_ROOM_ROOT="$LINUXDIR" \
    FM_DISK_ROOM_MB_GROUPS="$TMP_ROOT/mb_groups" FM_DISK_ROOM_STATE="$TMP_ROOT/state" \
    FM_DISK_ROOM_DEV_SIZE="${TEST_DEV_SIZE-$LINUX_SIZE}" \
    FAKE_EVENTS="$EVENTS" FM_DISK_ROOM_WEVTUTIL="${FM_DISK_ROOM_WEVTUTIL-wevtutil-stub}" \
    FAKE_SHADOW_LIVE="$SHADOW_LIVE" FM_DISK_ROOM_POWERSHELL="${FM_DISK_ROOM_POWERSHELL-powershell-stub}" \
    FM_DISK_ROOM_RESULTS_ROOT="${FM_DISK_ROOM_RESULTS_ROOT-$TMP_ROOT/storage/results-root}" \
    FM_DISK_ROOM_SAMPLES="${TEST_SAMPLES-$TMP_ROOT/no-samples}" \
    FM_DISK_ROOM_C_FREE_MIN="${FM_DISK_ROOM_C_FREE_MIN-off}" \
    FM_DISK_ROOM_WSLCONFIG="${FM_DISK_ROOM_WSLCONFIG-}" FM_DISK_ROOM_MEMINFO="${FM_DISK_ROOM_MEMINFO-$TMP_ROOT/meminfo}" \
    FM_DISK_ROOM_BOOT_ID="${FM_DISK_ROOM_BOOT_ID-$TMP_ROOT/boot_id}" \
    ${TEST_SWAP_DISCOVER:+env -u FM_DISK_ROOM_WSLCONFIG} "${ROOM_CMD[@]}" "$@"
}
ROOM_CMD=("$DISK_ROOM")

json_field() { printf '%s\n' "$1" | sed -n "s/.*\"$2\":\([^,}]*\).*/\1/p"; }

reset_state() { rm -rf "$TMP_ROOT/state" "$EVENTS" "$EVENTS.calls" "$SHADOW_LIVE" "$SHADOW_LIVE.calls" "$HOSTDIR/ProgramData"; }

# write_shadow_record MAX_GIB USED_GIB AGE_SECONDS: the file the elevated
# fm-wsl-reclaim.ps1 task writes (tests/fm-wsl-reclaim.test.sh pins its format).
write_shadow_record() {
  mkdir -p "$HOSTDIR/ProgramData/firstmate"
  printf 'recorded=2026-10-01T12:00:00Z\r\nrecorded_epoch=%s\r\nvolume=C:\r\nmax_bytes=%s\r\nused_bytes=%s\r\nallocated_bytes=%s\r\n' \
    $(( $(date +%s) - $3 )) $(( $1 * GIB )) $(( $2 * GIB )) $(( $2 * GIB )) >"$HOSTDIR/ProgramData/firstmate/shadow-storage.txt"
}

# mkvhdx.py FILE LENGTH HOLE UNMAPPED ZERO NOT_PRESENT: a sparse VHDX of
# LENGTH bytes (1 MiB blocks, 512-byte sectors, so a sector bitmap entry after
# every 4096 payload entries) whose block table marks enough blocks present,
# alternately full and partial, to fill all but HOLE bytes after the fixed
# area, plus the given counts of unmapped, zero and not-present blocks.
# Prints "present=N fixed=B", where fixed is the header, log, metadata and
# block table area that sits before the first present block.
cat >"$TMP_ROOT/mkvhdx.py" <<'PY'
import struct, sys, uuid
MIB = 1 << 20
path, length, hole, unmapped, zero, absent = sys.argv[1], *map(int, sys.argv[2:])
def guid(s): return uuid.UUID(s).bytes_le
chunk = 4096
def entries(blocks): return blocks + (blocks - 1) // chunk
# The fixed area depends on the table size, which depends on the block count.
bat_mib, present = 1, 0
while True:
    fixed = (3 + bat_mib) * MIB
    present = (length - fixed - hole) // MIB
    blocks = present + unmapped + zero + absent
    need = -(-entries(blocks) * 8 // MIB)
    if need <= bat_mib:
        break
    bat_mib = need
states = [6 if i % 2 == 0 else 7 for i in range(present)] + [3] * unmapped + [2] * zero + [0] * absent
bat = bytearray(bat_mib * MIB)
k = 0
for i, st in enumerate(states):
    if i and i % chunk == 0:
        k += 1  # sector bitmap entry, left not present
    where = fixed // MIB + i if st in (6, 7) else 0
    struct.pack_into("<Q", bat, 8 * k, (where << 20) | st)
    k += 1
with open(path, "wb") as f:
    f.write(b"vhdxfile")
    h = bytearray(4096); h[:4] = b"head"
    struct.pack_into("<Q", h, 8, 5); struct.pack_into("<I", h, 68, MIB)
    f.seek(64 * 1024); f.write(h)
    r = bytearray(4096); r[:4] = b"regi"; struct.pack_into("<I", r, 8, 2)
    r[16:32] = guid("2DC27766-F623-4200-9D64-115E9BFD4A08"); struct.pack_into("<QI", r, 32, 3 * MIB, bat_mib * MIB)
    r[48:64] = guid("8B7CA206-4790-4B9A-B8FE-575F050F886E"); struct.pack_into("<QI", r, 64, 2 * MIB, MIB)
    f.seek(192 * 1024); f.write(r)
    m = bytearray(65536); m[:8] = b"metadata"; struct.pack_into("<H", m, 10, 3)
    items = [("CAA16737-FA36-4D43-B3B6-33F0AA44E76B", struct.pack("<I", MIB)),
             ("2FA54224-CD1B-4876-B211-5DBED83BF4B8", struct.pack("<Q", blocks * MIB)),
             ("8141BF1D-A96F-4709-BA47-F233A8FAAB5F", struct.pack("<I", 512))]
    for n, (g, data) in enumerate(items):
        e, at = 32 + 32 * n, 65536 + 16 * n
        m[e:e + 16] = guid(g); struct.pack_into("<II", m, e + 16, at, len(data))
    f.seek(2 * MIB); f.write(m)
    for n, (_, data) in enumerate(items):
        f.seek(2 * MIB + 65536 + 16 * n); f.write(data)
    f.seek(3 * MIB); f.write(bat)
    f.truncate(length)
print("present=%d fixed=%d" % (present, fixed))
PY

# write_vhdx LENGTH_GIB HOLE_MIB [UNMAPPED ZERO NOT_PRESENT]: the disk file as
# a VHDX fixture; sets VHDX_PRESENT and VHDX_FIXED from what it wrote.
write_vhdx() {
  local out
  out=$(python3 -I "$TMP_ROOT/mkvhdx.py" "$VHDX" $(( $1 * GIB )) $(( $2 * 1048576 )) "${3:-1000}" "${4:-200}" "${5:-300}") ||
    fail "the VHDX fixture is written"
  VHDX_PRESENT=$(printf '%s\n' "$out" | sed -n 's/^present=\([0-9]*\) .*/\1/p')
  VHDX_FIXED=$(printf '%s\n' "$out" | sed -n 's/.* fixed=\([0-9]*\)$/\1/p')
}

# The host frame bytes have 4 KiB blocks here, so real stat reports the block
# size of the temp filesystem; the fixture groups assume 4 KiB.
BS=$(stat -f -c %S "$LINUXDIR")

test_status_real_room_and_reclaim() {
  reset_state
  set_sizes 60 600 400
  write_vhdx 470 $(( 12 * 1024 ))
  write_mb_groups 30
  local out
  out=$(run_room status --json) || fail "status exits 0"
  assert_equals $(( 60 * GIB )) "$(json_field "$out" room)" "real room is the host drive's free space"
  assert_equals false "$(json_field "$out" low)" "60 GiB is not low"
  assert_equals $(( 70 * GIB )) "$(json_field "$out" slack)" "slack is disk file size minus Linux used"
  if [ "$BS" = 4096 ]; then
    assert_equals $(( 30 * GIB )) "$(json_field "$out" fragmented_free)" "only sub-1 MiB buddies count as fragmented"
  fi
  assert_equals $(( 470 * GIB - VHDX_PRESENT * 1048576 - VHDX_FIXED )) "$(json_field "$out" reclaimable)" \
    "reclaimable is the disk file length minus its present blocks and fixed area"
  assert_equals $(( 12 * GIB )) "$(json_field "$out" reclaimable)" "reclaimable is the block table's hole, not slack minus fragmented free"
  out=$(run_room status)
  assert_contains "$out" "real room: 60.0 GiB (limited by $HOSTDIR; margin 20.0 GiB)" "plain status names the limit"
  assert_contains "$out" "reclaimable by compaction about 12.0 GiB (disk file block table)" "plain status names the block table figure"
  set_sizes 60 50 400
  out=$(run_room status --json)
  assert_equals $(( 50 * GIB )) "$(json_field "$out" room)" "Linux free limits when it is smaller"
  pass "status reports real room, slack and the reclaimable estimate"
}

test_trim_estimate() {
  reset_state
  set_sizes 60 600 400
  write_vhdx 470 $(( 12 * 1024 ))
  write_mb_groups 30
  # A wholly free group whose blocks the table already holds unmapped adds nothing.
  add_whole_groups $(( VHDX_PRESENT / 128 + 1 )) 1
  local out
  out=$(run_room status --json)
  assert_equals $(( 12 * GIB )) "$(json_field "$out" reclaimable)" "a trim estimate never adds to reclaimable"
  if [ "$BS" = 4096 ]; then
    assert_equals $(( 128 * 1048576 )) "$(json_field "$out" trim_reclaimable)" \
      "after a trim counts wholly free 1 MiB blocks the table holds present, not ones already unmapped"
    out=$(run_room status)
    assert_contains "$out" "after a trim: about 0.1 GiB more (ext4 free 1 MiB blocks the disk file still holds; reclaim-now trims before compacting)" \
      "plain status names the after-a-trim figure"
  fi
  # A cache line from before the trim figure (4 fields) is read again, not trusted.
  printf '%s %s %s %s\n' "$(date +%s)" $(( 470 * GIB )) 1 "$VHDX" >"$TMP_ROOT/state/vhdx-bat"
  out=$(run_room status --json)
  assert_equals $(( 12 * GIB )) "$(json_field "$out" reclaimable)" "an old-format cache line is not trusted"
  if [ "$BS" = 4096 ]; then
    # A group past the end of the disk file means the tables do not match.
    rm -rf "$TMP_ROOT/state"
    add_whole_groups $(( 470 * 8 + 10 )) 1
    out=$(run_room status --json)
    assert_equals null "$(json_field "$out" trim_reclaimable)" "a group past the disk file leaves the trim figure unknown"
    assert_equals $(( 12 * GIB )) "$(json_field "$out" reclaimable)" "and keeps the block table figure"
  fi
  rm -rf "$TMP_ROOT/state" "$TMP_ROOT/mb_groups"
  out=$(run_room status --json)
  assert_equals null "$(json_field "$out" trim_reclaimable)" "no mb_groups reading leaves the trim figure unknown"
  assert_equals $(( 12 * GIB )) "$(json_field "$out" reclaimable)" "and keeps the block table figure"
  out=$(run_room status)
  assert_contains "$out" "after a trim: unknown (ext4 mb_groups unreadable)" "plain status says the trim figure is unknown"
  mkdir -p "$HOSTDIR/ProgramData/firstmate"
  printf 'finished=2026-10-22T12:00:00\r\nmode=now\r\nresult=ok\r\nreclaimed_bytes=%s\r\nc_free_bytes=1\r\ntrim=ok\r\ntrim_detail=exit 0: /: 30 GiB trimmed\r\nfile=x|2|1|ok\r\n' "$GIB" \
    >"$HOSTDIR/ProgramData/firstmate/wsl-compact-last.txt"
  out=$(run_room status)
  assert_contains "$out" "last compaction: 2026-10-22T12:00:00 now ok reclaimed 1.0 GiB, trim ok" "the last compaction names its trim result"
  pass "status reports what a trim would add, apart from reclaimable"
}

test_check_margin() {
  reset_state
  set_sizes 45 600 400
  local out rc
  out=$(run_room check --expect-write 25G); rc=$?
  expect_code 0 "$rc" "exactly the margin left is admitted"
  assert_contains "$out" "ok: 20.0 GiB left after a 25.0 GiB write" "ok line"
  out=$(run_room check --expect-write 26G); rc=$?
  expect_code 1 "$rc" "under the margin is refused"
  assert_contains "$out" "low: only 19.0 GiB would be left on $HOSTDIR" "low line names the drive"
  out=$(FM_DISK_ROOM_MARGIN=10G run_room check --expect-write 26G); rc=$?
  expect_code 0 "$rc" "the margin is configurable"
  run_room check --expect-write lots >/dev/null 2>&1; rc=$?
  expect_code 2 "$rc" "a bad size is misuse"
  out=$(run_room check --expect-write "$(printf '9%.0s' $(seq 400))" 2>&1); rc=$?
  expect_code 2 "$rc" "an over-long size is misuse"
  assert_contains "$out" "bad size" "an over-long size is reported instead of overflowing"
  run_room check >/dev/null 2>&1; rc=$?
  expect_code 2 "$rc" "check needs --expect-write"
  pass "check admits down to the margin after the expected write"
}

test_margin_sources() {
  reset_state
  set_sizes 45 600 400
  local home="$TMP_ROOT/margin-home" out rc items
  mkdir -p "$home/config"
  out=$(TEST_FM_HOME="$home" run_room status --json)
  assert_equals $(( 20 * GIB )) "$(json_field "$out" margin)" "no file and no variable keeps 20G"
  printf '1G\r\nignored\n' >"$home/config/disk-room-margin"
  out=$(TEST_FM_HOME="$home" run_room status --json)
  assert_equals "$GIB" "$(json_field "$out" margin)" "the home's file wins over the default"
  out=$(TEST_FM_HOME="$home" run_room check --expect-write 43G); rc=$?
  expect_code 0 "$rc" "the file's margin admits a write the default would refuse"
  out=$(FM_DISK_ROOM_MARGIN=10G TEST_FM_HOME="$home" run_room status --json)
  assert_equals $(( 10 * GIB )) "$(json_field "$out" margin)" "the variable wins over the file"
  printf 'lots\n' >"$home/config/disk-room-margin"
  out=$(FM_DISK_ROOM_MARGIN=10G TEST_FM_HOME="$home" run_room status --json)
  assert_equals $(( 10 * GIB )) "$(json_field "$out" margin)" "the variable wins over a bad file"
  out=$(TEST_FM_HOME="$home" run_room check --expect-write 1G 2>&1); rc=$?
  expect_code 2 "$rc" "a bad file is a failed reading"
  assert_contains "$out" "bad margin in $home/config/disk-room-margin" "a bad file is named"
  out=$(TEST_FM_HOME="$home" run_room status 2>&1); rc=$?
  expect_code 2 "$rc" "status fails on a bad file"
  assert_contains "$out" "bad margin in $home/config/disk-room-margin" "status names the bad file"
  : >"$home/config/disk-room-margin"
  out=$(TEST_FM_HOME="$home" run_room check --expect-write 1G 2>&1); rc=$?
  expect_code 2 "$rc" "an empty file is a failed reading"
  rm -f "$home/config/disk-room-margin"
  items=$(env -u FM_INHERITABLE_CONFIG bash -c '. "$1" && fm_config_inherit_items' _ "$ROOT/bin/fm-config-inherit-lib.sh")
  assert_contains "$items" "config/disk-room-margin" "the margin file is inherited into secondmate homes"
  pass "the margin comes from the variable, else the home's config file, else 20G"
}

test_low_advice() {
  reset_state
  set_sizes 30 600 400
  write_vhdx 470 $(( 8 * 1024 ))
  write_mb_groups 10
  local out
  out=$(run_room check --expect-write 20G)
  assert_contains "$out" "a compaction would reclaim about 8.0 GiB" "holes in the block table point at compaction"
  reset_state
  write_vhdx 470 0 0 0 0
  out=$(run_room check --expect-write 20G)
  assert_not_contains "$out" "a compaction would reclaim about" "slack the ext4 side reads as 60 GiB unfragmented promises nothing without block table holes"
  reset_state
  add_whole_groups 100 60
  out=$(run_room check --expect-write 20G)
  assert_not_contains "$out" "a compaction would reclaim about" "a large after-a-trim figure never advises reclaim now"
  if [ "$BS" = 4096 ]; then
    assert_equals $(( 61 * 128 * 1048576 )) "$(json_field "$(run_room status --json)" trim_reclaimable)" \
      "the after-a-trim figure counts the 60 added groups and write_mb_groups' own wholly free group"
  fi
  assert_contains "$out" "compaction would reclaim under 5 GiB; data must be freed or moved" "a full block table says compaction cannot help"
  out=$(run_room status --json)
  assert_equals 0 "$(json_field "$out" reclaimable)" "a block table without holes reclaims nothing"
  pass "a low reading says whether compaction would help, from the disk file's block table"
}

test_unknown_reclaim() {
  reset_state
  set_sizes 30 600 400
  truncate -s 0 "$VHDX"
  truncate -s $(( 470 * GIB )) "$VHDX"
  write_mb_groups 30
  local out
  out=$(run_room status --json)
  assert_equals null "$(json_field "$out" reclaimable)" "reclaimable is not guessed from slack when the file is no VHDX"
  out=$(run_room status)
  assert_contains "$out" "reclaimable by compaction unknown (disk file block table unreadable)" "plain status says the figure is unknown"
  out=$(run_room check --expect-write 20G)
  assert_contains "$out" "reclaimable by compaction unknown (disk file block table unreadable)" "low advice names the unreadable block table"
  assert_not_contains "$out" "a compaction would reclaim" "no compaction promise without the block table"
  reset_state
  write_vhdx 470 $(( 12 * 1024 ))
  printf 'xxxx' | dd of="$VHDX" bs=1 seek=$(( 192 * 1024 )) conv=notrunc 2>/dev/null
  printf 'xxxx' | dd of="$VHDX" bs=1 seek=$(( 256 * 1024 )) conv=notrunc 2>/dev/null
  out=$(run_room status --json)
  assert_equals null "$(json_field "$out" reclaimable)" "a VHDX without a readable region table is unknown"
  reset_state
  write_vhdx 470 $(( 12 * 1024 ))
  rm -f "$TMP_ROOT/mb_groups"
  out=$(run_room status --json)
  assert_equals null "$(json_field "$out" fragmented_free)" "no fragmented reading"
  assert_equals $(( 12 * GIB )) "$(json_field "$out" reclaimable)" "the block table figure does not need the ext4 readings"
  write_mb_groups 30
  out=$(FM_DISK_ROOM_VHDX="$TMP_ROOT/missing.vhdx" run_room check --expect-write 20G)
  assert_contains "$out" "reclaimable by compaction unknown (disk file not found)" "a missing disk file is unknown, not hopeless"
  pass "an unreadable reclaim estimate is reported as unknown"
}

test_reservations() {
  reset_state
  set_sizes 60 600 400
  local out rc
  out=$(run_room reserve keeper 30G) || fail "reserve exits 0"
  assert_contains "$out" "reserved keeper: 30.0 GiB" "reserve confirms"
  out=$(run_room check --expect-write 20G); rc=$?
  expect_code 1 "$rc" "a reservation counts against room"
  out=$(run_room check --expect-write 20G --exclude keeper); rc=$?
  expect_code 0 "$rc" "--exclude drops the caller's own reservation"
  out=$(FM_DISK_ROOM_NOW=$(( $(date +%s) + 43201 )) run_room check --expect-write 20G); rc=$?
  expect_code 0 "$rc" "a reservation without a pid lapses after its ttl"
  run_room reserve keeper 30G >/dev/null
  run_room release keeper
  out=$(run_room check --expect-write 20G); rc=$?
  expect_code 0 "$rc" "release drops the reservation"
  sleep 300 &
  local pid=$!
  run_room reserve job 30G --pid "$pid" >/dev/null
  out=$(run_room check --expect-write 20G); rc=$?
  expect_code 1 "$rc" "a pid-bound reservation holds while the process lives"
  kill "$pid"; wait "$pid" 2>/dev/null
  out=$(run_room check --expect-write 20G); rc=$?
  expect_code 0 "$rc" "a pid-bound reservation lapses when the process exits"
  run_room reserve ../x 1G >/dev/null 2>&1; rc=$?
  expect_code 2 "$rc" "a reservation name cannot leave the state directory"
  pass "reservations reduce room until released, expired, or their process exits"
}

test_run() {
  reset_state
  set_sizes 60 600 400
  local out rc
  out=$(run_room run --name close-out --expect-write 20G -- sh -c 'cat "$FM_DISK_ROOM_STATE/reservations/close-out"; echo ran' 2>&1); rc=$?
  expect_code 0 "$rc" "an admitted run returns the command's status"
  assert_contains "$out" "bytes=$(( 20 * GIB ))" "the reservation is held while the command runs"
  assert_contains "$out" "ran" "the command ran"
  out=$(run_room check --expect-write 40G); rc=$?
  expect_code 0 "$rc" "the reservation lapses once the command exits"
  out=$(run_room run --name big --expect-write 50G -- sh -c 'echo ran' 2>&1); rc=$?
  expect_code 75 "$rc" "a run that would break the margin is refused"
  assert_contains "$out" "refused big: low" "refusal names the job"
  assert_not_contains "$out" "ran" "a refused command does not run"
  out=$(TEST_HOST="$TMP_ROOT/missing" run_room run --name x --expect-write 1G -- sh -c 'echo ran' 2>&1); rc=$?
  expect_code 75 "$rc" "an unreadable host drive refuses rather than admits"
  pass "run admits, holds the reservation for the command, and refuses when low"
}

test_watch_line() {
  reset_state
  set_sizes 60 600 400
  local out t0
  t0=$(date +%s)
  out=$(FM_DISK_ROOM_NOW=$t0 run_room watch-line)
  assert_equals "" "$out" "silent while room is above the margin"
  set_sizes 15 600 400
  out=$(FM_DISK_ROOM_NOW=$t0 run_room watch-line)
  assert_contains "$out" "disk room low: 15.0 GiB real room on $HOSTDIR" "one line when room falls under the margin"
  out=$(FM_DISK_ROOM_NOW=$(( t0 + 60 )) run_room watch-line)
  assert_equals "" "$out" "the same low reading does not repeat"
  set_sizes 12 600 400
  out=$(FM_DISK_ROOM_NOW=$(( t0 + 120 )) run_room watch-line)
  assert_equals "" "$out" "a small further drop does not repeat"
  set_sizes 9 600 400
  out=$(FM_DISK_ROOM_NOW=$(( t0 + 180 )) run_room watch-line)
  assert_contains "$out" "9.0 GiB real room" "a further 5 GiB drop repeats"
  out=$(FM_DISK_ROOM_NOW=$(( t0 + 180 + 21600 )) run_room watch-line)
  assert_contains "$out" "9.0 GiB real room" "a low reading repeats after 6 hours"
  set_sizes 60 600 400
  out=$(FM_DISK_ROOM_NOW=$(( t0 + 30000 )) run_room watch-line)
  assert_equals "" "$out" "silent again after recovery"
  set_sizes 15 600 400
  out=$(FM_DISK_ROOM_NOW=$(( t0 + 30060 )) run_room watch-line)
  assert_contains "$out" "disk room low" "a new fall after recovery alerts at once"
  out=$(TEST_HOST="$TMP_ROOT/missing" FM_DISK_ROOM_NOW=$(( t0 + 30120 )) run_room watch-line)
  assert_contains "$out" "disk room: cannot measure" "an unreadable drive is reported"
  pass "watch-line speaks only when room is low, without repeating itself"
}

test_fs_overhead() {
  reset_state
  set_sizes 30 600 400
  write_vhdx 470 $(( 2 * 1024 ))
  write_mb_groups 30
  local out
  out=$(TEST_DEV_SIZE=$(( 1017 * GIB )) run_room status --json)
  assert_equals $(( 17 * GIB )) "$(json_field "$out" fs_overhead)" "ext4 metadata is the block device size minus the df total"
  assert_equals $(( 2 * GIB )) "$(json_field "$out" reclaimable)" "reclaimable comes from the block table, not slack minus fragmented free minus metadata"
  if [ "$BS" = 4096 ]; then
    out=$(TEST_DEV_SIZE=$(( 1017 * GIB )) run_room status)
    assert_contains "$out" "slack 70.0 GiB, of which fragmented 30.0 GiB and ext4 metadata 17.0 GiB; reclaimable by compaction about 2.0 GiB (disk file block table)" "status names the ext4 readings apart from the reclaimable figure"
  fi
  out=$(TEST_DEV_SIZE=unreadable run_room status --json)
  assert_equals null "$(json_field "$out" fs_overhead)" "no metadata reading"
  assert_equals $(( 2 * GIB )) "$(json_field "$out" reclaimable)" "the block table figure does not need the device size"
  out=$(TEST_DEV_SIZE=unreadable run_room status)
  assert_contains "$out" "and ext4 metadata unknown; reclaimable by compaction about 2.0 GiB" "an unknown metadata size is shown as unknown"
  out=$(TEST_DEV_SIZE=unreadable run_room check --expect-write 20G)
  assert_contains "$out" "compaction would reclaim under 5 GiB; data must be freed or moved" "low advice follows the block table alone"
  pass "ext4 metadata is reported apart from what compaction can reclaim"
}

test_linux_only() {
  reset_state
  set_sizes 60 30 400
  local out
  out=$(PATH="$FAKEBIN:$PATH" FAKE_DF="$DFDIR" FM_DISK_ROOM_HOST='' FM_DISK_ROOM_ROOT="$LINUXDIR" \
    FM_DISK_ROOM_MB_GROUPS="$TMP_ROOT/mb_groups" FM_DISK_ROOM_STATE="$TMP_ROOT/state" "$DISK_ROOM" status --json)
  assert_equals $(( 30 * GIB )) "$(json_field "$out" room)" "without a Windows drive the Linux filesystem is the limit"
  assert_equals null "$(json_field "$out" host_free)" "no host reading"
  pass "outside WSL the monitor measures the Linux filesystem alone"
}

test_vhdx_discovery_cached() {
  reset_state
  set_sizes 60 600 400
  truncate -s $(( 470 * GIB )) "$VHDX"
  local out
  out=$(PATH="$FAKEBIN:$PATH" FAKE_DF="$DFDIR" FM_DISK_ROOM_HOST="${TEST_HOST-$HOSTDIR}" FM_DISK_ROOM_ROOT="$LINUXDIR" \
    FM_DISK_ROOM_MB_GROUPS="$TMP_ROOT/mb_groups" FM_DISK_ROOM_STATE="$TMP_ROOT/state" FM_DISK_ROOM_VHDX='' FM_DISK_ROOM_POWERSHELL='' "$DISK_ROOM" status --json)
  assert_contains "$out" "\"vhdx\":\"$VHDX\"" "the single distro disk under the Windows profile is found"
  mkdir -p "$HOSTDIR/Users/v/AppData/Local/wsl/{h}"
  : >"$HOSTDIR/Users/v/AppData/Local/wsl/{h}/ext4.vhdx"
  out=$(run_room status --json)
  assert_contains "$out" "\"vhdx\":\"$VHDX\"" "the discovered disk is cached"
  rm -rf "$HOSTDIR/Users/v"
  pass "the distro disk is discovered once and cached"
}

test_arm_and_disarm() {
  reset_state
  set_sizes 15 600 400
  local home out
  home="$TMP_ROOT/home"
  mkdir -p "$home/state"
  chmod 700 "$home/state"
  out=$(FM_HOME="$home" FM_DISK_ROOM_WEVTUTIL='' FM_DISK_ROOM_POWERSHELL='' FM_DISK_ROOM_MARGIN=20G FM_DISK_ROOM_HOST="$HOSTDIR" FM_DISK_ROOM_ROOT="$LINUXDIR" \
    FM_DISK_ROOM_MB_GROUPS="$TMP_ROOT/mb_groups" FM_DISK_ROOM_STATE="$TMP_ROOT/state" \
    FM_DISK_ROOM_RESULTS_ROOT="$TMP_ROOT/missing-results-root" FM_DISK_ROOM_SAMPLES="$TMP_ROOT/no-samples" \
    FM_DISK_ROOM_WSLCONFIG='' FM_DISK_ROOM_C_FREE_MIN=40G "$DISK_ROOM" arm) || fail "arm exits 0"
  assert_contains "$out" "armed: $home/state/disk-room.check.sh" "arm names the shim"
  assert_present "$home/state/disk-room.check-trust" "arm binds the shim's bytes"
  out=$(env -u FM_DISK_ROOM_HOST PATH="$FAKEBIN:$PATH" FAKE_DF="$DFDIR" FAKE_BULK_MNT="$TMP_ROOT/mnt" FM_STORAGE_MNT="$TMP_ROOT/mnt" "$home/state/disk-room.check.sh")
  assert_contains "$out" "disk room low: 15.0 GiB real room on $HOSTDIR" "the shim carries the arm-time settings"
  assert_contains "$out" " | storage alert: $HOSTDIR has 15.0 GiB actually free (floor 40.0 GiB)" "the shim carries the alert thresholds"
  FM_HOME="$home" "$DISK_ROOM" disarm >/dev/null || fail "disarm exits 0"
  assert_absent "$home/state/disk-room.check.sh" "disarm removes the shim"
  assert_absent "$home/state/disk-room.check-trust" "disarm removes the trust binding"
  pass "arm registers the watcher check with its settings and disarm retires it"
}

test_results_root_in_status() {
  reset_state
  set_sizes 60 600 400
  local out rr="$TMP_ROOT/results-root"
  out=$(FM_DISK_ROOM_RESULTS_ROOT="$rr" run_room status)
  assert_not_contains "$out" "fetched results root" "no results-root file adds no lines"
  printf '/mnt/d/lattice-data/tetjet-results/{task}\nformat=lattice-storage-results-root/v1\nactive=ssd\nstate=ok\nssd_letter=D\nssd_fs=exFAT\nssd_free_bytes=%s\nssd_total_bytes=%s\n' \
    $(( 1700 * GIB )) $(( 1863 * GIB )) >"$rr"
  out=$(FM_DISK_ROOM_RESULTS_ROOT="$rr" run_room status)
  assert_contains "$out" "SSD D: 1700.0 GiB free of 1863.0 GiB (exFAT)" "the SSD's room is reported"
  assert_contains "$out" "fetched results root: SSD D:" "the active root is named"
  out=$(FM_DISK_ROOM_RESULTS_ROOT="$rr" run_room status --json)
  assert_equals '"ssd"' "$(json_field "$out" results_active)" "json names the active root"
  assert_equals $(( 1700 * GIB )) "$(json_field "$out" ssd_free)" "json carries the SSD free space"
  sed -i 's/^active=ssd/active=c/; s/^state=ok/state=full/' "$rr"
  out=$(FM_DISK_ROOM_RESULTS_ROOT="$rr" run_room status)
  assert_contains "$out" "fetched results root: no active SSD publication (state full); per-fetch wait/refusal/fallback rules apply" "the publication state is named without promising every fetch waits"
  pass "status reports the SSD's room and the active results root"
}

test_shadow_record_reserves_headroom() {
  reset_state
  set_sizes 60 600 400
  write_shadow_record 10 3 60
  local out rc
  out=$(run_room status --json)
  assert_equals $(( 53 * GIB )) "$(json_field "$out" room)" "room drops by the cap minus what is used"
  assert_equals $(( 7 * GIB )) "$(json_field "$out" shadow_reserved)" "the headroom is reported"
  assert_equals '"record"' "$(json_field "$out" shadow_source)" "the elevated record is the source"
  assert_equals '"record"' "$(json_field "$out" shadow_reading)" "the reading is named as the record"
  out=$(run_room status)
  assert_contains "$out" "shadow storage: 7.0 GiB headroom reserved (cap 10.0 GiB, used 3.0 GiB" "plain status explains the reservation"
  assert_contains "$out" "source record, no live reading)" "plain status names the record as the source"
  out=$(run_room check --expect-write 34G); rc=$?
  expect_code 1 "$rc" "admission counts the shadow storage headroom"
  assert_contains "$out" "low: only 19.0 GiB would be left on $HOSTDIR" "the low line names the drive"
  write_shadow_record 10 12 60
  out=$(run_room status --json)
  assert_equals $(( 60 * GIB )) "$(json_field "$out" room)" "used above the cap reserves nothing"
  set_sizes 60 50 400
  write_shadow_record 10 3 60
  out=$(run_room status --json)
  assert_equals $(( 50 * GIB )) "$(json_field "$out" room)" "the reservation applies to the Windows drive only"
  pass "a fresh elevated record reserves the shadow storage headroom"
}

test_shadow_fallback_and_stale() {
  reset_state
  set_sizes 60 600 400
  local out
  out=$(FM_DISK_ROOM_SHADOW_MAX=10G run_room status --json)
  assert_equals $(( 50 * GIB )) "$(json_field "$out" room)" "with used unknown the whole configured cap is reserved"
  assert_equals '"config"' "$(json_field "$out" shadow_source)" "the configured cap is the source"
  out=$(FM_DISK_ROOM_SHADOW_MAX=10G run_room status)
  assert_contains "$out" "shadow storage: 10.0 GiB reserved (whole FM_DISK_ROOM_SHADOW_MAX cap" "plain status names the fallback"
  write_shadow_record 10 3 $(( 8 * 86400 ))
  out=$(run_room status --json)
  assert_equals $(( 50 * GIB )) "$(json_field "$out" room)" "a stale record keeps only its cap"
  assert_equals '"stale-record"' "$(json_field "$out" shadow_source)" "the stale record is named"
  printf 'garbage\n' >"$HOSTDIR/ProgramData/firstmate/shadow-storage.txt"
  out=$(run_room status --json)
  assert_equals $(( 60 * GIB )) "$(json_field "$out" room)" "an unreadable record never adds room and alone reserves nothing"
  out=$(FM_DISK_ROOM_SHADOW_MAX=10G run_room status --json)
  assert_equals $(( 50 * GIB )) "$(json_field "$out" room)" "an unreadable record falls back to the configured cap"
  write_shadow_record 10 3 60
  sed -i 's/^max_bytes=.*/max_bytes=unbounded\r/' "$HOSTDIR/ProgramData/firstmate/shadow-storage.txt"
  out=$(run_room status)
  assert_contains "$out" "shadow storage: not reserved (the recorded shadow storage has no cap" "an unbounded record is named"
  out=$(FM_DISK_ROOM_SHADOW_MAX=10G run_room status --json)
  assert_equals $(( 50 * GIB )) "$(json_field "$out" room)" "an unbounded record falls back to the configured cap"
  write_shadow_record 10 3 $(( 8 * 86400 ))
  sed -i 's/^max_bytes=.*/max_bytes=9223372036854775808\r/' "$HOSTDIR/ProgramData/firstmate/shadow-storage.txt"
  out=$(run_room status --json)
  assert_equals $(( 60 * GIB )) "$(json_field "$out" room)" "a cap past signed 64 bits is unreadable and never wraps room past host free space"
  out=$(FM_DISK_ROOM_SHADOW_MAX=10G run_room status --json)
  assert_equals $(( 50 * GIB )) "$(json_field "$out" room)" "a cap past signed 64 bits falls back to the configured cap"
  out=$(FM_DISK_ROOM_SHADOW_MAX=9000000000T run_room status 2>&1)
  assert_contains "$out" "bad FM_DISK_ROOM_SHADOW_MAX" "a configured cap past signed 64 bits is reported"
  out=$(FM_DISK_ROOM_SHADOW_MAX=lots run_room status 2>&1)
  assert_contains "$out" "bad FM_DISK_ROOM_SHADOW_MAX" "a bad configured cap is reported"
  pass "without a fresh record the configured cap is reserved whole"
}

test_shadow_live_reading() {
  reset_state
  set_sizes 60 600 400
  write_shadow_record 10 3 60
  write_shadow_live 19 16 15
  local out t0
  t0=$(date +%s)
  out=$(FM_DISK_ROOM_NOW=$t0 run_room status --json)
  assert_equals $(( 3 * GIB )) "$(json_field "$out" shadow_reserved)" "the live reading reserves the cap minus what is allocated"
  assert_equals $(( 57 * GIB )) "$(json_field "$out" room)" "room drops by the live headroom, not the record's"
  assert_equals '"live"' "$(json_field "$out" shadow_source)" "the live reading is the source"
  assert_equals '"live"' "$(json_field "$out" shadow_reading)" "the reading is named as live"
  assert_equals $(( 19 * GIB )) "$(json_field "$out" shadow_max)" "the live cap is reported"
  assert_equals $(( 16 * GIB )) "$(json_field "$out" shadow_allocated)" "the live allocated size is reported"
  assert_equals $(( 15 * GIB )) "$(json_field "$out" shadow_used)" "the live used size is reported"
  out=$(FM_DISK_ROOM_NOW=$(( t0 + 60 )) run_room status)
  assert_contains "$out" "shadow storage: 3.0 GiB headroom reserved (cap 19.0 GiB, allocated 16.0 GiB, used 15.0 GiB" "plain status explains the live reservation"
  assert_contains "$out" "source live)" "plain status names the live source"
  assert_equals 1 "$(live_calls)" "the live reading is cached for a few minutes"
  write_shadow_live 19 1 0
  out=$(FM_DISK_ROOM_NOW=$(( t0 + 299 )) run_room status --json)
  assert_equals $(( 3 * GIB )) "$(json_field "$out" shadow_reserved)" "the cached reading is reused within its window"
  assert_equals 1 "$(live_calls)" "no Windows process starts within the window"
  out=$(FM_DISK_ROOM_NOW=$(( t0 + 300 )) run_room status --json)
  assert_equals 2 "$(live_calls)" "an expired cache is read again"
  assert_equals $(( 18 * GIB )) "$(json_field "$out" shadow_reserved)" "after a restore-point cycle the small allocation reserves almost the whole cap"
  assert_equals $(( 42 * GIB )) "$(json_field "$out" room)" "after a cycle room is not overstated from the record's old used size"
  write_shadow_live 10 12 12
  out=$(FM_DISK_ROOM_NOW=$(( t0 + 600 )) run_room status --json)
  assert_equals 0 "$(json_field "$out" shadow_reserved)" "allocated above the cap reserves nothing"
  printf 'SHADOW|unbounded|%s|%s\r\nEND\r\n' $(( 2 * GIB )) $(( 2 * GIB )) >"$SHADOW_LIVE"
  out=$(FM_DISK_ROOM_NOW=$(( t0 + 900 )) FM_DISK_ROOM_SHADOW_MAX=10G run_room status --json)
  assert_equals $(( 10 * GIB )) "$(json_field "$out" shadow_reserved)" "a live reading without a cap reserves the configured cap whole"
  assert_equals '"live"' "$(json_field "$out" shadow_reading)" "the uncapped reading is still named live"
  pass "a live shadow storage reading reserves the cap minus what is allocated"
}

test_shadow_live_failure_falls_back() {
  reset_state
  set_sizes 60 600 400
  write_shadow_record 10 3 60
  local out t0
  t0=$(date +%s)
  out=$(FM_DISK_ROOM_NOW=$t0 run_room status --json) || fail "a failed live reading does not fail status"
  assert_equals 1 "$(live_calls)" "the live reading is tried"
  assert_equals $(( 7 * GIB )) "$(json_field "$out" shadow_reserved)" "a failed live reading falls back to the record"
  assert_equals '"record"' "$(json_field "$out" shadow_reading)" "the fallback is named as the record"
  [ ! -e "$TMP_ROOT/state/shadow-live-good" ] || fail "a failed reading never writes the last good reading"
  write_shadow_live 19 16 15
  out=$(FM_DISK_ROOM_NOW=$(( t0 + 60 )) run_room status --json)
  assert_equals 1 "$(live_calls)" "a failure is cached too, so a hung powershell is not retried on every status"
  assert_equals '"record"' "$(json_field "$out" shadow_reading)" "the cached failure keeps the record"
  out=$(FM_DISK_ROOM_NOW=$(( t0 + 300 )) run_room status --json)
  assert_equals '"live"' "$(json_field "$out" shadow_reading)" "the live reading is retried once the window passes"
  # From here the good reading at t0 + 300 is newer than the record, so each
  # failure falls back to it.
  printf 'SHADOW|%s|%s|%s\r\n' $(( 19 * GIB )) $(( 16 * GIB )) $(( 15 * GIB )) >"$SHADOW_LIVE"
  out=$(FM_DISK_ROOM_NOW=$(( t0 + 600 )) run_room status --json)
  assert_equals '"last-live"' "$(json_field "$out" shadow_reading)" "a reading cut off before its END line is a failure"
  printf 'END\r\n' >"$SHADOW_LIVE"
  out=$(FM_DISK_ROOM_NOW=$(( t0 + 900 )) run_room status --json)
  assert_equals '"last-live"' "$(json_field "$out" shadow_reading)" "a reading with no shadow storage on the drive falls back"
  printf 'SHADOW|9223372036854775808|0|0\r\nEND\r\n' >"$SHADOW_LIVE"
  out=$(FM_DISK_ROOM_NOW=$(( t0 + 1200 )) run_room status --json)
  assert_equals '"last-live"' "$(json_field "$out" shadow_reading)" "a live cap past signed 64 bits is unreadable"
  rm -f "$HOSTDIR/ProgramData/firstmate/shadow-storage.txt" "$SHADOW_LIVE" "$TMP_ROOT/state/shadow-live-good"
  out=$(FM_DISK_ROOM_NOW=$(( t0 + 1500 )) run_room status)
  assert_contains "$out" "shadow storage: not reserved (no live reading and no record" "with neither reading nothing is reserved"
  assert_contains "$out" "source none)" "plain status names no source"
  out=$(FM_DISK_ROOM_NOW=$(( t0 + 1500 )) FM_DISK_ROOM_POWERSHELL='' run_room status --json)
  assert_equals '"none"' "$(json_field "$out" shadow_reading)" "an empty powershell setting disables the live reading"
  pass "a failed live reading falls back to the elevated record"
}

test_shadow_last_live_fallback() {
  reset_state
  set_sizes 60 600 400
  write_shadow_record 10 0 3600
  write_shadow_live 3 1 1
  local out t0 when
  t0=$(date +%s)
  out=$(FM_DISK_ROOM_NOW=$t0 run_room status --json)
  assert_equals '"live"' "$(json_field "$out" shadow_reading)" "the live reading is taken"
  rm -f "$SHADOW_LIVE"
  out=$(FM_DISK_ROOM_NOW=$(( t0 + 300 )) run_room status --json)
  assert_equals 2 "$(live_calls)" "the live reading is tried again and fails"
  assert_equals '"last-live"' "$(json_field "$out" shadow_reading)" "the last good live reading, newer than the record, is the fallback"
  assert_equals '"last-live"' "$(json_field "$out" shadow_source)" "the source is the last live reading"
  assert_equals $(( 2 * GIB )) "$(json_field "$out" shadow_reserved)" "the last live cap minus allocated is reserved, not the older record's 10 GiB"
  assert_equals $(( 58 * GIB )) "$(json_field "$out" room)" "room keeps the last live reservation"
  read -r when _ <"$TMP_ROOT/state/shadow-live-good"
  assert_equals "$t0" "$when" "a failure never overwrites the last good reading"
  out=$(FM_DISK_ROOM_NOW=$(( t0 + 300 )) run_room status)
  assert_contains "$out" "shadow storage: 2.0 GiB headroom reserved (cap 3.0 GiB, allocated 1.0 GiB, used 1.0 GiB; source last live reading at $(date -u -d "@$t0" '+%Y-%m-%d %H:%M UTC'), no live reading now)" "plain status names the last live reading and its time"
  write_shadow_record 10 3 -100
  out=$(FM_DISK_ROOM_NOW=$(( t0 + 600 )) run_room status --json)
  assert_equals '"record"' "$(json_field "$out" shadow_reading)" "a record newer than the last good live reading wins"
  assert_equals $(( 7 * GIB )) "$(json_field "$out" shadow_reserved)" "the newer record's headroom is reserved"
  rm -f "$HOSTDIR/ProgramData/firstmate/shadow-storage.txt"
  out=$(FM_DISK_ROOM_NOW=$(( t0 + 8 * 86400 )) run_room status --json)
  assert_equals '"stale-last-live"' "$(json_field "$out" shadow_source)" "a last live reading over 7 days old is stale"
  assert_equals $(( 3 * GIB )) "$(json_field "$out" shadow_reserved)" "a stale last live reading reserves its whole cap"
  out=$(FM_DISK_ROOM_NOW=$(( t0 + 8 * 86400 + 300 )) FM_DISK_ROOM_SHADOW_MAX=10G run_room status --json)
  assert_equals $(( 10 * GIB )) "$(json_field "$out" shadow_reserved)" "a larger configured cap bounds a stale last live reading"
  pass "a failed live reading falls back to the newer of the last good live reading and the record"
}

test_swap_file_growth() {
  reset_state
  set_sizes 60 600 400
  local conf="$HOSTDIR/Users/u/.wslconfig" g1="$HOSTDIR/Users/u/AppData/Local/Temp/{G1}" g2="$HOSTDIR/Users/u/AppData/Local/Temp/{G2}" g3="$HOSTDIR/Users/u/AppData/Local/Temp/{G3}" out rc
  mkdir -p "$g1"
  truncate -s $(( 3 * GIB )) "$g1/swap.vhdx"
  printf '\xEF\xBB\xBF[wsl2]\r\nmemory=16GB\r\nSwap = 16GB\r\n' >"$conf"
  printf 'MemTotal:       16375996 kB\n' >"$TMP_ROOT/meminfo"
  out=$(TEST_SWAP_DISCOVER=1 run_room status --json)
  assert_equals '"wslconfig"' "$(json_field "$out" swap_source)" ".wslconfig beside the disk file gives the swap size"
  assert_equals $(( 16 * GIB )) "$(json_field "$out" swap_size)" "swap= is read from the [wsl2] section"
  assert_equals $(( 3 * GIB )) "$(json_field "$out" swap_file_size)" "the newest Temp swap.vhdx is the swap file"
  assert_equals $(( 13 * GIB )) "$(json_field "$out" swap_reserved)" "the swap file's remaining growth is reserved"
  assert_equals $(( 47 * GIB )) "$(json_field "$out" room)" "room drops by the swap file's growth"
  out=$(TEST_SWAP_DISCOVER=1 run_room status)
  assert_contains "$out" "swap file: 13.0 GiB growth reserved (size 16.0 GiB from swap= in $conf; file now 3.0 GiB at $g1/swap.vhdx)" "plain status names the swap line's source"
  out=$(TEST_SWAP_DISCOVER=1 run_room check --expect-write 30G); rc=$?
  expect_code 1 "$rc" "admission counts the swap file's growth"
  assert_contains "$out" "on $HOSTDIR" "the low line names the drive"
  rm -f "$g1/swap.vhdx"
  mkdir -p "$g2"
  truncate -s $(( 5 * GIB )) "$g2/swap.vhdx"
  out=$(FM_DISK_ROOM_WSLCONFIG="$conf" run_room status --json)
  assert_equals $(( 11 * GIB )) "$(json_field "$out" swap_reserved)" "a vanished cached swap file is looked up again"
  truncate -s $(( 15 * GIB )) "$g2/swap.vhdx"
  touch -d "@$(( $(date +%s) - 7200 ))" "$g2/swap.vhdx"
  mkdir -p "$g3"
  truncate -s $(( 1 * GIB )) "$g3/swap.vhdx"
  out=$(FM_DISK_ROOM_WSLCONFIG="$conf" run_room status --json)
  assert_equals $(( 15 * GIB )) "$(json_field "$out" swap_file_size)" "the cached swap file holds for the same VM boot"
  printf 'next-boot\n' >"$TMP_ROOT/boot_id"
  out=$(FM_DISK_ROOM_WSLCONFIG="$conf" run_room status --json)
  assert_equals $(( 1 * GIB )) "$(json_field "$out" swap_file_size)" "after a new VM boot the new swap file wins over a leftover from an unclean exit"
  assert_equals $(( 15 * GIB )) "$(json_field "$out" swap_reserved)" "the current swap file's growth is reserved, not the leftover's"
  rm -rf "$g3" "$TMP_ROOT/boot_id"
  truncate -s $(( 5 * GIB )) "$g2/swap.vhdx"
  touch "$g2/swap.vhdx"
  printf '[wsl2]\r\nmemory=16GB\r\n[experimental]\r\nswap=99GB\r\n' >"$conf"
  out=$(FM_DISK_ROOM_WSLCONFIG="$conf" run_room status --json)
  assert_equals '"default"' "$(json_field "$out" swap_source)" "swap= outside [wsl2] leaves the WSL default"
  assert_equals $(( 4 * GIB )) "$(json_field "$out" swap_size)" "the default is a quarter of memory="
  assert_equals 0 "$(json_field "$out" swap_reserved)" "a swap file past the default size reserves nothing"
  rm -f "$conf"
  printf 'MemTotal:       8000000 kB\n' >"$TMP_ROOT/meminfo"
  truncate -s $(( 1 * GIB )) "$g2/swap.vhdx"
  out=$(FM_DISK_ROOM_WSLCONFIG="$conf" run_room status --json)
  assert_equals '"default"' "$(json_field "$out" swap_source)" "with no .wslconfig the WSL default applies"
  assert_equals $(( 2 * GIB )) "$(json_field "$out" swap_size)" "the default is a quarter of Linux memory rounded up to a GiB"
  assert_equals $(( 1 * GIB )) "$(json_field "$out" swap_reserved)" "the default size minus the file is reserved"
  assert_equals $(( 59 * GIB )) "$(json_field "$out" room)" "room drops by the default's remaining growth"
  out=$(FM_DISK_ROOM_WSLCONFIG="$conf" run_room status)
  assert_contains "$out" "swap file: 1.0 GiB growth reserved (size 2.0 GiB, the WSL default of a quarter of 7.6 GiB memory rounded up, since swap= is unset in $conf" "plain status names the default"
  printf '[wsl2]\r\nswap=0\r\n' >"$conf"
  out=$(FM_DISK_ROOM_WSLCONFIG="$conf" run_room status --json)
  assert_equals '"off"' "$(json_field "$out" swap_source)" "swap=0 means no swap file"
  assert_equals 0 "$(json_field "$out" swap_reserved)" "swap=0 reserves nothing"
  assert_equals $(( 60 * GIB )) "$(json_field "$out" room)" "swap=0 leaves room unchanged"
  out=$(FM_DISK_ROOM_WSLCONFIG="$conf" run_room status)
  assert_contains "$out" "swap file: not reserved (swap=0 in $conf" "plain status names swap=0"
  mkdir -p "$HOSTDIR/swap"
  truncate -s $(( 2 * GIB )) "$HOSTDIR/swap/wsl.vhdx"
  printf '[wsl2]\r\nswap=8GB\r\nswapFile=C:\\\\swap\\\\wsl.vhdx\r\n' >"$conf"
  out=$(FM_DISK_ROOM_WSLCONFIG="$conf" run_room status --json)
  assert_equals $(( 2 * GIB )) "$(json_field "$out" swap_file_size)" "swapFile= on the drive is read through its mount"
  assert_equals $(( 6 * GIB )) "$(json_field "$out" swap_reserved)" "swapFile='s remaining growth is reserved"
  printf '[wsl2]\r\nswap=8GB\r\nswapFile=D:\\\\swap.vhdx\r\n' >"$conf"
  out=$(FM_DISK_ROOM_WSLCONFIG="$conf" run_room status --json)
  assert_equals '"other-drive"' "$(json_field "$out" swap_source)" "a swapFile= on another drive is named"
  assert_equals 0 "$(json_field "$out" swap_reserved)" "a swapFile= on another drive reserves nothing here"
  printf '[wsl2]\r\nswap=8GB\r\nswapFile=C:\\\\missing.vhdx\r\n' >"$conf"
  out=$(FM_DISK_ROOM_WSLCONFIG="$conf" run_room status --json)
  assert_equals $(( 8 * GIB )) "$(json_field "$out" swap_reserved)" "a swap file not found reserves the whole size"
  out=$(run_room status --json)
  assert_equals '"disabled"' "$(json_field "$out" swap_source)" "an empty FM_DISK_ROOM_WSLCONFIG disables the reservation"
  assert_equals 0 "$(json_field "$out" swap_reserved)" "a disabled reservation reserves nothing"
  rm -rf "$conf" "$HOSTDIR/Users/u/AppData/Local/Temp" "$HOSTDIR/swap" "$TMP_ROOT/meminfo"
  pass "the WSL swap file's remaining growth is reserved from the drive"
}

test_shadow_no_data_unchanged() {
  reset_state
  set_sizes 60 600 400
  local out
  out=$(run_room status --json)
  assert_equals $(( 60 * GIB )) "$(json_field "$out" room)" "no record and no cap leaves room as plain df"
  assert_equals 0 "$(json_field "$out" shadow_reserved)" "nothing is reserved"
  assert_equals '"none"' "$(json_field "$out" shadow_source)" "the source is none"
  out=$(FM_DISK_ROOM_WEVTUTIL=/nonexistent/wevtutil run_room status --json) || fail "a missing wevtutil does not fail"
  assert_equals null "$(json_field "$out" shadow_events)" "the event count is unknown without wevtutil"
  pass "with no shadow storage data room is unchanged"
}

test_shadow_cycling_warning() {
  reset_state
  set_sizes 15 600 400
  write_events 25 36 33
  local out t0
  t0=$(date +%s)
  out=$(FM_DISK_ROOM_NOW=$t0 run_room status)
  assert_contains "$out" "shadow storage cycling: 3 volsnap event(s) 25/33/36 in the last 7 days" "recent events warn"
  out=$(FM_DISK_ROOM_NOW=$t0 run_room watch-line)
  assert_contains "$out" "shadow storage cycling: 3 volsnap" "the low watcher line carries the warning"
  assert_equals 1 "$(wc -l <"$EVENTS.calls" | tr -d ' ')" "the count is cached for an hour"
  write_events 25
  out=$(FM_DISK_ROOM_NOW=$(( t0 + 3600 )) run_room status --json)
  assert_equals 1 "$(json_field "$out" shadow_events)" "an expired cache is refreshed"
  write_events
  out=$(FM_DISK_ROOM_NOW=$(( t0 + 7200 )) run_room status)
  assert_not_contains "$out" "cycling" "no recent events, no warning"
  rm -f "$EVENTS"
  out=$(FM_DISK_ROOM_NOW=$(( t0 + 10800 )) run_room status) || fail "a failed event read does not fail status"
  assert_not_contains "$out" "cycling" "a failed event read gives no warning"
  reset_state
  write_shadow_record 10 3 60
  write_shadow_live 19 16 15
  write_events 25 36
  out=$(run_room status --json)
  assert_equals 2 "$(json_field "$out" shadow_events)" "events are counted with a fresh record and a live reading present"
  pass "recent volsnap 25/33/36 events warn that shadow storage is cycling"
}

test_shadow_wevtutil_from_drive() {
  reset_state
  set_sizes 15 600 400
  write_events 33 36
  mkdir -p "$HOSTDIR/Windows/System32"
  cp "$FAKEBIN/wevtutil-stub" "$HOSTDIR/Windows/System32/wevtutil.exe"
  local out
  out=$(env -u FM_DISK_ROOM_WEVTUTIL PATH="$FAKEBIN:/usr/bin:/bin" FAKE_DF="$DFDIR" \
    FM_DISK_ROOM_HOST="$HOSTDIR" FM_DISK_ROOM_ROOT="$LINUXDIR" \
    FM_DISK_ROOM_MB_GROUPS="$TMP_ROOT/mb_groups" FM_DISK_ROOM_STATE="$TMP_ROOT/state" \
    FAKE_EVENTS="$EVENTS" "$DISK_ROOM" status --json)
  rm -rf "$HOSTDIR/Windows"
  assert_equals 2 "$(json_field "$out" shadow_events)" "the drive's wevtutil.exe is used when PATH lacks it"
  pass "without wevtutil.exe on PATH the drive's System32 copy counts the events"
}

test_bulk_reservations() {
  reset_state
  set_sizes 60 600 400
  local cfg="$TMP_ROOT/storage" mp="$TMP_ROOT/mnt/d" out rc
  mkdir -p "$cfg" "$mp/lattice-data/tetjet-results"
  printf 'volume-d\n' >"$mp/lattice-data/.lattice-storage-id"
  printf 'uniqueid=volume-d\n' >"$cfg/ssd-identity"
  printf '1 2 0:1 / %s rw - 9p D: rw\n' "$mp" >"$TMP_ROOT/mountinfo"
  printf '%s/lattice-data/tetjet-results/{task}\nformat=lattice-storage-results-root/v1\nactive=ssd\nstate=ok\nssd_letter=D\nssd_fs=exFAT\nssd_id=volume-d\nssd_marker=%s/lattice-data/.lattice-storage-id\nssd_device=999\nchecked_at=%s\n' \
    "$mp" "$mp" "$(date +%s)" >"$cfg/results-root"
  printf '%s\n' $((100 * GIB)) >"$DFDIR/$(key "$mp/lattice-data/tetjet-results").avail"
  run_room reserve c-job 30G >/dev/null
  out=$(run_room reserve-bulk d-job --task job --download 10G --expanded 20G --packaging 20G); rc=$?
  expect_code 0 "$rc" "whole 50G peak leaves exact D margin despite C reservation"
  assert_equals "$mp/lattice-data/tetjet-results/job" "$out" "admission prints only D root"
  out=$(run_room check --expect-write 10G); rc=$?
  expect_code 0 "$rc" "D reservation never consumes C room"
  out=$(run_room reserve-bulk another --task job2 --download 1 --expanded 0 --packaging 0 2>&1); rc=$?
  expect_code 75 "$rc" "concurrent D reservation counts against D room"
  assert_contains "$out" insufficient-space "capacity reason"
  out=$(run_room reserve-bulk d-job --task job --download 0 --expanded 0 --packaging 0 2>&1); rc=$?
  expect_code 75 "$rc" "live reservation not overwritten"
  assert_contains "$out" reservation-exists "reuse reason"
  run_room release-bulk d-job
  out=$(FM_DISK_ROOM_NOW=$(( $(date +%s) + 10 )) run_room reserve-bulk expiring --task job --download 1G --expanded 1G --packaging 1G --ttl 1); rc=$?
  expect_code 0 "$rc" "ttl admission"
  out=$(FM_DISK_ROOM_NOW=$(( $(date +%s) + 12 )) run_room reserve-bulk replacement --task job --download 10G --expanded 20G --packaging 20G); rc=$?
  expect_code 0 "$rc" "expired D reservations lapse"
  run_room release-bulk replacement
  out=$(run_room reserve-bulk missing --task job --download 10G --expanded 20G 2>&1); rc=$?
  expect_code 2 "$rc" "all peak components required"
  out=$(run_room reserve-bulk too-big --task job --download 10G --expanded 21G --packaging 20G 2>&1); rc=$?
  expect_code 75 "$rc" "expanded allocation included in peak"
  # Exercise publisher's integrated entry point and shared reservation owner.
  out=$(PATH="$FAKEBIN:$PATH" FAKE_DF="$DFDIR" FAKE_BULK_MNT="$TMP_ROOT/mnt" \
    FM_STORAGE_CONFIG="$cfg" FM_STORAGE_MNT="$TMP_ROOT/mnt" FM_STORAGE_MOUNTINFO="$TMP_ROOT/mountinfo" \
    FM_DISK_ROOM_STATE="$TMP_ROOT/state" "$ROOT/bin/fm-storage.sh" bulk-root job --name integrated \
    --download 10G --expanded 20G --packaging 20G --pid "$$"); rc=$?
  expect_code 0 "$rc" "storage bulk-root reserves before answering"
  assert_equals "$mp/lattice-data/tetjet-results/job" "$out" "integrated root"
  run_room release-bulk integrated
  mkdir -p "$mp/lattice-data/research"
  out=$(PATH="$FAKEBIN:$PATH" FAKE_DF="$DFDIR" FAKE_BULK_MNT="$TMP_ROOT/mnt" \
    FM_STORAGE_CONFIG="$cfg" FM_STORAGE_MNT="$TMP_ROOT/mnt" FM_STORAGE_MOUNTINFO="$TMP_ROOT/mountinfo" \
    FM_DISK_ROOM_STATE="$TMP_ROOT/state" "$ROOT/bin/fm-storage.sh" bulk-root --root research job --name integrated \
    --download 10G --expanded 20G --packaging 20G --pid "$$"); rc=$?
  expect_code 0 "$rc" "research bulk-root reserves in the same D pool"
  assert_equals "$mp/lattice-data/research/job" "$out" "integrated research root"
  out=$(run_room reserve-bulk after-research --task job2 --download 1 --expanded 0 --packaging 0 2>&1); rc=$?
  expect_code 75 "$rc" "the research reservation counts against D room"
  rm "$cfg/results-root"
  out=$(run_room reserve-bulk no-volume --task job --download 0 --expanded 0 --packaging 0 2>&1); rc=$?
  expect_code 75 "$rc" "no publication never creates C reservation"
  run_room release-bulk integrated || fail "release works with D absent"
  out=$(run_room check --expect-write 10G); rc=$?
  expect_code 0 "$rc" "small/control admission remains unchanged"
  pass "D and C reservations are independent and full allocation peak is admitted"
}

# write_samples END_EPOCH DAYS STEP_SECONDS GIB_PER_DAY: fm-io-sample lines whose
# Linux and C: used bytes grow at the given rate, ending at END_EPOCH.
write_samples() {
  awk -v end="$1" -v days="$2" -v step="$3" -v rate="$4" -v g="$GIB" 'BEGIN {
    for (t = end - days * 86400; t <= end; t += step) {
      u = 400 * g + (t - (end - days * 86400)) * rate * g / 86400
      printf "{\"ts\":%d,\"io_some_avg10\":1.00,\"root_used\":%.0f,\"mntc_used\":%.0f,\"disk\":\"sdd\"}\n", t, u, u + 100 * g
    }
    print "{\"ts\":" end ",\"broken"
  }' >"$TMP_ROOT/samples.jsonl"
}

test_growth_alerts() {
  reset_state
  set_sizes 60 600 400
  local out t0
  t0=$(date +%s)
  write_samples "$t0" 8 21600 2
  export TEST_SAMPLES="$TMP_ROOT/samples.jsonl" FM_DISK_ROOM_C_FREE_MIN=100G
  out=$(FM_DISK_ROOM_NOW=$t0 run_room watch-line)
  assert_contains "$out" "storage alert: Linux used grew 2.00 GiB/day over the last 7.0 days (limit 0.5 GiB/day" "fast weekly growth alerts"
  assert_contains "$out" "; $HOSTDIR has 60.0 GiB actually free (floor 100.0 GiB)" "C: under its floor alerts in the same line"
  assert_not_contains "$out" "disk room low" "room above the margin stays quiet"
  out=$(FM_DISK_ROOM_NOW=$(( t0 + 300 )) run_room watch-line)
  assert_equals "" "$out" "standing alerts are not repeated"
  set_sizes 150 600 400
  out=$(FM_DISK_ROOM_NOW=$(( t0 + 600 )) run_room watch-line)
  assert_equals "storage alert cleared: c runway" "$out" "a recovered C: reports once"
  out=$(FM_DISK_ROOM_NOW=$(( t0 + 900 )) run_room growth) || fail "growth exits 0"
  assert_contains "$out" "last week +14.0 GiB over 7.0 days (2.00 GiB/day)" "weekly Linux change is reported"
  assert_contains "$out" "last day +2.0 GiB over 1.0 days (2.00 GiB/day)" "daily Linux change is reported"
  assert_contains "$out" "ALERT growth: Linux used grew 2.00 GiB/day" "the report shows the alert"
  assert_contains "$out" "ok c runway" "the report shows clear alerts"
  assert_contains "$out" "thresholds: growth 0.5 GiB/day, C: free 100.0 GiB, D: free after reservations 50.0 GiB" "the report names the thresholds"
  out=$(FM_DISK_ROOM_GROWTH_MAX=3G FM_DISK_ROOM_NOW=$(( t0 + 1200 )) run_room watch-line)
  assert_equals "storage alert cleared: growth" "$out" "a raised growth limit clears the alert"
  out=$(FM_DISK_ROOM_NOW=$(( t0 + 3 * 3600 )) run_room watch-line)
  assert_equals "" "$out" "stale samples leave the growth alert unchanged"
  write_samples "$t0" 3 21600 2
  out=$(FM_DISK_ROOM_NOW=$t0 run_room growth)
  assert_contains "$out" "unknown growth" "under six days of samples gives no weekly verdict"
  set_sizes 15 600 400
  out=$(FM_DISK_ROOM_C_FREE_MIN=bogus FM_DISK_ROOM_NOW=$(( t0 + 1500 )) run_room watch-line)
  assert_contains "$out" "disk room low: 15.0 GiB" "the room alert still speaks"
  assert_contains "$out" " | storage alerts: cannot evaluate (bad FM_DISK_ROOM_C_FREE_MIN)" "a bad threshold is reported"
  out=$(FM_DISK_ROOM_C_FREE_MIN=bogus FM_DISK_ROOM_NOW=$(( t0 + 1800 )) run_room watch-line)
  assert_equals "" "$out" "the same bad threshold is reported once"
  out=$(FM_DISK_ROOM_NOW=$(( t0 + 2100 )) run_room watch-line)
  assert_contains "$out" "storage alert: $HOSTDIR has 15.0 GiB actually free (floor 100.0 GiB)" "C: alert after the threshold is fixed"
  unset TEST_SAMPLES FM_DISK_ROOM_C_FREE_MIN
  pass "growth and C: runway alerts speak once per change and growth reports daily and weekly values"
}

test_c_runway_reclaim() {
  reset_state
  set_sizes 60 600 400
  write_vhdx 470 0 0 0 0
  write_mb_groups 10
  local out t0
  t0=$(date +%s)
  out=$(FM_DISK_ROOM_C_FREE_MIN=100G FM_DISK_ROOM_NOW=$t0 run_room watch-line)
  assert_contains "$out" "storage alert: $HOSTDIR has 60.0 GiB actually free (floor 100.0 GiB)" "C: under its floor alerts"
  assert_not_contains "$out" "a compaction could return" "ext4 slack without block table holes is not offered as runway"
  reset_state
  write_vhdx 470 $(( 9 * 1024 ))
  out=$(FM_DISK_ROOM_C_FREE_MIN=100G FM_DISK_ROOM_NOW=$t0 run_room watch-line)
  assert_contains "$out" "actually free (floor 100.0 GiB); a compaction could return about 9.0 GiB" "the runway alert offers the block table figure"
  pass "the C: runway alert offers only what the disk file's block table can give back"
}

test_d_runway_and_substitution() {
  reset_state
  rm -rf "${TMP_ROOT:?}/storage" "${TMP_ROOT:?}/mnt"
  set_sizes 60 600 400
  truncate -s $(( 470 * GIB )) "$VHDX"
  local cfg="$TMP_ROOT/storage" mp="$TMP_ROOT/mnt/d" out t0 rootdev
  t0=$(date +%s)
  mkdir -p "$cfg" "$mp/lattice-data/tetjet-results"
  printf 'volume-d\n' >"$mp/lattice-data/.lattice-storage-id"
  printf 'uniqueid=volume-d\n' >"$cfg/ssd-identity"
  printf '1 2 0:1 / %s rw - 9p D: rw\n' "$mp" >"$TMP_ROOT/mountinfo"
  printf '%s/lattice-data/tetjet-results/{task}\nformat=lattice-storage-results-root/v1\nactive=ssd\nstate=ok\nssd_letter=D\nssd_fs=exFAT\nssd_id=volume-d\nssd_marker=%s/lattice-data/.lattice-storage-id\nssd_device=999\nssd_free_bytes=%s\nchecked_at=%s\n' \
    "$mp" "$mp" $(( 500 * GIB )) "$t0" >"$cfg/results-root"
  printf '%s\n' $(( 100 * GIB )) >"$DFDIR/$(key "$mp/lattice-data/tetjet-results").avail"
  run_room reserve-bulk d-job --task job --download 10G --expanded 20G --packaging 20G >/dev/null || fail "bulk admission"
  out=$(FM_DISK_ROOM_NOW=$t0 run_room watch-line)
  assert_equals "" "$out" "D: at its floor after reservations is not an alert"
  out=$(FM_DISK_ROOM_D_FREE_MIN=60G FM_DISK_ROOM_NOW=$(( t0 + 300 )) run_room watch-line)
  assert_equals "storage alert: D: has 50.0 GiB after 50.0 GiB of reservations (floor 60.0 GiB)" "$out" "live D: free minus reservations under the floor alerts"
  out=$(FM_DISK_ROOM_NOW=$(( t0 + 600 )) run_room growth)
  assert_contains "$out" "D: free 100.0 GiB (live), reserved 50.0 GiB, after reservations 50.0 GiB" "the report shows D: room and reservations"
  run_room release-bulk d-job
  rootdev=$(stat -c %d -- "$LINUXDIR")
  out=$(FAKE_BULK_DEVICE=$rootdev FM_DISK_ROOM_NOW=$(( t0 + 900 )) run_room watch-line)
  assert_contains "$out" "mandatory D: bulk substituted Linux storage: $mp/lattice-data is on the Linux disk" "a D: path on the Linux disk alerts"
  assert_contains "$out" "cleared: d runway" "the released reservation clears the D: alert in the same line"
  out=$(FAKE_BULK_DEVICE=$rootdev FM_DISK_ROOM_NOW=$(( t0 + 1200 )) run_room growth)
  assert_contains "$out" "D: free 500.0 GiB (published)" "an unverified D: falls back to the published reading"
  out=$(FM_DISK_ROOM_NOW=$(( t0 + 1500 )) run_room watch-line)
  assert_equals "storage alert cleared: d substitution" "$out" "the substitution clears once D: is back"
  mkdir -p "$TMP_ROOT/state/reservations-d/$rootdev"
  printf 'bytes=1\nexpires=%s\n' $(( t0 + 99999 )) >"$TMP_ROOT/state/reservations-d/$rootdev/stray"
  out=$(FM_DISK_ROOM_NOW=$(( t0 + 1800 )) run_room watch-line)
  assert_contains "$out" "live D: reservations are charged to filesystem $rootdev, which is the Linux disk" "a D: pool on the Linux disk alerts"
  truncate -s $(( 473 * GIB )) "$VHDX"
  printf '%s\n' $(( 90 * GIB )) >"$DFDIR/$(key "$mp/lattice-data/tetjet-results").avail"
  out=$(FM_DISK_ROOM_NOW=$(( t0 + 86400 )) run_room watch-line)
  out=$(FM_DISK_ROOM_NOW=$(( t0 + 86400 )) run_room growth)
  assert_contains "$out" "disk file: 473.0 GiB; last day +3.0 GiB over 1.0 days" "the disk file's daily change comes from the hourly history"
  assert_contains "$out" "free last day -10.0 GiB over 1.0 days" "D: free's daily change comes from the hourly history"
  out=$(printf '%s\n' "$out" | FM_USAGE_NOW=$(( t0 + 86400 )) "$ROOT/bin/fm-usage-report.sh" d-line --from -) || fail "d-line reads the growth report"
  assert_contains "$out" "D: 90.0 GiB free (live) at " "the D: line carries growth's D: free"
  assert_contains "$out" "last day -10.00 GiB/day: full in 9.0 days ($(date -u -d "@$(( t0 + 86400 + 9 * 86400 ))" +%Y-%m-%d))" "the D: line turns growth's daily rate into days to full"
  rm -rf "$TMP_ROOT/state/reservations-d/$rootdev" "$cfg/results-root"
  pass "D: runway and Linux substitution alerts, with disk file and D: history"
}

# Consumers pin interface v1, not the script's bytes, so this case pins v1's
# commands, fields, units and exit codes through the executable. A version
# other than v1 fails here until its own contract case is added, so the
# interface cannot drift without a version bump.
V1_FIELDS='margin:int linux_free:int linux_used:int reserved:int shadow_reserved:int swap_reserved:int room:int
  host_free:opt vhdx_size:opt fragmented_free:opt fs_overhead:opt slack:opt reclaimable:opt
  ssd_free:opt ssd_total:opt shadow_max:opt shadow_used:opt shadow_allocated:opt shadow_events:opt
  swap_size:opt swap_file_size:opt trim_reclaimable:opt
  low:bool host:str vhdx:str results_active:str results_state:str shadow_source:str shadow_reading:str swap_source:str'

# v1_value JSON KEY: a field's raw value, quotes kept on strings (which may hold braces).
v1_value() {
  printf '%s\n' "$1" | sed -n -e "s/.*[{,]\"$2\":\(\"[^\"]*\"\).*/\1/p;t" -e "s/.*[{,]\"$2\":\([^,}]*\).*/\1/p"
}

test_interface_v1_contract() {
  reset_state
  set_sizes 60 600 400
  truncate -s $(( 470 * GIB )) "$VHDX"
  write_mb_groups 30
  write_shadow_live 10 4 3
  local out rc spec key v
  out=$(run_room --interface v1); rc=$?
  expect_code 0 "$rc" "--interface v1 exits 0"
  assert_equals "fm-disk-room-interface/v1" "$out" "v2 still explicitly serves v1"
  out=$(run_room status --json); rc=$?
  expect_code 0 "$rc" "status --json exits 0"
  assert_equals 1 "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" "status --json is one line"
  for spec in $V1_FIELDS; do
    key=${spec%%:*}
    v=$(v1_value "$out" "$key")
    case "${spec#*:}" in
      int) [[ "$v" =~ ^-?[0-9]+$ ]] ;;
      opt) [[ "$v" =~ ^(null|[0-9]+)$ ]] ;;
      bool) [[ "$v" =~ ^(true|false)$ ]] ;;
      str) [[ "$v" =~ ^\".*\"$ ]] ;;
    esac || fail "status --json field $key is not ${spec#*:}: '$v'"
  done
  assert_equals $(( 20 * GIB )) "$(json_field "$out" margin)" "margin is bytes"
  assert_equals $(( 60 * GIB )) "$(json_field "$out" host_free)" "host_free is the drive's free bytes"
  assert_equals $(( 600 * GIB )) "$(json_field "$out" linux_free)" "linux_free is bytes"
  assert_equals $(( 400 * GIB )) "$(json_field "$out" linux_used)" "linux_used is bytes"
  assert_equals $(( 6 * GIB )) "$(json_field "$out" shadow_reserved)" "shadow_reserved is cap minus allocated, in bytes"
  assert_equals $(( 10 * GIB )) "$(json_field "$out" shadow_max)" "shadow_max is bytes"
  assert_equals $(( 4 * GIB )) "$(json_field "$out" shadow_allocated)" "shadow_allocated is bytes"
  assert_equals $(( 3 * GIB )) "$(json_field "$out" shadow_used)" "shadow_used is bytes"
  assert_equals '"live"' "$(json_field "$out" shadow_reading)" "shadow_reading names the live source"
  assert_equals '"live"' "$(json_field "$out" shadow_source)" "shadow_source names the live source"
  assert_equals 0 "$(json_field "$out" swap_reserved)" "swap_reserved is bytes, none with the reservation disabled"
  assert_equals '"disabled"' "$(json_field "$out" swap_source)" "swap_source names why nothing is reserved"
  assert_equals $(( 54 * GIB )) "$(json_field "$out" room)" "room is host free minus shadow headroom, in bytes"
  assert_equals false "$(json_field "$out" low)" "low is false at or above the margin"
  assert_equals "\"$HOSTDIR\"" "$(v1_value "$out" host)" "host is the drive mount"
  assert_equals "\"$VHDX\"" "$(v1_value "$out" vhdx)" "vhdx is the disk file path"
  assert_equals $(( 470 * GIB )) "$(json_field "$out" vhdx_size)" "vhdx_size is bytes"
  assert_equals $(( 70 * GIB )) "$(json_field "$out" slack)" "slack is bytes"
  out=$(run_room reserve contract-job 2G); rc=$?
  expect_code 0 "$rc" "reserve exits 0"
  assert_contains "$out" "reserved contract-job: " "reserve names the reservation"
  out=$(run_room status --json)
  assert_equals $(( 2 * GIB )) "$(json_field "$out" reserved)" "reserved is bytes"
  assert_equals $(( 52 * GIB )) "$(json_field "$out" room)" "room subtracts reservations"
  run_room release contract-job; rc=$?
  expect_code 0 "$rc" "release exits 0"
  run_room release never-reserved; rc=$?
  expect_code 0 "$rc" "release of an unknown name exits 0"
  run_room release 'bad/name' 2>/dev/null; rc=$?
  expect_code 2 "$rc" "release of an invalid name is misuse"
  run_room reserve contract-job lots >/dev/null 2>&1; rc=$?
  expect_code 2 "$rc" "reserve with a bad size is misuse"

  out=$(run_room check --expect-write 34G); rc=$?
  expect_code 0 "$rc" "check exits 0 when the margin holds"
  assert_equals "ok: " "${out:0:4}" "check's admitted line starts ok:"
  out=$(run_room check --expect-write 35G); rc=$?
  expect_code 1 "$rc" "check exits 1 under the margin"
  assert_equals "low: " "${out:0:5}" "check's refused line starts low:"
  out=$(TEST_HOST="$TMP_ROOT/missing" run_room check --expect-write 1G 2>/dev/null); rc=$?
  expect_code 2 "$rc" "check exits 2 when a reading fails"
  assert_contains "$out" "cannot measure disk room: " "an unreadable check says so on stdout"
  run_room check --expect-write 1G --bogus >/dev/null 2>&1; rc=$?
  expect_code 2 "$rc" "check misuse exits 2"
  TEST_HOST="$TMP_ROOT/missing" run_room status --json >/dev/null 2>&1; rc=$?
  expect_code 2 "$rc" "status --json exits 2 when a reading fails"
  run_room status >/dev/null; rc=$?
  expect_code 0 "$rc" "plain status exits 0"

  run_room run --name contract-run --expect-write 1G -- sh -c 'exit 7' >/dev/null 2>&1; rc=$?
  expect_code 7 "$rc" "an admitted run returns the command's own status"
  out=$(run_room run --name contract-run --expect-write 35G -- sh -c 'echo ran' 2>&1 >/dev/null); rc=$?
  expect_code 75 "$rc" "a run under the margin exits 75"
  assert_equals "fm-disk-room: refused contract-run: " "${out:0:36}" "a refused run says so on stderr"
  assert_equals 1 "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" "a refusal is one stderr line"
  TEST_HOST="$TMP_ROOT/missing" run_room run --name contract-run --expect-write 1G -- true >/dev/null 2>&1; rc=$?
  expect_code 75 "$rc" "a run with an unreadable reading exits 75"
  run_room run --name contract-run -- true >/dev/null 2>&1; rc=$?
  expect_code 2 "$rc" "run misuse exits 2"

  out=$(FM_DISK_ROOM_RESULTS_ROOT="$TMP_ROOT/no-results-root" run_room reserve-bulk contract-bulk --task t \
    --download 1G --expanded 1G --packaging 1G 2>&1 >/dev/null); rc=$?
  expect_code 75 "$rc" "reserve-bulk without verified D: storage exits 75"
  case "$out" in "fm-disk-room: wait: "?*|"fm-storage: wait: "?*) ;; *) fail "reserve-bulk's wait line names a reason: '$out'" ;; esac
  run_room reserve-bulk contract-bulk --task t >/dev/null 2>&1; rc=$?
  expect_code 2 "$rc" "reserve-bulk misuse exits 2"
  run_room release-bulk contract-bulk; rc=$?
  expect_code 0 "$rc" "release-bulk exits 0"
  run_room release-bulk >/dev/null 2>&1; rc=$?
  expect_code 2 "$rc" "release-bulk misuse exits 2"

  out=$(run_room watch-line); rc=$?
  expect_code 0 "$rc" "watch-line exits 0 above the margin"
  assert_equals "" "$out" "watch-line is silent above the margin"
  out=$(FM_DISK_ROOM_MARGIN=100G run_room watch-line); rc=$?
  expect_code 0 "$rc" "watch-line exits 0 under the margin"
  assert_equals "disk room low: " "${out:0:15}" "watch-line's low line starts disk room low:"
  out=$(TEST_HOST="$TMP_ROOT/missing" run_room watch-line); rc=$?
  expect_code 0 "$rc" "watch-line exits 0 when a reading fails"
  assert_equals "disk room: cannot measure" "${out:0:25}" "watch-line's error line starts disk room: cannot measure"
  run_room growth >/dev/null; rc=$?
  expect_code 0 "$rc" "growth exits 0"
  run_room growth extra >/dev/null 2>&1; rc=$?
  expect_code 2 "$rc" "growth misuse exits 2"
  run_room --interface v1 extra >/dev/null 2>&1; rc=$?
  expect_code 2 "$rc" "--interface misuse exits 2"
  pass "interface v1: commands, fields, units and exit codes hold through the executable"
}

# Pinned consumers hash the helper and run those bytes as bash -c TEXT PATH,
# from any working directory; only the digest-matched reader beside PATH may run.
test_pinned_mode() {
  local out rc cwd="$TMP_ROOT/cwd" tbin="$TMP_ROOT/tbin" planted
  mkdir -p "$cwd" "$tbin"
  planted="import sys; open('$TMP_ROOT/planted-ran', 'w').close(); print('reclaimable=123456789 present=0 fixed=0')"
  printf '%s\n' "$planted" >"$cwd/fm-vhdx-bat.py"
  set_sizes 60 600 400
  write_vhdx 470 $(( 12 * 1024 ))
  write_mb_groups 30
  assert_equals "$(sha256sum "$ROOT/bin/fm-vhdx-bat.py" | cut -d' ' -f1)" \
    "$(sed -n 's/^VHDX_BAT_SHA256=//p' "$DISK_ROOM")" "the helper embeds the digest of the reader it ships with"
  reset_state; rm -f "$TMP_ROOT/planted-ran"
  out=$(cd "$cwd" && ROOM_CMD=(bash -c "$(cat "$DISK_ROOM")" "$DISK_ROOM") && run_room status --json) || fail "pinned status exits 0"
  assert_equals "" "$(ls "$TMP_ROOT/planted-ran" 2>/dev/null)" "a reader planted in the working directory never runs"
  assert_equals $(( 12 * GIB )) "$(json_field "$out" reclaimable)" "pinned mode reads the block table with the shipped reader"
  cp "$DISK_ROOM" "$tbin/fm-disk-room.sh"
  { cat "$ROOT/bin/fm-vhdx-bat.py"; printf '%s\n' "$planted"; } >"$tbin/fm-vhdx-bat.py"
  reset_state; rm -f "$TMP_ROOT/planted-ran"
  out=$(ROOM_CMD=("$tbin/fm-disk-room.sh") && run_room status --json) || fail "status with a tampered reader exits 0"
  assert_equals "" "$(ls "$TMP_ROOT/planted-ran" 2>/dev/null)" "a tampered reader beside the helper never runs"
  assert_equals null "$(json_field "$out" reclaimable)" "a tampered reader leaves reclaimable unknown"
  reset_state
  out=$(cd "$cwd" && ROOM_CMD=(bash -c "$(cat "$tbin/fm-disk-room.sh")" "$tbin/fm-disk-room.sh") && run_room status --json) ||
    fail "pinned status with a tampered reader exits 0"
  assert_equals null "$(json_field "$out" reclaimable)" "pinned mode refuses a tampered reader too"
  rm -f "$tbin/fm-vhdx-bat.py"
  reset_state
  out=$(ROOM_CMD=("$tbin/fm-disk-room.sh") && run_room status --json) || fail "status without a reader exits 0"
  assert_equals null "$(json_field "$out" reclaimable)" "a missing reader leaves reclaimable unknown"
  out=$(cd "$cwd" && TMPDIR="$TMP_ROOT" bash -c "$(cat "$DISK_ROOM")" "$DISK_ROOM" --self-test v1); rc=$?
  expect_code 0 "$rc" "--self-test v1 passes when run as bash -c TEXT PATH"
  assert_contains "$out" "self-test v1 passed" "the pinned-mode self-test says it passed"
  reset_state
  pass "pinned bash -c runs only the digest-matched reader and can self-test"
}

test_self_test() {
  local out rc
  out=$(TMPDIR="$TMP_ROOT" "$DISK_ROOM" --self-test v1); rc=$?
  expect_code 0 "$rc" "--self-test v1 passes on the interface this script serves"
  assert_contains "$out" "self-test v1 passed" "a passing self-test says so"
  assert_equals "" "$(find "$TMP_ROOT" -maxdepth 1 -name 'fm-disk-room-self-test.*')" "the self-test removes its temp state"
  out=$(TMPDIR="$TMP_ROOT" "$DISK_ROOM" --self-test v99); rc=$?
  expect_code 1 "$rc" "--self-test of an unserved version exits 1"
  assert_contains "$out" "serves fm-disk-room-interface/v2" "an unserved version names the latest served"
  TMPDIR="$TMP_ROOT" "$DISK_ROOM" --self-test >/dev/null 2>&1; rc=$?
  expect_code 2 "$rc" "--self-test without a version is misuse"
  pass "--self-test reports whether this script serves the pinned interface"
}

# v2's samples come from real kernel counters, not df deltas or declared sizes.
# The written fixture is small; no test needs a write-heavy job or Windows I/O.
test_interface_v2_history() {
  reset_state
  set_sizes 60 600 400
  local out rc high
  out=$(run_room --interface)
  assert_equals 'fm-disk-room-interface/v2' "$out" "latest interface is v2"
  out=$(run_room write-history seal)
  assert_equals '{"kind":"seal","samples":0,"high_bytes":0}' "$out" "missing history is explicitly empty"
  out=$(run_room check --kind seal); rc=$?
  expect_code 2 "$rc" "a new kind cannot infer a write"
  assert_contains "$out" 'no write history' "the caller must supply a first declaration"
  out=$(run_room run --name missing --kind seal -- sh -c 'echo ran' 2>&1); rc=$?
  expect_code 75 "$rc" "an unmeasured kind refuses an undeclared run"
  assert_not_contains "$out" ran "a refused kind never starts"
  run_room check --kind ../seal --expect-write 1G >/dev/null 2>&1; rc=$?
  expect_code 2 "$rc" "a kind cannot escape state"
  run_room write-history ../seal >/dev/null 2>&1; rc=$?
  expect_code 2 "$rc" "history queries validate their kind"
  run_room write-history seal extra >/dev/null 2>&1; rc=$?
  expect_code 2 "$rc" "history query arity is checked"

  if [ ! -r /proc/$$/io ]; then
    out=$(run_room run --name unsupported --kind seal --expect-write 1M -- sh -c 'echo ran' 2>&1); rc=$?
    expect_code 75 "$rc" "unsupported counters refuse rather than record zero"
    assert_not_contains "$out" ran "unsupported measurement never starts work"
    pass "v2 refuses unsupported storage write accounting; recording cases require Linux procfs"
    return
  fi
  run_room reserve busy 1G --pid "$$" >/dev/null
  out=$(run_room run --name busy --kind seal --expect-write 1M -- sh -c 'echo ran' 2>&1); rc=$?
  expect_code 75 "$rc" "typed runs cannot overwrite a live reservation"
  assert_contains "$out" 'reservation already live' "collision names the reservation guard"
  assert_not_contains "$out" ran "a colliding run never starts"
  run_room release busy
  run_room run --name seal-1 --kind seal --expect-write 1M -- \
    dd if=/dev/zero of="$TMP_ROOT/written" bs=4096 count=8 conv=fsync >/dev/null 2>&1; rc=$?
  expect_code 0 "$rc" "a typed run returns success"
  out=$(run_room write-history seal)
  assert_equals 1 "$(json_field "$out" samples)" "one completed run records one sample"
  high=$(json_field "$out" high_bytes)
  [ "$high" -ge 32768 ] || fail "the recorded bytes include the actual write"
  [ "$high" -lt 1048576 ] || fail "the sample is measured, not the 1M declaration"
  out=$(run_room status --json)
  assert_equals 0 "$(json_field "$out" reserved)" "completion releases the typed reservation"
  out=$(run_room check --kind seal --expect-write 0); rc=$?
  expect_code 1 "$rc" "an understated declaration is refused even with ample room"
  assert_contains "$out" 'below recorded high' "refusal names the historical comparison"
  out=$(run_room run --name understated --kind seal --expect-write 0 -- sh -c 'echo ran' 2>&1); rc=$?
  expect_code 75 "$rc" "run applies the historical check too"
  assert_not_contains "$out" ran "an understated run does not start"
  out=$(run_room check --kind seal --expect-write "$high"); rc=$?
  expect_code 0 "$rc" "a declaration equal to the high is admitted"
  out=$(run_room check --kind seal); rc=$?
  expect_code 0 "$rc" "omitted declarations use the high"
  out=$(run_room run --name seal-2 --kind seal -- sh -c 'cat "$FM_DISK_ROOM_STATE/reservations/seal-2"; exit 7'); rc=$?
  expect_code 7 "$rc" "typed runs preserve a failed command status"
  assert_contains "$out" "bytes=$high" "the inferred high is actually reserved"
  out=$(run_room write-history seal)
  assert_equals 2 "$(json_field "$out" samples)" "failed attempts are recorded too"
  assert_equals "$high" "$(json_field "$out" high_bytes)" "a smaller sample never lowers the high"
  out=$(run_room write-history other)
  assert_equals 0 "$(json_field "$out" samples)" "kinds have separate history"
  out=$(FM_DISK_ROOM_MARGIN=1000G run_room check --kind seal); rc=$?
  expect_code 1 "$rc" "history never bypasses the configured margin"
  out=$(TEST_HOST="$TMP_ROOT/missing" run_room check --kind seal); rc=$?
  expect_code 2 "$rc" "history never bypasses an unreadable disk"
  set_sizes 0 0 400
  out=$(FM_DISK_ROOM_MARGIN=1G run_room run --name full --kind seal -- true 2>&1); rc=$?
  expect_code 75 "$rc" "history never bypasses the ENOSPC floor"
  set_sizes 60 600 400

  # Recording failure after successful work is visible, never a fake success.
  out=$(run_room run --name break-record --kind break-record --expect-write 1M -- \
    sh -c 'mkdir -p "$FM_DISK_ROOM_STATE/write-history/break-record"' 2>&1); rc=$?
  expect_code 74 "$rc" "failure to persist a successful run is an I/O failure"
  assert_contains "$out" 'cannot read write history' "post-command recording failure is surfaced"
  out=$(run_room run --name break-failed --kind break-failed --expect-write 1M -- \
    sh -c 'mkdir -p "$FM_DISK_ROOM_STATE/write-history/break-failed"; exit 9' 2>&1); rc=$?
  expect_code 9 "$rc" "recording failure preserves a nonzero command result"
  assert_contains "$out" 'cannot read write history' "the recording error still speaks on command failure"
  # A failed writer must establish its own nonzero high, not hide behind a
  # larger successful sample (forcing failed samples to zero must fail here).
  out=$(run_room run --name failed-only --kind failed-only --expect-write 1M -- \
    sh -c 'dd if=/dev/zero of="$1" bs=4096 count=16 conv=fsync 2>/dev/null; exit 7' _ "$TMP_ROOT/failed-only" 2>&1); rc=$?
  expect_code 7 "$rc" "a fresh failed writer preserves its command status"
  out=$(run_room write-history failed-only)
  assert_equals 1 "$(json_field "$out" samples)" "a failed writer records its own sample"
  [ "$(json_field "$out" high_bytes)" -ge 65536 ] || fail "failed writes are measured rather than recorded as zero"
  out=$(run_room check --kind failed-only --expect-write 0); rc=$?
  expect_code 1 "$rc" "a failed attempt's high refuses the next understated declaration"
  # Concurrent completions must append, not replace each other's samples.
  run_room run --name parallel-1 --kind parallel --expect-write 1M -- \
    sh -c 'dd if=/dev/zero of="$1" bs=4096 count=8 conv=fsync 2>/dev/null; exit 6' _ "$TMP_ROOT/parallel-1" &
  local p1=$!
  run_room run --name parallel-2 --kind parallel --expect-write 1M -- \
    dd if=/dev/zero of="$TMP_ROOT/parallel-2" bs=4096 count=16 conv=fsync >/dev/null 2>&1 &
  local p2=$!
  wait "$p1"; rc=$?
  expect_code 6 "$rc" "a failed writer retains its result and waits for its child"
  wait "$p2"; rc=$?
  expect_code 0 "$rc" "the concurrent writer completes"
  out=$(run_room write-history parallel)
  assert_equals 2 "$(json_field "$out" samples)" "concurrent completions keep both records"
  [ "$(json_field "$out" high_bytes)" -ge 65536 ] || fail "the high includes the larger writer"
  pass "v2 records storage bytes per kind and gates declarations and inferred reservations"
}

# Positive room alone is not enough: both check and run must subtract the
# resolved history estimate, for inferred and explicit declarations alike.
test_history_capacity_boundary() {
  reset_state
  set_sizes 1 600 400
  local out rc declared
  mkdir -p "$TMP_ROOT/state/write-history"
  printf 'fm-disk-write/v1 1 %s 0\n' "$((2 * GIB))" >"$TMP_ROOT/state/write-history/boundary"
  for declared in inferred explicit; do
    local args=(--kind boundary)
    [ "$declared" != explicit ] || args+=(--expect-write 2G)
    out=$(FM_DISK_ROOM_MARGIN=0 run_room check "${args[@]}"); rc=$?
    expect_code 1 "$rc" "$declared typed check subtracts the high from positive room"
    assert_contains "$out" 'only -1.0 GiB' "check reports post-write room, not pre-write free space"
    assert_contains "$out" 'after a 2.0 GiB write' "check reports the resolved history estimate"
    out=$(FM_DISK_ROOM_MARGIN=0 run_room run --name boundary "${args[@]}" -- sh -c 'echo WRONG_ADMISSION_COMMAND_STARTED' 2>&1); rc=$?
    expect_code 75 "$rc" "$declared typed run also refuses this positive-room boundary"
    if [ -r /proc/$$/io ]; then
      assert_contains "$out" 'only -1.0 GiB' "run also subtracts the resolved estimate before admission"
      assert_contains "$out" 'after a 2.0 GiB write' "run uses the historical high at the capacity boundary"
    fi
    assert_not_contains "$out" WRONG_ADMISSION_COMMAND_STARTED "the boundary refusal never starts work"
  done
  pass "typed check and run subtract historical writes at a positive-room boundary"
}

# This read-error path must run even on Linux with healthy real /proc counters.
test_unavailable_write_counter() {
  reset_state
  set_sizes 60 600 400
  local out rc
  out=$(FM_DISK_ROOM_WRITE_PROC="$TMP_ROOT/absent-proc" run_room run --name counterless --kind counterless --expect-write 1M -- \
    sh -c 'echo COUNTERLESS_COMMAND_STARTED' 2>&1); rc=$?
  expect_code 75 "$rc" "unreadable accounting refuses with a failure status on every host"
  assert_contains "$out" 'cannot measure storage write counter' "counter failure is diagnosed"
  assert_not_contains "$out" COUNTERLESS_COMMAND_STARTED "failed counter reads cannot admit work"
  out=$(run_room write-history counterless)
  assert_equals 0 "$(json_field "$out" samples)" "unreadable accounting cannot create a zero sample"
  # The opt-in accounting source cannot affect untyped v1 execution.
  FM_DISK_ROOM_WRITE_PROC="$TMP_ROOT/absent-proc" run_room run --name legacy --expect-write 1M -- sh -c 'exit 7'; rc=$?
  expect_code 7 "$rc" "v1 does not depend on the typed counter source"
  pass "counter read failures refuse before execution, including on Linux"
}

# Fault the append after its ordinary validation has read the intact old high.
# /dev/full produces deterministic ENOSPC even as root; restoring the old file
# exposes stale-history trust rather than relying on visible file corruption.
test_unrecorded_write_blocks_kind() {
  [ -r /proc/$$/io ] && [ -c /dev/full ] || return 0
  reset_state
  set_sizes 60 600 400
  local out rc result kind token fbin="$TMP_ROOT/append-fault-bin" real_awk
  real_awk=$(command -v awk)
  mkdir -p "$fbin" "$TMP_ROOT/state/write-history"
  cat >"$fbin/awk" <<'SH'
#!/usr/bin/env bash
"$REAL_AWK" "$@"; rc=$?
file=${!#}
if [ "$rc" -eq 0 ] && [ "$file" = "$FAULT_HISTORY" ] && [ -f "$FAULT_ARM" ]; then
  mv -- "$file" "$file.saved"
  ln -s /dev/full "$file"
  rm -- "$FAULT_ARM"
fi
exit "$rc"
SH
  cat >"$fbin/rm" <<'SH'
#!/usr/bin/env bash
if [ -n "${FAULT_RETIRE-}" ] && [ "${!#}" = "$FAULT_RETIRE" ]; then
  touch "$FAULT_RETIRE_HIT"; exit 1
fi
exec /bin/rm "$@"
SH
  chmod +x "$fbin/awk" "$fbin/rm"
  for result in 0 9; do
    kind="append-failed-$result"
    printf 'fm-disk-write/v1 1 0 0\n' >"$TMP_ROOT/state/write-history/$kind"
    out=$(PATH="$fbin:$PATH" REAL_AWK="$real_awk" FAULT_HISTORY="$TMP_ROOT/state/write-history/$kind" FAULT_ARM="$TMP_ROOT/fault-arm" \
      run_room run --name "$kind" --kind "$kind" --expect-write 1M -- \
      sh -c 'dd if=/dev/zero of="$1" bs=4096 count=16 conv=fsync 2>/dev/null; touch "$FAULT_ARM"; exit "$2"' _ "$TMP_ROOT/$kind" "$result" 2>&1); rc=$?
    if [ "$result" -eq 0 ]; then expect_code 74 "$rc" "append ENOSPC after success returns I/O failure"
    else expect_code "$result" "$rc" "append ENOSPC preserves the failed command's status"; fi
    assert_contains "$out" 'cannot record write history' "the actual append failure is surfaced"
    rm -- "$TMP_ROOT/state/write-history/$kind"
    mv -- "$TMP_ROOT/state/write-history/$kind.saved" "$TMP_ROOT/state/write-history/$kind"
    out=$(run_room check --kind "$kind" --expect-write 0); rc=$?
    expect_code 2 "$rc" "an intact stale high cannot authorize an explicit declaration after a lost sample"
    assert_contains "$out" 'unresolved write' "the abandoned attempt is named"
    out=$(run_room check --kind "$kind"); rc=$?
    expect_code 2 "$rc" "an intact stale high cannot authorize an inferred declaration either"
    out=$(run_room run --name next --kind "$kind" --expect-write 0 -- sh -c 'echo WRONG_ADMISSION_COMMAND_STARTED' 2>&1); rc=$?
    expect_code 75 "$rc" "a subsequent typed job stays held after append failure"
    assert_not_contains "$out" WRONG_ADMISSION_COMMAND_STARTED "lost accounting prevents execution"
    run_room write-history "$kind" >/dev/null 2>&1; rc=$?
    expect_code 2 "$rc" "queries cannot present the stale high as authoritative"
    run_room check --expect-write 0 >/dev/null; rc=$?
    expect_code 0 "$rc" "untyped v1 ignores unresolved typed attempts"
    local tokens=("$TMP_ROOT/state/write-pending/$kind/"*)
    assert_equals 1 "${#tokens[@]}" "only the failed attempt remains for recovery"
    token=${tokens[0]##*/}
    # Recovery has the same append-before-retire safety boundary as completion.
    # Bad input or a failed read/append must never consume the recovery target.
    local status
    for status in -1 256 00 invalid; do
      run_room recover-write "$kind" "$token" 1M "$status" >/dev/null 2>&1; rc=$?
      expect_code 2 "$rc" "recovery rejects invalid command status $status"
      assert_present "${tokens[0]}" "invalid recovery input cannot retire an attempt"
    done
    printf 'corrupt\n' >"$TMP_ROOT/state/write-history/$kind"
    out=$(run_room recover-write "$kind" "$token" 1M "$result" 2>&1); rc=$?
    expect_code 2 "$rc" "recovery refuses unreadable history rather than discarding the missing write"
    assert_contains "$out" 'corrupt write history' "recovery diagnoses the failed history validation"
    assert_present "${tokens[0]}" "failed history validation retains the recovery target"
    printf 'fm-disk-write/v1 1 0 0\n' >"$TMP_ROOT/state/write-history/$kind"
    touch "$TMP_ROOT/fault-arm"
    out=$(PATH="$fbin:$PATH" REAL_AWK="$real_awk" FAULT_HISTORY="$TMP_ROOT/state/write-history/$kind" FAULT_ARM="$TMP_ROOT/fault-arm" \
      run_room recover-write "$kind" "$token" 1M "$result" 2>&1); rc=$?
    expect_code 2 "$rc" "recovery append ENOSPC cannot report success"
    assert_contains "$out" 'cannot record write history' "recovery reached the actual append failure"
    assert_present "${tokens[0]}" "recovery append failure cannot retire the attempt"
    assert_not_contains "$out" 'recovered write:' "failed recovery never prints a success notice"
    rm -- "$TMP_ROOT/state/write-history/$kind"
    mv -- "$TMP_ROOT/state/write-history/$kind.saved" "$TMP_ROOT/state/write-history/$kind"
    rm -f "$TMP_ROOT/recovery-retire-hit"
    out=$(PATH="$fbin:$PATH" REAL_AWK="$real_awk" FAULT_RETIRE="${tokens[0]}" FAULT_RETIRE_HIT="$TMP_ROOT/recovery-retire-hit" \
      run_room recover-write "$kind" "$token" 1M "$result" 2>&1); rc=$?
    expect_code 2 "$rc" "recovery token retirement failure cannot report success"
    assert_present "$TMP_ROOT/recovery-retire-hit" "recovery reached the retirement failure"
    assert_contains "$out" 'cannot retire pending write' "recovery cleanup failure is diagnosed"
    assert_present "${tokens[0]}" "cleanup failure retains the token despite its appended sample"
    assert_not_contains "$out" 'recovered write:' "cleanup failure never prints a success notice"
    run_room check --kind "$kind" --expect-write 1M >/dev/null; rc=$?
    expect_code 2 "$rc" "a sample appended by failed recovery cannot bypass its unresolved token"
    out=$(run_room recover-write "$kind" "$token" 1M "$result"); rc=$?
    expect_code 0 "$rc" "evidence-backed recovery records the missing write"
    out=$(run_room write-history "$kind")
    assert_equals 3 "$(json_field "$out" samples)" "retrying recovery retains the old sample and the conservative duplicate from failed cleanup"
    assert_equals 1048576 "$(json_field "$out" high_bytes)" "recovery's conservative observation replaces the stale high"
    out=$(run_room check --kind "$kind"); rc=$?
    expect_code 0 "$rc" "inferred admission resumes only after recovery"
    out=$(run_room check --kind "$kind" --expect-write 1M); rc=$?
    expect_code 0 "$rc" "explicit admission resumes after recovery"
    run_room recover-write "$kind" "$token" 1M "$result" >/dev/null 2>&1; rc=$?
    expect_code 2 "$rc" "replaying recovery cannot duplicate a retired attempt"
  done
  pass "failed appends invalidate intact old highs until evidence-backed recovery"
}

# A readable empty pending directory is not proof that a token can be created.
# Exercise the real permission failure on unprivileged hosts, plus deterministic
# dependency failures (including as root) before any command is allowed to run.
test_pending_creation_refusals() {
  [ -r /proc/$$/io ] && [ -c /dev/full ] || return 0
  reset_state
  set_sizes 60 600 400
  local out rc mode dir="$TMP_ROOT/state/write-pending/creation" fbin="$TMP_ROOT/pending-fault-bin"
  local real_mkdir real_mktemp real_flock
  real_mkdir=$(command -v mkdir)
  real_mktemp=$(command -v mktemp)
  real_flock=$(command -v flock)
  mkdir -p "$dir" "$TMP_ROOT/state/write-history" "$fbin"
  printf 'fm-disk-write/v1 1 0 0\n' >"$TMP_ROOT/state/write-history/creation"
  chmod 0500 "$dir"
  if [ "$(id -u)" -ne 0 ]; then
    out=$(run_room run --name creation --kind creation --expect-write 1M -- \
      sh -c 'touch "$1"' _ "$TMP_ROOT/creation-executed" 2>&1); rc=$?
    chmod 0700 "$dir"
    expect_code 75 "$rc" "pending creation permission failure cannot report command success"
    assert_contains "$out" 'cannot establish pending write' "the failure reaches token creation, not the history or counter guard"
    assert_absent "$TMP_ROOT/creation-executed" "no command runs without a pending token"
    out=$(run_room write-history creation)
    assert_equals 1 "$(json_field "$out" samples)" "creation refusal cannot record a completed job"
    run_room run --name creation --kind creation --expect-write 1M -- sh -c 'touch "$1"' _ "$TMP_ROOT/creation-executed"; rc=$?
    expect_code 0 "$rc" "restoring directory write permission permits the same job"
    assert_present "$TMP_ROOT/creation-executed" "the permission counterfactual actually executes"
    rm -- "$TMP_ROOT/creation-executed"
  else
    chmod 0700 "$dir"
    printf '# root bypasses mode 0500; deterministic pending-creation faults still run\n'
  fi
  cat >"$fbin/mkdir" <<'SH'
#!/usr/bin/env bash
if [ "$FAULT_MODE" = directory ] && [ "${!#}" = "$FAULT_DIR" ]; then
  touch "$FAULT_HIT"; exit 1
fi
exec "$REAL_MKDIR" "$@"
SH
  cat >"$fbin/mktemp" <<'SH'
#!/usr/bin/env bash
if [ "$1" = "$FAULT_DIR/attempt.XXXXXX" ]; then
  case "$FAULT_MODE" in
    temporary) touch "$FAULT_HIT"; exit 1 ;;
    open|marker)
      file=$("$REAL_MKTEMP" "$@") || exit
      rm -- "$file"
      if [ "$FAULT_MODE" = open ]; then mkdir -- "$file"
      else ln -s /dev/full "$file"; fi
      touch "$FAULT_HIT"
      printf '%s\n' "$file"
      exit ;;
  esac
fi
exec "$REAL_MKTEMP" "$@"
SH
  cat >"$fbin/flock" <<'SH'
#!/usr/bin/env bash
if [ "$FAULT_MODE" = lock ] && [ "${!#}" = 8 ]; then
  touch "$FAULT_HIT"; exit 1
fi
exec "$REAL_FLOCK" "$@"
SH
  chmod +x "$fbin/mkdir" "$fbin/mktemp" "$fbin/flock"
  for mode in directory temporary open lock marker; do
    rm -rf -- "$dir"
    mkdir -p "$dir"
    rm -f -- "$TMP_ROOT/pending-fault-hit"
    out=$(PATH="$fbin:$PATH" FAULT_MODE="$mode" FAULT_DIR="$dir" FAULT_HIT="$TMP_ROOT/pending-fault-hit" \
      REAL_MKDIR="$real_mkdir" REAL_MKTEMP="$real_mktemp" REAL_FLOCK="$real_flock" \
      run_room run --name creation --kind creation --expect-write 1M -- \
      sh -c 'touch "$1"' _ "$TMP_ROOT/creation-executed" 2>&1); rc=$?
    expect_code 75 "$rc" "$mode pending establishment failure refuses rather than reporting success"
    assert_present "$TMP_ROOT/pending-fault-hit" "the $mode fault was actually exercised"
    assert_contains "$out" 'cannot establish pending write' "the $mode fault is diagnosed at the creation boundary"
    assert_absent "$TMP_ROOT/creation-executed" "$mode failure cannot start the command"
  done
  pass "pending creation failures return 75 and never execute the command"
}

# Invalid pending state must not look like an empty set of active attempts.
test_unreadable_pending_refusals() {
  local mode out rc pending_root="$TMP_ROOT/state/write-pending"
  for mode in root kind token dangling; do
    reset_state
    set_sizes 60 600 400
    mkdir -p "$TMP_ROOT/state/write-history"
    printf 'fm-disk-write/v1 1 0 0\n' >"$TMP_ROOT/state/write-history/broken-pending"
    case "$mode" in
      root) printf 'not a directory\n' >"$pending_root" ;;
      kind) mkdir -p "$pending_root"; printf 'not a directory\n' >"$pending_root/broken-pending" ;;
      token) mkdir -p "$pending_root/broken-pending/attempt.invalid" ;;
      dangling) mkdir -p "$pending_root/broken-pending"; ln -s "$TMP_ROOT/absent-attempt" "$pending_root/broken-pending/attempt.invalid" ;;
    esac
    out=$(run_room check --kind broken-pending --expect-write 0); rc=$?
    expect_code 2 "$rc" "$mode pending state fails explicit admission even with valid zero history"
    assert_contains "$out" 'cannot read pending' "the $mode pending reading is named"
    run_room check --kind broken-pending >/dev/null; rc=$?
    expect_code 2 "$rc" "$mode pending state also refuses inferred admission"
    out=$(run_room run --name invalid-pending --kind broken-pending --expect-write 1M -- \
      sh -c 'echo INVALID_PENDING_COMMAND_STARTED' 2>&1); rc=$?
    expect_code 75 "$rc" "$mode pending state refuses execution"
    assert_not_contains "$out" INVALID_PENDING_COMMAND_STARTED "invalid pending state cannot start work"
    run_room write-history broken-pending >/dev/null 2>&1; rc=$?
    expect_code 2 "$rc" "queries cannot certify history with $mode pending state"
  done
  pass "unreadable pending roots, kinds and tokens fail closed on every typed interface"
}

# Once a command has run, every completion failure must leave a recoverable
# attempt and preserve a failing command's status rather than losing the hold.
test_pending_completion_failures() {
  [ -r /proc/$$/io ] || return 0
  local mode result out rc token expected samples
  local fbin="$TMP_ROOT/completion-fault-bin" proc="$TMP_ROOT/accounting-proc" real_flock real_rm
  real_flock=$(command -v flock)
  real_rm=$(command -v rm)
  mkdir -p "$fbin"
  cat >"$fbin/flock" <<'SH'
#!/usr/bin/env bash
if [ "$FAULT_MODE" = lock-flock ] && [ "${!#}" = 9 ] && [ -f "$FAULT_ARM" ]; then
  touch "$FAULT_HIT"; exit 1
fi
exec "$REAL_FLOCK" "$@"
SH
  cat >"$fbin/rm" <<'SH'
#!/usr/bin/env bash
if [ "$FAULT_MODE" = retire ] && [[ "${!#}" == "$FM_DISK_ROOM_STATE/write-pending/"* ]]; then
  touch "$FAULT_HIT"; exit 1
fi
exec "$REAL_RM" "$@"
SH
  chmod +x "$fbin/flock" "$fbin/rm"
  for mode in lock-open lock-flock retire counter-missing counter-decreased; do
    for result in 0 9; do
      reset_state
      set_sizes 60 600 400
      mkdir -p "$TMP_ROOT/state/write-history"
      printf 'fm-disk-write/v1 1 0 0\n' >"$TMP_ROOT/state/write-history/completion"
      rm -f "$TMP_ROOT/completion-arm" "$TMP_ROOT/completion-hit"
      out=$(
        ROOM_CMD=(bash -c 'mkdir -p "$FM_DISK_ROOM_WRITE_PROC/$$"; printf "write_bytes: 100\n" >"$FM_DISK_ROOM_WRITE_PROC/$$/io"; exec "$@"' _ "$DISK_ROOM")
        PATH="$fbin:$PATH" FAULT_MODE="$mode" FAULT_ARM="$TMP_ROOT/completion-arm" FAULT_HIT="$TMP_ROOT/completion-hit" \
          REAL_FLOCK="$real_flock" REAL_RM="$real_rm" FM_DISK_ROOM_WRITE_PROC="$proc" \
          run_room run --name completion --kind completion --expect-write 1M -- sh -c '
            touch "$FAULT_ARM"
            case "$FAULT_MODE" in
              lock-open) rm -- "$FM_DISK_ROOM_STATE/.lock"; mkdir "$FM_DISK_ROOM_STATE/.lock"; touch "$FAULT_HIT" ;;
              counter-missing) rm -- "$FM_DISK_ROOM_WRITE_PROC/$PPID/io"; touch "$FAULT_HIT" ;;
              counter-decreased) printf "write_bytes: 99\n" >"$FM_DISK_ROOM_WRITE_PROC/$PPID/io"; touch "$FAULT_HIT" ;;
            esac
            exit "$1"' _ "$result" 2>&1
      ); rc=$?
      expected=$result
      [ "$result" -ne 0 ] || expected=74
      expect_code "$expected" "$rc" "$mode completion failure retains the correct status for command result $result"
      assert_present "$TMP_ROOT/completion-arm" "the command actually ran before $mode failure"
      assert_present "$TMP_ROOT/completion-hit" "the $mode completion fault was reached"
      case "$mode" in
        lock-*) assert_contains "$out" 'cannot lock completed write' "completion lock failure is diagnosed" ;;
        retire) assert_contains "$out" 'cannot retire pending write' "token retirement failure is diagnosed" ;;
        counter-*) assert_contains "$out" 'cannot measure completed write' "completion counter failure is diagnosed" ;;
      esac
      [ "$mode" != lock-open ] || rmdir "$TMP_ROOT/state/.lock"
      local tokens=("$TMP_ROOT/state/write-pending/completion/"*)
      assert_equals 1 "${#tokens[@]}" "$mode failure retains exactly the affected attempt"
      assert_present "${tokens[0]}" "the retained attempt is a real recovery target"
      token=${tokens[0]##*/}
      out=$(run_room check --kind completion --expect-write 0); rc=$?
      expect_code 2 "$rc" "$mode failure cannot authorize a stale explicit zero"
      assert_contains "$out" 'unresolved write' "the failed attempt holds admission"
      run_room check --kind completion >/dev/null; rc=$?
      expect_code 2 "$rc" "$mode failure cannot authorize an inferred write"
      out=$(run_room run --name after-failure --kind completion --expect-write 1M -- sh -c 'echo LOST_HOLD_COMMAND_STARTED' 2>&1); rc=$?
      expect_code 75 "$rc" "$mode completion failure holds subsequent execution"
      assert_not_contains "$out" LOST_HOLD_COMMAND_STARTED "an explicit declaration cannot bypass the retained attempt"
      run_room write-history completion >/dev/null 2>&1; rc=$?
      expect_code 2 "$rc" "$mode failure makes the old history nonauthoritative"
      out=$(run_room recover-write completion "$token" 1M "$result"); rc=$?
      expect_code 0 "$rc" "repair and evidence-backed recovery clear $mode failure"
      out=$(run_room write-history completion)
      samples=2
      [ "$mode" != retire ] || samples=3
      assert_equals "$samples" "$(json_field "$out" samples)" "recovery retains prior appends, including a sample whose cleanup failed"
      assert_equals 1048576 "$(json_field "$out" high_bytes)" "recovery restores a conservative high"
    done
  done
  pass "completion lock, retirement and counter failures preserve status and require recovery"
}

# Keep an actual command active while admitting another of the same kind.
test_live_pending_concurrency() {
  [ -r /proc/$$/io ] || return 0
  reset_state
  set_sizes 60 600 400
  local pid i out rc token
  rm -f "$TMP_ROOT/live-ready" "$TMP_ROOT/live-release"
  mkfifo "$TMP_ROOT/live-release"
  run_room run --name live-1 --kind overlap --expect-write 1M -- \
    sh -c 'touch "$1/live-ready"; read -r release <"$1/live-release"' _ "$TMP_ROOT" &
  pid=$!
  for ((i=0; i<200; i++)); do
    [ ! -f "$TMP_ROOT/live-ready" ] || break
    sleep 0.1
  done
  [ -f "$TMP_ROOT/live-ready" ] || fail "the concurrent fixture command started"
  local tokens=("$TMP_ROOT/state/write-pending/overlap/"*)
  token=${tokens[0]##*/}
  out=$(run_room recover-write overlap "$token" 1M 0 2>&1); rc=$?
  expect_code 2 "$rc" "recovery refuses a still-live attempt"
  assert_contains "$out" 'pending write active' "the live-attempt recovery guard is named"
  run_room run --name live-2 --kind overlap --expect-write 1M -- true; rc=$?
  expect_code 0 "$rc" "a live pending attempt does not serialize same-kind jobs"
  printf 'release\n' >"$TMP_ROOT/live-release"
  wait "$pid"; rc=$?
  expect_code 0 "$rc" "the first overlapping attempt also completes"
  out=$(run_room write-history overlap)
  assert_equals 2 "$(json_field "$out" samples)" "overlapping attempts retain both samples and retire their own tokens"
  pass "live pending attempts permit concurrency but cannot be recovered early"
}

# Stop the real post-command flock helper, then kill only its owned wrapper.
# A surviving helper must not make the dead wrapper's lost sample look live.
# The live-wrapper check is the negative control; killing the orphan must not
# change the already-failed admission. All waits and cleanup are fixture-owned.
test_orphaned_accounting_helper() {
  [ -r /proc/$$/io ] || return 0
  reset_state
  set_sizes 60 600 400
  local out rc probe="$TMP_ROOT/orphan-helper.py"
  mkdir -p "$TMP_ROOT/state/write-history"
  printf 'fm-disk-write/v1 1 0 0\n' >"$TMP_ROOT/state/write-history/orphan-helper"
  cat >"$probe" <<'PY'
import fcntl
import os
from pathlib import Path
import signal
import subprocess
import sys
import time

tool = sys.argv[1]
root = Path(sys.argv[2])
state = Path(os.environ['FM_DISK_ROOM_STATE'])
fifo = root / 'orphan-release'
ready = root / 'orphan-ready'
marker = root / 'orphan-wrong-admission'
os.mkfifo(fifo)
# RDWR prevents a fixture error from blocking the controller on FIFO open.
release = os.open(fifo, os.O_RDWR)
writer = '''import os, sys
from pathlib import Path
root = Path(sys.argv[1])
with open(root / 'orphan-output', 'wb') as f:
    f.write(bytes(65536)); f.flush(); os.fsync(f.fileno())
(root / 'orphan-ready').touch()
with open(root / 'orphan-release') as f:
    f.readline()
'''
wrapper = subprocess.Popen([tool, 'run', '--name', 'orphan-original',
    '--kind', 'orphan-helper', '--expect-write', '1M', '--',
    sys.executable, '-c', writer, str(root)])
helper = None
lock = None

def until(probe, label):
    for _ in range(200):
        value = probe()
        if value:
            return value
        time.sleep(0.1)
    raise AssertionError('timed out: ' + label)

def accounting_child():
    children = Path(f'/proc/{wrapper.pid}/task/{wrapper.pid}/children')
    for pid in children.read_text().split():
        try:
            argv = Path(f'/proc/{pid}/cmdline').read_bytes().split(b'\0')
        except FileNotFoundError:
            continue
        if argv[:4] == [b'flock', b'-w', b'30', b'9'] and argv[4:] == [b'']:
            return int(pid)
    return None

def stopped():
    text = Path(f'/proc/{helper}/stat').read_text()
    return text.rsplit(') ', 1)[1].split()[0] == 'T'

def acquire_lock():
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        return True
    except BlockingIOError:
        return False

def helper_gone():
    try:
        text = Path(f'/proc/{helper}/stat').read_text()
    except FileNotFoundError:
        return True
    return text.rsplit(') ', 1)[1].split()[0] == 'Z'

def invoke(expected, *args):
    result = subprocess.run([tool, *args], capture_output=True, text=True, timeout=40)
    assert result.returncode == expected, (args, result.returncode, result.stdout, result.stderr)
    return result.stdout + result.stderr

def held():
    assert 'unresolved write' in invoke(2, 'write-history', 'orphan-helper')
    for args in [[], ['--expect-write', '0']]:
        assert 'unresolved write' in invoke(2, 'check', '--kind', 'orphan-helper', *args)
    assert 'unresolved write' in invoke(75, 'run', '--name', 'orphan-next',
        '--kind', 'orphan-helper', '--expect-write', '0', '--',
        'touch', str(marker))
    assert not marker.exists(), 'dead wrapper must never authorize another job'

try:
    until(ready.exists, 'writer fsync and ready')
    lock = open(state / '.lock', 'w')
    until(acquire_lock, 'shared lock while writer waits')
    os.write(release, b'release\n')
    helper = until(accounting_child, 'real accounting flock child')
    os.kill(helper, signal.SIGSTOP)
    until(stopped, 'accounting helper stopped')
    fcntl.flock(lock, fcntl.LOCK_UN)
    # Negative control: a living wrapper still permits comparable jobs even
    # while its accounting helper is stopped; no sample has been appended.
    assert '"high_bytes":0' in invoke(0, 'write-history', 'orphan-helper')
    invoke(0, 'check', '--kind', 'orphan-helper', '--expect-write', '0')
    wrapper.kill()
    wrapper.wait(timeout=10)
    held()
    # Changing only the helper's lifetime cannot change the hold anymore.
    os.kill(helper, signal.SIGKILL)
    until(helper_gone, 'orphaned helper exits')
    helper = None
    held()
    tokens = list((state / 'write-pending/orphan-helper').iterdir())
    assert len(tokens) == 1, tokens
    invoke(0, 'recover-write', 'orphan-helper', tokens[0].name, '64K', '0')
    assert '"high_bytes":65536' in invoke(0, 'write-history', 'orphan-helper')
    invoke(1, 'check', '--kind', 'orphan-helper', '--expect-write', '0')
    print('orphaned helper cannot mask wrapper death; live-owner control passed')
finally:
    if lock is not None:
        lock.close()
    os.close(release)
    if helper is not None:
        try:
            os.kill(helper, signal.SIGKILL)
        except ProcessLookupError:
            pass
    # On an early fixture failure, stop the owned writer as well as its wrapper.
    if wrapper.poll() is None:
        children = Path(f'/proc/{wrapper.pid}/task/{wrapper.pid}/children')
        for pid in children.read_text().split():
            try:
                os.kill(int(pid), signal.SIGKILL)
            except ProcessLookupError:
                pass
        wrapper.kill()
    wrapper.wait(timeout=10)
PY
  out=$(ROOM_CMD=(python3 "$probe" "$DISK_ROOM" "$TMP_ROOT"); run_room 2>&1); rc=$?
  expect_code 0 "$rc" "an orphaned real accounting helper cannot keep a dead attempt admissible: $out"
  assert_contains "$out" 'live-owner control passed' "the orphan probe completes both the live and dead owner controls"
  pass "wrapper death holds admission even while its real stopped accounting helper survives"
}

test_corrupt_write_history() {
  reset_state
  set_sizes 60 600 400
  local row out rc
  mkdir -p "$TMP_ROOT/state/write-history"
  for row in '' garbage 'fm-disk-write/v99 1 10 0' 'fm-disk-write/v1 1 -1 0' \
    'fm-disk-write/v1 1 9999999999999999999 0' 'fm-disk-write/v1 1 10 256' \
    'fm-disk-write/v1 1 10 0 extra' 'fm-disk-write/v1 1 10'; do
    printf '%s\n' "$row" >"$TMP_ROOT/state/write-history/bad"
    out=$(run_room check --kind bad --expect-write 1G); rc=$?
    expect_code 2 "$rc" "corrupt history fails closed with an explicit declaration"
    assert_contains "$out" 'corrupt write history' "corruption is named"
    out=$(run_room run --name bad-run --kind bad --expect-write 1G -- sh -c 'echo ran' 2>&1); rc=$?
    expect_code 75 "$rc" "run refuses corrupt history"
    assert_not_contains "$out" ran "corruption never starts work"
    run_room write-history bad >/dev/null 2>&1; rc=$?
    expect_code 2 "$rc" "the query also refuses corrupt history"
  done
  # v1 neither consumes nor overwrites the broken v2 history.
  run_room check --expect-write 1G >/dev/null; rc=$?
  expect_code 0 "$rc" "legacy check ignores kind history"
  run_room run --name bad --expect-write 1G -- sh -c 'exit 7'; rc=$?
  expect_code 7 "$rc" "legacy exec remains unchanged despite corrupt history"
  printf 'fm-disk-write/v1 1 999999999999999998 0\nfm-disk-write/v1 2 999999999999999999 0\n' >"$TMP_ROOT/state/write-history/large"
  out=$(run_room write-history large)
  assert_equals 999999999999999999 "$(json_field "$out" high_bytes)" "high bytes retain integer precision"
  rm -rf "$TMP_ROOT/state/write-history"
  printf 'broken directory\n' >"$TMP_ROOT/state/write-history"
  out=$(run_room check --kind bad --expect-write 1G); rc=$?
  expect_code 2 "$rc" "an unreadable history directory is not missing history"
  assert_contains "$out" 'cannot read write history directory' "the unreadable parent is named"
  pass "missing and corrupt write history never silently become a trusted zero"
}

test_self_test_v2() {
  [ -r /proc/$$/io ] || return 0
  local out rc
  out=$(TMPDIR="$TMP_ROOT" "$DISK_ROOM" --self-test v2); rc=$?
  expect_code 0 "$rc" "the v2 self-test includes the compatible v1 probe"
  assert_contains "$out" 'self-test v2 passed' "v2 probe reports its version"
  out=$(TMPDIR="$TMP_ROOT" bash -c "$(cat "$DISK_ROOM")" "$DISK_ROOM" --self-test v2); rc=$?
  expect_code 0 "$rc" "pinned bash -c bytes can probe v2 too"
  assert_contains "$out" 'self-test v2 passed' "pinned v2 probe passes"
}

test_unavailable_write_counter
test_history_capacity_boundary
test_unrecorded_write_blocks_kind
test_pending_creation_refusals
test_unreadable_pending_refusals
test_pending_completion_failures
test_live_pending_concurrency
test_orphaned_accounting_helper
test_interface_v2_history
test_corrupt_write_history
test_self_test_v2
test_interface_v1_contract
test_self_test
test_pinned_mode
test_bulk_reservations
test_status_real_room_and_reclaim
test_trim_estimate
test_shadow_record_reserves_headroom
test_shadow_fallback_and_stale
test_shadow_live_reading
test_shadow_live_failure_falls_back
test_shadow_last_live_fallback
test_swap_file_growth
test_shadow_no_data_unchanged
test_shadow_cycling_warning
test_shadow_wevtutil_from_drive
test_results_root_in_status
test_check_margin
test_margin_sources
test_low_advice
test_unknown_reclaim
test_fs_overhead
test_reservations
test_run
test_watch_line
test_linux_only
test_vhdx_discovery_cached
test_arm_and_disarm
test_growth_alerts
test_c_runway_reclaim
test_d_runway_and_substitution
