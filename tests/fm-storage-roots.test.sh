#!/usr/bin/env bash
# shellcheck disable=SC1091
# Behavior tests for bin/fm-storage-roots.py (site-config and health).
#
# Every case builds a fresh world: a plain directory standing in for D: under a
# fake mount base, a fake mount table naming that directory's real device, a
# hand-written results-root publication, a machine id file, and the class map
# from tests/fixtures/fm-storage-roots. A stat shim gives the D: tree the
# published device the way tests/fm-storage.test.sh does, and powershell.exe
# and sudo stubs log any call, so nothing touches real drives or needs root.
# Each run also proves it changed nothing in the world.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

unset FM_STORAGE_FALLBACK FM_STORAGE_NOTIFY FM_STORAGE_NOW FM_STORAGE_RESULTS_ROOT FM_STORAGE_MAX_AGE \
  FM_STORAGE_MACHINE_ID FAKE_BULK_DEVICE
TMP_ROOT=$(fm_test_tmproot fm-storage-roots)
TOOL="$ROOT/bin/fm-storage-roots.py"
FIX="$ROOT/tests/fixtures/fm-storage-roots"
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
PSBIN="$TMP_ROOT/psbin"
CALLS="$TMP_ROOT/calls.log"
W="$TMP_ROOT/w"
MNT="$W/mnt"
DL="$MNT/d/lattice-data"
CFG="$W/cfg"
MID=0f1e2d3c4b5a69788796a5b4c3d2e1f0
VOLID='volume{ssd1}'
DEV=$(python3 -I -c 'import os, sys; s = os.stat(sys.argv[1]); print("%d:%d" % (os.major(s.st_dev), os.minor(s.st_dev)))' "$TMP_ROOT") \
  || fail "read the temp root's device"

mkdir -p "$PSBIN"
cat >"$PSBIN/powershell.exe" <<'SH'
#!/usr/bin/env bash
printf 'powershell %s\n' "$*" >>"$FAKE_CALLS"
exit 1
SH
cat >"$FAKEBIN/sudo" <<'SH'
#!/usr/bin/env bash
printf 'sudo %s\n' "$*" >>"$FAKE_CALLS"
exit 1
SH
cat >"$FAKEBIN/mount" <<'SH'
#!/usr/bin/env bash
printf 'mount %s\n' "$*" >>"$FAKE_CALLS"
exit 1
SH
cat >"$FAKEBIN/stat" <<SH
#!/usr/bin/env bash
if [ -n "\${FAKE_BULK_DEVICE:-}" ] && [ "\$1 \$2" = '-c %d' ]; then
  case "\${!#}" in "\$FAKE_BULK_MNT/d"|"\$FAKE_BULK_MNT/d/"*) printf '%s\\n' "\$FAKE_BULK_DEVICE"; exit ;; esac
fi
exec $(command -v stat) "\$@"
SH
chmod +x "$PSBIN/powershell.exe" "$FAKEBIN/sudo" "$FAKEBIN/mount" "$FAKEBIN/stat"

marker() { printf '{"root": "%s", "schema": "lattice-xp-root-marker/v1"}\n' "$1"; }

# publish CHECKED_AT: the results-root publication a healthy check leaves.
publish() {
  printf '%s\n' "$DL/tetjet-results/{task}" "format=lattice-storage-results-root/v1" active=ssd state=ok reason= \
    "checked_at=$1" ssd_letter=D ssd_fs=NTFS "ssd_marker=$DL/.lattice-storage-id" "ssd_id=$VOLID" ssd_device=999 \
    >"$CFG/results-root"
}

# mounts [LINE...]: the root and D: mounts, then any extra lines.
mounts() {
  {
    printf '%s\n' "1 0 $DEV / / rw - ext4 /dev/sdc rw" "2 1 $DEV / $MNT/d rw - 9p D:\\134 rw"
    [ "$#" -eq 0 ] || printf '%s\n' "$@"
  } >"$W/mountinfo"
}

render() { sed -e "s#@MNT@#$MNT#g" -e "s#@W@#$W#g" -e "s#@MID@#$MID#g" "$1"; }

