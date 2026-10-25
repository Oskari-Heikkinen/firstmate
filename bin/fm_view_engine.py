"""Read-only view engine primitives; no supervision or transaction authority.

Python 3.9+, standard library only. The resident transport owns only its socket.
Native readers return captured bytes/identity and refuse a changing generation.
Queue claims, ack, presentation commits, publication and custody remain callers'
existing transactions. No timer/watch/lease/beacon is installed by this module.
"""
import asyncio
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
import os
from pathlib import Path
import re
import socket
import stat
import struct
import time

from fm_view_status import Fold, Vocabulary

PROTOCOL = "fm-supervision-views.v1"
MAX_MESSAGE = 1024 * 1024
MAX_FILE = 4 * 1024 * 1024
MAX_CLIENTS = 64
MAX_TIMEOUT = 30.0
TASK_ID = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{0,127}\Z")


class Refused(ValueError):
    pass


def require(value, message):
    if not value:
        raise Refused(message)


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result, "duplicate JSON field")
        result[key] = value
    return result


def loads(raw):
    return json.loads(raw, object_pairs_hook=unique_object,
                      parse_constant=lambda _: (_ for _ in ()).throw(Refused("nonfinite JSON")))


def encoded(value):
    # ensure_ascii also transports undecodable status bytes losslessly through
    # surrogateescape; clients must use the same decoding on textual surfaces.
    result = json.dumps(value, ensure_ascii=True, allow_nan=False, separators=(",", ":")).encode() + b"\n"
    require(len(result) <= MAX_MESSAGE, "response exceeds message bound")
    return result


def identity(path):
    info = os.stat(path, follow_symlinks=False)
    require(stat.S_ISDIR(info.st_mode), "root is not a nonsymlink directory")
    return info.st_dev, info.st_ino


def read_file(path, limit=MAX_FILE, missing=False, dir_fd=None):
    """Bounded local regular-file observation, including a same-fd identity.

    O_NONBLOCK prevents a FIFO/open race from blocking; it does not promise a
    bound on a kernel syscall on a failed mount. Call only from an admitted I/O
    lane. Never follow a final-component link, or use stat-before-open as proof.
    """
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=dir_fd)
    except FileNotFoundError:
        if missing:
            return None
        raise
    with os.fdopen(fd, "rb") as stream:
        before = os.fstat(stream.fileno())
        require(stat.S_ISREG(before.st_mode), "input is not regular")
        data = stream.read(limit + 1)
        after = os.fstat(stream.fileno())
    require(len(data) <= limit, "input exceeds byte bound")
    signature = lambda s: (s.st_dev, s.st_ino, s.st_size, s.st_mtime_ns, s.st_ctime_ns)
    require(signature(before) == signature(after), "input changed during capture")
    require(signature(after) == signature(os.stat(path, dir_fd=dir_fd, follow_symlinks=False)), "input replaced during capture")
    return {"bytes": data, "identity": [after.st_dev, after.st_ino],
            "size": len(data), "sha256": hashlib.sha256(data).hexdigest()}


def fields(raw):
    """Metadata uses last field wins, as the existing in-shell reader does."""
    result = {}
    for line in raw.replace(b"\0", b"").decode("utf-8", "surrogateescape").split("\n"):
        name, separator, value = line.partition("=")
        if separator:
            result[name] = value
    return result


