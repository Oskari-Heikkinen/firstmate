#!/usr/bin/env python3
"""Read-only disk inventory: KEEP / REMOVE / other-homes tables for one home.

Usage: fm-disk-inventory.sh [--home DIR] [--out FILE | --stdout]
       [--also-home DIR]... [--pool-root DIR]... [--nm-root DIR] [--tmp-root DIR]
       [--idle-hours N] [--du-timeout SECS] [--git-timeout SECS] [--date YYYY-MM-DD]

--home defaults to $FM_HOME, else this script's code root.
Default output is <home>/data/housekeeping/inventory-<date>.md; when that exists
a -<HHMMSS> suffix is added, and an explicit --out that exists is refused.
The output file (and its missing parent directories) is the only thing written.

Scanned:
  * treehouse pool slots under each --pool-root (default $TREEHOUSE_ROOT or
    ~/.treehouse) plus every home's projects/*/.treehouse, as <root>/<key>/<N>/;
  * no-mistakes worktrees under --nm-root (default ~/.no-mistakes/worktrees),
    always KEEP because the shared daemon owns them;
  * task temp folders <tmp-root>/fm-* and session folders
    <tmp-root>/claude-<uid>/*/* (default --tmp-root /tmp);
  * the selected home's data/, state/ and projects/ (always KEEP), and the data/
    size of every other discovered home.

Homes are the selected home, each --also-home, every <pool>/<key>/<N>/<dir> and
git common-dir parent holding state/ plus data/ or state/*.meta. References are
every home's state/*.meta worktree=, tasktmp= and home= paths at or inside an
item, pool
leases in <key>/treehouse-state.json, and .fm-slot-owner claims.

A pool slot is REMOVE only when ALL hold: not leased, no referencing meta line,
no owner claim, not a home, no live process with cwd, root or open file inside
(read from /proc), exactly one git copy whose own top level it is, no tracked
change and no untracked file, and HEAD an ancestor of origin's default branch as
already recorded locally (no fetch); ignored content that would go with it
(caches, environments, local evidence) is named in the row. A scratch folder is
REMOVE only when it is unreferenced, has no live process, nothing inside changed
for --idle-hours (default 24), and its path is cited by no home's data/**/*.md. Any check that
errors, times out or cannot be read keeps the item in KEEP with the reason.

Read-only by construction: the only subprocesses are an allowlist of read-only
`du` and `git` invocations run with GIT_OPTIONAL_LOCKS=0; the module never
deletes, renames or modifies anything. The wrapper runs everything at nice 19
and ionice -c3; each du/git call has its own timeout.
"""
import argparse
import datetime
import json
import os
import re
import sys
import subprocess
import time
from pathlib import Path

GIT_READONLY = {
    ('rev-parse',), ('status',), ('symbolic-ref',), ('merge-base',),
}
MD_READ_LIMIT = 4 * 1024 * 1024


