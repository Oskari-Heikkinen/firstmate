"""Public CLI tests for immutable code preparation, with no installed actor.

All repositories, stores, homes and passive adapters belong to this CI fixture.
No service/backend lifecycle operation is performed by these tests.
"""
import concurrent.futures
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[3]
TOOL = ROOT / "bin/fm-view-bundle.py"

# Test-only syscall interception surrounds the unchanged public executable.
# The real fsync delegates normally until a fixture-owned staging fd exists;
# no production fault option, private helper replacement or source assertion.
STAGING_FAULT_DRIVER = r'''
import errno
import hashlib
import json
import os
from pathlib import Path
import runpy
import stat
import sys

tool, fault, store, report, fixture = sys.argv[1:6]
store, report, fixture = Path(store), Path(report), Path(fixture)
sys.path.insert(0, str(Path(tool).parent))
sys.argv = [tool, *sys.argv[6:]]
real_fsync = os.fsync
fired = False

def root_identity(path):
    info = path.lstat()
    return [info.st_dev, info.st_ino]

def fsync(fd):
    global fired
    if fired:
        return real_fsync(fd)
    candidates = [path for path in store.iterdir() if path.name.startswith(".prepare-")]
    if not candidates:
        return real_fsync(fd)
    assert len(candidates) == 1, "fixture requires exactly one staging tree"
    stage = candidates[0]
    info = os.fstat(fd)
    phase = "file" if stat.S_ISREG(info.st_mode) else "directory"
    if fault == "file-sync":
        if phase != "file":
            return real_fsync(fd)
        opened = Path(os.readlink("/proc/self/fd/" + str(fd)))
        assert stage in opened.parents, "fault fd must belong to this staging tree"
    elif phase != "directory" or [info.st_dev, info.st_ino] != root_identity(stage):
        return real_fsync(fd)
    # A root-directory fsync is reached only after the entire unpublished tree
    # exists and is read-only. Record artifact facts to reject a vacuous fault.
    fired = True
    members = sorted(str(path.relative_to(stage)) for path in stage.rglob("*") if path.is_file())
    facts = {"fault": fault, "phase": phase, "stage": str(stage), "members": members,
             "stage_identity": root_identity(stage), "store_identity": root_identity(store)}
    if fault != "file-sync":
        manifest = (stage / "manifest.json").read_bytes()
        facts["identity"] = hashlib.sha256(manifest).hexdigest()
        facts["stage_mode"] = stage.stat().st_mode & 0o777
    if fault == "publication-collision":
        # Cause the REAL nonreplacing rename to fail, rather than replacing its
        # implementation: a concurrently created invalid destination is owned
        # by this test and must survive exactly, never be repaired or removed.
        real_fsync(fd)
        protected = store / facts["identity"]
        protected.mkdir(mode=0o700)
        (protected / "protected").write_bytes(b"collision belongs to another publisher\n")
        protected.chmod(0o500)
        facts["protected"] = str(protected)
        facts["protected_identity"] = root_identity(protected)
        facts["sentinel_identity"] = root_identity(protected / "protected")
        facts["sentinel_mode"] = (protected / "protected").stat().st_mode & 0o777
        report.write_text(json.dumps(facts))
        return None
    if fault in ("replace-store", "replace-stage"):
        old = store if fault == "replace-store" else stage
        # A read-only stage cannot be moved across parents on Linux: that
        # requires write permission for its '..' update. Displace it within
        # the writable store so its original read-only mode stays intact.
        displaced = (fixture if fault == "replace-store" else store) / ("displaced-" + fault)
        old.rename(displaced)
        old.mkdir(mode=0o700)
        protected = old
        if fault == "replace-store":
            # Recreate the exact stale staging pathname in the replacement
            # store, so cleanup cannot pass vacuously because that path is gone.
            protected = old / stage.name
            protected.mkdir(mode=0o700)
            facts["replacement_store_identity"] = root_identity(old)
        (protected / "protected").write_bytes(b"replacement is not cleanup authority\n")
        facts.update(displaced=str(displaced), protected=str(protected), protected_identity=root_identity(protected),
                     sentinel_identity=root_identity(protected / "protected"),
                     sentinel_mode=(protected / "protected").stat().st_mode & 0o777)
    report.write_text(json.dumps(facts))
    raise OSError(errno.EIO, "fixture post-staging " + fault + " failure")

os.fsync = fsync
runpy.run_path(tool, run_name="__main__")
'''


# Runtime effective-config observation delegates EVERY command to the real Git.
# Checking emitted argv/config is mechanism evidence, not source-byte matching;
# callbacks are independently witnessed before the guarded read is exercised.
GIT_AUDIT_PROXY = r'''
import json
import os
from pathlib import Path
import subprocess
import sys

real = os.environ["FM_FIXTURE_REAL_GIT"]
args = sys.argv[1:]
prefix = []
index = 0
while index < len(args):
    word = args[index]
    if word in ("--no-pager", "--no-optional-locks"):
        prefix.append(word)
        index += 1
    elif word in ("-c", "-C"):
        prefix.extend(args[index:index + 2])
        index += 2
    else:
        break
record = {"command": args[index:], "configuration": {}}
for key in ("core.hooksPath", "core.fsmonitor"):
    answer = subprocess.run([real, *prefix, "config", "--get", key], capture_output=True, timeout=5)
    record["configuration"][key] = {"rc": answer.returncode, "value": answer.stdout.decode().strip()}
with Path(os.environ["FM_FIXTURE_GIT_AUDIT"]).open("a") as stream:
    stream.write(json.dumps(record) + "\n")
os.execv(real, [real, *args])
'''

