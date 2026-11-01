#!/usr/bin/env python3
"""fm-owner-notice-client.py - the producer side of fm-owner-notice/v1.

Usage:
  fm-owner-notice-client.py submit --config C --key K --kind T --payload-file F [--wait-seconds N]
  fm-owner-notice-client.py query --config C --key K --kind T (--payload-file F | --payload-sha256 P)
  fm-owner-notice-client.py pending --config C
  fm-owner-notice-client.py prune --config C (--key K | --all-recorded)
  fm-owner-notice-client.py probe --config C
  fm-owner-notice-client.py --interface [v1]
  fm-owner-notice-client.py --self-test v1

probe reports presence only from a fresh runner-written binding beat and a
visible watcher when /proc is available; it never starts automation.
--interface prints exactly fm-owner-notice-interface/v1; unsupported versions
exit 1. --self-test builds isolated fixtures using only the format module.

A producer hands an owner home one notice per key: submit writes the
deterministic envelope <outbox>/<K>.envelope.json exclusively, and the owner's
runner (or a manual fm-owner-notice.sh ingest) takes custody and writes a
receipt under <owner_home_path>/state/owner-notices/<binding_id>/receipts/<K>/.
Every answer, from submit and from query, comes from one answer function over
the caller's (key, kind, payload digest) and what it reads; docs/owner-notice.md
owns that table, the formats and the trust assumption.

C is a fm-owner-notice-client-config/v1 JSON file pinning the binding_id,
binding_sha256, recipient_home, owner_home_path, machine_id, producer_actor,
outbox and closure (each pinned client file mapped to its sha256). An unknown
config field is a usage error, so a stale field cannot linger.

pending lists every outbox envelope that has no delivered or consumed receipt
for its own digest. prune unlinks an envelope only when .receipts/<K>.json, the
verified receipt copy the client recorded, matches the envelope's digest; it
never touches owner files.

Output: one JSON line on stdout. Exit codes: 0 delivered or consumed for the
caller's digest (or a pending/prune command that succeeded); 2 usage or config
error; 3 absent (query only; never proof of never-sent); 65 refused,
key-conflict or not-recorded; 69 unavailable (names the path),
owner-tree-writable, owner-tree-writable-by-mode, or binding-retired on submit;
70 unknown or inconsistent state; 75 pending. Any other code, including 1 for
an uncaught exception, 124 or 137 from a caller's timeout, or a signal, is
unknown and never success.
"""

import argparse
import errno
import json
import os
import secrets
import stat
import sys
import time

# A read-only pinned deployment and the hermetic self-test never write pyc
# files beside their imported closure.
sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import fm_owner_notice_format as fmt  # noqa: E402

USAGE, ABSENT, REFUSED, UNAVAILABLE, UNKNOWN, PENDING = 2, 3, 65, 69, 70, 75
WAIT_CAP = 120
RECEIPTS_PER_KEY = 4096
COMMIT_WAIT = 5
PROBE_DIRS = ("state", "owner-notices", "bindings", "receipts")
INTERFACE = "fm-owner-notice-interface/v1"
PROBE_FRESH = 45
EXIT_WARNING = ""


class Answered(Exception):
    """A row of the answer function decided; .result is the stdout object."""

    # Positional-only, so a result field named code never collides.
    def __init__(self, exit_code, state, row, /, **extra):
        super().__init__(state)
        self.result = dict(extra, exit=exit_code, state=state, row=row)


def ans(exit_code, state, row, /, **extra):
    return Answered(exit_code, state, row, **extra)


class Context:
    """The pinned config, the verified binding and the derived owner paths."""

    def __init__(self, config, binding, binding_sha):
        self.config = config
        self.binding = binding
        self.binding_sha = binding_sha
        self.bid = config["binding_id"]
        self.home = config["owner_home_path"]
        self.state = os.path.join(self.home, "state")
        self.notices = os.path.join(self.state, "owner-notices")
        self.bindings = os.path.join(self.notices, "bindings")
        self.binding_path = os.path.join(self.bindings, self.bid + ".json")
        self.receipts = os.path.join(self.notices, self.bid, "receipts")
        # The owner publishes receipts through this temp directory, so a
        # receipt whose other link is there is not yet committed.
        self.owner_tmp = os.path.join(self.notices, self.bid, ".tmp")
        self.outbox = config["outbox"]
        self.tmp = os.path.join(self.outbox, ".tmp")
        self.records = os.path.join(self.outbox, ".receipts")
        self.max_bytes = binding["max_bytes"]
        self.retired = self._retired()

    def _retired(self):
        for suffix in (".retiring", ".retired"):
            p = os.path.join(self.bindings, self.bid + suffix)
            try:
                os.lstat(p)
                return True
            except FileNotFoundError:
                continue
            except OSError as exc:
                raise ans(UNAVAILABLE, "unavailable", 1, path=p, detail=exc.strerror)
        return False

    def identity(self, key):
        c = self.config
        return {"binding_id": c["binding_id"], "binding_sha256": c["binding_sha256"],
                "recipient_home": c["recipient_home"], "owner_home_path": c["owner_home_path"],
                "machine_id": c["machine_id"], "producer_actor": c["producer_actor"],
                "notice_key": key}

    def envelope(self, key, kind, payload):
        return fmt.envelope(self.bid, self.binding_sha, key, kind, payload)


