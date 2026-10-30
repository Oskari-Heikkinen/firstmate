#!/usr/bin/env python3
"""fm-handoff-actors.py - the install check and the undeclared-actor source.

Usage:
  fm-handoff-actors.py check     --home DIR [--state DIR] [--root DIR] ACTOR
  fm-handoff-actors.py declare   --home DIR [--state DIR] --none --reason TEXT ACTOR
  fm-handoff-actors.py undeclare --home DIR [--state DIR] ACTOR
  fm-handoff-actors.py list      --home DIR [--state DIR] [--root DIR]

docs/handoff-coverage.md owns the rules ("Installed tools"): which homes'
fragments and declarations cover an actor, the handoff-actors/v1 declaration
format, grandfathering, and the inventory format list prints. This file owns
how one call applies them. An ACTOR is <kind>:<name>, such as
fm-check:disk-room or systemd-timer:tj-sched.timer.

check      decides whether ACTOR may be installed in the home and prints one
           line "<verdict><TAB><actor><TAB><why>". Verdicts: declared (a stage
           of a fragment this home sees lists it), none (declared as reading
           or writing no handoff), grandfathered (installed before this check,
           or a Firstmate built-in listed in BUILTIN below), refused, or
           unknown (not covered while a fragment, declaration or listing was
           unreadable). An installer that gets anything but exit 0 must not
           install.
declare    records ACTOR as reading or writing no handoff in this home's
           state/handoff-actors/declared.json (idempotent; a new reason
           replaces the old one). Only --none is accepted: a tool that does
           read or write handoff records is declared in its stage's actors.
undeclare  removes ACTOR's declaration from declared.json.
list       prints this home's actor inventory (handoff-actor-inventory/v1,
           JSON): every registered custom check, and in the machine's anchor
           home every active user or transient systemd timer and service, each
           with its state; undeclared rows are what undeclared-actor alarms.

--state defaults to DIR/state (bin/fm-check-register.sh passes its
FM_STATE_OVERRIDE). --root DIR is the drill root fm-handoff-watch uses: every
folder under it named like a home id is a home, the home named main is the
machine anchor, and nothing else is read. FM_HANDOFF_ACTORS_SYSTEMCTL names the
systemctl to run (default systemctl); it is only ever run read-only.

Every check verdict, declaration change, grandfather snapshot and change in
the undeclared set is appended to <state>/handoff-actors/log.

Exit: 0 allowed (check), written (declare, undeclare), or every actor covered
(list); 1 refused, or list found an undeclared actor; 2 usage, or --home is
not a firstmate home (a missing or empty folder, or no state folder), refused
before anything is written; 3 a fragment, declaration, unit listing or
TriggeredBy could not be read, so nothing is decided (an installer refuses;
list still prints what it could read).
"""

import argparse
import datetime
import fcntl
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import fm_handoff_registry as registry  # noqa: E402
from fm_receipt_io import atomic  # noqa: E402

VALIDATE = registry.validator()

HERE = Path(__file__).resolve().parent
SCHEMAS = HERE.parent / "docs" / "handoff-coverage"
# Firstmate's own installed tools, each armed or installed by its own command
# (the fm-check-register.sh callers and the bin/systemd units). They are
# grandfathered here, in code, so a copy of bin/ without docs/ still arms them.
BUILTIN_SINCE = "2026-10-21T00:00:00Z"
BUILTIN_REASON = ("Firstmate built-in, installed by its own arm or install command; "
                  "grandfathered until firstmate's own handoffs are registered")
BUILTIN = [f"fm-check:{cid}" for cid in (
    "accounts", "claude-update", "contributions", "disk-room", "handoff-watch", "loop-alerts", "mail",
    "mem-guard", "startup-growth", "tool-updates")] + [f"systemd-timer:{unit}" for unit in (
        "claude-update.timer", "fm-away-watch-*", "fm-board.timer", "fm-schedule.timer", "fm-storage.timer",
        "lattice-data-gate-report.timer")]
FORMAT = "handoff-actors/v1"
INVENTORY = "handoff-actor-inventory/v1"
CACHE = "fm-handoff-actors-cache/v1"
OK, REFUSED, USAGE, UNREADABLE = 0, 1, 2, 3
ACTOR_RE = re.compile(r"^(systemd-timer|systemd-service|fm-check|cron|process):[^\s*]{1,200}$")
UNIT_KINDS = {".timer": "systemd-timer", ".service": "systemd-service"}
SYSTEMCTL_TIMEOUT = 10


