"""Exercise real HTTP and channel refresh threads without any public upstream.

The v9.5.15 control demonstrates how speculative backup warming can occupy
every shared refresh slot even though the player uses the device source.
"""
import contextlib
import http.client
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import importlib.util
from pathlib import Path
import sys
import threading
import time
import unittest
import uuid


ROOT = Path(__file__).resolve().parents[1]


def playlist(origin, sequence=1):
    return ('#EXTM3U\n#EXT-X-TARGETDURATION:6\n'
            '#EXT-X-MEDIA-SEQUENCE:%s\n#EXTINF:6,\n%s/segment.ts\n'
            % (sequence, origin))


class LocalPlayback:
    def __init__(self, version='9.5.16', device_channels=(), slow_channels=()):
        name = 'ysp_real_loop_' + uuid.uuid4().hex
        spec = importlib.util.spec_from_file_location(name, ROOT / ('ysp-live-v' + version + '.py'))
        self.live = importlib.util.module_from_spec(spec)
        sys.modules[name] = self.live
        spec.loader.exec_module(self.live)
        self.module_name = name
        self.release = threading.Event()
        self.requests = []
        self.request_lock = threading.Lock()
        self.slow_channels = set(slow_channels)
        self.device_channels = set(device_channels)
        harness = self

        class Origin(BaseHTTPRequestHandler):
            def do_GET(self):
                slug = self.path.split('/')[1]
                with harness.request_lock:
                    harness.requests.append(slug)
                    sequence = len(harness.requests)
                if slug in harness.slow_channels and not harness.release.wait(10):
                    self.send_error(504)
                    return
                body = playlist('http://127.0.0.1:' + str(self.server.server_port), sequence).encode()
                self.send_response(200)
                self.send_header('Content-Type', 'application/vnd.apple.mpegurl')
                self.send_header('Content-Length', str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def log_message(self, *_):
                pass

        self.origin = ThreadingHTTPServer(('127.0.0.1', 0), Origin)
        self.origin_thread = threading.Thread(target=self.origin.serve_forever, daemon=True)
        self.origin_thread.start()
        base = 'http://127.0.0.1:' + str(self.origin.server_port)
        live = self.live
        live.engine_enabled = False
        live.epg_manager = None
        live.media_probe_manager = None
        live.global_flow_limiter = live.ApiFlowLimiter(0, 0)
        live.jce_timeshift_url = lambda _pid, sid, *_args, **_kwargs: base + '/' + sid + '/index.m3u8'
        def forbid_public_fallback(*_args, **_kwargs):
            raise AssertionError('this regression test must not contact a public backup API')
        live.bk_playurls = forbid_public_fallback
        live.CHANNEL_MAP = {
            'cctv' + str(i): live.Channel('cctv' + str(i), 'Test ' + str(i), 'cctv' + str(i), 'pid', 'best')
            for i in range(1, 10)
        }

        class Backend:
            def is_channel_in_cooldown(self, _channel):
                return False

            def has_cached_channel_playlist(self, _channel):
                return False

            def fetch_channel_playlist_bounded(self, channel, *_args, **_kwargs):
                return playlist(base) if channel in harness.device_channels else None

            fetch_channel_playlist = fetch_channel_playlist_bounded

            def note_channel_interest(self, _channel):
                pass

        live.resolver = Backend()
        live.active_backend_channels = set(live.CHANNEL_MAP)
        live.set_resolver_ready(True)
        self.server = live.BoundedHTTPServer(('127.0.0.1', 0), live.Handler)
        self.server.access_token = ''
        self.server.trust_proxy = False
        self.server.public_base_url = ''
        self.server_thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.server_thread.start()

    def request(self, channel):
        with contextlib.closing(http.client.HTTPConnection(
                '127.0.0.1', self.server.server_port, timeout=3)) as connection:
            connection.request('GET', '/' + channel + '.m3u8')
            response = connection.getresponse()
            return response.status, response.getheader('X-Source'), response.read()

    def close(self):
        # Release blocked local upstreams before shutting down either HTTP server.
        self.release.set()
        self.live.shutdown_event.set()
        self.server.shutdown()
        self.server.server_close()
        self.server_thread.join(2)
        loops = [ch.thread for ch in self.live.CHANNEL_MAP.values() if ch.thread is not None]
        for worker in loops:
            worker.join(2)
        deadline = time.monotonic() + 2
        while time.monotonic() < deadline:
            with self.live._inflight_lock:
                if not self.live._inflight_refresh:
                    break
                tasks = list(self.live._inflight_refresh.values())
            for task in tasks:
                task.event.wait(.05)
        self.origin.shutdown()
        self.origin.server_close()
        self.origin_thread.join(2)
        self.live.feature_pool.shutdown(wait=True, cancel_futures=True)
        self.live.diagnostic_pool.shutdown(wait=True, cancel_futures=True)
        sys.modules.pop(self.module_name, None)
        if any(worker.is_alive() for worker in loops):
            raise AssertionError('channel refresh loop survived shutdown')
        with self.live._inflight_lock:
            if self.live._inflight_refresh:
                raise AssertionError('shared refresh task survived shutdown')


class Release9516Tests(unittest.TestCase):
    def harness(self, **kwargs):
        harness = LocalPlayback(**kwargs)
        self.addCleanup(harness.close)
        return harness

    def test_device_success_does_not_exhaust_capacity_needed_by_next_backup(self):
        channels = {'cctv' + str(i) for i in range(1, 9)}
        harness = self.harness(device_channels=channels, slow_channels=channels)
        for channel in sorted(channels):
            status, source, _ = harness.request(channel)
            self.assertEqual((status, source), (200, 'device'))
        with harness.request_lock:
            self.assertEqual(harness.requests, [])
        self.assertTrue(all(ch.thread is None for ch in harness.live.CHANNEL_MAP.values()))
        status, source, body = harness.request('cctv9')
        self.assertEqual((status, source), (200, 'backup:jce'))
        self.assertIn(b'#EXTINF:', body)
        with harness.request_lock:
            self.assertEqual(harness.requests, ['cctv9'])
        self.assertTrue(harness.live.CHANNEL_MAP['cctv9'].thread.is_alive())

    def test_previous_release_demonstrates_speculative_capacity_exhaustion(self):
        channels = {'cctv' + str(i) for i in range(1, 9)}
        harness = self.harness(version='9.5.15', device_channels=channels, slow_channels=channels)
        for channel in sorted(channels):
            status, source, _ = harness.request(channel)
            self.assertEqual((status, source), (200, 'device'))
        with harness.live._inflight_lock:
            self.assertEqual(len(harness.live._inflight_refresh), 8)
        status, _, _ = harness.request('cctv9')
        self.assertEqual(status, 503)
        with harness.request_lock:
            self.assertNotIn('cctv9', harness.requests)

    def test_pending_device_fetches_backup_on_demand_with_a_real_refresh_loop(self):
        harness = self.harness()
        status, source, body = harness.request('cctv1')
        self.assertEqual((status, source), (200, 'backup:jce'))
        self.assertIn(b'#EXTINF:', body)
        with harness.request_lock:
            self.assertEqual(harness.requests, ['cctv1'])
        channel = harness.live.CHANNEL_MAP['cctv1']
        self.assertTrue(channel.thread.is_alive())
        self.assertEqual(channel.selector.snapshot()['sources']['device']['failures'], 0)

    def test_multiple_real_refresh_loops_stop_and_release_all_shared_tasks(self):
        harness = LocalPlayback()
        loops = []
        try:
            for i in range(1, 7):
                self.assertEqual(harness.request('cctv' + str(i))[:2], (200, 'backup:jce'))
            loops = [ch.thread for ch in harness.live.CHANNEL_MAP.values() if ch.thread is not None]
            self.assertEqual(len(loops), 6)
            self.assertTrue(all(worker.is_alive() for worker in loops))
        finally:
            harness.close()
        self.assertTrue(all(not worker.is_alive() for worker in loops))
        self.assertFalse(harness.live._inflight_refresh)


if __name__ == '__main__':
    unittest.main()
