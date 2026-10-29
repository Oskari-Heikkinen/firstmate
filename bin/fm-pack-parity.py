#!/usr/bin/env python3
"""fm-pack-parity.py - the G5-equivalent tar/image parity check behind
`bin/fm-pack.sh verify-tar`.

That script's header owns the usage, the fm-pack-tar-expectation/v1 input,
the output line and the exit codes; this file only implements them. It reads
the tar, the image and the expectation and writes nothing but its one output
line: no extraction, no source write, no deletion.
"""

import hashlib
import json
import os
import re
import signal
import stat
import subprocess
import sys
import tempfile

FORMAT = "fm-pack-tar-expectation/v1"
RESULT = "fm-pack-tar-parity/v1"
CHUNK = 1 << 20
BLOCK = 512
EXPECT_MAX_BYTES = 64 << 20
MAX_MEMBERS = 262144
NAME_MAX_BYTES = 4095
COMPONENT_MAX_BYTES = 255
META_MAX_BYTES = 64 << 10
SIZE_MAX = (1 << 63) - 1
HEALTH_TIMEOUT = 60
SHA_RE = re.compile(r"\A[0-9a-f]{64}\Z")
PAX_KEYS = frozenset(("path", "size", "mtime", "atime", "ctime", "uid", "gid", "uname", "gname"))
POSIX_MAGIC = b"ustar\x0000"
GNU_MAGIC = b"ustar  \x00"
ZERO_CHUNK = bytes(CHUNK)
LISTING_RE = re.compile(rb"\A([-d])[-rwxsStT]{9} \S+ +\d+ \d{4}-\d\d-\d\d \d\d:\d\d (.*)\Z")


class Outcome(Exception):
    """One final outcome: exit code and the single stderr line."""

    def __init__(self, rc, line):
        super().__init__(line)
        self.rc = rc
        self.line = line


class ReadFailure(Exception):
    """An input could not be read; the outcome depends on D:'s health."""

    def __init__(self, rc, line):
        super().__init__(line)
        self.rc = rc
        self.line = line


class Interrupted(Exception):
    pass


def shown(value, n=160):
    """A bounded one-line rendering of untrusted text."""
    if isinstance(value, bytes):
        value = value.decode("utf-8", "backslashreplace")
    text = value.encode("unicode_escape").decode("ascii")
    return text if len(text) <= n else text[:n] + "..."


def usage(detail):
    return Outcome(2, "fm-pack: refused: usage: " + detail)


def bad_expect(detail):
    return Outcome(2, "fm-pack: refused: expectation: " + detail)


def g5(code, detail=""):
    return Outcome(1, "fm-pack: refused: G5: " + code + (": " + detail if detail else ""))


def check_name(name):
    """None when name is a canonical relative member name, else why not."""
    if not isinstance(name, str) or not name:
        return "empty or not a string"
    try:
        raw = name.encode("utf-8")
    except UnicodeEncodeError:
        return "not UTF-8"
    if len(raw) > NAME_MAX_BYTES:
        return "longer than %d bytes" % NAME_MAX_BYTES
    if any(c < 0x20 or c == 0x7F for c in raw) or b"\\" in raw:
        return "holds a control character or a backslash"
    if raw.startswith(b"/") or raw.endswith(b"/"):
        return "not relative or ends in /"
    for part in raw.split(b"/"):
        if part in (b"", b".", b".."):
            return "has an empty, . or .. component"
        if len(part) > COMPONENT_MAX_BYTES:
            return "has a component longer than %d bytes" % COMPONENT_MAX_BYTES
    return None


def ancestors(name):
    parts = name.split("/")
    return ["/".join(parts[:i]) for i in range(1, len(parts))]


def no_duplicate_keys(pairs):
    out = {}
    for key, value in pairs:
        if key in out:
            raise ValueError("duplicate key " + shown(key))
        out[key] = value
    return out


def closed(obj, keys, where):
    if not isinstance(obj, dict):
        raise bad_expect(where + " is not an object")
    if set(obj) != set(keys):
        raise bad_expect(where + " keys must be exactly " + ",".join(sorted(keys)))


