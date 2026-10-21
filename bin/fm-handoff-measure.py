#!/usr/bin/env python3
"""fm-handoff-measure.py - time to notice and the weekly coverage line.

Usage:
  fm-handoff-measure.py notice   --home DIR [--root DIR] [--since TIME] [--until TIME] [--now EPOCH] [--json]
  fm-handoff-measure.py coverage --home DIR [--root DIR] [--now EPOCH] [--json]

docs/handoff-coverage.md ("Measurement") owns what is measured, the targets
and the weekly line; this file owns how one call reads the records. It only
reads: the handoff watchers' alert stores registered in the home, the home's
state/alert-stores.log, the watcher's fragment cache and per-stage state under
state/handoff-watch/, and the actor inventory of bin/fm-handoff-actors.py.

notice     prints, for every handoff-watch alarm raised for the home between
           --since and --until (default: the last 7 days), its time to
           notice: from the event (the alert entry's since, the receipt or
           record time) to its delivery, the home's alert-store tick
           re-posting it as a blocked line, against the entry's deliver_by,
           then one summary line per check kind.
coverage   prints the coverage line for the 7 days before --now: protocols
           the home owns, the stages it owns with and without receipts in
           that week (a stage idle beyond 7 days says when its last receipt
           was), the undeclared actors, and the week's time-to-notice summary.

The watcher's weekly pass (bin/fm-handoff-watch.py) prints the same line on
its own; this command is the on-demand view. TIME is an epoch or a UTC ISO
8601 time. --root DIR is the drill root fm-handoff-watch uses. Runs under
nice 19 and idle I/O.

Exit: 0 every judged alarm met its target (coverage: and no stage is idle and
no actor is undeclared); 1 an alarm missed its target or was not delivered
(coverage: or a stage is idle or an actor undeclared); 2 usage; 3 a record
could not be read, so the result is incomplete (it still prints).
"""
import argparse
import datetime
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import fm_handoff_registry as registry  # noqa: E402

WEEK = 7 * 86400
STORE_PREFIX = "handoff-watch."
WATCH_PROTOCOL = "handoff-watch"
STATE_SCHEMA = "fm-handoff-watch-state/v1"
STORE_SCHEMAS = ("fm-alert-store/v1",)
REPOST_RE = re.compile(r"^(\S+) re-posted alert (\S+) from store (\S+) to \S+$")
# A judged alarm's outcome; the first two met their target, the rest did not or are not judged yet.
MET, MISSED, UNDELIVERED, PENDING, CLEARED, UNJUDGED = (
    "met", "missed", "undelivered", "pending", "cleared before delivery", "no target")


