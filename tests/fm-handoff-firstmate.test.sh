#!/usr/bin/env bash
# fm-handoff-firstmate: Firstmate's own handoffs in a scratch root of four
# homes. publish writes a valid fragment once and raises its revision only on a
# change; tooling-mate's fragment declares every home's heartbeat folder as the
# handoff-watch outbox without the watcher evaluating it. The drills: a marked
# request whose reply never came raises a level to the receiving home and the
# sender, reaching main at 4 h; a handled request with its correlated reply
# clears it; an inbox message left unhandled through the re-ring ladder and a
# delivery-unknown escalation route to their fix owners; a launched task with
# no first status line goes past its bound until the line arrives; and a
# secondmate's open keyed decision stays a record until resolved. A home whose
# config/merge-queue names a queue declares its merge-queue watch receipts as a
# planned stage of the train's home, with one key and outbox per home, which
# watch-target prints for the arming adapter.
# Covers bin/fm-handoff-firstmate.py, bin/fm_handoff_adapters.py and their
# read path in bin/fm-handoff-watch.py.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-handoff-firstmate)
export TZ=UTC

python3 - "$ROOT" "$TMP_ROOT" <<'PY'
import fnmatch
import json
import os
import re
import subprocess
import sys
import time
from pathlib import Path

root, tmp = Path(sys.argv[1]), Path(sys.argv[2])
NOW = int(time.time()) // 3600 * 3600
H = 3600
WATCH = str(root / "bin/fm-handoff-watch.sh")
STORE = str(root / "bin/fm-alert-store.sh")
PUBLISH = str(root / "bin/fm-handoff-firstmate.py")
R = (tmp / "machine").resolve()
LEAD, DOCS = "lead-mate", "docs-mate"
BASE_ENV = {k: v for k, v in os.environ.items()
            if k not in ("FM_HOME", "FM_STATE_OVERRIDE", "FM_ROOT_OVERRIDE", "FM_CONFIG_OVERRIDE",
                         "FM_MERGE_QUEUE_DIR")}


def ok(msg):
    print("ok - " + msg)


def fail(msg):
    print("not ok - " + msg)
    sys.exit(1)


def expect(cond, msg, detail=""):
    if not cond:
        fail(f"{msg}\n{detail}")
    ok(msg)


def run(*args, check=True, env=None):
    proc = subprocess.run([*map(str, args)], capture_output=True, text=True, timeout=60, env=env or BASE_ENV)
    if check and proc.returncode != 0:
        fail(f"{' '.join(map(str, args))} exited {proc.returncode}: {proc.stderr}")
    return proc


def tick(hid, now):
    return run(WATCH, "tick", "--root", R, "--home", R / hid, "--now", now)


def active(observer, target):
    path = R / observer / "state/handoff-watch/stores" / f"{target}.json"
    return json.loads(path.read_text())["active"] if path.exists() else {}


def keys(observer, target, prefix):
    return [k for k in active(observer, target) if k.startswith(prefix)]


def at(path, epoch):
    os.utime(path, (epoch, epoch))
    return path


for hid in ("main", "tooling-mate", LEAD, DOCS):
    (R / hid / "state").mkdir(parents=True)
(R / LEAD / "data").mkdir()
mates = R / LEAD / "data/secondmates.md"
mates.write_text(f"- {DOCS} - documentation lane (home: {R / DOCS})\n")
state = R / LEAD / "state"

# Publish: a valid fragment, written once, a new revision only on a change.
frag = state / "handoff-registry/firstmate.json"
out = run(sys.executable, PUBLISH, "publish", "--root", R, "--home", R / LEAD).stdout
expect(out == f"published {frag} revision 1\n" and frag.is_file(), "publish writes the fragment at revision 1", out)
valid = run(sys.executable, root / "bin/fm-handoff-validate.py", "fragment", frag, check=False)
expect(valid.returncode == 0, "the published fragment validates", valid.stdout + valid.stderr)
doc = json.loads(frag.read_text())
stages = {p["id"]: [s["name"] for s in p["stages"]] for p in doc["protocols"]}
expect(stages == {f"fm-brief.{LEAD}": ["launch"], f"fm-corr.{LEAD}": [f"reply.{DOCS}"],
                  f"fm-status.{LEAD}": [f"status.{DOCS}"]},
       "the fragment declares briefs, marked requests and status lines, one stage per secondmate", json.dumps(stages))
