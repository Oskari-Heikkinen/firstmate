"""fm_owner_notice_format - the shared half of fm-owner-notice/v1.

Both sides import this module: the producer client
(bin/fm-owner-notice-client.py) and the owner engine
(bin/fm_owner_notice_store.py). It owns, once each:

- canonical JSON and its strict parser (duplicate keys refused, and the bytes
  must equal their own canonical form);
- the key, id and kind grammars;
- the deterministic envelope, so its digest is a pure function of
  (binding, key, kind, payload);
- the binding, receipt and config schemas, validated field by field;
- the durable I/O primitives: create_exclusive, replace_durable,
  mkdir_durable, fsync_file, fsync_dir and read_regular_nofollow. Every fsync
  in owner-notice goes through fsync_file or fsync_dir, which are the spy
  points of FM_OWNER_NOTICE_FSYNC_SPY;
- process identity (pid plus /proc start time);
- the test seams, which are inert unless FM_OWNER_NOTICE_TEST_ROOT is set and
  every path the process touches is under it (see Seams.check).

docs/owner-notice.md owns the protocol, the formats and the seam grammar. This
module uses the standard library only, because the producer's pinned closure
is exactly this file and the client.
"""

import base64
import errno as errno_mod
import hashlib
import json
import os
import re
import secrets
import signal
import stat
import subprocess
import sys
import time

ENVELOPE_SCHEMA = "fm-owner-notice/v1"
ENVELOPE_PREFIX = "fm-owner-notice/v"
BINDING_SCHEMA = "fm-owner-notice-binding/v1"
RECEIPT_SCHEMA = "fm-owner-notice-receipt/v1"
CONFIG_SCHEMA = "fm-owner-notice-client-config/v1"
ANSWER_SCHEMA = "fm-owner-notice-answer/v1"
MANIFEST_SCHEMA = "fm-owner-notice-manifest/v1"
INDEX_SCHEMA = "fm-owner-notice-outbox-index/v1"
CURRENT_SCHEMA = "fm-owner-notice-current/v1"
LIVE_SCHEMA = "fm-owner-notice-live/v1"
LIVE_BOUND = 16 << 20

NOTE = "Delivery is not consumption or acceptance."

# The key, binding id and kind grammar is one pattern. fullmatch is used
# everywhere, because $ also matches before a final newline.
NAME_RE = re.compile(r"[a-z0-9][a-z0-9._-]{0,127}")
SHA_RE = re.compile(r"[0-9a-f]{64}")
ENVELOPE_SUFFIX = ".envelope.json"

MAX_BYTES_CAP = 65536
RECORD_BOUND = 1 << 20          # any owner or producer record we read
BINDING_BOUND = 64 * 1024
CONFIG_BOUND = 64 * 1024

ENVELOPE_FIELDS = ("binding_id", "binding_sha256", "kind", "notice_key",
                   "payload_b64", "payload_sha256", "schema")
BINDING_FIELDS = ("binding_id", "consume_bound_seconds", "created_at", "envelope_versions",
                  "kinds", "machine_id", "max_bytes", "outbox", "outbox_dev", "outbox_ino",
                  "owner_home_path", "producer_actor", "producer_uid", "receipt_versions",
                  "recipient_home", "schema")
# The fields two binds must agree on for a replay; created_at is the first
# bind's and is kept.
BINDING_REPLAY_FIELDS = tuple(f for f in BINDING_FIELDS if f != "created_at")
IDENTITY_FIELDS = ("binding_id", "binding_sha256", "recipient_home", "owner_home_path",
                   "machine_id", "producer_actor", "notice_key")
RECEIPT_COMMON = ("schema", "seq", "outcome") + IDENTITY_FIELDS + ("recorded_at", "note")
RECEIPT_EXTRA = {
    "delivered": ("kind", "payload_sha256", "envelope_sha256", "envelope_bytes"),
    "consumed": ("kind", "payload_sha256", "envelope_sha256", "delivered_seq"),
    "refused-digest": ("scope", "code", "kind", "payload_sha256", "envelope_sha256"),
    "refused-key": ("scope", "code"),
}
DIGEST_CODES = ("key-conflict", "kind-not-allowed", "binding-mismatch", "version-unsupported")
KEY_CODES = ("unsafe-file", "oversize", "malformed", "digest-mismatch", "name-key-mismatch",
             "binding-retired")
