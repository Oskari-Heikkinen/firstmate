#!/usr/bin/env python3
"""Bounded, opt-in P0 accounting; never launches a workload or activates a mode.

Usage: fm-supervision-accounting.py --help
Python >=3.9, standard library only. `probe` is read-only, with no attach.
`capture` needs Linux, strace, pidfds and permission to ptrace every explicitly
published root. It refuses unless FM_SUPERVISION_CAPTURE_LIVE=1 AND
--acknowledge-ptrace are supplied; never use it as a routine check.
`capture-proc` is a separate opt-in, unprivileged Linux /proc-only route:
--manifest FILE --output NEW_DIR --seconds 1..300 [--interval-ms 1000..10000]
[--max-bytes 4096..67108864] [--model FILE]. Optional model supplies CI
exclusive costs and owner-admitted append-only tick logs (64 KiB each).
Model estimates are separate from measurements, cross-checked against exact
machine totals; missing families and negative residuals stay explicit.
Requires FM_SUPERVISION_PROC_LIVE=1, non-root,
no effective capabilities, local single-machine enrollment and published roots.
No subprocess, attach, target signals, policy writes or workload. Output cap is TOTAL.
`account-proc FILE` replays its proc.json (including synthetic CI fixtures).
`check-proc-fixture FILE` exercises the SAME deadline/scan/task-cap/credential
guards with closed synthetic JSON inputs and at most 200ms of pause. Optional
read_region + expire_on_final_task deliver the alarm at a synthetic final-scan
read; credentials supplies synthetic euid/cap_eff. No /proc reads, output
directory or live capture. Fixture controls cannot be supplied to live
capture, by flags, environment or manifest fields.
Proc reports measured machine totals and observed lower bounds, NOT complete B0.
Capture output is private and may contain command arguments.
Exit: 0 report produced, 2 refused/invalid input or failed capture. A report
may retain losses/contradictions without certifying completeness. Diagnostics
use stderr; the invoking task owner routes failures through its status path.
Schemas and semantics: docs/supervision-accounting.md. No daemon or poller.
"""
import argparse
import base64
import binascii
from contextlib import nullcontext
import hashlib
import json
import os
from pathlib import Path
import re
import resource
import selectors
import shutil
import signal
import stat
import subprocess
import sys
import time
from decimal import Decimal
from fractions import Fraction

MAX_BYTES = 64 * 1024 * 1024
SCHEMAS = Path(__file__).resolve().parent.parent / "docs" / "supervision-accounting"
FAMILIES = ("crew-state", "watch", "wake-drain", "fleet-snapshot", "spawn", "control")
SCRIPT_FAMILIES = {"fm-" + name + ".sh": name for name in FAMILIES}
SHELL_EXECUTABLES = ("/bin/bash", "/usr/bin/bash", "/bin/sh", "/usr/bin/sh")


class Refused(ValueError):
    pass


class ProcDeadline(Exception):
    """Fatal invocation expiry, never a recoverable per-PID read loss."""


def require(condition, message):
    if not condition:
        raise Refused(message)


def read_bytes(path, limit=MAX_BYTES):
    # O_NONBLOCK prevents an accidental FIFO from turning a bounded read into a wait.
    fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK | os.O_NOFOLLOW)
    with os.fdopen(fd, "rb") as stream:
        require(stat.S_ISREG(os.fstat(stream.fileno()).st_mode), "not a regular file")
        data = stream.read(limit + 1)
    require(len(data) <= limit, "input exceeds byte bound")
    return data


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result, "duplicate JSON key: " + key)
        result[key] = value
    return result


def load_json(path):
    return json.loads(read_bytes(path), object_pairs_hook=unique_object)


def digest(data):
    return hashlib.sha256(data).hexdigest()


def dump(value):
    return json.dumps(value, sort_keys=True, indent=2, allow_nan=False) + "\n"


def validate(value, schema, root=None, where="$"):
    """The closed schema subset used by the three shipped v1 schemas."""
    root = root or schema
    if "$ref" in schema:
        ref = schema["$ref"]
        require(ref.startswith("#/$defs/"), "unsupported schema reference")
        validate(value, root["$defs"][ref[8:]], root, where)
        return
    types = {"object": dict, "array": list, "string": str, "integer": int,
             "boolean": bool, "null": type(None)}
    if "type" in schema:
        require(type(value) is types[schema["type"]], where + ": wrong type")
    if "const" in schema:
        require(value == schema["const"], where + ": unsupported format/value")
    if "enum" in schema:
        require(value in schema["enum"], where + ": unsupported value")
    if isinstance(value, dict):
        require(set(schema.get("required", ())) <= value.keys(), where + ": missing field")
        properties = schema.get("properties", {})
        if schema.get("additionalProperties") is False:
            require(value.keys() <= properties.keys(), where + ": unknown field")
        for key, item in value.items():
            if key in properties:
                validate(item, properties[key], root, where + "." + key)
    elif isinstance(value, list):
        require(schema.get("minItems", 0) <= len(value) <= schema.get("maxItems", 1000000),
                where + ": array size")
        if schema.get("uniqueItems"):
            require(len({json.dumps(v, sort_keys=True) for v in value}) == len(value),
                    where + ": duplicate array item")
        for index, item in enumerate(value):
            validate(item, schema.get("items", {}), root, where + "[" + str(index) + "]")
    elif isinstance(value, str):
        require(schema.get("minLength", 0) <= len(value) <= schema.get("maxLength", MAX_BYTES),
                where + ": string size")
        if "pattern" in schema:
            require(re.fullmatch(schema["pattern"], value) is not None, where + ": pattern")
    elif type(value) is int:
        require(schema.get("minimum", -2**63) <= value <= schema.get("maximum", 2**63 - 1),
                where + ": numeric bound")


def checked(value, kind):
    validate(value, load_json(SCHEMAS / (kind + "-v1.schema.json")))
    return value


def manifest(value):
    checked(value, "fleet-manifest")
    homes = value["homes"]
    require(len({h["id"] for h in homes}) == len(homes), "duplicate home")
    require(set(value["enrolled_homes"]) == {h["id"] for h in homes}, "enrollment mismatch")
    for home in homes:
        for key in ("home", "state_root", "code_root"):
            require(os.path.normpath(home[key]) == home[key], "noncanonical path spelling")
        require(home["state_root"].startswith(home["home"] + "/"), "state root outside home")
        require(len({r["pid"] for r in home["capture_roots"]}) == len(home["capture_roots"]),
                "duplicate capture root")
        for field, key in (("tasks", "id"), ("sources", "id"), ("checks", "id"), ("timers", "name")):
            require(len({row[key] for row in home[field]}) == len(home[field]),
                    "duplicate " + field)
        require(all(timer["bound_ms"] >= timer["interval_ms"] for timer in home["timers"]),
                "timer bound shorter than interval")
    return value


def boundary():
    sample_start = time.time_ns()
    cpu = []
    births = None
    with open("/proc/stat", encoding="ascii") as stream:
        for line in stream:
            if line.startswith("cpu "):
                cpu = [int(value) for value in line.split()[1:]]
            elif line.startswith("processes "):
                births = int(line.split()[1])
    require(births is not None, "machine birth counter unavailable")
    with open("/proc/loadavg", encoding="ascii") as stream:
        load = stream.read(256).strip()
    return {"wall_ns": sample_start, "monotonic_ns": time.monotonic_ns(),
            "machine_births": births, "counter_sample_end_wall_ns": time.time_ns(),
            "cpu_ticks": cpu, "loadavg": load}


