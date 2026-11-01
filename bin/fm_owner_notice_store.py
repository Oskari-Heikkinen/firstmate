#!/usr/bin/env python3
"""fm_owner_notice_store.py - the owner engine of fm-owner-notice/v1.

bin/fm-owner-notice.sh is the only intended caller: it takes the locks, runs
this engine as its direct child, appends the wakes and syncs the alert store.
docs/owner-notice.md owns the protocol, the state layout, the lock order and
the crash table; this header owns the subcommands.

Usage (H is the owner FM_HOME, L a lock directory the caller holds):
  fm_owner_notice_store.py bind-inspect --home H <id> <bind options>
  fm_owner_notice_store.py bind --home H --lock L <id> <bind options> --outbox-dev D --outbox-ino I
      where <bind options> are --outbox P --producer-actor A --producer-uid U
      --kinds K1[,K2...] --max-bytes N --consume-bound-seconds S
  fm_owner_notice_store.py fg-stage --home H --origin ingest <id> [<run>]
  fm_owner_notice_store.py stage --home H <id> <run>
  fm_owner_notice_store.py ingest-staged --home H --lock L <id> <run>
  fm_owner_notice_store.py reconcile --home H --lock L <id>
  fm_owner_notice_store.py retention --home H --lock L <id>
  fm_owner_notice_store.py announce-list --home H --lock L <id>
  fm_owner_notice_store.py mark-announced --home H --lock L <id> <key>...
  fm_owner_notice_store.py consume --home H --lock L <id> <key> [--note T]
  fm_owner_notice_store.py ack-refusal --home H --lock L <id> <key> --note T
  fm_owner_notice_store.py ack-vanished --home H --lock L <id> <name> --note T
  fm_owner_notice_store.py retire --home H --lock L --bindings-lock B <id>
  fm_owner_notice_store.py purge --home H --lock L --bindings-lock B <id>
  fm_owner_notice_store.py show --home H <id> <key>
  fm_owner_notice_store.py list --home H [--archived] [<id>]
  fm_owner_notice_store.py alarms --home H --out F
  fm_owner_notice_store.py status --home H
  fm_owner_notice_store.py lists --home H --bindings-lock B
  fm_owner_notice_store.py fsync-file <path>

Every mutating subcommand needs --lock naming a lock whose recorded owner pid is
this process's parent, and otherwise exits 70 lock-not-held. bind-inspect checks
the outbox in a recorded bounded child with no lock held and prints the
outbox_dev and outbox_ino that bind, under the bindings lock, then records.
stage writes only its own <id>/.tmp/<run>/; fg-stage (which names the run for its parent when
<run> is omitted) runs stage in a recorded child through the
common child-spawn operation and waits at most OUTBOX_IO_BOUND for it. Output
is one JSON line on stdout. Exits: 0 success or idempotent replay, 2 usage,
65 a refusal (code in the JSON), 69 unavailable, 70 unknown or inconsistent
state, 75 outbox-unresponsive.
"""

import argparse
import base64
import ctypes
import json
import os
import re
import select
import shutil
import signal
import stat
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import fm_owner_notice_format as fmt  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
USAGE, REFUSED, UNAVAILABLE, UNKNOWN, BUSY = 2, 65, 69, 70, 75

OUTBOX_IO_BOUND = 10
INGEST_CAP = 256
CACHE_SLACK = 2
# An outbox entry still in progress this long after its link raises a level.
IN_PROGRESS_SETTLE = 60
BACKLOG_NAMES = 4096
CURRENT_BACKLOG = 3072
RUNNER_LOOP = 15
RETIRED_SWEEP = 7 * 86400
HANDLED_KEEP = 30 * 86400
CURRENT_KEEP = 7 * 86400
PURGE_AFTER = 365 * 86400
RETIRING_STALE = OUTBOX_IO_BOUND + 60
LOG_ROTATE = 1 << 20
LOG_KEEP = 4
RESULT_BOUND = 4 << 20
OWNER_DIRS = ("custody", "handled", "receipts", "current", "archive", ".announced", ".acked", ".tmp")
STAGE_REFUSALS = ("outbox-identity-changed", "outbox-symlink", "outbox-filesystem", "outbox-unreadable")
FINAL = ("delivered", "consumed", "refused", "key-conflict")
PROBLEMS = ("custody-mismatch", "orphan-custody", "seq-collision")


class Done(Exception):
    """End the command with this exit code and stdout object."""

    # Positional-only, so a result field named code never collides.
    def __init__(self, exit_code, /, **result):
        super().__init__(result.get("state", ""))
        self.code = exit_code
        self.result = dict(result, exit=exit_code)


def now():
    return fmt.seams().time()


# ---------------------------------------------------------------- paths and records

class Owner:
    def __init__(self, home):
        if not home or not home.startswith("/"):
            raise Done(USAGE, state="usage", detail="--home must be absolute")
        self.home = os.path.realpath(home)
        self.state = os.path.join(self.home, "state")
        self.root = os.path.join(self.state, "owner-notices")
        self.bindings = os.path.join(self.root, "bindings")
        self.tmp = os.path.join(self.root, ".tmp")
        self.fg = os.path.join(self.root, ".fg-children")
        fmt.seams().check(self.home)

    def binding_path(self, bid):
        return os.path.join(self.bindings, bid + ".json")

    def marker(self, bid, suffix):
        return os.path.join(self.bindings, bid + suffix)

    def dir(self, bid, *parts):
        return os.path.join(self.root, bid, *parts)


def check_id(bid):
    if not fmt.valid_name(bid):
        raise Done(USAGE, state="usage", detail="binding id must match " + fmt.NAME_RE.pattern)


def check_key(key):
    if not fmt.valid_name(key):
        raise Done(USAGE, state="usage", detail="key must match " + fmt.NAME_RE.pattern)


def load_binding(owner, bid):
    """(binding, binding_sha256), or Done 69 when the binding is missing or bad."""
    check_id(bid)
    path = owner.binding_path(bid)
    try:
        data = fmt.read_regular_nofollow(path, fmt.BINDING_BOUND, "engine")
        return fmt.validate_binding(fmt.parse_canonical(data)), fmt.sha256_hex(data)
    except FileNotFoundError:
        raise Done(UNAVAILABLE, state="unavailable", code="not-bound", path=path)
    except (OSError, fmt.NotRegular, fmt.FormatError) as exc:
        raise Done(UNKNOWN, state="unknown", code="binding-unreadable", path=path, detail=str(exc))


def is_retired(owner, bid):
    return os.path.lexists(owner.marker(bid, ".retired"))


def is_purged(owner, bid):
    """Purge removes a retired binding's tree and keeps its record and marker."""
    return is_retired(owner, bid) and not os.path.lexists(owner.dir(bid))


def temp_dir(owner, bid):
    return owner.dir(bid, ".tmp")


def write_json(path, obj, tmpdir, ident):
    fmt.replace_durable(path, fmt.canonical(obj), tmpdir, ident)


def read_json(path, bound=fmt.RECORD_BOUND):
    """The parsed canonical record, None when absent; FormatError otherwise."""
    try:
        data = fmt.read_regular_nofollow(path, bound, "engine")
    except FileNotFoundError:
        return None
    except (OSError, fmt.NotRegular) as exc:
        raise fmt.FormatError("%s: %s" % (path, exc)) from None
    return fmt.parse_canonical(data)


def log(owner, bid, what, why, nxt):
    """One plain line: UTC time, what happened, why, what happens next."""
    path = owner.dir(bid, "log") if bid else os.path.join(owner.root, "log")
    line = "%s %s: %s; next: %s\n" % (fmt.utc_iso(time.time()), what, why, nxt)
    try:
        if os.path.getsize(path) >= LOG_ROTATE:
            for n in range(LOG_KEEP - 1, 0, -1):
                if os.path.exists("%s.%d" % (path, n)):
                    os.replace("%s.%d" % (path, n), "%s.%d" % (path, n + 1))
            os.replace(path, path + ".1")
    except OSError:
        pass
    try:
        with open(path, "a", encoding="utf-8") as fh:
            fh.write(line.replace("\r", " "))
    except OSError:
        pass


# ---------------------------------------------------------------- lock guard

def require_lock(lock):
    """The engine guard: the lock's recorded owner pid must be our parent."""
    if not lock:
        raise Done(UNKNOWN, state="unknown", code="lock-not-held", detail="--lock is required")
    try:
        data = fmt.read_regular_nofollow(os.path.join(lock, "pid"), 64, "engine")
        holder = int(data.decode("ascii").strip())
    except (OSError, fmt.NotRegular, ValueError, UnicodeDecodeError):
        raise Done(UNKNOWN, state="unknown", code="lock-not-held", lock=lock)
    if holder != os.getppid():
        raise Done(UNKNOWN, state="unknown", code="lock-not-held", lock=lock, holder=holder)


# ---------------------------------------------------------------- the common child-spawn operation

def _prctl_pdeathsig():
    try:
        libc = ctypes.CDLL(None, use_errno=True)
        libc.prctl(1, signal.SIGKILL, 0, 0, 0)  # PR_SET_PDEATHSIG
    except (OSError, AttributeError):
        pass


