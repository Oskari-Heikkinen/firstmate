#!/usr/bin/env python3
"""fm-usage-report.py - the `report` readout of bin/fm-usage-report.sh.

Reads only existing records and writes nothing. bin/fm-usage-report.sh owns the
usage text and the environment that names each source; docs/disk-room.md
"Usage report" owns what the rows mean.

Each source yields items (tier, owner, kind, age, logical, allocated, path).
The first source that names a path owns it, in the order of SOURCES below, so a
tree several records describe counts once. The only filesystem calls beyond
reading the named records are one stat per raw-tree path a record names, to
tell whether that tree still stands; nothing walks a tree.
"""

import csv
import glob
import json
import os
import re
import sqlite3
import subprocess
import sys
import time
from datetime import datetime, timezone

GIB = 1 << 30
AGES = (("<1d", 1), ("1-7d", 7), ("7-30d", 30), (">30d", None))
TIERS = ("Linux", "C:", "D:")


def env(name, default=""):
    return os.environ.get(name, default)


def now():
    return int(env("FM_USAGE_NOW") or time.time())


def tier_of(path):
    if path.startswith(env("FM_USAGE_D_ROOT", "/mnt/d").rstrip("/") + "/"):
        return "D:"
    if path.startswith(env("FM_USAGE_C_ROOT", "/mnt/c").rstrip("/") + "/"):
        return "C:"
    return "Linux"


def owner_of(home, default, path=""):
    """A record's owner_home, else the home a path sits in, else DEFAULT."""
    root = os.path.join(env("HOME"), ".treehouse") + "/"
    if not home and path.startswith(root):
        home = root + "/".join(path[len(root):].split("/")[:3])
    if not home:
        return default
    if home.startswith(root):
        home = home[len(root):]
    return home.removesuffix("/firstmate")


def epoch(text):
    if text in (None, ""):
        return None
    if isinstance(text, (int, float)) or str(text).isdigit():
        return int(text)
    try:
        return int(datetime.fromisoformat(str(text).replace("Z", "+00:00")).timestamp())
    except ValueError:
        return None


def age_of(at, at_now):
    if at is None:
        return "unknown"
    days = (at_now - at) / 86400
    for label, limit in AGES:
        if limit is None or days < limit:
            return label
    return AGES[-1][0]


class Report:
    def __init__(self):
        self.items = {}
        self.sources = []
        self.at_now = now()

    def add(self, source, path, tier, owner, kind, at, logical, allocated):
        if path in self.items:
            return False
        self.items[path] = {
            "tier": tier, "owner": owner, "kind": kind, "age": age_of(at, self.at_now),
            "logical": logical, "allocated": allocated, "source": source}
        return True

    def note(self, name, path, state, records=0, counted=0):
        self.sources.append({"source": name, "path": path, "state": state,
                             "records": records, "counted": counted})


def lattice_catalogs(rep):
    config = env("FM_USAGE_LATTICE_CONFIG",
                 os.path.join(env("HOME"), ".config/lattice-data/config.json"))
    try:
        with open(config) as f:
            stores = [s["root"] for s in json.load(f).get("stores", [])]
    except (OSError, ValueError, KeyError, TypeError) as err:
        rep.note("lattice-data config", config, f"unreadable: {err.__class__.__name__}")
        return []
    for root in stores:
        path = os.path.join(root, "catalog.jsonl")
        latest = {}
        try:
            with open(path) as f:
                for line in f:
                    try:
                        rec = json.loads(line)
                    except ValueError:
                        continue
                    if isinstance(rec, dict) and rec.get("id"):
                        latest[rec["id"]] = rec
        except OSError:
            rep.note("lattice-data catalog", path, "absent")
            continue
        counted = 0
        for rec in latest.values():
            if rec.get("state") == "deleted":
                continue
            pack = rec.get("pack") or {}
            where = pack.get("image") or rec.get("path") or ""
            if not where:
                continue
            counted += rep.add("lattice-data catalog", where, tier_of(where),
                               owner_of(rec.get("owner_home"), "lattice-data"),
                               rec.get("kind") or "unknown",
                               epoch(rec.get("recorded_at")), rec.get("bytes"), None)
        rep.note("lattice-data catalog", path, "read", len(latest), counted)
    return stores