def iso(epoch):
    return datetime.datetime.fromtimestamp(epoch, datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def epoch_of(text):
    try:
        return datetime.datetime.fromisoformat(str(text).replace("Z", "+00:00")).timestamp()
    except ValueError:
        return None


def span(seconds):
    """A short duration: 45s, 4m10s, 2h03m, 3d04h."""
    seconds = int(round(seconds))
    sign = "-" if seconds < 0 else ""
    seconds = abs(seconds)
    if seconds < 60:
        return f"{sign}{seconds}s"
    if seconds < 3600:
        return f"{sign}{seconds // 60}m{seconds % 60:02d}s"
    if seconds < 86400:
        return f"{sign}{seconds // 3600}h{seconds % 3600 // 60:02d}m"
    return f"{sign}{seconds // 86400}d{seconds % 86400 // 3600:02d}h"


def read_json(path):
    try:
        with open(path, encoding="utf-8") as handle:
            return json.load(handle)
    except (OSError, ValueError):
        return None


# ---------- delivery and raises ----------

def deliveries(log, offset=0):
    """Re-posts in <home>/state/alert-stores.log from byte offset on.

    Returns ({(store, key): [epoch, ...]}, (inode, end offset)); a log that was
    replaced or shrank since offset is read from its start.
    """
    out = {}
    try:
        with open(log, "rb") as handle:
            st = os.fstat(handle.fileno())
            if offset > st.st_size:
                offset = 0
            handle.seek(offset)
            data = handle.read()
    except FileNotFoundError:
        return out, (None, 0)
    for line in data.decode("utf-8", "replace").splitlines():
        match = REPOST_RE.match(line)
        if match:
            at = epoch_of(match.group(1))
            if at is not None:
                out.setdefault((match.group(3), match.group(2)), []).append(at)
    return out, (st.st_ino, offset + len(data))


def stores(home):
    """(store id, store doc or None, path, problem) for each handoff-watch registration in the home."""
    folder = Path(home) / "state/alert-stores"
    try:
        names = sorted(n for n in os.listdir(folder) if n.startswith(STORE_PREFIX) and n.endswith(".reg"))
    except FileNotFoundError:
        return []
    except OSError as exc:
        return [(None, None, str(folder), f"cannot be listed ({exc.strerror})")]
    out = []
    for name in names:
        reg = folder / name
        try:
            fields = dict(line.partition("=")[::2] for line in reg.read_text(encoding="utf-8").splitlines() if "=" in line)
        except (OSError, UnicodeDecodeError) as exc:
            out.append((name[:-4], None, str(reg), f"cannot be read ({exc})"))
            continue
        path = fields.get("path", "")
        doc = read_json(path) if path.startswith("/") else None
        if not isinstance(doc, dict) or doc.get("schema") not in STORE_SCHEMAS or not isinstance(doc.get("events"), list):
            out.append((name[:-4], None, path or str(reg), "is not a readable fm-alert-store/v1 store"))
            continue
        out.append((name[:-4], doc, path, None))
    return out


def keyed(doc):
    return [e for e in doc["events"] if isinstance(e, dict) and isinstance(e.get("key"), str)]


def ended_after(events, key, raised):
    """(action, epoch) of the first clear, acknowledgement or new raise of key after raised, else None."""
    for event in events:
        at = epoch_of(event.get("at"))
        if event["key"] == key and at is not None and at > raised and event.get("action") in ("cleared", "acked", "raised"):
            return [event["action"], at]
    return None


def raises(store_id, doc, since, until):
    """The raise events of one store in [since, until), each with when it was cleared or acknowledged."""
    events = keyed(doc)
    rows = []
    for event in events:
        at = epoch_of(event.get("at"))
        if event.get("action") != "raised" or at is None or not since <= at < until:
            continue
        alert = event.get("alert") if isinstance(event.get("alert"), dict) else {}
        rows.append({"store": store_id, "key": event["key"], "kind": alert.get("kind") or event["key"],
                     "subject": alert.get("subject", ""), "role": alert.get("role"),
                     "event": epoch_of(alert.get("since")) or at, "raised": at,
                     "deliver_by": epoch_of(alert.get("deliver_by")) if alert.get("deliver_by") else None,
                     "ended": ended_after(events, event["key"], at)})
    return rows


def history_gap(doc, since):
    """When the store's kept events start after since and earlier ones were dropped, the first kept time."""
    events = doc.get("events") or []
    first = events[0] if events and isinstance(events[0], dict) else None
    if first and isinstance(first.get("seq"), int) and first["seq"] > 1:
        at = epoch_of(first.get("at"))
        if at is not None and at > since:
            return at
    return None


def judge(row, posts, now):
    """Fill in delivered, notice and outcome for one raise from the re-posts of its key."""
    end = row["ended"][1] if row.get("ended") and row["ended"][1] is not None else None
    delivered = next((t for t in sorted(posts.get((row["store"], row["key"]), []))
                      if t >= row["raised"] and (end is None or t <= end)), None)
    row["delivered"] = delivered
    row["notice"] = delivered - row["event"] if delivered is not None else None
    by = row["deliver_by"]
    if by is None:
        row["outcome"] = UNJUDGED if delivered is not None or end is not None else PENDING
    elif delivered is not None:
        row["outcome"] = MET if delivered <= by else MISSED
    elif end is not None and row["ended"][0] != "raised" and end <= by:
        row["outcome"] = CLEARED
    elif (end if end is not None else now) > by:
        row["outcome"] = UNDELIVERED
    else:
        row["outcome"] = PENDING
    return row


def measure(home, since, until, now, posts=None, carried=()):
    """Judge every handoff-watch raise for the home in [since, until); returns (rows, problems, notes).

    posts defaults to every re-post in the home's log; carried are earlier rows
    still pending, judged again against posts. A problem is a record that could
    not be read; a note is a store whose kept history starts inside the window.
    """
    problems, notes = [], []
    if posts is None:
        posts, _ = deliveries(Path(home) / "state/alert-stores.log")
    rows = []
    docs = {}
    for store_id, doc, path, problem in stores(home):
        if problem:
            problems.append(f"alert store {store_id or ''} at {path} {problem}".replace("  ", " "))
            continue
        docs[store_id] = doc
        gap = history_gap(doc, since)
        if gap is not None:
            notes.append(f"alert store {store_id} keeps events only from {iso(gap)}; earlier raises are not measured")
        rows += raises(store_id, doc, since, until)
    for row in carried:
        row = dict(row)
        if row.get("store") in docs:
            row["ended"] = ended_after(keyed(docs[row["store"]]), row["key"], row["raised"])
        rows.append(row)
    return [judge(r, posts, now) for r in rows], problems, notes


def summary(rows):
    """One line per check kind, and the whole set's counts."""
    kinds = {}
    for row in rows:
        kinds.setdefault(row["kind"], []).append(row)
    lines = []
    for kind, group in sorted(kinds.items()):
        counts = {o: sum(1 for r in group if r["outcome"] == o) for o in (MET, MISSED, UNDELIVERED, PENDING, CLEARED, UNJUDGED)}
        notices = sorted(r["notice"] for r in group if r["notice"] is not None)
        text = f"{kind}: {len(group)} alarm{'s' if len(group) != 1 else ''}, " + ", ".join(
            f"{n} {o}" for o, n in counts.items() if n)
        if notices:
            text += f"; notice median {span(notices[len(notices) // 2])}, max {span(notices[-1])}"
        lines.append(text)
    return lines


def failed(row):
    return row["outcome"] in (MISSED, UNDELIVERED)


def notice_short(rows):
    """The time-to-notice part of the coverage line."""
    if not rows:
        return "time to notice: no alarm was raised, so nothing was measured"
    bad = [r for r in rows if failed(r)]
    counts = {o: sum(1 for r in rows if r["outcome"] == o) for o in (MET, MISSED, UNDELIVERED, PENDING, CLEARED, UNJUDGED)}
    text = f"time to notice: {len(rows)} alarm{'s' if len(rows) != 1 else ''}, " + ", ".join(
        f"{n} {o}" for o, n in counts.items() if n)
    if bad:
        worst = max(bad, key=lambda r: ((r["delivered"] or float("inf")) - r["deliver_by"]))
        late = (worst["delivered"] - worst["deliver_by"]) if worst["delivered"] is not None else None
        text += (f" (worst {worst['kind']} {worst['key']} for {worst['role'] or 'unknown role'}: "
                 + (f"{span(late)} past its target" if late is not None else "never delivered") + ")")
    return text


def row_line(row):
    target = span(row["deliver_by"] - row["event"]) if row["deliver_by"] is not None else "none"
    got = span(row["notice"]) if row["notice"] is not None else "-"
    return (f"{row['kind']} {row['key']} role={row['role'] or '-'} event={iso(row['event'])} "
            f"raised={iso(row['raised'])} delivered={iso(row['delivered']) if row['delivered'] else '-'} "
            f"notice={got} target={target} {row['outcome']}")


# ---------- coverage ----------

def cached_protocols(home):
    """Protocols from the watcher's fragment cache, or None when the watcher has not run here."""
    cache = read_json(Path(home) / "state/handoff-watch/fragments.json")
    if not isinstance(cache, dict) or cache.get("schema") != STATE_SCHEMA or not isinstance(cache.get("files"), dict):
        return None
    return registry.first_declared(cache["files"])[0]


def last_receipt(home, pid, sname):
    """(epoch of the stage's newest receipt or None, whether the watcher holds state for it)."""
    st = read_json(Path(home) / "state/handoff-watch/stages" / f"{pid}--{sname}.json")
    if not isinstance(st, dict) or st.get("schema") != STATE_SCHEMA:
        return None, False
    last = st.get("last_receipt")
    if not isinstance(last, (int, float)):
        ats = [r["cur"]["at"] for r in (st.get("records") or {}).values()
               if isinstance(r, dict) and isinstance(r.get("cur"), dict) and isinstance(r["cur"].get("at"), (int, float))]
        last = max(ats, default=None)
    return last, True


def undeclared(home, root):
    """(undeclared actors, problem or None) from bin/fm-handoff-actors.py list."""
    cmd = [sys.executable, str(HERE / "fm-handoff-actors.py"), "list", "--home", str(home)]
    if root:
        cmd += ["--root", str(root)]
    try:
        run = subprocess.run(cmd, capture_output=True, text=True, timeout=20)
        doc = json.loads(run.stdout)
    except (OSError, subprocess.TimeoutExpired, ValueError) as exc:
        return [], f"the actor inventory could not be read ({exc})"
    actors = sorted(r["actor"] for r in doc.get("actors", []) if r.get("state") == "undeclared")
    unknown = sorted(r["actor"] for r in doc.get("actors", []) if r.get("state") == "unknown")
    problem = None
    if doc.get("problems") or unknown:
        problem = "the actor inventory is incomplete: " + "; ".join(
            [f"{p.get('subject')} {p.get('what')}" for p in doc.get("problems", [])]
            + [f"{a} is unknown" for a in unknown])
    return actors, problem


def coverage(self_id, home, protocols, now, actors, rows, problems, notes=()):
    """The one-line weekly coverage of one home, and its detail lines."""
    owned = sorted(pid for pid, p in protocols.items() if p.get("owner") == self_id and pid != WATCH_PROTOCOL)
    live, idle, planned = [], [], []
    for pid, proto in sorted(protocols.items()):
        if pid == WATCH_PROTOCOL:
            continue
        for stage in proto.get("stages", []):
            if stage.get("owner") != self_id:
                continue
            name = f"{pid}/{stage['name']}"
            if stage.get("planned"):
                planned.append(name)
                continue
            last, known = last_receipt(home, pid, stage["name"])
            if last is not None and now - last <= WEEK:
                live.append(name)
            elif last is not None:
                idle.append(f"{name} idle since {iso(last)}")
            else:
                idle.append(f"{name} " + ("never had a receipt" if known else "has no watcher state"))
    stages = len(live) + len(idle)
    line = (f"handoff coverage {self_id} {iso(now - WEEK)}..{iso(now)}: {len(owned)} protocol"
            f"{'s' if len(owned) != 1 else ''} declared; {stages} stage{'s' if stages != 1 else ''} owned, "
            f"{len(live)} with receipts, {len(idle)} with none")
    line += f" (idle beyond 7 days: {', '.join(idle)})" if idle else ""
    line += f", {len(planned)} planned" if planned else ""
    line += (f"; {len(actors)} undeclared actor{'s' if len(actors) != 1 else ''}"
             + (f" ({', '.join(actors)})" if actors else ""))
    line += "; " + notice_short(rows)
    if problems:
        line += f"; incomplete: {len(problems)} source{'s' if len(problems) != 1 else ''} unreadable"
    detail = [f"protocols declared: {', '.join(owned) or 'none'}",
              f"stages with receipts in the week: {', '.join(live) or 'none'}",
              f"stages with none: {', '.join(idle) or 'none'}",
              f"planned stages: {', '.join(planned) or 'none'}",
              f"undeclared actors: {', '.join(actors) or 'none'}"]
    detail += [f"unreadable: {p}" for p in problems] + [f"note: {n}" for n in notes]
    detail += ["", "time to notice, per check:"] + (summary(rows) or ["no alarm was raised"])
    detail += ["", "alarms:"] + ([row_line(r) for r in rows] or ["none"])
    bad = bool(idle or actors or any(failed(r) for r in rows))
    return line, detail, bad


def coverage_for(home, root, now, rows=None, problems=None, notes=None, protocols=None):
    """Everything the coverage line needs, read for one home; returns (line, detail, bad, problems)."""
    self_id, _ = registry.discover(home, root)
    problems, notes = list(problems or []), list(notes or [])
    if rows is None:
        rows, more, notes = measure(home, now - WEEK, now + 1, now)
        problems += more
    if protocols is None:
        protocols = cached_protocols(home)
        if protocols is None:
            problems.append(f"{home}/state/handoff-watch/fragments.json is missing or unreadable: "
                            "the watcher has not run in this home")
            protocols = {}
    actors, problem = undeclared(home, root)
    if problem:
        problems.append(problem)
    line, detail, bad = coverage(self_id, home, protocols, now, actors, rows, problems, notes)
    return line, detail, bad, problems


# ---------- command line ----------

def when(text):
    if text.isdigit():
        return int(text)
    at = epoch_of(text)
    if at is None:
        raise argparse.ArgumentTypeError(f"not an epoch or a UTC ISO 8601 time: {text}")
    return at


def niced(argv):
    """Re-run under nice 19 and idle I/O once."""
    if os.environ.get("FM_HANDOFF_MEASURE_NICED"):
        return
    os.environ["FM_HANDOFF_MEASURE_NICED"] = "1"
    cmd = [sys.executable, os.path.abspath(__file__), *argv]
    if shutil.which("ionice"):
        cmd = ["ionice", "-c3", *cmd]
    if shutil.which("nice"):
        cmd = ["nice", "-n", "19", *cmd]
    os.execvp(cmd[0], cmd)


def main(argv):
    parser = argparse.ArgumentParser(prog="fm-handoff-measure.py", description=__doc__.split("\n\n")[0])
    parser.add_argument("command", choices=("notice", "coverage"))
    parser.add_argument("--home", required=True)
    parser.add_argument("--root")
    parser.add_argument("--since", type=when)
    parser.add_argument("--until", type=when)
    parser.add_argument("--now", type=int)
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args(argv)
    niced(argv)
    now = args.now if args.now is not None else int(datetime.datetime.now(datetime.timezone.utc).timestamp())
    home = Path(args.home).resolve()
    try:
        self_id, _ = registry.discover(home, args.root)
    except (ValueError, OSError) as exc:
        print(f"fm-handoff-measure: {exc}", file=sys.stderr)
        return 2
    if args.command == "notice":
        until = args.until if args.until is not None else now + 1
        since = args.since if args.since is not None else until - WEEK
        rows, problems, notes = measure(home, since, until, now)
        bad = any(failed(r) for r in rows)
        if args.json:
            print(json.dumps({"home": self_id, "since": iso(since), "until": iso(until), "alarms": rows,
                              "per_check": summary(rows), "problems": problems, "notes": notes},
                             indent=2, sort_keys=True))
        else:
            print(f"time to notice in {self_id}, alarms raised from {iso(since)} to {iso(until)}:")
            for row in rows:
                print("  " + row_line(row))
            print("per check:" if rows else "no alarm was raised for this home in the window")
            for line in summary(rows):
                print("  " + line)
            for problem in problems:
                print(f"unreadable: {problem}")
            for note in notes:
                print(f"note: {note}")
    else:
        line, detail, bad, problems = coverage_for(home, args.root, now)
        if args.json:
            print(json.dumps({"home": self_id, "line": line, "detail": detail, "problems": problems},
                             indent=2, sort_keys=True))
        else:
            print(line)
            for text in detail:
                print(("  " + text) if text else "")
    if problems:
        return 3
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
