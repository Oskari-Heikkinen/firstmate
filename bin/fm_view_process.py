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
import subprocess
import time

MAX_OUTPUT = 1024 * 1024


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
