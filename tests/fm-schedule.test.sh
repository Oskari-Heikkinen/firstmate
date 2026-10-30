#!/usr/bin/env bash
# Scheduled runs: an invalid schedule file is refused and shown, a new schedule
# only records its next slot, a slot fires only once due and files one task
# (a re-run of the same slot is a no-op), a slot whose previous task is still
# open is skipped, a closed run reports its time used and why it was cut short
# up the parent channel, downtime catches up once, two failed runs pause the
# schedule with a blocked line until resume, a main-home schedule reports
# through main's inbox, and the fleet board's Scheduled runs panel shows the
# rows. Temp homes, a fake clock (--now) and a fixed time zone throughout.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found"; exit 0; }
command -v systemd-analyze >/dev/null 2>&1 || { echo "skip: systemd-analyze not found"; exit 0; }
TMP_ROOT=$(fm_test_tmproot fm-schedule)
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
cat > "$FAKEBIN/systemctl" <<'EOF'
#!/usr/bin/env bash
case "$*" in *show*) printf 'LoadState=not-found\n' ;; esac
exit 0
EOF
chmod +x "$FAKEBIN/systemctl"
export HOME="$TMP_ROOT/fakehome" XDG_CONFIG_HOME="$TMP_ROOT/fakehome/.config"
export PATH="$FAKEBIN:$PATH" TZ=Europe/Berlin
mkdir -p "$HOME"
unset FM_HOME FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE TASKS_AXI_FILE

for h in main mate-a; do
  mkdir -p "$TMP_ROOT/$h/state" "$TMP_ROOT/$h/data" "$TMP_ROOT/$h/config/schedules.d"
  fm_test_tasks_toml "$TMP_ROOT/$h/.tasks.toml"
  printf '# Backlog\n\n## In flight\n\n## Queued\n\n## Done\n' > "$TMP_ROOT/$h/data/backlog.md"
done
printf 'mate-a\n' > "$TMP_ROOT/mate-a/.fm-secondmate-home"
printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$TMP_ROOT/main" \
  > "$TMP_ROOT/mate-a/.fm-secondmate-parent"
printf -- '- mate-a - Tooling (home: %s; scope: tooling; projects: none; added 2026-09-01)\n' \
  "$TMP_ROOT/mate-a" > "$TMP_ROOT/main/data/secondmates.md"

python3 - "$ROOT" "$TMP_ROOT" <<'PY'
import datetime
import json
import os
import re
import subprocess
import sys
from pathlib import Path
from zoneinfo import ZoneInfo

root, tmp = Path(sys.argv[1]), Path(sys.argv[2])
main, mate = tmp / "main", tmp / "mate-a"
BERLIN = ZoneInfo("Europe/Berlin")


def ok(msg):
    print("ok - " + msg)


def fail(msg):
    print("not ok - " + msg, file=sys.stderr)
    sys.exit(1)


def check(cond, msg):
    if not cond:
        fail(msg)


def at(y, mo, d, h, mi, tz=BERLIN):
    return int(datetime.datetime(y, mo, d, h, mi, tzinfo=tz).timestamp())


def utc(y, mo, d, h, mi):
    return at(y, mo, d, h, mi, datetime.timezone.utc)


def sched(*args, now=None, rc=0):
    argv = [str(root / "bin/fm-schedule.sh"), *args, "--home", str(main)]
    if now is not None:
        argv += ["--now", str(now)]
    p = subprocess.run(argv, text=True, capture_output=True, timeout=120)
    if rc is not None and p.returncode != rc:
        fail("%s exited %d, wanted %d:\n%s%s" % (" ".join(args), p.returncode, rc, p.stdout, p.stderr))
    return p


def axi(home, *args):
    env = dict(os.environ, FM_HOME=str(home))
    return subprocess.run([str(root / "bin/fm-tasks-axi.sh"), *args], text=True, capture_output=True,
                          env=env, cwd=str(home), timeout=60)


def state_of(home, task):
    p = axi(home, "show", task)
    if p.returncode != 0:
        return None
    for line in p.stdout.splitlines():
        if line.strip().startswith("state:"):
            return line.split(":", 1)[1].strip().strip('"')
    return "?"


def close(home, task):
    p = axi(home, "done", task)
    check(p.returncode == 0 and state_of(home, task) == "done", "could not close %s: %s%s" % (task, p.stdout, p.stderr))


def rec(home, name):
    out = {}
    for line in (home / "state/schedules" / (name + ".run")).read_text().splitlines():
        k, _, v = line.partition("=")
        out[k] = v
    return out


