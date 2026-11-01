#!/usr/bin/env python3
"""Native runner-alarm FIFO; docs/owner-notice.md owns the v1 contract.

Only the lock-authorized watcher changes SQLite. Publishers are read-only and
return a committed result through a separate, leased slot. No service/daemon.
"""
import argparse
import fcntl
import os
import sqlite3
import stat
import subprocess
import sys
import tempfile
import time
from contextlib import contextmanager
from urllib.parse import quote

import fm_owner_notice_format as fmt
from fm_owner_notice_runtime import (metadata_directory, publish, text, require_automation_runtime,
                                     configure_automation_connection, check_automation_runtime,
                                     VALUE_BOUND, SQL_BOUND)
from fm_owner_notice_runner import INGEST_BOUND, KILL_GRACE

HERE = os.path.dirname(os.path.abspath(__file__))
NAME = '.runner-alarms.sqlite3'
MARK = '.runner-alarms.pending'
LEASE = '.runner-alarm-publisher.lock'
RESULT_DIR = '.runner-alarm-publication'
RESULT_SCHEMA = 'fm-owner-notice-runner-publication/v1'
RESULT_BOUND = 8192  # 512 non-BMP reason characters can occupy 6144 JSON bytes.
KEYS = ('runner-beat-stale', 'runner-respawn-failing')
METADATA_BOUND = 1
DDL = (
    'CREATE TABLE meta (id INTEGER PRIMARY KEY CHECK(id=1), root TEXT NOT NULL, problem TEXT, since INTEGER, cursor INTEGER NOT NULL, digest TEXT, advance_problem TEXT, advance_since INTEGER)',
    'CREATE TABLE requests (seq INTEGER PRIMARY KEY AUTOINCREMENT, key TEXT NOT NULL, action TEXT NOT NULL, reason TEXT NOT NULL, at INTEGER NOT NULL)',
    'CREATE INDEX pending_key ON requests(key, seq)',
)
REQUEST_SELECT = ("SELECT seq, CASE WHEN length(CAST(key AS BLOB))<=64 THEN key END, "
                  "CASE WHEN length(CAST(action AS BLOB))<=8 THEN action END, "
                  "CASE WHEN length(CAST(reason AS BLOB))<=8192 THEN reason END, "
                  "CASE WHEN typeof(at)='integer' THEN at END FROM requests")
HEAD = REQUEST_SELECT + ' ORDER BY seq LIMIT 1'
TAIL = REQUEST_SELECT + ' WHERE key=? ORDER BY seq DESC LIMIT 1'


def command_bound():
    value = fmt.seams().value('ingest-bound', INGEST_BOUND)
    if type(value) is not int or value < 1:
        raise fmt.FormatError('invalid alarm publication bound')
    return value


def kill_grace():
    value = fmt.seams().value('kill-grace', KILL_GRACE)
    if type(value) is not int or value < 1:
        raise fmt.FormatError('invalid alarm kill grace')
    return value


def bound():
    # Three CLI phase budgets/graces; one further grace for local result work.
    return 3 * (command_bound() + kill_grace()) + kill_grace()


class QueueConnection(sqlite3.Connection):
    def __init__(self, *args, **kwargs):
        require_automation_runtime()
        super().__init__(*args, **kwargs)
        try:
            # Apply before any statement/schema/value read, including private
            # initialization. SQL result clipping is not an allocation guard.
            configure_automation_connection(self)
        except Exception:
            self.close()
            raise

    def bound(self):
        began = time.monotonic()
        self.set_progress_handler(lambda: int(time.monotonic() - began > METADATA_BOUND), 1000)

    def execute(self, *args, **kwargs):
        self.bound()
        return super().execute(*args, **kwargs)

    def commit(self):
        self.bound()
        return super().commit()


class Initializing(Exception):
    """A live first publication with no accepted work or prior cursor."""


def regular(path, writable=False, empty=False, links=(1,)):
    st = os.lstat(path)
    if (not stat.S_ISREG(st.st_mode) or st.st_nlink not in links or not st.st_mode & 0o444 or
            (writable and not st.st_mode & 0o222) or (empty and st.st_size != 0)):
        raise fmt.FormatError('unreadable/nonregular alarm queue member: ' + path)
    return st


def paths(owner):
    return os.path.join(owner.root, NAME), os.path.join(owner.root, MARK)


def result_paths(owner):
    directory = os.path.join(owner.root, RESULT_DIR)
    return directory, os.path.join(directory, 'result'), os.path.join(directory, '.tmp')


