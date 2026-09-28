#!/usr/bin/env bash
# Fleet board: source mappings and blind spots, mirrored-hold judgement, work
# classification, the token reader's seven detector rules, attribution in a
# reused copy, the incremental cursor, privacy of every output, and the
# systemd timer install under a fake HOME with a fake systemctl.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-board)
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
cat > "$FAKEBIN/systemctl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${FAKE_SYSTEMCTL_LOG:?}"
case "$*" in
  *"show fake.service"*) printf 'LoadState=loaded\nActiveState=inactive\nResult=success\nExecMainStatus=0\n' ;;
  *"show broken.service"*) printf 'LoadState=loaded\nActiveState=failed\nResult=exit-code\nExecMainStatus=1\n' ;;
  *show*) printf 'LoadState=not-found\n' ;;
esac
exit 0
EOF
chmod +x "$FAKEBIN/systemctl"
export FAKE_SYSTEMCTL_LOG="$TMP_ROOT/systemctl.log"
export HOME="$TMP_ROOT/fakehome" XDG_CONFIG_HOME="$TMP_ROOT/fakehome/.config"
export PATH="$FAKEBIN:$PATH" TZ=UTC
mkdir -p "$HOME"

python3 - "$ROOT" "$TMP_ROOT" <<'PY'
import hashlib
import json
import os
import re
import subprocess
import sys
from pathlib import Path

root, tmp = Path(sys.argv[1]), Path(sys.argv[2])
NOW = 1790600000
DAY0 = NOW - NOW % 86400
MARKERS = ["SECRET-CMD-MARKER", "SECRET-PROMPT-MARKER", "SECRET-RESULT-MARKER", "secret-read-path"]


def ok(msg):
    print("ok - " + msg)


def iso(epoch):
    import datetime
    return datetime.datetime.fromtimestamp(epoch, datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.000Z")


def write_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value))


main = tmp / "main"
mate_a, mate_b, mate_c, mate_d = tmp / "mate-a", tmp / "mate-b", tmp / "mate-c", tmp / "mate-d"
for h in (main, mate_a, mate_b, mate_c, mate_d):
    (h / "state").mkdir(parents=True)
(main / "data").mkdir()
(main / "config").mkdir()
(main / "data" / "secondmates.md").write_text("\n".join([
    "# Second mates", "",
    "- mate-a - Tooling work (home: %s; scope: tooling; projects: none; added 2026-09-01)" % mate_a,
    "- mate-b - Old summary (home: %s; scope: old; projects: none; added 2026-09-01)" % mate_b,
    "- mate-c - Future summary (home: %s; scope: new; projects: none; added 2026-09-01)" % mate_c,
    "- mate-d - Quiet summary (home: %s; scope: quiet; projects: none; added 2026-09-01)" % mate_d,
    "- mate-gone - No summary (home: %s; scope: gone; projects: none; added 2026-09-01)" % (tmp / "gone"),
    "- far - Remote (host: box; root: /r; home: /r/h; scope: far; projects: none; added 2026-09-01)",
    ""]))


def summary(**kw):
    base = {"schema": "fm-secondmate-home-summary.v1", "generated_epoch": NOW - 60, "valid": True,
            "reason": None, "decisions_open": [], "queued": [], "endpoints": [], "omitted": [],
            "counts": {"queued": 0}}
    base.update(kw)
    return base


