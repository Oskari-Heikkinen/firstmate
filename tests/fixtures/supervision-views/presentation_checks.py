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
    signature = "\\n" in args[1]
    if signature:
        if mode == "nonregular": rows[-5] = b"symbolic link:a1ff"
        if mode == "empty-field": rows[-4] = b""
        if mode == "weak":
            for index in range(0, len(rows), 5): rows[index+3:index+5] = [b"0", b"-"]
    else:
        if mode == "nonregular": rows[-1] = b"a1ff" + rows[-1][rows[-1].index(b"\\t"):]
        if mode == "empty-field": rows[-1] = rows[-1].replace(b"\\t", b"\\t\\t", 1)
        if mode == "weak":
            rows = [b"\\t".join(row.split(b"\\t")[:3] + [b"0", b"-"]) for row in rows]
    data = b"\\n".join(rows) + b"\\n"
elif mode == "weak" and args[:2] == ["-c", "%W"]:
    data = b"0\\n"
elif mode == "weak" and "\\n" in args[1]:
    data = b"\\n".join(data.splitlines()[:3] + [b"0", b"-"]) + b"\\n"
sys.stdout.buffer.write(data)
sys.exit(reply.returncode)
''')
        wrapper.chmod(0o700)

    def tearDown(self):
        self.temporary.cleanup()

    def invoke(self, operation, **environment):
        return subprocess.run(["bash", "-c", '. "$1/bin/fm-classify-lib.sh"; . "$1/bin/fm-wake-drain-lib.sh"; "$3" "$2"',
                               "capture", str(ROOT), str(self.state), operation],
                              env=dict(self.env, **environment), stdout=subprocess.PIPE,
                              stderr=subprocess.PIPE, timeout=20)

    def commit(self, snapshot, batch=True, acknowledgements="", **environment):
        script = '''. "$1/bin/fm-classify-lib.sh"
. "$1/bin/fm-wake-drain-lib.sh"
STATUS_OUTCOME_BACKSTOP_ACKNOWLEDGED=$4
if [ "${FM_FIXTURE_FORBID_ROW_READS:-0}" = 1 ]; then
  _fm_open_decisions_file_ident() { echo unexpected-identity-read >&2; return 81; }
  _fm_status_file_size() { echo unexpected-size-read >&2; return 82; }
  status_outcome_backstop_cursor_offset() { echo unexpected-backstop-read >&2; return 83; }
fi
status_commit_presentation_snapshot "$2" "$3" "$5"
'''
        return subprocess.run(["bash", "-c", script, "commit", str(ROOT), str(self.state),
                               snapshot, acknowledgements, "batch" if batch else ""],
                              env=dict(self.env, **environment), stdout=subprocess.PIPE,
                              stderr=subprocess.PIPE, timeout=30)

    def compare_commit(self, snapshot, acknowledgements="", **environment):
        manifest = self.state / ".status-presentation-cursor"
        before = manifest.read_bytes() if manifest.exists() else None
        self.log.unlink(missing_ok=True)
        actual = self.commit(snapshot, acknowledgements=acknowledgements, **environment)
        calls = [json.loads(line) for line in self.log.read_text().splitlines()] if self.log.exists() else []
        after = manifest.read_bytes() if manifest.exists() else None
        if before is None: manifest.unlink(missing_ok=True)
        else: manifest.write_bytes(before)
        expected = self.commit(snapshot, batch=False, acknowledgements=acknowledgements)
        self.assertEqual(actual.returncode, expected.returncode, (actual.stderr, expected.stderr))
        self.assertEqual(actual.stdout, expected.stdout)
        self.assertEqual(after, manifest.read_bytes() if manifest.exists() else None)
        if actual.returncode: self.assertEqual(before, after)
        self.assertFalse(list(self.state.glob(".status-presentation-cursor.tmp.*")))
        return actual, calls, after

    def signatures(self, paths, batch=True, **environment):
        script = '''. "$1/bin/fm-classify-lib.sh"
. "$1/bin/fm-wake-drain-lib.sh"
shift
if [ "$1" = batch ]; then
  shift; status_observed_signatures_batch "$@"
else
  shift
  for path in "$@"; do status_observed_signature "$path" || exit; printf '\\n'; done
