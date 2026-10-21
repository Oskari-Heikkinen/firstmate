#!/usr/bin/env bash
# dated-rule-schedule/v1: the example schedule validates and links to the
# example fragment; the validator reports a moved date without review, a broken
# chain, a foreign row and a fragment whose date disagrees with the schedule;
# fm-dated-rules.py check raises 14/7/1-day, due, unreviewed, unreadable and
# unlinked alarms in the owner's store, escalates a second slip to main through
# the parent channel until main_decision, keeps the slip count when rows are
# removed, routes escalations for local, remote and main homes, skips an
# unchanged pass, and lookup fails closed with exit 1 or 3.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-dated-rules)

python3 - "$ROOT" "$TMP_ROOT" <<'PY'
import copy
import json
import os
import subprocess
import sys
from pathlib import Path

root, tmp = Path(sys.argv[1]), Path(sys.argv[2])
VALIDATE = str(root / "bin/fm-handoff-validate.py")
READER = str(root / "bin/fm-dated-rules.py")
EXAMPLES = root / "docs/handoff-coverage/examples"
SCHEDULE = EXAMPLES / "research.schedule.json"
FRAGMENT = EXAMPLES / "xp-chain.fragment.json"


def ok(msg):
    print("ok - " + msg)


def fail(msg):
    print("not ok - " + msg)
    sys.exit(1)


def expect(cond, msg, detail=""):
    if not cond:
        fail(f"{msg}\n{detail}")
    ok(msg)


def run(tool, *args, env=None):
    proc = subprocess.run([sys.executable, "-I", tool, *map(str, args)], capture_output=True, text=True,
                          env={**os.environ, **(env or {})})
    return proc.returncode, proc.stdout + proc.stderr


def load(path):
    return json.loads(Path(path).read_text())


def write(path, doc):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(doc, indent=2) + "\n")
    return path


# ---------- validator ----------

rc, out = run(VALIDATE, "schedule", "--fragment", FRAGMENT, SCHEDULE)
expect(rc == 0 and "ok schedule" in out and "ok fragment" in out, "the example schedule validates and links to the example fragment", out)

base = load(SCHEDULE)


def variant(name, change):
    doc = copy.deepcopy(base)
    change(doc)
    return write(tmp / "invalid" / name, doc)


def unreviewed(doc):
    del doc["rows"][2]["review"]


def foreign(doc):
    doc["rows"][0]["owner"] = "tetjet-mate"


def in_force_moved(doc):
    doc["rows"][1]["state"] = "in-force"


def two_roots(doc):
    del doc["rows"][2]["replaces"]
    del doc["rows"][2]["review"]


def unknown_field(doc):
    doc["rows"][0]["grace"] = True


def bad_date(doc):
    doc["rows"][0]["date"] = "2026-02-30"


for name, change, want in [
    ("unreviewed.json", unreviewed, "without a review mark"),
    ("foreign.json", foreign, "a schedule holds only rows its home owns"),
    ("in-force-moved.json", in_force_moved, "a rule in force or withdrawn is never moved"),
    ("two-roots.json", two_roots, "exactly one starts the rule"),
    ("unknown-field.json", unknown_field, "/grace: is not a field of this format"),
    ("bad-date.json", bad_date, "is not a calendar date"),
]:
    rc, out = run(VALIDATE, "schedule", variant(name, change))
    expect(rc == 1 and want in out, f"schedule {name} fails with: {want}", out)

first = copy.deepcopy(base)
first["rows"] = base["rows"][:2]
second = copy.deepcopy(base)
second["rows"] = base["rows"][2:]
rc, out = run(VALIDATE, "schedule", write(tmp / "split/a.json", first), write(tmp / "split/b.json", second))
expect(rc == 1 and "split across" in out, "one rule's rows cannot be split across files", out)

frag = load(FRAGMENT)
frag["protocols"][0]["dated_rules"][0]["date"] = "2026-12-31"
rc, out = run(VALIDATE, "schedule", "--fragment", write(tmp / "link/fragment.json", frag), SCHEDULE)
expect(rc == 1 and "says 2026-12-31, but schedule row xp-v0-reader-retire.2 says 2027-01-31" in out,
       "a fragment date that is not the rule's effective date is a finding", out)
frag["protocols"][0]["dated_rules"][0].update(owner="tetjet-mate", id="other")
rc, out = run(VALIDATE, "schedule", "--fragment", write(tmp / "link/foreign.json", frag), SCHEDULE)
expect(rc == 0, "a dated rule of a home with no schedule in the call is not checked", out)
rc, out = run(VALIDATE, "schedule", tmp / "missing.json")
expect(rc == 3, "an unreadable schedule exits 3", out)