write_json(main / "state" / "home-summary.json", summary(
    supervision={"state": "healthy", "reason": None},
    counts={"queued": 3},
    omitted=[{"surface": "endpoints", "count": 5}, {"surface": "decisions_open", "count": 2}],
    decisions_open=[
        {"id": "mate-a", "key": "captain-hold-live-call-1", "verb": "needs-decision",
         "summary": "live mirror", "source": "status", "for": "captain"},
        {"id": "mate-a", "key": "captain-hold-later-call-1", "verb": "needs-decision",
         "summary": "deferred mirror", "source": "status", "for": "captain"},
        {"id": "mate-a", "key": "captain-hold-done-call-2", "verb": "needs-decision",
         "summary": "answered mirror", "source": "status", "for": "captain"},
        {"id": "mate-a", "key": "report-1", "verb": "needs-decision",
         "summary": "cross-area report", "source": "status", "for": "supervisor"},
        {"id": "t-main", "key": "default", "verb": "needs-decision", "summary": "main own call",
         "source": "status", "for": "captain", "opened_at_epoch": NOW - 3600, "age_seconds": 3600},
    ],
    endpoints=[
        {"id": "t-work", "state": "working", "kind": "ship", "title": "Working task",
         "endpoint": {"exists": True, "agent_alive": "not_checked", "status": "unknown"},
         "last_event": {"state": "working", "age_seconds": 120}},
        {"id": "t-ghost", "state": "working", "kind": "ship", "title": "Ghost task",
         "endpoint": {"exists": False, "agent_alive": "not_checked", "status": "absent"},
         "last_event": {"state": "working", "age_seconds": 7200}},
        {"id": "t-park", "state": "parked", "kind": "scout", "title": "Parked task",
         "endpoint": {"exists": False, "agent_alive": "not_checked", "status": "absent"},
         "last_event": {"state": "paused", "age_seconds": 600}},
        {"id": "t-done", "state": "done", "kind": "ship", "title": "Finished task",
         "endpoint": {"exists": True, "agent_alive": "not_checked", "status": "unknown"},
         "last_event": {"state": "done", "age_seconds": 30}},
        {"id": "mate-a", "state": "parked", "kind": "secondmate",
         "endpoint": {"exists": False, "agent_alive": "dead", "status": "absent"}},
    ]))
write_json(mate_a / "state" / "home-summary.json", summary(
    valid=False, reason="live child state has no in-flight backlog item",
    supervision={"state": "down", "reason": "no-beacon"},
    decisions_open=[{"id": "live-call", "key": "live-call", "verb": "captain-hold", "source": "backlog",
                     "for": "captain", "summary": "Live call", "opened_at_epoch": NOW - 86400}],
    queued=[{"id": "later-call", "title": "Later call", "hold_bucket": "dated", "hold_until": "2026-12-31"}]))
write_json(mate_b / "state" / "home-summary.json", summary(
    generated_epoch=NOW - 100000, supervision={"state": "unknown", "reason": "no-watcher"}))
write_json(mate_d / "state" / "home-summary.json", summary(
    generated_epoch=NOW - 1800, supervision={"state": "healthy", "reason": "supervised"}))
write_json(mate_c / "state" / "home-summary.json", summary(schema="fm-secondmate-home-summary.v9"))

# Project feeds, one per mapper plus the missing, stale and unknown-version cases.
feeds = tmp / "feeds"
feeds.mkdir()
write_json(feeds / "queue.json", {"schema": "tetjet-queue-snapshot.v1", "generated_at": iso(NOW - 30),
                                  "machine": {"runs_live": 0},
                                  "jobs": [{"state": "released"}] * 3 + [{"state": "ended_closeout"}]})
write_json(feeds / "old-queue.json", {"schema": "tetjet-queue-snapshot.v1", "generated_at": iso(NOW - 9999),
                                      "jobs": []})
(feeds / "queue.log").write_text("\n".join([
    "HANDOFF %s home=a task=one branch=fm/one head=aaa" % iso(NOW - 7200),
    "HANDOFF %s home=a task=two branch=fm/two head=bbb" % iso(NOW - 600),
    "RESULT %s head=bbb outcome=taken main=-" % iso(NOW - 500),
    "RESULT %s head=bbb outcome=landed main=ccc" % iso(NOW - 400),
    "HANDOFF %s home=a task=three branch=fm/three head=ddd" % iso(NOW - 300),
    "HANDOFF %s home=a task=three branch=fm/three head=eee" % iso(NOW - 200),
    ""]))
(feeds / "OVERVIEW.md").write_text("# Hypotheses\n\n| Running | Ready to test | Open after a result | Want to test "
                                   "| Settled | Dropped |\n|---|---|---|---|---|---|\n| 3 | 0 | 7 | 82 | 4 | 0 |\n")
write_json(feeds / "items.json", {"schema": "fm-board-items.v1", "generated_epoch": NOW - 10, "items": [
    {"panel": "health", "group": "Data store", "title": "Data audit clean", "state": "ok", "owner": "data"}]})
