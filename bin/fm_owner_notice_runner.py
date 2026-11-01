#!/usr/bin/env python3
"""Owner-notice automation internals, called by fm_owner_notice_store.py.

The shell front owns the runner mutex; the engine verifies its phase authority
and installed identity before entry. This module owns process records,
scheduling and deadlines; only recorded children touch
outboxes. docs/owner-notice.md owns the records and recovery contract.
"""
import os
import re
import select
import signal
import time

import fm_owner_notice_format as fmt
import fm_owner_notice_store as store
from fm_owner_notice_runtime import fields, publish, publish_fields, text

RUNNER_LOOP = 15
STAT_BOUND = 5
STAGE_BOUND = INGEST_BOUND = 60
KILL_GRACE = 5
FULL_SWEEP = 300
CHILD_EXIT_GRACE = 2
MTIME_SLACK = 2
ROLES = ("stat", "stage", "ingest")
STATE_ERRORS = (OSError, ValueError, KeyError, TypeError, OverflowError, store.Done)
MAX_EPOCH = 253402300799  # Last representable UTC second in year 9999.


def optional_json(path, bound=fmt.RECORD_BOUND):
    value = store.read_json(path, bound)
    if value is None and os.path.lexists(path):
        raise fmt.FormatError("null or dangling record: " + path)
    return value


def read_seen(owner, bid):
    value = text(owner.dir(bid, ".seen"))
    if value is None:
        return None
    if not re.fullmatch(r"[0-9]{1,20}\n", value):
        raise fmt.FormatError("invalid .seen")
    return int(value)


def read_routes(owner):
    expected = store.wanted_lists(owner)
    result = {}
    for name in (".bindings.list", ".retired.list"):
        if not os.path.lexists(os.path.join(owner.root, name)) and not expected[name]:
            rows = {}
        else:
            rows = store.list_lines(owner, name)
        for bid, lines in rows.items():
            if bid in result:
                raise fmt.FormatError("binding in both routing lists")
            parts = lines[0].rstrip("\n").split("\t")
            retired = len(parts) == 3
            epoch = int(parts[2]) if retired else 0
            if epoch > MAX_EPOCH:
                raise fmt.FormatError("invalid retired routing epoch")
            result[bid] = (parts[1], retired, retired and time.time() - epoch > store.RETIRED_SWEEP)
    if not result:
        if any(expected.values()):
            raise fmt.FormatError("empty routing does not withdraw a wanted binding")
        # An unreadable binding cannot prove that the retired window ended.
        for bid in store.binding_ids(owner):
            if not store.is_purged(owner, bid):
                store.load_binding(owner, bid)
    return result


def read_foreground(owner):
    if not os.path.lexists(owner.fg):
        return {}
    store.require_directory(owner.fg)
    records = {}
    for name in fmt.scandir_names(owner.fg, "runner"):
        record = optional_json(os.path.join(owner.fg, name))
        if (not isinstance(record, dict)
                or any(k not in record for k in ("pid", "starttime", "pgid", "binding", "started_at", "role"))
                or type(record["pid"]) is not int or not 1 < record["pid"] < 2**31
                or record["pgid"] != record["pid"] or not isinstance(record["starttime"], str)
                or not re.fullmatch(r"[0-9]{1,20}", record["starttime"])
                or not fmt.valid_name(record["binding"]) or record["role"] not in ROLES
                or type(record["started_at"]) is not int or not 0 <= record["started_at"] <= MAX_EPOCH
                or name != "%s-%s" % (record["pid"], record["starttime"])):
            raise fmt.FormatError("invalid foreground child record: " + name)
        records[name] = record
    return records


def read_problems(owner):
    value = optional_json(owner.dir("", ".quarantine"))
    if value is None:
        return {}
    if not isinstance(value, dict):
        raise fmt.FormatError("invalid quarantine map")
    for scope, row in value.items():
        if (scope not in ("routing", "foreground", "projection")
                and not (scope.startswith("binding:") and fmt.valid_name(scope[8:]))):
            raise fmt.FormatError("invalid quarantine scope")
        if (not isinstance(row, dict) or set(row) != {"reason", "since"}
                or not isinstance(row["reason"], str) or not row["reason"] or len(row["reason"]) > 512
                or type(row["since"]) is not int or not 0 <= row["since"] <= MAX_EPOCH):
            raise fmt.FormatError("invalid quarantine occurrence")
    return value


_INDEX_MTIMES = {}


def index_mtime(owner, bid):
    # The loop needs only this field, not a retained copy of thousands of
    # historical names. Atomic writer identity/size/mtime/ctime invalidates it.
    path = owner.dir(bid, ".outbox-index")
    try:
        st = os.lstat(path)
    except FileNotFoundError:
        _INDEX_MTIMES.pop(path, None)
        return None
    signature = (st.st_dev, st.st_ino, st.st_size, st.st_mtime_ns, st.st_ctime_ns, st.st_mode)
    cached = _INDEX_MTIMES.get(path)
    if cached and cached[0] == signature:
        return cached[1]
    value = optional_json(path, 64 << 20)  # Same bound as the index writer's prior-index read.
    if (not isinstance(value, dict) or value.get("schema") != fmt.INDEX_SCHEMA
            or value.get("binding_id") != bid or "mtime_ns" not in value
            or not (value["mtime_ns"] is None or type(value["mtime_ns"]) is int)):
        raise fmt.FormatError("invalid outbox index mtime source")
    _INDEX_MTIMES[path] = (signature, value["mtime_ns"])
    return value["mtime_ns"]


