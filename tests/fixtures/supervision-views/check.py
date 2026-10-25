#!/usr/bin/env python3
"""Isolated public-interface tests for the uninstalled view-engine primitives.

No backend or live home is contacted. Real Unix sockets/threads exercise the
transport and admission boundaries; the existing shell classifier is the fold
oracle. This is not a performance benchmark or a complete P1 acceptance run.
"""
import asyncio
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import threading
import time
import unittest

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "bin"))
from fm_view_engine import (BoundedLane, Engine, Inputs, PROTOCOL, Refused, client,
                            encoded, read_file, serve)
from fm_view_status import Fold, FoldIndex


class StatusParity(unittest.TestCase):
    def compare(self, raw, kind="secondmate", registrations=None):
        with tempfile.TemporaryDirectory() as temporary:
            home = Path(temporary).resolve()
            state = home / "state"
            state.mkdir()
            (state / "task.meta").write_text("kind=" + kind + "\nspawn_gen=g1\n")
            (state / "task.status").write_bytes(raw)
            if registrations:
                registrations(state)
            native = Inputs(str(home)).fold("task")
            script = '''. "$1/bin/fm-classify-lib.sh"
last_status_line_to latest "$2/task.status"
printf '%s\\0' "$latest"
status_current_line "$2/task.status" "$3"
printf '\\0'
status_open_decisions "$2/task.status" "$3"
'''
            run = subprocess.run(["bash", "-c", script, "oracle", str(ROOT), str(state), kind],
                                 capture_output=True, timeout=20)
            self.assertEqual(run.returncode, 0, run.stderr)
            latest, current, opened = run.stdout.split(b"\0")
            native_bytes = lambda s: s.encode("utf-8", "surrogateescape")
            self.assertEqual(native_bytes(native["latest"]), latest)
            self.assertEqual(native_bytes(native["current"]), current.rstrip(b"\n"))
            native_open = "\n".join("\t".join((row["key"], row["verb"], row["summary"])) for row in native["open"])
            self.assertEqual(native_bytes(native_open), opened.rstrip(b"\n"))

    def test_keyed_and_terminal_parity(self):
        cases = [
            b"", b"prose\n", b"working: now\ncontinued prose\n",
            b"needs-decision [key=x] [at=12]: question\nworking: other work\n",
            b"needs-decision: [key=x] question\nresolved [key=x]: yes\n",
            b"needs-decision [key=x]: [key=y] question\nresolved [key=y]: no\n",
            b"needs-decision [key=bad key]: invalid\nresolved: not it\n",
            b"needs-decision [key=x] [at=10:30]: question\nresolved [key=x] [at=<epoch>]: yes\n",
            b"needs-decision corr=0123456789abcdef [key=x]: question\nresolved corr=0123456789ABCDEF [key=x]: yes\n",
            b"needs-decision [key=x]: question\nresolved corr=bad [key=x]: not a transition\n",
            b"needs-decision [key=x]: question\ndone: another concern\n",
            b"needs-decision [key=x]: question\nfailed: another concern\n",
            b"needs-decision [key=x]: question\nblocked [key=y]: obstacle\nblocked [key=x]: replacement\n",
            b"blocked [key=x]: obstacle\nnote [supersedes=resume] [at=42]: resumed\n",
            b"needs-decision [key=x]: question\nblocked [key=y]: obstacle\nnote [supersedes=validation-run]: started\n",
            b"blocked [key=pending-reply-t]: pending-reply-missed: no answer\nnote [supersedes=relaunch]: relaunched\n",
            b"blocked [key=pending-reply-t]: pending-reply-missed: no answer\nresolved [key=pending-reply-t]: not the owner\n",
            b"paused [key=p]: wait\nresolved [key=x]: unrelated\n",
            b"paused: wait\nresolved [key=default]: unrelated phase\n",
            b"paused [key=default]: wait\nresolved: unrelated phase\n",
            b"paused [key=p]: wait\nresolved [key=p]: ended\n",
            b"paused [wait=ci:42] [at=23]: wait\nresolved [key=x]: unrelated\n",
            b"needs-decision [key=x]: question\nholding: unrecognized event\n",
            b"working: now\nPR ready\ncontinued prose mentions merged\n",
            b"needs-decision [key=x]: \xff invalid UTF-8\n",
            b"needs-decision [key=x]: partial final line",
            b"needs-decision [key=x]: before\nresolved [key=x]: after\0\n",
        ]
        for kind in ("ship", "scout", "secondmate", "unknown"):
            for case in cases:
                with self.subTest(kind=kind, raw=case):
                    self.compare(case, kind)

    def test_tool_levels_and_unreadable_stores(self):
        raw = b"blocked [key=alarm]: condition\nnote [supersedes=relaunch]: new worker\n"
        for mode in ("active", "cleared", "unreadable", "invalid-reg", "other-invalid-reg"):
            def registration(state):
                (state / "alert-stores").mkdir()
                store = state / "owned.json"
                if mode != "unreadable":
                    store.write_text(json.dumps({"schema": "fm-alert-store/v1", "active": {"alarm": {}} if mode == "active" else {}}))
                schema = "bad" if "invalid-reg" in mode else "fm-alert-registration/v1"
                named = "other.status" if mode == "other-invalid-reg" else "task.status"
                (state / "alert-stores" / "owner.reg").write_text(
                    f"schema={schema}\nstore=owner\npath={store}\nstatus={named}\n")
            with self.subTest(mode=mode):
                self.compare(raw, registrations=registration)

    def test_local_change_without_status_change(self):
        with tempfile.TemporaryDirectory() as temporary:
            home = Path(temporary).resolve()
            state = home / "state"
            state.mkdir()
            (state / "task.meta").write_text("kind=secondmate\nspawn_gen=g1\n")
            raw = b"blocked [key=alarm]: condition\nnote [supersedes=resume]: resumed\n"
            (state / "task.status").write_bytes(raw)
            (state / "alert-stores").mkdir()
            store = state / "owned.json"
            (state / "alert-stores" / "owner.reg").write_text(
                f"schema=fm-alert-registration/v1\nstore=owner\npath={store}\nstatus=task.status\n")
            inputs = Inputs(str(home))
            store.write_text(json.dumps({"schema": "fm-alert-store/v1", "active": {"alarm": {}}}))
            first = inputs.fold("task")
            store.write_text(json.dumps({"schema": "fm-alert-store/v1", "active": {}}))
            second = inputs.fold("task")
            self.assertEqual(first["status"], second["status"])
            self.assertEqual(len(first["open"]), 1)
            self.assertEqual(second["open"], [])

    def test_unreadable_never_empty_success(self):
        with tempfile.TemporaryDirectory() as temporary:
            home = Path(temporary).resolve()
            (home / "state").mkdir()
            status = home / "state" / "task.status"
            os.mkfifo(status)
            with self.assertRaises(Refused):
                Inputs(str(home)).fold("task")
            status.unlink()
            status.symlink_to(home / "absent")
            with self.assertRaises(OSError):
                Inputs(str(home)).fold("task")


