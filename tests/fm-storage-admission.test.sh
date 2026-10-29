#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2016
# Behavior tests for the storage admission owner: bin/fm-disk-room.sh
# reserve-token and release-token (interface v3) with
# bin/fm-storage-admission-lib.sh, the site policy and the strict C: terms port.
#
# Every case runs against a PATH-shimmed df that reports fixture sizes for a
# fake Windows drive, a fake Linux root and a fake D: results directory, a stat
# shim that gives the fake D: mount its own filesystem identity, a fixture
# C: terms measurer that prints a fixture fm-storage-c-terms/v1 object, and a
# flock shim that marks when an admission waits for the shared state lock. One
# case runs the real bin/fm-storage-c-terms.py against fixture mounts, statfs,
# /proc and a fake PowerShell. Nothing reads the real disk, Windows, WMI, the
# pagefile or the shadow storage.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

unset FM_DISK_ROOM_VHDX FM_DISK_ROOM_DEV_SIZE FM_DISK_ROOM_MARGIN FM_DISK_ROOM_NOW FM_DISK_ROOM_COMPACT_RESULT FM_DISK_ROOM_STATE \
  FM_DISK_ROOM_SHADOW_RECORD FM_DISK_ROOM_SHADOW_MAX FM_DISK_ROOM_WEVTUTIL FM_DISK_ROOM_POWERSHELL FM_DISK_ROOM_RESULTS_ROOT \
  FM_DISK_ROOM_SAMPLES FM_DISK_ROOM_GROWTH_MAX FM_DISK_ROOM_C_FREE_MIN FM_DISK_ROOM_D_FREE_MIN FM_STORAGE_MNT \
  FM_DISK_ROOM_WSLCONFIG FM_DISK_ROOM_MEMINFO FM_DISK_ROOM_WRITE_PROC FM_CONFIG_OVERRIDE FM_INHERITABLE_CONFIG \
  FM_DISK_ROOM_POLICY FM_DISK_ROOM_LOCK_WAIT FM_DISK_ROOM_RANDOM FM_DISK_ROOM_BULK_MARGIN FM_STORAGE_RESULTS_ROOT
TMP_ROOT=$(fm_test_tmproot fm-storage-admission)
DISK_ROOM="$ROOT/bin/fm-disk-room.sh"
GIB=1073741824
MAX=999999999999999999
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
DFDIR="$TMP_ROOT/df"
HOSTDIR="$TMP_ROOT/c"
LINUXDIR="$TMP_ROOT/root"
STATE="$TMP_ROOT/state"
POLICY="$TMP_ROOT/storage-admission"
CTERMS="$TMP_ROOT/cterms.json"
CFG="$TMP_ROOT/storage"
DMNT="$TMP_ROOT/mnt/d"
DROOT="$DMNT/lattice-data/tetjet-results"
mkdir -p "$DFDIR" "$HOSTDIR" "$LINUXDIR"
MY_START=$(awk '{ sub(/^.*\) /, ""); print $20 }' "/proc/$$/stat")
AS_ROOT=0
[ "$(id -u)" != 0 ] || AS_ROOT=1

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
# flock shim: marks the waiting owner process, then waits on the real lock.
cat >"$FAKEBIN/flock" <<SH
#!/usr/bin/env bash
[ -z "\${FAKE_FLOCK_SEEN:-}" ] || : >"\$FAKE_FLOCK_SEEN/\$PPID"
exec $(command -v flock) "\$@"
SH
chmod +x "$FAKEBIN/flock"
# The C: terms measurer port: records its arguments, prints $FAKE_CTERMS and
# exits with $FAKE_CTERMS_RC (default 0).
cat >"$FAKEBIN/measurer" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FAKE_CTERMS.args"
cat "$FAKE_CTERMS"
exit "${FAKE_CTERMS_RC:-0}"
SH
chmod +x "$FAKEBIN/measurer"
for stub in wevtutil-stub powershell-stub; do
  printf '#!/usr/bin/env bash\nexit 1\n' >"$FAKEBIN/$stub"
  chmod +x "$FAKEBIN/$stub"
done

key() { printf '%s' "$1" | tr / _; }

# set_sizes HOST_FREE_GIB LINUX_FREE_GIB LINUX_USED_GIB
set_sizes() {
  printf '%s\n' $(( $1 * GIB )) >"$DFDIR/$(key "$HOSTDIR").avail"
  printf '%s\n' $(( $2 * GIB )) >"$DFDIR/$(key "$LINUXDIR").avail"
  printf '%s\n' $(( $3 * GIB )) >"$DFDIR/$(key "$LINUXDIR").used"
  printf '%s\n' $(( ($2 + $3) * GIB )) >"$DFDIR/$(key "$LINUXDIR").size"
}

run_adm() {
  FM_HOME="$TMP_ROOT/home-unset" \
  PATH="$FAKEBIN:$PATH" FAKE_DF="$DFDIR" FAKE_BULK_MNT="$TMP_ROOT/mnt" \
    FAKE_CTERMS="$CTERMS" FAKE_CTERMS_RC="${FAKE_CTERMS_RC-}" FAKE_FLOCK_SEEN="${FAKE_FLOCK_SEEN-}" \
    FM_STORAGE_CONFIG="$CFG" FM_STORAGE_MNT="$TMP_ROOT/mnt" FM_STORAGE_MOUNTINFO="$TMP_ROOT/mountinfo" \
    FM_DISK_ROOM_POLICY="$POLICY" FM_DISK_ROOM_MARGIN="${TEST_MARGIN-1G}" \
    FM_DISK_ROOM_HOST="$HOSTDIR" FM_DISK_ROOM_ROOT="$LINUXDIR" FM_DISK_ROOM_STATE="$STATE" \
    FM_DISK_ROOM_MB_GROUPS="$TMP_ROOT/no-mb_groups" FM_DISK_ROOM_DEV_SIZE=0 \
    FM_DISK_ROOM_WEVTUTIL=wevtutil-stub FM_DISK_ROOM_POWERSHELL=powershell-stub \
    FM_DISK_ROOM_RESULTS_ROOT="$CFG/results-root" FM_DISK_ROOM_SAMPLES="$TMP_ROOT/no-samples" \
    FM_DISK_ROOM_C_FREE_MIN=off FM_DISK_ROOM_WSLCONFIG='' FM_DISK_ROOM_MEMINFO="$TMP_ROOT/no-meminfo" \
    FM_DISK_ROOM_BOOT_ID="$TMP_ROOT/boot_id" \
    FM_DISK_ROOM_LOCK_WAIT="${FM_DISK_ROOM_LOCK_WAIT-}" FM_DISK_ROOM_RANDOM="${FM_DISK_ROOM_RANDOM-}" \
    "$DISK_ROOM" "$@"
}