# ---------------------------------------------------------------- rows 1-3

def read_config(path):
    try:
        data = fmt.read_regular_nofollow(path, fmt.CONFIG_BOUND)
    except FileNotFoundError:
        raise ans(UNAVAILABLE, "unavailable", 1, path=path, detail="config missing")
    except (OSError, fmt.NotRegular) as exc:
        raise ans(UNAVAILABLE, "unavailable", 1, path=path, detail=str(exc))
    try:
        config = json.loads(data.decode("utf-8"), object_pairs_hook=fmt._no_dupes)
    except (UnicodeDecodeError, ValueError) as exc:
        raise ans(USAGE, "usage", 0, path=path, detail="config is not JSON: %s" % exc)
    if not isinstance(config, dict):
        raise ans(USAGE, "usage", 0, path=path, detail="config is not an object")
    unknown = sorted(set(config) - set(fmt.CONFIG_FIELDS))
    missing = sorted(set(fmt.CONFIG_FIELDS) - set(config))
    if unknown or missing:
        raise ans(USAGE, "usage", 0, path=path,
                  detail="config fields: unknown %s, missing %s" % (unknown, missing))
    if config["schema"] != fmt.CONFIG_SCHEMA:
        raise ans(USAGE, "usage", 0, path=path, detail="config schema")
    for f in fmt.CONFIG_FIELDS[1:-1]:
        if not isinstance(config[f], str) or not config[f]:
            raise ans(USAGE, "usage", 0, path=path, detail="config field " + f)
    if not fmt.valid_name(config["binding_id"]) or not fmt.valid_sha(config["binding_sha256"]):
        raise ans(USAGE, "usage", 0, path=path, detail="config binding pin")
    for f in ("owner_home_path", "outbox"):
        if not config[f].startswith("/"):
            raise ans(USAGE, "usage", 0, path=path, detail=f + " must be absolute")
    closure = config["closure"]
    if not isinstance(closure, dict) or not all(
            isinstance(k, str) and k.startswith("/") and fmt.valid_sha(v) for k, v in closure.items()):
        raise ans(USAGE, "usage", 0, path=path, detail="closure must map absolute paths to sha256")
    return config


def check_closure(config):
    """Every pinned file hashes to its pin, and the pin covers this client and its module."""
    pinned = {os.path.realpath(p): v for p, v in config["closure"].items()}
    for own in (os.path.abspath(__file__), os.path.abspath(fmt.__file__)):
        if os.path.realpath(own) not in pinned:
            raise ans(UNKNOWN, "unknown", 1, code="closure-mismatch", path=own,
                      detail="closure does not pin this file")
    for path, want in sorted(config["closure"].items()):
        try:
            data = fmt.read_regular_nofollow(os.path.realpath(path), 4 << 20)
        except (OSError, fmt.NotRegular) as exc:
            raise ans(UNAVAILABLE, "unavailable", 1, path=path, detail=str(exc))
        if fmt.sha256_hex(data) != want:
            raise ans(UNKNOWN, "unknown", 1, code="closure-mismatch", path=path)


def probe_dir(path, name):
    """Row 2: the owner directory must refuse a create with EROFS."""
    s = fmt.seams()
    code = s.probe_errno.get(name) if s.active else None
    if code is None:
        probe = os.path.join(path, ".fm-owner-notice-probe-%d-%s" % (os.getpid(), secrets.token_hex(4)))
        try:
            fd = os.open(probe, os.O_CREAT | os.O_EXCL | os.O_WRONLY | os.O_CLOEXEC, 0o600)
        except OSError as exc:
            code = exc.errno
        else:
            os.close(fd)
            os.unlink(probe)
    try:
        rdonly = bool(os.statvfs(path).f_flag & os.ST_RDONLY)
    except OSError:
        rdonly = None
    if code is None:
        raise ans(UNAVAILABLE, "unavailable", 2, code="owner-tree-writable", path=path, st_rdonly=rdonly)
    if code in (errno.EACCES, errno.EPERM):
        raise ans(UNAVAILABLE, "unavailable", 2, code="owner-tree-writable-by-mode", path=path,
                  st_rdonly=rdonly)
    if code != errno.EROFS:
        raise ans(UNKNOWN, "unknown", 2, path=path, detail="probe errno %s" % errno.errorcode.get(code, code))
    return {"path": path, "errno": "EROFS", "st_rdonly": rdonly}


