"""P1 recorder controller and offline finalizer (Linux, Python 3.9+, stdlib).

This module records nothing by itself. Only separately reviewed default-off
shell hooks may write its ticket spool. It writes no home file, enables no live
home and installs nothing. The CLI is bin/fm-supervision-recorder.py.
Formats, fixed timing, limits and refusal semantics:
docs/supervision-accounting.md, "Recorder controller".
"""
import base64
import ctypes
import errno
import hashlib
import json
import math
import os
from pathlib import Path
import re
import resource
import select
import signal
import stat
import struct
import subprocess
import time

from fm_supervision_bindings import CALLER_SITES, CALLERS, EXCLUDED_SITES, audit_callers
from fm_supervision_replay import MAX_FILE, blob, canonical, object_seal, path_parts, seal

MIB = 1024 * 1024
SECOND = 1_000_000_000
# G4 decision A: requests starting inside the 60 s window, each followed to its
# 30 s limit; the guard's absolute stop is 116 s after preparation starts.
PREPARE_NS = 10 * SECOND
WINDOW_NS = 60 * SECOND
REQUEST_LIMIT_NS = 30 * SECOND
ACQUISITION_NS = WINDOW_NS + REQUEST_LIMIT_NS
FLUSH_NS = 2 * SECOND
FINALIZE_NS = 10 * SECOND
TERM_GRACE_NS = 2 * SECOND
KILL_OBSERVE_NS = 2 * SECOND
# The guard escalates at the normal 112 s bound; its TERM grace and KILL
# observation end by the absolute 116 s deadline.
NORMAL_NS = PREPARE_NS + ACQUISITION_NS + FLUSH_NS + FINALIZE_NS
GUARD_NS = NORMAL_NS + TERM_GRACE_NS + KILL_OBSERVE_NS
CLOCK_DRIFT_NS = 1_000_000
# G3/G6 spool, slot and hook-memory bounds.
TICKETS = 4096
TICKET_BYTES = 32 * 1024
CHAIN_MAX = 128
DEMAND_MAX = 1024
PROBES = 8
SEED = 17
EMITTERS_MAX = 256
SPOOL_BYTES = TICKETS * TICKET_BYTES
QUOTA_MAX = 256 * MIB
DECODED_MAX = 24 * MIB
JSON_MAX = 64 * MIB
# role: (RLIMIT_CPU seconds, RLIMIT_AS bytes, RLIMIT_FSIZE bytes)
LIMITS = {"coordinator": (9, 128 * MIB, 64 * MIB), "io": (3, 64 * MIB, 64 * MIB),
          "guard": (1, 32 * MIB, 1 * MIB), "finalizer": (8, 768 * MIB, 64 * MIB)}
NOFILE = 128
FINALIZER_COST_MIB = 768

ENABLE_FORMAT = "fm-supervision-recorder-enable.v1"
TICKET_FORMAT = "fm-supervision-recorder-ticket.v1"
CLOSURE_FORMAT = "fm-supervision-recorder-read-closure.v1"
AUDIT_FORMAT = "fm-supervision-recorder-pin-audit.v1"
ACQUISITION_FORMAT = "fm-supervision-recorder-acquisition.v1"
PROVENANCE_FORMAT = "fm-supervision-recorder-provenance.v1"
TOKEN = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{0,63}")
SHA1 = re.compile(r"[0-9a-f]{40}")
ROOTS = ("state", "config", "data", "worktree")
# Registry read modes are the binder's logical operations. S admits both
# stat and exists results; L is the exact complete immediate listing.
MODES = {"R": ("read",), "L": ("list",), "S": ("stat", "exists")}
CLOSURE = Path(__file__).resolve().parent.parent / "docs" / "supervision-accounting" / "recorder-read-closure-v1.json"


class Refused(ValueError):
    pass


def need(condition, message):
    if not condition:
        raise Refused("recorder: " + message)


def b64(raw):
    return {"base64": base64.b64encode(raw).decode("ascii"), "sha256": hashlib.sha256(raw).hexdigest()}


def boottime_ns():
    return time.clock_gettime_ns(time.CLOCK_BOOTTIME)


def limit(role):
    """Apply one private role's kernel ceilings; never RLIMIT_NPROC."""
    cpu, address, size = LIMITS[role]
    for kind, value in ((resource.RLIMIT_CPU, cpu), (resource.RLIMIT_AS, address),
                        (resource.RLIMIT_FSIZE, size), (resource.RLIMIT_NOFILE, NOFILE)):
        soft, hard = resource.getrlimit(kind)
        value = value if hard == resource.RLIM_INFINITY else min(value, hard)
        resource.setrlimit(kind, (value, value))


# --- deterministic ticket slots ------------------------------------------

def fold(token):
    need(type(token) is str and TOKEN.fullmatch(token) is not None, "invalid slot token")
    value = SEED
    for byte in token.encode("ascii"):
        value = (33 * value + byte) % TICKETS
    return value


def probe_slots(token, pid, start_ticks, sequence):
    """The only admitted claim order: eight distinct slots, no random retry."""
    need(all(type(v) is int and v >= 0 for v in (pid, start_ticks, sequence)), "invalid slot identity")
    first = (fold(token) + pid + start_ticks + sequence) % TICKETS
    return [(first + step) % TICKETS for step in range(PROBES)]


# --- external enable record ----------------------------------------------

ENABLE_FIELDS = ("format", "epoch", "nonce", "boot_id", "t0_cs", "cutoff_cs", "end_cs", "expiry_cs",
                 "wall_t0_us", "spool", "tickets", "ticket_bytes", "chain_max")


def enable_line(record):
    values = [str(record[key]) for key in ENABLE_FIELDS]
    need(all("\t" not in v and "\n" not in v for v in values), "enable field separator")
    raw = ("\t".join(values) + "\n").encode("ascii")
    parse_enable(raw)
    return raw


