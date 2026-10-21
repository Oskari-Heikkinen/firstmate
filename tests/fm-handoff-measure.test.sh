#!/usr/bin/env bash
# fm-handoff-measure: the M1 drills in a scratch root of four homes. A raised
# alarm carries its role and deliver_by into each target store and yields a
# measured time to notice against its target once the target home's
# alert-store tick delivers it: met when delivered in time, missed when not.
# The watcher's weekly pass prints the coverage line only once 7 days have
# passed: a stage idle past 7 days shows as idle with its last receipt, a
# check bound by hand after the actor snapshot shows as an undeclared actor,
# and the next pass inside the week prints nothing. The on-demand coverage
# command prints the same line.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-handoff-measure)
export TZ=UTC

python3 - "$ROOT" "$TMP_ROOT" <<'PY'
import datetime
import json
import os
import subprocess
import sys
import time
from pathlib import Path

root, tmp = Path(sys.argv[1]), Path(sys.argv[2])
# Store events and deliveries are stamped with the real clock, so the drill clock is the real clock.
NOW = int(time.time())
DAY = 86400
WATCH = str(root / "bin/fm-handoff-watch.sh")
STORE = str(root / "bin/fm-alert-store.sh")
MEASURE = str(root / "bin/fm-handoff-measure.py")
ACTORS = str(root / "bin/fm-handoff-actors.py")
R = (tmp / "machine").resolve()
HOMES = ("main", "tooling-mate", "lattice-research-mate", "tetjet-mate")
RES, TJ = "lattice-research-mate", "tetjet-mate"
BASE_ENV = {k: v for k, v in os.environ.items()
            if k not in ("FM_HOME", "FM_STATE_OVERRIDE", "FM_ROOT_OVERRIDE", "FM_CONFIG_OVERRIDE")}


def ok(msg):
    print("ok - " + msg)


def fail(msg):
    print("not ok - " + msg)
    sys.exit(1)


def expect(cond, msg, detail=""):
    if not cond:
        fail(f"{msg}\n{detail}")
    ok(msg)


def iso(epoch, frac=False):
    stamp = datetime.datetime.fromtimestamp(epoch, datetime.timezone.utc)
    return stamp.strftime("%Y-%m-%dT%H:%M:%S.%fZ" if frac else "%Y-%m-%dT%H:%M:%SZ")


def write(path, doc):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(doc, indent=2) + "\n")
    return path


for hid in HOMES:
    (R / hid / "state").mkdir(parents=True)
    (R / hid / "state").chmod(0o700)
P = R / "places"


def place(name):
    path = P / name
    path.mkdir(parents=True, exist_ok=True)
    return {"path": str(path), "reach": {"kind": "local"}}


def stage(name, owner, **extra):
    doc = {
        "name": name, "owner": owner, "accepts": {"min": 0, "max": 0}, "writes": {"min": 0, "max": 0},
        "input": {**place(f"in-{name}"), "match": "*.json", "type_field": "schema_version"},
        "outbox": place(f"out-{name}"),
        "bounds": {"accepted": "30m", "waiting": "2h", "held": "1h"}, "retry_limit": 2,
        "codes": {"capability-unpublished": {"fix_owner": TJ, "holds_all": False, "what": "capability not published"}},
        "cleanup": {"action": "keep"},
    }
    doc.update(extra)
    return doc


FRAG = write(R / RES / "state/handoff-registry/xp.json", {
    "format": "handoff-registry/v1", "home": RES, "publisher": "fm-handoff-measure.test", "revision": 1,
    "published_at": "2026-10-21T12:00:00Z",
    "protocols": [{
        "id": "xp", "owner": RES, "title": "test chain", "schema": "test:xp.schema.json",
        "record_types": ["xp-contract/v0"], "versions": {"min": 0, "max": 0}, "senders": [RES],
        "first_stage": "filing",
        "stages": [stage("filing", RES), stage("intake", RES), stage("ready", TJ), stage("later", RES, planned=True)],
        "cleanup": {"stage": "later", "receipts_after": "30d", "records_after": "90d"},
    }],
})
check = subprocess.run([sys.executable, str(root / "bin/fm-handoff-validate.py"), "fragment", str(FRAG)],
                       capture_output=True, text=True)