def is_size(v):
    return isinstance(v, int) and not isinstance(v, bool) and 0 <= v <= SIZE_MAX


def is_sha(v):
    return isinstance(v, str) and SHA_RE.match(v) is not None


def load_expectation(raw):
    try:
        doc = json.loads(raw.decode("utf-8"), object_pairs_hook=no_duplicate_keys)
    except (UnicodeDecodeError, ValueError) as exc:
        raise bad_expect("not valid JSON: " + shown(str(exc)))
    if not isinstance(doc, dict) or "format" not in doc:
        raise bad_expect("no format field")
    if doc["format"] != FORMAT:
        raise bad_expect("unsupported format " + shown(str(doc["format"])))
    closed(doc, ("format", "tar_sha256", "image_sha256", "layout", "members"), "the expectation")
    for key in ("tar_sha256", "image_sha256"):
        if not is_sha(doc[key]):
            raise bad_expect(key + " is not 64 lowercase hex digits")
    layout = doc["layout"]
    closed(layout, ("image_prefix", "tar_directories"), "layout")
    prefix = layout["image_prefix"]
    if prefix != "" and check_name(prefix) is not None:
        raise bad_expect("layout.image_prefix " + check_name(prefix))
    if layout["tar_directories"] not in ("none", "ancestors"):
        raise bad_expect("layout.tar_directories must be none or ancestors")
    members = doc["members"]
    if not isinstance(members, list):
        raise bad_expect("members is not a list")
    if len(members) > MAX_MEMBERS:
        raise bad_expect("more than %d members" % MAX_MEMBERS)
    expected = {}
    for i, member in enumerate(members):
        closed(member, ("name", "bytes", "sha256"), "members[%d]" % i)
        why = check_name(member["name"])
        if why is not None:
            raise bad_expect("members[%d].name %s" % (i, why))
        if not is_size(member["bytes"]):
            raise bad_expect("members[%d].bytes is not a non-negative integer" % i)
        if not is_sha(member["sha256"]):
            raise bad_expect("members[%d].sha256 is not 64 lowercase hex digits" % i)
        if member["name"] in expected:
            raise bad_expect("duplicate member " + shown(member["name"]))
        expected[member["name"]] = (member["bytes"], member["sha256"])
    dirs = set()
    for name in expected:
        dirs.update(ancestors(name))
    clash = dirs.intersection(expected)
    if clash:
        raise bad_expect("member " + shown(min(clash)) + " is also another member's directory")
    return doc, expected, dirs


class Source:
    """One opened input: a no-follow regular file, its identity, a hashed reader."""

    def __init__(self, role, path):
        self.role = role
        self.path = path
        try:
            # O_NONBLOCK keeps a FIFO in the file's place from blocking the open.
            self.fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC | os.O_NONBLOCK)
        except OSError as exc:
            raise ReadFailure(2, "fm-pack: refused: usage: cannot open the %s %s: %s"
                              % (role, shown(path), exc.strerror))
        st = os.fstat(self.fd)
        if not stat.S_ISREG(st.st_mode):
            os.close(self.fd)
            raise usage("the %s %s is not a regular file" % (role, shown(path)))
        os.set_blocking(self.fd, True)
        self.ident = identity(st)
        self.size = st.st_size
        self.digest = hashlib.sha256()
        self.offset = 0

    def read(self, n):
        try:
            data = os.read(self.fd, n)
        except OSError as exc:
            raise ReadFailure(1, "fm-pack: refused: G5: %s-read: %s" % (self.role, exc.strerror))
        self.digest.update(data)
        self.offset += len(data)
        return data

    def recheck(self):
        """Refuse when the opened file or the name it was opened by has changed."""
        try:
            now = identity(os.fstat(self.fd))
            named = identity(os.lstat(self.path))
        except OSError as exc:
            raise ReadFailure(1, "fm-pack: refused: G5: %s-identity-changed: %s" % (self.role, exc.strerror))
        if now != self.ident or named != self.ident or self.offset != self.size:
            raise g5(self.role + "-identity-changed", shown(self.path))

    def close(self):
        os.close(self.fd)


