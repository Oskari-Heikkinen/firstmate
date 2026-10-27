"""P0-owned v2 workload reader and deterministic dual-consumer boundary.

Construct only through fm-supervision-accounting.py:workload, which applies the
shared closed schema, manifest and trace readers first. No filesystem, process,
clock, import-by-corpus or command-execution API. Supplied adapters are trusted
Python callers, not corpus values; production adapter integration is separate.
The format and compatibility owner is docs/supervision-accounting.md.
"""
import base64
import bisect
import copy
from dataclasses import dataclass
import errno
import hashlib
import json
import re
from types import MappingProxyType

MAX_FILE = 4 * 1024 * 1024
MAX_TOTAL = 64 * 1024 * 1024
def require(condition, message):
    if not condition:
        raise ValueError("replay workload: " + message)


def canonical(value):
    return (json.dumps(value, sort_keys=True, indent=2, allow_nan=False) + "\n").encode("ascii")


def seal(value):
    return hashlib.sha256(canonical(value)).hexdigest()


def blob(value):
    raw = base64.b64decode(value["base64"], validate=True)
    require(len(raw) <= MAX_FILE and hashlib.sha256(raw).hexdigest() == value["sha256"],
            "blob byte bound or seal mismatch")
    return raw


def object_seal(value):
    return seal(value) if value is not None else None


def path_parts(path):
    require(type(path) is str and len(path) <= 4096 and "\0" not in path and "\\" not in path,
            "invalid relative path")
    path.encode("utf-8")  # Unrepresentable filenames refuse, never get rewritten.
    parts = path.split("/") if path else []
    require(all(part not in ("", ".", "..") for part in parts), "noncanonical relative path")
    return parts


@dataclass(frozen=True)
class CapturedObject:
    identity: str
    kind: str
    mode: int
    mtime_ns: int
    error: str
    content: bytes

    def read(self):
        if self.error:
            raise OSError(getattr(errno, self.error), "captured " + self.error)
        if self.kind == "directory":
            raise IsADirectoryError(errno.EISDIR, "captured directory")
        require(self.kind == "regular", "nonsymlink regular file required")
        if not self.mode & 0o444:
            raise PermissionError(errno.EACCES, "captured unreadable mode")
        return self.content


@dataclass(frozen=True)
class CapturedObservation:
    exit_status: int
    stdout: bytes
    stderr: bytes
    start_ns: int
    end_ns: int