CONFIG_FIELDS = ("schema", "binding_id", "binding_sha256", "recipient_home", "owner_home_path",
                 "machine_id", "producer_actor", "outbox", "closure")
FS_ALLOWLIST = ("ext4", "xfs", "btrfs", "tmpfs", "overlay")


class FormatError(ValueError):
    """Bytes or a record that do not meet the format."""


class NotRegular(OSError):
    """An entry that is not a regular single-link file."""


class InProgress(NotRegular):
    """A file whose only other link is its publisher's temp: visible, not yet committed."""


class Oversize(OSError):
    """An entry over its bound; detail is "size" (fstat) or "grew" (read)."""

    def __init__(self, detail):
        super().__init__(errno_mod.EFBIG, "oversize: " + detail)
        self.detail = detail


class SeamRefused(Exception):
    """A test seam set outside its test root: exit 2."""


def envelope_cap(max_bytes):
    """The largest envelope a binding with this max_bytes can need."""
    return 4 * -(-max_bytes // 3) + 1024


def valid_name(value):
    return isinstance(value, str) and NAME_RE.fullmatch(value) is not None


def valid_sha(value):
    return isinstance(value, str) and SHA_RE.fullmatch(value) is not None


def sha256_hex(data):
    return hashlib.sha256(data).hexdigest()


def canonical(obj):
    """The one canonical byte form: sorted keys, no spaces, ASCII, no newline."""
    return json.dumps(obj, sort_keys=True, separators=(",", ":"), ensure_ascii=True,
                      allow_nan=False).encode("ascii")


def _no_dupes(pairs):
    out = {}
    for k, v in pairs:
        if k in out:
            raise FormatError("duplicate key " + repr(k))
        out[k] = v
    return out


def parse_canonical(data):
    """Parse bytes that must already be canonical; anything else is FormatError."""
    try:
        text = data.decode("ascii")
        obj = json.loads(text, object_pairs_hook=_no_dupes,
                         parse_constant=lambda c: (_ for _ in ()).throw(FormatError(c)))
    except (UnicodeDecodeError, ValueError) as exc:
        raise FormatError(str(exc)) from None
    if canonical(obj) != data:
        raise FormatError("not canonical")
    return obj


def utc_iso(epoch):
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(int(epoch)))


def parse_iso(text):
    if not isinstance(text, str) or not re.fullmatch(r"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ", text):
        raise FormatError("bad time " + repr(text))
    import calendar
    return calendar.timegm(time.strptime(text, "%Y-%m-%dT%H:%M:%SZ"))


def envelope(binding_id, binding_sha256, key, kind, payload):
    """The deterministic envelope bytes; no timestamp, so the digest is recomputable."""
    return canonical({
        "schema": ENVELOPE_SCHEMA,
        "binding_id": binding_id,
        "binding_sha256": binding_sha256,
        "notice_key": key,
        "kind": kind,
        "payload_sha256": sha256_hex(payload),
        "payload_b64": base64.b64encode(payload).decode("ascii"),
    })


def decode_b64(text):
    if not isinstance(text, str):
        raise FormatError("payload_b64 is not a string")
    try:
        raw = base64.b64decode(text.encode("ascii"), validate=True)
    except (ValueError, UnicodeEncodeError) as exc:
        raise FormatError("payload_b64: " + str(exc)) from None
    if base64.b64encode(raw).decode("ascii") != text:
        raise FormatError("payload_b64 is not canonical base64")
    return raw


def _int(value, lo, hi):
    return isinstance(value, int) and not isinstance(value, bool) and lo <= value <= hi


def validate_binding(obj):
    """Raise FormatError unless obj is a complete fm-owner-notice-binding/v1."""
    if not isinstance(obj, dict) or tuple(sorted(obj)) != BINDING_FIELDS:
        raise FormatError("binding fields")
    if obj["schema"] != BINDING_SCHEMA:
        raise FormatError("binding schema")
    if not valid_name(obj["binding_id"]):
        raise FormatError("binding_id")
    for f in ("recipient_home", "owner_home_path", "machine_id", "producer_actor", "outbox",
              "created_at"):
        if not isinstance(obj[f], str) or not obj[f]:
            raise FormatError(f)
    if not obj["owner_home_path"].startswith("/") or not obj["outbox"].startswith("/"):
        raise FormatError("paths must be absolute")
    parse_iso(obj["created_at"])
    if not _int(obj["max_bytes"], 1, MAX_BYTES_CAP):
        raise FormatError("max_bytes")
    if not _int(obj["consume_bound_seconds"], 1, 10 ** 9):
        raise FormatError("consume_bound_seconds")
    for f in ("producer_uid", "outbox_dev", "outbox_ino"):
        if not _int(obj[f], 0, 2 ** 64):
            raise FormatError(f)
    kinds = obj["kinds"]
    if (not isinstance(kinds, list) or not kinds or not all(valid_name(k) for k in kinds)
            or sorted(set(kinds)) != kinds):
        raise FormatError("kinds")
    if obj["envelope_versions"] != [1] or obj["receipt_versions"] != [1]:
        raise FormatError("versions")
    return obj


