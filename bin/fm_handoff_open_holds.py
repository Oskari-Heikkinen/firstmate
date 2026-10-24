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
WITNESS_LIMIT = 65536
CACHE_BYTES = 16 * 1024 * 1024
KINDS = {"launched", "fetched", "closed", "removed", "held", "waiting", "step", "checked",
         "archive-deleted", "closeout-recorded", "escalated"}
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
    closed_at = facts.get("closed_at")
    closed_by = None
    if closed_at:
        closed_at = timestamp(closed_at)
        if closed_at < timestamp(event.get("at")):
            raise ValueError("native closed_at precedes its held event")
        closed_by = text(facts.get("closed_by"), "closed_by", TEXT_LIMIT)
        if event["kind"] != "held":
            raise ValueError("native closed_at annotation is not attached to a held event")
    else:
        closed_at = None
    class_key = None
    if event.get("source") == "runner-class-receipt" and event["kind"] in ("launched", "fetched", "closed", "removed"):
        class_key = f"{text(facts.get('class'), 'class')}:{text(facts.get('root_kind'), 'root_kind')}:{subject}"
    return {"id": text(event.get("id"), "id"), "kind": event["kind"], "at": timestamp(event.get("at")),
            "subject": subject, "phase": phase, "alias": alias,
            "source": text(event.get("source"), "source"),
            "receipt": text(event.get("receipt"), "receipt", TEXT_LIMIT), "reason": reason,
            "closed_at": closed_at, "closed_by": closed_by, "class_key": class_key}


def closing_event(hold, latest_ok, alias_launch):
    """Current P:719-756, including native stop-cleared and runner-class witnesses."""
    if hold.get("closed_at"):
        return {"id": hold["id"], "kind": "held.closed_at", "at": hold["closed_at"],
                "subject": hold["subject"], "receipt": hold["receipt"], "reason": hold["closed_by"]}
    phase, subject = hold["phase"] or "other", hold["subject"]
    candidates = [latest_ok[(subject, kind)] for kind in CLOSES.get(phase, ()) if (subject, kind) in latest_ok]
    if phase == "launch" and hold["alias"] in alias_launch:
        candidates.append(alias_launch[hold["alias"]])
    candidates = [e for e in candidates if e["at"] >= hold["at"]
                  or (phase == "relaunch" and e["kind"] in ("fetched", "closed"))]
    return max(candidates, key=lambda e: (e["at"], e["id"])) if candidates else None


