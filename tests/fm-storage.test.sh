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
  /usr/bin/mount) printf '1 2 0:1 / %s rw - 9p %s rw\n' "$6" "$5" >>"$FAKE_MOUNTS" ;;
  /usr/bin/umount) mp=${!#}; awk -v mp="$mp" '$5 != mp' "$FAKE_MOUNTS" >"$FAKE_MOUNTS.n"; mv "$FAKE_MOUNTS.n" "$FAKE_MOUNTS" ;;
  *) exit 1 ;;
esac
SH
cat >"$FAKEBIN/dd" <<SH
#!/usr/bin/env bash
[ -n "\${FAKE_DD_FAIL:-}" ] && exit 1
exec $(command -v dd) "\$@"
SH
chmod +x "$PSBIN/powershell.exe" "$FAKEBIN/sudo" "$FAKEBIN/dd"

reset() {
  rm -rf "$MNT" "$CFG" "$ST" "$NOTE" "$SUDOLOG" "$PSOUT.calls"
  mkdir -p "$MNT/d" "$MNT/e"
  : >"$MOUNTS"
}

# listing LINE...: the fixture Windows answer, always with C: and the boot disk.
listing() { printf '%s\n' "$C_VOL" "$@" "$BOOT_DISK" END >"$PSOUT"; }

ssd_vol() { printf 'VOL|%s|%s|%s|Removable|%s|%s|\\\\?\\Volume{%s}\\|%s' "$1" "$2" "$2" "$TB" "${3:-1800000000000}" "${4:-ssd1}" "${5:-T7}"; }

run() {
  PATH="$FAKEBIN:$PSBIN:$PATH" FAKE_PS="$PSOUT" FAKE_MOUNTS="$MOUNTS" FAKE_SUDO_LOG="$SUDOLOG" \
    FM_STORAGE_CONFIG="$CFG" FM_STORAGE_STATE="$ST" FM_STORAGE_MNT="$MNT" FM_STORAGE_MOUNTINFO="$MOUNTS" \
    FM_STORAGE_FALLBACK="$FB" FM_STORAGE_NOTIFY="$NOTE" FM_STORAGE_SPEED_SIZE=1M FM_STORAGE_PS_BACKOFF='0 0' \
    "$STORAGE" "$@"
}
calls() { [ -r "$PSOUT.calls" ] && wc -l <"$PSOUT.calls" | tr -d ' ' || echo 0; }

rr() { sed -n "s/^$1=//p" "$CFG/results-root"; }
notes() { [ -r "$NOTE" ] && wc -l <"$NOTE" | tr -d ' ' || echo 0; }

test_absent() {
  reset
  listing
  local out
  out=$(run check) || fail "check exits 0"
  assert_contains "$out" "(absent: no SSD found in Windows)" "check names the state"
  assert_equals "$FB" "$(head -n 1 "$CFG/results-root")" "line 1 is the C: fallback"
  assert_equals "format=lattice-storage-results-root/v1" "$(sed -n 2p "$CFG/results-root")" "line 2 is the format"
  assert_equals c "$(rr active)" "active is c"
  assert_equals 0 "$(notes)" "the first absent reading is a baseline, not a notification"
  assert_equals "$TMP_ROOT/c-home/data/t1/tetjet-results" "$(run root t1)" "root resolves the fallback for a task"
  pass "no SSD publishes the C: fallback without notifying"
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
  assert_equals "$FB" "$(head -n 1 "$CFG/results-root")" "raw keeps the fallback"
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
  assert_equals "$FB" "$(head -n 1 "$CFG/results-root")" "full uses the fallback"
  assert_grep 'SSD storage full' "$NOTE" "full notifies"
  pass "a full SSD falls back to C:"
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
  assert_equals "$FB" "$(head -n 1 "$CFG/results-root")" "not-mounted uses the fallback"
  pass "without the mount rule the SSD is reported and C: stays active"
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
  assert_equals "$FB" "$(head -n 1 "$CFG/results-root")" "unreadable uses the fallback"
  assert_equals 3 "$(calls)" "the listing is tried three times"
  assert_grep 'SSD storage unreadable' "$NOTE" "with nothing published before, unreadable is published and notified at once"
  pass "a failed Windows call falls back to C:"
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
  assert_equals "$FB" "$(head -n 1 "$CFG/results-root")" "unreadable uses the fallback"
  assert_equals 1 "$(grep -c 'SSD storage unreadable' "$NOTE")" "unreadable notifies once"
  FAKE_PS_FAIL=1 run check >/dev/null || fail "fourth failed check exits 0"
  assert_equals 1 "$(grep -c 'SSD storage unreadable' "$NOTE")" "a lasting failure never notifies twice"
  FAKE_SUDO_OK=1 run check >/dev/null || fail "recovery exits 0"
  assert_equals ok "$(rr state)" "a readable listing recovers"
  assert_equals 3 "$(notes)" "recovery notifies the change back"
  FAKE_PS_FAIL=1 run check >/dev/null || fail "failure after recovery exits 0"
  FAKE_PS_FAIL=1 run check >/dev/null || fail "failure after recovery exits 0"
  assert_equals ok "$(rr state)" "a readable listing resets the count"
  pass "unreadable is published and notified only after three consecutive failed checks"
}

test_reader_rules() {
  reset
  listing "$(ssd_vol D NTFS)"
  FAKE_SUDO_OK=1 FM_STORAGE_NOW=1000 run check >/dev/null || fail "check exits 0"
  local c="$TMP_ROOT/c-home/data/t/tetjet-results"
  assert_equals "$MNT/d/lattice-data/tetjet-results/t" "$(FM_STORAGE_NOW=1000 run root t)" "fresh ok gives the SSD"
  assert_equals "$c" "$(FM_STORAGE_NOW=99999 run root t)" "an old check falls back"
  mv "$MNT/d/lattice-data/.lattice-storage-id" "$TMP_ROOT/marker"
  assert_equals "$c" "$(FM_STORAGE_NOW=1000 run root t)" "a missing marker falls back"
  mv "$TMP_ROOT/marker" "$MNT/d/lattice-data/.lattice-storage-id"
  sed -i 2s/v1/v2/ "$CFG/results-root"
  assert_equals "$c" "$(FM_STORAGE_NOW=1000 run root t)" "an unknown format falls back"
  rm -f "$CFG/results-root"
  assert_equals "$c" "$(run root t)" "a missing file falls back"
  pass "root applies the reader rules and falls back on any doubt"
}

test_no_fallback_refused() {
  reset
  listing
  local rc
  PATH="$FAKEBIN:$PSBIN:$PATH" FAKE_PS="$PSOUT" FM_STORAGE_CONFIG="$CFG" FM_STORAGE_STATE="$ST" "$STORAGE" check >/dev/null 2>&1; rc=$?
  expect_code 2 "$rc" "check refuses without a fallback template"
  assert_absent "$CFG/results-root" "nothing is published without a fallback"
  pass "check refuses to publish without a C: fallback"
}

test_absent
test_ntfs_mounted_and_idempotent
test_exfat
test_raw
test_full
test_small_stick_ignored
test_not_mounted
test_stale_mount
test_other_volume_keeps_letter
test_speed_remeasured_after_failure
test_timer_path_without_interop
test_ambiguous_and_identity
test_unreadable
test_transient_listing_failure_retried
test_unreadable_threshold
test_reader_rules
test_no_fallback_refused
