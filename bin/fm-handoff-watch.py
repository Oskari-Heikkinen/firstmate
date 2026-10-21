#!/usr/bin/env python3
"""fm-handoff-watch.py - one pass of the registry-driven handoff coverage watcher.

Driven by bin/fm-handoff-watch.sh, whose header owns usage, arming and the run
cap. docs/handoff-coverage.md owns the formats, the checks and the routing this
file implements; this file owns how one pass reads them and turns findings
into alert-store levels.

A pass reads every handoff-registry/v1 fragment on the homes this machine
sees, evaluates the stages this home owns, the dated rules of the protocols it
owns and the heartbeats it watches, then makes each target's alert store equal
the alarms it wants there. Its only writes are under <home>/state/handoff-watch/,
the heartbeat receipt, and in each target home the store registration and an
empty handoff-watch.status when that file is missing.
"""
import argparse
import datetime
import fcntl
import fnmatch
import hashlib
import json
import os
from pathlib import Path
import re
import secrets
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import fm_handoff_registry as registry  # noqa: E402
from fm_receipt_io import atomic  # noqa: E402

HERE = Path(__file__).resolve().parent
WATCH_PROTOCOL = "handoff-watch"
TOOLING = "tooling-mate"
MAIN = "main"
REFUSAL_TO_MAIN = 4 * 3600
UNCOVERED_TO_MAIN = 3600
RESCAN = 300
DATED_STEPS = ((14, "d14"), (7, "d7"), (1, "d1"))
ACK_MAX = 604800
STATE_SCHEMA = "fm-handoff-watch-state/v1"
REG_SCHEMA = "fm-alert-registration/v1"
STORE_SCHEMA = "fm-alert-store/v1"
UNSAFE_RE = re.compile(r"[^A-Za-z0-9._-]+")


