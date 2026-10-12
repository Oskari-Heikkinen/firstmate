"""Local IO shared by fleet-sync receipts, the fleet board and usage audit."""
import datetime
import hashlib
import json
import os
from pathlib import Path
import re
import tempfile

LIMIT = 2 * 1024 * 1024


def load(path, limit=LIMIT):
    if not Path(path).is_file():
        raise ValueError("JSON input must be a regular file")
    with open(path, "rb") as stream:
        data = stream.read(limit + 1)
    if len(data) > limit:
        raise ValueError("JSON input exceeds byte bound")
    return json.loads(data)


def digest(data):
    return hashlib.sha256(data).hexdigest()


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":")).encode()


def emit(value):
    print(json.dumps(value, sort_keys=True, indent=2))


def text(value):
    if not isinstance(value, str) or not value or any(ord(c) < 32 for c in value):
        raise ValueError("expected nonempty single-line string")
    return value


def number(value):
    if isinstance(value, bool) or not isinstance(value, (int, float)) or not 0 <= value < 1e20:
        raise ValueError("expected finite nonnegative number")
    return value


def local_path(home, value):
    path = Path(value)
    path = (home / path).resolve() if not path.is_absolute() else path.resolve()
    if path != home and home not in path.parents:
        raise ValueError("reference outside selected home")
    return path


def iso_epoch(value, *, numeric=False):
    if numeric and isinstance(value, (int, float)):
        return int(value)
    if not isinstance(value, str):
        return None
    if numeric and re.fullmatch(r"\d{9,11}", value):
        return int(value)
    try:
        return int(datetime.datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp())
    except ValueError:
        return None


def atomic_text(path, value):
    # Board outputs retain their existing UTF-8, PID-temp, non-fsync semantics.
    tmp = "%s.tmp.%d" % (path, os.getpid())
    with open(tmp, "w", encoding="utf-8") as stream:
        stream.write(value)
    os.replace(tmp, path)


def atomic(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, name = tempfile.mkstemp(prefix=".receipt-", dir=path.parent)
    try:
        with os.fdopen(fd, "w") as stream:
            json.dump(value, stream, sort_keys=True)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(name, path)
    finally:
        if os.path.exists(name):
            os.unlink(name)