def proc_identity(pid):
    # The only per-PID reads are explicitly supplied capture roots, not a PID scan.
    with open("/proc/" + str(pid) + "/stat", encoding="ascii") as stream:
        text = stream.read(16384)
    fields = text[text.rfind(")") + 2:].split()
    with open("/proc/" + str(pid) + "/cmdline", "rb") as stream:
        raw = stream.read(65537)
    require(len(raw) <= 65536, "root argv too large")
    argv = [v.decode("utf-8", "surrogateescape") for v in raw.rstrip(b"\0").split(b"\0")]
    require(argv and argv[0], "root argv unavailable")
    executable = os.readlink("/proc/" + str(pid) + "/exe")
    return {"pid": pid, "start_ticks": fields[19], "argv": argv,
            "executable": executable, "exec_evidence": "proc-exe-cmdline"}


def probe():
    result = {"format": "fm-supervision-probe.v1", "platform": sys.platform,
              "uid": os.getuid(), "strace": shutil.which("strace"),
              "pidfd_api": hasattr(os, "pidfd_open"), "attach_attempted": False,
              "permission_proven": False}
    for name, path in (("yama_ptrace_scope", "/proc/sys/kernel/yama/ptrace_scope"),
                       ("perf_event_paranoid", "/proc/sys/kernel/perf_event_paranoid"),
                       ("unprivileged_bpf_disabled", "/proc/sys/kernel/unprivileged_bpf_disabled")):
        try:
            with open(path, encoding="ascii") as stream:
                result[name] = stream.read(256).strip()
        except OSError as error:
            result[name] = str(error)
    try:
        with open("/proc/self/status", encoding="ascii") as stream:
            for line in stream:
                if line.startswith("CapEff:"):
                    result["cap_sys_ptrace"] = bool(int(line.split()[1], 16) & (1 << 19))
    except OSError:
        result["cap_sys_ptrace"] = False
    result["requirement"] = ("strace and permitted PTRACE_SEIZE/ATTACH for every published root; "
                             "with Yama=1 an unrelated tracer needs CAP_SYS_PTRACE in the "
                             "target user namespace or a target-established PR_SET_PTRACER grant. "
                             "Dumpability and LSM rules still apply. No attach was probed.")
    return result


def write_private(path, value):
    with open(path, "x", encoding="utf-8") as stream:
        os.chmod(path, 0o600)
        stream.write(dump(value))
        stream.flush()
        os.fsync(stream.fileno())


def wait_pidfd(process, seconds):
    fd = os.pidfd_open(process.pid)
    try:
        with selectors.DefaultSelector() as selector:
            selector.register(fd, selectors.EVENT_READ)
            return bool(selector.select(seconds))
    finally:
        os.close(fd)


def capture(args):
    require(sys.platform == "linux" and hasattr(os, "pidfd_open"), "Linux pidfds required")
    require(os.environ.get("FM_SUPERVISION_CAPTURE_LIVE") == "1",
            "live capture disabled; explicit FM_SUPERVISION_CAPTURE_LIVE=1 required")
    require(args.acknowledge_ptrace, "capture needs --acknowledge-ptrace")
    require(1 <= args.seconds <= 300, "capture duration must be 1..300 seconds")
    require(4096 <= args.max_bytes <= MAX_BYTES, "capture byte bound must be 4096..67108864")
    tool = shutil.which("strace")
    require(tool is not None, "strace unavailable; install nothing automatically")
    enrollment = manifest(load_json(args.manifest))
    homes = [h for h in enrollment["homes"] if h["id"] == args.home]
    require(len(homes) == 1, "capture needs one explicitly enrolled home")
    require(not homes[0]["remote"], "remote home must capture on its own machine")
    roots = homes[0]["capture_roots"]
    require(roots, "no published capture roots")
    seeds = []
    for root in roots:
        observed = proc_identity(root["pid"])
        require(observed["start_ticks"] == root["start_ticks"], "capture root identity changed")
        observed["home"] = args.home
        seeds.append(observed)
    output = Path(args.output)
    output.mkdir(mode=0o700)  # never overwrite any prior evidence
    os.chmod(output, 0o700)
    write_private(output / "manifest.json", enrollment)
    raw_path = output / "strace.log"
    with open(raw_path, "xb"):
        os.chmod(raw_path, 0o600)
    error_path = output / "strace.stderr"
    command = [tool, "-f", "-qq", "-ttt", "-s", "4096", "-e", "trace=process", "-o", str(raw_path)]
    for seed in seeds:
        command.extend(["-p", str(seed["pid"])])
    before = boundary()
    own_before = resource.getrusage(resource.RUSAGE_SELF)
    child_before = resource.getrusage(resource.RUSAGE_CHILDREN)
    metadata = {"format": "fm-supervision-capture.v1", "method": "strace-explicit-roots",
                "command": command, "seeds": seeds, "before": before,
                "duration_bound_s": args.seconds, "byte_bound": args.max_bytes,
                "manifest_sha256": digest(dump(enrollment).encode()), "complete": False}
    write_private(output / "started.json", metadata)

    def limits():
        resource.setrlimit(resource.RLIMIT_FSIZE, (args.max_bytes, args.max_bytes))

    process = None
    interrupted = False

    def interrupt(_signum, _frame):
        raise KeyboardInterrupt

    previous_signals = {sig: signal.signal(sig, interrupt) for sig in (signal.SIGTERM, signal.SIGHUP)}
    try:
        with open(error_path, "xb") as errors:
            os.chmod(error_path, 0o600)
            # Never create a process group containing targets and never kill one.
            process = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                                       stderr=errors, preexec_fn=limits)
            if not wait_pidfd(process, args.seconds):
                process.send_signal(signal.SIGINT)  # strace detaches; not forwarded to tracees
                if not wait_pidfd(process, 2):
                    process.kill()  # only our unreaped tracer PID; never a target
                    require(wait_pidfd(process, 2), "tracer did not exit after SIGKILL")
            process.wait()  # pidfd proved exit; this is a reap, not another wait
    except (KeyboardInterrupt, OSError):
        interrupted = True
        raise
    finally:
        for sig, previous in previous_signals.items():
            signal.signal(sig, previous)
        if process is not None and process.poll() is None:
            process.kill()
            if wait_pidfd(process, 2):
                process.wait()
        after = boundary()
        own_after = resource.getrusage(resource.RUSAGE_SELF)
        child_after = resource.getrusage(resource.RUSAGE_CHILDREN)
        usage = {"collector_user_s": own_after.ru_utime - own_before.ru_utime,
                 "collector_system_s": own_after.ru_stime - own_before.ru_stime,
                 "tracer_user_s": child_after.ru_utime - child_before.ru_utime,
                 "tracer_system_s": child_after.ru_stime - child_before.ru_stime,
                 "tracer_peak_rss_kib": child_after.ru_maxrss}
        raw = read_bytes(raw_path) if raw_path.exists() else b""
        errors = read_bytes(error_path) if error_path.exists() else b""
        metadata.update({"after": after, "raw_sha256": digest(raw), "stderr_sha256": digest(errors),
                         "tracer_rc": None if process is None else process.returncode,
                         "usage": usage,
                         "complete": not interrupted and process is not None
                         and process.returncode in (0, -signal.SIGINT)
                         and not errors.strip() and len(raw) < args.max_bytes})
        write_private(output / "finished.json", metadata)
    require(metadata["complete"], "capture incomplete; retain evidence and report refusal")
    return {"output": str(output), "complete": True, "next": "import-strace"}


