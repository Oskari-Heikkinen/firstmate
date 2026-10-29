#!/usr/bin/env python3
"""fm-repack.py - the work behind bin/fm-repack.sh (plan, run, baseline).

bin/fm-repack.sh owns the usage text, the exit codes and the environment;
docs/disk-room.md "Repacking cold trees" owns why and when. This file owns the
per-file protocol, which is the whole safety design:

  1. lstat the path: a regular file, one link, owned by this user (or run as
     root), size above 0, unchanged since the scan (inode, size, mtime, ctime).
  2. open it read-only without following a link, and take a write lease
     (F_SETLEASE F_WRLCK). The kernel grants it only when no other open file
     description exists, so an open file is skipped, and any later open by
     another process shows up as a lease break, which aborts the file.
  3. refuse inode flags other than extents (immutable, append-only, ...).
  4. journal the temporary name, create it O_EXCL in the same directory, copy
     in 1 MiB chunks (checking the lease after each), fsync, set owner, mode,
     xattrs, atime and mtime, fsync again, then compare every byte and the
     metadata of the copy against the original.
  5. lstat the path again: same inode, size, mtime and ctime, lease unbroken.
  6. renameat2(RENAME_EXCHANGE): the path now holds the verified copy and the
     temporary name holds the original. When the lease broke during the
     exchange (another process was opening the original), exchange back, so
     that process keeps the linked original.
  7. unlink the temporary name, release the lease, record the copy's inode and
     mtime in the ledger, end the journal entry.

A crash at any step leaves the path holding the original or the verified copy;
the next run removes the journalled temporary name, which holds either a
partial copy or the original that a verified copy already replaced.
"""

import ctypes
import errno
import fcntl
import json
import math
import os
import re
import shutil
import signal
import stat
import struct
import subprocess
import sys
import time

AGE_DAYS = 7
CHUNK = 1 << 20
MIB = 1 << 20
GIB = 1 << 30
F_SETLEASE = 1024
F_GETLEASE = 1025
FS_IOC_GETFLAGS = 0x80086601
FS_IOC_FIEMAP = 0xC020660B
EXTENTS_FL = 0x00080000
RENAME_EXCHANGE = 2
AT_FDCWD = -100
TMP_RE = re.compile(r"^\.fm-repack-[0-9]+-[0-9]+\.tmp$")
EXIT_FAILED, EXIT_USAGE, EXIT_WAIT = 1, 2, 75
SKIP_ORDER = ("young", "baseline", "repacked", "empty", "hard-linked", "not-owned", "sqlite",
              "name", "other-device", "open", "changed", "inode-flags", "metadata",
              "directory", "opened-during-swap", "vanished", "interrupted")
DIR_SKIPS = ("state", "git", "other-device", "unreadable")


class Refusal(Exception):
    """A precondition or configuration fault: exit 2 with one line."""


class FileSkip(Exception):
    def __init__(self, reason, detail=""):
        Exception.__init__(self, reason)
        self.reason, self.detail = reason, detail


class FileFailed(Exception):
    """An unexpected error that stops the batch."""


def env(name, default=""):
    return os.environ.get(name, default)


def now():
    raw = env("FM_REPACK_NOW")
    if raw:
        if not raw.isdigit():
            raise Refusal("FM_REPACK_NOW is not an epoch: %r" % raw)
        return int(raw)
    return int(time.time())


def utc(epoch):
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(epoch))


def say(text):
    sys.stdout.write("fm-repack: %s\n" % text)
    sys.stdout.flush()


def gib(n):
    return "%.2f" % (n / GIB)


# State: HOME/state/fm-repack/ holds the lock, the ledger, the journal, the
# baseline, the log and the per-run directories.

