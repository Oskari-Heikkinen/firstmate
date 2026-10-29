#!/usr/bin/env python3
"""fm-storage-c-terms.py - read-only measurement of the Windows drive (host-c)
growth terms that a WSL admission must reserve: future ext4.vhdx growth, the
WSL swap disk's remaining growth, restore-point (VSS) shadow storage headroom,
and pagefile growth.

Usage:
  fm-storage-c-terms.py measure --linux-pending BYTES [--policy FILE]
      Print one JSON object (schema fm-storage-c-terms/v1) on one line.
      BYTES is the live Linux charge the caller already holds (a nonnegative
      base-10 integer); it is charged one-for-one to future ext4.vhdx growth.
      FILE is the site policy (fm-storage-c-policy/v1, below); without it a
      system-managed pagefile has no approved growth budget.
  fm-storage-c-terms.py --help

Exit codes:
  0   every term and free-space reading is proven; stdout is the object,
      stderr is empty.
  75  at least one mandatory reading is unknown; stdout is still the object
      (unknown terms have state "unknown" and reserved_bytes null, never 0),
      stderr is exactly one line:
        fm-storage-c-terms: wait: cannot-measure: VOLUME:TERM: DETAIL
      naming the first unknown reading, with " (and N more)" when there are
      others. TERM is linux-free, host-c-free, or a c_terms key.
  2   misuse or an invalid policy file; stdout is empty, stderr is one line
      "fm-storage-c-terms: refused: CODE: DETAIL" (CODE usage or policy).
  1   internal failure; stdout is empty, stderr is one line
      "fm-storage-c-terms: refused: internal: DETAIL".

Output object, keys in this order:
  schema       "fm-storage-c-terms/v1"
  sampled_at   integer Unix seconds of this run (every reading is taken now;
               nothing is cached or read from an earlier run)
  free         {"linux": FS, "host-c": FS}; FS is {state (measured|unknown),
               path, device (MAJOR:MINOR), fstype, drive ("C:" for host-c,
               null for linux), free_bytes, reason}, one statfs snapshot each
  c_terms      {"ext4_vhdx", "swap_vhdx", "vss", "pagefile"}; each has
               state (measured|bounded|not-applicable|unknown), source,
               sampled_at, reason (null only when measured) and
               reserved_bytes (integer bytes to hold on host-c, null when
               unknown), then its own fields:
    ext4_vhdx  path, file_bytes, linux_free_bytes, linux_pending_bytes,
               growth_reserved_bytes; source policy|discovered. Reserves the
               Linux charge one-for-one; file_bytes is informational
    swap_vhdx  path, configured_bytes, file_bytes, hosting_volume (host-c,
               another drive as "X:", or null); source runtime,
               runtime+wslconfig or runtime+default. Reserves the running
               swap size minus the backing file's length, the whole size
               (bounded) when the backing file is not identified, 0 when no
               swap runs or it lives on another drive
    vss        cap_bytes, allocated_bytes, used_bytes, cap_proven; source cim.
               Reserves cap minus allocated, the whole live cap (bounded) when
               allocated is unreadable, 0 when C: has no shadow storage
    pagefile   mode (system-managed|fixed|off|unknown), allocation_bytes,
               maximum_bytes, operator_growth_reservation_bytes, policy_id,
               hosting_volumes; source cim or cim+policy. System-managed
               reserves the policy's approved growth budget (bounded); fixed
               reserves the sum over C: files of maximum minus allocated; off
               reserves 0
  reasons      [{code, volume, term, detail}] for every unknown reading, in
               the order above; code is cannot-measure

Every mandatory reading that is missing, unreadable, ambiguous or unbounded is
a named unknown, never zero. Integers above 2**63-1 are unreadable.

Readings (all read-only; nothing is written, created or changed):
  * mount table and statfs of the Linux root and of host-c, each proven by a
    mount entry at that exact path with a matching device; Linux must be
    ext4, host-c a 9p or drvfs mount of a drive letter, on its own device;
  * the ext4.vhdx: the policy's path, else the single match of
    <host-c>/Users/*/AppData/Local/wsl/*/ext4.vhdx or
    <host-c>/Users/*/AppData/Local/Packages/*/LocalState/ext4.vhdx; it must
    lie on the host-c mount and start with the "vhdxfile" signature;
  * the running swap from <proc>/swaps (partition entries, zram excluded),
    and for its location the .wslconfig the VM booted with (the policy's path,
    else <host-c>/Users/<user>/.wslconfig beside the ext4.vhdx); a .wslconfig
    changed after this boot (mtime past <proc>/stat btime) is unknown;
  * one ordinary-user PowerShell call (no profile, non-interactive, bounded
    timeout) reading Win32_Volume and Win32_ShadowStorage for the diff areas
    on host-c's drive, and Win32_ComputerSystem.AutomaticManagedPagefile,
    Win32_PageFileSetting and Win32_PageFileUsage (MiB, times 1048576).

Site policy, a JSON object with exactly these keys (unknown keys refuse):
  schema         "fm-storage-c-policy/v1" (required)
  policy_id      [A-Za-z0-9][A-Za-z0-9._-]{0,127} (required)
  approval       nonempty provenance text, at most 200 characters (required)
  pagefile_system_managed_growth_bytes
                 optional integer: the approved additional host-c growth of a
                 system-managed pagefile beyond what it already allocated
  ext4_vhdx      optional absolute Linux path of the distro's ext4.vhdx
  wslconfig      optional absolute Linux path of the .wslconfig

Environment (optional; tests point these at fixtures):
  FM_STORAGE_C_HOST        host-c mount (default /mnt/c)
  FM_STORAGE_C_LINUX_ROOT  Linux path whose filesystem is measured (default /)
  FM_STORAGE_C_PROC        procfs root for self/mountinfo, swaps and stat
                           (default /proc)
  FM_STORAGE_C_STATFS      file of "PATH MAJOR:MINOR AVAIL_BYTES" lines that
                           replaces statfs and device reads of the two mounts;
                           a path it does not list is unreadable
  FM_STORAGE_C_POWERSHELL  PowerShell command (default powershell.exe on PATH,
                           else <host-c>/Windows/System32/WindowsPowerShell/
                           v1.0/powershell.exe); empty: no Windows reading
  FM_STORAGE_C_POWERSHELL_TIMEOUT  seconds before that call is killed
                           (default 20)
  FM_STORAGE_C_NOW         epoch override for sampled_at
"""
import glob
import json
import os
import re
import shutil
import signal
import stat
import subprocess
import sys
import time