def proc_enrollment(value):
    manifest(value)
    require(not any(h["remote"] for h in value["homes"]), "proc capture refuses remote homes")
    require(len({h["machine"] for h in value["homes"]}) == 1, "proc capture needs one machine")
    roots = [r["pid"] for h in value["homes"] for r in h["capture_roots"]]
    require(roots and len(set(roots)) == len(roots), "missing or shared proc capture roots")
    return value


def proc_boundary(hz):
    def uptime():
        return Decimal(read_bytes("/proc/uptime", 256).decode("ascii").split()[0]) * hz

    lower = int(uptime())
    counter = boundary()
    # uptime is printed to centiseconds (truncated); add a full centisecond
    # plus one jiffy, not just a rounding operation at HZ > 100.
    upper = int(uptime()) + (hz + 99) // 100 + 1
    return {key: counter[key] for key in
            ("monotonic_ns", "wall_ns", "machine_births", "cpu_ticks")} | {
                "uptime_lower_ticks": lower, "uptime_upper_ticks": upper,
                "boot_id": read_bytes("/proc/sys/kernel/random/boot_id", 128).decode("ascii").strip()}


def proc_task(pid, *, read_file=read_bytes, read_link=os.readlink):
    base = "/proc/" + str(pid)

    def fields():
        text = read_file(base + "/stat", 16384).decode("utf-8", "surrogateescape")
        return text[text.rfind(")") + 2:].split()

    first = fields()
    hint_unavailable = False
    try:
        raw = read_file(base + "/cmdline", 65536)
        executable = read_link(base + "/exe") if raw else ""
    except (PermissionError, Refused):
        raw, executable, hint_unavailable = b"", "", True
    last = fields()
    require(first[19] == last[19], "PID reused during proc read")
    return {"pid": pid, "ppid": int(last[1]), "start_ticks": int(last[19]),
            "user_ticks": int(last[11]), "system_ticks": int(last[12]),
            "argv": [v.decode("utf-8", "surrogateescape") for v in raw.rstrip(b"\0").split(b"\0")]
            if raw else [], "executable": executable, "hint_unavailable": hint_unavailable}


def proc_scan(deadline, byte_budget, fixture=None, *, task_reader=None):
    # Only check-proc-fixture can supply fixture data. The live caller always
    # uses /proc, its real monotonic clock and the fixed 32768-leader ceiling.
    started = time.monotonic_ns()
    tasks, unreadable, vanished, encoded_bytes = [], 0, 0, 0
    require(byte_budget >= 0, "proc total output cap exceeded")
    task_limit = 32768 if fixture is None else fixture["task_limit"]
    entries = os.scandir("/proc") if fixture is None else nullcontext(fixture["pids"])
    with entries as directory:
        for item in directory:
            now = time.monotonic() if fixture is None else fixture["clock_ms"] / 1000
            require(now < deadline, "proc scan exceeded duration bound")
            name = item.name if fixture is None else str(item)
            if not name.isdecimal():
                continue
            require(len(tasks) + unreadable + vanished < task_limit, "proc task cap exceeded")
            try:
                if task_reader is not None:
                    task = task_reader(int(name))
                elif fixture is None:
                    task = proc_task(int(name))
                else:
                    task = {"pid": item, "ppid": 0, "start_ticks": 0, "user_ticks": 0,
                            "system_ticks": 0, "argv": [], "executable": "", "hint_unavailable": False}
            except (FileNotFoundError, ProcessLookupError):
                vanished += 1
                continue
            except (OSError, Refused, ValueError, IndexError):
                unreadable += 1
                continue
            encoded_bytes += len(dump(task).encode()) + 128  # enclosing JSON indentation
            require(encoded_bytes <= byte_budget, "proc total output cap exceeded")
            tasks.append(task)
    return {"tasks": tasks, "unreadable": unreadable, "vanished": vanished,
            "scan_ns": time.monotonic_ns() - started}


def proc_hints(tasks, enrollment):
    """An exclusive *provisional* partition, never executable-entry proof."""
    by_pid = {row["pid"]: row for row in tasks}
    roots = {r["pid"]: (int(r["start_ticks"]), h["id"])
             for h in enrollment["homes"] for r in h["capture_roots"]}
    result, memo = {}, {}
    for task in tasks:
        chain, seen, current = [], set(), task
        home, family = "unattributed", "unattributed"
        while current and current["pid"] not in seen:
            pid = current["pid"]
            if pid in memo:
                home, family = memo[pid]
                break
            seen.add(pid)
            chain.append(current)
            if pid in roots and roots[pid][0] == current["start_ticks"]:
                home = roots[pid][1]
                break
            parent = by_pid.get(current["ppid"])
            current = parent if parent and parent["start_ticks"] <= current["start_ticks"] else None
        for ancestor in reversed(chain):
            if home != "unattributed":
                observed = entry(ancestor["executable"], ancestor["argv"], enrollment, home)
                if observed:
                    family = observed["family"]
            memo[ancestor["pid"]] = (home, family)
        result[(task["pid"], task["start_ticks"])] = memo[task["pid"]]
    return result


def proc_model_spec(value, enrollment):
    checked(value, "proc-model")
    homes = {h["id"]: h for h in enrollment["homes"]}
    pairs, paths = set(), set()
    for profile in value["profiles"]:
        home, family = profile["home"], profile["family"]
        require(home in homes, "model home not enrolled")
        require((home, family) not in pairs, "duplicate model home/family")
        pairs.add((home, family))
        owner = homes[home]
        require(profile["code_ref"] == owner["code_ref"] and
                profile["configuration_sha256"] == owner["configuration_sha256"],
                "model code/configuration mismatch")
        path = profile["record_path"]
        require(os.path.normpath(path) == path and path.startswith(owner["home"] + "/"),
                "model record outside published home")
        # One record has one exclusive owner. Disallow even different selectors
        # on the same record: their events could overlap without detection.
        require(path not in paths, "shared model tick record")
        paths.add(path)
    return value


def read_proc_ticks(specification, byte_budget):
    readings = []
    for profile in specification["profiles"]:
        before = time.monotonic_ns()
        path = Path(profile["record_path"])
        # Walk with openat + NOFOLLOW, not a check/open race through a mutable
        # ancestor symlink. Files are read only; no owner state is created.
        fd = os.open("/", os.O_RDONLY | os.O_DIRECTORY)
        try:
            for part in path.parts[1:-1]:
                child = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
                os.close(fd)
                fd = child
            record_fd = os.open(path.name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=fd)
            with os.fdopen(record_fd, "rb") as stream:
                identity = os.fstat(stream.fileno())
                require(stat.S_ISREG(identity.st_mode), "model tick record not regular")
                data = stream.read(65537)
                require(len(data) <= 65536, "model tick record exceeds 64 KiB")
        finally:
            os.close(fd)
        row = {"before_ns": before, "after_ns": time.monotonic_ns(),
               "device": identity.st_dev, "inode": identity.st_ino,
               "base64": base64.b64encode(data).decode("ascii"), "sha256": digest(data)}
        byte_budget -= len(dump(row).encode()) + 128
        require(byte_budget >= 0, "proc total output cap exceeded")
        readings.append(row)
    return readings


