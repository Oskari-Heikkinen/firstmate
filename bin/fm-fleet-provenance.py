#!/usr/bin/env python3
"""Fleet-sync receipt coordinator.

Internal: sync SCRIPT HOME CLONE [REQUESTED_AT] serializes overlapping requests
per physical clone using an OS lock under HOME/data/fleet-sync. A request queued
behind a successful observation that STARTED after its arrival (the caller's
entry time in Unix seconds, else this process's start) reuses that receipt, so
requests queued behind the same in-flight run share its successor's fetch. A
request arriving after a fetch began always fetches again, because a remote
change may have landed in between; a previous timestamp is not proof of a
fresh remote. Failed or
skipped observations are not coalesced. Only fm-fleet-sync.sh owns Git mutation.
Receipts are atomically replaced per clone at data/fleet-sync/<sha256(path)>.json;
these are observations, not a second project registry. Interrupted writes leave
the prior dated receipt; interruption never becomes success. Lock files remain
as stable OS-lock anchors. No application commands, installs or reloads run.

Every wait is bounded, so a refresh that hangs cannot hold every later request
for the clone, or the caller waiting on it, open-ended. The refresh child runs
in its own session for at most FM_FLEET_SYNC_CHILD_TIMEOUT seconds (default six
fetch bounds plus 180, from FM_FLEET_SYNC_FETCH_TIMEOUT, default 120); at the
bound its group and, on Linux, every process still in its session (a bounded
fetch runs in a process group of its own) get TERM, then KILL after a short
grace, the run prints
"<clone>: skipped: refresh timed out after <n>s", records a failed receipt and
exits 124. A request waits for the clone's lock for at most
FM_FLEET_SYNC_LOCK_WAIT seconds (default the child bound plus 60); past that it
prints "<clone>: skipped: refresh lock wait timed out after <n>s", writes no
receipt and exits 124. Each local git read is bounded by
FM_FLEET_SYNC_GIT_TIMEOUT seconds (default 60) and reads as unknown when the
bound fires, which never coalesces. Because the child has its own session, a
TERM, INT or HUP sent to this process (such as bootstrap's group TERM at its
refresh bound) is forwarded to the child the same way before this
process exits 128 plus the signal number.

"""
import argparse
import fcntl
import json
import os
from pathlib import Path
import subprocess
import sys
import signal
import tempfile
import time

sys.dont_write_bytecode = True
from fm_receipt_io import atomic, digest, load


def seconds(name, default, report=True):
    value = os.environ.get(name, "")
    # A leading zero is refused, as fm-fleet-sync.sh refuses it for the fetch bound.
    if value.isdigit() and not value.startswith("0"):
        return int(value)
    if value and report:
        print(f"fm-fleet-provenance: invalid {name} '{value}'; using {default}s", file=sys.stderr)
    return default


# fm-fleet-sync.sh owns the fetch bound and already reports an invalid value.
FETCH_TIMEOUT = seconds("FM_FLEET_SYNC_FETCH_TIMEOUT", 120, report=False)
CHILD_TIMEOUT = seconds("FM_FLEET_SYNC_CHILD_TIMEOUT", 6 * FETCH_TIMEOUT + 180)
LOCK_WAIT = seconds("FM_FLEET_SYNC_LOCK_WAIT", CHILD_TIMEOUT + 60)
GIT_TIMEOUT = seconds("FM_FLEET_SYNC_GIT_TIMEOUT", 60)
KILL_GRACE = 5
TIMED_OUT = 124


def git(clone, *args):
    try:
        result = subprocess.run(["git", "-C", str(clone), *args], stdout=subprocess.PIPE,
                                stderr=subprocess.DEVNULL, text=True, check=False,
                                timeout=GIT_TIMEOUT)
    except subprocess.TimeoutExpired:
        return None
    return result.stdout.strip() if result.returncode == 0 else None


def observation(clone, base=None):
    if git(clone, "rev-parse", "--show-toplevel") != str(clone):
        return {"source": None, "remote_tip": None, "branch": None, "dirty": None}
    branch = base or git(clone, "symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD")
    if branch is None:
        for candidate in ("main", "master"):
            if git(clone, "rev-parse", "--verify", f"refs/heads/{candidate}"):
                branch = f"origin/{candidate}"
                break
    status = git(clone, "status", "--porcelain")
    return {"source": git(clone, "rev-parse", "--verify", "HEAD"),
            "remote_tip": git(clone, "rev-parse", "--verify", branch) if branch else None,
            "branch": git(clone, "symbolic-ref", "--quiet", "--short", "HEAD"),
            "dirty": bool(status) if status is not None else None}


class Stopped(Exception):
    def __init__(self, signum):
        super().__init__(signum)
        self.signum = signum


def on_signal(signum, _frame):
    # One stop per run: a repeated signal must not abandon the child mid-stop.
    signal.signal(signum, signal.SIG_IGN)
    raise Stopped(signum)