def parse_enable(raw):
    """Strict reader shared with hooks' builtin parser contract."""
    need(type(raw) is bytes and len(raw) <= 4096 and raw.endswith(b"\n") and raw.count(b"\n") == 1,
         "malformed enable record")
    try:
        fields = raw[:-1].decode("ascii").split("\t")
    except UnicodeDecodeError:
        raise Refused("recorder: malformed enable record") from None
    need(len(fields) == len(ENABLE_FIELDS), "enable field count")
    record = dict(zip(ENABLE_FIELDS, fields))
    need(record["format"] == ENABLE_FORMAT, "unsupported enable format")
    need(TOKEN.fullmatch(record["epoch"]) is not None and re.fullmatch(r"[0-9a-f]{32}", record["nonce"])
         and re.fullmatch(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}", record["boot_id"]),
         "invalid enable identity")
    for key in ENABLE_FIELDS[4:9] + ENABLE_FIELDS[10:]:
        need(re.fullmatch(r"0|[1-9][0-9]{0,18}", record[key]) is not None, "invalid enable number")
        record[key] = int(record[key])
    need(record["cutoff_cs"] == record["t0_cs"] + WINDOW_NS // 10_000_000
         and record["end_cs"] == record["t0_cs"] + ACQUISITION_NS // 10_000_000
         and record["expiry_cs"] == record["end_cs"] + FLUSH_NS // 10_000_000, "enable window mismatch")
    need((record["tickets"], record["ticket_bytes"], record["chain_max"]) == (TICKETS, TICKET_BYTES, CHAIN_MAX),
         "enable ticket table mismatch")
    need(record["spool"].startswith("/") and os.path.normpath(record["spool"]) == record["spool"],
         "noncanonical spool path")
    return record


def write_enable(path, record):
    """Exclusive private create; retained as immutable evidence, never removed."""
    raw = enable_line(record)
    parent = os.stat(os.path.dirname(path))
    need(stat.S_ISDIR(parent.st_mode) and parent.st_uid == os.getuid() and not parent.st_mode & 0o022,
         "enable directory must be private")
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600)
    try:
        need(os.write(fd, raw) == len(raw), "short enable write")
        os.fsync(fd)
        os.fchmod(fd, 0o400)
    finally:
        os.close(fd)


# --- ticket spool reader ---------------------------------------------------

def _fallocate_keep_size(fd, size):
    libc = ctypes.CDLL(None, use_errno=True)
    call = libc.fallocate
    call.argtypes = (ctypes.c_int, ctypes.c_int, ctypes.c_longlong, ctypes.c_longlong)
    if call(fd, 1, 0, size) != 0:  # FALLOC_FL_KEEP_SIZE reserves the extent only.
        code = ctypes.get_errno()
        raise OSError(code, "ticket extent reservation: " + os.strerror(code))


def prepare_bank(spool):
    """Create the finite private bank; tickets are never recycled."""
    os.mkdir(spool, 0o700)
    for slot in range(TICKETS):
        fd = os.open(os.path.join(spool, "t%04d" % slot),
                     os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600)
        try:
            _fallocate_keep_size(fd, TICKET_BYTES)
        finally:
            os.close(fd)


def unescape(text):
    out, index = [], 0
    while index < len(text):
        char = text[index]
        if char == "\\":
            need(index + 1 < len(text) and text[index + 1] in "\\tn", "invalid field escape")
            out.append({"\\": "\\", "t": "\t", "n": "\n"}[text[index + 1]])
            index += 2
        else:
            out.append(char)
            index += 1
    return "".join(out)


def _number(text, upper):
    need(re.fullmatch(r"0|[1-9][0-9]{0,18}", text) is not None and int(text) <= upper, "invalid ticket number")
    return int(text)


def _line(raw, index):
    end = raw.find(b"\n", index)
    need(end >= 0, "unterminated ticket line")
    try:
        text = raw[index:end].decode("ascii")
    except UnicodeDecodeError:
        raise Refused("recorder: non-ASCII ticket line") from None
    return text.split("\t"), end + 1


def parse_ticket(raw, slot, enable):
    """One ticket: header, whole records, then continuation or footer."""
    need(len(raw) <= TICKET_BYTES, "ticket extent overflow")
    fields, index = _line(raw, 0)
    need(len(fields) == 10 and fields[0] == "H" and fields[1] == TICKET_FORMAT
         and fields[2] == enable["epoch"] and fields[3] == enable["nonce"], "ticket header/generation mismatch")
    header = dict(slot=_number(fields[4], TICKETS - 1), head=_number(fields[5], TICKETS - 1),
                  index=_number(fields[6], CHAIN_MAX - 1), pid=_number(fields[7], 4194304),
                  start_ticks=_number(fields[8], 2**63 - 1), sequence=_number(fields[9], 2**31))
    need(header["slot"] == slot and (header["index"] == 0) == (header["head"] == slot), "ticket slot/chain identity")
    records, tail = [], None
    while index < len(raw):
        fields, after = _line(raw, index)
        if fields[0] == "R":
            need(len(fields) == 4 and re.fullmatch(r"[a-z]{1,16}", fields[2]) is not None, "invalid record line")
            sizes = [_number(v, TICKET_BYTES) for v in fields[3].split(",")]
            need(1 <= len(sizes) <= 64, "record segment count")
            stop = after + sum(sizes)
            need(stop + 1 <= len(raw) and raw[stop:stop + 1] == b"\n", "torn record")
            segments, cursor = [], after
            for size in sizes:
                segments.append(raw[cursor:cursor + size])
                cursor += size
            try:
                text = segments[0].decode("utf-8")
            except UnicodeDecodeError:
                raise Refused("recorder: record fields are not UTF-8") from None
            need("\0" not in text and "\n" not in text, "invalid record fields")
            records.append(dict(seq=_number(fields[1], 2**31), kind=fields[2], size=sum(sizes),
                                fields=[unescape(v) for v in text.split("\t")], segments=segments[1:]))
            index = stop + 1
        else:
            need(fields[0] in ("N", "F") and after == len(raw), "unexpected ticket tail")
            if fields[0] == "N":
                need(len(fields) == 2, "invalid continuation")
                tail = ("next", _number(fields[1], TICKETS - 1))
            else:
                need(len(fields) == 4 and fields[3] in ("ok", "invalid"), "invalid footer")
                tail = ("footer", _number(fields[1], 2**31), _number(fields[2], 2**40), fields[3])
            index = after
    need(tail is not None, "missing ticket end marker")
    return header, records, tail


