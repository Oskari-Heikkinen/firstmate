#!/usr/bin/env bash
# shellcheck disable=SC1091
# Behavior tests for bin/fm-storage.sh (docs/storage.md).
#
# Every case runs against a PATH-shimmed powershell.exe that prints a fixture
# volume and disk listing, a sudo stub that "mounts" by editing a fixture mount
# table (or refuses like sudo -n without a rule), and a plain directory standing
# in for the SSD, so nothing touches real drives or needs root.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

unset FM_STORAGE_FALLBACK FM_STORAGE_NOTIFY FM_STORAGE_MIN_FREE FM_STORAGE_MIN_SIZE FM_STORAGE_NOW
TMP_ROOT=$(fm_test_tmproot fm-storage)
STORAGE="$ROOT/bin/fm-storage.sh"
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
PSBIN="$TMP_ROOT/psbin"
MNT="$TMP_ROOT/mnt"
CFG="$TMP_ROOT/cfg"
ST="$TMP_ROOT/state"
NOTE="$TMP_ROOT/parent.status"
PSOUT="$TMP_ROOT/ps.txt"
MOUNTS="$TMP_ROOT/mountinfo"
SUDOLOG="$TMP_ROOT/sudo.log"
DEAD="$TMP_ROOT/dead-mount"
# A C: template the removed fallback setting names; nothing may ever print it.
FB="$TMP_ROOT/c-home/data/{task}/tetjet-results"
TB=2000000000000
GIB=1073741824
C_VOL='VOL|C|NTFS|NTFS|Fixed|1021821579264|40000000000|\\?\Volume{c}\|Windows-SSD'
BOOT_DISK='DISK|0|NVMe|GPT|1024209543168|True|True'

mkdir -p "$PSBIN"
cat >"$PSBIN/powershell.exe" <<'SH'
#!/usr/bin/env bash
printf 'call\n' >>"$FAKE_PS.calls"
[ -n "${FAKE_PS_FAIL:-}" ] && exit 1
# FAKE_PS_FAILS names a file holding how many more calls fail (the first
# prints a listing cut off before END, later ones exit 1).
if [ -n "${FAKE_PS_FAILS:-}" ] && n=$(cat "$FAKE_PS_FAILS") && [ "$n" -gt 0 ]; then
  echo $(( n - 1 )) >"$FAKE_PS_FAILS"
  if [ "$n" -gt 1 ]; then exit 1; fi
  grep -vx END "$FAKE_PS" | sed 's/$/\r/'
  exit 0
fi
sed 's/$/\r/' "$FAKE_PS"
SH
cat >"$FAKEBIN/sudo" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FAKE_SUDO_LOG"
[ "$1" = -n ] || exit 1
[ -n "${FAKE_SUDO_OK:-}" ] || { echo "sudo: a password is required" >&2; exit 1; }
case "$2" in
  /usr/bin/mount)
    [ -n "${FAKE_SUDO_MOUNT_FAIL:-}" ] && exit 1
    printf '1 2 0:1 / %s rw - 9p %s rw\n' "$6" "$5" >>"$FAKE_MOUNTS"
    [ -n "${FAKE_DEAD_STAYS:-}" ] || rm -f "$FAKE_DEAD" ;;
  /usr/bin/umount) mp=${!#}; awk -v mp="$mp" '$5 != mp' "$FAKE_MOUNTS" >"$FAKE_MOUNTS.n"; mv "$FAKE_MOUNTS.n" "$FAKE_MOUNTS" ;;
  *) exit 1 ;;
esac
SH
# The dead-mount probe: while $FAKE_DEAD exists, a stat of the mount point
# fails the way a dropped drvfs mount does; a fresh mount clears it.
cat >"$TMP_ROOT/mount-probe" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "${!#}" >>"$FAKE_DEAD.probes"
[ -e "$FAKE_DEAD" ] && { printf "stat: cannot statx '%s': No such device\n" "${!#}" >&2; exit 1; }
exec stat "$@"
SH
cat >"$FAKEBIN/dd" <<SH
#!/usr/bin/env bash
[ -n "\${FAKE_DD_FAIL:-}" ] && exit 1
exec $(command -v dd) "\$@"
SH
cat >"$FAKEBIN/stat" <<SH
#!/usr/bin/env bash
if [ -n "\${FAKE_BULK_DEVICE:-}" ] && [ "\$1 \$2" = '-c %d' ]; then
  case "\${!#}" in "\$FAKE_BULK_MNT/d"|"\$FAKE_BULK_MNT/d/"*) printf '%s\\n' "\$FAKE_BULK_DEVICE"; exit ;; esac
fi
if [ -n "\${FAKE_BULK_STATFS:-}" ] && [ "\$1 \$2 \$3" = '-f -c %a %b %S' ] && [ "\${!#}" = "\$FAKE_BULK_MNT/d" ]; then
  # Each check gets one proved snapshot; a later observation must differ.
  if [ -e "\$FAKE_BULK_STATFS.\$FM_STORAGE_NOW" ]; then
    printf '%s\\n' '17000002 488281253 16384'
  else
    : >"\$FAKE_BULK_STATFS.\$FM_STORAGE_NOW" || exit 1
    printf '%s\\n' '17000001 488281251 8192'
  fi
  exit
fi
exec $(command -v stat) "\$@"
SH
chmod +x "$TMP_ROOT/mount-probe" "$PSBIN/powershell.exe" "$FAKEBIN/sudo" "$FAKEBIN/dd" "$FAKEBIN/stat"

reset() {
  rm -rf "$MNT" "$CFG" "$ST" "$NOTE" "$SUDOLOG" "$PSOUT.calls" "$DEAD" "$DEAD.probes"
  mkdir -p "$MNT/d" "$MNT/e"
  : >"$MOUNTS"
}

# listing LINE...: the fixture Windows answer, always with C: and the boot disk.
listing() { printf '%s\n' "$C_VOL" "$@" "$BOOT_DISK" END >"$PSOUT"; }

