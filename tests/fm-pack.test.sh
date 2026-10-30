#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2016
# Behavior tests for bin/fm-pack.sh (docs/storage.md "Packing cold data").
#
# Every case packs a small fixture tree into a plain directory standing in for
# the D: publication, behind the same PATH-shimmed df and stat that
# tests/fm-disk-room.test.sh uses, so nothing touches real drives or data.
# The member check runs through FM_PACK_MOUNT=unsquashfs; the default
# squashfuse mount path runs only where /dev/fuse can actually mount, and is
# skipped elsewhere.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

for tool in mksquashfs unsquashfs jq sha256sum; do
  command -v "$tool" >/dev/null 2>&1 || { echo "skip: $tool is not installed"; exit 0; }
done

# fm-pack-verification/v1 is test-owned evidence, emitted in the executing CI
# slot's authenticated job log. The parent pins the interpreter and tool bytes
# before running the whole file, checks them again afterwards, and seals the
# exact output/rc plus Git tree and GitHub slot identity. Output is also encoded
# in numbered chunks so a verifier need not guess at Actions' text rendering.
# No seal is emitted for capability skips above or for an uncommitted tree.
if [ "${1:-}" != --sealed-child ]; then
  python3 - "$ROOT" "$0" <<'PY'
import base64
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

root, script = sys.argv[1:]
def git(*args):
    return subprocess.check_output(['git', '-C', root, *args], text=True).strip()
def digest(data):
    return hashlib.sha256(data).hexdigest()
def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':')).encode()
def clean():
    subprocess.run(['git', '-C', root, 'diff-index', '--quiet', 'HEAD', '--'], check=True)

clean()
head, tree = git('rev-parse', 'HEAD'), git('rev-parse', 'HEAD^{tree}')
interpreter = os.readlink(f'/proc/{os.getppid()}/exe')
# The tree pins repository inputs; this manifest pins the external executable
# inputs used by the fixtures and production command, including the C compiler.
tools = '''bash sh python3 gcc cc uname mksquashfs unsquashfs jq sha256sum find stat awk
sed grep cut wc sort cat df du flock nice ionice realpath dirname basename
readlink date mkdir mktemp mv rm cp ln chmod cmp head tail tr dd sleep touch'''.split()
pins = []
for tool in tools:
    path = shutil.which(tool)
    if not path:
        raise SystemExit('seal input missing: ' + tool)
    path = str(Path(path).resolve())
    pins.append({'tool': tool, 'path': path, 'sha256': digest(Path(path).read_bytes())})
interpreter_pin = {'path': interpreter, 'sha256': digest(Path(interpreter).read_bytes()),
                   'version': subprocess.check_output([interpreter, '-c', 'printf %s "$BASH_VERSION"'], text=True)}
result = subprocess.run([interpreter, script, '--sealed-child'], stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
sys.stdout.buffer.write(result.stdout)
sys.stdout.buffer.flush()
clean()
if git('rev-parse', 'HEAD') != head or git('rev-parse', 'HEAD^{tree}') != tree:
    raise SystemExit('seal tree changed during verification')
for pin in pins + [interpreter_pin]:
    if digest(Path(pin['path']).read_bytes()) != pin['sha256']:
        raise SystemExit('seal input changed: ' + pin['path'])
encoded = base64.b64encode(result.stdout).decode()
chunks = [encoded[i:i+4096] for i in range(0, len(encoded), 4096)]
for i, chunk in enumerate(chunks):
    print(f'FM_PACK_OUTPUT {i} {chunk}')
seal = {'format': 'fm-pack-verification/v1', 'head': head, 'tree': tree,
        'interpreter': interpreter_pin, 'pins': pins, 'pins_sha256': digest(canonical(pins)),
        'slot': {k: os.environ.get(k, '') for k in
                 ('GITHUB_REPOSITORY', 'GITHUB_RUN_ID', 'GITHUB_RUN_ATTEMPT', 'GITHUB_JOB',
                  'SHARD', 'SHARD_NUMBER', 'RUNNER_NAME')},
        'rc': result.returncode, 'output_sha256': digest(result.stdout), 'output_chunks': len(chunks)}
print('FM_PACK_SEAL ' + canonical(seal).decode(), flush=True)
sys.exit(result.returncode if result.returncode >= 0 else 128 - result.returncode)
PY
  exit "$?"
fi

unset FM_DISK_ROOM_VHDX FM_DISK_ROOM_DEV_SIZE FM_DISK_ROOM_MARGIN FM_DISK_ROOM_NOW FM_DISK_ROOM_STATE \
  FM_DISK_ROOM_WEVTUTIL FM_DISK_ROOM_POWERSHELL FM_DISK_ROOM_RESULTS_ROOT FM_DISK_ROOM_SAMPLES \
  FM_DISK_ROOM_C_FREE_MIN FM_DISK_ROOM_D_FREE_MIN FM_DISK_ROOM_BULK_MARGIN FM_STORAGE_MNT FM_STORAGE_CONFIG \
  FM_STORAGE_MOUNTINFO FM_STORAGE_RESULTS_ROOT FM_PACK_MOUNT FM_PACK_TEST_BEFORE_RECHECK \
  FM_PACK_SLOT_LOCK FM_PACK_SLOT_WAIT FM_PACK_TEST_IN_COMMIT FM_PACK_RETRY_LIMIT FM_PACK_RETRY_TEST_EVERY \
  FM_PACK_RETRY_LOG FM_PACK_SELF FM_PACK_RUN
TMP_ROOT=$(fm_test_tmproot fm-pack)
PACK="$ROOT/bin/fm-pack.sh"
GIB=1073741824
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
DFDIR="$TMP_ROOT/df"
HOSTDIR="$TMP_ROOT/c"
LINUXDIR="$TMP_ROOT/root"
CFG="$TMP_ROOT/storage"
MP="$TMP_ROOT/mnt/d"
R="$MP/lattice-data/tetjet-results/job"
SRC="$TMP_ROOT/src/unit-a"
mkdir -p "$DFDIR" "$HOSTDIR" "$LINUXDIR" "$CFG" "$MP/lattice-data/tetjet-results"

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
  case "\${!#}" in "\$FAKE_BULK_MNT/d"|"\$FAKE_BULK_MNT/d/"*) printf '%s\\n' 999; exit ;; esac
fi
exec $(command -v stat) "\$@"
SH
chmod +x "$FAKEBIN/stat"

# Each release fixture has a controlled process world (FM_PACK_PROC). Only the
# sleep process a case explicitly starts (PACK_PROC_PID) is in it, linked to its
# real /proc entry; unrelated host processes and exit races cannot turn a
# successful synthetic release into an environmental refusal. A case that
# builds its own world names it in PACK_PROC_ROOT.
export PACK_PROC_PID=''
export PACK_REAL_FIND
PACK_REAL_FIND=$(command -v find)
# PACK_FIND_HANG and PACK_FIND_FAIL make a walk of that one path hang or fail.
cat >"$FAKEBIN/find" <<'SH'
#!/usr/bin/env bash
if [ -n "${PACK_FIND_HANG:-}" ] && [ "$1" = "$PACK_FIND_HANG" ]; then exec sleep 60; fi
if [ -n "${PACK_FIND_FAIL:-}" ] && [ "$1" = "$PACK_FIND_FAIL" ]; then
  echo "find: '$1/held': Permission denied" >&2
  exit 1
fi
exec "$PACK_REAL_FIND" "$@"
SH
chmod +x "$FAKEBIN/find"

proc_world() {
  local d="$TMP_ROOT/proc-world"
  rm -rf "$d" && mkdir "$d" || return 1
  [ -z "$PACK_PROC_PID" ] || ln -s "/proc/$PACK_PROC_PID" "$d/$PACK_PROC_PID"
  printf '%s\n' "$d"
}

key() { printf '%s' "$1" | tr / _; }

# set_linux_free BYTES: Linux root free space as df reports it.
set_linux_free() { printf '%s\n' "$1" >"$DFDIR/$(key "$LINUXDIR").avail"; }

printf '%s\n' $((60 * GIB)) >"$DFDIR/$(key "$HOSTDIR").avail"
printf '%s\n' $((400 * GIB)) >"$DFDIR/$(key "$LINUXDIR").used"
printf '%s\n' $((1000 * GIB)) >"$DFDIR/$(key "$LINUXDIR").size"
set_linux_free $((600 * GIB))
printf '%s\n' $((100 * GIB)) >"$DFDIR/$(key "$MP/lattice-data/tetjet-results").avail"

publish_d() {
  printf 'volume-d\n' >"$MP/lattice-data/.lattice-storage-id"
  printf 'uniqueid=volume-d\n' >"$CFG/ssd-identity"
  printf '1 2 0:1 / %s rw - 9p D: rw\n' "$MP" >"$TMP_ROOT/mountinfo"
  printf '%s/lattice-data/tetjet-results/{task}\nformat=lattice-storage-results-root/v1\nactive=ssd\nstate=ok\nssd_letter=D\nssd_fs=exFAT\nssd_id=volume-d\nssd_marker=%s/lattice-data/.lattice-storage-id\nssd_device=999\nchecked_at=%s\n' \
    "$MP" "$MP" "$(date +%s)" >"$CFG/results-root"
}

run_pack() {
  PATH="$FAKEBIN:$PATH" FAKE_DF="$DFDIR" FAKE_BULK_MNT="$TMP_ROOT/mnt" \
    FM_STORAGE_CONFIG="$CFG" FM_STORAGE_MNT="$TMP_ROOT/mnt" FM_STORAGE_MOUNTINFO="$TMP_ROOT/mountinfo" \
    FM_DISK_ROOM_STATE="${PACK_RELEASE_STATE:-$TMP_ROOT/state}" FM_DISK_ROOM_RESULTS_ROOT="$CFG/results-root" \
    FM_DISK_ROOM_HOST="$HOSTDIR" FM_DISK_ROOM_ROOT="$LINUXDIR" FM_DISK_ROOM_POWERSHELL='' FM_DISK_ROOM_WEVTUTIL='' \
    FM_DISK_ROOM_SAMPLES="$TMP_ROOT/no-samples" FM_DISK_ROOM_C_FREE_MIN=off FM_DISK_ROOM_MB_GROUPS="$TMP_ROOT/no-mb-groups" \
    FM_DISK_ROOM_VHDX="$TMP_ROOT/no-vhdx" FM_DISK_ROOM_DEV_SIZE=$((1000 * GIB)) FM_DISK_ROOM_MARGIN=1G \
    FM_DISK_ROOM_BULK_MARGIN=1G FM_PACK_MOUNT="${FM_PACK_MOUNT-unsquashfs}" FM_HOME="$TMP_ROOT/home" \
    FM_PACK_SLOT_LOCK="${PACK_SLOT_LOCK:-$TMP_ROOT/slot.lock}" \
    FM_PACK_PROC="${PACK_PROC_ROOT:-$(proc_world)}" bash "${PACK_EXEC:-$PACK}" "$@"
}

# make_src DIR: six regular files (one empty, one with a space, a hard-linked
# pair, and one also linked from outside DIR), plus a symlink and a nested dir.
make_src() {
  mkdir -p "$1/nested/deep"
  printf 'hello world' >"$1/nested/deep/file.txt"
  : >"$1/empty"
  ln -s nested/deep/file.txt "$1/link"
  printf 'abcd' >"$1/with space.txt"
  head -c 3000 /dev/zero | tr '\0' a >"$1/hl1"
  ln "$1/hl1" "$1/hl2"
  head -c 5000 /dev/zero | tr '\0' b >"$1/shared"
  ln "$1/shared" "$TMP_ROOT/outside-$(basename "$1")"
}

snapshot() { (cd "$1" && find . -printf '%y %s %m %n %T@ %l %p\n' | LC_ALL=C sort && find . -type f -exec sha256sum {} + | LC_ALL=C sort); }

pack_reservations() { find "$TMP_ROOT/state" -path '*reservations-d*' -name '*pack-*' 2>/dev/null; }

receipt_field() { printf '%s\n' "$1" | tr ' ' '\n' | sed -n "s/^$2=//p"; }

make_src "$SRC"
SNAP=$(snapshot "$SRC")

