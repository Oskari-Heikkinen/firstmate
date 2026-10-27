"""Bounded passive external observations for the view engine (Python 3.9+).

Internal API only, not an arbitrary-command IPC verb. Collectors supply a fixed
adapter argv. Child stdout/stderr, lifetime and process group are bounded; no
shell timeout/sleep/stat helpers are started. No backend lifecycle operation is
allowed here. Unsupported process-identity primitives require legacy fallback.
"""
from dataclasses import dataclass
import os
import selectors
import signal
import stat
import subprocess
import sys
import time

MAX_OUTPUT = 1024 * 1024


def _proc_bytes(name, directory_fd=None, limit=8192):
    """Read a fixed procfs observation, never an unbounded record or FIFO."""
    fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=directory_fd)
    try:
        before = os.fstat(fd)
        if not stat.S_ISREG(before.st_mode):
            raise ValueError("process identity input is not regular")
        raw = bytearray()
        while len(raw) <= limit:
            chunk = os.read(fd, min(4096, limit + 1 - len(raw)))
            if not chunk:
                break
            raw.extend(chunk)
        after = os.fstat(fd)
        signature = lambda s: (s.st_dev, s.st_ino, s.st_mode, s.st_uid)
        if len(raw) > limit or signature(before) != signature(after):
            raise ValueError("process identity input changed or exceeds bound")
        return bytes(raw)
    finally:
        os.close(fd)


@dataclass(frozen=True)
class ProcessGeneration:
    """Ephemeral kernel observation, not a service record or signal authority."""
    pid: int
    uid: int
    start_ticks: int
    boot: str

    def __post_init__(self):
        import re
        if (type(self.pid) is not int or self.pid <= 0 or type(self.uid) is not int or self.uid < 0
                or type(self.start_ticks) is not int or self.start_ticks <= 0
                or type(self.boot) is not str
                or not re.fullmatch(r"[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}", self.boot)):
            raise ValueError("invalid process generation")