def binding_state(owner, bid, outbox=None):
    binding, _ = store.load_binding(owner, bid)
    if outbox is not None and binding["outbox"] != outbox:
        raise fmt.FormatError("routing outbox differs from binding")
    index_mtime(owner, bid)
    return dict(binding=binding, children=read_children(owner, bid), stalls=read_stalls(owner, bid),
                automation=read_automation(owner, bid), seen=read_seen(owner, bid))


def read_children(owner, bid):
    raw = text(owner.dir(bid, ".children"))
    records = {}
    if raw is None:
        return records
    if raw and not raw.endswith("\n"):
        raise fmt.FormatError("partial children record")
    for line in raw.splitlines():
        parts = line.split()
        if len(parts) != 6:
            raise fmt.FormatError("invalid children record")
        role, pid, start, pgid, began, run = parts
        if (role not in (ROLES if bid else ("ingest",)) or role in records
                or not all(re.fullmatch(r"[0-9]{1,20}", x) for x in (pid, start, pgid, began))
                or not 1 < int(pid) < 2**31 or int(began) > MAX_EPOCH
                or pid != pgid or not re.fullmatch(r"[0-9A-Za-z.-]+", run)):
            raise fmt.FormatError("invalid child identity")
        records[role] = dict(role=role, pid=int(pid), starttime=start, pgid=int(pgid),
                             started_at=int(began), run=run)
    return records


def batch_authorized(owner, bid, verb, pid, run):
    """Only a live recorded ingest front may defer its own internal command.

    A missing/empty slot is an ordinary manual call, never authority. Malformed
    records raise; callers must refuse and project automation-unreadable.
    """
    if verb not in ("maintain", "ingest-staged"):
        return False
    record = read_children(owner, bid).get("ingest")
    if not record or record["pid"] != pid or not fmt.identity_alive(pid, record["starttime"]):
        return False
    return record["run"] == run and (verb == "maintain") == (run == "-")


def read_stalls(owner, bid):
    raw = text(owner.dir(bid, ".stall"))
    result = {}
    if raw is None:
        return result
    if raw and not raw.endswith("\n"):
        raise fmt.FormatError("partial stall record")
    for line in raw.splitlines():
        parts = line.split()
        if (len(parts) != 3 or parts[0] not in (ROLES + ("fg",) if bid else ("ingest",))
                or parts[0] in result or not re.fullmatch(r"[0-9]{1,12}", parts[1])
                or int(parts[1]) > MAX_EPOCH):
            raise fmt.FormatError("invalid stall record")
        result[parts[0]] = (int(parts[1]), parts[2])
    return result


def read_automation(owner, bid):
    value = optional_json(owner.dir(bid, ".automation"))
    if value is None:
        return {"busy": {}, "failures": {}}
    if not isinstance(value, dict) or set(value) != {"busy", "failures"}:
        raise fmt.FormatError("invalid automation status")
    for kind, roles, field in (("busy", ("maintain", "ingest-staged"), "count"),
                                ("failures", ("stat", "stage", "maintain", "ingest-staged"), "reason")):
        rows = value[kind]
        if not isinstance(rows, dict) or set(rows) - set(roles):
            raise fmt.FormatError("invalid automation roles")
        for row in rows.values():
            if (not isinstance(row, dict) or set(row) != {field, "since"}
                    or type(row["since"]) is not int or not 0 <= row["since"] <= MAX_EPOCH
                    or (kind == "busy" and (type(row[field]) is not int or row[field] < 1))
                    or (kind == "failures" and (not isinstance(row[field], str) or not row[field]))):
                raise fmt.FormatError("invalid automation occurrence")
    return value


# Runs only inside the common recorded-spawn child, so registration and its
# native locks share the projector's deadline, identity and failure scope.
# No ambient flag changes public/manual sync-alarms or grants batch authority.
PROJECTION_COMMAND = r'''set -u
SCRIPT_DIR=$1; FM_HOME=$2; STATE=$FM_HOME/state
ROOT=$STATE/owner-notices; ALERT_STORE=$ROOT/alert-store.json
export FM_HOME
. "$SCRIPT_DIR/fm-wake-lib.sh"
. "$SCRIPT_DIR/fm-owner-notice-run-lib.sh"
runner_register || exit 70
exec "$SCRIPT_DIR/fm-owner-notice.sh" sync-alarms
'''


def projection_complete(data):
    """Consume the front's one canonical JSON line, not an on-disk record."""
    if not data.endswith(b'\n'):
        raise fmt.FormatError('partial projection response')
    result = fmt.parse_canonical(data[:-1])
    if not isinstance(result, dict) or set(result) != {'complete'} or type(result['complete']) is not bool:
        raise fmt.FormatError('invalid projection result')
    return result['complete']


def exit_detail(record, code):
    if code in (0, None):
        return ""
    return " detail=" + record.get("output", b"").decode("utf-8", "replace").replace("\n", " ").replace("\r", " ")


def signal_child(record, sig):
    if fmt.seams().role("unkillable", record["role"]):
        return
    if fmt.identity_alive(record["pid"], record["starttime"]):
        try:
            os.killpg(record["pgid"], sig)
        except ProcessLookupError:
            pass


