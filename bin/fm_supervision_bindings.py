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
                                   path_parts, require, seal, strict_equal)

MAX_CAPTURE_READS = 100000

# Fixed code-provenance contract, never corpus-selected code. Pins name the
# physical invocation line (not the start of a multiline command). Audit the
# complete invocation tail, including redirection/continuation, in CI. A real
# capture's code_ref still needs independent provenance review.
CALLER_SITES = {
    "bin/fm-classify-lib.sh:3709": ("crew-state", "value", "continued", 'line=$("$FM_CREW_STATE_BIN" "$id" 2>/dev/null) || true'),
    "bin/fm-classify-lib.sh:3755": ("crew-state", "value", "continued", 'line=$("$FM_CREW_STATE_BIN" "$task" 2>/dev/null) || true'),
    "bin/fm-classify-lib.sh:3884": ("crew-state", "value", "continued", 'line=$("$FM_CREW_STATE_BIN" "$id" 2>/dev/null) || true'),
    "bin/fm-inactive-reconcile.sh:504": ("crew-state", "value", "status", '"$CREW_STATE_BIN" "$id" 2>/dev/null) || state_rc=$?'),
    "bin/fm-fleet-snapshot.sh:362": ("crew-state", "first", "continued", '"$SCRIPT_DIR/fm-crew-state.sh" "$id" 2>/dev/null || true'),
    "bin/fm-supervise-daemon.sh:1556": ("wake-drain", "identity", "boolean", 'if ! "$FM_DAEMON_DIR/fm-wake-drain.sh" > "$out" 2> "$err"; then'),
    "bin/fm-session-start.sh:944": ("wake-drain", "merged", "status", 'DRAIN_OUT=$("$SCRIPT_DIR/fm-wake-drain.sh" 2>&1)'),
    "bin/fm-afk-return.sh:784": ("wake-drain", "value-stderr", "boolean", 'if drained=$("$SCRIPT_DIR/fm-wake-drain.sh" 2> "$drain_err"); then'),
    "bin/fm-home-summary-refresh.sh:248": ("fleet-snapshot", "identity", "status", '"$SCRIPT_DIR/fm-fleet-snapshot.sh" --secondmate-home-summary \\\n> "$HOME_SUMMARY_TMP" 2> "$HOME_SUMMARY_ERR_TMP"; then'),
    "bin/fm-contributions.sh:184": ("fleet-snapshot", "identity", "status", '"$SCRIPT_DIR/fm-fleet-snapshot.sh" --contribution-input > "$TMP/input.json"'),
    "bin/fm-fleet-view.sh:29": ("fleet-snapshot", "value-stderr", "status", 'SNAPSHOT=$("$SCRIPT_DIR/fm-fleet-snapshot.sh" --json) || exit $?'),
    "bin/fm-secondmate-reconcile.sh:420": ("fleet-snapshot", "value-stderr", "boolean", 'snapshot=$("$SCRIPT_DIR/fm-fleet-snapshot.sh" --json) || fail "cannot read the fleet snapshot"'),
    "bin/fm-bearings-snapshot.sh:236": ("fleet-snapshot", "value-stderr", "status", 'SNAP=$(FM_SNAPSHOT_NOW="$NOW" FM_SNAPSHOT_SECONDMATES=0 FM_SNAPSHOT_SECONDMATE_LANDED_PER_HOME=0 "$FLEET" --json) || exit $?'),
    "bin/fm-bearings-snapshot.sh:238": ("fleet-snapshot", "value-stderr", "status", 'SNAP=$(FM_SNAPSHOT_NOW="$NOW" FM_SNAPSHOT_SECONDMATES=0 "$FLEET" --json) || exit $?'),
    "bin/fm-bearings-snapshot.sh:241": ("fleet-snapshot", "value-stderr", "status", 'SNAP=$(FM_SNAPSHOT_NOW="$NOW" "$FLEET" --json) || exit $?'),
}
EXCLUDED_SITES = {
    "bin/fm-mem-guard.sh:490": 'st=$(FM_CREW_STATE_NO_FORGE=1 bounded "$SCRIPT_DIR/fm-crew-state.sh" "$id" 2>/dev/null | head -1)',
    "bin/fm-account.sh:303": 'line=$(FM_CREW_STATE_NO_FORGE=1 FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-crew-state.sh" "$1" 2>/dev/null | head -1)',
    "bin/fm-supervise-daemon.sh:1584": '"$FM_DAEMON_DIR/fm-wake-drain.sh" --ack-through "$ack_through" \\\n--recovery-generation "$ack_generation"',
    "bin/fm-fleet-view.sh:22": '--json) "$SCRIPT_DIR/fm-fleet-snapshot.sh" --json; exit $? ;;',
    "bin/fm-live-lab.sh:336": 'state=$(cd "$LAB" && lab_run FM_HOME="$LAB" FM_CREW_STATE_NO_FORGE=1 "$LAB/bin/fm-crew-state.sh" "$WORKER_ID" 2>/dev/null)',
}
CALLERS = {key: spec[:3] for key, spec in CALLER_SITES.items()}
EXCLUDED_CALLERS = tuple(EXCLUDED_SITES) + ("harness/direct-output",)


