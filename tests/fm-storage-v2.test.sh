#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2016
# Contract tests for fm-storage/v2 (docs/storage.md "fm-storage/v2").
#
# The suite pins the public contract a consumer such as lattice's CommandRoom
# relies on: --interface, reserve, release, status --json, site-config and
# health --volume d, each with its exact exit code, stdout and stderr, every
# error with no side effect, and the legacy commands unchanged.
# bin/fm-storage.sh --interface claims fm-storage/v2 only once this whole suite
# passes against the integrated implementation.
#
# Every case runs in a hermetic world: a PATH-shimmed df and stat answer fixture
# sizes and the D: device, uname -n answers the class map's host, fake
# powershells answer fixture CIM readings, the C: terms measurer reads fixture
# mount, swap, statfs and boot tables, sudo, mount and the mount probe only log,
# and plain directories stand in for the Linux disk, C: and D:. Nothing touches
# a real drive, a real reservation or a Windows binary, and no Windows setting is
# read or written.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-storage-v2)
S="$ROOT/bin/fm-storage.sh"
ROOM="$ROOT/bin/fm-disk-room.sh"
GIB=1073741824
T0=1790000000
BASE_PATH=/usr/local/bin:/usr/bin:/bin
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
REAL_STAT=$(command -v stat)
# W is everything a command may write; snapshots cover it. IN holds fixture
# inputs (sizes, mounts, Windows replies) and OBS call logs and captures.
W="$TMP_ROOT/w"
IN="$TMP_ROOT/in"
OBS="$TMP_ROOT/obs"
CFG="$W/cfg"
SST="$W/storage-state"
RST="$W/room"
MNT="$W/mnt"
HOSTC="$W/c"
LNX="$W/linux"
DL="$MNT/d/lattice-data"
VHDX="$HOSTC/Users/u/AppData/Local/wsl/{g}/ext4.vhdx"
SWAPF="$HOSTC/Users/u/AppData/Local/Temp/{s}/swap.vhdx"
HOLDERS=()

kill_holders() {
  local p
  for p in ${HOLDERS[@]+"${HOLDERS[@]}"}; do kill "$p" 2>/dev/null; done
  for p in ${HOLDERS[@]+"${HOLDERS[@]}"}; do wait "$p" 2>/dev/null; done
  HOLDERS=()
}
trap 'kill_holders; fm_test_cleanup' EXIT

# --- fake toolchain ---------------------------------------------------------

# df -B1 --output=FIELD -- PATH answers $FAKE_DF/<path with / as _>.<field> for
# PATH or its nearest ancestor that has one, as a mounted filesystem would.
cat >"$FAKEBIN/df" <<'SH'
#!/usr/bin/env bash
field='' path=''
for a in "$@"; do
  case "$a" in --output=*) field=${a#--output=} ;; -*) ;; *) path=$a ;; esac
done
p=$path
while [ -n "$p" ]; do
  f="$FAKE_DF/$(printf '%s' "$p" | tr / _).$field"
  if [ -r "$f" ]; then printf '%s\n' "$field"; cat "$f"; exit 0; fi
  [ "$p" = / ] && break
  p=$(dirname "$p")
done
echo "df: $path: No such file or directory" >&2
exit 1
SH
# stat answers the fixture D: device for %d under the D: mount (unless
# FAKE_D_DEV is empty, which leaves the real Linux-backed device), and a
# filesystem stat -f from the df fixture with 4 KiB blocks.
cat >"$FAKEBIN/stat" <<SH
#!/usr/bin/env bash
REAL=$REAL_STAT
SH
cat >>"$FAKEBIN/stat" <<'SH'
fmt='' fs=0 paths=() args=("$@")
while [ "$#" -gt 0 ]; do
  case "$1" in
    -c) fmt=$2; shift ;;
    --format=*|--printf=*) fmt=${1#*=} ;;
    -f|--file-system) fs=1 ;;
    -L|--dereference|--) ;;
    -*) ;;
    *) paths+=("$1") ;;
  esac
  shift
done
[ "${#paths[@]}" -eq 1 ] && [ -n "$fmt" ] || exec "$REAL" "${args[@]}"
p=${paths[0]}
if [ "$fs" = 1 ]; then
  q=$p
  while [ -n "$q" ]; do
    k="$FAKE_DF/$(printf '%s' "$q" | tr / _)"
    if [ -r "$k.avail" ]; then
      a=$(( $(cat "$k.avail") / 4096 )); b=$a
      [ -r "$k.size" ] && b=$(( $(cat "$k.size") / 4096 ))
      out=${fmt//%a/$a}; out=${out//%f/$a}; out=${out//%b/$b}; out=${out//%S/4096}; out=${out//%s/4096}
      printf '%s\n' "$out"; exit 0
    fi
    [ "$q" = / ] && break
    q=$(dirname "$q")
  done
  exec "$REAL" "${args[@]}"
fi
case "$p" in
  "$FAKE_D_MNT"|"$FAKE_D_MNT/"*)
    if [ -n "${FAKE_D_DEV:-}" ] && [[ $fmt == *%d* ]]; then
      out=$("$REAL" -c "${fmt//%d/@@D@@}" -- "$p") || exit
      printf '%s\n' "${out//@@D@@/$FAKE_D_DEV}"; exit 0
    fi ;;
esac
exec "$REAL" "${args[@]}"
SH
# Every Windows or privileged entry point logs its call; only powershell
# answers, from the fixture replies, and only while FAKE_WIN_UP is 1.
cat >"$FAKEBIN/powershell-stub" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "${0##*/}" >>"$FAKE_CALLS/win.calls"
[ "${FAKE_WIN_UP:-1}" = 1 ] || exit 1
case "$*" in
  *[Pp]age[Ff]ile*) cat "$FAKE_WIN/pagefile" ;;
  *) cat "$FAKE_WIN/shadow" ;;
esac
SH
cp "$FAKEBIN/powershell-stub" "$FAKEBIN/powershell.exe"
# The C: terms measurer's PowerShell answers the fixture CIM reply.
cat >"$FAKEBIN/ps-cterms" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "${0##*/}" >>"$FAKE_CALLS/win.calls"
[ "${FAKE_WIN_UP:-1}" = 1 ] || exit 1
cat "$FAKE_WIN/reply"
SH
# uname -n is the host the facade asks site-config about.
cat >"$FAKEBIN/uname" <<SH
#!/usr/bin/env bash
[ "\$*" = -n ] && { echo laptop; exit 0; }
exec $(command -v uname) "\$@"
SH
cat >"$FAKEBIN/wevtutil-stub" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "${0##*/}" >>"$FAKE_CALLS/win.calls"
[ "${FAKE_WIN_UP:-1}" = 1 ] || exit 1
cat "$FAKE_WIN/events"
SH
for t in cmd.exe wsl.exe wevtutil.exe vssadmin.exe fsutil.exe; do
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "${0##*/}" >>"$FAKE_CALLS/win.calls"\nexit 1\n' >"$FAKEBIN/$t"
done
for t in sudo mount umount; do
  printf '#!/usr/bin/env bash\nprintf "%%s %%s\\n" "${0##*/}" "$*" >>"$FAKE_CALLS/priv.calls"\nexit 1\n' >"$FAKEBIN/$t"
