"""Real compatibility entrypoints retain stdout/identity/commit ownership."""
import asyncio
import errno
import os
from pathlib import Path
import tempfile
import shutil
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

    async def test_batched_strong_snapshot_and_atomic_recapture_keep_whole_drain_parity(self):
        self.status(b"note: first\nworking: next\n", "a")
        self.status(b"blocked [key=held]: obstacle\nnote: second\n", "b")
        manifest = self.state / ".status-presentation-cursor"
        log = self.home / "batch-captures"
        stat = self.home / "fakebin/stat"
        real_stat = shutil.which("stat")
        stat.write_text('''#!/usr/bin/env python3
import os, subprocess, sys
args = sys.argv[1:]
if len(args) > 2 and args[0] == "-c" and args[1].count("\\t") == 4 and "--" in args:
    with open(os.environ["FM_FIXTURE_BATCH_LOG"], "ab") as stream:
        stream.write(b"batch\\n")
    mode = os.environ.get("FM_FIXTURE_BATCH_CORRUPT")
    count = len(open(os.environ["FM_FIXTURE_BATCH_LOG"], "rb").readlines())
    if mode == "1" or (mode == "commit" and count == 2):
        print("malformed")
        sys.exit(0)
sys.exit(subprocess.call([os.environ["FM_FIXTURE_REAL_STAT"], *args]))
''')
        stat.chmod(0o700)
        for malformed in ("0", "1", "commit"):
            with self.subTest(malformed=malformed):
                log.unlink(missing_ok=True)
                manifest.write_bytes(b"")
                calls = []
                original = Presentation.read
                def observed(instance, rows, vocabulary=None):
                    calls.append(rows)
                    return original(instance, rows, vocabulary)
                environment = {"FM_FIXTURE_BATCH_LOG": str(log), "FM_FIXTURE_REAL_STAT": real_stat,
                               "FM_FIXTURE_BATCH_CORRUPT": malformed}
                with patch.object(Presentation, "read", observed):
                    actual, error = await self.invoke("fm-wake-drain.sh", **environment)
                self.assertEqual(len(calls), 1, error)
                self.assertEqual(len(calls[0]), 2, error)
                self.assertEqual(log.read_bytes(), b"batch\nbatch\n")
                self.assertNotIn(b"fm-view-client:", error)
                diagnostic = b"native status capture refused; recapturing the complete legacy snapshot"
                if malformed == "1": self.assertIn(diagnostic, error)
                else: self.assertNotIn(diagnostic, error)
                commit_diagnostic = b"batch verification refused; using complete legacy commit"
                if malformed in ("1", "commit"): self.assertIn(commit_diagnostic, error)
                else: self.assertNotIn(commit_diagnostic, error)
                cursor = manifest.read_bytes()
                manifest.write_bytes(b"")
                expected, _ = await self.invoke("fm-wake-drain.sh", native=False, **environment)
                self.assertEqual(actual, expected)
                self.assertEqual(manifest.read_bytes(), cursor)
                self.assertEqual(log.read_bytes(), b"batch\nbatch\n", "legacy must not select either optional batch")
                self.assertIn(b"a note: first", actual)
                self.assertIn(b"b [key=held] blocked: obstacle", actual)

    async def test_native_backstop_is_fresh_and_never_reads_per_row_helpers(self):
        self.status(b"done: older\t \n", "a", "ship")
        self.status(b"blocked [key=bad key]: obstacle\n", "b", "ship")
        self.status(b"blocked [key=held]: folded not backstop\n", "c", "ship")
        manifest = self.state / ".status-presentation-cursor"
        manifest.write_bytes(b"")
        # No unread information changes in this same-size replacement; the
        # backstop must read the NEW late-phase bytes, not its initial capture.
        original_read, original_backstop = Presentation.read, Presentation.backstop
        calls = []
        def early(instance, rows, vocabulary=None):
            reply = original_read(instance, rows, vocabulary)
            path = self.state / "a.status"
            path.write_bytes(path.read_bytes().replace(b"older", b"newer"))
            return reply
        def observed(instance, rows):
            reply = original_backstop(instance, rows)
            calls.append(reply)
            return reply
        stat, perl = self.home / "fakebin/stat", self.home / "fakebin/perl"
        real_stat, real_perl = shutil.which("stat"), shutil.which("perl")
        log = self.home / "backstop-tripwire"
        stat.write_text('''#!/usr/bin/env python3
import os, subprocess, sys
args = sys.argv[1:]
if args and args[-1].endswith(".status") and len(args) > 1 and "\\t" not in args[1]:
    with open(os.environ["FM_FIXTURE_BACKSTOP_TRIPWIRE"], "ab") as f: f.write(b"stat\\n")
    sys.exit(85)
sys.exit(subprocess.call([os.environ["FM_FIXTURE_REAL_STAT"], *args]))
''')
        perl.write_text('''#!/usr/bin/env python3
import os, subprocess, sys
if any(arg.endswith(".latest") for arg in sys.argv[1:]):
    with open(os.environ["FM_FIXTURE_BACKSTOP_TRIPWIRE"], "ab") as f: f.write(b"latest\\n")
    sys.exit(85)
sys.exit(subprocess.call([os.environ["FM_FIXTURE_REAL_PERL"], *sys.argv[1:]]))
''')
        stat.chmod(0o700); perl.chmod(0o700)
        with patch.object(Presentation, "read", early), patch.object(Presentation, "backstop", observed):
            actual, error = await self.invoke("fm-wake-drain.sh", FM_FIXTURE_BACKSTOP_TRIPWIRE=str(log),
                FM_FIXTURE_REAL_STAT=real_stat, FM_FIXTURE_REAL_PERL=real_perl)
        self.assertEqual(len(calls), 1, error)
        self.assertEqual(len(calls[0]["rows"]), 3, error)
        self.assertNotIn(b"fm-view-client:", error)
        self.assertNotIn(b"complete legacy backstop", error)
        self.assertFalse(log.exists(), log.read_bytes() if log.exists() else b"")
        cursor = manifest.read_bytes()
        stat.unlink(); perl.unlink(); manifest.write_bytes(b"")
        expected, _ = await self.invoke("fm-wake-drain.sh", native=False)
        self.assertEqual(actual, expected)
        self.assertEqual(cursor, manifest.read_bytes())
        section = actual.split(b"STATUS OUTCOME BACKSTOP", 1)[1].split(b"OPEN DECISIONS", 1)[0]
        self.assertIn(b"a done: newer\t ", section)
        self.assertIn(b"b blocked [key=bad key]", section)
        self.assertNotIn(b"c blocked", section)
        self.assertNotIn(b"older", actual)

    async def test_backstop_bad_reply_or_late_mtime_change_discards_every_native_row(self):
        self.status(b"done: first\n", "a", "ship")
        self.status(b"done: other\n", "b", "ship")
        manifest = self.state / ".status-presentation-cursor"
        original = Presentation.backstop
        diagnostic = b"native backstop facts refused; using complete legacy backstop reads"
        for mode in ("receipt", "missing", "type", "mtime", "late-rewrite"):
            with self.subTest(mode=mode):
                self.status(b"done: first\n", "a", "ship")
                manifest.write_bytes(b"")
                calls = []
                def corrupt(instance, rows):
                    reply = original(instance, rows)
                    calls.append(reply)
                    # Valid poisoned unaffected row detects partial repair.
                    reply["rows"][1]["line"] = "done: bogus"
                    if mode == "receipt": reply["rows"][0]["receipt"] = 1
                    elif mode == "missing": reply["rows"].pop(0)
                    elif mode == "type": reply["rows"][0]["event_end"] = True
                    elif mode == "mtime": reply["rows"][0]["mtime"] += 1
                    else:
                        path = self.state / "a.status"
                        stamp = path.stat().st_mtime_ns + 2*10**9
                        path.write_bytes(b"done: newer\n")
                        os.utime(path, ns=(stamp, stamp))
                    return reply
                with patch.object(Presentation, "backstop", corrupt):
                    actual, error = await self.invoke("fm-wake-drain.sh")
                self.assertEqual(len(calls), 1, error)
                self.assertIn(diagnostic, error)
                cursor = manifest.read_bytes()
                manifest.write_bytes(b"")
                expected, _ = await self.invoke("fm-wake-drain.sh", native=False)
                self.assertEqual(actual, expected)
                self.assertEqual(cursor, manifest.read_bytes())
                self.assertNotIn(b"bogus", actual)
                self.assertIn(b"b done: other", actual)
                self.assertIn(b"a done: newer" if mode == "late-rewrite" else b"a done: first", actual)

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

    async def owner(self, script, *arguments):
        process = await asyncio.create_subprocess_exec(
            "bash", "-c", '. "$1/bin/fm-wake-lib.sh"; shift; ' + script, "owner", str(ROOT),
            str(self.state), *map(str, arguments), env=self.env,
            stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE)
        output, error = await asyncio.wait_for(process.communicate(), 15)
        self.assertEqual(process.returncode, 0, error)
        return output

    async def test_historical_signature_batch_preserves_marker_policy_direct_priority_and_order(self):
        tasks = ("z", "A", "missing", "bad", "old", "owned")
        for task in tasks: self.status(b"working: " + task.encode() + b"\n", task)
        for task in ("z", "A", "owned"):
            await self.owner('fm_wake_status_mark_current "$1" "$1/$2.status"', task)
        # The reported signature must not be replaced by an old classified-only
        # marker or an owned-append coverage decision.
        (self.state / ".seen-bad_status").write_bytes(b"v2\tmalformed\t-\n")
        old = await self.owner('_fm_wake_require_classify; _fm_open_decisions_file_ident "$1/old.status"')
        end = (self.state / "old.status").stat().st_size
        (self.state / ".seen-old_status").write_bytes(str(end).encode() + b"@" + old)
        await self.owner('fm_wake_status_append_self_announced "$1" "$1/owned.status" "working: owned update"')
        owned_line = (self.state / "owned.status").read_bytes().splitlines()[-1]
        # Regress only the reported observation behind the owned append. Its
        # wake suppression policy is intentionally not presentation authority.
        await self.owner('''_fm_wake_require_classify
file="$1/owned.status"
ident=$(_fm_open_decisions_file_ident "$file")
fm_wake_status_seen_commit "$1" "$file" 15 "$ident"
fm_wake_signal_seen_current "$1" "$file"
''')
        rows = b"100\t1\tsignal\tz.turn-ended\tsignal: z\n" + b"".join(
            f"100\t{i}\tsignal\t{task}.turn-ended\tsignal: {task}\n".encode()
            for i, task in enumerate(tasks[1:], 2)) + b"100\t7\tsignal\tA.status\tsignal: direct\n"
        (self.state / ".wake-queue").write_bytes(rows)
        manifest = self.state / ".status-presentation-cursor"
        log = self.home / "signature-reads"
        stat = self.home / "fakebin/stat"
        stat.write_text('''#!/usr/bin/env python3
import os, subprocess, sys
args = sys.argv[1:]
if len(args) > 1 and args[0] == "-c" and "\\n" in args[1]:
    batch = "--" in args
    with open(os.environ["FM_FIXTURE_SIGNATURE_LOG"], "ab") as stream:
        stream.write(b"batch\\n" if batch else b"row\\n")
    if batch:
        mode = os.environ.get("FM_FIXTURE_SIGNATURE_CORRUPT", "")
        if mode == "error": sys.exit(1)
        if mode == "malformed":
            print("malformed")
            sys.exit(0)
    elif not os.environ.get("FM_FIXTURE_SIGNATURE_CORRUPT"):
        print("unexpected per-row signature read", file=sys.stderr)
        sys.exit(89)
sys.exit(subprocess.call([os.environ["FM_FIXTURE_REAL_STAT"], *args]))
''')
        stat.chmod(0o700)
        calls = []
        original = Presentation.read
        def observed(instance, rows, vocabulary=None):
            calls.append(rows)
            return original(instance, rows, vocabulary)
        for locale in ("C", "C.UTF-8"):
            for mode in ("", "malformed", "error"):
                with self.subTest(locale=locale, mode=mode):
                    log.unlink(missing_ok=True)
                    manifest.write_bytes(b"")
                    env = dict(LC_ALL=locale, FM_FIXTURE_SIGNATURE_LOG=str(log),
                               FM_FIXTURE_SIGNATURE_CORRUPT=mode, FM_FIXTURE_REAL_STAT=shutil.which("stat"))
                    before = len(calls)
                    with patch.object(Presentation, "read", observed):
                        actual, error = await self.invoke("fm-wake-drain.sh", **env)
                    self.assertEqual(len(calls), before + 1, error)
                    self.assertEqual(len(calls[-1]), len(tasks), error)
                    reads = log.read_bytes().splitlines()
                    self.assertEqual(reads.count(b"batch"), 1, reads)
                    if not mode: self.assertNotIn(b"row", reads)
                    else: self.assertIn(b"row", reads)
                    diagnostic = b"signature batch refused; using complete legacy replay checks"
                    if mode: self.assertIn(diagnostic, error)
                    else: self.assertNotIn(diagnostic, error)
                    self.assertNotIn(b"fm-view-client:", error)
                    cursor = manifest.read_bytes()
                    manifest.write_bytes(b"")
                    # The ordinary legacy CLI never attempts the optional batch.
                    log.unlink()
                    legacy, _ = await self.invoke("fm-wake-drain.sh", native=False,
                        **dict(env, FM_FIXTURE_SIGNATURE_CORRUPT="allow-row"))
                    self.assertNotIn(b"batch", log.read_bytes().splitlines())
                    self.assertEqual(actual, legacy)
                    self.assertEqual(manifest.read_bytes(), cursor)
                    self.assertTrue(actual.startswith(rows))
                    annotations = [line for line in actual.split(b"\n") if line.startswith(b"wake annotation:")]
                    keys = [next(task.encode() + b".status" for task in tasks
                                 if b": " + task.encode() + b".status: " in line) for line in annotations]
                    self.assertEqual(keys, [b"A.status", b"missing.status", b"bad.status", b"old.status",
                                            b"owned.status", b"owned.status"], actual)
                    self.assertNotIn(b"historical / not necessarily the triggering event: A.status", actual)
                    self.assertIn(b"historical / not necessarily the triggering event: owned.status: " + owned_line, actual)

    async def test_historical_signature_is_observed_after_actual_enrichment_delay(self):
        self.status(b"working: before delay\n")
        status = self.state / "task.status"
        marker = self.state / ".seen-task_status"
        manifest = self.state / ".status-presentation-cursor"
        (self.state / ".wake-queue").write_bytes(b"100\t1\tsignal\ttask.turn-ended\tsignal: historical\n")
        ready = self.home / "delay-ready"
        release = self.home / "delay-release"
        sleep = self.home / "fakebin/sleep"
        sleep.write_text('''#!/usr/bin/env python3
import os, pathlib, subprocess, sys, time
if sys.argv[1:] != ["711"]:
    sys.exit(subprocess.call([os.environ["FM_FIXTURE_REAL_SLEEP"], *sys.argv[1:]]))
pathlib.Path(os.environ["FM_FIXTURE_DELAY_READY"]).touch()
for _ in range(3000):
    if pathlib.Path(os.environ["FM_FIXTURE_DELAY_RELEASE"]).exists(): sys.exit(0)
    time.sleep(0.01)
sys.exit(88)
''')
        sleep.chmod(0o700)
        calls = []
        original = Presentation.read
        def observed(instance, rows, vocabulary=None):
            calls.append(rows)
            return original(instance, rows, vocabulary)

        async def run(native, action):
            ready.unlink(missing_ok=True); release.unlink(missing_ok=True)
            manifest.write_bytes(b"")
            status.write_bytes(b"working: before delay\n")
            marker.unlink(missing_ok=True)
            if action == "append":
                await self.owner('fm_wake_status_mark_current "$1" "$1/task.status"')
            invoke = asyncio.create_task(self.invoke("fm-wake-drain.sh", native=native,
                FM_WAKE_ENRICH_TEST_DELAY="711", FM_FIXTURE_DELAY_READY=str(ready),
                FM_FIXTURE_DELAY_RELEASE=str(release), FM_FIXTURE_REAL_SLEEP=shutil.which("sleep")))
            try:
                for _ in range(2000):
                    if ready.exists() or invoke.done(): break
                    await asyncio.sleep(0.01)
                self.assertTrue(ready.exists(), "real enrichment seam never reached")
                if action == "append":
                    with status.open("ab") as stream: stream.write(b"working: appended during delay\n")
                else:
                    await self.owner('fm_wake_status_mark_current "$1" "$1/task.status"')
            finally:
                release.touch()
            output, error = await invoke
            self.assertNotIn(b"signature batch refused", error)
            return output, manifest.read_bytes()

        for action in ("append", "marker-update"):
            with self.subTest(action=action):
                before = len(calls)
                with patch.object(Presentation, "read", observed):
                    actual, cursor = await run(True, action)
                self.assertEqual(len(calls), before + 1)
                self.assertTrue(calls[-1])
                expected, legacy_cursor = await run(False, action)
                self.assertEqual(actual, expected)
                self.assertEqual(cursor, legacy_cursor)
                annotation = b"historical / not necessarily the triggering event: task.status: working: before delay"
                if action == "append": self.assertIn(annotation, actual)
                else: self.assertNotIn(b"wake annotation:", actual)
                self.assertNotIn(b"task.status: working: appended during delay", actual)

    async def test_annotation_path_guard_is_bounded_atomic_and_never_reads_spans_or_cursors(self):
        self.status(b"working: a\n", "a", kind="ship")
        self.status(b"working: b\n", "b", kind="ship")
        b = self.state / "b.status"
        protected = self.home / "protected"
        protected.write_bytes(b"outside data\n")
        cursor = self.state / ".status-presentation-cursor"
        cursor.write_bytes(b"prior cursor must not change\n")
        stat, log = self.home / "fakebin/stat", self.home / "path-admission-stat"
        stat.write_text('''#!/usr/bin/env python3
import os, pathlib, subprocess, sys
args = sys.argv[1:]
if len(args) > 2 and args[0] == "-c" and "\\t" in args[1] and "--" in args:
    with open(os.environ["FM_FIXTURE_PATH_LOG"], "ab") as stream: stream.write(b"batch\\n")
    mode = os.environ.get("FM_FIXTURE_PATH_FAULT", "")
    if mode == "error": sys.exit(1)
    run = subprocess.run([os.environ["FM_FIXTURE_REAL_STAT"], *args], capture_output=True)
    rows = run.stdout.splitlines()
    if mode == "malformed": rows = [b"malformed"]
    elif mode == "short": rows = rows[:-1]
    elif mode == "extra": rows += rows[:1]
    sys.stdout.buffer.write(b"\\n".join(rows) + b"\\n")
    sys.exit(run.returncode)
sys.exit(subprocess.call([os.environ["FM_FIXTURE_REAL_STAT"], *args]))
'''.replace('os.environ["FM_FIXTURE_REAL_STAT"]', repr(shutil.which("stat"))))
        stat.chmod(0o700)
        script = '''_fm_wake_require_classify || exit 1
_fm_status_file_size() { echo 'unexpected per-row size read' >&2; return 86; }
_fm_open_decisions_file_ident() { echo 'unexpected per-row identity read' >&2; return 86; }
fm_wake_status_cursor_offset() { echo 'unexpected cursor read' >&2; return 86; }
fm_wake_unread_events() { echo 'unexpected span read' >&2; return 86; }
if fm_wake_annotation_paths_current "$1" "$2"; then printf admitted; else printf refused; fi
'''
        for action in ("unchanged", "growth", "delete", "rotate", "truncate", "symlink", "unreadable", "directory", "fifo",
                       "malformed", "short", "extra", "error", "empty-snapshot", "duplicate", "foreign"):
            with self.subTest(action=action):
                if b.is_dir(): b.rmdir()
                elif b.is_symlink() or (b.exists() and not b.is_file()): b.unlink()
                b.write_bytes(b"working: b\n"); b.chmod(0o600)
                snapshot = await self.owner('_fm_wake_require_classify; status_presentation_snapshot "$1"')
                log.unlink(missing_ok=True)
                if action == "growth":
                    with b.open("ab") as stream: stream.write(b"working: appended\n")
                elif action == "delete": b.unlink()
                elif action == "rotate":
                    replacement = self.state / ".replacement"
                    replacement.write_bytes(b.read_bytes()); replacement.replace(b)
                elif action == "truncate": b.write_bytes(b"w")
                elif action == "symlink": b.unlink(); b.symlink_to(protected)
                elif action == "directory": b.unlink(); b.mkdir()
                elif action == "fifo": b.unlink(); os.mkfifo(b)
                elif action == "unreadable":
                    b.chmod(0)
                    self.assertFalse(os.access(b, os.R_OK), "unreadable path control is ineffective")
                elif action == "empty-snapshot": snapshot = b""
                elif action == "duplicate": snapshot += snapshot.splitlines(keepends=True)[0]
                elif action == "foreign": snapshot = snapshot.replace(b"a\t", b"foreign\t", 1)
                env = dict(self.env, FM_FIXTURE_REAL_STAT=shutil.which("stat"), FM_FIXTURE_PATH_LOG=str(log),
                           FM_FIXTURE_PATH_FAULT=action)
                process = await asyncio.create_subprocess_exec("bash", "-c",
                    '. "$1/bin/fm-wake-lib.sh"; shift; ' + script, "fixture", str(ROOT), str(self.state), snapshot,
                    env=env, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE)
                output, error = await asyncio.wait_for(process.communicate(), 15)
                self.assertEqual(process.returncode, 0, error)
                self.assertEqual(error, b"", error.decode("utf-8", "backslashreplace"))
                self.assertEqual(output, b"admitted" if action in ("unchanged", "growth") else b"refused")
                self.assertEqual(log.read_bytes() if log.exists() else b"",
                                 b"" if action == "empty-snapshot" else b"batch\n")
                self.assertEqual(cursor.read_bytes(), b"prior cursor must not change\n")
                self.assertEqual(protected.read_bytes(), b"outside data\n")
                if action == "unreadable": b.chmod(0o600)

    async def test_actual_enrichment_path_admission_preserves_whole_legacy_annotations(self):
        # The original queue case remains unchanged. Pin both sides of the
        # capture boundary here so an early refusal cannot mask late churn.
        for task in ("a", "b", "c"):
            self.status(b"working: " + task.encode() + b" context\n", task, kind="ship")
        status = self.state / "a.status"
        manifest = self.state / ".status-presentation-cursor"
        ready, release = self.home / "paths-ready", self.home / "paths-release"
        fault, triggered = self.home / "path-fault", self.home / "path-fault-triggered"
        sleep, stat = self.home / "fakebin/sleep", self.home / "fakebin/stat"
        sleep.write_text('''#!/usr/bin/env python3
import os, pathlib, subprocess, sys, time
if sys.argv[1:] != ["713"]:
    sys.exit(subprocess.call([os.environ["FM_FIXTURE_REAL_SLEEP"], *sys.argv[1:]]))
pathlib.Path(os.environ["FM_FIXTURE_DELAY_READY"]).touch()
for _ in range(3000):
    if pathlib.Path(os.environ["FM_FIXTURE_DELAY_RELEASE"]).exists(): sys.exit(0)
    time.sleep(0.01)
sys.exit(88)
''')
        sleep.chmod(0o700)
        stat.write_text('''#!/usr/bin/env python3
import os, pathlib, subprocess, sys
args = sys.argv[1:]
fault = pathlib.Path(os.environ["FM_FIXTURE_PATH_FAULT_FILE"])
if len(args) > 2 and args[0] == "-c" and "\\t" in args[1] and "--" in args and fault.exists():
    mode = fault.read_text(); fault.unlink()
    pathlib.Path(os.environ["FM_FIXTURE_PATH_TRIGGERED"]).write_text(mode)
    if mode == "error": sys.exit(1)
    print("malformed"); sys.exit(0)
sys.exit(subprocess.call([os.environ["FM_FIXTURE_REAL_STAT"], *args]))
''')
        stat.chmod(0o700)
        original, original_read = Presentation.read, Inputs.state_read
        diagnostic = b"captured paths changed or unsupported; using complete legacy annotations"
        modes = ("unchanged", "late-direct", "late-historical", "early-direct", "early-historical", "malformed", "error")
        cases = [(mode, "middle") for mode in modes]
        cases.extend((mode, "last") for mode in modes if mode.startswith(("late-", "early-")))
        for mode, placement in cases:
            with self.subTest(mode=mode, placement=placement):
                attempts, replies, deleted = [], [], []
                historical = mode.endswith("historical")
                victim = b"signal\ta." + (b"turn-ended" if historical else b"status") + b"\tsignal: disappears\n"
                later = b"signal\tc.turn-ended\tsignal: unrelated historical\n"
                raw = (b"100\t1\tsignal\tb.status\tsignal: unrelated first\n"
                       + b"100\t2\t" + (victim if placement == "middle" else later)
                       + b"100\t3\t" + (later if placement == "middle" else victim))
                (self.state / ".wake-queue").write_bytes(raw)
                def read(inputs, task, suffix):
                    if mode.startswith("early-") and task == "a" and suffix == ".status" and not deleted:
                        status.unlink(); deleted.append(True)
                    return original_read(inputs, task, suffix)
                def observed(instance, rows, vocabulary=None):
                    attempts.append(rows)
                    reply = original(instance, rows, vocabulary)
                    replies.append(reply)
                    # A valid but incomplete unaffected annotation proves the
                    # WHOLE selection is discarded, not just the deleted row.
                    if mode != "unchanged":
                        next(row for row in reply["rows"] if row["task"] == "b")["new_lines"] = []
                    return reply
                async def run(native):
                    status.write_bytes(b"working: a context\n")
                    manifest.write_bytes(b"")
                    for path in (ready, release, fault, triggered): path.unlink(missing_ok=True)
                    invoke = asyncio.create_task(self.invoke("fm-wake-drain.sh", native=native,
                        FM_WAKE_ENRICH_TEST_DELAY="713", FM_FIXTURE_DELAY_READY=str(ready),
                        FM_FIXTURE_DELAY_RELEASE=str(release), FM_FIXTURE_REAL_SLEEP=shutil.which("sleep"),
                        FM_FIXTURE_REAL_STAT=shutil.which("stat"), FM_FIXTURE_PATH_FAULT_FILE=str(fault),
                        FM_FIXTURE_PATH_TRIGGERED=str(triggered)))
                    try:
                        for _ in range(2000):
                            if ready.exists() or invoke.done(): break
                            await asyncio.sleep(0.01)
                        self.assertTrue(ready.exists(), "actual enrichment seam never reached")
                        if native:
                            self.assertEqual(len(attempts), 1)
                            self.assertEqual(len(attempts[0]), 3)
                            if not mode.startswith("early-"):
                                self.assertEqual(len(replies), 1, "late mutation must follow a successful nonempty native read")
                                self.assertEqual(len(replies[0]["rows"]), 3)
                        if mode.startswith(("late-", "early-")):
                            status.unlink(missing_ok=True)
                        elif native and mode in ("malformed", "error"):
                            fault.write_text(mode)
                    finally:
                        release.touch()
                    output, error = await invoke
                    if mode.startswith(("late-", "early-")):
                        self.assertEqual(manifest.read_bytes(), b"")
                    if native and mode.startswith("early-"):
                        self.assertEqual(len(deleted), 1)
                        self.assertEqual(replies, [])
                        self.assertIn(b"fm-view-client: read refused; use legacy: service refused: presentation status identity changed", error)
                        self.assertNotIn(diagnostic, error)
                    else:
                        self.assertNotIn(b"fm-view-client:", error, error.decode("utf-8", "backslashreplace"))
                        if native and mode != "unchanged": self.assertIn(diagnostic, error)
                        else: self.assertNotIn(diagnostic, error)
                    if native and mode in ("malformed", "error"):
                        self.assertEqual(triggered.read_text(), mode)
                        self.assertFalse(fault.exists())
                    return output, manifest.read_bytes()
                with patch.object(Presentation, "read", observed), patch.object(Inputs, "state_read", read):
                    actual, cursor = await run(True)
                # Legacy has the same original snapshot and missing path at
                # annotation time; it has no native read hook. Its deletion
                # occurs at the actual enrichment seam, never before capture.
                expected, legacy_cursor = await run(False)
                self.assertEqual(actual, expected)
                self.assertEqual(cursor, legacy_cursor)
                self.assertTrue(actual.startswith(raw))
                self.assertEqual((self.state / ".wake-queue").read_bytes(), raw)
                annotations = [line for line in actual.splitlines() if line.startswith(b"wake annotation:")]
                if mode.startswith(("late-", "early-")):
                    # The existing legacy cursor lookup aborts on a missing
                    # middle path, so c is omitted too. Keep that boundary
                    # separate from the deleted-last whole-fallback proof.
                    expected_keys = (b"b",) if placement == "middle" else (b"b", b"c")
                    self.assertNotIn(b": a.status:", b"\n".join(annotations))
                else:
                    expected_keys = (b"b", b"a", b"c")
                self.assertEqual(len(annotations), len(expected_keys), actual)
                for task, line in zip(expected_keys, annotations):
                    self.assertIn(b": " + task + b".status: working: " + task + b" context", line)
                    if task == b"c":
                        self.assertIn(b"historical / not necessarily the triggering event", line)

    async def test_late_classification_marker_guard_keeps_whole_legacy_acknowledgement_parity(self):
        self.status(b"working: first\nworking: last\n", "a")
        self.status(b"working: unchanged task\n", "b")
        (self.state / ".wake-queue").write_bytes(b"100\t1\tsignal\ta.turn-ended\tsignal: historical\n")
        manifest = self.state / ".status-presentation-cursor"
        marker = self.state / ".seen-a_status"
        ready, release = self.home / "ack-ready", self.home / "ack-release"
        sleep = self.home / "fakebin/sleep"
        sleep.write_text('''#!/usr/bin/env python3
import os, pathlib, subprocess, sys, time
if sys.argv[1:] != ["712"]:
    sys.exit(subprocess.call([os.environ["FM_FIXTURE_REAL_SLEEP"], *sys.argv[1:]]))
pathlib.Path(os.environ["FM_FIXTURE_DELAY_READY"]).touch()
for _ in range(3000):
    if pathlib.Path(os.environ["FM_FIXTURE_DELAY_RELEASE"]).exists(): sys.exit(0)
    time.sleep(0.01)
sys.exit(88)
''')
        sleep.chmod(0o700)
        calls = []
        original = Presentation.read
        diagnostic = b"classification markers changed or unsupported; using complete legacy acknowledgement preparation"

        async def run(native, action):
            ready.unlink(missing_ok=True); release.unlink(missing_ok=True)
            manifest.write_bytes(b"")
            if marker.is_dir(): marker.rmdir()
            marker.unlink(missing_ok=True)
            await self.owner('fm_wake_status_mark_current "$1" "$1/b.status"')
            if action in ("regression", "deletion", "malformed", "nonregular", "unreadable", "unsupported"):
                await self.owner('fm_wake_status_mark_current "$1" "$1/a.status"')
                if action == "unsupported":
                    classified = marker.read_bytes().rstrip(b"\n").split(b"\t")[-1]
                    marker.write_bytes(b"v2\tr1:" + b"ab" * 400 + b"\t" + classified)
            else:
                await self.owner('''_fm_wake_require_classify
ident=$(_fm_open_decisions_file_ident "$1/a.status")
fm_wake_status_seen_commit "$1" "$1/a.status" 0 "$ident"
''')
            invoke = asyncio.create_task(self.invoke("fm-wake-drain.sh", native=native,
                FM_WAKE_ENRICH_TEST_DELAY="712", FM_FIXTURE_DELAY_READY=str(ready),
                FM_FIXTURE_DELAY_RELEASE=str(release), FM_FIXTURE_REAL_SLEEP=shutil.which("sleep")))
            try:
                for _ in range(2000):
                    if ready.exists() or invoke.done(): break
                    await asyncio.sleep(0.01)
                self.assertTrue(ready.exists(), "post-native acknowledgement seam never reached")
                if action == "advance":
                    await self.owner('fm_wake_status_mark_current "$1" "$1/a.status"')
                elif action == "reported-only":
                    await self.owner('sig=$(fm_wake_signal_sig "$1/a.status"); fm_wake_status_reported_commit "$1" "$1/a.status" "$sig"')
                elif action == "regression":
                    await self.owner('''_fm_wake_require_classify
ident=$(_fm_open_decisions_file_ident "$1/a.status")
fm_wake_status_seen_commit "$1" "$1/a.status" 0 "$ident"
''')
                elif action == "deletion": marker.unlink()
                elif action == "malformed": marker.write_bytes(b"v2\tmalformed\t123@wrong\n")
                elif action == "nonregular":
                    marker.unlink(); marker.mkdir()
                elif action == "unreadable":
                    marker.chmod(0)
                    self.assertFalse(os.access(marker, os.R_OK), "unreadable-marker control is not effective")
            finally:
                release.touch()
            output, error = await invoke
            self.assertNotIn(b"fm-view-client:", error, error.decode("utf-8", "backslashreplace"))
            if native and action != "unchanged": self.assertIn(diagnostic, error)
            else: self.assertNotIn(diagnostic, error)
            return output, manifest.read_bytes()

        for action in ("unchanged", "reported-only", "advance", "regression", "deletion", "malformed", "nonregular", "unreadable", "unsupported"):
            with self.subTest(action=action):
                before = len(calls)
                def observed(instance, rows, vocabulary=None):
                    reply = original(instance, rows, vocabulary)
                    calls.append(reply)
                    unchanged = next(row for row in reply["rows"] if row["task"] == "b")
                    self.assertEqual(unchanged["acknowledged_end"], unchanged["end"])
                    # A valid conservative suggestion on the UNCHANGED task
                    # distinguishes whole-batch fallback from per-row repair.
                    if action != "unchanged": unchanged["acknowledged_end"] = 0
                    return reply
                with patch.object(Presentation, "read", observed):
                    actual, cursor = await run(True, action)
                self.assertEqual(len(calls), before + 1)
                self.assertEqual(len(calls[-1]["rows"]), 2)
                expected, legacy_cursor = await run(False, action)
                self.assertEqual(actual, expected)
                self.assertEqual(cursor, legacy_cursor)
                offsets = {row.split(b"\t")[0]: int(row.split(b"\t")[2]) for row in cursor.splitlines()}
                self.assertEqual(offsets[b"b"], (self.state / "b.status").stat().st_size)
                self.assertEqual(offsets[b"a"], (self.state / "a.status").stat().st_size if action in ("advance", "unsupported") else 0)

    async def test_malformed_classification_evidence_falls_back_before_native_selection(self):
        self.status(b"working: progress\nnote: answer\n")
        manifest = self.state / ".status-presentation-cursor"
        manifest.write_bytes(b"")
        original = Presentation.read_from_snapshot
        for corruption in ("missing", "count", "binding", "type", "oversize", "nul", "newline"):
            with self.subTest(corruption=corruption):
                manifest.write_bytes(b"")
                calls = []
                def corrupt(instance, rows):
                    reply = original(instance, rows)
                    calls.append(reply)
                    if corruption == "missing": del reply["classification_markers"]
                    elif corruption == "count": reply["classification_markers"] = []
                    else:
                        evidence = reply["classification_markers"][0]
                        if corruption == "binding": evidence["task"] = "foreign"
                        elif corruption == "type": evidence["text"] = True
                        elif corruption == "oversize": evidence["text"] = "x" * 4097
                        elif corruption == "nul": evidence["text"] = "x\0y"
                        elif corruption == "newline": evidence["text"] = "x\n"
                    return reply
                with patch.object(Presentation, "read_from_snapshot", corrupt):
                    actual, error = await self.invoke("fm-wake-drain.sh")
                self.assertEqual(len(calls), 1, error)
                self.assertIn(b"fm-view-client: read refused; use legacy:", error)
                self.assertIn(b"classification marker evidence", error)
                self.assertNotIn(b"using complete legacy acknowledgement preparation", error)
                cursor = manifest.read_bytes()
                manifest.write_bytes(b"")
                expected, _ = await self.invoke("fm-wake-drain.sh", native=False)
                self.assertEqual(actual, expected)
                self.assertEqual(cursor, manifest.read_bytes())

    async def test_corrupt_private_marker_output_keeps_complete_legacy_presentation(self):
        self.status(b"working: captured\nnote: answer\n")
        (self.state / ".wake-queue").write_bytes(b"100\t1\tsignal\ttask.status\tsignal: direct\n")
        manifest = self.state / ".status-presentation-cursor"
        wrapper = self.home / "fakebin/python3"
        marker = self.home / "corrupted-marker-output"
        for corruption in ("missing", "duplicate", "foreign", "hex", "odd", "extra", "oversize"):
            with self.subTest(corruption=corruption):
                manifest.write_bytes(b"")
                marker.unlink(missing_ok=True)
                wrapper.write_text(f'''#!{sys.executable}
import subprocess, sys
from pathlib import Path
run = subprocess.run([{sys.executable!r}] + sys.argv[1:], stdout=subprocess.PIPE)
output = run.stdout
if run.returncode == 0 and sys.argv[1].endswith("fm-view-client.py"):
    lines = output.splitlines(keepends=True)
    rows = [line for line in lines if line.startswith(b"M\\t")]
    assert len(rows) == 1, output
    corruption = {corruption!r}
    row = rows[0]
    if corruption == "missing": row = b""
    elif corruption == "duplicate": row += row
    elif corruption == "foreign": row = b"M\\tother\\t-\\n"
    elif corruption == "hex": row = b"M\\ttask\\th:xyz0\\n"
    elif corruption == "odd": row = b"M\\ttask\\th:0\\n"
    elif corruption == "extra": row = b"M\\ttask\\t-\\textra\\n"
    elif corruption == "oversize": row = b"M\\ttask\\th:" + b"00" * 4097 + b"\\n"
    output = b"".join(line for line in lines if not line.startswith(b"M\\t")) + row
    Path({str(marker)!r}).write_bytes(output)
sys.stdout.buffer.write(output)
sys.exit(run.returncode)
''')
                wrapper.chmod(0o700)
                calls = []
                original = Presentation.read
                def observed(instance, rows, vocabulary=None):
                    calls.append(rows)
                    return original(instance, rows, vocabulary)
                with patch.object(Presentation, "read", observed):
                    actual, error = await self.invoke("fm-wake-drain.sh")
                self.assertTrue(marker.exists(), error)
                self.assertEqual(len(calls), 1, error)
                self.assertIn(b"malformed native classification evidence; using legacy presentation", error)
                cursor = manifest.read_bytes()
                manifest.write_bytes(b"")
                expected, _ = await self.invoke("fm-wake-drain.sh", native=False)
                self.assertEqual(actual, expected)
                self.assertEqual(cursor, manifest.read_bytes())

    async def test_captured_renderer_loads_classifier_only_for_nonempty_inventory(self):
        self.status(b"working: captured\n")
        snapshot = await self.owner('_fm_wake_require_classify; status_presentation_snapshot "$1"')
        captured = b"task\tworking: captured\n"
        script = '''. "$1/bin/fm-wake-lib.sh"
fm_wake_status_cursor_offset() { echo 'unexpected cursor read' >&2; return 1; }
fm_wake_unread_events() { echo 'unexpected span read' >&2; return 1; }
if [ "$4" = no-classifier ]; then
  _fm_wake_require_classify() { echo 'unexpected classifier load' >&2; return 1; }
fi
fm_wake_print_annotations "$2" "$5" "$3"
'''
        for case in ("empty", "direct", "historical", "reported"):
            with self.subTest(case=case):
                if case == "reported": await self.owner('fm_wake_status_mark_current "$1" "$1/task.status"')
                rows = b"" if case == "empty" else b"100\t1\tsignal\ttask." + (b"status" if case == "direct" else b"turn-ended") + b"\tsignal: event\n"
                process = await asyncio.create_subprocess_exec("bash", "-c", script, "fixture", str(ROOT), rows, captured,
                    "no-classifier" if case == "empty" else "allow-classifier", snapshot,
                    env=self.env, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE)
                output, error = await asyncio.wait_for(process.communicate(), 15)
                self.assertEqual(process.returncode, 0, error)
                self.assertEqual(error, b"", error.decode("utf-8", "backslashreplace"))
                if case in ("empty", "reported"): self.assertEqual(output, b"")
                else:
                    prefix = b"wake annotation: latest wake-EVENT observed at drain, not current state"
                    if case == "historical": prefix += b"; historical / not necessarily the triggering event"
                    self.assertEqual(output, prefix + b": task.status: working: captured\n")

    @unittest.skipUnless(Path("/dev/full").exists(), "requires failing stdout device")
    async def test_late_ack_fallback_failed_stdout_preserves_cursor_and_retries(self):
        self.status(b"working: captured\n")
        manifest = self.state / ".status-presentation-cursor"
        manifest.write_bytes(b"")
        calls = []
        original = Presentation.read
        marker = self.state / ".seen-task_status"
        diagnostic = b"using complete legacy acknowledgement preparation"
        prior_cursor = manifest.read_bytes()

        def mark_current():
            process = subprocess.run(["bash", "-c", '. "$1/bin/fm-wake-lib.sh"; fm_wake_status_mark_current "$2" "$2/task.status"',
                "fixture", str(ROOT), str(self.state)], env=self.env, capture_output=True, timeout=15)
            self.assertEqual(process.returncode, 0, process.stderr)

        def update(instance, rows, vocabulary=None):
            reply = original(instance, rows, vocabulary)
            calls.append(reply)
            mark_current()
            return reply

        codes = []
        for native in (False, True):
            with self.subTest(native=native):
                manifest.write_bytes(prior_cursor)
                marker.unlink(missing_ok=True)
                env = dict(self.env, LC_ALL="C")
                if not native:
                    env.pop("FM_VIEW_SOCKET")
                    # Legacy has no native capture seam: publish the same
                    # marker its acknowledgement preparation must observe.
                    await asyncio.to_thread(mark_current)
                with patch.object(Presentation, "read", update), open("/dev/full", "wb") as full:
                    process = await asyncio.create_subprocess_exec("bash", str(ROOT / "bin/fm-wake-drain.sh"),
                        env=env, stdout=full, stderr=asyncio.subprocess.PIPE)
                    _, error = await asyncio.wait_for(process.communicate(), 40)
                codes.append(process.returncode)
                # Supplemental presentation failure is nonfatal to the public
                # drain, but must be visible and never commit its cursor.
                self.assertEqual(process.returncode, 0, error)
                self.assertIn(b"cat: write error: No space left on device", error)
                self.assertNotIn(b"fm-view-client:", error)
                if native: self.assertIn(diagnostic, error)
                else: self.assertNotIn(diagnostic, error)
                self.assertEqual(manifest.read_bytes(), prior_cursor)
        self.assertEqual(codes, [0, 0])
        self.assertEqual(len(calls), 1)
        self.assertTrue(calls[0]["rows"])
        actual, error = await self.invoke("fm-wake-drain.sh")
        self.assertNotIn(b"using complete legacy acknowledgement preparation", error)
        cursor = manifest.read_bytes()
        manifest.write_bytes(b"")
        expected, _ = await self.invoke("fm-wake-drain.sh", native=False)
        self.assertEqual(actual, expected)
        self.assertEqual(cursor, manifest.read_bytes())
        self.assertIn(b"task working: captured", actual)

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
        for task in ("task", "A-task", "z-task"):
            self.status(task=task)
        snapshot = await self.owner('_fm_wake_require_classify; status_presentation_snapshot "$1"')
        script = '''. "$1/bin/fm-wake-lib.sh"
fm_wake_status_cursor_offset() { echo 'unexpected cursor read' >&2; return 1; }
fm_wake_unread_events() { echo 'unexpected span read' >&2; return 1; }
fm_wake_print_annotations "$2" "$4" "$3"
'''
        # Include leading/trailing tabs, CR, invalid UTF-8 and duplicate latest
        # lines; each output must retain all bytes except the legacy tr mapping.
        row = (b"100\t1\tsignal\tz-task.status\tsignal: z\n"
               b"100\t2\tsignal\ttask.status\tsignal: direct\n"
               b"100\t3\tsignal\tA-task.status\tsignal: A\n"
               b"100\t4\tsignal\tmissing.status\tsignal: absent capture")
        captured = b"A-task\tfirst group\ntask\t\tfirst\t\r\ntask\tlast\ntask\tlast\nz-task\tlast group\n"
        process = await asyncio.create_subprocess_exec(
            "bash", "-c", script, "fixture", str(ROOT), row, captured, snapshot,
            env=self.env, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE)
        output, error = await asyncio.wait_for(process.communicate(), 10)
        self.assertEqual(process.returncode, 0, error)
        self.assertEqual(error, b"", error.decode("utf-8", "backslashreplace"))
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