def validate_live(obj, binding_id):
    """The bounded live-key inventory is required membership evidence, not a cache."""
    if (not isinstance(obj, dict) or set(obj) != {"schema", "binding_id", "keys"}
            or obj["schema"] != LIVE_SCHEMA or obj["binding_id"] != binding_id):
        raise FormatError("live inventory identity/fields")
    keys = obj["keys"]
    if (not isinstance(keys, list) or not all(valid_name(k) for k in keys)
            or keys != sorted(set(keys))):
        raise FormatError("live inventory keys")
    return obj


def validate_current(obj, binding_id, key):
    """Validate the complete flat projection, including identity and state fields."""
    fields = {"schema", "binding_id", "key", "state", "kind", "payload_sha256", "seq", "code",
              "final_at", "delivered_at", "consumed_at", "problem", "problem_since"}
    if not isinstance(obj, dict) or set(obj) != fields:
        raise FormatError("current fields")
    if obj["schema"] != CURRENT_SCHEMA or obj["binding_id"] != binding_id or obj["key"] != key:
        raise FormatError("current identity")
    state = obj["state"]
    if state not in ("pending", "delivered", "consumed", "refused"):
        raise FormatError("current state")
    for name in ("final_at", "delivered_at", "consumed_at", "problem_since"):
        if obj[name] is not None:
            try:
                parse_iso(obj[name])
            except (ValueError, OverflowError):
                raise FormatError("current " + name) from None
    if obj["kind"] is not None and not valid_name(obj["kind"]):
        raise FormatError("current kind")
    if obj["payload_sha256"] is not None and not valid_sha(obj["payload_sha256"]):
        raise FormatError("current payload_sha256")
    if obj["seq"] is not None and not _int(obj["seq"], 1, 2 ** 63 - 1):
        raise FormatError("current seq")
    if obj["code"] is not None and obj["code"] not in KEY_CODES + DIGEST_CODES:
        raise FormatError("current code")
    if obj["problem"] not in (None, "custody-mismatch", "orphan-custody", "seq-collision"):
        raise FormatError("current problem")
    if (obj["problem"] is None) != (obj["problem_since"] is None):
        raise FormatError("current problem_since")
    if state == "pending":
        if any(obj[f] is not None for f in ("kind", "payload_sha256", "seq", "code", "final_at",
                                            "delivered_at", "consumed_at")):
            raise FormatError("current pending fields")
    else:
        if obj["seq"] is None or obj["final_at"] is None:
            raise FormatError("current final fields")
        if state in ("delivered", "consumed"):
            if any(obj[f] is None for f in ("kind", "payload_sha256", "delivered_at")):
                raise FormatError("current delivery fields")
            if obj["code"] not in (None, "key-conflict"):
                raise FormatError("current delivery code")
        elif obj["code"] is None or obj["delivered_at"] is not None:
            raise FormatError("current refusal fields")
        if (state == "consumed") != (obj["consumed_at"] is not None):
            raise FormatError("current consumed_at")
    return obj


