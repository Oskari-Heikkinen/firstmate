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
import fnmatch
import json
import os
from pathlib import Path
import re
import stat
import subprocess

import fm_handoff_open_holds as open_holds

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


# Native readers are bounded observations, not a second writer or an executor.
# The version/state/retention contract is owned by docs/handoff-coverage.md.
NATIVE_LIMIT = 1 << 20
NATIVE_PASS_BYTES = 16 << 20
NATIVE_FILES = 4096
NATIVE_RESULT_CHARS = 4096
HANDOFF_KINDS = {
    "READY FOR LAUNCH", "READY FOR HELPER REVIEW", "READY FOR KIT REVIEW", "PASS", "FAIL",
    "REQUEST ACCEPTED", "REQUEST REFUSED", "BATCH CUT", "REQUEST ALL CUT", "REQUEST SUPERSEDED",
    "REQUEST WITHDRAWN", "BATCH ABANDONED",
}
STEP_WORDS = {None, "LAUNCH-STARTED", "RELAUNCHED", "FETCHED-VERIFIED", "MOVED-ASIDE", "UPLOAD-ONLY",
              "DRY-RUN", "READY-CHECK", "REFUSE", "FAIL", "BLOCKED", "WAIT"}
SHA_RE = re.compile(r"^[0-9a-f]{64}$")


def token(value):
    if not isinstance(value, str) or not re.fullmatch(r"\S{1,256}", value):
        raise ValueError("missing or invalid native record identity")
    return value


def digest_identity(*values):
    if not all(isinstance(v, str) and v for v in values):
        raise ValueError("missing native identity fields")
    return hashlib.sha256(json.dumps(values, ensure_ascii=True).encode()).hexdigest()


def native_time(value):
    if not isinstance(value, str) or not value.endswith("Z"):
        raise ValueError("missing native UTC decision time")
    try:
        return datetime.datetime.fromisoformat(value[:-1] + "+00:00").timestamp()
    except (ValueError, OverflowError) as exc:
        raise ValueError("invalid native UTC decision time") from exc


def native_json(path, limit=NATIVE_LIMIT):
    # Never block on a FIFO or follow a source link to an undeclared tree.
    fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK | os.O_NOFOLLOW)
    with os.fdopen(fd, "rb") as stream:
        if not stat.S_ISREG(os.fstat(stream.fileno()).st_mode):
            raise ValueError("native record is not a regular file")
        data = stream.read(limit + 1)
    if len(data) > limit:
        raise ValueError(f"native record is larger than {limit} bytes")
    doc = json.loads(data)
    if not isinstance(doc, dict):
        raise ValueError("native record is not a JSON object")
    return doc


def native_handoff(doc, path):
    kind = doc.get("kind")
    if kind not in HANDOFF_KINDS:
        raise ValueError(f"unknown tj-handoff kind {kind!r}")
    record = token(doc.get("id"))
    if kind in ("REQUEST ACCEPTED", "REQUEST REFUSED"):
        sha = (doc.get("artefact") or {}).get("sums_sha256")
        if not isinstance(sha, str) or not SHA_RE.fullmatch(sha):
            raise ValueError("request decision lacks full artefact sums_sha256")
        record = token(f"request:{token(doc.get('subject'))}:{sha}")
    state = "refused" if kind in ("REQUEST REFUSED", "FAIL") else "done"
    return record, native_time(doc.get("created_at")), state, "native-refused" if state == "refused" else None, kind


def native_collected(doc, path):
    kind = doc.get("kind")
    if kind == "request":
        sha = doc.get("request_sha256")
        if not isinstance(sha, str) or not SHA_RE.fullmatch(sha):
            raise ValueError("request collection lacks full request_sha256")
        record = token(f"request:{token(doc.get('request_id'))}:{sha}")
        outcome = doc.get("outcome")
        if doc.get("complete") is not True or outcome not in ("collected", "partly-withdrawn", "withdrawn"):
            raise ValueError("unknown or incomplete collected request outcome")
    elif kind in ("tj-package", "rolling-slice"):
        record = token(f"batch:{token(doc.get('batch_id'))}")
        if not isinstance(doc.get("verification"), dict) or doc["verification"].get("verdict") != "PASS":
            raise ValueError("unknown collected verification verdict (writer emits only PASS)")
        outcome = "verified-collection"
    else:
        raise ValueError(f"unknown collected kind {kind!r}")
    return record, native_time(doc.get("recorded_at")), "done", None, f"{kind}:{outcome}"


