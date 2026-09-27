#!/usr/bin/env python3
"""Fleet-sync receipt coordinator and read-only application provenance join.

Internal: sync SCRIPT HOME CLONE [REQUESTED_AT] serializes overlapping requests
per physical clone using an OS lock under HOME/data/fleet-sync. A request queued
behind a successful observation completed after its arrival (the caller's entry
time in Unix seconds, else this process's start) reuses that receipt, so
concurrent duplicate refresh requests do not fetch twice. Sequential requests
still fetch; a previous timestamp is not proof of a fresh remote. Failed or
skipped observations are not coalesced. Only fm-fleet-sync.sh owns Git mutation.
Receipts are atomically replaced per clone at data/fleet-sync/<sha256(path)>.json;
these are observations, not a second project registry. Interrupted writes leave
the prior dated receipt; interruption never becomes success. Lock files remain
as stable OS-lock anchors. No application commands, installs or reloads run.

Public: read RECEIPT [--application FILE] [--max-age SECONDS]
Outputs fm-application-provenance.v1 JSON for workbench consumers. Sync receipts
bind clone, requested/start/completed times, outcome, before/after source,
remote-tracking tip and whether fetch succeeded. A tracking tip after failed
fetch is explicitly NOT a current remote tip. Git dirty/ahead/diverged state is
reported, never repaired here. The sync script remains sole safety owner.

Optional fm-application-observations.v1 input: clone (physical absolute path),
stages object with optional build/server/browser members, each {revision,
observed_at, identity, evidence:{path,sha256}}. Evidence is home-local, exact
SHA-256 bound and supplied by the application owner, not inferred from Git or
PID presence. Stage revision is a full 40/64-digit hex commit. Missing, stale,
future, malformed or unbound stages stay unknown. Fresh mismatching stages
mean source-updated-app-not-updated; equal stages mean owner-reported-match,
not a new running-process proof. max-age defaults to 300 seconds and applies
to source and all stage observations. Never choose a newer prose as authority.
"""
import argparse
import fcntl
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import time

sys.dont_write_bytecode = True
from fm_receipt_io import atomic, digest, emit, freshness, load, reference, text


def git(clone, *args):
    result = subprocess.run(["git", "-C", str(clone), *args], stdout=subprocess.PIPE,
                            stderr=subprocess.DEVNULL, text=True, check=False)
    return result.stdout.strip() if result.returncode == 0 else None


def observation(clone):
    if git(clone, "rev-parse", "--show-toplevel") != str(clone):
        return {"source": None, "remote_tip": None, "branch": None, "dirty": None}
    branch = git(clone, "symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD")
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
            and old.get("fetch_succeeded") is True and old.get("completed_at", 0) >= requested
            and old.get("outcome") in ("current", "synced", "recovered")
            and old.get("after") == observation(clone))


def sync(script, home, clone, requested=None):
    try:
        # Bash EPOCHREALTIME follows the locale's decimal separator.
        requested = float(str(requested).replace(",", "."))
    except ValueError:
        requested = time.time()
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
        return run_child(script, clone)[0]
    with lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        if coalescible(target, home, clone, requested):
            print(f"{clone.name}: coalesced refresh; receipt: {target}")
            return 0
        started = time.time()
        before = observation(clone)
        code, result = run_child(script, clone)
        receipt = {"schema": "fm-fleet-sync.v1", "home": str(home), "clone": str(clone),
                   "requested_at": requested, "started_at": started, "completed_at": time.time(),
                   "before": before, "after": observation(clone), **result}
        receipt["id"] = digest(json.dumps(receipt, sort_keys=True).encode())
        try:
            atomic(target, receipt)
        except OSError as error:
            print(f"{clone.name}: warning: fleet-sync receipt not written ({error.strerror})", file=sys.stderr)
        return code


def readout(args):
    receipt = load(args.receipt)
    if receipt["schema"] != "fm-fleet-sync.v1":
        raise ValueError("unsupported sync receipt")
    home = Path(receipt["home"]).resolve()
    source_freshness = freshness(receipt["completed_at"], args.max_age)
    after = receipt["after"]
    source_current = (source_freshness["state"] == "fresh" and receipt["fetch_succeeded"] is True
                      and receipt["outcome"] in ("current", "synced", "recovered")
                      and after["dirty"] is False and bool(after["source"])
                      and after["source"] == after["remote_tip"])
    stages = {}
    app = load(args.application) if args.application else None
    if app and (app["schema"] != "fm-application-observations.v1" or app["clone"] != receipt["clone"]):
        raise ValueError("application clone/schema mismatch")
    for name in ("build", "server", "browser"):
        stage = {"state": "unknown", "reason": "no owner observation"}
        try:
            if app and name in app["stages"]:
                supplied = app["stages"][name]
                revision = text(supplied["revision"])
                if not re.fullmatch(r"[0-9a-f]{40}|[0-9a-f]{64}", revision):
                    raise ValueError("stage revision must be a full commit")
                reference(home, supplied["evidence"])
                fresh = freshness(supplied["observed_at"], args.max_age)
                stage = {"state": "observed" if fresh["state"] == "fresh" else "unknown",
                         "revision": revision, "identity": text(supplied["identity"]),
                         "freshness": fresh, "evidence": supplied["evidence"]}
        except (OSError, ValueError, KeyError, TypeError):
            stage = {"state": "unknown", "reason": "invalid or unavailable owner evidence"}
        stages[name] = stage
    known = [s for s in stages.values() if s["state"] == "observed"]
    state = "unknown"
    if source_current and any(s["revision"] != after["source"] for s in known):
        state = "source-updated-app-not-updated"
    elif source_current and len(known) == 3:
        state = "owner-reported-match"
    emit({"schema": "fm-application-provenance.v1", "authority": "observation-only",
          "clone": receipt["clone"], "sync_receipt": str(Path(args.receipt).resolve()),
          "sync_id": receipt["id"], "outcome": receipt["outcome"], "source": after,
          "source_freshness": source_freshness, "source_current": source_current,
          "stages": stages, "application_state": state})


def main():
    if len(sys.argv) > 1 and sys.argv[1] == "sync":
        return sync(*sys.argv[2:])
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("command", choices=["read"])
    parser.add_argument("receipt")
    parser.add_argument("--application")
    parser.add_argument("--max-age", type=float, default=300)
    args = parser.parse_args()
    if not 0 < args.max_age < 1e9:
        raise ValueError("max-age must be positive and finite")
    readout(args)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError, KeyError, TypeError) as error:
        print(f"fm-fleet-provenance: {error}", file=sys.stderr)
        sys.exit(1)