def identity(st):
    return (st.st_dev, st.st_ino, st.st_size, st.st_mtime_ns, st.st_ctime_ns)


class Blocks:
    """Whole 512-byte blocks from a Source, read CHUNK bytes at a time."""

    def __init__(self, src):
        self.src = src
        self.buf = bytearray()
        self.pos = 0
        self.eof = False

    def _fill(self):
        if self.eof:
            return False
        data = self.src.read(CHUNK)
        if not data:
            self.eof = True
            return False
        del self.buf[:self.pos]
        self.pos = 0
        self.buf += data
        return True

    def take(self, n):
        """Exactly n bytes (n <= CHUNK), or fewer only at end of file."""
        while len(self.buf) - self.pos < n and self._fill():
            pass
        out = bytes(self.buf[self.pos:self.pos + n])
        self.pos += len(out)
        return out

    def stream(self, n, sink):
        """Feed n bytes to sink in bounded pieces; False when the file ends first."""
        while n:
            piece = self.take(min(n, CHUNK))
            if not piece:
                return False
            sink(piece)
            n -= len(piece)
        return True


def octal(field, what):
    if field[:1] == b"\x80":
        value = int.from_bytes(field[1:], "big")
    else:
        text = field.rstrip(b"\x00 ").lstrip(b" ")
        if not text or any(c not in b"01234567" for c in text):
            raise g5("tar-header", "malformed %s field" % what)
        value = int(text, 8)
    if value > SIZE_MAX:
        raise g5("tar-header", "%s out of range" % what)
    return value


def cstring(field, what):
    """A NUL-terminated header string whose padding is all NUL."""
    end = field.find(b"\x00")
    if end < 0:
        return bytes(field)
    if field[end:].strip(b"\x00"):
        raise g5("tar-header", "bytes after the %s terminator" % what)
    return bytes(field[:end])


def parse_pax(data):
    out = {}
    pos = 0
    while pos < len(data):
        space = data.find(b" ", pos)
        if space <= pos or not data[pos:space].isdigit():
            raise g5("tar-unsupported", "malformed PAX record")
        length = int(data[pos:space])
        record = data[pos:pos + length]
        if length <= space - pos + 1 or len(record) != length or not record.endswith(b"\n"):
            raise g5("tar-unsupported", "malformed PAX record")
        key, eq, value = record[space - pos + 1:-1].partition(b"=")
        key = key.decode("ascii", "replace")
        if not eq or key not in PAX_KEYS:
            raise g5("tar-unsupported", "PAX key " + shown(key))
        if key in out:
            raise g5("tar-unsupported", "PAX key repeated " + shown(key))
        out[key] = value
        pos += length
    return out