def native_step(doc, path):
    token(doc.get("subject"))
    token(doc.get("phase"))
    word, rc = doc.get("result_word"), doc.get("rc")
    if word not in STEP_WORDS:
        raise ValueError(f"unknown step result_word {word!r}")
    started = native_time(doc.get("started"))
    if rc is None:
        if doc.get("ended") is not None:
            raise ValueError("step ended without a recorded rc")
        return token(path.name), started, "accepted", None, "wrapper outcome unknown; child liveness not observed"
    if type(rc) is not int or rc < 0:
        raise ValueError("invalid step rc")
    ended = native_time(doc.get("ended"))
    if ended < started:
        raise ValueError("step ended before it started")
    if word == "WAIT":
        state, code = "held", "native-wait"
    elif rc != 0 or word in ("REFUSE", "FAIL", "BLOCKED"):
        state, code = "held", "native-failed"
    else:
        state, code = "done", None
    detail = f"wrapper rc={rc} result_word={word}; not downstream completion"
    if word is None and doc.get("result") is not None:
        result = doc["result"]
        if not isinstance(result, str) or len(result) > NATIVE_RESULT_CHARS:
            raise ValueError(f"null-word step result must be a string of at most {NATIVE_RESULT_CHARS} characters")
        detail += f"; result={result}"
    return token(path.name), ended, state, code, detail


def native_verified(doc, path):
    if doc.get("result") != "pass":
        raise ValueError("unknown manifest verification result (writer emits only pass)")
    if not isinstance(doc.get("manifest_sha256"), str) or not SHA_RE.fullmatch(doc["manifest_sha256"]):
        raise ValueError("missing manifest sha256")
    record = digest_identity(doc.get("item"), doc.get("manifest"))
    return record, native_time(doc.get("verified_at")), "done", None, "recorded manifest verification pass; not rehashed"


def cursor_shape(doc):
    if set(doc) != {"dev", "ino", "offset", "tail"}:
        raise ValueError("unknown capacity cursor version/shape; expected legacy dev/ino/offset/tail")
    if any(type(doc[k]) is not int or doc[k] < 0 for k in ("dev", "ino", "offset")) \
            or not isinstance(doc["tail"], str) or not SHA_RE.fullmatch(doc["tail"]):
        raise ValueError("invalid capacity cursor identity/offset/tail")


def native_cursor(doc, path):
    cursor_shape(doc)
    if not path.name.endswith(".cursor.json"):
        raise ValueError("capacity cursor filename must end in .cursor.json")
    signal = path.with_name(path.name[:-len(".cursor.json")] + ".signal")
    fd = os.open(signal, os.O_RDONLY | os.O_NONBLOCK | os.O_NOFOLLOW)
    with os.fdopen(fd, "rb") as stream:
        st = os.fstat(stream.fileno())
        if not stat.S_ISREG(st.st_mode) or (doc["dev"], doc["ino"]) != (st.st_dev, st.st_ino) \
                or doc["offset"] > st.st_size:
            raise ValueError("capacity signal identity/size no longer matches checkpoint; native replay required")
        stream.seek(max(0, doc["offset"] - 256))
        tail = stream.read(min(doc["offset"], 256))
        if hashlib.sha256(tail).hexdigest() != doc["tail"]:
            raise ValueError("capacity signal checkpoint digest mismatch; native replay required")
        if doc["offset"] and not tail.endswith(b"\n"):
            raise ValueError("capacity checkpoint is not after a complete signal line")
        state = "done" if doc["offset"] == st.st_size else "accepted"
    return digest_identity(str(path)), path.stat().st_mtime, state, None, \
        f"stdout checkpoint {doc['offset']}/{st.st_size} bytes; downstream acknowledgement not observed"