def unit_blocks(shown):
    """The property maps of systemctl show output, one per unit."""
    return [dict(line.split("=", 1) for line in block.splitlines() if "=" in line)
            for block in shown.split("\n\n")]


def timers_of(props):
    """The timer actors in one unit's TriggeredBy; a path or socket trigger is not a timer."""
    return [f"systemd-timer:{u}" for u in props.get("TriggeredBy", "").split() if u.endswith(".timer")]


def now():
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def matches(pattern, actor):
    """An entry ending in * declares a family by prefix, as codes do."""
    return actor.startswith(pattern[:-1]) if pattern.endswith("*") else actor == pattern


def code_signature():
    """What parsed results depend on besides the files themselves: this tool and its schemas."""
    parts = []
    for path in (Path(__file__).resolve(), HERE / "fm_handoff_registry.py", HERE / "fm-handoff-validate.py",
                 SCHEMAS / "handoff-registry-v1.schema.json", SCHEMAS / "handoff-actors-v1.schema.json"):
        try:
            st = os.stat(path)
            parts.append(f"{st.st_size}:{st.st_mtime_ns}")
        except OSError:
            parts.append("-")
    return "/".join(parts)


def machine_scope(actor):
    return not actor.startswith("fm-check:")


class Home:
    """What one call can see from one home: fragments, declarations, snapshots."""

    def __init__(self, home, state=None, root=None):
        self.home = Path(home).resolve()
        self.state = Path(state).resolve() if state else self.home / "state"
        self.root = root
        self.problems = []
        self.home_problems = []
        self.validate = VALIDATE
        self._units = False
        self._checks = False
        self.triggered_by = {}   # service actor -> the timer actors systemd names in its TriggeredBy
        self.schemas = {}
        try:
            self.self_id, self.homes = registry.discover(self.home, root)
        except (OSError, ValueError) as exc:
            self.problem(str(self.home), f"cannot find the homes this one sees ({exc})")
            self.self_id, self.homes = registry.home_id(self.home) or "main", {}
        self.homes = dict(self.homes)
        self.homes.setdefault(self.self_id, self.home)
        if root is not None:
            self.anchor = self.self_id == "main"
        else:
            self.anchor = registry.local_parent(self.home) is None
        self.cache_path = self.state / "handoff-actors" / ".cache.json"
        self.code = code_signature()
        self.cache = self.read_cache()
        self.new_cache = {"format": CACHE, "code": self.code, "files": {}, "units": self.cache.get("units")}
        self.stage_actors = []   # (actor, owner home, protocol/stage, fragment path)
        self.declarations = []   # (entry, declaring home, path)
        self.load()

    def problem(self, subject, what, units=False):
        """units marks a problem that can hide only systemd actors, never a custom check."""
        self.problems.append({"subject": subject, "what": what})
        if not units:
            self.home_problems.append(self.problems[-1])

    # ---------- reading, skipping unchanged files by signature ----------

    def read_cache(self):
        try:
            doc = json.loads(self.cache_path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            return {}
        if not isinstance(doc, dict) or doc.get("format") != CACHE or doc.get("code") != self.code:
            return {}  # a changed tool or schema reparses everything
        return doc

    def cached(self, path, kind, parse):
        """parse(path) -> (value, problem), reused while the file's signature holds."""
        try:
            st = os.stat(path)
        except OSError as exc:
            return None, f"cannot be read ({exc.strerror or exc})"
        sig = f"{kind}:{st.st_dev}:{st.st_ino}:{st.st_size}:{st.st_mtime_ns}"
        old = self.cache.get("files", {}).get(str(path))
        if isinstance(old, dict) and old.get("sig") == sig:
            value, problem = old.get("value"), old.get("problem")
        else:
            value, problem = parse(path)
        self.new_cache["files"][str(path)] = {"sig": sig, "value": value, "problem": problem}
        return value, problem

    def schema(self, name):
        """The named schema, loaded on first use, or one sentence saying why it cannot be."""
        if name not in self.schemas:
            try:
                self.schemas[name] = self.validate.Schema(str(SCHEMAS / name))
            except (self.validate.Unreadable, OSError, ValueError) as exc:
                self.schemas[name] = f"cannot be checked: schema {SCHEMAS / name} is unusable ({exc})"
        return self.schemas[name]

    def parse_fragment(self, path):
        schema = self.schema("handoff-registry-v1.schema.json")
        if isinstance(schema, str):
            return None, schema
        doc, problem = registry.check_fragment(self.validate, schema, path)
        if doc is None:
            return None, problem
        out = []
        for protocol in doc.get("protocols", []):
            for stage in protocol.get("stages", []):
                for actor in stage.get("actors", []):
                    out.append([actor, stage["owner"], f"{protocol['id']}/{stage['name']}"])
        return out, None

    def parse_declarations(self, path):
        try:
            doc, bad = self.validate.load_json(str(path))
        except self.validate.Unreadable as exc:
            return None, f"cannot be read ({exc})"
        if bad:
            return None, bad
        if isinstance(doc, dict) and doc.get("format") != FORMAT:
            return None, f"has unknown format {doc.get('format')!r}"
        schema = self.schema("handoff-actors-v1.schema.json")
        if isinstance(schema, str):
            return None, schema
        errors = schema.errors(doc)
        if errors:
            where, what = errors[0]
            return None, f"is invalid at {where}: {what}"
        return doc["actors"], None

    def load(self):
        for hid, hpath in sorted(self.homes.items()):
            try:
                paths = registry.fragment_files(hpath)
            except OSError as exc:
                self.problem(f"{hpath}/state/handoff-registry", f"cannot be listed ({exc.strerror or exc})")
                paths = []
            for path in paths:
                rows, problem = self.cached(path, "fragment", self.parse_fragment)
                if problem:
                    self.problem(str(path), f"fragment {problem}")
                for actor, owner, where in rows or []:
                    self.stage_actors.append((actor, owner, where, str(path)))
            folder = self.state if hid == self.self_id else Path(hpath) / "state"
            for path in self.declaration_files(folder / "handoff-actors"):
                entries, problem = self.cached(path, "actors", self.parse_declarations)
                if problem:
                    self.problem(str(path), f"declaration file {problem}")
                for entry in entries or []:
                    self.declarations.append((entry, hid, str(path)))
        for actor in BUILTIN:
            entry = {"actor": actor, "handoff": "grandfathered", "reason": BUILTIN_REASON, "since": BUILTIN_SINCE}
            self.declarations.append((entry, None, "bin/fm-handoff-actors.py BUILTIN"))

    def declaration_files(self, folder):
        try:
            names = sorted(os.listdir(folder))
        except FileNotFoundError:
            return []
        except OSError as exc:
            self.problem(str(folder), f"cannot be listed ({exc.strerror or exc})")
            return []
        return [folder / n for n in names if not n.startswith(".") and n.endswith(".json")]

    def save_cache(self):
        if self.new_cache == self.cache:
            return
        try:
            atomic(self.cache_path, self.new_cache)
        except OSError:
            pass  # a cache that cannot be written only costs a reparse next call

    # ---------- what is installed ----------

    def registered_checks(self):
        """Custom checks with a trust binding (the set the watcher may run), or None when unlisted."""
        if self._checks is False:
            self._checks = self.list_checks()
        return self._checks

    def list_checks(self):
        try:
            names = os.listdir(self.state)
        except OSError as exc:
            self.problem(str(self.state), f"cannot be listed ({exc.strerror or exc})")
            return None
        present = set(names)
        out = []
        for name in sorted(names):
            if name.endswith(".check-trust") and not name.startswith("."):
                cid = name[:-len(".check-trust")]
                if f"{cid}.check.sh" in present:
                    out.append(f"fm-check:{cid}")
        return out

    def units(self):
        """Active user-installed or transient timers and services, or None when unlisted."""
        if self._units is False:
            self._units = self.list_units()
        return self._units

    def list_units(self):
        systemctl = os.environ.get("FM_HANDOFF_ACTORS_SYSTEMCTL", "systemctl")
        listing = self.run([systemctl, "--user", "list-units", "--type=timer,service", "--state=active",
                            "--no-legend", "--plain", "--no-pager"])
        if listing is None:
            return None
        names = sorted({line.split()[0] for line in listing.splitlines()
                        if line.split() and os.path.splitext(line.split()[0])[1] in UNIT_KINDS})
        old = self.new_cache.get("units")
        if isinstance(old, dict) and old.get("names") == names and isinstance(old.get("triggers"), dict):
            self.triggered_by.update(old["triggers"])
            return old["kept"]
        kept, triggers = [], {}
        if names:
            shown = self.run([systemctl, "--user", "show", "--property=Id,FragmentPath,Transient,TriggeredBy",
                              "--"] + names)
            if shown is None:
                return None
            user = os.path.expanduser("~").rstrip("/") + "/"
            for props in unit_blocks(shown):
                unit = props.get("Id", "")
                if os.path.splitext(unit)[1] in UNIT_KINDS and (
                        props.get("Transient") == "yes" or props.get("FragmentPath", "").startswith(user)):
                    actor = f"{UNIT_KINDS[os.path.splitext(unit)[1]]}:{unit}"
                    kept.append(actor)
                    if actor.startswith("systemd-service:"):
                        triggers[actor] = timers_of(props)
        self.new_cache["units"] = {"names": names, "kept": sorted(kept), "triggers": triggers}
        self.triggered_by.update(triggers)
        return sorted(kept)

    def timers(self, actor):
        """The timer actors systemd names in a service's TriggeredBy, read once per call.

        The unit listing answers for the services it keeps, with the rest of its
        show; any other service is asked on its own, so a check sees the timer
        an installer just enabled. A systemctl that cannot be read is a problem
        and covers nothing.
        """
        if actor not in self.triggered_by:
            systemctl = os.environ.get("FM_HANDOFF_ACTORS_SYSTEMCTL", "systemctl")
            shown = self.run([systemctl, "--user", "show", "--property=TriggeredBy", "--",
                              actor[len("systemd-service:"):]], "read TriggeredBy of")
            self.triggered_by[actor] = [t for props in unit_blocks(shown or "") for t in timers_of(props)]
        return self.triggered_by[actor]

    def run(self, argv, what="list"):
        try:
            done = subprocess.run(argv, capture_output=True, text=True, timeout=SYSTEMCTL_TIMEOUT)
        except FileNotFoundError:
            return ""  # no systemd on this machine, so it has no user units to list
        except (OSError, subprocess.TimeoutExpired) as exc:
            self.problem("systemctl --user", f"cannot {what} user units ({exc})", True)
            return None
        if done.returncode != 0:
            self.problem("systemctl --user",
                         f"cannot {what} user units ({done.stderr.strip()[:200] or done.returncode})", True)
            return None
        return done.stdout

    # ---------- grandfathering ----------

    def snapshot(self, units):
        """Grandfather what is installed, once per file, on the first call after the check ships.

        Checks and units have separate snapshots, so a machine where the user
        units cannot be listed still grandfathers its checks; the unit snapshot
        is only taken in the anchor home, and only once a listing succeeds.
        """
        self.freeze("grandfathered.json", self.registered_checks, False)
        if units and self.anchor:
            self.freeze("grandfathered-units.json", self.units, True)

    def freeze(self, name, source, units):
        path = self.state / "handoff-actors" / name
        if os.path.lexists(path):
            return
        actors = source()
        if actors is None:
            return  # retried on the next call, with the problem already reported
        stamp = now()
        why = "installed before the handoff install check existed"
        doc = {"format": FORMAT, "publisher": "bin/fm-handoff-actors.py snapshot", "revision": 1,
               "published_at": stamp,
               "actors": [{"actor": a, "handoff": "grandfathered", "reason": why, "since": stamp}
                          for a in actors]}
        try:
            path.parent.mkdir(parents=True, exist_ok=True)
            fd, tmp = tempfile.mkstemp(prefix=".snapshot-", dir=path.parent)
            try:
                with os.fdopen(fd, "w") as stream:
                    json.dump(doc, stream, indent=2)
                    stream.write("\n")
                    stream.flush()
                    os.fsync(stream.fileno())
                os.link(tmp, path)  # never replaces a snapshot another call wrote first
            except FileExistsError:
                entries, problem = self.parse_declarations(path)  # another call wrote it first
                if problem:
                    self.problem(str(path), f"declaration file {problem}", units)
                for entry in entries or []:
                    self.declarations.append((entry, self.self_id, str(path)))
                return
            finally:
                os.unlink(tmp)
        except OSError as exc:
            self.problem(str(path), f"grandfather snapshot cannot be written ({exc.strerror or exc})", units)
            return
        for entry in doc["actors"]:
            self.declarations.append((entry, self.self_id, str(path)))
        self.log(f"snapshot: grandfathered {len(actors)} installed actor(s) in {path}; "
                 "later installs need a declaration")

    # ---------- the verdict ----------

    def verdict(self, actor):
        """(verdict, why) for one actor, from what this home sees."""
        scope = machine_scope(actor)
        candidates = self.covering(actor)
        for candidate in candidates:
            for item, owner, where, path in self.stage_actors:
                if item == candidate and (scope or owner == self.self_id):
                    return "declared", f"stage {where} owned by {owner} lists {candidate} ({path})"
        best = None
        for candidate in candidates:
            for entry, hid, path in self.declarations:
                if not matches(entry["actor"], candidate):
                    continue
                if not scope and hid not in (None, self.self_id):
                    continue
                rank = 0 if entry["handoff"] == "none" else 1
                if best is None or rank < best[0]:
                    best = (rank, entry["handoff"], f"{entry['reason']} ({path})")
        if best:
            return best[1], best[2]
        problems = self.problems if scope else self.home_problems
        if problems:
            return "unknown", f"not covered by what could be read; {problems[0]['subject']} {problems[0]['what']}"
        if scope:
            where = "a stage's actors in any local home's fragment"
        else:
            where = f"a stage owned by {self.self_id} in a fragment"
        return "refused", (f"no handoff declaration: list {actor} in {where}, or declare that it reads "
                           f"and writes no handoff (fm-handoff-actors.py declare --none --reason TEXT)")

    def covering(self, actor):
        """The actor itself, and for a service the timers that start it: the one of the
        same name, and every timer systemd names in its TriggeredBy."""
        out = [actor]
        if actor.startswith("systemd-service:") and actor.endswith(".service"):
            out.append("systemd-timer:" + actor[len("systemd-service:"):-len(".service")] + ".timer")
            out += [t for t in self.timers(actor) if t not in out]
        return out

    def log(self, text):
        try:
            path = self.state / "handoff-actors" / "log"
            path.parent.mkdir(parents=True, exist_ok=True)
            with open(path, "a", encoding="utf-8") as stream:
                stream.write(f"{now()} {text}\n")
        except OSError:
            pass


# ---------- commands ----------

def cmd_check(args):
    home = Home(args.home, args.state, args.root)
    home.snapshot(machine_scope(args.actor))
    verdict, why = home.verdict(args.actor)
    home.save_cache()
    allowed = verdict in ("declared", "none", "grandfathered")
    nxt = "install proceeds" if allowed else "installer must not install"
    home.log(f"check {args.actor}: {verdict} - {why}; {nxt}")
    print(f"{verdict}\t{args.actor}\t{why}")
    if allowed:
        return OK
    return UNREADABLE if verdict == "unknown" else REFUSED


def state_of(args):
    return Path(args.state).resolve() if args.state else Path(args.home).resolve() / "state"


def edit_declarations(args, change):
    """Apply change(actors) -> actors to declared.json under its lock; None when written."""
    folder = state_of(args) / "handoff-actors"
    folder.mkdir(parents=True, exist_ok=True)
    path = folder / "declared.json"
    with open(folder / ".lock", "a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        doc = {"format": FORMAT, "publisher": "bin/fm-handoff-actors.py declare", "revision": 0, "actors": []}
        if path.exists():
            try:
                doc = json.loads(path.read_text(encoding="utf-8"))
            except (OSError, ValueError) as exc:
                print(f"fm-handoff-actors: {path} cannot be read ({exc}); not changed", file=sys.stderr)
                return UNREADABLE
            if not isinstance(doc, dict) or doc.get("format") != FORMAT or not isinstance(doc.get("actors"), list):
                print(f"fm-handoff-actors: {path} is not {FORMAT}; not changed", file=sys.stderr)
                return UNREADABLE
        new = change(list(doc["actors"]))
        if new == doc["actors"]:
            print(f"unchanged\t{args.actor}")
            return OK
        doc["actors"] = new
        doc["revision"] = int(doc.get("revision", 0)) + 1
        doc["published_at"] = now()
        atomic(path, doc)
    return None


def cmd_declare(args):
    if not (1 <= len(args.reason) <= 300) or "\n" in args.reason:
        print("fm-handoff-actors: --reason must be one line of 1-300 characters", file=sys.stderr)
        return USAGE

    def change(actors):
        old = [e for e in actors if e.get("actor") == args.actor]
        if old and old[0].get("reason") == args.reason and old[0].get("handoff") == "none":
            return actors
        entry = {"actor": args.actor, "handoff": "none", "reason": args.reason, "since": now()}
        rest = [e for e in actors if e.get("actor") != args.actor]
        return sorted(rest + [entry], key=lambda e: e["actor"])

    code = edit_declarations(args, change)
    if code is not None:
        return code
    _log(args, f"declare {args.actor}: reads and writes no handoff - {args.reason}")
    print(f"written\t{args.actor}\tnone")
    return OK


def cmd_undeclare(args):
    code = edit_declarations(args, lambda actors: [e for e in actors if e.get("actor") != args.actor])
    if code is not None:
        return code
    _log(args, f"undeclare {args.actor}: its no-handoff declaration is removed")
    print(f"undeclared\t{args.actor}")
    return OK


def _log(args, text):
    try:
        with open(state_of(args) / "handoff-actors" / "log", "a", encoding="utf-8") as stream:
            stream.write(f"{now()} {text}\n")
    except OSError:
        pass


def inventory(home):
    """The handoff-actor-inventory/v1 document for one Home."""
    home.snapshot(True)
    rows = []
    actors = [(a, "home") for a in home.registered_checks() or []]
    if home.anchor:
        actors += [(a, "machine") for a in (home.units() or [])]
    for actor, scope in actors:
        verdict, why = home.verdict(actor)
        rows.append({"actor": actor, "scope": scope, "state": verdict, "why": why})
    home.save_cache()
    return {"format": INVENTORY, "home": home.self_id, "home_path": str(home.home), "anchor": home.anchor,
            "actors": rows, "problems": home.problems}


def cmd_list(args):
    home = Home(args.home, args.state, args.root)
    doc = inventory(home)
    undeclared = sorted(r["actor"] for r in doc["actors"] if r["state"] == "refused")
    for row in doc["actors"]:
        if row["state"] == "refused":
            row["state"] = "undeclared"
    mark = home.state / "handoff-actors" / ".undeclared"
    text = "\n".join(undeclared)
    try:
        old = mark.read_text(encoding="utf-8")
    except OSError:
        old = None
    if old != text:
        home.log(f"list: undeclared actors now [{', '.join(undeclared) or 'none'}]; "
                 + ("undeclared-actor alarms them" if undeclared else "nothing to alarm"))
        try:
            mark.parent.mkdir(parents=True, exist_ok=True)
            mark.write_text(text, encoding="utf-8")
        except OSError:
            pass
    print(json.dumps(doc, indent=2, sort_keys=True))
    if doc["problems"]:
        return UNREADABLE
    return REFUSED if undeclared else OK


def not_a_home(args):
    """One line naming why --home is not a Firstmate home to write under, or None."""
    try:
        empty = not os.listdir(args.home)
    except OSError as exc:
        return f"--home {args.home} is not a firstmate home ({exc.strerror or exc}); nothing written"
    if empty:
        return f"--home {args.home} is not a firstmate home (empty folder); nothing written"
    if not state_of(args).is_dir():
        if args.state:
            return f"--state {args.state} is not a folder; nothing written"
        return f"--home {args.home} is not a firstmate home (no state/ folder); nothing written"
    return None


def main(argv):
    parser = argparse.ArgumentParser(prog="fm-handoff-actors.py", add_help=True)
    sub = parser.add_subparsers(dest="command", required=True)
    for name in ("check", "declare", "undeclare", "list"):
        p = sub.add_parser(name)
        p.add_argument("--home", required=True)
        p.add_argument("--state")
        if name in ("check", "list"):
            p.add_argument("--root")
        if name == "declare":
            p.add_argument("--none", action="store_true", required=True)
            p.add_argument("--reason", required=True)
        if name != "list":
            p.add_argument("actor")
    try:
        args = parser.parse_args(argv)
    except SystemExit as exc:
        return USAGE if exc.code else OK
    if getattr(args, "actor", None) is not None and not ACTOR_RE.match(args.actor):
        print(f"fm-handoff-actors: {args.actor!r} is not <kind>:<name> with kind systemd-timer, "
              "systemd-service, fm-check, cron or process", file=sys.stderr)
        return USAGE
    refusal = None
    if refusal:
        print(f"fm-handoff-actors: {refusal}", file=sys.stderr)
        return USAGE
    try:
        return {"check": cmd_check, "declare": cmd_declare, "undeclare": cmd_undeclare,
                "list": cmd_list}[args.command](args)
    except VALIDATE.Unreadable as exc:
        print(f"fm-handoff-actors: {exc}", file=sys.stderr)
        return UNREADABLE


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