class State:
    def __init__(self, home):
        self.home = home
        self.dir = os.path.join(home, "state", "fm-repack")
        self.ledger = os.path.join(self.dir, "repacked.tsv")
        self.journal = os.path.join(self.dir, "journal.jsonl")
        self.baseline = os.path.join(self.dir, "baseline")
        self.logfile = os.path.join(self.dir, "log")
        self.lockfile = os.path.join(self.dir, "lock")

    def ensure(self):
        os.makedirs(self.dir, exist_ok=True)

    def log(self, text):
        try:
            self.ensure()
            with open(self.logfile, "a", encoding="utf-8", errors="surrogateescape") as f:
                f.write("%s %s\n" % (utc(int(time.time())), text))
        except OSError as e:
            sys.stderr.write("fm-repack: cannot append to %s: %s\n" % (self.logfile, e.strerror))

    def read_baseline(self):
        try:
            with open(self.baseline, encoding="utf-8") as f:
                text = f.read()
        except FileNotFoundError:
            return None
        except OSError as e:
            raise Refusal("cannot read %s: %s" % (self.baseline, e.strerror))
        first = text.split("\n", 1)[0].strip()
        if not first.isdigit():
            raise Refusal("%s does not hold an epoch on its first line" % self.baseline)
        return int(first)

    def read_ledger(self):
        """-> list of (ino, mtime_ns) in file order; a malformed line refuses."""
        out = []
        try:
            with open(self.ledger, encoding="ascii") as f:
                for n, line in enumerate(f, 1):
                    parts = line.rstrip("\n").split("\t")
                    if len(parts) != 2 or not parts[0].isdigit() or not parts[1].lstrip("-").isdigit():
                        raise Refusal("%s line %d is not 'inode<TAB>mtime_ns'" % (self.ledger, n))
                    out.append((int(parts[0]), int(parts[1])))
        except FileNotFoundError:
            pass
        except (OSError, UnicodeDecodeError) as e:
            raise Refusal("cannot read %s: %s" % (self.ledger, getattr(e, "strerror", None) or e))
        return out


def write_atomic(path, text):
    tmp = "%s.%d.new" % (path, os.getpid())
    with open(tmp, "w", encoding="utf-8", errors="surrogateescape") as f:
        f.write(text)
        f.flush()
        os.fsync(f.fileno())
    os.rename(tmp, path)


# Trees: HOME/config/repack-trees, one directory per line.

