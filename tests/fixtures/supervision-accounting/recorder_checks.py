"""CI-only recorder controller controls; synthetic tickets, roots and kernels.

No enable record is written outside the test temp root, no hook runs and no
home is read. The fixture producer below writes the ticket grammar the shell
primitive must write; the library is only the reader.
"""
import copy
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time
import unittest
from unittest.mock import patch

import binding_checks as v3
import workload_checks as old
import fm_supervision_recorder as rec
import fm_supervision_replay as replay

ROOT = old.ROOT
TMP = Path(os.environ["FM_ACCOUNTING_TEST_TMP"]) / "recorder"
TMP.mkdir(exist_ok=True)
accounting, blob, obj, place = old.accounting, old.blob, old.obj, old.place
CLI = ROOT / "bin/fm-supervision-recorder.py"
HEAD = subprocess.run(["git", "-C", str(ROOT), "rev-parse", "HEAD"], stdout=subprocess.PIPE,
                      check=True).stdout.decode().strip()
CREW = "bin/fm-classify-lib.sh:3709"
DRAIN = "bin/fm-afk-return.sh:784"
SNAPSHOT = "bin/fm-fleet-view.sh:29"
MEM = next(site for site in rec.EXCLUDED_SITES if site.startswith("bin/fm-mem-guard.sh:"))
T0 = 5_000_000_000
WALL = 1_700_000_000_000_000_000
counter = [0]


def fresh(name):
    counter[0] += 1
    path = TMP / ("%s-%d" % (name, counter[0]))
    path.mkdir(mode=0o700)
    return path


