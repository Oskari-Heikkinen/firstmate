#!/usr/bin/env bash
# fm-storage-c-terms.py: each host-c growth term (ext4.vhdx, WSL swap, VSS,
# pagefile) and both free-space readings come out measured, bounded,
# not-applicable or a named unknown; every unknown exits 75 with a null
# reservation (never zero), misuse and bad policy exit 2 with empty stdout, and
# nothing in the fixture world is written. Windows replies come from a fake
# PowerShell; mounts, statfs and /proc are fixture files.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
T=$(fm_test_tmproot fm-storage-c-terms)
TOOL=$ROOT/bin/fm-storage-c-terms.py
# No real powershell.exe may answer a case that does not name the fake.
P=$(fm_test_base_path_sans "$PATH" powershell.exe)
GIB=1073741824
PENDING=5368709120

mkdir -p "$T/fakebin"
cat > "$T/fakebin/fake-ps" <<'SH'
#!/bin/sh
printf '%s\n' "$@" > "$FAKE_PS_DIR/argv"
if [ -f "$FAKE_PS_DIR/hang" ]; then
  echo "$$" > "$FAKE_PS_DIR/pid"
  exec sleep 60
fi
cat "$FAKE_PS_DIR/reply"
exit "$(cat "$FAKE_PS_DIR/rc" 2>/dev/null || echo 0)"
SH
chmod +x "$T/fakebin/fake-ps"
FAKE=$T/fakebin/fake-ps

sized_file() {
  python3 -c 'import sys
with open(sys.argv[1], "wb") as f:
    f.write(sys.argv[3].encode())
    f.truncate(int(sys.argv[2]))' "$1" "$2" "${3:-}"
}

mountinfo() {
  printf '170 155 %s / %s rw,relatime - %s /dev/sde rw\n' "${1:-8:64}" "$W/root" "${2:-ext4}"
  printf '220 170 %s / %s rw,noatime - 9p C:\\134 rw,aname=drvfs;path=C:\\134;uid=1000\n' \
    "${3:-0:100}" "$W/c"
}

reply() { cat > "$W/ps/reply"; }

# A world where every reading is proven: 8 GiB swap with a 1 GiB file on C:,
# a 10 GiB VSS cap with 4 GiB allocated, one fixed 4-8 GiB pagefile.
new_world() {
  W=$T/$1
  XENV=()
  PSV=("FM_STORAGE_C_POWERSHELL=$FAKE")
  mkdir -p "$W/proc/self" "$W/root" "$W/c/Users/u/AppData/Local/wsl/g1" "$W/c/swap" "$W/ps"
  mountinfo > "$W/proc/self/mountinfo"
  printf '%s 8:64 100000000000\n%s 0:100 200000000000\n' "$W/root" "$W/c" > "$W/statfs"
  printf 'Filename\t\t\t\tType\t\tSize\t\tUsed\t\tPriority\n/dev/sdc                                partition\t8388608\t\t0\t\t-2\n' \
    > "$W/proc/swaps"
  printf 'cpu  1 2 3\nbtime 4000000000\nprocesses 10\n' > "$W/proc/stat"
  sized_file "$W/c/Users/u/AppData/Local/wsl/g1/ext4.vhdx" 4096 vhdxfile
  printf '\357\273\277[wsl2]\r\nmemory=8GB\r\nswapFile=C:\\\\swap\\\\swap.vhdx # here\r\n' > "$W/c/Users/u/.wslconfig"
  sized_file "$W/c/swap/swap.vhdx" "$GIB"
  reply <<'EOF'
VOLUME|\\?\Volume{1}\
SHADOW|10737418240|4294967296|3221225472
VSS-END
PAGEFILE-AUTO|False
PAGEFILE-SETTING|C:\pagefile.sys|4096|8192
PAGEFILE-USAGE|C:\pagefile.sys|4096
PAGEFILE-END
END
EOF
}

# The tree's names, sizes, modes and mtimes, to prove a run wrote nothing; the
# fake PowerShell's own directory (its reply and recorded argv) is left out.
snapshot() {
  python3 -c 'import os, sys
for d, dirs, files in os.walk(sys.argv[1]):
    dirs[:] = sorted(x for x in dirs if os.path.join(d, x) != sys.argv[2])
    for n in sorted(dirs + files):
        st = os.lstat(os.path.join(d, n))
        print(os.path.join(d, n), st.st_size, st.st_mode, st.st_mtime_ns)' "$W" "$W/ps"
}