(main / "config" / "board-feeds").write_text("\n".join([
    "# name path version max_age owner [link]",
    "feed queue %s tetjet-queue-snapshot.v1 900 tetjet" % (feeds / "queue.json"),
    "feed old-queue %s tetjet-queue-snapshot.v1 900 tetjet" % (feeds / "old-queue.json"),
    "feed train %s merge-queue-log.v1 0 research" % (feeds / "queue.log"),
    "feed hypotheses %s hypotheses-overview.v1 0 research https://example.invalid/h" % (feeds / "OVERVIEW.md"),
    "feed store %s fm-board-items.v1 900 data" % (feeds / "items.json"),
    "feed absent %s fm-board-items.v1 900 absent-owner" % (feeds / "nope.json"),
    "feed future %s nope.v1 900 future-owner" % (feeds / "items.json"),
    "threshold context_tokens 1000",
    "threshold context_turns 3",
    "session_root %s" % (tmp / "sessions"),
    "unit fake.service jobs-owner",
    "unit broken.service jobs-owner",
    "unit missing.service gone-owner",
    ""]))

# ---------------------------------------------------------------- session fixtures
sessions = tmp / "sessions"
worktree = tmp / "pool" / "copy-1"
(main / "state" / "spawn-starts.jsonl").write_text(
    json.dumps({"schema": "fm-spawn-start.v1", "task": "old-task", "kind": "scout", "home": str(main),
                "worktree": str(worktree), "spawn_epoch": DAY0 + 1000}) + "\n"
    + json.dumps({"schema": "fm-spawn-start.v1", "task": "new-task", "kind": "ship", "home": str(main),
                  "worktree": str(worktree), "spawn_epoch": DAY0 + 20000}) + "\n")


MESSAGE_TIMES = {}  # fm-usage.v1 id -> the message's own epoch, for every message written today


class Session:
    def __init__(self, stem, cwd, branch="main", project="proj", start=DAY0 + 3600, sub_of=None):
        self.stem, self.cwd, self.branch, self.t = stem, str(cwd), branch, start
        folder = sessions / project
        self.path = (folder / sub_of / "subagents" / (stem + ".jsonl")) if sub_of else folder / (stem + ".jsonl")
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self.lines = []
        self.n = 0

    def turn(self, usage=(1, 0, 0, 1), tools=(), gap=10, mid=None, results=()):
        self.t += gap
        self.n += 1
        mid = mid or "%s-m%d" % (self.stem, self.n)
        if self.t >= DAY0:
            MESSAGE_TIMES.setdefault(hashlib.sha1(str(self.path).encode()).hexdigest()[:16] + "."
                                     + hashlib.sha1(mid.encode()).hexdigest()[:16], self.t)
        content = [{"type": "text", "text": "SECRET-PROMPT-MARKER reply"}]
        for i, (name, inp) in enumerate(tools):
            content.append({"type": "tool_use", "id": "%s-t%d" % (mid, i), "name": name, "input": inp})
        self.lines.append({"type": "assistant", "timestamp": iso(self.t), "cwd": self.cwd,
                           "gitBranch": self.branch, "sessionId": self.stem,
                           "message": {"id": mid, "model": "claude-test", "content": content,
                                       "usage": {"input_tokens": usage[0], "cache_creation_input_tokens": usage[1],
                                                 "cache_read_input_tokens": usage[2], "output_tokens": usage[3]}}})
        for i, text in results:
            self.lines.append({"type": "user", "timestamp": iso(self.t + 1), "cwd": self.cwd,
                               "message": {"content": [{"type": "tool_result", "tool_use_id": "%s-t%d" % (mid, i),
                                                        "content": text}]}})
        self.lines.append({"type": "user", "timestamp": iso(self.t + 2), "cwd": self.cwd,
                           "message": {"content": "SECRET-PROMPT-MARKER next"}})
        return mid

    def save(self):
        self.path.write_text("".join(json.dumps(x) + "\n" for x in self.lines))


def sh(cmd):
    return ("Bash", {"command": cmd})


