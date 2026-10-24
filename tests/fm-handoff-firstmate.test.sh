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
# secondmate's open keyed decision stays a record until resolved.
# Covers bin/fm-handoff-firstmate.py, bin/fm_handoff_adapters.py and their
# read path in bin/fm-handoff-watch.py.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-handoff-firstmate)
export TZ=UTC

python3 - "$ROOT" "$TMP_ROOT" <<'PY'
import json
import os
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


def run(*args, check=True):
    proc = subprocess.run([*map(str, args)], capture_output=True, text=True, timeout=60, env=BASE_ENV)
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
PY

# Native family mapping, bounded observation and real watcher/validator integration.
python3 "$ROOT/tests/handoff-native-cases.py" "$ROOT" "$TMP_ROOT"
