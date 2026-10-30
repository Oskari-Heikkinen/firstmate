#!/usr/bin/env python3
"""P1 recorder controller; one owner-authorized attempt, never a routine check.

Usage: fm-supervision-recorder.py --help
Linux, Python >=3.9, standard library only. Library: fm_supervision_recorder.py.
`audit --repo DIR --code-ref SHA --output NEW` audits every caller and reviewed
read pin against the exact blobs at SHA (git cat-file; no checkout) and writes
the sealed pin-audit receipt a capture must carry.
`check-admission FILE --audit RECEIPT` validates an admission offline: schema,
manifest, roots, template values, selected callers and the G6 projection.
`run FILE --audit RECEIPT --trace PATH` is the one acquisition attempt. It
refuses unless FM_SUPERVISION_RECORDER_LIVE=1 and --acknowledge-enable are
given, then checks the destination filesystem, writes the external enable
record, watches, scans, waits through T0+90 s, rereads, and finalizes under
`fm-mem-guard.sh admit --cost-mib 768` (every FM_* variable stripped), nice
19 and idle I/O. The independent guard stops every role by T0-prepare+116 s
unless the controller writes its completion line.
`finalize DIR --trace PATH` re-runs only the offline finalizer on retained
attempt evidence. Exit: 0 published, 2 refused/invalid/loss/timeout. Evidence
stays private in the attempt directory; nothing is deleted or retried.
Semantics, limits and formats: docs/supervision-accounting.md "Recorder controller".
"""
import argparse
import fcntl
import importlib.util
import json
import os
from pathlib import Path
import secrets
import select
import subprocess
import sys
import time

BIN = Path(__file__).resolve().parent
sys.path.insert(0, str(BIN))
import fm_supervision_recorder as rec  # noqa: E402

accounting = None


def load_accounting():
    """Not loaded by the guard and io roles, which run under 32 and 64 MiB address-space limits."""
    global accounting
    spec = importlib.util.spec_from_file_location("fm_supervision_accounting", BIN / "fm-supervision-accounting.py")
    accounting = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(accounting)


def load(path):
    return accounting.load_json(path)


def write_new(path, value):
    accounting.write_private(path, value)


def admission_checked(value):
    def schema(item):
        accounting.validate(item, accounting.load_json(accounting.SCHEMAS / "recorder-admission-v1.schema.json"))
    return rec.validate_admission(value, schema, accounting.manifest)


def screened(admission, audit):
    closure = rec.load_closure()
    rec.check_audit(audit, closure, admission["code_ref"])
    places = rec.admitted_places(closure, admission)
    captured = rec.captured_places(places)
    return closure, places, captured, rec.project(admission, captured)


def physical_roots(admission):
    return {(r["home"], r["root"], r["task"]): r["path"] for r in admission["roots"]}


def roles_file(attempt):
    return os.path.join(attempt, "roles")


def sealed_file(attempt):
    return os.path.join(attempt, "roles.sealed")


def register(attempt, role, pid):
    """Append-only role table the guard reads; one short line per role, written
    under the table's lock and refused once the guard has sealed it."""
    line = "%s %d %d\n" % (role, pid, rec.proc_start_ticks(pid))
    fd = os.open(roles_file(attempt), os.O_WRONLY | os.O_APPEND | os.O_CREAT | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX)
        rec.need(not os.path.lexists(sealed_file(attempt)), "guard has escalated; role not registered")
        os.write(fd, line.encode("ascii"))
    finally:
        os.close(fd)


def seal_roles(attempt):
    """The guard's one read of the table: under the same lock it marks the table
    sealed, so a role the controller starts later is refused, never missed."""
    fd = os.open(roles_file(attempt), os.O_RDONLY | os.O_CREAT | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX)
        os.close(os.open(sealed_file(attempt), os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC,
                         0o600))
        return read_roles(attempt)
    finally:
        os.close(fd)


def read_roles(attempt):
    try:
        with open(roles_file(attempt), "rb") as stream:
            lines = stream.read(65536).decode("ascii").splitlines()
    except FileNotFoundError:
        return []
    return [dict(role=role, pid=int(pid), start_ticks=int(ticks)) for role, pid, ticks in (l.split() for l in lines)]


def spawn(role, *arguments, stdin=None, stdout=None, prefix=()):
    return subprocess.Popen(list(prefix) + [sys.executable, "-I", str(Path(__file__).resolve()), "_" + role]
                            + [str(a) for a in arguments], stdin=stdin, stdout=stdout, start_new_session=True,
                            close_fds=True)


ROLE_GO = b"go\n"


def started(name, role, attempt, *arguments, stdout=None, prefix=()):
    """Spawn a role that waits for its go line, written only once the guard can
    see it, so a controller that dies in between leaves no unregistered role."""
    child = spawn(role, attempt, *arguments, stdin=subprocess.PIPE, stdout=stdout, prefix=prefix)
    try:
        register(attempt, name, child.pid)
        child.stdin.write(ROLE_GO)
    finally:
        child.stdin.close()
    return child


