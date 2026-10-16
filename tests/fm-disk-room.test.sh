#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2016
# Behavior tests for bin/fm-disk-room.sh (docs/disk-room.md).
#
# Every case runs against a PATH-shimmed df that reports fixture sizes for a
# fake Windows drive and a fake Linux root, a real sparse file standing in for
# ext4.vhdx, a fixture ext4 mb_groups table, a stub wevtutil that prints
# fixture volsnap events, and a stub powershell that prints a fixture shadow
# storage reading, so nothing reads the real disk, the Windows log or WMI.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

unset FM_DISK_ROOM_VHDX FM_DISK_ROOM_DEV_SIZE FM_DISK_ROOM_MARGIN FM_DISK_ROOM_NOW FM_DISK_ROOM_COMPACT_RESULT FM_DISK_ROOM_STATE \
  FM_DISK_ROOM_SHADOW_RECORD FM_DISK_ROOM_SHADOW_MAX FM_DISK_ROOM_WEVTUTIL FM_DISK_ROOM_POWERSHELL FM_DISK_ROOM_RESULTS_ROOT \
  FM_DISK_ROOM_SAMPLES FM_DISK_ROOM_GROWTH_MAX FM_DISK_ROOM_C_FREE_MIN FM_DISK_ROOM_D_FREE_MIN FM_STORAGE_MNT \
  FM_DISK_ROOM_WSLCONFIG FM_DISK_ROOM_MEMINFO
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

run_room() {
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
    ${TEST_SWAP_DISCOVER:+env -u FM_DISK_ROOM_WSLCONFIG} "$DISK_ROOM" "$@"
}

json_field() { printf '%s\n' "$1" | sed -n "s/.*\"$2\":\([^,}]*\).*/\1/p"; }

reset_state() { rm -rf "$TMP_ROOT/state" "$EVENTS" "$EVENTS.calls" "$SHADOW_LIVE" "$SHADOW_LIVE.calls" "$HOSTDIR/ProgramData"; }

# write_shadow_record MAX_GIB USED_GIB AGE_SECONDS: the file the elevated
# fm-wsl-reclaim.ps1 task writes (tests/fm-wsl-reclaim.test.sh pins its format).
write_shadow_record() {
  mkdir -p "$HOSTDIR/ProgramData/firstmate"
  printf 'recorded=2026-10-01T12:00:00Z\r\nrecorded_epoch=%s\r\nvolume=C:\r\nmax_bytes=%s\r\nused_bytes=%s\r\nallocated_bytes=%s\r\n' \
    $(( $(date +%s) - $3 )) $(( $1 * GIB )) $(( $2 * GIB )) $(( $2 * GIB )) >"$HOSTDIR/ProgramData/firstmate/shadow-storage.txt"
}

# The host frame bytes have 4 KiB blocks here, so real stat reports the block
# size of the temp filesystem; the fixture groups assume 4 KiB.
BS=$(stat -f -c %S "$LINUXDIR")

