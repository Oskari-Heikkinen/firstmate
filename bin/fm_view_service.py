"""Foreground owner for an explicitly commissioned, home-local read service.

No daemonization, installation, home selection, monitoring lease or recovery.
The invoking owner supplies existing private roots, a published nonplanned
contract and immutable input. It consumes EVERY output/exit through its wake
path. Only this process's socket/owner are disposable; receipts/capabilities
are immutable and retained. Uncertain/replayed acceptance NEVER repeats an
external effect. All process signals use a freshly validated pidfd.
"""
import asyncio
from dataclasses import asdict
import hashlib
import os
from pathlib import Path
import signal
import socket
import stat
import struct
import sys
import time

from fm_view_bundle import (directory, packed, read_regular, rename_new, require,
                            write_new)
from fm_view_capabilities import inspect
from fm_view_engine import Engine, Inputs, Transport
from fm_view_journal import LifecycleJournal, preview_intake
from fm_view_lifecycle import (LIMIT, OWNER_SCHEMA, contract, decode, names,
                               owner_record, request_record)
from fm_view_lock import ServiceSingleton
from fm_view_process import ProcessGeneration, ProcessPin, process_generation, run
from fm_view_protocol import MAX_MESSAGE

# Fixed private names are this owner's only mutable runtime namespace.
SOCKET = "read.sock"
OWNER = "owner.json"
CAPABILITIES = "capabilities.json"
RESULT = "fm-view-service-result.v1"


def fingerprint(value):
    return hashlib.sha256(packed(value)).hexdigest()


class Runtime:
    """Pin the selected parent BEFORE creating any runtime object.

    All opens, publication, bind and unlink use the retained directory fd, not
    a pathname that could lead to a replacement tree. Namespace freshness is an
    additional refusal, not the creation/cleanup authority.
    """
    def __init__(self, request):
        self.request = request
        self.fd = None
        self.roots = ((Path(request["home"]), None), (Path(request["home"]) / "state", 0o700),
                      (Path(request["runtime"]), 0o700))
        self.identities = tuple(tuple(request["roots"][name]) for name in ("home", "state", "runtime"))
        self.fresh()
        fd = os.open(self.roots[-1][0], os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_NONBLOCK)
        try:
            info = os.fstat(fd)
            require((info.st_dev, info.st_ino) == self.identities[-1]
                    and info.st_uid == os.getuid() and stat.S_ISDIR(info.st_mode)
                    and stat.S_IMODE(info.st_mode) == 0o700, "selected runtime parent changed")
            self.fd = fd
            self.fresh()
        except BaseException:
            os.close(fd)
            self.fd = None
            raise

    def fresh(self):
        require(all(directory(root, mode)[1] == identity for (root, mode), identity
                    in zip(self.roots, self.identities)), "service input root replaced")

    def pinned(self, name):
        require(name in (SOCKET, OWNER, CAPABILITIES) or name.startswith(".view-publish-"),
                "unsupported service runtime name")
        require(self.fd is not None, "runtime pin closed")
        return Path("/proc/self/fd") / str(self.fd) / name

    def absent(self, name):
        require(not os.path.lexists(self.pinned(name)), "existing service runtime object: " + name)

    def publish(self, name, value):
        self.fresh()
        self.absent(name)
        stage = self.pinned(".view-publish-" + os.urandom(16).hex())
        identity = None
        try:
            identity = write_new(stage, packed(value), 0o600)
            self.fresh()
            rename_new(stage, self.pinned(name))
            os.fsync(self.fd)
            self.fresh()
            self.read(name, value)
            return identity
        finally:
            if os.path.lexists(stage):
                # No namespace/path-based removal after root replacement.
                self.fresh()
                info = stage.lstat()
                require(identity == (info.st_dev, info.st_ino) and stat.S_ISREG(info.st_mode)
                        and info.st_nlink == 1, "runtime staging replaced; cleanup refused")
                stage.unlink()

    def read(self, name, expected):
        self.fresh()
        target = self.pinned(name)
        before = target.lstat()
        raw = read_regular(target, LIMIT, 0o600)
        after = target.lstat()
        require((before.st_dev, before.st_ino) == (after.st_dev, after.st_ino)
                and raw == packed(expected), "service runtime binding mismatch: " + name)
        self.fresh()
        return [after.st_dev, after.st_ino]

    def socket_identity(self):
        self.fresh()
        info = self.pinned(SOCKET).lstat()
        require(stat.S_ISSOCK(info.st_mode) and info.st_uid == os.getuid()
                and stat.S_IMODE(info.st_mode) == 0o600, "unsafe bound service socket")
        return [info.st_dev, info.st_ino]

    def remove(self, name, identity, expected=None):
        self.fresh()
        target = self.pinned(name)
        if not os.path.lexists(target):
            return "absent"
        info = target.lstat()
        # A successor is never cleanup authority, even after proven exit.
        result = "replacement-preserved"
        matching = [info.st_dev, info.st_ino] == list(identity)
        if name == OWNER and matching:
            require(expected is not None, "owner cleanup lacks selected bytes")
            try:
                matching = read_regular(target, LIMIT, 0o600) == packed(expected)
            except (OSError, ValueError):
                matching = False
        if name == SOCKET:
            matching = matching and stat.S_ISSOCK(info.st_mode) and info.st_uid == os.getuid()
        if matching:
            os.unlink(name, dir_fd=self.fd)
            os.fsync(self.fd)
            result = "removed"
        self.fresh()
        return result

    def close(self):
        if self.fd is not None:
            fd, self.fd = self.fd, None
            os.close(fd)