PROG = 'fm-storage-c-terms'
SCHEMA = 'fm-storage-c-terms/v1'
POLICY_SCHEMA = 'fm-storage-c-policy/v1'
MAX_INT = 2 ** 63 - 1
MIB = 1048576
DETAIL_MAX = 300
PS_OUTPUT_MAX = 1024 * 1024
POLICY_MAX = 64 * 1024
WSLCONFIG_MAX = 1024 * 1024
NAME_RE = re.compile(r'[A-Za-z0-9][A-Za-z0-9._-]{0,127}\Z')
INT_RE = re.compile(r'[0-9]{1,19}\Z')
DRIVE_RE = re.compile(r'([A-Za-z]):')
POLICY_KEYS = ('schema', 'policy_id', 'approval',
               'pagefile_system_managed_growth_bytes', 'ext4_vhdx', 'wslconfig')
# VSS reports an unbounded cap as UINT64_MAX; anything past the ceiling is unbounded.
VSS_UNBOUNDED = 2 ** 63


class Refused(Exception):
    def __init__(self, code, detail):
        Exception.__init__(self, detail)
        self.code = code
        self.detail = detail


def clean(text):
    """Bounded single-line detail text."""
    text = re.sub(r'[\x00-\x1f\x7f]+', ' ', str(text)).strip()
    return text[:DETAIL_MAX]


def parse_int(text):
    """A nonnegative base-10 integer no larger than MAX_INT, or None."""
    if not isinstance(text, str) or not INT_RE.match(text):
        return None
    value = int(text)
    return value if value <= MAX_INT else None


def checked_sum(values):
    total = 0
    for v in values:
        total += v
        if total > MAX_INT:
            return None
    return total


def env(name, default):
    value = os.environ.get(name)
    return default if value is None else value


# ---- mounts and statfs -----------------------------------------------------

def unescape_mount(text):
    return re.sub(r'\\([0-7]{3})', lambda m: chr(int(m.group(1), 8)), text)


def read_mountinfo(proc):
    """List of dicts, or raise OSError/ValueError on an unreadable table."""
    with open(os.path.join(proc, 'self', 'mountinfo'), encoding='utf-8',
              errors='strict') as f:
        text = f.read()
    mounts = []
    for line in text.splitlines():
        fields = line.split(' ')
        if '-' not in fields:
            raise ValueError('malformed mountinfo line')
        sep = fields.index('-')
        if sep < 6 or len(fields) < sep + 4:
            raise ValueError('malformed mountinfo line')
        mounts.append({
            'device': fields[2],
            'root': unescape_mount(fields[3]),
            'point': unescape_mount(fields[4]),
            'fstype': fields[sep + 1],
            'source': unescape_mount(fields[sep + 2]),
            'super': unescape_mount(fields[sep + 3]),
        })
    if not mounts:
        raise ValueError('empty mountinfo')
    return mounts


def mount_at(mounts, point):
    """The top mount at exactly POINT, or None."""
    found = None
    for m in mounts:
        if m['point'] == point:
            found = m
    return found


def mount_containing(mounts, path):
    """The mount whose point is the longest prefix of PATH."""
    best = None
    for m in mounts:
        p = m['point']
        if path == p or path.startswith(p.rstrip('/') + '/'):
            if best is None or len(p) >= len(best['point']):
                best = m
    return best


