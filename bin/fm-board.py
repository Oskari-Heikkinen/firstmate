#!/usr/bin/env python3
"""Fleet board generator, run by bin/fm-board.sh (see its header for usage).

Reads published summaries only and writes exactly two page files atomically:
<home>/state/board/board.json (fm-board.v1) and <home>/state/board/index.html.
The token reader (bin/fm_board_tokens.py) runs inside the same run and keeps its
own cursor, tokens.json and fm-usage.v1 rows beside them.

Homes arrive in the --homes file as `<area>\t<home>\t<remote 0|1>` lines (main first),
parsed by the wrapper with bin/fm-secondmate-registry-lib.sh. Project feeds,
detector thresholds, session roots and scheduled units come from
<home>/config/board-feeds (docs/configuration.md "Fleet board feeds"); a missing
file means no feeds and default thresholds.

Every item has one shape {panel, group, title, state, since, owner, link,
detail} plus optional `value` (a count) and `view` ("count" or "bar"). A source
that is missing, stale, unreadable or of an unknown version becomes a visible
blind-spot item naming the source and its owner; it never silently disappears.

The board is read-only: it never acts on what it shows, and it never reads raw
status logs, watcher internals or backlog markdown. It never shows money,
spend, remaining allowance, quota or run-out.
"""

import argparse
import datetime
import html
import json
import os
import re
import subprocess
import sys
import threading
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import fm_board_tokens  # noqa: E402

SCHEMA = "fm-board.v1"
SUMMARY_SCHEMA = "fm-secondmate-home-summary.v1"
PANELS = ["decisions", "health", "work", "pipeline", "waste", "tokens"]
STATES = {"ok", "bad", "warn", "blind", "idle", "info"}
SOURCE_TIMEOUT = 5.0
DEFAULTS = {"summary_max_age": 7200, "merge_stall_seconds": 3600}
FEED_VERSIONS = ("fm-board-items.v1", "tetjet-queue-snapshot.v1", "merge-queue-log.v1",
                 "hypotheses-overview.v1")
HYPOTHESES_HEADER = ["Running", "Ready to test", "Open after a result", "Want to test",
                     "Settled", "Dropped"]
TAIL_BYTES = 4 * 1024 * 1024


class SourceError(Exception):
    def __init__(self, status, detail):
        super().__init__(detail)
        self.status = status
        self.detail = detail


def item(panel, group, title, state="info", since=None, owner=None, link=None, detail=None,
         value=None, view=None):
    it = {"panel": panel, "group": group, "title": title, "state": state, "since": since,
          "owner": owner, "link": link, "detail": detail}
    if value is not None:
        it["value"] = value
    if view is not None:
        it["view"] = view
    return it


def timed(fn, timeout=SOURCE_TIMEOUT):
    box = {}

    def target():
        try:
            box["ok"] = fn()
        except Exception as exc:  # noqa: BLE001 - reported as a blind spot
            box["err"] = exc

    th = threading.Thread(target=target, daemon=True)
    th.start()
    th.join(timeout)
    if th.is_alive():
        raise SourceError("error", "timed out after %ds" % timeout)
    if "err" in box:
        err = box["err"]
        if isinstance(err, SourceError):
            raise err
        if isinstance(err, FileNotFoundError):
            raise SourceError("missing", "not found")
        if isinstance(err, (OSError, ValueError)):
            raise SourceError("error", "unreadable")
        raise SourceError("error", type(err).__name__)
    return box["ok"]


def read_text(path, tail=None):
    with open(path, "rb") as fh:
        if tail:
            fh.seek(0, os.SEEK_END)
            size = fh.tell()
            fh.seek(max(0, size - tail))
        data = fh.read()
    return data.decode("utf-8", "replace")


def read_json(path):
    return json.loads(read_text(path))


def iso_epoch(value):
    if isinstance(value, (int, float)):
        return int(value)
    if not isinstance(value, str):
        return None
    if re.fullmatch(r"\d{9,11}", value):
        return int(value)
    try:
        return int(datetime.datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp())
    except ValueError:
        return None


def ago(seconds):
    if seconds is None:
        return "unknown age"
    seconds = max(0, int(seconds))
    if seconds < 90:
        return "%d s" % seconds
    if seconds < 5400:
        return "%d min" % round(seconds / 60)
    if seconds < 2 * 86400:
        return "%.1f h" % (seconds / 3600) if seconds < 36000 else "%d h" % round(seconds / 3600)
    return "%d days" % round(seconds / 86400)


def trunc(text, n):
    text = str(text or "")
    return text if len(text) <= n else text[: n - 1] + "…"


# ---------------------------------------------------------------- config

def read_config(home):
    cfg = {"feeds": [], "thresholds": {}, "session_roots": [], "broad_roots": [], "units": [],
           "errors": []}
    path = os.path.join(home, "config", "board-feeds")
    try:
        text = read_text(path)
    except FileNotFoundError:
        return cfg
    except OSError:
        cfg["errors"].append("config/board-feeds unreadable")
        return cfg
    for n, line in enumerate(text.splitlines(), 1):
        w = line.split("#", 1)[0].split()
        if not w:
            continue
        try:
            if w[0] == "feed" and len(w) in (6, 7):
                cfg["feeds"].append({"name": w[1], "path": os.path.expanduser(w[2]), "version": w[3],
                                     "max_age": int(w[4]), "owner": w[5],
                                     "link": w[6] if len(w) == 7 else None})
            elif w[0] == "threshold" and len(w) == 3:
                cfg["thresholds"][w[1]] = int(w[2])
            elif w[0] == "session_root" and len(w) == 2:
                cfg["session_roots"].append(os.path.expanduser(w[1]))
            elif w[0] == "broad_root" and len(w) == 2:
                cfg["broad_roots"].append(os.path.expanduser(w[1]))
            elif w[0] == "unit" and len(w) == 3:
                cfg["units"].append({"unit": w[1], "owner": w[2]})
            else:
                raise ValueError
        except ValueError:
            cfg["errors"].append("config/board-feeds line %d not understood" % n)
    return cfg


