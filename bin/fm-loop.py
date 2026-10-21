#!/usr/bin/env python3
"""Read-only experiment-loop view: request stages, stall alerts and lead time.

Driven by bin/fm-loop.sh, whose header owns usage. This file owns the source
list, the stage rules, the alert conditions and the lead-time buckets;
docs/loop-status.md explains them and docs/configuration.md "Loop sources"
owns the config file format and the handoff-registry/v1 stage key that
declares a source. Every source is read directly and never written; the only
writes are this home's own alert records and cursors under state/loop-alerts/.
"""
import argparse
import datetime
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import sqlite3
import statistics
import sys
import threading
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from fm_receipt_io import atomic, atomic_text, iso_epoch, load  # noqa: E402
import fm_handoff_registry as registry  # noqa: E402

ALERT_SCHEMA = "fm-loop-alert.v1"
CURSOR_SCHEMA = "fm-loop-reported.v1"
STATUS_SCHEMA = "fm-loop-status.v1"
LEADTIME_SCHEMA = "fm-loop-leadtime.v1"
LANE_CURSOR_SCHEMA = "fm-loop-lane-cursor.v1"
LANE_ALERTS_SCHEMA = "tj-capacity-alerts/v1"
QUEUE_STATE_SCHEMAS = ("tj-capacity-queue-state/v1", "tj-capacity-queue-state/v2")
SNAPSHOT_LIMIT = 32 * 1024 * 1024
# The lane alerts journal is never truncated by its writer.
LANE_LIMIT = 128 * 1024 * 1024
STATUS_TAIL = 256 * 1024
# Seconds the source reads, and then the batch lookups, may take; fm-loop.sh
# passes a quarter of its run cap.
READ_TIMEOUT = 15

# Hours; each can be overridden by a `threshold <name> <hours>` config line.
THRESHOLDS = {
    "no_collection_hours": 24,
    "accepted_no_package_hours": 12,
    "collected_no_analysis_hours": 6,
}

SOURCE_NAMES = (
    "submits", "handoff_queue", "operator_acked", "collected", "snapshot",
    "batches", "catalog", "backlog", "parks", "tetjet_status",
)
# The capacity filler's observation files and STOP marker: no default, read
# only when configured, and their failures raise filler-stale, not
# source-unreadable. The config's lines form the tj-capacity group; each
# registry stage that declares one forms a group named <protocol>/<stage>.
FILLER_SOURCES = ("lane_alerts", "queue_state", "filler_stop")
DEFAULT_FILLER = "tj-capacity"
# The handoff-registry/v1 stage ext key, under the fragment's own home id,
# that declares the stage's records as loop sources.
REGISTRY_KEY = "loop-source"
# About three ticks of the filler's 90 s interval, rounded up.
FILLER_STALE_MINUTES = 5

# Stages a request is open in, in loop order.
STAGES = (
    "filed", "refused", "accepted", "launch-ready", "taken", "running",
    "ended", "collected", "registered", "analysis-refused",
)
# Stages after a launch package exists; collection can only follow these.
LAUNCHED = {"launch-ready", "taken", "running", "ended"}
TETJET_KEYS = ("tj-lane-refused", "tj-idle", "tj-capacity-unread")
CLOSING_KINDS = {"REQUEST SUPERSEDED": "superseded", "REQUEST WITHDRAWN": "withdrawn"}
PACKAGE_KINDS = {"READY FOR LAUNCH", "BATCH CUT"}
WEEK_STAGES = (
    ("filing->gate", "submitted", "intake"),
    ("gate->package", "accepted", "package"),
    ("package->operator", "package", "taken"),
    ("operator->start", "taken", "started"),
    ("start->end", "started", "ended"),
    ("end->collected", "ended", "collected"),
    ("collected->analysis", "collected", "analysed"),
)