class Statfs(object):
    """statfs and device readings, or the FM_STORAGE_C_STATFS fixture."""

    def __init__(self):
        self.fixture = None
        self.fixture_error = None
        path = os.environ.get('FM_STORAGE_C_STATFS')
        if path is None:
            return
        self.fixture = {}
        try:
            with open(path, encoding='utf-8') as f:
                for line in f.read().splitlines():
                    parts = line.rsplit(' ', 2)
                    if len(parts) == 3:
                        self.fixture[parts[0]] = (parts[1], parts[2])
        except (OSError, ValueError) as e:
            self.fixture_error = 'cannot read %s: %s' % (path, e)

    def read(self, path):
        """(device "MAJOR:MINOR", avail bytes) or raise OSError."""
        if self.fixture is not None:
            if self.fixture_error:
                raise OSError(self.fixture_error)
            if path not in self.fixture:
                raise OSError('no statfs reading for %s' % path)
            device, avail = self.fixture[path]
            value = parse_int(avail)
            if value is None or not re.match(r'[0-9]+:[0-9]+\Z', device):
                raise OSError('malformed statfs reading for %s' % path)
            return device, value
        st = os.stat(path)
        sv = os.statvfs(path)
        avail = sv.f_bavail * sv.f_frsize
        if avail > MAX_INT:
            raise OSError('free space past the integer ceiling')
        return '%d:%d' % (os.major(st.st_dev), os.minor(st.st_dev)), avail


def drive_of_mount(m):
    for opt in re.split(r'[;,]', m['super']):
        if opt.startswith('path='):
            d = DRIVE_RE.match(opt[5:])
            if d and opt[5:] in (d.group(0), d.group(0) + '\\'):
                return d.group(1).upper()
    d = DRIVE_RE.match(m['source'])
    if d and m['source'] in (d.group(0), d.group(0) + '\\'):
        return d.group(1).upper()
    return None


def measure_fs(path, mounts, mount_err, statfs, want):
    """One filesystem's free-space reading; WANT is 'ext4' or 'drive'."""
    fs = {'state': 'unknown', 'path': path, 'device': None, 'fstype': None,
          'drive': None, 'free_bytes': None, 'reason': None}
    if mount_err:
        fs['reason'] = 'cannot read the mount table: %s' % mount_err
        return fs
    m = mount_at(mounts, path)
    if m is None:
        fs['reason'] = '%s is not a mount point' % path
        return fs
    fs['device'] = m['device']
    fs['fstype'] = m['fstype']
    if m['root'] != '/':
        fs['reason'] = '%s mounts %s, not a whole filesystem' % (path, m['root'])
        return fs
    if want == 'ext4' and m['fstype'] != 'ext4':
        fs['reason'] = '%s is %s, not ext4' % (path, m['fstype'])
        return fs
    if want == 'drive':
        drive = drive_of_mount(m) if m['fstype'] in ('9p', 'drvfs') else None
        if drive is None:
            fs['reason'] = '%s is not a 9p or drvfs mount of a drive letter' % path
            return fs
        fs['drive'] = drive + ':'
    try:
        device, avail = statfs.read(path)
    except OSError as e:
        fs['reason'] = 'cannot read free space on %s: %s' % (path, e)
        return fs
    if device != m['device']:
        fs['reason'] = '%s is device %s, not the mounted %s' % (path, device, m['device'])
        return fs
    fs['free_bytes'] = avail
    fs['state'] = 'measured'
    return fs


# ---- policy ----------------------------------------------------------------

def load_policy(path):
    if path is None:
        return None
    try:
        with open(path, 'rb') as f:
            raw = f.read(POLICY_MAX + 1)
    except OSError as e:
        raise Refused('policy', 'cannot read %s: %s' % (path, e.strerror or e))
    if len(raw) > POLICY_MAX:
        raise Refused('policy', '%s is larger than %d bytes' % (path, POLICY_MAX))

    def no_dupes(pairs):
        keys = [k for k, _ in pairs]
        if len(keys) != len(set(keys)):
            raise ValueError('duplicate key')
        return dict(pairs)

    try:
        doc = json.loads(raw.decode('utf-8'), object_pairs_hook=no_dupes,
                         parse_constant=lambda c: (_ for _ in ()).throw(ValueError(c)))
    except (UnicodeDecodeError, ValueError) as e:
        raise Refused('policy', '%s is not valid JSON: %s' % (path, clean(e)))
    if not isinstance(doc, dict):
        raise Refused('policy', '%s is not a JSON object' % path)
    extra = sorted(set(doc) - set(POLICY_KEYS))
    if extra:
        raise Refused('policy', '%s has unknown key %s' % (path, clean(extra[0])))
    if doc.get('schema') != POLICY_SCHEMA:
        raise Refused('policy', '%s schema is not %s' % (path, POLICY_SCHEMA))
    pid = doc.get('policy_id')
    if not isinstance(pid, str) or not NAME_RE.match(pid):
        raise Refused('policy', '%s policy_id is missing or invalid' % path)
    approval = doc.get('approval')
    if not isinstance(approval, str) or not approval.strip() or len(approval) > 200 \
            or clean(approval) != approval:
        raise Refused('policy', '%s approval is missing or invalid' % path)
    if 'pagefile_system_managed_growth_bytes' in doc:
        v = doc['pagefile_system_managed_growth_bytes']
        if isinstance(v, bool) or not isinstance(v, int) or v < 0 or v > MAX_INT:
            raise Refused('policy', '%s pagefile_system_managed_growth_bytes is not '
                          'a nonnegative integer' % path)
    for key in ('ext4_vhdx', 'wslconfig'):
        if key in doc:
            v = doc[key]
            if not isinstance(v, str) or not v.startswith('/') or clean(v) != v:
                raise Refused('policy', '%s %s is not an absolute path' % (path, key))
    return doc


