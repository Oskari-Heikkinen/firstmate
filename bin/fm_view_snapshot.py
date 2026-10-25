"""Native local task-row composition; publication and cross-home owners stay shell.

A bounded captured inventory is disposable. Mutable row evidence is discarded on
metadata replacement; no snapshot, cursor, queue or home ledger is written here.
Only the existing passive endpoint adapter may observe an external backend.
"""
import os
import re

from fm_view_crew import Crew, result
from fm_view_engine import MAX_FILE, fields, read_file, require
from fm_view_status import at_epoch, note, verb

MAX_TASKS = 256
MAX_STATUS_BYTES = 64 * 1024 * 1024


class CapturedInputs:
    """One row's immutable local inputs, with fresh tool protection and barriers."""
    def __init__(self, inputs, task, meta, status):
        self.owner, self.task, self.meta, self.status = inputs, task, meta, status
        self.home, self.state = inputs.home, inputs.state

    def check(self):
        self.owner.check()

    def metadata(self, task):
        require(task == self.task, "foreign snapshot task")
        return self.owner.metadata(task)

    def fold(self, task, kind, vocabulary):
        require(task == self.task, "foreign snapshot task")
        protected, protect_all = self.owner.protection(task)
        return self.owner.status_index.fold(task, self.status["identity"] if self.status else ["missing"],
                                            self.status["bytes"] if self.status else b"", kind,
                                            vocabulary, protected, protect_all)