def read_tar(src, policy):
    """Parse every entry of the opened tar and hash every byte of it.

    Returns (files, dirs): files maps name -> (bytes, sha256) for regular
    members, dirs is the set of directory entry names.
    """
    blocks = Blocks(src)
    files, dirs, seen = {}, set(), set()
    pending_long = pending_pax = None
    while True:
        header = blocks.take(BLOCK)
        if len(header) < BLOCK:
            raise g5("tar-truncated", "no end-of-archive marker")
        if header == ZERO_CHUNK[:BLOCK]:
            if pending_long is not None or pending_pax is not None:
                raise g5("tar-truncated", "a long-name or PAX header with no member")
            if blocks.take(BLOCK) != ZERO_CHUNK[:BLOCK]:
                raise g5("tar-trailing-data", "data after a single zero block")
            while True:
                rest = blocks.take(CHUNK)
                if not rest:
                    break
                if rest != ZERO_CHUNK[:len(rest)]:
                    raise g5("tar-trailing-data", "non-zero bytes after the end-of-archive marker")
            if src.offset % BLOCK:
                raise g5("tar-truncated", "length is not a whole number of 512-byte blocks")
            return files, dirs
        stored = octal(header[148:156], "checksum")
        if sum(header[:148]) + 256 + sum(header[156:]) != stored:
            raise g5("tar-checksum", "entry %d" % (len(seen) + 1))
        magic = bytes(header[257:265])
        if magic not in (POSIX_MAGIC, GNU_MAGIC):
            raise g5("tar-unsupported", "header format is neither POSIX ustar nor GNU")
        kind = header[156:157]
        size = octal(header[124:136], "size")
        if kind in (b"L", b"x"):
            if (kind == b"L") != (magic == GNU_MAGIC):
                raise g5("tar-unsupported", "type %s in a %s header" % (kind.decode(), "GNU" if magic == GNU_MAGIC else "POSIX"))
            if pending_long is not None or pending_pax is not None:
                raise g5("tar-unsupported", "more than one long-name or PAX header for one member")
            if size > META_MAX_BYTES:
                raise g5("tar-unsupported", "long-name or PAX header over %d bytes" % META_MAX_BYTES)
            data = blocks.take(size)
            pad = blocks.take(-size % BLOCK)
            if len(data) < size or len(pad) < -size % BLOCK:
                raise g5("tar-truncated", "inside a long-name or PAX header")
            if pad.strip(b"\x00"):
                raise g5("tar-padding", "non-zero padding after a long-name or PAX header")
            if kind == b"L":
                pending_long = cstring(data, "long name")
                if not pending_long:
                    raise g5("tar-unsafe-name", "empty long name")
            else:
                pending_pax = parse_pax(data)
            continue
        if kind in (b"1", b"2"):
            raise g5("tar-link", "a hard or symbolic link entry")
        if kind not in (b"0", b"\x00", b"5"):
            raise g5("tar-unsupported", "entry type " + shown(kind))
        if header[157:257].strip(b"\x00"):
            raise g5("tar-link", "a link target on a regular or directory entry")
        name = cstring(header[0:100], "name")
        if magic == POSIX_MAGIC:
            prefix = cstring(header[345:500], "prefix")
            if prefix:
                name = prefix + b"/" + name
        if pending_long is not None:
            if not pending_long.startswith(name):
                raise g5("tar-unsafe-name", "the header name is not a prefix of the long name")
            name, pending_long = pending_long, None
        if pending_pax is not None:
            pax, pending_pax = pending_pax, None
            if "path" in pax:
                if not pax["path"].startswith(name):
                    raise g5("tar-unsafe-name", "the header name is not a prefix of the PAX path")
                name = pax["path"]
            if "size" in pax:
                if not pax["size"].isdigit():
                    raise g5("tar-header", "malformed PAX size")
                pax_size = int(pax["size"])
                if pax_size > SIZE_MAX or (size != pax_size and not (size == 0 and pax_size >= 8 ** 11)):
                    raise g5("tar-header", "the PAX size disagrees with the header size")
                size = pax_size
        if kind == b"5":
            if size:
                raise g5("tar-unsupported", "a directory entry with data")
            if name.endswith(b"/"):
                name = name[:-1]
        try:
            text = name.decode("utf-8")
        except UnicodeDecodeError:
            raise g5("tar-unsafe-name", shown(name) + " is not UTF-8")
        why = check_name(text)
        if why is not None:
            raise g5("tar-unsafe-name", shown(text) + " " + why)
        if text in seen:
            raise g5("tar-duplicate", shown(text))
        seen.add(text)
        if kind == b"5":
            if policy != "ancestors":
                raise g5("tar-directory", shown(text) + ": the layout admits no directory entries")
            dirs.add(text)
            continue
        member = hashlib.sha256()
        if not blocks.stream(size, member.update):
            raise g5("tar-truncated", "inside member " + shown(text))
        pad = blocks.take(-size % BLOCK)
        if len(pad) < -size % BLOCK:
            raise g5("tar-truncated", "inside the padding of " + shown(text))
        if pad.strip(b"\x00"):
            raise g5("tar-padding", "non-zero padding after " + shown(text))
        files[text] = (size, member.hexdigest())


