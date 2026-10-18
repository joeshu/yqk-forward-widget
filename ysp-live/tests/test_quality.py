"""Highest-quality routing, immutable HLS reuse, and bounded media sampling."""
import concurrent.futures
import contextlib
import dataclasses
import http.client
import importlib.util
import io
import json
import os
from pathlib import Path
import sys
import threading
import time
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('ysp_quality_application', ROOT / 'ysp-live-v9.5.12.py')
live = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = live
spec.loader.exec_module(live)
TS = (b'G' + b'\0' * 187) * 512
MASTER = '''#EXTM3U
#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="sound",NAME="中文",URI="audio.m3u8"
#EXT-X-STREAM-INF:BANDWIDTH=2000000,RESOLUTION=1280x720,CODECS="avc1.64001f",AUDIO="sound"
low.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=25000000,RESOLUTION=3840x2160,CODECS="hvc1.1.6.L153",AUDIO="sound"
high.m3u8
'''


def media(seq=1, uri='https://media.cctv.cn/live.ts', extra=''):
    return f'#EXTM3U\n#EXT-X-TARGETDURATION:6\n#EXT-X-MEDIA-SEQUENCE:{seq}\n{extra}#EXTINF:6,\n{uri}\n'


class AnalysisCacheTests(unittest.TestCase):
    def test_one_parse_across_threads_and_nested_data_are_immutable(self):
        cache = live.PlaylistAnalysisCache()
        text = media()
        with mock.patch.object(live, '_parse_media_uncached', wraps=live._parse_media_uncached) as parse:
            with concurrent.futures.ThreadPoolExecutor(8) as pool:
                results = list(pool.map(lambda _: cache.get(text), range(32)))
        self.assertEqual(parse.call_count, 1)
        self.assertTrue(all(result is results[0] for result in results))
        with self.assertRaises(dataclasses.FrozenInstanceError):
            results[0].media.sequence = 7
        self.assertIsInstance(results[0].media.segments, tuple)
        self.assertIsInstance(results[0].media.segments[0].tags, tuple)

    def test_lru_budget_expiry_and_large_input_limit(self):
        clock = [100.0]
        cache = live.PlaylistAnalysisCache(max_entries=2, max_bytes=30000, ttl=5, clock=lambda: clock[0])
        for n in range(10):
            cache.get(media(n))
        self.assertLessEqual(cache.stats()['entries'], 2)
        self.assertLessEqual(cache.stats()['charged_bytes'], 30000)
        old = cache.get(media(20))
        clock[0] += 6
        self.assertIsNot(cache.get(media(20)), old)
        with self.assertRaises(live.UnsafePlaylist):
            cache.get('#EXTM3U\n' + '\n' * 8193)

    def test_profiles_are_scoped_to_exact_body_and_origin(self):
        cache = live.PlaylistAnalysisCache()
        first, second = media(uri='http://first.example/proxy?resource=one'), media(uri='http://second.example/proxy?resource=two')
        cache.remember_profile(first, live.StreamProfile(3840, 2160, 25000000, 'hvc1'))
        self.assertEqual(cache.get(first).profile.height, 2160)
        self.assertEqual(cache.get(second).profile.height, 0)

    def test_publication_reuses_snapshot_but_keeps_freeze_guard(self):
        ch = live.Channel('test', 'Test', 'sid', 'pid', 'best')
        with mock.patch.object(live, 'render_media', wraps=live.render_media) as render, \
                mock.patch.object(live.time, 'monotonic', return_value=100):
            first = live.publish_channel_playlist(ch, media(), 'device')
            for _ in range(20):
                self.assertEqual(live.publish_channel_playlist(ch, media(), 'device'), first)
            self.assertEqual(render.call_count, 1)
        with mock.patch.object(live.time, 'monotonic', return_value=140):
            with self.assertRaises(live.FrozenPlaylistError):
                live.publish_channel_playlist(ch, media(), 'device')