def read_tsv(path):
    with open(path, newline="") as f:
        return list(csv.DictReader(f, delimiter="\t"))


def cold_archive(rep, stores):
    for root in stores:
        manifest = os.path.join(root, "MANIFEST.tsv")
        packed = os.path.join(root, "MANIFEST.packed.tsv")
        try:
            moved = read_tsv(manifest)
        except OSError:
            continue
        try:
            packs = read_tsv(packed)
        except OSError:
            packs = []
        counted = 0
        for sidecar in sorted({p.get("unit_sidecar") for p in packs if p.get("unit_sidecar")}):
            try:
                with open(sidecar) as f:
                    unit = json.load(f)
            except (OSError, ValueError):
                continue
            image = unit.get("image") or ""
            if image:
                counted += rep.add("cold archive MANIFEST.packed.tsv", image, tier_of(image),
                                   owner_of(unit.get("owner_home"), "cold-archive"),
                                   "cold-archive-image", epoch(unit.get("verified_at")),
                                   unit.get("logical_bytes"), None)
        packed_raw = {p.get("archive_path"): p for p in packs}
        for row in moved:
            arch, orig = row.get("archive_path") or "", row.get("original_path") or ""
            owner = owner_of(row.get("owner_home"), "cold-archive")
            logical = int(row["payload_bytes"]) if (row.get("payload_bytes") or "").isdigit() else None
            at = epoch(row.get("moved_at_utc"))
            # A packed tree's raw copy stays until its removal date; stat tells.
            if arch and (arch not in packed_raw or os.path.isdir(arch)):
                counted += rep.add("cold archive MANIFEST.tsv", arch, tier_of(arch), owner,
                                   "cold-archive-tree", at, logical, None)
            if row.get("state") == "copied-not-removed" and orig:
                alloc = row.get("source_allocated_bytes") or ""
                counted += rep.add("cold archive MANIFEST.tsv", orig, tier_of(orig), owner,
                                   "cold-archive-source", at, logical,
                                   int(alloc) if alloc.isdigit() else None)
        rep.note("cold archive manifests", manifest, "read", len(moved) + len(packs), counted)


def pack_index(rep):
    path = env("FM_USAGE_PACK_INDEX")
    if not path:
        rep.note("TETJET pack index", "", "not configured")
        return
    raw_root = env("FM_USAGE_RESULTS_ROOT", "/mnt/d/lattice-data/tetjet-results")
    try:
        with open(path) as f:
            lines = f.read().splitlines()
    except OSError:
        rep.note("TETJET pack index", path, "absent")
        return
    rows = counted = 0
    for line in lines:
        cells = [c.strip() for c in line.strip().strip("|").split("|")]
        if len(cells) < 9 or not cells[3].isdigit():
            continue
        rows += 1
        unit, image, logical, verify_at, raw_alloc = cells[0], cells[1], cells[4], cells[7], cells[8]
        at = epoch(verify_at)
        counted += rep.add("TETJET pack index", image, tier_of(image), "tetjet", "tetjet-pack",
                           at, int(logical) if logical.isdigit() else None, None)
        raw = os.path.join(raw_root, unit)
        if os.path.isdir(raw):
            counted += rep.add("TETJET pack index", raw, tier_of(raw), "tetjet", "tetjet-fetch",
                               at, int(logical) if logical.isdigit() else None,
                               int(raw_alloc) if raw_alloc.isdigit() else None)
    rep.note("TETJET pack index", path, "read", rows, counted)


CENSUS = re.compile(r"^\s*\d+s (\S+): (\d+) files ([\d.]+) GiB alloc ([\d.]+) GiB\s*$")


def census(rep):
    paths = [p for p in env("FM_USAGE_CENSUS").split(":") if p]
    if not paths:
        rep.note("TETJET pack census", "", "not configured")
        return
    raw_root = env("FM_USAGE_RESULTS_ROOT", "/mnt/d/lattice-data/tetjet-results")
    for path in paths:
        try:
            with open(path) as f:
                lines = f.read().splitlines()
        except OSError:
            rep.note("TETJET pack census", path, "absent")
            continue
        rows = counted = 0
        for line in lines:
            m = CENSUS.match(line)
            if not m:
                continue
            rows += 1
            raw = os.path.join(raw_root, m.group(1))
            if os.path.isdir(raw):
                counted += rep.add("TETJET pack census", raw, tier_of(raw), "tetjet",
                                   "tetjet-fetch", None, int(float(m.group(3)) * GIB),
                                   int(float(m.group(4)) * GIB))
        rep.note("TETJET pack census", path, "read", rows, counted)