class Snapshot:
    def __init__(self, inputs, environment=None):
        self.inputs = inputs
        self.environment = dict(os.environ if environment is None else environment)

    def inventory(self):
        self.inputs.check()
        fd = self.inputs.open_state()
        try:
            names = sorted((name for name in os.listdir(fd) if name.endswith(".meta") and not name.startswith(".")),
                           key=lambda name: name[:-5])
            require(len(names) <= MAX_TASKS, "snapshot task bound exceeded")
            rows, total = [], 0
            for name in names:
                task = name[:-5]
                self.inputs.task_path(task, ".meta")
                meta = read_file(name, missing=True, dir_fd=fd)
                if meta is None:
                    continue
                total += len(meta["bytes"])
                require(total <= MAX_FILE, "snapshot metadata byte bound exceeded")
                rows.append({"task": task, "meta": meta})
        finally:
            os.close(fd)
        self.inputs.check()
        return rows

    def capture(self, rows):
        total = 0
        captured = []
        for selected in rows:
            task, meta = selected["task"], selected["meta"]
            status = self.inputs.state_read(task, ".status")
            total += len(status["bytes"]) if status else 0
            require(total <= MAX_STATUS_BYTES, "snapshot status byte bound exceeded")
            captured.append(dict(selected, status=status))
        self.inputs.check()
        return captured

    def current(self, row):
        current = self.inputs.metadata(row["task"])
        if current == row["meta"]:
            return True
        if current is not None:
            selected_gen = fields(row["meta"]["bytes"]).get("spawn_gen", "")
            current_gen = fields(current["bytes"]).get("spawn_gen", "")
            same_generation = (selected_gen == current_gen if selected_gen else
                               row["meta"]["bytes"] == current["bytes"])
            # Keep strict Crew/input attribution. Ordinary publication within a
            # legacy generation is not a reason to invent an unknown row: its
            # existing owner can recapture and compose the complete fallback.
            require(not same_generation, "same-generation metadata changed; use legacy snapshot")
        return False

    def compose(self, row, observed_at, epoch):
        self.inputs.check()
        task, meta = row["task"], fields(row["meta"]["bytes"])
        remote = meta.get("remote_host", "")
        status = row["status"]
        captured = CapturedInputs(self.inputs, task, row["meta"], status)
        crew = Crew(captured, task, self.environment, expected_generation=row["meta"])
        endpoint_exists, agent_alive = None, "not_checked"
        if remote:
            current = dict(result("unknown", "none", "remote endpoint liveness not collected by fleet snapshot"), raw="")
            agent_alive = "unknown"
        elif self.current(row):
            current = crew.read()
            packet = crew.packet("snapshot-endpoint", timeout=10, cwd=str(self.inputs.home))
            require(packet and len(packet) == 2 and packet[0] in ("null", "true", "false")
                    and packet[1] in ("not_checked", "unknown", "alive", "dead"),
                    "snapshot endpoint observation unavailable")
            endpoint_exists = {"null": None, "true": True, "false": False}[packet[0]]
            agent_alive = packet[1]
        else:
            current = dict(result("unknown", "none", "task generation changed during snapshot"), raw="")
            agent_alive = "unknown"
        # Only ordinary worker capacity performs path observations or row folds.
        report = os.path.isfile(self.inputs.home / "data" / task / "report.md")
        folded = captured.fold(task, meta.get("kind") or "ship", crew.vocabulary)
        return self.row(row, meta, status, folded, current, endpoint_exists, agent_alive,
                        report, observed_at, epoch)

    def row(self, row, meta, status, folded, current, endpoint_exists, agent_alive, report, observed_at, epoch):
        task = row["task"]
        kind = meta.get("kind") or "ship"
        remote = meta.get("remote_host", "")
        backend = (meta.get("remote_backend") or "unknown") if remote else (meta.get("backend") or "tmux")
        target = meta.get("remote_target", "") if remote else (
            meta.get("terminal") if backend == "orca" and meta.get("terminal") else meta.get("window", ""))
        data = status["bytes"].replace(b"\0", b"").decode("utf-8", "surrogateescape") if status else ""
        latest = next((line for line in reversed(data.split("\n")) if line.strip()), "")
        stamped = at_epoch(latest)
        age = lambda at: epoch - at if at is not None and at <= epoch else None
        opened = folded["open"]
        if kind != "secondmate" and ((current["source"] in ("run-step", "pane")
                and current["state"] not in ("parked", "blocked")) or current["state"] in ("done", "failed")):
            opened = []
        opened = [dict(item, age_seconds=age(item["opened_at_epoch"])) for item in opened]
        pr = meta.get("pr", "")
        pr_source = "meta"
        if not pr:
            match = re.search(r'https?://[^\s)\"]+/pull/[0-9]+', data)
            pr, pr_source = (match.group(), "status_event") if match else ("", "absent")
        home, worktree = meta.get("home", ""), meta.get("worktree", "")
        base = str(self.inputs.home)
        path = lambda name, present: {"path": name, "present": present}
        current = {key: current[key] for key in ("state", "source", "detail", "raw")}
        return {
            "id": task, "kind": kind, "harness": meta.get("harness", ""), "mode": meta.get("mode", ""),
            "yolo": meta.get("yolo", ""), "branch": meta.get("branch") or None, "project": meta.get("project", ""),
            "spawn_gen": meta.get("spawn_gen") or None, "backend": backend,
            "remote": {"host": remote, "root": meta.get("remote_root", "")} if remote else None,
            "paths": {
                "meta": path(base + "/state/" + task + ".meta", True),
                "status_log": dict(path(base + "/state/" + task + ".status", status is not None),
                    kind="event_history", last_event={"state": verb(latest), "note": note(latest), "raw": latest,
                                                       "age_seconds": age(stamped)}),
                "worktree": path(worktree or None, bool(worktree) and os.path.exists(worktree)),
                "home": path(home or None, None if home and remote else bool(home) and os.path.exists(home)),
                "report": path(base + "/data/" + task + "/report.md", report)},
            "secondmate_projects": [value.strip() for value in meta.get("projects", "").split(",") if value.strip()],
            "current_state": dict(current, observed_at=observed_at, freshness="fresh"),
            "endpoint": {"target": target or None, "exists": endpoint_exists, "agent_alive": agent_alive,
                "status": "absent" if endpoint_exists is False else agent_alive if agent_alive in ("alive", "dead") else "unknown",
                "observed_at": observed_at, "freshness": "fresh"},
            "pr": {"url": pr or None, "source": pr_source, "head": meta.get("pr_head") or None},
            "hints": {"pending_decision": any(item["verb"] == "needs-decision" for item in opened),
                "blocked_event": any(item["verb"] == "blocked" for item in opened), "open_decisions": opened,
                "scout_report_present": report, "last_event_text": latest},
            "actions": ({"send": "bin/fm-send.sh fm-" + task + " '<request>'",
                "watch": "read status/doc return channel; do not routinely fm-peek a secondmate for answers",
                "return_channel_note": "Secondmate answers come back through status/doc paths after a marked fm-send request."}
                if kind == "secondmate" else {"watch": "bin/fm-peek.sh fm-" + task,
                    "steer": "bin/fm-send.sh fm-" + task + " '<instruction>'", "return_channel_note": None})}

    def finish(self, captures, rows, observed_at, epoch):
        # Bracket ALL evidence, including folds/report/endpoint, with the selected
        # metadata identity. Replacements never inherit the predecessor's facts.
        staged = []
        for index, captured in enumerate(captures):
            status = captured["status"]
            if not self.current(captured):
                status = None
                rows[index] = self.row(captured, fields(captured["meta"]["bytes"]), None, {"open": []},
                    dict(result("unknown", "none", "task generation changed during snapshot"), raw=""), None, "unknown", False,
                    observed_at, epoch)
            # The legacy cross-home collector consumes these SAME captured
            # inputs, not a second live read or an invented missing file. Only
            # its invoking client writes disposable private transport files.
            staged.append({"task": captured["task"],
                "meta": captured["meta"]["bytes"].decode("utf-8", "surrogateescape"),
                "status": status["bytes"].decode("utf-8", "surrogateescape") if status else None,
                "status_mtime_ns": status["mtime_ns"] if status else None})
        self.inputs.check()
        return {"tasks": rows, "captures": staged}
