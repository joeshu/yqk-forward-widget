"""Causal regressions for late source results, cancellation, and bounded playlist chains."""
import concurrent.futures
import contextlib
import importlib.util
import os
from pathlib import Path
import sys
import threading
import time
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('ysp_deep_stability', ROOT / 'ysp-live-v9.5.7.py')
live = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = live
spec.loader.exec_module(live)


def media(sequence=1, uri='https://media.cctv.cn/1.ts'):
    return f'#EXTM3U\n#EXT-X-TARGETDURATION:6\n#EXT-X-MEDIA-SEQUENCE:{sequence}\n#EXTINF:6,\n{uri}\n'


class SourceEpochTests(unittest.TestCase):
    def test_late_playlist_cannot_clear_a_new_content_failure(self):
        selector = live.SourceSelector()
        selector.success('device', media(), .01)
        epoch = selector.attempt_token('device')
        selector.failure('device', 'HTML error body')
        with self.assertRaises(live.SourceAttemptSuperseded):
            selector.success('device', media(2), .01, expected_epoch=epoch)
        self.assertEqual(selector.states['device']['failures'], 1)
        self.assertEqual(selector.states['device']['error'], 'HTML error body')

    def test_old_request_error_cannot_poison_new_source_context(self):
        selector = live.SourceSelector()
        selector.success('backup', media(), .01, context='backup:jce')
        epoch = selector.attempt_token('backup')
        selector.success('backup', media(2), .01, context='backup:bk')
        self.assertFalse(selector.failure('backup', 'old JCE timeout', expected_epoch=epoch))
        self.assertEqual(selector.states['backup']['failures'], 0)

    def test_compatible_concurrent_success_is_accepted_without_false_failure(self):
        selector = live.SourceSelector()
        epoch = selector.attempt_token('device')
        selector.success('device', media(), .01, expected_epoch=epoch, context='device')
        selector.success('device', media(), .01, expected_epoch=epoch, context='device')
        self.assertEqual(selector.states['device']['successes'], 2)

    def test_late_lower_profile_cannot_replace_newer_high_quality_evidence(self):
        selector = live.SourceSelector()
        low, high = media(1, 'https://media.cctv.cn/low.ts'), media(2, 'https://media.cctv.cn/high.ts')
        live.remember_playlist_profile(low, live.StreamProfile(1920, 1080))
        live.remember_playlist_profile(high, live.StreamProfile(3840, 2160))
        selector.success('device', low, .01)
        epoch = selector.attempt_token('device')
        selector.success('device', high, .01)
        with self.assertRaises(live.SourceAttemptSuperseded):
            selector.success('device', low, .01, expected_epoch=epoch)
        self.assertEqual(selector.states['device']['profile'].height, 2160)

    def test_backup_context_change_clears_quality_and_master_progress(self):
        selector = live.SourceSelector()
        text = media()
        live.remember_playlist_profile(text, live.StreamProfile(3840, 2160))
        selector.success('backup', text, .01, context='backup:jce')
        state = selector.states['backup']
        state['content_signature'], state['content_progress_at'] = 'old-master', 1.0
        state['content_result'] = {'ok': True}
        selector.success('backup', media(2), .01, context='backup:bk')
        self.assertEqual(state['source_context'], 'backup:bk')
        self.assertEqual(state['profile'].height, 0)
        self.assertNotIn('content_signature', state)
        self.assertIsNone(state['content_result'])

    def test_old_generation_cannot_replace_new_generation(self):
        selector = live.SourceSelector()
        newer = live.register_resource('https://media.cctv.cn/new.ts', generation=9)
        older = live.register_resource('https://media.cctv.cn/old.ts', generation=8)
        selector.success('device', media(uri='/proxy?resource=' + newer), .01)
        with self.assertRaises(live.SourceAttemptSuperseded):
            selector.success('device', media(uri='/proxy?resource=' + older), .01)
        self.assertEqual(selector.states['device']['generation'], 9)

    def test_master_capabilities_also_carry_generation(self):
        selector = live.SourceSelector()
        newer = live.register_resource('https://media.cctv.cn/new.m3u8', generation=9)
        older = live.register_resource('https://media.cctv.cn/old.m3u8', generation=8)
        template = '#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=20000000,RESOLUTION=3840x2160\n/proxy?resource='
        selector.success('device', template + newer + '\n', .01)
        with self.assertRaises(live.SourceAttemptSuperseded):
            selector.success('device', template + older + '\n', .01)
        self.assertEqual(selector.states['device']['generation'], 9)

    def test_stale_quality_does_not_allow_known_lower_resolution_promotion(self):
        clock = [100.0]
        selector = live.SourceSelector(clock=lambda: clock[0])
        high = media(uri='https://media.cctv.cn/high.ts')
        live.remember_playlist_profile(high, live.StreamProfile(3840, 2160))
        selector.success('backup', high, .1)
        selector.commit('backup')
        clock[0] += 61
        for sequence in (1, 2):
            low = media(sequence, 'https://media.cctv.cn/low.ts')
            live.remember_playlist_profile(low, live.StreamProfile(1920, 1080))
            selector.success('device', low, .01, probe=True)
        self.assertEqual(selector.order(['device', 'backup'])[0], 'backup')
        row = selector.snapshot()['sources']['backup']
        self.assertEqual(row['playlist_resolution'], '3840x2160')
        self.assertFalse(row['profile_fresh'])

    def test_empty_or_non_hls_is_rejected_but_actual_llhls_parts_are_preserved(self):
        selector = live.SourceSelector()
        for body in ('#EXTM3U\n', '<html>#EXTM3U</html>', '#EXTM3U\n#EXT-X-PRELOAD-HINT:TYPE=PART,URI="next"\n'):
            with self.assertRaises(live.UnsafePlaylist):
                selector.success('device', body, .01)
        selector.success('device', '#EXTM3U\n#EXT-X-PART:DURATION=0.3,URI="part.m4s"\n', .01)
        self.assertEqual(selector.states['device']['successes'], 1)


