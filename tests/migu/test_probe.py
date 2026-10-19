import importlib.util
from pathlib import Path
import threading
import unittest
from unittest.mock import patch

import update_migu as m

spec = importlib.util.spec_from_file_location("migu_probe", Path("migu/probe.py"))
probe = importlib.util.module_from_spec(spec)
spec.loader.exec_module(probe)
BASE = "https://hlszymgsplive.miguvideo.com/a/master.m3u8?token=keep-private"


class ProbeTests(unittest.TestCase):
    def test_relative_child_uses_final_redirect_location_without_copying_query(self):
        kind, urls = probe.hls_references(b"#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1000\nchild/index.m3u8\n", BASE)
        self.assertEqual(kind, "master")
        self.assertEqual(urls, ["https://hlszymgsplive.miguvideo.com/a/child/index.m3u8"])

    def test_media_playlist_needs_real_segment_references(self):
        kind, urls = probe.hls_references(b"#EXTM3U\n#EXT-X-TARGETDURATION:6\n#EXTINF:6,\n001.ts\n", BASE)
        self.assertEqual(kind, "media")
        self.assertEqual(len(urls), 1)
        for raw in (b"<html>ok</html>", b"#EXTM3U\n", b"#EXTM3U\n#EXTINF:6,\n001.ts\n", b"#EXTM3U\n#EXT-X-TARGETDURATION:6\n#EXTINF:6,\n", b"#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1000\nfile:///etc/passwd\n"):
            with self.assertRaises(m.UpdateError):
                probe.hls_references(raw, BASE)

    def test_master_200_child_661_is_not_reported_as_playable(self):
        channel = m.Channel("id", "name", "name", "group", "", BASE, m.utcnow())
        client = m.HttpClient("media")
        client.last_url = BASE
        with patch.object(probe.m, "HttpClient", return_value=client), patch.object(client, "get", side_effect=[(b"#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1000\nchild.m3u8\n", {}), m.FetchError("HTTP_661")]):
            result = probe.probe_channel(channel, threading.Event())
        self.assertFalse(result["media_manifest_accessible"])
        self.assertTrue(result["entry_manifest_accessible"])
        self.assertEqual(result["error"], "HTTP_661")
        self.assertEqual(result["stage"], "child_manifest")
        self.assertEqual(result["requests"], 2)

    def test_full_probe_resolves_relative_child_against_effective_cdn_url(self):
        entry = "http://gslbmgsplive.miguvideo.com/a/master.m3u8?token=entry"
        final = "http://hlszymgsplive.miguvideo.com:8080/a/master.m3u8?token=entry"
        expected = "http://hlszymgsplive.miguvideo.com:8080/a/child.m3u8"
        channel = m.Channel("id", "name", "name", "group", "", entry, m.utcnow())
        client = m.HttpClient("media")
        calls = []

        def fetch(url, **kwargs):
            calls.append(url)
            if len(calls) == 1:
                self.assertEqual(url, entry)
                client.last_url = final
                return b"#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1000\nchild.m3u8\n", {}
            self.assertEqual(url, expected)
            client.last_url = expected
            return b"#EXTM3U\n#EXT-X-TARGETDURATION:6\n#EXTINF:6,\n001.ts\n", {}

        with patch.object(probe.m, "HttpClient", return_value=client), patch.object(client, "get", side_effect=fetch):
            result = probe.probe_channel(channel, threading.Event())
        self.assertTrue(result["media_manifest_accessible"])
        self.assertFalse(result["video_decoded"])
        self.assertEqual(len(calls), 2)  # No video segment or key requests.

    def test_limiter_stops_queued_work_after_429(self):
        channel = m.Channel("id", "name", "name", "group", "", BASE, m.utcnow())
        stop = threading.Event()
        stop.set()
        with patch.object(probe.m, "HttpClient") as client:
            result = probe.probe_channel(channel, stop)
            client.assert_not_called()
        self.assertEqual(result["error"], "SKIPPED_AFTER_RATE_LIMIT")


if __name__ == "__main__":
    unittest.main()
