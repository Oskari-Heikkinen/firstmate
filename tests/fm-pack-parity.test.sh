#!/usr/bin/env bash
# shellcheck disable=SC2016
# Behavior tests for bin/fm-pack.sh verify-tar, the G5-equivalent tar/image
# parity check that bin/fm-pack-parity.py implements.
#
# Every case builds its tars, images and expectations in a fixture root and
# runs the public command from a copy of bin/ whose fm-storage.sh is a fake
# that logs its arguments and answers health --volume d as the case says, so
# nothing reads a real drive, reservation or publication. Images are read
# through FM_PACK_MOUNT=unsquashfs; the squashfuse path runs only where FUSE
# can actually mount, and is skipped elsewhere.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

for tool in python3 mksquashfs unsquashfs sha256sum; do
  command -v "$tool" >/dev/null 2>&1 || { echo "skip: $tool is not installed"; exit 0; }
done

T=$(fm_test_tmproot fm-pack-parity) || fail "cannot create the fixture root"
FX=$T/fx.py
mkdir -p "$T/tmp" "$T/w"

# Fixture builder: tars through Python's tarfile, byte edits that keep a
# header's checksum valid, and expectations computed from content files.
cat >"$FX" <<'PY'
import hashlib, json, os, sys, tarfile

MTIME = 1700000000


def sha(path):
    with open(path, "rb") as f:
        return hashlib.sha256(f.read()).hexdigest()


def headers(data):
    """Offsets of every header block, metadata headers included."""
    out, pos = [], 0
    while pos + 512 <= len(data) and data[pos:pos + 512] != bytes(512):
        out.append(pos)
        size = int(data[pos + 124:pos + 136].rstrip(b"\0 ") or b"0", 8)
        pos += 512 + (size + 511) // 512 * 512
    return out


def checksum(block):
    block[148:156] = b"        "
    block[148:156] = b"%06o\0 " % sum(block)


FIELDS = {"name": (0, 100), "mtime": (136, 148), "type": (156, 157), "magic": (257, 265), "size": (124, 136)}


def cmd_tar(out, fmt, *specs):
    form = {"gnu": tarfile.GNU_FORMAT, "pax": tarfile.PAX_FORMAT}[fmt]
    with tarfile.open(out, "w", format=form) as tf:
        for spec in specs:
            kind, _, rest = spec.partition(":")
            name, _, arg = rest.partition("=")
            ti = tarfile.TarInfo(name)
            ti.mtime, ti.mode, ti.uname, ti.gname = MTIME, 0o644, "root", "root"
            if kind == "f":
                ti.size = os.path.getsize(arg)
                with open(arg, "rb") as f:
                    tf.addfile(ti, f)
                continue
            if kind == "d":
                ti.type, ti.mode = tarfile.DIRTYPE, 0o755
            elif kind == "s":
                ti.type, ti.linkname = tarfile.SYMTYPE, arg
            elif kind == "h":
                ti.type, ti.linkname = tarfile.LNKTYPE, arg
            elif kind == "x":
                # x:NAME=KEY=VALUE writes NAME with that PAX record and no data.
                key, _, value = arg.partition("=")
                ti.pax_headers = {key: value}
            tf.addfile(ti)


def cmd_globalpax(out, path):
    with tarfile.open(out, "w", format=tarfile.PAX_FORMAT, pax_headers={"comment": "x"}) as tf:
        ti = tarfile.TarInfo(os.path.basename(path))
        ti.size, ti.mtime = os.path.getsize(path), MTIME
        with open(path, "rb") as f:
            tf.addfile(ti, f)


def cmd_header(path, index, field, value):
    data = bytearray(open(path, "rb").read())
    pos = headers(data)[int(index)]
    block = data[pos:pos + 512]
    lo, hi = FIELDS[field]
    raw = value.encode("utf-8").decode("unicode_escape").encode("latin-1")
    block[lo:hi] = raw.ljust(hi - lo, b"\0")[:hi - lo]
    checksum(block)
    data[pos:pos + 512] = block
    open(path, "wb").write(data)


