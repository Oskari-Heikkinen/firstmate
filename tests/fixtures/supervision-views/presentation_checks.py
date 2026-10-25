"""Captured native drain facts versus the existing presentation transaction APIs."""
import asyncio
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

from fm_view_engine import Engine, Inputs, Refused
from fm_view_presentation import Presentation

ROOT = Path(__file__).resolve().parents[3]


class PresentationParity(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.home = Path(self.temporary.name).resolve()
        self.state = self.home / "state"
        self.state.mkdir()
        self.inputs = Inputs(str(self.home))

    def tearDown(self):
        self.temporary.cleanup()

    def row(self, raw, kind="secondmate", task="task", offset=0, classified=0, fully=False):
        (self.state / (task + ".meta")).write_text("kind=" + kind + "\nspawn_gen=g1\n")
        path = self.state / (task + ".status")
        path.write_bytes(raw)
        info = path.stat()
        return {"task": task, "end": len(raw), "identity": [info.st_dev, info.st_ino],
                "offset": offset, "classified": classified, "fully_presented": fully}

    def compare(self, raw, kind="secondmate", offset=0, classified=0, fully=False):
        row = self.row(raw, kind, offset=offset, classified=classified, fully=fully)
        (self.state / ".task.open-decisions-cursor").unlink(missing_ok=True)
        before = {p.name: p.read_bytes() for p in self.state.iterdir() if p.is_file()}
        native = Presentation(self.inputs).read([row])["rows"][0]
        self.assertEqual(before, {p.name: p.read_bytes() for p in self.state.iterdir() if p.is_file()})
        script = '''. "$1/bin/fm-classify-lib.sh"
f="$2/task.status"
ident=$(_fm_open_decisions_file_ident "$f") || exit 1
snapshot=$(printf 'task\\t%s\\t%s' "$3" "$ident")
printf 'task\\t%s\\t%s\\t0\\n' "$ident" "$4" > "$2/.status-presentation-cursor"
status_presentation_marker_commit "$(status_signal_seen_marker_path "$2" task)" "$f" "$5" "$ident" || exit 1
scan_unread_surface_snapshot "$2" "$snapshot" || exit 1
printf '\\0'
scan_open_decisions_snapshot "$2" "$snapshot" || exit 1
printf '\\0'
status_acknowledge_presented_snapshot "$2" "$snapshot" "$6" || exit 1
printf '\\0'
status_new_lines_since_cursor "$f" "$3" || exit 1
'''
        result = subprocess.run(["bash", "-c", script, "oracle", str(ROOT), str(self.state),
                                 str(row["end"]), str(offset), str(classified), "task" if fully else ""],
                                capture_output=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stderr)
        unread, opened, acknowledged, new_lines = result.stdout.split(b"\0")
        def encoded(lines):
            return ("\n".join(lines) + ("\n" if lines else "")).encode("utf-8", "surrogateescape")
        self.assertEqual(encoded(["task\t" + line for line in native["unread"]]), unread)
        self.assertEqual(encoded(["task\t" + "\t".join((r["key"], r["verb"], r["summary"]))
                                  for r in native["open"]]), opened)
        self.assertEqual(int(acknowledged.split(b"\t")[1]), native["acknowledged_end"])
        self.assertEqual(encoded(native["new_lines"]), new_lines)
        return native

    def test_kind_unread_and_decision_matrix(self):
        cases = [
            b"", b"working: progress\n", b"note: answer\nworking: later\n",
            b"needs-decision [key=x]: question\nnote: answer\nresolved [key=x]: settled\n",
            b"blocked [key=x]: obstacle\nnote [supersedes=resume]: continued\n",
            b"note corr=0123456789abcdef: acknowledgement\nworking: progress\n",
            b"note: reply mentioning corr=0123456789ABCDEF0\n",
            b"note corr=bad: substantive reply\n",
            b"resolved [key=pending-reply-task]: pending-reply-resolved: delivered\n",
            b"resolved [key=pending-reply-task]: unauthorized\n",
            b"captain-held [key=handoff-tj-task]: handoff-tj-ready: filed\n",
            b"\t \r\nworking: routine\nnote: \xff unfinished UTF-8",
            b"note: nul\0 byte\nneeds-decision [key=partial]: unfinished",
            b"needs-decision: question\ndone: finish\n",
        ]
        for kind in ("ship", "scout", "secondmate", "unknown"):
            for raw in cases:
                with self.subTest(kind=kind, raw=raw):
                    self.compare(raw, kind)

    def test_ack_only_presented_or_classified_contiguous_bytes(self):
        raw = b"working: first\nnote corr=0123456789abcdef: ack\nworking: later\n"
        boundary = raw.index(b"note")
        for offset, classified, fully in ((0, 0, False), (0, boundary, False),
                                           (boundary, len(raw), False), (boundary, 0, False),
                                           (len(raw), 0, False), (0, 0, True)):
            with self.subTest(offset=offset, classified=classified, fully=fully):
                self.compare(raw, offset=offset, classified=classified, fully=fully)
        # A substantive note after absorbable bytes makes the whole captured
        # contiguous span presentable; routine-only crew bytes remain unread.
        self.compare(raw + b"note: substantive answer\n")
        self.compare(b"working: routine\ndone: ordinary\n", kind="ship")
        self.compare(b"note: first\nnote: second\n", offset=5)

    def test_captured_end_append_replacement_truncation_and_all_or_nothing(self):
        row = self.row(b"needs-decision [key=old]: question\nnote: first\n")
        path = self.state / "task.status"
        with path.open("ab") as stream:
            stream.write(b"resolved [key=old]: later\nnote: appended\n")
        result = Presentation(self.inputs).read([row])["rows"][0]
        self.assertEqual([r["key"] for r in result["open"]], ["old"])
        self.assertEqual(result["unread"], ["note: first"])
        self.assertEqual(result["end"], row["end"])
        second = self.row(b"note: second task\n", task="second")
        replacement = self.state / "replacement"
        replacement.write_bytes(path.read_bytes())
        replacement.replace(path)
        with self.assertRaisesRegex(Refused, "identity changed"):
            Presentation(self.inputs).read([second, row])
        row["identity"] = [path.stat().st_dev, path.stat().st_ino]
        path.write_bytes(b"short")
        with self.assertRaisesRegex(Refused, "truncated"):
            Presentation(self.inputs).read([row])
        with self.assertRaisesRegex(Refused, "duplicate"):
            Presentation(self.inputs).read([second, second])

    def test_generation_and_prefix_barrier(self):
        row = self.row(b"note: answer\n")
        original = self.inputs.state_read
        calls = 0
        def replace_generation(task, suffix):
            nonlocal calls
            result = original(task, suffix)
            if suffix == ".status":
                calls += 1
                if calls == 1:
                    (self.state / "task.meta").write_text("kind=secondmate\nspawn_gen=g2\n")
            return result
        self.inputs.state_read = replace_generation
        with self.assertRaisesRegex(Refused, "generation changed"):
            Presentation(self.inputs).read([row])
        self.inputs.state_read = original
        calls = 0
        def rewrite_prefix(task, suffix):
            nonlocal calls
            if suffix == ".status":
                calls += 1
                if calls == 2:
                    (self.state / "task.status").write_bytes(b"note: other!\n")
            return original(task, suffix)
        self.inputs.state_read = rewrite_prefix
        with self.assertRaisesRegex(Refused, "prefix changed"):
            Presentation(self.inputs).read([row])

    def test_protection_is_fresh_and_never_uses_presentation_as_ack(self):
        import json
        row = self.row(b"blocked [key=alarm]: held\nnote [supersedes=resume]: continued\n")
        (self.state / "alert-stores").mkdir()
        store = self.state / "owned.json"
        (self.state / "alert-stores" / "owner.reg").write_text(
            f"schema=fm-alert-registration/v1\nstore=owner\npath={store}\nstatus=task.status\n")
        store.write_text(json.dumps({"schema": "fm-alert-store/v1", "active": {"alarm": {}}}))
        held = Presentation(self.inputs).read([row])["rows"][0]
        self.assertEqual(held["open"][0]["key"], "alarm")
        self.assertFalse((self.state / ".status-presentation-cursor").exists())
        store.write_text(json.dumps({"schema": "fm-alert-store/v1", "active": {}}))
        self.assertEqual(Presentation(self.inputs).read([row])["rows"][0]["open"], [])

    def test_invalid_rows_and_unknown_are_refusals(self):
        row = self.row(b"note: answer\n")
        for field, value in (("end", True), ("end", -1), ("end", 4194305),
                             ("offset", row["end"] + 1), ("identity", [1]),
                             ("fully_presented", 1), ("task", "../outside")):
            changed = dict(row, **{field: value})
            with self.subTest(field=field, value=value), self.assertRaises(Refused):
                Presentation(self.inputs).read([changed])
        with self.assertRaises(Refused):
            Presentation(self.inputs).read([row] * 257)
        (self.state / "task.status").unlink()
        os.mkfifo(self.state / "task.status")
        with self.assertRaises(Refused):
            Presentation(self.inputs).read([row])


class PresentationScheduling(unittest.IsolatedAsyncioTestCase):
    async def test_both_generation_barriers_leave_both_critical_slots_reserved(self):
        import threading
        for stalled_call, phase in ((1, "pre-observe"), (5, "pre-reply")):
            with self.subTest(phase=phase), tempfile.TemporaryDirectory() as temporary:
                home = Path(temporary).resolve()
                (home / "state").mkdir()
                batch_entered = {"batch" + str(i): threading.Event() for i in range(4)}
                critical_entered = {"critical" + str(i): threading.Event() for i in range(2)}
                release_batch, release_critical = threading.Event(), threading.Event()
                counts, count_lock = {}, threading.Lock()
                class StalledInputs(Inputs):
                    def metadata(self, task):
                        if task in batch_entered:
                            with count_lock:
                                counts[task] = counts.get(task, 0) + 1
                                count = counts[task]
                            # Real Presentation reads metadata at capture and
                            # at its batch barrier. The outer request captures
                            # it before observation (1), checks before observe
                            # (2), then rechecks before reply (5).
                            if count == stalled_call:
                                batch_entered[task].set()
                                release_batch.wait(20)
                        return super().metadata(task)
                    def fold(self, task, kind="", vocabulary=None):
                        if task in critical_entered:
                            critical_entered[task].set()
                            release_critical.wait(20)
                        return super().fold(task, kind, vocabulary)
                requests = []
                for task in list(batch_entered) + list(critical_entered):
                    (home / "state" / (task + ".meta")).write_text("kind=secondmate\nspawn_gen=g1\n")
                    (home / "state" / (task + ".status")).write_bytes(b"blocked [key=x]: held\n")
                engine = Engine(StalledInputs(str(home)), workers=4, critical_workers=2)
                async def wait_entered(events):
                    for _ in range(500):
                        if all(event.is_set() for event in events.values()):
                            return
                        await asyncio.sleep(0.01)
                    self.fail(phase + " did not enter every expected fixture stall")
                try:
                    for task in batch_entered:
                        info = (home / "state" / (task + ".status")).stat()
                        args = {"rows": [{"task": task, "end": info.st_size, "offset": 0,
                                          "identity": [info.st_dev, info.st_ino],
                                          "classified": 0, "fully_presented": False}]}
                        requests.append(asyncio.create_task(engine.request("status-presentation", args, 20)))
                    await wait_entered(batch_entered)
                    self.assertEqual(engine.ordinary.active, 4)
                    self.assertEqual(engine.critical.active, 0)
                    critical_requests = [asyncio.create_task(engine.request("status-fold", {"task": task}, 20))
                                         for task in critical_entered]
                    requests.extend(critical_requests)
                    await wait_entered(critical_entered)
                    self.assertEqual(engine.critical.active, 2)
                    self.assertEqual(engine.ordinary.active, 4)
                    release_critical.set()
                    folded = await asyncio.wait_for(asyncio.gather(*critical_requests), 5)
                    self.assertTrue(all(result["open"][0]["key"] == "x" for result in folded))
                    self.assertFalse(release_batch.is_set())
                    release_batch.set()
                    results = await asyncio.wait_for(asyncio.gather(*requests[:4]), 5)
                    self.assertTrue(all(result["rows"][0]["open"][0]["key"] == "x" for result in results))
                finally:
                    release_batch.set()
                    release_critical.set()
                    await asyncio.gather(*requests, return_exceptions=True)
                    engine.close()

    async def test_singleflight_timeout_and_status_fairness(self):
        import threading
        from unittest.mock import patch
        import fm_view_presentation
        with tempfile.TemporaryDirectory() as temporary:
            home = Path(temporary).resolve()
            (home / "state").mkdir()
            meta = home / "state/task.meta"
            meta.write_text("kind=secondmate\nspawn_gen=g1\n")
            (home / "state/task.status").write_bytes(b"blocked [key=x]: held\n")
            engine = Engine(Inputs(str(home)), workers=1)
            entered, release = threading.Event(), threading.Event()
            calls = []
            class CapturedFixture:
                def __init__(self, inputs):
                    pass
                def read(self, rows):
                    calls.append(rows)
                    entered.set()
                    release.wait(5)
                    return {"rows": []}
            try:
                with patch.object(fm_view_presentation, "Presentation", CapturedFixture):
                    args = {"rows": [{"task": "task"}]}
                    first = asyncio.create_task(engine.request("status-presentation", args, 4))
                    await asyncio.get_running_loop().run_in_executor(None, entered.wait, 2)
                    second = asyncio.create_task(engine.request("status-presentation", args, 4))
                    for _ in range(200):
                        if engine.shared:
                            break
                        await asyncio.sleep(0.005)
                    self.assertEqual(engine.shared, 1)
                    with self.assertRaises(asyncio.TimeoutError):
                        await engine.request("status-presentation", args, 0.05)
                    self.assertEqual(engine.ordinary.active, 1)
                    folded = await engine.request("status-fold", {"task": "task"}, 2)
                    self.assertEqual(folded["open"][0]["key"], "x")
                    self.assertEqual(len(calls), 1)
                    meta.write_text("kind=secondmate\nspawn_gen=g2\n")
                    release.set()
                    for pending in (first, second):
                        with self.assertRaisesRegex(Refused, "generation changed before reply"):
                            await pending
            finally:
                release.set()
                engine.close()

    async def test_batch_rpc_and_fresh_generation(self):
        with tempfile.TemporaryDirectory() as temporary:
            home = Path(temporary).resolve()
            (home / "state").mkdir()
            meta = home / "state/task.meta"
            path = home / "state/task.status"
            meta.write_text("kind=secondmate\nspawn_gen=g1\n")
            path.write_bytes(b"note: answer\n")
            args = {"rows": [{"task": "task", "end": path.stat().st_size, "offset": 0,
                              "identity": [path.stat().st_dev, path.stat().st_ino],
                              "classified": 0, "fully_presented": False}]}
            engine = Engine(Inputs(str(home)))
            try:
                first = await engine.request("status-presentation", args, 2)
                self.assertEqual(first["rows"][0]["generation"], "g1")
                meta.write_text("kind=secondmate\nspawn_gen=g2\n")
                second = await engine.request("status-presentation", args, 2)
                self.assertEqual(second["rows"][0]["generation"], "g2")
                self.assertEqual(engine.operations, 2)
                with self.assertRaises(Refused):
                    await engine.request("status-presentation", {"rows": args["rows"], "ack": True}, 2)
            finally:
                engine.close()
