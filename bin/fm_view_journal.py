"""Bounded immutable lifecycle decisions for the uninstalled foreground owner.

Internal API, not an intake daemon or effect owner. All directories/fragment
must already exist. A future owner must check its declared actor BEFORE using
this journal, then separately revalidate code, capabilities and live identities
before any effect. An accepted receipt never proves an effect completed and a
replayed accepted receipt MUST NOT authorize an automatic retry.

The new journal-only flock serializes this stage's writers; no legacy writer
uses its outbox. It is not a watcher/task/custody lock or service singleton.
Future start acquires its service singleton before this journal, never reverse.
No lock is held while waiting on an external effect. The persistent anchor is
never unlinked, recovered by PID, or treated as a liveness record.
"""
import fcntl
import hashlib
import os
from pathlib import Path
import re
import stat

from fm_view_bundle import (directory, packed, read_regular, rename_new, require,
                            write_new)
from fm_view_lifecycle import (LIMIT, SCHEMA, VERSION, contract, decode, envelope,
                               envelope_receipt, request_record, validate_receipt)

MAX_RECEIPTS = 1024
MAX_JOURNAL_BYTES = 8 * 1024 * 1024
INPUT_NAME = re.compile(r"([A-Za-z0-9][A-Za-z0-9._-]{0,127})\.([1-9][0-9]{0,3})\.json\Z")


def receipt_name(value):
    # The shared validator, not this filename projection, owns the grammar.
    return value["written_at"].replace("-", "").replace(":", "") + "-" + value["receipt_id"] + ".json"


def next_attempt(previous, attempt):
    return ((previous is None and attempt == 1) or (previous is not None
            and previous["state"] == "refused" and previous.get("code") != "effect-failed"
            and attempt == previous["attempt"] + 1))