done
cat >"$FAKEBIN/mount-probe" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "${!#}" >>"$FAKE_CALLS/probe.calls"
exec stat "$@"
SH
chmod +x "$FAKEBIN"/*

# in_world CMD...: run CMD with only the fixture world's environment.
in_world() {
  timeout 150 env -i \
    PATH="$FAKEBIN:$BASE_PATH" HOME="$W/home" LANG=C LC_ALL=C TMPDIR="$W/tmp" FM_HOME="$W/home" \
    FAKE_DF="$IN/df" FAKE_D_MNT="$MNT/d" FAKE_D_DEV="${FAKE_D_DEV-999}" FAKE_WIN="$IN/win" \
    FAKE_WIN_UP="${FAKE_WIN_UP-1}" FAKE_CALLS="$OBS" \
    FM_STORAGE_CONFIG="$CFG" FM_STORAGE_STATE="$SST" FM_STORAGE_MNT="$MNT" FM_STORAGE_MOUNTINFO="$IN/mountinfo" \
    FM_STORAGE_NOTIFY="$OBS/notify" FM_STORAGE_MOUNT_PROBE="$FAKEBIN/mount-probe" FM_STORAGE_NOW="$NOW" \
    FM_STORAGE_PS_BACKOFF='0 0' FM_STORAGE_MACHINE_ID="$IN/machine-id" \
    FM_STORAGE_C_HOST="$HOSTC" FM_STORAGE_C_LINUX_ROOT="$LNX" FM_STORAGE_C_PROC="$IN/proc" \
    FM_STORAGE_C_STATFS="$IN/statfs" FM_STORAGE_C_NOW="$NOW" FM_STORAGE_C_POWERSHELL="$FAKEBIN/ps-cterms" \
    FM_DISK_ROOM_POLICY="$SITE_POLICY" FM_DISK_ROOM_LOCK_WAIT="${FM_DISK_ROOM_LOCK_WAIT-30}" \
    FM_DISK_ROOM_HOST="$HOSTC" FM_DISK_ROOM_ROOT="$LNX" FM_DISK_ROOM_STATE="$RST" \
    FM_DISK_ROOM_MB_GROUPS="$IN/mb_groups" FM_DISK_ROOM_DEV_SIZE=$(( 500 * GIB )) \
    FM_DISK_ROOM_WEVTUTIL=wevtutil-stub FM_DISK_ROOM_POWERSHELL=powershell-stub \
    FM_DISK_ROOM_RESULTS_ROOT="$CFG/results-root" FM_DISK_ROOM_SAMPLES="$IN/no-samples" \
    FM_DISK_ROOM_C_FREE_MIN=off FM_DISK_ROOM_D_FREE_MIN=off FM_DISK_ROOM_GROWTH_MAX=off \
    FM_DISK_ROOM_WSLCONFIG="$WSLCONFIG" FM_DISK_ROOM_MEMINFO="$IN/meminfo" FM_DISK_ROOM_BOOT_ID="$IN/boot_id" \
    FM_DISK_ROOM_NOW="$NOW" FM_DISK_ROOM_MARGIN=20G FM_DISK_ROOM_BULK_MARGIN=50G \
    "$@"
}
s() { in_world "$S" "$@"; }
room() { in_world "$ROOM" "$@"; }

# --- integration ports --------------------------------------------------------
# The class map, the site policies and the Windows CIM reply are formats the
# roots, admission and c-terms pieces own; these functions are the only place
# this suite writes them.
# Every expectation below is built from the world, never read back from these.
CLASS_MAP="$CFG/class-map.json"
SITE_POLICY="$CFG/storage-admission"
C_POLICY="$CFG/c-policy.json"
WSLCONFIG="$HOSTC/Users/u/.wslconfig"
POLICY_ID=fm-storage-v2-test-policy
PF_BUDGET=$(( 2 * GIB ))
MIB=1048576
MID=0f1e2d3c4b5a69788796a5b4c3d2e1f0
DEV=$(python3 -I -c 'import os, sys; s = os.stat(sys.argv[1]); print("%d:%d" % (os.major(s.st_dev), os.minor(s.st_dev)))' "$TMP_ROOT") \
  || fail "read the temp root's device"

root_json() { printf '"%s":{"host":"%s","path":"%s","transport":"local","volume":"%s"}' "$1" "$2" "$3" "$4"; }

# port_class_map VARIANT: the storage-owned map (fm-storage-class-map/v1).
port_class_map() {
  local meta units roots classes='"metadata-view":"xp-meta","undeclared-default":"xp-units","result-class":"xp-units"'
  meta=$(root_json xp-meta laptop "$LNX/xp-meta" linux)
  units=$(root_json xp-units laptop "$DL/xp-units" d)
  roots="$meta,$units"
  case "$1" in
    default) ;;
    siblings) roots="$roots,$(root_json xp-images laptop "$DL/xp-images" d)"; classes="$classes,\"image-class\":\"xp-images\"" ;;
    alias) roots="$roots,$(root_json xp-twin laptop "$DL/xp-units" d)" ;;
    host-alias) roots="$roots,$(root_json xp-twin localhost "$DL/xp-units" d)" ;;
    nested) roots="$roots,$(root_json xp-inner laptop "$DL/xp-units/inner" d)" ;;
    ancestor) roots="$roots,$(root_json xp-all laptop "$DL" d)" ;;
    symlink) roots="$roots,$(root_json xp-link laptop "$DL/xp-link" d)" ;;
    result-on-linux) classes='"metadata-view":"xp-meta","undeclared-default":"xp-units","result-class":"xp-meta"' ;;
    result-on-c) roots="$roots,$(root_json xp-cdrive laptop "$HOSTC/xp-c" host-c)"
      classes="$classes,\"c-class\":\"xp-cdrive\"" ;;
    no-default) classes='"metadata-view":"xp-meta","result-class":"xp-units"' ;;
    no-metadata-view) classes='"undeclared-default":"xp-units","result-class":"xp-units"' ;;
    unknown-root) classes="$classes,\"lost-class\":\"xp-nowhere\"" ;;
    malformed) printf '{"schema":"fm-storage-class-map/v1","roots":\n' >"$CLASS_MAP"; return ;;
    *) fail "unknown class-map variant $1" ;;
  esac
  printf '{"schema":"fm-storage-class-map/v1","hosts":{"laptop":{"machine_id":"%s","aliases":["localhost"]}},"roots":{%s},"classes":{%s}}\n' \
    "$MID" "$roots" "$classes" >"$CLASS_MAP"
}

# port_site_policy VARIANT: the admission policy that turns on strict C: terms
# through the landed measurer, and its C: policy with the approved pagefile
# growth budget (fm-storage-c-policy/v1).
port_site_policy() {
  local budget=",\"pagefile_system_managed_growth_bytes\":$PF_BUDGET"
  case "$1" in
    default) ;;
    no-pagefile-budget) budget='' ;;
    none) rm -f "$SITE_POLICY" "$C_POLICY"; return ;;
    *) fail "unknown site-policy variant $1" ;;
  esac
  printf '%s\n' fm-storage-admission-policy/v1 admission=on c-terms=strict \
    "c-terms-command=$ROOT/bin/fm-storage-c-terms.py" c-terms-arg=measure c-terms-arg=--linux-pending \
    c-terms-arg=0 c-terms-arg=--policy "c-terms-arg=$C_POLICY" c-terms-bounded=accept >"$SITE_POLICY"
  printf '{"schema":"fm-storage-c-policy/v1","policy_id":"%s","approval":"fixture approval"%s}\n' \
    "$POLICY_ID" "$budget" >"$C_POLICY"
}

# port_windows: the fixture CIM replies from the VSS_* and PF_* settings, in
# MiB for the pagefile as Win32_PageFileSetting and Win32_PageFileUsage give.
port_windows() {
  mkdir -p "$IN/win"
  {
    printf '%s\n' "VOLUME|\\\\?\\Volume{1}\\" "SHADOW|$VSS_CAP|$VSS_ALLOC|$VSS_USED" VSS-END
    if [ "$PF_MODE" = system-managed ]; then
      printf '%s\n' 'PAGEFILE-AUTO|True' "PAGEFILE-USAGE|C:\\pagefile.sys|$(( PF_ALLOC / MIB ))"
    else
      printf '%s\n' 'PAGEFILE-AUTO|False' "PAGEFILE-SETTING|C:\\pagefile.sys|$(( PF_ALLOC / MIB ))|$(( PF_MAX / MIB ))" \
        "PAGEFILE-USAGE|C:\\pagefile.sys|$(( PF_ALLOC / MIB ))"
    fi
    printf '%s\n' PAGEFILE-END END
  } >"$IN/win/reply"
  printf 'SHADOW|%s|%s|%s\r\nEND\r\n' "$VSS_CAP" "$VSS_ALLOC" "$VSS_USED" >"$IN/win/shadow"
  : >"$IN/win/events"
}

# port_marker ROOT_DIR NAME: the consumer's per-root marker (roots.marker).
port_marker() { printf '{"root": "%s", "schema": "lattice-xp-root-marker/v1"}\n' "$2" >"$1/.lattice-xp-root.json"; }

# --- world ------------------------------------------------------------------

key() { printf '%s' "$1" | tr / _; }
set_df() { printf '%s\n' "$3" >"$IN/df/$(key "$1").$2"; }

world() {
  kill_holders
  rm -rf "$W" "$IN" "$OBS"
  mkdir -p "$W/home/config" "$W/tmp" "$CFG" "$SST" "$RST" "$IN/df" "$OBS" \
    "$LNX/xp-meta" "$DL/tetjet-results" "$DL/xp-units" "$(dirname "$VHDX")" "$(dirname "$SWAPF")"
  # The owner's empty lock file exists once it has run anywhere; a refusal under
  # the lock must still leave it empty and every record byte-for-byte unchanged.
  : >"$RST/.lock"
  NOW=$T0
  printf 'vhdxfile' >"$VHDX"
  truncate -s $(( 300 * GIB )) "$VHDX"
  truncate -s $(( 1 * GIB )) "$SWAPF"
  # The measurer's view of this VM boot: the Linux ext4 root, the 9p C: mount,
  # a 4 GiB swap disk and a boot after every fixture file's mtime.
  mkdir -p "$IN/proc/self"
  printf '170 155 8:64 / %s rw,relatime - ext4 /dev/sde rw\n' "$LNX" >"$IN/proc/self/mountinfo"
  printf '220 170 0:100 / %s rw,noatime - 9p C:\\134 rw,aname=drvfs;path=C:\\134;uid=1000\n' "$HOSTC" >>"$IN/proc/self/mountinfo"
  printf '%s 8:64 %s\n%s 0:100 %s\n' "$LNX" $(( 400 * GIB )) "$HOSTC" $(( 200 * GIB )) >"$IN/statfs"
  printf 'Filename\t\t\t\tType\t\tSize\t\tUsed\t\tPriority\n/dev/sdc                                partition\t4194304\t\t0\t\t-2\n' >"$IN/proc/swaps"
  printf 'cpu  1 2 3\nbtime 4000000000\nprocesses 10\n' >"$IN/proc/stat"
  printf '%s\n' "$MID" >"$IN/machine-id"
  set_df "$LNX" avail $(( 400 * GIB )); set_df "$LNX" used $(( 100 * GIB )); set_df "$LNX" size $(( 500 * GIB ))
  set_df "$HOSTC" avail $(( 200 * GIB )); set_df "$HOSTC" size $(( 1000 * GIB ))
  set_df "$MNT/d" avail $(( 500 * GIB )); set_df "$MNT/d" size $(( 2000 * GIB ))
  printf '[wsl2]\nmemory=16GB\nswap=4GB\nswapFile=C:\\\\Users\\\\u\\\\AppData\\\\Local\\\\Temp\\\\{s}\\\\swap.vhdx\n' >"$WSLCONFIG"
  printf 'MemTotal:       16777216 kB\n' >"$IN/meminfo"
  printf 'boot-one\n' >"$IN/boot_id"
  # A proven D: publication, its remembered identity and its 9p mount.
  printf 'volume-d\n' >"$DL/.lattice-storage-id"
  printf 'uniqueid=volume-d\n' >"$CFG/ssd-identity"
  printf '%s/tetjet-results/{task}\nformat=lattice-storage-results-root/v1\nactive=ssd\nstate=ok\nssd_letter=D\nssd_fs=exFAT\nssd_id=volume-d\nssd_marker=%s/.lattice-storage-id\nssd_device=999\nssd_free_bytes=%s\nchecked_at=%s\n' \
    "$DL" "$DL" $(( 500 * GIB )) $(( T0 - 10 )) >"$CFG/results-root"
  printf '%s\n' "1 0 $DEV / / rw - ext4 /dev/sdc rw" "2 1 $DEV / $MNT/d rw - 9p D:\\134 rw" >"$IN/mountinfo"
  port_marker "$LNX/xp-meta" xp-meta
  port_marker "$DL/xp-units" xp-units
  VSS_CAP=$(( 20 * GIB )) VSS_ALLOC=$(( 5 * GIB )) VSS_USED=$(( 3 * GIB ))
  PF_MODE=system-managed PF_ALLOC=$(( 8 * GIB )) PF_MAX=0
  port_windows
  port_class_map default
  port_site_policy default
  unset FAKE_D_DEV FAKE_WIN_UP
}

holder() { sleep 600 & HOLD=$!; HOLDERS+=("$HOLD"); }

# --- capture and assertions -------------------------------------------------

# cap CMD...: run CMD, keep its exit code in RC and its output in OUT and ERR.
cap() {
  "$@" >"$OBS/out" 2>"$OBS/err"
  RC=$?
  OUT=$(cat "$OBS/out")
  ERR=$(cat "$OBS/err")
}

# one_line FILE LABEL: FILE holds exactly one LF-terminated line.
one_line() {
  [ -s "$1" ] || fail "$2: expected one line, got nothing"
  [ "$(wc -l <"$1" | tr -d ' ')" = 1 ] && [ -z "$(tail -c 1 "$1")" ] ||
    fail "$2: expected one LF-terminated line, got: $(cat "$1")"
}

assert_starts() {
  case "$1" in "$2"*) ;; *) fail "$3 (expected a line starting '$2', got '$1')" ;; esac
}

calls() { if [ -r "$OBS/$1.calls" ]; then wc -l <"$OBS/$1.calls" | tr -d ' '; else echo 0; fi; }

# snap: every path in the world with its type, mode, size and (for files under
# 1 MiB) content hash, so any write, create, delete or chmod shows.
snap() {
  (
    cd "$W" || exit 1
    find . -mindepth 1 | LC_ALL=C sort | while IFS= read -r p; do
      if [ -L "$p" ]; then printf 'L %s %s\n' "$p" "$(readlink "$p")"
      elif [ -d "$p" ]; then printf 'D %s %s\n' "$p" "$(stat -c %a "$p")"
      else
        read -r mode size <<<"$(stat -c '%a %s' "$p")"
        if [ "$size" -lt 1048576 ]; then printf 'F %s %s %s %s\n' "$p" "$mode" "$size" "$(sha256sum <"$p" | cut -c1-64)"
        else printf 'F %s %s %s\n' "$p" "$mode" "$size"; fi
      fi
    done
  )
}

# no_effect RC PREFIX LABEL CMD...: CMD exits RC with empty stdout and one
# stderr line starting PREFIX, and the world is byte-for-byte unchanged.
no_effect() {
  local rc=$1 prefix=$2 label=$3 before
  shift 3
  before=$(snap)
  cap "$@"
  expect_code "$rc" "$RC" "$label"
  assert_equals "" "$OUT" "$label prints nothing on stdout"
  one_line "$OBS/err" "$label"
  assert_starts "$ERR" "$prefix" "$label"
  assert_equals "$before" "$(snap)" "$label leaves no side effect"
}

# reserve VOLUME CLASS TASK NAME BYTES [PID]
reserve() { cap s reserve --volume "$1" --class "$2" "$3" --name "$4" --bytes "$5" --pid "${6:-$HOLD}"; }

# admitted LABEL: the last reserve printed one token and nothing else.
admitted() {
  expect_code 0 "$RC" "$1 admits"
  one_line "$OBS/out" "$1 token"
  [[ $OUT =~ ^[0-9a-f]{64}$ ]] || fail "$1: token is 64 lowercase hex, got '$OUT'"
  assert_equals "" "$ERR" "$1 prints nothing on stderr"
  TOKEN=$OUT
}

# waits PREFIX LABEL: the last command waited with one stderr line PREFIX...
waits() {
  expect_code 75 "$RC" "$2 waits"
  assert_equals "" "$OUT" "$2 prints no token"
  one_line "$OBS/err" "$2"
  assert_starts "$ERR" "$1" "$2"
}

released() {
  expect_code 0 "$RC" "$1 releases"
  assert_equals "" "$OUT" "$1 prints nothing on stdout"
  assert_equals "" "$ERR" "$1 prints nothing on stderr"
}

# status: run status --json into STATUS (the one JSON line) and SRC (its rc).
status() {
  cap s status --json
  SRC=$RC STATUS=$OUT
  one_line "$OBS/out" "status --json"
  printf '%s\n' "$STATUS" | jq -e . >/dev/null || fail "status --json prints valid JSON: $STATUS"
}
j() { printf '%s\n' "$STATUS" | jq -r "$1"; }

# The closed status --json schema: prints one line per violation.
cat >"$TMP_ROOT/schema.jq" <<'JQ'
def int: type == "number" and . == floor;
def intn: . == null or int;
def strn: . == null or type == "string";
def extra: {
  "ext4_vhdx": ["path", "file_bytes", "linux_free_bytes", "linux_pending_bytes", "growth_reserved_bytes"],
  "swap_vhdx": ["path", "configured_bytes", "file_bytes", "hosting_volume"],
  "vss": ["cap_bytes", "allocated_bytes", "used_bytes", "cap_proven"],
  "pagefile": ["mode", "allocation_bytes", "maximum_bytes", "operator_growth_reservation_bytes", "policy_id", "hosting_volumes"]
};
def strings: { "ext4_vhdx": ["path"], "swap_vhdx": ["path", "hosting_volume"], "pagefile": ["policy_id"] };
. as $s |
(if .interface != "fm-storage/v2" then "interface" else empty end),
(if (.sampled_at | int | not) then "sampled_at" else empty end),
(if (.state | IN("ok", "waiting", "refused") | not) then "state" else empty end),
(if .class_map_sha256 == null or (.class_map_sha256 | type == "string" and test("^[0-9a-f]{64}$")) then empty else "class_map_sha256" end),
(if (keys - ["c_terms", "class_map_sha256", "interface", "reasons", "sampled_at", "state", "volumes"]) != [] or (keys | length) != 7 then "top-level keys \(keys)" else empty end),
(if (.volumes | keys) != ["d", "host-c", "linux"] then "volume names \(.volumes | keys)" else empty end),
(.volumes | to_entries[] | .key as $v | .value |
  (if keys != ["free_bytes", "margin_bytes", "reason", "reserved_bytes", "room_bytes", "state"] then "\($v) keys \(keys)" else empty end),
  (if (.state | IN("ok", "offline", "unknown", "refused") | not) then "\($v).state" else empty end),
  (["free_bytes", "reserved_bytes", "margin_bytes", "room_bytes"][] as $k | if (.[$k] | intn | not) then "\($v).\($k)" else empty end),
  (if (.reason | strn | not) then "\($v).reason" else empty end),
  (if .state == "ok" and (.free_bytes == null or .room_bytes == null) then "\($v) ok without numbers" else empty end)),
(if (.c_terms | keys) != ["ext4_vhdx", "pagefile", "swap_vhdx", "vss"] then "term names \(.c_terms | keys)" else empty end),
(.c_terms | to_entries[] | .key as $t | .value |
  (if (keys - ["reclaimable_bytes"]) != ((["reason", "reserved_bytes", "sampled_at", "source", "state"] + extra[$t]) | sort) then "\($t) keys \(keys)" else empty end),
  (if (.state | IN("measured", "bounded", "not-applicable", "unknown") | not) then "\($t).state" else empty end),
  (if (.reserved_bytes | intn | not) then "\($t).reserved_bytes" else empty end),
  (if (.sampled_at | intn | not) then "\($t).sampled_at" else empty end),
  (if (.source | strn | not) then "\($t).source" else empty end),
  (if (.reason | strn | not) then "\($t).reason" else empty end),
  (if has("reclaimable_bytes") and (.reclaimable_bytes | intn | not) then "\($t).reclaimable_bytes" else empty end),
  (if .state == "unknown" and .reserved_bytes != null then "\($t) unknown but reserves a number" else empty end),
  (if (.state | IN("measured", "bounded")) and .reserved_bytes == null then "\($t) known but reserves null" else empty end),
  (if .state == "unknown" and .reason == null then "\($t) unknown without a reason" else empty end),
  (extra[$t][] as $k | if ((strings[$t] // []) | index([$k])) then (if (.[$k] | strn | not) then "\($t).\($k)" else empty end)
    elif $k == "cap_proven" then (if (.[$k] | type) != "boolean" then "\($t).cap_proven" else empty end)
    elif $k == "mode" then (if (.[$k] | IN("system-managed", "fixed", "off", "unknown") | not) then "\($t).mode" else empty end)
    elif $k == "hosting_volumes" then (if .[$k] != null and ((.[$k] | type) != "array" or any(.[$k][]; type != "string")) then "\($t).hosting_volumes" else empty end)
    else (if (.[$k] | intn | not) then "\($t).\($k)" else empty end) end)),
(if (.reasons | type) != "array" then "reasons" else
  (.reasons[] | if (type != "object") or keys != ["code", "detail", "term", "volume"] then "reason keys"
    elif (.code | type) != "string" or (.detail | type) != "string" or (.volume | strn | not) or (.term | strn | not) then "reason types"
    else empty end) end),
(if .state == "ok" and (.reasons | length) != 0 then "state ok with reasons" else empty end),
(if .state != "ok" and (.reasons | length) == 0 then "state \(.state) without a reason" else empty end)
JQ

# The admission arithmetic every status reading must satisfy.
cat >"$TMP_ROOT/identities.jq" <<'JQ'
def known(f): [f] | all(. != null);
.volumes as $v | .c_terms as $t |
(if known($t[].reserved_bytes) and $v["host-c"].state == "ok" and
    $v["host-c"].room_bytes != $v["host-c"].free_bytes - $v["host-c"].reserved_bytes - ([$t[].reserved_bytes] | add)
  then "host-c room is free minus its charges minus every C: term" else empty end),
(if $v.linux.state == "ok" and $v["host-c"].state == "ok" and
    $v.linux.room_bytes != ([$v.linux.free_bytes - $v.linux.reserved_bytes, $v["host-c"].room_bytes] | min)
  then "linux room is the smaller of Linux and the shared C: budget" else empty end),
(if $v.d.state == "ok" and $v.d.room_bytes != $v.d.free_bytes - $v.d.reserved_bytes then "d room is free minus its charges" else empty end),
(if $v.linux.state == "ok" and $t.ext4_vhdx.linux_free_bytes != $v.linux.free_bytes then "ext4 linux_free_bytes is Linux free" else empty end),
(if $v.linux.state == "ok" and $t.ext4_vhdx.linux_pending_bytes != $v.linux.reserved_bytes then "ext4 pending is the Linux charges" else empty end),
(if $t.ext4_vhdx.state != "unknown" and $t.ext4_vhdx.growth_reserved_bytes != $t.ext4_vhdx.linux_pending_bytes then "ext4 growth charges Linux one-for-one" else empty end),
(if $t.ext4_vhdx.state != "unknown" and $t.ext4_vhdx.reserved_bytes != $t.ext4_vhdx.growth_reserved_bytes then "ext4 reserves its growth" else empty end),
($t.swap_vhdx | if .state == "measured" and .reserved_bytes != ([.configured_bytes - .file_bytes, 0] | max) then "swap reserves configured minus file"
  elif .state == "bounded" and .reserved_bytes != .configured_bytes then "bounded swap reserves the whole cap" else empty end),
($t.vss | if .state == "measured" and .reserved_bytes != ([.cap_bytes - .allocated_bytes, 0] | max) then "vss reserves cap minus allocated"
  elif .state == "bounded" and (.cap_proven != true or .reserved_bytes != .cap_bytes) then "bounded vss reserves a proven cap" else empty end),
($t.pagefile | if .mode == "system-managed" and .state != "unknown" and .reserved_bytes != .operator_growth_reservation_bytes then "system-managed pagefile reserves the approved growth"
  elif .mode == "system-managed" and .operator_growth_reservation_bytes == null and .state != "unknown" then "system-managed pagefile without a budget is unknown"
  elif .mode == "fixed" and .state != "unknown" and .reserved_bytes != ([.maximum_bytes - .allocation_bytes, 0] | max) then "fixed pagefile reserves maximum minus allocation"
  else empty end)
JQ

# check_status LABEL: the reading is well formed and its arithmetic holds.
check_status() {
  local bad
  bad=$(printf '%s\n' "$STATUS" | jq -r -f "$TMP_ROOT/schema.jq") || fail "$1: the schema check ran"
  assert_equals "" "$bad" "$1: status --json matches the v2 schema"
  bad=$(printf '%s\n' "$STATUS" | jq -r -f "$TMP_ROOT/identities.jq") || fail "$1: the identity check ran"
  assert_equals "" "$bad" "$1: status --json arithmetic holds"
  case "$SRC:$(j .state)" in 0:ok|75:waiting|2:refused) ;; *) fail "$1: status exit $SRC disagrees with state $(j .state)" ;; esac
}

# --- 1. interface -----------------------------------------------------------

test_interface() {
  world
  local before
  rm -rf "$CFG" "$SST" "$RST"
  before=$(snap)
  cap s --interface
  expect_code 0 "$RC" "--interface"
  assert_equals "fm-storage/v2" "$OUT" "--interface names fm-storage/v2"
  assert_equals "fm-storage/v2" "$(cat "$OBS/out")" "--interface prints exactly one line"
  one_line "$OBS/out" "--interface"
  assert_equals "" "$ERR" "--interface prints nothing on stderr"
  assert_equals "$before" "$(snap)" "--interface creates no config or state"
  assert_equals 0 "$(calls win)" "--interface calls no Windows tool"
  assert_equals 0 "$(calls priv)" "--interface runs no sudo or mount"
  # The interface line does not depend on any configuration being present.
  world
  port_class_map malformed
  port_site_policy none
  cap s --interface
  expect_code 0 "$RC" "--interface with a malformed map"
  assert_equals "fm-storage/v2" "$OUT" "--interface ignores site configuration"
  cap s --interface extra
  expect_code 2 "$RC" "--interface with an operand"
  assert_equals "" "$OUT" "--interface with an operand claims nothing"
  pass "--interface prints fm-storage/v2 alone, touching nothing"
}

# --- 2. reserve ---------------------------------------------------------------

test_reserve_admits_exact_boundary() {
  world
  holder
  local avail t1
  status
  check_status "fresh world"
  avail=$(( $(j '.volumes.d.room_bytes') - $(j '.volumes.d.margin_bytes') ))
  assert_equals $(( 450 * GIB )) "$avail" "D: admits free minus the bulk margin"
  reserve d result-class job unit-a "$avail"
  admitted "an exact-boundary D: booking"
  t1=$TOKEN
  status
  assert_equals "$avail" "$(j '.volumes.d.reserved_bytes')" "the D: booking is charged once in full"
  reserve d result-class job unit-b 1
  waits "fm-storage: wait: insufficient-space: d:result-class: required=1 available=0" "one byte past the boundary"
  assert_equals "fm-storage: wait: insufficient-space: d:result-class: required=1 available=0" "$ERR" "the wait names required and available bytes"
  reserve d result-class job unit-z 0
  admitted "a zero-byte booking at the boundary"
  assert_not_equals "$t1" "$TOKEN" "every admission gets its own token"
  status
  assert_equals "$avail" "$(j '.volumes.d.reserved_bytes')" "a zero-byte booking charges nothing"
  pass "reserve admits exactly up to the margin and waits one byte past it"
}

test_reserve_refusals_leave_nothing() {
  world
  holder
  local n v c a
  local -a bad_bytes=(-1 +1 1.5 1e3 0x10 '' ' 1' '1 ' 1G 99999999999999999999 18446744073709551616 07x)
  for n in "${bad_bytes[@]}"; do
    no_effect 2 "fm-storage: refused: " "reserve --bytes '$n'" \
      s reserve --volume d --class result-class job --name u --bytes "$n" --pid "$HOLD"
  done
  for v in e C D host-d linux,d ''; do
    no_effect 2 "fm-storage: refused: " "reserve --volume '$v'" \
      s reserve --volume "$v" --class result-class job --name u --bytes 1 --pid "$HOLD"
  done
  for c in no-such-class Result-Class '' 'a/b' lost-class; do
    no_effect 2 "fm-storage: refused: " "reserve --class '$c'" \
      s reserve --volume d --class "$c" job --name u --bytes 1 --pid "$HOLD"
  done
  no_effect 2 "fm-storage: refused: " "a D: class booked on Linux" \
    s reserve --volume linux --class result-class job --name u --bytes 1 --pid "$HOLD"
  no_effect 2 "fm-storage: refused: " "metadata-view booked on D:" \
    s reserve --volume d --class metadata-view job --name u --bytes 1 --pid "$HOLD"
  no_effect 2 "fm-storage: refused: " "a result class booked on C:" \
    s reserve --volume host-c --class result-class job --name u --bytes 1 --pid "$HOLD"
  no_effect 2 "fm-storage: refused: " "the default class booked on C:" \
    s reserve --volume host-c --class undeclared-default job --name u --bytes 1 --pid "$HOLD"
  for a in 0 -1 abc '' 4194305999 "$HOLD " 1.5; do
    no_effect 2 "fm-storage: refused: " "reserve --pid '$a'" \
      s reserve --volume d --class result-class job --name u --bytes 1 --pid "$a"
  done
  sleep 0 & a=$!
  wait "$a"
  no_effect 2 "fm-storage: refused: " "reserve with an exited pid" \
    s reserve --volume d --class result-class job --name u --bytes 1 --pid "$a"
  for n in ../x a/b -x .x _x '' 'a b' "a$(printf '%0128d' 0)" $'a\nb'; do
    no_effect 2 "fm-storage: refused: " "reserve TASK '$n'" \
      s reserve --volume d --class result-class "$n" --name u --bytes 1 --pid "$HOLD"
    no_effect 2 "fm-storage: refused: " "reserve --name '$n'" \
      s reserve --volume d --class result-class job --name "$n" --bytes 1 --pid "$HOLD"
  done
  no_effect 2 "fm-storage: refused: " "reserve with a trailing operand" \
    s reserve --volume d --class result-class job --name u --bytes 1 --pid "$HOLD" extra
  no_effect 2 "fm-storage: refused: " "reserve with a repeated option" \
    s reserve --volume d --class result-class job --name u --bytes 1 --bytes 2 --pid "$HOLD"
  no_effect 2 "fm-storage: refused: " "reserve without --pid" \
    s reserve --volume d --class result-class job --name u --bytes 1
  no_effect 2 "fm-storage: refused: " "reserve without a task" \
    s reserve --volume d --class result-class --name u --bytes 1 --pid "$HOLD"
  no_effect 2 "fm-storage: refused: " "reserve with a --ttl" \
    s reserve --volume d --class result-class job --name u --bytes 1 --pid "$HOLD" --ttl 60
  # The class map alone chooses the root; a caller's --root never reaches the owner.
  no_effect 2 "fm-storage: refused: invalid-argument: --root is not a reserve option: " "reserve with a caller-chosen --root" \
    s reserve --volume d --class result-class job --name u --bytes 1 --pid "$HOLD" --root "$DL/xp-units"
  port_class_map malformed
  no_effect 2 "fm-storage: refused: " "reserve against a malformed map" \
    s reserve --volume d --class result-class job --name u --bytes 1 --pid "$HOLD"
  port_class_map unknown-root
  no_effect 2 "fm-storage: refused: " "a class bound to an undefined root" \
    s reserve --volume d --class lost-class job --name u --bytes 1 --pid "$HOLD"
  pass "reserve refuses every malformed or forbidden request with rc 2 and no effect"
}

test_reserve_valid_names() {
  world
  holder
  local long unit
  long="T$(printf '%0127d' 0)"
  unit=$(printf '%064x' 3054)
  reserve d result-class "$long" "$unit" 1
  admitted "a 128-character task with a 64-hex unit name"
  reserve linux metadata-view "$long" "$unit-view" 1
  admitted "a 69-character view name on Linux"
  reserve linux metadata-view "$long" "$unit" 1
  admitted "the same task and name on another volume"
  reserve d undeclared-default job.v2_x-1 Unit.A_b-9 1
  admitted "dots, underscores and capitals in task and name"
  pass "reserve accepts the consumer's real task and name shapes"
}

test_reserve_collision_keeps_first_charge() {
  world
  holder
  local first
  reserve d result-class job unit 10
  admitted "the first booking"
  first=$TOKEN
  status
  no_effect 75 "fm-storage: wait: reservation-exists: d:result-class" "a live same-name booking" \
    s reserve --volume d --class result-class job --name unit --bytes 99 --pid "$HOLD"
  status
  assert_equals 10 "$(j '.volumes.d.reserved_bytes')" "the first charge is kept unchanged"
  cap s release job --token "$first"
  released "the first token"
  status
  assert_equals 0 "$(j '.volumes.d.reserved_bytes')" "the first token still owns its charge"
  pass "a live (task, name, volume) collision waits without replacing the charge"
}

test_reserve_pid_identity() {
  world
  holder
  local dead
  reserve d result-class job unit $(( 7 * GIB ))
  admitted "a PID-bound booking"
  status
  assert_equals $(( 7 * GIB )) "$(j '.volumes.d.reserved_bytes')" "a live owner's booking is charged"
  dead=$HOLD
  kill "$dead"; wait "$dead" 2>/dev/null
  local before
  before=$(snap)
  status
  assert_equals 0 "$(j '.volumes.d.reserved_bytes')" "an exited owner's booking is no longer charged"
  assert_equals "$before" "$(snap)" "status does not prune the dead record"
  holder
  reserve d result-class job unit $(( 7 * GIB ))
  admitted "a new booking after the owner exited"
  printf 'boot-two\n' >"$IN/boot_id"
  status
  assert_equals 0 "$(j '.volumes.d.reserved_bytes')" "a booking from an earlier boot is no longer charged"
  pass "a booking lasts exactly as long as its owner process in this boot"
}

test_reserve_concurrent_pair() {
  world
  holder
  local p1 p2 rc1 rc2
  ( s reserve --volume d --class result-class job --name left --bytes $(( 300 * GIB )) --pid "$HOLD" \
      >"$OBS/left.out" 2>"$OBS/left.err"; echo $? >"$OBS/left.rc" ) &
  p1=$!
  ( s reserve --volume d --class result-class job --name right --bytes $(( 300 * GIB )) --pid "$HOLD" \
      >"$OBS/right.out" 2>"$OBS/right.err"; echo $? >"$OBS/right.rc" ) &
  p2=$!
  wait "$p1"; wait "$p2"
  rc1=$(cat "$OBS/left.rc"); rc2=$(cat "$OBS/right.rc")
  case "$rc1:$rc2" in 0:75|75:0) ;; *) fail "two concurrent 300 GiB bookings: one admits, one waits (got $rc1 and $rc2)" ;; esac
  if [ "$rc1" = 75 ]; then assert_starts "$(cat "$OBS/left.err")" "fm-storage: wait: insufficient-space: d:result-class" "the loser names the shortage"
  else assert_starts "$(cat "$OBS/right.err")" "fm-storage: wait: insufficient-space: d:result-class" "the loser names the shortage"; fi
  status
  assert_equals $(( 300 * GIB )) "$(j '.volumes.d.reserved_bytes')" "only the winner is charged"
  pass "two concurrent admissions never both fit into room for one"
}

test_reserve_offline_and_owner_state() {
  world
  holder
  : >"$IN/mountinfo"
  no_effect 75 "fm-storage: wait: storage-offline: d:result-class" "a D: booking while D: is not mounted" \
    s reserve --volume d --class result-class job --name u --bytes 1 --pid "$HOLD"
  world
  holder
  rm -f "$CFG/results-root"
  no_effect 75 "fm-storage: wait: storage-offline: d:result-class" "a D: booking with no publication" \
    s reserve --volume d --class result-class job --name u --bytes 1 --pid "$HOLD"
  world
  holder
  FAKE_D_DEV=''
  no_effect 75 "fm-storage: wait: storage-offline: d:result-class" "a D: booking on a Linux-backed /mnt/d" \
    s reserve --volume d --class result-class job --name u --bytes 1 --pid "$HOLD"
  unset FAKE_D_DEV
  # A corrupt owner record is never skipped as if it were not there.
  world
  holder
  mkdir -p "$RST/reservations"
  printf 'bytes=lots\npid=%s\n' "$HOLD" >"$RST/reservations/broken"
  no_effect 1 "fm-storage: refused: owner-state: " "a Linux booking beside a corrupt owner record" \
    s reserve --volume linux --class metadata-view job --name u --bytes 1 --pid "$HOLD"
  if [ "$(id -u)" != 0 ]; then
    world
    holder
    chmod -R a-w "$RST"
    no_effect 1 "fm-storage: refused: owner-state: " "a booking whose record cannot be written" \
      s reserve --volume d --class result-class job --name u --bytes 1 --pid "$HOLD"
    chmod -R u+w "$RST"
  fi
  pass "offline D: waits and an owner-state failure refuses, neither leaving a charge"
}

test_reserve_owner_busy() {
  world
  holder
  local locker
  reserve d result-class job held 5
  admitted "a booking released while the lock is busy"
  printf '%s\n' "$TOKEN" >"$OBS/held.token"
  # One process holds the lock, so killing it frees the lock and leaves nothing.
  ( exec 9>"$RST/.lock" && flock 9 && exec sleep 600 ) </dev/null >/dev/null 2>&1 &
  locker=$!
  HOLDERS+=("$locker")
  for _ in $(seq 1 600); do
    flock -n "$RST/.lock" true || break
    sleep 0.1
  done
  ! flock -n "$RST/.lock" true || fail "the fixture holds the owner lock"
  # The owner gives up on a busy lock after FM_DISK_ROOM_LOCK_WAIT seconds.
  local FM_DISK_ROOM_LOCK_WAIT=1
  ( s reserve --volume d --class result-class job --name u --bytes 1 --pid "$HOLD" \
      >"$OBS/busy.out" 2>"$OBS/busy.err"; echo $? >"$OBS/busy.rc" ) &
  local pr=$!
  ( s release job --token "$(cat "$OBS/held.token")" >"$OBS/rbusy.out" 2>"$OBS/rbusy.err"; echo $? >"$OBS/rbusy.rc" ) &
  local pl=$!
  wait "$pr"; wait "$pl"
  unset FM_DISK_ROOM_LOCK_WAIT
  expect_code 75 "$(cat "$OBS/busy.rc")" "a booking while the owner lock stays busy"
  assert_equals "" "$(cat "$OBS/busy.out")" "a busy-lock booking prints no token"
  one_line "$OBS/busy.err" "busy-lock booking"
  assert_starts "$(cat "$OBS/busy.err")" "fm-storage: wait: owner-busy: d:result-class" "the wait names the busy owner"
  expect_code 1 "$(cat "$OBS/rbusy.rc")" "a release while the owner lock stays busy"
  assert_equals "" "$(cat "$OBS/rbusy.out")" "a busy-lock release prints nothing"
  one_line "$OBS/rbusy.err" "busy-lock release"
  kill "$locker"; wait "$locker" 2>/dev/null
  status
  assert_equals 5 "$(j '.volumes.d.reserved_bytes')" "neither busy call changed the charges"
  pass "a busy owner lock waits a booking and fails a release, changing nothing"
}

# --- 3. release ---------------------------------------------------------------

test_release() {
  world
  holder
  local t1 t2 tok
  reserve d result-class job unit $(( 9 * GIB ))
  admitted "the first generation"
  t1=$TOKEN
  cap s release job --token "$t1"
  released "a live token"
  status
  assert_equals 0 "$(j '.volumes.d.reserved_bytes')" "release drops the charge"
  cap s release job --token "$t1"
  released "the same token again"
  reserve d result-class job unit $(( 9 * GIB ))
  admitted "a second generation under the same name"
  t2=$TOKEN
  assert_not_equals "$t1" "$t2" "a new generation gets a new token"
  cap s release job --token "$t1"
  released "the first generation's token"
  status
  assert_equals $(( 9 * GIB )) "$(j '.volumes.d.reserved_bytes')" "an old token cannot remove a newer admission"
  no_effect 2 "fm-storage: refused: " "another task's token" s release other --token "$t2"
  status
  assert_equals $(( 9 * GIB )) "$(j '.volumes.d.reserved_bytes')" "a refused release keeps the charge"
  for tok in '' ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789 \
    "$(printf '%063d' 0)" "$(printf '%065d' 0)" "$(printf 'g%.0s' $(seq 1 64))" ../x "${t2:0:63}/" $'0\n1' "$t2 "; do
    no_effect 2 "fm-storage: refused: " "release --token '$tok'" s release job --token "$tok"
  done
  no_effect 2 "fm-storage: refused: " "release without --token" s release job
  no_effect 2 "fm-storage: refused: " "release without a task" s release --token "$t2"
  no_effect 2 "fm-storage: refused: " "release with a trailing operand" s release job --token "$t2" extra
  no_effect 2 "fm-storage: refused: " "release of an invalid task" s release ../job --token "$t2"
  # Release needs no D: at all: an unplugged drive still frees its booking.
  : >"$IN/mountinfo"
  rm -f "$CFG/results-root"
  FAKE_WIN_UP=0
  local before
  before=$(find "$DL" | LC_ALL=C sort)
  cap s release job --token "$t2"
  released "a token while D: is unplugged and Windows is down"
  assert_equals "$before" "$(find "$DL" | LC_ALL=C sort)" "release deletes no data"
  unset FAKE_WIN_UP
  world
  holder
  status
  assert_equals 0 "$(j '.volumes.d.reserved_bytes')" "a fresh world starts uncharged"
  pass "release removes exactly its own generation, idempotently, with D: absent"
}

test_release_owner_state() {
  [ "$(id -u)" != 0 ] || { pass "release owner-state failure (skipped as root)"; return; }
  world
  holder
  reserve d result-class job unit 4
  admitted "a booking whose release cannot be recorded"
  chmod -R a-w "$RST"
  no_effect 1 "fm-storage: refused: " "a release whose record cannot be removed" s release job --token "$TOKEN"
  chmod -R u+w "$RST"
  status
  assert_equals 4 "$(j '.volumes.d.reserved_bytes')" "a failed release keeps the charge"
  pass "a release that cannot be recorded fails with rc 1, never a silent success"
}

# --- 4. status --json and the C: terms ---------------------------------------

test_status_shape_and_values() {
  world
  local before
  before=$(snap)
  status
  expect_code 0 "$SRC" "status --json in a proven world"
  assert_equals "" "$ERR" "a valid status prints nothing on stderr"
  check_status "proven world"
  assert_equals "$before" "$(snap)" "status --json writes, caches and prunes nothing"
  assert_equals 0 "$(calls priv)" "status runs no sudo or mount"
  assert_equals 0 "$(calls probe)" "status starts no probe"
  assert_equals "$T0" "$(j .sampled_at)" "sampled_at follows the storage clock"
  assert_equals ok "$(j .state)" "the overall state is ok"
  assert_equals "$(sha256sum <"$CLASS_MAP" | cut -c1-64)" "$(j .class_map_sha256)" "class_map_sha256 is the map file's digest"
  assert_equals $(( 400 * GIB )) "$(j .volumes.linux.free_bytes)" "linux free is the Linux filesystem's"
  assert_equals $(( 200 * GIB )) "$(j '.volumes["host-c"].free_bytes')" "host-c free is C:'s"
  assert_equals $(( 500 * GIB )) "$(j .volumes.d.free_bytes)" "d free is D:'s"
  assert_equals $(( 20 * GIB )) "$(j .volumes.linux.margin_bytes)" "linux margin is the disk-room margin"
  assert_equals $(( 20 * GIB )) "$(j '.volumes["host-c"].margin_bytes')" "host-c margin is the disk-room margin"
  assert_equals $(( 50 * GIB )) "$(j .volumes.d.margin_bytes)" "d margin is the bulk margin"
  assert_equals "$VHDX" "$(j .c_terms.ext4_vhdx.path)" "the ext4 term names the disk file"
  assert_equals $(( 300 * GIB )) "$(j .c_terms.ext4_vhdx.file_bytes)" "the ext4 term reports the file's length"
  assert_equals 0 "$(j .c_terms.ext4_vhdx.reserved_bytes)" "no Linux booking, no ext4 growth charge"
  assert_equals $(( 4 * GIB )) "$(j .c_terms.swap_vhdx.configured_bytes)" "the swap term reads the configured cap"
  assert_equals $(( 20 * GIB )) "$(j .c_terms.vss.cap_bytes)" "the vss term reads the cap"
  assert_equals $(( 5 * GIB )) "$(j .c_terms.vss.allocated_bytes)" "the vss term reads the allocation"
  assert_equals system-managed "$(j .c_terms.pagefile.mode)" "the pagefile mode is read"
  assert_equals "$PF_BUDGET" "$(j .c_terms.pagefile.operator_growth_reservation_bytes)" "the approved growth budget is read"
  assert_equals "$POLICY_ID" "$(j .c_terms.pagefile.policy_id)" "the policy is named"
  assert_equals "$PF_BUDGET" "$(j .c_terms.pagefile.reserved_bytes)" "a system-managed pagefile reserves its approved growth"
  # The equation subtracts the pagefile: without it the room would be larger.
  local terms
  terms=$(j '[.c_terms[].reserved_bytes] | add')
  [ "$terms" -ge $(( PF_BUDGET + 15 * GIB + 3 * GIB )) ] || fail "every C: term is subtracted (got $terms)"
  assert_equals $(( 200 * GIB - terms )) "$(j '.volumes["host-c"].room_bytes')" "host-c room subtracts every C: term"
  pass "status --json is one closed v2 object whose numbers follow the fixtures"
}

test_status_coupling() {
  world
  holder
  local c0 l0 d0 n=$(( 6 * GIB ))
  status
  c0=$(j '.volumes["host-c"].room_bytes'); l0=$(j .volumes.linux.room_bytes); d0=$(j .volumes.d.room_bytes)
  reserve linux metadata-view job meta $n
  admitted "a Linux booking"
  status
  check_status "after a Linux booking"
  assert_equals "$n" "$(j .volumes.linux.reserved_bytes)" "the Linux booking is charged to Linux"
  assert_equals "$n" "$(j .c_terms.ext4_vhdx.growth_reserved_bytes)" "the Linux booking is charged to C: growth once"
  assert_equals $(( c0 - n )) "$(j '.volumes["host-c"].room_bytes')" "C: room drops by the Linux peak exactly once"
  assert_equals $(( l0 - n )) "$(j .volumes.linux.room_bytes)" "Linux room drops by the peak"
  assert_equals "$d0" "$(j .volumes.d.room_bytes)" "D: room is untouched by Linux bookings"
  reserve d result-class job unit $n
  admitted "a D: booking"
  status
  assert_equals $(( c0 - n )) "$(j '.volumes["host-c"].room_bytes')" "C: room is untouched by D: bookings"
  assert_equals $(( d0 - n )) "$(j .volumes.d.room_bytes)" "D: room drops by its booking"
  pass "Linux peaks charge Linux and C: once, and D: stays isolated"
}

test_legacy_and_v2_charge_each_other() {
  world
  holder
  local l0 legacy
  status
  l0=$(j .volumes.linux.reserved_bytes)
  cap room reserve legacy-job 2G --pid "$HOLD"
  expect_code 0 "$RC" "a legacy Linux reservation"
  assert_equals "reserved legacy-job: 2.0 GiB" "$OUT" "the legacy receipt is unchanged"
  status
  assert_equals $(( l0 + 2 * GIB )) "$(j .volumes.linux.reserved_bytes)" "v2 sees the legacy Linux reservation"
  assert_equals $(( 2 * GIB )) "$(j .c_terms.ext4_vhdx.growth_reserved_bytes)" "the legacy reservation is charged to C: growth"
  cap room reserve-bulk d-job --task job --download 10G --expanded 20G --packaging 20G --pid "$HOLD"
  expect_code 0 "$RC" "a legacy D: reservation"
  assert_equals "$DL/tetjet-results/job" "$OUT" "the legacy reserve-bulk receipt is unchanged"
  status
  assert_equals $(( 50 * GIB )) "$(j .volumes.d.reserved_bytes)" "v2 sees the legacy D: reservation"
  reserve linux metadata-view job meta $(( 3 * GIB ))
  admitted "a v2 Linux booking"
  cap room status --json
  expect_code 0 "$RC" "legacy status --json"
  legacy=$(printf '%s\n' "$OUT" | jq -r .reserved)
  assert_equals $(( 5 * GIB )) "$legacy" "legacy status sees the v2 Linux booking"
  # 500 GiB free less 50 GiB legacy leaves 400 GiB above the margin for v2.
  reserve d result-class job unit $(( 400 * GIB ))
  admitted "a v2 D: booking up to the margin"
  cap room reserve-bulk d-two --task job --download 1G --expanded 0 --packaging 0 --pid "$HOLD"
  expect_code 75 "$RC" "legacy reserve-bulk sees the v2 D: booking"
  assert_starts "$ERR" "fm-disk-room: wait: insufficient-space: D:" "the legacy wait is unchanged"
  assert_equals "" "$OUT" "the waiting legacy call prints no root"
  pass "legacy and v2 admissions charge one shared pool per volume"
}

test_c_terms_fail_closed() {
  world
  holder
  # No approved pagefile growth budget: the pagefile is a named unknown.
  port_site_policy no-pagefile-budget
  local before
  status
  expect_code 75 "$SRC" "status with an unapproved system-managed pagefile"
  check_status "unapproved pagefile"
  one_line "$OBS/err" "status wait"
  assert_starts "$ERR" "fm-storage: wait: cannot-measure: " "status names why it waits"
  assert_equals unknown "$(j .c_terms.pagefile.state)" "the pagefile term is unknown"
  assert_equals null "$(j .c_terms.pagefile.reserved_bytes)" "an unknown term reserves null, never zero"
  assert_equals unknown "$(j '.volumes["host-c"].state')" "C: is unknown"
  assert_equals unknown "$(j .volumes.linux.state)" "Linux, which grows C:, is unknown"
  assert_equals ok "$(j .volumes.d.state)" "D: stays measurable"
  assert_equals pagefile "$(j '[.reasons[] | select(.term == "pagefile")][0].term')" "a reason names the pagefile term"
  before=$(snap)
  reserve linux metadata-view job meta 1
  waits "fm-storage: wait: cannot-measure: linux:metadata-view: host-c:pagefile: " "a Linux booking with the pagefile unknown"
  assert_equals "$before" "$(snap)" "the waiting Linux booking leaves nothing"
  reserve d result-class job unit 1
  admitted "a D: booking while C: is unknown"
  # Windows down: every CIM term is unknown, and D: still admits.
  world
  holder
  FAKE_WIN_UP=0
  status
  expect_code 75 "$SRC" "status with Windows unreadable"
  check_status "Windows down"
  assert_equals unknown "$(j .c_terms.vss.state)" "VSS without a reading is unknown"
  assert_equals unknown "$(j .c_terms.pagefile.state)" "the pagefile without a reading is unknown"
  assert_equals null "$(j .c_terms.vss.reserved_bytes)" "unknown VSS reserves null"
  reserve linux metadata-view job meta 1
  waits "fm-storage: wait: cannot-measure: linux:metadata-view: host-c:" "a Linux booking with Windows down"
  reserve d result-class job unit 1
  admitted "a D: booking with Windows down"
  unset FAKE_WIN_UP
  # No swap setting is not zero swap: the cap then comes from memory size,
  # and an unreadable configuration is unknown rather than zero.
  world
  holder
  chmod a-r "$WSLCONFIG"
  if [ "$(id -u)" != 0 ]; then
    status
    expect_code 75 "$SRC" "status with an unreadable .wslconfig"
    assert_equals unknown "$(j .c_terms.swap_vhdx.state)" "an unreadable swap configuration is unknown"
  fi
  chmod a+r "$WSLCONFIG"
  # Missing C: mount in WSL mode is not Linux-only room.
  world
  rm -f "$IN/df/$(key "$HOSTC").avail"
  status
  expect_code 75 "$SRC" "status without a C: reading"
  assert_equals unknown "$(j '.volumes["host-c"].state')" "C: free unreadable is unknown"
  assert_not_equals ok "$(j .volumes.linux.state)" "Linux room never escapes C: by losing its reading"
  # A fixed pagefile reserves maximum minus allocation.
  world
  PF_MODE=fixed PF_ALLOC=$(( 4 * GIB )) PF_MAX=$(( 12 * GIB ))
  port_windows
  status
  expect_code 0 "$SRC" "status with a fixed pagefile"
  check_status "fixed pagefile"
  assert_equals $(( 8 * GIB )) "$(j .c_terms.pagefile.reserved_bytes)" "a fixed pagefile reserves maximum minus allocation"
  pass "every unknown C: term waits C: and Linux by name and never blocks D:"
}

test_status_refusals() {
  world
  port_class_map malformed
  local before
  before=$(snap)
  cap s status --json
  expect_code 2 "$RC" "status with a malformed class map"
  one_line "$OBS/err" "malformed map status"
  assert_starts "$ERR" "fm-storage: refused: " "status names the refusal"
  if [ -n "$OUT" ]; then
    STATUS=$OUT SRC=$RC
    one_line "$OBS/out" "malformed map status JSON"
    check_status "malformed map"
    assert_equals null "$(j .class_map_sha256)" "an unusable map has no digest"
  fi
  assert_equals "$before" "$(snap)" "a refused status writes nothing"
  no_effect 2 "fm-storage: refused: " "status --json with an operand" s status --json extra
  pass "a malformed map refuses status with rc 2 and one line"
}

test_status_site_config_wait() {
  world
  # Only the roots reading fails: every volume reading stays ok.
  rm -f "$DL/xp-units/.lattice-xp-root.json"
  local before code
  before=$(snap)
  status
  check_status "a root marker missing"
  expect_code 75 "$SRC" "status --json while a site root is unproven"
  assert_equals waiting "$(j .state)" "an unproven site root makes status wait"
  one_line "$OBS/err" "site-config wait status"
  assert_starts "$ERR" "fm-storage: wait: " "status names the site-config wait"
  code=${ERR#fm-storage: wait: }
  code=${code%%: *}
  assert_equals "1 null $code" "$(j '[(.reasons | length | tostring), (.reasons[0].volume // "null"), .reasons[0].code] | join(" ")')" \
    "the site-config wait is the one reason, on no volume"
  assert_equals "ok ok ok" "$(j '[.volumes.linux.state, .volumes["host-c"].state, .volumes.d.state] | join(" ")')" \
    "the volume readings stay ok"
  assert_equals "$before" "$(snap)" "a waiting status writes nothing"
  pass "a site-config wait makes status --json wait with one reason and its volume readings"
}

# --- 5. site-config -----------------------------------------------------------

# roots_load: a strict reading of lattice-xp-roots/v1 as the consumer loads it.
cat >"$TMP_ROOT/roots_load.py" <<'PY'
import json, re, sys
NAME = re.compile(r"[a-z0-9-]{1,40}")
d = json.loads(sys.stdin.read())
assert set(d) == {"schema", "here", "metadata", "roots", "classes"}, sorted(d)
assert d["schema"] == "lattice-xp-roots/v1"
for name, r in d["roots"].items():
    assert NAME.fullmatch(name), name
    assert set(r) == {"host", "path", "transport", "volume"}, r
    assert all(isinstance(v, str) for v in r.values()), r
    assert r["path"].startswith("/") and r["transport"] in ("local", "ssh") and NAME.fullmatch(r["volume"]), r
    assert (r["transport"] == "local") == (r["host"] == d["here"]), r
for c, r in d["classes"].items():
    assert NAME.fullmatch(c) and r in d["roots"], (c, r)
assert d["roots"][d["metadata"]]["host"] == d["here"]
PY

expected_site() {
  printf '{"schema":"lattice-xp-roots/v1","here":"laptop","metadata":"xp-meta","roots":{%s,%s%s},"classes":{"metadata-view":"xp-meta","undeclared-default":"xp-units","result-class":"xp-units"%s}}' \
    "$(root_json xp-meta laptop "$LNX/xp-meta" linux)" "$(root_json xp-units laptop "$DL/xp-units" d)" "${1:-}" "${2:-}" | jq -cS .
}

test_site_config() {
  world
  local before
  before=$(snap)
  cap s site-config --here laptop
  expect_code 0 "$RC" "site-config for a proven map"
  one_line "$OBS/out" "site-config"
  assert_equals "" "$ERR" "site-config prints nothing on stderr"
  assert_equals "$(expected_site)" "$(printf '%s\n' "$OUT" | jq -cS .)" "site-config projects the map exactly"
  printf '%s\n' "$OUT" | python3 -I "$TMP_ROOT/roots_load.py" || fail "the consumer's roots loader accepts the output"
  assert_equals "$before" "$(snap)" "site-config creates nothing"
  assert_equals 0 "$(calls win)" "site-config calls no Windows tool"
  assert_equals 0 "$(calls priv)" "site-config runs no sudo or mount"
  cap s site-config --here localhost
  expect_code 0 "$RC" "site-config for a host alias"
  assert_equals laptop "$(printf '%s\n' "$OUT" | jq -r .here)" "a host alias resolves to its canonical id"
  world
  mkdir -p "$DL/xp-images"
  port_marker "$DL/xp-images" xp-images
  port_class_map siblings
  cap s site-config --here laptop
  expect_code 0 "$RC" "site-config with sibling roots on one D: filesystem"
  assert_equals "$(expected_site ",$(root_json xp-images laptop "$DL/xp-images" d)" ',"image-class":"xp-images"')" \
    "$(printf '%s\n' "$OUT" | jq -cS .)" "sharing a device is not an alias"
  pass "site-config prints the closed lattice-xp-roots/v1 object and creates nothing"
}

test_site_config_refusals() {
  local v
  for v in alias host-alias nested ancestor symlink result-on-linux result-on-c no-default no-metadata-view unknown-root malformed; do
    world
    mkdir -p "$DL/xp-units/inner" "$HOSTC/xp-c"
    port_marker "$DL/xp-units/inner" xp-inner
    port_marker "$DL" xp-all
    port_marker "$HOSTC/xp-c" xp-cdrive
    ln -s "$DL/xp-units" "$DL/xp-link"
    port_class_map "$v"
    no_effect 2 "fm-storage: refused: " "site-config for a $v map" s site-config --here laptop
  done
  world
  no_effect 2 "fm-storage: refused: " "site-config for an unknown host" s site-config --here elsewhere
  no_effect 2 "fm-storage: refused: " "site-config without --here" s site-config
  no_effect 2 "fm-storage: refused: " "site-config with a trailing operand" s site-config --here laptop extra
  world
  rm -f "$DL/xp-units/.lattice-xp-root.json"
  no_effect 75 "fm-storage: wait: " "site-config with a root marker missing" s site-config --here laptop
  world
  rm -rf "$DL/xp-units"
  no_effect 75 "fm-storage: wait: " "site-config with a root directory missing" s site-config --here laptop
  world
  : >"$IN/mountinfo"
  no_effect 75 "fm-storage: wait: " "site-config with D: unmounted" s site-config --here laptop
  world
  FAKE_D_DEV=''
  no_effect 75 "fm-storage: wait: " "site-config with a copied marker on a Linux /mnt/d" s site-config --here laptop
  unset FAKE_D_DEV
  pass "site-config refuses forbidden maps (rc 2) and waits on unprovable roots (rc 75), printing no object"
}

# --- 6. health --volume d ------------------------------------------------------

# offline LABEL: health reports D: offline with one stdout line and no stderr.
offline() {
  local before
  before=$(snap)
  cap s health --volume d
  expect_code 75 "$RC" "health $1"
  one_line "$OBS/out" "health $1"
  [[ $OUT =~ ^offline\ [a-z0-9][a-z0-9:-]*$ ]] || fail "health $1: prints 'offline REASON', got '$OUT'"
  assert_equals "" "$ERR" "health $1 prints nothing on stderr"
  assert_equals "$before" "$(snap)" "health $1 changes nothing"
}

test_health() {
  world
  local before
  before=$(snap)
  cap s health --volume d
  expect_code 0 "$RC" "health of a proven D:"
  assert_equals ok "$(cat "$OBS/out")" "health prints ok"
  one_line "$OBS/out" "health ok"
  assert_equals "" "$ERR" "healthy D: prints nothing on stderr"
  assert_equals "$before" "$(snap)" "health writes nothing"
  assert_equals 0 "$(calls win)" "health calls no Windows tool"
  assert_equals 0 "$(calls priv)" "health runs no sudo or mount"
  assert_equals 0 "$(calls probe)" "health starts no probe"
  set_df "$MNT/d" avail 0
  cap s health --volume d
  expect_code 0 "$RC" "health of a full D:"
  assert_equals ok "$OUT" "health is not capacity"
  world; rm -f "$CFG/results-root"; offline "with no publication"
  world; NOW=$(( T0 + 1800 )); offline "with a stale publication"
  world; : >"$IN/mountinfo"; offline "with D: unmounted"
  world; printf '1 2 0:1 / %s rw - ext4 /dev/sdb rw\n' "$MNT/d" >"$IN/mountinfo"; offline "with a non-drvfs mount"
  world; FAKE_D_DEV=''; offline "with a copied marker on a Linux /mnt/d"; unset FAKE_D_DEV
  world; rm -f "$DL/.lattice-storage-id"; offline "with the volume marker missing"
  world; printf 'volume-other\n' >"$DL/.lattice-storage-id"; offline "with another volume's marker"
  world; FAKE_WIN_UP=0
  cap s health --volume d
  expect_code 0 "$RC" "health of a proven D: with Windows down"
  unset FAKE_WIN_UP
  world
  local a
  for a in '' '--volume' '--volume e' '--volume D' '--volume d extra' '--volume host-c x' 'd'; do
    # shellcheck disable=SC2086
    no_effect 2 "fm-storage: refused: " "health $a" s health $a
  done
  pass "health --volume d is read-only, ok or offline REASON, and independent of capacity"
}

# --- 7. consumer mirror and legacy -------------------------------------------

# A subprocess client that applies the consumer's rules strictly: the interface
# line must be exact with rc 0, a token exactly one safe line, rc 75 a wait.
cat >"$TMP_ROOT/client.py" <<'PY'
import re, subprocess, sys
s, task, pid = sys.argv[1], sys.argv[2], sys.argv[3]
def run(*argv):
    p = subprocess.run([s, *argv], stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=300)
    return p.returncode, p.stdout, p.stderr
rc, out, err = run("--interface")
assert rc == 0 and out == "fm-storage/v2\n" and err == "", (rc, out, err)
rc, out, err = run("reserve", "--volume", "d", "--class", "result-class", task, "--name", "unit", "--bytes", "4096", "--pid", pid)
assert rc == 0 and re.fullmatch(r"[0-9a-f]{64}\n", out) and err == "", (rc, out, err)
token = out.strip()
rc, out2, err = run("reserve", "--volume", "d", "--class", "result-class", task, "--name", "unit", "--bytes", "4096", "--pid", pid)
assert rc == 75 and out2 == "" and err.count("\n") == 1 and err.startswith("fm-storage: wait: reservation-exists: d:result-class"), (rc, out2, err)
rc, out, err = run("release", task, "--token", token)
assert rc == 0 and out == "" and err == "", (rc, out, err)
print("client ok")
PY

test_consumer_mirror() {
  world
  holder
  cap in_world python3 -I "$TMP_ROOT/client.py" "$S" job "$HOLD"
  expect_code 0 "$RC" "the strict consumer client: $ERR"
  assert_equals "client ok" "$OUT" "the strict consumer client completes"
  status
  assert_equals 0 "$(j .volumes.d.reserved_bytes)" "the client's booking is released"
  pass "a strict subprocess consumer reserves, waits and releases through the real CLI"
}

# legacy_outputs: every legacy reading whose bytes must not depend on v2 data.
legacy_outputs() {
  local c
  for c in "status" "root job" "verify-bulk-root job" "root --root research job" "--help"; do
    printf '== fm-storage %s\n' "$c"
    # shellcheck disable=SC2086
    s $c 2>&1
    printf 'rc=%s\n' "$?"
  done
  for c in "status --json" "status" "--interface" "check --expect-write 1G"; do
    printf '== fm-disk-room %s\n' "$c"
    # shellcheck disable=SC2086
    room $c 2>&1
    printf 'rc=%s\n' "$?"
  done
}

test_legacy_unchanged_without_policy() {
  world
  local with without
  port_site_policy none
  with=$(legacy_outputs)
  rm -f "$CLASS_MAP"
  without=$(legacy_outputs)
  assert_equals "$without" "$with" "a class map without site policy changes no legacy output"
  assert_contains "$with" "== fm-storage verify-bulk-root job"$'\n'"$DL/tetjet-results/job"$'\n'"rc=0" "legacy verify-bulk-root still prints its root"
  cap room status --json
  local legacy
  legacy=$OUT
  [ "$(printf '%s\n' "$legacy" | jq -r '.room')" = "$(printf '%s\n' "$legacy" | jq -r \
    '[.linux_free - .reserved, .host_free - .shadow_reserved - .swap_reserved - .reserved] | min')" ] ||
    fail "without site policy the legacy room equation is unchanged: $legacy"
  # No v2 command writes the published results-root file.
  world
  holder
  local pub
  pub=$(sha256sum <"$CFG/results-root")
  reserve d result-class job unit 1
  admitted "a booking beside the publication"
  cap s release job --token "$TOKEN"
  s status --json >/dev/null 2>&1
  s site-config --here laptop >/dev/null 2>&1
  s health --volume d >/dev/null 2>&1
  assert_equals "$pub" "$(sha256sum <"$CFG/results-root")" "the results-root publication is untouched"
  pass "legacy commands, receipts and the publication are unchanged by v2 data"
}

test_inert_without_configuration() {
  world
  holder
  rm -f "$CLASS_MAP" "$SITE_POLICY" "$C_POLICY"
  local before
  before=$(snap)
  cap s reserve --volume d --class result-class job --name unit --bytes 1 --pid "$HOLD"
  assert_not_equals 0 "$RC" "nothing admits before a class map exists"
  assert_equals "" "$OUT" "no token before a class map exists"
  one_line "$OBS/err" "unconfigured reserve"
  assert_starts "$ERR" "fm-storage: " "the refusal names fm-storage"
  cap s site-config --here laptop
  assert_not_equals 0 "$RC" "no site configuration before a class map exists"
  assert_equals "" "$OUT" "no roots object before a class map exists"
  cap s status --json
  assert_not_equals 0 "$RC" "status says an unconfigured site is not ready"
  if [ -n "$OUT" ]; then STATUS=$OUT; assert_equals null "$(j .class_map_sha256)" "no map, no digest"; fi
  assert_equals "$before" "$(snap)" "an unconfigured site writes nothing"
  pass "v2 stays inert until its class map and site policy exist"
}

test_interface
test_reserve_admits_exact_boundary
test_reserve_refusals_leave_nothing
test_reserve_valid_names
test_reserve_collision_keeps_first_charge
test_reserve_pid_identity
test_reserve_concurrent_pair
test_reserve_offline_and_owner_state
test_release
test_release_owner_state
test_status_shape_and_values
test_status_coupling
test_legacy_and_v2_charge_each_other
test_c_terms_fail_closed
test_status_refusals
test_status_site_config_wait
test_site_config
test_site_config_refusals
test_health
test_consumer_mirror
test_legacy_unchanged_without_policy
test_inert_without_configuration
test_reserve_owner_busy