def account_proc_model(model, enrollment, synthetic, first, last, machine_births, machine_cpu, hz):
    spec = proc_model_spec(model["specification"], enrollment)
    require(synthetic or not spec["synthetic"], "synthetic model in real proc recording")
    samples = model["samples"]
    require(all(len(s) == len(spec["profiles"]) for s in samples), "model tick sample count mismatch")
    rows, totals = [], [Fraction(0), Fraction(0), Fraction(0)]
    for sample in samples:
        require(len({(r["device"], r["inode"]) for r in sample}) == len(sample),
                "aliased model tick records")
    duration = last["monotonic_ns"] - first["monotonic_ns"]
    for profile, begin, end in zip(spec["profiles"], *samples):
        raw = []
        for reading in (begin, end):
            require(reading["before_ns"] <= reading["after_ns"], "model tick read clock reversed")
            data = base64.b64decode(reading["base64"], validate=True)
            require(len(data) <= 65536 and digest(data) == reading["sha256"], "model tick seal mismatch")
            raw.append(data)
        require((begin["device"], begin["inode"]) == (end["device"], end["inode"])
                and raw[1].startswith(raw[0]), "model tick record rotated, truncated or rewritten")
        # Record reads enclose the measured machine window. Their longer rate
        # window is explicit; scaling it is part of the model, not measurement.
        require(begin["after_ns"] <= first["monotonic_ns"] < last["monotonic_ns"]
                <= end["before_ns"], "model tick reads do not enclose machine window")
        elapsed = end["after_ns"] - begin["after_ns"]
        require(0 < elapsed <= 310000000000, "invalid model tick duration")
        needle = profile["line_contains"].encode("utf-8")
        counts = [sum(needle in line for line in data.split(b"\n")[:-1]) for data in raw]
        ticks = counts[1] - counts[0]
        calibration = profile["calibration"]
        scale = Fraction(ticks * duration, elapsed * calibration["ticks"])
        estimates = [calibration[key] * scale for key in ("births", "user_ns", "system_ns")]
        totals = [a + b for a, b in zip(totals, estimates)]
        rows.append({"home": profile["home"], "family": profile["family"],
                     "tick_unit": profile["tick_unit"], "observed_record_ticks": ticks,
                     "record_window_ns": elapsed, "record_ticks_per_second": ticks * 1e9 / elapsed,
                     "record_boundary_skew_ns": {"before": first["monotonic_ns"] - begin["after_ns"],
                                                 "after": end["after_ns"] - last["monotonic_ns"]},
                     "estimated_births": float(estimates[0]),
                     "estimated_births_per_second": float(estimates[0] * 1000000000 / duration),
                     "estimated_user_ns": float(estimates[1]), "estimated_system_ns": float(estimates[2]),
                     "estimated_cpu_one_core_percent": float(sum(estimates[1:]) * 100 / duration),
                     "calibration": calibration, "ci_url": profile["ci_url"],
                     "evidence_sha256": profile["evidence_sha256"]})
    births_residual = machine_births - totals[0]
    cpu_residual = Fraction(machine_cpu * 1000000000, hz) - sum(totals[1:])
    covered = {(p["home"], p["family"]) for p in spec["profiles"]}
    uncovered = [{"home": h["id"], "family": f} for h in enrollment["homes"]
                 for f in FAMILIES if (h["id"], f) not in covered]
    contradiction = births_residual < 0 or cpu_residual < 0
    return {"basis": "CI-per-tick-model-times-live-record-rate; NOT measured attribution",
            "status": "model-total-contradiction" if contradiction else "pending-reviewed-model-baseline",
            "synthetic_calibration": spec["synthetic"], "by_home_family": rows,
            "estimated_births": float(totals[0]),
            "estimated_births_per_second": float(totals[0] * 1000000000 / duration),
            "estimated_user_ns": float(totals[1]), "estimated_system_ns": float(totals[2]),
            "estimated_cpu_one_core_percent": float(sum(totals[1:]) * 100 / duration),
            "machine_minus_model_residual": {"births": float(births_residual),
                "births_per_second": float(births_residual * 1000000000 / duration),
                "busy_cpu_ns": float(cpu_residual),
                "busy_cpu_one_core_percent": float(cpu_residual * 100 / duration)},
            "exact_machine_total_check": "contradiction" if contradiction else "nonnegative-not-proof",
            "uncovered_named_families": uncovered,
            "other_families": "unmodeled unless explicitly supplied; coverage is owner-attested, not discovered",
            "uncertainty": "No statistical error bound. CI work mix, unseen callers/children, version "
                "and tick-unit equivalence require review; observed log rates use a wider window. "
                "Positive residual mixes unmodeled supervision, workload, collector and model error; "
                "negative residual is a contradiction, never clipped. Do not add observed lower bounds "
                "to these estimates. No per-tick model recovers resident startup or partial boundary work."}