printed = json.loads(run(sys.executable, PUBLISH, "fragment", "--root", R, "--home", R / LEAD).stdout)
expect(printed["protocols"] == doc["protocols"], "fragment prints what publish writes")
out = run(sys.executable, PUBLISH, "publish", "--root", R, "--home", R / LEAD).stdout
expect(out == f"unchanged {frag} revision 1\n", "an unchanged publish writes nothing", out)
mates.write_text(mates.read_text() + f"- far-mate - remote lane (host: far; home: /srv/far)\n")
out = run(sys.executable, PUBLISH, "publish", "--root", R, "--home", R / LEAD).stdout
expect(out == f"unchanged {frag} revision 1\n", "a remote secondmate adds no stage", out)
(R / "late-mate/state").mkdir(parents=True)
mates.write_text(mates.read_text() + f"- late-mate - another lane (home: {R / 'late-mate'})\n")
out = run(sys.executable, PUBLISH, "publish", "--root", R, "--home", R / LEAD).stdout
expect(out == f"published {frag} revision 2\n", "a new local secondmate is a new revision", out)
mates.write_text(f"- {DOCS} - documentation lane (home: {R / DOCS})\n")
run(sys.executable, PUBLISH, "publish", "--root", R, "--home", R / LEAD)
expect(json.loads(frag.read_text())["revision"] == 3, "retiring it is another revision")
(R / "late-mate/state").rmdir()
(R / "late-mate").rmdir()

# Tooling-mate declares each home's heartbeat folder as the handoff-watch outbox.
run(sys.executable, PUBLISH, "publish", "--root", R, "--home", R / "tooling-mate")
tdoc = json.loads((R / "tooling-mate/state/handoff-registry/firstmate.json").read_text())
watch = [p for p in tdoc["protocols"] if p["id"] == "handoff-watch"]
expect(watch and {s["name"]: s["outbox"]["path"] for s in watch[0]["stages"]}
       == {h: str(R / h / "state/handoff-watch/heartbeat") for h in ("main", "tooling-mate", LEAD, DOCS)}
       and all(s["owner"] == s["name"] for s in watch[0]["stages"]),
       "tooling-mate's fragment gives every home a handoff-watch stage whose outbox is its heartbeat folder",
       json.dumps(watch))
expect(not [p for p in doc["protocols"] if p["id"] == "handoff-watch"], "no other home declares handoff-watch")
tick(LEAD, NOW - 2 * H)
expect(not any(k for t in ("main", LEAD) for k in active(LEAD, t)),
       "a quiet home raises nothing, and the heartbeat stages are never judged as a chain",
       json.dumps({t: list(active(LEAD, t)) for t in ("main", LEAD)}))

# The marked-request drill: an unanswered request past the ladder, then its reply.
CORR = "0123456789abcdef"
replies = state / "pending-replies"
replies.mkdir()
inbox = state / f"{DOCS}.inbox"
(inbox / "handled").mkdir(parents=True)


def record(corr, phase, created, **extra):
    fields = {"schema": "fm-pending-reply.v1", "corr_id": corr, "task_id": DOCS, "parent_home": str(R / LEAD),
              "parent_status": str(state / f"{LEAD}.status"), "expect": "answer", "created_epoch": created,
              "delivered_epoch": created + 5, "phase": phase, **extra}
    path = replies / corr
    path.write_text("".join(f"{k}={v}\n" for k, v in fields.items()))
    return at(path, NOW)


T0 = NOW - H
msg = inbox / "001.msg"
msg.write_text(f"schema=fm-task-inbox.v1\nat=2026-10-21T00:00:00Z\n--\nfrom-firstmate: which way? corr={CORR}\n")
at(msg, T0)
record(CORR, "awaiting_report", T0)
tick(LEAD, NOW)
expect(not any(active(LEAD, t) for t in ("main", LEAD, DOCS)), "a request inside the ladder raises nothing")
msg.rename(inbox / "handled/001.msg")
record(CORR, "escalated", T0, recovery_sent_epoch=T0 + 300, escalated_epoch=T0 + 900)
tick(LEAD, NOW + 60)
held = keys(LEAD, DOCS, "hw-held-")
expect(held and held[0] in active(LEAD, LEAD) and held[0] not in active(LEAD, "main"),
       "the unanswered request is a level for the receiving home and the sender, not main",
       json.dumps({t: list(active(LEAD, t)) for t in ("main", LEAD, DOCS)}))
