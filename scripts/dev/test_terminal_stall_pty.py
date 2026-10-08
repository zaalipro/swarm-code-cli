#!/usr/bin/env python3
"""cli020 R2/R3: a terminal that stops reading for a while slows the TUI and
never ends it. A real terminal + socket + loopback HTTP provider; all state is
disposable (the project is a temporary directory, the provider is loopback).

The QA close (session home2, 2026-10-07): the capture harness rendered a PNG
for about a second without reading the PTY while a long stream was drawing. A
macOS pty holds about 1 KiB of unread output, so the native writer's next frame
write waited, its fixed 500 ms bound expired, and the port reported a draw
failure: `terminal owner stopped: :draw`, "The terminal stopped responding".
"""
import http.server
import json
import select
import tempfile
import threading
import time
import unittest
from test_terminal_demo_pty import Demo, ROOT

PROMPT = 'Stream the long stall fixture'
WORDS = 400
WORD_DELAY = 0.015


class Provider(http.server.BaseHTTPRequestHandler):
    """An OpenAI-compatible stream: WORDS words, WORD_DELAY apart."""
    served = []
    cut = threading.Event()

    def log_message(self, *args):
        pass

    def chunk(self, payload):
        data = ('data: ' + json.dumps(payload) + '\n\n').encode()
        self.wfile.write(('%x\r\n' % len(data)).encode() + data + b'\r\n')
        self.wfile.flush()

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        last = body['messages'][-1].get('content')
        long_stream = isinstance(last, str) and PROMPT in last
        self.send_response(200)
        self.send_header('Content-Type', 'text/event-stream')
        self.send_header('Transfer-Encoding', 'chunked')
        self.send_header('Connection', 'close')
        self.end_headers()
        try:
            if long_stream:
                for index in range(WORDS):
                    word = 'w%04d ' % index
                    self.chunk({'choices': [{'delta': {'content': word}, 'finish_reason': None}]})
                    Provider.served.append(index)
                    time.sleep(WORD_DELAY)
                self.chunk({'choices': [{'delta': {}, 'finish_reason': 'stop'}]})
            else:
                self.chunk({'choices': [{'delta': {'content': 'ok'}, 'finish_reason': 'stop'}]})
            self.wfile.write(b'0\r\n\r\n')
            self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            # The client stopped the turn and closed the stream.
            Provider.cut.set()


class TerminalStall(unittest.TestCase):
    def quit(self, terminal):
        # Ctrl-C closes layers or stops turns; two idle presses quit (pass71 R1).
        for _ in range(10):
            if terminal.status is not None:
                break
            terminal.send(b'\x03')
            end = time.monotonic() + .3
            while time.monotonic() < end and terminal.status is None:
                terminal.pump()
                if select.select([terminal.meta], [], [], 0)[0]:
                    terminal.status = int(terminal.meta.readline())
        terminal.finish()

    def wait_alive(self, terminal, marker, timeout=10):
        end = time.monotonic() + timeout
        while True:
            terminal.pump()
            if select.select([terminal.meta], [], [], 0)[0]:
                terminal.status = int(terminal.meta.readline())
            self.assertIsNone(terminal.status, ('the session ended', bytes(terminal.output[-3000:])))
            if marker in terminal.screen():
                return
            if time.monotonic() >= end:
                self.fail(('missing marker', marker, terminal.screen()))

    def test_reader_stall_during_a_long_stream_then_esc_keeps_the_session(self):
        Provider.served = []
        Provider.cut.clear()
        server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Provider)
        worker = threading.Thread(target=server.serve_forever, daemon=True)
        worker.start()
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        with tempfile.TemporaryDirectory(prefix='swarm-stall-pty-') as project:
            terminal = Demo(launcher=ROOT / 'scripts/dev/run_live_session.sh', environment={
                'SWARM_PROJECT_ROOT': project,
                'SWARM_PROVIDER': 'openai',
                'SWARM_MODEL': 'pty-fixture',
                'SWARM_BASE_URL': f'http://127.0.0.1:{server.server_port}/v1',
                'SWARM_API_KEY': 'fixture',
                'SWARM_APPROVAL': 'ask',
            })
            try:
                terminal.wait_for(b'LIVE')
                terminal.descendants()
                terminal.send(b'\x1b[200~' + PROMPT.encode() + b'\x1b[201~')
                terminal.wait_for(PROMPT.encode())
                terminal.send(b'\r')
                # The stream is drawing.
                terminal.wait_for(b'w0010')
                # The reader stalls for 1.5 s while frames keep coming; Esc is
                # pressed in the middle of the stall (input and output are
                # separate queues, so the key waits in the tty).
                time.sleep(.75)
                terminal.send(b'\x1b')
                time.sleep(.75)
                # Reading again: the TUI catches up, the session is alive and
                # Esc stopped the turn (the card says so while the session
                # runs; the stream was cut long before its last word).
                self.wait_alive(terminal, b'stopped')
                self.assertTrue(Provider.cut.wait(5), 'the stream was never cut')
                self.assertLess(len(Provider.served), WORDS)
                self.assertNotIn(b'w%04d' % (WORDS - 1), terminal.screen())
                # Still alive a second later, and nothing reported a close.
                end = time.monotonic() + 1
                while time.monotonic() < end:
                    self.wait_alive(terminal, b'stopped', timeout=.1)
                for words in (b'stopped responding', b'session closed', b'draw_failed'):
                    self.assertNotIn(words, bytes(terminal.output))
                terminal.capture('stall-stopped')
                self.quit(terminal)
            finally:
                terminal.close()


if __name__ == '__main__':
    unittest.main()
