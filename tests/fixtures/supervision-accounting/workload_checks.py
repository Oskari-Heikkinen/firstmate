"""CI-only v2 reader/dual-consumer controls; no production replay or profiling.

The supplied test adapters exercise the contract with complete synthetic local
inventories and all three P1 request families. They are NOT the production shell
and resident adapters, and their equality is not P1 performance acceptance.
"""
import base64
import copy
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import unittest
from unittest.mock import patch

ROOT = Path(os.environ["FM_ACCOUNTING_TEST_ROOT"])
sys.path.insert(0, str(ROOT / "bin"))
sys.path.insert(0, str(Path(__file__).parent))
import fm_supervision_replay as replay
import fixture

spec = importlib.util.spec_from_file_location("accounting_workload", ROOT / "bin/fm-supervision-accounting.py")
accounting = importlib.util.module_from_spec(spec)
spec.loader.exec_module(accounting)


def blob(raw):
    return {"base64": base64.b64encode(raw).decode("ascii"), "sha256": hashlib.sha256(raw).hexdigest()}


def obj(raw=b"", identity="i1", kind="regular", mode=0o600, error=""):
    return dict(identity=identity, kind=kind, mode=mode, mtime_ns=0, error=error, content=blob(raw))


def place(path="", root="state", task="", home="fixture"):
    return dict(home=home, root=root, task=task, path=path)


def reseal(value):
    value["sha256"] = replay.seal({k: v for k, v in value.items() if k != "sha256"})
    return value


def make(count=6):
    old = fixture.make(count)
    files = []
    def add(location, value):
        files.append(dict(place=location, object=value))
    names = ["cursor"] + ["task-" + str(i) + suffix for i in range(count) for suffix in (".meta", ".status")]
    add(place(), obj(b"".join(name.encode() + b"\0" for name in names), kind="directory"))
    add(place("cursor"), obj(b"0\n"))
    add(place("absent"), None)
    for root in ("config", "data"):
        add(place(root=root), obj(kind="directory"))
    for i in range(count):
        task = "task-" + str(i)
        add(place(task + ".meta"), obj(("kind=ship\nspawn_gen=g1\nworktree=/fixture/" + task + "\n").encode()))
        add(place(task + ".status"), obj(b"working: partial\xff", identity="status-" + task))
        add(place(root="worktree", task=task), obj(b"HEAD\0", kind="directory"))
        add(place("HEAD", "worktree", task), obj(b"a" * 40 + b"\n"))
    requests = []
    for index, kind in enumerate(("crew-state", "wake-drain", "fleet-snapshot", "crew-state")):
        start = index * 100 + 10
        task = "task-0" if kind == "crew-state" else ""
        requests.append(dict(id="r" + str(index), home="fixture", task=task, generation="g1", kind=kind,
                             arguments=["--captured"], actor=dict(name="main", token="", claim=blob(b"")),
                             start_ns=start, end_ns=start + 90, observations=[
                                 dict(id="o" + str(index), operation="git", arguments=["rev-parse", "HEAD"],
                                      cwd=place(root="worktree", task="task-0"), generation="g1",
                                      start_ns=start + 5, end_ns=start + 10, exit_status=0,
                                      stdout=blob((b"a" if index < 3 else b"b") * 40 + b"\n"), stderr=blob(b""))]))
    before = next(row["object"] for row in files if row["place"] == place("HEAD", "worktree", "task-0"))
    value = dict(format="fm-supervision-replay.v2", synthetic=True, label="synthetic-whole-reader-workload",
                 manifest=old["manifest"], trace=old["trace"],
                 clock=dict(machine="ci-fixture", boot_id="00000000-0000-0000-0000-000000000001",
                            namespace="synthetic-ci", monotonic_start_ns=0,
                            monotonic_end_ns=60_000_000_000, wall_start_ns=1_000_000),
                 files=files, changes=[dict(seq=1, at_ns=300, place=place("HEAD", "worktree", "task-0"),
                                           before_sha256=replay.object_seal(before), object=obj(b"b" * 40 + b"\n"))],
                 requests=requests)
    return reseal(value)


def duplicate_directory(value):
    directory = value["files"][0]["object"]
    # Preserve the full valid child inventory and final NUL; only uniqueness
    # differs, so neither partial-list nor topology refusal masks this guard.
    directory["content"] = blob(replay.blob(directory["content"]) + b"cursor\0")


