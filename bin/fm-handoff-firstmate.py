#!/usr/bin/env python3
"""fm-handoff-firstmate.py - publish the fragment of Firstmate's own handoffs.

Usage:
  fm-handoff-firstmate.py fragment --home DIR [--root DIR]
  fm-handoff-firstmate.py publish  --home DIR [--root DIR]

docs/handoff-coverage.md ("Firstmate's own handoffs") owns what the fragment
declares and what each receipt adapter reads; bin/fm_handoff_adapters.py owns
how the watcher reads those records. This file only builds the fragment for one
home from that home's id and the local secondmates in its data/secondmates.md.

fragment  prints the fragment this home would publish (revision 1, now), so an
          owner can read it before adopting.
publish   writes it to DIR/state/handoff-registry/firstmate.json: validated,
          then renamed over the old file, with revision raised by one. Prints
          "published <path> revision <n>", or "unchanged <path> revision <n>"
          and writes nothing when the protocols are the same.

Every home gets protocol fm-brief.<home>; a home with local secondmates also
gets fm-corr.<home> and fm-status.<home>, with one stage per secondmate.
Tooling-mate's fragment also declares protocol handoff-watch, one stage per
home it sees, whose outbox is that home's heartbeat folder. --root DIR is the
drill root fm-handoff-watch uses: every folder under it named like a home id is
a home. Rerun publish after a secondmate is added or retired.

Exit: 0 printed or published; 1 the fragment would be invalid or could not be
written; 2 usage.
"""
import argparse
import datetime
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


def problems(doc):
    validate = registry.validator()
    found = validate.Schema(str(SCHEMA)).errors(doc) or validate.fragment_problems(doc)
    return [f"{where}: {what}" for where, what in found]


def main(argv):
    parser = argparse.ArgumentParser(prog="fm-handoff-firstmate.py")
    parser.add_argument("command", choices=("fragment", "publish"))
    parser.add_argument("--home", required=True)
    parser.add_argument("--root")
    args = parser.parse_args(argv)
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
