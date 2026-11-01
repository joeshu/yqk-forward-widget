import pathlib
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


@unittest.skipUnless(sys.platform == "darwin", "Foundation tests require macOS")
class NativeProfiles(unittest.TestCase):
    def test_profiles_backup_xmltv_and_cancellation(self):
        requests = []
        class Handler(BaseHTTPRequestHandler):
            def do_GET(self):
                requests.append(self.path)
                if self.path == "/tvbox-start":
                    self.send_response(302)
                    self.send_header("Location", "/configs/easytv.jpg")
                    self.end_headers()
                    return
                if self.path == "/configs/easytv.jpg":
                    body = b'{"name":"Easy TVBox","sites":[{"key":"mac","name":"MacCMS","api":"api.php/provide/vod/","type":0}]}'
                    self.send_response(200)
                    self.send_header("Content-Type", "application/json")
                    self.send_header("Content-Length", str(len(body)))
                    self.end_headers()
                    self.wfile.write(body)
                    return
                if "slow" in self.path:
                    time.sleep(1)
                body = b'<tv><programme channel="cctv1" start="20261023120000 +0800" stop="20261023130000 +0800"><title>News</title></programme></tv>'
                self.send_response(200)
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                try:
                    self.wfile.write(body)
                except (BrokenPipeError, ConnectionResetError):
                    pass
            def log_message(self, *args):
                pass
        server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        root = pathlib.Path(__file__).parents[1]
        try:
            with tempfile.TemporaryDirectory() as tmp:
                exe = str(pathlib.Path(tmp) / "native-profiles")
                command = ["xcrun", "clang", "-fobjc-arc", "-framework", "Foundation", "-lz", "-I", str(root / "Sources")]
                command += [str(root / "Tests/native_profile_tests.m")]
                command += [str(root / "Sources" / f) for f in ("M3UParser.m", "ProfileStore.m", "HostBackup.m", "XMLTVStore.m", "TVBoxCatalogStore.m", "TVBoxCatalogDownloader.m")]
                command += ["-o", exe]
                result = subprocess.run(command, capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                result = subprocess.run([exe, f"http://127.0.0.1:{server.server_port}/guide.xml", f"http://127.0.0.1:{server.server_port}/tvbox-start"], capture_output=True, text=True, timeout=20)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(requests.count("/guide.xml"), 1, "cache should prevent a second download")
        finally:
            server.shutdown()
            server.server_close()