ssd_vol() { printf 'VOL|%s|%s|%s|Removable|%s|%s|\\\\?\\Volume{%s}\\|%s' "$1" "$2" "$2" "$TB" "${3:-1800000000000}" "${4:-ssd1}" "${5:-T7}"; }

run() {
  PATH="$FAKEBIN:$PSBIN:$PATH" FAKE_PS="$PSOUT" FAKE_MOUNTS="$MOUNTS" FAKE_SUDO_LOG="$SUDOLOG" FAKE_BULK_MNT="$MNT" \
    FAKE_DEAD="$DEAD" FM_STORAGE_MOUNT_PROBE="$TMP_ROOT/mount-probe" \
    FM_STORAGE_CONFIG="$CFG" FM_STORAGE_STATE="$ST" FM_STORAGE_MNT="$MNT" FM_STORAGE_MOUNTINFO="$MOUNTS" \
    FM_STORAGE_FALLBACK="$FB" FM_STORAGE_NOTIFY="$NOTE" FM_STORAGE_SPEED_SIZE=1M FM_STORAGE_PS_BACKOFF='0 0' \
    "$STORAGE" "$@"
}
calls() { [ -r "$PSOUT.calls" ] && wc -l <"$PSOUT.calls" | tr -d ' ' || echo 0; }

rr() { sed -n "s/^$1=//p" "$CFG/results-root"; }

# root_waits WHY ARGS...: run root ARGS (environment as given) and require exit
# 75, no stdout and one wait: reason on stderr containing WHY.
root_waits() {
  local why=$1 out err rc
  shift
  out=$(run root "$@" 2>"$TMP_ROOT/root.err"); rc=$?
  err=$(cat "$TMP_ROOT/root.err")
  expect_code 75 "$rc" "root $* waits ($why)"
  assert_equals "" "$out" "root $* prints no path ($why)"
  assert_contains "$err" "fm-storage: wait: $why" "root $* names why it waits"
  assert_not_contains "$err" "c-home" "root $* never names a C: path"
}
notes() { [ -r "$NOTE" ] && wc -l <"$NOTE" | tr -d ' ' || echo 0; }

test_absent() {
  reset
  listing
  local out
  out=$(run check) || fail "check exits 0"
  assert_contains "$out" "(absent: no SSD found in Windows)" "check names the state"
  assert_equals unavailable "$(head -n 1 "$CFG/results-root")" "line 1 names no directory"
  assert_no_grep fallback= "$CFG/results-root" "no fallback= is published"
  assert_equals "format=lattice-storage-results-root/v1" "$(sed -n 2p "$CFG/results-root")" "line 2 is the format"
  assert_equals c "$(rr active)" "active is c"
  assert_equals 0 "$(notes)" "the first absent reading is a baseline, not a notification"
  root_waits 'storage-unavailable: absent' t1
  pass "no SSD publishes unavailable without notifying, and root waits"
}

test_ntfs_mounted_and_idempotent() {
  reset
  listing "$(ssd_vol D NTFS)"
  local out setup1
  out=$(FAKE_SUDO_OK=1 FM_STORAGE_NOW=1000 run check) || fail "check exits 0"
  assert_contains "$out" "(ok: SSD D: NTFS" "check reaches ok"
  assert_grep "mount -t drvfs D: $MNT/d -o uid=$(id -u),gid=$(id -g)" "$SUDOLOG" "mount uses exactly the rule's arguments"
  assert_equals "$MNT/d/lattice-data/tetjet-results/{task}" "$(head -n 1 "$CFG/results-root")" "line 1 is the SSD template"
  assert_equals ssd "$(rr active)" "active is ssd"
  assert_present "$MNT/d/lattice-data/tetjet-results" "results folder exists"
  assert_present "$MNT/d/lattice-data/archive" "archive folder exists"
  assert_present "$MNT/d/lattice-data/research" "research folder exists"
  assert_equals "\\\\?\\Volume{ssd1}\\" "$(cat "$MNT/d/lattice-data/.lattice-storage-id")" "the marker holds the volume id"
  case "$(rr write_mib_s)" in ''|*[!0-9]*) fail "write speed is measured" ;; esac
  [ -z "$(find "$MNT/d/lattice-data" -name '.speedtest*' -o -name '.probe*')" ] || fail "speed and probe files are removed"
  assert_equals 1 "$(notes)" "the SSD appearing notifies once"
  assert_grep 'note [at=1000]: SSD storage ok: SSD D: NTFS' "$NOTE" "the note uses the parent-channel format"
  setup1=$(sed -n 's/^setup_at=//p' "$CFG/ssd-identity")
  FAKE_SUDO_OK=1 FM_STORAGE_NOW=2000 run check >/dev/null || fail "re-run exits 0"
  assert_equals 1 "$(notes)" "an unchanged state never notifies twice"
  assert_equals "$setup1" "$(sed -n 's/^setup_at=//p' "$CFG/ssd-identity")" "setup and speed run only once"
  assert_equals 1 "$(grep -c mount "$SUDOLOG")" "an existing mount is not mounted again"
  assert_equals 2000 "$(rr checked_at)" "checked_at advances"
  assert_equals "$MNT/d/lattice-data/tetjet-results/t2" "$(FM_STORAGE_NOW=2100 run root t2)" "root gives the SSD path"
  pass "a mounted NTFS SSD becomes the root, once, idempotently"
}

test_exfat() {
  reset
  listing "$(ssd_vol E exFAT)"
  FAKE_SUDO_OK=1 run check >/dev/null || fail "check exits 0"
  assert_equals ok "$(rr state)" "exFAT is usable"
  assert_equals exFAT "$(rr ssd_fs)" "filesystem recorded"
  assert_equals "$MNT/e/lattice-data/tetjet-results/{task}" "$(head -n 1 "$CFG/results-root")" "the letter picks the mount"
  pass "an exFAT SSD is used"
}

