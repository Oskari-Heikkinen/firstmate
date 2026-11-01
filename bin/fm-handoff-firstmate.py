#!/usr/bin/env python3
"""fm-handoff-firstmate.py - publish the fragment of Firstmate's own handoffs.

Usage:
  fm-handoff-firstmate.py fragment --home DIR [--root DIR]
  fm-handoff-firstmate.py publish  --home DIR [--root DIR]
  fm-handoff-firstmate.py watch-target --home DIR [--root DIR]

docs/handoff-coverage.md ("Firstmate's own handoffs") owns what the fragment
declares and what each receipt adapter reads; bin/fm_handoff_adapters.py owns
how the watcher reads those records. This file only builds the fragment for one
home from that home's id and the local secondmates in its data/secondmates.md.

fragment  prints the fragment this home would publish (revision 1, now), so an
          owner can read it before adopting.
watch-target  prints two lines, the folder this home's merge-queue watch
          receipts go in and the key that ends their names, exactly as the
          fragment declares them; bin/fm-procevent-merge-queue.sh reads them
          here, so the writer and the declaration cannot disagree. Exit 1 when
          the home names no queue dir, with a warning when the one it names or
          its home id is unusable.
publish   writes it to DIR/state/handoff-registry/firstmate.json: validated,
          then renamed over the old file, with revision raised by one. Prints
          "published <path> revision <n>", or "unchanged <path> revision <n>"
          and writes nothing when the protocols are the same.

Every home gets protocol fm-brief.<home>; a home with local secondmates also
gets fm-corr.<home> and fm-status.<home>, with one stage per secondmate. A home
whose merge queue (FM_MERGE_QUEUE_DIR, else dir= in config/merge-queue) is
named also gets fm-mq-watch.<home>, the watch receipts that
bin/fm-procevent-merge-queue.sh arm writes there under this home's key (its id
and a digest of its physical path), read by the train home that the queue's
owner.json names; a queue dir that is not absolute or holds a control
character, an unreadable config, or an owner that cannot be read is skipped
with a warning on stderr.
Tooling-mate's fragment also declares protocol handoff-watch, one stage per
home it sees, whose outbox is that home's heartbeat folder. --root DIR is the
drill root fm-handoff-watch uses: every folder under it named like a home id is
a home. Rerun publish after a secondmate is added or retired, and after
config/merge-queue or the queue's owner.json changes.

Exit: 0 printed or published; 1 the fragment would be invalid or could not be
written, or watch-target has no folder or key to print; 2 usage.
"""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import fm_handoff_adapters as adapters  # noqa: E402
import fm_handoff_registry as registry  # noqa: E402
from fm_receipt_io import atomic  # noqa: E402

HERE = Path(__file__).resolve().parent
SCHEMA = HERE.parent / "docs/handoff-coverage/handoff-registry-v1.schema.json"
PUBLISHER = "bin/fm-handoff-firstmate.py"
FILE_NAME = "firstmate.json"
TOOLING = "tooling-mate"
WATCH_PROTOCOL = "handoff-watch"
LOCAL = {"kind": "local"}
MQ_WATCH_RECORD = "lattice.merge-queue.watch.v1"


def local_mates(home):
    """Secondmate ids data/secondmates.md lists without a host, in file order."""
    try:
        lines = (Path(home) / "data/secondmates.md").read_text(encoding="utf-8").splitlines()
    except (OSError, UnicodeDecodeError):
        return []
    out = []
    for line in lines:
        match = registry.SECONDMATE_HOME_RE.match(line)
        if match and "(host:" not in line and match.group(1) not in out:
            out.append(match.group(1))
    return out


def queue_dir(home):
    """The merge-queue dir this home names, or None (with a warning on stderr when one is named but unusable).

    The one reader of the dir for watch receipts: bin/fm-procevent-merge-queue.sh asks watch-target rather
    than parsing it again. FM_MERGE_QUEUE_DIR, else the last dir= line of config/merge-queue, a leading ~/
    being the user's home; only an absolute path with no control character is used."""
    config = Path(home) / "config/merge-queue"
    qdir = os.environ.get("FM_MERGE_QUEUE_DIR", "")
    where = "FM_MERGE_QUEUE_DIR"
    if not qdir:
        if config.is_symlink() or not config.is_file():
            return None
        try:
            # Bytes split on newlines only, as sed reads them, so a carriage return stays in the value and is
            # refused below.
            lines = config.read_bytes().decode("utf-8").split("\n")
        except (OSError, UnicodeDecodeError) as exc:
            print(f"fm-handoff-firstmate: skipping the merge-queue watch receipts: {config} is unreadable ({exc})",
                  file=sys.stderr)
            return None
        dirs = [line[len("dir="):] for line in lines if line.startswith("dir=")]
        qdir = dirs[-1] if dirs else ""
        where = f"dir= in {config}"
    if qdir.startswith("~/"):
        qdir = os.path.join(os.path.expanduser("~"), qdir[2:])
    if not qdir:
        return None
    if not os.path.isabs(qdir) or any(ord(c) < 32 or ord(c) == 127 for c in qdir):
        print(f"fm-handoff-firstmate: skipping the merge-queue watch receipts: {where} ({qdir!r}) is not an "
              "absolute path without control characters", file=sys.stderr)
        return None
    return os.path.normpath(qdir)