def collect_spool(spool, enable):
    """Reconcile every claim marker, ticket and chain exactly once."""
    names = os.listdir(spool)
    need(len(names) <= 2 * TICKETS + 64, "spool entry bound")
    claims, overflow = set(), []
    for name in names:
        if re.fullmatch(r"t[0-9]{4}", name):
            need(int(name[1:]) < TICKETS, "unknown ticket slot")
        elif re.fullmatch(r"c[0-9]{4}", name):
            need(int(name[1:]) < TICKETS, "unknown claim slot")
            claims.add(int(name[1:]))
        elif re.fullmatch(r"x[0-9]{1,7}-[0-9]{1,19}-[0-9]{1,10}", name):
            overflow.append(name)
        else:
            raise Refused("recorder: foreign spool entry")
    # A producer that found eight occupied slots leaves an exhaustion marker
    # instead of a ticket; the capture is invalid, the original call is not.
    need(not overflow, "ticket claim exhausted (eight-slot collision or bank full)")
    tickets, total = {}, 0
    for slot in range(TICKETS):
        path = os.path.join(spool, "t%04d" % slot)
        st = os.lstat(path)
        need(stat.S_ISREG(st.st_mode) and st.st_nlink == 1 and not st.st_mode & 0o077, "ticket is not private regular")
        with open(path, "rb") as stream:
            raw = stream.read(TICKET_BYTES + 1)
        need((slot in claims) == bool(raw), "claim marker/ticket mismatch")
        total += len(raw)
        if raw:
            tickets[slot] = parse_ticket(raw, slot, enable)
    need(total <= SPOOL_BYTES, "spool byte bound")
    producers, used = [], set()
    for slot, (header, _, _) in sorted(tickets.items()):
        if header["index"] != 0:
            continue
        chain, records, current = [slot], [], slot
        while True:
            head, rows, tail = tickets[current]
            need(head["head"] == slot and head["index"] == len(chain) - 1
                 and (head["pid"], head["start_ticks"], head["sequence"]) == (header["pid"], header["start_ticks"], header["sequence"]),
                 "ticket chain identity")
            records.extend(rows)
            if tail[0] == "footer":
                break
            need(len(chain) < CHAIN_MAX and tail[1] in tickets and tail[1] not in chain, "broken ticket chain")
            current = tail[1]
            chain.append(current)
        _, count, payload, status = tail
        need(status == "ok", "producer reported invalid recording")
        need([r["seq"] for r in records] == list(range(1, len(records) + 1)), "record sequence gap")
        need(count == len(records) and payload == sum(r["size"] for r in records), "footer count mismatch")
        used.update(chain)
        producers.append(dict(identity=(header["pid"], header["start_ticks"], header["sequence"]),
                              tickets=chain, records=records))
    need(used == set(tickets), "orphan ticket outside any chain")
    need(len({p["identity"] for p in producers}) == len(producers), "duplicate producer generation")
    return producers


# --- reviewed read closure and code_ref pin audit ------------------------

def load_closure(path=CLOSURE):
    with open(path, "rb") as stream:
        value = json.loads(stream.read(4 * MIB + 1))
    need(type(value) is dict and value.get("format") == CLOSURE_FORMAT, "unsupported read-closure format")
    need(set(value) == {"format", "code_ref", "rows", "instrumentation", "excluded"}, "read-closure fields")
    need(SHA1.fullmatch(value["code_ref"]) is not None, "read-closure pin")
    ids = set()
    for row in value["rows"]:
        need(set(row) == {"id", "families", "root", "template", "modes", "sites"}
             and row["id"] not in ids and row["root"] in ROOTS
             and type(row["modes"]) is str and row["modes"] and set(row["modes"]) <= set(MODES), "invalid read-closure row")
        ids.add(row["id"])
        if row["template"]:
            path_parts(re.sub(r"<[a-z]+>", "x", row["template"]))
        need(all(set(site) == {"site", "source"} for site in row["sites"]) and row["sites"], "read-closure site")
    for row in value["instrumentation"]:
        need(set(row) == {"id", "sites"} and row["id"] not in ids and row["sites"]
             and all(set(site) == {"site", "source"} for site in row["sites"]), "invalid instrumentation row")
        ids.add(row["id"])
    for row in value["excluded"]:
        need(set(row) == {"id", "class", "reason", "families", "reads"} and row["id"] not in ids and row["reads"]
             and all({"site", "source"} <= set(read) for read in row["reads"]), "invalid excluded read class")
        ids.add(row["id"])
    return value


def _sites(closure):
    sites = {}
    for row in closure["rows"] + closure["instrumentation"] + closure["excluded"]:
        for site in row.get("sites", row.get("reads", ())):
            need(sites.get(site["site"], site["source"]) == site["source"], "conflicting site pin")
            sites[site["site"]] = site["source"]
    return sites


def audit_reads(closure, sources):
    """Every pinned read site must still say exactly what was reviewed."""
    sites = _sites(closure)
    for key, expected in sites.items():
        path, number = key.rsplit(":", 1)
        need(type(sources.get(path)) is str, "read-closure source missing: " + path)
        lines = sources[path].splitlines()
        start = int(number) - 1
        actual = "\n".join(line.strip() for line in lines[start:start + len(expected.splitlines())])
        need(actual == expected, "read source pin mismatch: " + key)
    return tuple(sorted(sites))


def pinned_paths(closure):
    paths = {key.rsplit(":", 1)[0] for key in list(CALLER_SITES) + list(EXCLUDED_SITES) + list(_sites(closure))}
    return sorted(paths)


def git_sources(repo, code_ref, paths):
    """Read exact blobs at code_ref through one batch reader; no worktree file."""
    need(SHA1.fullmatch(code_ref) is not None, "code_ref must be a full commit id")
    environment = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
    query = "".join(line + "\n" for line in [code_ref] + [code_ref + ":" + p for p in paths]).encode()
    result = subprocess.run(["git", "--no-replace-objects", "-C", repo, "cat-file", "--batch"],
                            input=query, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                            env=environment, timeout=30, check=False)
    need(result.returncode == 0, "git cat-file failed")
    raw, index, sources, blobs = result.stdout, 0, {}, {}
    for position, name in enumerate([None] + paths):
        end = raw.find(b"\n", index)
        need(end >= 0, "truncated git batch output")
        header = raw[index:end].decode("ascii", "replace").split(" ")
        need(len(header) == 3, "missing object at code_ref: " + (name or code_ref))
        size = int(header[2])
        body = raw[end + 1:end + 1 + size]
        need(len(body) == size and raw[end + 1 + size:end + 2 + size] == b"\n", "torn git batch output")
        index = end + 2 + size
        if name is None:
            need(header[:2] == [code_ref, "commit"], "code_ref is not that commit")
        else:
            need(header[1] == "blob", "pinned path is not a file at code_ref: " + name)
            sources[name] = body.decode("utf-8")
            blobs[name] = header[0]
    need(index == len(raw), "trailing git batch output")
    return sources, blobs