def open_context(config_path):
    config = read_config(config_path)
    fmt.seams().check(config_path, config["owner_home_path"], config["outbox"])
    check_closure(config)
    home = config["owner_home_path"]
    state = os.path.join(home, "state")
    bpath = os.path.join(state, "owner-notices", "bindings", config["binding_id"] + ".json")
    if not os.path.isdir(state):
        raise ans(UNAVAILABLE, "unavailable", 1, path=state)
    try:
        bdata = fmt.read_regular_nofollow(bpath, fmt.BINDING_BOUND)
    except (OSError, fmt.NotRegular) as exc:
        raise ans(UNAVAILABLE, "unavailable", 1, path=bpath, detail=str(exc))
    notices = os.path.join(state, "owner-notices")
    dirs = [(state, "state"), (notices, "owner-notices"), (os.path.dirname(bpath), "bindings")]
    receipts = os.path.join(notices, config["binding_id"], "receipts")
    # A missing receipts/ is rows 4 and 5's to answer, so it is probed only
    # when it exists.
    if os.path.isdir(receipts):
        dirs.append((receipts, "receipts"))
    probes = [probe_dir(path, name) for path, name in dirs]
    sha = fmt.sha256_hex(bdata)
    if sha != config["binding_sha256"]:
        raise ans(UNKNOWN, "unknown", 3, code="binding-mismatch", path=bpath, detail="binding digest")
    try:
        binding = fmt.validate_binding(fmt.parse_canonical(bdata))
    except fmt.FormatError as exc:
        raise ans(UNKNOWN, "unknown", 3, code="binding-mismatch", path=bpath, detail=str(exc))
    for f in ("binding_id", "recipient_home", "owner_home_path", "machine_id", "producer_actor", "outbox"):
        if binding[f] != config[f]:
            raise ans(UNKNOWN, "unknown", 3, code="binding-mismatch", path=bpath, detail="binding " + f)
    ctx = Context(config, binding, sha)
    ctx.probes = probes
    return ctx


# ---------------------------------------------------------------- rows 4-12

# Digest-scoped refusals of an envelope the client cannot rebuild: the owner
# hashed the bytes it rejected, which are not this binding's v1 envelope.
UNREBUILDABLE = ("binding-mismatch", "version-unsupported")


def read_receipts(ctx, key, payloads):
    """(validated committed receipts for key by seq, whether one is uncommitted); Answered for rows 4-6.

    payloads maps (payload_sha256, kind) to payload bytes the caller holds, so
    a receipt's envelope_sha256 is recomputed wherever the bytes are known.
    A receipt still linked from the owner's temp directory is a publication
    not yet committed (fmt.create_exclusive), so it is left out and reported.
    """
    if not os.path.isdir(ctx.receipts):
        if ctx.retired:
            raise ans(UNKNOWN, "unknown", 4, code="binding-retired", path=ctx.receipts)
        raise ans(UNAVAILABLE, "unavailable", 5, path=ctx.receipts)
    if not ctx.retired and not os.path.isdir(ctx.outbox):
        raise ans(UNAVAILABLE, "unavailable", 5, path=ctx.outbox)
    kdir = os.path.join(ctx.receipts, key)
    try:
        st = os.lstat(kdir)
    except FileNotFoundError:
        return [], False
    except OSError as exc:
        raise ans(UNKNOWN, "unknown", 6, path=kdir, detail=exc.strerror)
    if not stat.S_ISDIR(st.st_mode):
        raise ans(UNKNOWN, "unknown", 6, path=kdir, detail="not a directory")
    try:
        names = fmt.scandir_names(kdir, "client")
    except OSError as exc:
        raise ans(UNKNOWN, "unknown", 6, path=kdir, detail=exc.strerror)
    if len(names) > RECEIPTS_PER_KEY:
        raise ans(UNKNOWN, "unknown", 6, path=kdir, detail="too many receipts")
    want = ctx.identity(key)
    out = []
    uncommitted = False
    for name in names:
        path = os.path.join(kdir, name)
        seq = fmt.seq_of_name(name)
        if seq is None:
            raise ans(UNKNOWN, "unknown", 6, path=path, detail="file name is not a seq")
        try:
            data = fmt.read_regular_nofollow(path, fmt.RECORD_BOUND, "client", tmpdir=ctx.owner_tmp)
            obj = fmt.parse_canonical(data)
            shape = fmt.validate_receipt(obj, seq)
        except FileNotFoundError:
            continue
        except fmt.InProgress:
            uncommitted = True
            continue
        except (OSError, fmt.NotRegular, fmt.FormatError) as exc:
            raise ans(UNKNOWN, "unknown", 6, path=path, detail=str(exc))
        for f, v in want.items():
            if obj[f] != v:
                raise ans(UNKNOWN, "unknown", 6, path=path, detail="receipt names another " + f)
        digest = fmt.receipt_digest(obj)
        if digest in payloads and not (shape == "refused-digest" and obj["code"] in UNREBUILDABLE):
            env = ctx.envelope(key, digest[1], payloads[digest])
            if fmt.sha256_hex(env) != obj["envelope_sha256"]:
                raise ans(UNKNOWN, "unknown", 6, path=path, detail="envelope_sha256 is not the envelope's")
        out.append((obj, shape, data, path))
    delivered = {o["seq"]: o for o, s, _, _ in out if s == "delivered"}
    for obj, shape, _, path in out:
        if shape == "consumed":
            d = delivered.get(obj["delivered_seq"])
            if d is None or fmt.receipt_digest(d) != fmt.receipt_digest(obj) \
                    or d["envelope_sha256"] != obj["envelope_sha256"]:
                raise ans(UNKNOWN, "unknown", 6, path=path, detail="consumed names no matching delivered")
    return out, uncommitted


