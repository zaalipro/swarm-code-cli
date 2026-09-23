#!/usr/bin/env python3
"""Guarded new-database + saved TUI restart smoke; disposable _build paths only."""
import http.server
import json
import os
from pathlib import Path
import re
import shlex
import sqlite3
import subprocess
import tempfile
import threading
import unittest
from test_terminal_demo_pty import Demo, ROOT

OVERRIDES = ('SWARM_PROVIDER SWARM_MODEL SWARM_BASE_URL OPENAI_MODEL ANTHROPIC_MODEL '
             'OPENAI_BASE_URL ANTHROPIC_BASE_URL OPENAI_API_KEY ANTHROPIC_API_KEY SWARM_API_KEY '
             'SWARM_CONVERSATION SWARM_PERSISTED')


class SavedSession(unittest.TestCase):
    def test_saved_prompt_response_and_provider_resume_on_second_vm(self):
        requests = []

        class Provider(http.server.BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def do_POST(self):
                body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
                requests.append(body)
                event = {'choices': [{'delta': {'content': 'Saved terminal verified.'},
                                      'finish_reason': 'stop'}]}
                payload = ('data: ' + json.dumps(event) + '\n\n').encode()
                self.send_response(200)
                self.send_header('Content-Type', 'text/event-stream')
                self.send_header('Content-Length', str(len(payload)))
                self.end_headers()
                self.wfile.write(payload)

        server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Provider)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        fixture_parent = ROOT / '_build/saved-session-pty'
        fixture_parent.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(prefix='fixture-', dir=fixture_parent) as temporary:
            fixture = Path(temporary)
            storage = fixture / 'storage'
            project = fixture / 'project'
            storage.mkdir(mode=0o700)
            project.mkdir()
            subprocess.run(['git', 'init', '-q', str(project)], check=True)
            runner = fixture / 'trusted_runner.exs'
            # Direct test-only function call: production has no database path
            # option/env fallback. Test storage is never the user's home.
            runner.write_text('''
Code.require_file("scripts/dev/persisted_session.exs")
root = %s
Application.put_env(:swarm_code_daemon, :domain_config_dir, Path.join(root, "config"))
boot = [platform: :linux, mode: :test, home: root,
  env: Map.new(~w(XDG_DATA_HOME XDG_CONFIG_HOME XDG_STATE_HOME XDG_CACHE_HOME XDG_RUNTIME_DIR), &{&1, root}),
  database_path: Path.join(root, "swarm_code.db"), app_version: "0.1.0-dev",
  desktop_detector: fn -> :none end,
  directory_ensure: fn path, owner ->
    case File.mkdir(path) do
      :ok -> File.chmod!(path, 0o700)
      {:error, :eexist} -> :ok
    end
    SwarmCode.Daemon.Platform.PrivateDirectory.ensure(path, owner)
  end,
  identity: fn -> {:ok, %%SwarmCode.Daemon.Platform.ProcessIdentity{
    uid: File.stat!(root).uid, pid: String.to_integer(System.pid()),
    process_start_id: "saved-pty", boot_id: "saved-pty"}} end]
SwarmCode.Development.PersistedSession.run_for_test(boot)
''' % json.dumps(str(storage)))
            wrappers = []
            for phase in range(2):
                wrapper = fixture / f'launch-{phase}.sh'
                shell = ['#!/usr/bin/env bash', 'set -euo pipefail', 'unset ' + OVERRIDES,
                         'export MIX_ENV=test', 'export SWARM_PROJECT_ROOT=' + shlex.quote(str(project))]
                if phase == 0:
                    shell += ['export SWARM_PROVIDER=openai', 'export SWARM_MODEL=pty-fixture',
                              'export SWARM_BASE_URL=' + shlex.quote(f'http://127.0.0.1:{server.server_port}/v1'),
                              'export SWARM_API_KEY=fixture', 'export SWARM_CONVERSATION=new']
                shell += ['exec mise exec -- elixir --erl "-noinput" -S mix run --no-start ' + shlex.quote(str(runner))]
                wrapper.write_text('\n'.join(shell) + '\n')
                wrappers.append(wrapper)

            conversation_ids = []
            for phase, wrapper in enumerate(wrappers):
                terminal = Demo(launcher=wrapper)
                try:
                    terminal.wait_for(b'Focus: composer', timeout=120)
                    # The SAVED · DEV launcher banner is the title lead only until
                    # the workspace snapshot arrives; shell.ex then leads with
                    # the project name, so wait for the actually-rendered banner
                    # (phase 0 starts in Build mode, phase 1 resumes in Plan).
                    mode = 'Build' if phase == 0 else 'Plan'
                    terminal.wait_for(f'project · {mode} · pty-fixture'.encode())
                    self.assertNotIn(b'FAKE', terminal.screen())
                    terminal.descendants()
                    match = re.search(rb'conversation ([0-9a-f-]{36})', terminal.output)
                    self.assertIsNotNone(match)
                    conversation_ids.append(match.group(1))
                    if phase == 0:
                        terminal.send(b'\x1b[200~Remember saved terminal\x1b[201~')
                        terminal.wait_for(b'Remember saved terminal')
                        terminal.send(b'\r')
                    else:
                        terminal.wait_for(b'Remember saved terminal')
                    terminal.wait_for(b'Saved terminal verified.', timeout=30)
                    terminal.capture(f'saved-session-{phase}')
                    self.assertEqual(terminal.screen().count(b'Saved terminal verified.'), 1)
                    if phase == 0:
                        terminal.send(b'\x1b[200~/goal\x1b[201~\r')
                        terminal.wait_for(b'Conversation goal')
                        terminal.wait_for(b'No goal is set')
                        terminal.capture('saved-goal-report')
                        terminal.send(b'\x1b')
                        terminal.wait_for(b'Focus: composer')
                        terminal.send(b'\x1b[200~/plan\x1b[201~\r')
                        terminal.wait_for(b'Plan mode enabled')
                        terminal.wait_for('project · Plan · pty-fixture'.encode())
                        terminal.capture('saved-plan-mode')
                        terminal.send(b'\x1b[200~/rewind\x1b[201~\r')
                        terminal.wait_for(b'Checkpoints')
                        terminal.send(b'\x1b')
                        terminal.wait_for(b'Focus: composer')
                        terminal.send(b'\x1b')
                        terminal.wait_for(b'Focus: main')
                        # Shift-Tab used to walk focus to the (since-removed)
                        # navigator dock; the focus graph is now main, inspector
                        # and composer only, so Shift-Tab from main wraps to the
                        # composer's editor.
                        terminal.send(b'\x1b[Z')
                        terminal.wait_for(b'Focus: composer')
                        terminal.send(b'\x1b')
                        terminal.wait_for(b'Focus: main')
                        terminal.wait_for(b'Saved terminal verified.')
                        terminal.capture('saved-run-navigation')
                        self.assertNotIn(b'Page error', terminal.screen())
                        terminal.send(b'\x1b')
                        terminal.wait_for('project · Plan · pty-fixture'.encode())
                    # q is text while the composer is focused; leave the editor
                    # first, matching the footer's explicit Esc Back hint.
                    if b'Focus: composer' in terminal.screen():
                        terminal.send(b'\x1b')
                        terminal.wait_for(b'Focus: main')
                    terminal.send(b'q')
                    terminal.finish()
                    # A clean close is silent; a bounded, unconfirmed one says so.
                    self.assertNotIn(b'handle still pending', terminal.output)
                finally:
                    terminal.close()

            self.assertEqual(conversation_ids[0], conversation_ids[1])
            self.assertGreaterEqual(len(requests), 1)
            self.assertEqual(requests[0]['model'], 'pty-fixture')
            self.assertTrue(any(m.get('content') == 'Remember saved terminal'
                                for m in requests[0]['messages']))
            database = sqlite3.connect(f'file:{storage / "swarm_code.db"}?mode=ro', uri=True)
            with database:
                messages = database.execute('SELECT content FROM messages ORDER BY position').fetchall()
                self.assertIn(('Remember saved terminal',), messages)
                self.assertIn(('Saved terminal verified.',), messages)
                self.assertEqual(database.execute('SELECT count(*) FROM conversations').fetchone()[0], 1)
                self.assertEqual(database.execute('SELECT count(*) FROM schema_migrations').fetchone()[0], 46)
            database.close()


if __name__ == '__main__':
    unittest.main()