# run ARGS...: OUT, ERR and RC of one measure run in world W, plus the
# invariants every run keeps: an unknown reserves null, never 0, and rc 0
# exactly when nothing is unknown.
run() {
  set +e
  OUT=$(cd "$W" && env -i PATH="$P" HOME="$W/home" FAKE_PS_DIR="$W/ps" \
    FM_STORAGE_C_HOST="$W/c" FM_STORAGE_C_LINUX_ROOT="$W/root" \
    FM_STORAGE_C_PROC="$W/proc" FM_STORAGE_C_STATFS="$W/statfs" \
    FM_STORAGE_C_NOW=1800000000 ${PSV[@]+"${PSV[@]}"} \
    ${XENV[@]+"${XENV[@]}"} "$TOOL" "$@" 2> "$T/err")
  RC=$?
  set -e
  ERR=$(cat "$T/err")
  case "$RC" in
    0|75)
      jq -e '[.c_terms[] | select(.state == "unknown" and .reserved_bytes != null)] == []
        and ([.free[] | select(.state == "unknown" and .free_bytes != null)] == [])
        and ([.c_terms[] | select(.state != "unknown" and (.reserved_bytes | type) != "number")] == [])' \
        <<< "$OUT" > /dev/null || fail "$CASE: an unknown reading carries a number or a proven one does not: $OUT"
      if [ "$RC" = 0 ]; then
        assert_equals '[]' "$(j .reasons)" "$CASE: rc 0 with reasons"
        assert_equals '' "$ERR" "$CASE: rc 0 stderr"
      else
        assert_not_equals '[]' "$(j .reasons)" "$CASE: rc 75 without reasons"
      fi
      ;;
    *) assert_equals '' "$OUT" "$CASE: refusal stdout" ;;
  esac
}

measure() { run measure --linux-pending "$PENDING" "$@"; }
j() { jq -c "$1" <<< "$OUT"; }
term() { j "[.c_terms.$1 | .state, .reserved_bytes, .reason]"; }

policy() {
  printf '{"schema":"fm-storage-c-policy/v1","policy_id":"site-1","approval":"approved 2026-10-29"%s}\n' \
    "${1:-}" > "$W/policy.json"
}

# --- positive control: every term proven --------------------------------------
CASE='control'
new_world control
before=$(snapshot)
measure
expect_code 0 "$RC" "$CASE"
expected=$(cat <<EOF
{"schema":"fm-storage-c-terms/v1","sampled_at":1800000000,"free":{"linux":{"state":"measured","path":"$W/root","device":"8:64","fstype":"ext4","drive":null,"free_bytes":100000000000,"reason":null},"host-c":{"state":"measured","path":"$W/c","device":"0:100","fstype":"9p","drive":"C:","free_bytes":200000000000,"reason":null}},"c_terms":{"ext4_vhdx":{"state":"measured","source":"discovered","sampled_at":1800000000,"reason":null,"reserved_bytes":5368709120,"path":"$W/c/Users/u/AppData/Local/wsl/g1/ext4.vhdx","file_bytes":4096,"linux_free_bytes":100000000000,"linux_pending_bytes":5368709120,"growth_reserved_bytes":5368709120},"swap_vhdx":{"state":"measured","source":"runtime+wslconfig","sampled_at":1800000000,"reason":null,"reserved_bytes":7516192768,"path":"$W/c/swap/swap.vhdx","configured_bytes":8589934592,"file_bytes":1073741824,"hosting_volume":"host-c"},"vss":{"state":"measured","source":"cim","sampled_at":1800000000,"reason":null,"reserved_bytes":6442450944,"cap_bytes":10737418240,"allocated_bytes":4294967296,"used_bytes":3221225472,"cap_proven":true},"pagefile":{"state":"measured","source":"cim","sampled_at":1800000000,"reason":null,"reserved_bytes":4294967296,"mode":"fixed","allocation_bytes":4294967296,"maximum_bytes":8589934592,"operator_growth_reservation_bytes":null,"policy_id":null,"hosting_volumes":["host-c"]}},"reasons":[]}
EOF
)
assert_equals "$expected" "$OUT" "$CASE: whole object"
assert_equals '' "$ERR" "$CASE: stderr"
assert_equals "$(printf '%s\n' -NoProfile -NonInteractive -Command)" "$(head -n 3 "$W/ps/argv")" "$CASE: PowerShell flags"
assert_grep "DriveLetter='C:'" "$W/ps/argv" "$CASE: the query names host-c's drive"
rm -f "$W/ps/argv"
assert_equals "$before" "$(snapshot)" "$CASE: the run wrote nothing"
pass "control: every term measured, exact object, read-only"