# Rule 1: repeated identical calls, plus a multi-part turn written twice.
rep = Session("s-repeat", main)
m = rep.turn(usage=(100, 10, 1000, 5))
rep.lines.append(dict(rep.lines[-2]))  # the multi-part duplicate carries the same id and usage
for _ in range(3):
    rep.turn(tools=[sh("echo SECRET-CMD-MARKER")])
rep.save()
sub = Session("agent-1", main, sub_of="s-repeat")
sub.turn(usage=(7, 0, 0, 3))
sub.save()
# Rule 2: wait loops and sleeps.
wait = Session("s-wait", main)
for cmd in ("sleep 30", "until test -f x; do sleep 5; done", "sleep 10", "while true; do sleep 1; done", "sleep 9"):
    wait.turn(tools=[sh(cmd)])
wait.save()
# Rule 3: broad searches (one unbounded, one bounded, one Grep tool).
broad = Session("s-broad", main)
broad.turn(tools=[sh("find / -name SECRET-CMD-MARKER")])
broad.turn(tools=[sh("find ~ -maxdepth 1 -name x")])
broad.turn(tools=[("Grep", {"pattern": "x", "path": str(main / "data")})])
broad.turn(tools=[sh("grep -n x ./file")])
broad.save()
# Rule 4: the same big file read three times.
reread = Session("s-reread", main)
for _ in range(3):
    reread.turn(tools=[("Read", {"file_path": "/x/secret-read-path.md"})],
                results=[(0, "SECRET-RESULT-MARKER" + "y" * 20000)])
reread.save()
# Rule 5: long idle, then wake (the waking turn re-writes 777 cache tokens).
idle = Session("s-idle", main)
idle.turn()
idle.turn(gap=400)
idle.turn(usage=(1, 777, 0, 1), gap=4000)
idle.save()
# Rule 6: an oversized status line.
prose = Session("s-prose", main)
prose.turn(tools=[sh("echo 'SECRET-CMD-MARKER %s' >> state/t.status" % ("z" * 700))])
prose.turn(tools=[sh("echo 'short' >> state/t.status")])
prose.save()
# Rule 7: swollen context (threshold lowered to 1000 tokens after 3 turns).
swollen = Session("s-swollen", main)
for _ in range(3):
    swollen.turn(usage=(10, 100, 1000, 1))
swollen.save()
# Attribution: one reused copy served two tasks; a session before either
# spawn falls back to its task branch.
s_old = Session("s-old", worktree, branch="fm/old-task", start=DAY0 + 1100)
s_old.turn(usage=(5, 0, 0, 0))
s_old.save()
s_new = Session("s-new", worktree, branch="fm/new-task", start=DAY0 + 20100)
s_new.turn(usage=(6, 0, 0, 0))
s_new.save()
s_branch = Session("s-branch", tmp / "elsewhere", branch="fm/t-work", start=DAY0 + 50)
s_branch.turn(usage=(4, 0, 0, 0))
s_branch.save()
s_pipe = Session("s-pipe", tmp / ".no-mistakes" / "wt", start=DAY0 + 50)
s_pipe.turn(usage=(3, 0, 0, 0))
s_pipe.save()
s_yday = Session("s-yday", main, start=DAY0 - 7200)
s_yday.turn(usage=(999, 0, 0, 0))
s_yday.save()
# A tool-results folder is never opened.
(sessions / "proj" / "s-repeat" / "tool-results").mkdir(parents=True)
(sessions / "proj" / "s-repeat" / "tool-results" / "x.jsonl").write_text("not json SECRET-RESULT-MARKER\n")


def build():
    p = subprocess.run([str(root / "bin/fm-board.sh"), "--home", str(main), "--now", str(NOW)],
                       text=True, capture_output=True, timeout=120)
    assert p.returncode == 0, p.stderr
    board = json.loads((main / "state/board/board.json").read_text())
    tokens = json.loads((main / "state/board/tokens.json").read_text())
    return board, tokens


def sid(stem):
    return hashlib.sha1(stem.encode()).hexdigest()[:12]


