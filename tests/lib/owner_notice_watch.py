#!/usr/bin/env python3
"""Behavior fixtures for fm-owner-notice-watch.test.sh; never a live home.

All waits end on observable state. Caps are hang guards, not success oracles.
The shell suite owns the isolated temp root and CI case selection.
"""
import hashlib
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time

ROOT = Path(sys.argv[1])
BASE = Path(sys.argv[2])
CASE = sys.argv[3]
sys.path.insert(0, str(ROOT / 'bin'))
import fm_owner_notice_format as fmt


def wait(label, fn, cap=30):
    end = time.monotonic() + cap
    while True:
        value = fn()
        if value:
            return value
        if time.monotonic() >= end:
            raise AssertionError('timeout: ' + label)
        time.sleep(.025)


def record(path):
    try:
        return json.loads(path.read_text())
    except FileNotFoundError:
        return None


def fields(path):
    try:
        return dict(x.split('=', 1) for x in path.read_text().split())
    except FileNotFoundError:
        return {}


class World:
    def __init__(self):
        self.root = BASE / CASE
        self.home = self.root / 'home'
        self.state = self.home / 'state'
        self.own = self.state / 'owner-notices'
        self.state.mkdir(parents=True)
        (self.home / 'config').mkdir()
        (self.root / '.fm-owner-notice-test-root').touch()
        self.env = {k: v for k, v in os.environ.items() if not k.startswith(('FM_', 'BLOCK_')) and k not in ('LD_PRELOAD', 'GIT_DIR', 'GIT_WORK_TREE')}
        self.env.update(HOME=str(self.home), FM_HOME=str(self.home), FM_OWNER_NOTICE_TEST_ROOT=str(self.root),
                        FM_OWNER_NOTICE_FAULT='runner-loop-seconds=1,stat-bound=1,stage-bound=10,ingest-bound=20,kill-grace=2',
                        FM_CHECK_INTERVAL='2')
        self.script_dir = ROOT / 'bin'
        self.processes = []
        self.watch = None
        self.files = []

    def call(self, *args, env=None, code=0):
        """Return raw front stdout; callers decode JSON before field access."""
        # A deliberately surviving child may retain inherited output FDs.
        # Wait on the front's exit, not communicate()'s descendant-pipe EOF.
        with tempfile.TemporaryFile(dir=self.root) as out, tempfile.TemporaryFile(dir=self.root) as err:
            p = subprocess.run(['bash', str(ROOT / 'bin/fm-owner-notice.sh'), *args],
                               env=env or self.env, stdout=out, stderr=err, timeout=40)
            out.seek(0); err.seek(0)
            stdout, stderr = out.read().decode(), err.read().decode()
        assert p.returncode == code, (args, p.returncode, stdout, stderr)
        return stdout

    def bind(self, bid, outbox=None):
        outbox = outbox or self.root / ('outbox-' + bid)
        outbox.mkdir(parents=True)
        self.call('bind', bid, '--outbox', str(outbox), '--producer-actor', 'process:fixture-' + bid,
                  '--producer-uid', str(os.getuid()), '--kinds', 'note', '--max-bytes', '1000',
                  '--consume-bound-seconds', '3600')
        return outbox

    def envelope(self, bid, key):
        binding = (self.own / 'bindings' / (bid + '.json')).read_bytes()
        obj = json.loads(binding)
        data = fmt.envelope(bid, hashlib.sha256(binding).hexdigest(), key, 'note', key.encode())
        target = Path(obj['outbox']) / (key + '.envelope.json')
        target.write_bytes(data)
        return target

    def start(self, extra='', shim=False):
        env = dict(self.env)
        if extra:
            env['FM_OWNER_NOTICE_FAULT'] += ',' + extra
        if shim:
            env.update(self.shim_env())
        fh = open(self.root / ('watch-%d.log' % len(self.processes)), 'w')
        self.files.append(fh)
        self.watch = subprocess.Popen(['bash', str(ROOT / 'tests/lib/owner-notice-watcher.sh'), str(self.script_dir)],
                                      env=env, stdout=fh, stderr=fh, start_new_session=True)
        self.processes.append(self.watch)
        def started():
            try:
                return ((self.state / '.watch.lock/pid').read_text().strip() == str(self.watch.pid)
                        and (self.state / '.watch.lock/pid-identity').is_file()
                        and (self.state / '.last-watcher-beat').exists())
            except FileNotFoundError:
                return False
        wait('watcher owns lock and beats', started)
        return self.watch

    def alarm_command(self, verb, action='', key='', reason='fixture transition', *, wait_for_acceptance=True, code=0):
        token = str(time.monotonic_ns())
        path = self.state / '.fixture-command'
        temp = self.state / '.fixture-command.new'
        temp.write_text('%s %s %s %s %s\n' % (token, verb, action, key, reason))
        temp.replace(path)
        if wait_for_acceptance:
            self.alarm_finish(token, code)
        return token

    def alarm_finish(self, token, code=0):
        wait('fixture alarm command finished', lambda: (self.state / ('.fixture-command.' + token + '.done')).exists())
        actual = (self.state / ('.fixture-command.' + token + '.code')).read_text().strip()
        assert actual == str(code), (token, actual, code)

    def alarm_rows(self):
        import sqlite3
        from urllib.parse import quote
        path = self.own / '.runner-alarms.sqlite3'
        if not path.exists():
            return []
        db = sqlite3.connect('file:' + quote(str(path), safe='/') + '?mode=ro', uri=True, timeout=1)
        try:
            return db.execute('SELECT seq,key,action FROM requests ORDER BY seq').fetchall()
        finally:
            db.close()

    def publication_result(self):
        import fcntl
        path = self.own / '.runner-alarm-publication/result'
        if not path.exists() or path.stat().st_nlink != 1:
            return None
        with open(self.own / '.runner-alarm-publisher.lock', 'rb') as fh:
            try:
                fcntl.flock(fh, fcntl.LOCK_SH | fcntl.LOCK_NB)
                return record(path)
            except BlockingIOError:
                return None

    def alert_calls(self):
        return (self.home / 'alert-calls').read_text().splitlines()

    def hold_alarm(self, action, key):
        os.mkfifo(self.root / 'alarm-hold')
        self.env['FM_TEST_ALARM_HOLD'] = action + ':' + key

    def spy_alerts(self):
        self.script_dir = self.root / 'scripts'
        self.script_dir.mkdir()
        for path in (ROOT / 'bin').iterdir():
            if path.is_file() and path.name != 'fm-alert-store.sh':
                (self.script_dir / path.name).symlink_to(path)
        wrapper = self.script_dir / 'fm-alert-store.sh'
        wrapper.write_text('#!/usr/bin/env bash\nprintf "%s\\n" "$*" >> "$HOME/alert-calls"\n'
                           'if [ "${1:-}:${4:-}" = "${FM_TEST_ALARM_HOLD:-disabled}" ] && mkdir "$FM_OWNER_NOTICE_TEST_ROOT/alarm-held-once" 2>/dev/null; then\n'
                           '  printf "%s\\n" "$$" > "$FM_OWNER_NOTICE_TEST_ROOT/alarm-writer-pid"\n'
                           '  : > "$FM_OWNER_NOTICE_TEST_ROOT/alarm-hold.reached"\n  IFS= read -r _ < "$FM_OWNER_NOTICE_TEST_ROOT/alarm-hold" || true\nfi\n'
                           'if [ -f "$FM_OWNER_NOTICE_TEST_ROOT/alarm-fail" ] && [ "${1:-}" = assert ]; then exit 70; fi\n'
                           'exec bash "$REAL_ALERT_STORE" "$@"\n')
        wrapper.chmod(0o755)
        self.env['REAL_ALERT_STORE'] = str(ROOT / 'bin/fm-alert-store.sh')

    def alert(self, command, key, *args):
        p = subprocess.run(['bash', str(ROOT / 'bin/fm-alert-store.sh'), command,
                            str(self.own / 'runner-alert-store.json'), 'owner-notice-runner', key, *args],
                           env=self.env, capture_output=True, timeout=20, text=True)
        assert p.returncode == 0, p.stderr

    def shim_env(self):
        return dict(LD_PRELOAD=str(BASE / 'stat-block.so'), BLOCK_PREFIX=str(self.root / 'outbox-x'),
                    BLOCK_HITS=str(self.root / 'hits'), BLOCK_FIFO=str(self.root / 'block'),
                    BLOCK_DISABLE=str(self.root / 'disable'))

    def block(self):
        os.mkfifo(self.root / 'block')

    def release(self, name='block'):
        # Opening a FIFO can block; keep the writer separately bounded.
        p = subprocess.run(['bash', '-c', ': > "$1"', '_', str(self.root / name)], timeout=10)
        assert p.returncode == 0

    def delivered(self, bid, key):
        path = self.own / bid / 'receipts' / key / '1.json'
        return wait('delivery ' + bid + '/' + key, lambda: record(path))

    def children(self, bid):
        path = self.own / bid / '.children'
        try:
            return {p[0]: dict(pid=int(p[1]), starttime=p[2], pgid=int(p[3]), started_at=int(p[4]), run=p[5])
                    for p in (x.split() for x in path.read_text().splitlines())}
        except FileNotFoundError:
            return {}

    def child(self, bid, role):
        return wait('child ' + bid + '/' + role, lambda: self.children(bid).get(role))

    def stall(self, bid, role):
        try:
            return next((x.split() for x in (self.own / bid / '.stall').read_text().splitlines()
                         if x.startswith(role + ' ')), None)
        except FileNotFoundError:
            return None

    def level(self, kind, bid='x', runner=False):
        obj = record(self.own / ('runner-alert-store.json' if runner else 'alert-store.json')) or {}
        return next((a for a in obj.get('active', {}).values()
                     if a.get('key') == kind or (a.get('kind') == kind and a.get('subject') == bid)), None)

    def runner(self):
        return wait('runner record', lambda: fields(self.own / '.runner'))

    def loop(self, runner=None):
        r = runner or self.runner()
        front = int(r['pid'])
        def find():
            if not fmt.identity_alive(front, r['starttime']):
                return None
            try:
                children = Path('/proc/%s/task/%s/children' % (front, front)).read_text().split()
            except FileNotFoundError:
                return None
            for child in children:
                try:
                    pid = int(child)
                    args = Path('/proc/%s/cmdline' % pid).read_bytes().split(b'\0')
                    status = dict(line.split(':', 1) for line in Path('/proc/%s/status' % pid).read_text().splitlines())
                    if b'runner-loop' in args and str(self.home).encode() in args and int(status['PPid']) == front:
                        return pid
                except (FileNotFoundError, ProcessLookupError):
                    pass  # A short-lived sibling is not the loop.
            return None
        return wait('owned loop identity', find)

    def cycle(self):
        try:
            lines = (self.state / '.last-watcher-beat').read_text().splitlines()
        except FileNotFoundError:
            return 0  # The first publication is not observable yet.
        return int(lines[0]) if lines and lines[0].isdigit() else 0

    def advance(self, n=3):
        before = wait('nonpartial beat', self.cycle)
        wait('watcher advanced', lambda: self.cycle() >= before + n)

    def sweeps(self, count=3):
        marker = self.state / '.last-check'
        for _ in range(count):
            before = marker.stat().st_mtime_ns if marker.exists() else 0
            wait('next completed slow sweep', lambda: marker.exists() and marker.stat().st_mtime_ns > before)

    def wake_sources(self, kind):
        # Native alert-store tick publishes the durable wake-facing blocker.
        # Also include the direct check queue used when publication fails.
        lines = []
        for name in ('owner-notice.status', 'owner-notice-runner.status', '.wake-queue'):
            path = self.state / name
            if path.exists():
                lines += [line for line in path.read_text().splitlines()
                          if kind in line and ('blocked ' in line or name == '.wake-queue')]
        return lines

    def wait_wake(self, kind):
        return wait('wake-facing occurrence ' + kind, lambda: self.wake_sources(kind))

    def log(self, bid='x'):
        try:
            return (self.own / bid / 'log').read_text()
        except FileNotFoundError:
            return ''

    def remember_publishers(self):
        for p in self.processes:
            if p.poll() is not None:
                continue
            path = Path('/proc/%s/task/%s/children' % (p.pid, p.pid))
            if not path.exists():
                continue
            for child in path.read_text().split():
                pid = int(child)
                try:
                    if b'fm_owner_notice_alarm.py' in Path('/proc/%s/cmdline' % pid).read_bytes():
                        self.publishers = getattr(self, 'publishers', []) + [(pid, fmt.pid_starttime(pid), os.getpgid(pid))]
                except (FileNotFoundError, ProcessLookupError):
                    pass

    def stop_watch(self):
        if self.watch and self.watch.poll() is None:
            self.remember_publishers()
            self.watch.terminate()
            self.watch.wait(timeout=10)
        self.watch = None

    def close(self):
        # Record first, signal owned identities only. Never a pattern kill.
        self.remember_publishers()
        records = list(getattr(self, 'publishers', []))
        if self.own.exists():
            for path in [self.own / '.children'] + list(self.own.glob('*/.children')):
                if path.is_file():
                    for row in path.read_text().splitlines():
                        p = row.split()
                        try:
                            records.append((int(p[1]), p[2], int(p[3])))
                        except (ValueError, IndexError):
                            pass  # Corrupt fixture input grants no signal authority.
            for path in (self.own / '.fg-children').glob('*'):
                try:
                    r = record(path)
                    records.append((r['pid'], r['starttime'], r['pgid']))
                except (ValueError, KeyError, TypeError):
                    pass
        for pid, start, pgid in records:
            if fmt.identity_alive(pid, start):
                try:
                    os.killpg(pgid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
        runner = fields(self.own / '.runner')
        for p in self.processes:
            held = p.poll() is None
            if runner and fmt.identity_alive(int(runner['pid']), runner['starttime']):
                try:
                    held = held or os.getpgid(int(runner['pid'])) == p.pid
                except ProcessLookupError:
                    pass
            if held:
                try:
                    os.killpg(p.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
            p.wait(timeout=10)
        for fh in self.files:
            fh.close()


def idle(w):
    w.bind('x'); w.envelope('x', 'one')
    w.start()
    r = w.delivered('x', 'one')
    assert r['payload_sha256'] == hashlib.sha256(b'one').hexdigest()
    wait('binding beat', lambda: fields(w.own / 'x/.beat'))
    assert fields(w.own / 'x/.beat')['writer'] == 'runner'
    assert (w.state / 'alert-stores/owner-notice.reg').exists()
    assert (w.state / 'alert-stores/owner-notice-runner.reg').exists()
    wait('delivered key announced', lambda: (w.own / 'x/.announced/one').exists())
    w.call('consume', 'x', 'one')


def handrun(w):
    w.bind('x')
    p = subprocess.run(['bash', str(ROOT / 'bin/fm-owner-notice.sh'), 'run', '--watcher-pid', str(os.getpid()),
                        '--attempt', '0'*32], env=w.env, capture_output=True, text=True, timeout=10)
    assert p.returncode == 70 and 'not-watcher-child' in p.stdout
    assert not (w.own / 'x/.beat').exists()
    for option in ('--watcher-pid', '--attempt'):
        p = subprocess.run(['bash', str(ROOT / 'bin/fm-owner-notice.sh'), 'run', option],
                           env=w.env, capture_output=True, text=True, timeout=3)
        assert p.returncode == 2, (option, p.returncode, p.stderr)


def stat_stall(w):
    w.bind('x'); w.bind('y'); w.block(); w.envelope('y', 'one')
    w.start('unkillable:stat', shim=True)
    r = w.child('x', 'stat')
    w.delivered('y', 'one')
    assert time.time() <= r['started_at'] + 7
    wait('stat stall', lambda: w.stall('x', 'stat'))
    wait('outbox level', lambda: w.level('outbox-stalled'))
    assert fmt.identity_alive(r['pid'], r['starttime'])
    w.advance(10)
    assert w.children('x')['stat']['pid'] == r['pid']
    assert not (w.own / 'x/.beat').exists()


def stage_stall(w):
    w.bind('x'); w.bind('y'); w.envelope('y', 'one')
    # Block opens only: X's stat completes, its stage blocks, Y stays healthy.
    w.block()
    w.env['BLOCK_CALLS'] = 'open,open64,openat,openat64,opendir'
    w.start('stage-bound=3' + ('' if CASE.endswith('signal') else ',unkillable:stage'), shim=True)
    r = w.child('x', 'stage')
    w.delivered('y', 'one')
    if CASE.endswith('signal'):
        wait('signalable stage ends at TERM', lambda: not fmt.identity_alive(r['pid'], r['starttime']), cap=4)
        assert not w.stall('x', 'stage') and not w.level('ingest-stalled')
        return
    wait('stage stall', lambda: w.stall('x', 'stage'))
    assert int(w.stall('x', 'stage')[1]) == r['started_at']
    wait('ingest-stalled level', lambda: w.level('ingest-stalled'))
    w.advance(10)
    assert w.children('x')['stage']['pid'] == r['pid']
    assert fmt.identity_alive(r['pid'], r['starttime'])


def adoption(w):
    w.bind('x'); w.bind('y'); w.block()
    w.start('unkillable:stat,stat-bound=3', shim=True)
    original = w.child('x', 'stat')
    wait('stat stall', lambda: w.stall('x', 'stat'))
    first = int(w.stall('x', 'stat')[1])
    wait('outbox level', lambda: w.level('outbox-stalled'))
    for i in range(3):
        front = int(w.runner()['pid'])
        os.kill(front, signal.SIGTERM)
        wait('new runner', lambda: fields(w.own / '.runner').get('pid') not in (None, str(front)), cap=60)
        wait('adoption log', lambda: w.log().count('adopted stat') >= i + 1)
        assert fmt.identity_alive(original['pid'], original['starttime'])
        assert w.children('x')['stat']['pid'] == original['pid']
        assert int(w.stall('x', 'stat')[1]) == first
        w.envelope('y', 'n' + str(i)); w.delivered('y', 'n' + str(i))
    assert w.log().count('stall stat since=') == 1
    assert 'stall-clear stat' not in w.log()


def watcher_loss(w):
    w.bind('x'); w.start()
    front = w.runner()
    w.stop_watch()
    wait('front stopped with watcher', lambda: not fmt.identity_alive(int(front['pid']), front['starttime']), cap=10)
    assert not (w.own / '.runner.lock').exists()


def foreground(w):
    w.bind('x'); w.bind('y'); w.block()
    env = dict(w.env, **w.shim_env())
    env['FM_OWNER_NOTICE_FAULT'] += ',outbox-io-bound=2,unkillable:stage'
    out = w.call('ingest', 'x', env=env, code=75)
    assert 'outbox-unresponsive' in out
    r = next(record(p) for p in (w.own / '.fg-children').glob('*'))
    assert fmt.identity_alive(r['pid'], r['starttime'])
    hits = (w.root / 'hits').read_text().splitlines()
    assert len(hits) == 1
    w.envelope('y', 'one'); w.start(shim=True)
    w.delivered('y', 'one')
    wait('foreground stall', lambda: w.stall('x', 'fg'), cap=30)
    wait('foreground alarm', lambda: w.level('outbox-stalled'))
    w.advance(15)
    assert len((w.root / 'hits').read_text().splitlines()) == 1
    assert fmt.identity_alive(r['pid'], r['starttime'])


def flapping(w):
    w.bind('x'); w.block(); w.start(shim=True)
    first = w.child('x', 'stat')
    wait('stat stall', lambda: w.stall('x', 'stat'))
    since = w.stall('x', 'stat')[1]
    wait('five workers', lambda: len((w.root / 'hits').read_text().splitlines()) >= 5)
    assert not fmt.identity_alive(first['pid'], first['starttime'])
    assert w.stall('x', 'stat')[1] == since
    assert w.log().count('stall stat since=') == 1
    assert 'stall-clear stat' not in w.log()
    (w.root / 'disable').touch()
    wait('successful replacement stat', lambda: (w.own / 'x/.beat').exists())
    wait('stall cleared', lambda: not w.stall('x', 'stat'))
    wait('level cleared', lambda: not w.level('outbox-stalled'))
    assert w.log().count('stall-clear stat') == 1


def exit_children(w):
    w.bind('x'); w.block()
    extra = 'stat-bound=30,no-pdeathsig:stat'
    if CASE.endswith('kill'):
        extra += ',child-ignore-term:stat'
    w.start(extra, shim=True)
    r = w.child('x', 'stat')
    wait('stat entered shim', lambda: (w.root / 'hits').exists())
    front = w.runner()
    # Freeze the fixture watcher so no replacement obscures this exit.
    os.kill(w.watch.pid, signal.SIGSTOP)
    at = time.monotonic()
    os.kill(int(front['pid']), signal.SIGTERM)
    if CASE.endswith('kill'):
        wait('TERM-only observation', lambda: time.monotonic() >= at + 1)
        assert fmt.identity_alive(r['pid'], r['starttime'])
    wait('exit path removed child and record', lambda: not fmt.identity_alive(r['pid'], r['starttime'])
         and 'stat' not in w.children('x'), cap=max(.01, at + 3 - time.monotonic()))


def foreground_survival(w):
    w.bind('x'); w.block()
    origin = CASE.split('_')[-1]
    role = 'stat' if origin == 'bind' else 'stage'
    env = dict(w.env, **w.shim_env())
    env['FM_OWNER_NOTICE_FAULT'] += ',outbox-io-bound=30'
    if not CASE.startswith('pdeath'):
        env['FM_OWNER_NOTICE_FAULT'] += ',no-pdeathsig:' + role
    elif origin == 'bind':
        env['FM_OWNER_NOTICE_FAULT'] += ',no-pdeathsig:stage'  # role-mismatch control
    if origin == 'bind':
        args = ['bind', 'x', '--outbox', str(w.root / 'outbox-x'), '--producer-actor', 'process:fixture-x',
                '--producer-uid', str(os.getuid()), '--kinds', 'note', '--max-bytes', '1000', '--consume-bound-seconds', '3600']
    else:
        args = [origin, 'x']
    fh = open(w.root / 'foreground.log', 'w'); w.files.append(fh)
    p = subprocess.Popen(['bash', str(ROOT / 'bin/fm-owner-notice.sh'), *args], env=env,
                         stdout=fh, stderr=fh, start_new_session=True)
    w.processes.append(p)
    r = wait('foreground child record', lambda: next((record(f) for f in (w.own / '.fg-children').glob('*')), None))
    wait('foreground syscall', lambda: (w.root / 'hits').exists())
    p.kill(); p.wait(timeout=5)
    if CASE.startswith('pdeath'):
        wait('parent-death signal', lambda: not fmt.identity_alive(r['pid'], r['starttime']), cap=2)
        w.start()
        wait('dead foreground record reconciled', lambda: not list((w.own / '.fg-children').glob('*')))
    else:
        at = time.monotonic()
        wait('separated survival observation', lambda: time.monotonic() >= at + 2)
        assert fmt.identity_alive(r['pid'], r['starttime'])
        assert list((w.own / '.fg-children').glob('*'))


def foreground_recovery(w):
    w.bind('x'); w.block()
    env = dict(w.env, **w.shim_env())
    env['FM_OWNER_NOTICE_FAULT'] += ',outbox-io-bound=30,no-pdeathsig:stage'
    fh = open(w.root / 'foreground.log', 'w'); w.files.append(fh)
    p = subprocess.Popen(['bash', str(ROOT / 'bin/fm-owner-notice.sh'), 'ingest', 'x'], env=env,
                         stdout=fh, stderr=fh, start_new_session=True)
    w.processes.append(p)
    r = wait('fg record', lambda: next((record(f) for f in (w.own / '.fg-children').glob('*')), None))
    wait('fg entered shim', lambda: (w.root / 'hits').exists())
    p.kill(); p.wait(timeout=5)
    w.start('outbox-io-bound=2', shim=True)
    wait('fg stall', lambda: w.stall('x', 'fg'))
    original_since = w.stall('x', 'fg')[1]
    w.release()
    wait('original foreground identity gone', lambda: not fmt.identity_alive(r['pid'], r['starttime']))
    wait('new stat stalls', lambda: w.stall('x', 'stat'))
    assert w.stall('x', 'fg')[1] == original_since
    assert 'stall-clear fg' not in w.log()
    (w.root / 'disable').touch()
    wait('successful stat clears both', lambda: not w.stall('x', 'fg') and not w.stall('x', 'stat'))
    assert w.log().count('stall-clear fg') == 1


def deadline(w):
    role = 'ingest' if 'ingest' in CASE else 'stage'
    signalable = CASE.endswith('signal')
    w.bind('x'); w.envelope('x', 'one')
    os.mkfifo(w.root / 'pause')
    point = 'ingest:after-receipt' if role == 'ingest' else 'stage:after-listing'
    extra = '%s:pause=%s,%s-bound=3' % (point, w.root / 'pause', role)
    extra += (',no-pdeathsig:%s,child-ignore-term:%s' % (role, role)) if signalable else ',unkillable:' + role
    w.start(extra)
    wait('child reached pause', lambda: (w.root / 'pause.reached').exists())
    original = w.child('x', role)
    wait('restart barrier lower bound', lambda: time.time() >= original['started_at'] + 1)
    os.kill(w.watch.pid, signal.SIGSTOP)
    front = int(w.runner()['pid'])
    loop = w.loop()
    os.kill(front, signal.SIGKILL)
    try:
        os.kill(loop, signal.SIGKILL)
    except ProcessLookupError:
        pass  # The front's parent-death chain may already have killed it.
    assert fmt.identity_alive(original['pid'], original['starttime'])
    wait('restart release time', lambda: time.time() >= original['started_at'] + 3)
    os.kill(w.watch.pid, signal.SIGCONT)
    wait('observable adoption', lambda: 'adopted ' + role in w.log())
    adopted = next(line for line in w.log().splitlines() if 'adopted ' + role in line)
    adoption_time = fmt.parse_iso(adopted.split()[0])
    assert adoption_time >= original['started_at'] + 3
    wait('separated deadline observation', lambda: time.time() >= adoption_time + 4)
    assert 'term %s pid=%s' % (role, original['pid']) in w.log()
    if signalable:
        assert not fmt.identity_alive(original['pid'], original['starttime'])
        lines = [line for line in w.log().splitlines() if 'kill %s pid=%s' % (role, original['pid']) in line]
        assert lines and original['started_at'] + 5 <= fmt.parse_iso(lines[0].split()[0]) < adoption_time + 5
        # SIGKILL is asynchronous: a transient stall at signal time is allowed.
    else:
        assert fmt.identity_alive(original['pid'], original['starttime'])
        row = w.stall('x', role)
        assert row and int(row[1]) == original['started_at']
        line = next(line for line in w.log().splitlines() if 'stall %s since=' % role in line)
        assert original['started_at'] + 5 <= fmt.parse_iso(line.split()[0]) < adoption_time + 5
        wait('persisted role level', lambda: w.level('ingest-stalled'))
        assert fmt.parse_iso(w.level('ingest-stalled')['since']) == original['started_at']
        assert w.children('x')[role]['pid'] == original['pid']


def backoff(w):
    w.env['FM_CHECK_INTERVAL'] = '30'
    w.bind('x'); w.start('run:exit=70')
    path = w.own / '.runner-respawns'
    wait('first failed start', lambda: path.exists())
    first = path.stat().st_mtime
    wait('second failed start', lambda: int(path.read_text().split()[0]) >= 2)
    second = path.stat().st_mtime
    assert second - first >= 1.9
    wait('third failed start', lambda: (w.own / '.runner-respawns').exists()
         and int((w.own / '.runner-respawns').read_text().split()[0]) >= 3)
    assert path.stat().st_mtime - second >= 3.9
    wait('respawn failure level', lambda: w.level('runner-respawn-failing', runner=True))
    r = (w.own / '.runner-respawns').read_text().split()
    assert int(r[0]) <= 4
    previous = int(r[0]); w.stop_watch(); w.start('run:exit=70')
    wait('count survives watcher restart', lambda: int((w.own / '.runner-respawns').read_text().split()[0]) > previous)
    w.stop_watch(); w.env['FM_CHECK_INTERVAL'] = '2'; w.start()
    wait('healthy progress clears failures without exiting', lambda: not w.level('runner-respawn-failing', runner=True))
    assert int((w.own / '.runner-respawns').read_text().split()[0]) == 0
    current = w.runner()
    assert fmt.identity_alive(int(current['pid']), current['starttime'])


def slow_sweep(w):
    outbox = w.bind('x'); w.start('full-sweep=5')
    wait('seen', lambda: (w.own / 'x/.seen').exists())
    old = int((w.own / 'x/.seen').read_text())
    w.envelope('x', 'late')
    os.utime(outbox, ns=(old, old))
    w.delivered('x', 'late')


def cap(w):
    outbox = w.bind('x')
    old = time.time_ns() - 60 * 10**9
    # Lexical listing order differs from chronological order on purpose.
    for i in range(300):
        path = w.envelope('x', 'k%03d' % i)
        stamp = old + (299-i) * 10**6
        os.utime(path, ns=(stamp, stamp))
    w.call('ingest', 'x')
    current = {p.stem for p in (w.own / 'x/current').glob('*.json')}
    assert len(current) == 256
    assert current == {'k%03d' % i for i in range(44, 300)}
    w.start(); w.delivered('x', 'k000')
    wait('all cap entries', lambda: len(list((w.own / 'x/current').glob('*.json'))) == 300)


def racy(w):
    w.bind('x'); w.envelope('x', 'one')
    stamp = time.time_ns() + 60 * 10**9
    os.utime(w.root / 'outbox-x', ns=(stamp, stamp))
    os.mkfifo(w.root / 'stage')
    w.start('stage:after-listing:pause=' + str(w.root / 'stage') + ',full-sweep=3600')
    first = w.child('x', 'stage')
    manifest_path = w.own / 'x/.tmp' / first['run'] / 'manifest.json'
    wait('stage pause reached', lambda: (w.root / 'stage.reached').exists())
    m = record(manifest_path)
    w.envelope('x', 'two')
    # Force a coarse-clock equality that is still in the listing's slack.
    os.utime(w.root / 'outbox-x', ns=(m['mtime_ns'], m['mtime_ns']))
    w.release('stage'); w.delivered('x', 'one')
    wait('second stage', lambda: w.children('x').get('stage', {}).get('pid') not in (None, first['pid']))
    w.release('stage'); w.delivered('x', 'two')


def all_ingests_stalled(w):
    for bid in ('x', 'y'):
        w.bind(bid); w.envelope(bid, 'one')
    os.mkfifo(w.root / 'ingest')
    w.start('ingest:after-receipt:pause=' + str(w.root / 'ingest') + ',unkillable:ingest,ingest-bound=3')
    wait('both ingests paused', lambda: (w.root / 'ingest.reached').exists()
         and len((w.root / 'ingest.reached').read_text().splitlines()) >= 2)
    originals = {bid: w.child(bid, 'ingest') for bid in ('x', 'y')}
    for bid in ('x', 'y'):
        wait(bid + ' ingest stalled', lambda bid=bid: w.stall(bid, 'ingest'))
    for bid, original in originals.items():
        assert fmt.identity_alive(original['pid'], original['starttime'])
        wait(bid + ' alarm despite no free binding slot', lambda bid=bid: w.level('ingest-stalled', bid))
        assert w.children(bid)['ingest']['pid'] == original['pid']


def projection_restart(w):
    w.bind('x'); os.mkfifo(w.root / 'projection')
    w.start('alarms:after-snapshot:pause=' + str(w.root / 'projection') + ',unkillable:ingest,ingest-bound=3')
    wait('projection reached snapshot', lambda: (w.root / 'projection.reached').exists())
    original = w.child('', 'ingest')
    wait('root projector stall', lambda: w.stall('', 'ingest'))
    # The root reader must notice this independently of recent loop beats.
    assert time.time() - int(fields(w.own / '.runner-beat')['epoch']) < 5
    wait('projector failure reaches watcher store', lambda: w.level('runner-beat-stale', runner=True))
    # Automatic watcher recovery or an explicit front restart must adopt, not
    # launch a second projector. The stand-in's exact identity is the control.
    front = w.runner()['pid']
    if fmt.identity_alive(int(front), w.runner()['starttime']):
        os.kill(int(front), signal.SIGTERM)
    wait('new front after projection failure', lambda: fields(w.own / '.runner').get('pid') not in (None, front))
    wait('projector adopted', lambda: 'adopted ingest pid=' + str(original['pid']) in w.log(''))
    assert fmt.identity_alive(original['pid'], original['starttime'])
    assert w.children('')['ingest']['pid'] == original['pid']
    w.stop_watch(); w.start()
    wait('replacement projection clears root stall', lambda: not w.stall('', 'ingest'))
    wait('watcher level clears on recovery', lambda: not w.level('runner-beat-stale', runner=True))


def role_recovery(w):
    role = 'stage' if CASE == 'stage_recovery' else 'ingest'
    w.bind('x'); w.envelope('x', 'one')
    os.mkfifo(w.root / 'stage'); os.mkfifo(w.root / 'ingest')
    extra = 'ingest:after-receipt:pause=' + str(w.root / 'ingest')
    if role == 'stage':
        extra += ',stage:after-listing:pause=' + str(w.root / 'stage') + ',unkillable:stage,stage-bound=3'
    else:
        extra += ',unkillable:ingest,ingest-bound=3'
    w.start(extra)
    wait('role stall', lambda: w.stall('x', role))
    wait('role level', lambda: w.level('ingest-stalled'))
    if role == 'stage':
        old = w.children('x')['stage']
        w.release('stage')
        wait('stage identity gone', lambda: not fmt.identity_alive(old['pid'], old['starttime']))
        wait('following ingest paused', lambda: (w.root / 'ingest.reached').exists())
        assert w.stall('x', 'stage')
        assert 'stall-clear stage' not in w.log()
        w.release('ingest')
    else:
        old = w.children('x')['ingest']
        os.killpg(old['pgid'], signal.SIGKILL)
        wait('ingest identity gone', lambda: not fmt.identity_alive(old['pid'], old['starttime']))
        assert w.stall('x', 'ingest')
        assert 'stall-clear ingest' not in w.log()
        # Disable the pause for recovery, not merely its signal suppression.
        w.stop_watch(); w.start()
        w.envelope('x', 'two')
    wait('role clears after successful ingest', lambda: not w.stall('x', role))
    assert w.log().count('stall-clear ' + role) == 1
    clear = w.log().index('stall-clear ' + role)
    assert 'exit ingest' in w.log()[:clear] and 'code=0' in w.log()[:clear]


def singleton(w):
    w.bind('x'); w.start('runner-lock-wait=2')
    wait('first runner beats', lambda: fields(w.own / '.runner-beat'))
    original = w.runner()
    (w.state / 'second-run').touch()
    wait('second front exits', lambda: (w.state / 'second-exit').exists(), cap=8)
    assert (w.state / 'second-exit').read_text().strip() == '75'
    assert w.runner()['pid'] == original['pid']
    assert fmt.identity_alive(int(original['pid']), original['starttime'])


def in_flight(w):
    outbox = w.bind('x')
    stamp = time.time_ns() + 60 * 10**9
    os.utime(outbox, ns=(stamp, stamp))
    gate = w.root / 'listed'; os.mkfifo(gate)
    keeper = os.open(gate, os.O_RDWR | os.O_NONBLOCK)
    try:
        w.start('runner-loop-seconds=5,stage:after-listing:pause=' + str(gate))
        stage = w.child('x', 'stage')
        manifest = w.own / 'x/.tmp' / stage['run'] / 'manifest.json'
        wait('in-flight listing completed', lambda: record(manifest) and record(manifest)['names'] is not None)
        def reader_open():
            try:
                return any(os.readlink(p) == str(gate) for p in Path('/proc/%s/fd' % stage['pid']).iterdir())
            except FileNotFoundError:
                return False
        wait('listed stage really holds barrier', reader_open)
        at = time.monotonic(); w.envelope('x', 'late')
        assert not (w.own / 'x/current/late.json').exists()
        # Release only this stage; later stage passes use an empty regular
        # file instead of adding artificial whole-second sleeps to the bound.
        gate.unlink(); gate.write_bytes(b''); os.close(keeper); keeper = None
        w.delivered('x', 'late')
        assert time.monotonic() - at <= 4
        assert not fmt.identity_alive(stage['pid'], stage['starttime'])
    finally:
        if keeper is not None: os.close(keeper)


def handover(w):
    w.bind('x')
    # Include the documented two-second front/check cleanup margin, making
    # the old front's worst-case lifetime distinguish 20 from 30 seconds.
    w.start('runner-loop-seconds=15,run:check-delay=17,runner-loop:ignore-term')
    wait('old front progress', lambda: fields(w.own / '.runner-beat'))
    old = w.runner(); w.stop_watch()
    w.start('runner-loop-seconds=15,runner-loop:ignore-term')
    attempt = wait('successor reserved', lambda: (lambda r: r if r.get('token') != old['attempt'] else None)(
        fields(w.own / '.runner-attempt')))
    reserved_at = time.monotonic()
    w.envelope('x', 'handover')
    w.delivered('x', 'handover')  # The still-authorized old front may deliver it.
    wait('reserved successor installed', lambda: fields(w.own / '.runner').get('attempt') == attempt['token'],
         cap=max(.1, 30 - (time.monotonic() - reserved_at)))
    assert w.runner()['attempt'] == attempt['token']
    assert fields(w.own / '.runner-attempt')['token'] == attempt['token']
    assert not fmt.identity_alive(int(old['pid']), old['starttime'])
    assert not (w.own / '.runner-respawns').exists()


def busy(w):
    w.bind('x'); w.envelope('x', 'seed'); w.call('ingest', 'x')
    w.start('full-sweep=3600')
    wait('warm settled runner', lambda: (w.own / 'x/.seen').exists())
    os.mkfifo(w.root / 'consume')
    env = dict(w.env, FM_OWNER_NOTICE_FAULT='consume:after-link:pause=' + str(w.root / 'consume'))
    fh = open(w.root / 'consume.log', 'w'); w.files.append(fh)
    consumer = subprocess.Popen(['bash', str(ROOT / 'bin/fm-owner-notice.sh'), 'consume', 'x', 'seed'],
                                env=env, stdout=fh, stderr=fh, start_new_session=True)
    w.processes.append(consumer)
    wait('consume holds lock', lambda: (w.root / 'consume.reached').exists())
    w.envelope('x', 'busy')
    wait('three busy retries', lambda: w.level('ingest-busy'))
    before = w.log().count('spawn stage')
    assert 'ingest-staged busy count=3' in w.log()
    at = time.monotonic(); w.release('consume'); w.delivered('x', 'busy')
    assert time.monotonic() - at <= 2
    assert w.log().count('spawn stage') == before
    assert consumer.wait(timeout=10) == 0
    wait('busy clears', lambda: not w.level('ingest-busy'))


def start_announce(w):
    w.bind('x'); w.envelope('x', 'old'); w.call('ingest', 'x')
    (w.own / 'x/.announced/old').unlink()
    old = time.time() - 600
    for p in (w.own / 'x/receipts/old').glob('*'):
        obj = record(p); obj['recorded_at'] = fmt.utc_iso(old)
        p.write_bytes(fmt.canonical(obj)); os.utime(p, (old, old))
    current = w.own / 'x/current/old.json'
    obj = record(current); obj['final_at'] = obj['delivered_at'] = fmt.utc_iso(old)
    current.write_bytes(fmt.canonical(obj))
    w.start()
    wait('old receipt announced at start', lambda: (w.own / 'x/.announced/old').exists())
    wait('start sync observed', lambda: 'start-sync' in w.log(''))
    status = (w.state / 'owner-notice.status').read_text()
    assert 'unannounced:old' not in status


def stale_transition(w):
    w.bind('x'); w.spy_alerts(); os.mkfifo(w.root / 'loop')
    w.start('runner-loop:pause=' + str(w.root / 'loop'))
    wait('loop paused', lambda: (w.root / 'loop.reached').exists())
    original = w.runner()
    wait('stale raised', lambda: w.level('runner-beat-stale', runner=True))
    w.alert('ack', 'runner-beat-stale', '120', 'fixture', 'observe held transition')
    def asserts():
        return [line for line in w.alert_calls()
                if line.startswith('assert ') and ' runner-beat-stale ' in line]
    assert len(asserts()) == 1
    marker = (w.state / '.last-check').stat().st_mtime_ns
    for _ in range(2):
        marker = wait('next slow sweep', lambda: (lambda n: n if n > marker else 0)((w.state / '.last-check').stat().st_mtime_ns))
    assert len(asserts()) == 1
    wait('old stale runner stopped', lambda: not fmt.identity_alive(int(original['pid']), original['starttime']))
    w.stop_watch(); w.start()
    wait('healthy beat clears acknowledged level', lambda: not w.level('runner-beat-stale', runner=True))
    calls = w.alert_calls()
    assert len([s for s in calls if s.startswith('clear ') and ' runner-beat-stale ' in s]) == 1


def first_start(w):
    w.bind('x'); os.mkfifo(w.root / 'loop')
    if CASE == 'successor_grace':
        w.start(); wait('prior beat', lambda: fields(w.own / '.runner-beat'))
        old = w.runner(); w.stop_watch()
        wait('prior runner exits', lambda: not fmt.identity_alive(int(old['pid']), old['starttime']))
        path = w.own / '.runner-beat'; beat = fields(path); beat['epoch'] = str(int(time.time()) - 120)
        path.write_text(' '.join('%s=%s' % x for x in beat.items()) + '\n')
        os.utime(path, (time.time() - 120, time.time() - 120))
    for generation in range(5):
        start = time.time_ns()
        w.start('runner-loop:pause=' + str(w.root / 'loop'))
        wait('first sweep complete', lambda: (w.state / '.last-check').exists()
             and (w.state / '.last-check').stat().st_mtime_ns >= start)
        def starter():
            paths = [w.own / '.runner'] + list((w.own / '.runner-starting').glob('*'))
            return next((r for r in (fields(p) for p in paths)
                         if r.get('watcher_pid') == str(w.watch.pid)
                         and fmt.identity_alive(int(r['pid']), r['starttime'])), None)
        current = wait('this watcher live starter', starter)
        assert fmt.identity_alive(int(current['pid']), current['starttime'])
        if generation == 0:
            assert not w.level('runner-beat-stale', runner=True)
        else:
            wait('no renewed grace', lambda: w.level('runner-beat-stale', runner=True))
            assert fmt.identity_alive(int(current['pid']), current['starttime'])
        w.stop_watch()


def recovery_down(w):
    w.bind('x'); w.start(); wait('old beat', lambda: fields(w.own / '.runner-beat'))
    old = w.runner(); w.stop_watch()
    wait('old runner exits', lambda: not fmt.identity_alive(int(old['pid']), old['starttime']))
    w.alert('assert', 'runner-beat-stale', 'fixture stale occurrence')
    path = w.own / '.runner-beat'; beat = fields(path); beat['epoch'] = str(int(time.time()))
    path.write_text(' '.join('%s=%s' % x for x in beat.items()) + '\n')
    os.mkfifo(w.root / 'loop'); w.start('runner-loop:pause=' + str(w.root / 'loop'))
    wait('first sweep clears disk-held level', lambda: not w.level('runner-beat-stale', runner=True), cap=4)


def live_fast(w):
    w.bind('x'); os.mkfifo(w.root / 'loop')
    w.start('runner-loop:pause=' + str(w.root / 'loop') + ',runner-loop-seconds=15')
    wait('live paused runner', lambda: (w.root / 'loop.reached').exists())
    original = w.runner()
    for _ in range(10):
        at = time.monotonic(); w.advance(1)
        assert time.monotonic() - at <= 1.2
        assert fmt.identity_alive(int(original['pid']), original['starttime'])


def engine_death(w):
    w.bind('x'); w.envelope('x', 'one'); os.mkfifo(w.root / 'ingest')
    w.start('ingest:after-receipt:pause=' + str(w.root / 'ingest'))
    wait('engine is paused', lambda: (w.root / 'ingest.reached').exists())
    engine = int((w.root / 'ingest.reached').read_text().split()[1])
    start = fmt.pid_starttime(engine)
    front = w.children('x')['ingest']['pid']
    os.kill(front, signal.SIGKILL)
    wait('unrecorded engine dies with recorded front', lambda: not fmt.identity_alive(engine, start), cap=2)


def loop_death(w):
    w.bind('x'); w.start()
    wait('loop has beaten', lambda: fields(w.own / '.runner-beat'))
    runner = w.runner(); front = int(runner['pid'])
    loop = w.loop(runner)
    start = fmt.pid_starttime(loop)
    os.kill(w.watch.pid, signal.SIGSTOP)
    os.kill(front, signal.SIGKILL)
    wait('loop dies with front before lock can be reused', lambda: not fmt.identity_alive(loop, start), cap=2)


def real_watcher(w, empty=False):
    if empty:
        w.bind('x'); retire_old_and_purge(w); lifecycle_mark(w)
    else:
        parent = w.root / 'producer'
        w.bind('x', parent / 'outbox')
        hang = w.root / 'hang'; parent.rename(hang); parent.symlink_to(hang, target_is_directory=True)
        w.block()
    fake = w.root / 'fakebin'; fake.mkdir()
    tmux = fake / 'tmux'
    tmux.write_text('#!/usr/bin/env bash\ncase "$1" in list-windows|list-sessions|has-session) exit 0;; *) exit 1;; esac\n')
    tmux.chmod(0o755)
    (w.home / 'config/backend').write_text('tmux\n')
    (w.home / 'config/supervision-host-off').touch()
    env = dict(w.env)
    env.update(PATH=str(fake) + ':' + w.env['PATH'], FM_BACKEND='tmux', FM_POLL='1', FM_CHECK_INTERVAL='3',
               FM_WAKE_BATCH_SECS='0', FM_SIGNAL_GRACE='0', FM_WATCH_FOREGROUND_CHECKPOINT='1')
    if not empty:
        env.update(w.shim_env(), BLOCK_PREFIX=str(hang) + '/')
        env['FM_OWNER_NOTICE_FAULT'] += ',stat-bound=60,unkillable:stat'
    fh = open(w.root / 'real-watch.log', 'w'); w.files.append(fh)
    w.watch = subprocess.Popen(['bash', str(ROOT / 'bin/fm-watch.sh')], env=env,
                               stdout=fh, stderr=fh, start_new_session=True)
    w.processes.append(w.watch)
    if not empty:
        wait('real watcher producer worker blocked', lambda: (w.root / 'hits').exists())
    checks = set()
    for cycle in range(1, 11):
        wait('real watcher cycle %s' % cycle, lambda cycle=cycle: w.cycle() >= cycle)
        # Cycle-start precedes the first completed slow sweep.
        marker = w.state / '.last-check'
        if marker.exists():
            checks.add(marker.stat().st_mtime_ns)
        assert w.watch.poll() is None
    assert len(checks) >= 2
    before = w.cycle()
    (w.state / 'fixture.status').write_text('done [at=%s]: fixture completion\n' % int(time.time()))
    wait('real watcher delivers status', lambda: w.watch.poll() is not None, cap=5)
    assert w.cycle() <= before + 2
    output = (w.root / 'real-watch.log').read_text()
    assert 'fixture.status' in output, output
    if empty:
        assert not (w.own / '.runner-attempt').exists()
        assert 'runner-beat-stale' not in output, output
        return
    roles = w.children('x')
    allowed = {r['pid'] for role, r in roles.items() if role in ('stat', 'stage')}
    for hit in (w.root / 'hits').read_text().splitlines():
        assert int(hit.split()[0]) in allowed, hit


def foreground_bound(w):
    w.bind('x'); w.envelope('x', 'one'); w.call('ingest', 'x'); w.block()
    origin = CASE.split('_')[-1]
    env = dict(w.env, **w.shim_env()); env['FM_OWNER_NOTICE_FAULT'] += ',outbox-io-bound=2'
    args = [origin, 'x']
    if origin == 'bind':
        args += ['--outbox', str(w.root / 'outbox-x'), '--producer-actor', 'process:fixture-x',
                 '--producer-uid', str(os.getuid()), '--kinds', 'note', '--max-bytes', '1000',
                 '--consume-bound-seconds', '3600']
    at = time.monotonic()
    p = subprocess.run(['timeout', '--kill-after=1', '6', 'bash', str(ROOT / 'bin/fm-owner-notice.sh'), *args],
                       env=env, capture_output=True, text=True, timeout=10)
    assert p.returncode == 75 and 'outbox-unresponsive' in p.stdout, (p.returncode, p.stdout, p.stderr)
    assert time.monotonic() - at <= 4
    if origin == 'retire':
        w.call('consume', 'x', 'one')


def archive(w):
    w.env['FM_OWNER_NOTICE_NOW'] = str(int(time.time()) - 8 * 86400)
    w.bind('x'); w.envelope('x', 'one'); w.call('ingest', 'x'); w.call('consume', 'x', 'one')
    del w.env['FM_OWNER_NOTICE_NOW']
    w.start()
    wait('automatic daily archive', lambda: not (w.own / 'x/current/one.json').exists())
    assert list((w.own / 'x/archive').glob('*/one.json'))


def retention_boundary(w):
    # Each permitted path gets independently aged, valid consumed custody.
    w.env['FM_OWNER_NOTICE_NOW'] = str(int(time.time()) - 8 * 86400)
    for bid in ('engine', 'maintain', 'ingest'):
        w.bind(bid); w.envelope(bid, 'one'); w.call('ingest', bid); w.call('consume', bid, 'one')
    del w.env['FM_OWNER_NOTICE_NOW']
    base = w.own / 'engine'
    before = {str(p.relative_to(base)): p.read_bytes() for p in base.rglob('*') if p.is_file()}
    refused = json.loads(w.call('retention', 'engine', code=2))
    assert refused['state'] == 'usage' and refused['detail'] == 'unknown command: retention', refused
    assert before == {str(p.relative_to(base)): p.read_bytes() for p in base.rglob('*') if p.is_file()}
    assert (base / 'current/one.json').exists() and not list((base / 'archive').glob('*/one.json'))
    # The existing engine operation still succeeds under its real native lock.
    script = '''. "$1/bin/fm-wake-lib.sh"
fm_lock_acquire_wait_bounded "$2" 5 || exit 75
trap 'fm_lock_release "$2"' EXIT
python3 "$1/bin/fm_owner_notice_store.py" retention --home "$FM_HOME" --lock "$2" engine
rc=$?; exit "$rc"
'''
    p = subprocess.run(['bash', '-c', script, '_', str(ROOT), str(base / '.lock')],
                       env=w.env, capture_output=True, text=True, timeout=20)
    assert p.returncode == 0 and json.loads(p.stdout)['state'] == 'retained', (p.stdout, p.stderr)
    w.call('maintain', 'maintain')
    w.call('ingest', 'ingest')
    for bid in ('engine', 'maintain', 'ingest'):
        assert not (w.own / bid / 'current/one.json').exists(), bid
        assert len(list((w.own / bid / 'archive').glob('*/one.json'))) == 1, bid


def history(w):
    w.env['FM_OWNER_NOTICE_NOW'] = str(int(time.time()) - 8 * 86400)
    outbox = w.bind('x'); seed = w.envelope('x', 'seed')
    w.call('ingest', 'x'); w.call('consume', 'x', 'seed')
    templates = [record(w.own / 'x/receipts/seed' / (str(n) + '.json')) for n in (1, 2)]
    projection = record(w.own / 'x/current/seed.json')
    seed.unlink(); del w.env['FM_OWNER_NOTICE_NOW']
    binding = (w.own / 'bindings/x.json').read_bytes()
    bsha = hashlib.sha256(binding).hexdigest()
    archive_dir = w.own / 'x/archive' / templates[1]['recorded_at'][:7]; archive_dir.mkdir(exist_ok=True)
    cache = []
    # Valid archived consumed history, not 10,000 live keys. Derive every
    # receipt and projection from one public delivered/consumed pair.
    for n in range(10000):
        key = 'history-%05d' % n
        envelope = fmt.envelope('x', bsha, key, 'note', b'seed')
        path = outbox / (key + fmt.ENVELOPE_SUFFIX); path.write_bytes(envelope)
        rdir = w.own / 'x/receipts' / key; rdir.mkdir()
        for i, template in enumerate(templates, 1):
            receipt = dict(template, notice_key=key, envelope_sha256=hashlib.sha256(envelope).hexdigest())
            if i == 1:
                receipt['envelope_bytes'] = len(envelope)
            fmt.validate_receipt(receipt, i)
            (rdir / (str(i) + '.json')).write_bytes(fmt.canonical(receipt))
        (archive_dir / (key + '.json')).write_bytes(fmt.canonical(dict(projection, key=key)))
        st = path.stat(); cache.append('%s\t%s\t%s\n' % (st.st_ino, st.st_ctime_ns, path.name))
    (w.own / 'x/.ingest-cache').write_text(''.join(cache))
    for n in range(3):
        w.envelope('x', 'new-%s' % n)
    env = dict(w.env, FM_OWNER_NOTICE_OPEN_COUNT=str(w.root / 'opens'))
    env['FM_OWNER_NOTICE_FAULT'] += ',cache-slack=0,ingest-cap=20000'
    run = '%s-%s-cafe' % (os.getpid(), fmt.pid_starttime(os.getpid()))
    p = subprocess.run(['python3', str(ROOT / 'bin/fm_owner_notice_store.py'), 'stage', '--home', str(w.home), 'x', run],
                       env=env, capture_output=True, text=True, timeout=120)
    assert p.returncode == 0, (p.stdout, p.stderr)
    opened = [line for line in (w.root / 'opens').read_text().splitlines()
              if '.envelope.json' in line and ' open ' in line]
    assert len(opened) == 3, len(opened)
    w.call('ingest', 'x', env=env)
    assert w.level('outbox-backlog')
    events = record(w.own / 'alert-store.json')['events']
    assert len([e for e in events if e['action'] == 'raised' and e.get('alert', {}).get('kind') == 'outbox-backlog']) == 1


def refusal_ack(w):
    outbox = w.bind('x')
    bsha = hashlib.sha256((w.own / 'bindings/x.json').read_bytes()).hexdigest()
    (outbox / ('unsupported' + fmt.ENVELOPE_SUFFIX)).write_bytes(
        fmt.envelope('x', bsha, 'unsupported', 'other', b'payload'))
    w.start()
    wait('refusal level', lambda: w.level('refused', 'x/unsupported'))
    w.call('ack-refusal', 'x', 'unsupported', '--note', 'fixture refusal handled')
    wait('ack removes refusal level', lambda: not w.level('refused', 'x/unsupported'))


def empty_home(w):
    w.start(); w.advance(10)
    assert not (w.own / '.runner-attempt').exists()
    assert not w.level('runner-beat-stale', runner=True)


def bad_routing(w):
    w.bind('x'); path = w.own / '.bindings.list'; path.unlink(); os.mkfifo(path)
    w.start()
    wait('invalid routing is diagnosed without crashing the runner', lambda: w.level('routing-unreadable', bid='all'))
    assert not (w.own / 'x/.beat').exists()


def counter_reader(w):
    samples = [('missing', None, '0 0 0'), ('valid', b'2 70\n', '2 70 0'),
               ('leading-zero', b'08 070\n', '8 70 0'), ('empty', b'', '3 70 1'),
               ('white', b' \t\n', '3 70 1'), ('partial', b'2 70', '3 70 1'),
               ('nul', b'2\x00 70\n', '3 70 1'), ('colon', b'1:1 0\n', '3 70 1'),
               ('large', b'9' * 10000 + b' 0\n', '3 70 1'),
               ('extra', b'2 70\n1 0\n', '3 70 1'), ('bad-code', b'1 300\n', '3 70 1')]
    samples += [(name, None, '3 70 1') for name in ('fifo', 'directory', 'link')]
    script = '''STATE=$2; SCRIPT_DIR=$1; problem=0
. "$SCRIPT_DIR/fm-alert-store-lib.sh"
. "$SCRIPT_DIR/fm-owner-notice-watch-lib.sh"
# Isolate the counter parser; source persistence has the recovery fixtures.
owner_notice_source_failed() { problem=1; }
owner_notice_source_repaired() { :; }
owner_notice_count
printf '%s %s %s\\n' "$OWNER_NOTICE_COUNT" "$OWNER_NOTICE_LAST_CODE" "$problem"
'''
    for name, data, expected in samples:
        state = w.root / ('counter-' + name); own = state / 'owner-notices'; own.mkdir(parents=True)
        path = own / '.runner-respawns'
        if data is not None:
            path.write_bytes(data)
        elif name == 'fifo':
            os.mkfifo(path)
        elif name == 'directory':
            path.mkdir()
        elif name == 'link':
            path.symlink_to(own / 'missing')
        p = subprocess.run(['bash', '-c', script, '_', str(ROOT / 'bin'), str(state)],
                           env=w.env, capture_output=True, text=True, timeout=3)
        assert p.returncode == 0 and p.stdout.strip() == expected, (name, p.returncode, p.stdout, p.stderr)


def startup_fixture(w):
    w.bind('x')
    w.env.update(FM_TEST_START_ONLY='1', FM_CHECK_INTERVAL='5')
    shim = w.root / 'startup-path'; shim.mkdir()
    trace = w.root / 'startup-calls'
    fault = w.root / 'startup-runtime-failure'
    wrapper = shim / 'python3'
    wrapper.write_text('#!' + sys.executable + '\n' +
        'import os,runpy,sys\nargs=sys.argv[1:]\n' +
        'if len(args)>1 and os.path.basename(args[0])=="fm_owner_notice_store.py" and args[1] in '
        '("runner-config","reserve-run","runner-progress","runner-count"):\n' +
        '    with open(' + repr(str(trace)) + ',"a") as f: f.write(args[1]+"\\n")\n' +
        '    if args[1]=="runner-count" and os.path.exists(' + repr(str(w.root / 'startup-count-failure')) + '): sys.exit(70)\n' +
        '    if args[1]=="reserve-run" and os.path.exists(' + repr(str(w.root / 'startup-reserve-failure')) + '): sys.exit(70)\n' +
        '    if args[1]=="runner-config" and os.path.exists(' + repr(str(fault)) + '):\n' +
        '        sys.path.insert(0,' + repr(str(ROOT / 'bin')) + ')\n' +
        '        sys.version_info=(3,10,0,"final",0); sys.argv=args\n' +
        '        runpy.run_path(args[0],run_name="__main__")\n' +
        'os.execv(' + repr(sys.executable) + ',[' + repr(sys.executable) + ']+args)\n')
    wrapper.chmod(0o755)
    w.env['PATH'] = str(shim) + os.pathsep + w.env['PATH']
    def calls():
        return trace.read_text().splitlines() if trace.exists() else []
    def step(clock, code=0):
        w.alarm_command('startup', str(clock), code=code)
        after, initialized, pid = (w.state / '.fixture-startup-state').read_text().split()
        return int(after), int(initialized), pid
    return fault, calls, step


def startup_refusal(w):
    fault, calls, step = startup_fixture(w)
    w.envelope('x', 'one')
    temp = w.own / '.tmp'; saved = w.own / '.tmp.saved'
    if CASE == 'startup_config':
        fault.touch()
    else:
        foreign = w.root / 'startup-foreign'; foreign.mkdir()
        temp.rename(saved); temp.symlink_to(foreign, target_is_directory=True)
    w.start()
    after, initialized, pid = step(100, code=1)
    assert (after, pid) == (105, '-'), (after, initialized, pid)
    assert not (w.own / '.runner-attempt').exists()
    if CASE == 'startup_config':
        wait('configuration refusal is held', lambda: w.level('runner-respawn-failing', runner=True))
    else:
        wait('reservation publication refusal is visible', lambda: (w.state / '.wake-queue').exists()
             and 'alarm publication failed' in (w.state / '.wake-queue').read_text())
    first = calls()
    assert first.count('runner-config') == 1
    assert first.count('reserve-run') == (0 if CASE == 'startup_config' else 1)
    # No duration window: the fixture shell's SECONDS is an ordinary,
    # explicitly controlled variable, while the production functions/CLIs run.
    for clock in (100, 101, 104, 104):
        assert step(clock) == (105, initialized, '-')
        assert calls() == first, 'preflight repeated before its deadline'
    step(105, code=1)
    second = calls()
    verb = 'runner-config' if CASE == 'startup_config' else 'reserve-run'
    assert second.count(verb) == first.count(verb) + 1
    if CASE == 'startup_config':
        fault.unlink()
    else:
        assert not list(foreign.iterdir()), 'failed reservation wrote through metadata alias'
        temp.unlink(); saved.rename(temp)
    assert step(109) == (110, initialized, '-')
    assert calls() == second
    step(110)
    w.delivered('x', 'one')
    w.alarm_command('sweep')
    # Release each observed publisher deadline too: the controlled startup
    # clock otherwise stops while the clears wait behind earlier results.
    def recovered():
        w.alarm_command('pump-next')
        return not w.level('runner-respawn-failing', runner=True)
    wait('repaired startup clears its level', recovered)


def startup_exit_refusal(w):
    _fault, calls, step = startup_fixture(w)
    w.start('run:exit=7')
    _after, _initialized, pid = step(100)
    assert pid != '-'
    wait('failed front gone before bookkeeping', lambda: not Path('/proc/%s' % pid).exists())
    attempt = (w.own / '.runner-attempt').read_bytes()
    count = w.own / '.runner-respawns'
    failed_write = w.root / 'startup-count-failure'
    if CASE == 'startup_exit_counter':
        count.write_bytes(b'unknown\n')
    else:
        count.write_bytes(b'0 0\n')
        # Fail only the counter command, not reservation: otherwise a later
        # reservation refusal could mask a missing exit-bookkeeping deadline.
        failed_write.touch()
    raw = count.read_bytes()
    reserved = calls().count('reserve-run')
    assert step(101) == (106, 1, '-')
    assert calls().count('reserve-run') == reserved
    observed = calls()
    for clock in (101, 102, 105, 105):
        assert step(clock) == (106, 1, '-')
        assert calls() == observed, 'failed bookkeeping caused a fast-tick respawn'
        assert count.read_bytes() == raw and (w.own / '.runner-attempt').read_bytes() == attempt
    if CASE == 'startup_exit_counter':
        count.write_bytes(b'0 0\n')
    else:
        failed_write.unlink()
    _after, _initialized, replacement = step(106)
    assert replacement != '-'
    assert (w.own / '.runner-attempt').read_bytes() != attempt
    assert calls().count('reserve-run') == observed.count('reserve-run') + 1
    wait('replacement exits for repaired bookkeeping', lambda: not Path('/proc/%s' % replacement).exists())
    assert step(107) == (109, 1, '-')
    assert count.read_bytes() == b'1 7\n'


def recovery_prior(w):
    config_fault, _calls, step = startup_fixture(w)
    w.env['FM_OWNER_NOTICE_FAULT'] += ',stat-bound=60'
    w.start(); step(0)
    wait('prior genuine progress', lambda: fields(w.own / '.runner-beat'))
    wait('prior initial cycle', lambda: (w.own / 'x/.seen').exists())
    prior = w.runner(); w.stop_watch()
    wait('prior front gone', lambda: not fmt.identity_alive(int(prior['pid']), prior['starttime']))
    source = CASE.split('_')[2]
    source = {'config': 'configuration', 'reserve': 'reservation', 'write': 'counter-write'}[source]
    fault = {'configuration': config_fault, 'reservation': w.root / 'startup-reserve-failure',
             'counter-write': w.root / 'startup-count-failure'}[source]
    def refuse():
        w.start('run:exit=7' if source == 'counter-write' else '')
        if source == 'counter-write':
            # The previous successful beat stays fresh, but this new front
            # never beats and its failed exit cannot persist the new count.
            fault.unlink(missing_ok=True)
            _after, _init, pid = step(100)
            wait('pre-beat front exits', lambda: not Path('/proc/%s' % pid).exists())
            (w.own / '.runner-respawns').write_text('0 0\n')
            fault.touch(); step(101)
        else:
            fault.touch(); step(100, code=1)
        row = record(w.own / '.runner-recovery')
        assert source in row['sources'] and not row['sources'][source]['repaired'], row
        assert row['phase'] == 'pending' and row['candidate'] is None, row
        w.alarm_command('sweep')
        w.alarm_command('pump-next')
        wait('source failure held despite fresh prior beat', lambda: w.level('runner-respawn-failing', runner=True))
        return w.level('runner-respawn-failing', runner=True), row['sources'][source]['since']
    first, since = refuse()
    for _ in range(2):
        w.alarm_command('sweep'); w.alarm_command('pump-next')
        assert w.level('runner-respawn-failing', runner=True) == first
    w.stop_watch()
    second, again = refuse()
    assert second == first and again == since, (first, second, since, again)
    events = record(w.own / 'runner-alert-store.json')['events']
    assert [e['action'] for e in events if e['key'] == 'runner-respawn-failing'] == ['raised'], events
    fault.unlink()
    w.stop_watch()
    if CASE.endswith('_empty'):
        retire_old_and_purge(w)
    w.start()
    # The first sweep after replacement is NOT evidence of recovery. It may
    # validate sources, but only later work can clear the held occurrence.
    w.alarm_command('sweep')
    assert w.level('runner-respawn-failing', runner=True) == first
    step(100)
    def recovered():
        w.alarm_command('sweep'); w.alarm_command('pump-next')
        return record(w.own / '.runner-recovery')['phase'] == 'cleared' and not w.level('runner-respawn-failing', runner=True)
    wait('later work recovers all source fences', recovered)
    beat = fields(w.own / '.runner-beat')
    assert beat['attempt'] != fields(w.own / '.runner')['prev_attempt']
    if CASE.endswith('_empty'):
        assert beat.get('drained') == 'yes'
    else:
        w.envelope('x', 'repaired'); w.delivered('x', 'repaired')
    events = record(w.own / 'runner-alert-store.json')['events']
    assert [e['action'] for e in events if e['key'] == 'runner-respawn-failing'] == ['raised', 'cleared'], events
    w.stop_watch(); w.start(); w.alarm_command('sweep')
    assert not w.level('runner-respawn-failing', runner=True)


def recovery_reader(w):
    import copy
    w.bind('x'); w.env['FM_TEST_START_ONLY'] = '1'; w.start()
    path = w.own / '.runner-recovery'
    w.alarm_command('recovery', 'status')
    assert (w.state / '.fixture-recovery-output').read_text() == 'clear -\n'
    assert not path.exists()
    w.alarm_command('recovery', 'fail', 'configuration', 'reader fixture')
    good = path.read_bytes(); obj = json.loads(good)
    malformed = [b'', b' ', good + b'\x00', good[:-1], b'x' * 8193]
    for key, value in [('schema', 'old'), ('phase', 'ready'), ('sources', {}), ('candidate', {})]:
        row = copy.deepcopy(obj); row[key] = value; malformed.append(fmt.canonical(row))
    for key, value in [('since', True), ('reason', ''), ('repaired', 1)]:
        row = copy.deepcopy(obj); row['sources']['configuration'][key] = value; malformed.append(fmt.canonical(row))
    row = copy.deepcopy(obj); row['sources']['foreign'] = row['sources'].pop('configuration'); malformed.append(fmt.canonical(row))
    for bad in malformed:
        path.write_bytes(bad)
        w.alarm_command('recovery', 'status', code=70)
        assert path.read_bytes() == bad
        w.alarm_command('recovery', 'fail', 'reservation', code=70)
        assert path.read_bytes() == bad
    path.write_bytes(good)
    path.chmod(0)
    w.alarm_command('recovery', 'status', code=70)
    assert path.stat().st_mode & 0o777 == 0
    path.chmod(0o600); path.unlink()
    saved = w.root / 'recovery-good'; saved.write_bytes(good)
    for shape in ('link', 'dangling', 'directory', 'fifo'):
        if shape == 'link': path.symlink_to(saved)
        elif shape == 'dangling': path.symlink_to(w.root / 'missing-recovery')
        elif shape == 'directory': path.mkdir()
        else: os.mkfifo(path)
        w.alarm_command('recovery', 'status', code=70)
        assert saved.read_bytes() == good
        if shape == 'directory': path.rmdir()
        else: path.unlink()
    # Held legacy failure with absent sidecar is not a healthy empty source.
    w.alert('assert', 'runner-respawn-failing', 'unattributed legacy failure')
    w.alarm_command('sweep')
    row = record(path)
    assert set(row['sources']) == {'configuration', 'reservation', 'counter-read', 'counter-write', 'failed-start'}
    assert row['phase'] == 'pending' and w.level('runner-respawn-failing', runner=True)
    # A corrupt persisted fence is surfaced, never silently reset as absent.
    path.write_bytes(b'{}\n'); w.alarm_command('sweep')
    assert path.read_bytes() == b'{}\n' and w.level('runner-respawn-failing', runner=True)
    w.call('sync-alarms')
    assert w.level('automation-unreadable', 'recovery')


def recovery_progress(w):
    _config, _calls, step = startup_fixture(w)
    w.start(); step(100)
    wait('real attempt progress', lambda: fields(w.own / '.runner-beat'))
    runner = w.runner(); loop = w.loop(runner)
    os.kill(loop, signal.SIGSTOP)
    w.alarm_command('recovery', 'fail', 'counter-read', 'fenced current attempt')
    w.alarm_command('recovery', 'repair', 'counter-read')
    baseline = record(w.own / '.runner-recovery')
    assert baseline['candidate']['identity']['attempt'] == runner['attempt']
    w.alarm_command('recovery', 'advance')
    assert record(w.own / '.runner-recovery') == baseline, 'old current-attempt beat became repair'
    # Exercise the two distinct identity guards with otherwise valid records.
    beat_path, installed_path = w.own / '.runner-beat', w.own / '.runner'
    beat_bytes, installed_bytes = beat_path.read_bytes(), installed_path.read_bytes()
    beat, installed = fields(beat_path), fields(installed_path)
    different = str(int(runner['pid']) + 1)
    beat['pid'] = different; installed['pid'] = different
    def put_fields(path, row):
        path.write_text(' '.join('%s=%s' % item for item in row.items()) + '\n')
    put_fields(beat_path, beat); put_fields(installed_path, installed)
    w.alarm_command('recovery', 'advance')
    assert record(w.own / '.runner-recovery') == baseline, 'different installed identity satisfied an existing candidate'
    installed_path.write_bytes(installed_bytes)
    no_identity = json.loads(json.dumps(baseline)); no_identity['candidate']['identity'] = None
    (w.own / '.runner-recovery').write_bytes(fmt.canonical(no_identity))
    w.alarm_command('recovery', 'advance')
    assert record(w.own / '.runner-recovery') == no_identity, 'nonmatching installed beat satisfied a pre-install candidate'
    beat_path.write_bytes(beat_bytes); (w.own / '.runner-recovery').write_bytes(fmt.canonical(baseline))
    # One repaired source cannot form a candidate while a sibling is refused.
    w.alarm_command('recovery', 'fail', 'configuration', 'second source')
    w.alarm_command('recovery', 'repair', 'counter-read')
    both = record(w.own / '.runner-recovery')
    assert both['candidate'] is None and not both['sources']['configuration']['repaired'], both
    w.alarm_command('recovery', 'repair', 'configuration')
    # Repeated failure invalidates the candidate while preserving occurrence.
    w.alarm_command('recovery', 'fail', 'counter-read', 'still failed')
    repeated = record(w.own / '.runner-recovery')
    assert repeated['candidate'] is None
    assert repeated['sources']['counter-read']['since'] == baseline['sources']['counter-read']['since']
    old_epoch = fields(w.own / '.runner-beat')['epoch']
    os.kill(loop, signal.SIGCONT)
    wait('new beat while source still failed', lambda: fields(w.own / '.runner-beat')['epoch'] != old_epoch)
    w.alarm_command('recovery', 'advance')
    assert record(w.own / '.runner-recovery')['phase'] == 'pending'
    w.alarm_command('recovery', 'repair', 'counter-read')
    def ready():
        w.alarm_command('recovery', 'advance')
        return record(w.own / '.runner-recovery')['phase'] == 'ready'
    wait('new progress after successful source repair', ready)
    w.alarm_command('recovery', 'cleared', code=70)
    assert record(w.own / '.runner-recovery')['phase'] == 'ready', 'completion skipped durable clear admission'
    # A second failing source vetoes existing ready proof even at zero count.
    (w.own / '.runner-respawns').write_text('0 0\n')
    refusal = w.root / 'startup-count-failure'; refusal.touch()
    w.alarm_command('sweep')
    row = record(w.own / '.runner-recovery')
    assert row['phase'] == 'pending' and row['candidate'] is None, row
    assert set(row['sources']) == {'configuration', 'counter-read', 'counter-write'}, row
    assert not row['sources']['counter-write']['repaired'], row
    wait('late persistence refusal held', lambda: w.level('runner-respawn-failing', runner=True))
    refusal.unlink()
    def cleared():
        w.alarm_command('sweep'); w.alarm_command('pump-next')
        return record(w.own / '.runner-recovery')['phase'] == 'cleared'
    wait('normal clear commits all-source recovery', cleared)


def projection_reader(w):
    from fm_owner_notice_runner import projection_complete
    w.bind('x')
    good = w.call('sync-alarms').encode()
    assert good == b'{"complete":true}\n' and projection_complete(good) is True
    assert projection_complete(b'{"complete":false}\n') is False
    for bad in (b'', b' ', good[:-1], good + b'\n', good + good, good + b'\x00',
                b'{"complete":1}\n', b'{"complete":null}\n', b'{}\n', b'[]\n',
                b'{"complete":true,"extra":0}\n', b'{"complete":true,"complete":false}\n',
                b'{"complete": true}\n', b'{"complete":true}\r\n', b'x' * 4096 + b'\n'):
        try:
            projection_complete(bad)
        except fmt.FormatError:
            pass
        else:
            raise AssertionError(('accepted invalid projection frame', bad[:128]))


def registration_isolation(w):
    w.bind('x'); w.start()
    wait('initial native registration completed', lambda: (w.state / 'alert-stores/owner-notice-runner.reg').exists())
    wait('initial real projection succeeded', lambda: 'projection exit' in w.log('') and 'code=0' in w.log(''))
    old = w.runner(); w.stop_watch()
    wait('original front stopped', lambda: not fmt.identity_alive(int(old['pid']), old['starttime']))
    kind = CASE.removeprefix('registration_')
    path = {'notice': w.own / 'alert-store.json', 'runner': w.own / 'runner-alert-store.json',
            'status': w.state / 'owner-notice.status', 'directory': w.state / 'alert-stores'}[kind]
    saved = w.root / 'saved-registration'
    if kind == 'directory':
        path.rename(saved); path.write_text('not a registration directory\n')
    else:
        healthy = path.read_bytes()
        if kind == 'status': path.chmod(0)
        else: path.write_bytes(b'{}\n')
    w.start()
    wait('new front installed despite source failure', lambda: fields(w.own / '.runner').get('attempt') not in (None, old['attempt']))
    current = w.runner(); worker = w.child('x', 'stat')
    first = wait('registration failure scoped to root projection', lambda: w.stall('', 'ingest'))
    w.envelope('x', 'independent'); w.delivered('x', 'independent')
    w.sweeps(2)
    assert w.stall('', 'ingest') == first
    assert w.runner()['pid'] == current['pid'] and fmt.identity_alive(worker['pid'], worker['starttime'])
    if kind == 'directory':
        assert path.read_text() == 'not a registration directory\n'
        path.unlink(); saved.rename(path)
    elif kind == 'status':
        assert path.stat().st_mode & 0o777 == 0
        path.chmod(0o600); assert path.read_bytes() == healthy
    else:
        assert path.read_bytes() == b'{}\n'; path.write_bytes(healthy)
    wait('same runner retries native registration and projection', lambda: not w.stall('', 'ingest'))
    assert w.runner()['pid'] == current['pid']
    for name in ('owner-notice.reg', 'owner-notice-runner.reg'):
        assert (w.state / 'alert-stores' / name).is_file()
    wait('independent delivery announced after projection repair', lambda: (w.own / 'x/.announced/independent').exists())


def registration_late(w):
    w.bind('x'); w.start()
    wait('warm successful projector', lambda: 'code=0 complete=true' in w.log(''))
    w.sweeps(1)
    current = w.runner()
    store = w.own / 'alert-store.json'; healthy = store.read_bytes()
    store.write_bytes(b'{}\n')
    w.envelope('x', 'late'); w.delivered('x', 'late')
    first = wait('late source failure invalidates registration cache', lambda: w.stall('', 'ingest'))
    status = w.state / 'owner-notice.status'; status.chmod(0)
    store.write_bytes(healthy)
    w.advance(5)
    assert w.stall('', 'ingest') == first, 'repaired store bypassed still-invalid registration source'
    assert status.stat().st_mode & 0o777 == 0
    assert w.runner()['pid'] == current['pid']
    status.chmod(0o600)
    wait('late registration source repair clears original stall', lambda: not w.stall('', 'ingest'))
    assert w.runner()['pid'] == current['pid']


def projection_failure(w):
    w.bind('x'); w.envelope('x', 'one')
    path = w.own / 'alert-store.json'; healthy = path.read_bytes(); path.write_text('{}\n')
    w.start('runner-loop-seconds=5,stat-bound=30')
    original = w.runner(); worker = w.child('x', 'stat')
    wait('nonzero projector failure', lambda: 'projection exit' in w.log('') and 'code=70' in w.log(''))
    first_stall = w.stall('', 'ingest')
    assert first_stall
    w.delivered('x', 'one')
    w.envelope('x', 'two'); w.delivered('x', 'two')
    def failures():
        return [line for line in w.log('').splitlines() if 'projection exit' in line and 'code=70' in line]
    wait('three bounded retries', lambda: len(failures()) >= 3)
    times = [fmt.parse_iso(line.split()[0]) for line in failures()]
    assert all(b - a >= 5 for a, b in zip(times, times[1:])), times
    assert w.runner()['pid'] == original['pid']
    assert w.children('x')['stat']['pid'] == worker['pid']
    assert fmt.identity_alive(worker['pid'], worker['starttime'])
    assert w.stall('', 'ingest')[1] == first_stall[1]
    wait('projector failure remains visible', lambda: w.level('runner-beat-stale', runner=True))
    assert 'start-sync-deferred' in w.log('')
    path.write_bytes(healthy)
    wait('successful projection clears failure', lambda: not w.stall('', 'ingest'))
    wait('watcher recovers without replacing runner', lambda: not w.level('runner-beat-stale', runner=True))
    assert w.runner()['pid'] == original['pid']


def old_projection_failure(w):
    w.bind('x'); w.envelope('x', 'one'); w.start('stat-bound=5')
    w.delivered('x', 'one')
    original = w.runner(); worker = w.child('x', 'stat')
    # Real age, not a forged beat/mtime: exceed 4*loop + stat-bound in both
    # the engine and the watcher's own SECONDS-based recovery guard.
    wait('runner older than recovery bound', lambda: time.time() > int(original['started_at']) + 12)
    path = w.own / 'alert-store.json'; healthy = path.read_bytes(); path.write_text('{}\n')
    w.envelope('x', 'two'); w.delivered('x', 'two')
    wait('old runner projection failure', lambda: w.stall('', 'ingest'))
    wait('watcher has held failure', lambda: w.level('runner-beat-stale', runner=True))
    w.advance(6)
    assert w.runner()['pid'] == original['pid']
    assert fmt.identity_alive(worker['pid'], worker['starttime'])
    if CASE == 'old_projection_stale':
        loop = w.loop(original)
        os.kill(loop, signal.SIGSTOP)
        wait('stale loop recovered despite already-held projection alarm',
             lambda: not fmt.identity_alive(original['pid'], original['starttime']))
        wait('stale loop children stopped', lambda: not fmt.identity_alive(worker['pid'], worker['starttime']))
        return
    stall = w.own / '.stall'; prior = stall.read_bytes(); stall.write_text('partial')
    w.advance(6)
    assert w.runner()['pid'] == original['pid']
    assert w.level('runner-beat-stale', runner=True)
    assert fmt.identity_alive(worker['pid'], worker['starttime'])
    stall.write_bytes(prior); path.write_bytes(healthy)
    wait('projector recovers on same old runner', lambda: not w.stall('', 'ingest'))
    wait('combined health clears only after recovery', lambda: not w.level('runner-beat-stale', runner=True))
    assert w.runner()['pid'] == original['pid']


def role_failure_retention(w):
    outbox = w.bind('x'); saved = w.root / 'saved-outbox'
    w.envelope('x', 'one'); os.mkfifo(w.root / 'ingest')
    w.start('ingest:after-receipt:pause=' + str(w.root / 'ingest'))
    wait('valid staged ingest paused', lambda: (w.root / 'ingest.reached').exists())
    outbox.rename(saved); outbox.mkdir()
    def state():
        return (record(w.own / 'x/.automation') or {}).get('failures', {})
    wait('stat-owned failure', lambda: state().get('stat'))
    first = state()['stat'].copy()
    w.release('ingest')
    wait('unrelated successful ingest completes', lambda: sum(
         'exit ingest' in line and 'code=0' in line for line in w.log().splitlines()) >= 2)
    assert state()['stat'] == first
    wait('stat failure projected', lambda: w.level('ingest-failed'))
    old = w.runner(); w.stop_watch()
    wait('old runner stopped', lambda: not fmt.identity_alive(int(old['pid']), old['starttime']))
    before = w.log().count('exit ingest'); w.start()
    wait('replacement maintenance completes', lambda: w.log().count('exit ingest') > before)
    assert state()['stat'] == first
    assert 'failure stat cleared' not in w.log()
    status = (w.state / 'owner-notice.status').read_text()
    assert not any('resolved' in line and 'ingest-failed:x' in line for line in status.splitlines())
    # Restore precisely the original inode; successful stat, not child exit or
    # maintenance success, is the recovery evidence for this occurrence.
    outbox.rmdir(); saved.rename(outbox)
    wait('successful stat clears its own failure', lambda: 'stat' not in state())
    w.envelope('x', 'recovered'); w.delivered('x', 'recovered')
    wait('failure level clears', lambda: not w.level('ingest-failed'))
    assert w.log().count('failure stat cleared') == 1


def role_failure_scope(w):
    w.bind('x'); w.envelope('x', 'one'); os.mkfifo(w.root / 'ingest')
    stamp = int(time.time()) - 100
    failures = {role: {'reason': role + ' prior failure', 'since': stamp}
                for role in ('stat', 'stage', 'maintain', 'ingest-staged')}
    (w.own / 'x/.automation').write_bytes(fmt.canonical({'busy': {}, 'failures': failures}))
    w.start('ingest:after-receipt:pause=' + str(w.root / 'ingest'))
    wait('ingest paused after stat and maintenance succeeded', lambda: (w.root / 'ingest.reached').exists())
    current = record(w.own / 'x/.automation')['failures']
    assert set(current) == {'stage', 'ingest-staged'}, current
    assert all(row['since'] == stamp for row in current.values())
    w.release('ingest')
    wait('corresponding ingest clears remaining cycle failures',
         lambda: not record(w.own / 'x/.automation')['failures'])


def quarantine_binding(w):
    w.bind('x'); w.bind('y'); w.envelope('y', 'one')
    kind = CASE.removeprefix('quarantine_')
    names = {'children': '.children', 'stall': '.stall', 'automation': '.automation',
             'seen': '.seen', 'index': '.outbox-index'}
    path = w.own / 'x' / names.get(kind, '.seen')
    if kind == 'binding':
        path = w.own / 'bindings/x.json'
    if kind == 'route':
        path = w.own / '.bindings.list'
    original = path.read_bytes() if path.exists() else None
    bad = b'partial'
    if kind == 'route':
        bad = original.replace(str(w.root / 'outbox-x').encode(), str(w.root / 'wrong-outbox').encode())
    path.write_bytes(bad)
    w.start(); current = w.runner()
    w.delivered('y', 'one')
    assert 'quarantine binding:x' in w.log('')
    if kind != 'route':  # U1 list repair can legitimately fix a routing mismatch.
        wait('binding source alarm', lambda: w.level('automation-unreadable'))
        assert path.read_bytes() == bad
        assert 'spawn ' not in w.log('x')
        if original is None:
            path.unlink()
        else:
            path.write_bytes(original)
    w.envelope('x', 'after-repair'); w.delivered('x', 'after-repair')
    assert w.runner()['pid'] == current['pid']
    wait('binding quarantine recovered', lambda: 'binding:x' not in (record(w.own / '.quarantine') or {}))


def quarantine_live(w):
    w.bind('x'); w.bind('y'); w.envelope('x', 'one'); w.start()
    w.delivered('x', 'one'); child = w.child('x', 'stat'); current = w.runner()
    path = w.own / 'x/.automation'; original = path.read_bytes(); path.write_text('{}\n')
    wait('live binding quarantined', lambda: 'binding:x' in (record(w.own / '.quarantine') or {}))
    before = (w.own / 'x/.beat').read_bytes()
    w.envelope('x', 'held'); w.envelope('y', 'independent'); w.delivered('y', 'independent')
    w.advance(4)
    assert (w.own / 'x/.beat').read_bytes() == before
    assert path.read_bytes() == b'{}\n'
    assert fmt.identity_alive(child['pid'], child['starttime'])
    assert w.children('x')['stat']['pid'] == child['pid']
    path.write_bytes(original); w.delivered('x', 'held')
    assert w.runner()['pid'] == current['pid']


def quarantine_global(w, scope=None):
    w.bind('x'); w.bind('y'); w.envelope('y', 'one')
    scope = scope or CASE.removeprefix('quarantine_')
    if scope == 'routing':
        path = w.own / '.bindings.list'
    elif scope == 'foreground':
        path = w.own / '.fg-children/bad'
        path.parent.mkdir(exist_ok=True)
    else:
        path = w.own / {'projection': '.children', 'root_stall': '.stall', 'ledger': '.quarantine'}[scope]
    original = path.read_bytes() if path.exists() else None
    path.write_text('partial')
    w.start(); current = w.runner()
    if scope in ('routing', 'foreground'):
        level = 'routing-unreadable' if scope == 'routing' else 'automation-unreadable'
        subject = 'all' if scope == 'routing' else scope
        wait('global source diagnosis', lambda: w.level(level, bid=subject))
        w.wait_wake(level)
        w.advance(4)
        for bid in ('x', 'y'):
            assert 'stat' not in w.children(bid) and 'stage' not in w.children(bid)
    else:
        w.delivered('y', 'one')
        wait('independent watcher diagnosis', lambda: w.level('runner-beat-stale', runner=True))
    assert path.read_bytes() == b'partial'
    assert w.runner()['pid'] == current['pid']
    if original is None:
        path.unlink()
    else:
        path.write_bytes(original)
    w.delivered('y', 'one')
    wait('quarantine recovered', lambda: not record(w.own / '.quarantine'))
    wait('projection diagnosis recovered', lambda: not w.level('runner-beat-stale', runner=True))
    assert w.runner()['pid'] == current['pid']


def quarantine_stat_reply(w):
    w.bind('x'); w.bind('y'); w.start(); child = w.child('x', 'stat'); current = w.runner()
    # Corrupt only this fixture-owned stat pipe, not a production fault knob.
    base = Path('/proc/%s/fd' % child['pid'])
    candidates = []
    for fd in base.iterdir():
        target = os.readlink(fd)
        if int(fd.name) <= 2 or not target.startswith('pipe:') or target == os.readlink(base / '1'):
            continue
        info = Path('/proc/%s/fdinfo/%s' % (child['pid'], fd.name)).read_text()
        flags = int(next(line.split()[1] for line in info.splitlines() if line.startswith('flags:')), 8)
        if flags & os.O_ACCMODE == os.O_WRONLY:
            candidates.append(fd)
    assert len(candidates) == 1, candidates
    fd = os.open(candidates[0], os.O_WRONLY | os.O_NONBLOCK)
    try:
        os.write(fd, b'bad reply\n')
    finally:
        os.close(fd)
    wait('bad stat reply diagnosed', lambda: 'invalid stat reply' in w.log())
    w.envelope('y', 'independent'); w.delivered('y', 'independent')
    wait('only failed stat replaced', lambda: w.children('x').get('stat', {}).get('pid') not in (None, child['pid']))
    w.envelope('x', 'recovered'); w.delivered('x', 'recovered')
    assert w.runner()['pid'] == current['pid']


def retire_old_and_purge(w, code=0):
    env = dict(w.env, FM_OWNER_NOTICE_NOW=str(int(time.time()) - 367 * 86400))
    w.call('retire', 'x', env=env, code=code)
    w.call('purge', 'x', code=code)
    assert not (w.own / '.bindings.list').read_bytes()
    assert not (w.own / '.retired.list').read_bytes()


def empty_after_projection_failure(w):
    w.bind('x'); w.start()
    wait('initial binding cycle completed', lambda: (w.own / 'x/.seen').exists())
    path = w.own / 'alert-store.json'; healthy = path.read_bytes(); path.write_text('{}\n')
    retire_old_and_purge(w, code=70)
    wait('failed final projection retained', lambda: w.stall('', 'ingest'))
    wait('watcher holds failure on empty demand', lambda: w.level('runner-beat-stale', runner=True))
    w.wait_wake('runner-beat-stale')
    old = w.runner(); w.stop_watch()
    wait('old runner stops', lambda: not fmt.identity_alive(int(old['pid']), old['starttime']))
    w.start()
    wait('empty-demand cleanup restarts', lambda: w.runner()['pid'] != old['pid'])
    w.advance(5)
    assert w.stall('', 'ingest')
    assert w.level('runner-beat-stale', runner=True)
    assert fields(w.own / '.runner-beat').get('drained') != 'yes'
    path.write_bytes(healthy)
    wait('successful final projection witness', lambda: fields(w.own / '.runner-beat').get('drained') == 'yes')
    wait('empty-demand failure recovered', lambda: not w.level('runner-beat-stale', runner=True))
    final = w.runner()
    wait('drained runner exits', lambda: not fmt.identity_alive(int(final['pid']), final['starttime']))
    w.advance(5)
    assert w.runner()['pid'] == final['pid'], 'empty home keeps respawning after drain'


def empty_incomplete_projection(w):
    w.bind('x')
    env = dict(w.env, FM_OWNER_NOTICE_NOW=str(int(time.time()) - 8 * 86400))
    w.call('retire', 'x', env=env)
    path = w.own / 'x/.automation'; path.write_text('{}\n')
    w.call('reconcile', 'x')  # U1 repairs routing; unknown-source projection only asserts.
    assert not (w.own / '.bindings.list').read_bytes()
    assert not (w.own / '.retired.list').read_bytes()
    w.start(); current = w.runner()
    wait('incomplete final projection diagnoses old source', lambda: w.level('automation-unreadable'))
    w.wait_wake('automation-unreadable')
    first = wait('incomplete projection holds root failure', lambda: w.stall('', 'ingest'))
    w.advance(5)
    assert w.stall('', 'ingest') == first
    assert fields(w.own / '.runner-beat').get('drained') != 'yes'
    assert fmt.identity_alive(int(current['pid']), current['starttime'])
    path.write_bytes(fmt.canonical({'busy': {}, 'failures': {}}))
    wait('complete final projection after repair', lambda: fields(w.own / '.runner-beat').get('drained') == 'yes')
    wait('old source alarm clears without new demand', lambda: not w.level('automation-unreadable'))


def empty_after_failed_starts(w):
    w.bind('x'); w.start('run:exit=7')
    wait('pre-beat failures held', lambda: w.level('runner-respawn-failing', runner=True))
    w.wait_wake('runner-respawn-failing')
    w.stop_watch(); retire_old_and_purge(w)
    assert w.level('runner-respawn-failing', runner=True)
    w.start()
    wait('empty-demand final beat', lambda: fields(w.own / '.runner-beat').get('drained') == 'yes')
    wait('failed-start occurrence recovered by final progress', lambda: not w.level('runner-respawn-failing', runner=True))
    wait('aggregate runner level clear', lambda: not w.level('runner-beat-stale', runner=True))
    final = w.runner(); w.advance(5)
    assert w.runner()['pid'] == final['pid']


def lifecycle_mark(w):
    w.lifecycle_before = {kind: len(w.wake_sources(kind)) for kind in
                          ('runner-beat-stale', 'runner-respawn-failing', 'automation-unreadable', 'routing-unreadable')}
    path = w.own / '.runner-attempt'
    w.lifecycle_attempt = path.read_bytes() if path.exists() else None


def lifecycle_existing_empty(w):
    w.bind('x'); retire_old_and_purge(w)
    assert w.own.is_dir() and not (w.own / '.runner-attempt').exists()
    lifecycle_mark(w)
    w.start(); w.sweeps()
    assert not (w.own / '.runner-beat').exists()


def lifecycle_drained(w):
    w.bind('x'); w.start()
    wait('initial cycle complete', lambda: (w.own / 'x/.seen').exists())
    retire_old_and_purge(w)
    wait('real final drain completed', lambda: fields(w.own / '.runner-beat').get('drained') == 'yes')
    final = w.runner()
    wait('final front gone', lambda: not fmt.identity_alive(int(final['pid']), final['starttime']))
    wait('preparation levels recovered', lambda: not w.level('runner-beat-stale', runner=True))
    w.stop_watch(); lifecycle_mark(w)
    w.start(); w.sweeps()


def lifecycle_unknown_ownership(w):
    w.bind('x'); retire_old_and_purge(w)
    path = w.own / '.children'; path.write_text('partial')
    lifecycle_mark(w); w.start()
    wait('unknown empty-home ownership alarm', lambda: w.level('runner-beat-stale', runner=True))
    w.wait_wake('runner-beat-stale')
    current = w.runner(); w.sweeps(2)
    assert path.read_text() == 'partial'
    assert 'projection exit' not in w.log('')
    path.unlink()
    wait('revalidated ownership permits final drain', lambda: fields(w.own / '.runner-beat').get('drained') == 'yes')
    wait('ownership alarm clears after repair', lambda: not w.level('runner-beat-stale', runner=True))
    assert w.runner()['pid'] == current['pid']


def lifecycle_notice_store(w, malformed=False):
    w.bind('x'); retire_old_and_purge(w)
    path = w.own / 'alert-store.json'; original = path.read_bytes()
    if malformed:
        path.write_text('{}\n')
    else:
        p = subprocess.run(['bash', str(ROOT / 'bin/fm-alert-store.sh'), 'assert', str(path),
                            'owner-notice', 'obsolete', 'fixture interrupted U1 post-mutation projection'],
                           env=w.env, capture_output=True, text=True, timeout=20)
        assert p.returncode == 0, p.stderr
    lifecycle_mark(w); w.start()
    if malformed:
        wait('unknown store prevents false idle', lambda: w.level('runner-beat-stale', runner=True))
        w.wait_wake('runner-beat-stale')
        assert path.read_bytes() == b'{}\n'
        path.write_bytes(original)
    wait('required U1 projection completes', lambda: fields(w.own / '.runner-beat').get('drained') == 'yes')
    wait('store-source recovery', lambda: not w.level('runner-beat-stale', runner=True))
    assert not record(path)['active']


def lifecycle_unknown_counter(w):
    w.bind('x'); w.envelope('x', 'one')
    path = w.own / '.runner-respawns'; raw = b'bad history\n'; path.write_bytes(raw)
    w.start(); w.delivered('x', 'one'); w.sweeps(2)
    assert path.read_bytes() == raw, 'fresh progress overwrote unknown history'
    w.wait_wake('runner-respawn-failing')
    old = w.runner(); os.kill(int(old['pid']), signal.SIGTERM)
    wait('replacement after ended runner', lambda: w.runner()['pid'] != old['pid'])
    assert path.read_bytes() == raw, 'exit bookkeeping overwrote unknown history'
    path.write_bytes(b'0 0\n')
    wait('repaired counter recovers', lambda: not w.level('runner-respawn-failing', runner=True))


def lifecycle_restart_setup(w):
    w.bind('x'); w.start('run:exit=7')
    wait('real failed-start history', lambda: w.level('runner-respawn-failing', runner=True))
    w.wait_wake('runner-respawn-failing')
    w.stop_watch()
    # Finish already accepted observations without producing more. Otherwise
    # an old queued stale assertion could replay after the baseline's clear.
    w.env['FM_TEST_ALARM_ONLY'] = '1'; w.start()
    wait('prior alarm observations drained', lambda: not w.alarm_rows()
         and not (w.own / '.runner-alarms.pending').exists())
    w.stop_watch(); del w.env['FM_TEST_ALARM_ONLY']
    retire_old_and_purge(w)
    # Isolate the sibling: one real held start-failure occurrence, no stale
    # level carried over from the earlier nonempty-work phase.
    if w.level('runner-beat-stale', runner=True):
        w.alert('clear', 'runner-beat-stale', 'fixture begins empty restart with only the start-failure level')
    os.mkfifo(w.state / '.fixture-first-sweep')
    lifecycle_mark(w)


def lifecycle_restart(w, stalled=False):
    lifecycle_restart_setup(w)
    if stalled:
        os.mkfifo(w.root / 'loop')
    w.start('runner-loop:pause=' + str(w.root / 'loop') if stalled else '')
    wait('first empty restart sweep complete', lambda: (w.state / '.fixture-first-sweep.reached').exists())
    assert not w.level('runner-beat-stale', runner=True)
    assert w.level('runner-respawn-failing', runner=True)
    assert (w.own / '.runner-attempt').read_bytes() == w.lifecycle_attempt
    assert len(w.wake_sources('runner-beat-stale')) == w.lifecycle_before['runner-beat-stale']
    w.release('home/state/.fixture-first-sweep')
    if stalled:
        wait('actual cleanup loop paused', lambda: (w.root / 'loop.reached').exists())
        current = w.runner()
        wait('actual cleanup progress becomes overdue', lambda: w.level('runner-beat-stale', runner=True))
        assert fmt.parse_iso(w.level('runner-beat-stale', runner=True)['since']) >= int(current['started_at']) + 5
        w.wait_wake('runner-beat-stale')
        wait('watcher terminates only the overdue cleanup front',
             lambda: not fmt.identity_alive(int(current['pid']), current['starttime']))
        w.stop_watch()
    else:
        wait('needed cleanup completes', lambda: fields(w.own / '.runner-beat').get('drained') == 'yes')
        wait('held start failure clears through actual progress', lambda: not w.level('runner-respawn-failing', runner=True))
        assert not w.level('runner-beat-stale', runner=True)


# Table-driven lifecycle contract. "Wake" means the native alert-store's
# durable blocked source (or direct check fallback), not a live fleet consumer.
# Each row runs in its own marked World. Guard columns name isolated reverts;
# the CI counterfactual record must cite the matching row, never a batch mutant.
LIFECYCLE = {
    'lifecycle_absent': (empty_home, 'clear', None, 'none', 'absent-tree early return'),
    'lifecycle_idle': (lifecycle_existing_empty, 'clear', None, 'none', 'validated idle does not force drain'),
    'lifecycle_idle_native': (lambda w: real_watcher(w, True), 'clear', None, 'none', 'native watcher has no spurious idle wake'),
    'lifecycle_drained': (lifecycle_drained, 'clear', None, 'unchanged', 'accepted final witness suppresses respawn'),
    'lifecycle_legacy_pending': (lifecycle_notice_store, 'clear', None, 'new', 'held U1 projection is not idle'),
    'lifecycle_notice_unknown': (lambda w: lifecycle_notice_store(w, True), 'clear', 'runner-beat-stale', 'new', 'unknown notice store is not idle'),
    'lifecycle_held_restart': (empty_after_failed_starts, 'clear', 'runner-respawn-failing', 'new', 'held failure requires final drain'),
    'lifecycle_projection': (empty_after_projection_failure, 'clear', 'runner-beat-stale', 'new', 'failed empty projection retains recovery'),
    'lifecycle_incomplete': (empty_incomplete_projection, 'clear', 'automation-unreadable', 'new', 'partial projection cannot certify drain'),
    'lifecycle_routing': (lambda w: quarantine_global(w, 'routing'), 'clear', 'routing-unreadable', 'new', 'unknown routing is not empty'),
    'lifecycle_ownership': (lifecycle_unknown_ownership, 'clear', 'runner-beat-stale', 'new', 'unknown ownership is not idle'),
    'lifecycle_counter': (lifecycle_unknown_counter, 'clear', 'runner-respawn-failing', 'new', 'unknown history is not reset by progress or exit'),
    'lifecycle_stalled': (lambda w: lifecycle_restart(w, True), 'held', 'runner-beat-stale', 'new', 'overdue cleanup can assert and terminate'),
    'lifecycle_restart_failed': (lifecycle_restart, 'clear', None, 'new', 'no new stale occurrence before cleanup starts'),
}


def lifecycle(w):
    fixture, alarm, wake, starts, guard = LIFECYCLE[CASE]
    w.spy_alerts(); lifecycle_mark(w)
    fixture(w)
    stale = w.level('runner-beat-stale', runner=True)
    assert bool(stale) == (alarm == 'held'), (CASE, alarm, stale)
    if alarm == 'clear':
        assert not w.level('runner-respawn-failing', runner=True)
        if wake in ('routing-unreadable', 'automation-unreadable'):
            wait('matrix source level recovered', lambda: not w.level(wake, bid='all' if wake == 'routing-unreadable' else 'x'))
    if wake is None:
        for kind in ('runner-beat-stale', 'runner-respawn-failing'):
            assert len(w.wake_sources(kind)) == w.lifecycle_before[kind], (CASE, kind, w.wake_sources(kind))
    else:
        assert len(w.wake_sources(wake)) > w.lifecycle_before[wake], (CASE, wake)
    attempt = w.own / '.runner-attempt'
    if starts == 'none':
        assert not attempt.exists(), CASE
    elif starts == 'unchanged':
        assert attempt.read_bytes() == w.lifecycle_attempt, CASE
    else:
        assert attempt.exists() and attempt.read_bytes() != w.lifecycle_attempt, CASE
    print('lifecycle row=%s alarm=%s wake=%s start=%s revert=%s' % (CASE, alarm, wake or 'none', starts, guard))


def publication_lease_sync(w):
    # Called by the protocol suite: U2 initialization must use U1's fsync
    # observer before queue publication, with genuine watcher authority.
    w.bind('x')
    spy = w.root / 'fsync-spy'
    w.env.update(FM_TEST_ALARM_ONLY='1', FM_OWNER_NOTICE_FSYNC_SPY=str(spy))
    watcher = w.start()
    start = fmt.pid_starttime(watcher.pid)
    w.alarm_command('enqueue', 'assert', 'runner-beat-stale')
    wait('native writer delivered lease-sync control', lambda: w.level('runner-beat-stale', runner=True))
    rows = [line.split() for line in spy.read_text().splitlines()]
    lease = str(w.own / '.runner-alarm-publisher.lock')
    queue = str(w.own / '.runner-alarms.sqlite3')
    sync = next(i for i, row in enumerate(rows) if row[:2] == ['o-alarm-lease-fsync', lease])
    published = next(i for i, row in enumerate(rows) if row[:2] == ['link', queue])
    assert sync < published, rows
    # A forced healthy reconciliation must return to the SAME watcher, not
    # replace it with the exec-style timeout helper, even with a native store.
    w.alarm_command('runtime-check')
    w.advance()
    assert watcher.poll() is None and fmt.identity_alive(watcher.pid, start)
    w.alarm_command('enqueue', 'clear', 'runner-beat-stale')
    wait('same watcher cleared control', lambda: not w.level('runner-beat-stale', runner=True))


def publication_fifo(w):
    w.bind('x'); w.spy_alerts(); w.hold_alarm('assert', 'runner-beat-stale')
    w.env['FM_TEST_ALARM_ONLY'] = '1'
    w.start('ingest-bound=60')
    for action in ('assert', 'clear', 'assert'):
        w.alarm_command('enqueue', action, 'runner-beat-stale')
    wait('publisher held before first write', lambda: (w.root / 'alarm-hold.reached').exists())
    assert [r[2] for r in w.alarm_rows()] == ['assert', 'clear', 'assert']
    writer = int((w.root / 'alarm-writer-pid').read_text())
    assert any(Path(os.readlink(fd)).resolve() == (w.own / '.runner-alarm-publisher.lock').resolve()
               for fd in Path('/proc/%s/fd' % writer).iterdir()), 'writer descendants did not inherit the lease'
    busy = subprocess.run(['python3', str(w.script_dir / 'fm_owner_notice_alarm.py'), '--home', str(w.home), 'drain'],
                          env=w.env, capture_output=True, text=True, timeout=10)
    assert busy.returncode == 75, busy
    assert not w.level('runner-beat-stale', runner=True), 'second publisher bypassed occupied lease'
    w.stop_watch()
    assert [r[2] for r in w.alarm_rows()] == ['assert', 'clear', 'assert'], 'exit lost/reordered accepted requests'
    # Parent-loss cleanup cancels the old bounded writer. The successor must
    # replay the retained head, not require the dead writer's FIFO release.
    w.start('ingest-bound=60')
    wait('FIFO fully acknowledged', lambda: not w.alarm_rows())
    events = record(w.own / 'runner-alert-store.json')['events']
    assert [e['action'] for e in events if e['key'] == 'runner-beat-stale'] == ['raised', 'cleared', 'raised']
    old = w.level('runner-beat-stale', runner=True)
    calls = w.alert_calls()
    for _ in range(3):
        w.alarm_command('enqueue', 'assert', 'runner-beat-stale')
    wait('held observations acknowledged', lambda: not w.alarm_rows())
    assert w.alert_calls().count(next(x for x in calls if x.startswith('assert '))) == calls.count(next(x for x in calls if x.startswith('assert ')))
    assert w.level('runner-beat-stale', runner=True) == old
    # Native write succeeded but queue acknowledgement did not. Restart must
    # observe the ACKed active key, not refresh it or lose the pending request.
    w.stop_watch(); os.mkfifo(w.root / 'after-alarm-write')
    w.start('ingest-bound=60,alarm-publisher:after-write:pause=' + str(w.root / 'after-alarm-write'))
    w.alarm_command('enqueue', 'assert', 'runner-respawn-failing')
    hit = w.root / 'after-alarm-write.reached'
    wait('writer before acknowledgement', hit.exists)
    old = w.level('runner-respawn-failing', runner=True)
    w.alert('ack', 'runner-respawn-failing', '300', 'fixture', 'held observation control')
    pid = int(hit.read_text().splitlines()[0].split()[-1]); start = fmt.pid_starttime(pid)
    os.kill(pid, signal.SIGKILL); w.stop_watch()
    wait('old publisher ended', lambda: not fmt.identity_alive(pid, start))
    w.start('ingest-bound=60')
    wait('write-before-ack replay completed', lambda: not w.alarm_rows())
    assert w.level('runner-respawn-failing', runner=True) == old
    assert sum(line.startswith('assert ') and 'runner-respawn-failing' in line
               for line in w.alert_calls()) == 1


def publication_stale_counter(w):
    w.bind('x'); w.spy_alerts(); w.hold_alarm('assert', 'runner-respawn-failing')
    os.mkfifo(w.root / 'loop-gate')
    w.start('ingest-bound=60,runner-loop:pause=' + str(w.root / 'loop-gate'))
    wait('initial loop at gate', lambda: (w.root / 'loop-gate.reached').exists())
    w.release('loop-gate')
    wait('real loop progressed', lambda: fields(w.own / '.runner-beat'))
    loop = w.loop()
    (w.own / '.runner-respawns').write_text('unknown\n')
    wait('counter publisher deliberately occupied', lambda: (w.root / 'alarm-hold.reached').exists())
    os.kill(loop, signal.SIGSTOP)
    wait('later stale transition retained', lambda: any(r[1:] == ('runner-beat-stale', 'assert') for r in w.alarm_rows()))
    w.release('alarm-hold')
    # Replacement loops remain at their own gate, so recovery cannot consume
    # the occurrence before the real native wake-facing projection sees it.
    w.wait_wake('runner-respawn-failing'); w.wait_wake('runner-beat-stale')
    assert (w.own / '.runner-respawns').read_text() == 'unknown\n'
    assert sum(line.startswith('assert ') and 'runner-respawn-failing' in line
               for line in w.alert_calls()) == 1


def publication_two_clears(w):
    w.bind('x'); w.start()
    wait('real initial progress', lambda: (w.own / 'x/.seen').exists())
    retire_old_and_purge(w)
    wait('real drain witness', lambda: fields(w.own / '.runner-beat').get('drained') == 'yes')
    wait('preparation publication drained', lambda: not w.alarm_rows())
    w.stop_watch(); w.spy_alerts(); w.hold_alarm('clear', 'runner-beat-stale')
    for key in ('runner-beat-stale', 'runner-respawn-failing'):
        w.alert('assert', key, 'fixture held occurrence')
    w.env['FM_TEST_ALARM_ONLY'] = '1'; w.start('ingest-bound=60')
    w.alarm_command('sweep')
    wait('first clear held', lambda: (w.root / 'alarm-hold.reached').exists())
    assert [(r[1], r[2]) for r in w.alarm_rows()] == [('runner-beat-stale', 'clear'), ('runner-respawn-failing', 'clear')]
    w.release('alarm-hold')
    wait('both clears without a second sweep', lambda: not w.alarm_rows())
    assert not w.level('runner-beat-stale', runner=True)
    assert not w.level('runner-respawn-failing', runner=True)


def publication_third_failure(w):
    w.bind('x'); w.spy_alerts(); w.hold_alarm('assert', 'runner-beat-stale')
    w.start('run:exit=7,ingest-bound=60')
    wait('earlier publication occupied', lambda: (w.root / 'alarm-hold.reached').exists())
    wait('third failure retained behind publisher', lambda: any(r[1:] == ('runner-respawn-failing', 'assert') for r in w.alarm_rows()))
    assert int((w.own / '.runner-respawns').read_text().split()[0]) >= 3
    assert not w.level('runner-respawn-failing', runner=True)
    w.release('alarm-hold')
    wait('third-failure level published', lambda: w.level('runner-respawn-failing', runner=True))


def publication_failure(w):
    w.bind('x'); w.spy_alerts(); (w.root / 'alarm-fail').touch()
    w.env['FM_TEST_ALARM_ONLY'] = '1'; w.start('ingest-bound=60')
    w.alarm_command('enqueue', 'assert', 'runner-beat-stale')
    w.alarm_command('enqueue', 'clear', 'runner-beat-stale')
    w.call('sync-alarms')
    wait('failed publisher check', lambda: (w.state / '.wake-queue').exists() and 'alarm publication failed' in (w.state / '.wake-queue').read_text())
    w.call('sync-alarms')
    assert w.level('automation-unreadable', bid='publisher')
    assert [r[2] for r in w.alarm_rows()] == ['assert', 'clear']
    assert not w.level('runner-beat-stale', runner=True)
    (w.root / 'alarm-fail').unlink()
    wait('ordered retry succeeds', lambda: not w.alarm_rows())
    events = record(w.own / 'runner-alert-store.json')['events']
    assert [e['action'] for e in events if e['key'] == 'runner-beat-stale'] == ['raised', 'cleared']
    w.call('sync-alarms')
    assert not w.level('automation-unreadable', bid='publisher')


def publication_deadline(w):
    w.bind('x'); w.spy_alerts(); w.hold_alarm('assert', 'runner-beat-stale')
    w.env['FM_TEST_ALARM_ONLY'] = '1'; w.start('ingest-bound=1')
    w.alarm_command('enqueue', 'assert', 'runner-beat-stale')
    wait('real writer reached blocked command', lambda: (w.root / 'alarm-hold.reached').exists())
    wait('deadline failure is visible', lambda: (w.state / '.wake-queue').exists() and 'alarm publication failed' in (w.state / '.wake-queue').read_text())
    # The first writer was terminated; its one-shot hold is not used by the
    # retry. No FIFO release can conceal a missing process-group deadline.
    wait('retained head retries after deadline', lambda: w.level('runner-beat-stale', runner=True))
    wait('deadline retry acknowledged', lambda: not w.alarm_rows())


def publication_lifetime(w):
    w.bind('x'); w.spy_alerts(); w.env['FM_TEST_ALARM_ONLY'] = '1'
    w.env['FM_TEST_ALARM_TRACE'] = '1'
    os.mkfifo(w.root / 'publisher-end')
    w.start('ingest-bound=5,alarm-publisher:after-write:pause=' + str(w.root / 'publisher-end'))
    w.alarm_command('enqueue', 'assert', 'runner-beat-stale')
    hit = w.root / 'publisher-end.reached'
    wait('publisher after native write', hit.exists)
    pid = int(hit.read_text().splitlines()[0].split()[-1]); start = fmt.pid_starttime(pid)
    status = dict(line.split(':', 1) for line in Path('/proc/%s/status' % pid).read_text().splitlines())
    wrapper = int(status['PPid'])
    assert b'fm_owner_notice_alarm.py' in Path('/proc/%s/cmdline' % wrapper).read_bytes()
    if CASE == 'publication_lifetime':
        # Isolate the common whole-publisher deadline from the parent guard.
        os.kill(w.watch.pid, signal.SIGSTOP)
    else:
        # Isolate the parent's TERM/KILL guard from that common timer.
        os.kill(wrapper, signal.SIGSTOP)
        marker = w.state / '.fixture-alarm-term'
        wait('TERM observed before KILL grace', marker.exists, cap=90)
        masks = [int(line.split(':', 1)[1].strip(), 16) for line in marker.read_text().splitlines()]
        assert any(mask & (1 << (signal.SIGTERM - 1)) for mask in masks), 'TERM was not delivered'
    wait('bounded publisher lifetime', lambda: not fmt.identity_alive(pid, start), cap=90)
    if CASE == 'publication_lifetime':
        os.kill(w.watch.pid, signal.SIGCONT)
    else:
        signals = (w.state / '.fixture-alarm-signals').read_text().splitlines()
        assert signals.count('-TERM %s' % wrapper) == 1
        assert signals.count('-KILL %s' % wrapper) == 1
    wait('lifetime failure is visible', lambda: (w.state / '.wake-queue').exists() and 'alarm publication failed' in (w.state / '.wake-queue').read_text())
    assert w.alarm_rows(), 'unacknowledged request was lost on timeout'
    w.stop_watch(); w.start('ingest-bound=5')
    wait('timed-out write replays without reassertion', lambda: not w.alarm_rows())
    assert sum(line.startswith('assert ') and 'runner-beat-stale' in line for line in w.alert_calls()) == 1


def publication_frozen_reader(w):
    import sqlite3
    from fm_owner_notice_alarm import connect
    from fm_owner_notice_store import Owner
    w.bind('x'); w.env['FM_TEST_ALARM_ONLY'] = '1'; w.start()
    w.alarm_command('enqueue', 'assert', 'runner-beat-stale')
    wait('initial transition completed', lambda: w.level('runner-beat-stale', runner=True) and not w.alarm_rows())
    with connect(Owner(str(w.home))) as db:
        try:
            db.execute('UPDATE meta SET root=root WHERE id=1')
        except sqlite3.OperationalError as exc:
            assert 'readonly' in str(exc).lower(), exc
        else:
            raise AssertionError('read-only queue connection permitted mutation')
    os.mkfifo(w.root / 'reader-snapshot')
    env = dict(w.env, FM_OWNER_NOTICE_FAULT=w.env['FM_OWNER_NOTICE_FAULT'] + ',alarm-reader:snapshot:pause=' + str(w.root / 'reader-snapshot'))
    fh = open(w.root / 'publication-reader.log', 'w'); w.files.append(fh)
    reader = subprocess.Popen(['python3', str(ROOT / 'bin/fm_owner_notice_store.py'), 'runner-health', '--home', str(w.home)],
                              env=env, stdout=fh, stderr=fh, start_new_session=True)
    w.processes.append(reader)
    wait('real reader holds a snapshot', lambda: (w.root / 'reader-snapshot.reached').exists())
    for action in ('clear', 'assert'):
        w.alarm_command('enqueue', action, 'runner-beat-stale')
    assert [r[2] for r in w.alarm_rows()] == ['clear', 'assert'], 'reader blocked admission'
    w.release('reader-snapshot'); reader.wait(timeout=15)
    assert reader.returncode == 0
    wait('reader release permits ordered publication', lambda: not w.alarm_rows())
    events = record(w.own / 'runner-alert-store.json')['events']
    assert [e['action'] for e in events if e['key'] == 'runner-beat-stale'] == ['raised', 'cleared', 'raised']


def publication_result_reader(w):
    import fcntl
    from fm_owner_notice_alarm import connect, digest, HEAD, read_result, RESULT_BOUND
    from fm_owner_notice_store import Owner
    w.bind('x'); w.spy_alerts(); w.hold_alarm('assert', 'runner-beat-stale')
    # Parser probes have no latency assertion; all actors share a bound that
    # covers the bounded sequence of adversarial reads on a loaded CI host.
    w.env['FM_OWNER_NOTICE_FAULT'] += ',ingest-bound=600'
    w.env['FM_TEST_ALARM_ONLY'] = '1'; w.start()
    w.alarm_command('enqueue', 'assert', 'runner-beat-stale')
    wait('writer held for result isolation', lambda: (w.root / 'alarm-hold.reached').exists())
    os.kill(w.watch.pid, signal.SIGSTOP)
    w.release('alarm-hold')
    path = w.own / '.runner-alarm-publication/result'
    def committed():
        if not path.exists() or path.stat().st_nlink != 1:
            return False
        with open(w.own / '.runner-alarm-publisher.lock', 'rb') as fh:
            try:
                fcntl.flock(fh, fcntl.LOCK_SH | fcntl.LOCK_NB)
                return True
            except BlockingIOError:
                return False
    wait('committed result and released writer', committed)
    original = path.read_bytes(); result = fmt.parse_canonical(original)
    with connect(Owner(str(w.home))) as db:
        row = db.execute(HEAD).fetchone()
    foreign = digest(Owner(str(w.root / 'other-home')), row)
    wide = dict(result, outcome='failed', reason='\U0001f600' * 512)
    path.write_bytes(fmt.canonical(wide))
    assert read_result(Owner(str(w.home))) == wide, 'valid wide reason exceeded the byte bound'
    # Structurally valid at this reader boundary; correlation belongs to the
    # next layer. Only the encoded-record byte guard rejects it here.
    huge = fmt.canonical(dict(wide, seq=10 ** 3000))
    assert len(huge) > RESULT_BOUND
    path.write_bytes(huge)
    try:
        read_result(Owner(str(w.home)))
    except fmt.Oversize:
        pass
    else:
        raise AssertionError('publication reader ignored its byte bound')
    path.write_bytes(original)
    variants = [b'', b' ', b'\0', b'null', b'{}', original + b'\n', b' ' * (RESULT_BOUND + 1),
                b'[' * 1500 + b'0' + b']' * 1500,
                b'{"schema":"duplicate",' + original[1:],
                fmt.canonical(dict(result, seq=result['seq'] + 1)),
                fmt.canonical(dict(result, seq=True)),
                fmt.canonical(dict(result, request_sha256='0' * 64)),
                fmt.canonical(dict(result, request_sha256=foreign)),
                fmt.canonical(dict(result, outcome='unknown')),
                fmt.canonical(dict(result, reason='inconsistent success')),
                fmt.canonical(dict(result, outcome='failed', reason='\ud800')),
                'directory', 'fifo', 'link', 'unreadable']
    for shape in variants:
        if isinstance(shape, bytes):
            path.write_bytes(shape)
        elif shape == 'unreadable':
            path.chmod(0)
        else:
            path.unlink()
            if shape == 'directory': path.mkdir()
            elif shape == 'fifo': os.mkfifo(path)
            else: path.symlink_to(w.root / 'missing-result')
        try:
            w.call('sync-alarms')
            assert w.level('automation-unreadable', bid='publisher'), shape
            assert w.alarm_rows(), 'unknown result acknowledged a request'
            if isinstance(shape, bytes): assert path.read_bytes() == shape
        finally:
            if shape == 'unreadable': path.chmod(0o600)
            elif shape == 'directory': path.rmdir()
            elif isinstance(shape, str): path.unlink()
            path.write_bytes(original)
        w.call('sync-alarms')
        assert not w.level('automation-unreadable', bid='publisher'), shape
    os.kill(w.watch.pid, signal.SIGCONT)
    wait('repaired result acknowledged', lambda: not w.alarm_rows())
    assert sum(line.startswith('assert ') and 'runner-beat-stale' in line for line in w.alert_calls()) == 1


def publication_advance_failure(w):
    import sqlite3
    w.bind('x'); w.spy_alerts(); (w.root / 'alarm-fail').touch()
    w.env['FM_TEST_ALARM_ONLY'] = '1'
    pause = w.state / '.fixture-alarm-pump-paused'; pause.touch()
    w.start('ingest-bound=60,alarm-advance:after-unlink:errno=EIO')
    w.alarm_command('enqueue', 'assert', 'runner-beat-stale')
    result = wait('native failed publication result', w.publication_result)
    assert result['outcome'] == 'failed'
    w.alarm_command('advance', code=70)
    def failures():
        db = sqlite3.connect(w.own / '.runner-alarms.sqlite3')
        try:
            return db.execute('SELECT problem,since,advance_problem,advance_since FROM meta').fetchone()
        finally:
            db.close()
    both = failures()
    assert both[0] and both[2], both
    w.call('sync-alarms'); w.wait_wake('automation-unreadable')
    w.alarm_command('advance')
    recovered = failures()
    assert recovered[:2] == both[:2] and recovered[2:] == (None, None), recovered
    w.call('sync-alarms')
    assert w.level('automation-unreadable', bid='publisher'), 'cleanup success cleared a writer failure'
    assert w.alarm_rows()
    (w.root / 'alarm-fail').unlink(); pause.unlink()
    w.stop_watch(); w.start('ingest-bound=60')
    wait('writer recovery finally acknowledges request', lambda: not w.alarm_rows())
    w.call('sync-alarms')
    assert not w.level('automation-unreadable', bid='publisher')


def publication_cursor_replay(w):
    w.bind('x'); w.spy_alerts(); w.env['FM_TEST_ALARM_ONLY'] = '1'
    os.mkfifo(w.root / 'cursor-commit')
    w.start('ingest-bound=60,alarm-advance:after-commit:pause=' + str(w.root / 'cursor-commit'))
    w.alarm_command('enqueue', 'assert', 'runner-beat-stale')
    hit = w.root / 'cursor-commit.reached'
    wait('ACK committed before result removal', hit.exists)
    assert not w.alarm_rows()
    path = w.own / '.runner-alarm-publication/result'; original = path.read_bytes()
    pause = w.state / '.fixture-alarm-pump-paused'; pause.touch()
    pid = int(hit.read_text().splitlines()[0].split()[-1])
    os.kill(pid, signal.SIGKILL); w.stop_watch()
    result = fmt.parse_canonical(original)
    for replacement in (dict(result, request_sha256='0' * 64), dict(result, seq=result['seq'] + 1),
                        dict(result, outcome='failed', reason='foreign failed result')):
        path.write_bytes(fmt.canonical(replacement))
        w.call('sync-alarms')
        assert w.level('automation-unreadable', bid='publisher')
        assert path.read_bytes() == fmt.canonical(replacement)
        path.write_bytes(original)
        w.call('sync-alarms')
        assert not w.level('automation-unreadable', bid='publisher')
    pause.unlink(); w.start('ingest-bound=60')
    wait('exact acknowledged result replayed', lambda: not path.exists() and not (w.own / '.runner-alarms.pending').exists())
    assert sum(line.startswith('assert ') and 'runner-beat-stale' in line for line in w.alert_calls()) == 1


def publication_initialization(w):
    import sqlite3
    w.bind('x'); w.env['FM_TEST_ALARM_ONLY'] = '1'
    os.mkfifo(w.root / 'queue-birth'); os.mkfifo(w.root / 'queue-prepared')
    w.start('alarm-initialize:prepared:pause=' + str(w.root / 'queue-prepared')
            + ',o-runner-dirsync:after-link:pause=' + str(w.root / 'queue-birth'))
    token = w.alarm_command('enqueue', 'assert', 'runner-beat-stale', wait_for_acceptance=False)
    wait('private database prepared', lambda: (w.root / 'queue-prepared.reached').exists())
    w.bind('y')  # Real owner temp sweep must preserve the live initializer.
    w.release('queue-prepared')
    hit = w.root / 'queue-birth.reached'
    wait('queue initial publication in progress', hit.exists)
    path = w.own / '.runner-alarms.sqlite3'; original = path.read_bytes()
    assert path.stat().st_nlink == 2
    if CASE == 'publication_initialization_dead':
        pid = int(hit.read_text().splitlines()[0].split()[-1])
        os.kill(pid, signal.SIGKILL)
        w.alarm_finish(token, code=1); w.stop_watch()
        w.call('sync-alarms')
        assert w.level('automation-unreadable', bid='publisher')
        assert path.read_bytes() == original and path.stat().st_nlink == 2
        return
    w.call('sync-alarms')
    assert not w.level('automation-unreadable', bid='publisher'), 'live empty initialization became a false failure'
    db = sqlite3.connect(path)
    try:
        db.execute('INSERT INTO requests(key,action,reason,at) VALUES(?,?,?,?)', ('runner-beat-stale', 'assert', 'foreign in-progress work', int(time.time())))
        db.commit()
    finally:
        db.close()
    bad = path.read_bytes()
    w.call('sync-alarms')
    assert w.level('automation-unreadable', bid='publisher'), 'work was hidden by initialization grace'
    assert path.read_bytes() == bad
    # Only the non-SQL initializer remains paused; all DB probes have exited.
    for suffix in ('-wal', '-shm', '-journal'):
        Path(str(path) + suffix).unlink(missing_ok=True)
    path.write_bytes(original)
    fresh = path.stat()
    os.utime(path, (1, 1))
    w.call('sync-alarms')
    assert w.level('automation-unreadable', bid='publisher'), 'old initialization renewed its grace'
    os.utime(path, ns=(fresh.st_atime_ns, fresh.st_mtime_ns))
    w.call('sync-alarms')
    assert not w.level('automation-unreadable', bid='publisher')
    w.release('queue-birth'); w.alarm_finish(token)
    wait('committed initialization accepts and publishes', lambda: w.level('runner-beat-stale', runner=True) and not w.alarm_rows())


def publication_metadata_directory(w):
    w.bind('x'); w.env['FM_TEST_ALARM_ONLY'] = '1'; w.start()
    temp = w.own / '.tmp'; saved = w.own / '.tmp.fixture-saved'
    foreign = w.root / 'foreign-metadata'; foreign.mkdir()
    os.utime(foreign, (1, 1)); before = foreign.stat().st_mtime_ns
    temp.rename(saved); temp.symlink_to(foreign, target_is_directory=True)
    try:
        w.alarm_command('reserve', code=70)
        assert not (w.own / '.runner-attempt').exists()
        assert foreign.stat().st_mtime_ns == before and not list(foreign.iterdir())
    finally:
        temp.unlink(); saved.rename(temp)
    w.alarm_command('reserve')
    assert fields(w.own / '.runner-attempt')['token']
    w.stop_watch()
    from fm_owner_notice_runtime import publish
    from fm_owner_notice_store import Owner
    owner = Owner(str(w.home))
    target = w.own / 'alias-probe'
    for i, directory in enumerate((w.state, w.own, w.own / '.tmp')):
        backup = directory.with_name(directory.name + '.probe-saved')
        other = w.root / ('foreign-directory-%s' % i); other.mkdir()
        if i == 0: (other / 'owner-notices/.tmp').mkdir(parents=True)
        elif i == 1: (other / '.tmp').mkdir()
        directory.rename(backup); directory.symlink_to(other, target_is_directory=True)
        try:
            try:
                publish(owner, str(target), 'probe\n')
            except (OSError, ValueError):
                pass
            else:
                raise AssertionError('metadata directory alias accepted: ' + str(directory))
            assert not target.exists()
        finally:
            directory.unlink(); backup.rename(directory)
        publish(owner, str(target), 'probe\n')
        assert target.read_text() == 'probe\n'
        target.unlink()


def publication_store(w):
    w.bind('x')
    store = w.own / 'runner-alert-store.json'
    body = ('SCRIPT_DIR=$1; . "$1/fm-wake-lib.sh"; . "$1/fm-owner-notice-run-lib.sh"; '
            'owner_notice_initialize_store "$2" "$3"')
    def initialize(expected='owner-notice-runner', code=0):
        p = subprocess.run(['bash', '-c', body, '_', str(ROOT / 'bin'), str(store), expected],
                           env=w.env, capture_output=True, text=True, timeout=30)
        assert p.returncode == code, (p.returncode, p.stdout, p.stderr)
    initialize()
    assert record(store)['active'] == {}
    status = w.state / 'runner-source.status'
    prepare_body = ('SCRIPT_DIR=$1; . "$1/fm-wake-lib.sh"; . "$1/fm-owner-notice-run-lib.sh"; '
                    'owner_notice_status_file "$2"')
    def prepare(code=0):
        p = subprocess.run(['bash', '-c', prepare_body, '_', str(ROOT / 'bin'), str(status)],
                           env=w.env, capture_output=True, text=True, timeout=20)
        assert p.returncode == code, (p.returncode, p.stdout, p.stderr)
    prepare(); assert status.read_bytes() == b''
    status.write_text('working: fixture\n'); before = status.stat().st_mtime_ns
    prepare(); assert status.read_text() == 'working: fixture\n' and status.stat().st_mtime_ns == before
    status.unlink()
    foreign = w.root / 'foreign-status'; foreign.write_bytes(b'untouched')
    for shape in ('link', 'dangling', 'directory', 'fifo'):
        if shape == 'link': status.symlink_to(foreign)
        elif shape == 'dangling': status.symlink_to(w.root / 'missing-status')
        elif shape == 'directory': status.mkdir()
        else: os.mkfifo(status)
        prepare(code=70)
        assert foreign.read_bytes() == b'untouched' and not (w.root / 'missing-status').exists()
        if shape == 'directory': status.rmdir()
        else: status.unlink()
    prepare()
    for mode in (0, 0o400, 0o200):
        status.chmod(mode)
        prepare(code=70)
        status.chmod(0o600)
    prepare()
    w.alert('assert', 'runner-beat-stale', 'real held level')
    w.alert('ack', 'runner-beat-stale', '600', 'fixture', 'keep acknowledgement')
    original = store.read_bytes(); inode = store.stat().st_ino
    initialize()
    assert store.read_bytes() == original and store.stat().st_ino == inode, 'initialization rewrote existing levels/ACKs'
    legacy = json.loads(original); legacy['schema'] = 'tj-capacity-alerts/v1'
    encoded = fmt.canonical(legacy); store.write_bytes(encoded)
    initialize(code=70)
    assert store.read_bytes() == encoded
    store.write_bytes(original)
    initialize('foreign-id', code=70)
    assert store.read_bytes() == original
    for malformed in (b'not a store', original + original):
        store.write_bytes(malformed)
        initialize(code=70)
        assert store.read_bytes() == malformed
    store.write_bytes(original)
    os.mkfifo(w.root / 'init-lock')
    holder = subprocess.Popen(['bash', '-c',
        '. "$1/fm-wake-lib.sh"; fm_lock_acquire_wait_max "$2.lock" 5 || exit 1; '
        'trap \'fm_lock_release "$2.lock"\' EXIT; : > "$3/init-lock.reached"; '
        'IFS= read -r _ < "$3/init-lock"', '_', str(ROOT / 'bin'), str(store), str(w.root)],
        env=w.env, start_new_session=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    w.processes.append(holder)
    wait('real store lock held', lambda: (w.root / 'init-lock.reached').exists())
    initialize(code=70)  # Refusal is observed, not inferred from a timed absence.
    assert store.read_bytes() == original
    w.release('init-lock'); assert holder.wait(timeout=10) == 0
    initialize()
    assert store.read_bytes() == original and store.stat().st_ino == inode


def publication_admission(w):
    import sqlite3
    w.bind('x'); w.env['FM_TEST_ALARM_ONLY'] = '1'; w.start()
    w.alarm_command('enqueue', 'assert', 'runner-beat-stale')
    wait('baseline acknowledged', lambda: w.level('runner-beat-stale', runner=True) and not w.alarm_rows()
         and not (w.own / '.runner-alarms.pending').exists())
    w.stop_watch()
    path = w.own / '.runner-alarms.sqlite3'
    for shape in ('sequence', 'head', 'tail'):
        db = sqlite3.connect(path)
        try:
            cursor = db.execute('SELECT cursor FROM meta').fetchone()[0]
            if shape == 'sequence':
                db.execute("UPDATE sqlite_sequence SET seq=0 WHERE name='requests'")
            else:
                db.execute("INSERT INTO requests(key,action,reason,at) VALUES(?,'assert',?,?)",
                           ('runner-beat-stale' if shape == 'tail' else 'runner-respawn-failing',
                            'valid' if shape == 'tail' else '', int(time.time())))
                if shape == 'tail':
                    db.execute("INSERT INTO requests(key,action,reason,at) VALUES('runner-beat-stale','assert','',?)",
                               (int(time.time()),))
            db.commit()
        finally:
            db.close()
        before = w.alarm_rows()
        w.start()
        # Same action makes a malformed tail otherwise eligible for dedup;
        # sequence reuse has no pending row or other failing predicate.
        w.alarm_command('enqueue', 'assert', 'runner-beat-stale', code=1)
        assert w.alarm_rows() == before, shape
        assert not (w.own / '.runner-alarms.pending').exists(), shape
        w.stop_watch()
        db = sqlite3.connect(path)
        try:
            assert db.execute('SELECT cursor FROM meta').fetchone()[0] == cursor
            db.execute('DELETE FROM requests')
            db.execute("UPDATE sqlite_sequence SET seq=? WHERE name='requests'", (cursor,))
            db.commit()
        finally:
            db.close()
    w.start()
    w.alarm_command('enqueue', 'clear', 'runner-beat-stale')
    wait('repaired admission publishes', lambda: not w.level('runner-beat-stale', runner=True)
         and not w.alarm_rows() and not (w.own / '.runner-alarms.pending').exists())


def whole_runtime(w, mode='old'):
    """Fault every python3 invocation and propagated sys.executable, not one verb.

    This controls version/capability reporting in the installed interpreter;
    it is not evidence from an installed historical Python binary.
    """
    shim = w.root / 'runtime-path'; shim.mkdir()
    fault = w.root / 'runtime-fault'; fault.write_text(mode)
    wrapper = shim / 'python3'
    wrapper.write_text('#!' + sys.executable + '\n' +
        'import os,runpy,sys\nfrom pathlib import Path\n' +
        'fault=Path(' + repr(str(fault)) + ')\n' +
        'mode=fault.read_text() if fault.exists() else "native"\n' +
        'sys.executable=os.path.abspath(__file__)\nargs=sys.argv[1:]\n' +
        'if args and os.path.basename(args[0]) in ("fm_owner_notice_store.py","fm_owner_notice_alarm.py"):\n' +
        '    with open(' + repr(str(w.root / 'runtime-calls')) + ',"a") as f: f.write(" ".join(args)+"\\n")\n' +
        'if mode=="old": sys.version_info=(3,10,9,"final",0)\n' +
        'elif mode=="api":\n'
        '    import sqlite3\n'
        '    class MissingAPI(sqlite3.Connection): getlimit=None\n'
        '    sqlite3.Connection=MissingAPI\n' +
        'elif mode=="sqlite-missing": sys.modules["sqlite3"]=None\n' +
        'elif mode.startswith("probe-") and args and os.path.basename(args[0])=="fm_owner_notice_runtime.py":\n'
        '    if mode=="probe-error": print("ready"); sys.exit(1)\n'
        '    if mode=="probe-empty": sys.exit(0)\n'
        '    if mode=="probe-malformed": print("partial"); sys.exit(78)\n'
        '    if mode=="probe-nul": sys.stdout.buffer.write(b"ready\\n\\x00"); sys.exit(0)\n'
        '    if mode=="probe-partial": sys.stdout.write("ready"); sys.exit(0)\n'
        '    if mode=="probe-extra": print("ready\\n"); sys.exit(0)\n'
        '    if mode=="probe-large": print("r"*2048); sys.exit(0)\n' +
        'if args[0]=="-c":\n'
        '    sys.argv=["-c"]+args[2:]; exec(compile(args[1],"<string>","exec"),{"__name__":"__main__"})\n' +
        'elif args[0]=="-m":\n'
        '    sys.argv=args[1:]; runpy.run_module(args[1],run_name="__main__",alter_sys=True)\n' +
        'else:\n'
        '    sys.path.insert(0,os.path.dirname(args[0])); sys.argv=args\n'
        '    runpy.run_path(args[0],run_name="__main__")\n')
    wrapper.chmod(0o755)
    w.env['PATH'] = str(shim) + os.pathsep + w.env['PATH']
    return fault


def runtime_owner(w):
    w.bind('x')
    if CASE != 'runtime_work':
        retire_old_and_purge(w)
    else:
        w.envelope('x', 'one')
    preserved = {}
    if CASE == 'runtime_pending':
        w.env['FM_TEST_START_ONLY'] = '1'
        paused = w.state / '.fixture-alarm-pump-paused'; paused.touch()
        w.start()
        w.alarm_command('queue-only', 'assert', 'runner-respawn-failing', 'accepted before runtime outage')
        w.stop_watch()
        w.env.pop('FM_TEST_START_ONLY'); paused.unlink()
        assert (w.own / '.runner-alarms.pending').exists()
        for name in ('.runner-alarms.sqlite3', '.runner-alarms.sqlite3-wal', '.runner-alarms.sqlite3-shm',
                     '.runner-alarms.pending', '.runner-alarm-publisher.lock'):
            path = w.own / name
            if path.exists(): preserved[path] = path.read_bytes()
    if CASE == 'runtime_unknown':
        path = w.own / '.runner-respawns'; path.write_bytes(b'unknown\n')
        preserved[path] = path.read_bytes()
    mode = {'runtime_api': 'api', 'runtime_sqlite_missing': 'sqlite-missing',
            'runtime_probe_error': 'probe-error'}.get(CASE, 'old')
    fault = whole_runtime(w, mode)
    w.start(); w.sweeps()
    level = w.level('runner-runtime-unavailable', runner=True)
    assert level, 'runtime refusal was not held in its native store'
    notices = [level['reason']]
    raised = lambda: [e for e in record(w.own / 'runner-alert-store.json')['events']
                      if e['key'] == 'runner-runtime-unavailable' and e['action'] == 'raised']
    assert len(raised()) == 1, 'unchanged runtime condition repeated its occurrence'
    assert not (w.root / 'runtime-calls').exists(), 'unsupported runtime reached an owner automation command'
    if mode == 'probe-error':
        assert 'runtime check failed (interpreter version unavailable)' in notices[0]
    else:
        version = '3.10.9' if mode == 'old' else '.'.join(str(n) for n in sys.version_info[:3])
        assert 'unsupported runtime: Python ' + version in notices[0]
        assert 'Python 3.11+' in notices[0] and 'Connection.setlimit/getlimit' in notices[0]
    assert not w.wake_sources('alarm publication failed')
    assert not w.wake_sources('repair its publication queue/store')
    assert not (w.own / '.runner-attempt').exists()
    if CASE == 'runtime_work':
        assert not (w.own / 'x/receipts/one').exists()
    for path, raw in preserved.items():
        assert path.read_bytes() == raw, ('unsupported runtime changed obligation', path)
    if CASE != 'runtime_pending':
        assert not (w.own / '.runner-alarms.sqlite3').exists()
    if mode == 'probe-error':
        for bad in ('probe-empty', 'probe-malformed', 'probe-nul', 'probe-partial', 'probe-extra', 'probe-large'):
            fault.write_text(bad); w.sweeps()
            assert w.level('runner-runtime-unavailable', runner=True)['reason'] == notices[0]
            assert len(raised()) == 1
            assert not w.wake_sources('owner runtime recovered'), 'malformed probe granted recovery'
        fault.write_text('old')
        wait('changed runtime cause held', lambda: 'Python 3.10.9' in
             w.level('runner-runtime-unavailable', runner=True)['reason'])
        w.sweeps()
        assert len(raised()) == 1, 'changed diagnosis restarted the same outage'
        assert w.level('runner-runtime-unavailable', runner=True)['since'] == level['since']
    fault.unlink()
    w.wait_wake('owner runtime recovered')
    if CASE == 'runtime_work':
        w.delivered('x', 'one')
    elif CASE == 'runtime_pending':
        wait('accepted request processed after runtime repair', lambda: any(
            e['action'] == 'raised' and e['key'] == 'runner-respawn-failing'
            for e in (record(w.own / 'runner-alert-store.json') or {}).get('events', [])))
        wait('pending transitions drained after runtime repair', lambda: not (w.own / '.runner-alarms.pending').exists())
    elif CASE == 'runtime_unknown':
        w.wait_wake('runner-respawn-failing')
        path = w.own / '.runner-respawns'
        assert path.read_bytes() == b'unknown\n', 'runtime repair overwrote unknown history'
        path.write_bytes(b'0 0\n')
        wait('source repair clears its failure', lambda: not w.level('runner-respawn-failing', runner=True))
    else:
        w.sweeps()
        assert not (w.own / '.runner-attempt').exists(), 'supported idle repair spawned work'
        assert not w.level('runner-beat-stale', runner=True)
        assert not (w.own / '.runner-alarms.sqlite3').exists()
    assert len(w.wake_sources('owner runtime recovered')) == 1
    assert not w.level('runner-runtime-unavailable', runner=True)


def runtime_changed(w):
    w.bind('x'); fault = whole_runtime(w, 'native')
    w.env['FM_TEST_START_ONLY'] = '1'; w.start()
    w.alarm_command('runtime-check')
    # Interpreter replacement after a positive probe, before a command.
    # Automatic slow sweeps are off: only the failure-path re-probe can see it.
    fault.write_text('old')
    w.alarm_command('enqueue', 'assert', 'runner-respawn-failing', code=1)
    notes = w.level('runner-runtime-unavailable', runner=True)
    assert notes and 'unsupported runtime: Python 3.10.9' in notes['reason'], notes
    assert not w.wake_sources('alarm publication failed')
    assert not (w.own / '.runner-alarms.sqlite3').exists()
    calls = (w.root / 'runtime-calls').read_bytes()
    for _ in range(3):
        w.alarm_command('enqueue', 'assert', 'runner-respawn-failing', code=1)
    assert (w.root / 'runtime-calls').read_bytes() == calls, 'cached runtime refusal retried publication'
    assert w.level('runner-runtime-unavailable', runner=True) == notes
    fault.unlink(); w.alarm_command('runtime-check')
    assert len(w.wake_sources('owner runtime recovered')) == 1
    w.alarm_command('enqueue', 'assert', 'runner-respawn-failing')
    wait('publication works after runtime repair', lambda: w.level('runner-respawn-failing', runner=True))


def runtime_manual_routing(w, fault):
    # U1 uses routing files as fallback only when a binding cannot be read.
    # Keep a separate healthy binding so this source cannot be confused with
    # the independent per-binding failure or with automation's stricter reader.
    w.bind('route'); w.call('retire', 'route')
    files = [w.own / '.bindings.list', w.own / '.retired.list']
    good = {path: path.read_bytes() for path in files}
    modes = {path: path.stat().st_mode & 0o777 for path in files}
    assert all(good.values()), 'fixture needs nonempty active AND retired routing'
    binding = w.own / 'bindings/route.json'; original_binding = binding.read_bytes()
    route = ('routing-unreadable', 'all')
    unavailable_binding = ('binding-unreadable', 'route')
    unavailable_runtime = ('automation-unreadable', 'runtime')

    def snapshot(home=None):
        out = w.root / 'manual-routing-wanted.json'
        p = subprocess.run(['python3', str(ROOT / 'bin/fm_owner_notice_store.py'), 'alarms',
                            '--home', str(home or w.home), '--out', str(out)], env=w.env,
                           capture_output=True, text=True, timeout=40)
        assert p.returncode == 0, (p.stdout, p.stderr)
        return {(v['kind'], v['subject']) for v in record(out).values()}, json.loads(p.stdout)['complete']

    # An existing empty U1 owner still has only its runtime prerequisite; empty
    # protocol routing is not an additional alarm, and no automation DB opens.
    empty = w.root / 'manual-empty-home'
    empty_root = empty / 'state/owner-notices'
    (empty_root / 'bindings').mkdir(parents=True)
    for name in ('.bindings.list', '.retired.list'): (empty_root / name).touch()
    levels, complete = snapshot(empty)
    assert levels == {unavailable_runtime} and complete is False, levels
    assert not (empty_root / '.runner-alarms.sqlite3').exists()

    binding.write_bytes(b'{')
    for empty_lists in (True, False):
        for path in files: path.write_bytes(b'' if empty_lists else good[path])
        levels, complete = snapshot()
        assert unavailable_binding in levels and unavailable_runtime in levels and not complete
        assert route not in levels, ('healthy fallback diagnosed as unknown', empty_lists, levels)
        w.call('sync-alarms')
        assert not w.level(*route)
    binding.write_bytes(original_binding)
    fault.unlink(); assert json.loads(w.call('sync-alarms'))['complete'] is True
    assert not w.level(*route)
    fault.write_text('old')

    for path in files:
        for shape in ('malformed', 'missing', 'unreadable'):
            # Start without a pre-held routing level: only NEW derivation can
            # satisfy the assertion. Every other routing input is valid.
            assert not w.level(*route)
            binding.write_bytes(b'{')
            if shape == 'malformed': path.write_bytes(b'bad row\n')
            elif shape == 'missing': path.unlink()
            else: path.chmod(0)
            levels, complete = snapshot()
            assert route in levels and unavailable_binding in levels and unavailable_runtime in levels and not complete, (path, shape, levels)
            w.call('sync-alarms')
            assert w.level(*route), ('new U1 routing source was suppressed', path, shape)
            assert binding.read_bytes() == b'{'
            if shape == 'missing': assert not path.exists()
            elif shape == 'malformed': assert path.read_bytes() == b'bad row\n'
            else: assert path.stat().st_mode & 0o777 == 0
            for other in files:
                if other != path: assert other.read_bytes() == good[other]
            if shape == 'unreadable': path.chmod(modes[path])
            path.write_bytes(good[path]); path.chmod(modes[path])
            levels, complete = snapshot()
            assert route not in levels and unavailable_binding in levels and not complete
            w.call('sync-alarms')
            assert w.level(*route), 'an incomplete projection cleared a previously held level'
            binding.write_bytes(original_binding)
            levels, complete = snapshot()
            assert route not in levels and unavailable_binding not in levels and unavailable_runtime in levels and not complete
            fault.unlink()
            assert json.loads(w.call('sync-alarms'))['complete'] is True
            assert not w.level(*route) and not w.level(*unavailable_binding) and not w.level(*unavailable_runtime)
            fault.write_text('old')
    assert not (w.own / '.runner-alarms.sqlite3').exists()


def runtime_manual(w):
    w.bind('x'); w.envelope('x', 'one')
    fault = whole_runtime(w)
    w.call('ingest', 'x'); w.delivered('x', 'one')
    alarm = w.level('automation-unreadable', 'runtime')
    assert alarm and 'Python 3.10.9' in alarm['reason'] and 'Python 3.11+' in alarm['reason'], alarm
    assert not w.level('automation-unreadable', 'publisher')
    assert not (w.own / '.runner-alarms.sqlite3').exists()
    assert not (w.own / '.runner-attempt').exists()
    w.call('show', 'x', 'one')
    w.call('consume', 'x', 'one')
    assert not w.level('refused', 'x/one') and not w.level('unconsumed', 'x/one')
    runtime_manual_routing(w, fault)
    # Derive NEW protocol conditions, not just preserve old held rows. Only
    # automation sources may be skipped: real manual ingest still refuses a
    # disallowed kind and projects that new refusal on the old runtime.
    bad = w.envelope('x', 'bad')
    envelope = json.loads(bad.read_bytes()); envelope['kind'] = 'not-allowed'
    bad.write_bytes(fmt.canonical(envelope))
    w.envelope('x', 'two'); w.call('ingest', 'x'); w.delivered('x', 'two')
    assert w.level('refused', 'x/bad'), 'old runtime suppressed a newly refused envelope'
    assert not w.level('refused', 'x/two'), 'healthy manual delivery was refused'
    current = record(w.own / 'x/current/two.json')
    w.env['FM_OWNER_NOTICE_NOW'] = str(fmt.parse_iso(current['delivered_at']) + 3601)
    w.call('sync-alarms')
    assert w.level('unconsumed', 'x/two'), 'old runtime suppressed a new delivery deadline'
    # A missing SQLite module must not break manual projection by importing
    # the automation publisher before its capability refusal.
    fault.write_text('sqlite-missing')
    w.call('sync-alarms')
    assert w.level('automation-unreadable', 'runtime')
    assert w.level('refused', 'x/bad') and w.level('unconsumed', 'x/two')
    fault.unlink(); w.call('sync-alarms')
    assert not w.level('automation-unreadable', 'runtime')
    assert w.level('refused', 'x/bad') and w.level('unconsumed', 'x/two')
    w.call('consume', 'x', 'two')
    assert not w.level('unconsumed', 'x/two'), 'healthy manual recovery retained a protocol level'


def start_authority(w):
    if CASE == 'start_authority_alias':
        alias = w.root / 'home-alias'; alias.symlink_to(w.home, target_is_directory=True)
        w.env['FM_HOME'] = str(alias); w.env['HOME'] = str(alias)
    w.bind('x'); w.env['FM_TEST_START_ONLY'] = '1'
    w.env['FM_TEST_START_PROOF'] = str(ROOT / 'tests/lib/owner-notice-start-proof.sh')
    w.start()
    # Actual engine parent, but NOT a child of the recorded watcher. A valid
    # reservation alone does not authorize a direct call to either phase.
    w.alarm_command('reserve')
    token = (w.state / '.fixture-reserve-output').read_text().strip()
    for install in (False, True):
        p = subprocess.run([sys.executable, str(ROOT / 'bin/fm_owner_notice_store.py'),
                            'start-run', '--home', str(w.home), '--pid', str(os.getpid()),
                            '--watcher-pid', str(w.watch.pid), '--attempt', token] +
                           (['--install'] if install else []), env=w.env, capture_output=True, text=True)
        assert p.returncode == 70 and 'unknown' in p.stdout, (p.stdout, p.stderr)
        assert not (w.own / '.runner-starting').exists() and not (w.own / '.runner').exists()
    for mode in ('bad-watch', 'token', 'lockless', 'foreign-lock', 'stale-lock',
                 'missing-lock-start', 'parent-before', 'parent-change'):
        w.alarm_command('start-proof', mode, code=70)
        output = (w.state / '.fixture-start-proof-output').read_text()
        assert 'unknown' in output, (mode, output)
        assert not (w.own / '.runner').exists(), mode
        assert not (w.own / '.runner-starting').exists(), mode
    # Genuine watcher-child evidence is permitted BEFORE it owns a runner lock.
    w.alarm_command('start-proof', 'preinstall')
    assert list((w.own / '.runner-starting').iterdir())
    assert not (w.own / '.runner.lock').exists() and not (w.own / '.runner').exists()
    w.alarm_command('start-proof', 'install')
    assert fields(w.own / '.runner')['watcher_pid'] == str(w.watch.pid)
    assert not list((w.own / '.runner-starting').iterdir())
    # Sibling mutation surface: a loop must use the actual runner mutex and
    # this front's installed identity, not an arbitrary caller-owned lock.
    for mode, refusal in (('loop-foreign', 'runner-lock-mismatch'),
                          ('loop-uninstalled', 'runner-installation-mismatch'),
                          ('loop-identity', 'runner-start-authority-unavailable')):
        w.alarm_command('start-proof', mode, code=70)
        assert refusal in (w.state / '.fixture-start-proof-output').read_text()


def start_authority_bound(w):
    w.bind('x'); w.spy_alerts()
    wake = w.script_dir / 'fm-wake-lib.sh'; assert wake.is_symlink(); wake.unlink()
    wake.write_text('. ' + repr(str(ROOT / 'bin/fm-wake-lib.sh')) + '\n' + '''
if [ "${_FM_TEST_WATCHER_WRAPPED:-0}" -eq 0 ]; then
  definition=$(declare -f fm_watcher_healthy)
  eval "${definition/fm_watcher_healthy/fixture_watcher_healthy}"
  fm_watcher_healthy() {
    if [ "${FM_TEST_AUTH_STALL:-0}" -eq 1 ]; then
      : > "$FM_HOME/state/.fixture-proof-bound.reached"
      IFS= read -r _ < "$FM_HOME/state/.fixture-proof-bound"
      return 70
    fi
    fixture_watcher_healthy "$@"
  }
  _FM_TEST_WATCHER_WRAPPED=1
fi
''')
    os.mkfifo(w.state / '.fixture-proof-bound')
    w.env['FM_TEST_START_ONLY'] = '1'
    w.env['FM_TEST_START_PROOF'] = str(ROOT / 'tests/lib/owner-notice-start-proof.sh')
    w.start(); w.alarm_command('start-proof', 'proof-bound', code=70)
    assert (w.state / '.fixture-proof-bound.reached').exists()
    answer = record(w.state / '.fixture-start-proof-output')
    assert answer['code'] == 'runner-start-authority-unavailable' and answer['exit_code'] == 124, answer
    assert not (w.own / '.runner-starting').exists() and not (w.own / '.runner').exists()
    w.alarm_command('start-proof', 'install')
    assert fields(w.own / '.runner')['watcher_pid'] == str(w.watch.pid)


def native_level(w, action, reason, pid, start, pause=False):
    script = '''SCRIPT_DIR=$1; FM_HOME=$2; STATE=$2/state
. "$SCRIPT_DIR/fm-wake-lib.sh"
. "$SCRIPT_DIR/fm-owner-notice-run-lib.sh"
'''
    if pause:
        # Acquire the REAL native lock, then stop at its return boundary. This
        # isolates authority-after-serialization from the other identity guard.
        if pause == 'initialize':
            script += '''definition=$(declare -f fm_alert_store_initialize)
eval "${definition/fm_alert_store_initialize/fixture_initialize}"
fm_alert_store_initialize() {
  : > "$FM_HOME/state/.fixture-native-locked"
  IFS= read -r _ < "$FM_HOME/state/.fixture-native-release" || return 70
  fixture_initialize "$@"
}
'''
        else:
            script += '''definition=$(declare -f fm_lock_acquire_wait_max)
eval "${definition/fm_lock_acquire_wait_max/fixture_lock_acquire}"
fm_lock_acquire_wait_max() {
  fixture_lock_acquire "$@" || return $?
  : > "$FM_HOME/state/.fixture-native-locked"
  IFS= read -r _ < "$FM_HOME/state/.fixture-native-release" || return 70
}
'''
    script += 'owner_notice_runtime_level "$3" "$4" "$5" "$6"\n'
    fh = open(w.root / ('native-%d.log' % len(w.processes)), 'w'); w.files.append(fh)
    p = subprocess.Popen(['bash', '-c', script, '_', str(w.script_dir), str(w.home),
                          action, reason, str(pid), start], env=w.env,
                         stdout=fh, stderr=fh, start_new_session=True)
    w.processes.append(p)
    return p


def runtime_restart(w):
    w.bind('x'); retire_old_and_purge(w)
    w.env['FM_TEST_START_ONLY'] = '1'; fault = whole_runtime(w)
    w.start(); w.alarm_command('runtime-check', code=1)
    store = w.own / 'runner-alert-store.json'
    level = w.level('runner-runtime-unavailable', runner=True); assert level
    def native(*args):
        p = subprocess.run(['bash', str(ROOT / 'bin/fm-alert-store.sh'), *args], env=w.env,
                           capture_output=True, text=True, timeout=40)
        assert p.returncode == 0, (args, p.stdout, p.stderr)
    native('tick')
    status = w.state / 'owner-notice-runner.status'
    assert 'blocked [key=runner-runtime-unavailable]' in status.read_text()
    status.write_text('working: replacement has not repaired the interpreter\n')
    native('tick')
    assert 'blocked [key=runner-runtime-unavailable]' in status.read_text(), 'relaunch closed the held runtime level'
    native('ack', str(store), 'owner-notice-runner', 'runner-runtime-unavailable', '300', 'fixture', 'ack is not repair')
    ack = record(store)['acks']['runner-runtime-unavailable']
    w.stop_watch(); w.start(); w.alarm_command('runtime-check', code=1)
    assert w.level('runner-runtime-unavailable', runner=True)['since'] == level['since']
    assert record(store)['acks']['runner-runtime-unavailable'] == ack
    assert len([e for e in record(store)['events'] if e['action'] == 'raised']) == 1
    assert not (w.root / 'runtime-calls').exists()
    # A new, supported watcher must clear an outage it never observed itself.
    w.stop_watch(); fault.unlink(); w.start(); w.alarm_command('runtime-check')
    assert not w.level('runner-runtime-unavailable', runner=True)
    assert not (w.own / '.runner-alarms.sqlite3').exists(), 'runtime repair depended on the FIFO'


def runtime_overlap(w):
    w.bind('x'); w.env['FM_TEST_START_ONLY'] = '1'; w.start()
    w.alarm_command('enqueue', 'assert', 'runner-respawn-failing', 'independent FIFO condition')
    wait('FIFO source held', lambda: w.level('runner-respawn-failing', runner=True) and not w.alarm_rows())
    old = w.watch
    start = (w.state / '.watch.lock/pid-start').read_text().strip()
    # Isolate the start-identity guard: current watcher PID and healthy lock,
    # otherwise valid command, but an identity from a different incarnation.
    before = (w.own / 'runner-alert-store.json').read_bytes()
    p = native_level(w, 'assert', 'wrong incarnation', old.pid, 'proc-starttime=0')
    assert p.wait(timeout=20) == 70
    assert (w.own / 'runner-alert-store.json').read_bytes() == before
    os.mkfifo(w.state / '.fixture-native-release')
    os.mkfifo(w.state / '.fixture-handoff')
    p = native_level(w, 'assert', 'obsolete watcher generation', old.pid, start, pause=True)
    wait('runtime writer owns native lock', lambda: (w.state / '.fixture-native-locked').exists())
    w.alarm_command('handoff', wait_for_acceptance=False)
    wait('old watcher released authority but lives', lambda: (w.state / '.fixture-handoff.reached').exists())
    assert old.poll() is None and fmt.identity_alive(old.pid, start.split('=', 1)[1])
    w.start()
    with open(w.state / '.fixture-native-release', 'w') as release: release.write('continue\n')
    assert p.wait(timeout=20) == 70, 'old generation wrote after losing watcher authority'
    assert (w.own / 'runner-alert-store.json').read_bytes() == before
    assert w.level('runner-respawn-failing', runner=True), 'runtime writer altered the FIFO key'
    new_start = (w.state / '.watch.lock/pid-start').read_text().strip()
    p = native_level(w, 'assert', 'current generation outage', w.watch.pid, new_start)
    assert p.wait(timeout=20) == 0 and w.level('runner-runtime-unavailable', runner=True)
    w.alarm_command('runtime-check')
    assert not w.level('runner-runtime-unavailable', runner=True)
    assert w.level('runner-respawn-failing', runner=True)
    with open(w.state / '.fixture-handoff', 'w') as release: release.write('exit\n')
    assert old.wait(timeout=10) == 0


def runtime_first_publish(w):
    w.bind('x'); w.spy_alerts(); w.env['FM_TEST_START_ONLY'] = '1'
    wake = w.script_dir / 'fm-wake-lib.sh'; assert wake.is_symlink(); wake.unlink()
    wake.write_text('. ' + repr(str(ROOT / 'bin/fm-wake-lib.sh')) + '\n' + '''
if [ "${_FM_TEST_LOCK_WRAPPED:-0}" -eq 0 ]; then
  definition=$(declare -f fm_lock_acquire_wait_max)
  eval "${definition/fm_lock_acquire_wait_max/fixture_acquire}"
  fm_lock_acquire_wait_max() {
    if [ "$1" = "$FM_HOME/state/owner-notices/runner-alert-store.json.lock" ]; then
      : > "$FM_HOME/state/.fixture-native-attempt"
    fi
    fixture_acquire "$@"
  }
  _FM_TEST_LOCK_WRAPPED=1
fi
''')
    w.start(); old = w.watch
    start = (w.state / '.watch.lock/pid-start').read_text().strip()
    os.mkfifo(w.state / '.fixture-native-release'); os.mkfifo(w.state / '.fixture-handoff')
    p = native_level(w, 'assert', 'old in-flight first publication', old.pid, start, pause='initialize')
    wait('writer passed authority under lock before initialization', lambda: (w.state / '.fixture-native-locked').exists())
    assert not (w.own / 'runner-alert-store.json').exists()
    (w.state / '.fixture-native-attempt').unlink()
    w.alarm_command('handoff', wait_for_acceptance=False)
    wait('old watcher handed off', lambda: (w.state / '.fixture-handoff.reached').exists())
    w.start()
    token = w.alarm_command('runtime-check', wait_for_acceptance=False)
    # Absence of the store is NOT proof of no obligation when its writer lock
    # is held. The replacement must serialize behind the already-proved write.
    wait('replacement attempts native serialization', lambda: (w.state / '.fixture-native-attempt').exists())
    with open(w.state / '.fixture-native-release', 'w') as release: release.write('publish\n')
    assert p.wait(timeout=20) == 0
    w.alarm_finish(token)
    assert not w.level('runner-runtime-unavailable', runner=True)
    events = [e['action'] for e in record(w.own / 'runner-alert-store.json')['events']
              if e['key'] == 'runner-runtime-unavailable']
    assert events == ['raised', 'cleared'], events
    assert not (w.own / '.runner-alarms.sqlite3').exists()
    with open(w.state / '.fixture-handoff', 'w') as release: release.write('exit\n')
    assert old.wait(timeout=10) == 0


def runtime_native_failure(w):
    w.bind('x'); w.env['FM_TEST_START_ONLY'] = '1'; w.env['FM_CHECK_TIMEOUT'] = '5'
    fault = whole_runtime(w, 'native'); w.start()
    w.alarm_command('enqueue', 'assert', 'runner-respawn-failing', 'independent condition')
    wait('baseline native writer finished', lambda: w.level('runner-respawn-failing', runner=True) and not w.alarm_rows())
    store = w.own / 'runner-alert-store.json'; before = store.read_bytes(); inode = store.stat().st_ino
    w.alarm_command('runtime-check')
    assert store.read_bytes() == before and store.stat().st_ino == inode, 'absent runtime key rewrote unrelated state'
    os.mkfifo(w.root / 'runtime-store-lock')
    holder = subprocess.Popen(['bash', '-c',
        '. "$1/fm-wake-lib.sh"; fm_lock_acquire_wait_max "$2.lock" 5 || exit 1; '
        'trap \'fm_lock_release "$2.lock"\' EXIT; : > "$3/runtime-store-lock.reached"; '
        'IFS= read -r _ < "$3/runtime-store-lock"', '_', str(ROOT / 'bin'), str(store), str(w.root)],
        env=w.env, start_new_session=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    w.processes.append(holder)
    wait('native store writer lock held', lambda: (w.root / 'runtime-store-lock.reached').exists())
    # Cold supported admission must not reconcile through a busy native writer.
    # Removing only the forced-probe gate produces a runtime publication failure
    # before accepting this command, without relying on a wall-clock assertion.
    w.stop_watch(); w.start()
    w.alarm_command('enqueue', 'assert', 'runner-beat-stale', 'accepted while native writer is busy')
    assert not w.wake_sources('runtime level publication failed')
    assert any(row[1] == 'runner-beat-stale' for row in w.alarm_rows())
    fault.write_text('old')
    for _ in range(2):
        w.alarm_command('runtime-check', code=1)
        assert store.read_bytes() == before
    notes = w.wake_sources('runtime level publication failed')
    assert len(notes) == 1 and 'exit 124' in notes[0] and 'Python 3.10.9' in notes[0], notes
    assert not w.level('runner-runtime-unavailable', runner=True)
    w.release('runtime-store-lock'); assert holder.wait(timeout=10) == 0
    w.alarm_command('runtime-check', code=1)
    assert w.level('runner-runtime-unavailable', runner=True)
    assert len(w.wake_sources('native runtime level reconciled')) == 1
    assert not w.wake_sources('owner runtime recovered'), 'writer repair falsely repaired the runtime'
    fault.unlink(); w.alarm_command('runtime-check')
    assert not w.level('runner-runtime-unavailable', runner=True)
    assert w.level('runner-respawn-failing', runner=True)
    w.alarm_command('pump-next')
    wait('busy-writer admission is still delivered', lambda: w.level('runner-beat-stale', runner=True) and not w.alarm_rows())


def runtime_native_paths(w):
    w.bind('x'); w.env['FM_TEST_START_ONLY'] = '1'; w.start()
    start = (w.state / '.watch.lock/pid-start').read_text().strip()
    for shape in ('symlink', 'dangling', 'file', 'fifo', 'mode'):
        saved = w.state / 'saved-owner'; w.own.rename(saved)
        try:
            if shape == 'symlink': w.own.symlink_to(saved, target_is_directory=True)
            elif shape == 'dangling': w.own.symlink_to(w.state / 'missing-owner')
            elif shape == 'file': w.own.touch()
            elif shape == 'fifo': os.mkfifo(w.own)
            else: w.own.mkdir(); w.own.chmod(0)
            p = native_level(w, 'assert', 'invalid directory', w.watch.pid, start)
            assert p.wait(timeout=20) == 70, shape
            assert not (saved / 'runner-alert-store.json').exists(), shape
        finally:
            if shape == 'mode': w.own.chmod(0o700); w.own.rmdir()
            else: w.own.unlink()
            saved.rename(w.own)
    p = native_level(w, 'assert', 'valid native directory', w.watch.pid, start)
    assert p.wait(timeout=20) == 0 and w.level('runner-runtime-unavailable', runner=True)
    w.alarm_command('runtime-check')
    assert not w.level('runner-runtime-unavailable', runner=True)


def publication_runtime(w):
    # Controlled interpreter/capability loss, not a claim to execute Python 3.9.
    launcher = '''import runpy,sqlite3,sys
root,mode,script=sys.argv[1:4]
sys.path.insert(0,root+'/bin')
if mode in ('3.9','3.10'):
    sys.version_info=(3,int(mode.split('.')[1]),0,'final',0)
elif mode in ('setlimit','getlimit'):
    class MissingAPI(sqlite3.Connection): pass
    setattr(MissingAPI,mode,None)
    sqlite3.Connection=MissingAPI
elif mode.startswith('SQLITE_LIMIT_'):
    delattr(sqlite3,mode)
elif mode=='boolean-limit':
    sqlite3.SQLITE_LIMIT_LENGTH=False
if script.endswith('/require-only'):
    import fm_owner_notice_format as fmt
    from fm_owner_notice_runtime import require_automation_runtime
    try: require_automation_runtime()
    except fmt.FormatError as error:
        print(str(error)); sys.exit(70)
    sys.exit(0)
sys.argv=[script]+sys.argv[4:]
runpy.run_path(script,run_name='__main__')
'''
    def probe(mode, script, *args):
        return subprocess.run([sys.executable, '-c', launcher, str(ROOT), mode,
                               str(ROOT / 'bin' / script), *args], env=w.env,
                              capture_output=True, text=True, timeout=20)
    for mode in ('3.9', '3.10', 'setlimit', 'getlimit', 'SQLITE_LIMIT_LENGTH', 'SQLITE_LIMIT_SQL_LENGTH', 'boolean-limit'):
        # Isolate the prerequisite guard itself: a later connection-setup
        # exception must not mask its removal in a counterfactual.
        p = probe(mode, 'require-only')
        assert p.returncode == 70 and 'requires Python 3.11+' in p.stdout, (mode, p.stdout, p.stderr)
        p = probe(mode, 'fm_owner_notice_store.py', 'runner-config', '--home', str(w.home))
        assert p.returncode == 70 and 'requires Python 3.11+' in p.stdout, (mode, p.stdout, p.stderr)
        p = probe(mode, 'fm_owner_notice_alarm.py', '--home', str(w.home), 'advance')
        assert p.returncode == 70 and 'requires Python 3.11+' in p.stderr, (mode, p.stdout, p.stderr)
        assert not w.own.exists(), 'unsupported runtime created owner state'
        # The two-file producer remains independently importable/callable.
        p = probe(mode, 'fm-owner-notice-client.py', '--help')
        assert p.returncode == 0, (mode, p.stdout, p.stderr)
    p = probe('native', 'require-only')
    assert p.returncode == 0, (p.stdout, p.stderr)
    p = probe('native', 'fm_owner_notice_store.py', 'runner-config', '--home', str(w.home))
    assert p.returncode == 0 and len(p.stdout.split()) == 5, (p.stdout, p.stderr)
    assert not w.own.exists()


def publication_limits(_w):
    import sqlite3
    from fm_owner_notice_alarm import QueueConnection, VALUE_BOUND, SQL_BOUND
    # Each query is otherwise valid at the connection API. Removing only its
    # limit makes it succeed; schema/correlation refusals cannot mask this.
    db = sqlite3.connect(':memory:', factory=QueueConnection)
    try:
        assert len(db.execute('SELECT zeroblob(?)', (VALUE_BOUND // 2,)).fetchone()[0]) == VALUE_BOUND // 2
        try:
            db.execute('SELECT zeroblob(?)', (VALUE_BOUND + 1,)).fetchone()
        except sqlite3.DataError:
            pass
        else:
            raise AssertionError('SQLite value allocation was unbounded')
        assert db.execute('SELECT 1 -- ' + 'x' * (SQL_BOUND // 2)).fetchone() == (1,)
        try:
            db.execute('SELECT 1 -- ' + 'x' * SQL_BOUND).fetchone()
        except sqlite3.DataError:
            pass
        else:
            raise AssertionError('SQLite SQL input was unbounded')
    finally:
        db.close()
    original = QueueConnection.setlimit
    QueueConnection.setlimit = lambda self, category, _limit: self.getlimit(category)
    try:
        try:
            db = sqlite3.connect(':memory:', factory=QueueConnection)
        except fmt.FormatError as exc:
            assert 'did not install' in str(exc)
        else:
            db.close()
            raise AssertionError('ignored SQLite limit was accepted')
    finally:
        QueueConnection.setlimit = original


def publication_reader(w):
    w.bind('x'); w.env['FM_TEST_ALARM_ONLY'] = '1'; w.start()
    w.alarm_command('enqueue', 'assert', 'runner-beat-stale')
    wait('real queue initialized and drained', lambda: w.level('runner-beat-stale', runner=True) and not w.alarm_rows() and not (w.own / '.runner-alarms.pending').exists())
    w.stop_watch()
    import sqlite3
    path = w.own / '.runner-alarms.sqlite3'
    db = sqlite3.connect(path)
    try:
        assert db.execute('PRAGMA wal_checkpoint(TRUNCATE)').fetchone()[0] == 0
    finally:
        db.close()
    original = path.read_bytes()
    def restore():
        # All fixture actors are stopped and the saved queue is fully ACKed.
        # Restore its complete SQLite snapshot, not a main file under old WAL.
        for suffix in ('-wal', '-shm', '-journal'):
            Path(str(path) + suffix).unlink(missing_ok=True)
        path.write_bytes(original)
    for shape in (b'', b' ', b'\x00', b'partial', original[:64], 'missing', 'directory', 'fifo', 'link', 'unreadable'):
        if isinstance(shape, bytes):
            path.write_bytes(shape)
        elif shape == 'unreadable':
            path.chmod(0)
        else:
            path.unlink()
            if shape == 'directory': path.mkdir()
            elif shape == 'fifo': os.mkfifo(path)
            elif shape == 'link': path.symlink_to(w.root / 'missing-queue')
        try:
            w.call('sync-alarms')
            assert w.level('automation-unreadable', bid='publisher'), shape
            if isinstance(shape, bytes): assert path.read_bytes() == shape
        finally:
            if shape == 'unreadable': path.chmod(0o600)
            elif shape == 'directory': path.rmdir()
            elif isinstance(shape, str): path.unlink(missing_ok=True)
            restore()
        w.call('sync-alarms')
        assert not w.level('automation-unreadable', bid='publisher'), shape
    from fm_owner_notice_alarm import problem, SQL_BOUND
    from fm_owner_notice_store import Owner
    bad_sql = ["UPDATE meta SET root='foreign-home'", "PRAGMA user_version=2",
               "PRAGMA journal_mode=DELETE", "DROP INDEX pending_key",
               "CREATE VIEW extra AS SELECT 1", "DELETE FROM meta", "UPDATE meta SET id=2",
               "UPDATE meta SET cursor=-1", "UPDATE meta SET cursor=0",
               "UPDATE meta SET digest=NULL", "UPDATE meta SET digest='invalid'",
               "UPDATE meta SET since=0", "UPDATE meta SET advance_since=0",
               "UPDATE meta SET problem='',since=0", "UPDATE meta SET advance_problem='',advance_since=0",
               "UPDATE meta SET advance_problem='failure',advance_since=-1",
               "UPDATE meta SET advance_problem='failure',advance_since=253402300800",
               "UPDATE meta SET advance_problem='failure',advance_since='unknown'",
               "UPDATE meta SET advance_problem='failure',advance_since=NULL",
               "UPDATE meta SET advance_problem=char(10),advance_since=0",
               "UPDATE meta SET advance_problem=char(13),advance_since=0",
               "UPDATE meta SET advance_problem=char(0),advance_since=0",
               "CREATE VIEW oversized AS SELECT 1 AS \"" + 'x' * (SQL_BOUND * 2) + '\"',
               "INSERT INTO requests(seq,key,action,reason,at) VALUES(1,'runner-beat-stale','assert','reason',1)"]
    for key, action, reason, at in (("'unknown'", "'assert'", "'reason'", '1'),
                                  ("'runner-beat-stale'", "'noop'", "'reason'", '1'),
                                  ("'runner-beat-stale'", "'assert'", "''", '1'),
                                  ("'runner-beat-stale'", "'assert'", 'char(10)', '1'),
                                  ("'runner-beat-stale'", "'assert'", 'char(0)', '1'),
                                  ("'runner-beat-stale'", "'assert'", 'zeroblob(2097152)', '1'),
                                  ("'runner-beat-stale'", "'assert'", "'reason'", "'bad epoch'"),
                                  ("'runner-beat-stale'", "'assert'", "'reason'", '-1'),
                                  ("'runner-beat-stale'", "'assert'", "'reason'", '1.5'),
                                  ("'runner-beat-stale'", "'assert'", "'reason'", '253402300800')):
        bad_sql.append('INSERT INTO requests(key,action,reason,at) VALUES(%s,%s,%s,%s)' % (key, action, reason, at))
    bad_sql += [sql.replace('advance_problem', 'problem').replace('advance_since', 'since')
                for sql in bad_sql if sql.startswith('UPDATE meta SET advance_problem')]
    for sql in dict.fromkeys(bad_sql):
        db = sqlite3.connect(path)
        try:
            db.execute('PRAGMA ignore_check_constraints=ON')
            if sql.startswith('UPDATE meta SET problem') or sql == 'UPDATE meta SET since=0':
                db.execute("INSERT INTO requests(key,action,reason,at) VALUES('runner-beat-stale','assert','pending',?)",
                           (int(time.time()),))
            db.execute(sql)
            db.commit()
        finally:
            db.close()
        w.call('sync-alarms')
        assert w.level('automation-unreadable', bid='publisher'), sql
        try:
            problem(Owner(str(w.home)))
        except (OSError, ValueError):
            pass
        else:
            raise AssertionError('corrupt queue was accepted as a known state: ' + sql)
        restore()
        w.call('sync-alarms')
        assert not w.level('automation-unreadable', bid='publisher'), sql
    db = sqlite3.connect(path)
    try:
        db.execute("INSERT INTO requests(key,action,reason,at) VALUES('runner-beat-stale','assert','pending',?)",
                   (int(time.time()),))
        db.execute("UPDATE meta SET problem='writer failure',since=0,advance_problem='advance failure',advance_since=0")
        db.commit()
    finally:
        db.close()
    known = problem(Owner(str(w.home)))
    assert known[1] == 0 and 'writer' in known[0] and 'advance' in known[0], known
    restore()
    journal = Path(str(path) + '-journal')
    journal.write_bytes(b'')
    w.call('sync-alarms')
    assert w.level('automation-unreadable', bid='publisher')
    assert journal.read_bytes() == b'' and path.read_bytes() == original
    journal.unlink()
    w.call('sync-alarms')
    assert not w.level('automation-unreadable', bid='publisher')
    for name in ('.runner-alarm-publisher.lock', '.runner-alarms.pending', 'watcher.log'):
        member = w.own / name
        saved = member.read_bytes() if member.exists() else None
        malformed = ['link', 'directory', 'fifo', 'hardlink', 'unreadable', 'write-only']
        if not name.endswith('.pending'): malformed += ['read-only']
        if name.endswith('.lock'): malformed += ['missing', b' ', b'partial\n', b'\0']
        if name.endswith('.pending'): malformed += [b'', b' ', b'pending', b'pending\n\n', b'pending\0\n', b'x' * (fmt.RECORD_BOUND + 1)]
        for shape in malformed:
            member.unlink(missing_ok=True)
            other = w.root / 'reader-other-link'
            if isinstance(shape, bytes): member.write_bytes(shape)
            elif shape == 'link': member.symlink_to(w.root / 'reader-missing')
            elif shape == 'directory': member.mkdir()
            elif shape == 'fifo': os.mkfifo(member)
            elif shape == 'hardlink':
                member.write_bytes(saved if saved is not None else b'pending\n'); os.link(member, other)
            elif shape in ('unreadable', 'write-only', 'read-only'):
                member.write_bytes(saved if saved is not None else b'pending\n')
                member.chmod({'unreadable': 0, 'write-only': 0o200, 'read-only': 0o400}[shape])
            w.call('sync-alarms')
            assert w.level('automation-unreadable', bid='publisher'), (name, shape)
            if isinstance(shape, bytes): assert member.read_bytes() == shape
            if shape == 'directory': member.rmdir()
            else: member.unlink(missing_ok=True)
            other.unlink(missing_ok=True)
            if saved is not None: member.write_bytes(saved)
            w.call('sync-alarms')
            assert not w.level('automation-unreadable', bid='publisher'), name
        if name.endswith('.pending'):
            member.write_bytes(b'pending\n')  # Valid stale hint, not queue truth.
        elif name == 'watcher.log':
            member.write_bytes(b'x' * (4 * 1024 * 1024))  # Contents/history are not scanned.
        w.call('sync-alarms')
        assert not w.level('automation-unreadable', bid='publisher'), name
        member.unlink(missing_ok=True)
        if saved is not None: member.write_bytes(saved)


def automation_reader(w):
    w.bind('x'); path = w.own / 'x/.automation'
    bad = [b'', b' ', b'{', b'{}\x00', fmt.canonical({'busy': 0, 'failure': None, 'since': 1}),
           fmt.canonical({'busy': {'stat': {'count': 3, 'since': 1}}, 'failures': {}}),
           fmt.canonical({'busy': {'maintain': {'count': True, 'since': 1}}, 'failures': {}}),
           fmt.canonical({'busy': {}, 'failures': {'stat': {'reason': '', 'since': 1}}}),
           fmt.canonical({'busy': {}, 'failures': {'stat': {'reason': 'failed', 'since': 10**30}}})]
    for raw in bad:
        path.write_bytes(raw); w.call('sync-alarms')
        assert w.level('automation-unreadable'), raw
        path.write_bytes(fmt.canonical({'busy': {}, 'failures': {}})); w.call('sync-alarms')
        assert not w.level('automation-unreadable')
    path.unlink(); w.call('sync-alarms')
    assert not w.level('automation-unreadable')


def manual_batch_spoof(w):
    w.bind('x'); w.envelope('x', 'one'); w.call('ingest', 'x')
    env = dict(w.env, FM_OWNER_NOTICE_RUNNER_BATCH='1')
    for command in (('consume', 'x', 'one'), ('reconcile', 'x'), ('maintain', 'x'), ('ingest', 'x')):
        p = subprocess.run(['bash', str(ROOT / 'bin/fm-alert-store.sh'), 'assert',
                            str(w.own / 'alert-store.json'), 'owner-notice', 'obsolete', 'fixture ended condition'],
                           env=w.env, capture_output=True, text=True, timeout=20)
        assert p.returncode == 0, p.stderr
        w.call(*command, env=env)
        assert 'obsolete' not in record(w.own / 'alert-store.json')['active'], command

    launcher = '''import os,sys,time
from pathlib import Path
sys.path.insert(0, sys.argv[1] + '/bin')
import fm_owner_notice_format as fmt
pid=os.getpid(); start=fmt.pid_starttime(pid)
mode=sys.argv[3]
record_pid=pid+1000000 if mode=='pid' else pid
record_start=str(int(start)+1) if mode=='start' else start
Path(sys.argv[2] + '/state/owner-notices/x/.children').write_text(
    'ingest %s %s %s %s -\\n' % (record_pid,record_start,record_pid,int(time.time())))
os.execve('/bin/bash', ['/bin/bash',sys.argv[1]+'/bin/fm-owner-notice.sh','maintain','x'],os.environ)
'''
    for mode in ('pid', 'start'):
        p = subprocess.run(['bash', str(ROOT / 'bin/fm-alert-store.sh'), 'assert',
                            str(w.own / 'alert-store.json'), 'owner-notice', 'obsolete', 'fixture ended condition'],
                           env=w.env, capture_output=True, text=True, timeout=20)
        assert p.returncode == 0
        p = subprocess.run([sys.executable, '-c', launcher, str(ROOT), str(w.home), mode],
                           env=env, capture_output=True, text=True, timeout=20, start_new_session=True)
        assert p.returncode == 0, (mode, p.stdout, p.stderr)
        assert 'obsolete' not in record(w.own / 'alert-store.json')['active'], mode


def legitimate_batch(w):
    w.bind('x'); w.envelope('x', 'one'); os.mkfifo(w.root / 'projection')
    w.start('alarms:after-snapshot:pause=' + str(w.root / 'projection')
            + ',unkillable:ingest,ingest-bound=3,stat-bound=30')
    wait('projector holds serializer', lambda: (w.root / 'projection.reached').exists())
    w.delivered('x', 'one')
    def finished():
        lines = w.log().splitlines()
        starts = [i for i, line in enumerate(lines) if 'ingest-staged start' in line]
        return starts and any('exit ingest' in line and 'code=0' in line for line in lines[starts[0]+1:])
    wait('recorded child finishes without its own blocked projection', finished, cap=8)
    assert w.stall('', 'ingest')
    assert fmt.identity_alive(w.children('')['ingest']['pid'], w.children('')['ingest']['starttime'])


def batch_authorization_unknown(w):
    w.bind('x')
    path = w.own / 'x/.children'
    shapes = [('partial', b'ingest 9999999 1 9999999 1 -'), ('white', b' \n'),
              ('nul', b'ingest 9999999 1 9999999 1 -\x00\n'), ('large', b'x' * (128 << 10)),
              ('duplicate', b'ingest 9999999 1 9999999 1 -\ningest 9999998 1 9999998 1 -\n'),
              ('fifo', None), ('directory', None), ('link', None)]
    for name, raw in shapes:
        if path.exists() or path.is_symlink():
            path.unlink()
        if raw is not None:
            path.write_bytes(raw)
        elif name == 'fifo':
            os.mkfifo(path)
        elif name == 'directory':
            path.mkdir()
        else:
            path.symlink_to(w.root / 'missing')
        result = w.call('maintain', 'x', code=70)
        assert 'batch-authorization-unreadable' in result, (name, result)
        assert w.level('automation-unreadable'), name
        if name == 'directory':
            path.rmdir()
        else:
            path.unlink()
        # Valid empty records are manual work; regrowth must not retain a
        # cached failure or grant a different process's stale slot.
        path.write_text('' if name != 'partial' else 'ingest 9999999 1 9999999 1 -\n')
        w.call('maintain', 'x')
        assert not w.level('automation-unreadable'), name


CASES = dict(quarantine_children=quarantine_binding, quarantine_stall=quarantine_binding,
             quarantine_automation=quarantine_binding, quarantine_seen=quarantine_binding,
             quarantine_index=quarantine_binding, quarantine_binding=quarantine_binding, quarantine_route=quarantine_binding,
             quarantine_live=quarantine_live, quarantine_routing=quarantine_global, quarantine_foreground=quarantine_global,
             quarantine_projection=quarantine_global, quarantine_root_stall=quarantine_global, quarantine_ledger=quarantine_global,
             quarantine_stat_reply=quarantine_stat_reply,
             empty_after_projection_failure=empty_after_projection_failure, empty_after_failed_starts=empty_after_failed_starts,
             empty_incomplete_projection=empty_incomplete_projection,
             old_projection_failure=old_projection_failure, old_projection_stale=old_projection_failure,
             role_failure_retention=role_failure_retention, role_failure_scope=role_failure_scope, automation_reader=automation_reader,
             projection_failure=projection_failure, manual_batch_spoof=manual_batch_spoof,
             legitimate_batch=legitimate_batch, batch_authorization_unknown=batch_authorization_unknown,
             counter_reader=counter_reader, bad_routing=bad_routing, empty_home=empty_home,
             refusal_ack=refusal_ack, history=history, archive=archive, retention_boundary=retention_boundary,
             bound_bind=foreground_bound, bound_retire=foreground_bound,
             bound_ingest=foreground_bound, real_watcher=real_watcher, engine_death=engine_death, loop_death=loop_death, stale_transition=stale_transition, first_start=first_start, successor_grace=first_start,
             recovery_down=recovery_down, live_fast=live_fast, singleton=singleton, in_flight=in_flight, handover=handover, busy=busy,
             start_announce=start_announce, all_ingests_stalled=all_ingests_stalled, projection_restart=projection_restart,
             stage_recovery=role_recovery, ingest_recovery=role_recovery, exit_term=exit_children, exit_kill=exit_children,
             pdeath_ingest=foreground_survival, pdeath_bind=foreground_survival, survival_ingest=foreground_survival,
             survival_bind=foreground_survival, survival_retire=foreground_survival,
             foreground_recovery=foreground_recovery, stage_deadline=deadline, stage_signal=deadline,
             ingest_deadline=deadline, ingest_signal=deadline, backoff=backoff, slow_sweep=slow_sweep,
             cap=cap, racy=racy, idle=idle, handrun=handrun, stat_stall=stat_stall, stage_stall=stage_stall, stage_live_signal=stage_stall,
             adoption=adoption, watcher_loss=watcher_loss, foreground=foreground, flapping=flapping)
CASES.update({name: lifecycle for name in LIFECYCLE})
CASES.update(publication_fifo=publication_fifo, publication_stale_counter=publication_stale_counter,
             publication_two_clears=publication_two_clears, publication_third_failure=publication_third_failure,
             publication_failure=publication_failure, publication_deadline=publication_deadline,
             runtime_empty=runtime_owner, runtime_work=runtime_owner, runtime_pending=runtime_owner,
             runtime_unknown=runtime_owner, runtime_api=runtime_owner, runtime_sqlite_missing=runtime_owner,
             runtime_probe_error=runtime_owner, runtime_manual=runtime_manual, runtime_changed=runtime_changed,
             start_authority=start_authority, start_authority_alias=start_authority,
             start_authority_bound=start_authority_bound,
             runtime_restart=runtime_restart, runtime_overlap=runtime_overlap,
             runtime_first_publish=runtime_first_publish,
             runtime_native_failure=runtime_native_failure, runtime_native_paths=runtime_native_paths,
             startup_config=startup_refusal, startup_reserve=startup_refusal,
             startup_exit_counter=startup_exit_refusal, startup_exit_write=startup_exit_refusal,
             publication_store=publication_store, publication_admission=publication_admission,
             publication_runtime=publication_runtime, publication_limits=publication_limits,
             publication_reader=publication_reader, publication_result_reader=publication_result_reader,
             publication_frozen_reader=publication_frozen_reader,
             publication_lifetime=publication_lifetime, publication_watcher_deadline=publication_lifetime,
             publication_advance_failure=publication_advance_failure, publication_cursor_replay=publication_cursor_replay,
             publication_initialization=publication_initialization, publication_initialization_dead=publication_initialization,
             publication_metadata_directory=publication_metadata_directory)

CASES['publication_lease_sync'] = publication_lease_sync
CASES.update(recovery_reader=recovery_reader, recovery_progress=recovery_progress, projection_reader=projection_reader, registration_late=registration_late)
for source in ('notice', 'runner', 'status', 'directory'):
    CASES['registration_' + source] = registration_isolation
for source in ('config', 'reserve', 'write'):
    for ending in ('work', 'empty'):
        CASES['recovery_prior_' + source + '_' + ending] = recovery_prior

w = World()
try:
    CASES[CASE](w)
    print('PASS', CASE)
except BaseException:
    for path in [w.own / 'runner.log', w.own / 'watcher.log', w.own / 'log', w.own / 'x/log',
                 *sorted(w.root.glob('watch-*.log')), w.root / 'real-watch.log',
                 w.state / '.last-watcher-beat', w.state / '.wake-queue',
                 w.state / 'owner-notice.status', w.state / 'owner-notice-runner.status']:
        try:
            if path.is_file():
                print('EVIDENCE', path, path.read_text()[-12000:], file=sys.stderr)
        except OSError as error:
            print('EVIDENCE unreadable', path, str(error), file=sys.stderr)
    raise
finally:
    w.close()