def spawn_recorded_child(owner, role, origin, bid, outbox, work):
    """Run work() in a recorded child of its own process group, bounded.

    The child sets PDEATHSIG (unless no-pdeathsig:<role>), ignores TERM under
    child-ignore-term:<role> or unkillable:<role>, and blocks on a start pipe;
    the parent makes .fg-children/<pid>-<starttime> durable and only then
    writes the release byte. A child that reads EOF exits without touching any
    path. Returns (status, result): status is "ok", "died" or "timeout".
    """
    s = fmt.seams()
    parent = os.getpid()
    r_start, w_start = os.pipe()
    r_res, w_res = os.pipe()
    pid = os.fork()
    if pid == 0:
        try:
            os.close(w_start)
            os.close(r_res)
            os.setpgid(0, 0)
            if not (s.role("no-pdeathsig", role) or s.role("unkillable", role)):
                _prctl_pdeathsig()
                if os.getppid() != parent:
                    os._exit(0)
            if s.role("child-ignore-term", role) or s.role("unkillable", role):
                signal.signal(signal.SIGTERM, signal.SIG_IGN)
            if os.read(r_start, 1) != b"1":
                os._exit(0)
            os.close(r_start)
            s.fault("child:" + origin)
            try:
                out = json.dumps(work()).encode("utf-8")
                code = 0
            except BaseException as exc:  # noqa: BLE001 - the parent reports it
                out = json.dumps({"error": repr(exc)}).encode("utf-8")
                code = 1
            view = memoryview(out)
            while view:
                view = view[os.write(w_res, view):]
            os._exit(code)
        except BaseException:  # noqa: BLE001
            os._exit(1)
    os.close(r_start)
    os.close(w_res)
    try:
        os.setpgid(pid, pid)
    except OSError:
        pass
    start = fmt.pid_starttime(pid) or "0"
    fmt.mkdir_durable(owner.fg)
    fmt.mkdir_durable(owner.tmp)
    rec = os.path.join(owner.fg, "%d-%s" % (pid, start))
    record = {"role": role, "origin": origin, "binding": bid, "outbox": outbox, "pgid": pid,
              "pid": pid, "starttime": start, "started_at": int(time.time())}
    try:
        fmt.create_exclusive(rec, fmt.canonical(record), owner.tmp, "o-fgchild-dirsync")
    except BaseException:
        os.close(w_start)
        os.waitpid(pid, 0)
        raise
    os.write(w_start, b"1")
    os.close(w_start)
    chunks, size = [], 0
    deadline = time.monotonic() + OUTBOX_IO_BOUND
    status = "ok"
    while True:
        left = deadline - time.monotonic()
        if left <= 0:
            status = "timeout"
            break
        ready, _, _ = select.select([r_res], [], [], left)
        if not ready:
            continue
        chunk = os.read(r_res, 65536)
        if not chunk:
            break
        size += len(chunk)
        if size > RESULT_BOUND:
            status = "died"
            break
        chunks.append(chunk)
    os.close(r_res)
    if status == "timeout":
        if not s.role("unkillable", role):
            try:
                os.killpg(pid, signal.SIGKILL)
            except OSError:
                pass
        gone = _reap(pid, 1.0)
        if gone:
            fmt._unlink_quiet(rec)
        return "timeout", {"pid": pid, "starttime": start, "record": rec}
    _, wstatus = os.waitpid(pid, 0)
    fmt._unlink_quiet(rec)
    if os.WIFEXITED(wstatus) and os.WEXITSTATUS(wstatus) == 0 and status == "ok":
        try:
            return "ok", json.loads(b"".join(chunks).decode("utf-8"))
        except ValueError:
            return "died", {"detail": "unparsable child result"}
    detail = {"exit": os.WEXITSTATUS(wstatus) if os.WIFEXITED(wstatus) else None,
              "signal": os.WTERMSIG(wstatus) if os.WIFSIGNALED(wstatus) else None}
    try:
        detail.update(json.loads(b"".join(chunks).decode("utf-8")))
    except ValueError:
        pass
    return "died", detail


def _reap(pid, seconds):
    end = time.monotonic() + seconds
    while time.monotonic() < end:
        try:
            got, _ = os.waitpid(pid, os.WNOHANG)
        except ChildProcessError:
            return True
        if got:
            return True
        time.sleep(0.02)
    return False


# ---------------------------------------------------------------- bind

def inspect_outbox(outbox):
    """The bind child's work: every syscall on the outbox path happens here."""
    out = {"outbox": outbox}
    try:
        lst = os.lstat(outbox)
    except OSError as exc:
        out["error"] = exc.strerror
        return out
    out["is_symlink"] = stat.S_ISLNK(lst.st_mode)
    out["is_dir"] = stat.S_ISDIR(lst.st_mode)
    out["realpath"] = os.path.realpath(outbox)
    try:
        fd = os.open(outbox, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC)
    except OSError as exc:
        out["open_error"] = exc.errno
        return out
    try:
        st = os.fstat(fd)
    finally:
        os.close(fd)
    allowed, types = fmt.fs_allowed(st.st_dev)
    out.update(dev=st.st_dev, ino=st.st_ino, uid=st.st_uid, fs_allowed=allowed, fs_types=types)
    return out


def _is_symlink(path):
    """Whether path itself is a symlink; an O_DIRECTORY|O_NOFOLLOW open refuses one
    with ENOTDIR on Linux, not ELOOP, so the errno cannot tell."""
    try:
        return stat.S_ISLNK(os.lstat(path).st_mode)
    except OSError:
        return False


def _within(a, b):
    return a == b or a.startswith(b.rstrip("/") + "/")


def recipient_home(owner):
    marker = os.path.join(owner.home, ".fm-secondmate-home")
    try:
        data = fmt.read_regular_nofollow(marker, 4096, "engine")
    except FileNotFoundError:
        return "main"
    except (OSError, fmt.NotRegular) as exc:
        raise Done(UNAVAILABLE, state="unavailable", path=marker, detail=str(exc))
    text = data.decode("utf-8", "replace").strip()
    if not text:
        raise Done(UNAVAILABLE, state="unavailable", path=marker, detail="empty secondmate marker")
    return text


def machine_id():
    try:
        return fmt.read_regular_nofollow("/etc/machine-id", 4096, "engine").decode("ascii").strip()
    except (OSError, fmt.NotRegular, UnicodeDecodeError) as exc:
        raise Done(UNAVAILABLE, state="unavailable", path="/etc/machine-id", detail=str(exc))


def list_lines(owner, name):
    """{binding id: its lines} in the current list file name; {} when it is absent or unreadable."""
    try:
        data = fmt.read_regular_nofollow(os.path.join(owner.root, name), 16 << 20, "engine")
    except (OSError, fmt.NotRegular):
        return {}
    out = {}
    for line in data.decode("utf-8", "replace").splitlines(True):
        out.setdefault(line.split("\t", 1)[0], []).append(line)
    return out


def wanted_lists(owner):
    """The .bindings.list and .retired.list contents bindings/* implies.

    A binding that cannot be read keeps the lines it has now: an unknown
    binding is not a removed one (its binding-unreadable level says so).
    """
    active, retired = [], []
    t = now()
    have = None
    for name in fmt.scandir_names(owner.bindings, "engine"):
        if not name.endswith(".json"):
            continue
        bid = name[:-5]
        if not fmt.valid_name(bid):
            continue
        try:
            binding, _ = load_binding(owner, bid)
        except Done:
            if have is None:
                have = (list_lines(owner, ".bindings.list"), list_lines(owner, ".retired.list"))
            active.extend(have[0].get(bid, []))
            retired.extend(have[1].get(bid, []))
            continue
        ret = owner.marker(bid, ".retired")
        if os.path.lexists(ret):
            try:
                at = fmt.parse_iso(read_json(ret)["retired_at"])
            except (fmt.FormatError, KeyError, TypeError):
                at = t
            if t - at < RETIRED_SWEEP:
                retired.append("%s\t%s\t%d\n" % (bid, binding["outbox"], at))
        else:
            active.append("%s\t%s\n" % (bid, binding["outbox"]))
    return {".bindings.list": "".join(active).encode("utf-8"), ".retired.list": "".join(retired).encode("utf-8")}


def stale_lists(owner):
    """The list names whose bytes differ from what bindings/* implies."""
    stale = []
    for name, data in sorted(wanted_lists(owner).items()):
        try:
            have = fmt.read_regular_nofollow(os.path.join(owner.root, name), 16 << 20, "engine")
        except (OSError, fmt.NotRegular):
            have = None
        if have != data:
            stale.append(name)
    return stale


def rebuild_lists(owner):
    """Rewrite .bindings.list and .retired.list from bindings/* (bindings lock held)."""
    for name, data in sorted(wanted_lists(owner).items()):
        fmt.replace_durable(os.path.join(owner.root, name), data, owner.tmp, "o-list-dirsync")


def cmd_lists(owner, a):
    require_lock(a.bindings_lock)
    fmt.mkdir_durable(owner.tmp)
    fmt.reap_dead_temps(owner.tmp)
    rebuild_lists(owner)
    raise Done(0, state="lists-rebuilt")


def bind_args(a):
    """The bind options checked for both halves: (kinds, normalized outbox)."""
    check_id(a.id)
    kinds = sorted(set(k for k in a.kinds.split(",") if k))
    if not kinds or not all(fmt.valid_name(k) for k in kinds):
        raise Done(USAGE, state="usage", detail="--kinds must be names matching " + fmt.NAME_RE.pattern)
    if not 1 <= a.max_bytes <= fmt.MAX_BYTES_CAP:
        raise Done(USAGE, state="usage", detail="--max-bytes is 1 to %d" % fmt.MAX_BYTES_CAP)
    if a.consume_bound_seconds < 1:
        raise Done(USAGE, state="usage", detail="--consume-bound-seconds must be positive")
    if not a.outbox.startswith("/"):
        raise Done(USAGE, state="usage", detail="--outbox must be absolute")
    return kinds, os.path.normpath(a.outbox)


