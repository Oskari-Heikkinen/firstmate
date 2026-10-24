"""Native observation cases called by fm-handoff-firstmate.test.sh; scratch paths only."""
import copy
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
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


def replace_bytes(path, data):
    # Publish a distinct inode rather than relying on timestamp granularity for
    # same-sized updates. No sleeps or production cache bypasses are needed.
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(dir=path.parent, prefix=".fixture-", delete=False) as stream:
        temporary = Path(stream.name)
        stream.write(data)
    temporary.replace(path)
    return path


def put(path, doc):
    return replace_bytes(path, (json.dumps(doc) + "\n").encode())


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


def event(kind, subject="pkg-b12-old", phase="fetch", at="2026-10-24T15:00:00Z", reason="native reason"):
    # Source-shaped normalized native events, not a captured aggregate snapshot.
    eid = hashlib.sha256(json.dumps([kind, subject, phase, at, reason]).encode()).hexdigest()[:16]
    alias = re.search(r"(?:^|-)(b\d+)(?:-|$)", subject)
    return {"id": eid, "kind": kind, "subject": subject, "phase": phase, "at": at,
            "alias": alias.group(1) if alias else None, "source": "step-receipt",
            "receipt": f"/fixture/native/{eid}.json", "facts": {"reason": reason}}


def snapshot(events, **changes):
    return dict({"schema": "tj-receipt-events/v1", "version": "tj-auto-receipts/1.1", "scanned_at": T,
                 "inputs": {"step_receipts": len(events)}, "problems": [], "events": events}, **changes)