# ---- ext4.vhdx -------------------------------------------------------------

def common_term(now):
    return {'state': 'unknown', 'source': None, 'sampled_at': now,
            'reason': None, 'reserved_bytes': None}


def measure_ext4(now, linux, host, mounts, policy, pending):
    t = common_term(now)
    t.update({'path': None, 'file_bytes': None,
              'linux_free_bytes': linux['free_bytes'],
              'linux_pending_bytes': pending, 'growth_reserved_bytes': None})
    if linux['state'] != 'measured' and linux['fstype'] != 'ext4':
        t['reason'] = 'the Linux root is not a proven ext4 mount'
        return t
    if host['state'] != 'measured' and host['drive'] is None:
        t['reason'] = 'host-c is not a proven drive mount'
        return t
    if policy is not None and 'ext4_vhdx' in policy:
        path = policy['ext4_vhdx']
        t['source'] = 'policy'
    else:
        t['source'] = 'discovered'
        root = host['path']
        found = sorted(set(
            glob.glob(os.path.join(glob.escape(root), 'Users', '*', 'AppData', 'Local',
                                   'wsl', '*', 'ext4.vhdx')) +
            glob.glob(os.path.join(glob.escape(root), 'Users', '*', 'AppData', 'Local',
                                   'Packages', '*', 'LocalState', 'ext4.vhdx'))))
        if len(found) != 1:
            t['reason'] = ('no ext4.vhdx found on host-c' if not found else
                           '%d ext4.vhdx files found on host-c; name one in the '
                           'site policy' % len(found))
            return t
        path = found[0]
    t['path'] = path
    real = os.path.realpath(path)
    m = mount_containing(mounts, real)
    if m is None or m['point'] != host['path']:
        t['reason'] = '%s is not on the host-c mount' % path
        return t
    try:
        st = os.stat(real)
        if not stat.S_ISREG(st.st_mode):
            t['reason'] = '%s is not a regular file' % path
            return t
        with open(real, 'rb') as f:
            magic = f.read(8)
    except OSError as e:
        t['reason'] = 'cannot read %s: %s' % (path, e.strerror or e)
        return t
    if magic != b'vhdxfile':
        t['reason'] = '%s has no vhdxfile signature' % path
        return t
    if st.st_size > MAX_INT:
        t['reason'] = '%s length is past the integer ceiling' % path
        return t
    t['file_bytes'] = st.st_size
    t['growth_reserved_bytes'] = pending
    t['reserved_bytes'] = pending
    t['state'] = 'measured'
    return t


# ---- WSL swap --------------------------------------------------------------

def read_swaps(proc):
    """Running swap bytes on WSL swap disks, or raise OSError/ValueError."""
    with open(os.path.join(proc, 'swaps'), encoding='utf-8') as f:
        lines = f.read().splitlines()
    if not lines or not lines[0].startswith('Filename'):
        raise ValueError('no header')
    total = 0
    for line in lines[1:]:
        fields = line.split()
        if not fields:
            continue
        if len(fields) != 5:
            raise ValueError('malformed line')
        name, kind, size = fields[0], fields[1], parse_int(fields[2])
        if size is None:
            raise ValueError('malformed size')
        if kind == 'file' or name.startswith('/dev/zram'):
            # A swap file inside a Linux filesystem is preallocated; zram is RAM.
            continue
        if kind != 'partition':
            raise ValueError('unknown swap type %s' % kind)
        total += size * 1024
        if total > MAX_INT:
            raise ValueError('swap size past the integer ceiling')
    return total


def read_btime(proc):
    with open(os.path.join(proc, 'stat'), encoding='utf-8') as f:
        for line in f.read().splitlines():
            if line.startswith('btime '):
                v = parse_int(line[6:].strip())
                if v is not None:
                    return v
    raise ValueError('no btime')


def wslconfig_values(text):
    """The [wsl2] section's keys (lower-cased) and values, like WSL reads them."""
    values = {}
    sect = None
    if text.startswith('\ufeff'):
        text = text[1:]
    for raw in text.splitlines():
        line = raw.strip()
        if line.startswith('['):
            sect = re.sub(r'[ \t]', '', line).lower()
            continue
        if sect != '[wsl2]' or '=' not in line:
            continue
        key, value = line.split('=', 1)
        key = re.sub(r'[ \t]', '', key).lower()
        value = re.sub(r'[ \t]+[#;].*$', '', value).strip()
        if len(value) >= 2 and value[0] == '"' and value[-1] == '"':
            value = value[1:-1]
        values[key] = value
    return values


