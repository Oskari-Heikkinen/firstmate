#!/usr/bin/env python3
"""Private checked spools: seal FILE KIND; read FILE; inspect FILE; summary FILE N.

KIND is lines (LF required), text (optional final LF), nul, or matches
(filename-NUL/line-LF pairs). The producer seals only after a successful write.
The seal binds bytes, framing and file identity. Consumers validate while
streaming and emit their completion frame only after checked EOF and close.
read emits D-prefixed NUL-terminated fields, then E-NUL on success. This makes
shell EOF, including an open or mid-read error, distinct from successful EOF.
All files and sidecars belong in the caller-owned per-run scratch directory.
"""
from contextlib import closing
import hashlib
import json
import os
import stat
import sys
import tempfile


class SpoolError(ValueError):
    """Private input failed, not evidence that the original source was lost."""


def signature(info):
    return [info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns, info.st_ctime_ns]


def open_regular(path):
    fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK | getattr(os, 'O_NOFOLLOW', 0))
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or not info.st_mode & 0o444:
            raise OSError('not a readable regular file: ' + path)
        return os.fdopen(fd, 'rb'), signature(info)
    except BaseException:
        os.close(fd)
        raise


def chunks(path, expected=None):
    source, before = open_regular(path)
    digest = hashlib.sha256()
    with source:
        if expected is not None and before != expected['identity']:
            raise ValueError('spool identity changed: ' + path)
        while True:
            block = source.read(65536)
            if not block:
                break
            digest.update(block)
            yield block
        if signature(os.fstat(source.fileno())) != before or signature(os.lstat(path)) != before:
            raise ValueError('spool changed during read: ' + path)
    if expected is not None and digest.hexdigest() != expected['sha256']:
        raise ValueError('spool bytes changed: ' + path)


def fields(blocks, kind):
    pending = b''
    delimiter = b'\0' if kind in ('nul', 'matches') else b'\n'
    pair = 0
    for block in blocks:
        pending += block
        while True:
            position = pending.find(delimiter)
            if position < 0:
                break
            value, pending = pending[:position], pending[position + 1:]
            if kind != 'nul' and b'\0' in value:
                raise ValueError('NUL in line spool')
            yield value
            if kind == 'matches':
                pair = 1 - pair
                delimiter = b'\n' if pair else b'\0'
    if pending:
        if kind == 'text' and b'\0' not in pending:
            yield pending
        else:
            raise ValueError('incomplete spool framing')
    if kind == 'matches' and pair:
        raise ValueError('incomplete matches pair')


def seal(path, kind):
    if kind not in ('lines', 'text', 'nul', 'matches'):
        raise ValueError('invalid spool kind')
    source, identity = open_regular(path)
    digest = hashlib.sha256()
    with source:
        def blocks():
            while True:
                block = source.read(65536)
                if not block:
                    break
                digest.update(block)
                yield block
        for _ in fields(blocks(), kind):
            pass
        if signature(os.fstat(source.fileno())) != identity or signature(os.lstat(path)) != identity:
            raise ValueError('spool changed while sealing: ' + path)
    record = {'version': 1, 'kind': kind, 'identity': identity, 'sha256': digest.hexdigest()}
    fd, temporary = tempfile.mkstemp(prefix='.spool-seal.', dir=os.path.dirname(path) or '.')
    try:
        with os.fdopen(fd, 'w', encoding='ascii') as out:
            json.dump(record, out)
            out.write('\n')
        os.replace(temporary, path + '.seal')
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def load_seal(path):
    source, _ = open_regular(path + '.seal')
    with source:
        raw = source.read(4097)
    if len(raw) > 4096:
        raise ValueError('oversized spool seal')
    expected = json.loads(raw)
    if (not isinstance(expected, dict) or expected.get('version') != 1
            or expected.get('kind') not in ('lines', 'text', 'nul', 'matches')
            or not isinstance(expected.get('identity'), list) or len(expected['identity']) != 5
            or any(type(number) is not int for number in expected['identity'])
            or not isinstance(expected.get('sha256'), str) or len(expected['sha256']) != 64
            or any(char not in '0123456789abcdef' for char in expected['sha256'])):
        raise ValueError('invalid spool seal')
    return expected


def records(path):
    try:
        expected = load_seal(path)
        with closing(chunks(path, expected)) as blocks:
            yield from fields(blocks, expected['kind'])
    except (OSError, ValueError, TypeError, KeyError, IndexError) as exc:
        raise SpoolError('checked spool ' + path + ': ' + str(exc)) from exc


def inspect(path):
    # A bounded emptiness decision at finish time: staging already consumed and
    # verified the full spool. Bind its identity and read the byte needed for
    # this decision, not the whole regular-file manifest under the lock.
    expected = load_seal(path)
    source, before = open_regular(path)
    with source:
        if before != expected['identity']:
            raise ValueError('spool identity changed: ' + path)
        present = bool(source.read(1))
        if present != (before[2] != 0) or signature(os.fstat(source.fileno())) != before or signature(os.lstat(path)) != before:
            raise ValueError('spool changed during inspection: ' + path)
    return present


def main():
    mode, path, *args = sys.argv[1:]
    if mode == 'seal':
        seal(path, *args)
    elif mode == 'read':
        for value in records(path):
            sys.stdout.buffer.write(b'D' + value + b'\0')
        # No consumer may treat a missing completion frame as an empty stream.
        sys.stdout.buffer.write(b'E\0')
        sys.stdout.buffer.flush()
    elif mode == 'inspect':
        print('1' if inspect(path) else '0')
    elif mode == 'cat':
        for value in records(path):
            sys.stdout.buffer.write(value + b'\n')
        sys.stdout.buffer.flush()
    elif mode == 'contains':
        wanted = os.fsencode(args[0])
        found = False
        for value in records(path):
            found = found or value == wanted
        return 0 if found else 1
    elif mode == 'summary':
        limit = int(args[0])
        if limit < 0 or limit > 10:
            raise ValueError('invalid summary limit')
        first = []
        for value in records(path):
            if len(first) < limit:
                first.append(value)
        for value in first:
            sys.stdout.buffer.write(value + b'\n')
    else:
        raise ValueError('invalid spool operation')


if __name__ == '__main__':
    try:
        sys.exit(main() or 0)
    except BrokenPipeError:
        # A refusing shell consumer may cancel its producer. Do not emit an
        # unraisable shutdown traceback; absence of E still prevents success.
        os._exit(1)
    except (OSError, ValueError, TypeError, KeyError, IndexError) as exc:
        print('REFUSED: checked spool: ' + str(exc), file=sys.stderr)
        sys.exit(2)
