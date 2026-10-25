"""Captured task-row parity, real compatibility routing and bounded batch lanes."""
import asyncio
import json
import os
from pathlib import Path
import subprocess
import threading
import unittest
from unittest.mock import patch

from crew_checks import CrewParity
from compatibility_checks import Compatibility
from fm_view_engine import Engine, Inputs, Refused
from fm_view_snapshot import Snapshot

ROOT = Path(__file__).resolve().parents[3]
NOW = "2026-10-24T00:00:00Z"
EPOCH = 1792800000


def arguments(concurrency=4):
    return dict(observed_at=NOW, epoch=EPOCH, concurrency=concurrency, task_timeout=10, options={})


class SnapshotParity(unittest.TestCase):
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
        captures = snapshot.capture(snapshot.inventory())
        rows = [snapshot.compose(row, NOW, EPOCH) for row in captures]
        return snapshot.finish(captures, rows, NOW, EPOCH)["tasks"]

    def compare(self):
        legacy = subprocess.run(["bash", str(ROOT / "bin/fm-fleet-snapshot.sh"), "--json"],
                                env=self.env, capture_output=True, timeout=60)
        self.assertEqual(legacy.returncode, 0, legacy.stderr)
        # JSON transport replaces undecodable argument bytes like jq; normal
        # metadata is UTF-8 and status encoding has a separate fold matrix.
        self.assertEqual(self.native(), json.loads(legacy.stdout)["tasks"])

    def test_full_local_row_matrix(self):
        for kind in ("ship", "scout", "secondmate"):
            for raw in (b"", b"working [at=1792799900]: active\n\n",
                        b"needs-decision [at=1792799900] [key=x]: choose\nnote: later\n",
                        b"blocked [at=oops] [key=x]: stop\nresolved [key=x]: okay\n",
                        b"needs-decision [at=1792800100] [key=x]: future\n",
                        b"working: https://github.com/example/fixture/pull/42\npaused: waiting"):
                with self.subTest(kind=kind, raw=raw):
                    self.fixture.write_meta(kind=kind)
                    self.fixture.status(raw)
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

    def test_generation_discards_every_mutable_surface(self):
        self.fixture.status(b"blocked [key=x]: predecessor\n")
        (self.home / "data/task").mkdir()
        (self.home / "data/task/report.md").touch()
        snapshot = Snapshot(Inputs(str(self.home)), self.env)
        captures = snapshot.capture(snapshot.inventory())
        rows = [snapshot.compose(row, NOW, EPOCH) for row in captures]
        (self.state / "task.meta").write_text("kind=scout\nspawn_gen=replacement\n")
        row = snapshot.finish(captures, rows, NOW, EPOCH)["tasks"][0]
        self.assertEqual(row["spawn_gen"], "g1")
        self.assertEqual(row["current_state"]["detail"], "task generation changed during snapshot")
        self.assertEqual(row["hints"]["open_decisions"], [])
        self.assertFalse(row["paths"]["status_log"]["present"])
        self.assertFalse(row["paths"]["report"]["present"])
        self.assertIsNone(row["endpoint"]["exists"])
        self.assertEqual(row["endpoint"]["agent_alive"], "unknown")

    def test_capture_append_and_fresh_pane_negative_control(self):
        snapshot = Snapshot(Inputs(str(self.home)), self.env)
        captures = snapshot.capture(snapshot.inventory())
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


    async def test_atomic_same_generation_metadata_rewrite_uses_complete_legacy_fallback(self):
        original = Snapshot.compose
        for phase in ("before", "after"):
            self.status(b"blocked [key=old]: captured predecessor\n")
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
        for damage in ("duplicate", "path", "state", "missing"):
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
                else:
                    del reply["tasks"][0]["hints"]
                return reply
            with self.subTest(damage=damage), patch.dict(os.environ, self.env), patch.object(Snapshot, "finish", finish):
                native, error = await self.invoke("fm-fleet-snapshot.sh", "--json", FM_SNAPSHOT_NOW=NOW, FM_SNAPSHOT_NOW_EPOCH=str(EPOCH))
                legacy, _ = await self.invoke("fm-fleet-snapshot.sh", "--json", native=False, FM_SNAPSHOT_NOW=NOW, FM_SNAPSHOT_NOW_EPOCH=str(EPOCH))
                self.assertEqual(json.loads(native), json.loads(legacy))
                self.assertEqual(calls, [True])
                self.assertIn(b"use legacy", error)

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
        for phase in ("inventory", "capture", "finish"):
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
                                self.assertEqual(outcome, {"tasks": []})
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