def await_go():
    rec.need(sys.stdin.buffer.read(len(ROLE_GO) + 1) == ROLE_GO, "controller did not register this role")


def reproduced(admission, audit):
    """G1 carry-forward: the receipt must equal a fresh audit from Git at code_ref."""
    rec.need(rec.audit_code_ref(str(BIN.parent), admission["code_ref"], rec.load_closure()) == audit,
             "pin audit does not reproduce at code_ref")


def finalize_admitted(attempt, trace):
    """The only way either verb admits evidence and runs the 768 MiB finalizer:
    the retained receipt reproduces from Git, the memory guard admits it, then
    its own limited role runs under nice 19 and idle I/O."""
    reproduced(load(os.path.join(attempt, "admission.json")), load(os.path.join(attempt, "pin-audit.json")))
    rec.admit_finalizer(str(BIN / "fm-mem-guard.sh"))
    finalizer = started("finalizer", "finalize", attempt, trace, stdout=subprocess.PIPE,
                        prefix=("nice", "-n", "19", "ionice", "-c3"))
    # communicate() would flush the stdin started() already closed.
    with finalizer.stdout:
        out = finalizer.stdout.read()
    rec.need(finalizer.wait() == 0, "finalizer refused; attempt evidence retained")
    return json.loads(out)


# --- private roles -------------------------------------------------------------

GUARD_DONE = b"done\n"


def guard_role(attempt, origin_ns, normal_ns):
    """Independent deadline owner: stands down only on the controller's
    completion line; end of input without it, or anything else, escalates at
    once, so a dead or interrupted controller never dismisses the guard."""
    rec.limit("guard")
    deadline = origin_ns + normal_ns
    received = b""
    while rec.boottime_ns() < deadline:
        ready = select.select([0], [], [], max(0, deadline - rec.boottime_ns()) / rec.SECOND)[0]
        if ready:
            chunk = os.read(0, 64)
            received += chunk
            if received == GUARD_DONE:
                return 0
            if not chunk or not GUARD_DONE.startswith(received):
                break
    outcome = rec.escalate(seal_roles(attempt), rec.boottime_ns())
    fd = os.open(os.path.join(attempt, "guard.json"), os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_CLOEXEC, 0o600)
    os.write(fd, (json.dumps(dict(format="fm-supervision-recorder-guard.v1", outcome=outcome),
                             sort_keys=True, indent=2) + "\n").encode())
    os.close(fd)
    return 2


def io_role(attempt):
    """Bounded object reads only; the coordinator never opens admitted files.

    Runs without the accounting module and streams one place at a time, so its
    peak is one 4 MiB object and its encodings, inside the 64 MiB limit.
    """
    rec.limit("io")
    with open(os.path.join(attempt, "admission.json"), "rb") as stream:
        roots = physical_roots(json.load(stream))
    with open(os.path.join(attempt, "captured.json"), "rb") as stream:
        captured = [tuple(row) for row in json.load(stream)]
    for line in sys.stdin:
        name = line.strip()
        rec.need(name in ("initial", "final"), "unknown scan request")
        path = os.path.join(attempt, name + ".json")
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            stream.write("[")
            for index, key in enumerate(captured):
                row = dict(key=list(key), object=rec.encode_object(rec.capture_object(rec.physical(roots, key))))
                stream.write(("," if index else "") + "\n" + json.dumps(row, sort_keys=True, allow_nan=False))
            stream.write("\n]\n")
            stream.flush()
            os.fsync(stream.fileno())
        sys.stdout.write(name + "\n")
        sys.stdout.flush()
    return 0