# Real Git children still execute and are reaped by the normal passive owner.
# Shared-budget time advances only AFTER each real child is reaped, so one
# command's simulated cost cannot cause a spurious timeout in that same call.
# Slow-command time uses equivalent accelerated monotonic/select units, without
# a production bound override or replacement of a production function.
GIT_CLOCK_DRIVER = r'''
import json
from pathlib import Path
import runpy
import selectors
import subprocess
import sys
import time

tool, scenario, report = sys.argv[1:4]
sys.path.insert(0, str(Path(tool).parent))
sys.argv = [tool, *sys.argv[4:]]
real_clock = time.monotonic
start = real_clock()
scale = 4.0 if scenario == "slow-command" else 1.0
offset = 0.0
records = []

def clock():
    return start + (real_clock() - start) * scale + offset

time.monotonic = clock
real_init = subprocess.Popen.__init__
real_wait = subprocess.Popen.wait
real_select = selectors.DefaultSelector.select

def initialize(child, args, *positional, **options):
    real_init(child, args, *positional, **options)
    if isinstance(args, (list, tuple)) and args[0] == "git":
        child.fixture_record = {"pid": child.pid, "argv": list(args), "select_timeouts": [], "reaped": False}
        records.append(child.fixture_record)

def wait(child, *positional, **options):
    global offset
    answer = real_wait(child, *positional, **options)
    record = getattr(child, "fixture_record", None)
    if record is not None and not record["reaped"]:
        record["reaped"] = True
        record["returncode"] = answer
        if scenario == "shared-budget":
            cost = (55.0, 50.0, 25.0)[min(len([r for r in records if r["reaped"]]) - 1, 2)]
            offset += cost
            record["virtual_cost"] = cost
    return answer

def select(selector, timeout=None):
    if records:
        records[-1]["select_timeouts"].append(timeout)
    return real_select(selector, None if timeout is None else timeout / scale)

subprocess.Popen.__init__ = initialize
subprocess.Popen.wait = wait
selectors.DefaultSelector.select = select
try:
    runpy.run_path(tool, run_name="__main__")
finally:
    Path(report).write_text(json.dumps({"records": records, "virtual_elapsed": clock() - start,
                                      "real_elapsed": real_clock() - start, "scenario": scenario}))
'''

SLOW_GIT_PROXY = r'''
import json
import os
from pathlib import Path
import sys
import time

# This fixture-only child has a finite eight-second lifetime even if the tested
# deadline regresses, and never touches a backend, session or shared process.
marker = Path(os.environ["FM_FIXTURE_SLOW_GIT"])
proc = Path("/proc/" + str(os.getpid()) + "/stat").read_text()
marker.write_text(json.dumps({"pid": os.getpid(), "start_ticks": proc.rsplit(")", 1)[1].split()[19]}))
time.sleep(8)
sys.exit(87)
'''