# try ARGS...: runs the owner; sets RC, OUT (stdout) and ERRT (stderr).
try() {
  OUT=$(run_adm "$@" 2>"$TMP_ROOT/stderr"); RC=$?
  ERRT=$(cat "$TMP_ROOT/stderr")
}

# expect_err RC STDERR LABEL: the exact exit and stderr line, and no stdout.
expect_err() {
  expect_code "$1" "$RC" "$3"
  assert_equals "$2" "$ERRT" "$3: stderr"
  assert_equals '' "$OUT" "$3: stdout"
}

# expect_token LABEL: admitted; the token is the only output.
expect_token() {
  expect_code 0 "$RC" "$1"
  assert_equals '' "$ERRT" "$1: stderr"
  case "$OUT" in *[!0-9a-f]*|'') fail "$1: token is not lowercase hex: '$OUT'" ;; esac
  assert_equals 64 "${#OUT}" "$1: token length"
  TOKEN=$OUT
}

# lin|hostc|dvol NAME BYTES [ARGS...]: one admission for task job, class
# results, owned by this test shell.
lin() { local n=$1 b=$2; shift 2; try reserve-token job --volume linux --class results --name "$n" --bytes "$b" --pid "$$" "$@"; }
hostc() { local n=$1 b=$2; shift 2; try reserve-token job --volume host-c --class results --name "$n" --bytes "$b" --pid "$$" "$@"; }
dvol() { local n=$1 b=$2; shift 2; try reserve-token job --volume d --class results --name "$n" --bytes "$b" --pid "$$" --root "$DROOT" "$@"; }

json_field() { printf '%s\n' "$1" | sed -n "s/.*\"$2\":\([^,}]*\).*/\1/p"; }
reserved() { json_field "$(run_adm status --json)" reserved; }

write_policy() { { printf 'fm-storage-admission-policy/v1\n'; printf '%s\n' "$@"; } >"$POLICY"; }
strict_policy() { write_policy admission=on c-terms=strict "c-terms-command=$FAKEBIN/measurer" c-terms-arg=--volume c-terms-arg=C: "$@"; }

# term STATE RESERVED REASON EXTRA: one c_terms term with every common key.
term() { printf '{"state":"%s","source":"fixture","sampled_at":"2026-10-29T00:00:00Z","reason":%s,"reserved_bytes":%s,%s}' "$1" "$3" "$2" "$4"; }

# write_cterms SWAP VSS PAGEFILE: the measurer's fm-storage-c-terms/v1
# object, every term measured with these reserved bytes. CT_PF_STATE,
# CT_PF_REASON, CT_VSS_STATE, CT_VSS_PROVEN, CT_EXTRA (a raw suffix of
# c_terms), CT_TOP (a raw top-level suffix), CT_SCHEMA and CT_REASONS (the raw
# reasons array) vary it.
write_cterms() {
  local pf_state=${CT_PF_STATE:-measured} pf_res=$3 pf_reason=null
  [ "$pf_state" != unknown ] || pf_res=null
  [ -z "${CT_PF_REASON:-}" ] || pf_reason="\"$CT_PF_REASON\""
  printf '{"schema":"%s","sampled_at":1793000000,"free":{},"c_terms":{"ext4_vhdx":%s,"swap_vhdx":%s,"vss":%s,"pagefile":%s%s},"reasons":%s%s}\n' \
    "${CT_SCHEMA:-fm-storage-c-terms/v1}" \
    "$(term measured 0 null '"path":null,"file_bytes":null,"linux_free_bytes":null,"linux_pending_bytes":null,"growth_reserved_bytes":null')" \
    "$(term measured "$1" null '"path":null,"configured_bytes":null,"file_bytes":null,"hosting_volume":null')" \
    "$(term "${CT_VSS_STATE:-measured}" "$2" null "\"cap_bytes\":null,\"allocated_bytes\":null,\"used_bytes\":null,\"cap_proven\":${CT_VSS_PROVEN:-true}")" \
    "$(term "$pf_state" "$pf_res" "$pf_reason" '"mode":"system-managed","allocation_bytes":null,"maximum_bytes":null,"operator_growth_reservation_bytes":null,"policy_id":null,"hosting_volumes":["C:"]')" \
    "${CT_EXTRA:-}" "${CT_REASONS:-[]}" "${CT_TOP:-}" >"$CTERMS"
}

# reason VOLUME TERM DETAIL: one measurer reason; TERM null is a free reading.
reason() { printf '{"code":"cannot-measure","volume":"%s","term":%s,"detail":"%s"}' "$1" "$2" "$3"; }

# setup_world: C: 20 GiB free, Linux 10 GiB free, margin 1 GiB, strict terms
# swap 1, shadow storage 2 and pagefile 3 GiB. Linux tokens may take 9 GiB
# (Linux limits) and host-c tokens 20 - 6 - 1 = 13 GiB.
setup_world() {
  chmod -R u+rwx "$STATE" 2>/dev/null
  rm -rf "$STATE" "$CFG" "${TMP_ROOT:?}/mnt" "$TMP_ROOT/mountinfo" "$CTERMS.args" "$TMP_ROOT/random"
  set_sizes 20 10 5
  printf 'boot-a\n' >"$TMP_ROOT/boot_id"
  strict_policy
  write_cterms "$GIB" $((2 * GIB)) $((3 * GIB))
}

# setup_d: a verified D: publication whose results directory has 100 GiB free
# (the D: margin is 50 GiB).
setup_d() {
  mkdir -p "$CFG" "$DROOT"
  printf 'volume-d\n' >"$DMNT/lattice-data/.lattice-storage-id"
  printf 'uniqueid=volume-d\n' >"$CFG/ssd-identity"
  printf '1 2 0:1 / %s rw - 9p D: rw\n' "$DMNT" >"$TMP_ROOT/mountinfo"
  printf '%s/{task}\nformat=lattice-storage-results-root/v1\nactive=ssd\nstate=ok\nssd_letter=D\nssd_fs=exFAT\nssd_id=volume-d\nssd_marker=%s/lattice-data/.lattice-storage-id\nssd_device=999\nchecked_at=%s\n' \
    "$DROOT" "$DMNT" "$(date +%s)" >"$CFG/results-root"
  printf '%s\n' $((100 * GIB)) >"$DFDIR/$(key "$DROOT").avail"
}

# v2_record FILE TOKEN START BOOT VOLUME NAME BYTES: a token record as the owner writes it.
v2_record() {
  printf 'bytes=%s\npid=%s\nstart=%s\nformat=fm-storage-admission/v1\ntoken=%s\ntask=job\nclass=results\nvolume=%s\nname=%s\nboot=%s\nadmitted=1\n' \
    "$7" "$$" "$3" "$2" "$5" "$6" "$4" >"$1"
}