def audit_usage(day):
    p = subprocess.run([str(root / "bin/fm-usage-audit.sh"), "--home", str(main), "--usage",
                        "state/board/usage/%s.jsonl" % day], text=True, capture_output=True, timeout=60)
    assert p.returncode == 0, p.stderr
    return json.loads(p.stdout)


board, tokens = build()
items = board["items"]
src = {s["name"]: s for s in board["sources"]}


def find(**kw):
    return [i for i in items if all(i.get(k) == v for k, v in kw.items())]


# ---------------------------------------------------------------- sources and blind spots
expect = {"main summary": "ok", "mate-a summary": "ok", "mate-b summary": "stale",
          "mate-c summary": "unknown-version", "mate-d summary": "ok", "mate-gone summary": "missing",
          "far summary": "not-read",
          "queue": "ok", "old-queue": "stale", "train": "ok", "hypotheses": "ok", "store": "ok",
          "absent": "missing", "future": "unknown-version", "scheduled job fake.service": "ok",
          "scheduled job missing.service": "missing", "Session records": "ok",
          "Spawn admission verdict": "not-configured", "Heavy slot status": "not-configured",
          "Status volume": "not-configured"}
for name, status in expect.items():
    assert src.get(name, {}).get("status") == status, (name, src.get(name))
blind = find(panel="health", group="Blind spots")
for name, status in expect.items():
    if status != "ok":
        owner = src[name]["owner"]
        assert any(i["title"].startswith(name + ":") and i["owner"] == owner for i in blind), name
ok("every missing, stale, unknown-version or unread source is a blind-spot line naming it and its owner")

for i in items:
    assert set(i) - {"value", "view"} == {"panel", "group", "title", "state", "since", "owner", "link", "detail"}, i
    assert i["panel"] in ("decisions", "health", "work", "pipeline", "waste", "tokens"), i
ok("every item uses the single item shape")

# ---------------------------------------------------------------- decisions (F3, F4)
calls = [i["title"] for i in find(panel="decisions", group="Needs a call now")]
assert "Live call" in calls and "main own call" in calls, calls
assert "live mirror" not in calls and "deferred mirror" not in calls and "answered mirror" not in calls, calls
assert find(panel="decisions", title="Live call")[0]["owner"] == "mate-a"
answered = find(panel="decisions", group="Answered, not yet closed by the owner")
assert [i["title"] for i in answered] == ["answered mirror"], answered
parked = find(panel="decisions", group="Parked on purpose")
assert parked and parked[0]["title"] == "Later call" and "2026-12-31" in parked[0]["detail"], parked
ok("a mirrored captain hold is judged by its owner: live counted once, deferred parked, answered shown apart")
sup = find(panel="decisions", group="Waiting on a supervisor")
assert [i["title"] for i in sup] == ["cross-area report"], sup
assert find(title="main own call")[0]["since"] == NOW - 3600
ok("supervisor questions stay out of the captain's calls and a call carries its opening time")
cut = find(panel="decisions", group="Not listed by the summary")
assert [(i["title"], i["owner"]) for i in cut] == [("2 more open items in main", "main")], cut
ok("open items cut by the summary's bounds get their own label, not a supervisor wait")

# ---------------------------------------------------------------- health and work (F1, F2)
assert find(panel="health", title="main: monitoring running", state="ok")
assert find(panel="health", title="mate-a: monitoring down", state="bad")
assert find(panel="health", title="mate-a summary marks itself incomplete", state="warn")
assert find(panel="health", title="Second mate mate-a is not running", state="bad")
ok("health shows each area's monitoring verdict and an incomplete summary without hiding its tasks")
quiet = find(panel="health", title="mate-d: monitoring unconfirmed", state="blind")
assert quiet and "30 min" in quiet[0]["detail"], quiet
assert not find(title="mate-d: monitoring running") and not find(title="mate-b: monitoring running")
ok("a healthy verdict from a summary older than its refresh allows shows as unconfirmed, not green")
unknown = find(panel="health", title="mate-b: monitoring verdict unknown", state="blind")
assert unknown and unknown[0]["detail"] == "Reason: no-watcher.", unknown
ok("an unknown monitoring verdict shows the reason its summary publishes")
assert find(panel="work", group="Working", title="Working task")
ghost = find(panel="work", group="Says working, no agent", title="Ghost task")
assert ghost and ghost[0]["since"] == NOW - 7200, ghost
assert find(panel="work", group="Parked, no agent", title="Parked task")
assert [i["title"] for i in find(panel="work", group="Parked, no agent")] == ["Parked task"]
assert [i["title"] for i in find(panel="work", group="Not listed by the summary")] == ["5 more tasks in main"]
assert find(panel="work", group="Empty tabs", title="Finished task")
assert board["work"]["main"] == {"working": 1, "idle": 0, "parked": 2, "empty": 1}, board["work"]
ok("work separates working, working with no agent, parked, empty tabs and tasks the summary cut")