def receipts(rep):
    folder = env("FM_USAGE_RECEIPTS")
    if not folder:
        rep.note("TETJET receipts", "", "not configured")
        return
    files = sorted(glob.glob(os.path.join(folder, "*.json")))
    if not os.path.isdir(folder):
        rep.note("TETJET receipts", folder, "absent")
        return
    counted = 0
    for path in files:
        try:
            with open(path) as f:
                rec = json.load(f)
        except (OSError, ValueError):
            continue
        where = rec.get("results_path") or ""
        if not where or not os.path.exists(where):
            continue
        ver = rec.get("verification") or {}
        counted += rep.add("TETJET receipts", where, tier_of(where),
                           owner_of(rec.get("owner_home"), "tetjet", where),
                           rec.get("kind") or "unknown",
                           epoch(rec.get("recorded_at")), ver.get("bytes"), None)
    rep.note("TETJET receipts", folder, "read", len(files), counted)


def ledger_kept(rep):
    path = env("FM_USAGE_LEDGER_CATALOG",
               os.path.join(env("HOME"), "lattice-ledger/catalog.sqlite"))
    root = env("FM_USAGE_LEDGER_ROOT", os.path.dirname(path))
    if not os.path.exists(path):
        rep.note("research catalog.sqlite", path, "absent")
        return
    try:
        db = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
        rows = db.execute(
            "SELECT k.entry_id, SUM(k.bytes), MIN(r.started_utc) FROM kept k "
            "LEFT JOIN runs r ON r.entry_id = k.entry_id "
            "GROUP BY k.entry_id HAVING SUM(k.bytes) > 0").fetchall()
        db.close()
    except sqlite3.Error as err:
        rep.note("research catalog.sqlite", path, f"unreadable: {err}")
        return
    counted = 0
    for entry, total, started in rows:
        counted += rep.add("research catalog.sqlite", f"{root}#kept:{entry}", tier_of(root),
                           "research", "ledger-kept", epoch(started), total, None)
    rep.note("research catalog.sqlite", path, "read", len(rows), counted)


WINDOW = re.compile(r"([+-]?[\d.]+) GiB over ([\d.]+) days \(([+-]?[\d.]+) GiB/day\)")


def windows(text):
    out = {}
    for label, part in (("day", "last day"), ("week", "last week")):
        i = text.find(part)
        m = WINDOW.match(text, i + len(part) + 1) if i >= 0 else None
        out[label] = {"rate": float(m.group(3)), "span_days": float(m.group(2))} if m else None
    return out


def runway(rep):
    cmd = env("FM_USAGE_DISK_ROOM") or os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                                     "fm-disk-room.sh")
    tiers = {t: {"free_bytes": None, "day": None, "week": None} for t in TIERS}
    try:
        growth = subprocess.run([cmd, "growth"], capture_output=True, text=True, timeout=120).stdout
        status = json.loads(subprocess.run([cmd, "status", "--json"], capture_output=True,
                                           text=True, timeout=120).stdout or "{}")
    except (OSError, ValueError, subprocess.TimeoutExpired):
        rep.note("fm-disk-room history", cmd, "unavailable")
        return tiers
    for line in growth.splitlines():
        if line.startswith("Linux used:"):
            w, sign, free = windows(line), -1, status.get("linux_free")
        elif line.startswith("/mnt/c free:"):
            w, sign = windows(line), -1
            m = re.match(r"/mnt/c free: ([\d.]+) GiB", line)
            free = int(float(m.group(1)) * GIB) if m else None
        elif line.startswith("D: free "):
            w, sign = windows(line), 1
            m = re.match(r"D: free ([\d.]+) GiB", line)
            free = int(float(m.group(1)) * GIB) if m else None
        else:
            continue
        tier = {"L": "Linux", "/": "C:", "D": "D:"}[line[0]]
        tiers[tier]["free_bytes"] = free
        for key, val in w.items():
            if val is None:
                continue
            rate = sign * val["rate"]  # free GiB/day: used growth lowers free
            days = None if free is None or rate >= 0 else free / GIB / -rate
            tiers[tier][key] = {"free_gib_per_day": round(rate, 2), "span_days": val["span_days"],
                                "days_to_full": None if days is None else round(days, 1),
                                "full_on": None if days is None else datetime.fromtimestamp(
                                    rep.at_now + days * 86400, timezone.utc).strftime("%Y-%m-%d")}
    rep.note("fm-disk-room history", cmd, "read")
    return tiers


