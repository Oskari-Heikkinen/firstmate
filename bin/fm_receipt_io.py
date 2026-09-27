"""Bounded local JSON/reference IO shared by observational receipt tools."""
import hashlib
import json
import os
from pathlib import Path
import tempfile
import time

LIMIT = 2 * 1024 * 1024


def load(path):
    if not Path(path).is_file():
        raise ValueError("JSON input must be a regular file")
    with open(path, "rb") as stream:
        data = stream.read(LIMIT + 1)
    if len(data) > LIMIT:
        raise ValueError("JSON input exceeds 2 MiB")
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


def reference(home, ref):
    path = local_path(home, text(ref["path"]))
    if not path.is_file():
        raise ValueError("reference must be a regular file")
    with path.open("rb") as stream:
        data = stream.read(LIMIT + 1)
    if len(data) > LIMIT or digest(data) != ref["sha256"]:
        raise ValueError("reference too large or digest mismatch")
    return path, data


def freshness(observed_at, max_age):
    age = time.time() - number(observed_at)
    return {"observed_at": observed_at, "age_seconds": age,
            "state": "fresh" if 0 <= age <= max_age else "stale"}


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
