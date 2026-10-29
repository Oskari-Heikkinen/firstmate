"""Offline v3 bounded-directory and capture-binding reader (Python 3.9+).

Construct through accounting.workload/bound_workload only. No file, process,
clock, hook, enable, installation or capture API. The v2 owner supplies shared
seals, paths, passive grammar, generation checks and result comparison.
Semantics and compatibility: docs/supervision-accounting.md.
"""
import bisect
import copy
from dataclasses import dataclass

from fm_supervision_replay import (MAX_FILE, _Request, _Side,
                                   _Workload, blob, canonical, object_seal,
                                   path_parts, require, seal)

MAX_CAPTURE_READS = 100000

# Fixed projection registry, never a corpus-selected executable. Caller source
# identities/pins are provenance assertions requiring independent review.
CALLERS = {
    "bin/fm-classify-lib.sh:4120": ("crew-state", "value", "continued"),
    "bin/fm-classify-lib.sh:4166": ("crew-state", "value", "continued"),
    "bin/fm-classify-lib.sh:4295": ("crew-state", "value", "continued"),
    "bin/fm-inactive-reconcile.sh:503": ("crew-state", "value", "status"),
    "bin/fm-fleet-snapshot.sh:354": ("crew-state", "first", "continued"),
    "bin/fm-supervise-daemon.sh:1556": ("wake-drain", "identity", "boolean"),
    "bin/fm-session-start.sh:944": ("wake-drain", "merged", "status"),
    "bin/fm-afk-return.sh:784": ("wake-drain", "value-stderr", "boolean"),
    "bin/fm-home-summary-refresh.sh:248": ("fleet-snapshot", "identity", "status"),
    "bin/fm-contributions.sh:184": ("fleet-snapshot", "stdout", "status"),
    "bin/fm-fleet-view.sh:29": ("fleet-snapshot", "value", "status"),
    "bin/fm-secondmate-reconcile.sh:420": ("fleet-snapshot", "value", "boolean"),
    "bin/fm-bearings-snapshot.sh:236": ("fleet-snapshot", "value", "status"),
    "bin/fm-bearings-snapshot.sh:238": ("fleet-snapshot", "value", "status"),
    "bin/fm-bearings-snapshot.sh:241": ("fleet-snapshot", "value", "status"),
}
EXCLUDED_CALLERS = (
    "bin/fm-mem-guard.sh:490", "bin/fm-account.sh:303",
    "bin/fm-supervise-daemon.sh:1584", "bin/fm-fleet-view.sh:22",
    "harness/direct-output", "bin/fm-live-lab.sh:336",
)


@dataclass(frozen=True)
class Access:
    """Captured result: raw read bytes, or canonical JSON for other operations."""
    data: bytes
    error: str


def delivery_bytes(result, delivery):
    require(delivery is not None, "merged delivery order unavailable")
    require(type(delivery) is list and len(delivery) <= 10000, "delivery event count bound")
    chunks = {"stdout": [], "stderr": []}
    combined, total = [], 0
    for item in delivery:
        require(type(item) is dict and set(item) == {"stream", "content"}
                and item["stream"] in chunks and type(item["content"]) is bytes, "invalid delivery event")
        total += len(item["content"])
        require(total <= 2 * MAX_FILE, "delivery byte bound")
        chunks[item["stream"]].append(item["content"])
        combined.append(item["content"])
    require(b"".join(chunks["stdout"]) == result["stdout"] and b"".join(chunks["stderr"]) == result["stderr"],
            "delivery bytes mismatch")
    return b"".join(combined)


def project(caller, result, delivery):
    _, kind, status_kind = CALLERS[caller]
    out, err, status = result["stdout"], result["stderr"], result["exit_status"]
    if kind == "merged":
        # Validate actual fd merge order, not out+err guessing or chunk sizes.
        out, err = delivery_bytes(result, delivery), b""
    if kind in ("value", "first", "merged", "value-stderr"):
        out = out.replace(b"\0", b"").rstrip(b"\n")
        if kind == "first":
            out = out.split(b"\n", 1)[0]
        if kind != "value-stderr":
            err = b""
    elif kind == "stdout":
        err = b""
    status = 0 if status_kind == "continued" else int(status != 0) if status_kind == "boolean" else status
    return out, err, status


