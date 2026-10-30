"""CI-only v3/binding public-interface controls, never a live recorder."""
import copy
import json
import os
from pathlib import Path
import subprocess
import sys
import unittest
from unittest.mock import patch

import workload_checks as old
import fm_supervision_bindings as bindings
import fm_supervision_replay as replay

accounting, blob, place, obj = old.accounting, old.blob, old.place, old.obj


def reseal(value):
    value["sha256"] = replay.seal({k: v for k, v in value.items() if k != "sha256"})
    return value


def make(count=6):
    value = old.make(count)
    value["format"] = "fm-supervision-replay.v3"
    directory = value["files"][0]["object"]
    directory["content"] = blob(replay.blob(directory["content"]) + b"private-unadmitted\0")
    capture = dict(format="fm-supervision-capture-bindings.v1", workload_sha256="", admission_sha256="2" * 64,
                   code_ref="1" * 40, start_ns=0, cutoff_ns=60_000_000_000, requests=[])
    for request in value["requests"]:
        start = request["start_ns"]
        files = {r["place"]["path"]: r["object"] for r in value["files"] if r["place"]["root"] == "state"}
        reads = []
        for ident, path, offset, length, at in (("meta-first", "task-0.meta", 0, len(replay.blob(files["task-0.meta"]["content"])), start + 1),
                                                ("meta-again", "task-0.meta", 0, len(replay.blob(files["task-0.meta"]["content"])), start + 2),
                                                ("status-left", "task-0.status", 0, 8, start + 3),
                                                ("status-right", "task-0.status", 8, len(replay.blob(files["task-0.status"]["content"])) - 8, start + 4)):
            source = files[path]
            reads.append(dict(id=ident, operation="read", place=place(path), clock="", offset=offset, length=length,
                              start_ns=at, end_ns=at, version_sha256=replay.object_seal(source), error="",
                              result=blob(replay.blob(source["content"])[offset:offset + length])))
        reads.append(dict(id="wall", operation="clock", place=None, clock="wall", offset=0, length=0,
                          start_ns=start + 11, end_ns=start + 11, version_sha256=None,
                          result=blob(replay.canonical(1_000_000 + start + 11)), error=""))
        caller, err, status = {"crew-state": ("bin/fm-classify-lib.sh:3801", b"", 0),
                               "wake-drain": ("bin/fm-afk-return.sh:784", b"discard\n", 1),
                               "fleet-snapshot": ("bin/fm-fleet-view.sh:29", b"discard\n", 7)}[request["kind"]]
        capture["requests"].append(dict(id=request["id"], caller=caller, reads=reads,
                                       live=dict(stdout=blob(b"hello"), stderr=blob(err), exit_status=status, effects=[])))
    reseal(value)
    capture["workload_sha256"] = value["sha256"]
    return value, reseal(capture)


def model(pair=None):
    value, capture = pair or make()
    return accounting.bound_workload(value, capture)


def access(request, row):
    return request.access(row["operation"], row["place"], clock=row["clock"], offset=row["offset"], length=row["length"],
                          point=row["id"], at_ns=row["start_ns"])


def consume(side, owner, *, stdout=b"hello\n\n", stderr=b"discard\n", status=7, delivery=None, effects=None, commits=()):
    for context in owner.requests:
        request = old.opening(side, context)
        captured = owner._bound_requests[context["id"]]
        if side.name == "legacy":
            for row in captured["reads"][:-1]:
                access(request, row)
        else:
            # Positive optimization: reorder, merge both ranges, skip one meta
            # reread; no copied legacy I/O structure needed by the candidate.
            whole = request.access("read", place("task-0.status"), offset=0, length=len(b"working: partial\xff"))
            assert whole.data == b"working: partial\xff"
            meta = captured["reads"][0]
            request.access("read", meta["place"], length=meta["length"])
        for observation in context["observations"]:
            request.observe(operation=observation["operation"], arguments=observation["arguments"], cwd=observation["cwd"],
                            generation=observation["generation"], at_ns=observation["start_ns"])
        if side.name == "legacy":
            access(request, captured["reads"][-1])
        else:
            request.access("clock", clock="wall")
        images = []
        for effect in effects or []:
            image = dict(effect)
            expected = next((e for e in captured["live"]["effects"] if e["place"] == effect["place"]), None)
            image.setdefault("object_sha256", expected["object_sha256"] if expected is not None else None)
            images.append(image)
        request.complete(stdout=stdout, stderr=stderr, exit_status=status, effects=images, delivery=delivery, commits=commits)


