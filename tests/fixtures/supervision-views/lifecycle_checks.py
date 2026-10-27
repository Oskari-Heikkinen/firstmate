"""CI-only public contract readers, not service lifecycle/effect acceptance."""
import copy
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[3]
TOOL = ROOT / "bin/fm-view-lifecycle.py"
VALIDATOR = ROOT / "bin/fm-handoff-validate.py"


class LifecycleContracts(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.home = self.root / "home"
        self.state = self.home / "state"
        self.state.mkdir(parents=True, mode=0o700)
        self.runtime = self.state / "read-service"
        self.runtime.mkdir(mode=0o700)
        self.inbox = self.state / "read-requests"
        self.outbox = self.state / "read-receipts"
        for folder in (self.inbox, self.outbox):
            folder.mkdir(mode=0o700)
        self.environment = dict(os.environ, PYTHONDONTWRITEBYTECODE="1")
        self.policy = self.file("policy.json", {
            "bounds": {"accepted": "1m", "waiting": "1m", "held": "1m"}, "retry_limit": 0,
            "cleanup": {"stage": "lifecycle", "receipts_after": "7d", "records_after": "7d"},
        })
        self.fragment = self.call("candidate", "--home", self.home, "--owner", "main",
                                  "--inbox", self.inbox, "--outbox", self.outbox, "--policy", self.policy)
        self.fragment_path = self.file("fragment.json", self.fragment)
        identities = {name: [folder.stat().st_dev, folder.stat().st_ino] for name, folder in
                      (("home", self.home), ("state", self.state), ("runtime", self.runtime))}
        self.request = {
            "schema": "fm-view-lifecycle.v1", "version": 1, "record": "start-a", "attempt": 1,
            "home": str(self.home), "owner": "main", "operation": "start", "epoch": "epoch-a",
            "roots": identities, "runtime": str(self.runtime), "bundle": {
                "path": str(self.root / "versions" / ("a" * 64)), "identity": "a" * 64},
            "workers": 4, "timeout_ms": 1000, "expected_owner": None, "capabilities": "b" * 64,
        }
        self.owner = {
            "schema": "fm-view-owner.v1", **{name: copy.deepcopy(self.request[name]) for name in
                ("home", "roots", "runtime", "bundle", "epoch", "capabilities")},
            "process": {"pid": 12345, "uid": os.getuid(), "start_ticks": 100,
                        "boot": "00000000-0000-0000-0000-000000000000"},
            "socket": {"path": str(self.runtime / "read.sock"), "identity": [1, 2]}, "request": "c" * 64,
        }

    def file(self, name, value):
        target = self.root / name
        raw = value if isinstance(value, bytes) else json.dumps(value).encode() + b"\n"
        target.write_bytes(raw)
        target.chmod(0o600)
        return target

    def command(self, *args, ok=True, prefix=None):
        argv = prefix or [sys.executable, str(TOOL)]
        result = subprocess.run([*argv, *map(str, args)], env=self.environment, capture_output=True, timeout=10)
        if ok:
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stderr, b"")
            return json.loads(result.stdout)
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertEqual(result.stdout, b"")
        self.assertIn(b"fm-view-lifecycle: refused:", result.stderr)
        return result.stderr.decode()

    call = command

    def inspect_request(self, value, **kwargs):
        return self.call("request", "--home", self.home, "--fragment", self.fragment_path,
                         "--input", self.file("request.json", value), **kwargs)

    def inspect_owner(self, value, **kwargs):
        return self.call("owner", "--input", self.file("owner.json", value), **kwargs)

    def public_validate(self, kind, filename, fragment=False):
        args = [sys.executable, str(VALIDATOR), kind]
        if fragment:
            args += ["--fragment", str(self.fragment_path)]
        result = subprocess.run([*args, str(filename)], env=self.environment, capture_output=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)

    def test_planned_candidate_and_every_receipt_use_public_handoff_validator(self):
        self.public_validate("fragment", self.fragment_path)
        protocol = self.fragment["protocols"][0]
        self.assertTrue(protocol["stages"][0]["planned"])
        self.assertEqual(protocol["stages"][0]["bounds"], json.loads(self.policy.read_bytes())["bounds"])
        self.assertEqual(list(self.outbox.iterdir()), [])
        request = self.file("request.json", self.request)
        for seq, state, code in ((1, "accepted", None), (2, "done", None),
                                 (3, "refused", "input-invalid"), (4, "refused", "identity-changed"),
                                 (5, "refused", "effect-failed")):
            args = ["receipt", "--home", self.home, "--fragment", self.fragment_path, "--input", request,
                    "--state", state, "--seq", seq]
            if code:
                args += ["--code", code]
            output = self.call(*args)
            self.assertEqual((output["seq"], output["state"]), (seq, state))
            self.public_validate("receipt", self.file("receipt.json", output), fragment=True)
        self.assertEqual(list(self.outbox.iterdir()), [])

    def test_valid_start_stop_and_owner_are_explicitly_not_authority(self):
        output = self.inspect_request(self.request)
        self.assertEqual(output, {"structurally_valid": True, "authority": False, "request": self.request})
        self.assertEqual(self.inspect_owner(self.owner), {"structurally_valid": True, "authority": False, "owner": self.owner})
        stop = dict(self.request, operation="stop", expected_owner=self.owner, record="stop-a")
        self.assertEqual(self.inspect_request(stop)["request"], stop)
        # Missing bundle/socket/PID is intentional: this proves the CLI makes
        # no live-readiness assertion from a structurally valid record.
        self.assertFalse(Path(self.owner["bundle"]["path"]).exists())
        self.assertFalse(Path(self.owner["socket"]["path"]).exists())

    def test_unknown_version_refuses_without_interpreting_payload_and_receipts_it(self):
        unknown = {name: self.request[name] for name in ("schema", "record", "attempt", "home", "owner")}
        unknown.update(version=2, foreign_payload={"not": "version-one"})
        self.assertIn("version-unsupported", self.inspect_request(unknown, ok=False))
        output = self.call("receipt", "--home", self.home, "--fragment", self.fragment_path,
                           "--input", self.file("unknown.json", unknown), "--state", "refused", "--seq", 1,
                           "--code", "version-unsupported")
        self.assertEqual((output["version"], output["code"]), (2, "version-unsupported"))
        self.public_validate("receipt", self.file("receipt.json", output), fragment=True)
        self.assertIn("not an unsupported-version refusal", self.call("receipt", "--home", self.home,
            "--fragment", self.fragment_path, "--input", self.file("known.json", self.request),
            "--state", "refused", "--seq", 1, "--code", "version-unsupported", ok=False))

    def test_request_field_guard_batch_has_independent_healthy_baseline(self):
        self.inspect_request(self.request)
        for field, value, message in (
            ("home", str(self.root), "home binding"), ("owner", "other", "home binding"),
            ("attempt", 2, "retry limit"), ("attempt", True, "retry limit"),
            ("version", True, "request version"), ("operation", "restart", "unsupported lifecycle operation"),
            ("record", "bad/id", "record identity"), ("epoch", "", "request epoch"),
            ("roots", {"home": [1, 2]}, "request roots fields"),
            ("runtime", str(self.root), "runtime outside"),
            ("bundle", {"path": "/versions/" + "a" * 64, "identity": "b" * 64}, "bundle identity"),
            ("workers", 0, "worker bound"), ("workers", True, "worker bound"),
            ("timeout_ms", 30001, "deadline"), ("timeout_ms", True, "deadline"),
            ("expected_owner", self.owner, "start must not replace"),
            ("capabilities", "", "capabilities digest"),
        ):
            with self.subTest(field=field, value=value):
                changed = copy.deepcopy(self.request)
                changed[field] = value
                self.assertIn(message, self.inspect_request(changed, ok=False))
        for changed in ({}, dict(self.request, extra=1)):
            self.inspect_request(changed, ok=False)

    def test_stop_binding_and_owner_shape_guard_batch(self):
        stop = dict(self.request, operation="stop", expected_owner=self.owner)
        self.inspect_request(stop)
        for field in ("home", "epoch", "roots", "runtime", "bundle", "capabilities"):
            with self.subTest(field=field):
                changed = copy.deepcopy(stop)
                if field == "home": changed["expected_owner"][field] += "-other"
                elif field == "epoch": changed["expected_owner"][field] += "-other"
                elif field == "roots": changed["expected_owner"][field]["home"][1] += 1
                elif field == "runtime":
                    changed["expected_owner"][field] += "-other"
                    changed["expected_owner"]["socket"]["path"] = changed["expected_owner"][field] + "/read.sock"
                elif field == "bundle": changed["expected_owner"][field]["path"] = "/other/" + "a" * 64
                else: changed["expected_owner"][field] = "d" * 64
                # Keep the wrong home's runtime internally valid, so the stop
                # binding itself, not a sibling shape guard, must reject it.
                if field == "home":
                    changed["expected_owner"]["runtime"] = changed["expected_owner"][field] + "/state/read-service"
                    changed["expected_owner"]["socket"]["path"] = changed["expected_owner"]["runtime"] + "/read.sock"
                self.assertIn("stop owner binding mismatch: " + field, self.inspect_request(changed, ok=False))
        for field, value, message in (
            ("schema", "fm-view-owner.v2", "owner version"),
            ("roots", {"home": [True, 2], "state": [1, 2], "runtime": [1, 2]}, "owner home identity"),
            ("runtime", str(self.state / ".." / "foreign"), "runtime"),
            ("epoch", "bad/epoch", "owner epoch"),
            ("bundle", {"path": "/bad\n/" + "a" * 64, "identity": "a" * 64}, "bundle path"),
            ("process", {"pid": True, "uid": os.getuid(), "start_ticks": 1, "boot": self.owner["process"]["boot"]}, "process generation"),
            ("socket", {"path": "/other/read.sock", "identity": [1, 2]}, "socket outside runtime"),
            ("request", "x", "request digest"),
        ):
            changed = copy.deepcopy(self.owner); changed[field] = value
            self.assertIn(message, self.inspect_owner(changed, ok=False))

    def test_invalid_fragment_and_policy_are_not_repaired_or_assumed(self):
        self.public_validate("fragment", self.fragment_path)
        for mutate, message in (
            (lambda f: f.update(example=True), "example fragment"),
            (lambda f: f["protocols"][0]["stages"][0].update(actors=["process:other"]), "unsupported lifecycle stage"),
            (lambda f: f["protocols"][0]["stages"][0]["outbox"].update(path=str(self.inbox)), "invalid lifecycle fragment"),
            (lambda f: f["protocols"][0]["stages"][0]["input"].update(path="/other/input"), "outside selected state"),
        ):
            changed = copy.deepcopy(self.fragment); mutate(changed)
            self.file("fragment.json", changed)
            self.assertIn(message, self.inspect_request(self.request, ok=False))
        self.file("fragment.json", self.fragment)
        for raw in ({}, {"bounds": {"accepted": "0s"}, "retry_limit": 0, "cleanup": {}}):
            self.call("candidate", "--home", self.home, "--owner", "main", "--inbox", self.inbox,
                      "--outbox", self.outbox, "--policy", self.file("bad-policy.json", raw), ok=False)

    def test_independent_request_guards_have_single_guard_counterfactuals(self):
        driver = self.file("counterfactual.py", b'''import os, runpy, sys
sys.dont_write_bytecode = True
tool, message = sys.argv[1:3]
sys.argv = [tool, *sys.argv[3:]]
sys.path.insert(0, os.path.dirname(tool))
import fm_view_lifecycle as owner
original = owner.require
def reverted(value, why):
    if not value and why == message:
        print("counterfactual: " + why, file=sys.stderr)
        return
    return original(value, why)
owner.require = reverted
runpy.run_path(tool, run_name="__main__")
''')
        cases = [
            ("home", str(self.root), "lifecycle home binding mismatch"),
            ("attempt", 2, "lifecycle retry limit exceeded"),
            ("version", True, "invalid lifecycle request version"),
            ("operation", "restart", "unsupported lifecycle operation"),
            ("record", "bad/id", "invalid record identity"),
            ("epoch", "", "invalid request epoch"),
            ("roots", {"home": [1, 2]}, "invalid request roots fields"),
            ("roots", {"home": [True, 2], "state": [1, 2], "runtime": [1, 2]}, "invalid request home identity"),
            ("runtime", str(self.root), "runtime outside selected state root"),
            ("bundle", {"path": "/versions/" + "a" * 64, "identity": "b" * 64}, "invalid bundle identity"),
            ("workers", 0, "invalid worker bound"),
            ("timeout_ms", 30001, "invalid lifecycle deadline"),
            ("expected_owner", self.owner, "start must not replace an owner"),
            ("capabilities", "", "invalid capabilities digest"),
        ]
        for field, value, message in cases:
            with self.subTest(field=field, message=message):
                baseline = copy.deepcopy(self.request)
                if field == "operation":
                    # Bypassing only the operation refusal reaches the stop
                    # branch. Keep every owner-shape/binding guard satisfied.
                    baseline.update(operation="stop", expected_owner=copy.deepcopy(self.owner))
                self.assertEqual(self.inspect_request(baseline)["request"], baseline)
                changed = copy.deepcopy(baseline); changed[field] = value
                self.assertIn(message, self.inspect_request(changed, ok=False))
                selected = self.file("request.json", changed)
                result = subprocess.run([sys.executable, str(driver), str(TOOL), message, "request",
                    "--home", str(self.home), "--fragment", str(self.fragment_path), "--input", str(selected)],
                    env=self.environment, capture_output=True, timeout=10)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stderr.decode(), "counterfactual: " + message + "\n")
                self.assertEqual(json.loads(result.stdout), {
                    "structurally_valid": True, "authority": False, "request": changed})

    def test_invalid_decisions_never_emit_candidate_receipts(self):
        request = self.file("request.json", self.request)
        args = ["receipt", "--home", self.home, "--fragment", self.fragment_path, "--input", request]
        for state, seq, code in (("waiting", 1, None), ("done", 0, None), ("refused", 1, None),
                                 ("done", 1, "input-invalid"), ("refused", 1, "undeclared-code")):
            selected = [*args, "--state", state, "--seq", seq]
            if code is not None: selected += ["--code", code]
            self.call(*selected, ok=False)
        self.assertEqual(list(self.outbox.iterdir()), [])

    def test_adversarial_file_shapes_refuse_boundedly_with_empty_stdout(self):
        self.inspect_owner(self.owner)
        valid = json.dumps(self.owner).encode() + b"\n"
        for name, raw in (("empty", b""), ("space", b" \n"), ("partial", valid[:-1]),
                          ("nul", valid + b"\0\n"), ("huge", b" " * 65537 + b"\n"),
                          ("duplicate", valid.replace(b'"schema":', b'"schema": "other", "schema":', 1)),
                          ("nonfinite", b'{"schema": NaN}\n')):
            with self.subTest(name=name):
                self.call("owner", "--input", self.file(name, raw), ok=False)
        target = self.file("target.json", valid)
        unreadable = self.file("unreadable", valid); unreadable.chmod(0)
        fifo = self.root / "fifo"; os.mkfifo(fifo)
        symlink = self.root / "link"; symlink.symlink_to(target)
        dangling = self.root / "dangling"; dangling.symlink_to(self.root / "absent")
        hardlink = self.root / "hard"; os.link(target, hardlink)
        for item in (self.root / "missing", self.runtime, fifo, symlink, dangling, hardlink, unreadable):
            with self.subTest(path=item): self.call("owner", "--input", item, ok=False)
        self.assertEqual(target.read_bytes(), valid)

    def test_reader_commands_have_no_process_socket_or_record_effect(self):
        wrapper = self.file("tripwire.py", b'''import os, runpy, signal, socket, subprocess, sys
sys.dont_write_bytecode = True
def forbidden(*args, **kwargs): raise AssertionError("lifecycle inspector attempted an effect")
for module, names in ((os, ("kill", "killpg", "pidfd_open", "fork", "execve", "rename", "replace", "unlink", "mkdir")),
                      (signal, ("pidfd_send_signal",)), (subprocess, ("Popen",)),
                      (socket.socket, ("bind", "connect"))):
    for name in names:
        if hasattr(module, name): setattr(module, name, forbidden)
tool = sys.argv.pop(1)
sys.path.insert(0, os.path.dirname(tool))
runpy.run_path(tool, run_name="__main__")
''')
        request = self.file("request.json", self.request)
        owner = self.file("owner.json", self.owner)
        def snapshot():
            return {str(p.relative_to(self.home)): (p.stat().st_mode, p.read_bytes() if p.is_file() else None)
                    for p in self.home.rglob("*")}
        before = snapshot()
        prefix = [sys.executable, str(wrapper), str(TOOL)]
        self.call("request", "--home", self.home, "--fragment", self.fragment_path, "--input", request, prefix=prefix)
        self.call("owner", "--input", owner, prefix=prefix)
        self.call("receipt", "--home", self.home, "--fragment", self.fragment_path, "--input", request,
                  "--state", "accepted", "--seq", 1, prefix=prefix)
        self.call("candidate", "--home", self.home, "--owner", "main", "--inbox", self.inbox,
                  "--outbox", self.outbox, "--policy", self.policy, prefix=prefix)
        self.assertEqual(snapshot(), before)


if __name__ == "__main__":
    unittest.main()