class WorkloadV3(_Workload):
    def __init__(self, value):
        super().__init__(value)
        self._bindings = None

    def topology(self, current):
        # Parent listings remain complete; only admitted objects need content.
        # A listed but unrecorded child is NEVER inferred absent or openable.
        for key, value in current.items():
            parts = path_parts(key[3])
            if not parts:
                require(value is None or value["kind"] == "directory", "root object is not a directory")
                continue
            parent = key[:3] + ("/".join(parts[:-1]),)
            directory = current.get(parent)
            require(directory is not None and directory["kind"] == "directory", "missing captured parent directory")
            raw = blob(directory["content"])
            listed = parts[-1].encode("utf-8") in (raw[:-1].split(b"\0") if raw else [])
            require(listed == (value is not None), "admitted child/listing disagreement")

    def version(self, key, at):
        require(key in self._history, "unadmitted place; absence is not inferred")
        index = bisect.bisect_right(self._times[key], at) - 1
        return self._history[key][index][1]

    def derive(self, row, offset=None, length=None):
        op = row["operation"]
        if op == "clock":
            at = row["start_ns"]
            return Access(canonical(at if row["clock"] == "monotonic" else
                                    self.clock["wall_start_ns"] + at - self.start), "")
        value = self.version(self.place(row["place"]), row["start_ns"])
        if value is None:
            return Access(canonical(False), "") if op == "exists" else Access(b"", "ENOENT")
        if value["error"]:
            return Access(b"", value["error"])
        if op == "exists":
            return Access(canonical(True), "")
        if op == "stat":
            return Access(canonical({k: value[k] for k in ("identity", "kind", "mode", "mtime_ns")}), "")
        raw = blob(value["content"])
        if op == "list":
            if value["kind"] != "directory":
                return Access(b"", "EINVAL")
            if not value["mode"] & 0o444:
                return Access(b"", "EACCES")
            return Access(raw, "")
        if value["kind"] == "directory":
            return Access(b"", "EISDIR")
        if value["kind"] != "regular":
            return Access(b"", "EINVAL")
        if not value["mode"] & 0o444:
            return Access(b"", "EACCES")
        offset = row["offset"] if offset is None else offset
        length = row["length"] if length is None else length
        return Access(raw[offset:offset + length], "")

    def bind(self, value):
        require(self._bindings is None and not self._sides, "duplicate or late capture binding")
        value = copy.deepcopy(value)
        require(value["sha256"] == seal({k: v for k, v in value.items() if k != "sha256"}), "binding seal mismatch")
        require(value["workload_sha256"] == self.digest, "binding workload mismatch")
        participating = {key[0] for key in self._history} | {r["home"] for r in self._requests.values()}
        require(all(home["code_ref"] == value["code_ref"] for home in self._value["manifest"]["homes"]
                    if home["id"] in participating), "binding code pin mismatch")
        require(value["start_ns"] == self.start and value["cutoff_ns"] == self.start + 60_000_000_000
                and value["cutoff_ns"] <= self.end <= value["cutoff_ns"] + 30_000_000_000,
                "binding selection window mismatch")
        require([row["id"] for row in value["requests"]] == self._order, "binding request inventory mismatch")
        total_reads = 0
        for captured, request in zip(value["requests"], self.requests):
            require(self.start <= request["start_ns"] < value["cutoff_ns"], "request outside start window")
            require(captured["caller"] in CALLERS and CALLERS[captured["caller"]][0] == request["kind"],
                    "unknown or foreign caller projection")
            seen, previous = set(), request["start_ns"]
            total_reads += len(captured["reads"])
            require(total_reads <= MAX_CAPTURE_READS, "capture read count bound")
            for row in captured["reads"]:
                require(row["id"] not in seen, "duplicate logical read point")
                seen.add(row["id"])
                require(previous <= row["start_ns"] <= row["end_ns"] <= request["end_ns"], "read interval/order mismatch")
                previous = row["end_ns"]
                if row["operation"] == "clock":
                    require(row["place"] is None and row["clock"] in ("wall", "monotonic")
                            and row["version_sha256"] is None, "invalid clock binding")
                else:
                    require(row["clock"] == "", "file read has clock selector")
                    key = self.place(row["place"])
                    require(key[0] == request["home"], "foreign scheduled read")
                    version = self.version(key, row["start_ns"])
                    require(object_seal(version) == row["version_sha256"], "read version mismatch")
                    require(not any(row["start_ns"] < at <= row["end_ns"] for at in self._times[key]),
                            "file changed during scheduled read")
                require(row["operation"] == "read" or (row["offset"] == 0 and row["length"] == 0),
                        "range on non-read operation")
                require(row["offset"] + row["length"] <= MAX_FILE, "scheduled range bound")
                result = self.derive(row)
                require(Access(self._add_blob(row["result"]), row["error"]) == result, "scheduled result mismatch")
            self._add_blob(captured["live"]["stdout"])
            self._add_blob(captured["live"]["stderr"])
            places, commits = set(), {}
            for effect in captured["live"]["effects"]:
                key = self.place(effect["place"])
                require(key[0] == request["home"] and key[1] in ("state", "data") and key not in places,
                        "foreign or duplicate live effect")
                places.add(key)
                seq = effect["change_seq"]
                require(seq <= len(self._value["changes"]), "effect change missing")
                change = self._value["changes"][seq - 1]
                commit = effect["commit_id"]
                require(commit not in commits or commits[commit] == change["at_ns"], "commit spans atomic groups")
                commits[commit] = change["at_ns"]
                obj = change["object"]
                content = self._add_blob(effect["content"]) if effect["content"] is not None else None
                expected = blob(obj["content"]) if obj is not None else None
                require(self.place(change["place"]) == key and request["start_ns"] <= change["at_ns"] <= request["end_ns"]
                        and expected == content, "effect commit/image mismatch")
        self._bindings = value
        self._bound_requests = {r["id"]: r for r in value["requests"]}
        return self

    def summary(self):
        result = super().summary()
        result.update(format="fm-supervision-workload-reader.v3", capture_bindings=self._bindings is not None,
                      scope="captured-subset-reader-only", whole_workload_coverage=False,
                      passive_observation_policy="exact-logical-consumption",
                      excluded_callers=[dict(caller=c, count=None) for c in EXCLUDED_CALLERS])
        if self._bindings is not None:
            result["bindings_sha256"] = self._bindings["sha256"]
            result["admission_sha256"] = self._bindings["admission_sha256"]
        return result

    def _make_side(self, name):
        require(self._bindings is not None, "capture bindings required before replay")
        return BoundSide(self, name)