fi
'''
        return subprocess.run(["bash", "-c", script, "signature", str(ROOT),
                               "batch" if batch else "legacy", *map(str, paths)],
                              env=dict(self.env, **environment), capture_output=True, timeout=30)

    def test_device_bearing_manifest_preserves_owner_floor_receipt_and_commit(self):
        path = self.state / "task.status"
        path.write_bytes(b"note: owner identity\n")
        captured = self.invoke("status_presentation_snapshot_batch")
        self.assertEqual(captured.returncode, 0, captured.stderr)
        task, end, strong = captured.stdout.decode().strip().split("\t")
        if not strong.startswith("strong:"):
            self.skipTest("filesystem lacks birth-time identities; weak identity remains device-bound")
        old = "strong:2096:" + strong[len("strong:"):]
        manifest = self.state / ".status-presentation-cursor"
        initial = f"{task}\t{old}\t{int(end)-1}\t2\n".encode()
        manifest.write_bytes(initial)
        script = '''. "$1/bin/fm-classify-lib.sh"
. "$1/bin/fm-wake-drain-lib.sh"
status_presentation_suggestions_valid "$2" "$3" "$4"
'''
        def suggestions(endpoint):
            return subprocess.run(["bash", "-c", script, "guard", str(ROOT), str(self.state),
                                   captured.stdout.decode(), f"{task}\t{endpoint}\t{strong}"],
                                  env=self.env, capture_output=True, timeout=20)
        with self.subTest(stage="independent cursor floor"):
            self.assertEqual(suggestions(end).returncode, 0)
            self.assertNotEqual(suggestions(str(int(end)-2)).returncode, 0,
                                "an old device number must not erase the independent non-regression floor")
            self.assertEqual(manifest.read_bytes(), initial)
            old_capture = f"{task}\t{end}\t{old}"
            old_reply = subprocess.run(["bash", "-c", script, "guard", str(ROOT), str(self.state),
                                        old_capture, old_capture], env=self.env, capture_output=True, timeout=20)
            self.assertNotEqual(old_reply.returncode, 0, "old transaction captures must refuse, not zero the independent floor")
        facts = f"{task}\t{end}\t{strong}\t2\t{path.stat().st_mtime_ns // 10**9}\t{end}\tl:note: owner identity:l"
        script = '''. "$1/bin/fm-classify-lib.sh"
. "$1/bin/fm-wake-drain-lib.sh"
status_backstop_facts_current "$2" "$3" "$4"
'''
        def backstop(selected):
            return subprocess.run(["bash", "-c", script, "guard", str(ROOT), str(self.state),
                                   captured.stdout.decode(), selected], env=self.env, capture_output=True, timeout=20)
        with self.subTest(stage="independent backstop receipt"):
            self.assertEqual(backstop(facts).returncode, 0)
            self.assertNotEqual(backstop(facts.replace("\t2\t", "\t0\t", 1)).returncode, 0)
            self.assertEqual(manifest.read_bytes(), initial)
        with self.subTest(stage="whole commit parity"):
            actual, _, after = self.compare_commit(captured.stdout.decode())
            self.assertEqual(actual.returncode, 0, actual.stderr)
            self.assertNotIn(b"batch verification refused", actual.stderr)
            self.assertEqual(after, f"{task}\t{strong}\t{end}\t2\n".encode())

    def test_manifest_projection_refuses_binary_partial_and_nonregular_inputs(self):
        path = self.state / "task.status"
        path.write_bytes(b"note: reader boundary\n")
        captured = self.invoke("status_presentation_snapshot_batch")
        self.assertEqual(captured.returncode, 0, captured.stderr)
        task, end, strong = captured.stdout.decode().strip().split("\t")
        manifest = self.state / ".status-presentation-cursor"
        suggestion = f"{task}\t{end}\t{strong}"
        script = '''. "$1/bin/fm-classify-lib.sh"