class Inventory:
    def __init__(self, args):
        self.args = args
        self.limits = []  # scan limits hit, reported in the output
        self.keep = []    # (item, size_kb, why)
        self.remove = []  # (item, size_kb, scope, owner, why)
        self.other_homes = []

    # ---- read-only subprocess allowlist -------------------------------
    def run_ro(self, argv, timeout):
        if argv[0] == 'du':
            if argv[1:2] != ['-sxk']:
                raise AssertionError('refused non-read-only du: %r' % argv)
        elif argv[0] == 'git':
            sub = argv[3:4]  # argv is git -C <dir> <subcommand> ...
            if argv[1] != '-C' or tuple(sub) not in GIT_READONLY:
                raise AssertionError('refused non-read-only git: %r' % argv)
            if tuple(sub) == ('merge-base',) and '--is-ancestor' not in argv:
                raise AssertionError('refused merge-base form: %r' % argv)
        else:
            raise AssertionError('refused command: %r' % argv)
        env = dict(os.environ, GIT_OPTIONAL_LOCKS='0', LC_ALL='C')
        try:
            p = subprocess.run(argv, capture_output=True, text=True,
                               timeout=timeout, env=env, stdin=subprocess.DEVNULL)
        except subprocess.TimeoutExpired:
            return None, 'timed out after %ss' % timeout
        except OSError as e:
            return None, str(e)
        return p, None

    def du_kb(self, path):
        p, err = self.run_ro(['du', '-sxk', str(path)], self.args.du_timeout)
        if err or p.returncode not in (0, 1) or not p.stdout.strip():
            self.limits.append('size of %s unknown (%s)' % (path, err or p.stderr.strip()[:120]))
            return None
        return int(p.stdout.split()[0])

    def git(self, wt, *rest):
        return self.run_ro(['git', '-C', str(wt), *rest], self.args.git_timeout)

    # ---- discovery -----------------------------------------------------
    @staticmethod
    def is_home(d):
        state = d / 'state'
        if not state.is_dir():
            return False
        return (d / 'data').is_dir() or any(state.glob('*.meta'))

    def discover(self):
        a = self.args
        self.home = Path(a.home).resolve()
        homes = {self.home}
        homes.update(Path(h).resolve() for h in a.also_home)
        pool_roots = [Path(p).expanduser() for p in a.pool_root] or [
            Path(os.environ.get('TREEHOUSE_ROOT') or Path.home() / '.treehouse')]
        roots = []
        for r in pool_roots:
            if r.is_dir():
                roots.append(r.resolve())
        # Slots that are homes, then the git common-dir parent of every slot.
        slots = []
        for r in list(roots):
            slots.extend(self.slots_of(r))
        for slot, wts in slots:
            for wt in wts:
                if self.is_home(wt):
                    homes.add(wt.resolve())
        for slot, wts in slots:
            for wt in wts:
                main = self.common_parent(wt)
                if main and self.is_home(main):
                    homes.add(main)
        for h in sorted(homes):
            for proj_pool in sorted((h / 'projects').glob('*/.treehouse')):
                rp = proj_pool.resolve()
                if proj_pool.is_dir() and rp not in roots:
                    roots.append(rp)
        self.homes = sorted(homes)
        self.pool_roots = roots

    @staticmethod
    def slots_of(root):
        out = []
        for key in sorted(p for p in root.iterdir() if p.is_dir()):
            for slot in sorted((p for p in key.iterdir() if p.is_dir() and p.name.isdigit()),
                               key=lambda p: int(p.name)):
                wts = sorted(c for c in slot.iterdir()
                             if c.is_dir() and not c.name.startswith('.'))
                out.append((slot, wts))
        return out

    def common_parent(self, wt):
        p, err = self.git(wt, 'rev-parse', '--path-format=absolute', '--git-common-dir')
        if err or p.returncode != 0:
            return None
        common = Path(p.stdout.strip())
        return common.parent if common.name == '.git' else None

    def load_refs(self):
        self.refs = []  # (path, where)
        self.meta_tasks = set()  # (home, task)
        for h in self.homes:
            for meta in sorted((h / 'state').glob('*.meta')):
                self.meta_tasks.add((h, meta.name[:-5]))
                try:
                    text = meta.read_text(errors='replace')
                except OSError as e:
                    self.limits.append('unreadable meta %s (%s)' % (meta, e))
                    continue
                for line in text.splitlines():
                    k, _, v = line.partition('=')
                    if k in ('worktree', 'tasktmp', 'home') and v.startswith('/'):
                        self.refs.append((os.path.realpath(v), '%s (%s=)' % (meta, k)))

    def scan_processes(self):
        self.live = None
        proc = Path('/proc')
        if not (proc / 'self' / 'cwd').exists():
            self.limits.append('no /proc: live processes cannot be ruled out, nothing is REMOVE')
            return
        me = os.getpid()
        live = []
        for pid in proc.iterdir():
            if not pid.name.isdigit() or int(pid.name) == me:
                continue
            for link in ('cwd', 'root'):
                try:
                    t = os.readlink(pid / link)
                except OSError:
                    continue
                if t != '/':
                    live.append((t, int(pid.name)))
            try:
                fds = list((pid / 'fd').iterdir())
            except OSError:
                continue
            for fd in fds:
                try:
                    t = os.readlink(fd)
                except OSError:
                    continue
                if t.startswith('/'):
                    live.append((t, int(pid.name)))
        self.live = live

    # ---- checks --------------------------------------------------------
    def refs_for(self, path):
        rp = os.path.realpath(path)
        return sorted({w for p, w in self.refs if p == rp or p.startswith(rp + '/')})

    def live_pids(self, path):
        if self.live is None:
            return None
        rp = os.path.realpath(path)
        return sorted({pid for t, pid in self.live if t == rp or t.startswith(rp + '/')})

    def git_verdict(self, wt):
        """Return (ok, reason) for a git copy's clean-and-landed checks."""
        p, err = self.git(wt, 'rev-parse', '--show-toplevel')
        if err or p.returncode != 0:
            return False, 'not a readable git copy (%s)' % (err or p.stderr.strip()[:80])
        if os.path.realpath(p.stdout.strip()) != os.path.realpath(wt):
            return False, 'git top level is %s, not this copy' % p.stdout.strip()
        p, err = self.git(wt, 'status', '--porcelain', '--untracked-files=normal', '--ignored')
        if err or p.returncode != 0:
            return False, 'git status failed (%s)' % (err or p.stderr.strip()[:80])
        lines = [ln for ln in p.stdout.splitlines() if ln]
        tracked = [ln for ln in lines if ln[:2] not in ('??', '!!')]
        ignored = [ln[3:] for ln in lines if ln.startswith('!!')]
        untracked = [ln for ln in lines if ln.startswith('??')]
        if tracked:
            return False, '%d uncommitted tracked change(s)' % len(tracked)
        if untracked:
            return False, 'untracked files: %s' % ', '.join(ln[3:] for ln in untracked[:3])
        p, err = self.git(wt, 'symbolic-ref', '-q', '--short', 'refs/remotes/origin/HEAD')
        if err or p.returncode != 0 or not p.stdout.strip():
            return False, "origin's default branch unknown (no origin/HEAD)"
        default = p.stdout.strip()
        p, err = self.git(wt, 'rev-parse', '--short', 'HEAD')
        if err or p.returncode != 0:
            return False, 'HEAD unreadable'
        head = p.stdout.strip()
        p, err = self.git(wt, 'merge-base', '--is-ancestor', 'HEAD', default)
        if err or p.returncode not in (0, 1):
            return False, 'ancestry check failed (%s)' % (err or p.stderr.strip()[:80])
        if p.returncode == 1:
            return False, 'head %s is not on %s' % (head, default)
        kept = ''
        if ignored:
            more = ' +%d more' % (len(ignored) - 5) if len(ignored) > 5 else ''
            kept = '; ignored content goes too: %s%s' % (', '.join(ignored[:5]), more)
        return True, 'clean, head %s on %s%s' % (head, default, kept)

    def leases(self, key):
        f = key / 'treehouse-state.json'
        if not f.exists():
            return {}, None
        try:
            data = json.loads(f.read_text())
        except (OSError, ValueError) as e:
            return None, 'unreadable pool state %s (%s)' % (f, e)
        out = {}
        for w in data.get('worktrees', []):
            if w.get('leased'):
                out[os.path.realpath(w.get('path', ''))] = w.get('lease_holder') or 'unknown holder'
        return out, None

    def claim(self, slot):
        f = slot / '.fm-slot-owner'
        if not f.exists():
            return None
        try:
            kv = dict(ln.split('=', 1) for ln in f.read_text().splitlines() if '=' in ln)
        except OSError:
            return 'unreadable owner claim'
        task, home = kv.get('task', '?'), kv.get('home', '')
        if (Path(home).resolve() if home else None, task) in self.meta_tasks:
            return 'claimed by live task %s (%s)' % (task, home)
        return 'owner claim names task %s of %s with no meta; confirm with that home' % (task, home or '?')

    def scope_of(self, path):
        rp = os.path.realpath(path)
        for h in sorted(self.homes, key=lambda p: -len(str(p))):
            if rp.startswith(str(h) + '/'):
                return 'this home' if h == self.home else 'home %s' % h
        return 'shared pool'

    # ---- inventory passes ---------------------------------------------
    def pools(self):
        for root in self.pool_roots:
            for key in sorted(p for p in root.iterdir() if p.is_dir()):
                leases, lerr = self.leases(key)
                if lerr:
                    self.limits.append(lerr)
                for slot, wts in [s for s in self.slots_of(root) if s[0].parent == key]:
                    self.slot(slot, wts, leases)

    def slot(self, slot, wts, leases):
        size = self.du_kb(slot)
        item = str(slot)
        why = []
        if leases is None:
            why.append('pool lease state unreadable')
        else:
            for wt in wts:
                holder = leases.get(os.path.realpath(wt))
                if holder:
                    why.append('leased to %s' % holder)
        for wt in wts:
            if wt.resolve() in self.homes:
                why.append('is a firstmate home')
        refs = self.refs_for(slot)
        if refs:
            why.append('referenced by ' + '; '.join(refs[:3]))
        c = self.claim(slot)
        if c:
            why.append(c)
        pids = self.live_pids(slot)
        if pids is None:
            why.append('live processes not checked')
        elif pids:
            why.append('%d live process(es) inside' % len(pids))
        owner = '?'
        if len(wts) != 1:
            why.append('%d git copies in slot' % len(wts))
        else:
            main = self.common_parent(wts[0])
            owner = str(main) if main else '?'
            if not why:
                ok, reason = self.git_verdict(wts[0])
                if not ok:
                    why.append(reason)
                else:
                    self.remove.append((item, size, self.scope_of(slot), owner,
                                        'unreferenced, no lease or claim, no live process, ' + reason))
                    return
        self.keep.append((item, size, '; '.join(why)))

    def nm_worktrees(self):
        root = Path(self.args.nm_root).expanduser()
        if not root.is_dir():
            return
        for repo in sorted(p for p in root.iterdir() if p.is_dir()):
            for run in sorted(p for p in repo.iterdir() if p.is_dir()):
                pids = self.live_pids(run)
                live = '' if not pids else '; %d live process(es) inside' % len(pids)
                self.keep.append((str(run), self.du_kb(run),
                                  'no-mistakes worktree owned by the shared daemon' + live))

    def scratch_dirs(self):
        tmp = Path(self.args.tmp_root)
        cands = sorted(p for p in tmp.glob('fm-*') if p.is_dir() and not p.is_symlink())
        cands += sorted(p for p in tmp.glob('claude-%d/*/*' % os.getuid())
                        if p.is_dir() and not p.is_symlink())
        if not cands:
            return
        cited = self.citations([str(p) for p in cands])
        cutoff = time.time() - self.args.idle_hours * 3600
        for d in cands:
            why = []
            refs = self.refs_for(d)
            if refs:
                why.append('referenced by ' + '; '.join(refs[:3]))
            pids = self.live_pids(d)
            if pids is None:
                why.append('live processes not checked')
            elif pids:
                why.append('%d live process(es) inside' % len(pids))
            if cited is None:
                why.append('report citations not checked')
            elif cited.get(str(d)):
                why.append('cited by ' + cited[str(d)])
            newest = self.newest_mtime(d)
            if newest is None:
                why.append('age unknown')
            elif newest > cutoff:
                why.append('changed within %sh' % self.args.idle_hours)
            size = self.du_kb(d)
            if why:
                self.keep.append((str(d), size, '; '.join(why)))
            else:
                age = (time.time() - newest) / 3600
                self.remove.append((str(d), size, 'temp folder', '-',
                                    'unreferenced, no live process, uncited, idle %.0fh' % age))

    def newest_mtime(self, d):
        deadline = time.monotonic() + self.args.du_timeout
        newest = 0.0
        try:
            newest = d.lstat().st_mtime
            for base, dirs, files in os.walk(d, onerror=self._walk_error):
                if time.monotonic() > deadline:
                    self.limits.append('age walk of %s timed out' % d)
                    return None
                for n in dirs + files:
                    try:
                        newest = max(newest, os.lstat(os.path.join(base, n)).st_mtime)
                    except OSError:
                        pass
        except _WalkError:
            return None
        except OSError:
            return None
        return newest

    @staticmethod
    def _walk_error(e):
        raise _WalkError(e)

    def citations(self, paths):
        """Map path -> first home report citing it; None when the scan is incomplete."""
        deadline = time.monotonic() + self.args.du_timeout
        found = {}
        for h in self.homes:
            for base, _dirs, files in os.walk(h / 'data'):
                if time.monotonic() > deadline:
                    self.limits.append('report citation scan timed out')
                    return None
                for n in files:
                    if not n.endswith('.md'):
                        continue
                    f = os.path.join(base, n)
                    try:
                        if os.path.getsize(f) > MD_READ_LIMIT:
                            continue
                        with open(f, errors='replace') as fh:
                            text = fh.read()
                    except OSError:
                        continue
                    for p in paths:
                        if p not in found and p in text:
                            found[p] = f
        return found

    def home_tables(self):
        h = self.home
        data = h / 'data'
        if data.is_dir():
            for c in sorted(data.iterdir()):
                self.keep.append((str(c), self.du_kb(c),
                                  'this home data/; removal is the owning task\'s call'))
        if (h / 'state').is_dir():
            self.keep.append((str(h / 'state'), self.du_kb(h / 'state'),
                              'runtime records; script-owned, never hand-edited'))
        for c in sorted((h / 'projects').glob('*')):
            if c.is_dir():
                self.keep.append((str(c), self.du_kb(c), 'project clone the pool hangs off'))
        for o in self.homes:
            if o != h and (o / 'data').is_dir():
                self.other_homes.append((str(o / 'data'), self.du_kb(o / 'data')))

    # ---- output --------------------------------------------------------
    def render(self, date):
        def hs(kb):
            if kb is None:
                return 'unknown'
            for unit, div in (('GB', 1024 * 1024), ('MB', 1024)):
                if kb >= div:
                    return '%.1f %s' % (kb / div, unit)
            return '%d KB' % kb

        def cell(s):
            return str(s).replace('|', '\\|').replace('\n', ' ')

        out = ['# Disk inventory - %s' % self.home, '',
               'Date: %s.' % date,
               'Generated by `bin/fm-disk-inventory.sh` (read-only; see its header for every check).',
               '**Nothing was deleted, moved or changed.** REMOVE rows are proposals that need the captain\'s approval.',
               'Pool slots should be removed through `treehouse`, never `rm`, so pool state stays consistent.',
               '', 'Homes scanned for references: %d.' % len(self.homes),
               'Pool roots: %s.' % (', '.join('`%s`' % r for r in self.pool_roots) or 'none'), '']
        rsum = sum(r[1] or 0 for r in self.remove)
        out += ['## Headline', '',
                '- REMOVE candidates: %d item(s), %s.' % (len(self.remove), hs(rsum)),
                '- KEEP: %d item(s).' % len(self.keep),
                '- Other homes listed for their owners: %d.' % len(self.other_homes), '']
        out += ['## KEEP', '', '| Item | Size | Why |', '|---|---|---|']
        out += ['| `%s` | %s | %s |' % (cell(i), hs(s), cell(w)) for i, s, w in self.keep]
        out += ['', '## REMOVE (captain approval needed; nothing deleted)', '']
        if self.remove:
            out += ['| Item | Size | Scope | Owner (git common dir parent) | Why safe |',
                    '|---|---|---|---|---|']
            out += ['| `%s` | %s | %s | %s | %s |' % (cell(i), hs(s), sc, cell(o), cell(w))
                    for i, s, sc, o, w in self.remove]
        else:
            out.append('None.')
        out += ['', '## Other homes (for their owners - not touched)', '']
        if self.other_homes:
            out += ['| Home data dir | Size |', '|---|---|']
            out += ['| `%s` | %s |' % (cell(d), hs(s))
                    for d, s in sorted(self.other_homes, key=lambda r: -(r[1] or 0))]
        else:
            out.append('None found.')
        out += ['', '## Scan limits', '']
        out += ['- %s' % cell(x) for x in self.limits] or ['None.']
        return '\n'.join(out) + '\n'