test_no_publication_waits() {
  local out rc
  out=$(run_pack pack job unit-a "$SRC" 2>&1); rc=$?
  expect_code 75 "$rc" "no D: publication is a wait"
  assert_absent "$R" "a refused pack writes nothing on D:"
  assert_equals "" "$(pack_reservations)" "a refused pack holds no reservation"
  assert_equals "$SNAP" "$(snapshot "$SRC")" "the source is untouched"
  pass "pack waits with 75 and writes nothing when D: is not published"
}

test_pack_round_trip() {
  local out rc img json now
  publish_d
  out=$(run_pack pack job unit-a "$SRC"); rc=$?
  expect_code 0 "$rc" "pack commits"
  img="$R/unit-a.sqfs" json="$R/unit-a.json"
  assert_equals 1 "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" "pack prints one line"
  assert_contains "$out" "fm-pack-receipt/v1 image=$img " "receipt names the image"
  assert_equals 6 "$(receipt_field "$out" files)" "six regular files"
  assert_equals 11015 "$(receipt_field "$out" logical)" "logical bytes count every link"
  assert_equals 3015 "$(receipt_field "$out" frees)" "frees skips a file linked from outside and counts a pair once"
  assert_equals "$json" "$(receipt_field "$out" sidecar)" "receipt names the sidecar"
  assert_equals "$(cut -d' ' -f1 <"$R/unit-a.sqfs.sha256")" "$(receipt_field "$out" sha256)" "receipt sha256 is the image's"
  assert_equals "$(sha256sum <"$img" | cut -d' ' -f1)" "$(receipt_field "$out" sha256)" "the sha256 file matches the image"
  for f in sqfs.sha256 members.sha256 tree.tsv json; do assert_present "$R/unit-a.$f" "sidecar $f committed"; done
  assert_absent "$R/.incoming" "no staging left"
  assert_equals 6 "$(wc -l <"$R/unit-a.members.sha256" | tr -d ' ')" "members list has six lines"
  assert_equals fm-pack-unit/v1 "$(jq -r .format "$json")" "sidecar format"
  assert_equals unit-a "$(jq -r .dir "$json")" "sidecar records the directory name"
  assert_equals "$TMP_ROOT/home" "$(jq -r .owner_home "$json")" "sidecar records the owner home"
  assert_equals "$(receipt_field "$out" verified_at)" "$(jq -r .verified_at "$json")" "sidecar verified_at matches the receipt"
  now=$(date +%s)
  [ "$(jq -r .packed_at "$json")" -le "$(jq -r .verified_at "$json")" ] && [ "$(jq -r .verified_at "$json")" -le "$now" ] ||
    fail "packed_at <= verified_at <= now"
  assert_equals unsquashfs "$(jq -r .verify_method "$json")" "sidecar names the verify path"
  assert_equals "" "$(pack_reservations)" "the pack reservation is released"
  assert_contains "$(unsquashfs -lls "$img")" "squashfs-root/unit-a/link -> nested/deep/file.txt" "the image keeps the symlink"
  out=$(run_pack verify "$img"); rc=$?
  expect_code 0 "$rc" "verify passes"
  assert_contains "$out" "verified $img (6 files, unsquashfs)" "verify names the count and path"
  out=$(run_pack verify "$img" --against "$SRC"); rc=$?
  expect_code 0 "$rc" "verify --against an unchanged source passes"
  assert_contains "$out" "source unchanged" "verify --against says so"
  assert_equals "$SNAP" "$(snapshot "$SRC")" "the source is untouched"
  pass "pack commits a verified image with its sidecars and one receipt line"
}

# wait_for SECONDS COMMAND...: wait until COMMAND succeeds; SECONDS only
# bounds a hang.
wait_for() {
  local cap=$(($1 * 20)) _; shift
  for _ in $(seq "$cap"); do
    "$@" && return 0
    sleep 0.05
  done
  return 1
}

test_machine_share() {
  local out err rc src="$TMP_ROOT/src/unit-s" probe="$TMP_ROOT/share-probe" linux=''
  [ "$(uname -s)" != Linux ] || linux=1
  make_src "$src"
  mkdir -p "$probe"
  # On Linux every process fails its first wrapped call (and every 40th) with
  # ENOMEM; without the retry the shell itself, mksquashfs or the member check
  # fails. Elsewhere there is no shim and the hook does nothing.
  err="$TMP_ROOT/share.err"
  out=$(FM_PACK_RETRY_TEST_EVERY=40 \
    FM_PACK_TEST_BEFORE_RECHECK="nice >'$probe/nice'; ionice -p \$\$ >'$probe/io' 2>&1; grep -c fm-pack-retry.so /proc/\$\$/maps >'$probe/maps'" \
    run_pack pack job unit-s "$src" 2>"$err"); rc=$?
  expect_code 0 "$rc" "pack commits while its reads, writes and opens fail with ENOMEM: $(cat "$err")"
  assert_contains "$out" "fm-pack-receipt/v1 image=$R/unit-s.sqfs " "the receipt names the image"
  if [ -n "$linux" ]; then
    assert_grep "fm-pack: retried " "$err" "pack reports the calls it retried"
    [ "$(cat "$probe/maps")" -ge 1 ] || fail "every step runs with the retry shim loaded"
  fi
  assert_no_grep "still failed with ENOMEM" "$err" "no call gave up"
  assert_equals 19 "$(cat "$probe/nice")" "every step runs at nice 19"
  if command -v ionice >/dev/null 2>&1; then
    assert_equals idle "$(cat "$probe/io")" "every step runs at idle I/O priority"
  fi
  out=$(FM_PACK_RETRY_TEST_EVERY=40 run_pack verify "$R/unit-s.sqfs" --against "$src" 2>"$err"); rc=$?
  expect_code 0 "$rc" "verify passes while its reads fail with ENOMEM: $(cat "$err")"
  assert_contains "$out" "verified $R/unit-s.sqfs (6 files, unsquashfs), source unchanged" "verify reads every member"
  [ -z "$linux" ] || assert_grep "fm-pack: retried " "$err" "verify reports the calls it retried"
  out=$(run_pack verify "$R/unit-s.sqfs" 2>&1); rc=$?
  expect_code 0 "$rc" "verify without injected failures passes"
  assert_not_contains "$out" "retried" "no retry note when nothing was retried"
  pass "fm-pack runs at nice 19 and idle I/O and retries calls that fail with ENOMEM"
}

test_slot_waits() {
  local lock="$TMP_ROOT/held-slot.lock" ready="$TMP_ROOT/slot-ready" go="$TMP_ROOT/slot-go"
  local out="$TMP_ROOT/slot.out" err="$TMP_ROOT/slot.err" holder verify rc
  # The holder keeps no output pipe open and gives up after 300 s, so a failed
  # assertion below ends the test instead of leaving it waiting on the holder.
  flock "$lock" bash -c 'printf "pid=%s started=1 command=test-holder\n" "$$" >"$1"; : >"$2"; n=0
    until [ -e "$3" ] || [ "$n" -ge 6000 ]; do sleep 0.05; n=$((n + 1)); done' _ "$lock" "$ready" "$go" \
    </dev/null >/dev/null 2>&1 &
  holder=$!
  wait_for 30 test -e "$ready" || fail "the test holder never took the slot"
  PACK_SLOT_LOCK=$lock run_pack verify "$R/unit-a.sqfs" >"$out" 2>"$err" &
  verify=$!
  wait_for 60 grep -F "waiting for the machine-wide pack slot $lock" "$err" >/dev/null ||
    fail "a second caller never said it waits: $(cat "$err")"
  kill -0 "$verify" 2>/dev/null || fail "the waiting caller exited instead of waiting"
  assert_equals "" "$(cat "$out")" "the waiting caller does no work while the slot is held"
  : >"$go"
  wait "$holder"
  wait "$verify"; rc=$?
  expect_code 0 "$rc" "the waiting caller runs once the slot is free"
  assert_contains "$(cat "$out")" "verified $R/unit-a.sqfs" "the waiting caller verifies"
  assert_equals 1 "$(grep -c 'waiting for the machine-wide pack slot' "$err")" "one waiting line"
  assert_grep "held by pid=" "$err" "the waiting line names the holder"
  assert_grep "command=test-holder" "$err" "the waiting line quotes the holder's command"
  assert_grep "command=fm-pack verify $R/unit-a.sqfs" "$lock" "the holder names itself in the slot"
  pass "a second caller prints one line and waits for the machine-wide slot"
}

# pid_gone PID: PID has exited (or is a reaped orphan).
pid_gone() { ! kill -0 "$1" 2>/dev/null; }