test_raw() {
  reset
  listing 'VOL|D|Unknown|RAW|Removable|2000000000000|0|\\?\Volume{r}\|'
  FAKE_SUDO_OK=1 run check >/dev/null || fail "check exits 0"
  assert_equals raw "$(rr state)" "RAW volume is raw"
  assert_equals unavailable "$(head -n 1 "$CFG/results-root")" "raw names no directory"
  assert_absent "$MNT/d/lattice-data" "nothing is written to a raw drive"
  assert_absent "$SUDOLOG" "a raw drive is not mounted"
  assert_grep 'formatting needs the captain' "$NOTE" "raw notifies"
  reset
  printf '%s\n' "$C_VOL" "$BOOT_DISK" 'DISK|1|USB|RAW|2000398934016|False|False' END >"$PSOUT"
  run check >/dev/null || fail "check exits 0"
  assert_equals raw "$(rr state)" "an unformatted disk with no letter is raw"
  assert_grep 'disk 1 (USB' "$NOTE" "the note names the disk"
  pass "a RAW or unformatted SSD is reported and never touched"
}

test_full() {
  reset
  listing "$(ssd_vol D NTFS $(( 10 * GIB )))"
  FAKE_SUDO_OK=1 run check >/dev/null || fail "check exits 0"
  assert_equals full "$(rr state)" "under the minimum free is full"
  assert_equals unavailable "$(head -n 1 "$CFG/results-root")" "full names no directory"
  assert_grep 'SSD storage full' "$NOTE" "full notifies"
  assert_grep 'fetched-result writers wait until it is usable' "$NOTE" "the note says writers wait"
  assert_no_grep c-home "$NOTE" "the note never names a C: path"
  root_waits 'storage-unavailable: full' t
  pass "a full SSD makes writers wait, never C:"
}

test_small_stick_ignored() {
  reset
  listing 'VOL|F|FAT32|FAT32|Removable|32000000000|30000000000|\\?\Volume{stick}\|STICK' 'DISK|2|USB|MBR|32000000000|False|False'
  run check >/dev/null || fail "check exits 0"
  assert_equals absent "$(rr state)" "a small stick alone is not an SSD"
  listing 'VOL|F|FAT32|FAT32|Removable|32000000000|30000000000|\\?\Volume{stick}\|STICK' "$(ssd_vol D NTFS)"
  FAKE_SUDO_OK=1 run check >/dev/null || fail "check exits 0"
  assert_equals D "$(rr ssd_letter)" "the SSD is picked beside a stick"
  assert_absent "$MNT/f" "the stick is never touched"
  pass "a small USB stick is ignored"
}

test_not_mounted() {
  reset
  listing "$(ssd_vol D NTFS)"
  run check >/dev/null || fail "check exits 0"
  assert_equals not-mounted "$(rr state)" "a sudo refusal is not-mounted"
  assert_grep 'restart the laptop with the SSD plugged in, or see the mount rule section in docs/storage.md' "$CFG/results-root" "the reason says what to do"
  assert_absent "$MNT/d/lattice-data" "nothing is written into an unmounted folder"
  assert_equals unavailable "$(head -n 1 "$CFG/results-root")" "not-mounted names no directory"
  pass "without the mount rule the SSD is reported and writers wait"
}

test_stale_mount() {
  reset
  listing "$(ssd_vol D NTFS)"
  FAKE_SUDO_OK=1 run check >/dev/null || fail "setup exits 0"
  listing
  run check >/dev/null || fail "check exits 0"
  assert_equals stale-mount "$(rr state)" "an unreleasable leftover mount is stale-mount"
  FAKE_SUDO_OK=1 run check >/dev/null || fail "check exits 0"
  assert_equals absent "$(rr state)" "a released mount reads as absent"
  assert_grep "umount -l $MNT/d" "$SUDOLOG" "the stale mount is released lazily"
  assert_grep 'stale WSL mount was released' "$CFG/results-root" "the reason says so"
  assert_equals 3 "$(notes)" "ok, stale-mount and absent each notify once"
  pass "a removed SSD releases its stale mount"
}

test_healthy_mount_no_sudo() {
  reset
  listing "$(ssd_vol D NTFS)"
  FAKE_SUDO_OK=1 run check >/dev/null || fail "setup exits 0"
  : >"$SUDOLOG"
  FAKE_SUDO_OK=1 run check >/dev/null || fail "check exits 0"
  assert_equals ok "$(rr state)" "a live listed mount stays ok"
  [ -s "$SUDOLOG" ] && fail "a live listed mount takes no sudo call"
  assert_grep "$MNT/d" "$DEAD.probes" "the listed mount is probed"
  pass "a healthy listed mount keeps the fast path"
}

test_dead_mount_repaired() {
  reset
  listing "$(ssd_vol D NTFS)"
  FAKE_SUDO_OK=1 run check >/dev/null || fail "setup exits 0"
  : >"$SUDOLOG"; : >"$DEAD"
  FAKE_SUDO_OK=1 run check >/dev/null || fail "check exits 0"
  assert_equals ok "$(rr state)" "a dead mount of a listed SSD is repaired"
  assert_equals "umount -l $MNT/d" "$(sed -n 's/^-n \/usr\/bin\///p' "$SUDOLOG" | sed -n 1p)" "the dead mount is released lazily first"
  assert_equals "mount -t drvfs D: $MNT/d -o uid=$(id -u),gid=$(id -g)" "$(sed -n 's/^-n \/usr\/bin\///p' "$SUDOLOG" | sed -n 2p)" "then mounted through the rule"
  assert_equals 2 "$(wc -l <"$SUDOLOG" | tr -d ' ')" "the repair takes exactly two sudo calls"
  assert_equals 1 "$(grep -c " $MNT/d " "$MOUNTS")" "one mount is listed afterwards"
  assert_equals 1 "$(notes)" "a repair that ends ok does not notify again"
  pass "a dead listed mount is released and mounted again"
}