def opening(side, row, **overrides):
    values = {key: row[key] for key in ("home", "task", "generation", "kind", "arguments", "actor")}
    values.update(overrides)
    return side.open(row["id"], **values)


def consume(request, row, *, suffix=b"", omit=False, extra=False, effect=b"1\n"):
    initial = request.object(place("task-0.status"), row["start_ns"])
    request.object(place("absent"), row["start_ns"])
    out = initial.read()
    if not omit:
        for item in row["observations"]:
            result = request.observe(operation=item["operation"], arguments=item["arguments"], cwd=item["cwd"],
                                     generation=item["generation"], at_ns=item["start_ns"])
            out += result.stdout + result.stderr + str(result.exit_status).encode()
    if extra:
        request.observe(operation="git", arguments=[], cwd=place(), generation="g1", at_ns=row["end_ns"])
    request.complete(stdout=out + suffix, stderr=b"", exit_status=0,
                     effects=[dict(place=place("cursor"), content=effect)])
    return out


class WorkloadChecks(unittest.TestCase):
    def rejected(self, mutate, message):
        value = make()
        mutate(value)
        reseal(value)
        with self.assertRaisesRegex(ValueError, message):
            accounting.workload(value)

    def test_six_thirty_and_both_supplied_adapters_consume_identical_schedule(self):
        for count in (6, 30):
            value = make(count)
            pinned = copy.deepcopy(value)
            model = accounting.workload(value)
            # Mutating the input or returned request contexts cannot change pins.
            value["requests"][0]["arguments"].append("foreign")
            contexts = model.requests
            contexts[0]["arguments"].append("foreign")
            outputs = {}
            for name in ("legacy", "candidate"):
                side = model.side(name)
                outputs[name] = [consume(opening(side, row), row) for row in model.requests]
                outputs[name + "-side"] = side
            self.assertNotEqual(outputs["legacy"][0], outputs["legacy"][-1])
            # Fresh HEAD changes without ANY status-byte change.
            self.assertEqual(outputs["legacy"][0][:16], outputs["legacy"][-1][:16])
            result = replay.compare(outputs["legacy-side"], outputs["candidate-side"])
            self.assertTrue(result["equal"])
            self.assertEqual(result["sha256"], pinned["sha256"])
            self.assertEqual(result["claimed_births_per_second_saved"], 0)
            self.assertFalse(model.summary()["production_adapters"])

    def test_healthy_empty_workload_is_not_an_alarm_or_performance_claim(self):
        value = make()
        value.update(requests=[], changes=[], files=[])
        model = accounting.workload(reseal(value))
        result = replay.compare(model.side("legacy"), model.side("candidate"))
        self.assertEqual(result["requests"], 0)
        self.assertEqual(result["claimed_births_per_second_saved"], 0)
        self.assertEqual(result["b0_status"], "pending-reviewed-real-capture")

    def test_cli_v2_and_unchanged_v1_reader_and_insufficient_measurement(self):
        tmp = Path(os.environ["FM_ACCOUNTING_TEST_TMP"])
        for version, value in ((1, fixture.make(6)), (2, make())):
            path = tmp / ("reader-v" + str(version) + ".json")
            path.write_text(json.dumps(value))
            command = [sys.executable, str(ROOT / "bin/fm-supervision-accounting.py")]
            result = subprocess.run(command + ["validate-workload", str(path)], capture_output=True, timeout=30)
            if version == 1:
                self.assertEqual(result.returncode, 2, result.stderr)
                self.assertIn(b"insufficient for P1", result.stderr)
                self.assertEqual(result.stdout, b"")
                legacy = subprocess.run(command + ["replay", str(path)], capture_output=True, timeout=30)
                self.assertEqual(legacy.returncode, 0, legacy.stderr)
                self.assertEqual(json.loads(legacy.stdout)["sealed_records"], 3)
            else:
                self.assertEqual(result.returncode, 0, result.stderr)
                report = json.loads(result.stdout)
                self.assertEqual(report["scope"], "sealed-workload-reader-only")
                self.assertEqual(report["b0_status"], "pending-reviewed-real-capture")

    def test_envelope_and_blob_seals_are_independent(self):
        value = make()
        value["label"] += "changed"
        with self.assertRaisesRegex(ValueError, "envelope seal"):
            accounting.workload(value)
        self.rejected(lambda v: v["files"][1]["object"]["content"].update(base64="eA=="), "blob")
        self.rejected(lambda v: v["requests"][0]["observations"][0]["stderr"].update(base64="AA!"), "Only base64 data")

    def test_closed_shapes_versions_types_paths_and_bounds(self):
        cases = [lambda v: v.update(format="fm-supervision-replay.v99"),
                 lambda v: v.update(unexpected=True),
                 lambda v: v["clock"].update(monotonic_start_ns=True),
                 lambda v: v["clock"].update(machine="another-machine"),
                 lambda v: v["clock"].update(boot_id="unknown"),
                 lambda v: v["files"][0]["place"].update(path="../outside"),
                 lambda v: v["files"][0]["place"].update(path="/outside"),
                 lambda v: v["files"][0]["place"].update(path="a//b"),
                 lambda v: v["files"][0]["place"].update(path="a\\b"),
                 lambda v: v["files"][0]["place"].update(home="foreign"),
                 lambda v: v["files"][0]["place"].update(task="task-0"),
                 lambda v: v["requests"][0].update(task="unknown"),
                 lambda v: v["requests"][1].update(task="task-0"),
                 lambda v: v["requests"][0]["observations"][0].update(operation="exec"),
                 lambda v: v["requests"][0]["actor"].update(name="branch"),
                 lambda v: v["files"][1]["object"].update(mode=True),
                 lambda v: v["requests"][0].update(start_ns=-1),
                 lambda v: v["requests"][0]["observations"][0].update(exit_status=256)]
        messages = ["unsupported format/value", "unknown field", "wrong type", "place home/root/machine",
                    "pattern", "noncanonical relative path", "noncanonical relative path", "noncanonical relative path",
                    "invalid relative path", "place home/root/machine", "place task binding", "request task/home binding",
                    "request task/home binding", "unadmitted passive", "branch actor lacks claim token", "wrong type",
                    "numeric bound", "numeric bound"]
        self.assertEqual(len(cases), len(messages))
        for index, (mutate, message) in enumerate(zip(cases, messages)):
            with self.subTest(index=index):
                self.rejected(mutate, message)

    def test_clock_order_preimages_duplicates_and_inventory_completeness(self):
        cases = [lambda v: v["clock"].update(monotonic_end_ns=1),
                 lambda v: v.update(synthetic=False),
                 lambda v: v["changes"][0].update(seq=2),
                 lambda v: v["changes"][0].update(before_sha256="0" * 64),
                 lambda v: v["changes"][0].update(at_ns=61_000_000_000),
                 lambda v: v["requests"][1].update(id="r0"),
                 lambda v: v["requests"][1].update(start_ns=1),
                 lambda v: v["requests"][0]["observations"][0].update(start_ns=0),
                 lambda v: v["requests"][1]["observations"][0].update(id="o0"),
                 lambda v: v["requests"][0]["observations"][0].update(end_ns=101),
                 lambda v: v["files"].append(copy.deepcopy(v["files"][0])),
                 lambda v: v["files"].pop(1),
                 lambda v: v["files"][0]["object"].update(content=blob(b"cursor"))]
        messages = ["clock/trace interval mismatch", "synthetic provenance mismatch", "change sequence/clock",
                    "change preimage mismatch", "change sequence/clock", "duplicate request id", "request order/interval",
                    "observation interval/order", "duplicate observation id", "observation interval/order",
                    "duplicate initial file", "directory inventory/file mismatch", "partial directory inventory"]
        self.assertEqual(len(cases), len(messages))
        for index, (mutate, message) in enumerate(zip(cases, messages)):
            with self.subTest(index=index):
                self.rejected(mutate, message)

    def test_missing_empty_partial_binary_and_hostile_file_objects(self):
        for kind, mode, error, expected in (("regular", 0o600, "", None),
                                            ("regular", 0, "", PermissionError),
                                            ("regular", 0o600, "EIO", OSError),
                                            ("directory", 0o700, "", IsADirectoryError),
                                            ("symlink", 0o600, "", ValueError),
                                            ("fifo", 0o600, "", ValueError)):
            value = make()
            value["files"][1]["object"] = obj(b"" if kind == "directory" else b"\0\xffpartial", kind=kind, mode=mode, error=error)
            model = accounting.workload(reseal(value))
            row = model.requests[0]
            request = opening(model.side("legacy"), row)
            self.assertIsNone(request.object(place("absent"), row["start_ns"]))
            captured = request.object(place("cursor"), row["start_ns"])
            if expected:
                with self.assertRaises(expected):
                    captured.read()
            else:
                self.assertEqual(captured.read(), b"\0\xffpartial")
            with self.assertRaisesRegex(ValueError, "uncaptured"):
                request.object(place("not-recorded"), row["start_ns"])

    def test_append_rotation_truncation_deletion_and_same_time_changes(self):
        value = make()
        original = value["files"][1]["object"]
        states = [obj(b"0\nnew", "i1"), obj(b"new", "rotated"), obj(b"", "rotated"), None]
        changes = []
        for index, new in enumerate(states):
            changes.append(dict(seq=index + 1, at_ns=20 + index * 10, place=place("cursor"),
                                before_sha256=replay.object_seal(original), object=new))
            original = new
        # Deletion updates its directory atomically at the same time, before reads.
        directory = value["files"][0]["object"]
        changed_directory = copy.deepcopy(directory)
        changed_directory["content"] = blob(replay.blob(directory["content"]).replace(b"cursor\0", b""))
        changes.append(dict(seq=5, at_ns=50, place=place(), before_sha256=replay.object_seal(directory), object=changed_directory))
        value["changes"] = changes
        model = accounting.workload(reseal(value))
        request = opening(model.side("legacy"), model.requests[0])
        self.assertEqual(request.object(place("cursor"), 19).read(), b"0\n")
        self.assertEqual(request.object(place("cursor"), 20).read(), b"0\nnew")
        self.assertEqual(request.object(place("cursor"), 30).identity, "rotated")
        self.assertEqual(request.object(place("cursor"), 40).read(), b"")
        self.assertIsNone(request.object(place("cursor"), 50))
        self.assertEqual(request.wall_ns(51), 1_000_051)

    def test_both_sides_refuse_missing_extra_wrong_order_and_swallowed_errors(self):
        for side_name in ("legacy", "candidate"):
            for mutation in ("omit", "extra", "binding", "clock", "actor", "request-order", "unfinished"):
                with self.subTest(side=side_name, mutation=mutation):
                    model = accounting.workload(make())
                    side = model.side(side_name)
                    row = model.requests[0]
                    with self.assertRaises(ValueError):
                        if mutation == "request-order":
                            opening(side, model.requests[1])
                        elif mutation == "actor":
                            opening(side, row, actor=dict(row["actor"], token="wrong"))
                        elif mutation == "unfinished":
                            side.finish()
                        else:
                            request = opening(side, row)
                            if mutation == "binding":
                                item = row["observations"][0]
                                request.observe(operation="git", arguments=["status"], cwd=item["cwd"], generation="g1", at_ns=item["start_ns"])
                            elif mutation == "clock":
                                request.wall_ns(row["start_ns"] - 1)
                            else:
                                consume(request, row, omit=mutation == "omit", extra=mutation == "extra")
                    with self.assertRaises(ValueError):
                        side.finish()

    def test_whole_output_stderr_status_effects_and_workload_binding(self):
        for what in ("stdout", "stderr", "exit_status", "effects"):
            model = accounting.workload(make())
            sides = [model.side(name) for name in ("legacy", "candidate")]
            for index, side in enumerate(sides):
                for row in model.requests:
                    request = opening(side, row)
                    item = row["observations"][0]
                    request.observe(operation=item["operation"], arguments=item["arguments"], cwd=item["cwd"], generation=item["generation"], at_ns=item["start_ns"])
                    result = dict(stdout=b"whole\xff", stderr=b"", exit_status=0, effects=[dict(place=place("cursor"), content=b"1\n")])
                    if index:
                        result[what] = {"stdout": b"truncated", "stderr": b"diagnostic", "exit_status": 2,
                                        "effects": [dict(place=place("cursor"), content=b"2\n")]}[what]
                    request.complete(**result)
            with self.assertRaisesRegex(ValueError, "whole adapter"):
                replay.compare(*sides)
        a, b = accounting.workload(make()), accounting.workload(make())
        with self.assertRaisesRegex(ValueError, "workload/side"):
            replay.compare(a.side("legacy"), b.side("candidate"))

    def test_passive_vocabulary_accepts_only_fixed_reads(self):
        allowed = [("git", ["rev-parse", "HEAD"]),
                   ("git", ["symbolic-ref", "--quiet", "--short", "HEAD"]),
                   ("git", ["rev-parse", "--verify", "--quiet", "a" * 40 + "^{commit}"]),
                   ("git", ["merge-base", "--is-ancestor", "a" * 40, "b" * 40]),
                   ("no-mistakes", ["axi"]), ("no-mistakes", ["axi", "status"]),
                   ("no-mistakes", ["daemon", "status"]), ("no-mistakes", ["runs", "--limit", "200"]),
                   ("no-mistakes", ["axi", "status", "--run", "r1"]),
                   ("no-mistakes", ["axi", "logs", "--step", "ci", "--run", "r1", "--full"]),
                   ("backend", ["task-0"]), ("snapshot-endpoint", ["task-0"]),
                   ("saved-custody", ["task-0"]), ("done-proof", ["task-0", "done: text"]),
                   ("forge", ["task-0", "https://example.invalid/pr/1"])]
        for operation, args in allowed:
            value = make()
            value["requests"][0]["observations"][0].update(operation=operation, arguments=args)
            accounting.workload(reseal(value))
        for operation, args in (("exec", ["sh", "-c", "true"]), ("git", ["reset", "--hard"]),
                                ("git", ["-c", "core.hooksPath=evil", "rev-parse", "HEAD"]),
                                ("no-mistakes", ["daemon", "restart"]), ("backend", ["task-0", "kill"]),
                                ("forge", ["task-other", "url"]), ("saved-custody", ["../other"]),
                                ("snapshot-endpoint", []), ("snapshot-endpoint", ["task-0", "task-0"])):
            self.rejected(lambda v: v["requests"][0]["observations"][0].update(operation=operation, arguments=args),
                          "unadmitted passive")

    def test_byte_bounds_and_remaining_inventory_guards(self):
        self.rejected(lambda v: v["files"][1]["object"].update(content=blob(b"x" * (replay.MAX_FILE + 1))), "blob byte bound")
        self.rejected(lambda v: v["requests"][0].update(end_ns=31_000_000_011), "request order/interval")
        self.rejected(lambda v: v["files"][0]["object"].update(kind="regular"), "root object is not a directory")
        self.rejected(duplicate_directory, "duplicate directory entry")
        self.rejected(lambda v: v["requests"][0]["observations"][0]["cwd"].update(path="uncaptured"), "uncaptured observation cwd")
        self.rejected(lambda v: v.update(files=[row for row in v["files"] if row["place"]["root"] != "state"]), "state inventory")
        with patch.object(replay, "MAX_TOTAL", 1):
            with self.assertRaisesRegex(ValueError, "decoded workload byte bound"):
                accounting.workload(make())
        value = make()
        first = copy.deepcopy(value["changes"][0])
        first.update(seq=2, before_sha256=replay.object_seal(first["object"]))
        value["changes"].append(first)
        with self.assertRaisesRegex(ValueError, "duplicate same-time"):
            accounting.workload(reseal(value))
        value = make()
        value["changes"][0]["place"]["path"] = "uncaptured"
        with self.assertRaisesRegex(ValueError, "uncaptured file"):
            accounting.workload(reseal(value))

    def test_output_guards_and_late_refusal_remain_sticky(self):
        for kind in ("bytes", "status", "effects", "duplicate", "unknown", "output-bound", "closed"):
            model = accounting.workload(make())
            side = model.side("legacy")
            row = model.requests[0]
            request = opening(side, row)
            item = row["observations"][0]
            request.observe(operation=item["operation"], arguments=item["arguments"], cwd=item["cwd"], generation="g1", at_ns=item["start_ns"])
            values = dict(stdout=b"ok", stderr=b"", exit_status=0, effects=[])
            if kind == "bytes":
                values["stdout"] = "not-bytes"
            elif kind == "status":
                values["exit_status"] = True
            elif kind == "effects":
                values["effects"] = [dict(place=place("cursor"), content="not-bytes")]
            elif kind == "duplicate":
                values["effects"] = [dict(place=place("cursor"), content=b"x")] * 2
            elif kind == "unknown":
                values["effects"] = [dict(place=place("uncaptured"), content=b"x")]
            elif kind == "closed":
                request.complete(**values)
            with patch.object(replay, "MAX_TOTAL", 1 if kind == "output-bound" else replay.MAX_TOTAL):
                with self.assertRaises(ValueError):
                    request.complete(**values)
            with self.assertRaises(ValueError):
                opening(side, model.requests[1])
            with self.assertRaises(ValueError):
                side.finish()

    def test_home_namespaces_are_not_collapsed_and_cross_home_reads_refuse(self):
        value = make()
        other = copy.deepcopy(value["manifest"]["homes"][0])
        other.update(id="other", home="/other", state_root="/other/state")
        value["manifest"]["homes"].append(other)
        value["manifest"]["enrolled_homes"].append("other")
        second_files = copy.deepcopy(value["files"])
        for row in second_files:
            row["place"]["home"] = "other"
        value["files"].extend(second_files)
        model = accounting.workload(reseal(value))
        row = model.requests[0]
        side = model.side("legacy")
        request = opening(side, row)
        with self.assertRaisesRegex(ValueError, "foreign file"):
            request.object(place("cursor", home="other"), row["start_ns"])
        with self.assertRaises(ValueError):
            consume(request, row)

    def test_independent_guard_counterfactuals_fail_the_same_refusal_oracles(self):
        # CI-only guard replacement, not source-byte mutation or a runtime flag.
        # Each fixture is otherwise valid and the original public oracle must
        # itself fail when exactly the named semantic guard is removed.
        cases = [("duplicate directory entry", duplicate_directory, True),
                 ("envelope seal mismatch", lambda v: v.update(label="changed"), False),
                 ("blob byte bound or seal mismatch", lambda v: v["files"][1]["object"]["content"].update(sha256="0" * 64), True),
                 ("change preimage mismatch", lambda v: v["changes"][0].update(before_sha256="0" * 64), True),
                 ("change sequence/clock gap or regression", lambda v: v["changes"][0].update(seq=2), True),
                 ("unadmitted passive operation/arguments", lambda v: v["requests"][0]["observations"][0].update(arguments=["reset", "--hard"]), True),
                 ("branch actor lacks claim token", lambda v: v["requests"][0]["actor"].update(name="branch"), True),
                 ("duplicate request id", lambda v: v["requests"][1].update(id="r0"), True),
                 ("duplicate observation id", lambda v: v["requests"][1]["observations"][0].update(id="o0"), True)]
        original = replay.require
        for message, mutate, update_seal in cases:
            with self.subTest(guard=message):
                value = make()
                mutate(value)
                if update_seal:
                    reseal(value)
                def oracle():
                    with self.assertRaisesRegex(ValueError, message):
                        accounting.workload(value)
                oracle()
                def reverted(condition, detail):
                    if detail != message:
                        original(condition, detail)
                with patch.object(replay, "require", reverted):
                    with self.assertRaises(AssertionError):
                        oracle()
        for side_name in ("legacy", "candidate"):
            model = accounting.workload(make())
            side = model.side(side_name)
            row = model.requests[0]
            request = opening(side, row)
            def oracle():
                with self.assertRaisesRegex(ValueError, "unconsumed passive"):
                    consume(request, row, omit=True)
            oracle()
            # Fresh admitted request for the single-guard counterfactual.
            model = accounting.workload(make())
            side = model.side(side_name)
            request = opening(side, model.requests[0])
            def reverted(condition, detail):
                if detail != "unconsumed passive observations":
                    original(condition, detail)
            with patch.object(replay, "require", reverted):
                with self.assertRaises(AssertionError):
                    oracle()

    def test_no_materialization_clock_command_or_live_file_read(self):
        value = make()
        # Read the schema using its owner first; all later workload operations
        # are memory-only, including malicious-looking passive argument bytes.
        model = accounting.workload(value)
        with patch("builtins.open", side_effect=AssertionError("filesystem")), \
             patch("os.open", side_effect=AssertionError("filesystem")), \
             patch("subprocess.Popen", side_effect=AssertionError("process")), \
             patch("time.time_ns", side_effect=AssertionError("clock")):
            sides = [model.side(name) for name in ("legacy", "candidate")]
            for side in sides:
                for row in model.requests:
                    consume(opening(side, row), row)
            self.assertTrue(replay.compare(*sides)["equal"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