# The Linux charge flows one-for-one into ext4 growth.
CASE='pending'
new_world pending
run measure --linux-pending 0
expect_code 0 "$RC" "$CASE"
assert_equals '["measured",0,null]' "$(term ext4_vhdx)" "$CASE"
run measure --linux-pending 9223372036854775807
expect_code 0 "$RC" "$CASE max"
assert_equals '9223372036854775807' "$(j .c_terms.ext4_vhdx.reserved_bytes)" "$CASE max"
pass "ext4.vhdx growth reserves the caller's Linux charge"

# --- free-space proof -----------------------------------------------------------
CASE='linux-statfs'
new_world linux-statfs
printf '%s 0:100 200000000000\n' "$W/c" > "$W/statfs"
measure
expect_code 75 "$RC" "$CASE"
assert_equals "fm-storage-c-terms: wait: cannot-measure: linux:linux-free: cannot read free space on $W/root: no statfs reading for $W/root" "$ERR" "$CASE stderr"
assert_equals '[{"code":"cannot-measure","volume":"linux","term":null,"detail":"cannot read free space on '"$W"'/root: no statfs reading for '"$W"'/root"}]' "$(j .reasons)" "$CASE reasons"
assert_equals '"measured"' "$(j .c_terms.ext4_vhdx.state)" "$CASE: ext4 still proven"
pass "unreadable Linux free space is a named unknown"

CASE='device-mismatch'
new_world device-mismatch
printf '%s 8:65 100000000000\n%s 0:100 200000000000\n' "$W/root" "$W/c" > "$W/statfs"
measure
expect_code 75 "$RC" "$CASE"
assert_equals "fm-storage-c-terms: wait: cannot-measure: linux:linux-free: $W/root is device 8:65, not the mounted 8:64" "$ERR" "$CASE"
pass "a statfs of another device than the mount entry is unknown"

CASE='not-ext4'
new_world not-ext4
mountinfo 8:64 xfs > "$W/proc/self/mountinfo"
measure
expect_code 75 "$RC" "$CASE"
assert_equals "fm-storage-c-terms: wait: cannot-measure: linux:linux-free: $W/root is xfs, not ext4 (and 1 more)" "$ERR" "$CASE"
assert_equals '["unknown",null,"the Linux root is not a proven ext4 mount"]' "$(term ext4_vhdx)" "$CASE ext4"
pass "a Linux root that is not ext4 refuses free space and ext4 growth"

CASE='no-host-mount'
new_world no-host-mount
mountinfo | head -n 1 > "$W/proc/self/mountinfo"
measure
expect_code 75 "$RC" "$CASE"
assert_equals "fm-storage-c-terms: wait: cannot-measure: host-c:host-c-free: $W/c is not a mount point (and 4 more)" "$ERR" "$CASE"
assert_equals '["host-c","host-c","host-c","host-c","host-c"]' "$(j '[.reasons[].volume]')" "$CASE volumes"
assert_equals '[null,"ext4_vhdx","swap_vhdx","vss","pagefile"]' "$(j '[.reasons[].term]')" "$CASE terms"
[ ! -e "$W/ps/argv" ] || fail "$CASE: PowerShell ran without a proven drive"
pass "an absent host-c mount never becomes Linux-only"

CASE='same-device'
new_world same-device
mountinfo 8:64 ext4 8:64 > "$W/proc/self/mountinfo"
printf '%s 8:64 100000000000\n%s 8:64 100000000000\n' "$W/root" "$W/c" > "$W/statfs"
measure
expect_code 75 "$RC" "$CASE"
assert_equals "fm-storage-c-terms: wait: cannot-measure: host-c:host-c-free: $W/c is the Linux root device, not a separate drive" "$ERR" "$CASE"
pass "host-c on the Linux root's device is unknown"

CASE='no-mountinfo'
new_world no-mountinfo
rm "$W/proc/self/mountinfo"
measure
expect_code 75 "$RC" "$CASE"
assert_equals '6' "$(j '.reasons | length')" "$CASE"
assert_contains "$ERR" "fm-storage-c-terms: wait: cannot-measure: linux:linux-free: cannot read the mount table:" "$CASE"
pass "an unreadable mount table makes every reading unknown"

