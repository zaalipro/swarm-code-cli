#!/usr/bin/env python3
"""Exercise launcher environment precedence without providers or user storage."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
LAUNCHERS = [ROOT / 'scripts/dev' / f'run_{kind}_session.sh'
             for kind in ('live', 'saved', 'plain')]


class LauncherEnvironment(unittest.TestCase):
    def launch(self, secret_text, overrides, expected):
        with tempfile.TemporaryDirectory(prefix='swarm-env-') as temporary:
            fixture = Path(temporary)
            secrets = fixture / 'provider.env'
            secrets.write_text(secret_text)
            # Only replace the VM boundary. Run the real launcher's shell logic.
            # Report equality, never values, even if a loader accidentally reads
            # the user's actual credentials instead of this disposable fixture.
            mise = fixture / 'mise'
            mise.write_text('''#!/usr/bin/env python3
import json, os
expected = json.loads(os.environ['SWARM_TEST_EXPECTED'])
print(json.dumps({key: os.environ.get(key) == value for key, value in expected.items()}))
''')
            mise.chmod(0o700)
            env = {key: value for key, value in os.environ.items()
                   if not key.startswith(('SWARM_', 'OPENAI_', 'ANTHROPIC_'))}
            env.update(PATH=str(fixture) + os.pathsep + env['PATH'],
                       SWARM_ENV_FILE=str(secrets),
                       SWARM_TEST_EXPECTED=json.dumps(expected))
            env.update(overrides)
            for launcher in LAUNCHERS:
                with self.subTest(launcher=launcher.name):
                    result = subprocess.run(['bash', str(launcher)], env=env, cwd=ROOT,
                                            capture_output=True, text=True, timeout=10)
                    self.assertEqual(result.returncode, 0, 'launcher exited unsuccessfully')
                    matches = json.loads(result.stdout)
                    self.assertTrue(all(matches.values()),
                                    'incorrect environment keys: ' + ', '.join(
                                        key for key, equal in matches.items() if not equal))

    def test_private_file_supplies_missing_settings(self):
        self.launch('OPENAI_API_KEY=fixture-key\nSWARM_MODEL=fixture-model\n', {},
                    {'OPENAI_API_KEY': 'fixture-key', 'SWARM_MODEL': 'fixture-model'})

    def test_explicit_model_endpoint_and_project_survive_loading_credentials(self):
        self.launch('OPENAI_API_KEY=fixture-key\nSWARM_MODEL=file-model\n'
                    'SWARM_BASE_URL=https://file.invalid/v1\nSWARM_PROJECT_ROOT=/file/project\n',
                    {'SWARM_MODEL': 'shell-model', 'SWARM_BASE_URL': 'http://localhost:4321/v1',
                     'SWARM_PROJECT_ROOT': '/shell/project'},
                    {'OPENAI_API_KEY': 'fixture-key', 'SWARM_MODEL': 'shell-model',
                     'SWARM_BASE_URL': 'http://localhost:4321/v1',
                     'SWARM_PROJECT_ROOT': '/shell/project'})

    def test_explicit_empty_key_keeps_local_server_credentials_empty(self):
        self.launch('SWARM_API_KEY=fixture-key\nSWARM_MODEL=file-model\n',
                    {'SWARM_API_KEY': '', 'SWARM_MODEL': 'local-model'},
                    {'SWARM_API_KEY': '', 'SWARM_MODEL': 'local-model'})

    def test_exported_provider_key_skips_private_file(self):
        self.launch('OPENAI_API_KEY=file-key\nSWARM_MODEL=file-model\n',
                    {'OPENAI_API_KEY': 'shell-key', 'SWARM_MODEL': 'shell-model'},
                    {'OPENAI_API_KEY': 'shell-key', 'SWARM_MODEL': 'shell-model'})


if __name__ == '__main__':
    unittest.main()
