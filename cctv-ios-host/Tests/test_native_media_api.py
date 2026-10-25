import json
import pathlib
import platform
import subprocess
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit


@unittest.skipUnless(platform.system() == "Darwin", "requires macOS Foundation and QuartzCore")
class NativeMediaAPITests(unittest.TestCase):
    def test_tvbox_type_1_and_4_protocol_roundtrip(self):
        requests = []

        class Handler(BaseHTTPRequestHandler):
            def do_GET(self):
                parsed = urlsplit(self.path)
                query = parse_qs(parsed.query)
                requests.append((query, self.headers.get("X-Fixture"), self.headers.get("Host")))
                if query.get("wd") == ["fail"]:
                    payload = {"code": 0, "msg": "fixture denied"}
                elif query.get("wd") == ["empty"]:
                    payload = {"code": 0, "msg": "ok", "page": 1, "list": []}
                elif query.get("play") == ["web-episode"]:
                    payload = {"code": 1, "url": "https://resolver.example/watch?id=fixture", "parse": 1, "jx": 1}
                elif query.get("play"):
                    payload = {"code": 1, "playUrl": "https://cdn.example/", "url": ["标清", "low.m3u8", "高清", "high.m3u8"], "parse": 0, "header": {"X-Playback": "fixture"}, "UA": "FixtureUA/1"}
                elif query.get("ids"):
                    payload = {"code": 1, "list": [{"vod_id": "film-1", "vod_name": "Fixture film", "vod_play_from": "线路一$$$线路二", "vod_play_url": "第1集$episode-1$$$正片$feature.m3u8"}]}
                elif query.get("wd"):
                    payload = {"code": 1, "page": 2, "pagecount": 2, "list": [{"vod_id": "search-1", "vod_name": "Search fixture"}]}
                elif query.get("t"):
                    payload = {"code": 1, "total": 30, "limit": 10, "list": [{"vod_id": "category-1", "vod_name": "Category fixture"}]}
                else:
                    payload = {"code": 1, "data": {"class": [{"type_id": "movie", "type_name": "电影"}], "filters": {"movie": [{"key": "area", "name": "地区", "value": [{"n": "大陆", "v": "cn"}]}]}, "list": [{"vod_id": "home-1", "vod_name": "Home fixture", "vod_pic": "/poster.jpg"}]}}
                data = json.dumps(payload).encode()
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)

            def log_message(self, *args):
                pass

        server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        root = pathlib.Path(__file__).resolve().parents[1]
        try:
            with tempfile.TemporaryDirectory() as tmp:
                executable = str(pathlib.Path(tmp) / "native-media-api-tests")
                build = subprocess.run([
                    "xcrun", "clang", "-fobjc-arc", "-framework", "Foundation", "-framework", "QuartzCore",
                    "-I", str(root / "Sources"), str(root / "Tests" / "native_media_api_tests.m"),
                    str(root / "Sources" / "MediaAPIClient.m"), "-o", executable,
                ], capture_output=True, text=True)
                self.assertEqual(build.returncode, 0, build.stdout + build.stderr)
                result = subprocess.run([executable, str(server.server_port)], check=True, capture_output=True, text=True, timeout=30)
                self.assertIn("Native TVBox JSON API adapter tests passed", result.stderr + result.stdout)
            self.assertTrue(any(query.get("filter") == ["true"] for query, _, _ in requests), "type 4 home asks for filters")
            self.assertTrue(any(query.get("wd") == ["fixture"] and query.get("quick") == ["false"] and query.get("pg") == ["2"] for query, _, _ in requests))
            self.assertTrue(any(query.get("ac") == ["detail"] and query.get("t") == ["movie"] and query.get("pg") == ["1"] and query.get("area") == ["cn"] for query, _, _ in requests))
            self.assertTrue(any(query.get("ac") == ["detail"] and query.get("ids") == ["film-1"] for query, _, _ in requests))
            self.assertTrue(any(query.get("play") == ["episode-1"] and query.get("flag") == ["线路一"] for query, _, _ in requests))
            self.assertTrue(any(query.get("play") == ["web-episode"] and query.get("flag") == ["线路一"] for query, _, _ in requests))
            self.assertTrue(all(header == "header" for _, header, _ in requests), "source headers reach each API request")
            self.assertTrue(all(host.startswith("127.0.0.1:") for _, _, host in requests), "untrusted Host headers cannot override the API host")
            self.assertTrue(all(query.get("token") == ["fixture"] and query.get("extend") == ['{"region":"cn"}'] for query, _, _ in requests))
            self.assertEqual(len(requests), 8, "type 1 play is resolved locally and does not make an API request")
        finally:
            server.shutdown()
            server.server_close()


if __name__ == "__main__":
    unittest.main()