. "$1/bin/fm-wake-drain-lib.sh"
status_presentation_suggestions_valid "$2" "$3" "$4"
'''
        def guard():
            return subprocess.run(["bash", "-c", script, "guard", str(ROOT), str(self.state),
                                   captured.stdout.decode(), suggestion], env=self.env, capture_output=True, timeout=20)
        for raw in (b"", f"{task}\t{strong}\t0\t0".encode()):
            with self.subTest(healthy=raw):
                manifest.write_bytes(raw)
                self.assertEqual(guard().returncode, 0)
                self.assertEqual(manifest.read_bytes(), raw)
        for raw in (b" ", b"partial", b"@snapshot", b"task\t", b"task\tweak:1:2\t0\x00\t0\n",
                    b"x" * (4*1024*1024 + 1)):
            with self.subTest(malformed_size=len(raw)):
                manifest.write_bytes(raw)
                self.assertNotEqual(guard().returncode, 0)
                self.assertEqual(manifest.read_bytes(), raw)
        manifest.unlink()
        protected = self.home / "protected-manifest"
        protected.write_text(f"{task}\t{strong}\t0\t0\n")
        for kind in ("link", "dangling", "directory", "fifo", "unreadable"):
            with self.subTest(kind=kind):
                if kind == "link": manifest.symlink_to(protected)
                elif kind == "dangling": manifest.symlink_to(self.home / "absent-manifest")
                elif kind == "directory": manifest.mkdir()
                elif kind == "fifo": os.mkfifo(manifest)
                else:
                    manifest.write_bytes(protected.read_bytes())
                    manifest.chmod(0)
                if kind != "unreadable" or os.getuid() != 0:
                    self.assertNotEqual(guard().returncode, 0)
                self.assertEqual(protected.read_text(), f"{task}\t{strong}\t0\t0\n")
                if kind == "directory": manifest.rmdir()
                else:
                    if kind == "unreadable": manifest.chmod(0o600)
                    manifest.unlink()
        self.assertEqual(guard().returncode, 0, "truly missing manifest is a healthy initial cursor")

    def test_backstop_guard_proves_whole_inventory_receipts_and_mtime_once(self):
        for task in ("a", "b"):
            (self.state / (task + ".status")).write_bytes(b"done: latest\n")
        snapshot = self.invoke("status_presentation_snapshot_batch")
        self.assertEqual(snapshot.returncode, 0, snapshot.stderr)
        captured = snapshot.stdout.decode().strip().split("\n")
        facts = []
        for row in captured:
            task, end, ident = row.split("\t")
            mtime = (self.state / (task + ".status")).stat().st_mtime_ns // 10**9
            facts.append(f"{row}\t4\t{mtime}\t{end}\tl:done: latest:l")
        cursor = self.state / ".status-presentation-cursor"
        cursor.write_text("".join(f"{row.split(chr(9))[0]}\t{row.split(chr(9))[2]}\t0\t4\n" for row in captured))
        script = '''. "$1/bin/fm-classify-lib.sh"