# ---------------------------------------------------------------- board state

class Board:
    def __init__(self, now):
        self.now = now
        self.items = []
        self.sources = []

    def add(self, *args, **kw):
        self.items.append(item(*args, **kw))

    def source(self, name, kind, owner, status, detail=None, age=None):
        self.sources.append({"name": name, "kind": kind, "owner": owner, "status": status,
                             "detail": detail, "age_seconds": age})
        if status != "ok":
            words = {"missing": "missing", "stale": "stale", "unknown-version": "unknown version",
                     "error": "unreadable", "not-configured": "not set up yet",
                     "not-read": "not read"}.get(status, status)
            self.add("health", "Blind spots", "%s: %s" % (name, words), "blind",
                     owner=owner, detail=detail)


# ---------------------------------------------------------------- home summaries

def load_summaries(board, homes, thresholds):
    out = {}
    for area, home, remote in homes:
        name = "%s summary" % area
        if remote:
            board.source(name, "home-summary", area, "not-read",
                         "Remote home: the board reads local homes only.")
            continue
        path = os.path.join(home, "state", "home-summary.json")
        try:
            data = timed(lambda p=path: read_json(p))
        except SourceError as err:
            board.source(name, "home-summary", area, err.status,
                         "%s (%s)." % (err.detail.capitalize(), "state/home-summary.json"))
            continue
        if not isinstance(data, dict) or data.get("schema") != SUMMARY_SCHEMA:
            board.source(name, "home-summary", area, "unknown-version",
                         "Expected %s." % SUMMARY_SCHEMA)
            continue
        gen = data.get("generated_epoch") if isinstance(data.get("generated_epoch"), int) else None
        age = board.now - gen if gen is not None else None
        if age is None or age > thresholds["summary_max_age"]:
            board.source(name, "home-summary", area, "stale",
                         "Last written %s ago; figures below may be out of date." % ago(age), age)
        else:
            board.source(name, "home-summary", area, "ok", age=age)
        out[area] = data
    return out


def decision_for(entry):
    f = entry.get("for")
    if f in ("captain", "supervisor"):
        return f
    if entry.get("source") == "backlog" or str(entry.get("key", "")).startswith("captain-hold-"):
        return "captain"
    return "captain" if entry.get("verb") in ("needs-decision", "captain-hold") else "supervisor"


def omitted(summary, surface):
    for o in summary.get("omitted") or []:
        if isinstance(o, dict) and o.get("surface") == surface:
            return int(o.get("count") or 0)
    return 0


def mirror_task(key):
    m = re.fullmatch(r"captain-hold-(.+)-\d+", key or "")
    return m.group(1) if m else None


def decisions(board, summaries, homes):
    areas = {a for a, _, _ in homes}
    parked = []
    for area, s in summaries.items():
        for d in s.get("decisions_open") or []:
            if not isinstance(d, dict):
                continue
            since = d.get("opened_at_epoch") if isinstance(d.get("opened_at_epoch"), int) else None
            title = trunc(d.get("summary") or d.get("id"), 160)
            owner = d.get("id") if d.get("id") in areas else area
            group = "Needs a call now"
            state = "warn"
            detail = None
            # F3: a captain hold mirrored up from a second mate is judged by that
            # second mate's own summary, so answered or deferred holds stop
            # counting as open calls here.
            task = mirror_task(d.get("key")) if d.get("id") in areas else None
            if task is not None:
                src = summaries.get(owner)
                if src is None:
                    detail = "Owner summary unreadable; shown as open until it can be checked."
                else:
                    live = [x for x in src.get("decisions_open") or []
                            if isinstance(x, dict) and x.get("id") == task and x.get("source") == "backlog"]
                    queued = [x for x in src.get("queued") or []
                              if isinstance(x, dict) and x.get("id") == task]
                    if live:
                        continue  # the owner's own row carries it
                    if queued and queued[0].get("hold_bucket") not in (None, "live"):
                        continue  # deferred; listed under Parked on purpose by its owner
                    if omitted(src, "decisions_open"):
                        detail = "Owner list is truncated; shown as open until it can be checked."
                    elif omitted(src, "queued"):
                        group, state = "Answered, not yet closed by the owner", "idle"
                        detail = ("No longer waiting on a call in %s (answered or deferred); "
                                  "its mirror here still needs closing." % owner)
                    else:
                        group, state = "Answered, not yet closed by the owner", "idle"
                        detail = "No longer held by %s; its mirror here still needs closing." % owner
            elif decision_for(d) == "supervisor":
                group, state = "Waiting on a supervisor", "info"
                detail = "A question between areas, not a call for the captain."
            if since is not None:
                detail = ((detail + " ") if detail else "") + "Open %s." % ago(board.now - since)
            board.add("decisions", group, title, state, since=since, owner=owner, detail=detail)
        extra = omitted(s, "decisions_open")
        if extra:
            board.add("decisions", "Waiting on a supervisor", "%d more open items in %s" % (extra, area),
                      "info", owner=area, detail="Not listed by the area's summary.")
        for q in s.get("queued") or []:
            if isinstance(q, dict) and q.get("hold_bucket") in ("dated", "aged", "blocked"):
                parked.append((area, q))
    for area, q in sorted(parked, key=lambda x: str(x[1].get("hold_until") or "9999")):
        until = q.get("hold_until")
        why = {"dated": "back %s" % until if until else "deferred", "aged": "no date, held long",
               "blocked": "waits on other work"}[q["hold_bucket"]]
        board.add("decisions", "Parked on purpose", trunc(q.get("title") or q.get("id"), 120), "idle",
                  owner=area, detail=why)