entry = active(LEAD, DOCS)[held[0]]
expect(entry["subject"] == f"fm-corr.{LEAD}/reply.{DOCS}/{CORR}" and "REPOST REQUIRED" in entry["reason"]
       and entry["evidence"] == {"path": str(replies / CORR)},
       "the level names the request, the missed recovery and the pending-reply record", json.dumps(entry))
status = R / DOCS / "state/handoff-watch.status"
proj = subprocess.run([STORE, "tick"], env={**BASE_ENV, "FM_HOME": str(R / DOCS)}, capture_output=True, text=True)
expect(proj.returncode == 0 and f"blocked [key={held[0]}]" in status.read_text(),
       "the receiving home's alert-store tick projects it as a blocked line", proj.stderr)
tick(LEAD, T0 + 900 + 4 * H + 1)
expect(held[0] in active(LEAD, "main"), "still unanswered at 4 h it reaches main")
record(CORR, "resolved", T0, recovery_sent_epoch=T0 + 300, escalated_epoch=T0 + 900,
       resolved_epoch=T0 + 5 * H, resolved_via="status")
tick(LEAD, T0 + 5 * H + 60)
expect(not any(k.startswith(("hw-held", "hw-open")) for t in ("main", LEAD, DOCS) for k in active(LEAD, t)),
       "the handled request with its correlated reply clears every level",
       json.dumps({t: list(active(LEAD, t)) for t in ("main", LEAD, DOCS)}))

# An inbox message left unhandled through the re-ring ladder is the receiving home's to fix.
T1 = T0 + 6 * H
msg = inbox / "002.msg"
msg.write_text("schema=fm-task-inbox.v1\nat=2026-10-21T00:00:00Z\n--\nfrom-firstmate: a plain steer\n")
at(msg, T1)
(inbox / ".escalated").write_text("002.msg\n")
tick(LEAD, T1 + 60)
unacked = active(LEAD, DOCS).get(f"hw-held-fm-corr.{LEAD}-reply.{DOCS}-msg-002")
expect(unacked and "re-ring ladder" in unacked["reason"], "an unhandled inbox message past the ladder is held for "
       "the receiving home", json.dumps(active(LEAD, DOCS)))
msg.rename(inbox / "handled/002.msg")
(inbox / ".escalated").unlink()
tick(LEAD, T1 + 120)
expect(not keys(LEAD, DOCS, "hw-held-"), "moving it to handled/ clears it")

# A delivery-unknown escalation is the sender's own to fix.
OTHER = "fedcba9876543210"
record(OTHER, "escalated", T1, delivered_epoch="", escalated_epoch=T1 + 900)
tick(LEAD, T1 + 960)
unknown = keys(LEAD, LEAD, "hw-held-")
expect(unknown and not keys(LEAD, DOCS, "hw-held-") and "may never have been delivered" in
       active(LEAD, LEAD)[unknown[0]]["reason"], "a delivery-unknown escalation routes to the sender only",
       json.dumps({t: list(active(LEAD, t)) for t in (LEAD, DOCS)}))
(replies / OTHER).unlink()
(replies / CORR).unlink()

# A launched task with no first status line, until the line arrives.
T2 = T1 + 2 * H
meta = state / "crew-1.meta"
meta.write_text("kind=ship\n")
at(meta, T2)
tick(LEAD, T2 + 60)
expect(not keys(LEAD, LEAD, "hw-open-past-bound-"), "a fresh launch raises nothing")
tick(LEAD, T2 + 2 * H + 60)
late = keys(LEAD, LEAD, "hw-open-past-bound-")
expect(late == [f"hw-open-past-bound-fm-brief.{LEAD}-launch-crew-1"], "a launch with no status line past 2 h is "
       "open past its bound for the launching home", json.dumps(active(LEAD, LEAD)))
