#!/usr/bin/env python3
"""Adversarial checked-spool inputs and real mid-read fault injection (CI only)."""
import errno
import io
import json
import os
from pathlib import Path
import sys
from types import SimpleNamespace
from unittest.mock import patch

sys.path.insert(0, sys.argv[1])
import fm_spool as spool

root = Path(sys.argv[2])
root.mkdir(parents=True)


def rejects(call, message):
    try:
        call()
    except (OSError, ValueError, TypeError, KeyError, IndexError):
        return
    raise AssertionError(message)


def command(mode, path, *args):
    output = io.BytesIO()
    with patch.object(sys, 'argv', ['fm_spool.py', mode, str(path), *args]), patch.object(sys, 'stdout', SimpleNamespace(buffer=output)):
        result = spool.main()
    return result, output.getvalue()


for kind in ('lines', 'text', 'nul', 'matches'):
    path = root / ('empty-' + kind)
    path.write_bytes(b'')
    spool.seal(str(path), kind)
    assert list(spool.records(str(path))) == []
    assert not spool.inspect(str(path))
    assert command('read', path)[1] == b'E\0'
    assert command('summary', path, '5')[1] == b''
    assert command('contains', path, 'missing')[0] == 1

for index, (kind, content, expected) in enumerate((
        ('lines', b'\n \nE\nDhello\n', [b'', b' ', b'E', b'Dhello']),
        ('text', b'no final newline', [b'no final newline']),
        ('nul', b'a\nb\0E\0', [b'a\nb', b'E']),
        ('matches', b'record\0line\nother\0\n', [b'record', b'line', b'other', b'']))):
    path = root / ('control-' + str(index))
    path.write_bytes(content)
    spool.seal(str(path), kind)
    assert list(spool.records(str(path))) == expected
    assert spool.inspect(str(path))
    assert command('read', path)[1] == b''.join(b'D' + value + b'\0' for value in expected) + b'E\0'

for index, (kind, content) in enumerate((('lines', b'partial'), ('lines', b'bad\0line\n'),
        ('nul', b'partial'), ('matches', b'record\0'), ('matches', b'record\0partial'),
        ('matches', b'record\0bad\0line\n'))):
    path = root / ('framing-' + str(index))
    path.write_bytes(content)
    rejects(lambda: spool.seal(str(path), kind), 'malformed framing was sealed')

for shape in ('missing', 'empty', 'space', 'no-newline', 'partial', 'truncate-regrow',
              'mode000', 'symlink', 'dangling', 'directory', 'fifo'):
    path = root / shape
    path.write_bytes(b'first\nlast\n')
    spool.seal(str(path), 'lines')
    if shape in ('missing', 'symlink', 'dangling', 'directory', 'fifo'):
        path.unlink()
        if shape == 'symlink':
            path.symlink_to(root / 'control-0')
        elif shape == 'dangling':
            path.symlink_to(root / 'absent')
        elif shape == 'directory':
            path.mkdir()
        elif shape == 'fifo':
            os.mkfifo(path)
    elif shape == 'mode000':
        path.chmod(0)
    else:
        path.write_bytes({'empty': b'', 'space': b' ', 'no-newline': b'first\nlast',
                          'partial': b'first\nla', 'truncate-regrow': b'other\nlast\n'}[shape])
    rejects(lambda: list(spool.records(str(path))), shape + ' was read as healthy input')
    rejects(lambda: spool.inspect(str(path)), shape + ' was classified as healthy emptiness')
    rejects(lambda: command('summary', path, '5'), shape + ' produced a successful summary')

for index, raw in enumerate((b'', b' ', b'null', b'[]', b'{', b'\0', b' ' * 4097,
                             json.dumps({'version': 1, 'kind': 'lines', 'identity': None}).encode())):
    path = root / ('seal-' + str(index))
    path.write_bytes(b'valid\n')
    Path(str(path) + '.seal').write_bytes(raw)
    rejects(lambda: list(spool.records(str(path))), 'invalid seal accepted')

# A real readable file, complete valid seal and successful first block. The
# next read raises EIO, rather than simulating empty output or failed hashing.
path = root / 'mid-read'
path.write_bytes(b'first\n' * 30000)
spool.seal(str(path), 'lines')
real_open = spool.open_regular


class Interrupted:
    def __init__(self, stream, fail_at):
        self.stream, self.fail_at, self.reads = stream, fail_at, 0

    def __enter__(self):
        return self

    def __exit__(self, *args):
        self.stream.close()

    def fileno(self):
        return self.stream.fileno()

    def read(self, length):
        self.reads += 1
        if self.reads == self.fail_at:
            raise OSError(errno.EIO, 'injected mid-read I/O error')
        return self.stream.read(length)


def interrupted_open(name):
    stream, identity = real_open(name)
    return (Interrupted(stream, 2), identity) if name == str(path) else (stream, identity)


with patch.object(spool, 'open_regular', interrupted_open):
    seen = []
    def read_all():
        for value in spool.records(str(path)):
            seen.append(value)
    rejects(read_all, 'mid-stream error accepted as EOF')
    assert seen and len(seen) < 30000
    for mode, args in (('read', []), ('cat', []), ('summary', ['5']), ('contains', ['first'])):
        output = io.BytesIO()
        with patch.object(sys, 'argv', ['fm_spool.py', mode, str(path), *args]), patch.object(sys, 'stdout', SimpleNamespace(buffer=output)):
            rejects(spool.main, mode + ' accepted a mid-read error')
        if mode == 'read':
            assert output.getvalue().startswith(b'Dfirst\0')
            assert not output.getvalue().endswith(b'E\0'), 'failed stream emitted completion'
        if mode == 'summary':
            assert output.getvalue() == b'', 'summary escaped before checked EOF'

# The bounded emptiness read must propagate its own error, even for a file
# whose metadata says it is empty. Neither mode 000 nor FIFO probes depend on
# uid, root permission bypasses, or a fixed sleep.
empty = root / 'empty-inspection'
empty.write_bytes(b'')
spool.seal(str(empty), 'lines')
def failed_open(name):
    stream, identity = real_open(name)
    return (Interrupted(stream, 1), identity) if name == str(empty) else (stream, identity)
with patch.object(spool, 'open_regular', failed_open):
    rejects(lambda: spool.inspect(str(empty)), 'failed empty read was healthy')

print('ok - checked spool framing, controls, adversarial files and mid-stream errors')