world() {
  rm -rf "$W"
  mkdir -p "$DL/tetjet-results" "$DL/xp-units" "$DL/xp-images" "$W/home/meta" "$CFG" "$W/state" "$W/c"
  printf '%s\n' "$VOLID" >"$DL/.lattice-storage-id"
  printf 'uniqueid=%s\n' "$VOLID" >"$CFG/ssd-identity"
  publish 1000
  printf '%s\n' "$MID" >"$W/machine-id"
  mounts
  marker xp-units >"$DL/xp-units/.lattice-xp-root.json"
  marker xp-images >"$DL/xp-images/.lattice-xp-root.json"
  marker xp-meta >"$W/home/meta/.lattice-xp-root.json"
  render "$FIX/class-map.json.in" >"$CFG/class-map.json"
}

# edit STATEMENT...: run Python statements on the class map as m.
edit() {
  python3 -I -c 'import json, sys
path = sys.argv[1]
with open(path) as f:
    m = json.load(f)
for statement in sys.argv[2:]:
    exec(statement)
with open(path, "w") as f:
    json.dump(m, f)
' "$CFG/class-map.json" "$@" || fail "edit the class map"
}

snapshot() {
  python3 -I -c 'import os, sys
def show(p):
    s = os.lstat(p)
    print(repr(p), s.st_mode, s.st_size, s.st_mtime_ns, s.st_ino)
show(sys.argv[1])
for d, ds, fs in os.walk(sys.argv[1]):
    ds.sort()
    for n in sorted(ds + fs):
        show(os.path.join(d, n))
' "$W"
}

# roots ARGS...: run the tool against the world; sets RC, OUT and ERR, and
# fails if the run changed anything in the world or called a stub.
roots() {
  local before after
  before=$(snapshot) || fail "snapshot the world"
  RC=0
  OUT=$(PATH="$FAKEBIN:$PSBIN:$PATH" FAKE_CALLS="$CALLS" FAKE_BULK_MNT="$MNT" \
    FAKE_BULK_DEVICE="${FAKE_BULK_DEVICE-999}" FM_STORAGE_NOW="${FM_STORAGE_NOW-1100}" \
    FM_STORAGE_CONFIG="$CFG" FM_STORAGE_STATE="$W/state" FM_STORAGE_MNT="$MNT" \
    FM_STORAGE_MOUNTINFO="$W/mountinfo" FM_STORAGE_MACHINE_ID="${FM_STORAGE_MACHINE_ID-$W/machine-id}" \
    FM_DISK_ROOM_HOST="$W/c" python3 -I "$TOOL" "$@" 2>"$TMP_ROOT/err") || RC=$?
  ERR=$(cat "$TMP_ROOT/err")
  after=$(snapshot) || fail "snapshot the world"
  [ "$before" = "$after" ] || fail "$* changed the world"
  assert_absent "$CALLS" "$* calls no Windows, sudo or mount tool"
}

# expect LABEL RC STDOUT STDERR: the last run's exact result.
expect() {
  expect_code "$2" "$RC" "$1"
  assert_equals "$3" "$OUT" "$1: stdout"
  assert_equals "$4" "$ERR" "$1: stderr"
  pass "$1"
}

refused() { roots site-config --here lap; expect "$1" 2 "" "fm-storage: refused: $2"; }
waits() { roots site-config --here lap; expect "$1" 75 "" "fm-storage: wait: $2"; }

GOLDEN=$(render "$FIX/site-config.golden.in")

# --- positive controls -------------------------------------------------------

world
roots site-config --here lap
expect "site-config prints the generated roots object" 0 "$GOLDEN" ""

world
roots site-config --here lap-alias
expect "a host alias names the same host" 0 "$GOLDEN" ""

world
FM_STORAGE_NOW=2800 roots site-config --here lap
expect "a publication at its maximum age is still trusted" 0 "$GOLDEN" ""

world
rm "$CFG/class-map.json"
roots health --volume d
expect "health is ok when D: is proven, with no class map" 0 "ok" ""

# --- usage -------------------------------------------------------------------