def remembered_closure(hold, knowledge):
    """An individual stop-cleared proves its event only; family proof covers older history."""
    exact = knowledge["ids"].get(hold["id"])
    if exact:
        return exact["closed_by"]
    family = knowledge["family"]
    if family and hold["at"] <= family["hold"]["at"]:
        return family["closed_by"]
    return None


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
    held_events, latest_ok, alias_launch, seen = [], {}, {}, set()
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
            if event["class_key"]:
                class_key = (event["class_key"], "removed")
                if class_key not in latest_ok or event["at"] >= latest_ok[class_key]["at"]:
                    latest_ok[class_key] = dict(event, via=event["class_key"])
            alias = event["alias"]
            if kind == "launched" and alias and (alias not in alias_launch or event["at"] >= alias_launch[alias]["at"]):
                alias_launch[alias] = event
        elif kind == "held":
            held_events.append(event)
        # waiting/step/checked/escalated/archive events neither hold nor close.
    # Filter BEFORE latest selection: a newer individually closed runner stop
    # does not hide an older unresolved hold of the same subject/phase.
    old_operations = previous["operations"] if previous else {}
    knowledge_by_key = {}
    for key, old in old_operations.items():
        resolved = dict(old.get("resolved", {}))
        if old["closed_by"]:
            resolved.setdefault(old["hold"]["id"], {"hold": old["hold"], "closed_by": old["closed_by"]})
        families = [r for r in resolved.values() if r["closed_by"]["kind"] != "held.closed_at"]
        knowledge_by_key[key] = {"ids": resolved, "family": max(families, key=lambda r: r["hold"]["at"]) if families else None}
    holds, closed_holds = {}, {}
    current_by_id = {e["id"]: e for e in held_events}
    for hold in held_events:
        key = identity(hold)
        closed = closing_event(hold, latest_ok, alias_launch)
        if not closed and key in knowledge_by_key:
            closed = remembered_closure(hold, knowledge_by_key[key])
        if closed:
            if key not in closed_holds or hold["at"] >= closed_holds[key]["hold"]["at"]:
                closed_holds[key] = {"hold": hold, "closed_by": closed}
        else:
            # Every observed unresolved event is an obligation, even when a
            # newer event of this operation wins the displayed receipt.
            holds.setdefault(key, {})[hold["id"]] = hold
    operations, problems = {}, []
    for key in sorted(set(holds) | set(closed_holds) | set(old_operations)):
        old, current = old_operations.get(key), holds.get(key)
        terminal = closed_holds.get(key)
        knowledge = knowledge_by_key.get(key, {"ids": {}, "family": None})
        resolved = dict(knowledge["ids"])
        if terminal:
            resolved.setdefault(terminal["hold"]["id"], terminal)
        pending, prior_selected_closure = {}, None
        if old and old["closed_by"]:
            if not current and not terminal:
                continue  # terminal history disappeared, no obligation remains
            if not current and (not terminal or terminal["hold"]["id"] in knowledge["ids"]
                                or terminal["hold"]["at"] <= old["hold"]["at"]):
                operations[key] = dict(old, resolved=resolved)  # preserve FIRST accepted done observation
                continue
        if old and not old["closed_by"]:
            for prior in old.get("unresolved", [old["hold"]]):
                hold = current_by_id.get(prior["id"], prior)
                closed = closing_event(hold, latest_ok, alias_launch) or remembered_closure(hold, knowledge)
                if not closed:
                    pending[hold["id"]] = hold
                else:
                    result = {"hold": hold, "closed_by": closed}
                    resolved.setdefault(hold["id"], result)
                    if hold["id"] == old["hold"]["id"]:
                        prior_selected_closure = result
                    if not terminal or hold["at"] >= terminal["hold"]["at"]:
                        terminal = result
        for hold in (current or {}).values():
            pending.pop(hold["id"], None)
            pending[hold["id"]] = hold  # native last-event tie wins over retained missing history
        if pending:
            witnesses = list(pending.values())
            hold = max(enumerate(witnesses), key=lambda pair: (pair[1]["at"], pair[0]))[1]
            operations[key] = {"hold": hold, "closed_by": None, "done_at": None, "unresolved": witnesses, "resolved": resolved}
            for retained in witnesses:
                if retained["id"] not in current_by_id:
                    problems.append(f"unresolved native hold {retained['id']} disappeared before explicit closure ({key})")
        elif terminal:
            # Resolve the previously selected open hold, not an already-closed
            # newer historical stop whose earlier observation was not group done.
            operations[key] = dict(prior_selected_closure or terminal, done_at=scanned, unresolved=[], resolved=resolved)
    if len(operations) > OPERATION_LIMIT:
        raise ValueError(f"native logical-operation retention exceeds {OPERATION_LIMIT} operations")
    witness_count = sum(len(op.get("unresolved", [])) + 2 * len(op.get("resolved", {}))
                        + (2 if op["closed_by"] else 0) for op in operations.values())
    if witness_count > WITNESS_LIMIT:
        raise ValueError(f"native retained witness count exceeds {WITNESS_LIMIT}")
    projection = {"scanned_at": scanned, "operations": operations}
    if len(json.dumps(projection, ensure_ascii=True).encode()) > CACHE_BYTES:
        raise ValueError(f"native compact projection exceeds {CACHE_BYTES} bytes")
    return projection, problems
