"""Compact logical-operation projection of tjr.py's normalized open_holds relation.

Read-only pure mapping of tj-receipt-events/v1, not native ingestion/deduplication.
The adapter wrapper owns bounded file reads, freshness, receipts and routing.
The contract and limits live in docs/handoff-coverage.md (Native observation adapters).
"""
import datetime
import hashlib
import json
import re

EVENT_LIMIT = 65536
OPERATION_LIMIT = 4096
TEXT_LIMIT = 4096
KINDS = {"launched", "fetched", "closed", "removed", "held", "waiting", "step", "checked",
         "archive-deleted", "closeout-recorded"}
CLOSES = {"launch": ("launched", "fetched", "closed"), "relaunch": ("launched", "fetched", "closed"),
          "fetch": ("fetched", "closed"), "remove": ("removed",)}
ALIAS_RE = re.compile(r"(?:^|-)(b\d+)(?:-|$)")


def text(value, label, limit=256):
    if not isinstance(value, str) or not value or len(value) > limit:
        raise ValueError(f"invalid native event {label}")
    return value


def timestamp(value):
    if not isinstance(value, str) or not re.fullmatch(r"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ", value):
        raise ValueError("native events require normalized whole-second UTC timestamps")
    try:
        datetime.datetime.fromisoformat(value[:-1] + "+00:00")
    except ValueError as exc:
        raise ValueError("invalid native event timestamp") from exc
    return value


def identity(hold):
    return hashlib.sha256(json.dumps([hold["subject"], hold["phase"] or "other"], ensure_ascii=True).encode()).hexdigest()


def compact(event):
    if not isinstance(event, dict) or event.get("kind") not in KINDS:
        raise ValueError("unknown native event kind")
    subject = text(event.get("subject"), "subject")
    phase = event.get("phase")
    if phase not in (None, ""):
        text(phase, "phase")
    found = ALIAS_RE.search(subject)
    alias = found.group(1) if found else None
    if event.get("alias") != alias:
        raise ValueError("native event alias disagrees with native alias_of(subject)")
    facts = event.get("facts")
    if not isinstance(facts, dict):
        raise ValueError("invalid native event facts")
    reason = facts.get("reason") or facts.get("result") or ""
    if not isinstance(reason, str) or len(reason) > TEXT_LIMIT:
        raise ValueError("native event reason exceeds observation text bound or is not a string")
    return {"id": text(event.get("id"), "id"), "kind": event["kind"], "at": timestamp(event.get("at")),
            "subject": subject, "phase": phase, "alias": alias,
            "source": text(event.get("source"), "source"),
            "receipt": text(event.get("receipt"), "receipt", TEXT_LIMIT), "reason": reason}


def closing_event(hold, latest_ok, alias_launch):
    """Exact S:585-616 closure relation, including the older-fetch relaunch exception."""
    phase, subject = hold["phase"] or "other", hold["subject"]
    candidates = [latest_ok[(subject, kind)] for kind in CLOSES.get(phase, ()) if (subject, kind) in latest_ok]
    if phase == "launch" and hold["alias"] in alias_launch:
        candidates.append(alias_launch[hold["alias"]])
    candidates = [e for e in candidates if e["at"] >= hold["at"]
                  or (phase == "relaunch" and e["kind"] in ("fetched", "closed"))]
    return max(candidates, key=lambda e: (e["at"], e["id"])) if candidates else None


def project(doc, previous):
    """Return compact projection + pruning problems; invalid/incomplete snapshots raise.

    Previous operations are retained only to avoid resolving by disappearance or
    resurrecting already-closed older history. They never supply closure for a
    genuinely later hold that the current native event set does not resolve.
    """
    if doc.get("schema") != "tj-receipt-events/v1":
        raise ValueError(f"unknown native events version {doc.get('schema')!r}")
    scanned = timestamp(doc.get("scanned_at"))
    if previous and scanned < previous["scanned_at"]:
        raise ValueError("native scan timestamp regressed")
    inputs = doc.get("inputs")
    if not isinstance(inputs, dict) or any(type(v) is not int or v < 0 for v in inputs.values()):
        raise ValueError("invalid native snapshot input counts")
    if doc.get("problems") != []:
        raise ValueError("native snapshot contains source problems or lacks an empty problems array")
    events = doc.get("events")
    if not isinstance(events, list) or len(events) > EVENT_LIMIT:
        raise ValueError(f"native snapshot needs an events array of at most {EVENT_LIMIT} events")
    holds, latest_ok, alias_launch, seen = {}, {}, {}, set()
    held_ids = set()
    for raw in events:
        event = compact(raw)
        if event["id"] in seen:
            raise ValueError("duplicate native event id")
        seen.add(event["id"])
        kind = event["kind"]
        if kind in ("launched", "fetched", "closed", "removed"):
            key = (event["subject"], kind)
            if key not in latest_ok or event["at"] >= latest_ok[key]["at"]:
                latest_ok[key] = event
            alias = event["alias"]
            if kind == "launched" and alias and (alias not in alias_launch or event["at"] >= alias_launch[alias]["at"]):
                alias_launch[alias] = event
        elif kind == "held":
            held_ids.add(event["id"])
            key = identity(event)
            if key not in holds or event["at"] >= holds[key]["at"]:
                holds[key] = event
        # waiting/step/check/archive events are not held and do not close holds.
    old_operations = previous["operations"] if previous else {}
    operations, problems = {}, []
    for key in sorted(set(holds) | set(old_operations)):
        hold, old = holds.get(key), old_operations.get(key)
        if old:
            if old["closed_by"] and (hold is None or hold["at"] <= old["hold"]["at"]):
                if hold is not None:
                    operations[key] = old  # never resurrect known-closed retained history
                continue  # pruned terminal history leaves no obligation
            if hold is None or hold["at"] < old["hold"]["at"]:
                hold = old["hold"]
        closed = closing_event(hold, latest_ok, alias_launch)
        operations[key] = {"hold": hold, "closed_by": closed, "done_at": scanned if closed else None}
        if not closed and hold["id"] not in held_ids:
            problems.append(f"unresolved native hold {hold['id']} disappeared before explicit closure ({key})")
    if len(operations) > OPERATION_LIMIT:
        raise ValueError(f"native logical-operation retention exceeds {OPERATION_LIMIT} operations")
    return {"scanned_at": scanned, "operations": operations}, problems