def account_proc(value):
    checked(value, "proc")
    enrollment = proc_enrollment(value["manifest"])
    snapshots, hz = value["snapshots"], value["clock_ticks"]
    first, last = snapshots[0]["boundary"], snapshots[-1]["boundary"]
    duration = last["monotonic_ns"] - first["monotonic_ns"]
    require(0 < duration <= 310000000000, "invalid proc duration")
    previous = None
    observations, birth_hints, cpu_hints = {}, {}, {}
    hint_changes = 0
    for snapshot in snapshots:
        at = snapshot["boundary"]
        require(at["boot_id"] == first["boot_id"], "proc boot changed")
        require(at["uptime_lower_ticks"] <= at["uptime_upper_ticks"], "invalid uptime bracket")
        if previous:
            require(at["monotonic_ns"] > previous["monotonic_ns"]
                    and at["machine_births"] >= previous["machine_births"]
                    and at["uptime_lower_ticks"] >= previous["uptime_lower_ticks"],
                    "proc counter reset or reversed samples")
        previous = at
        tasks = snapshot["tasks"]
        require(len({t["pid"] for t in tasks}) == len(tasks), "duplicate proc PID")
        hints = proc_hints(tasks, enrollment)
        for task in tasks:
            ident = (task["pid"], task["start_ticks"])
            hint = hints[ident]
            cpu = (task["user_ticks"], task["system_ticks"])
            if ident not in observations:
                observations[ident] = [cpu, cpu, hint, 1]
                if first["uptime_upper_ticks"] <= ident[1] < last["uptime_lower_ticks"]:
                    birth_hints[hint] = birth_hints.get(hint, 0) + 1
            else:
                row = observations[ident]
                require(all(a >= b for a, b in zip(cpu, row[1])), "proc CPU counter reset")
                if hint != row[2]:
                    hint_changes += 1
                delta = tuple(a - b for a, b in zip(cpu, row[1]))
                # Changed executable/ancestry is an unknown interval. Do not
                # transfer its whole history to the last observed family.
                bucket = hint if hint == row[2] else ("unattributed", "unattributed")
                totals = cpu_hints.setdefault(bucket, [0, 0])
                totals[0] += delta[0]
                totals[1] += delta[1]
                row[1], row[2], row[3] = cpu, hint, row[3] + 1
    observed_births = sum(birth_hints.values())
    user = sum(v[0] for v in cpu_hints.values())
    system = sum(v[1] for v in cpu_hints.values())
    machine_births = last["machine_births"] - first["machine_births"]
    # guest/guest_nice already occur in user/nice; idle and iowait are not busy.
    busy = lambda b: sum(b["cpu_ticks"][i] for i in (0, 1, 2, 5, 6, 7))
    machine_cpu = busy(last) - busy(first)
    require(machine_cpu >= 0, "machine CPU counter reset")
    buckets = sorted(set(birth_hints) | set(cpu_hints))
    result = {"format": "fm-supervision-proc-accounting.v1", "synthetic": value["synthetic"],
            "b0_status": "incomplete-unprivileged-attribution", "claimed_births_per_second_saved": 0,
            "duration_ns": duration, "clock_ticks": hz,
            "machine": {"births": machine_births, "births_per_second": machine_births * 1e9 / duration,
                        "busy_cpu_ticks": machine_cpu, "busy_cpu_one_core_percent":
                        machine_cpu / hz * 1e11 / duration},
            "observed": {"process_births_lower_bound": observed_births, "user_ticks": user,
                         "system_ticks": system, "cpu_one_core_percent_lower_bound":
                         (user + system) / hz * 1e11 / duration},
            "residual": {"births_not_observed": machine_births - observed_births,
                         "busy_cpu_ticks_not_observed": machine_cpu - user - system},
            "exclusive_measured_supervision_by_home_family": None,
            "provisional_not_measured_attribution": [
                {"home": h, "family": f, "observed_process_births": birth_hints.get((h, f), 0),
                 "user_ticks": cpu_hints.get((h, f), [0, 0])[0],
                 "system_ticks": cpu_hints.get((h, f), [0, 0])[1]} for h, f in buckets],
            "losses": {"unreadable_pid_samples": sum(s["unreadable"] for s in snapshots),
                       "unavailable_hint_samples": sum(t["hint_unavailable"]
                           for s in snapshots for t in s["tasks"]),
                       "vanished_pid_samples": sum(s["vanished"] for s in snapshots),
                       "single_sample_identities": sum(r[3] == 1 for r in observations.values()),
                       "observed_hint_changes": hint_changes,
                       "unseen_short_lived_tasks": "unknown; included in births_not_observed",
                       "unseen_execs_and_reparenting": "unknown; all source/home allocation provisional",
                       "nonleader_thread_births": "not sampled; included in births_not_observed",
                       "proc_visibility": "current PID namespace and proc mount permissions only; "
                       "not proof of machine-wide process visibility"},
            "startup_coverage": {"existing_identities_observed": sum(
                ident[1] < first["uptime_upper_ticks"] for ident in observations),
                "entry_history": "unavailable for every existing process",
                "barrier": "no simultaneous scan; boundary-tick births excluded conservatively"},
            "residual_explanation": "Machine minus observed, not machine minus supervision. Includes "
            "unseen short-lived processes/threads, boundary ticks, unreadable tasks, CPU before first/"
            "after last observation and between-sample exits. Observed work also includes workload/"
            "collector. Negative values are retained contradictions. No residual is claimed as savings."}
    result["model_derived_supervision"] = None
    if "model" in value:
        result["model_derived_supervision"] = account_proc_model(
            value["model"], enrollment, value["synthetic"], first, last, machine_births, machine_cpu, hz)
        result["b0_status"] = result["model_derived_supervision"]["status"]
    return result


def proc_with_deadline(seconds, action):
    def expired(_signum, _frame):
        raise ProcDeadline("proc total deadline exceeded; retain incomplete output")

    previous = signal.signal(signal.SIGALRM, expired)
    signal.setitimer(signal.ITIMER_REAL, seconds)
    try:
        return action()
    finally:
        signal.setitimer(signal.ITIMER_REAL, 0)
        signal.signal(signal.SIGALRM, previous)


def capture_proc(args):
    require(sys.platform == "linux", "proc capture needs Linux")
    require(1 <= args.seconds <= 300, "proc duration must be 1..300 seconds")
    return proc_with_deadline(args.seconds + 5, lambda: collect_proc(args))


def check_proc_fixture(value):
    checked(value, "proc-bounds-fixture")
    require(hasattr(signal, "setitimer"), "fixture needs interval timer support")

    def exercise():
        if "credentials" in value:
            credentials = value["credentials"]
            proc_credentials(credentials["euid"], "CapEff:\t" + credentials["cap_eff"] + "\n")
        # The bounded pause exercises timer delivery. The optional read probe
        # instead delivers that same handler deterministically inside the real
        # proc_task/scan catch regions, on the last PID of the second scan.
        # Only this closed fixture command constructs substitute readers.
        time.sleep(value["pause_ms"] / 1000)
        region = value.get("read_region")
        require(not value.get("expire_on_final_task") or region is not None,
                "fixture expiry needs read_region")

        def scan_once(final):
            def task_reader(pid):
                stat_reads = 0

                def read_probe(path, _limit=None):
                    nonlocal stat_reads
                    part = path.rsplit("/", 1)[1]
                    if part == "stat":
                        stat_reads += 1
                        part = "stat-first" if stat_reads == 1 else "stat-last"
                    if (final and value.get("expire_on_final_task") and
                            pid == value["pids"][-1] and part == region):
                        signal.raise_signal(signal.SIGALRM)
                    if part.startswith("stat-"):
                        return b"1 (fixture) S " + b"0 " * 19
                    return b"/fixture/exe" if part == "exe" else b"fixture\0"

                return proc_task(pid, read_file=read_probe,
                                 read_link=lambda path: read_probe(path).decode("ascii"))

            return proc_scan(value["scan_deadline_ms"] / 1000, 65536, value,
                             task_reader=task_reader if region is not None else None)

        scan_once(False)
        scan = scan_once(True)
        return {"synthetic": True, "tasks_read": len(scan["tasks"])}

    return proc_with_deadline(value["deadline_ms"] / 1000, exercise)


def proc_credentials(euid, capabilities):
    require(euid != 0, "proc capture refuses root")
    effective = re.search(r"^CapEff:\s*([0-9a-fA-F]+)$", capabilities, re.M)
    require(effective is not None and int(effective[1], 16) == 0,
            "proc capture refuses effective capabilities; no privileged route")