def measure_swap(now, host, ext4, proc, policy):
    t = common_term(now)
    t.update({'path': None, 'configured_bytes': None, 'file_bytes': None,
              'hosting_volume': None})
    try:
        cap = read_swaps(proc)
    except (OSError, ValueError) as e:
        t['reason'] = 'cannot read the running swap from %s/swaps: %s' % (proc, clean(e))
        return t
    t['source'] = 'runtime'
    t['configured_bytes'] = cap
    if cap == 0:
        t.update(state='not-applicable', reserved_bytes=0,
                 reason='no swap disk is active in this VM boot')
        return t
    if host['drive'] is None:
        t['reason'] = 'host-c is not a proven drive mount'
        return t
    if policy is not None and 'wslconfig' in policy:
        conf = policy['wslconfig']
    elif ext4['path'] and ext4['path'].startswith(host['path'].rstrip('/') + '/Users/'):
        user = ext4['path'][len(host['path'].rstrip('/') + '/Users/'):].split('/', 1)[0]
        conf = os.path.join(host['path'], 'Users', user, '.wslconfig')
    else:
        t['reason'] = 'the Windows profile holding .wslconfig is not known'
        return t
    profile = os.path.dirname(conf)
    profile_on_c = (os.path.realpath(profile).startswith(host['path'].rstrip('/') + '/')
                    and os.path.isdir(profile))
    try:
        btime = read_btime(proc)
    except (OSError, ValueError) as e:
        t['reason'] = 'cannot read this VM boot time from %s/stat: %s' % (proc, clean(e))
        return t
    values = {}
    try:
        st = os.stat(conf)
    except FileNotFoundError:
        st = None
    except OSError as e:
        t['reason'] = 'cannot read %s: %s' % (conf, e.strerror or e)
        return t
    if st is not None:
        if not stat.S_ISREG(st.st_mode):
            t['reason'] = '%s is not a regular file' % conf
            return t
        if int(st.st_mtime) > btime:
            t['reason'] = ('%s changed after this VM booted, so the running swap '
                           'location is not proven' % conf)
            return t
        try:
            with open(conf, 'rb') as f:
                raw = f.read(WSLCONFIG_MAX + 1)
            if len(raw) > WSLCONFIG_MAX:
                raise ValueError('larger than %d bytes' % WSLCONFIG_MAX)
            values = wslconfig_values(raw.decode('utf-8'))
        except (OSError, ValueError) as e:
            t['reason'] = 'cannot read %s: %s' % (conf, clean(e))
            return t
    swapfile = values.get('swapfile', '')
    if not swapfile:
        # WSL's default: %TEMP%\<guid>\swap.vhdx in the profile beside .wslconfig.
        t['source'] = 'runtime+default'
        if not profile_on_c:
            t['reason'] = 'the Windows profile %s is not proven on host-c' % profile
            return t
        t.update(state='bounded', reserved_bytes=cap, hosting_volume='host-c',
                 reason='the running swap disk sits in the default Temp location, '
                        'whose active file is not identified, so its whole size is reserved')
        return t
    t['source'] = 'runtime+wslconfig'
    win = swapfile.replace('\\\\', '\\').replace('/', '\\')
    d = DRIVE_RE.match(win)
    if not d or not win[2:3] == '\\':
        t['reason'] = 'swapFile=%s in %s is not an absolute Windows path' % (clean(swapfile), conf)
        return t
    letter = d.group(1).upper() + ':'
    if letter != host['drive']:
        t.update(state='not-applicable', reserved_bytes=0, hosting_volume=letter,
                 path=clean(swapfile),
                 reason='swapFile=%s in %s is not on host-c' % (clean(swapfile), conf))
        return t
    path = host['path'].rstrip('/') + win[2:].replace('\\', '/')
    t['path'] = path
    t['hosting_volume'] = 'host-c'
    try:
        fst = os.stat(path)
        if not stat.S_ISREG(fst.st_mode):
            raise OSError('not a regular file')
    except OSError as e:
        t.update(state='bounded', reserved_bytes=cap,
                 reason='the swap file %s cannot be read (%s), so the whole running '
                        'size is reserved' % (path, clean(getattr(e, 'strerror', None) or e)))
        return t
    if fst.st_size > MAX_INT:
        t.update(state='bounded', reserved_bytes=cap,
                 reason='the swap file length is past the integer ceiling')
        return t
    t['file_bytes'] = fst.st_size
    t['reserved_bytes'] = max(cap - fst.st_size, 0)
    t['state'] = 'measured'
    return t


# ---- Windows readings ------------------------------------------------------