def read_trees(home):
    path = os.path.join(home, "config", "repack-trees")
    try:
        with open(path, encoding="utf-8", errors="surrogateescape") as f:
            lines = f.read().split("\n")
    except FileNotFoundError:
        return []
    except OSError as e:
        raise Refusal("cannot read %s: %s" % (path, e.strerror))
    trees, seen = [], set()
    state_dir = os.path.realpath(os.path.join(home, "state"))
    for n, raw in enumerate(lines, 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        where = "%s line %d" % (path, n)
        if line.startswith("~/"):
            line = os.path.join(os.path.expanduser("~"), line[2:])
        elif not line.startswith("/"):
            line = os.path.join(home, line)
        if ".." in line.split("/"):
            raise Refusal("%s: %s has a .. component" % (where, raw.strip()))
        real = os.path.realpath(line)
        if not os.path.isdir(real):
            raise Refusal("%s: %s is not a directory" % (where, raw.strip()))
        if real == "/":
            raise Refusal("%s: the root directory cannot be a repack tree" % where)
        if real == state_dir or real.startswith(state_dir + "/") or "state" in real.split("/"):
            raise Refusal("%s: %s is inside a state/ directory" % (where, raw.strip()))
        if real not in seen:
            seen.add(real)
            trees.append(real)
    return trees


# The scan: every regular file in the listed trees, with the skips that a
# stat alone decides. Open files and inode flags are decided at run time.

class Scan:
    def __init__(self, trees, at, baseline, ledger_keys):
        self.trees = trees
        self.at = at
        self.cutoff_ns = (at - AGE_DAYS * 86400) * 10 ** 9
        self.baseline_ns = None if baseline is None else baseline * 10 ** 9
        self.ledger_keys = ledger_keys
        self.seen_ledger = set()
        self.uid = os.geteuid()
        self.skips = dict.fromkeys(SKIP_ORDER, 0)
        self.dir_skips = dict.fromkeys(DIR_SKIPS, 0)
        self.walk_errors = 0
        self.candidates = []  # dicts, per tree order
        self.per_tree = {t: [0, 0] for t in trees}  # files, bytes

    def run(self):
        seen = set()
        for tree in self.trees:
            root_dev = os.lstat(tree).st_dev
            stack = [tree]
            while stack:
                d = stack.pop()
                try:
                    with os.scandir(d) as it:
                        entries = list(it)
                except OSError:
                    self.dir_skips["unreadable"] += 1
                    self.walk_errors += 1
                    continue
                names = {e.name for e in entries}
                for e in entries:
                    try:
                        st = e.stat(follow_symlinks=False)
                    except OSError:
                        self.walk_errors += 1
                        continue
                    if stat.S_ISDIR(st.st_mode):
                        if st.st_dev != root_dev:
                            self.dir_skips["other-device"] += 1
                        elif e.name == "state":
                            self.dir_skips["state"] += 1
                        elif e.name == ".git" or (e.name == "objects" and "HEAD" in names and "refs" in names):
                            self.dir_skips["git"] += 1
                        else:
                            stack.append(e.path)
                        continue
                    if e.name == ".git":
                        continue  # a worktree's gitfile
                    if not stat.S_ISREG(st.st_mode):
                        continue
                    key = (st.st_dev, st.st_ino)
                    if key in seen:
                        continue
                    seen.add(key)
                    reason = self.skip_reason(e.path, e.name, st, root_dev)
                    if reason:
                        self.skips[reason] += 1
                        continue
                    self.candidates.append(dict(path=e.path, tree=tree, ino=st.st_ino, size=st.st_size,
                                                mtime_ns=st.st_mtime_ns, ctime_ns=st.st_ctime_ns,
                                                alloc=alloc_bytes(st)))
                    self.per_tree[tree][0] += 1
                    self.per_tree[tree][1] += st.st_size
        self.candidates.sort(key=lambda c: (c["mtime_ns"], c["path"]))
        return self

    def skip_reason(self, path, name, st, root_dev):
        if st.st_mtime_ns > self.cutoff_ns:
            return "young"
        if self.baseline_ns is not None and st.st_ctime_ns <= self.baseline_ns:
            return "baseline"
        lk = (st.st_ino, st.st_mtime_ns)
        if lk in self.ledger_keys:
            self.seen_ledger.add(lk)
            return "repacked"
        if st.st_size == 0:
            return "empty"
        if st.st_nlink != 1:
            return "hard-linked"
        if self.uid != 0 and st.st_uid != self.uid:
            return "not-owned"
        if name.endswith(("-wal", "-journal", "-shm")) or os.path.lexists(path + "-wal") \
                or os.path.lexists(path + "-journal"):
            return "sqlite"
        if TMP_RE.match(name) or "\n" in path:
            return "name"
        if st.st_dev != root_dev:
            return "other-device"
        return None


def xattrs_of(fd):
    try:
        return {n: os.getxattr(fd, n) for n in os.listxattr(fd)}
    except OSError as e:
        if e.errno in (errno.ENOTSUP, errno.EOPNOTSUPP):
            return {}
        raise


def alloc_bytes(st):
    """Bytes a rewrite allocates: the larger of the blocks held and the size in 4 KiB blocks."""
    return max(st.st_blocks * 512, (st.st_size + 4095) // 4096 * 4096)


def skip_text(skips, dir_skips):
    parts = ["%s %d" % (k, v) for k, v in skips.items() if v]
    parts += ["%s dirs %d" % (k, v) for k, v in dir_skips.items() if v]
    return ", ".join(parts) or "none"


# plan: the F1 method (data/disk-f1-returns/report.md, "How the return is
# weighted"), from a block sample of partly used 1 MiB blocks.

SAMPLE_TOTAL_RE = re.compile(r"bitmaps read: (\d+) partly used 1 MiB blocks")
SAMPLE_RE = re.compile(r"sample block (\d+) mib (\d+) holes (\d+)")


def read_sample(path, per_mib):
    total, holes = None, {}
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            for line in f:
                m = SAMPLE_TOTAL_RE.search(line)
                if m:
                    total = int(m.group(1))
                    continue
                m = SAMPLE_RE.search(line)
                if m:
                    mib, h = int(m.group(2)), int(m.group(3))
                    if not 0 < h < per_mib:
                        raise Refusal("%s: sample mib %d has %d holes, not 1-%d" % (path, mib, h, per_mib - 1))
                    holes[mib] = h
    except OSError as e:
        raise Refusal("cannot read sample %s: %s" % (path, e.strerror))
    if total is None or not holes:
        raise Refusal("%s holds no 'bitmaps read: N partly used' line or no 'sample block' lines" % path)
    return total, holes, int(os.stat(path).st_mtime)


def fiemap(fd):
    """-> list of (physical byte, length) of the file's real extents."""
    out, start = [], 0
    count = 256
    while True:
        buf = bytearray(struct.pack("=QQIIII", start, 0xFFFFFFFFFFFFFFFF, 0, 0, count, 0) + bytes(56 * count))
        fcntl.ioctl(fd, FS_IOC_FIEMAP, buf, True)
        n = struct.unpack_from("=I", buf, 20)[0]
        last = False
        for i in range(n):
            lg, ph, ln, _, _, fl = struct.unpack_from("=QQQQQI", buf, 32 + i * 56)
            if not fl & (0x2 | 0x4 | 0x200):  # unknown, delalloc, inline
                out.append((ph, ln))
            if fl & 0x1:
                last = True
            start = lg + ln
        if last or n < count:
            return out


def wilson(k, n, z=1.96):
    p = k / n
    d = 1 + z * z / n
    c = (p + z * z / (2 * n)) / d
    w = z * math.sqrt(p * (1 - p) / n + z * z / (4 * n * n)) / d
    return max(c - w, 0.0), c + w


def cmd_plan(home, sample_path):
    st = State(home)
    trees = read_trees(home)
    at = now()
    baseline = st.read_baseline()
    if not trees:
        say("plan: nothing to do (%s/config/repack-trees lists no tree)" % home)
        return 0
    ledger = st.read_ledger()
    scan = Scan(trees, at, baseline, set(ledger)).run()
    head = "plan: home %s; files untouched %d days or more; baseline %s" % (
        home, AGE_DAYS, "none" if baseline is None else utc(baseline))
    est = None
    if sample_path:
        bsize = os.statvfs(trees[0]).f_frsize
        per_mib = MIB // bsize
        total, holes, taken = read_sample(sample_path, per_mib)
        head += "; sample %s (%d of %d partly used MiBs, taken %s)" % (sample_path, len(holes), total, utc(taken))
        est = Estimate(total, holes, bsize, per_mib)
        for c in scan.candidates:
            est.add(c)
    else:
        head += "; no --sample, so MiBs emptied are unknown"
    say(head)
    for tree in trees:
        files, size = scan.per_tree[tree]
        say("tree %s: %d files, %d bytes (%s GiB); %s" % (
            tree, files, size, gib(size), est.text(tree) if est else "MiBs emptied unknown"))
    files = sum(v[0] for v in scan.per_tree.values())
    size = sum(v[1] for v in scan.per_tree.values())
    say("all trees, one batch: %d files, %d bytes (%s GiB); %s" % (
        files, size, gib(size), est.text(None) if est else "MiBs emptied unknown"))
    say("skipped: %s; open files and inode flags are checked at run time%s" % (
        skip_text(scan.skips, scan.dir_skips),
        "; %d files had no readable extent map" % est.unmapped if est and est.unmapped else ""))
    return 0


class Estimate:
    def __init__(self, total, holes, bsize, per_mib):
        self.total, self.holes, self.bsize, self.per_mib = total, holes, bsize, per_mib
        self.cover = {}  # tree -> {mib: blocks}
        self.unmapped = 0

    def add(self, c):
        try:
            fd = os.open(c["path"], os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC
                         | getattr(os, "O_NOATIME", 0))
        except OSError:
            self.unmapped += 1
            return
        try:
            ext = fiemap(fd)
        except OSError:
            self.unmapped += 1
            return
        finally:
            os.close(fd)
        cv = self.cover.setdefault(c["tree"], {})
        for ph, ln in ext:
            b0, b1 = ph // self.bsize, (ph + ln + self.bsize - 1) // self.bsize
            for m in range(b0 // self.per_mib, (b1 - 1) // self.per_mib + 1):
                if m in self.holes:
                    lo, hi = max(b0, m * self.per_mib), min(b1, (m + 1) * self.per_mib)
                    cv[m] = cv.get(m, 0) + hi - lo

    def text(self, tree):
        trees = [tree] if tree else list(self.cover)
        k, inpart = 0, 0
        for m, h in self.holes.items():
            used = self.per_mib - h
            c = sum(self.cover.get(t, {}).get(m, 0) for t in trees)
            inpart += min(c, used)
            if c and c >= used:
                k += 1
        n = len(self.holes)
        lo, hi = wilson(k, n)
        emptied = self.total * k / n
        cleared = emptied * MIB - self.total * inpart / n * self.bsize
        return "MiBs emptied ~%d (95%% CI %d-%d, %d of %d sampled), %s GiB; holes cleared ~%s GiB" % (
            round(emptied), round(self.total * lo), round(self.total * hi), k, n,
            gib(emptied * MIB), gib(cleared))


# baseline: files whose inode changed at or before EPOCH are dense already.

def cmd_baseline(home, at):
    st = State(home)
    if at is None:
        at = now()
    st.ensure()
    write_atomic(st.baseline, "%d\n" % at)
    st.log("baseline set to %s: files whose inode last changed at or before it are not repacked" % utc(at))
    say("baseline set to %s (%d)" % (utc(at), at))
    return 0


# run: lock, recover, scan, admit, exec, record.

def recover(st):
    """Remove journalled temporary names a killed run left; -> count removed."""
    try:
        with open(st.journal, encoding="utf-8") as f:
            lines = f.read().split("\n")
    except FileNotFoundError:
        return 0
    except OSError as e:
        raise Refusal("cannot read %s: %s" % (st.journal, e.strerror))
    open_tmps = {}
    for line in lines:
        if not line:
            continue
        try:
            rec = json.loads(line)
            kind, tmp = rec["kind"], rec["tmp"]
        except (ValueError, KeyError, TypeError):
            continue  # a torn last line from a crash
        if kind == "tmp":
            open_tmps[tmp] = True
        elif kind == "end":
            open_tmps.pop(tmp, None)
    removed = 0
    for tmp in open_tmps:
        if not TMP_RE.match(os.path.basename(tmp)):
            raise Refusal("%s names %r, which is not an fm-repack temporary name" % (st.journal, tmp))
        try:
            s = os.lstat(tmp)
        except FileNotFoundError:
            continue
        if not stat.S_ISREG(s.st_mode) or s.st_nlink != 1:
            raise Refusal("journalled temporary %s is not a single-link regular file; left in place" % tmp)
        os.unlink(tmp)
        removed += 1
        st.log("recovered: removed %s left by an interrupted run (the original path was never without its data)" % tmp)
    os.unlink(st.journal)
    return removed


def parse_size(text):
    m = re.match(r"^([0-9]+)([KMGT]?)$", text or "")
    if not m:
        raise Refusal("--max-bytes needs a size in bytes or with K, M, G or T: %r" % text)
    return int(m.group(1)) << {"": 0, "K": 10, "M": 20, "G": 30, "T": 40}[m.group(2)]


def cmd_run(home, max_bytes, script_dir):
    st = State(home)
    trees = read_trees(home)
    if not trees:
        say("run: nothing to do (%s/config/repack-trees lists no tree)" % home)
        return 0
    st.ensure()
    lockfd = os.open(st.lockfile, os.O_RDWR | os.O_CREAT | os.O_CLOEXEC, 0o600)
    try:
        fcntl.flock(lockfd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError as e:
        if e.errno in (errno.EAGAIN, errno.EACCES):
            st.log("held: another run holds %s" % st.lockfile)
            say("held: another fm-repack run for this home is active")
            return EXIT_WAIT
        raise
    removed = recover(st)
    if removed:
        say("recovered %d temporary file(s) an interrupted run left" % removed)
    at = now()
    baseline = st.read_baseline()
    ledger = st.read_ledger()
    scan = Scan(trees, at, baseline, set(ledger)).run()
    batch = scan.candidates
    if max_bytes is not None:
        total, cut = 0, 0
        for c in batch:
            if total + c["alloc"] > max_bytes:
                break
            total += c["alloc"]
            cut += 1
        if batch and cut == 0:
            say("refused: the oldest candidate (%d bytes) is larger than --max-bytes %d" % (batch[0]["alloc"], max_bytes))
            st.log("refused: oldest candidate %s is larger than --max-bytes %d" % (batch[0]["path"], max_bytes))
            return EXIT_FAILED
        batch = batch[:cut]
    skips = skip_text(scan.skips, scan.dir_skips)
    if not batch:
        st.log("run: nothing to repack in %d tree(s); skipped: %s" % (len(trees), skips))
        say("run: nothing to repack in %d tree(s); skipped: %s" % (len(trees), skips))
        compact_ledger(st, len(ledger), scan)
        return 0
    expect = (sum(c["alloc"] for c in batch) + MIB - 1) // MIB * MIB
    rundir = os.path.join(st.dir, "run-%d-%d" % (at, os.getpid()))
    os.makedirs(rundir)
    with open(os.path.join(rundir, "batch.jsonl"), "w", encoding="utf-8", errors="surrogateescape") as f:
        for c in batch:
            f.write(json.dumps(c) + "\n")
    st.log("run: batch of %d files, %d bytes, from %d tree(s) in mtime order; asking admission for %d bytes" % (
        len(batch), sum(c["size"] for c in batch), len(trees), expect))
    disk_room = env("FM_REPACK_DISK_ROOM") or os.path.join(script_dir, "fm-disk-room.sh")
    io_cap = shutil.which(env("FM_IO_CAP") or "fm-io-cap")
    if not io_cap:
        st.log("refused: fm-io-cap is not on PATH, and the batch runs only under its I/O cap; nothing was written")
        remove_rundir(rundir)
        raise Refusal("fm-io-cap is not on PATH (set FM_IO_CAP to its path); the batch runs only under its I/O cap")
    name = "fm-repack-%d" % (os.stat(st.dir).st_ino)
    cmd = ["bash", disk_room, "run", "--name", name, "--expect-write", str(expect), "--",
           io_cap, "--strict", "--", sys.executable, "-I", os.path.abspath(__file__),
           "exec", "--home", home, "--run-dir", rundir]
    child_env = dict(os.environ, FM_HOME=home)
    proc = subprocess.run(cmd, stderr=subprocess.PIPE, env=child_env)
    err = proc.stderr.decode("utf-8", "replace").strip()
    result = read_result(rundir)
    if proc.returncode == EXIT_WAIT and result is None:
        line = err.splitlines()[-1] if err else "fm-disk-room exited 75"
        st.log("held: admission refused the batch (%d bytes): %s; nothing was written" % (expect, line))
        say("held: admission refused the batch (%d bytes): %s" % (expect, line))
        remove_rundir(rundir)
        return EXIT_WAIT
    if err:
        sys.stderr.write(err + "\n")
    if result is None:
        st.log("failed: the batch did not start or died before it reported (exit %d): %s" % (
            proc.returncode, err.splitlines()[-1] if err else "no message"))
        say("failed: the batch did not start or died before it reported (exit %d); every path holds its "
            "original or its verified copy, and the next run removes any temporary file" % proc.returncode)
        return EXIT_FAILED
    merged = dict(scan.skips)
    for k, v in result["skips"].items():
        merged[k] = merged.get(k, 0) + v
    summary = "repacked %d files, %d bytes; skipped: %s" % (
        result["repacked"], result["bytes"], skip_text(merged, scan.dir_skips))
    remove_rundir(rundir)
    if result["outcome"] == "done" and proc.returncode == 0:
        compact_ledger(st, len(ledger), scan)
        st.log("run done: " + summary)
        say("run done: " + summary)
        return 0
    detail = result.get("detail", "")
    st.log("run %s: %s; %s" % (result["outcome"], detail, summary))
    say("run %s: %s; %s" % (result["outcome"], detail, summary))
    return EXIT_FAILED


def read_result(rundir):
    try:
        with open(os.path.join(rundir, "result.json"), encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


def remove_rundir(rundir):
    for name in ("batch.jsonl", "result.json"):
        try:
            os.unlink(os.path.join(rundir, name))
        except FileNotFoundError:
            pass
    os.rmdir(rundir)


def compact_ledger(st, n_before, scan):
    """Drop ledger entries for files a complete scan no longer found."""
    if scan.walk_errors:
        return
    after = st.read_ledger()
    keep = [k for k in after[:n_before] if k in scan.seen_ledger] + after[n_before:]
    if len(keep) != len(after):
        write_atomic(st.ledger, "".join("%d\t%d\n" % k for k in keep))


# exec: the batch, under admission and the I/O cap.

class Batch:
    def __init__(self, home, rundir):
        self.st = State(home)
        self.rundir = rundir
        self.uid = os.geteuid()
        self.skips = {}
        self.repacked = 0
        self.bytes = 0
        self.stop = False
        self.libc = ctypes.CDLL(None, use_errno=True)
        if not hasattr(self.libc, "renameat2"):
            raise Refusal("this C library has no renameat2, so an atomic exchange is impossible")
        self.during_copy = env("FM_REPACK_TEST_DURING_COPY")
        self.crash_at = env("FM_REPACK_TEST_CRASH")

    def on_term(self, *_):
        self.stop = True

    def exchange(self, a, b):
        if self.libc.renameat2(AT_FDCWD, os.fsencode(a), AT_FDCWD, os.fsencode(b), RENAME_EXCHANGE) != 0:
            e = ctypes.get_errno()
            raise OSError(e, os.strerror(e), a)

    def journal(self, jf, kind, tmp):
        jf.write(json.dumps(dict(kind=kind, tmp=tmp)) + "\n")
        jf.flush()
        os.fsync(jf.fileno())

    def crash(self, point):
        if self.crash_at == point:
            os._exit(137)  # test seam: a kill at this point, with no cleanup

    def run(self):
        signal.signal(signal.SIGIO, signal.SIG_IGN)  # lease breaks are polled, never signalled
        signal.signal(signal.SIGTERM, self.on_term)
        signal.signal(signal.SIGINT, self.on_term)
        try:
            os.sched_setaffinity(0, {sorted(os.sched_getaffinity(0))[0]})
        except (AttributeError, OSError):
            pass  # one CPU keeps ext4's per-CPU allocation group, so the copies land together
        outcome, detail = "done", ""
        with open(os.path.join(self.rundir, "batch.jsonl"), encoding="utf-8", errors="surrogateescape") as f:
            batch = [json.loads(line) for line in f if line.strip()]
        jf = open(self.st.journal, "a", encoding="utf-8", errors="surrogateescape")
        lf = open(self.st.ledger, "a", encoding="ascii")
        try:
            for c in batch:
                if self.stop:
                    outcome, detail = "interrupted", "stopped by a signal before %s; a rerun continues" % c["path"]
                    break
                try:
                    self.one(c, jf, lf)
                except FileSkip as s:
                    self.skips[s.reason] = self.skips.get(s.reason, 0) + 1
                    if s.reason not in ("open", "vanished", "interrupted"):
                        self.st.log("skipped %s: %s%s" % (c["path"], s.reason, ": " + s.detail if s.detail else ""))
                    continue
                except (FileFailed, OSError) as e:
                    outcome = "failed"
                    detail = "stopped at %s: %s" % (c["path"], e)
                    break
                self.repacked += 1
                self.bytes += c["size"]
        finally:
            lf.close()
            jf.close()
        write_atomic(os.path.join(self.rundir, "result.json"), json.dumps(dict(
            outcome=outcome, detail=detail, repacked=self.repacked, bytes=self.bytes, skips=self.skips)))
        return 0 if outcome == "done" else EXIT_FAILED

    def lease_ok(self, fd):
        return fcntl.fcntl(fd, F_GETLEASE) == fcntl.F_WRLCK

    def one(self, c, jf, lf):
        path = c["path"]
        try:
            s0 = os.lstat(path)
        except FileNotFoundError:
            raise FileSkip("vanished")
        if (s0.st_ino, s0.st_size, s0.st_mtime_ns, s0.st_ctime_ns) != (c["ino"], c["size"], c["mtime_ns"], c["ctime_ns"]):
            raise FileSkip("changed", "since the scan")
        if not stat.S_ISREG(s0.st_mode) or s0.st_nlink != 1:
            raise FileSkip("hard-linked")
        try:
            fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC | getattr(os, "O_NOATIME", 0))
        except FileNotFoundError:
            raise FileSkip("vanished")
        tmp = os.path.join(os.path.dirname(path), ".fm-repack-%d-%d.tmp" % (s0.st_ino, os.getpid()))
        tfd, journalled, created, swapped = None, False, False, False
        try:
            if os.fstat(fd).st_ino != s0.st_ino:
                raise FileSkip("changed", "replaced while opening")
            try:
                fcntl.fcntl(fd, F_SETLEASE, fcntl.F_WRLCK)
            except OSError as e:
                if e.errno == errno.EAGAIN:
                    raise FileSkip("open")
                raise FileFailed("cannot take a write lease (%s), so open files cannot be told apart" % e.strerror)
            try:
                flags = struct.unpack("=l", fcntl.ioctl(fd, FS_IOC_GETFLAGS, struct.pack("=l", 0)))[0]
            except OSError as e:
                if e.errno not in (errno.ENOTTY, errno.EOPNOTSUPP, errno.EINVAL):
                    raise
                flags = 0
            if flags & ~EXTENTS_FL:
                raise FileSkip("inode-flags", "flags 0x%x" % flags)
            xattrs = xattrs_of(fd)
            self.journal(jf, "tmp", tmp)
            journalled = True
            try:
                tfd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600)
            except OSError as e:
                if e.errno in (errno.EACCES, errno.EPERM, errno.EROFS):
                    raise FileSkip("directory", "cannot create a file beside it: %s" % e.strerror)
                raise
            created = True
            self.copy(fd, tfd)
            os.fsync(tfd)
            if self.during_copy:
                subprocess.run([self.during_copy, path], check=False)
            try:
                t = os.fstat(tfd)
                if (t.st_uid, t.st_gid) != (s0.st_uid, s0.st_gid):
                    os.fchown(tfd, s0.st_uid, s0.st_gid)
                os.fchmod(tfd, stat.S_IMODE(s0.st_mode))
                for name, value in xattrs.items():
                    os.setxattr(tfd, name, value)
                os.utime(tfd, ns=(s0.st_atime_ns, s0.st_mtime_ns))
            except OSError as e:
                raise FileSkip("metadata", "cannot set on the copy: %s" % e.strerror)
            os.fsync(tfd)
            self.compare(fd, tmp, s0, xattrs)
            s1 = os.lstat(path)
            if (s1.st_ino, s1.st_size, s1.st_mtime_ns, s1.st_ctime_ns, s1.st_nlink) != \
                    (s0.st_ino, s0.st_size, s0.st_mtime_ns, s0.st_ctime_ns, 1):
                raise FileSkip("changed", "during the copy")
            if not self.lease_ok(fd):
                raise FileSkip("open", "opened during the copy")
            # Recorded before the exchange, so a crash after it still makes the rerun a no-op;
            # an entry whose copy never took the path names an unlinked inode and is dropped later.
            lf.write("%d\t%d\n" % (os.fstat(tfd).st_ino, s0.st_mtime_ns))
            lf.flush()
            os.fsync(lf.fileno())
            self.crash("before-swap")
            self.exchange(tmp, path)
            swapped = True
            self.crash("after-swap")
            if not self.lease_ok(fd):
                try:
                    self.exchange(tmp, path)  # the opener keeps the linked original
                except OSError as e:
                    self.journal(jf, "end", tmp)  # never let recovery remove the original
                    raise FileFailed("could not put the original back after a lease break (%s); "
                                     "it is at %s and the verified copy at %s" % (e.strerror, tmp, path))
                swapped = False
                raise FileSkip("opened-during-swap", "another process opened it during the exchange; original kept")
            os.unlink(tmp)
            self.journal(jf, "end", tmp)
            journalled = False
        finally:
            if tfd is not None:
                os.close(tfd)
            if journalled and not swapped:
                if created:
                    try:
                        os.unlink(tmp)
                    except FileNotFoundError:
                        pass
                self.journal(jf, "end", tmp)
            os.close(fd)  # releases the lease

    def copy(self, fd, tfd):
        off = 0
        while True:
            if not self.lease_ok(fd):
                raise FileSkip("open", "opened during the copy")
            if self.stop:
                raise FileSkip("interrupted")
            data = os.pread(fd, CHUNK, off)
            if not data:
                return
            view = memoryview(data)
            while view:
                n = os.write(tfd, view)
                view = view[n:]
            off += len(data)

    def compare(self, fd, tmp, s0, xattrs):
        rfd = os.open(tmp, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC | getattr(os, "O_NOATIME", 0))
        try:
            off = 0
            while True:
                if not self.lease_ok(fd):
                    raise FileSkip("open", "opened during the compare")
                a, b = os.pread(fd, CHUNK, off), os.pread(rfd, CHUNK, off)
                if a != b:
                    raise FileFailed("the copy differs from the original at byte %d" % off)
                if not a:
                    break
                off += len(a)
            t = os.fstat(rfd)
            if off != s0.st_size or t.st_size != s0.st_size:
                raise FileFailed("the copy holds %d bytes, the original %d" % (t.st_size, s0.st_size))
            if (t.st_mode, t.st_uid, t.st_gid, t.st_mtime_ns, t.st_atime_ns) != \
                    (s0.st_mode, s0.st_uid, s0.st_gid, s0.st_mtime_ns, s0.st_atime_ns):
                raise FileSkip("metadata", "mode, owner, mtime or atime did not carry over")
            if xattrs_of(rfd) != xattrs:
                raise FileSkip("metadata", "xattrs did not carry over")
        finally:
            os.close(rfd)


def main(argv):
    if not argv:
        raise Refusal("needs plan, run or baseline (see fm-repack.sh --help)")
    cmd, args = argv[0], argv[1:]
    opts, i = {}, 0
    takes = {"plan": ("--home", "--sample"), "run": ("--home", "--max-bytes"),
             "baseline": ("--home", "--at"), "exec": ("--home", "--run-dir")}
    if cmd not in takes:
        raise Refusal("unknown command %r (see fm-repack.sh --help)" % cmd)
    while i < len(args):
        if args[i] in takes[cmd] and i + 1 < len(args) and args[i] not in opts:
            opts[args[i]] = args[i + 1]
            i += 2
        else:
            raise Refusal("%s: unexpected argument %r" % (cmd, args[i]))
    home = opts.get("--home")
    if not home:
        raise Refusal("%s needs --home HOME" % cmd)
    home = os.path.realpath(home)
    if not os.path.isdir(os.path.join(home, "config")) and cmd != "exec":
        raise Refusal("%s is not a firstmate home (no config/ directory)" % home)
    if cmd == "plan":
        return cmd_plan(home, opts.get("--sample"))
    if cmd == "baseline":
        at = opts.get("--at")
        if at is not None and not at.isdigit():
            raise Refusal("--at needs an epoch: %r" % at)
        return cmd_baseline(home, None if at is None else int(at))
    if cmd == "run":
        mb = opts.get("--max-bytes")
        return cmd_run(home, None if mb is None else parse_size(mb), os.path.dirname(os.path.abspath(__file__)))
    if not opts.get("--run-dir"):
        raise Refusal("exec needs --run-dir")
    lockfd = os.open(State(home).lockfile, os.O_RDONLY | os.O_CLOEXEC)
    try:
        fcntl.flock(lockfd, fcntl.LOCK_SH | fcntl.LOCK_NB)
        raise Refusal("exec runs only inside 'fm-repack.sh run', which holds the home's repack lock")
    except BlockingIOError:
        pass
    finally:
        os.close(lockfd)
    return Batch(home, opts["--run-dir"]).run()


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except Refusal as e:
        sys.stderr.write("fm-repack: refused: %s\n" % e)
        sys.exit(EXIT_USAGE)
    except OSError as e:
        sys.stderr.write("fm-repack: failed: %s\n" % e)
        sys.exit(EXIT_FAILED)
