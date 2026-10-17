#!/usr/bin/env python3
"""Read-only experiment-loop view: request stages, stall alerts and lead time.

Driven by bin/fm-loop.sh, whose header owns usage. This file owns the source
list, the stage rules, the alert conditions and the lead-time buckets;
docs/loop-status.md explains them and docs/configuration.md "Loop sources"
owns the config file format. Every source is read directly and never written;
the only writes are this home's own alert records and the reported cursor
under state/loop-alerts/.
"""
import argparse
import datetime
import fcntl
import json
import os
from pathlib import Path
import re
import sqlite3
import statistics
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from fm_receipt_io import atomic, iso_epoch, load  # noqa: E402

ALERT_SCHEMA = "fm-loop-alert.v1"
CURSOR_SCHEMA = "fm-loop-reported.v1"
STATUS_SCHEMA = "fm-loop-status.v1"
LEADTIME_SCHEMA = "fm-loop-leadtime.v1"
SNAPSHOT_LIMIT = 32 * 1024 * 1024
STATUS_TAIL = 256 * 1024

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
REPEATABLE = {"backlog", "parks"}

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

    def __init__(self, name, paths, configured):
        self.name = name
        self.paths = paths
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


def read_config(home):
    """Parse <home>/config/loop-sources; return (sources, thresholds, warnings)."""
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
        if fields[0] == "source" and len(fields) == 3 and fields[1] in SOURCE_NAMES:
            value = Path(os.path.expanduser(fields[2]))
            if not value.is_absolute():
                value = home / value
            if fields[1] in REPEATABLE:
                configured.setdefault(fields[1], []).append(value)
            else:
                configured[fields[1]] = [value]
        elif fields[0] == "threshold" and len(fields) == 3 and fields[1] in THRESHOLDS:
            try:
                hours = float(fields[2])
            except ValueError:
                hours = -1
            if hours <= 0:
                warnings.append("%s: threshold %s must be a positive number of hours; kept %s" % (where, fields[1], thresholds[fields[1]]))
            else:
                thresholds[fields[1]] = hours
        else:
            warnings.append("%s ignored: %s" % (where, line.strip()))
    sources = {}
    for name in SOURCE_NAMES:
        sources[name] = Source(name, configured.get(name, defaults[name]), name in configured)
    return sources, thresholds, warnings


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


def read_submits(src):
    out = {}
    for path in list_dir(src.paths[0], src, ".submit.json"):
        data = load_json(path, src)
        if isinstance(data, dict) and isinstance(data.get("id"), str):
            out[data["id"]] = data
        elif data is not None:
            src.fail("unreadable", "%s has no request id" % path)
    return out


def read_queue(src):
    out = []
    for path in list_dir(src.paths[0], src, ".json"):
        data = load_json(path, src)
        if isinstance(data, dict) and data.get("schema") == "tj-handoff/v1" and isinstance(data.get("kind"), str):
            data["_epoch"] = iso_epoch(data.get("created_at"))
            out.append(data)
        elif data is not None:
            src.fail("unreadable", "%s is not a tj-handoff/v1 record" % path)
    out.sort(key=lambda r: (r["_epoch"] or 0, r.get("id") or ""))
    return out


def read_acked(src):
    out = {}
    path = src.paths[0]
    try:
        text = path.read_text(encoding="utf-8")
    except FileNotFoundError:
        src.fail("missing", "%s not found" % path)
        return out
    except (OSError, UnicodeDecodeError) as exc:
        src.fail("unreadable", "%s: %s" % (path, exc))
        return out
    for line in text.splitlines():
        fields = line.split()
        if len(fields) >= 2 and iso_epoch(fields[1]) is not None:
            out.setdefault(fields[0], iso_epoch(fields[1]))
    return out


def read_collected(src):
    out = {}
    for path in list_dir(src.paths[0], src, ".json"):
        data = load_json(path, src)
        if isinstance(data, dict) and isinstance(data.get("request_id"), str):
            out[data["request_id"]] = data
        elif data is not None:
            src.fail("unreadable", "%s has no request_id" % path)
    return out


def read_snapshot(src):
    data = load_json(src.paths[0], src, SNAPSHOT_LIMIT)
    if data is None:
        return {}
    if not isinstance(data, dict) or data.get("schema") != "tetjet-queue-snapshot.v1" or not isinstance(data.get("jobs"), list):
        src.fail("unreadable", "%s is not a tetjet-queue-snapshot.v1 file" % src.paths[0])
        return {}
    jobs = {}
    for job in data["jobs"]:
        if isinstance(job, dict):
            for key in (job.get("batch_id"), job.get("id")):
                if isinstance(key, str):
                    jobs.setdefault(key, job)
    src.detail = "generated %s" % data.get("generated_at")
    return jobs