def selected_fragment(home, filename):
    folder = Path(home) / "state" / "handoff-registry"
    directory(folder, 0o700)
    selected = Path(filename)
    require(selected.parent == folder and not selected.name.startswith(".")
            and selected.suffix == ".json", "lifecycle contract must be published in this home")
    raw = read_regular(selected, LIMIT, 0o600)
    fragment = decode(raw)
    _, stage = contract(fragment, home)
    require(stage.get("planned") is not True, "planned lifecycle actor cannot run")
    return fragment, raw


def actor_admission(home, fragment_path, fragment, timeout):
    """Use the existing installation check, never a parallel actor parser.

    Its declared verdict must cite THIS home's selected published fragment;
    none, grandfathered or a foreign covering stage is insufficient.
    """
    actor = names(home)[1]
    tool = Path(__file__).resolve().parent / "fm-handoff-actors.py"
    environment = {key: value for key, value in os.environ.items() if not key.startswith("FM_")}
    result = run([sys.executable, "-I", "-B", str(tool), "check", "--home", str(home), actor],
                 str(tool.parent), timeout, environment, max_output=LIMIT)
    expected = "(" + str(fragment_path) + ")"
    require(not result.problem and result.status == 0 and not result.stderr
            and result.text.startswith("declared\t" + actor + "\t")
            and result.text.endswith(expected), "declared lifecycle actor admission refused")
    require(read_regular(fragment_path, LIMIT, 0o600) == packed(fragment), "published lifecycle contract changed")


def capabilities(request):
    bundle = Path(request["bundle"]["path"])
    require(Path(__file__).resolve().parent.parent == bundle,
            "foreground owner must run from the explicitly selected immutable bundle")
    value = inspect(bundle, request["bundle"]["identity"], request["home"])
    require(fingerprint(value) == request["capabilities"], "fresh read capabilities differ from request")
    return value


class Operation:
    def __init__(self, home, fragment_path, filename):
        self.singleton = None
        self.effects = False
        self.home, _ = directory(home)
        directory(self.home / "state", 0o700)
        self.fragment_path = Path(fragment_path)
        self.fragment, raw = selected_fragment(self.home, self.fragment_path)
        require(raw == packed(self.fragment), "noncanonical published lifecycle contract")
        self.filename = filename
        self.deadline = time.monotonic() + 30
        bundle = Path(__file__).resolve().parent.parent
        # The invoked code must already be trusted; verification is binding,
        # not a signature. Refuse a mutable checkout before any actor writes.
        inspect(bundle, bundle.name, self.home)
        # No receipt or service effect before declared actor admission.
        actor_admission(self.home, self.fragment_path, self.fragment, self.remaining())
        self.selection = preview_intake(self.home, self.fragment, filename)
        self.request, problem, _ = self.selection
        if problem is None:
            self.deadline = min(self.deadline, time.monotonic() + self.request["timeout_ms"] / 1000)
        try:
            # Start admission precedes ANY journal constructor/anchor/decision.
            # Stop (and invalid-input refusal) never takes the live singleton.
            self.acquire_start()
            self.remaining()
            with self.journal() as transaction:
                decision = transaction.admit(filename, expected=self.selection)
            self.decision = decision
            self.accepted = decision["fresh"] and decision["receipt"]["state"] == "accepted"
        except BaseException:
            self.close()
            raise

    def acquire_start(self):
        if self.selection[1] is None and self.request["operation"] == "start":
            self.singleton = ServiceSingleton(self.home, self.request["runtime"], self.request["roots"])

    def close(self):
        # This covers constructor errors, terminal/ambiguous replay and every
        # pre-effect failure. After effects begin, ONLY actual OS exit closes
        # the same descriptor handed into foreground(), including live threads.
        if self.singleton is not None and not self.effects:
            self.singleton.close()
            self.singleton = None

    def remaining(self):
        remaining = self.deadline - time.monotonic()
        require(remaining > 0, "lifecycle operation deadline expired")
        return remaining

    def journal(self):
        require(read_regular(self.fragment_path, LIMIT, 0o600) == packed(self.fragment),
                "published lifecycle contract changed")
        return LifecycleJournal(self.home, self.fragment)

    def fresh(self):
        self.remaining()
        with self.journal() as transaction:
            # Replay validation binds the original selection and receipt to
            # exact input bytes in this ONE locked read, never a second parse.
            previous = transaction.admit(self.filename, expected=self.selection)
            require(not previous["fresh"] and previous["receipt"]["state"] == "accepted",
                    "lifecycle effect lacks current accepted receipt")

    def complete(self, code=None):
        with self.journal() as transaction:
            return transaction.complete(self.filename, code=code)

    def replay(self):
        receipt = self.decision["receipt"]
        require(receipt["state"] != "accepted", "ambiguous prior acceptance; verify effect, never retry automatically")
        return {"schema": RESULT, "fresh": self.decision["fresh"], "receipt": receipt}