# hex64 CHARS: CHARS repeated to a 64-character token.
hex64() { local s=''; while [ "${#s}" -lt 64 ]; do s=$s$1; done; printf '%s' "$s"; }

test_inert_without_policy() {
  setup_world
  rm -f "$POLICY"
  lin a 1
  expect_err 2 "fm-storage: refused: not-activated: no storage admission policy at $POLICY" "no policy refuses token admission"
  assert_absent "$STATE" "a refused admission creates no owner state"
  assert_absent "$CTERMS.args" "no policy never runs the measurer"
  OUT=$(run_adm --interface v1); RC=$?
  expect_code 0 "$RC" "v1 without a policy"
  assert_equals fm-disk-room-interface/v1 "$OUT" "v1 is served without a policy"
  OUT=$(run_adm --interface); RC=$?
  assert_equals fm-disk-room-interface/v3 "$OUT" "the current interface is v3"
  write_policy admission=off c-terms=strict "c-terms-command=$FAKEBIN/measurer"
  lin a 1
  expect_err 2 "fm-storage: refused: not-activated: admission=off in $POLICY" "admission=off refuses"
  write_policy admission=on c-terms=off
  lin a 1
  expect_err 2 "fm-storage: refused: not-activated: linux admissions need c-terms=strict in $POLICY" "linux needs strict C: terms"
  hostc a 1
  expect_err 2 "fm-storage: refused: not-activated: host-c admissions need c-terms=strict in $POLICY" "host-c needs strict C: terms"
  OUT=$(run_adm --interface v2); RC=$?
  expect_code 0 "$RC" "v2 with c-terms=off"
  assert_equals fm-disk-room-interface/v2 "$OUT" "v2 is served while C: terms are not strict"
  assert_absent "$CTERMS.args" "c-terms=off never runs the measurer"
  pass "without a policy, or with admission or strict terms off, nothing is admitted and older interfaces stay served"
}

test_linux_exact_boundary() {
  setup_world
  lin lin $((9 * GIB))
  expect_token "Linux admits exactly its room minus the margin"
  assert_equals "--volume C:" "$(cat "$CTERMS.args")" "the measurer runs once per admission with the policy's arguments"
  assert_equals $((9 * GIB)) "$(reserved)" "the token charges Linux"
  assert_present "$STATE/reservations/token@$TOKEN" "the record is named by its token"
  lin more 1
  expect_err 75 "fm-storage: wait: insufficient-space: linux:results: required=1 available=0" "one byte over waits"
  lin lin 0
  expect_err 75 "fm-storage: wait: reservation-exists: linux:results: job/lin is live" "a live name is never replaced"
  setup_world
  lin lin $((9 * GIB + 1))
  expect_err 75 "fm-storage: wait: insufficient-space: linux:results: required=$((9 * GIB + 1)) available=$((9 * GIB))" "over the boundary waits"
  assert_absent "$STATE/reservations" "nothing is recorded"
  pass "Linux admission boundary is exact and duplicates wait"
}

test_host_c_terms_and_single_charge() {
  setup_world
  hostc hc $((13 * GIB + 1))
  expect_err 75 "fm-storage: wait: insufficient-space: host-c:results: required=$((13 * GIB + 1)) available=$((13 * GIB))" "swap, shadow storage and pagefile are charged to C:"
  hostc hc $((13 * GIB))
  expect_token "host-c admits exactly C: free minus every term and the margin"
  local hc=$TOKEN
  assert_equals 0 "$(reserved)" "a host-c token never charges Linux"
  lin lin 1
  expect_err 75 "fm-storage: wait: insufficient-space: linux:results: required=1 available=0" "a host-c token limits Linux through C:"
  OUT=$(run_adm status --json)
  assert_contains "$OUT" '"admission":"on","c_terms_mode":"strict","host_c_reserved":13958643712,"pagefile_reserved":3221225472,"c_terms":{"ext4_vhdx":{' "status shows the v3 fields"
  assert_equals "$((2 * GIB)) \"strict\" \"strict\" null null null null $GIB \"strict\" null null" \
    "$(for f in shadow_reserved shadow_source shadow_reading shadow_max shadow_used shadow_allocated shadow_events swap_reserved swap_source swap_size swap_file_size; do
      json_field "$OUT" "$f"; done | tr '\n' ' ' | sed 's/ $//')" "strict terms replace the shadow storage and swap file fields"
  try release-token job --token "$hc"
  expect_err 0 '' "release the host-c token"
  lin lin $((4 * GIB))
  expect_token "a Linux token"
  hostc hc $((9 * GIB + 1))
  expect_err 75 "fm-storage: wait: insufficient-space: host-c:results: required=$((9 * GIB + 1)) available=$((9 * GIB))" "a Linux token is charged to C: once"
  hostc hc $((5 * GIB))
  expect_token "a second host-c token"
  lin more $((4 * GIB + 1))
  expect_err 75 "fm-storage: wait: insufficient-space: linux:results: required=$((4 * GIB + 1)) available=$((4 * GIB))" "Linux sees C: tokens"
  OUT=$(run_adm status)
  assert_contains "$OUT" "reserved writes: 4.0 GiB (" "status sums Linux tokens"
  assert_contains "$OUT" "job/lin 4.0 GiB" "status names the Linux token"
  assert_contains "$OUT" "job/hc C: only 5.0 GiB" "status names the C: token"
  assert_contains "$OUT" $'\nreserved C: only: 5.0 GiB\n' "status sums C: tokens"
  assert_contains "$OUT" $'\nC: terms (strict): ext4.vhdx measured; swap file 1.0 GiB; shadow storage 2.0 GiB; pagefile 3.0 GiB\n' "status shows the strict terms"
  pass "Linux peaks charge Linux and C: once, host-c tokens charge C: only, pagefile is charged"
}