# ---------------------------------------------------------------- feeds and units
bar = [i for i in items if i["panel"] == "pipeline" and i.get("view") == "bar"]
assert {(i["title"], i["value"]) for i in bar} == {("released", 3), ("ended closeout", 1)}, bar
train = find(panel="health", group="Merge train")[0]
assert train["state"] == "warn" and train["title"] == "train: 2 waiting", train
assert {(i["title"], i["value"]) for i in find(panel="pipeline", group="train")} == {("waiting", 2), ("landed today", 1)}
hyp = {i["title"]: i["value"] for i in find(panel="pipeline", group="hypotheses")}
assert hyp == {"running": 3, "ready to test": 0, "open after a result": 7, "want to test": 82,
               "settled": 4, "dropped": 0}, hyp
assert find(panel="health", group="Data store", title="Data audit clean", owner="data")
assert find(panel="health", group="Scheduled jobs", title="fake.service", state="ok")
assert find(panel="health", group="Scheduled jobs", title="broken.service", state="bad")
assert {(i["title"], i["value"]) for i in find(panel="pipeline", group="Queued work per area")} >= {("main", 3)}
ok("feed mappings: queue states, merge train stall and landings, hypothesis counts, owner items, scheduled jobs")

# ---------------------------------------------------------------- tokens: rules and attribution
rows = {r["session"]: r for r in tokens["sessions"]}
r = rows[sid("s-repeat")]
assert (r["input"], r["cache_write"], r["cache_read"], r["output"]) == (100 + 3 + 7, 10, 1000, 5 + 3 + 3), r
assert r["turns"] == 5 and r["subagent_files"] == 1, r
assert r["rules"]["repeat"] == 2 and r["flags"]["repeat_by_tool"] == {"Bash": 2}, r["flags"]
ok("usage counts once per message id across a multi-part turn, helper agents join their session")
assert rows[sid("s-wait")]["flags"]["loops"] == 2 and rows[sid("s-wait")]["flags"]["sleeps"] == 3
assert rows[sid("s-wait")]["rules"]["wait"] == 5
f = rows[sid("s-broad")]["flags"]
assert (f["broad"], f["broad_unbounded"]) == (3, 2), f
f = rows[sid("s-reread")]["flags"]
assert (f["rereads_big"], rows[sid("s-reread")]["rules"]["reread"]) == (1, 1), f
f = rows[sid("s-idle")]["flags"]
assert (f["idle_wakes"], f["idle_wake_cache_write"], f["waits"]) == (1, 777, 1), f
f = rows[sid("s-prose")]["flags"]
assert (f["status_n"], f["status_long"]) == (2, 1), f
assert rows[sid("s-swollen")]["rules"]["swollen"] == 1 and rows[sid("s-swollen")]["context_now"] == 1110
assert sum(x["rules"]["swollen"] for x in tokens["sessions"]) == 1
rules = {x["rule"]: x for x in tokens["rules"]}
assert len(rules) == 7 and all(rules[k]["sessions"] >= 1 for k in rules), rules
ok("each of the seven detector rules flags its fixture")
assert (rows[sid("s-old")]["task"], rows[sid("s-old")]["how"]) == ("old-task", "spawn record")
assert (rows[sid("s-new")]["task"], rows[sid("s-new")]["kind"]) == ("new-task", "ship")
assert (rows[sid("s-branch")]["task"], rows[sid("s-branch")]["how"]) == ("t-work", "task branch")
assert rows[sid("s-repeat")]["kind"] == "supervisor" and rows[sid("s-repeat")]["area"] == "main"
assert rows[sid("s-pipe")]["area"] == "pipeline"
assert sid("s-yday") not in rows
by_task = {(g["area"], g["task"]): g["tokens"] for g in tokens["by_task"]}
assert by_task[("main", "old-task")] == 5 and by_task[("main", "new-task")] == 6
ok("a reused copy credits each session to the task spawned before it; branch, home root and pipeline fall back")

