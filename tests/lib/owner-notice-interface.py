"""CLI-only U3 fixtures; owner records use the format encoders, not the engine."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import unittest
import uuid

ROOT, TMP, CASE = Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3]
sys.dont_write_bytecode = True
sys.path.insert(0, str(ROOT / "bin"))
import fm_owner_notice_format as fmt

CLIENT = ROOT / "bin/fm-owner-notice-client.py"
FORMAT = ROOT / "bin/fm_owner_notice_format.py"
WARNING = "Any other exit code (including 124 and 137) is unknown, never success."
PROBES = ("state", "owner-notices", "bindings", "receipts")
NOW = 2000000000


class Interface(unittest.TestCase):
    def setUp(self):
        self.root = TMP / uuid.uuid4().hex
        self.home = self.root / "owner"
        self.outbox = self.root / "outbox"
        self.notices = self.home / "state/owner-notices"
        self.bindings = self.notices / "bindings"
        self.leaf = self.notices / "fixture"
        for path in (self.bindings, self.leaf / "receipts", self.leaf / ".tmp", self.outbox):
            path.mkdir(parents=True, exist_ok=True)
        (self.root / fmt.TEST_ROOT_MARKER).touch()
        self.env = {k: v for k, v in os.environ.items() if not k.startswith("FM_")}
        self.env.update(HOME=str(self.root), FM_HOME=str(self.home), PYTHONDONTWRITEBYTECODE="1",
                        XDG_CONFIG_HOME=str(self.root / "config"), XDG_STATE_HOME=str(self.root / "state"),
                        FM_OWNER_NOTICE_TEST_ROOT=str(self.root), FM_OWNER_NOTICE_NOW=str(NOW))
        self.probes()
        st = self.outbox.stat()
        self.binding = dict(schema=fmt.BINDING_SCHEMA, binding_id="fixture", recipient_home="main",
                            owner_home_path=str(self.home), machine_id="fixture", producer_actor="process:fixture",
                            producer_uid=os.getuid(), outbox=str(self.outbox), outbox_dev=st.st_dev,
                            outbox_ino=st.st_ino, kinds=["notice"], max_bytes=65536, consume_bound_seconds=60,
                            envelope_versions=[1], receipt_versions=[1], created_at=fmt.utc_iso(NOW))
        raw = fmt.canonical(fmt.validate_binding(self.binding))
        (self.bindings / "fixture.json").write_bytes(raw)
        self.config = {k: self.binding[k] for k in ("binding_id", "recipient_home", "owner_home_path",
                                                   "machine_id", "producer_actor", "outbox")}
        self.config.update(schema=fmt.CONFIG_SCHEMA, binding_sha256=hashlib.sha256(raw).hexdigest(),
                           closure={str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in (CLIENT, FORMAT)})
        self.cp = self.root / "config.json"
        self.cp.write_bytes(fmt.canonical(self.config))
        self.payload = self.root / "payload"
        self.payload.write_bytes(b"fixture notice\x00\xff")
        self.beat()

    def probes(self, omit=None, code=None):
        self.env["FM_OWNER_NOTICE_FAULT"] = ",".join(
            "probe-errno:%s:%s" % (name, code if name == omit else "EROFS")
            for name in PROBES if name != omit or code is not None)

    def beat(self, **changes):
        obj = dict(writer="runner", epoch=str(NOW), runner_pid=str(os.getpid()),
                   runner_starttime=fmt.pid_starttime(os.getpid()), watcher_pid=str(os.getpid()),
                   watcher_identity="fixture", outbox_mtime_ns="0", dirty_since="-")
        obj.update({k: str(v) for k, v in changes.items()})
        (self.leaf / ".beat").write_text(" ".join(k + "=" + v for k, v in obj.items()) + "\n")

    def run_client(self, *args, env=None, trace=False):
        return subprocess.run([sys.executable, "-I"] + (["-X", "importtime"] if trace else []) +
                              [str(CLIENT)] + list(args), env=self.env if env is None else env,
                              capture_output=True, text=True, timeout=30)

    def answer(self, rc=0, code=None, *args):
        got = self.run_client(*(args or ("probe", "--config", str(self.cp))))
        self.assertEqual(got.returncode, rc, got.stdout + got.stderr)
        obj = json.loads(got.stdout)
        if code:
            self.assertEqual(obj.get("code"), code, obj)
        return obj

    def test_u3_01(self):
        """R-U3-01: exactly one genuinely writable directory per fixture."""
        paths = (self.home / "state", self.notices, self.bindings, self.leaf / "receipts")
        for name, path in zip(PROBES, paths):
            with self.subTest(directory=name):
                self.probes(omit=name)
                got = self.answer(69, "owner-tree-writable")
                self.assertEqual(got["path"], str(path))
                self.assertEqual(list(path.glob(".fm-owner-notice-probe-*")), [])
        self.probes()
        self.assertEqual(self.answer()["state"], "present")

    def test_u3_02(self):
        """R-U3-02: mode-only denial is not a read-only mount."""
        for code in ("EACCES", "EPERM"):
            for name in PROBES:
                with self.subTest(errno=code, directory=name):
                    self.probes(omit=name, code=code)
                    self.answer(69, "owner-tree-writable-by-mode")
        self.probes(omit="state", code="EIO")
        self.answer(70)

    def test_u3_03(self):
        """R-U3-03: kernel EROFS and ST_RDONLY, when user namespaces are available."""
        if not shutil.which("unshare") or not shutil.which("mount"):
            self.skipTest("SKIP: unshare/mount unavailable")
        # Capability preflight never invokes the client. Implementation failures
        # after this point are failures, not capability skips.
        mount = 'mount --bind "$1" "$1" && mount -o remount,bind,ro "$1"'
        prefix = ["unshare", "--user", "--map-root-user", "--mount", "bash", "-c"]
        control = subprocess.run(prefix + [mount, "fixture", str(self.home)],
                                 capture_output=True, text=True, timeout=10, env=self.env)
        if control.returncode:
            self.skipTest("SKIP: read-only user namespace refused: " + control.stderr.strip())
        env = dict(self.env)
        env.pop("FM_OWNER_NOTICE_FAULT")
        cmd = mount + ' && exec "$2" -I "$3" probe --config "$4"'
        got = subprocess.run(prefix + [cmd, "fixture", str(self.home), sys.executable, str(CLIENT), str(self.cp)],
                             capture_output=True, text=True, timeout=30, env=env)
        self.assertEqual(got.returncode, 0, got.stdout + got.stderr)
        probes = json.loads(got.stdout)["probes"]
        self.assertEqual(len(probes), 4)
        self.assertTrue(all(p["errno"] == "EROFS" and p["st_rdonly"] is True for p in probes))

    def closure(self, *args):
        # -I removes PYTHONPATH and user-site injection. Subtract interpreter
        # startup imports, then judge every loaded root against stdlib, not a
        # handpicked list of expected extra-module names.
        baseline = subprocess.run([sys.executable, "-I", "-X", "importtime", "-c", "pass"],
                                  capture_output=True, text=True, timeout=10, env=self.env)
        got = self.run_client(*args, trace=True)
        self.assertIn(got.returncode, (0, 75), got.stdout + got.stderr)
        def modules(text):
            return {line.rsplit("|", 1)[-1].strip().split(".")[0] for line in text.splitlines()
                    if line.startswith("import time:") and "|" in line and "package" not in line}
        loaded = modules(got.stderr) - modules(baseline.stderr)
        nonstdlib = loaded - sys.stdlib_module_names
        self.assertEqual(nonstdlib, {"fm_owner_notice_format"}, got.stderr)
        # The executed client is __main__, so importtime does not list it.
        return got

    def test_u3_04(self):
        """R-U3-04: producer path loads only client + format, beyond stdlib."""
        self.closure("submit", "--config", str(self.cp), "--key", "closure", "--kind", "notice",
                     "--payload-file", str(self.payload))

    def test_u3_05(self):
        """R-U3-05: hermetic self-test has the same exact closure."""
        env = dict(self.env)
        for key in tuple(env):
            if key.startswith("FM_OWNER_NOTICE_"):
                env.pop(key)
        before = {str(p.relative_to(self.root)): p.read_bytes() for p in self.root.rglob("*") if p.is_file()}
        got = self.run_client("--self-test", "v1", env=env)
        self.assertEqual(got.returncode, 0, got.stdout + got.stderr)
        self.assertIn("PASS fm-owner-notice-interface/v1", got.stdout)
        after = {str(p.relative_to(self.root)): p.read_bytes() for p in self.root.rglob("*") if p.is_file()}
        self.assertEqual(before, after)
        self.closure("--self-test", "v1")

    def test_u3_06(self):
        """R-U3-06: manual ingest cannot create presence; writer must be runner."""
        owner = self.root / "manual"
        owner.mkdir()
        env = dict(self.env, FM_HOME=str(owner))
        front = str(ROOT / "bin/fm-owner-notice.sh")
        args = ["bind", "manual", "--outbox", str(self.outbox), "--producer-actor", "process:fixture",
                "--producer-uid", str(os.getuid()), "--kinds", "notice", "--max-bytes", "65536",
                "--consume-bound-seconds", "60"]
        for command in (args, ["ingest", "manual"]):
            got = subprocess.run(["bash", front] + command, capture_output=True, text=True, timeout=60, env=env)
            self.assertEqual(got.returncode, 0, got.stdout + got.stderr)
        raw = (owner / "state/owner-notices/bindings/manual.json").read_bytes()
        b = json.loads(raw)
        config = dict(self.config, **{k: b[k] for k in ("binding_id", "recipient_home", "owner_home_path",
                                                       "machine_id", "producer_actor", "outbox")})
        config["binding_sha256"] = hashlib.sha256(raw).hexdigest()
        cp = self.root / "manual-config.json"
        cp.write_bytes(fmt.canonical(config))
        self.answer(69, "owner-automation-absent", "probe", "--config", str(cp))
        self.beat(writer="manual")
        self.answer(69, "owner-automation-absent")
        self.beat()
        self.assertEqual(self.answer()["state"], "present")

    def test_u3_07(self):
        """R-U3-07: clock controlled exact 45s boundary, stale and future refuse."""
        self.beat(epoch=NOW - 46)
        self.answer(69, "owner-automation-absent")
        self.beat(epoch=NOW - 45)
        self.assertEqual(self.answer()["state"], "present")
        self.beat(epoch=NOW + 1)
        self.answer(69, "owner-automation-absent")

    def test_u3_08(self):
        """R-U3-08: live beat on either retiring/retired binding is still absent."""
        for suffix in ("retiring", "retired"):
            marker = self.bindings / ("fixture." + suffix)
            marker.write_text("retired\n")
            self.answer(69, "owner-automation-absent")
            marker.unlink()
        self.assertEqual(self.answer()["state"], "present")

    def test_u3_09(self):
        """R-U3-09 amended by instruction 002: warning in help and owning doc."""
        for args in (("--interface",), ("--interface", "v1")):
            got = self.run_client(*args)
            self.assertEqual((got.returncode, got.stdout, got.stderr), (0, "fm-owner-notice-interface/v1\n", ""))
        self.assertEqual(self.run_client("--interface", "v2").returncode, 1)
        self.assertEqual(self.run_client("--self-test", "v2").returncode, 1)
        help_result = self.run_client("--help")
        self.assertEqual(help_result.returncode, 0)
        self.assertIn(WARNING, help_result.stdout)
        doc = (ROOT / "docs/owner-notice.md").read_text().split("## Exit codes\n", 1)[1].split("\n## ", 1)[0]
        self.assertIn(WARNING, doc)
        # Caller fixture must keep the exit status, not trust a success-shaped
        # stdout line from an interrupted/failed call.
        observed = []
        for rc in (124, 137):
            got = subprocess.run([sys.executable, "-c", 'print(\'{"state":"delivered"}\'); exit(' + str(rc) + ')'],
                                 capture_output=True, text=True, timeout=10, env=self.env)
            state = json.loads(got.stdout)["state"] if got.returncode == 0 else "unknown"
            observed.append({"exit": got.returncode, "state": state})
        self.assertEqual(observed, [{"exit": 124, "state": "unknown"}, {"exit": 137, "state": "unknown"}])
        (self.root / "caller-results.json").write_text(json.dumps(observed))

    def test_paths(self):
        """Presence prerequisites preserve rows 1-5, including a purged binding."""
        receipts = self.leaf / "receipts"
        for path in (receipts, self.outbox):
            with self.subTest(path=path, shape="missing"):
                parked = path.with_name(path.name + ".parked")
                path.rename(parked)
                obj = self.answer(69)
                self.assertEqual((obj["row"], obj["path"]), (5, str(path)))
                parked.rename(path)
            with self.subTest(path=path, shape="unreadable"):
                path.chmod(0)
                try:
                    obj = self.answer(69)
                    self.assertEqual((obj["row"], obj["path"]), (5, str(path)))
                finally:
                    path.chmod(0o755)
        receipts.rmdir()
        (self.bindings / "fixture.retired").write_text("retired\n")
        obj = self.answer(70, "binding-retired")
        self.assertEqual((obj["row"], obj["path"]), (4, str(receipts)))
        # Config/closure/binding failures precede any beat decision.
        self.cp.unlink()
        self.answer(69)
        self.cp.write_bytes(fmt.canonical(dict(self.config, closure={str(CLIENT): "0" * 64,
                                                                   str(FORMAT): "0" * 64})))
        self.answer(70, "closure-mismatch")

    def test_readers(self):
        """Unknown/unsafe/partial beats never certify presence; no receipt is needed."""
        path = self.leaf / ".beat"
        good = path.read_bytes()
        for data in (b"", b" \n", b"\x00\n", good[:-1], good + b"epoch=1\n", b"x" * 4097,
                     good.replace(b"writer=runner", b"writer=runner writer=runner"),
                     good.replace(b"runner_pid=", b"bad_pid=")):
            with self.subTest(data=data[:60]):
                path.write_bytes(data)
                self.answer(69, "owner-automation-absent")
        path.unlink()
        self.answer(69, "owner-automation-absent")
        for shape in ("fifo", "directory", "symlink", "unreadable"):
            with self.subTest(shape=shape):
                if shape == "fifo":
                    os.mkfifo(path)
                elif shape == "directory":
                    path.mkdir()
                elif shape == "symlink":
                    path.symlink_to(self.root / "missing")
                else:
                    path.write_bytes(good)
                    path.chmod(0)
                self.answer(69, "owner-automation-absent")
                if shape == "directory":
                    path.rmdir()
                else:
                    path.unlink()
        self.beat(watcher_pid=2147483647)
        self.answer(69, "owner-automation-absent")
        self.beat()
        before = {str(p): p.read_bytes() for p in self.root.rglob("*") if p.is_file()}
        self.assertEqual(self.answer()["state"], "present")
        self.assertEqual(before, {str(p): p.read_bytes() for p in self.root.rglob("*") if p.is_file()})


if __name__ == "__main__":
    result = unittest.TextTestRunner(verbosity=2).run(unittest.TestSuite([Interface(CASE)]))
    sys.exit(0 if result.wasSuccessful() else 1)
