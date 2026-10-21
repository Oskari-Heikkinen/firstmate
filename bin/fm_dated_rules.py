"""fm_dated_rules - read and resolve dated-rule-schedule/v1 schedules.

docs/dated-rule-schedule.md owns the format and its rules; this module is
their one implementation. bin/fm-handoff-validate.py (schedule) checks files
with it, bin/fm-dated-rules.py (check, lookup) reads a home's schedule with it,
and another tool may load this file by path and call lookup():

  spec = importlib.util.spec_from_file_location("fm_dated_rules", "<firstmate>/bin/fm_dated_rules.py")
  rules = importlib.util.module_from_spec(spec); spec.loader.exec_module(rules)
  row = rules.lookup("<home>", "prep-grace-end")   # {"date": "2026-10-27", ...}

lookup() raises NotDeclared when no readable schedule of the home declares the
rule, and Unknown when the rule, or any schedule file that might declare it,
cannot be read; a caller treats both as "no date" and fails closed.
"""

import datetime
import importlib.util
import json
import os

FORMAT = "dated-rule-schedule/v1"
SCHEMA_FILE = "dated-rule-schedule-v1.schema.json"
ALARM_DAYS = (14, 7, 1)
ESCALATE_AFTER_SLIPS = 2
_HERE = os.path.dirname(os.path.abspath(__file__))


class NotDeclared(Exception):
    pass


class Unknown(Exception):
    pass


