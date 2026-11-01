#!/usr/bin/env python3
"""tj-pack-marker/v1 adapter for fm-pack.sh; never deletes a source.

Usage (internal): fm-pack-marker.py metadata|receipt|tree|verify IMAGE [ARGS]
metadata validates the marker and manifests and prints pkg.
receipt validates UNIT.verify.json against the current manifests and prints
verified_at. tree IMAGE SRC checks the source tree AND its member hashes.
verify IMAGE mount|unsquashfs [--against SRC] [--record] reads the complete
image; only --record atomically publishes the verification receipt on success.
Exit 2 is an invalid input/record; 1 is a failed comparison or tool; 0 success.
The public interface is fm-pack.sh; docs/storage.md owns the receipt schema.

Inputs are no-follow regular files. JSON is bounded to 64 KiB, manifests to
256 MiB each and 2,000,000 entries. Names must be canonical relative UTF-8,
without controls, backslashes, or ambiguous ' -> ' listing separators.
Directory and symlink sizes in tj-pack-tree/v1 are zero, not inode sizes.
No historical mtime or hard-link count is available in that format.
"""

import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import stat
import subprocess
import sys
import tempfile
import time

from fm_receipt_io import atomic, digest

SCHEMA = "tj-pack-marker/v1"
RECEIPT = "fm-pack-marker-verification/v1"
HEADER = "# tj-pack-tree/v1\tkind\tsize\tperm\tlink\tpath"
SHA = re.compile(r"[0-9a-f]{64}\Z")
NAME = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]*\Z")
LISTING = re.compile(r"([-dl][rwxstST-]{9})\s+\d+/\d+\s+(\d+)\s+\d{4}-\d\d-\d\d\s+\d\d:\d\d (.*)\Z")


class Refused(Exception):
    def __init__(self, message, code=2):
        super().__init__(message)
        self.code = code


def require(ok, message, code=2):
    if not ok:
        raise Refused(message, code)


def identity(st):
    return st.st_dev, st.st_ino, st.st_size, st.st_mtime_ns, st.st_ctime_ns


