#!/usr/bin/env python3
"""Scheduled-run engine, run by bin/fm-schedule.sh (see its header for usage).

bin/fm-schedule.sh owns the commands, the timer and the home listing; this file
owns the schedule-file validation, the run record, the scan state machine, the
result-file reader, the one-line notifications and the summary the fleet board
reads. docs/configuration.md "Scheduled runs" owns the file formats.

Homes arrive in the --homes file as `<area>\t<home>\t<remote 0|1>` lines (main
first), the same listing bin/fm-board.sh builds. A remote home is never read.
"""

import argparse
import datetime
import fcntl
import json
import os
import re
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from fm_receipt_io import atomic_text  # noqa: E402

CONF_SCHEMA = "fm-schedule/v1"
RUN_SCHEMA = "fm-schedule-run/v1"
RESULT_SCHEMA = "fm-schedule-result/v1"
SUMMARY_SCHEMA = "fm-schedule-summary/v1"
CONF_KEYS = {"schema", "name", "calendar", "kind", "title", "brief", "approval"}
CONF_OPTIONAL = {"repo"}
RESULT_KEYS = {"schema", "started", "ended", "used_seconds", "outcome", "cut_reason",
               "carried_over", "note"}
RESULT_OPTIONAL = {"budget_seconds", "report"}
OUTCOMES = {"complete", "cut-short", "failed"}
CUT_REASONS = {"none", "job-cap", "weekly-budget", "other"}
NAME_RE = re.compile(r"^[a-z0-9](?:[a-z0-9-]{0,38}[a-z0-9])?$")
APPROVAL_RE = re.compile(r"^\S.*\s(\d{4}-\d{2}-\d{2}(?:T\d{2}:\d{2}(?::\d{2})?Z)?)$")
ISO_RE = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$")
CONF_MAX = 8192
BRIEF_MAX = 65536
RESULT_MAX = 8192
RESULTS_KEPT = 12
FAILURES_TO_PAUSE = 2
# A run that fires more than this after its slot was caught up after downtime.
LATE_GRACE = 3600
MISSED_SCAN = 200
NOTICES_KEPT = 20


def fail(msg):
    print("fm-schedule: %s" % msg, file=sys.stderr)
    return 2


def one_line(text, n=600):
    text = re.sub(r"[\t\r\n]+", " ", str(text or "")).strip()
    return text if len(text) <= n else text[: n - 1] + "…"


def local(epoch):
    # A run record stores "no time" as "0" (a non-empty string), so test the number.
    if not epoch or int(epoch) <= 0:
        return "-"
    return time.strftime("%a %Y-%m-%d %H:%M %Z", time.localtime(int(epoch)))


def next_run(epoch):
    """The next slot in words; a calendar with no slot left (a passed one-time date) says so."""
    if not epoch or int(epoch) <= 0:
        return "none: its calendar has no slot after now"
    return local(epoch)


def slot_stamp(epoch):
    return time.strftime("%Y%m%d%H%M", time.localtime(int(epoch)))