def _validator():
    spec = importlib.util.spec_from_file_location("fm_handoff_validate", os.path.join(_HERE, "fm-handoff-validate.py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def default_schema_dir():
    return os.path.join(os.path.dirname(_HERE), "docs", "handoff-coverage")


def schema(schema_dir=None):
    """The schedule schema as the validator's Schema; raises Unknown when it cannot be read."""
    validator = _validator()
    folder = schema_dir or default_schema_dir()
    try:
        return validator.Schema(os.path.join(folder, SCHEMA_FILE))
    except validator.Unreadable as exc:
        raise Unknown(str(exc)) from exc


def parse_date(text):
    try:
        return datetime.date.fromisoformat(text)
    except (TypeError, ValueError):
        return None


def file_problems(doc):
    """Cross-field problems that make a whole schema-valid file unusable."""
    out = []
    seen = set()
    for index, row in enumerate(doc.get("rows", [])):
        where = f"/rows/{index}"
        if row["id"] in seen:
            out.append((where + "/id", f"row {row['id']} is declared twice"))
        seen.add(row["id"])
        if row["owner"] != doc["home"]:
            out.append((where + "/owner", f"a schedule holds only rows its home owns; {row['owner']} is not {doc['home']}"))
        if parse_date(row["date"]) is None:
            out.append((where + "/date", f"{row['date']} is not a calendar date"))
    return out


def read_file(path, checker):
    """(doc, problems) for one schedule file; problems is a list of (where, text)."""
    try:
        with open(path, encoding="utf-8") as handle:
            text = handle.read()
    except OSError as exc:
        return None, [("/", f"cannot be read: {exc.strerror or exc}")]
    try:
        doc = json.loads(text)
    except ValueError as exc:
        return None, [("/", f"not valid JSON ({exc})")]
    problems = checker.errors(doc)
    if not problems:
        problems = file_problems(doc)
    return (None if problems else doc), problems


class Rule:
    """One rule's chain of rows across a home's schedule files."""

    def __init__(self, rule_id):
        self.id = rule_id
        self.rows = []
        self.paths = set()
        self.problems = []
        self.chain = []
        self.effective = None
        self.unreviewed = None
        self.slips = 0

    def summary(self):
        row = self.effective
        return {
            "rule": self.id, "row": row["id"], "date": row["date"], "state": row["state"],
            "owner": row["owner"], "what": row["what"], "slips": self.slips,
            "pending": [r["id"] for r in self.chain[self.chain.index(row) + 1:]],
            "paths": sorted(self.paths),
        }


def resolve(docs):
    """Resolve [(path, doc)] of one home's valid files into {rule id: Rule}.

    A row id used twice across files is reported against each rule that uses it
    and breaks those rules, so one bad rule never hides another rule's date.
    """
    by_id = {}
    rules = {}
    for path, doc in docs:
        for row in doc.get("rows", []):
            rule = rules.setdefault(row["rule"], Rule(row["rule"]))
            rule.rows.append(row)
            rule.paths.add(path)
            by_id.setdefault(row["id"], []).append(row)
    for rule in rules.values():
        _resolve_rule(rule, by_id)
    return rules


def _resolve_rule(rule, by_id):
    problems = rule.problems
    if len(rule.paths) > 1:
        problems.append(f"its rows are split across {', '.join(sorted(os.path.basename(p) for p in rule.paths))}; one file holds a rule")
    for row in rule.rows:
        if len(by_id[row["id"]]) > 1:
            problems.append(f"row id {row['id']} is used by more than one row")
    roots = [row for row in rule.rows if "replaces" not in row]
    if len(roots) != 1:
        problems.append(f"{len(roots)} rows have no replaces; exactly one starts the rule")
    child = {}
    for row in rule.rows:
        if "replaces" not in row:
            continue
        targets = by_id.get(row["replaces"], [])
        if not targets:
            problems.append(f"row {row['id']} replaces {row['replaces']}, which is not a row of this home")
            continue
        target = targets[0]
        if target["rule"] != rule.id:
            problems.append(f"row {row['id']} replaces {target['id']}, a row of rule {target['rule']}")
        elif target["state"] != "scheduled":
            problems.append(f"row {row['id']} replaces {target['id']}, which is {target['state']}; a rule in force or withdrawn is never moved, a new rule id is")
        if row["replaces"] in child:
            problems.append(f"row {row['replaces']} is replaced by both {child[row['replaces']]['id']} and {row['id']}")
        child[row["replaces"]] = row
    if problems:
        return
    chain = [roots[0]]
    while chain[-1]["id"] in child and len(chain) <= len(rule.rows):
        chain.append(child[chain[-1]["id"]])
    if len(chain) != len(rule.rows):
        stray = sorted({row["id"] for row in rule.rows} - {row["id"] for row in chain})
        problems.append(f"rows {', '.join(stray)} are not on the chain from {roots[0]['id']}")
        return
    for row in chain[:-1]:
        if row["state"] != "scheduled":
            problems.append(f"row {row['id']} is {row['state']} but has been replaced")
    if problems:
        return
    rule.chain = chain
    rule.effective = chain[0]
    for row in chain[1:]:
        if "review" not in row:
            rule.unreviewed = row
            break
        if row["date"] > rule.effective["date"]:
            rule.slips += 1
        rule.effective = row


def chain_problems(rules):
    """Every rule-level finding, for a validator: (rule id, text)."""
    out = []
    for rule in rules.values():
        out.extend((rule.id, text) for text in rule.problems)
        if rule.unreviewed is not None:
            row = rule.unreviewed
            out.append((rule.id, f"row {row['id']} replaces {row['replaces']} without a review mark; a moved date needs review {{by, at, ref}}"))
    return out


def link_problem(item, rules):
    """Why a fragment's dated rule does not match its owner's schedule, or None.

    The fragment entry's id names the rule and its date must be the rule's
    effective date, so a moved date shows until the fragment is revised.
    """
    rule = rules.get(item.get("id"))
    if rule is None:
        return f"dated rule {item.get('id')} names no rule in the schedule of {item.get('owner')}"
    if rule.problems:
        return f"dated rule {rule.id} cannot be resolved in its schedule"
    if item.get("date") != rule.effective["date"]:
        return f"dated rule {rule.id} says {item.get('date')}, but schedule row {rule.effective['id']} says {rule.effective['date']}"
    return None


def alarms(rules, today, slip_floor=None):
    """({key: (reason, rule id)} for the owner, the same for main) on <today>.

    slip_floor maps a rule to the most slips a reader has ever seen for it, so
    removing old rows cannot lower the count that escalates to main.
    """
    owner, main = {}, {}
    floor = slip_floor or {}
    for rule in rules.values():
        if rule.problems:
            owner[f"dated-rule.{rule.id}.broken"] = (
                f"dated rule {rule.id} cannot be resolved: {'; '.join(rule.problems)}; "
                "lookups of it fail until the rows are fixed", rule.id)
            continue
        row = rule.effective
        if rule.unreviewed is not None:
            new = rule.unreviewed
            owner[f"dated-rule.{new['id']}.unreviewed"] = (
                f"row {new['id']} moves dated rule {rule.id} from {new.get('replaces')} to {new['date']} without a review mark, "
                f"so {row['date']} (row {row['id']}) stays in force; add review {{by, at, ref}} or remove the row", rule.id)
        if row["state"] != "scheduled":
            continue
        days = (parse_date(row["date"]) - today).days
        tail = f"{row['what']}; set state in-force once it holds, or move it with a reviewed new row"
        if days <= 0:
            owner[f"dated-rule.{row['id']}.due"] = (
                f"dated rule {rule.id} took effect on {row['date']} and row {row['id']} is still scheduled: {tail}", rule.id)
        elif days <= ALARM_DAYS[0]:
            lead = min(d for d in ALARM_DAYS if d >= days)
            owner[f"dated-rule.{row['id']}.{lead}d"] = (
                f"dated rule {rule.id} takes effect on {row['date']}, in {days} day{'s' if days != 1 else ''}: {tail}", rule.id)
        slips = max(rule.slips, floor.get(rule.id, 0))
        if slips >= ESCALATE_AFTER_SLIPS and "main_decision" not in row:
            main[f"dated-rule.{row['id']}.escalated"] = (
                f"dated rule {rule.id} of {row['owner']} has slipped {slips} times, now to {row['date']} in row {row['id']}: "
                f"{row['what']}; decide whether it may slip again and record main_decision {{by, at, ref}} on the row", rule.id)
    return owner, main


def home_files(folder):
    """(sorted schedule paths, stray entries) at the top level of <folder>; raises OSError."""
    paths, strays = [], []
    for entry in sorted(os.listdir(folder)):
        if entry.startswith("."):
            continue
        path = os.path.join(folder, entry)
        (paths if entry.endswith(".json") and os.path.isfile(path) else strays).append(path)
    return paths, strays


def read_home(folder, checker):
    """({rule: Rule}, {path: problems}, [example paths]) for one home's schedule folder.

    A missing folder declares nothing; any other listing failure raises Unknown.
    """
    try:
        paths, strays = home_files(folder)
    except FileNotFoundError:
        return {}, {}, []
    except OSError as exc:
        raise Unknown(f"{folder}: {exc.strerror or exc}") from exc
    bad = {path: [("/", "not a schedule file; the folder holds only <name>.json schedules")] for path in strays}
    docs, examples = [], []
    for path in paths:
        doc, problems = read_file(path, checker)
        if problems:
            bad[path] = problems
        elif doc.get("example"):
            examples.append(path)
        else:
            docs.append((path, doc))
    return resolve(docs), bad, examples


def lookup(home, rule_id, state_dir=None, schema_dir=None):
    """The resolved row of <rule_id> in <home>'s schedule, as a dict (see Rule.summary)."""
    folder = os.path.join(state_dir or os.path.join(home, "state"), "dated-rules")
    rules, bad, _ = read_home(folder, schema(schema_dir))
    if bad:
        # Any unreadable file could hold this rule or a newer reviewed row of it.
        raise Unknown(f"{', '.join(sorted(bad))} cannot be read, so no rule of this home is known")
    rule = rules.get(rule_id)
    if rule is None:
        raise NotDeclared(f"{rule_id} is not declared in {folder}")
    if rule.problems:
        raise Unknown(f"{rule_id} cannot be resolved: {'; '.join(rule.problems)}")
    return rule.summary()