def parse_binding_beat(data):
    """Read the runner's complete newline-terminated binding beat, not a receipt.

    Kept here so presence and coverage readers share the record grammar.
    Unknown fields and partial records refuse rather than implying liveness.
    """
    fields = {"writer", "epoch", "runner_pid", "runner_starttime", "watcher_pid",
              "watcher_identity", "outbox_mtime_ns", "dirty_since"}
    try:
        text = data.decode("ascii")
        if not text.endswith("\n") or "\n" in text[:-1] or "\x00" in text:
            raise ValueError("partial or multiline beat")
        pairs = [word.split("=", 1) for word in text[:-1].split(" ")]
        if any(len(pair) != 2 or not pair[1] for pair in pairs):
            raise ValueError("beat fields")
        obj = dict(pairs)
        if set(obj) != fields:
            raise ValueError("beat fields")
        for key in ("writer", "watcher_identity"):
            if any(ord(char) < 33 or ord(char) == 127 for char in obj[key]):
                raise ValueError("beat " + key + " token")
        for key in ("epoch", "runner_pid", "runner_starttime", "watcher_pid", "outbox_mtime_ns"):
            if not obj[key].isdigit():
                raise ValueError("beat " + key)
        if int(obj["runner_pid"]) <= 0 or int(obj["watcher_pid"]) <= 0:
            raise ValueError("beat pid")
        if obj["dirty_since"] != "-" and not obj["dirty_since"].isdigit():
            raise ValueError("beat dirty_since")
        for key in ("epoch", "watcher_pid"):
            obj[key] = int(obj[key])
        return obj
    except (UnicodeDecodeError, ValueError, TypeError) as exc:
        raise FormatError("invalid binding beat: %s" % exc) from None


def receipt_identity(binding, binding_sha256, key):
    return {
        "binding_id": binding["binding_id"],
        "binding_sha256": binding_sha256,
        "recipient_home": binding["recipient_home"],
        "owner_home_path": binding["owner_home_path"],
        "machine_id": binding["machine_id"],
        "producer_actor": binding["producer_actor"],
        "notice_key": key,
    }


def receipt_shape(obj):
    """The RECEIPT_EXTRA key for a receipt object, or FormatError."""
    if not isinstance(obj, dict):
        raise FormatError("receipt is not an object")
    if obj.get("schema") != RECEIPT_SCHEMA:
        raise FormatError("receipt version")
    outcome = obj.get("outcome")
    if outcome == "refused":
        shape = "refused-digest" if obj.get("scope") == "digest" else "refused-key"
    elif outcome in ("delivered", "consumed"):
        shape = outcome
    else:
        raise FormatError("outcome")
    return shape


def validate_receipt(obj, seq_from_name=None):
    """Raise FormatError unless obj is a well-formed receipt; return its shape."""
    if isinstance(obj, dict) and obj.get("schema") != RECEIPT_SCHEMA:
        raise FormatError("receipt version")
    shape = receipt_shape(obj)
    extra = RECEIPT_EXTRA[shape]
    if shape == "refused-key":
        want = set(RECEIPT_COMMON + extra)
        if set(obj) - {"envelope_sha256"} != want:
            raise FormatError("receipt fields")
        if "envelope_sha256" in obj and not valid_sha(obj["envelope_sha256"]):
            raise FormatError("envelope_sha256")
        if obj["scope"] != "key" or obj["code"] not in KEY_CODES:
            raise FormatError("refusal code")
    else:
        if set(obj) != set(RECEIPT_COMMON + extra):
            raise FormatError("receipt fields")
        if not valid_sha(obj["payload_sha256"]) or not valid_sha(obj["envelope_sha256"]):
            raise FormatError("digests")
        if not valid_name(obj["kind"]):
            raise FormatError("kind")
        if shape == "refused-digest" and obj["code"] not in DIGEST_CODES:
            raise FormatError("refusal code")
        if shape == "delivered" and not _int(obj["envelope_bytes"], 1, 1 << 24):
            raise FormatError("envelope_bytes")
        if shape == "consumed" and not _int(obj["delivered_seq"], 1, 1 << 40):
            raise FormatError("delivered_seq")
    if not _int(obj["seq"], 1, 1 << 40):
        raise FormatError("seq")
    if seq_from_name is not None and obj["seq"] != seq_from_name:
        raise FormatError("file name is not its seq")
    if obj["note"] != NOTE:
        raise FormatError("note")
    if not valid_name(obj["notice_key"]) or not valid_name(obj["binding_id"]):
        raise FormatError("identity")
    parse_iso(obj["recorded_at"])
    return shape


def receipt_digest(obj):
    """(payload_sha256, kind) of a receipt that names one, else None."""
    if "payload_sha256" in obj and "kind" in obj:
        return (obj["payload_sha256"], obj["kind"])
    return None


def seq_of_name(name):
    if not name.endswith(".json"):
        return None
    stem = name[:-5]
    if not stem.isdigit() or stem != str(int(stem)) or int(stem) < 1:
        return None
    return int(stem)


# ---------------------------------------------------------------- process identity

