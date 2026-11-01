"""Copied as sitecustomize.py ONLY inside a marker test's private world.

Make a real file change at the fstat/read or DirEntry.stat/open boundary.
This modifies OS inputs, not production predicates or parser results.
"""
import os

_case = os.environ.get("PACK_MARKER_IO_CASE")
_target = os.environ.get("PACK_MARKER_IO_TARGET")
_fstat, _open = os.fstat, os.open
_fired = False


def changing_fstat(fd):
    global _fired
    st = _fstat(fd)
    if not _fired and _case == "read-growth" and os.readlink("/proc/self/fd/" + str(fd)) == _target:
        _fired = True
        with open(_target, "ab") as stream:
            stream.write(b" " * 65537)
    return st


def changing_open(path, flags, *args, **kwargs):
    global _fired
    fd = _open(path, flags, *args, **kwargs)
    if not _fired and _case == "source-open" and str(path) == _target:
        _fired = True
        with open(_target, "ab") as stream:
            stream.write(b"x")
    return fd


if _case == "read-growth":
    os.fstat = changing_fstat
elif _case == "source-open":
    os.open = changing_open
