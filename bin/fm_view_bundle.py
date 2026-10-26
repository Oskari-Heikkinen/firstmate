"""Immutable, bounded Git-blob preparation for the uninstalled read service.

This module has no import-time dependency on a view-engine or home checkout.
It prepares code, not an actor, installation, service start or home mode.
The explicit closure is limited to the admitted fixed passive adapter (tmux)
and the native readers. Adding a reader dependency requires updating it here.
"""
import ctypes
import errno
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import stat
import sys
import tempfile
import time

SCHEMA = "fm-view-bundle.v1"
MAX_FILE = 1024 * 1024
MAX_TOTAL = 32 * 1024 * 1024
MAX_MANIFEST = 64 * 1024
# Full source closure of the admitted adapter operations, including the tmux
# backend's dynamic sibling set. Non-tmux backend operations remain refused.
FILES = tuple(sorted((
    "bin/fm-view-bundle.py", "bin/fm_view_bundle.py", "bin/fm-view-client.py",
    "bin/fm-view-capabilities.py", "bin/fm_view_capabilities.py", "bin/fm_view_protocol.py",
    "bin/fm_view_engine.py", "bin/fm_view_status.py", "bin/fm_view_crew.py",
    "bin/fm_view_runs.py", "bin/fm_view_process.py", "bin/fm_view_offsets.py",
    "bin/fm_view_presentation.py", "bin/fm_view_snapshot.py",
    "bin/fm-view-adapter.sh", "bin/fm-backend.sh", "bin/backends/tmux.sh",
    "bin/fm-tmux-lib.sh", "bin/fm-composer-lib.sh", "bin/fm-cursor-lib.sh",
    "bin/fm-session-lock-lib.sh", "bin/fm-agent-process-lib.sh", "bin/fm-gemini-lib.sh",
    "bin/fm-busy-lib.sh", "bin/fm-suspend-lib.sh", "bin/fm-control-lib.sh",
    "bin/fm-classify-lib.sh", "bin/fm-timeout-lib.sh", "bin/fm-alert-store-lib.sh",
    "bin/fm-parent-channel-lib.sh", "bin/fm-secondmate-parent-lib.sh",
    "bin/fm-dod-lib.sh", "bin/fm-pr-lib.sh", "bin/fm-nm-run-lib.sh", "bin/fm-brief-heading-lib.sh",
)))


class BundleRefused(ValueError):
    pass


def require(value, message):
    if not value:
        raise BundleRefused(message)


def packed(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=True, allow_nan=False).encode() + b"\n"


def unique(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result, "duplicate manifest key")
        result[key] = value
    return result


def digest(raw):
    return hashlib.sha256(raw).hexdigest()


def signature(info):
    return info.st_dev, info.st_ino, info.st_mode, info.st_uid, info.st_nlink, info.st_size, info.st_mtime_ns, info.st_ctime_ns


def directory(path, mode=None):
    path = Path(path)
    require(path.is_absolute() and str(path) == os.path.realpath(path), "noncanonical directory")
    info = path.lstat()
    require(stat.S_ISDIR(info.st_mode) and info.st_uid == os.getuid(), "directory must be owned and nonsymlink")
    if mode is not None:
        require(stat.S_IMODE(info.st_mode) == mode, "directory mode mismatch")
    return path, (info.st_dev, info.st_ino)


def contained(path, root):
    return path == root or root in path.parents


def read_regular(path, limit, mode=None):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(fd, "rb") as stream:
        before = os.fstat(stream.fileno())
        require(stat.S_ISREG(before.st_mode) and before.st_uid == os.getuid() and before.st_nlink == 1,
                "bundle member must be an owned single-link regular file")
        if mode is not None:
            require(stat.S_IMODE(before.st_mode) == mode, "bundle member mode mismatch")
        require(before.st_size <= limit, "bundle member exceeds bound")
        raw = stream.read(limit + 1)
        after = os.fstat(stream.fileno())
    require(len(raw) <= limit and signature(before) == signature(after)
            and signature(after) == signature(os.lstat(path)), "bundle member changed during read")
    return raw