class _Workload:
    """Validated immutable-input model. Public factory is accounting.workload."""
    def __init__(self, value):
        # Detach caller-owned containers before constructing any indices.
        self._value = copy.deepcopy(value)
        value = self._value
        payload = {key: item for key, item in value.items() if key != "sha256"}
        require(value["sha256"] == seal(payload), "envelope seal mismatch")
        self.digest = value["sha256"]
        self.homes = MappingProxyType({home["id"]: frozenset(task["id"] for task in home["tasks"])
                                       for home in value["manifest"]["homes"]})
        self.clock = MappingProxyType(dict(value["clock"]))
        self._machines = {home["id"]: home["machine"] for home in value["manifest"]["homes"]}
        self.start, self.end = self.clock["monotonic_start_ns"], self.clock["monotonic_end_ns"]
        trace = value["trace"]
        require(self.start == trace["start_ns"] and self.end == trace["end_ns"]
                and 0 < self.end - self.start <= 310_000_000_000
                and self.end - self.start == trace["monotonic_duration_ns"], "clock/trace interval mismatch")
        require(value["synthetic"] == trace["synthetic"], "synthetic provenance mismatch")
        require(bool(self.clock["machine"]) and self.clock["wall_start_ns"] + self.end - self.start <= 2**63 - 1,
                "wall clock origin/bound")
        self._bytes = 0
        current, self._history = {}, {}
        for row in value["files"]:
            key = self.place(row["place"])
            require(key not in current, "duplicate initial file")
            self.object(row["object"])
            current[key] = row["object"]
            self._history[key] = [(self.start, row["object"])]
        self.topology(current)
        previous = self.start
        touched = set()
        for seq, change in enumerate(value["changes"], 1):
            at = change["at_ns"]
            require(change["seq"] == seq and previous <= at <= self.end,
                    "change sequence/clock gap or regression")
            if at != previous:
                self.topology(current)
                touched.clear()
            previous = at
            key = self.place(change["place"])
            require(key in current, "change targets uncaptured file")
            require(key not in touched, "duplicate same-time file change")
            touched.add(key)
            require(change["before_sha256"] == object_seal(current[key]), "change preimage mismatch")
            self.object(change["object"])
            current[key] = change["object"]
            self._history[key].append((at, change["object"]))
        self.topology(current)
        self._times = {key: tuple(at for at, _ in rows) for key, rows in self._history.items()}
        self._requests, self._order = {}, []
        previous = self.start
        observation_ids = set()
        for request in value["requests"]:
            ident, home, task = request["id"], request["home"], request["task"]
            require(ident not in self._requests, "duplicate request id")
            require(home in self.homes and self._machines[home] == self.clock["machine"],
                    "request home/machine not captured")
            require((task in self.homes[home]) if request["kind"] == "crew-state" else task == "",
                    "request task/home binding")
            start, end = request["start_ns"], request["end_ns"]
            require(previous <= start <= end <= self.end and end - start <= 30_000_000_000,
                    "request order/interval bound")
            previous = start
            require((home, "state", "", "") in current, "request state inventory not captured")
            self._add_blob(request["actor"]["claim"])
            if request["actor"]["name"] == "branch":
                require(bool(request["actor"]["token"]), "branch actor lacks claim token")
            previous_observation = start
            for observation in request["observations"]:
                require(observation["id"] not in observation_ids, "duplicate observation id")
                observation_ids.add(observation["id"])
                self.passive(observation, request)
                require(previous_observation <= observation["start_ns"] <= observation["end_ns"] <= end,
                        "observation interval/order")
                previous_observation = observation["end_ns"]
                self._add_blob(observation["stdout"])
                self._add_blob(observation["stderr"])
            self._requests[ident] = request
            self._order.append(ident)
        self._sides = set()

    def _add_blob(self, value):
        raw = blob(value)
        self._bytes += len(raw)
        require(self._bytes <= MAX_TOTAL, "decoded workload byte bound")
        return raw

    def place(self, value):
        require(type(value) is dict and set(value) == {"home", "root", "task", "path"}, "invalid place shape")
        home, root, task, path = (value[key] for key in ("home", "root", "task", "path"))
        require(home in self.homes and root in ("state", "config", "data", "worktree")
                and self._machines[home] == self.clock["machine"], "place home/root/machine binding")
        require((task in self.homes[home]) if root == "worktree" else task == "", "place task binding")
        path_parts(path)
        return home, root, task, path

    def passive(self, observation, request):
        """Single fixed passive vocabulary/argument owner; never runs a command."""
        operation, args = observation["operation"], observation["arguments"]
        cwd = self.place(observation["cwd"])
        require(cwd[0] == request["home"] and cwd in self._history, "foreign or uncaptured observation cwd")
        sha = lambda text: re.fullmatch(r"[0-9a-f]{40}", text) is not None
        admitted = False
        if operation == "git":
            admitted = (args in (["rev-parse", "HEAD"], ["symbolic-ref", "--quiet", "--short", "HEAD"])
                        or (len(args) == 4 and args[:3] == ["rev-parse", "--verify", "--quiet"]
                            and args[3].endswith("^{commit}") and sha(args[3][:-9]))
                        or (len(args) == 4 and args[:2] == ["merge-base", "--is-ancestor"]
                            and sha(args[2]) and sha(args[3])))
            admitted = admitted and cwd[1] == "worktree"
        elif operation == "no-mistakes":
            token = lambda text: re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._:-]{0,199}", text) is not None
            admitted = (args in (["daemon", "status"], ["axi"], ["axi", "status"])
                        or (len(args) == 3 and args[:2] == ["runs", "--limit"]
                            and re.fullmatch(r"[0-9]{1,7}", args[2]) is not None and int(args[2]) <= 1000000)
                        or (len(args) == 4 and args[:3] == ["axi", "status", "--run"] and token(args[3]))
                        or (len(args) == 7 and args[:5] == ["axi", "logs", "--step", "ci", "--run"]
                            and token(args[5]) and args[6] == "--full"))
            admitted = admitted and cwd[1] == "worktree"
        elif operation in ("backend", "snapshot-endpoint", "saved-custody", "done-proof", "forge"):
            admitted = (len(args) == (2 if operation in ("done-proof", "forge") else 1)
                        and args[0] in self.homes[request["home"]]
                        and (not request["task"] or args[0] == request["task"]))
        require(admitted, "unadmitted passive operation/arguments")

    def object(self, value):
        if value is None:
            return
        raw = self._add_blob(value["content"])
        if value["kind"] == "directory":
            require(not raw or raw.endswith(b"\0"), "partial directory inventory")
            names = raw[:-1].split(b"\0") if raw else []
            require(len(set(names)) == len(names), "duplicate directory entry")
            for name in names:
                parts = path_parts(name.decode("utf-8"))
                require(len(parts) == 1, "invalid directory entry")

    def topology(self, current):
        """Explicit inventories prevent an omitted file becoming false absence."""
        children = {}
        for key, value in current.items():
            if value is None:
                continue
            home, root, task, path = key
            parts = path_parts(path)
            if parts:
                parent = (home, root, task, "/".join(parts[:-1]))
                require(parent in current and current[parent] is not None
                        and current[parent]["kind"] == "directory", "missing captured parent directory")
                children.setdefault(parent, set()).add(parts[-1].encode("utf-8"))
            else:
                require(value["kind"] == "directory", "root object is not a directory")
        for key, value in current.items():
            if value is not None and value["kind"] == "directory":
                raw = blob(value["content"])
                names = set(raw[:-1].split(b"\0")) if raw else set()
                require(names == children.get(key, set()), "directory inventory/file mismatch")

    @property
    def requests(self):
        return tuple(copy.deepcopy(self._requests[ident]) for ident in self._order)

    def summary(self):
        return {"format": "fm-supervision-workload-reader.v2", "sha256": self.digest,
                "scope": "sealed-workload-reader-only", "synthetic": self._value["synthetic"],
                "files": len(self._history), "changes": len(self._value["changes"]),
                "requests": len(self._order), "decoded_bytes": self._bytes,
                "production_adapters": False, "b0_status": "pending-reviewed-real-capture",
                "claimed_births_per_second_saved": 0}

    def side(self, name):
        require(name in ("legacy", "candidate") and name not in self._sides, "duplicate or unknown replay side")
        self._sides.add(name)
        return _Side(self, name)