def dur(seconds):
    if seconds is None:
        return "-"
    seconds = int(seconds)
    h, m = divmod(seconds // 60, 60)
    if h:
        return "%dh %02dm" % (h, m)
    if m:
        return "%dm" % m
    return "%ds" % seconds


def read_kv(path, limit):
    """Strict key=value reader: (dict, error). Blank and # lines are skipped."""
    if os.path.islink(path):
        return None, "symlink refused"
    try:
        with open(path, "rb") as fh:
            raw = fh.read(limit + 1)
    except OSError as err:
        return None, "unreadable (%s)" % type(err).__name__
    if len(raw) > limit:
        return None, "larger than %d bytes" % limit
    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError:
        return None, "not UTF-8"
    out = {}
    for n, line in enumerate(text.splitlines(), 1):
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        if "=" not in line:
            return None, "line %d is not key=value" % n
        key, value = line.split("=", 1)
        key = key.strip()
        if not re.match(r"^[a-z_]+$", key):
            return None, "line %d has a bad key" % n
        if key in out:
            return None, "key %s appears twice" % key
        out[key] = value.strip()
    return out, None


def write_kv(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    lines = []
    for key in sorted(data):
        value = data[key]
        if value is None:
            continue
        lines.append("%s=%s" % (key, one_line(value, 2000)))
    atomic_text(path, "\n".join(lines) + "\n")


# ---------------------------------------------------------------- calendar

ELAPSE_RE = re.compile(r"^\s*(?:Next elapse|Iteration #\d+):\s*(.*)$")
UTC_RE = re.compile(r"^\s*\(in UTC\):\s*(.*)$")


def _utc_epoch(text):
    text = text.strip()
    if not text.endswith(" UTC"):
        return None
    try:
        dt = datetime.datetime.strptime(text, "%a %Y-%m-%d %H:%M:%S UTC")
    except ValueError:
        return None
    return int(dt.replace(tzinfo=datetime.timezone.utc).timestamp())


def elapses(calendar, base, count=1):
    """Up to <count> elapse epochs strictly after <base>; raises ValueError on a bad expression."""
    try:
        p = subprocess.run(["systemd-analyze", "calendar", "--base-time=@%d" % int(base),
                            "--iterations=%d" % count, "--", calendar],
                           text=True, capture_output=True, timeout=20)
    except FileNotFoundError:
        raise ValueError("systemd-analyze is not installed")
    except subprocess.TimeoutExpired:
        raise ValueError("systemd-analyze timed out")
    if p.returncode != 0:
        raise ValueError(one_line(p.stderr or p.stdout or "not a systemd calendar expression", 200))
    found = []
    for line in p.stdout.splitlines():
        m = ELAPSE_RE.match(line)
        if m:
            found.append(m.group(1).strip())
            continue
        m = UTC_RE.match(line)
        if m and found:
            found[-1] = m.group(1).strip()
    out = []
    for text in found:
        if text == "never":
            break
        epoch = _utc_epoch(text)
        if epoch is None:
            raise ValueError("cannot read the elapse time %r" % text)
        if epoch > base:
            out.append(epoch)
    return out


def next_after(calendar, base):
    got = elapses(calendar, base, 1)
    return got[0] if got else None


# ---------------------------------------------------------------- schedule files

def load_conf(home, path):
    stem = os.path.basename(path)[: -len(".conf")]
    conf = {"file": path, "stem": stem, "error": None}
    data, err = read_kv(path, CONF_MAX)
    if err:
        conf["error"] = err
        return conf
    conf.update({k: data.get(k) for k in CONF_KEYS | CONF_OPTIONAL})
    unknown = sorted(set(data) - CONF_KEYS - CONF_OPTIONAL)
    missing = sorted(k for k in CONF_KEYS if not data.get(k))
    if unknown:
        conf["error"] = "unknown key %s" % ", ".join(unknown)
    elif missing:
        conf["error"] = "missing %s" % ", ".join(missing)
    elif data["schema"] != CONF_SCHEMA:
        conf["error"] = "schema is %r, expected %s" % (data["schema"], CONF_SCHEMA)
    elif not NAME_RE.match(data["name"]) or data["name"] != stem:
        conf["error"] = "name must equal the file name and be 1-40 of a-z, 0-9, -"
    elif data["kind"] not in ("ship", "scout"):
        conf["error"] = "kind must be ship or scout"
    elif not APPROVAL_RE.match(data["approval"]):
        conf["error"] = "approval must be '<who> <YYYY-MM-DD[THH:MM[:SS]Z]>'"
    elif "repo" in data and not re.match(r"^[A-Za-z0-9._-]+$", data["repo"]):
        conf["error"] = "repo must be a plain project name"
    if conf["error"]:
        return conf
    brief = data["brief"]
    brief_path = brief if brief.startswith("/") else os.path.join(home, brief)
    conf["brief_path"] = brief_path
    if os.path.islink(brief_path) or not os.path.isfile(brief_path):
        conf["error"] = "brief %s is not a regular file" % brief
    elif os.path.getsize(brief_path) > BRIEF_MAX:
        conf["error"] = "brief %s is larger than %d bytes" % (brief, BRIEF_MAX)
    if conf["error"]:
        return conf
    try:
        elapses(data["calendar"], int(time.time()), 1)
    except ValueError as err:
        conf["error"] = "calendar refused: %s" % err
    return conf


def load_confs(home):
    d = os.path.join(home, "config", "schedules.d")
    if not os.path.isdir(d):
        return []
    out = []
    for fn in sorted(os.listdir(d)):
        if fn.endswith(".conf") and not fn.startswith("."):
            out.append(load_conf(home, os.path.join(d, fn)))
    return out


# ---------------------------------------------------------------- run records

def rec_path(home, name):
    return os.path.join(home, "state", "schedules", name + ".run")


def load_rec(home, name):
    data, err = read_kv(rec_path(home, name), 16384)
    if err or data.get("schema") != RUN_SCHEMA:
        return {"schema": RUN_SCHEMA}
    return data


def ival(rec, key, default=0):
    try:
        return int(rec.get(key) or default)
    except ValueError:
        return default


def result_path(home, name, task):
    return os.path.join(home, "data", "schedules", name, task + ".result")


def read_result(path):
    """(dict, error) for a result file; (None, None) when it does not exist."""
    if not os.path.lexists(path):
        return None, None
    data, err = read_kv(path, RESULT_MAX)
    if err:
        return None, err
    unknown = sorted(set(data) - RESULT_KEYS - RESULT_OPTIONAL)
    missing = sorted(k for k in RESULT_KEYS if k not in data)
    if unknown:
        return None, "unknown key %s" % ", ".join(unknown)
    if missing:
        return None, "missing %s" % ", ".join(missing)
    if data["schema"] != RESULT_SCHEMA:
        return None, "schema is not %s" % RESULT_SCHEMA
    for key in ("started", "ended"):
        if not ISO_RE.match(data[key]):
            return None, "%s must be YYYY-MM-DDTHH:MM:SSZ" % key
    for key in ("used_seconds", "carried_over", "budget_seconds"):
        if key in data and not re.match(r"^\d{1,9}$", data[key]):
            return None, "%s must be a whole number" % key
    if data["outcome"] not in OUTCOMES:
        return None, "outcome must be complete, cut-short or failed"
    if data["cut_reason"] not in CUT_REASONS:
        return None, "cut_reason must be none, job-cap, weekly-budget or other"
    if (data["outcome"] == "cut-short") != (data["cut_reason"] != "none"):
        return None, "cut_reason is none exactly when the outcome is not cut-short"
    if "report" in data and not data["report"].startswith("/"):
        return None, "report must be an absolute path"
    return data, None


def prune_results(home, name):
    d = os.path.join(home, "data", "schedules", name)
    try:
        files = sorted(f for f in os.listdir(d) if f.endswith(".result"))
    except OSError:
        return
    for f in files[:-RESULTS_KEPT]:
        try:
            os.unlink(os.path.join(d, f))
        except OSError:
            pass


# ---------------------------------------------------------------- side effects

class Env:
    def __init__(self, code_root, main_home, now):
        self.code_root = code_root
        self.main = main_home
        self.now = now

    def tool(self, home, name):
        own = os.path.join(home, "bin", name)
        if os.path.isfile(own) and os.access(own, os.X_OK):
            return own
        return os.path.join(self.code_root, "bin", name)

    def run(self, home, argv, stdin=None):
        env = dict(os.environ, FM_HOME=home)
        for k in ("FM_DATA_OVERRIDE", "FM_STATE_OVERRIDE", "FM_CONFIG_OVERRIDE", "TASKS_AXI_FILE"):
            env.pop(k, None)
        try:
            p = subprocess.run(argv, text=True, capture_output=True, env=env, input=stdin,
                               timeout=60, cwd=home)
        except (OSError, subprocess.TimeoutExpired) as err:
            return 127, "", type(err).__name__
        return p.returncode, p.stdout, p.stderr

    def task_state(self, home, task):
        """queued|in_flight|held|done|... ; 'gone' when not found; None when unreadable."""
        rc, out, err = self.run(home, [self.tool(home, "fm-tasks-axi.sh"), "show", task])
        if rc != 0:
            return "gone" if "NOT_FOUND" in (out + err) else None
        for line in out.splitlines():
            m = re.match(r"^\s*state:\s*(\S+)\s*$", line)
            if m:
                return m.group(1).strip('"')
        return None

    def file_task(self, home, conf, task, title, body):
        tmp = os.path.join(home, "state", "schedules", ".%s.body" % conf["name"])
        atomic_text(tmp, body)
        argv = [self.tool(home, "fm-tasks-axi.sh"), "add", task, title, "--kind", conf["kind"],
                "--body-file", tmp, "--json"]
        if conf.get("repo"):
            argv[5:5] = ["--repo", conf["repo"]]
        rc, out, err = self.run(home, argv)
        try:
            os.unlink(tmp)
        except OSError:
            pass
        return rc == 0, one_line(err or out, 300)

    def inbox_note(self, home, request_id, text, saved_is_enough=False):
        """True once the note is saved and announced; exit 3 is saved but not announced,
        which a durable notice accepts and a wake retries (a replay re-announces it)."""
        rc, out, err = self.run(home, [self.tool(home, "fm-inbox.sh"), "note", "--request-id",
                                       request_id, "--", text])
        return rc == 0 or (saved_is_enough and rc == 3), one_line(err or out, 300)

    def notify(self, home, area, verb, key, text):
        """One line to main firstmate: the parent channel from a mate, main's inbox at main."""
        line = "%s [key=%s]: %s" % (verb, key, one_line(text, 1000))
        if os.path.realpath(home) != os.path.realpath(self.main):
            lib = os.path.join(self.code_root, "bin", "fm-parent-channel-lib.sh")
            rc, out, err = self.run(home, ["bash", "-c",
                                           '. "$1" && fm_parent_channel_report "$2" "$2/state" "$3"',
                                           "fm-schedule", lib, home, line])
            if rc == 0:
                return True, ""
            if rc != 1:
                return False, "parent channel refused (rc %d) %s" % (rc, one_line(err, 200))
        ok, why = self.inbox_note(self.main, key, "Scheduled run notice (%s): %s" % (area, line),
                                  saved_is_enough=True)
        return ok, why


def queue_notice(home, name, verb, key, text):
    path = os.path.join(home, "state", "schedules", name + ".notices")
    try:
        with open(path, encoding="utf-8") as fh:
            lines = [ln for ln in fh.read().splitlines() if ln.strip()]
    except OSError:
        lines = []
    entry = json.dumps({"verb": verb, "key": key, "text": one_line(text, 1000)}, sort_keys=True)
    if entry not in lines:
        lines.append(entry)
    atomic_text(path, "\n".join(lines[-NOTICES_KEPT:]) + "\n")


def flush_notices(env, home, area, name):
    path = os.path.join(home, "state", "schedules", name + ".notices")
    try:
        with open(path, encoding="utf-8") as fh:
            lines = [ln for ln in fh.read().splitlines() if ln.strip()]
    except OSError:
        return []
    left, problems = [], []
    for ln in lines:
        try:
            n = json.loads(ln)
            ok, why = env.notify(home, area, n["verb"], n["key"], n["text"])
        except (ValueError, KeyError, TypeError):
            continue
        if not ok:
            left.append(ln)
            problems.append(why)
    if left:
        atomic_text(path, "\n".join(left) + "\n")
    else:
        os.unlink(path)
    return problems


# ---------------------------------------------------------------- scan

def describe_result(rec):
    out = rec.get("last_outcome") or "-"
    if out == "cut-short":
        out = "cut short (%s)" % (rec.get("cut_reason") or "other")
    return out


def close_text(name, area, rec):
    task = rec.get("last_task")
    head = "scheduled run %s (home %s, task %s)" % (name, area, task)
    outcome = rec.get("last_outcome")
    if outcome == "no-summary":
        text = "%s closed with no run summary: opened %s, closed by %s" % (
            head, local(rec.get("last_fired")), local(rec.get("closed_seen")))
    else:
        used = "used %s" % dur(ival(rec, "used_seconds"))
        if rec.get("budget_seconds"):
            used += " of %s budget" % dur(ival(rec, "budget_seconds"))
        if outcome == "complete":
            text = "%s complete, not interrupted: %s" % (head, used)
        elif outcome == "cut-short":
            text = "%s interrupted mid run, cut short by %s: %s" % (head, rec.get("cut_reason"), used)
        else:
            text = "%s failed: %s" % (head, used)
        if rec.get("carried_over") not in (None, ""):
            text += ", carried over %s" % rec.get("carried_over")
        if rec.get("note"):
            text += "; %s" % rec.get("note")
        if rec.get("report"):
            text += "; report %s" % rec.get("report")
    if rec.get("caught_up") == "1":
        text += "; missed/caught-up: fired late after downtime, caught up once, %s missed slots not run" % (
            rec.get("missed") or "0")
    return text


def close_task(env, home, area, conf, rec, state):
    name = conf["name"]
    task = rec["last_task"]
    rec["last_task_state"] = state
    rec["closed_seen"] = str(env.now)
    for key in ("used_seconds", "budget_seconds", "cut_reason", "carried_over", "note", "report"):
        rec.pop(key, None)
    result, err = read_result(result_path(home, name, task))
    if err:
        rec["last_outcome"] = "failed"
        rec["note"] = "result file invalid: %s" % err
    elif result is None:
        rec["last_outcome"] = "no-summary"
        if state == "gone":
            rec["note"] = "task record no longer in the backlog"
    else:
        rec["last_outcome"] = result["outcome"]
        for key in ("used_seconds", "budget_seconds", "cut_reason", "carried_over", "report"):
            if key in result:
                rec[key] = result[key]
        rec["note"] = one_line(result.get("note"), 300)
    if rec["last_outcome"] == "failed":
        rec["consecutive_failures"] = str(ival(rec, "consecutive_failures") + 1)
    elif rec["last_outcome"] in ("complete", "cut-short"):
        rec["consecutive_failures"] = "0"
    verb = "failed" if rec["last_outcome"] == "failed" else "done"
    queue_notice(home, name, verb, "schedule-%s-%s" % (name, task), close_text(name, area, rec))
    prune_results(home, name)


def maybe_pause(home, area, name, rec, why, now):
    if ival(rec, "consecutive_failures") < FAILURES_TO_PAUSE or rec.get("paused") == "1":
        return
    rec["paused"] = "1"
    rec["paused_reason"] = why
    rec["paused_at"] = str(now)
    queue_notice(home, name, "blocked", "schedule-%s-paused" % name,
                 "scheduled run %s (home %s) paused-after-failures: %d failed runs in a row (%s); "
                 "nothing more is filed until bin/fm-schedule.sh resume %s %s"
                 % (name, area, FAILURES_TO_PAUSE, why, area, name))


def task_title(conf, slot):
    return "%s (scheduled %s)" % (one_line(conf["title"], 120), time.strftime("%Y-%m-%d %H:%M", time.localtime(slot)))


def task_body(home, conf, slot, task):
    with open(conf["brief_path"], encoding="utf-8", errors="replace") as fh:
        brief = fh.read()
    return ("Scheduled run %s from %s, slot %s.\n"
            "This is a captain-approved scheduled run (approval: %s); it counts as captain-routed work.\n\n"
            "When the run ends, write its summary to:\n  %s\n"
            "in the %s format (docs/configuration.md \"Scheduled runs\"). The scheduler reads it once this "
            "task is closed and sends one line to the main firstmate.\n\n"
            "Brief:\n%s"
            % (conf["name"], conf["file"], local(slot), conf["approval"],
               result_path(home, conf["name"], task), RESULT_SCHEMA, brief))


def scan_one(env, home, area, conf):
    name = conf["name"]
    rec = load_rec(home, name)
    now = env.now
    if rec.get("calendar") != conf["calendar"] or not rec.get("next_due"):
        rec["calendar"] = conf["calendar"]
        nxt = next_after(conf["calendar"], now)
        rec["next_due"] = str(nxt or 0)
        write_kv(rec_path(home, name), rec)
        return rec
    rec["calendar"] = conf["calendar"]
    task = rec.get("last_task")
    if task and rec.get("last_task_state") not in ("done", "gone"):
        state = env.task_state(home, task)
        if state in ("done", "gone"):
            close_task(env, home, area, conf, rec, state)
            maybe_pause(home, area, name, rec, "last outcome failed", now)
        elif state:
            rec["last_task_state"] = state
            if rec.get("wake_pending") == "1":
                ok, _ = env.inbox_note(home, task, wake_text(conf, task, ival(rec, "last_slot")))
                if ok:
                    rec.pop("wake_pending", None)
    due = ival(rec, "next_due")
    if rec.get("paused") == "1" or not due or now < due:
        write_kv(rec_path(home, name), rec)
        return rec
    slot = due
    missed = len([t for t in elapses(conf["calendar"], slot, MISSED_SCAN) if t <= now])
    if task and rec.get("last_task_state") not in ("done", "gone"):
        rec["last_skip_slot"] = str(slot)
        rec["skipped_count"] = str(ival(rec, "skipped_count") + 1)
        rec["next_due"] = str(next_after(conf["calendar"], now) or 0)
        queue_notice(home, name, "done", "schedule-%s-skip-%s" % (name, slot_stamp(slot)),
                     "scheduled run %s (home %s) skipped-open: the %s slot was not run because the "
                     "previous task %s is still %s; nothing new was filed" % (name, area, local(slot), task, rec.get("last_task_state")))
        write_kv(rec_path(home, name), rec)
        return rec
    new_task = "sched-%s-%s" % (name, slot_stamp(slot))
    os.makedirs(os.path.dirname(result_path(home, name, new_task)), exist_ok=True)
    ok, why = env.file_task(home, conf, new_task, task_title(conf, slot), task_body(home, conf, slot, new_task))
    if not ok:
        rec["consecutive_failures"] = str(ival(rec, "consecutive_failures") + 1)
        rec["last_outcome"] = "failed"
        rec["note"] = "filing %s failed: %s" % (new_task, why)
        queue_notice(home, name, "failed", "schedule-%s-file-%s-%d" % (name, slot_stamp(slot),
                                                                       ival(rec, "consecutive_failures")),
                     "scheduled run %s (home %s) could not file task %s: %s; it retries on the next scan"
                     % (name, area, new_task, why))
        maybe_pause(home, area, name, rec, "filing failed", now)
        write_kv(rec_path(home, name), rec)
        return rec
    for key in ("used_seconds", "budget_seconds", "cut_reason", "carried_over", "note", "report",
                "closed_seen", "last_outcome"):
        rec.pop(key, None)
    rec.update({"last_slot": str(slot), "last_fired": str(now), "last_task": new_task,
                "last_task_state": "queued", "missed": str(missed),
                "caught_up": "1" if missed or now - slot > LATE_GRACE else "0",
                "next_due": str(next_after(conf["calendar"], now) or 0)})
    ok, _ = env.inbox_note(home, new_task, wake_text(conf, new_task, slot))
    if ok:
        rec.pop("wake_pending", None)
    else:
        rec["wake_pending"] = "1"
    write_kv(rec_path(home, name), rec)
    return rec


def wake_text(conf, task, slot):
    return ("Captain-approved scheduled run %s is due: backlog task %s was filed for the %s slot "
            "(approval: %s). Dispatch it as captain-routed work; its body names the run-summary file to write."
            % (conf["name"], task, local(slot), conf["approval"]))


# ---------------------------------------------------------------- rows, summary, list

def row(area, home, conf, rec):
    r = {"home": area, "home_path": home, "name": conf.get("name") or conf["stem"],
         "file": conf["file"], "valid": not conf["error"], "error": conf["error"]}
    if conf["error"]:
        r.update({"state": "invalid"})
        return r
    rec = rec or {}
    r.update({"kind": conf["kind"], "title": conf["title"], "calendar": conf["calendar"],
              "approval": conf["approval"],
              "next_due": ival(rec, "next_due") or None, "last_slot": ival(rec, "last_slot") or None,
              "last_fired": ival(rec, "last_fired") or None, "last_task": rec.get("last_task"),
              "task_state": rec.get("last_task_state"), "outcome": rec.get("last_outcome"),
              "used_seconds": ival(rec, "used_seconds", None) if rec.get("used_seconds") else None,
              "budget_seconds": ival(rec, "budget_seconds") or None,
              "cut_reason": rec.get("cut_reason"), "carried_over": rec.get("carried_over"),
              "note": rec.get("note"), "report": rec.get("report"),
              "closed_seen": ival(rec, "closed_seen") or None,
              "skipped_count": ival(rec, "skipped_count"), "last_skip_slot": ival(rec, "last_skip_slot") or None,
              "missed": ival(rec, "missed"), "caught_up": rec.get("caught_up") == "1",
              "consecutive_failures": ival(rec, "consecutive_failures"),
              "paused": rec.get("paused") == "1", "paused_reason": rec.get("paused_reason")})
    if r["paused"]:
        r["state"] = "paused"
    elif r["task_state"] and r["task_state"] not in ("done", "gone"):
        r["state"] = "running" if r["task_state"] == "in_flight" else "filed"
    else:
        r["state"] = "scheduled" if r["next_due"] else "no further runs"
    return r


def result_word(r):
    """The Result column, shared by `list` and the board."""
    if not r.get("valid"):
        return "invalid: %s" % r.get("error")
    out = r.get("outcome")
    if r.get("task_state") and r["task_state"] not in ("done", "gone"):
        return "open (%s)" % r["task_state"]
    if not out:
        return "-"
    if out == "no-summary":
        return "no run summary"
    if out == "complete":
        text = "complete"
    elif out == "cut-short":
        text = "cut short: %s" % (r.get("cut_reason") or "other")
    else:
        text = "failed"
    if r.get("used_seconds") is not None:
        text += ", used %s" % dur(r["used_seconds"])
        if r.get("budget_seconds"):
            text += " of %s" % dur(r["budget_seconds"])
    if r.get("carried_over") not in (None, ""):
        text += ", carried %s" % r["carried_over"]
    return text


def state_word(r):
    if not r.get("valid"):
        return "refused"
    words = ["paused-after-failures" if r["state"] == "paused" else r["state"]]
    if r.get("skipped_count"):
        words.append("skipped-open %d" % r["skipped_count"])
    if r.get("caught_up"):
        words.append("caught-up (%d missed)" % r.get("missed", 0))
    return ", ".join(words)


def what_word(r):
    if not r.get("valid"):
        return os.path.basename(r["file"])
    return "%s: %s" % (r["kind"], r["title"])


def last_word(r):
    if not r.get("valid") or not r.get("last_fired"):
        return "-"
    return "%s (%s)" % (local(r["last_fired"]), r.get("last_task"))


def gather(homes, env=None):
    rows = []
    for area, home, remote in homes:
        if remote:
            continue
        for conf in load_confs(home):
            rec = None
            if not conf["error"]:
                if env:
                    try:
                        rec = scan_one(env, home, area, conf)
                    except (OSError, ValueError) as err:
                        rec = load_rec(home, conf["name"])
                        conf = dict(conf, scan_error=one_line(str(err), 200))
                    flush_notices(env, home, area, conf["name"])
                else:
                    rec = load_rec(home, conf["name"])
            r = row(area, home, conf, rec)
            if conf.get("scan_error"):
                r["scan_error"] = conf["scan_error"]
            r["display"] = dict(zip(COLUMNS, display(r)))
            rows.append(r)
    return rows


# The table `list` prints and the board's Scheduled runs panel shows, column for column.
COLUMNS = ["Name", "Home", "What", "Next run", "Last run", "Result", "State"]


def display(r):
    return [r["name"], r["home"], what_word(r), local(r.get("next_due")), last_word(r),
            result_word(r), state_word(r)]


def print_table(rows):
    head = COLUMNS
    body = [[r["display"][c] for c in COLUMNS] for r in rows]
    if not body:
        print("No schedules: no home has a config/schedules.d/*.conf file.")
        return
    widths = [max(len(str(x[i])) for x in [head] + body) for i in range(len(head))]
    for line in [head] + body:
        print("  ".join(str(c).ljust(widths[i]) for i, c in enumerate(line)).rstrip())


def read_homes(path, main_home):
    homes = []
    try:
        with open(path, encoding="utf-8") as fh:
            text = fh.read()
    except OSError:
        text = ""
    for line in text.splitlines():
        parts = line.split("\t")
        if len(parts) == 3 and parts[0] and parts[1].startswith("/"):
            homes.append((parts[0], parts[1].rstrip("/"), parts[2] == "1"))
    return homes or [("main", main_home, False)]


def resolve_home(homes, area):
    for a, h, remote in homes:
        if a == area and not remote:
            return h
    return None


def main(argv=None):
    ap = argparse.ArgumentParser(description="Scheduled-run engine (use bin/fm-schedule.sh).")
    ap.add_argument("command", choices=["scan", "list", "validate", "resume"])
    ap.add_argument("args", nargs="*")
    ap.add_argument("--home", required=True)
    ap.add_argument("--homes", required=True)
    ap.add_argument("--code-root", required=True)
    ap.add_argument("--now", type=int, default=None)
    ap.add_argument("--json", action="store_true")
    a = ap.parse_args(argv)
    main_home = os.path.abspath(a.home)
    now = a.now if a.now is not None else int(time.time())
    homes = read_homes(a.homes, main_home)
    sdir = os.path.join(main_home, "state", "schedules")

    if a.command == "validate":
        bad = 0
        for area, home, remote in homes:
            if remote:
                continue
            for conf in load_confs(home):
                if conf["error"]:
                    bad += 1
                    print("refused %s: %s" % (conf["file"], conf["error"]))
                else:
                    print("ok      %s (next %s)" % (conf["file"], next_run(next_after(conf["calendar"], now))))
        return 1 if bad else 0

    if a.command == "list":
        rows = gather(homes)
        if a.json:
            print(json.dumps({"schema": SUMMARY_SCHEMA, "generated_epoch": now, "rows": rows},
                             indent=1, sort_keys=True))
        else:
            print_table(rows)
        return 0

    os.makedirs(sdir, exist_ok=True)
    lock = open(os.path.join(sdir, ".scan.lock"), "w")
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        print("fm-schedule: another scan holds the lock; nothing done")
        return 0
    env = Env(os.path.abspath(a.code_root), main_home, now)

    if a.command == "resume":
        if len(a.args) != 2:
            return fail("resume needs <home-area> <name>")
        area, name = a.args
        home = resolve_home(homes, area)
        if not home or not NAME_RE.match(name):
            return fail("no local home %r or bad schedule name %r" % (area, name))
        conf = load_conf(home, os.path.join(home, "config", "schedules.d", name + ".conf"))
        if conf["error"]:
            return fail("%s is refused: %s" % (conf["file"], conf["error"]))
        rec = load_rec(home, name)
        was = rec.get("paused") == "1"
        for key in ("paused", "paused_reason", "paused_at"):
            rec.pop(key, None)
        rec["consecutive_failures"] = "0"
        rec["calendar"] = conf["calendar"]
        rec["next_due"] = str(next_after(conf["calendar"], now) or 0)
        write_kv(rec_path(home, name), rec)
        if was:
            queue_notice(home, name, "resolved", "schedule-%s-paused" % name,
                         "scheduled run %s (home %s) resumed; next run %s" % (name, area, next_run(rec["next_due"])))
            flush_notices(env, home, area, name)
        print("resumed %s/%s; next run %s" % (area, name, next_run(rec["next_due"])))
        return 0

    rows = gather(homes, env)
    atomic_text(os.path.join(sdir, "summary.json"),
                json.dumps({"schema": SUMMARY_SCHEMA, "generated_epoch": now, "rows": rows},
                           indent=1, sort_keys=True) + "\n")
    for r in rows:
        if r.get("error"):
            print("refused %s: %s" % (r["file"], r["error"]), file=sys.stderr)
        if r.get("scan_error"):
            print("scan error %s/%s: %s" % (r["home"], r["name"], r["scan_error"]), file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
