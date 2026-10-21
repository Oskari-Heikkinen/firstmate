#!/usr/bin/env python3
"""fm-dated-rules.py - raise a home's dated-rule alarms and look up a rule's date.

Usage:
  fm-dated-rules.py check [--today YYYY-MM-DD]
  fm-dated-rules.py lookup [--json] RULE

docs/dated-rule-schedule.md owns the schedule format, the alarm keys and where
each alarm goes; bin/fm_dated_rules.py owns the rules this tool applies.

check    reads every schedule in state/dated-rules/ and this home's own
         fragments in state/handoff-registry/, and keeps two fm-alert-store/v1
         stores level with what it finds: state/dated-rules.alerts.json
         (store dated-rules, registered for state/dated-rules.status) for the
         owner, and state/dated-rules.escalated.json (store
         dated-rules-<home>, registered for this home's parent channel) for
         main. A main home keeps both kinds in the owner store. It writes a
         store (through bin/fm-alert-store.sh sync, under the store lock) and
         a registration only when they change, and skips the whole pass when
         the UTC date and the stat of every input match the last pass
         (state/dated-rules/.reader-state.json). The bin/fm-alert-store.sh
         tick projects the stores onto the status files. Once
         state/dated-rules/ is gone it unregisters and removes both stores,
         closing their blockers. It prints one line per problem of its own
         (an unreadable schema, a store it cannot write) on every pass until
         the problem is gone, and nothing when all is well.
lookup   prints "<date> <state> <row>" for RULE's effective row, or with --json
         the whole resolved row (rule, row, date, state, owner, what, slips,
         pending, paths). A moved date without a review mark is not effective.

Environment: FM_HOME (default: this checkout), FM_STATE_OVERRIDE.
FM_DATED_RULES_CHECK_MARK=1 makes check end with "dated-rules check: complete",
which bin/fm-watch.sh strips; a pass without it did not finish.

Exit: 0 done (check: even with problems, which it prints); 1 lookup: RULE is
not declared; 2 usage; 3 lookup: RULE or a schedule cannot be read or resolved
(unknown is failure: a caller treats it as no date and fails closed).
"""

import datetime
import importlib.util
import json
import os
import re
import subprocess
import sys
import tempfile

PROG = "fm-dated-rules"
REG_SCHEMA = "fm-alert-registration/v1"
OWNER_STORE_ID = "dated-rules"
MARK = "dated-rules check: complete"
SLUG_BAD = re.compile(r"[^A-Za-z0-9._-]")
_HERE = os.path.dirname(os.path.abspath(__file__))


