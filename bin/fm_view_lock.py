"""Private read-service-only flock anchors, never legacy transaction locks.

Internal API for the uninstalled foreground owner and its lifecycle journal.
Roots must already exist. Anchors are persistent owned single-link 0600 files
in canonical private 0700 directories. They are never unlinked or recovered
from a PID. Closing a descriptor relinquishes only that invocation's lock.
No record, liveness verdict, service effect or action authority is produced.
"""
import fcntl
import os
from pathlib import Path
import stat

from fm_view_bundle import directory, require
from fm_view_lifecycle import object_fields, pair, path


class PrivateAnchor:
    """One nonblocking private mutex, with failure-safe context entry.

    A subclass may add root checks in fresh(), calling super().fresh() last.
    All subclass observations must be initialized before this constructor.
    parent_identity is the caller's already selected directory incarnation.
    Failed construction or entry closes acquired fds even on BaseException.
    """
    def __init__(self, anchor, label, parent_identity):
        self.fd = None
        self.anchor = Path(anchor)
        self.label = label
        directory(self.anchor.parent, 0o700)
        parent_fd, fd = None, None
        try:
            parent_fd = os.open(self.anchor.parent, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_NONBLOCK)
            try:
                parent = os.fstat(parent_fd)
                require(stat.S_ISDIR(parent.st_mode) and parent.st_uid == os.getuid()
                        and stat.S_IMODE(parent.st_mode) == 0o700, "unsafe " + self.label + " parent")
                require((parent.st_dev, parent.st_ino) == tuple(parent_identity), self.label + " parent replaced")
                # Creation is relative to the selected directory incarnation,
                # not a pathname that could now lead into a successor's tree.
                fd = os.open(self.anchor.name, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW | os.O_NONBLOCK,
                             0o600, dir_fd=parent_fd)
                info = os.fstat(fd)
                require(stat.S_ISREG(info.st_mode) and info.st_uid == os.getuid()
                        and info.st_nlink == 1 and stat.S_IMODE(info.st_mode) == 0o600,
                        "unsafe " + self.label + " anchor")
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                self.fd = fd
                self.anchor_identity = (info.st_dev, info.st_ino)
                self.fresh()
            finally:
                os.close(parent_fd)
        except BaseException:
            self.fd = None
            if fd is not None:
                os.close(fd)
            raise

    def fresh(self):
        require(self.fd is not None, self.label + " transaction closed")
        info = self.anchor.lstat()
        require((info.st_dev, info.st_ino) == self.anchor_identity
                and stat.S_ISREG(info.st_mode) and info.st_uid == os.getuid()
                and info.st_nlink == 1 and stat.S_IMODE(info.st_mode) == 0o600,
                self.label + " anchor replaced")

    def close(self):
        if self.fd is not None:
            fd, self.fd = self.fd, None
            os.close(fd)

    def __enter__(self):
        try:
            self.fresh()
        except BaseException:
            self.close()
            raise
        return self

    def __exit__(self, *_):
        self.close()


class ServiceSingleton(PrivateAnchor):
    """Private runtime admission for the explicit foreground owner only.

    This is NOT the watcher/queue/presentation/source/custody boundary. It
    serializes native read-service starts across all runtimes of one home.
    Start takes this before ANY journal construction/admission; stop does not.
    The caller must retain it through actual process exit after service effects
    begin; socket or executor cleanup does not authorize releasing it. This API
    neither starts a process nor supplies the caller's lifecycle/exit gate.
    """
    def __init__(self, home, runtime, roots):
        home, runtime = path(str(home), "singleton home"), path(str(runtime), "singleton runtime")
        require(home / "state" in runtime.parents, "singleton runtime outside selected state root")
        object_fields(roots, "home state runtime", "singleton roots")
        for name, value in roots.items():
            pair(value, "singleton " + name + " identity")
        self.roots = ((home, None), (home / "state", 0o700), (runtime, 0o700))
        self.identities = tuple(tuple(roots[name]) for name in ("home", "state", "runtime"))
        self.roots_fresh()
        super().__init__(home / "state" / ".view-service.lock", "service singleton", self.identities[1])

    def roots_fresh(self):
        require(all(directory(root, mode)[1] == identity for (root, mode), identity
                    in zip(self.roots, self.identities)), "service singleton root replaced")

    def fresh(self):
        self.roots_fresh()
        super().fresh()
