#!/usr/bin/env python3
"""Bounded, opt-in P0 accounting; never launches a workload or activates a mode.

Usage: fm-supervision-accounting.py --help
Python >=3.9, standard library only. `probe` is read-only, with no attach.
`capture` needs Linux, strace, pidfds and permission to ptrace every explicitly
published root. It refuses unless FM_SUPERVISION_CAPTURE_LIVE=1 AND
--acknowledge-ptrace are supplied; never use it as a routine check.
Capture output is private and may contain command arguments.
Exit: 0 report produced, 2 refused/invalid input or failed capture. A report
may retain losses/contradictions without certifying completeness. Diagnostics
use stderr; the invoking task owner routes failures through its status path.
Schemas and semantics: docs/supervision-accounting.md. No daemon or poller.
"""
import argparse
import base64
import binascii
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

MAX_BYTES = 64 * 1024 * 1024
SCHEMAS = Path(__file__).resolve().parent.parent / "docs" / "supervision-accounting"
FAMILIES = ("crew-state", "watch", "wake-drain", "fleet-snapshot", "spawn", "control")
SCRIPT_FAMILIES = {"fm-" + name + ".sh": name for name in FAMILIES}
SHELL_EXECUTABLES = ("/bin/bash", "/usr/bin/bash", "/bin/sh", "/usr/bin/sh")


class Refused(ValueError):
    pass


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
    except (Refused, OSError, ValueError, KeyError, IndexError, TypeError, RecursionError) as error:
        print("supervision-accounting: refused: " + str(error), file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
