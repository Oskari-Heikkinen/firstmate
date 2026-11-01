#!/usr/bin/env python3
"""Owner-notice attempted starts: one reader for watcher and handoff adapter.

runner_start_status(root, beat=None, now=None, spawned=None, bound=65) is pure.
root is the absolute owner-notices directory. beat is an already validated
mapping with an optional attempt token, or None when genuinely absent.
spawned, only for the launching watcher before its front publishes a starting
record, is {pid, starttime, token}; its identity is checked, never trusted.
Returns live, pid, starttime, started_at, token, previous, first_start, grace.
Unknown/nonregular/partial records raise FormatError or OSError, never grace.
An attempt token is history, NOT process liveness. docs/owner-notice.md owns
formats, the single-writer reservation and the nonrenewable grace contract.
CLI: --check probes only the interpreter: 0/ready, 78/one unsupported-runtime
line, other exit/output unknown. It never opens an owner tree or database.
"""
import os
import re
import sys
import time

import fm_owner_notice_format as fmt

TOKEN = re.compile(r"[0-9a-f]{32}")
# LENGTH includes whole rows (root, two failure strings, digest and scalars).
VALUE_BOUND = 16384
SQL_BOUND = 4096


def runtime_requirement():
    version = '.'.join(str(n) for n in sys.version_info[:3])
    return ('owner-notice unsupported runtime: Python ' + version +
            '; owner automation requires Python 3.11+ with SQLite Connection.setlimit/getlimit'
            ' and SQLITE_LIMIT_LENGTH/SQLITE_LIMIT_SQL_LENGTH')


def require_automation_runtime():
    """Owner automation only; producer and pure record readers stay compatible."""
    message = runtime_requirement()
    if sys.version_info < (3, 11):
        raise fmt.FormatError(message)
    try:
        import sqlite3
    except ImportError as exc:
        raise fmt.FormatError(message) from exc
    if (not callable(getattr(sqlite3.Connection, 'setlimit', None)) or
            not callable(getattr(sqlite3.Connection, 'getlimit', None)) or
            any(type(getattr(sqlite3, name, None)) is not int
                for name in ('SQLITE_LIMIT_LENGTH', 'SQLITE_LIMIT_SQL_LENGTH'))):
        raise fmt.FormatError(message)


def configure_automation_connection(connection):
    """One limit owner, shared by the capability probe and every real queue connection."""
    require_automation_runtime()
    import sqlite3
    try:
        for category, limit in ((sqlite3.SQLITE_LIMIT_LENGTH, VALUE_BOUND),
                                (sqlite3.SQLITE_LIMIT_SQL_LENGTH, SQL_BOUND)):
            connection.setlimit(category, limit)
            if connection.getlimit(category) != limit:
                raise fmt.FormatError(runtime_requirement() + '; SQLite did not install the required alarm queue limit')
    except fmt.FormatError:
        raise
    except (AttributeError, TypeError, ValueError, sqlite3.Error) as exc:
        raise fmt.FormatError(runtime_requirement() + '; SQLite limit setup failed') from exc


def check_automation_runtime():
    """No owner input is read, even when its tree is malformed or has pending work."""
    require_automation_runtime()
    import sqlite3
    try:
        connection = sqlite3.connect(':memory:')
        try:
            configure_automation_connection(connection)
        finally:
            connection.close()
    except sqlite3.Error as exc:
        raise fmt.FormatError(runtime_requirement() + '; SQLite capability probe failed') from exc


def text(path, optional=True):
    try:
        raw = fmt.read_regular_nofollow(path, fmt.RECORD_BOUND, "runner")
    except FileNotFoundError:
        # A dangling link is unknown, not a missing record.
        if optional and not os.path.lexists(path):
            return None
        raise
    try:
        return raw.decode("ascii")
    except UnicodeDecodeError as exc:
        raise fmt.FormatError("non-ASCII runner record: " + path) from exc


def fields(path, optional=True):
    raw = text(path, optional)
    if raw is None:
        return None
    result = {}
    for word in raw.split():
        key, sep, value = word.partition("=")
        if not sep or key in result or not value or "\x00" in word:
            raise fmt.FormatError("invalid runner record: " + path)
        result[key] = value
    if not result or not raw.endswith("\n"):
        raise fmt.FormatError("partial runner record: " + path)
    return result


def attempt_record(root):
    record = fields(os.path.join(root, ".runner-attempt"))
    if record is None:
        return None
    if (set(record) != {"token", "previous", "spawned_at"}
            or not TOKEN.fullmatch(record["token"])
            or not (TOKEN.fullmatch(record["previous"]) or record["previous"] in ("-", "legacy"))
            or not record["spawned_at"].isdigit()):
        raise fmt.FormatError("invalid attempted-start history")
    return record


def metadata_directory(owner):
    """Do not follow owner metadata aliases into a producer during a write."""
    try:
        fmt.require_directory(os.path.dirname(owner.root))
        for directory in (owner.root, owner.tmp):
            if os.path.lexists(directory):
                fmt.require_directory(directory)
            else:
                fmt.mkdir_durable(directory)
                fmt.require_directory(directory)
    except OSError as exc:
        raise fmt.FormatError('owner metadata directory unavailable: ' + str(exc)) from exc


def publish(owner, path, data, spy="o-runner-dirsync"):
    metadata_directory(owner)
    fmt.replace_durable(path, data.encode("ascii"), owner.tmp, spy)


