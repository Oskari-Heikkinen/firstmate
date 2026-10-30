"""Captured task-row parity, real compatibility routing and bounded batch lanes."""
import asyncio
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import threading
import unittest
from unittest.mock import patch

from crew_checks import CrewParity
from compatibility_checks import Compatibility
from fm_view_engine import Engine, Inputs, Refused
import fm_view_snapshot
from fm_view_snapshot import Snapshot

ROOT = Path(__file__).resolve().parents[3]
NOW = "2026-10-24T00:00:00Z"
EPOCH = 1792800000


def arguments(concurrency=4):
    return dict(observed_at=NOW, epoch=EPOCH, concurrency=concurrency, task_timeout=10, options={})


def fresh_history(test, path, raw):
    """Start an independent history without reusing a persisted fold's identity."""
    before = path.stat()
    replacement = path.with_name("." + path.name + ".independent")
    replacement.write_bytes(raw)
    after = replacement.stat()
    # Keep the old file alive until the new one exists: inode reuse cannot
    # accidentally make this independent case look like an in-place rewrite.
    test.assertNotEqual((before.st_dev, before.st_ino), (after.st_dev, after.st_ino))
    replacement.replace(path)
    test.assertEqual(path.read_bytes(), raw)


class SnapshotParity(unittest.TestCase):
    maxDiff = None

    def setUp(self):
        self.fixture = CrewParity("runTest")
        self.fixture.setUp()
        self.home, self.state, self.env = self.fixture.home, self.fixture.state, self.fixture.env
        for folder in ("data", "projects", "config"):
            (self.home / folder).mkdir(exist_ok=True)
        self.env.update(FM_SNAPSHOT_NOW=NOW, FM_SNAPSHOT_NOW_EPOCH=str(EPOCH), FM_SNAPSHOT_SECONDMATES="0")
        self.fixture.fake("tasks-axi", "exit 1\n")
        self.fixture.fake("herdr", "echo FORBIDDEN_LIFECYCLE >&2; exit 99\n")

    def tearDown(self):
        self.fixture.tearDown()

    def native(self):
        snapshot = Snapshot(Inputs(str(self.home)), self.env)
        captures = snapshot.endpoints(snapshot.capture(snapshot.inventory()), 10)
        rows = [snapshot.compose(row, NOW, EPOCH) for row in captures]
        return snapshot.finish(captures, rows, NOW, EPOCH)["tasks"]

    def compare(self):
        legacy = subprocess.run(["bash", str(ROOT / "bin/fm-fleet-snapshot.sh"), "--json"],
                                env=self.env, capture_output=True, timeout=60)
        self.assertEqual(legacy.returncode, 0, legacy.stderr)
        # JSON transport replaces undecodable argument bytes like jq; normal
        # metadata is UTF-8 and status encoding has a separate fold matrix.
        expected = json.loads(legacy.stdout)["tasks"]
        # The public composer enriches task rows with backlog AFTER either
        # engine returns. This unit oracle compares only that engine boundary;
        # real-client tests below retain full public JSON equality.
        for row in expected:
            self.assertIsNone(row.pop("backlog"))
        self.assertEqual(self.native(), expected)

    def test_full_local_row_matrix(self):
        for kind in ("ship", "scout", "secondmate"):
            for raw in (b"", b"working [at=1792799900]: active\n\n",
                        b"needs-decision [at=1792799900] [key=x]: choose\nnote: later\n",
                        b"blocked [at=oops] [key=x]: stop\nresolved [key=x]: okay\n",
                        b"needs-decision [at=1792800100] [key=x]: future\n",
                        b"working: https://github.com/example/fixture/pull/42\npaused: waiting"):
                with self.subTest(kind=kind, raw=raw):
                    self.fixture.write_meta(kind=kind)
                    fresh_history(self, self.state / "task.status", raw)
                    self.compare()
        (self.home / "data/task").mkdir()
        (self.home / "data/task/report.md").write_text("report body never parsed\n")
        with (self.state / "task.meta").open("a") as stream:
            stream.write(f"projects=alpha, beta, , gamma\nhome={self.home}\npr=https://github.com/example/fixture/pull/99\npr_head=abc\nbranch=fm/task\nyolo=off\n")
        self.compare()
        (self.state / "task.status").unlink()
        self.compare()

    def test_similar_task_ids_use_row_order_not_metadata_filename_order(self):
        for task in ("foo", "foo-2", "foo.x"):
            (self.state / (task + ".meta")).write_text("kind=scout\nspawn_gen=g1\n")
        self.assertEqual([row["id"] for row in self.native()], ["foo", "foo-2", "foo.x", "task"])
        self.compare()

    def test_remote_missing_worktree_endpoint_and_multiple_rows(self):
        (self.state / "remote.meta").write_text("kind=secondmate\nremote_host=remote-fixture\nremote_root=/explicit/root\nremote_backend=herdr\nremote_target=opaque\nhome=/remote/home\n")
        (self.state / "missing.meta").write_text("kind=scout\nworktree=/nonexistent/view-fixture\n")
        self.compare()
        # Unsupported local endpoint observation refuses as a whole; it cannot
        # report an invented endpoint or drive a backend lifecycle command.
        self.fixture.write_meta(backend="herdr")
        with self.assertRaisesRegex(ValueError, "unsupported"):
            self.native()

    def test_one_endpoint_process_observes_every_local_row(self):
        (self.state / "other.meta").write_text("kind=scout\nspawn_gen=g1\n")
        (self.state / "remote.meta").write_text("kind=secondmate\nremote_host=remote-fixture\nremote_root=/explicit/root\nremote_backend=herdr\nremote_target=opaque\nhome=/remote/home\n")
        calls = []
        original = fm_view_snapshot.run
        def counted(argv, *args, **kwargs):
            calls.append(argv[2:])
            return original(argv, *args, **kwargs)
        with patch.object(fm_view_snapshot, "run", counted):
            self.compare()
        # The remote row is never observed locally; both local rows share one
        # adapter process instead of sourcing the backend graph per row.
        self.assertEqual(calls, [["snapshot-endpoint", "other", "task"]])

    def test_endpoint_batch_refuses_mismatched_packets_and_unobserved_rows(self):
        from fm_view_process import Observation
        snapshot = Snapshot(Inputs(str(self.home)), self.env)
        captures = snapshot.capture(snapshot.inventory())
        for status, stdout in ((0, b"other\0null\0not_checked\0"), (0, b"task\0null\0"),
                               (0, b"task\0null\0not_checked\0task\0null\0not_checked\0"),
                               (0, b"task\0maybe\0not_checked\0"), (0, b"task\0null\0awake\0"),
                               (0, b"task\0null\0not_checked"), (1, b"task\0null\0not_checked\0")):
            observed = Observation(("bash",), status, stdout, b"", 0, 0)
            with self.subTest(status=status, stdout=stdout), \
                    patch.object(fm_view_snapshot, "run", lambda *args, **kwargs: observed), \
                    self.assertRaisesRegex(ValueError, "snapshot endpoint observation unavailable"):
                snapshot.endpoints(captures, 10)
        # A current row composed without batched evidence refuses rather than
        # inventing an endpoint or observing it again per row.
        with self.assertRaisesRegex(ValueError, "snapshot endpoint observation unavailable"):
            snapshot.compose(captures[0], NOW, EPOCH)

    def test_generation_discards_every_mutable_surface(self):
        self.fixture.status(b"blocked [key=x]: predecessor\n")
        (self.home / "data/task").mkdir()
        (self.home / "data/task/report.md").touch()
        snapshot = Snapshot(Inputs(str(self.home)), self.env)
        captures = snapshot.endpoints(snapshot.capture(snapshot.inventory()), 10)
        rows = [snapshot.compose(row, NOW, EPOCH) for row in captures]
        (self.state / "task.meta").write_text("kind=scout\nspawn_gen=replacement\n")
        finished = snapshot.finish(captures, rows, NOW, EPOCH)
        row = finished["tasks"][0]
        self.assertIsNone(finished["captures"][0]["status"])
        self.assertIsNone(finished["captures"][0]["status_mtime_ns"])
        self.assertEqual(row["spawn_gen"], "g1")
        self.assertEqual(row["current_state"]["raw"], "")
        self.assertEqual(row["current_state"]["detail"], "task generation changed during snapshot")
        self.assertEqual(row["hints"]["open_decisions"], [])
        self.assertFalse(row["paths"]["status_log"]["present"])
        self.assertFalse(row["paths"]["report"]["present"])
        self.assertIsNone(row["endpoint"]["exists"])
        self.assertEqual(row["endpoint"]["agent_alive"], "unknown")

    def test_capture_append_and_fresh_pane_negative_control(self):
        snapshot = Snapshot(Inputs(str(self.home)), self.env)
        captures = snapshot.endpoints(snapshot.capture(snapshot.inventory()), 10)
        with (self.state / "task.status").open("ab") as stream:
            stream.write(b"blocked [key=later]: after capture\n")
        rows = [snapshot.compose(row, NOW, EPOCH) for row in captures]
        self.assertEqual(snapshot.finish(captures, rows, NOW, EPOCH)["tasks"][0]["hints"]["open_decisions"], [])
        self.assertTrue(self.native()[0]["hints"]["blocked_event"])
        before = (self.state / "task.status").read_bytes()
        self.fixture.busy("busy")
        self.assertEqual(self.native()[0]["current_state"]["source"], "pane")
        self.assertFalse(self.native()[0]["hints"]["blocked_event"])
        self.assertEqual((self.state / "task.status").read_bytes(), before)

    def test_bad_files_and_inventory_bounds_refuse(self):
        (self.state / "task.status").unlink()
        (self.state / "task.status").symlink_to(self.state / "task.meta")
        with self.assertRaises(OSError):
            self.native()
        (self.state / "task.status").unlink()
        for index in range(257):
            (self.state / f"row{index}.meta").write_text("kind=scout\n")
        with self.assertRaisesRegex(Refused, "task bound"):
            self.native()