def git(repo, *args, limit=MAX_FILE, deadline=None):
    # Ignore inherited repository locations, config injection and replace refs.
    env = {key: value for key, value in os.environ.items() if not key.startswith("GIT_")}
    env.update(GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL=os.devnull, GIT_NO_REPLACE_OBJECTS="1",
               GIT_TERMINAL_PROMPT="0", GIT_OPTIONAL_LOCKS="0", LC_ALL="C")
    # Preparation reuses the existing identity-owned bounded child runner.
    # Verification deliberately imports no code from the bundle being checked.
    from fm_view_process import run
    remaining = min(20, deadline - time.monotonic()) if deadline is not None else 20
    require(remaining > 0, "Git preparation deadline expired")
    result = run(["git", "--no-pager", "--no-optional-locks", "-c", "core.fsmonitor=false",
                  "-c", "core.hooksPath=/dev/null", "-C", str(repo), *args],
                 str(repo), remaining, env, max_output=max(1, limit))
    require(not result.problem and result.status == 0,
            "Git read refused: " + (result.problem or result.stderr.decode("utf-8", "replace")[:500]))
    require(len(result.stdout) <= limit and len(result.stderr) <= MAX_MANIFEST, "Git output exceeds bound")
    return result.stdout


def pinned_files(repo, commit):
    deadline = time.monotonic() + 120
    def read(*args, **options):
        return git(repo, *args, deadline=deadline, **options)
    require(type(commit) is str and re.fullmatch(r"[0-9a-f]{40}|[0-9a-f]{64}", commit), "full commit identity required")
    require(read("rev-parse", "--show-toplevel").decode().strip() == str(repo), "source must be the canonical checkout root")
    require(not read("status", "--porcelain", "--untracked-files=no", limit=MAX_MANIFEST), "dirty tracked source")
    actual = read("rev-parse", "--verify", commit + "^{commit}").decode().strip()
    require(actual == commit, "commit identity mismatch")
    tree = read("rev-parse", "--verify", commit + "^{tree}").decode().strip()
    records = read("ls-tree", "-z", "-r", "--long", "--full-tree", tree, "--", *FILES, limit=MAX_MANIFEST)
    members = {}
    total = 0
    for record in records.split(b"\0"):
        if not record:
            continue
        header, name = record.split(b"\t", 1)
        mode, kind, oid, raw_size = header.decode("ascii").split()
        name = name.decode("ascii")
        require(name in FILES and name not in members and mode in ("100644", "100755") and kind == "blob",
                "missing or nonregular tracked dependency")
        size = int(raw_size)
        require(0 <= size <= MAX_FILE and total + size <= MAX_TOTAL, "Git dependency exceeds byte bound")
        raw = read("cat-file", "blob", oid, limit=size)
        require(len(raw) == size, "Git blob size mismatch")
        members[name] = (mode, raw)
        total += size
    require(tuple(sorted(members)) == FILES, "incomplete fixed adapter/native dependency closure")
    # Recheck source cleanliness; never consume its mutable working files.
    require(not read("status", "--porcelain", "--untracked-files=no", limit=MAX_MANIFEST), "source changed during preparation")
    manifest = {"schema": SCHEMA, "commit": commit, "tree": tree, "files": [
        {"path": name, "mode": mode, "bytes": len(raw), "sha256": digest(raw)}
        for name, (mode, raw) in sorted(members.items())]}
    return manifest, members


def manifest_check(manifest):
    require(type(manifest) is dict and set(manifest) == {"schema", "commit", "tree", "files"}
            and manifest["schema"] == SCHEMA, "unsupported bundle manifest")
    for field in ("commit", "tree"):
        require(type(manifest[field]) is str and re.fullmatch(r"[0-9a-f]{40}|[0-9a-f]{64}", manifest[field]),
                "invalid pinned Git identity")
    require(type(manifest["files"]) is list and len(manifest["files"]) == len(FILES), "incomplete dependency manifest")
    names, total = [], 0
    for row in manifest["files"]:
        require(type(row) is dict and set(row) == {"path", "mode", "bytes", "sha256"}, "invalid manifest row")
        require(row["path"] in FILES and row["mode"] in ("100644", "100755")
                and type(row["bytes"]) is int and 0 <= row["bytes"] <= MAX_FILE
                and type(row["sha256"]) is str and re.fullmatch(r"[0-9a-f]{64}", row["sha256"]), "invalid manifest member")
        names.append(row["path"])
        total += row["bytes"]
    require(tuple(names) == FILES and total <= MAX_TOTAL, "unordered, duplicate or oversized dependency closure")