PS_SCRIPT = r'''
$ErrorActionPreference = 'Stop'
try {
  $v = @(Get-CimInstance -ClassName Win32_Volume -Filter "DriveLetter='@DRIVE@'")
  if ($v.Count -ne 1) { throw ("{0} volumes have drive letter @DRIVE@" -f $v.Count) }
  "VOLUME|" + $v[0].DeviceID
  foreach ($s in @(Get-CimInstance -ClassName Win32_ShadowStorage)) {
    if ($s.DiffVolume.DeviceID -eq $v[0].DeviceID) {
      "SHADOW|{0}|{1}|{2}" -f $s.MaxSpace, $s.AllocatedSpace, $s.UsedSpace
    }
  }
  "VSS-END"
} catch { "VSS-ERROR|" + ($_.Exception.Message -replace '[\r\n|]', ' ') }
try {
  $c = Get-CimInstance -ClassName Win32_ComputerSystem
  "PAGEFILE-AUTO|" + $c.AutomaticManagedPagefile
  foreach ($p in @(Get-CimInstance -ClassName Win32_PageFileSetting)) {
    "PAGEFILE-SETTING|{0}|{1}|{2}" -f $p.Name, $p.InitialSize, $p.MaximumSize
  }
  foreach ($p in @(Get-CimInstance -ClassName Win32_PageFileUsage)) {
    "PAGEFILE-USAGE|{0}|{1}" -f $p.Name, $p.AllocatedBaseSize
  }
  "PAGEFILE-END"
} catch { "PAGEFILE-ERROR|" + ($_.Exception.Message -replace '[\r\n|]', ' ') }
"END"
'''


def powershell_command(host):
    configured = os.environ.get('FM_STORAGE_C_POWERSHELL')
    if configured is not None:
        if not configured:
            return None
        return shutil.which(configured)
    found = shutil.which('powershell.exe')
    if found:
        return found
    if host['path']:
        p = os.path.join(host['path'], 'Windows', 'System32', 'WindowsPowerShell',
                         'v1.0', 'powershell.exe')
        if os.access(p, os.X_OK):
            return p
    return None


def windows_reading(host):
    """(lines, None) from one PowerShell call, or (None, why)."""
    if host['drive'] is None:
        return None, 'host-c is not a proven drive mount'
    cmd = powershell_command(host)
    if cmd is None:
        return None, 'Windows reading unavailable: no PowerShell command'
    raw_timeout = env('FM_STORAGE_C_POWERSHELL_TIMEOUT', '20')
    timeout = parse_int(raw_timeout)
    if timeout is None or timeout == 0:
        return None, 'FM_STORAGE_C_POWERSHELL_TIMEOUT=%s is not a positive integer' % clean(raw_timeout)
    script = PS_SCRIPT.replace('@DRIVE@', host['drive'])
    try:
        p = subprocess.Popen([cmd, '-NoProfile', '-NonInteractive', '-Command', script],
                             stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                             stderr=subprocess.DEVNULL, start_new_session=True)
    except OSError as e:
        return None, 'Windows reading unavailable: %s' % clean(e)
    try:
        out, _ = p.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(p.pid, signal.SIGKILL)
        except OSError:
            pass
        p.communicate()
        return None, 'Windows reading unavailable: PowerShell timed out after %ds' % timeout
    if p.returncode != 0:
        return None, 'Windows reading unavailable: PowerShell exited %d' % p.returncode
    if len(out) > PS_OUTPUT_MAX:
        return None, 'Windows reading unavailable: PowerShell output too large'
    lines = out.decode('utf-8', 'replace').replace('\r', '').split('\n')
    lines = [line.lstrip('\ufeff') for line in lines if line.strip()]
    if not lines or lines[-1] != 'END':
        return None, 'Windows reading unavailable: PowerShell output is incomplete'
    return lines, None


def section(lines, prefix):
    """Rows of PREFIX-..., the error text, and whether the section ended."""
    rows, error, ended = [], None, False
    for line in lines:
        if line == prefix + 'END':
            ended = True
        elif line.startswith(prefix + 'ERROR|'):
            error = line[len(prefix) + 6:]
        elif line.startswith(prefix):
            rows.append(line[len(prefix):])
    return rows, error, ended