class ProbeLifecycleTests(unittest.TestCase):
    def setUp(self):
        self.selector = live.SourceSelector()
        self.manager = live.MediaProbeManager()
        self.addCleanup(self.manager.close)

    def wait(self):
        deadline = time.monotonic() + 3
        while self.selector._state('device')['content_probing']:
            if time.monotonic() >= deadline:
                self.fail('probe did not clean up')
            time.sleep(.005)

    def test_cancelled_queued_job_clears_state_and_pending_registry(self):
        self.manager.pool.shutdown()
        self.manager.pool = live.ThreadPoolExecutor(max_workers=1, max_queue=8)
        release, started = threading.Event(), threading.Event()
        self.addCleanup(release.set)
        def occupy():
            started.set()
            release.wait(3)
        self.manager.pool.submit(occupy)
        self.assertTrue(started.wait(1))
        self.manager.schedule(self.selector, 'device', media(), '')
        self.assertTrue(self.selector.states['device']['content_probing'])
        self.manager.close()
        self.assertFalse(self.selector.states['device']['content_probing'])
        self.assertEqual(self.manager.stats()['pending'], 0)
        self.assertEqual(self.manager.stats()['cancelled'], 1)
        release.set()

    def test_running_result_after_close_cannot_apply_a_failure(self):
        release, entered = threading.Event(), threading.Event()
        self.addCleanup(release.set)
        def probe(*args, **kwargs):
            entered.set()
            release.wait(3)
            return {'ok': False, 'kind': 'old error', 'sampled_bytes': 12}
        with mock.patch.object(live, 'probe_playlist_content', side_effect=probe):
            self.manager.schedule(self.selector, 'device', media(), '')
            self.assertTrue(entered.wait(1))
            self.manager.close()
            release.set()
            self.wait()
        self.assertEqual(self.selector.states['device']['failures'], 0)
        self.assertIsNone(self.selector.states['device']['content_result'])
        self.assertEqual(self.manager.stats()['ignored'], 1)

    def test_master_freeze_is_counted_as_failed_and_does_not_reuse_stale_progress(self):
        clock = [100.0]
        self.selector.clock = lambda: clock[0]
        result = {'ok': True, 'kind': 'mpegts_prefix', 'sampled_bytes': 564,
                  'master': True, 'media_signature': 'same', 'target_duration': 6}
        with mock.patch.object(live, 'probe_playlist_content', side_effect=lambda *a, **kw: dict(result)):
            self.manager.schedule(self.selector, 'device', media(), '')
            self.wait()
            clock[0] += 31
            self.manager.schedule(self.selector, 'device', media(), '')
            self.wait()
        self.assertEqual(self.manager.stats()['failed'], 1)
        self.assertEqual(self.selector.states['device']['content_result']['kind'], 'media_frozen')
        self.assertNotIn('content_signature', self.selector.states['device'])

    def test_failure_for_a_replaced_signed_segment_cannot_poison_the_new_window(self):
        entered, release = threading.Event(), threading.Event()
        self.addCleanup(release.set)
        old = media(uri='https://media.cctv.cn/1.ts?sig=old')
        new = media(2, uri='https://media.cctv.cn/1.ts?sig=new')
        self.selector.success('device', old, .01)
        def probe(*args, **kwargs):
            entered.set()
            release.wait(3)
            return {'ok': False, 'kind': 'old URL expired', 'sampled_bytes': 0}
        with mock.patch.object(live, 'probe_playlist_content', side_effect=probe):
            self.manager.schedule(self.selector, 'device', old, '')
            self.assertTrue(entered.wait(1))
            self.selector.success('device', new, .01)
            release.set()
            self.wait()
        self.assertEqual(self.selector.states['device']['failures'], 0)
        self.assertEqual(self.manager.stats()['ignored'], 1)

    def test_target_policy_refusal_is_not_reported_as_a_cdn_authentication_failure(self):
        self.selector.channel = 'cctv1'
        resolver = mock.Mock()
        error = live.ProxyError(403, 'target not allowed', category='target_policy')
        with mock.patch.object(live, 'probe_playlist_content', side_effect=error), mock.patch.object(live, 'resolver', resolver):
            self.manager.schedule(self.selector, 'device', media(), '')
            self.wait()
        self.assertEqual(self.selector.states['device']['failures'], 0)
        self.assertIsNone(self.selector.states['device']['content_result']['ok'])
        resolver.record_segment_failure.assert_not_called()

    def test_confirmed_upstream_auth_failure_is_fed_back_with_generation(self):
        self.selector.channel = 'cctv1'
        self.selector._state('device')['generation'] = 7
        resolver = mock.Mock()
        error = live.ProxyError(403, 'CDN forbidden', category='upstream_status')
        with mock.patch.object(live, 'probe_playlist_content', side_effect=error), mock.patch.object(live, 'resolver', resolver):
            self.manager.schedule(self.selector, 'device', media(), '')
            self.wait()
        resolver.record_segment_failure.assert_called_once_with('cctv1', 7, 403)

    def test_cancelled_recovery_probe_clears_probation_flag(self):
        release, started = threading.Event(), threading.Event()
        self.addCleanup(release.set)
        pool = live.ThreadPoolExecutor(max_workers=1, max_queue=8)
        self.addCleanup(lambda: pool.shutdown(wait=False, cancel_futures=True))
        def occupy():
            started.set()
            release.wait(3)
        pool.submit(occupy)
        self.assertTrue(started.wait(1))
        clock = [100.0]
        selector = live.SourceSelector(clock=lambda: clock[0])
        selector.commit('backup')
        clock[0] += 31
        with mock.patch.object(live, 'feature_pool', pool):
            live.schedule_source_probe(selector, {'device': lambda: (media(), 'device', {})})
            self.assertTrue(selector.states['device']['probing'])
            pool.shutdown(wait=False, cancel_futures=True)
        self.assertFalse(selector.states['device']['probing'])
        release.set()