# --- ext4.vhdx ------------------------------------------------------------------
CASE='two-vhdx'
new_world two-vhdx
mkdir -p "$W/c/Users/u/AppData/Local/Packages/Distro/LocalState"
sized_file "$W/c/Users/u/AppData/Local/Packages/Distro/LocalState/ext4.vhdx" 8192 vhdxfile
measure
expect_code 75 "$RC" "$CASE"
assert_equals '["unknown",null,"2 ext4.vhdx files found on host-c; name one in the site policy"]' "$(term ext4_vhdx)" "$CASE"
policy ",\"ext4_vhdx\":\"$W/c/Users/u/AppData/Local/Packages/Distro/LocalState/ext4.vhdx\""
measure --policy "$W/policy.json"
expect_code 0 "$RC" "$CASE policy"
assert_equals '["policy",8192]' "$(j '[.c_terms.ext4_vhdx.source, .c_terms.ext4_vhdx.file_bytes]')" "$CASE policy"
pass "several ext4.vhdx files are unknown until the policy names one"

CASE='no-vhdx'
new_world no-vhdx
rm "$W/c/Users/u/AppData/Local/wsl/g1/ext4.vhdx"
measure
expect_code 75 "$RC" "$CASE"
assert_equals '["unknown",null,"no ext4.vhdx found on host-c"]' "$(term ext4_vhdx)" "$CASE"
pass "a missing ext4.vhdx is unknown"

CASE='bad-header'
new_world bad-header
sized_file "$W/c/Users/u/AppData/Local/wsl/g1/ext4.vhdx" 4096 notavhdx
measure
expect_code 75 "$RC" "$CASE"
assert_equals '["unknown",null,"'"$W"'/c/Users/u/AppData/Local/wsl/g1/ext4.vhdx has no vhdxfile signature"]' "$(term ext4_vhdx)" "$CASE"
pass "an ext4.vhdx without the VHDX signature is unknown"

CASE='off-host'
new_world off-host
sized_file "$W/root/ext4.vhdx" 4096 vhdxfile
policy ",\"ext4_vhdx\":\"$W/root/ext4.vhdx\""
measure --policy "$W/policy.json"
expect_code 75 "$RC" "$CASE"
assert_equals '["unknown",null,"'"$W"'/root/ext4.vhdx is not on the host-c mount"]' "$(term ext4_vhdx)" "$CASE"
pass "an ext4.vhdx off the host-c mount is unknown"

# --- WSL swap -------------------------------------------------------------------
CASE='no-swap'
new_world no-swap
printf 'Filename\t\t\t\tType\t\tSize\t\tUsed\t\tPriority\n/dev/zram0 partition 4194304 0 100\n/swapfile file 1048576 0 -3\n' > "$W/proc/swaps"
measure
expect_code 0 "$RC" "$CASE"
assert_equals '["not-applicable",0,"no swap disk is active in this VM boot"]' "$(term swap_vhdx)" "$CASE"
pass "no WSL swap disk (zram and in-filesystem files aside) reserves 0 with evidence"

CASE='swap-missing-file'
new_world swap-missing-file
rm "$W/c/swap/swap.vhdx"
measure
expect_code 0 "$RC" "$CASE"
assert_equals '["bounded",8589934592]' "$(j '[.c_terms.swap_vhdx.state, .c_terms.swap_vhdx.reserved_bytes]')" "$CASE"
assert_contains "$(j .c_terms.swap_vhdx.reason)" "so the whole running size is reserved" "$CASE"
pass "a swapFile on C: that cannot be read reserves the whole running size"

CASE='swap-file-full'
new_world swap-file-full
sized_file "$W/c/swap/swap.vhdx" 9663676416
measure
expect_code 0 "$RC" "$CASE"
assert_equals '["measured",0,null]' "$(term swap_vhdx)" "$CASE"
pass "a swap file already past the running size reserves 0"

CASE='swap-other-drive'
new_world swap-other-drive
printf '[wsl2]\nswapFile = "D:\\swap\\swap.vhdx"\n' > "$W/c/Users/u/.wslconfig"
measure
expect_code 0 "$RC" "$CASE"
assert_equals '["not-applicable",0,"D:"]' "$(j '[.c_terms.swap_vhdx | .state, .reserved_bytes, .hosting_volume]')" "$CASE"
pass "a swapFile on another drive is not a host-c term"

CASE='swap-default'
new_world swap-default
printf '[wsl2]\nmemory=8GB\n[other]\nswapFile=C:\\\\x.vhdx\n' > "$W/c/Users/u/.wslconfig"
measure
expect_code 0 "$RC" "$CASE"
assert_equals '["bounded",8589934592,"runtime+default",null,"host-c"]' \
  "$(j '[.c_terms.swap_vhdx | .state, .reserved_bytes, .source, .path, .hosting_volume]')" "$CASE"