def check_audit(audit, closure, code_ref):
    """A receipt counts only when sealed for this code_ref and closure and
    covering every caller and read pin; a sealed subset is refused."""
    need(type(audit) is dict and audit.get("format") == AUDIT_FORMAT, "unsupported pin audit")
    need(audit.get("code_ref") == code_ref and audit.get("closure_sha256") == seal(closure)
         and audit.get("sha256") == seal({k: v for k, v in audit.items() if k != "sha256"}),
         "pin audit does not cover this capture's code_ref and closure")
    need(audit["caller_sites"] == sorted(set(CALLER_SITES) | set(EXCLUDED_SITES))
         and audit["read_sites"] == sorted(_sites(closure)) and type(audit["blobs"]) is dict
         and sorted(audit["blobs"]) == pinned_paths(closure),
         "pin audit does not cover every caller and read pin")
    return audit


def audit_code_ref(repo, code_ref, closure):
    """Carry-forward: audit every caller and read pin at the capture's code_ref."""
    sources, blobs = git_sources(repo, code_ref, pinned_paths(closure))
    callers = audit_callers(sources)
    reads = audit_reads(closure, sources)
    value = dict(format=AUDIT_FORMAT, code_ref=code_ref, closure_sha256=seal(closure),
                 caller_sites=sorted(set(callers)), read_sites=list(reads), blobs=blobs)
    value["sha256"] = seal(value)
    return check_audit(value, closure, code_ref)


# --- admission ---------------------------------------------------------------

def admitted_places(closure, admission):
    """Expand templates only from explicit admission values; nothing discovered."""
    values = admission["values"]
    roots = {(r["home"], r["root"], r["task"]): r["path"] for r in admission["roots"]}
    places = {}
    for row in closure["rows"]:
        names = re.findall(r"<([a-z]+)>", row["template"])
        need(all(name in values for name in names), "template value not admitted: " + row["id"])
        combos = [({}, row["template"])]
        for name in dict.fromkeys(names):
            combos = [(dict(bound, **{name: v}), text.replace("<" + name + ">", v))
                      for bound, text in combos for v in values[name]]
        for bound, path in combos:
            # A worktree template is relative to each admitted task's worktree.
            tasks = [""]
            if row["root"] == "worktree":
                need("t" in values, "worktree row needs admitted tasks: " + row["id"])
                tasks = [bound["t"]] if "t" in bound else values["t"]
            for home, task in sorted({(key[0], task) for key in roots for task in tasks}):
                if (home, row["root"], task) not in roots:
                    continue
                path_parts(path)
                key = (home, row["root"], task, path)
                entry = places.setdefault(key, [set(), set(), set()])
                entry[0].add(row["id"])
                entry[1].update(op for mode in row["modes"] for op in MODES[mode])
                entry[2].update(row["families"])
    return places


def captured_places(places):
    """Admitted places plus their ancestors, which topology requires as objects."""
    keys = set(places)
    for home, root, task, path in list(places):
        parts = path_parts(path)
        for depth in range(len(parts)):
            keys.add((home, root, task, "/".join(parts[:depth])))
    return sorted(keys)


def validate_admission(admission, validate, manifest):
    validate(admission)
    need(TOKEN.fullmatch(admission["label"]) is not None, "label is not an enable epoch token")
    manifest(admission["manifest"])
    homes = {h["id"]: h for h in admission["manifest"]["homes"]}
    need(all(h["code_ref"] == admission["code_ref"] and h["machine"] == admission["machine"]
             and not h["remote"] for h in homes.values()), "admission home code/machine/remote mismatch")
    seen = set()
    for row in admission["roots"]:
        key = (row["home"], row["root"], row["task"])
        need(key not in seen and row["home"] in homes and os.path.normpath(row["path"]) == row["path"]
             and row["path"].startswith("/"), "invalid admitted root")
        tasks = {t["id"] for t in homes[row["home"]]["tasks"]}
        need((row["task"] in tasks) if row["root"] == "worktree" else row["task"] == "", "root task binding")
        if row["root"] == "state":
            need(row["path"] == homes[row["home"]]["state_root"], "state root differs from manifest")
        seen.add(key)
    need(all((h, "state", "") in seen for h in homes), "home without admitted state root")
    values = admission["values"]
    need(len(values) <= 32 and all(re.fullmatch(r"[a-z]{1,16}", name) is not None and type(rows) is list
                                   and len(rows) <= 1000 and len(set(rows)) == len(rows)
                                   and all(type(v) is str and TOKEN.fullmatch(v) is not None for v in rows)
                                   for name, rows in values.items()), "invalid template values")
    need(set(values.get("t", ())) <= {t["id"] for h in homes.values() for t in h["tasks"]},
         "template task value outside the manifest")
    need(set(admission["callers"]) <= set(CALLERS), "unknown selected caller")
    for path in (admission["destination"], admission["enable_file"]):
        need(path.startswith("/") and os.path.normpath(path) == path, "noncanonical recorder path")
    return admission


# --- G6 projection -------------------------------------------------------

def project(admission, captured):
    """Screen bytes and ticket demand before T0; unknown ceilings refuse."""
    spec = admission["projection"]
    rows = {}
    for row in spec["places"]:
        key = (row["home"], row["root"], row["task"], row["path"])
        need(key not in rows, "duplicate projection place")
        need(row["bytes"] <= MAX_FILE, "projected object exceeds blob bound")
        rows[key] = row
    need(set(rows) == set(captured), "projection must name exactly every captured place")
    decoded = sum(r["bytes"] * (1 + r["updates"]) for r in rows.values()) + spec["request_bytes"]
    encoded = decoded * 4 // 3 + 4096 * (len(rows) + sum(r["updates"] for r in rows.values())) + spec["request_bytes"]
    demand, payload_limit = 0, CHAIN_MAX * (TICKET_BYTES - 256)
    for producer in spec["producers"]:
        need(producer["bytes"] <= payload_limit, "producer exceeds ticket chain capacity")
        demand += producer["count"] * max(1, math.ceil(producer["bytes"] / TICKET_BYTES))
    need(decoded <= DECODED_MAX, "projected decoded workload exceeds 24 MiB")
    need(encoded <= JSON_MAX, "projected JSON exceeds 64 MiB")
    need(demand <= DEMAND_MAX, "projected ticket demand exceeds 1024 of 4096")
    need(SPOOL_BYTES + 2 * encoded + 16 * MIB <= QUOTA_MAX, "projected evidence exceeds 256 MiB")
    return dict(decoded_bytes=decoded, json_bytes=encoded, ticket_demand=demand)