class PublicationTests(unittest.TestCase):
    def test_selection_commits_before_send_and_slow_send_holds_no_source_lock(self):
        channel = live.Channel('cctv1', 'CCTV1', 'sid', 'pid', 'best')
        selector = live.channel_selector(channel)
        epoch = selector.success('device', media(), .01, context='device')
        handler = object.__new__(live.Handler)
        observed = []
        def send(*args):
            def inspect():
                with selector.lock:
                    return selector.selected, channel._publication['source']
            with concurrent.futures.ThreadPoolExecutor(1) as executor:
                observed.append(executor.submit(inspect).result(timeout=1))
        handler._send = send
        self.assertTrue(handler._playlist(channel, media(), 'device', False,
                        selector=selector, source_key='device', expected_epoch=epoch))
        self.assertEqual(observed, [('device', 'device')])

    def test_failure_before_publication_prevents_known_bad_body_from_being_sent(self):
        channel = live.Channel('cctv1', 'CCTV1', 'sid', 'pid', 'best')
        selector = live.channel_selector(channel)
        epoch = selector.success('device', media(), .01, context='device')
        selector.failure('device', 'bad content')
        handler = object.__new__(live.Handler)
        handler._send = mock.Mock()
        with self.assertRaises(live.SourceAttemptSuperseded):
            handler._playlist(channel, media(), 'device', False,
                selector=selector, source_key='device', expected_epoch=epoch)
        handler._send.assert_not_called()
        self.assertIsNone(channel._publication)

    def test_status_snapshot_and_publication_do_not_invert_channel_locks(self):
        channel = live.Channel('cctv1', 'CCTV1', 'sid', 'pid', 'best')
        selector = live.channel_selector(channel)
        entered = threading.Event()
        original = selector.snapshot
        def snapshot():
            entered.set()
            return original()
        with mock.patch.object(live, 'CHANNEL_MAP', {'cctv1': channel}), mock.patch.object(selector, 'snapshot', side_effect=snapshot):
            with concurrent.futures.ThreadPoolExecutor(1) as executor:
                with selector.lock:
                    status = executor.submit(live.channel_status)
                    self.assertTrue(entered.wait(1))
                    acquired = channel.lock.acquire(timeout=.5)
                    if acquired:
                        channel.lock.release()
                    self.assertTrue(acquired, 'status holds channel lock while waiting for selector')
                self.assertTrue(status.result(timeout=1))