class _WalkError(Exception):
    pass


def output_path(a, home, date):
    if a.out:
        p = Path(a.out)
        if p.exists():
            sys.exit('fm-disk-inventory: refusing to overwrite existing %s' % p)
        return p
    d = home / 'data' / 'housekeeping'
    p = d / ('inventory-%s.md' % date)
    if p.exists():
        p = d / ('inventory-%s-%s.md' % (date, time.strftime('%H%M%S')))
    if p.exists():
        sys.exit('fm-disk-inventory: refusing to overwrite existing %s' % p)
    return p


def main():
    code_root = Path(__file__).resolve().parent.parent
    ap = argparse.ArgumentParser(prog='fm-disk-inventory.sh', description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--home', default=os.environ.get('FM_HOME') or str(code_root))
    ap.add_argument('--out')
    ap.add_argument('--stdout', action='store_true')
    ap.add_argument('--also-home', action='append', default=[])
    ap.add_argument('--pool-root', action='append', default=[])
    ap.add_argument('--nm-root', default=str(Path.home() / '.no-mistakes' / 'worktrees'))
    ap.add_argument('--tmp-root', default='/tmp')
    ap.add_argument('--idle-hours', type=float, default=24)
    ap.add_argument('--du-timeout', type=int, default=120)
    ap.add_argument('--git-timeout', type=int, default=30)
    ap.add_argument('--date')
    a = ap.parse_args()
    if a.out and a.stdout:
        ap.error('--out and --stdout are exclusive')
    if a.date and not re.fullmatch(r'\d{4}-\d{2}-\d{2}', a.date):
        ap.error('--date must be YYYY-MM-DD')
    if not Path(a.home).is_dir():
        ap.error('--home %s is not a directory' % a.home)
    try:
        os.nice(max(0, 19 - os.nice(0)))
    except OSError:
        pass
    date = a.date or datetime.date.today().isoformat()
    inv = Inventory(a)
    inv.scan_processes()
    inv.discover()
    inv.load_refs()
    inv.pools()
    inv.nm_worktrees()
    inv.scratch_dirs()
    inv.home_tables()
    text = inv.render(date)
    if a.stdout:
        sys.stdout.write(text)
        return
    p = output_path(a, inv.home, date)
    p.parent.mkdir(parents=True, exist_ok=True)
    with open(p, 'x') as fh:
        fh.write(text)
    print(p)


if __name__ == '__main__':
    main()