def cmd_bytes(path, op, *args):
    data = bytearray(open(path, "rb").read())
    if op == "append":
        data += args[0].encode("utf-8").decode("unicode_escape").encode("latin-1")
    elif op == "append-zero":
        data += bytes(int(args[0]))
    elif op == "append-file":
        data += open(args[0], "rb").read()
    elif op == "cut":
        del data[int(args[0]):]
    elif op == "set":
        data[int(args[0])] = int(args[1])
    elif op == "pad":
        # The first padding byte after entry INDEX's data becomes non-zero.
        pos = headers(data)[int(args[0])]
        size = int(data[pos + 124:pos + 136].rstrip(b"\0 "), 8)
        data[pos + 512 + size] = 1
    elif op == "data":
        pos = headers(data)[int(args[0])]
        data[pos + 512] ^= 1
    elif op == "drop-end":
        # Ends the file after the last entry's padded data, dropping the
        # end-of-archive marker.
        pos = headers(data)[-1]
        size = int(data[pos + 124:pos + 136].rstrip(b"\0 "), 8)
        del data[pos + 512 + (size + 511) // 512 * 512:]
    open(path, "wb").write(data)


def cmd_expect(out, tar, image, prefix, dirs, *members):
    rows = []
    for m in members:
        name, _, path = m.partition("=")
        rows.append({"name": name, "bytes": os.path.getsize(path), "sha256": sha(path)})
    doc = {"format": "fm-pack-tar-expectation/v1", "tar_sha256": sha(tar), "image_sha256": sha(image),
           "layout": {"image_prefix": prefix, "tar_directories": dirs}, "members": rows}
    json.dump(doc, open(out, "w"))


def cmd_edit(path, code):
    d = json.load(open(path))
    exec(code, {"d": d})
    json.dump(d, open(path, "w"))


def cmd_mutant(source, mode, dest):
    text = open(source).read()
    if mode == "skip-tar-hash":
        old, new = 'if tar_sha != doc["tar_sha256"]:', "if False:"
    elif mode == "omit-reverse":
        old = '''    for name in sorted(found_files):
        if name not in expected:
            raise g5(side + "-extra-member", shown(name))
    for name in sorted(found_dirs):
        if name not in allowed_dirs:
            raise g5(side + "-extra-member", shown(name) + "/")
'''
        new = ""
    else:
        raise SystemExit("unknown mutant: " + mode)
    if old not in text:
        raise SystemExit("mutant does not apply: " + mode)
    open(dest, "w").write(text.replace(old, new))


globals()["cmd_" + sys.argv[1].replace("-", "")](*sys.argv[2:])
PY
fx() { python3 -I "$FX" "$@" || fail "fixture builder failed: $*"; }

# make_bin DIR [MUTANT]: a copy of the command, with a fake fm-storage.sh.
make_bin() {
  mkdir -p "$1"
  cp "$ROOT/bin/fm-pack.sh" "$ROOT/bin/fm-pack-retry.c" "$1/"
  if [ -n "${2:-}" ]; then
    fx mutant "$ROOT/bin/fm-pack-parity.py" "$2" "$1/fm-pack-parity.py"
  else
    cp "$ROOT/bin/fm-pack-parity.py" "$1/fm-pack-parity.py"
  fi
  cat >"$1/fm-storage.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FAKE_STORAGE_LOG"
case "${FAKE_HEALTH:-}" in
  offline) printf 'offline d-unplugged\n'; exit 75 ;;
  ok) printf 'ok\n'; exit 0 ;;
  two-lines) printf 'offline d-unplugged\nmore\n'; exit 75 ;;
  *) printf 'fm-storage: unknown command %s\n' "${1:-}" >&2; exit 2 ;;
esac
SH
  chmod +x "$1/fm-pack.sh" "$1/fm-pack-parity.py" "$1/fm-storage.sh"
}
make_bin "$T/bin"
VB=$T/bin

# vt ARG...: run verify-tar from $VB; sets RC, OUT and ERR.
vt() {
  local hook=()
  [ -z "${HOOK:-}" ] || hook=("FM_PACK_TEST_BEFORE_RECHECK=$HOOK")
  rm -f "$T/storage.log"
  OUT=$(env -u FM_PACK_TEST_BEFORE_RECHECK FM_PACK_MOUNT="${MOUNT:-unsquashfs}" TMPDIR="$T/tmp" \
    FM_PACK_SLOT_LOCK="$T/slot.lock" \
    FAKE_STORAGE_LOG="$T/storage.log" FAKE_HEALTH="${HEALTH:-}" ${hook[@]+"${hook[@]}"} \
    "$VB/fm-pack.sh" verify-tar "$@" 2>"$T/err")
  RC=$?
  ERR=$(cat "$T/err")
}

sha() { local s; s=$(sha256sum -- "$1") || fail "cannot hash $1"; printf '%s\n' "${s%% *}"; }

# expect_pass LABEL TAR IMAGE N
expect_pass() {
  expect_code 0 "$RC" "$1: $ERR"
  assert_equals "fm-pack-tar-parity/v1 tar_sha256=$(sha "$2") image_sha256=$(sha "$3") members=$4" "$OUT" "$1: the one stdout line"
  assert_equals '' "$ERR" "$1: stderr is empty"
  assert_equals '' "$(ls -A "$T/tmp")" "$1: nothing is left in TMPDIR"
}

# expect_refusal LABEL RC LINE: exactly one stderr line, nothing on stdout.
expect_refusal() {
  expect_code "$2" "$RC" "$1: $ERR"
  assert_equals '' "$OUT" "$1: stdout is empty"
  assert_equals "$3" "$ERR" "$1: the one stderr line"
  assert_equals '' "$(ls -A "$T/tmp")" "$1: nothing is left in TMPDIR"
}

# The unit: an empty file, a name over 100 bytes, a UTF-8 name with a space.
LONG=$(printf 'n%.0s' $(seq 1 150))
SRC=$T/src
mkdir -p "$SRC/sub"
printf 'hello\n' >"$SRC/a.txt"
: >"$SRC/empty"
printf 'x%.0s' $(seq 1 700) >"$SRC/sub/b.bin"
printf 'u\n' >"$SRC/sp ace ü"
printf 'long\n' >"$SRC/sub/$LONG"
NAMES=(a.txt empty sub/b.bin 'sp ace ü' "sub/$LONG")
SPECS=() MEMBERS=()
for n in "${NAMES[@]}"; do SPECS+=("f:$n=$SRC/$n"); MEMBERS+=("$n=$SRC/$n"); done

# image DIR OUT [-keep-as-directory]
image() {
  mksquashfs "$1" "$2" -noappend -no-progress -quiet -comp gzip -all-root -no-xattrs \
    -mkfs-time 0 -all-time 0 ${3:+"$3"} >/dev/null || fail "mksquashfs $1 failed"
}