def audit_callers(sources):
    """Validate explicit in-memory code snapshots, not live paths or Git refs."""
    sites = {key: spec[3] for key, spec in CALLER_SITES.items()}
    sites.update(EXCLUDED_SITES)
    require(type(sources) is dict and all(type(sources.get(key.rsplit(":", 1)[0])) is str for key in sites),
            "caller source inventory mismatch")
    for key, expected in sites.items():
        path, number = key.rsplit(":", 1)
        lines = sources[path].splitlines()
        start = int(number) - 1
        actual = "\n".join(line.strip() for line in lines[start:start + len(expected.splitlines())])
        require(actual == expected, "caller source pin mismatch: " + key)
    return tuple(sites)


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
                and type(item["stream"]) is str and item["stream"] in chunks
                and type(item["content"]) is bytes, "invalid delivery event")
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
        self._children, self._parents, self._listing_cache = {}, {}, {}
        super().__init__(value)
        self._bindings = None

    def topology(self, current, changed=None):
        # Keys never change. Index once; after an atomic group revisit only its
        # changed objects and their admitted immediate children, not all files.
        if changed is None:
            for key in current:
                parts = path_parts(key[3])
                if parts:
                    parent = key[:3] + ("/".join(parts[:-1]),)
                    self._parents[key] = (parent, parts[-1].encode("utf-8"))
                    self._children.setdefault(parent, set()).add(key)
            selected = current.keys()
        else:
            selected = set(changed)
            for key in changed:
                selected.update(self._children.get(key, ()))
        for key in selected:
            value = current[key]
            if key not in self._parents:
                require(value is None or value["kind"] == "directory", "root object is not a directory")
                continue
            parent, name = self._parents[key]
            # Known absence may propagate below an explicitly absent admitted
            # parent, but never below an unadmitted or non-directory object.
            require(parent in current, "unadmitted captured parent")
            directory = current[parent]
            if directory is None and value is None:
                continue
            require(directory is not None and directory["kind"] == "directory", "missing captured parent directory")
            digest = directory["content"]["sha256"]
            if digest not in self._listing_cache:
                raw = blob(directory["content"])
                self._listing_cache[digest] = frozenset(raw[:-1].split(b"\0") if raw else ())
            listed = name in self._listing_cache[digest]
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
        claimed_changes, commit_requests = {}, {}
        for captured, request in zip(value["requests"], self.requests):
            require(request["start_ns"] < value["cutoff_ns"], "request outside start window")
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
                    require(bisect.bisect_right(self._times[key], row["start_ns"]) ==
                            bisect.bisect_right(self._times[key], row["end_ns"]),
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
                require(seq not in claimed_changes or claimed_changes[seq] == request["id"],
                        "change claimed by multiple requests")
                claimed_changes[seq] = request["id"]
                commit = effect["commit_id"]
                require(commit not in commit_requests or commit_requests[commit] == request["id"],
                        "commit claimed by multiple requests")
                commit_requests[commit] = request["id"]
                require(commit not in commits or commits[commit] == change["at_ns"], "commit spans atomic groups")
                commits[commit] = change["at_ns"]
                obj = change["object"]
                content = self._add_blob(effect["content"]) if effect["content"] is not None else None
                expected = blob(obj["content"]) if obj is not None else None
                require(self.place(change["place"]) == key and request["start_ns"] <= change["at_ns"] <= request["end_ns"]
                        and expected == content and effect["object_sha256"] == object_seal(obj),
                        "effect commit/image mismatch")
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
        self._peers, self._points, self._versions, self._ranges = {}, {}, {}, {}
        self._point_selectors = {}
        for row in self._captured["reads"]:
            key = side._workload.place(row["place"]) if row["place"] is not None else None
            selector = (row["operation"], key, row["clock"])
            self._peers.setdefault(selector, []).append(row)
            self._points[row["id"]] = row
            self._point_selectors[row["id"]] = selector
            version_key = key if key is not None else selector
            version = row["version_sha256"] if key is not None else blob(row["result"])
            self._versions.setdefault(version_key, set()).add(version)
            if row["operation"] == "read":
                group = (selector, row["version_sha256"], row["error"])
                self._ranges.setdefault(group, []).append((row["offset"], row["offset"] + row["length"]))
        for group, intervals in self._ranges.items():
            merged = []
            for left, right in sorted(intervals):
                if merged and left <= merged[-1][1]:
                    merged[-1] = (merged[-1][0], max(right, merged[-1][1]))
                else:
                    merged.append((left, right))
            self._ranges[group] = merged

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
                require(strict_equal((operation, place, clock, offset, length, point, at_ns),
                        (row["operation"], row["place"], row["clock"], row["offset"], row["length"], row["id"], row["start_ns"])),
                        "legacy read schedule mismatch")
                self._advance(at_ns)
                self._advance(row["end_ns"])
                self._read_index += 1
                return owner.derive(row)
            require(at_ns is None, "candidate cannot choose a read time")
            selector = (operation, key, clock)
            peers = self._peers.get(selector)
            require(peers, "candidate input instance was not read by legacy")
            # The bound selector inventory admits a null place only for a
            # validated clock; no second, unreachable clock guard is needed.
            versions = self._versions[key if key is not None else selector]
            if point is not None:
                row = self._points.get(point)
                require(row is not None and self._point_selectors[point] == selector, "unknown candidate logical read point")
            else:
                require(len(versions) == 1, "changed input requires logical read point")
                row = peers[0]
            if operation == "read":
                intervals = self._ranges[(selector, row["version_sha256"], row["error"])]
                index = bisect.bisect_right(intervals, (offset, MAX_FILE + 1)) - 1
                require(index >= 0 and intervals[index][0] <= offset <= offset + length <= intervals[index][1],
                        "candidate range exceeds captured reads")
            else:
                require(offset == 0 and length == 0, "range on non-read operation")
            return owner.derive(row, offset, length)
        return self._guard(action)

    def _effect_fields(self):
        return super()._effect_fields() | {"object_sha256"}

    def _effect_valid(self, content):
        return content is None or super()._effect_valid(content)

    def _effect_size(self, content):
        return 0 if content is None else super()._effect_size(content)

    def complete(self, *, stdout, stderr, exit_status, effects, delivery=None, commits=()):
        def action():
            require(self._side.name != "legacy" or self._read_index == len(self._captured["reads"]),
                    "unconsumed legacy reads")
            require(type(commits) in (list, tuple) and type(effects) is list and len(commits) == len(effects)
                    and all(type(c) is str for c in commits), "invalid owner commit inventory")
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
                expected_effects = sorted([dict(place=e["place"], content=blob(e["content"]) if e["content"] is not None else None,
                                                object_sha256=e["object_sha256"])
                                           for e in live["effects"]],
                                          key=lambda e: self._side._workload.place(e["place"]))
                require(project(self._captured["caller"], result, delivery) ==
                        (blob(live["stdout"]), blob(live["stderr"]), live["exit_status"])
                        and result["effects"] == expected_effects, "legacy caller-visible live fidelity mismatch")
        return self._guard(action)