test_unknown_terms_wait() {
  local why
  setup_world
  CT_PF_STATE=unknown CT_PF_REASON='pagefile size not readable' \
    CT_REASONS="[$(reason host-c '"pagefile"' 'pagefile size not readable')]" write_cterms "$GIB" $((2 * GIB)) 0
  export FAKE_CTERMS_RC=75
  lin a 1
  expect_err 75 "fm-storage: wait: cannot-measure: linux:results: host-c:pagefile: pagefile size not readable" "an unknown pagefile holds Linux admissions"
  hostc a 1
  expect_err 75 "fm-storage: wait: cannot-measure: host-c:results: host-c:pagefile: pagefile size not readable" "an unknown pagefile holds C: admissions"
  OUT=$(run_adm check --expect-write 1); RC=$?
  expect_code 2 "$RC" "legacy check under unknown terms"
  assert_equals "cannot measure disk room: host-c:pagefile: pagefile size not readable" "$OUT" "legacy check names the unknown term"
  try status
  expect_err 2 "fm-disk-room: host-c:pagefile: pagefile size not readable" "status names the unknown term"
  CT_REASONS="[$(reason linux null 'no statfs reading'),$(reason host-c '"vss"' 'no reply')]" \
    write_cterms "$GIB" $((2 * GIB)) $((3 * GIB))
  lin a 1
  expect_err 75 "fm-storage: wait: cannot-measure: linux:results: linux:linux-free: no statfs reading" "the measurer's first reason names its wait, a free reading too"
  write_cterms "$GIB" $((2 * GIB)) $((3 * GIB))
  lin a 1
  expect_err 75 "fm-storage: wait: cannot-measure: linux:results: host-c:c-terms: measurer exited 75 without a reason" "a wait without a reason still waits"
  printf 'not json\n' >"$CTERMS"
  lin a 1
  expect_err 75 "fm-storage: wait: cannot-measure: linux:results: host-c:c-terms: measurer exited 75" "a wait with an unreadable object still waits"
  unset FAKE_CTERMS_RC
  CT_REASONS="[$(reason host-c '"swap_vhdx"' 'no swap')]" write_cterms "$GIB" $((2 * GIB)) $((3 * GIB))
  lin a 1
  expect_err 75 "fm-storage: wait: cannot-measure: linux:results: host-c:swap_vhdx: no swap" "a reason under exit 0 is still an unknown reading"
  CT_PF_STATE=unknown write_cterms "$GIB" $((2 * GIB)) 0
  lin a 1
  expect_err 75 "fm-storage: wait: cannot-measure: linux:results: host-c:pagefile: unknown" "an unknown term without a reason"
  write_cterms "$GIB" $((2 * GIB)) $((3 * GIB))
  FAKE_CTERMS_RC=3 lin a 1
  expect_err 75 "fm-storage: wait: cannot-measure: linux:results: host-c:c-terms: measurer exited 3" "a failed measurer holds admissions"
  why="fm-storage: wait: cannot-measure: linux:results: host-c:c-terms: measurer output is not the strict c_terms object"
  CT_EXTRA=',"extra":1' write_cterms "$GIB" $((2 * GIB)) $((3 * GIB))
  lin a 1
  expect_err 75 "$why" "an extra key is refused"
  CT_TOP=',"extra":1' write_cterms "$GIB" $((2 * GIB)) $((3 * GIB))
  lin a 1
  expect_err 75 "$why" "an extra top-level key is refused"
  CT_SCHEMA=fm-storage-c-terms/v2 write_cterms "$GIB" $((2 * GIB)) $((3 * GIB))
  lin a 1
  expect_err 75 "$why" "another schema is refused"
  CT_REASONS='[{"code":"cannot-measure"}]' write_cterms "$GIB" $((2 * GIB)) $((3 * GIB))
  lin a 1
  expect_err 75 "$why" "a malformed reason is refused"
  CT_PF_STATE=measure write_cterms "$GIB" $((2 * GIB)) $((3 * GIB))
  lin a 1
  expect_err 75 "$why" "a state outside the enum is refused"
  printf 'not json\n' >"$CTERMS"
  lin a 1
  expect_err 75 "$why" "non-JSON is refused"
  write_cterms "$GIB" -1 $((3 * GIB))
  lin a 1
  expect_err 75 "$why" "a negative term is refused"
  CT_PF_STATE=bounded write_cterms "$GIB" $((2 * GIB)) $((3 * GIB))
  lin a 1
  expect_err 75 "fm-storage: wait: cannot-measure: linux:results: host-c:pagefile: bounded reading not accepted by site policy" "bounded readings refuse by default"
  strict_policy c-terms-bounded=accept
  lin a $((9 * GIB))
  expect_token "an accepted bounded pagefile admits"
  setup_world
  strict_policy c-terms-bounded=accept
  CT_VSS_STATE=bounded CT_VSS_PROVEN=false write_cterms "$GIB" $((2 * GIB)) $((3 * GIB))
  lin a 1
  expect_err 75 "fm-storage: wait: cannot-measure: linux:results: host-c:vss: bounded cap not proven" "an unproven shadow storage bound fails closed"
  assert_absent "$STATE/reservations" "no failed reading records anything"
  pass "unknown, failed, malformed and unaccepted C: terms wait instead of counting as zero"
}

# landed_world W: a fixture world for the real bin/fm-storage-c-terms.py in
# which every C: term is proven: an 8 GiB swap with a 1 GiB file on C: (7 GiB),
# a 10 GiB shadow storage cap with 4 GiB allocated (6 GiB) and one fixed 4-8
# GiB pagefile (4 GiB), 17 GiB in all. $W/measurer runs it with the world's
# readers; PS= in $W/ps-env names the PowerShell it may ask.
landed_world() {
  local w=$1
  rm -rf "$w"
  mkdir -p "$w/proc/self" "$w/root" "$w/c/Users/u/AppData/Local/wsl/g1" "$w/c/swap" "$w/home"
  printf '170 155 8:64 / %s rw,relatime - ext4 /dev/sde rw\n' "$w/root" >"$w/proc/self/mountinfo"
  printf '220 170 0:100 / %s rw,noatime - 9p C:\\134 rw,aname=drvfs;path=C:\\134;uid=1000\n' "$w/c" >>"$w/proc/self/mountinfo"
  printf '%s 8:64 100000000000\n%s 0:100 200000000000\n' "$w/root" "$w/c" >"$w/statfs"
  printf 'Filename\t\t\t\tType\t\tSize\t\tUsed\t\tPriority\n/dev/sdc                                partition\t8388608\t\t0\t\t-2\n' >"$w/proc/swaps"
  printf 'cpu  1 2 3\nbtime 4000000000\nprocesses 10\n' >"$w/proc/stat"
  python3 -c 'import sys
for path, size, head in ((sys.argv[1], 4096, b"vhdxfile"), (sys.argv[2], int(sys.argv[3]), b"")):
    with open(path, "wb") as f:
        f.write(head)
        f.truncate(size)' "$w/c/Users/u/AppData/Local/wsl/g1/ext4.vhdx" "$w/c/swap/swap.vhdx" "$GIB"
  printf '[wsl2]\r\nmemory=8GB\r\nswapFile=C:\\\\swap\\\\swap.vhdx\r\n' >"$w/c/Users/u/.wslconfig"
  cat >"$w/reply" <<'EOF'
VOLUME|\\?\Volume{1}\
SHADOW|10737418240|4294967296|3221225472
VSS-END
PAGEFILE-AUTO|False
PAGEFILE-SETTING|C:\pagefile.sys|4096|8192
PAGEFILE-USAGE|C:\pagefile.sys|4096
PAGEFILE-END
END
EOF
  printf '#!/bin/sh\ncat %s\n' "$w/reply" >"$w/ps"
  printf 'PS=%s\n' "$w/ps" >"$w/ps-env"
  cat >"$w/measurer" <<SH
#!/usr/bin/env bash
. "$w/ps-env"
exec env -i PATH="$(fm_test_base_path_sans "$PATH" powershell.exe)" HOME="$w/home" \\
  FM_STORAGE_C_HOST="$w/c" FM_STORAGE_C_LINUX_ROOT="$w/root" FM_STORAGE_C_PROC="$w/proc" \\
  FM_STORAGE_C_STATFS="$w/statfs" FM_STORAGE_C_NOW=1800000000 FM_STORAGE_C_POWERSHELL="\$PS" \\
  "$ROOT/bin/fm-storage-c-terms.py" "\$@"
SH
  chmod +x "$w/ps" "$w/measurer"
}