def collect_proc(args):
    proc_credentials(os.geteuid(), read_bytes("/proc/self/status", 16384).decode("ascii"))
    require(os.environ.get("FM_SUPERVISION_PROC_LIVE") == "1", "proc live capture disabled")
    require(1 <= args.seconds <= 300, "proc duration must be 1..300 seconds")
    require(1000 <= args.interval_ms <= 10000, "proc interval must be 1000..10000 ms")
    require(4096 <= args.max_bytes <= MAX_BYTES, "proc byte bound must be 4096..67108864")
    enrollment = proc_enrollment(load_json(args.manifest))
    specification = proc_model_spec(load_json(args.model), enrollment) if args.model else None
    require(specification is None or not specification["synthetic"], "live capture refuses synthetic model")
    hz = os.sysconf("SC_CLK_TCK")
    value = {"format": "fm-supervision-proc.v1", "synthetic": False,
             "manifest": enrollment, "clock_ticks": hz, "snapshots": []}
    output = Path(args.output)
    output.mkdir(mode=0o700)
    os.chmod(output, 0o700)
    # This record is part of the TOTAL output budget, including error cases.
    started = {"method": "unprivileged-proc", "seconds": args.seconds,
               "max_bytes": args.max_bytes, "interval_ms": args.interval_ms, "complete": False}
    write_private(output / "started.json", started)
    used = len(dump(started).encode())
    deadline = time.monotonic() + args.seconds
    hard_deadline = deadline + 2  # final scan budget, no unbounded catch-up
    if specification is not None:
        value["model"] = {"specification": specification, "samples": [read_proc_ticks(
            specification, args.max_bytes - used - len(dump(value).encode()) - 16384)]}
    before = proc_boundary(hz)
    while True:
        scan = proc_scan(hard_deadline, args.max_bytes - len(dump(value).encode()) - used - 16384)
        scan["boundary"] = before if not value["snapshots"] else proc_boundary(hz)
        value["snapshots"].append(scan)
        if len(value["snapshots"]) == 1:
            available = {t["pid"]: t["start_ticks"] for t in scan["tasks"]}
            require(all(available.get(r["pid"]) == int(r["start_ticks"])
                        for h in enrollment["homes"] for r in h["capture_roots"]),
                    "published proc root missing, unreadable or replaced at startup")
        # Bound in-memory/output growth before another scan. A cap refusal
        # leaves started.json, never a partial report claiming success.
        require(len(dump(value).encode()) + used + 16384 <= args.max_bytes,
                "proc total output cap exceeded")
        if time.monotonic() >= deadline and len(value["snapshots"]) >= 2:
            break
        time.sleep(max(0, min(args.interval_ms / 1000, deadline - time.monotonic())))
    if specification is not None:
        value["model"]["samples"].append(read_proc_ticks(
            specification, args.max_bytes - used - len(dump(value).encode()) - 16384))
    result = account_proc(value)
    raw, report = dump(value).encode(), dump(result).encode()
    require(len(raw) + len(report) + used <= args.max_bytes, "proc total output cap exceeded")
    write_private(output / "proc.json", value)
    write_private(output / "report.json", result)
    return {"output": str(output), "recording_complete": True,
            "b0_status": result["b0_status"], "proc_sha256": digest(raw),
            "report_sha256": digest(report), "total_bytes": len(raw) + len(report) + used}


# strace prints one line per traced task with -f -o, and unfinished/resumed calls
# can interleave. Unknown syntax is loss, never a guessed successful entry.
LINE = re.compile(r"^(?:\[pid\s+)?(\d+)\]?\s+(\d+\.\d+)\s+(.*)$")
RETURN = re.compile(r"^\s*=\s+([0-9]+)(?:\s|$)")
CSTRING = re.compile(r'"(?:[^"\\]|\\.)*"')


def syscall_parts(body):
    """Split top-level operands, never delimiters inside C strings/containers."""
    opening = body.find("(")
    require(opening > 0, "syscall opening missing")
    call = body[:opening]
    cursor = start = opening + 1
    stack, arguments = [], []
    while cursor < len(body):
        char = body[cursor]
        if char == '"':
            match = CSTRING.match(body, cursor)
            require(match is not None, "unterminated syscall string")
            cursor = match.end()
            continue
        if char == ")" and not stack:
            arguments.append(body[start:cursor].strip())
            return call, arguments, body[cursor + 1:]
        if char in "([{":
            stack.append(char)
        elif char in ")]}":
            require(stack and stack.pop() == {")": "(", "]": "[", "}": "{"}[char],
                    "unbalanced syscall operand")
        elif char == "," and not stack:
            arguments.append(body[start:cursor].strip())
            start = cursor + 1
        cursor += 1
    raise Refused("unterminated syscall")


def c_string(text):
    """Decode strace's C byte escapes, including octal UTF-8, without evaluation."""
    require(CSTRING.fullmatch(text) is not None, "truncated/unreadable string")
    result = bytearray()
    cursor = 1
    escapes = {"a": 7, "b": 8, "t": 9, "n": 10, "v": 11, "f": 12,
               "r": 13, '"': 34, "\\": 92}
    while cursor < len(text) - 1:
        char = text[cursor]
        cursor += 1
        if char != "\\":
            result.extend(char.encode("utf-8"))
            continue
        char = text[cursor]
        cursor += 1
        if char in "01234567":
            digits = char
            while cursor < len(text) - 1 and len(digits) < 3 and text[cursor] in "01234567":
                digits += text[cursor]
                cursor += 1
            number = int(digits, 8)
            require(number <= 255, "invalid byte escape")
            result.append(number)
        else:
            require(char in escapes, "unsupported C escape")
            result.append(escapes[char])
    require(0 not in result, "NUL in exec string")
    return result.decode("utf-8", "surrogateescape")


def exec_operands(call, arguments):
    path_index = 0 if call == "execve" else 1
    require(len(arguments) == (3 if call == "execve" else 5), "exec operand count")
    executable = c_string(arguments[path_index])
    text = arguments[path_index + 1]
    require(text.startswith("[") and text.endswith("]"), "exec argv missing/truncated")
    cursor, result = 1, []
    while cursor < len(text) - 1:
        while cursor < len(text) - 1 and text[cursor].isspace():
            cursor += 1
        if cursor == len(text) - 1:
            break
        match = CSTRING.match(text, cursor)
        require(match is not None, "truncated/unreadable exec argv")
        result.append(c_string(match.group()))
        cursor = match.end()
        while cursor < len(text) - 1 and text[cursor].isspace():
            cursor += 1
        if cursor != len(text) - 1:
            require(text[cursor] == ",", "exec argv separator missing")
            cursor += 1
            require(text[cursor:].strip() != "]", "trailing exec argv comma")
    return executable, result


def normalize(raw, metadata):
    active = {}
    events = []
    losses = {"unknown_lines": 0, "unfinished_calls": 0, "unresolved_argv": 0,
              "unknown_parents": 0, "attachment_gaps": 1}
    # Attach is not a simultaneous machine-wide barrier. Never certify this
    # sampler's startup gap away; an independently sealed kernel trace can.
    calls = []
    for seed in metadata["seeds"]:
        ident = "seed:" + str(seed["pid"]) + ":" + seed["start_ticks"]
        active[seed["pid"]] = ident
        events.append({"kind": "seed", "id": ident, "at_ns": metadata["before"]["wall_ns"],
                       "parent": "", "argv": seed["argv"], "home": seed["home"], "thread": False,
                       "executable": seed["executable"], "exec_evidence": seed["exec_evidence"]})
    pending = {}
    for line_number, line in enumerate(raw.splitlines(), 1):
        match = LINE.fullmatch(line)
        if not match:
            losses["unknown_lines"] += 1
            continue
        pid = int(match[1])
        at = int(Decimal(match[2]) * 1000000000)
        body = match[3]
        if body.endswith("<unfinished ...>"):
            if pid in pending:
                losses["unfinished_calls"] += 1
            pending[pid] = (body[:-len("<unfinished ...>")], at, line_number)
            continue
        resumed = re.match(r"<\.\.\. \w+ resumed>(.*)", body)
        if resumed:
            if pid not in pending:
                losses["unfinished_calls"] += 1
                continue
            prefix, at, line_number = pending.pop(pid)
            body = prefix + resumed[1]
        calls.append((at, line_number, pid, body))
    losses["unfinished_calls"] += len(pending)
    # In a vfork/unfinished clone, the child can print exec before its parent's
    # syscall returns. Sort by ENTRY timestamp AND original entry-line ordinal;
    # timestamp resolution can tie a parent entry, child exec and parent resume.
    for at, line_number, pid, body in sorted(calls):
        if body.startswith("--- "):
            continue
        if body.startswith(("+++ exited with ", "+++ killed by ")):
            active.pop(pid, None)
            continue
        try:
            call, arguments, outcome = syscall_parts(body)
        except Refused:
            losses["unknown_lines"] += 1
            continue
        if call in ("wait4", "waitid", "exit", "exit_group"):
            continue
        returned = RETURN.match(outcome)
        if call in ("clone", "clone3", "fork", "vfork"):
            if not returned:
                if "= -1 " not in body:
                    losses["unknown_lines"] += 1
                continue
            child = int(returned[1])
            if child in active:
                losses["unknown_lines"] += 1  # PID reuse with a missed exit
            parent = active.get(pid, "")
            if not parent:
                losses["unknown_parents"] += 1
            ident = str(child) + ":" + str(at) + ":" + str(line_number)
            active[child] = ident
            events.append({"kind": "birth", "id": ident, "parent": parent, "at_ns": at,
                           "argv": [], "home": "", "thread": "CLONE_THREAD" in body,
                           "executable": "", "exec_evidence": "none"})
        elif call in ("execve", "execveat"):
            if not returned or int(returned[1]) != 0:
                if "= -1 " not in body:
                    losses["unknown_lines"] += 1
                continue
            ident = active.get(pid)
            if not ident:
                losses["unknown_parents"] += 1
                continue
            try:
                executable, argv = exec_operands(call, arguments)
                if not executable.startswith("/") or not argv:
                    # Relative/AT_EMPTY_PATH execs need cwd/fd resolution that
                    # this capture does not provide. Retain, never guess proof.
                    losses["unresolved_argv"] += 1
            except Refused:
                losses["unresolved_argv"] += 1
                executable, argv = "", []
            events.append({"kind": "exec", "id": ident, "parent": "", "at_ns": at,
                           "argv": argv, "home": "", "thread": False,
                           "executable": executable, "exec_evidence": call})
        else:
            losses["unknown_lines"] += 1
    events.sort(key=lambda event: event["at_ns"])
    before, after = metadata["before"], metadata["after"]
    return {"format": "fm-supervision-trace.v1", "synthetic": False,
            "start_ns": before["wall_ns"], "end_ns": after["wall_ns"],
            "monotonic_duration_ns": after["monotonic_ns"] - before["monotonic_ns"],
            "machine_births": after["machine_births"] - before["machine_births"],
            "capture_complete": metadata["complete"], "losses": losses, "events": events}