class HTTPRaceTests(unittest.TestCase):
    def test_late_device_response_after_content_failure_serves_backup(self):
        import http.client
        channel = live.Channel('cctv1', 'CCTV1', 'sid', 'pid', 'best')
        selector = live.channel_selector(channel)
        selector.success('device', media(), .01, context='device')
        selector.commit('device')
        entered, release = threading.Event(), threading.Event()
        def load():
            entered.set()
            release.wait(3)
            return media(2), 'device', {}
        loaders = {'device': load, 'backup': lambda: (media(3), 'backup:jce', {})}
        server = live.BoundedHTTPServer(('127.0.0.1', 0), live.Handler)
        server.access_token = ''
        worker = threading.Thread(target=server.serve_forever, daemon=True)
        worker.start()
        def request():
            with contextlib.closing(http.client.HTTPConnection('127.0.0.1', server.server_port, timeout=4)) as client:
                client.request('GET', '/cctv1.m3u8')
                response = client.getresponse()
                response.read()
                return response.status, response.getheader('X-Source')
        try:
            with mock.patch.object(live, 'CHANNEL_MAP', {'cctv1': channel}), mock.patch.object(live, 'source_loaders', return_value=loaders):
                with concurrent.futures.ThreadPoolExecutor(1) as pool:
                    response = pool.submit(request)
                    self.assertTrue(entered.wait(1))
                    selector.failure('device', 'confirmed bad segment')
                    release.set()
                    self.assertEqual(response.result(timeout=4), (200, 'backup:jce'))
            self.assertEqual(selector.states['device']['failures'], 1)
            self.assertEqual(selector.selected, 'backup')
        finally:
            release.set()
            server.shutdown()
            server.server_close()
            worker.join(2)

    def test_late_lower_quality_response_reuses_current_high_quality_without_downgrade(self):
        import http.client
        channel = live.Channel('cctv1', 'CCTV1', 'sid', 'pid', 'best')
        selector = live.channel_selector(channel)
        low, high = media(1, 'https://media.cctv.cn/low.ts'), media(2, 'https://media.cctv.cn/high.ts')
        live.remember_playlist_profile(low, live.StreamProfile(1920, 1080))
        live.remember_playlist_profile(high, live.StreamProfile(3840, 2160))
        selector.success('device', low, .01, context='device')
        selector.commit('device')
        entered, release = threading.Event(), threading.Event()
        def load():
            entered.set()
            release.wait(3)
            return low, 'device', {}
        backup = mock.Mock(return_value=(media(3), 'backup:jce', {}))
        server = live.BoundedHTTPServer(('127.0.0.1', 0), live.Handler)
        server.access_token = ''
        worker = threading.Thread(target=server.serve_forever, daemon=True)
        worker.start()
        def request():
            with contextlib.closing(http.client.HTTPConnection('127.0.0.1', server.server_port, timeout=4)) as client:
                client.request('GET', '/cctv1.m3u8')
                response = client.getresponse()
                return response.status, response.getheader('X-Source'), response.read()
        try:
            with mock.patch.object(live, 'CHANNEL_MAP', {'cctv1': channel}), mock.patch.object(live, 'source_loaders', return_value={'device': load, 'backup': backup}):
                with concurrent.futures.ThreadPoolExecutor(1) as pool:
                    response = pool.submit(request)
                    self.assertTrue(entered.wait(1))
                    epoch = selector.success('device', high, .01, context='device')
                    preparing = object.__new__(live.Handler)
                    preparing._send = mock.Mock()
                    preparing._playlist(channel, high, 'device', False, selector=selector,
                                        source_key='device', expected_epoch=epoch)
                    release.set()
                    status, source, body = response.result(timeout=4)
            self.assertEqual((status, source), (200, 'device'))
            self.assertIn(b'high.ts', body)
            backup.assert_not_called()
            self.assertEqual(selector.selected, 'device')
        finally:
            release.set()
            server.shutdown()
            server.server_close()
            worker.join(2)