def pid_starttime(pid):
    """The start time of pid from /proc (field 22), or ps lstart; None when gone."""
    try:
        with open("/proc/%d/stat" % pid, "rb") as fh:
            data = fh.read()
        return data[data.rindex(b")") + 2:].split()[19].decode("ascii")
    except FileNotFoundError:
        if os.path.isdir("/proc/self"):
            return None
    except (OSError, ValueError, IndexError):
        return None
    try:
        # LC_ALL=C keeps lstart locale-invariant between writer and reader.
        out = subprocess.run(["ps", "-o", "lstart=", "-p", str(pid)], capture_output=True,
                             env=dict(os.environ, LC_ALL="C"), text=True, timeout=5,
                             check=False).stdout.strip()
    except (OSError, subprocess.SubprocessError):
        return None
    return "-".join(out.split()) or None


def identity_alive(pid, starttime):
    try:
        pid = int(pid)
    except (TypeError, ValueError):
        return False
    return pid > 0 and pid_starttime(pid) == str(starttime)


def own_identity():
    pid = os.getpid()
    return pid, pid_starttime(pid) or "0"


def identity_name_alive(name):
    """For a <pid>-<starttime>[-<rand>] name: whether that identity still lives."""
    parts = name.split("-")
    if len(parts) < 2 or not parts[0].isdigit():
        return False
    pid = int(parts[0])
    st = pid_starttime(pid)
    if st is None:
        return False
    # The start time may itself hold dashes (the ps fallback), so compare the
    # name's prefix rather than a fixed field.
    return name[len(parts[0]) + 1:].startswith(st + "-") or name[len(parts[0]) + 1:] == st


# ---------------------------------------------------------------- seams

TEST_ROOT_MARKER = ".fm-owner-notice-test-root"


def check_test_root(root):
    """A test root is never / and holds a regular marker file, so the
    environment alone cannot turn a seam on."""
    real = os.path.realpath(root)
    if real == "/":
        raise SeamRefused("FM_OWNER_NOTICE_TEST_ROOT may not be /")
    try:
        st = os.lstat(os.path.join(real, TEST_ROOT_MARKER))
    except OSError:
        st = None
    if st is None or not stat.S_ISREG(st.st_mode):
        raise SeamRefused("FM_OWNER_NOTICE_TEST_ROOT has no regular %s file" % TEST_ROOT_MARKER)