def health_and_work(board, summaries, homes):
    areas = {a for a, _, _ in homes}
    table = {}
    for area, s in summaries.items():
        if s.get("valid") is False:
            board.add("health", "Areas", "%s summary marks itself incomplete" % area, "warn",
                      owner=area, detail=trunc(s.get("reason") or "no reason given", 160)
                      + ". Its tasks are still listed one by one.")
        sup = s.get("supervision") if isinstance(s.get("supervision"), dict) else None
        verdict = (sup or {}).get("state")
        if verdict == "healthy":
            board.add("health", "Monitoring", "%s: monitoring running" % area, "ok", owner=area)
        elif verdict == "down":
            board.add("health", "Monitoring", "%s: monitoring down" % area, "bad", owner=area,
                      detail=trunc((sup or {}).get("reason") or "", 120) or None)
        else:
            board.add("health", "Blind spots", "%s: monitoring verdict unknown" % area, "blind",
                      owner=area, detail="The area's summary publishes no monitoring verdict.")
        row = table.setdefault(area, {"working": 0, "idle": 0, "parked": 0, "empty": 0})
        for e in s.get("endpoints") or []:
            if not isinstance(e, dict):
                continue
            ep = e.get("endpoint") if isinstance(e.get("endpoint"), dict) else {}
            # Ordinary tasks carry only endpoint presence (agent_alive is
            # "not_checked"), so "no agent" needs positive evidence: an absent
            # endpoint or a dead agent.
            alive = not (ep.get("exists") is False or ep.get("status") in ("absent", "dead")
                         or ep.get("agent_alive") == "dead")
            state = e.get("state") or "unknown"
            name = trunc(e.get("title") or e.get("id"), 90)
            last = e.get("last_event") if isinstance(e.get("last_event"), dict) else {}
            age = last.get("age_seconds") if isinstance(last.get("age_seconds"), int) else None
            since = board.now - age if age is not None else None
            if e.get("kind") == "secondmate" or (e.get("kind") is None and e.get("id") in areas):
                if not alive:
                    board.add("health", "Areas", "Second mate %s is not running" % e.get("id"), "bad",
                              owner=area, detail="Its area gets no supervision until it is relaunched.")
                continue
            if state in ("done", "failed"):
                if ep.get("exists"):
                    row["empty"] += 1
                    board.add("work", "Empty tabs", name, "idle", since=since, owner=area,
                              detail="Task finished, its tab is still open.")
                continue
            if state == "working":
                if alive:
                    row["working"] += 1
                    board.add("work", "Working", name, "ok", since=since, owner=area)
                else:
                    row["parked"] += 1
                    board.add("work", "Says working, no agent", name, "warn", since=since, owner=area,
                              detail="Last event %s ago." % ago(age) if age is not None else None)
                continue
            if alive:
                row["idle"] += 1
                board.add("work", "Idle agent", name, "idle", since=since, owner=area,
                          detail="State: %s." % state)
            else:
                row["parked"] += 1
                board.add("work", "Parked, no agent", name, "idle", since=since, owner=area,
                          detail="State: %s." % state)
        extra = omitted(s, "endpoints")
        if extra:
            board.add("work", "Parked, no agent", "%d more tasks in %s" % (extra, area), "info",
                      owner=area, detail="Not listed by the area's summary.")
        queued = (s.get("counts") or {}).get("queued")
        if isinstance(queued, int):
            board.add("pipeline", "Queued work per area", area, "info", owner=area, value=queued,
                      view="count")
    return table


# ---------------------------------------------------------------- feeds

def feed_items_v1(board, feed, data):
    if not isinstance(data, dict) or data.get("schema") != "fm-board-items.v1" \
            or not isinstance(data.get("items"), list):
        raise SourceError("unknown-version", "Expected fm-board-items.v1.")
    for it in data["items"][:200]:
        if not isinstance(it, dict) or it.get("panel") not in PANELS:
            continue
        state = it.get("state") if it.get("state") in STATES else "info"
        value = it.get("value") if isinstance(it.get("value"), int) else None
        view = it.get("view") if it.get("view") in ("count", "bar") else None
        since = it.get("since") if isinstance(it.get("since"), int) else None
        link = it.get("link") if isinstance(it.get("link"), str) else feed["link"]
        board.add(it["panel"], trunc(it.get("group") or feed["name"], 80), trunc(it.get("title"), 160),
                  state, since=since, owner=trunc(it.get("owner") or feed["owner"], 40), link=link,
                  detail=trunc(it.get("detail"), 240) if it.get("detail") else None, value=value, view=view)
    return iso_epoch(data.get("generated_epoch") or data.get("generated_at"))


def feed_tetjet(board, feed, data):
    if not isinstance(data, dict) or data.get("schema") != "tetjet-queue-snapshot.v1" \
            or not isinstance(data.get("jobs"), list):
        raise SourceError("unknown-version", "Expected tetjet-queue-snapshot.v1.")
    counts = {}
    for job in data["jobs"]:
        if isinstance(job, dict):
            word = str(job.get("state") or "unknown")
            counts[word] = counts.get(word, 0) + 1
    machine = data.get("machine") if isinstance(data.get("machine"), dict) else {}
    live = machine.get("runs_live")
    group = "%s · %d jobs%s" % (feed["name"], len(data["jobs"]),
                               " · %s runs live" % live if isinstance(live, int) else "")
    for word, n in sorted(counts.items(), key=lambda kv: -kv[1]):
        board.add("pipeline", group, trunc(word.replace("_", " "), 60), "info", owner=feed["owner"],
                  link=feed["link"], value=n, view="bar")
    return iso_epoch(data.get("generated_at"))


LOG_RE = re.compile(r"^(HANDOFF|RESULT)\s+(\S+)\s*(.*)$")