test_slot_wait_is_bounded() {
  local lock="$TMP_ROOT/busy-slot.lock" ready="$TMP_ROOT/busy-ready" go="$TMP_ROOT/busy-go"
  local err="$TMP_ROOT/busy.err" out holder hpid line began rc
  flock "$lock" bash -c 'printf "pid=%s started=1 command=test-holder\n" "$$" >"$1"; : >"$2"; n=0
    until [ -e "$3" ] || [ "$n" -ge 6000 ]; do sleep 0.05; n=$((n + 1)); done' _ "$lock" "$ready" "$go" \
    </dev/null >/dev/null 2>&1 &
  holder=$!
  wait_for 30 test -e "$ready" || fail "the test holder never took the slot"
  began=$SECONDS
  out=$(FM_PACK_SLOT_WAIT=2 PACK_SLOT_LOCK=$lock run_pack pack job unit-busy "$SRC" 2>"$err"); rc=$?
  expect_code 75 "$rc" "a pack that finds the slot held past its bound waits with 75"
  [ $((SECONDS - began)) -ge 2 ] || fail "the pack gave up before its 2 s bound: $(cat "$err")"
  [ $((SECONDS - began)) -lt 120 ] || fail "the pack waited far past its 2 s bound"
  assert_equals "" "$out" "the busy pack prints no receipt"
  assert_grep "waiting for the machine-wide pack slot $lock (at most 2 s), held by pid=" "$err" "one waiting line names the bound"
  assert_grep "fm-pack: wait: pack-slot-busy: $lock still held after 2 s by pid=" "$err" "the wait line names the slot and the bound"
  assert_grep "command=test-holder; nothing done" "$err" "the wait line names the holder and that nothing was done"
  assert_absent "$R/unit-busy.sqfs" "the busy pack commits nothing"
  assert_equals "" "$(pack_reservations)" "the busy pack holds no reservation"
  out=$(FM_PACK_SLOT_WAIT=soon PACK_SLOT_LOCK=$lock run_pack verify "$R/unit-a.sqfs" 2>&1); rc=$?
  expect_code 2 "$rc" "a bound that is not whole seconds is misuse"
  assert_contains "$out" "FM_PACK_SLOT_WAIT must be whole seconds" "the refusal names the variable"

  # stop signals only a holder named by pid and start time.
  out=$(PACK_SLOT_LOCK=$lock run_pack stop 2>&1); rc=$?
  expect_code 1 "$rc" "stop refuses a holder line without a start time"
  assert_contains "$out" "has not named itself as pid=PID start=TICKS" "the refusal says why"
  line=$(cat "$lock") hpid=${line#pid=} hpid=${hpid%% *}
  printf 'pid=%s start=1 started=1 command=test-holder\n' "$hpid" >"$lock"
  out=$(PACK_SLOT_LOCK=$lock run_pack stop 2>&1); rc=$?
  expect_code 1 "$rc" "stop refuses a pid whose start time differs"
  assert_contains "$out" "not the holder's 1; nothing signalled" "the refusal names the mismatch"
  kill -0 "$hpid" 2>/dev/null || fail "a refused stop signalled the holder"
  : >"$go"
  wait "$holder"
  out=$(PACK_SLOT_LOCK=$lock run_pack stop 2>&1); rc=$?
  expect_code 0 "$rc" "stop with a free slot succeeds"
  assert_contains "$out" "fm-pack: stop: the pack slot $lock is free" "stop says the slot is free"
  out=$(PACK_SLOT_LOCK="$TMP_ROOT/never.lock" run_pack stop 2>&1); rc=$?
  expect_code 0 "$rc" "stop with no slot file succeeds"
  assert_contains "$out" "is free ($TMP_ROOT/never.lock does not exist)" "stop says no slot exists"
  pass "a held slot makes a second pack wait its bound and exit 75, and stop refuses an unproven holder"
}

test_stop_finishes_the_commit() {
  local lock="$TMP_ROOT/commit-slot.lock" src="$TMP_ROOT/stop-commit/unit-sc" ready="$TMP_ROOT/commit-ready"
  local go="$TMP_ROOT/commit-go" err="$TMP_ROOT/commit.err" out="$TMP_ROOT/commit.out" pack stop rc
  mkdir -p "${src%/*}"
  make_src "$src"
  PACK_SLOT_LOCK=$lock \
    FM_PACK_TEST_IN_COMMIT=": >'$ready'; n=0; until [ -e '$go' ] || [ \$n -ge 6000 ]; do sleep 0.05; n=\$((n + 1)); done" \
    run_pack pack job unit-sc "$src" </dev/null >"$out" 2>"$err" &
  pack=$!
  wait_for 120 test -e "$ready" || fail "the pack never reached its commit: $(cat "$err")"
  PACK_SLOT_LOCK=$lock run_pack stop --wait 120 </dev/null >"$TMP_ROOT/commit-stop.out" 2>"$TMP_ROOT/commit-stop.err" &
  stop=$!
  wait_for 60 grep -F "sent SIGTERM to the pack slot holder pid" "$TMP_ROOT/commit-stop.err" >/dev/null ||
    fail "stop never signalled the holder: $(cat "$TMP_ROOT/commit-stop.err")"
  kill -0 "$pack" 2>/dev/null || fail "the pack ended inside its commit"
  : >"$go"
  wait "$stop"; rc=$?
  expect_code 0 "$rc" "stop returns once the holder has stopped"
  assert_grep "fm-pack: stop: the pack slot holder pid" "$TMP_ROOT/commit-stop.out" "stop says the holder stopped"
  wait "$pack"; rc=$?
  expect_code 0 "$rc" "a stop during the commit lets the pack finish"
  assert_grep "fm-pack-receipt/v1 image=$R/unit-sc.sqfs " "$out" "the pack still prints its receipt"
  assert_grep "a stop arrived during the commit of unit-sc; the unit was committed whole first" "$err" "the pack says a stop arrived"
  for f in sqfs sqfs.sha256 members.sha256 tree.tsv json; do assert_present "$R/unit-sc.$f" "unit-sc.$f committed"; done
  assert_absent "$R/.incoming" "no staging left"
  assert_equals "" "$(pack_reservations)" "the pack reservation is released"
  out=$(run_pack verify "$R/unit-sc.sqfs" --against "$src"); rc=$?
  expect_code 0 "$rc" "the committed unit verifies against its source"
  pass "stop during the commit ends the pack after the unit is whole"
}

test_stop_ends_a_running_step() {
  local lock="$TMP_ROOT/step-slot.lock" src="$TMP_ROOT/stop-step/unit-ss" slow="$TMP_ROOT/slow-bin"
  local ev="$TMP_ROOT/slow-ev" err="$TMP_ROOT/step.err" out real pack sleeper rc
  real=$(command -v mksquashfs) || fail "no mksquashfs"
  mkdir -p "${src%/*}" "$slow" "$ev"
  make_src "$src"
  cat >"$slow/mksquashfs" <<SH
#!/usr/bin/env bash
[ "\${1:-}" != -version ] || exec "$real" "\$@"
sleep 600 </dev/null >/dev/null 2>&1 &
printf '%s\n' "\$!" >"$ev/sleep.tmp" && mv "$ev/sleep.tmp" "$ev/sleep"
wait
SH
  chmod +x "$slow/mksquashfs"
  PATH="$slow:$PATH" PACK_SLOT_LOCK=$lock run_pack pack job unit-ss "$src" </dev/null >"$TMP_ROOT/step.out" 2>"$err" &
  pack=$!
  wait_for 120 test -e "$ev/sleep" || fail "the pack never reached mksquashfs: $(cat "$err")"
  sleeper=$(cat "$ev/sleep")
  out=$(PACK_SLOT_LOCK=$lock run_pack stop --wait 120 2>&1); rc=$?
  expect_code 0 "$rc" "stop ends a pack inside a long step"
  assert_contains "$out" "sent SIGTERM to the pack slot holder pid" "stop names the signal it sent"
  assert_contains "$out" "fm-pack: stop: the pack slot holder pid" "stop says the holder stopped"
  wait "$pack"; rc=$?
  expect_code 143 "$rc" "a stopped pack exits 143"
  assert_grep "fm-pack: stopped by SIGTERM" "$err" "the pack says it was stopped"
  wait_for 30 pid_gone "$sleeper" || fail "the step's process group outlived the stop"
  assert_equals "" "$(cat "$TMP_ROOT/step.out")" "a stopped pack prints no receipt"
  assert_absent "$R/unit-ss.sqfs" "a stopped pack commits no image"
  assert_absent "$R/unit-ss.json" "a stopped pack commits no sidecar"
  assert_absent "$R/.incoming" "a stopped pack leaves no staging"
  assert_equals "" "$(pack_reservations)" "a stopped pack holds no reservation"
  out=$(PACK_SLOT_LOCK=$lock run_pack stop 2>&1); rc=$?
  expect_code 0 "$rc" "the slot is free after the stop"
  assert_contains "$out" "is free" "stop finds the slot free"
  pass "stop ends a pack's running step and leaves the store as it was"
}

test_against_changed_source() {
  local out rc copy="$TMP_ROOT/changed/unit-a"
  mkdir -p "$TMP_ROOT/changed"
  cp -a "$SRC" "$copy"
  printf 'more' >>"$copy/with space.txt"
  out=$(run_pack verify "$R/unit-a.sqfs" --against "$copy" 2>&1); rc=$?
  expect_code 1 "$rc" "verify --against a changed source fails"
  assert_contains "$out" "no longer matches" "the failure names the tree list"
  pass "verify --against refuses a source that changed after packing"
}

test_source_change_refuses() {
  local out rc src_b="$TMP_ROOT/src/unit-b" snap_b
  make_src "$src_b"
  snap_b=$(snapshot "$src_b")
  out=$(FM_PACK_TEST_BEFORE_RECHECK="touch -d @1 '$src_b/empty'" run_pack pack job unit-b "$src_b" 2>&1); rc=$?
  expect_code 1 "$rc" "a source change during the pack refuses"
  assert_contains "$out" "changed while it was packed" "the refusal names the change"
  for f in sqfs sqfs.sha256 members.sha256 tree.tsv json; do assert_absent "$R/unit-b.$f" "nothing committed: $f"; done
  assert_absent "$R/.incoming" "this run's staging is removed"
  assert_equals "" "$(pack_reservations)" "the reservation is released on refusal"
  assert_present "$R/unit-a.sqfs" "an earlier unit is untouched"
  assert_equals "$SNAP" "$(snapshot "$SRC")" "the other source is untouched"
  [ "$snap_b" != "$(snapshot "$src_b")" ] || fail "the hook changed unit-b"
  pass "pack refuses with 1 and commits nothing when the source changes"
}

# tamper_copy NAME: a copy of unit-a's image and sidecars under NAME/.
tamper_copy() {
  local d="$TMP_ROOT/$1" f
  mkdir -p "$d"
  for f in sqfs sqfs.sha256 members.sha256 tree.tsv json; do cp "$R/unit-a.$f" "$d/unit-a.$f"; done
  printf '%s\n' "$d"
}

# flip_first_hash FILE: change the first hex digit of FILE's first line.
flip_first_hash() { sed -i '1s/^0/1/;t;1s/^./0/' "$1"; }

test_tampering_fails_verify() {
  local out rc d size
  d=$(tamper_copy flipped)
  size=$(stat -c %s "$d/unit-a.sqfs")
  printf '\377' | dd of="$d/unit-a.sqfs" bs=1 seek=$((size / 2)) conv=notrunc status=none
  out=$(run_pack verify "$d/unit-a.sqfs" 2>&1); rc=$?
  expect_code 1 "$rc" "a flipped image byte fails verify"
  assert_contains "$out" "does not match" "the failure names the image sha256"
  d=$(tamper_copy edited)
  flip_first_hash "$d/unit-a.members.sha256"
  out=$(run_pack verify "$d/unit-a.sqfs" 2>&1); rc=$?
  expect_code 1 "$rc" "an edited members line fails verify"
  assert_contains "$out" "FAILED" "the failure names the member"
  d=$(tamper_copy short)
  sed -i '$d' "$d/unit-a.members.sha256"
  out=$(run_pack verify "$d/unit-a.sqfs" 2>&1); rc=$?
  expect_code 1 "$rc" "a members list missing a file fails verify"
  pass "verify fails on a changed image byte or members list"
}

test_repack_refuses() {
  local out rc before
  before=$(sha256sum <"$R/unit-a.sqfs")
  out=$(run_pack pack job unit-a "$SRC" 2>&1); rc=$?
  expect_code 2 "$rc" "packing an existing unit is misuse"
  assert_contains "$out" "never overwritten" "the refusal says why"
  assert_equals "$before" "$(sha256sum <"$R/unit-a.sqfs")" "the image is unchanged"
  assert_equals "" "$(pack_reservations)" "the reservation is released"
  out=$(run_pack pack job ../escape "$SRC" 2>&1); rc=$?
  expect_code 2 "$rc" "a unit name with a slash is misuse"
  assert_equals "$SNAP" "$(snapshot "$SRC")" "the source is untouched"
  pass "pack never overwrites a unit"
}

# no_fuse_path: a PATH dir holding every tool on PATH except squashfuse and
# fusermount3.
no_fuse_path() {
  fm_test_base_path_sans "$PATH" squashfuse fusermount3
}

test_reader_mode_refuses() {
  local out rc nofuse mode
  nofuse=$(no_fuse_path)
  out=$(FM_PACK_MOUNT='' PATH="$nofuse" run_pack pack job unit-n "$SRC" 2>&1); rc=$?
  expect_code 2 "$rc" "pack without a usable FUSE mount in the default mode is refused"
  assert_contains "$out" "no usable FUSE mount" "the refusal names the missing mount"
  out=$(FM_PACK_MOUNT='' PATH="$nofuse" run_pack verify "$R/unit-a.sqfs" 2>&1); rc=$?
  expect_code 2 "$rc" "verify without a usable FUSE mount in the default mode is refused"
  assert_contains "$out" "no usable FUSE mount" "the verify refusal names the missing mount"
  for mode in on off auto; do
    out=$(FM_PACK_MOUNT=$mode run_pack pack job unit-n "$SRC" 2>&1); rc=$?
    expect_code 2 "$rc" "pack with FM_PACK_MOUNT=$mode is misuse"
    assert_contains "$out" "FM_PACK_MOUNT must be mount or unsquashfs" "the refusal names the variable"
    out=$(FM_PACK_MOUNT=$mode run_pack verify "$R/unit-a.sqfs" 2>&1); rc=$?
    expect_code 2 "$rc" "verify with FM_PACK_MOUNT=$mode is misuse"
    out=$(FM_PACK_MOUNT=$mode run_pack restore "$R/unit-a.sqfs" "$TMP_ROOT/restore-$mode" 2>&1); rc=$?
    expect_code 2 "$rc" "restore with FM_PACK_MOUNT=$mode is misuse"
    assert_absent "$TMP_ROOT/restore-$mode" "a misused restore writes nothing"
  done
  for f in sqfs sqfs.sha256 members.sha256 tree.tsv json; do assert_absent "$R/unit-n.$f" "nothing written: $f"; done
  assert_absent "$R/.incoming" "no staging created"
  assert_equals "" "$(pack_reservations)" "no reservation is held"
  assert_equals "$SNAP" "$(snapshot "$SRC")" "the source is untouched"
  pass "pack and verify refuse with 2 before any work on an unknown or unusable reader"
}

test_root_overlap_refuses() {
  local out rc before parent="$MP/lattice-data/tetjet-results" stage="$R/.incoming/inner"
  before=$(snapshot "$parent")
  out=$(run_pack pack job job-raw "$R" 2>&1); rc=$?
  expect_code 2 "$rc" "packing the task's own results root is refused"
  assert_contains "$out" "the D: root $R is $R or inside it" "the refusal names both paths"
  out=$(run_pack pack job job-up "$parent" 2>&1); rc=$?
  expect_code 2 "$rc" "packing a tree that holds the results root is refused"
  assert_contains "$out" "the D: root $R is $parent or inside it" "the refusal names both paths"
  assert_equals "$before" "$(snapshot "$parent")" "a refused overlap writes nothing on D:"
  assert_equals "" "$(pack_reservations)" "no reservation is held"
  mkdir -p "$stage"
  printf 'x' >"$stage/f"
  out=$(run_pack pack job job-in "$stage" 2>&1); rc=$?
  expect_code 2 "$rc" "packing a tree inside the staging is refused"
  assert_contains "$out" "$stage is inside the staging of the D: root $R" "the refusal names both paths"
  assert_equals "" "$(pack_reservations)" "no reservation is held"
  assert_equals x "$(cat "$stage/f")" "the staged source is untouched"
  rm -rf "$R/.incoming"
  pass "pack refuses with 2 when the D: root and SRC overlap"
}

test_restore() {
  local out rc dest="$TMP_ROOT/restored"
  out=$(run_pack restore "$R/unit-a.sqfs" "$dest" 2>&1); rc=$?
  expect_code 0 "$rc" "restore succeeds"
  assert_contains "$out" "checked 6 files" "restore checks every member"
  assert_equals "$(cd "$SRC" && find . -type f -exec sha256sum {} + | LC_ALL=C sort)" \
    "$(cd "$dest/unit-a" && find . -type f -exec sha256sum {} + | LC_ALL=C sort)" "restored contents match"
  assert_equals nested/deep/file.txt "$(readlink "$dest/unit-a/link")" "the symlink is restored"
  assert_equals "$(stat -c %i "$dest/unit-a/hl1")" "$(stat -c %i "$dest/unit-a/hl2")" "the hard-linked pair is restored"
  out=$(run_pack restore "$R/unit-a.sqfs" "$dest" 2>&1); rc=$?
  expect_code 2 "$rc" "restore never writes into an existing path"
  set_linux_free "$GIB"
  out=$(run_pack restore "$R/unit-a.sqfs" "$TMP_ROOT/low" 2>&1); rc=$?
  set_linux_free $((600 * GIB))
  expect_code 75 "$rc" "restore with no Linux room is refused"
  assert_contains "$out" "refused restore-unit-a" "the refusal names the job"
  assert_absent "$TMP_ROOT/low" "a refused restore writes nothing"
  assert_equals "$SNAP" "$(snapshot "$SRC")" "the source is untouched"
  pass "restore unpacks and checks the unit, and waits for room"
}

# make_arrival NAME: an arrival unit NAME in the shape a lattice-research
# fetch-arrival v2 writer leaves it: the image root holds NAME/ and the
# .tj-pack.json marker, members list paths carry no ./, the tree list is
# tj-pack-tree/v1, and NAME.json has the tj-fetch-arrival-unit/v2 field set.
ARR="$TMP_ROOT/arrival"
make_arrival() {
  local k=$1 stage="$TMP_ROOT/arrival-stage" files logical now
  mkdir -p "$stage/$k/sub" "$ARR"
  printf 'arrival one' >"$stage/$k/a.txt"
  printf 'arrival two' >"$stage/$k/sub/b.txt"
  : >"$stage/$k/sub/empty"
  printf '{"layout":"tj-pack-marker/v1"}\n' >"$stage/.tj-pack.json"
  mksquashfs "$stage" "$ARR/$k.sqfs" -noappend -comp gzip -no-xattrs -quiet -no-progress >/dev/null
  (cd "$ARR" && sha256sum -- "$k.sqfs" >"$k.sqfs.sha256")
  (cd "$stage/$k" && find . -type f -printf '%P\n' | LC_ALL=C sort | xargs -d '\n' sha256sum --) >"$ARR/$k.members.sha256"
  {
    printf '# tj-pack-tree/v1\tkind\tsize\tperm\tlink\tpath\n'
    (cd "$stage/$k" && find . -mindepth 1 -printf '%y\t%s\t%m\t-\t%P\n' | LC_ALL=C sort -t$'\t' -k5)
  } >"$ARR/$k.tree.tsv"
  cp "$stage/.tj-pack.json" "$ARR/$k.marker.json"
  files=$(wc -l <"$ARR/$k.members.sha256" | tr -d ' ')
  logical=$(find "$stage/$k" -type f -printf '%s\n' | awk '{n += $1} END {print n + 0}')
  now=$(date +%s)
  jq -n --arg k "$k" --arg arr "$ARR" --arg home "$TMP_ROOT/home" --argjson files "$files" --argjson logical "$logical" \
    --argjson bytes "$(stat -c %s "$ARR/$k.sqfs")" --arg sha "$(cut -d' ' -f1 <"$ARR/$k.sqfs.sha256")" \
    --arg msha "$(sha256sum <"$ARR/$k.members.sha256" | cut -d' ' -f1)" --argjson now "$now" \
    '{format: "tj-fetch-arrival-unit/v2", fm_pack_reader: "verify/restore-compatible subset", unit: $k, task: "job",
      root: "tetjet-results", source: ($arr + "/" + $k + ".raw.tar"), source_kind: "tar-stream", dir: $k,
      owner_home: $home, files: $files, logical_bytes: $logical, frees_bytes: 0, image: ($arr + "/" + $k + ".sqfs"),
      image_bytes: $bytes, image_sha256: $sha, members_sha256: $msha, packed_at: $now, verified_at: $now,
      verify_method: "mount", pack_layout: "tj-pack-marker/v1", raw_archive: ($arr + "/" + $k + ".raw.tar"),
      raw_sha256: $sha, retention: {class: "R2", delete: true, minimum_days_after_verify: 0,
        requires: ["cold fresh-mount member verification", "G7", "G8", "raw integrity"]},
      raw_release_record: ($arr + "/" + $k + ".raw.tar.released.json")}' >"$ARR/$k.json"
  rm -rf "$stage"
}

