"""Native observation cases called by fm-handoff-firstmate.test.sh; scratch paths only."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import unittest
from unittest.mock import patch

ROOT, TMP = Path(sys.argv[1]), Path(sys.argv[2]) / "native"
sys.path.insert(0, str(ROOT / "bin"))
import fm_handoff_adapters as adapters
import fm_handoff_registry as registry
validate = registry.validator()
T, SHA, OWNER = "2026-10-24T16:00:00Z", "a" * 64, "tetjet-mate"
NOW = adapters.native_time(T)
REAL = ROOT / "tests/fixtures/handoff-coverage/native/real"
ENV = {k: v for k, v in os.environ.items()
       if k not in ("FM_HOME", "FM_STATE_OVERRIDE", "FM_ROOT_OVERRIDE", "FM_CONFIG_OVERRIDE")}
FAMILIES = ("native-tj-handoff", "native-tetjet-collected", "native-tj-step",
            "native-manifest-verified", "native-capacity-cursor")


def put(path, doc):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(doc) + "\n")
    return path


def sample(family):
    # Source-shaped examples of the native writer APIs, not live endpoint reads.
    # verified.json is the real empty-manifest writer probe with only item sanitized.
    if family == "native-tj-handoff":
        return {"schema": "tj-handoff/v1", "id": "request-accepted--example--aaaaaaaaaaaa--builder",
                "kind": "REQUEST ACCEPTED", "subject": "example", "created_at": T,
                "producer": "intake", "consumer": "builder", "artefact": {"sums_sha256": SHA}}
    if family == "native-tetjet-collected":
        return {"schema": "tetjet-collected/v1", "kind": "tj-package", "batch_id": "batch-a",
                "recorded_at": T, "verified_at": "2026-10-01T00:00:00Z", "verification": {"verdict": "PASS"},
                "lines": {"nonzero": [1]}, "labels": {"status": "incomplete"}}
    if family == "native-tj-step":
        return {"schema": "tj-step-receipt/v1", "subject": "batch-a", "phase": "launch",
                "started": T, "ended": T, "rc": 0, "result_word": "LAUNCH-STARTED"}
    if family == "native-manifest-verified":
        return json.loads((ROOT / "tests/fixtures/handoff-coverage/native/verified.json").read_text())
    return {"dev": 0, "ino": 0, "offset": 0, "tail": hashlib.sha256(b"").hexdigest()}


class NativeAdapters(unittest.TestCase):
    def setUp(self):
        self.folder = TMP / self.id().split(".")[-1]
        self.folder.mkdir(parents=True)
        self.cache = {}

    def protocol(self, family, match="*.json"):
        if family == "native-capacity-cursor" and match == "*.json":
            match = "capacity.cursor.json"
        stage = {"name": "observe", "owner": OWNER, "accepts": {"min": 0, "max": 1},
                 "input": {"path": str(self.folder), "reach": {"kind": "local"}, "match": match},
                 "outbox": {"path": str(self.folder), "reach": {"kind": "local"}},
                 "bounds": {"accepted": "1h", "held": "1h", "waiting": "1h"}, "retry_limit": 0,
                 "codes": {code: {"fix_owner": OWNER, "holds_all": False, "what": code}
                           for code in ("native-refused", "native-wait", "native-failed")},
                 "cleanup": {"action": "keep"}, "ext": {f"{OWNER}.receipt-adapter": family}}
        proto = {"id": "native.test", "owner": OWNER, "title": "native observation", "schema": "fixture:local",
                 "record_types": ["native/v1"], "versions": {"min": 0, "max": 99}, "senders": [OWNER],
                 "first_stage": "observe", "stages": [stage],
                 "cleanup": {"stage": "observe", "receipts_after": "7d", "records_after": "7d"}}
        return proto, stage

    def adapt(self, family, match="*.json"):
        proto, stage = self.protocol(family, match)
        docs, problems = adapters.adapt(proto, stage, self.cache, NOW)
        for doc in docs:
            self.assertEqual([], validate.Schema(str(ROOT / "docs/handoff-coverage/handoff-receipt-v1.schema.json")).errors(doc))
            self.assertEqual([], validate.receipt_problems(doc, {proto["id"]: proto}))
            self.assertFalse(doc["ext"][f"{OWNER}.native-attempts-known"])
        return docs, problems

    def one(self, family, doc, name="record.json"):
        put(self.folder / name, doc)
        docs, bad = self.adapt(family)
        self.assertEqual([], bad)
        self.assertEqual(1, len(docs))
        self.assertEqual(0 if family == "native-capacity-cursor" else 1, docs[0]["version"])
        self.assertEqual(str(self.folder / name), docs[0]["evidence"])
        return docs[0]

    def copy_real(self, group):
        # Copies are byte-identical to the owner's already-sanitized fixtures.
        for source in (REAL / group).glob("*.json"):
            (self.folder / source.name).write_bytes(source.read_bytes())

    def test_real_fixture_seal(self):
        provenance = json.loads((REAL / "provenance.json").read_text())
        self.assertEqual("44fd3bc7f3fdc056b397538cd10ba25423f4b366b706ec46ad376d3c93dd13a8",
                         provenance["owner_manifest_sha256"])
        self.assertFalse(provenance["real_cursor_supplied"])
        self.assertEqual(10, len(provenance["files"]))
        for name, sha in provenance["files"].items():
            self.assertEqual(sha, hashlib.sha256((REAL / name).read_bytes()).hexdigest(), name)

    def test_real_queue_refusal_then_acceptance(self):
        family = "native-tj-handoff"
        refused = next((REAL / "queue").glob("request-refused*.json"))
        (self.folder / refused.name).write_bytes(refused.read_bytes())
        docs, bad = self.adapt(family)
        self.assertEqual([], bad)
        self.assertEqual(["refused"], [d["state"] for d in docs])
        record = docs[0]["record"]
        self.copy_real("queue")
        docs, bad = self.adapt(family)
        self.assertEqual([], bad)
        self.assertEqual(["done"], [d["state"] for d in docs])
        self.assertEqual(record, docs[0]["record"])

    def test_real_collected_and_separate_request_directory(self):
        family = "native-tetjet-collected"
        self.copy_real("collected")
        docs, bad = self.adapt(family)
        self.assertEqual([], bad)
        self.assertEqual(2, len(docs))
        self.assertTrue(all(d["state"] == "done" for d in docs))
        # Request collection is a different declared input, not recursive discovery.
        self.folder = self.folder / "requests"
        self.folder.mkdir()
        self.copy_real("collected/requests")
        docs, bad = self.adapt(family)
        self.assertEqual([], bad)
        self.assertEqual(1, len(docs))
        self.assertTrue(docs[0]["record"].startswith("request:b10-proposal-ceiling-1:"))
        self.assertIn("request:collected", docs[0]["detail"])

    def test_real_step_invocations_and_null_fallback(self):
        family = "native-tj-step"
        self.copy_real("steps")
        docs, bad = self.adapt(family)
        self.assertEqual([], bad)
        self.assertEqual(["accepted", "done", "held", "held"], sorted(d["state"] for d in docs))
        self.assertEqual(4, len({d["record"] for d in docs}))
        # The real WAIT/success pair remains two historical invocation outcomes.
        pair = [d for d in docs if d["record"].startswith("allin-2100s-repeat-")]
        self.assertEqual(["done", "held"], sorted(d["state"] for d in pair))
        fallback = next(d for d in docs if d["record"].startswith("bent-chain-"))
        source = self.folder / fallback["record"]
        doc = json.loads(source.read_text())
        self.assertIsNone(doc["result_word"])
        self.assertIn(doc["result"], fallback["detail"])
        # Derived variants, not represented as additional real fixtures.
        put(source, dict(doc, rc=0))
        docs, bad = self.adapt(family)
        self.assertEqual([], bad)
        fixed = next(d for d in docs if d["record"] == fallback["record"])
        self.assertEqual("done", fixed["state"], "C1: rc=0/null is wrapper completion, not a launch")
        self.assertIn(doc["result"], fixed["detail"])
        put(source, dict(doc, rc=0, result_word="UNRECOGNIZED"))
        self.assertIn("unknown step result_word", self.adapt(family)[1][0][1])
        put(source, dict(doc, result="x" * (adapters.NATIVE_RESULT_CHARS + 1)))
        self.assertIn("at most", self.adapt(family)[1][0][1])

    def test_real_signal_tail_is_not_a_real_cursor(self):
        family = "native-capacity-cursor"
        signal = self.folder / "capacity.signal"
        signal.write_bytes((REAL / "capacity/tj-auto-capacity.signal").read_bytes())
        docs, bad = self.adapt(family)
        self.assertEqual([], docs)
        self.assertIn("missing", bad[0][1])
        # Synthetic checkpoint for this scratch inode only, not a native live cursor.
        st = signal.stat()
        cursor = {"dev": st.st_dev, "ino": st.st_ino, "offset": st.st_size,
                  "tail": hashlib.sha256(signal.read_bytes()[-256:]).hexdigest()}
        self.assertEqual("done", self.one(family, cursor, "capacity.cursor.json")["state"])
        signal.write_bytes(signal.read_bytes() + b"incomplete")
        self.assertEqual("accepted", self.adapt(family)[0][0]["state"])

    def test_handoff_every_kind_and_request_recovery(self):
        family = "native-tj-handoff"
        kinds = ("READY FOR LAUNCH", "READY FOR HELPER REVIEW", "READY FOR KIT REVIEW", "PASS", "FAIL",
                 "REQUEST ACCEPTED", "REQUEST REFUSED", "BATCH CUT", "REQUEST ALL CUT", "REQUEST SUPERSEDED",
                 "REQUEST WITHDRAWN", "BATCH ABANDONED")
        for kind in kinds:
            with self.subTest(kind=kind):
                self.cache = {}
                out = self.one(family, dict(sample(family), kind=kind))
                self.assertEqual("refused" if kind in ("FAIL", "REQUEST REFUSED") else "done", out["state"])
                self.assertIn(kind, out["detail"])
        doc = dict(sample(family), kind="REQUEST REFUSED", created_at="2026-10-24T15:00:00Z")
        put(self.folder / "refused.json", doc)
        # The loop ended on BATCH ABANDONED; restore an acceptance of the same request.
        put(self.folder / "record.json", sample(family))
        docs, bad = self.adapt(family)
        self.assertEqual([], bad)
        self.assertEqual(["done"], [d["state"] for d in docs])
        self.assertTrue(docs[0]["record"].endswith(SHA))
        (self.folder / "record.json").unlink()
        self.assertEqual(["done"], [d["state"] for d in self.adapt(family)[0]],
                         "pruned later acceptance cannot resurrect retained older refusal")
        put(self.folder / "record.json", sample(family))
        put(self.folder / "refused.json", dict(doc, created_at=T))
        self.assertTrue(self.adapt(family)[1], "same-second conflicting decisions cannot be ordered by filename")

    def test_collected_kinds_and_withdrawal_outcomes(self):
        family = "native-tetjet-collected"
        for kind in ("tj-package", "rolling-slice", "request"):
            for outcome in ("collected", "partly-withdrawn", "withdrawn"):
                with self.subTest(kind=kind, outcome=outcome):
                    self.cache = {}
                    doc = dict(sample(family), kind=kind, request_id="request-a", request_sha256=SHA,
                               complete=True, outcome=outcome)
                    out = self.one(family, doc)
                    self.assertEqual("done", out["state"])
                    self.assertEqual(adapters.utc(NOW), out["written_at"])
                    if kind == "request":
                        self.assertIn(outcome, out["detail"])
        put(self.folder / "record.json", dict(doc, complete=False))
        self.assertTrue(self.adapt(family)[1])
        put(self.folder / "record.json", dict(doc, kind="tj-package-partial"))
        self.assertIn("unknown collected kind", self.adapt(family)[1][0][1])

    def test_step_every_state_and_no_fake_until(self):
        family = "native-tj-step"
        words = (None, "LAUNCH-STARTED", "RELAUNCHED", "FETCHED-VERIFIED", "MOVED-ASIDE", "UPLOAD-ONLY",
                 "DRY-RUN", "READY-CHECK", "REFUSE", "FAIL", "BLOCKED", "WAIT")
        cases = [(None, None, "accepted", None), (1, None, "held", "native-failed"),
                 (75, "WAIT", "held", "native-wait")]
        cases += [(0, w, "held" if w in ("REFUSE", "FAIL", "BLOCKED", "WAIT") else "done",
                   "native-wait" if w == "WAIT" else "native-failed" if w in ("REFUSE", "FAIL", "BLOCKED") else None)
                  for w in words]
        for rc, word, state, code in cases:
            with self.subTest(rc=rc, word=word):
                self.cache = {}
                out = self.one(family, dict(sample(family), rc=rc, result_word=word, ended=None if rc is None else T))
                self.assertEqual(state, out["state"])
                self.assertEqual(code, out.get("code"))
                self.assertNotIn("until", out)
        put(self.folder / "second.json", sample(family))
        docs, bad = self.adapt(family)
        self.assertEqual([], bad)
        self.assertEqual(2, len({d["record"] for d in docs}))

    def test_verified_real_scratch_probe_and_dot_match(self):
        family = "native-manifest-verified"
        doc = sample(family)
        self.assertEqual("done", self.one(family, doc)["state"])
        path = put(self.folder / ".pc-archive.VERIFIED.json", doc)
        docs, bad = self.adapt(family, path.name)
        self.assertEqual([], bad)
        self.assertEqual([str(path)], [d["evidence"] for d in docs])
        put(path, dict(doc, result="failed"))
        self.assertTrue(self.adapt(family, path.name)[1])

    def test_manifest_pair_identity_is_unambiguous(self):
        family = "native-manifest-verified"
        put(self.folder / "a.json", dict(sample(family), item="a:b", manifest="c"))
        put(self.folder / "b.json", dict(sample(family), item="a", manifest="b:c"))
        docs, bad = self.adapt(family)
        self.assertEqual([], bad)
        self.assertEqual(2, len({d["record"] for d in docs}))

    def test_unknown_versions_oversize_unreadable_and_malformed(self):
        for family in FAMILIES:
            with self.subTest(family=family):
                self.cache = {}
                doc = sample(family)
                doc["schema_version" if family == "native-manifest-verified" else "schema"] = "future/v99"
                path = put(self.folder / ("capacity.cursor.json" if family == "native-capacity-cursor" else "record.json"), doc)
                docs, bad = self.adapt(family)
                self.assertFalse(docs)
                self.assertIn("unknown", bad[0][1])
                path.write_text(" " * (adapters.NATIVE_LIMIT + 1))
                self.assertIn("larger than", self.adapt(family)[1][0][1])
                path.unlink()
                path.symlink_to(self.folder / "absent")
                self.assertTrue(self.adapt(family)[1])
                path.unlink()
                path.mkdir()
                self.assertTrue(self.adapt(family)[1])
                path.rmdir()
                path.write_text("{partial")
                self.assertTrue(self.adapt(family)[1])
                path.unlink()
                self.folder.rmdir()
                self.assertTrue(self.adapt(family)[1], "missing declared directory is not idle success")
                self.folder.mkdir()

    def test_cache_once_per_change_and_pruned_open(self):
        family = "native-tj-step"
        path = put(self.folder / "record.json", dict(sample(family), rc=2))
        with patch.object(adapters, "native_json", wraps=adapters.native_json) as reader:
            first = self.adapt(family)
            self.assertEqual(first, self.adapt(family))
            self.assertEqual(1, reader.call_count)
            put(path, dict(sample(family), rc=None, ended=None))
            self.adapt(family)
            self.assertEqual(2, reader.call_count)
        path.unlink()
        docs, bad = self.adapt(family)
        self.assertEqual("accepted", docs[0]["state"])
        self.assertIn("pruned", bad[0][1])
        put(path, sample(family))
        self.assertEqual("done", self.adapt(family)[0][0]["state"])
        path.unlink()
        self.assertEqual(([], []), self.adapt(family))
        self.assertEqual({}, self.cache["files"])

    def test_permission_failure_and_read_budget_are_visible(self):
        family = "native-tj-step"
        path = put(self.folder / "record.json", sample(family))
        if os.geteuid() != 0:
            path.chmod(0)
            try:
                self.assertTrue(self.adapt(family)[1], "permission refusal must be a source problem")
            finally:
                path.chmod(0o600)
        else:
            with patch.object(adapters, "native_json", side_effect=PermissionError("permission denied")):
                self.assertTrue(self.adapt(family)[1])
            path.touch()  # make the denied parse cache stale
        path.unlink()
        for i in range(17):
            put(self.folder / f"{i:02d}.json", dict(sample(family), padding="x" * (adapters.NATIVE_LIMIT - 1000)))
        before = {p.name: p.read_bytes() for p in self.folder.glob("*.json")}
        docs, bad = self.adapt(family)
        self.assertTrue(bad)
        self.assertIn("this pass", bad[0][1])
        self.assertLess(len(docs), 17)
        docs, bad = self.adapt(family)
        self.assertEqual([], bad)
        self.assertEqual(17, len(docs))
        self.assertEqual(before, {p.name: p.read_bytes() for p in self.folder.glob("*.json")})
        self.assertLess(len(json.dumps(self.cache)), 100000, "cache must hold projections, not padding")

    def test_selection_cap_no_recursion_and_collision(self):
        family = "native-tj-step"
        put(self.folder / "nested/record.json", sample(family))
        put(self.folder / ".ignored.json", {"unknown": True})
        self.assertEqual(([], []), self.adapt(family))
        for i in range(adapters.NATIVE_FILES + 1):
            put(self.folder / f"{i % 2}-{i}.json", sample(family))
        self.assertIn("exceeds", self.adapt(family)[1][0][1])
        # A real retained step directory exceeds the cap: selection, not directory
        # size, is bounded. Exhaustive disjoint stages must each stay below it.
        selected = set()
        for pattern in ("0-*.json", "1-*.json"):
            docs, bad = self.adapt(family, pattern)
            self.assertEqual([], bad)
            records = {d["record"] for d in docs}
            self.assertLessEqual(len(records), adapters.NATIVE_FILES)
            self.assertFalse(selected & records)
            selected.update(records)
        self.assertEqual(adapters.NATIVE_FILES + 1, len(selected))
        for p in self.folder.glob("[0-9]*.json"):
            p.unlink()
        family = "native-manifest-verified"
        put(self.folder / "a.json", sample(family))
        put(self.folder / "b.json", sample(family))
        self.assertIn("duplicate", self.adapt(family)[1][0][1])

    def test_cursor_eof_backlog_partial_rotation_and_shape(self):
        family = "native-capacity-cursor"
        signal = self.folder / "capacity.signal"
        signal.write_bytes(b"line1\nline2\npartial")
        st = signal.stat()
        path = self.folder / "capacity.cursor.json"
        def cursor(offset):
            raw = signal.read_bytes()
            return {"dev": st.st_dev, "ino": st.st_ino, "offset": offset,
                    "tail": hashlib.sha256(raw[max(0, offset - 256):offset]).hexdigest()}
        self.assertEqual("accepted", self.one(family, cursor(6), path.name)["state"])
        self.assertEqual("accepted", self.one(family, cursor(12), path.name)["state"])
        signal.write_bytes(b"line1\nline2\n")
        self.assertEqual("done", self.adapt(family)[0][0]["state"])
        signal.write_bytes(b"line1\nline2\nnew\n")
        self.assertEqual("accepted", self.adapt(family)[0][0]["state"])
        for change in ({"tail": "0" * 64}, {"offset": 1000}, {"ino": st.st_ino + 1},
                       {"schema": "cursor/v1"}, {"offset": True}):
            with self.subTest(change=change):
                put(path, dict(cursor(12), **change))
                self.assertTrue(self.adapt(family)[1])
        put(path, cursor(12))
        signal.unlink()
        self.assertTrue(self.adapt(family)[1])

    def test_cli_accepts_receipts_but_not_native_outbox(self):
        family = "native-manifest-verified"
        doc = self.one(family, sample(family))
        proto, stage = self.protocol(family)
        fragment = {"format": "handoff-registry/v1", "home": OWNER, "publisher": "test", "revision": 1,
                    "published_at": T, "protocols": [proto]}
        frag = put(self.folder / ".fragment.json", fragment)
        receipt = put(self.folder / ".receipt.json", doc)
        def run(*args):
            return subprocess.run([sys.executable, str(ROOT / "bin/fm-handoff-validate.py"), *map(str, args)],
                                  capture_output=True, text=True, env=ENV, timeout=30)
        result = run("receipt", "--fragment", frag, receipt)
        self.assertEqual(0, result.returncode, result.stdout + result.stderr)
        self.assertEqual(1, run("outbox", "--fragment", frag, self.folder).returncode)
        put(self.folder / "20261024T160000.000000Z-0123456789abcdef.json", sample(family))
        self.assertEqual(1, run("outbox", "--fragment", frag, self.folder).returncode)

    def test_watcher_levels_unknown_and_prune_across_restart(self):
        machine = self.folder / "machine"
        for hid in (OWNER, "main", "tooling-mate"):
            (machine / hid / "state").mkdir(parents=True)
        old_folder, self.folder = self.folder, self.folder / "sources"
        self.folder.mkdir()
        proto, stage = self.protocol("native-tj-step")
        self.folder = old_folder
        fragment = {"format": "handoff-registry/v1", "home": OWNER, "publisher": "test", "revision": 1,
                    "published_at": T, "protocols": [proto]}
        frag = put(machine / OWNER / "state/handoff-registry/native.json", fragment)
        record = put(Path(stage["input"]["path"]) / "step.json", dict(sample("native-tj-step"), rc=75, result_word="WAIT"))
        def tick():
            proc = subprocess.run([sys.executable, str(ROOT / "bin/fm-handoff-watch.py"), "tick", "--root", str(machine),
                                   "--home", str(machine / OWNER), "--now", str(int(NOW + 7200))],
                                  capture_output=True, text=True, env=ENV, timeout=60)
            self.assertEqual(0, proc.returncode, proc.stdout + proc.stderr)
            return json.loads((machine / OWNER / f"state/handoff-watch/stores/{OWNER}.json").read_text())["active"]
        alarms = tick()
        self.assertTrue(any(k.startswith("hw-held-") for k in alarms))
        self.assertTrue(any(k.startswith("hw-open-past-bound-") for k in alarms))
        record.unlink()
        alarms = tick()
        self.assertTrue(any(k.startswith("hw-held-") for k in alarms))
        self.assertTrue(any(k.startswith("hw-source-unreadable-") for k in alarms))
        put(record, dict(sample("native-tj-step"), schema="tj-step-receipt/v99"))
        self.assertTrue(any(k.startswith("hw-held-") for k in tick()))
        put(record, sample("native-tj-step"))
        self.assertFalse(tick(), "completion clears all levels")
        # Switch to an ordinary outbox without allowing input/outbox aliasing.
        del stage["ext"]
        stage["input"]["path"] = str(self.folder / "empty-input")
        Path(stage["input"]["path"]).mkdir()
        fragment["revision"] += 1
        put(frag, fragment)
        self.assertTrue(any(k.startswith("hw-unregistered-receipt-") for k in tick()))

    def test_watcher_invalid_adapter_cannot_erase_previous_state(self):
        import importlib.util
        spec = importlib.util.spec_from_file_location("native_watch", ROOT / "bin/fm-handoff-watch.py")
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        machine = self.folder / "machine"
        (machine / OWNER / "state").mkdir(parents=True)
        watcher = module.Watch(machine / OWNER, machine, NOW)
        proto, stage = self.protocol("native-tj-step")
        watcher.protocols = {proto["id"]: proto}
        old = {"pairs": [], "cur": {"state": "held"}}
        valid = adapters.receipt(proto, stage, "new", NOW, "done", self.folder / "new.json")
        cases = [[dict(valid, protocol="elsewhere")], [dict(valid, state="unexpected")],
                 [valid, dict(valid, receipt_id="f" * 16)]]
        for docs in cases:
            with self.subTest(docs=docs):
                state = {"records": {"old": old}}
                with patch.object(adapters, "adapt", return_value=(docs, [])):
                    watcher.read_adapter(proto, stage, "stage:scope", state)
                self.assertIn("old", state["records"])
                self.assertIn("stage:scope", watcher.incomplete)


unittest.main(argv=[sys.argv[0]], verbosity=2)
