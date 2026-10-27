"""Native fresh crew-state reader and captured-record classifier (Python 3.9+).

No mutation or acknowledgement APIs. Passive backend/forge/custody observations
remain in their existing owners behind the fixed fm-view-adapter.sh interface.
Unsupported integration surfaces refuse so the compatibility owner can choose
legacy, never substitute a status tail for a fresh external observation.
"""
import os
from pathlib import Path
import re
import shutil
import time

from fm_view_engine import fields
from fm_view_process import run
from fm_view_runs import Run, ci_checks, head_matches, ledger_status, select_run, status_class
from fm_view_status import Vocabulary, note, verb

SEP = " · "
_UNSET = object()


class LegacyRequired(ValueError):
    pass


def result(state, source, detail=""):
    raw = "state: " + state + SEP + "source: " + source
    if detail:
        raw += SEP + detail
    return {"state": state, "source": source, "detail": detail, "raw": raw}


class PassiveGit:
    def __init__(self, collector):
        self.collector = collector
        self.memo = {}

    def observation(self, *args):
        # Git objects and graph answers keyed by complete SHAs are immutable;
        # mutable refs are sampled only for this one fresh request, never later.
        if args not in self.memo:
            self.memo[args] = self.collector.command("git", ("git", "-C", self.collector.worktree, *args), 5)
        return self.memo[args]

    def __call__(self, *args):
        observation = self.observation(*args)
        return observation.text if observation.status == 0 else ""

    def success(self, *args):
        return self.observation(*args).status == 0


