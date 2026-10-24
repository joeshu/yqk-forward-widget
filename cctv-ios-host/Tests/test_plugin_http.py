import builtins
import http.client
import http.server
import importlib.util
from pathlib import Path
import sys
import threading
import time
import unittest
from unittest.mock import Mock, patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("cctv_embedded_plugin", ROOT / "Plugins/ysp-live.py")
plugin = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = plugin
previous_stop = getattr(builtins, "_ysp_stop_server", None)
with patch("urllib.request.install_opener"), patch("atexit.register"):
    spec.loader.exec_module(plugin)
if previous_stop is None:
    del builtins._ysp_stop_server
else:
    builtins._ysp_stop_server = previous_stop


def playlist(sequence):
    return (f"#EXTM3U\n#EXT-X-TARGETDURATION:1\n#EXT-X-MEDIA-SEQUENCE:{sequence}\n"
            f"#EXTINF:1,\nhttp://example.invalid/{sequence}.ts\n")


class PluginHTTPTests(unittest.TestCase):
    def setUp(self):
        self.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), plugin.Handler)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=2)

    def request(self, path, method="GET"):
        conn = http.client.HTTPConnection("127.0.0.1", self.server.server_port, timeout=3)
        try:
            conn.request(method, path)
            response = conn.getresponse()
            return response.status, response.read().decode(), dict(response.getheaders())
        finally:
            conn.close()

    def test_feed_aliases_and_head_are_valid_without_media_engine(self):
        for path in ["/all.m3u", "/m3u", "/all.m3u8"]:
            status, text, headers = self.request(path)
            self.assertEqual(status, 200)
            self.assertTrue(text.startswith("#EXTM3U"))
            self.assertGreater(text.count("#EXTINF:"), 20)
            self.assertIn(f"http://127.0.0.1:{self.server.server_port}/cctv1.m3u8", text)
            self.assertEqual(int(headers["Content-Length"]), len(text.encode()))
            status, body, _ = self.request(path, "HEAD")
            self.assertEqual((status, body), (200, ""))

    def channel(self):
        ch = plugin.Channel(*next(c for c in plugin.DEFAULT_CHANNELS if c[0] == "cctv1"))
        ch.mode = "bk"
        ch.last_access = time.time()
        ch.last_m3u8_source = "bk"
        ch.bk_playlist = playlist(1001)
        ch.last_built_playlist = playlist(1000)
        ch.last_built_time = time.time() - 2
        return ch

    def test_short_live_playlist_advances_instead_of_15_second_cached_window(self):
        ch = self.channel()
        with patch.object(plugin, "get_channel_instance", return_value=ch), \
             patch.object(plugin, "resolver_ready", return_value=False), \
             patch.object(plugin, "ensure_channel"):
            status, body, _ = self.request("/cctv1.m3u8")
        self.assertEqual(status, 200)
        self.assertIn("MEDIA-SEQUENCE:1001", body)
        self.assertNotIn("MEDIA-SEQUENCE:1000", body)
        self.assertEqual(plugin.playlist_reload_interval(body), .5)
        self.assertEqual(plugin.playlist_reload_interval("#EXT-X-TARGETDURATION:20"), 3)

    def test_active_fallback_is_not_upgraded_to_incompatible_sequence_space(self):
        ch = self.channel()
        resolver = Mock()
        resolver.is_channel_in_cooldown.return_value = False
        resolver.fetch_channel_playlist.return_value = playlist(1)
        with patch.object(plugin, "get_channel_instance", return_value=ch), \
             patch.object(plugin, "resolver_ready", return_value=True), \
             patch.object(plugin, "resolver", resolver), \
             patch.object(plugin, "stable_playback", True), \
             patch.object(plugin, "ensure_channel"):
            status, body, _ = self.request("/cctv1.m3u8")
        self.assertEqual(status, 200)
        self.assertIn("MEDIA-SEQUENCE:1001", body)
        resolver.fetch_channel_playlist.assert_not_called()

    def test_new_view_can_use_device_source_after_idle_session_expires(self):
        ch = self.channel()
        ch.last_access = time.time() - plugin.IDLE_TIMEOUT - 1
        resolver = Mock()
        resolver.is_channel_in_cooldown.return_value = False
        resolver.fetch_channel_playlist.return_value = playlist(1)
        with patch.object(plugin, "get_channel_instance", return_value=ch), \
             patch.object(plugin, "resolver_ready", return_value=True), \
             patch.object(plugin, "resolver", resolver), \
             patch.object(plugin, "stable_playback", True):
            status, body, _ = self.request("/cctv1.m3u8")
        self.assertEqual(status, 200)
        self.assertIn("MEDIA-SEQUENCE:1", body)
        resolver.fetch_channel_playlist.assert_called_once()

    def test_engine_proxy_keeps_independent_response_limit(self):
        response = Mock()
        response.status = 200
        response.read.return_value = b"segment"
        response.headers = {"Content-Type": "video/mp2t"}
        context = Mock()
        context.__enter__ = Mock(return_value=response)
        context.__exit__ = Mock(return_value=False)
        with patch.object(plugin, "_is_safe_engine_proxy_url", return_value=True), \
             patch.object(plugin.urllib.request, "urlopen", return_value=context):
            status, body, _ = self.request("/engine_proxy?url=http%3A%2F%2F127.0.0.1%3A8787%2Fa.ts")
        self.assertEqual((status, body), (200, "segment"))