def cmd_bind_inspect(owner, a):
    """Bind's first half, with no lock held: inspect the outbox in the bounded
    child and print the identity the locked half records."""
    _, outbox = bind_args(a)
    fmt.mkdir_durable(owner.tmp)
    status, got = spawn_recorded_child(owner, "stat", "bind", a.id, outbox, lambda: inspect_outbox(outbox))
    if status == "timeout":
        raise Done(BUSY, state="outbox-unresponsive", code="outbox-unresponsive", outbox=outbox, detail=got)
    if status != "ok":
        raise Done(UNKNOWN, state="unknown", code="outbox-inspect-failed", outbox=outbox, detail=got)
    root = os.path.realpath(owner.root)
    state = os.path.realpath(owner.state)
    real = got.get("realpath") or outbox
    for cand in {outbox, real}:
        if _within(cand, root) or _within(root, cand) or _within(state, cand):
            raise Done(REFUSED, state="refused", code="outbox-overlaps-owner", outbox=outbox)
    if "error" in got:
        raise Done(REFUSED, state="refused", code="outbox-not-directory", outbox=outbox, detail=got["error"])
    if got.get("is_symlink"):
        raise Done(REFUSED, state="refused", code="outbox-symlink", outbox=outbox)
    if not got.get("is_dir") or "open_error" in got:
        raise Done(REFUSED, state="refused", code="outbox-not-directory", outbox=outbox)
    if got["uid"] != a.producer_uid:
        raise Done(REFUSED, state="refused", code="outbox-owner", outbox=outbox, uid=got["uid"])
    if not got["fs_allowed"]:
        raise Done(REFUSED, state="refused", code="outbox-filesystem", outbox=outbox, fs_types=got["fs_types"])
    raise Done(0, state="inspected", outbox=outbox, outbox_dev=got["dev"], outbox_ino=got["ino"])


def cmd_bind(owner, a):
    """Bind's second half, under the bindings lock: owner files only, recording
    the outbox identity bind-inspect found (stage re-checks it on every run)."""
    require_lock(a.lock)
    kinds, outbox = bind_args(a)
    if os.path.lexists(owner.marker(a.id, ".retired")):
        raise Done(REFUSED, state="refused", code="binding-retired", binding_id=a.id)
    actor = subprocess.run([sys.executable, os.path.join(HERE, "fm-handoff-actors.py"), "valid-actor",
                            a.producer_actor], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                           stderr=subprocess.DEVNULL, timeout=30, check=False).returncode
    if actor != 0:
        raise Done(REFUSED, state="refused", code="actor-invalid", producer_actor=a.producer_actor)
    # The front creates owner-notices/ and its .tmp/ itself (it holds
    # .bindings.lock there), so make both levels durable before anything counts.
    fmt.fsync_dir(owner.state, "o-mkdir-parent")
    fmt.mkdir_durable(owner.tmp)
    fmt.fsync_dir(owner.root, "o-mkdir-parent")
    fmt.reap_dead_temps(owner.tmp)
    got = {"dev": a.outbox_dev, "ino": a.outbox_ino}
    binding = {
        "schema": fmt.BINDING_SCHEMA, "binding_id": a.id, "recipient_home": recipient_home(owner),
        "owner_home_path": owner.home, "machine_id": machine_id(), "producer_actor": a.producer_actor,
        "producer_uid": a.producer_uid, "outbox": outbox, "outbox_dev": got["dev"], "outbox_ino": got["ino"],
        "kinds": kinds, "max_bytes": a.max_bytes, "consume_bound_seconds": a.consume_bound_seconds,
        "envelope_versions": [1], "receipt_versions": [1], "created_at": fmt.utc_iso(now()),
    }
    fmt.validate_binding(binding)
    for d in OWNER_DIRS:
        fmt.mkdir_durable(owner.dir(a.id, d), root=owner.root)
    fmt.mkdir_durable(owner.bindings, root=owner.root)
    path = owner.binding_path(a.id)
    data = fmt.canonical(binding)
    try:
        fmt.create_exclusive(path, data, owner.tmp, "o-binding-dirsync")
        replay = False
    except FileExistsError:
        have, sha = load_binding(owner, a.id)
        if any(have[f] != binding[f] for f in fmt.BINDING_REPLAY_FIELDS):
            raise Done(REFUSED, state="refused", code="binding-conflict", binding_id=a.id)
        data = fmt.canonical(have)
        replay = True
    fmt.seams().fault("bind:after-create")
    rebuild_lists(owner)
    log(owner, a.id, "bound" if not replay else "bind replayed", "outbox " + outbox, "producer submits")
    raise Done(0, state="bound", binding_id=a.id, binding_sha256=fmt.sha256_hex(data), replay=replay,
               recipient_home=binding["recipient_home"], owner_home_path=owner.home,
               machine_id=binding["machine_id"])


# ---------------------------------------------------------------- stage

def stage(owner, bid, run, binding):
    """List and copy new outbox entries into <id>/.tmp/<run>/ (no lock, no owner writes)."""
    s = fmt.seams()
    rdir = os.path.join(temp_dir(owner, bid), run)
    os.mkdir(rdir, 0o755)
    me, mestart = fmt.own_identity()
    manifest = {"schema": fmt.MANIFEST_SCHEMA, "binding_id": bid, "run": run, "stage_pid": me,
                "stage_starttime": mestart, "complete": False, "code": None, "names": None, "entries": [],
                "cap_hit": False, "backlog": False, "listed_at": None, "mtime_ns": None}
    mpath = os.path.join(rdir, "manifest.json")

    def save():
        with open(mpath + ".part", "wb") as fh:
            fh.write(fmt.canonical(manifest))
        os.replace(mpath + ".part", mpath)

    save()
    outbox = binding["outbox"]
    try:
        fd = os.open(outbox, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC)
    except OSError as exc:
        manifest["code"] = "outbox-symlink" if _is_symlink(outbox) else "outbox-unreadable"
        manifest["detail"] = exc.strerror
        save()
        return manifest
    try:
        s.opened("stage", "open", outbox)
        st = os.fstat(fd)
        if (st.st_dev, st.st_ino) != (binding["outbox_dev"], binding["outbox_ino"]):
            manifest["code"] = "outbox-identity-changed"
            save()
            return manifest
        if not fmt.fs_allowed(st.st_dev)[0]:
            manifest["code"] = "outbox-filesystem"
            save()
            return manifest
        manifest["mtime_ns"] = st.st_mtime_ns
        manifest["listed_at"] = now()
        # The filesystem's own clock, not the clock seam: the cache compares it
        # with ctimes.
        settled = time.time_ns() - s.value("cache-slack", CACHE_SLACK) * 10**9
        stuck = time.time_ns() - s.value("in-progress-settle", IN_PROGRESS_SETTLE) * 10**9
        s.opened("stage", "scandir", outbox)
        with os.scandir(fd) as it:
            names = sorted(e.name for e in it if not e.name.startswith("."))
        manifest["names"] = names
        manifest["backlog"] = len(names) > BACKLOG_NAMES
        save()
        s.fault("stage:after-listing")
        cache = read_cache(owner, bid)
        fresh = []
        for name in names:
            if envelope_key(name) is None:
                continue
            try:
                st = os.stat(name, dir_fd=fd, follow_symlinks=False)
            except OSError:
                continue
            # A replaced entry can reuse the inode, so the ctime is part of
            # its identity.
            ident = (name, st.st_ino, st.st_ctime_ns)
            if ident not in cache:
                fresh.append((st.st_mtime_ns, ident))
        fresh.sort()
        cap = s.value("ingest-cap", INGEST_CAP)
        manifest["cap_hit"] = len(fresh) > cap
        bound = fmt.envelope_cap(binding["max_bytes"])
        for n, (_, (name, ino, ctime)) in enumerate(fresh[:cap]):
            # An entry changed within the slack could share its ctime with a
            # replacement, so only a settled one may enter the cache.
            entry = {"name": name, "ino": ino, "ctime_ns": ctime,
                     "cacheable": ctime < settled, "result": "staged"}
            try:
                data = fmt.read_regular_nofollow(name, bound, "stage", dir_fd=fd,
                                                 after_fstat=lambda: s.fault("stage:after-fstat"),
                                                 tmpdir=".tmp")
            except FileNotFoundError:
                continue
            except fmt.InProgress as exc:
                # The link set the ctime, so it dates the publication.
                entry.update(result="in-progress", cacheable=False, detail=str(exc), stuck=ctime < stuck)
            except fmt.Oversize as exc:
                entry.update(result="oversize", detail=exc.detail)
            except (fmt.NotRegular, OSError) as exc:
                entry.update(result="unsafe-file", detail=str(exc))
            else:
                entry["file"] = "%d.bytes" % n
                with open(os.path.join(rdir, entry["file"]), "wb") as fh:
                    fh.write(data)
            manifest["entries"].append(entry)
        manifest["complete"] = True
        save()
        return manifest
    finally:
        os.close(fd)


def envelope_key(name):
    if name.startswith(".") or not name.endswith(fmt.ENVELOPE_SUFFIX):
        return None
    key = name[:-len(fmt.ENVELOPE_SUFFIX)]
    return key if fmt.valid_name(key) else None


def cmd_stage(owner, a):
    binding, _ = load_binding(owner, a.id)
    stage(owner, a.id, a.run, binding)
    raise Done(0, state="staged", run=a.run)


def cmd_fg_stage(owner, a):
    """A foreground stage: the stage runs in a recorded child, bounded by OUTBOX_IO_BOUND."""
    binding, _ = load_binding(owner, a.id)
    if a.run is None:
        # Named for the caller (the front), so a reconcile between this stage
        # and its ingest-staged keeps the run while the front lives.
        ppid = os.getppid()
        a.run = "%d-%s-%s" % (ppid, fmt.pid_starttime(ppid) or "0", os.urandom(6).hex())
    if not re.fullmatch(r"[0-9]+-[0-9A-Za-z:-]+-[0-9a-f]+", a.run):
        raise Done(USAGE, state="usage", detail="run must be <pid>-<starttime>-<hex>")
    status, got = spawn_recorded_child(owner, "stage", a.origin, a.id, binding["outbox"],
                                       lambda: stage(owner, a.id, a.run, binding) and {"ok": True})
    if status == "timeout":
        log(owner, a.id, "stage timed out", "outbox did not answer within %ds" % OUTBOX_IO_BOUND,
            "the recorded child is killed; run ingest again")
        raise Done(BUSY, state="outbox-unresponsive", code="outbox-unresponsive", run=a.run, detail=got)
    raise Done(0, state="staged" if status == "ok" else "stage-died", run=a.run, child=status, detail=got)