class Seams:
    """FM_OWNER_NOTICE_* test seams; all inert unless the test root holds every path."""

    VARS = ("FM_OWNER_NOTICE_FAULT", "FM_OWNER_NOTICE_FSYNC_SPY", "FM_OWNER_NOTICE_OPEN_COUNT",
            "FM_OWNER_NOTICE_NOW")

    def __init__(self, env=None):
        env = os.environ if env is None else env
        self.root = env.get("FM_OWNER_NOTICE_TEST_ROOT") or ""
        self.raw = {v: env.get(v, "") for v in self.VARS}
        self.active = any(self.raw.values())
        self.points = {}
        self.probe_errno = {}
        self.roles = {"no-pdeathsig": set(), "child-ignore-term": set(), "unkillable": set()}
        self.values = {}
        self.fired = set()
        self.spy = self.raw["FM_OWNER_NOTICE_FSYNC_SPY"]
        self.open_log = self.raw["FM_OWNER_NOTICE_OPEN_COUNT"]
        self.now = None
        self.paths = []
        if not self.active:
            return
        if not self.root:
            raise SeamRefused("FM_OWNER_NOTICE_* seams need FM_OWNER_NOTICE_TEST_ROOT")
        check_test_root(self.root)
        for item in filter(None, self.raw["FM_OWNER_NOTICE_FAULT"].split(",")):
            self._parse(item)
        if self.raw["FM_OWNER_NOTICE_NOW"]:
            if not self.raw["FM_OWNER_NOTICE_NOW"].isdigit():
                raise SeamRefused("FM_OWNER_NOTICE_NOW must be epoch seconds")
            self.now = int(self.raw["FM_OWNER_NOTICE_NOW"])
        for p in (self.spy, self.open_log):
            if p:
                self.paths.append(p)

    def _parse(self, item):
        m = re.fullmatch(r"probe-errno:([a-z-]+):([A-Z]+)", item)
        if m:
            code = getattr(errno_mod, m.group(2), None)
            if code is None:
                raise SeamRefused("unknown errno " + m.group(2))
            self.probe_errno[m.group(1)] = code
            return
        m = re.fullmatch(r"(no-pdeathsig|child-ignore-term|unkillable):([a-z]+)", item)
        if m:
            self.roles[m.group(1)].add(m.group(2))
            return
        m = re.fullmatch(r"(seq:stale|seq:stale-always|ingest-cap|cache-slack|in-progress-settle|membership-write-bound)=(\d+)", item)
        if m:
            self.values[m.group(1)] = int(m.group(2))
            return
        m = re.fullmatch(r"mountinfo=(/.+)", item)
        if m:
            self.values["mountinfo"] = m.group(1)
            self.paths.append(m.group(1))
            return
        m = re.fullmatch(r"([a-z-]+:[a-z-]+):(kill|pause=/.+|errno=[A-Z]+)", item)
        if m:
            act = m.group(2)
            if act.startswith("pause="):
                self.paths.append(act[6:])
            elif act.startswith("errno="):
                if getattr(errno_mod, act[6:], None) is None:
                    raise SeamRefused("unknown errno " + act[6:])
            self.points[m.group(1)] = act
            return
        raise SeamRefused("unknown seam " + repr(item))

    def check(self, *paths):
        """Refuse (exit 2) unless every path this process touches is under the root."""
        if not self.active:
            return
        root = os.path.realpath(self.root)
        for p in list(self.paths) + [p for p in paths if p]:
            real = os.path.realpath(p)
            if real != root and not real.startswith(root.rstrip("/") + "/"):
                raise SeamRefused("seam path outside FM_OWNER_NOTICE_TEST_ROOT: " + p)

    def fault(self, point):
        """Run the action named for point, once per process."""
        act = self.points.get(point)
        if act is None or point in self.fired:
            return
        self.fired.add(point)
        if act == "kill":
            os.kill(os.getpid(), signal.SIGKILL)
        elif act.startswith("errno="):
            code = getattr(errno_mod, act[6:])
            raise OSError(code, os.strerror(code) + " (seam " + point + ")")
        else:
            fifo = act[6:]
            with open(fifo + ".reached", "a") as fh:
                fh.write("%s %d\n" % (point, os.getpid()))
            with open(fifo, "rb") as fh:
                fh.read()

    def role(self, kind, role):
        return self.active and role in self.roles[kind]

    def value(self, name, default=None):
        return self.values.get(name, default) if self.active else default

    def time(self):
        return self.now if self.now is not None else int(time.time())

    def spy_line(self, ident, path):
        if self.spy:
            with open(self.spy, "a") as fh:
                fh.write("%s %s %d\n" % (ident, path, time.monotonic_ns()))

    def opened(self, role, op, path):
        if self.open_log:
            with open(self.open_log, "a") as fh:
                fh.write("%s %s %s\n" % (role, op, path))


SEAMS = None


def seams():
    global SEAMS
    if SEAMS is None:
        SEAMS = Seams()
    return SEAMS


# ---------------------------------------------------------------- durable I/O

def fsync_file(fd, ident, path):
    seams().spy_line(ident, path)
    os.fsync(fd)


def fsync_dir(path, ident):
    seams().spy_line(ident, path)
    fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def _write_temp(tmpdir, data, file_ident):
    name = "%d-%s-%s" % (os.getpid(), own_identity()[1], secrets.token_hex(6))
    tmp = os.path.join(tmpdir, name)
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_CLOEXEC | os.O_NOFOLLOW, 0o644)
    try:
        view = memoryview(data)
        while view:
            view = view[os.write(fd, view):]
        fsync_file(fd, file_ident, tmp)
    except BaseException:
        os.close(fd)
        _unlink_quiet(tmp)
        raise
    os.close(fd)
    return tmp


def _unlink_quiet(path):
    try:
        os.unlink(path)
    except FileNotFoundError:
        pass


TEMP_NAME = re.compile(r"[0-9]+-.+-[0-9a-f]{12}")


def create_exclusive(path, data, tmpdir, dir_ident, file_ident="o-temp-fsync", before_link=None):
    """Write data to a temp, fsync it, link it to path (EEXIST raises), fsync the dir, commit.

    The commit is the temp's unlink, after path's directory fsync: while path
    still has its temp as a second link, readers given tmpdir see InProgress,
    so a single-link path is always one whose name is durable. The temp's
    directory is fsynced after the unlink. A publisher killed before its
    commit leaves the temp, which reap_dead_temps finishes. Returns True.
    """
    tmp = _write_temp(tmpdir, data, file_ident)
    try:
        if before_link is not None:
            before_link()
        os.link(tmp, path)
    except BaseException:
        _unlink_quiet(tmp)
        raise
    seams().spy_line("link", path)
    seams().fault(dir_ident + ":after-link")
    fsync_dir(os.path.dirname(path), dir_ident)
    seams().fault(dir_ident + ":after-dirsync")
    os.unlink(tmp)
    seams().spy_line("commit", path)
    fsync_dir(tmpdir, file_ident.replace("-fsync", "-dirsync"))
    seams().spy_line("create", path)
    return True