def feed_merge_log(board, feed, text):
    # One hand-off per task: a newer HANDOFF replaces an older head, "taken"
    # means the merge agent is on it, and any other RESULT outcome ends it.
    waiting = {}
    head_task = {}
    landed = 0
    parsed = 0
    day_start = fm_board_tokens.day_window(board.now)[1]
    for line in text.splitlines():
        m = LOG_RE.match(line.strip())
        if not m:
            continue
        parsed += 1
        at = iso_epoch(m.group(2))
        fields = dict(kv.split("=", 1) for kv in m.group(3).split() if "=" in kv)
        head = fields.get("head") or ""
        if m.group(1) == "HANDOFF":
            task = fields.get("task") or head
            waiting[task] = (head, at)
            head_task[head] = task
            continue
        task = head_task.get(head, head)
        if fields.get("outcome") != "taken" and waiting.get(task, (None,))[0] == head:
            waiting.pop(task, None)
        if fields.get("outcome") == "landed" and at is not None and at >= day_start:
            landed += 1
    if text.strip() and not parsed:
        raise SourceError("unknown-version", "No HANDOFF or RESULT lines found.")
    stall = board.thresholds["merge_stall_seconds"]
    oldest = min((a for _, a in waiting.values() if a is not None), default=None)
    oldest_age = board.now - oldest if oldest is not None else None
    stalled = oldest_age is not None and oldest_age > stall
    board.add("health", "Merge train", "%s: %d waiting" % (feed["name"], len(waiting)),
              "warn" if stalled else "ok", since=oldest, owner=feed["owner"], link=feed["link"],
              detail=("Oldest has waited %s." % ago(oldest_age)) if oldest_age is not None else None)
    board.add("pipeline", feed["name"], "waiting", "info", owner=feed["owner"], value=len(waiting),
              view="count")
    board.add("pipeline", feed["name"], "landed today", "info", owner=feed["owner"], value=landed,
              view="count")
    return None


def feed_hypotheses(board, feed, text):
    lines = [ln.strip() for ln in text.splitlines()]
    for i, ln in enumerate(lines):
        cells = [c.strip() for c in ln.strip("|").split("|")] if ln.startswith("|") else []
        if cells == HYPOTHESES_HEADER and i + 2 < len(lines):
            nums = [c.strip().strip("*") for c in lines[i + 2].strip("|").split("|")]
            if len(nums) == len(cells) and all(re.fullmatch(r"\d+", n) for n in nums):
                for label, n in zip(cells, nums):
                    board.add("pipeline", feed["name"], label.lower(), "info", owner=feed["owner"],
                              link=feed["link"], value=int(n), view="count")
                return None
    raise SourceError("unknown-version", "Count table header not found.")


def load_feeds(board, cfg):
    mappers = {"fm-board-items.v1": ("json", feed_items_v1),
               "tetjet-queue-snapshot.v1": ("json", feed_tetjet),
               "merge-queue-log.v1": ("tail", feed_merge_log),
               "hypotheses-overview.v1": ("text", feed_hypotheses)}
    for feed in cfg["feeds"]:
        name, owner = feed["name"], feed["owner"]
        if feed["version"] not in mappers:
            board.source(name, "feed", owner, "unknown-version",
                         "Configured version %s has no mapper." % feed["version"])
            continue
        how, mapper = mappers[feed["version"]]
        mark = len(board.items)
        try:
            if how == "json":
                data = timed(lambda p=feed["path"]: read_json(p))
            else:
                data = timed(lambda p=feed["path"], t=(TAIL_BYTES if how == "tail" else None): read_text(p, t))
            stamp = mapper(board, feed, data)
            if stamp is None:
                stamp = int(os.stat(feed["path"]).st_mtime)
        except SourceError as err:
            del board.items[mark:]
            board.source(name, "feed", owner, err.status, err.detail)
            continue
        except OSError:
            del board.items[mark:]
            board.source(name, "feed", owner, "error", "unreadable")
            continue
        age = board.now - stamp
        if feed["max_age"] and age > feed["max_age"]:
            board.source(name, "feed", owner, "stale", "Last written %s ago." % ago(age), age)
        else:
            board.source(name, "feed", owner, "ok", age=age)


def load_units(board, cfg):
    for u in cfg["units"]:
        name = "scheduled job %s" % u["unit"]
        try:
            proc = subprocess.run(["systemctl", "--user", "show", u["unit"],
                                   "--property=LoadState,ActiveState,Result,ExecMainStatus"],
                                  capture_output=True, text=True, timeout=SOURCE_TIMEOUT, check=False)
        except (OSError, subprocess.TimeoutExpired):
            board.source(name, "systemd", u["owner"], "error", "systemctl did not answer.")
            continue
        props = dict(ln.split("=", 1) for ln in proc.stdout.splitlines() if "=" in ln)
        if proc.returncode != 0 or props.get("LoadState") in (None, "not-found"):
            board.source(name, "systemd", u["owner"], "missing", "Unit not found.")
            continue
        board.source(name, "systemd", u["owner"], "ok")
        good = props.get("Result") == "success" and props.get("ExecMainStatus", "0") == "0"
        board.add("health", "Scheduled jobs", u["unit"], "ok" if good else "bad", owner=u["owner"],
                  detail=None if good else "Last result: %s." % trunc(props.get("Result"), 40))


def load_spawn_starts(homes):
    starts = []
    for area, home, remote in homes:
        if remote:
            continue
        try:
            text = timed(lambda p=os.path.join(home, "state", "spawn-starts.jsonl"): read_text(p, TAIL_BYTES))
        except SourceError:
            continue
        for line in text.splitlines():
            try:
                rec = json.loads(line)
            except ValueError:
                continue
            if isinstance(rec, dict) and rec.get("schema") == "fm-spawn-start.v1":
                starts.append(rec)
    return starts


# ---------------------------------------------------------------- tokens + waste