def measure_vss(now, host, lines, why):
    t = common_term(now)
    t.update({'cap_bytes': None, 'allocated_bytes': None, 'used_bytes': None,
              'cap_proven': False})
    if lines is None:
        t['reason'] = why
        return t
    t['source'] = 'cim'
    rows = [line for line in lines if line.startswith(('VOLUME|', 'SHADOW|'))]
    _, error, ended = section(lines, 'VSS-')
    if error is not None or not ended:
        t['reason'] = 'shadow storage query failed: %s' % clean(error or 'no end marker')
        return t
    volumes = [r for r in rows if r.startswith('VOLUME|')]
    if len(volumes) != 1 or not volumes[0][7:]:
        t['reason'] = 'shadow storage query named no single %s volume' % host['drive']
        return t
    caps, allocs, useds = [], [], []
    alloc_readable = True
    for r in rows:
        if not r.startswith('SHADOW|'):
            continue
        parts = r[7:].split('|')
        if len(parts) != 3:
            t['reason'] = 'malformed shadow storage row'
            return t
        if re.match(r'[0-9]+\Z', parts[0]) and int(parts[0]) >= VSS_UNBOUNDED:
            t['reason'] = 'shadow storage on %s has no cap (unbounded)' % host['drive']
            return t
        cap = parse_int(parts[0])
        if cap is None:
            t['reason'] = 'shadow storage cap is unreadable'
            return t
        caps.append(cap)
        alloc, used = parse_int(parts[1]), parse_int(parts[2])
        if alloc is None:
            alloc_readable = False
        else:
            allocs.append(alloc)
        if used is not None:
            useds.append(used)
    if not caps:
        t.update(state='not-applicable', reserved_bytes=0, cap_bytes=0,
                 allocated_bytes=0, used_bytes=0, cap_proven=True,
                 reason='%s has no shadow storage (restore points off)' % host['drive'])
        return t
    cap = checked_sum(caps)
    if cap is None:
        t['reason'] = 'shadow storage cap is past the integer ceiling'
        return t
    t['cap_bytes'] = cap
    t['cap_proven'] = True
    if useds is not None and len(useds) == len(caps):
        t['used_bytes'] = checked_sum(useds)
    alloc = checked_sum(allocs) if alloc_readable else None
    if alloc is None:
        t.update(state='bounded', reserved_bytes=cap,
                 reason='allocated shadow storage is unreadable, so the whole live cap is reserved')
        return t
    t['allocated_bytes'] = alloc
    t['reserved_bytes'] = max(cap - alloc, 0)
    t['state'] = 'measured'
    return t


def drive_of_pagefile(name):
    d = DRIVE_RE.match(name)
    if not d or name[2:3] != '\\':
        return None
    return d.group(1).upper() + ':'


def measure_pagefile(now, host, lines, why, policy):
    t = common_term(now)
    t.update({'mode': 'unknown', 'allocation_bytes': None, 'maximum_bytes': None,
              'operator_growth_reservation_bytes': None,
              'policy_id': policy['policy_id'] if policy else None,
              'hosting_volumes': None})
    if lines is None:
        t['reason'] = why
        return t
    t['source'] = 'cim'
    rows, error, ended = section(lines, 'PAGEFILE-')
    if error is not None or not ended:
        t['reason'] = 'pagefile query failed: %s' % clean(error or 'no end marker')
        return t
    autos, settings, usage = [], {}, {}
    for r in rows:
        kind, _, rest = r.partition('|')
        parts = rest.split('|')
        if kind == 'AUTO':
            autos.append(rest)
            continue
        if kind not in ('SETTING', 'USAGE') or len(parts) != (3 if kind == 'SETTING' else 2):
            t['reason'] = 'malformed pagefile row'
            return t
        drive = drive_of_pagefile(parts[0])
        sizes = [parse_int(p) for p in parts[1:]]
        if drive is None or None in sizes:
            t['reason'] = 'unreadable pagefile row %s' % clean(parts[0])
            return t
        table = settings if kind == 'SETTING' else usage
        key = parts[0].lower()
        if key in table:
            t['reason'] = 'pagefile %s is listed twice' % clean(parts[0])
            return t
        table[key] = (drive, [s * MIB for s in sizes])
    if len(autos) != 1 or autos[0] not in ('True', 'False'):
        t['reason'] = 'automatic pagefile management is unreadable'
        return t
    c = host['drive']
    hosting = sorted(set(d for d, _ in list(settings.values()) + list(usage.values())))
    t['hosting_volumes'] = ['host-c' if d == c else d for d in hosting]
    c_settings = dict((k, v[1]) for k, v in settings.items() if v[0] == c)
    c_usage = dict((k, v[1][0]) for k, v in usage.items() if v[0] == c)
    t['allocation_bytes'] = checked_sum(c_usage.values())
    if t['allocation_bytes'] is None:
        t['reason'] = 'pagefile allocation is past the integer ceiling'
        return t
    system_managed = autos[0] == 'True' or any(m == 0 for _, m in c_settings.values())
    if system_managed:
        t['mode'] = 'system-managed'
        if policy is None or 'pagefile_system_managed_growth_bytes' not in policy:
            t['reason'] = ('the %s pagefile is system-managed and the site policy has no '
                           'approved growth budget' % c)
            return t
        budget = policy['pagefile_system_managed_growth_bytes']
        t.update(state='bounded', source='cim+policy', reserved_bytes=budget,
                 operator_growth_reservation_bytes=budget,
                 reason='system-managed pagefile: approved growth budget of policy %s'
                        % policy['policy_id'])
        return t
    if not c_settings and not c_usage:
        t.update(mode='off', state='not-applicable', reserved_bytes=0, maximum_bytes=0,
                 reason='no pagefile on %s' % c)
        return t
    t['mode'] = 'fixed'
    if set(c_settings) != set(c_usage):
        t['reason'] = ('the %s pagefile settings and allocations name different files '
                       '(a change waits for a restart)' % c)
        return t
    t['maximum_bytes'] = checked_sum(m for _, m in c_settings.values())
    growth = checked_sum(max(c_settings[k][1] - c_usage[k], 0) for k in c_settings)
    if t['maximum_bytes'] is None or growth is None:
        t['reason'] = 'pagefile maximum is past the integer ceiling'
        return t
    t.update(state='measured', reserved_bytes=growth)
    return t