IMG=$T/flat.sqfs
image "$SRC" "$IMG"
GNU=$T/gnu.tar
fx tar "$GNU" gnu "${SPECS[@]}"
EXP=$T/gnu.json
fx expect "$EXP" "$GNU" "$IMG" '' none "${MEMBERS[@]}"

# variant NAME: a private copy of the GNU tar and its expectation, to edit.
variant() {
  W=$T/w/$1
  mkdir -p "$W"
  cp "$GNU" "$W/t.tar"
  cp "$EXP" "$W/e.json"
}

# re-anchor: the expectation names the edited tar's digest, so the case
# reaches the check after the whole-tar digest.
re_anchor() { fx edit "$W/e.json" "d['tar_sha256']='$(sha "$W/t.tar")'"; }

snapshot() { (cd "$T" && find src w gnu.tar gnu.json flat.sqfs -printf '%p %s %T@ %i\n' | LC_ALL=C sort && find src w -type f -exec sha256sum {} + | LC_ALL=C sort); }

test_positive_controls() {
  local before d
  before=$(snapshot)
  vt "$IMG" --tar "$GNU" --expect "$EXP"
  expect_pass "a GNU tar with long, UTF-8 and empty members" "$GNU" "$IMG" 5
  assert_absent "$T/storage.log" "a pass never asks for D: health"
  vt "$IMG" --expect "$EXP" --tar "$GNU"
  expect_pass "the options in either order" "$GNU" "$IMG" 5
  assert_equals "$before" "$(snapshot)" "verify-tar writes, moves and deletes nothing"

  # A PAX tar of ASCII names, the long one in a PAX path record.
  d=$T/pax
  mkdir -p "$d/src"
  cp "$SRC/a.txt" "$d/src/a.txt"
  mkdir "$d/src/sub"
  cp "$SRC/sub/$LONG" "$d/src/sub/$LONG"
  image "$d/src" "$d/i.sqfs"
  fx tar "$d/t.tar" pax "f:a.txt=$d/src/a.txt" "f:sub/$LONG=$d/src/sub/$LONG"
  fx expect "$d/e.json" "$d/t.tar" "$d/i.sqfs" '' none "a.txt=$d/src/a.txt" "sub/$LONG=$d/src/sub/$LONG"
  vt "$d/i.sqfs" --tar "$d/t.tar" --expect "$d/e.json"
  expect_pass "a PAX tar with a long path" "$d/t.tar" "$d/i.sqfs" 2

  # A pack tree: the image holds basename(SRC)/, and the tar carries its
  # members' directory entries under the ancestors layout.
  d=$T/tree
  mkdir -p "$d"
  image "$SRC" "$d/i.sqfs" -keep-as-directory
  fx tar "$d/t.tar" gnu d:sub "${SPECS[@]}"
  fx expect "$d/e.json" "$d/t.tar" "$d/i.sqfs" src ancestors "${MEMBERS[@]}"
  vt "$d/i.sqfs" --tar "$d/t.tar" --expect "$d/e.json"
  expect_pass "a prefixed image and a tar with directory entries" "$d/t.tar" "$d/i.sqfs" 5

  # The phase-D dialect: GNU tar's own output from explicit names, and the
  # image sqfstar builds from that same stream.
  if tar --version 2>/dev/null | grep -F 'GNU tar' >/dev/null && command -v sqfstar >/dev/null 2>&1; then
    d=$T/phase-d
    mkdir -p "$d"
    (cd "$SRC" && tar -cf - -- "${NAMES[@]}") >"$d/t.tar" || fail "GNU tar failed"
    sqfstar -quiet -no-progress -comp gzip -no-xattrs -mkfs-time 0 -all-time 0 -force-uid 0 -force-gid 0 \
      "$d/i.sqfs" <"$d/t.tar" >/dev/null || fail "sqfstar failed"
    fx expect "$d/e.json" "$d/t.tar" "$d/i.sqfs" '' none "${MEMBERS[@]}"
    vt "$d/i.sqfs" --tar "$d/t.tar" --expect "$d/e.json"
    expect_pass "GNU tar output and its sqfstar image" "$d/t.tar" "$d/i.sqfs" 5
    (cd "$SRC" && tar --format=posix -cf - -- "${NAMES[@]}") >"$d/p.tar" || fail "GNU tar --format=posix failed"
    fx expect "$d/p.json" "$d/p.tar" "$IMG" '' none "${MEMBERS[@]}"
    vt "$IMG" --tar "$d/p.tar" --expect "$d/p.json"
    expect_pass "GNU tar's POSIX format against the same members" "$d/p.tar" "$IMG" 5
  else
    echo "skip: GNU tar or sqfstar missing; the tarfile fixtures cover GNU and PAX tars"
  fi

  d=$T/only-empty
  mkdir -p "$d/src"
  : >"$d/src/e"
  image "$d/src" "$d/i.sqfs"
  fx tar "$d/t.tar" gnu "f:e=$d/src/e"
  fx expect "$d/e.json" "$d/t.tar" "$d/i.sqfs" '' none "e=$d/src/e"
  vt "$d/i.sqfs" --tar "$d/t.tar" --expect "$d/e.json"
  expect_pass "a unit of one empty file" "$d/t.tar" "$d/i.sqfs" 1
  pass "positive controls: GNU, PAX, prefixed tree, phase-D dialect, empty files; read-only"
}