# ---------------------------------------------------------------- receipts and the index of current state

def receipts_of(owner, bid, key):
    """[(seq, obj)] for key, sorted; FormatError on anything unreadable."""
    kdir = owner.dir(bid, "receipts", key)
    try:
        names = fmt.scandir_names(kdir, "engine")
    except FileNotFoundError:
        return []
    out = []
    for name in names:
        seq = fmt.seq_of_name(name)
        if seq is None:
            raise fmt.FormatError("%s/%s: not a seq" % (kdir, name))
        obj = read_json(os.path.join(kdir, name))
        fmt.validate_receipt(obj, seq)
        out.append((seq, obj))
    return sorted(out, key=lambda x: x[0])


class Ctx:
    """One locked engine run on one binding."""

    def __init__(self, owner, bid, finish=True):
        self.owner = owner
        self.bid = bid
        self.tmp = temp_dir(owner, bid)
        if finish:
            # A publication killed before its commit left its temp linked;
            # finishing it here, under the lock, makes every committed-looking
            # entry durable before this run relies on it (fmt.create_exclusive).
            check_id(bid)
            for d in (owner.tmp, self.tmp):
                fmt.reap_dead_temps(d, files_only=True)
        self.binding, self.sha = load_binding(owner, bid)
        self.seq_allocs = 0
        self.touched = set()

    def path(self, *parts):
        return self.owner.dir(self.bid, *parts)

    def receipt(self, key, outcome, **extra):
        obj = {"schema": fmt.RECEIPT_SCHEMA, "outcome": outcome, "recorded_at": fmt.utc_iso(now()),
               "note": fmt.NOTE}
        obj.update(fmt.receipt_identity(self.binding, self.sha, key))
        obj.update(extra)
        return obj

    def alloc_seq(self, key):
        s = fmt.seams()
        self.seq_allocs += 1
        stale = s.value("seq:stale-always")
        if stale is None and self.seq_allocs == 1:
            stale = s.value("seq:stale")
        if stale is not None:
            return stale
        names = fmt.scandir_names(self.path("receipts", key), "engine")
        seqs = [fmt.seq_of_name(n) for n in names]
        return max([q for q in seqs if q] or [0]) + 1

    def write_receipt(self, key, obj):
        """Allocate a seq and create receipts/<K>/<seq>.json exclusively; one retry."""
        kdir = self.path("receipts", key)
        if not os.path.lexists(self.current_path(key)):
            # A key's first receipt: its current/ entry exists before the
            # receipt does, so a crash before refresh_current leaves a stale
            # entry reconcile rebuilds, never a final key nothing announces.
            write_json(self.current_path(key), self.derive_current(key, []), self.tmp, "o-current-dirsync")
        fmt.mkdir_durable(kdir, root=self.owner.root)
        for _ in range(2):
            obj["seq"] = self.alloc_seq(key)
            fmt.validate_receipt(obj)
            try:
                fmt.create_exclusive(os.path.join(kdir, "%d.json" % obj["seq"]), fmt.canonical(obj),
                                     self.tmp, "o-receipt-dirsync")
                self.touched.add(key)
                return obj
            except FileExistsError:
                continue
        self.set_problem(key, "seq-collision")
        log(self.owner, self.bid, "seq collision for " + key, "two exclusive creates found their seq taken",
            "check receipts/%s/ by hand; the level stays until ack-refusal" % key)
        raise Done(UNKNOWN, state="unknown", code="seq-collision", key=key)

    # current/<K>.json: the flat index of each key's current state.

    def current_path(self, key):
        return self.path("current", key + ".json")

    def read_current(self, key):
        try:
            return read_json(self.current_path(key))
        except fmt.FormatError:
            return None

    def derive_current(self, key, receipts, old=None):
        cur = {"schema": fmt.CURRENT_SCHEMA, "binding_id": self.bid, "key": key, "state": "pending",
               "kind": None, "payload_sha256": None, "seq": None, "code": None, "final_at": None,
               "delivered_at": None, "consumed_at": None, "problem": None, "problem_since": None}
        delivered = [o for _, o in receipts if o["outcome"] == "delivered"]
        consumed = [o for _, o in receipts if o["outcome"] == "consumed"]
        refused = [o for _, o in receipts if o["outcome"] == "refused"]
        if delivered:
            d = delivered[0]
            cur.update(state="delivered", kind=d["kind"], payload_sha256=d["payload_sha256"], seq=d["seq"],
                       final_at=d["recorded_at"], delivered_at=d["recorded_at"])
            c = [o for o in consumed if o["delivered_seq"] == d["seq"]]
            if c:
                cur.update(state="consumed", consumed_at=c[0]["recorded_at"], seq=c[0]["seq"])
        elif refused:
            r = refused[0]
            keyed = [o for o in refused if o["scope"] == "key"]
            r = keyed[0] if keyed else r
            cur.update(state="refused", code=r["code"], seq=r["seq"], final_at=r["recorded_at"],
                       kind=r.get("kind"), payload_sha256=r.get("payload_sha256"))
        if delivered and refused:
            cur["code"] = "key-conflict"
        if old:
            cur["problem"], cur["problem_since"] = old.get("problem"), old.get("problem_since")
            if cur["problem"] == "custody-mismatch" and delivered:
                cur["problem"] = cur["problem_since"] = None
        return cur

    def refresh_current(self, key):
        old = self.read_current(key)
        cur = self.derive_current(key, receipts_of(self.owner, self.bid, key), old)
        if cur != old:
            write_json(self.current_path(key), cur, self.tmp, "o-current-dirsync")
        return cur

    def set_problem(self, key, problem):
        old = self.read_current(key) or self.derive_current(key, receipts_of(self.owner, self.bid, key))
        if old.get("problem") == problem:
            return
        old["problem"], old["problem_since"] = problem, fmt.utc_iso(now())
        write_json(self.current_path(key), old, self.tmp, "o-current-dirsync")


def read_cache(owner, bid):
    path = owner.dir(bid, ".ingest-cache")
    try:
        data = fmt.read_regular_nofollow(path, 16 << 20, "engine")
    except (OSError, fmt.NotRegular):
        return set()
    out = set()
    for line in data.decode("utf-8", "replace").splitlines():
        ino, ctime, name = (line.split("\t", 2) + ["", ""])[:3]
        if ino.isdigit() and ctime.isdigit() and name:
            out.add((name, int(ino), int(ctime)))
    return out


def write_cache(ctx, entries, manifest):
    """Keep this run's processed entries, and earlier ones the complete listing still holds.

    A name has one file at a time, so a processed entry replaces every earlier
    entry for its name.
    """
    old = read_cache(ctx.owner, ctx.bid)
    done = {e[0] for e in entries}
    cache = {e for e in old if e[0] not in done}
    if manifest["complete"]:
        listed = set(manifest["names"])
        cache = {e for e in cache if e[0] in listed}
    cache |= entries
    if cache == old:
        return
    lines = "".join("%d\t%d\t%s\n" % (ino, ctime, name) for name, ino, ctime in sorted(cache))
    fmt.replace_durable(ctx.path(".ingest-cache"), lines.encode("utf-8"), ctx.tmp, "o-cache-dirsync")


# ---------------------------------------------------------------- ingest-staged

def validate_envelope(ctx, key, data):
    """('ok', env, payload) or ('key'|'digest', code, (psha, kind) or None)."""
    try:
        env = fmt.parse_canonical(data)
    except fmt.FormatError:
        return "key", "malformed", None
    if not isinstance(env, dict) or tuple(sorted(env)) != fmt.ENVELOPE_FIELDS \
            or not all(isinstance(env[f], str) for f in fmt.ENVELOPE_FIELDS):
        return "key", "malformed", None
    if not env["schema"].startswith(fmt.ENVELOPE_PREFIX) or not fmt.valid_name(env["kind"]) \
            or not fmt.valid_name(env["notice_key"]) or not fmt.valid_sha(env["payload_sha256"]):
        return "key", "malformed", None
    if env["notice_key"] != key:
        return "key", "name-key-mismatch", None
    try:
        payload = fmt.decode_b64(env["payload_b64"])
    except fmt.FormatError:
        return "key", "malformed", None
    if len(payload) > ctx.binding["max_bytes"]:
        return "key", "oversize", None
    if fmt.sha256_hex(payload) != env["payload_sha256"]:
        return "key", "digest-mismatch", None
    digest = (env["payload_sha256"], env["kind"])
    if env["schema"] != fmt.ENVELOPE_SCHEMA:
        return "digest", "version-unsupported", digest
    if env["binding_id"] != ctx.bid or env["binding_sha256"] != ctx.sha:
        return "digest", "binding-mismatch", digest
    if env["kind"] not in ctx.binding["kinds"]:
        return "digest", "kind-not-allowed", digest
    return "ok", env, payload


def refuse_key(ctx, key, code, data=None):
    receipts = receipts_of(ctx.owner, ctx.bid, key)
    if any(o["outcome"] == "refused" and o["scope"] == "key" for _, o in receipts):
        return "replay"
    extra = {"scope": "key", "code": code}
    if data is not None:
        extra["envelope_sha256"] = fmt.sha256_hex(data)
    ctx.write_receipt(key, ctx.receipt(key, "refused", **extra))
    fmt.seams().fault("ingest:after-refusal")
    ctx.refresh_current(key)
    log(ctx.owner, ctx.bid, "refused %s (%s)" % (key, code), "the envelope failed validation",
        "the producer's query answers refused; ack-refusal clears the level")
    return "refused"


