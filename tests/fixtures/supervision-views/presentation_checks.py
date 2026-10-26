"""Captured native drain facts versus the existing presentation transaction APIs."""
import asyncio
import json
import os
from pathlib import Path
import subprocess
import shutil
import tempfile
import unittest

from fm_view_engine import Engine, Inputs, Refused
from fm_view_presentation import Presentation

ROOT = Path(__file__).resolve().parents[3]


class SnapshotCapture(unittest.TestCase):
    """Public shell capture parity and stat-boundary refusal, CI only."""
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.home = Path(self.temporary.name).resolve()
        self.state = self.home / "state with spaces"
        self.state.mkdir()
        self.fakebin = self.home / "fakebin"
        self.fakebin.mkdir()
        self.log = self.home / "stat-calls.jsonl"
        self.env = {k: v for k, v in os.environ.items() if not k.startswith("FM_")}
        self.env.update(PATH=str(self.fakebin) + os.pathsep + os.environ["PATH"],
                        FM_FIXTURE_STAT=shutil.which("stat"), FM_FIXTURE_STAT_LOG=str(self.log),
                        PYTHONDONTWRITEBYTECODE="1")
        wrapper = self.fakebin / "stat"
        wrapper.write_text('''#!/usr/bin/env python3
import json, os, subprocess, sys
args = sys.argv[1:]
with open(os.environ["FM_FIXTURE_STAT_LOG"], "a") as stream:
    stream.write(json.dumps(args) + "\\n")
mode = os.environ.get("FM_FIXTURE_STAT_MODE", "")
batch = "--" in args
if batch and mode == "error":
    sys.exit(1)
if batch and mode in ("swap", "delete"):
    victim = args[-1]
    os.rename(victim, victim + ".original")
    if mode == "swap": os.symlink(os.environ["FM_FIXTURE_STAT_SECRET"], victim)
reply = subprocess.run([os.environ["FM_FIXTURE_STAT"], *args], stdout=subprocess.PIPE)
data = reply.stdout
if batch:
    rows = data.splitlines()
    if mode == "short": rows = rows[:-1]
    if mode == "extra": rows = rows + rows[:1]
    if mode == "malformed": rows[-1] = b"malformed"
    if mode == "nonregular": rows[-1] = b"a1ff" + rows[-1][rows[-1].index(b"\\t"):]
    if mode == "empty-field": rows[-1] = rows[-1].replace(b"\\t", b"\\t\\t", 1)
    if mode == "weak":
        rows = [b"\\t".join(row.split(b"\\t")[:3] + [b"0", b"-"]) for row in rows]
    data = b"\\n".join(rows) + b"\\n"
elif mode == "weak" and args[:2] == ["-c", "%W"]:
    data = b"0\\n"
sys.stdout.buffer.write(data)
sys.exit(reply.returncode)
''')
        wrapper.chmod(0o700)

    def tearDown(self):
        self.temporary.cleanup()

    def invoke(self, operation, **environment):
        return subprocess.run(["bash", "-c", '. "$1/bin/fm-classify-lib.sh"; "$3" "$2"',
                               "capture", str(ROOT), str(self.state), operation],
                              env=dict(self.env, **environment), stdout=subprocess.PIPE,
                              stderr=subprocess.PIPE, timeout=20)

    def test_whole_snapshot_matches_legacy_and_one_stat_covers_inventory(self):
        for name, raw in (("foo", b"note: a\n"), ("foo-2", b""), ("foo.x", b"note: \xff\n"),
                          ("Z", b"working: next\n"), ("a_2", b"note: answer\n")):
            (self.state / (name + ".status")).write_bytes(raw)
        (self.state / "directory.status").mkdir()
        (self.state / "link.status").symlink_to(self.state / "foo.status")
        (self.state / "dangling.status").symlink_to(self.state / "missing")
        os.mkfifo(self.state / "pipe.status")
        for locale in ("C", "C.UTF-8"):
            for mode in ("", "weak"):
                with self.subTest(locale=locale, mode=mode):
                    self.log.unlink(missing_ok=True)
                    actual = self.invoke("status_presentation_snapshot_batch", LC_ALL=locale,
                                         FM_FIXTURE_STAT_MODE=mode)
                    self.assertEqual(actual.returncode, 0, actual.stderr)
                    calls = [json.loads(line) for line in self.log.read_text().splitlines()]
                    self.assertEqual(len(calls), 1, calls)
                    self.assertEqual(len(calls[0][calls[0].index("--") + 1:]), 5, calls)
                    expected = self.invoke("status_presentation_snapshot", LC_ALL=locale,
                                           FM_FIXTURE_STAT_MODE=mode)
                    self.assertEqual(expected.returncode, 0, expected.stderr)
                    self.assertEqual(actual.stdout, expected.stdout)
                    self.assertEqual(len(actual.stdout.splitlines()), 5)
                    if mode == "weak": self.assertIn(b"\tweak:", actual.stdout)
                    for line in actual.stdout.splitlines():
                        self.assertEqual(len(line.split(b"\t")), 3)
        # The next fresh capture must observe growth, then same-size rotation.
        before = self.invoke("status_presentation_snapshot_batch").stdout
        with (self.state / "foo.status").open("ab") as stream:
            stream.write(b"note: append\n")
        grown = self.invoke("status_presentation_snapshot_batch").stdout
        self.assertNotEqual(before, grown)
        replacement = self.state / ".replacement"
        replacement.write_bytes((self.state / "foo.status").read_bytes())
        replacement.replace(self.state / "foo.status")
        rotated = self.invoke("status_presentation_snapshot_batch")
        self.assertEqual(rotated.returncode, 0, rotated.stderr)
        self.assertNotEqual(grown, rotated.stdout)
        self.assertEqual(rotated.stdout, self.invoke("status_presentation_snapshot").stdout)

    def test_refusal_is_atomic_and_override_or_inventory_never_truncates(self):
        for task in ("a", "b"):
            (self.state / (task + ".status")).write_text("note: answer\n")
        for mode in ("error", "short", "extra", "malformed", "nonregular", "empty-field"):
            with self.subTest(mode=mode):
                reply = self.invoke("status_presentation_snapshot_batch", FM_FIXTURE_STAT_MODE=mode)
                self.assertNotEqual(reply.returncode, 0, reply)
                self.assertEqual(reply.stdout, b"")
        for name in ("FM_STATUS_SIZE_READER", "FM_STATUS_IDENTITY_READER"):
            reply = self.invoke("status_presentation_snapshot_batch", **{name: "/missing"})
            self.assertNotEqual(reply.returncode, 0)
            self.assertEqual(reply.stdout, b"")
        for index in range(255):
            (self.state / ("task%03d.status" % index)).touch()
        reply = self.invoke("status_presentation_snapshot_batch")
        self.assertNotEqual(reply.returncode, 0)
        self.assertEqual(reply.stdout, b"")
        # The oversized legacy control needs no per-stat Python instrument.
        legacy = self.invoke("status_presentation_snapshot", PATH=os.environ["PATH"])
        self.assertEqual(legacy.returncode, 0, legacy.stderr)
        self.assertEqual(len(legacy.stdout.splitlines()), 257)

    def test_real_symlink_swap_and_deletion_cannot_publish_partial_capture(self):
        secret = self.home / "secret"
        secret.write_text("protected bytes\n")
        for mode in ("swap", "delete"):
            with self.subTest(mode=mode):
                for task in ("a", "z"):
                    (self.state / (task + ".status")).write_text("note: safe\n")
                reply = self.invoke("status_presentation_snapshot_batch", FM_FIXTURE_STAT_MODE=mode,
                                    FM_FIXTURE_STAT_SECRET=str(secret))
                self.assertNotEqual(reply.returncode, 0, reply)
                self.assertEqual(reply.stdout, b"")
                self.assertEqual(secret.read_text(), "protected bytes\n")
                victim = self.state / "z.status"
                if mode == "swap": self.assertTrue(victim.is_symlink())
                else: self.assertFalse(victim.exists())
                victim.unlink(missing_ok=True)
                (self.state / "z.status.original").replace(victim)

    def test_parent_channel_exclusion_matches_legacy_binding_not_filename(self):
        self.state = self.home / "state"
        self.state.mkdir()
        for task in ("task", "parent-replies"):
            (self.state / (task + ".status")).write_text("note: present\n")
        marker = self.home / ".fm-secondmate-home"
        parent = self.home / ".fm-secondmate-parent"
        for shape in ("main", "remote", "local", "invalid"):
            with self.subTest(shape=shape):
                if shape != "main": marker.write_text("mate\n")
                if shape == "remote": parent.write_text("schema=fm-secondmate-parent.v1\nroute=remote\n")
                if shape == "local":
                    parent.write_text("schema=fm-secondmate-parent.v1\nroute=local\nparent_home=" + str(self.home) + "\n")
                if shape == "invalid": parent.write_text("schema=unsupported\nroute=remote\n")
                actual = self.invoke("status_presentation_snapshot_batch")
                legacy = self.invoke("status_presentation_snapshot")
                self.assertEqual(actual.returncode, 0, actual.stderr)
                self.assertEqual(legacy.returncode, 0, legacy.stderr)
                self.assertEqual(actual.stdout, legacy.stdout)
                self.assertEqual(len(actual.stdout.splitlines()), 1 if shape == "remote" else 2)

    def test_empty_snapshot_has_no_stat_and_invalid_task_keeps_legacy(self):
        self.log.unlink(missing_ok=True)
        reply = self.invoke("status_presentation_snapshot_batch")
        self.assertEqual((reply.returncode, reply.stdout), (0, b""), reply.stderr)
        self.assertFalse(self.log.exists())
        (self.state / "odd task.status").write_text("note: legacy\n")
        reply = self.invoke("status_presentation_snapshot_batch")
        self.assertNotEqual(reply.returncode, 0)
        self.assertEqual(reply.stdout, b"")
        legacy = self.invoke("status_presentation_snapshot")
        self.assertEqual(legacy.returncode, 0, legacy.stderr)
        self.assertTrue(legacy.stdout.startswith(b"odd task\t"))


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
        # Exercise the production offset-batching interface against those SAME
        # real owner-written manifest/marker bytes, not a fabricated format.
        snapshot = {name: row[name] for name in ("task", "end", "identity", "fully_presented")}
        snapshot["strong_identity"] = acknowledged.split(b"\t")[2].rstrip(b"\n").decode()
        before = {p.name: p.read_bytes() for p in self.state.iterdir() if p.is_file()}
        self.assertEqual(Presentation(self.inputs).read_from_snapshot([snapshot])["rows"][0], native)
        self.assertEqual(before, {p.name: p.read_bytes() for p in self.state.iterdir() if p.is_file()})
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

    def test_marker_formats_compare_to_existing_offset_owner(self):
        from fm_view_offsets import Offsets
        raw = b"working: first\nworking: last\n"
        self.compare(raw)
        strong = (self.state / ".status-presentation-cursor").read_text().split("\t")[1]
        info = (self.state / "task.status").stat()
        snapshot = {"task": "task", "end": len(raw), "identity": [info.st_dev, info.st_ino],
                    "strong_identity": strong, "fully_presented": False}
        boundary = len(b"working: first\n")
        valid = f"{boundary}@{strong}"
        cases = [valid, f"v2\t{valid}\t{valid}", f"v2\tr1:00ab\t{valid}",
                 f"v2\tunverifiable\t{valid}", f"v2\t{valid}\t-", "unverifiable", "r1:ab",
                 f"v2\tbad\t{valid}", f"v2\t{valid}\tr1:ab", f"v2\t{valid}\tunverifiable",
                 f"v2\t{valid}\t{valid}\textra", "12@other-identity", "malformed", ""]
        script = '''. "$1/bin/fm-classify-lib.sh"
status_presentation_marker_offset "$2/.seen-task_status" "$2/task.status"
'''
        marker = self.state / ".seen-task_status"
        for raw_marker in cases:
            marker.write_text(raw_marker)
            with self.subTest(marker=raw_marker):
                before = marker.read_bytes()
                result = subprocess.run(["bash", "-c", script, "oracle", str(ROOT), str(self.state)],
                                        capture_output=True, timeout=30)
                self.assertEqual(result.returncode, 0, result.stderr)
                rows, _ = Offsets(self.inputs).capture([snapshot])
                self.assertEqual(rows[0]["classified"], int(result.stdout))
                self.assertEqual(marker.read_bytes(), before)

    def test_offset_batch_missing_rows_identity_reset_migration_and_cursor_barrier(self):
        from unittest.mock import patch
        row = self.row(b"working: first\nnote: answer\n")
        snapshot = {name: row[name] for name in ("task", "end", "identity", "fully_presented")}
        # A weak original identity remains weak; it must not be upgraded by the
        # native observer or confused with a different strong proof.
        strong = "weak:" + ":".join(str(i) for i in row["identity"])
        snapshot["strong_identity"] = strong
        manifest = self.state / ".status-presentation-cursor"
        migration = self.state / ".task.open-decisions-cursor"
        presentation = Presentation(self.inputs)
        self.assertEqual(presentation.read_from_snapshot([snapshot])["rows"][0]["new_lines"],
                         ["working: first", "note: answer"])
        migration.write_text("legacy cursor remains owned by legacy")
        with self.assertRaisesRegex(Refused, "migration cursor"):
            presentation.read_from_snapshot([snapshot])
        # Missing task rows in an EXISTING manifest must never use migration.
        manifest.write_bytes(b"")
        presentation.read_from_snapshot([snapshot])
        manifest.write_text("task\t" + strong + "\t" + str(row["end"]) + "\t0\n")
        self.assertEqual(presentation.read_from_snapshot([snapshot])["rows"][0]["new_lines"], [])
        for identity, offset in (("strong:1:2:other", row["end"]), (strong, row["end"] + 1)):
            manifest.write_text(f"task\t{identity}\t{offset}\t0\n")
            self.assertEqual(len(presentation.read_from_snapshot([snapshot])["rows"][0]["new_lines"]), 2)
        for raw in (b"task\tbad\tnot-a-number\n", b"task\tx\t0\n task\tx\tbad\n",
                    b"task\tx\t0\ntask\tx\t0\n", b"task\tx\t0\t0\textra\n"):
            manifest.write_bytes(raw)
            with self.subTest(raw=raw), self.assertRaises(Refused):
                presentation.read_from_snapshot([snapshot])
        manifest.write_bytes(b"")
        reads = []
        original_read = self.inputs.state_named_read
        def count(name):
            reads.append(name)
            return original_read(name)
        with patch.object(self.inputs, "state_named_read", count):
            presentation.read_from_snapshot([snapshot])
        self.assertEqual(reads.count(".status-presentation-cursor"), 2)  # capture and barrier only
        self.assertEqual(reads.count(".seen-task_status"), 1)
        original = presentation.read
        def change_cursor(rows):
            result = original(rows)
            manifest.write_text("task\t" + strong + "\t0\n")
            return result
        with patch.object(presentation, "read", change_cursor), self.assertRaisesRegex(Refused, "cursor changed"):
            presentation.read_from_snapshot([snapshot])
        manifest.unlink()
        manifest.symlink_to(migration)
        with self.assertRaises(OSError):
            presentation.read_from_snapshot([snapshot])

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
        cases = [(call, phase, operation) for call, phase in ((1, "pre-observe"), (5, "pre-reply"))
                 for operation in ("status-presentation", "drain-presentation")]
        for stalled_call, phase, operation in cases:
            with self.subTest(phase=phase, operation=operation), tempfile.TemporaryDirectory() as temporary:
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
                        if operation == "drain-presentation":
                            row = args["rows"][0]
                            row.pop("offset")
                            row.pop("classified")
                            row["strong_identity"] = f"weak:{info.st_dev}:{info.st_ino}"
                        requests.append(asyncio.create_task(engine.request(operation, args, 20)))
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
            # One slot holds the observation; another admits the fresh
            # generation captures required before any caller can join it.
            engine = Engine(Inputs(str(home)), workers=2)
            entered, release = threading.Event(), threading.Event()
            calls, requests = [], []
            class CapturedFixture:
                def __init__(self, inputs):
                    pass
                def read(self, rows):
                    calls.append(rows)
                    entered.set()
                    release.wait(20)
                    return {"rows": []}
            try:
                with patch.object(fm_view_presentation, "Presentation", CapturedFixture):
                    args = {"rows": [{"task": "task"}]}
                    first = asyncio.create_task(engine.request("status-presentation", args, 10))
                    requests.append(first)
                    self.assertTrue(await asyncio.get_running_loop().run_in_executor(None, entered.wait, 5))
                    second = asyncio.create_task(engine.request("status-presentation", args, 10))
                    requests.append(second)
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
                await asyncio.gather(*requests, return_exceptions=True)
                engine.close()

    async def test_saturated_batch_refuses_before_joining_and_preserves_critical_lane(self):
        import threading
        with tempfile.TemporaryDirectory() as temporary:
            home = Path(temporary).resolve()
            (home / "state").mkdir()
            (home / "state/task.meta").write_text("kind=secondmate\nspawn_gen=g1\n")
            path = home / "state/task.status"
            path.write_bytes(b"blocked [key=x]: held\n")
            entered, release = threading.Event(), threading.Event()
            class StalledInputs(Inputs):
                def state_read(self, task, suffix):
                    if task == "task" and suffix == ".status":
                        entered.set()
                        release.wait(20)
                    return super().state_read(task, suffix)
            inputs = StalledInputs(str(home))
            engine = Engine(inputs, workers=1)
            info = path.stat()
            args = {"rows": [{"task": "task", "end": info.st_size, "offset": 0,
                              "identity": [info.st_dev, info.st_ino],
                              "classified": 0, "fully_presented": False}]}
            first = asyncio.create_task(engine.request("status-presentation", args, 10))
            try:
                self.assertTrue(await asyncio.get_running_loop().run_in_executor(None, entered.wait, 5))
                with self.assertRaisesRegex(Refused, "capacity exhausted"):
                    await engine.request("status-presentation", args, 2)
                self.assertEqual(engine.shared, 0)
                self.assertEqual(engine.operations, 1)
                self.assertEqual(engine.ordinary.active, 1)
                # Another task's missing status avoids the held batch read.
                # It still exercises the real critical fold and both barriers.
                folded = await engine.request("status-fold", {"task": "critical"}, 2)
                self.assertEqual(folded["open"], [])
                self.assertFalse(release.is_set())
                release.set()
                result = await first
                self.assertEqual(result["rows"][0]["open"][0]["key"], "x")
            finally:
                release.set()
                await asyncio.gather(first, return_exceptions=True)
                engine.close()

    async def test_drain_offsets_are_fresh_without_status_changes_and_do_not_share_with_other_verb(self):
        with tempfile.TemporaryDirectory() as temporary:
            home = Path(temporary).resolve()
            (home / "state").mkdir()
            (home / "state/task.meta").write_text("kind=secondmate\nspawn_gen=g1\n")
            path = home / "state/task.status"
            path.write_bytes(b"note: answer\n")
            info = path.stat()
            strong = f"weak:{info.st_dev}:{info.st_ino}"
            args = {"rows": [{"task": "task", "end": info.st_size,
                              "identity": [info.st_dev, info.st_ino], "strong_identity": strong,
                              "fully_presented": False}]}
            engine = Engine(Inputs(str(home)))
            try:
                first = await engine.request("drain-presentation", args, 2)
                self.assertEqual(first["rows"][0]["unread"], ["note: answer"])
                (home / "state/.status-presentation-cursor").write_text(f"task\t{strong}\t{info.st_size}\t0\n")
                second = await engine.request("drain-presentation", args, 2)
                self.assertEqual(second["rows"][0]["unread"], [])
                self.assertEqual(engine.operations, 2)
                # These shapes are different APIs; a drain snapshot cannot be
                # admitted as a pre-captured-offset presentation request.
                with self.assertRaisesRegex(Refused, "invalid presentation row"):
                    await engine.request("status-presentation", args, 2)
            finally:
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
