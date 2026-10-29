#!/usr/bin/env python3
"""Read-only: the storage class map's generated site roots, and D: health.

Usage:
  fm-storage-roots.py site-config --here HOST
      Validate the whole class map, prove every root on this host, and print
      one lattice-xp-roots/v1 object (compact JSON, keys schema, here,
      metadata, roots, classes; roots and classes sorted by name).
  fm-storage-roots.py health --volume d
      Print "ok" when the published D: results volume is proven now, else
      "offline REASON" (exit 75, stderr empty). The proof is
      fm-storage.sh verify-bulk-root, run as a child with a 30 s bound.

Neither command creates, mounts, probes, reserves or repairs anything, and
neither calls Windows. docs/storage.md owns the class map format
(fm-storage-class-map/v1), the placement rules and the generated object.

Class map: <config dir>/class-map.json, the config dir being fm-storage.sh's
(FM_STORAGE_CONFIG, else ${XDG_CONFIG_HOME:-~/.config}/lattice-storage).
With no map, site-config refuses no-class-map and nothing is generated.

site-config checks, in order, stopping at the first failure:
  1. The map parses strictly (no duplicate key, NaN or trailing data) and
     has exactly the closed fields; HOST is a host id or alias in it.
  2. The machine id file holds the machine_id the map gives HOST.
  3. Every root is local to HOST (a remote or ssh root is unproven), on
     volume linux or d (host-c is refused), at a canonical absolute path; a
     d root sits under <mnt>/d/lattice-data in lower-case, Windows-safe
     names away from the legacy tetjet-results, research and archive
     directories; no two roots are equal or nested.
  4. undeclared-default and metadata-view are bound; metadata-view's root
     is on linux and every other class's root is on d.
  5. verify-bulk-root proves the published D: volume.
  6. Each root exists as a directory with no symlink on its path, and its
     device matches its mount in the mount table.
  7. No two roots are the same place by mount source, bind, inode or
     ancestor (case-insensitive on a Windows-backed mount).
  8. A d root's mount is <mnt>/d itself (9p or drvfs, source D:) with that
     mount's device and size; a linux root is on the mount at /.
  9. Each root holds .lattice-xp-root.json with exactly its own marker bytes.

Exit codes:
  0   success, one stdout line
  2   refused: misuse, or a malformed, forbidden or overlapping map;
      stderr "fm-storage: refused: CODE: DETAIL"
  75  wait: storage is offline or cannot be proven now; site-config prints
      stderr "fm-storage: wait: CODE: DETAIL" and health prints
      stdout "offline REASON"
  Stdout is empty unless the exit is 0, or 75 from health.

Refusal codes: usage, no-class-map, invalid-class-map, unknown-host,
host-mismatch, host-unproven, remote-unproven, forbidden-placement,
root-path, root-overlap, root-alias, root-symlink, unknown-root,
missing-class. Wait codes: storage-offline, cannot-measure.

Environment (all optional):
  FM_STORAGE_CONFIG     config dir holding class-map.json
  FM_STORAGE_MNT        WSL mount base (default /mnt)
  FM_STORAGE_MOUNTINFO  mount table (default /proc/self/mountinfo)
  FM_STORAGE_MACHINE_ID machine id file (default /etc/machine-id)
  Every other FM_STORAGE_* and FM_DISK_ROOM_HOST setting reaches
  verify-bulk-root unchanged.
"""
import errno
import json
import os
import posixpath
import re
import signal
import stat
import subprocess
import sys