def refuse_digest(ctx, key, code, digest, data):
    receipts = receipts_of(ctx.owner, ctx.bid, key)
    if any(o["outcome"] == "refused" and o["scope"] == "key" for _, o in receipts):
        return "replay"
    if any(fmt.receipt_digest(o) == digest for _, o in receipts):
        ctx.refresh_current(key)
        return "replay"
    ctx.write_receipt(key, ctx.receipt(key, "refused", scope="digest", code=code, kind=digest[1],
                                       payload_sha256=digest[0], envelope_sha256=fmt.sha256_hex(data)))
    fmt.seams().fault("ingest:after-refusal")
    ctx.refresh_current(key)
    log(ctx.owner, ctx.bid, "refused %s (%s)" % (key, code), "digest %s" % digest[0][:12],
        "the producer's query answers refused or key-conflict; ack-refusal clears the level")
    return "refused"


def deliver(ctx, key, data, payload_check=True):
    """Custody, re-read compare, delivered receipt. Returns the outcome word."""
    s = fmt.seams()
    custody = ctx.path("custody", key + ".notice")
    try:
        fmt.create_exclusive(custody, data, ctx.tmp, "o-custody-dirsync")
    except FileExistsError:
        try:
            have = fmt.read_regular_nofollow(custody, len(data) + 1, "engine")
        except (OSError, fmt.NotRegular):
            have = None
        if have != data:
            fmt.replace_durable(custody, data, ctx.tmp, "o-custody-dirsync")
        else:
            # Equal custody may be a run's that died before its directory
            # fsync, so the barrier is finished before a receipt relies on it.
            fmt.fsync_dir(os.path.dirname(custody), "o-custody-dirsync")
    s.fault("ingest:after-custody-fsync")
    try:
        again = fmt.read_regular_nofollow(custody, fmt.envelope_cap(ctx.binding["max_bytes"]), "engine")
    except (OSError, fmt.NotRegular):
        again = None
    if again != data:
        ctx.set_problem(key, "custody-mismatch")
        log(ctx.owner, ctx.bid, "custody mismatch for " + key, "the re-read custody bytes differ from the "
            "validated bytes, so no receipt was written", "the next ingest replaces custody")
        return "custody-mismatch"
    env = fmt.parse_canonical(again)
    ctx.write_receipt(key, ctx.receipt(key, "delivered", kind=env["kind"],
                                       payload_sha256=fmt.sha256_hex(fmt.decode_b64(env["payload_b64"])),
                                       envelope_sha256=fmt.sha256_hex(again), envelope_bytes=len(again)))
    s.fault("ingest:after-receipt")
    ctx.refresh_current(key)
    log(ctx.owner, ctx.bid, "delivered " + key, "custody holds the validated envelope",
        "announce, then the owner shows and consumes it")
    return "delivered"


def route_valid(ctx, key, env, data):
    digest = (env["payload_sha256"], env["kind"])
    receipts = receipts_of(ctx.owner, ctx.bid, key)
    if any(o["outcome"] == "refused" and o["scope"] == "key" for _, o in receipts):
        return "replay"
    delivered = [o for _, o in receipts if o["outcome"] == "delivered"]
    if any(fmt.receipt_digest(o) == digest for o in delivered):
        ctx.refresh_current(key)
        return "replay"
    if receipts:
        if any(fmt.receipt_digest(o) == digest for _, o in receipts):
            ctx.refresh_current(key)
            return "replay"
        return refuse_digest(ctx, key, "key-conflict", digest, data)
    return deliver(ctx, key, data)


def ingest_entry(ctx, entry, rdir, retired):
    key = envelope_key(entry["name"])
    if key is None:
        return None
    fmt.seams().fault("stage-entry:before-route")
    if entry["result"] == "in-progress":
        # A submit has not committed this envelope yet; the next ingest reads it.
        return "in-progress"
    if entry["result"] in ("unsafe-file", "oversize"):
        return refuse_key(ctx, key, entry["result"])
    try:
        data = fmt.read_regular_nofollow(os.path.join(rdir, entry["file"]),
                                         fmt.envelope_cap(ctx.binding["max_bytes"]), "ingest")
    except fmt.Oversize:
        return refuse_key(ctx, key, "oversize")
    receipts = receipts_of(ctx.owner, ctx.bid, key)
    if retired:
        if receipts:
            return "replay"
        return refuse_key(ctx, key, "binding-retired", data)
    verdict = validate_envelope(ctx, key, data)
    if verdict[0] == "key":
        return refuse_key(ctx, key, verdict[1], data)
    if verdict[0] == "digest":
        return refuse_digest(ctx, key, verdict[1], verdict[2], data)
    return route_valid(ctx, key, verdict[1], data)


def read_manifest(ctx, run):
    rdir = os.path.join(ctx.tmp, run)
    try:
        m = read_json(os.path.join(rdir, "manifest.json"), 64 << 20)
    except fmt.FormatError:
        m = None
    return rdir, m


def cmd_ingest_staged(owner, a):
    require_lock(a.lock)
    ctx = Ctx(owner, a.id)
    rdir, manifest = read_manifest(ctx, a.run)
    if manifest is None or manifest.get("binding_id") != a.id:
        reconcile(ctx, keep=(a.run,))
        raise Done(UNKNOWN, state="unknown", code="manifest-unreadable", run=a.run)
    retired = is_retired(owner, a.id)
    outcomes, processed = {}, set()
    for entry in manifest["entries"]:
        got = ingest_entry(ctx, entry, rdir, retired)
        if got is None:
            continue
        outcomes[entry["name"]] = got
        if got in ("delivered", "refused", "replay") and entry.get("cacheable"):
            processed.add((entry["name"], entry["ino"], entry["ctime_ns"]))
    if processed or manifest["complete"]:
        write_cache(ctx, processed, manifest)
    reconcile(ctx, manifest=manifest, keep=(a.run,))
    if manifest["complete"]:
        write_index(ctx, manifest)
    write_outbox_status(ctx, manifest)
    retention(ctx)
    shutil.rmtree(rdir, ignore_errors=True)
    # A stage refusal (the outbox itself was refused) is the run's answer; its
    # level is raised by alarms.
    raise Done(REFUSED if manifest["code"] else 0, state="ingested", run=a.run,
               complete=manifest["complete"], code=manifest["code"],
               cap_hit=manifest["cap_hit"], outcomes=outcomes, lists_stale=stale_lists(owner))


