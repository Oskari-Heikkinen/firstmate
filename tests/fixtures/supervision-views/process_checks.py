"""CI-only kernel identity/exit observations; no backend or live service.

The fixture owns every child. Observation APIs may not signal or reap one;
only fixture teardown can terminate its own child after a failed assertion.
"""
from dataclasses import replace
import os
from pathlib import Path
import selectors
import signal
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

from fm_view_process import ProcessGeneration, ProcessPin, process_generation


CHILD = r'''
import ctypes, os, socket, sys, threading
from concurrent.futures import ThreadPoolExecutor
# A comm containing parentheses and a newline cannot become an argv heuristic.
assert ctypes.CDLL(None).prctl(15, b'a) b (c\n', 0, 0, 0) == 0
if len(sys.argv) > 1:
    go = threading.Event()
    started = threading.Event()
    def held_read():
        started.set()
        go.wait()
        assert sys.stdin.buffer.read(1) == b'x'
    executor = ThreadPoolExecutor(max_workers=1)
    executor.submit(held_read)
    assert started.wait(20)
    left, right = socket.socketpair()
    print('ready', flush=True)
    assert sys.stdin.buffer.read(1) == b'x'
    left.close()
    right.close()
    executor.shutdown(wait=False)
    print('socket-closed-engine-returned', flush=True)
    go.set()
    # The main function falls through to interpreter exit here. Its ONLY
    # remaining liveness is the real executor worker's blocked stdin read.
else:
    print('ready', flush=True)
    action = sys.stdin.buffer.read(1)
    if action == b'e':
        os.execv(sys.executable, [sys.executable, '-c',
            "import sys;print('exec-ready',flush=True);sys.stdin.buffer.read(1)"])
'''