test_landed_measurer() {
  local w=$TMP_ROOT/landed
  setup_world
  landed_world "$w"
  write_policy admission=on c-terms=strict "c-terms-command=$w/measurer" \
    c-terms-arg=measure c-terms-arg=--linux-pending c-terms-arg=0
  # Linux room is min(10, 20 - 17) - 1 = 2 GiB.
  lin over $((2 * GIB + 1))
  expect_err 75 "fm-storage: wait: insufficient-space: linux:results: required=$((2 * GIB + 1)) available=$((2 * GIB))" "the landed measurer's terms hold one byte over"
  lin fit $((2 * GIB))
  expect_token "the landed measurer's terms admit the exact room"
  try release-token job --token "$TOKEN"
  expect_code 0 "$RC" "release after the landed measurer"
  printf 'PS=\n' >"$w/ps-env"
  lin fit 1
  expect_err 75 "fm-storage: wait: cannot-measure: linux:results: host-c:vss: Windows reading unavailable: no PowerShell command" "no Windows reading holds admissions"
  pass "the landed fm-storage-c-terms.py measurer feeds strict admission end to end"
}

test_arguments() {
  local arg sp
  setup_world
  for arg in 1K -1 1.5 '' 1e3 +1 1000000000000000000 0x10; do
    lin a "$arg"
    expect_err 2 "fm-storage: refused: invalid-argument: --bytes must be a base-10 integer from 0 to $MAX" "--bytes '$arg' is refused"
  done
  lin a 000000000000000000001
  expect_token "leading zeros are base 10"
  assert_equals 1 "$(reserved)" "leading zeros parse as decimal"
  lin b 0000000000000000010
  expect_token "leading zeros are not octal"
  assert_equals 11 "$(reserved)" "010 is ten"
  setup_world
  lin a "$MAX"
  expect_err 75 "fm-storage: wait: insufficient-space: linux:results: required=$MAX available=$((9 * GIB))" "the ceiling parses and waits"
  try reserve-token job --volume linux --class Results --name a --bytes 1 --pid "$$"
  expect_err 2 "fm-storage: refused: invalid-argument: --class must be 1-40 of a-z 0-9 -" "an upper-case class"
  try reserve-token .job --volume linux --class results --name a --bytes 1 --pid "$$"
  expect_err 2 "fm-storage: refused: invalid-argument: TASK must be 1-128 of A-Z a-z 0-9 . _ - starting with a letter or digit" "a task starting with a dot"
  try reserve-token job --volume linux --class results --name 'a/b' --bytes 1 --pid "$$"
  expect_err 2 "fm-storage: refused: invalid-argument: --name must be 1-128 of A-Z a-z 0-9 . _ - starting with a letter or digit" "a name with a slash"
  try reserve-token job --volume e --class results --name a --bytes 1 --pid "$$"
  expect_err 2 "fm-storage: refused: invalid-argument: --volume must be linux, host-c or d" "an unknown volume"
  for arg in 0 abc ''; do
    try reserve-token job --volume linux --class results --name a --bytes 1 --pid "$arg"
    expect_err 2 "fm-storage: refused: invalid-argument: --pid must be a process id" "--pid '$arg'"
  done
  try reserve-token job --volume d --class results --name a --bytes 1 --pid "$$"
  expect_err 2 "fm-storage: refused: invalid-argument: --volume d needs --root" "D needs its root"
  lin a 1 --root relative/dir
  expect_err 2 "fm-storage: refused: invalid-argument: --root must be an absolute path" "a relative root"
  lin a 1 --class other
  expect_err 2 "fm-storage: refused: invalid-argument: --class given twice" "a repeated option"
  lin a 1 extra
  expect_err 2 "fm-storage: refused: invalid-argument: unexpected argument extra" "a second task"
  lin a 1 --force
  expect_err 2 "fm-storage: refused: invalid-argument: unknown option --force" "an unknown option"
  try reserve-token job --volume linux --class results --name a --pid "$$"
  expect_err 2 "fm-storage: refused: invalid-argument: --bytes must be a base-10 integer from 0 to $MAX" "a missing size"
  try reserve-token job --volume linux --class results --name a --bytes 1 --pid
  expect_err 2 "fm-storage: refused: invalid-argument: --pid needs a value" "an option without its value"
  # Children here exit on their own: a signal sent before the fork execs would
  # run the inherited cleanup trap in the child and remove TMP_ROOT.
  sh -c 'exit 0' & sp=$!
  wait "$sp"
  try reserve-token job --volume linux --class results --name a --bytes 1 --pid "$sp"
  expect_err 2 "fm-storage: refused: invalid-pid: process $sp is not running" "a dead owner process"
  mkdir -p "$DROOT"
  lin a 1 --root "$DROOT"
  expect_err 2 "fm-storage: refused: placement: $DROOT is not on the linux filesystem" "a Linux token placed on another filesystem"
  lin a 1 --root "$LINUXDIR"
  expect_token "a Linux token placed on the Linux filesystem"
  pass "arguments are strict: plain base-10 bytes up to the ceiling, bounded names, live owner, absolute placement"
}

test_saturating_sums() {
  local i
  setup_world
  mkdir -p "$STATE/reservations"
  for i in 0 1 2 3 4 5 6 7 8 9; do
    printf 'bytes=%s\npid=%s\nstart=%s\n' "$MAX" "$$" "$MY_START" >"$STATE/reservations/huge$i"
  done
  lin a 0
  expect_err 75 "fm-storage: wait: insufficient-space: linux:results: required=0 available=$((9 * GIB - MAX))" "huge reservations saturate instead of wrapping"
  pass "reservation sums saturate at the byte ceiling"
}

