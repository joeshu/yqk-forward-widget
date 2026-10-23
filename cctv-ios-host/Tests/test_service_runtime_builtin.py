"""Run the shipped service twice in one real Python process, without cloud access."""
from pathlib import Path
import subprocess
import sys
import unittest

ROOT = Path(__file__).resolve().parents[1]


class BuiltinSessionTests(unittest.TestCase):
    def test_builtin_stop_and_restart_in_same_interpreter(self):
        code = r'''
import http.client, socket, sys, tempfile, threading, time
sys.path.insert(0, sys.argv[1] + '/Scripts')
import host_service_runtime as runtime
script = sys.argv[1] + '/Plugins/ysp-live.py'
with tempfile.TemporaryDirectory() as data:
    for iteration in range(2):
        probe = socket.socket(); probe.bind(('127.0.0.1', 0)); port = probe.getsockname()[1]; probe.close()
        sys.argv = [script, str(port), '--bind', '127.0.0.1', '--no-engine', '--no-4k', '--data-dir', data, '--cache-mb', '0']
        runtime.configure_environment(data, port)
        errors = []
        def run():
            try: runtime.run_script(script)
            except BaseException as e: errors.append(repr(e))
        worker = threading.Thread(target=run, daemon=True); worker.start()
        end = time.monotonic() + 4
        while time.monotonic() < end:
            try:
                c = http.client.HTTPConnection('127.0.0.1', port, timeout=.3)
                c.request('GET', '/all.m3u'); response = c.getresponse(); body = response.read(); c.close()
                if response.status == 200 and body.startswith(b'#EXTM3U'): break
            except OSError: time.sleep(.02)
        else: raise AssertionError('service not ready: ' + repr(errors))
        assert runtime.stop_session(3), runtime.last_error()
        worker.join(1)
        assert not worker.is_alive() and runtime.is_idle() and not errors, errors
print('SEQUENTIAL_BUILTIN_OK')
'''
        result = subprocess.run([sys.executable, '-c', code, str(ROOT)], capture_output=True, text=True, timeout=15)
        self.assertEqual(result.returncode, 0, result.stdout[-2500:] + result.stderr[-2500:])
        self.assertIn('SEQUENTIAL_BUILTIN_OK', result.stdout)
