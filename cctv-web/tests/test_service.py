import importlib.util
import json
from pathlib import Path
import tempfile
import threading
import time
from types import SimpleNamespace
import unittest
import urllib.error
import urllib.request


spec = importlib.util.spec_from_file_location("cctv_web", Path(__file__).parents[1] / "cctv-web.py")
service = importlib.util.module_from_spec(spec)
spec.loader.exec_module(service)


class PlaylistTests(unittest.TestCase):
    def test_requires_real_complete_segments(self):
        with tempfile.TemporaryDirectory() as name:
            folder = Path(name)
            text = "#EXTM3U\n#EXT-X-TARGETDURATION:2\n#EXTINF:2,\nsegment_000000001.ts\n#EXTINF:2,\nsegment_000000002.ts\n"
            (folder / "index.m3u8").write_text(text)
            self.assertIsNone(service.valid_playlist(folder))
            for item in ("segment_000000001.ts", "segment_000000002.ts"):
                (folder / item).write_bytes(b"media")
            self.assertEqual(service.valid_playlist(folder), text)
            (folder / "index.m3u8").write_text(text.replace("segment_000000001.ts", "../secret.ts"))
            self.assertIsNone(service.valid_playlist(folder))

    def test_stale_playlist_is_not_ready(self):
        import os
        with tempfile.TemporaryDirectory() as name:
            folder = Path(name)
            (folder / "index.m3u8").write_text("#EXTM3U\n#EXTINF:2,\na.ts\n#EXTINF:2,\nb.ts\n")
            os.utime(folder / "index.m3u8", (time.time() - 60,) * 2)
            self.assertIsNone(service.valid_playlist(folder))

    def test_public_origin_validation(self):
        self.assertEqual(service.public_base("127.0.0.1:18768"), "http://127.0.0.1:18768")
        self.assertEqual(service.public_base("[::1]:18768"), "http://[::1]:18768")
        self.assertEqual(service.public_base("ignored", "https://example.test/tv/"), "https://example.test/tv")
        for host in ('bad"host', "a/b", "host:99999", "user@host", "host\r\nInjected: 1"):
            with self.subTest(host=host), self.assertRaises(ValueError):
                service.public_base(host)
        for base in ("file:///tmp", "https://u:p@host", "https://host/?token=secret", "https://host/#x"):
            with self.subTest(base=base), self.assertRaises(ValueError):
                service.public_base("", base)


class HttpTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.args = SimpleNamespace(data_dir=self.tmp.name, public_base_url="", startup_timeout=5, idle_timeout=30)
        self.app = service.App(self.args)
        self.requests = []
        self.app.channel.request = lambda start=True: self.requests.append(start)
        self.server = service.ThreadingHTTPServer(("127.0.0.1", 0), service.Handler)
        self.server.daemon_threads = True
        self.server.app = self.app
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.base = f"http://127.0.0.1:{self.server.server_port}"

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(2)
        self.app.close()
        self.tmp.cleanup()

    def get(self, path, method="GET", headers=None):
        req = urllib.request.Request(self.base + path, method=method, headers=headers or {})
        try:
            with urllib.request.urlopen(req, timeout=8) as response:
                return response.status, response.read(), response.headers
        except urllib.error.HTTPError as error:
            with error:
                return error.code, error.read(), error.headers

    def ready(self):
        channel = self.app.channel
        channel.generation = "a" * 32
        channel.folder = self.app.folder / "fixture"
        channel.folder.mkdir()
        channel.state = "ready"
        for i in (1, 2):
            (channel.folder / f"segment_{i:09d}.ts").write_bytes(b"test-ts" + bytes([i]))
        (channel.folder / "index.m3u8").write_text(
            "#EXTM3U\n#EXT-X-TARGETDURATION:2\n#EXTINF:2,\nsegment_000000001.ts\n"
            "#EXTINF:2,\nsegment_000000002.ts\n")

    def test_subscription_is_same_source_and_does_not_start_browser(self):
        status, body, headers = self.get("/all.m3u")
        self.assertEqual(status, 200)
        self.assertEqual(body.count(b"#EXTINF:"), 1)
        self.assertIn((self.base + "/cctv2.m3u8").encode(), body)
        self.assertEqual(self.requests, [])
        self.assertIsNone(self.app.browser)

    def test_head_does_not_start_or_record_demand(self):
        status, body, _ = self.get("/cctv2.m3u8", method="HEAD")
        self.assertEqual((status, body), (200, b""))
        self.assertEqual(self.requests, [])

    def test_playlist_and_media_routes_use_generation(self):
        self.ready()
        status, body, _ = self.get("/cctv2.m3u8")
        self.assertEqual(status, 200)
        uri = next(x for x in body.decode().splitlines() if x and not x.startswith("#"))
        self.assertTrue(uri.startswith("media/cctv2/" + "a" * 32))
        status, body, headers = self.get("/" + uri)
        self.assertEqual((status, body), (200, b"test-ts\x01"))
        self.assertEqual(headers["Content-Type"], "video/mp2t")
        self.assertEqual(self.requests, [True, False])
        self.assertEqual(self.get("/" + uri.replace("a" * 32, "b" * 32))[0], 410)

    def test_failure_is_503_without_fake_media(self):
        self.app.channel.state, self.app.channel.error = "error", "media-stalled"
        status, body, headers = self.get("/cctv2.m3u8")
        self.assertEqual(status, 503)
        self.assertEqual(headers["Retry-After"], "3")
        self.assertEqual(json.loads(body)["error"], "media-stalled")

    def test_status_has_no_upstream_addresses(self):
        status, body, _ = self.get("/status")
        self.assertEqual(status, 200)
        self.assertFalse(json.loads(body)["media_ready"])
        self.assertNotIn(b"http", body)
        self.assertEqual(self.requests, [])

    def test_unknown_paths_and_methods(self):
        self.assertEqual(self.get("/other.m3u8")[0], 404)
        self.assertEqual(self.get("/media/cctv2/" + "a" * 32 + "/../encoder.log")[0], 404)
        self.assertEqual(self.get("/all.m3u", method="POST")[0], 405)
        self.assertEqual(self.get("/all.m3u", headers={"Host": 'bad"host'})[0], 400)


class CleanupTests(unittest.TestCase):
    def test_disconnected_browser_still_stops_runtime_and_cleans_files(self):
        stopped = []
        class Browser:
            async def close(self):
                raise RuntimeError("connection already closed")
        class Runtime:
            async def stop(self):
                stopped.append(True)
        with tempfile.TemporaryDirectory() as name:
            app = service.App(SimpleNamespace(data_dir=name))
            folder = app.folder
            app.browser, app.playwright = Browser(), Runtime()
            app.close()
            self.assertEqual(stopped, [True])
            self.assertTrue(app.loop.is_closed())
            self.assertFalse(folder.exists())


if __name__ == "__main__":
    unittest.main()