def import_strace(path):
    path = Path(path)
    metadata = load_json(path / "finished.json")
    require(metadata["format"] == "fm-supervision-capture.v1", "unsupported capture")
    raw = read_bytes(path / "strace.log")
    errors = read_bytes(path / "strace.stderr")
    require(digest(raw) == metadata["raw_sha256"] and digest(errors) == metadata["stderr_sha256"],
            "capture digest mismatch")
    enrollment = manifest(load_json(path / "manifest.json"))
    require(digest(dump(enrollment).encode()) == metadata["manifest_sha256"], "manifest changed")
    return checked(normalize(raw.decode("utf-8", "strict"), metadata), "trace")


def entry(executable, argv, enrollment, home_hint=""):
    if not argv:
        return None
    script_index = 0
    script = executable  # kernel exec path, NEVER caller-controlled argv[0]
    if executable in SHELL_EXECUTABLES:
        script_index = 1
        while script_index < len(argv) and argv[script_index].startswith("-"):
            option = argv[script_index]
            if option == "--":
                script_index += 1
                break
            # -c/-s and options with operands cannot prove script execution.
            if not re.fullmatch(r"-[euxv]+", option):
                return None
            script_index += 1
        if script_index >= len(argv):
            return None
        script = argv[script_index]
    for home in enrollment["homes"]:
        if home["id"] != home_hint:
            continue
        for name, family in SCRIPT_FAMILIES.items():
            if script == home["code_root"] + "/bin/" + name:
                arguments = argv[script_index + 1:]
                target, action, shape = "", "", "recognized"
                if family == "control":
                    target = arguments[0] if arguments else ""
                    action = arguments[1] if len(arguments) > 1 else ""
                    if not target or not action:
                        shape = "malformed"
                    elif action not in ("interrupt", "exit", "relaunch"):
                        shape = "unknown"
                elif family == "spawn":
                    target = arguments[0] if arguments else ""
                    action = "restore" if "--restore" in arguments[1:] else (
                        "relaunch" if "--relaunch" in arguments[1:] else "spawn")
                    if not target:
                        shape = "malformed"
                elif family == "crew-state":
                    target = arguments[0] if arguments else ""
                    action = "read"
                else:
                    action = {"watch": "observe", "wake-drain": "drain",
                              "fleet-snapshot": "snapshot"}[family]
                lifecycle = family in ("spawn", "control") and shape == "recognized"
                return {"family": family, "home": home["id"], "target": target, "action": action,
                        "call_shape": shape, "lifecycle_entry": lifecycle}
    return None


