"""Incremental, metadata-only token reader for the fleet board (bin/fm-board.sh).

Reads Claude Code session records (one JSON object per line) from the session
roots the board names, one directory level at a time: each root's direct
project folders, their top-level ``*.jsonl`` files, and each session's named
``<session>/subagents/`` folder. It never walks a root recursively, never opens
``tool-results/``, and never reads a home root or ``data/``.

Per file it keeps a byte-offset cursor (device, inode, offset) and today's
aggregates in ``state/board/tokens-cursor.json``; a changed inode or a file
shorter than its cursor resets that file. Only complete lines are consumed.
Usage is counted once per ``message.id``: the parts of a multi-part turn carry
the same usage, so a repeated id replaces rather than adds.

Outputs, both written atomically under ``state/board/``:
- ``tokens.json`` (fm-board-tokens.v1): token counts per area, task, kind and
  session, plus the seven detector rules' counts.
- ``usage/<YYYY-MM-DD>.jsonl``: one fm-usage.v1 row per newly seen message for
  bin/fm-usage-audit.sh (kept 7 days), stamped with that message's own time. A
  file read again after a reset repeats its earlier rows byte for byte.

Nothing here stores or emits transcript content, command text, prompts, hosts
or secrets: only counts, hashes, tool names and rule labels. Paths read by the
Read tool are kept only as hashes. The working directory and branch of a
session are kept in the private cursor for attribution and never emitted. No
money, spend, remaining allowance, quota or run-out figure exists here.
"""

import datetime
import hashlib
import json
import os
import re
import shlex
import time

SCHEMA = "fm-board-tokens.v1"
CURSOR_SCHEMA = "fm-board-token-cursor.v1"
USAGE_KEEP_DAYS = 7

# Detector thresholds; config/board-feeds `threshold <name> <value>` overrides.
DEFAULT_THRESHOLDS = {
    "repeat_min": 3,            # identical tool call seen this many times in a session
    "wait_min": 5,              # wait loops + bare sleeps per session per day
    "reread_min": 3,            # Read of one path this many times ...
    "reread_chars": 20000,      # ... with a result at least this large
    "idle_wake_seconds": 3600,  # gap between main-thread turns that re-writes the cache
    "wait_gap_seconds": 300,    # smaller gaps counted as waits
    "status_chars": 600,        # echo appended to a .status file longer than this
    "context_tokens": 200000,   # last main turn context at least this ...
    "context_turns": 100,       # ... after at least this many turns
}

RULES = [
    ("repeat", "Repeated identical calls"),
    ("wait", "Wait loops and sleeps"),
    ("broad", "Broad searches"),
    ("reread", "Big files read again and again"),
    ("idle_wake", "Long idle, then wake"),
    ("status_prose", "Oversized status lines"),
    ("swollen", "Swollen context"),
]

LOOP_RE = re.compile(r"\b(until|while)\b.*\bsleep\b", re.S)
SLEEP_RE = re.compile(r"(^|[;&\s])sleep\s+\d")
STATUS_RE = re.compile(r">>\s*\S*\.status")
TOOL_NAME_RE = re.compile(r"^[A-Za-z0-9_.:-]{1,64}$")
PENDING_READS_MAX = 256
SEEN_TOOL_IDS_MAX = 512


def _h(text, n=16):
    return hashlib.sha1(text.encode("utf-8", "replace")).hexdigest()[:n]


def _iso_epoch(ts):
    try:
        return int(datetime.datetime.fromisoformat(ts.replace("Z", "+00:00")).timestamp())
    except (ValueError, AttributeError):
        return None