class Binding:
    def __init__(self, runner, bid, outbox, retired):
        self.runner, self.owner, self.bid = runner, runner.owner, bid
        state = binding_state(self.owner, bid, outbox)
        self.binding = state["binding"]
        self.quarantined = False
        self.retired = retired
        self.removing = False
        self.expired = False
        self.children = state["children"]
        self.stalls = state["stalls"]
        self.fg = False
        self.latest = None
        self.dirty = None
        self.manifest = None
        self.pending = None
        self.retry_at = 0
        self.automation = state["automation"]
        self.maintenance = True
        self.last_sweep = 0
        self.again = False
        self.seen = state["seen"]
        for role, rec in list(self.children.items()):
            if not fmt.identity_alive(rec["pid"], rec["starttime"]):
                del self.children[role]
                continue
            rec.update(adopted=time.time(), term=False, killed=False)
            self.event("adopted %s pid=%s starttime=%s started_at=%s" %
                       (role, rec["pid"], rec["starttime"], rec["started_at"]))
        self.save_children()

    def adopt_records(self, records):
        for role, rec in list(self.children.items()):
            incoming = records.get(role)
            if (fmt.identity_alive(rec["pid"], rec["starttime"])
                    and (not incoming or (incoming["pid"], incoming["starttime"]) != (rec["pid"], rec["starttime"]))):
                raise fmt.FormatError("live known child missing from repaired ownership: " + role)
            if incoming is None and not fmt.identity_alive(rec["pid"], rec["starttime"]):
                if "adopted" not in rec and "exit" not in rec:
                    try:
                        os.waitpid(rec["pid"], os.WNOHANG)
                    except ChildProcessError:
                        pass
                for key in ("fd", "request", "answer"):
                    if key in rec:
                        os.close(rec[key])
                del self.children[role]
        for role, rec in records.items():
            old = self.children.get(role)
            if old and (old["pid"], old["starttime"]) == (rec["pid"], rec["starttime"]):
                continue
            if old:
                self.passive()
                for key in ("fd", "request", "answer"):
                    if key in old:
                        os.close(old[key])
                self.children.pop(role)
            if fmt.identity_alive(rec["pid"], rec["starttime"]):
                rec.update(adopted=time.time(), term=False, killed=False)
                self.children[role] = rec
                self.event("adopted %s pid=%s after repair" % (role, rec["pid"]))
        if self.quarantined:
            for rec in self.children.values():
                # Retry only this confirmed role's overdue actions. An earlier
                # failed status publication must not hide a surviving child.
                rec["term"] = rec["killed"] = False

    def revalidate(self, outbox):
        state = binding_state(self.owner, self.bid, outbox)
        if state["binding"] != self.binding:
            raise fmt.FormatError("immutable binding changed under live runner")
        self.adopt_records(state["children"])
        self.stalls, self.automation, self.seen = state["stalls"], state["automation"], state["seen"]
        if self.quarantined:
            # Re-establish publication too; readable-but-unwritable state is
            # not recovery from a failed record update. All inputs validated.
            self.save_children()
            self.save_stalls()
            self.save_status()
        self.quarantined = False

    def passive(self):
        # Keep pipe/backpressure and zombie ownership bounded while frozen.
        # Do not signal, replace records, or infer success from disappearance.
        for rec in self.children.values():
            if "fd" in rec and not rec.get("eof"):
                self.drain(rec)
            if "adopted" not in rec and "exit" not in rec:
                try:
                    pid, status = os.waitpid(rec["pid"], os.WNOHANG)
                    if pid:
                        rec["exit"] = os.waitstatus_to_exitcode(status)
                except ChildProcessError:
                    rec["exit"] = None

    def event(self, msg):
        store.log(self.owner, self.bid, msg, "owner automation", "continue bounded scheduling")

    def save_children(self):
        read_children(self.owner, self.bid)  # Never replace an unreadable ownership record.
        data = "".join("%s %s %s %s %s %s\n" % (role, r["pid"], r["starttime"], r["pgid"],
                                                r["started_at"], r["run"])
                       for role, r in sorted(self.children.items()))
        publish(self.owner, self.owner.dir(self.bid, ".children"), data, "o-children-dirsync")

    def stall(self, role, since, run="-"):
        if role in self.stalls:
            return
        self.stalls[role] = (int(since), run)
        self.save_stalls()
        self.event("stall %s since=%s" % (role, int(since)))
        self.runner.sync_due = True

    def clear(self, roles):
        for role in roles:
            if role in self.stalls:
                del self.stalls[role]
                self.save_stalls()
                self.event("stall-clear " + role)
                self.runner.sync_due = True

    def save_stalls(self):
        read_stalls(self.owner, self.bid)
        publish(self.owner, self.owner.dir(self.bid, ".stall"),
                "".join("%s %s %s\n" % (r, v[0], v[1]) for r, v in sorted(self.stalls.items())))

    def fds(self):
        return [r[k] for r in self.children.values() for k in ("fd", "request", "answer") if k in r]

    def spawn(self, role, run, work, extra_close=()):
        read_children(self.owner, self.bid)
        def record(rec):
            rec["run"] = run
            self.children[role] = rec
            self.save_children()
        rec, fd = store.spawn_recorded_child(self.owner, role, "runner", self.bid,
                                             self.binding["outbox"], work, record,
                                             self.runner.fds() + list(extra_close))
        rec.update(fd=fd, term=False, killed=False)
        self.event("spawn %s pid=%s run=%s" % (role, rec["pid"], run))
        return rec

    def stat_start(self):
        req_r, req_w = os.pipe()
        ans_r, ans_w = os.pipe()
        def work():
            while os.read(req_r, 1):
                try:
                    st = os.stat(self.binding["outbox"], follow_symlinks=False)
                    row = "%s %s %s\n" % (st.st_mtime_ns, st.st_dev, st.st_ino)
                except OSError:
                    row = "error\n"
                os.write(ans_w, row.encode())
            return {}
        try:
            rec = self.spawn("stat", "-", work, (req_w, ans_r))
        except BaseException:
            for fd in (req_r, req_w, ans_r, ans_w):
                os.close(fd)
            raise
        os.close(req_r)
        os.close(ans_w)
        os.set_blocking(ans_r, False)
        rec.update(request=req_w, answer=ans_r, asked=None, buffer=b"")
        return rec

    def stat_request(self, tick):
        if self.fg or self.retired or self.removing or not self.runner.allow_io:
            return
        rec = self.children.get("stat") or self.stat_start()
        if "adopted" in rec or rec.get("asked") is not None or rec["killed"]:
            return
        try:
            os.write(rec["request"], b"1")
            rec["asked"] = tick
        except BrokenPipeError:
            self.set_failure("stat", "stat worker exited before request")
            self.runner.sync_due = True

    def stat_answer(self, rec):
        try:
            data = os.read(rec["answer"], 4096)
        except BlockingIOError:
            return
        rec["buffer"] += data
        if not data or len(rec["buffer"]) > 128:
            self.set_failure("stat", "invalid stat reply")
            signal_child(rec, signal.SIGKILL)
            rec["killed"] = True
            return
        if b"\n" not in rec["buffer"]:
            return
        line, rec["buffer"] = rec["buffer"].split(b"\n", 1)
        rec["asked"] = None
        if line == b"error":
            self.set_failure("stat", "outbox stat failed")
            self.runner.sync_due = True
            return
        nums = line.split()
        if len(nums) != 3 or not all(re.fullmatch(rb"[0-9]{1,20}", x) for x in nums):
            self.set_failure("stat", "invalid stat reply")
            signal_child(rec, signal.SIGKILL)
            rec["killed"] = True
            return
        self.latest, dev, ino = map(int, nums)
        if (dev, ino) != (self.binding["outbox_dev"], self.binding["outbox_ino"]):
            self.set_failure("stat", "outbox identity changed")
            self.runner.sync_due = True
        else:
            self.set_failure("stat", None)
        self.clear(("stat", "fg"))
        equal = index_mtime(self.owner, self.bid) == self.latest
        self.dirty = None if equal else self.dirty or int(time.time())
        publish_fields(self.owner, self.owner.dir(self.bid, ".beat"), {
            "writer": "runner", "epoch": int(time.time()), "runner_pid": self.runner.front,
            "runner_starttime": self.runner.front_start, "watcher_pid": self.runner.watcher,
            "watcher_identity": self.runner.watcher_identity, "attempt": self.runner.attempt,
            "outbox_mtime_ns": self.latest, "dirty_since": self.dirty or "-"})

    def run_front(self, command, run="-"):
        argv = [os.path.join(store.HERE, "fm-owner-notice.sh"), command]
        if command != "sync-alarms":
            argv.append(self.bid)
        if command == "ingest-staged":
            argv.append(run)
        registering = command == 'sync-alarms' and not self.registered
        def work():
            env = dict(os.environ, FM_HOME=self.owner.home)
            if registering:
                os.execvpe('bash', ['bash', '-c', PROJECTION_COMMAND, '_', store.HERE, self.owner.home], env)
            os.execve(argv[0], argv, env)
        rec = self.spawn("ingest", run, work)
        rec["command"] = command
        rec["registering"] = registering
        self.event(command + " start")

    def schedule(self, tick):
        if self.runner.routing is None:
            return  # Only projection may run against unknown routing membership.
        if self.removing or "stage" in self.children or "ingest" in self.children or tick < self.retry_at:
            return
        if self.pending:
            if tick >= self.retry_at:
                self.run_front("ingest-staged", self.pending)
            return
        if self.maintenance:
            self.run_front("maintain")
            return
        if self.runner.starting or self.fg or self.expired or not self.runner.allow_io:
            return
        full = tick - self.last_sweep >= self.runner.full_sweep
        if not (full or self.again or (not self.retired and self.latest is not None and self.latest != self.seen)):
            return
        # An active binding must have a completed stat before stage starts;
        # a stalled stat never launches another producer-path operation.
        stat_rec = self.children.get("stat", {})
        if not self.retired and (self.latest is None or stat_rec.get("killed") or "adopted" in stat_rec):
            return
        run = "%s-%s-%s" % (self.runner.front, self.runner.front_start, os.urandom(6).hex())
        self.last_sweep = tick
        self.again = False
        self.spawn("stage", run, lambda: store.stage(self.owner, self.bid, run, self.binding) and {})

    def drain(self, rec):
        try:
            data = os.read(rec["fd"], 65536)
        except BlockingIOError:
            return
        rec["output"] = (rec.get("output", b"") + data)[:4096]
        if not data:
            rec["eof"] = True

    def finished(self, role, rec, code):
        if "fd" in rec:
            self.drain(rec)
        for key in ("fd", "request", "answer"):
            if key in rec:
                os.close(rec[key])
        del self.children[role]
        self.save_children()
        self.event("exit %s pid=%s code=%s%s" % (role, rec["pid"], code, exit_detail(rec, code)))
        if role == "stat":
            self.set_failure("stat", "stat worker exited: %s" % code)
            return
        if role == "stage":
            # Adopted completions have no wait status. Only a complete manifest
            # can authorize ingest; it is validated again under the binding lock.
            try:
                manifest = store.read_json(self.owner.dir(self.bid, ".tmp", rec["run"], "manifest.json"), 64 << 20)
                if manifest is not None and not isinstance(manifest, dict):
                    raise fmt.FormatError("invalid stage manifest")
            except STATE_ERRORS as exc:
                self.set_failure("stage", "stage result unreadable: %s" % exc)
                self.retry_at = time.time() + self.runner.loop
                return
            if manifest and (manifest.get("complete") or manifest.get("code")) and code in (0, None):
                self.pending, self.manifest = rec["run"], manifest
            else:
                self.set_failure("stage", "stage failed: %s" % code)
                self.retry_at = time.time() + self.runner.loop
            self.runner.sync_due = True
            return
        command = rec.get("command", "ingest-staged" if rec["run"] != "-" else "maintain")
        self.set_busy(command, code == 75)
        if code == 75:
            self.retry_at = time.time() + self.runner.loop
            self.event("%s busy count=%s" % (command, self.automation["busy"][command]["count"]))
        elif code == 0:
            self.set_failure(command, None)
            stalled = self.stalls.get("ingest")
            if stalled and (stalled[1] == "-") == (command == "maintain"):
                self.clear(("ingest",))
            if command == "maintain":
                self.maintenance = False
            else:
                # A stage cycle completes only after its corresponding ingest,
                # not merely when the stage child disappears (R-U2-30).
                self.clear(("stage",))
                self.set_failure("stage", None)
                m = self.manifest
                if m:
                    self.again = bool(m["cap_hit"] or self.latest != m["mtime_ns"])
                    if m["cap_hit"]:
                        self.event("cap-hit")
                    if (m["complete"] and not m["cap_hit"] and m["mtime_ns"] is not None
                            and m["listed_at"] * 10**9 - m["mtime_ns"] > MTIME_SLACK * 10**9):
                        self.seen = m["mtime_ns"]
                        publish(self.owner, self.owner.dir(self.bid, ".seen"), str(self.seen) + "\n")
                self.pending = self.manifest = None
        else:
            self.set_failure(command, "%s failed: %s" % (command, code))
            self.pending = self.manifest = None
            self.retry_at = time.time() + self.runner.loop
        self.save_status()
        self.runner.sync_due = True

    def set_failure(self, role, reason):
        rows = self.automation["failures"]
        old = rows.get(role)
        if reason:
            rows[role] = {"reason": reason, "since": old["since"] if old else int(time.time())}
        else:
            rows.pop(role, None)
        if rows.get(role) != old:
            self.event("failure %s %s" % (role, reason or "cleared"))
            self.save_status()
            self.runner.sync_due = True

    def set_busy(self, command, busy):
        rows = self.automation["busy"]
        old = rows.get(command, {"count": 0})
        if busy:
            count = old["count"] + 1
            rows[command] = {"count": count, "since": old["since"] if old["count"] >= 3 else int(time.time())}
        else:
            rows.pop(command, None)
        self.save_status()

    def maintenance_waiting(self):
        if self.runner.routing is None:
            return False
        # Only inability to finish the announce pass can release its gate.
        # A failing stat is independent: maintenance must still get its turn.
        blocked = any(role in self.children and role in self.stalls for role in ("stage", "ingest"))
        busy = self.automation["busy"]
        return self.maintenance and not (blocked or "maintain" in self.automation["failures"]
            or busy.get("maintain", {}).get("count", 0) >= 3
            or (self.pending and busy.get("ingest-staged", {}).get("count", 0) >= 3))

    def save_status(self):
        read_automation(self.owner, self.bid)
        store.write_json(self.owner.dir(self.bid, ".automation"), self.automation,
                         self.owner.tmp, "o-automation-dirsync")

    def poll(self, tick):
        for role, rec in list(self.children.items()):
            code = None
            if "exit" in rec:
                self.finished(role, rec, rec["exit"])
                continue
            if "adopted" not in rec:
                try:
                    pid, status = os.waitpid(rec["pid"], os.WNOHANG)
                except ChildProcessError:
                    self.finished(role, rec, None)
                    continue
                if pid:
                    code = os.waitstatus_to_exitcode(status)
                    self.finished(role, rec, code)
                    continue
            elif not fmt.identity_alive(rec["pid"], rec["starttime"]):
                self.finished(role, rec, None)
                continue
            if role == "stat":
                if "answer" in rec:
                    self.stat_answer(rec)
                since = rec.get("adopted", rec.get("asked"))
                if since is not None and tick - since >= self.runner.stat_bound and not rec["killed"]:
                    self.stall("stat", since)
                    signal_child(rec, signal.SIGKILL)
                    rec["killed"] = True
                continue
            bound = self.runner.stage_bound if role == "stage" else self.runner.ingest_bound
            if tick >= rec["started_at"] + bound and not rec["term"]:
                signal_child(rec, signal.SIGTERM)
                rec["term"] = True
                self.event("term %s pid=%s" % (role, rec["pid"]))
            if tick >= rec["started_at"] + bound + self.runner.kill_grace and not rec["killed"]:
                signal_child(rec, signal.SIGKILL)
                rec["killed"] = True
                self.event("kill %s pid=%s" % (role, rec["pid"]))
                if fmt.identity_alive(rec["pid"], rec["starttime"]):
                    self.stall(role, rec["started_at"], rec["run"])
                failure_role = role if role == "stage" else rec.get(
                    "command", "maintain" if rec["run"] == "-" else "ingest-staged")
                self.set_failure(failure_role, "%s exceeded deadline" % role)
                self.runner.sync_due = True