def sched_ids(home):
    return sorted(set(re.findall(r"sched-[a-z0-9-]+-[0-9]{12}", (home / "data/backlog.md").read_text())))


def notes(home):
    d = home / "state/inbox"
    return sorted(p.read_text() for p in d.glob("*.note")) if d.is_dir() else []


def parent_lines():
    p = main / "state/mate-a.status"
    return p.read_text().splitlines() if p.exists() else []


def rows():
    return {r["name"]: r for r in json.loads(sched("list", "--json").stdout)["rows"]}


def write_result(home, name, task, **kw):
    fields = {"schema": "fm-schedule-result/v1", "started": "2026-10-17T00:00:00Z",
              "ended": "2026-10-17T02:00:00Z", "used_seconds": "60", "outcome": "complete",
              "cut_reason": "none", "carried_over": "0", "note": ""}
    fields.update(kw)
    d = home / "data/schedules" / name
    d.mkdir(parents=True, exist_ok=True)
    (d / (task + ".result")).write_text("".join("%s=%s\n" % kv for kv in fields.items()))


# ---------------------------------------------------------------- invalid files
conf_dir = main / "config/schedules.d"
(main / "data/nightly-brief.md").write_text("Run the nightly check.\n")
base = ("schema=fm-schedule/v1\nname=%s\ncalendar=%s\nkind=%s\ntitle=T\n"
        "brief=data/nightly-brief.md\napproval=operator 2026-10-15\n")
(conf_dir / "bad-kind.conf").write_text(base % ("bad-kind", "*-*-* 03:00:00", "deploy"))
(conf_dir / "bad-cal.conf").write_text(base % ("bad-cal", "Funday 25:00", "ship"))
(conf_dir / "extra-key.conf").write_text(base % ("extra-key", "*-*-* 03:00:00", "ship") + "colour=red\n")
p = sched("validate", rc=1)
check("refused" in p.stdout and "kind must be ship or scout" in p.stdout, "bad kind not refused: " + p.stdout)
check("calendar refused" in p.stdout, "bad calendar not refused: " + p.stdout)
check("unknown key colour" in p.stdout, "unknown key not refused: " + p.stdout)
r = rows()
check(all(not r[n]["valid"] and r[n]["display"]["State"] == "refused" for n in ("bad-kind", "bad-cal", "extra-key")),
      "list does not show the refused files: %r" % r)
check("refused" in sched("list").stdout, "the list table does not show refused files")
ok("an invalid schedule file is refused with its reason and shown by validate and list")

# ---------------------------------------------------------------- first scan, not due, due
(mate / "config/weekly-brief.md").write_text("Run the weekly mutation pass.\n")
(mate / "config/schedules.d/weekly.conf").write_text(
    "schema=fm-schedule/v1\nname=weekly\ncalendar=Sat,Sun *-*-* 01:30:00\nkind=ship\n"
    "title=Weekly mutation run\nbrief=config/weekly-brief.md\napproval=operator 2026-10-15T16:01Z\n")
sched("validate", rc=1)
T0 = utc(2026, 10, 16, 12, 0)
SLOT1 = at(2026, 10, 17, 1, 30)
sched("scan", now=T0)
check(rec(mate, "weekly")["next_due"] == str(SLOT1), "first scan did not record Sat 01:30 local: %r" % rec(mate, "weekly"))
check(sched_ids(mate) == [] and notes(mate) == [], "the first scan fired a run")
summary = json.loads((main / "state/schedules/summary.json").read_text())
check(summary["schema"] == "fm-schedule-summary/v1" and any(x["name"] == "weekly" for x in summary["rows"]),
      "scan did not write the summary")
check(sched_ids(main) == [], "a refused file was filed")
ok("a new schedule only records its next slot, in local time")

sched("scan", now=SLOT1 - 60)
check(sched_ids(mate) == [], "a run fired before its slot")
ok("a slot not yet due files nothing")

before = (mate / "state/schedules/weekly.run").read_bytes()
TASK1 = "sched-weekly-202610170130"
sched("scan", now=SLOT1 + 120)
check(sched_ids(mate) == [TASK1] and state_of(mate, TASK1) == "queued", "due slot not filed: %r" % sched_ids(mate))
body = (mate / "data/backlog.md").read_text()
check("captain-approved scheduled run" in body and (TASK1 + ".result") in body
      and "weekly mutation pass" in body, "task body lacks approval, result path or brief: " + body)
n = notes(mate)
check(len(n) == 1 and "Captain-approved scheduled run weekly" in n[0] and TASK1 in n[0], "home not woken: %r" % n)
check(rows()["weekly"]["display"]["State"].startswith("filed"), "list does not show the filed run")
ok("a due slot files one Queued task in the home's backlog and wakes the home's inbox")