class ProcessPins(unittest.TestCase):
    def child(self, threaded=False):
        child = subprocess.Popen([sys.executable, '-u', '-c', CHILD] + (['threaded'] if threaded else []),
                                 stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.addCleanup(self.cleanup_child, child)
        self.assertEqual(self.line(child), b'ready\n')
        return child

    def cleanup_child(self, child):
        if child.poll() is None:
            child.kill()  # Only this fixture's direct child, never the pin API.
        child.wait(timeout=10)
        for stream in (child.stdin, child.stdout, child.stderr):
            stream.close()

    def line(self, child):
        # Unbuffered -u child emits one complete line per command. Readiness is
        # the observable pipe event, never an elapsed sleep or fixed poll count.
        with selectors.DefaultSelector() as selector:
            selector.register(child.stdout, selectors.EVENT_READ)
            self.assertTrue(selector.select(20), 'fixture child did not publish its phase')
        return child.stdout.readline()

    def command(self, child, command=b'x'):
        child.stdin.write(command)
        child.stdin.flush()

    def no_signals(self):
        from contextlib import ExitStack
        stack = ExitStack()
        for owner, name in ((os, 'kill'), (os, 'killpg'), (signal, 'pidfd_send_signal')):
            stack.enter_context(patch.object(owner, name, side_effect=AssertionError('observation sent a signal')))
        return stack

    def test_kernel_pin_survives_exec_and_closes_without_reaping_or_signalling(self):
        child = self.child()
        generation = process_generation(child.pid)
        self.assertEqual((generation.pid, generation.uid), (child.pid, os.getuid()))
        self.assertGreater(generation.start_ticks, 0)
        with self.no_signals(), ProcessPin(generation) as pin:
            self.assertFalse(pin.exited())
            self.assertFalse(os.get_inheritable(pin.fileno()))
            self.command(child, b'e')
            self.assertEqual(self.line(child), b'exec-ready\n')
            self.assertEqual(process_generation(child.pid), generation)
            self.assertFalse(pin.exited())
            self.command(child)
            pin.wait_exit(20)
            self.assertTrue(pin.exited())
            # waitid WNOWAIT proves the pin did not reap or consume ownership.
            event = os.waitid(os.P_PID, child.pid, os.WEXITED | os.WNOHANG | os.WNOWAIT)
            self.assertEqual(event.si_pid, child.pid)
        child.wait(timeout=10)
        pin.close()
        with self.assertRaisesRegex(ValueError, 'closed'):
            pin.exited()
        # Reusing the numeric fd cannot let a second close retire another fd.
        read, write = os.pipe()
        try:
            pin.close()
            os.fstat(read)
            os.fstat(write)
        finally:
            os.close(read)
            os.close(write)

    def test_wait_observes_actual_process_exit_not_socket_or_executor_cleanup(self):
        child = self.child(threaded=True)
        with ProcessPin(process_generation(child.pid)) as pin, self.no_signals():
            self.command(child)
            self.assertEqual(self.line(child), b'socket-closed-engine-returned\n')
            # A real non-daemon thread still holds this process, exactly the
            # shutdown(wait=False) limitation; no fake stopped/exited verdict.
            self.assertFalse(pin.exited())
            with self.assertRaises(TimeoutError):
                pin.wait_exit(0.05)
            self.assertFalse(pin.exited())
            self.command(child)
            pin.wait_exit(20)
        child.wait(timeout=10)

    def test_sigstop_is_not_exit_and_an_expired_wait_does_not_signal(self):
        child = self.child()
        with ProcessPin(process_generation(child.pid)) as pin:
            os.kill(child.pid, signal.SIGSTOP)  # Fixture drives only its child.
            event = os.waitid(os.P_PID, child.pid, os.WSTOPPED)
            self.assertEqual(event.si_code, os.CLD_STOPPED)
            with self.no_signals():
                self.assertFalse(pin.exited())
                with self.assertRaises(TimeoutError):
                    pin.wait_exit(0.05)
            os.kill(child.pid, signal.SIGCONT)
            self.command(child)
            pin.wait_exit(20)
        child.wait(timeout=10)

    def test_each_generation_mismatch_refuses_and_leaves_the_child_alive(self):
        child = self.child()
        generation = process_generation(child.pid)
        boot = ('0' if generation.boot[0] != '0' else '1') + generation.boot[1:]
        sibling = self.child()
        wrong = [replace(generation, uid=generation.uid + 1),
                 replace(generation, start_ticks=generation.start_ticks + 1),
                 replace(generation, boot=boot), replace(generation, pid=sibling.pid)]
        for changed in wrong:
            # The sibling's ticks can coincide. Bind the PID mismatch to the
            # original child's observed generation rather than trusting time.
            with self.subTest(expected=changed), self.no_signals():
                if changed.uid != generation.uid:
                    # Isolate same-UID admission from the later equality guard.
                    with patch('fm_view_process.process_generation', return_value=changed):
                        with self.assertRaisesRegex(ValueError, 'this UID'):
                            ProcessPin(changed)
                elif changed.pid == sibling.pid:
                    with patch('fm_view_process.process_generation', return_value=generation):
                        with self.assertRaisesRegex(ValueError, 'generation changed'):
                            ProcessPin(changed)
                else:
                    with self.assertRaises(ValueError):
                        ProcessPin(changed)
                self.assertIsNone(child.poll())
                self.assertIsNone(sibling.poll())
        self.command(child)
        self.command(sibling)
        child.wait(timeout=10)
        sibling.wait(timeout=10)

    def test_exit_after_generation_capture_refuses_the_pinned_incarnation(self):
        child = self.child()
        generation = process_generation(child.pid)
        original = process_generation
        def capture_then_exit(pid):
            observed = original(pid)
            self.command(child)
            child.wait(timeout=10)
            return observed
        with patch('fm_view_process.process_generation', side_effect=capture_then_exit), self.no_signals():
            with self.assertRaisesRegex(ValueError, 'exited'):
                ProcessPin(generation)

    def test_dead_pidfd_cannot_admit_an_observation_from_a_later_generation(self):
        child = self.child()
        generation = process_generation(child.pid)
        opened = os.pidfd_open
        def open_then_exit(pid, flags):
            fd = opened(pid, flags)
            self.command(child)
            child.wait(timeout=10)
            return fd
        # Model numeric-PID reuse after pidfd acquisition without trying to
        # exhaust the CI PID space: the old fd is a REAL exited process, while
        # the later procfs answer has exactly the expected admitted fields.
        with patch.object(os, 'pidfd_open', side_effect=open_then_exit), \
                patch('fm_view_process.process_generation', return_value=generation), self.no_signals():
            with self.assertRaisesRegex(ValueError, 'exited'):
                ProcessPin(generation)

    def test_unknown_identity_inputs_refuse_without_signals_or_blocking(self):
        child = self.child()
        original = os.open
        valid = f'{child.pid} (fixture) S ' + ' '.join(['0'] * 18 + ['1']) + '\n'
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            cases = {'empty': b'', 'whitespace': b' \n', 'partial': valid[:-1].encode(),
                     'nul': valid.encode() + b'\0', 'oversized': b'x' * 8193,
                     'wrong-pid': valid.replace(str(child.pid), str(child.pid + 1), 1).encode(),
                     'bad-ticks': valid.replace('1\n', 'bad\n').encode()}
            for name, raw in cases.items():
                (root / name).write_bytes(raw)
            (root / 'unreadable').write_bytes(valid.encode())
            (root / 'unreadable').chmod(0)
            self.assertNotEqual(os.geteuid(), 0, 'mode-000 refusal requires the unprivileged CI fixture')
            (root / 'directory').mkdir()
            os.mkfifo(root / 'fifo')
            (root / 'link').symlink_to(root / 'empty')
            (root / 'dangling').symlink_to(root / 'absent')
            for name in (*cases, 'unreadable', 'directory', 'fifo', 'link', 'dangling', 'absent'):
                def redirect(path, flags, *args, **kwargs):
                    if path == 'stat':
                        return original(root / name, flags)
                    return original(path, flags, *args, **kwargs)
                with self.subTest(shape=name), patch.object(os, 'open', side_effect=redirect), self.no_signals():
                    with self.assertRaises((OSError, ValueError)):
                        process_generation(child.pid)
            boot = root / 'boot'
            boot.write_bytes(b'')
            def redirect_boot(path, flags, *args, **kwargs):
                if path == '/proc/sys/kernel/random/boot_id':
                    return original(boot, flags)
                return original(path, flags, *args, **kwargs)
            with patch.object(os, 'open', side_effect=redirect_boot), self.no_signals():
                with self.assertRaises(ValueError):
                    process_generation(child.pid)
        self.assertIsNone(child.poll())
        self.command(child)
        child.wait(timeout=10)

    def test_failed_generation_observation_closes_only_its_acquired_pidfd(self):
        child = self.child()
        generation = process_generation(child.pid)
        opened = os.pidfd_open
        acquired = []
        def remember(pid, flags):
            fd = opened(pid, flags)
            acquired.append(fd)
            return fd
        with patch.object(os, 'pidfd_open', side_effect=remember), \
                patch('fm_view_process.process_generation', side_effect=OSError('procfs unknown')), self.no_signals():
            with self.assertRaisesRegex(OSError, 'procfs unknown'):
                ProcessPin(generation)
        self.assertEqual(len(acquired), 1)
        with self.assertRaises(OSError):
            os.fstat(acquired[0])
        self.assertIsNone(child.poll())
        self.command(child)
        child.wait(timeout=10)

    def test_changed_identity_descriptor_refuses_before_a_generation_is_returned(self):
        from types import SimpleNamespace
        child = self.child()
        opened, observed = os.open, os.fstat
        target, calls = [], []
        def remember(path, flags, *args, **kwargs):
            fd = opened(path, flags, *args, **kwargs)
            if path == 'stat':
                target.append(fd)
            return fd
        def changed(fd):
            info = observed(fd)
            if target and fd == target[-1]:
                calls.append(fd)
                if len(calls) == 2:
                    return SimpleNamespace(st_dev=info.st_dev, st_ino=info.st_ino,
                                           st_mode=info.st_mode, st_uid=info.st_uid + 1)
            return info
        with patch.object(os, 'open', side_effect=remember), patch.object(os, 'fstat', side_effect=changed), self.no_signals():
            with self.assertRaisesRegex(ValueError, 'identity input changed'):
                process_generation(child.pid)
        self.assertEqual(len(calls), 2)
        self.assertIsNone(child.poll())
        self.command(child)
        child.wait(timeout=10)

    def test_spurious_wakes_do_not_reset_the_original_exit_deadline(self):
        child = self.child()
        with ProcessPin(process_generation(child.pid)) as pin, self.no_signals():
            with patch('fm_view_process.time.monotonic', side_effect=[100, 100.01, 100.02, 100.06]), \
                    patch('selectors.EpollSelector.select', return_value=[]) as wake:
                with self.assertRaises(TimeoutError):
                    pin.wait_exit(0.05)
                self.assertEqual(wake.call_count, 2)
                self.assertAlmostEqual(wake.call_args_list[0].args[0], 0.04)
                self.assertAlmostEqual(wake.call_args_list[1].args[0], 0.03)
            self.assertFalse(pin.exited())
            self.command(child)
            pin.wait_exit(20)
        child.wait(timeout=10)

    def test_invalid_values_and_unsupported_pidfd_refuse_without_process_effects(self):
        child = self.child()
        generation = process_generation(child.pid)
        for values in [dict(pid=True), dict(pid=0), dict(uid=True), dict(uid=-1),
                       dict(start_ticks=True), dict(start_ticks=0), dict(boot=''), dict(boot='bad')]:
            with self.subTest(values=values), self.assertRaises(ValueError):
                replace(generation, **values)
        for pid in [None, True, -1, 0, '1']:
            with self.subTest(pid=pid), self.assertRaises(ValueError):
                process_generation(pid)
        with patch('fm_view_process.sys.platform', 'darwin'), self.no_signals():
            with self.assertRaisesRegex(ValueError, 'requires Linux'):
                process_generation(child.pid)
        with patch.object(os, 'pidfd_open', side_effect=PermissionError('kernel denied')), self.no_signals():
            with self.assertRaises(PermissionError):
                ProcessPin(generation)
        with patch.dict(os.__dict__):
            del os.pidfd_open
            with self.no_signals(), self.assertRaisesRegex(ValueError, 'pidfd unavailable'):
                ProcessPin(generation)
        with ProcessPin(generation) as pin, self.no_signals():
            for bound in [None, True, 0, -1, 31, float('nan'), float('inf')]:
                with self.subTest(bound=bound), self.assertRaises(ValueError):
                    pin.wait_exit(bound)
        self.assertIsNone(child.poll())
        self.command(child)
        child.wait(timeout=10)