def tokens_panel(board, tok, work_table):
    if tok is None:
        return
    files = tok["files"]
    if files.get("behind"):
        board.add("health", "Board", "Token reader catching up", "warn", owner="board",
                  detail="%d session files not fully read this run; the rest follows next run."
                  % files["behind"])
    if files.get("unreadable"):
        board.add("health", "Blind spots", "Session records: %d unreadable" % files["unreadable"],
                  "blind", owner="board")
    for g in tok["by_area"]:
        board.add("tokens", "By area", g["area"], "info", owner=g["area"], value=g["tokens"], view="bar",
                  detail="%d sessions" % g["sessions"])
    for g in tok["by_kind"]:
        board.add("tokens", "By kind of agent", g["kind"], "info", value=g["tokens"], view="bar",
                  detail="%d sessions" % g["sessions"])
    for g in tok["by_task"]:
        board.add("tokens", "By task", g["task"], "info", owner=g["area"], value=g["tokens"],
                  detail="%s tokens · %s · %d sessions · %d turns"
                  % (fmt_tokens(g["tokens"]), g["kind"], g["sessions"], g["turns"]))
    for r in tok["rules"]:
        board.add("tokens", "Detectors", "%s: %d" % (r["label"], r["count"]),
                  "warn" if r["sessions"] else "ok", value=r["count"],
                  detail="%d sessions flagged today" % r["sessions"])
    # Waste: where agents do a script's job.
    rules = {r["rule"]: r for r in tok["rules"]}
    for key, fix in (("wait", "Register the wait as a condition watch instead of a loop."),
                     ("repeat", "Publish the answer once and read the summary."),
                     ("broad", "Search named folders only."),
                     ("status_prose", "Short typed status lines, detail in files."),
                     ("idle_wake", "Exit when idle and let an event start a fresh agent.")):
        r = rules[key]
        if r["sessions"]:
            board.add("waste", "Habits", "%s: %d" % (r["label"], r["count"]), "warn",
                      detail="%d sessions today. Fix: %s" % (r["sessions"], fix))
    no_agent = sum(1 for it in board.items if it["group"] == "Says working, no agent")
    if no_agent:
        board.add("waste", "Records", "%d \"working\" records with no agent" % no_agent, "warn",
                  detail="Fix: relaunch or close the task.")
    empty = sum(row["empty"] for row in work_table.values())
    if empty:
        board.add("waste", "Records", "%d empty tabs" % empty, "idle",
                  detail="Fix: clean-up closes the task's tab.")


STATIC_BLIND = [
    ("Spawn admission verdict", "not published yet", "tooling",
     "Why a new worker cannot start (slot cap, memory) appears here once spawn publishes it."),
    ("Heavy slot status", "not published yet", "tooling",
     "Which heavy job holds the shared slot appears here once the slot owner publishes it."),
    ("Status volume", "not measured yet", "tooling",
     "Status text volume into each supervisor appears here once it is published as counts."),
]


# ---------------------------------------------------------------- render