def native_records(proto, stage, cache, now, schema, mapper):
    """One top-level native family, with explicit version, bounded reads and pruning evidence."""
    folder = Path(stage["input"]["path"])
    pattern = stage["input"].get("match", "*.json")
    config = [str(folder), pattern, schema]
    if schema is None and (not pattern.endswith(".cursor.json") or any(c in pattern for c in "*?[]")):
        return [], [(folder, "capacity cursor input.match must name one exact .cursor.json file")]
    if cache.get("config") != config:
        cache.clear()
        cache.update(config=config, files={}, observed={})
    files, observed = cache["files"], cache["observed"]
    try:
        # Do not materialize an unbounded directory or silently cut its record set.
        names = []
        with os.scandir(folder) as entries:
            for entry in entries:
                if (entry.name.startswith(".") and not pattern.startswith(".")) \
                        or not fnmatch.fnmatchcase(entry.name, pattern):
                    continue
                names.append(entry.name)
                if len(names) > NATIVE_FILES:
                    raise ValueError(f"native stage exceeds {NATIVE_FILES} selected records")
        if schema is None and not names:
            raise ValueError(f"declared capacity cursor {pattern} is missing")
    except (OSError, ValueError) as exc:
        return list(observed.values()), [(folder, str(exc))]
    out, problems, present = {}, [], {str(folder / name) for name in names}
    read_bytes = 0
    for name in sorted(names):
        path = folder / name
        key = str(path)
        try:
            st = path.lstat()
            if not stat.S_ISREG(st.st_mode):
                raise ValueError("native record is not a regular file")
            sig = [st.st_mtime_ns, st.st_size, st.st_ino, st.st_ctime_ns]
            old = files.get(key)
            if old and old[0] == sig:
                if len(old) > 2:
                    raise ValueError(old[2])
                mapped = old[1]
            else:
                cost = min(st.st_size, NATIVE_LIMIT + 1)
                if read_bytes + cost > NATIVE_PASS_BYTES:
                    raise ValueError(f"native changed-record reads exceed {NATIVE_PASS_BYTES} bytes this pass; retry next tick")
                read_bytes += cost
                try:
                    doc = native_json(path)
                    if schema is not None:
                        field = "schema_version" if schema == "lattice-manifest-verified/v1" else "schema"
                        if doc.get(field) != schema:
                            raise ValueError(f"unknown native version {doc.get(field)!r}; expected {schema}")
                    # Persist only a small observation, never the whole source.
                    mapped = doc if schema is None else mapper(doc, path)
                    if schema is None:
                        cursor_shape(doc)
                except (OSError, ValueError, TypeError, AttributeError, OverflowError) as exc:
                    files[key] = [sig, None, str(exc)[:300]]
                    raise
                files[key] = [sig, mapped]
            # A cursor's signal can grow or rotate even when the cursor is unchanged.
            record, at, state, code, detail = mapper(mapped, path) if schema is None else mapped
            adapted = receipt(proto, stage, record, at, state, path, code=code, detail=detail, entry=name)
            adapted["version"] = 0 if schema is None else 1
            adapted["ext"] = {f"{stage['owner']}.native-attempts-known": False,
                              f"{stage['owner']}.native-outcome": detail}
            if code:
                # Routing and lane scope remain fragment data, never native-reader constants.
                entry = proto_code(stage, code)
                if entry and entry.get("holds_all"):
                    adapted.update(holds_all=True, stops=entry["stops"])
            previous = out.get(record)
            if previous:
                if schema == "tj-handoff/v1" and record.startswith("request:"):
                    if previous["written_at"] == adapted["written_at"] and previous["state"] != adapted["state"]:
                        raise ValueError("conflicting request decisions share a native timestamp")
                    adapted = max((previous, adapted), key=lambda r: (r["written_at"], r["evidence"]))
                else:
                    raise ValueError(f"duplicate native identity {record}")
            out[record] = adapted
        except (OSError, ValueError, TypeError, AttributeError, OverflowError) as exc:
            problems.append((path, str(exc)))
    # Do not let pruning (or parse failure) manufacture successful resolution.
    for record, old in observed.items():
        current = out.get(record)
        if schema == "tj-handoff/v1" and record.startswith("request:") and current \
                and current["written_at"] < old["written_at"]:
            # Pruning a later acceptance must not resurrect an older refusal
            # still retained in the write-once queue for the same request.
            out[record] = old
        if record in out or old["state"] == "done":
            continue
        if old["evidence"] not in present:
            problems.append((Path(old["evidence"]), "native record pruned before observed completion"))
        out[record] = old
    prune(files, present)
    if len(out) > NATIVE_FILES:
        return list(observed.values()), problems + [(folder, "native unresolved observation retention exceeds record cap")]
    cache["observed"] = out
    return list(out.values()), problems


def proto_code(stage, code):
    """Use the validator's exact/longest-family rule without importing its CLI module."""
    codes = stage.get("codes", {})
    if code in codes:
        return codes[code]
    families = [k for k in codes if k.endswith("*") and code.startswith(k[:-1])]
    return codes[max(families, key=len)] if families else None


def tj_handoff(proto, stage, cache, now):
    return native_records(proto, stage, cache, now, "tj-handoff/v1", native_handoff)


def tetjet_collected(proto, stage, cache, now):
    return native_records(proto, stage, cache, now, "tetjet-collected/v1", native_collected)


def tj_step(proto, stage, cache, now):
    return native_records(proto, stage, cache, now, "tj-step-receipt/v1", native_step)


def manifest_verified(proto, stage, cache, now):
    return native_records(proto, stage, cache, now, "lattice-manifest-verified/v1", native_verified)