test_dead_mount_repair_refused() {
  reset
  listing "$(ssd_vol D NTFS)"
  FAKE_SUDO_OK=1 run check >/dev/null || fail "setup exits 0"
  : >"$DEAD"
  run check >/dev/null || fail "check exits 0"
  assert_equals stale-mount "$(rr state)" "a refused release is stale-mount"
  assert_grep 'releasing it with umount -l was refused' "$CFG/results-root" "the reason names the refused release"
  assert_equals unavailable "$(head -n 1 "$CFG/results-root")" "stale-mount names no directory"
  root_waits 'storage-unavailable: stale-mount' t
  FAKE_SUDO_OK=1 FAKE_SUDO_MOUNT_FAIL=1 run check >/dev/null || fail "check exits 0"
  assert_equals stale-mount "$(rr state)" "a refused remount is stale-mount"
  assert_grep 'mounting it again was refused' "$CFG/results-root" "the reason names the refused remount"
  root_waits 'storage-unavailable: stale-mount' t
  : >"$DEAD"
  printf '1 2 0:1 / %s rw - 9p D: rw\n' "$MNT/d" >>"$MOUNTS"
  FAKE_SUDO_OK=1 FAKE_DEAD_STAYS=1 run check >/dev/null || fail "check exits 0"
  assert_equals stale-mount "$(rr state)" "a remount that still fails is stale-mount"
  assert_grep 'still fails with a dead-mount error' "$CFG/results-root" "the reason names the failed remount"
  root_waits 'storage-unavailable: stale-mount' t
  assert_equals 2 "$(notes)" "ok and stale-mount each notify once"
  pass "a refused dead-mount repair is stale-mount and writers wait"
}

test_dead_mount_drive_absent() {
  reset
  listing "$(ssd_vol D NTFS)"
  FAKE_SUDO_OK=1 run check >/dev/null || fail "setup exits 0"
  : >"$SUDOLOG"; : >"$DEAD"
  listing
  FAKE_SUDO_OK=1 run check >/dev/null || fail "check exits 0"
  assert_equals absent "$(rr state)" "a dead mount of a removed SSD reads as absent"
  assert_grep "umount -l $MNT/d" "$SUDOLOG" "it is released"
  assert_no_grep 'mount -t drvfs' "$SUDOLOG" "it is not mounted again"
  assert_grep 'stale WSL mount was released' "$CFG/results-root" "the release path names it"
  pass "a dead mount of an SSD gone from Windows takes the release path"
}

test_other_volume_keeps_letter() {
  reset
  listing "$(ssd_vol D NTFS)"
  FAKE_SUDO_OK=1 run check >/dev/null || fail "setup exits 0"
  : >"$SUDOLOG"
  listing 'VOL|D|FAT32|FAT32|Removable|32000000000|30000000000|\\?\Volume{stick}\|STICK'
  FAKE_SUDO_OK=1 run check >/dev/null || fail "check exits 0"
  assert_equals absent "$(rr state)" "a small stick on the old letter is absent"
  assert_grep " $MNT/d " "$MOUNTS" "the mount on the reused letter stays"
  [ -s "$SUDOLOG" ] && fail "nothing is unmounted while another volume holds the letter"
  pass "a stale-mount release skips a letter another volume now holds"
}

test_speed_remeasured_after_failure() {
  reset
  listing "$(ssd_vol D NTFS)"
  FAKE_SUDO_OK=1 FAKE_DD_FAIL=1 run check >/dev/null || fail "check exits 0"
  assert_equals unknown "$(rr write_mib_s)" "a failed speed test records unknown"
  FAKE_SUDO_OK=1 run check >/dev/null || fail "re-run exits 0"
  case "$(rr write_mib_s)" in ''|*[!0-9]*) fail "an unknown speed is measured again" ;; esac
  pass "an unknown write speed is measured again on the next check"
}

test_timer_path_without_interop() {
  reset
  listing "$(ssd_vol D NTFS)"
  local out
  out=$(PATH="$FAKEBIN:/usr/local/bin:/usr/bin:/bin" FM_STORAGE_POWERSHELL="$PSBIN/powershell.exe" \
    FAKE_PS="$PSOUT" FAKE_MOUNTS="$MOUNTS" FAKE_SUDO_LOG="$SUDOLOG" FAKE_SUDO_OK=1 \
    FM_STORAGE_CONFIG="$CFG" FM_STORAGE_STATE="$ST" FM_STORAGE_MNT="$MNT" FM_STORAGE_MOUNTINFO="$MOUNTS" \
    FM_STORAGE_FALLBACK="$FB" FM_STORAGE_NOTIFY="$NOTE" FM_STORAGE_SPEED_SIZE=1M \
    "$STORAGE" check) || fail "check exits 0"
  assert_contains "$out" "(ok: SSD D: NTFS" "check reads Windows without powershell.exe on PATH"
  assert_equals ok "$(rr state)" "the timer's PATH still reaches ok"
  pass "check finds powershell.exe outside PATH"
}

test_ambiguous_and_identity() {
  reset
  listing "$(ssd_vol D NTFS 1800000000000 a)" "$(ssd_vol E NTFS 1800000000000 b)"
  FAKE_SUDO_OK=1 run check >/dev/null || fail "check exits 0"
  assert_equals ambiguous "$(rr state)" "two large volumes with no identity pick nothing"
  printf 'uniqueid=\\\\?\\Volume{b}\\\n' >"$CFG/ssd-identity"
  FAKE_SUDO_OK=1 run check >/dev/null || fail "check exits 0"
  assert_equals E "$(rr ssd_letter)" "the remembered identity wins"
  pass "the remembered SSD identity decides between large volumes"
}