expect(check.returncode == 0, "the drill fragment validates", check.stdout)

seq = [0]


def receipt(stage_name, record, state, at, **extra):
    seq[0] += 1
    rid = "%016x" % seq[0]
    doc = {"format": "handoff-receipt/v1", "receipt_id": rid, "written_at": iso(at, True), "protocol": "xp",
           "version": 0, "stage": stage_name, "home": RES, "record": record, "attempt": 1, "seq": 1,
           "state": state, **extra}
    name = datetime.datetime.fromtimestamp(at, datetime.timezone.utc).strftime("%Y%m%dT%H%M%S.%fZ")
    return write(P / f"out-{stage_name}" / f"{name}-{rid}.json", doc)


def tick(hid, now):
    proc = subprocess.run([WATCH, "tick", "--root", str(R), "--home", str(R / hid), "--now", str(now)],
                          capture_output=True, text=True, timeout=60, env=BASE_ENV)
    if proc.returncode != 0:
        fail(f"tick {hid} exited {proc.returncode}: {proc.stderr}")
    return proc.stdout


def active(observer, target):
    path = R / observer / "state/handoff-watch/stores" / f"{target}.json"
    return json.loads(path.read_text())["active"] if path.exists() else {}


def project(target):
    proc = subprocess.run([STORE, "tick"], env={**BASE_ENV, "FM_HOME": str(R / target)},
                          capture_output=True, text=True, timeout=60)
    if proc.returncode != 0:
        fail(f"alert-store tick in {target}: {proc.stderr}")


def measure(*args):
    proc = subprocess.run([sys.executable, MEASURE, *map(str, args)], capture_output=True, text=True, timeout=60,
                          env=BASE_ENV)
    return proc.returncode, proc.stdout + proc.stderr


# The actor inventory's first run snapshots what the home already runs, as at install.
snap = subprocess.run([sys.executable, ACTORS, "list", "--root", str(R), "--home", str(R / RES)],
                      capture_output=True, text=True, env=BASE_ENV)
expect(snap.returncode == 0, "the actor inventory snapshots the drill home", snap.stdout + snap.stderr)

# Two refusals with a fix_owner in another home: one 2 minutes old, one an hour old when the watcher first sees it.
FRESH, STALE = NOW - 120, NOW - 3600
receipt("filing", "req-1", "refused", FRESH, code="capability-unpublished", detail="the gpu capability is not published")
receipt("filing", "req-2", "refused", STALE, code="capability-unpublished", detail="the cpu capability is not published")
receipt("intake", "req-0", "done", NOW - 8 * DAY)
out = tick(RES, NOW)
expect(out == "", "the first pass stamps the weekly clock and prints no coverage line", out)
K1, K2 = "hw-refused-xp-filing-req-1", "hw-refused-xp-filing-req-2"
fix, sender = active(RES, TJ).get(K1, {}), active(RES, RES).get(K1, {})
expect(fix.get("role") == "fix-owner" and fix.get("deliver_by") == iso(FRESH + 600),
       "the fix owner's store entry carries its role and a deliver_by 10 min after the refusal", json.dumps(fix))
expect(sender.get("role") == "sender" and sender.get("deliver_by") == iso(FRESH + 900),
       "the sender's store entry carries its role and a deliver_by 15 min after the refusal", json.dumps(sender))

