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

"""
import argparse
import fcntl
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time

sys.dont_write_bytecode = True
from fm_receipt_io import atomic, digest, load


def git(clone, *args):
    result = subprocess.run(["git", "-C", str(clone), *args], stdout=subprocess.PIPE,
                            stderr=subprocess.DEVNULL, text=True, check=False)
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


def run_child(script, clone):
    # clone is the caller's spelling, so the child's status label stays the project name.
    with tempfile.TemporaryDirectory(prefix="fm-sync-") as tmp:
        response = Path(tmp) / "result.json"
        child = subprocess.run([script, "--receipt-child", str(clone), str(response)], check=False)
        try:
            result = load(response)
        except (OSError, ValueError):
            result = {"outcome": "failed", "fetch_succeeded": False}
    if child.returncode != 0:
        result["outcome"] = "failed"
    return child.returncode, result


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
        return run_child(script, given)[0]
    with lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        if coalescible(target, home, clone, requested):
            print(f"{clone.name}: coalesced refresh; receipt: {target}")
            return 0
        started = time.time()
        before = observation(clone)
        code, result = run_child(script, given)
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
    return sync(args.script, args.home, args.clone, args.requested_at)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError, KeyError, TypeError) as error:
        print(f"fm-fleet-provenance: {error}", file=sys.stderr)
        sys.exit(1)