(state / "crew-1.status").write_text("working: setup done\n")
tick(LEAD, T2 + 2 * H + 120)
expect(not keys(LEAD, LEAD, "hw-open-past-bound-"), "the first status line clears it")

# A secondmate's open keyed decision stays a record until resolved.
T3 = T2 + 3 * H
docs_status = state / f"{DOCS}.status"
docs_status.write_text(f"working: started\nneeds-decision [key=scope] [at={T3}]: which scope?\n")
tick(LEAD, T3 + 60)
expect(not keys(LEAD, LEAD, "hw-"), "an open decision inside its bound raises nothing", json.dumps(active(LEAD, LEAD)))
tick(LEAD, T3 + 7 * 24 * H + 60)
expect(keys(LEAD, LEAD, "hw-open-past-bound-") == [f"hw-open-past-bound-fm-status.{LEAD}-status.{DOCS}-scope"],
       "a decision open past 7 days is open past its bound for the parent", json.dumps(active(LEAD, LEAD)))
with docs_status.open("a") as stream:
    stream.write("resolved [key=scope]: scope settled\n")
tick(LEAD, T3 + 7 * 24 * H + 120)
expect(not keys(LEAD, LEAD, "hw-"), "resolving the decision clears it", json.dumps(active(LEAD, LEAD)))

# A home whose config/merge-queue names a queue declares its watch receipts for the train's home.
QUEUE = tmp / "queue"
(QUEUE / "watches").mkdir(parents=True)
(R / DOCS / "config").mkdir()
mq_config = R / DOCS / "config/merge-queue"
docs_frag = R / DOCS / "state/handoff-registry/firstmate.json"


def mq_protocols():
    return [p for p in json.loads(docs_frag.read_text())["protocols"] if p["id"].startswith("fm-mq-watch.")]


def target(home, root=R, env=None):
    args = ["--root", root] if root else []
    return run(sys.executable, PUBLISH, "watch-target", *args, "--home", home, check=False, env=env)


proc = target(R / DOCS)
expect(proc.returncode == 1 and proc.stdout == "" and proc.stderr == "",
       "watch-target names no receipt place, silently, for a home with no queue", proc.stdout + proc.stderr)
mq_config.write_text("dir=queue\n")
proc = run(sys.executable, PUBLISH, "publish", "--root", R, "--home", R / DOCS)
expect(not mq_protocols() and "is not an absolute path" in proc.stderr, "a relative queue dir is skipped with a warning",
       proc.stderr)
proc = target(R / DOCS)
expect(proc.returncode == 1 and proc.stdout == "" and "is not an absolute path" in proc.stderr,
       "watch-target refuses a relative queue dir with the same warning", proc.stdout + proc.stderr)
mq_config.write_text(f"dir={QUEUE}\r\n")
proc = run(sys.executable, PUBLISH, "publish", "--root", R, "--home", R / DOCS)
expect(not mq_protocols() and "without control characters" in proc.stderr,
       "a queue dir ending in a carriage return is skipped with a warning", proc.stderr)
mq_config.write_bytes(b"dir=\xff\n")
proc = run(sys.executable, PUBLISH, "publish", "--root", R, "--home", R / DOCS)
expect(not mq_protocols() and "is unreadable" in proc.stderr, "a config that is not UTF-8 is skipped with a warning",
       proc.stderr)
mq_config.unlink()
real_config = tmp / "real-merge-queue"
real_config.write_text(f"dir={QUEUE}\n")
mq_config.symlink_to(real_config)
proc = run(sys.executable, PUBLISH, "publish", "--root", R, "--home", R / DOCS)
expect(not mq_protocols() and proc.stderr == "", "a symlinked config names no queue and warns nothing", proc.stderr)
mq_config.unlink()
mq_config.write_text(f"dir={QUEUE}\nhome=docs\n")
proc = run(sys.executable, PUBLISH, "publish", "--root", R, "--home", R / DOCS)
expect(not mq_protocols() and "names no train owner home" in proc.stderr,
       "a queue whose owner.json is missing is skipped with a warning", proc.stderr)
