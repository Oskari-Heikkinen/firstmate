#!/usr/bin/env bash
# Loop status: stages joined from every source, captain holds and parks, TETJET
# capacity alerts shown not re-raised, durable stall alerts with ack, clear and
# recur, lead time per family and week, every source missing or unreadable
# reading as unknown without failing, and no write outside the home's alerts.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-loop)
export TZ=UTC

python3 - "$ROOT" "$TMP_ROOT" <<'PY'
import datetime
import hashlib
import json
import os
import shutil
import sqlite3
import subprocess
import sys
from pathlib import Path

root, tmp = Path(sys.argv[1]), Path(sys.argv[2])
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
PY

if "$ROOT/bin/fm-loop.sh" bogus >/dev/null 2>&1; then fail "an unknown command succeeded"; fi
"$ROOT/bin/fm-loop.sh" --help | grep -q 'fm-loop.sh status' || fail "--help lacks usage"
pass "an unknown command fails and --help prints usage"