def validate_live(runtime, request, owner, capability, timeout):
    owner_record(owner)
    selected_inode = runtime.read(OWNER, owner)
    runtime.read(CAPABILITIES, capability)
    require(runtime.socket_identity() == owner["socket"]["identity"], "selected socket replaced")
    require(owner["socket"]["path"] == str(Path(request["runtime"]) / SOCKET), "unsupported owner socket path")
    # Peer PID and UID bind the actual listener to the pidfd-selected generation.
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as peer:
        peer.settimeout(timeout)
        peer.connect(str(runtime.pinned(SOCKET)))
        pid, uid, _ = struct.unpack("3i", peer.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, 12))
        require(pid == owner["process"]["pid"] and uid == owner["process"]["uid"] == os.getuid(),
                "listener process binding mismatch")
    require(runtime.read(OWNER, owner) == selected_inode, "selected owner inode replaced")
    require(runtime.socket_identity() == owner["socket"]["identity"], "selected socket replaced")
    return selected_inode


def startup_binding(operation, owner):
    """Require the original completed, immutable start decision and input."""
    with operation.journal() as transaction:
        histories, _, _ = transaction.history()
        matches = [values[-1] for values in histories.values()
                   if values[-1]["ext"][transaction.stage["owner"] + ".request-sha256"] == owner["request"]]
        require(len(matches) == 1 and matches[0]["state"] == "done", "owner lacks completed start decision")
        receipt = matches[0]
        original, problem, _ = transaction.intake(receipt["record"] + "." + str(receipt["attempt"]) + ".json")
        require(problem is None and original["operation"] == "start" and fingerprint(original) == owner["request"],
                "owner start input changed")
        for key in ("home", "roots", "runtime", "bundle", "epoch", "capabilities"):
            require(original[key] == owner[key], "owner start binding mismatch: " + key)
        replay = transaction.admit(receipt["record"] + "." + str(receipt["attempt"]) + ".json")
        require(not replay["fresh"] and replay["receipt"] == receipt, "owner start receipt changed")