class Batches:
    """Lazy reader of ~/lattice-batches/.registered and .analysis per batch."""

    def __init__(self, src):
        self.src = src
        self.root = src.paths[0]
        self.cache = {}
        if not self.root.is_dir():
            src.fail("missing", "%s is not a directory" % self.root)

    def get(self, batch):
        if batch in self.cache:
            return self.cache[batch]
        info = {"registered": None, "collected": None, "launched": None, "analysed": None, "refusal": None}
        if self.src.ok and re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*", batch):
            reg = self.root / ".registered" / (batch + ".json")
            if reg.is_file():
                data = load_json(reg, self.src)
                if isinstance(data, dict):
                    info["registered"] = iso_epoch(data.get("registered_utc"))
                    collection = data.get("collection") if isinstance(data.get("collection"), dict) else {}
                    info["collected"] = iso_epoch(collection.get("recorded_utc")) or iso_epoch(data.get("collected_utc"))
                    info["launched"] = iso_epoch(data.get("launched_utc"))
            current = self.root / ".analysis" / batch / "CURRENT"
            if current.is_file():
                data = load_json(current, self.src)
                if isinstance(data, dict):
                    info["analysed"] = iso_epoch(data.get("analysed_utc"))
            refused = self.root / ".analysis" / batch / "refused.json"
            if refused.is_file():
                data = load_json(refused, self.src)
                if isinstance(data, dict) and not data.get("resolved_utc"):
                    info["refusal"] = {
                        "code": data.get("code"),
                        "message": str(data.get("message") or "")[:200],
                        "since": iso_epoch(data.get("unresolved_since_utc")) or iso_epoch(data.get("refused_utc")),
                    }
        self.cache[batch] = info
        return info


def read_catalog(src):
    path = src.paths[0]
    if not path.is_file():
        src.fail("missing", "%s not found" % path)
        return {}
    try:
        conn = sqlite3.connect("file:%s?mode=ro" % path, uri=True, timeout=5)
        try:
            rows = conn.execute("SELECT batch_id, COUNT(*), MIN(started_utc) FROM runs WHERE batch_id IS NOT NULL GROUP BY batch_id").fetchall()
        finally:
            conn.close()
    except sqlite3.Error as exc:
        src.fail("unreadable", "%s: %s" % (path, exc))
        return {}
    return {row[0]: {"runs": row[1], "started": iso_epoch(row[2])} for row in rows}


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
    path = src.paths[0]
    try:
        with open(path, "rb") as stream:
            stream.seek(0, os.SEEK_END)
            size = stream.tell()
            stream.seek(max(0, size - STATUS_TAIL))
            text = stream.read().decode("utf-8", "replace")
    except FileNotFoundError:
        src.fail("missing", "%s not found" % path)
        return []
    except OSError as exc:
        src.fail("unreadable", "%s: %s" % (path, exc))
        return []
    last = {}
    for line in text.splitlines():
        match = re.match(r"(\w[\w-]*) \[key=([\w-]+)\](?: \[at=(\d+)\])?: ?(.*)", line)
        if match and match.group(2) in TETJET_KEYS:
            last[match.group(2)] = (match.group(1), int(match.group(3)) if match.group(3) else None, match.group(4))
    return [{"key": key, "since": utc(at), "line": text_}
            for key, (state, at, text_) in sorted(last.items()) if state == "blocked"]


def request_refs(record, submits_dir):
    """Request ids a package record names, through covers[] or requests[].path.

    A requests[] path counts only inside the submits folder; packages also
    name their own per-batch request copies, which are not requests.
    """
    ids = []
    for cover in record.get("covers") or []:
        if isinstance(cover, dict) and isinstance(cover.get("request_id"), str):
            ids.append(cover["request_id"])
    for ref in record.get("requests") or []:
        path = ref.get("path") if isinstance(ref, dict) else None
        if isinstance(path, str) and path.endswith(".json") and Path(path).parent == submits_dir:
            ids.append(os.path.basename(path)[:-5])
    return list(dict.fromkeys(ids))


