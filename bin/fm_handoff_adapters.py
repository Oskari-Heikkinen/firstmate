"""Receipt adapters: read Firstmate's existing handoff records as handoff-receipt/v1.

docs/handoff-coverage.md ("Receipt adapters") owns what each adapter maps and
which stages name one; bin/fm-handoff-firstmate.py publishes the stages that do.
An adapter is a reader only: the records it reads keep their one writer
(bin/fm-pending-reply-lib.sh, bin/fm-task-inbox-lib.sh, bin/fm-spawn.sh and the
status-append path) and it writes nothing. The watcher calls adapt() for a
stage whose ext names an adapter in place of reading an outbox of receipt files.

adapt() returns (receipts, problems): one receipt document per record for the
record's current state, whose evidence is the source file, and (path, why)
pairs for sources that could not be read. The adapter reads the stage's input
place itself, so a missing folder is a stage with no records yet. cache is a dict the
caller persists between passes, so an unchanged file is not read again.
"""
import datetime
import hashlib
import os
from pathlib import Path
import re
import subprocess

HERE = Path(__file__).resolve().parent
ADAPTER_KEY = "receipt-adapter"
CORR_RE = re.compile(r"corr=([0-9a-f]{16})")
RECORD_LIMIT = 65536
# Phases of bin/fm-pending-reply-lib.sh that mean the ladder is still working.
REPLY_OPEN = ("awaiting_report", "delivery_unknown", "recovery_sending", "recovery_sent",
              "recovery_failed", "recovery_unknown")
RESERVED_KEYS = ("pending-reply-", "handoff-pickup-", "handoff-tj-")
FOLD = r'''
. "$1/fm-classify-lib.sh" || exit 3
f=$2
status_open_decisions "$f" | while IFS=$'\t' read -r key verb note || [ -n "$key" ]; do
  [ -n "$key" ] || continue
  at=$(status_decision_opened_at "$f" "$key" 2>/dev/null) || at=
  printf '%s\t%s\t%s\n' "$key" "$verb" "$at"
done
'''


def adapter_name(stage):
    """The adapter a stage names in <owner>.receipt-adapter, else None."""
    return (stage.get("ext") or {}).get(f"{stage['owner']}.{ADAPTER_KEY}")