class SnapshotCompatibility(unittest.IsolatedAsyncioTestCase):
    maxDiff = None

    # Reuse the isolated real transport/entrypoint fixture, not any live home.
    asyncSetUp = Compatibility.asyncSetUp
    asyncTearDown = Compatibility.asyncTearDown
    status = Compatibility.status
    invoke = Compatibility.invoke

    async def test_snapshot_real_client_parity_and_refusal_fallback(self):
        self.status(b"blocked [at=1792799900] [key=x]: question\nnote: later\n")
        calls = []
        original = Snapshot.compose
        def compose(instance, row, observed_at, epoch):
            calls.append(row["task"])
            return original(instance, row, observed_at, epoch)
        with patch.dict(os.environ, self.env), patch.object(Snapshot, "compose", compose):
            native, error = await self.invoke("fm-fleet-snapshot.sh", "--json", FM_SNAPSHOT_NOW=NOW, FM_SNAPSHOT_NOW_EPOCH=str(EPOCH))
            legacy, _ = await self.invoke("fm-fleet-snapshot.sh", "--json", native=False, FM_SNAPSHOT_NOW=NOW, FM_SNAPSHOT_NOW_EPOCH=str(EPOCH))
            self.assertEqual(json.loads(native), json.loads(legacy))
            self.assertEqual(calls, ["task"])
            self.assertNotIn(b"use legacy", error)
            refused, error = await self.invoke("fm-fleet-snapshot.sh", "--json", FM_VIEW_EPOCH="stale",
                                               FM_SNAPSHOT_NOW=NOW, FM_SNAPSHOT_NOW_EPOCH=str(EPOCH))
            self.assertEqual(json.loads(refused), json.loads(legacy))
            self.assertIn(b"use legacy", error)


    async def test_snapshot_fold_probe_requires_whole_legacy_fallback(self):
        from fm_view_engine import Engine
        self.status(b"needs-decision [key=first]: retained\nnote: later\n")
        probe = self.home / "fold-probe"
        cursor = self.state / ".task.snapshot-open-decisions-cursor"
        calls = []
        original = Engine.request

        async def observed(engine, operation, values, timeout):
            calls.append(operation)
            return await original(engine, operation, values, timeout)

        options = dict(FM_SNAPSHOT_NOW=NOW, FM_SNAPSHOT_NOW_EPOCH=str(EPOCH),
                       FM_OPEN_DECISIONS_READ_PROBE=str(probe))
        # Equal initial cursor bytes for both public owners, not an output-only
        # comparison after the first execution has consumed the legacy fold.
        cursor.write_bytes(b"")
        with patch.object(Engine, "request", observed):
            actual, error = await self.invoke("fm-fleet-snapshot.sh", "--json", **options)
        self.assertEqual(calls, [], error)
        self.assertIn(b"custom classifier/input reader requires legacy", error)
        expected_probe = str(self.state / "task.status") + "\t" + str((self.state / "task.status").stat().st_size) + "\n"
        self.assertEqual(probe.read_text(), expected_probe)
        actual_cursor = cursor.read_bytes()
        self.assertTrue(actual_cursor)
        cursor.write_bytes(b"")
        # A fresh probe path permits a whole-byte comparison without deleting
        # the first run's evidence or conflating two appends to one probe.
        expected, _ = await self.invoke("fm-fleet-snapshot.sh", "--json", native=False,
            **dict(options, FM_OPEN_DECISIONS_READ_PROBE=str(self.home / "legacy-fold-probe")))
        self.assertEqual(actual, expected)
        self.assertEqual(actual_cursor, cursor.read_bytes())
        self.assertEqual((self.home / "legacy-fold-probe").read_text(), expected_probe)
        # Empty is not a custom reader: prove the same public client can still
        # select native composition, not blanket fallback for all snapshots.
        with patch.dict(os.environ, self.env), patch.object(Engine, "request", observed):
            empty, error = await self.invoke("fm-fleet-snapshot.sh", "--json",
                **dict(options, FM_OPEN_DECISIONS_READ_PROBE=""))
        self.assertEqual(calls, ["snapshot-tasks"], error)
        self.assertNotIn(b"use legacy", error)
        self.assertEqual(empty, expected)
        print("snapshot fold-probe: real-client pre-RPC refusal, whole stdout/probe/cursor parity; empty probe stays native")

    async def test_resident_snapshot_appends_keep_whole_output_parity_without_legacy_cursor_writes(self):
        self.status(b"needs-decision [key=first]: initial\nnote: unrelated\n")
        cursor = self.state / ".task.snapshot-open-decisions-cursor"
        calls = []
        original = Snapshot.compose

        def observed(instance, row, observed_at, epoch):
            calls.append(row["task"])
            return original(instance, row, observed_at, epoch)

        options = dict(FM_SNAPSHOT_NOW=NOW, FM_SNAPSHOT_NOW_EPOCH=str(EPOCH))
        before = None
        for addition in (b"", b"resolved [key=first]: answered\nblocked [key=next]: new\nnote: later\n"):
            with (self.state / "task.status").open("ab") as stream:
                stream.write(addition)
            with patch.dict(os.environ, self.env), patch.object(Snapshot, "compose", observed):
                actual, error = await self.invoke("fm-fleet-snapshot.sh", "--json", **options)
            self.assertEqual(calls, ["task"], error)
            calls.clear()
            self.assertNotIn(b"use legacy", error)
            self.assertEqual(cursor.read_bytes() if cursor.exists() else None, before)
            expected, _ = await self.invoke("fm-fleet-snapshot.sh", "--json", native=False, **options)
            self.assertEqual(actual, expected)
            before = cursor.read_bytes()
        self.assertEqual(json.loads(actual)["tasks"][0]["hints"]["open_decisions"][0]["key"], "next")
        print("resident snapshot append: two native compositions, whole stdout parity, no native legacy-cursor write")

    async def test_unsupported_snapshot_backend_uses_complete_legacy_fallback(self):
        self.status(b"blocked [key=backend]: retain decision\n", kind="ship")
        (self.state / "task.meta").write_text(
            "kind=ship\nspawn_gen=g1\nbackend=cmux\nwindow=workspace:surface\n"
            + "worktree=" + str(self.home / "missing") + "\n")
        # Isolated passive fake only; neither path can reach a real backend.
        cmux = self.home / "fakebin/cmux"
        cmux.write_text("#!/bin/sh\nexit 1\n")
        cmux.chmod(0o700)
        calls = []
        original = Snapshot.compose

        def compose(instance, row, observed_at, epoch):
            calls.append(row["task"])
            return original(instance, row, observed_at, epoch)

        with patch.dict(os.environ, self.env), patch.object(Snapshot, "compose", compose):
            actual, error = await self.invoke("fm-fleet-snapshot.sh", "--json",
                FM_SNAPSHOT_NOW=NOW, FM_SNAPSHOT_NOW_EPOCH=str(EPOCH))
        # The batched endpoint observation refuses before any row composes.
        self.assertEqual(calls, [], error)
        self.assertIn(b"passive snapshot-endpoint integration unsupported; use legacy", error)
        expected, _ = await self.invoke("fm-fleet-snapshot.sh", "--json", native=False,
            FM_SNAPSHOT_NOW=NOW, FM_SNAPSHOT_NOW_EPOCH=str(EPOCH))
        self.assertEqual(json.loads(actual), json.loads(expected))
        self.assertEqual(json.loads(actual)["tasks"][0]["hints"]["open_decisions"][0]["key"], "backend")

    async def test_parent_collector_uses_captured_bytes_mtime_and_metadata(self):
        self.status(b"working [key=activity]: captured work\nnote: captured answer\n")
        stamp = (EPOCH - 120) * 1_000_000_000
        os.utime(self.state / "task.status", ns=(stamp, stamp))
        with (self.state / "task.meta").open("a") as stream:
            stream.write("window=fixture:task\nbackend=tmux\n")
        # A present endpoint and a terminal capture require the collector's
        # captured metadata, not just its captured status history.
        tmux = self.home / "fakebin/tmux"
        tmux.write_text('#!/bin/sh\ncase "$1" in display-message) printf "%%1\\n"; exit 0;; capture-pane) printf "captured answer\\n"; exit 0;; esac\nexit 1\n')
        tmux.chmod(0o700)
        legacy, _ = await self.invoke("fm-fleet-snapshot.sh", "--json", native=False,
                                      FM_SNAPSHOT_NOW=NOW, FM_SNAPSHOT_NOW_EPOCH=str(EPOCH))
        baseline = json.loads(legacy)
        parent = baseline["secondmate_current"]["records"][0]
        self.assertEqual(parent["freshness"]["age_seconds"], 120)
        self.assertEqual(parent["parent_event"]["open_activities"][0]["key"], "activity")
        self.assertTrue(parent["terminal_evidence"]["captured"])
        calls = []
        original = Snapshot.finish
        def finish(instance, captures, rows, observed_at, epoch):
            reply = original(instance, captures, rows, observed_at, epoch)
            calls.append(True)
            # A new status, including a new mtime, arrives after capture. It
            # cannot leak into ANY selected row or parent-evidence surface.
            (self.state / "task.status").write_bytes(b"working [key=newer]: after capture\n")
            return reply
        with patch.dict(os.environ, self.env), patch.object(Snapshot, "finish", finish):
            native, error = await self.invoke("fm-fleet-snapshot.sh", "--json",
                                              FM_SNAPSHOT_NOW=NOW, FM_SNAPSHOT_NOW_EPOCH=str(EPOCH))
        self.assertEqual(calls, [True])
        self.assertNotIn(b"use legacy", error)
        self.assertEqual(json.loads(native), baseline)

    async def test_atomic_same_generation_metadata_rewrite_uses_complete_legacy_fallback(self):
        original = Snapshot.compose
        for phase in ("before", "after"):
            self.status(b"blocked [key=old]: captured predecessor\n")
            # Each phase is independent; the preceding fallback may have
            # persisted a legacy snapshot fold for its replacement history.
            path = self.state / "task.status"
            fresh_history(self, path, path.read_bytes())
            calls = []
            def compose(instance, row, observed_at, epoch):
                calls.append(row["task"])
                def rewrite():
                    meta = self.state / "task.meta"
                    staged = self.state / ".replacement-meta"
                    staged.write_bytes(meta.read_bytes() + b"pr=https://github.com/example/fixture/pull/99\n")
                    # Same nonempty spawn_gen, different inode and content.
                    before = meta.stat().st_ino
                    staged.replace(meta)
                    self.assertNotEqual(meta.stat().st_ino, before)
                    self.assertIn(b"spawn_gen=g1\n", meta.read_bytes())
                    (self.state / "task.status").write_bytes(b"blocked [key=newer]: recaptured by legacy owner\n")
                if phase == "before":
                    rewrite()
                result = original(instance, row, observed_at, epoch)
                if phase == "after":
                    rewrite()
                return result
            with self.subTest(phase=phase), patch.dict(os.environ, self.env), patch.object(Snapshot, "compose", compose):
                native, error = await self.invoke("fm-fleet-snapshot.sh", "--json", FM_SNAPSHOT_NOW=NOW, FM_SNAPSHOT_NOW_EPOCH=str(EPOCH))
                legacy, _ = await self.invoke("fm-fleet-snapshot.sh", "--json", native=False, FM_SNAPSHOT_NOW=NOW, FM_SNAPSHOT_NOW_EPOCH=str(EPOCH))
                self.assertEqual(json.loads(native), json.loads(legacy))
                self.assertEqual(calls, ["task"])
                self.assertIn(b"same-generation metadata changed", error)
                row = json.loads(native)["tasks"][0]
                self.assertEqual(row["pr"]["url"], "https://github.com/example/fixture/pull/99")
                self.assertEqual([decision["key"] for decision in row["hints"]["open_decisions"]], ["newer"])
                self.assertNotEqual(row["current_state"]["detail"], "task generation changed during snapshot")

    async def test_malformed_snapshot_reply_falls_back_before_output(self):
        self.status(b"blocked [key=x]: question\n")
        original = Snapshot.finish
        for damage in ("duplicate", "path", "state", "missing", "capture-missing", "capture-foreign",
                       "capture-presence", "capture-time", "capture-duplicate"):
            calls = []
            def finish(instance, captures, rows, observed_at, epoch):
                reply = original(instance, captures, rows, observed_at, epoch)
                calls.append(True)
                if damage == "duplicate":
                    reply["tasks"].append(reply["tasks"][0])
                elif damage == "path":
                    reply["tasks"][0]["paths"]["meta"]["path"] = "/foreign/task.meta"
                elif damage == "state":
                    reply["tasks"][0]["current_state"]["state"] = "invented"
                elif damage == "missing":
                    del reply["tasks"][0]["hints"]
                elif damage == "capture-missing":
                    del reply["captures"]
                elif damage == "capture-foreign":
                    reply["captures"][0]["task"] = "foreign"
                elif damage == "capture-presence":
                    reply["captures"][0]["status"] = None
                elif damage == "capture-time":
                    reply["captures"][0]["status_mtime_ns"] = True
                else:
                    reply["captures"].append(reply["captures"][0])
                return reply
            with self.subTest(damage=damage), patch.dict(os.environ, self.env), patch.object(Snapshot, "finish", finish):
                native, error = await self.invoke("fm-fleet-snapshot.sh", "--json", FM_SNAPSHOT_NOW=NOW, FM_SNAPSHOT_NOW_EPOCH=str(EPOCH))
                legacy, _ = await self.invoke("fm-fleet-snapshot.sh", "--json", native=False, FM_SNAPSHOT_NOW=NOW, FM_SNAPSHOT_NOW_EPOCH=str(EPOCH))
                self.assertEqual(json.loads(native), json.loads(legacy))
                self.assertEqual(calls, [True])
                self.assertIn(b"use legacy", error)

    async def test_unsafe_capture_directory_refuses_before_native_selection(self):
        self.status(b"working [key=activity]: captured\nnote: answer\n")
        legacy, _ = await self.invoke("fm-fleet-snapshot.sh", "--json", native=False,
                                      FM_SNAPSHOT_NOW=NOW, FM_SNAPSHOT_NOW_EPOCH=str(EPOCH))
        protected = self.home / "protected-captures"
        protected.mkdir()
        (protected / "sentinel").write_bytes(b"untouched")
        marker = self.home / "staging-refusal-reached"
        wrapper = self.home / "fakebin/python3"
        for damage in ("occupied", "public", "symlink"):
            wrapper.write_text(f'''#!{sys.executable}
import os
from pathlib import Path
import sys
if len(sys.argv) > 2 and sys.argv[1].endswith("fm-view-client.py") and sys.argv[2] == "snapshot-tasks":
    directory = Path(sys.argv[-1])
    damage = {damage!r}
    if damage == "occupied":
        (directory / ".occupied").touch()
    elif damage == "public":
        directory.chmod(0o755)
    else:
        directory.rmdir()
        directory.symlink_to({str(protected)!r}, target_is_directory=True)
    Path({str(marker)!r}).write_text(damage)
os.execv({sys.executable!r}, [{sys.executable!r}] + sys.argv[1:])
''')
            wrapper.chmod(0o700)
            with self.subTest(damage=damage), patch.dict(os.environ, self.env):
                native, error = await self.invoke("fm-fleet-snapshot.sh", "--json",
                                                  FM_SNAPSHOT_NOW=NOW, FM_SNAPSHOT_NOW_EPOCH=str(EPOCH))
                self.assertEqual(marker.read_text(), damage)
                self.assertIn(b"use legacy", error)
                self.assertEqual(json.loads(native), json.loads(legacy))
                self.assertEqual(list(protected.iterdir()), [protected / "sentinel"])
                self.assertEqual((protected / "sentinel").read_bytes(), b"untouched")

    def pin_summary_wall_timestamp(self):
        # Keep the primary-ready wall timestamp on the same explicit clock as
        # snapshot generation. Numeric/elapsed date calls still use real time;
        # do not normalize away a field or blind the timeout owner.
        real_date = shutil.which("date", path=self.env["PATH"])
        self.assertIsNotNone(real_date)
        date = self.home / "fakebin/date"
        date.write_text('#!/bin/sh\nif [ "$#" -eq 2 ] && [ "$1" = -u ] && '
                        '[ "$2" = +%Y-%m-%dT%H:%M:%SZ ]; then\n'
                        + "  printf '%s\\n' " + shlex.quote(NOW) + "\nelse\n  exec "
                        + shlex.quote(real_date) + ' "$@"\nfi\n')
        date.chmod(0o700)

    async def test_complete_home_summary_and_publication_equal_legacy(self):
        self.pin_summary_wall_timestamp()
        self.env.update(GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM="1",
                        GIT_AUTHOR_NAME="fixture", GIT_AUTHOR_EMAIL="fixture@example.invalid",
                        GIT_COMMITTER_NAME="fixture", GIT_COMMITTER_EMAIL="fixture@example.invalid")
        for task, kind, raw in (
            ("ship", "ship", b"blocked [key=dependency]: dependency\nnote: later\n"),
            ("scout", "scout", b"needs-decision [key=route]: route\nworking: later\n"),
            ("mate", "secondmate", b"working: resident activity\nnote: answer\n"),
        ):
            self.status(raw, task=task, kind=kind)
        report = self.home / "data/scout"
        report.mkdir()
        (report / "report.md").write_text("durable scout report\n")
        (self.home / "data/backlog.md").write_text(
            "## In flight\n- [ ] ship - Work (repo: fixture) (kind: ship)\n"
            "- [ ] scout - Inspect (repo: fixture) (kind: scout)\n"
            "## Queued\n- [ ] future - Next (repo: fixture) (kind: ship)\n"
            "## Done\n- [x] prior - Prior (repo: fixture) (kind: ship)\n")
        clock = dict(FM_SNAPSHOT_NOW=NOW, FM_SNAPSHOT_NOW_EPOCH=str(EPOCH))
        calls = []
        composed = {}
        original = Snapshot.compose

        def compose(instance, row, observed_at, epoch):
            calls.append(row["task"])
            result = original(instance, row, observed_at, epoch)
            composed[row["task"]] = result
            return result

        with patch.dict(os.environ, self.env), patch.object(Snapshot, "compose", compose):
            native, error = await self.invoke("fm-fleet-snapshot.sh", "--secondmate-home-summary", **clock)
            self.assertNotIn(b"use legacy", error)
            self.assertCountEqual(calls, ["ship", "scout", "mate"])
            expected, _ = await self.invoke("fm-fleet-snapshot.sh", "--secondmate-home-summary", native=False, **clock)
            # Retain the original three-row input as an explicit empty-child
            # parity control: none is both backlog-owned and currently working.
            empty = json.loads(native)
            self.assertEqual(empty, json.loads(expected))
            self.assertEqual(empty["active_children"], [])
            self.assertEqual(empty["counts"]["active_children"], 0)

            # Make the resident mate a genuinely eligible working child. Both
            # classifiers see a real isolated Git tree and the same passive
            # endpoint fake; no live backend or harness is contacted.
            worktree = self.home / "projects/mate"
            worktree.mkdir(parents=True)
            for command in (("init", "-q"), ("checkout", "-q", "-b", "fm/mate"),
                            ("commit", "-q", "--allow-empty", "-m", "fixture")):
                result = await asyncio.to_thread(subprocess.run, ["git", "-C", str(worktree), *command],
                                                 env=self.env, capture_output=True, timeout=10)
                self.assertEqual(result.returncode, 0, result.stderr)
            with (self.state / "mate.meta").open("a") as stream:
                stream.write(f"worktree={worktree}\nbackend=tmux\nwindow=fixture:mate\n")
            backlog = self.home / "data/backlog.md"
            backlog.write_text(backlog.read_text().replace("## Queued\n",
                "- [ ] mate - Resident work (repo: fixture) (kind: secondmate)\n## Queued\n"))
            tmux = self.home / "fakebin/tmux"
            tmux.write_text('''#!/bin/sh
case "$1" in
  list-windows) printf 'mate\\n'; exit 0;;
  display-message)
    case "$5" in
      '#{pane_tty}') exit 1;;
      '#{pane_current_command}') printf 'claude\\n';;
      *) printf '%%1\\n';;
    esac
    exit 0;;
  capture-pane) printf 'resident answer\\n'; exit 0;;
esac
exit 1
''')
            tmux.chmod(0o700)
            # Only this expanded input ends in a current working event; retain
            # the note-tailed empty-child control above without changing bytes.
            with (self.state / "mate.status").open("ab") as stream:
                stream.write(b"working: resident activity\n")
            calls.clear()
            composed.clear()
            native, error = await self.invoke("fm-fleet-snapshot.sh", "--secondmate-home-summary", **clock)
            self.assertNotIn(b"use legacy", error)
            self.assertCountEqual(calls, ["ship", "scout", "mate"])
            expected, _ = await self.invoke("fm-fleet-snapshot.sh", "--secondmate-home-summary", native=False, **clock)
            summary = json.loads(native)
            admission = json.dumps({"mate": composed.get("mate"), "endpoints": summary["endpoints"],
                                    "summary": summary}, indent=2, sort_keys=True)
            self.assertEqual(summary, json.loads(expected), admission)
            self.assertEqual([row["id"] for row in summary["active_children"]], ["mate"], admission)
            self.assertEqual(summary["active_children"][0]["state"], "working")
            self.assertEqual(summary["counts"]["active_children"], 1)
            endpoint = next(row for row in summary["endpoints"] if row["id"] == "mate")
            self.assertEqual(endpoint["backlog_state"], "in_flight")
            self.assertTrue(endpoint["endpoint"]["exists"])
            self.assertEqual(endpoint["endpoint"]["agent_alive"], "alive")
            self.assertTrue(summary["decisions_open"])
            calls.clear()
            await self.invoke("fm-home-summary-refresh.sh", **clock)
            self.assertCountEqual(calls, ["ship", "scout", "mate"])
            ledger = self.state / "home-summary.json"
            self.assertEqual(json.loads(ledger.read_bytes()), summary)
            for marker in ("pending", "owed", "attempt"):
                self.assertFalse((self.state / (".home-summary-refresh." + marker)).exists())
            # A later fresh read must update the complete ledger, not reuse its
            # predecessor or normalize away the changed decision/publication.
            fresh_history(self, self.state / "ship.status", b"blocked [key=newer]: new dependency\n")
            calls.clear()
            await self.invoke("fm-home-summary-refresh.sh", **clock)
            self.assertCountEqual(calls, ["ship", "scout", "mate"])
            updated = json.loads(ledger.read_bytes())
            fresh, _ = await self.invoke("fm-fleet-snapshot.sh", "--secondmate-home-summary", native=False, **clock)
            self.assertEqual(updated, json.loads(fresh))
            self.assertNotEqual(updated, summary)
            fallback, error = await self.invoke("fm-fleet-snapshot.sh", "--secondmate-home-summary",
                                                 FM_VIEW_EPOCH="stale", **clock)
            self.assertIn(b"use legacy", error)
            self.assertEqual(json.loads(fallback), updated)

    async def test_timed_out_native_publication_retains_prior_complete_ledger_and_retries(self):
        self.pin_summary_wall_timestamp()
        self.status(b"blocked [key=first]: original ledger\n")
        clock = dict(FM_SNAPSHOT_NOW=NOW, FM_SNAPSHOT_NOW_EPOCH=str(EPOCH))
        entered, release = threading.Event(), threading.Event()
        calls = []
        original = Snapshot.compose

        def compose(instance, row, observed_at, epoch):
            calls.append(row["task"])
            entered.set()
            if not release.wait(20):
                raise RuntimeError("publication-timeout fixture release missing")
            return original(instance, row, observed_at, epoch)

        pending = None
        try:
            with patch.dict(os.environ, self.env):
                await self.invoke("fm-home-summary-refresh.sh", **clock)
                ledger = self.state / "home-summary.json"
                prior = ledger.read_bytes()
                (self.state / "task.status").write_bytes(b"blocked [key=newer]: replacement ledger\n")
                with patch.object(Snapshot, "compose", compose):
                    pending = asyncio.create_task(self.invoke("fm-home-summary-refresh.sh", "--best-effort",
                                                               FM_HOME_SUMMARY_TIMEOUT="5", **clock))
                    for _ in range(1000):
                        if entered.is_set() or pending.done():
                            break
                        await asyncio.sleep(.01)
                    self.assertTrue(entered.is_set(), "timeout did not exercise native composition")
                    await pending
                    self.assertEqual(calls, ["task"])
                    self.assertFalse(release.is_set())
                    self.assertEqual(ledger.read_bytes(), prior)
                    self.assertTrue((self.state / ".home-summary-refresh.owed").exists())
                    self.assertTrue((self.state / ".home-summary-refresh.log").stat().st_size)
                    release.set()
                await self.invoke("fm-home-summary-refresh.sh", **clock)
                current = json.loads(ledger.read_bytes())
                self.assertEqual([row["key"] for row in current["decisions_open"]], ["newer"])
                expected, _ = await self.invoke("fm-fleet-snapshot.sh", "--secondmate-home-summary", native=False, **clock)
                self.assertEqual(current, json.loads(expected))
                for marker in ("pending", "owed", "attempt"):
                    self.assertFalse((self.state / (".home-summary-refresh." + marker)).exists())
        finally:
            release.set()
            if pending:
                await asyncio.gather(pending, return_exceptions=True)

    async def test_dirty_trigger_during_native_publication_survives_for_next_refresh(self):
        self.status(b"blocked [key=first]: captured\n")
        entered, release = threading.Event(), threading.Event()
        original = Snapshot.compose
        calls = []
        def compose(instance, row, observed_at, epoch):
            calls.append(row["task"])
            if len(calls) == 1:
                entered.set()
                if not release.wait(15):
                    raise RuntimeError("publication fixture release missing")
            return original(instance, row, observed_at, epoch)
        first = None
        try:
            with patch.dict(os.environ, self.env), patch.object(Snapshot, "compose", compose):
                first = asyncio.create_task(self.invoke("fm-home-summary-refresh.sh"))
                for _ in range(1000):
                    if entered.is_set():
                        break
                    await asyncio.sleep(.01)
                self.assertTrue(entered.is_set())
                self.assertTrue((self.state / ".home-summary-refresh.owed").exists())
                (self.state / "task.status").write_bytes(b"blocked [key=newer]: not in first capture\n")
                await self.invoke("fm-home-summary-refresh.sh", FM_HOME_SUMMARY_IF_IDLE="1")
                self.assertTrue((self.state / ".home-summary-refresh.pending").exists())
                release.set()
                await first
                first_ledger = json.loads((self.state / "home-summary.json").read_bytes())
                self.assertEqual([row["key"] for row in first_ledger["decisions_open"]], ["first"])
                self.assertTrue((self.state / ".home-summary-refresh.pending").exists())
                self.assertFalse((self.state / ".home-summary-refresh.owed").exists())
                await self.invoke("fm-home-summary-refresh.sh")
                second_ledger = json.loads((self.state / "home-summary.json").read_bytes())
                self.assertEqual([row["key"] for row in second_ledger["decisions_open"]], ["newer"])
                self.assertFalse((self.state / ".home-summary-refresh.pending").exists())
                self.assertFalse((self.state / ".home-summary-refresh.owed").exists())
                self.assertEqual(calls, ["task", "task"])
        finally:
            release.set()
            if first:
                await asyncio.gather(first, return_exceptions=True)