def verified(ctx, key, obj, data, path, payloads):
    """Raise 70 envelope-unverifiable unless obj's envelope_sha256 was checked.

    It was when the caller holds the payload (read_receipts recomputed it), or
    when the producer's own record holds these exact bytes, which record()
    writes only after that check.
    """
    if fmt.receipt_digest(obj) in payloads:
        return
    try:
        have = fmt.read_regular_nofollow(record_path(ctx, key), fmt.RECORD_BOUND, "client")
    except FileNotFoundError:
        have = None
    except (OSError, fmt.NotRegular) as exc:
        raise ans(UNKNOWN, "unknown", 6, key=key, path=record_path(ctx, key), detail=str(exc))
    if have != data:
        raise ans(UNKNOWN, "unknown", 6, key=key, code="envelope-unverifiable", path=path,
                  detail="no payload bytes or recorded receipt bind envelope_sha256")


def answer_receipts(ctx, key, kind, psha, payloads):
    """Rows 4-12, and row 13 while a receipt is uncommitted; None when no receipt answers."""
    receipts, uncommitted = read_receipts(ctx, key, payloads)
    mine = (psha, kind)
    for obj, shape, data, path in receipts:
        if shape == "delivered" and fmt.receipt_digest(obj) == mine:
            verified(ctx, key, obj, data, path, payloads)
            consumed = [o for o, s, _, _ in receipts if s == "consumed" and o["delivered_seq"] == obj["seq"]]
            state, row = ("consumed", 7) if consumed else ("delivered", 8)
            return ans(0, state, row, key=key, seq=obj["seq"], payload_sha256=psha,
                       envelope_sha256=obj["envelope_sha256"]), (data, path)
    for obj, shape, data, path in receipts:
        if shape == "refused-key":
            return ans(REFUSED, "refused", 9, key=key, code=obj["code"], seq=obj["seq"]), (data, path)
    for obj, shape, data, path in receipts:
        if shape == "delivered":
            return ans(REFUSED, "key-conflict", 10, key=key, code="key-conflict",
                       digests=[psha, obj["payload_sha256"]], kinds=[kind, obj["kind"]]), (data, path)
    for obj, shape, data, path in receipts:
        if shape == "refused-digest" and fmt.receipt_digest(obj) == mine:
            if obj["code"] not in UNREBUILDABLE:
                verified(ctx, key, obj, data, path, payloads)
            return ans(REFUSED, "refused", 11, key=key, code=obj["code"], seq=obj["seq"]), (data, path)
    for obj, shape, data, path in receipts:
        if shape == "refused-digest":
            return ans(REFUSED, "key-conflict", 12, key=key, code="key-conflict",
                       digests=[psha, obj["payload_sha256"]]), None
    if uncommitted:
        return ans(PENDING, "pending", 13, key=key, payload_sha256=psha, detail="owner receipt not yet committed"), None
    return None


# ---------------------------------------------------------------- rows 13-18

def envelope_path(ctx, key):
    return os.path.join(ctx.outbox, key + fmt.ENVELOPE_SUFFIX)


def read_envelope_bytes(ctx, path):
    """The outbox envelope's bytes, once committed; InProgress if a live submit holds it past the wait.

    A dead submit's linked temp is finished (fmt.reap_dead_temps), and a live
    one's commit is waited for up to COMMIT_WAIT seconds, since it is one
    directory fsync away.
    """
    deadline = time.monotonic() + COMMIT_WAIT
    while True:
        try:
            return fmt.read_regular_nofollow(path, fmt.envelope_cap(ctx.max_bytes), "client", tmpdir=ctx.tmp)
        except fmt.InProgress:
            if time.monotonic() >= deadline:
                raise
            fmt.seams().fault("query:commit-wait")
            fmt.reap_dead_temps(ctx.tmp, files_only=True, sync_ident="c-finish-sync")
            time.sleep(0.05)


def answer_envelope(ctx, key, kind, psha):
    """Rows 13-15 on the outbox envelope; None when there is none."""
    path = envelope_path(ctx, key)
    try:
        data = read_envelope_bytes(ctx, path)
    except FileNotFoundError:
        return None
    except fmt.InProgress:
        return ans(PENDING, "pending", 13, key=key, payload_sha256=psha, detail="envelope not yet committed")
    except (OSError, fmt.NotRegular) as exc:
        raise ans(UNKNOWN, "unknown", 15, key=key, path=path, detail=str(exc))
    try:
        env = fmt.parse_canonical(data)
        theirs = (env["payload_sha256"], env["kind"])
    except (fmt.FormatError, KeyError, TypeError) as exc:
        raise ans(UNKNOWN, "unknown", 15, key=key, path=path, detail="envelope: %s" % exc)
    if theirs == (psha, kind):
        return ans(PENDING, "pending", 13, key=key, payload_sha256=psha)
    return ans(REFUSED, "key-conflict", 14, key=key, code="key-conflict", digests=[psha, theirs[0]],
               kinds=[kind, theirs[1]])


def record_path(ctx, key):
    return os.path.join(ctx.records, key + ".json")


def answer_record_missing(ctx, key):
    """Row 17: the producer recorded an owner receipt that is no longer there."""
    p = record_path(ctx, key)
    if os.path.lexists(p):
        return ans(UNKNOWN, "unknown", 17, key=key, code="owner-record-missing", path=p)
    return None