CSS = """
:root{color-scheme:light;--bg:#edf1f4;--surface:#fff;--surface-2:#e2e8ed;--sunk:#d7dfe6;--ink:#13212e;--ink-2:#3f5063;--ink-3:#66778a;--rule:#c6d0d9;--accent:#0b6682;--accent-soft:#d3e7ee;--signal:#9a5b0c;--signal-soft:#f6e6c8;--ok:#2c7a4b;--ok-soft:#d6ecde;--bad:#ad3326;--bad-soft:#f5d9d4;--blind:#5f4f8c;--blind-soft:#e4def3;--idle:#66778a;--idle-soft:#e2e8ed;--sans:"Atkinson Hyperlegible","Segoe UI",system-ui,-apple-system,sans-serif;--mono:"JetBrains Mono",ui-monospace,"Cascadia Mono",Consolas,monospace}
@media (prefers-color-scheme:dark){:root:not([data-theme="light"]){color-scheme:dark;--bg:#0d151e;--surface:#142130;--surface-2:#1b2a3a;--sunk:#0f1a25;--ink:#e3ebf2;--ink-2:#a8b7c6;--ink-3:#7d8fa1;--rule:#28394b;--accent:#62c3df;--accent-soft:#16384a;--signal:#e7ae52;--signal-soft:#3b2c12;--ok:#62c08a;--ok-soft:#153324;--bad:#f0806f;--bad-soft:#3d1c18;--blind:#ae9ee0;--blind-soft:#2a2440;--idle:#8a9bad;--idle-soft:#1b2a3a}}
:root[data-theme="dark"]{color-scheme:dark;--bg:#0d151e;--surface:#142130;--surface-2:#1b2a3a;--sunk:#0f1a25;--ink:#e3ebf2;--ink-2:#a8b7c6;--ink-3:#7d8fa1;--rule:#28394b;--accent:#62c3df;--accent-soft:#16384a;--signal:#e7ae52;--signal-soft:#3b2c12;--ok:#62c08a;--ok-soft:#153324;--bad:#f0806f;--bad-soft:#3d1c18;--blind:#ae9ee0;--blind-soft:#2a2440;--idle:#8a9bad;--idle-soft:#1b2a3a}
*{box-sizing:border-box}html{-webkit-text-size-adjust:100%}
body{margin:0;background:var(--bg);color:var(--ink);font-family:var(--sans);font-size:16px;line-height:1.5}
.wrap{max-width:1180px;margin:0 auto;padding:16px 16px 48px;display:grid;gap:14px}
a{color:var(--accent);text-underline-offset:2px}
.mono{font-family:var(--mono);font-size:.86em}.muted{color:var(--ink-3)}.small{font-size:.86rem}
.boardhead{display:flex;flex-wrap:wrap;gap:8px 18px;align-items:center;justify-content:space-between;background:var(--surface);border:1px solid var(--rule);border-radius:10px;padding:12px 16px}
.boardhead h1{font-size:1.2rem;margin:0}.when{font-family:var(--mono);font-size:.8rem;color:var(--ink-3)}
.chips,.headline{display:flex;flex-wrap:wrap;gap:6px 10px}
.headline span{background:var(--surface);border:1px solid var(--rule);border-radius:6px;padding:4px 10px;font-size:.92rem}
.headline b{font-family:var(--mono);font-weight:500}
.panels{display:grid;gap:14px;grid-template-columns:repeat(auto-fit,minmax(min(100%,470px),1fr))}
.panel{background:var(--surface);border:1px solid var(--rule);border-radius:10px;overflow:hidden;min-width:0}
.panel.full{grid-column:1/-1}
.panel>header{display:flex;flex-wrap:wrap;gap:4px 12px;align-items:baseline;justify-content:space-between;padding:12px 16px;border-bottom:1px solid var(--rule);border-top:4px solid var(--c,var(--accent))}
.panel>header h2{margin:0;font-size:1.1rem}.panel>header .q{font-size:.85rem;color:var(--ink-3)}
.pbody{padding:10px 16px 14px;display:grid;gap:12px;min-width:0}
.group{display:grid;gap:4px;min-width:0}
.gtitle{font-size:.76rem;letter-spacing:.09em;text-transform:uppercase;color:var(--ink-3);font-weight:700}
.gtitle .ct{font-family:var(--mono);letter-spacing:0;color:var(--ink);margin-left:6px}
.row{display:grid;grid-template-columns:auto minmax(0,1fr) auto;gap:2px 10px;padding:7px 0;border-bottom:1px solid var(--rule);align-items:baseline}
.row:last-child{border-bottom:0}.row .main{font-weight:700;font-size:.94rem;overflow-wrap:anywhere}
.row .who{font-size:.8rem;color:var(--ink-3);white-space:nowrap}
.row .sub{grid-column:2/-1;color:var(--ink-2);font-size:.86rem;overflow-wrap:anywhere}
@media (max-width:460px){.row{grid-template-columns:auto minmax(0,1fr)}.row .who{grid-column:2}}
.pill{display:inline-flex;align-items:center;gap:6px;font-size:.74rem;font-weight:700;padding:1px 8px;border-radius:999px;white-space:nowrap}
.pill::before{content:"";width:7px;height:7px;border-radius:50%;background:currentColor}
.p-ok{color:var(--ok);background:var(--ok-soft)}.p-bad{color:var(--bad);background:var(--bad-soft)}.p-warn{color:var(--signal);background:var(--signal-soft)}.p-blind{color:var(--blind);background:var(--blind-soft)}.p-idle{color:var(--idle);background:var(--idle-soft)}.p-info{color:var(--accent);background:var(--accent-soft)}
.counts{display:grid;grid-template-columns:repeat(auto-fit,minmax(min(100%,120px),1fr));gap:8px}
.counts div{border:1px solid var(--rule);border-radius:8px;padding:8px 10px;background:var(--bg)}
.counts b{display:block;font-family:var(--mono);font-size:1.25rem;font-weight:500}.counts span{font-size:.8rem;color:var(--ink-2)}
.bars{display:grid;gap:6px}
.bar{display:grid;grid-template-columns:minmax(0,9.5rem) minmax(0,1fr) 7rem;gap:10px;align-items:center;font-size:.9rem}
.bar .track{height:14px;background:var(--surface-2);border-radius:4px;overflow:hidden}
.bar .fill{display:block;height:100%;background:var(--accent);border-radius:4px}
.bar .v{white-space:nowrap;font-family:var(--mono);font-size:.84rem;text-align:right}
.bar .lbl{overflow-wrap:anywhere}
.tablewrap{overflow-x:auto;border:1px solid var(--rule);border-radius:8px}
table{border-collapse:collapse;width:100%;font-size:.9rem}
th,td{text-align:left;vertical-align:top;padding:7px 10px;border-bottom:1px solid var(--rule)}
th{font-size:.72rem;letter-spacing:.08em;text-transform:uppercase;color:var(--ink-3);background:var(--surface-2);white-space:nowrap}
td.num,th.num{text-align:right}td.num{font-family:var(--mono);font-size:.84rem;white-space:nowrap}
tr:last-child td{border-bottom:0}
.flag{display:inline-block;font-size:.74rem;font-weight:700;padding:1px 7px;border-radius:999px;margin:1px 2px 1px 0;white-space:nowrap;color:var(--signal);background:var(--signal-soft)}
details{border:1px solid var(--rule);border-radius:8px;background:var(--surface)}
details>summary{cursor:pointer;padding:8px 12px;display:flex;gap:10px;align-items:baseline;flex-wrap:wrap}
details>.body{padding:0 12px 10px}
.foot{color:var(--ink-3);font-size:.84rem}
"""

PANEL_META = {
    "decisions": ("Decisions", "What is waiting on a call?", "var(--signal)", False),
    "health": ("Health", "Is everything running as intended?", "var(--ok)", False),
    "work": ("Work", "What is being worked on, what is stuck or parked?", "var(--accent)", True),
    "pipeline": ("Pipeline", "What ideas and tests are coming?", "var(--blind)", False),
    "waste": ("Waste", "Where are agents doing a script's job?", "var(--bad)", False),
    "tokens": ("Tokens", "Where do tokens go today?", "var(--accent)", True),
}
FOLDED = {"Parked on purpose", "Waiting on a supervisor", "Parked, no agent", "Empty tabs",
          "Idle agent", "By task", "Working"}
PILL_WORD = {"ok": "ok", "bad": "alert", "warn": "look", "blind": "blind spot", "idle": "idle",
             "info": "info"}


def e(text):
    return html.escape(str(text), quote=True)


def fmt_tokens(n):
    if n >= 10_000_000:
        return "%d M" % round(n / 1e6)
    if n >= 1_000_000:
        return "%.1f M" % (n / 1e6)
    if n >= 1000:
        return "%d k" % round(n / 1e3)
    return str(n)


def link_html(url, label):
    if isinstance(url, str) and re.match(r"^(https?://|file://|/|\./|[A-Za-z0-9._-]+(/|$))", url):
        return '<a href="%s">%s</a>' % (e(url), e(label))
    return ""