# Mutant oracles: each is a subshell so a failed assertion ends only the case.
case_header_only() (
  variant header-only
  fx header "$W/t.tar" 0 mtime '00000000001\0'
  vt "$IMG" --tar "$W/t.tar" --expect "$W/e.json"
  expect_refusal "a header-only change" 1 \
    "fm-pack: refused: G5: tar-digest: the tar's sha256 is $(sha "$W/t.tar"), expected $(sha "$GNU")"
  assert_absent "$T/storage.log" "a mismatch never asks for D: health"
)

case_extra_zero_block() (
  variant zero-block
  fx bytes "$W/t.tar" append-zero 512
  vt "$IMG" --tar "$W/t.tar" --expect "$W/e.json"
  expect_refusal "one more trailing zero block" 1 \
    "fm-pack: refused: G5: tar-digest: the tar's sha256 is $(sha "$W/t.tar"), expected $(sha "$GNU")"
)

case_extra_tar_member() (
  variant extra-tar
  printf 'more\n' >"$W/more"
  fx tar "$W/t.tar" gnu "${SPECS[@]}" "f:more=$W/more"
  re_anchor
  vt "$IMG" --tar "$W/t.tar" --expect "$W/e.json"
  expect_refusal "a tar member the expectation lacks" 1 "fm-pack: refused: G5: tar-extra-member: more"
)

case_extra_image_member() (
  local d=$T/w/extra-image
  mkdir -p "$d"
  cp -R "$SRC" "$d/src"
  printf 'more\n' >"$d/src/more"
  image "$d/src" "$d/i.sqfs"
  cp "$EXP" "$d/e.json"
  fx edit "$d/e.json" "d['image_sha256']='$(sha "$d/i.sqfs")'"
  vt "$d/i.sqfs" --tar "$GNU" --expect "$d/e.json"
  expect_refusal "an image member the expectation lacks" 1 "fm-pack: refused: G5: image-extra-member: more"
)

case_extra_image_directory() (
  local d=$T/w/extra-dir
  mkdir -p "$d"
  cp -R "$SRC" "$d/src"
  mkdir "$d/src/stray"
  image "$d/src" "$d/i.sqfs"
  cp "$EXP" "$d/e.json"
  fx edit "$d/e.json" "d['image_sha256']='$(sha "$d/i.sqfs")'"
  vt "$d/i.sqfs" --tar "$GNU" --expect "$d/e.json"
  expect_refusal "an empty directory the layout does not admit" 1 "fm-pack: refused: G5: image-extra-member: stray/"
)

test_whole_tar_digest() {
  case_header_only
  case_extra_zero_block
  variant member-byte
  fx bytes "$W/t.tar" data 0
  vt "$IMG" --tar "$W/t.tar" --expect "$W/e.json"
  expect_refusal "a changed member byte" 1 \
    "fm-pack: refused: G5: tar-digest: the tar's sha256 is $(sha "$W/t.tar"), expected $(sha "$GNU")"
  re_anchor
  vt "$IMG" --tar "$W/t.tar" --expect "$W/e.json"
  expect_refusal "a changed member under a re-anchored digest" 1 "fm-pack: refused: G5: tar-member-digest: a.txt"
  variant padding
  fx bytes "$W/t.tar" pad 0
  vt "$IMG" --tar "$W/t.tar" --expect "$W/e.json"
  expect_refusal "non-zero entry padding" 1 "fm-pack: refused: G5: tar-padding: non-zero padding after a.txt"
  pass "the whole-tar digest catches header-only, trailing-block and content changes; padding refuses"
}