def watch_key(hid, home):
    """The key naming this home's watch receipts: its id plus a digest of its physical path.

    The queue folder is shared by every home that hands heads to it, across fleets, so an id alone (every
    unmarked home is main) would let two homes overwrite and delete each other's receipts."""
    digest = hashlib.sha256(os.fsencode(os.path.realpath(home))).hexdigest()[:16]
    return f"{hid}-{digest}"


def train_owner(qdir):
    """The train owner home named by <qdir>/owner.json, or None with a warning on stderr."""
    owner_file = Path(qdir) / "owner.json"
    owner = None
    try:
        # A FIFO or device in its place would block the read, so only a regular file is read.
        if owner_file.is_file():
            owner = json.loads(owner_file.read_text(encoding="utf-8"))["owner"]["home"]
    except (OSError, UnicodeDecodeError, ValueError, KeyError, TypeError) as exc:
        owner = exc
    if not isinstance(owner, str) or not registry.HOME_ID_RE.match(owner):
        print(f"fm-handoff-firstmate: skipping the merge-queue watch receipts: {owner_file} names no train owner "
              "home", file=sys.stderr)
        return None
    return owner


def stage(name, owner, src, src_match, outbox, bounds, retry_limit, codes, adapter):
    return {"name": name, "owner": owner, "accepts": {"min": 1, "max": 1},
            "input": {"path": str(src), "reach": LOCAL, "match": src_match},
            "outbox": {"path": str(outbox), "reach": LOCAL},
            "bounds": dict(zip(("accepted", "waiting", "held"), bounds)), "retry_limit": retry_limit,
            "codes": codes, "cleanup": {"action": "keep"}, "ext": {f"{owner}.{adapters.ADAPTER_KEY}": adapter}}


def protocol(pid, owner, title, schema, record_type, senders, stages, receipts_after):
    return {"id": pid, "owner": owner, "title": title, "schema": schema, "record_types": [record_type],
            "versions": {"min": 1, "max": 1}, "senders": senders, "first_stage": stages[0]["name"],
            "stages": stages, "cleanup": {"stage": stages[0]["name"], "receipts_after": receipts_after,
                                          "records_after": "7d"}}


def code(fix_owner, what):
    return {"fix_owner": fix_owner, "holds_all": False, "what": what}


