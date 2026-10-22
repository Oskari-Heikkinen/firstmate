#!/usr/bin/env bash
# fm-handoff-watch: the plan's drills V-a, V-b, V-c, V-g, V-h and V-l in a
# scratch root of four homes, each alarm reaching its target home's status
# file through that home's alert-store tick; refusal escalation to main at 4 h
# unless acknowledged; a later attempt clearing the levels; unregistered and
# duplicate receipts; an invalid fragment keeping its last valid revision; an
# example fragment never loaded; dated rules, left to the owner's schedule
# reader once its schedule declares them; a target this machine does not
# see falling back to main; a quiet pass writing nothing; and arm and disarm.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-handoff-watch)
OBSERVER=$(fm_check_rename_observer "$TMP_ROOT/arm-observer")
export TZ=UTC

python3 - "$ROOT" "$TMP_ROOT" "$OBSERVER" <<'PY'
import datetime
import json
import os
import shutil
import subprocess
import sys
import time
from pathlib import Path

root, tmp, observer = Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3]
# Store acknowledgements are stamped with the real clock, so the drill clock starts there.
NOW = int(time.time()) // 3600 * 3600
H = 3600
WATCH = str(root / "bin/fm-handoff-watch.sh")
STORE = str(root / "bin/fm-alert-store.sh")
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
P = R / "places"


def place(name, synced=False):
    path = P / name
    path.mkdir(parents=True, exist_ok=True)
    reach = {"kind": "synced", "source": f"tetjet:/srv/{name}", "max_lag": "15m"} if synced else {"kind": "local"}
    return {"path": str(path), "reach": reach}


def stage(name, owner, synced=False, **extra):
    doc = {
        "name": name, "owner": owner, "accepts": {"min": 0, "max": 0}, "writes": {"min": 0, "max": 0},
        "input": {**place(f"in-{name}", synced), "match": "*.json", "type_field": "schema_version"},
        "outbox": place(f"out-{name}", synced),
        "bounds": {"accepted": "30m", "waiting": "2h", "held": "1h"}, "retry_limit": 2,
        "codes": {
            "finding:*": {"fix_owner": RES, "holds_all": False, "what": "a filing check finding"},
            "capability-unpublished": {"fix_owner": TJ, "holds_all": False, "what": "capability not published"},
            "intake-ledger-lock": {"fix_owner": TJ, "holds_all": True, "stops": "every start in the scheduler",
                                   "what": "intake failed closed"},
        },
        "cleanup": {"action": "keep"},
    }
    doc.update(extra)
    return doc


def fragment(revision=1, rule_date="2030-01-01", **extra):
    return {
        "format": "handoff-registry/v1", "home": RES, "publisher": "fm-handoff-watch.test", "revision": revision,
        "published_at": "2026-10-21T12:00:00Z",
        "protocols": [{
            "id": "xp", "owner": RES, "title": "test chain", "schema": "test:xp.schema.json",
            "record_types": ["xp-contract/v0"], "versions": {"min": 0, "max": 0}, "senders": [RES],
            "first_stage": "filing",
            "stages": [stage("filing", RES), stage("ready", TJ, synced=True), stage("later", RES, planned=True)],
            "cleanup": {"stage": "later", "receipts_after": "30d", "records_after": "90d"},
            "dated_rules": [{"id": "v0-retire", "owner": RES, "date": rule_date, "what": "v0 readers retire"}],
        }],
        **extra,
    }


FRAG = write(R / RES / "state/handoff-registry/xp.json", fragment())
check = subprocess.run([sys.executable, str(root / "bin/fm-handoff-validate.py"), "fragment", str(FRAG)],
                       capture_output=True, text=True)
expect(check.returncode == 0, "the drill fragment validates", check.stdout)

seq = [0]