test_unreadable() {
  reset
  FAKE_PS_FAIL=1 run check >/dev/null || fail "check exits 0"
  assert_equals unreadable "$(rr state)" "a failed Windows listing is unreadable"
  assert_equals unavailable "$(head -n 1 "$CFG/results-root")" "unreadable names no directory"
  assert_equals 3 "$(calls)" "the listing is tried three times"
  assert_grep 'SSD storage unreadable' "$NOTE" "with nothing published before, unreadable is published and notified at once"
  pass "a failed Windows call publishes unavailable"
}

test_transient_listing_failure_retried() {
  reset
  listing
  run check >/dev/null || fail "baseline exits 0"
  echo 2 >"$TMP_ROOT/fails"
  listing "$(ssd_vol D NTFS)"
  FAKE_PS_FAILS="$TMP_ROOT/fails" FAKE_SUDO_OK=1 run check >/dev/null || fail "check exits 0"
  assert_equals ok "$(rr state)" "a listing that succeeds on retry is used"
  assert_equals 4 "$(calls)" "two failed attempts are retried within one check"
  assert_equals 1 "$(notes)" "only the SSD appearing notifies"
  if grep -q unreadable "$NOTE"; then fail "a retried failure never notifies unreadable"; fi
  pass "a transient listing failure is retried within the check"
}

test_unreadable_threshold() {
  reset
  listing "$(ssd_vol D NTFS)"
  FAKE_SUDO_OK=1 FM_STORAGE_NOW=1000 run check >/dev/null || fail "setup exits 0"
  # Without the mount the marker cannot stand in for the listing.
  : >"$MOUNTS"
  local out
  out=$(FAKE_PS_FAIL=1 FM_STORAGE_NOW=1300 run check) || fail "first failed check exits 0"
  assert_contains "$out" "kept ok" "the first failed check keeps the published state"
  assert_equals ok "$(rr state)" "state kept after one failed check"
  assert_equals 1000 "$(rr checked_at)" "the published file is left untouched"
  FAKE_PS_FAIL=1 run check >/dev/null || fail "second failed check exits 0"
  assert_equals ok "$(rr state)" "state kept after two failed checks"
  assert_equals 1 "$(notes)" "failed checks under the threshold never notify"
  FAKE_PS_FAIL=1 run check >/dev/null || fail "third failed check exits 0"
  assert_equals unreadable "$(rr state)" "three consecutive failed checks publish unreadable"
  assert_equals unavailable "$(head -n 1 "$CFG/results-root")" "unreadable names no directory"
  assert_equals 1 "$(grep -c 'SSD storage unreadable' "$NOTE")" "unreadable notifies once"
  FAKE_PS_FAIL=1 run check >/dev/null || fail "fourth failed check exits 0"
  assert_equals 1 "$(grep -c 'SSD storage unreadable' "$NOTE")" "a lasting failure never notifies twice"
  FAKE_SUDO_OK=1 run check >/dev/null || fail "recovery exits 0"
  assert_equals ok "$(rr state)" "a readable listing recovers"
  assert_equals 3 "$(notes)" "recovery notifies the change back"
  : >"$MOUNTS"
  FAKE_PS_FAIL=1 run check >/dev/null || fail "failure after recovery exits 0"
  FAKE_PS_FAIL=1 run check >/dev/null || fail "failure after recovery exits 0"
  assert_equals ok "$(rr state)" "a readable listing resets the count"
  pass "unreadable is published and notified only after three consecutive failed checks"
}

test_marker_identity_without_listing() {
  reset
  listing "$(ssd_vol D NTFS)"
  FAKE_BULK_DEVICE=999 FAKE_SUDO_OK=1 FM_STORAGE_NOW=1000 run check >/dev/null || fail "setup exits 0"
  local out n
  # Pin each check's first snapshot, not a later live or mixed observation.
  # The shim keys its observation record by this check's FM_STORAGE_NOW.
  local -x FAKE_BULK_STATFS="$TMP_ROOT/statfs-observed"
  for n in 1 2 3 4; do
    out=$(FAKE_BULK_DEVICE=999 FAKE_PS_FAIL=1 FM_STORAGE_NOW=$(( 1000 + n * 300 )) run check) || fail "failed listing $n exits 0"
    assert_equals $(( 17000001 * 8192 )) "$(rr ssd_free_bytes)" "check $n free space comes from the first statfs snapshot"
    assert_equals $(( 488281251 * 8192 )) "$(rr ssd_total_bytes)" "check $n total space comes from the first statfs snapshot"
  done
  assert_contains "$out" "identity from the marker" "the line says where the identity came from"
  assert_equals ok "$(rr state)" "a proven SSD stays ok through failed listings"
  assert_equals ssd "$(rr active)" "a proven SSD stays active"
  assert_equals marker "$(rr ssd_identity)" "the publication records the marker identity"
  assert_equals 2200 "$(rr checked_at)" "the check is published, not kept"
  assert_equals "\\\\?\\Volume{ssd1}\\" "$(rr ssd_id)" "the remembered volume id is published"
  assert_absent "$ST/unreadable-runs" "a proven SSD resets the unreadable count"
  [ -z "$(find "$MNT/d/lattice-data" -name '.probe*')" ] || fail "the probe file is removed"
  assert_equals 1 "$(notes)" "an unchanged ok never notifies"
  assert_equals "$MNT/d/lattice-data/tetjet-results/t" "$(FM_STORAGE_NOW=2200 run root t)" "root accepts the marker ok"
  out=$(FAKE_BULK_DEVICE=999 FM_STORAGE_NOW=2200 run verify-bulk-root t) || fail "verify-bulk-root accepts the marker ok"
  assert_equals "$MNT/d/lattice-data/tetjet-results/t" "$out" "mandatory bulk accepts the marker ok"
  pass "a failed listing keeps the SSD when mount, marker, device and probe prove it"
}