test_status_real_room_and_reclaim() {
  reset_state
  set_sizes 60 600 400
  truncate -s $(( 470 * GIB )) "$VHDX"
  write_mb_groups 30
  local out
  out=$(run_room status --json) || fail "status exits 0"
  assert_equals $(( 60 * GIB )) "$(json_field "$out" room)" "real room is the host drive's free space"
  assert_equals false "$(json_field "$out" low)" "60 GiB is not low"
  assert_equals $(( 70 * GIB )) "$(json_field "$out" slack)" "slack is disk file size minus Linux used"
  if [ "$BS" = 4096 ]; then
    assert_equals $(( 30 * GIB )) "$(json_field "$out" fragmented_free)" "only sub-1 MiB buddies count as fragmented"
    assert_equals $(( 40 * GIB )) "$(json_field "$out" reclaimable)" "reclaimable is slack minus fragmented free"
  fi
  out=$(run_room status)
  assert_contains "$out" "real room: 60.0 GiB (limited by $HOSTDIR; margin 20.0 GiB)" "plain status names the limit"
  set_sizes 60 50 400
  out=$(run_room status --json)
  assert_equals $(( 50 * GIB )) "$(json_field "$out" room)" "Linux free limits when it is smaller"
  pass "status reports real room, slack and the reclaimable estimate"
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

test_low_advice() {
  reset_state
  set_sizes 30 600 400
  truncate -s $(( 470 * GIB )) "$VHDX"
  write_mb_groups 30
  local out
  out=$(run_room check --expect-write 20G)
  if [ "$BS" = 4096 ]; then
    assert_contains "$out" "a compaction would reclaim about 40.0 GiB" "large slack points at compaction"
  fi
  truncate -s $(( 430 * GIB )) "$VHDX"
  out=$(run_room check --expect-write 20G)
  assert_contains "$out" "data must be freed or moved" "fragmented slack alone does not suggest compaction"
  pass "a low reading says whether compaction would help"
}

test_unknown_reclaim() {
  reset_state
  set_sizes 30 600 400
  truncate -s $(( 470 * GIB )) "$VHDX"
  rm -f "$TMP_ROOT/mb_groups"
  local out
  out=$(run_room status --json)
  assert_equals null "$(json_field "$out" fragmented_free)" "no fragmented reading"
  assert_equals null "$(json_field "$out" reclaimable)" "reclaimable is not guessed without the fragmented reading"
  out=$(run_room status)
  assert_contains "$out" "reclaimable by compaction unknown" "plain status says the estimate is unknown"
  out=$(run_room check --expect-write 20G)
  assert_contains "$out" "reclaimable by compaction unknown (fragmented free space unreadable)" "low advice names the missing reading"
  assert_not_contains "$out" "a compaction would reclaim" "no compaction promise without the reading"
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
  truncate -s $(( 470 * GIB )) "$VHDX"
  write_mb_groups 30
  local out
  out=$(TEST_DEV_SIZE=$(( 1017 * GIB )) run_room status --json)
  assert_equals $(( 17 * GIB )) "$(json_field "$out" fs_overhead)" "ext4 metadata is the block device size minus the df total"
  if [ "$BS" = 4096 ]; then
    assert_equals $(( 23 * GIB )) "$(json_field "$out" reclaimable)" "reclaimable is slack minus fragmented free minus ext4 metadata"
    out=$(TEST_DEV_SIZE=$(( 1017 * GIB )) run_room status)
    assert_contains "$out" "slack 70.0 GiB, of which fragmented 30.0 GiB and ext4 metadata 17.0 GiB; reclaimable by compaction about 23.0 GiB" "status names the metadata"
  fi
  truncate -s $(( 410 * GIB )) "$VHDX"
  out=$(TEST_DEV_SIZE=$(( 1017 * GIB )) run_room status --json)
  assert_equals 0 "$(json_field "$out" reclaimable)" "metadata past the slack floors reclaimable at 0"
  out=$(TEST_DEV_SIZE=$(( 1017 * GIB )) run_room check --expect-write 20G)
  assert_not_contains "$out" "a compaction would reclaim" "no compaction promise for slack that is all metadata"
  assert_contains "$out" "data must be freed or moved" "low advice says compaction cannot help"
  truncate -s $(( 470 * GIB )) "$VHDX"
  out=$(TEST_DEV_SIZE=unreadable run_room status --json)
  assert_equals null "$(json_field "$out" fs_overhead)" "no metadata reading"
  assert_equals null "$(json_field "$out" reclaimable)" "reclaimable is not guessed without the device size"
  out=$(TEST_DEV_SIZE=unreadable run_room check --expect-write 20G)
  assert_contains "$out" "reclaimable by compaction unknown (ext4 metadata size unreadable)" "low advice names the missing device size"
  assert_not_contains "$out" "a compaction would reclaim" "no fallback to the estimate without metadata"
  pass "ext4 metadata is subtracted from the reclaimable estimate"
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
    FM_DISK_ROOM_C_FREE_MIN=40G "$DISK_ROOM" arm) || fail "arm exits 0"
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
  assert_contains "$out" "fetched results root: C: fallback (SSD full)" "the fallback and its cause are named"
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
  local conf="$HOSTDIR/Users/u/.wslconfig" g1="$HOSTDIR/Users/u/AppData/Local/Temp/{G1}" g2="$HOSTDIR/Users/u/AppData/Local/Temp/{G2}" out rc
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
  rm -rf "$TMP_ROOT/state/reservations-d/$rootdev" "$cfg/results-root"
  pass "D: runway and Linux substitution alerts, with disk file and D: history"
}

test_bulk_reservations
test_status_real_room_and_reclaim
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
test_d_runway_and_substitution