# ---------- reader ----------

parent = tmp / "parent"
home = tmp / "mate"
(parent / "state").mkdir(parents=True)
(home / "state/dated-rules").mkdir(parents=True)
(home / ".fm-secondmate-home").write_text("mate-x\n")
(home / ".fm-secondmate-parent").write_text(f"schema=fm-secondmate-parent.v1\nroute=local\nparent_home={parent}\n")
ENV = {"FM_HOME": str(home), "FM_STATE_OVERRIDE": "", "FM_DATED_RULES_CHECK_MARK": "1"}
STATE = home / "state"
REVIEW = {"by": "test", "at": "2026-10-01T00:00:00Z", "ref": "test review"}


def row(rid, rule, date, **extra):
    return {"id": rid, "rule": rule, "owner": "mate-x", "date": date, "what": f"test {rule}", "state": "scheduled", **extra}


def schedule(rows, name="main.json"):
    return write(STATE / "dated-rules" / name, {"format": "dated-rule-schedule/v1", "home": "mate-x", "publisher": "test",
                                                 "revision": 1, "published_at": "2026-10-01T00:00:00Z", "rows": rows})


def check(today):
    rc, out = run(READER, "check", "--today", today, env=ENV)
    expect(rc == 0 and out.endswith("dated-rules check: complete\n"), f"check on {today} completes", out)
    return out


def active(name):
    path = STATE / name
    return load(path)["active"] if path.exists() else {}


slip_rows = [row("slip.1", "slip", "2026-12-01"),
             row("slip.2", "slip", "2026-12-15", replaces="slip.1", review=REVIEW),
             row("slip.3", "slip", "2027-01-15", replaces="slip.2", review=REVIEW)]
schedule([row("v.1", "v", "2026-11-05"),
          row("un.1", "un", "2026-10-22"), row("un.2", "un", "2027-03-01", replaces="un.1")] + slip_rows)

check("2026-10-21")
expect("dated-rule.v.1.14d" not in active("dated-rules.alerts.json"), "a rule 15 days out raises nothing yet")
owner = active("dated-rules.alerts.json")
expect({"dated-rule.un.1.1d", "dated-rule.un.2.unreviewed"} <= set(owner),
       "a move without review leaves the earlier date in force and alarms on both", str(sorted(owner)))
escalated = active("dated-rules.escalated.json")
expect(set(escalated) == {"dated-rule.slip.3.escalated"}, "the second slip escalates to main", str(sorted(escalated)))
reg = (parent / "state/alert-stores/dated-rules-mate-x.reg").read_text()
expect("status=mate-x.status\n" in reg and f"path={STATE}/dated-rules.escalated.json\n" in reg,
       "the escalation store is registered for the parent channel in the parent home", reg)
expect("status=dated-rules.status\n" in (STATE / "alert-stores/dated-rules.reg").read_text() and (STATE / "dated-rules.status").exists(),
       "the owner store is registered for state/dated-rules.status")

stores = {p: p.stat().st_mtime_ns for p in STATE.glob("dated-rules.*")}
check("2026-10-21")
expect(stores == {p: p.stat().st_mtime_ns for p in STATE.glob("dated-rules.*")}, "an unchanged pass writes nothing")

check("2026-10-22")
owner = active("dated-rules.alerts.json")
expect("dated-rule.v.1.14d" in owner and "dated-rule.un.1.due" in owner and "dated-rule.un.1.1d" not in owner,
       "the 14-day alarm is raised on the first pass of that day and a passed date is due", str(sorted(owner)))
check("2026-10-29")
owner = active("dated-rules.alerts.json")
expect("dated-rule.v.1.7d" in owner and "dated-rule.v.1.14d" not in owner, "the alarm steps to 7 days", str(sorted(owner)))
check("2026-11-04")
expect("dated-rule.v.1.1d" in active("dated-rules.alerts.json"), "the alarm steps to 1 day")

rc, out = run(READER, "lookup", "un", env=ENV)
expect(rc == 0 and out.strip() == "2026-10-22 scheduled un.1", "lookup returns the reviewed date, not the unreviewed move", out)
rc, out = run(READER, "lookup", "--json", "slip", env=ENV)
expect(rc == 0 and json.loads(out)["slips"] == 2 and json.loads(out)["date"] == "2027-01-15", "lookup --json reports the slips", out)
rc, out = run(READER, "lookup", "nope", env=ENV)
expect(rc == 1, "lookup of an undeclared rule exits 1", out)