def record(ctx, key, source):
    """Submit step 6: keep the verified receipt bytes, exclusively; compare on exist."""
    if source is None:
        return None
    data, _ = source
    p = record_path(ctx, key)
    for d, ident in ((ctx.tmp, "c-mkdir-parent"), (ctx.records, "c-mkdir-parent")):
        fmt.mkdir_durable(d, 0o755, ident, root=ctx.outbox)
    try:
        fmt.create_exclusive(p, data, ctx.tmp, "c-record-dirsync", "c-temp-fsync")
        fmt.seams().fault("submit:after-record")
        return None
    except FileExistsError:
        pass
    try:
        have = fmt.read_regular_nofollow(p, fmt.RECORD_BOUND, "client")
    except (OSError, fmt.NotRegular) as exc:
        return ans(UNKNOWN, "unknown", 6, key=key, path=p, detail=str(exc))
    if have != data:
        return ans(UNKNOWN, "unknown", 6, key=key, path=p, detail="recorded receipt differs")
    return None


def full_answer(ctx, key, kind, psha, payloads):
    """The whole table, rows 4-18 (rows 1-3 ran in open_context)."""
    got = answer_receipts(ctx, key, kind, psha, payloads)
    if got is not None:
        result, source = got
        if result.result["row"] <= 11:
            bad = record(ctx, key, source)
            if bad is not None:
                return bad
        return result
    env = answer_envelope(ctx, key, kind, psha)
    if env is not None:
        return env
    if ctx.retired:
        return ans(UNKNOWN, "unknown", 16, key=key, code="binding-retired")
    missing = answer_record_missing(ctx, key)
    if missing is not None:
        return missing
    return ans(ABSENT, "absent", 18, key=key)


# ---------------------------------------------------------------- commands

def read_payload(path, cap):
    try:
        data = fmt.read_regular_nofollow(path, cap, "client")
    except fmt.Oversize:
        raise ans(USAGE, "usage", 0, path=path, detail="payload over max_bytes %d" % cap)
    except (OSError, fmt.NotRegular) as exc:
        raise ans(USAGE, "usage", 0, path=path, detail="payload: %s" % exc)
    return data


def check_key_kind(key, kind):
    if not fmt.valid_name(key):
        raise ans(USAGE, "usage", 0, detail="key must match " + fmt.NAME_RE.pattern)
    if kind is not None and not fmt.valid_name(kind):
        raise ans(USAGE, "usage", 0, detail="kind must match " + fmt.NAME_RE.pattern)


def cmd_submit(args):
    result = submit(args)
    result.result.setdefault("created", False)
    return result


def submit(args):
    check_key_kind(args.key, args.kind)
    if not 0 <= args.wait_seconds <= WAIT_CAP:
        raise ans(USAGE, "usage", 0, detail="--wait-seconds is 0 to %d" % WAIT_CAP)
    fmt.seams().check(args.payload_file)
    ctx = open_context(args.config)
    payload = read_payload(args.payload_file, ctx.max_bytes)
    psha = fmt.sha256_hex(payload)
    payloads = {(psha, args.kind): payload}
    fmt.reap_dead_temps(ctx.tmp, sync_ident="c-finish-sync")
    got = answer_receipts(ctx, args.key, args.kind, psha, payloads)
    if got is not None:
        result, source = got
        if result.result["row"] <= 11:
            bad = record(ctx, args.key, source)
            if bad is not None:
                return bad
        return result
    missing = answer_record_missing(ctx, args.key)
    if missing is not None:
        return missing
    if ctx.retired:
        return ans(UNAVAILABLE, "unavailable", 16, key=args.key, code="binding-retired")
    fmt.seams().fault("submit:after-check")
    env = ctx.envelope(args.key, args.kind, payload)
    fmt.mkdir_durable(ctx.tmp, 0o755, "c-mkdir-parent", root=ctx.outbox)
    try:
        fmt.create_exclusive(envelope_path(ctx, args.key), env, ctx.tmp, "c-envelope-dirsync",
                             "c-temp-fsync", before_link=lambda: fmt.seams().fault("submit:before-link"))
        created = True
        fmt.seams().fault("submit:after-create")
    except FileExistsError:
        created = False
    result = None
    if not created:
        result = answer_envelope(ctx, args.key, args.kind, psha)
        if result is None:
            result = ans(UNKNOWN, "unknown", 15, key=args.key, detail="envelope vanished after EEXIST")
    else:
        result = ans(PENDING, "pending", 13, key=args.key, payload_sha256=psha)
    deadline = time.monotonic() + args.wait_seconds
    while result.result["exit"] == PENDING and time.monotonic() < deadline:
        time.sleep(1)
        result = full_answer(ctx, args.key, args.kind, psha, payloads)
    result.result["created"] = created
    result.result["envelope_sha256"] = result.result.get("envelope_sha256") or fmt.sha256_hex(env)
    return result


def cmd_query(args):
    check_key_kind(args.key, args.kind)
    if (args.payload_file is None) == (args.payload_sha256 is None):
        raise ans(USAGE, "usage", 0, detail="give exactly one of --payload-file and --payload-sha256")
    if args.payload_file is not None:
        fmt.seams().check(args.payload_file)
    ctx = open_context(args.config)
    payloads = {}
    if args.payload_file is not None:
        payload = read_payload(args.payload_file, ctx.max_bytes)
        psha = fmt.sha256_hex(payload)
        payloads[(psha, args.kind)] = payload
    else:
        if not fmt.valid_sha(args.payload_sha256):
            raise ans(USAGE, "usage", 0, detail="--payload-sha256 must be 64 lowercase hex digits")
        psha = args.payload_sha256
    fmt.reap_dead_temps(ctx.tmp, sync_ident="c-finish-sync")
    if not payloads:
        # A digest-only query binds envelope_sha256 through the producer's own
        # outbox envelope when it still holds that digest (verified() covers
        # the recorded case).
        try:
            env, _, payload = read_own_envelope(ctx, args.key)
        except Answered:
            env = None
        if env is not None and (env["payload_sha256"], env["kind"]) == (psha, args.kind) \
                and fmt.sha256_hex(payload) == psha:
            payloads[(psha, args.kind)] = payload
    return full_answer(ctx, args.key, args.kind, psha, payloads)


