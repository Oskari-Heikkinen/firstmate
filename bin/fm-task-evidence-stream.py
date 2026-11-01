#!/usr/bin/env python3
"""Disk-backed evidence operations for fm-task-evidence-lib.sh.

Usage: copies SRC DEST KEY MANIFEST RELS; verify ROOT MANIFEST;
       snapshot ROOT SCRATCH INDEX KEY; recheck STAGING SCRATCH COUNT.
RELS is a newline-delimited relative-suffix file (including empty suffix).
No collection grows with tree membership: hashes use fixed batches, inventories
and manifest lookups use SQLite with a fixed cache and disk temporary tables.
Scratch belongs to the caller's scan directory; this helper never removes roots.
"""
import hashlib
import os
import shutil
import sqlite3
import stat
import subprocess
import sys
import time


def refuse(message):
    raise RuntimeError(message)


def hash_group(paths):
    tool = shutil.which('shasum')
    command = [tool, '-a', '256'] if tool else [shutil.which('sha256sum')]
    if not command[0]:
        refuse('no evidence hash tool')
    result = subprocess.run(command + paths, stdout=subprocess.PIPE,
                            stderr=subprocess.DEVNULL, check=False)
    lines = result.stdout.splitlines()
    hashes = [line.split()[0] if line.split() else b'' for line in lines]
    if result.returncode == 0 and len(hashes) == len(paths) and all(hashes):
        return hashes
    # Preserve per-file fallback and refusal order, including empty hashes.
    hashes = []
    for path in paths:
        result = subprocess.run(command + [path], stdout=subprocess.PIPE,
                                stderr=subprocess.DEVNULL, check=False)
        words = result.stdout.split()
        hashes.append(words[0] if result.returncode == 0 and words else b'')
    return hashes


def batches(lines):
    batch, size = [], 0
    for line in lines:
        if batch and (len(batch) >= 64 or size + len(line) > 16384):
            yield batch
            batch, size = [], 0
        batch.append(line)
        size += len(line)
    if batch:
        yield batch


def hash_batch(paths):
    hashes = []
    for group in batches(paths):
        hashes.extend(hash_group(group))
    return hashes


def copies(src, dest, key, manifest, rels):
    with open(rels, 'rb') as names:
        for group in batches(names):
            suffixes = [os.fsdecode(line[:-1]) for line in group]
            if any(not line.endswith(b'\n') for line in group):
                refuse('incomplete evidence path list')
            paths = [src + rel for rel in suffixes] + [dest + rel for rel in suffixes]
            hashes = hash_batch(paths)
            for i, rel in enumerate(suffixes):
                left, right = hashes[i], hashes[len(suffixes) + i]
                if not left or not right:
                    refuse('cannot hash copied evidence ' + dest + rel)
                if left != right:
                    refuse('copied evidence ' + dest + rel + ' does not match its source')
                with open(manifest, 'ab') as out:
                    out.write(right + b'  ' + os.fsencode(key + rel) + b'\n')


def verify(root, manifest, task=''):
    with open(manifest, 'rb') as lines:
        for group in batches(lines):
            rows = [line.rstrip(b'\n').split(b'  ', 1) for line in group]
            if any(len(row) != 2 for row in rows):
                refuse('malformed evidence manifest')
            hashes = hash_batch([os.path.join(root, os.fsdecode(row[1])) for row in rows])
            for row, actual in zip(rows, hashes):
                if not actual or actual != row[0]:
                    refuse('staged evidence ' + os.fsdecode(row[1]) +
                           (' for ' + task if task else '') + ' failed verification')


def database(path, existing=False):
    if existing:
        info = os.lstat(path)
        if not stat.S_ISREG(info.st_mode) or not info.st_mode & 0o444 or not info.st_size:
            refuse('unreadable or non-regular evidence snapshot ' + path)
    db = sqlite3.connect(path)
    db.execute('PRAGMA cache_size=-2048')
    db.execute('PRAGMA temp_store=FILE')
    return db


def inventory(db, root, table):
    # A disk queue avoids both readdir's whole-directory array and one open
    # directory handle per nesting level. Path names are BLOBs, not Unicode.
    db.execute('CREATE TABLE ' + table + ' (path BLOB PRIMARY KEY, sig TEXT, stamp REAL)')
    db.execute('CREATE TEMP TABLE pending (id INTEGER PRIMARY KEY, path BLOB)')
    if os.path.lexists(root):
        db.execute('INSERT INTO pending(path) VALUES (?)', (os.fsencode(root),))
    while True:
        row = db.execute('SELECT id,path FROM pending ORDER BY id LIMIT 1').fetchone()
        if row is None:
            break
        ident, path = row
        db.execute('DELETE FROM pending WHERE id=?', (ident,))
        stamp = None
        try:
            s = os.lstat(path)
            fields = [s.st_dev, s.st_ino, s.st_mode, s.st_uid, s.st_gid, s.st_rdev]
            is_dir = stat.S_ISDIR(s.st_mode)
            if not is_dir:
                fields += [s.st_nlink, s.st_size, s.st_mtime_ns, s.st_ctime_ns]
            signature = ':'.join(map(str, fields))
            if stat.S_ISREG(s.st_mode):
                stamp = max(s.st_mtime, s.st_ctime)
            if stat.S_ISLNK(s.st_mode):
                signature += ':link:' + os.readlink(path).hex()
            if is_dir:
                try:
                    with os.scandir(path) as entries:
                        for entry in entries:
                            db.execute('INSERT INTO pending(path) VALUES (?)', (entry.path,))
                except OSError:
                    signature += ':unlisted'
        except OSError:
            signature = 'unreadable'
        db.execute('INSERT INTO ' + table + ' VALUES (?,?,?)', (path, signature, stamp))
    db.execute('DROP TABLE pending')