def receipt(stage_name, record, state, at, home=RES, attempt=1, seq_no=1, **extra):
    seq[0] += 1
    rid = "%016x" % seq[0]
    doc = {"format": "handoff-receipt/v1", "receipt_id": rid, "written_at": iso(at, True), "protocol": "xp",
           "version": 0, "stage": stage_name, "home": home, "record": record, "attempt": attempt, "seq": seq_no,
           "state": state, **extra}
    name = datetime.datetime.fromtimestamp(at, datetime.timezone.utc).strftime("%Y%m%dT%H%M%S.%fZ")
    return write(P / f"out-{stage_name}" / f"{name}-{rid}.json", doc)


def tick(hid, now, check=True):
    proc = subprocess.run([WATCH, "tick", "--root", str(R), "--home", str(R / hid), "--now", str(now)],
                          capture_output=True, text=True, timeout=60, env=BASE_ENV)
    if check and proc.returncode != 0:
        fail(f"tick {hid} exited {proc.returncode}: {proc.stderr}")
    return proc


def store(observer, target):
    path = R / observer / "state/handoff-watch/stores" / f"{target}.json"
    return json.loads(path.read_text()) if path.exists() else None


def active(observer, target):
    doc = store(observer, target)
    return doc["active"] if doc else {}


def project(target):
    """Run the target home's alert-store tick and return its handoff-watch.status lines."""
    proc = subprocess.run([STORE, "tick"], env={**BASE_ENV, "FM_HOME": str(R / target)},
                          capture_output=True, text=True, timeout=60)
    if proc.returncode != 0:
        fail(f"alert-store tick in {target}: {proc.stderr}")
    status = R / target / "state/handoff-watch.status"
    return status.read_text().splitlines() if status.exists() else []


KEY_REFUSED = "hw-refused-xp-filing-req-1"

# V-a: a filing refused with a code whose fix_owner is tetjet-mate; the sender is research.
T0 = NOW - 600
r1 = receipt("filing", "req-1", "refused", T0, code="capability-unpublished",
             detail="the gpu capability is not published")
(P / "in-filing/req-1.json").write_text(json.dumps({"schema_version": "xp-contract/v0"}))
os.utime(P / "in-filing/req-1.json", (T0, T0))
out = tick(RES, NOW)
expect(out.stdout == "", "a pass with every target known prints nothing", out.stdout)
expect(KEY_REFUSED in active(RES, TJ) and KEY_REFUSED in active(RES, RES) and KEY_REFUSED not in active(RES, "main"),
       "V-a: the refusal is a level for its fix_owner and its sender, not main")
entry = active(RES, TJ)[KEY_REFUSED]
expect(entry["kind"] == "refused" and entry["subject"] == "xp/filing/req-1"
       and entry["reason"] == "the gpu capability is not published" and entry["since"] == iso(T0)
       and entry["evidence"] == {"path": str(r1)}, "V-a: the entry carries kind, subject, detail, since and evidence",
       json.dumps(entry))
reg = (R / TJ / "state/alert-stores/handoff-watch.lattice-research-mate.reg").read_text()
expect(f"path={R / RES}/state/handoff-watch/stores/{TJ}.json" in reg and "status=handoff-watch.status" in reg,
       "V-a: the store is registered in the target home", reg)
lines = project(TJ)
expect(any(f"blocked [key={KEY_REFUSED}]" in line for line in lines),
       "V-a: the target home's alert-store tick projects the alarm as a blocked line", "\n".join(lines))
log = (R / RES / "state/handoff-watch/log").read_text()
expect(f"raised {KEY_REFUSED} for {TJ}" in log, "V-a: the append-only log records the raise", log)

# A quiet pass rewrites no store and appends nothing to the log.
store_path = R / RES / "state/handoff-watch/stores" / f"{TJ}.json"
before = (store_path.stat().st_mtime_ns, log)
tick(RES, NOW + 60)
expect((store_path.stat().st_mtime_ns, (R / RES / "state/handoff-watch/log").read_text()) == before,
       "an unchanged pass leaves the stores and the log untouched")

