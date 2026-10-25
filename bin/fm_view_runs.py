"""Native no-mistakes captured-record parsing and read-only run attribution.

The legacy fm-nm-run-lib.sh remains the fallback/comparison oracle during the
view migration. No command, gate answer, custody mutation or fetch happens in
this module. `git` is a caller-supplied bounded passive observation interface.
"""
import datetime
import json
import os
from pathlib import Path
import re
import sqlite3

TERMINAL = ("completed", "failed", "cancelled")
GATE_SCALAR = re.compile(r'^\s*(?:status|state):\s*"?(?:awaiting_approval|fix_review)"?\s*$')
GATE_ROW = re.compile(r'^\s*[^,]+,\s*"?(?:awaiting_approval|fix_review)"?\s*,')


def scalar(value):
    value = value.strip()
    if value.startswith('"') and value.endswith('"'):
        value = value[1:-1]
    return value.strip()


class Run:
    def __init__(self, text):
        self.text = text
        self.lines = text.splitlines()

    def field(self, name):
        pattern = re.compile(r"^\s*" + re.escape(name) + r":\s*(.*)")
        for line in self.lines:
            match = pattern.match(line)
            if match:
                return scalar(match.group(1))
        return ""

    @property
    def active(self):
        return not self.field("outcome") and self.field("status") not in TERMINAL

    @property
    def parked(self):
        return any(re.match(r"^\s*(?:gate|awaiting_agent):", line) or GATE_SCALAR.match(line) or GATE_ROW.match(line)
                   for line in self.lines)

    @property
    def executing(self):
        return self.active and not self.parked and self.field("status") in ("pending", "running", "fixing", "ci")

    @property
    def pipeline_owned(self):
        inside = False
        for line in self.lines:
            if re.match(r"^\s*branch_sync:\s*$", line):
                inside = True
                continue
            if inside:
                if line and not line[0].isspace():
                    break
                match = re.match(r"^\s+state:\s*(.*)", line)
                if match:
                    return self.active and scalar(match.group(1)) == "pipeline_owned"
        return False

    def rows(self, table):
        result, indent = [], None
        for line in self.lines:
            match = re.match(r"^(\s*)" + re.escape(table) + r"\[[0-9]+\]\{", line)
            if match:
                indent = len(match.group(1))
                continue
            if indent is not None:
                if not line.strip() or len(line) - len(line.lstrip()) <= indent:
                    indent = None
                else:
                    result.append(line)
        return result

    def gate_row(self):
        row = next((line.strip() for line in self.lines if GATE_ROW.match(line)), "")
        pieces = row.split(",")
        return [scalar(value) for value in pieces[:3]] if len(pieces) >= 3 else []

    def gate_line_name(self):
        name = self.field("gate")
        if name:
            return name
        inside = False
        for line in self.lines:
            if re.match(r"^\s*gate:\s*$", line):
                inside = True
                continue
            if inside:
                if line and not line[0].isspace():
                    break
                match = re.match(r"^\s*step:\s*(.*)", line)
                if match:
                    return scalar(match.group(1))
        return ""

    def gate_name(self):
        name = self.gate_line_name()
        if name:
            return name
        row = self.gate_row()
        return row[0] if row else ""

    def findings_count(self):
        # Legacy precedence deliberately includes an unbraced count here. Only
        # the separate ask-user authority reader below requires a braced table.
        match = re.search(r"findings\[([0-9]+)\]", self.text)
        if match:
            return match.group(1)
        row = self.gate_row()
        return row[2] if row and re.fullmatch(r"[0-9]+", row[2]) else ""

    def awaits_human(self):
        for index, line in enumerate(self.lines):
            match = re.match(r"^\s*findings\[([0-9]+)\]\{([^}]*)\}:", line)
            if not match:
                continue
            count, columns = int(match.group(1)), [scalar(c) for c in match.group(2).split(",")]
            if not count or "action" not in columns:
                return False
            action = columns.index("action")
            if any(column not in ("id", "severity", "file", "line") for column in columns[:action]):
                return False
            for row in self.lines[index + 1:index + count + 1]:
                fields = row.split(",")
                if len(fields) > action and scalar(fields[action]) == "ask-user":
                    return True
            return False
        return False

    def ci_step(self):
        if self.field("status") == "fixing":
            return "fixing"
        for line in self.lines:
            match = re.match(r'^\s*ci,\s*"?(running|fixing)"?\s*,', line)
            if match:
                return match.group(1)
        return "running" if self.field("status") == "ci" else ""

    def activity_recent(self):
        rows = self.rows("active_steps")
        return bool(rows) and not any("quiet" in row for row in rows)

    def only_ci_failed(self):
        rows = self.rows("steps")
        failed = False
        if not rows:
            return False
        for row in rows:
            pieces = row.strip().split(",")
            if len(pieces) < 2:
                return False
            step, status = scalar(pieces[0]), scalar(pieces[1])
            if status == "completed" or (status == "skipped" and step == "rebase"):
                continue
            if status in ("failed", "cancelled") and step == "ci":
                failed = True
                continue
            return False
        return failed