class BindingChecks(unittest.TestCase):
    def reject(self, mutate, message):
        value, captured = make()
        mutate(value, captured)
        reseal(value)
        captured["workload_sha256"] = value["sha256"]
        reseal(captured)
        with self.assertRaisesRegex(ValueError, message):
            accounting.bound_workload(value, captured)

    def test_positive_publication_six_thirty_and_optimized_candidate(self):
        for count in (6, 30):
            value, captured = make(count)
            owner = model((value, captured))
            legacy, candidate = owner.side("legacy"), owner.side("candidate")
            consume(legacy, owner)
            consume(candidate, owner)
            self.assertTrue(replay.compare(legacy, candidate)["equal"])
            self.assertEqual(owner.summary()["scope"], "captured-subset-reader-only")
            self.assertFalse(owner.summary()["whole_workload_coverage"])
            self.assertFalse(owner.summary()["production_adapters"])
            self.assertEqual(owner.summary()["claimed_births_per_second_saved"], 0)

    def test_v3_bounded_directory_unadmitted_and_absent_are_different(self):
        value, captured = make()
        with self.assertRaisesRegex(ValueError, "directory inventory"):
            accounting.workload(old.reseal(dict(value, format="fm-supervision-replay.v2")))
        owner = model((value, captured))
        context = owner.requests[0]
        request = old.opening(owner.side("candidate"), context)
        with self.assertRaisesRegex(ValueError, "not read by legacy"):
            request.access("exists", place("private-unadmitted"))
        # It is invalid to claim known absence for an actually listed child.
        self.reject(lambda v, c: v["files"].append(dict(place=place("private-unadmitted"), object=None)), "child/listing")
        self.reject(lambda v, c: v["files"][0]["object"].update(content=blob(b"private-unadmitted\0")), "child/listing")

    def test_cli_versions_binding_and_unknown_fields(self):
        value, captured = make()
        tmp = Path(os.environ["FM_ACCOUNTING_TEST_TMP"])
        vp, cp = tmp / "v3.json", tmp / "binding.json"
        vp.write_text(json.dumps(value))
        cp.write_text(json.dumps(captured))
        result = subprocess.run([sys.executable, str(old.ROOT / "bin/fm-supervision-accounting.py"),
                                 "validate-workload", str(vp), "--bindings", str(cp)], capture_output=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(json.loads(result.stdout)["capture_bindings"])
        unbound = accounting.workload(value)
        with self.assertRaisesRegex(ValueError, "bindings required"):
            unbound.side("legacy")
        self.reject(lambda v, c: c.update(extra=True), "unknown field")
        self.reject(lambda v, c: c["requests"][0]["reads"][0].update(offset=True), "wrong type")
        self.reject(lambda v, c: c.update(code_ref="3" * 40), "code pin")
        self.reject(lambda v, c: c.update(cutoff_ns=59_000_000_000), "window")
        self.reject(lambda v, c: c["requests"].reverse(), "inventory")
        self.reject(lambda v, c: c["requests"][0].update(caller="harness"), "projection")
        self.reject(lambda v, c: c["requests"][0]["reads"][0].update(place=place("unadmitted")), "unadmitted")
        self.reject(lambda v, c: c["requests"][0]["reads"][0].update(version_sha256="0" * 64), "version")
        self.reject(lambda v, c: c["requests"][0]["reads"][0].update(result=blob(b"invented")), "result")
        self.reject(lambda v, c: c["requests"][0]["reads"][0].update(end_ns=500), "interval")
        self.reject(lambda v, c: c["requests"][0]["reads"][1].update(id="meta-first"), "duplicate logical")

    def test_outer_binding_and_workload_seals_independent(self):
        value, captured = make()
        captured["admission_sha256"] = "3" * 64
        with self.assertRaisesRegex(ValueError, "binding seal"):
            model((value, captured))
        reseal(captured)
        captured["workload_sha256"] = "0" * 64
        reseal(captured)
        with self.assertRaisesRegex(ValueError, "workload mismatch"):
            model((value, captured))

    def test_legacy_schedule_missing_extra_reordered_and_poisoned(self):
        for kind in ("extra", "order", "unconsumed", "object", "clock"):
            owner = model()
            side = owner.side("legacy")
            request = old.opening(side, owner.requests[0])
            rows = owner._bound_requests["r0"]["reads"]
            with self.assertRaises(ValueError):
                if kind == "order":
                    access(request, rows[1])
                elif kind == "object":
                    request.object(place("task-0.meta"), 10)
                elif kind == "clock":
                    request.wall_ns(10)
                elif kind == "extra":
                    request.access("exists", place("task-0.meta"), point="meta-first", at_ns=11)
                else:
                    request.complete(stdout=b"hello\n", stderr=b"", exit_status=0, effects=[])
            with self.assertRaises(ValueError):
                side.finish()

    def test_candidate_range_instance_and_changed_version_rules(self):
        value, captured = make()
        value["requests"] = value["requests"][:1]
        captured["requests"] = captured["requests"][:1]
        before = next(r["object"] for r in value["files"] if r["place"] == place("task-0.meta"))
        replacement = obj(b"new metadata", identity="new-meta")
        value["changes"].insert(0, dict(seq=1, at_ns=12, place=place("task-0.meta"),
                                       before_sha256=replay.object_seal(before), object=replacement))
        value["changes"][1]["seq"] = 2
        row = captured["requests"][0]["reads"][1]
        row.update(start_ns=12, end_ns=12, length=len(b"new metadata"),
                   version_sha256=replay.object_seal(replacement), result=blob(b"new metadata"))
        reseal(value)
        captured["workload_sha256"] = value["sha256"]
        reseal(captured)
        for point, expected in (("meta-first", replay.blob(before["content"])), ("meta-again", b"new metadata")):
            owner = model((value, captured))
            request = old.opening(owner.side("candidate"), owner.requests[0])
            result = request.access("read", place("task-0.meta"), length=len(expected), point=point)
            self.assertEqual(result.data, expected)
        owner = model((value, captured))
        request = old.opening(owner.side("candidate"), owner.requests[0])
        with self.assertRaisesRegex(ValueError, "requires logical"):
            request.access("read", place("task-0.meta"), length=1)
        for args in (("read", place("task-1.status"), dict(length=1)),
                     ("stat", place("task-0.meta"), {}),
                     ("read", place("task-0.status"), dict(length=100)),
                     ("read", place("task-0.meta"), dict(length=1, at_ns=11))):
            owner = model()
            request = old.opening(owner.side("candidate"), owner.requests[0])
            with self.assertRaises(ValueError):
                request.access(args[0], args[1], **args[2])

    def test_live_kept_hidden_input_refuses_discarded_input_can_pass(self):
        owner = model()
        side = owner.side("legacy")
        with self.assertRaisesRegex(ValueError, "live fidelity"):
            consume(side, owner, stdout=b"hidden kept difference\n")
        with self.assertRaises(ValueError):
            side.finish()
        # Make every selected site a crew substitution to isolate discarded data.
        value, captured = make()
        value["requests"] = value["requests"][:1]
        captured["requests"] = captured["requests"][:1]
        reseal(value)
        captured["workload_sha256"] = value["sha256"]
        reseal(captured)
        owner = model((value, captured))
        sides = [owner.side(n) for n in ("legacy", "candidate")]
        for side in sides:
            consume(side, owner, stderr=b"unseen hidden input", stdout=b"hello\n\n\n", status=9)
        self.assertTrue(replay.compare(*sides)["equal"])
        # The unprojected comparison still catches different discarded bytes.
        owner = model((value, captured))
        sides = [owner.side(n) for n in ("legacy", "candidate")]
        consume(sides[0], owner)
        consume(sides[1], owner, stderr=b"candidate differs")
        with self.assertRaisesRegex(ValueError, "whole adapter"):
            replay.compare(*sides)

    def test_projection_registry_identity_first_merge_and_masked_status(self):
        result = dict(stdout=b"first\nsecond\n\n", stderr=b"err\n", exit_status=7)
        self.assertEqual(bindings.project("bin/fm-fleet-snapshot.sh:362", result, None), (b"first", b"", 0))
        self.assertEqual(bindings.project("bin/fm-home-summary-refresh.sh:248", result, None),
                         (result["stdout"], result["stderr"], 7))
        self.assertEqual(bindings.project("bin/fm-contributions.sh:184", result, None), (result["stdout"], result["stderr"], 7))
        chunks = [dict(stream="stdout", content=b"first\n"), dict(stream="stderr", content=b"err\n"),
                  dict(stream="stdout", content=b"second\n\n")]
        self.assertEqual(bindings.project("bin/fm-session-start.sh:944", result, chunks), (b"first\nerr\nsecond", b"", 7))
        with self.assertRaisesRegex(ValueError, "unavailable"):
            bindings.project("bin/fm-session-start.sh:944", result, None)
        with self.assertRaisesRegex(ValueError, "bytes mismatch"):
            bindings.project("bin/fm-session-start.sh:944", result, chunks[:-1])
        nul = dict(result, stdout=b"a\0b\n\n")
        self.assertEqual(bindings.project("bin/fm-classify-lib.sh:3801", nul, None), (b"ab", b"", 0))

    def test_passive_omission_still_refuses_both_sides(self):
        for name in ("legacy", "candidate"):
            owner = model()
            side = owner.side(name)
            request = old.opening(side, owner.requests[0])
            for row in owner._bound_requests["r0"]["reads"]:
                if name == "legacy":
                    access(request, row)
            with self.assertRaisesRegex(ValueError, "unconsumed passive"):
                request.complete(stdout=b"hello\n", stderr=b"discard\n", exit_status=7, effects=[])
            with self.assertRaises(ValueError):
                side.finish()

    def test_stat_list_absence_error_and_changed_clock_bindings(self):
        value, captured = make()
        value["files"][1]["object"]["mode"] = 0
        for entry in captured["requests"]:
            at = entry["reads"][-2]["end_ns"]
            for ident, op, path in (("stat-meta", "stat", "task-0.meta"), ("listing", "list", ""),
                                    ("missing", "exists", "absent"), ("permission", "read", "cursor")):
                source = next(x["object"] for x in value["files"] if x["place"] == place(path))
                expected = {"stat": replay.canonical({k: source[k] for k in ("identity", "kind", "mode", "mtime_ns")})
                            if op == "stat" else b"", "list": replay.blob(source["content"]) if op == "list" else b"",
                            "exists": replay.canonical(False), "read": b""}[op]
                row = dict(id=ident, operation=op, place=place(path), clock="", offset=0,
                           length=1 if op == "read" else 0, start_ns=at, end_ns=at,
                           version_sha256=replay.object_seal(source), result=blob(expected),
                           error="EACCES" if op == "read" else "")
                entry["reads"].insert(-1, row)
        reseal(value)
        captured["workload_sha256"] = value["sha256"]
        reseal(captured)
        owner = model((value, captured))
        request = old.opening(owner.side("candidate"), owner.requests[0])
        self.assertEqual(json.loads(request.access("exists", place("absent")).data), False)
        self.assertIn(b"private-unadmitted\0", request.access("list", place()).data)
        self.assertEqual(json.loads(request.access("stat", place("task-0.meta")).data)["kind"], "regular")
        self.assertEqual(request.access("read", place("cursor"), length=1).error, "EACCES")
        value, captured = make()
        clock = copy.deepcopy(captured["requests"][0]["reads"][-1])
        clock.update(id="wall-later", start_ns=22, end_ns=22, result=blob(replay.canonical(1_000_022)))
        captured["requests"][0]["reads"].append(clock)
        reseal(captured)
        owner = model((value, captured))
        request = old.opening(owner.side("candidate"), owner.requests[0])
        self.assertEqual(json.loads(request.access("clock", clock="wall", point="wall").data), 1_000_021)
        with self.assertRaisesRegex(ValueError, "requires logical"):
            request.access("clock", clock="wall")

    def test_owner_effect_commit_and_full_live_effect_fidelity(self):
        value, captured = make()
        value["requests"] = value["requests"][:1]
        captured["requests"] = captured["requests"][:1]
        before = value["files"][1]["object"]
        value["changes"].insert(0, dict(seq=1, at_ns=50, place=place("cursor"),
                                       before_sha256=replay.object_seal(before), object=obj(b"1\n")))
        value["changes"][1]["seq"] = 2
        captured["requests"][0]["live"]["effects"] = [dict(place=place("cursor"), content=blob(b"1\n"),
                                                           object_sha256=replay.object_seal(value["changes"][0]["object"]),
                                                           change_seq=1, commit_id="owner-commit-1")]
        reseal(value)
        captured["workload_sha256"] = value["sha256"]
        reseal(captured)
        owner = model((value, captured))
        sides = [owner.side(n) for n in ("legacy", "candidate")]
        for side in sides:
            consume(side, owner, effects=[dict(place=place("cursor"), content=b"1\n")], commits=["owner-commit-1"])
        self.assertTrue(replay.compare(*sides)["equal"])
        owner = model((value, captured))
        with self.assertRaisesRegex(ValueError, "live fidelity"):
            consume(owner.side("legacy"), owner, effects=[dict(place=place("cursor"), content=b"wrong after-image")],
                    commits=["owner-commit-1"])
        owner = model((value, captured))
        with self.assertRaisesRegex(ValueError, "invalid owner commit inventory"):
            consume(owner.side("candidate"), owner, commits=["wrong"])
        corrupt = copy.deepcopy(captured)
        corrupt["requests"][0]["live"]["effects"][0]["content"] = blob(b"not the committed bytes")
        with self.assertRaisesRegex(ValueError, "commit/image"):
            model((value, reseal(corrupt)))

    def test_deletion_and_directory_effect_images_are_not_empty_files(self):
        value, captured = make()
        value["requests"] = value["requests"][:1]
        captured["requests"] = captured["requests"][:1]
        root = copy.deepcopy(value["files"][0]["object"])
        after = copy.deepcopy(root)
        after["content"] = blob(replay.blob(root["content"]).replace(b"cursor\0", b""))
        before = value["files"][1]["object"]
        value["changes"] = [dict(seq=1, at_ns=50, place=place("cursor"), before_sha256=replay.object_seal(before), object=None),
                            dict(seq=2, at_ns=50, place=place(), before_sha256=replay.object_seal(root), object=after)]
        captured["requests"][0]["live"]["effects"] = [
            dict(place=place("cursor"), content=None, object_sha256=None, change_seq=1, commit_id="atomic-delete"),
            dict(place=place(), content=after["content"], object_sha256=replay.object_seal(after),
                 change_seq=2, commit_id="atomic-delete")]
        reseal(value)
        captured["workload_sha256"] = value["sha256"]
        reseal(captured)
        owner = model((value, captured))
        sides = [owner.side(n) for n in ("legacy", "candidate")]
        for side in sides:
            consume(side, owner, effects=[dict(place=place("cursor"), content=None),
                                           dict(place=place(), content=replay.blob(after["content"]))],
                    commits=["atomic-delete", "atomic-delete"])
        self.assertTrue(replay.compare(*sides)["equal"])
        owner = model((value, captured))
        with self.assertRaisesRegex(ValueError, "live fidelity"):
            consume(owner.side("legacy"), owner, effects=[dict(place=place("cursor"), content=b""),
                                                          dict(place=place(), content=replay.blob(after["content"]))],
                    commits=["atomic-delete", "atomic-delete"])

    def test_merged_public_fidelity_keeps_byte_order_not_chunk_sizes(self):
        value, captured = make()
        value["requests"] = value["requests"][:1]
        value["requests"][0].update(kind="wake-drain", task="")
        captured["requests"] = captured["requests"][:1]
        captured["requests"][0].update(caller="bin/fm-session-start.sh:944",
                                       live=dict(stdout=blob(b"hello\ndiscard"), stderr=blob(b""), exit_status=7, effects=[]))
        reseal(value)
        captured["workload_sha256"] = value["sha256"]
        reseal(captured)
        legacy_delivery = [dict(stream="stdout", content=b"hello\n"), dict(stream="stderr", content=b"discard\n"),
                           dict(stream="stdout", content=b"\n")]
        candidate_delivery = [dict(stream="stdout", content=b"he"), dict(stream="stdout", content=b"llo\n"),
                              dict(stream="stderr", content=b"discard\n"), dict(stream="stdout", content=b"\n")]
        owner = model((value, captured))
        sides = [owner.side(n) for n in ("legacy", "candidate")]
        consume(sides[0], owner, delivery=legacy_delivery)
        consume(sides[1], owner, delivery=candidate_delivery)
        self.assertTrue(replay.compare(*sides)["equal"])
        owner = model((value, captured))
        with self.assertRaisesRegex(ValueError, "unavailable"):
            consume(owner.side("legacy"), owner)
        owner = model((value, captured))
        sides = [owner.side(n) for n in ("legacy", "candidate")]
        consume(sides[0], owner, delivery=legacy_delivery)
        consume(sides[1], owner, delivery=[legacy_delivery[1], legacy_delivery[0], legacy_delivery[2]])
        with self.assertRaisesRegex(ValueError, "whole adapter"):
            replay.compare(*sides)

    def test_healthy_empty_bound_workload(self):
        value, captured = make()
        value.update(files=[], changes=[], requests=[])
        captured["requests"] = []
        reseal(value)
        captured["workload_sha256"] = value["sha256"]
        owner = model((value, reseal(captured)))
        self.assertEqual(replay.compare(owner.side("legacy"), owner.side("candidate"))["requests"], 0)

    def test_binding_guards_independent_counterfactuals(self):
        cases = [("binding code pin mismatch", lambda v, c: c.update(code_ref="3" * 40)),
                 ("binding selection window mismatch", lambda v, c: c.update(cutoff_ns=59_000_000_000)),
                 ("binding request inventory mismatch", lambda v, c: c["requests"][0].update(id="unbound")),
                 ("unknown or foreign caller projection", lambda v, c: c["requests"][0].update(caller="harness")),
                 ("duplicate logical read point", lambda v, c: c["requests"][0]["reads"][1].update(id="meta-first")),
                 ("scheduled result mismatch", lambda v, c: c["requests"][0]["reads"][0].update(result=blob(b"wrong")))]
        original = bindings.require
        for message, mutate in cases:
            with self.subTest(guard=message):
                value, captured = make()
                mutate(value, captured)
                reseal(captured)
                def oracle():
                    with self.assertRaises(ValueError):
                        model((value, captured))
                oracle()
                def removed(condition, reason):
                    if reason != message:
                        original(condition, reason)
                with patch.object(bindings, "require", removed):
                    with self.assertRaises(AssertionError):
                        oracle()
        # Missing legacy consumption has its own otherwise-valid public case.
        def check_missing(owner):
            side = owner.side("legacy")
            for context in owner.requests:
                request = old.opening(side, context)
                for observation in context["observations"]:
                    request.observe(operation=observation["operation"], arguments=observation["arguments"], cwd=observation["cwd"],
                                    generation=observation["generation"], at_ns=observation["start_ns"])
                request.complete(stdout=b"hello\n\n", stderr=b"discard\n", exit_status=7, effects=[])
        with self.assertRaisesRegex(ValueError, "unconsumed legacy"):
            check_missing(model())
        def removed(condition, reason):
            if reason != "unconsumed legacy reads":
                original(condition, reason)
        with patch.object(bindings, "require", removed):
            check_missing(model())

    def test_other_binding_guards_have_independent_refusal_oracles(self):
        cases = [
            ("binding seal mismatch", lambda v, c: c.update(admission_sha256="3" * 64), False),
            ("binding workload mismatch", lambda v, c: c.update(workload_sha256="0" * 64), True),
            ("read version mismatch", lambda v, c: c["requests"][0]["reads"][0].update(version_sha256="0" * 64), True),
            ("file read has clock selector", lambda v, c: c["requests"][0]["reads"][0].update(clock="wall"), True),
            ("invalid clock binding", lambda v, c: c["requests"][0]["reads"][-1].update(version_sha256="0" * 64), True),
            ("range on non-read operation", lambda v, c: c["requests"][0]["reads"][-1].update(offset=1), True),
            ("scheduled range bound", lambda v, c: c["requests"][0]["reads"][0].update(offset=replay.MAX_FILE, length=1, result=blob(b"")), True),
            ("read interval/order mismatch", lambda v, c: c["requests"][0]["reads"][1].update(start_ns=10), True),
        ]
        original = bindings.require
        for reason, mutate, update_seal in cases:
            with self.subTest(guard=reason):
                value, captured = make()
                mutate(value, captured)
                if update_seal:
                    reseal(captured)
                def oracle():
                    with self.assertRaisesRegex(ValueError, reason):
                        model((value, captured))
                oracle()
                def removed(condition, message):
                    if message != reason:
                        original(condition, message)
                with patch.object(bindings, "require", removed):
                    with self.assertRaises(AssertionError):
                        oracle()
        with patch.object(bindings, "MAX_CAPTURE_READS", 1):
            with self.assertRaisesRegex(ValueError, "read count"):
                model()
            def removed(condition, message):
                if message != "capture read count bound":
                    original(condition, message)
            with patch.object(bindings, "require", removed):
                model()
        for reason, action in (
                ("duplicate or late capture binding", lambda owner, c: owner.bind(c)),
                ("legacy read schedule mismatch", lambda owner, c: old.opening(owner.side("legacy"), owner.requests[0]).access(
                    "read", place("task-0.meta"), length=c["requests"][0]["reads"][0]["length"], point="wrong", at_ns=11)),
                ("candidate cannot choose a read time", lambda owner, c: old.opening(owner.side("candidate"), owner.requests[0]).access(
                    "read", place("task-0.meta"), length=1, at_ns=11)),
                ("candidate range exceeds captured reads", lambda owner, c: old.opening(owner.side("candidate"), owner.requests[0]).access(
                    "read", place("task-0.status"), length=100)),
                ("legacy caller-visible live fidelity mismatch", lambda owner, c: consume(owner.side("legacy"), owner, stdout=b"wrong"))):
            with self.subTest(guard=reason):
                def oracle():
                    value, c = make()
                    owner = model((value, c))
                    with self.assertRaisesRegex(ValueError, reason):
                        action(owner, c)
                oracle()
                def removed(condition, message):
                    if message != reason:
                        original(condition, message)
                with patch.object(bindings, "require", removed):
                    with self.assertRaises(AssertionError):
                        oracle()

    def test_no_live_io_after_factories_and_immutable_input_detachment(self):
        value, captured = make()
        owner = model((value, captured))
        captured["requests"][0]["reads"].clear()
        value["files"].clear()
        with patch("builtins.open", side_effect=AssertionError("live file")), \
             patch("os.open", side_effect=AssertionError("live file")), \
             patch("subprocess.Popen", side_effect=AssertionError("command")), \
             patch("time.time_ns", side_effect=AssertionError("clock")):
            sides = [owner.side(n) for n in ("legacy", "candidate")]
            for side in sides:
                consume(side, owner)
            self.assertTrue(replay.compare(*sides)["equal"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