class QualityTests(unittest.TestCase):
    def test_best_has_no_1080p_cap_and_preserves_audio_group(self):
        muxed = MASTER.replace(',AUDIO="sound"', '')
        self.assertEqual(live.select_variant(muxed, 'best'), 'high.m3u8')
        self.assertEqual(live.select_variant(muxed, 'fhd'), 'low.m3u8')
        self.assertIsNone(live.select_variant(MASTER, 'best'))
        selected = live.filter_master_quality(MASTER, 'best')
        self.assertIn('high.m3u8', selected)
        self.assertNotIn('low.m3u8', selected)
        self.assertIn('URI="audio.m3u8"', selected)
        self.assertIn('AUDIO="sound"', selected)
        self.assertEqual(live.filter_master_quality(MASTER, 'auto'), MASTER)

    def test_slow_high_resolution_source_is_not_replaced_by_lower_resolution(self):
        clock = [100.0]
        selector = live.SourceSelector(clock=lambda: clock[0])
        high, low = media(), media(uri='https://media.cctv.cn/low.ts')
        live.remember_playlist_profile(high, live.StreamProfile(3840, 2160, 25000000, 'hvc1'))
        live.remember_playlist_profile(low, live.StreamProfile(1920, 1080, 8000000, 'avc1'))
        selector.success('backup', high, 2)
        selector.commit('backup')
        selector.success('device', low, .01, probe=True)
        clock[0] += 31
        second = low.replace('SEQUENCE:1', 'SEQUENCE:2')
        live.remember_playlist_profile(second, live.StreamProfile(1920, 1080, 8000000, 'avc1'))
        selector.success('device', second, .01, probe=True)
        self.assertEqual(selector.order(['device', 'backup'])[0], 'backup')

    def test_higher_resolution_lower_priority_source_can_recover(self):
        clock = [100.0]
        selector = live.SourceSelector(clock=lambda: clock[0])
        low = media()
        live.remember_playlist_profile(low, live.StreamProfile(1920, 1080))
        selector.success('device', low, .01)
        selector.commit('device')
        for seq in (1, 2):
            high = media(seq, 'https://media.cctv.cn/high.ts')
            live.remember_playlist_profile(high, live.StreamProfile(3840, 2160))
            selector.success('engine', high, .1, probe=True)
        clock[0] += 31
        self.assertEqual(selector.order(['device', 'engine'])[0], 'engine')

    def test_content_evidence_is_required_for_recovery_when_enabled(self):
        clock = [100.0]
        selector = live.SourceSelector(clock=lambda: clock[0], validate_recovery=True)
        selector.commit('backup')
        for seq in (1, 2):
            selector.success('device', media(seq), .1, probe=True)
        clock[0] += 31
        self.assertEqual(selector.order(['device', 'backup'])[0], 'backup')
        state = selector.states['device']
        state['content_result'], state['content_verified_at'] = {'ok': True}, clock[0]
        self.assertEqual(selector.order(['device', 'backup'])[0], 'device')

    def test_stable_policy_keeps_existing_priority_and_does_not_probe_lower_priority(self):
        clock = [100.0]
        selector = live.SourceSelector(clock=lambda: clock[0], policy='stable')
        selector.commit('device')
        clock[0] += 31
        self.assertIsNone(selector.reserve_probe(['device', 'backup', 'engine']))