rm "$W/c/Users/u/.wslconfig"
measure
expect_code 0 "$RC" "$CASE absent config"
assert_equals '["bounded",8589934592,"runtime+default"]' "$(j '[.c_terms.swap_vhdx | .state, .reserved_bytes, .source]')" "$CASE absent config"
pass "the default swap location reserves the whole running size"

CASE='swap-after-boot'
new_world swap-after-boot
printf 'btime 1000\n' > "$W/proc/stat"
measure
expect_code 75 "$RC" "$CASE"
assert_equals "fm-storage-c-terms: wait: cannot-measure: host-c:swap_vhdx: $W/c/Users/u/.wslconfig changed after this VM booted, so the running swap location is not proven" "$ERR" "$CASE"
pass "a .wslconfig edited after boot leaves the swap location unknown"

CASE='swap-config-dir'
new_world swap-config-dir
rm "$W/c/Users/u/.wslconfig"
mkdir "$W/c/Users/u/.wslconfig"
measure
expect_code 75 "$RC" "$CASE"
assert_equals '["unknown",null,"'"$W"'/c/Users/u/.wslconfig is not a regular file"]' "$(term swap_vhdx)" "$CASE"
pass "a .wslconfig that is not a regular file is unknown, not absent"

CASE='swap-bad-proc'
new_world swap-bad-proc
rm "$W/proc/swaps"
measure
expect_code 75 "$RC" "$CASE"
assert_contains "$ERR" "host-c:swap_vhdx: cannot read the running swap from $W/proc/swaps:" "$CASE absent"
printf 'Filename Type Size Used Priority\n/dev/sdc partition lots 0 -2\n' > "$W/proc/swaps"
measure
expect_code 75 "$RC" "$CASE malformed"
assert_equals '["unknown",null,"cannot read the running swap from '"$W"'/proc/swaps: malformed size"]' "$(term swap_vhdx)" "$CASE malformed"
printf 'Filename Type Size Used Priority\n/dev/sdc partition 9007199254740992 0 -2\n' > "$W/proc/swaps"
measure
expect_code 75 "$RC" "$CASE overflow"
assert_equals '["unknown",null,"cannot read the running swap from '"$W"'/proc/swaps: swap size past the integer ceiling"]' "$(term swap_vhdx)" "$CASE overflow"
pass "an unreadable, malformed or overflowing swap table is unknown"

# --- VSS ------------------------------------------------------------------------
vss_reply() {
  { printf 'VOLUME|\\\\?\\Volume{1}\\\n'; cat; printf 'VSS-END\nPAGEFILE-AUTO|False\nPAGEFILE-END\nEND\n'; } > "$W/ps/reply"
}

CASE='vss-off'
new_world vss-off
vss_reply < /dev/null
measure
expect_code 0 "$RC" "$CASE"
assert_equals '["not-applicable",0,0,0,0,true]' "$(j '[.c_terms.vss | .state, .reserved_bytes, .cap_bytes, .allocated_bytes, .used_bytes, .cap_proven]')" "$CASE"
pass "no shadow storage on C: reserves 0 with evidence"

CASE='vss-unbounded'
new_world vss-unbounded
printf 'SHADOW|18446744073709551615|4294967296|3221225472\n' | vss_reply
measure
expect_code 75 "$RC" "$CASE"
assert_equals '["unknown",null,"shadow storage on C: has no cap (unbounded)"]' "$(term vss)" "$CASE"
assert_equals 'false' "$(j .c_terms.vss.cap_proven)" "$CASE"
pass "an unbounded shadow storage cap is unknown"

CASE='vss-recycled'
new_world vss-recycled
printf 'SHADOW|10737418240|12884901888|10737418240\n' | vss_reply
measure
expect_code 0 "$RC" "$CASE"
assert_equals '["measured",0,null]' "$(term vss)" "$CASE"
pass "shadow storage at its cap (recycling) reserves 0"

CASE='vss-two-rows'
new_world vss-two-rows
printf 'SHADOW|10737418240|4294967296|1\nSHADOW|2147483648|1073741824|1\n' | vss_reply
measure
expect_code 0 "$RC" "$CASE"
assert_equals '[7516192768,12884901888,5368709120,2]' "$(j '[.c_terms.vss | .reserved_bytes, .cap_bytes, .allocated_bytes, .used_bytes]')" "$CASE"
pass "several diff areas on C: sum"

CASE='vss-alloc-unreadable'
new_world vss-alloc-unreadable
printf 'SHADOW|10737418240||\n' | vss_reply
measure
expect_code 0 "$RC" "$CASE"
assert_equals '["bounded",10737418240,null,null,true]' "$(j '[.c_terms.vss | .state, .reserved_bytes, .allocated_bytes, .used_bytes, .cap_proven]')" "$CASE"
pass "a proven cap with unreadable usage reserves the whole cap"