sched("scan", now=SLOT1 + 180)
(mate / "state/schedules/weekly.run").write_bytes(before)
sched("scan", now=SLOT1 + 240)
check(sched_ids(mate) == [TASK1] and len(notes(mate)) == 1, "a re-run of the same slot filed twice: %r" % sched_ids(mate))
check(rec(mate, "weekly")["last_task"] == TASK1, "re-run lost the task")
ok("re-running the same slot, even from an older run record, is a no-op")

# ---------------------------------------------------------------- skip while open
SLOT2 = at(2026, 10, 18, 1, 30)
sched("scan", now=SLOT2 + 60)
check(sched_ids(mate) == [TASK1], "a slot filed while the previous task was open")
r = rec(mate, "weekly")
check(r["skipped_count"] == "1" and r["last_skip_slot"] == str(SLOT2), "skip not recorded: %r" % r)
skip = [ln for ln in parent_lines() if "skipped-open" in ln]
check(len(skip) == 1 and "weekly" in skip[0] and "mate-a" in skip[0] and TASK1 in skip[0],
      "skip not reported up the parent channel: %r" % parent_lines())
check("skipped-open 1" in rows()["weekly"]["display"]["State"], "list does not show the skip")
ok("a due slot whose previous task is still open is skipped, recorded and reported once")

# ---------------------------------------------------------------- close with a cut-short summary
write_result(mate, "weekly", TASK1, used_seconds="7200", budget_seconds="7200", outcome="cut-short",
             cut_reason="weekly-budget", carried_over="3", note="budget spent", report="/var/report/run1.md")
close(mate, TASK1)
sched("scan", now=SLOT2 + 3600)
done = [ln for ln in parent_lines() if TASK1 in ln and "interrupted mid run" in ln]
check(len(done) == 1 and done[0].startswith("done") and "cut short by weekly-budget" in done[0]
      and "used 2h 00m of 2h 00m budget" in done[0] and "carried over 3" in done[0]
      and "/var/report/run1.md" in done[0], "close not reported with time used and reason: %r" % parent_lines())
sched("scan", now=SLOT2 + 4000)
check(len([ln for ln in parent_lines() if TASK1 in ln and "interrupted" in ln]) == 1, "close reported twice")
res = rows()["weekly"]["display"]["Result"]
check(res == "cut short: weekly-budget, used 2h 00m of 2h 00m, carried 3", "list result is %r" % res)
ok("a closed run sends exactly one line naming time used and why it was cut short, and list shows it")

# ---------------------------------------------------------------- downtime catches up once
SLOT3 = at(2026, 10, 24, 1, 30)
LATE = utc(2026, 10, 25, 12, 0)
TASK3 = "sched-weekly-202610240130"
sched("scan", now=LATE)
check(sched_ids(mate) == [TASK1, TASK3], "downtime did not catch up exactly once: %r" % sched_ids(mate))
r = rec(mate, "weekly")
check(r["caught_up"] == "1" and r["missed"] == "1" and r["last_slot"] == str(SLOT3), "catch-up not recorded: %r" % r)
check(r["next_due"] == str(at(2026, 10, 31, 1, 30)), "next slot after downtime is not the next one after now: %r" % r)
check("caught-up (1 missed)" in rows()["weekly"]["display"]["State"], "list does not show the catch-up")
ok("after downtime a schedule fires once, marks it caught up and counts the missed slot")

# ---------------------------------------------------------------- no run summary
close(mate, TASK3)
sched("scan", now=LATE + 3600)
nos = [ln for ln in parent_lines() if TASK3 in ln]
check(len(nos) == 1 and "no run summary" in nos[0] and "opened" in nos[0] and "closed by" in nos[0]
      and "missed/caught-up" in nos[0], "no-summary close not reported: %r" % nos)
check(rows()["weekly"]["display"]["Result"] == "no run summary", "list does not say no run summary")
ok("a run closed without a summary reports its open and close times and no run summary")

# ---------------------------------------------------------------- two failures pause
SLOT4, SLOT5 = at(2026, 10, 31, 1, 30), at(2026, 11, 1, 1, 30)
TASK4, TASK5 = "sched-weekly-202610310130", "sched-weekly-202611010130"
sched("scan", now=SLOT4 + 60)
write_result(mate, "weekly", TASK4, outcome="failed", note="runner crashed")
close(mate, TASK4)
sched("scan", now=SLOT4 + 3600)
check(any(ln.startswith("failed") and TASK4 in ln and "runner crashed" in ln for ln in parent_lines()),
      "failed run not reported: %r" % parent_lines())