class MediaContentTests(unittest.TestCase):
    def remote(self, body, status=200, headers=None):
        response = mock.Mock(status=status, headers=headers or {})
        stream = io.BytesIO(body)
        response.read.side_effect = stream.read
        return response

    def test_formats_error_documents_and_encryption_are_distinguished(self):
        cases = [(TS, False, True), (b'\0\0\0\x18ftyp' + b'iso6' * 4, False, True),
                 (b'<html>error</html>', False, False), (b'', False, False),
                 (b'{"error":"bad"}', False, False), (b'\x91\x92\x93', True, True),
                 (b'\x91\x92\x93', False, None)]
        for body, encrypted, expected in cases:
            self.assertIs(live.classify_media_prefix(body, encrypted)[0], expected)

    def test_read_is_bounded_even_when_server_ignores_range(self):
        remote = self.remote(TS * 8)
        with mock.patch.object(live, 'open_remote', return_value=remote) as request:
            result = live.probe_playlist_content(media())
        self.assertTrue(result['ok'])
        self.assertEqual(result['sampled_bytes'], 65536)
        self.assertEqual(request.call_args.kwargs['method'], 'GET')
        self.assertEqual(request.call_args.args[1]['Range'], 'bytes=0-65535')
        remote.close.assert_called_once()
        self.assertFalse(result['decode_verified'])

    def test_range_rejection_is_confirmed_with_a_bounded_plain_get(self):
        rejected, valid = self.remote(b'', status=403), self.remote(TS * 8)
        with mock.patch.object(live, 'open_remote', side_effect=[rejected, valid]) as request:
            result = live.probe_playlist_content(media())
        self.assertTrue(result['ok'])
        self.assertEqual(result['sampled_bytes'], 65536)
        self.assertNotIn('Range', request.call_args_list[-1].args[1])
        self.assertEqual(request.call_count, 2)
        rejected.close.assert_called_once()
        valid.close.assert_called_once()

    def test_truncated_or_inconsistent_ranges_are_rejected(self):
        for headers in ({'content-length': '999'}, {'content-range': 'bytes 9-20/100'},
                        {'content-range': 'bytes 0-187/188', 'content-length': '999'}):
            status = 206 if 'content-range' in headers else 200
            with mock.patch.object(live, 'open_remote', return_value=self.remote(b'x' * 188, status, headers)):
                with self.assertRaises(live.ProxyError):
                    live.probe_playlist_content(media())

    def test_nonzero_byte_range_ignored_is_inconclusive_not_a_downgrade(self):
        remote = self.remote(TS)
        with mock.patch.object(live, 'open_remote', return_value=remote):
            result = live.probe_playlist_content(media(extra='#EXT-X-BYTERANGE:188@188\n'))
        self.assertIsNone(result['ok'])
        self.assertEqual(result['kind'], 'byte_range_ignored')
        remote.read.assert_not_called()

    def test_completed_proxy_cache_avoids_an_extra_upstream_request(self):
        proxy = live.SharedMediaProxy()
        self.addCleanup(proxy.close)
        key = proxy._key('https://media.cctv.cn/live.ts', {})
        proxy.cache[key] = live._CacheEntry((TS[:1000], TS[1000:]), {}, len(TS), time.monotonic() + 60)
        proxy.cache_bytes = len(TS)
        with mock.patch.object(live, 'open_remote', side_effect=AssertionError('must reuse cache')):
            result = live.probe_playlist_content(media(), proxy=proxy)
        self.assertTrue(result['from_cache'])
        self.assertEqual(result['sampled_bytes'], 65536)
        self.assertEqual(proxy.cached_prefix(key[0], {}, 950, 100), TS[950:1050])

    def test_master_probe_follows_highest_variant_without_dropping_audio_from_output(self):
        child = media(uri='segment.ts').encode()
        remote = self.remote(TS)
        with mock.patch.object(live, 'fetch_bytes', return_value=(200, {}, child, 'https://media.cctv.cn/high.m3u8')) as fetch, \
                mock.patch.object(live, 'open_remote', return_value=remote):
            result = live.probe_playlist_content(MASTER, 'https://media.cctv.cn/root.m3u8')
        self.assertTrue(result['ok'])
        self.assertEqual(fetch.call_args.args[0], 'https://media.cctv.cn/high.m3u8')
        self.assertEqual(result['declared_profile']['height'], 2160)
        self.assertTrue(result['master'])
        self.assertIn('audio.m3u8', MASTER)

    def test_cross_origin_child_does_not_inherit_sensitive_headers(self):
        resource = live.playback_resource('https://other.cctv.cn/seg.ts', 'https://media.cctv.cn/index.m3u8',
                                         {'UID': 'secret', 'Authorization': 'Bearer secret', 'User-Agent': 'test'})
        self.assertEqual(resource.headers, {'User-Agent': 'test'})


