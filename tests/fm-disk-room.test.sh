#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2016
# Behavior tests for bin/fm-disk-room.sh (docs/disk-room.md).
#
# Every case runs against a PATH-shimmed df that reports fixture sizes for a
# fake Windows drive and a fake Linux root, a real sparse file standing in for
# ext4.vhdx, a fixture ext4 mb_groups table, and a stub wevtutil that prints
# fixture volsnap events, so nothing reads the real disk or the Windows log.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

unset FM_DISK_ROOM_VHDX FM_DISK_ROOM_MARGIN FM_DISK_ROOM_NOW FM_DISK_ROOM_COMPACT_RESULT FM_DISK_ROOM_STATE \
  FM_DISK_ROOM_SHADOW_RECORD FM_DISK_ROOM_SHADOW_MAX FM_DISK_ROOM_WEVTUTIL
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

# wevtutil stub: prints $FAKE_EVENTS (an XML fixture) and counts its calls.
cat >"$FAKEBIN/wevtutil-stub" <<'SH'
#!/usr/bin/env bash
printf 'x\n' >>"$FAKE_EVENTS.calls"
[ -r "$FAKE_EVENTS" ] || exit 1
cat "$FAKE_EVENTS"
SH
chmod +x "$FAKEBIN/wevtutil-stub"
EVENTS="$TMP_ROOT/events.xml"

# write_events ID...: one volsnap event per id, as wevtutil /f:xml prints them.
write_events() {
  local id
  : >"$EVENTS"
  for id in "$@"; do
    printf '<Event xmlns="http://schemas.microsoft.com/win/2004/08/events/event"><System><Provider Name="volsnap"/><EventID Qualifiers="49158">%s</EventID></System></Event>\r\n' "$id" >>"$EVENTS"
  done
}

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
    FAKE_EVENTS="$EVENTS" FM_DISK_ROOM_WEVTUTIL="${FM_DISK_ROOM_WEVTUTIL-wevtutil-stub}" \
    "$DISK_ROOM" "$@"
}

json_field() { printf '%s\n' "$1" | sed -n "s/.*\"$2\":\([^,}]*\).*/\1/p"; }

reset_state() { rm -rf "$TMP_ROOT/state" "$EVENTS" "$EVENTS.calls" "$HOSTDIR/ProgramData"; }

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
  out=$(FM_HOME="$home" FM_DISK_ROOM_WEVTUTIL='' FM_DISK_ROOM_MARGIN=20G FM_DISK_ROOM_HOST="$HOSTDIR" FM_DISK_ROOM_ROOT="$LINUXDIR" \
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
  assert_equals null "$(json_field "$out" shadow_events)" "a fresh record needs no event count"
  assert_absent "$EVENTS.calls" "a fresh record starts no Windows process"
  out=$(run_room status)
  assert_contains "$out" "shadow storage: 7.0 GiB headroom reserved (cap 10.0 GiB, used 3.0 GiB" "plain status explains the reservation"
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
  out=$(FM_DISK_ROOM_SHADOW_MAX=lots run_room status 2>&1)
  assert_contains "$out" "bad FM_DISK_ROOM_SHADOW_MAX" "a bad configured cap is reported"
  pass "without a fresh record the configured cap is reserved whole"
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
  pass "recent volsnap 25/33/36 events warn that shadow storage is cycling"
}

test_status_real_room_and_reclaim
test_shadow_record_reserves_headroom
test_shadow_fallback_and_stale
test_shadow_no_data_unchanged
test_shadow_cycling_warning
test_results_root_in_status
test_check_margin
test_low_advice
test_unknown_reclaim
test_reservations
test_run
test_watch_line
test_linux_only
test_vhdx_discovery_cached
test_arm_and_disarm