world
roots
expect "no verb is usage" 2 "" "fm-storage: refused: usage: site-config --here HOST | health --volume d"
roots lookup x
expect "an unknown verb is usage" 2 "" "fm-storage: refused: usage: site-config --here HOST | health --volume d"
roots site-config
expect "site-config needs --here" 2 "" "fm-storage: refused: usage: site-config --here HOST"
roots site-config --here lap extra
expect "site-config takes one host" 2 "" "fm-storage: refused: usage: site-config --here HOST"
roots site-config --host lap
expect "site-config takes only --here" 2 "" "fm-storage: refused: usage: site-config --here HOST"
roots health
expect "health needs --volume" 2 "" "fm-storage: refused: usage: health --volume d"
roots health --volume c
expect "health covers only d" 2 "" "fm-storage: refused: usage: health --volume d"

# --- the map -----------------------------------------------------------------

world
rm "$CFG/class-map.json"
refused "an absent map generates nothing" \
  "no-class-map: $CFG/class-map.json is absent; nothing is generated until it exists"

world
printf '{"schema": "fm-storage-class-map/v1", "hosts": {}, "hosts": {}, "roots": {}, "classes": {}}\n' >"$CFG/class-map.json"
refused "a duplicate key is refused" "invalid-class-map: $CFG/class-map.json: duplicate key 'hosts'"

world
printf '{"schema": "fm-storage-class-map/v1", "hosts": NaN, "roots": {}, "classes": {}}\n' >"$CFG/class-map.json"
refused "NaN is refused" "invalid-class-map: $CFG/class-map.json: non-finite number NaN"

world
printf '{} {}\n' >"$CFG/class-map.json"
roots site-config --here lap
expect_code 2 "$RC" "trailing data is refused"
assert_contains "$ERR" "fm-storage: refused: invalid-class-map: $CFG/class-map.json: Extra data" "trailing data names the map"
pass "trailing data is refused"

world
rm "$CFG/class-map.json"
mkdir "$CFG/class-map.json"
refused "a directory in the map's place is refused" "invalid-class-map: $CFG/class-map.json is not a regular file"

world
rm "$CFG/class-map.json"
mkfifo "$CFG/class-map.json"
refused "a FIFO in the map's place is refused without blocking" \
  "invalid-class-map: $CFG/class-map.json is not a regular file"

world
render "$FIX/class-map.json.in" | python3 -I -c 'import sys; sys.stdout.write(sys.stdin.read() + " " * 65536)' \
  >"$CFG/class-map.json"
refused "a map over 64 KiB is refused" "invalid-class-map: $CFG/class-map.json is over 65536 bytes"

world
chmod 000 "$CFG/class-map.json"
if [ -r "$CFG/class-map.json" ]; then
  pass "an unreadable map is a wait (skipped: this user reads mode 000 files)"
else
  waits "an unreadable map is a wait" "cannot-measure: $CFG/class-map.json: Permission denied"
fi

world
edit 'm["extra"] = 1'
refused "an extra top-level field is refused" \
  "invalid-class-map: not a fm-storage-class-map/v1 record {schema, hosts, roots, classes}"

world
edit 'm["schema"] = "fm-storage-class-map/v2"'
refused "another schema is refused" \
  "invalid-class-map: not a fm-storage-class-map/v1 record {schema, hosts, roots, classes}"

world
edit 'm["roots"]["xp-units"]["mode"] = "rw"'
refused "an extra root field is refused" \
  "invalid-class-map: root 'xp-units' is {host, path, transport (local|ssh), volume (linux|host-c|d)}"

world
edit 'm["hosts"]["tj"]["machine_id"] = m["hosts"]["lap"]["machine_id"]'
refused "two hosts with one machine id are refused" "invalid-class-map: host tj repeats another host's machine_id"

world
edit 'm["hosts"]["tj"]["aliases"] = ["lap-alias"]'
refused "an alias on two hosts is refused" "invalid-class-map: host tj alias 'lap-alias' is not a unique name"

world
edit 'm["hosts"]["tj"]["aliases"] = ["lap"]'
refused "an alias that is a host id is refused" "invalid-class-map: alias lap is also a host id"

world
edit 'm["roots"]["xp-units"]["host"] = "nowhere"'
refused "a root on an unknown host is refused" "invalid-class-map: root xp-units names unknown host 'nowhere'"

# --- the host ----------------------------------------------------------------

world
roots site-config --here nowhere
expect "an unknown host is refused" 2 "" "fm-storage: refused: unknown-host: host 'nowhere' is not in the class map"