def account(trace, enrollment):
    checked(trace, "trace")
    manifest(enrollment)
    require(trace["end_ns"] > trace["start_ns"], "empty/reversed trace window")
    duration = trace["monotonic_duration_ns"]
    require(duration > 0, "invalid monotonic duration")
    owners, origins, births, entries, edges = {}, {}, {}, [], {}
    process_homes, current_invocations, invocations = {}, {}, {}
    totals = {name: 0 for name in FAMILIES + ("unattributed",)}
    origin_totals = dict(totals)
    thread_births = 0
    seed_ownership = []
    last_at = trace["start_ns"]
    for event in trace["events"]:
        at, ident, kind = event["at_ns"], event["id"], event["kind"]
        require(trace["start_ns"] <= at <= trace["end_ns"], "event outside capture window")
        require(at >= last_at, "events not in chronological order")
        last_at = at
        if kind == "seed":
            require(ident not in owners, "duplicate seed")
            require(not event["parent"] and not event["thread"], "malformed seed")
            require(event["home"] in enrollment["enrolled_homes"], "seed home not enrolled")
            process_homes[ident] = event["home"]
            require(event["exec_evidence"] == "proc-exe-cmdline" and event["executable"],
                    "seed needs qualified executable/cmdline evidence")
            observed = entry(event["executable"], event["argv"], enrollment, event["home"])
            owners[ident] = observed["family"] if observed else "unattributed"
            seed_ownership.append({"id": ident, "family": owners[ident],
                                   "evidence": "proc-exe-cmdline",
                                   "qualification": "cmdline-hint-not-observed-entry"})
            origins[ident] = owners[ident]
            invocation = ident + ":initial"
            current_invocations[ident] = invocation
            invocations[invocation] = {"family": owners[ident], "seed": True,
                                       "exclusive_child_births": 0, "self_births": 0}
        elif kind == "birth":
            require(ident not in owners, "duplicate birth identity")
            parent = event["parent"]
            require(parent in owners or trace["losses"]["unknown_parents"] > 0,
                    "birth without known parent or declared loss")
            require(not event["argv"] and not event["home"] and not event["executable"]
                    and event["exec_evidence"] == "none", "birth contains fabricated exec/home")
            process_homes[ident] = process_homes.get(parent, "")
            owners[ident] = owners.get(parent, "unattributed")
            origins[ident] = origins.get(parent, "unattributed")
            current_invocations[ident] = current_invocations.get(parent, "unattributed")
            births[ident] = {"family": owners[ident], "origin": origins[ident], "direct": False,
                             "invocation": current_invocations[ident]}
            thread_births += int(event["thread"])
        else:
            require(ident in owners, "exec without birth/seed")
            require(not event["parent"] and not event["thread"] and not event["home"], "malformed exec")
            require(event["exec_evidence"] in ("execve", "execveat"), "exec needs syscall evidence")
            require((event["argv"] and event["executable"])
                    or trace["losses"]["unresolved_argv"] > 0, "exec evidence missing without loss")
            observed = entry(event["executable"], event["argv"], enrollment, process_homes[ident])
            if observed:
                caller = owners[ident]
                invocation = ident + ":entry:" + str(len(entries))
                entries.append(dict(observed, id=ident, at_ns=at, caller_family=caller,
                                    invocation=invocation, exec_evidence=event["exec_evidence"],
                                    executable=event["executable"],
                                    caller_invocation=current_invocations[ident]))
                invocations[invocation] = {"family": observed["family"], "seed": False,
                                           "exclusive_child_births": 0, "self_births": 0}
                current_invocations[ident] = invocation
                edge = caller + " -> " + observed["family"]
                edges[edge] = edges.get(edge, 0) + 1
                owners[ident] = observed["family"]
                if origins[ident] == "unattributed":
                    origins[ident] = observed["family"]
                if ident in births and not births[ident]["direct"]:
                    births[ident]["family"] = observed["family"]
                    births[ident]["direct"] = True
                    births[ident]["invocation"] = invocation
    invocations.setdefault("unattributed", {"family": "unattributed", "seed": False,
                                            "exclusive_child_births": 0, "self_births": 0})
    for birth in births.values():
        totals[birth["family"]] += 1
        origin_totals[birth["origin"]] += 1
        key = "self_births" if birth["direct"] else "exclusive_child_births"
        invocations[birth["invocation"]][key] += 1
    observed_births = len(births)
    residual = trace["machine_births"] - observed_births
    lossless = trace["capture_complete"] and not any(trace["losses"].values())
    seed_hints = sum(row["family"] != "unattributed" for row in seed_ownership)
    complete = lossless and totals["unattributed"] == 0 and residual >= 0 and seed_hints == 0
    return {"format": "fm-supervision-accounting.v1", "synthetic": trace["synthetic"],
            "claimed_births_per_second_saved": 0, "duration_ns": duration,
            "exclusive_births": totals, "observed_births": observed_births,
            "thread_births_included": thread_births, "entries": entries, "caller_edges": edges,
            "seed_ownership": seed_ownership, "seed_cmdline_hints": seed_hints,
            "entry_counts": {family: sum(row["family"] == family for row in entries) for family in FAMILIES},
            "per_invocation": invocations, "births_by_origin_ancestry": origin_totals,
            "machine_births": trace["machine_births"], "residual": residual,
            "residual_explanation": ("Outside explicitly attached descendant trees, including the tracer; "
                                     "also capture/attachment gaps if incomplete. Not additional savings."),
            "losses": trace["losses"], "complete_for_attached_trees": complete,
            "b0_status": "pending-reviewed-real-capture",
            "births_per_second": observed_births * 1000000000 / duration}


def corpus(value):
    checked(value, "replay")
    manifest(value["manifest"])
    checked(value["trace"], "trace")
    require(value["synthetic"] == value["trace"]["synthetic"], "synthetic provenance mismatch")
    records = {}
    for record in value["records"]:
        try:
            raw = base64.b64decode(record["base64"], validate=True)
        except binascii.Error as error:
            raise Refused("bad record base64") from error
        require(len(raw) <= 1048576 and digest(raw) == record["sha256"], "record seal mismatch")
        key = (record["kind"], record["name"])
        require(key not in records, "duplicate replay record")
        records[key] = raw
    request_ids = set()
    previous_at = value["trace"]["start_ns"]
    for request in value["requests"]:
        require(request["id"] not in request_ids, "duplicate request id")
        request_ids.add(request["id"])
        require(previous_at <= request["at_ns"] <= value["trace"]["end_ns"], "request clock/order")
        previous_at = request["at_ns"]
        for response in request["adapter_responses"]:
            require(request["at_ns"] <= response["at_ns"] <= value["trace"]["end_ns"], "response clock")
            for field in ("stdout_base64", "stderr_base64"):
                try:
                    decoded = base64.b64decode(response[field], validate=True)
                    require(len(decoded) <= 1048576, "adapter response exceeds byte bound")
                except binascii.Error as error:
                    raise Refused("bad adapter base64") from error
    return records


def main():
    if sys.version_info < (3, 9):
        print("supervision-accounting: refused: Python >=3.9 required", file=sys.stderr)
        return 2
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest="verb", required=True)
    commands.add_parser("probe", help="read-only availability/privilege report; never attaches")
    for name in ("validate-manifest", "account", "replay", "read-record", "import-strace"):
        sub = commands.add_parser(name)
        sub.add_argument("input")
        if name == "account":
            sub.add_argument("--manifest", required=True)
        if name == "read-record":
            sub.add_argument("--kind", choices=("queue", "status", "claim"), required=True)
            sub.add_argument("--name", required=True)
    sub = commands.add_parser("account-proc", help="replay bounded proc.json; never certifies B0")
    sub.add_argument("input")
    sub = commands.add_parser("check-proc-fixture", help="synthetic-only deadline/scan/cap guard probes")
    sub.add_argument("input")
    sub = commands.add_parser("capture-proc", help="unprivileged proc-only finite sampling, no attach")
    sub.add_argument("--manifest", required=True)
    sub.add_argument("--output", required=True)
    sub.add_argument("--seconds", type=int, required=True)
    sub.add_argument("--interval-ms", type=int, default=1000)
    sub.add_argument("--max-bytes", type=int, default=8 * 1024 * 1024)
    sub.add_argument("--model", help="owner-supplied CI costs and admitted append-only tick records")
    sub = commands.add_parser("capture", help="bounded attach only; never executes a workload")
    sub.add_argument("--manifest", required=True)
    sub.add_argument("--home", required=True)
    sub.add_argument("--output", required=True)
    sub.add_argument("--seconds", type=int, required=True)
    sub.add_argument("--max-bytes", type=int, default=MAX_BYTES)
    sub.add_argument("--acknowledge-ptrace", action="store_true")
    args = parser.parse_args()
    try:
        if args.verb == "probe":
            result = probe()
        elif args.verb == "capture":
            result = capture(args)
        elif args.verb == "capture-proc":
            result = capture_proc(args)
        elif args.verb == "account-proc":
            result = account_proc(load_json(args.input))
        elif args.verb == "check-proc-fixture":
            result = check_proc_fixture(load_json(args.input))
        elif args.verb == "validate-manifest":
            value = manifest(load_json(args.input))
            result = {"valid": True, "certified_complete": value["certified_complete"],
                      "homes": len(value["homes"])}
        elif args.verb == "import-strace":
            result = import_strace(args.input)
        elif args.verb == "account":
            result = account(load_json(args.input), load_json(args.manifest))
        else:
            value = load_json(args.input)
            records = corpus(value)
            if args.verb == "read-record":
                key = (args.kind, args.name)
                require(key in records, "record not found")
                sys.stdout.buffer.write(records[key])
                return 0
            result = account(value["trace"], value["manifest"])
            result["sealed_records"] = len(records)
            result["requests"] = len(value["requests"])
        sys.stdout.write(dump(result))
        return 0
    except KeyboardInterrupt:
        print("supervision-accounting: refused: interrupted; capture evidence retained", file=sys.stderr)
        return 2
    except (ProcDeadline, Refused, OSError, ValueError, KeyError, IndexError, TypeError, RecursionError) as error:
        print("supervision-accounting: refused: " + str(error), file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