def write_outbox_status(ctx, manifest):
    path = ctx.path(".outbox-status")
    try:
        old = read_json(path)
    except fmt.FormatError:
        old = None
    code = manifest["code"]
    cur = {"code": code, "backlog": bool(manifest["backlog"]), "complete": bool(manifest["complete"])}
    # An entry stuck in progress keeps its level until a complete listing no
    # longer finds it stuck: a partial listing is unknown, never a clear.
    stuck = {e["name"]: fmt.utc_iso(e["ctime_ns"] // 10**9) for e in manifest["entries"]
             if e["result"] == "in-progress" and e.get("stuck") and envelope_key(e["name"])}
    if not manifest["complete"] and old:
        for e in old.get("in_progress") or []:
            stuck.setdefault(e["name"], e["since"])
    cur["in_progress"] = [{"name": n, "since": stuck[n]} for n in sorted(stuck)]
    if old and old.get("code") == code and old.get("backlog") == cur["backlog"]:
        cur["since"] = old.get("since")
    else:
        cur["since"] = fmt.utc_iso(now())
    if cur != old:
        write_json(path, cur, ctx.tmp, "o-status-dirsync")
    if code:
        log(ctx.owner, ctx.bid, "stage refused: " + code, "the outbox failed its identity, type or open check",
            "nothing was staged; fix the outbox or rebind")


def write_index(ctx, manifest):
    """fm-owner-notice-outbox-index/v1 from a complete listing (M-1, R3-n3)."""
    path = ctx.path(".outbox-index")
    try:
        old = read_json(path, 64 << 20) or {}
    except fmt.FormatError:
        old = {}
    prev = {e["name"]: e for e in old.get("entries", [])}
    listed = manifest["listed_at"]
    names = [n for n in manifest["names"] if envelope_key(n) is not None]
    entries = {}
    for n in names:
        entries[n] = {"name": n, "first_seen": prev.get(n, {}).get("first_seen", listed)}
    for n, e in prev.items():
        if n in entries:
            continue
        if receipts_of(ctx.owner, ctx.bid, envelope_key(n)):
            continue
        entries[n] = {"name": n, "first_seen": e["first_seen"], "vanished_at": e.get("vanished_at", listed)}
    ordered = sorted(entries.values(), key=lambda e: (e["first_seen"], e["name"]))
    me, mestart = fmt.own_identity()
    index = {"schema": fmt.INDEX_SCHEMA, "binding_id": ctx.bid, "listed_at": listed,
             "written_at": now(), "stage_pid": manifest["stage_pid"],
             "stage_starttime": manifest["stage_starttime"], "mtime_ns": manifest["mtime_ns"],
             "complete": True, "truncated": len(ordered) > BACKLOG_NAMES,
             "entries": ordered[:BACKLOG_NAMES]}
    # An unchanged listing writes no file; freshness is judged from .beat, never
    # from the index's own times.
    same = ("mtime_ns", "complete", "truncated", "entries")
    if old.get("schema") == fmt.INDEX_SCHEMA and all(old.get(f) == index[f] for f in same):
        return
    write_json(path, index, ctx.tmp, "o-index-dirsync")


# ---------------------------------------------------------------- reconcile

def reconcile(ctx, manifest=None, keep=()):
    """Crash repair under the binding lock; see the crash table in docs/owner-notice.md."""
    fmt.reap_dead_temps(ctx.tmp, keep=set(keep))
    custody = set(n[:-7] for n in fmt.scandir_names(ctx.path("custody"), "engine") if n.endswith(".notice"))
    handled = set(n[:-7] for n in fmt.scandir_names(ctx.path("handled"), "engine") if n.endswith(".notice"))
    for key in sorted(handled):
        if fmt.valid_name(key):
            finish_consume(ctx, key)
    listed = None
    if manifest and manifest.get("complete") and manifest.get("names") is not None:
        listed = set(manifest["names"])
    for key in sorted(custody - handled):
        if not fmt.valid_name(key):
            continue
        if receipts_of(ctx.owner, ctx.bid, key):
            continue
        if listed is None or key + fmt.ENVELOPE_SUFFIX in listed:
            continue
        orphan(ctx, key)
    for name in fmt.scandir_names(ctx.path("current"), "engine"):
        if name.endswith(".json") and fmt.valid_name(name[:-5]):
            ctx.refresh_current(name[:-5])
    retiring = ctx.owner.marker(ctx.bid, ".retiring")
    try:
        age = now() - os.lstat(retiring).st_mtime
    except FileNotFoundError:
        age = None
    if age is not None and age > RETIRING_STALE:
        fmt.unlink_durable(retiring, "o-retiring-dirsync")
        log(ctx.owner, ctx.bid, "removed a stale .retiring", "no retire held the lock for %ds" % age,
            "submits work again")


def orphan(ctx, key):
    """n2: custody with no receipt and no envelope in a complete listing."""
    custody = ctx.path("custody", key + ".notice")
    try:
        data = fmt.read_regular_nofollow(custody, fmt.envelope_cap(ctx.binding["max_bytes"]), "engine")
    except (OSError, fmt.NotRegular):
        data = None
    verdict = validate_envelope(ctx, key, data) if data is not None else ("key", "unreadable", None)
    if verdict[0] != "ok":
        ctx.set_problem(key, "orphan-custody")
        log(ctx.owner, ctx.bid, "orphan custody for " + key, "custody fails validation (%s)" % verdict[1],
            "nothing is written; inspect custody/%s.notice, then ack-refusal" % key)
        return
    deliver(ctx, key, data)


def finish_consume(ctx, key):
    """Repair a consume cut short: custody left beside handled, or no consumed receipt."""
    custody = ctx.path("custody", key + ".notice")
    handled = ctx.path("handled", key + ".notice")
    if os.path.lexists(custody):
        try:
            same = os.path.samefile(custody, handled) or \
                fmt.read_regular_nofollow(custody, 1 << 20) == fmt.read_regular_nofollow(handled, 1 << 20)
        except (OSError, fmt.NotRegular):
            same = False
        if same:
            fmt.unlink_durable(custody, "o-custody-unlink-dirsync")
            fmt.seams().fault("consume:after-unlink")
    receipts = receipts_of(ctx.owner, ctx.bid, key)
    delivered = [o for _, o in receipts if o["outcome"] == "delivered"]
    if not delivered:
        return None
    d = delivered[0]
    done = [o for _, o in receipts if o["outcome"] == "consumed" and o["delivered_seq"] == d["seq"]]
    if done:
        return done[0]
    obj = ctx.write_receipt(key, ctx.receipt(key, "consumed", kind=d["kind"], payload_sha256=d["payload_sha256"],
                                             envelope_sha256=d["envelope_sha256"], delivered_seq=d["seq"]))
    fmt.seams().fault("consume:after-receipt")
    ctx.refresh_current(key)
    return obj


# ---------------------------------------------------------------- consume, acks

def cmd_consume(owner, a):
    require_lock(a.lock)
    check_key(a.key)
    ctx = Ctx(owner, a.id)
    receipts = receipts_of(owner, a.id, a.key)
    delivered = [o for _, o in receipts if o["outcome"] == "delivered"]
    if not delivered:
        raise Done(REFUSED, state="refused", code="not-delivered", key=a.key)
    done = [o for _, o in receipts if o["outcome"] == "consumed"]
    custody = ctx.path("custody", a.key + ".notice")
    handled = ctx.path("handled", a.key + ".notice")
    if done and not os.path.lexists(custody):
        ctx.refresh_current(a.key)
        raise Done(0, state="consumed", key=a.key, seq=done[0]["seq"], replay=True)
    if not os.path.lexists(handled):
        try:
            os.link(custody, handled)
        except FileNotFoundError:
            raise Done(UNKNOWN, state="unknown", code="custody-missing", key=a.key, path=custody)
        fmt.seams().spy_line("link", handled)
        fmt.seams().fault("consume:after-handled-link")
    # Every pass, so a consume that died between its link and this fsync is
    # finished before its consumed receipt.
    fmt.fsync_dir(ctx.path("handled"), "o-handled-dirsync")
    fmt.seams().fault("consume:after-link")
    obj = finish_consume(ctx, a.key)
    log(owner, a.id, "consumed " + a.key, "note: " + (a.note or "-").replace("\n", " "),
        "retention removes handled custody after 30 days")
    raise Done(0, state="consumed", key=a.key, seq=obj["seq"], replay=False)


def cmd_ack_refusal(owner, a):
    require_lock(a.lock)
    check_key(a.key)
    ctx = Ctx(owner, a.id)
    receipts = receipts_of(owner, a.id, a.key)
    cur = ctx.read_current(a.key) or {}
    if not any(o["outcome"] == "refused" for _, o in receipts) and cur.get("problem") not in PROBLEMS:
        raise Done(REFUSED, state="refused", code="not-refused", key=a.key)
    marker = ctx.path(".acked", a.key)
    try:
        fmt.create_exclusive(marker, fmt.canonical({"at": fmt.utc_iso(now()), "note": a.note}), ctx.tmp,
                             "o-acked-dirsync")
        replay = False
    except FileExistsError:
        replay = True
    log(owner, a.id, "acknowledged refusal of " + a.key, "note: " + a.note.replace("\n", " "),
        "its refusal levels leave the alert store; the producer's answer is unchanged")
    raise Done(0, state="acked", key=a.key, replay=replay)


def cmd_ack_vanished(owner, a):
    require_lock(a.lock)
    ctx = Ctx(owner, a.id)
    path = ctx.path(".outbox-index")
    try:
        index = read_json(path, 64 << 20)
    except fmt.FormatError as exc:
        raise Done(UNKNOWN, state="unknown", code="index-unreadable", detail=str(exc))
    entries = (index or {}).get("entries", [])
    hit = [e for e in entries if e["name"] == a.name and "vanished_at" in e]
    if not hit:
        raise Done(REFUSED, state="refused", code="not-vanished", name=a.name)
    index["entries"] = [e for e in entries if e is not hit[0]]
    write_json(path, index, ctx.tmp, "o-index-dirsync")
    log(owner, a.id, "acknowledged vanished envelope " + a.name, "note: " + a.note.replace("\n", " "),
        "the name leaves the outbox index")
    raise Done(0, state="acked", name=a.name)


# ---------------------------------------------------------------- retire, purge, retention

def list_outbox(outbox, binding):
    out = {"names": None}
    try:
        fd = os.open(outbox, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC)
    except FileNotFoundError:
        out["names"] = []
        return out
    except OSError as exc:
        out["error"] = exc.strerror
        return out
    try:
        st = os.fstat(fd)
        if (st.st_dev, st.st_ino) != (binding["outbox_dev"], binding["outbox_ino"]):
            out["error"] = "outbox-identity-changed"
            return out
        with os.scandir(fd) as it:
            out["names"] = sorted(e.name for e in it if not e.name.startswith("."))
    finally:
        os.close(fd)
    return out


def cmd_retire(owner, a):
    require_lock(a.lock)
    require_lock(a.bindings_lock)
    ctx = Ctx(owner, a.id)
    retiring = owner.marker(a.id, ".retiring")
    if is_retired(owner, a.id):
        # A retire that died after .retired finishes its bookkeeping here.
        if os.path.lexists(retiring):
            fmt._unlink_quiet(retiring)
            fmt.fsync_dir(owner.bindings, "o-retiring-dirsync")
        rebuild_lists(owner)
        raise Done(0, state="retired", binding_id=a.id, replay=True, lists_stale=stale_lists(owner))
    try:
        fmt.create_exclusive(retiring, fmt.canonical({"at": fmt.utc_iso(now())}), owner.tmp, "o-retiring-dirsync")
    except FileExistsError:
        pass

    def undo():
        fmt._unlink_quiet(retiring)
        fmt.fsync_dir(owner.bindings, "o-retiring-dirsync")

    status, got = spawn_recorded_child(owner, "stage", "retire", a.id, ctx.binding["outbox"],
                                       lambda: list_outbox(ctx.binding["outbox"], ctx.binding))
    if status != "ok" or got.get("names") is None:
        undo()
        if status == "timeout":
            raise Done(BUSY, state="outbox-unresponsive", code="outbox-unresponsive", detail=got)
        raise Done(UNKNOWN, state="unknown", code="outbox-unreadable", detail=got)
    # The decision reads receipt truth, refreshing current/ from it, because
    # current/ is a repairable index a crash can leave behind its receipts.
    outbox_keys = set(k for k in map(envelope_key, got["names"]) if k is not None)
    try:
        keys = set(n for n in fmt.scandir_names(ctx.path("receipts"), "engine") if fmt.valid_name(n))
        keys |= set(n[:-5] for n in fmt.scandir_names(ctx.path("current"), "engine")
                    if n.endswith(".json") and fmt.valid_name(n[:-5]))
        truth = {}
        for key in sorted(keys):
            truth[key] = ctx.refresh_current(key)
        for key in sorted(outbox_keys - keys):
            truth[key] = ctx.derive_current(key, receipts_of(owner, a.id, key))
    except (OSError, fmt.FormatError) as exc:
        undo()
        log(owner, a.id, "retire refused", "receipts or current entries cannot be read: %s" % exc,
            "repair them (reconcile names the file), then retire again")
        raise Done(UNKNOWN, state="unknown", code="receipts-unreadable", detail=str(exc))
    busy = []
    for key, cur in truth.items():
        if key in outbox_keys and cur["state"] == "pending":
            busy.append(key)
        if cur["state"] == "delivered":
            busy.append(key)
        if cur["state"] in FINAL and not os.path.lexists(ctx.path(".announced", key)):
            busy.append(key)
    if busy:
        undo()
        log(owner, a.id, "retire refused", "keys still need work: " + " ".join(sorted(set(busy))),
            "ingest, consume or announce them, then retire again")
        raise Done(REFUSED, state="refused", code="retire-busy", keys=sorted(set(busy)))
    fmt.seams().fault("retire:after-check")
    try:
        fmt.create_exclusive(owner.marker(a.id, ".retired"), fmt.canonical({"retired_at": fmt.utc_iso(now())}),
                             owner.tmp, "o-retired-dirsync")
    except FileExistsError:
        pass
    fmt.seams().fault("retire:after-retired")
    undo()
    rebuild_lists(owner)
    log(owner, a.id, "retired", "no envelope, delivery or announce was pending",
        "stragglers get binding-retired refusals for 7 days")
    raise Done(0, state="retired", binding_id=a.id, replay=False, lists_stale=stale_lists(owner))


def retention(ctx):
    t = now()
    for name in fmt.scandir_names(ctx.path("handled"), "engine"):
        key = name[:-7]
        if not name.endswith(".notice") or not fmt.valid_name(key):
            continue
        consumed = [o for _, o in receipts_of(ctx.owner, ctx.bid, key) if o["outcome"] == "consumed"]
        if consumed and t - fmt.parse_iso(consumed[0]["recorded_at"]) >= HANDLED_KEEP:
            fmt.unlink_durable(ctx.path("handled", name), "o-handled-dirsync")
    for name in fmt.scandir_names(ctx.path("current"), "engine"):
        key = name[:-5]
        cur = ctx.read_current(key)
        if not cur:
            continue
        since = None
        if cur["state"] == "consumed":
            since = fmt.parse_iso(cur["consumed_at"])
        elif cur["state"] == "refused":
            try:
                since = os.lstat(ctx.path(".acked", key)).st_mtime
            except FileNotFoundError:
                since = None
        if since is None or t - since < CURRENT_KEEP:
            continue
        month = time.strftime("%Y-%m", time.gmtime(t))
        adir = ctx.path("archive", month)
        fmt.mkdir_durable(adir, root=ctx.owner.root)
        dest = os.path.join(adir, name)
        try:
            os.link(ctx.current_path(key), dest)
            fmt.seams().spy_line("link", dest)
        except FileExistsError:
            pass
        fmt.fsync_dir(adir, "o-archive-dirsync")
        fmt.seams().fault("retention:after-archive-link")
        fmt.unlink_durable(ctx.current_path(key), "o-current-dirsync")


def cmd_retention(owner, a):
    require_lock(a.lock)
    retention(Ctx(owner, a.id))
    raise Done(0, state="retained", binding_id=a.id)


def cmd_reconcile(owner, a):
    require_lock(a.lock)
    reconcile(Ctx(owner, a.id))
    raise Done(0, state="reconciled", binding_id=a.id, lists_stale=stale_lists(owner))


def cmd_purge(owner, a):
    require_lock(a.lock)
    require_lock(a.bindings_lock)
    ctx = Ctx(owner, a.id)
    if not is_retired(owner, a.id):
        raise Done(REFUSED, state="refused", code="not-retired", binding_id=a.id)
    # The clock starts at the later of the retire and the last receipt, so a
    # binding retired with no receipts still keeps its tree for PURGE_AFTER.
    try:
        last = fmt.parse_iso(read_json(owner.marker(a.id, ".retired"))["retired_at"])
    except (fmt.FormatError, KeyError, TypeError):
        raise Done(UNKNOWN, state="unknown", code="retired-unreadable", binding_id=a.id)
    rdir = ctx.path("receipts")
    if os.path.isdir(rdir):
        for key in fmt.scandir_names(rdir, "engine"):
            for _, o in receipts_of(owner, a.id, key):
                last = max(last, fmt.parse_iso(o["recorded_at"]))
    if now() - last < PURGE_AFTER:
        raise Done(REFUSED, state="refused", code="purge-too-early", since=fmt.utc_iso(last))
    shutil.rmtree(owner.dir(a.id))
    fmt.fsync_dir(owner.root, "o-purge-dirsync")
    rebuild_lists(owner)
    log(owner, None, "purged binding " + a.id, "365 days since the retire and the last receipt",
        "bindings/%s.json and .retired stay, so the id stays reserved" % a.id)
    raise Done(0, state="purged", binding_id=a.id, lists_stale=stale_lists(owner))


# ---------------------------------------------------------------- announce

def cmd_announce_list(owner, a):
    require_lock(a.lock)
    ctx = Ctx(owner, a.id)
    rows = []
    for name in fmt.scandir_names(ctx.path("current"), "engine"):
        key = name[:-5]
        if not name.endswith(".json") or not fmt.valid_name(key):
            continue
        cur = ctx.read_current(key)
        if not cur or cur["state"] == "pending":
            # A crash between a receipt and its refresh leaves current/ behind
            # the receipts; announce from their truth. Unreadable receipts
            # stay unannounced and raise current-unreadable in alarms.
            try:
                cur = ctx.refresh_current(key)
            except fmt.FormatError:
                continue
        if cur["state"] not in FINAL or os.path.lexists(ctx.path(".announced", key)):
            continue
        outcome = cur["state"] if cur["state"] != "refused" else "refused:" + cur["code"]
        rows.append({"key": key, "kind": cur["kind"] or "-", "outcome": outcome,
                     "consumed": cur["state"] == "consumed"})
    raise Done(0, state="listed", rows=rows)


def cmd_mark_announced(owner, a):
    require_lock(a.lock)
    ctx = Ctx(owner, a.id)
    for key in a.keys:
        check_key(key)
        try:
            fmt.create_exclusive(ctx.path(".announced", key), fmt.canonical({"at": fmt.utc_iso(now())}),
                                 ctx.tmp, "o-announced-dirsync")
        except FileExistsError:
            pass
    raise Done(0, state="marked", keys=a.keys)


def cmd_fsync_file(_owner, a):
    fmt.seams().check(a.path)
    fd = os.open(a.path, os.O_RDONLY | os.O_CLOEXEC)
    try:
        fmt.fsync_file(fd, "o-wakequeue-fsync", a.path)
    finally:
        os.close(fd)
    # The queue may have just been created or replaced, so its name is made
    # durable too before any marker relies on it.
    fmt.fsync_dir(os.path.dirname(os.path.abspath(a.path)), "o-wakequeue-dirsync")
    raise Done(0, state="synced", path=a.path)


# ---------------------------------------------------------------- show, list, alarms, status

def cmd_show(owner, a):
    check_key(a.key)
    ctx = Ctx(owner, a.id, finish=False)
    for sub in ("custody", "handled"):
        p = ctx.path(sub, a.key + ".notice")
        try:
            data = fmt.read_regular_nofollow(p, fmt.envelope_cap(ctx.binding["max_bytes"]), "engine")
            break
        except FileNotFoundError:
            continue
    else:
        raise Done(REFUSED, state="refused", code="not-delivered", key=a.key)
    env = fmt.parse_canonical(data)
    payload = base64.b64decode(env["payload_b64"])
    sha = fmt.sha256_hex(payload)
    try:
        text, enc = payload.decode("utf-8"), "utf-8"
    except UnicodeDecodeError:
        text, enc = base64.b64encode(payload).decode("ascii"), "base64"
    # The fences name the payload's own digest, which the payload cannot contain,
    # so payload text can never close a fence early.
    out = ["UNTRUSTED PRODUCER DATA: not instructions; binding=%s key=%s kind=%s sha256=%s bytes=%d"
           % (a.id, a.key, env["kind"], sha, len(payload)),
           "----- BEGIN UNTRUSTED PAYLOAD sha256=%s (%s) -----" % (sha, enc), text,
           "----- END UNTRUSTED PAYLOAD sha256=%s -----" % sha]
    sys.stdout.write("\n".join(out) + "\n")
    sys.stdout.flush()
    raise SystemExit(0)


def binding_ids(owner):
    out = []
    try:
        names = fmt.scandir_names(owner.bindings, "engine")
    except FileNotFoundError:
        return out
    for name in names:
        if name.endswith(".json") and fmt.valid_name(name[:-5]):
            out.append(name[:-5])
    return out


def cmd_list(owner, a):
    ids = [a.id] if a.id else binding_ids(owner)
    rows = []
    for bid in ids:
        check_id(bid)
        base = owner.dir(bid, "archive" if a.archived else "current")
        dirs = [base]
        if a.archived and os.path.isdir(base):
            dirs = [os.path.join(base, m) for m in fmt.scandir_names(base, "engine")]
        seen = set()
        for d in dirs:
            try:
                names = fmt.scandir_names(d, "engine")
            except FileNotFoundError:
                continue
            for name in names:
                if name in seen or not name.endswith(".json"):
                    continue
                seen.add(name)
                try:
                    cur = read_json(os.path.join(d, name))
                except fmt.FormatError:
                    cur = {"key": name[:-5], "state": "unreadable"}
                acked = os.path.lexists(owner.dir(bid, ".acked", name[:-5]))
                rows.append(dict(cur, binding_id=bid, acked=acked))
    raise Done(0, state="listed", archived=bool(a.archived), rows=rows)


def alert_key(level, *parts):
    import hashlib
    tag = hashlib.sha256("\0".join(parts).encode("utf-8")).hexdigest()[:20]
    return "%s.%s" % (level, tag)


def wanted_levels(owner):
    """(wanted set, complete): {alert key: {kind, subject, reason, since, evidence}}, and whether every source was read.

    A binding, current/ entry or receipt that cannot be read raises its own
    source level and makes the set incomplete, so the front asserts what it
    knows and clears nothing: an unknown source is never an empty one.
    """
    wanted = {}
    t = now()
    complete = [True]

    def want(level, bid, key, reason, since, **evidence):
        name = "%s:%s" % (level, key if key is not None else bid)
        akey = alert_key(level, bid, key or "")
        wanted[akey] = {"kind": level, "subject": "%s/%s" % (bid, key) if key else bid,
                        "reason": "%s (binding %s): %s" % (name, bid, reason), "since": since,
                        "evidence": dict(evidence, level=name, binding_id=bid)}

    def unknown(level, bid, key, reason, **evidence):
        complete[0] = False
        want(level, bid, key, reason, fmt.utc_iso(t), **evidence)

    for bid in binding_ids(owner):
        if is_purged(owner, bid):
            continue
        try:
            ctx = Ctx(owner, bid, finish=False)
        except Done as d:
            unknown("binding-unreadable", bid, None, "the binding record cannot be read",
                    path=owner.binding_path(bid), detail=d.result.get("detail"))
            continue
        status_path = ctx.path(".outbox-status")
        try:
            st = read_json(status_path)
        except fmt.FormatError:
            st = {"code": "outbox-unreadable", "since": fmt.utc_iso(t), "backlog": False}
        if st and st.get("code") in STAGE_REFUSALS:
            want(st["code"], bid, None, "the last stage refused the outbox", st["since"], path=status_path)
        if st and st.get("backlog"):
            want("outbox-backlog", bid, None, "more than %d outbox entries" % BACKLOG_NAMES, st["since"])
        for e in (st or {}).get("in_progress") or []:
            want("outbox-in-progress", bid, envelope_key(e["name"]),
                 "%s is still in progress %ds after its link" % (e["name"], IN_PROGRESS_SETTLE), e["since"],
                 path=os.path.join(ctx.binding["outbox"], e["name"]))
        if not os.access(ctx.path("receipts"), os.R_OK | os.X_OK):
            unknown("receipts-unreadable", bid, None, "receipts/ cannot be listed")
        try:
            names = fmt.scandir_names(ctx.path("current"), "engine")
        except FileNotFoundError:
            names = []
        except OSError as exc:
            unknown("current-unreadable", bid, None, "current/ cannot be listed", detail=exc.strerror)
            names = []
        if len(names) > CURRENT_BACKLOG:
            want("current-backlog", bid, None, "%d entries in current/" % len(names), fmt.utc_iso(t))
        for name in names:
            key = name[:-5]
            if not name.endswith(".json") or not fmt.valid_name(key):
                continue
            cur = ctx.read_current(key)
            if not cur or cur["state"] == "pending":
                # An unreadable or crash-stale entry is read from the receipts.
                if not cur:
                    unknown("current-unreadable", bid, key, "current/%s cannot be read" % name,
                            path=ctx.current_path(key))
                try:
                    cur = ctx.derive_current(key, receipts_of(owner, bid, key), cur)
                except fmt.FormatError as exc:
                    unknown("receipts-unreadable", bid, key, "receipts/%s cannot be read" % key, detail=str(exc))
                    continue
            acked = os.path.lexists(ctx.path(".acked", key))
            if cur.get("problem") in PROBLEMS and not acked:
                want(cur["problem"], bid, key, "see the binding log", cur["problem_since"])
            if cur["state"] == "refused" and not acked:
                level = "unsafe-file" if cur["code"] == "unsafe-file" else "refused"
                want(level, bid, key, "refused with code %s" % cur["code"], cur["final_at"], code=cur["code"])
            if cur.get("code") == "key-conflict" and cur["state"] != "refused" and not acked:
                want("refused", bid, key, "a conflicting digest was refused", cur["final_at"], code="key-conflict")
            if cur["state"] in FINAL and not os.path.lexists(ctx.path(".announced", key)) \
                    and t - fmt.parse_iso(cur["final_at"]) > RUNNER_LOOP:
                want("unannounced", bid, key, "final receipt with no wake marker", cur["final_at"])
            if cur["state"] == "delivered" and \
                    t - fmt.parse_iso(cur["delivered_at"]) > ctx.binding["consume_bound_seconds"]:
                want("unconsumed", bid, key, "delivered and not consumed within %ds"
                     % ctx.binding["consume_bound_seconds"], cur["delivered_at"])
    return wanted, complete[0]


def cmd_alarms(owner, a):
    wanted, complete = wanted_levels(owner)
    fmt.seams().check(a.out)
    with open(a.out, "w", encoding="utf-8") as fh:
        json.dump(wanted, fh, sort_keys=True)
    raise Done(0, state="alarms", count=len(wanted), keys=sorted(wanted), complete=complete)


def cmd_status(owner, _a):
    rows = []
    for bid in binding_ids(owner):
        if is_purged(owner, bid):
            rows.append({"binding_id": bid, "retired": True, "purged": True})
            continue
        try:
            ctx = Ctx(owner, bid, finish=False)
        except Done as d:
            rows.append({"binding_id": bid, "error": d.result})
            continue
        counts = {}
        for name in fmt.scandir_names(ctx.path("current"), "engine"):
            cur = ctx.read_current(name[:-5]) or {"state": "unreadable"}
            counts[cur["state"]] = counts.get(cur["state"], 0) + 1
        rows.append({"binding_id": bid, "retired": is_retired(owner, bid),
                     "retiring": os.path.lexists(owner.marker(bid, ".retiring")), "current": counts})
    wanted, complete = wanted_levels(owner)
    raise Done(0, state="status", bindings=rows, alarms_complete=complete,
               alarms=sorted(v["evidence"]["level"] + " " + v["evidence"]["binding_id"] for v in wanted.values()))


# ---------------------------------------------------------------- arguments

class Parser(argparse.ArgumentParser):
    def error(self, message):
        raise Done(USAGE, state="usage", detail=message)


def build_parser():
    p = Parser(prog="fm_owner_notice_store.py")
    sub = p.add_subparsers(dest="cmd", parser_class=Parser)

    def add(name, lock=True, *pos):
        s = sub.add_parser(name)
        s.add_argument("--home", required=True)
        if lock:
            s.add_argument("--lock", required=True)
        for x in pos:
            s.add_argument(x)
        return s

    for name, lock in (("bind-inspect", False), ("bind", True)):
        b = add(name, lock, "id")
        b.add_argument("--outbox", required=True)
        b.add_argument("--producer-actor", required=True)
        b.add_argument("--producer-uid", type=int, required=True)
        b.add_argument("--kinds", required=True)
        b.add_argument("--max-bytes", type=int, required=True)
        b.add_argument("--consume-bound-seconds", type=int, required=True)
        if lock:
            b.add_argument("--outbox-dev", type=int, required=True)
            b.add_argument("--outbox-ino", type=int, required=True)
    f = add("fg-stage", False, "id")
    f.add_argument("run", nargs="?")
    f.add_argument("--origin", choices=("ingest",), default="ingest")
    add("stage", False, "id", "run")
    add("ingest-staged", True, "id", "run")
    add("reconcile", True, "id")
    add("retention", True, "id")
    add("announce-list", True, "id")
    m = add("mark-announced", True, "id")
    m.add_argument("keys", nargs="+")
    c = add("consume", True, "id", "key")
    c.add_argument("--note", default="")
    for name, pos in (("ack-refusal", "key"), ("ack-vanished", "name")):
        x = add(name, True, "id", pos)
        x.add_argument("--note", required=True)
    for name in ("retire", "purge"):
        x = add(name, True, "id")
        x.add_argument("--bindings-lock", required=True)
    add("show", False, "id", "key")
    lst = add("list", False)
    lst.add_argument("--archived", action="store_true")
    lst.add_argument("id", nargs="?")
    al = add("alarms", False)
    al.add_argument("--out", required=True)
    add("status", False)
    ls = add("lists", False)
    ls.add_argument("--bindings-lock", required=True)
    fs = sub.add_parser("fsync-file")
    fs.add_argument("path")
    return p


COMMANDS = {
    "bind-inspect": cmd_bind_inspect, "bind": cmd_bind, "fg-stage": cmd_fg_stage, "stage": cmd_stage, "ingest-staged": cmd_ingest_staged,
    "reconcile": cmd_reconcile, "retention": cmd_retention, "announce-list": cmd_announce_list,
    "mark-announced": cmd_mark_announced, "consume": cmd_consume, "ack-refusal": cmd_ack_refusal,
    "ack-vanished": cmd_ack_vanished, "retire": cmd_retire, "purge": cmd_purge, "show": cmd_show,
    "list": cmd_list, "lists": cmd_lists, "alarms": cmd_alarms, "status": cmd_status, "fsync-file": cmd_fsync_file,
}


def main(argv):
    try:
        fmt.seams()
        a = build_parser().parse_args(argv)
        if a.cmd is None:
            raise Done(USAGE, state="usage", detail="a subcommand is required")
        owner = Owner(a.home) if a.cmd != "fsync-file" else None
        if getattr(a, "id", None):
            check_id(a.id)
        COMMANDS[a.cmd](owner, a)
        raise Done(UNKNOWN, state="unknown", detail="subcommand returned no result")
    except fmt.SeamRefused as exc:
        d = Done(USAGE, state="usage", detail=str(exc))
    except fmt.FormatError as exc:
        d = Done(UNKNOWN, state="unknown", detail=str(exc))
    except Done as exc:
        d = exc
    fmt.emit(d.result)
    return d.code


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
