"""CI-only High-review delta controls; no recorder or live acquisition.

Every counterfactual disables only the named refusal, keeps the same invalid
input and reruns the same exact public refusal oracle. Unexpected exception
classes/messages also fail that oracle; they cannot masquerade as the guard.
"""
import copy
import unittest
from unittest.mock import patch

import binding_checks as base

old, bindings, replay = base.old, base.bindings, base.replay
blob, obj, place = base.blob, base.obj, base.place


def pair():
    value, captured = base.make()
    value["requests"] = value["requests"][:1]
    captured["requests"] = captured["requests"][:1]
    value["changes"] = []
    return value, captured


def sealed(value, captured):
    base.reseal(value)
    captured["workload_sha256"] = value["sha256"]
    return value, base.reseal(captured)


def bound(value, captured):
    return base.model(sealed(value, captured))


def effect(value, captured, path="cursor", at=50, content=b"1\n", commit="commit-1", root="state", home="fixture"):
    location = place(path, root=root, home=home)
    before = next(row["object"] for row in value["files"] if row["place"] == location)
    after = obj(content)
    seq = len(value["changes"]) + 1
    value["changes"].append(dict(seq=seq, at_ns=at, place=location,
                                 before_sha256=replay.object_seal(before), object=after))
    result = dict(place=location, content=blob(content), object_sha256=replay.object_seal(after),
                  change_seq=seq, commit_id=commit)
    captured["requests"][0]["live"]["effects"].append(result)
    return result


def foreign_home(value):
    home = copy.deepcopy(value["manifest"]["homes"][0])
    home.update(id="other", home="/other", state_root="/other/state")
    value["manifest"]["homes"].append(home)
    value["manifest"]["enrolled_homes"].append("other")
    rows = copy.deepcopy(value["files"])
    for row in rows:
        row["place"]["home"] = "other"
    value["files"].extend(rows)


def shift(context, captured, amount):
    for row in [context] + context["observations"] + captured["reads"]:
        row["start_ns"] += amount
        row["end_ns"] += amount
    for row in captured["reads"]:
        if row["operation"] == "clock":
            row["result"] = blob(replay.canonical(1_000_000 + row["start_ns"]))


def acquisition_end(value, end):
    value["clock"]["monotonic_end_ns"] = end
    value["trace"]["end_ns"] = end
    value["trace"]["monotonic_duration_ns"] = end