def verify(bundle, expected=None):
    bundle, original = directory(bundle, 0o500)
    require(re.fullmatch(r"[0-9a-f]{64}", bundle.name), "bundle name is not its content identity")
    if expected is not None:
        require(bundle.name == expected, "bundle identity mismatch")
    raw = read_regular(bundle / "manifest.json", MAX_MANIFEST, 0o400)
    require(digest(raw) == bundle.name, "manifest content identity mismatch")
    manifest = json.loads(raw, object_pairs_hook=unique)
    manifest_check(manifest)
    require(packed(manifest) == raw, "noncanonical bundle manifest")
    expected_paths = {"manifest.json", "bin", "bin/backends", *FILES}
    actual_paths = set()
    # The tree is shallow and its permitted contents are fixed before walking.
    for folder, dirs, files in os.walk(bundle, followlinks=False):
        require(len(dirs) + len(files) <= len(FILES) + 3, "bundle directory exceeds bound")
        for name in dirs + files:
            path = Path(folder) / name
            relative = str(path.relative_to(bundle))
            require(relative in expected_paths, "unexpected bundle member")
            actual_paths.add(relative)
            if relative in ("bin", "bin/backends"):
                directory(path, 0o500)
    require(actual_paths == expected_paths, "missing bundle member")
    for row in manifest["files"]:
        mode = 0o500 if row["mode"] == "100755" else 0o400
        content = read_regular(bundle / row["path"], MAX_FILE, mode)
        require(len(content) == row["bytes"] and digest(content) == row["sha256"], "dependency hash mismatch: " + row["path"])
    require(directory(bundle, 0o500)[1] == original, "bundle root replaced")
    return manifest


def write_new(path, raw, mode):
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, "wb") as stream:
        stream.write(raw)
        stream.flush()
        os.fchmod(stream.fileno(), mode)
        os.fsync(stream.fileno())


def rename_new(source, target):
    # Unlike os.rename, RENAME_NOREPLACE cannot replace even an empty version
    # directory created concurrently. Unsupported kernels refuse preparation.
    require(sys.platform == "linux", "atomic nonreplacing bundle publication requires Linux")
    libc = ctypes.CDLL(None, use_errno=True)
    operation = getattr(libc, "renameat2", None)
    require(operation is not None, "nonreplacing rename unsupported")
    operation.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
    operation.restype = ctypes.c_int
    if operation(-100, os.fsencode(source), -100, os.fsencode(target), 1) != 0:
        code = ctypes.get_errno()
        if code == errno.EEXIST:
            raise FileExistsError(code, os.strerror(code), str(target))
        raise BundleRefused("nonreplacing publication refused: " + os.strerror(code))


def prepare(repo, commit, store, home):
    repo, repo_identity = directory(repo)
    home, home_identity = directory(home)
    directory(home / "state")
    store, store_identity = directory(store, 0o700)
    require(not contained(store, repo) and not contained(store, home), "bundle store must be outside checkout and operational home")
    # Any containing Git checkout is forbidden, including a different pool copy.
    for parent in (store, *store.parents):
        require(not os.path.lexists(parent / ".git"), "bundle store is inside a Git checkout")
    manifest, members = pinned_files(repo, commit)
    raw = packed(manifest)
    require(len(raw) <= MAX_MANIFEST, "manifest exceeds bound")
    version = digest(raw)
    target = store / version
    if os.path.lexists(target):
        verify(target, version)
        require(directory(store, 0o700)[1] == store_identity and directory(home)[1] == home_identity
                and directory(repo)[1] == repo_identity, "preparation root replaced")
        return target
    stage = Path(tempfile.mkdtemp(prefix=".prepare-", dir=store))
    staging_identity = directory(stage)[1]
    try:
        (stage / "bin").mkdir(mode=0o700)
        (stage / "bin/backends").mkdir(mode=0o700)
        for name, (mode, content) in members.items():
            write_new(stage / name, content, 0o500 if mode == "100755" else 0o400)
        write_new(stage / "manifest.json", raw, 0o400)
        for path in (stage / "bin/backends", stage / "bin", stage):
            os.chmod(path, 0o500)
            fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
            try:
                os.fsync(fd)
            finally:
                os.close(fd)
        require(directory(store, 0o700)[1] == store_identity and directory(repo)[1] == repo_identity
                and directory(home)[1] == home_identity, "preparation root replaced")
        try:
            rename_new(stage, target)
        except FileExistsError:
            # A concurrent publisher may have produced this identical version;
            # it is never repaired, replaced or accepted without full checking.
            verify(target, version)
        verify(target, version)
        require(directory(store, 0o700)[1] == store_identity, "store replaced during publication")
        fd = os.open(store, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        try:
            os.fsync(fd)
        finally:
            os.close(fd)
        return target
    finally:
        if os.path.lexists(stage):
            # A replaced store/staging path is not cleanup authority. fd-based
            # chmod refuses links; rmtree's fd walk never follows nested links.
            require(directory(store, 0o700)[1] == store_identity
                    and directory(stage)[1] == staging_identity, "staging identity changed; cleanup refused")
            for relative in ("", "bin", "bin/backends"):
                path = stage / relative
                if not os.path.lexists(path):
                    continue
                fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
                try:
                    os.fchmod(fd, 0o700)
                finally:
                    os.close(fd)
            shutil.rmtree(stage)