class ProbeManagerTests(unittest.TestCase):
    def setUp(self):
        self.selector = live.SourceSelector()
        self.selector.commit('device')
        self.manager = live.MediaProbeManager()
        self.addCleanup(self.manager.close)

    def wait(self):
        deadline = time.monotonic() + 3
        while self.selector._state('device')['content_probing']:
            if time.monotonic() > deadline:
                self.fail('probe did not finish')
            time.sleep(.01)

    def test_concurrent_checks_coalesce_and_definite_error_opens_circuit(self):
        entered, release = threading.Event(), threading.Event()
        self.addCleanup(release.set)
        def check(*args, **kwargs):
            entered.set()
            release.wait(2)
            return {'ok': False, 'kind': 'error_document', 'sampled_bytes': 15, 'decode_verified': False}
        with mock.patch.object(live, 'probe_playlist_content', side_effect=check) as probe:
            with concurrent.futures.ThreadPoolExecutor(10) as pool:
                list(pool.map(lambda _: self.manager.schedule(self.selector, 'device', media(), ''), range(10)))
            self.assertTrue(entered.wait(1))
            release.set()
            self.wait()
            self.assertEqual(probe.call_count, 1)
        self.assertEqual(self.selector.order(['device', 'backup']), ['backup'])

    def test_timeout_and_dns_failure_do_not_downgrade_a_working_high_quality_source(self):
        for error in (live.ProxyError(504, 'deadline'), live.ProxyError(502, 'DNS unavailable')):
            if error.status == 502:
                error.__cause__ = live.DNSLookupError('temporary DNS failure')
            self.selector.states.clear()
            with mock.patch.object(live, 'probe_playlist_content', side_effect=error):
                self.manager.schedule(self.selector, 'device', media(), '')
                self.wait()
            self.assertEqual(self.selector.states['device']['failures'], 0)
            self.assertIsNone(self.selector.states['device']['content_result']['ok'])

    def test_old_epoch_result_cannot_override_a_new_foreground_failure(self):
        entered, release = threading.Event(), threading.Event()
        self.addCleanup(release.set)
        def check(*args, **kwargs):
            entered.set()
            release.wait(2)
            return {'ok': False, 'kind': 'old body', 'sampled_bytes': 0}
        with mock.patch.object(live, 'probe_playlist_content', side_effect=check):
            self.manager.schedule(self.selector, 'device', media(), '')
            self.assertTrue(entered.wait(1))
            self.selector.failure('device', 'new foreground failure')
            release.set()
            self.wait()
        self.assertEqual(self.selector.states['device']['error'], 'new foreground failure')
        self.assertIsNone(self.selector.states['device']['content_result'])

    def test_queue_rejection_clears_pending_flag_without_downgrading(self):
        with mock.patch.object(self.manager.pool, 'submit', side_effect=RuntimeError('queue full')):
            self.manager.schedule(self.selector, 'device', media(), '')
        self.assertFalse(self.selector.states['device']['content_probing'])
        self.assertEqual(self.selector.states['device']['failures'], 0)
        self.assertEqual(self.manager.stats()['dropped'], 1)


class LocalRangeTests(unittest.TestCase):
    def test_real_socket_range_sample_and_html_detection(self):
        paths = []
        class Origin(BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass
            def do_GET(self):
                paths.append((self.path, self.headers.get('Range')))
                payload = TS if self.path == '/live.ts' else b'<html>origin error</html>'
                limit = 65536
                body = payload[:limit]
                self.send_response(206)
                self.send_header('Content-Length', str(len(body)))
                self.send_header('Content-Range', f'bytes 0-{len(body)-1}/{len(payload)}')
                self.end_headers()
                self.wfile.write(body)
        server = ThreadingHTTPServer(('127.0.0.1', 0), Origin)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            base = f'http://127.0.0.1:{server.server_port}'
            policy = live.URLPolicy(('127.0.0.1',), allow_private=True)
            with mock.patch.dict(os.environ, {'NO_PROXY': '127.0.0.1', 'no_proxy': '127.0.0.1'}):
                good = live.probe_playlist_content(media(uri=base + '/live.ts'), policy=policy)
                bad = live.probe_playlist_content(media(uri=base + '/error.ts'), policy=policy)
            self.assertTrue(good['ok'])
            self.assertFalse(bad['ok'])
            self.assertEqual(paths[0][1], 'bytes=0-65535')
        finally:
            server.shutdown()
            server.server_close()
            thread.join(2)


if __name__ == '__main__':
    unittest.main()