world
roots site-config --here tj
expect "another host's id is refused on this machine" 2 "" \
  "fm-storage: refused: host-mismatch: this machine is not host tj ($W/machine-id differs)"

world
mkfifo "$W/fifo-machine-id"
FM_STORAGE_MACHINE_ID="$W/fifo-machine-id" roots site-config --here lap
expect "a FIFO machine id leaves the host unproven without blocking" 2 "" \
  "fm-storage: refused: host-unproven: $W/fifo-machine-id is unreadable: not a regular file"

world
FM_STORAGE_MACHINE_ID="$W/no-machine-id" roots site-config --here lap
expect "an unreadable machine id leaves the host unproven" 2 "" \
  "fm-storage: refused: host-unproven: $W/no-machine-id is unreadable: No such file or directory"

world
edit 'm["roots"]["xp-remote"] = {"host": "tj", "path": "'"$DL"'/xp-remote", "transport": "ssh", "volume": "d"}'
refused "an ssh root on another host is unproven" "remote-unproven: root xp-remote on host tj has no host-side proof"

world
edit 'm["roots"]["xp-units"]["transport"] = "ssh"'
refused "an ssh root on this host is unproven" "remote-unproven: root xp-units on host lap has no host-side proof"

world
edit 'm["roots"]["xp-remote"] = {"host": "tj", "path": "'"$DL"'/xp-remote", "transport": "local", "volume": "d"}'
refused "a local root on another host is refused" "invalid-class-map: root xp-remote is local on another host"

# --- placement ---------------------------------------------------------------

world
edit 'm["roots"]["xp-c"] = {"host": "lap", "path": "'"$W"'/c/xp", "transport": "local", "volume": "host-c"}'
refused "a host-c root is refused" "forbidden-placement: root xp-c is on host-c"

world
edit 'm["classes"]["example-result"] = "xp-meta"'
refused "a payload class on linux is refused" "forbidden-placement: class example-result is on linux; it belongs on d"

world
edit 'm["classes"]["undeclared-default"] = "xp-meta"'
refused "undeclared-default on linux is refused" \
  "forbidden-placement: class undeclared-default is on linux; it belongs on d"

world
edit 'm["classes"]["metadata-view"] = "xp-images"'
refused "metadata-view on d is refused" "forbidden-placement: class metadata-view is on d; it belongs on linux"

world
edit 'del m["classes"]["undeclared-default"]'
refused "undeclared-default must be bound" "missing-class: class undeclared-default is not bound"

world
edit 'del m["classes"]["metadata-view"]'
refused "metadata-view must be bound" "missing-class: class metadata-view is not bound"

world
edit 'm["classes"]["example-result"] = "xp-gone"'
refused "a class on an undefined root is refused" "unknown-root: class example-result maps to undefined root 'xp-gone'"

# --- paths and overlaps ------------------------------------------------------

world
edit 'm["roots"]["xp-images"]["path"] = m["roots"]["xp-units"]["path"]'
refused "two equal roots are refused" "root-overlap: roots xp-images and xp-units are equal or nested"

world
edit 'm["roots"]["xp-images"]["path"] = m["roots"]["xp-units"]["path"] + "/images"'
refused "a nested root is refused" "root-overlap: roots xp-images and xp-units are equal or nested"

world
edit 'm["roots"]["xp-images"]["host"] = "lap-alias"' 'm["roots"]["xp-units"]["host"] = "lap"' \
  'm["roots"]["xp-images"]["path"] = m["roots"]["xp-units"]["path"]'
refused "roots split across a host and its alias still overlap" \
  "root-overlap: roots xp-images and xp-units are equal or nested"

world
edit 'm["roots"]["xp-units"]["path"] = "'"$DL"'/tetjet-results/xp"'
refused "a root inside the legacy D: tree is refused" \
  "root-overlap: root xp-units overlaps the legacy D: directory tetjet-results"

world
edit 'm["roots"]["xp-units"]["path"] = "'"$DL"'/research"'
refused "a root equal to a legacy D: directory is refused" \
  "root-overlap: root xp-units overlaps the legacy D: directory research"

world
edit 'm["roots"]["xp-units"]["path"] = "'"$MNT"'/d/other/xp"'
refused "a d root outside lattice-data is refused" "root-path: root xp-units is a d root outside $DL"