# ---------------------------------------------------------------- usage rows feed the audit
day = tokens["day"]
usage = main / "state/board/usage" / (day + ".jsonl")
urows = [json.loads(x) for x in usage.read_text().splitlines()]
assert all(u["schema"] == "fm-usage.v1" and u["cached_input_tokens"] <= u["input_tokens"] for u in urows)
assert len({u["id"] for u in urows}) == len(urows) == sum(x["turns"] for x in tokens["sessions"])
assert any(u["cycle_kind"] == "wait-renewal" for u in urows)
assert {u["id"]: u["ts"] for u in urows} == MESSAGE_TIMES, \
    sorted(set(MESSAGE_TIMES.items()) ^ {(u["id"], u["ts"]) for u in urows})
ok("each fm-usage.v1 row carries its own message's time, not the file's newest")
audit = audit_usage(day)
assert audit["actual_usage"]["available"] is True and not audit["quality"].get("invalid_usage_rows") \
    and not audit["quality"].get("conflicting_usage_ids"), audit["quality"]
ok("fm-usage.v1 rows are written once per message and accepted by the usage audit")

# ---------------------------------------------------------------- privacy
outputs = [x for x in (main / "state/board").rglob("*") if x.is_file()]
names = sorted(str(x.relative_to(main / "state/board")) for x in outputs)
assert names == sorted(["board.json", "index.html", "tokens.json", "tokens-cursor.json",
                        "usage/%s.jsonl" % day]), names
forbidden_key = re.compile(r"cost|spend|price|usd|dollar|money|quota|allowance|remaining|run_?out|reset_at|limit", re.I)


def keys(value):
    if isinstance(value, dict):
        for k, v in value.items():
            yield k
            yield from keys(v)
    elif isinstance(value, list):
        for v in value:
            yield from keys(v)


for x in outputs:
    text = x.read_text()
    for marker in MARKERS:
        assert marker not in text, (x, marker)
    if x.suffix in (".json", ".jsonl"):
        docs = [json.loads(ln) for ln in text.splitlines()] if x.suffix == ".jsonl" else [json.loads(text)]
        bad = [k for d in docs for k in keys(d) if forbidden_key.search(k)]
        assert not bad, (x, bad)
page = (main / "state/board/index.html").read_text()
visible = page.replace("it never shows money, remaining allowance, quota or run-out", "")
assert not re.search(r"\$\s?\d|\bUSD\b|\bquota\b|allowance|run-out|runs out", visible, re.I)
assert "<script" not in page.lower() and 'http-equiv="refresh"' in page
assert "prefers-color-scheme:dark" in page and 'data-theme="dark"' in page
ok("no transcript content, command text, read paths, money or quota field reaches any output")

# ---------------------------------------------------------------- incremental cursor
cur = Session("s-cursor", main)
cur.turn(usage=(10, 0, 0, 1))
cur.save()
_, tokens = build()
assert {r["session"]: r for r in tokens["sessions"]}[sid("s-cursor")]["input"] == 10
cur.turn(usage=(5, 0, 0, 1))
with cur.path.open("a") as fh:
    fh.write("".join(json.dumps(x) + "\n" for x in cur.lines[-2:]))
    fh.write(json.dumps(dict(cur.lines[-2], message=dict(cur.lines[-2]["message"], id="partial")))[:40])