class TimelineOrderingTests(unittest.TestCase):
    def window(self, start, count, suffix=''):
        lines = ['#EXTM3U', '#EXT-X-TARGETDURATION:6', f'#EXT-X-MEDIA-SEQUENCE:{start}']
        for number in range(start, start + count):
            lines.extend(['#EXTINF:6,', f'https://media.cctv.cn/{number}.ts{suffix}'])
        return '\n'.join(lines) + '\n'

    def channel(self):
        return live.Channel('test', 'Test', 'sid', 'pid', 'best')

    def test_late_old_window_cannot_rewind_current_publication_or_fake_progress(self):
        ch = self.channel()
        with mock.patch.object(live.time, 'monotonic', return_value=100):
            live.publish_channel_playlist(ch, self.window(100, 3), 'device')
        with mock.patch.object(live.time, 'monotonic', return_value=101):
            latest = live.publish_channel_playlist(ch, self.window(101, 3), 'device')
        with mock.patch.object(live.time, 'monotonic', return_value=102):
            self.assertEqual(live.publish_channel_playlist(ch, self.window(100, 3), 'device'), latest)
            self.assertEqual(ch._media_progress['published-device'][2], 101)
        with mock.patch.object(live.time, 'monotonic', return_value=140):
            with self.assertRaises(live.FrozenPlaylistError):
                live.publish_channel_playlist(ch, self.window(100, 3), 'device')

    def test_older_prefix_does_not_rewind_sequence_but_new_signatures_are_kept(self):
        ch = self.channel()
        live.publish_channel_playlist(ch, self.window(100, 3), 'device')
        live.publish_channel_playlist(ch, self.window(101, 3), 'device')
        result = live.publish_channel_playlist(ch, self.window(100, 4, '?sig=new'), 'device')
        parsed = live.parse_media(result)
        self.assertEqual(parsed.sequence, 101)
        self.assertTrue(all('sig=new' in s.uri for s in parsed.segments))
        self.assertEqual(len(parsed.segments), 3)

    def test_unseen_old_prefix_is_not_appended_as_new_media(self):
        ch = self.channel()
        live.publish_channel_playlist(ch, self.window(100, 3), 'device')
        live.publish_channel_playlist(ch, self.window(101, 3), 'device')
        result = live.publish_channel_playlist(ch, self.window(99, 6), 'device')
        parsed = live.parse_media(result)
        self.assertEqual(parsed.sequence, 101)
        self.assertEqual([s.uri.rsplit('/', 1)[1] for s in parsed.segments], ['101.ts', '102.ts', '103.ts', '104.ts'])

    def test_sequence_reset_with_new_segment_identities_can_still_advance(self):
        ch = self.channel()
        previous = live.publish_channel_playlist(ch, self.window(100, 3), 'device')
        replacement = self.window(0, 3).replace('/0.ts', '/new0.ts').replace('/1.ts', '/new1.ts').replace('/2.ts', '/new2.ts')
        result = live.publish_channel_playlist(ch, replacement, 'device')
        self.assertGreater(live.parse_media(result).sequence, live.parse_media(previous).sequence)