test_unit_format() {
  local out rc d fmt dest
  d=$(tamper_copy fmt-v9)
  jq '.format = "fm-pack-unit/v9"' "$R/unit-a.json" >"$d/unit-a.json"
  d=$(tamper_copy fmt-none)
  jq 'del(.format)' "$R/unit-a.json" >"$d/unit-a.json"
  for fmt in v9 none; do
    d="$TMP_ROOT/fmt-$fmt"
    printf '\377' | dd of="$d/unit-a.sqfs" bs=1 seek=0 conv=notrunc status=none
    out=$(run_pack verify "$d/unit-a.sqfs" 2>&1); rc=$?
    expect_code 2 "$rc" "verify refuses a unit with format $fmt"
    assert_contains "$out" "$d/unit-a.json has" "the verify refusal names the unit file"
    dest="$TMP_ROOT/restore-fmt-$fmt"
    out=$(run_pack restore "$d/unit-a.sqfs" "$dest" 2>&1); rc=$?
    expect_code 2 "$rc" "restore refuses a unit with format $fmt"
    assert_absent "$dest" "a refused restore writes nothing"
  done
  assert_contains "$(run_pack verify "$TMP_ROOT/fmt-v9/unit-a.sqfs" 2>&1)" "unknown format fm-pack-unit/v9" "the refusal names the format"
  assert_contains "$(run_pack restore "$TMP_ROOT/fmt-none/unit-a.sqfs" "$TMP_ROOT/r" 2>&1)" "has no format" "the refusal names the missing format"
  pass "verify and restore refuse an unknown or missing unit format with 2 before any work"
}

test_arrival_unit() {
  local out rc dest="$TMP_ROOT/restored-arrival" d
  make_arrival pkg-a
  out=$(run_pack verify "$ARR/pkg-a.sqfs"); rc=$?
  expect_code 0 "$rc" "an arrival unit verifies"
  assert_contains "$out" "(3 files, unsquashfs)" "verify checks every arrival member"
  out=$(run_pack restore "$ARR/pkg-a.sqfs" "$dest" 2>&1); rc=$?
  expect_code 0 "$rc" "an arrival unit restores"
  assert_contains "$out" "checked 3 files" "restore checks every arrival member"
  assert_equals 'arrival two' "$(cat "$dest/pkg-a/sub/b.txt")" "restored arrival contents match"
  out=$(run_pack verify "$ARR/pkg-a.sqfs" --against "$dest/pkg-a" 2>&1); rc=$?
  expect_code 2 "$rc" "verify --against refuses an arrival unit"
  assert_contains "$out" "tj-fetch-arrival-unit/v2" "the --against refusal names the format"
  out=$(run_pack release "$ARR/pkg-a.sqfs" "$dest/pkg-a" --accepted-by test 2>&1); rc=$?
  expect_code 2 "$rc" "release refuses an arrival unit"
  assert_contains "$out" "tj-fetch-arrival-unit/v2" "the release refusal names the format"
  assert_present "$dest/pkg-a/a.txt" "a refused release deletes nothing"
  assert_absent "$ARR/pkg-a.release.json" "a refused release writes no record"
  d=$(tamper_copy bare-v1)
  sed -i 's#  \./#  #' "$d/unit-a.members.sha256"
  out=$(run_pack verify "$d/unit-a.sqfs" 2>&1); rc=$?
  expect_code 1 "$rc" "an fm-pack-unit/v1 members list with bare paths fails verify"
  assert_contains "$out" "members line 1 is malformed" "bare paths stay arrival-only"
  pass "verify and restore read an arrival unit; --against and release refuse it"
}

test_mount_verify() {
  local probe out rc d
  probe=$(mktemp -d "$TMP_ROOT/probe.XXXXXX")
  if ! command -v squashfuse >/dev/null 2>&1 || ! command -v fusermount3 >/dev/null 2>&1 ||
    ! squashfuse -o ro "$R/unit-a.sqfs" "$probe" 2>/dev/null; then
    echo "skip: no usable squashfuse mount here; the unsquashfs path covers verify"
    return 0
  fi
  fusermount3 -u "$probe"
  out=$(FM_PACK_MOUNT='' run_pack verify "$R/unit-a.sqfs" --against "$SRC"); rc=$?
  expect_code 0 "$rc" "verify through a fresh mount passes"
  assert_contains "$out" "(6 files, mount), source unchanged" "verify names the mount path"
  d=$(tamper_copy mount-edited)
  flip_first_hash "$d/unit-a.members.sha256"
  out=$(FM_PACK_MOUNT='' run_pack verify "$d/unit-a.sqfs" 2>&1); rc=$?
  expect_code 1 "$rc" "an edited members line fails the mount verify"
  assert_equals "" "$(grep fm-pack-verify /proc/self/mounts)" "no verify mount is left behind"
  out=$(FM_PACK_MOUNT='' run_pack verify "$ARR/pkg-a.sqfs"); rc=$?
  expect_code 0 "$rc" "an arrival unit verifies through a fresh mount"
  assert_contains "$out" "(3 files, mount)" "the arrival verify names the mount path"
  pass "verify reads the image through a fresh squashfuse mount"
}

SRC_R="$TMP_ROOT/src/unit-r"
IMG_R="$R/unit-r.sqfs"
ASIDE_R="$TMP_ROOT/src/.unit-r.fm-pack-release"
OUT_R="$TMP_ROOT/outside-unit-r"
SNAP_R=''

test_release_setup() {
  local out rc
  make_src "$SRC_R"
  out=$(run_pack pack job unit-r "$SRC_R"); rc=$?
  expect_code 0 "$rc" "the release fixture packs"
  SNAP_R=$(snapshot "$SRC_R")
}

# expect_release_refused CODE WHY PATTERN ARGS...: releasing unit-r with ARGS
# exits CODE naming PATTERN and deletes nothing.
expect_release_refused() {
  local code=$1 why=$2 pattern=$3 out rc
  shift 3
  out=$(run_pack release "$IMG_R" "$SRC_R" "$@" 2>&1); rc=$?
  expect_code "$code" "$rc" "$why"
  assert_contains "$out" "$pattern" "$why: the refusal says why"
  assert_equals "$SNAP_R" "$(snapshot "$SRC_R")" "$why: the source is untouched"
  assert_present "$OUT_R" "$why: the outside name is untouched"
  assert_absent "$R/unit-r.release.json" "$why: no release record"
  assert_absent "$ASIDE_R" "$why: no aside left"
}

# wait_link LINK TARGET: wait up to 5 s until the symlink LINK reads TARGET.
wait_link() {
  local _
  for _ in $(seq 50); do
    [ "$(readlink "$1" 2>/dev/null)" = "$2" ] && return 0
    sleep 0.1
  done
  fail "$1 never pointed at $2"
}