def render_row(it, now):
    who = [it["owner"]] if it.get("owner") else []
    if it.get("since") is not None:
        who.append(ago(now - it["since"]))
    sub = e(it["detail"]) if it.get("detail") else ""
    lk = link_html(it.get("link"), "Open")
    if lk:
        sub = (sub + " " + lk).strip()
    return ('<div class="row"><span class="pill p-%s">%s</span><span class="main">%s</span>'
            '<span class="who">%s</span>%s</div>'
            % (it["state"], e(PILL_WORD[it["state"]]), e(it["title"]), e(" · ".join(who)),
               '<span class="sub">%s</span>' % sub if sub else ""))


def render_group(name, items, now, fmt=str):
    view = items[0].get("view") if all(i.get("view") == items[0].get("view") for i in items) else None
    head = '<div class="gtitle">%s<span class="ct">%d</span></div>' % (e(name), len(items))
    if view == "count":
        cells = "".join('<div><b>%s</b><span>%s</span></div>' % (e(fmt(i["value"])), e(i["title"]))
                        for i in items)
        return '<div class="group"><div class="gtitle">%s</div><div class="counts">%s</div></div>' % (
            e(name), cells)
    if view == "bar":
        top = max((i["value"] for i in items), default=0) or 1
        total = sum(i["value"] for i in items) or 1
        rows = "".join(
            '<div class="bar"><span class="lbl">%s</span><span class="track"><span class="fill" '
            'style="width:%.1f%%"></span></span><span class="v">%s · %d%%</span></div>'
            % (e(i["title"]), 100.0 * i["value"] / top, e(fmt(i["value"])), round(100.0 * i["value"] / total))
            for i in items)
        return '<div class="group"><div class="gtitle">%s</div><div class="bars">%s</div></div>' % (e(name), rows)
    body = "".join(render_row(i, now) for i in items)
    if name in FOLDED:
        return ('<details><summary><b>%s</b> <span class="mono">%d</span></summary>'
                '<div class="body">%s</div></details>' % (e(name), len(items), body))
    return '<div class="group">%s%s</div>' % (head, body)


def render_work_table(table):
    if not table:
        return ""
    rows = []
    tot = {"working": 0, "idle": 0, "parked": 0, "empty": 0}
    for area in sorted(table):
        r = table[area]
        for k in tot:
            tot[k] += r[k]
        rows.append("<tr><td>%s</td>%s</tr>" % (e(area), "".join('<td class="num">%d</td>' % r[k] for k in tot)))
    rows.append("<tr><td><b>All</b></td>%s</tr>" % "".join('<td class="num"><b>%d</b></td>' % tot[k] for k in tot))
    return ('<div class="tablewrap"><table><thead><tr><th>Area</th><th class="num">Working</th>'
            '<th class="num">Idle agent</th><th class="num">Parked, no agent</th><th class="num">Empty tab</th>'
            '</tr></thead><tbody>%s</tbody></table></div>' % "".join(rows))


def render_heaviest(tok):
    if not tok or not tok["sessions"]:
        return ""
    rows = []
    for s in tok["sessions"][:10]:
        flags = []
        f = s["flags"]
        if s["rules"]["repeat"]:
            flags.append("%d repeated calls" % f["repeat_extra"])
        if s["rules"]["wait"]:
            flags.append("%d wait loops · %d sleeps" % (f["loops"], f["sleeps"]))
        if f["broad"]:
            flags.append("%d broad searches" % f["broad"])
        if f["rereads_big"]:
            flags.append("%d big re-reads" % f["rereads_big"])
        if f["idle_wakes"]:
            flags.append("%d wakes after an hour idle" % f["idle_wakes"])
        if f["status_long"]:
            flags.append("%d long status lines" % f["status_long"])
        if f["context_swollen"]:
            flags.append("context over %s" % fmt_tokens(tok["thresholds"]["context_tokens"]))
        rows.append('<tr><td>%s</td><td>%s</td><td class="num">%s</td><td class="num">%d</td>'
                    '<td class="num">%s</td><td>%s</td></tr>'
                    % (e(s["task"]), e(s["area"]), fmt_tokens(s["tokens"]), s["turns"],
                       fmt_tokens(s["context_now"]), "".join('<span class="flag">%s</span>' % e(x) for x in flags)))
    return ('<div class="group"><div class="gtitle">Heaviest agents</div><div class="tablewrap"><table>'
            '<thead><tr><th>Agent</th><th>Area</th><th class="num">Tokens</th><th class="num">Turns</th>'
            '<th class="num">Context now</th><th>Flags today</th></tr></thead><tbody>%s</tbody></table></div></div>'
            % "".join(rows))