MAP_SCHEMA = "fm-storage-class-map/v1"
ROOTS_SCHEMA = "lattice-xp-roots/v1"
MARKER = ".lattice-xp-root.json"
MARKER_SCHEMA = "lattice-xp-root-marker/v1"
MAP_MAX = 65536
NAME = re.compile(r"[a-z0-9-]{1,40}")
MACHINE_ID = re.compile(r"[0-9a-f]{32}")
# One lower-case Windows-safe spelling per D: name: no case, 8.3 (~), stream
# (:) or trailing-dot alias can name the same place twice.
D_PART = re.compile(r"[a-z0-9_-]([a-z0-9._-]*[a-z0-9_-])?")
RESERVED = {"con", "prn", "aux", "nul"} | {"com%d" % i for i in range(1, 10)} | {"lpt%d" % i for i in range(1, 10)}
LEGACY_D = ("tetjet-results", "research", "archive")
VOLUMES = ("linux", "host-c", "d")
WINDOWS_FS = ("9p", "drvfs")
PAYLOAD_EXEMPT = "metadata-view"
REQUIRED = ("undeclared-default", "metadata-view")
VERIFY_TIMEOUT = 30
DETAIL_MAX = 300
MAX_HOPS = 40


class Stop(Exception):
    """One refusal (rc 2) or wait (rc 75) with its stable code."""

    def __init__(self, rc, code, detail):
        super().__init__(code)
        self.rc, self.code, self.detail = rc, code, detail


def refuse(code, detail):
    return Stop(2, code, detail)


def wait(code, detail):
    return Stop(75, code, detail)


def one_line(text):
    text = re.sub(r"[\x00-\x1f\x7f]+", " ", str(text)).strip()
    return text[:DETAIL_MAX]


def config_dir():
    if os.environ.get("FM_STORAGE_CONFIG"):
        return os.environ["FM_STORAGE_CONFIG"]
    base = os.environ.get("XDG_CONFIG_HOME") or os.path.join(os.environ.get("HOME") or "/tmp", ".config")
    return os.path.join(base, "lattice-storage")


def mnt_base():
    return os.environ.get("FM_STORAGE_MNT") or "/mnt"


def lexical(path):
    path = posixpath.normpath(path)
    return path[1:] if path.startswith("//") else path


def related(a, b):
    return a == b or a.startswith(b.rstrip("/") + "/") or b.startswith(a.rstrip("/") + "/")


def marker(name):
    return json.dumps({"schema": MARKER_SCHEMA, "root": name}, sort_keys=True).encode() + b"\n"


def read_regular(path, limit):
    """Up to LIMIT bytes of a regular file, or None for anything else; a FIFO never blocks the read."""
    fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK | os.O_CLOEXEC)
    try:
        if not stat.S_ISREG(os.fstat(fd).st_mode):
            return None
        chunks, size = [], 0
        while size < limit:
            chunk = os.read(fd, limit - size)
            if not chunk:
                break
            chunks.append(chunk)
            size += len(chunk)
        return b"".join(chunks)
    finally:
        os.close(fd)


# --- the map -----------------------------------------------------------------

def strict_json(data):
    def pairs(items):
        out = {}
        for key, value in items:
            if key in out:
                raise ValueError("duplicate key %r" % key)
            out[key] = value
        return out

    def constant(name):
        raise ValueError("non-finite number %s" % name)

    return json.loads(data.decode("utf-8"), object_pairs_hook=pairs, parse_constant=constant)


def read_map():
    path = os.path.join(config_dir(), "class-map.json")
    try:
        data = read_regular(path, MAP_MAX + 1)
    except FileNotFoundError:
        raise refuse("no-class-map", "%s is absent; nothing is generated until it exists" % path) from None
    except OSError as error:
        raise wait("cannot-measure", "%s: %s" % (path, error.strerror)) from None
    if data is None:
        raise refuse("invalid-class-map", "%s is not a regular file" % path)
    if len(data) > MAP_MAX:
        raise refuse("invalid-class-map", "%s is over %d bytes" % (path, MAP_MAX))
    try:
        record = strict_json(data)
    except (ValueError, UnicodeDecodeError) as error:
        raise refuse("invalid-class-map", "%s: %s" % (path, error)) from None
    return record


def bad(detail):
    return refuse("invalid-class-map", detail)