class NativeAdapters(unittest.TestCase):
    def setUp(self):
        self.folder = TMP / self.id().split(".")[-1]
        self.folder.mkdir(parents=True)
        self.cache = {}

    def protocol(self, family, match="*.json"):
        if family == "native-capacity-cursor" and match == "*.json":
            match = "capacity.cursor.json"
        if family == "native-tj-open-holds" and match == "*.json":
            match = "events.json"
        stage = {"name": "observe", "owner": OWNER, "accepts": {"min": 0, "max": 1},
                 "input": {"path": str(self.folder), "reach": {"kind": "local"}, "match": match},
                 "outbox": {"path": str(self.folder), "reach": {"kind": "local"}},
                 "bounds": {"accepted": "1h", "held": "1h", "waiting": "1h"}, "retry_limit": 0,
                 "codes": {code: {"fix_owner": OWNER, "holds_all": False, "what": code}
                           for code in ("native-refused", "native-wait", "native-failed")},
                 "cleanup": {"action": "keep"}, "ext": {f"{OWNER}.receipt-adapter": family}}
        if family == "native-tj-open-holds":
            stage["ext"][f"{OWNER}.native-snapshot-max-age-seconds"] = 86400
        proto = {"id": "native.test", "owner": OWNER, "title": "native observation", "schema": "fixture:local",
                 "record_types": ["native/v1"], "versions": {"min": 0, "max": 99}, "senders": [OWNER],
                 "first_stage": "observe", "stages": [stage],
                 "cleanup": {"stage": "observe", "receipts_after": "7d", "records_after": "7d"}}
        return proto, stage

    def adapt(self, family, match="*.json", now=NOW):
        proto, stage = self.protocol(family, match)
        docs, problems = adapters.adapt(proto, stage, self.cache, now)
        for doc in docs:
            self.assertEqual([], validate.Schema(str(ROOT / "docs/handoff-coverage/handoff-receipt-v1.schema.json")).errors(doc))
            self.assertEqual([], validate.receipt_problems(doc, {proto["id"]: proto}))
            self.assertFalse(doc["ext"][f"{OWNER}.native-attempts-known"])
            self.assertEqual(0 if family == "native-capacity-cursor" else 1, doc["version"])
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
            replace_bytes(self.folder / source.name, source.read_bytes())

    def watcher_fixture(self, family):
        machine = self.folder / "machine"
        for hid in (OWNER, "main", "tooling-mate"):
            (machine / hid / "state").mkdir(parents=True)
        self.folder = self.folder / "sources"
        self.folder.mkdir()
        proto, stage = self.protocol(family)
        fragment = {"format": "handoff-registry/v1", "home": OWNER, "publisher": "test", "revision": 1,
                    "published_at": T, "protocols": [proto]}
        frag = put(machine / OWNER / "state/handoff-registry/native.json", fragment)
        def tick():
            # A separate process each pass exercises persisted restart state.
            proc = subprocess.run([sys.executable, str(ROOT / "bin/fm-handoff-watch.py"), "tick", "--root", str(machine),
                                   "--home", str(machine / OWNER), "--now", str(int(NOW + 7200))],
                                  capture_output=True, text=True, env=ENV, timeout=60)
            self.assertEqual(0, proc.returncode, proc.stdout + proc.stderr)
            state = machine / OWNER / "state/handoff-watch"
            store = state / f"stores/{OWNER}.json"
            if store.exists():
                alarms = json.loads(store.read_text())["active"]
            else:
                # A clean first pass has no target store until an alarm is raised.
                # Do not mask a missing store that should have received an alarm.
                pending = json.loads((state / "alarms.json").read_text())["alarms"]
                self.assertFalse(any(OWNER in a["routed"] for a in pending.values()))
                self.assertFalse((state / "undeliverable").exists(), proc.stdout + proc.stderr)
                alarms = {}
            records = json.loads((state / "stages/native.test--observe.json").read_text())["records"]
            return alarms, records
        return frag, tick

    def test_real_fixture_seal(self):
        provenance = json.loads((REAL / "provenance.json").read_text())
        self.assertEqual("44fd3bc7f3fdc056b397538cd10ba25423f4b366b706ec46ad376d3c93dd13a8",
                         provenance["owner_manifest_sha256"])
        self.assertFalse(provenance["real_cursor_supplied"])
        self.assertEqual(10, len(provenance["files"]))
        for name, sha in provenance["files"].items():
            self.assertEqual(sha, hashlib.sha256((REAL / name).read_bytes()).hexdigest(), name)
        probe = provenance["manifest_probe"]
        self.assertEqual("../verified.json", probe["fixture"])
        self.assertFalse(probe["real_production_record"])
        self.assertEqual("e99f0975be174deb30aaf4ac1ba0b8a33827e5d5203f9dd2b9f2e08bab57e313", probe["source_sha256"])
        self.assertEqual(probe["sha256"], hashlib.sha256((REAL / probe["fixture"]).read_bytes()).hexdigest())

    def test_real_queue_refusal_then_acceptance(self):
        family = "native-tj-handoff"
        refused = next((REAL / "queue").glob("request-refused*.json"))
        replace_bytes(self.folder / refused.name, refused.read_bytes())
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

    def test_step_long_null_fallback_adapter_cli_and_watcher(self):
        family = "native-tj-step"
        frag, tick = self.watcher_fixture(family)
        prefix = "wrapper rc=0 result_word=None; not downstream completion; result="
        lengths = (900, 999 - len(prefix), 1000 - len(prefix), 1001 - len(prefix), 1000, 4096)
        for length in lengths:
            for rc in (0, 1):
                with self.subTest(length=length, rc=rc):
                    result = "x" * length
                    doc = self.one(family, dict(sample(family), rc=rc, result_word=None, result=result))
                    full = f"wrapper rc={rc} result_word=None; not downstream completion; result={result}"
                    self.assertEqual(full, doc["ext"][f"{OWNER}.native-outcome"])
                    self.assertLessEqual(len(doc["detail"]), 1000)
                    if len(full) > 1000:
                        self.assertIn("display preview; full native-outcome in ext", doc["detail"])
                        self.assertIn("not downstream completion", doc["detail"])
                    else:
                        self.assertEqual(full, doc["detail"])
                    receipt = put(self.folder / ".receipt.json", doc)
                    check = subprocess.run([sys.executable, str(ROOT / "bin/fm-handoff-validate.py"), "receipt",
                                            "--fragment", str(frag), str(receipt)], capture_output=True, text=True,
                                           env=ENV, timeout=30)
                    self.assertEqual(0, check.returncode, check.stdout + check.stderr)
                    alarms, records = tick()
                    self.assertEqual(["done" if rc == 0 else "held"], [r["cur"]["state"] for r in records.values()])
                    self.assertFalse(any(k.startswith("hw-source-unreadable-") for k in alarms))
                    self.assertEqual(rc != 0, any(k.startswith("hw-held-") for k in alarms))

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

    def test_malformed_native_identity_fields_never_mint_receipts(self):
        cases = [("native-manifest-verified", {}, ("item", "manifest"), "missing native identity fields"),
                 ("native-tj-handoff", {}, ("id", "subject"), "native record identity"),
                 ("native-tetjet-collected", {}, ("batch_id",), "native record identity"),
                 ("native-tetjet-collected", {"kind": "request", "request_id": "request-a",
                                             "request_sha256": SHA, "complete": True, "outcome": "collected"},
                  ("request_id",), "native record identity"),
                 ("native-tj-step", {}, ("subject", "phase"), "native record identity")]
        for family, changes, fields, error in cases:
            for field in fields:
                for value in ("missing", None, 17, [], {}, ""):
                    with self.subTest(family=family, field=field, value=value):
                        self.cache = {}
                        doc = dict(sample(family), **changes)
                        if value == "missing":
                            doc.pop(field, None)
                        else:
                            doc[field] = value
                        path = put(self.folder / "record.json", doc)
                        docs, bad = self.adapt(family)
                        self.assertEqual([], docs)
                        self.assertEqual([path], [p for p, _ in bad])
                        self.assertIn(error, bad[0][1])

    def test_semantic_rejections_are_not_json_or_version_errors(self):
        cases = [("native-tj-handoff", {"kind": "UNSUPPORTED"}, "unknown tj-handoff kind"),
                 ("native-tetjet-collected", {"verification": {"verdict": "FAIL"}}, "verification verdict"),
                 ("native-tetjet-collected", {"verification": []}, "verification verdict"),
                 ("native-tetjet-collected", {"kind": "request", "request_id": "r", "request_sha256": SHA,
                                             "complete": False, "outcome": "collected"}, "incomplete"),
                 ("native-tetjet-collected", {"kind": "request", "request_id": "r", "request_sha256": SHA,
                                             "complete": True, "outcome": "unknown"}, "unknown"),
                 ("native-tj-step", {"rc": None, "ended": T}, "ended without"),
                 ("native-tj-step", {"ended": "2026-10-24T15:00:00Z"}, "ended before"),
                 ("native-manifest-verified", {"result": "FAIL"}, "verification result")]
        cases += [("native-tj-step", {"rc": rc}, "invalid step rc") for rc in (-1, True, "0", 0.5, [])]
        for family, field in (("native-tj-handoff", "artefact"),
                              ("native-tetjet-collected", "request_sha256"),
                              ("native-manifest-verified", "manifest_sha256")):
            for sha in (None, "", "a" * 63, "g" * 64, 12):
                changes = {field: sha}
                if field == "artefact":
                    changes[field] = {"sums_sha256": sha}
                if field == "request_sha256":
                    changes.update(kind="request", request_id="r", complete=True, outcome="collected")
                cases.append((family, changes, "sha256"))
        for family, changes, error in cases:
            with self.subTest(family=family, changes=changes):
                self.cache = {}
                put(self.folder / "record.json", dict(sample(family), **changes))
                docs, bad = self.adapt(family)
                self.assertEqual([], docs)
                self.assertTrue(bad)
                self.assertIn(error, bad[0][1])
        for doc in ([], None, 5, "record"):
            with self.subTest(shape=doc):
                self.cache = {}
                put(self.folder / "record.json", doc)
                docs, bad = self.adapt("native-tj-step")
                self.assertEqual([], docs)
                self.assertIn("not a JSON object", bad[0][1])

    def test_cursor_checkpoint_inside_partial_line_is_rejected(self):
        signal = self.folder / "capacity.signal"
        signal.write_bytes(b"partial")
        st = signal.stat()
        put(self.folder / "capacity.cursor.json", {"dev": st.st_dev, "ino": st.st_ino,
            "offset": 7, "tail": hashlib.sha256(b"partial").hexdigest()})
        docs, bad = self.adapt("native-capacity-cursor")
        self.assertEqual([], docs)
        self.assertIn("not after a complete signal line", bad[0][1])

    def test_invalid_request_identity_preserves_refusal_through_watcher_restart(self):
        family = "native-tj-handoff"
        _, tick = self.watcher_fixture(family)
        source = self.folder / "record.json"
        refused = dict(sample(family), kind="REQUEST REFUSED")
        put(source, refused)
        alarms, records = tick()
        key = f"request:example:{SHA}"
        self.assertEqual("refused", records[key]["cur"]["state"])
        for field in ("id", "subject", "artefact"):
            for value in ("missing", None, "", 17):
                with self.subTest(field=field, value=value):
                    doc = dict(sample(family))
                    if value == "missing":
                        doc.pop(field)
                    else:
                        doc[field] = value
                    put(source, doc)
                    alarms, records = tick()
                    self.assertEqual({key}, set(records))
                    self.assertEqual("refused", records[key]["cur"]["state"])
                    self.assertTrue(any(k.startswith("hw-source-unreadable-") for k in alarms))
                    self.assertTrue(any(k.startswith("hw-refused-") for k in alarms))

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
                replace_bytes(path, b" " * (adapters.NATIVE_LIMIT + 1))
                self.assertIn("larger than", self.adapt(family)[1][0][1])
                path.unlink()
                path.symlink_to(self.folder / "absent")
                self.assertTrue(self.adapt(family)[1])
                path.unlink()
                path.mkdir()
                self.assertTrue(self.adapt(family)[1])
                path.rmdir()
                replace_bytes(path, b"{partial")
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
            put(path, sample(family))  # distinct inode makes denied parse cache stale
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

    def test_open_holds_native_closure_matrix(self):
        family = "native-tj-open-holds"
        closures = {"launch": ("launched", "fetched", "closed"), "relaunch": ("launched", "fetched", "closed"),
                    "fetch": ("fetched", "closed"), "remove": ("removed",), "other": ()}
        for phase, kinds in closures.items():
            for kind in ("launched", "fetched", "closed", "removed"):
                for at in ("2026-10-24T14:00:00Z", "2026-10-24T15:00:00Z", "2026-10-24T15:30:00Z"):
                    with self.subTest(phase=phase, kind=kind, at=at):
                        self.cache = {}
                        put(self.folder / "events.json", snapshot([event("held", phase=phase), event(kind, at=at)]))
                        docs, bad = self.adapt(family)
                        self.assertEqual([], bad)
                        closed = kind in kinds and (at >= "2026-10-24T15:00:00Z"
                                                    or (phase == "relaunch" and kind in ("fetched", "closed")))
                        self.assertEqual(["done" if closed else "held"], [d["state"] for d in docs])
                        expected_at = T if closed else "2026-10-24T15:00:00Z"
                        self.assertEqual(adapters.utc(adapters.native_time(expected_at)), docs[0]["written_at"])
        for phase in ("launch", "relaunch", "fetch", "remove"):
            for subject in ("new-kit-b12-recut", "new-kit-b13-other"):
                with self.subTest(phase=phase, subject=subject):
                    self.cache = {}
                    put(self.folder / "events.json", snapshot([event("held", phase=phase),
                        event("launched", subject=subject, phase="launch", at="2026-10-24T15:30:00Z")]))
                    docs, bad = self.adapt(family)
                    self.assertEqual([], bad)
                    self.assertEqual("done" if phase == "launch" and "b12" in subject else "held", docs[0]["state"])

    def test_open_holds_wait_pending_and_native_ties(self):
        family = "native-tj-open-holds"
        put(self.folder / "events.json", snapshot([event("waiting"), event("step"), event("checked")]))
        self.assertEqual(([], []), self.adapt(family), "WAIT/pending are not operational held events")
        for phase in (None, "", "fetch"):
            for reasons in (("first", "last"), ("last", "first")):
                self.cache = {}
                put(self.folder / "events.json", snapshot([event("held", phase=phase, reason=r) for r in reasons]))
                docs, bad = self.adapt(family)
                self.assertEqual([], bad)
                self.assertIn(": " + reasons[-1] + ";", docs[0]["detail"])
                expected = hashlib.sha256(json.dumps(["pkg-b12-old", phase or "other"]).encode()).hexdigest()
                self.assertEqual(expected, docs[0]["record"])

    def test_open_holds_real_step_derived_events_are_not_live_aggregate(self):
        # These are generated normalized events from the real step pair, not a
        # claimed real native events.json fixture or a run of the native reader.
        family = "native-tj-open-holds"
        steps = [json.loads(p.read_text()) for p in (REAL / "steps").glob("allin-*.json")]
        derived = [event("waiting" if d["result_word"] == "WAIT" else "fetched", subject=d["subject"],
                         phase=d["phase"], at=d["ended"].split(".")[0] + "Z", reason=d["result"]) for d in steps]
        put(self.folder / "events.json", snapshot(derived))
        self.assertEqual(([], []), self.adapt(family))
        wait = next(e for e in derived if e["kind"] == "waiting")
        fetched = next(e for e in derived if e["kind"] == "fetched")
        # A derived failure of the same operation closes on the later real fetch.
        put(self.folder / "events.json", snapshot([dict(wait, kind="held"), fetched]))
        docs, bad = self.adapt(family)
        self.assertEqual([], bad)
        self.assertEqual(["done"], [d["state"] for d in docs])

    def test_open_holds_pruning_restart_terminal_watermark_and_new_failure(self):
        family = "native-tj-open-holds"
        path = self.folder / "events.json"
        hold = event("held")
        put(path, snapshot([hold]))
        self.assertEqual("held", self.adapt(family)[0][0]["state"])
        self.cache = json.loads(json.dumps(self.cache))  # watcher restart persistence
        put(path, snapshot([]))
        docs, bad = self.adapt(family)
        self.assertEqual("held", docs[0]["state"])
        self.assertIn("disappeared", bad[0][1])
        success = event("fetched", at="2026-10-24T15:30:00Z")
        put(path, snapshot([success]))
        docs, bad = self.adapt(family)
        self.assertEqual([], bad)
        self.assertEqual("done", docs[0]["state"], "explicit native witness resolves a pruned hold")
        for old in (hold, event("held", at="2026-10-24T14:30:00Z")):
            put(path, snapshot([old]))
            self.assertEqual("done", self.adapt(family)[0][0]["state"], "pruned closer cannot resurrect old failure")
        put(path, snapshot([event("held", at="2026-10-24T15:45:00Z")]))
        self.assertEqual("held", self.adapt(family)[0][0]["state"], "a genuinely later failure is evaluated anew")
        put(path, snapshot([event("closed", at="2026-10-24T15:50:00Z")]))
        self.assertEqual("done", self.adapt(family)[0][0]["state"])
        put(path, snapshot([]))
        self.assertEqual(([], []), self.adapt(family), "terminal pruning drops operation history")

    def test_open_holds_errors_freshness_cache_and_bounds(self):
        family = "native-tj-open-holds"
        path = self.folder / "events.json"
        hold = event("held")
        good = snapshot([hold])
        put(path, good)
        with patch.object(adapters, "native_json", wraps=adapters.native_json) as reader:
            docs, bad = self.adapt(family)
            self.assertEqual([], bad)
            self.assertEqual((docs, bad), self.adapt(family))
            self.assertEqual(1, reader.call_count)
            stale_docs, stale = self.adapt(family, now=NOW + 86401)
            self.assertEqual(docs, stale_docs)
            self.assertIn("stale", stale[0][1])
            self.assertEqual(1, reader.call_count, "unchanged aggregate is not re-read for freshness")
        errors = [dict(good, schema="tj-receipt-events/v2"), dict(good, problems=[{"error": "native failed"}]),
                  dict(good, scanned_at="2026-10-24T15:59:00Z"), dict(good, scanned_at="2026-10-24T17:00:00Z"),
                  dict(good, events=[dict(hold, kind="unknown")]), dict(good, events=[dict(hold, alias="b999")]),
                  dict(good, events=[dict(hold, at="not UTC")]), dict(good, events=[hold, hold]),
                  dict(good, inputs={"step_receipts": True}), dict(good, events={})]
        for bad_doc in errors:
            put(path, bad_doc)
            docs, bad = self.adapt(family)
            self.assertTrue(bad)
            self.assertEqual(["held"], [d["state"] for d in docs])
        put(path, dict(good, padding="x" * (adapters.NATIVE_LIMIT + 1)))
        docs, bad = self.adapt(family)
        self.assertEqual([], bad, "aggregate cap is distinct from per-invocation JSON cap")
        self.assertLess(len(json.dumps(self.cache)), 50000, "no full snapshot/padding in cache")
        with patch.object(adapters.open_holds, "EVENT_LIMIT", 1):
            put(path, snapshot([hold, event("held", subject="other")]))
            self.assertIn("at most", self.adapt(family)[1][0][1])
        with patch.object(adapters.open_holds, "OPERATION_LIMIT", 1):
            put(path, snapshot([hold, event("held", subject="other")]))
            self.assertIn("retention exceeds", self.adapt(family)[1][0][1])
        replace_bytes(path, b" " * (adapters.NATIVE_PASS_BYTES + 1))
        self.assertIn("larger than", self.adapt(family)[1][0][1])
        path.unlink()
        path.symlink_to(REAL / "provenance.json")
        self.assertTrue(self.adapt(family)[1])
        path.unlink()
        self.assertTrue(self.adapt(family)[1])
        put(path, good)
        proto, stage = self.protocol(family)
        del stage["ext"][f"{OWNER}.native-snapshot-max-age-seconds"]
        self.assertIn("policy", adapters.adapt(proto, stage, self.cache, NOW)[1][0][1])
        self.assertIn("exact", self.adapt(family, "*.events.json")[1][0][1])

    def test_open_holds_current_source_annotation_and_fixture_seals(self):
        family = "native-tj-open-holds"
        fixture = ROOT / "tests/fixtures/handoff-coverage/native/open-holds"
        provenance = json.loads((fixture / "provenance.json").read_text())
        for name, key in (("extract.json", "extract"), ("incomplete-header.json", "incomplete_header")):
            self.assertEqual(provenance[key]["sha256"], hashlib.sha256((fixture / name).read_bytes()).hexdigest())
            self.assertFalse(provenance[key]["complete_snapshot"])
        extract = json.loads((fixture / "extract.json").read_text())
        by_selection = {e["selection"]: e["event"] for e in extract}
        native_closed = by_selection["held-with-native-closed_at"]
        # Generated complete-shaped frames from the sealed small real extract;
        # NOT the original aggregate, which has a source problem and cannot pass.
        put(self.folder / "events.json", snapshot([native_closed, by_selection["waiting-not-held"]]))
        docs, bad = self.adapt(family)
        self.assertEqual([], bad)
        self.assertEqual(["done"], [d["state"] for d in docs])
        self.assertIn(native_closed["facts"]["closed_by"], docs[0]["detail"])
        self.assertIn("not proof of removal", docs[0]["detail"])

    def test_open_holds_current_class_key_rules(self):
        family = "native-tj-open-holds"
        fixture = ROOT / "tests/fixtures/handoff-coverage/native/open-holds"
        extract = json.loads((fixture / "extract.json").read_text())
        real_removed = next(e["event"] for e in extract if e["selection"] == "runner-class-removed")
        composite = f"{real_removed['facts']['class']}:{real_removed['facts']['root_kind']}:{real_removed['subject']}"
        held = event("held", subject=composite, phase="remove", at="2026-09-28T12:00:00Z")
        for source, at, expected in (("runner-class-receipt", real_removed["at"], "done"),
                                     ("runner-receipt", real_removed["at"], "held"),
                                     ("runner-class-receipt", "2026-09-28T11:00:00Z", "held")):
            with self.subTest(source=source, at=at):
                self.cache = {}
                put(self.folder / "events.json", snapshot([held, dict(real_removed, source=source, at=at)]))
                docs, bad = self.adapt(family)
                self.assertEqual([], bad)
                self.assertEqual(expected, docs[0]["state"])
                self.assertLessEqual(len(docs[0]["detail"]), 1000)
                if expected == "done":
                    self.assertIn(real_removed["facts"]["result"], docs[0]["ext"][f"{OWNER}.native-outcome"])
                    self.assertIn("full native-outcome in ext", docs[0]["detail"])
        # Follow P exactly: its additional removed key is registered for each
        # allowed success of that source, not only today's emitted removed kind.
        self.cache = {}
        put(self.folder / "events.json", snapshot([held, dict(real_removed, kind="fetched")]))
        self.assertEqual("done", self.adapt(family)[0][0]["state"])

    def test_open_holds_known_neutrals_and_real_incomplete_header(self):
        family = "native-tj-open-holds"
        fixture = ROOT / "tests/fixtures/handoff-coverage/native/open-holds"
        provenance = json.loads((fixture / "provenance.json").read_text())
        put(self.folder / "events.json", snapshot([event(k) for k in
            ("waiting", "step", "checked", "escalated", "archive-deleted", "closeout-recorded")]))
        self.assertEqual(([], []), self.adapt(family), "known neutral events neither create nor close holds")
        # Current real incomplete header retains its source problem exactly
        # (username sanitized). Its events are omitted and are never called a
        # full real aggregate: the completeness gate must reject before folding.
        incomplete = json.loads((fixture / "incomplete-header.json").read_text())
        self.assertEqual(provenance["incomplete_header"]["source_problems"], len(incomplete["problems"]))
        put(self.folder / "events.json", incomplete)
        self.assertIn("source problems", self.adapt(family)[1][0][1])
        incomplete["events"] = [{"kind": "unreachable-after-native-source-problem"}]
        put(self.folder / "events.json", incomplete)
        self.assertIn("source problems", self.adapt(family)[1][0][1], "fail closed independently of event payload")

    def test_open_holds_closed_at_filters_before_latest_and_keeps_first_done_time(self):
        family = "native-tj-open-holds"
        path = self.folder / "events.json"
        older = event("held", phase="remove")
        newer = event("held", phase="remove", at="2026-10-24T15:30:00Z")
        annotated = dict(newer, facts={"closed_at": "2026-10-24T15:45:00Z", "closed_by": "stop-cleared: roots retained"})
        put(path, snapshot([older, newer]))
        self.assertIn(newer["id"], self.adapt(family)[0][0]["detail"])
        put(path, snapshot([older, annotated]))
        docs, bad = self.adapt(family)
        self.assertEqual([], bad)
        self.assertEqual("held", docs[0]["state"], "closing the newer stop does not close the older unresolved stop")
        self.assertIn(older["id"], docs[0]["detail"])
        put(path, snapshot([older, newer]))  # annotation is now pruned
        self.assertIn(older["id"], self.adapt(family)[0][0]["detail"], "remembered individual proof filters before latest")
        self.cache = {}
        put(path, snapshot([annotated]))
        self.assertEqual("done", self.adapt(family)[0][0]["state"])
        put(path, snapshot([older, newer]))
        self.assertEqual("held", self.adapt(family)[0][0]["state"], "a different older stop is not closed by another event's annotation")
        self.assertIn(older["id"], self.adapt(family)[0][0]["detail"])
        # Native same-time selection must filter closed facts BEFORE the tie.
        self.cache = {}
        same_time_closed = dict(annotated, at=older["at"])
        put(path, snapshot([older, same_time_closed]))
        self.assertEqual("held", self.adapt(family)[0][0]["state"])
        # Explicit removal resolves all remaining observed stops of this subject.
        put(path, snapshot([older, annotated, event("removed", phase="remove", at=T)]))
        docs, bad = self.adapt(family)
        self.assertEqual([], bad)
        self.assertEqual("done", docs[0]["state"])
        first_done = docs[0]["written_at"]
        self.cache = json.loads(json.dumps(self.cache))
        put(path, snapshot([older, annotated, event("removed", phase="remove", at=T)], scanned_at="2026-10-24T17:00:00Z"))
        docs, bad = self.adapt(family, now=NOW + 3600)
        self.assertEqual([], bad)
        self.assertEqual(first_done, docs[0]["written_at"], "fresh scans do not move first accepted terminal observation")

    def test_open_holds_individual_closure_does_not_erase_retained_other_stop(self):
        family = "native-tj-open-holds"
        path = self.folder / "events.json"
        older = event("held", phase="remove")
        newer = event("held", phase="remove", at="2026-10-24T15:30:00Z")
        put(path, snapshot([older]))
        self.adapt(family)
        put(path, snapshot([newer]))
        self.assertTrue(self.adapt(family)[1], "pruned observed unresolved stop is retained beside new stop")
        self.cache = json.loads(json.dumps(self.cache))
        annotated = dict(newer, facts={"closed_at": "2026-10-24T15:45:00Z", "closed_by": "stop-cleared: roots retained"})
        put(path, snapshot([annotated]))
        docs, bad = self.adapt(family)
        self.assertTrue(bad)
        self.assertEqual("held", docs[0]["state"])
        self.assertIn(older["id"], docs[0]["detail"])
        put(path, snapshot([event("removed", phase="remove", at=T)]))
        self.assertEqual("done", self.adapt(family)[0][0]["state"])

    def test_open_holds_simultaneous_stops_pruning_restart_and_individual_close(self):
        self.check_simultaneous_stops_pruning(family_close=False)

    def test_open_holds_simultaneous_stops_pruning_restart_and_family_close(self):
        self.check_simultaneous_stops_pruning(family_close=True)

    def check_simultaneous_stops_pruning(self, family_close):
        family = "native-tj-open-holds"
        _, tick = self.watcher_fixture(family)
        path = self.folder / "events.json"
        older = event("held", phase="remove", at="2026-10-24T14:00:00Z")
        newer = event("held", phase="remove", at="2026-10-24T15:00:00Z")
        annotated = dict(newer, facts={"closed_at": "2026-10-24T15:45:00Z", "closed_by": "stop-cleared: roots retained"})
        put(path, snapshot([older, newer]))
        alarms, records = tick()
        self.assertTrue(any(k.startswith("hw-held-") for k in alarms))
        self.assertIn(newer["id"], next(iter(records.values()))["cur"]["detail"])
        # Older A was observed with B, never selected alone. B's individual
        # annotation cannot prove that the now-pruned A resolved.
        put(path, snapshot([annotated]))
        for _ in range(2):  # unchanged-source pass and process restart keep the obligation
            alarms, records = tick()
            self.assertEqual(["held"], [r["cur"]["state"] for r in records.values()])
            self.assertIn(older["id"], next(iter(records.values()))["cur"]["detail"])
            self.assertTrue(any(k.startswith("hw-held-") for k in alarms))
            self.assertTrue(any(k.startswith("hw-source-unreadable-") for k in alarms))
        if family_close:
            # Actual removal covers both events, even with both source stops pruned.
            put(path, snapshot([event("removed", phase="remove", at=T)]))
        else:
            # A's own closure suffices; B's previously observed annotation is
            # remembered even though the current copy of B lacks it.
            closed_older = dict(older, facts={"closed_at": T, "closed_by": "stop-cleared: A roots retained"})
            put(path, snapshot([closed_older, newer]))
        alarms, records = tick()
        self.assertEqual(["done"], [r["cur"]["state"] for r in records.values()])
        self.assertFalse(alarms, "only explicit individual or family proof clears all levels")

    def test_open_holds_annotation_errors_and_retained_witness_bounds(self):
        family = "native-tj-open-holds"
        path = self.folder / "events.json"
        held = event("held", phase="remove")
        put(path, snapshot([held]))
        baseline, _ = self.adapt(family)
        for facts in ({"closed_at": "not a timestamp", "closed_by": "stop-cleared"},
                      {"closed_at": "2026-10-24T14:00:00Z", "closed_by": "stop-cleared"},
                      {"closed_at": T}, {"closed_at": T, "closed_by": "x" * 4097}):
            put(path, snapshot([dict(held, facts=facts)]))
            docs, bad = self.adapt(family)
            self.assertTrue(bad)
            self.assertEqual(baseline, docs, "invalid closure evidence cannot clear a cached hold")
        newer = event("held", phase="remove", at="2026-10-24T15:30:00Z")
        with patch.object(adapters.open_holds, "WITNESS_LIMIT", 1):
            put(path, snapshot([newer]))
            self.assertIn("witness count", self.adapt(family)[1][0][1])
        with patch.object(adapters.open_holds, "CACHE_BYTES", 1):
            put(path, snapshot([held]))
            self.assertIn("compact projection", self.adapt(family)[1][0][1])

    def test_open_holds_rejected_future_scan_does_not_advance_accepted_clock(self):
        family = "native-tj-open-holds"
        path = self.folder / "events.json"
        held = event("held", phase="remove")
        put(path, snapshot([held]))
        self.adapt(family)
        closed = dict(held, facts={"closed_at": T, "closed_by": "stop-cleared: roots retained"})
        put(path, snapshot([closed], scanned_at="2026-10-24T17:00:00Z"))
        docs, bad = self.adapt(family)
        self.assertIn("future", bad[0][1])
        self.assertEqual("held", docs[0]["state"])
        put(path, snapshot([closed], scanned_at="2026-10-24T16:30:00Z"))
        docs, bad = self.adapt(family, now=NOW + 1800)
        self.assertEqual([], bad, "rejected 17:00 observation never became accepted high-water mark")
        self.assertEqual("done", docs[0]["state"])
        self.assertEqual("2026-10-24T16:30:00.000000Z", docs[0]["written_at"])

    def test_open_holds_generated_six_class_keys_and_operation_not_raw_held_cap(self):
        family = "native-tj-open-holds"
        # A CONSTRUCTED 14-vs-8 regression, not replay of the private complete
        # aggregate: six class-keyed journal holds close on class removals.
        events = [event("held", subject=f"kit-b{i}", phase="launch" if i < 5 else "fetch") for i in range(8)]
        expected_phase = {hashlib.sha256(json.dumps([e["subject"], e["phase"]]).encode()).hexdigest(): e["phase"] for e in events}
        for i in range(6):
            stop = event("held", subject=f"tj-root:tj:mp{i}-root", phase="remove")
            stop["source"] = "runner-journal"
            removed = event("removed", subject=f"mp{i}-root", phase="remove", at=T)
            removed["source"] = "runner-class-receipt"
            removed["facts"].update({"class": "tj-root", "root_kind": "tj"})
            events.extend([stop, removed])
        put(self.folder / "events.json", snapshot(events))
        docs, bad = self.adapt(family)
        self.assertEqual([], bad)
        self.assertEqual(8, sum(d["state"] == "held" for d in docs))
        self.assertEqual(6, sum(d["state"] == "done" for d in docs))
        self.assertEqual({"launch": 5, "fetch": 3}, {phase: sum(d["state"] == "held" and expected_phase.get(d["record"]) == phase
            for d in docs) for phase in ("launch", "fetch")})
        self.cache = {}
        put(self.folder / "events.json", snapshot([event("held", reason=f"repeat {i}") for i in range(4097)]))
        docs, bad = self.adapt(family)
        self.assertEqual([], bad, "operation cap is not a cap on raw held-event count")
        self.assertEqual(["held"], [d["state"] for d in docs])

    def test_open_holds_watcher_clears_only_on_explicit_native_success(self):
        machine = self.folder / "machine"
        for hid in (OWNER, "main", "tooling-mate"):
            (machine / hid / "state").mkdir(parents=True)
        old_folder, self.folder = self.folder, self.folder / "sources"
        self.folder.mkdir()
        proto, stage = self.protocol("native-tj-open-holds")
        self.folder = old_folder
        fragment = {"format": "handoff-registry/v1", "home": OWNER, "publisher": "test", "revision": 1,
                    "published_at": T, "protocols": [proto]}
        put(machine / OWNER / "state/handoff-registry/native.json", fragment)
        source = Path(stage["input"]["path"]) / "events.json"
        put(source, snapshot([event("held")]))
        def tick():
            proc = subprocess.run([sys.executable, str(ROOT / "bin/fm-handoff-watch.py"), "tick", "--root", str(machine),
                                   "--home", str(machine / OWNER), "--now", str(int(NOW + 7200))],
                                  capture_output=True, text=True, env=ENV, timeout=60)
            self.assertEqual(0, proc.returncode, proc.stdout + proc.stderr)
            return json.loads((machine / OWNER / f"state/handoff-watch/stores/{OWNER}.json").read_text())["active"]
        self.assertTrue(any(k.startswith("hw-held-") for k in tick()))
        put(source, snapshot([event("waiting")]))
        alarms = tick()
        self.assertTrue(any(k.startswith("hw-held-") for k in alarms))
        self.assertTrue(any(k.startswith("hw-source-unreadable-") for k in alarms))
        put(source, snapshot([event("fetched", at=T)], problems=[{"error": "partial native scan"}]))
        self.assertTrue(any(k.startswith("hw-held-") for k in tick()))
        put(source, snapshot([event("fetched", at=T)]))
        self.assertFalse(tick(), "native closure proof clears held, past-bound and source-error levels")

    def test_watcher_invalid_adapter_cannot_erase_previous_state(self):
        import importlib.util
        spec = importlib.util.spec_from_file_location("native_watch", ROOT / "bin/fm-handoff-watch.py")
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        machine = self.folder / "machine"
        (machine / OWNER / "state").mkdir(parents=True)
        watcher = module.Watch(machine / OWNER, machine, NOW)
        proto, stage = self.protocol("native-tj-step")
        proto["versions"] = {"min": 1, "max": 1}
        other = copy.deepcopy(proto)
        other["id"] = "elsewhere"
        alternate = copy.deepcopy(stage)
        alternate["name"] = "alternate"
        proto["stages"].append(alternate)
        watcher.protocols = {proto["id"]: proto, other["id"]: other}
        held = adapters.receipt(proto, stage, "same", NOW, "held", self.folder / "record.json", code="native-failed")
        done = adapters.receipt(proto, stage, "same", NOW, "done", self.folder / "record.json")
        foreign = dict(done, protocol="elsewhere")
        foreign_stage = dict(done, stage="alternate")
        for doc in (held, done, foreign, foreign_stage):
            self.assertEqual([], watcher.receipt_schema.errors(doc))
            self.assertEqual([], validate.receipt_problems(doc, watcher.protocols))
        for docs, message in (([foreign], "different protocol/stage"),
                              ([foreign_stage], "different protocol/stage"),
                              ([dict(done, state="unexpected")], "invalid receipt"),
                              ([held, done], "duplicate native record identity")):
            with self.subTest(docs=docs):
                watcher.incomplete.clear()
                watcher.alarms.clear()
                old = {"pairs": [], "cur": {"state": "held"}}
                state = {"records": {"same": copy.deepcopy(old)}}
                with patch.object(adapters, "adapt", return_value=(docs, [])):
                    watcher.read_adapter(proto, stage, "stage:scope", state)
                self.assertEqual("held", state["records"]["same"]["cur"]["state"])
                self.assertIn("stage:scope", watcher.incomplete)
                self.assertTrue(any(message in a["reason"] for a in watcher.alarms.values()))


unittest.main(argv=[sys.argv[0]], verbosity=2)
