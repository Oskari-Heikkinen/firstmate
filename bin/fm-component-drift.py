#!/usr/bin/env python3
"""fm-component-drift.py - the engine behind bin/fm-component-drift.sh.

The shell script's header owns the behaviour, the state files and the exit
codes; this file only implements them. Drift itself is detected only by
bin/fm-component-map.sh drift, and a skill's metadata.owner is read with that
tool's own frontmatter reader, so neither rule has a second copy here.
"""

import argparse
import fcntl
import glob
import hashlib
import importlib.util
import json
import os
import re
import subprocess
import sys
import time

LEDGER_SCHEMA = "fm-component-drift-ledger/v1"
RESULT_SCHEMA = "fm-schedule-result/v1"
CLOSED = ("done", "gone")
REPO_MAP = os.path.join("docs", "component-map.json")
HOME_MAP = os.path.join("config", "component-map.json")


def one_line(text, n=300):
    return " ".join(str(text).split())[:n]


def utc(epoch):
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(epoch))


def atomic_text(path, text):
    tmp = "%s.tmp.%d" % (path, os.getpid())
    with open(tmp, "w", encoding="utf-8") as fh:
        fh.write(text)
    os.replace(tmp, path)


def load_map_tool(code_root):
    spec = importlib.util.spec_from_file_location(
        "fm_component_map", os.path.join(code_root, "bin", "fm-component-map.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def git_out(path, *args):
    try:
        p = subprocess.run(["git", "-C", path, *args], capture_output=True, text=True, timeout=60)
    except (OSError, subprocess.TimeoutExpired):
        return None
    return p.stdout.strip() if p.returncode == 0 else None


def existing_dir(path):
    probe = os.path.dirname(os.path.abspath(path))
    while not os.path.isdir(probe):
        parent = os.path.dirname(probe)
        if parent == probe:
            break
        probe = parent
    return probe


def repo_identity(top):
    url = git_out(top, "config", "--get", "remote.origin.url")
    if url:
        url = url.rstrip("/")
        return url[:-4] if url.endswith(".git") else url
    return os.path.realpath(top)


class Run:
    def __init__(self, args):
        self.home = args.home.rstrip("/")
        self.code_root = args.code_root
        self.now = args.now if args.now is not None else int(time.time())
        self.started = int(time.time())
        self.homes = self.read_homes(args.homes)
        self.sdir = os.path.join(self.home, "state", "component-drift")
        self.log_path = os.path.join(self.sdir, "log")
        self.tool = load_map_tool(self.code_root)
        self.failures = []
        self.carried = 0
        self.counts = {"maps": 0, "drifted": 0, "filed": 0, "open": 0}

    # ------------------------------------------------------------ plumbing

    def read_homes(self, path):
        homes = []
        try:
            with open(path, encoding="utf-8") as fh:
                lines = fh.read().splitlines()
        except OSError:
            lines = []
        for line in lines:
            parts = line.split("\t")
            if len(parts) == 3 and parts[0] and parts[1].startswith("/"):
                homes.append((parts[0], parts[1].rstrip("/"), parts[2] == "1"))
        return homes or [("main", self.home, False)]

    def log(self, text):
        line = "%s %s\n" % (utc(int(time.time())), one_line(text, 1000))
        with open(self.log_path, "a", encoding="utf-8") as fh:
            fh.write(line)

    def fail(self, text):
        self.failures.append(text)
        self.log("FAILED: " + text)

    def home_tool(self, home, name):
        own = os.path.join(home, "bin", name)
        if os.path.isfile(own) and os.access(own, os.X_OK):
            return own
        return os.path.join(self.code_root, "bin", name)

    def run_in(self, home, argv, timeout=60):
        env = dict(os.environ, FM_HOME=home)
        for k in ("FM_DATA_OVERRIDE", "FM_STATE_OVERRIDE", "FM_CONFIG_OVERRIDE", "TASKS_AXI_FILE"):
            env.pop(k, None)
        try:
            p = subprocess.run(argv, text=True, capture_output=True, env=env, cwd=home, timeout=timeout)
        except (OSError, subprocess.TimeoutExpired) as err:
            return 127, "", type(err).__name__
        return p.returncode, p.stdout, p.stderr

    def task_state(self, home, task):
        """queued|in_flight|...|done; 'gone' when not found; None when unreadable."""
        rc, out, err = self.run_in(home, [self.home_tool(home, "fm-tasks-axi.sh"), "show", task])
        if rc != 0:
            return "gone" if "NOT_FOUND" in (out + err) else None
        for line in out.splitlines():
            m = re.match(r"^\s*state:\s*(\S+)\s*$", line)
            if m:
                return m.group(1).strip('"')
        return None

    # ------------------------------------------------------------ targets

    def targets(self):
        """[(kind, path, home_id)]: one checkout per repository, then every home map."""
        repos, home_maps = {}, []
        for hid, hpath, remote in self.homes:
            if remote:
                self.log("skipped home %s: a remote home's files are not on this machine" % hid)
                continue
            if not os.path.isdir(hpath):
                self.fail("home %s not found at %s" % (hid, hpath))
                continue
            for cand in [hpath] + sorted(glob.glob(os.path.join(hpath, "projects", "*"))):
                if not os.path.isfile(os.path.join(cand, REPO_MAP)):
                    continue
                top = git_out(cand, "rev-parse", "--show-toplevel")
                if not top or os.path.realpath(top) != os.path.realpath(cand):
                    continue
                ident = repo_identity(cand)
                head = git_out(cand, "log", "-1", "--format=%ct", "HEAD") or "0"
                stamp = int(head) if head.isdigit() else 0
                if ident not in repos or stamp > repos[ident][0]:
                    repos[ident] = (stamp, cand, hid)
            hmap = os.path.join(hpath, HOME_MAP)
            if os.path.isfile(hmap):
                home_maps.append(("home-map", hmap, hid))
        out = []
        for ident, (_, path, hid) in sorted(repos.items()):
            self.log("checking %s in %s's checkout %s (newest HEAD among its checkouts)" % (ident, hid, path))
            out.append(("repo", path, hid))
        return out + home_maps

    # ------------------------------------------------------------ drift

    def skill_key(self, skill):
        """(identity, repo top or None): a skill in a repository is that repository plus its relative path."""
        top = git_out(existing_dir(skill), "rev-parse", "--show-toplevel")
        if top and os.path.realpath(skill).startswith(os.path.realpath(top) + "/"):
            rel = os.path.relpath(os.path.realpath(skill), os.path.realpath(top))
            return "%s:%s" % (repo_identity(top), rel), top
        return os.path.realpath(skill), None

    def norm_source(self, src, top):
        if top and os.path.realpath(src).startswith(os.path.realpath(top) + "/"):
            return os.path.relpath(os.path.realpath(src), os.path.realpath(top))
        return src

    def collect(self):
        """{skill identity: drift record}, plus the set of identities whose maps were all read."""
        found = {}
        for kind, path, hid in self.targets():
            self.counts["maps"] += 1
            rc, out, err = self.run_in(self.home, [os.path.join(self.code_root, "bin", "fm-component-map.sh"),
                                                    "drift", path], timeout=600)
            if rc == 0:
                self.log("%s %s: no drift" % (kind, path))
                continue
            if rc != 1:
                self.fail("drift could not check %s %s (exit %d): %s" % (kind, path, rc, one_line(err or out)))
                continue
            for line in out.splitlines():
                parts = line.split("\t")
                if len(parts) < 4 or parts[0] not in ("changed", "vanished", "unreadable"):
                    self.fail("drift printed a line this run cannot read for %s: %s" % (path, one_line(line)))
                    continue
                skill = parts[2]
                ident, top = self.skill_key(skill)
                rec = found.setdefault(ident, {"skill": skill, "name": self.skill_name(skill), "top": top,
                                               "ids": set(), "problems": set(), "seen_in": set(),
                                               "home_map_home": None})
                rec["ids"].update(parts[1].split(","))
                rec["seen_in"].add("%s %s (home %s)" % (kind, path, hid))
                if kind == "home-map" and rec["home_map_home"] is None:
                    rec["home_map_home"] = hid
                if parts[0] == "changed" and len(parts) == 6:
                    rec["problems"].add(("changed", self.norm_source(parts[3], top), parts[4], parts[5]))
                elif parts[0] == "vanished":
                    rec["problems"].add(("vanished", self.norm_source(parts[3], top)))
                else:
                    rec["problems"].add((parts[0], "\t".join(parts[3:])))
        return found

    def skill_name(self, skill):
        return os.path.basename(os.path.dirname(skill)) if os.path.basename(skill) == "SKILL.md" else os.path.basename(skill)

    @staticmethod
    def fingerprint(ident, problems):
        text = ident + "\n" + "\n".join("\t".join(p) for p in sorted(problems))
        return hashlib.sha256(text.encode("utf-8")).hexdigest()

    def owner(self, rec):
        """(home id, home path, why) for a drifted skill."""
        known = {hid: hpath for hid, hpath, remote in self.homes if not remote}
        named = None
        try:
            fm, _ = self.tool.read_skill(rec["skill"])
            meta = fm.get("metadata")
            if isinstance(meta, dict) and meta.get("owner") is not None:
                named = str(meta.get("owner"))
        except ValueError:
            pass
        if named is not None:
            if named in known:
                return named, known[named], "metadata.owner names %s" % named
            return "main", self.home, "metadata.owner names %r, which is no local home, so main routes it" % named
        if rec["home_map_home"] in known:
            hid = rec["home_map_home"]
            return hid, known[hid], "no metadata.owner; the home map in %s names this skill" % hid
        return "main", self.home, "no metadata.owner, so main routes it to the owner"

    # ------------------------------------------------------------ items

    def body(self, rec, owner_why, previous):
        lines = ["The component skill %s has drifted: a source it pins in metadata.sources changed, vanished or "
                 "could not be read." % rec["skill"],
                 "",
                 "Components: %s" % ", ".join(sorted(rec["ids"])),
                 "Found by: %s" % "; ".join(sorted(rec["seen_in"])),
                 "Routed here because %s." % owner_why,
                 "",
                 "Drift (bin/fm-component-map.sh drift):"]
        for p in sorted(rec["problems"]):
            if p[0] == "changed":
                lines.append("- changed: %s (pinned %s, now %s)" % (p[1], p[2], p[3]))
            else:
                lines.append("- %s: %s" % (p[0], p[1]))
        lines += ["",
                  "Update path (docs/component-map.md, Source pins): read each source's change, update the skill's "
                  "goal, refuse and review sections to match, pin the new sha256, and land the skill through its "
                  "repository's normal path with a non-author review.",
                  "A source change that contradicts the skill is a finding against the source's owner, not a silent "
                  "skill edit.",
                  "The daily drift run files no second item for this exact drift while this one is open; closing "
                  "it without re-pinning files a new item on the next run."]
        if previous:
            lines += ["", "This drift differs from the one in %s, which is still open; this item supersedes it." % previous]
        return "\n".join(lines) + "\n"

    def file_item(self, rec, ident, fp, entry):
        hid, hpath, why = self.owner(rec)
        previous = entry.get("task") if entry and entry.get("fingerprint") != fp else None
        if previous and self.task_state(entry["home_path"], previous) in CLOSED:
            previous = None
        slug = re.sub(r"[^a-z0-9-]+", "-", rec["name"].lower()).strip("-")[:40] or "skill"
        task = "drift-%s-%s-%s" % (slug, fp[:6], time.strftime("%Y%m%d%H%M", time.gmtime(self.now)))
        title = "Re-pin component skill %s: %d pinned source(s) drifted" % (rec["name"], len(rec["problems"]))
        body_path = os.path.join(self.sdir, ".item.body")
        atomic_text(body_path, self.body(rec, why, previous))
        rc, out, err = self.run_in(hpath, [self.home_tool(hpath, "fm-tasks-axi.sh"), "add", task, title,
                                           "--kind", "ship", "--body-file", body_path, "--json"])
        os.unlink(body_path)
        if rc != 0:
            self.carried += 1
            self.fail("could not file %s in %s for %s: %s; the next run retries" % (task, hid, ident,
                                                                                 one_line(err or out)))
            return entry
        self.counts["filed"] += 1
        self.log("filed %s in %s for %s (%s)" % (task, hid, ident, why))
        new = {"fingerprint": fp, "task": task, "home": hid, "home_path": hpath, "filed": utc(self.now),
               "skill": rec["skill"], "wake_pending": True}
        self.wake(new, ident)
        return new

    def wake(self, entry, ident):
        text = ("The component-skill drift run filed backlog task %s: the skill %s drifted from a source it pins. "
                "It is part of the captain-approved daily drift check; its body names the drift and the update path."
                % (entry["task"], entry["skill"]))
        rc, out, err = self.run_in(entry["home_path"], [self.home_tool(entry["home_path"], "fm-inbox.sh"), "note",
                                                        "--request-id", entry["task"], "--", text])
        if rc == 0:
            entry["wake_pending"] = False
            self.log("woke %s about %s" % (entry["home"], entry["task"]))
        else:
            self.carried += 1
            self.fail("could not wake %s about %s for %s: %s; the next run retries" % (
                entry["home"], entry["task"], ident, one_line(err or out)))

    # ------------------------------------------------------------ main

    def load_ledger(self):
        path = os.path.join(self.sdir, "ledger.json")
        try:
            with open(path, encoding="utf-8") as fh:
                data = json.load(fh)
        except FileNotFoundError:
            return {}
        if not isinstance(data, dict) or data.get("schema") != LEDGER_SCHEMA or not isinstance(data.get("skills"), dict):
            raise RuntimeError("ledger %s is not %s; move it aside to start fresh" % (path, LEDGER_SCHEMA))
        return data["skills"]

    def save_ledger(self, skills):
        atomic_text(os.path.join(self.sdir, "ledger.json"),
                    json.dumps({"schema": LEDGER_SCHEMA, "skills": skills}, indent=2, sort_keys=True) + "\n")

    def execute(self):
        ledger = self.load_ledger()
        self.log("run started for %d home(s)" % len(self.homes))
        found = self.collect()
        self.counts["drifted"] = len(found)
        incomplete = bool(self.failures)
        out = {}
        for ident in sorted(found):
            rec = found[ident]
            fp = self.fingerprint(ident, rec["problems"])
            entry = ledger.get(ident)
            if entry and entry.get("fingerprint") == fp:
                if entry.get("wake_pending"):
                    self.wake(entry, ident)
                state = self.task_state(entry["home_path"], entry["task"])
                if state is None:
                    self.fail("could not read the state of %s in %s; treated as open, nothing filed for %s" % (
                        entry["task"], entry["home"], ident))
                    out[ident] = entry
                    continue
                if state not in CLOSED:
                    self.counts["open"] += 1
                    self.log("unchanged drift of %s: %s in %s is still %s, nothing filed" % (
                        ident, entry["task"], entry["home"], state))
                    out[ident] = entry
                    continue
                self.log("unchanged drift of %s, but %s is %s: filing again" % (ident, entry["task"], state))
            new = self.file_item(rec, ident, fp, entry)
            if new:
                out[ident] = new
        for ident, entry in ledger.items():
            if ident in out:
                continue
            if incomplete:
                out[ident] = entry
                self.log("kept %s: a map could not be checked this run" % ident)
            else:
                self.log("%s no longer drifts; forgotten" % ident)
        self.save_ledger(out)
        summary = ("%d map(s) checked, %d drifted skill(s): %d filed, %d still open" % (
            self.counts["maps"], self.counts["drifted"], self.counts["filed"], self.counts["open"]))
        if self.failures:
            summary += "; %d failure(s): %s" % (len(self.failures), self.failures[0])
        self.log("run ended: " + summary)
        print(summary)
        return summary


def write_result(path, run, summary, failed):
    ended = int(time.time())
    lines = ["schema=%s" % RESULT_SCHEMA,
             "started=%s" % utc(run.started),
             "ended=%s" % utc(ended),
             "used_seconds=%d" % max(0, ended - run.started),
             "outcome=%s" % ("failed" if failed else "complete"),
             "cut_reason=none",
             "carried_over=%d" % run.carried,
             "note=%s" % one_line(summary, 500),
             "report=%s" % run.log_path]
    os.makedirs(os.path.dirname(path), exist_ok=True)
    atomic_text(path, "\n".join(lines) + "\n")


def main(argv):
    ap = argparse.ArgumentParser(prog="fm-component-drift.py")
    ap.add_argument("--home", required=True)
    ap.add_argument("--homes", required=True)
    ap.add_argument("--code-root", required=True)
    ap.add_argument("--result")
    ap.add_argument("--now", type=int)
    args = ap.parse_args(argv)
    run = Run(args)
    os.makedirs(run.sdir, exist_ok=True)
    lock = open(os.path.join(run.sdir, ".lock"), "w")
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        print("fm-component-drift: another run holds the lock; nothing done", file=sys.stderr)
        return 2
    try:
        summary = run.execute()
    except Exception as exc:  # noqa: BLE001 - any crash is "could not run", reported in the summary
        summary = "the run stopped: %s" % one_line(repr(exc))
        try:
            run.log("FAILED: " + summary)
        except OSError:
            pass
        print("fm-component-drift: " + summary, file=sys.stderr)
        if args.result:
            write_result(args.result, run, summary, True)
        return 2
    if args.result:
        write_result(args.result, run, summary, bool(run.failures))
    return 1 if run.failures else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