# --- filesystem, destination and root overlap ----------------------------

def _unescape_mount(text):
    return re.sub(r"\\([0-7]{3})", lambda m: chr(int(m.group(1), 8)), text)


def mounts(text):
    rows = []
    for line in text.splitlines():
        left, separator, right = line.partition(" - ")
        need(separator, "malformed mountinfo")
        fields, tail = left.split(" "), right.split(" ")
        major, minor = fields[2].split(":")
        rows.append(dict(device=os.makedev(int(major), int(minor)), point=_unescape_mount(fields[4]), fstype=tail[0]))
    return rows


def filesystem_of(path, table, device):
    best = None
    for row in table:
        point = row["point"]
        inside = path == point or path.startswith(point.rstrip("/") + "/")
        if row["device"] == device and inside and (best is None or len(point) > len(best["point"])):
            best = row
    need(best is not None, "mount for path not found")
    return best["fstype"]


def check_filesystems(destination, roots, table, stat_path=os.stat, statvfs=os.statvfs, real=os.path.realpath):
    """Dedicated <=256 MiB ext4 destination; local ext4 roots; no overlap."""
    parent = os.path.dirname(destination)
    need(not os.path.lexists(destination), "destination already exists")
    need(real(parent) == parent, "destination parent is an alias")
    parent_stat = stat_path(parent)
    need(filesystem_of(parent, table, parent_stat.st_dev) == "ext4", "destination is not local ext4")
    vfs = statvfs(parent)
    need(vfs.f_blocks * vfs.f_frsize <= QUOTA_MAX, "destination filesystem is not a dedicated <=256 MiB quota")
    for root in roots:
        need(real(root) == root, "admitted root is an alias")
        root_stat = stat_path(root)
        need(filesystem_of(root, table, root_stat.st_dev) == "ext4", "admitted root is not local ext4")
        need(root_stat.st_dev != parent_stat.st_dev, "destination shares a filesystem with an admitted root")
        for outer, inner in ((root, destination), (destination, root)):
            need(not (inner == outer or inner.startswith(outer.rstrip("/") + "/")), "destination overlaps an admitted root")


# --- bounded object capture (I/O child) ----------------------------------

def capture_object(path):
    """One admitted place: never follows a symlink or opens a special file."""
    try:
        st = os.lstat(path)
    except FileNotFoundError:
        return None
    need(not stat.S_ISLNK(st.st_mode), "symlink in admitted place")
    meta = dict(identity="%d:%d" % (st.st_dev, st.st_ino), mode=st.st_mode & 0o7777, mtime_ns=st.st_mtime_ns)
    if stat.S_ISDIR(st.st_mode):
        try:
            names = sorted(os.listdir(os.fsencode(path)))
        except PermissionError:
            return dict(meta, kind="directory", error="EACCES", content=b"")
        for name in names:
            name.decode("utf-8")
        return dict(meta, kind="directory", error="", content=b"".join(n + b"\0" for n in names))
    if stat.S_ISFIFO(st.st_mode):
        return dict(meta, kind="fifo", error="", content=b"")
    need(stat.S_ISREG(st.st_mode), "special file in admitted place")
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC)
    except PermissionError:
        return dict(meta, kind="regular", error="EACCES", content=b"")
    try:
        before = os.fstat(fd)
        need((before.st_dev, before.st_ino) == (st.st_dev, st.st_ino), "admitted place replaced during capture")
        chunks, size = [], 0
        while True:
            chunk = os.read(fd, 65536)
            if not chunk:
                break
            size += len(chunk)
            need(size <= MAX_FILE, "admitted file exceeds 4 MiB")
            chunks.append(chunk)
        after = os.fstat(fd)
        need((after.st_size, after.st_mtime_ns) == (size, before.st_mtime_ns), "torn read of admitted file")
    finally:
        os.close(fd)
    return dict(meta, kind="regular", error="", content=b"".join(chunks))


def encode_object(value):
    return None if value is None else dict({k: v for k, v in value.items() if k != "content"}, content=b64(value["content"]))


def physical(roots, key):
    home, root, task, path = key
    return os.path.join(roots[(home, root, task)], path) if path else roots[(home, root, task)]


# --- inotify loss detector -----------------------------------------------

IN_MODIFY, IN_ATTRIB, IN_CLOSE_WRITE = 0x2, 0x4, 0x8
IN_MOVED_FROM, IN_MOVED_TO, IN_CREATE, IN_DELETE = 0x40, 0x80, 0x100, 0x200
IN_DELETE_SELF, IN_MOVE_SELF, IN_UNMOUNT, IN_Q_OVERFLOW, IN_IGNORED = 0x400, 0x800, 0x2000, 0x4000, 0x8000
IN_ONLYDIR, IN_DONT_FOLLOW, IN_ISDIR = 0x01000000, 0x02000000, 0x40000000
CONTENT = IN_MODIFY | IN_ATTRIB | IN_CLOSE_WRITE
STRUCTURE = IN_MOVED_FROM | IN_MOVED_TO | IN_CREATE | IN_DELETE
LOSS = IN_DELETE_SELF | IN_MOVE_SELF | IN_UNMOUNT | IN_Q_OVERFLOW | IN_IGNORED


class Watcher:
    """Directory watches established before the initial scan."""

    def __init__(self, directories):
        self._libc = ctypes.CDLL(None, use_errno=True)
        self.fd = self._libc.inotify_init1(os.O_NONBLOCK | os.O_CLOEXEC)
        need(self.fd >= 0, "inotify unavailable")
        self._dirs, self.events = {}, []
        add = self._libc.inotify_add_watch
        add.argtypes = (ctypes.c_int, ctypes.c_char_p, ctypes.c_uint32)
        for key, path in directories:
            wd = add(self.fd, os.fsencode(path), CONTENT | STRUCTURE | IN_DELETE_SELF | IN_MOVE_SELF
                     | IN_ONLYDIR | IN_DONT_FOLLOW)
            need(wd >= 0, "inotify watch failed")
            self._dirs[wd] = key

    def drain(self, at_ns):
        while True:
            try:
                raw = os.read(self.fd, 65536)
            except BlockingIOError:
                return
            index = 0
            while index < len(raw):
                wd, mask, _, size = struct.unpack_from("iIII", raw, index)
                name = raw[index + 16:index + 16 + size].rstrip(b"\0")
                index += 16 + size
                self.events.append(dict(directory=self._dirs.get(wd), mask=mask,
                                        name=name.decode("utf-8", "surrogateescape"), at_ns=at_ns))

    def wait(self, timeout_ns):
        ready, _, _ = select.select([self.fd], [], [], max(0, timeout_ns) / SECOND)
        return bool(ready)

    def close(self):
        os.close(self.fd)