class BoundSide(_Side):
    def _make_request(self, request):
        return BoundRequest(self, request)


class BoundRequest(_Request):
    def __init__(self, side, request):
        super().__init__(side, request)
        self._captured = side._workload._bound_requests[request["id"]]
        self._read_index = 0

    def object(self, place, at_ns):
        return self._guard(lambda: require(False, "unscheduled object API forbidden in v3"))

    def wall_ns(self, at_ns):
        return self._guard(lambda: require(False, "unscheduled clock API forbidden in v3"))

    def access(self, operation, place=None, *, clock="", offset=0, length=0, point=None, at_ns=None):
        def action():
            require(type(offset) is int and type(length) is int and 0 <= offset <= offset + length <= MAX_FILE,
                    "invalid requested range")
            rows = self._captured["reads"]
            owner = self._side._workload
            key = owner.place(place) if place is not None else None
            if self._side.name == "legacy":
                require(self._read_index < len(rows), "extra legacy read")
                row = rows[self._read_index]
                require((operation, place, clock, offset, length, point, at_ns) ==
                        (row["operation"], row["place"], row["clock"], row["offset"], row["length"], row["id"], row["start_ns"]),
                        "legacy read schedule mismatch")
                self._advance(at_ns)
                self._advance(row["end_ns"])
                self._read_index += 1
                return owner.derive(row)
            require(at_ns is None, "candidate cannot choose a read time")
            peers = [r for r in rows if r["place"] == place and r["operation"] == operation and r["clock"] == clock]
            require(peers, "candidate input instance was not read by legacy")
            if key is None:
                require(operation == "clock", "invalid candidate clock input")
                versions = {blob(r["result"]) for r in peers}
            else:
                versions = {r["version_sha256"] for r in rows if r["place"] == place}
            if point is not None:
                selected = [r for r in peers if r["id"] == point]
                require(selected, "unknown candidate logical read point")
                row = selected[0]
            else:
                require(len(versions) == 1, "changed input requires logical read point")
                row = peers[0]
            if operation == "read":
                compatible = [r for r in peers if r["version_sha256"] == row["version_sha256"] and r["error"] == row["error"]]
                end = offset
                for left, right in sorted((r["offset"], r["offset"] + r["length"]) for r in compatible):
                    if left <= end:
                        end = max(end, right)
                require(end >= offset + length and any(r["offset"] <= offset <= r["offset"] + r["length"] for r in compatible),
                        "candidate range exceeds captured reads")
            else:
                require(offset == 0 and length == 0, "range on non-read operation")
            return owner.derive(row, offset, length)
        return self._guard(action)

    def _effect_valid(self, content):
        return content is None or super()._effect_valid(content)

    def _effect_size(self, content):
        return 0 if content is None else super()._effect_size(content)

    def complete(self, *, stdout, stderr, exit_status, effects, delivery=None, commits=()):
        def action():
            require(self._side.name != "legacy" or self._read_index == len(self._captured["reads"]),
                    "unconsumed legacy reads")
            require(type(commits) in (list, tuple) and type(effects) is list and len(commits) == len(effects)
                    and all(type(c) is str for c in commits), "owner commit identity mismatch")
            super(BoundRequest, self).complete(stdout=stdout, stderr=stderr, exit_status=exit_status, effects=effects)
            owner = self._side._workload
            expected_commits = sorted((owner.place(e["place"]), e["commit_id"]) for e in self._captured["live"]["effects"])
            actual_commits = sorted((owner.place(e["place"]), c) for e, c in zip(effects, commits))
            require(actual_commits == expected_commits, "owner commit identity mismatch")
            result = self._side._completed[self._request["id"]]
            # Compare delivered byte order, not irrelevant write chunk sizes.
            result["delivery"] = (delivery_bytes(result, delivery) if delivery is not None
                                  or CALLERS[self._captured["caller"]][1] == "merged" else None)
            result["commits"] = actual_commits
            if self._side.name == "legacy":
                live = self._captured["live"]
                expected_effects = sorted([dict(place=e["place"], content=blob(e["content"]) if e["content"] is not None else None)
                                           for e in live["effects"]],
                                          key=lambda e: self._side._workload.place(e["place"]))
                require(project(self._captured["caller"], result, delivery) ==
                        (blob(live["stdout"]), blob(live["stderr"]), live["exit_status"])
                        and result["effects"] == expected_effects, "legacy caller-visible live fidelity mismatch")
        return self._guard(action)