def day_window(now):
    """Local-midnight window start: (YYYY-MM-DD, epoch, UTC ISO prefix)."""
    lt = time.localtime(now)
    start = int(time.mktime((lt.tm_year, lt.tm_mon, lt.tm_mday, 0, 0, 0, 0, 0, -1)))
    iso = datetime.datetime.fromtimestamp(start, datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S")
    return time.strftime("%Y-%m-%d", lt), start, iso


# ---------------------------------------------------------------- broad search

def broad_targets(user_home, home_roots, extra_roots):
    roots = {"/", "/mnt/c", "/home", user_home.rstrip("/") or "/",
             os.path.join(user_home, ".treehouse")}
    for r in list(home_roots) + list(extra_roots):
        r = r.rstrip("/") or "/"
        roots.add(r)
    homes = {r.rstrip("/") for r in home_roots}
    return roots, homes


def _is_broad(path, roots, homes):
    p = path.rstrip("/") or "/"
    if p in roots:
        return True
    return p.endswith("/data") and p[:-5] in homes


def _resolve(arg, cur, user_home, allow_relative_data=True):
    if arg.startswith("~"):
        return user_home + arg[1:]
    if arg in (".", "./"):
        return cur
    if arg.startswith("/"):
        return arg
    if allow_relative_data and arg.rstrip("/").endswith("data"):
        return cur.rstrip("/") + "/" + arg
    return None


def classify_bash(cmd, cwd, user_home, roots, homes):
    """(broad, unbounded) for one shell command; the rule from the tokens report."""
    env = {"HOME": user_home}
    cur = cwd or "/"
    broad = unbounded = False
    for seg in re.split(r"\n|;|&&|\|\||\|", cmd):
        seg = seg.strip()
        m = re.match(r"^([A-Za-z_][A-Za-z0-9_]*)=(\S+)$", seg)
        if m:
            env[m.group(1)] = m.group(2).strip("'\"")
            continue
        seg = re.sub(r"\$\{?([A-Za-z_][A-Za-z0-9_]*)\}?", lambda k: env.get(k.group(1), k.group(0)), seg)
        try:
            w = shlex.split(seg)
        except ValueError:
            w = seg.split()
        while w and (w[0] in ("timeout", "nice", "ionice", "-n", "-c3", "19", "sudo")
                     or re.match(r"^\d+[sm]?$", w[0])):
            w = w[1:]
        if not w:
            continue
        if w[0] == "cd" and len(w) > 1:
            target = _resolve(w[1], cur, user_home, allow_relative_data=False)
            cur = target if target else cur.rstrip("/") + "/" + w[1]
            continue
        verb, args = w[0], w[1:]
        recursive = bounded = False
        if verb == "find":
            recursive, bounded = True, "-maxdepth" in args
        elif verb in ("grep", "egrep") and any(
                a.startswith("-") and not a.startswith("--") and ("r" in a or "R" in a) for a in args):
            recursive = True
        elif verb in ("rg", "du"):
            recursive = True
        elif verb == "ls" and any(a.startswith("-") and "R" in a for a in args):
            recursive = True
        if not recursive:
            continue
        for a in args:
            if a.startswith("-"):
                continue
            target = _resolve(a, cur, user_home)
            if target and _is_broad(target, roots, homes):
                broad = True
                if not bounded:
                    unbounded = True
    return broad, unbounded


# ---------------------------------------------------------------- per-file state

def _new_agg():
    return {
        "first": None, "last": None, "cwd": {}, "branch": {}, "model": {},
        "mids": {},            # message id hash -> [input, cache_write, cache_read, output]
        "main_last_ts": None, "main_last_mid": None, "main_turns": 0,
        "idle_wakes": 0, "idle_wake_cw": 0, "waits": 0,
        "tools": {}, "calls": {}, "reads": {}, "readsize": {}, "pending": {},
        "seen_tools": [],
        "broad": 0, "broad_unbounded": 0, "loops": 0, "sleeps": 0,
        "status_n": 0, "status_long": 0, "status_max": 0,
    }


def _bump(d, key, n=1):
    d[key] = d.get(key, 0) + n


def _top(d):
    return max(d.items(), key=lambda kv: kv[1])[0] if d else ""


class Ctx:
    def __init__(self, day_iso, thresholds, user_home, roots, homes):
        self.day_iso = day_iso
        self.t = thresholds
        self.user_home = user_home
        self.roots = roots
        self.homes = homes
        self.new_rows = {}     # (file key, mid hash) -> [message epoch, wait flag]
        self.reset = set()     # file keys read again from the start this run


def _consume_line(ctx, fkey, st, raw, is_sub):
    if b'"assistant"' not in raw and b'"tool_result"' not in raw:
        return
    try:
        o = json.loads(raw)
    except ValueError:
        return
    if not isinstance(o, dict):
        return
    ts = o.get("timestamp")
    if not isinstance(ts, str) or ts[:19] < ctx.day_iso:
        return
    agg = st["agg"]
    kind = o.get("type")
    msg = o.get("message") if isinstance(o.get("message"), dict) else {}
    if kind == "assistant":
        cwd = o.get("cwd")
        if isinstance(cwd, str) and cwd:
            _bump(agg["cwd"], cwd)
        br = o.get("gitBranch")
        if isinstance(br, str) and br:
            _bump(agg["branch"], br)
        agg["first"] = min(agg["first"] or ts, ts)
        agg["last"] = max(agg["last"] or ts, ts)
        mid = msg.get("id") or o.get("uuid") or ""
        mkey = _h(str(mid))
        u = msg.get("usage") if isinstance(msg.get("usage"), dict) else {}
        usage = [int(u.get(k) or 0) for k in ("input_tokens", "cache_creation_input_tokens",
                                               "cache_read_input_tokens", "output_tokens")]
        new = mkey not in agg["mids"]
        agg["mids"][mkey] = usage
        model = msg.get("model")
        if new and isinstance(model, str) and TOOL_NAME_RE.match(model):
            _bump(agg["model"], model)
        if new:
            ctx.new_rows.setdefault((fkey, mkey), [_iso_epoch(ts), False])
            if not is_sub:
                epoch = _iso_epoch(ts)
                last = agg["main_last_ts"]
                if epoch is not None and last is not None:
                    gap = epoch - last
                    if gap >= ctx.t["idle_wake_seconds"]:
                        agg["idle_wakes"] += 1
                        agg["idle_wake_cw"] += usage[1]
                    elif gap >= ctx.t["wait_gap_seconds"]:
                        agg["waits"] += 1
                if epoch is not None:
                    agg["main_last_ts"] = epoch
                agg["main_turns"] += 1
        if not is_sub:
            agg["main_last_mid"] = mkey if new or agg["main_last_mid"] is None else agg["main_last_mid"]
        for c in msg.get("content") or []:
            if not isinstance(c, dict) or c.get("type") != "tool_use":
                continue
            tid = str(c.get("id") or "")
            if tid:
                th = _h(tid, 12)
                if th in agg["seen_tools"]:
                    continue
                agg["seen_tools"].append(th)
                del agg["seen_tools"][:-SEEN_TOOL_IDS_MAX]
            name = c.get("name") if isinstance(c.get("name"), str) else "?"
            name = name if TOOL_NAME_RE.match(name) else "other"
            inp = c.get("input") if isinstance(c.get("input"), dict) else {}
            _bump(agg["tools"], name)
            _bump(agg["calls"], _h(name + json.dumps(inp, sort_keys=True)) + ":" + name)
            if name == "Read" and isinstance(inp.get("file_path"), str):
                ph = _h(inp["file_path"])
                _bump(agg["reads"], ph)
                if tid:
                    agg["pending"][_h(tid, 12)] = ph
                    while len(agg["pending"]) > PENDING_READS_MAX:
                        agg["pending"].pop(next(iter(agg["pending"])))
            elif name == "Bash" and isinstance(inp.get("command"), str):
                cmd = inp["command"]
                broad, unb = classify_bash(cmd, cwd or "/", ctx.user_home, ctx.roots, ctx.homes)
                agg["broad"] += int(broad)
                agg["broad_unbounded"] += int(unb)
                if LOOP_RE.search(cmd):
                    agg["loops"] += 1
                    if (fkey, mkey) in ctx.new_rows:
                        ctx.new_rows[(fkey, mkey)][1] = True
                elif SLEEP_RE.search(cmd):
                    agg["sleeps"] += 1
                    if (fkey, mkey) in ctx.new_rows:
                        ctx.new_rows[(fkey, mkey)][1] = True
                if STATUS_RE.search(cmd) and "echo" in cmd:
                    agg["status_n"] += 1
                    agg["status_max"] = max(agg["status_max"], len(cmd))
                    if len(cmd) > ctx.t["status_chars"]:
                        agg["status_long"] += 1
            elif name in ("Grep", "Glob"):
                path = inp.get("path") if isinstance(inp.get("path"), str) else (cwd or "")
                target = _resolve(path, cwd or "/", ctx.user_home) if path else None
                if target and _is_broad(target, ctx.roots, ctx.homes):
                    agg["broad"] += 1
                    agg["broad_unbounded"] += 1
    elif kind == "user":
        content = msg.get("content")
        if not isinstance(content, list):
            return
        for c in content:
            if not isinstance(c, dict) or c.get("type") != "tool_result":
                continue
            ph = agg["pending"].pop(_h(str(c.get("tool_use_id") or ""), 12), None)
            if ph is None:
                continue
            cc = c.get("content")
            if isinstance(cc, str):
                size = len(cc)
            else:
                size = sum(len(x.get("text", "")) for x in cc or [] if isinstance(x, dict)
                           and isinstance(x.get("text", ""), str))
            agg["readsize"][ph] = max(agg["readsize"].get(ph, 0), size)


def _read_file(ctx, fkey, st, path, is_sub, deadline):
    """Consume complete appended lines; returns (bytes read, finished)."""
    read = 0
    with open(path, "rb") as fh:
        fh.seek(st["offset"])
        while True:
            if time.monotonic() > deadline:
                return read, False
            chunk = fh.read(4 * 1024 * 1024)
            if not chunk:
                return read, True
            cut = chunk.rfind(b"\n")
            if cut < 0:
                if len(chunk) < 4 * 1024 * 1024:
                    return read, True  # incomplete tail; wait for its newline
                # one line longer than a chunk: extend until its newline
                more = chunk
                while cut < 0:
                    nxt = fh.read(4 * 1024 * 1024)
                    if not nxt:
                        return read, True
                    base = len(more)
                    more += nxt
                    pos = nxt.find(b"\n")
                    cut = base + pos if pos >= 0 else -1
                chunk = more
            body = chunk[:cut + 1]
            for raw in body.split(b"\n"):
                if raw:
                    _consume_line(ctx, fkey, st, raw, is_sub)
            st["offset"] += len(body)
            read += len(body)
            fh.seek(st["offset"])


# ---------------------------------------------------------------- discovery

def discover(session_roots, day_start):
    """(path, parent session stem, is_sub) for session files touched today."""
    out = []
    for root in session_roots:
        try:
            projects = sorted(os.listdir(root))
        except OSError:
            continue
        for proj in projects:
            pdir = os.path.join(root, proj)
            try:
                entries = list(os.scandir(pdir))
            except OSError:
                continue
            for e in entries:
                try:
                    if not (e.name.endswith(".jsonl") and e.is_file(follow_symlinks=False)):
                        continue
                    if e.stat(follow_symlinks=False).st_mtime < day_start:
                        continue
                except OSError:
                    continue
                stem = e.name[:-6]
                out.append((e.path, stem, False))
                sub = os.path.join(pdir, stem, "subagents")
                try:
                    subs = list(os.scandir(sub))
                except OSError:
                    continue
                for s in subs:
                    try:
                        if (s.name.endswith(".jsonl") and s.is_file(follow_symlinks=False)
                                and s.stat(follow_symlinks=False).st_mtime >= day_start):
                            out.append((s.path, stem, True))
                    except OSError:
                        continue
    return out


# ---------------------------------------------------------------- attribution

def attribute(cwd, branch, first_epoch, areas, starts, task_index):
    """-> (area, task, kind, how). ``areas`` is [(area, home root)]."""
    for area, root in areas:
        if cwd == root:
            return area, area + " supervisor", "supervisor", "home root"
    root_area = {root: area for area, root in areas}
    matched = [s for s in starts if s.get("worktree") == cwd]
    if matched:
        ok = [s for s in matched if isinstance(s.get("spawn_epoch"), int)
              and (first_epoch is None or s["spawn_epoch"] <= first_epoch + 120)]
        if ok:
            s = max(ok, key=lambda r: r["spawn_epoch"])
            area = root_area.get(s.get("home"), "other")
            return area, str(s.get("task")), str(s.get("kind") or "task"), "spawn record"
    if branch.startswith("fm/"):
        task = branch[3:]
        if task in task_index:
            area, kind = task_index[task]
            return area, task, kind, "task branch"
    for area, root in areas:
        if cwd.startswith(root + "/"):
            return area, "(in " + area + ", no task record)", "no task record", "under home"
    if "/.no-mistakes/" in cwd:
        return "pipeline", "(validation pipeline)", "pipeline", "pipeline copy"
    return "other", "(unattributed)", "unknown", "none"


# ---------------------------------------------------------------- main entry

def _atomic_write(path, data):
    tmp = "%s.tmp.%d" % (path, os.getpid())
    with open(tmp, "w", encoding="utf-8") as fh:
        fh.write(data)
    os.replace(tmp, path)


def _load_cursor(path, day):
    try:
        with open(path, encoding="utf-8") as fh:
            cur = json.load(fh)
        if cur.get("schema") != CURSOR_SCHEMA or not isinstance(cur.get("files"), dict):
            raise ValueError
    except (OSError, ValueError):
        return {"schema": CURSOR_SCHEMA, "day": day, "files": {}}
    if cur.get("day") != day:
        for st in cur["files"].values():
            st["agg"] = _new_agg()
        cur["day"] = day
    return cur


def run(board_dir, now, session_roots, areas, starts, task_index, thresholds, user_home,
        extra_broad_roots, deadline):
    """Read appended session lines, write tokens.json and usage rows; return the summary."""
    t = dict(DEFAULT_THRESHOLDS)
    t.update(thresholds or {})
    day, day_start, day_iso = day_window(now)
    roots, homes = broad_targets(user_home, [r for _, r in areas], extra_broad_roots)
    ctx = Ctx(day_iso, t, user_home, roots, homes)
    cursor_path = os.path.join(board_dir, "tokens-cursor.json")
    cur = _load_cursor(cursor_path, day)
    files = discover(session_roots, day_start)
    seen = set()
    stats = {"files": len(files), "read": 0, "behind": 0, "unreadable": 0, "bytes_read": 0,
             "reset": 0}
    todo = []
    for path, stem, is_sub in files:
        fkey = _h(path)
        seen.add(fkey)
        try:
            sb = os.stat(path)
        except OSError:
            stats["unreadable"] += 1
            continue
        st = cur["files"].get(fkey)
        if st is None or st.get("dev") != sb.st_dev or st.get("ino") != sb.st_ino or sb.st_size < st.get("offset", 0):
            if st is not None:
                stats["reset"] += 1
                ctx.reset.add(fkey)
            st = {"dev": sb.st_dev, "ino": sb.st_ino, "offset": 0, "agg": _new_agg()}
            cur["files"][fkey] = st
        st["session"] = _h(stem, 12)
        st["sub"] = is_sub
        todo.append((sb.st_size - st["offset"], path, fkey, st, is_sub))
    for fkey in [k for k in cur["files"] if k not in seen]:
        del cur["files"][fkey]
    for _, path, fkey, st, is_sub in sorted(todo, key=lambda x: x[0]):
        try:
            n, finished = _read_file(ctx, fkey, st, path, is_sub, deadline)
        except OSError:
            stats["unreadable"] += 1
            continue
        stats["bytes_read"] += n
        stats["read"] += 1
        if not finished:
            stats["behind"] += 1

    summary = _summarize(cur, t, day, now, stats, areas, starts, task_index)
    _write_usage(board_dir, now, day, ctx, cur, summary)
    _atomic_write(cursor_path, json.dumps(cur, separators=(",", ":")))
    _atomic_write(os.path.join(board_dir, "tokens.json"), json.dumps(summary, indent=1, sort_keys=True))
    return summary


def _summarize(cur, t, day, now, stats, areas, starts, task_index):
    sessions = {}
    for fkey, st in cur["files"].items():
        agg = st["agg"]
        if not agg["mids"]:
            continue
        s = sessions.setdefault(st["session"], {"files": [], "subfiles": 0})
        s["files"].append((st, agg))
        if st.get("sub"):
            s["subfiles"] += 1
    rows = []
    for sid, s in sessions.items():
        main = [a for st, a in s["files"] if not st.get("sub")]
        lead = main[0] if main else s["files"][0][1]
        firsts = [a["first"] for _, a in s["files"] if a["first"]]
        lasts = [a["last"] for _, a in s["files"] if a["last"]]
        first = min(firsts) if firsts else None
        first_epoch = _iso_epoch(first) if first else None
        area, task, kind, how = attribute(_top(lead["cwd"]), _top(lead["branch"]), first_epoch,
                                          areas, starts, task_index)
        tot = [0, 0, 0, 0]
        turns = 0
        calls, tools, reads, readsize, models = {}, {}, {}, {}, {}
        flags = {k: 0 for k in ("broad", "broad_unbounded", "loops", "sleeps", "status_n",
                                "status_long", "status_max", "idle_wakes", "idle_wake_cache_write", "waits")}
        for _, a in s["files"]:
            for u in a["mids"].values():
                for i in range(4):
                    tot[i] += u[i]
            turns += len(a["mids"])
            for d, src in ((calls, a["calls"]), (tools, a["tools"]), (models, a["model"])):
                for k, v in src.items():
                    _bump(d, k, v)
            for k, v in a["reads"].items():
                _bump(reads, k, v)
            for k, v in a["readsize"].items():
                readsize[k] = max(readsize.get(k, 0), v)
            for k in ("broad", "broad_unbounded", "loops", "sleeps", "status_n", "status_long",
                      "idle_wakes", "waits"):
                flags[k] += a[k]
            flags["status_max"] = max(flags["status_max"], a["status_max"])
            flags["idle_wake_cache_write"] += a["idle_wake_cw"]
        rep = [c for c in calls.values() if c >= t["repeat_min"]]
        rep_tools = {}
        for k, c in calls.items():
            if c >= t["repeat_min"]:
                _bump(rep_tools, k.split(":", 1)[1], c - 1)
        big = [(n, readsize.get(k, 0)) for k, n in reads.items()
               if n >= t["reread_min"] and readsize.get(k, 0) >= t["reread_chars"]]
        ctx_now = 0
        main_turns = sum(a["main_turns"] for a in main)
        if main and main[0]["main_last_mid"] in main[0]["mids"]:
            u = main[0]["mids"][main[0]["main_last_mid"]]
            ctx_now = u[0] + u[1] + u[2]
        flags.update({
            "repeat_groups": len(rep), "repeat_extra": sum(c - 1 for c in rep),
            "repeat_max": max(rep) if rep else 0, "repeat_by_tool": rep_tools,
            "rereads_big": len(big), "rereads_big_chars": sum((n - 1) * sz for n, sz in big),
            "context_swollen": int(ctx_now >= t["context_tokens"] and main_turns >= t["context_turns"]),
        })
        rule_hits = {
            "repeat": flags["repeat_extra"],
            "wait": (flags["loops"] + flags["sleeps"]) if flags["loops"] + flags["sleeps"] >= t["wait_min"] else 0,
            "broad": flags["broad"],
            "reread": flags["rereads_big"],
            "idle_wake": flags["idle_wakes"],
            "status_prose": flags["status_long"],
            "swollen": flags["context_swollen"],
        }
        rows.append({
            "session": sid, "area": area, "task": task, "kind": kind, "how": how,
            "model": _top(models), "first_epoch": first_epoch,
            "last_epoch": _iso_epoch(max(lasts)) if lasts else None,
            "turns": turns, "input": tot[0], "cache_write": tot[1], "cache_read": tot[2],
            "output": tot[3], "tokens": sum(tot), "context_now": ctx_now,
            "subagent_files": s["subfiles"], "tools": tools, "flags": flags, "rules": rule_hits,
        })
    rows.sort(key=lambda r: (-r["tokens"], r["session"]))

    def group(keyf):
        out = {}
        for r in rows:
            k = keyf(r)
            g = out.setdefault(k, {"tokens": 0, "sessions": 0, "turns": 0})
            g["tokens"] += r["tokens"]
            g["sessions"] += 1
            g["turns"] += r["turns"]
        return out

    by_area = [dict(area=k, **v) for k, v in group(lambda r: r["area"]).items()]
    by_kind = [dict(kind=k, **v) for k, v in group(lambda r: r["kind"]).items()]
    by_task = [dict(area=k[0], task=k[1], kind=k[2], **v)
               for k, v in group(lambda r: (r["area"], r["task"], r["kind"])).items()]
    for lst in (by_area, by_kind, by_task):
        lst.sort(key=lambda g: -g["tokens"])
    rules = []
    for key, label in RULES:
        hit = [r for r in rows if r["rules"][key]]
        rules.append({"rule": key, "label": label, "sessions": len(hit),
                      "count": sum(r["rules"][key] for r in hit)})
    totals = {k: sum(r[k] for r in rows) for k in ("input", "cache_write", "cache_read", "output",
                                                    "tokens", "turns")}
    totals["sessions"] = len(rows)
    return {"schema": SCHEMA, "generated_epoch": int(now), "day": day, "thresholds": t,
            "files": stats, "totals": totals, "by_area": by_area, "by_kind": by_kind,
            "by_task": by_task, "rules": rules, "sessions": rows}


def _write_usage(board_dir, now, day, ctx, cur, summary):
    udir = os.path.join(board_dir, "usage")
    os.makedirs(udir, exist_ok=True)
    keep = time.strftime("%Y-%m-%d", time.localtime(now - USAGE_KEEP_DAYS * 86400))
    for name in os.listdir(udir):
        if name.endswith(".jsonl") and name[:10] < keep:
            try:
                os.remove(os.path.join(udir, name))
            except OSError:
                pass
    if not ctx.new_rows:
        return
    role_of = {}
    for r in summary["sessions"]:
        role = re.sub(r"[^A-Za-z0-9_.-]", "-", "%s.%s" % (r["area"], r["kind"]))[:128]
        role_of[r["session"]] = role
    path = os.path.join(udir, day + ".jsonl")
    prior = {}
    if any(fkey in ctx.reset for fkey, _ in ctx.new_rows):
        try:
            with open(path, encoding="utf-8") as fh:
                for line in fh:
                    try:
                        prior.setdefault(json.loads(line)["id"], line.rstrip("\n"))
                    except (ValueError, KeyError, TypeError):
                        continue
        except OSError:
            pass
    lines = []
    for (fkey, mkey), (ts, waiting) in ctx.new_rows.items():
        st = cur["files"].get(fkey)
        if not st or mkey not in st["agg"]["mids"]:
            continue
        if fkey + "." + mkey in prior:
            lines.append(prior[fkey + "." + mkey])
            continue
        u = st["agg"]["mids"][mkey]
        lines.append(json.dumps({
            "schema": "fm-usage.v1", "id": fkey + "." + mkey,
            "role": role_of.get(st["session"], "other.unknown"), "ts": ts or int(now),
            "input_tokens": u[0] + u[1] + u[2], "output_tokens": u[3],
            "cached_input_tokens": u[2], "context_tokens": u[0] + u[1] + u[2],
            "cycle_kind": "wait-renewal" if waiting else "unknown",
        }, sort_keys=True))
    with open(path, "a", encoding="utf-8") as fh:
        fh.write("".join(line + "\n" for line in lines))