def outbox_envelopes(ctx):
    try:
        names = fmt.scandir_names(ctx.outbox, "client")
    except OSError as exc:
        raise ans(UNAVAILABLE, "unavailable", 5, path=ctx.outbox, detail=exc.strerror)
    keys = []
    for name in names:
        if name.startswith(".") or not name.endswith(fmt.ENVELOPE_SUFFIX):
            continue
        key = name[:-len(fmt.ENVELOPE_SUFFIX)]
        if fmt.valid_name(key):
            keys.append(key)
    return keys


def read_own_envelope(ctx, key):
    """(env object, bytes) of the outbox envelope for key, or raise Answered 70, or 75 while uncommitted."""
    path = envelope_path(ctx, key)
    try:
        data = read_envelope_bytes(ctx, path)
        env = fmt.parse_canonical(data)
        payload = fmt.decode_b64(env["payload_b64"])
        return env, data, payload
    except FileNotFoundError:
        return None, None, None
    except fmt.InProgress:
        # Still in flight: never absent, so prune keeps it and pending lists it.
        raise ans(PENDING, "pending", 13, key=key, path=path, detail="envelope not yet committed")
    except (OSError, fmt.NotRegular, fmt.FormatError, KeyError, TypeError) as exc:
        raise ans(UNKNOWN, "unknown", 15, key=key, path=path, detail=str(exc))


def cmd_pending(args):
    ctx = open_context(args.config)
    rows = []
    for key in outbox_envelopes(ctx):
        try:
            env, _, payload = read_own_envelope(ctx, key)
            if env is None:
                continue
            digest = (env["payload_sha256"], env["kind"])
            got = full_answer(ctx, key, env["kind"], env["payload_sha256"], {digest: payload})
        except Answered as a:
            got = a
        if got.result["state"] not in ("delivered", "consumed"):
            rows.append(got.result)
    return ans(0, "listed", 0, pending=rows)


def verify_record(ctx, key, env, payload):
    """Whether .receipts/K.json is a valid receipt that finalizes this envelope's digest."""
    p = record_path(ctx, key)
    try:
        obj = fmt.parse_canonical(fmt.read_regular_nofollow(p, fmt.RECORD_BOUND, "client"))
        shape = fmt.validate_receipt(obj)
    except FileNotFoundError:
        return False
    except (OSError, fmt.NotRegular, fmt.FormatError):
        return False
    if any(obj[f] != v for f, v in ctx.identity(key).items()):
        return False
    if shape == "refused-key":
        return True
    if fmt.receipt_digest(obj) != (env["payload_sha256"], env["kind"]):
        return False
    return obj["envelope_sha256"] == fmt.sha256_hex(ctx.envelope(key, env["kind"], payload))


def prune_one(ctx, key):
    env, _, payload = read_own_envelope(ctx, key)
    if env is None:
        return ans(0, "pruned", 0, key=key, detail="no envelope")
    if not verify_record(ctx, key, env, payload):
        return ans(REFUSED, "refused", 0, key=key, code="not-recorded", path=record_path(ctx, key))
    path = envelope_path(ctx, key)
    fmt.unlink_durable(path, "c-envelope-dirsync")
    fmt.seams().fault("prune:after-unlink")
    return ans(0, "pruned", 0, key=key)


def cmd_prune(args):
    if (args.key is None) == (not args.all_recorded):
        raise ans(USAGE, "usage", 0, detail="give exactly one of --key and --all-recorded")
    if args.key is not None:
        check_key_kind(args.key, None)
    ctx = open_context(args.config)
    fmt.reap_dead_temps(ctx.tmp, sync_ident="c-finish-sync")
    if args.key is not None:
        return prune_one(ctx, args.key)
    pruned, kept = [], []
    for key in outbox_envelopes(ctx):
        try:
            got = prune_one(ctx, key)
        except Answered as a:
            got = a
        (pruned if got.result["exit"] == 0 else kept).append(key)
    return ans(0, "pruned", 0, pruned=pruned, kept=kept)