class DeltaChecks(unittest.TestCase):
    def counterfactual(self, module, message, action):
        def oracle():
            try:
                action()
            except ValueError as error:
                self.assertEqual(str(error), "replay workload: " + message)
            except Exception as error:
                self.fail("wrong refusal type: " + type(error).__name__)
            else:
                self.fail("required refusal missing: " + message)
        oracle()
        original = module.require
        def reverted(condition, reason):
            if reason != message:
                original(condition, reason)
        with patch.object(module, "require", reverted):
            with self.assertRaises(AssertionError):
                oracle()

    def bind_guard(self, message, prepare):
        def action():
            value, captured = pair()
            prepare(value, captured)
            bound(value, captured)
        self.counterfactual(bindings, message, action)

    def access_guard(self, message, name, prepare, arguments):
        def action():
            value, captured = pair()
            prepare(value, captured)
            owner = bound(value, captured)
            side = owner.side(name)
            request = old.opening(side, owner.requests[0])
            if name == "legacy" and arguments is None:
                for row in captured["requests"][0]["reads"]:
                    base.access(request, row)
                try:
                    base.access(request, captured["requests"][0]["reads"][-1])
                except ValueError:
                    with self.assertRaisesRegex(ValueError, "failed or unconsumed"):
                        side.finish()
                    raise
            else:
                request.access(**arguments)
        self.counterfactual(bindings, message, action)

    def test_caller_provenance_audits_all_pins_and_fails_closed(self):
        # The API audits its explicit source-provenance contract. Assertions are
        # on public audit results/refusals, not implementation byte snapshots.
        keys = tuple(bindings.CALLER_SITES) + tuple(bindings.EXCLUDED_SITES)
        paths = {key.rsplit(":", 1)[0] for key in keys}
        sources = {path: (old.ROOT / path).read_text() for path in paths}
        self.assertEqual(set(bindings.audit_callers(sources)), set(keys))
        self.assertEqual(len(keys), 20)
        for key in keys:
            with self.subTest(pin=key):
                broken = dict(sources)
                path, number = key.rsplit(":", 1)
                lines = broken[path].splitlines()
                lines[int(number) - 1] = "# independent invocation mismatch"
                broken[path] = "\n".join(lines)
                self.counterfactual(bindings, "caller source pin mismatch: " + key,
                                    lambda: bindings.audit_callers(broken))
        drifted = dict(sources)
        drifted["bin/fm-classify-lib.sh"] = "# line drift\n" + drifted["bin/fm-classify-lib.sh"]
        with self.assertRaisesRegex(ValueError, "caller source pin mismatch"):
            bindings.audit_callers(drifted)
        for bad in (None, {}, dict(sources, **{next(iter(paths)): None})):
            self.counterfactual(bindings, "caller source inventory mismatch", lambda: bindings.audit_callers(bad))

    def test_inherited_stderr_is_visible_for_every_selected_snapshot_caller(self):
        result = dict(stdout=b"first\nsecond\n\n", stderr=b"inherited\n", exit_status=7)
        for key, (_, kind, _) in bindings.CALLERS.items():
            with self.subTest(caller=key):
                if key.startswith(("bin/fm-fleet-view.sh:", "bin/fm-secondmate-reconcile.sh:", "bin/fm-bearings-snapshot.sh:")):
                    self.assertEqual(bindings.project(key, result, None)[1], result["stderr"])
                if key.startswith("bin/fm-contributions.sh:"):
                    self.assertEqual(bindings.project(key, result, None), (result["stdout"], result["stderr"], 7))
                if kind in ("value-stderr", "identity"):
                    continue
        value, captured = pair()
        value["requests"][0].update(kind="fleet-snapshot", task="")
        captured["requests"][0].update(caller="bin/fm-fleet-view.sh:29")
        owner = bound(value, captured)
        with self.assertRaisesRegex(ValueError, "caller-visible live fidelity"):
            base.consume(owner.side("legacy"), owner, stderr=b"previously discarded")

    def test_window_each_independent_conjunct(self):
        for field, value in (("start_ns", 1), ("cutoff_ns", 59_000_000_000)):
            self.bind_guard("binding selection window mismatch", lambda v, c: c.update({field: value}))
        for end in (59_000_000_000, 90_000_000_001):
            self.bind_guard("binding selection window mismatch", lambda v, c: acquisition_end(v, end))
        for start in (60_000_000_000, 60_000_000_001):
            def prepare(v, c):
                acquisition_end(v, 90_000_000_000)
                shift(v["requests"][0], c["requests"][0], start - v["requests"][0]["start_ns"])
            self.bind_guard("request outside start window", prepare)
        # Lower request bound is owned by the shared workload order guard, not
        # a redundant binding guard. An isolated pre-origin request refuses.
        self.counterfactual(replay, "request order/interval bound", lambda: self._before_origin())

    def _before_origin(self):
        value = old.make()
        value["requests"][0].update(start_ns=0, end_ns=90)
        value["clock"]["monotonic_start_ns"] = 1
        value["trace"]["start_ns"] = 1
        value["trace"]["monotonic_duration_ns"] -= 1
        return old.accounting.workload(old.reseal(value))

    def test_read_origin_and_changed_during_read(self):
        def foreign(v, c):
            foreign_home(v)
            c["requests"][0]["reads"][0]["place"]["home"] = "other"
        self.bind_guard("foreign scheduled read", foreign)
        def crossing(v, c):
            before = next(r["object"] for r in v["files"] if r["place"] == place("task-0.meta"))
            v["changes"] = [dict(seq=1, at_ns=12, place=place("task-0.meta"),
                                  before_sha256=replay.object_seal(before), object=copy.deepcopy(before))]
            c["requests"][0]["reads"][0]["end_ns"] = 12
        self.bind_guard("file changed during scheduled read", crossing)

    def test_effect_namespace_duplicate_change_group_and_each_image_conjunct(self):
        def foreign(v, c):
            foreign_home(v)
            effect(v, c, home="other")
        self.bind_guard("foreign or duplicate live effect", foreign)
        def config(v, c):
            root = next(r["object"] for r in v["files"] if r["place"] == place(root="config"))
            root["content"] = blob(b"cursor\0")
            v["files"].append(dict(place=place("cursor", root="config"), object=obj(b"0\n")))
            effect(v, c, root="config")
        self.bind_guard("foreign or duplicate live effect", config)
        def duplicate(v, c):
            row = effect(v, c)
            c["requests"][0]["live"]["effects"].append(copy.deepcopy(row))
        self.bind_guard("foreign or duplicate live effect", duplicate)
        def missing(v, c):
            effect(v, c)["change_seq"] = 2
        self.bind_guard("effect change missing", missing)
        def groups(v, c):
            effect(v, c)
            effect(v, c, path="task-0.meta", at=60)
        self.bind_guard("commit spans atomic groups", groups)
        for kind in ("place", "before-request", "after-request", "content", "kind", "mode", "identity", "mtime_ns", "error"):
            def prepare(v, c):
                row = effect(v, c)
                if kind == "place":
                    row["place"] = place("task-0.meta")
                elif kind == "before-request":
                    v["changes"][0]["at_ns"] = 5
                elif kind == "after-request":
                    v["changes"][0]["at_ns"] = 101
                elif kind == "content":
                    row["content"] = blob(b"wrong image")
                else:
                    image = copy.deepcopy(v["changes"][0]["object"])
                    image[kind] = {"kind": "directory", "mode": 0, "identity": "replacement", "mtime_ns": 1, "error": "EIO"}[kind]
                    row["object_sha256"] = replay.object_seal(image)
            with self.subTest(conjunct=kind):
                self.bind_guard("effect commit/image mismatch", prepare)

    def test_atomic_claims_cannot_be_reused_by_another_request(self):
        for same_seq in (True, False):
            def action():
                value, captured = base.make()
                value["requests"], captured["requests"] = value["requests"][:2], captured["requests"][:2]
                value["changes"] = []
                shift(value["requests"][1], captured["requests"][1], -90)
                row = effect(value, captured)
                if same_seq:
                    captured["requests"][1]["live"]["effects"] = [dict(row, commit_id="other-owner")]
                else:
                    second = effect(value, captured, path="task-0.meta", at=51)
                    captured["requests"][0]["live"]["effects"].pop()
                    captured["requests"][1]["live"]["effects"] = [second]
                bound(value, captured)
            self.counterfactual(bindings, "change claimed by multiple requests" if same_seq else
                                "commit claimed by multiple requests", action)

    def test_actual_owner_commit_pairing_not_inventory_length(self):
        def action():
            value, captured = pair()
            effect(value, captured)
            owner = bound(value, captured)
            sides = [owner.side(name) for name in ("legacy", "candidate")]
            for side in sides:
                base.consume(side, owner, effects=[dict(place=place("cursor"), content=b"1\n")],
                             commits=["wrong-but-correct-length"])
            self.assertTrue(replay.compare(*sides)["equal"])
        self.counterfactual(bindings, "owner commit identity mismatch", action)
        class Token(str):
            pass
        def inventory():
            value, captured = pair()
            effect(value, captured)
            owner = bound(value, captured)
            base.consume(owner.side("candidate"), owner, effects=[dict(place=place("cursor"), content=b"1\n")],
                         commits=[Token("commit-1")])
        self.counterfactual(bindings, "invalid owner commit inventory", inventory)
        # The candidate's otherwise valid image must include object metadata.
        for key in ("kind", "mode"):
            value, captured = pair()
            row = effect(value, captured)
            image = copy.deepcopy(value["changes"][0]["object"])
            image[key] = "directory" if key == "kind" else 0
            owner = bound(value, captured)
            with self.assertRaisesRegex(ValueError, "live fidelity"):
                base.consume(owner.side("legacy"), owner,
                             effects=[dict(place=place("cursor"), content=b"1\n", object_sha256=replay.object_seal(image))],
                             commits=[row["commit_id"]])

    def test_access_guards_are_reached_at_access_not_factory(self):
        for field in ("offset", "length"):
            args = dict(operation="read", place=place("task-0.meta"), offset=0, length=1)
            args[field] = True
            self.access_guard("invalid requested range", "candidate", lambda v, c: None, args)
        for args in (dict(operation="read", place=place("task-0.meta"), offset=-1, length=0),
                     dict(operation="read", place=place("task-0.meta"), offset=0, length=-1),
                     dict(operation="read", place=place("task-0.meta"), offset=replay.MAX_FILE, length=1)):
            self.access_guard("invalid requested range", "candidate", lambda v, c: None, args)
        self.access_guard("extra legacy read", "legacy", lambda v, c: None, None)
        self.access_guard("unknown candidate logical read point", "candidate", lambda v, c: None,
                          dict(operation="read", place=place("task-0.meta"), length=1, point="missing"))
        def stat(v, c):
            source = next(r["object"] for r in v["files"] if r["place"] == place("task-0.meta"))
            row = c["requests"][0]["reads"][0]
            row.update(operation="stat", offset=0, length=0,
                       result=blob(replay.canonical({k: source[k] for k in ("identity", "kind", "mode", "mtime_ns")})))
        for field in ("offset", "length"):
            args = dict(operation="stat", place=place("task-0.meta"), offset=0, length=0)
            args[field] = 1
            self.access_guard("range on non-read operation", "candidate", stat, args)

    def test_delivery_each_count_shape_stream_type_and_byte_bound(self):
        empty = dict(stdout=b"", stderr=b"")
        self.counterfactual(bindings, "merged delivery order unavailable", lambda: bindings.delivery_bytes(empty, None))
        for stream in ("stdout", "stderr"):
            result = dict(empty, **{stream: b"missing"})
            self.counterfactual(bindings, "delivery bytes mismatch", lambda: bindings.delivery_bytes(result, []))
        for bad in ((), [dict(stream="stdout", content=b"")] * 10001):
            self.counterfactual(bindings, "delivery event count bound", lambda: bindings.delivery_bytes(empty, bad))
        for bad in (dict(stream="stdout", content=b"", extra=True), dict(stream="unknown", content=b""),
                    dict(stream="stdout", content=""), dict(stream=[], content=b""), []):
            self.counterfactual(bindings, "invalid delivery event", lambda: bindings.delivery_bytes(empty, [bad]))
        with patch.object(bindings, "MAX_FILE", 1):
            self.counterfactual(bindings, "delivery byte bound",
                                lambda: bindings.delivery_bytes(dict(stdout=b"abc", stderr=b""), [dict(stream="stdout", content=b"abc")]))

    def test_v3_topology_counterfactuals_and_absence_contract(self):
        def root(v, c):
            v.update(files=[dict(place=place(), object=obj())], changes=[], requests=[])
            c["requests"] = []
        self.bind_guard("root object is not a directory", root)
        def parent(v, c):
            v["files"][0]["object"]["content"] = blob(replay.blob(v["files"][0]["object"]["content"]) + b"parent\0")
            v["files"] += [dict(place=place("parent"), object=obj()), dict(place=place("parent/absent"), object=None)]
        self.bind_guard("missing captured parent directory", parent)
        self.bind_guard("unadmitted captured parent",
                        lambda v, c: v["files"].append(dict(place=place("unknown/absent"), object=None)))
        for depth in (1, 3):
            value, captured = pair()
            for index in range(1, depth + 1):
                value["files"].append(dict(place=place("/".join(["gone"] * index)), object=None))
            owner = bound(value, captured)
            self.assertIsNone(owner.version(owner.place(place("/".join(["gone"] * depth))), 0))
        value, captured = pair()
        value["files"] += [dict(place=place("gone"), object=None), dict(place=place("gone/child"), object=obj())]
        with self.assertRaisesRegex(ValueError, "missing captured parent"):
            bound(value, captured)
        # An atomic directory removal can retain explicit descendant absences.
        value, captured = pair()
        directory = obj(b"child\0", kind="directory")
        root = value["files"][0]["object"]
        root["content"] = blob(replay.blob(root["content"]) + b"gone\0")
        value["files"] += [dict(place=place("gone"), object=directory), dict(place=place("gone/child"), object=obj())]
        for seq, path, before in ((1, "gone/child", value["files"][-1]["object"]), (2, "gone", directory)):
            value["changes"].append(dict(seq=seq, at_ns=50, place=place(path), before_sha256=replay.object_seal(before), object=None))
        after = copy.deepcopy(root)
        after["content"] = blob(replay.blob(root["content"]).replace(b"gone\0", b""))
        value["changes"].append(dict(seq=3, at_ns=50, place=place(), before_sha256=replay.object_seal(root), object=after))
        owner = bound(value, captured)
        self.assertIsNone(owner.version(owner.place(place("gone/child")), 50))

    def test_unscheduled_unknown_changed_and_coverage_refusals(self):
        for message, operation in (("unscheduled object API forbidden in v3", "object"),
                                   ("unscheduled clock API forbidden in v3", "wall_ns")):
            def action():
                owner = bound(*pair())
                request = old.opening(owner.side("candidate"), owner.requests[0])
                if operation == "object":
                    request.object(place("cursor"), 11)
                else:
                    request.wall_ns(11)
            self.counterfactual(bindings, message, action)
        def unknown():
            owner = bound(*pair())
            return owner.version(owner.place(place("unadmitted")), 11)
        self.counterfactual(bindings, "unadmitted place; absence is not inferred", unknown)
        def clock_changes(v, c):
            row = copy.deepcopy(c["requests"][0]["reads"][-1])
            row.update(id="later-clock", start_ns=22, end_ns=22, result=blob(replay.canonical(1_000_022)))
            c["requests"][0]["reads"].append(row)
        self.access_guard("changed input requires logical read point", "candidate", clock_changes,
                          dict(operation="clock", clock="wall"))
        def gap(v, c):
            row = c["requests"][0]["reads"][2]
            row.update(length=7, result=blob(replay.blob(row["result"])[:7]))
        self.access_guard("candidate range exceeds captured reads", "candidate", gap,
                          dict(operation="read", place=place("task-0.status"), offset=7, length=1))

    def test_remaining_clock_interval_listing_and_late_binding_conjuncts(self):
        for field, value in (("place", place()), ("clock", ""), ("version_sha256", "0" * 64)):
            self.bind_guard("invalid clock binding", lambda v, c: c["requests"][0]["reads"][-1].update({field: value}))
        for field in ("offset", "length"):
            self.bind_guard("range on non-read operation", lambda v, c: c["requests"][0]["reads"][-1].update({field: 1}))
        for row_index, field, value in ((0, "start_ns", 9), (0, "end_ns", 10), (-1, "end_ns", 101)):
            self.bind_guard("read interval/order mismatch",
                            lambda v, c: c["requests"][0]["reads"][row_index].update({field: value}))
        self.bind_guard("admitted child/listing disagreement",
                        lambda v, c: v["files"].append(dict(place=place("private-unadmitted"), object=None)))
        self.bind_guard("admitted child/listing disagreement",
                        lambda v, c: v["files"][0]["object"].update(
                            content=blob(replay.blob(v["files"][0]["object"]["content"]).replace(b"cursor\0", b""))))
        def late():
            value, captured = pair()
            value, captured = sealed(value, captured)
            owner = old.accounting.workload(value)
            with self.assertRaisesRegex(ValueError, "capture bindings required before replay"):
                owner.side("candidate")
            owner.bind(captured)
        self.counterfactual(bindings, "duplicate or late capture binding", late)
        def unbound():
            value, captured = pair()
            return old.accounting.workload(sealed(value, captured)[0]).side("candidate")
        self.counterfactual(bindings, "capture bindings required before replay", unbound)

    def test_topology_dirty_groups_do_not_rewalk_inventory_or_redecode_listings(self):
        value, captured = pair()
        owner = bound(value, captured)
        current = {owner.place(row["place"]): row["object"] for row in value["files"]}
        class NoWalk(dict):
            def __iter__(self):
                raise AssertionError("topology rescanned all places")
            def items(self):
                raise AssertionError("topology rescanned all places")
            def keys(self):
                raise AssertionError("topology rescanned all places")
        with patch.object(bindings, "blob", side_effect=AssertionError("listing decoded twice")):
            for _ in range(100):
                owner.topology(NoWalk(current), {owner.place(place("cursor"))})
        root = copy.deepcopy(current[owner.place(place())])
        root["content"] = blob(b"private-unadmitted\0")
        current[owner.place(place())] = root
        with self.assertRaisesRegex(ValueError, "admitted child/listing disagreement"):
            owner.topology(NoWalk(current), {owner.place(place())})

    def test_request_terminated_at_limit_is_witnessed_not_extended(self):
        value, captured = pair()
        value["requests"][0]["end_ns"] = value["requests"][0]["start_ns"] + 30_000_000_000
        owner = bound(value, captured)
        sides = [owner.side(name) for name in ("legacy", "candidate")]
        for side in sides:
            base.consume(side, owner, status=143)
        self.assertTrue(replay.compare(*sides)["equal"])
        self.assertEqual(sides[0].finish()["r0"]["exit_status"], 143)

    def test_shared_v2_topology_uses_distinct_refusal_oracles(self):
        def root():
            value = old.make()
            value.update(files=[dict(place=place(), object=obj())], changes=[], requests=[])
            return old.accounting.workload(old.reseal(value))
        self.counterfactual(replay, "root object is not a directory", root)
        def parent():
            value = old.make()
            value.update(files=[dict(place=place(), object=obj(b"parent\0", kind="directory")),
                                dict(place=place("parent"), object=obj(b"child\0")),
                                dict(place=place("parent/child"), object=obj())], changes=[], requests=[])
            return old.accounting.workload(old.reseal(value))
        self.counterfactual(replay, "missing captured parent directory", parent)

    def test_type_strict_adapter_values_and_indexed_large_reads(self):
        for left, right in ((True, 1), (1, 1.0), ({"n": [True]}, {"n": [1]}), ((1,), (1.0,))):
            self.assertFalse(replay.strict_equal(left, right))
            self.assertTrue(replay.strict_equal(left, copy.deepcopy(left)))
            with patch.object(replay, "strict_equal", lambda a, b: a == b):
                with self.assertRaises(AssertionError):
                    self.assertFalse(replay.strict_equal(left, right))
        value, captured = pair()
        row = captured["requests"][0]["reads"][0]
        captured["requests"][0]["reads"] = [dict(row, id="read-" + str(i)) for i in range(10000)]
        owner = bound(value, captured)
        request = old.opening(owner.side("candidate"), owner.requests[0])
        # Repeated reads do not re-scan or decode the 10k-row captured schedule.
        # Hostile iterables make an accidental rewalk an observable failure,
        # instead of using runner-speed thresholds as a complexity test.
        class NoWalk(list):
            def __iter__(self):
                raise AssertionError("candidate rescanned captured schedule")
        request._captured["reads"] = NoWalk(request._captured["reads"])
        for _ in range(100):
            self.assertEqual(request.access("read", row["place"], length=row["length"]).data, replay.blob(row["result"]))


if __name__ == "__main__":
    unittest.main(verbosity=2)