def gib(n):
    return "unknown" if n is None else f"{n / GIB:.2f}"


def rate_text(label, w):
    if w is None:
        return f"{label} unknown"
    text = f"{label} {w['free_gib_per_day']:+.2f} GiB/day"
    if w["days_to_full"] is None:
        return text + " not filling"
    return text + f" full in {w['days_to_full']} days ({w['full_on']})"


def main(argv):
    as_json = argv == ["--json"]
    if argv not in ([], ["--json"]):
        print(f"fm-usage-report: report: unknown argument: {argv[0]}", file=sys.stderr)
        return 2
    rep = Report()
    stores = lattice_catalogs(rep)
    cold_archive(rep, stores)
    pack_index(rep)
    census(rep)
    receipts(rep)
    ledger_kept(rep)
    tiers = runway(rep)
    groups = {}
    for it in rep.items.values():
        key = (it["tier"], it["owner"], it["kind"], it["age"])
        g = groups.setdefault(key, {"items": 0, "logical": 0, "allocated": 0,
                                    "logical_unknown": 0, "allocated_unknown": 0})
        g["items"] += 1
        for field in ("logical", "allocated"):
            if it[field] is None:
                g[f"{field}_unknown"] += 1
            else:
                g[field] += int(it[field])
    order = {t: i for i, t in enumerate(TIERS)}
    ages = {a: i for i, (a, _) in enumerate(AGES)}
    keys = sorted(groups, key=lambda k: (order[k[0]], k[1], k[2], ages.get(k[3], 99)))
    rows = []
    for k in keys:
        g = groups[k]
        rows.append({"tier": k[0], "owner": k[1], "kind": k[2], "age": k[3], "items": g["items"],
                     "logical_bytes": None if g["logical_unknown"] else g["logical"],
                     "allocated_bytes": None if g["allocated_unknown"] else g["allocated"]})
    if as_json:
        json.dump({"schema_version": "fm-usage-report/v1", "at": rep.at_now, "tiers": tiers,
                   "rows": rows, "sources": rep.sources}, sys.stdout, indent=1, sort_keys=True)
        print()
        return 0
    stamp = datetime.fromtimestamp(rep.at_now, timezone.utc).strftime("%Y-%m-%d %H:%M UTC")
    print(f"usage report at {stamp}; logical and allocated GiB from records, unknown where a record has none")
    for tier in TIERS:
        t = tiers[tier]
        free = "unknown" if t["free_bytes"] is None else f"{gib(t['free_bytes'])} GiB"
        print(f"\n{tier} free {free}; {rate_text('last day', t['day'])}; "
              f"{rate_text('last week', t['week'])}")
        mine = [r for r in rows if r["tier"] == tier]
        if not mine:
            print("  no recorded items")
            continue
        print(f"  {'owner':<22} {'kind':<22} {'age':<7} {'items':>6} {'logical':>10} {'allocated':>10}")
        for r in mine:
            print(f"  {r['owner']:<22} {r['kind']:<22} {r['age']:<7} {r['items']:>6} "
                  f"{gib(r['logical_bytes']):>10} {gib(r['allocated_bytes']):>10}")
    print("\nsources:")
    for s in rep.sources:
        where = f" {s['path']}" if s["path"] else ""
        extra = f", {s['records']} records, {s['counted']} counted" if s["state"] == "read" and s["records"] else ""
        print(f"  {s['source']}: {s['state']}{where}{extra}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
