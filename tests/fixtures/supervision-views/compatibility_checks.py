"""Real compatibility entrypoints retain stdout/identity/commit ownership."""
import asyncio
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from fm_view_engine import serve
from fm_view_presentation import Presentation

ROOT = Path(__file__).resolve().parents[3]


class Compatibility(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.home = Path(self.temporary.name).resolve()
        for name in ("state", "config", "data", "fakebin", "ipc"):
            (self.home / name).mkdir(mode=0o700)
        self.state = self.home / "state"
        (self.home / "config/supervision-host-off").touch()
        for name in ("tmux", "tasks-axi", "no-mistakes"):
            path = self.home / "fakebin" / name
            path.write_text("#!/bin/sh\nexit 1\n")
            path.chmod(0o700)
        self.path = str(self.home / "ipc/read.sock")
        self.env = {name: value for name, value in os.environ.items()
                    if not name.startswith(("FM_", "GIT_"))}
        self.env.update(FM_HOME=str(self.home), FM_ROOT_OVERRIDE=str(self.home),
                        FM_STATE_OVERRIDE=str(self.state), FM_DATA_OVERRIDE=str(self.home / "data"),
                        FM_CONFIG_OVERRIDE=str(self.home / "config"), FM_VIEW_SOCKET=self.path,
                        FM_VIEW_EPOCH="fixture", FM_WEDGE_ALARM_EXEC="discard",
                        PATH=str(self.home / "fakebin") + os.pathsep + os.environ["PATH"],
                        PYTHONDONTWRITEBYTECODE="1")
        self.stop = asyncio.Event()
        self.service = asyncio.create_task(serve(str(self.home), self.path, "fixture", self.stop))
        for _ in range(500):
            if os.path.exists(self.path):
                break
            if self.service.done():
                await self.service
            await asyncio.sleep(0.01)
        self.assertTrue(os.path.exists(self.path))

    async def asyncTearDown(self):
        self.stop.set()
        await asyncio.wait_for(self.service, 5)
        self.temporary.cleanup()

    def status(self, raw=b"note: answer\n", task="task", kind="secondmate"):
        (self.state / (task + ".meta")).write_text("kind=" + kind + "\nspawn_gen=g1\n")
        (self.state / (task + ".status")).write_bytes(raw)

    async def invoke(self, command, *arguments, native=True, output=None, **environment):
        env = dict(self.env, **environment)
        if not native:
            env.pop("FM_VIEW_SOCKET", None)
        process = await asyncio.create_subprocess_exec(
            "bash", str(ROOT / "bin" / command), *arguments, env=env,
            stdout=asyncio.subprocess.PIPE if output is None else output, stderr=asyncio.subprocess.PIPE)
        stdout, stderr = await asyncio.wait_for(process.communicate(), 40)
        self.assertEqual(process.returncode, 0, stderr)
        return stdout, stderr

    async def test_drain_transaction_uses_native_facts_and_keeps_open_decisions(self):
        self.status(b"blocked [key=x]: obstacle\nnote: answer\nworking: later\n")
        calls = []
        original = Presentation.read
        def read(instance, rows, vocabulary=None):
            calls.append(rows)
            return original(instance, rows, vocabulary)
        with patch.object(Presentation, "read", read):
            native, error = await self.invoke("fm-wake-drain.sh")
        self.assertEqual(len(calls), 1, error)
        self.assertNotIn(b"fm-view-client:", error)
        self.assertIn(b"task note: answer", native)
        self.assertIn(b"task [key=x] blocked: obstacle", native)
        cursor = (self.state / ".status-presentation-cursor").read_bytes()
        self.assertTrue(cursor.split(b"\t")[1].startswith((b"strong:", b"weak:")))
        again, _ = await self.invoke("fm-wake-drain.sh")
        self.assertNotIn(b"task note: answer", again)
        self.assertIn(b"task [key=x] blocked: obstacle", again)
        # Restore only the presentation state to compare the whole legacy
        # rendering on the identical captured bytes; native never owns it.
        (self.state / ".status-presentation-cursor").unlink()
        legacy, _ = await self.invoke("fm-wake-drain.sh", native=False)
        self.assertEqual(native, legacy)
        self.assertEqual(cursor, (self.state / ".status-presentation-cursor").read_bytes())

    @unittest.skipUnless(Path("/dev/full").exists(), "requires failing stdout device")
    async def test_failed_stdout_retries_without_advancing_cursor(self):
        self.status()
        with open("/dev/full", "wb") as full:
            await self.invoke("fm-wake-drain.sh", output=full)
        self.assertFalse((self.state / ".status-presentation-cursor").exists())
        recovered, error = await self.invoke("fm-wake-drain.sh")
        self.assertNotIn(b"fm-view-client:", error)
        self.assertIn(b"task note: answer", recovered)
        self.assertTrue((self.state / ".status-presentation-cursor").exists())

    async def test_append_after_native_capture_remains_unread(self):
        self.status()
        original = Presentation.read
        def append(instance, rows, vocabulary=None):
            result = original(instance, rows, vocabulary)
            with (self.state / "task.status").open("ab") as stream:
                stream.write(b"note: concurrent append\n")
            return result
        with patch.object(Presentation, "read", append):
            first, error = await self.invoke("fm-wake-drain.sh")
        self.assertNotIn(b"fm-view-client:", error)
        self.assertIn(b"task note: answer", first)
        self.assertNotIn(b"task note: concurrent append", first)
        second, _ = await self.invoke("fm-wake-drain.sh")
        self.assertIn(b"task note: concurrent append", second)

    async def test_socket_epoch_refusal_falls_back_before_presentation(self):
        self.status()
        result, error = await self.invoke("fm-wake-drain.sh", FM_VIEW_EPOCH="stale")
        self.assertIn(b"fm-view-client: read refused; use legacy:", error)
        self.assertIn(b"task note: answer", result)
        self.assertTrue((self.state / ".status-presentation-cursor").exists())

    async def test_crew_public_client_and_captured_override_fallback(self):
        self.status(kind="scout")
        # No worktree: this is a real native unknown answer, not a fabricated
        # empty success. Unsupported captured roots explicitly take legacy.
        native, error = await self.invoke("fm-crew-state.sh", "task")
        legacy, _ = await self.invoke("fm-crew-state.sh", "task", native=False)
        self.assertNotIn(b"fm-view-client:", error)
        self.assertEqual(native, legacy)
        overridden, error = await self.invoke("fm-crew-state.sh", "task",
                                               FM_CREW_STATE_META_OVERRIDE=str(self.state / "task.meta"))
        self.assertIn(b"captured crew inputs require legacy", error)
        self.assertEqual(overridden, legacy)