def unmatched_events(events, changes, captured, t0_ns, barrier_ns):
    """Every kernel event needs a witness; coalescing only removes events."""
    changed = {tuple(c["key"]) for c in changes}
    listed = {}
    for change in changes:
        if change["listing_delta"]:
            listed.setdefault(tuple(change["key"]), set()).update(change["listing_delta"])
    captured = set(captured)
    problems = []
    for event in events:
        if event["directory"] is None or event["mask"] & LOSS:
            problems.append("watch loss or root replacement")
            continue
        directory = tuple(event["directory"])
        if not t0_ns <= event["at_ns"] <= barrier_ns:
            problems.append("event outside the witnessed interval")
            continue
        name = event["name"]
        child = directory[:3] + (directory[3] + "/" + name if directory[3] else name,) if name else directory
        if event["mask"] & STRUCTURE and name not in listed.get(directory, ()):
            problems.append("unwitnessed listing change")
        elif child in captured and child not in changed:
            problems.append("unwitnessed change to admitted place")
    return problems


# --- guard ---------------------------------------------------------------------

def proc_start_ticks(pid):
    with open("/proc/%d/stat" % pid, "rb") as stream:
        text = stream.read(4096)
    return int(text[text.rfind(b")") + 2:].split()[19])


def verified_pidfd(pid, start_ticks):
    """Identity-bound handle; a reused or uncertain pid is never signalled."""
    try:
        fd = os.pidfd_open(pid)
    except ProcessLookupError:
        return None
    try:
        if proc_start_ticks(pid) == start_ticks:
            return fd
    except (FileNotFoundError, ProcessLookupError, ValueError, IndexError):
        pass
    os.close(fd)
    return None


def _alive(fd):
    ready, _, _ = select.select([fd], [], [], 0)
    return not ready


def _wait_all(fds, deadline_ns):
    while any(_alive(fd) for fd in fds) and boottime_ns() < deadline_ns:
        select.select([fd for fd in fds if _alive(fd)], [], [], max(0, deadline_ns - boottime_ns()) / SECOND)


def escalate(targets, now_ns):
    """Signal first, wait, kill through the same pidfds, then bookkeeping."""
    handles = [(t, verified_pidfd(t["pid"], t["start_ticks"])) for t in targets]
    live = [(t, fd) for t, fd in handles if fd is not None]
    for _, fd in live:
        signal.pidfd_send_signal(fd, signal.SIGTERM)
    _wait_all([fd for _, fd in live], now_ns + TERM_GRACE_NS)
    killed = []
    for target, fd in live:
        if _alive(fd):
            signal.pidfd_send_signal(fd, signal.SIGKILL)
            killed.append(target)
    _wait_all([fd for _, fd in live], boottime_ns() + KILL_OBSERVE_NS)
    outcome = [dict(role=t["role"], pid=t["pid"], start_ticks=t["start_ticks"],
                    outcome=("not-ours-or-gone" if fd is None else "stuck" if _alive(fd)
                             else "killed" if t in killed else "terminated"))
               for t, fd in handles]
    for _, fd in live:
        os.close(fd)
    return outcome


def admit_finalizer(script):
    """fm-mem-guard admission for the 768 MiB finalizer; no FM_MEM_GUARD=off bypass.

    Every FM_* variable is removed, so no test seam (proc root, guard
    directory, clock, rules file) can fake the machine's answer.
    """
    environment = {k: v for k, v in os.environ.items() if not k.startswith("FM_")}
    result = subprocess.run([script, "admit", "--cost-mib", str(FINALIZER_COST_MIB)], env=environment,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=5, check=False)
    need(result.returncode == 0 and result.stdout == b"admit\n",
         "memory guard refused the finalizer: " + result.stdout.decode("utf-8", "replace").strip())


# --- offline finalizer ---------------------------------------------------------

def _place_key(fields):
    home, root, task, path = fields
    need(root in ROOTS, "unknown logical root")
    path_parts(path)
    return (home, root, task, path)


def _int(text, upper=2**63 - 1):
    need(re.fullmatch(r"0|[1-9][0-9]{0,18}", text) is not None and int(text) <= upper, "invalid record number")
    return int(text)


def projected_shape(caller, end):
    """Live values are what the pinned caller saw; reject raw-stream records."""
    _, kind, status_kind = CALLERS[caller]
    out, err, status = end["stdout"], end["stderr"], end["exit_status"]
    if kind in ("value", "first", "merged", "value-stderr"):
        need(b"\0" not in out and not out.endswith(b"\n"), "live value is not the caller's substitution")
        if kind == "first":
            need(b"\n" not in out, "live first-line value has more lines")
    if kind not in ("value-stderr", "identity"):
        need(err == b"", "caller did not observe stderr")
    need(status_kind == "status" or status in ((0,) if status_kind == "continued" else (0, 1)),
         "live status is not the caller's projection")


def _listing(raw):
    need(not raw or raw.endswith(b"\0"), "partial listing image")
    names = raw[:-1].split(b"\0") if raw else []
    need(len(set(names)) == len(names) and all(names), "invalid listing image")
    return sorted(names)