proc = target(R / DOCS)
qdir = os.path.normpath(str(QUEUE))
docs_key = proc.stdout.splitlines()[1] if proc.stdout.count("\n") == 2 else ""
expect(proc.returncode == 0 and proc.stdout.splitlines()[0] == f"{qdir}/watches"
       and re.fullmatch(rf"{DOCS}-[0-9a-f]{{16}}", docs_key) and proc.stderr == "",
       "watch-target prints the queue's watches folder and this home's key, without needing the owner",
       proc.stdout + proc.stderr)
os.mkfifo(QUEUE / "owner.json")
proc = run(sys.executable, PUBLISH, "publish", "--root", R, "--home", R / DOCS)
expect(not mq_protocols() and "names no train owner home" in proc.stderr,
       "a FIFO in place of owner.json is skipped with a warning, never read", proc.stderr)
(QUEUE / "owner.json").unlink()
for bad in ("", "{", json.dumps({"owner": {"home": "../x"}}), json.dumps({"owner": ["x"]})):
    (QUEUE / "owner.json").write_text(bad)
    proc = run(sys.executable, PUBLISH, "publish", "--root", R, "--home", R / DOCS)
    expect(not mq_protocols() and "names no train owner home" in proc.stderr,
           f"an owner.json of {bad!r} is skipped with a warning", proc.stderr)
(QUEUE / "owner.json").write_text(json.dumps({"owner": {"home": LEAD, "task": "merge-agent"}}))
proc = run(sys.executable, PUBLISH, "publish", "--root", R, "--home", R / DOCS)
expect(proc.stderr == "", "a queue with a readable owner publishes without a warning", proc.stderr)
mq_config.write_text("dir=elsewhere\n")
proc = run(sys.executable, PUBLISH, "publish", "--root", R, "--home", R / DOCS,
           env={**BASE_ENV, "FM_MERGE_QUEUE_DIR": str(QUEUE)})
expect(proc.stderr == "" and [p["stages"][0]["input"]["path"] for p in mq_protocols()]
       == [f"{os.path.normpath(str(QUEUE))}/watches"],
       "FM_MERGE_QUEUE_DIR names the queue before dir=, as the arming adapter reads it", proc.stderr)
mq_config.write_text(f"dir={QUEUE}\nhome=docs\n")
proc = run(sys.executable, PUBLISH, "publish", "--root", R, "--home", R / DOCS)
valid = run(sys.executable, root / "bin/fm-handoff-validate.py", "fragment", docs_frag, check=False)
expect(valid.returncode == 0, "the fragment with the watch receipts validates", valid.stdout + valid.stderr)
mq = mq_protocols()
expect(len(mq) == 1 and mq[0]["id"] == f"fm-mq-watch.{DOCS}" and mq[0]["senders"] == [DOCS]
       and mq[0]["record_types"] == ["lattice.merge-queue.watch.v1"], "the watch receipts are a protocol of the "
       "arming home, with their versioned record type", json.dumps(mq))
train = mq[0]["stages"]
expect(len(train) == 1 and train[0]["name"] == "train" and train[0]["owner"] == LEAD and train[0]["planned"] is True
       and train[0]["input"] == {"path": f"{qdir}/watches", "reach": {"kind": "local"},
                                  "match": f"*.{docs_key}.json", "type_field": "schema"}
       and train[0]["outbox"]["path"] == f"{qdir}/watch-receipts/{docs_key}",
       "its one planned stage is owned by the train's home, reads the queue's watches and has a per-home outbox",
       json.dumps(train))
(R / LEAD / "config").mkdir()
(R / LEAD / "config/merge-queue").write_text(f"dir={QUEUE}\n")
run(sys.executable, PUBLISH, "publish", "--root", R, "--home", R / LEAD)
lead_mq = [p for p in json.loads(frag.read_text())["protocols"] if p["id"].startswith("fm-mq-watch.")]
lead_key = target(R / LEAD).stdout.splitlines()[1]
expect(lead_mq and lead_key != docs_key
       and lead_mq[0]["stages"][0]["outbox"]["path"] == f"{qdir}/watch-receipts/{lead_key}",
       "a second home on the same queue gets its own key and outbox", json.dumps(lead_mq))