def iso(epoch):
    return datetime.datetime.fromtimestamp(epoch, datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def name_epoch(name):
    """The written_at epoch encoded in a receipt file name, else None."""
    try:
        stamp = datetime.datetime.strptime(name[:23], "%Y%m%dT%H%M%S.%fZ")
    except ValueError:
        return None
    return stamp.replace(tzinfo=datetime.timezone.utc).timestamp()


def name_at(epoch):
    return datetime.datetime.fromtimestamp(epoch, datetime.timezone.utc).strftime("%Y%m%dT%H%M%S.%fZ")


def alert_key(kind, subject, variant=""):
    """hw-<kind>-<subject slug>[-<variant>]: stable per check and subject, at most 128 characters."""
    slug = UNSAFE_RE.sub("-", subject.replace("/", "-")).strip("-.")
    key = f"hw-{kind}-{slug}" + (f"-{variant}" if variant else "")
    lossy = UNSAFE_RE.sub("", subject.replace("/", "")) != subject.replace("/", "")
    if lossy or len(key) > 128:
        digest = hashlib.sha1(f"{kind}\0{subject}\0{variant}".encode()).hexdigest()[:12]
        key = key[:115].rstrip("-.") + "-" + digest
    return key


def read_json(path):
    try:
        with open(path, encoding="utf-8") as handle:
            return json.load(handle)
    except (OSError, ValueError):
        return None


class Watch:
    def __init__(self, home, root, now):
        self.now = now
        self.self_id, self.homes = registry.discover(home, root)
        self.home = self.homes[self.self_id]
        self.dir = self.home / "state/handoff-watch"
        self.alarms = {}
        self.incomplete = set()
        self.notes = []
        self.validate = registry.validator()
        schemas = HERE.parent / "docs/handoff-coverage"
        self.fragment_schema = self.validate.Schema(str(schemas / "handoff-registry-v1.schema.json"))
        self.receipt_schema = self.validate.Schema(str(schemas / "handoff-receipt-v1.schema.json"))
        interval = int(os.environ.get("FM_CHECK_INTERVAL") or 300)
        self.silent_after = int(os.environ.get("FM_HANDOFF_WATCH_SILENT_AFTER") or 2 * interval)

    # ---------- alarms ----------

    def alarm(self, scope, kind, subject, reason, targets, since, evidence=None,
              main_after=None, ack_closes=False, variant="", uncovered=False):
        key = alert_key(kind, subject, variant)
        entry = self.alarms.get(key)
        if entry:
            entry["targets"] = sorted(set(entry["targets"]) | set(targets))
            return
        self.alarms[key] = {
            "scope": scope, "kind": kind, "subject": subject, "reason": " ".join(str(reason).split())[:400],
            "targets": sorted(set(t for t in targets if t)), "since": since,
            "evidence": {"path": str(evidence)} if evidence else {},
            "main_after": main_after, "ack_closes": ack_closes, "uncovered": uncovered,
        }

    def unreadable(self, scope, path, why, owner=None):
        self.incomplete.add(scope)
        self.alarm(scope, "source-unreadable", str(path), f"{path} {why}", [owner or self.self_id], self.now, path)

    # ---------- fragments ----------

    def load_registry(self):
        cache_path = self.dir / "fragments.json"
        cache = read_json(cache_path) or {}
        files = cache.get("files", {}) if cache.get("schema") == STATE_SCHEMA else {}
        kept = {}
        for hid, hpath in sorted(self.homes.items()):
            try:
                paths = registry.fragment_files(hpath)
            except OSError as exc:
                if hid == self.self_id:
                    self.unreadable("fragments", hpath / "state/handoff-registry", f"cannot be listed ({exc.strerror})")
                kept.update({k: v for k, v in files.items() if v.get("home") == hid})
                continue
            for path in paths:
                key = str(path)
                old = files.get(key, {})
                try:
                    st = os.stat(path)
                    sig = [st.st_mtime_ns, st.st_size]
                except OSError as exc:
                    sig, doc, problem = None, None, f"cannot be read ({exc.strerror})"
                else:
                    if old.get("sig") == sig:
                        kept[key] = old
                        self.fragment_alarm(hid, path, old.get("problem"))
                        continue
                    doc, problem = registry.check_fragment(self.validate, self.fragment_schema, path)
                entry = {"home": hid, "sig": sig, "problem": problem, "doc": old.get("doc")}
                if doc is not None:
                    last = old.get("doc")
                    if last and last.get("revision", 0) > doc.get("revision", 0):
                        entry["problem"] = (f"went back to revision {doc.get('revision')} after "
                                            f"{last.get('revision')}; the higher revision is kept")
                    else:
                        entry["doc"] = doc
                elif problem is None:
                    entry["doc"] = None  # an example fragment
                kept[key] = entry
                self.fragment_alarm(hid, path, entry["problem"])
        atomic(cache_path, {"schema": STATE_SCHEMA, "files": kept})
        self.protocols = {}
        declared = {}
        for key in sorted(kept, key=lambda k: (kept[k]["home"], k)):
            doc = kept[key].get("doc")
            for proto in (doc or {}).get("protocols", []):
                pid = proto["id"]
                if pid in self.protocols:
                    first_home, first_path = declared[pid]
                    if self.self_id in (first_home, kept[key]["home"]):
                        self.alarm("fragments", "source-unreadable", f"protocol {pid}",
                                   f"protocol {pid} is declared in both {first_path} and {key}; the first is used",
                                   [TOOLING, first_home, kept[key]["home"]], self.now, key, variant="duplicate")
                    continue
                self.protocols[pid] = proto
                declared[pid] = (kept[key]["home"], key)
        self.record_types = {t for proto in self.protocols.values() for t in proto.get("record_types", [])}

    def fragment_alarm(self, hid, path, problem):
        if problem and hid == self.self_id:
            self.alarm("fragments", "source-unreadable", str(path),
                       f"fragment {path} {problem}; the last valid revision stays in use", [self.self_id], self.now, path)

    # ---------- stages ----------

    def stage_state(self, pid, sname):
        path = self.dir / "stages" / f"{pid}--{sname}.json"
        doc = read_json(path)
        if not isinstance(doc, dict) or doc.get("schema") != STATE_SCHEMA:
            doc = {"schema": STATE_SCHEMA}
        doc.setdefault("outbox", {})
        doc.setdefault("place", {})
        doc.setdefault("records", {})
        doc.setdefault("answered", {})
        return path, doc

    def sync_stamp(self, scope, folder, reach):
        if reach.get("kind") != "synced":
            return
        stamp = Path(folder) / ".synced-at"
        try:
            text = stamp.read_text(encoding="utf-8").strip()
        except (OSError, UnicodeDecodeError) as exc:
            self.unreadable(scope, stamp, f"cannot be read ({getattr(exc, 'strerror', None) or exc})")
            return
        at = self.validate.parse_utc(text)
        if at is None:
            self.unreadable(scope, stamp, f"does not hold a UTC time ({text[:40]!r})")
            return
        lag = self.validate.seconds(reach.get("max_lag"))
        if lag is not None and self.now - at.timestamp() > lag:
            self.alarm(scope, "sync-stale", str(folder), f"{folder} was last synced at {text}, more than {reach['max_lag']} ago "
                       f"(from {reach.get('source')})", [self.self_id], at.timestamp(), stamp)

    def stage(self, proto, sindex):
        stage = proto["stages"][sindex]
        pid, sname = proto["id"], stage["name"]
        scope = f"stage:{pid}/{sname}"
        planned = bool(stage.get("planned"))
        path, st = self.stage_state(pid, sname)
        for which in ("input", "outbox"):
            place = stage[which]
            if not planned or os.path.isdir(place["path"]):
                self.sync_stamp(scope, place["path"], place["reach"])
        self.read_outbox(proto, stage, scope, st, planned)
        self.read_place(stage, scope, st, planned)
        self.judge(proto, sindex, scope, st)
        atomic(path, st)

    def read_outbox(self, proto, stage, scope, st, planned):
        folder = stage["outbox"]["path"]
        ob = st["outbox"]
        if ob.get("path") != folder:
            ob.clear()
            ob.update({"path": folder, "seen": [], "bad": {}})
        try:
            sig = os.stat(folder).st_mtime_ns
            if sig == ob.get("sig"):
                return
            names = sorted(n for n in os.listdir(folder) if not n.startswith("."))
        except OSError as exc:
            if not planned:
                self.unreadable(scope, folder, f"cannot be listed ({exc.strerror})")
            return
        present = set(names)
        ob["bad"] = {n: v for n, v in ob.get("bad", {}).items() if n in present}
        seen = set(ob.get("seen", []))
        cursor = ob.get("cursor") or ""
        # A synced copy can deliver a receipt up to max_lag after it was written.
        window = RESCAN + (self.validate.seconds(stage["outbox"]["reach"].get("max_lag")) or 0)
        floor = name_at(name_epoch(cursor) - window) if name_epoch(cursor) else ""
        retry = False
        for name in names:
            if name < floor or name in seen:
                continue
            if self.receipt(proto, stage, st, folder, name) is False:
                retry = True
                continue
            seen.add(name)
            if self.validate.RECEIPT_NAME_RE.match(name) and name > cursor:
                cursor = name
        floor = name_at(name_epoch(cursor) - window) if name_epoch(cursor) else ""
        ob["seen"] = sorted(n for n in seen if n >= floor and n in present)
        ob["cursor"] = cursor
        if retry:
            self.incomplete.add(scope)
        else:
            ob["sig"] = sig

    def receipt(self, proto, stage, st, folder, name):
        """Fold one outbox entry into the stage state; False when it should be read again next pass."""
        path = os.path.join(folder, name)
        bad = st["outbox"]["bad"]
        match = self.validate.RECEIPT_NAME_RE.match(name)
        if not match or not os.path.isfile(path):
            bad[name] = ["unregistered-receipt", "is not a receipt file name; an outbox holds only receipts", None]
            return True
        try:
            doc, problem = self.validate.load_json(path)
        except self.validate.Unreadable:
            return False
        if problem:
            bad[name] = ["source-unreadable", problem, None]
            return True
        if not isinstance(doc, dict) or doc.get("format") != self.validate.RECEIPT_FORMAT:
            fmt = doc.get("format") if isinstance(doc, dict) else None
            bad[name] = ["source-unreadable", f"has unknown format {fmt!r}", None]
            return True
        writer = doc.get("home") if isinstance(doc.get("home"), str) and registry.HOME_ID_RE.match(doc.get("home")) else None
        problems = self.receipt_schema.errors(doc) or self.validate.receipt_problems(doc, self.protocols)
        if not problems:
            stamp = doc["written_at"].replace("-", "").replace(":", "")
            if match.group(1) != stamp or match.group(2) != doc["receipt_id"]:
                problems = [("/", f"file name must be {stamp}-{doc['receipt_id']}.json")]
            elif (doc["protocol"], doc["stage"]) != (proto["id"], stage["name"]):
                problems = [("/stage", f"a receipt of {doc['protocol']}/{doc['stage']} sits in the outbox of "
                             f"{proto['id']}/{stage['name']}")]
        if problems:
            where, what = problems[0]
            bad[name] = ["unregistered-receipt", f"at {where}: {what}", writer]
            return True
        rec = st["records"].setdefault(doc["record"], {"pairs": []})
        pair = f"{doc['attempt']}.{doc['seq']}"
        if pair in rec["pairs"]:
            bad[name] = ["unregistered-receipt", f"repeats attempt {doc['attempt']} seq {doc['seq']} of record "
                         f"{doc['record']}, which an earlier receipt already used", writer]
            return True
        rec["pairs"].append(pair)
        st["answered"][doc.get("input") or f"{doc['record']}.json"] = name_epoch(name)
        cur = rec.get("cur")
        if cur is None or (doc["attempt"], doc["seq"]) > (cur["attempt"], cur["seq"]):
            rec["cur"] = {k: doc.get(k) for k in ("state", "code", "attempt", "seq", "holds_all", "stops", "detail",
                                                    "sender", "until", "evidence")}
            rec["cur"]["name"] = name
            rec["cur"]["at"] = name_epoch(name)
        return True

    def read_place(self, stage, scope, st, planned):
        place = stage["input"]
        pl = st["place"]
        if pl.get("path") != place["path"] or pl.get("match") != place.get("match") \
                or pl.get("type_field") != place.get("type_field"):
            pl.clear()
            pl.update({"path": place["path"], "match": place.get("match"), "type_field": place.get("type_field"),
                       "entries": {}})
        try:
            sig = os.stat(place["path"]).st_mtime_ns
            if sig == pl.get("sig"):
                return
            names = [n for n in os.listdir(place["path"]) if not n.startswith(".")
                     and fnmatch.fnmatchcase(n, place.get("match") or "*")]
        except OSError as exc:
            if not planned:
                self.unreadable(scope, place["path"], f"cannot be listed ({exc.strerror})")
            return
        old = pl["entries"]
        entries = {}
        for name in names:
            if name in old:
                entries[name] = old[name]
                continue
            path = os.path.join(place["path"], name)
            try:
                mtime = os.lstat(path).st_mtime
            except OSError:
                continue
            entries[name] = [mtime, None, None]
            field = place.get("type_field")
            if field:
                doc = read_json(path)
                if not isinstance(doc, dict):
                    entries[name][1:] = ["source-unreadable", "is not a readable JSON object"]
                elif doc.get(field) not in self.record_types:
                    entries[name][1:] = ["unregistered-type", f"has {field} {doc.get(field)!r}, which no protocol "
                                         "lists in record_types"]
        pl["entries"] = entries
        pl["sig"] = sig

    def judge(self, proto, sindex, scope, st):
        stage = proto["stages"][sindex]
        pid, sname, owner = proto["id"], stage["name"], stage["owner"]
        bounds = {k: self.validate.seconds(v) for k, v in stage["bounds"].items()}
        outbox, place = stage["outbox"]["path"], stage["input"]["path"]
        for name, (kind, why, writer) in st["outbox"]["bad"].items():
            path = os.path.join(outbox, name)
            if kind == "source-unreadable":
                self.alarm(scope, kind, f"{pid}/{sname}/{name}", f"receipt {path} {why}", [owner], self.now, path)
            else:
                self.alarm(scope, kind, f"{pid}/{sname}/{name}", f"receipt {path} {why}", [writer or owner, TOOLING],
                           self.now, path, main_after=UNCOVERED_TO_MAIN, uncovered=True)
        for name, (mtime, kind, why) in st["place"].get("entries", {}).items():
            path = os.path.join(place, name)
            if kind == "source-unreadable":
                self.alarm(scope, kind, f"{pid}/{sname}/{name}", f"record {path} {why}", [owner], mtime, path)
            elif kind:
                self.alarm(scope, kind, f"{pid}/{sname}/{name}", f"record {path} {why}", [TOOLING, owner], mtime, path,
                           main_after=UNCOVERED_TO_MAIN, uncovered=True)
            if not stage.get("planned") and name not in st["answered"] and bounds["accepted"] is not None \
                    and self.now - mtime > bounds["accepted"]:
                self.alarm(scope, "no-receipt", f"{pid}/{sname}/{name}",
                           f"{path} has waited past the {stage['bounds']['accepted']} accepted bound with no "
                           f"receipt from {sname}", [owner], mtime, path)
        keep = self.validate.seconds(proto["cleanup"]["receipts_after"]) or 0
        entries = st["place"].get("entries", {})
        st["answered"] = {n: at for n, at in st["answered"].items() if n in entries or self.now - (at or 0) <= keep}
        prev_owner = proto["stages"][sindex - 1]["owner"] if sindex > 0 else None
        for record, rec in list(st["records"].items()):
            cur = rec.get("cur")
            if cur is None:
                continue
            if cur["state"] == "done":
                if self.now - cur["at"] > keep:
                    del st["records"][record]
                continue
            subject = f"{pid}/{sname}/{record}"
            evidence = os.path.join(outbox, cur["name"])
            senders = [cur["sender"]] if cur.get("sender") else [prev_owner] if prev_owner else proto["senders"]
            entry = self.validate.code_entry(stage, cur["code"]) if cur.get("code") else None
            fix = entry["fix_owner"] if entry else owner
            detail = cur.get("detail")
            if cur["state"] in ("refused", "held"):
                if cur["code"] in self.validate.RESERVED_CODES:
                    targets = senders + [proto["owner"]]
                else:
                    targets = [fix] + senders
                self.alarm(scope, cur["state"], subject, detail or f"{subject} is {cur['state']} with code {cur['code']}",
                           targets, cur["at"], evidence, main_after=REFUSAL_TO_MAIN, ack_closes=True)
                if cur.get("holds_all"):
                    self.alarm(scope, "lane-fault", subject, f"{cur['code']} stops {cur.get('stops')}", [MAIN],
                               cur["at"], evidence)
            late = None
            if cur["state"] == "held" and bounds["held"] is not None and self.now - cur["at"] > bounds["held"]:
                late = (f"held past its {stage['bounds']['held']} bound", fix)
            elif cur["state"] == "accepted" and bounds["accepted"] is not None and self.now - cur["at"] > bounds["accepted"]:
                late = (f"accepted past its {stage['bounds']['accepted']} bound", owner)
            elif cur["state"] == "waiting":
                until = self.validate.parse_utc(cur.get("until") or "")
                if until is not None and self.now > until.timestamp():
                    late = (f"waiting past its until {cur['until']}", owner)
            if late:
                self.alarm(scope, "open-past-bound", subject, f"{subject} is {late[0]}" + (f": {detail}" if detail else ""),
                           [late[1]], cur["at"], evidence, main_after=REFUSAL_TO_MAIN)
            if cur["attempt"] - 1 > stage["retry_limit"]:
                self.alarm(scope, "open-past-bound", subject, f"{subject} is on attempt {cur['attempt']}, past its retry "
                           f"limit {stage['retry_limit']}", [fix], cur["at"], evidence,
                           main_after=REFUSAL_TO_MAIN, variant="retries")

    # ---------- dated rules ----------

    def dated_rules(self):
        today = datetime.datetime.fromtimestamp(self.now, datetime.timezone.utc).date()
        for pid, proto in sorted(self.protocols.items()):
            if proto["owner"] != self.self_id:
                continue
            for rule in proto.get("dated_rules", []):
                try:
                    date = datetime.date.fromisoformat(rule["date"])
                except ValueError:
                    continue
                days = (date - today).days
                step = "due" if days <= 0 else next((tag for limit, tag in reversed(DATED_STEPS) if days <= limit), None)
                if step is None:
                    continue
                start = date - datetime.timedelta(days=0 if step == "due" else int(step[1:]))
                since = datetime.datetime.combine(start, datetime.time(), datetime.timezone.utc).timestamp()
                when = "took effect" if days <= 0 else f"takes effect in {days} day{'s' if days != 1 else ''}"
                self.alarm(f"dated:{pid}", "dated-rule", f"{pid}/{rule['id']}",
                           f"{pid} rule {rule['id']} {when} on {rule['date']}: {rule['what']}", [rule["owner"]],
                           min(since, self.now), variant=step)

    # ---------- heartbeat ----------

    def heartbeat_dir(self, home):
        return Path(home) / "state/handoff-watch/heartbeat"

    def beat(self):
        folder = self.heartbeat_dir(self.home)
        (folder / ".tmp").mkdir(parents=True, exist_ok=True)
        stamp = datetime.datetime.fromtimestamp(self.now, datetime.timezone.utc)
        receipt_id = secrets.token_hex(8)
        doc = {"format": "handoff-receipt/v1", "receipt_id": receipt_id,
               "written_at": stamp.strftime("%Y-%m-%dT%H:%M:%S.%fZ"), "protocol": WATCH_PROTOCOL, "version": 0,
               "stage": self.self_id, "home": self.self_id, "record": self.self_id, "attempt": 1,
               "seq": max(1, int(self.now)), "state": "done", "detail": "fm-handoff-watch finished a pass"}
        name = f"{stamp.strftime('%Y%m%dT%H%M%S.%fZ')}-{receipt_id}.json"
        atomic(folder / ".tmp" / name, doc)
        os.replace(folder / ".tmp" / name, folder / name)
        for old in os.listdir(folder):
            if old != name and self.validate.RECEIPT_NAME_RE.match(old):
                try:
                    os.unlink(folder / old)
                except OSError:
                    pass

    def silence(self):
        if self.self_id == MAIN:
            watched = [(hid, path, "") for hid, path in self.homes.items() if hid != MAIN]
        elif MAIN in self.homes:
            watched = [(MAIN, self.homes[MAIN], f"seen-by-{self.self_id}")]
        else:
            watched = []
        for hid, path, variant in sorted(watched):
            folder = self.heartbeat_dir(path)
            if not folder.is_dir():
                continue
            try:
                stamps = [name_epoch(n) for n in os.listdir(folder) if self.validate.RECEIPT_NAME_RE.match(n)]
            except OSError:
                stamps = []
            last = max((s for s in stamps if s), default=None)
            if last is None or self.now - last > self.silent_after:
                seen = f"its last heartbeat was at {iso(last)}" if last else "it has no heartbeat"
                self.alarm(f"heartbeat:{hid}", "watcher-silent", hid,
                           f"the handoff watcher of {hid} is silent: {seen}, more than {self.silent_after} s ago",
                           [MAIN], last or self.now, folder, variant=variant)

    # ---------- delivery ----------

    def store_path(self, target):
        return self.dir / "stores" / f"{target}.json"

    @property
    def store_id(self):
        return f"handoff-watch.{self.self_id}"

    def acked(self, key, stores):
        for doc in stores.values():
            ack = ((doc or {}).get("acks") or {}).get(key)
            if not isinstance(ack, dict):
                continue
            try:
                at = datetime.datetime.fromisoformat(str(ack.get("at")).replace("Z", "+00:00")).timestamp()
                until = datetime.datetime.fromisoformat(str(ack.get("until")).replace("Z", "+00:00")).timestamp()
            except ValueError:
                continue
            if at <= self.now < until and until - at <= ACK_MAX:
                return True
        return False

    def deliver(self):
        state_path = self.dir / "alarms.json"
        prev = read_json(state_path)
        prev = prev.get("alarms", {}) if isinstance(prev, dict) and prev.get("schema") == STATE_SCHEMA else {}
        for key, old in prev.items():
            if key not in self.alarms and old.get("scope") in self.incomplete:
                self.alarms[key] = {k: v for k, v in old.items() if k not in ("first_seen", "routed")}
        stores_dir = self.dir / "stores"
        stores_dir.mkdir(parents=True, exist_ok=True)
        stores = {p.stem: read_json(p) for p in stores_dir.glob("*.json")}
        wanted = {}
        undeliverable = []
        for key, alarm in sorted(self.alarms.items()):
            first = prev.get(key, {}).get("first_seen", self.now)
            alarm["first_seen"] = first
            base = first if alarm["uncovered"] else alarm["since"]
            targets = set(alarm["targets"])
            if alarm["main_after"] is not None and self.now - base >= alarm["main_after"] \
                    and not (alarm["ack_closes"] and self.acked(key, stores)):
                targets.add(MAIN)
            routed = set()
            for target in sorted(targets):
                note = ""
                if target not in self.homes:
                    if MAIN not in self.homes:
                        undeliverable.append(f"handoff-watch: alarm {key} for {target} cannot be delivered: "
                                             f"neither {target} nor main is a home this machine sees")
                        continue
                    note = f"(for {target}, whose home this machine does not see) "
                    target = MAIN
                routed.add(target)
                wanted.setdefault(target, {})[key] = {
                    "kind": alarm["kind"], "subject": alarm["subject"], "reason": note + alarm["reason"],
                    "since": iso(alarm["since"]), "evidence": alarm["evidence"]}
            alarm["routed"] = sorted(routed)
        log = []
        for target in sorted(set(wanted) | set(stores)):
            want = wanted.get(target, {})
            current = stores.get(target)
            active = (current or {}).get("active") if isinstance(current, dict) else None
            if current is None and not want and not self.store_path(target).exists():
                continue
            same = isinstance(active, dict) and set(active) == set(want) and all(
                active[k].get("reason") == v["reason"] and active[k].get("evidence") == v["evidence"]
                for k, v in want.items())
            if not same:
                problem = self.sync_store(target, want)
                if problem:
                    undeliverable.append(problem)
                    continue
                old = set(active or {})
                log += [f"raised {k} for {target}: {want[k]['reason']}" for k in sorted(set(want) - old)]
                log += [f"cleared {k} for {target}" for k in sorted(old - set(want))]
            if target in self.homes:
                problem = self.register(target)
                if problem:
                    undeliverable.append(problem)
        atomic(state_path, {"schema": STATE_SCHEMA, "alarms": self.alarms})
        if log:
            with open(self.dir / "log", "a", encoding="utf-8") as handle:
                for line in log:
                    handle.write(f"{iso(self.now)} {line}\n")
        self.report(undeliverable)

    def sync_store(self, target, want):
        tmp = self.dir / f".wanted-{target}.json"
        atomic(tmp, want)
        try:
            run = subprocess.run(
                [str(HERE / "fm-alert-store.sh"), "sync", str(self.store_path(target)), self.store_id, str(tmp),
                 f"the condition is gone (fm-handoff-watch of {self.self_id})"],
                env={**os.environ, "FM_HOME": str(self.home), "FM_STATE_OVERRIDE": str(self.home / "state")},
                capture_output=True, text=True, timeout=30)
        except (OSError, subprocess.TimeoutExpired) as exc:
            return f"handoff-watch: store for {target} could not be written: {exc}"
        finally:
            tmp.unlink(missing_ok=True)
        if run.returncode != 0:
            return f"handoff-watch: store for {target} could not be written: {run.stderr.strip()[:200]}"
        return None

    def register(self, target):
        state = self.homes[target] / "state"
        reg = state / "alert-stores" / f"{self.store_id}.reg"
        text = (f"schema={REG_SCHEMA}\nstore={self.store_id}\npath={self.store_path(target)}\n"
                f"status=handoff-watch.status\nowner={self.self_id} fm-handoff-watch\n")
        try:
            if not state.is_dir():
                return f"handoff-watch: alarms for {target} cannot be delivered: {state} does not exist"
            status = state / "handoff-watch.status"
            if not status.exists():
                status.touch()
            if not reg.is_file() or reg.read_text(encoding="utf-8") != text:
                reg.parent.mkdir(exist_ok=True)
                tmp = reg.parent / f".{reg.name}.{os.getpid()}"
                tmp.write_text(text, encoding="utf-8")
                os.replace(tmp, reg)
        except OSError as exc:
            return f"handoff-watch: alarms for {target} cannot be delivered: {reg}: {exc.strerror}"
        return None

    def report(self, lines):
        """Print each undeliverable line once per occurrence; the watcher wakes on stdout."""
        path = self.dir / "undeliverable"
        try:
            old = set(path.read_text(encoding="utf-8").splitlines())
        except OSError:
            old = set()
        for line in lines:
            if line not in old:
                print(line)
        if lines:
            path.write_text("".join(f"{line}\n" for line in lines), encoding="utf-8")
        else:
            path.unlink(missing_ok=True)

    # ---------- pass ----------

    def tick(self):
        self.dir.mkdir(parents=True, exist_ok=True)
        with open(self.dir / ".lock", "w") as lock:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except OSError:
                return 0
            self.load_registry()
            for pid, proto in sorted(self.protocols.items()):
                if pid == WATCH_PROTOCOL:
                    continue
                for sindex, stage in enumerate(proto["stages"]):
                    if stage["owner"] == self.self_id:
                        self.stage(proto, sindex)
            self.dated_rules()
            self.silence()
            self.deliver()
            self.beat()
        return 0

    def release(self):
        """Unregister this watcher's stores from every home it can see and drop its heartbeat."""
        rc = 0
        stores_dir = self.dir / "stores"
        targets = sorted(p.stem for p in stores_dir.glob("*.json")) if stores_dir.is_dir() else []
        for target in targets:
            if target not in self.homes:
                continue
            run = subprocess.run([str(HERE / "fm-alert-store.sh"), "unregister", self.store_id],
                                 env={k: v for k, v in os.environ.items() if k not in ("FM_STATE_OVERRIDE", "FM_ROOT_OVERRIDE", "FM_CONFIG_OVERRIDE")}
                                 | {"FM_HOME": str(self.homes[target])}, capture_output=True, text=True)
            if run.returncode != 0:
                print(f"could not unregister {self.store_id} in {target}: {run.stderr.strip()}", file=sys.stderr)
                rc = 1
        folder = self.heartbeat_dir(self.home)
        if folder.is_dir():
            for name in os.listdir(folder):
                if self.validate.RECEIPT_NAME_RE.match(name):
                    (folder / name).unlink(missing_ok=True)
            for sub in (folder / ".tmp", folder):
                try:
                    sub.rmdir()
                except OSError:
                    pass
        return rc


def main(argv):
    parser = argparse.ArgumentParser(prog="fm-handoff-watch.py")
    parser.add_argument("command", choices=("tick", "release"))
    parser.add_argument("--home", required=True)
    parser.add_argument("--root")
    parser.add_argument("--now", type=int)
    args = parser.parse_args(argv)
    now = args.now if args.now is not None else int(datetime.datetime.now(datetime.timezone.utc).timestamp())
    try:
        watch = Watch(args.home, args.root, now)
    except (ValueError, OSError) as exc:
        print(f"fm-handoff-watch: {exc}", file=sys.stderr)
        return 1
    return watch.tick() if args.command == "tick" else watch.release()


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