def publish_fields(owner, path, record):
    publish(owner, path, " ".join("%s=%s" % x for x in record.items()) + "\n")


def reserve(owner):
    """Singleton watcher calls before spawning; never in a starting child.

    The record is durable before fork, so losing both watcher and child before
    installation cannot renew first-start grace. Only the last two tokens are
    retained: storage and reads do not grow with restart history.
    """
    prior = attempt_record(owner.root)
    previous = prior["token"] if prior else ("legacy" if fields(os.path.join(owner.root, ".runner")) else "-")
    token = os.urandom(16).hex()
    publish_fields(owner, os.path.join(owner.root, ".runner-attempt"),
                   {"token": token, "previous": previous, "spawned_at": int(time.time())})
    return token


def start_record(owner, pid, watcher, token, install=False):
    """Framing primitive; the engine proves phase authority before calling it."""
    attempt = attempt_record(owner.root)
    if attempt is None or not TOKEN.fullmatch(token) or attempt["token"] != token:
        raise fmt.FormatError("start-attempt-mismatch")
    start = fmt.pid_starttime(pid)
    if start is None:
        raise fmt.FormatError("runner-parent-gone")
    folder = os.path.join(owner.root, ".runner-starting")
    fmt.mkdir_durable(folder)
    path = os.path.join(folder, "%s-%s" % (pid, start))
    if not install:
        record = dict(attempt, pid=pid, starttime=start)
        fmt.create_exclusive(path, (" ".join("%s=%s" % x for x in record.items()) + "\n").encode(),
                             owner.tmp, "o-runner-start-dirsync")
        return
    old = fields(os.path.join(owner.root, ".runner")) or {}
    publish_fields(owner, os.path.join(owner.root, ".runner"), {
        "pid": pid, "starttime": start, "watcher_pid": watcher,
        "started_at": attempt["spawned_at"], "attempt": token,
        "prev_attempt": attempt["previous"], "prev_pid": old.get("pid", "-"),
        "prev_starttime": old.get("starttime", "-")})
    for name in os.listdir(folder):
        if name == os.path.basename(path) or not fmt.identity_name_alive(name):
            fmt.unlink_durable(os.path.join(folder, name), "o-runner-start-dirsync")


def runner_start_status(root, beat=None, now=None, spawned=None, bound=65):
    """Return current live start and whether its one-start grace applies.

    Consumers call this function rather than parsing any attempted-start,
    starting or installed-runner record. A beat with no token is legacy:
    it cannot grant grace to a token-bearing start. No file is written here.
    """
    fmt.seams().check(root)
    now = time.time() if now is None else now
    attempt = attempt_record(root)
    candidates = []

    def candidate(record, installed=False):
        required = ("pid", "starttime", "started_at", "attempt", "prev_attempt") if installed else (
            "pid", "starttime", "spawned_at", "token", "previous")
        if any(k not in record for k in required):
            raise fmt.FormatError("runner start missing fields")
        pid, start = str(record["pid"]), str(record["starttime"])
        began = str(record["started_at" if installed else "spawned_at"])
        token = record["attempt" if installed else "token"]
        previous = record["prev_attempt" if installed else "previous"]
        if (not pid.isdigit() or int(pid) <= 1 or not start.isdigit() or not began.isdigit()
                or not TOKEN.fullmatch(token)
                or not (TOKEN.fullmatch(previous) or previous in ("-", "legacy"))):
            raise fmt.FormatError("invalid runner start identity")
        if fmt.identity_alive(int(pid), start):
            candidates.append(dict(live=True, pid=int(pid), starttime=start, started_at=int(began),
                                   token=token, previous=previous))

    installed = fields(os.path.join(root, ".runner"))
    if installed:
        candidate(installed, True)
    folder = os.path.join(root, ".runner-starting")
    if os.path.lexists(folder):
        if os.path.islink(folder) or not os.path.isdir(folder):
            raise fmt.FormatError("invalid starting directory")
        for name in fmt.scandir_names(folder, "runner"):
            record = fields(os.path.join(folder, name), False)
            if name != "%s-%s" % (record.get("pid"), record.get("starttime")):
                raise fmt.FormatError("starting identity differs from filename")
            candidate(record)
    if spawned and attempt and spawned.get("token") == attempt["token"]:
        candidate(dict(attempt, pid=spawned["pid"], starttime=spawned["starttime"]))
    result = dict(live=False, pid=None, starttime=None, started_at=None, token=None,
                  previous=None, first_start=False, grace=False)
    if not candidates:
        return result
    # A recorded attempt outranks installation order. An old live front cannot
    # grant grace for a newer failed attempt that has no live identity.
    current = [c for c in candidates if attempt and c["token"] == attempt["token"]]
    result.update(max(current or candidates, key=lambda c: c["started_at"]))
    latest = bool(attempt and result["token"] == attempt["token"])
    result["first_start"] = latest and result["previous"] == "-"
    young = 0 <= now - result["started_at"] < bound
    predecessor_beat = bool(beat and beat.get("attempt") == result["previous"])
    result["grace"] = latest and young and ((beat is None and result["first_start"]) or predecessor_beat)
    return result


if __name__ == '__main__':
    if sys.argv[1:] != ['--check']:
        print('usage: fm_owner_notice_runtime.py --check', file=sys.stderr)
        sys.exit(2)
    try:
        check_automation_runtime()
    except fmt.FormatError as error:
        print(str(error))
        sys.exit(78)
    print('ready')