def check_shape(record):
    """The closed map fields; returns (hosts, aliases, roots, classes)."""
    if not isinstance(record, dict) or set(record) != {"schema", "hosts", "roots", "classes"} \
            or record["schema"] != MAP_SCHEMA:
        raise bad("not a %s record {schema, hosts, roots, classes}" % MAP_SCHEMA)
    hosts, aliases, ids = {}, {}, set()
    if not isinstance(record["hosts"], dict) or not record["hosts"]:
        raise bad("hosts is a non-empty object")
    for host, value in record["hosts"].items():
        if not NAME.fullmatch(host) or not isinstance(value, dict) or set(value) != {"machine_id", "aliases"} \
                or not isinstance(value["machine_id"], str) or not MACHINE_ID.fullmatch(value["machine_id"]) \
                or not isinstance(value["aliases"], list):
            raise bad("host %r is {machine_id (32 hex), aliases (list)}" % host)
        if value["machine_id"] in ids:
            raise bad("host %s repeats another host's machine_id" % host)
        ids.add(value["machine_id"])
        hosts[host] = value["machine_id"]
        for alias in value["aliases"]:
            if not isinstance(alias, str) or not NAME.fullmatch(alias) or alias in aliases:
                raise bad("host %s alias %r is not a unique name" % (host, alias))
            aliases[alias] = host
    for alias in aliases:
        if alias in hosts:
            raise bad("alias %s is also a host id" % alias)
    if not isinstance(record["roots"], dict) or not record["roots"]:
        raise bad("roots is a non-empty object")
    roots = {}
    for name, value in record["roots"].items():
        if not NAME.fullmatch(name) or not isinstance(value, dict) \
                or set(value) != {"host", "path", "transport", "volume"} \
                or not all(isinstance(value[key], str) for key in value) \
                or value["transport"] not in ("local", "ssh") or value["volume"] not in VOLUMES:
            raise bad("root %r is {host, path, transport (local|ssh), volume (%s)}" % (name, "|".join(VOLUMES)))
        host = aliases.get(value["host"], value["host"])
        if host not in hosts:
            raise bad("root %s names unknown host %r" % (name, value["host"]))
        roots[name] = dict(value, host=host)
    if not isinstance(record["classes"], dict):
        raise bad("classes is an object")
    for name, root in record["classes"].items():
        if not NAME.fullmatch(name) or not isinstance(root, str):
            raise bad("class %r maps to a root name" % name)
    return hosts, aliases, roots, dict(record["classes"])


def check_host(here, hosts):
    path = os.environ.get("FM_STORAGE_MACHINE_ID") or "/etc/machine-id"
    try:
        data = read_regular(path, 128)
    except OSError as error:
        raise refuse("host-unproven", "%s is unreadable: %s" % (path, error.strerror)) from None
    if data is None:
        raise refuse("host-unproven", "%s is unreadable: not a regular file" % path)
    if data.decode("ascii", "replace").strip() != hosts[here]:
        raise refuse("host-mismatch", "this machine is not host %s (%s differs)" % (here, path))


def d_base():
    return posixpath.join(lexical(mnt_base()), "d", "lattice-data")


def check_path(name, root):
    path, volume = root["path"], root["volume"]
    if not path.startswith("/") or path != lexical(path) or path == "/" or len(path) > 1024 \
            or re.search(r"[\x00-\x1f\x7f\\]", path):
        raise refuse("root-path", "root %s path %r is not a canonical absolute path" % (name, path))
    base = d_base()
    if volume == "d":
        if not path.startswith(base + "/"):
            raise refuse("root-path", "root %s is a d root outside %s" % (name, base))
        parts = path[len(base) + 1:].split("/")
        for part in parts:
            if not D_PART.fullmatch(part) or part.split(".")[0] in RESERVED:
                raise refuse("root-path", "root %s name %r is not a lower-case Windows-safe name" % (name, part))
        if parts[0] in LEGACY_D:
            raise refuse("root-overlap", "root %s overlaps the legacy D: directory %s" % (name, parts[0]))
    elif related(path, lexical(mnt_base())):
        raise refuse("root-path", "root %s is a linux root under %s" % (name, lexical(mnt_base())))


