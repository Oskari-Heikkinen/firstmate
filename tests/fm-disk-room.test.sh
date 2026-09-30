#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2016
# Behavior tests for bin/fm-disk-room.sh (docs/disk-room.md).
#
# Every case runs against a PATH-shimmed df that reports fixture sizes for a
# fake Windows drive and a fake Linux root, a real sparse file standing in for
# ext4.vhdx, and a fixture ext4 mb_groups table, so nothing reads the real disk.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

unset FM_DISK_ROOM_VHDX FM_DISK_ROOM_MARGIN FM_DISK_ROOM_NOW FM_DISK_ROOM_COMPACT_RESULT FM_DISK_ROOM_STATE
TMP_ROOT=$(fm_test_tmproot fm-disk-room)
DISK_ROOM="$ROOT/bin/fm-disk-room.sh"
GIB=1073741824
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

key() { printf '%s' "$1" | tr / _; }

# set_sizes HOST_FREE_GIB LINUX_FREE_GIB LINUX_USED_GIB
set_sizes() {
  printf '%s\n' $(( $1 * GIB )) >"$DFDIR/$(key "$HOSTDIR").avail"
  printf '%s\n' $(( $2 * GIB )) >"$DFDIR/$(key "$LINUXDIR").avail"
  printf '%s\n' $(( $3 * GIB )) >"$DFDIR/$(key "$LINUXDIR").used"
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
  PATH="$FAKEBIN:$PATH" FAKE_DF="$DFDIR" \
    FM_DISK_ROOM_HOST="${TEST_HOST-$HOSTDIR}" FM_DISK_ROOM_ROOT="$LINUXDIR" \
    FM_DISK_ROOM_MB_GROUPS="$TMP_ROOT/mb_groups" FM_DISK_ROOM_STATE="$TMP_ROOT/state" \
    "$DISK_ROOM" "$@"
}

json_field() { printf '%s\n' "$1" | sed -n "s/.*\"$2\":\([^,}]*\).*/\1/p"; }

reset_state() { rm -rf "$TMP_ROOT/state"; }

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
    FM_DISK_ROOM_MB_GROUPS="$TMP_ROOT/mb_groups" FM_DISK_ROOM_STATE="$TMP_ROOT/state" FM_DISK_ROOM_VHDX='' "$DISK_ROOM" status --json)
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
  out=$(FM_HOME="$home" FM_DISK_ROOM_MARGIN=20G FM_DISK_ROOM_HOST="$HOSTDIR" FM_DISK_ROOM_ROOT="$LINUXDIR" \
    FM_DISK_ROOM_MB_GROUPS="$TMP_ROOT/mb_groups" FM_DISK_ROOM_STATE="$TMP_ROOT/state" "$DISK_ROOM" arm) || fail "arm exits 0"
  assert_contains "$out" "armed: $home/state/disk-room.check.sh" "arm names the shim"
  assert_present "$home/state/disk-room.check-trust" "arm binds the shim's bytes"
  out=$(env -u FM_DISK_ROOM_HOST PATH="$FAKEBIN:$PATH" FAKE_DF="$DFDIR" "$home/state/disk-room.check.sh")
  assert_contains "$out" "disk room low: 15.0 GiB real room on $HOSTDIR" "the shim carries the arm-time settings"
  FM_HOME="$home" "$DISK_ROOM" disarm >/dev/null || fail "disarm exits 0"
  assert_absent "$home/state/disk-room.check.sh" "disarm removes the shim"
  assert_absent "$home/state/disk-room.check-trust" "disarm removes the trust binding"
  pass "arm registers the watcher check with its settings and disarm retires it"
}

test_status_real_room_and_reclaim
test_check_margin
test_low_advice
test_reservations
test_run
test_watch_line
test_linux_only
test_vhdx_discovery_cached
test_arm_and_disarm