test_legacy_and_tokens_charge_each_other() {
  setup_world
  OUT=$(run_adm reserve big 4G --pid "$$"); RC=$?
  expect_code 0 "$RC" "legacy reserve with the policy present"
  lin a $((5 * GIB + 1))
  expect_err 75 "fm-storage: wait: insufficient-space: linux:results: required=$((5 * GIB + 1)) available=$((5 * GIB))" "a token sees legacy reservations"
  run_adm release big >/dev/null
  lin a $((4 * GIB))
  expect_token "a Linux token"
  OUT=$(run_adm check --expect-write 5G); RC=$?
  expect_code 0 "$RC" "legacy check fits beside the token"
  OUT=$(run_adm check --expect-write 6G); RC=$?
  expect_code 1 "$RC" "legacy check sees the token"
  OUT=$(run_adm run --name job --expect-write 6G -- true 2>&1); RC=$?
  expect_code 75 "$RC" "legacy run sees the token"
  rm -f "$POLICY"
  assert_equals $((4 * GIB)) "$(reserved)" "without the policy the legacy reader still counts the token"
  setup_world
  setup_d
  OUT=$(run_adm reserve-bulk dj --task job --download 10G --expanded 0 --packaging 0); RC=$?
  expect_code 0 "$RC" "legacy D reservation with the policy present"
  dvol dn $((40 * GIB + 1))
  expect_err 75 "fm-storage: wait: insufficient-space: d:results: required=$((40 * GIB + 1)) available=$((40 * GIB))" "a D token sees legacy D reservations"
  dvol dn $((40 * GIB))
  expect_token "a D token fills D: to its margin"
  OUT=$(run_adm reserve-bulk dj2 --task job --download 1 --expanded 0 --packaging 0 2>&1); RC=$?
  expect_code 75 "$RC" "legacy reserve-bulk sees D tokens"
  assert_contains "$OUT" "fm-disk-room: wait: insufficient-space: D:" "legacy D wait reason"
  pass "legacy admissions see token charges and tokens see legacy charges"
}

test_d_isolated_from_c() {
  setup_world
  setup_d
  CT_PF_STATE=unknown CT_PF_REASON='pagefile size not readable' write_cterms "$GIB" $((2 * GIB)) 0
  set_sizes 0 0 5
  dvol dn $((50 * GIB))
  expect_token "D admits while C: terms are unknown and C: is full"
  assert_absent "$CTERMS.args" "D admission never runs the C: measurer"
  assert_present "$STATE/reservations-d/999/token@$TOKEN" "D records sit in the D: pool of its filesystem"
  assert_absent "$STATE/reservations" "a D token writes nothing to the C: pool"
  dvol more 1
  expect_err 75 "fm-storage: wait: insufficient-space: d:results: required=1 available=0" "the D: boundary is exact"
  dvol dn 0
  expect_err 75 "fm-storage: wait: reservation-exists: d:results: job/dn is live" "a live D name is never replaced"
  try reserve-token job --volume d --class results --name x --bytes 1 --pid "$$" --root "$TMP_ROOT"
  expect_err 2 "fm-storage: refused: placement: $TMP_ROOT is not a directory on the verified D: filesystem" "a root off D: is refused"
  setup_world
  write_policy admission=on c-terms=off
  setup_d
  dvol dn 1
  expect_token "D admits without strict C: terms"
  rm "$CFG/results-root"
  dvol dn2 1
  expect_err 75 "fm-storage: wait: storage-offline: d:results: missing-publication" "no publication waits with its reason"
  try release-token job --token "$TOKEN"
  expect_err 0 '' "release works with D: unpublished"
  assert_absent "$STATE/reservations-d/999/token@$TOKEN" "the D record is gone"
  pass "D: is admitted from its own pool, isolated from C: readings"
}

test_pid_and_boot_identity() {
  local tok sp
  setup_world
  mkdir -p "$STATE/reservations"
  tok=$(hex64 b)
  v2_record "$STATE/reservations/token@$tok" "$tok" "$MY_START" boot-a linux live $((4 * GIB))
  assert_equals $((4 * GIB)) "$(reserved)" "a record with this boot and start counts"
  v2_record "$STATE/reservations/token@$tok" "$tok" $((MY_START + 1)) boot-a linux reused $((4 * GIB))
  assert_equals 0 "$(reserved)" "a reused pid with another start time lapses"
  assert_absent "$STATE/reservations/token@$tok" "the lapsed record is pruned"
  v2_record "$STATE/reservations/token@$tok" "$tok" "$MY_START" boot-b linux oldboot $((4 * GIB))
  assert_equals 0 "$(reserved)" "a record from another boot lapses"
  assert_absent "$STATE/reservations/token@$tok" "the other boot's record is pruned"
  sh -c 'while [ ! -e "$1" ]; do sleep 0.1; done' _ "$TMP_ROOT/child-exit" & sp=$!
  try reserve-token job --volume linux --class results --name child --bytes $((4 * GIB)) --pid "$sp"
  expect_token "a token owned by a child process"
  assert_equals $((4 * GIB)) "$(reserved)" "the child's token counts while it runs"
  : >"$TMP_ROOT/child-exit"
  wait "$sp"
  assert_equals 0 "$(reserved)" "the token lapses when its owner exits"
  printf '\n' >"$TMP_ROOT/boot_id"
  lin a 1
  expect_err 75 "fm-storage: wait: cannot-measure: linux:results: boot-id: cannot read the boot id" "an unreadable boot id waits"
  pass "token liveness is pid plus start ticks plus boot identity"
}