check(rec(mate, "weekly").get("paused") != "1", "paused after one failure")
sched("scan", now=SLOT5 + 60)
write_result(mate, "weekly", TASK5, outcome="sideways")
close(mate, TASK5)
sched("scan", now=SLOT5 + 3600)
r = rec(mate, "weekly")
check(r.get("paused") == "1" and r["consecutive_failures"] == "2", "not paused after two failures: %r" % r)
blocked = [ln for ln in parent_lines() if ln.startswith("blocked") and "paused-after-failures" in ln]
check(len(blocked) == 1 and "resume mate-a weekly" in blocked[0], "pause not sent as a blocked line: %r" % parent_lines())
sched("scan", now=at(2026, 11, 8, 12, 0))
check(TASK5 == sched_ids(mate)[-1] and len(sched_ids(mate)) == 4, "a paused schedule filed: %r" % sched_ids(mate))
check(rows()["weekly"]["display"]["State"].startswith("paused-after-failures"), "list does not show the pause")
ok("two failed runs in a row pause the schedule with one blocked line and nothing more is filed")

# ---------------------------------------------------------------- the board panel
board = subprocess.run([str(root / "bin/fm-board.sh"), "--home", str(main), "--now", str(at(2026, 11, 8, 12, 5))],
                       text=True, capture_output=True, timeout=120)
check(board.returncode == 0, "board failed: " + board.stdout + board.stderr)
doc = json.loads((main / "state/board/board.json").read_text())
names = {r["name"] for r in doc["schedules"]}
check({"weekly", "bad-kind", "bad-cal", "extra-key"} <= names, "board.json lacks schedule rows: %r" % names)
items = [i for i in doc["items"] if i["panel"] == "schedules"]
check(any(i["title"] == "mate-a/weekly paused" and i["state"] == "bad" for i in items), "no paused item: %r" % items)
check(any(i["title"] == "main/bad-kind refused" for i in items), "no refused item: %r" % items)
check(any(s["name"] == "Scheduled runs" and s["status"] == "ok" for s in doc["sources"]), "schedule source not ok")
page = (main / "state/board/index.html").read_text()
check("Scheduled runs" in page and "Weekly mutation run" in page and "paused-after-failures" in page,
      "the page lacks the Scheduled runs table")
ok("the fleet board's Scheduled runs panel lists every schedule across homes with its state")

# ---------------------------------------------------------------- resume
NOW = at(2026, 11, 8, 13, 0)
p = sched("resume", "mate-a", "weekly", now=NOW)
check("resumed mate-a/weekly" in p.stdout, "resume said: " + p.stdout)
r = rec(mate, "weekly")
check(r.get("paused") is None and r["consecutive_failures"] == "0" and r["next_due"] == str(at(2026, 11, 14, 1, 30)),
      "resume did not clear the pause: %r" % r)
check(any(ln.startswith("resolved") and "schedule-weekly-paused" in ln for ln in parent_lines()),
      "resume did not resolve the blocked line")
ok("resume clears the pause, resolves the blocked line and schedules from now")

# ---------------------------------------------------------------- a main-home schedule
for f in ("bad-kind", "bad-cal", "extra-key"):
    (conf_dir / (f + ".conf")).unlink()
(conf_dir / "nightly.conf").write_text(base % ("nightly", "*-*-* 03:00:00", "scout"))
sched("validate")
sched("scan", now=NOW)
NSLOT = at(2026, 11, 9, 3, 0)
sched("scan", now=NSLOT + 60)
NTASK = "sched-nightly-202611090300"
check(sched_ids(main) == [NTASK], "main schedule not filed: %r" % sched_ids(main))
close(main, NTASK)
sched("scan", now=NSLOT + 600)
told = [t for t in notes(main) if "Scheduled run notice (main)" in t and NTASK in t]
check(len(told) == 1 and "no run summary" in told[0], "main close not noted in main's inbox: %r" % notes(main))
check(not [ln for ln in parent_lines() if NTASK in ln], "main's notice went to a mate channel")
ok("a main-home schedule files in main's backlog and reports through main's own inbox")

# ---------------------------------------------------------------- the timer's service
sched("install-timer")
svc = (Path(os.environ["XDG_CONFIG_HOME"]) / "systemd/user/fm-schedule.service").read_text()
check(re.search(r"^TimeoutStartSec=[1-9]", svc, re.M) is not None and "Type=oneshot" in svc,
      "the scan service has no start limit, so a hung scan would skip every later tick:\n" + svc)
ok("install-timer writes a scan service with a start limit")
PY