# marker_check_fails WHY BREAK [DEVICE]: after setup, BREAK one check (DEVICE
# is the device the failed checks see); three failed listings then publish
# unreadable, naming WHY.
marker_check_fails() {
  local why=$1 brk=$2 dev=${3:-999} out
  reset
  listing "$(ssd_vol D NTFS)"
  FAKE_BULK_DEVICE=999 FAKE_SUDO_OK=1 FM_STORAGE_NOW=1000 run check >/dev/null || fail "setup exits 0"
  eval "$brk"
  out=$(FAKE_BULK_DEVICE=$dev FAKE_PS_FAIL=1 FM_STORAGE_NOW=1300 run check) || fail "$why: first failed check exits 0"
  assert_contains "$out" "kept ok" "$why: the first failed check keeps the published state"
  FAKE_BULK_DEVICE=$dev FAKE_PS_FAIL=1 run check >/dev/null || fail "$why: second failed check exits 0"
  FAKE_BULK_DEVICE=$dev FAKE_PS_FAIL=1 run check >/dev/null || fail "$why: third failed check exits 0"
  assert_equals unreadable "$(rr state)" "$why: three failed checks publish unreadable"
  assert_equals c "$(rr active)" "$why: unreadable is not active"
  assert_equals unavailable "$(head -n 1 "$CFG/results-root")" "$why: line 1 names no directory"
  assert_contains "$(rr reason)" "marker check failed: $why" "$why: the reason names the failed check"
  assert_equals 1 "$(grep -c 'SSD storage unreadable' "$NOTE")" "$why: unreadable notifies once"
}

# shellcheck disable=SC2016 # each BREAK is eval'd inside marker_check_fails
test_marker_checks_fall_back() {
  marker_check_fails "$MNT/d is not mounted" ': >"$MOUNTS"'
  marker_check_fails "the marker on $MNT/d is missing or names another volume" \
    'printf "other\n" >"$MNT/d/lattice-data/.lattice-storage-id"'
  marker_check_fails "the device of $MNT/d is not the published ssd_device" : 998
  if [ "$(id -u)" != 0 ]; then
    marker_check_fails "write probe on $MNT/d failed" 'chmod a-w "$MNT/d/lattice-data"'
    chmod u+w "$MNT/d/lattice-data"
  fi
  pass "a missing mount, marker mismatch, device change or failed probe publishes unreadable"
}

test_reader_rules() {
  reset
  listing "$(ssd_vol D NTFS)"
  FAKE_SUDO_OK=1 FM_STORAGE_NOW=1000 run check >/dev/null || fail "check exits 0"
  assert_equals "$MNT/d/lattice-data/tetjet-results/t" "$(FM_STORAGE_NOW=1000 run root t)" "fresh ok gives the SSD"
  assert_equals "$MNT/d/lattice-data/tetjet-results/{task}" "$(FM_STORAGE_NOW=1000 run root)" "without TASK the template is kept"
  FM_STORAGE_NOW=99999 root_waits stale-publication t
  sed -i 's/^checked_at=.*/checked_at=malformed/' "$CFG/results-root"
  FM_STORAGE_NOW=1000 root_waits stale-publication t
  sed -i 's/^checked_at=.*/checked_at=1000/' "$CFG/results-root"
  mv "$MNT/d/lattice-data/.lattice-storage-id" "$TMP_ROOT/marker"
  FM_STORAGE_NOW=1000 root_waits missing-marker t
  mv "$TMP_ROOT/marker" "$MNT/d/lattice-data/.lattice-storage-id"
  sed -i 2s/v1/v2/ "$CFG/results-root"
  FM_STORAGE_NOW=1000 root_waits invalid-publication t
  sed -i 2s/v2/v1/ "$CFG/results-root"
  sed -i 1s/.*/unavailable/ "$CFG/results-root"
  FM_STORAGE_NOW=1000 root_waits wrong-root t
  rm -f "$CFG/results-root"
  root_waits missing-publication t
  pass "root applies the reader rules and waits on any doubt, never printing C:"
}

test_no_fallback_needed() {
  reset
  listing
  local out rc
  PATH="$FAKEBIN:$PSBIN:$PATH" FAKE_PS="$PSOUT" FM_STORAGE_CONFIG="$CFG" FM_STORAGE_STATE="$ST" "$STORAGE" check >/dev/null 2>&1; rc=$?
  expect_code 0 "$rc" "check needs no fallback template"
  assert_equals absent "$(rr state)" "check publishes without a fallback"
  # A storage.conf left from the fallback era never brings C: back.
  reset
  mkdir -p "$CFG"
  printf 'fallback=%s\nnotify=%s\n' "$FB" "$NOTE" >"$CFG/storage.conf"
  listing "$(ssd_vol D NTFS $(( 10 * GIB )))"
  FAKE_SUDO_OK=1 run check >/dev/null || fail "check with a leftover fallback= exits 0"
  assert_equals full "$(rr state)" "the leftover config still checks"
  assert_equals unavailable "$(head -n 1 "$CFG/results-root")" "a leftover fallback= is not published as line 1"
  assert_no_grep fallback= "$CFG/results-root" "a leftover fallback= is not republished"
  root_waits 'storage-unavailable: full' t
  printf '%s\nformat=lattice-storage-results-root/v1\nactive=c\nstate=full\nreason=old\nchecked_at=1\nfallback=%s\n' "$FB" "$FB" >"$CFG/results-root"
  root_waits 'storage-unavailable: full' t
  out=$(run install-timer --fallback "$FB" 2>&1); rc=$?
  expect_code 2 "$rc" "install-timer refuses the removed --fallback"
  assert_contains "$out" "--fallback was removed" "the refusal says why"
  assert_grep "fallback=$FB" "$CFG/storage.conf" "a refused install-timer leaves storage.conf alone"
  pass "no command needs, publishes or honours a C: fallback"
}