class LifecycleJournal:
    """One bounded journal transaction; use as a context manager per decision.

    admit(filename) returns {fresh, receipt}. fresh=True means ONLY that this
    invocation newly committed that decision. No return value grants process,
    socket, actor, capability or home-mode authority. Repeated input returns its
    existing decision unchanged. Accepted-without-completion is ambiguous after
    a crash; only the future effect owner may verify and complete it.
    """
    def __init__(self, home, fragment):
        self.fd = None
        self.fragment = decode(packed(fragment))
        self.home = Path(home)
        self.protocol, self.stage = contract(self.fragment, self.home)
        require(self.stage.get("planned") is not True, "planned lifecycle stage cannot write decisions")
        self.inbox = Path(self.stage["input"]["path"])
        self.outbox = Path(self.stage["outbox"]["path"])
        require(self.inbox not in self.outbox.parents and self.outbox not in self.inbox.parents,
                "lifecycle places must be disjoint")
        self.roots = [(self.home, None), (self.home / "state", 0o700),
                      (self.inbox, 0o700), (self.outbox, 0o700), (self.outbox / ".tmp", 0o700)]
        self.identities = [directory(path, mode)[1] for path, mode in self.roots]
        self.anchor = self.outbox / ".lifecycle-journal.lock"
        fd = os.open(self.anchor, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW | os.O_NONBLOCK, 0o600)
        try:
            info = os.fstat(fd)
            require(stat.S_ISREG(info.st_mode) and info.st_uid == os.getuid()
                    and info.st_nlink == 1 and stat.S_IMODE(info.st_mode) == 0o600,
                    "unsafe lifecycle journal anchor")
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            self.fd = fd
            self.anchor_identity = (info.st_dev, info.st_ino)
            self.fresh()
        except BaseException:
            self.fd = None
            os.close(fd)
            raise

    def fresh(self):
        require(self.fd is not None, "lifecycle journal transaction closed")
        require(all(directory(path, mode)[1] == identity for (path, mode), identity
                    in zip(self.roots, self.identities)), "lifecycle journal root replaced")
        info = self.anchor.lstat()
        require((info.st_dev, info.st_ino) == self.anchor_identity
                and stat.S_ISREG(info.st_mode) and info.st_uid == os.getuid()
                and info.st_nlink == 1 and stat.S_IMODE(info.st_mode) == 0o600,
                "lifecycle journal anchor replaced")

    def history(self):
        self.fresh()
        entries, total = [], 0
        # No unbounded listdir allocation before applying the entry limit.
        with os.scandir(self.outbox) as scan:
            for entry in scan:
                if entry.name in (".tmp", ".lifecycle-journal.lock"):
                    continue
                require(len(entries) < MAX_RECEIPTS, "lifecycle journal entry bound exceeded")
                entries.append(entry.name)
        histories = {}
        for name in entries:
            raw = read_regular(self.outbox / name, LIMIT, 0o600)
            total += len(raw)
            require(total <= MAX_JOURNAL_BYTES, "lifecycle journal byte bound exceeded")
            value = decode(raw)
            validate_receipt(value, self.protocol)
            require(value["protocol"] == self.protocol["id"] and value["stage"] == self.stage["name"]
                    and value["home"] == self.stage["owner"] and receipt_name(value) == name,
                    "foreign or misnamed lifecycle receipt")
            envelope({"schema": SCHEMA, "version": value["version"], "record": value["record"],
                      "attempt": value["attempt"], "home": str(self.home), "owner": value["home"]},
                     self.stage, self.home)
            key = value["record"], value["attempt"]
            histories.setdefault(key, []).append(value)
        for values in histories.values():
            values.sort(key=lambda value: value["seq"])
            previous = None
            for seq, value in enumerate(values, 1):
                fingerprint = value.get("ext", {}).get(self.stage["owner"] + ".input-sha256")
                request_digest = value.get("ext", {}).get(self.stage["owner"] + ".request-sha256")
                require(type(fingerprint) is str and re.fullmatch(r"[0-9a-f]{64}|unreadable", fingerprint)
                        and type(request_digest) is str and re.fullmatch(r"[0-9a-f]{64}", request_digest),
                        "lifecycle receipt lacks input binding")
                require(value["seq"] == seq and ((previous is None and value["state"] in ("accepted", "refused")) or
                        (previous is not None and previous["state"] == "accepted"
                         and value["state"] in ("done", "refused")
                         and previous["version"] == value["version"]
                         and previous["ext"] == value["ext"])), "invalid lifecycle decision sequence")
                previous = value
        records = {}
        for (record, attempt), values in sorted(histories.items()):
            require(next_attempt(records.get(record), attempt), "invalid lifecycle attempt history")
            records[record] = values[-1]
        self.fresh()
        return histories, len(entries), total

    def _publish(self, value, count, total):
        # Revalidate even internally constructed decisions before any write.
        validate_receipt(value, self.protocol)
        raw = packed(value)
        require(count < MAX_RECEIPTS and total + len(raw) <= MAX_JOURNAL_BYTES
                and len(raw) <= LIMIT, "lifecycle journal publication bound exceeded")
        self.fresh()
        with os.scandir(self.outbox / ".tmp") as pending:
            require(next(pending, None) is None, "incomplete lifecycle staging; owner reconciliation required")
        stage = self.outbox / ".tmp" / ("decision-" + os.urandom(16).hex())
        staged_identity = None
        try:
            staged_identity = write_new(stage, raw, 0o600)
            self.fresh()
            target = self.outbox / receipt_name(value)
            rename_new(stage, target)
            for path in (self.outbox / ".tmp", self.outbox):
                fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
                try:
                    os.fsync(fd)
                finally:
                    os.close(fd)
            self.fresh()
            published = target.lstat()
            require((published.st_dev, published.st_ino) == staged_identity
                    and read_regular(target, LIMIT, 0o600) == raw,
                    "published lifecycle receipt changed; effect refused")
        finally:
            if os.path.lexists(stage):
                # Refuse cleanup after root/anchor replacement, never touch a
                # newer tree. Only this unpublished random stage is disposable.
                self.fresh()
                info = stage.lstat()
                require(staged_identity is not None and (info.st_dev, info.st_ino) == staged_identity
                        and stat.S_ISREG(info.st_mode) and info.st_nlink == 1,
                        "journal staging replacement; cleanup refused")
                stage.unlink()
        return value

    def intake(self, filename):
        require(type(filename) is str, "invalid lifecycle input filename")
        match = INPUT_NAME.fullmatch(filename)
        require(match is not None, "invalid lifecycle input filename")
        record, attempt = match[1], int(match[2])
        base = {"schema": SCHEMA, "version": VERSION, "record": record, "attempt": attempt,
                "home": str(self.home), "owner": self.stage["owner"]}
        envelope(base, self.stage, self.home)
        raw = None
        request = base
        code = "input-invalid"
        self.fresh()
        try:
            raw = read_regular(self.inbox / filename, LIMIT, 0o600)
            selected = decode(raw)
            envelope(selected, self.stage, self.home)
            require(selected["record"] == record and selected["attempt"] == attempt,
                    "lifecycle input filename binding mismatch")
            if selected["version"] != VERSION:
                request, code = selected, "version-unsupported"
            else:
                request_record(selected, self.fragment, self.home)
                request, code = selected, None
        except (OSError, ValueError, TypeError, KeyError, RecursionError, OverflowError):
            # A malformed payload cannot select another identity/version. Even
            # unreadable objects have the selected filename's refusal identity;
            # no bytes means explicit unreadable, not an empty successful read.
            pass
        self.fresh()
        fingerprint = hashlib.sha256(raw).hexdigest() if raw is not None else "unreadable"
        return request, code, fingerprint

    def admit(self, filename):
        request, code, fingerprint = self.intake(filename)
        histories, count, total = self.history()
        key = request["record"], request["attempt"]
        previous = histories.get(key, [])
        if previous:
            last = previous[-1]
            require(last["ext"][self.stage["owner"] + ".input-sha256"] == fingerprint
                    and last["ext"][self.stage["owner"] + ".request-sha256"] == hashlib.sha256(packed(request)).hexdigest(),
                    "lifecycle input changed after decision; effect refused")
            return {"fresh": False, "receipt": last}
        # An attempt cannot skip or automatically replay an ambiguous effect.
        older = [value for (record, _), values in histories.items() if record == key[0] for value in values]
        latest = max(older, key=lambda value: (value["attempt"], value["seq"]), default=None)
        require(next_attempt(latest, key[1]), "lifecycle attempt is not the next refused attempt")
        value = envelope_receipt(request, self.fragment, self.home,
                                 "refused" if code else "accepted", 1, code)
        value.setdefault("ext", {})[self.stage["owner"] + ".input-sha256"] = fingerprint
        return {"fresh": True, "receipt": self._publish(value, count, total)}

    def complete(self, filename, *, code=None):
        require(code in (None, "identity-changed", "effect-failed"), "invalid lifecycle completion code")
        request, problem, fingerprint = self.intake(filename)
        require(problem is None, "cannot complete invalid lifecycle input")
        histories, count, total = self.history()
        previous = histories.get((request["record"], request["attempt"]), [])
        final_state = "refused" if code else "done"
        require(bool(previous) and (previous[-1]["state"] == "accepted" or
                (previous[-1]["seq"] == 2 and previous[-1]["state"] == final_state
                 and previous[-1].get("code") == code))
                and previous[-1]["ext"][self.stage["owner"] + ".input-sha256"] == fingerprint
                and previous[-1]["ext"][self.stage["owner"] + ".request-sha256"] == hashlib.sha256(packed(request)).hexdigest(),
                "lifecycle completion lacks matching accepted decision")
        if previous[-1]["seq"] == 2:
            return previous[-1]
        value = envelope_receipt(request, self.fragment, self.home, final_state, 2, code)
        value["ext"] = previous[-1]["ext"].copy()
        return self._publish(value, count, total)

    def close(self):
        if self.fd is not None:
            fd, self.fd = self.fd, None
            os.close(fd)

    def __enter__(self):
        try:
            self.fresh()
        except BaseException:
            # Python does not call __exit__ when entry itself fails.
            self.close()
            raise
        return self

    def __exit__(self, *_):
        self.close()