# V-l: a refusal left open reaches main at 4 h; an acknowledgement before then keeps it from main.
tick(RES, T0 + 4 * H - 60)
expect(KEY_REFUSED not in active(RES, "main"), "V-l: the refusal stays off main before 4 h")
tick(RES, T0 + 4 * H + 1)
expect(KEY_REFUSED in active(RES, "main"), "V-l: the refusal reaches main once open 4 h")
ack = subprocess.run([STORE, "ack", str(store_path), f"handoff-watch.{RES}", KEY_REFUSED, "86400", TJ, "fix in hand"],
                     env={**BASE_ENV, "FM_HOME": str(R / TJ)}, capture_output=True, text=True)
expect(ack.returncode == 0, "the target acknowledges the refusal in its store", ack.stderr)
tick(RES, T0 + 4 * H + 2)
expect(KEY_REFUSED not in active(RES, "main") and KEY_REFUSED in active(RES, TJ),
       "V-l: an acknowledged refusal leaves main but stays a level for its targets")

# Lane fault: a held receipt with holds_all reaches main at once, naming what it stops.
receipt("filing", "req-9", "held", NOW, code="intake-ledger-lock", holds_all=True,
        stops="every start in the scheduler")
tick(RES, NOW + 120)
lane = active(RES, "main").get("hw-lane-fault-xp-filing-req-9")
expect(lane and "every start in the scheduler" in lane["reason"], "a lane fault reaches main at once with its stops",
       json.dumps(active(RES, "main")))
expect("hw-held-xp-filing-req-9" in active(RES, TJ), "the hold itself reaches its fix_owner")
tick(RES, NOW + 2 * H)
expect("hw-open-past-bound-xp-filing-req-9" in active(RES, TJ), "a hold past its bound is open-past-bound to fix_owner")

# A later attempt closes the refusal for good, and every level clears.
receipt("filing", "req-1", "done", NOW + 2 * H, attempt=2)
receipt("filing", "req-9", "done", NOW + 2 * H, attempt=2)
tick(RES, NOW + 2 * H + 60)
expect(not any(k.startswith(("hw-refused", "hw-held", "hw-lane", "hw-open")) for target in (RES, TJ, "main")
               for k in active(RES, target)), "a later done attempt clears every level it raised",
       json.dumps({t: list(active(RES, t)) for t in (RES, TJ, "main")}))
lines = project(TJ)
expect(any(line.startswith("resolved") and KEY_REFUSED in line for line in lines),
       "the target's tick closes the cleared blocker", "\n".join(lines))
log = (R / RES / "state/handoff-watch/log").read_text()
expect(f"cleared {KEY_REFUSED} for {TJ}" in log, "the log records the clear")

# V-b: a record of an unregistered type in a declared place: tooling-mate at once, main at 1 h.
T1 = NOW + 3 * H
(P / "in-filing/stray.json").write_text(json.dumps({"schema_version": "mystery/v9"}))
os.utime(P / "in-filing/stray.json", (T1, T1))
os.utime(P / "in-filing", None)
tick(RES, T1 + 60)
key_b = [k for k in active(RES, "tooling-mate") if k.startswith("hw-unregistered-type-")]
expect(key_b and key_b[0] in active(RES, RES) and key_b[0] not in active(RES, "main"),
       "V-b: an unregistered type reaches tooling-mate and the stage owner at once", json.dumps(active(RES, "tooling-mate")))
tick(RES, T1 + 60 + H)
expect(key_b[0] in active(RES, "main"), "V-b: still open after 1 h it reaches main")
(P / "in-filing/stray.json").unlink()