test_member_parity() {
  local d
  case_extra_tar_member
  case_extra_image_member
  case_extra_image_directory

  variant missing
  fx tar "$W/t.tar" gnu "${SPECS[@]:0:4}"
  re_anchor
  vt "$IMG" --tar "$W/t.tar" --expect "$W/e.json"
  expect_refusal "an expected member missing from the tar" 1 \
    "fm-pack: refused: G5: tar-missing-member: sub/$LONG"

  d=$T/w/missing-image
  mkdir -p "$d"
  cp -R "$SRC" "$d/src"
  rm "$d/src/empty"
  image "$d/src" "$d/i.sqfs"
  cp "$EXP" "$d/e.json"
  fx edit "$d/e.json" "d['image_sha256']='$(sha "$d/i.sqfs")'"
  vt "$d/i.sqfs" --tar "$GNU" --expect "$d/e.json"
  expect_refusal "an expected member missing from the image" 1 "fm-pack: refused: G5: image-missing-member: empty"

  d=$T/w/changed-image
  mkdir -p "$d"
  cp -R "$SRC" "$d/src"
  printf 'HELLO\n' >"$d/src/a.txt"
  image "$d/src" "$d/i.sqfs"
  cp "$EXP" "$d/e.json"
  fx edit "$d/e.json" "d['image_sha256']='$(sha "$d/i.sqfs")'"
  vt "$d/i.sqfs" --tar "$GNU" --expect "$d/e.json"
  expect_refusal "an image member with other bytes of the same length" 1 \
    "fm-pack: refused: G5: image-member-digest: a.txt"
  printf 'hello!\n' >"$d/src/a.txt"
  image "$d/src" "$d/i.sqfs"
  fx edit "$d/e.json" "d['image_sha256']='$(sha "$d/i.sqfs")'"
  vt "$d/i.sqfs" --tar "$GNU" --expect "$d/e.json"
  expect_refusal "an image member of another length" 1 \
    "fm-pack: refused: G5: image-member-size: a.txt: 7 bytes, expected 6"

  d=$T/w/type-swap
  mkdir -p "$d"
  cp -R "$SRC" "$d/src"
  rm "$d/src/a.txt"
  ln -s empty "$d/src/a.txt"
  image "$d/src" "$d/i.sqfs"
  cp "$EXP" "$d/e.json"
  fx edit "$d/e.json" "d['image_sha256']='$(sha "$d/i.sqfs")'"
  vt "$d/i.sqfs" --tar "$GNU" --expect "$d/e.json"
  assert_contains "$ERR" "fm-pack: refused: G5: image-member-type: " "a symlink in a member's place"
  expect_code 1 "$RC" "a symlink in a member's place"
  rm "$d/src/a.txt"
  mkdir "$d/src/a.txt"
  image "$d/src" "$d/i.sqfs"
  fx edit "$d/e.json" "d['image_sha256']='$(sha "$d/i.sqfs")'"
  vt "$d/i.sqfs" --tar "$GNU" --expect "$d/e.json"
  expect_refusal "a directory in a member's place" 1 "fm-pack: refused: G5: image-extra-member: a.txt/"

  variant wrong-size
  fx edit "$W/e.json" "d['members'][0]['bytes']+=1"
  vt "$IMG" --tar "$W/t.tar" --expect "$W/e.json"
  expect_refusal "an expected size one byte off" 1 "fm-pack: refused: G5: tar-member-size: a.txt: 6 bytes, expected 7"
  variant wrong-name
  fx edit "$W/e.json" "d['members'][0]['name']='A.txt'"
  vt "$IMG" --tar "$W/t.tar" --expect "$W/e.json"
  expect_refusal "the same content under another name" 1 "fm-pack: refused: G5: tar-extra-member: a.txt"
  variant wrong-member-sha
  fx edit "$W/e.json" "d['members'][1]['sha256']='0'*64"
  vt "$IMG" --tar "$W/t.tar" --expect "$W/e.json"
  expect_refusal "a wrong receipt member digest" 1 "fm-pack: refused: G5: tar-member-digest: empty"
  variant wrong-image-sha
  fx edit "$W/e.json" "d['image_sha256']='0'*64"
  vt "$IMG" --tar "$W/t.tar" --expect "$W/e.json"
  expect_refusal "a wrong image digest" 1 \
    "fm-pack: refused: G5: image-digest: the image's sha256 is $(sha "$IMG"), expected $(printf '0%.0s' $(seq 1 64))"
  variant wrong-prefix
  image "$SRC" "$W/i.sqfs" -keep-as-directory
  fx edit "$W/e.json" "d['image_sha256']='$(sha "$W/i.sqfs")'"
  vt "$W/i.sqfs" --tar "$W/t.tar" --expect "$W/e.json"
  expect_refusal "a prefixed image read as flat" 1 "fm-pack: refused: G5: image-extra-member: src/a.txt"
  pass "members compare in both directions on both sides: missing, extra, size, digest, type, name, prefix"
}

test_tar_entries() {
  variant duplicate
  fx tar "$W/t.tar" gnu "${SPECS[@]}" "f:a.txt=$SRC/a.txt"
  re_anchor
  vt "$IMG" --tar "$W/t.tar" --expect "$W/e.json"
  expect_refusal "a duplicate member" 1 "fm-pack: refused: G5: tar-duplicate: a.txt"
  variant symlink
  fx tar "$W/t.tar" gnu "${SPECS[@]:1}" s:a.txt=empty
  re_anchor
  vt "$IMG" --tar "$W/t.tar" --expect "$W/e.json"
  expect_refusal "a symlink in a member's place" 1 "fm-pack: refused: G5: tar-link: a hard or symbolic link entry"
  variant hardlink
  fx tar "$W/t.tar" gnu "${SPECS[@]:1}" h:a.txt=empty
  re_anchor
  vt "$IMG" --tar "$W/t.tar" --expect "$W/e.json"
  expect_refusal "a hard link in a member's place" 1 "fm-pack: refused: G5: tar-link: a hard or symbolic link entry"
  variant dir-none
  fx tar "$W/t.tar" gnu d:sub "${SPECS[@]}"
  re_anchor
  vt "$IMG" --tar "$W/t.tar" --expect "$W/e.json"
  expect_refusal "a directory entry under the none layout" 1 \
    "fm-pack: refused: G5: tar-directory: sub: the layout admits no directory entries"
  variant dir-swap
  fx tar "$W/t.tar" gnu d:a.txt "${SPECS[@]:1}"
  re_anchor
  fx edit "$W/e.json" "d['layout']['tar_directories']='ancestors'"
  vt "$IMG" --tar "$W/t.tar" --expect "$W/e.json"
  expect_refusal "a directory in a member's place" 1 "fm-pack: refused: G5: tar-extra-member: a.txt/"
  variant traversal
  fx tar "$W/t.tar" gnu "${SPECS[@]}" "f:../evil=$SRC/a.txt"
  re_anchor
  vt "$IMG" --tar "$W/t.tar" --expect "$W/e.json"
  expect_refusal "a .. member" 1 "fm-pack: refused: G5: tar-unsafe-name: ../evil has an empty, . or .. component"
  variant absolute
  fx tar "$W/t.tar" gnu "f:/etc/evil=$SRC/a.txt"
  re_anchor
  vt "$IMG" --tar "$W/t.tar" --expect "$W/e.json"
  expect_refusal "an absolute member" 1 "fm-pack: refused: G5: tar-unsafe-name: /etc/evil not relative or ends in /"
  variant pax-override
  fx tar "$W/t.tar" pax x:a.txt=path=b.txt "${SPECS[@]:1}"
  re_anchor
  vt "$IMG" --tar "$W/t.tar" --expect "$W/e.json"
  expect_refusal "a PAX path overriding the header name" 1 \
    "fm-pack: refused: G5: tar-unsafe-name: the header name is not a prefix of the PAX path"
  variant pax-traversal
  fx tar "$W/t.tar" pax x:a.txt=path=a.txt/../../evil "${SPECS[@]:1}"
  re_anchor
  vt "$IMG" --tar "$W/t.tar" --expect "$W/e.json"
  expect_refusal "a PAX path that climbs out" 1 \
    "fm-pack: refused: G5: tar-unsafe-name: a.txt/../../evil has an empty, . or .. component"
  # Python's PAX writer puts a ?-replaced ASCII name in the ustar header of a
  # non-ASCII path, so the two names disagree and the entry is ambiguous.
  variant pax-ascii-name
  fx tar "$W/t.tar" pax "f:sp ace ü=$SRC/sp ace ü"
  re_anchor
  vt "$IMG" --tar "$W/t.tar" --expect "$W/e.json"
  expect_refusal "a PAX path whose ustar name was replaced" 1 \
    "fm-pack: refused: G5: tar-unsafe-name: the header name is not a prefix of the PAX path"
  variant pax-key
  fx tar "$W/t.tar" pax x:a.txt=linkpath=empty "${SPECS[@]:1}"
  re_anchor
  vt "$IMG" --tar "$W/t.tar" --expect "$W/e.json"
  expect_refusal "an unsupported PAX key" 1 "fm-pack: refused: G5: tar-unsupported: PAX key linkpath"
  variant pax-global
  fx globalpax "$W/t.tar" "$SRC/a.txt"
  re_anchor
  vt "$IMG" --tar "$W/t.tar" --expect "$W/e.json"
  expect_refusal "a PAX global header" 1 "fm-pack: refused: G5: tar-unsupported: entry type g"
  pass "tar entries: duplicates, links, directories by layout, traversal, PAX override and extensions refuse"
}