def check_roots(here, roots):
    for name in sorted(roots):
        root = roots[name]
        if root["transport"] == "local" and root["host"] != here:
            raise bad("root %s is local on another host" % name)
        if root["transport"] != "local":
            raise refuse("remote-unproven", "root %s on host %s has no host-side proof" % (name, root["host"]))
        if root["volume"] == "host-c":
            raise refuse("forbidden-placement", "root %s is on host-c" % name)
        check_path(name, root)
    names = sorted(roots)
    for i, a in enumerate(names):
        for b in names[i + 1:]:
            if related(roots[a]["path"], roots[b]["path"]):
                raise refuse("root-overlap", "roots %s and %s are equal or nested" % (a, b))


def check_classes(roots, classes):
    for name in sorted(classes):
        if classes[name] not in roots:
            raise refuse("unknown-root", "class %s maps to undefined root %r" % (name, classes[name]))
    for name in REQUIRED:
        if name not in classes:
            raise refuse("missing-class", "class %s is not bound" % name)
    for name in sorted(classes):
        volume = roots[classes[name]]["volume"]
        want = "linux" if name == PAYLOAD_EXEMPT else "d"
        if volume != want:
            raise refuse("forbidden-placement", "class %s is on %s; it belongs on %s" % (name, volume, want))


# --- the machine -------------------------------------------------------------