def load_lib():
    spec = importlib.util.spec_from_file_location("fm_dated_rules", os.path.join(_HERE, "fm_dated_rules.py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


LIB = load_lib()


def utc_now():
    return datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0)


def stamp(moment):
    return moment.strftime("%Y-%m-%dT%H:%M:%SZ")


def read_text(path):
    try:
        with open(path, encoding="utf-8") as handle:
            return handle.read()
    except (OSError, UnicodeDecodeError):
        return None


def write_atomic(path, text):
    folder, base = os.path.split(path)
    fd, tmp = tempfile.mkstemp(prefix=f".{base}.", dir=folder)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(text)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def stat_key(path):
    try:
        st = os.stat(path)
    except OSError:
        return None
    return [st.st_ino, st.st_size, st.st_mtime_ns]


class Home:
    """This home's identity and where an alarm for main goes."""

    def __init__(self, root, state):
        self.root = root
        self.state = state
        self.id, self.problem = self.read_id()
        self.main_status = self.main_reg = None
        if self.id not in (None, "main"):
            self.resolve_main()

    def read_id(self):
        marker = os.path.join(self.root, ".fm-secondmate-home")
        if not os.path.lexists(marker):
            return "main", None
        text = read_text(marker) if os.path.isfile(marker) and not os.path.islink(marker) else None
        ident = None if text is None or "\0" in text else text.rstrip("\n")
        if not ident or ident.startswith(".") or SLUG_BAD.search(ident):
            return None, f"{marker} does not name this home"
        return ident, None

    def resolve_main(self):
        record = os.path.join(self.root, ".fm-secondmate-parent")
        text = read_text(record) if os.path.isfile(record) and not os.path.islink(record) else None
        fields = {}
        for line in (text or "").splitlines():
            name, sep, value = line.partition("=")
            if sep and name in ("schema", "route", "parent_home", "parent_host"):
                fields.setdefault(name, []).append(value)
        one = {name: values[0] for name, values in fields.items() if len(values) == 1}
        route = one.get("route")
        valid = (text is not None and "\0" not in text and one.get("schema") == "fm-secondmate-parent.v1"
                 and all(len(v) == 1 for v in fields.values()))
        store_id = f"{OWNER_STORE_ID}-{self.id}"
        if valid and route == "local" and one.get("parent_home", "").startswith("/") and "parent_host" not in one:
            parent_state = os.path.join(one["parent_home"], "state")
            self.main_status = os.path.join(parent_state, f"{self.id}.status")
            self.main_reg = os.path.join(parent_state, "alert-stores", f"{store_id}.reg")
        elif valid and route == "remote" and "parent_home" not in fields:
            self.main_status = os.path.join(self.state, "parent-replies.status")
            self.main_reg = os.path.join(self.state, "alert-stores", f"{store_id}.reg")
        else:
            self.problem = f"{record} is missing or unusable, so escalations to main stay in this home's store"


class Store:
    """One fm-alert-store/v1 file this tool owns, kept level with a wanted set."""

    def __init__(self, path, store_id):
        self.path = path
        self.id = store_id

    def sync(self, wanted, home, log):
        """Make active equal <wanted> {key: (reason, subject)} through fm-alert-store.sh sync,
        which writes under the store lock; return a problem or None."""
        text = read_text(self.path)
        try:
            active = json.loads(text)["active"] if text is not None else {}
        except (ValueError, TypeError, KeyError):
            active = None
        if isinstance(active, dict) and set(active) == set(wanted) and all(
                isinstance(active[k], dict) and active[k].get("reason") == r for k, (r, _) in wanted.items()):
            return None
        if text is None and not wanted:
            return None
        want = {k: {"kind": "dated-rule", "subject": s, "reason": r} for k, (r, s) in wanted.items()}
        fd, tmp = tempfile.mkstemp(prefix=f".{os.path.basename(self.path)}.wanted.", dir=os.path.dirname(self.path))
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as handle:
                json.dump(want, handle)
            run = subprocess.run([os.path.join(_HERE, "fm-alert-store.sh"), "sync", self.path, self.id, tmp,
                                  "the dated rule no longer needs this alarm"],
                                 env={**os.environ, "FM_HOME": home.root, "FM_STATE_OVERRIDE": home.state},
                                 capture_output=True, text=True, timeout=30)
        except (OSError, subprocess.TimeoutExpired) as exc:
            return f"cannot write alert store {self.path}: {exc}"
        finally:
            try:
                os.unlink(tmp)
            except OSError:
                pass
        if run.returncode != 0:
            return f"cannot write alert store {self.path}: {(run.stderr or run.stdout).strip()[:200]}"
        old = set(active) if isinstance(active, dict) else set()
        for key in sorted(set(wanted) - old):
            log(f"raised {key} in store {self.id}: {wanted[key][0]}")
        for key in sorted(old - set(wanted)):
            log(f"cleared {key} in store {self.id}")
        return None


def ensure_registration(reg, store, status, owner, log):
    """Write <reg> when it does not already say exactly this; return a problem or None."""
    want = (f"schema={REG_SCHEMA}\nstore={os.path.basename(reg)[:-4]}\npath={store.path}\n"
            f"status={os.path.basename(status)}\nowner={owner}\n")
    if read_text(reg) == want:
        return None
    try:
        os.makedirs(os.path.dirname(reg), exist_ok=True)
        if not os.path.exists(status):
            with open(status, "a", encoding="utf-8"):
                pass
        write_atomic(reg, want)
    except OSError as exc:
        return f"cannot register alert store {store.id} at {reg}: {exc.strerror or exc}"
    log(f"registered alert store {store.id} for {status}")
    return None


def slug(text):
    return SLUG_BAD.sub("-", text)


def fragment_links(state, home_id, rules):
    """{key: (reason, subject)} for this home's fragment dated rules that miss their schedule row."""
    out = {}
    folder = os.path.join(state, "handoff-registry")
    try:
        entries = sorted(os.listdir(folder))
    except OSError:
        return out
    for entry in entries:
        if entry.startswith(".") or not entry.endswith(".json"):
            continue
        path = os.path.join(folder, entry)
        try:
            doc = json.loads(read_text(path) or "")
            protocols = [p for p in doc.get("protocols", []) if isinstance(p, dict)]
        except (ValueError, AttributeError):
            continue  # fragment readability is the coverage watcher's source-unreadable check
        for proto in protocols:
            for item in proto.get("dated_rules", []) or []:
                if not isinstance(item, dict) or item.get("owner") != home_id:
                    continue
                problem = LIB.link_problem(item, rules)
                if problem:
                    key = f"dated-rule.{slug(str(item.get('id')))}.unlinked"
                    out[key] = (f"fragment {path} protocol {proto.get('id')}: {problem}", path)
    return out


def signature(state, folder, home, today):
    paths = [os.path.join(LIB.default_schema_dir(), LIB.SCHEMA_FILE),
             os.path.join(home.root, ".fm-secondmate-home"), os.path.join(home.root, ".fm-secondmate-parent"),
             os.path.join(state, "dated-rules.alerts.json"), os.path.join(state, "dated-rules.escalated.json"),
             os.path.join(state, "alert-stores", f"{OWNER_STORE_ID}.reg"), home.main_reg or ""]
    for sub in (folder, os.path.join(state, "handoff-registry")):
        try:
            paths.extend(os.path.join(sub, e) for e in sorted(os.listdir(sub)) if not e.startswith("."))
        except OSError:
            paths.append(sub)
    return [today.isoformat()] + [[p, stat_key(p)] for p in paths if p]


def retire(home, log_path):
    """With the schedule folder gone, unregister and remove both stores, closing their blockers; return problems."""
    problems = []
    stores = [(os.path.join(home.state, "dated-rules.alerts.json"), OWNER_STORE_ID, home.root, home.state)]
    if home.id is not None:
        main_state = os.path.dirname(os.path.dirname(home.main_reg)) if home.main_reg else None
        stores.append((os.path.join(home.state, "dated-rules.escalated.json"), f"{OWNER_STORE_ID}-{home.id}",
                       os.path.dirname(main_state) if main_state else None, main_state))
    for path, store_id, reg_root, reg_state in stores:
        if not os.path.exists(path):
            continue
        if reg_root is None:
            problems.append(f"cannot unregister alert store {store_id}: {home.problem}")
            continue
        try:
            run = subprocess.run([os.path.join(_HERE, "fm-alert-store.sh"), "unregister", store_id],
                                 env={**os.environ, "FM_HOME": reg_root, "FM_STATE_OVERRIDE": reg_state},
                                 capture_output=True, text=True, timeout=30)
            if run.returncode != 0:
                problems.append(f"cannot unregister alert store {store_id}: {(run.stderr or run.stdout).strip()[:200]}")
                continue
            os.unlink(path)
            with open(log_path, "a", encoding="utf-8") as handle:
                handle.write(f"{stamp(utc_now())} retired alert store {store_id}: state/dated-rules/ is gone\n")
        except (OSError, subprocess.TimeoutExpired) as exc:
            problems.append(f"cannot retire alert store {store_id}: {exc}")
    return problems


def check(root, state, today):
    folder = os.path.join(state, "dated-rules")
    reader_path = os.path.join(folder, ".reader-state.json")
    log_path = os.path.join(state, "dated-rules.log")
    try:
        saved = json.loads(read_text(reader_path) or "{}")
    except ValueError:
        saved = {}
    if not isinstance(saved, dict):
        saved = {}
    home = Home(root, state)
    if not os.path.isdir(folder):
        return retire(home, log_path)
    sig = signature(state, folder, home, today)
    if saved.get("signature") == sig:
        return saved.get("problems", [])
    lines = []

    def log(text):
        lines.append(f"{stamp(utc_now())} {text}")

    problems = [home.problem] if home.problem else []
    try:
        checker = LIB.schema()
    except LIB.Unknown as exc:
        return problems + [f"cannot check dated rules: {exc}"]
    rules, bad, examples = LIB.read_home(folder, checker)
    owner_wanted = {}
    for path in examples:
        bad[path] = [("/", "an example schedule declares nothing; a live home holds only real schedules")]
    for path, found in bad.items():
        reason = f"schedule {path} cannot be used, so its rules are unknown: " + "; ".join(f"{w}: {p}" for w, p in found)
        owner_wanted[f"dated-rule.file.{slug(os.path.basename(path))}.unreadable"] = (reason, path)
    if home.id is not None:
        for rule in rules.values():
            wrong = sorted({row["owner"] for row in rule.rows} - {home.id})
            if wrong:
                rule.problems.append(f"its rows are owned by {', '.join(wrong)}, but this home is {home.id}")
    slips = {k: v for k, v in (saved.get("slips") or {}).items() if isinstance(v, int)}
    owner_alarms, main_alarms = LIB.alarms(rules, today, slips)
    for rule in rules.values():
        if not rule.problems:
            slips[rule.id] = max(slips.get(rule.id, 0), rule.slips)
    owner_wanted.update(owner_alarms)
    owner_wanted.update(fragment_links(state, home.id, rules))
    main_wanted = main_alarms
    if home.main_status is None:
        prefix = "" if home.id == "main" else "main cannot be reached from this home, so this stays here: "
        owner_wanted.update({k: (prefix + r, s) for k, (r, s) in main_wanted.items()})
        main_wanted = {}
    now = utc_now()
    owner = Store(os.path.join(state, "dated-rules.alerts.json"), OWNER_STORE_ID)
    problem = owner.sync(owner_wanted, home, log)
    if problem is None and os.path.exists(owner.path):
        problem = ensure_registration(os.path.join(state, "alert-stores", f"{OWNER_STORE_ID}.reg"), owner,
                                      os.path.join(state, "dated-rules.status"), f"{PROG} ({home.id})", log)
    problems += [problem] if problem else []
    if home.main_status is not None:
        main = Store(os.path.join(state, "dated-rules.escalated.json"), f"{OWNER_STORE_ID}-{home.id}")
        problem = main.sync(main_wanted, home, log)
        if problem is None and os.path.exists(main.path):
            problem = ensure_registration(home.main_reg, main, home.main_status, f"{PROG} ({home.id})", log)
        problems += [problem] if problem else []
    if problems != saved.get("problems", []):
        lines.extend(f"{stamp(now)} problem: {p}" for p in problems)
    try:
        if lines:
            with open(log_path, "a", encoding="utf-8") as handle:
                handle.write("".join(line + "\n" for line in lines))
        record = {"signature": None if problems else signature(state, folder, home, today),
                  "slips": slips, "problems": problems}
        write_atomic(reader_path, json.dumps(record, sort_keys=True) + "\n")
    except OSError as exc:
        problems.append(f"cannot write {reader_path}: {exc.strerror or exc}")
    return problems


def lookup(root, state, rule_id, as_json):
    try:
        row = LIB.lookup(root, rule_id, state_dir=state)
    except LIB.NotDeclared as exc:
        print(f"{PROG}: {exc}", file=sys.stderr)
        return 1
    except LIB.Unknown as exc:
        print(f"{PROG}: unknown: {exc}", file=sys.stderr)
        return 3
    print(json.dumps(row, sort_keys=True) if as_json else f"{row['date']} {row['state']} {row['row']}")
    return 0


def usage(message):
    if message:
        print(f"{PROG}: {message}", file=sys.stderr)
    print(__doc__.split("\n\n")[1], file=sys.stderr)
    return 2


def main(argv):
    root = os.environ.get("FM_HOME") or os.path.dirname(_HERE)
    state = os.environ.get("FM_STATE_OVERRIDE") or os.path.join(root, "state")
    if not argv or argv[0] in ("-h", "--help"):
        return usage(None)
    command, rest = argv[0], argv[1:]
    if command == "lookup":
        as_json = rest[:1] == ["--json"]
        rest = rest[1:] if as_json else rest
        if len(rest) != 1:
            return usage("lookup needs one RULE")
        return lookup(root, state, rest[0], as_json)
    if command != "check":
        return usage(f"unknown command {command}")
    today = utc_now().date()
    if rest[:1] == ["--today"] and len(rest) == 2 and LIB.parse_date(rest[1]):
        today, rest = LIB.parse_date(rest[1]), []
    if rest:
        return usage("check takes only --today YYYY-MM-DD")
    for problem in check(root, state, today):
        print(problem)
    if os.environ.get("FM_DATED_RULES_CHECK_MARK") == "1":
        print(MARK)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