test_install_timer_bounds_a_check() {
  reset
  local xdg="$TMP_ROOT/xdg" sbin="$TMP_ROOT/systemctl-bin" out
  rm -rf "$xdg" "$sbin"
  mkdir -p "$sbin"
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >>"%s/calls"\n' "$sbin" >"$sbin/systemctl"
  chmod +x "$sbin/systemctl"
  out=$(PATH="$sbin:$PATH" XDG_CONFIG_HOME="$xdg" run install-timer 2>&1) || fail "install-timer exits 0: $out"
  assert_grep "TimeoutStartSec=" "$xdg/systemd/user/fm-storage.service" "the written check service has a start limit"
  assert_grep "Type=oneshot" "$xdg/systemd/user/fm-storage.service" "the written check service is a oneshot"
  assert_grep "--user enable --now fm-storage.timer" "$sbin/calls" "install-timer enables the timer"
  PATH="$sbin:$PATH" XDG_CONFIG_HOME="$xdg" run uninstall-timer >/dev/null 2>&1
  assert_absent "$xdg/systemd/user/fm-storage.service" "uninstall-timer removes the service"
  pass "install-timer writes a check service whose hung run is stopped"
}

test_named_roots() {
  reset
  listing "$(ssd_vol D exFAT)"
  FAKE_BULK_DEVICE=999 FAKE_SUDO_OK=1 FM_STORAGE_NOW=1000 run check >/dev/null || fail "bulk publication"
  local out rc home="$TMP_ROOT/research-home"
  out=$(FAKE_BULK_DEVICE=999 FM_STORAGE_NOW=1100 run verify-bulk-root --root research job); rc=$?
  expect_code 0 "$rc" "research root verifies on D"
  assert_equals "$MNT/d/lattice-data/research/job" "$out" "verified research path"
  assert_equals "$MNT/d/lattice-data/research/job" \
    "$(FM_HOME="$home" FAKE_BULK_DEVICE=999 FM_STORAGE_NOW=1100 run root --root research job)" "root --root research prints D when verified"
  assert_equals "$MNT/d/lattice-data/tetjet-results/job" \
    "$(FAKE_BULK_DEVICE=999 FM_STORAGE_NOW=1100 run verify-bulk-root job)" "default root unchanged"
  assert_equals "$MNT/d/lattice-data/tetjet-results/job" \
    "$(FAKE_BULK_DEVICE=999 FM_STORAGE_NOW=1100 run verify-bulk-root --root tetjet-results job)" "tetjet-results is the default name"
  assert_equals "$MNT/d/lattice-data/tetjet-results/job" "$(FM_STORAGE_NOW=1100 run root job)" "legacy root unchanged"
  rmdir "$MNT/d/lattice-data/research"
  out=$(FAKE_BULK_DEVICE=999 FM_STORAGE_NOW=1100 run verify-bulk-root --root research job 2>&1); rc=$?
  expect_code 75 "$rc" "a missing research directory waits"
  assert_contains "$out" wrong-root "research root reason"
  mkdir "$MNT/d/lattice-data/research"
  mv "$MNT/d/lattice-data" "$TMP_ROOT/lattice-data"
  : >"$MOUNTS"
  out=$(FM_STORAGE_NOW=1100 run verify-bulk-root --root research job 2>&1); rc=$?
  expect_code 75 "$rc" "an empty unmounted D waits for the research root"
  assert_not_contains "$out" "$home" "the mandatory form never falls back"
  out=$(FM_HOME="$home" FM_STORAGE_NOW=1100 run root --root research job 2>&1); rc=$?
  expect_code 75 "$rc" "root --root research waits without D"
  assert_contains "$out" "fm-storage: wait:" "root --root research names why it waits"
  assert_not_contains "$out" "/data/job/bulk" "root --root research never prints the Linux path"
  out=$(run verify-bulk-root --root nope job 2>&1); rc=$?
  expect_code 2 "$rc" "unknown root refused"
  assert_contains "$out" "unknown root nope" "unknown root reason"
  out=$(run root --root nope job 2>&1); rc=$?
  expect_code 2 "$rc" "root refuses an unknown root"
  out=$(run bulk-root --root nope job --name d --download 0 --expanded 0 --packaging 0 2>&1); rc=$?
  expect_code 2 "$rc" "bulk-root refuses an unknown root"
  out=$(run verify-bulk-root --root 2>&1); rc=$?
  expect_code 2 "$rc" "--root needs a value"
  out=$(run root --root research ../job 2>&1); rc=$?
  expect_code 2 "$rc" "research task traversal is misuse"
  pass "named roots verify research on D, wait without it, and refuse unknown names"
}