# V-c: a declared stage that writes no receipt: no-receipt after its accepted bound.
(P / "in-filing/req-2.json").write_text(json.dumps({"schema_version": "xp-contract/v0"}))
os.utime(P / "in-filing/req-2.json", (T1, T1))
tick(RES, T1 + 29 * 60)
expect("hw-no-receipt-xp-filing-req-2.json" not in active(RES, RES), "V-c: quiet inside the accepted bound")
tick(RES, T1 + 31 * 60)
expect("hw-no-receipt-xp-filing-req-2.json" in active(RES, RES), "V-c: no receipt past the bound alarms the stage owner",
       json.dumps(list(active(RES, RES))))
expect(not any("later" in k for k in active(RES, RES)), "a planned stage raises nothing for its missing places")

# Unregistered receipts: a writer that is not the stage owner, and a repeated (attempt, seq).
receipt("filing", "req-2", "accepted", T1 + 31 * 60, home=TJ)
receipt("filing", "req-2", "accepted", T1 + 31 * 60 + 1)
receipt("filing", "req-2", "accepted", T1 + 31 * 60 + 2)
tick(RES, T1 + 33 * 60)
bad = [k for k in active(RES, "tooling-mate") if k.startswith("hw-unregistered-receipt-")]
expect(len(bad) == 2 and all(k in active(RES, TJ) or k in active(RES, RES) for k in bad),
       "a receipt from the wrong home and a repeated attempt and seq reach the writer and tooling-mate",
       json.dumps(list(active(RES, "tooling-mate"))))
expect("hw-no-receipt-xp-filing-req-2.json" not in active(RES, RES), "a receipt for the record clears no-receipt")

# V-g: an unreadable outbox alarms its owner and keeps the stage's levels; a stale sync alarms the stage owner.
out_filing = P / "out-filing"
held_keys = set(active(RES, "tooling-mate"))
os.rename(out_filing, P / "out-filing.moved")
out_filing.write_text("not a folder\n")
tick(RES, T1 + 40 * 60)
key_g = [k for k in active(RES, RES) if k.startswith("hw-source-unreadable-")]
expect(key_g and held_keys <= set(active(RES, "tooling-mate")),
       "V-g: an unreadable outbox alarms its owner and no level of that stage clears", json.dumps(list(active(RES, RES))))
out_filing.unlink()
os.rename(P / "out-filing.moved", out_filing)
tick(RES, T1 + 45 * 60)
expect(not [k for k in active(RES, RES) if k.startswith("hw-source-unreadable-")], "V-g: a readable outbox clears it")

T2 = NOW + 5 * H
(P / "in-ready/.synced-at").write_text(iso(T2 - 20 * 60) + "\n")
tick(TJ, T2)
stale = [v for v in active(TJ, TJ).values() if v["kind"] == "sync-stale"]
missing = [v for v in active(TJ, TJ).values() if v["kind"] == "source-unreadable" and v["subject"].endswith(".synced-at")]
expect(len(stale) == 1 and stale[0]["subject"] == str(P / "in-ready") and len(missing) == 1
       and missing[0]["subject"] == str(P / "out-ready/.synced-at"),
       "V-g: a sync older than max_lag is sync-stale, a missing stamp is source-unreadable, both to the stage owner",
       json.dumps(active(TJ, TJ)))
(P / "in-ready/.synced-at").write_text(iso(T2) + "\n")
(P / "out-ready/.synced-at").write_text(iso(T2) + "\n")
tick(TJ, T2 + 60)
expect(not active(TJ, TJ), "fresh stamps clear both", json.dumps(active(TJ, TJ)))

# V-h: a watcher that stops beating reaches main after two ticks; disarm (release) removes the heartbeat.
tick("main", T2 + 300)
expect("hw-watcher-silent-tetjet-mate" not in active("main", "main"), "V-h: a heartbeat one tick old is not silent")
tick("main", T2 + 60 + 601)
silent = active("main", "main").get("hw-watcher-silent-tetjet-mate")
expect(silent and silent["kind"] == "watcher-silent", "V-h: a heartbeat older than two ticks reaches main",
       json.dumps(active("main", "main")))
