"""CI-only real foreground lifecycle fixtures. No installed/live home is used."""
import copy
import errno
import json
import os
from pathlib import Path
import selectors
import signal
import socket
import subprocess
import sys
import threading
import time
import unittest
from unittest.mock import patch

from bundle_checks import BundlePreparation
from fm_view_bundle import packed
from fm_view_capabilities import inspect
from fm_view_engine import client
from fm_view_journal import LifecycleJournal, preview_intake
from fm_view_lifecycle import LIMIT, candidate
from fm_view_lock import ServiceSingleton
from fm_view_process import process_generation
import fm_view_service as service

# Test-only process wrapper: immutable bytes remain unchanged. It exercises the
# actual public CLI in the selected bundle, not a substitute lifecycle owner.
DRIVER = r'''
import json,os,runpy,signal,socket,sys,threading
from pathlib import Path
from unittest.mock import patch

tool,mode=sys.argv[1:3]
sys.path.insert(0,str(Path(tool).parent))
import fm_view_service as owner
from fm_view_journal import LifecycleJournal
import fm_view_journal as journal
real_execute=owner.execute
real_run=owner.run
real_require=owner.require
skipped={"capability-counterfactual":"fresh read capabilities differ from request",
         "actor-failure-counterfactual":"declared lifecycle actor admission refused",
         "receipt-fresh-counterfactual":"lifecycle effect lacks current accepted receipt"}
if mode in skipped:
    owner.require=lambda value,message:None if message==skipped[mode] else real_require(value,message)
if mode=="ambiguous-replay-counterfactual":
    owner.require=lambda value,message:None if message.startswith("ambiguous prior acceptance;") else real_require(value,message)
if mode=="start-order-counterfactual":
    owner.Operation.acquire_start=lambda self:None
if mode=="actual-exit-counterfactual":
    owner.ProcessPin.wait_exit=lambda self,timeout:None
if mode=="thread-lifetime-counterfactual":
    owner.Operation.close=lambda self:self.singleton.close() if self.singleton is not None else None
if mode.startswith("intake-swap"):
    preview=owner.preview_intake
    def swapped(home,fragment,filename):
        selected=preview(home,fragment,filename)
        changed=dict(selected[0],operation="start",expected_owner=None)
        target=Path(fragment["protocols"][0]["stages"][0]["input"]["path"])/filename
        target.write_bytes(owner.packed(changed));target.chmod(0o600)
        return selected
    owner.preview_intake=swapped
    if mode=="intake-swap-counterfactual":
        check=journal.require
        journal.require=lambda value,message:None if message=="lifecycle intake changed before admission" else check(value,message)
if mode.startswith("actor-failure"):
    from fm_view_process import Observation
    owner.run=lambda *args,**kwargs:Observation(tuple(args[0]),1,b"",b"",0,1,"fixture actor refusal")
real_bind=socket.socket.bind
real_remove=owner.Runtime.remove
real_publish=LifecycleJournal._publish

def execute(operation,emit):
    def output(value):
        if value.get("ready"):
            if mode=="ignored-term": signal.signal(signal.SIGTERM,signal.SIG_IGN)
            if mode.startswith("thread"):
                threading.Thread(target=lambda:sys.stdin.buffer.read(1),daemon=False).start()
        emit(value)
    return real_execute(operation,output)
owner.execute=execute

def bind(sock,path):
    # Actual bind witnesses acceptance DURABLY BEFORE the first socket effect.
    # Every other check remains real; no source-byte inspection is used.
    home=Path(sys.argv[sys.argv.index("--home")+1])
    receipts=[json.loads(p.read_bytes()) for p in (home/"state/receipts").glob("*.json")]
    assert receipts and receipts[-1]["state"]=="accepted", "bind before accepted receipt"
    assert (home/"state/runtime/capabilities.json").is_file(), "bind before capabilities"
    if mode=="bind-failure": raise OSError(5,"fixture bind failure")
    return real_bind(sock,path)
socket.socket.bind=bind

def publish(self,value,count,total):
    if mode=="receipt-fresh-counterfactual": return value
    if mode=="receipt-failure": raise OSError(5,"fixture receipt fsync refusal")
    return real_publish(self,value,count,total)
LifecycleJournal._publish=publish

def remove(self,name,identity,expected=None):
    if mode=="cleanup-replacement":
        p=self.pinned(name)
        if p.exists() or p.is_socket(): p.rename(p.with_name("retained-"+name))
        p.write_bytes(b"replacement must survive\n");p.chmod(0o600)
    return real_remove(self,name,identity,expected)
owner.Runtime.remove=remove
sys.argv=[tool,*sys.argv[3:]]
runpy.run_path(tool,run_name="__main__")
'''