def session_members(sid):
    """Linux: live processes still in session sid, whatever group they moved to."""
    members = []
    try:
        entries = os.listdir("/proc")
    except OSError:
        return members
    for entry in entries:
        if not entry.isdigit() or int(entry) == os.getpid():
            continue
        try:
            with open(f"/proc/{entry}/stat") as handle:
                fields = handle.read().rsplit(")", 1)[1].split()
        except (OSError, IndexError):
            continue
        if len(fields) > 3 and fields[3] == str(sid):
            members.append(int(entry))
    return members


def signal_session(child, signum):
    # A bounded command (fm_run_timed's GNU timeout) runs in a process group of
    # its own, which the child's group signal misses but the session still holds.
    try:
        os.killpg(child.pid, signum)
    except OSError:
        pass
    for pid in session_members(child.pid):
        try:
            os.kill(pid, signum)
        except OSError:
            pass


def stop_group(child):
    """TERM the child's session, then KILL whatever outlived the grace."""
    signal_session(child, signal.SIGTERM)
    try:
        child.wait(timeout=KILL_GRACE)
    except subprocess.TimeoutExpired:
        pass
    signal_session(child, signal.SIGKILL)
    child.wait()


def run_child(script, clone, label):
    # clone is the caller's spelling, so the child's status label stays the project name.
    with tempfile.TemporaryDirectory(prefix="fm-sync-") as tmp:
        response = Path(tmp) / "result.json"
        child = subprocess.Popen([script, "--receipt-child", str(clone), str(response)],
                                 start_new_session=True)
        try:
            code = child.wait(timeout=CHILD_TIMEOUT)
        except subprocess.TimeoutExpired:
            stop_group(child)
            print(f"{label}: skipped: refresh timed out after {CHILD_TIMEOUT}s", flush=True)
            return TIMED_OUT, {"outcome": "failed", "fetch_succeeded": False}
        except BaseException:
            stop_group(child)
            raise
        try:
            result = load(response)
        except (OSError, ValueError):
            result = {"outcome": "failed", "fetch_succeeded": False}
    if code != 0:
        result["outcome"] = "failed"
    return code, result


def lock_within(lock, deadline):
    """Take the exclusive lock, or return False once the deadline has passed."""
    pause = 0.05
    while True:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            return True
        except BlockingIOError:
            left = deadline - time.monotonic()
            if left <= 0:
                return False
            time.sleep(min(pause, left))
            pause = min(pause * 2, 1.0)


def coalescible(target, home, clone, requested):
    try:
        old = load(target)
    except (OSError, ValueError):
        return False
    return (isinstance(old, dict) and old.get("schema") == "fm-fleet-sync.v1"
            and old.get("home") == str(home) and old.get("clone") == str(clone)
            and old.get("fetch_succeeded") is True and old.get("started_at", 0) >= requested
            and old.get("outcome") in ("current", "synced", "recovered")
            and old.get("after") == observation(clone, old.get("base")))


def sync(script, home, clone, requested=None):
    try:
        # Bash EPOCHREALTIME follows the locale's decimal separator.
        requested = float(str(requested).replace(",", "."))
    except ValueError:
        requested = time.time()
    given = clone
    home, clone = Path(home).resolve(), Path(clone).resolve()
    directory = home / "data" / "fleet-sync"
    key = digest(str(clone).encode())
    target = directory / f"{key}.json"
    try:
        directory.mkdir(parents=True, exist_ok=True)
        lock = (directory / f"{key}.lock").open("a")
    except OSError as error:
        # A missing receipt must never cost the refresh itself.
        print(f"{clone.name}: warning: fleet-sync receipt unavailable ({error.strerror})", file=sys.stderr)
        return run_child(script, given, clone.name)[0]
    with lock:
        if not lock_within(lock, time.monotonic() + LOCK_WAIT):
            print(f"{clone.name}: skipped: refresh lock wait timed out after {LOCK_WAIT}s "
                  f"(another refresh of this clone still holds {directory / (key + '.lock')})", flush=True)
            return TIMED_OUT
        if coalescible(target, home, clone, requested):
            print(f"{clone.name}: coalesced refresh; receipt: {target}")
            return 0
        started = time.time()
        before = observation(clone)
        code, result = run_child(script, given, clone.name)
        receipt = {"schema": "fm-fleet-sync.v1", "home": str(home), "clone": str(clone),
                   "requested_at": requested, "started_at": started, "completed_at": time.time(),
                   "before": before, "after": observation(clone, result.get("base")), **result}
        receipt["id"] = digest(json.dumps(receipt, sort_keys=True).encode())
        try:
            atomic(target, receipt)
        except OSError as error:
            print(f"{clone.name}: warning: fleet-sync receipt not written ({error.strerror})", file=sys.stderr)
        return code


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("command", choices=["sync"])
    parser.add_argument("script")
    parser.add_argument("home")
    parser.add_argument("clone")
    parser.add_argument("requested_at", nargs="?")
    args = parser.parse_args()
    for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
        signal.signal(sig, on_signal)
    return sync(args.script, args.home, args.clone, args.requested_at)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Stopped as stop:
        sys.exit(128 + stop.signum)
    except (OSError, ValueError, KeyError, TypeError) as error:
        print(f"fm-fleet-provenance: {error}", file=sys.stderr)
        sys.exit(1)