def utc(epoch):
    return datetime.datetime.fromtimestamp(epoch, datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%fZ")


def signature(path):
    st = os.stat(path)
    return [st.st_mtime_ns, st.st_size, st.st_ino]


def read_text(path):
    with open(path, "rb") as stream:
        data = stream.read(RECORD_LIMIT + 1)
    if len(data) > RECORD_LIMIT:
        raise ValueError(f"is larger than {RECORD_LIMIT} bytes")
    return data.decode("utf-8")


def fields(text):
    """key=value lines up to a "--" line, first value per key."""
    out = {}
    for line in text.splitlines():
        if line == "--":
            break
        key, sep, value = line.partition("=")
        if sep:
            out.setdefault(key, value)
    return out


def receipt(proto, stage, record, at, state, path, attempt=1, code=None, detail=None, sender=None, entry=None):
    seq = 1 if state == "accepted" else 2
    rid = hashlib.sha256(f"{proto['id']}/{stage['name']}/{record}/{attempt}/{seq}/{state}/{code}".encode()).hexdigest()[:16]
    doc = {"format": "handoff-receipt/v1", "receipt_id": rid, "written_at": utc(at), "protocol": proto["id"],
           "version": proto["versions"]["max"], "stage": stage["name"], "home": stage["owner"], "record": record,
           "attempt": attempt, "seq": seq, "state": state, "evidence": str(path)}
    if code:
        doc["code"] = code
        doc["holds_all"] = False
    for key, value in (("detail", detail), ("sender", sender), ("input", entry)):
        if value:
            doc[key] = value
    return doc


def cached(cache, path, parse):
    """parse(path) once per file signature; raises OSError or ValueError."""
    key = str(path)
    sig = signature(path)
    old = cache.get(key)
    if old and old[0] == sig:
        return old[1]
    value = parse(path)
    cache[key] = [sig, value]
    return value


def prune(cache, keep):
    for key in [k for k in cache if k not in keep]:
        del cache[key]


def listing(folder):
    return sorted(n for n in os.listdir(folder) if not n.startswith("."))


def corr_request(proto, stage, cache, now):
    """One secondmate's marked requests: its inbox messages and its pending-reply records."""
    inbox, records = Path(stage["input"]["path"]), Path(stage["outbox"]["path"])
    mate = stage["name"].split(".", 1)[1]
    sender = proto["owner"]
    out, problems, keep = {}, [], set()
    try:
        names = [n for n in listing(records) if (records / n).is_file()]
    except FileNotFoundError:
        names = []
    except OSError as exc:
        return [], [(records, f"cannot be listed ({exc.strerror})")]
    for name in names:
        path = records / name
        keep.add(str(path))
        try:
            rec = cached(cache, path, lambda p: fields(read_text(p)))
        except (OSError, ValueError, UnicodeDecodeError) as exc:
            problems.append((path, f"cannot be read ({getattr(exc, 'strerror', None) or exc})"))
            continue
        if rec.get("task_id") != mate or not rec.get("corr_id"):
            continue
        corr, phase = rec["corr_id"], rec.get("phase", "")
        at = int(rec.get("created_epoch") or 0) or int(os.stat(path).st_mtime)
        attempt = 2 if rec.get("recovery_attempted_epoch") or rec.get("recovery_sent_epoch") else 1
        if phase == "resolved":
            out[corr] = receipt(proto, stage, corr, int(rec.get("resolved_epoch") or at), "done", path, attempt,
                                sender=sender)
        elif phase == "escalated" and rec.get("delivered_epoch"):
            out[corr] = receipt(proto, stage, corr, int(rec.get("escalated_epoch") or at), "held", path, attempt,
                                "reply-missed", f"{mate} sent no correlated reply to request {corr}, "
                                "even after REPOST REQUIRED", sender)
        elif phase == "escalated":
            out[corr] = receipt(proto, stage, corr, int(rec.get("escalated_epoch") or at), "held", path, attempt,
                                "delivery-unknown", f"request {corr} to {mate} may never have been delivered", sender)
        elif phase in REPLY_OPEN:
            out[corr] = receipt(proto, stage, corr, at, "accepted", path, attempt, sender=sender)
        else:
            problems.append((path, f"has unknown phase {phase!r}"))
    try:
        msgs = [n for n in listing(inbox) if n.endswith(".msg")]
    except FileNotFoundError:
        msgs = []
    except OSError as exc:
        return [], problems + [(inbox, f"cannot be listed ({exc.strerror})")]
    try:
        stale = (inbox / ".escalated").read_text(encoding="utf-8").strip()
    except (OSError, UnicodeDecodeError):
        stale = ""
    for name in msgs:
        path = inbox / name
        keep.add(str(path))
        try:
            text = cached(cache, path, read_text)
        except (OSError, ValueError, UnicodeDecodeError) as exc:
            problems.append((path, f"cannot be read ({getattr(exc, 'strerror', None) or exc})"))
            continue
        found = CORR_RE.search(text.partition("\n--\n")[2])
        record = found.group(1) if found else f"msg-{name[:-4]}"
        if name == stale:
            at = int(os.stat(path).st_mtime)
            out[record] = receipt(proto, stage, record, at, "held", path, code="unacked",
                                  detail=f"{mate} has not moved {name} to handled/ through the whole re-ring ladder",
                                  sender=sender, entry=name)
        elif record not in out:
            out[record] = receipt(proto, stage, record, int(os.stat(path).st_mtime), "accepted", path,
                                  sender=sender, entry=name)
    prune(cache, keep)
    return list(out.values()), problems


def first_status(proto, stage, cache, now):
    """Each launched task (its state/<id>.meta) until its first status line."""
    folder = Path(stage["input"]["path"])
    try:
        names = [n for n in listing(folder) if n.endswith(".meta")]
    except OSError as exc:
        return [], [(folder, f"cannot be listed ({exc.strerror})")]
    out = []
    for name in names:
        task = name[:-5]
        meta, status = folder / name, folder / f"{task}.status"
        try:
            at = int(os.stat(meta).st_mtime)
        except OSError:
            continue
        try:
            st = os.stat(status)
        except OSError:
            st = None
        if st is not None and st.st_size > 0:
            out.append(receipt(proto, stage, task, int(st.st_mtime), "done", status, sender=proto["owner"], entry=name))
        else:
            out.append(receipt(proto, stage, task, at, "accepted", meta, sender=proto["owner"], entry=name))
    return out, []


def status_decisions(proto, stage, cache, now):
    """The keyed needs-decision and blocked lines a secondmate's status log holds open."""
    mate = stage["name"].split(".", 1)[1]
    path = Path(stage["input"]["path"]) / f"{mate}.status"
    if not path.is_file():
        prune(cache, set())
        return [], []

    def fold(p):
        run = subprocess.run(["bash", "-c", FOLD, "fold", str(HERE), str(p)], capture_output=True, text=True,
                             timeout=20)
        if run.returncode != 0:
            raise ValueError(f"could not be folded ({run.stderr.strip()[:200] or run.returncode})")
        return [line.split("\t") for line in run.stdout.splitlines() if line.count("\t") == 2]

    try:
        rows = cached(cache, path, fold)
    except (OSError, ValueError, subprocess.SubprocessError) as exc:
        return [], [(path, str(getattr(exc, "strerror", None) or exc))]
    prune(cache, {str(path)})
    mtime = int(os.stat(path).st_mtime)
    out = []
    for key, verb, at in rows:
        if key.startswith(RESERVED_KEYS):
            continue
        out.append(receipt(proto, stage, key, int(at) if at.isdigit() else mtime, "accepted", path,
                           detail=f"{mate} holds {verb} [key={key}] open", sender=mate, entry=path.name))
    return out, []


ADAPTERS = {"corr-request": corr_request, "first-status": first_status, "status-decisions": status_decisions}


def adapt(proto, stage, cache, now):
    """Run the stage's adapter; raises KeyError for an adapter this code does not know."""
    return ADAPTERS[adapter_name(stage)](proto, stage, cache, now)