CASE='vss-overflow'
new_world vss-overflow
printf 'SHADOW|9223372036854775807|0|0\nSHADOW|1|0|0\n' | vss_reply
measure
expect_code 75 "$RC" "$CASE"
assert_equals '["unknown",null,"shadow storage cap is past the integer ceiling"]' "$(term vss)" "$CASE"
pass "a shadow storage sum past the ceiling is unknown"

CASE='vss-error'
new_world vss-error
reply <<'EOF'
VSS-ERROR|Access is denied.
PAGEFILE-AUTO|False
PAGEFILE-SETTING|C:\pagefile.sys|4096|8192
PAGEFILE-USAGE|C:\pagefile.sys|4096
PAGEFILE-END
END
EOF
measure
expect_code 75 "$RC" "$CASE"
assert_equals "fm-storage-c-terms: wait: cannot-measure: host-c:vss: shadow storage query failed: Access is denied." "$ERR" "$CASE"
assert_equals '["measured",4294967296,null]' "$(term pagefile)" "$CASE: pagefile still read"
pass "a failed shadow storage query is unknown, not 'no restore points'"

CASE='vss-no-end'
new_world vss-no-end
reply <<'EOF'
VOLUME|\\?\Volume{1}\
PAGEFILE-AUTO|False
PAGEFILE-END
END
EOF
measure
expect_code 75 "$RC" "$CASE"
assert_equals '["unknown",null,"shadow storage query failed: no end marker"]' "$(term vss)" "$CASE"
printf 'VSS-END\nPAGEFILE-AUTO|False\nPAGEFILE-END\nEND\n' > "$W/ps/reply"
measure
expect_code 75 "$RC" "$CASE no volume"
assert_equals '["unknown",null,"shadow storage query named no single C: volume"]' "$(term vss)" "$CASE no volume"
pass "a shadow storage reply without its end marker or volume is unknown"

# --- the PowerShell call ----------------------------------------------------------
CASE='ps-timeout'
new_world ps-timeout
: > "$W/ps/hang"
XENV=(FM_STORAGE_C_POWERSHELL_TIMEOUT=1)
measure
expect_code 75 "$RC" "$CASE"
assert_equals "fm-storage-c-terms: wait: cannot-measure: host-c:vss: Windows reading unavailable: PowerShell timed out after 1s (and 1 more)" "$ERR" "$CASE"
assert_equals '["unknown",null,"Windows reading unavailable: PowerShell timed out after 1s"]' "$(term pagefile)" "$CASE"
# A loaded runner may kill the fake before it records its pid.
if [ -f "$W/ps/pid" ] && kill -0 "$(cat "$W/ps/pid")" 2> /dev/null; then
  fail "$CASE: the timed-out PowerShell is still running"
fi
pass "a PowerShell call past its timeout is killed and both Windows terms are unknown"

CASE='ps-incomplete'
new_world ps-incomplete
sed '$d' "$W/ps/reply" > "$W/reply.cut" && mv "$W/reply.cut" "$W/ps/reply"
measure
expect_code 75 "$RC" "$CASE"
assert_equals '["unknown",null,"Windows reading unavailable: PowerShell output is incomplete"]' "$(term vss)" "$CASE"
echo 3 > "$W/ps/rc"
reply <<'EOF'
END
EOF
measure
expect_code 75 "$RC" "$CASE exit"
assert_equals '["unknown",null,"Windows reading unavailable: PowerShell exited 3"]' "$(term vss)" "$CASE exit"
pass "an incomplete or failed PowerShell reply is unknown"

CASE='ps-none'
new_world ps-none
PSV=(FM_STORAGE_C_POWERSHELL=)
measure
expect_code 75 "$RC" "$CASE"
assert_equals "fm-storage-c-terms: wait: cannot-measure: host-c:vss: Windows reading unavailable: no PowerShell command (and 1 more)" "$ERR" "$CASE"
pass "no PowerShell means unknown VSS and pagefile, never zero"

CASE='ps-lookup'
new_world ps-lookup
mkdir -p "$W/bin" "$W/c/Windows/System32/WindowsPowerShell/v1.0"
cp "$FAKE" "$W/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe"
PSV=()
measure
expect_code 0 "$RC" "$CASE host fallback"
cp "$FAKE" "$W/bin/powershell.exe"
rm "$W/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe" "$W/ps/argv"
XENV=(PATH="$W/bin:$P")
measure
expect_code 0 "$RC" "$CASE PATH"
[ -f "$W/ps/argv" ] || fail "$CASE: powershell.exe on PATH did not run"
pass "PowerShell resolves from PATH, then from host-c's Windows directory"