def coordinator_role(attempt, origin_ns):
    rec.limit("coordinator")
    admission = load(os.path.join(attempt, "admission.json"))
    roots = physical_roots(admission)
    captured = [tuple(row) for row in load(os.path.join(attempt, "captured.json"))]
    directories = [(key, rec.physical(roots, key)) for key in captured
                   if os.path.isdir(rec.physical(roots, key)) and not os.path.islink(rec.physical(roots, key))]
    watcher = rec.Watcher(directories)
    io = subprocess.Popen([sys.executable, "-I", str(Path(__file__).resolve()), "_io", attempt],
                          stdin=subprocess.PIPE, stdout=subprocess.PIPE, close_fds=True)
    register(attempt, "io", io.pid)

    def scan(name):
        io.stdin.write((name + "\n").encode())
        io.stdin.flush()
        rec.need(io.stdout.readline() == (name + "\n").encode(), "I/O child failed its scan")

    spool = os.path.join(attempt, "spool")
    rec.prepare_bank(spool)
    scan("initial")
    watcher.drain(rec.boottime_ns())
    rec.need(not watcher.events, "admitted state changed before T0")
    with open("/proc/sys/kernel/random/boot_id", "rb") as stream:
        boot_id = stream.read(64).decode("ascii").strip()
    wall_t0, t0 = time.time_ns(), rec.boottime_ns()
    rec.need(t0 - origin_ns <= rec.PREPARE_NS, "preparation exceeded 10 s")
    offset_start = wall_t0 - t0
    wall_t0 -= wall_t0 % 1000  # The enable record carries microseconds.
    t0 = wall_t0 - offset_start
    t0_cs, centi = t0 // 10_000_000, 10_000_000
    enable = dict(format=rec.ENABLE_FORMAT, epoch=admission["label"], nonce=secrets.token_hex(16),
                  boot_id=boot_id, t0_cs=t0_cs, cutoff_cs=t0_cs + rec.WINDOW_NS // centi,
                  end_cs=t0_cs + rec.ACQUISITION_NS // centi,
                  expiry_cs=t0_cs + (rec.ACQUISITION_NS + rec.FLUSH_NS) // centi, wall_t0_us=wall_t0 // 1000,
                  spool=spool, tickets=rec.TICKETS, ticket_bytes=rec.TICKET_BYTES, chain_max=rec.CHAIN_MAX)
    rec.write_enable(admission["enable_file"], enable)
    while rec.boottime_ns() < t0 + rec.ACQUISITION_NS + rec.FLUSH_NS:
        watcher.wait(t0 + rec.ACQUISITION_NS + rec.FLUSH_NS - rec.boottime_ns())
        watcher.drain(rec.boottime_ns())
    scan("final")
    barrier = rec.boottime_ns()
    watcher.drain(barrier)
    offset_end = time.time_ns() - rec.boottime_ns()
    watcher.close()
    io.stdin.close()
    rec.need(io.wait(timeout=2) == 0, "I/O child failed")
    acquisition = dict(format=rec.ACQUISITION_FORMAT, enable_nonce=enable["nonce"], enable=enable, t0_ns=t0,
                       wall_t0_ns=wall_t0, offset_start_ns=offset_start, offset_end_ns=offset_end,
                       barrier_ns=barrier, namespace="time-%d" % os.stat("/proc/self/ns/time").st_ino,
                       events=watcher.events)
    write_new(os.path.join(attempt, "acquisition.json"), acquisition)
    return 0


def finalize(attempt, trace_path):
    rec.limit("finalizer")
    admission = load(os.path.join(attempt, "admission.json"))
    audit = load(os.path.join(attempt, "pin-audit.json"))
    acquisition = load(os.path.join(attempt, "acquisition.json"))
    # The scans stay in the io role's files so the coordinator never holds them.
    rec.need(not {"initial", "final"} & set(acquisition), "acquisition record embeds a scan")
    for name in ("initial", "final"):
        acquisition[name] = load(os.path.join(attempt, name + ".json"))
    closure, _, _, _ = screened(admission, audit)
    with open(admission["enable_file"], "rb") as stream:
        enable = rec.parse_enable(stream.read(4097))
    rec.need(enable == acquisition["enable"], "enable record changed")
    producers = rec.collect_spool(enable["spool"], enable)
    finalizer = rec.Finalizer(admission, closure, audit, enable, acquisition, producers)
    trace = load(trace_path)
    workload, bindings, provenance = finalizer.build(trace, False, admission["label"])
    losses = finalizer.losses()
    rec.need(not losses, "loss detected: " + "; ".join(sorted(set(losses))))
    accounting.bound_workload(workload, bindings)
    staging = os.path.join(attempt, ".published")
    os.mkdir(staging, 0o700)
    for name, value in (("workload.json", workload), ("bindings.json", bindings), ("provenance.json", provenance)):
        write_new(os.path.join(staging, name), value)
    os.rename(staging, os.path.join(attempt, "published"))
    return dict(published=os.path.join(attempt, "published"), selected=provenance["selected"],
                workload_sha256=workload["sha256"], bindings_sha256=bindings["sha256"])