class Inputs:
    def __init__(self, home):
        self.home = Path(home)
        require(self.home.is_absolute() and str(self.home) == os.path.realpath(self.home), "noncanonical home")
        self.home_identity = identity(self.home)
        self.state = self.home / "state"
        self.state_identity = identity(self.state)

    def check(self):
        require(identity(self.home) == self.home_identity and identity(self.state) == self.state_identity,
                "home/state root identity changed")

    def task_path(self, task, suffix):
        require(type(task) is str and TASK_ID.fullmatch(task), "invalid task id")
        return self.state / (task + suffix)

    def open_state(self):
        fd = os.open(self.state, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        info = os.fstat(fd)
        if (info.st_dev, info.st_ino) != self.state_identity:
            os.close(fd)
            raise Refused("state root identity changed")
        return fd

    def state_read(self, task, suffix):
        path = self.task_path(task, suffix)
        fd = self.open_state()
        try:
            return read_file(path.name, missing=True, dir_fd=fd)
        finally:
            os.close(fd)

    def metadata(self, task):
        return self.state_read(task, ".meta")

    def protection(self, task):
        """Read the registered tool level even when status bytes are unchanged.

        This is the existing alert-store read-side rule, not an acknowledgement
        reader: even an acknowledged active key is held against supersession.
        An invalid registration whose FIRST status field plainly names another
        file does not protect this file; every other unknown holds all keys.
        """
        protected = set()
        protect_all = False
        state_fd = self.open_state()
        try:
            try:
                reg_fd = os.open("alert-stores", os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=state_fd)
            except FileNotFoundError:
                return protected, protect_all
        finally:
            os.close(state_fd)
        try:
            return self._protection_from_directory(task, reg_fd)
        finally:
            os.close(reg_fd)

    def _protection_from_directory(self, task, reg_fd):
        protected, protect_all = set(), False
        for name in sorted(os.listdir(reg_fd)):
            if name.startswith(".") or not name.endswith(".reg"):
                continue
            try:
                captured = read_file(name, dir_fd=reg_fd)
                values = fields(captured["bytes"])
                slug = name[:-4]
                valid = (values.get("schema") == "fm-alert-registration/v1"
                         and values.get("store") == slug
                         and re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,127}", slug)
                         and values.get("path", "").startswith("/")
                         and re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*\.status", values.get("status", "")))
                if not valid:
                    first = next((line[7:] for line in captured["bytes"].decode("utf-8", "surrogateescape").split("\n")
                                  if line.startswith("status=")), "")
                    if not first or first == task + ".status":
                        protect_all = True
                    continue
                if values["status"] != task + ".status":
                    continue
                # The existing store reader uses jq's last-key-wins JSON
                # semantics. IPC duplicate-field refusal must not change them.
                store = json.loads(read_file(values["path"])["bytes"])
                require(type(store) is dict and store.get("schema") in ("fm-alert-store/v1", "tj-capacity-alerts/v1")
                        and type(store.get("active")) is dict
                        and type(store.get("acks", {})) is dict and type(store.get("events", [])) is list
                        and all(re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*", k) for k in store["active"]),
                        "invalid alert store")
                protected.update(store["active"])
            except (OSError, ValueError, TypeError, KeyError):
                protect_all = True
        return protected, protect_all

    def fold(self, task, kind="", vocabulary=None):
        self.check()
        meta = self.metadata(task)
        selected = fields(meta["bytes"]) if meta else {}
        if not kind:
            kind = selected.get("kind", "ship") if meta else "unknown"
        if kind not in ("ship", "scout", "secondmate"):
            kind = "unknown"
        status = self.state_read(task, ".status")
        protected, protect_all = self.protection(task)
        result = Fold(status["bytes"] if status else b"", kind, vocabulary, protected, protect_all).result()
        now = self.metadata(task)
        require(meta == now, "task generation changed during observation")
        self.check()
        result["status"] = ({k: v for k, v in status.items() if k != "bytes"} if status else None)
        result["generation"] = selected.get("spawn_gen", "")
        return result


class BoundedLane:
    """No unbounded executor queue; timed-out I/O still occupies its own slot.

    Cancelling a future cannot kill a filesystem read. Capacity is released by
    the real operation's completion, not by a caller's shorter timeout. A hung
    summary therefore cannot consume the separately reserved critical lane.
    """
    def __init__(self, workers):
        self.executor = ThreadPoolExecutor(max_workers=workers, thread_name_prefix="fm-view-io")
        self.capacity = workers
        self.active = 0

    async def run(self, function, timeout):
        require(self.active < self.capacity, "observation capacity exhausted; retry through legacy")
        self.active += 1
        loop = asyncio.get_running_loop()
        future = loop.run_in_executor(self.executor, function)
        def finished(_):
            self.active -= 1
        future.add_done_callback(finished)
        return await asyncio.wait_for(asyncio.shield(future), timeout)

    def close(self):
        self.executor.shutdown(wait=False, cancel_futures=True)


class Engine:
    def __init__(self, inputs, workers=4, critical_workers=2):
        require(1 <= workers <= 16 and 1 <= critical_workers <= 4, "worker count outside bound")
        self.inputs = inputs
        self.ordinary = BoundedLane(workers)
        self.critical = BoundedLane(critical_workers)
        self.inflight = {}
        self.operations = 0

    async def request(self, operation, arguments, timeout):
        require(operation == "status-fold", "unsupported read verb")
        require(type(arguments) is dict and set(arguments) <= {"task", "kind", "vocabulary"}
                and "task" in arguments, "invalid fold arguments")
        task = arguments["task"]
        self.inputs.task_path(task, ".status")
        kind = arguments.get("kind", "")
        require(kind in ("", "unknown", "ship", "scout", "secondmate"), "invalid task kind")
        raw_vocabulary = arguments.get("vocabulary", {})
        require(type(raw_vocabulary) is dict and set(raw_vocabulary) <= {"paused", "resolved", "held", "relevant", "reserved"},
                "unsupported vocabulary field")
        for name, value in raw_vocabulary.items():
            if name == "reserved":
                require(type(value) is list and len(value) <= 32
                        and all(type(p) is str and 1 <= len(p) <= 128 for p in value), "invalid reserved vocabulary")
            else:
                require(type(value) is str and 1 <= len(value) <= 1024, "invalid vocabulary")
        vocabulary = Vocabulary(**raw_vocabulary)
        try:
            re.compile(vocabulary.relevant)
        except re.error as exc:
            raise Refused("invalid classifier expression") from exc
        # Generation is captured/revalidated IN the operation. This local-only
        # pure read is cheap, but still never reused across completed requests.
        token = json.dumps([operation, arguments], sort_keys=True)
        future = self.inflight.get(token)
        if future is None or future.done():
            self.operations += 1
            future = asyncio.create_task(self.critical.run(lambda: self.inputs.fold(task, kind, vocabulary), MAX_TIMEOUT))
            self.inflight[token] = future
            def finished(done):
                if self.inflight.get(token) is done:
                    del self.inflight[token]
                # Observe failures even when every subscribing client departed.
                if not done.cancelled():
                    done.exception()
            future.add_done_callback(finished)
        return await asyncio.wait_for(asyncio.shield(future), timeout)

    def close(self):
        self.ordinary.close()
        self.critical.close()


def peer_uid(sock):
    if hasattr(socket, "SO_PEERCRED"):
        return struct.unpack("3i", sock.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, 12))[1]
    if hasattr(sock, "getpeereid"):
        return sock.getpeereid()[0]
    raise Refused("peer UID verification unsupported on this platform")


class Transport:
    def __init__(self, engine, epoch):
        self.engine = engine
        self.epoch = epoch
        self.clients = 0

    async def handle(self, reader, writer):
        request_id = ""
        admitted = False
        response = {"schema": PROTOCOL, "epoch": self.epoch, "home": str(self.engine.inputs.home),
                    "request": request_id, "ok": False}
        try:
            require(self.clients < MAX_CLIENTS, "too many read clients")
            self.clients += 1
            admitted = True
            require(peer_uid(writer.get_extra_info("socket")) == os.getuid(), "peer UID mismatch")
            raw = await asyncio.wait_for(reader.readline(), 2)
            require(raw.endswith(b"\n") and len(raw) <= MAX_MESSAGE, "incomplete/oversized request")
            request = loads(raw)
            require(type(request) is dict and set(request) == {"schema", "epoch", "home", "request", "verb", "timeout_ms", "args"},
                    "invalid request fields")
            require(request["schema"] == PROTOCOL and request["epoch"] == self.epoch,
                    "protocol/epoch mismatch")
            require(request["home"] == str(self.engine.inputs.home), "home mismatch")
            require(type(request["request"]) is str and re.fullmatch(r"[A-Za-z0-9._-]{1,128}", request["request"]), "invalid request identity")
            response["request"] = request["request"]
            require(type(request["timeout_ms"]) is int and 1 <= request["timeout_ms"] <= 30000, "invalid read deadline")
            require(type(request["verb"]) is str, "invalid read verb")
            result = await self.engine.request(request["verb"], request["args"], request["timeout_ms"] / 1000)
            response.update(ok=True, result=result)
        except (OSError, ValueError, TypeError, KeyError, asyncio.TimeoutError, asyncio.LimitOverrunError) as exc:
            response["error"] = "read deadline expired" if isinstance(exc, asyncio.TimeoutError) else str(exc)[:500]
        try:
            writer.write(encoded(response))
            await asyncio.wait_for(writer.drain(), 2)
        except (OSError, ValueError, asyncio.TimeoutError):
            # No commit/cursor exists to lose: the caller must retry/fallback.
            pass
        finally:
            writer.close()
            if admitted:
                self.clients -= 1


async def serve(home, path, epoch, stop, workers=4):
    """Owner supplies a private local transport directory and stop condition.

    No stale-socket unlink, background daemonization, root creation, mode switch,
    health lease, or stop-by-PID API. Only the inode we bound is removed on exit.
    """
    sockpath = Path(path)
    parent = sockpath.parent
    info = parent.lstat()
    require(stat.S_ISDIR(info.st_mode) and info.st_uid == os.getuid() and stat.S_IMODE(info.st_mode) == 0o700,
            "socket parent must be a private owned 0700 directory")
    require(str(parent) == os.path.realpath(parent), "symlinked socket directory")
    require(not os.path.lexists(sockpath), "socket already exists; owner must verify stale identity")
    engine = Engine(Inputs(home), workers)
    transport = Transport(engine, epoch)
    server = None
    bound_identity = None
    try:
        # The private parent prevents other UIDs racing the chmod after bind.
        server = await asyncio.start_unix_server(transport.handle, path=str(sockpath), limit=MAX_MESSAGE)
        os.chmod(sockpath, 0o600)
        bound = sockpath.lstat()
        bound_identity = (bound.st_dev, bound.st_ino)
        print(json.dumps({"schema": PROTOCOL, "epoch": epoch, "home": str(engine.inputs.home),
                          "socket": str(sockpath), "pid": os.getpid(), "ready": True}), flush=True)
        async with server:
            await stop.wait()
    finally:
        if server:
            server.close()
            await server.wait_closed()
        engine.close()
        if bound_identity and os.path.lexists(sockpath):
            current = sockpath.lstat()
            if (current.st_dev, current.st_ino) == bound_identity:
                sockpath.unlink()


def client(path, home, epoch, verb, arguments, timeout=10):
    require(0 < timeout <= MAX_TIMEOUT, "invalid read timeout")
    request_id = os.urandom(16).hex()
    request = {"schema": PROTOCOL, "epoch": epoch, "home": home, "request": request_id,
               "verb": verb, "timeout_ms": max(1, int(timeout * 1000)), "args": arguments}
    info = os.lstat(path)
    require(stat.S_ISSOCK(info.st_mode) and info.st_uid == os.getuid()
            and stat.S_IMODE(info.st_mode) == 0o600, "socket identity/mode invalid")
    deadline = time.monotonic() + timeout
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock:
        sock.settimeout(timeout)
        sock.connect(path)
        require(peer_uid(sock) == os.getuid(), "service UID mismatch")
        sock.sendall(encoded(request))
        response = bytearray()
        while not response.endswith(b"\n"):
            sock.settimeout(max(0.001, deadline - time.monotonic()))
            chunk = sock.recv(min(65536, MAX_MESSAGE + 1 - len(response)))
            require(chunk, "service closed without a complete response")
            response.extend(chunk)
            require(len(response) <= MAX_MESSAGE, "oversized response")
        result = loads(response)
    require(type(result) is dict and result.get("schema") == PROTOCOL and result.get("epoch") == epoch
            and result.get("home") == home and result.get("request") == request_id, "response binding mismatch")
    require(result.get("ok") is True, "service refused: " + str(result.get("error", "unknown")))
    return result["result"]