lines = project("main")
expect(any("blocked [key=hw-watcher-silent-tetjet-mate]" in line for line in lines),
       "V-h: main's alert-store tick projects it", "\n".join(lines))
tick(RES, T2 + 2000)
expect("hw-watcher-silent-main-seen-by-lattice-research-mate" in active(RES, "main"),
       "V-h: a home that sees main's heartbeat go silent says so in main", json.dumps(list(active(RES, "main"))))
proc = subprocess.run([sys.executable, str(root / "bin/fm-handoff-watch.py"), "release", "--root", str(R),
                       "--home", str(R / TJ)], capture_output=True, text=True, env=BASE_ENV)
expect(proc.returncode == 0 and not (R / TJ / "state/handoff-watch/heartbeat").exists()
       and not (R / TJ / "state/alert-stores/handoff-watch.tetjet-mate.reg").exists(),
       "release unregisters the stores and removes the heartbeat", proc.stderr)
tick("main", T2 + 2100)
expect("hw-watcher-silent-tetjet-mate" not in active("main", "main"), "a released watcher is not reported silent")

# An invalid fragment keeps its last valid revision and alarms its home; an example fragment is never loaded.
FRAG.write_text("{ broken")
tick(RES, T2 + 2200)
frag_keys = [v for v in active(RES, RES).values() if v["kind"] == "source-unreadable" and v["subject"] == str(FRAG)]
expect(frag_keys and "hw-no-receipt-xp-filing-req-2.json" not in active(RES, RES)
       and set(held_keys) <= set(active(RES, "tooling-mate")),
       "an invalid fragment alarms its home and the last valid revision stays in use", json.dumps(active(RES, RES)))
write(FRAG, fragment(revision=2))
write(R / RES / "state/handoff-registry/teach.json", {"example": True, "format": "handoff-registry/v1"})
tick(RES, T2 + 2300)
expect(not [v for v in active(RES, RES).values() if v["kind"] == "source-unreadable"],
       "a valid revision clears it, and an example fragment is skipped", json.dumps(active(RES, RES)))

# Dated rules: 14, 7 and 1 days out and past the date, each step a new key to the rule owner.
day = 86400
rule_day = datetime.datetime.fromtimestamp(T2, datetime.timezone.utc).date() + datetime.timedelta(days=10)
write(FRAG, fragment(revision=3, rule_date=rule_day.isoformat()))
tick(RES, T2 + 2400)
expect("hw-dated-rule-xp-v0-retire-d14" in active(RES, RES), "a dated rule 10 days out is at its 14-day step")
tick(RES, T2 + 9 * day)
expect("hw-dated-rule-xp-v0-retire-d1" in active(RES, RES) and "hw-dated-rule-xp-v0-retire-d14" not in active(RES, RES),
       "one day out it moves to the 1-day step")
tick(RES, T2 + 12 * day)
expect("hw-dated-rule-xp-v0-retire-due" in active(RES, RES), "past its date it stays due on every tick")

# A rule its owner's dated-rule schedule declares is alarmed by fm-dated-rules.sh, not here.
SCHED = write(R / RES / "state/dated-rules/main.json", {
    "format": "dated-rule-schedule/v1", "home": RES, "publisher": "fm-handoff-watch.test", "revision": 1,
    "published_at": "2026-10-21T12:00:00Z",
    "rows": [{"id": "v0-retire.1", "rule": "v0-retire", "owner": RES, "date": rule_day.isoformat(),
              "what": "v0 readers retire", "state": "scheduled"}]})
tick(RES, T2 + 12 * day + 30)
expect(not [k for k in active(RES, RES) if "dated-rule" in k], "a rule in its owner's schedule leaves the watcher",
       json.dumps(active(RES, RES)))
SCHED.unlink()