async def foreground(operation, emit):
    request = operation.request
    runtime = Runtime(request)
    singleton = operation.singleton
    engine = None
    listener = None
    server = None
    bound = None
    published_owner = None
    stop = asyncio.Event()
    loop = asyncio.get_running_loop()
    handlers = []
    reason = "stopped"
    cleanup = {}
    def stopping(signum):
        nonlocal reason
        reason = signal.Signals(signum).name
        stop.set()
    try:
        require(singleton is not None, "start lacks its pre-journal singleton")
        singleton.fresh()
        capability = capabilities(request)
        require(len(os.fsencode(Path(request["runtime"]) / SOCKET)) <= 100, "service socket path exceeds bound")
        for name in (SOCKET, OWNER, CAPABILITIES):
            runtime.absent(name)
        for signum in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
            loop.add_signal_handler(signum, stopping, signum)
            handlers.append(signum)
        operation.fresh()
        singleton.fresh()
        runtime.fresh()
        # From here the descriptor is deliberately NEVER closed in Python.
        # ThreadPoolExecutor's interpreter-exit join may outlive engine.close()
        # and this coroutine. The OS alone releases admission on actual exit.
        operation.effects = True
        runtime.publish(CAPABILITIES, capability)
        operation.fresh()
        singleton.fresh()
        require(capabilities(request) == capability, "capabilities changed before bind")
        runtime.read(CAPABILITIES, capability)
        listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        listener.setblocking(False)
        listener.bind(str(runtime.pinned(SOCKET)))
        os.chmod(runtime.pinned(SOCKET), 0o600)
        bound = runtime.socket_identity()
        listener.listen()
        engine = Engine(Inputs(operation.home), request["workers"])
        transport = Transport(engine, request["epoch"])
        # Python 3.13+ otherwise adds a second pathname-cleanup owner. This
        # runtime's pinned, identity-checked cleanup remains the sole owner.
        options = {"cleanup_socket": False} if sys.version_info >= (3, 13) else {}
        server = await asyncio.start_unix_server(transport.handle, sock=listener, limit=MAX_MESSAGE,
                                                start_serving=False, **options)
        owner = {"schema": OWNER_SCHEMA, **{key: request[key] for key in
                 ("home", "roots", "runtime", "bundle", "epoch", "capabilities")},
                 "process": asdict(process_generation(os.getpid())),
                 "socket": {"path": str(Path(request["runtime"]) / SOCKET), "identity": bound},
                 "request": fingerprint(request)}
        owner_record(owner)
        published_owner = runtime.publish(OWNER, owner)
        operation.fresh()
        singleton.fresh()
        runtime.read(OWNER, owner)
        runtime.read(CAPABILITIES, capability)
        require(runtime.socket_identity() == bound and not stop.is_set(), "startup identity changed or cancelled")
        await server.start_serving()
        operation.remaining()
        require(not stop.is_set(), "startup cancelled before ready")
        operation.complete()
        emit({"schema": RESULT, "ready": True, "owner": owner})
        await stop.wait()
    finally:
        for signum in handlers:
            loop.remove_signal_handler(signum)
        if server is not None:
            server.close()
            await server.wait_closed()
        elif listener is not None:
            listener.close()
        if engine is not None:
            engine.close()
        try:
            if published_owner is not None:
                cleanup[OWNER] = runtime.remove(OWNER, published_owner, owner)
            if bound is not None:
                cleanup[SOCKET] = runtime.remove(SOCKET, bound)
        finally:
            runtime.close()
            operation.close()
    emit({"schema": RESULT, "event": "foreground-return", "epoch": request["epoch"], "reason": reason,
          "exited": False, "cleanup": cleanup})
    # Return/socket cleanup is explicitly NOT actual process exit evidence.


def shutdown(operation):
    request = operation.request
    capability = capabilities(request)
    owner = request["expected_owner"]
    runtime = Runtime(request)
    try:
        startup_binding(operation, owner)
        expected = ProcessGeneration(**owner["process"])
        with ProcessPin(expected) as pin:
            selected_inode = validate_live(runtime, request, owner, capability, operation.remaining())
            operation.fresh()
            # Repeat ALL live bindings after receipt and request revalidation;
            # no pathname or service-provided PID can replace this open pidfd.
            startup_binding(operation, owner)
            require(validate_live(runtime, request, owner, capability, operation.remaining()) == selected_inode,
                    "selected owner inode replaced")
            require(not pin.exited() and process_generation(expected.pid) == expected, "selected process exited or changed")
            operation.remaining()
            signal.pidfd_send_signal(pin.fileno(), signal.SIGTERM, None, 0)
            pin.wait_exit(operation.remaining())
        # Only the actual exit licenses caller cleanup. Replacements survive.
        cleanup = {OWNER: runtime.remove(OWNER, selected_inode, owner),
                   SOCKET: runtime.remove(SOCKET, owner["socket"]["identity"])}
        receipt = operation.complete()
        return {"schema": RESULT, "fresh": True, "exited": True, "receipt": receipt, "cleanup": cleanup}
    finally:
        runtime.close()



def execute(operation, emit):
    try:
        if not operation.accepted:
            emit(operation.replay())
            return
        request_record(operation.request, operation.fragment, operation.home)
        if operation.request["operation"] == "start":
            asyncio.run(foreground(operation, emit))
        else:
            emit(shutdown(operation))
    except BaseException:
        # Completion failure stays visible even if the effect already happened;
        # an immutable accepted/done record is never rewritten to hide it.
        if operation.accepted:
            try:
                with operation.journal() as transaction:
                    prior = transaction.admit(operation.filename, expected=operation.selection)["receipt"]
                    if prior["state"] == "accepted":
                        transaction.complete(operation.filename, code="effect-failed")
            except BaseException as completion_error:
                print("fm-view-service: outcome publication refused: " + str(completion_error), file=sys.stderr)
        raise
    finally:
        operation.close()