# Removing the history keeps the slip count; main_decision clears the escalation.
schedule([row("v.1", "v", "2026-11-05", state="in-force"), row("slip.3", "slip", "2027-01-15")])
check("2026-11-04")
expect(set(active("dated-rules.escalated.json")) == {"dated-rule.slip.3.escalated"}, "removing old rows does not lower the slip count")
expect(active("dated-rules.alerts.json") == {}, "an in-force rule and a cleared move raise nothing", str(active("dated-rules.alerts.json")))
schedule([row("slip.3", "slip", "2027-01-15", main_decision=REVIEW)])
check("2026-11-04")
expect(active("dated-rules.escalated.json") == {}, "main_decision clears the escalation")

# Unreadable files and fragment links alarm the owner; lookups fail closed.
(STATE / "dated-rules/broken.json").write_text("{not json\n")
write(STATE / "handoff-registry/own.json", {"protocols": [{"id": "p", "dated_rules": [
    {"id": "slip", "owner": "mate-x", "date": "2027-01-15", "what": "x"},
    {"id": "gone", "owner": "mate-x", "date": "2027-01-01", "what": "x"},
    {"id": "theirs", "owner": "tetjet-mate", "date": "2027-01-01", "what": "x"}]}]})
check("2026-11-04")
owner = active("dated-rules.alerts.json")
expect(set(owner) == {"dated-rule.file.broken.json.unreadable", "dated-rule.gone.unlinked"},
       "an unreadable schedule and an own fragment rule with no schedule row alarm the owner", str(sorted(owner)))
rc, out = run(READER, "lookup", "nope", env=ENV)
expect(rc == 3, "lookup exits 3 when a schedule that might declare the rule cannot be read", out)
rc, out = run(READER, "lookup", "slip", env=ENV)
expect(rc == 3, "a rule in a readable file fails closed too, since the unreadable one could move it", out)

# Removing the schedule folder retires both stores and their registrations.
expect((STATE / "dated-rules.escalated.json").exists(), "an emptied escalation store stays while the schedule does")
os.rename(STATE / "dated-rules", tmp / "retired-schedule")
check("2026-10-21")
expect(not list(STATE.glob("dated-rules.*.json")) and not (STATE / "alert-stores/dated-rules.reg").exists()
       and not (parent / "state/alert-stores/dated-rules-mate-x.reg").exists(),
       "a removed schedule folder unregisters and removes both stores")

# A main home keeps its escalations in its own store.
main = tmp / "main"
write(main / "state/dated-rules/main.json", {"format": "dated-rule-schedule/v1", "home": "main", "publisher": "test", "revision": 1,
                                             "published_at": "2026-10-01T00:00:00Z",
                                             "rows": [dict(r, owner="main") for r in slip_rows]})
rc, out = run(READER, "check", "--today", "2026-10-21", env={"FM_HOME": str(main)})
expect(rc == 0 and "dated-rule.slip.3.escalated" in load(main / "state/dated-rules.alerts.json")["active"]
       and not (main / "state/dated-rules.escalated.json").exists(), "a main home keeps escalations in its own store", out)

# A remote secondmate's escalations go to its own parent-replies.status.
remote = tmp / "remote"
write(remote / "state/dated-rules/main.json", {"format": "dated-rule-schedule/v1", "home": "mate-x", "publisher": "test",
                                               "revision": 1, "published_at": "2026-10-01T00:00:00Z", "rows": slip_rows})
(remote / ".fm-secondmate-home").write_text("mate-x\n")
(remote / ".fm-secondmate-parent").write_text("schema=fm-secondmate-parent.v1\nroute=remote\n")
rc, out = run(READER, "check", "--today", "2026-10-21", env={"FM_HOME": str(remote)})
reg = (remote / "state/alert-stores/dated-rules-mate-x.reg").read_text()
expect(rc == 0 and "status=parent-replies.status\n" in reg
       and "dated-rule.slip.3.escalated" in load(remote / "state/dated-rules.escalated.json")["active"],
       "a remote secondmate's escalation is registered for its parent channel in its own home", out + reg)

rc, out = run(READER, "check", "--today", "soon", env=ENV)
expect(rc == 2, "a bad --today is a usage error", out)
watch = (root / "bin/fm-watch.sh").read_text()
expect('run_check_capture "$SCRIPT_DIR/fm-dated-rules.sh" check' in watch, "the watcher runs the check in its slow-check step")
PY
pass "dated-rule-schedule/v1 validator, reader alarms and lookup"
