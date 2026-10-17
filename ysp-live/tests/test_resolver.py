"""Resolver regressions use simulated upstreams only; no CCTV calls."""
import concurrent.futures
import dataclasses
import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import threading
import time
from types import SimpleNamespace
import unittest
from unittest import mock


ROOT =Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
spec =importlib.util.spec_from_file_location('ysp_live_resolver_tests', ROOT /'ysp-live.py')
live =importlib.util.module_from_spec(spec)
sys.modules[spec.name] =live
spec.loader.exec_module(live)


class ResolverTests(unittest.TestCase):
    def setUp(self):
        self.directory =tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        args =SimpleNamespace(
            timeout=1.0, insecure_tls=False,
            meta_json=str(Path(self.directory.name) /'meta.json'),
            device_json=str(Path(self.directory.name) /'device.json'),
            heartbeat_interval=30.0, heartbeat_ttl_guard=60.0,
            background_refresh_queue_limit=16, refresh_interval=0.0,
            control_step_jitter_min_ms=0, control_step_jitter_max_ms=0,
            session_ttl=3600.0, stale_while_refresh_ttl=0.0,
            refresh_error_cooldown=2.0, identity_reset_error_threshold=0,
            identity_reset_cooldown=300.0, links_per_device=6,
            playlist_cache_ttl=2.0, cache_ttl=600.0,
            http_workers=8, http_queue_limit=16, zap_debounce=0.0,
            foreground_wait=0.03,
        )
        self.resolver =live.Resolver(args)
        self.addCleanup(self.resolver.close)
        self.resolver.write_meta =mock.Mock()

    def entry(self, generation=1):
        return live.ChannelEntry(
            channel='cctv1', final_url='https://media.cctv.cn/live/index.m3u8',
            android_id='0123456789abcdef', generation=generation,
            refreshed_at=time.time(), expires_at=time.time() +600.0,
        )

    def session(self):
        return SimpleNamespace(
            created_at=time.time(), generation=1, linked_channels=set(),
            last_heartbeat_at=time.time(), heartbeat_count=1,
            last_heartbeat_result='0', last_heartbeat_error='',
            profile=SimpleNamespace(), identity=SimpleNamespace(),
            version='1.4.1', cloud_guid='test',
        )

    def test_simultaneous_channel_failures_are_shared_and_counted_once(self):
        entered, release =threading.Event(), threading.Event()
        calls =[]
        def failure(channel):
            calls.append(channel)
            entered.set()
            self.assertTrue(release.wait(2.0))
            raise live.YsptpError('simulated upstream unavailable')
        self.resolver.refresh_channel_controlled =failure
        with concurrent.futures.ThreadPoolExecutor(max_workers=12) as pool:
            futures =[pool.submit(self.resolver.ensure_channel, 'cctv1') for _ in range(12)]
            self.assertTrue(entered.wait(1.0))
            time.sleep(0.04)
            release.set()
            for future in futures:
                with self.assertRaises(live.YsptpError):
                    future.result(timeout=2.0)
        self.assertEqual(calls, ['cctv1'])
        self.assertEqual(self.resolver.get_channel_failure_info('cctv1')[2], 1)
        with self.assertRaisesRegex(live.YsptpError, 'cooldown'):
            self.resolver.ensure_channel('cctv1', force=True)
        self.assertEqual(len(calls), 1)

    def test_cooldown_rechecked_after_waiting_for_protocol_lock(self):
        self.resolver.refresh_channel_controlled =mock.Mock(side_effect=AssertionError('must not call upstream'))
        self.resolver.control_lock.acquire()
        try:
            with concurrent.futures.ThreadPoolExecutor(max_workers=1) as pool:
                future =pool.submit(self.resolver.ensure_channel, 'cctv1')
                deadline =time.monotonic() +1.0
                while 'cctv1' not in self.resolver._channel_flights and time.monotonic() <deadline:
                    time.sleep(0.005)
                with self.resolver.state_lock:
                    self.resolver.state.channel_failures['cctv1'] =(time.time(), 'another failure', 1)
                    self.resolver._failure_mono['cctv1'] =time.monotonic()
                self.resolver.control_lock.release()
                with self.assertRaisesRegex(live.YsptpError, 'cooldown'):
                    future.result(timeout=1.0)
        finally:
            # The normal path above releases before joining its worker.
            if getattr(self.resolver.control_lock, '_is_owned', lambda: False)():
                self.resolver.control_lock.release()
        self.resolver.refresh_channel_controlled.assert_not_called()
        self.assertEqual(self.resolver.get_channel_failure_info('cctv1')[2], 1)

    def test_old_force_request_reuses_replacement_generation(self):
        replacement =self.entry(2)
        self.resolver.state.cache['cctv1'] =replacement
        self.resolver.refresh_channel_controlled =mock.Mock(side_effect=AssertionError('duplicate refresh'))
        result =self.resolver.ensure_channel('cctv1', force=True, expected_generation=1)
        self.assertIs(result, replacement)
        self.resolver.refresh_channel_controlled.assert_not_called()

    def test_segment_failure_matches_generation_and_counts_once(self):
        entry =self.entry(2)
        self.resolver.state.cache[entry.channel] =entry
        self.resolver.args.stale_while_refresh_ttl =120.0
        self.resolver.rotate_device_on_400 =mock.Mock(side_effect=AssertionError('must not rotate identity'))
        self.assertFalse(self.resolver.record_segment_failure('cctv1', 1, 403))
        self.assertTrue(entry.fresh(time.time()))
        self.assertTrue(self.resolver.record_segment_failure('cctv1', 2, 403))
        self.assertFalse(self.resolver.record_segment_failure('cctv1', 2, 404))
        self.assertEqual(self.resolver.get_channel_failure_info('cctv1')[2], 1)
        self.assertFalse(entry.fresh(time.time()))
        with self.assertRaisesRegex(live.YsptpError, 'cooldown'):
            self.resolver.ensure_channel('cctv1')
        self.assertIn('cctv1', self.resolver._segment_retry_due)
        self.resolver.rotate_device_on_400.assert_not_called()

    def test_slot_creation_failure_has_one_shared_attempt(self):
        def fail(*args, **kwargs):
            time.sleep(0.04)
            raise live.YsptpError('session bootstrap unavailable')
        self.resolver.bootstrap_session =mock.Mock(side_effect=fail)
        with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
            results =[pool.submit(self.resolver.ensure_slot_session, 0) for _ in range(8)]
            for result in results:
                with self.assertRaisesRegex(live.YsptpError, 'bootstrap unavailable'):
                    result.result(timeout=2.0)
        self.assertEqual(self.resolver.bootstrap_session.call_count, 1)

    def test_bootstrap_failure_is_shared_across_different_channels(self):
        self.resolver.bootstrap_session =mock.Mock(side_effect=live.YsptpError('app/start HTTP 503'))
        for channel in ('cctv1', 'cctv2'):
            with self.assertRaisesRegex(live.YsptpError, 'app/start HTTP 503'):
                self.resolver.ensure_channel(channel)
        self.assertEqual(self.resolver.bootstrap_session.call_count, 1)

    def test_playlist_cache_is_shared_across_origins_and_proxies_tag_uris(self):
        entry =self.entry()
        self.resolver.state.cache['cctv1'] =entry
        playlist ='#EXTM3U\n#EXT-X-TARGETDURATION:6\n#EXT-X-KEY:METHOD=AES-128,URI="key.bin"\n#EXT-X-MAP:URI="init.mp4"\n#EXTINF:6,\nseg.ts\n'
        with mock.patch.object(live, 'fetch_playlist_http1', return_value=(200, 'application/vnd.apple.mpegurl', playlist, 'https://media.cctv.cn/redirect/index.m3u8')) as fetch:
            first =self.resolver.fetch_playlist(entry, 'http://first.example')[0]
            second =self.resolver.fetch_playlist(entry, 'http://second.example')[0]
        self.assertEqual(fetch.call_count, 1)
        self.assertIn('http://first.example/proxy?resource=', first)
        self.assertNotIn('first.example', second)
        self.assertIn('http://second.example/proxy?resource=', second)
        from ysp_runtime import resolve_resource
        import re
        tokens =re.findall(r'resource=([A-Za-z0-9_-]+)', first)
        self.assertEqual(len(tokens), 3)
        urls ={resolve_resource(token).url for token in tokens}
        self.assertEqual(urls, {
            'https://media.cctv.cn/redirect/key.bin',
            'https://media.cctv.cn/redirect/init.mp4',
            'https://media.cctv.cn/redirect/seg.ts',
        })

    def test_playlist_failure_backoff_prevents_serial_retry_amplification(self):
        entry =self.entry()
        self.resolver.state.cache['cctv1'] =entry
        def fail(*args):
            time.sleep(0.03)
            raise live.YsptpError('simulated playlist timeout')
        with mock.patch.object(live, 'fetch_playlist_http1', side_effect=fail) as fetch:
            with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
                results =[pool.submit(self.resolver.fetch_playlist, entry, 'http://local') for _ in range(8)]
                for result in results:
                    with self.assertRaisesRegex(live.YsptpError, 'playlist timeout'):
                        result.result(timeout=2.0)
            with self.assertRaises(live.YsptpError):
                self.resolver.fetch_playlist(entry, 'http://local')
        self.assertEqual(fetch.call_count, 1)

    def test_stale_playlist_returns_immediately_while_one_refresh_runs(self):
        entry =self.entry()
        self.resolver.state.cache['cctv1'] =entry
        entered, release =threading.Event(), threading.Event()
        def response(*args):
            if response.count:
                entered.set()
                self.assertTrue(release.wait(2.0))
            response.count +=1
            return 200, 'application/vnd.apple.mpegurl', f'#EXTM3U\n#EXT-X-TARGETDURATION:6\n{response.count}.ts\n', entry.final_url
        response.count =0
        with mock.patch.object(live, 'fetch_playlist_http1', side_effect=response) as fetch:
            self.resolver.fetch_playlist(entry, 'http://local')
            self.resolver._playlist_raw[entry.channel].expires_at =time.monotonic() -1.0
            start =time.monotonic()
            for _ in range(8):
                self.resolver.fetch_playlist(entry, 'http://local')
            self.assertLess(time.monotonic() -start, 0.25)
            self.assertTrue(entered.wait(1.0))
            release.set()
            deadline =time.monotonic() +2.0
            while self.resolver._playlist_flights and time.monotonic() <deadline:
                time.sleep(0.005)
            self.assertEqual(fetch.call_count, 2)

    def test_stale_playlist_never_crosses_source_or_identity(self):
        old =self.entry(1)
        with mock.patch.object(live, 'fetch_playlist_http1', return_value=(200, 'hls', '#EXTM3U\nold.ts\n', old.final_url)):
            self.resolver.fetch_playlist(old, 'http://local')
        new =dataclasses.replace(old, generation=2, android_id='fedcba9876543210')
        self.resolver.state.cache[new.channel] =new
        with mock.patch.object(live, 'fetch_playlist_http1', side_effect=live.YsptpError('new source failed')):
            with self.assertRaisesRegex(live.YsptpError, 'new source failed'):
                self.resolver.fetch_playlist(new, 'http://local')

    def test_frozen_media_cannot_keep_renewing_cache(self):
        entry =self.entry()
        self.resolver.state.cache['cctv1'] =entry
        playlist ='#EXTM3U\n#EXT-X-TARGETDURATION:6\n#EXT-X-MEDIA-SEQUENCE:100\n#EXTINF:6,\nstuck.ts\n'
        with mock.patch.object(live, 'fetch_playlist_http1', return_value=(200, 'hls', playlist, entry.final_url)):
            self.resolver.fetch_playlist(entry, 'http://local')
            raw =self.resolver._playlist_raw[entry.channel]
            first_cached_at =raw.cached_at
            raw.expires_at =raw.stale_until =0.0
            self.resolver._playlist_progress[entry.channel]['progress_at'] =time.monotonic() -30.0
            with self.assertRaisesRegex(live.YsptpError, 'media stalled'):
                self.resolver.fetch_playlist(entry, 'http://local')
        self.assertEqual(raw.cached_at, first_cached_at)
        self.assertTrue(self.resolver._playlist_progress[entry.channel]['stalled'])

    def test_heartbeat_failure_does_not_mark_ready(self):
        session =self.session()
        self.resolver.state.sessions[0] =session
        self.resolver.heartbeat_flow =mock.Mock(side_effect=live.YsptpError('heartbeat timeout'))
        live.set_resolver_ready(True)
        self.resolver.send_heartbeat()
        self.assertFalse(live.resolver_ready())
        self.assertEqual(session.last_heartbeat_error, 'heartbeat timeout')

    def test_foreground_wait_is_bounded_and_work_is_shared(self):
        entered, release =threading.Event(), threading.Event()
        def slow(*args):
            entered.set()
            release.wait(2.0)
            return '#EXTM3U\n'
        self.resolver.fetch_channel_playlist =mock.Mock(side_effect=slow)
        try:
            start =time.monotonic()
            self.assertIsNone(self.resolver.fetch_channel_playlist_bounded('cctv1', 'local'))
            self.assertIsNone(self.resolver.fetch_channel_playlist_bounded('cctv1', 'local'))
            self.assertLess(time.monotonic() -start, 0.25)
            self.assertTrue(entered.is_set())
            self.assertEqual(self.resolver.fetch_channel_playlist.call_count, 1)
        finally:
            release.set()

    def test_refresh_worker_survives_unexpected_exception(self):
        finished =threading.Event()
        def refresh(channel):
            if channel =='broken':
                raise RuntimeError('unexpected failure')
            finished.set()
            return True
        self.resolver.refresh_channel_background =refresh
        self.resolver.start_refresh_worker()
        self.resolver.enqueue_background_refresh('broken')
        self.resolver.enqueue_background_refresh('healthy')
        self.assertTrue(finished.wait(1.0))
        deadline =time.monotonic() +1.0
        while self.resolver.refresh_queue.running_channel and time.monotonic() <deadline:
            time.sleep(0.005)
        self.assertTrue(self.resolver._threads[0].is_alive())
        self.assertEqual(self.resolver.refresh_queue.failed_total, 1)
        self.assertEqual(self.resolver.refresh_queue.completed_total, 1)
        self.assertEqual(self.resolver.refresh_queue.running_channel, '')

    def test_device_writers_leave_complete_newest_json(self):
        path =self.resolver.args.device_json
        state =live.default_device_state()
        states =[dataclasses.replace(state, updated_at=float(index), cloud_guid='x' *(index +1)) for index in range(24)]
        with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
            list(pool.map(lambda value: live.save_device_state(path, value), reversed(states)))
        payload =json.loads(Path(path).read_text())
        self.assertEqual(payload['updated_at'], 23.0)
        self.assertEqual(payload['cloud_guid'], 'x' *24)
        self.assertEqual(list(Path(self.directory.name).glob('*.tmp')), [])

    def test_requested_rate_selects_actual_upstream_item(self):
        self.resolver.args.device_rate ='10p'
        session =SimpleNamespace(screen_param='3840-2160', cast_model='tv',
                                client=mock.Mock(), identity=SimpleNamespace(headers={}))
        videos =[
            {'url': 'https://media.cctv.cn/36.m3u8', 'rate': '36p', 'rateName': '8K超高清'},
            {'url': 'https://media.cctv.cn/10.m3u8', 'rate': '10p', 'rateName': '高清'},
        ]
        with mock.patch.object(live, 'response_json', return_value=(200, '', {'data': {'videos': videos}})):
            chosen =self.resolver.live_v1_01_flow(session, 'test')
            self.assertEqual(chosen.rate, '10p')
            self.assertEqual(chosen.live_url, 'https://media.cctv.cn/10.m3u8')
            self.resolver.args.device_rate ='auto'
            chosen =self.resolver.live_v1_01_flow(session, 'test')
            self.assertEqual(chosen.rate_name, '8K超高清')
        self.resolver.args.device_rate ='10p'
        with mock.patch.object(live, 'response_json', return_value=(200, '', {'data': {'videos': videos[:1]}})):
            with self.assertRaisesRegex(live.YsptpError, 'requested rate 10p unavailable'):
                self.resolver.live_v1_01_flow(session, 'test')


if __name__ =='__main__':
    unittest.main()