class SnapshotScheduling(unittest.IsolatedAsyncioTestCase):
    async def test_initial_capture_and_final_barriers_never_take_critical_capacity(self):
        import tempfile
        for phase in ("inventory", "capture", "endpoints", "finish"):
            with self.subTest(phase=phase), tempfile.TemporaryDirectory() as temporary:
                home = Path(temporary).resolve()
                (home / "state").mkdir()
                engine = Engine(Inputs(str(home)), workers=2, critical_workers=2)
                entered = [threading.Event(), threading.Event()]
                release = threading.Event()
                count = 0
                lock = threading.Lock()
                original = getattr(Snapshot, phase)
                def stall(instance, *args):
                    nonlocal count
                    with lock:
                        index = count
                        count += 1
                    if index < 2:
                        entered[index].set()
                        if not release.wait(10):
                            raise RuntimeError("barrier fixture release missing")
                    return original(instance, *args)
                subscribers = []
                try:
                    with patch.object(Snapshot, phase, stall):
                        first, second = arguments(), arguments()
                        second["epoch"] += 1
                        subscribers = [asyncio.create_task(engine.request("snapshot-tasks", args, 5))
                                       for args in (first, second)]
                        for _ in range(1000):
                            if all(event.is_set() for event in entered):
                                break
                            await asyncio.sleep(.01)
                        self.assertTrue(all(event.is_set() for event in entered))
                        self.assertEqual(engine.ordinary.active, 2)
                        folds = await asyncio.gather(*(engine.request("status-fold", {"task": f"task{i}"}, 2) for i in range(2)))
                        self.assertEqual([row["open"] for row in folds], [[], []])
                        release.set()
                        outcomes = await asyncio.gather(*subscribers, return_exceptions=True)
                        for outcome in outcomes:
                            if isinstance(outcome, Refused):
                                self.assertIn("capacity", str(outcome))
                            else:
                                self.assertEqual(outcome, {"tasks": [], "captures": []})
                finally:
                    release.set()
                    await asyncio.gather(*subscribers, return_exceptions=True)
                    engine.close()

    async def test_fixed_pool_singleflight_timeout_and_critical_reservation(self):
        import tempfile
        with tempfile.TemporaryDirectory() as temporary:
            home = Path(temporary).resolve()
            (home / "state").mkdir()
            for index in range(6):
                (home / "state" / f"task{index}.meta").write_text("kind=scout\nspawn_gen=g1\n")
            engine = Engine(Inputs(str(home)), workers=2, critical_workers=2)
            release, entered = threading.Event(), threading.Event()
            active, peak, calls = 0, 0, 0
            lock = threading.Lock()
            def compose(instance, row, observed_at, epoch):
                nonlocal active, peak, calls
                with lock:
                    active += 1
                    calls += 1
                    peak = max(active, peak)
                    if active == 2:
                        entered.set()
                try:
                    if not release.wait(10):
                        raise RuntimeError("fixture release missing")
                    return {"id": row["task"]}
                finally:
                    with lock:
                        active -= 1
            subscribers = []
            try:
                with patch.object(Snapshot, "compose", compose):
                    # Hold capture briefly so both subscribers capture their
                    # generation and join before the two ordinary slots fill.
                    original_capture = Snapshot.capture
                    gate = threading.Event()
                    def capture(instance, rows):
                        if not gate.wait(10):
                            raise RuntimeError("capture gate missing")
                        return original_capture(instance, rows)
                    with patch.object(Snapshot, "capture", capture):
                        subscribers = [asyncio.create_task(engine.request("snapshot-tasks", arguments(), 5))]
                        for _ in range(1000):
                            if engine.operations:
                                break
                            await asyncio.sleep(.01)
                        subscribers.append(asyncio.create_task(engine.request("snapshot-tasks", arguments(), .2)))
                        for _ in range(1000):
                            if engine.shared:
                                break
                            await asyncio.sleep(.01)
                        self.assertEqual(engine.shared, 1)
                        gate.set()
                        for _ in range(1000):
                            if entered.is_set():
                                break
                            await asyncio.sleep(.01)
                        self.assertTrue(entered.is_set())
                        with self.assertRaises(asyncio.TimeoutError):
                            await subscribers[1]
                        self.assertEqual(engine.ordinary.active, 2)
                        folds = await asyncio.gather(*(engine.request("status-fold", {"task": f"task{i}"}, 2) for i in range(2)))
                        self.assertEqual([row["open"] for row in folds], [[], []])
                        release.set()
                        self.assertEqual(len((await subscribers[0])["tasks"]), 6)
                        self.assertEqual((peak, calls), (2, 6))
                        await engine.request("snapshot-tasks", arguments(concurrency=1), 5)
                        self.assertEqual(calls, 12)  # completed requests are fresh
            finally:
                release.set()
                gate.set()
                await asyncio.gather(*subscribers, return_exceptions=True)
                engine.close()