def capacity_cursor(proto, stage, cache, now):
    return native_records(proto, stage, cache, now, None, native_cursor)


def open_hold_receipts(proto, stage, projection, path):
    """Render compact logical witnesses, not an immutable receipt/retry history."""
    out = []
    for record, operation in (projection or {}).get("operations", {}).items():
        hold, closed = operation["hold"], operation["closed_by"]
        detail = (f"{hold['subject']}/{hold['phase'] or 'other'}: {hold['reason']}; "
                  f"native held {hold['id']} at {hold['at']} receipt={hold['receipt']}")
        if closed:
            state, code, at = "done", None, operation["done_at"]
            detail += (f"; closed by {closed['kind']} {closed['subject']} at {closed['at']} "
                       f"receipt={closed['receipt']} reason={closed['reason']}"
                       f"{'; class-key=' + closed['via'] if closed.get('via') else ''}; "
                       "logical hold resolved, not proof of removal or whole-service completion")
        else:
            state, code, at = "held", "native-failed", hold["at"]
        preview = detail
        if len(preview) > 1000:
            prefix = "logical hold resolved, not proof of removal/service completion; " if closed else "native logical hold remains open; "
            suffix = " ... [full native-outcome in ext]"
            preview = prefix + detail[:1000 - len(prefix) - len(suffix)] + suffix
        doc = receipt(proto, stage, record, native_time(at), state, path, code=code, detail=preview, entry=path.name)
        doc["version"] = 1
        doc["ext"] = {f"{stage['owner']}.native-attempts-known": False,
                      f"{stage['owner']}.native-outcome": detail}
        entry = proto_code(stage, code) if code else None
        if entry and entry.get("holds_all"):
            doc.update(holds_all=True, stops=entry["stops"])
        out.append(doc)
    return out


def tj_open_holds(proto, stage, cache, now):
    """One bounded, complete native event snapshot; failures never resolve old holds."""
    folder, pattern = Path(stage["input"]["path"]), stage["input"].get("match", "*.json")
    config = ["native-tj-open-holds", str(folder), pattern]
    if cache.get("open-holds-config") != config:
        cache.clear()
        cache["open-holds-config"] = config
    if not isinstance(pattern, str) or not pattern.endswith(".json") or any(c in pattern for c in "*?[]/\\"):
        return [], [(folder, "logical open-holds input.match must name one exact JSON snapshot")]
    path = folder / pattern
    previous = cache.get("projection")
    old_docs = lambda: open_hold_receipts(proto, stage, previous, path)
    max_age = (stage.get("ext") or {}).get(f"{stage['owner']}.native-snapshot-max-age-seconds")
    if type(max_age) is not int or max_age <= 0:
        return old_docs(), [(path, "logical open-holds requires a positive integer native-snapshot-max-age-seconds policy")]
    try:
        st = path.lstat()
        if not stat.S_ISREG(st.st_mode):
            raise ValueError("native events snapshot is not a regular file")
        sig = [st.st_mtime_ns, st.st_size, st.st_ino, st.st_ctime_ns]
        source = cache.get("source")
        if not source or source[0] != sig:
            try:
                # A single aggregate has its own 16 MiB cap, not the 1 MiB per-invocation cap.
                projection, problems = open_holds.project(native_json(path, limit=NATIVE_PASS_BYTES), previous)
                source = [sig, projection, problems]
            except (OSError, ValueError, TypeError, AttributeError, OverflowError) as exc:
                source = [sig, None, str(exc)[:300]]
            cache["source"] = source
        if source[1] is None:
            raise ValueError(source[2])
        projection, problems = source[1:]
        at = native_time(projection["scanned_at"])
        if at > now or now - at > max_age:
            raise ValueError("native events snapshot is stale or future-dated under the declared freshness policy")
        cache["projection"] = projection
        return open_hold_receipts(proto, stage, projection, path), [(path, why) for why in problems]
    except (OSError, ValueError, TypeError, AttributeError, OverflowError) as exc:
        return old_docs(), [(path, str(exc))]


ADAPTERS = {"corr-request": corr_request, "first-status": first_status, "status-decisions": status_decisions,
            "native-tj-handoff": tj_handoff, "native-tetjet-collected": tetjet_collected,
            "native-tj-step": tj_step, "native-manifest-verified": manifest_verified,
            "native-capacity-cursor": capacity_cursor, "native-tj-open-holds": tj_open_holds}


def adapt(proto, stage, cache, now):
    """Run the stage's adapter; raises KeyError for an adapter this code does not know."""
    return ADAPTERS[adapter_name(stage)](proto, stage, cache, now)