class Crew:
    def __init__(self, inputs, task, env=None, expected_generation=_UNSET):
        self.inputs, self.task = inputs, task
        self.env = dict(os.environ if env is None else env)
        self.expected_generation = expected_generation
        self.meta_capture = inputs.metadata(task)
        self.meta = fields(self.meta_capture["bytes"]) if self.meta_capture else {}
        self.kind = self.meta.get("kind") or "ship"
        self.worktree = self.meta.get("worktree", "")
        self.git = PassiveGit(self)
        self.observations = []
        self.daemon_answer = ""
        self.nm_timeout = self.positive("FM_CREW_STATE_NM_TIMEOUT", 10, zero=True)
        self.runs_limit = self.positive("FM_CREW_STATE_RUNS_LIMIT", 200, zero=True)
        self.started_ns = time.monotonic_ns()
        self.home = str(inputs.home)
        self.env.update(FM_HOME=self.home, FM_STATE_OVERRIDE=str(inputs.state))
        self.script = Path(__file__).resolve().parent / "fm-view-adapter.sh"
        self.vocabulary = Vocabulary(
            paused=self.env.get("FM_CLASSIFY_PAUSED_VERB") or "paused",
            resolved=self.env.get("FM_CLASSIFY_RESOLVE_VERB") or "resolved",
            held=self.env.get("FM_CLASSIFY_CAPTAIN_HELD_VERB") or "captain-held",
            reserved=tuple((self.env.get("FM_CLASSIFY_RESERVED_KEY_PREFIXES") or "pending-reply- handoff-pickup- handoff-tj-").split()))
        self.log = ""
        self.latest = ""
        self.selected = ""
        self.dead_daemon = ""
        self.source = "full"
        self.coarse = ""
        self.run = Run("")

    def positive(self, name, default, zero=False):
        value = self.env.get(name, str(default))
        if not re.fullmatch(r"[0-9]+", value):
            return default
        value = int(value)
        return value if zero or value > 0 else default

    def command(self, adapter, argv, timeout, cwd=None):
        # Legacy accepts 0 as a no-timeout CLI bound; the native service cannot
        # admit an unbounded adapter. Explicit legacy fallback keeps that setting.
        if not 0 < timeout <= 120:
            raise LegacyRequired("passive adapter bound unsupported; use legacy")
        observation = run(list(argv), cwd or self.worktree or self.home, timeout, self.env)
        self.observations.append((adapter, self.meta.get("spawn_gen", ""), observation))
        return observation

    def nm(self, *args):
        return self.command("no-mistakes:" + "-".join(args[:2]), ("no-mistakes", *args), self.nm_timeout)

    def packet(self, operation, *args, timeout=5, cwd=None):
        observation = self.command(operation, ("bash", str(self.script), operation, self.task, *args), timeout, cwd=cwd)
        if observation.status == 3:
            raise LegacyRequired("passive " + operation + " integration unsupported; use legacy")
        if observation.problem or observation.status:
            return None
        if not observation.stdout.endswith(b"\0"):
            return None
        return [value.decode("utf-8", "surrogateescape") for value in observation.stdout[:-1].split(b"\0")]

    def daemon(self):
        if not self.daemon_answer:
            observation = self.nm("daemon", "status")
            rc = observation.status
            running = re.search(r"(^|\s)daemon running(\s|$)", observation.text)
            self.daemon_answer = "up" if rc == 0 and running else "unanswered" if rc == 124 else "down"
        return self.daemon_answer

    def ledger(self, expected=""):
        return ledger_status(self.git, self.branch, self.nm("runs", "--limit", str(self.runs_limit)).text, expected)

    def bind(self):
        return (head_matches(self.git, self.run.field("head")) or self.run.pipeline_owned
                or (self.run.executing and self.daemon() != "down"))

    def choose_run(self):
        """Return an early unknown result or None; set attributed evidence only."""
        self.have_run = False
        if self.kind != "ship" or not self.branch or not shutil.which("no-mistakes", path=self.env.get("PATH")):
            return None
        self.run = Run(self.nm("axi", "status").text)
        if any(line.startswith("error: ") and line[7:].strip().strip('"') == "repo not initialized (run 'no-mistakes init' first)"
               for line in self.run.lines):
            self.run = Run("")
        if not self.run.text:
            return None
        # The current legacy owner treats this addressed CLI answer as absent
        # without consulting a capped overview or the coarse fallback ledger.
        if self.run.field("current_branch") == self.branch and self.run.field("runs_on_current_branch") == "0":
            return None
        overview = self.nm("axi")
        if not overview.text:
            return result("unknown", "run-step", "run inventory unavailable; run id: " + self.run.field("id"))
        nm_home = self.env.get("NM_HOME") or os.path.expanduser("~/.no-mistakes")
        database = Path(nm_home) / "state.sqlite"
        if not database.is_absolute():
            database = Path(self.worktree) / database
        choice = select_run(self.branch, overview.text, database, min(30, self.nm_timeout))
        if overview.status:
            return result("unknown", "run-step", "run inventory unreadable; run ids: " + self.run.field("id") + ", " + choice.rsplit("|", 1)[-1])
        if choice.startswith("unknown|"):
            known = self.run.field("id") if self.run.field("branch") == self.branch else ""
            return result("unknown", "run-step", choice.partition("|")[2] + ("; last reported run id: " + known if known else ""))
        if choice.startswith("selected|"):
            _, selected, selected_status, names = choice.split("|", 3)
            observation = self.nm("axi", "status", "--run", selected)
            self.run = Run(observation.text)
            if observation.status:
                return result("unknown", "run-step", "selected run unreadable; run ids: " + names)
            if self.run.field("id") != selected or self.run.field("branch") != self.branch:
                return result("unknown", "run-step", "selected run unavailable or mismatched; run ids: " + names)
            if self.run.field("status") not in ("pending", "running", "fixing", "ci", "awaiting_approval", "fix_review", "completed", "failed", "cancelled"):
                return result("unknown", "run-step", "selected run status unverified; run ids: " + names)
            if status_class(selected_status) != ("live" if self.run.active else "terminal"):
                return result("unknown", "run-step", "selected run status disagrees with inventory; run ids: " + names)
            if self.bind():
                self.have_run = True
            elif not self.git("rev-parse", "--verify", "--quiet", self.run.field("head") + "^{commit}"):
                if self.run.active and self.ledger(self.run.field("head")) == "running":
                    self.have_run = True
                    if not self.run.parked and self.daemon() == "down":
                        self.dead_daemon = "no-mistakes daemon unreachable; last run record " + self.run.field("status") + " - unverified"
                else:
                    return result("unknown", "run-step", "selected run code identity unverified; run ids: " + names)
            self.selected = selected
        if not self.have_run and not self.selected:
            if self.run.field("branch") and self.run.field("branch") == self.branch and self.bind():
                self.have_run = True
                status = self.ledger()
                if self.run.active and status_class(status) == "terminal":
                    return result("unknown", "run-step", "run records disagree; run ids: " + self.run.field("id") + ", competing identity unavailable")
                if not self.run.active:
                    if status_class(status) == "live":
                        return result("unknown", "run-step", "replacement run identity unavailable; run ids: " + self.run.field("id") + ", replacement unavailable")
                    if status and status not in (self.run.field("status"), self.run.field("outcome")):
                        self.coarse, self.source = status, "coarse"
            else:
                self.coarse = self.ledger()
                if self.coarse:
                    self.have_run = True
                    if self.run.field("branch") != self.branch:
                        self.source = "coarse"
        return None

    def forge(self):
        packet = self.packet("forge", self.run.field("pr"), timeout=5)
        return packet[0] if packet else "run passed: PR state unknown (unreadable)"

    def ci(self):
        run_id = self.run.field("id")
        return ci_checks(self.nm("axi", "logs", "--step", "ci", "--run", run_id, "--full").text) if run_id else "unknown"

    def green_held(self):
        if not self.run.only_ci_failed() or self.ci() != "green":
            return None
        disposition = self.forge()
        if disposition == "run passed: PR open":
            detail = "checks green: PR held for merge (ci monitor ended)"
        elif disposition == "run passed: PR merged":
            detail = "checks green: PR merged (ci monitor ended)"
        else:
            return None
        return detail + (": " + self.run.field("pr") if self.run.field("pr") else "")

    def ship_done(self, extra=""):
        packet = self.packet("done-proof", self.log, timeout=15)
        if not packet or len(packet) != 2:
            return result("unknown", "status-log", "named head proof unavailable")
        if packet[0] != "accepted":
            return result("blocked", "status-log", packet[1])
        details = [note(self.log), extra, packet[1]]
        return result("done", "status-log", SEP.join(value for value in details if value))

    def run_state(self):
        state, detail, step, ci, status = "working", "", "", "", ""
        if self.dead_daemon:
            state, detail = "unknown", self.dead_daemon
        elif self.source == "coarse":
            if self.coarse == "running":
                state, detail = "working", "validating (background run)"
            elif self.coarse == "completed":
                state, detail = "done", "run completed"
            elif self.coarse == "failed":
                state, detail = ("unknown", "no-mistakes daemon unreachable; last ledger record failed - unverified") if self.daemon() != "up" else ("failed", "run failed")
            elif self.coarse == "cancelled":
                state, detail = "unknown", "run cancelled: no verdict"
            else:
                state, detail = "unknown", "runs list status: " + self.coarse
        else:
            status, outcome = self.run.field("status"), self.run.field("outcome")
            if outcome:
                if outcome in ("passed", "passed-with-override", "passed-with-skips"):
                    state, detail = "done", self.forge()
                    if outcome == "passed-with-skips":
                        detail += " (publication/CI verification skipped)"
                elif outcome == "checks-passed":
                    state, detail = "done", "checks green: PR ready for review"
                elif outcome in ("failed", "cancelled"):
                    held = self.green_held()
                    state, detail = ("done", held) if held else (("failed", "run failed") if outcome == "failed" else ("unknown", "run cancelled: no verdict"))
                else:
                    state, detail = "unknown", "outcome: " + outcome
            elif self.run.parked:
                has_gate = any(re.match(r"^\s*gate:", line) for line in self.run.lines)
                gate = (self.run.gate_line_name() if has_gate else self.run.gate_name()) or status or "gate"
                state, detail = "parked", "parked at " + gate
                count = self.run.findings_count()
                if count:
                    detail += ": " + count + " finding(s)"
                if self.run.awaits_human():
                    detail += SEP + "ask-user: authority decision"
            else:
                if status == "ci":
                    state, detail = "working", "ci running"
                elif status in ("running", "fixing"):
                    state, detail = "working", "validating (" + status + ")"
                elif status == "completed":
                    state, detail = "done", "run completed"
                elif status in ("failed", "cancelled"):
                    held = self.green_held()
                    state, detail = ("done", held) if held else (("failed", "run failed") if status == "failed" else ("unknown", "run cancelled: no verdict"))
                else:
                    detail = "run active" + (" (" + status + ")" if status else "")
                if state == "working":
                    step = self.run.ci_step()
                    if step == "running":
                        ci = self.ci()
                        if ci == "green":
                            state, detail = "done", "checks green: PR ready for review (still monitoring for merge/close)"
                            if self.run.field("pr"):
                                detail += ": " + self.run.field("pr")
                        elif ci == "no-checks":
                            detail = "no CI checks reported (or repository declares no CI): nothing has verified the PR (still monitoring for merge/close)"
                    elif step == "fixing":
                        ci = "not-ready"
        logverb = verb(self.log)
        if state == "working" and logverb == "done" and "PR" in note(self.log) and "checks green" in note(self.log):
            if self.source == "coarse":
                return self.ship_done("run still monitoring PR")
            step = step or self.run.ci_step()
            if status == "fixing" or step == "fixing":
                ci = "not-ready"
            elif step == "running" and not ci:
                ci = self.ci()
            if ci not in ("not-ready", "no-checks"):
                return self.ship_done("run still monitoring PR")
        if logverb in ("needs-decision", "blocked"):
            latest = self.latest.lower()
            socket_down = (any(word in latest for word in ("daemon", "no-mistakes"))
                           and any(word in latest for word in ("connection refused", "connections refused", "socket refused connection",
                                                              "socket refuses connection", "socket refusing connection", "socket missing",
                                                              "socket is missing", "missing socket")))
            if logverb == "blocked" and verb(self.latest) == "blocked" and socket_down:
                return result("blocked", "status-log", note(self.latest) + SEP + "daemon socket down despite attributed run record")
            if self.dead_daemon:
                return result("parked" if logverb == "needs-decision" else "blocked", "status-log",
                              note(self.log) + SEP + self.dead_daemon + (SEP + "run: " + self.selected if self.selected else ""))
            if state != "parked":
                if state == "working":
                    claims_transport = any(word in self.log.lower() for word in ("daemon", "timeout", "timed out", "unreachab"))
                    if logverb == "blocked" and claims_transport and status in ("running", "fixing") and self.run.activity_recent():
                        detail += SEP + "status-log superseded: run alive, not a daemon failure (steer reattach)"
                    else:
                        detail += SEP + "status-log superseded by active run"
                else:
                    detail += SEP + "status-log superseded (run " + state + ")"
        if self.selected:
            detail += SEP + "run: " + self.selected
        return result(state, "run-step", detail)

    def fallback(self):
        packet = self.packet("backend", timeout=15)
        if packet == ["no-target"]:
            return result("unknown", "none", "no backend target recorded")
        if not packet or len(packet) != 3:
            return result("unknown", "none", "backend observation unavailable")
        target, agent, busy = packet
        backend = self.meta.get("backend") or "tmux"
        if agent == "missing":
            return result("unknown", "none", "backend target gone: " + target)
        if agent == "dead":
            return result("unknown", "none", "backend target gone: " + target + " (agent gone, pane shell remains)")
        if agent != "alive":
            return result("unknown", "none", "backend unreachable (" + backend + " endpoint state: " + agent + ")")
        if self.kind != "secondmate":
            word, _, source = busy.partition(" ")
            if word == "busy":
                return result("working", "pane", "harness busy (" + source + ")")
            if word != "idle":
                return result("unknown", "pane", "harness state unavailable (" + busy + ")")
        if verb(self.log) == "done":
            return self.ship_done()
        state = {"working": "working", "needs-decision": "parked", "blocked": "blocked", self.vocabulary.paused: "paused", "failed": "failed"}.get(verb(self.log))
        return result(state, "status-log", note(self.log)) if state else result("unknown", "none", "no current-state source available")

    def read(self):
        self.inputs.check()
        if self.env.get("FM_CAPTAIN_RE"):
            raise LegacyRequired("custom ERE classification remains with legacy")
        if self.worktree and not os.path.isabs(self.worktree):
            raise LegacyRequired("relative worktree spelling remains with legacy")
        if self.expected_generation is not _UNSET and self.meta_capture != self.expected_generation:
            return result("unknown", "none", "task generation changed before observation")
        if not self.meta_capture:
            return result("unknown", "none", "no metadata for " + self.task)
        if (not self.env.get("NM_HOME") and self.kind == "ship"
                and os.path.lexists(Path(self.env.get("FM_CONFIG_OVERRIDE") or str(self.inputs.home / "config")) / "nm-home-resolver")):
            # The resolver can select a different daemon AND SQLite inventory.
            # Keep that external policy with its legacy owner, not an ambient
            # native read of another no-mistakes home.
            raise LegacyRequired("configured no-mistakes home resolver requires legacy")
        copy_state = self.meta.get("copy_state", "")
        if copy_state not in ("", "retained"):
            if copy_state == "released":
                packet = self.packet("saved-custody", timeout=15)
                answer = result("paused", "park", "waiting; no worker or copy reserved") if packet == ["valid"] else result("blocked", "park", "saved branch/bundle custody does not validate")
            else:
                answer = result("blocked", "park", "copy release/restore transaction needs reconciliation")
        elif self.meta.get("remote_host"):
            raise LegacyRequired("remote endpoint observation remains with legacy owner")
        elif not self.worktree or not os.path.isdir(self.worktree):
            answer = result("unknown", "none", "worktree gone (torn down?)")
        else:
            folded = self.inputs.fold(self.task, self.kind, self.vocabulary)
            self.log, self.latest = folded["current"], folded["latest"]
            self.branch = self.git("symbolic-ref", "--quiet", "--short", "HEAD")
            starting_head = self.git("rev-parse", "HEAD")
            answer = self.choose_run()
            if answer is None:
                answer = self.run_state() if self.have_run else self.fallback()
            final_head = self.command("git-head-barrier", ("git", "-C", self.worktree, "rev-parse", "HEAD"), 5)
            final_branch = self.command("git-branch-barrier", ("git", "-C", self.worktree, "symbolic-ref", "--quiet", "--short", "HEAD"), 5)
            if starting_head != (final_head.text if final_head.status == 0 else "") or self.branch != (final_branch.text if final_branch.status == 0 else ""):
                answer = result("unknown", "none", "code identity changed during observation")
        if self.inputs.metadata(self.task) != self.meta_capture:
            return result("unknown", "none", "task generation changed during observation")
        self.inputs.check()
        answer["observation"] = {"task": self.task, "spawn_gen": self.meta.get("spawn_gen", ""),
                                 "meta_sha256": self.meta_capture["sha256"], "started_ns": self.started_ns,
                                 "finished_ns": time.monotonic_ns(),
                                 "sources": [{"adapter": adapter, "spawn_gen": generation,
                                              "argv": list(observation.argv), "started_ns": observation.started_ns,
                                              "finished_ns": observation.finished_ns, "status": observation.status,
                                              "problem": observation.problem}
                                             for adapter, generation, observation in self.observations]}
        return answer
