#!/usr/bin/env python3
"""Bounded P0 accounting; CI-only fixture workloads, never mode activation.

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
`source-families` prints the retrospective coverage/plan source registry.
`validate-workload FILE [--bindings FILE]` validates sealed v2/v3 data offline.
V3 replay needs the sealed capture-bindings/v1 sidecar; validation launches no
adapter or capture. V1 remains readable through replay/read-record but is
insufficient here. No reader certifies B0 or production adapters.
`prepare-calibration-plan FILE --revision SHA --checkout ABSOLUTE` resolves
@REVISION@ and @CHECKOUT@ tokens offline, validates the complete plan and
preserves its provenance/pins; it executes nothing and reads no home.
`calibrate-ci PLAN --output NEW_DIR --repeats 3..9` runs a trusted, bounded
fixture plan ONLY in GitHub Actions, using installed strace and GNU time.
This is the only workload-launching verb; never use a plan naming live homes.
`count-ticks RECORDS --capture PROC` counts sealed, owner-admitted saved log
bytes using capture wall bounds or instrumented uptime brackets, with the
exact measured monotonic rate denominator.
`reconcile PROC --ticks RECORDS [--calibration FILE ...]` is offline only.
Missing/stale inputs remain uncovered, never zero-cost or measured families.
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
# Shared by retrospective coverage and CI plans, including unavailable units.
# FAMILIES remains the narrower proc-hint classifier, not a coverage registry.
SOURCE_FAMILIES = FAMILIES + ("procevent-reconcile", "park-check", "owner-guard",
    "attached-arm", "supervision-host", "custom-check", "turnend-guard")
SCRIPT_FAMILIES = {"fm-" + name + ".sh": name for name in FAMILIES}
SHELL_EXECUTABLES = ("/bin/bash", "/usr/bin/bash", "/bin/sh", "/usr/bin/sh")
JOURNAL_TIMESTAMPS = ("supervision-tick-v1", "supervision-tick-v2", "supervision-tick-v3")
BOOT_ID_PATTERN = r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"


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


def validate(value, schema, root=None, where="$", references=None):
    """Closed owner-schema subset; only fixed local cross-schema references."""
    root = root or schema
    references = {} if references is None else references
    if "$ref" in schema:
        ref = schema["$ref"]
        if ref == "tick-counts-v1.schema.json":
            if ref not in references:
                references[ref] = load_json(SCHEMAS / ref)
            validate(value, references[ref], where=where, references=references)
        elif ref.startswith("replay-v2.schema.json#/"):
            name, pointer = ref.split("#/", 1)
            if name not in references:
                references[name] = load_json(SCHEMAS / name)
            external = references[name]
            target = external
            for part in pointer.split("/"):
                require(type(target) is dict and part in target, "unknown schema reference")
                target = target[part]
            validate(value, target, external, where, references)
        else:
            require(ref.startswith("#/$defs/"), "unsupported schema reference")
            validate(value, root["$defs"][ref[8:]], root, where, references)
        return
    types = {"object": dict, "array": list, "string": str, "integer": int,
             "boolean": bool, "null": type(None)}
    if "type" in schema:
        admitted = schema["type"] if isinstance(schema["type"], list) else [schema["type"]]
        require(any((type(value) in (int, float) if kind == "number" else type(value) is types[kind])
                    for kind in admitted), where + ": wrong type")
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
                validate(item, properties[key], root, where + "." + key, references)
    elif isinstance(value, list):
        require(schema.get("minItems", 0) <= len(value) <= schema.get("maxItems", 1000000),
                where + ": array size")
        if schema.get("uniqueItems"):
            require(len({json.dumps(v, sort_keys=True) for v in value}) == len(value),
                    where + ": duplicate array item")
        for index, item in enumerate(value):
            validate(item, schema.get("items", {}), root, where + "[" + str(index) + "]", references)
    elif isinstance(value, str):
        require(schema.get("minLength", 0) <= len(value) <= schema.get("maxLength", MAX_BYTES),
                where + ": string size")
        if "pattern" in schema:
            require(re.fullmatch(schema["pattern"], value) is not None, where + ": pattern")
    elif type(value) in (int, float):
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
        # trace=process also includes signal sends (for example the watcher's
        # watchdog cleanup). They create neither births nor executable entries;
        # delivery/termination is represented by strace's separate signal/exit rows.
        if call in ("wait4", "waitid", "exit", "exit_group", "kill", "tkill", "tgkill", "pidfd_send_signal"):
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


def workload(value):
    """Versioned read-only factory; v1 accounting semantics remain unchanged."""
    if type(value) is dict and value.get("format") == "fm-supervision-replay.v1":
        corpus(value)
        raise Refused("v1 accounting corpus is insufficient for P1 whole-workload measurement")
    version = 3 if type(value) is dict and value.get("format") == "fm-supervision-replay.v3" else 2
    validate(value, load_json(SCHEMAS / ("replay-v" + str(version) + ".schema.json")))
    manifest(value["manifest"])
    checked(value["trace"], "trace")
    if version == 3:
        from fm_supervision_bindings import WorkloadV3
        return WorkloadV3(value)
    from fm_supervision_replay import _Workload
    return _Workload(value)


def bound_workload(value, bindings):
    """Bind v3 to its closed, sealed live-outcome/read-schedule sidecar."""
    model = workload(value)
    require(value["format"] == "fm-supervision-replay.v3", "capture bindings require workload v3")
    validate(bindings, load_json(SCHEMAS / "capture-bindings-v1.schema.json"))
    return model.bind(bindings)


def content_seal(payload):
    return {"payload": payload, "sha256": digest(dump(payload).encode())}


def unseal(value):
    require(set(value) == {"payload", "sha256"}, "invalid sealed envelope")
    require(value["sha256"] == digest(dump(value["payload"]).encode()), "artifact seal mismatch")
    return value["payload"]


def attribution_input(value, kind):
    checked(value, "attribution")
    require(value["format"] == "fm-supervision-" + kind + ".v1", "wrong attribution input format")
    pairs = [(p["home"], p["family"]) for p in value["profiles"]]
    require(len(set(pairs)) == len(pairs), "duplicate attribution home/family")
    plan_keys = {"argv", "environment", "fixture_files", "ticks_per_sample"}
    record_keys = {"record_path", "line_contains", "timestamp", "coverage_start_wall_ns",
                   "coverage_end_wall_ns", "base64", "sha256", "fragments", "instrumentation_error", "record_kind"}
    for profile in value["profiles"]:
        require(not (set(profile) & ((record_keys | {"timestamp_field"}) if kind == "calibration-plan" else plan_keys)),
                "fields from wrong attribution input kind")
        if "unavailable" in profile:
            require(not (set(profile) & (plan_keys | record_keys | {"timestamp_field"})), "unavailable profile has data")
        else:
            required = (plan_keys if kind == "calibration-plan" else {
                "line_contains", "timestamp", "coverage_start_wall_ns", "coverage_end_wall_ns"}) | {"tick_unit", "work_mix_sha256"}
            require(required <= profile.keys(), "missing attribution input fields")
            if kind == "tick-records":
                scalar = {"record_path", "base64", "sha256"}
                require((scalar <= profile.keys() and "fragments" not in profile) or
                        ("fragments" in profile and not (scalar & profile.keys())), "missing or ambiguous tick fragments")
            if kind == "calibration-plan":
                require(profile["work_mix_sha256"] == digest(dump(profile["fixture_files"]).encode()),
                        "CI fixture work-mix seal mismatch")
                fixture_paths = set()
                for record in profile["fixture_files"]:
                    path = record["path"]
                    require(not path.startswith("/") and os.path.normpath(path) == path
                            and ".." not in Path(path).parts and path not in fixture_paths,
                            "unsafe CI fixture path")
                    require(not path.startswith("state/.supervision-"), "reserved CI instrumentation path")
                    fixture_paths.add(path)
                    raw = base64.b64decode(record["base64"], validate=True)
                    require(len(raw) <= 65536 and digest(raw) == record["sha256"], "CI fixture seal mismatch")
            if kind == "tick-records":
                require(not ({"record_kind", "instrumentation_error"} & profile.keys()) or profile["timestamp"] in JOURNAL_TIMESTAMPS,
                        "journal state metadata on ordinary record")
                require("timestamp_field" not in profile or profile["timestamp"].startswith("json-"),
                        "timestamp field on non-JSON record")
                require(profile["timestamp"] != "json-epoch-seconds" or "timestamp_field" in profile,
                        "JSON epoch record needs timestamp field")
    return value


def ci_tick_count(records, profile):
    require(len({r["name"] for r in records}) == len(records), "duplicate CI tick record")
    pieces, boots, owned_starts = [], set(), []
    for record in records:
        data = base64.b64decode(record["base64"], validate=True)
        require(len(data) <= 6 * 1024 * 1024 and digest(data) == record["sha256"], "CI tick record seal mismatch")
        require(not data or data.endswith(b"\n"), "unfinished CI tick record")
        for line in data.splitlines():
            fields = line.decode("ascii").split("\t")
            require(len(fields) == 9 and fields[0] == "fm-supervision-tick.v3"
                    and (fields[1], fields[2]) == (profile["family"], profile["tick_unit"]),
                    "different family/unit or legacy format in CI tick scope")
            boots.add(fields[3])
            if fields[8] != "entry":
                owned_starts.append((int(fields[5]), fields[8]))
        pieces.append(data)
    require(not owned_starts or min(owned_starts) == (1, "start"), "CI owned fixture lost startup prefix")
    require(len(boots) == 1, "CI tick records have missing or mixed boot identity")
    boot_id = next(iter(boots))
    count, reason = count_instrumented_ticks(b"".join(pieces), profile,
        {"uptime_upper_ticks": 0, "boot_id": boot_id}, {"uptime_lower_ticks": 2**63-1}, 100)
    require(not reason and count == profile["ticks_per_sample"], "CI tick count mismatch or incomplete retention")
    return count, boot_id


def ci_cpu_values(reading):
    require(re.fullmatch(r"[0-9]+\.[0-9]{2} [0-9]+\.[0-9]{2}", reading), "invalid calibration CPU evidence")
    return [int(Decimal(v) * 1000000000) for v in reading.split()]


def calibration_uncertainty(samples):
    differences = [sum(ci_cpu_values(s["traced_cpu_reading"])) - s["user_ns"] - s["system_ns"]
                   for s in samples]
    return {"cpu_quantization_ns_per_component": 10000000,
            "trace_minus_untraced_cpu_ns_per_repeat_range": [min(differences), max(differences)],
            "repeat_ranges": {k: [min(s[k] for s in samples), max(s[k] for s in samples)]
                              for k in ("births", "user_ns", "system_ns")}}


def calibration_payload(value):
    payload = unseal(value)
    checked(payload, "calibration")
    plan = attribution_input(payload["plan"], "calibration-plan")
    require(len(payload["results"]) == len(plan["profiles"]), "calibration result count mismatch")
    boots = set()
    for profile, result in zip(plan["profiles"], payload["results"]):
        if "unavailable" in profile:
            require(result == {"unavailable": profile["unavailable"]}, "changed calibration gap")
            continue
        require(profile["code_ref"] == payload["revision"], "calibration revision mismatch")
        require(set(result) == {"samples", "uncertainty"}, "invalid measured calibration result")
        samples = result["samples"]
        require(len(samples) >= 3, "insufficient calibration repeats")
        require(result["uncertainty"] == calibration_uncertainty(samples), "calibration uncertainty mismatch")
        for sample in samples:
            raw = base64.b64decode(sample["trace_base64"], validate=True)
            require(digest(raw) == sample["trace_sha256"], "calibration trace seal mismatch")
            births = calibration_births(raw, profile["family"])
            require(sample["births"] == births, "calibration birth count mismatch")
            traced_ticks, traced_boot = ci_tick_count(sample["tick_records"], profile)
            cpu_ticks, cpu_boot = ci_tick_count(sample["cpu_tick_records"], profile)
            require(sample["ticks"] == traced_ticks == cpu_ticks and sample["boot_id"] == traced_boot == cpu_boot,
                    "calibration tick count or boot mismatch")
            boots.add(traced_boot)
            ci_cpu_values(sample["traced_cpu_reading"])
            cpu = ci_cpu_values(sample["cpu_reading"])
            require(cpu == [sample["user_ns"], sample["system_ns"]], "calibration CPU evidence mismatch")
        require(len({s["births"] for s in samples}) == 1, "nondeterministic calibration births")
    require(len(boots) <= 1, "calibration samples span different boots")
    return payload


def calibration_births(raw, family):
    text = raw.decode("utf-8", "strict")
    # Launch tracing starts before exec, unlike the live attach route. Seed the
    # first tracer child (GNU time); its one fork is the measured script entry.
    lines = text.splitlines()
    require(lines and LINE.fullmatch(lines[0]), "calibration trace has no root")
    root_pid = int(LINE.fullmatch(lines[0])[1])
    metadata = {"seeds": [{"pid": root_pid, "start_ticks": "0", "home": "ci",
        "argv": ["/usr/bin/time"], "executable": "/usr/bin/time",
        "exec_evidence": "proc-exe-cmdline"}],
        "before": {"wall_ns": 0, "monotonic_ns": 0, "machine_births": 0},
        "after": {"wall_ns": 2**63-1, "monotonic_ns": 1, "machine_births": 0}, "complete": True}
    trace = normalize(text, metadata)
    require(not any(v for k, v in trace["losses"].items() if k != "attachment_gaps"),
            "lossy calibration trace")
    for event in trace["events"]:
        # An inclusive parent cost cannot be combined with a separately priced
        # nested family. Isolated fixture scopes only; do not pretend to split CPU.
        if event["kind"] == "exec":
            nested = SCRIPT_FAMILIES.get(Path(event["executable"]).name)
            for argument in event["argv"][1:2]:
                nested = nested or SCRIPT_FAMILIES.get(Path(argument).name)
            require(not nested or nested == family, "nested family in calibration scope")
    return sum(event["kind"] == "birth" for event in trace["events"])


def ci_fixture(profile, fixture):
    fixture.mkdir(mode=0o700, exist_ok=False)
    for directory in ("state", "data", "config", "projects"):
        (fixture / directory).mkdir(mode=0o700)
    for record in profile["fixture_files"]:
        target = fixture / record["path"]  # already closed, sealed and path-validated
        target.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        target.write_bytes(base64.b64decode(record["base64"], validate=True))
    environment = dict(os.environ)
    environment.update({p["name"]: p["value"].replace("@FIXTURE@", str(fixture))
                        for p in profile["environment"]})
    for key, suffix in (("HOME", ""), ("FM_HOME", ""), ("FM_STATE_OVERRIDE", "/state"),
                        ("FM_DATA_OVERRIDE", "/data"), ("FM_CONFIG_OVERRIDE", "/config"),
                        ("FM_PROJECTS_OVERRIDE", "/projects")):
        require(environment.get(key) == str(fixture) + suffix, "CI fixture environment escapes scratch: " + key)
    return environment


def ci_run(argv, prefix, environment, deadline):
    # These are private CI fixture children, never live capture targets.
    def file_limit():
        resource.setrlimit(resource.RLIMIT_FSIZE, (1048576, 1048576))
    with open(str(prefix) + ".stdout", "wb") as stdout, open(str(prefix) + ".stderr", "wb") as stderr:
        child = subprocess.Popen(argv, env=environment, stdout=stdout, stderr=stderr,
                                 start_new_session=True, preexec_fn=file_limit)
        try:
            remaining = deadline - time.monotonic()
            require(remaining > 0, "CI calibration total deadline exceeded")
            status = child.wait(timeout=min(30, remaining))
        finally:
            try:
                os.killpg(child.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            child.wait()
    require(status == 0, "CI calibration command failed; evidence retained")


def ci_tick_records(fixture):
    require(not (fixture / "state/.supervision-ticks.error").exists(), "CI instrumentation invalidation")
    records, size = [], 0
    for name in (".supervision-entries.tsv", ".supervision-entries.previous.tsv",
                 ".supervision-watch-ticks.0.tsv", ".supervision-watch-ticks.1.tsv",
                 ".supervision-host-ticks.0.tsv", ".supervision-host-ticks.1.tsv"):
        path = fixture / "state" / name
        if path.exists():
            data = read_bytes(path, 6 * 1024 * 1024)
            records.append({"name": name, "base64": base64.b64encode(data).decode(), "sha256": digest(data)})
            size += len(data)
    return records, size


def calibrate_ci(args):
    require(os.environ.get("GITHUB_ACTIONS") == "true" and os.environ.get("RUNNER_ENVIRONMENT") == "github-hosted",
            "calibration runs only on GitHub-hosted Actions runners")
    require(sys.platform == "linux" and shutil.which("strace") and Path("/usr/bin/time").is_file(),
            "calibration requires Linux, installed strace and GNU time")
    require(3 <= args.repeats <= 9, "calibration repeats outside 3..9")
    revision = subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip()
    require(revision == os.environ.get("GITHUB_SHA"), "CI checkout is not exact GitHub revision")
    require(not subprocess.check_output(["git", "status", "--porcelain", "--untracked-files=no"]),
            "CI calibration checkout has tracked modifications")
    plan = attribution_input(load_json(args.input), "calibration-plan")
    require(len(plan["profiles"]) <= 32, "CI calibration profile cap exceeded")
    output = Path(args.output)
    output.mkdir(mode=0o700, parents=False, exist_ok=False)
    (output / "started.json").write_text(dump({"revision": revision, "complete": False}))
    results = []
    total_bytes = 0
    deadline = time.monotonic() + 300
    for index, profile in enumerate(plan["profiles"]):
        if "unavailable" in profile:
            results.append({"unavailable": profile["unavailable"]})
            continue
        require(profile["code_ref"] == revision, "calibration plan revision is stale")
        names = [p["name"] for p in profile["environment"]]
        require(len(set(names)) == len(names), "duplicate calibration environment name")
        samples = []
        for repeat in range(args.repeats):
            measurements = {}
            for mode in ("trace", "plain"):
                prefix = output / (str(index) + "-" + str(repeat) + "-" + mode)
                fixture = Path(str(prefix) + "-fixture")
                environment = ci_fixture(profile, fixture)
                cpu_path = str(prefix) + ".cpu"
                argv = ["/usr/bin/time", "-f", "%U %S", "-o", cpu_path, *profile["argv"]]
                suffixes = (".cpu", ".stdout", ".stderr")
                if mode == "trace":
                    raw_path = str(prefix) + ".trace"
                    argv = ["strace", "-f", "-qq", "-ttt", "-s", "65536", "-e", "trace=process",
                            "-o", raw_path, *argv]
                    suffixes += (".trace",)
                ci_run(argv, prefix, environment, deadline)
                cpu = read_bytes(cpu_path, 4096).decode("ascii").strip()
                ci_cpu_values(cpu)
                records, record_bytes = ci_tick_records(fixture)
                ticks, boot_id = ci_tick_count(records, profile)
                measurements[mode] = {"cpu": cpu, "records": records, "ticks": ticks, "boot_id": boot_id}
                if mode == "trace":
                    measurements[mode]["raw"] = read_bytes(raw_path, 1048576)
                total_bytes += record_bytes + sum(Path(str(prefix) + suffix).stat().st_size for suffix in suffixes)
                total_bytes += sum(len(base64.b64decode(r["base64"], validate=True)) for r in profile["fixture_files"])
                require(total_bytes <= 16 * 1024 * 1024, "calibration aggregate trace cap exceeded")
            traced, plain = measurements["trace"], measurements["plain"]
            require(traced["ticks"] == plain["ticks"] and traced["boot_id"] == plain["boot_id"],
                    "traced/untraced unit counts or boots differ")
            user, system = ci_cpu_values(plain["cpu"])
            samples.append({"ticks": traced["ticks"], "boot_id": traced["boot_id"], "tick_records": traced["records"],
                "cpu_tick_records": plain["records"], "births": calibration_births(traced["raw"], profile["family"]),
                "user_ns": user, "system_ns": system, "cpu_reading": plain["cpu"],
                "traced_cpu_reading": traced["cpu"], "trace_base64": base64.b64encode(traced["raw"]).decode(),
                "trace_sha256": digest(traced["raw"])})
        require(len({s["births"] for s in samples}) == 1, "nondeterministic calibration births")
        results.append({"samples": samples, "uncertainty": calibration_uncertainty(samples)})
    require(subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip() == revision
            and not subprocess.check_output(["git", "status", "--porcelain", "--untracked-files=no"]),
            "CI calibration changed its checkout")
    payload = {"format": "fm-supervision-calibration.v1", "revision": revision,
        "runner": "/".join(os.environ.get(key, "unknown") for key in
                           ("RUNNER_NAME", "RUNNER_OS", "RUNNER_ARCH", "ImageOS", "ImageVersion")),
        "ci_url": "https://github.com/" + os.environ["GITHUB_REPOSITORY"] + "/actions/runs/" + os.environ["GITHUB_RUN_ID"],
        "method": "launch-strace-births+untraced-GNU-time-subtree.v1", "plan": plan, "results": results,
        "uncertainty": "CPU comes from a fresh untraced matched repeat, rounded to 10ms per component. Repeat spread and traced-minus-untraced differences are diagnostics, not confidence intervals or an exact tracer-overhead correction. CI/runtime differences and work mix remain. Command startup remains in the tick average; real resident startup frequency and partial boundary work are not recovered."}
    artifact = content_seal(payload)
    calibration_payload(artifact)
    (output / "calibration.json").write_text(dump(artifact))
    return {"artifact": str(output / "calibration.json"), "sha256": artifact["sha256"], "revision": revision}


def count_instrumented_ticks(data, profile, first, last, hz):
    groups, stream, count, current_boot_seen, oldest_entry = {}, [], 0, False, None
    lower = Fraction(first["uptime_upper_ticks"] * 1000000000, hz)
    upper = Fraction(last["uptime_lower_ticks"] * 1000000000, hz)
    for line in data.split(b"\n")[:-1]:
        if not line:
            continue
        fields = line.decode("ascii").split("\t")
        require(len(fields) == 9 and fields[0] == "fm-supervision-tick.v3"
                and all(len(field) <= 128 for field in fields), "invalid instrumentation row")
        family, unit, record_boot, generation, seq, wall, boot, phase = fields[1:]
        require(re.fullmatch(r"[a-z0-9][a-z0-9-]{0,63}", family) and re.fullmatch(r"[a-z0-9][a-z0-9-]{0,63}", unit)
                and re.fullmatch(BOOT_ID_PATTERN, record_boot)
                and re.fullmatch(r"[0-9]{1,18}:[0-9]{1,12}\.[0-9]{6}", generation)
                and seq.isdecimal() and len(seq) <= 18
                and re.fullmatch(r"[0-9]{1,12}\.[0-9]{6}", wall)
                and re.fullmatch(r"[0-9]{1,12}\.[0-9]{2}", boot)
                and phase in ("start", "rotate", "tick", "entry"), "invalid instrumentation fields")
        if record_boot != first["boot_id"]:
            continue
        current_boot_seen = True
        at = int(Decimal(boot) * 1000000000)
        if phase == "entry":
            oldest_entry = at if oldest_entry is None else min(oldest_entry, at)
        if (family, unit) != (profile["family"], profile["tick_unit"]):
            continue
        if profile.get("record_kind") == "owned-loop" and phase == "entry":
            return None, "concurrent entry supplied as owned-loop tick"
        if profile.get("record_kind") == "concurrent" and phase != "entry":
            return None, "owned-loop record supplied as concurrent entry"
        sequence = int(seq)
        require(sequence > 0, "invalid tick sequence")
        groups.setdefault(generation, []).append((sequence, at, phase))
        if phase != "entry":
            stream.append((sequence, at, phase))
        count += phase != "start" and lower <= at < upper
    if not current_boot_seen:
        return None, "no journal record from the capture boot"
    if profile.get("record_kind") == "owned-loop" and not groups:
        return None, "no owned-loop startup or retained tick record"
    if profile.get("record_kind") == "concurrent" and (oldest_entry is None or oldest_entry > lower):
        return None, "concurrent journal has no retained pre-window coverage evidence"
    # A stream sequence survives generations in the owned cursor. A whole lost
    # generation becomes a gap; a post-window-start prefix cannot prove coverage.
    if profile.get("record_kind") == "owned-loop":
        stream.sort()
        if stream[0][1] > lower:
            return None, "earlier generation or prefix lost inside requested window"
    if stream:
        stream.sort()
        if any(b[0] != a[0] + 1 or b[1] < a[1] for a, b in zip(stream, stream[1:])):
            return None, "duplicate, missing or reversed instrumented stream sequence"
    for rows in groups.values():
        rows.sort()
        if any(b[0] != a[0] + 1 or b[1] < a[1] for a, b in zip(rows, rows[1:])):
            return None, "duplicate, missing or reversed instrumented tick sequence"
    return count, None


def count_saved_ticks(records, capture):
    records = attribution_input(records, "tick-records")
    measured = account_proc(capture)
    require(capture["synthetic"] or not records["synthetic"], "synthetic tick records with real capture")
    first, last = capture["snapshots"][0]["boundary"], capture["snapshots"][-1]["boundary"]
    start, end = first["wall_ns"], last["wall_ns"]
    require(end > start, "wall window reversed; timestamped tick attribution unavailable")
    homes = {h["id"]: h for h in capture["manifest"]["homes"]}
    rows, paths = [], {}
    for profile in records["profiles"]:
        require(profile["home"] in homes, "tick record home not enrolled")
        row = {k: profile[k] for k in ("home", "family", "code_ref", "configuration_sha256",
                                      "work_mix_sha256", "tick_unit", "qualification") if k in profile}
        reason = profile.get("unavailable")
        owner = homes[profile["home"]]
        if profile["code_ref"] != owner["code_ref"] or profile["configuration_sha256"] != owner["configuration_sha256"]:
            reason = "stale tick code/configuration pins"
        if not reason:
            fragments = profile.get("fragments", [{k: profile.get(k) for k in ("record_path", "base64", "sha256")}])
            pieces = []
            for fragment in fragments:
                path = fragment["record_path"]
                require(os.path.normpath(path) == path and path.startswith(owner["home"] + "/"), "tick path outside admitted home")
                if path in paths:
                    require(profile["timestamp"] in JOURNAL_TIMESTAMPS and paths[path] == (fragment["sha256"], profile["timestamp"]),
                            "shared saved tick record or inconsistent fragment")
                paths[path] = (fragment["sha256"], profile["timestamp"])
                piece = base64.b64decode(fragment["base64"], validate=True)
                require(len(piece) <= 6 * 1024 * 1024 and digest(piece) == fragment["sha256"], "saved tick seal mismatch")
                pieces.append(piece)
            require(len({f["record_path"] for f in fragments}) == len(fragments), "duplicate tick fragment")
            data = b"".join(piece if piece.endswith(b"\n") else piece.rsplit(b"\n", 1)[0] + b"\n"
                            if b"\n" in piece else b"" for piece in pieces)
            if profile["timestamp"] in JOURNAL_TIMESTAMPS and profile.get("instrumentation_error", True):
                reason = "instrumentation cohort invalid or error-state attestation missing"
            if profile["timestamp"] in JOURNAL_TIMESTAMPS and "record_kind" not in profile:
                reason = "journal ownership kind missing"
            if profile["timestamp"] in ("supervision-tick-v1", "supervision-tick-v2"):
                reason = "legacy journal lacks boot identity or cross-generation continuity; unavailable"
            if not profile["coverage_start_wall_ns"] <= start < end <= profile["coverage_end_wall_ns"]:
                reason = "stale or partial tick record window"
            elif not reason:
                count = 0
                if profile["timestamp"] == "supervision-tick-v3":
                    count, reason = count_instrumented_ticks(data, profile, first, last, measured["clock_ticks"])
                for line in ([] if profile["timestamp"] in JOURNAL_TIMESTAMPS else data.split(b"\n")[:-1]):
                    if profile["line_contains"].encode() not in line:
                        continue
                    if profile["timestamp"] == "epoch-tab-seconds":
                        stamp = line.split(b"\t", 1)[0]
                        require(re.fullmatch(rb"[0-9]+(?:\.[0-9]{1,9})?", stamp), "invalid tick epoch")
                        at = int(Decimal(stamp.decode()) * 1000000000)
                    elif profile["timestamp"] == "status-at-seconds":
                        match = re.search(rb"\[at=([0-9]+)\]", line)
                        require(match is not None, "matching status tick has no timestamp")
                        at = int(match[1]) * 1000000000
                    else:
                        value = json.loads(line, object_pairs_hook=unique_object)
                        at = value.get(profile.get("timestamp_field", "wall_ns"))
                        require(type(at) is int and at >= 0, "invalid JSON tick timestamp")
                        if profile["timestamp"] == "json-epoch-seconds":
                            at *= 1000000000
                    count += start <= at < end
                if not reason:
                    row.update(ticks=count, ticks_per_second=count * 1e9 / measured["duration_ns"],
                               record_fragments=[{k: f[k] for k in ("record_path", "sha256")} for f in fragments])
        if reason:
            row["unavailable"] = reason
        rows.append(row)
    return checked({"format": "fm-supervision-tick-counts.v1", "capture_sha256": digest(dump(capture).encode()),
        "window_wall_ns": [start, end], "boot_id": first["boot_id"], "duration_ns": measured["duration_ns"], "by_home_family": rows,
        "journal_count_interval_ns": max(0, (last["uptime_lower_ticks"] - first["uptime_upper_ticks"]) * 1000000000 // measured["clock_ticks"]),
        "journal_denominator_excess_ns": measured["duration_ns"] - max(0, (last["uptime_lower_ticks"] - first["uptime_upper_ticks"]) * 1000000000 // measured["clock_ticks"]),
        "clock_qualification": "Ordinary rows use [wall-start,wall-end); v3 journal rows match capture boot and conservative uptime brackets (uncertain edge jiffies excluded). Rates use measured monotonic duration. The excluded bracket duration is published; this biases rates downward relative to full-window counts, with no finite bound on missed edge events or their model cost. Owner attests retained coverage, clock-namespace equivalence and one row per calibrated unit; boot UUID alone does not prove shared time namespace. Clock steps and quantization remain uncertainty.",
        "concurrent_log_loss_limit": "A producer frozen between O_APPEND open and write across two watcher rename rotations can silently lose its line. No writer-lifetime bound or zero-loss proof is claimed; this limit accompanies every result using the concurrent journal.",
        "wall_minus_monotonic_ns": end - start - measured["duration_ns"]}, "tick-counts")


def reconcile_saved(capture, records, calibrations):
    measured = account_proc(capture)
    ticks = count_saved_ticks(records, capture)
    homes = {h["id"]: h for h in capture["manifest"]["homes"]}
    costs = {}
    for artifact in calibrations:
        calibration = calibration_payload(artifact)
        require(capture["synthetic"] or not calibration["plan"]["synthetic"], "synthetic calibration with real capture")
        for profile, result in zip(calibration["plan"]["profiles"], calibration["results"]):
            key = (profile["home"], profile["family"])
            require(key not in costs, "duplicate calibration home/family")
            costs[key] = (profile, result, calibration, artifact["sha256"])
    rates = {(p["home"], p["family"]): p for p in ticks["by_home_family"]}
    expected = {(home, family) for home in homes for family in SOURCE_FAMILIES} | set(rates) | set(costs)
    require(all(home in homes for home, _ in expected), "calibration home not enrolled")
    rows, totals, covered = [], [Fraction(0), Fraction(0), Fraction(0)], 0
    for home, family in sorted(expected):
        row = {"home": home, "family": family}
        rate, cost = rates.get((home, family)), costs.get((home, family))
        reasons = []
        if not rate:
            reasons.append("missing countable live tick record")
        elif "unavailable" in rate:
            reasons.append(rate["unavailable"])
        if not cost:
            reasons.append("missing CI calibration")
        else:
            profile, result, calibration, seal = cost
            if "unavailable" in result:
                reasons.append(result["unavailable"])
            if profile["code_ref"] != homes[home]["code_ref"] or profile["configuration_sha256"] != homes[home]["configuration_sha256"]:
                reasons.append("stale calibration code/configuration pins")
            if rate and "unavailable" not in rate and "unavailable" not in result and any(
                    profile[k] != rate[k] for k in ("tick_unit", "work_mix_sha256")):
                reasons.append("calibration/tick unit or work-mix mismatch")
        if reasons:
            row.update(status="unavailable", reasons=reasons)
        else:
            samples = result["samples"]
            calibration_ticks = sum(s["ticks"] for s in samples)
            values = [Fraction(sum(s[k] for s in samples) * rate["ticks"], calibration_ticks)
                      for k in ("births", "user_ns", "system_ns")]
            totals = [a + b for a, b in zip(totals, values)]
            covered += 1
            row.update(status="modelled-not-measured", ticks=rate["ticks"], estimated_births=float(values[0]),
                estimated_user_ns=float(values[1]), estimated_system_ns=float(values[2]),
                calibration_sha256=seal, ci_url=calibration["ci_url"], method=calibration["method"],
                cpu_basis="untraced matched CI repeat",
                trace_minus_untraced_cpu_ns_per_repeat_range=result["uncertainty"]["trace_minus_untraced_cpu_ns_per_repeat_range"],
                per_tick={k: {"mean": float(Fraction(sum(s[k] for s in samples), calibration_ticks)),
                              "min": float(min(Fraction(s[k], s["ticks"]) for s in samples)),
                              "max": float(max(Fraction(s[k], s["ticks"]) for s in samples))}
                          for k in ("births", "user_ns", "system_ns")},
                uncertainty=calibration["uncertainty"], cpu_quantization_ns_per_component=10000000,
                qualification=profile["qualification"])
        rows.append(row)
    duration = measured["duration_ns"]
    birth_residual = measured["machine"]["births"] - totals[0]
    cpu_residual = Fraction(measured["machine"]["busy_cpu_ticks"] * 1000000000, measured["clock_ticks"]) - sum(totals[1:])
    contradiction = birth_residual < 0 or cpu_residual < 0
    return checked({"format": "fm-supervision-reconciliation.v1", "basis": "CI per-tick cost times timestamped live unit records; NOT measured supervision",
        "status": "model-total-contradiction" if contradiction else "incomplete-model-inputs" if covered < len(expected) else "pending-reviewed-model-baseline",
        "machine": measured["machine"], "duration_ns": duration, "ticks": ticks,
        "exclusive_measured_supervision": None, "by_home_family": rows,
        "model_log_loss_limit": ticks["concurrent_log_loss_limit"],
        "coverage": {"modelled_pairs": covered, "expected_pairs": len(expected),
                     "other_families": "not discovered; require owner inventory and explicit additional profiles"},
        "modelled_subtotal": {"births": float(totals[0]), "births_per_second": float(totals[0] * 1000000000 / duration),
                              "user_ns": float(totals[1]), "system_ns": float(totals[2]),
                              "cpu_one_core_percent": float(sum(totals[1:]) * 100 / duration)} if covered else None,
        "unattributed_machine_minus_modelled_subtotal": {"births": float(birth_residual),
            "births_per_second": float(birth_residual * 1000000000 / duration), "busy_cpu_ns": float(cpu_residual),
            "busy_cpu_one_core_percent": float(cpu_residual * 100 / duration)},
        "residual_qualification": "Subtracts covered subtotal only (empty subtotal when coverage is zero), NOT all supervision. Positive residual includes workload, unmodelled supervision, collector and model error; negative values are contradictions, never clipped.",
        "startup_coverage": measured["startup_coverage"],
        "startup_qualification": "CI command startup remains in the per-tick average; real resident startup frequency and in-flight window-boundary work are not recovered. No B0 certification or performance acceptance.",
        "claimed_births_per_second_saved": 0}, "reconciliation")


def prepare_calibration_plan(value, revision, checkout):
    require(re.fullmatch(r"[0-9a-f]{40}", revision) is not None and Path(checkout).is_absolute(),
            "invalid calibration revision or checkout")
    # Resolution never changes synthetic provenance, config pins or fixture seals.
    for profile in value["profiles"]:
        if profile["code_ref"] == "@REVISION@":
            profile["code_ref"] = revision
        if "argv" in profile:
            profile["argv"] = [v.replace("@CHECKOUT@", checkout) for v in profile["argv"]]
    plan = attribution_input(value, "calibration-plan")
    homes = {p["home"] for p in plan["profiles"]}
    require(bool(homes), "empty reviewed calibration plan")
    require(not ({(h, f) for h in homes for f in SOURCE_FAMILIES}
                 - {(p["home"], p["family"]) for p in plan["profiles"]}),
            "reviewed plan omits source registry families; publish explicit unavailable rows")
    require(all(p["code_ref"] == revision for p in plan["profiles"]), "reviewed plan revision is stale")
    return plan


def main():
    if sys.version_info < (3, 9):
        print("supervision-accounting: refused: Python >=3.9 required", file=sys.stderr)
        return 2
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest="verb", required=True)
    commands.add_parser("source-families", help="print the complete retrospective source registry")
    commands.add_parser("probe", help="read-only availability/privilege report; never attaches")
    for name in ("validate-manifest", "validate-workload", "account", "replay", "read-record", "import-strace"):
        sub = commands.add_parser(name)
        sub.add_argument("input")
        if name == "validate-workload":
            sub.add_argument("--bindings", help="sealed v3 capture bindings; validation only")
        if name == "account":
            sub.add_argument("--manifest", required=True)
        if name == "read-record":
            sub.add_argument("--kind", choices=("queue", "status", "claim"), required=True)
            sub.add_argument("--name", required=True)
    sub = commands.add_parser("prepare-calibration-plan", help="resolve reviewed plan tokens offline; executes nothing")
    sub.add_argument("input")
    sub.add_argument("--revision", required=True)
    sub.add_argument("--checkout", required=True)
    sub = commands.add_parser("calibrate-ci", help="GitHub CI ONLY: trusted finite fixture calibration")
    sub.add_argument("input")
    sub.add_argument("--output", required=True)
    sub.add_argument("--repeats", type=int, default=3)
    for name in ("count-ticks", "reconcile"):
        sub = commands.add_parser(name, help="offline saved-record attribution; no home reads")
        sub.add_argument("input", help="saved proc.json" if name == "reconcile" else "saved tick records")
        if name == "count-ticks":
            sub.add_argument("--capture", required=True)
        else:
            sub.add_argument("--ticks", required=True)
            sub.add_argument("--calibration", action="append", default=[])
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
        if args.verb == "source-families":
            result = {"families": list(SOURCE_FAMILIES)}
        elif args.verb == "probe":
            result = probe()
        elif args.verb == "capture":
            result = capture(args)
        elif args.verb == "capture-proc":
            result = capture_proc(args)
        elif args.verb == "prepare-calibration-plan":
            result = prepare_calibration_plan(load_json(args.input), args.revision, args.checkout)
        elif args.verb == "calibrate-ci":
            result = calibrate_ci(args)
        elif args.verb == "count-ticks":
            result = count_saved_ticks(load_json(args.input), load_json(args.capture))
        elif args.verb == "reconcile":
            result = reconcile_saved(load_json(args.input), load_json(args.ticks),
                                     [load_json(path) for path in args.calibration])
        elif args.verb == "account-proc":
            result = account_proc(load_json(args.input))
        elif args.verb == "check-proc-fixture":
            result = check_proc_fixture(load_json(args.input))
        elif args.verb == "validate-manifest":
            value = manifest(load_json(args.input))
            result = {"valid": True, "certified_complete": value["certified_complete"],
                      "homes": len(value["homes"])}
        elif args.verb == "validate-workload":
            value = load_json(args.input)
            model = bound_workload(value, load_json(args.bindings)) if args.bindings else workload(value)
            result = model.summary()
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
    except (ProcDeadline, Refused, OSError, ValueError, KeyError, IndexError, TypeError, RecursionError,
            subprocess.SubprocessError) as error:
        print("supervision-accounting: refused: " + str(error), file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