def status_class(status):
    if status in TERMINAL:
        return "terminal"
    return "live" if status in ("pending", "running") else "unknown"


def ci_checks(text):
    pattern = re.compile(r"CI checks passed|no CI checks reported - still monitoring|no CI checks reported yet|checks failed|issues detected|CI checks running")
    marker = next((line for line in reversed(text.splitlines()) if pattern.search(line)), "")
    if "checks passed" in marker or "no CI checks reported - still monitoring" in marker:
        return "green"
    return "not-ready" if marker else "unknown"


def csv_row(text):
    fields, value, quoted, escaped = [], "", False, False
    for char in text:
        if escaped:
            value += char
            escaped = False
        elif quoted and char == "\\":
            escaped = True
        elif char == '"':
            quoted = not quoted
        elif not quoted and char == ",":
            fields.append(value.strip(" \t"))
            value = ""
        else:
            value += char
    if quoted or escaped:
        return []
    return fields + [value.strip(" \t")]


def overview(branch, text):
    """Return exactly the legacy selection vocabulary; no precedence guessing."""
    counts, expected, shown, total, found, inrows = 0, 0, 0, 0, False, False
    bad, rows = False, []
    for line in text.splitlines():
        if line.startswith("count: "):
            counts += 1
            match = re.fullmatch(r"([0-9]+) of ([0-9]+) total", scalar(line[7:]))
            if match:
                shown, total = map(int, match.groups())
            else:
                bad = True
        match = re.fullmatch(r"runs\[([0-9]+)\]\{id,branch,status,head,pr\}:", line)
        if match:
            if found:
                bad = True
            expected, found, inrows = int(match.group(1)), True, True
            continue
        if line.startswith("runs["):
            found, bad = True, True
        if inrows and line and line[0] in " \t":
            row = csv_row(line)
            if len(row) != 5:
                bad = True
            rows.append(row)
        elif inrows:
            inrows = False
    if not found:
        return "unavailable"
    ids, valid, unknown, live, first = [], True, False, 0, None
    for row in rows:
        if len(row) < 2 or row[1] != branch:
            continue
        if re.fullmatch(r"[A-Za-z0-9_-]+", row[0]):
            if row[0] in ids:
                valid = False
            else:
                ids.append(row[0])
        if len(row) != 5:
            continue
        if not (re.fullmatch(r"[A-Za-z0-9_-]+", row[0])
                and re.fullmatch(r"[a-z_-]+", row[2]) and re.fullmatch(r"[a-fA-F0-9]{7,40}", row[3])):
            valid = False
            continue
        if first is None:
            first = row
        live += row[2] in ("running", "pending")
        unknown |= row[2] not in ("pending", "running", *TERMINAL)
    names = ", ".join(ids)
    if bad or counts != 1 or len(rows) != expected or len(rows) != shown or total < shown:
        return "unknown|unreadable runs table; run ids: " + names
    if shown < total:
        return "incomplete|" + names
    if not valid:
        return "unknown|unreadable runs table; run ids: " + names
    if unknown:
        return "unknown|unrecognized run status; run ids: " + names
    if first is None:
        return "absent"
    if first[2] in ("running", "pending") and live > 1:
        return "unknown|competing live runs; run ids: " + names
    return "selected|" + first[0] + "|" + first[2] + "|" + names


