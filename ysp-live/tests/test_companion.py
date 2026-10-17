"""Start the real Python/Node pair without requesting any channel or live upstream."""
from __future__ import annotations

import contextlib
import http.client
import json
import os
from pathlib import Path
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import time
import unittest


ROOT = Path(__file__).resolve().parents[1]


def port_open(port):
    with socket.socket() as probe:
        probe.settimeout(0.2)
        return probe.connect_ex(("127.0.0.1", port)) == 0


def read_json(port, path):
    with contextlib.closing(http.client.HTTPConnection("127.0.0.1", port, timeout=0.6)) as connection:
        connection.request("GET", path, headers={"Connection": "close"})
        response = connection.getresponse()
        return response.status, json.loads(response.read())


@unittest.skipUnless(shutil.which("node"), "the companion process needs Node")
@unittest.skipUnless(os.name == "posix", "this process lifecycle test verifies POSIX SIGTERM")
class CompanionProcessSmokeTests(unittest.TestCase):
    def test_real_companion_starts_identifies_itself_and_stops_with_python(self):
        # Hold both reservations together so the selected ports are distinct.
        with socket.socket() as python_socket, socket.socket() as node_socket:
            python_socket.bind(("127.0.0.1", 0))
            node_socket.bind(("127.0.0.1", 0))
            python_port = python_socket.getsockname()[1]
            node_port = node_socket.getsockname()[1]
        with tempfile.TemporaryDirectory() as temp:
            logfile = Path(temp) / "process.log"
            env = dict(os.environ, PYTHONUNBUFFERED="1", NO_PROXY="127.0.0.1,localhost",
                       no_proxy="127.0.0.1,localhost")
            # An inherited access token should not affect an unauthenticated liveness check.
            with logfile.open("w", encoding="utf-8") as output:
                process = subprocess.Popen(
                    [sys.executable, str(ROOT / "ysp-live-v9.5.8.py"), str(python_port),
                     "--bind", "127.0.0.1", "--no-4k", "--no-epg", "--cache-mb", "0",
                     "--engine-port", str(node_port), "--data-dir", temp],
                    cwd=ROOT, env=env, stdout=output, stderr=subprocess.STDOUT,
                    start_new_session=True,
                )
                try:
                    deadline = time.monotonic() + 10
                    while True:
                        if process.poll() is not None:
                            self.fail("Python exited during startup:\n" + logfile.read_text())
                        try:
                            status, alive = read_json(python_port, "/livez")
                            self.assertEqual(status, 200)
                            self.assertTrue(alive["ok"])
                            break
                        except (OSError, http.client.HTTPException):
                            if time.monotonic() >= deadline:
                                self.fail("Python did not become live:\n" + logfile.read_text())
                            time.sleep(0.05)

                    status, detail = read_json(node_port, "/health")
                    self.assertEqual(status, 503)  # No channel has been requested yet.
                    self.assertEqual(detail["engine"], "ysp-engine")
                    self.assertFalse(detail["ready"])
                    self.assertEqual(detail["channels"], 0)
                    self.assertEqual(detail["activeRequests"], 0)
                    self.assertEqual(detail["upstream"], {"active": 0, "queued": 0})
                    status, alive = read_json(node_port, "/livez")
                    self.assertEqual(status, 200)
                    self.assertTrue(alive["alive"])

                    process.send_signal(signal.SIGTERM)
                    process.wait(timeout=8)
                    self.assertEqual(process.returncode, 0, logfile.read_text())
                    deadline = time.monotonic() + 3
                    while (port_open(python_port) or port_open(node_port)) and time.monotonic() < deadline:
                        time.sleep(0.05)
                    self.assertFalse(port_open(python_port), "Python still accepts connections after exit")
                    self.assertFalse(port_open(node_port), "Node companion survived the parent's SIGTERM")
                finally:
                    # Keep a failed smoke test from leaving an orphaned companion.
                    if process.poll() is None or port_open(python_port) or port_open(node_port):
                        try:
                            os.killpg(process.pid, signal.SIGTERM)
                        except ProcessLookupError:
                            pass
                        try:
                            process.wait(timeout=3)
                        except subprocess.TimeoutExpired:
                            pass
                        if process.poll() is None or port_open(node_port):
                            try:
                                os.killpg(process.pid, signal.SIGKILL)
                            except ProcessLookupError:
                                pass
                            process.wait(timeout=3)


if __name__ == "__main__":
    unittest.main()