def run(args):
    rec.need(sys.platform == "linux" and hasattr(os, "pidfd_open"), "Linux pidfds required")
    rec.need(os.environ.get("FM_SUPERVISION_RECORDER_LIVE") == "1",
             "recording disabled; explicit FM_SUPERVISION_RECORDER_LIVE=1 required")
    rec.need(args.acknowledge_enable, "run needs --acknowledge-enable")
    origin = rec.boottime_ns()
    admission = admission_checked(load(args.input))
    with open("/etc/machine-id", encoding="ascii") as stream:
        rec.need(stream.read(64).strip() == admission["machine"], "admission names another machine")
    audit = load(args.audit)
    _, _, captured, projection = screened(admission, audit)
    reproduced(admission, audit)
    destination = admission["destination"]
    with open("/proc/self/mountinfo", encoding="utf-8") as stream:
        table = rec.mounts(stream.read(1048576))
    rec.check_filesystems(destination, sorted(set(physical_roots(admission).values())), table)
    rec.need(not os.path.lexists(admission["enable_file"]), "enable record already exists")
    enable_parent = os.path.dirname(admission["enable_file"])
    rec.need(os.path.realpath(enable_parent) == enable_parent, "enable directory is an alias")
    for root in physical_roots(admission).values():
        rec.need(not (admission["enable_file"] + "/").startswith(root.rstrip("/") + "/"), "enable record inside a root")
    os.mkdir(destination, 0o700)
    write_new(os.path.join(destination, "admission.json"), admission)
    write_new(os.path.join(destination, "pin-audit.json"), audit)
    write_new(os.path.join(destination, "captured.json"), [list(key) for key in captured])
    write_new(os.path.join(destination, "projection.json"), projection)
    # Escalation starts at the normal bound so it ends by the 116 s deadline.
    guard = spawn("guard", destination, origin, rec.NORMAL_NS, stdin=subprocess.PIPE)
    completed = False
    try:
        coordinator = started("coordinator", "coordinator", destination, origin)
        rec.need(coordinator.wait() == 0, "coordinator failed; attempt evidence retained")
        finalize_admitted(destination, args.trace)
        completed = True
    finally:
        # Without the completion line the guard stops every registered role now.
        try:
            if completed:
                guard.stdin.write(GUARD_DONE)
            guard.stdin.close()
        except BrokenPipeError:
            pass
        guard.wait()
    rec.need(guard.returncode == 0, "guard stopped the attempt; attempt evidence retained")
    rec.need(os.path.isdir(os.path.join(destination, "published")), "nothing published")
    return dict(published=os.path.join(destination, "published"), attempt=destination)


def main():
    if len(sys.argv) > 1 and sys.argv[1].startswith("_"):
        role, rest = sys.argv[1], sys.argv[2:]
        if role in ("_guard", "_io"):
            try:
                return guard_role(rest[0], int(rest[1]), int(rest[2])) if role == "_guard" else io_role(rest[0])
            except (rec.Refused, OSError, ValueError, KeyError, IndexError) as error:
                print("supervision-recorder: refused: " + str(error), file=sys.stderr)
                return 2
        load_accounting()
        try:
            if role in ("_coordinator", "_finalize"):
                await_go()
            if role == "_coordinator":
                return coordinator_role(rest[0], int(rest[1]))
            if role == "_finalize":
                sys.stdout.write(accounting.dump(finalize(rest[0], rest[1])))
                return 0
        except (rec.Refused, accounting.Refused, OSError, ValueError, KeyError) as error:
            print("supervision-recorder: refused: " + str(error), file=sys.stderr)
            return 2
        print("supervision-recorder: refused: unknown private role", file=sys.stderr)
        return 2
    load_accounting()
    parser = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    verbs = parser.add_subparsers(dest="verb", required=True)
    audit = verbs.add_parser("audit")
    audit.add_argument("--repo", required=True)
    audit.add_argument("--code-ref", required=True)
    audit.add_argument("--output", required=True)
    check = verbs.add_parser("check-admission")
    check.add_argument("input")
    check.add_argument("--audit", required=True)
    live = verbs.add_parser("run")
    live.add_argument("input")
    live.add_argument("--audit", required=True)
    live.add_argument("--trace", required=True)
    live.add_argument("--acknowledge-enable", action="store_true")
    offline = verbs.add_parser("finalize")
    offline.add_argument("attempt")
    offline.add_argument("--trace", required=True)
    args = parser.parse_args()
    try:
        if args.verb == "audit":
            receipt = rec.audit_code_ref(args.repo, args.code_ref, rec.load_closure())
            write_new(args.output, receipt)
            result = dict(code_ref=receipt["code_ref"], sha256=receipt["sha256"],
                          caller_sites=len(receipt["caller_sites"]), read_sites=len(receipt["read_sites"]))
        elif args.verb == "check-admission":
            admission = admission_checked(load(args.input))
            _, _, captured, projection = screened(admission, load(args.audit))
            result = dict(projection, captured_places=len(captured))
        elif args.verb == "run":
            result = run(args)
        else:
            result = finalize_admitted(args.attempt, args.trace)
        sys.stdout.write(accounting.dump(result))
        return 0
    except KeyboardInterrupt:
        print("supervision-recorder: refused: interrupted; attempt evidence retained", file=sys.stderr)
        return 2
    except (rec.Refused, accounting.Refused, OSError, ValueError, KeyError, IndexError, TypeError,
            subprocess.SubprocessError) as error:
        print("supervision-recorder: refused: " + str(error), file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