# A rule owned by another home is linked by this watcher: a fragment date the schedule disagrees with alarms both.
frag = fragment(revision=4, rule_date=rule_day.isoformat())
frag["protocols"][0]["dated_rules"][0]["owner"] = TJ
write(FRAG, frag)
TJ_SCHED = write(R / TJ / "state/dated-rules/main.json", {
    "format": "dated-rule-schedule/v1", "home": TJ, "publisher": "fm-handoff-watch.test", "revision": 1,
    "published_at": "2026-10-21T12:00:00Z",
    "rows": [{"id": "v0-retire.1", "rule": "v0-retire", "owner": TJ, "date": "2031-01-01",
              "what": "v0 readers retire", "state": "scheduled"}]})
tick(RES, T2 + 12 * day + 40)
unlinked = active(RES, TJ).get("hw-dated-rule-xp-v0-retire-unlinked")
expect(unlinked and "says 2031-01-01" in unlinked["reason"] and "hw-dated-rule-xp-v0-retire-unlinked" in active(RES, RES)
       and "hw-dated-rule-xp-v0-retire-due" not in active(RES, TJ),
       "a cross-home fragment date the owner's schedule disagrees with alarms both homes", json.dumps(active(RES, TJ)))
TJ_SCHED.unlink()

# A target this machine does not see falls back to main, saying so.
frag = fragment(revision=5, rule_date=rule_day.isoformat())
frag["protocols"][0]["dated_rules"][0]["owner"] = "lattice-ml-mate"
write(FRAG, frag)
tick(RES, T2 + 12 * day + 60)
due = active(RES, "main").get("hw-dated-rule-xp-v0-retire-due")
expect(due and "lattice-ml-mate" in due["reason"], "an unseen target's alarm goes to main naming it",
       json.dumps(active(RES, "main")))

# Arm and disarm in a home of its own; arm writes only under state/.
home = tmp / "home-arm"
(home / "state").mkdir(parents=True)


def cmd(*args, env=BASE_ENV):
    proc = subprocess.run([WATCH, *args, "--home", str(home)], capture_output=True, text=True, timeout=60,
                          env=env)
    if proc.returncode != 0:
        fail(f"{' '.join(args)} exited {proc.returncode}: {proc.stderr}")
    return proc.stdout


shim = home / "state/handoff-watch.check.sh"
trust = home / "state/handoff-watch.check-trust"
mv_log = tmp / "arm-mv.log"
observed = dict(BASE_ENV, PATH=observer + os.pathsep + BASE_ENV["PATH"],
                FM_TEST_MV_LOG=str(mv_log), FM_TEST_CHECK=str(shim))
expect(cmd("arm", env=observed) == "armed: state/handoff-watch.check.sh\n" and shim.is_file()
       and trust.read_text().splitlines()[0] == "fm-custom-check-v1"
       and list((home / "state/handoff-watch/heartbeat").glob("*.json")),
       "arm runs a first pass, writes the heartbeat and binds the check")
renames = mv_log.read_text().splitlines() if mv_log.exists() else []
expect(renames == ["trust absent", "check bound"], "arm binds the check before it appears", json.dumps(renames))
first = shim.read_bytes()
expect(cmd("arm") == "armed: state/handoff-watch.check.sh\n" and shim.read_bytes() == first, "a second arm is a no-op")
expect(f"check --home {home.resolve()}" in shim.read_text() and shim.stat().st_mode & 0o777 == 0o700, "the shim runs check")
written = [str(p.relative_to(home)) for p in home.rglob("*") if p.is_file()]
expect(all(w.startswith("state/") for w in written), "arm writes only under state/", json.dumps(written))
expect(subprocess.run([str(shim)], capture_output=True, text=True).stdout == "", "a healthy check prints nothing")
expect(cmd("disarm") == "disarmed: state/handoff-watch.check.sh\n" and not shim.exists() and not trust.exists()
       and not (home / "state/handoff-watch/heartbeat").exists(), "disarm removes the check, trust and heartbeat")
PY