def compare(side, found_files, found_dirs, expected, allowed_dirs):
    """Both directions: every found entry expected, every expected member found, equal."""
    for name in sorted(found_files):
        if name not in expected:
            raise g5(side + "-extra-member", shown(name))
    for name in sorted(found_dirs):
        if name not in allowed_dirs:
            raise g5(side + "-extra-member", shown(name) + "/")
    for name in sorted(expected):
        if name not in found_files:
            raise g5(side + "-missing-member", shown(name))
        size, sha = found_files[name]
        want_size, want_sha = expected[name]
        if size != want_size:
            raise g5(side + "-member-size", "%s: %d bytes, expected %d" % (shown(name), size, want_size))
        if sha != want_sha:
            raise g5(side + "-member-digest", shown(name))


def hash_whole(src):
    while src.read(CHUNK):
        pass
    return src.digest.hexdigest()


def strip_prefix(path, prefix, prefix_dirs):
    """Image path -> member name, or None for the prefix's own directories."""
    if path in prefix_dirs:
        return None
    if not prefix:
        return path
    if path.startswith(prefix + "/"):
        return path[len(prefix) + 1:]
    return False


def read_image_mount(image, prefix, expected, member_dirs):
    """Walk a new read-only squashfuse mount of the opened image."""
    mnt = tempfile.mkdtemp(prefix="fm-pack-parity.")
    view = "/proc/self/fd/%d" % image.fd
    mounted = False
    try:
        try:
            run = subprocess.run(["squashfuse", "-o", "ro", view, mnt], pass_fds=(image.fd,),
                                 stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                                 stderr=subprocess.PIPE, timeout=120)
        except (OSError, subprocess.TimeoutExpired) as exc:
            raise ReadFailure(1, "fm-pack: refused: G5: image-read: squashfuse: " + shown(str(exc)))
        if run.returncode != 0:
            raise ReadFailure(1, "fm-pack: refused: G5: image-read: squashfuse could not mount the image")
        mounted = True
        return walk_mount(mnt, prefix, expected, member_dirs)
    finally:
        if mounted:
            for args in (["fusermount3", "-u", mnt], ["fusermount3", "-uz", mnt]):
                try:
                    if subprocess.run(args, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                                      stderr=subprocess.DEVNULL, timeout=60).returncode == 0:
                        break
                except (OSError, subprocess.TimeoutExpired):
                    pass
        try:
            os.rmdir(mnt)
        except OSError:
            pass


def walk_mount(mnt, prefix, expected, member_dirs):
    files, dirs = {}, set()
    limit = len(expected) + len(member_dirs) + prefix.count("/") + 1
    stack = [""]
    try:
        while stack:
            rel = stack.pop()
            with os.scandir(os.path.join(mnt, rel) if rel else mnt) as entries:
                for entry in entries:
                    path = rel + "/" + entry.name if rel else entry.name
                    if len(files) + len(dirs) >= limit:
                        raise g5("image-extra-member", shown(path))
                    st = os.lstat(os.path.join(mnt, path))
                    if stat.S_ISDIR(st.st_mode):
                        dirs.add(path)
                        stack.append(path)
                    elif stat.S_ISREG(st.st_mode):
                        files[path] = hash_file(os.path.join(mnt, path))
                    else:
                        raise g5("image-member-type", shown(path) + " is not a regular file or directory")
    except OSError as exc:
        raise ReadFailure(1, "fm-pack: refused: G5: image-read: " + shown(exc.strerror or str(exc)))
    return files, dirs


def hash_file(path):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC)
    try:
        digest, size = hashlib.sha256(), 0
        while True:
            data = os.read(fd, CHUNK)
            if not data:
                return size, digest.hexdigest()
            digest.update(data)
            size += len(data)
    finally:
        os.close(fd)