world
edit 'm["roots"]["xp-units"]["path"] = "'"$MNT"'/e/lattice-data/xp"'
refused "a d root on another letter is refused" "root-path: root xp-units is a d root outside $DL"

for part in XP-Units xp. xp~1 'con' 'nul.txt' 'xp:s' 'xp ' '.xp'; do
  world
  python3 -I -c 'import json, sys
path, part = sys.argv[1], sys.argv[2]
with open(path) as f:
    m = json.load(f)
m["roots"]["xp-units"]["path"] = sys.argv[3] + "/" + part
with open(path, "w") as f:
    json.dump(m, f)
' "$CFG/class-map.json" "$part" "$DL" || fail "edit the class map"
  refused "the d name '$part' is refused" "root-path: root xp-units name '$part' is not a lower-case Windows-safe name"
done

world
edit 'm["roots"]["xp-units"]["path"] = "'"$DL"'/./xp"'
refused "a non-canonical path is refused" "root-path: root xp-units path '$DL/./xp' is not a canonical absolute path"

world
edit 'm["roots"]["xp-units"]["path"] = "'"$DL"'/xp/"'
refused "a trailing slash is refused" "root-path: root xp-units path '$DL/xp/' is not a canonical absolute path"

world
edit 'm["roots"]["xp-meta"]["path"] = "home/meta"'
refused "a relative path is refused" "root-path: root xp-meta path 'home/meta' is not a canonical absolute path"

world
edit 'm["roots"]["xp-meta"]["path"] = "'"$MNT"'/e/meta"'
refused "a linux root under the mount base is refused" "root-path: root xp-meta is a linux root under $MNT"

# --- symlinks and aliases ----------------------------------------------------

world
ln -s "$W/home" "$W/link"
edit 'm["roots"]["xp-meta"]["path"] = "'"$W"'/link/meta"'
refused "a symlinked ancestor is refused" "root-symlink: root xp-meta path $W/link/meta goes through a symlink or junction"

world
ln -s "$W/home/meta" "$W/home/meta-link"
edit 'm["roots"]["xp-meta"]["path"] = "'"$W"'/home/meta-link"'
refused "a symlinked root is refused" "root-symlink: root xp-meta path $W/home/meta-link goes through a symlink or junction"

world
ln -s "$DL/xp-images" "$DL/xp-link"
edit 'm["roots"]["xp-units"]["path"] = "'"$DL"'/xp-link"'
refused "a d root that is a link to another root is refused" \
  "root-symlink: root xp-units path $DL/xp-link goes through a symlink or junction"

world
mkdir "$W/cyc"
ln -s "$W/cyc/b" "$W/cyc/a"
ln -s "$W/cyc/a" "$W/cyc/b"
edit 'm["roots"]["xp-meta"]["path"] = "'"$W"'/cyc/a"'
refused "a symlink cycle is refused" "root-symlink: root xp-meta path $W/cyc/a holds a symlink cycle"

world
mkdir -p "$W/bind/meta"
marker xp-bind >"$W/bind/meta/.lattice-xp-root.json"
mounts "3 1 $DEV $W/home $W/bind rw - ext4 /dev/sdc rw"
edit 'm["roots"]["xp-bind"] = {"host": "lap", "path": "'"$W"'/bind/meta", "transport": "local", "volume": "linux"}'
refused "a bind mount of another root is an alias" \
  "root-alias: roots xp-bind and xp-meta are one place or nested through a mount or link"

world
mkdir -p "$W/win/XP-UNITS"
mounts "3 1 $DEV / $W/win rw - 9p D:\\134Lattice-Data rw"
edit 'm["roots"]["xp-win"] = {"host": "lap", "path": "'"$W"'/win/XP-UNITS", "transport": "local", "volume": "linux"}'
refused "a second Windows mount of a d root is an alias, whatever its case" \
  "root-alias: roots xp-units and xp-win are one place or nested through a mount or link"

# --- the D: volume (verify-bulk-root) ----------------------------------------

world
FM_STORAGE_NOW=2801 roots site-config --here lap
expect "a stale publication is a wait" 75 "" "fm-storage: wait: storage-offline: d: stale-publication"