def snapshot(root, scratch, index, key):
    if not index or any(c not in '0123456789' for c in index):
        refuse('evidence copy check: invalid snapshot invocation')
    path = os.path.join(scratch, 'snapshot.' + index + '.sqlite')
    with database(path) as db:
        db.execute('CREATE TABLE info (root BLOB, key BLOB, t0 REAL)')
        db.execute('INSERT INTO info VALUES (?,?,?)', (os.fsencode(root), os.fsencode(key), time.time() - 3))
        inventory(db, root, 'saved')


def recheck(staging, scratch, count):
    if not count or any(c not in '0123456789' for c in count):
        refuse('evidence copy check: invalid recheck invocation')
    # Index the manifest once on disk. Racy entries use an indexed lookup, not
    # a whole-manifest hash table or a repeated whole-manifest scan.
    with database(os.path.join(scratch, 'recheck.sqlite')) as manifests:
        manifests.execute('CREATE TABLE IF NOT EXISTS hashes (name BLOB PRIMARY KEY, hash BLOB)')
        manifests.execute('DELETE FROM hashes')
        with open(os.path.join(staging, 'MANIFEST.sha256'), 'rb') as lines:
            for line in lines:
                fields = line.rstrip(b'\n').split(b'  ', 1)
                digest = fields[0].lstrip(b'\\')
                if len(fields) != 2 or len(digest) != 64 or any(c not in b'0123456789abcdef' for c in digest):
                    refuse('evidence copy check: malformed staged manifest line')
                manifests.execute('INSERT OR REPLACE INTO hashes VALUES (?,?)', (fields[1], digest))
        for index in range(int(count)):
            with database(os.path.join(scratch, 'snapshot.' + str(index) + '.sqlite'), existing=True) as db:
                root, key, t0 = db.execute('SELECT root,key,t0 FROM info').fetchone()
                db.execute('DROP TABLE IF EXISTS current')
                inventory(db, root, 'current')
                extra = db.execute('SELECT path FROM current WHERE path NOT IN (SELECT path FROM saved) LIMIT 1').fetchone()
                if extra:
                    refuse('evidence copy check: ' + os.fsdecode(extra[0]) + ' changed while it was copied outside the project lock')
                rows = db.execute('SELECT saved.path,saved.sig,current.sig,current.stamp FROM saved LEFT JOIN current USING(path) ORDER BY saved.path')
                for path, before, after, stamp in rows:
                    retimed = False
                    if before != after:
                        a, b = before.split(':'), after.split(':') if after else []
                        retimed = len(a) == len(b) == 10 and a[:8] == b[:8] and stat.S_ISREG(int(a[2]))
                        if not retimed:
                            refuse('evidence copy check: ' + os.fsdecode(path) + ' changed while it was copied outside the project lock')
                    if stamp is None or (not retimed and stamp < t0):
                        continue
                    expected = manifests.execute('SELECT hash FROM hashes WHERE name=?', (key + path[len(root):],)).fetchone()
                    if expected is None and not retimed:
                        continue
                    digest = hashlib.sha256()
                    with open(path, 'rb') as source:
                        while True:
                            block = source.read(1024 * 1024)
                            if not block:
                                break
                            digest.update(block)
                    if expected is None or digest.hexdigest().encode() != expected[0]:
                        refuse('evidence copy check: ' + os.fsdecode(path) + ' changed while it was copied outside the project lock')


if __name__ == '__main__':
    try:
        modes = {'copies': copies, 'verify': verify, 'snapshot': snapshot, 'recheck': recheck}
        modes[sys.argv[1]](*sys.argv[2:])
    except (OSError, RuntimeError, sqlite3.Error, ValueError, TypeError, KeyError, IndexError) as exc:
        message = str(exc)
        if len(sys.argv) > 1 and sys.argv[1] in ('snapshot', 'recheck'):
            if not message.startswith('evidence copy check: '):
                message = 'evidence copy check: ' + message
            message += '; nothing was changed; retry teardown'
        print('REFUSED: ' + message, file=sys.stderr)
        sys.exit(1)
