"""Native reader versus legacy public CLI on identical isolated fake adapters."""
import asyncio
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "bin"))
from fm_view_crew import Crew, LegacyRequired
from fm_view_engine import Inputs
from fm_view_process import run
from fm_view_runs import Run, overview


@unittest.skipUnless(hasattr(os, "pidfd_open"), "native passive adapters require Linux pidfds; other platforms retain legacy")
class PassiveProcess(unittest.TestCase):
    def test_exit_and_inherited_pipe_cleanup(self):
        script = "import subprocess,sys; subprocess.Popen([sys.executable,'-c','import time;time.sleep(30)']); print('captured',flush=True)"
        observed = run([sys.executable, "-c", script], str(ROOT), 3)
        self.assertEqual(observed.status, 0, observed)
        self.assertEqual(observed.stdout, b"captured\n")
        self.assertEqual(observed.problem, "")

    def test_hang_and_output_cap(self):
        hung = run([sys.executable, "-c", "import time;time.sleep(30)"], str(ROOT), 0.1)
        self.assertEqual(hung.status, 124)
        self.assertTrue(hung.problem)
        capped = run([sys.executable, "-c", "import sys;sys.stdout.write('x'*100000)"], str(ROOT), 3, max_output=100)
        self.assertEqual(capped.status, 125)
        self.assertEqual(len(capped.stdout), 100)
        failed = run(["/no/such/fm-passive-adapter"], str(ROOT), 3)
        self.assertEqual(failed.status, 127)


