"""Fresh, read-only primitive preflight, without service startup authority.

The selected immutable bundle is verified before any capability is asserted.
No inspected member is dynamically imported to discover capabilities. The
selected inspector's ordinary modules must themselves be trusted code. No
process, registry, receipt, capability file, listener or home mode is written.
The output is an ephemeral response to its invoking owner, not a health record.
"""
import hashlib
import os
from pathlib import Path
import signal
import socket
import struct
import sys

from fm_view_bundle import (MAX_FILE, contained, directory, read_regular,
                            require, verify)
from fm_view_protocol import (PROTOCOL, VERBS, MIN_PYTHON, MAX_MESSAGE,
                              MAX_FILE as MAX_INPUT, MAX_CLIENTS, MAX_TIMEOUT,
                              MAX_WORKERS, MAX_CRITICAL_WORKERS)

SCHEMA = "fm-view-capabilities.v1"
# A different inspector/protocol cannot certify an arbitrary bundle using its
# own newer constants. Old versions remain inspectable with their own tools.
INSPECTOR_FILES = ("bin/fm-view-capabilities.py", "bin/fm_view_capabilities.py",
                   "bin/fm_view_protocol.py")


def kernel_capabilities():
    require(sys.version_info >= MIN_PYTHON, "Python 3.9 or later required")
    require(sys.platform == "linux", "native passive observations require Linux; retain legacy")
    require(hasattr(socket, "SO_PEERCRED"), "peer UID verification unavailable; retain legacy")
    require(hasattr(os, "pidfd_open") and hasattr(signal, "pidfd_send_signal")
            and hasattr(os, "P_PIDFD") and hasattr(os, "WNOWAIT"),
            "pidfd/nonreaping wait unavailable; retain legacy")
    require(signal.getsignal(signal.SIGCHLD) == signal.SIG_DFL,
            "nondefault SIGCHLD handler; retain legacy")
    # Presence of a Python symbol is not kernel capability: seccomp or an old
    # kernel can refuse its syscall. Probe only this inspector's own process.
    fd = os.pidfd_open(os.getpid(), 0)
    try:
        signal.pidfd_send_signal(fd, 0, None, 0)
        try:
            os.waitid(os.P_PIDFD, fd, os.WEXITED | os.WNOHANG | os.WNOWAIT)
        except ChildProcessError:
            pass  # The inspector is not its own child; the idtype is accepted.
        else:
            require(False, "unexpected self-wait result")
    finally:
        os.close(fd)
    left, right = socket.socketpair(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        for sock in (left, right):
            credentials = sock.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, 12)
            require(struct.unpack("3i", credentials)[1] == os.getuid(), "peer UID probe mismatch")
    finally:
        left.close()
        right.close()
    return {"peer_uid": "SO_PEERCRED", "pidfd": True, "nonreaping_wait": True,
            "sigchld": "default"}


def inspect(bundle, expected, home):
    require(type(expected) is str and len(expected) == 64
            and all(c in "0123456789abcdef" for c in expected), "SHA256 bundle identity required")
    home, home_identity = directory(home)
    state, state_identity = directory(home / "state")
    bundle, bundle_identity = directory(bundle, 0o500)
    store, store_identity = directory(bundle.parent, 0o700)
    require(not contained(store, home), "bundle store must be outside operational home")
    for parent in (store, *store.parents):
        require(not os.path.lexists(parent / ".git"), "bundle store is inside a Git checkout")
    manifest = verify(bundle, expected)
    members = {row["path"]: row for row in manifest["files"]}
    current_root = Path(__file__).resolve().parent.parent
    for name in INSPECTOR_FILES:
        raw = read_regular(current_root / name, MAX_FILE)
        require(hashlib.sha256(raw).hexdigest() == members[name]["sha256"],
                "inspector/protocol differs from selected bundle; use that version's inspector")
    features = kernel_capabilities()
    # This is observation binding only, never a cursor, lease or signal target.
    require(directory(home)[1] == home_identity and directory(state)[1] == state_identity
            and directory(store, 0o700)[1] == store_identity
            and directory(bundle, 0o500)[1] == bundle_identity, "preflight root replaced")
    return {"schema": SCHEMA, "scope": "read-only-primitives", "home": str(home),
            "roots": {"home": list(home_identity), "state": list(state_identity)},
            "bundle": {"path": str(bundle), "identity": expected,
                       "commit": manifest["commit"], "tree": manifest["tree"]},
            "python": {"minimum": list(MIN_PYTHON), "running": list(sys.version_info[:3])},
            "platform": sys.platform, "features": features,
            "read_protocol": PROTOCOL, "verbs": list(VERBS),
            "bounds": {"message_bytes": MAX_MESSAGE, "input_bytes": MAX_INPUT,
                       "clients": MAX_CLIENTS, "timeout_ms": int(MAX_TIMEOUT * 1000),
                       "ordinary_workers_max": MAX_WORKERS,
                       "critical_workers_max": MAX_CRITICAL_WORKERS},
            "authority": {"installed": False, "monitoring": False,
                          "identity_bound_shutdown": False, "transactions": False}}