# The target home's alert-store tick delivers both now: the fresh one in time, the stale one late.
project(TJ)
rc, out = measure("notice", "--root", R, "--home", R / TJ, "--now", NOW + 600, "--json")
doc = json.loads(out)
rows = {r["key"]: r for r in doc["alarms"]}
expect(set(rows) == {K1, K2}, "notice lists each alarm raised for the home in the window", out)
expect(rows[K1]["outcome"] == "met" and rows[K1]["role"] == "fix-owner" and 120 <= rows[K1]["notice"] < 600,
       "D1: a raised alarm yields a measured time to notice that met its 10 min target", json.dumps(rows[K1]))
expect(rows[K2]["outcome"] == "missed" and rows[K2]["notice"] >= 3600,
       "D1: an alarm delivered past its target is measured as missed", json.dumps(rows[K2]))
expect(rc == 1, "notice exits 1 when an alarm missed its target", out)
rc, out = measure("notice", "--root", R, "--home", R / TJ, "--now", NOW + 600)
expect("refused: 2 alarms, 1 met, 1 missed; notice median" in out, "the text form sums up per check kind", out)
rc, out = measure("notice", "--root", R, "--home", R / RES, "--now", NOW + 600, "--json")
rows = {r["key"]: r for r in json.loads(out)["alarms"]}
expect(rows.get(K1, {}).get("outcome") == "pending" and rows.get(K1, {}).get("role") == "sender",
       "an alarm not yet delivered inside its target is pending", out)
expect(rows.get(K2, {}).get("outcome") == "undelivered", "an alarm not delivered by its target is undelivered", out)

# Inside the week the pass prints no coverage line.
expect(tick(RES, NOW + 60) == "", "a pass inside the week prints no coverage line")

# A check bound by hand after the snapshot is an undeclared actor.
check_path = R / RES / "state/rogue.check.sh"
check_path.write_text("#!/usr/bin/env bash\nexit 0\n")
check_path.chmod(0o700)
(R / RES / "state/rogue.check-trust").write_text("fm-custom-check-v1\n0\n")

# A week on: filing's last receipt is 8 days old, intake has a fresh one, later is planned.
LATER = NOW + 8 * DAY
receipt("intake", "req-3", "done", LATER - 60)
out = tick(RES, LATER)
lines = out.splitlines()
printed = next((l for l in lines if l.startswith(f"handoff coverage {RES} ")), "")
line = printed.rsplit(" (report: ", 1)[0]
expect(line != "", "D2: the weekly pass prints the coverage line once 7 days have passed", out)
expect(f"xp/filing idle since {iso(FRESH)}" in line and "2 stages owned, 1 with receipts, 1 with none" in line
       and "1 planned" in line and "1 protocol declared" in line,
       "D2: a stage idle past 7 days shows as idle with its last receipt, the active and planned ones counted", line)
expect("1 undeclared actor (fm-check:rogue)" in line, "D3: an undeclared actor appears in the line", line)
reports = sorted((R / RES / "state/handoff-watch/coverage").glob("*.txt"))
expect(len(reports) == 1 and reports[0].read_text().splitlines()[0] == line and printed.endswith(f"(report: {reports[0]})"),
       "the line and its detail are kept in a dated report", out)
expect(f"coverage: {line}" in (R / RES / "state/handoff-watch/log").read_text(), "the watcher log records the line")
expect(tick(RES, LATER + 60) == "", "the next pass inside the new week prints nothing")

rc, out = measure("coverage", "--root", R, "--home", R / RES, "--now", LATER)
expect(rc == 1 and f"xp/filing idle since {iso(FRESH)}" in out and "fm-check:rogue" in out,
       "the on-demand coverage command prints the same findings and exits 1", out)

# Gone records read as unreadable, not as quiet.
(R / TJ / "state/alert-stores/handoff-watch.lattice-research-mate.reg").write_text("path=/nowhere/store.json\n")
rc, out = measure("notice", "--root", R, "--home", R / TJ, "--now", NOW + 600)
expect(rc == 3 and "unreadable: alert store handoff-watch.lattice-research-mate" in out,
       "an unreadable store makes the measurement incomplete (exit 3)", out)
PY
