"""Real compatibility entrypoints retain stdout/identity/commit ownership."""
import asyncio
import errno
import os
from pathlib import Path
import tempfile
import subprocess
import sys
import unittest
from unittest.mock import patch

from fm_view_engine import Inputs, serve
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

    async def test_resident_drain_growth_replacement_and_cache_independence(self):
        self.status(b"needs-decision [key=x]: question\nnote: initial answer\nworking: later\n")
        manifest = self.state / ".status-presentation-cursor"
        manifest.write_bytes(b"")  # explicit start, never legacy migration seeding
        cache = self.state / ".task.open-decisions-cursor"
        status = self.state / "task.status"
        calls = []
        original = Presentation.read

        def observed(instance, rows, vocabulary=None):
            reply = original(instance, rows, vocabulary)
            calls.append(reply)
            return reply

        async def compare(label, present, absent=()):
            # An obsolete/poisoned legacy fold cache is not native authority.
            # Native must neither consume nor rewrite it. Legacy refolds it.
            sentinel = b"version=3\noffset=999999\nident=obsolete\nforeign\tblocked\tpoison\n"
            cache.write_bytes(sentinel)
            before = manifest.read_bytes()
            count = len(calls)
            with patch.object(Presentation, "read", observed):
                actual, error = await self.invoke("fm-wake-drain.sh")
            self.assertEqual(len(calls), count + 1, (label, error))
            self.assertNotIn(b"fm-view-client:", error, label)
            self.assertEqual(cache.read_bytes(), sentinel, label)
            endpoint = manifest.read_bytes()
            manifest.write_bytes(before)
            expected, _ = await self.invoke("fm-wake-drain.sh", native=False)
            self.assertEqual(actual, expected, label)
            self.assertEqual(manifest.read_bytes(), endpoint, label)
            for text in present:
                self.assertIn(text, actual, label)
            for text in absent:
                self.assertNotIn(text, actual, label)

        await compare("bootstrap", (b"task [key=x]", b"task note: initial answer"), (b"poison",))
        for round_number in range(3):
            with status.open("ab") as stream:
                stream.write(b"working: growing log\n" * 20)
            await compare("growth " + str(round_number), (b"task [key=x]",), (b"task note: initial answer",))
        with status.open("ab") as stream:
            stream.write(b"resolved [key=x]: answered\nnote: new answer\nworking: later\n")
        await compare("resolve", (b"task note: new answer",), (b"task [key=x]", b"task note: initial answer"))
        status.write_bytes(b"blocked [key=y]: truncated\nnote: rewritten\nworking: later\n")
        await compare("truncate", (b"task [key=y] blocked: truncated", b"task note: rewritten"), (b"task [key=x]",))
        rotated = status.read_bytes().replace(b"truncated", b"rotated!!")
        replacement = self.state / ".replacement"
        replacement.write_bytes(rotated)
        self.assertEqual(len(rotated), status.stat().st_size)
        replacement.replace(status)
        await compare("same-size rotation", (b"task [key=y] blocked: rotated!!", b"task note: rewritten"), (b"truncated",))
        # A task-kind change must invalidate the resident fold even without a
        # status change; done is item completion for a mate but terminal for ship.
        status.write_bytes(b"blocked [key=z]: before completion\ndone: completed\nnote: after\nworking: later\n")
        await compare("mate terminal", (b"task [key=z]",))
        (self.state / "task.meta").write_text("kind=ship\nspawn_gen=g1\n")
        await compare("kind change without status append", (), (b"task [key=z]",))

    async def test_overbound_status_falls_back_with_complete_output_and_cursor_parity(self):
        self.status(b"note: " + b"x" * 70000 + b"\nworking: routine\n")
        manifest = self.state / ".status-presentation-cursor"
        manifest.write_bytes(b"")
        calls = []
        original = Presentation.read

        def observed(instance, rows, vocabulary=None):
            calls.append(True)
            return original(instance, rows, vocabulary)

        with patch.object(Presentation, "read", observed):
            actual, error = await self.invoke("fm-wake-drain.sh")
        self.assertEqual(calls, [True], error)
        self.assertIn(b"native status line bound exceeded; use legacy", error)
        endpoint = manifest.read_bytes()
        manifest.write_bytes(b"")
        expected, _ = await self.invoke("fm-wake-drain.sh", native=False)
        self.assertEqual(actual, expected)
        self.assertEqual(manifest.read_bytes(), endpoint)
        self.assertIn(b"task note: " + b"x" * 70000, actual)
        again, _ = await self.invoke("fm-wake-drain.sh")
        self.assertNotIn(b"task note:", again)

    async def test_queued_annotations_share_capture_with_fold_and_keep_legacy_bytes(self):
        raw = (b"working: first\n\tindented\tvalue\r \n\n\v\f\r\t\n"
               b"note: \xff answer\t \r\nworking: repeated\nworking: repeated")
        self.status(raw)
        queue = self.state / ".wake-queue"
        queue.write_bytes(b"100\t1\tsignal\ttask.turn-ended\tsignal: historical\n"
                          b"100\t2\tsignal\ttask.status\tsignal: direct\n")
        calls = []
        original = Presentation.read
        def read(instance, rows, vocabulary=None):
            calls.append(rows)
            return original(instance, rows, vocabulary)
        with patch.object(Presentation, "read", read):
            native, error = await self.invoke("fm-wake-drain.sh")
        self.assertEqual(len(calls), 1, error)
        self.assertNotIn(b"fm-view-client:", error)
        annotations = [line for line in native.split(b"\n") if line.startswith(b"wake annotation:")]
        self.assertEqual(len(annotations), 5, native)
        self.assertIn(b"task.status:  indented value  ", annotations[1])
        self.assertIn(b"task.status: note: \xff answer   ", annotations[2])
        self.assertTrue(all(b"latest wake-EVENT" in line for line in annotations[-2:]))
        cursor = (self.state / ".status-presentation-cursor").read_bytes()
        (self.state / ".status-presentation-cursor").unlink()
        legacy, _ = await self.invoke("fm-wake-drain.sh", native=False)
        self.assertEqual(native, legacy)
        self.assertEqual(cursor, (self.state / ".status-presentation-cursor").read_bytes())
        again, _ = await self.invoke("fm-wake-drain.sh")
        self.assertNotIn(b"wake annotation:", again)

    async def test_early_symlink_refusal_matches_legacy_cursor_refusal_and_raw_rows(self):
        # This is deliberately NOT the original late Perl-reader race. A swap
        # before fallback makes the legacy cursor lookup refuse before it can
        # reach the independent historical row. Pin that parity, not a new rule.
        raw = b"working: first\n\ndone: latest event\n"
        self.status(raw, kind="ship")
        self.status(b"working: old turn-end context\n", task="turn-only", kind="ship")
        secret = self.home / "outside-secret"
        secret.write_bytes(b"must-not-be-read\n")
        status = self.state / "task.status"
        (self.state / "escape.status").symlink_to(secret)
        rows = b"".join(f"100\t{seq}\t{kind}\t{key}\t{payload}\n".encode() for seq, (kind, key, payload) in enumerate((
            ("signal", "task.status", "signal: " + str(secret)),
            ("signal", "task.turn-ended", "signal: " + str(secret)),
            ("signal", "turn-only.turn-ended", "signal: " + str(secret)),
            ("signal", "escape.status", "signal: " + str(secret)),
            ("signal", "arbitrary-key", "signal: " + str(secret)),
            ("check", "task.check.sh", "check: complete payload"),
            ("stale", "test:fm-task", "stale: test:fm-task"),
            ("heartbeat", "heartbeat", "heartbeat"),
        ), 1))
        (self.state / ".wake-queue").write_bytes(rows)
        manifest = self.state / ".status-presentation-cursor"
        manifest.write_bytes(b"")

        def cursor():
            # Probe the real legacy cursor API on the exact attacked path at
            # the swap boundary. If it succeeds, the causal explanation is
            # falsified even if the two complete drain outputs happen to match.
            return subprocess.run(["bash", "-c", '. "$1"; status_presentation_cursor_offset "$2"', "_",
                                   str(ROOT / "bin/fm-classify-lib.sh"), str(status)],
                                  env=self.env, capture_output=True, timeout=10)

        status.unlink()
        status.symlink_to(secret)
        refused = await asyncio.to_thread(cursor)
        self.assertEqual(refused.returncode, 1, refused.stderr)
        self.assertEqual(refused.stdout, b"")
        expected, _ = await self.invoke("fm-wake-drain.sh", native=False)
        self.assertEqual(manifest.read_bytes(), b"")
        status.unlink()
        status.write_bytes(raw)
        accepted = await asyncio.to_thread(cursor)
        self.assertEqual(accepted.returncode, 0, accepted.stderr)
        self.assertEqual(accepted.stdout, b"0")
        swapped = []
        original = Inputs.state_read

        def read(inputs, task, suffix):
            if inputs.task_path(task, suffix) == status and not swapped:
                status.unlink()
                status.symlink_to(secret)
                swapped.append(cursor())
            # Actual O_NOFOLLOW must refuse; do not synthesize a transport error.
            return original(inputs, task, suffix)

        with patch.object(Inputs, "state_read", read):
            actual, error = await self.invoke("fm-wake-drain.sh")
        self.assertEqual(len(swapped), 1, error)
        self.assertEqual(swapped[0].returncode, 1, swapped[0].stderr)
        self.assertEqual(swapped[0].stdout, b"")
        refusal = (f"fm-view-client: read refused; use legacy: service refused: "
                   f"[Errno {errno.ELOOP}] {os.strerror(errno.ELOOP)}: 'task.status'").encode()
        self.assertIn(refusal, error)
        self.assertEqual(actual, expected)
        for label, output in (("native fallback", actual), ("early-swap legacy", expected)):
            with self.subTest(path=label):
                self.assertEqual(b"".join(line + b"\n" for line in output.split(b"\n")
                                          if len(line.split(b"\t")) == 5), rows)
                self.assertEqual(sum(line.startswith(b"wake annotation:") for line in output.split(b"\n")), 0)
                self.assertNotIn(b"historical / not necessarily the triggering event: turn-only.status:", output)
                self.assertNotIn(b"must-not-be-read", output)
        self.assertNotIn(b"must-not-be-read", error)
        self.assertEqual(secret.read_bytes(), b"must-not-be-read\n")
        self.assertEqual(manifest.read_bytes(), b"")
        self.assertEqual((self.state / ".wake-queue").read_bytes(), rows)

    async def test_native_annotation_index_keeps_queue_order_across_tasks(self):
        for task in ("A-task", "a.task", "z-task"):
            self.status(b"working: " + task.encode() + b"\n", task=task)
        order = ("z-task", "A-task", "a.task")
        (self.state / ".wake-queue").write_text("".join(
            f"100\t{i}\tsignal\t{task}.status\tsignal: {task}\n" for i, task in enumerate(order, 1)))
        native, error = await self.invoke("fm-wake-drain.sh")
        self.assertNotIn(b"fm-view-client:", error)
        annotations = [line for line in native.split(b"\n") if line.startswith(b"wake annotation:")]
        self.assertEqual(len(annotations), 3)
        for task, line in zip(order, annotations):
            self.assertTrue(line.endswith(task.encode() + b".status: working: " + task.encode()), line)
        cursor = (self.state / ".status-presentation-cursor").read_bytes()
        (self.state / ".status-presentation-cursor").unlink()
        legacy, _ = await self.invoke("fm-wake-drain.sh", native=False)
        self.assertEqual(native, legacy)
        self.assertEqual(cursor, (self.state / ".status-presentation-cursor").read_bytes())

    async def test_malformed_client_annotation_order_falls_back_before_native_selection(self):
        for task in ("A-task", "z-task"):
            self.status(b"note: " + task.encode() + b" answer\n", task=task)
        (self.state / ".wake-queue").write_bytes(
            b"100\t1\tsignal\tA-task.status\tsignal: A\n"
            b"100\t2\tsignal\tz-task.status\tsignal: z\n")
        legacy, _ = await self.invoke("fm-wake-drain.sh", native=False)
        cursor_path = self.state / ".status-presentation-cursor"
        expected_cursor = cursor_path.read_bytes()
        # The legacy fold has now populated its migration cursor at EOF. An
        # absent manifest would seed from that cursor and supply zero N rows,
        # never reaching the malformed-order control. An empty manifest means
        # missing task rows start at byte zero, as on the first drain.
        cursor_path.write_bytes(b"")
        # Interpose only the compatibility-client process, preserving a real
        # socket observation and its valid A/U/O facts. Reverse the two N task
        # groups after that client succeeds. On the pre-fix drain, renderer
        # refusal loses all annotations/sections and leaves no cursor: this
        # whole-output/cursor assertion therefore catches late validation.
        marker = self.home / "malformed-client-output"
        wrapper = self.home / "fakebin/python3"
        wrapper.write_text(f'''#!{sys.executable}
import subprocess
import sys
from pathlib import Path
run = subprocess.run([{sys.executable!r}] + sys.argv[1:], stdout=subprocess.PIPE)
output = run.stdout
if run.returncode == 0 and sys.argv[1].endswith("fm-view-client.py"):
    lines = output.splitlines(keepends=True)
    annotations = [line for line in lines if line.startswith(b"N\\t")]
    assert len(annotations) == 2, output
    output = b"".join(line for line in lines if not line.startswith(b"N\\t")) + b"".join(reversed(annotations))
    Path({str(marker)!r}).write_bytes(output)
sys.stdout.buffer.write(output)
sys.exit(run.returncode)
''')
        wrapper.chmod(0o700)
        calls = []
        original = Presentation.read
        def read(instance, rows, vocabulary=None):
            calls.append(rows)
            return original(instance, rows, vocabulary)
        with patch.object(Presentation, "read", read):
            actual, error = await self.invoke("fm-wake-drain.sh")
        self.assertEqual(len(calls), 1, error)
        self.assertTrue(marker.exists(), error)
        emitted = [line for line in marker.read_bytes().split(b"\n") if line.startswith(b"N\t")]
        self.assertTrue(emitted[0].startswith(b"N\tz-task\t"))
        self.assertTrue(emitted[1].startswith(b"N\tA-task\t"))
        self.assertIn(b"malformed native annotation facts; using legacy presentation", error)
        self.assertEqual(actual, legacy)
        self.assertEqual(cursor_path.read_bytes(), expected_cursor)

    async def test_regressive_service_reply_is_refused_by_real_client_before_selection(self):
        self.status(b"note: already handled\n")
        await self.invoke("fm-wake-drain.sh")
        cursor = self.state / ".status-presentation-cursor"
        original_cursor = cursor.read_bytes()
        with (self.state / "task.status").open("ab") as stream:
            stream.write(b"note: new answer\n")
        legacy, _ = await self.invoke("fm-wake-drain.sh", native=False)
        expected_cursor = cursor.read_bytes()
        original = Presentation.read
        for changed in ({"acknowledged_end": 0}, {"observed_offset": True}):
            cursor.write_bytes(original_cursor)
            calls = []
            def corrupt(instance, rows, vocabulary=None):
                calls.append(rows)
                result = original(instance, rows, vocabulary)
                self.assertGreater(result["rows"][0]["observed_offset"], 0)
                result["rows"][0].update(changed)
                return result
            with self.subTest(changed=changed), patch.object(Presentation, "read", corrupt):
                actual, error = await self.invoke("fm-wake-drain.sh")
                self.assertEqual(len(calls), 1, error)
                self.assertIn(b"fm-view-client: read refused; use legacy:", error)
                self.assertEqual(actual, legacy)
                self.assertEqual(cursor.read_bytes(), expected_cursor)

    async def test_independent_owner_guard_refuses_client_output_that_rewinds_or_malforms_cursor(self):
        self.status(b"note: already handled\n")
        await self.invoke("fm-wake-drain.sh")
        cursor = self.state / ".status-presentation-cursor"
        original_cursor = cursor.read_bytes()
        with (self.state / "task.status").open("ab") as stream:
            stream.write(b"note: new answer\n")
        legacy, _ = await self.invoke("fm-wake-drain.sh", native=False)
        expected_cursor = cursor.read_bytes()
        marker = self.home / "corrupted-client-endpoints"
        wrapper = self.home / "fakebin/python3"
        # Preserve real IPC AND the real successful client's reply checks.
        # Corrupt only the private A records after client validation; the
        # independent owner-side guard must not trust this output as authority.
        for corruption in ("rewind", "duplicate", "missing", "foreign", "identity", "past-end"):
            cursor.write_bytes(original_cursor)
            marker.unlink(missing_ok=True)
            wrapper.write_text(f'''#!{sys.executable}
import subprocess
import sys
from pathlib import Path
run = subprocess.run([{sys.executable!r}] + sys.argv[1:], stdout=subprocess.PIPE)
output = run.stdout
if run.returncode == 0 and sys.argv[1].endswith("fm-view-client.py"):
    lines = output.splitlines(keepends=True)
    rows = [line for line in lines if line.startswith(b"A\\t")]
    assert len(rows) == 1, output
    fields = rows[0].rstrip(b"\\n").split(b"\\t")
    assert int(fields[2]) > 0
    corruption = {corruption!r}
    if corruption == "rewind":
        fields[2] = b"0"
    elif corruption == "foreign":
        fields[1] = b"other-task"
    elif corruption == "identity":
        fields[3] = b"weak:1:2"
    elif corruption == "past-end":
        fields[2] = b"4194304"
    row = b"\\t".join(fields) + b"\\n"
    if corruption == "duplicate":
        row += row
    elif corruption == "missing":
        row = b""
    output = b"".join(line for line in lines if not line.startswith(b"A\\t")) + row
    Path({str(marker)!r}).write_bytes(output)
sys.stdout.buffer.write(output)
sys.exit(run.returncode)
''')
            wrapper.chmod(0o700)
            calls = []
            original = Presentation.read
            def read(instance, rows, vocabulary=None):
                calls.append(rows)
                return original(instance, rows, vocabulary)
            with self.subTest(corruption=corruption), patch.object(Presentation, "read", read):
                actual, error = await self.invoke("fm-wake-drain.sh")
                self.assertTrue(marker.exists(), error)
                self.assertEqual(len(calls), 1, error)
                self.assertIn(b"malformed or regressive native endpoints; using legacy presentation", error)
                self.assertEqual(actual, legacy)
                self.assertEqual(cursor.read_bytes(), expected_cursor)

    async def test_native_annotation_rendering_never_reopens_a_span_or_cursor(self):
        self.status()
        script = '''. "$1/bin/fm-wake-lib.sh"
fm_wake_status_cursor_offset() { echo 'unexpected cursor read' >&2; return 1; }
fm_wake_unread_events() { echo 'unexpected span read' >&2; return 1; }
fm_wake_print_annotations "$2" '' "$3"
'''
        # Include leading/trailing tabs, CR, invalid UTF-8 and duplicate latest
        # lines; each output must retain all bytes except the legacy tr mapping.
        row = (b"100\t1\tsignal\tz-task.status\tsignal: z\n"
               b"100\t2\tsignal\ttask.status\tsignal: direct\n"
               b"100\t3\tsignal\tA-task.status\tsignal: A\n"
               b"100\t4\tsignal\tmissing.status\tsignal: absent capture")
        captured = b"A-task\tfirst group\ntask\t\tfirst\t\r\ntask\tlast\ntask\tlast\nz-task\tlast group\n"
        process = await asyncio.create_subprocess_exec(
            "bash", "-c", script, "fixture", str(ROOT), row, captured,
            env=self.env, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE)
        output, error = await asyncio.wait_for(process.communicate(), 10)
        self.assertEqual(process.returncode, 0, error)
        self.assertEqual(error, b"")
        self.assertEqual(output, b"wake annotation: latest wake-EVENT observed at drain, not current state: z-task.status: last group\n"
                         + b"wake annotation: unread wake-EVENT since last drain, not current state: task.status:  first  \n"
                         + b"wake annotation: latest wake-EVENT observed at drain, not current state: task.status: last\n" * 2
                         + b"wake annotation: latest wake-EVENT observed at drain, not current state: A-task.status: first group\n")

    async def test_annotation_uses_captured_endpoint_when_append_arrives(self):
        self.status(b"working: captured\n")
        (self.state / ".wake-queue").write_bytes(b"100\t1\tsignal\ttask.status\tsignal: direct\n")
        original = Presentation.read
        def append(instance, rows, vocabulary=None):
            result = original(instance, rows, vocabulary)
            with (self.state / "task.status").open("ab") as stream:
                stream.write(b"note: appended after capture\n")
            return result
        with patch.object(Presentation, "read", append):
            first, error = await self.invoke("fm-wake-drain.sh")
        self.assertNotIn(b"fm-view-client:", error)
        self.assertIn(b"task.status: working: captured", first)
        self.assertNotIn(b"appended after capture", first)
        second, _ = await self.invoke("fm-wake-drain.sh")
        self.assertIn(b"task.status: note: appended after capture", second)

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