_, tokens = build()
row = {r["session"]: r for r in tokens["sessions"]}[sid("s-cursor")]
assert (row["input"], row["turns"]) == (15, 2), row
assert tokens["files"]["reset"] == 0
ok("an append is read from the cursor, and an unterminated last line waits")
cur.lines = []
cur.turn(usage=(3, 0, 0, 1))
cur.save()  # shorter than the cursor: a rewritten file
_, tokens = build()
row = {r["session"]: r for r in tokens["sessions"]}[sid("s-cursor")]
assert (row["input"], row["turns"]) == (3, 1) and tokens["files"]["reset"] == 1, (row, tokens["files"])
ok("a file shorter than its cursor is read again from the start")
cur.turn(usage=(4, 0, 0, 1))
fresh = cur.path.with_name("replacement.tmp")
fresh.write_text("".join(json.dumps(x) + "\n" for x in cur.lines))
os.replace(fresh, cur.path)  # longer than before, but a different file
_, tokens = build()
row = {r["session"]: r for r in tokens["sessions"]}[sid("s-cursor")]
assert (row["input"], row["turns"]) == (7, 2) and tokens["files"]["reset"] == 1, (row, tokens["files"])
lines = usage.read_text().splitlines()
by_id = {}
for line in lines:
    by_id.setdefault(json.loads(line)["id"], set()).add(line)
assert len(lines) > len(by_id) and all(len(v) == 1 for v in by_id.values()), \
    [v for v in by_id.values() if len(v) > 1]
assert {i: json.loads(next(iter(v)))["ts"] for i, v in by_id.items()} == MESSAGE_TIMES
q = audit_usage(day)["quality"]
assert q.get("duplicate_usage_ids") and not q.get("conflicting_usage_ids"), q
ok("rows written again after a cursor reset are byte-identical, so the audit sees no conflict")
_, tokens = build()
row = {r["session"]: r for r in tokens["sessions"]}[sid("s-cursor")]
assert (row["input"], tokens["files"]["bytes_read"]) == (7, 0), (row, tokens["files"])
ok("a replaced file (new inode) resets its cursor, and an unchanged file reads nothing")
PY

# ---------------------------------------------------------------- scheduled job
: > "$FAKE_SYSTEMCTL_LOG"
out=$("$ROOT/bin/fm-board.sh" install-timer --home "$TMP_ROOT/main") || fail "install-timer failed: $out"
unit_dir="$XDG_CONFIG_HOME/systemd/user"
service="$unit_dir/fm-board.service"
timer="$unit_dir/fm-board.timer"
home_real=$(cd "$TMP_ROOT/main" && pwd -P)
for want in 'Type=oneshot' 'Nice=19' 'IOSchedulingClass=idle' 'MemoryMax=512M' 'TimeoutStartSec=75' \
  "Environment=FM_HOME=$home_real" "ExecStart=/usr/bin/env bash $ROOT/bin/fm-board.sh --home $home_real"; do
  grep -qxF "$want" "$service" || fail "service unit lacks '$want': $(cat "$service")"
done
for want in 'OnUnitActiveSec=5min' 'WantedBy=timers.target'; do
  grep -qxF "$want" "$timer" || fail "timer unit lacks '$want'"
done
grep -qxF -- '--user daemon-reload' "$FAKE_SYSTEMCTL_LOG" || fail "install did not reload the user manager"
grep -qxF -- '--user enable --now fm-board.timer' "$FAKE_SYSTEMCTL_LOG" || fail "install did not enable the timer"
if grep -v -- '^--user ' "$FAKE_SYSTEMCTL_LOG" | grep -q .; then fail "a systemctl call left the user scope"; fi
pass "install-timer writes a niced oneshot service and 5-minute timer for the given home and enables it"
: > "$FAKE_SYSTEMCTL_LOG"
"$ROOT/bin/fm-board.sh" uninstall-timer >/dev/null || fail "uninstall-timer failed"
[ ! -e "$service" ] && [ ! -e "$timer" ] || fail "uninstall-timer left a unit behind"
grep -qxF -- '--user disable --now fm-board.timer' "$FAKE_SYSTEMCTL_LOG" || fail "uninstall did not disable the timer"
pass "uninstall-timer disables the timer and removes both units"
mkdir -p "$TMP_ROOT/bad home"
if "$ROOT/bin/fm-board.sh" install-timer --home "$TMP_ROOT/bad home" >/dev/null 2>&1; then
  fail "install-timer accepted a home a unit file cannot carry"
fi
pass "install-timer refuses a path a unit line cannot carry"