class IncrementalFold(unittest.TestCase):
    def test_append_partial_replacement_and_truncation_equal_full_fold(self):
        cache = FoldIndex()
        raw = b""
        fragments = [b"needs-decision [key=quota]: part", b"ial", b" note\n",
                     b"blocked [key=run]: missing daemon\n", b"note [supersedes=resume]: resumed\n",
                     b"paused [key=phase]: wait\n", b"resolved [key=other]: unrelated\n",
                     b"resolved [key=quota]: answered", b"\n", b"resolved [key=phase]: ended\n"]
        for fragment in fragments:
            previous_partial = len(raw.rsplit(b"\n", 1)[-1])
            raw += fragment
            with self.subTest(raw=raw):
                self.assertEqual(cache.fold("task", (1, 2), raw, "secondmate"), Fold(raw, "secondmate").result())
                self.assertLessEqual(cache.last_processed_bytes, len(fragment) + previous_partial)
                repeated = cache.fold("task", (1, 2), raw, "secondmate")
                self.assertEqual(repeated, Fold(raw, "secondmate").result())
                self.assertEqual(cache.last_processed_bytes, 0)
        # Same inode, shorter/truncated or rewritten bytes: never resume a cursor
        # into a previous stream. A new identity rebuilds even byte-identical data.
        for identity, changed in (((1, 2), b"needs-decision [key=new]: replacement\n"),
                                  ((1, 2), b"blocked: x"), ((1, 3), b"blocked: x")):
            self.assertEqual(cache.fold("task", identity, changed, "secondmate"), Fold(changed, "secondmate").result())
            self.assertEqual(cache.last_processed_bytes, len(changed))

    def test_context_changes_rebuild_and_results_cannot_poison_index(self):
        cache = FoldIndex()
        raw = b"blocked [key=alarm]: condition\nnote [supersedes=resume]: resumed\n"
        held = cache.fold("task", (1, 2), raw, "secondmate", protected=("alarm",))
        self.assertEqual(held["open"][0]["key"], "alarm")
        held["open"][0]["summary"] = "consumer mutation"
        again = cache.fold("task", (1, 2), raw, "secondmate", protected=("alarm",))
        self.assertEqual(again["open"][0]["summary"], "condition")
        self.assertEqual(cache.last_processed_bytes, 0)
        cleared = cache.fold("task", (1, 2), raw, "secondmate")
        self.assertEqual(cleared["open"], [])
        self.assertEqual(cache.last_processed_bytes, len(raw))
        raw = b"needs-decision: question\ndone: one item\n"
        self.assertEqual(len(cache.fold("task", (1, 2), raw, "secondmate")["open"]), 1)
        self.assertEqual(cache.fold("task", (1, 2), raw, "ship")["open"], [])
        self.assertEqual(cache.last_processed_bytes, len(raw))

    def test_bounded_eviction_is_disposable(self):
        cache = FoldIndex(max_entries=2, max_bytes=80)
        raw = b"blocked: condition\n"
        for name in ("a", "b", "c", "a"):
            self.assertEqual(cache.fold(name, (1, 2), raw), Fold(raw).result())
            self.assertLessEqual(len(cache.entries), 2)
            self.assertLessEqual(cache.bytes, 80)
        self.assertEqual(cache.last_processed_bytes, len(raw))
        too_large = b"note: " + b"x" * 100
        self.assertEqual(cache.fold("large", (1, 3), too_large), Fold(too_large).result())
        self.assertNotIn("large", cache.entries)
        self.assertLessEqual(cache.bytes, 80)