def publisher_temp(tmpdir, st, dir_fd=None):
    """The name in tmpdir of the publisher's temp that is st's other link, or None.

    Only a regular file with exactly two links, whose other link carries a
    temp name directly in tmpdir, is a publication in progress; any other
    extra link is foreign.
    """
    if not stat.S_ISREG(st.st_mode) or st.st_nlink != 2:
        return None
    try:
        tfd = os.open(tmpdir, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC, dir_fd=dir_fd)
    except FileNotFoundError:
        return None
    except OSError as exc:
        raise InProgress(errno_mod.EBUSY, "publisher temp directory unavailable", tmpdir) from exc
    try:
        for name in os.listdir(tfd):
            if not TEMP_NAME.fullmatch(name):
                continue
            try:
                seams().fault("publication:before-temp-stat")
                t = os.stat(name, dir_fd=tfd, follow_symlinks=False)
            except FileNotFoundError:
                continue
            if (t.st_dev, t.st_ino) == (st.st_dev, st.st_ino):
                return name
    except OSError as exc:
        raise InProgress(errno_mod.EBUSY, "publisher temp lookup unavailable", tmpdir) from exc
    finally:
        os.close(tfd)
    return None


def replace_durable(path, data, tmpdir, dir_ident, file_ident="o-temp-fsync"):
    """Temp, fsync, rename over path, fsync the dir. Only for files no idempotency rests on."""
    tmp = _write_temp(tmpdir, data, file_ident)
    try:
        os.rename(tmp, path)
    except BaseException:
        _unlink_quiet(tmp)
        raise
    seams().spy_line("rename", path)
    fsync_dir(os.path.dirname(path), dir_ident)


def unlink_durable(path, dir_ident):
    os.unlink(path)
    seams().spy_line("unlink", path)
    fsync_dir(os.path.dirname(path), dir_ident)


def mkdir_durable(path, mode=0o755, ident="o-mkdir-parent", root=None):
    """Create path and any missing parents, fsyncing each created level's parent.

    With root (an ancestor of path), the parent of every level below root is
    fsynced on every call, created now or not, so a replay finishes the
    barrier a run killed between its mkdir and that fsync never reached.
    """
    path = os.path.abspath(path)
    missing = []
    probe = path
    while not os.path.isdir(probe):
        if os.path.lexists(probe):
            raise NotADirectoryError(errno_mod.ENOTDIR, "not a directory", probe)
        missing.append(probe)
        probe = os.path.dirname(probe)
    synced = set()
    for level in reversed(missing):
        try:
            os.mkdir(level, mode)
        except FileExistsError:
            if not os.path.isdir(level) or os.path.islink(level):
                raise
            continue
        seams().fault(ident + ":after-mkdir")
        fsync_dir(os.path.dirname(level), ident)
        synced.add(os.path.dirname(level))
    if root is None:
        return
    root = os.path.abspath(root)
    level = path
    while level != root and level.startswith(root.rstrip("/") + "/"):
        parent = os.path.dirname(level)
        if parent not in synced:
            fsync_dir(parent, ident)
        level = parent