def cmd_probe(args):
    """Presence is observation, never a receipt or permission to execute."""
    ctx = open_context(args.config)
    for path in (ctx.receipts, ctx.outbox):
        if ctx.retired and path == ctx.outbox:
            continue
        try:
            fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_NONBLOCK)
            try:
                if not os.fstat(fd).st_mode & 0o444:
                    raise PermissionError(errno.EACCES, "directory unreadable", path)
            finally:
                os.close(fd)
        except OSError as exc:
            if ctx.retired and path == ctx.receipts and isinstance(exc, FileNotFoundError):
                raise ans(UNKNOWN, "unknown", 4, code="binding-retired", path=path)
            raise ans(UNAVAILABLE, "unavailable", 5, path=path, detail=str(exc))
    path = os.path.join(ctx.notices, ctx.bid, ".beat")
    try:
        beat = fmt.parse_binding_beat(fmt.read_regular_nofollow(path, 4096, "client"))
    except (OSError, fmt.FormatError) as exc:
        raise ans(UNAVAILABLE, "unavailable", 0, code="owner-automation-absent", path=path,
                  detail=str(exc))
    reason = None
    if ctx.retired:
        reason = "binding retired or retiring"
    elif beat["writer"] != "runner":
        reason = "beat writer is not runner"
    elif not 0 <= fmt.seams().time() - beat["epoch"] <= PROBE_FRESH:
        reason = "beat is stale or in the future"
    elif os.path.isdir("/proc/self") and not os.path.isdir("/proc/%d" % beat["watcher_pid"]):
        reason = "watcher is not visible in /proc"
    if reason:
        return ans(UNAVAILABLE, "unavailable", 0, code="owner-automation-absent", path=path, detail=reason)
    return ans(0, "present", 0, interface=INTERFACE, binding_id=ctx.bid,
               binding_sha256=ctx.binding_sha, probes=ctx.probes, closure=ctx.config["closure"])


def self_test():
    """Exercise v1 without loading an owner engine, front or test helper."""
    import contextlib
    import io
    import tempfile

    failures = []
    saved_env = {key: os.environ.get(key) for key in fmt.Seams.VARS + ("FM_OWNER_NOTICE_TEST_ROOT",)}
    saved_seams = fmt.SEAMS
    try:
        with tempfile.TemporaryDirectory(prefix="fm-owner-notice-selftest-") as root:
            root = os.path.realpath(root)
            with open(os.path.join(root, fmt.TEST_ROOT_MARKER), "wb"):
                pass
            for key in saved_env:
                os.environ.pop(key, None)
            os.environ["FM_OWNER_NOTICE_TEST_ROOT"] = root
            os.environ["FM_OWNER_NOTICE_NOW"] = "2000000000"
            os.environ["FM_OWNER_NOTICE_FAULT"] = ",".join(
                "probe-errno:%s:EROFS" % name for name in PROBE_DIRS)
            fmt.SEAMS = None
            home, outbox = os.path.join(root, "owner"), os.path.join(root, "outbox")
            notices = os.path.join(home, "state", "owner-notices")
            bindings = os.path.join(notices, "bindings")
            leaf = os.path.join(notices, "fixture")
            receipts = os.path.join(leaf, "receipts")
            for path in (bindings, receipts, os.path.join(leaf, ".tmp"), outbox):
                os.makedirs(path, mode=0o755)
            st = os.stat(outbox)
            binding = {"schema": fmt.BINDING_SCHEMA, "binding_id": "fixture",
                       "recipient_home": "secondmate:fixture", "owner_home_path": home,
                       "machine_id": "fixture-machine", "producer_actor": "process:fixture",
                       "producer_uid": os.getuid(), "outbox": outbox, "outbox_dev": st.st_dev,
                       "outbox_ino": st.st_ino, "kinds": ["notice"], "max_bytes": 65536,
                       "consume_bound_seconds": 60, "envelope_versions": [1],
                       "receipt_versions": [1], "created_at": fmt.utc_iso(2000000000)}

            def put(path, data):
                with open(path, "wb") as fh:
                    fh.write(data)

            raw = fmt.canonical(fmt.validate_binding(binding))
            bsha = fmt.sha256_hex(raw)
            put(os.path.join(bindings, "fixture.json"), raw)
            config = {"schema": fmt.CONFIG_SCHEMA, "binding_sha256": bsha,
                      "closure": {os.path.abspath(p): fmt.sha256_hex(
                          fmt.read_regular_nofollow(os.path.abspath(p), 4 << 20))
                          for p in (__file__, fmt.__file__)}}
            for key in ("binding_id", "recipient_home", "owner_home_path", "machine_id", "producer_actor", "outbox"):
                config[key] = binding[key]
            cp = os.path.join(root, "config.json")
            put(cp, fmt.canonical(config))
            payload, pf = b"notice bytes\x00\xff", os.path.join(root, "payload")
            put(pf, payload)

            def call(label, code, state, *argv):
                output = io.StringIO()
                try:
                    with contextlib.redirect_stdout(output):
                        rc = main(list(argv))
                    got = json.loads(output.getvalue())
                    if rc != code or got["state"] != state:
                        failures.append("%s: expected %s/%s, got %s" % (label, code, state, got))
                    return got
                except Exception as exc:
                    failures.append("%s: %s" % (label, exc))
                    return {}

            def query(key, code, state):
                return call("query " + key, code, state, "query", "--config", cp, "--key", key,
                            "--kind", "notice", "--payload-file", pf)

            def receipt(key, outcome, seq=1, **extra):
                env = fmt.envelope("fixture", bsha, key, "notice", payload)
                obj = dict(fmt.receipt_identity(binding, bsha, key), schema=fmt.RECEIPT_SCHEMA,
                           seq=seq, outcome=outcome, recorded_at=fmt.utc_iso(2000000000), note=fmt.NOTE)
                if outcome != "refused" or extra.get("scope") == "digest":
                    obj.update(kind="notice", payload_sha256=fmt.sha256_hex(payload),
                               envelope_sha256=fmt.sha256_hex(env))
                if outcome == "delivered":
                    obj["envelope_bytes"] = len(env)
                obj.update(extra)
                fmt.validate_receipt(obj)
                os.makedirs(os.path.join(receipts, key), exist_ok=True)
                put(os.path.join(receipts, key, str(seq) + ".json"), fmt.canonical(obj))

            query("normal", ABSENT, "absent")
            for created in (True, False):
                got = call("submit", PENDING, "pending", "submit", "--config", cp, "--key", "normal",
                           "--kind", "notice", "--payload-file", pf)
                if got.get("created") is not created:
                    failures.append("submit created does not match exclusive publication")
            query("normal", PENDING, "pending")
            receipt("normal", "delivered")
            query("normal", 0, "delivered")
            receipt("normal", "consumed", 2, delivered_seq=1)
            query("normal", 0, "consumed")
            call("prune", 0, "pruned", "prune", "--config", cp, "--key", "normal")
            query("normal", 0, "consumed")
            receipt("key-refusal", "refused", scope="key", code="malformed")
            query("key-refusal", REFUSED, "refused")
            receipt("digest-refusal", "refused", scope="digest", code="kind-not-allowed")
            query("digest-refusal", REFUSED, "refused")
            call("missing beat", UNAVAILABLE, "unavailable", "probe", "--config", cp)
            beat = ("writer=runner epoch=2000000000 runner_pid=%d runner_starttime=%s "
                    "watcher_pid=%d watcher_identity=fixture outbox_mtime_ns=0 dirty_since=-\n"
                    % (os.getpid(), fmt.pid_starttime(os.getpid()), os.getpid())).encode("ascii")
            put(os.path.join(leaf, ".beat"), beat)
            call("presence", 0, "present", "probe", "--config", cp)
            put(os.path.join(leaf, ".beat"), beat.replace(b"epoch=2000000000", b"epoch=1999999954"))
            call("stale beat", UNAVAILABLE, "unavailable", "probe", "--config", cp)
            put(os.path.join(leaf, ".beat"), beat)
            for path in (receipts, outbox):
                os.rename(path, path + ".parked")
                call("missing " + path, UNAVAILABLE, "unavailable", "probe", "--config", cp)
                os.rename(path + ".parked", path)
            put(os.path.join(bindings, "fixture.retired"), b"retired\n")
            call("retired", UNAVAILABLE, "unavailable", "probe", "--config", cp)
            os.rename(receipts, receipts + ".parked")
            got = call("purged", UNKNOWN, "unknown", "probe", "--config", cp)
            if got.get("code") != "binding-retired" or got.get("row") != 4:
                failures.append("purged binding must preserve row 4")
    finally:
        fmt.SEAMS = saved_seams
        for key, value in saved_env.items():
            if value is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = value
    for failure in failures:
        print("FAIL " + failure)
    if failures:
        return 1
    print("PASS " + INTERFACE + " self-test (isolated format-module fixtures)")
    return 0