class NetworkBudgetTests(unittest.TestCase):
    def test_target_dns_receives_remaining_deadline_and_expired_requests_skip_dns(self):
        policy = live.URLPolicy(('example.test',))
        with mock.patch.object(live, 'bounded_dns_addresses', return_value=['8.8.8.8']) as dns:
            policy.resolve_for_request('https://media.example.test/list', time.monotonic() + .1)
            self.assertGreater(dns.call_args.kwargs['timeout'], 0)
            self.assertLessEqual(dns.call_args.kwargs['timeout'], .1)
            dns.reset_mock()
            with self.assertRaises(live.ProxyError) as error:
                policy.resolve_for_request('https://media.example.test/list', time.monotonic() - 1)
            self.assertEqual(error.exception.status, 504)
            dns.assert_not_called()

    def test_nested_master_chain_shares_one_total_deadline(self):
        clock, calls = [100.0], []
        master = b'#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=10\nnext.m3u8\n'
        def fetch(url, headers, **kwargs):
            calls.append(kwargs)
            clock[0] += 4
            if clock[0] > kwargs['deadline']:
                raise live.ProxyError(504, 'deadline')
            return 200, {}, master, url
        with mock.patch.object(live.time, 'monotonic', side_effect=lambda: clock[0]), mock.patch.object(live, 'fetch_urllib_bytes', side_effect=fetch):
            with self.assertRaises(live.ProxyError) as error:
                live.fetch_abs_playlist('https://media.cctv.cn/list.m3u8', quality='best')
        self.assertEqual(error.exception.status, 504)
        self.assertEqual([row['timeout'] for row in calls], [10, 6, 2])
        self.assertEqual({row['deadline'] for row in calls}, {110})

    def test_more_specific_nested_master_metadata_takes_precedence(self):
        top = b'#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=20000000,RESOLUTION=3840x2160\nchild.m3u8\n'
        child = b'#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=5000000,RESOLUTION=1920x1080\nmedia.m3u8\n'
        with mock.patch.object(live, 'fetch_urllib_bytes', side_effect=[
                (200, {}, top, 'https://media.cctv.cn/top.m3u8'),
                (200, {}, child, 'https://media.cctv.cn/child.m3u8'),
                (200, {}, media().encode(), 'https://media.cctv.cn/media.m3u8')]):
            result = live.fetch_abs_playlist('https://media.cctv.cn/top.m3u8', quality='best')
        self.assertEqual(live.analyze_playlist(result).profile.height, 1080)

    def test_previous_parent_metadata_is_not_mistaken_for_current_child_evidence(self):
        body = media(uri='https://media.cctv.cn/profile-isolation.ts').encode()
        for height in (2160, 1080):
            parent = f'#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=10000000,RESOLUTION=3840x{height}\nmedia.m3u8\n'.encode()
            with mock.patch.object(live, 'fetch_urllib_bytes', side_effect=[
                    (200, {}, parent, 'https://media.cctv.cn/root.m3u8'),
                    (200, {}, body, 'https://media.cctv.cn/media.m3u8')]):
                result = live.fetch_abs_playlist('https://media.cctv.cn/root.m3u8', quality='best')
            self.assertEqual(live.analyze_playlist(result).profile.height, height)

    def test_urllib_path_accepts_nonpublic_dns_without_custom_policy_and_uses_redirect_base(self):
        body = b'#EXTM3U\n#EXT-X-TARGETDURATION:6\n#EXT-X-KEY:METHOD=AES-128,URI="key.bin"\n#EXTINF:6,\nseg.ts\n'
        class Origin(BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass
            def do_GET(self):
                if self.path == '/start.m3u8':
                    self.send_response(302)
                    self.send_header('Location', '/final/list.m3u8')
                    self.end_headers()
                    return
                self.send_response(200)
                self.send_header('Content-Length', str(len(body)))
                self.end_headers()
                self.wfile.write(body)
        server = ThreadingHTTPServer(('127.0.0.1', 0), Origin)
        worker = threading.Thread(target=server.serve_forever, daemon=True)
        worker.start()
        base = f'http://127.0.0.1:{server.server_port}'
        try:
            with mock.patch.dict(os.environ, {'NO_PROXY': '127.0.0.1', 'no_proxy': '127.0.0.1'}), \
                 mock.patch.object(live.URLPolicy, 'resolve', side_effect=AssertionError('unexpected address policy')) as policy, \
                 mock.patch.object(live, 'bounded_dns_addresses', side_effect=AssertionError('unexpected custom DNS')) as dns:
                result = live.fetch_abs_playlist(base + '/start.m3u8', quality='best')
                self.assertIn(base + '/final/seg.ts', result)
                self.assertIn('URI="' + base + '/final/key.bin"', result)
                policy.assert_not_called()
                dns.assert_not_called()
        finally:
            server.shutdown()
            server.server_close()
            worker.join(2)

    def test_real_socket_oversized_playlist_is_rejected(self):
        payload = b'#EXTM3U\n' + b'#padding\n' * 240000
        class Origin(BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass
            def do_GET(self):
                self.send_response(200)
                self.send_header('Content-Length', str(len(payload)))
                self.end_headers()
                try:
                    self.wfile.write(payload)
                except (OSError, ConnectionResetError):
                    pass
        server = ThreadingHTTPServer(('127.0.0.1', 0), Origin)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            url = f'http://127.0.0.1:{server.server_port}/large.m3u8'
            with mock.patch.dict(os.environ, {'NO_PROXY': '127.0.0.1', 'no_proxy': '127.0.0.1'}):
                with self.assertRaises(live.ProxyError) as error:
                    live.fetch_abs_playlist(url)
            self.assertEqual(error.exception.status, 502)
        finally:
            server.shutdown()
            server.server_close()
            thread.join(2)


if __name__ == '__main__':
    unittest.main()
