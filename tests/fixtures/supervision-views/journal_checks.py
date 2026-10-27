"""CI-only immutable journal API controls, not service/effect-owner acceptance."""
from contextlib import nullcontext
import copy
import errno
import hashlib
import os
import signal
import socket
import subprocess
import unittest
from unittest.mock import patch

from lifecycle_checks import LifecycleContracts
from fm_view_bundle import packed
import fm_view_journal as journal


class LifecycleDecisions(unittest.TestCase):
    # Reuse fixture construction, without inheriting/reexecuting its test pool.
    file = LifecycleContracts.file
    call = LifecycleContracts.call
    command = LifecycleContracts.command
    public_validate = LifecycleContracts.public_validate

    def setUp(self):
        LifecycleContracts.setUp(self)
        self.fragment["protocols"][0]["stages"][0]["planned"] = False
        self.file("fragment.json", self.fragment)
        (self.outbox / ".tmp").mkdir(mode=0o700)
        self.filename = "start-a.1.json"
        self.input(self.request)

    def input(self, value, name=None):
        target = self.inbox / (name or self.filename)
        target.write_bytes(value if type(value) is bytes else packed(value))
        target.chmod(0o600)
        return target

    def open(self, fragment=None):
        return journal.LifecycleJournal(self.home, fragment or self.fragment)

    def receipts(self):
        return {p.name: p.read_bytes() for p in self.outbox.iterdir() if not p.name.startswith(".")}

    def admit(self, name=None):
        with self.open() as transaction:
            return transaction.admit(name or self.filename)

    def test_fresh_and_replayed_acceptance_never_imply_effect_completion(self):
        before = {str(p): p.read_bytes() for p in self.state.glob("*.status")}
        value = self.admit()
        self.assertTrue(value["fresh"])
        self.assertEqual((value["receipt"]["state"], value["receipt"]["seq"]), ("accepted", 1))
        files = self.receipts()
        self.assertEqual(len(files), 1)
        for name in files: self.public_validate("receipt", self.outbox / name, fragment=True)
        for _ in range(3):
            # A new object simulates loss of ALL process memory after commit.
            self.assertEqual(self.admit(), {"fresh": False, "receipt": value["receipt"]})
        self.assertEqual(self.receipts(), files)
        self.assertEqual(before, {str(p): p.read_bytes() for p in self.state.glob("*.status")})
        self.public_validate("outbox", self.outbox, fragment=True)

    def test_complete_sequence_is_immutable_and_publicly_valid(self):
        accepted = self.admit()["receipt"]
        first = self.receipts()
        with self.open() as transaction:
            result = transaction.complete(self.filename)
        self.assertEqual((result["state"], result["seq"], result["ext"]), ("done", 2, accepted["ext"]))
        self.assertEqual(self.admit(), {"fresh": False, "receipt": result})
        self.assertEqual({k: self.receipts()[k] for k in first}, first)
        self.public_validate("outbox", self.outbox, fragment=True)
        final = self.receipts()
        with self.open() as transaction:
            self.assertEqual(transaction.complete(self.filename), result)
        self.assertEqual(self.receipts(), final)
        with self.open() as transaction, self.assertRaisesRegex(ValueError, "lacks matching accepted"):
            transaction.complete(self.filename, code="effect-failed")

    def test_filename_bound_invalid_intake_and_unknown_version_receipts(self):
        malformed = [b"", b" \n", b"{", b'{"schema":NaN}\n', b'{"schema":1,"schema":2}\n',
                     b'{}\0\n', packed(self.request)[:-1], b" " * 65537]
        for number, raw in enumerate(malformed):
            name = "invalid-" + str(number) + ".1.json"
            self.input(raw, name)
            result = self.admit(name)
            self.assertEqual((result["receipt"]["record"], result["receipt"]["code"]),
                             ("invalid-" + str(number), "input-invalid"))
        wrong = dict(self.request, record="foreign")
        self.input(wrong, "filename.1.json")
        result = self.admit("filename.1.json")["receipt"]
        self.assertEqual((result["record"], result["code"]), ("filename", "input-invalid"))
        unknown = {key: self.request[key] for key in ("schema", "record", "attempt", "home", "owner")}
        unknown.update(record="unknown", version=7, uninterpretable={"x": [None]})
        self.input(unknown, "unknown.1.json")
        result = self.admit("unknown.1.json")["receipt"]
        self.assertEqual((result["version"], result["code"]), (7, "version-unsupported"))
        self.public_validate("outbox", self.outbox, fragment=True)

    def test_nonregular_missing_and_unreadable_intake_are_refusals_not_empty_success(self):
        paths = []
        for name in ("missing", "empty", "fifo", "directory", "symlink", "dangling", "hard", "unreadable"):
            filename = name + ".1.json"; path = self.inbox / filename; paths.append((name, filename, path))
            if name == "empty": self.input(b"", filename)
            if name == "fifo": os.mkfifo(path)
            if name == "directory": path.mkdir()
            if name == "symlink": path.symlink_to(self.inbox / self.filename)
            if name == "dangling": path.symlink_to(self.inbox / "absent")
            if name == "hard": os.link(self.inbox / self.filename, path)
            if name == "unreadable": self.input(self.request, filename).chmod(0)
        for name, filename, _ in paths:
            with self.subTest(name=name):
                value = self.admit(filename)["receipt"]
                self.assertEqual((value["state"], value["code"]), ("refused", "input-invalid"))
                fingerprint = value["ext"]["main.input-sha256"]
                self.assertEqual(fingerprint, hashlib.sha256(b"").hexdigest() if name == "empty" else "unreadable")
        self.assertEqual((self.inbox / self.filename).read_bytes(), packed(self.request))

    def test_changed_input_and_ambiguous_effect_cannot_automatically_retry(self):
        self.admit(); original = self.receipts()
        self.input(dict(self.request, epoch="other"))
        with self.assertRaisesRegex(ValueError, "changed after decision"): self.admit()
        self.assertEqual(self.receipts(), original)
        self.input(self.request)
        with self.open() as transaction: transaction.complete(self.filename, code="effect-failed")
        fragment = copy.deepcopy(self.fragment)
        fragment["protocols"][0]["stages"][0]["retry_limit"] = 2
        self.input(dict(self.request, attempt=2), "start-a.2.json")
        with self.open(fragment) as transaction, self.assertRaisesRegex(ValueError, "next refused attempt"):
            transaction.admit("start-a.2.json")
        self.public_validate("outbox", self.outbox, fragment=True)

    def test_next_attempt_requires_prior_refusal_and_never_rewrites_it(self):
        fragment = copy.deepcopy(self.fragment)
        fragment["protocols"][0]["stages"][0]["retry_limit"] = 2
        self.input(dict(self.request, attempt=2), "start-a.2.json")
        with self.open(fragment) as transaction, self.assertRaisesRegex(ValueError, "next refused attempt"):
            transaction.admit("start-a.2.json")
        self.input(dict(self.request, operation="restart"))
        self.assertEqual(self.admit()["receipt"]["state"], "refused")
        old = self.receipts()
        with self.open(fragment) as transaction:
            result = transaction.admit("start-a.2.json")
        self.assertEqual(result["receipt"]["state"], "accepted")
        self.assertEqual({k: self.receipts()[k] for k in old}, old)

    def test_journal_lock_is_exclusive_and_never_unlinks_its_anchor(self):
        with self.open() as first:
            anchor = self.outbox / ".lifecycle-journal.lock"
            before = anchor.stat()
            with self.assertRaises(BlockingIOError): self.open()
            first.admit(self.filename)
        self.assertEqual((anchor.stat().st_dev, anchor.stat().st_ino), (before.st_dev, before.st_ino))
        self.assertFalse(self.admit()["fresh"])

    def assert_entry_failure_releases(self, failure):
        fixture = LifecycleDecisions(); fixture.setUp()
        transaction = None
        try:
            transaction = fixture.open()
            self.assertEqual(transaction.history(), ({}, 0, 0))
            anchor = transaction.anchor
            info = anchor.stat()
            identity, raw, fd = (info.st_dev, info.st_ino), anchor.read_bytes(), transaction.fd
            path = {"inbox": fixture.inbox, "outbox": fixture.outbox,
                    "anchor": anchor, "missing-anchor": anchor}.get(failure)
            retained = fixture.root / "retained-entry-original"
            expected, message = ValueError, "lifecycle journal root replaced"
            if path is not None:
                path.rename(retained)
                if failure in ("inbox", "outbox"):
                    path.mkdir(mode=0o700)
                elif failure == "anchor":
                    path.write_bytes(b"successor"); path.chmod(0o600)
                    expected, message = ValueError, "lifecycle journal anchor replaced"
                else:
                    expected, message = FileNotFoundError, "No such file"
            else:
                expected, message = KeyboardInterrupt, "entry interrupted"
            try:
                interrupted = (patch.object(transaction, "fresh", side_effect=KeyboardInterrupt(message))
                               if failure == "interrupt" else nullcontext())
                with interrupted, self.assertRaisesRegex(expected, message):
                    with transaction:
                        self.fail("failed context entry executed its body")
            finally:
                if path is not None:
                    if path.exists():
                        if failure == "anchor": self.assertEqual(path.read_bytes(), b"successor")
                        else: self.assertEqual(list(path.iterdir()), [])
                        path.rename(fixture.root / "retained-entry-successor")
                    retained.rename(path)
            self.assertEqual((anchor.stat().st_dev, anchor.stat().st_ino), identity)
            self.assertEqual(anchor.read_bytes(), raw)
            # Observe descriptor retirement before any new open can reuse its
            # numeric fd, but require public same-anchor acquisition as well.
            retired = False
            try:
                os.fstat(fd)
            except OSError as error:
                self.assertEqual(error.errno, errno.EBADF)
                retired = True
            try:
                with fixture.open() as replacement:
                    self.assertEqual(replacement.anchor_identity, identity)
                    self.assertEqual(replacement.history(), ({}, 0, 0))
            except BlockingIOError:
                self.fail("failed context entry retained journal lock")
            self.assertTrue(retired, "failed context entry retained journal descriptor")
            self.assertEqual(fixture.receipts(), {})
        finally:
            if transaction is not None: transaction.close()
            fixture.doCleanups()

    def test_context_entry_failures_release_descriptor_and_same_surviving_anchor(self):
        for failure in ("inbox", "outbox", "anchor", "missing-anchor", "interrupt"):
            with self.subTest(failure=failure):
                self.assert_entry_failure_releases(failure)

    def test_context_entry_release_counterfactual(self):
        # Revert only entry-failure cleanup. The same regression must then fail
        # through public reacquisition, not an unrelated identity refusal.
        def unreleased_entry(transaction):
            transaction.fresh()
            return transaction
        with patch.object(journal.LifecycleJournal, "__enter__", unreleased_entry):
            with self.assertRaisesRegex(AssertionError, "failed context entry retained journal lock"):
                self.assert_entry_failure_releases("inbox")

    def test_planned_public_symlink_and_nested_places_refuse(self):
        planned = copy.deepcopy(self.fragment); planned["protocols"][0]["stages"][0]["planned"] = True
        with self.assertRaisesRegex(ValueError, "planned lifecycle"): self.open(planned)
        self.outbox.chmod(0o755)
        with self.assertRaisesRegex(ValueError, "directory mode"): self.open()
        self.outbox.chmod(0o700)
        nested = copy.deepcopy(self.fragment)
        nested["protocols"][0]["stages"][0]["outbox"]["path"] = str(self.inbox / "receipts")
        with self.assertRaisesRegex(ValueError, "disjoint"): self.open(nested)
        self.outbox.rename(self.state / "retained")
        self.outbox.symlink_to(self.state / "retained", target_is_directory=True)
        with self.assertRaisesRegex(ValueError, "noncanonical"): self.open()
        self.assertEqual(list((self.state / "retained").iterdir()), [self.state / "retained" / ".tmp"])

    def test_root_and_anchor_replacement_refuse_without_touching_successors(self):
        for root in ("inbox", "outbox", "anchor"):
            # Separate roots/receipts for each mutation, no stale oracle lifetime.
            with self.subTest(root=root), self.open() as transaction:
                path = self.inbox if root == "inbox" else self.outbox if root == "outbox" else transaction.anchor
                retained = path.with_name(path.name + "-retained")
                path.rename(retained)
                if root == "anchor": path.write_bytes(b"successor"); path.chmod(0o600)
                else: path.mkdir(mode=0o700)
                try:
                    with self.assertRaisesRegex(ValueError, "replaced"):
                        transaction.admit(self.filename)
                    if root == "anchor": self.assertEqual(path.read_bytes(), b"successor")
                    else: self.assertEqual(list(path.iterdir()), [])
                finally:
                    path.unlink() if root == "anchor" else path.rmdir()
                    retained.rename(path)

    def test_invalid_sequence_filename_or_binding_refuses_whole_journal(self):
        original = self.admit()["receipt"]
        original_path = self.outbox / journal.receipt_name(original)
        cases = [(dict(original, seq=2), "sequence"), (dict(original, state="done"), "sequence"),
                 (dict(original, ext={}), "input binding")]
        for changed, message in cases:
            original_path.write_bytes(packed(changed))
            with self.assertRaisesRegex(ValueError, message): self.admit()
            original_path.write_bytes(packed(original))
        wrong = original_path.with_name("wrong.json"); original_path.rename(wrong)
        with self.assertRaisesRegex(ValueError, "misnamed"): self.admit()
        wrong.rename(original_path)
        self.assertFalse(self.admit()["fresh"])

    def test_bounds_and_stale_staging_refuse_without_partial_decision(self):
        with patch.object(journal, "MAX_RECEIPTS", 0), self.assertRaisesRegex(ValueError, "publication bound"):
            self.admit()
        self.assertEqual(self.receipts(), {})
        self.admit(); old = self.receipts()
        with patch.object(journal, "MAX_RECEIPTS", 0), self.assertRaisesRegex(ValueError, "entry bound"):
            self.admit()
        with patch.object(journal, "MAX_JOURNAL_BYTES", 1), self.assertRaisesRegex(ValueError, "byte bound"):
            self.admit()
        self.assertEqual(self.receipts(), old)
        self.input(dict(self.request, record="next"), "next.1.json")
        stale = self.outbox / ".tmp" / "killed-writer"
        stale.write_bytes(b"partial decision"); stale.chmod(0o600)
        with self.assertRaisesRegex(ValueError, "incomplete lifecycle staging"):
            self.admit("next.1.json")
        self.assertEqual(stale.read_bytes(), b"partial decision")
        self.assertEqual(self.receipts(), old)

    def test_failed_receipt_publication_cannot_return_success_and_preserves_history(self):
        for operation in ("write_new", "rename_new"):
            with self.subTest(operation=operation):
                with patch.object(journal, operation, side_effect=OSError("injected receipt failure")):
                    with self.assertRaises(OSError): self.admit()
                self.assertEqual(self.receipts(), {})
                self.assertEqual(list((self.outbox / ".tmp").iterdir()), [])
        # A committed decision with failed directory fsync is uncertain, NOT a
        # fresh retry. The next invocation discovers the exact original receipt.
        real = os.fsync
        def failed_directory(fd):
            import stat
            if stat.S_ISDIR(os.fstat(fd).st_mode): raise OSError("directory fsync refused")
            return real(fd)
        with patch.object(os, "fsync", failed_directory), self.assertRaises(OSError): self.admit()
        self.assertEqual(len(self.receipts()), 1)
        self.assertFalse(self.admit()["fresh"])

    def healthy_control(self):
        fixture = LifecycleDecisions(); fixture.setUp()
        try:
            result = fixture.admit()
            self.assertTrue(result["fresh"])
            self.assertEqual(result["receipt"]["state"], "accepted")
        finally:
            fixture.doCleanups()

    def test_independent_journal_guard_counterfactuals(self):
        # Each case owns an independent intact baseline and one changed input.
        # Only its named require is bypassed; neither implementation bytes nor
        # another refusal is changed. All execution stays on isolated CI roots.
        cases = ("planned", "binding", "changed", "sequence", "filename", "entry", "bytes", "publication", "staging")
        for case in cases:
            with self.subTest(case=case):
                self.healthy_control()
                fixture = LifecycleDecisions()
                fixture.setUp()
                try:
                    with fixture.open(): pass
                    expected = None
                    call = fixture.admit
                    if case == "planned":
                        fixture.fragment["protocols"][0]["stages"][0]["planned"] = True
                        expected = "planned lifecycle stage cannot write decisions"
                    elif case == "binding":
                        fixture.input(dict(fixture.request, record="foreign"))
                        expected = "lifecycle input filename binding mismatch"
                    elif case == "changed":
                        fixture.admit()
                        fixture.input(dict(fixture.request, epoch="other"))
                        expected = "lifecycle input changed after decision; effect refused"
                    elif case in ("sequence", "filename", "entry", "bytes"):
                        value = fixture.admit()["receipt"]
                        target = fixture.outbox / journal.receipt_name(value)
                        if case == "sequence":
                            target.write_bytes(packed(dict(value, seq=2)))
                            expected = "invalid lifecycle decision sequence"
                        if case == "filename":
                            target.rename(target.with_name("wrong.json"))
                            expected = "foreign or misnamed lifecycle receipt"
                        if case == "entry": expected = "lifecycle journal entry bound exceeded"
                        if case == "bytes": expected = "lifecycle journal byte bound exceeded"
                    elif case == "publication": expected = "lifecycle journal publication bound exceeded"
                    elif case == "staging":
                        (fixture.outbox / ".tmp" / "partial").write_bytes(b"unfinished")
                        expected = "incomplete lifecycle staging; owner reconciliation required"
                    from contextlib import ExitStack
                    with ExitStack() as stack:
                        if case in ("entry", "publication"):
                            stack.enter_context(patch.object(journal, "MAX_RECEIPTS", 0))
                        if case == "bytes": stack.enter_context(patch.object(journal, "MAX_JOURNAL_BYTES", 1))
                        if case == "binding":
                            self.assertEqual(call()["receipt"]["code"], "input-invalid")
                            # Its refusal is immutable: use a new independent
                            # name for the counterfactual, with the same defect.
                            fixture.filename = "other.1.json"
                            fixture.input(dict(fixture.request, record="foreign"))
                        else:
                            with self.assertRaisesRegex(ValueError, expected): call()
                        original = journal.require
                        hits = []
                        def reverted(value, message):
                            if not value and message == expected:
                                hits.append(message)
                                return
                            return original(value, message)
                        with patch.object(journal, "require", reverted): result = call()
                        self.assertTrue(hits, case)
                        self.assertIn(result["receipt"]["state"], ("accepted", "refused"))
                        if case == "binding": self.assertEqual(result["receipt"]["record"], "foreign")
                finally:
                    fixture.doCleanups()

    def test_root_anchor_attempt_and_published_byte_guard_counterfactuals(self):
        for case in ("root", "anchor", "attempt", "published"):
            with self.subTest(case=case):
                self.healthy_control()
                fixture = LifecycleDecisions(); fixture.setUp()
                try:
                    with fixture.open() as transaction:
                        if case == "root":
                            old = fixture.inbox.with_name("retained-input")
                            fixture.inbox.rename(old); fixture.inbox.mkdir(mode=0o700)
                            fixture.input(fixture.request)
                            message = "lifecycle journal root replaced"
                        elif case == "anchor":
                            before = transaction.anchor.stat()
                            retained = fixture.root / "retained-anchor"
                            transaction.anchor.rename(retained)
                            transaction.anchor.write_bytes(b""); transaction.anchor.chmod(0o600)
                            self.assertEqual((retained.stat().st_dev, retained.stat().st_ino),
                                             (before.st_dev, before.st_ino))
                            self.assertEqual(retained.read_bytes(), b"")
                            self.assertNotEqual((transaction.anchor.stat().st_dev, transaction.anchor.stat().st_ino),
                                                (before.st_dev, before.st_ino))
                            message = "lifecycle journal anchor replaced"
                        elif case == "attempt":
                            fixture.fragment["protocols"][0]["stages"][0]["retry_limit"] = 1
                            # The open transaction intentionally uses the same
                            # valid policy, so only next-attempt admission fires.
                            transaction.stage["retry_limit"] = 1
                            fixture.filename = "start-a.2.json"
                            fixture.input(dict(fixture.request, attempt=2))
                            message = "lifecycle attempt is not the next refused attempt"
                        else:
                            message = "published lifecycle receipt changed; effect refused"
                        original = journal.require
                        hits = []
                        def reverted(value, why):
                            if not value and why == message: hits.append(why); return
                            return original(value, why)
                        if case != "published":
                            with self.assertRaisesRegex(ValueError, message): transaction.admit(fixture.filename)
                            with patch.object(journal, "require", reverted): transaction.admit(fixture.filename)
                        else:
                            rename = journal.rename_new
                            def corrupt(source, target):
                                rename(source, target)
                                target.write_bytes(b"corrupted receipt\n")
                            with patch.object(journal, "rename_new", corrupt):
                                with self.assertRaisesRegex(ValueError, message): transaction.admit(fixture.filename)
                            # Preserve the first corruption as evidence, then
                            # use another independent record for the same seam.
                            target = next(p for p in fixture.outbox.iterdir() if not p.name.startswith("."))
                            target.rename(fixture.root / "retained-corruption")
                            with patch.object(journal, "rename_new", corrupt), patch.object(journal, "require", reverted):
                                transaction.admit(fixture.filename)
                        self.assertTrue(hits, case)
                finally:
                    fixture.doCleanups()

    def test_staging_replacement_guard_preserves_foreign_bytes(self):
        self.healthy_control()
        for reverted in (False, True):
            fixture = LifecycleDecisions(); fixture.setUp()
            try:
                observed = []
                def replaced(source, _target):
                    source.rename(fixture.root / "retained-original-stage")
                    source.write_bytes(b"foreign staging bytes"); source.chmod(0o600)
                    observed.append(source)
                    raise OSError("publication interrupted")
                real = journal.require
                def bypass(value, why):
                    if reverted and why == "journal staging replacement; cleanup refused": return
                    return real(value, why)
                with patch.object(journal, "rename_new", replaced), patch.object(journal, "require", bypass):
                    if reverted:
                        with self.assertRaisesRegex(OSError, "publication interrupted"): fixture.admit()
                    else:
                        with self.assertRaisesRegex(ValueError, "staging replacement; cleanup refused"): fixture.admit()
                self.assertEqual(observed[0].exists(), not reverted)
                if not reverted: self.assertEqual(observed[0].read_bytes(), b"foreign staging bytes")
                self.assertEqual(fixture.receipts(), {})
            finally:
                fixture.doCleanups()

    def test_journal_has_no_process_listener_or_authoritative_record_effect(self):
        def forbidden(*_args, **_kwargs): raise AssertionError("journal attempted a process/socket effect")
        tracked = self.state / "task.status"; tracked.write_bytes(b"note: untouched\n")
        records = {name: self.state / name for name in (".wake-queue", ".last-watcher-beat", ".lease-task")}
        for name, path in records.items(): path.write_bytes(name.encode())
        before = {p: p.read_bytes() for p in (tracked, *records.values())}
        with patch.object(subprocess, "Popen", forbidden), patch.object(os, "kill", forbidden), \
                patch.object(socket.socket, "bind", forbidden), patch.object(signal, "pidfd_send_signal", forbidden):
            self.admit()
            with self.open() as transaction: transaction.complete(self.filename)
        self.assertEqual(before, {p: p.read_bytes() for p in before})
        self.assertFalse((self.runtime / "read.sock").exists())
        self.assertFalse((self.runtime / "owner.json").exists())