test_release_refusals() {
  local also=(--also "$OUT_R") ok=(--accepted-by tetjet-mate --also "$OUT_R") out rc copy d pid m
  expect_release_refused 2 "a release without acceptance" "no acceptance, no release" "${also[@]}"
  expect_release_refused 2 "an acceptance that is not a name" "--accepted-by must be" --accepted-by 'two words' "${also[@]}"
  expect_release_refused 2 "a window that is not seconds" "whole seconds" "${ok[@]}" --window 7d

  copy="$TMP_ROOT/copy/unit-r"
  mkdir -p "$TMP_ROOT/copy"
  cp -a "$SRC_R" "$copy"
  out=$(run_pack release "$IMG_R" "$copy" "${ok[@]}" 2>&1); rc=$?
  expect_code 2 "$rc" "releasing a copy of the source is misuse"
  assert_contains "$out" "is not the source" "the refusal names the recorded source"
  assert_present "$copy/hl1" "the copy is untouched"

  expect_release_refused 75 "a window not yet passed" "release window of 604800 s ends at" "${ok[@]}" --window 604800
  FM_PACK_RELEASE_WINDOW=604800 expect_release_refused 75 "a configured window not yet passed" "release window of 604800 s" "${ok[@]}"
  assert_contains "$(tail -n1 "$R/fm-pack-release.log")" "waits unit-r $SRC_R" "the wait is logged"

  printf 'tree: %s\n' "$SRC_R" >"$TMP_ROOT/ledger.txt"
  expect_release_refused 1 "a ledger that still names the source" "$TMP_ROOT/ledger.txt still names $SRC_R" \
    "${ok[@]}" --ref "$TMP_ROOT/ledger.txt"
  assert_contains "$(tail -n1 "$R/fm-pack-release.log")" "refused unit-r $SRC_R" "the refusal is logged"
  expect_release_refused 2 "an unreadable reference" "is not a readable file" "${ok[@]}" --ref "$TMP_ROOT/no-ledger"

  printf '36 1 0:5 / %s rw - tmpfs tmpfs rw\n' "$SRC_R/nested" >"$TMP_ROOT/mountinfo-r"
  FM_PACK_MOUNTINFO="$TMP_ROOT/mountinfo-r" expect_release_refused 1 "a mount inside the source" \
    "$SRC_R/nested is a mount point" "${ok[@]}"

  (cd "$SRC_R/nested" && exec sleep 30) &
  pid=$!
  wait_link "/proc/$pid/cwd" "$SRC_R/nested"
  PACK_PROC_PID=$pid expect_release_refused 1 "a process working in the source" "process $pid (sleep) uses $SRC_R/nested" "${ok[@]}"
  kill "$pid"; wait "$pid" 2>/dev/null
  (exec 3<"$SRC_R/with space.txt" && exec sleep 30) &
  pid=$!
  wait_link "/proc/$pid/fd/3" "$SRC_R/with space.txt"
  PACK_PROC_PID=$pid expect_release_refused 1 "a file open in the source" "uses $SRC_R/with space.txt" "${ok[@]}"
  kill "$pid"; wait "$pid" 2>/dev/null
  (exec 3<"$OUT_R" && exec sleep 30) &
  pid=$!
  wait_link "/proc/$pid/fd/3" "$OUT_R"
  PACK_PROC_PID=$pid expect_release_refused 1 "an open --also name" "uses $OUT_R" "${ok[@]}"
  kill "$pid"; wait "$pid" 2>/dev/null

  mkdir -p "$TMP_ROOT/state/reservations" "$TMP_ROOT/state/reservations-d/999"
  printf 'bytes=1\nexpires=%s\n' $(( $(date +%s) + 3600 )) >"$TMP_ROOT/state/reservations/unit-r"
  expect_release_refused 1 "a live Linux reservation named for the unit" "reservations/unit-r is live" "${ok[@]}"
  printf 'bytes=1\nexpires=1\n' >"$TMP_ROOT/state/reservations/unit-r"
  printf 'bytes=1\npid=%s\n' "$$" >"$TMP_ROOT/state/reservations-d/999/pack-unit-r"
  expect_release_refused 1 "a live D: reservation for the unit's pack" "reservations-d/999/pack-unit-r is live" "${ok[@]}"
  rm -f "$TMP_ROOT/state/reservations-d/999/pack-unit-r"

  expect_release_refused 1 "a hard link left outside the source" \
    "$SRC_R/shared has 1 more hard-link name(s) outside $SRC_R" --accepted-by tetjet-mate
  expect_release_refused 2 "an --also that is no link of the source" "is not a link of a file in" \
    "${ok[@]}" --also "$TMP_ROOT/ledger.txt"
  expect_release_refused 2 "an --also inside the source" "is inside $SRC_R" "${ok[@]}" --also "$SRC_R/hl2"

  d="$TMP_ROOT/flipped-r"
  mkdir -p "$d"
  for f in sqfs sqfs.sha256 members.sha256 tree.tsv json; do cp "$R/unit-r.$f" "$d/unit-r.$f"; done
  printf '\377' | dd of="$d/unit-r.sqfs" bs=1 seek=$(( $(stat -c %s "$d/unit-r.sqfs") / 2 )) conv=notrunc status=none
  out=$(run_pack release "$d/unit-r.sqfs" "$SRC_R" "${ok[@]}" 2>&1); rc=$?
  expect_code 1 "$rc" "an image that fails verify refuses the release"
  assert_contains "$out" "does not match" "the refusal names the image sha256"
  assert_absent "$d/unit-r.release.json" "no release record for the failed image"
  assert_equals "$SNAP_R" "$(snapshot "$SRC_R")" "the source is untouched after a failed verify"

  m=$(find "$SRC_R/empty" -printf '%T@')
  touch -d @1 "$SRC_R/empty"
  out=$(run_pack release "$IMG_R" "$SRC_R" "${ok[@]}" 2>&1); rc=$?
  touch -d "@$m" "$SRC_R/empty"
  expect_code 1 "$rc" "a changed source refuses the release"
  assert_contains "$out" "no longer matches unit-r.tree.tsv" "the refusal names the tree list"
  assert_equals "$SNAP_R" "$(snapshot "$SRC_R")" "the source is back as it was"

  out=$(FM_PACK_TEST_BEFORE_RECHECK="touch -d @1 '$ASIDE_R/empty'" run_pack release "$IMG_R" "$SRC_R" "${ok[@]}" 2>&1); rc=$?
  expect_code 1 "$rc" "a change while renamed aside refuses the release"
  assert_contains "$out" "changed while it was renamed aside" "the refusal names the aside re-check"
  assert_present "$SRC_R/hl1" "the source is renamed back after the aside re-check"
  assert_absent "$ASIDE_R" "no aside is left after the aside re-check"
  assert_absent "$R/unit-r.release.json" "the pending record is removed after the aside re-check"
  touch -d "@$m" "$SRC_R/empty"
  assert_equals "$SNAP_R" "$(snapshot "$SRC_R")" "the renamed-back source is whole"
  pass "release refuses on every guard and deletes nothing"
}

test_release() {
  local out rc rec="$R/unit-r.release.json"
  # A genuinely absent ancestor is allowed, including a literal name with glob
  # characters and a trailing newline (not a failed metadata read).
  local PACK_RELEASE_STATE="$TMP_ROOT/uncreated[*]?"$'\n'"/nested"
  printf 'tree: %s\n' "$TMP_ROOT/src/unit-other" >"$TMP_ROOT/ledger-clean.txt"
  out=$(run_pack release "$IMG_R" "$SRC_R" --accepted-by tetjet-mate --note 'the ledger reads the image' \
    --ref "$TMP_ROOT/ledger-clean.txt" --also "$OUT_R"); rc=$?
  expect_code 0 "$rc" "release succeeds when every guard holds"
  assert_equals 1 "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" "release prints one line"
  assert_contains "$out" "fm-pack-release/v1 image=$IMG_R src=$SRC_R " "the receipt names the image and source"
  assert_equals 8015 "$(receipt_field "$out" freed)" "freed counts each inode once, the outside name included"
  assert_equals tetjet-mate "$(receipt_field "$out" accepted_by)" "the receipt names who accepted"
  assert_equals "$rec" "$(receipt_field "$out" record)" "the receipt names the record"
  assert_equals fm-pack-release/v1 "$(jq -r .format "$rec")" "record format"
  assert_equals released "$(jq -r .state "$rec")" "the record says released"
  assert_equals 8015 "$(jq -r .freed_bytes "$rec")" "the record keeps the freed bytes"
  assert_equals 6 "$(jq -r .files "$rec")" "the record keeps the file count"
  assert_equals "the ledger reads the image" "$(jq -r .note "$rec")" "the record keeps the acceptance note"
  assert_equals "$OUT_R" "$(jq -r '.also[0]' "$rec")" "the record names the released outside name"
  assert_equals 0 "$(jq -r .window_seconds "$rec")" "the default window is zero"
  assert_equals "$(receipt_field "$out" released_at)" "$(jq -r .released_at "$rec")" "record and receipt agree on released_at"
  assert_equals STORED.md "$(ls -A "$SRC_R")" "only the stub is left at the source"
  assert_contains "$(cat "$SRC_R/STORED.md")" "image: $IMG_R" "the stub names the image"
  assert_absent "$OUT_R" "the outside name is released too"
  assert_absent "$ASIDE_R" "no aside is left"
  assert_contains "$(tail -n1 "$R/fm-pack-release.log")" "released unit-r $SRC_R: freed 8015 bytes" "the release is logged"
  out=$(run_pack verify "$IMG_R"); rc=$?
  expect_code 0 "$rc" "the image still verifies after the release"
  out=$(run_pack release "$IMG_R" "$SRC_R" --accepted-by tetjet-mate 2>&1); rc=$?
  expect_code 2 "$rc" "a second release is misuse"
  assert_contains "$out" "already released" "the second release says so"
  pass "release removes a verified, accepted source and leaves a receipt, a record and a stub"
}