class Parser(argparse.ArgumentParser):
    def error(self, message):
        raise ans(USAGE, "usage", 0, detail=message)


def build_parser():
    p = Parser(prog="fm-owner-notice-client.py", add_help=True,
               description=__doc__, epilog=EXIT_WARNING,
               formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--interface", nargs="?", const="v1", metavar="VERSION")
    p.add_argument("--self-test", metavar="VERSION")
    sub = p.add_subparsers(dest="cmd", parser_class=Parser)
    s = sub.add_parser("submit")
    s.add_argument("--config", required=True)
    s.add_argument("--key", required=True)
    s.add_argument("--kind", required=True)
    s.add_argument("--payload-file", required=True)
    s.add_argument("--wait-seconds", type=int, default=0)
    q = sub.add_parser("query")
    q.add_argument("--config", required=True)
    q.add_argument("--key", required=True)
    q.add_argument("--kind", required=True)
    q.add_argument("--payload-file")
    q.add_argument("--payload-sha256")
    probe = sub.add_parser("probe")
    probe.add_argument("--config", required=True)
    pe = sub.add_parser("pending")
    pe.add_argument("--config", required=True)
    pr = sub.add_parser("prune")
    pr.add_argument("--config", required=True)
    pr.add_argument("--key")
    pr.add_argument("--all-recorded", action="store_true")
    return p


COMMANDS = {"submit": cmd_submit, "query": cmd_query, "pending": cmd_pending, "prune": cmd_prune,
            "probe": cmd_probe}


def main(argv):
    try:
        fmt.seams()
        args = build_parser().parse_args(argv)
        if args.interface is not None or args.self_test is not None:
            if args.cmd or (args.interface is not None and args.self_test is not None):
                raise ans(USAGE, "usage", 0, detail="interface/self-test must be used alone")
            version = args.interface if args.interface is not None else args.self_test
            if version != "v1":
                print("unsupported interface " + version)
                return 1
            if args.interface is not None:
                print(INTERFACE)
                return 0
            return self_test()
        if args.cmd is None:
            raise ans(USAGE, "usage", 0, detail="a command is required")
        result = COMMANDS[args.cmd](args)
    except fmt.SeamRefused as exc:
        result = ans(USAGE, "usage", 0, detail=str(exc))
    except Answered as a:
        result = a
    fmt.emit(result.result)
    return result.result["exit"]


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