# --- pagefile -------------------------------------------------------------------
pf_reply() {
  { printf 'VOLUME|\\\\?\\Volume{1}\\\nVSS-END\n'; cat; printf 'PAGEFILE-END\nEND\n'; } > "$W/ps/reply"
}

CASE='pf-auto'
new_world pf-auto
printf 'PAGEFILE-AUTO|True\nPAGEFILE-USAGE|C:\\pagefile.sys|6144\n' | pf_reply
measure
expect_code 75 "$RC" "$CASE"
assert_equals "fm-storage-c-terms: wait: cannot-measure: host-c:pagefile: the C: pagefile is system-managed and the site policy has no approved growth budget" "$ERR" "$CASE"
assert_equals '["system-managed",6442450944]' "$(j '[.c_terms.pagefile | .mode, .allocation_bytes]')" "$CASE"
policy
measure --policy "$W/policy.json"
expect_code 75 "$RC" "$CASE policy without budget"
assert_equals '"site-1"' "$(j .c_terms.pagefile.policy_id)" "$CASE policy without budget"
policy ',"pagefile_system_managed_growth_bytes":2147483648'
measure --policy "$W/policy.json"
expect_code 0 "$RC" "$CASE budget"
assert_equals '["bounded","cim+policy",2147483648,2147483648,"site-1"]' \
  "$(j '[.c_terms.pagefile | .state, .source, .reserved_bytes, .operator_growth_reservation_bytes, .policy_id]')" "$CASE budget"
pass "a system-managed pagefile needs the approved growth budget, never its current use"

CASE='pf-file-managed'
new_world pf-file-managed
printf 'PAGEFILE-AUTO|False\nPAGEFILE-SETTING|C:\\pagefile.sys|0|0\nPAGEFILE-USAGE|C:\\pagefile.sys|2048\n' | pf_reply
measure
expect_code 75 "$RC" "$CASE"
assert_equals '["system-managed","unknown",null]' "$(j '[.c_terms.pagefile | .mode, .state, .reserved_bytes]')" "$CASE"
pass "a per-file system-managed size counts as system-managed"

CASE='pf-fixed-many'
new_world pf-fixed-many
pf_reply <<'EOF'
PAGEFILE-AUTO|False
PAGEFILE-SETTING|C:\pagefile.sys|4096|8192
PAGEFILE-SETTING|c:\extra.sys|1024|1024
PAGEFILE-SETTING|D:\pagefile.sys|1024|4096
PAGEFILE-USAGE|C:\PAGEFILE.SYS|4096
PAGEFILE-USAGE|C:\extra.sys|2048
PAGEFILE-USAGE|D:\pagefile.sys|1024
EOF
measure
expect_code 0 "$RC" "$CASE"
assert_equals '["fixed",4294967296,6442450944,9663676416,["host-c","D:"]]' \
  "$(j '[.c_terms.pagefile | .mode, .reserved_bytes, .allocation_bytes, .maximum_bytes, .hosting_volumes]')" "$CASE"
pass "fixed pagefiles reserve maximum minus allocated per C: file, clamped at 0"

CASE='pf-off'
new_world pf-off
printf 'PAGEFILE-AUTO|False\n' | pf_reply
measure
expect_code 0 "$RC" "$CASE"
assert_equals '["off","not-applicable",0,[]]' "$(j '[.c_terms.pagefile | .mode, .state, .reserved_bytes, .hosting_volumes]')" "$CASE"
printf 'PAGEFILE-AUTO|False\nPAGEFILE-SETTING|D:\\pagefile.sys|4096|8192\nPAGEFILE-USAGE|D:\\pagefile.sys|4096\n' | pf_reply
measure
expect_code 0 "$RC" "$CASE other drive"
assert_equals '["off",0,["D:"]]' "$(j '[.c_terms.pagefile | .mode, .reserved_bytes, .hosting_volumes]')" "$CASE other drive"
pass "no pagefile on C: reserves 0 with evidence"

CASE='pf-pending'
new_world pf-pending
printf 'PAGEFILE-AUTO|False\nPAGEFILE-SETTING|C:\\pagefile.sys|4096|8192\nPAGEFILE-USAGE|C:\\old.sys|4096\n' | pf_reply
measure
expect_code 75 "$RC" "$CASE"
assert_equals '["unknown",null,"the C: pagefile settings and allocations name different files (a change waits for a restart)"]' "$(term pagefile)" "$CASE"
pass "pagefile settings that differ from what is allocated are unknown"