class Projection(Binding):
    """Home-wide snapshot slot: a stuck binding must not suppress its own alarm.

    Uses the same recorded ingest child and deadlines, in root/.children rather
    than a binding's slot. It never touches producer paths or mutation locks.
    """
    def __init__(self, runner):
        self.runner, self.owner, self.bid = runner, runner.owner, ""
        self.binding = {"outbox": ""}
        self.quarantined = False
        self.children = read_children(self.owner, "")
        self.stalls = read_stalls(self.owner, "")
        self.registered = False
        self.retry_at = 0
        for role, rec in list(self.children.items()):
            if not fmt.identity_alive(rec["pid"], rec["starttime"]):
                del self.children[role]
            else:
                rec.update(adopted=time.time(), term=False, killed=False, command="sync-alarms")
                self.event("adopted %s pid=%s starttime=%s started_at=%s" %
                           (role, rec["pid"], rec["starttime"], rec["started_at"]))
        self.save_children()

    def revalidate(self, outbox=None):
        children = read_children(self.owner, "")
        stalls = read_stalls(self.owner, "")
        self.adopt_records(children)
        self.stalls = stalls
        if self.quarantined:
            self.save_children()
            self.save_stalls()
        self.quarantined = False

    def set_failure(self, role, reason):
        # Root projection alone owns this occurrence, not binding status.
        if reason:
            rec = self.children.get("ingest")
            self.stall("ingest", rec["started_at"] if rec else time.time())
            self.release_start(False)

    def release_start(self, success):
        self.runner.release_start(success)

    def finished(self, role, rec, code):
        if "fd" in rec:
            self.drain(rec)
        for key in ("fd", "request", "answer"):
            if key in rec:
                os.close(rec[key])
        del self.children[role]
        self.save_children()
        self.runner.sync_inflight = False
        complete = False
        if code == 0:
            try:
                complete = projection_complete(rec.get("output", b""))
            except STATE_ERRORS:
                code = store.UNKNOWN
        self.event("projection exit pid=%s code=%s complete=%s%s" %
                   (rec["pid"], code, str(complete).lower(), exit_detail(rec, code)))
        if code != 0 or not complete:
            self.registered = False
            # Unknown adopted completion or an incomplete set is not proof
            # that a previously held projection source recovered.
            # Failure remains a root level; never cancel healthy binding work.
            self.stall("ingest", rec["started_at"], "-")
            self.retry_at = time.time() + self.runner.loop
            self.runner.sync_due = True
            self.release_start(False)
            return
        if rec.get('registering'):
            self.registered = True
        self.retry_at = 0
        self.clear(("ingest",))
        if rec.get("final") and not self.runner.sync_due:
            self.runner.drain_synced = True
        self.release_start(True)