. "$1/bin/fm-wake-drain-lib.sh"
_fm_status_file_size() { echo per-row-size >&2; return 85; }
_fm_open_decisions_file_ident() { echo per-row-identity >&2; return 85; }
_fm_status_file_mtime() { echo per-row-mtime >&2; return 85; }
status_outcome_backstop_cursor_offset() { echo per-row-receipt >&2; return 85; }
status_snapshot_latest_event() { echo per-row-latest >&2; return 85; }
status_backstop_facts_current "$2" "$3" "$4"
'''
        def guard(selected, **environment):
            self.log.unlink(missing_ok=True)
            result = subprocess.run(["bash", "-c", script, "guard", str(ROOT), str(self.state),
                                     snapshot.stdout.decode(), "\n".join(selected)],
                                    env=dict(self.env, **environment), capture_output=True, timeout=20)
            calls = [json.loads(line) for line in self.log.read_text().splitlines()] if self.log.exists() else []
            self.assertLessEqual(len(calls), 1)
            self.assertEqual(result.stdout, b"")
            self.assertNotIn(b"per-row-", result.stderr)
            return result
        original = {p.name: p.read_bytes() for p in self.state.iterdir()}
        self.assertEqual(guard(facts).returncode, 0)
        self.assertEqual(len(self.log.read_text().splitlines()), 1)
        self.assertEqual(original, {p.name: p.read_bytes() for p in self.state.iterdir()})
        altered = [facts[:-1], facts + facts[:1], facts[::-1]]
        for field, value in ((0, "foreign"), (1, "1"), (2, "wrong"), (3, "3"), (3, "5"),
                             (4, "0"), (5, "999999"), (6, "."), (6, "l::l")):
            row = facts[0].split("\t"); row[field] = value
            altered.append(["\t".join(row), facts[1]])
        for selected in altered:
            with self.subTest(selected=selected): self.assertNotEqual(guard(selected).returncode, 0)
        for mode in ("short", "extra", "malformed", "empty-field", "nonregular", "error"):
            with self.subTest(mode=mode):
                self.assertNotEqual(guard(facts, FM_FIXTURE_STAT_MODE=mode).returncode, 0)
        status = self.state / "a.status"
        raw, stamp = status.read_bytes(), status.stat().st_mtime_ns
        status.write_bytes(raw + b"done: grew\n")
        self.assertNotEqual(guard(facts).returncode, 0)
        status.write_bytes(raw); os.utime(status, ns=(stamp + 2*10**9, stamp + 2*10**9))
        self.assertNotEqual(guard(facts).returncode, 0)
        os.utime(status, ns=(stamp, stamp))
        self.assertEqual(guard(facts).returncode, 0)
        replacement = self.state / ".replacement"; replacement.write_bytes(raw)
        replacement.replace(status)
        self.assertNotEqual(guard(facts).returncode, 0)
        status.unlink(); status.symlink_to(self.home / "secret")
        self.assertNotEqual(guard(facts).returncode, 0)
        cursor.write_text("malformed\n")
        self.assertNotEqual(guard(facts).returncode, 0)

    def test_fresh_signature_batch_matches_reported_owner_without_per_row_commands(self):
        paths = [self.state / name for name in ("b.status", "A.status", "a.x.status")]
        for path in paths: path.write_bytes(b"note: \xff answer\n")
        paths[1].write_bytes(b"")
        for locale in ("C", "C.UTF-8"):
            for mode in ("", "weak"):
                with self.subTest(locale=locale, mode=mode):
                    self.log.unlink(missing_ok=True)
                    actual = self.signatures(paths, LC_ALL=locale, FM_FIXTURE_STAT_MODE=mode)
                    self.assertEqual(actual.returncode, 0, actual.stderr)
                    calls = [json.loads(row) for row in self.log.read_text().splitlines()]
                    self.assertEqual(len(calls), 1, calls)
                    self.assertEqual(calls[0][calls[0].index("--")+1:], list(map(str, paths)))
                    expected = self.signatures(paths, batch=False, LC_ALL=locale, FM_FIXTURE_STAT_MODE=mode)
                    self.assertEqual(expected.returncode, 0, expected.stderr)
                    self.assertEqual(actual.stdout, expected.stdout)
                    self.assertEqual(len(actual.stdout.splitlines()), 3)
        before = self.signatures(paths).stdout
        paths[0].chmod(0o400)
        changed = self.signatures(paths).stdout
        self.assertNotEqual(before, changed)
        self.assertEqual(changed, self.signatures(paths, batch=False).stdout)
        paths[0].chmod(0o600)
        with paths[0].open("ab") as stream: stream.write(b"note: grew\n")
        grown = self.signatures(paths).stdout
        self.assertNotEqual(before, grown)
        self.assertEqual(grown, self.signatures(paths, batch=False).stdout)
        replacement = self.state / ".replacement"
        replacement.write_bytes(paths[0].read_bytes())
        replacement.replace(paths[0])
        rotated = self.signatures(paths).stdout
        self.assertNotEqual(grown, rotated)
        self.assertEqual(rotated, self.signatures(paths, batch=False).stdout)

    def test_signature_batch_refuses_whole_uncertain_inventory_without_output(self):
        paths = [self.state / (name + ".status") for name in ("a", "z")]
        for path in paths: path.write_bytes(b"working: event\n")
        for mode in ("error", "short", "extra", "malformed", "nonregular", "empty-field"):
            with self.subTest(mode=mode):
                reply = self.signatures(paths, FM_FIXTURE_STAT_MODE=mode)
                self.assertNotEqual(reply.returncode, 0, reply.stderr)
                self.assertEqual(reply.stdout, b"")
        for name in ("FM_STATUS_SIZE_READER", "FM_STATUS_IDENTITY_READER"):
            reply = self.signatures(paths, **{name: "/missing"})
            self.assertNotEqual(reply.returncode, 0)
            self.assertEqual(reply.stdout, b"")
        reply = self.signatures(paths * 129)
        self.assertNotEqual(reply.returncode, 0)
        self.assertEqual(reply.stdout, b"")
        self.log.unlink(missing_ok=True)
        empty = self.signatures([])
        self.assertEqual((empty.returncode, empty.stdout), (0, b""))
        self.assertFalse(self.log.exists())
        secret = self.home / "secret"
        secret.write_bytes(b"private\n")
        for mode in ("swap", "delete"):
            reply = self.signatures(paths, FM_FIXTURE_STAT_MODE=mode, FM_FIXTURE_STAT_SECRET=str(secret))
            self.assertNotEqual(reply.returncode, 0)
            self.assertEqual(reply.stdout, b"")
            self.assertEqual(secret.read_bytes(), b"private\n")
            paths[-1].unlink(missing_ok=True)
            Path(str(paths[-1]) + ".original").replace(paths[-1])
        directory = self.state / "directory.status"
        directory.mkdir()
        reply = self.signatures([*paths, directory])
        self.assertNotEqual(reply.returncode, 0)
        self.assertEqual(reply.stdout, b"")

    def test_commit_batch_matches_whole_legacy_cursor_without_per_row_reads(self):
        for task in ("b", "a", "a-2", "a.x"):
            (self.state / (task + ".status")).write_text("note: answer\nworking: more\n")
        snapshot = self.invoke("status_presentation_snapshot_batch").stdout.decode().rstrip("\n")
        rows = [line.split("\t") for line in snapshot.splitlines()]
        manifest = self.state / ".status-presentation-cursor"
        for locale in ("C", "C.UTF-8"):
            for shape in ("missing", "empty", "old", "carry", "reset", "duplicate"):
                with self.subTest(locale=locale, shape=shape):
                    manifest.unlink(missing_ok=True)
                    if shape == "empty": manifest.write_bytes(b"")
                    if shape in ("old", "carry", "reset", "duplicate"):
                        lines = []
                        for task, end, ident in rows:
                            row = [task, ident, "0"]
                            if shape in ("carry", "duplicate"): row.append("3")
                            if shape == "reset":
                                row[1] = "strong:old-identity"
                                row.append("99999")
                            lines.append("\t".join(row))
                        if shape == "duplicate": lines.append(lines[0])
                        manifest.write_text("\n".join(lines) + "\n")
                    # Last matching acknowledgement wins; foreign acks have no
                    # cursor effect, and row ordering is the selected ordering.
                    acks = "b\t2\nb\t4\nforeign\t999999\n"
                    actual, calls, after = self.compare_commit(snapshot, acks, LC_ALL=locale,
                        **({} if shape == "duplicate" else {"FM_FIXTURE_FORBID_ROW_READS": "1"}))
                    self.assertEqual(actual.returncode, 0, actual.stderr)
                    if shape == "duplicate":
                        self.assertIn(b"batch verification refused", actual.stderr)
                    else:
                        self.assertEqual(actual.stderr, b"")
                        self.assertEqual(len(calls), 1, calls)
                    self.assertEqual([line.split(b"\t")[0] for line in after.splitlines()],
                                     [row[0].encode() for row in rows])
                    self.assertEqual(after.splitlines()[-1].split(b"\t")[-1], b"4")

    def test_commit_capture_is_fresh_growth_preserves_selected_end_and_backstop(self):
        status = self.state / "task.status"
        status.write_text("note: original\n")
        snapshot = self.invoke("status_presentation_snapshot_batch").stdout.decode().rstrip("\n")
        task, end, ident = snapshot.split("\t")
        status.write_text("note: original\nnote: appended after presentation\n")
        # A newly arrived status is not in this presentation's selection.
        (self.state / "new.status").write_text("note: unread\n")
        manifest = self.state / ".status-presentation-cursor"
        for old_ident, backstop, expected in ((ident, status.stat().st_size, status.stat().st_size),
                                             (ident, status.stat().st_size + 1, 0), ("replaced", 2, 0)):
            with self.subTest(old_ident=old_ident, backstop=backstop):
                manifest.write_text(f"{task}\t{old_ident}\t0\t{backstop}\n")
                actual, calls, after = self.compare_commit(snapshot, FM_FIXTURE_FORBID_ROW_READS="1")
                self.assertEqual(actual.returncode, 0, actual.stderr)
                self.assertEqual(actual.stderr, b"")
                self.assertEqual(len(calls), 1, calls)
                self.assertEqual(after, f"{task}\t{ident}\t{end}\t{expected}\n".encode())

    def test_commit_batch_refuses_replacement_deletion_truncation_and_symlink(self):
        status = self.state / "task.status"
        secret = self.home / "secret"
        secret.write_text("protected bytes\n")
        manifest = self.state / ".status-presentation-cursor"
        for attack in ("rotation", "deletion", "truncation", "symlink", "past-end-ack"):
            with self.subTest(attack=attack):
                status.unlink(missing_ok=True)
                status.write_text("note: original\n")
                snapshot = self.invoke("status_presentation_snapshot_batch").stdout.decode().rstrip("\n")
                manifest.write_bytes(b"unselected\tproof\t0\t0\n")
                if attack == "rotation":
                    replacement = self.state / ".new"
                    replacement.write_bytes(status.read_bytes())
                    replacement.replace(status)
                elif attack == "deletion": status.unlink()
                elif attack == "truncation": status.write_bytes(b"")
                elif attack == "symlink":
                    status.unlink()
                    status.symlink_to(secret)
                acks = "task\t99999" if attack == "past-end-ack" else ""
                actual, _, after = self.compare_commit(snapshot, acks)
                self.assertNotEqual(actual.returncode, 0, actual.stderr)
                self.assertIn(b"batch verification refused", actual.stderr)
                self.assertEqual(after, b"unselected\tproof\t0\t0\n")
                self.assertEqual(secret.read_text(), "protected bytes\n")

    def test_commit_batch_malformed_capture_and_cursor_use_complete_legacy_owner(self):
        (self.state / "task.status").write_text("note: answer\n")
        snapshot = self.invoke("status_presentation_snapshot_batch").stdout.decode().rstrip("\n")
        manifest = self.state / ".status-presentation-cursor"
        for mode in ("error", "short", "extra", "malformed", "nonregular", "empty-field"):
            with self.subTest(mode=mode):
                manifest.write_bytes(b"")
                actual, _, _ = self.compare_commit(snapshot, FM_FIXTURE_STAT_MODE=mode)
                self.assertEqual(actual.returncode, 0, actual.stderr)
                self.assertIn(b"batch verification refused", actual.stderr)
        for raw in (b"malformed\n", b"task\tproof\tno-offset\n", b"task\tproof\t0\t0\textra\n"):
            with self.subTest(raw=raw):
                manifest.write_bytes(raw)
                actual, _, after = self.compare_commit(snapshot)
                self.assertNotEqual(actual.returncode, 0)
                self.assertEqual(after, raw)
        manifest.write_bytes(b"")
        self.log.unlink(missing_ok=True)
        legacy = self.commit(snapshot, batch=False)
        self.assertEqual(legacy.returncode, 0, legacy.stderr)
        self.assertFalse(any("--" in json.loads(line) for line in self.log.read_text().splitlines()),
                         "ordinary legacy commit must not attempt a batch")
        # Empty selections still atomically publish the original empty manifest.
        actual, _, after = self.compare_commit("")
        self.assertEqual(actual.returncode, 0, actual.stderr)
        self.assertEqual(after, b"")

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

    def test_current_and_device_bearing_strong_forms_share_native_offsets_not_authority(self):
        from unittest.mock import patch
        row = self.row(b"note: first\nnote: second\n")
        path = self.state / "task.status"
        answer = subprocess.run(["bash", "-c", '. "$1/bin/fm-classify-lib.sh"; _fm_open_decisions_file_ident "$2"',
                                 "identity", str(ROOT), str(path)], capture_output=True, timeout=20)
        self.assertEqual(answer.returncode, 0, answer.stderr)
        strong = answer.stdout.decode()
        if not strong.startswith("strong:"):
            self.skipTest("filesystem lacks birth-time identities; weak identity remains device-bound")
        old = "strong:2096:" + strong[len("strong:"):]
        snapshot = {name: row[name] for name in ("task", "end", "identity", "fully_presented")}
        snapshot["strong_identity"] = strong
        cursor = self.state / ".status-presentation-cursor"
        marker = self.state / ".seen-task_status"
        cursor.write_text(f"task\t{old}\t12\t2\n")
        marker.write_text(f"12@{old}\n")
        before = {p.name: p.read_bytes() for p in self.state.iterdir()}
        native = Presentation(self.inputs).read_from_snapshot([snapshot])["rows"][0]
        expected = Presentation(self.inputs).read([dict(row, offset=12, classified=12)])["rows"][0]
        self.assertEqual(native, expected)
        self.assertEqual(native["observed_offset"], 12)
        self.assertEqual(Presentation(self.inputs).backstop([snapshot])["rows"][0]["receipt"], 2)
        self.assertEqual(before, {p.name: p.read_bytes() for p in self.state.iterdir()})
        # Birth/inode changes still reset; weak identities never lose a device.
        for changed in ("strong:2096:9" + strong[len("strong:"):],
                        "strong:" + strong.split(":", 2)[1] + ":different-birth",
                        "weak:" + str(row["identity"][0] + 1) + ":" + str(row["identity"][1])):
            with self.subTest(changed=changed):
                cursor.write_text(f"task\t{changed}\t12\t2\n")
                marker.write_text(f"12@{changed}\n")
                self.assertEqual(Presentation(self.inputs).read_from_snapshot([snapshot])["rows"][0]["observed_offset"], 0)
                self.assertEqual(Presentation(self.inputs).backstop([snapshot])["rows"][0]["receipt"], 0)
        # A canonical identity predicts the root filesystem only; it never
        # suppresses the descriptor's device/inode capture check.
        original = self.inputs.state_read
        def foreign_device(task, suffix):
            captured = original(task, suffix)
            if captured is not None and suffix == ".status":
                captured = dict(captured, identity=[row["identity"][0] + 1, row["identity"][1]])
            return captured
        with patch.object(self.inputs, "state_read", foreign_device):
            with self.assertRaisesRegex(Refused, "status identity changed"):
                Presentation(self.inputs).read_from_snapshot([snapshot])
        with self.assertRaisesRegex(Refused, "snapshot identity mismatch"):
            Presentation(self.inputs).read_from_snapshot([dict(snapshot, identity=[row["identity"][0] + 1, row["identity"][1]])])

    def test_backstop_latest_and_receipt_equal_original_owner_without_writes(self):
        cases = [b"", b" \t\r\n", b"done: one\r\n\t \n", b"failed: unfinished\t ",
                 b"done: old\n\0\n", b"done: nul\0 byte\r\n", b"done: \xff\n",
                 b"done: old\n\x85\n", b"done: old\n\xa0\n", b"done: old\n\x1c\n",
                 b"x" * 65536 + b"\ndone: bounded\n", b"done: " + b"x" * 65536,
                 b"x" * 65536 + b"\n", b"x" * 65535 + b"\n", b"\vdone: one\rinside\n"]
        script = '''. "$1/bin/fm-classify-lib.sh"