@unittest.skipUnless(sys.platform == "linux", "native foreground owner is Linux-only")
class ForegroundService(unittest.TestCase):
    setUpClass = classmethod(BundlePreparation.setUpClass.__func__)
    git = BundlePreparation.git
    command = BundlePreparation.command
    prepare = BundlePreparation.prepare
    prepared = BundlePreparation.prepared

    def setUp(self):
        BundlePreparation.setUp(self)
        self.bundle = self.prepared()
        self.tool = self.bundle / "bin/fm-view-service.py"
        self.state = self.home / "state"
        self.runtime = self.state / "runtime"
        self.inbox = self.state / "requests"
        self.outbox = self.state / "receipts"
        self.registry = self.state / "handoff-registry"
        for folder in (self.runtime, self.inbox, self.outbox, self.registry): folder.mkdir(mode=0o700)
        (self.outbox / ".tmp").mkdir(mode=0o700)
        policy = {"bounds": {"accepted": "1m", "waiting": "1m", "held": "1m"}, "retry_limit": 0,
                  "cleanup": {"stage": "lifecycle", "receipts_after": "7d", "records_after": "7d"}}
        self.fragment = candidate(self.home, "main", self.inbox, self.outbox, policy)
        self.fragment["protocols"][0]["stages"][0]["planned"] = False
        self.fragment_path = self.registry / "read.json"
        self.file(self.fragment_path, self.fragment)
        self.capability = inspect(self.bundle, self.bundle.name, self.home)
        self.request = {"schema": "fm-view-lifecycle.v1", "version": 1, "record": "start-a", "attempt": 1,
                        "home": str(self.home), "owner": "main", "operation": "start", "epoch": "epoch-a",
                        "roots": self.roots(), "runtime": str(self.runtime),
                        "bundle": {"path": str(self.bundle), "identity": self.bundle.name}, "workers": 2,
                        "timeout_ms": 15000, "expected_owner": None, "capabilities": service.fingerprint(self.capability)}
        self.file(self.inbox / "start-a.1.json", self.request)
        for name, raw in (("task.meta", b"kind=ship\nspawn_gen=one\n"),
                          ("task.status", b"needs-decision [key=x]: choose\n"),
                          (".wake-queue", b"unchanged queue\n"), (".lease-task", b"unchanged custody\n")):
            self.file(self.state / name, raw)
        self.protected = {p.name: p.read_bytes() for p in self.state.iterdir() if p.is_file()}
        self.children = []
        self.addCleanup(self.retire_children)

    def file(self, path, value):
        path.write_bytes(value if type(value) is bytes else packed(value)); path.chmod(0o600)
        return path

    def roots(self, runtime=None):
        return {name: [p.stat().st_dev, p.stat().st_ino] for name,p in
                (("home",self.home),("state",self.state),("runtime",runtime or self.runtime))}

    def args(self, filename, mode=None):
        prefix = [sys.executable, "-I", "-B"]
        prefix += ["-c", DRIVER, str(self.tool), mode] if mode else [str(self.tool)]
        return [*prefix, "--home", str(self.home), "--fragment", str(self.fragment_path), "--input", filename]

    def spawn(self, filename="start-a.1.json", mode=None):
        process = subprocess.Popen(self.args(filename, mode), env=self.environment, stdin=subprocess.PIPE,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.children.append(process)
        return process

    def retire_children(self):
        # Only direct fixture-owned children; no backend, pool or live home.
        for process in self.children:
            if process.poll() is None:
                process.send_signal(signal.SIGCONT)
                try:
                    process.stdin.write(b"x"); process.stdin.flush()
                except (OSError, ValueError): pass
                process.terminate()
                try: process.wait(timeout=5)
                except subprocess.TimeoutExpired: process.kill(); process.wait(timeout=5)
            for stream in (process.stdin, process.stdout, process.stderr): stream.close()

    def line(self, process):
        with selectors.DefaultSelector() as selector:
            selector.register(process.stdout, selectors.EVENT_READ)
            self.assertTrue(selector.select(40), "foreground result did not arrive")
        raw = process.stdout.readline()
        self.assertTrue(raw, process.stderr.read() if process.poll() is not None else "no foreground output")
        return json.loads(raw)

    def ready(self, mode=None):
        process = self.spawn(mode=mode)
        value = self.line(process)
        self.assertEqual(value["schema"], service.RESULT)
        self.assertTrue(value["ready"], value)
        owner = value["owner"]
        self.assertEqual(owner["process"]["pid"], process.pid)
        self.assertEqual(json.loads((self.runtime / "owner.json").read_bytes()), owner)
        self.assertEqual(json.loads((self.runtime / "capabilities.json").read_bytes()), self.capability)
        self.assert_protected()
        return process, owner

    def assert_protected(self):
        self.assertEqual(self.protected, {name:(self.state/name).read_bytes() for name in self.protected})
        self.assertFalse((self.state / ".last-watcher-beat").exists())
        self.assertFalse((self.state / ".view-mode").exists())

    def invoke(self, filename, mode=None):
        return subprocess.run(self.args(filename, mode), env=self.environment, capture_output=True, timeout=45)

    def stop_input(self, owner, record="stop-a", timeout=15000):
        value = copy.deepcopy(self.request)
        value.update(operation="stop", expected_owner=owner, record=record, timeout_ms=timeout)
        for key in ("home", "roots", "runtime", "bundle", "epoch", "capabilities"): value[key]=copy.deepcopy(owner[key])
        filename = record + ".1.json"
        self.file(self.inbox / filename, value)
        return filename

    def stop(self, process, owner):
        result = self.invoke(self.stop_input(owner))
        self.assertEqual((result.returncode, result.stderr), (0,b""), result.stdout)
        output = json.loads(result.stdout)
        self.assertTrue(output["exited"])
        self.assertEqual(output["receipt"]["state"], "done")
        process.wait(timeout=5)
        self.assertEqual(process.returncode, 0, process.stderr.read())
        return output

    def journal_snapshot(self):
        return {p.name:(p.lstat().st_ino,p.lstat().st_mode,p.read_bytes())
                for p in self.outbox.iterdir() if p.is_file()}

    def assert_competing_start(self, mode=None):
        process,owner=self.ready()
        other=self.state/"runtime-b";other.mkdir(mode=0o700)
        value=copy.deepcopy(self.request)
        value.update(record="start-b",epoch="epoch-b",runtime=str(other),roots=self.roots(other))
        self.file(self.inbox/"start-b.1.json",value)
        before=self.journal_snapshot()
        anchor=self.state/".view-service.lock"
        original=(anchor.stat().st_ino,anchor.read_bytes())
        result=self.invoke("start-b.1.json",mode)
        self.assertNotEqual(result.returncode,0,result.stdout)
        self.assertEqual(result.stdout,b"")
        self.assertEqual(self.journal_snapshot(),before,"competing start changed journal before singleton admission")
        self.assertEqual(list(other.iterdir()),[])
        self.assertEqual((anchor.stat().st_ino,anchor.read_bytes()),original)
        self.assertIsNone(process.poll())
        self.assertEqual(json.loads((self.runtime/"owner.json").read_bytes()),owner)
        self.assertIn("choose",json.dumps(client(str(self.runtime/"read.sock"),str(self.home),"epoch-a",
                                                "status-fold",{"task":"task"})))
        self.assert_protected()
        self.stop(process,owner)
        with ServiceSingleton(self.home,other,self.roots(other)): pass

    def test_contended_first_start_never_creates_a_journal_anchor(self):
        def oracle(mode=None):
            with ServiceSingleton(self.home,self.runtime,self.roots()):
                result=self.invoke("start-a.1.json",mode)
                self.assertNotEqual(result.returncode,0)
                self.assertEqual(result.stdout,b"")
                self.assertFalse((self.outbox/".lifecycle-journal.lock").exists(),
                                 "contended start created journal before admission")
                self.assertEqual(list(self.outbox.glob("*.json")),[])
                self.assertEqual(list(self.runtime.iterdir()),[])
        oracle()
        with self.assertRaisesRegex(AssertionError,"contended start created journal before admission"):
            oracle("start-order-counterfactual")
        self.assert_protected()

    def test_contended_start_has_no_journal_anchor_receipt_or_runtime_effect(self):
        self.assert_competing_start()

    def test_competing_start_order_counterfactual_fails_the_same_no_write_oracle(self):
        with self.assertRaisesRegex(AssertionError,"competing start changed journal"):
            self.assert_competing_start("start-order-counterfactual")

    def assert_ambiguous_replay(self, filename, mode=None):
        before=self.journal_snapshot()
        result=self.invoke(filename,mode)
        self.assertNotEqual(result.returncode,0,"ambiguous replay must not exit successfully")
        self.assertEqual(result.stdout,b"")
        self.assertIn(b"ambiguous prior acceptance",result.stderr)
        self.assertEqual(self.journal_snapshot(),before,"replay rewrote ambiguous receipt history")
        self.assert_protected()

    def test_public_start_acceptance_without_completion_is_ambiguous(self):
        # Fixture seeds the exact crash-after-acceptance boundary without an
        # effect; its initial start journal obeys the same singleton ordering.
        with ServiceSingleton(self.home,self.runtime,self.roots()), LifecycleJournal(self.home,self.fragment) as transaction:
            value=transaction.admit("start-a.1.json")
        self.assertTrue(value["fresh"])
        self.assertEqual(value["receipt"]["state"],"accepted")
        self.assert_ambiguous_replay("start-a.1.json")
        self.assertEqual(list(self.runtime.iterdir()),[])
        with self.assertRaisesRegex(AssertionError,"ambiguous replay must not exit successfully"):
            self.assert_ambiguous_replay("start-a.1.json","ambiguous-replay-counterfactual")
        self.assertEqual(list(self.runtime.iterdir()),[])
        with ServiceSingleton(self.home,self.runtime,self.roots()): pass

    def test_public_stop_ambiguity_never_takes_live_singleton_and_done_replay_is_historical(self):
        process,owner=self.ready()
        filename=self.stop_input(owner,"stop-ambiguous")
        # Stop intake MUST remain usable while the start owner holds admission.
        with LifecycleJournal(self.home,self.fragment) as transaction:
            accepted=transaction.admit(filename)
        self.assertTrue(accepted["fresh"])
        self.assert_ambiguous_replay(filename)
        with self.assertRaisesRegex(AssertionError,"ambiguous replay must not exit successfully"):
            self.assert_ambiguous_replay(filename,"ambiguous-replay-counterfactual")
        self.assertIsNone(process.poll())
        self.stop(process,owner)
        before=self.journal_snapshot()
        replay=self.invoke("stop-a.1.json")
        self.assertEqual((replay.returncode,replay.stderr),(0,b""),replay.stdout)
        output=json.loads(replay.stdout)
        self.assertFalse(output["fresh"])
        self.assertEqual(output["receipt"]["state"],"done")
        self.assertNotIn("ready",output);self.assertNotIn("exited",output)
        self.assertEqual(self.journal_snapshot(),before)

    def assert_changed_operation_refuses(self, mode):
        process,owner=self.ready()
        filename=self.stop_input(owner,"stop-swap")
        before=self.journal_snapshot()
        result=self.invoke(filename,mode)
        self.assertNotEqual(result.returncode,0,"changed intake must not be admitted successfully")
        self.assertIn(b"lifecycle intake changed before admission",result.stderr)
        self.assertEqual(self.journal_snapshot(),before)
        self.assertIsNone(process.poll())
        self.assert_protected()
        self.stop(process,owner)

    def test_preliminary_intake_shares_locked_grammar_without_journal_writes(self):
        name="start-a.1.json";target=self.inbox/name
        unknown=dict(self.request,version=2)
        cases={"valid":packed(self.request),"empty":b"","white":b" \t\n","nul":b"{}\0\n",
               "partial":packed(self.request)[:-1],"unknown":packed(unknown),"oversized":b"x"*(LIMIT+1)}
        for shape in (*cases,"missing","directory","fifo","dangling","mode000"):
            with self.subTest(shape=shape):
                target.unlink(missing_ok=True)
                if shape in cases: self.file(target,cases[shape])
                elif shape=="directory": target.mkdir()
                elif shape=="fifo": os.mkfifo(target)
                elif shape=="dangling": target.symlink_to(self.root/"absent")
                elif shape=="mode000": self.file(target,packed(self.request));target.chmod(0)
                before=self.journal_snapshot()
                try:
                    selected=preview_intake(self.home,self.fragment,name)
                    self.assertEqual(self.journal_snapshot(),before,"preview wrote a journal object")
                    # This is a reader-only comparison; no decision is admitted.
                    with ServiceSingleton(self.home,self.runtime,self.roots()), LifecycleJournal(self.home,self.fragment) as transaction:
                        self.assertEqual(transaction.intake(name),selected)
                    self.assertEqual(list(self.outbox.glob("*.json")),[])
                    self.assertEqual(selected[1],None if shape=="valid" else
                                     ("version-unsupported" if shape=="unknown" else "input-invalid"))
                    self.assertEqual(list(self.runtime.iterdir()),[])
                finally:
                    if shape=="directory": target.rmdir()
                    elif os.path.lexists(target): target.unlink()
        self.assert_protected()

    def test_locked_intake_fence_refuses_stop_replacement_by_start(self):
        self.assert_changed_operation_refuses("intake-swap")

    def test_locked_intake_guard_counterfactual_fails_the_same_refusal_oracle(self):
        with self.assertRaisesRegex(AssertionError,"changed intake must not be admitted successfully"):
            self.assert_changed_operation_refuses("intake-swap-counterfactual")

    def test_real_foreground_client_stop_receipts_and_unchanged_transaction_bytes(self):
        process, owner = self.ready()
        result = client(str(self.runtime/"read.sock"),str(self.home),"epoch-a","status-fold",{"task":"task"})
        self.assertIn("choose",json.dumps(result))
        with self.assertRaises(BlockingIOError): ServiceSingleton(self.home,self.runtime,self.roots())
        output = self.stop(process,owner)
        self.assertFalse((self.runtime/"read.sock").exists())
        self.assertFalse((self.runtime/"owner.json").exists())
        self.assertTrue((self.runtime/"capabilities.json").is_file())
        tail = self.line(process)
        self.assertEqual((tail["event"],tail["exited"]),("foreground-return",False))
        self.assert_protected()
        # Public receipt validation, not only this implementation's reader.
        for receipt in self.outbox.glob("*.json"):
            result = subprocess.run([sys.executable,str(self.bundle/"bin/fm-handoff-validate.py"),"receipt",
                                     "--fragment",str(self.fragment_path),str(receipt)],capture_output=True,timeout=10)
            self.assertEqual(result.returncode,0,result.stdout+result.stderr)
        replay = self.invoke("start-a.1.json")
        self.assertEqual(replay.returncode,0,replay.stderr)
        self.assertFalse(json.loads(replay.stdout)["fresh"])
        self.assertNotIn("ready",json.loads(replay.stdout))
        self.assertTrue(output["fresh"])

    def test_healthy_empty_home_is_a_successful_empty_observation(self):
        for name in ("task.meta", "task.status"):
            (self.state/name).unlink(); self.protected.pop(name)
        process,owner=self.ready()
        result=client(str(self.runtime/"read.sock"),str(self.home),"epoch-a","status-fold",{"task":"absent"})
        self.assertIsNone(result["status"])
        self.assertEqual(result["generation"],"")
        self.stop(process,owner)
        self.assert_protected()

    def test_private_runtime_modes_and_nonregular_roots_refuse_before_creation(self):
        for mode in (0o755,0o000):
            self.runtime.chmod(mode)
            try:
                with self.assertRaises(ValueError): service.Runtime(self.request)
            finally: self.runtime.chmod(0o700)
        retained=self.state/"retained-unsafe-runtime"
        self.runtime.rename(retained)
        try:
            for shape in ("fifo","symlink","dangling"):
                with self.subTest(shape=shape):
                    if shape=="fifo": os.mkfifo(self.runtime)
                    else: self.runtime.symlink_to(retained if shape=="symlink" else self.state/"absent")
                    try:
                        with self.assertRaises((OSError,ValueError)): service.Runtime(self.request)
                    finally: self.runtime.unlink()
            self.assertEqual(list(retained.iterdir()),[])
        finally: retained.rename(self.runtime)
        self.assert_protected()

    def test_shared_actor_refusal_precedes_journal_and_runtime_effects(self):
        result = self.invoke("start-a.1.json", "actor-failure")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(b"declared lifecycle actor admission refused", result.stderr)
        self.assertEqual(list(self.runtime.iterdir()), [])
        self.assertEqual(list(self.outbox.glob("*.json")), [])
        self.assertFalse((self.outbox / ".lifecycle-journal.lock").exists())
        self.assert_protected()

    def test_independent_capability_actor_and_receipt_guard_counterfactuals(self):
        # Each fixture satisfies every other gate. Revert one refusal only;
        # the SAME observable safety oracle must now fail, never another guard.
        for mode in ("capability-counterfactual", "actor-failure-counterfactual", "receipt-fresh-counterfactual"):
            with self.subTest(mode=mode):
                fixture=ForegroundService(methodName="runTest");fixture.setUp()
                try:
                    if mode=="capability-counterfactual":
                        fixture.request["capabilities"]="0"*64
                        fixture.file(fixture.inbox/"start-a.1.json",fixture.request)
                    if mode=="receipt-fresh-counterfactual":
                        result=fixture.invoke("start-a.1.json",mode)
                        # The real bind witness detects omission of the fresh
                        # durable-acceptance gate before any actual socket bind.
                        self.assertNotEqual(result.returncode,0)
                        self.assertIn(b"bind before accepted receipt",result.stderr)
                        self.assertFalse((fixture.runtime/"read.sock").exists())
                    else:
                        process,owner=fixture.ready(mode)
                        self.assertIsNone(process.poll())
                        def refusal_oracle():
                            self.assertFalse((fixture.runtime/"read.sock").exists(),"guard allowed listener")
                        with self.assertRaisesRegex(AssertionError,"guard allowed listener"): refusal_oracle()
                finally: fixture.doCleanups()

    def test_receipt_failure_prevents_all_runtime_effects(self):
        result = self.invoke("start-a.1.json","receipt-failure")
        self.assertNotEqual(result.returncode,0)
        self.assertIn(b"fixture receipt fsync refusal",result.stderr)
        self.assertEqual(list(self.runtime.iterdir()),[])
        self.assertEqual(list(self.outbox.glob("*.json")),[])
        self.assert_protected()

    def test_bind_witnesses_durable_receipt_and_failed_bind_is_not_done(self):
        result = self.invoke("start-a.1.json","bind-failure")
        self.assertNotEqual(result.returncode,0)
        self.assertIn(b"fixture bind failure",result.stderr)
        self.assertNotIn(b"bind before",result.stderr)
        receipts=sorted((json.loads(p.read_bytes()) for p in self.outbox.glob("*.json")),key=lambda v:v["seq"])
        self.assertEqual([(r["state"],r.get("code")) for r in receipts],[("accepted",None),("refused","effect-failed")])
        self.assertFalse((self.runtime/"read.sock").exists())
        replay=self.invoke("start-a.1.json")
        self.assertNotEqual(replay.returncode,0)
        self.assertFalse(json.loads(replay.stdout)["fresh"])
        self.assert_protected()

    def test_declared_published_contract_and_immutable_execution_are_required(self):
        self.fragment["protocols"][0]["stages"][0]["planned"]=True
        self.file(self.fragment_path,self.fragment)
        result=self.invoke("start-a.1.json")
        self.assertNotEqual(result.returncode,0)
        self.assertIn(b"planned lifecycle actor",result.stderr)
        self.assertEqual(list(self.outbox.glob("*.json")),[])
        self.assertEqual(list(self.runtime.iterdir()),[])
        self.fragment["protocols"][0]["stages"][0]["planned"]=False
        self.file(self.fragment_path,self.fragment)
        result=subprocess.run([sys.executable,"-I","-B",str(Path(service.__file__).with_name("fm-view-service.py")),
                               "--home",str(self.home),"--fragment",str(self.fragment_path),"--input","start-a.1.json"],
                              env=self.environment,capture_output=True,timeout=10)
        self.assertNotEqual(result.returncode,0)
        self.assertEqual(result.stdout,b"")
        self.assertEqual(list(self.outbox.glob("*.json")),[])

    def test_start_refuses_capability_and_root_changes_without_socket_effects(self):
        for key in ("capabilities","home","state","runtime"):
            with self.subTest(key=key):
                value=copy.deepcopy(self.request);value["record"]="bad-"+key
                if key=="capabilities": value[key]="0"*64
                else: value["roots"][key][1]+=1
                name=value["record"]+".1.json";self.file(self.inbox/name,value)
                result=self.invoke(name)
                self.assertNotEqual(result.returncode,0,result.stdout)
                self.assertFalse((self.runtime/"read.sock").exists())
                self.assertFalse((self.runtime/"owner.json").exists())
                self.assert_protected()
        process,owner=self.ready();self.stop(process,owner)

    def test_existing_runtime_objects_are_not_unlinked_or_repaired(self):
        for name in ("read.sock","owner.json","capabilities.json"):
            with self.subTest(name=name):
                target=self.file(self.runtime/name,b"existing unrelated object\n")
                before=(target.stat().st_ino,target.read_bytes())
                request=copy.deepcopy(self.request);request["record"]="existing-"+name
                filename=request["record"]+".1.json";self.file(self.inbox/filename,request)
                result=self.invoke(filename)
                self.assertNotEqual(result.returncode,0)
                self.assertEqual((target.stat().st_ino,target.read_bytes()),before)
                target.unlink()
        self.assert_protected()

    def test_stop_process_generation_and_live_listener_bindings_refuse(self):
        process,owner=self.ready()
        real=copy.deepcopy(owner)
        for key in ("pid","uid","start_ticks","boot"):
            with self.subTest(key=key):
                wrong=copy.deepcopy(real)
                if key=="boot": wrong["process"][key]="00000000-0000-0000-0000-000000000000"
                elif key=="pid": wrong["process"]=vars(process_generation(os.getpid())).copy()
                else: wrong["process"][key]+=1
                self.file(self.runtime/"owner.json",wrong)
                result=self.invoke(self.stop_input(wrong,"stop-"+key))
                self.assertNotEqual(result.returncode,0,result.stdout)
                self.assertIsNone(process.poll())
                self.assert_protected()
        self.file(self.runtime/"owner.json",real)
        self.stop(process,real)

    def test_stale_owner_epoch_capability_socket_and_start_receipt_refuse(self):
        process,owner=self.ready()
        for key in ("epoch","capabilities","socket","request"):
            with self.subTest(key=key):
                wrong=copy.deepcopy(owner)
                if key=="epoch": wrong[key]="foreign-epoch"
                elif key=="socket": wrong[key]["identity"][1]+=1
                else: wrong[key]="0"*64
                self.file(self.runtime/"owner.json",wrong)
                result=self.invoke(self.stop_input(wrong,"stale-"+key))
                self.assertNotEqual(result.returncode,0,result.stdout)
                self.assertIsNone(process.poll())
        self.file(self.runtime/"owner.json",owner)
        self.stop(process,owner)

    def test_stopped_or_ignored_term_never_reports_actual_exit_or_escalates(self):
        # Separate fixture instances retain all other guards and normal stop.
        for mode in ("stopped","ignored-term"):
            with self.subTest(mode=mode):
                fixture=ForegroundService(methodName="runTest");fixture.setUp()
                try:
                    process,owner=fixture.ready(None if mode=="stopped" else mode)
                    if mode=="stopped": process.send_signal(signal.SIGSTOP)
                    result=fixture.invoke(fixture.stop_input(owner,timeout=1000))
                    self.assertNotEqual(result.returncode,0,result.stdout)
                    self.assertIn(b"pinned process has not exited",result.stderr)
                    self.assertNotIn(b'"exited":true',result.stdout)
                    self.assertIsNone(process.poll())
                    fixture.assert_protected()
                finally: fixture.doCleanups()

    def test_actual_exit_wait_counterfactual_fails_the_same_public_stop_oracle(self):
        process,owner=self.ready()
        process.send_signal(signal.SIGSTOP)
        result=self.invoke(self.stop_input(owner,timeout=1000),"actual-exit-counterfactual")
        def oracle():
            self.assertNotEqual(result.returncode,0,"stopped process must not be reported exited")
            self.assertIn(b"pinned process has not exited",result.stderr)
            self.assertIsNone(process.poll())
        with self.assertRaisesRegex(AssertionError,"stopped process must not be reported exited"): oracle()
        self.assertIsNone(process.poll())
        self.assert_protected()

    def assert_thread_lifetime(self, mode):
        process,owner=self.ready(mode)
        result=self.invoke(self.stop_input(owner,timeout=1000))
        self.assertNotEqual(result.returncode,0,result.stdout)
        self.assertIn(b"pinned process has not exited",result.stderr)
        tail=self.line(process)
        self.assertEqual((tail["event"],tail["exited"]),("foreground-return",False))
        self.assertIsNone(process.poll())
        self.assertFalse((self.runtime/"read.sock").exists())
        self.assertFalse((self.runtime/"owner.json").exists())
        other=self.state/"runtime-b";other.mkdir(mode=0o700)
        contender=None
        try:
            with self.assertRaises(BlockingIOError,msg="actual process still lives after foreground return"):
                contender=ServiceSingleton(self.home,other,self.roots(other))
        finally:
            if contender is not None: contender.close()
        process.stdin.write(b"x");process.stdin.flush();process.wait(timeout=10)
        self.assertEqual(process.returncode,0,process.stderr.read())
        with ServiceSingleton(self.home,other,self.roots(other)): pass
        self.assert_protected()

    def test_non_daemon_thread_keeps_singleton_after_foreground_return(self):
        self.assert_thread_lifetime("thread")

    def test_lifetime_release_counterfactual_fails_the_same_live_thread_oracle(self):
        with self.assertRaisesRegex(AssertionError,"actual process still lives after foreground return"):
            self.assert_thread_lifetime("thread-lifetime-counterfactual")

    def test_cleanup_preserves_replacement_objects_after_verified_exit(self):
        process,owner=self.ready("cleanup-replacement")
        output=self.stop(process,owner)
        self.assertEqual(set(output["cleanup"].values()),{"replacement-preserved"})
        for name in ("owner.json","read.sock"):
            self.assertEqual((self.runtime/name).read_bytes(),b"replacement must survive\n")
        self.assert_protected()

    def test_stop_refuses_replaced_runtime_without_touching_successor_or_process(self):
        process, owner = self.ready()
        retained = self.state / "retained-runtime"
        self.runtime.rename(retained)
        self.runtime.mkdir(mode=0o700)
        sentinel = self.file(self.runtime / "protected", b"successor remains whole\n")
        before = (sentinel.stat().st_ino, sentinel.read_bytes())
        try:
            result = self.invoke(self.stop_input(owner))
            self.assertNotEqual(result.returncode, 0, result.stdout)
            self.assertIsNone(process.poll())
            self.assertEqual(list(self.runtime.iterdir()), [sentinel])
            self.assertEqual((sentinel.stat().st_ino, sentinel.read_bytes()), before)
        finally:
            sentinel.unlink(); self.runtime.rmdir(); retained.rename(self.runtime)
        self.stop_input(owner, "stop-restored")
        result = self.invoke("stop-restored.1.json")
        self.assertEqual(result.returncode, 0, result.stderr)
        process.wait(timeout=10)
        self.assert_protected()

    def assert_runtime_publish_binding(self, pathname=False):
        # Atomic replacement after the last pre-write namespace check must not
        # put even an unpublished file into the successor. The retained parent
        # may keep this invocation's staging evidence on the refusal path.
        runtime = service.Runtime(self.request)
        retained = self.state / "retained-runtime-publish"
        real_write = service.write_new
        replacement = False
        def write(path, raw, mode):
            nonlocal replacement
            self.runtime.rename(retained); self.runtime.mkdir(mode=0o700)
            self.file(self.runtime / "protected", b"whole successor\n")
            replacement = True
            return real_write(path, raw, mode)
        def old_path(self_runtime, name): return self.runtime / name
        from contextlib import nullcontext
        try:
            with (patch.object(service.Runtime, "pinned", old_path) if pathname else nullcontext()):
                with patch.object(service, "write_new", write):
                    with self.assertRaisesRegex(ValueError, "root replaced"):
                        runtime.publish("owner.json", {"fixture": "bounded"})
            self.assertTrue(replacement)
            self.assertEqual({p.name:p.read_bytes() for p in self.runtime.iterdir()},
                             {"protected":b"whole successor\n"})
        finally:
            runtime.close()
            if replacement:
                # Only these fixture-owned temporary trees, never live roots.
                import shutil
                shutil.rmtree(self.runtime)
                retained.rename(self.runtime)
                for p in self.runtime.glob(".view-publish-*"): p.unlink()

    def test_runtime_creation_is_parent_relative_even_before_final_refusal(self):
        self.assert_runtime_publish_binding()
        with self.assertRaises(AssertionError): self.assert_runtime_publish_binding(pathname=True)
        self.assert_protected()

    def test_runtime_constructor_parent_replacement_retires_acquired_descriptor(self):
        for seam in ("before-open", "after-open"):
            with self.subTest(seam=seam):
                retained = self.state / ("retained-" + seam)
                opened = []
                real_open, real_fstat = os.open, os.fstat
                replaced = False
                def replace():
                    nonlocal replaced
                    self.runtime.rename(retained); self.runtime.mkdir(mode=0o700)
                    self.file(self.runtime/"protected",b"successor\n"); replaced=True
                def opening(path, flags, *args, **kwargs):
                    if Path(path) == self.runtime:
                        if seam == "before-open": replace()
                        fd=real_open(path,flags,*args,**kwargs);opened.append(fd);return fd
                    return real_open(path,flags,*args,**kwargs)
                def observing(fd):
                    if seam == "after-open" and opened and fd == opened[0] and not replaced: replace()
                    return real_fstat(fd)
                try:
                    with patch.object(os,"open",opening), patch.object(os,"fstat",observing):
                        with self.assertRaises(ValueError): service.Runtime(self.request)
                    self.assertTrue(replaced); self.assertEqual(len(opened),1)
                    with self.assertRaises(OSError) as caught: real_fstat(opened[0])
                    self.assertEqual(caught.exception.errno,errno.EBADF)
                    self.assertEqual({p.name:p.read_bytes() for p in self.runtime.iterdir()}, {"protected":b"successor\n"})
                finally:
                    if replaced:
                        (self.runtime/"protected").unlink();self.runtime.rmdir();retained.rename(self.runtime)
        self.assert_protected()

    def test_runtime_parent_pin_and_root_guard_counterfactual(self):
        for name in ("home","state"):
            request=copy.deepcopy(self.request);request["roots"][name][1]+=1
            def oracle():
                selected = None
                try:
                    with self.assertRaisesRegex(ValueError,"root replaced"):
                        selected = service.Runtime(request)
                finally:
                    if selected is not None: selected.close()
            oracle()
            # Revert ONLY this new root guard; the same refusal oracle fails.
            with patch.object(service.Runtime,"fresh",lambda self:None):
                with self.assertRaises(AssertionError): oracle()
        runtime=service.Runtime(self.request)
        fd=runtime.fd;runtime.close()
        with self.assertRaises(OSError) as caught: os.fstat(fd)
        self.assertEqual(caught.exception.errno,errno.EBADF)
        self.assertEqual(list(self.runtime.iterdir()),[])