class Scheduling(unittest.IsolatedAsyncioTestCase):
    async def test_singleflight_not_completed_cache(self):
        class Fake:
            home = "/fixture"
            count = 0
            entered = threading.Event()
            release = threading.Event()
            def task_path(self, task, suffix):
                return "/fixture/" + task + suffix
            def check(self):
                pass
            def metadata(self, task):
                return {"sha256": "g1"}
            def fold(self, task, kind, vocabulary):
                self.count += 1
                self.entered.set()
                self.release.wait(5)
                return {"count": self.count}
        inputs = Fake()
        engine = Engine(inputs)
        try:
            a = asyncio.create_task(engine.request("status-fold", {"task": "task"}, 4))
            await asyncio.get_running_loop().run_in_executor(None, inputs.entered.wait, 2)
            b = asyncio.create_task(engine.request("status-fold", {"task": "task"}, 4))
            for _ in range(200):
                if engine.shared:
                    break
                await asyncio.sleep(0.005)
            self.assertEqual(engine.shared, 1)
            inputs.release.set()
            self.assertEqual(await a, await b)
            self.assertEqual(inputs.count, 1)
            self.assertEqual(await engine.request("status-fold", {"task": "task"}, 4), {"count": 2})
        finally:
            inputs.release.set()
            engine.close()

    async def test_timeout_occupies_slot_and_critical_is_reserved(self):
        ordinary = BoundedLane(1)
        critical = BoundedLane(1)
        entered = threading.Event()
        release = threading.Event()
        def hung():
            entered.set()
            release.wait(5)
        try:
            with self.assertRaises(asyncio.TimeoutError):
                await ordinary.run(hung, 0.1)
            self.assertTrue(entered.is_set())
            with self.assertRaises(Refused):
                await ordinary.run(lambda: None, 1)
            self.assertEqual(await critical.run(lambda: "delivered", 1), "delivered")
            self.assertEqual(ordinary.active, 1)
        finally:
            release.set()
            ordinary.close()
            critical.close()

    async def test_crew_generation_singleflight_and_reserved_status_lane(self):
        from unittest.mock import patch
        import fm_view_crew
        from fm_view_engine import fields
        with tempfile.TemporaryDirectory() as temporary:
            home = Path(temporary).resolve()
            state = home / "state"
            state.mkdir()
            meta = state / "task.meta"
            meta.write_text("kind=ship\nspawn_gen=g1\n")
            (state / "task.status").write_text("needs-decision [key=x]: question\n")
            inputs = Inputs(str(home))
            entered, release = threading.Event(), threading.Event()
            observed = []
            class PassiveFixture:
                def __init__(self, inputs, task, environment, expected_generation):
                    self.generation = fields(expected_generation["bytes"])["spawn_gen"]
                    observed.append((self.generation, environment.get("FM_CREW_STATE_NO_FORGE")))
                def read(self):
                    if self.generation == "g1":
                        entered.set()
                        release.wait(5)
                    return {"state": "working", "source": "fixture", "generation": self.generation}
            engine = Engine(inputs)
            try:
                with patch.object(fm_view_crew, "Crew", PassiveFixture):
                    args = {"task": "task", "options": {"FM_CREW_STATE_NO_FORGE": "1"}}
                    first = asyncio.create_task(engine.request("crew-state", args, 4))
                    await asyncio.get_running_loop().run_in_executor(None, entered.wait, 2)
                    second = asyncio.create_task(engine.request("crew-state", args, 4))
                    for _ in range(200):
                        if engine.shared:
                            break
                        await asyncio.sleep(0.005)
                    self.assertEqual(engine.shared, 1)
                    self.assertEqual(engine.ordinary.active, 1)
                    # A blocked ordinary current-state read cannot consume the
                    # separately reserved status-delivery lane.
                    folded = await engine.request("status-fold", {"task": "task"}, 2)
                    self.assertEqual(folded["open"][0]["key"], "x")
                    meta.write_text("kind=ship\nspawn_gen=g2\n")
                    replacement = await engine.request("crew-state", args, 2)
                    self.assertEqual(replacement["generation"], "g2")
                    self.assertEqual(observed, [("g1", "1"), ("g2", "1")])
                    release.set()
                    with self.assertRaises(Refused):
                        await first
                    with self.assertRaises(Refused):
                        await second
            finally:
                release.set()
                engine.close()

    @unittest.skipUnless(hasattr(socket, "SO_PEERCRED"), "native IPC not admitted here; legacy remains selected")
    async def test_real_transport_binding_and_no_authority(self):
        with tempfile.TemporaryDirectory() as temporary:
            home = Path(temporary).resolve()
            state = home / "state"
            state.mkdir()
            transport = home / "transport"
            transport.mkdir(mode=0o700)
            path = str(transport / "read.sock")
            (state / "task.meta").write_text("kind=secondmate\nspawn_gen=g1\n")
            (state / "task.status").write_bytes(b"needs-decision [key=x]: question\n")
            (state / ".watch-wake.queue").write_bytes(b"sealed queue\n")
            before = {p.name: p.read_bytes() for p in state.iterdir()}
            stop = asyncio.Event()
            service = asyncio.create_task(serve(str(home), path, "e1", stop))
            try:
                # Bounded iteration wait, isolated fixture only, no fleet poller.
                for _ in range(200):
                    if os.path.exists(path):
                        break
                    await asyncio.sleep(0.01)
                self.assertTrue(os.path.exists(path))
                call = lambda epoch="e1", verb="status-fold", args=None: client(
                    path, str(home), epoch, verb, args or {"task": "task"}, 2)
                loop = asyncio.get_running_loop()
                result = await loop.run_in_executor(None, call)
                self.assertEqual(result["open"][0]["key"], "x")
                status_info = (state / "task.status").stat()
                presentation = await loop.run_in_executor(None, lambda: call("e1", "status-presentation", {
                    "rows": [{"task": "task", "end": status_info.st_size, "offset": 0,
                              "identity": [status_info.st_dev, status_info.st_ino],
                              "classified": 0, "fully_presented": False}]}))
                self.assertEqual(presentation["rows"][0]["open"][0]["key"], "x")
                self.assertEqual(presentation["rows"][0]["acknowledged_end"], 0)
                crew = await loop.run_in_executor(None, lambda: call("e1", "crew-state", {
                    "task": "task", "options": {"FM_CREW_STATE_NO_FORGE": "1"}}))
                self.assertEqual((crew["state"], crew["source"]), ("unknown", "none"))
                self.assertIn("worktree gone", crew["detail"])
                for epoch, verb, args in (("old", "status-fold", None), ("e1", "ack", None),
                                          ("e1", "status-fold", {"task": "../other"}),
                                          ("e1", "crew-state", {"task": "task", "options": {"PATH": "/untrusted"}}),
                                          ("e1", "crew-state", {"task": "task", "options": {"FM_CREW_STATE_NO_FORGE": "x" * 33}}),
                                          ("e1", "crew-state", {"task": "task", "options": {"FM_CREW_STATE_NO_FORGE": 1}})):
                    with self.assertRaises(Refused):
                        await loop.run_in_executor(None, lambda: call(epoch, verb, args))
                self.assertEqual(before, {p.name: p.read_bytes() for p in state.iterdir()})
                (state / "task.status").write_bytes(b"resolved [key=x]: yes\n")
                self.assertEqual((await loop.run_in_executor(None, call))["open"], [])
                # A replaced state root cannot reuse the old service's authority.
                state.rename(home / "old-state")
                state.mkdir()
                with self.assertRaises(Refused):
                    await loop.run_in_executor(None, call)
            finally:
                stop.set()
                await asyncio.wait_for(service, 5)
            self.assertFalse(os.path.lexists(path))


if __name__ == "__main__":
    from crew_checks import CrewParity, PassiveProcess
    from presentation_checks import PresentationParity, PresentationScheduling
    unittest.main()