# Read failures are injected through executable tools, including successful
# complete output followed by ENOMEM: content equality must not mask status.
setup_read_failure_tools() {
  local t d="$TMP_ROOT/read-failure-bin" real
  mkdir -p "$d"
  for t in find stat awk sed grep unsquashfs sha256sum cut wc sort cat python3; do
    real=$(PATH="$FAKEBIN:$PATH" command -v "$t")
    printf -v "PACK_REAL_$t" '%s' "$real"
    export "PACK_REAL_$t"
  done
  cat >"$d/tool" <<'SH'
#!/usr/bin/env bash
set -u
t=${0##*/} var=PACK_REAL_${0##*/}
real=${!var} mode=${PACK_FAIL_MODE:-} fail=''
case "$t:$mode" in
  find:links-empty|find:links-partial|find:links-full)
    if [ "$1" = "$PACK_FAIL_SRC" ]; then fail=1; fi ;;
  find:tree-source) [ "$1" != . ] || [ "$PWD" != "$PACK_FAIL_SRC" ] || fail=1 ;;
  find:tree-aside) [ "$1" != . ] || [ "$PWD" != "$PACK_FAIL_ASIDE" ] || fail=1 ;;
  python3:process-source) [ "${1:-}" != - ] || [ "${2:-}" != "${FM_PACK_PROC:-}" ] || fail=1 ;;
  python3:process-aside) [ "${1:-}" != - ] || [ "${2:-}" != "${FM_PACK_PROC:-}" ] || [ ! -d "$PACK_FAIL_ASIDE" ] || fail=1 ;;
  find:reservation-list) [ "${2:-}" != "$PACK_FAIL_STATE/reservations" ] || fail=1 ;;
  find:reservation-liveness) [ "$1" != /proc ] || [ "${3:-}" != 1 ] || fail=1 ;;
  find:release-record) [ "$1" != "${PACK_FAIL_IMG%/*}" ] || fail=1 ;;
  find:release-aside) [ "$1" != "${PACK_FAIL_SRC%/*}" ] || fail=1 ;;
  stat:also) [ "${!#}" != "$PACK_FAIL_OUT" ] || fail=1 ;;
  awk:mount-source) [ "${!#}" != "$PACK_FAIL_MOUNTS" ] || fail=1 ;;
  awk:mount-aside) [ "${!#}" != "$PACK_FAIL_MOUNTS" ] || [ ! -d "$PACK_FAIL_ASIDE" ] || fail=1 ;;
  sed:reservation-pid) [ "${!#}" != "$PACK_FAIL_RES" ] || [ "${2:-}" != 's/^pid=//p' ] || fail=1 ;;
  sed:reservation-expiry) [ "${!#}" != "$PACK_FAIL_RES" ] || [ "${2:-}" != 's/^expires=//p' ] || fail=1 ;;
  sed:account-*) [ "${2:-}" != "s/^${mode#account-}\\t//p" ] || fail=1 ;;
  grep:reference) [ "${!#}" != "$PACK_FAIL_REF" ] || fail=2 ;;
  unsquashfs:image-list) [ "$1" != -no-wildcards ] || [ "${2:-}" != -lln ] || fail=1 ;;
  unsquashfs:image-cat) [ "$1" != -no-wildcards ] || [ "${2:-}" != -cat ] || fail=1 ;;
  sha256sum:member-hash) [ "$#" != 0 ] || fail=1 ;;
  cut:image-hash) fail=1 ;;
  cat:member-list-io) case "${!#}" in *.members.sha256) fail=1 ;; esac ;;
  wc:member-count) fail=1 ;;
  find:mount-count) case "$PWD" in */fm-pack-verify.*/*) fail=1 ;; esac ;;
  sort:tree-sort) [ "$PWD" != "$PACK_FAIL_SRC" ] || fail=1 ;;
esac
if [ -n "$fail" ]; then
  : >"$PACK_FAIL_HIT"
  case "$mode" in
    links-empty|reference|reservation-liveness) : ;;
    links-partial) "$real" "$@" | awk -F'\t' '$3 > 1' ;;
    *) "$real" "$@" ;;
  esac
  echo "$t: Cannot allocate memory (injected $mode)" >&2
  exit "$fail"
fi
# Simulate the manifest becoming unreadable/truncated after a successful count.
if [ "$t:$mode" = wc:member-list ]; then
  path=$(readlink /proc/self/fd/0)
  "$real" "$@" || exit
  head -n1 "$path" >"$path.short" && mv "$path.short" "$path"
  : >"$PACK_FAIL_HIT"
  exit 0
fi
exec "$real" "$@"
SH
  chmod +x "$d/tool"
  for t in find stat awk sed grep unsquashfs sha256sum cut wc sort cat python3; do ln -s tool "$d/$t"; done
  # Exercise the mount reader without a host FUSE device: only capability
  # discovery is shimmed; hashing, counting and the public release are real.
  cat >"$d/fuse-env" <<'SH'
[() {
  case "${1:-}:${2:-}" in -c:/dev/fuse|-r:/dev/fuse|-w:/dev/fuse) return 0 ;; esac
  builtin [ "$@"
}
SH
  cat >"$d/squashfuse" <<'SH'
#!/usr/bin/env bash
exec "$PACK_REAL_unsquashfs" -f -no-progress -quiet -d "${!#}" "${@: -2:1}"
SH
  cat >"$d/fusermount3" <<'SH'
#!/usr/bin/env bash
rm -rf -- "${!#}"/*
SH
  chmod +x "$d/squashfuse" "$d/fusermount3"
  # Interpose Bash's real metadata syscall, not find's directory reads. This
  # reproduces ENOMEM in [ -e/-d ] while readdir still lists the live pool.
  cat >"$d/stat-fault.c" <<'C'
#define _GNU_SOURCE
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
extern char *program_invocation_short_name;
static int fault(const char *path) {
  const char *target = getenv("PACK_STAT_FAULT"), *hit = getenv("PACK_FAIL_HIT");
  if (!target || strcmp(program_invocation_short_name, "bash")) return 0;
  size_t n = strlen(target);
  if (strncmp(path, target, n) || (path[n] && path[n] != '/')) return 0;
  if (hit) { int fd = open(hit, O_CREAT | O_WRONLY | O_APPEND, 0600); if (fd >= 0) close(fd); }
  errno = ENOMEM;
  return 1;
}
int stat(const char *path, struct stat *buf) {
  if (fault(path)) return -1;
  int (*real)(const char *, struct stat *) = dlsym(RTLD_NEXT, "stat");
  return real(path, buf);
}
int stat64(const char *path, struct stat64 *buf) {
  if (fault(path)) return -1;
  int (*real)(const char *, struct stat64 *) = dlsym(RTLD_NEXT, "stat64");
  return real(path, buf);
}
C
  gcc -shared -fPIC -Wall -Wextra -Werror -o "$d/stat-fault.so" "$d/stat-fault.c" -ldl ||
    fail "cannot build the reservation metadata fault fixture"
}

# One regression oracle, reused against the real command and one fail-open
# mutant per repaired guard. Mutants change control flow, never the oracle.
read_failure_case() (
  local mode=$1 exe=$3 unit="read-$1-$2" out rc snap diag mount=unsquashfs
  local also=() preload='' PACK_STAT_FAULT='' PACK_RELEASE_STATE="$TMP_ROOT/state"
  local src="$TMP_ROOT/src/$unit" outside="$TMP_ROOT/outside-$unit" image="$R/$unit.sqfs"
  make_src "$src"
  out=$(run_pack pack job "$unit" "$src" 2>&1); rc=$?
  expect_code 0 "$rc" "$mode fixture packs: $out"
  snap=$(snapshot "$src")
  export PACK_FAIL_MODE=$mode PACK_FAIL_SRC=$src PACK_FAIL_OUT=$outside PACK_FAIL_IMG=$image
  export PACK_FAIL_ASIDE="$TMP_ROOT/src/.$unit.fm-pack-release" PACK_FAIL_STATE="$TMP_ROOT/state"
  export PACK_FAIL_RES="$TMP_ROOT/state/reservations/$unit" PACK_FAIL_REF="$TMP_ROOT/$unit.ref"
  export PACK_FAIL_MOUNTS="$TMP_ROOT/$unit.mounts" PACK_FAIL_HIT="$TMP_ROOT/$unit.hit"
  mkdir -p "$PACK_FAIL_STATE/reservations"
  printf 'bytes=1\nexpires=1\n' >"$PACK_FAIL_RES"
  [ "$mode" != reservation-liveness ] || printf 'bytes=1\npid=%s\n' "$$" >"$PACK_FAIL_RES"
  case "$mode" in
    reservation-metadata-linux) PACK_STAT_FAULT="$PACK_FAIL_STATE/reservations" ;;
    reservation-metadata-d)
      PACK_STAT_FAULT="$PACK_FAIL_STATE/reservations-d"
      PACK_FAIL_RES="$PACK_STAT_FAULT/999/$unit"
      mkdir -p "${PACK_FAIL_RES%/*}" ;;
    reservation-metadata-ancestor)
      PACK_RELEASE_STATE="$PACK_FAIL_STATE/ancestor"
      PACK_STAT_FAULT=$PACK_RELEASE_STATE
      PACK_FAIL_RES="$PACK_RELEASE_STATE/reservations/$unit"
      mkdir -p "${PACK_FAIL_RES%/*}" ;;
  esac
  if [ -n "$PACK_STAT_FAULT" ]; then
    printf 'bytes=1\nexpires=9999999999\n' >"$PACK_FAIL_RES"
    # The identical public command, without the fault, must see the live record.
    out=$(run_pack release "$image" "$src" --accepted-by test --also "$outside" 2>&1); rc=$?
    expect_code 1 "$rc" "$mode live reservation control refuses"
    assert_contains "$out" "$PACK_FAIL_RES is live" "$mode control reads the live reservation"
    preload="$TMP_ROOT/read-failure-bin/stat-fault.so"
  fi
  printf 'no source reference here\n' >"$PACK_FAIL_REF"
  : >"$PACK_FAIL_MOUNTS"
  case "$mode" in
    links-*) diag=link-census-read-failed ;;
    also) diag=link-census-read-failed ;;
    account-*) diag=link-accounting-read-failed ;;
    release-*) diag=release-state-read-failed ;;
    tree-*) diag='tree-read-failed' ;;
    mount-source|mount-aside) diag='mount-table-read-failed' ;;
    process-*) diag=process-scan-read-failed ;;
    reservation-*) diag=reservation-read-failed ;;
    reference) diag=reference-read-failed ;;
    image-list|member-count|mount-count) diag=member-count-read-failed ;;
    image-cat|member-hash) diag=member-read-failed ;;
    image-hash) diag='image-hash-read-failed' ;;
    member-list|member-list-io) diag=member-list-read-failed ;;
    *) fail "unknown failure case $mode" ;;
  esac
  [ "$mode" != mount-count ] || mount=mount
  [ "$mode" = links-empty ] || also=(--also "$outside")
  local PACK_EXEC=$exe
  # run_pack prepends FAKEBIN, so put the fault shims there only for this call.
  # The delegates retain the normal fake df/stat and controlled /proc world.
  local oldbin=$FAKEBIN
  FAKEBIN="$TMP_ROOT/read-failure-bin"
  out=$(LD_PRELOAD="$preload" PACK_STAT_FAULT="$PACK_STAT_FAULT" \
    BASH_ENV="$FAKEBIN/fuse-env" FM_PACK_MOUNT=$mount PATH="$oldbin:$PATH" \
    FM_PACK_MOUNTINFO="$PACK_FAIL_MOUNTS" run_pack release "$image" "$src" --accepted-by test \
    "${also[@]}" --ref "$PACK_FAIL_REF" 2>&1); rc=$?
  FAKEBIN=$oldbin
  assert_present "$PACK_FAIL_HIT" "$mode injected the intended read failure: $out"
  expect_code 1 "$rc" "$mode read error refuses"
  assert_contains "$out" "$diag" "$mode names the failed guard"
  assert_equals "$snap" "$(snapshot "$src")" "$mode keeps the entire source"
  assert_present "$outside" "$mode keeps the outside link"
  assert_absent "$R/$unit.release.json" "$mode writes no released receipt (nor pending record)"
  assert_absent "$PACK_FAIL_ASIDE" "$mode restores the original source name"
  assert_contains "$(tail -n1 "$R/fm-pack-release.log")" 'nothing deleted' "$mode logs the refusal"
  pass "read failure $mode refuses with intact source and no receipt"
)

# Mutation generation is fixture construction, not a source-text assertion:
# only the public-command regression's exit status decides whether it is killed.
make_read_mutant() {
  local mode=$1 dest=$2
  cp "$ROOT/bin/fm-pack-retry.c" "${dest%/*}/" || return 1
  python3 - "$PACK" "$mode" "$dest" <<'PY'
import pathlib, sys
source, mode, dest = sys.argv[1:]
text = pathlib.Path(source).read_text()
if mode.startswith('links-'):
    # Revert the producer guard, so --also metadata still reaches awk after
    # find fails. Masking only the caller would skip that metadata and let
    # the independent outside-hard-link guard refuse instead of releasing.
    old = '''find "$src" -xdev -type f -printf 'i\\t%D:%i\\t%n\\t%s\\t%p\\n' || return 1'''
    new = old.removesuffix(' || return 1') + '; :'
elif mode == 'also':
    old, new = 'out=$(links "$src" "${names[@]}")', 'out=$(links "$src" "${names[@]}"; :)'
elif mode in ('tree-source', 'tree-aside', 'tree-sort'):
    old, new = 'if tree_list "$1" >"$tmp"; then', 'if tree_list "$1" >"$tmp"; true; then'
elif mode.startswith('mount-') and mode != 'mount-count':
    old, new = 'out=$(mounts_in "$p")', 'out=$(mounts_in "$p"; :)'
elif mode.startswith('process-'):
    old, new = 'out=$(procs_in "$@")', 'out=$(procs_in "$@"; :)'
elif mode == 'release-record':
    old = 'out=$(find "$IDIR" -mindepth 1 -maxdepth 1 -name "$IUNIT.release.json" -print)'
    new = old[:-1] + '; :)'
elif mode == 'release-aside':
    old = 'out=$(find "$(dirname -- "$src")" -mindepth 1 -maxdepth 1 -name ".${src##*/}.fm-pack-release" -print)'
    new = old[:-1] + '; :)'
elif mode.startswith('account-'):
    field = mode.removeprefix('account-')
    var = field if field in ('files', 'freed') else 'a'
    old = var + '''=$(printf '%s\\n' "$out" | sed -n 's/^''' + field + '''\\t//p')'''
    new = old[:-1] + '; :)'
elif mode == 'reservation-liveness':
    old = 'live=$(find /proc -mindepth 1 -maxdepth 1 -type d -name "$pid" -print)'
    new = old[:-1] + '; :)'