def read_regular_nofollow(path, bound, role="", dir_fd=None, after_fstat=None, tmpdir=None):
    """Read a regular, single-link, non-symlink file of at most bound bytes.

    The open is O_NOFOLLOW|O_NONBLOCK, so a symlink fails with ELOOP and a FIFO
    never blocks. fstat decides the type, the link count and the size before any
    byte is read; the read itself is bounded to bound+1 so a file that grew is
    caught too. With tmpdir (the publisher's temp directory, relative to dir_fd
    when given), a second link that is the publisher's temp raises InProgress
    instead of NotRegular. Raises InProgress, NotRegular, Oversize or OSError.
    """
    shown = path if dir_fd is None else "<fd>/" + path
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC, dir_fd=dir_fd)
    try:
        seams().opened(role, "open", shown)
        st = os.fstat(fd)
        if not stat.S_ISREG(st.st_mode):
            raise NotRegular(errno_mod.EINVAL, "not a regular file", shown)
        if st.st_nlink != 1:
            if tmpdir is not None:
                seams().fault("publication:before-temp-lookup")
                if publisher_temp(tmpdir, st, dir_fd) is not None:
                    raise InProgress(errno_mod.EBUSY, "publication not yet committed", shown)
                # The publisher may commit between fstat and the lookup (or
                # unlink a name already listed). Revalidate this opened inode,
                # not the pathname, once; a remaining foreign link still fails.
                st = os.fstat(fd)
            if st.st_nlink != 1:
                raise NotRegular(errno_mod.EMLINK, "more than one link", shown)
        if st.st_size > bound:
            raise Oversize("size")
        if after_fstat is not None:
            after_fstat()
        seams().opened(role, "read", shown)
        chunks = []
        left = bound + 1
        while left > 0:
            chunk = os.read(fd, min(left, 1 << 16))
            if not chunk:
                break
            chunks.append(chunk)
            left -= len(chunk)
        data = b"".join(chunks)
        if len(data) > bound:
            raise Oversize("grew")
        return data
    finally:
        os.close(fd)


def read_record(path, bound=RECORD_BOUND, role=""):
    """read_regular_nofollow, returning None when the file is absent."""
    try:
        return read_regular_nofollow(path, bound, role)
    except FileNotFoundError:
        return None


def scandir_names(path, role=""):
    seams().opened(role, "scandir", path)
    with os.scandir(path) as it:
        return sorted(e.name for e in it)


def _other_link_dir(tmpdir, tmp, st):
    """The directory under tmpdir's parent holding another link to st, or None."""
    tmpdir = os.path.abspath(tmpdir)
    for top, dirs, files in os.walk(os.path.dirname(tmpdir)):
        if top == tmpdir:
            dirs[:] = []
            continue
        for name in files:
            p = os.path.join(top, name)
            try:
                o = os.lstat(p)
            except OSError:
                continue
            if (o.st_dev, o.st_ino) == (st.st_dev, st.st_ino):
                return top
    return None


def reap_dead_temps(tmpdir, keep=(), files_only=False, sync_ident="o-finish-sync"):
    """Remove temp entries in tmpdir whose <pid>-<starttime> no longer lives.

    A dead temp that still has a second link is a publication killed before
    its commit (create_exclusive), whose destination directory may never have
    been fsynced; reaping it is that publication's commit, so the directory
    holding the other link (found under tmpdir's parent, which holds every
    name this side publishes) is fsynced before the unlink, and tmpdir after.
    A whole-machine sync() is not used: it can block for minutes behind other
    filesystems. With files_only, directories (stage runs) are left alone.
    """
    try:
        names = os.listdir(tmpdir)
    except FileNotFoundError:
        return
    finished = False
    for name in names:
        if name in keep or identity_name_alive(name):
            continue
        p = os.path.join(tmpdir, name)
        try:
            st = os.lstat(p)
            if stat.S_ISDIR(st.st_mode):
                if not files_only:
                    import shutil
                    shutil.rmtree(p, ignore_errors=True)
                continue
            if stat.S_ISREG(st.st_mode) and st.st_nlink > 1:
                dest = _other_link_dir(tmpdir, p, st)
                if dest is not None:
                    fsync_dir(dest, sync_ident)
                finished = True
            os.unlink(p)
        except OSError:
            pass
    if finished:
        fsync_dir(tmpdir, sync_ident.replace("-sync", "-dirsync"))


def mount_fstype(st_dev, mountinfo=None):
    """The filesystem types mountinfo lists for st_dev, or an empty set."""
    path = mountinfo or seams().value("mountinfo") or "/proc/self/mountinfo"
    want = "%d:%d" % (os.major(st_dev), os.minor(st_dev))
    found = set()
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as fh:
            for line in fh:
                parts = line.split()
                if len(parts) < 7 or parts[2] != want or "-" not in parts:
                    continue
                at = parts.index("-")
                if at + 1 < len(parts):
                    found.add(parts[at + 1])
    except OSError:
        return set()
    return found


def fs_allowed(st_dev):
    types = mount_fstype(st_dev)
    return bool(types) and types <= set(FS_ALLOWLIST), sorted(types)


def emit(obj):
    sys.stdout.write(json.dumps(obj, sort_keys=True) + "\n")
    sys.stdout.flush()