def read_image_unsquashfs(image, prefix, expected, member_dirs):
    """unsquashfs -lln for the entries, one unsquashfs -cat per regular file."""
    view = "/proc/self/fd/%d" % image.fd
    try:
        run = subprocess.run(["unsquashfs", "-lln", view], pass_fds=(image.fd,), stdin=subprocess.DEVNULL,
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=600)
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise ReadFailure(1, "fm-pack: refused: G5: image-read: unsquashfs: " + shown(str(exc)))
    if run.returncode != 0:
        raise ReadFailure(1, "fm-pack: refused: G5: image-read: unsquashfs -lln failed")
    regular, dirs = set(), set()
    for line in run.stdout.split(b"\n")[:-1]:
        if line[:1] not in (b"-", b"d"):
            raise g5("image-member-type", shown(line) + ": not a regular file or directory")
        match = LISTING_RE.match(line)
        if match is None:
            raise g5("image-read", "unparsable listing line " + shown(line))
        kind, path = match.group(1), match.group(2)
        if path == b"squashfs-root":
            continue
        if not path.startswith(b"squashfs-root/"):
            raise g5("image-read", "unparsable listing line " + shown(line))
        path = os.fsdecode(path[len(b"squashfs-root/"):])
        if kind == b"d":
            dirs.add(path)
        else:
            regular.add(path)
    files = {}
    for path in sorted(regular):
        name = strip_prefix(path, prefix, ())
        # An unexpected file is not read; compare() refuses it by name.
        files[path] = cat_member(view, image.fd, path) if name in expected else (None, None)
    return files, dirs