@unittest.skipUnless(hasattr(os, "pidfd_open"), "native passive adapters require Linux pidfds; other platforms retain legacy")
class CrewParity(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.home = Path(self.temporary.name).resolve()
        self.state, self.worktree, self.fakebin = (self.home / name for name in ("state", "worktree", "fakebin"))
        for folder in (self.state, self.worktree, self.fakebin):
            folder.mkdir()
        self.env = dict(os.environ, GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM="1",
                        GIT_AUTHOR_NAME="fixture", GIT_AUTHOR_EMAIL="fixture@example.invalid",
                        GIT_COMMITTER_NAME="fixture", GIT_COMMITTER_EMAIL="fixture@example.invalid",
                        FM_HOME=str(self.home), FM_ROOT_OVERRIDE=str(self.home), FM_STATE_OVERRIDE=str(self.state),
                        FM_DATA_OVERRIDE=str(self.home / "data"), FM_CREW_STATE_NO_FORGE="1")
        # Every tool comes from a known real installation or this case's fakebin,
        # never a live home's endpoint namespace or external model/forge.
        self.env["PATH"] = str(self.fakebin) + os.pathsep + self.env["PATH"]
        self.git("init", "-q")
        self.git("checkout", "-q", "-b", "fm/task")
        self.git("commit", "-q", "--allow-empty", "-m", "fixture")
        self.head = self.git("rev-parse", "HEAD").strip()
        self.git("update-ref", "refs/remotes/origin/main", self.head)
        self.write_meta()
        self.status(b"paused: external wait\n")
        self.busy("idle")
        self.fake("no-mistakes", '''case "${1:-} ${2:-}" in
"axi status") if [ "${3:-}" = --run ]; then printf '%s\\n' "${FM_FAKE_SELECTED:-}"; exit "${FM_FAKE_SELECTED_RC:-0}"; fi
  printf '%s\\n' "${FM_FAKE_STATUS:-}"; exit "${FM_FAKE_STATUS_RC:-0}" ;;
"axi ") printf '%s\\n' "${FM_FAKE_OVERVIEW:-${FM_FAKE_STATUS:-}}"; exit "${FM_FAKE_OVERVIEW_RC:-0}" ;;
"axi logs") printf '%s\\n' "${FM_FAKE_CI_LOG:-}" ;;
"runs --limit") printf '%s\\n' "${FM_FAKE_LEDGER:-}" ;;
"daemon status") exit "${FM_FAKE_DAEMON_RC:-0}" ;;
esac
''')
        self.fake("tmux", '''case "${1:-}" in
 display-message) printf '%%1\\n'; exit 0 ;;
 capture-pane) printf 'fixture pane\\n'; exit 0 ;;
esac
exit 1
''')
        self.fake("gh", "printf 'state=%s\\nmerged=%s\\n' \"${FM_FAKE_PR_STATE:-OPEN}\" \"${FM_FAKE_PR_MERGED:-false}\"\n")
        self.fake("gh-axi", "exit 1\n")

    def tearDown(self):
        self.temporary.cleanup()

    def fake(self, name, text):
        path = self.fakebin / name
        path.write_text("#!/usr/bin/env bash\nset -u\n" + text)
        path.chmod(0o700)

    def git(self, *args):
        answer = subprocess.run(["git", "-C", str(self.worktree), *args], env=self.env,
                                capture_output=True, text=True, timeout=10)
        self.assertEqual(answer.returncode, 0, answer.stderr)
        return answer.stdout

    def write_meta(self, kind="ship", backend="tmux"):
        (self.state / "task.meta").write_text(
            f"kind={kind}\nbackend={backend}\nworktree={self.worktree}\nwindow=fixture:task\nharness=pi\nspawn_gen=g1\nmode=direct-push\n")

    def status(self, raw):
        (self.state / "task.status").write_bytes(raw)

    def busy(self, value):
        (self.state / "task.busy-gen").write_text("b1\n")
        (self.state / "task.busy-state").write_text(
            f"v1 gen=b1 seq=1 state={value} source=pi-ext event=fixture ts=1\n")

    def run_record(self, status="running", outcome="", head=None, extra="", branch="fm/task"):
        return f"id: run1\nbranch: {branch}\nhead: {head or self.head}\nstatus: {status}\noutcome: {outcome}\n" + extra

    def compare(self):
        before = {path.name: path.read_bytes() for path in self.state.iterdir() if path.is_file()}
        native = Crew(Inputs(str(self.home)), "task", self.env).read()
        legacy = subprocess.run(["bash", str(ROOT / "bin" / "fm-crew-state.sh"), "task"], env=self.env,
                                capture_output=True, timeout=30)
        self.assertEqual(legacy.returncode, 0, legacy.stderr)
        self.assertEqual(native["raw"].encode("utf-8", "surrogateescape") + b"\n", legacy.stdout)
        self.assertEqual(before, {path.name: path.read_bytes() for path in self.state.iterdir() if path.is_file()})
        return native

    def test_full_records_gates_outcomes_and_ci(self):
        cases = [
            (self.run_record(), ""),
            (self.run_record("fixing"), ""),
            (self.run_record("ci"), "all CI checks passed - still monitoring until merged or closed"),
            (self.run_record("fixing", extra="steps[1]{step,status,findings,duration_ms}:\n  ci,fixing,0,1\n"), "CI checks passed"),
            (self.run_record("awaiting_approval", extra="gate: review\nfindings[1]{id,severity,file,line,action,description}:\n  f1,major,x,1,ask-user,question\n"), ""),
            (self.run_record("running", extra="gate:\n  step: fix\n  state: fix_review\nfindings[1]{id,severity,file,line,action,description}:\n  f1,major,x,1,fix,not a human finding\n"), ""),
            (self.run_record("completed", "passed-with-skips"), ""),
            (self.run_record("cancelled", "cancelled", extra="gate: review\n"), ""),
            (self.run_record("failed", "failed"), ""),
            (self.run_record("completed", "checks-passed"), ""),
            (self.run_record("running", extra="steps[1]{step,status,findings,duration_ms}:\n  test,running,0,1\nactive_steps[1]{step,last_activity}:\n  test,now\n"), ""),
        ]
        for record, ci in cases:
            with self.subTest(record=record):
                self.env.update(FM_FAKE_STATUS=record, FM_FAKE_CI_LOG=ci)
                self.compare()

    def test_status_reconciliation(self):
        for status in (b"needs-decision [key=x]: question\n", b"blocked [key=x]: timeout reaching daemon\n",
                       b"blocked [key=x]: no-mistakes daemon socket missing\n"):
            for recent in ("now", "quiet 1h"):
                with self.subTest(status=status, recent=recent):
                    self.status(status)
                    self.env["FM_FAKE_STATUS"] = self.run_record(extra="active_steps[1]{step,last_activity}:\n  test," + recent + "\n")
                    self.compare()

    def test_selected_identity_and_mismatch(self):
        self.env["FM_FAKE_STATUS"] = self.run_record()
        self.env["FM_FAKE_OVERVIEW"] = f"count: 1 of 1 total\nruns[1]{{id,branch,status,head,pr}}:\n  chosen,fm/task,running,{self.head},\n"
        self.env["FM_FAKE_SELECTED"] = self.run_record("fixing").replace("id: run1", "id: chosen")
        self.compare()
        self.env["FM_FAKE_SELECTED"] = self.run_record("failed").replace("id: run1", "id: chosen")
        self.compare()
        self.env["FM_FAKE_SELECTED"] = self.run_record("running").replace("id: run1", "id: wrong")
        self.compare()

    def test_coarse_dead_instrument(self):
        self.env["FM_FAKE_STATUS"] = self.run_record("completed", branch="fm/other")
        self.env["FM_FAKE_LEDGER"] = f"failed fm/task {self.head[:12]} 2026-01-01 10:00\n"
        self.env["FM_FAKE_DAEMON_RC"] = "1"
        self.compare()
        self.env["FM_FAKE_DAEMON_RC"] = "0"
        self.compare()

    def test_pane_and_task_kinds(self):
        self.env["FM_FAKE_STATUS"] = ""
        for kind in ("ship", "scout", "secondmate"):
            for value in ("busy", "idle", "unknown"):
                with self.subTest(kind=kind, value=value):
                    self.write_meta(kind)
                    self.busy(value)
                    self.compare()

    def test_fresh_head_daemon_and_pane_negative_controls(self):
        self.status(b"paused: external wait\n")
        self.env["FM_FAKE_STATUS"] = self.run_record("completed", "checks-passed")
        first = self.compare()
        self.git("commit", "-q", "--allow-empty", "-m", "advance")
        second = self.compare()
        self.assertNotEqual(first["raw"], second["raw"])
        self.env["FM_FAKE_STATUS"] = self.run_record("running", head="a" * 40)
        self.env["FM_FAKE_DAEMON_RC"] = "0"
        alive = self.compare()
        self.env["FM_FAKE_DAEMON_RC"] = "1"
        dead = self.compare()
        self.assertNotEqual(alive["raw"], dead["raw"])
        self.env["FM_FAKE_STATUS"] = ""
        self.busy("busy")
        busy = self.compare()
        self.busy("idle")
        idle = self.compare()
        self.assertNotEqual(busy["raw"], idle["raw"])
        self.assertEqual((self.state / "task.status").read_bytes(), b"paused: external wait\n")

    def test_unsupported_backend_never_calls_herdr(self):
        self.env["FM_FAKE_STATUS"] = ""
        self.write_meta(backend="herdr")
        tripwire = self.home / "herdr-called"
        self.fake("herdr", f"printf called > '{tripwire}'\nexit 1\n")
        with self.assertRaises(LegacyRequired):
            Crew(Inputs(str(self.home)), "task", self.env).read()
        self.assertFalse(tripwire.exists())

    def test_generation_barrier_before_external_observation(self):
        inputs = Inputs(str(self.home))
        old = inputs.metadata("task")
        (self.state / "task.meta").write_text((self.state / "task.meta").read_text().replace("g1", "g2"))
        crew = Crew(inputs, "task", self.env, expected_generation=old)
        answer = crew.read()
        self.assertEqual(answer["state"], "unknown")
        self.assertEqual(crew.observations, [])

    def test_saved_custody_valid_invalid_and_transaction_phases(self):
        data = self.home / "data" / "task"
        data.mkdir(parents=True)
        bundle = data / "suspension.bundle"
        self.git("bundle", "create", str(bundle), "refs/heads/fm/task")
        identity = {"project": str(self.worktree), "kind": "ship", "mode": "direct-push",
                    "branch": "fm/task", "harness": "pi", "backend": "tmux", "spawn_gen": "g1"}
        manifest = {"schema": "fm-suspension.v1", "task": "task", "home": str(self.home),
                    "token": "saved1", "head": self.head, "branch": "fm/task", "project": str(self.worktree),
                    "bundle": str(bundle), "bundle_hash": self.git("hash-object", str(bundle)).strip(),
                    "common": self.git("rev-parse", "--path-format=absolute", "--git-common-dir").strip(),
                    "identity": identity, "old_record": {}}
        (data / "suspension.json").write_text(json.dumps(manifest))
        meta = "".join(k + "=" + value + "\n" for k, value in identity.items())
        (self.state / "task.meta").write_text(meta + "copy_state=released\nsuspend_token=saved1\n")
        valid = self.compare()
        self.assertEqual((valid["state"], valid["source"]), ("paused", "park"))
        bundle.write_bytes(b"corrupt bundle\n")
        invalid = self.compare()
        self.assertEqual((invalid["state"], invalid["source"]), ("blocked", "park"))
        for phase in ("release-prepared", "restore-prepared", "unknown-phase"):
            (self.state / "task.meta").write_text(meta + "copy_state=" + phase + "\n")
            self.assertIn("transaction needs reconciliation", self.compare()["detail"])

    def test_done_head_proof_accepted_blocked_and_ready_only(self):
        self.env["FM_FAKE_STATUS"] = ""
        self.status(b"done: ready in branch fm/task\n")
        accepted = self.compare()
        self.assertEqual(accepted["state"], "done")
        self.assertIn("landed on origin/main", accepted["detail"])
        self.git("commit", "-q", "--allow-empty", "-m", "unpreserved")
        blocked = self.compare()
        self.assertEqual(blocked["state"], "blocked")
        self.assertIn("unreachable outside the worker copy", blocked["detail"])
        self.git("update-ref", "refs/remotes/origin/fm/task", self.git("rev-parse", "HEAD").strip())
        ready = self.compare()
        self.assertEqual(ready["state"], "done")
        self.assertIn("not landed on origin's default branch", ready["detail"])

    def test_forge_providers_and_green_held_ci(self):
        self.env["FM_CREW_STATE_NO_FORGE"] = "0"
        self.fake("glab", "printf '{\"state\":\"%s\"}\\n' \"${FM_FAKE_GLAB_STATE:-opened}\"\n")
        self.fake("tea", '''if [ "${1:-} ${2:-}" = 'login list' ]; then
 printf '[{"name":"fixture","url":"https://git.example.org"}]\\n'; exit 0
fi
printf '{"state":"%s","merged":%s,"head":{"sha":"abc"}}\\n' "${FM_FAKE_TEA_STATE:-open}" "${FM_FAKE_TEA_MERGED:-false}"
''')
        self.fake("gerrit-axi", '''printf '{"ok":true,"changes":[{"change":%s,"status":"%s"}]}\\n' "${2:-1}" "${FM_FAKE_GERRIT_STATE:-NEW}"
''')
        providers = [
            ("https://github.com/o/r/pull/1", "FM_FAKE_PR_STATE", ("OPEN", "CLOSED", "UNKNOWN"), "FM_FAKE_PR_MERGED"),
            ("https://gitlab.example.org/g/sub/r/-/merge_requests/1", "FM_FAKE_GLAB_STATE", ("opened", "closed", "merged"), None),
            ("https://git.example.org/o/r/pulls/1", "FM_FAKE_TEA_STATE", ("open", "closed", "unknown"), "FM_FAKE_TEA_MERGED"),
            ("https://review.example.org/c/project/+/1", "FM_FAKE_GERRIT_STATE", ("NEW", "ABANDONED", "MERGED"), None),
        ]
        for url, variable, states, merged in providers:
            for state in states:
                with self.subTest(url=url, state=state):
                    self.env[variable] = state
                    if merged:
                        self.env[merged] = "false"
                    self.env["FM_FAKE_STATUS"] = self.run_record("completed", "passed", extra="pr: " + url + "\n")
                    self.compare()
            if merged:
                self.env[merged] = "true"
                self.assertIn("PR merged", self.compare()["detail"])
        url = "https://github.com/o/r/pull/1"
        self.env.update(FM_FAKE_PR_STATE="OPEN", FM_FAKE_PR_MERGED="false", FM_FAKE_CI_LOG="CI checks passed")
        self.env["FM_FAKE_STATUS"] = self.run_record("failed", "failed", extra="pr: " + url + "\nsteps[2]{step,status,findings,duration_ms}:\n  test,completed,0,1\n  ci,failed,0,1\n")
        held = self.compare()
        self.assertEqual(held["state"], "done")
        self.assertIn("PR held for merge (ci monitor ended)", held["detail"])
        self.env["FM_FAKE_PR_MERGED"] = "true"
        self.assertIn("PR merged (ci monitor ended)", self.compare()["detail"])
        self.env.update(FM_FAKE_PR_STATE="CLOSED", FM_FAKE_PR_MERGED="false")
        self.assertEqual(self.compare()["state"], "failed")

    def test_retirement_receipt_is_local_and_identity_bound(self):
        url = "https://github.com/o/r/pull/1"
        meta = self.state / "task.meta"
        meta.write_text(meta.read_text() + "pr=" + url + "\n")
        seed = '''. "$1/bin/fm-pr-lib.sh"
template="$1/bin/fm-pr-poll.sh"
fm_pr_poll_prepare "$2" task github "$3" github.com o/r 1 "$template" || exit
fm_pr_poll_publish_prepared || exit
fm_pr_poll_snapshot_capture "$2" task "$template" || exit
fm_pr_poll_retirement_publish "$2" task "$template" merged
'''
        seeded = subprocess.run(["bash", "-c", seed, "fixture", str(ROOT), str(self.state), url],
                                env=self.env, capture_output=True, timeout=20)
        self.assertEqual(seeded.returncode, 0, seeded.stderr)
        self.env["FM_FAKE_STATUS"] = self.run_record("completed", "passed", extra="pr: " + url + "\n")
        # Even with forge reads disabled the matching local receipt answers.
        self.assertIn("PR merged", self.compare()["detail"])
        self.env["FM_FAKE_STATUS"] = self.run_record("completed", "passed", extra="pr: https://github.com/o/other/pull/2\n")
        self.assertIn("forge read skipped", self.compare()["detail"])