class Runner:
    def __init__(self, owner, args):
        store.require_lock(args.lock)
        self.owner = owner
        self.front, self.front_start = os.getppid(), fmt.pid_starttime(os.getppid())
        record = fields(os.path.join(owner.root, ".runner"), False)
        self.attempt = record["attempt"]
        self.watcher, self.watcher_identity = args.watcher_pid, args.watcher_identity
        s = fmt.seams()
        self.loop = s.value("runner-loop-seconds", RUNNER_LOOP)
        self.stat_bound = s.value("stat-bound", STAT_BOUND)
        self.stage_bound = s.value("stage-bound", STAGE_BOUND)
        self.ingest_bound = s.value("ingest-bound", INGEST_BOUND)
        self.kill_grace = s.value("kill-grace", KILL_GRACE)
        self.full_sweep = s.value("full-sweep", FULL_SWEEP)
        self.bindings = {}
        self.stopping = False
        self.starting = True
        self.sync_due = True
        self.sync_inflight = False
        self.last_maintenance = time.time()
        self.next_tick = 0
        self.projection = None
        self.problems = {}
        self.allow_io = False
        self.routing = None
        self.foreground = None
        self.drain_pending = False
        self.drain_synced = False
        self.ledger_unknown = False
        try:
            self.problems = read_problems(owner)
        except STATE_ERRORS:
            self.ledger_unknown = True

    def members(self):
        return list(self.bindings.values()) + ([self.projection] if self.projection else [])

    def fds(self):
        return [fd for b in self.members() for fd in b.fds()]

    def problem(self, scope, error=None):
        old = self.problems.get(scope)
        if error is None:
            self.problems.pop(scope, None)
        else:
            reason = str(error).replace("\n", " ")[:512] or type(error).__name__
            self.problems[scope] = {"reason": reason, "since": old["since"] if old else int(time.time())}
        if old != self.problems.get(scope):
            store.log(self.owner, None, "quarantine " + scope + (" recovered" if error is None else " " + str(error)[:512]),
                      "scope validation", "revalidate before scheduling; keep independent work alive")
            self.sync_due = True

    def save_problems(self):
        try:
            previous = read_problems(self.owner)
            # Preserve occurrence identity across runner replacements.
            for scope, row in self.problems.items():
                if scope in previous:
                    row["since"] = previous[scope]["since"]
            if previous != self.problems:
                store.write_json(self.owner.dir("", ".quarantine"), self.problems,
                                 self.owner.tmp, "o-quarantine-dirsync")
                self.sync_due = True
            self.ledger_unknown = False
        except STATE_ERRORS as exc:
            if not self.ledger_unknown:
                store.log(self.owner, None, "quarantine ledger unreadable: " + str(exc),
                          "unknown record is not overwritten", "repair .quarantine; watcher reports unknown projection health")
            self.ledger_unknown = True

    def release_start(self, success):
        if self.starting:
            self.starting = False
            store.log(self.owner, None, "start-sync" if success else "start-sync-deferred",
                      "announce pass attempted; projection " + ("completed" if success else "unavailable"),
                      "continue independent binding scheduling")

    def refresh(self):
        try:
            wanted = read_routes(self.owner)
            self.problem("routing")
        except STATE_ERRORS as exc:
            wanted = None
            self.problem("routing", exc)
        if self.routing != wanted:
            self.sync_due = True
        self.routing = wanted
        if wanted is not None:
            for bid, (outbox, retired, expired) in wanted.items():
                try:
                    if bid not in self.bindings:
                        self.bindings[bid] = Binding(self, bid, outbox, retired)
                    else:
                        self.bindings[bid].revalidate(outbox)
                    b = self.bindings[bid]
                    b.removing = False
                    b.retired = retired
                    if expired and not b.expired:
                        b.maintenance = True
                        b.expired = True
                    self.problem("binding:" + bid)
                except STATE_ERRORS as exc:
                    if bid in self.bindings:
                        self.bindings[bid].quarantined = True
                    self.problem("binding:" + bid, exc)
            for bid in set(self.bindings) - set(wanted):
                b = self.bindings[bid]
                b.removing = True
                # Withdrawal is not recovery. Stop known children but never
                # overwrite unreadable records or cancel another binding.
                for rec in b.children.values():
                    signal_child(rec, signal.SIGTERM)
                    signal_child(rec, signal.SIGKILL)
                b.passive()
                if not any(fmt.identity_alive(r["pid"], r["starttime"]) for r in b.children.values()):
                    for rec in b.children.values():
                        for key in ("fd", "request", "answer"):
                            if key in rec:
                                os.close(rec[key])
                    del self.bindings[bid]
                    self.problem("binding:" + bid)
            # Bindings never constructed because their state was unreadable
            # can only disappear by validated routing withdrawal.
            for scope in list(self.problems):
                if scope.startswith("binding:") and scope[8:] not in wanted and scope[8:] not in self.bindings:
                    self.problem(scope)
        try:
            foreground = read_foreground(self.owner)
            self.problem("foreground")
        except STATE_ERRORS as exc:
            foreground = None
            self.problem("foreground", exc)
        self.foreground = foreground
        self.allow_io = wanted is not None and foreground is not None
        for b in self.bindings.values():
            b.fg = foreground is None
        for name, rec in (foreground or {}).items():
            if not fmt.identity_alive(rec["pid"], rec["starttime"]):
                # A parsed dead record is no longer ownership; its binding's
                # stall remains until a completed stat, as before.
                try:
                    fmt.unlink_durable(os.path.join(self.owner.fg, name), "o-fgchild-dirsync")
                except STATE_ERRORS as exc:
                    self.problem("foreground", exc)
                    self.foreground = None
                    self.allow_io = False
                continue
            b = self.bindings.get(rec["binding"])
            if b:
                b.fg = True
                if not b.quarantined and time.time() - rec["started_at"] >= fmt.seams().value("outbox-io-bound", store.OUTBOX_IO_BOUND):
                    try:
                        b.stall("fg", rec["started_at"])
                    except STATE_ERRORS as exc:
                        b.quarantined = True
                        self.problem("binding:" + b.bid, exc)
        try:
            if self.projection is None:
                self.projection = Projection(self)
            else:
                self.projection.revalidate()
            self.sync_inflight = bool(self.projection.children)
            self.problem("projection")
        except STATE_ERRORS as exc:
            if self.projection:
                self.projection.quarantined = True
            self.problem("projection", exc)
        self.save_problems()

    def empty(self):
        return (self.routing == {} and self.foreground is not None and not self.bindings
                and not self.problems and not self.ledger_unknown
                and not any(fmt.identity_alive(r["pid"], r["starttime"]) for r in self.foreground.values()))

    def sync(self):
        if self.starting and any(not b.quarantined and b.maintenance_waiting() for b in self.bindings.values()):
            return
        if not self.projection or self.projection.quarantined:
            self.release_start(False)
            return
        if not self.sync_due or self.sync_inflight:
            return
        if self.projection.children or time.time() < self.projection.retry_at:
            return
        self.projection.run_front("sync-alarms")
        self.projection.children["ingest"]["final"] = self.drain_pending
        self.sync_due = False
        self.sync_inflight = True

    def stop(self):
        all_bindings = self.members()
        records = [(b, r) for b in all_bindings for r in b.children.values()]
        for _, rec in records:
            signal_child(rec, signal.SIGTERM)
        end = time.monotonic() + CHILD_EXIT_GRACE
        while time.monotonic() < end:
            if not any(fmt.identity_alive(r["pid"], r["starttime"]) for _, r in records):
                break
            for _, r in records:
                if "adopted" not in r:
                    try:
                        os.waitpid(r["pid"], os.WNOHANG)
                    except ChildProcessError:
                        pass
            time.sleep(0.02)
        for _, rec in records:
            signal_child(rec, signal.SIGKILL)
        # Allow signal delivery without treating KILL as synchronous death.
        # One shared bound, never one grace per binding.
        end = time.monotonic() + 0.2
        while time.monotonic() < end and any(fmt.identity_alive(r["pid"], r["starttime"]) for _, r in records):
            for _, r in records:
                if "adopted" not in r:
                    try:
                        os.waitpid(r["pid"], os.WNOHANG)
                    except ChildProcessError:
                        pass
            time.sleep(0.01)
        # Reap only with WNOHANG. D-state survivors retain their durable record.
        for b, rec in records:
            if "adopted" not in rec:
                try:
                    os.waitpid(rec["pid"], os.WNOHANG)
                except ChildProcessError:
                    pass
            if not fmt.identity_alive(rec["pid"], rec["starttime"]):
                b.children.pop(rec["role"], None)
        for b in all_bindings:
            if not b.quarantined:
                try:
                    b.save_children()
                except STATE_ERRORS as exc:
                    self.problem("binding:" + b.bid if b.bid else "projection", exc)
        self.save_problems()

    def run(self):
        if fmt.seams().role("child-ignore-term", "runner-loop"):
            signal.signal(signal.SIGTERM, signal.SIG_IGN)
        else:
            signal.signal(signal.SIGTERM, lambda *_: setattr(self, "stopping", True))
        try:
            fmt.seams().fault("runner-loop")
            while not self.stopping and os.getppid() == self.front:
                tick = time.time()
                periodic = tick >= self.next_tick
                if periodic:
                    self.refresh()
                    self.next_tick = tick + self.loop
                    if tick - self.last_maintenance >= 300:
                        for b in self.bindings.values():
                            b.maintenance = True
                        self.last_maintenance = tick
                        self.sync_due = True
                for b in self.members():
                    scope = "binding:" + b.bid if b.bid else "projection"
                    try:
                        if b.quarantined:
                            b.passive()
                            continue
                        b.poll(tick)
                        if b.bid and periodic:
                            b.stat_request(tick)
                    except STATE_ERRORS as exc:
                        b.quarantined = True
                        self.problem(scope, exc)
                empty = self.empty()
                if empty and not self.drain_pending:
                    self.drain_pending = True
                    self.sync_due = True
                elif not empty:
                    self.drain_pending = self.drain_synced = False
                try:
                    self.sync()
                except STATE_ERRORS as exc:
                    if self.projection:
                        self.projection.quarantined = True
                    self.problem("projection", exc)
                for b in self.bindings.values():
                    if b.quarantined:
                        continue
                    try:
                        b.schedule(tick)
                    except STATE_ERRORS as exc:
                        b.quarantined = True
                        self.problem("binding:" + b.bid, exc)
                self.save_problems()
                drained = (self.empty() and self.drain_synced and not self.sync_due
                           and self.projection and not self.projection.children and not self.projection.stalls)
                if periodic or drained:
                    beat = dict(pid=self.front, starttime=self.front_start, epoch=int(tick), attempt=self.attempt)
                    if drained:
                        # A final successful projection, not an empty list, is
                        # the durable completion witness for demand withdrawal.
                        beat["drained"] = "yes"
                    publish_fields(self.owner, os.path.join(self.owner.root, ".runner-beat"), beat)
                if drained:
                    break
                deadlines = [self.next_tick]
                if self.projection and self.sync_due and not self.sync_inflight and self.projection.retry_at > tick:
                    deadlines.append(self.projection.retry_at)
                waits = []
                for b in self.members():
                    for role, r in b.children.items():
                        if r.get("eof"):
                            deadlines.append(tick + 0.02)
                        waits += [r[k] for k in ("fd", "answer") if k in r and not r.get("eof")]
                        if b.quarantined:
                            continue
                        if role == "stat":
                            since = r.get("adopted", r.get("asked"))
                            if since is not None and not r["killed"]:
                                deadlines.append(since + self.stat_bound)
                        elif not r["killed"]:
                            bound = self.stage_bound if role == "stage" else self.ingest_bound
                            deadlines.append(r["started_at"] + bound + (self.kill_grace if r["term"] else 0))
                ready, _, _ = select.select(waits, [], [], max(0, min(deadlines) - time.time()))
                for b in self.members():
                    for r in b.children.values():
                        if r.get("fd") in ready:
                            try:
                                b.drain(r)
                            except STATE_ERRORS as exc:
                                b.quarantined = True
                                self.problem("binding:" + b.bid if b.bid else "projection", exc)
        finally:
            self.stop()


def run(owner, args):
    Runner(owner, args).run()
    raise store.Done(0, state="runner-stopped")
