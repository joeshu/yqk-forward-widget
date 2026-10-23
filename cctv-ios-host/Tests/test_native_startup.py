import http.server
import json
import pathlib
import platform
import subprocess
import tempfile
import threading
import unittest


class ReadinessFixture(http.server.BaseHTTPRequestHandler):
    attempts = 0

    def log_message(self, *_):
        pass

    def do_GET(self):
        if self.path == "/ready":
            type(self).attempts += 1
            attempt = type(self).attempts
            self.send_response(503 if attempt == 1 else 200)
            data = json.dumps({"ok": attempt >= 3}).encode()
        else:
            self.send_response(503)
            data = b'{"ok":false}'
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        try:
            self.wfile.write(data)
        except (BrokenPipeError, ConnectionResetError):
            pass


@unittest.skipUnless(platform.system() == "Darwin", "requires macOS Foundation/QuartzCore")
class NativeStartupTests(unittest.TestCase):
    def test_health_deadline_cancellation_and_true_frame_stages(self):
        root = pathlib.Path(__file__).resolve().parents[1]
        ReadinessFixture.attempts = 0
        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), ReadinessFixture)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            with tempfile.TemporaryDirectory() as tmp:
                exe = str(pathlib.Path(tmp) / "cctv-startup-tests")
                subprocess.run([
                    "xcrun", "clang", "-fobjc-arc", "-framework", "Foundation",
                    "-framework", "QuartzCore", "-I", str(root / "Sources"),
                    str(root / "Tests" / "native_startup_tests.m"),
                    str(root / "Sources" / "LocalServiceReadiness.m"),
                    str(root / "Sources" / "PlaybackStartupTrace.m"), "-o", exe,
                ], check=True, capture_output=True, text=True)
                subprocess.run([exe, str(server.server_port)], check=True,
                               capture_output=True, text=True, timeout=15)
                self.assertGreaterEqual(ReadinessFixture.attempts, 3)
        finally:
            server.shutdown()
            server.server_close()
            thread.join(timeout=2)