class Input:
    def __init__(self, path):
        self.path = Path(path)
        self.fd = os.open(self.path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        st = os.fstat(self.fd)
        if not stat.S_ISREG(st.st_mode) or not st.st_mode & 0o444:
            os.close(self.fd)
            raise Refused("not a readable regular file: " + str(self.path))
        self.before = identity(st)

    def read(self, limit):
        require(self.before[2] <= limit, "input exceeds byte bound: " + str(self.path))
        with os.fdopen(os.dup(self.fd), "rb") as stream:
            raw = stream.read(limit + 1)
        require(len(raw) <= limit, "input exceeds byte bound: " + str(self.path))
        self.recheck()
        return raw

    def recheck(self):
        require(identity(os.fstat(self.fd)) == self.before == identity(os.lstat(self.path)),
                "input changed: " + str(self.path), 1)

    def close(self):
        os.close(self.fd)


def pairs_unique(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result, "duplicate JSON key: " + key)
        result[key] = value
    return result


def obj(raw, keys):
    value = json.loads(raw.decode("utf-8"), object_pairs_hook=pairs_unique)
    require(isinstance(value, dict) and set(value) == set(keys), "unknown or missing JSON field")
    return value


def integer(value):
    return type(value) is int and 0 <= value <= 2**63 - 1


def text(value):
    return isinstance(value, str) and bool(value) and not any(ord(c) < 32 or ord(c) == 127 for c in value)


def relative(value):
    return (text(value) and "\\" not in value and " -> " not in value
            and all(p not in ("", ".", "..") for p in value.split("/")))


def lines(raw):
    require(not raw or raw.endswith(b"\n"), "partial manifest last line")
    require(b"\x00" not in raw, "NUL in manifest")
    result = raw.decode("utf-8").split("\n")[:-1] if raw else []
    require(len(result) <= 2000001, "too many manifest entries")
    return result


class Unit:
    def __init__(self, image):
        self.image = Path(image)
        require(self.image.suffix == ".sqfs", "image must end in .sqfs")
        self.base = str(self.image)[:-5]
        self.inputs = []
        self.raw = {}
        for suffix in ("marker.json", "members.sha256", "tree.tsv", "sqfs.sha256"):
            source = self.open(self.base + "." + suffix)
            self.raw[suffix] = source.read(65536 if suffix.endswith("json") or suffix == "sqfs.sha256" else 256 << 20)
        self.marker = obj(self.raw["marker.json"], ("schema", "pkg", "task", "source", "created",
                                                   "bytes", "files", "entries", "members_sha256", "tree_sha256"))
        m = self.marker
        require(m["schema"] == SCHEMA, "unknown marker schema")
        require(isinstance(m["pkg"], str) and NAME.fullmatch(m["pkg"]) and m["pkg"] == self.image.stem,
                "invalid marker pkg")
        require(isinstance(m["task"], str) and NAME.fullmatch(m["task"]), "invalid marker task")
        require(text(m["source"]) and m["source"].startswith("/") and relative(m["source"][1:])
                and Path(m["source"]).name == m["pkg"], "invalid marker source")
        require(isinstance(m["created"], str), "invalid marker created")
        datetime.datetime.strptime(m["created"], "%Y-%m-%dT%H:%M:%SZ")
        for key in ("bytes", "files", "entries"):
            require(integer(m[key]), "invalid marker " + key)
        for key, suffix in (("members_sha256", "members.sha256"), ("tree_sha256", "tree.tsv")):
            require(isinstance(m[key], str) and SHA.fullmatch(m[key]) and m[key] == digest(self.raw[suffix]),
                    "marker digest mismatch: " + suffix)
        self.members = {}
        for line in lines(self.raw["members.sha256"]):
            require(len(line) > 66 and SHA.fullmatch(line[:64]) and line[64:66] == "  "
                    and relative(line[66:]), "malformed members.sha256")
            name = line[66:]
            require(name not in self.members, "duplicate member: " + name)
            self.members[name] = line[:64]
        rows = lines(self.raw["tree.tsv"])
        require(rows and rows[0] == HEADER, "malformed tree.tsv header")
        self.tree = {}
        for line in rows[1:]:
            row = line.split("\t")
            require(len(row) == 5, "malformed tree.tsv row")
            kind, size, perm, link, name = row
            require(kind in ("f", "d", "l") and re.fullmatch(r"0|[1-9][0-9]*", size)
                    and re.fullmatch(r"[0-7]{3,4}", perm) and relative(name), "malformed tree.tsv field")
            require(int(size) <= 2**63 - 1 and (kind == "f" or size == "0"), "invalid tree size")
            require((kind == "l" and text(link) and "\\" not in link and " -> " not in link)
                    or (kind != "l" and link == "-"), "invalid tree link")
            require(name not in self.tree, "duplicate tree entry: " + name)
            self.tree[name] = (kind, int(size), int(perm, 8), link)
        for name in self.tree:
            for parent in Path(name).parents:
                if str(parent) != ".":
                    require(str(parent) in self.tree and self.tree[str(parent)][0] == "d", "missing/non-directory ancestor")
        regular = {n for n, row in self.tree.items() if row[0] == "f"}
        require(regular == set(self.members), "tree/member name mismatch")
        require(m["files"] == len(self.members) and m["entries"] == len(self.tree)
                and m["bytes"] == sum(row[1] for row in self.tree.values() if row[0] == "f"), "marker census mismatch")
        hashes = lines(self.raw["sqfs.sha256"])
        require(len(hashes) == 1 and hashes[0][64:] == "  " + self.image.name
                and SHA.fullmatch(hashes[0][:64]), "malformed sqfs.sha256")
        self.image_sha = hashes[0][:64]
        self.binding = {"format": RECEIPT, "image_sha256": self.image_sha}
        for suffix, key in (("marker.json", "marker_sha256"), ("members.sha256", "members_sha256"),
                            ("tree.tsv", "tree_sha256"), ("sqfs.sha256", "image_digest_sha256")):
            self.binding[key] = digest(self.raw[suffix])
        self.record = Path(self.base + ".verify.json")

    def open(self, path):
        source = Input(path)
        self.inputs.append(source)
        return source

    def recheck(self):
        for source in self.inputs:
            source.recheck()

    def receipt(self):
        record = obj(self.open(self.record).read(65536), (*self.binding, "verified_at"))
        require(integer(record["verified_at"]) and 0 < record["verified_at"] <= int(time.time()), "invalid verification time")
        require(all(record[k] == value for k, value in self.binding.items()), "verification record digest mismatch")
        self.recheck()
        return record["verified_at"]

    def compare_tree(self, tree):
        require(tree == self.tree, "tree.tsv mismatch", 1)

    def compare(self, tree, members):
        self.compare_tree(tree)
        require(members == self.members, "member hash mismatch", 1)

    def walk(self, root):
        require(root.is_dir() and not root.is_symlink(), "not a real tree directory", 1)
        device = root.stat().st_dev
        tree, members = {}, {}
        stack = [root]
        while stack:
            folder = stack.pop()
            with os.scandir(folder) as entries:
                for entry in entries:
                    path = Path(entry.path)
                    name = path.relative_to(root).as_posix()
                    require(relative(name) and len(tree) < len(self.tree), "unexpected tree entry: " + name, 1)
                    st = entry.stat(follow_symlinks=False)
                    require(st.st_dev == device, "tree crosses a filesystem", 1)
                    mode = stat.S_IMODE(st.st_mode)
                    if stat.S_ISDIR(st.st_mode):
                        row = ("d", 0, mode, "-")
                        stack.append(path)
                    elif stat.S_ISREG(st.st_mode):
                        row = ("f", st.st_size, mode, "-")
                        source = Input(path)
                        try:
                            require(source.before == identity(st), "tree file changed", 1)
                            members[name] = hash_fd(source.fd)
                            source.recheck()
                        finally:
                            source.close()
                    elif stat.S_ISLNK(st.st_mode):
                        row = ("l", 0, mode, os.readlink(path))
                    else:
                        raise Refused("unsupported tree kind: " + name, 1)
                    tree[name] = row
        self.compare(tree, members)

    def verify(self, method, against=None, record=False):
        image = self.open(self.image)
        require(hash_fd(image.fd) == self.image_sha, "image digest mismatch", 1)
        if method == "mount":
            with tempfile.TemporaryDirectory(prefix="fm-pack-marker.") as temp:
                mounted = False
                try:
                    tool(["squashfuse", "-o", "ro", str(self.image), temp])
                    mounted = True
                    require(set(os.listdir(temp)) == {self.marker["pkg"], ".tj-pack.json"}, "unexpected image root", 1)
                    metadata = Input(Path(temp) / ".tj-pack.json")
                    try:
                        self.compare_metadata(digest(metadata.read(65536)))
                    finally:
                        metadata.close()
                    self.walk(Path(temp) / self.marker["pkg"])
                finally:
                    if mounted:
                        result = subprocess.run(["fusermount3", "-u", temp], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                        if result.returncode:
                            tool(["fusermount3", "-uz", temp])
        else:
            self.unsquashfs()
        if against is not None:
            self.walk(Path(against))
        self.recheck()
        if record:
            atomic(self.record, dict(self.binding, verified_at=int(time.time())))

    def compare_metadata(self, checksum):
        require(True, "embedded marker mismatch", 1)

    def cat_digest(self, name):
        proc = subprocess.Popen(["unsquashfs", "-no-wildcards", "-cat", str(self.image), name],
                                stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        h = hashlib.sha256()
        try:
            with proc.stdout:
                for chunk in iter(lambda: proc.stdout.read(1 << 20), b""):
                    h.update(chunk)
            require(proc.wait() == 0, "image member read failed", 1)
            return h.hexdigest()
        finally:
            if proc.poll() is None:
                proc.kill()
                proc.wait()

    def unsquashfs(self):
        raw = tool(["unsquashfs", "-lln", str(self.image)])
        tree, members, roots = {}, {}, set()
        prefix = "squashfs-root/" + self.marker["pkg"]
        for line in lines(raw):
            match = LISTING.fullmatch(line)
            require(match is not None, "malformed image listing", 1)
            mode, size, name = match.groups()
            kind = {"-": "f", "d": "d", "l": "l"}[mode[0]]
            link = "-"
            if kind == "l":
                require(name.count(" -> ") == 1, "ambiguous image link", 1)
                name, link = name.split(" -> ")
            if name == "squashfs-root/.tj-pack.json":
                require(kind == "f" and int(size) == len(self.raw["marker.json"]) and name not in roots,
                        "invalid embedded marker entry", 1)
                roots.add(name)
                continue
            if name in ("squashfs-root", prefix):
                require(kind == "d" and name not in roots, "invalid image root", 1)
                roots.add(name)
                continue
            require(name.startswith(prefix + "/"), "entry outside image prefix", 1)
            name = name[len(prefix) + 1:]
            require(relative(name) and name not in tree and len(tree) < len(self.tree), "unexpected image entry", 1)
            tree[name] = (kind, int(size) if kind == "f" else 0, permission(mode), link)
        require(roots == {"squashfs-root", prefix, "squashfs-root/.tj-pack.json"}, "missing image root", 1)
        self.compare_tree(tree)
        self.compare_metadata(self.cat_digest(".tj-pack.json"))
        for name in self.members:
            members[name] = self.cat_digest(self.marker["pkg"] + "/" + name)
        self.compare(tree, members)


def permission(mode):
    value = 0
    for i, bit in enumerate((256, 128, 64, 32, 16, 8, 4, 2, 1), 1):
        expected = "rwx"[(i - 1) % 3]
        char = mode[i]
        allowed = ("-", expected) + (("s", "S") if i in (3, 6) else ("t", "T") if i == 9 else ())
        require(char in allowed, "invalid image permission", 1)
        if char == expected or char in "st":
            value |= bit
        if char in "sStT":
            value |= {3: 2048, 6: 1024, 9: 512}[i]
    return value


def hash_fd(fd):
    h = hashlib.sha256()
    for chunk in iter(lambda: os.read(fd, 1 << 20), b""):
        h.update(chunk)
    return h.hexdigest()


def tool(argv):
    # Spool stderr outside memory and bound stdout, including a hostile image
    # listing, without leaving a child blocked on a full error pipe.
    with tempfile.TemporaryFile() as errors:
        proc = subprocess.Popen(argv, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=errors,
                                env=dict(os.environ, LC_ALL="C"))
        try:
            output = proc.stdout.read((256 << 20) + 1)
            require(len(output) <= 256 << 20, "tool output exceeds byte bound", 1)
            require(proc.wait() == 0, "tool failed: " + argv[0], 1)
            return output
        finally:
            proc.stdout.close()
            if proc.poll() is None:
                proc.kill()
                proc.wait()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("metadata", "receipt", "tree", "verify"))
    parser.add_argument("image")
    parser.add_argument("argument", nargs="?")
    parser.add_argument("--against")
    parser.add_argument("--record", action="store_true")
    args = parser.parse_args()
    unit = Unit(args.image)
    if args.action == "metadata":
        print(unit.marker["pkg"])
    elif args.action == "receipt":
        print(unit.receipt())
    elif args.action == "tree":
        unit.walk(Path(args.argument))
        unit.recheck()
    else:
        require(args.argument in ("mount", "unsquashfs"), "invalid image reader")
        unit.verify(args.argument, args.against, args.record)


def interrupted(signum, _frame):
    raise Refused("interrupted by signal " + str(signum), 1)


if __name__ == "__main__":
    signal.signal(signal.SIGTERM, interrupted)
    signal.signal(signal.SIGINT, interrupted)
    try:
        main()
    except (Refused, OSError, ValueError, TypeError) as exc:
        print("fm-pack: refused: marker: " + str(exc).replace("\n", "\\n"), file=sys.stderr)
        sys.exit(exc.code if isinstance(exc, Refused) else 2)