keys_of = {hid: key for hid, key in ((DOCS, docs_key), (LEAD, lead_key))}
# Both homes arm the same task and head: one receipt each, and each protocol's input selects only its own.
receipts = {}
for hid in (DOCS, LEAD):
    receipts[hid] = QUEUE / "watches" / ("a" * 40 + f".merge-queue-t1-aaaaaaaa.{keys_of[hid]}.json")
    receipts[hid].write_text(json.dumps({"schema": "lattice.merge-queue.watch.v1", "head": "a" * 40, "task": "t1",
                                         "source_id": "merge-queue-t1-aaaaaaaa", "home": str(R / hid),
                                         "armed_at": "2026-10-30T00:00:00Z", "registration": "/nonexistent"}))
    at(receipts[hid], T3)
matches = {DOCS: mq[0]["stages"][0]["input"]["match"], LEAD: lead_mq[0]["stages"][0]["input"]["match"]}
selected = {hid: sorted(p.name for p in receipts.values() if fnmatch.fnmatchcase(p.name, m))
            for hid, m in matches.items()}
expect(selected == {hid: [receipts[hid].name] for hid in (DOCS, LEAD)},
       "two homes on one queue each declare only their own receipts", json.dumps(selected))
receipt = receipts[DOCS]
for hid in (LEAD, DOCS):
    tick(hid, T3 + 8 * 24 * H)
raised = {f"{o}->{t}": list(active(o, t)) for o in (LEAD, DOCS) for t in ("main", LEAD, DOCS)}
expect(not any(k for ks in raised.values() for k in ks if "mq-watch" in k or "unregistered" in k),
       "a receipt in the planned stage's input raises nothing, even past its accepted bound", json.dumps(raised))
foreign = QUEUE / "watches" / ("b" * 40 + f".merge-queue-t1-bbbbbbbb.{docs_key}.json")
foreign.write_text(json.dumps({"schema": "lattice.merge-queue.watch.v9"}))
tick(LEAD, T3 + 8 * 24 * H + 60)
expect(any("unregistered-type" in k for k in active(LEAD, LEAD)),
       "a record of a version no protocol lists is still raised to the train's home", json.dumps(active(LEAD, LEAD)))

# Outside a drill root a home's id comes from its marker, and homes in different fleets share ids: every unmarked
# home is main, and two fleets can each have a secondmate of one name. The key still tells them apart.
fleets = tmp / "fleets"
for name in ("one/main", "two/main", "one/mate", "two/mate"):
    (fleets / name).mkdir(parents=True)
for name in ("one/mate", "two/mate"):
    (fleets / name / ".fm-secondmate-home").write_text("mate1\n")
q_env = {**BASE_ENV, "FM_MERGE_QUEUE_DIR": str(QUEUE)}
fleet_keys = {}
for name in ("one/main", "two/main", "one/mate", "two/mate"):
    proc = target(fleets / name, root=None, env=q_env)
    expect(proc.returncode == 0, f"watch-target names a key for {name}", proc.stdout + proc.stderr)
    fleet_keys[name] = proc.stdout.splitlines()[1]
expect(fleet_keys["one/main"].startswith("main-") and fleet_keys["one/mate"].startswith("mate1-")
       and len(set(fleet_keys.values())) == 4, "homes sharing an id on one queue get distinct keys",
       json.dumps(fleet_keys))
(fleets / "alias").symlink_to(fleets / "one/main")
proc = target(fleets / "alias", root=None, env=q_env)
expect(proc.stdout.splitlines()[1:] == [fleet_keys["one/main"]], "the key follows the home's physical path",
       proc.stdout + proc.stderr)
bad_marker = fleets / "bad"
(bad_marker / ".fm-secondmate-home").mkdir(parents=True)
proc = target(bad_marker, root=None, env=q_env)
expect(proc.returncode == 1 and proc.stdout == "" and "does not hold a home id" in proc.stderr,
       "a marker that cannot be read gives no key, never main", proc.stdout + proc.stderr)
(fleets / "dangling").mkdir()
(fleets / "dangling/.fm-secondmate-home").symlink_to(fleets / "no-such-marker")
proc = target(fleets / "dangling", root=None, env=q_env)
expect(proc.returncode == 1 and "does not hold a home id" in proc.stderr,
       "a dangling marker symlink gives no key, never main", proc.stdout + proc.stderr)
PY

# Native family mapping, bounded observation and real watcher/validator integration.
python3 "$ROOT/tests/handoff-native-cases.py" "$ROOT" "$TMP_ROOT"