# ---- the run ---------------------------------------------------------------

def measure(argv):
    pending, policy_path = None, None
    i = 0
    while i < len(argv):
        a = argv[i]
        if a in ('--linux-pending', '--policy') and i + 1 < len(argv):
            if a == '--linux-pending':
                if pending is not None:
                    raise Refused('usage', '--linux-pending given twice')
                pending = parse_int(argv[i + 1])
                if pending is None:
                    raise Refused('usage', '--linux-pending %s is not a nonnegative '
                                  'integer of at most 2**63-1' % clean(argv[i + 1]))
            else:
                if policy_path is not None:
                    raise Refused('usage', '--policy given twice')
                policy_path = argv[i + 1]
            i += 2
            continue
        raise Refused('usage', 'unexpected argument %s (see --help)' % clean(a))
    if pending is None:
        raise Refused('usage', 'measure needs --linux-pending BYTES')
    policy = load_policy(policy_path)

    raw_now = os.environ.get('FM_STORAGE_C_NOW')
    now = parse_int(raw_now) if raw_now else int(time.time())
    if now is None:
        raise Refused('usage', 'FM_STORAGE_C_NOW=%s is not an epoch' % clean(raw_now))
    proc = env('FM_STORAGE_C_PROC', '/proc')
    linux_root = os.path.realpath(env('FM_STORAGE_C_LINUX_ROOT', '/'))
    host_path = os.path.realpath(env('FM_STORAGE_C_HOST', '/mnt/c'))
    mounts, mount_err = [], None
    try:
        mounts = read_mountinfo(proc)
    except (OSError, ValueError) as e:
        mount_err = clean(e)
    statfs = Statfs()
    linux = measure_fs(linux_root, mounts, mount_err, statfs, 'ext4')
    host = measure_fs(host_path, mounts, mount_err, statfs, 'drive')
    if (linux['state'] == 'measured' and host['state'] == 'measured'
            and linux['device'] == host['device']):
        host.update(state='unknown', free_bytes=None,
                    reason='%s is the Linux root device, not a separate drive' % host_path)
    ext4 = measure_ext4(now, linux, host, mounts, policy, pending)
    swap = measure_swap(now, host, ext4, proc, policy)
    lines, why = windows_reading(host)
    vss = measure_vss(now, host, lines, why)
    pagefile = measure_pagefile(now, host, lines, why, policy)

    reasons = []
    for vol, fs in (('linux', linux), ('host-c', host)):
        if fs['state'] == 'unknown':
            reasons.append({'code': 'cannot-measure', 'volume': vol, 'term': None,
                            'detail': clean(fs['reason'])})
    terms = (('ext4_vhdx', ext4), ('swap_vhdx', swap), ('vss', vss), ('pagefile', pagefile))
    for name, term in terms:
        if term['reason'] is not None:
            term['reason'] = clean(term['reason'])
        if term['state'] == 'unknown':
            term['reserved_bytes'] = None
            reasons.append({'code': 'cannot-measure', 'volume': 'host-c', 'term': name,
                            'detail': term['reason']})
    for fs in (linux, host):
        if fs['reason'] is not None:
            fs['reason'] = clean(fs['reason'])
    doc = {'schema': SCHEMA, 'sampled_at': now,
           'free': {'linux': linux, 'host-c': host},
           'c_terms': dict(terms), 'reasons': reasons}
    out = json.dumps(doc, separators=(',', ':'), ensure_ascii=True)
    if not reasons:
        return out, None
    first = reasons[0]
    label = first['term'] or ('%s-free' % first['volume'])
    line = 'wait: cannot-measure: %s:%s: %s' % (first['volume'], label, first['detail'])
    if len(reasons) > 1:
        line += ' (and %d more)' % (len(reasons) - 1)
    return out, line


def main(argv):
    args = argv[1:]
    if args in (['--help'], ['-h']):
        sys.stdout.write(__doc__)
        return 0
    try:
        if not args or args[0] != 'measure':
            raise Refused('usage', 'expected the measure command (see --help)')
        out, wait = measure(args[1:])
    except Refused as e:
        sys.stderr.write('%s: refused: %s: %s\n' % (PROG, e.code, clean(e.detail)))
        return 2
    except Exception as e:  # noqa: BLE001 - one bounded line, never a traceback
        sys.stderr.write('%s: refused: internal: %s\n' % (PROG, clean(repr(e))))
        return 1
    sys.stdout.write(out + '\n')
    if wait is None:
        return 0
    sys.stderr.write('%s: %s\n' % (PROG, wait))
    return 75


if __name__ == '__main__':
    sys.exit(main(sys.argv))