test_token_semantics() {
  local tok other
  setup_world
  printf 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' >"$TMP_ROOT/random"
  tok=$(hex64 61)
  FM_DISK_ROOM_RANDOM="$TMP_ROOT/random" lin first $GIB
  expect_token "the token is the admission generation"
  assert_equals "$tok" "$TOKEN" "the token is the random bytes in lowercase hex"
  FM_DISK_ROOM_RANDOM="$TMP_ROOT/random" lin second $GIB
  expect_err 1 "fm-storage: refused: owner-state: cannot publish reservation token@$tok in $STATE/reservations" "a token collision never overwrites"
  assert_grep "name=first" "$STATE/reservations/token@$tok" "the first record is intact"
  assert_equals "$GIB" "$(reserved)" "only the first token counts"
  try release-token other --token "$tok"
  expect_err 2 "fm-storage: refused: wrong-task: the token belongs to another task" "another task cannot release it"
  assert_present "$STATE/reservations/token@$tok" "the record survives a wrong-task release"
  try release-token job --token ABC
  expect_err 2 "fm-storage: refused: invalid-token: a token is 64 lowercase hex characters" "a malformed token"
  try release-token job --token "$(printf 'A%.0s' $(seq 64))"
  expect_err 2 "fm-storage: refused: invalid-token: a token is 64 lowercase hex characters" "upper-case hex"
  try release-token job "$tok"
  expect_err 2 "fm-storage: refused: invalid-argument: release-token needs TASK --token TOKEN" "release needs --token"
  other=$(hex64 c)
  try release-token job --token "$other"
  expect_err 0 '' "an absent token releases"
  try release-token job --token "$tok"
  expect_err 0 '' "release"
  assert_absent "$STATE/reservations/token@$tok" "the record is gone"
  assert_equals 0 "$(reserved)" "nothing counts"
  try release-token job --token "$tok"
  expect_err 0 '' "a repeated release"
  printf 'garbage\n' >"$STATE/reservations/token@$other"
  try release-token job --token "$other"
  expect_err 1 "fm-storage: refused: owner-state: unreadable or malformed reservation $STATE/reservations/token@$other" "a malformed record refuses release"
  rm -f "$STATE/reservations/token@$other"
  if [ "$AS_ROOT" = 1 ]; then
    printf 'skip - unremovable record case needs a non-root user\n'
  else
    lin held $GIB
    expect_token "a token to release"
    chmod 555 "$STATE/reservations"
    try release-token job --token "$TOKEN"
    chmod 755 "$STATE/reservations"
    expect_err 1 "fm-storage: refused: owner-state: cannot remove $STATE/reservations/token@$TOKEN" "a failed removal is reported"
    assert_present "$STATE/reservations/token@$TOKEN" "the record is still there"
  fi
  pass "tokens are unique admission generations, release is task-checked, idempotent and fails loudly"
}

test_owner_state_failures() {
  setup_world
  mkdir -p "$STATE/.lock"
  lin a 1
  expect_err 1 "fm-storage: refused: owner-state: cannot open the state lock in $STATE" "an unopenable lock"
  rmdir "$STATE/.lock"
  exec 8>"$STATE/.lock"
  flock 8
  FM_DISK_ROOM_LOCK_WAIT=0 lin a 1
  expect_err 75 "fm-storage: wait: owner-busy: linux:results: state lock busy after 0s" "a busy owner lock waits"
  FM_DISK_ROOM_LOCK_WAIT=0 hostc a 1
  expect_err 75 "fm-storage: wait: owner-busy: host-c:results: state lock busy after 0s" "host-c admissions take the same owner lock"
  FM_DISK_ROOM_LOCK_WAIT=0 dvol a 1
  expect_err 75 "fm-storage: wait: owner-busy: d:results: state lock busy after 0s" "D admissions take the same owner lock"
  FM_DISK_ROOM_LOCK_WAIT=0 try release-token job --token "$(hex64 d)"
  expect_err 1 "fm-storage: refused: owner-state: state lock busy after 0s" "release under a busy lock"
  flock -u 8
  exec 8>&-
  FM_DISK_ROOM_LOCK_WAIT=abc lin a 1
  expect_err 1 "fm-storage: refused: owner-state: bad FM_DISK_ROOM_LOCK_WAIT" "a bad lock wait"
  mkdir -p "$STATE/reservations"
  printf 'garbage\n' >"$STATE/reservations/bad"
  lin a 1
  expect_err 1 "fm-storage: refused: owner-state: unreadable or malformed reservation $STATE/reservations/bad" "a malformed record refuses admission"
  try status
  expect_err 2 "fm-disk-room: owner-state: unreadable or malformed reservation $STATE/reservations/bad" "status refuses a malformed record"
  OUT=$(run_adm check --expect-write 1); RC=$?
  expect_code 2 "$RC" "legacy check with a malformed record"
  assert_equals "cannot measure disk room: owner-state: unreadable or malformed reservation $STATE/reservations/bad" "$OUT" "legacy check names it"
  printf 'bytes=1\npid=%s\nstart=%s\n' "$$" "$MY_START" >"$STATE/reservations/bad"
  lin a 1
  expect_token "a well-formed legacy record is read"
  rm -f "$STATE/reservations/bad"
  mv "$STATE/reservations/token@$TOKEN" "$STATE/reservations/token@$(hex64 e)"
  lin b 1
  expect_err 1 "fm-storage: refused: owner-state: reservation $STATE/reservations/token@$(hex64 e) does not match its token" "a renamed record refuses"
  rm -f "$STATE/reservations/token@"*
  mkdir "$STATE/reservations/token@$(hex64 f)"
  lin b 1
  expect_err 1 "fm-storage: refused: owner-state: reservation $STATE/reservations/token@$(hex64 f) is not a regular file" "a directory in the pool refuses"
  rmdir "$STATE/reservations/token@$(hex64 f)"
  v2_record "$STATE/reservations/token@$(hex64 1)" "$(hex64 1)" "$MY_START" boot-a d stray 1
  lin b 1
  expect_err 1 "fm-storage: refused: owner-state: reservation $STATE/reservations/token@$(hex64 1) is in the wrong pool" "a D record in the C: pool refuses"
  rm -f "$STATE/reservations/token@"*
  if [ "$AS_ROOT" = 1 ]; then
    printf 'skip - unwritable pool case needs a non-root user\n'
  else
    chmod 555 "$STATE/reservations"
    lin c 1
    chmod 755 "$STATE/reservations"
    expect_err 1 "fm-storage: refused: owner-state: cannot write in reservation pool $STATE/reservations" "an unwritable pool"
    assert_equals '' "$(ls -A "$STATE/reservations")" "nothing is left in the pool"
  fi
  pass "owner lock and record failures refuse loudly; record parse failures never count as zero"
}