test_mandatory_bulk() {
  reset
  listing "$(ssd_vol D exFAT)"
  FAKE_BULK_DEVICE=999 FAKE_SUDO_OK=1 FM_STORAGE_NOW=1000 run check >/dev/null || fail "bulk publication"
  local out rc
  out=$(FAKE_BULK_DEVICE=999 FM_STORAGE_NOW=1100 run verify-bulk-root job); rc=$?
  expect_code 0 "$rc" "fresh verified D root"
  assert_equals "$MNT/d/lattice-data/tetjet-results/job" "$out" "verified D path"
  # Observed WSL mountinfo source spelling (backslash is octal-escaped).
  printf '1 2 0:1 / %s rw - 9p D:\\134 rw,aname=drvfs;path=D:\\;uid=1000\n' "$MNT/d" >"$MOUNTS"
  out=$(FAKE_BULK_DEVICE=999 FM_STORAGE_NOW=1100 run verify-bulk-root job); rc=$?
  expect_code 0 "$rc" "actual WSL escaped source spelling is accepted"
  cp "$CFG/results-root" "$TMP_ROOT/publication"
  sed -i 2s/v1/v2/ "$CFG/results-root"
  out=$(FAKE_BULK_DEVICE=999 FM_STORAGE_NOW=1100 run verify-bulk-root job 2>&1); rc=$?
  expect_code 75 "$rc" "unknown format refuses"
  assert_contains "$out" invalid-publication "format reason"
  cp "$TMP_ROOT/publication" "$CFG/results-root"
  sed -i 's/ssd_letter=D/ssd_letter=E/' "$CFG/results-root"
  out=$(FAKE_BULK_DEVICE=999 FM_STORAGE_NOW=1100 run verify-bulk-root job 2>&1); rc=$?
  expect_code 75 "$rc" "other SSD letter never satisfies D required"
  cp "$TMP_ROOT/publication" "$CFG/results-root"
  sed -i 's/ssd_fs=exFAT/ssd_fs=RAW/' "$CFG/results-root"
  out=$(FAKE_BULK_DEVICE=999 FM_STORAGE_NOW=1100 run verify-bulk-root job 2>&1); rc=$?
  expect_code 75 "$rc" "unsupported filesystem refuses"
  cp "$TMP_ROOT/publication" "$CFG/results-root"
  sed -i 's/checked_at=1000/checked_at=malformed/' "$CFG/results-root"
  out=$(FAKE_BULK_DEVICE=999 FM_STORAGE_NOW=1100 run verify-bulk-root job 2>&1); rc=$?
  expect_code 75 "$rc" "malformed date is a wait, not an arithmetic crash"
  cp "$TMP_ROOT/publication" "$CFG/results-root"
  mv "$CFG/ssd-identity" "$TMP_ROOT/identity"
  out=$(FAKE_BULK_DEVICE=999 FM_STORAGE_NOW=1100 run verify-bulk-root job 2>&1); rc=$?
  expect_code 75 "$rc" "missing remembered configuration refuses"
  mv "$TMP_ROOT/identity" "$CFG/ssd-identity"
  mv "$MNT/d/lattice-data/tetjet-results" "$MNT/d/lattice-data/real-results"
  ln -s real-results "$MNT/d/lattice-data/tetjet-results"
  out=$(FAKE_BULK_DEVICE=999 FM_STORAGE_NOW=1100 run verify-bulk-root job 2>&1); rc=$?
  expect_code 75 "$rc" "symlinked bulk root refuses"
  assert_contains "$out" wrong-root "root reason"
  rm "$MNT/d/lattice-data/tetjet-results"
  mv "$MNT/d/lattice-data/real-results" "$MNT/d/lattice-data/tetjet-results"
  out=$(FAKE_BULK_DEVICE=999 FM_STORAGE_NOW=99999 run verify-bulk-root job 2>&1); rc=$?
  expect_code 75 "$rc" "stale publication refuses"
  assert_contains "$out" stale-publication "stale reason"
  out=$(FAKE_BULK_DEVICE=999 FM_STORAGE_NOW=999 run verify-bulk-root job 2>&1); rc=$?
  expect_code 75 "$rc" "future publication refuses"
  out=$(FM_STORAGE_NOW=1100 run verify-bulk-root job 2>&1); rc=$?
  expect_code 75 "$rc" "Linux-backed D-shaped folder refuses despite marker"
  assert_contains "$out" wrong-filesystem-identity "filesystem reason"
  : >"$MOUNTS"
  out=$(FAKE_BULK_DEVICE=999 FM_STORAGE_NOW=1100 run verify-bulk-root job 2>&1); rc=$?
  expect_code 75 "$rc" "missing mount refuses"
  assert_contains "$out" wrong-mount-identity "mount reason"
  printf '1 2 0:1 / %s rw - 9p E: rw\n' "$MNT/d" >"$MOUNTS"
  out=$(FAKE_BULK_DEVICE=999 FM_STORAGE_NOW=1100 run verify-bulk-root job 2>&1); rc=$?
  expect_code 75 "$rc" "wrong letter mount refuses"
  printf '1 2 0:1 / %s rw - 9p D: rw\n' "$MNT/d" >"$MOUNTS"
  printf 'wrong-volume\n' >"$MNT/d/lattice-data/.lattice-storage-id"
  out=$(FAKE_BULK_DEVICE=999 FM_STORAGE_NOW=1100 run verify-bulk-root job 2>&1); rc=$?
  expect_code 75 "$rc" "wrong marker contents refuse"
  assert_contains "$out" wrong-volume-identity "marker identity reason"
  rm "$MNT/d/lattice-data/.lattice-storage-id"
  out=$(FAKE_BULK_DEVICE=999 FM_STORAGE_NOW=1100 run verify-bulk-root job 2>&1); rc=$?
  expect_code 75 "$rc" "missing marker refuses"
  assert_contains "$out" missing-marker "missing marker reason"
  FM_STORAGE_NOW=1100 root_waits missing-marker job
  rm "$CFG/results-root"
  out=$(run verify-bulk-root job 2>&1); rc=$?
  expect_code 75 "$rc" "missing config refuses"
  assert_contains "$out" missing-publication "publication reason"
  reset
  listing
  run check >/dev/null
  out=$(run verify-bulk-root job 2>&1); rc=$?
  expect_code 75 "$rc" "absent SSD refuses rather than C"
  assert_contains "$out" 'storage-unavailable: absent' "publisher reason remains available"
  out=$(run verify-bulk-root ../job 2>&1); rc=$?
  expect_code 2 "$rc" "task traversal is misuse"
  pass "mandatory bulk rejects unavailable, stale, mismatched and Linux-backed storage"
}

test_named_roots
test_mandatory_bulk
test_absent
test_ntfs_mounted_and_idempotent
test_exfat
test_raw
test_full
test_small_stick_ignored
test_not_mounted
test_stale_mount
test_healthy_mount_no_sudo
test_dead_mount_repaired
test_dead_mount_repair_refused
test_dead_mount_drive_absent
test_other_volume_keeps_letter
test_speed_remeasured_after_failure
test_timer_path_without_interop
test_ambiguous_and_identity
test_unreadable
test_transient_listing_failure_retried
test_unreadable_threshold
test_marker_identity_without_listing
test_marker_checks_fall_back
test_reader_rules
test_no_fallback_needed
test_install_timer_bounds_a_check