elif mode.startswith('reservation-metadata-'):
    start = text.index('reservation_directory() {')
    end = text.index('# reservations_named NAME...', start)
    old = text[start:end]
    # Restore the reviewed fail-open branch: a failed stat plus successful
    # parent readdir was accepted as absence, without checking the child name.
    new = '''reservation_listing() {
  local d=$1 parent
  [ ! -L "$d" ] || return 1
  if [ ! -e "$d" ]; then
    parent=$(dirname -- "$d") || return 1
    [ "$parent" != "$d" ] || return 1
    reservation_listing "$parent" 0 >/dev/null || return 1
    if [ -d "$parent" ]; then find "$parent" -mindepth 1 -maxdepth 1 -print >/dev/null || return 1; fi
    return 0
  fi
  [ -d "$d" ] && [ -r "$d" ] && [ -x "$d" ] || return 1
  find -L "$d" -mindepth 1 -maxdepth "$2" -print
}

'''
elif mode == 'reservation-list':
    old = 'listing=$(reservation_listing "$dir/reservations" 1 && reservation_listing "$dir/reservations-d" 2)'
    new = old[:-1] + '; :)'
elif mode in ('reservation-pid', 'reservation-expiry'):
    old = '''pid=$(sed -n 's/^pid=//p' "$f") && expires=$(sed -n 's/^expires=//p' "$f") || return 1'''
    new = '''pid=$(sed -n 's/^pid=//p' "$f"); expires=$(sed -n 's/^expires=//p' "$f"); :'''
elif mode == 'reference':
    old, new = '*) rel_refuse 1 "reference-read-failed: $2" ;;', '*) return 0 ;;'
elif mode == 'image-list':
    old = '''count=$(unsquashfs -no-wildcards -lln "$img" "$dir" | awk '/^-/ {n++} END {print n+0}')'''
    new = old[:-1] + '; :)'
elif mode in ('image-cat', 'member-hash'):
    old = 'got=$(unsquashfs -no-wildcards -cat "$img" "$dir/$path" | sha256sum)'
    new = old[:-1] + '; :)'
elif mode == 'member-count':
    old, new = 'expected=$(wc -l <"$members")', 'expected=$(wc -l <"$members"; :)'
elif mode == 'image-hash':
    old = '''REL_IMAGE_SHA=$(cut -d' ' -f1 <"$IDIR/$IUNIT.sqfs.sha256")'''
    new = old[:-1] + '; :)'
elif mode == 'member-list-io':
    old, new = 'manifest=$(cat -- "$members")', 'manifest=$(cat -- "$members"; :)'
elif mode == 'member-list':
    old = '[ "$n" -eq "$expected" ] || { note "member-list-read-failed: $members"; return 1; }'
    new = ':'
elif mode == 'mount-count':
    old = 'count=$(cd "$MNT/$dir" && find . -type f -printf \'.\\n\' | wc -l)'
    new = old[:-1] + '; :)'
else:
    raise SystemExit('unknown mutant: ' + mode)
# A no-op mutation will survive and fail the behavior-based kill check below.
pathlib.Path(dest).write_text(text.replace(old, new))
PY
}

test_release_read_failures() {
  local mode mutant log errors=''
  setup_read_failure_tools
  for mode in links-empty links-partial links-full also account-bad account-out account-files account-freed \
    tree-source tree-aside tree-sort release-record release-aside mount-source mount-aside \
    process-source process-aside reservation-list reservation-pid reservation-expiry reservation-liveness \
    reservation-metadata-linux reservation-metadata-d reservation-metadata-ancestor \
    reference image-list image-cat member-hash member-count image-hash member-list member-list-io mount-count; do
    read_failure_case "$mode" baseline "$PACK" || errors+="$mode baseline; "
    mutant="$TMP_ROOT/mutant-$mode.sh" log="$TMP_ROOT/mutant-$mode.log"
    if ! make_read_mutant "$mode" "$mutant"; then
      errors+="$mode mutant generation; "
      continue
    fi
    if read_failure_case "$mode" mutant "$mutant" >"$log" 2>&1; then
      errors+="$mode mutant survived; "
    # Require actual unsafe success, not a fixture/setup error or another refusal.
    elif ! grep -F "$mode read error refuses: expected exit 1, got 0" "$log" >/dev/null; then
      cat "$log"
      errors+="$mode mutant did not reach unsafe release; "
    else
      pass "mutant killed: $mode"
    fi
  done
  [ -z "$errors" ] || fail "read-failure regressions: $errors"
}

# cand_row OUT TREE: the candidates row for TREE.
cand_row() { printf '%s\n' "$1" | awk -F'\t' -v t="$2" '$9 == t'; }

# hand_row TREE BUCKET DAYS SMALL_PCT PACK: the row a hand du and find give.
hand_row() {
  local newest
  newest=$(find "$1" -xdev -printf '%T@\n' | sort -n | tail -n 1)
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$2" "$3" "$(du -sB1 -x "$1" | cut -f1)" \
    "$(find "$1" -xdev -type f -printf '%i %s\n' | sort -u | awk '{ n += $2 } END { printf "%.0f", n }')" \
    "$(find "$1" -xdev -type f | wc -l | tr -d ' ')" "$4" "$(date -u -d "@${newest%.*}" +%Y-%m-%dT%H:%M:%SZ)" "$5" "$1"
}

# The candidates home: a 30-day tree per pack state, a 7-day tree, a young
# tree, a symlinked tree and a plain file, behind a clock 100 days ahead.
test_candidates() {
  local h d now out rc before after t
  h="$(cd -P -- "$TMP_ROOT" && pwd -P)/cand-home" d="$h/data"
  mkdir -p "$d/old/sub" "$d/packed" "$d/changed" "$d/gone" "$d/pending" "$d/week" "$d/young" "$d/.dot" \
    "$MP/lattice-data/research"
  publish_d
  printf '%010d' 0 >"$d/old/a"; head -c 70000 /dev/zero >"$d/old/sub/big"; printf 'x' >"$d/old/sub/b"
  ln "$d/old/sub/b" "$d/old/b2"; ln -s sub/big "$d/old/to-big"
  for t in packed changed gone pending; do printf '%s' "$t" >"$d/$t/f"; done
  printf 'w' >"$d/week/f"; printf 'y' >"$d/young/f"; printf 'z' >"$d/.dot/f"
  ln -s old "$d/link"; printf 'p' >"$d/plain"
  now=$(( $(date +%s) + 100 * 86400 ))
  find "$d/week" -exec touch -h -d "@$((now - 10 * 86400))" {} +
  find "$d/young" -exec touch -h -d "@$((now - 86400))" {} +
  for t in packed changed gone pending; do
    out=$(run_pack pack cand "unit-$t" "$d/$t"); rc=$?
    expect_code 0 "$rc" "the $t candidate packs"
  done
  out=$(run_pack release "$MP/lattice-data/tetjet-results/cand/unit-gone.sqfs" "$d/gone" --accepted-by tester); rc=$?
  expect_code 0 "$rc" "the gone candidate is released"
  printf '{"format":"fm-pack-release/v1","state":"releasing"}\n' >"$MP/lattice-data/tetjet-results/cand/unit-pending.release.json"
  printf 'more' >"$d/changed/g"
  touch -d "@$((now - 40 * 86400))" "$d/changed/g"
  before=$(snapshot "$h"; snapshot "$MP")

  out=$(FM_PACK_NOW=$now run_pack candidates --home "$h"); rc=$?
  expect_code 0 "$rc" "candidates lists a readable home"
  after=$(snapshot "$h"; snapshot "$MP")
  assert_equals "$before" "$after" "candidates changes nothing in the home or on D:"
  assert_equals "fm-pack-candidates/v1 home=$h now=$now small=65536 listed=7 recent=1 skipped=1 failed=0" \
    "$(printf '%s\n' "$out" | sed -n 1p)" "the header counts listed, recent and skipped trees"
  assert_equals "$(printf 'bucket\tdays\tallocated\tlogical\tfiles\tsmall_pct\tnewest\tpack\ttree')" \
    "$(printf '%s\n' "$out" | sed -n 2p)" "the column line"
  assert_equals "$(hand_row "$d/old" 30d+ 100 75.0 none)" "$(cand_row "$out" "$d/old")" \
    "an unpacked tree matches a hand du and find, each inode once, symlink not followed"
  assert_equals "$(hand_row "$d/packed" 30d+ 100 100.0 verified)" "$(cand_row "$out" "$d/packed")" "a packed, unchanged tree is verified"
  assert_equals changed "$(cand_row "$out" "$d/changed" | cut -f8)" "a tree changed after its pack says changed"
  assert_equals released "$(cand_row "$out" "$d/gone" | cut -f8)" "a released tree says released"
  assert_equals releasing "$(cand_row "$out" "$d/pending" | cut -f8)" "an unfinished release says releasing"
  assert_equals "$(hand_row "$d/week" 7d+ 10 100.0 none)" "$(cand_row "$out" "$d/week")" "a tree quiet for 10 days is in the 7-day bucket"
  assert_equals "$d/.dot" "$(cand_row "$out" "$d/.dot" | cut -f9)" "a dot tree is listed"
  assert_equals "" "$(cand_row "$out" "$d/young")" "a tree touched a day ago is not listed"
  assert_equals "" "$(cand_row "$out" "$d/link")" "a symlinked tree is not walked"
  assert_equals "30d+ 30d+ 30d+ 30d+ 30d+ 30d+ 7d+" "$(printf '%s\n' "$out" | sed -n '3,$p' | cut -f1 | tr '\n' ' ' | sed 's/ $//')" \
    "30-day trees come before 7-day trees"
  assert_equals "$d/old" "$(printf '%s\n' "$out" | sed -n 3p | cut -f9)" "the largest tree comes first"

  out=$(FM_PACK_NOW=$now run_pack candidates --home "$h" --small 1 --root tetjet-results); rc=$?
  expect_code 0 "$rc" "one named root reads"
  assert_equals 0.0 "$(cand_row "$out" "$d/old" | cut -f6)" "--small sets the small-file size"

  out=$(FM_PACK_NOW=$now PACK_FIND_HANG="$d/old" PACK_FIND_FAIL="$d/week" run_pack candidates --home "$h" --timeout 3 2>"$TMP_ROOT/cand.err"); rc=$?
  expect_code 1 "$rc" "a failed or timed-out walk exits 1"
  assert_equals "$(printf 'failed\t-\t-\t-\t-\t-\t-\ttimeout\t%s' "$d/old")" "$(cand_row "$out" "$d/old")" "a timed-out walk is a failed row"
  assert_equals "$(printf 'failed\t-\t-\t-\t-\t-\t-\tread-error\t%s' "$d/week")" "$(cand_row "$out" "$d/week")" "a failed walk is a failed row"
  assert_contains "$(cat "$TMP_ROOT/cand.err")" "walking $d/week failed (read-error): find: '$d/week/held': Permission denied" "stderr names the failed walk"
  assert_equals verified "$(cand_row "$out" "$d/packed" | cut -f8)" "the other trees are still listed"
  assert_contains "$(printf '%s\n' "$out" | sed -n 1p)" " failed=2" "the header counts failed walks"

  mkdir -p "$MP/lattice-data/research/odd"
  printf 'x' >"$MP/lattice-data/research/odd/bad.sqfs"; printf 'not json' >"$MP/lattice-data/research/odd/bad.json"
  out=$(FM_PACK_NOW=$now run_pack candidates --home "$h" 2>"$TMP_ROOT/cand.err"); rc=$?
  expect_code 1 "$rc" "an unreadable sidecar exits 1"
  assert_equals unknown "$(cand_row "$out" "$d/old" | cut -f8)" "an unreadable sidecar leaves an unpacked tree unknown, not none"
  assert_equals verified "$(cand_row "$out" "$d/packed" | cut -f8)" "a tree with a readable pack is still verified"
  assert_contains "$(cat "$TMP_ROOT/cand.err")" "unreadable sidecar $MP/lattice-data/research/odd/bad.json" "stderr names the sidecar"
  rm -rf -- "$MP/lattice-data/research/odd"

  out=$(FM_PACK_NOW=$now FM_STORAGE_RESULTS_ROOT="$TMP_ROOT/no-publication" run_pack candidates --home "$h" 2>"$TMP_ROOT/cand.err"); rc=$?
  expect_code 75 "$rc" "an unpublished D: is a wait"
  assert_equals unknown "$(cand_row "$out" "$d/packed" | cut -f8)" "pack state is unknown while D: waits"
  assert_contains "$(cat "$TMP_ROOT/cand.err")" "wait: missing-publication" "the wait reason is on stderr"
  assert_equals "$(hand_row "$d/old" 30d+ 100 75.0 unknown)" "$(cand_row "$out" "$d/old")" "the walk still reports while D: waits"

  out=$(FM_PACK_NOW=$now run_pack candidates --home "$TMP_ROOT/src"); rc=$?
  expect_code 0 "$rc" "a home without data/ lists nothing"
  assert_contains "$out" " listed=0 recent=0 skipped=0 failed=0" "nothing is listed"
  for t in "" "--home" "--home $TMP_ROOT/missing" "--home $h --timeout 0" "--home $h --small 1.5K" \
    "--home $h --small 0" "--home $h --root other" "--home $h extra"; do
    # shellcheck disable=SC2086 # each case is a word list
    out=$(run_pack candidates $t 2>&1); rc=$?
    expect_code 2 "$rc" "candidates misuse: '$t'"
  done
  pass "candidates lists cold data/ trees with sizes a hand du and find match, and each pack state"
}