test_malformed_policy() {
  local err
  setup_world
  check_policy() {
    try status
    expect_err 2 "fm-disk-room: storage admission policy: $1" "status: $2"
    lin a 1
    expect_err 2 "fm-storage: refused: policy: $1" "reserve-token: $2"
    OUT=$(run_adm --interface v2); RC=$?
    expect_code 1 "$RC" "--interface v2: $2"
    assert_equals "fm-disk-room: interface v2 is not served while strict C: terms are active (serves fm-disk-room-interface/v3)" "$OUT" "v2 is not served: $2"
  }
  printf 'fm-storage-admission-policy/v2\nadmission=on\nc-terms=off\n' >"$POLICY"
  check_policy "policy $POLICY line 1 is not fm-storage-admission-policy/v1" "a wrong format line"
  printf 'fm-storage-admission-policy/v1\r\nadmission=on\nc-terms=off\n' >"$POLICY"
  check_policy "policy $POLICY line 1 has a carriage return" "a carriage return"
  write_policy admission=on c-terms=off foo=bar
  check_policy "policy $POLICY has unknown key foo" "an unknown key"
  write_policy admission=on admission=off c-terms=off
  check_policy "policy $POLICY repeats admission" "a repeated key"
  printf 'fm-storage-admission-policy/v1\nadmission=on\nc-terms=off' >"$POLICY"
  check_policy "policy $POLICY does not end with a newline" "a missing final newline"
  write_policy admission=on c-terms=strict
  check_policy "policy $POLICY needs c-terms-command= with c-terms=strict" "strict without a measurer"
  write_policy admission=yes c-terms=off
  check_policy "policy $POLICY has a bad admission value" "a bad value"
  write_policy admission=on c-terms=strict c-terms-command=measurer
  check_policy "policy $POLICY has a bad c-terms-command value" "a relative measurer"
  write_policy admission=on
  check_policy "policy $POLICY needs admission= and c-terms=" "a missing key"
  write_policy admission=on c-terms=off 'just text'
  check_policy "policy $POLICY line 4 is not KEY=VALUE" "a line without ="
  : >"$POLICY"
  check_policy "policy $POLICY is empty" "an empty file"
  rm -f "$POLICY"; mkdir "$POLICY"
  check_policy "policy $POLICY is not a readable file" "a directory"
  rmdir "$POLICY"
  printf 'fm-storage-admission-policy/v1\n' >"$POLICY"
  err="fm-disk-room: wait: owner-state: storage admission policy: policy $POLICY needs admission= and c-terms="
  setup_d
  OUT=$(run_adm reserve-bulk x --task job --download 1 --expanded 0 --packaging 0 2>&1); RC=$?
  expect_code 75 "$RC" "legacy reserve-bulk under a bad policy"
  assert_equals "$err" "$OUT" "legacy reserve-bulk names the bad policy"
  pass "a present but malformed policy is a failed reading everywhere, never the default"
}

# A copy of the library that differs from the bytes the script was shipped
# with is never loaded: a pin on fm-disk-room.sh covers the library.
test_changed_library_refuses() {
  local tb="$TMP_ROOT/copy/bin" lib DISK_ROOM="$TMP_ROOT/copy/bin/fm-disk-room.sh"
  lib="$tb/fm-storage-admission-lib.sh"
  setup_world
  mkdir -p "$tb"
  cp "$ROOT/bin/fm-disk-room.sh" "$ROOT/bin/fm-storage-admission-lib.sh" "$tb/"
  lin a 1
  expect_token "an unchanged copy beside the script loads"
  printf '# changed\n' >>"$lib"
  try status
  expect_err 2 "fm-disk-room: storage admission policy: cannot load $lib" "status with a changed library"
  lin b 1
  expect_err 1 "fm-storage: refused: owner-state: cannot load $lib" "reserve-token with a changed library"
  try release-token job --token "$TOKEN"
  expect_err 1 "fm-storage: refused: owner-state: cannot load $lib" "release-token with a changed library"
  OUT=$(run_adm --interface v2); RC=$?
  expect_code 1 "$RC" "--interface v2 with a changed library"
  assert_present "$STATE/reservations/token@$TOKEN" "nothing was released"
  rm -f "$lib"
  try status
  expect_err 2 "fm-disk-room: storage admission policy: cannot load $lib" "status with no library"
  rm -rf "$TMP_ROOT/copy"
  pass "only the library bytes the script embeds a digest of load"
}

# wait_blocked_or_done N DIR PID...: until N owners wait on the state lock
# (the flock shim marked them in DIR) or have exited.
wait_blocked_or_done() {
  local n=$1 dir=$2 pid f seen done_n deadline=$(( $(date +%s) + 60 ))
  shift 2
  while :; do
    seen=0
    for f in "$dir"/*; do [ ! -e "$f" ] || seen=$((seen + 1)); done
    done_n=0
    for pid in "$@"; do kill -0 "$pid" 2>/dev/null || done_n=$((done_n + 1)); done
    [ $((seen + done_n)) -lt "$n" ] || return 0
    [ "$(date +%s)" -lt "$deadline" ] || fail "admissions neither waited on the lock nor finished"
    sleep 0.05
  done
}

# race VOLUME_A NAME_A BYTES_A VOLUME_B NAME_B BYTES_B: two admissions start
# while this shell holds the owner lock; nothing may be admitted until it is
# released, then exactly one is.
race() {
  local seen="$TMP_ROOT/flock-seen" p1 p2 rc1 rc2 left
  rm -rf "$seen"; mkdir -p "$seen" "$STATE"
  exec 8>"$STATE/.lock"
  flock 8
  FAKE_FLOCK_SEEN=$seen run_adm reserve-token job --volume "$1" --class results --name "$2" --bytes "$3" --pid "$$" \
    >"$TMP_ROOT/race1.out" 2>"$TMP_ROOT/race1.err" &
  p1=$!
  FAKE_FLOCK_SEEN=$seen run_adm reserve-token job --volume "$4" --class results --name "$5" --bytes "$6" --pid "$$" \
    >"$TMP_ROOT/race2.out" 2>"$TMP_ROOT/race2.err" &
  p2=$!
  wait_blocked_or_done 2 "$seen" "$p1" "$p2"
  left=$(ls -A "$STATE/reservations" 2>/dev/null)
  flock -u 8
  exec 8>&-
  wait "$p1"; rc1=$?
  wait "$p2"; rc2=$?
  assert_equals '' "$left" "$1/$4: nothing is admitted while the owner lock is held"
  assert_equals "0 75" "$(printf '%s\n' "$rc1" "$rc2" | sort -n | tr '\n' ' ' | sed 's/ $//')" "$1/$4: exactly one admission wins"
  assert_contains "$(cat "$TMP_ROOT/race1.err" "$TMP_ROOT/race2.err")" "fm-storage: wait: insufficient-space: " "$1/$4: the loser waits for space"
}

test_concurrent_admissions() {
  setup_world
  race linux a $((9 * GIB)) linux b $((9 * GIB))
  setup_world
  race linux a $((9 * GIB)) host-c b $((13 * GIB))
  setup_world
  race host-c a $((13 * GIB)) host-c b $((13 * GIB))
  pass "Linux and C: admissions share one owner lock with no check-then-reserve window"
}

command -v jq >/dev/null 2>&1 || fail "jq is required for strict C: terms"
test_inert_without_policy
test_linux_exact_boundary
test_host_c_terms_and_single_charge
test_unknown_terms_wait
test_landed_measurer
test_arguments
test_saturating_sums
test_legacy_and_tokens_charge_each_other
test_d_isolated_from_c
test_pid_and_boot_identity
test_token_semantics
test_owner_state_failures
test_malformed_policy
test_changed_library_refuses
test_concurrent_admissions