test_tar_framing() {
  variant extra-archive
  fx bytes "$W/t.tar" append-file "$GNU"
  re_anchor
  vt "$IMG" --tar "$W/t.tar" --expect "$W/e.json"
  expect_refusal "a second archive after the end marker" 1 \
    "fm-pack: refused: G5: tar-trailing-data: non-zero bytes after the end-of-archive marker"
  variant trailing
  fx bytes "$W/t.tar" append 'payload'
  re_anchor
  vt "$IMG" --tar "$W/t.tar" --expect "$W/e.json"
  expect_refusal "a trailing payload" 1 \
    "fm-pack: refused: G5: tar-trailing-data: non-zero bytes after the end-of-archive marker"
  variant ragged
  fx bytes "$W/t.tar" append-zero 100
  re_anchor
  vt "$IMG" --tar "$W/t.tar" --expect "$W/e.json"
  expect_refusal "a length that is not whole blocks" 1 \
    "fm-pack: refused: G5: tar-truncated: length is not a whole number of 512-byte blocks"
  variant truncated
  fx bytes "$W/t.tar" cut 700
  re_anchor
  vt "$IMG" --tar "$W/t.tar" --expect "$W/e.json"
  expect_refusal "a tar cut inside the first entry" 1 "fm-pack: refused: G5: tar-truncated: inside the padding of a.txt"
  variant no-end
  fx bytes "$W/t.tar" drop-end
  re_anchor
  vt "$IMG" --tar "$W/t.tar" --expect "$W/e.json"
  expect_refusal "a tar with no end-of-archive marker" 1 "fm-pack: refused: G5: tar-truncated: no end-of-archive marker"
  variant checksum
  fx bytes "$W/t.tar" set 0 66
  re_anchor
  vt "$IMG" --tar "$W/t.tar" --expect "$W/e.json"
  expect_refusal "a header whose checksum no longer matches" 1 "fm-pack: refused: G5: tar-checksum: entry 1"
  variant v7
  fx header "$W/t.tar" 0 magic ''
  re_anchor
  vt "$IMG" --tar "$W/t.tar" --expect "$W/e.json"
  expect_refusal "a header with no ustar magic" 1 \
    "fm-pack: refused: G5: tar-unsupported: header format is neither POSIX ustar nor GNU"
  variant fifo-type
  fx header "$W/t.tar" 0 type 6
  re_anchor
  vt "$IMG" --tar "$W/t.tar" --expect "$W/e.json"
  expect_refusal "a FIFO entry" 1 "fm-pack: refused: G5: tar-unsupported: entry type 6"
  pass "tar framing: hidden archives, trailing bytes, truncation, checksum and format refuse"
}

