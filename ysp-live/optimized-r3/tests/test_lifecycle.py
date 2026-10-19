import http.client
import json
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

from test_gateway import g, ROOT, URL

def free_port():
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0))
        return sock.getsockname()[1]

def get(port, path):
    conn = http.client.HTTPConnection('127.0.0.1', port, timeout=1)
    try:
        conn.request('GET', path)
        resp = conn.getresponse()
        return resp.status, resp.read()
    finally: conn.close()

class LifecycleTests(unittest.TestCase):
    def test_gateway_cli_zero_cache_playlist_diag_and_shutdown(self):
        port = free_port()
        with tempfile.TemporaryDirectory() as data_dir, tempfile.TemporaryFile() as logs:
            proc = subprocess.Popen([sys.executable, str(ROOT / 'ysp-live-v9.5.py'), str(port), '--bind', '127.0.0.1', '--no-4k', '--no-engine', '--cache-mb', '0', '--data-dir', data_dir], stdout=logs, stderr=logs)
            try:
                deadline = time.monotonic() + 5
                while True:
                    try: status, body = get(port, '/health'); break
                    except OSError:
                        if proc.poll() is not None or time.monotonic() > deadline:
                            logs.seek(0); self.fail(logs.read().decode())
                        time.sleep(.05)
                self.assertEqual(status, 200)
                self.assertEqual(json.loads(body)['ts_cache']['size_mb'], 0)
                self.assertIn(b'#EXTM3U', get(port, '/all.m3u')[1])
                self.assertEqual(get(port, '/diag')[0], 200)
                self.assertEqual(get(port, '/engine_proxy?url=http://127.0.0.1/')[0], 403)
                # A zero-sized cache should still successfully report its state.
                self.assertEqual(json.loads(body)['ts_cache']['count'], 0)
            finally:
                proc.terminate(); proc.wait(timeout=5)
            self.assertEqual(proc.returncode, 0)

    @unittest.skipUnless(__import__('shutil').which('node'), 'Node.js not installed')
    def test_engine_loopback_start_crash_restart_and_stop(self):
        port = free_port()
        with patch.object(g, 'log'):
            try:
                g.start_companion_engine(str(ROOT), port)
                self.assertTrue(g._engine_healthy(port))
                first = g.companion_proc
                self.assertIsNotNone(first)
                # Linux TCP table verifies the real listener is loopback only.
                if Path('/proc/net/tcp').exists():
                    matches = [line.split()[1] for line in Path('/proc/net/tcp').read_text().splitlines()[1:]
                               if line.split()[1].endswith(f':{port:04X}') and line.split()[3] == '0A']
                    self.assertEqual(matches, [f'0100007F:{port:04X}'])
                first.kill(); first.wait(timeout=3)
                deadline = time.monotonic() + 6
                while time.monotonic() < deadline:
                    if g.companion_proc is not first and g._engine_healthy(port): break
                    time.sleep(.05)
                self.assertIsNot(g.companion_proc, first)
                self.assertTrue(g._engine_healthy(port))
                last = g.companion_proc
            finally: g.stop_companion_engine()
            self.assertIsNotNone(last.poll())
            self.assertTrue(g._companion_stop.is_set())

if __name__ == '__main__': unittest.main()