CASE='pf-bad'
new_world pf-bad
printf 'PAGEFILE-AUTO|False\nPAGEFILE-SETTING|C:\\pagefile.sys|4096|lots\n' | pf_reply
measure
expect_code 75 "$RC" "$CASE"
assert_equals '["unknown",null,"unreadable pagefile row C:\\pagefile.sys"]' "$(term pagefile)" "$CASE"
printf 'PAGEFILE-SETTING|C:\\pagefile.sys|4096|8192\nPAGEFILE-USAGE|C:\\pagefile.sys|4096\n' | pf_reply
measure
expect_code 75 "$RC" "$CASE no auto"
assert_equals '["unknown",null,"automatic pagefile management is unreadable"]' "$(term pagefile)" "$CASE no auto"
reply <<'EOF'
VOLUME|\\?\Volume{1}\
VSS-END
PAGEFILE-ERROR|Invalid class
END
EOF
measure
expect_code 75 "$RC" "$CASE error"
assert_equals '["unknown",null,"pagefile query failed: Invalid class"]' "$(term pagefile)" "$CASE error"
pass "an unreadable or failed pagefile reading is unknown"

# --- misuse and policy --------------------------------------------------------------
refused() {
  expect_code 2 "$RC" "$CASE"
  assert_equals "fm-storage-c-terms: refused: $1" "$ERR" "$CASE"
}

CASE='usage'
new_world usage
run
refused 'usage: expected the measure command (see --help)'
run measure
refused 'usage: measure needs --linux-pending BYTES'
for bad in -1 1.5 '' 9223372036854775808 0x10; do
  run measure --linux-pending "$bad"
  refused "usage: --linux-pending $bad is not a nonnegative integer of at most 2**63-1"
done
run measure --linux-pending 1 --linux-pending 2
refused 'usage: --linux-pending given twice'
run measure --linux-pending 1 --bogus
refused 'usage: unexpected argument --bogus (see --help)'
run --help
expect_code 0 "$RC" "$CASE help"
assert_contains "$OUT" "fm-storage-c-terms.py measure --linux-pending BYTES" "$CASE help"
pass "misuse refuses with exit 2 and empty stdout"

CASE='policy'
new_world policy
measure --policy "$W/absent.json"
refused "policy: cannot read $W/absent.json: No such file or directory"
policy ',"extra":1'
measure --policy "$W/policy.json"
refused "policy: $W/policy.json has unknown key extra"
printf '{"schema":"fm-storage-c-policy/v2","policy_id":"a","approval":"b"}' > "$W/policy.json"
measure --policy "$W/policy.json"
refused "policy: $W/policy.json schema is not fm-storage-c-policy/v1"
printf '{"schema":"fm-storage-c-policy/v1","policy_id":"a","approval":""}' > "$W/policy.json"
measure --policy "$W/policy.json"
refused "policy: $W/policy.json approval is missing or invalid"
printf '{"schema":"fm-storage-c-policy/v1","policy_id":"a b","approval":"x"}' > "$W/policy.json"
measure --policy "$W/policy.json"
refused "policy: $W/policy.json policy_id is missing or invalid"
for budget in -1 true 1.5 '"1"' 9223372036854775808; do
  policy ",\"pagefile_system_managed_growth_bytes\":$budget"
  measure --policy "$W/policy.json"
  refused "policy: $W/policy.json pagefile_system_managed_growth_bytes is not a nonnegative integer"
done
policy ',"wslconfig":"relative/.wslconfig"'
measure --policy "$W/policy.json"
refused "policy: $W/policy.json wslconfig is not an absolute path"
printf '{"schema":"fm-storage-c-policy/v1","schema":"fm-storage-c-policy/v1","policy_id":"a","approval":"x"}' > "$W/policy.json"
measure --policy "$W/policy.json"
refused "policy: $W/policy.json is not valid JSON: duplicate key"
printf '[1]' > "$W/policy.json"
measure --policy "$W/policy.json"
refused "policy: $W/policy.json is not a JSON object"
policy ",\"wslconfig\":\"$W/elsewhere/.wslconfig\""
measure --policy "$W/policy.json"
expect_code 75 "$RC" "$CASE wslconfig path"
assert_equals '["unknown",null,"the Windows profile '"$W"'/elsewhere is not proven on host-c"]' "$(term swap_vhdx)" "$CASE wslconfig path"
pass "an invalid policy refuses with exit 2 before any reading"