def render(board, tok, table):
    now = board.now
    by_panel = {p: {} for p in PANELS}
    for it in board.items:
        by_panel[it["panel"]].setdefault(it["group"], []).append(it)
    ok = sum(1 for s in board.sources if s["status"] == "ok")
    blind = sum(1 for s in board.sources if s["status"] in ("missing", "not-configured", "not-read"))
    bad = len(board.sources) - ok - blind
    calls = len(by_panel["decisions"].get("Needs a call now", []))
    alerts = sum(1 for i in board.items if i["state"] == "bad")
    warns = sum(1 for i in board.items if i["state"] == "warn" and i["panel"] in ("health", "work"))
    no_agent = len(by_panel["work"].get("Says working, no agent", []))
    out = []
    for p in PANELS:
        title, q, colour, full = PANEL_META[p]
        parts = []
        if p == "work":
            parts.append(render_work_table(table))
        groups = by_panel[p]
        order = sorted(groups, key=lambda g: (g in FOLDED, g == "Blind spots"))
        for g in order:
            parts.append(render_group(g, groups[g], now, fmt_tokens if p == "tokens" else str))
        if p == "tokens":
            parts.insert(0, render_heaviest(tok))
            if tok:
                t = tok["totals"]
                parts.insert(0, '<p class="small muted">Today so far: %s tokens in %d sessions and %d turns '
                                '(new input %s, cache writes %s, cache reads %s, output %s).</p>'
                             % (fmt_tokens(t["tokens"]), t["sessions"], t["turns"], fmt_tokens(t["input"]),
                                fmt_tokens(t["cache_write"]), fmt_tokens(t["cache_read"]), fmt_tokens(t["output"])))
            parts.append('<p class="small muted">Tokens are all four counts added together. '
                         'This panel shows token counts only.</p>')
        if p == "waste":
            parts.append('<p class="small muted">The board never acts on what it shows. Token counts appear '
                         'on the Tokens panel; it never shows money, remaining allowance, quota or run-out.</p>')
        body = "".join(x for x in parts if x) or '<p class="small muted">Nothing to show.</p>'
        out.append('<section class="panel%s" id="%s" style="--c:%s"><header><h2>%s</h2><span class="q">%s</span>'
                   '</header><div class="pbody">%s</div></section>'
                   % (" full" if full else "", p, colour, e(title), e(q), body))
    built = time.strftime("%H:%M · %d %b %Y", time.localtime(now))
    return ("<!doctype html>\n<html lang=\"en\"><head><meta charset=\"utf-8\">"
            "<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">"
            "<meta http-equiv=\"refresh\" content=\"300\"><title>Fleet Board</title><style>%s</style></head>"
            "<body><main class=\"wrap\"><div class=\"boardhead\"><div><h1>Fleet board</h1>"
            "<div class=\"when\">built %s · rebuilds every 5 min</div></div><div class=\"chips\">"
            "<span class=\"pill p-ok\">%d sources read</span><span class=\"pill p-blind\">%d not set up or not read</span>"
            "<span class=\"pill p-idle\">%d stale or unreadable</span></div></div>"
            "<div class=\"headline\"><span><b>%d</b> decisions need a call</span>"
            "<span><b>%d</b> alerts · <b>%d</b> warnings</span>"
            "<span><b>%d</b> tasks say \"working\" with no agent</span></div>"
            "<div class=\"panels\">%s</div><p class=\"foot\">Read-only page built by bin/fm-board.sh from "
            "published summaries; board.json beside it holds the same items.</p></main></body></html>\n"
            % (CSS, e(built), ok, blind, bad, calls, alerts, warns, no_agent, "".join(out)))


# ---------------------------------------------------------------- main

def atomic_write(path, text):
    tmp = "%s.tmp.%d" % (path, os.getpid())
    with open(tmp, "w", encoding="utf-8") as fh:
        fh.write(text)
    os.replace(tmp, path)


def main(argv=None):
    ap = argparse.ArgumentParser(description="Build the fleet board (use bin/fm-board.sh).")
    ap.add_argument("--home", required=True)
    ap.add_argument("--homes", default=None, help="TSV of area, home, remote flag")
    ap.add_argument("--now", type=int, default=None)
    ap.add_argument("--budget", type=int, default=50, help="seconds for the whole run")
    args = ap.parse_args(argv)
    started = time.monotonic()
    now = args.now if args.now is not None else int(time.time())
    home = os.path.abspath(args.home)
    homes = []
    try:
        listing = read_text(args.homes) if args.homes else ""
    except OSError:
        listing = ""
    for line in listing.splitlines():
        parts = line.split("\t")
        if len(parts) == 3 and parts[0] and parts[1].startswith("/"):
            homes.append((parts[0], parts[1].rstrip("/"), parts[2] == "1"))
    if not homes:
        homes = [("main", home, False)]

    cfg = read_config(home)
    thresholds = dict(DEFAULTS)
    thresholds.update({k: v for k, v in cfg["thresholds"].items() if k in DEFAULTS})
    board = Board(now)
    board.thresholds = thresholds
    for msg in cfg["errors"]:
        board.add("health", "Blind spots", msg, "blind", owner="board")

    summaries = load_summaries(board, homes, thresholds)
    decisions(board, summaries, homes)
    table = health_and_work(board, summaries, homes)
    if cfg["feeds"]:
        load_feeds(board, cfg)
    else:
        board.source("Project feeds", "feed", "board", "not-configured",
                     "No config/board-feeds file lists any feed.")
    load_units(board, cfg)
    for title, words, owner, detail in STATIC_BLIND:
        board.source(title, "static", owner, "not-configured", detail)
        board.items[-1]["title"] = "%s: %s" % (title, words)

    board_dir = os.path.join(home, "state", "board")
    os.makedirs(board_dir, exist_ok=True)
    tok = None
    task_index = {}
    for area, s in summaries.items():
        for ep in s.get("endpoints") or []:
            if isinstance(ep, dict) and isinstance(ep.get("id"), str):
                task_index[ep["id"]] = (area, str(ep.get("kind") or "task"))
    roots = cfg["session_roots"] or [os.path.expanduser("~/.claude-work/projects"),
                                     os.path.expanduser("~/.claude/projects")]
    deadline = started + max(5, args.budget - 8 - (time.monotonic() - started))
    try:
        tok = fm_board_tokens.run(board_dir, now, roots, [(a, h) for a, h, r in homes if not r],
                                  load_spawn_starts(homes), task_index,
                                  {k: v for k, v in cfg["thresholds"].items()
                                   if k in fm_board_tokens.DEFAULT_THRESHOLDS},
                                  os.path.expanduser("~"), cfg["broad_roots"], deadline)
        board.source("Session records", "tokens", "board", "ok")
    except OSError as err:
        board.source("Session records", "tokens", "board", "error",
                     "Token reader failed (%s)." % type(err).__name__)
    tokens_panel(board, tok, table)

    doc = {"schema": SCHEMA, "generated_epoch": now, "home": home, "sources": board.sources,
           "items": board.items,
           "work": table}
    atomic_write(os.path.join(board_dir, "board.json"), json.dumps(doc, indent=1, sort_keys=True) + "\n")
    atomic_write(os.path.join(board_dir, "index.html"), render(board, tok, table))
    print(os.path.join(board_dir, "index.html"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