def utc(epoch):
    if epoch is None:
        return None
    return datetime.datetime.fromtimestamp(epoch, datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def span(seconds):
    if seconds is None:
        return "unknown"
    seconds = max(0, int(seconds))
    days, rest = divmod(seconds, 86400)
    hours, rest = divmod(rest, 3600)
    if days:
        return "%dd%02dh" % (days, hours)
    return "%dh%02dm" % (hours, rest // 60)


def family_of(rid, task=None):
    if isinstance(task, str) and task:
        return task
    return re.sub(r"-\d+$", "", rid)


class Source:
    """One input: its path, whether it was configured, and how reading went."""

    def __init__(self, name, paths, configured, kind=None):
        self.name = name
        self.kind = kind or name
        self.paths = list(dict.fromkeys(paths))
        self.configured = configured
        self.state = "ok"
        self.detail = ""

    def fail(self, state, detail):
        # Keep the worst outcome: unreadable beats missing.
        if self.state == "unreadable":
            return
        self.state = state
        self.detail = detail

    @property
    def ok(self):
        return self.state == "ok"

    def view(self):
        return {"paths": [str(p) for p in self.paths], "state": self.state,
                "configured": self.configured, "detail": self.detail}


def registry_sources(home):
    """Loop sources the handoff registry declares: (paths, groups, registry source).

    paths maps a source kind to the stage paths declared for it; groups maps
    <protocol>/<stage> to {filler kind: path}. The registry source is None
    when no home this machine sees has a fragment; it reads unreadable when a
    fragment that may declare a source cannot be loaded, so its sources are
    unknown, not absent. Another home's invalid fragment that names no loop
    source is its watcher's alarm, not this view's.
    """
    paths, groups = {}, {}
    src = Source("registry", [home / "state/handoff-registry"], True)
    try:
        _, homes = registry.discover(home)
    except (OSError, ValueError) as exc:
        src.fail("unreadable", "home discovery failed: %s" % exc)
        return paths, groups, src
    files = []
    for hid, hpath in sorted(homes.items()):
        try:
            files += registry.fragment_files(hpath)
        except OSError as exc:
            src.fail("unreadable", "%s/state/handoff-registry: %s" % (hpath, exc))
    if not files and src.ok:
        return paths, groups, None
    module = registry.validator()
    schema = module.Schema(str(Path(registry.HERE).parent / "docs/handoff-coverage/handoff-registry-v1.schema.json"))
    for path in files:
        try:
            text = path.read_text(encoding="utf-8")
        except (OSError, UnicodeDecodeError) as exc:
            src.fail("unreadable", "%s: %s" % (path, exc))
            continue
        doc, problem = registry.check_fragment(module, schema, path)
        if problem:
            if "." + REGISTRY_KEY in text:
                src.fail("unreadable", "%s %s" % (path, problem))
            continue
        if doc is None:
            continue
        key = "%s.%s" % (doc["home"], REGISTRY_KEY)
        for protocol in doc["protocols"]:
            for stage in protocol["stages"]:
                value = (stage.get("ext") or {}).get(key)
                if value is None:
                    continue
                where = "%s %s/%s %s" % (path, protocol["id"], stage["name"], key)
                if not isinstance(value, str):
                    src.fail("unreadable", "%s is not a string" % where)
                    continue
                group = "%s/%s" % (protocol["id"], stage["name"])
                for item in (part.strip() for part in value.split(",")):
                    kind, sep, target = item.partition("=")
                    target = target if sep else stage["input"]["path"]
                    if kind not in SOURCE_NAMES and kind not in FILLER_SOURCES:
                        src.fail("unreadable", "%s names unknown source %r" % (where, kind))
                    elif not target.startswith("/"):
                        src.fail("unreadable", "%s gives %s a path that is not absolute" % (where, kind))
                    elif kind in FILLER_SOURCES:
                        if kind in groups.setdefault(group, {}):
                            src.fail("unreadable", "%s names %s twice" % (where, kind))
                        groups[group][kind] = Path(target)
                    else:
                        paths.setdefault(kind, []).append(Path(target))
    src.detail = src.detail or "%d fragment(s)" % len(files)
    return paths, groups, src


def read_config(home):
    """Parse <home>/config/loop-sources and the registry; return (sources, thresholds, stale_minutes, warnings)."""
    ledger = os.environ.get("LATTICE_LEDGER_DIR") or os.path.expanduser("~/lattice-ledger")
    defaults = {
        "submits": [home / "data/tetjet-offload/requests"],
        "handoff_queue": [Path(os.path.expanduser("~/.local/share/tj-handoff/queue"))],
        "operator_acked": [Path(os.path.expanduser("~/.local/share/tj-handoff/consumers/tj-operator.acked"))],
        "collected": [home / "data/tetjet-collected/requests"],
        "snapshot": [home / "data/tetjet-offload/queue-snapshot.json"],
        "batches": [Path(os.path.expanduser("~/lattice-batches"))],
        "catalog": [Path(ledger) / "catalog.sqlite"],
        "backlog": [home / "data/backlog.md"],
        "parks": [home / "state"],
        "tetjet_status": [home / "state/tetjet-mate.status"],
    }
    configured = {}
    thresholds = dict(THRESHOLDS)
    stale_minutes = FILLER_STALE_MINUTES
    warnings = []
    path = home / "config/loop-sources"
    try:
        lines = path.read_text(encoding="utf-8").splitlines() if path.is_file() else []
    except (OSError, UnicodeDecodeError) as exc:
        warnings.append("config %s unreadable (%s); using defaults" % (path, exc))
        lines = []
    for number, line in enumerate(lines, 1):
        fields = line.split("#", 1)[0].split()
        if not fields:
            continue
        where = "config/loop-sources line %d" % number
        if fields[0] == "source" and len(fields) == 3 and (fields[1] in SOURCE_NAMES or fields[1] in FILLER_SOURCES):
            value = Path(os.path.expanduser(fields[2]))
            if not value.is_absolute():
                value = home / value
            if fields[1] in FILLER_SOURCES:
                configured[fields[1]] = [value]
            else:
                configured.setdefault(fields[1], []).append(value)
        elif fields[0] == "threshold" and len(fields) == 3 and fields[1] in THRESHOLDS:
            try:
                hours = float(fields[2])
            except ValueError:
                hours = -1
            if hours <= 0:
                warnings.append("%s: threshold %s must be a positive number of hours; kept %s" % (where, fields[1], thresholds[fields[1]]))
            else:
                thresholds[fields[1]] = hours
        elif fields[0] == "threshold" and len(fields) == 3 and fields[1] == "filler_stale_minutes":
            try:
                minutes = float(fields[2])
            except ValueError:
                minutes = -1
            if minutes <= 0:
                warnings.append("%s: threshold filler_stale_minutes must be a positive number of minutes; kept %s" % (where, stale_minutes))
            else:
                stale_minutes = minutes
        else:
            warnings.append("%s ignored: %s" % (where, line.strip()))
    declared, groups, registry_src = registry_sources(home)
    sources = {}
    # A declared path joins configured ones and replaces the default.
    for name in SOURCE_NAMES:
        paths = configured.get(name, []) + declared.get(name, [])
        sources[name] = Source(name, paths or defaults[name], bool(paths))
    for name in FILLER_SOURCES:
        if name in configured:
            sources[name] = Source(name, configured[name], True)
    for group, kinds in sorted(groups.items()):
        for kind, path in sorted(kinds.items()):
            sources["%s@%s" % (kind, group)] = Source("%s@%s" % (kind, group), [path], True, kind)
    if registry_src is not None:
        sources["registry"] = registry_src
    return sources, thresholds, stale_minutes, warnings


def load_json(path, src, limit=None):
    if not os.path.lexists(path):
        src.fail("missing", "%s not found" % path)
        return None
    try:
        return load(path, limit) if limit else load(path)
    except (OSError, ValueError) as exc:
        src.fail("unreadable", "%s: %s" % (path, exc))
    return None


def list_dir(path, src, suffix):
    if not path.is_dir():
        src.fail("missing", "%s is not a directory" % path)
        return []
    try:
        return sorted(p for p in path.iterdir() if p.name.endswith(suffix))
    except OSError as exc:
        src.fail("unreadable", "%s: %s" % (path, exc))
        return []


def each_file(src, suffix):
    for folder in src.paths:
        yield from list_dir(folder, src, suffix)


def read_submits(src):
    out = {}
    for path in each_file(src, ".submit.json"):
        data = load_json(path, src)
        if isinstance(data, dict) and isinstance(data.get("id"), str):
            out[data["id"]] = data
        elif data is not None:
            src.fail("unreadable", "%s has no request id" % path)
    return out


def read_queue(src):
    out = []
    for path in each_file(src, ".json"):
        data = load_json(path, src)
        if isinstance(data, dict) and data.get("schema") == "tj-handoff/v1" and isinstance(data.get("kind"), str):
            data["_epoch"] = iso_epoch(data.get("created_at"))
            out.append(data)
        elif data is not None:
            src.fail("unreadable", "%s is not a tj-handoff/v1 record" % path)
    out.sort(key=lambda r: (r["_epoch"] or 0, r.get("id") or ""))
    return out


def read_acked(src):
    """Record id to its first ack time, over every acks file."""
    out = {}
    for path in src.paths:
        try:
            text = path.read_text(encoding="utf-8")
        except FileNotFoundError:
            src.fail("missing", "%s not found" % path)
            continue
        except (OSError, UnicodeDecodeError) as exc:
            src.fail("unreadable", "%s: %s" % (path, exc))
            continue
        seen = {}
        for line in text.splitlines():
            fields = line.split()
            if len(fields) >= 2 and iso_epoch(fields[1]) is not None:
                seen.setdefault(fields[0], iso_epoch(fields[1]))
        for rid, at in seen.items():
            out[rid] = min(at, out.get(rid, at))
    return out


def read_collected(src):
    out = {}
    for path in each_file(src, ".json"):
        data = load_json(path, src)
        if isinstance(data, dict) and isinstance(data.get("request_id"), str):
            out[data["request_id"]] = data
        elif data is not None:
            src.fail("unreadable", "%s has no request_id" % path)
    return out


def read_snapshot(src):
    jobs, generated = {}, []
    for path in src.paths:
        data = load_json(path, src, SNAPSHOT_LIMIT)
        if data is None:
            continue
        if not isinstance(data, dict) or data.get("schema") != "tetjet-queue-snapshot.v1" or not isinstance(data.get("jobs"), list):
            src.fail("unreadable", "%s is not a tetjet-queue-snapshot.v1 file" % path)
            continue
        for job in data["jobs"]:
            if isinstance(job, dict):
                for key in (job.get("batch_id"), job.get("id")):
                    if isinstance(key, str):
                        jobs.setdefault(key, job)
        generated.append("generated %s" % data.get("generated_at"))
    if src.ok:
        src.detail = "; ".join(generated)
    return jobs


class Batches:
    """Lazy reader of ~/lattice-batches/.registered and .analysis per batch; the first root that has a file wins."""

    def __init__(self, src):
        self.src = src
        self.cache = {}
        if src.ok:
            for root in src.paths:
                if not root.is_dir():
                    src.fail("missing", "%s is not a directory" % root)
                    break

    def prefetch(self, batches):
        for batch in batches:
            self.get(batch)
        return self

    def get(self, batch):
        if batch in self.cache:
            return self.cache[batch]
        info = {"registered": None, "collected": None, "launched": None, "analysed": None, "refusal": None}
        if self.src.ok and re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*", batch):
            for root in self.src.paths:
                self.read_batch(root, batch, info)
        self.cache[batch] = info
        return info

    def read_batch(self, root, batch, info):
        if info["registered"] is None:
            reg = root / ".registered" / (batch + ".json")
            if reg.is_file():
                data = load_json(reg, self.src)
                if isinstance(data, dict):
                    info["registered"] = iso_epoch(data.get("registered_utc"))
                    collection = data.get("collection") if isinstance(data.get("collection"), dict) else {}
                    info["collected"] = iso_epoch(collection.get("recorded_utc")) or iso_epoch(data.get("collected_utc"))
                    info["launched"] = iso_epoch(data.get("launched_utc"))
        current = root / ".analysis" / batch / "CURRENT"
        if info["analysed"] is None and current.is_file():
            data = load_json(current, self.src)
            if isinstance(data, dict):
                info["analysed"] = iso_epoch(data.get("analysed_utc"))
        refused = root / ".analysis" / batch / "refused.json"
        if info["refusal"] is None and refused.is_file():
            data = load_json(refused, self.src)
            if isinstance(data, dict) and not data.get("resolved_utc"):
                info["refusal"] = {
                    "code": data.get("code"),
                    "message": str(data.get("message") or "")[:200],
                    "since": iso_epoch(data.get("unresolved_since_utc")) or iso_epoch(data.get("refused_utc")),
                }


def read_catalog(src):
    out = {}
    for path in src.paths:
        if not path.is_file():
            src.fail("missing", "%s not found" % path)
            continue
        try:
            conn = sqlite3.connect("file:%s?mode=ro" % path, uri=True, timeout=5)
            try:
                rows = conn.execute("SELECT batch_id, COUNT(*), MIN(started_utc) FROM runs WHERE batch_id IS NOT NULL GROUP BY batch_id").fetchall()
            finally:
                conn.close()
        except sqlite3.Error as exc:
            src.fail("unreadable", "%s: %s" % (path, exc))
            continue
        for batch, runs, started in rows:
            row = out.setdefault(batch, {"runs": 0, "started": None})
            row["runs"] += runs
            started = iso_epoch(started)
            if started is not None:
                row["started"] = min(started, row["started"] or started)
    return out


def read_holds(src):
    holds = {}
    for path in src.paths:
        try:
            lines = path.read_text(encoding="utf-8").splitlines()
        except FileNotFoundError:
            src.fail("missing", "%s not found" % path)
            continue
        except (OSError, UnicodeDecodeError) as exc:
            src.fail("unreadable", "%s: %s" % (path, exc))
            continue
        for index, line in enumerate(lines):
            match = re.match(r"- \[ \] (\S+) - .*\(hold-kind: captain\)", line)
            if not match:
                continue
            since = None
            if index + 1 < len(lines):
                found = re.match(r"\s+Captain hold set: (\S+)", lines[index + 1])
                since = iso_epoch(found.group(1)) if found else None
            holds[match.group(1)] = since
    return holds


def read_parks(src):
    parks = []
    for folder in src.paths:
        for path in list_dir(folder, src, ".meta"):
            try:
                text = path.read_text(encoding="utf-8")
            except (OSError, UnicodeDecodeError) as exc:
                src.fail("unreadable", "%s: %s" % (path, exc))
                continue
            meta = dict(line.split("=", 1) for line in text.splitlines() if "=" in line)
            if meta.get("park_state") == "parked" and meta.get("park_when"):
                parks.append({"task": path.name[:-5], "when": meta["park_when"],
                              "deadline": meta.get("park_deadline") or None, "meta": str(path)})
    return parks


def read_tetjet_alerts(src):
    out = []
    for path in src.paths:
        try:
            with open(path, "rb") as stream:
                stream.seek(0, os.SEEK_END)
                size = stream.tell()
                stream.seek(max(0, size - STATUS_TAIL))
                text = stream.read().decode("utf-8", "replace")
        except FileNotFoundError:
            src.fail("missing", "%s not found" % path)
            continue
        except OSError as exc:
            src.fail("unreadable", "%s: %s" % (path, exc))
            continue
        last = {}
        for line in text.splitlines():
            match = re.match(r"(\w[\w-]*) \[key=([\w-]+)\](?: \[at=(\d+)\])?: ?(.*)", line)
            if match and match.group(2) in TETJET_KEYS:
                last[match.group(2)] = (match.group(1), int(match.group(3)) if match.group(3) else None, match.group(4))
        out += [{"key": key, "since": utc(at), "line": text_}
                for key, (state, at, text_) in sorted(last.items()) if state == "blocked"]
    return out


def read_stamped(src, limit, schemas):
    """Load a filler observation file whose schema is one of schemas; None if not read."""
    path = src.paths[0]
    data = load_json(path, src, limit)
    if data is None:
        return None
    schema = data.get("schema") if isinstance(data, dict) else None
    if schema not in schemas:
        src.fail("unreadable", "%s has schema %r, not %s; refused" % (path, schema, " or ".join(schemas)))
        return None
    at = iso_epoch(data.get("at"))
    try:
        mtime = int(os.stat(path).st_mtime)
    except OSError as exc:
        src.fail("unreadable", "%s: %s" % (path, exc))
        return None
    if at is None:
        src.fail("unreadable", "%s has no readable at" % path)
        return None
    src.detail = "%s at %s" % (schema, data.get("at"))
    return data, at, mtime


def read_lane_alerts(src):
    """The filler's tj-capacity-alerts/v1 snapshot: active alerts and the event journal."""
    got = read_stamped(src, LANE_LIMIT, (LANE_ALERTS_SCHEMA,))
    if got is None:
        return None
    data, at, mtime = got

    def alert_ok(alert):
        return isinstance(alert, dict) and all(isinstance(alert.get(k), str) for k in ("key", "kind", "subject", "reason"))

    active, events, revision = data.get("active"), data.get("events"), data.get("revision")
    bad = None
    if not isinstance(active, dict) or not all(alert_ok(a) and a["key"] == k for k, a in active.items()):
        bad = "active"
    elif not isinstance(events, list) or not all(
            isinstance(e, dict) and isinstance(e.get("seq"), int) and e.get("action") in ("raised", "cleared")
            and isinstance(e.get("key"), str) and alert_ok(e.get("alert")) and isinstance(e.get("at"), str) for e in events):
        bad = "events"
    elif not isinstance(revision, int) or isinstance(revision, bool) or revision < 0:
        bad = "revision"
    if bad:
        src.fail("unreadable", "%s has a malformed %s" % (src.paths[0], bad))
        return None
    return {"at": at, "mtime": mtime, "revision": revision, "active": active, "events": events}


def read_queue_state(src):
    """The filler's queue snapshot, v1 or v2: supply and lane health kept apart."""
    got = read_stamped(src, SNAPSHOT_LIMIT, QUEUE_STATE_SCHEMAS)
    if got is None:
        return None
    data, at, mtime = got
    health = None
    if data["schema"] != QUEUE_STATE_SCHEMAS[0]:
        lanes = data.get("lanes") if isinstance(data.get("lanes"), dict) else {}
        health = {"refusing": data.get("refusing"), "since": data.get("since"), "lanes": {
            name: {k: lane.get(k) for k in ("state", "reasons", "key", "since")}
            for name, lane in sorted(lanes.items()) if isinstance(lane, dict)}}
    return {"schema": data["schema"], "seq": data.get("seq"), "at": data.get("at"), "at_epoch": at, "mtime": mtime,
            "supply": {"state": data.get("state"), "admissible_run_eq": data.get("admissible_run_eq"),
                       "free_slots": data.get("free_slots"), "queued_run_eq": data.get("queued_run_eq")},
            "lane_health": health, "why": data.get("why")}


def read_filler_stop(src):
    """True when the filler's STOP marker exists, False when not, None if unknown."""
    try:
        os.lstat(src.paths[0])
    except FileNotFoundError:
        src.detail = "absent"
        return False
    except OSError as exc:
        src.fail("unreadable", "%s: %s" % (src.paths[0], exc))
        return None
    src.detail = "present"
    return True


def lane_alert_id(alert, key, tag):
    safe = lambda value: re.sub(r"[^A-Za-z0-9._-]", "_", value)
    ident = key if tag == "lane_alerts" else "%s %s" % (tag, key)
    return "%s--%s--%s" % (safe(alert["kind"]), safe(alert["subject"])[:80], hashlib.sha256(ident.encode()).hexdigest()[:10])


def lane_message(alert):
    evidence = alert.get("evidence") if isinstance(alert.get("evidence"), dict) else {}
    summary = ", ".join("%s=%s" % (k, str(v)[:60]) for k, v in sorted(evidence.items()))[:200]
    return "%s %s: %s (since %s)%s" % (alert["kind"], alert["subject"], alert["reason"][:200], alert.get("since") or "unknown",
                                      "; evidence " + summary if summary else "")


def request_refs(record, submits_dirs):
    """Request ids a package record names, through covers[] or requests[].path.

    A requests[] path counts only inside a submits folder; packages also
    name their own per-batch request copies, which are not requests.
    """
    ids = []
    for cover in record.get("covers") or []:
        if isinstance(cover, dict) and isinstance(cover.get("request_id"), str):
            ids.append(cover["request_id"])
    for ref in record.get("requests") or []:
        path = ref.get("path") if isinstance(ref, dict) else None
        if isinstance(path, str) and path.endswith(".json") and Path(path).parent in submits_dirs:
            ids.append(os.path.basename(path)[:-5])
    return list(dict.fromkeys(ids))


class Loop:
    def __init__(self, home, now, read_timeout=READ_TIMEOUT):
        self.home = home
        self.now = now
        self.read_timeout = read_timeout
        self.timed_out = False
        self.sources, self.thresholds, self.stale_minutes, self.warnings = read_config(home)
        fillers = {"lane_alerts": read_lane_alerts, "queue_state": read_queue_state, "filler_stop": read_filler_stop}
        got = self.bounded([
            ("submits", read_submits, {}), ("handoff_queue", read_queue, []), ("operator_acked", read_acked, {}),
            ("collected", read_collected, {}), ("snapshot", read_snapshot, {}), ("catalog", read_catalog, {}),
            ("backlog", read_holds, {}), ("parks", read_parks, []), ("tetjet_status", read_tetjet_alerts, [])]
            + [(name, fillers[src.kind], None) for name, src in self.sources.items() if src.kind in fillers])
        self.submits, self.queue, self.acked = got["submits"], got["handoff_queue"], got["operator_acked"]
        self.collected, self.jobs, self.catalog = got["collected"], got["snapshot"], got["catalog"]
        self.holds, self.parks, self.tetjet = got["backlog"], got["parks"], got["tetjet_status"]
        self.fillers = filler_groups(self.sources, got)
        self.requests = self.join()

    def bounded(self, readers):
        """Run each configured reader in its own thread, all within read_timeout seconds.

        A reader still running at the deadline (a slow disk, a FIFO, a lock)
        is abandoned: its source reads as unreadable, so what it feeds is
        unknown, and its result is the given empty value.
        """
        threads, results, errors = {}, {}, {}

        def run(name, reader, src):
            try:
                results[name] = reader(src)
            except Exception as exc:  # noqa: BLE001 - one source's bug must not stop the others
                errors[name] = "%s: %s" % (type(exc).__name__, exc)

        for name, reader, empty in readers:
            if name in self.sources:
                threads[name] = (threading.Thread(target=run, args=(name, reader, self.sources[name]), daemon=True), empty)
                threads[name][0].start()
        deadline = time.monotonic() + self.read_timeout
        got = {}
        for name, (thread, empty) in threads.items():
            thread.join(max(0, deadline - time.monotonic()))
            if name in results:
                got[name] = results[name]
                continue
            # The abandoned thread keeps the old Source, so nothing it does later shows.
            old = self.sources[name]
            src = self.sources[name] = Source(name, old.paths, old.configured, old.kind)
            if thread.is_alive():
                self.timed_out = True
                src.fail("unreadable", "read did not finish within %gs (a slow disk or a blocking file)" % self.read_timeout)
            else:
                src.fail("unreadable", "reader failed: %s" % errors.get(name, "no result"))
            got[name] = empty
        return got

    def join(self):
        reqs = {}

        def req(rid):
            if rid not in reqs:
                submit = self.submits.get(rid) or {}
                reqs[rid] = {"id": rid, "family": family_of(rid, submit.get("task")),
                             "submitted": iso_epoch(submit.get("submitted_utc")),
                             "sha256": submit.get("request_sha256"), "intake": None,
                             "closed": None, "all_cut": None, "packages": {}, "replaced_by": None}
            return reqs[rid]

        for rid in self.submits:
            req(rid)
        for rid, submit in self.submits.items():
            old = submit.get("replaces")
            if isinstance(old, str) and old:
                req(old)["replaced_by"] = rid
        abandoned = {}
        records = {}
        for rec in self.queue:
            kind, subject, at = rec["kind"], rec.get("subject"), rec["_epoch"]
            if kind == "BATCH ABANDONED" and isinstance(subject, str):
                abandoned[subject] = at
        for rec in self.queue:
            kind, subject, at = rec["kind"], rec.get("subject"), rec["_epoch"]
            if not isinstance(subject, str):
                continue
            if kind in ("REQUEST ACCEPTED", "REQUEST REFUSED"):
                r = req(subject)
                sha = (rec.get("artefact") or {}).get("sums_sha256")
                if r["sha256"] and sha and sha != r["sha256"]:
                    continue
                r["intake"] = {"kind": kind, "at": at, "reasons": rec.get("reasons") or [], "id": rec.get("id")}
            elif kind in CLOSING_KINDS:
                r = req(subject)
                r["closed"] = {"why": CLOSING_KINDS[kind], "at": at, "replaced_by": rec.get("replaced_by")}
            elif kind == "REQUEST ALL CUT":
                req(subject)["all_cut"] = at
            elif kind in PACKAGE_KINDS:
                records.setdefault(subject, []).append(rec.get("id"))
                for rid in request_refs(rec, self.sources["submits"].paths):
                    req(rid)["packages"].setdefault(subject, {
                        "batch": subject, "at": at, "abandoned": abandoned.get(subject)})
        for rid, rec in self.collected.items():
            r = req(rid)
            for batch in rec.get("batches") or []:
                if isinstance(batch, dict) and isinstance(batch.get("batch_id"), str):
                    r["packages"].setdefault(batch["batch_id"], {
                        "batch": batch["batch_id"], "at": None, "abandoned": abandoned.get(batch["batch_id"])})
        names = list(dict.fromkeys(pkg["batch"] for r in reqs.values() for pkg in r["packages"].values()))
        self.batches = self.bounded([("batches", lambda src: Batches(src).prefetch(names), None)])["batches"]
        if self.batches is None:
            self.batches = Batches(self.sources["batches"])
        for r in reqs.values():
            for pkg in r["packages"].values():
                pkg["records"] = records.get(pkg["batch"], [])
                self.batch_state(r, pkg)
            self.stage(r)
        return reqs

    def batch_state(self, r, pkg):
        batch = pkg["batch"]
        info = self.batches.get(batch)
        job = self.jobs.get(batch) or {}
        cat = self.catalog.get(batch) or {}
        pkg["taken"] = min((self.acked[i] for i in pkg["records"] if i in self.acked), default=None)
        pkg["started"] = iso_epoch(job.get("started_utc")) or cat.get("started") or info["launched"]
        pkg["ended"] = iso_epoch(job.get("ended_utc"))
        pkg["job_state"] = job.get("state")
        pkg["job_note"] = job.get("state_note")
        pkg["runs"] = cat.get("runs")
        rec = self.collected.get(r["id"]) or {}
        receipt = None
        for entry in rec.get("batches") or []:
            if isinstance(entry, dict) and entry.get("batch_id") == batch:
                receipt = iso_epoch(rec.get("recorded_at"))
        pkg["collected"] = info["collected"] or receipt
        pkg["registered"] = info["registered"]
        pkg["analysed"] = info["analysed"]
        pkg["refusal"] = info["refusal"]

    def stage(self, r):
        """Set r's stage, since, last event and reason; None stage means not open."""
        s = self.sources
        rec = self.collected.get(r["id"])
        pkgs = [p for p in r["packages"].values() if not p["abandoned"]]
        events = []
        if r["submitted"]:
            events.append((r["submitted"], "submitted"))
        if r["intake"]:
            events.append((r["intake"]["at"], r["intake"]["kind"].lower()))
        for p in r["packages"].values():
            for key, label in (("at", "package %s"), ("abandoned", "package %s abandoned"), ("taken", "operator took %s"),
                               ("started", "%s started"), ("ended", "%s ended"), ("collected", "%s collected"),
                               ("registered", "%s registered"), ("analysed", "%s analysed")):
                if p.get(key):
                    events.append((p[key], label % p["batch"]))
        if r["all_cut"]:
            events.append((r["all_cut"], "all lines cut"))
        if r["closed"]:
            events.append((r["closed"]["at"], "request %s" % r["closed"]["why"]))
        events = [e for e in events if e[0]]
        events.sort()
        r["last_event"] = {"at": events[-1][0], "what": events[-1][1]} if events else None

        def put(stage, since, reason):
            r["stage"], r["since"], r["reason"] = stage, since, reason

        if r["closed"]:
            return put(None, r["closed"]["at"], "request %s" % r["closed"]["why"])
        if rec and (rec.get("outcome") == "withdrawn" or rec.get("superseded_by")):
            return put(None, iso_epoch(rec.get("recorded_at")), "collected record says %s" % rec.get("outcome"))
        if r["replaced_by"] and not pkgs:
            return put(None, None, "replaced by %s" % r["replaced_by"])
        # Without a collected record (older requests), every package collected counts.
        collected = bool(rec.get("fully_collected")) if rec else (bool(pkgs) and all(p["collected"] for p in pkgs))
        if collected:
            when = iso_epoch(rec.get("recorded_at")) if rec else max(p["collected"] for p in pkgs)
            refused = [p for p in pkgs if p["refusal"]]
            if refused:
                p = refused[0]
                return put("analysis-refused", p["refusal"]["since"], "analysis of %s refused: %s" % (p["batch"], p["refusal"]["code"]))
            if not s["batches"].ok:
                return put("collected", when, "registration and analysis unknown (batches %s)" % s["batches"].state)
            unregistered = [p for p in pkgs if not p["registered"]]
            if unregistered:
                return put("collected", when, "waiting for registration of %s" % unregistered[0]["batch"])
            unanalysed = [p for p in pkgs if not p["analysed"]]
            if unanalysed:
                return put("registered", max(p["registered"] for p in pkgs), "waiting for analysis of %s" % unanalysed[0]["batch"])
            return put(None, max(p["analysed"] for p in pkgs), "analysed")
        if not s["handoff_queue"].ok and not pkgs:
            return put("unknown", r["submitted"], "hand-off queue %s" % s["handoff_queue"].state)
        if pkgs:
            ended = [p for p in pkgs if p["ended"] and not p["collected"]]
            running = [p for p in pkgs if p["started"] and not p["ended"] and not p["collected"]]
            taken = [p for p in pkgs if p["taken"] and not p["started"] and not p["collected"]]
            ready = [p for p in pkgs if not p["taken"] and not p["started"] and not p["collected"]]
            if ended:
                p = ended[0]
                return put("ended", p["ended"], "%s ended; waiting for collection" % p["batch"])
            if running:
                p = running[0]
                return put("running", p["started"], "%s: %s" % (p["batch"], p["job_note"] or p["job_state"] or "started"))
            if taken:
                p = taken[0]
                if not (s["snapshot"].ok or s["catalog"].ok):
                    return put("taken", p["taken"], "%s start unknown (snapshot and catalog unreadable)" % p["batch"])
                return put("taken", p["taken"], "operator took %s; not started" % p["batch"])
            if ready:
                p = ready[0]
                if not s["operator_acked"].ok:
                    return put("launch-ready", p["at"], "%s pickup unknown (operator acks %s)" % (p["batch"], s["operator_acked"].state))
                return put("launch-ready", p["at"], "%s waits for the operator" % p["batch"])
            if r["all_cut"]:
                p = max(pkgs, key=lambda q: q["collected"] or 0)
                return put("collected", p["collected"], "collected batches; no fully collected record yet")
        intake = r["intake"]
        if intake and intake["kind"] == "REQUEST REFUSED":
            reason = intake["reasons"][0] if intake["reasons"] else "refused at intake"
            return put("refused", intake["at"], str(reason)[:200])
        if intake:
            hold = self.hold_for(r)
            reason = "accepted; no launch package yet"
            if hold == "unknown":
                reason += " (captain hold unknown)"
            elif hold:
                reason += " (captain hold on %s)" % hold
            return put("accepted", intake["at"], reason)
        return put("filed", r["submitted"], "waiting for the intake gate")

    def hold_for(self, r):
        if not self.sources["backlog"].ok:
            return "unknown"
        for key in (r["family"], r["id"]):
            if key in self.holds:
                return key
        return None

    def parks_for(self, rid):
        if not self.sources["parks"].ok:
            return "unknown"
        pattern = re.compile(r"(?<![A-Za-z0-9._-])%s(?![A-Za-z0-9._-])" % re.escape(rid))
        return [p for p in self.parks if pattern.search(p["when"])]

    def open_requests(self):
        rows = [r for r in self.requests.values() if r["stage"]]
        order = {name: index for index, name in enumerate(STAGES)}
        rows.sort(key=lambda r: (order.get(r["stage"], -1), r["since"] or 0, r["id"]))
        return rows

    # Alerts -----------------------------------------------------------------

    def conditions(self):
        """Current alert conditions as {alert_id: (condition, subject, message)}."""
        out = {}
        hours = self.thresholds
        s = self.sources

        def add(condition, subject, message):
            out["%s--%s" % (condition, re.sub(r"[^A-Za-z0-9._-]", "_", subject))] = (condition, subject, message)

        for name in self.failing_sources():
            src = s[name]
            add("source-unreadable", name, "%s source is %s: %s" % (name, src.state, src.detail))
        for group in self.fillers:
            problems = self.filler_problems(group)
            if problems:
                add("filler-stale", group["subject"], "%s; the filler cannot report its own death" % "; ".join(problems))
        open_rows = self.open_requests()
        if s["collected"].ok:
            last = [iso_epoch(rec.get("recorded_at")) for rec in self.collected.values()]
            last += [p["collected"] for r in self.requests.values() for p in r["packages"].values()]
            last = max([x for x in last if x] or [0])
            waiting = [r for r in open_rows if r["stage"] in LAUNCHED]
            if waiting and self.now - last > hours["no_collection_hours"] * 3600:
                add("no-collection", "loop", "no collection since %s while %d launched request(s) are open, oldest %s"
                    % (utc(last) if last else "ever", len(waiting), waiting[0]["id"]))
        if s["handoff_queue"].ok:
            for r in open_rows:
                if r["stage"] == "accepted" and r["since"] and self.now - r["since"] > hours["accepted_no_package_hours"] * 3600:
                    add("no-package", r["id"], "accepted %s ago with no launch package: %s" % (span(self.now - r["since"]), r["reason"]))
        if s["batches"].ok:
            for r in open_rows:
                for p in r["packages"].values():
                    if p["abandoned"]:
                        continue
                    if p["refusal"]:
                        add("analysis-refused", p["batch"], "analysis refused since %s: %s %s"
                            % (utc(p["refusal"]["since"]), p["refusal"]["code"], p["refusal"]["message"]))
                    elif p["collected"] and not p["analysed"] and self.now - p["collected"] > hours["collected_no_analysis_hours"] * 3600:
                        missing = "registration" if not p["registered"] else "analysis"
                        add("no-analysis", p["batch"], "collected %s ago with no %s" % (span(self.now - p["collected"]), missing))
        if s["parks"].ok:
            for rid, r in self.requests.items():
                why = (r["closed"] or {}).get("why")
                if not why:
                    continue
                for park in self.parks_for(rid):
                    add("park-on-closed", "%s--%s" % (park["task"], rid), "park %s watches %s request %s (%s)"
                        % (park["task"], why, rid, park["meta"]))
        return out

    def failing_sources(self):
        """Sources that are unreadable, or configured and not read; the filler's raise filler-stale instead."""
        return [n for n, src in self.sources.items()
                if src.kind not in FILLER_SOURCES and (src.state == "unreadable" or (src.configured and not src.ok))]

    def filler_problems(self, group):
        """Why a filler group's observation files are not current; empty while it is stopped on purpose."""
        if group["stopped"]:
            return []
        out = []
        limit = self.stale_minutes * 60
        for name, doc in (("lane_alerts", group["lane"]), ("queue_state", group["queue_state"])):
            src = group["src"].get(name)
            if src is None:
                continue
            if not src.ok:
                out.append("%s %s: %s" % (name, src.state, src.detail))
                continue
            at = doc["at"] if name == "lane_alerts" else doc["at_epoch"]
            age = self.now - min(at, doc["mtime"])
            if age > limit:
                out.append("%s last written %s ago (at %s, mtime %s; limit %g min)" % (
                    name, span(age), utc(at), utc(doc["mtime"]), self.stale_minutes))
        if out and group["stopped"] is None:
            out.append("filler_stop %s, so a STOP is not known" % group["src"]["filler_stop"].state)
        return out

    def record_alerts(self):
        """Sync durable alert records with current conditions; return open ones.

        While a source fails, no alert clears: its condition is unknown, not
        gone, so a source that comes back never re-raises what it hid.

        A raise or clear is written and synced at once. A record whose message
        changed is rewritten without a sync, since the next run derives it
        again, and an unchanged record is not written at all: a sync per open
        alert per run starves under idle I/O on a busy disk. last_seen on disk
        is therefore the last write, and this run's view carries the current one.
        """
        folder = self.home / "state/loop-alerts"
        folder.mkdir(parents=True, exist_ok=True)
        current = self.conditions()
        with open(folder / ".lock", "a") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            # Under the lock no write is in progress, so a temp file is one a killed run left.
            for stray in [*folder.glob(".receipt-*"), *folder.glob("*.json.tmp.*")]:
                stray.unlink(missing_ok=True)
                self.log(folder, "removed %s, left by a run that was stopped while writing" % stray.name)
            records = {}
            for path in sorted(folder.glob("*.json")):
                try:
                    data = load(path)
                except (OSError, ValueError):
                    continue
                if isinstance(data, dict) and data.get("schema") == ALERT_SCHEMA:
                    records[data["id"]] = data
            stamp = utc(self.now)
            for alert_id, (condition, subject, message) in current.items():
                rec = records.get(alert_id)
                raised = rec is None or rec.get("cleared_at")
                if raised:
                    event = "raised" if rec is None else "raised again"
                    occurrence = 1 if rec is None else rec.get("occurrence", 1) + 1
                    rec = {"schema": ALERT_SCHEMA, "id": alert_id, "condition": condition, "subject": subject,
                           "first_seen": stamp, "cleared_at": None, "acked_at": None, "occurrence": occurrence}
                    self.log(folder, "%s %s: %s; it prints until bin/fm-loop.sh ack %s" % (event, alert_id, message, alert_id))
                changed = rec.get("message") != message
                rec["message"] = message
                rec["last_seen"] = stamp
                records[alert_id] = rec
                if raised:
                    atomic(folder / (alert_id + ".json"), rec)
                elif changed:
                    atomic_text(folder / (alert_id + ".json"), json.dumps(rec, sort_keys=True) + "\n")
            lane_owned = set()
            for group in self.fillers:
                if "lane_alerts" not in group["src"]:
                    continue
                lane_owned.add(group["tag"])
                if group["lane"] is not None:
                    self.sync_lane(folder, records, stamp, group)
                elif group["src"]["lane_alerts"].state == "missing" and not (folder / group["cursor"]).exists():
                    # The filler starts the file empty, so a first file reports every event in it.
                    atomic(folder / group["cursor"], {"schema": LANE_CURSOR_SCHEMA, "updated_utc": stamp, "revision": 0,
                                                      "path": str(group["src"]["lane_alerts"].paths[0])})
                    self.log(folder, "seeded the lane alerts cursor%s at revision 0: the file is missing, so every event in it once it appears is reported"
                             % group["label"])
            holding = bool(self.failing_sources())
            for alert_id, rec in records.items():
                if rec.get("source") in lane_owned:
                    continue
                if alert_id not in current and not rec.get("cleared_at") and not holding:
                    rec["cleared_at"] = stamp
                    atomic(folder / (alert_id + ".json"), rec)
                    note = "it prints until acked" if not rec.get("acked_at") else "already acked"
                    self.log(folder, "cleared %s: the condition no longer holds; %s" % (alert_id, note))
        self.records = records
        return sorted((r for r in records.values() if not r.get("acked_at")), key=lambda r: (r["first_seen"], r["id"]))

    def sync_lane(self, folder, records, stamp, group):
        """Mirror the filler's lane alerts into alert records, by its event journal.

        Events after the cursor's revision apply in seq order, deduplicated by
        key, so a raise and clear between two runs still makes an occurrence.
        The active map then reconciles what the events left. A missing cursor
        seeds quietly; an unreadable one, one for another file, or one ahead
        of the file's revision reconciles against active without replaying.
        """
        doc = group["lane"]
        source_path = str(group["src"]["lane_alerts"].paths[0])
        path = folder / group["cursor"]
        seed = not path.exists()
        cursor, lost = None, None
        if not seed:
            try:
                data = load(path)
                if isinstance(data, dict) and data.get("schema") == LANE_CURSOR_SCHEMA and isinstance(data.get("revision"), int):
                    cursor = data
            except (OSError, ValueError):
                pass
            if cursor is None:
                lost = "unreadable"
            elif cursor.get("path") != source_path:
                cursor, lost = None, "for %s" % cursor.get("path")
            elif cursor["revision"] > doc["revision"]:
                lost = "at revision %d, ahead of the file's %d" % (cursor["revision"], doc["revision"])
                cursor = None
        by_key = {rec["tj_key"]: rec for rec in records.values() if rec.get("source") == group["tag"]}
        # A long journal behind the cursor touches one record many times, so
        # records and log lines are written once, after every event applies.
        self.lane_dirty, self.lane_notes = set(), []
        if cursor is not None:
            for event in sorted((e for e in doc["events"] if e["seq"] > cursor["revision"]), key=lambda e: e["seq"]):
                self.lane_event(group, records, by_key, event["action"], event["key"], event["alert"], event["at"], False)
        elif lost:
            self.lane_notes.append("lane alerts cursor%s was %s; reconciled with the active lane alerts instead of replaying the journal"
                                   % (group["label"], lost))
        for key, alert in sorted(doc["active"].items()):
            detected = alert.get("detected_at") if iso_epoch(alert.get("detected_at")) else stamp
            self.lane_event(group, records, by_key, "raised", key, alert, detected, seed)
        for key, rec in sorted(by_key.items()):
            if key not in doc["active"] and not rec.get("cleared_at"):
                self.lane_event(group, records, by_key, "cleared", key, None, stamp, False)
        for alert_id in sorted(self.lane_dirty):
            atomic(folder / (alert_id + ".json"), records[alert_id])
        if self.lane_notes:
            with open(folder / "log", "a", encoding="utf-8") as stream:
                stream.writelines("%s %s\n" % (stamp, note) for note in self.lane_notes)
        if cursor is None or cursor["revision"] != doc["revision"]:
            atomic(path, {"schema": LANE_CURSOR_SCHEMA, "path": source_path, "revision": doc["revision"], "updated_utc": stamp})
        if seed:
            self.log(folder, "seeded the lane alerts cursor%s at revision %d with %d active lane alert(s): alerts --new does not report them" % (
                group["label"], doc["revision"], len(doc["active"])))

    def lane_event(self, group, records, by_key, action, key, alert, at, quiet):
        rec = by_key.get(key)
        if action == "cleared":
            if rec and not rec.get("cleared_at"):
                rec["cleared_at"] = at
                self.lane_dirty.add(rec["id"])
                note = "it prints until acked" if not rec.get("acked_at") else "already acked"
                self.lane_notes.append("cleared %s: the filler cleared lane alert %s; %s" % (rec["id"], key, note))
            return
        message = lane_message(alert)
        dirty = rec is None or rec.get("cleared_at") or rec.get("message") != message
        if rec is None or rec.get("cleared_at"):
            alert_id = rec["id"] if rec else lane_alert_id(alert, key, group["tag"])
            occurrence = 1 if rec is None else rec.get("occurrence", 1) + 1
            rec = {"schema": ALERT_SCHEMA, "id": alert_id, "condition": alert["kind"], "subject": alert["subject"],
                   "source": group["tag"], "tj_key": key, "first_seen": at, "cleared_at": None, "acked_at": None,
                   "occurrence": occurrence}
            if quiet:
                rec["quiet"] = occurrence_key(rec)
            self.lane_notes.append("%s %s: %s; it prints until bin/fm-loop.sh ack %s" % (
                "raised" if occurrence == 1 else "raised again", alert_id, message, alert_id))
        rec["message"] = message
        rec["last_seen"] = utc(self.now)
        records[rec["id"]] = rec
        by_key[key] = rec
        if dirty:
            self.lane_dirty.add(rec["id"])

    def log(self, folder, line):
        with open(folder / "log", "a", encoding="utf-8") as stream:
            stream.write("%s %s\n" % (utc(self.now), line))


def ack(home, now, alert_id):
    folder = home / "state/loop-alerts"
    path = folder / (alert_id + ".json")
    if not re.fullmatch(r"[A-Za-z0-9._-]+", alert_id) or not path.is_file():
        print("fm-loop: no alert record %s under %s" % (alert_id, folder), file=sys.stderr)
        return 1
    with open(folder / ".lock", "a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        rec = load(path)
        if rec.get("acked_at"):
            print("%s already acknowledged at %s" % (alert_id, rec["acked_at"]))
            return 0
        rec["acked_at"] = utc(now)
        atomic(path, rec)
        with open(folder / "log", "a", encoding="utf-8") as stream:
            stream.write("%s acked %s: it stops printing; it is raised again only after it clears and recurs\n" % (utc(now), alert_id))
    print("acknowledged %s" % alert_id)
    return 0


def request_view(loop, r):
    hold = loop.hold_for(r)
    parks = loop.parks_for(r["id"])
    return {
        "id": r["id"], "family": r["family"], "stage": r["stage"],
        "since": utc(r["since"]), "age_seconds": (loop.now - r["since"]) if r["since"] else None,
        "last_event": {"at": utc(r["last_event"]["at"]), "what": r["last_event"]["what"]} if r["last_event"] else None,
        "reason": r["reason"],
        "captain_hold": hold,
        "parks": parks if parks == "unknown" else [p["task"] for p in parks],
        "batches": sorted(r["packages"]),
    }


def status(loop, as_json, show_all):
    alerts = loop.record_alerts()
    fillers = [(g, filler_view(loop, g)) for g in loop.fillers]
    filler = next((view for g, view in fillers if g["subject"] == DEFAULT_FILLER), None)
    views_by_group = {g["subject"]: view for g, view in fillers if g["subject"] != DEFAULT_FILLER}
    rows = loop.open_requests() if not show_all else sorted(loop.requests.values(), key=lambda r: r["id"])
    views = [request_view(loop, r) for r in rows]
    if as_json:
        print(json.dumps({
            "schema": STATUS_SCHEMA, "generated_utc": utc(loop.now),
            "sources": {name: src.view() for name, src in loop.sources.items()},
            "thresholds_hours": loop.thresholds, "warnings": loop.warnings,
            "requests": views, "alerts": alerts, "tetjet_alerts": loop.tetjet,
            **({"filler": filler} if filler else {}),
            **({"filler_groups": views_by_group} if views_by_group else {}),
        }, indent=2, sort_keys=True))
        return 0
    for warning in loop.warnings:
        print("warning: %s" % warning)
    print("sources: " + ", ".join("%s %s" % (n, s.state if s.ok else s.state + " (unknown)") for n, s in loop.sources.items()))
    print()
    print("%-36s %-16s %-8s %-38s %s" % ("REQUEST", "STAGE", "AGE", "LAST EVENT", "WAITS ON"))
    for v in views:
        last = v["last_event"]
        last = "%s %s" % (last["at"][5:16], last["what"]) if last else "unknown"
        extra = ""
        if v["captain_hold"]:
            extra += " [hold: %s]" % v["captain_hold"]
        if v["parks"]:
            extra += " [parks: %s]" % (v["parks"] if v["parks"] == "unknown" else ",".join(v["parks"]))
        print("%-36s %-16s %-8s %-38s %s%s" % (v["id"], v["stage"] or "closed", span(v["age_seconds"]),
                                             last[:38], v["reason"], extra))
    if not views:
        print("(no open requests)")
    print()
    if loop.sources["tetjet_status"].ok:
        print("TETJET alerts (tetjet-mate's own; not re-raised here): %s" %
              ("none open" if not loop.tetjet else ""))
        for t in loop.tetjet:
            print("  %s since %s: %s" % (t["key"], t["since"] or "unknown", t["line"]))
    else:
        print("TETJET alerts: unknown (tetjet_status %s)" % loop.sources["tetjet_status"].state)
    for group, view in fillers:
        print_filler(group, view)
    print("loop alerts: %s" % ("none open" if not alerts else ""))
    for a in alerts:
        print("  %s since %s%s: %s" % (a["id"], a["first_seen"], " (cleared %s)" % a["cleared_at"] if a.get("cleared_at") else "", a["message"]))
    return 0


def filler_groups(sources, got):
    """The filler groups: the config's tj-capacity group, then one per registry stage, from the bounded reads."""
    found = {}
    for name, src in sources.items():
        if src.kind in FILLER_SOURCES:
            found.setdefault(name.partition("@")[2], {})[src.kind] = src
    groups = []
    for key, srcs in sorted(found.items()):
        groups.append({
            "subject": key or DEFAULT_FILLER, "src": srcs,
            "tag": "lane_alerts@" + key if key else "lane_alerts",
            "cursor": "lane-alerts--%s.cursor" % re.sub(r"[^A-Za-z0-9._-]", "--", key) if key else "lane-alerts.cursor",
            "label": " for " + key if key else "",
            "lane": got.get(srcs["lane_alerts"].name) if "lane_alerts" in srcs else None,
            "queue_state": got.get(srcs["queue_state"].name) if "queue_state" in srcs else None,
            "stopped": bool(got.get(srcs["filler_stop"].name)) if "filler_stop" in srcs else False,
        })
    return groups


def filler_view(loop, group):
    """One filler group's two observation files, supply and lane health apart."""
    queue = None
    if group["queue_state"] is not None:
        queue = {k: v for k, v in group["queue_state"].items() if k not in ("at_epoch", "mtime")}
        queue["age_seconds"] = loop.now - group["queue_state"]["at_epoch"]
    lane = None
    if group["lane"] is not None:
        lane = {"at": utc(group["lane"]["at"]), "age_seconds": loop.now - group["lane"]["at"],
                "revision": group["lane"]["revision"], "active": len(group["lane"]["active"])}
    return {"stopped": group["stopped"], "stale_minutes": loop.stale_minutes, "queue_state": queue,
            "lane_alerts": lane, "problems": loop.filler_problems(group)}


def print_filler(group, filler):
    srcs = group["src"]
    if group["subject"] == DEFAULT_FILLER:
        print("TETJET filler (its observation files; lane alerts are listed with the loop alerts):")
    else:
        print("filler %s (declared in the handoff registry; lane alerts are listed with the loop alerts):" % group["subject"])
    if filler["stopped"]:
        print("  STOP marker present: stopped on purpose, so stale files raise nothing")
    q = filler["queue_state"]
    if q:
        supply = q["supply"]
        print("  queue-state %s seq %s at %s (%s ago)" % (q["schema"].rsplit("/", 1)[-1], q["seq"], q["at"], span(q["age_seconds"])))
        print("  supply: state %s, admissible_run_eq %s (free_slots %s, queued_run_eq %s)" % (
            supply["state"], supply["admissible_run_eq"], supply["free_slots"], supply["queued_run_eq"]))
        health = q["lane_health"]
        if health is None:
            print("  lane health: not in a v1 snapshot")
        else:
            print("  lane health: %s" % ("refusing since %s" % health["since"] if health["refusing"] else "no lane refusing"))
            for name, lane in health["lanes"].items():
                print("    %s %s since %s (key %s): %s" % (name, lane["state"], lane["since"], str(lane["key"])[:12],
                                                     "; ".join(str(r) for r in lane["reasons"] or [])))
    elif "queue_state" in srcs:
        print("  queue-state: unknown (%s)" % srcs["queue_state"].state)
    lane = filler["lane_alerts"]
    if lane:
        print("  lane alerts revision %d at %s (%s ago): %d active" % (lane["revision"], lane["at"], span(lane["age_seconds"]), lane["active"]))
    elif "lane_alerts" in srcs:
        print("  lane alerts: unknown (%s)" % srcs["lane_alerts"].state)
    for problem in filler["problems"]:
        print("  stale: %s" % problem)


def alert_line(a):
    cleared = " (cleared %s)" % a["cleared_at"] if a.get("cleared_at") else ""
    return "%s since %s%s: %s" % (a["id"], a["first_seen"], cleared, a["message"])


def alerts_mode(loop):
    for a in loop.record_alerts():
        print(alert_line(a))
    return 0


def occurrence_key(rec):
    return "%s#%d" % (rec["first_seen"], rec.get("occurrence", 1))


def new_alerts_mode(loop):
    """Print each unacknowledged alert occurrence not yet reported, once.

    The cursor maps alert id to the raise occurrence last reported. The first
    run seeds it with every record and prints nothing; source-unreadable
    prints like any other alert, since an unknown source is a failure. Lines
    print before the cursor moves, so a cursor that cannot be written repeats
    a line rather than losing it.
    """
    loop.record_alerts()
    folder = loop.home / "state/loop-alerts"
    path = folder / "reported.cursor"
    with open(folder / ".lock", "a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        reported, broken = None, False
        if path.exists():
            try:
                data = load(path)
                if isinstance(data, dict) and data.get("schema") == CURSOR_SCHEMA and isinstance(data.get("reported"), dict):
                    reported = data["reported"]
            except (OSError, ValueError):
                pass
            broken = reported is None
        records = sorted(loop.records.values(), key=lambda r: (r["first_seen"], r["id"]))
        if reported is not None:
            for rec in records:
                if rec.get("acked_at") or rec.get("quiet") == occurrence_key(rec):
                    continue
                if reported.get(rec["id"]) != occurrence_key(rec):
                    print(alert_line(rec))
        if broken:
            print("loop alerts: %s was unreadable; reseeded with every current alert as reported" % path)
        sys.stdout.flush()
        now_reported = {rec["id"]: occurrence_key(rec) for rec in records}
        if now_reported != reported:
            atomic(path, {"schema": CURSOR_SCHEMA, "updated_utc": utc(loop.now), "reported": now_reported})
        if reported is None:
            loop.log(folder, "seeded the reported cursor with %d alert(s): alerts --new prints only alerts raised or raised again after this" % len(records))
    return 0


def median(values):
    return statistics.median(values) if values else None


def week_of(epoch):
    year, week, _ = datetime.datetime.fromtimestamp(epoch, datetime.timezone.utc).isocalendar()
    return "%d-W%02d" % (year, week)


def leadtime(loop, as_json, weeks):
    fams = {}
    marks = []
    for r in loop.requests.values():
        intake = r["intake"]
        accepted = intake["at"] if intake and intake["kind"] == "REQUEST ACCEPTED" else None
        pkgs = [p for p in r["packages"].values() if p["at"]]
        ready = min((p["at"] for p in pkgs), default=None)
        results = [p["collected"] for p in r["packages"].values() if p["collected"]]
        first = min(results, default=None)
        fam = fams.setdefault(r["family"], {"requests": 0, "accepted": 0, "to_ready": [], "to_result": [], "waiting": 0})
        fam["requests"] += 1
        if accepted:
            fam["accepted"] += 1
            if ready and ready >= accepted:
                fam["to_ready"].append(ready - accepted)
            if first and first >= accepted:
                fam["to_result"].append(first - accepted)
            if not ready and not r["closed"]:
                fam["waiting"] += 1
        p0 = min(pkgs, key=lambda p: p["at"], default=None)
        marks.append({
            "submitted": r["submitted"], "intake": intake["at"] if intake else None, "accepted": accepted,
            "package": ready, "taken": p0["taken"] if p0 else None, "started": p0["started"] if p0 else None,
            "ended": p0["ended"] if p0 else None, "collected": p0["collected"] if p0 else None,
            "analysed": p0["analysed"] if p0 else None, "refile": r["id"] in loop.submits and bool(loop.submits[r["id"]].get("replaces")),
        })
    families = []
    for name, f in sorted(fams.items()):
        if not f["accepted"]:
            continue
        families.append({"family": name, "requests": f["requests"], "accepted": f["accepted"],
                         "accepted_to_launch_ready_median_hours": hrs(median(f["to_ready"])),
                         "accepted_to_launch_ready_max_hours": hrs(max(f["to_ready"], default=None)),
                         "accepted_to_first_result_median_hours": hrs(median(f["to_result"])),
                         "with_launch_ready": len(f["to_ready"]), "with_result": len(f["to_result"]),
                         "accepted_waiting": f["waiting"]})
    horizon = loop.now - weeks * 7 * 86400
    by_week = {}
    for m in marks:
        for label, start, end in WEEK_STAGES:
            a, b = m[start], m[end]
            if a and b and b >= a and a >= horizon:
                by_week.setdefault(week_of(a), {}).setdefault(label, []).append(b - a)
        if m["submitted"] and m["submitted"] >= horizon:
            share = by_week.setdefault(week_of(m["submitted"]), {}).setdefault("_refile", [0, 0])
            share[0] += 1
            share[1] += m["refile"]
    week_rows = []
    for week in sorted(by_week):
        cell = by_week[week]
        refile = cell.get("_refile", [0, 0])
        week_rows.append({"week": week, "submits": refile[0], "refiles": refile[1],
                          "stages": {label: {"n": len(cell.get(label, [])), "median_hours": hrs(median(cell.get(label, [])))}
                                     for label, _, _ in WEEK_STAGES}})
    unknown = sorted(n for n, s in loop.sources.items() if not s.ok and n in ("submits", "handoff_queue", "operator_acked", "collected", "snapshot", "batches", "catalog"))
    if as_json:
        print(json.dumps({"schema": LEADTIME_SCHEMA, "generated_utc": utc(loop.now), "weeks": weeks,
                          "unknown_sources": unknown, "families": families, "by_week": week_rows,
                          "not_read": ["report", "decision", "idea to verdict (hypothesis register)"]},
                         indent=2, sort_keys=True))
        return 0
    if unknown:
        print("unknown sources (their stages read as missing): %s" % ", ".join(unknown))
    print("%-34s %4s %4s %10s %10s %10s %5s" % ("FAMILY", "REQ", "ACC", "->READY", "MAX", "->RESULT", "WAIT"))
    for f in families:
        print("%-34s %4d %4d %10s %10s %10s %5d" % (
            f["family"][:34], f["requests"], f["accepted"], fmt_h(f["accepted_to_launch_ready_median_hours"]),
            fmt_h(f["accepted_to_launch_ready_max_hours"]), fmt_h(f["accepted_to_first_result_median_hours"]),
            f["accepted_waiting"]))
    print()
    print("median hours per stage, by ISO week the stage started (last %d weeks; n in brackets)" % weeks)
    for w in week_rows:
        cells = ["%s %s[%d]" % (label, fmt_h(v["median_hours"]), v["n"]) for label, v in w["stages"].items() if v["n"]]
        print("%s submits %d refiles %d  %s" % (w["week"], w["submits"], w["refiles"], "  ".join(cells)))
    print("not read: report, decision, idea to verdict")
    return 0


def hrs(seconds):
    return round(seconds / 3600.0, 1) if seconds is not None else None


def fmt_h(value):
    return "-" if value is None else "%.1fh" % value


def main():
    parser = argparse.ArgumentParser(prog="fm-loop.py")
    parser.add_argument("command", choices=("status", "alerts", "ack", "leadtime"))
    parser.add_argument("alert_id", nargs="?")
    parser.add_argument("--home", required=True)
    parser.add_argument("--now", type=int)
    parser.add_argument("--json", action="store_true")
    parser.add_argument("--all", action="store_true")
    parser.add_argument("--weeks", type=int, default=8)
    parser.add_argument("--new", action="store_true")
    parser.add_argument("--read-timeout", type=float, default=READ_TIMEOUT)
    args = parser.parse_args()
    home = Path(args.home)
    now = args.now if args.now is not None else int(datetime.datetime.now(datetime.timezone.utc).timestamp())
    if args.command == "ack":
        if not args.alert_id:
            parser.error("ack needs an alert id")
        return ack(home, now, args.alert_id)
    loop = Loop(home, now, max(0.1, args.read_timeout))
    if args.command == "status":
        rc = status(loop, args.json, args.all)
    elif args.command == "alerts":
        rc = new_alerts_mode(loop) if args.new else alerts_mode(loop)
    else:
        rc = leadtime(loop, args.json, max(1, args.weeks))
    if loop.timed_out:
        # An abandoned reader may sit in a blocking call; never wait for it at exit.
        sys.stdout.flush()
        sys.stderr.flush()
        os._exit(rc)
    return rc


if __name__ == "__main__":
    sys.exit(main())
