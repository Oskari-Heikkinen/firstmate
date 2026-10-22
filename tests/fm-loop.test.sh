#!/usr/bin/env bash
# Loop status: stages joined from every source, captain holds and parks, TETJET
# capacity alerts shown not re-raised, durable stall alerts with ack, clear and
# recur, lead time per family and week, every source missing or unreadable
# reading as unknown without failing, no write outside the home's alerts, and
# the new-alerts-only check mode with its arm and disarm.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-loop)
OBSERVER=$(fm_check_rename_observer "$TMP_ROOT/arm-observer")
export TZ=UTC

python3 - "$ROOT" "$TMP_ROOT" "$OBSERVER" <<'PY'
import datetime
import hashlib
import json
import os
import shutil
import sqlite3
import subprocess
import sys
import time
from pathlib import Path

root, tmp, observer = Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3]
NOW = 1792000000
H = 3600


def ok(msg):
    print("ok - " + msg)


def fail(msg):
    print("not ok - " + msg)
    sys.exit(1)


def iso(epoch):
    return datetime.datetime.fromtimestamp(epoch, datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def write(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(value if isinstance(value, str) else json.dumps(value))


home = tmp / "home"
src = tmp / "src"
submits = src / "research/data/tetjet-offload/requests"
queue = src / "tj-handoff/queue"
acked = src / "tj-handoff/consumers/tj-operator.acked"
collected = src / "research/data/tetjet-collected/requests"
snapshot = src / "research/data/tetjet-offload/queue-snapshot.json"
batches = src / "lattice-batches"
catalog = src / "lattice-ledger/catalog.sqlite"
backlog = src / "research/data/backlog.md"
parks = src / "research/state"
tj_status = src / "main/state/tetjet-mate.status"
SOURCES = {"submits": submits, "handoff_queue": queue, "operator_acked": acked, "collected": collected,
           "snapshot": snapshot, "batches": batches, "catalog": catalog, "backlog": backlog,
           "parks": parks, "tetjet_status": tj_status}


def config(overrides=None, extra=""):
    paths = dict(SOURCES)
    paths.update(overrides or {})
    lines = ["source %s %s" % (k, v) for k, v in paths.items()]
    lines.append("threshold no_collection_hours 5")
    write(home / "config/loop-sources", "\n".join(lines) + "\n" + extra)


def submit(rid, at, task=None, replaces=None):
    sha = hashlib.sha256(rid.encode()).hexdigest()
    write(submits / (rid + ".submit.json"), {
        "schema": "tetjet-request-submit.v1", "id": rid, "request_sha256": sha, "task": task or rid.rsplit("-", 1)[0],
        "replaces": replaces, "submitted_utc": iso(at)})
    return sha


def record(kind, subject, at, **kw):
    slug = kind.lower().replace(" ", "-")
    rid = "%s--%s--%d" % (slug, subject, at)
    value = {"schema": "tj-handoff/v1", "id": rid, "kind": kind, "subject": subject, "created_at": iso(at),
             "reasons": [], "covers": [], "requests": [], "launch": None}
    value.update(kw)
    write(queue / (rid + ".json"), value)
    return rid


def accept(rid, at, sha):
    record("REQUEST ACCEPTED", rid, at, artefact={"path": str(submits / (rid + ".json")), "sums_sha256": sha})


def package(rid, batch, at, sha):
    return record("READY FOR LAUNCH", batch, at, covers=[{"request_id": rid, "request_sha256": sha, "lines": [0]}],
                  launch={"package": batch, "parent": "/elsewhere"},
                  requests=[{"path": "/elsewhere/packages/%s/requests/%s.json" % (batch, batch), "sha256": "x"}])


def registry(batch, collected_at=None, registered_at=None):
    write(batches / ".registered" / (batch + ".json"), {
        "batch_id": batch, "registered_utc": iso(registered_at or collected_at), "collected_utc": iso(collected_at),
        "collection": {"recorded_utc": iso(collected_at)}})


def analysed(batch, at):
    write(batches / ".analysis" / batch / "CURRENT", {"schema_version": "lattice-batch-analysis-current/v1",
                                                      "analysed_utc": iso(at), "dir": "abc"})


def collect(rid, batch, at, sha, **kw):
    value = {"schema": "tetjet-collected/v1", "request_id": rid, "request_sha256": sha, "outcome": "collected",
             "recorded_at": iso(at), "fully_collected": True, "superseded_by": None, "withdrawn": [],
             "batches": [{"batch_id": batch, "lines": "0", "record": "x"}]}
    value.update(kw)
    write(collected / (rid + ".json"), value)


def build():
    if src.exists():
        shutil.rmtree(src)
    t0 = NOW - 40 * H
    submit("fam-filed-1", NOW - 1 * H)
    sha = submit("fam-refused-1", t0)
    record("REQUEST REFUSED", "fam-refused-1", t0 + 60, reasons=["R8 experiment_id is too long"],
           artefact={"path": "x", "sums_sha256": sha})
    sha = submit("held-acc-1", t0, task="held-acc")
    accept("held-acc-1", NOW - 20 * H, sha)
    sha = submit("fam-ready-1", t0)
    accept("fam-ready-1", NOW - 10 * H, sha)
    package("fam-ready-1", "pkg-ready", NOW - 8 * H, sha)
    sha = submit("fam-taken-1", t0)
    accept("fam-taken-1", t0, sha)
    taken_id = package("fam-taken-1", "pkg-taken", t0 + H, sha)
    sha = submit("fam-run-1", t0)
    accept("fam-run-1", t0, sha)
    package("fam-run-1", "pkg-run", t0 + H, sha)
    sha = submit("fam-cat-1", t0)
    accept("fam-cat-1", t0, sha)
    cat_id = package("fam-cat-1", "pkg-cat", t0 + H, sha)
    sha = submit("fam-end-1", t0)
    accept("fam-end-1", t0, sha)
    package("fam-end-1", "pkg-end", t0 + H, sha)
    sha = submit("fam-col-1", t0)
    accept("fam-col-1", t0, sha)
    package("fam-col-1", "pkg-col", t0 + H, sha)
    collect("fam-col-1", "pkg-col", NOW - 10 * H, sha)
    sha = submit("fam-done-1", t0)
    accept("fam-done-1", t0, sha)
    package("fam-done-1", "pkg-done", t0 + 2 * H, sha)
    collect("fam-done-1", "pkg-done", t0 + 6 * H, sha)
    registry("pkg-done", t0 + 6 * H)
    analysed("pkg-done", t0 + 7 * H)
    sha = submit("fam-arf-1", t0)
    accept("fam-arf-1", t0, sha)
    package("fam-arf-1", "pkg-arf", t0 + H, sha)
    collect("fam-arf-1", "pkg-arf", t0 + 5 * H, sha)
    registry("pkg-arf", t0 + 5 * H)
    write(batches / ".analysis/pkg-arf/refused.json", {
        "schema_version": "lattice-batch-analysis-refusal/v2", "code": "ANALYSIS_INPUT", "message": "wrong batch",
        "refused_utc": iso(t0 + 6 * H), "unresolved_since_utc": iso(t0 + 6 * H)})
    sha = submit("fam-sup-1", t0)
    accept("fam-sup-1", t0, sha)
    record("REQUEST SUPERSEDED", "fam-sup-1", t0 + H, replaced_by="fam-sup-2")
    write(acked, "%s %s\n%s %s\n" % (taken_id, iso(t0 + 2 * H), cat_id, iso(t0 + 2 * H)))
    write(snapshot, {"schema": "tetjet-queue-snapshot.v1", "generated_at": iso(NOW), "jobs": [
        {"id": "pkg-run", "batch_id": "pkg-run", "requests": ["fam-run-1"], "state": "live",
         "state_note": "Launcher running; 3 of 4 jobs ended", "started_utc": iso(NOW - 3 * H), "ended_utc": None},
        {"id": "pkg-end", "batch_id": "pkg-end", "requests": ["fam-end-1"], "state": "ended, closeout unverified",
         "started_utc": iso(NOW - 6 * H), "ended_utc": iso(NOW - 2 * H)}]})
    catalog.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(str(catalog))
    conn.execute("CREATE TABLE runs (entry_id TEXT PRIMARY KEY, run_id TEXT, batch_id TEXT, experiment_id TEXT, started_utc TEXT)")
    conn.execute("INSERT INTO runs VALUES ('e1', 'r1', 'pkg-cat', 'x', ?)", (iso(NOW - 4 * H),))
    conn.commit()
    conn.close()
    write(backlog, "# Backlog\n\n- [ ] held-acc - Wait on a call (kind: task) (hold-kind: captain)\n  Captain hold set: %s\n" % iso(NOW - 30 * H))
    write(parks / "finisher.meta", "park_state=parked\npark_when=cmd:/x/check.py fam-sup-1\npark_deadline=2026-12-01T00:00:00Z\n")
    write(parks / "other.meta", "park_state=parked\npark_when=cmd:/x/check.py fam-sup-10\n")
    write(tj_status, "\n".join([
        "blocked [key=tj-lane-refused] [at=%d]: lane refused" % (NOW - 5 * H),
        "resolved [key=tj-lane-refused] [at=%d]: lane takes work" % (NOW - 4 * H),
        "blocked [key=tj-idle] [at=%d]: machine idle with open requests" % (NOW - H),
        "working [at=%d]: unrelated" % (NOW - 60)]) + "\n")


def run(*args, now=NOW, check=True):
    proc = subprocess.run([str(root / "bin/fm-loop.sh"), *args, "--home", str(home)] +
                          (["--now", str(now)] if args[0] != "ack" else []),
                          capture_output=True, text=True, timeout=60)
    if check and proc.returncode != 0:
        fail("%s exited %d: %s" % (" ".join(args), proc.returncode, proc.stderr))
    return proc


def cursor_of(h):
    return h / "state/loop-alerts/reported.cursor"


def status(now=NOW):
    return json.loads(run("status", "--json", now=now).stdout)


def tree(path):
    out = {}
    for dirpath, _, files in os.walk(path):
        for name in files:
            p = Path(dirpath) / name
            out[str(p)] = hashlib.sha256(p.read_bytes()).hexdigest()
    return out


home.mkdir(parents=True)
build()
config()
before = tree(src)
data = status()
rows = {r["id"]: r for r in data["requests"]}
want = {"fam-filed-1": "filed", "fam-refused-1": "refused", "held-acc-1": "accepted", "fam-ready-1": "launch-ready",
        "fam-taken-1": "taken", "fam-run-1": "running", "fam-cat-1": "running", "fam-end-1": "ended",
        "fam-col-1": "collected", "fam-arf-1": "analysis-refused"}
got = {k: rows[k]["stage"] for k in want if k in rows}
if got != want:
    fail("stages: %s" % got)
if "fam-done-1" in rows or "fam-sup-1" in rows:
    fail("closed or analysed requests listed as open: %s" % sorted(rows))
if [r["id"] for r in data["requests"]][:2] != ["fam-filed-1", "fam-refused-1"]:
    fail("rows are not in loop order: %s" % [r["id"] for r in data["requests"]])
ok("status joins submits, intake, packages, pickups, snapshot, catalog, collected and analyses into one stage each")

if rows["held-acc-1"]["age_seconds"] != 20 * H or rows["held-acc-1"]["captain_hold"] != "held-acc":
    fail("accepted row: %s" % rows["held-acc-1"])
if "R8 experiment_id" not in rows["fam-refused-1"]["reason"] or "3 of 4 jobs" not in rows["fam-run-1"]["reason"]:
    fail("reasons: %s / %s" % (rows["fam-refused-1"]["reason"], rows["fam-run-1"]["reason"]))
if rows["fam-ready-1"]["last_event"]["what"] != "package pkg-ready" or rows["fam-col-1"]["reason"] != "waiting for registration of pkg-col":
    fail("last event or wait reason: %s / %s" % (rows["fam-ready-1"], rows["fam-col-1"]))
ok("age in stage, last event, the waiting reason and a captain hold on the family are reported")

if "pkg-ready" in rows or any(r["id"].startswith("pkg-") for r in data["requests"]):
    fail("a package's own request copy was read as a request")
ok("package request copies outside the submits folder are not requests")

if [t["key"] for t in data["tetjet_alerts"]] != ["tj-idle"]:
    fail("tetjet alerts: %s" % data["tetjet_alerts"])
ids = sorted(a["id"] for a in data["alerts"])
want_ids = ["analysis-refused--pkg-arf", "no-analysis--pkg-col", "no-collection--loop",
            "no-package--held-acc-1", "park-on-closed--finisher--fam-sup-1"]
if ids != want_ids:
    fail("alerts: %s" % ids)
if any(a["condition"].startswith("tj-") for a in data["alerts"]):
    fail("a TETJET alert was re-raised")
ok("stall alerts fire for each condition; TETJET's open capacity alert is shown, its resolved one is not, neither re-raised")

if tree(src) != before:
    fail("a source was changed")
written = sorted(str(p.relative_to(home)) for p in home.rglob("*") if p.is_file())
if any(not (w.startswith("state/loop-alerts/") or w == "config/loop-sources") for w in written):
    fail("wrote outside state/loop-alerts: %s" % written)
ok("every source is left byte-identical and only state/loop-alerts is written")

lines = run("alerts").stdout.splitlines()
if len(lines) != 5 or not lines[0].startswith("analysis-refused--pkg-arf since "):
    fail("alerts mode: %s" % lines)
ack = run("ack", "no-package--held-acc-1")
again = run("ack", "no-package--held-acc-1")
missing = run("ack", "no-such-alert", check=False)
if "acknowledged" not in ack.stdout or "already" not in again.stdout or missing.returncode != 1:
    fail("ack: %r %r %d" % (ack.stdout, again.stdout, missing.returncode))
if any(l.startswith("no-package--held-acc-1") for l in run("alerts").stdout.splitlines()):
    fail("an acked alert still prints")
ok("alerts prints one line per open alert; ack silences one, is idempotent, and refuses an unknown id")

# The refusal resolves and the hold row's request gets a package: one clears unacked, one clears acked.
os.remove(batches / ".analysis/pkg-arf/refused.json")
analysed("pkg-arf", NOW)
package("held-acc-1", "pkg-held", NOW - H, hashlib.sha256(b"held-acc-1").hexdigest())
lines = run("alerts", now=NOW + 60).stdout.splitlines()
cleared = [l for l in lines if l.startswith("analysis-refused--pkg-arf")]
if not cleared or "(cleared " not in cleared[0] or any(l.startswith("no-package--held-acc-1") for l in lines):
    fail("cleared alerts: %s" % lines)
run("ack", "analysis-refused--pkg-arf")
os.remove(queue / ("ready-for-launch--pkg-held--%d.json" % (NOW - H)))
lines = run("alerts", now=NOW + 120).stdout.splitlines()
if not any(l.startswith("no-package--held-acc-1 since %s" % iso(NOW + 120)) for l in lines):
    fail("a recurring acked alert was not raised again: %s" % lines)
log = (home / "state/loop-alerts/log").read_text()
for word in ("raised no-package--held-acc-1", "acked no-package--held-acc-1", "cleared analysis-refused--pkg-arf", "raised again no-package--held-acc-1"):
    if word not in log:
        fail("log lacks %r:\n%s" % (word, log))
ok("a cleared alert prints until acked, a recurring one is raised again, and the log records each step")
build()

text = run("status").stdout
if "tj-idle since" not in text or "held-acc-1" not in text or "[hold: held-acc]" not in text:
    fail("text status: %s" % text)
if "sources: submits ok" not in text:
    fail("sources line: %s" % text)
ok("the text view lists stages, holds, TETJET alerts and loop alerts")

# Each source missing in turn, and each unreadable in turn: the command still succeeds.
for name, path in SOURCES.items():
    config({name: tmp / "nowhere" / path.name})
    proc = run("status", "--json")
    data = json.loads(proc.stdout)
    if data["sources"][name]["state"] != "missing":
        fail("%s missing reads as %s" % (name, data["sources"][name]))
    if "source-unreadable--%s" % name not in [a["id"] for a in data["alerts"]]:
        fail("configured missing %s raised no alert" % name)
    if "%s missing (unknown)" % name not in run("status").stdout:
        fail("%s missing is not shown as unknown" % name)
    run("leadtime")
ok("each source missing in turn reads as unknown, raises a source alert, and fails nothing")

bad = tmp / "bad"
write(bad / "submits/x.submit.json", "{not json")
write(bad / "queue/x.json", "{not json")
(bad / "acked.d").mkdir(parents=True)
write(bad / "collected/x.json", "[]")
write(bad / "snapshot.json", {"schema": "other"})
(bad / "backlog.d").mkdir(parents=True)
write(bad / "catalog.sqlite", "not a database at all, just text that sqlite refuses")
write(bad / "status.d/x", "")
unreadable = {"submits": bad / "submits", "handoff_queue": bad / "queue", "operator_acked": bad / "acked.d",
              "collected": bad / "collected", "snapshot": bad / "snapshot.json", "catalog": bad / "catalog.sqlite",
              "backlog": bad / "backlog.d", "tetjet_status": bad / "status.d"}
for name, path in unreadable.items():
    config({name: path})
    data = status()
    if data["sources"][name]["state"] != "unreadable":
        fail("%s unreadable reads as %s" % (name, data["sources"][name]))
config({"backlog": bad / "backlog.d", "parks": tmp / "nowhere"})
data = status()
rows = {r["id"]: r for r in data["requests"]}
if rows["held-acc-1"]["captain_hold"] != "unknown" or rows["held-acc-1"]["parks"] != "unknown":
    fail("hold and park columns: %s" % rows["held-acc-1"])
config({"handoff_queue": tmp / "nowhere"})
rows = {r["id"]: r for r in status()["requests"]}
if rows["fam-filed-1"]["stage"] != "unknown" or rows["fam-col-1"]["stage"] != "collected":
    fail("hand-off queue missing: %s %s" % (rows["fam-filed-1"]["stage"], rows["fam-col-1"]["stage"]))
config({"snapshot": tmp / "nowhere", "catalog": tmp / "nowhere"})
rows = {r["id"]: r for r in status()["requests"]}
if "start unknown" not in rows["fam-taken-1"]["reason"]:
    fail("start with no snapshot or catalog: %s" % rows["fam-taken-1"])
ok("unreadable sources read as unknown in the columns they feed, and the rest still joins")

config(extra="threshold no_package_hours 3\nthreshold accepted_no_package_hours -1\nbogus line\n")
data = status()
if len(data["warnings"]) != 3 or data["thresholds_hours"]["accepted_no_package_hours"] != 12:
    fail("config warnings: %s %s" % (data["warnings"], data["thresholds_hours"]))
config(extra="threshold accepted_no_package_hours 30\n")
shutil.rmtree(home / "state/loop-alerts")
if "no-package--held-acc-1" in [a["id"] for a in status()["alerts"]]:
    fail("a raised threshold still alerted")
ok("bad config lines are warned about and ignored, and thresholds can be overridden")

config()
data = json.loads(run("leadtime", "--json").stdout)
fams = {f["family"]: f for f in data["families"]}
if fams["fam-ready"]["accepted_to_launch_ready_median_hours"] != 2.0 or fams["held-acc"]["accepted_waiting"] != 1:
    fail("families: %s" % fams)
if fams["fam-done"]["accepted_to_first_result_median_hours"] != 6.0:
    fail("first result: %s" % fams["fam-done"])
weeks = {w["week"]: w for w in data["by_week"]}
if not any(w["stages"]["gate->package"]["n"] for w in weeks.values()) or sum(w["submits"] for w in weeks.values()) != 12:
    fail("weeks: %s" % data["by_week"])
text = run("leadtime").stdout
if "fam-ready" not in text or "gate->package" not in text:
    fail("leadtime text: %s" % text)
ok("leadtime gives accepted-to-launch-ready and to first result per family, and per-stage medians per week")

# alerts --new, the watcher check's mode, in a fresh home.
home = tmp / "home-new"
home.mkdir()
build()
config()
cursor = cursor_of(home)


def new(now):
    return run("alerts", "--new", now=now).stdout.splitlines()


if new(NOW) or not cursor.is_file() or not run("alerts").stdout.strip():
    fail("the first run printed or did not seed")
if new(NOW + 60):
    fail("a seeded alert printed")
if "seeded the reported cursor with 5 alert(s)" not in (home / "state/loop-alerts/log").read_text():
    fail("the seed is not logged")
ok("the first run seeds every open alert as reported and prints nothing")

sha = submit("fresh-acc-1", NOW - 30 * H)
accept("fresh-acc-1", NOW - 20 * H, sha)
lines = new(NOW + 120)
if len(lines) != 1 or not lines[0].startswith("no-package--fresh-acc-1 since %s: " % iso(NOW + 120)):
    fail("a new alert: %s" % lines)
if new(NOW + 180) or new(NOW + 240):
    fail("a reported alert printed again")
ok("a newly opened alert prints once and never again")

package("fresh-acc-1", "pkg-fresh", NOW, sha)
if new(NOW + 300):
    fail("a clear printed")
os.remove(queue / ("ready-for-launch--pkg-fresh--%d.json" % NOW))
lines = new(NOW + 360)
if len(lines) != 1 or not lines[0].startswith("no-package--fresh-acc-1 since %s: " % iso(NOW + 360)):
    fail("a recurring alert: %s" % lines)
if new(NOW + 420):
    fail("a recurring alert printed twice")
ok("an alert that clears and recurs prints again, once")

sha = submit("acked-acc-1", NOW - 30 * H)
accept("acked-acc-1", NOW - 20 * H, sha)
run("alerts", now=NOW + 480)
run("ack", "no-package--acked-acc-1")
if new(NOW + 540):
    fail("an acknowledged alert printed")
ok("an acknowledged alert never prints")


def unreadable_lines(lines, source):
    want = "source-unreadable--%s since " % source
    if len(lines) != 1 or not lines[0].startswith(want):
        fail("expected one %s line: %s" % (want, lines))


config({"handoff_queue": bad / "queue"})
unreadable_lines(new(NOW + 600), "handoff_queue")
if new(NOW + 660):
    fail("an unreadable source printed twice")
rec = json.loads((home / "state/loop-alerts/no-package--fresh-acc-1.json").read_text())
if rec["cleared_at"]:
    fail("an alert cleared while its source was unreadable: %s" % rec)
ok("an unreadable source prints once, and holds clears so its return raises nothing")

config()
if new(NOW + 720):
    fail("a source coming back printed")
config({"handoff_queue": bad / "queue"})
unreadable_lines(new(NOW + 780), "handoff_queue")
if new(NOW + 790):
    fail("a returning unreadable source printed twice")
ok("an unreadable source that clears and returns prints again, once")

config()
new(NOW + 800)
config({"collected": tmp / "nowhere"})
unreadable_lines(new(NOW + 820), "collected")
if new(NOW + 840):
    fail("a missing source printed twice")
config()
if new(NOW + 860):
    fail("a missing source coming back printed")
ok("a missing source prints once, the same as an unreadable one")

record_path = home / "state/loop-alerts/analysis-refused--pkg-arf.json"
inode = record_path.stat().st_ino
write(home / "state/loop-alerts/.receipt-left", "{}")
if new(NOW + 865) or record_path.stat().st_ino != inode:
    fail("a run with nothing new printed or rewrote an unchanged alert record")
if (home / "state/loop-alerts/.receipt-left").exists() or "removed .receipt-left" not in (home / "state/loop-alerts/log").read_text():
    fail("a temp file left by a stopped run was not removed and logged")
ok("an unchanged alert record is not rewritten, and a stopped run's temp file is removed")

# A source that blocks (a FIFO nobody writes) reads as unknown within its bound.
fifo = tmp / "blocking.status"
os.mkfifo(fifo)
config({"tetjet_status": fifo})
package("fresh-acc-1", "pkg-fresh", NOW, hashlib.sha256(b"fresh-acc-1").hexdigest())
started = time.monotonic()
proc = subprocess.run([str(root / "bin/fm-loop.sh"), "alerts", "--new", "--home", str(home), "--now", str(NOW + 880)],
                      capture_output=True, text=True, timeout=60, env=dict(os.environ, FM_CHECK_TIMEOUT="12"))
took = time.monotonic() - started
unreadable_lines(proc.stdout.splitlines(), "tetjet_status")
if "did not finish within 1s" not in proc.stdout or took > 7 or (home / "state/loop-alerts/check-failure").exists():
    fail("a blocking source in a 7s check took %.1fs: %r" % (took, proc.stdout))
if json.loads((home / "state/loop-alerts/no-package--fresh-acc-1.json").read_text())["cleared_at"]:
    fail("an alert cleared while a source was blocked")
proc = subprocess.run([str(root / "bin/fm-loop.sh"), "status", "--json", "--home", str(home), "--now", str(NOW + 890)],
                      capture_output=True, text=True, timeout=60, env=dict(os.environ, FM_LOOP_READ_TIMEOUT="1"))
view = json.loads(proc.stdout)["sources"]["tetjet_status"]
if view["state"] != "unreadable" or "did not finish" not in view["detail"]:
    fail("a blocked source in status: %s" % view)
config()
os.remove(queue / ("ready-for-launch--pkg-fresh--%d.json" % NOW))
if new(NOW + 895):
    fail("a blocked source coming back printed")
ok("a blocking source reads as unknown within its bound, raises source-unreadable once, holds clears, and the check stays in its cap")

cursor.write_text("{not json")
lines = new(NOW + 900)
if len(lines) != 1 or "reseeded" not in lines[0] or new(NOW + 960):
    fail("an unreadable cursor: %s" % lines)
ok("an unreadable cursor prints one line and is reseeded")

home = tmp / "home-arm"
(home / "state").mkdir(parents=True)
config()
before_arm = tree(src)
shim = home / "state/loop-alerts.check.sh"
trust = home / "state/loop-alerts.check-trust"


def loop_cmd(*args, env=None):
    proc = subprocess.run([str(root / "bin/fm-loop.sh"), *args, "--home", str(home)],
                          capture_output=True, text=True, timeout=60, env=env)
    if proc.returncode != 0:
        fail("%s exited %d: %s" % (" ".join(args), proc.returncode, proc.stderr))
    return proc.stdout


mv_log = tmp / "arm-mv.log"
observed = dict(os.environ, PATH=observer + os.pathsep + os.environ["PATH"],
                FM_TEST_MV_LOG=str(mv_log), FM_TEST_CHECK=str(shim))
if loop_cmd("arm", env=observed) != "armed: state/loop-alerts.check.sh\n" or not cursor_of(home).is_file():
    fail("arm did not arm and seed")
renames = mv_log.read_text().splitlines() if mv_log.exists() else []
if renames != ["trust absent", "check bound"]:
    fail("arm did not bind the shim before it appeared: %s" % renames)
first = (shim.read_bytes(), cursor_of(home).read_bytes())
if loop_cmd("arm") != "armed: state/loop-alerts.check.sh\n" or (shim.read_bytes(), cursor_of(home).read_bytes()) != first:
    fail("a second arm changed the shim or reseeded")
if shim.stat().st_mode & 0o777 != 0o700 or "alerts --new --home %s" % home.resolve() not in shim.read_text():
    fail("shim: %o %s" % (shim.stat().st_mode, shim.read_text()))
if trust.read_text().splitlines()[0] != "fm-custom-check-v1":
    fail("the shim is not bound")
written = sorted(str(p.relative_to(home)) for p in home.rglob("*") if p.is_file())
if any(not (w.startswith("state/") or w == "config/loop-sources") for w in written) or tree(src) != before_arm:
    fail("arm wrote outside state: %s" % written)
if loop_cmd("disarm") != "disarmed: state/loop-alerts.check.sh\n":
    fail("disarm output")
if shim.exists() or trust.exists() or cursor_of(home).exists():
    fail("disarm left the shim, trust or cursor")
ok("arm seeds, binds and then writes the check idempotently inside state/, and disarm removes it")

# The capacity filler watch: lane alerts, queue-state and the stale alarm.
filler = tmp / "filler"
lane_path = filler / "state/lane-alerts.json"
qs_path = filler / "offload/requests/filler/queue-state.json"
stop_path = filler / "state/STOP"
FILLER_LINES = "source lane_alerts %s\nsource queue_state %s\nsource filler_stop %s\n" % (lane_path, qs_path, stop_path)


def stamp(path, at):
    os.utime(path, (at, at))


def lane_alert(kind, subject, reason, since, **evidence):
    key = "%s:%s:%s" % (kind, subject, hashlib.sha256(reason.encode()).hexdigest())
    return {"key": key, "kind": kind, "subject": subject, "reason": reason, "since": iso(since), "evidence": evidence}


def alert_id(a):
    return "%s--%s--%s" % (a["kind"], a["subject"], hashlib.sha256(a["key"].encode()).hexdigest()[:10])


class Filler:
    """Writes lane-alerts.json the way the filler's write_alerts does."""

    def __init__(self):
        self.active, self.events, self.revision = {}, [], 0

    def tick(self, at, *wanted):
        new = {}
        for a in wanted:
            new[a["key"]] = dict(a, detected_at=(self.active.get(a["key"]) or {}).get("detected_at") or iso(at))
        for key in sorted(set(self.active) - set(new)):
            self.revision += 1
            self.events.append({"seq": self.revision, "at": iso(at), "action": "cleared", "key": key, "alert": self.active[key]})
        for key in sorted(set(new) - set(self.active)):
            self.revision += 1
            self.events.append({"seq": self.revision, "at": iso(at), "action": "raised", "key": key, "alert": new[key]})
        self.active = new
        write(lane_path, {"schema": "tj-capacity-alerts/v1", "at": iso(at), "revision": self.revision,
                          "active": self.active, "events": self.events})
        stamp(lane_path, at)


QS_V1 = {"seq": 15001, "schema": "tj-capacity-queue-state/v1", "state": "empty", "free_slots": 22,
         "admissible_run_eq": 22, "queued_run_eq": 0, "why": None, "refused_no_room": None,
         "reclaimable": {"bytes": 0, "roots": 0, "unsized": 0, "inventory": "2026-10-18.json", "written": "2026-10-18T00:03:32Z"},
         "free_slots_basis": "reference job only, not actual-job admission", "next_job": None}
QS_V2 = {"seq": 15002, "schema": "tj-capacity-queue-state/v2", "state": "empty", "free_slots": 7,
         "admissible_run_eq": 7, "queued_run_eq": 0, "why": "tjpkg: launch-check: no valid recorded PASS",
         "refusing": True, "since": "2026-10-18T00:00:00Z", "refused_no_room": None, "reclaimable": None,
         "lanes": {"tjpkg": {"state": "refusing", "reasons": ["r: launch-check: no valid recorded PASS"],
                             "key": "ab" * 32, "since": "2026-10-18T00:00:00Z", "evidence": {}}},
         "free_slots_basis": "reference job only, not actual-job admission", "next_job": None}


def queue_state(doc, at):
    write(qs_path, dict(doc, at=iso(at)))
    stamp(qs_path, at)


def lane_lines(lines):
    return [l for l in lines if l.split("--", 1)[0] in ("lane-refusing", "accepted-no-pickup", "no-liveness", "rc-unknown", "filler-stale")]


# A home without the filler lines is unchanged.
home = tmp / "home-plain"
home.mkdir()
build()
config()
data = status()
if "filler" in data or any(n in data["sources"] for n in ("lane_alerts", "queue_state", "filler_stop")):
    fail("an unconfigured home shows the filler: %s" % sorted(data))
if "TETJET filler" in run("status").stdout:
    fail("an unconfigured home prints the filler")
ok("a home that names no filler file reads none and shows nothing new")

home = tmp / "home-filler"
home.mkdir()
config(extra=FILLER_LINES)
lane_cursor = home / "state/loop-alerts/lane-alerts.cursor"
fill = Filler()
refusing = lane_alert("lane-refusing", "tjpkg", "launch step pin mismatch", NOW - H)
probe = lane_alert("no-liveness", "capacity-probe", "capacity probe unavailable", NOW - 2 * H, error="timeout")
pickup = lane_alert("accepted-no-pickup", "accepted-r1", "ACCEPTED has no matching pickup within 1 h", NOW - 3 * H,
                    request_path="/request/r1.json", request_sha256="a" * 64)
flap = lane_alert("rc-unknown", "r7", "launch step rc unknown; filler will not retry", NOW)
later = lane_alert("accepted-no-pickup", "accepted-r2", "ACCEPTED has no matching pickup within 1 h", NOW)
fill.tick(NOW - 60, refusing, probe)
queue_state(QS_V1, NOW - 60)
if new(NOW) or json.loads(lane_cursor.read_text())["revision"] != 2:
    fail("the first run printed or did not seed the lane cursor")
lines = run("alerts", now=NOW).stdout.splitlines()
if sorted(l.split(" ", 1)[0] for l in lane_lines(lines)) != sorted([alert_id(refusing), alert_id(probe)]):
    fail("seeded lane alerts: %s" % lines)
rec = json.loads((home / "state/loop-alerts" / (alert_id(probe) + ".json")).read_text())
if rec["condition"] != "no-liveness" or "capacity probe unavailable" not in rec["message"] or "error=timeout" not in rec["message"] \
        or "since %s" % iso(NOW - 2 * H) not in rec["message"]:
    fail("lane alert record: %s" % rec)
if "seeded the lane alerts cursor at revision 2" not in (home / "state/loop-alerts/log").read_text():
    fail("the lane seed is not logged")
ok("the first run seeds the active lane alerts quietly; each is an alert with its subject, reason, since and evidence")

fill.tick(NOW + 30, probe, pickup)
queue_state(QS_V1, NOW + 30)
lines = lane_lines(new(NOW + 60))
if len(lines) != 1 or not lines[0].startswith("%s since %s: accepted-no-pickup accepted-r1" % (alert_id(pickup), iso(NOW + 30))):
    fail("a new lane alert: %s" % lines)
rec = json.loads((home / "state/loop-alerts" / (alert_id(refusing) + ".json")).read_text())
if rec["cleared_at"] != iso(NOW + 30):
    fail("a cleared lane alert: %s" % rec)
fill.tick(NOW + 90, probe, pickup)
if lane_lines(new(NOW + 100)):
    fail("an unchanged lane alert printed again")
ok("a raised lane event prints once, a cleared one clears its record, and an unchanged tick adds nothing")

fill.tick(NOW + 120, probe, pickup, flap)
fill.tick(NOW + 150, probe, pickup)
lines = lane_lines(new(NOW + 160))
if len(lines) != 1 or not lines[0].startswith("%s since %s (cleared %s)" % (alert_id(flap), iso(NOW + 120), iso(NOW + 150))):
    fail("a raise and clear between runs: %s" % lines)
fill.tick(NOW + 180, probe, pickup, refusing)
lines = lane_lines(new(NOW + 190))
if len(lines) != 1 or not lines[0].startswith("%s since %s: " % (alert_id(refusing), iso(NOW + 180))):
    fail("a recurring lane alert: %s" % lines)
if lane_lines(new(NOW + 200)):
    fail("a recurring lane alert printed twice")
run("ack", alert_id(pickup))
fill.tick(NOW + 210, probe, pickup, refusing)
if lane_lines(new(NOW + 220)):
    fail("an acknowledged lane alert printed")
ok("a raise and clear between runs prints once, marked cleared; a clear then a recurrence prints again; an ack silences")

lane_cursor.write_text("{not json")
fill.tick(NOW + 240, probe, pickup, later)
lines = lane_lines(new(NOW + 250))
if len(lines) != 1 or not lines[0].startswith(alert_id(later) + " since "):
    fail("cursor loss replayed or missed: %s" % lines)
if json.loads((home / "state/loop-alerts" / (alert_id(refusing) + ".json")).read_text())["cleared_at"] != iso(NOW + 250):
    fail("cursor loss did not reconcile a cleared alert")
if "lane alerts cursor was unreadable; reconciled" not in (home / "state/loop-alerts/log").read_text():
    fail("cursor loss is not logged")
ok("a lost cursor reconciles with the active alerts and never replays the journal")

fill = Filler()
fill.tick(NOW + 270, probe, flap)
lines = lane_lines(new(NOW + 280))
if len(lines) != 1 or not lines[0].startswith("%s since " % alert_id(flap)) or "(cleared" in lines[0]:
    fail("a revision going backwards: %s" % lines)
if json.loads(lane_cursor.read_text())["revision"] != 2 or "ahead of the file's 2" not in (home / "state/loop-alerts/log").read_text():
    fail("a backwards revision did not reseat the cursor")
ok("a revision going backwards reconciles with the active alerts")

queue_state(QS_V2, NOW + 270)
data = status(now=NOW + 280)
q = data["filler"]["queue_state"]
if q["supply"] != {"state": "empty", "admissible_run_eq": 7, "free_slots": 7, "queued_run_eq": 0}:
    fail("v2 supply: %s" % q)
if q["lane_health"]["refusing"] is not True or q["lane_health"]["lanes"]["tjpkg"]["state"] != "refusing" \
        or q["lane_health"]["lanes"]["tjpkg"]["key"] != "ab" * 32:
    fail("v2 lane health: %s" % q)
text = run("status", now=NOW + 280).stdout
if "supply: state empty, admissible_run_eq 7" not in text or "lane health: refusing since 2026-10-18T00:00:00Z" not in text \
        or "tjpkg refusing since" not in text:
    fail("v2 text: %s" % text)
queue_state(QS_V1, NOW + 270)
data = status(now=NOW + 280)
if data["filler"]["queue_state"]["supply"]["admissible_run_eq"] != 22 or data["filler"]["queue_state"]["lane_health"] is not None:
    fail("v1: %s" % data["filler"])
if "lane health: not in a v1 snapshot" not in run("status", now=NOW + 280).stdout:
    fail("v1 text")
if data["filler"]["problems"] or "filler-stale--tj-capacity" in [a["id"] for a in data["alerts"]]:
    fail("fresh files raised filler-stale: %s" % data["filler"])
ok("queue-state v1 and v2 show supply and lane health as separate fields")

written = sorted(str(p.relative_to(home)) for p in home.rglob("*") if p.is_file())
if any(not (w.startswith("state/loop-alerts/") or w == "config/loop-sources") for w in written):
    fail("wrote outside state/loop-alerts: %s" % written)
snap = tree(filler)
run("status", now=NOW + 290)
new(NOW + 290)
if tree(filler) != snap:
    fail("a filler file was changed")
ok("the filler's files are only read")

lines = lane_lines(new(NOW + 270 + 6 * 60))
if len(lines) != 1 or not lines[0].startswith("filler-stale--tj-capacity since ") \
        or "lane_alerts last written 0h06m" not in lines[0] or "queue_state last written 0h06m" not in lines[0]:
    fail("stale files: %s" % lines)
fill.tick(NOW + 700, probe, flap)
queue_state(QS_V1, NOW + 700)
stamp(qs_path, NOW + 270)
data = status(now=NOW + 700)
if data["filler"]["problems"] != [p for p in data["filler"]["problems"] if p.startswith("queue_state last written")] \
        or not data["filler"]["problems"]:
    fail("an old mtime with a fresh at is not stale: %s" % data["filler"]["problems"])
queue_state(QS_V1, NOW + 700)
data = status(now=NOW + 710)
stale = [a for a in data["alerts"] if a["id"] == "filler-stale--tj-capacity"]
if data["filler"]["problems"] or not stale or not stale[0]["cleared_at"]:
    fail("fresh files did not clear filler-stale: %s" % data["filler"])
run("ack", "filler-stale--tj-capacity")
ok("files older than the threshold by at or by mtime raise one filler-stale alert, which clears when they are fresh")

config(extra=FILLER_LINES + "threshold filler_stale_minutes 30\n")
if status(now=NOW + 700 + 20 * 60)["filler"]["problems"]:
    fail("a raised stale threshold still alarmed")
config(extra=FILLER_LINES)
write(stop_path, "")
data = status(now=NOW + 700 + 60 * 60)
if data["filler"]["problems"] or data["filler"]["stopped"] is not True or "STOP marker present" not in run("status", now=NOW + 3 * H).stdout:
    fail("STOP still alarmed: %s" % data["filler"])
os.remove(stop_path)
lines = lane_lines(new(NOW + 700 + 61 * 60))
if len(lines) != 1 or not lines[0].startswith("filler-stale--tj-capacity"):
    fail("stale files after STOP is removed: %s" % lines)
ok("the stale threshold can be raised, and the filler's STOP marker means no alarm")

stale_at = NOW + 700 + 62 * 60
fill.tick(stale_at, probe, flap)
queue_state(QS_V1, stale_at)
new(stale_at)
os.remove(lane_path)
write(qs_path, dict(QS_V1, schema="tj-capacity-queue-state/v3", at=iso(stale_at)))
data = status(now=stale_at + 10)
problems = " | ".join(data["filler"]["problems"])
if "lane_alerts missing" not in problems or "tj-capacity-queue-state/v3" not in problems or "refused" not in problems:
    fail("missing and unknown-schema files: %s" % problems)
if data["sources"]["queue_state"]["state"] != "unreadable":
    fail("an unknown queue-state schema was read: %s" % data["sources"]["queue_state"])
ids = [a["id"] for a in data["alerts"]]
if any(i.startswith("source-unreadable--") for i in ids):
    fail("a filler file raised source-unreadable: %s" % ids)
if json.loads((home / "state/loop-alerts" / (alert_id(probe) + ".json")).read_text())["cleared_at"]:
    fail("a lane alert cleared while its file was missing")
lines = lane_lines(new(stale_at + 20))
if len(lines) != 1 or not lines[0].startswith("filler-stale--tj-capacity"):
    fail("a missing file did not alarm: %s" % lines)
write(lane_path, {"schema": "tj-capacity-alerts/v2", "at": iso(stale_at), "revision": 0, "active": {}, "events": []})
queue_state(QS_V1, stale_at)
data = status(now=stale_at + 30)
if data["sources"]["lane_alerts"]["state"] != "unreadable" or not data["filler"]["problems"]:
    fail("an unknown lane alerts schema was read: %s" % data["sources"]["lane_alerts"])
ok("a missing file or an unknown schema in either is refused and alarms, and holds the lane alerts")

# Installed before the filler writes its first file: every event in it then prints.
home = tmp / "home-install"
home.mkdir()
config(extra=FILLER_LINES)
os.remove(lane_path)
queue_state(QS_V1, NOW)
new(NOW)
if json.loads((home / "state/loop-alerts/lane-alerts.cursor").read_text())["revision"] != 0:
    fail("a missing file did not seed the lane cursor at revision 0")
fill = Filler()
fill.tick(NOW + 60, pickup, later, probe)
queue_state(QS_V1, NOW + 60)
lines = lane_lines(new(NOW + 70))
if sorted(l.split(" ", 1)[0] for l in lines) != sorted(alert_id(a) for a in (pickup, later, probe)):
    fail("events in a first file: %s" % lines)
ok("a home armed before the filler's first file reports every alert in it")

# A large untruncated journal stays well inside the check's cap.
fill = Filler()
fill.active = {probe["key"]: dict(probe, detected_at=iso(NOW))}
big = dict(probe, evidence={"error": "x" * 200})
fill.events = [{"seq": n, "at": iso(NOW), "action": ("raised", "cleared")[n % 2], "key": big["key"], "alert": big}
               for n in range(1, 60001)]
fill.revision = 60000
fill.tick(NOW + 600, probe)
queue_state(QS_V1, NOW + 600)
lane_cursor = home / "state/loop-alerts/lane-alerts.cursor"
lane_cursor.write_text(json.dumps({"schema": "fm-loop-lane-cursor.v1", "path": str(lane_path), "revision": 0}))
started = time.monotonic()
new(NOW + 610)
took = time.monotonic() - started
if took > 15 or lane_path.stat().st_size < 10 * 1024 * 1024:
    fail("a %d-byte journal took %.1fs" % (lane_path.stat().st_size, took))
ok("a %d MiB journal is followed in %.1fs" % (lane_path.stat().st_size // (1024 * 1024), took))

# Sources declared in the handoff registry: a stage's <home>.loop-source key.
home = tmp / "home-registry"
home.mkdir()
build()
config()
plain = status()
if "registry" in plain["sources"] or "filler_groups" in plain:
    fail("a home with no fragment reads a registry: %s" % sorted(plain["sources"]))
extra_submits = tmp / "elsewhere/requests"
write(extra_submits / "far-filed-1.submit.json", {"schema": "tetjet-request-submit.v1", "id": "far-filed-1",
                                                  "request_sha256": "f" * 64, "task": "far", "submitted_utc": iso(NOW - H)})
lane2 = tmp / "elsewhere/lane-alerts.json"
fragment = json.loads((root / "docs/handoff-coverage/examples/xp-chain.fragment.json").read_text())
fragment.pop("example", None)
owner = fragment["home"]
stages = fragment["protocols"][0]["stages"]
pid = fragment["protocols"][0]["id"]
stages[0]["input"]["path"] = str(extra_submits)
stages[0]["ext"] = {owner + ".loop-source": "submits"}
stages[1]["ext"] = {owner + ".loop-source": "lane_alerts=%s" % lane2, "main.loop-source": "catalog=/nowhere"}
group = "%s/%s" % (pid, stages[1]["name"])
write(home / "state/handoff-registry/xp.json", fragment)
lane_doc = {"schema": "tj-capacity-alerts/v1", "at": iso(NOW), "revision": 0, "active": {}, "events": []}
write(lane2, lane_doc)
stamp(lane2, NOW)
before = tree(src)
data = status()
rows = {r["id"]: r for r in data["requests"]}
if rows.get("far-filed-1", {}).get("stage") != "filed" or rows.get("fam-filed-1", {}).get("stage") != "filed":
    fail("declared submits are not joined with configured ones: %s" % sorted(rows))
if data["sources"]["submits"]["paths"] != [str(submits), str(extra_submits)] or data["sources"]["catalog"]["paths"] != [str(catalog)]:
    fail("declared paths: %s / %s" % (data["sources"]["submits"], data["sources"]["catalog"]))
if data["sources"]["registry"]["state"] != "ok" or group not in data.get("filler_groups", {}) or "filler" in data:
    fail("registry or filler group: %s / %s" % (data["sources"]["registry"], sorted(data)))
ok("a stage's loop-source key adds its input place to configured paths; a key under another home's name is ignored")

new(NOW + 30)

refusing2 = lane_alert("lane-refusing", "tjpkg", "lane two refuses", NOW)
write(lane2, dict(lane_doc, at=iso(NOW + 60), revision=1, active={refusing2["key"]: dict(refusing2, detected_at=iso(NOW + 60))},
                  events=[{"seq": 1, "at": iso(NOW + 60), "action": "raised", "key": refusing2["key"], "alert": refusing2}]))
stamp(lane2, NOW + 60)
lines = [l for l in new(NOW + 90) if l.startswith("lane-refusing--")]
cursor2 = home / "state/loop-alerts" / ("lane-alerts--%s.cursor" % group.replace("/", "--"))
if len(lines) != 1 or alert_id(refusing2) in lines[0] or json.loads(cursor2.read_text())["revision"] != 1:
    fail("a declared filler group's lane alert: %s" % lines)
if "filler %s (declared in the handoff registry" % group not in run("status", now=NOW + 90).stdout:
    fail("status does not name the filler group")
lines = new(NOW + 60 + 6 * 60 + 30)
if not any(l.startswith("filler-stale--%s since " % group.replace("/", "_")) for l in lines):
    fail("a declared filler group's stale file: %s" % lines)
ok("a declared filler group keeps its own cursor, alert ids and filler-stale subject")

broken = dict(fragment, unknown_field=1)
write(home / "state/handoff-registry/other.json", {"format": "handoff-registry/v1", "home": "x"})
data = status(now=NOW + 7 * 60)
if data["sources"]["registry"]["state"] != "ok":
    fail("an invalid fragment that names no loop source was read as unknown: %s" % data["sources"]["registry"])
write(home / "state/handoff-registry/other.json", broken)
data = status(now=NOW + 8 * 60)
if data["sources"]["registry"]["state"] != "unreadable" or "source-unreadable--registry" not in [a["id"] for a in data["alerts"]]:
    fail("an invalid fragment naming a loop source: %s" % data["sources"]["registry"])
if any(a.get("cleared_at") for a in data["alerts"] if a["id"].startswith("filler-stale--")):
    fail("an alert cleared while the registry was unknown")
os.remove(home / "state/handoff-registry/other.json")
if tree(src) != before:
    fail("a source was changed")
written = sorted(str(p.relative_to(home)) for p in home.rglob("*") if p.is_file())
if any(not (w.startswith("state/loop-alerts/") or w == "config/loop-sources" or w.startswith("state/handoff-registry/")) for w in written):
    fail("wrote outside state/loop-alerts: %s" % written)
ok("an invalid fragment that may declare a source raises source-unreadable and holds clears; others are its watcher's")
PY

if "$ROOT/bin/fm-loop.sh" bogus >/dev/null 2>&1; then fail "an unknown command succeeded"; fi
"$ROOT/bin/fm-loop.sh" --help | grep -q 'fm-loop.sh status' || fail "--help lacks usage"
pass "an unknown command fails and --help prints usage"