def process_generation(pid):
    """Observe Linux PID/start-ticks/UID/boot without using a command line.

    The directory descriptor pins this procfs incarnation through the read.
    This alone is not a PID-reuse fence: ProcessPin opens a pidfd first, checks
    this generation and rejects an exit on either side of that observation.
    """
    if sys.platform != "linux":
        raise ValueError("process identity requires Linux; retain legacy")
    if type(pid) is not int or pid <= 0:
        raise ValueError("invalid process id")
    boot = _proc_bytes("/proc/sys/kernel/random/boot_id", limit=128).decode("ascii").rstrip("\n")
    folder = os.open("/proc/" + str(pid), os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        info = os.fstat(folder)
        raw = _proc_bytes("stat", folder)
        prefix, separator, fields = raw.rpartition(b") ")
        if (not separator or not raw.endswith(b"\n") or b"\0" in raw
                or not prefix.startswith(str(pid).encode() + b" (")):
            raise ValueError("invalid process stat identity")
        fields = fields.split()
        if len(fields) < 20 or not fields[19].isdigit():
            raise ValueError("invalid process start ticks")
        return ProcessGeneration(pid, info.st_uid, int(fields[19]), boot)
    finally:
        os.close(folder)


class ProcessPin:
    """Read-only, generation-verified pidfd and bounded actual-exit observation.

    No signal, stop, readiness, receipt or actor effect is provided. A future
    lifecycle owner must validate its home/code/socket/epoch and persist its
    receipt before any signal. Closing an engine/socket is not process exit;
    only this pinned descriptor's kernel exit readiness proves that fact.
    """
    def __init__(self, expected):
        self.fd = None
        if type(expected) is not ProcessGeneration or expected.uid != os.getuid():
            raise ValueError("process generation must belong to this UID")
        if not hasattr(os, "pidfd_open"):
            raise ValueError("pidfd unavailable; retain legacy")
        fd = os.pidfd_open(expected.pid, 0)
        try:
            self.fd = fd
            if process_generation(expected.pid) != expected or self.exited():
                raise ValueError("process generation changed or exited")
            self.generation = expected
        except BaseException:
            self.close()
            raise

    def fileno(self):
        if self.fd is None:
            raise ValueError("process pin is closed")
        return self.fd

    def exited(self):
        with selectors.DefaultSelector() as selector:
            selector.register(self.fileno(), selectors.EVENT_READ)
            return bool(selector.select(0))

    def wait_exit(self, timeout):
        if type(timeout) not in (int, float) or not 0 < timeout <= 30:
            raise ValueError("invalid process exit observation bound")
        deadline = time.monotonic() + timeout
        with selectors.DefaultSelector() as selector:
            selector.register(self.fileno(), selectors.EVENT_READ)
            # A signal/spurious wake cannot reset the original wall bound.
            while True:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise TimeoutError("pinned process has not exited")
                if selector.select(remaining):
                    return

    def close(self):
        if self.fd is not None:
            fd, self.fd = self.fd, None
            os.close(fd)

    def __enter__(self):
        self.fileno()
        return self

    def __exit__(self, *_):
        self.close()


@dataclass(frozen=True)
class Observation:
    argv: tuple
    status: int
    stdout: bytes
    stderr: bytes
    started_ns: int
    finished_ns: int
    problem: str = ""

    @property
    def text(self):
        # Command substitution removes NUL and trailing LF in the legacy reader.
        return self.stdout.replace(b"\0", b"").decode("utf-8", "surrogateescape").rstrip("\n")


def run(argv, cwd, timeout, env=None, max_output=MAX_OUTPUT):
    """Observe one directly-owned, unreaped child group, never an external PID.

    pidfd readability wakes completion without reaping the leader. Even if its
    descendants hold output pipes open, the leader's PID cannot be recycled
    before group cleanup. Popen.poll()/communicate() are deliberately not used:
    polling could reap the identity that licenses that cleanup.
    """
    if signal.getsignal(signal.SIGCHLD) != signal.SIG_DFL:
        raise ValueError("passive child ownership requires the default SIGCHLD disposition")
    if not hasattr(os, "pidfd_open") or not hasattr(os, "waitid") or not hasattr(os, "WNOWAIT"):
        raise ValueError("bounded passive adapter needs pidfd and nonreaping wait; use legacy")
    if not 0 < timeout <= 120 or not 1 <= max_output <= MAX_OUTPUT:
        raise ValueError("invalid passive observation bound")
    if not argv or any(not isinstance(value, str) or "\0" in value for value in argv):
        raise ValueError("invalid passive adapter argv")
    started = time.monotonic_ns()
    deadline = time.monotonic() + timeout
    try:
        process = subprocess.Popen(argv, cwd=cwd, env=env, stdin=subprocess.DEVNULL,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                   start_new_session=True, close_fds=True)
    except OSError as exc:
        return Observation(tuple(argv), 127, b"", str(exc).encode(), started, time.monotonic_ns(), "exec failed")
    output = {"stdout": bytearray(), "stderr": bytearray()}
    problem, status, terminal = "", 0, False
    selector = selectors.DefaultSelector()
    pidfd = None
    try:
        pidfd = os.pidfd_open(process.pid, 0)
        selector.register(pidfd, selectors.EVENT_READ, "process")
        for stream, name in ((process.stdout, "stdout"), (process.stderr, "stderr")):
            os.set_blocking(stream.fileno(), False)
            selector.register(stream, selectors.EVENT_READ, name)
        while selector.get_map():
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                problem, status = "passive observation deadline expired", 124
                break
            events = selector.select(remaining)
            for key, _ in events:
                if key.data == "process":
                    # Validate the pidfd event without releasing the PID identity.
                    event = os.waitid(os.P_PID, process.pid, os.WEXITED | os.WNOHANG | os.WNOWAIT)
                    if event is None:
                        continue
                    if event.si_pid != process.pid:
                        raise ValueError("passive child completion identity disagrees")
                    terminal = True
                    selector.unregister(pidfd)
                    # A successful parent is not permission to orphan a child
                    # that kept its stdout pipe open. Only our owned group dies.
                    try:
                        os.killpg(process.pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                    continue
                chunk = os.read(key.fileobj.fileno(), min(65536, max_output + 1 - len(output[key.data])))
                if not chunk:
                    selector.unregister(key.fileobj)
                    continue
                output[key.data].extend(chunk)
                if len(output[key.data]) > max_output:
                    problem, status = "passive observation output exceeds byte bound", 125
                    break
            if problem:
                break
        if not terminal and not problem:
            problem, status = "passive observation completion unverified", 125
    except (OSError, ValueError) as exc:
        problem, status = "passive observation failed: " + str(exc), 125
    finally:
        # The direct child has never been reaped, so its group identity is still
        # ours even after timeout, failed pidfd installation or an output cap.
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        selector.close()
        if pidfd is not None:
            os.close(pidfd)
        process.stdout.close()
        process.stderr.close()
        try:
            result = process.wait(timeout=2)
            if not problem:
                status = result if result >= 0 else 128 - result
        except subprocess.TimeoutExpired:
            # A process stuck in uninterruptible kernel I/O cannot be made
            # bounded by another Python wait. Refuse; never report healthy.
            problem, status = "owned passive child did not reap after SIGKILL", 125
    return Observation(tuple(argv), status, bytes(output["stdout"][:max_output]),
                       bytes(output["stderr"][:max_output]), started, time.monotonic_ns(), problem)
