#!/usr/bin/env python3
"""Real terminal + socket + HTTP provider smoke test; all state is disposable."""
import http.server
import json
import select
import tempfile
import threading
import time
import unittest
from test_terminal_demo_pty import Demo, ROOT


class LiveSession(unittest.TestCase):
    def test_prompt_reaches_provider_and_response_is_visible_before_clean_exit(self):
        requests = []

        class Provider(http.server.BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def do_POST(self):
                body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
                requests.append(body)
                event = {'choices': [{'delta': {'content': 'Live terminal verified.'}, 'finish_reason': 'stop'}]}
                payload = ('data: ' + json.dumps(event) + '\n\n').encode()
                self.send_response(200)
                self.send_header('Content-Type', 'text/event-stream')
                self.send_header('Transfer-Encoding', 'chunked')
                self.send_header('Connection', 'close')
                self.end_headers()
                self.wfile.write(('%x\r\n' % len(payload)).encode() + payload + b'\r\n0\r\n\r\n')

        server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Provider)
        worker = threading.Thread(target=server.serve_forever, daemon=True)
        worker.start()
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        with tempfile.TemporaryDirectory(prefix='swarm-live-pty-') as project:
            terminal = Demo(launcher=ROOT / 'scripts/dev/run_live_session.sh', environment={
                'SWARM_PROJECT_ROOT': project,
                'SWARM_PROVIDER': 'openai',
                'SWARM_MODEL': 'pty-fixture',
                'SWARM_BASE_URL': f'http://127.0.0.1:{server.server_port}/v1',
                'SWARM_API_KEY': 'fixture',
                'SWARM_APPROVAL': 'ask',
            })
            try:
                # pass70 (D4, D5): no focus names on screen, and the view opens
                # composer-first, so the banner and a paste are the markers.
                terminal.wait_for(b'LIVE')
                self.assertNotIn(b'FAKE', terminal.screen())
                terminal.descendants()
                terminal.send(b'\x1b[200~Verify live terminal\x1b[201~')
                terminal.wait_for(b'Verify live terminal')
                terminal.send(b'\r')
                terminal.wait_for(b'Live terminal verified.')
                terminal.capture('live-response')
                self.assertEqual(requests[0]['model'], 'pty-fixture')
                self.assertEqual(requests[0]['messages'][-1]['content'], 'Verify live terminal')
                terminal.send(b'\x10')
                terminal.wait_for(b'Search:')
                terminal.send(b'Settings')
                terminal.wait_for(b'Settings')
                terminal.send(b'\r')
                terminal.wait_for(b'Unavailable')
                terminal.capture('live-library-unavailable')
                # Ctrl-C closes the layers, then two presses quit (letters type).
                for _ in range(8):
                    if terminal.status is not None:
                        break
                    terminal.send(b'\x03')
                    end = time.monotonic() + .3
                    while time.monotonic() < end and terminal.status is None:
                        terminal.pump()
                        if select.select([terminal.meta], [], [], 0)[0]:
                            terminal.status = int(terminal.meta.readline())
                terminal.finish()
            finally:
                terminal.close()


if __name__ == '__main__':
    unittest.main()