# scan_world NAME: an empty process table for one process-scan case.
scan_world() {
  local w="$TMP_ROOT/scan-world/$1"
  mkdir -p "$w" && printf '%s\n' "$w"
}

# scan_entry WORLD PID CWD STATE: a fake process entry owned by this user, with
# a cwd link, a stat line in STATE and an empty fd directory.
scan_entry() {
  mkdir -p "$1/$2/fd"
  [ -z "$3" ] || ln -s "$3" "$1/$2/cwd"
  printf '%s (fake) %s 1 1 1 0 -1\n' "$2" "$4" >"$1/$2/stat"
}

# process_scan_cases TAG EXE: the process-scan regressions against EXE, fail-fast
# so a mutant is killed by the first case it breaks. Each releasing case packs
# its own unit; the refusing cases share one and must leave it whole.
process_scan_cases() (
  local tag=$1 PACK_EXEC=$2 w src out rc snap unit
  scan_unit() {
    unit="scan-$tag-$1" src="$TMP_ROOT/src/scan-$tag-$1"
    make_src "$src"
    out=$(PACK_EXEC='' run_pack pack job "$unit" "$src" 2>&1); rc=$?
    expect_code 0 "$rc" "process-scan fixture $unit packs: $out"
    snap=$(snapshot "$src")
  }
  scan_release() {
    out=$(PACK_PROC_ROOT=$1 run_pack release "$R/$unit.sqfs" "$src" --accepted-by test \
      --also "$TMP_ROOT/outside-$unit" 2>&1); rc=$?
  }
  expect_scan_released() {
    scan_release "$1"
    expect_code 0 "$rc" "$2"
    assert_equals STORED.md "$(ls -A "$src")" "$2: only the stub is left: $out"
  }
  expect_scan_refused() {
    scan_release "$1"
    expect_code 1 "$rc" "$2"
    assert_contains "$out" "$3" "$2: the refusal says why"
    assert_equals "$snap" "$(snapshot "$src")" "$2: the source is untouched"
    assert_present "$TMP_ROOT/outside-$unit" "$2: the outside name is untouched"
    assert_absent "$R/$unit.release.json" "$2: no release record"
  }

  # Hidden processes: the kernel denies ptrace-read access with EACCES. A
  # directory without search permission gives that errno on the cwd read, and
  # one that lists but cannot be searched gives it on each fd read after a
  # readable cwd (an own process holding capabilities this caller lacks). The
  # host's pid 1 is another user's when this user cannot read its cwd.
  w=$(scan_world "hidden-$tag")
  mkdir -p "$w/4000000" && chmod 000 "$w/4000000"
  scan_entry "$w" 4000001 "$TMP_ROOT" S
  : >"$w/4000001/fd/3" && chmod 0400 "$w/4000001/fd"
  ln -s "/proc/$$" "$w/$$"
  if ! readlink /proc/1/cwd >/dev/null 2>&1 && [ -d /proc/1 ]; then ln -s /proc/1 "$w/1"; fi
  ! readlink "$w/4000000/cwd" >/dev/null 2>&1 || fail "a search-denied process entry is readable"
  ! readlink "$w/4000001/fd/3" >/dev/null 2>&1 || fail "a search-denied fd entry is readable"
  scan_unit hidden
  expect_scan_released "$w" "hidden processes do not block the release"

  # Exited processes: a listed pid whose entry is gone, and a zombie with no cwd.
  w=$(scan_world "exited-$tag")
  ln -s "$w/no-such-entry" "$w/4000002"
  scan_entry "$w" 4000003 '' Z
  scan_unit exited
  expect_scan_released "$w" "exited processes do not block the release"

  scan_unit refused
  w=$(scan_world "partial-$tag")
  scan_entry "$w" 4000004 "$src/nested" S
  : >"$w/4000004/fd/3" && chmod 0400 "$w/4000004/fd"
  expect_scan_refused "$w" "a hidden process's cwd read before the denial still refuses" "uses $src/nested"

  w=$(scan_world "own-error-$tag")
  scan_entry "$w" 4000005 "$TMP_ROOT" S
  rmdir "$w/4000005/fd" && : >"$w/4000005/fd"
  expect_scan_refused "$w" "another read error on an own process refuses" "process-scan-read-failed"

  w=$(scan_world "own-missing-$tag")
  scan_entry "$w" 4000006 "$TMP_ROOT" S
  rmdir "$w/4000006/fd"
  expect_scan_refused "$w" "an own live process with a missing entry refuses" "process-scan-read-failed"

  w=$(scan_world "unreadable-$tag")
  chmod 000 "$w"
  expect_scan_refused "$w" "an unreadable process table refuses" "process-scan-read-failed"
  chmod 755 "$w"

  expect_scan_refused "$TMP_ROOT/scan-world/missing-$tag" "a missing process table refuses" "process-scan-read-failed"

  w=$(scan_world "empty-$tag")
  out=$(PATH="$TMP_ROOT/scan-bin:$PATH" PACK_PROC_ROOT=$w run_pack release "$R/$unit.sqfs" "$src" \
    --accepted-by test --also "$TMP_ROOT/outside-$unit" 2>&1); rc=$?
  expect_code 1 "$rc" "a process scanner that cannot start refuses"
  assert_contains "$out" "process-scan-read-failed" "a process scanner that cannot start: the refusal says why"
  assert_equals "$snap" "$(snapshot "$src")" "a process scanner that cannot start: the source is untouched"
  assert_absent "$R/$unit.release.json" "a process scanner that cannot start: no release record"
  pass "process scan ($tag): hidden and exited processes pass; every other scan failure refuses"
)

# make_scan_mutant MODE DEST: fm-pack with one process-scan rule reverted.
make_scan_mutant() {
  python3 - "$PACK" "$1" "$2" <<'PY'
import pathlib, sys
source, mode, dest = sys.argv[1:]
text = pathlib.Path(source).read_text()
denied = 'if e.errno == errno.EACCES:\n                    break'
if mode == 'old-find':
    # The scan before this fix, reading the fixture's process table: any find
    # error, permission denials included, fails the scan.
    start = text.index('procs_in() {')
    end = text.index('\nPY\n}\n', start) + len('\nPY\n}\n')
    old = text[start:end]
    new = r'''procs_in() {
  local p=$1 r=${FM_PACK_PROC:-/proc}; shift
  find "$r" -mindepth 2 -maxdepth 3 \( -path "$r/[0-9]*/cwd" -o -path "$r/[0-9]*/fd/*" \) \
    -printf '%p\t%l\n' 2>/dev/null |
    awk -F'\t' -v r="$r" -v p="$p" -v names="$(printf '%s\n' "$@")" '
      BEGIN { n = split(names, a, "\n"); for (i = 1; i <= n; i++) if (a[i] != "") x[a[i]] = 1 }
      { t = $2; sub(/ \(deleted\)$/, "", t)
        if (t == p || index(t, p "/") == 1 || (t in x)) { split(substr($1, length(r) + 2), q, "/"); print q[1] "\t" t } }' |
    LC_ALL=C sort -u
}
'''
elif mode == 'denied-fails':
    old, new = denied, 'if False:\n                    break'
elif mode == 'denied-drops-reads':
    old, new = denied, 'if e.errno == errno.EACCES:\n                    targets = []\n                    break'
elif mode == 'errors-hidden':
    old = 'if e.errno != errno.ENOENT:\n                    raise'
    new = 'if e.errno != errno.ENOENT:\n                    break'
elif mode == 'exited-fails':
    old, new = 'if gone(d) or zombie(d):', 'if False:'
elif mode == 'missing-skipped':
    old, new = 'if gone(d) or zombie(d):', 'if True:'
elif mode == 'table-skipped':
    old = 'for pid in os.listdir(root):'
    new = 'for pid in (os.listdir(root) if os.access(root, os.R_OK) else []):'
elif mode == 'scan-ignored':
    old, new = 'out=$(procs_in "$@")', 'out=$(procs_in "$@"; :)'
else:
    raise SystemExit('unknown mutant: ' + mode)
if old not in text:
    raise SystemExit('mutant site not found: ' + mode)
pathlib.Path(dest).write_text(text.replace(old, new))
PY
}

test_release_process_scan() {
  local mode why mutant log errors=''
  if [ "$(id -u)" = 0 ]; then
    pass "release process scan: hidden processes pass, other scan failures refuse (skipped as root, which reads every process)"
    return 0
  fi
  mkdir -p "$TMP_ROOT/scan-bin"
  PACK_REAL_PYTHON3=$(command -v python3)
  export PACK_REAL_PYTHON3
  cat >"$TMP_ROOT/scan-bin/python3" <<'SH'
#!/usr/bin/env bash
# The process scanner cannot start; every other python3 run is real.
if [ "${1:-}" = - ] && [ "${2:-}" = "${FM_PACK_PROC:-}" ]; then
  echo "python3: cannot execute: Exec format error (injected)" >&2
  exit 126
fi
exec "$PACK_REAL_PYTHON3" "$@"
SH
  chmod +x "$TMP_ROOT/scan-bin/python3"
  process_scan_cases baseline "$PACK" || errors+="baseline; "
  # MODE|the case it must break, with the exit that case then sees. The list is
  # read on fd 3, so nothing a case runs can consume it.
  while IFS='|' read -r mode why <&3; do
    mutant="$TMP_ROOT/scan-mutant-$mode.sh" log="$TMP_ROOT/scan-mutant-$mode.log"
    if ! make_scan_mutant "$mode" "$mutant"; then
      errors+="$mode mutant generation; "
    elif process_scan_cases "$mode" "$mutant" >"$log" 2>&1; then
      errors+="$mode mutant survived; "
    elif ! grep -F "$why" "$log" >/dev/null; then
      cat "$log"
      errors+="$mode mutant failed elsewhere; "
    else
      pass "process-scan mutant killed: $mode"
    fi
  done 3<<'MUTANTS'
old-find|hidden processes do not block the release: expected exit 0, got 1
denied-fails|hidden processes do not block the release: expected exit 0, got 1
denied-drops-reads|a hidden process's cwd read before the denial still refuses: expected exit 1, got 0
errors-hidden|another read error on an own process refuses: expected exit 1, got 0
exited-fails|exited processes do not block the release: expected exit 0, got 1
missing-skipped|an own live process with a missing entry refuses: expected exit 1, got 0
table-skipped|an unreadable process table refuses: expected exit 1, got 0
scan-ignored|another read error on an own process refuses: expected exit 1, got 0
MUTANTS
  [ -z "$errors" ] || fail "process-scan regressions: $errors"
}

test_no_publication_waits
test_pack_round_trip
test_machine_share
test_slot_waits
test_slot_wait_is_bounded
test_stop_finishes_the_commit
test_stop_ends_a_running_step
test_against_changed_source
test_source_change_refuses
test_tampering_fails_verify
test_repack_refuses
test_reader_mode_refuses
test_root_overlap_refuses
test_restore
test_unit_format
test_arrival_unit
test_mount_verify
test_release_setup
test_release_refusals
test_release_read_failures
test_release_process_scan
test_release
test_candidates