class Finalizer:
    """Builds v3 + capture bindings from one attempt's private evidence."""

    def __init__(self, admission, closure, audit, enable, acquisition, producers):
        check_audit(audit, closure, admission["code_ref"])
        need(acquisition["format"] == ACQUISITION_FORMAT and acquisition["enable_nonce"] == enable["nonce"],
             "acquisition/enable generation mismatch")
        self.admission, self.enable, self.acq = admission, enable, acquisition
        self.places = admitted_places(closure, admission)
        self.captured = captured_places(self.places)
        self.t0 = acquisition["t0_ns"]
        self.cutoff, self.end = self.t0 + WINDOW_NS, self.t0 + ACQUISITION_NS
        self.wall_t0 = acquisition["wall_t0_ns"]
        need(enable["wall_t0_us"] * 1000 == self.wall_t0, "enable wall origin mismatch")
        need(abs(acquisition["offset_end_ns"] - acquisition["offset_start_ns"]) <= CLOCK_DRIFT_NS,
             "wall clock stepped during acquisition")
        need(acquisition["barrier_ns"] >= self.end, "final barrier before acquisition end")
        self.producers = producers

    def mono(self, wall_us):
        return self.t0 + _int(wall_us) * 1000 - self.wall_t0

    def _object(self, value):
        if value is None:
            return None
        return dict(identity=value["identity"], kind=value["kind"], mode=value["mode"], mtime_ns=value["mtime_ns"],
                    error=value["error"], content=value["content"])

    def build(self, trace, synthetic, label):
        initial = {tuple(row["key"]): row["object"] for row in self.acq["initial"]}
        need(sorted(initial) == self.captured, "initial scan does not cover the captured inventory")
        begins, ends, reads, observes, changes = {}, {}, [], [], []
        for order, producer in enumerate(self.producers):
            for record in producer["records"]:
                kind, fields, segments = record["kind"], record["fields"], record["segments"]
                where = (order, record["seq"])
                if kind == "begin":
                    need(len(fields) >= 9 and len(segments) == 1, "invalid begin record")
                    need(fields[0] not in begins, "duplicate request begin")
                    begins[fields[0]] = dict(id=fields[0], caller=fields[1], home=fields[2], task=fields[3],
                                             generation=fields[4], kind=fields[5], actor=dict(
                                                 name=fields[6], token=fields[7], claim=b64(segments[0])),
                                             start_ns=self.mono(fields[8]), arguments=fields[9:], where=where)
                elif kind == "end":
                    # The caller-visible projection the hook observed at the
                    # pinned site, not the producer's raw streams.
                    need(len(fields) == 3 and len(segments) == 2 and fields[0] not in ends, "invalid end record")
                    ends[fields[0]] = dict(end_ns=self.mono(fields[1]), exit_status=_int(fields[2], 255),
                                           stdout=segments[0], stderr=segments[1])
                elif kind == "read":
                    need(len(fields) == 13 and len(segments) == 1, "invalid read record")
                    reads.append(dict(request=fields[0], id=fields[1], operation=fields[2],
                                      key=None if fields[2] == "clock" else _place_key(fields[3:7]),
                                      clock=fields[7], offset=_int(fields[8], MAX_FILE), length=_int(fields[9], MAX_FILE),
                                      start_ns=self.mono(fields[10]), end_ns=self.mono(fields[11]),
                                      error=fields[12], result=segments[0], producer=order, where=where))
                elif kind == "observe":
                    need(len(fields) >= 11 and len(segments) == 2, "invalid observe record")
                    observes.append(dict(request=fields[0], id=fields[1], operation=fields[2],
                                         cwd=_place_key(fields[3:7]), generation=fields[7],
                                         start_ns=self.mono(fields[8]), end_ns=self.mono(fields[9]),
                                         exit_status=_int(fields[10], 255), arguments=fields[11:],
                                         stdout=segments[0], stderr=segments[1], where=where))
                elif kind == "change":
                    need(len(fields) == 14 and len(segments) == 1 and fields[0] in ("image", "append", "absent"),
                         "invalid change record")
                    changes.append(dict(op=fields[0], key=_place_key(fields[1:5]), at_ns=self.mono(fields[5]),
                                        meta=dict(identity=fields[6], kind=fields[7], mode=_int(fields[8], 4095),
                                                  mtime_ns=_int(fields[9]), error=fields[10]),
                                        offset=_int(fields[11], MAX_FILE), request=fields[12], commit=fields[13],
                                        data=segments[0], where=where))
                else:
                    raise Refused("recorder: unknown record kind")
        # Requests: classify by the fixed caller registry; selection is decided
        # by start time and admitted caller class, never after a failure.
        selected, excluded, late = [], {}, 0
        for ident, begin in begins.items():
            caller = begin["caller"]
            need(caller in CALLERS or caller in EXCLUDED_SITES, "unknown caller identity")
            need(begin["start_ns"] >= self.t0, "request begin before T0")
            if caller in EXCLUDED_SITES or caller not in self.admission["callers"]:
                excluded[caller] = excluded.get(caller, 0) + 1
            elif begin["start_ns"] >= self.cutoff:
                late += 1
            else:
                need(ident in ends, "selected request has no end marker")
                end = ends[ident]
                need(begin["start_ns"] <= end["end_ns"] <= begin["start_ns"] + REQUEST_LIMIT_NS,
                     "selected request exceeds its 30 s limit")
                need(end["end_ns"] <= self.end, "selected request ends after acquisition")
                need(CALLERS[caller][0] == begin["kind"], "caller/request kind mismatch")
                projected_shape(caller, end)
                selected.append(ident)
        known = set(begins)
        for row in reads + observes:
            need(row["request"] in known, "record for an unknown request")
        for row in changes:
            need(row["request"] == "" or row["request"] in known, "change for an unknown request")
        selected.sort(key=lambda i: (begins[i]["start_ns"], begins[i]["where"]))
        files, history, model_changes, after_end = self._timeline(initial, changes)
        requests, bound = [], []
        for ident in selected:
            begin, end = begins[ident], ends[ident]
            own = sorted((r for r in reads if r["request"] == ident), key=lambda r: (r["start_ns"], r["where"]))
            for left, right in zip(own, own[1:]):
                need(left["end_ns"] <= right["start_ns"], "concurrent reads within one request are unrepresentable")
            rows = [self._read(row, history, begin["kind"]) for row in own]
            observations = [dict(id=o["id"], operation=o["operation"], arguments=o["arguments"],
                                 cwd=dict(zip(("home", "root", "task", "path"), o["cwd"])), generation=o["generation"],
                                 start_ns=o["start_ns"], end_ns=o["end_ns"], exit_status=o["exit_status"],
                                 stdout=b64(o["stdout"]), stderr=b64(o["stderr"]))
                            for o in sorted((o for o in observes if o["request"] == ident),
                                            key=lambda o: (o["start_ns"], o["where"]))]
            requests.append(dict(id=ident, home=begin["home"], task=begin["task"], generation=begin["generation"],
                                 kind=begin["kind"], arguments=begin["arguments"], actor=begin["actor"],
                                 start_ns=begin["start_ns"], end_ns=end["end_ns"], observations=observations))
            effects = [dict(place=dict(zip(("home", "root", "task", "path"), c["key"])),
                            content=None if c["object"] is None else c["object"]["content"],
                            object_sha256=object_seal(c["object"]), change_seq=c["seq"], commit_id=c["commit"])
                       for c in model_changes if c["request"] == ident and c["commit"]]
            live = dict(stdout=b64(end["stdout"]), stderr=b64(end["stderr"]), exit_status=end["exit_status"],
                        effects=effects)
            bound.append(dict(id=ident, caller=begin["caller"], reads=rows, live=live))
        self.after_end = after_end
        clock = dict(machine=self.admission["machine"], boot_id=self.enable["boot_id"],
                     namespace=self.acq["namespace"], monotonic_start_ns=self.t0, monotonic_end_ns=self.end,
                     wall_start_ns=self.wall_t0)
        workload = dict(format="fm-supervision-replay.v3", synthetic=synthetic, label=label,
                        manifest=self.admission["manifest"], trace=trace, clock=clock, files=files,
                        changes=[{k: c[k] for k in ("seq", "at_ns", "place", "before_sha256", "object")}
                                 for c in model_changes], requests=requests)
        workload["sha256"] = seal(workload)
        bindings = dict(format="fm-supervision-capture-bindings.v1", workload_sha256=workload["sha256"],
                        admission_sha256=seal(self.admission), code_ref=self.admission["code_ref"],
                        start_ns=self.t0, cutoff_ns=self.cutoff, requests=bound)
        bindings["sha256"] = seal(bindings)
        provenance = dict(format=PROVENANCE_FORMAT, scope="captured-subset-diagnostic", g5="open",
                          whole_workload_coverage=False, selected=len(selected), late_starts=late,
                          excluded_callers=[dict(caller=c, count=n) for c, n in sorted(excluded.items())]
                          + [dict(caller="harness/direct-output", count=None)],
                          producers=len(self.producers), tickets=sum(len(p["tickets"]) for p in self.producers))
        return workload, bindings, provenance

    def _timeline(self, initial, changes):
        current = {key: self._object(None if value is None else dict(value)) for key, value in initial.items()}
        files = [dict(place=dict(zip(("home", "root", "task", "path"), key)), object=current[key]) for key in self.captured]
        history = {key: [(self.t0, current[key])] for key in self.captured}
        model, after_end, seen = [], [], set()
        for change in sorted(changes, key=lambda c: (c["at_ns"], c["where"])):
            key = change["key"]
            need(key in current, "change targets an unadmitted place")
            need(self.t0 <= change["at_ns"], "change before T0")
            need((key, change["at_ns"]) not in seen, "duplicate same-time change to one place")
            seen.add((key, change["at_ns"]))
            before = current[key]
            if change["op"] == "absent":
                after = None
                need(not change["data"], "deletion carries bytes")
            else:
                old = blob(before["content"]) if before is not None else b""
                if change["op"] == "append":
                    need(before is not None and before["kind"] == "regular" and change["offset"] == len(old),
                         "append offset is not the exact end of the witnessed image")
                    raw = old + change["data"]
                else:
                    raw = change["data"]
                need(len(raw) <= MAX_FILE, "changed image exceeds 4 MiB")
                if change["meta"]["kind"] == "directory":
                    raw = b"".join(n + b"\0" for n in _listing(raw))
                need(change["meta"]["kind"] in ("regular", "directory", "fifo"), "unsupported changed kind")
                after = dict(change["meta"], content=b64(raw))
            delta = set()
            if (before or {}).get("kind") == "directory" or (after or {}).get("kind") == "directory":
                old_names = set(_listing(blob(before["content"]))) if before and before["kind"] == "directory" else set()
                new_names = set(_listing(blob(after["content"]))) if after and after["kind"] == "directory" else set()
                delta = {n.decode("utf-8", "surrogateescape") for n in old_names ^ new_names}
            current[key] = after
            row = dict(key=key, at_ns=change["at_ns"], request=change["request"], commit=change["commit"],
                       place=dict(zip(("home", "root", "task", "path"), key)), before_sha256=object_seal(before),
                       object=after, listing_delta=sorted(delta))
            if change["at_ns"] <= self.end:
                row["seq"] = len(model) + 1
                model.append(row)
                history[key].append((change["at_ns"], after))
            else:
                after_end.append(row)
        self.final_model = current
        self.witnessed = model + after_end
        return files, history, model, after_end

    def _read(self, row, history, family):
        need(row["start_ns"] <= row["end_ns"], "read interval regression")
        if row["operation"] == "clock":
            need(row["key"] is None and row["clock"] in ("wall", "monotonic") and not row["error"],
                 "invalid clock read")
            value = _int(row["result"].decode("ascii") if row["result"].isascii() else "x")
            at = self.t0 + value - self.wall_t0 if row["clock"] == "wall" else value
            need(row["start_ns"] <= at <= row["end_ns"], "clock value outside its read interval")
            return dict(id=row["id"], operation="clock", place=None, clock=row["clock"], offset=0, length=0,
                        start_ns=at, end_ns=at, version_sha256=None, result=b64(canonical(value)), error="")
        key = row["key"]
        need(key in self.places and row["operation"] in self.places[key][1], "read outside the reviewed closure")
        need(family in self.places[key][2], "read outside its family's reviewed closure")
        need(row["clock"] == "", "file read has a clock selector")
        versions = history[key]
        at = max(index for index, (when, _) in enumerate(versions) if when <= row["start_ns"])
        version = versions[at][1]
        return dict(id=row["id"], operation=row["operation"], place=dict(zip(("home", "root", "task", "path"), key)),
                    clock="", offset=row["offset"], length=row["length"], start_ns=row["start_ns"],
                    end_ns=row["end_ns"], version_sha256=object_seal(version), result=b64(row["result"]),
                    error=row["error"])

    def losses(self):
        """Loss detectors: unmatched kernel events and final-reread mismatch."""
        problems = unmatched_events(self.acq["events"], self.witnessed, self.captured, self.t0,
                                    self.acq["barrier_ns"])
        final = {tuple(row["key"]): row["object"] for row in self.acq["final"]}
        need(sorted(final) == self.captured, "final reread does not cover the captured inventory")
        for key in self.captured:
            if final[key] != self.final_model[key]:
                problems.append("final reread differs from the witnessed model")
                break
        return problems