test_expectation() {
  local e=$T/w/expect.json
  bad_expect() {
    vt "$IMG" --tar "$GNU" --expect "$e"
    expect_refusal "$1" 2 "fm-pack: refused: expectation: $2"
  }
  printf '{' >"$e"
  vt "$IMG" --tar "$GNU" --expect "$e"
  expect_code 2 "$RC" "a truncated expectation"
  assert_contains "$ERR" "fm-pack: refused: expectation: not valid JSON: " "a truncated expectation"
  cp "$EXP" "$e"
  fx edit "$e" "d['format']='fm-pack-tar-expectation/v2'"
  bad_expect "an unknown expectation format" "unsupported format fm-pack-tar-expectation/v2"
  cp "$EXP" "$e"
  fx edit "$e" "d['extra']=1"
  bad_expect "an unknown key" "the expectation keys must be exactly format,image_sha256,layout,members,tar_sha256"
  cp "$EXP" "$e"
  fx edit "$e" "d['tar_sha256']=d['tar_sha256'].upper()"
  bad_expect "an uppercase digest" "tar_sha256 is not 64 lowercase hex digits"
  cp "$EXP" "$e"
  fx edit "$e" "d['layout']['tar_directories']='any'"
  bad_expect "an unknown directory layout" "layout.tar_directories must be none or ancestors"
  cp "$EXP" "$e"
  fx edit "$e" "d['layout']['image_prefix']='../up'"
  bad_expect "a prefix that climbs out" "layout.image_prefix has an empty, . or .. component"
  cp "$EXP" "$e"
  fx edit "$e" "d['members'][0]['name']='a/../b'"
  bad_expect "a member that climbs out" "members[0].name has an empty, . or .. component"
  cp "$EXP" "$e"
  fx edit "$e" "d['members'][0]['bytes']=True"
  bad_expect "a boolean size" "members[0].bytes is not a non-negative integer"
  cp "$EXP" "$e"
  fx edit "$e" "d['members'].append(dict(d['members'][0]))"
  bad_expect "a duplicate expected member" "duplicate member a.txt"
  cp "$EXP" "$e"
  fx edit "$e" "d['members'].append(dict(d['members'][0], name='sub'))"
  bad_expect "a member that is another member's directory" "member sub is also another member's directory"
  python3 -c 'import sys; t=open(sys.argv[1]).read(); open(sys.argv[2],"w").write(t[:-1] + ", \"format\": \"x\"}")' "$EXP" "$e"
  bad_expect "a repeated key" "not valid JSON: duplicate key format"
  pass "an invalid or unsupported expectation refuses with exit 2"
}

test_misuse() {
  local d=$T/w/misuse
  mkdir -p "$d"
  vt
  expect_refusal "no arguments" 2 "fm-pack: refused: usage: verify-tar needs IMAGE --tar TAR --expect EXPECTATION.json"
  vt "$IMG" --tar "$GNU"
  expect_refusal "no expectation" 2 "fm-pack: refused: usage: verify-tar needs IMAGE --tar TAR --expect EXPECTATION.json"
  vt "$IMG" --tar "$GNU" --tar "$GNU" --expect "$EXP"
  expect_refusal "a repeated option" 2 "fm-pack: refused: usage: --tar given twice"
  vt "$IMG" --tar "$GNU" --expect "$EXP" extra
  expect_refusal "an extra argument" 2 \
    "fm-pack: refused: usage: verify-tar needs IMAGE --tar TAR --expect EXPECTATION.json, not extra"
  MOUNT=bogus vt "$IMG" --tar "$GNU" --expect "$EXP"
  expect_refusal "an unknown reader" 2 "fm-pack: FM_PACK_MOUNT must be mount or unsquashfs, not bogus"
  ln -s "$GNU" "$d/link.tar"
  vt "$IMG" --tar "$d/link.tar" --expect "$EXP"
  expect_refusal "a tar named through a symlink" 2 \
    "fm-pack: refused: usage: cannot open the tar $d/link.tar: Too many levels of symbolic links"
  mkfifo "$d/fifo"
  vt "$IMG" --tar "$d/fifo" --expect "$EXP"
  expect_refusal "a FIFO in the tar's place" 2 "fm-pack: refused: usage: the tar $d/fifo is not a regular file"
  vt "$T/src" --tar "$GNU" --expect "$EXP"
  expect_refusal "a directory in the image's place" 2 "fm-pack: refused: usage: the image $T/src is not a regular file"
  pass "misuse refuses with exit 2 and one line"
}

test_storage_offline() {
  local d=$T/w/offline
  mkdir -p "$d"
  HEALTH=offline vt "$IMG" --tar "$d/absent.tar" --expect "$EXP"
  expect_refusal "a missing tar while D: is offline" 75 "fm-pack: wait: storage-offline: d-unplugged"
  assert_equals 'health --volume d' "$(cat "$T/storage.log")" "health is asked once, read-only"
  vt "$IMG" --tar "$d/absent.tar" --expect "$EXP"
  expect_refusal "a missing tar while health cannot answer" 2 \
    "fm-pack: refused: usage: cannot open the tar $d/absent.tar: No such file or directory"
  HEALTH=ok vt "$IMG" --tar "$d/absent.tar" --expect "$EXP"
  expect_refusal "a missing tar while D: is healthy" 2 \
    "fm-pack: refused: usage: cannot open the tar $d/absent.tar: No such file or directory"
  HEALTH=two-lines vt "$IMG" --tar "$d/absent.tar" --expect "$EXP"
  expect_refusal "a malformed offline answer" 2 \
    "fm-pack: refused: usage: cannot open the tar $d/absent.tar: No such file or directory"

  # An image whose bytes match the expectation but cannot be read as SquashFS.
  printf 'not squashfs\n' >"$d/i.sqfs"
  cp "$EXP" "$d/e.json"
  fx edit "$d/e.json" "d['image_sha256']='$(sha "$d/i.sqfs")'"
  HEALTH=offline vt "$d/i.sqfs" --tar "$GNU" --expect "$d/e.json"
  expect_refusal "an image read failure while D: is offline" 75 "fm-pack: wait: storage-offline: d-unplugged"
  HEALTH=ok vt "$d/i.sqfs" --tar "$GNU" --expect "$d/e.json"
  expect_refusal "an image read failure while D: is healthy" 1 \
    "fm-pack: refused: G5: image-read: unsquashfs -lln failed"
  pass "a read failure waits 75 only when health proves D: offline; any other answer refuses"
}

