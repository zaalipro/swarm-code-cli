#!/usr/bin/env python3
"""Task-owned controlling-PTY tests. Never opens or alters the caller's terminal."""
import fcntl
import json
import os
from pathlib import Path
import select
import signal
import struct
import subprocess
import sys
import termios
import time
import unittest

ROOT = Path(__file__).resolve().parents[2]
EXE = ROOT / '_build/terminal-port/debug/swarm-terminal-port'
GEN = 7


def packet(body):
    return struct.pack('>I', len(body)) + body


def command(tag, token=1, generation=GEN):
    return packet(struct.pack('>BBQQ', 1, tag, generation, token))


def draw(sequence=1, text=b'X', columns=80, rows=24):
    body = struct.pack('>BBQQHHBBHB', 1, 3, sequence, 42, columns, rows, 0, 0, 1, 0)
    cells = text.ljust(columns * rows, b' ')
    assert len(cells) == columns * rows
    body += struct.pack('>I', len(cells)) + b'\0\0\0'
    for byte in cells:
        body += struct.pack('>HHIB', 1, 0, 1, byte)
    return packet(body)


class Port:
    def __init__(self, flags=7, initialize=True, mode="default"):
        self.master, self.slave = os.openpty()
        fcntl.ioctl(self.slave, termios.TIOCSWINSZ, struct.pack('HHHH', 24, 80, 0, 0))
        self.mode = mode
        self.original_status_flags = fcntl.fcntl(self.slave, fcntl.F_GETFL)
        self.terminal = bytearray()
        self.wire = bytearray()
        meta_read, meta_write = os.pipe()
        release_read, self.release = os.pipe()
        # Keep a task-owned session leader alive after the native guard exits.
        # macOS revokes the slave when its session leader exits, so keep
        # that leader alive and snapshot inside the established session.
        self.process = subprocess.Popen(
            [sys.executable, __file__, '--holder', str(self.slave), str(meta_write), str(release_read), mode],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            pass_fds=(self.slave, meta_write, release_read))
        os.close(meta_write)
        os.close(release_read)
        self.meta = os.fdopen(meta_read, 'r')
        initial = json.loads(self.meta.readline())
        self.pid = initial['pid']
        self.original = initial['termios']
        self.original[6] = [bytes([b]) if isinstance(b, int) else b for b in self.original[6]]
        self.status = None
        self.writer_pid = None
        self.flags = flags
        if initialize:
            self.send(packet(struct.pack('>BBQB', 1, 1, GEN, flags)))
            ready = self.recv()
            assert ready == struct.pack('>BBQHHB', 1, 16, GEN, 80, 24, flags), ready
            assert termios.tcgetattr(self.slave) != self.original
            listing = subprocess.check_output(['ps', '-axo', 'ppid=,pid='], text=True)
            children = [int(line.split()[1]) for line in listing.splitlines() if line.split()[0] == str(self.pid)]
            assert len(children) == 1, children
            self.writer_pid = children[0]

    def poll(self):
        if self.status is None and select.select([self.meta], [], [], 0)[0]:
            self.status = int(self.meta.readline())
        return self.status

    def terminate(self):
        os.kill(self.pid, signal.SIGTERM)

    def send(self, data):
        self.process.stdin.write(data)
        self.process.stdin.flush()

    def pump(self, timeout=.05):
        for fd in select.select([self.master] + ([] if self.process.stdout.closed else [self.process.stdout]), [], [], timeout)[0]:
            try:
                data = os.read(fd if isinstance(fd, int) else fd.fileno(), 65536)
            except OSError:
                data = b''
            (self.terminal if isinstance(fd, int) else self.wire).extend(data)

    def recv(self, timeout=3):
        end = time.monotonic() + timeout
        while time.monotonic() < end:
            if len(self.wire) >= 4:
                size = struct.unpack('>I', self.wire[:4])[0]
                assert size <= 262167, size
                if len(self.wire) >= size + 4:
                    result = bytes(self.wire[4:4+size])
                    del self.wire[:4+size]
                    return result
            self.pump()
        raise AssertionError(('response timeout', bytes(self.wire), self.poll()))

    def silent(self, duration=.15):
        end = time.monotonic() + duration
        while time.monotonic() < end:
            self.pump(.01)
        assert not self.wire, bytes(self.wire)

    def restored(self):
        end = time.monotonic() + 3
        while self.poll() is None and time.monotonic() < end:
            self.pump()
        assert self.poll() is not None, 'guard did not exit'
        self.pump(0)
        assert termios.tcgetattr(self.slave) == self.original, 'termios not exactly restored'
        if self.mode == 'beam':
            assert fcntl.fcntl(self.slave, fcntl.F_GETFL) == self.original_status_flags, 'descriptor flags not restored'
        assert b'\x1b[?25h' in self.terminal and b'\x1b[?7h' in self.terminal
        if self.flags & 1:
            assert b'\x1b[?1049h' in self.terminal and b'\x1b[?1049l' in self.terminal
        else:
            assert b'\x1b[?1049h' not in self.terminal and b'\x1b[?1049l' not in self.terminal
        children = subprocess.check_output(['ps', '-axo', 'ppid=,pid='], text=True)
        assert not any(line.split()[0] == str(self.pid) for line in children.splitlines())
        if self.writer_pid:
            try:
                os.kill(self.writer_pid, 0)
            except ProcessLookupError:
                pass
            else:
                raise AssertionError('writer survived guard exit')

    def close(self):
        try:
            if self.poll() is None:
                self.terminate()
                self.restored()
        finally:
            if self.poll() is None:
                try:
                    os.kill(self.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
            os.close(self.release)
            self.process.wait(timeout=3)
            self.meta.close()
            self.process.stdin.close()
            self.process.stdout.close()
            self.process.stderr.close()
            os.close(self.master)
            os.close(self.slave)


class TerminalPortPTY(unittest.TestCase):
    def port(self, *args, **kwargs):
        port = Port(*args, **kwargs)
        self.addCleanup(port.close)
        return port

    def test_beam_handoff_without_controlling_terminal(self):
        p = self.port(mode='beam')
        p.send(draw())
        self.assertEqual(p.recv()[1], 18)
        p.send(command(5, 1))
        self.assertEqual(p.recv()[1], 19)
        self.assertEqual(fcntl.fcntl(p.slave, fcntl.F_GETFL), p.original_status_flags)
        p.send(command(6, 2))
        self.assertEqual(p.recv()[1], 16)
        p.send(command(4, 3))
        self.assertEqual(p.recv()[1], 19)
        p.restored()
        killed = self.port(mode='beam')
        os.kill(killed.writer_pid, signal.SIGKILL)
        killed.restored()

    def test_invalid_beam_handoff_never_changes_modes(self):
        for mode in ['beam_bad', 'beam_mismatch']:
            p = self.port(initialize=False, mode=mode)
            end = time.monotonic() + 3
            while p.poll() is None and time.monotonic() < end:
                p.pump(.01)
            self.assertEqual(p.poll(), 1)
            self.assertEqual(termios.tcgetattr(p.slave), p.original)
            self.assertEqual(fcntl.fcntl(p.slave, fcntl.F_GETFL), p.original_status_flags)
            self.assertEqual(p.terminal, b'')

    def test_credit_stall_preserves_split_csi_and_paste_start(self):
        for sequence, payload in [(b'\x1b[A', bytes([0, 0, 4, 0])),
                                  (b'\x1b[200~hello\x1b[201~', bytes([2]) + struct.pack('>I', 5) + b'hello')]:
            marker_len = 3 if sequence == b'\x1b[A' else 6
            for split in range(1, marker_len):
                with self.subTest(sequence=sequence, split=split):
                    p = self.port()
                    os.write(p.master, b'x' + sequence[:split])
                    p.send(command(2, 1))
                    self.assertEqual(p.recv()[-1:], b'x')
                    os.write(p.master, sequence[split:])
                    p.silent(.12)
                    p.send(command(2, 2))
                    self.assertEqual(p.recv(), struct.pack('>BBQQ', 1, 17, GEN, 2) + payload)
                    p.send(command(4, 3))
                    self.assertEqual(p.recv()[1], 19)
                    p.restored()

    def test_parent_eof_reaps_externally_stopped_writer(self):
        p = self.port()
        os.kill(p.pid, signal.SIGTSTP)
        end = time.monotonic() + 3
        while time.monotonic() < end:
            status = subprocess.check_output(['ps', '-o', 'stat=', '-p', str(p.writer_pid)], text=True)
            if 'T' in status:
                break
            p.pump(.01)
        self.assertIn('T', status)
        self.assertEqual(termios.tcgetattr(p.slave), p.original)
        p.process.stdin.close()
        p.restored()

    def test_external_resume_barrier_drains_old_work_and_keeps_input(self):
        p = self.port()
        os.write(p.master, b'ab')
        p.send(command(2, 1))
        self.assertEqual(p.recv()[-1:], b'a')
        os.kill(p.pid, signal.SIGTSTP)
        end = time.monotonic() + 3
        while time.monotonic() < end:
            status = subprocess.check_output(['ps', '-o', 'stat=', '-p', str(p.writer_pid)], text=True)
            if 'T' in status:
                break
            p.pump(.01)
        self.assertIn('T', status)
        p.send(command(2, 2))
        p.send(draw(1))
        os.kill(p.pid, signal.SIGCONT)
        self.assertEqual(p.recv(), struct.pack('>BBQ', 1, 24, GEN))
        self.assertEqual(termios.tcgetattr(p.slave), p.original)
        p.silent()
        p.send(command(6, 3))
        self.assertEqual(p.recv()[1], 16)
        p.send(draw(2))
        self.assertEqual(p.recv()[1], 18)
        p.send(command(2, 4))
        self.assertEqual(p.recv()[-1:], b'b')
        p.send(command(4, 5))
        self.assertEqual(p.recv()[1], 19)
        p.restored()

    def test_undrained_terminal_restoration_retry_has_bounded_failure(self):
        p = self.port()
        p.send(draw())
        # Never drain the terminal during this interval: the output pipe must
        # remain saturated through the writer failure and guard's final retry.
        end = time.monotonic() + 3
        while p.poll() is None and time.monotonic() < end:
            if select.select([p.process.stdout], [], [], .02)[0]:
                p.wire.extend(os.read(p.process.stdout.fileno(), 65536))
        self.assertIsNotNone(p.poll(), 'guard blocked retrying terminal restoration')
        self.assertNotEqual(p.poll(), 0)
        self.assertEqual(termios.tcgetattr(p.slave), p.original)
        self.assertEqual(bytes(p.wire), packet(struct.pack('>BBQB', 1, 21, GEN, 6)))
        # No Restored success is emitted: termios is exact, but escape-mode
        # restoration cannot be guaranteed against a permanently blocked sink.
        with self.assertRaises(ProcessLookupError):
            os.kill(p.writer_pid, 0)
        listing = subprocess.check_output(['ps', '-axo', 'ppid=,pid='], text=True)
        self.assertFalse(any(line.split()[0] == str(p.pid) for line in listing.splitlines()))
        # The native guard has exited before any drain. Only now release the
        # capture bytes so the separate test session-holder can close its tty.
        while select.select([p.master], [], [], 0)[0]:
            p.terminal.extend(os.read(p.master, 65536))

    def test_draw_credit_paste_escape_and_shutdown(self):
        p = self.port()
        p.send(draw(text=b'XYZ'))
        self.assertEqual(p.recv(), struct.pack('>BBQQQ', 1, 18, GEN, 1, 42))
        self.assertIn(b'X', p.terminal)
        os.write(p.master, b'ab\x1b[200~hello\nworld\x1b[201~\x1b')
        p.silent()
        for token, value in [(1, b'a'), (2, b'b')]:
            p.send(command(2, token))
            self.assertEqual(p.recv(), struct.pack('>BBQQBBB H', 1, 17, GEN, token, 1, 0, 0, 1) + value)
            p.silent()
        p.send(command(2, 3))
        self.assertEqual(p.recv(), struct.pack('>BBQQBI', 1, 17, GEN, 3, 2, 11) + b'hello\nworld')
        p.send(command(2, 4))
        self.assertEqual(p.recv(), struct.pack('>BBQQBBBB', 1, 17, GEN, 4, 0, 0, 14, 0))
        p.send(command(4, 5))
        self.assertEqual(p.recv(), struct.pack('>BBQQB', 1, 19, GEN, 5, 0))
        p.restored()

    def test_no_alt_resize_suspend_resume_full_paint(self):
        p = self.port(flags=6)
        os.write(p.slave, b'SCROLLBACK_SENTINEL\r\n' + b'\r\n' * 24)
        for cycle in range(3):
            base = cycle * 4
            fcntl.ioctl(p.slave, termios.TIOCSWINSZ, struct.pack('HHHH', 25 + cycle, 90 + cycle, 0, 0))
            p.silent(.2)
            p.send(command(2, base + 1))
            self.assertEqual(p.recv(), struct.pack('>BBQQHH', 1, 20, GEN, base + 1, 90 + cycle, 25 + cycle))
            p.send(draw(base + 1, columns=90 + cycle, rows=25 + cycle))
            self.assertEqual(p.recv()[1], 18)
            p.send(command(5, base + 2))
            self.assertEqual(p.recv(), struct.pack('>BBQQB', 1, 19, GEN, base + 2, 1))
            self.assertEqual(termios.tcgetattr(p.slave), p.original)
            p.send(command(6, base + 3))
            self.assertEqual(p.recv()[1], 16)
            before = len(p.terminal)
            p.send(draw(base + 2, columns=90 + cycle, rows=25 + cycle))
            self.assertEqual(p.recv()[1], 18)
            self.assertIn(b'X', p.terminal[before:])
        p.send(command(4, 13))
        self.assertEqual(p.recv()[1], 19)
        p.restored()
        self.assertIn(b'SCROLLBACK_SENTINEL', p.terminal)
        self.assertNotIn(b'\x1b[2J', p.terminal)
        self.assertNotIn(b'\x1b[3J', p.terminal)

    def test_partial_header_eof_and_fragmented_body_signal(self):
        p = self.port()
        p.send(b'\x00\x00')
        p.process.stdin.close()
        p.restored()
        q = self.port()
        q.send(struct.pack('>I', 33554432) + b'\x01')
        q.terminate()
        q.restored()

    def test_protocol_rejections_restore(self):
        cases = [struct.pack('>I', 33554433), command(2, 1, GEN + 1),
                 command(2, 1) + command(2, 2), command(2, 2) + command(5, 1),
                 draw(1) + draw(1)]
        for data in cases:
            with self.subTest(data=data[:20]):
                p = self.port()
                p.send(data)
                response = p.recv()
                if response[1] == 18:
                    response = p.recv()
                self.assertEqual(response, struct.pack('>BBQB', 1, 21, GEN, 1))
                p.restored()

    def test_fragmented_frame_and_initialization_failure(self):
        p = self.port()
        for byte in draw():
            p.send(bytes([byte]))
        self.assertEqual(p.recv()[1], 18)
        p.send(command(4, 1))
        self.assertEqual(p.recv()[1], 19)
        p.restored()
        q = self.port(initialize=False)
        fcntl.ioctl(q.slave, termios.TIOCSWINSZ, struct.pack('HHHH', 0, 0, 0, 0))
        q.send(packet(struct.pack('>BBQB', 1, 1, GEN, 7)))
        self.assertEqual(q.recv(), struct.pack('>BBQB', 1, 21, GEN, 2))
        q.restored()

    def test_external_suspend_resume_and_broken_output(self):
        p = self.port()
        os.kill(p.pid, signal.SIGTSTP)
        end = time.monotonic() + 3
        while termios.tcgetattr(p.slave) != p.original and time.monotonic() < end:
            p.pump(.01)
        self.assertEqual(termios.tcgetattr(p.slave), p.original)
        os.kill(p.pid, signal.SIGCONT)
        self.assertEqual(p.recv()[1], 24)
        p.send(command(6, 1))
        self.assertEqual(p.recv()[1], 16)
        p.send(draw())
        self.assertEqual(p.recv()[1], 18)
        p.process.stdout.close()
        p.send(draw(2))
        p.restored()

    def test_resize_between_ready_and_draw_skips_without_output(self):
        p = self.port(flags=0)
        p.pump(0)
        before = bytes(p.terminal)
        fcntl.ioctl(p.slave, termios.TIOCSWINSZ, struct.pack('HHHH', 20, 70, 0, 0))
        p.send(draw())
        self.assertEqual(p.recv(), struct.pack('>BBQQQ', 1, 23, GEN, 1, 42))
        p.pump(0)
        self.assertEqual(bytes(p.terminal), before)
        p.send(command(2, 1))
        self.assertEqual(p.recv(), struct.pack('>BBQQHH', 1, 20, GEN, 1, 70, 20))
        p.send(draw(2, columns=70, rows=20))
        self.assertEqual(p.recv(), struct.pack('>BBQQQ', 1, 18, GEN, 2, 42))
        self.assertIn(b'X', p.terminal[len(before):])
        p.send(command(4, 2))
        self.assertEqual(p.recv()[1], 19)
        p.restored()

    def test_parent_eof_and_signals_and_killed_writer(self):
        p = self.port()
        p.process.stdin.close()
        p.restored()
        for sig in [signal.SIGINT, signal.SIGTERM, signal.SIGHUP]:
            q = self.port()
            os.kill(q.pid, sig)
            q.restored()
        r = self.port()
        listing = subprocess.check_output(['ps', '-axo', 'ppid=,pid='], text=True)
        children = [int(line.split()[1]) for line in listing.splitlines() if line.split()[0] == str(r.pid)]
        self.assertEqual(len(children), 1)
        os.kill(children[0], signal.SIGKILL)
        r.restored()
        with self.assertRaises(ProcessLookupError):
            os.kill(children[0], 0)


def holder():
    slave, meta, release = map(int, sys.argv[2:5])
    mode = sys.argv[5]
    os.setsid()
    fcntl.ioctl(slave, termios.TIOCSCTTY, 0)
    original = termios.tcgetattr(slave)
    original[6] = [b[0] if isinstance(b, bytes) else b for b in original[6]]
    if mode == 'default':
        child = subprocess.Popen([str(EXE)])
    else:
        terminal = fcntl.fcntl(slave, fcntl.F_DUPFD_CLOEXEC, 10)
        source = fcntl.fcntl(0, fcntl.F_DUPFD_CLOEXEC, 10)
        sink = fcntl.fcntl(1, fcntl.F_DUPFD_CLOEXEC, 10)
        os.dup2(source, 3)
        os.dup2(sink, 4)
        wrong = os.openpty() if mode == 'beam_mismatch' else None
        def handoff():
            os.setsid()  # OTP's spawn child also has no controlling tty.
            if mode != 'beam_bad':
                os.dup2(terminal, 0)
            os.dup2(wrong[1] if wrong else terminal, 1)
        inherited = (3, 4, terminal) + ((wrong[1],) if wrong else ())
        child = subprocess.Popen([str(EXE), '--beam-port'], pass_fds=inherited, preexec_fn=handoff)
        for descriptor in [source, sink, 3, 4, terminal] + (list(wrong) if wrong else []):
            os.close(descriptor)
    os.write(meta, (json.dumps({'pid': child.pid, 'termios': original}) + '\n').encode())
    os.close(0)
    os.close(1)
    code = child.wait()
    os.write(meta, (str(code) + '\n').encode())
    os.read(release, 1)


if __name__ == '__main__':
    if len(sys.argv) > 1 and sys.argv[1] == '--holder':
        holder()
    else:
        unittest.main()