class _Side:
    def __init__(self, workload, name):
        self._workload, self.name = workload, name
        self._opened, self._completed = [], {}
        self._output_bytes = 0
        self._failed = False

    def open(self, ident, *, home, task, generation, kind, arguments, actor):
        require(not self._failed, "replay side already refused")
        try:
            owner = self._workload
            require(len(self._opened) < len(owner._order)
                    and owner._order[len(self._opened)] == ident, "missing/extra/out-of-order request")
            expected = owner._requests[ident]
            actual = dict(home=home, task=task, generation=generation, kind=kind, arguments=arguments, actor=actor)
            require(all(actual[key] == expected[key] for key in actual), "request argument/actor/generation mismatch")
            self._opened.append(ident)
            return _Request(self, expected)
        except (ValueError, KeyError, TypeError):
            self._failed = True
            raise

    def finish(self):
        if self._failed or len(self._completed) != len(self._workload._order):
            self._failed = True
            raise ValueError("replay workload: failed or unconsumed replay requests")
        return copy.deepcopy(self._completed)


class _Request:
    def __init__(self, side, request):
        self._side, self._request = side, request
        self._now, self._next, self._closed = request["start_ns"], 0, False

    def _guard(self, action):
        try:
            require(not self._side._failed and not self._closed, "request closed or side refused")
            return action()
        except (ValueError, KeyError, TypeError):
            self._side._failed = True
            raise

    def _advance(self, at_ns):
        require(type(at_ns) is int and self._now <= at_ns <= self._request["end_ns"], "request clock regression/bound")
        self._now = at_ns

    def wall_ns(self, at_ns):
        def action():
            self._advance(at_ns)
            owner = self._side._workload
            return owner.clock["wall_start_ns"] + at_ns - owner.start
        return self._guard(action)

    def object(self, place, at_ns):
        def action():
            self._advance(at_ns)
            owner = self._side._workload
            key = owner.place(place)
            require(key[0] == self._request["home"], "foreign file read")
            require(key in owner._history, "uncaptured file read; absence is not inferred")
            index = bisect.bisect_right(owner._times[key], at_ns) - 1
            value = owner._history[key][index][1]
            if value is None:
                return None
            return CapturedObject(value["identity"], value["kind"], value["mode"], value["mtime_ns"],
                                  value["error"], blob(value["content"]))
        return self._guard(action)

    def observe(self, *, operation, arguments, cwd, generation, at_ns):
        def action():
            self._advance(at_ns)
            observations = self._request["observations"]
            require(self._next < len(observations), "extra passive observation")
            expected = observations[self._next]
            actual = dict(operation=operation, arguments=arguments, cwd=cwd, generation=generation, start_ns=at_ns)
            require(all(actual[key] == expected[key] for key in actual), "passive observation binding/order mismatch")
            self._advance(expected["end_ns"])
            self._next += 1
            return CapturedObservation(expected["exit_status"], blob(expected["stdout"]), blob(expected["stderr"]),
                                       expected["start_ns"], expected["end_ns"])
        return self._guard(action)

    def complete(self, *, stdout, stderr, exit_status, effects):
        """Compare whole opaque owner outputs/effects, never apply an effect."""
        def action():
            require(type(stdout) is bytes and type(stderr) is bytes and len(stdout) <= MAX_FILE
                    and len(stderr) <= MAX_FILE and type(exit_status) is int and 0 <= exit_status <= 255,
                    "invalid adapter output")
            require(self._next == len(self._request["observations"]), "unconsumed passive observations")
            require(type(effects) is list and len(effects) <= 10000, "invalid effects inventory")
            owner = self._side._workload
            keys, effect_bytes = set(), 0
            for effect in effects:
                require(type(effect) is dict and set(effect) == {"place", "content"}, "invalid effect shape")
                key = owner.place(effect["place"])
                require(key[0] == self._request["home"] and key[1] in ("state", "data")
                        and key in owner._history and key not in keys, "unbound or duplicate owner effect")
                require(type(effect["content"]) is bytes and len(effect["content"]) <= MAX_FILE, "invalid effect bytes")
                keys.add(key)
                effect_bytes += len(effect["content"])
            self._side._output_bytes += len(stdout) + len(stderr) + effect_bytes
            require(self._side._output_bytes <= MAX_TOTAL, "adapter output byte bound")
            # Effects are a set of complete named byte images, not write order.
            ordered = sorted(copy.deepcopy(effects), key=lambda item: owner.place(item["place"]))
            self._side._completed[self._request["id"]] = dict(stdout=stdout, stderr=stderr,
                                                             exit_status=exit_status, effects=ordered)
            self._now, self._closed = self._request["end_ns"], True
        return self._guard(action)


def compare(legacy, candidate):
    """Only completed opposite sides of the SAME sealed workload can compare.

    This verifies caller-supplied adapter results, not their implementation or
    performance. Failure is sticky, including if a caller catches a refusal.
    """
    require(isinstance(legacy, _Side) and isinstance(candidate, _Side)
            and legacy.name == "legacy" and candidate.name == "candidate"
            and legacy._workload is candidate._workload, "comparison workload/side mismatch")
    before, after = legacy.finish(), candidate.finish()
    require(before == after, "whole adapter output/effect mismatch")
    return {"equal": True, "sha256": legacy._workload.digest, "requests": len(before),
            "scope": "supplied-adapter-results-only", "b0_status": "pending-reviewed-real-capture",
            "claimed_births_per_second_saved": 0}