def cat_member(view, fd, path):
    digest, size = hashlib.sha256(), 0
    try:
        proc = subprocess.Popen(["unsquashfs", "-no-wildcards", "-cat", view, path], pass_fds=(fd,),
                                stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    except OSError as exc:
        raise ReadFailure(1, "fm-pack: refused: G5: image-read: unsquashfs: " + shown(str(exc)))
    try:
        while True:
            data = proc.stdout.read(CHUNK)
            if not data:
                break
            digest.update(data)
            size += len(data)
    finally:
        proc.stdout.close()
        rc = proc.wait()
    if rc != 0:
        raise ReadFailure(1, "fm-pack: refused: G5: image-read: unsquashfs -cat failed for " + shown(path))
    return size, digest.hexdigest()


def image_view(files, dirs, prefix):
    """Image paths -> (member files, member directories), refusing anything outside the prefix."""
    prefix_dirs = set(ancestors(prefix) + [prefix]) if prefix else set()
    out_files, out_dirs = {}, set()
    for path, value in files.items():
        name = strip_prefix(path, prefix, prefix_dirs)
        if not name:
            raise g5("image-extra-member", shown(path))
        out_files[name] = value
    for path in dirs:
        name = strip_prefix(path, prefix, prefix_dirs)
        if name is False:
            raise g5("image-extra-member", shown(path) + "/")
        if name is not None:
            out_dirs.add(name)
    missing = prefix_dirs - dirs
    if missing:
        raise g5("image-missing-member", shown(min(missing)) + "/")
    return out_files, out_dirs


def health(tool):
    """True only when D: health proves a temporary offline state; the reason then."""
    try:
        run = subprocess.run([tool, "health", "--volume", "d"], stdin=subprocess.DEVNULL,
                             stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=HEALTH_TIMEOUT)
    except (OSError, subprocess.TimeoutExpired):
        return None
    match = re.match(rb"\Aoffline ([!-~][ -~]{0,199})\n\Z", run.stdout)
    if run.returncode != 75 or match is None:
        return None
    return match.group(1).decode("ascii")


def run_hook():
    hook = os.environ.get("FM_PACK_TEST_BEFORE_RECHECK", "")
    if hook:
        subprocess.run(["bash", "-c", hook], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                       stderr=subprocess.DEVNULL)


def parse_argv(argv):
    reader = tool = None
    while argv and argv[0] in ("--reader", "--storage-tool"):
        if len(argv) < 2:
            raise usage(argv[0] + " needs a value")
        if argv[0] == "--reader":
            reader = argv[1]
        else:
            tool = argv[1]
        argv = argv[2:]
    if reader not in ("mount", "unsquashfs") or not tool:
        raise usage("internal: --reader mount|unsquashfs and --storage-tool are required")
    if not argv or argv[0].startswith("--"):
        raise usage("verify-tar needs IMAGE --tar TAR --expect EXPECTATION.json")
    image, opts, rest = argv[0], {}, argv[1:]
    while rest:
        if rest[0] not in ("--tar", "--expect") or len(rest) < 2:
            raise usage("verify-tar needs IMAGE --tar TAR --expect EXPECTATION.json, not " + shown(rest[0]))
        if rest[0] in opts:
            raise usage(rest[0] + " given twice")
        opts[rest[0]] = rest[1]
        rest = rest[2:]
    if set(opts) != {"--tar", "--expect"} or not all(opts.values()) or not image:
        raise usage("verify-tar needs IMAGE --tar TAR --expect EXPECTATION.json")
    return reader, tool, image, opts["--tar"], opts["--expect"]


def verify(reader, image_path, tar_path, expect_path):
    with_expect = Source("expectation", expect_path)
    try:
        if with_expect.size > EXPECT_MAX_BYTES:
            raise bad_expect("larger than %d bytes" % EXPECT_MAX_BYTES)
        raw = bytearray()
        while True:
            data = with_expect.read(CHUNK)
            if not data:
                break
            raw += data
            if len(raw) > EXPECT_MAX_BYTES:
                raise bad_expect("larger than %d bytes" % EXPECT_MAX_BYTES)
    finally:
        with_expect.close()
    doc, expected, member_dirs = load_expectation(bytes(raw))
    prefix = doc["layout"]["image_prefix"]
    tar = Source("tar", tar_path)
    image = None
    try:
        image = Source("image", image_path)
        tar_files, tar_dirs = read_tar(tar, doc["layout"]["tar_directories"])
        tar_sha = tar.digest.hexdigest()
        if tar_sha != doc["tar_sha256"]:
            raise g5("tar-digest", "the tar's sha256 is %s, expected %s" % (tar_sha, doc["tar_sha256"]))
        compare("tar", tar_files, tar_dirs, expected, member_dirs)
        image_sha = hash_whole(image)
        if image_sha != doc["image_sha256"]:
            raise g5("image-digest", "the image's sha256 is %s, expected %s" % (image_sha, doc["image_sha256"]))
        read_image = read_image_mount if reader == "mount" else read_image_unsquashfs
        found_files, found_dirs = read_image(image, prefix, expected, member_dirs)
        img_files, img_dirs = image_view(found_files, found_dirs, prefix)
        compare("image", img_files, img_dirs, expected, member_dirs)
        run_hook()
        tar.recheck()
        image.recheck()
    finally:
        tar.close()
        if image is not None:
            image.close()
    return "%s tar_sha256=%s image_sha256=%s members=%d" % (RESULT, tar_sha, image_sha, len(expected))


def interrupt(signum, _frame):
    raise Interrupted(signum)


def main(argv):
    signal.signal(signal.SIGTERM, interrupt)
    signal.signal(signal.SIGINT, interrupt)
    tool = None
    try:
        reader, tool, image, tar, expect = parse_argv(argv)
        line = verify(reader, image, tar, expect)
    except Interrupted as exc:
        sys.stderr.write("fm-pack: refused: G5: interrupted: signal %d\n" % exc.args[0])
        return 1
    except Outcome as exc:
        sys.stderr.write(exc.line + "\n")
        return exc.rc
    except ReadFailure as exc:
        reason = health(tool) if tool else None
        if reason is not None:
            sys.stderr.write("fm-pack: wait: storage-offline: " + reason + "\n")
            return 75
        sys.stderr.write(exc.line + "\n")
        return exc.rc
    except Exception as exc:  # noqa: BLE001 - any unforeseen failure is a refusal, never parity
        sys.stderr.write("fm-pack: refused: G5: internal-error: " + shown(type(exc).__name__ + ": " + str(exc)) + "\n")
        return 1
    sys.stdout.write(line + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