test_fresh_view() {
  local d=$T/w/fresh
  mkdir -p "$d"
  cp -R "$SRC" "$d/src"
  image "$d/src" "$d/i.sqfs"
  cp "$EXP" "$d/e.json"
  fx edit "$d/e.json" "d['image_sha256']='$(sha "$d/i.sqfs")'"
  vt "$d/i.sqfs" --tar "$GNU" --expect "$d/e.json"
  expect_pass "the first image" "$GNU" "$d/i.sqfs" 5
  printf 'HELLO\n' >"$d/src/a.txt"
  image "$d/src" "$d/i.sqfs"
  fx edit "$d/e.json" "d['image_sha256']='$(sha "$d/i.sqfs")'"
  vt "$d/i.sqfs" --tar "$GNU" --expect "$d/e.json"
  expect_refusal "a rebuilt image at the same path is read afresh" 1 "fm-pack: refused: G5: image-member-digest: a.txt"
  pass "each run reads the image it hashed, never an earlier view"
}

test_identity() {
  local d=$T/w/identity
  mkdir -p "$d"
  cp "$GNU" "$d/t.tar"
  cp "$IMG" "$d/i.sqfs"
  fx expect "$d/e.json" "$d/t.tar" "$d/i.sqfs" '' none "${MEMBERS[@]}"
  HOOK="cp '$d/t.tar' '$d/t.new' && mv '$d/t.new' '$d/t.tar'" vt "$d/i.sqfs" --tar "$d/t.tar" --expect "$d/e.json"
  expect_refusal "the tar replaced by an identical copy" 1 "fm-pack: refused: G5: tar-identity-changed: $d/t.tar"
  HOOK="touch -t 200101010000 '$d/i.sqfs'" vt "$d/i.sqfs" --tar "$d/t.tar" --expect "$d/e.json"
  expect_refusal "the image touched" 1 "fm-pack: refused: G5: image-identity-changed: $d/i.sqfs"
  HOOK="rm '$d/t.tar'" vt "$d/i.sqfs" --tar "$d/t.tar" --expect "$d/e.json"
  expect_refusal "the tar removed" 1 "fm-pack: refused: G5: tar-identity-changed: No such file or directory"
  pass "a pass is bound to the opened tar and image: replaced, touched or removed refuses"
}

test_mount_reader() {
  local probe d=$T/w/mount
  probe=$(mktemp -d "$T/probe.XXXXXX")
  if [ ! -c /dev/fuse ] || ! command -v squashfuse >/dev/null 2>&1 || ! command -v fusermount3 >/dev/null 2>&1 ||
    ! squashfuse -o ro "$IMG" "$probe" 2>/dev/null; then
    echo "skip: no usable squashfuse mount here; the unsquashfs reader covers verify-tar"
    return 0
  fi
  fusermount3 -u "$probe"
  MOUNT=mount vt "$IMG" --tar "$GNU" --expect "$EXP"
  expect_pass "the squashfuse reader" "$GNU" "$IMG" 5
  mkdir -p "$d"
  cp -R "$SRC" "$d/src"
  printf 'more\n' >"$d/src/more"
  image "$d/src" "$d/i.sqfs"
  cp "$EXP" "$d/e.json"
  fx edit "$d/e.json" "d['image_sha256']='$(sha "$d/i.sqfs")'"
  MOUNT=mount vt "$d/i.sqfs" --tar "$GNU" --expect "$d/e.json"
  expect_refusal "an extra image member through squashfuse" 1 "fm-pack: refused: G5: image-extra-member: more"
  pass "the squashfuse reader passes, refuses an extra member and unmounts"
}

# Branch-removal mutants from the plan: each must turn a refusal into a pass.
test_mutants() {
  local mode cases c log errors=''
  for mode in skip-tar-hash omit-reverse; do
    case "$mode" in
      skip-tar-hash) cases='case_header_only case_extra_zero_block' ;;
      omit-reverse) cases='case_extra_tar_member case_extra_image_member case_extra_image_directory' ;;
    esac
    make_bin "$T/mutant-$mode" "$mode"
    for c in $cases; do
      log=$T/mutant-$mode-$c.log
      if VB=$T/mutant-$mode "$c" >"$log" 2>&1; then
        errors+="$mode survived $c; "
      elif ! grep -F 'expected exit 1, got 0' "$log" >/dev/null; then
        cat "$log"
        errors+="$mode did not reach a false pass in $c; "
      else
        pass "mutant $mode killed by $c"
      fi
    done
  done
  [ -z "$errors" ] || fail "mutants: $errors"
}

test_positive_controls
test_whole_tar_digest
test_member_parity
test_tar_entries
test_tar_framing
test_expectation
test_misuse
test_storage_offline
test_fresh_view
test_identity
test_mount_reader
test_mutants