def select_run(branch, text, database, timeout):
    selection = overview(branch, text)
    if not selection.startswith("incomplete|"):
        return selection
    ids = selection.partition("|")[2].split(", ") if selection.partition("|")[2] else []
    try:
        repos = [line[6:].strip() for line in text.splitlines() if line.startswith("repo: ")]
        if len(repos) != 1:
            raise ValueError("ambiguous repository")
        repo = json.loads(repos[0]) if repos[0].startswith('"') else repos[0]
        if not isinstance(repo, str) or not os.path.isabs(repo):
            raise ValueError("unverified repository")
        db = sqlite3.connect(Path(database).as_uri() + "?mode=ro", uri=True, timeout=timeout)
        try:
            db.execute("BEGIN")
            matched = db.execute("SELECT id FROM repos WHERE working_path = ?", (repo,)).fetchall()
            if len(matched) != 1:
                raise ValueError("repository identity not unique")
            rows = db.execute("SELECT id, branch, status, head_sha FROM runs WHERE repo_id = ? AND branch = ? "
                              "ORDER BY created_at DESC, id DESC", (matched[0][0], branch)).fetchmany(10001)
            if len(rows) > 10000:
                raise ValueError("same-branch inventory exceeds native row bound")
        finally:
            db.close()
        displayed = set(ids)
        for row in rows:
            if isinstance(row[0], str) and re.fullmatch(r"[A-Za-z0-9_-]+", row[0]) and row[0] not in ids:
                ids.append(row[0])
        if not displayed.issubset(row[0] for row in rows):
            raise ValueError("inventory contradicts display")
        for row in rows:
            if (not all(isinstance(v, str) for v in row) or not re.fullmatch(r"[A-Za-z0-9_-]+", row[0])
                    or row[1] != branch or not re.fullmatch(r"[a-z_-]+", row[2])
                    or not re.fullmatch(r"[a-fA-F0-9]{7,40}", row[3])):
                raise ValueError("invalid inventory row")
        captured = "count: {0} of {0} total\nruns[{0}]{{id,branch,status,head,pr}}:\n".format(len(rows))
        captured += "\n".join("  " + ",".join(json.dumps(v, ensure_ascii=False) for v in row) + ',""' for row in rows)
        return overview(branch, captured)
    except (ValueError, OSError, sqlite3.Error):
        return "unknown|complete same-branch run inventory unreadable; run ids: " + ", ".join(ids)


def head_matches(git, head):
    if not head:
        return False
    local, run = git("rev-parse", "HEAD"), git("rev-parse", "--verify", "--quiet", head + "^{commit}")
    return bool(local and run and (local == run or git.success("merge-base", "--is-ancestor", local, run)))


def ledger_status(git, branch, text, expected=""):
    local = git("rev-parse", "HEAD")
    if not local or not text:
        return ""
    pending = ""
    for line in text.splitlines():
        row = line.strip().split()
        if not row:
            continue
        if len(row) not in (5, 6):
            break
        status, recorded_branch, sha, day, clock = row[:5]
        if (not re.fullmatch(r"[a-z_-]+", status) or not re.fullmatch(r"[A-Za-z0-9._/-]+", recorded_branch)
                or not re.fullmatch(r"[a-fA-F0-9]{7,40}", sha) or not re.fullmatch(r"[0-9]{4}-[0-9]{2}-[0-9]{2}", day)
                or not re.fullmatch(r"(?:[01][0-9]|2[0-3]):[0-5][0-9]", clock)
                or (len(row) == 6 and not row[5].startswith("https://"))):
            break
        try:
            datetime.date.fromisoformat(day)
        except ValueError:
            break
        if recorded_branch != branch:
            continue
        resolved = git("rev-parse", "--verify", "--quiet", sha + "^{commit}")
        if pending:
            return pending if resolved == local else ""
        if expected and (not re.fullmatch(r"[a-fA-F0-9]{7,40}", expected)
                         or not (expected.startswith(sha) or sha.startswith(expected))):
            break
        if resolved:
            return status if head_matches(git, sha) else ""
        if status != "running":
            break
        pending = status
    return ""