@unittest.skipUnless(sys.platform == "linux", "immutable native bundle publication is Linux-only; legacy remains selected")
class BundlePreparation(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        result = subprocess.run([sys.executable, str(TOOL), "requirements"], capture_output=True, timeout=5)
        if result.returncode:
            raise AssertionError(result.stderr)
        cls.requirements = json.loads(result.stdout)["files"]
        cls.environment = {key: value for key, value in os.environ.items() if not key.startswith("GIT_")}
        cls.environment.update(GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL=os.devnull,
                               GIT_AUTHOR_NAME="Fixture", GIT_AUTHOR_EMAIL="fixture@example.invalid",
                               GIT_COMMITTER_NAME="Fixture", GIT_COMMITTER_EMAIL="fixture@example.invalid",
                               PYTHONDONTWRITEBYTECODE="1")

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.repo = self.root / "source"
        self.home = self.root / "home"
        self.store = self.root / "versions"
        for path in (self.repo, self.home, self.store):
            path.mkdir(mode=0o700)
        (self.home / "state").mkdir(mode=0o700)
        for name in self.requirements:
            path = self.repo / name
            path.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(ROOT / name, path)
        self.git("init", "-q")
        self.git("add", "--all")
        self.git("commit", "-qm", "Fixture source")
        self.commit = self.git("rev-parse", "HEAD").stdout.decode().strip()

    def git(self, *args):
        result = subprocess.run(["git", "-C", str(self.repo), *args], env=self.environment,
                                capture_output=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        return result

    def command(self, *args, ok=True, environment=None):
        result = subprocess.run([sys.executable, str(TOOL), *map(str, args)], capture_output=True,
                                env=environment or self.environment, timeout=150)
        if ok:
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stderr, b"")
            return json.loads(result.stdout)
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertEqual(result.stdout, b"")
        self.assertIn(b"fm-view-bundle: refused:", result.stderr)
        return result

    def prepare(self, **options):
        return self.command("prepare", "--repo", self.repo, "--commit", self.commit,
                            "--store", self.store, "--home", self.home, **options)

    def prepared(self):
        answer = self.prepare()
        path = Path(answer["bundle"])
        self.assertEqual(path.parent, self.store)
        self.assertEqual(path.name, answer["identity"])
        self.assertTrue(self.command("verify", "--bundle", path, "--identity", path.name)["verified"])
        return path

    def clone_bundle(self, original):
        folder = self.root / ("copy-" + os.urandom(4).hex())
        folder.mkdir(mode=0o700)
        path = folder / original.name
        shutil.copytree(original, path)
        return path

    def staging_fault(self, fault):
        report = self.root / (fault + "-fault.json")
        result = subprocess.run([sys.executable, "-I", "-B", "-c", STAGING_FAULT_DRIVER,
                                 str(TOOL), fault, str(self.store), str(report), str(self.root),
                                 "prepare", "--repo", str(self.repo), "--commit", self.commit,
                                 "--store", str(self.store), "--home", str(self.home)],
                                capture_output=True, env=self.environment, timeout=150)
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertEqual(result.stdout, b"")
        self.assertIn(b"fm-view-bundle: refused:", result.stderr)
        self.assertTrue(report.is_file(), result.stderr)
        facts = json.loads(report.read_text())
        self.assertEqual(facts["fault"], fault)
        self.assertTrue(facts["members"], "the failure must occur after staging begins")
        stage = Path(facts["stage"])
        self.assertEqual(stage.parent, self.store)
        self.assertTrue(stage.name.startswith(".prepare-"))
        if fault != "file-sync":
            self.assertEqual(facts["phase"], "directory")
            self.assertEqual(facts["stage_mode"], 0o500)
            self.assertEqual(facts["members"], sorted(["manifest.json", *self.requirements]))
        return result, facts

    def candidate_after_valid_version(self):
        original = self.prepared()
        # Publish a distinct pinned candidate only in the fixture source, so
        # the tested failure cannot become existing-version reuse/refusal.
        source = self.repo / "bin/fm-view-adapter.sh"
        source.write_bytes(source.read_bytes() + b"\n# fixture post-staging candidate\n")
        self.git("add", "--all"); self.git("commit", "-qm", "Distinct staging candidate")
        self.commit = self.git("rev-parse", "HEAD").stdout.decode().strip()
        return original

    def test_post_staging_write_and_publication_failure_remove_only_owned_stage(self):
        original = self.candidate_after_valid_version()
        original_identity = (original.stat().st_dev, original.stat().st_ino)
        (self.home / "state/task.status").write_bytes(b"working: untouched by preparation\n")
        (self.home / "state/.status-presentation-cursor").write_bytes(b"previous cursor\n")
        before = {path.name: path.read_bytes() for path in (self.home / "state").iterdir()}
        for fault in ("file-sync", "publication-collision"):
            with self.subTest(fault=fault):
                result, facts = self.staging_fault(fault)
                self.assertFalse(os.path.lexists(facts["stage"]), "owned unpublished staging must be removed")
                self.assertEqual(list(self.store.glob(".prepare-*")), [])
                self.assertEqual((original.stat().st_dev, original.stat().st_ino), original_identity)
                self.assertTrue(self.command("verify", "--bundle", original, "--identity", original.name)["verified"])
                self.assertEqual(before, {path.name: path.read_bytes() for path in (self.home / "state").iterdir()})
                if fault == "file-sync":
                    self.assertEqual(facts["phase"], "file")
                    self.assertIn(b"fixture post-staging file-sync failure", result.stderr)
                    self.assertEqual(list(self.store.iterdir()), [original])
                else:
                    protected = Path(facts["protected"])
                    self.assertEqual(protected.name, facts["identity"])
                    self.assertEqual([protected.stat().st_dev, protected.stat().st_ino], facts["protected_identity"])
                    self.assertEqual(protected.stat().st_mode & 0o777, 0o500)
                    self.assertEqual([path.name for path in protected.iterdir()], ["protected"])
                    self.assertEqual((protected / "protected").read_bytes(), b"collision belongs to another publisher\n")
                    self.assertEqual([(protected / "protected").stat().st_dev, (protected / "protected").stat().st_ino],
                                     facts["sentinel_identity"])
                    self.assertEqual((protected / "protected").stat().st_mode & 0o777, facts["sentinel_mode"])
                    self.assertEqual(set(self.store.iterdir()), {original, protected})

    def test_post_staging_root_replacements_refuse_cleanup_and_preserve_both_trees(self):
        (self.home / "state/task.status").write_bytes(b"working: untouched by preparation\n")
        (self.home / "state/.status-presentation-cursor").write_bytes(b"previous cursor\n")
        before = {path.name: path.read_bytes() for path in (self.home / "state").iterdir()}
        for fault in ("replace-store", "replace-stage"):
            with self.subTest(fault=fault):
                self.store = self.root / ("versions-" + fault)
                self.store.mkdir(mode=0o700)
                original = self.candidate_after_valid_version()
                original_identity = (original.stat().st_dev, original.stat().st_ino)
                result, facts = self.staging_fault(fault)
                self.assertIn(b"staging identity changed; cleanup refused", result.stderr)
                protected, displaced = Path(facts["protected"]), Path(facts["displaced"])
                self.assertEqual([protected.stat().st_dev, protected.stat().st_ino], facts["protected_identity"])
                self.assertEqual(protected.stat().st_mode & 0o777, 0o700)
                self.assertEqual([path.name for path in protected.iterdir()], ["protected"])
                self.assertEqual((protected / "protected").read_bytes(), b"replacement is not cleanup authority\n")
                self.assertEqual([(protected / "protected").stat().st_dev, (protected / "protected").stat().st_ino],
                                 facts["sentinel_identity"])
                self.assertEqual((protected / "protected").stat().st_mode & 0o777, facts["sentinel_mode"])
                if fault == "replace-store":
                    self.assertEqual(protected, self.store / Path(facts["stage"]).name)
                    self.assertEqual([self.store.stat().st_dev, self.store.stat().st_ino], facts["replacement_store_identity"])
                    self.assertEqual(self.store.stat().st_mode & 0o777, 0o700)
                    self.assertEqual(list(self.store.iterdir()), [protected])
                    self.assertEqual([displaced.stat().st_dev, displaced.stat().st_ino], facts["store_identity"])
                    retained_stage = displaced / Path(facts["stage"]).name
                    retained_original = displaced / original.name
                else:
                    self.assertEqual(protected, Path(facts["stage"]))
                    self.assertEqual([self.store.stat().st_dev, self.store.stat().st_ino], facts["store_identity"])
                    self.assertEqual(displaced.parent, self.store)
                    self.assertEqual(set(self.store.iterdir()), {original, protected, displaced})
                    retained_stage, retained_original = displaced, original
                self.assertEqual([retained_stage.stat().st_dev, retained_stage.stat().st_ino], facts["stage_identity"])
                self.assertEqual(retained_stage.stat().st_mode & 0o777, 0o500)
                self.assertEqual((retained_original.stat().st_dev, retained_original.stat().st_ino), original_identity)
                self.assertTrue(self.command("verify", "--bundle", retained_original,
                                             "--identity", retained_original.name)["verified"])
                # Preserve the actual displaced tree, then verify a fixture-owned
                # evidence copy through the public API under its content name.
                evidence = self.root / ("retained-evidence-" + fault)
                evidence.mkdir(mode=0o700)
                copy = evidence / facts["identity"]
                shutil.copytree(retained_stage, copy)
                self.assertTrue(self.command("verify", "--bundle", copy, "--identity", copy.name)["verified"])
                self.assertEqual(before, {path.name: path.read_bytes() for path in (self.home / "state").iterdir()})

    def git_proxy(self, script, **extra):
        folder = self.root / ("git-proxy-" + os.urandom(4).hex())
        folder.mkdir(mode=0o700)
        proxy = folder / "git"
        proxy.write_text("#!" + sys.executable + "\n" + script)
        proxy.chmod(0o700)
        real = shutil.which("git", path=self.environment.get("PATH"))
        self.assertTrue(real, "fixture requires the real Git")
        return dict(self.environment, PATH=str(folder) + os.pathsep + self.environment.get("PATH", ""),
                    FM_FIXTURE_REAL_GIT=real, **extra)

    def test_hostile_git_environment_cannot_redirect_or_inject_pinned_reads(self):
        original = self.prepared()
        expected = original.name
        foreign = self.root / "foreign-checkout"
        foreign.mkdir(mode=0o700)
        answer = subprocess.run(["git", "-C", str(foreign), "init", "-q"], capture_output=True,
                                env=self.environment, timeout=10)
        self.assertEqual(answer.returncode, 0, answer.stderr)
        sentinel = foreign / "protected"; sentinel.write_bytes(b"foreign fixture remains untouched\n")
        bad_index = self.root / "hostile-index"; bad_index.write_bytes(b"invalid index must not be opened for writing\n")
        objects = self.root / "foreign-objects"; objects.mkdir(mode=0o700)
        bad_config = self.root / "hostile-config"; bad_config.write_bytes(b"[invalid configuration\n")
        ambient = self.root / "hostile-home"; ambient.mkdir(mode=0o700)
        (ambient / ".gitconfig").write_bytes(b"[invalid ambient configuration\n")
        xdg = self.root / "hostile-xdg"; (xdg / "git").mkdir(parents=True, mode=0o700)
        (xdg / "git/config").write_bytes(b"[invalid xdg configuration\n")
        trace, setup_trace, event_trace = (self.root / name for name in ("trace", "setup-trace", "event-trace"))
        cases = {
            "repository": {"GIT_DIR": str(foreign / ".git"), "GIT_WORK_TREE": str(foreign),
                           "GIT_COMMON_DIR": str(foreign / ".git")},
            "index-objects": {"GIT_INDEX_FILE": str(bad_index), "GIT_OBJECT_DIRECTORY": str(objects),
                              "GIT_ALTERNATE_OBJECT_DIRECTORIES": str(objects)},
            "config-count": {"GIT_CONFIG_COUNT": "2", "GIT_CONFIG_KEY_0": "core.bare", "GIT_CONFIG_VALUE_0": "true",
                             "GIT_CONFIG_KEY_1": "core.worktree", "GIT_CONFIG_VALUE_1": str(foreign)},
            "config-parameters": {"GIT_CONFIG_PARAMETERS": "not-a-quoted-key-value-pair"},
            "config-files": {"GIT_CONFIG_GLOBAL": str(bad_config), "GIT_CONFIG_SYSTEM": str(bad_config),
                             "GIT_CONFIG_NOSYSTEM": "0"},
            "ambient-config": {"HOME": str(ambient), "XDG_CONFIG_HOME": str(xdg)},
            "tracing": {"GIT_TRACE": str(trace), "GIT_TRACE_SETUP": str(setup_trace), "GIT_TRACE2_EVENT": str(event_trace)},
        }
        (self.home / "state/task.status").write_bytes(b"working: preserved\n")
        before = {path.name: path.read_bytes() for path in (self.home / "state").iterdir()}
        for name, hostile in cases.items():
            with self.subTest(inheritance=name):
                self.store = self.root / ("hostile-store-" + name)
                self.store.mkdir(mode=0o700)
                # Unlike ordinary fixture setup, these variables reach the
                # actual executable unsanitized. The production owner must
                # isolate them; fixture helpers must not do that work for it.
                result = self.prepare(environment=dict(self.environment, **hostile))
                self.assertEqual(result["identity"], expected)
                bundle = Path(result["bundle"])
                self.assertTrue(self.command("verify", "--bundle", bundle, "--identity", expected)["verified"])
                self.assertEqual(list(self.store.iterdir()), [bundle])
                self.assertEqual(sentinel.read_bytes(), b"foreign fixture remains untouched\n")
                self.assertEqual(bad_index.read_bytes(), b"invalid index must not be opened for writing\n")
                self.assertEqual(before, {path.name: path.read_bytes() for path in (self.home / "state").iterdir()})
                self.assertFalse(any(path.exists() for path in (trace, setup_trace, event_trace)))

    def test_commit_and_blob_replace_refs_cannot_substitute_pinned_code(self):
        original = self.prepared()
        pinned = self.commit
        original_tree = self.git("rev-parse", pinned + "^{tree}").stdout.strip()
        old_blob = self.git("rev-parse", pinned + ":bin/fm-view-adapter.sh").stdout.decode().strip()
        source = self.repo / "bin/fm-view-adapter.sh"
        source.write_bytes(source.read_bytes() + b"\n# distinct fixture replacement object\n")
        self.git("add", "--all"); self.git("commit", "-qm", "Fixture replacement content")
        replacement = self.git("rev-parse", "HEAD").stdout.decode().strip()
        new_blob = self.git("rev-parse", "HEAD:bin/fm-view-adapter.sh").stdout.decode().strip()
        self.assertNotEqual(original_tree, self.git("rev-parse", "HEAD^{tree}").stdout.strip())
        self.assertNotEqual(old_blob, new_blob)
        self.commit = pinned
        for name, old, new in (("commit", pinned, replacement), ("blob", old_blob, new_blob)):
            with self.subTest(replace=name):
                self.git("replace", old, new)
                self.assertEqual(self.git("replace", "--list", old).stdout.decode().strip(), old)
                self.store = self.root / ("replace-store-" + name)
                self.store.mkdir(mode=0o700)
                answer = self.prepare(environment=dict(self.environment, GIT_NO_REPLACE_OBJECTS=""))
                self.assertEqual(answer["identity"], original.name)
                self.assertTrue(self.command("verify", "--bundle", answer["bundle"], "--identity", original.name)["verified"])
                self.git("replace", "--delete", old)
        self.assertTrue(self.command("verify", "--bundle", original, "--identity", original.name)["verified"])

    def test_hooks_and_fsmonitor_are_disabled_for_every_real_git_observation(self):
        original = self.prepared()
        hooks = self.root / "fixture-hooks"; hooks.mkdir(mode=0o700)
        hook_marker, monitor_marker = self.root / "hook-called", self.root / "monitor-called"
        hook = hooks / "pre-commit"
        hook.write_text("#!" + sys.executable + "\nfrom pathlib import Path\nPath(" + repr(str(hook_marker)) + ").write_text('hook called')\n")
        hook.chmod(0o700)
        self.git("config", "core.hooksPath", str(hooks))
        self.git("commit", "--allow-empty", "-qm", "Fixture hook witness")
        self.assertEqual(hook_marker.read_text(), "hook called")
        hook_marker.unlink()
        monitor = self.root / "fixture-fsmonitor"
        monitor.write_text("#!" + sys.executable + "\nfrom pathlib import Path\nimport sys\nPath(" + repr(str(monitor_marker))
                           + ").write_text('monitor called')\nsys.stdout.buffer.write(b'fixture-token\\0/\\0')\n")
        monitor.chmod(0o700)
        self.git("-c", "core.fsmonitor=" + str(monitor), "status", "--porcelain", "--untracked-files=no")
        self.assertEqual(monitor_marker.read_text(), "monitor called")
        monitor_marker.unlink()
        self.git("config", "core.fsmonitor", str(monitor))
        audit = self.root / "git-observation-audit.jsonl"
        env = self.git_proxy(GIT_AUDIT_PROXY, FM_FIXTURE_GIT_AUDIT=str(audit))
        self.store = self.root / "callback-guard-store"; self.store.mkdir(mode=0o700)
        answer = self.prepare(environment=env)
        self.assertEqual(answer["identity"], original.name)
        self.assertFalse(hook_marker.exists())
        self.assertFalse(monitor_marker.exists())
        observations = [json.loads(line) for line in audit.read_text().splitlines()]
        self.assertTrue(observations, "must observe actual child Git calls, not a preflight refusal")
        self.assertTrue(any(row["command"][:1] == ["status"] for row in observations))
        for row in observations:
            with self.subTest(command=row["command"]):
                self.assertEqual(row["configuration"]["core.hooksPath"], {"rc": 0, "value": "/dev/null"})
                self.assertEqual(row["configuration"]["core.fsmonitor"], {"rc": 0, "value": "false"})
        # Reads need not normally execute a Git hook. The effective-config
        # check independently proves hook suppression rather than claiming a
        # silent pre-commit tripwire alone tests that defense-in-depth guard.
        self.assertTrue(self.command("verify", "--bundle", answer["bundle"], "--identity", original.name)["verified"])

    def clocked_preparation(self, scenario, environment=None):
        report = self.root / (scenario + "-clock.json")
        result = subprocess.run([sys.executable, "-I", "-B", "-c", GIT_CLOCK_DRIVER, str(TOOL), scenario, str(report),
                                 "prepare", "--repo", str(self.repo), "--commit", self.commit,
                                 "--store", str(self.store), "--home", str(self.home)],
                                capture_output=True, env=environment or self.environment, timeout=15)
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertEqual(result.stdout, b"")
        self.assertIn(b"fm-view-bundle: refused:", result.stderr)
        self.assertTrue(report.is_file(), result.stderr)
        facts = json.loads(report.read_text())
        self.assertEqual(facts["scenario"], scenario)
        self.assertTrue(facts["records"])
        self.assertTrue(all(row["reaped"] for row in facts["records"]), facts)
        self.assertTrue(all(row["select_timeouts"] for row in facts["records"]), facts)
        self.assertEqual(list(self.store.iterdir()), [], "deadline refusal precedes any publication/staging")
        return result, facts

    def test_shared_git_budget_expires_between_real_successful_commands(self):
        result, facts = self.clocked_preparation("shared-budget")
        self.assertIn(b"Git preparation deadline expired", result.stderr)
        self.assertEqual(len(facts["records"]), 3)
        self.assertTrue(all(row["returncode"] == 0 for row in facts["records"]), facts)
        self.assertEqual([row["virtual_cost"] for row in facts["records"]], [55.0, 50.0, 25.0])
        self.assertGreaterEqual(facts["virtual_elapsed"], 130)
        self.assertTrue(all(0 < row["select_timeouts"][0] <= 20 for row in facts["records"]), facts)
        # After 105 seconds of completed-command cost, the next real child
        # gets only the remainder, not a refreshed 20- or 120-second budget.
        self.assertLessEqual(facts["records"][2]["select_timeouts"][0], 15)

    def test_slow_git_child_hits_command_cap_and_is_reaped(self):
        marker = self.root / "slow-git-child.json"
        env = self.git_proxy(SLOW_GIT_PROXY, FM_FIXTURE_SLOW_GIT=str(marker))
        result, facts = self.clocked_preparation("slow-command", environment=env)
        self.assertIn(b"passive observation deadline expired", result.stderr)
        self.assertEqual(len(facts["records"]), 1)
        self.assertLess(facts["records"][0]["returncode"], 0)
        self.assertLessEqual(facts["records"][0]["select_timeouts"][0], 20)
        self.assertGreaterEqual(facts["virtual_elapsed"], 19)
        self.assertTrue(marker.is_file(), "must time out an actually running fixture child")
        child = json.loads(marker.read_text())
        self.assertEqual(child["pid"], facts["records"][0]["pid"])
        proc = Path("/proc/" + str(child["pid"]) + "/stat")
        try:
            current = proc.read_text().rsplit(")", 1)[1].split()[19]
        except FileNotFoundError:
            current = None
        self.assertNotEqual(current, child["start_ticks"], "the exact timed-out Git generation must be gone")

    def test_public_preparation_reuse_pins_and_no_home_mutation(self):
        (self.home / "state/task.status").write_bytes(b"needs-decision [key=x]: preserved\n")
        (self.home / "state/.status-presentation-cursor").write_bytes(b"existing cursor\n")
        before = {p.name: p.read_bytes() for p in (self.home / "state").iterdir()}
        original = self.prepared()
        inode = original.stat().st_ino
        self.assertEqual(Path(self.prepare()["bundle"]), original)
        self.assertEqual(original.stat().st_ino, inode)
        self.assertEqual(list(self.store.iterdir()), [original])
        manifest = json.loads((original / "manifest.json").read_bytes())
        self.assertEqual(manifest["commit"], self.commit)
        self.assertEqual(manifest["tree"], self.git("rev-parse", "HEAD^{tree}").stdout.decode().strip())
        self.assertEqual([row["path"] for row in manifest["files"]], self.requirements)
        # A newer clean source commit does not change an explicitly pinned old
        # version. It can be prepared independently without editing the old one.
        source = self.repo / "bin/fm-view-adapter.sh"
        source.write_bytes(source.read_bytes() + b"\n# fixture newer version\n")
        self.git("add", "--all"); self.git("commit", "-qm", "New fixture version")
        self.assertEqual(Path(self.prepare()["bundle"]), original)
        self.commit = self.git("rev-parse", "HEAD").stdout.decode().strip()
        new = self.prepared()
        self.assertNotEqual(new, original)
        self.assertEqual(original.stat().st_ino, inode)
        self.assertTrue(self.command("verify", "--bundle", original)["verified"])
        self.assertEqual(before, {p.name: p.read_bytes() for p in (self.home / "state").iterdir()})

    def test_dirty_missing_symlink_and_oversized_dependencies_refuse_before_publish(self):
        source = self.repo / "bin/fm-composer-lib.sh"
        source.write_bytes(source.read_bytes() + b"\n# dirty\n")
        self.assertIn(b"dirty tracked source", self.prepare(ok=False).stderr)
        self.git("checkout", "--", "bin/fm-composer-lib.sh")
        source.unlink()
        self.git("add", "--all"); self.git("commit", "-qm", "Missing dependency")
        self.commit = self.git("rev-parse", "HEAD").stdout.decode().strip()
        self.assertIn(b"incomplete", self.prepare(ok=False).stderr)
        source.symlink_to(self.home / "state/task.status")
        self.git("add", "--all"); self.git("commit", "-qm", "Symlink dependency")
        self.commit = self.git("rev-parse", "HEAD").stdout.decode().strip()
        self.assertIn(b"nonregular", self.prepare(ok=False).stderr)
        source.unlink(); source.write_bytes(b"x" * (1024 * 1024 + 1))
        self.git("add", "--all"); self.git("commit", "-qm", "Oversized dependency")
        self.commit = self.git("rev-parse", "HEAD").stdout.decode().strip()
        self.assertIn(b"byte bound", self.prepare(ok=False).stderr)
        self.assertEqual(list(self.store.iterdir()), [])

    def test_store_placement_modes_and_commit_identity_refuse(self):
        self.commit = "HEAD"
        self.assertIn(b"full commit identity", self.prepare(ok=False).stderr)
        self.commit = self.git("rev-parse", "HEAD").stdout.decode().strip()
        self.store.chmod(0o755)
        self.assertIn(b"mode", self.prepare(ok=False).stderr)
        self.store.chmod(0o700)
        outside = self.store
        for forbidden in (self.home / "state/code", self.repo / "code"):
            forbidden.mkdir(mode=0o700)
            self.store = forbidden
            self.assertIn(b"outside checkout", self.prepare(ok=False).stderr)
            self.assertEqual(list(forbidden.iterdir()), [])
        link = self.root / "linked-store"; link.symlink_to(outside, target_is_directory=True)
        self.store = link
        self.assertIn(b"noncanonical", self.prepare(ok=False).stderr)
        # A different checkout is equally unsuitable as a stable code store.
        other = self.root / "other-checkout"; other.mkdir(mode=0o700)
        (other / ".git").write_text("gitdir: elsewhere\n")
        self.store = other / "code"; self.store.mkdir(mode=0o700)
        self.assertIn(b"inside a Git checkout", self.prepare(ok=False).stderr)
        self.assertEqual(list(outside.iterdir()), [])

    def test_existing_version_never_repaired_and_every_member_verified(self):
        original = self.prepared()
        before_manifest = (original / "manifest.json").read_bytes()
        pristine = self.clone_bundle(original)
        self.assertTrue(self.command("verify", "--bundle", pristine)["verified"])
        victim = original / "bin/fm-tmux-lib.sh"
        victim_mode = victim.stat().st_mode & 0o777
        victim.chmod(0o600); victim.write_bytes(b"corrupt dependency\n"); victim.chmod(victim_mode)
        self.assertEqual(victim.stat().st_mode & 0o777, victim_mode)
        self.assertIn(b"hash mismatch", self.prepare(ok=False).stderr)
        self.assertEqual(victim.read_bytes(), b"corrupt dependency\n")
        self.assertEqual((original / "manifest.json").read_bytes(), before_manifest)
        self.assertEqual(list(self.store.iterdir()), [original])
        # Test the other unsupported shapes through the public verifier, not
        # source-code assertions or a private parser.
        for defect in ("missing", "symlink", "hardlink", "mode", "extra", "fifo"):
            path = self.clone_bundle(pristine)
            self.assertTrue(self.command("verify", "--bundle", path)["verified"])
            member = path / "bin/fm_view_status.py"
            (path / "bin").chmod(0o700)
            if defect == "missing": member.unlink()
            elif defect == "symlink":
                member.unlink(); member.symlink_to(self.home / "state/protected")
            elif defect == "hardlink": os.link(member, self.root / "extra-link")
            elif defect == "mode": member.chmod(0o600)
            elif defect == "extra": (path / "bin/unexpected.py").write_bytes(b"not admitted\n")
            else:
                member.unlink(); os.mkfifo(member)
            (path / "bin").chmod(0o500)
            self.command("verify", "--bundle", path, ok=False)
        self.assertFalse((self.home / "state/protected").exists())
        self.command("verify", "--bundle", original, "--identity", "0" * 64, ok=False)

    def test_manifest_traversal_unknown_version_and_duplicate_refuse(self):
        original = self.prepared()
        protected = self.root / "protected"; protected.write_bytes(b"never opened or modified\n")
        for defect in ("traversal", "schema", "duplicate", "bool-size", "noncanonical"):
            path = self.clone_bundle(original)
            manifest = json.loads((path / "manifest.json").read_bytes())
            if defect == "traversal": manifest["files"][0]["path"] = "../../protected"
            if defect == "schema": manifest["schema"] = "fm-view-bundle.v999"
            if defect == "bool-size": manifest["files"][0]["bytes"] = True
            raw = json.dumps(manifest, sort_keys=True, separators=(",", ":")).encode() + b"\n"
            if defect == "duplicate": raw = b'{"schema":"fm-view-bundle.v1",' + raw[1:]
            if defect == "noncanonical": raw = b" " + raw
            (path / "manifest.json").chmod(0o600)
            (path / "manifest.json").write_bytes(raw)
            (path / "manifest.json").chmod(0o400)
            renamed = path.parent / hashlib.sha256(raw).hexdigest()
            path.rename(renamed)
            self.command("verify", "--bundle", renamed, ok=False)
        self.assertEqual(protected.read_bytes(), b"never opened or modified\n")

    def test_concurrent_publish_is_idempotent_and_keeps_previous_versions(self):
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
            results = list(pool.map(lambda _: self.prepare(), range(2)))
        self.assertEqual(results[0], results[1])
        original = Path(results[0]["bundle"])
        self.assertEqual(list(self.store.iterdir()), [original])
        self.assertTrue(self.command("verify", "--bundle", original)["verified"])
        # An existing empty path is never replaced, even when its name equals
        # the expected content identity. This is a refusal, not stale cleanup.
        moved = self.root / original.name
        # Only this fixture's setup temporarily permits the cross-parent
        # directory move. Restore the immutable root before any verifier or
        # preparation call, retaining its original object identity.
        moved_identity = (original.stat().st_dev, original.stat().st_ino)
        self.assertEqual(original.stat().st_mode & 0o777, 0o500)
        original.chmod(0o700)
        original.rename(moved)
        moved.chmod(0o500)
        self.assertEqual((moved.stat().st_dev, moved.stat().st_ino), moved_identity)
        self.assertEqual(moved.stat().st_mode & 0o777, 0o500)
        original.mkdir(mode=0o500)
        inode = original.stat().st_ino
        self.prepare(ok=False)
        self.assertEqual(original.stat().st_ino, inode)
        self.assertEqual(list(original.iterdir()), [])
        self.assertTrue(self.command("verify", "--bundle", moved)["verified"])

    def test_relocated_code_runs_fixed_passive_owners_without_source_checkout(self):
        bundle = self.prepared()
        fakebin = self.root / "fakebin"; fakebin.mkdir()
        tmux = fakebin / "tmux"
        tmux.write_text('#!/bin/bash\ncase "$1" in display-message) printf "%%1\\n";; capture-pane) printf "plain pane\\n";; *) exit 81;; esac\n')
        tmux.chmod(0o700)
        (self.home / "state/task.meta").write_text("kind=scout\nbackend=tmux\nwindow=fixture:fm-task\nharness=pi\nspawn_gen=g1\n")
        (self.home / "state/task.status").write_text("needs-decision [key=x]: question\n")
        before = {p.name: p.read_bytes() for p in (self.home / "state").iterdir()}
        def adapter(base, operation):
            env = dict(self.environment, FM_HOME=str(self.home), FM_ROOT_OVERRIDE=str(base),
                       FM_STATE_OVERRIDE=str(self.home / "state"), FM_DATA_OVERRIDE=str(self.home / "data"),
                       PATH=str(fakebin) + os.pathsep + self.environment.get("PATH", ""))
            return subprocess.run(["bash", str(base / "bin/fm-view-adapter.sh"), operation, "task", "done: report"],
                                  cwd=self.home, env=env, capture_output=True, timeout=20)
        expected = {name: adapter(self.repo, name) for name in ("backend", "snapshot-endpoint", "saved-custody", "done-proof", "forge")}
        for name, result in expected.items():
            self.assertEqual(result.returncode, 0, (name, result.stderr))
            self.assertTrue(result.stdout.endswith(b"\0"), name)
            self.assertEqual(result.stderr, b"", name)
        hidden = self.root / "source-unavailable"
        self.repo.rename(hidden)
        for name, result in expected.items():
            actual = adapter(bundle, name)
            self.assertEqual((actual.returncode, actual.stdout, actual.stderr),
                             (result.returncode, result.stdout, result.stderr), name)
        # The native module imports/fold are usable from the immutable version;
        # PYTHONDONTWRITEBYTECODE prevents any cache writer in that code tree.
        code = 'import sys,json;sys.path.insert(0,sys.argv[1]);from fm_view_engine import Inputs;print(json.dumps(Inputs(sys.argv[2]).fold("task")))'
        result = subprocess.run([sys.executable, "-I", "-B", "-c", code, str(bundle / "bin"), str(self.home)],
                                cwd=self.home, capture_output=True, env=self.environment, timeout=20)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)["open"][0]["key"], "x")
        self.assertEqual(before, {p.name: p.read_bytes() for p in (self.home / "state").iterdir()})
        self.assertTrue(self.command("verify", "--bundle", bundle)["verified"])


if __name__ == "__main__":
    unittest.main()