f="$2/task.status"
ident=$(_fm_open_decisions_file_ident "$f") || exit 1
printf "%s\\0" "$ident"
status_outcome_backstop_cursor_offset "$f" || exit 1
printf "\\0"
if status_snapshot_latest_event "$f" "$3" "$ident"; then
  printf "%s\\0%s\\0%s" "$FM_STATUS_SNAPSHOT_EVENT_MTIME" "$FM_STATUS_SNAPSHOT_EVENT_ENDPOINT" "$FM_STATUS_SNAPSHOT_EVENT_LINE"
else
  printf "%s\\0%s\\0%s" - 0 ''
fi
'''
        cursor = self.state / ".status-presentation-cursor"
        for raw in cases:
            with self.subTest(raw=raw[:30], size=len(raw)):
                row = self.row(raw)
                # A four-column receipt is read, not consumed or rewritten.
                ident_run = subprocess.run(["bash", "-c", '. "$1/bin/fm-classify-lib.sh"; _fm_open_decisions_file_ident "$2"',
                                            "identity", str(ROOT), str(self.state / "task.status")],
                                           capture_output=True, timeout=20)
                self.assertEqual(ident_run.returncode, 0, ident_run.stderr)
                strong = ident_run.stdout.decode()
                for saved in (None, f"task\t{strong}\t0\n", f"task\t{strong}\t0\t3\n",
                              "task\tother\t0\t999999\n"):
                    with self.subTest(saved=saved):
                        if saved is None: cursor.unlink(missing_ok=True)
                        else: cursor.write_text(saved)
                        before = {p.name: p.read_bytes() for p in self.state.iterdir() if p.is_file()}
                        snapshot = {name: row[name] for name in ("task", "end", "identity", "fully_presented")}
                        snapshot["strong_identity"] = strong
                        native = Presentation(self.inputs).backstop([snapshot])["rows"][0]
                        oracle = subprocess.run(["bash", "-c", script, "oracle", str(ROOT), str(self.state), str(len(raw))],
                                                capture_output=True, timeout=20)
                        self.assertEqual(oracle.returncode, 0, oracle.stderr)
                        identity, receipt, mtime, end, line = oracle.stdout.split(b"\0")
                        self.assertEqual(identity.decode(), strong)
                        self.assertEqual(native["receipt"], int(receipt))
                        self.assertEqual(native["event_end"], int(end))
                        self.assertEqual(native["line"].encode("utf-8", "surrogateescape"), line)
                        if mtime != b"-": self.assertEqual(native["mtime"], int(mtime))
                        self.assertEqual(before, {p.name: p.read_bytes() for p in self.state.iterdir() if p.is_file()})

    def test_backstop_whole_batch_refuses_growth_replacement_and_late_changes(self):
        from unittest.mock import patch
        rows = []
        for task in ("a", "b"):
            row = self.row(b"done: first\n", task=task)
            rows.append({**{name: row[name] for name in ("task", "end", "identity", "fully_presented")},
                         "strong_identity": "weak:" + ":".join(map(str, row["identity"]))})
        reader = Presentation(self.inputs)
        self.assertEqual(len(reader.backstop(rows)["rows"]), 2)
        status = self.state / "a.status"
        original = status.read_bytes()
        for raw in (original + b"done: grew\n", original[:-1]):
            status.write_bytes(raw)
            with self.assertRaisesRegex(Refused, "live endpoint changed"):
                reader.backstop(rows)
        status.write_bytes(original)
        capture = self.inputs.state_read
        calls = 0
        def changed(task, suffix):
            nonlocal calls
            result = capture(task, suffix)
            if task == "a" and suffix == ".status":
                calls += 1
                if calls == 1: status.write_bytes(b"done: other\n")
            return result
        with patch.object(self.inputs, "state_read", changed):
            with self.assertRaisesRegex(Refused, "input changed before reply"):
                reader.backstop(rows)
        replacement = self.state / ".replacement"
        replacement.write_bytes(original)
        replacement.replace(status)
        with self.assertRaisesRegex(Refused, "live endpoint changed"):
            reader.backstop(rows)
        cursor = self.state / ".status-presentation-cursor"
        cursor.write_text("malformed\n")
        with self.assertRaisesRegex(Refused, "invalid presentation cursor"):
            reader.backstop(rows)

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
                evidence = Presentation(self.inputs).read_from_snapshot([snapshot])["classification_markers"]
                self.assertEqual(evidence, [{"task": "task", "text": raw_marker}])
                self.assertEqual(marker.read_bytes(), before)
        marker.write_bytes(b"r1:ab\0\n\n")
        self.assertEqual(Presentation(self.inputs).read_from_snapshot([snapshot])["classification_markers"],
                         [{"task": "task", "text": "r1:ab"}])
        marker.unlink()
        self.assertEqual(Presentation(self.inputs).read_from_snapshot([snapshot])["classification_markers"],
                         [{"task": "task", "text": None}])
        marker.write_bytes(b"x" * 4097)
        with self.assertRaisesRegex(Refused, "classification marker evidence bound exceeded"):
            Presentation(self.inputs).read_from_snapshot([snapshot])

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
                 for operation in ("status-presentation", "drain-presentation", "status-backstop")]
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
                        if operation in ("drain-presentation", "status-backstop"):
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
                    if operation == "status-backstop":
                        self.assertTrue(all(result["rows"][0]["line"] == "blocked [key=x]: held" for result in results))
                    else:
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
                backstop = await engine.request("status-backstop", args, 2)
                self.assertEqual(backstop["rows"][0]["receipt"], 0)
                (home / "state/.status-presentation-cursor").write_text(f"task\t{strong}\t{info.st_size}\t1\n")
                changed = await engine.request("status-backstop", args, 2)
                self.assertEqual(changed["rows"][0]["receipt"], 1)
                self.assertEqual(engine.operations, 4)
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