class Loop:
    def __init__(self, home, now):
        self.home = home
        self.now = now
        self.sources, self.thresholds, self.warnings = read_config(home)
        s = self.sources
        self.submits = read_submits(s["submits"])
        self.queue = read_queue(s["handoff_queue"])
        self.acked = read_acked(s["operator_acked"])
        self.collected = read_collected(s["collected"])
        self.jobs = read_snapshot(s["snapshot"])
        self.batches = Batches(s["batches"])
        self.catalog = read_catalog(s["catalog"])
        self.holds = read_holds(s["backlog"])
        self.parks = read_parks(s["parks"])
        self.tetjet = read_tetjet_alerts(s["tetjet_status"])
        self.requests = self.join()

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
                for rid in request_refs(rec, self.sources["submits"].paths[0]):
                    req(rid)["packages"].setdefault(subject, {
                        "batch": subject, "at": at, "abandoned": abandoned.get(subject)})
        for rid, rec in self.collected.items():
            r = req(rid)
            for batch in rec.get("batches") or []:
                if isinstance(batch, dict) and isinstance(batch.get("batch_id"), str):
                    r["packages"].setdefault(batch["batch_id"], {
                        "batch": batch["batch_id"], "at": None, "abandoned": abandoned.get(batch["batch_id"])})
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
        """Sources that are unreadable, or configured and not read."""
        return [n for n, src in self.sources.items() if src.state == "unreadable" or (src.configured and not src.ok)]

    def record_alerts(self):
        """Sync durable alert records with current conditions; return open ones.

        While a source fails, no alert clears: its condition is unknown, not
        gone, so a source that comes back never re-raises what it hid.
        """
        folder = self.home / "state/loop-alerts"
        folder.mkdir(parents=True, exist_ok=True)
        current = self.conditions()
        with open(folder / ".lock", "a") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
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
                if rec is None or rec.get("cleared_at"):
                    event = "raised" if rec is None else "raised again"
                    occurrence = 1 if rec is None else rec.get("occurrence", 1) + 1
                    rec = {"schema": ALERT_SCHEMA, "id": alert_id, "condition": condition, "subject": subject,
                           "first_seen": stamp, "cleared_at": None, "acked_at": None, "occurrence": occurrence}
                    self.log(folder, "%s %s: %s; it prints until bin/fm-loop.sh ack %s" % (event, alert_id, message, alert_id))
                rec["message"] = message
                rec["last_seen"] = stamp
                records[alert_id] = rec
                atomic(folder / (alert_id + ".json"), rec)
            holding = bool(self.failing_sources())
            for alert_id, rec in records.items():
                if alert_id not in current and not rec.get("cleared_at") and not holding:
                    rec["cleared_at"] = stamp
                    atomic(folder / (alert_id + ".json"), rec)
                    note = "it prints until acked" if not rec.get("acked_at") else "already acked"
                    self.log(folder, "cleared %s: the condition no longer holds; %s" % (alert_id, note))
        self.records = records
        return sorted((r for r in records.values() if not r.get("acked_at")), key=lambda r: (r["first_seen"], r["id"]))

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
    rows = loop.open_requests() if not show_all else sorted(loop.requests.values(), key=lambda r: r["id"])
    views = [request_view(loop, r) for r in rows]
    if as_json:
        print(json.dumps({
            "schema": STATUS_SCHEMA, "generated_utc": utc(loop.now),
            "sources": {name: src.view() for name, src in loop.sources.items()},
            "thresholds_hours": loop.thresholds, "warnings": loop.warnings,
            "requests": views, "alerts": alerts, "tetjet_alerts": loop.tetjet,
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
    print("loop alerts: %s" % ("none open" if not alerts else ""))
    for a in alerts:
        print("  %s since %s%s: %s" % (a["id"], a["first_seen"], " (cleared %s)" % a["cleared_at"] if a.get("cleared_at") else "", a["message"]))
    return 0


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
    alerts never print here. Lines print before the cursor moves, so a cursor
    that cannot be written repeats a line rather than losing it.
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
                if rec.get("acked_at") or rec["condition"] == "source-unreadable":
                    continue
                if reported.get(rec["id"]) != occurrence_key(rec):
                    print(alert_line(rec))
        if broken:
            print("loop alerts: %s was unreadable; reseeded with every current alert as reported" % path)
        sys.stdout.flush()
        atomic(path, {"schema": CURSOR_SCHEMA, "updated_utc": utc(loop.now),
                      "reported": {rec["id"]: occurrence_key(rec) for rec in records}})
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
    args = parser.parse_args()
    home = Path(args.home)
    now = args.now if args.now is not None else int(datetime.datetime.now(datetime.timezone.utc).timestamp())
    if args.command == "ack":
        if not args.alert_id:
            parser.error("ack needs an alert id")
        return ack(home, now, args.alert_id)
    loop = Loop(home, now)
    if args.command == "status":
        return status(loop, args.json, args.all)
    if args.command == "alerts":
        return new_alerts_mode(loop) if args.new else alerts_mode(loop)
    return leadtime(loop, args.json, max(1, args.weeks))


if __name__ == "__main__":
    sys.exit(main())