def protocols(hid, home, homes):
    state = Path(home) / "state"
    mates = local_mates(home)
    out = [protocol(f"fm-brief.{hid}", hid, f"Worker briefs from {hid}: each launched task until its first status line",
                    "firstmate:bin/fm-spawn.sh", "fm-task-meta", [hid],
                    [stage("launch", hid, state, "*.meta", state, ("2h", "1h", "1h"), 0, {}, "first-status")], "1d")]
    if mates:
        out.append(protocol(
            f"fm-corr.{hid}", hid, f"Marked fm-send requests from {hid} to its secondmates, until the correlated reply",
            "firstmate:bin/fm-pending-reply-lib.sh", "fm-pending-reply.v1", [hid],
            [stage(f"reply.{m}", hid, state / f"{m}.inbox", "*.msg", state / "pending-replies", ("24h", "1h", "4h"), 1, {
                "unacked": code(m, f"{m} has not moved the request to handled/ through the whole inbox re-ring ladder"),
                "reply-missed": code(m, f"{m} sent no correlated reply, even after REPOST REQUIRED"),
                "delivery-unknown": code(hid, f"{hid} cannot tell whether the request reached {m}; it may resend "
                                         "under the same correlation"),
            }, "corr-request") for m in mates], "1d"))
        out.append(protocol(
            f"fm-status.{hid}", hid, f"Keyed status lines {hid}'s secondmates post to it, until resolved",
            "firstmate:bin/fm-classify-lib.sh", "fm-status-log", mates,
            [stage(f"status.{m}", hid, state, f"{m}.status", state, ("7d", "1h", "1h"), 0, {}, "status-decisions")
             for m in mates], "1d"))
    qdir = queue_dir(home)
    train = train_owner(qdir) if qdir else None
    if train:
        key = watch_key(hid, home)
        out.append(protocol(
            f"fm-mq-watch.{hid}", hid, f"Merge-queue watch receipts {hid} writes for the merge train",
            "firstmate:docs/handoff-coverage.md", MQ_WATCH_RECORD, [hid],
            [{"name": "train", "owner": train, "accepts": {"min": 1, "max": 1},
              "input": {"path": f"{qdir}/watches", "reach": LOCAL, "match": f"*.{key}.json",
                        "type_field": "schema"},
              "outbox": {"path": f"{qdir}/watch-receipts/{key}", "reach": LOCAL},
              "bounds": {"accepted": "7d", "waiting": "1h", "held": "1h"}, "retry_limit": 0, "codes": {},
              "cleanup": {"action": "keep"}, "planned": True}], "7d"))
    if hid == TOOLING:
        out.append({
            "id": WATCH_PROTOCOL, "owner": TOOLING, "title": "Each home's handoff watcher heartbeat",
            "schema": "firstmate:docs/handoff-coverage.md", "record_types": ["handoff-receipt/v1"],
            "versions": {"min": 0, "max": 0}, "senders": [TOOLING], "first_stage": sorted(homes)[0],
            "stages": [{"name": h, "owner": h, "accepts": {"min": 0, "max": 0},
                        "input": {"path": str(Path(p) / "state/handoff-registry"), "reach": LOCAL},
                        "outbox": {"path": str(Path(p) / "state/handoff-watch/heartbeat"), "reach": LOCAL},
                        "bounds": {"accepted": "10m", "waiting": "10m", "held": "10m"}, "retry_limit": 0,
                        "codes": {}, "cleanup": {"action": "keep"}, "actors": ["fm-check:handoff-watch"]}
                       for h, p in sorted(homes.items())],
            "cleanup": {"stage": sorted(homes)[0], "receipts_after": "1d", "records_after": "1d"}})
    return out


def utc_now():
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def build(home, root, revision=1):
    hid, homes = registry.discover(home, root)
    return {"format": "handoff-registry/v1", "home": hid, "publisher": PUBLISHER, "revision": revision,
            "published_at": utc_now(), "protocols": protocols(hid, homes[hid], homes)}


def watch_target(home, root):
    try:
        hid, homes = registry.discover(home, root)
    except (ValueError, OSError) as exc:
        print(f"fm-handoff-firstmate: no watch receipts: {exc}", file=sys.stderr)
        return 1
    qdir = queue_dir(homes[hid])
    if not qdir:
        return 1
    print(f"{qdir}/watches")
    print(watch_key(hid, homes[hid]))
    return 0


def problems(doc):
    validate = registry.validator()
    found = validate.Schema(str(SCHEMA)).errors(doc) or validate.fragment_problems(doc)
    return [f"{where}: {what}" for where, what in found]


def main(argv):
    parser = argparse.ArgumentParser(prog="fm-handoff-firstmate.py")
    parser.add_argument("command", choices=("fragment", "publish", "watch-target"))
    parser.add_argument("--home", required=True)
    parser.add_argument("--root")
    args = parser.parse_args(argv)
    if args.command == "watch-target":
        return watch_target(args.home, args.root)
    try:
        doc = build(args.home, args.root)
    except (ValueError, OSError) as exc:
        print(f"fm-handoff-firstmate: {exc}", file=sys.stderr)
        return 1
    bad = problems(doc)
    if bad:
        print(f"fm-handoff-firstmate: the fragment would be invalid at {bad[0]}", file=sys.stderr)
        return 1
    if args.command == "fragment":
        print(json.dumps(doc, indent=2, sort_keys=True))
        return 0
    path = Path(args.home).resolve() / "state/handoff-registry" / FILE_NAME
    try:
        old = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        old = None
    except (OSError, ValueError) as exc:
        old = {}
        print(f"fm-handoff-firstmate: replacing unreadable {path} ({exc})", file=sys.stderr)
    if isinstance(old, dict) and old.get("protocols") == doc["protocols"] and old.get("home") == doc["home"]:
        print(f"unchanged {path} revision {old.get('revision')}")
        return 0
    last = old.get("revision") if isinstance(old, dict) else None
    doc["revision"] = last + 1 if isinstance(last, int) and last >= 1 else 1
    try:
        atomic(path, doc)
    except OSError as exc:
        print(f"fm-handoff-firstmate: cannot write {path} ({exc.strerror})", file=sys.stderr)
        return 1
    print(f"published {path} revision {doc['revision']}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