def us(mono_ns):
    """Hook wall-clock microseconds for a fixture monotonic instant."""
    return str((WALL + mono_ns - T0) // 1000)


def enable_record(spool, nonce="a" * 32):
    return dict(format=rec.ENABLE_FORMAT, epoch="attempt-1", nonce=nonce,
                boot_id="00000000-0000-4000-8000-000000000001", t0_cs=T0 // 10_000_000,
                cutoff_cs=T0 // 10_000_000 + 6000, end_cs=T0 // 10_000_000 + 9000,
                expiry_cs=T0 // 10_000_000 + 9200, wall_t0_us=WALL // 1000, spool=str(spool),
                tickets=rec.TICKETS, ticket_bytes=rec.TICKET_BYTES, chain_max=rec.CHAIN_MAX)


def esc(text):
    return text.replace("\\", "\\\\").replace("\t", "\\t").replace("\n", "\\n")


def record(seq, kind, fields, segments=()):
    head = "\t".join(esc(f) for f in fields).encode()
    parts = [head] + list(segments)
    raw = ("R\t%d\t%s\t%s\n" % (seq, kind, ",".join(str(len(p)) for p in parts))).encode() + b"".join(parts) + b"\n"
    return raw, sum(len(p) for p in parts)


class Producer:
    """Reference ticket writer: claim marker, whole records, chain, footer."""

    def __init__(self, spool, enable, identity=(4242, 99, 1), token="fm-crew-state"):
        self.spool, self.enable, self.identity, self.token = Path(spool), enable, identity, token
        self.records = []

    def add(self, kind, fields, segments=()):
        self.records.append((kind, list(fields), list(segments)))
        return self

    def write(self, per_ticket=None, status="ok", slots=None):
        rows = [record(i + 1, *row) for i, row in enumerate(self.records)]
        groups = [rows[i:i + per_ticket] for i in range(0, len(rows), per_ticket)] if per_ticket else [rows]
        groups = groups or [[]]
        slots = slots or [s for s in rec.probe_slots(self.token, *self.identity)][:len(groups)]
        head = slots[0]
        for index, (slot, group) in enumerate(zip(slots, groups)):
            pid, ticks, sequence = self.identity
            raw = ("H\t%s\t%s\t%s\t%d\t%d\t%d\t%d\t%d\t%d\n" % (
                rec.TICKET_FORMAT, self.enable["epoch"], self.enable["nonce"], slot, head, index, pid, ticks,
                sequence)).encode() + b"".join(r for r, _ in group)
            if index + 1 < len(groups):
                raw += ("N\t%d\n" % slots[index + 1]).encode()
            else:
                raw += ("F\t%d\t%d\t%s\n" % (len(rows), sum(n for _, n in rows), status)).encode()
            (self.spool / ("c%04d" % slot)).write_bytes(b"")
            (self.spool / ("t%04d" % slot)).write_bytes(raw)
        return slots


def bank():
    """A ticket bank without extent reservations; one test reserves for real."""
    spool = fresh("spool") / "spool"
    with patch.object(rec, "_fallocate_keep_size", lambda fd, size: None):
        rec.prepare_bank(str(spool))
    return spool


CLOSURE = dict(format=rec.CLOSURE_FORMAT, code_ref="1" * 40, rows=[
    dict(id="state-dir", families=["crew-state"], root="state", template="", modes="L", sites=[
        dict(site="bin/fm-supervision-recorder.py:2", source='"""P1 recorder controller; one owner-authorized attempt, never a routine check.')]),
    dict(id="status", families=["crew-state"], root="state", template="<t>.status", modes="RS", sites=[
        dict(site="bin/fm-supervision-recorder.py:2", source='"""P1 recorder controller; one owner-authorized attempt, never a routine check.')]),
    dict(id="meta", families=["crew-state"], root="state", template="<t>.meta", modes="R", sites=[
        dict(site="bin/fm-supervision-recorder.py:2", source='"""P1 recorder controller; one owner-authorized attempt, never a routine check.')]),
], instrumentation=[], excluded=[])


def manifest(code_ref=HEAD):
    value = copy.deepcopy(old.make(2)["manifest"])
    for home in value["homes"]:
        home["code_ref"] = code_ref
        home["machine"] = "ci-machine"
        home["remote"] = False
    return value


def admission(**changes):
    value = manifest()
    home = value["homes"][0]
    tasks = [t["id"] for t in home["tasks"]][:1]
    places = [("", 0, 0), (tasks[0] + ".status", 64, 2), (tasks[0] + ".meta", 64, 0)]
    result = dict(format="fm-supervision-recorder-admission.v1", label="attempt-1", machine="ci-machine",
                  code_ref=HEAD, manifest=value,
                  roots=[dict(home=h["id"], root="state", task="", path=h["state_root"]) for h in value["homes"]],
                  values=dict(t=tasks), callers=[CREW], destination="/captures/sr/attempt-1",
                  enable_file="/captures/sr/enable", projection=dict(
                      places=[dict(home=home["id"], root="state", task="", path=p, bytes=b, updates=u)
                              for p, b, u in places]
                      + [dict(home=h["id"], root="state", task="", path="", bytes=0, updates=0)
                         for h in value["homes"][1:]],
                      producers=[dict(**{"class": CREW}, count=40, bytes=4096)], request_bytes=1024))
    result.update(changes)
    return result


def checked(value):
    def schema(item):
        accounting.validate(item, accounting.load_json(accounting.SCHEMAS / "recorder-admission-v1.schema.json"))
    return rec.validate_admission(value, schema, accounting.manifest)


def audit(closure=CLOSURE, code_ref=HEAD):
    value = dict(format=rec.AUDIT_FORMAT, code_ref=code_ref, closure_sha256=replay.seal(closure),
                 caller_sites=sorted(set(rec.CALLER_SITES) | set(rec.EXCLUDED_SITES)),
                 read_sites=sorted(rec._sites(closure)), blobs={p: "0" * 40 for p in rec.pinned_paths(closure)})
    value["sha256"] = replay.seal(value)
    return value


class World:
    """One synthetic attempt: admission, initial scan, producers, final scan."""

    def __init__(self):
        self.admission = checked(admission())
        self.home = self.admission["manifest"]["homes"][0]["id"]
        self.task = self.admission["values"]["t"][0]
        self.spool = bank()
        self.enable = enable_record(self.spool)
        self.status = (self.home, "state", "", self.task + ".status")
        self.meta = (self.home, "state", "", self.task + ".meta")
        directory = obj((self.task + ".meta\0" + self.task + ".status\0").encode(), identity="d", kind="directory",
                        mode=0o700)
        self.objects = {(self.home, "state", "", ""): directory, self.status: obj(b"working\n", identity="s"),
                        self.meta: obj(b"kind=ship\n", identity="m")}
        for other in self.admission["manifest"]["homes"][1:]:
            self.objects[(other["id"], "state", "", "")] = obj(b"", identity="o", kind="directory", mode=0o700)
        self.final = dict(self.objects)
        self.events = []
        self.producers = []

    def producer(self, identity=(4242, 99, 1)):
        producer = Producer(self.spool, self.enable, identity)
        self.producers.append(producer)
        return producer

    def request(self, ident="r1", start=T0 + 1_000_000_000, end=None, caller=CREW, out=b"working", reads=True,
                identity=(4242, 99, 1)):
        end = start + 2_000_000_000 if end is None else end
        producer = self.producer(identity)
        producer.add("begin", [ident, caller, self.home, self.task, "g1", "crew-state", "main", "", us(start),
                               self.task], [b""])
        if reads:
            producer.add("read", [ident, "status", "read", self.home, "state", "", self.task + ".status", "", "0",
                                  "8", us(start + 1000), us(start + 2000), ""], [b"working\n"])
            producer.add("read", [ident, "now", "clock", "", "state", "", "", "wall", "0", "0", us(start + 3000),
                                  us(start + 4000), ""], [str(WALL + start + 3000 - T0).encode()])
        producer.add("end", [ident, us(end), "0"], [out, b""])
        return producer

    def change(self, key, at, data, ident="", commit="", op="image", identity=(5151, 7, 1), meta=None):
        meta = meta or dict(identity="s2", kind="regular", mode=0o600)
        producer = self.producer(identity)
        offset = len(replay.blob(self.final[key]["content"])) if op == "append" else 0
        producer.add("change", [op, key[0], key[1], key[2], key[3], us(at), meta["identity"], meta["kind"],
                                str(meta["mode"]), "0", "", str(offset), ident, commit], [data])
        raw = (replay.blob(self.final[key]["content"]) if op == "append" else b"") + data
        self.final[key] = None if op == "absent" else obj(raw, identity=meta["identity"], kind=meta["kind"],
                                                          mode=meta["mode"])
        self.events.append(dict(directory=list(key[:3]) + [""], mask=rec.IN_CLOSE_WRITE, name=key[3],
                                at_ns=at + 10, ))
        return producer

    def acquisition(self, **changes):
        rows = lambda table: [dict(key=list(k), object=v) for k, v in sorted(table.items())]
        value = dict(format=rec.ACQUISITION_FORMAT, enable_nonce=self.enable["nonce"], enable=self.enable,
                     t0_ns=T0, wall_t0_ns=WALL, offset_start_ns=WALL - T0, offset_end_ns=WALL - T0 + 500,
                     barrier_ns=T0 + rec.ACQUISITION_NS + rec.FLUSH_NS, namespace="time-4026531834",
                     initial=rows(self.objects), final=rows(self.final), events=self.events)
        value.update(changes)
        return value

    def trace(self):
        value = copy.deepcopy(old.make(2)["trace"])
        value.update(start_ns=T0, end_ns=T0 + rec.ACQUISITION_NS, monotonic_duration_ns=rec.ACQUISITION_NS,
                     synthetic=False)
        return value

    def finalize(self, closure=CLOSURE, audit_value=None, **acquisition):
        for producer in self.producers:
            producer.write()
        producers = rec.collect_spool(str(self.spool), self.enable)
        finalizer = rec.Finalizer(self.admission, closure, audit_value or audit(closure), self.enable,
                                  self.acquisition(**acquisition), producers)
        workload, bindings, provenance = finalizer.build(self.trace(), False, "attempt-1")
        return finalizer, workload, bindings, provenance


class SlotsAndEnable(unittest.TestCase):
    def test_fold_and_eight_distinct_probes(self):
        value = 17
        for byte in b"fm-crew-state":
            value = (33 * value + byte) % 4096
        self.assertEqual(rec.fold("fm-crew-state"), value)
        slots = rec.probe_slots("fm-crew-state", (4093 - value) % 4096, 0, 0)
        self.assertEqual(slots, [4093, 4094, 4095, 0, 1, 2, 3, 4])
        for bad in ("", "-x", "a" * 65, "a b", "é"):
            with self.assertRaises(rec.Refused):
                rec.fold(bad)
        with self.assertRaises(rec.Refused):
            rec.probe_slots("x", -1, 0, 0)

    def test_enable_record_is_strict_private_and_exclusive(self):
        record = enable_record("/captures/sr/spool")
        raw = rec.enable_line(record)
        self.assertEqual(rec.parse_enable(raw), record)
        for broken in (raw[:-1], raw + b"x\n", raw.replace(b"\t", b" ", 1), raw.replace(b"attempt-1", b"att\xc3\xa9")):
            with self.assertRaises(rec.Refused):
                rec.parse_enable(broken)
        for field, value in (("cutoff_cs", record["cutoff_cs"] + 1), ("expiry_cs", record["end_cs"]),
                             ("tickets", 4095), ("spool", "relative"), ("spool", "/a/../b"), ("nonce", "A" * 32)):
            with self.assertRaises(rec.Refused):
                rec.enable_line(dict(record, **{field: value}))
        directory = fresh("enable")
        path = str(directory / "enable")
        rec.write_enable(path, record)
        self.assertEqual(os.stat(path).st_mode & 0o777, 0o400)
        self.assertEqual(rec.parse_enable(Path(path).read_bytes()), record)
        with self.assertRaises(FileExistsError):
            rec.write_enable(path, record)
        os.chmod(directory, 0o720)
        with self.assertRaises(rec.Refused):
            rec.write_enable(str(directory / "other"), record)
        os.chmod(directory, 0o700)
        os.symlink(path, str(directory / "link"))
        with self.assertRaises(FileExistsError):
            rec.write_enable(str(directory / "link"), record)

    def test_role_limits_never_touch_nproc(self):
        script = ("import resource,sys;sys.path.insert(0,%r);import fm_supervision_recorder as r;"
                  "before=resource.getrlimit(resource.RLIMIT_NPROC);r.limit('guard');"
                  "print(resource.getrlimit(resource.RLIMIT_CPU)[0],resource.getrlimit(resource.RLIMIT_AS)[0],"
                  "resource.getrlimit(resource.RLIMIT_FSIZE)[0],resource.getrlimit(resource.RLIMIT_NOFILE)[0],"
                  "before==resource.getrlimit(resource.RLIMIT_NPROC))" % str(ROOT / "bin"))
        out = subprocess.run([sys.executable, "-c", script], stdout=subprocess.PIPE, check=True).stdout.split()
        self.assertEqual(out, [b"1", str(32 * 1024 * 1024).encode(), str(1024 * 1024).encode(), b"128", b"True"])


class Spool(unittest.TestCase):
    def setUp(self):
        self.spool = bank()
        self.enable = enable_record(self.spool)

    def producer(self, identity=(10, 20, 1)):
        return Producer(self.spool, self.enable, identity)

    def refuses(self, message):
        with self.assertRaisesRegex(rec.Refused, message):
            rec.collect_spool(str(self.spool), self.enable)

    def test_bank_is_finite_private_and_reserved(self):
        names = sorted(os.listdir(self.spool))
        self.assertEqual(len(names), rec.TICKETS)
        st = os.stat(self.spool / "t0000")
        self.assertEqual((st.st_size, st.st_mode & 0o777), (0, 0o600))
        self.assertEqual(rec.collect_spool(str(self.spool), self.enable), [])
        with self.assertRaises(FileExistsError):
            rec.prepare_bank(str(self.spool))
        fd = os.open(str(fresh("reserve") / "t0000"), os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        try:
            rec._fallocate_keep_size(fd, rec.TICKET_BYTES)
            st = os.fstat(fd)
        finally:
            os.close(fd)
        self.assertEqual(st.st_size, 0)
        self.assertGreaterEqual(st.st_blocks * 512, rec.TICKET_BYTES)

    def test_chain_records_escapes_and_segments_round_trip(self):
        producer = self.producer()
        for index in range(5):
            producer.add("observe", ["r", "o%d" % index, "git", "h", "worktree", "t", "", "g", "1", "2", "0",
                                     "tab\there", "line\nnext", "back\\slash"], [b"\0bin\n", b""])
        slots = producer.write(per_ticket=2)
        self.assertEqual(len(slots), 3)
        (found,) = rec.collect_spool(str(self.spool), self.enable)
        self.assertEqual(found["tickets"], slots)
        self.assertEqual([r["seq"] for r in found["records"]], [1, 2, 3, 4, 5])
        self.assertEqual(found["records"][0]["fields"][-3:], ["tab\there", "line\nnext", "back\\slash"])
        self.assertEqual(found["records"][4]["segments"], [b"\0bin\n", b""])

    def test_every_unreconciled_spool_shape_refuses(self):
        self.producer().add("invalid", ["x"]).write()
        (self.spool / "x10-20-2").write_bytes(b"")
        self.refuses("exhausted")
        os.unlink(self.spool / "x10-20-2")
        (self.spool / "notes").write_bytes(b"")
        self.refuses("foreign")
        os.unlink(self.spool / "notes")
        (self.spool / "c0001").write_bytes(b"")
        self.refuses("claim marker")

    def test_ticket_without_claim_and_status_invalid_refuse(self):
        (slot,) = self.producer().add("invalid", ["hook could not record"]).write(status="invalid")
        self.refuses("invalid recording")
        os.unlink(self.spool / ("c%04d" % slot))
        self.refuses("claim marker")

    def test_torn_footer_generation_and_chain_damage_refuse(self):
        cases = []
        for damage in ("torn", "count", "nonce", "gap", "orphan", "overflow", "duplicate"):
            spool = bank()
            enable = enable_record(spool)
            producer = Producer(spool, enable).add("begin", ["r"], [b"claim"]).add("end", ["r", "1", "0"], [b"", b""])
            slots = producer.write(per_ticket=1)
            path = spool / ("t%04d" % slots[0])
            raw = path.read_bytes()
            if damage == "torn":
                path.write_bytes(raw.replace(b"claim", b"cla", 1))
            elif damage == "count":
                last = spool / ("t%04d" % slots[-1])
                last.write_bytes(last.read_bytes().replace(b"F\t2\t", b"F\t3\t"))
            elif damage == "nonce":
                path.write_bytes(raw.replace(enable["nonce"].encode(), b"b" * 32))
            elif damage == "gap":
                Producer(spool, enable, (1, 1, 1)).add("x", ["a"]).add("x", ["b"]).write()
                found = rec.probe_slots("fm-crew-state", 1, 1, 1)[0]
                target = spool / ("t%04d" % found)
                target.write_bytes(target.read_bytes().replace(b"R\t2\t", b"R\t3\t"))
            elif damage == "orphan":
                (spool / ("c%04d" % slots[-1])).write_bytes(b"")
                path.write_bytes(raw.replace(("N\t%d" % slots[1]).encode(), b"F\t1\t6\tok"))
            elif damage == "overflow":
                path.write_bytes(raw + b"\0" * rec.TICKET_BYTES)
            else:
                Producer(spool, enable).add("x", ["a"]).write(slots=[(slots[-1] + 9) % 4096])
            cases.append((damage, spool, enable))
        for damage, spool, enable in cases:
            with self.subTest(damage=damage), self.assertRaises(rec.Refused):
                rec.collect_spool(str(spool), enable)


class Closure(unittest.TestCase):
    def test_reviewed_registry_pins_hold_at_this_commit(self):
        closure = rec.load_closure()
        receipt = rec.audit_code_ref(str(ROOT), HEAD, closure)
        self.assertEqual(receipt["code_ref"], HEAD)
        self.assertEqual(receipt["sha256"], replay.seal({k: v for k, v in receipt.items() if k != "sha256"}))
        self.assertEqual(sorted(receipt["caller_sites"]), sorted(list(rec.CALLER_SITES) + list(rec.EXCLUDED_SITES)))
        self.assertTrue(receipt["read_sites"])
        self.assertTrue(closure["rows"] and closure["excluded"])
        for row in closure["rows"]:
            self.assertTrue(row["families"], row["id"])

    def test_pin_drift_and_wrong_objects_refuse(self):
        closure = rec.load_closure()
        sources, _ = rec.git_sources(str(ROOT), HEAD, rec.pinned_paths(closure))
        key = sorted(rec._sites(closure))[0]
        path, number = key.rsplit(":", 1)
        lines = sources[path].splitlines()
        lines.insert(int(number) - 1, "# inserted")
        with self.assertRaisesRegex(rec.Refused, "read source pin mismatch"):
            rec.audit_reads(closure, dict(sources, **{path: "\n".join(lines)}))
        with self.assertRaises(rec.Refused):
            rec.audit_reads(closure, {k: v for k, v in sources.items() if k != path})
        tree = subprocess.run(["git", "-C", str(ROOT), "rev-parse", "HEAD^{tree}"], stdout=subprocess.PIPE,
                              check=True).stdout.decode().strip()
        for ref, paths in ((tree, ["bin/fm-watch.sh"]), (HEAD, ["bin/no-such-file"]), (HEAD, ["bin"]),
                           ("HEAD", ["bin/fm-watch.sh"]), ("0" * 40, ["bin/fm-watch.sh"])):
            with self.subTest(ref=ref, paths=paths), self.assertRaises(rec.Refused):
                rec.git_sources(str(ROOT), ref, paths)

    def test_registry_shape_refusals(self):
        path = fresh("closure") / "closure.json"
        for change in (dict(format="x"), dict(code_ref="HEAD"), dict(extra=1),
                       dict(rows=[dict(CLOSURE["rows"][0], modes="W")]),
                       dict(rows=[dict(CLOSURE["rows"][0], root="home")]),
                       dict(rows=[dict(CLOSURE["rows"][0], template="../x")]),
                       dict(rows=CLOSURE["rows"] + [CLOSURE["rows"][0]])):
            path.write_text(json.dumps(dict(CLOSURE, **change)))
            with self.subTest(change=change), self.assertRaises((rec.Refused, ValueError)):
                rec.load_closure(path)


class Admission(unittest.TestCase):
    def test_places_expand_only_from_admitted_values(self):
        value = checked(admission())
        places = rec.admitted_places(CLOSURE, value)
        home, task = value["manifest"]["homes"][0]["id"], value["values"]["t"][0]
        self.assertEqual(places[(home, "state", "", task + ".status")][1], {"read", "stat", "exists"})
        self.assertEqual(len(rec.captured_places(places)), 3 + len(value["manifest"]["homes"]) - 1)
        self.assertEqual(rec.project(value, rec.captured_places(places))["ticket_demand"], 40)

    def test_admission_refusals(self):
        base = admission()
        home = base["manifest"]["homes"][0]
        cases = dict(caller=dict(callers=[MEM]), label=dict(label="a:b"),
                     value=dict(values=dict(t=["not-a-task"])), placeholder=dict(values=dict(T=["x"])),
                     root=dict(roots=base["roots"][1:]), relative=dict(destination="captures"),
                     state=dict(roots=[dict(base["roots"][0], path="/elsewhere")] + base["roots"][1:]),
                     task=dict(roots=base["roots"] + [dict(home=home["id"], root="config", task="x", path="/c")]),
                     code=dict(code_ref="2" * 40), machine=dict(machine="other"))
        for name, change in cases.items():
            with self.subTest(name=name), self.assertRaises((rec.Refused, accounting.Refused, ValueError)):
                checked(dict(base, **change))
        remote = copy.deepcopy(base)
        remote["manifest"]["homes"][0]["remote"] = True
        with self.assertRaises(rec.Refused):
            checked(remote)

    def test_projection_ceilings(self):
        value = checked(admission())
        captured = rec.captured_places(rec.admitted_places(CLOSURE, value))

        def screen(**changes):
            spec = copy.deepcopy(value["projection"])
            spec.update(changes)
            return rec.project(dict(value, projection=spec), captured)

        places = value["projection"]["places"]
        big = [dict(p, bytes=4 * 1024 * 1024, updates=6) if p["path"] else p for p in places]
        with self.assertRaisesRegex(rec.Refused, "24 MiB"):
            screen(places=big)
        with self.assertRaisesRegex(rec.Refused, "1024"):
            screen(producers=[{"class": CREW, "count": 1025, "bytes": 1}])
        with self.assertRaisesRegex(rec.Refused, "1024"):
            screen(producers=[{"class": CREW, "count": 342, "bytes": 3 * 32768}])
        self.assertEqual(screen(producers=[{"class": CREW, "count": 341, "bytes": 3 * 32768}])["ticket_demand"], 1023)
        with self.assertRaisesRegex(rec.Refused, "chain capacity"):
            screen(producers=[{"class": CREW, "count": 1, "bytes": 128 * 32768}])
        with self.assertRaisesRegex(rec.Refused, "exactly every"):
            screen(places=places[1:])
        with self.assertRaisesRegex(rec.Refused, "duplicate"):
            screen(places=places + places[:1])


class Filesystems(unittest.TestCase):
    TABLE = ("21 1 8:1 / / rw - ext4 /dev/sda1 rw\n"
             "22 21 7:0 / /captures rw - ext4 /dev/loop0 rw\n"
             "23 21 0:5 / /tmpfs rw - tmpfs tmpfs rw\n"
             "24 21 7:1 / /big rw - ext4 /dev/loop1 rw\n"
             "25 21 0:6 / /space\\040dir rw - ext4 /dev/sdb rw\n")

    def check(self, destination, roots, *, blocks=65536, exists=False, real=lambda p: p):
        devices = {"/captures": os.makedev(7, 0), "/tmpfs": os.makedev(0, 5), "/big": os.makedev(7, 1),
                   "/space dir": os.makedev(0, 6)}

        def fake_stat(path):
            device = next((d for p, d in devices.items() if path == p or path.startswith(p + "/")), os.makedev(8, 1))
            return os.stat_result((0o40700, 1, device, 1, 0, 0, 0, 0, 0, 0))

        def fake_vfs(path):
            return os.statvfs_result((4096, 4096, blocks, 0, 0, 0, 0, 0, 0, 255))
        with patch("os.path.lexists", lambda p: exists):
            rec.check_filesystems(destination, roots, rec.mounts(self.TABLE), fake_stat, fake_vfs, real)

    def test_dedicated_quota_and_separation(self):
        self.check("/captures/sr/attempt-1", ["/home/x/state", "/space dir/w"])
        for kwargs in (dict(destination="/tmpfs/a", roots=["/home/x"]),
                       dict(destination="/captures/a", roots=["/tmpfs/x"]),
                       dict(destination="/big/a", roots=["/home/x"], blocks=65537),
                       dict(destination="/home/x/state/a", roots=["/home/x/state"]),
                       dict(destination="/captures/a", roots=["/captures/a/b"]),
                       dict(destination="/captures/a", roots=["/captures"]),
                       dict(destination="/captures/a", roots=["/home/x"], exists=True),
                       dict(destination="/captures/a", roots=["/home/x"], real=lambda p: p + "x")):
            with self.subTest(**{k: str(v) for k, v in kwargs.items()}), self.assertRaises(rec.Refused):
                self.check(**kwargs)

    def test_live_mountinfo_parses(self):
        with open("/proc/self/mountinfo", encoding="utf-8") as stream:
            self.assertTrue(rec.mounts(stream.read()))


class Capture(unittest.TestCase):
    def test_object_kinds_and_bounds(self):
        root = fresh("objects")
        (root / "file").write_bytes(b"abc")
        os.mkfifo(root / "fifo")
        (root / "dir").mkdir()
        (root / "dir" / "b").write_bytes(b"")
        (root / "dir" / "a").write_bytes(b"")
        os.symlink("file", root / "link")
        (root / "big").write_bytes(b"x" * (4 * 1024 * 1024 + 1))
        value = rec.capture_object(str(root / "file"))
        st = os.stat(root / "file")
        self.assertEqual(value, dict(identity="%d:%d" % (st.st_dev, st.st_ino), mode=st.st_mode & 0o7777,
                                     mtime_ns=st.st_mtime_ns, kind="regular", error="", content=b"abc"))
        self.assertEqual(rec.capture_object(str(root / "dir"))["content"], b"a\0b\0")
        self.assertEqual(rec.capture_object(str(root / "fifo"))["kind"], "fifo")
        self.assertIsNone(rec.capture_object(str(root / "absent")))
        for name in ("link", "big"):
            with self.subTest(name=name), self.assertRaises(rec.Refused):
                rec.capture_object(str(root / name))
        encoded = rec.encode_object(value)
        self.assertEqual(replay.blob(encoded["content"]), b"abc")

    def test_inotify_reports_witnessed_and_unwitnessed_events(self):
        root = fresh("watch")
        key = ("h", "state", "", "")
        watcher = rec.Watcher([(key, str(root))])
        try:
            (root / "status").write_bytes(b"x")
            os.rename(root / "status", root / "renamed")
            deadline = time.monotonic() + 5
            while (not any(e["mask"] & rec.IN_MOVED_TO for e in watcher.events)
                   and time.monotonic() < deadline):
                watcher.wait(100_000_000)
                watcher.drain(T0 + 1)
        finally:
            watcher.close()
        masks = [e["mask"] for e in watcher.events]
        self.assertTrue(any(m & rec.IN_CREATE for m in masks) and any(m & rec.IN_MOVED_TO for m in masks))
        captured = [key, ("h", "state", "", "status")]
        problems = rec.unmatched_events(watcher.events, [], captured, T0, T0 + 2)
        self.assertIn("unwitnessed listing change", problems)
        delta = [dict(key=key, listing_delta=["status", "renamed"])]
        content = [dict(key=("h", "state", "", "status"), listing_delta=[])]
        self.assertEqual(rec.unmatched_events(watcher.events, delta + content, captured, T0, T0 + 2), [])
        self.assertTrue(rec.unmatched_events(watcher.events, delta + content, captured, T0 + 5, T0 + 9))
        self.assertTrue(rec.unmatched_events([dict(directory=None, mask=rec.IN_Q_OVERFLOW, name="", at_ns=T0)],
                                             [], captured, T0, T0 + 2))


# Starts the finalizer role the way the controller does, after the guard has
# escalated, and reports the refusal and how the unregistered child ended.
LATE = r"""
import importlib.util, os, sys
cli_path, attempt = sys.argv[1:3]
spec = importlib.util.spec_from_file_location("recorder_cli", cli_path)
cli = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cli)
try:
    cli.started("finalizer", "finalize", attempt, os.path.join(attempt, "trace.json"))
    print("started")
except cli.rec.Refused as error:
    print(error)
print(os.waitstatus_to_exitcode(os.wait()[1]))
"""


class Guard(unittest.TestCase):
    def test_terms_then_kills_only_verified_identities(self):
        polite = subprocess.Popen(["sleep", "30"])
        stubborn = subprocess.Popen([sys.executable, "-c", "import signal,time\n"
                                     "signal.signal(signal.SIGTERM, signal.SIG_IGN)\nprint(1, flush=True)\n"
                                     "time.sleep(30)"], stdout=subprocess.PIPE)
        stubborn.stdout.readline()
        bystander = subprocess.Popen(["sleep", "30"])
        try:
            targets = [dict(role="io", pid=polite.pid, start_ticks=rec.proc_start_ticks(polite.pid)),
                       dict(role="coordinator", pid=stubborn.pid, start_ticks=rec.proc_start_ticks(stubborn.pid)),
                       dict(role="finalizer", pid=bystander.pid, start_ticks=rec.proc_start_ticks(bystander.pid) + 1)]
            started = time.monotonic()
            outcome = rec.escalate(targets, rec.boottime_ns())
            self.assertLess(time.monotonic() - started, 4.5)
            self.assertEqual([o["outcome"] for o in outcome], ["terminated", "killed", "not-ours-or-gone"])
            self.assertEqual(polite.wait(1), -15)
            self.assertEqual(stubborn.wait(1), -9)
            self.assertIsNone(bystander.poll())
        finally:
            for process in (polite, stubborn, bystander):
                if process.poll() is None:
                    process.kill()
                process.wait()

    def test_guard_role_closes_on_eof_and_escalates_at_deadline(self):
        attempt = fresh("guard")
        victim = subprocess.Popen(["sleep", "30"])
        try:
            (attempt / "roles").write_text("io %d %d\n" % (victim.pid, rec.proc_start_ticks(victim.pid)))
            guard = subprocess.Popen([sys.executable, str(CLI), "_guard", str(attempt), str(rec.boottime_ns()),
                                      str(300_000_000)], stdin=subprocess.PIPE)
            self.assertEqual(guard.wait(6), 2)
            self.assertEqual(victim.wait(1), -15)
            outcome = json.loads((attempt / "guard.json").read_text())["outcome"]
            self.assertEqual(outcome[0]["outcome"], "terminated")
            calm = subprocess.Popen([sys.executable, str(CLI), "_guard", str(fresh("guard")), str(rec.boottime_ns()),
                                     str(60_000_000_000)], stdin=subprocess.PIPE)
            calm.stdin.write(b"done\n")
            calm.stdin.close()
            self.assertEqual(calm.wait(5), 0)
        finally:
            if victim.poll() is None:
                victim.kill()
            victim.wait()

    def test_a_role_started_after_escalation_is_refused_not_missed(self):
        attempt = fresh("late")
        guard = subprocess.Popen([sys.executable, str(CLI), "_guard", str(attempt), str(rec.boottime_ns()),
                                  str(200_000_000)], stdin=subprocess.PIPE)
        try:
            self.assertEqual(guard.wait(6), 2)
        finally:
            guard.stdin.close()
        self.assertEqual(json.loads((attempt / "guard.json").read_text())["outcome"], [])
        late = subprocess.run([sys.executable, "-I", "-c", LATE, str(CLI), str(attempt)], stdout=subprocess.PIPE,
                              stderr=subprocess.PIPE, timeout=60)
        self.assertEqual(late.stdout.decode().splitlines(), ["recorder: guard has escalated; role not registered", "2"],
                         late.stderr)
        self.assertIn(b"controller did not register this role", late.stderr)
        self.assertEqual((attempt / "roles").read_text(), "")
        self.assertEqual(sorted(os.listdir(attempt)), ["guard.json", "roles", "roles.sealed"])

    def test_guard_escalates_at_once_when_the_controller_vanishes(self):
        for ending in (b"", b"don", b"stop\n"):
            attempt = fresh("guard")
            victim = subprocess.Popen(["sleep", "30"])
            try:
                (attempt / "roles").write_text("coordinator %d %d\n" % (victim.pid, rec.proc_start_ticks(victim.pid)))
                guard = subprocess.Popen([sys.executable, str(CLI), "_guard", str(attempt), str(rec.boottime_ns()),
                                          str(60_000_000_000)], stdin=subprocess.PIPE)
                guard.stdin.write(ending)
                guard.stdin.close()
                self.assertEqual(guard.wait(10), 2)
                self.assertEqual(victim.wait(1), -15)
                self.assertTrue((attempt / "guard.json").exists())
            finally:
                if victim.poll() is None:
                    victim.kill()
                victim.wait()

    def test_memory_admission_strips_the_bypass(self):
        script = fresh("memguard") / "guard.sh"
        script.write_text('#!/bin/sh\n[ "$*" = "admit --cost-mib 768" ] || exit 9\n'
                          'if env | grep -q "^FM_"; then echo "refuse: seam seen"; exit 1; fi\n'
                          'echo "${FAKE_ANSWER:-admit}"\n')
        script.chmod(0o700)
        seams = dict(FM_MEM_GUARD="off", FM_PROC_ROOT_OVERRIDE="/fake", FM_MEM_GUARD_DIR="/fake",
                     FM_MEM_GUARD_NOW="1", FM_ADMISSION_RULES="/fake/rules.json")
        with patch.dict(os.environ, seams):
            rec.admit_finalizer(str(script))
        with patch.dict(os.environ, {"FAKE_ANSWER": "refuse: memory guard is at red: test"}), \
                self.assertRaisesRegex(rec.Refused, "red: test"):
            rec.admit_finalizer(str(script))


# Runs the coordinator role with decision A's window shortened to 1 s + 0.5 s
# and a 0.2 s flush. The patch exists only in this child; production constants
# and every other process keep the real values.
COORDINATOR = r"""
import importlib.util, sys
mode, cli_path, attempt, prepare_ns, status = sys.argv[1:6]
spec = importlib.util.spec_from_file_location("recorder_cli", cli_path)
cli = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cli)
cli.load_accounting()
rec = cli.rec
rec.WINDOW_NS, rec.REQUEST_LIMIT_NS, rec.FLUSH_NS = 1_000_000_000, 500_000_000, 200_000_000
rec.ACQUISITION_NS = rec.WINDOW_NS + rec.REQUEST_LIMIT_NS
rec.PREPARE_NS = int(prepare_ns)
rec._fallocate_keep_size = lambda fd, size: None
if mode == "early":
    prepare = rec.prepare_bank
    def touched(spool):
        prepare(spool)
        with open(status, "ab") as stream:
            stream.write(b"early\n")
    rec.prepare_bank = touched
try:
    sys.exit(cli.coordinator_role(attempt, rec.boottime_ns()))
except rec.Refused as error:
    print("refused: " + str(error), file=sys.stderr)
    sys.exit(2)
"""


class Coordinator(unittest.TestCase):
    def start(self, mode, prepare_ns=rec.PREPARE_NS):
        attempt, state, private = fresh("coord"), fresh("coord-state"), fresh("coord-enable")
        status, enable = state / "a.status", private / "enable"
        status.write_bytes(b"working\n")
        roots = [dict(home="h", root="state", task="", path=str(state))]
        (attempt / "admission.json").write_text(json.dumps(dict(label="attempt-1", enable_file=str(enable),
                                                                roots=roots)))
        (attempt / "captured.json").write_text(json.dumps([["h", "state", "", ""], ["h", "state", "", "a.status"]]))
        process = subprocess.Popen([sys.executable, "-c", COORDINATOR, mode, str(CLI), str(attempt),
                                    str(prepare_ns), str(status)], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        return process, attempt, status, enable

    def test_enable_window_scans_and_a_witnessed_change(self):
        process, attempt, status, enable = self.start("ok")
        deadline = time.monotonic() + 20
        while not enable.exists() and process.poll() is None and time.monotonic() < deadline:
            time.sleep(0.01)
        status.write_bytes(b"done\n")
        _, err = process.communicate(timeout=60)
        self.assertEqual(process.returncode, 0, err)
        fields = enable.read_bytes().decode("ascii")[:-1].split("\t")
        record = dict(zip(rec.ENABLE_FIELDS, fields))
        self.assertEqual(os.stat(enable).st_mode & 0o777, 0o400)
        self.assertEqual((record["format"], record["epoch"], record["tickets"]), (rec.ENABLE_FORMAT, "attempt-1", "4096"))
        t0_cs = int(record["t0_cs"])
        self.assertEqual([int(record[k]) - t0_cs for k in ("cutoff_cs", "end_cs", "expiry_cs")], [100, 150, 170])
        acquisition = json.loads((attempt / "acquisition.json").read_text())
        self.assertFalse({"initial", "final"} & set(acquisition))
        t0, barrier = acquisition["t0_ns"], acquisition["barrier_ns"]
        self.assertEqual((t0 // 10_000_000, acquisition["enable"]["nonce"]), (t0_cs, record["nonce"]))
        self.assertEqual(acquisition["wall_t0_ns"], int(record["wall_t0_us"]) * 1000)
        self.assertGreaterEqual(barrier, t0 + 1_700_000_000)
        self.assertTrue(any(e["name"] == "a.status" and t0 <= e["at_ns"] <= barrier for e in acquisition["events"]))
        scans = [json.loads((attempt / name).read_text()) for name in ("initial.json", "final.json")]
        self.assertEqual([scan[1]["object"]["content"] for scan in scans], [rec.b64(b"working\n"), rec.b64(b"done\n")])
        self.assertEqual(len(os.listdir(attempt / "spool")), rec.TICKETS)

    def test_slow_preparation_and_a_pre_t0_change_refuse_before_enable(self):
        for mode, prepare_ns, message in (("ok", 0, b"preparation exceeded"), ("early", rec.PREPARE_NS, b"before T0")):
            process, _, _, enable = self.start(mode, prepare_ns)
            _, err = process.communicate(timeout=60)
            self.assertEqual(process.returncode, 2, err)
            self.assertIn(message, err)
            self.assertFalse(enable.exists())


# Runs `run` with only the filesystem screen replaced: CI has no dedicated
# ext4 quota. Every role is a real child with the real constants.
RUN = r"""
import importlib.util, sys
cli_path = sys.argv[1]
spec = importlib.util.spec_from_file_location("recorder_cli", cli_path)
cli = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cli)
cli.rec.check_filesystems = lambda *arguments: None
sys.argv = [cli_path] + sys.argv[2:]
sys.exit(cli.main())
"""


class Run(unittest.TestCase):
    def prepare(self, machine=None, audit_value=None, enable_file=None):
        """An admission the real closure accepts; returns the work and shared enable directories."""
        try:
            with open("/etc/machine-id", encoding="ascii") as stream:
                local = stream.read(64).strip()
        except FileNotFoundError:
            self.skipTest("no /etc/machine-id")
        machine = machine or local
        work = fresh("run")
        shared = work / "shared"
        shared.mkdir()
        shared.chmod(0o770)  # The coordinator refuses a group-writable enable directory after preparing.
        closure = rec.load_closure()
        names = {n for row in closure["rows"] for n in re.findall(r"<([a-z]+)>", row["template"])}
        value = admission(machine=machine, destination=str(work / "attempt"),
                          enable_file=enable_file or str(shared / "enable"))
        for home in value["manifest"]["homes"]:
            home["machine"] = machine
        value["values"] = dict({n: [] for n in names}, t=value["values"]["t"])
        captured = rec.captured_places(rec.admitted_places(closure, value))
        value["projection"]["places"] = [dict(home=h, root=r, task=t, path=p, bytes=0, updates=0)
                                         for h, r, t, p in captured]
        (work / "admission.json").write_text(json.dumps(value))
        (work / "audit.json").write_text(json.dumps(audit_value or rec.audit_code_ref(str(ROOT), HEAD, closure)))
        return work, shared, value

    def run_cli(self, work):
        env = dict(os.environ, FM_SUPERVISION_RECORDER_LIVE="1")
        return subprocess.run([sys.executable, "-c", RUN, str(CLI), "run", str(work / "admission.json"), "--audit",
                               str(work / "audit.json"), "--trace", str(work / "trace.json"), "--acknowledge-enable"],
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=90, env=env)

    def test_refusals_before_any_attempt_evidence(self):
        unsealed = audit(rec.load_closure())  # Sealed and complete, but its blobs are not the code_ref's.
        cases = [("admission names another machine", dict(machine="another-machine")),
                 ("pin audit does not reproduce at code_ref", dict(audit_value=unsealed))]
        for message, changes in cases:
            work, _, _ = self.prepare(**changes)
            self.assertRefused(work, message)
        work, shared, _ = self.prepare()
        (shared / "enable").write_bytes(b"")
        self.assertRefused(work, "enable record already exists")
        inside = admission()["roots"][0]["path"].rstrip("/") + "/enable"
        work, _, _ = self.prepare(enable_file=inside)
        self.assertRefused(work, "enable record inside a root")
        work, shared, _ = self.prepare()
        (work / "alias").symlink_to(shared)  # A parent that resolves elsewhere, as a link into a home's root would.
        (work / "admission.json").write_text(json.dumps(dict(json.loads((work / "admission.json").read_text()),
                                                             enable_file=str(work / "alias" / "enable"))))
        self.assertRefused(work, "enable directory is an alias")
        self.assertFalse((shared / "enable").exists())

    def assertRefused(self, work, message):
        result = self.run_cli(work)
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertIn(message.encode(), result.stderr)
        self.assertFalse((work / "attempt").exists())

    def test_a_failed_coordinator_leaves_the_guard_to_stop_every_role(self):
        work, shared, _ = self.prepare()
        result = self.run_cli(work)
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertIn(b"coordinator failed", result.stderr)
        self.assertNotIn(b"Traceback", result.stderr)
        attempt = work / "attempt"
        roles = [line.split()[0] for line in (attempt / "roles").read_text().splitlines()]
        self.assertEqual(roles[:2], ["coordinator", "io"] if roles[0] == "coordinator" else ["io", "coordinator"])
        outcome = json.loads((attempt / "guard.json").read_text())["outcome"]
        self.assertEqual(sorted(o["role"] for o in outcome), sorted(roles))
        self.assertFalse([o for o in outcome if o["outcome"] == "stuck"])
        for row in outcome:
            fd = rec.verified_pidfd(row["pid"], row["start_ticks"])
            if fd is not None:
                self.assertFalse(rec._alive(fd))
                os.close(fd)
        self.assertFalse((shared / "enable").exists() or (attempt / "published").exists())


class Finalize(unittest.TestCase):
    def test_accepted_subset_binds_and_replays(self):
        world = World()
        world.request("r1")
        world.request("r2", start=T0 + 30_000_000_000, identity=(4243, 99, 1))
        world.change(world.status, T0 + 31_000_000_000, b"done\n", ident="r2", commit="c1")
        world.request("late", start=T0 + 61_000_000_000, identity=(4244, 99, 1))
        world.request("other", caller=DRAIN, identity=(4245, 99, 1))
        world.request("mem", caller=MEM, identity=(4246, 99, 1))
        finalizer, workload, bindings, provenance = world.finalize()
        self.assertEqual(finalizer.losses(), [])
        model = accounting.bound_workload(workload, bindings)
        self.assertEqual([r["id"] for r in workload["requests"]], ["r1", "r2"])
        self.assertEqual(workload["clock"]["monotonic_end_ns"] - workload["clock"]["monotonic_start_ns"],
                         rec.ACQUISITION_NS)
        self.assertEqual(bindings["code_ref"], HEAD)
        self.assertEqual(bindings["admission_sha256"], replay.seal(world.admission))
        self.assertEqual(bindings["requests"][1]["live"]["effects"][0]["commit_id"], "c1")
        clock = bindings["requests"][0]["reads"][1]
        self.assertEqual(clock["start_ns"], T0 + 1_000_003_000)
        self.assertEqual(provenance["selected"], 2)
        self.assertEqual(provenance["late_starts"], 1)
        self.assertEqual(provenance["g5"], "open")
        self.assertFalse(provenance["whole_workload_coverage"])
        self.assertIn(dict(caller=DRAIN, count=1), provenance["excluded_callers"])
        self.assertIn(dict(caller=MEM, count=1), provenance["excluded_callers"])
        self.assertTrue(model.summary())

    def test_appends_and_directory_images_rebuild_full_objects(self):
        world = World()
        world.request("r1")
        world.change(world.status, T0 + 10_000_000_000, b"more\n", op="append",
                     meta=dict(identity="s", kind="regular", mode=0o600))
        listing = (world.home, "state", "", "")
        world.change(listing, T0 + 11_000_000_000, (world.task + ".status\0" + world.task + ".meta\0").encode(),
                     meta=dict(identity="d", kind="directory", mode=0o700), identity=(5152, 7, 1))
        world.final[listing] = world.objects[listing]
        world.events[-1].update(directory=list(listing), name="", mask=rec.IN_ATTRIB)
        finalizer, workload, bindings, _ = world.finalize()
        self.assertEqual(finalizer.losses(), [])
        self.assertEqual(replay.blob(workload["changes"][0]["object"]["content"]), b"working\nmore\n")
        accounting.bound_workload(workload, bindings)

    def assertRefused(self, message, world, **kwargs):
        with self.assertRaisesRegex((rec.Refused, ValueError), message):
            world.finalize(**kwargs)

    def test_selected_request_refusals(self):
        cases = {
            "no end marker": lambda w: w.request(end=0).records.pop(),
            "30 s limit": lambda w: w.request(end=T0 + 1_000_000_000 + rec.REQUEST_LIMIT_NS + 1000),
            "before T0": lambda w: w.request(start=T0 - 1000),
            "unknown caller": lambda w: w.request(caller="bin/fm-watch.sh:1"),
            "caller's substitution": lambda w: w.request(out=b"working\n"),
            "unknown request": lambda w: w.producer((1, 1, 1)).add("read", ["ghost", "p", "read", w.home, "state", "",
                                                                              w.task + ".status", "", "0", "1",
                                                                              us(T0 + 5), us(T0 + 6), ""], [b"w"]),
            "duplicate request": lambda w: (w.request(), w.request(identity=(9, 9, 9))),
        }
        for message, build in cases.items():
            world = World()
            build(world)
            with self.subTest(message=message):
                self.assertRefused(message, world)

    def test_read_and_change_refusals(self):
        world = World()
        producer = world.request()
        producer.records.insert(2, ("read", ["r1", "late", "read", world.home, "state", "", world.task + ".status",
                                             "", "0", "1", us(T0 + 1_000_001_500), us(T0 + 1_000_002_500), ""],
                                    [b"w"]))
        self.assertRefused("concurrent reads", world)
        world = World()
        world.request().records[1][1][6] = world.task + ".secret"
        self.assertRefused("reviewed closure|unadmitted", world)
        world = World()
        world.request().records[1][1][2] = "list"
        self.assertRefused("reviewed closure", world)
        world = World()
        world.request()
        world.change(world.status, T0 - 1000, b"x")
        self.assertRefused("before T0", world)
        world = World()
        world.request()
        world.change((world.home, "state", "", "unlisted"), T0 + 2000, b"x")
        self.assertRefused("unadmitted", world)
        world = World()
        world.request()
        world.change(world.status, T0 + 2000, b"x", op="append")
        world.producers[-1].records[0][1][11] = "1"
        self.assertRefused("append offset", world)
        world = World()
        world.request()
        foreign = copy.deepcopy(CLOSURE)
        foreign["rows"][1]["families"] = ["wake-drain"]
        self.assertRefused("family", world, closure=foreign)

    def test_loss_detectors_refuse_unwitnessed_state(self):
        world = World()
        world.request()
        world.events.append(dict(directory=[world.home, "state", "", ""], mask=rec.IN_MODIFY,
                                 name=world.task + ".meta", at_ns=T0 + 5))
        finalizer = world.finalize()[0]
        self.assertIn("unwitnessed change to admitted place", finalizer.losses())
        world = World()
        world.request()
        world.final[world.meta] = obj(b"hand edit\n", identity="m")
        self.assertIn("final reread differs from the witnessed model", world.finalize()[0].losses())
        world = World()
        world.request()
        world.events.append(dict(directory=None, mask=rec.IN_Q_OVERFLOW, name="", at_ns=T0 + 5))
        self.assertIn("watch loss or root replacement", world.finalize()[0].losses())

    def test_provenance_and_clock_refusals(self):
        world = World()
        world.request()
        self.assertRefused("code_ref", world, audit_value=audit(code_ref="3" * 40))
        world = World()
        world.request()
        tampered = audit()
        tampered["read_sites"] = ["x"]
        self.assertRefused("pin audit", world, audit_value=tampered)
        for field in ("caller_sites", "read_sites", "blobs"):
            world = World()
            world.request()
            subset = audit()
            subset[field] = {} if field == "blobs" else subset[field][1:]
            del subset["sha256"]
            subset["sha256"] = replay.seal(subset)
            self.assertRefused("every caller and read pin", world, audit_value=subset)
        world = World()
        world.request()
        self.assertRefused("stepped", world, offset_end_ns=WALL - T0 + rec.CLOCK_DRIFT_NS + 1)
        world = World()
        world.request()
        self.assertRefused("barrier", world, barrier_ns=T0 + rec.ACQUISITION_NS - 1)
        world = World()
        world.request()
        self.assertRefused("generation", world, enable_nonce="b" * 32)
        world = World()
        world.request()
        initial = world.acquisition()["initial"][1:]
        self.assertRefused("initial scan", world, initial=initial)

    def test_v3_binder_rejects_a_mismatched_live_or_read(self):
        world = World()
        world.request()
        _, workload, bindings, _ = world.finalize()
        broken = copy.deepcopy(bindings)
        broken["requests"][0]["reads"][0]["result"] = blob(b"tampered")
        v3.reseal(broken)
        with self.assertRaises((ValueError, accounting.Refused)):
            accounting.bound_workload(workload, broken)


# Runs the admitted `finalize` verb with only the memory guard and the read
# closure replaced; its spawned `_finalize` role reruns this same script.
FINALIZE = r"""
import importlib.util, json, os, subprocess, sys
script, cli_path = os.path.abspath(sys.argv[0]), sys.argv[1]
spec = importlib.util.spec_from_file_location("recorder_cli", cli_path)
cli = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cli)
with open(os.environ["RECORDER_TEST_CLOSURE"], encoding="utf-8") as stream:
    closure = json.load(stream)
cli.rec.load_closure = lambda path=None: closure
def admit(guard):
    if os.environ.get("RECORDER_TEST_REFUSE"):
        raise cli.rec.Refused("memory guard refused the finalizer: test")
cli.rec.admit_finalizer = admit
def spawn(role, *arguments, stdin=None, stdout=None, prefix=()):
    return subprocess.Popen(list(prefix) + [sys.executable, "-I", script, cli_path, "_" + role]
                            + [str(a) for a in arguments], stdin=stdin, stdout=stdout, close_fds=True)
cli.spawn = spawn
sys.argv = [cli_path] + sys.argv[2:]
sys.exit(cli.main())
"""


class FinalizeVerb(unittest.TestCase):
    def attempt(self, world, embed=False):
        work = fresh("finalize")
        attempt = work / "attempt"
        attempt.mkdir(mode=0o700)
        world.admission["enable_file"] = str(work / "enable")
        rec.write_enable(world.admission["enable_file"], world.enable)
        for producer in world.producers:
            producer.write()
        acquisition = world.acquisition()
        for name in ("initial", "final"):
            (attempt / (name + ".json")).write_text(json.dumps(acquisition[name] if embed else acquisition.pop(name)))
        receipt = rec.audit_code_ref(str(ROOT), HEAD, CLOSURE)
        for name, value in (("admission", world.admission), ("pin-audit", receipt), ("acquisition", acquisition)):
            (attempt / (name + ".json")).write_text(json.dumps(value))
        (work / "trace.json").write_text(json.dumps(world.trace()))
        (work / "closure.json").write_text(json.dumps(CLOSURE))
        (work / "finalize.py").write_text(FINALIZE)
        return work, attempt

    def finalize(self, work, attempt, good=True, **env):
        result = subprocess.run([sys.executable, str(work / "finalize.py"), str(CLI), "finalize", str(attempt),
                                 "--trace", str(work / "trace.json")], stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                timeout=60, env=dict(os.environ, RECORDER_TEST_CLOSURE=str(work / "closure.json"),
                                                     **env))
        self.assertEqual(result.returncode, 0 if good else 2, result.stderr)
        return result

    def test_the_admitted_role_publishes_from_retained_evidence(self):
        world = World()
        world.request("r1")
        work, attempt = self.attempt(world)
        result = json.loads(self.finalize(work, attempt).stdout)
        published = attempt / "published"
        self.assertEqual((result["published"], result["selected"]), (str(published), 1))
        self.assertEqual(sorted(os.listdir(published)), ["bindings.json", "provenance.json", "workload.json"])
        self.assertFalse((attempt / ".published").exists())
        workload = json.loads((published / "workload.json").read_text())
        bindings = json.loads((published / "bindings.json").read_text())
        self.assertEqual((workload["sha256"], bindings["sha256"]), (result["workload_sha256"], result["bindings_sha256"]))
        self.assertEqual([r["id"] for r in workload["requests"]], ["r1"])
        accounting.bound_workload(workload, bindings)
        self.assertEqual([line.split()[0] for line in (attempt / "roles").read_text().splitlines()], ["finalizer"])

    def test_a_forged_receipt_or_a_memory_refusal_stops_before_the_role(self):
        world = World()
        world.request("r1")
        work, attempt = self.attempt(world)
        result = self.finalize(work, attempt, good=False, RECORDER_TEST_REFUSE="1")
        self.assertIn(b"memory guard refused the finalizer: test", result.stderr)
        (attempt / "pin-audit.json").write_text(json.dumps(audit()))  # Sealed and complete, wrong blobs.
        result = self.finalize(work, attempt, good=False)
        self.assertIn(b"pin audit does not reproduce at code_ref", result.stderr)
        self.assertEqual(sorted(os.listdir(attempt)), ["acquisition.json", "admission.json", "final.json",
                                                       "initial.json", "pin-audit.json"])

    def test_the_role_refuses_an_embedded_scan_or_a_changed_enable_record(self):
        world = World()
        world.request("r1")
        work, attempt = self.attempt(world, embed=True)
        result = self.finalize(work, attempt, good=False)
        self.assertIn(b"acquisition record embeds a scan", result.stderr)
        self.assertIn(b"finalizer refused; attempt evidence retained", result.stderr)
        world = World()
        world.request("r1")
        work, attempt = self.attempt(world)
        os.unlink(world.admission["enable_file"])
        rec.write_enable(world.admission["enable_file"], dict(world.enable, nonce="b" * 32))
        result = self.finalize(work, attempt, good=False)
        self.assertIn(b"enable record changed", result.stderr)
        for evidence in (attempt / ".published", attempt / "published"):
            self.assertFalse(evidence.exists())


class Cli(unittest.TestCase):
    def run_cli(self, *arguments, env=None, good=True):
        result = subprocess.run([sys.executable, str(CLI)] + [str(a) for a in arguments], stdout=subprocess.PIPE,
                                stderr=subprocess.PIPE, timeout=60, env=env)
        self.assertEqual(result.returncode, 0 if good else 2, result.stderr)
        if not good:
            self.assertIn(b"refused:", result.stderr)
            self.assertNotIn(b"Traceback", result.stderr)
        return result

    def test_audit_writes_a_sealed_receipt_once(self):
        output = fresh("cli") / "audit.json"
        result = json.loads(self.run_cli("audit", "--repo", ROOT, "--code-ref", HEAD, "--output", output).stdout)
        receipt = json.loads(output.read_text())
        self.assertEqual((result["code_ref"], result["sha256"]), (HEAD, receipt["sha256"]))
        self.assertEqual(os.stat(output).st_mode & 0o777, 0o600)
        self.run_cli("audit", "--repo", ROOT, "--code-ref", HEAD, "--output", output, good=False)
        self.run_cli("audit", "--repo", ROOT, "--code-ref", "f" * 40, "--output", output.with_name("x"), good=False)

    def test_run_needs_both_explicit_live_gates(self):
        directory = fresh("cli")
        path = directory / "admission.json"
        path.write_text(json.dumps(admission()))
        env = {k: v for k, v in os.environ.items() if k != "FM_SUPERVISION_RECORDER_LIVE"}
        self.assertIn(b"FM_SUPERVISION_RECORDER_LIVE=1", self.run_cli(
            "run", path, "--audit", path, "--trace", path, "--acknowledge-enable", env=env, good=False).stderr)
        env["FM_SUPERVISION_RECORDER_LIVE"] = "1"
        self.assertIn(b"--acknowledge-enable", self.run_cli(
            "run", path, "--audit", path, "--trace", path, env=env, good=False).stderr)
        self.assertFalse(os.path.exists("/captures"))

    def test_io_role_streams_one_exclusive_scan_per_request(self):
        attempt, state = fresh("io"), fresh("io-state")
        (state / "a.status").write_bytes(b"working\n")
        os.mkdir(state / "sub")
        roots = [dict(home="h", root="state", task="", path=str(state))]
        (attempt / "admission.json").write_text(json.dumps(dict(roots=roots)))
        keys = [["h", "state", "", ""], ["h", "state", "", "a.status"], ["h", "state", "", "gone"]]
        (attempt / "captured.json").write_text(json.dumps(keys))
        io = subprocess.run([sys.executable, str(CLI), "_io", str(attempt)], input=b"initial\n",
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=30)
        self.assertEqual((io.returncode, io.stdout), (0, b"initial\n"), io.stderr)
        rows = json.loads((attempt / "initial.json").read_text())
        self.assertEqual([row["key"] for row in rows], keys)
        self.assertEqual(rows[1]["object"], rec.encode_object(rec.capture_object(str(state / "a.status"))))
        self.assertEqual((rows[0]["object"]["kind"], rows[2]["object"]), ("directory", None))
        self.assertEqual(os.stat(attempt / "initial.json").st_mode & 0o777, 0o600)
        again = subprocess.run([sys.executable, str(CLI), "_io", str(attempt)], input=b"initial\n",
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=30)
        self.assertEqual(again.returncode, 2)
        self.assertIn(b"refused:", again.stderr)

    def test_roles_never_act_before_the_controller_registers_them(self):
        attempt = fresh("unregistered")
        for role in (["_coordinator", str(attempt), "0"], ["_finalize", str(attempt), str(attempt / "trace.json")]):
            result = subprocess.run([sys.executable, str(CLI)] + role, input=b"", stdout=subprocess.PIPE,
                                    stderr=subprocess.PIPE, timeout=60)
            self.assertEqual(result.returncode, 2, result.stderr)
            self.assertIn(b"controller did not register this role", result.stderr)
        self.assertEqual(os.listdir(attempt), [])

    def test_private_roles_reject_unknown_names(self):
        self.run_cli("_unknown", good=False)


if __name__ == "__main__":
    unittest.main(verbosity=2)