def check_hint(owner):
    hint = text(paths(owner)[1])
    if hint is not None and hint != 'pending\n':
        raise fmt.FormatError('invalid alarm pending hint')


def check_row(row):
    if row is None:
        return
    seq, key, action, reason, at = row
    if (type(seq) is not int or seq < 1 or key not in KEYS or action not in ('assert', 'clear') or
            not isinstance(reason, str) or not reason or len(reason) > 2048 or
            any(c in reason for c in '\n\r\x00') or type(at) is not int or not 0 <= at <= 253402300799):
        raise fmt.FormatError('invalid queued alarm transition')


def digest(owner, row):
    return fmt.sha256_hex(fmt.canonical({'root': owner.root, 'request': list(row)}))


def initialize(owner):
    require_automation_runtime()
    path, _ = paths(owner)
    if os.path.lexists(path):
        return
    if os.path.lexists(result_paths(owner)[0]):
        raise fmt.FormatError('publication state exists without its queue')
    metadata_directory(owner)
    lock = os.path.join(owner.root, LEASE)
    if os.path.lexists(lock):
        regular(lock, writable=True, empty=True)
    else:
        fd = os.open(lock, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        try:
            fmt.fsync_file(fd, 'o-alarm-lease-fsync', lock)
        finally:
            os.close(fd)
        fmt.fsync_dir(owner.root, 'o-runner-dirsync')
    # The common owner temp reaper must recognize a LIVE initializer; its
    # existing dead-directory cleanup owns scratch left by a killed process.
    with tempfile.TemporaryDirectory(prefix='%s-%s-' % fmt.own_identity(), dir=owner.tmp) as scratch:
        temp = os.path.join(scratch, 'queue')
        db = sqlite3.connect(temp, timeout=METADATA_BOUND, factory=QueueConnection)
        try:
            if db.execute('PRAGMA journal_mode=WAL').fetchone() != ('wal',):
                raise fmt.FormatError('cannot initialize alarm queue WAL mode')
            for sql in DDL:
                db.execute(sql)
            db.execute('PRAGMA user_version=1')
            db.execute('INSERT INTO meta VALUES (1, ?, NULL, NULL, 0, NULL, NULL, NULL)', (owner.root,))
            db.commit()
        finally:
            db.close()
        fmt.seams().fault('alarm-initialize:prepared')
        with open(temp, 'rb') as fh:
            data = fh.read()
        try:
            fmt.create_exclusive(path, data, owner.tmp, 'o-runner-dirsync')
        except FileExistsError:
            pass  # Validate the winner, never replace it.


def read_meta(db, owner):
    rows = db.execute("SELECT id, CASE WHEN length(CAST(root AS BLOB))<=4096 THEN root END, "
                      "CASE WHEN problem IS NULL OR length(CAST(problem AS BLOB))<=2048 THEN problem ELSE -1 END, "
                      "CASE WHEN since IS NULL OR typeof(since)='integer' THEN since ELSE -1 END, "
                      "CASE WHEN typeof(cursor)='integer' THEN cursor END, "
                      "CASE WHEN digest IS NULL OR length(CAST(digest AS BLOB))<=64 THEN digest END, "
                      "CASE WHEN advance_problem IS NULL OR length(CAST(advance_problem AS BLOB))<=2048 THEN advance_problem ELSE -1 END, "
                      "CASE WHEN advance_since IS NULL OR typeof(advance_since)='integer' THEN advance_since ELSE -1 END FROM meta LIMIT 2").fetchall()
    m = rows[0][1:] if len(rows) == 1 and rows[0][0] == 1 else None
    if (not m or m[0] != owner.root or type(m[3]) is not int or m[3] < 0 or
            (m[3] == 0 and m[4] is not None) or (m[3] > 0 and not fmt.valid_sha(m[4])) or
            (m[1] is None and m[2] is not None) or (m[1] is not None and
             (not isinstance(m[1], str) or not m[1] or len(m[1]) > 512 or type(m[2]) is not int or not 0 <= m[2] <= 253402300799)) or
            (m[5] is None and m[6] is not None) or (m[5] is not None and
             (not isinstance(m[5], str) or not m[5] or len(m[5]) > 512 or type(m[6]) is not int or not 0 <= m[6] <= 253402300799))):
        raise fmt.FormatError('invalid alarm queue metadata')
    if any(reason is not None and any(c in reason for c in '\n\r\x00') for reason in (m[1], m[5])):
        raise fmt.FormatError('invalid alarm queue failure text')
    return m


@contextmanager
def connect(owner, readonly=True, initializing=False):
    path, hint = paths(owner)
    st = regular(path, writable=True, links=(1, 2) if initializing else (1,))
    birth = st.st_nlink == 2
    if birth:
        name = fmt.publisher_temp(owner.tmp, st)
        if (not name or not fmt.identity_name_alive(name) or not 0 <= time.time() - st.st_mtime <= bound() or
                os.path.lexists(hint) or os.path.lexists(result_paths(owner)[0])):
            # Publication may have finished during the temp/identity probe.
            # Only that same now-single-linked inode is an ordinary queue.
            current = regular(path, writable=True)
            if (current.st_dev, current.st_ino) != (st.st_dev, st.st_ino):
                raise fmt.FormatError('alarm queue changed during initialization read')
            birth = False
    regular(os.path.join(owner.root, LEASE), writable=True, empty=True)
    # This format never changes out of WAL or attaches other databases. A
    # rollback journal is foreign state, not permission for SQLite to recover
    # (and thereby mutate) unknown bytes while opening a write connection.
    if os.path.lexists(path + '-journal'):
        raise fmt.FormatError('unexpected alarm queue rollback journal')
    for suffix in ('-wal', '-shm'):
        if os.path.lexists(path + suffix):
            regular(path + suffix)
    db = sqlite3.connect('file:' + quote(path, safe='/') + ('?mode=ro' if readonly else '?mode=rw'),
                         uri=True, timeout=METADATA_BOUND, factory=QueueConnection)
    try:
        if readonly:
            db.execute('BEGIN')
        if db.execute('PRAGMA user_version').fetchone() != (1,):
            raise fmt.FormatError('unknown alarm queue version')
        schema = {r[0] for r in db.execute("SELECT CASE WHEN length(CAST(sql AS BLOB))<=4096 THEN sql END FROM sqlite_master WHERE name NOT LIKE 'sqlite_%' LIMIT 4")}
        if schema != set(DDL):
            raise fmt.FormatError('unknown alarm queue schema')
        meta = read_meta(db, owner)
        mode = db.execute('PRAGMA journal_mode').fetchone()[0]
        if mode != 'wal':
            raise fmt.FormatError('alarm queue is not in its native WAL mode')
        if birth and os.lstat(path).st_nlink == 2:
            if meta[3] == 0 and not meta[1] and not meta[5] and not db.execute('SELECT 1 FROM requests LIMIT 1').fetchone():
                raise Initializing()
            raise fmt.FormatError('in-progress queue has accepted work/history')
        yield db
    finally:
        db.close()


@contextmanager
def lease(owner, shared=False):
    path = os.path.join(owner.root, LEASE)
    regular(path, writable=True, empty=True)  # Never recreate a lost lease.
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        try:
            fcntl.flock(fd, (fcntl.LOCK_SH if shared else fcntl.LOCK_EX) | fcntl.LOCK_NB)
        except BlockingIOError:
            yield None
            return
        yield fd
    finally:
        os.close(fd)


def read_result(owner, finish=False):
    from fm_owner_notice_store import require_directory
    directory, path, tmp = result_paths(owner)
    if not os.path.lexists(directory):
        return None
    require_directory(directory)
    with os.scandir(directory) as entries:
        for entry in entries:
            if entry.name not in ('result', '.tmp'):
                raise fmt.FormatError('unknown publication-slot member')
    if os.path.lexists(tmp):
        require_directory(tmp)
        with os.scandir(tmp) as entries:
            for entry in entries:
                if not fmt.TEMP_NAME.fullmatch(entry.name) or not entry.is_file(follow_symlinks=False):
                    raise fmt.FormatError('unknown publication scratch member')
        if finish:
            # The caller holds the publisher lease. This dedicated namespace
            # contains no binding data or unrelated metadata publications.
            fmt.reap_dead_temps(tmp, files_only=True)
    if os.path.lexists(path):
        regular(path)
    try:
        data = fmt.read_regular_nofollow(path, RESULT_BOUND, tmpdir=tmp)
    except FileNotFoundError:
        return None
    r = fmt.parse_canonical(data)
    if (not isinstance(r, dict) or set(r) != {'schema', 'seq', 'request_sha256', 'outcome', 'reason', 'at'} or
            r['schema'] != RESULT_SCHEMA or type(r['seq']) is not int or r['seq'] < 1 or
            not fmt.valid_sha(r['request_sha256']) or r['outcome'] not in ('published', 'failed') or
            not isinstance(r['reason'], str) or len(r['reason']) > 512 or
            any(c in r['reason'] for c in '\n\r\x00') or (r['outcome'] == 'failed' and not r['reason']) or
            (r['outcome'] == 'published' and r['reason'] != '') or
            type(r['at']) is not int or not 0 <= r['at'] <= 253402300799):
        raise fmt.FormatError('unknown alarm publication result')
    try:
        r['reason'].encode('utf-8')
    except UnicodeEncodeError as exc:
        raise fmt.FormatError('publication reason is not Unicode scalar text') from exc
    return r


def match_result(owner, r, row, meta):
    if r is None:
        return None
    if row and r['seq'] == row[0] and r['request_sha256'] == digest(owner, row):
        return 'head'
    if r['outcome'] == 'published' and r['seq'] == meta[3] and r['request_sha256'] == meta[4]:
        return 'acknowledged'
    raise fmt.FormatError('publication result does not match its request/cursor')


def snapshot(db, owner):
    meta = read_meta(db, owner)
    row = db.execute(HEAD).fetchone()
    check_row(row)
    if (row and row[0] <= meta[3]) or (not row and meta[1]):
        raise fmt.FormatError('inconsistent alarm queue cursor/problem')
    return meta, row


def pending_action(owner, key):
    """Validated last pending action for one key; absent is not a write."""
    if key not in KEYS:
        raise fmt.FormatError('invalid pending alarm key')
    check_hint(owner)
    if not os.path.lexists(paths(owner)[0]):
        if os.path.lexists(paths(owner)[1]) or os.path.lexists(result_paths(owner)[0]):
            raise fmt.FormatError('publication state exists without its queue')
        return None
    with connect(owner) as db:
        snapshot(db, owner)
        row = db.execute(TAIL, (key,)).fetchone()
        check_row(row)
        return row[2] if row else None


def problem(owner):
    """Read-only independent diagnosis; no waiting for an occupied publisher."""
    from fm_owner_notice_store import require_directory
    require_directory(owner.state)
    if os.path.lexists(owner.root):
        require_directory(owner.root)
    check_hint(owner)
    if not os.path.lexists(paths(owner)[0]):
        if os.path.lexists(paths(owner)[1]) or os.path.lexists(result_paths(owner)[0]):
            raise fmt.FormatError('publication state exists without its queue')
        return None
    if os.path.lexists(owner.tmp):
        require_directory(owner.tmp)
    log = os.path.join(owner.root, 'watcher.log')
    if os.path.lexists(log):
        regular(log, writable=True)
    try:
        with lease(owner, shared=True) as held, connect(owner, initializing=True) as db:
            meta, row = snapshot(db, owner)
            fmt.seams().fault('alarm-reader:snapshot')
            problems = {}
            if meta[1]: problems['writer'] = (meta[1], meta[2])
            if meta[5]: problems['advance'] = (meta[5], meta[6])
            if row and time.time() - row[4] > bound():
                problems['overdue'] = ('oldest accepted transition is overdue', row[4] + bound())
            if held is not None:
                result = read_result(owner)
                if match_result(owner, result, row, meta) == 'head':
                    if result['outcome'] == 'published':
                        problems.pop('writer', None)
                    else:
                        problems['writer'] = (result['reason'], min(meta[2] if meta[2] is not None else result['at'], result['at']))
            if not problems:
                return None
            reason = ','.join(sorted(problems)) + ': ' + '; '.join(p[0] for p in problems.values())
            return reason[:512], min(p[1] for p in problems.values())
    except Initializing:
        return None
    except sqlite3.Error as exc:
        raise fmt.FormatError('alarm queue unreadable: ' + str(exc)) from exc


def enqueue(owner, action, key, reason):
    from fm_owner_notice_store import require_lock
    lock = os.path.join(owner.state, '.watch.lock')
    require_lock(lock)
    if action not in ('assert', 'clear') or key not in KEYS or not reason or len(reason) > 2048 or any(c in reason for c in '\n\r\x00'):
        raise fmt.FormatError('invalid alarm transition')
    check_hint(owner)
    initialize(owner)
    metadata_directory(owner)
    with connect(owner, readonly=False) as db:
        db.execute('BEGIN IMMEDIATE')
        meta, _head = snapshot(db, owner)
        last = db.execute(TAIL, (key,)).fetchone()
        check_row(last)
        if last is None or last[2] != action:
            inserted = db.execute('INSERT INTO requests(key,action,reason,at) VALUES(?,?,?,?)',
                                  (key, action, reason, int(time.time())))
            if inserted.lastrowid <= meta[3]:
                raise fmt.FormatError('alarm sequence would reuse an acknowledged request')
        publish(owner, paths(owner)[1], 'pending\n')
        require_lock(lock)
        db.commit()


def advance(owner):
    """Watcher-only metadata step; consume one result, never await a publisher."""
    from fm_owner_notice_store import require_lock
    lock = os.path.join(owner.state, '.watch.lock')
    require_lock(lock)
    limit = bound()
    check_hint(owner)
    metadata_directory(owner)
    with lease(owner) as held:
        if held is None:
            return 75
        result = read_result(owner, finish=True)
        with connect(owner, readonly=False) as db:
            db.execute('BEGIN IMMEDIATE')
            meta, row = snapshot(db, owner)
            match = match_result(owner, result, row, meta)
            if match == 'head':
                if result['outcome'] == 'published':
                    db.execute('DELETE FROM requests WHERE seq=?', (row[0],))
                    db.execute('UPDATE meta SET cursor=?, digest=?, problem=NULL, since=NULL WHERE id=1', (row[0], digest(owner, row)))
                else:
                    db.execute('UPDATE meta SET problem=?, since=COALESCE(since, ?) WHERE id=1', (result['reason'], result['at']))
            require_lock(lock)
            db.commit()
            # A crash between SQL commit and unlink leaves a result matching
            # the exact last cursor/digest; replay consumes it without re-ACK.
            if result is not None:
                fmt.seams().fault('alarm-advance:after-commit')
                fmt.unlink_durable(result_paths(owner)[1], 'o-runner-dirsync')
                fmt.seams().fault('alarm-advance:after-unlink')
            # Explicit cleanup proof, also when replaying a prior failed
            # advance with no result left. A writer success cannot clear it.
            directory = result_paths(owner)[0]
            if os.path.lexists(directory):
                fmt.fsync_dir(directory, 'o-alarm-result-dirsync')
            pending = db.execute('SELECT 1 FROM requests LIMIT 1').fetchone() is not None
            mark = paths(owner)[1]
            if pending:
                publish(owner, mark, 'pending\n')
            elif os.path.lexists(mark):
                fmt.unlink_durable(mark, 'o-runner-dirsync')
            require_lock(lock)
            db.execute('UPDATE meta SET advance_problem=NULL, advance_since=NULL WHERE id=1')
            db.commit()
            print('pending' if pending else 'idle', limit, kill_grace(), flush=True)
    return 0


def remember_advance_failure(owner, exc):
    """The watcher owns this failure; publication success cannot clear it."""
    from fm_owner_notice_store import require_lock
    require_lock(os.path.join(owner.state, '.watch.lock'))
    with connect(owner, readonly=False) as db:
        snapshot(db, owner)  # Never change an unknown queue to record a fault.
        reason = str(exc).replace('\n', ' ').replace('\r', ' ').replace('\x00', ' ')[:512] or 'queue advance failed'
        db.execute('UPDATE meta SET advance_problem=?, advance_since=COALESCE(advance_since, ?) WHERE id=1', (reason, int(time.time())))
        require_lock(os.path.join(owner.state, '.watch.lock'))
        db.commit()


def command(owner, held, script, *args):
    body = '. "$1/fm-timeout-lib.sh"; shift; fm_exec_timed "$1" "$2" bash -c "$3" _ "${@:4}"'
    p = subprocess.run(['bash', '-c', body, '_', HERE, str(command_bound()), str(kill_grace()), script, *args],
                       stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                       pass_fds=(held,), env=dict(os.environ, FM_HOME=owner.home, FM_STATE_OVERRIDE=owner.state))
    if p.returncode:
        raise RuntimeError('alarm writer exit %s: %s' % (p.returncode, p.stderr.decode(errors='replace')[-256:]))
    return p.stdout.decode('utf-8')


def drain(owner):
    check_hint(owner)
    with lease(owner) as held:
        if held is None:
            return 75
        if read_result(owner) is not None:
            return 75  # Only the watcher may consume/replace this result.
        with connect(owner) as db:
            _, row = snapshot(db, owner)
        if row is None:
            return 0
        seq, key, action, reason, at = row
        outcome, detail = 'published', ''
        try:
            store = os.path.join(owner.root, 'runner-alert-store.json')
            command(owner, held,
                    'SCRIPT_DIR=$1; . "$1/fm-wake-lib.sh"; . "$1/fm-owner-notice-run-lib.sh"; '
                    'owner_notice_initialize_store "$3" owner-notice-runner && '
                    'owner_notice_status_file "$2" && "$1/fm-alert-store.sh" register "$3" owner-notice-runner owner-notice-runner.status owner-notice',
                    HERE, os.path.join(owner.state, 'owner-notice-runner.status'), store)
            regular(store)
            if os.path.getsize(store) > fmt.RECORD_BOUND:
                raise fmt.FormatError('runner alert store exceeds record bound')
            keys = command(owner, held, '. "$1/fm-alert-store-lib.sh"; fm_alert_store_active_keys "$2"', HERE, store).splitlines()
            if (key in keys) != (action == 'assert'):
                print('%s publishing %s %s %s (observed %s): %s' % (fmt.utc_iso(time.time()), seq, action, key, at, reason), flush=True)
                command(owner, held, 'exec "$1/fm-alert-store.sh" "$2" "$3" owner-notice-runner "$4" "$5"', HERE, action, store, key, reason)
            fmt.seams().fault('alarm-publisher:after-write')
        except (OSError, ValueError, RuntimeError) as exc:
            outcome = 'failed'
            detail = str(exc).replace('\n', ' ').replace('\r', ' ').replace('\x00', ' ')[:512] or 'publication failed'
        directory, path, tmp = result_paths(owner)
        fmt.mkdir_durable(directory)
        fmt.mkdir_durable(tmp)
        result = {'schema': RESULT_SCHEMA, 'seq': seq, 'request_sha256': digest(owner, row),
                  'outcome': outcome, 'reason': detail, 'at': int(time.time())}
        fmt.create_exclusive(path, fmt.canonical(result), tmp, 'o-alarm-result-dirsync')
        # No operation after this committed result may change its outcome.
        return 0 if outcome == 'published' else 70


def open_log(owner):
    path = os.path.join(owner.root, 'watcher.log')
    fd = os.open(path, os.O_WRONLY | os.O_APPEND | os.O_CREAT | os.O_NOFOLLOW | os.O_NONBLOCK, 0o600)
    try:
        st = os.fstat(fd)
        if not stat.S_ISREG(st.st_mode) or st.st_nlink != 1 or not st.st_mode & 0o444:
            raise fmt.FormatError('unknown publisher log')
        os.dup2(fd, 1)
        os.dup2(fd, 2)
    finally:
        if fd not in (1, 2):
            os.close(fd)


def main():
    from fm_owner_notice_store import Owner, Done, require_directory, _prctl_pdeathsig
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('verb', choices=('enqueue', 'advance', 'dispatch', 'drain'))
    p.add_argument('--home', required=True)
    p.add_argument('transition', nargs='*')
    a = p.parse_args()
    try:
        check_automation_runtime()
        parent = os.getppid()
        if a.verb != 'dispatch':
            _prctl_pdeathsig()
            if os.getppid() != parent:
                raise fmt.FormatError('alarm operation parent changed')
        owner = Owner(a.home)
        require_directory(owner.state)
        require_directory(owner.root)
        if a.verb == 'enqueue':
            if len(a.transition) != 3:
                raise fmt.FormatError('enqueue requires action, key and reason')
            enqueue(owner, *a.transition)
            return 0
        if a.transition:
            raise fmt.FormatError('unexpected alarm operation arguments')
        if a.verb == 'advance':
            try:
                return advance(owner)
            except (OSError, ValueError, sqlite3.Error) as exc:
                try:
                    remember_advance_failure(owner, exc)
                except (OSError, ValueError, sqlite3.Error, Done):
                    pass  # The original refusal still reaches stderr/check.
                raise
        if a.verb == 'dispatch':
            body = '. "$1/fm-timeout-lib.sh"; fm_exec_timed "$2" "$3" python3 "$1/fm_owner_notice_alarm.py" --home "$4" drain'
            os.execvp('bash', ['bash', '-c', body, '_', HERE, str(bound()), str(kill_grace()), owner.home])
        open_log(owner)
        return drain(owner)
    except (OSError, ValueError, RuntimeError, sqlite3.Error, Done) as exc:
        print('owner-notice alarm publication unknown: ' + str(exc), file=sys.stderr, flush=True)
        return 70


if __name__ == '__main__':
    sys.exit(main())