world
FM_STORAGE_NOW=999 roots site-config --here lap
expect "a publication from the future is a wait" 75 "" "fm-storage: wait: storage-offline: d: stale-publication"

world
rm "$CFG/results-root"
waits "no publication is a wait" "storage-offline: d: missing-publication"

world
mounts
sed -i.bak "s#9p D:\\\\134#ext4 /dev/sdd#" "$W/mountinfo" && rm -f "$W/mountinfo.bak"
assert_grep "$MNT/d rw - ext4 /dev/sdd" "$W/mountinfo" "the fake D: entry is Linux-backed"
waits "a Linux directory with copied markers is not D:" "storage-offline: d: wrong-mount-identity"

world
printf 'uniqueid=%s\n' 'volume{other}' >"$CFG/ssd-identity"
waits "another volume id is a wait" "storage-offline: d: wrong-volume-identity"

world
printf '%s\n' 'volume{other}' >"$DL/.lattice-storage-id"
waits "a copied D: marker from another volume is a wait" "storage-offline: d: wrong-volume-identity"

world
FAKE_BULK_DEVICE=998 roots site-config --here lap
expect "another device is a wait" 75 "" "fm-storage: wait: storage-offline: d: wrong-filesystem-identity"

world
roots health --volume d
expect "health is ok on a proven D:" 0 "ok" ""
FM_STORAGE_NOW=2801 roots health --volume d
expect "health reports a stale publication offline" 75 "offline stale-publication" ""
world
mounts
sed -i.bak "s#9p D:\\\\134#ext4 /dev/sdd#" "$W/mountinfo" && rm -f "$W/mountinfo.bak"
roots health --volume d
expect "health reports a Linux-backed D: offline" 75 "offline wrong-mount-identity" ""
world
FAKE_BULK_DEVICE=998 roots health --volume d
expect "health reports a device mismatch offline" 75 "offline wrong-filesystem-identity" ""

# --- each root on the machine ------------------------------------------------

world
rm -r "$DL/xp-units"
waits "an absent root is a wait" "storage-offline: root xp-units: root-absent"

world
rm -r "$DL/xp-units"
: >"$DL/xp-units"
waits "a root that is a file is a wait" "storage-offline: root xp-units: root-not-directory"

world
rm "$DL/xp-units/.lattice-xp-root.json"
waits "an absent root marker is a wait" "storage-offline: root xp-units: marker-absent"

world
cp "$DL/xp-images/.lattice-xp-root.json" "$DL/xp-units/.lattice-xp-root.json"
waits "a root marker copied from another root is a wait" "storage-offline: root xp-units: marker-mismatch"

world
marker xp-units >"$W/elsewhere.json"
rm "$DL/xp-units/.lattice-xp-root.json"
ln -s "$W/elsewhere.json" "$DL/xp-units/.lattice-xp-root.json"
waits "a symlinked root marker is a wait" "storage-offline: root xp-units: marker-mismatch"

world
rm "$DL/xp-units/.lattice-xp-root.json"
mkdir "$DL/xp-units/.lattice-xp-root.json"
waits "a root marker that is a directory is a wait" "storage-offline: root xp-units: marker-mismatch"

world
marker xp-units | tr -d '\n' >"$DL/xp-units/.lattice-xp-root.json"
waits "a root marker without its newline is a wait" "storage-offline: root xp-units: marker-mismatch"

world
mounts "3 1 $DEV /nested-vol $DL/xp-units rw - ext4 /dev/sde rw"
waits "a Linux mount inside D: is not on D:" "storage-offline: root xp-units: not-on-d-volume"

world
sed -i.bak "s#^2 1 $DEV #2 1 0:999 #" "$W/mountinfo" && rm -f "$W/mountinfo.bak"
waits "a mount table device that differs is a wait" "storage-offline: root xp-images: mount-identity-mismatch"

world
mounts "3 1 $DEV /homevol $W/home rw - ext4 /dev/sdf rw"
waits "a linux root on another mount is a wait" "storage-offline: root xp-meta: not-on-linux-volume"

world
mounts "this line is not a mount"
waits "an unreadable mount table line is a wait" "cannot-measure: mount table $W/mountinfo has an unreadable line"

printf 'ok - fm-storage-roots: all cases\n'