def run_verify():
    """(rc, reason): verify-bulk-root's answer, rc 0 or 75 only; anything else is a failed check."""
    tool = os.path.join(os.path.dirname(os.path.abspath(__file__)), "fm-storage.sh")
    try:
        child = subprocess.Popen(["bash", tool, "verify-bulk-root"], stdin=subprocess.DEVNULL,
                                 stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
    except OSError:
        return 75, "check-failed"
    try:
        out, err = child.communicate(timeout=VERIFY_TIMEOUT)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(child.pid, signal.SIGKILL)
        except OSError:
            pass
        child.communicate()
        return 75, "check-timeout"
    lines = err.decode("utf-8", "replace").splitlines()
    if child.returncode == 0 and out.strip() and not lines:
        return 0, ""
    if child.returncode == 75 and len(lines) == 1 and lines[0].startswith("fm-storage: wait: "):
        return 75, one_line(lines[0][len("fm-storage: wait: "):]) or "check-failed"
    return 75, "check-failed"


def unescape(field):
    return re.sub(r"\\([0-7]{3})", lambda m: chr(int(m.group(1), 8)), field)


def read_mounts():
    path = os.environ.get("FM_STORAGE_MOUNTINFO") or "/proc/self/mountinfo"
    try:
        data = read_regular(path, 4 * 1024 * 1024)
    except OSError as error:
        raise wait("cannot-measure", "mount table %s: %s" % (path, error.strerror)) from None
    if data is None:
        raise wait("cannot-measure", "mount table %s is not a regular file" % path)
    text = data.decode("utf-8", "replace")
    mounts = []
    for line in text.splitlines():
        fields = line.split(" ")
        try:
            sep = fields.index("-", 6)
            mounts.append({"dev": fields[2], "root": unescape(fields[3]), "point": lexical(unescape(fields[4])),
                           "fstype": fields[sep + 1], "source": unescape(fields[sep + 2])})
        except (ValueError, IndexError):
            raise wait("cannot-measure", "mount table %s has an unreadable line" % path) from None
    if not mounts:
        raise wait("cannot-measure", "mount table %s is empty" % path)
    return mounts


def mount_of(path, mounts):
    """The mount a path lives on: the longest mount point over it, the last listed winning a tie."""
    best = None
    for entry in mounts:
        point = entry["point"]
        if point == "/" or path == point or path.startswith(point + "/"):
            if best is None or len(point) >= len(best["point"]):
                best = entry
    return best


def dev_of(st):
    return "%d:%d" % (os.major(st.st_dev), os.minor(st.st_dev))


def place_of(path, entry):
    """A path's physical place: (domain, spelling); Windows mounts compare case-insensitively."""
    rest = path[len(entry["point"]):].lstrip("/") if entry["point"] != "/" else path.lstrip("/")
    inner = lexical(posixpath.join("/", entry["root"].lstrip("/"), rest))
    if entry["fstype"] in WINDOWS_FS:
        source = entry["source"].replace("\\", "/").rstrip("/").casefold()
        return "win", lexical(source + inner).casefold()
    return "dev:" + entry["dev"], inner


def no_links(name, path):
    """Refuse a symlink anywhere on PATH (a junction on a Windows mount reads as one), cycles included."""
    cur, seen = path, {path}
    for _ in range(MAX_HOPS):
        parts, nxt = cur.split("/"), None
        for i in range(2, len(parts) + 1):
            pre = "/".join(parts[:i])
            try:
                st = os.lstat(pre)
            except OSError:
                break
            if stat.S_ISLNK(st.st_mode):
                try:
                    nxt = lexical(posixpath.join(posixpath.dirname(pre), os.readlink(pre), *parts[i:]))
                except OSError:
                    nxt = pre
                break
        if nxt is None:
            break
        if nxt in seen:
            raise refuse("root-symlink", "root %s path %s holds a symlink cycle" % (name, path))
        seen.add(nxt)
        cur = nxt
    else:
        raise refuse("root-symlink", "root %s path %s holds too many symlink hops" % (name, path))
    if len(seen) > 1 or os.path.realpath(path) != path:
        raise refuse("root-symlink", "root %s path %s goes through a symlink or junction" % (name, path))


def identity(name, path, mounts):
    no_links(name, path)
    try:
        st = os.stat(path)
    except FileNotFoundError:
        raise wait("storage-offline", "root %s: root-absent" % name) from None
    except OSError as error:
        raise wait("cannot-measure", "root %s: %s" % (name, errno.errorcode.get(error.errno, "os-error"))) from None
    if not stat.S_ISDIR(st.st_mode):
        raise wait("storage-offline", "root %s: root-not-directory" % name)
    entry = mount_of(path, mounts)
    if entry is None or entry["dev"] != dev_of(st):
        raise wait("storage-offline", "root %s: mount-identity-mismatch" % name)
    chain, cur = set(), path
    while cur != "/":
        cur = posixpath.dirname(cur)
        try:
            up = os.stat(cur)
        except OSError as error:
            raise wait("cannot-measure", "root %s: %s" % (name, errno.errorcode.get(error.errno, "os-error"))) \
                from None
        chain.add((up.st_dev, up.st_ino))
    return {"st": st, "entry": entry, "place": place_of(path, entry), "chain": chain}


def check_aliases(roots, ids):
    names = sorted(roots)
    for i, a in enumerate(names):
        for b in names[i + 1:]:
            x, y = ids[a], ids[b]
            same_inode = (x["st"].st_dev, x["st"].st_ino) == (y["st"].st_dev, y["st"].st_ino)
            nested = (x["st"].st_dev, x["st"].st_ino) in y["chain"] or (y["st"].st_dev, y["st"].st_ino) in x["chain"]
            same_place = x["place"][0] == y["place"][0] and related(x["place"][1], y["place"][1])
            if same_inode or nested or same_place:
                raise refuse("root-alias", "roots %s and %s are one place or nested through a mount or link" % (a, b))


def size_of(path):
    vfs = os.statvfs(path)
    return vfs.f_blocks * vfs.f_frsize


def check_volume(name, root, found, mounts):
    entry, st = found["entry"], found["st"]
    if root["volume"] == "d":
        point = lexical(posixpath.join(mnt_base(), "d"))
        source = entry["source"].rstrip("\\").casefold()
        try:
            d_st = os.stat(point)
            same_size = size_of(root["path"]) == size_of(point)
        except OSError:
            raise wait("storage-offline", "root %s: d-mount-unreadable" % name) from None
        if entry["point"] != point or entry["fstype"] not in WINDOWS_FS or source != "d:" \
                or st.st_dev != d_st.st_dev or not same_size:
            raise wait("storage-offline", "root %s: not-on-d-volume" % name)
    else:
        top = mount_of("/", mounts)
        if entry["point"] != "/" or top is None or entry["fstype"] in WINDOWS_FS or entry["dev"] != top["dev"]:
            raise wait("storage-offline", "root %s: not-on-linux-volume" % name)


def check_marker(name, path):
    try:
        fd = os.open(os.path.join(path, MARKER), os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    except FileNotFoundError:
        raise wait("storage-offline", "root %s: marker-absent" % name) from None
    except OSError as error:
        if error.errno == errno.ELOOP:
            raise wait("storage-offline", "root %s: marker-mismatch" % name) from None
        raise wait("cannot-measure", "root %s: marker %s" % (name, errno.errorcode.get(error.errno, "os-error"))) \
            from None
    try:
        if not stat.S_ISREG(os.fstat(fd).st_mode):
            raise wait("storage-offline", "root %s: marker-mismatch" % name)
        data = os.read(fd, 4097)
    except OSError as error:
        raise wait("cannot-measure", "root %s: marker %s" % (name, errno.errorcode.get(error.errno, "os-error"))) \
            from None
    finally:
        os.close(fd)
    if data != marker(name):
        raise wait("storage-offline", "root %s: marker-mismatch" % name)


# --- commands ----------------------------------------------------------------

def site_config(argv):
    if len(argv) != 2 or argv[0] != "--here" or not argv[1]:
        raise refuse("usage", "site-config --here HOST")
    hosts, aliases, roots, classes = check_shape(read_map())
    here = aliases.get(argv[1], argv[1])
    if here not in hosts:
        raise refuse("unknown-host", "host %r is not in the class map" % argv[1])
    check_host(here, hosts)
    check_roots(here, roots)
    check_classes(roots, classes)
    rc, reason = run_verify()
    if rc:
        raise wait("storage-offline", "d: " + reason)
    mounts = read_mounts()
    ids = {name: identity(name, roots[name]["path"], mounts) for name in sorted(roots)}
    check_aliases(roots, ids)
    for name in sorted(roots):
        check_volume(name, roots[name], ids[name], mounts)
    for name in sorted(roots):
        check_marker(name, roots[name]["path"])
    out = {
        "schema": ROOTS_SCHEMA,
        "here": here,
        "metadata": classes[PAYLOAD_EXEMPT],
        "roots": {name: {"host": here, "path": roots[name]["path"], "transport": "local",
                         "volume": roots[name]["volume"]} for name in sorted(roots)},
        "classes": {name: classes[name] for name in sorted(classes)},
    }
    sys.stdout.write(json.dumps(out, separators=(",", ":")) + "\n")
    return 0


def health(argv):
    if argv != ["--volume", "d"]:
        raise refuse("usage", "health --volume d")
    rc, reason = run_verify()
    sys.stdout.write("ok\n" if rc == 0 else "offline %s\n" % reason)
    return rc


def main(argv):
    verbs = {"site-config": site_config, "health": health}
    try:
        if not argv or argv[0] not in verbs:
            raise refuse("usage", "site-config --here HOST | health --volume d")
        return verbs[argv[0]](argv[1:])
    except Stop as stop:
        kind = "refused" if stop.rc == 2 else "wait"
        sys.stderr.write("fm-storage: %s: %s: %s\n" % (kind, stop.code, one_line(stop.detail)))
        return stop.rc


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
