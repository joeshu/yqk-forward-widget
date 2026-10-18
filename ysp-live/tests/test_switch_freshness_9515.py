"""Idle-channel switching regressions against the standalone application.

All upstream work is replaced locally. The real shared-refresh admission,
playlist rebuilding, source selection, and HTTP handler remain in use.
"""
import concurrent.futures
import contextlib
import http.client
import importlib.util
from pathlib import Path
import sys
import threading
import time
from types import SimpleNamespace
import unittest
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location(
    'ysp_switch_freshness_9515', ROOT / 'ysp-live-v9.5.16.py')
live = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = live
spec.loader.exec_module(live)


def media(label, sequence):
    lines = ['#EXTM3U', '#EXT-X-TARGETDURATION:6',
             '#EXT-X-MEDIA-SEQUENCE:' + str(sequence)]
    for value in range(sequence, sequence + 3):
        lines.extend(('#EXTINF:6,', 'https://media.example/' + label + str(value) + '.ts'))
    return '\n'.join(lines) + '\n'


class SwitchFreshnessTests(unittest.TestCase):
    def setUp(self):
        self.ch = live.Channel('cctv1', 'Test', 'sid', 'pid', 'best')
        # Exercise refresh admission without starting an unrelated refresh loop.
        self.ch.thread = SimpleNamespace(is_alive=lambda: True)
        self.old = live._FetchedSegments(media('old-', 10))
        self.fresh = live._FetchedSegments(media('fresh-', 50))
        with mock.patch.object(live, 'jce_fetch', return_value=self.old):
            live.jce_refresh(self.ch)
        self.old_built = live.build_playlist(self.ch)
        self.selector = live.channel_selector(self.ch)
        self.selector.success('backup', self.old_built, .01, context='backup:jce')
        self.selector.commit('backup')
        live.publish_channel_playlist(self.ch, self.old_built, 'backup:jce')
        self.publication = self.ch._publication
        self.old_next = self.publication['next']
        self.old_seq = self.ch.seq
        now = time.time()
        self.ch.last_ok = self.ch.last_fetch_success_at = now

        patches = (
            mock.patch.object(live, 'CHANNEL_MAP', {'cctv1': self.ch}),
            mock.patch.object(live, 'active_backend_channels', set()),
            mock.patch.object(live, 'resolver', None),
            mock.patch.object(live, 'engine_enabled', False),
            mock.patch.object(live, 'epg_manager', None),
            mock.patch.object(live, 'media_probe_manager', None),
        )
        for patch in patches:
            patch.start()
            self.addCleanup(patch.stop)
        self.server = None

    def expire(self):
        stale = time.time() - live.IDLE_TIMEOUT - 1
        self.ch.last_ok = self.ch.last_fetch_success_at = stale
        self.ch.last_built_time = stale

    def start_server(self):
        self.server = live.BoundedHTTPServer(('127.0.0.1', 0), live.Handler)
        self.server.access_token = ''
        self.server.trust_proxy = False
        self.server.public_base_url = ''
        self.server_thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.server_thread.start()
        self.addCleanup(self.stop_server)

    def stop_server(self):
        self.server.shutdown()
        self.server.server_close()
        self.server_thread.join(2)

    def request(self):
        with contextlib.closing(http.client.HTTPConnection(
                '127.0.0.1', self.server.server_port, timeout=3)) as connection:
            connection.request('GET', '/cctv1.m3u8')
            response = connection.getresponse()
            return response.status, dict(response.getheaders()), response.read()

    def paused_refresh(self, entered, release, finished=None, inspect=None):
        def refresh(ch):
            try:
                if inspect:
                    inspect(ch)
                entered.set()
                if not release.wait(2):
                    raise AssertionError('test did not release refresh')
                with mock.patch.object(live, 'jce_fetch', return_value=self.fresh):
                    result = live.jce_refresh(ch)
                ch.last_ok = time.time()
                return result
            finally:
                if finished:
                    finished.set()
        return refresh

    def test_expired_get_waits_for_fresh_media_instead_of_publishing_old_segments(self):
        self.expire()
        self.start_server()
        entered, release = threading.Event(), threading.Event()
        with mock.patch.object(live, 'refresh_once', side_effect=self.paused_refresh(entered, release)) as refresh:
            with concurrent.futures.ThreadPoolExecutor(max_workers=1) as pool:
                response = pool.submit(self.request)
                try:
                    self.assertTrue(entered.wait(1), 'idle channel must start a refresh')
                    self.assertFalse(response.done(), 'old segments must not be returned while refreshing')
                    self.assertIs(self.ch._publication, self.publication)
                    self.assertIn('old-', self.publication['snapshot'])
                finally:
                    release.set()
                status, _, body = response.result(2)
        self.assertEqual(status, 200)
        self.assertIn(b'fresh-', body)
        self.assertNotIn(b'old-', body)
        self.assertEqual(refresh.call_count, 1)
        self.assertGreaterEqual(live.parse_media(body.decode()).sequence, self.old_next)

    def test_concurrent_idle_reentry_clears_buffers_once_and_retains_output_state(self):
        self.expire()
        # Include both source caches so a partial reset cannot silently pass.
        self.ch.bk_playlist = media('stale-backup-', 1)
        self.ch._jce_passthrough = media('stale-passthrough-', 1)
        entered, release = threading.Event(), threading.Event()
        observations = []
        def inspect(ch):
            observations.append(ch)
            with ch.lock:
                self.assertFalse(ch.segments)
                self.assertFalse(ch.segment_models)
                self.assertFalse(ch.order)
                self.assertFalse(ch.seen_keys)
                self.assertEqual(ch.bk_playlist, '')
                self.assertIsNone(ch._jce_media)
                self.assertEqual(ch._jce_passthrough, '')
                self.assertEqual(ch.last_built_playlist, '')
                self.assertEqual(ch.seq, self.old_seq)
                self.assertIs(ch._publication, self.publication)
                self.assertIs(ch.selector, self.selector)
        with mock.patch.object(live, 'refresh_once', side_effect=self.paused_refresh(
                entered, release, inspect=inspect)) as refresh:
            with concurrent.futures.ThreadPoolExecutor(max_workers=6) as pool:
                first = pool.submit(live.ensure_channel, self.ch, timeout=1)
                followers = []
                try:
                    self.assertTrue(entered.wait(1))
                    followers = [pool.submit(live.ensure_channel, self.ch, timeout=1) for _ in range(5)]
                finally:
                    release.set()
                for future in [first] + followers:
                    future.result(2)
        self.assertEqual(refresh.call_count, 1)
        self.assertEqual(observations, [self.ch])
        self.assertIs(self.ch._publication, self.publication)
        self.assertIs(self.ch.selector, self.selector)
        self.assertGreater(self.ch.seq, self.old_seq)
        rebuilt = live.build_playlist(self.ch)
        self.assertIn('fresh-', rebuilt)
        self.assertNotIn('old-', rebuilt)

    def test_warm_backup_cache_does_not_refresh_or_wait(self):
        with mock.patch.object(live, 'coalesce_refresh', side_effect=AssertionError('warm cache must not fetch')):
            started = time.monotonic()
            playlist, source, headers = live.source_loaders(self.ch, 'http://localhost')['backup']()
            elapsed = time.monotonic() - started
        self.assertEqual(playlist, self.old_built)
        self.assertEqual(source, 'backup:jce')
        self.assertEqual(headers.get('X-SWR'), 'HIT')
        self.assertLess(elapsed, .25)

    def test_device_debounce_pending_uses_backup_without_source_failure(self):
        self.start_server()
        self.ch.selector = live.SourceSelector(policy='quality', fast_start=True)
        device = mock.Mock(return_value=None)
        resolver = SimpleNamespace(
            is_channel_in_cooldown=lambda channel: False,
            fetch_channel_playlist_bounded=device,
            fetch_channel_playlist=device,
            note_channel_interest=mock.Mock())
        with mock.patch.object(live, 'active_backend_channels', {'cctv1'}), \
             mock.patch.object(live, 'resolver_ready', return_value=True), \
             mock.patch.object(live, 'resolver', resolver):
            status, _, body = self.request()
        self.assertEqual(status, 200)
        self.assertIn(b'old-', body)
        self.assertEqual(device.call_count, 1)
        state = self.ch.selector.snapshot()['sources']['device']
        self.assertEqual(state['failures'], 0)
        self.assertEqual(state['retry_in'], 0)
        self.assertTrue(state['pending_reason'])

    def test_refresh_capacity_rejection_cannot_publish_expired_buffer_or_count_failure(self):
        self.expire()
        self.start_server()
        previous_snapshot = self.publication['snapshot']
        with mock.patch.object(live, 'coalesce_refresh', return_value=False):
            loader = live.source_loaders(self.ch, 'http://localhost')['backup']
            with self.assertRaises(live.SourcePending):
                loader()
            status, _, body = self.request()
        self.assertEqual(status, 503)
        self.assertNotIn(b'old-', body)
        self.assertIs(self.ch._publication, self.publication)
        self.assertEqual(self.publication['snapshot'], previous_snapshot)
        state = self.selector.snapshot()['sources']['backup']
        self.assertEqual(state['failures'], 0)
        self.assertEqual(state['retry_in'], 0)
        self.assertTrue(state['pending_reason'])

    def test_short_refresh_wait_is_pending_and_does_not_cool_down_backup(self):
        self.expire()
        self.start_server()
        entered, release, finished = threading.Event(), threading.Event(), threading.Event()
        original_ensure = live.ensure_channel
        def short_wait(ch, *args, **kwargs):
            return original_ensure(ch, timeout=.02)
        try:
            with mock.patch.object(live, 'refresh_once', side_effect=self.paused_refresh(
                    entered, release, finished)) as refresh, \
                 mock.patch.object(live, 'ensure_channel', side_effect=short_wait):
                status, _, body = self.request()
                self.assertTrue(entered.is_set())
                self.assertEqual(status, 503)
                self.assertNotIn(b'old-', body)
                state = self.selector.snapshot()['sources']['backup']
                self.assertEqual(state['failures'], 0)
                self.assertEqual(state['retry_in'], 0)
                self.assertTrue(state['pending_reason'])
                with live._inflight_lock:
                    task = live._inflight_refresh[self.ch.slug]
                release.set()
                self.assertTrue(finished.wait(1))
                # Join completion including _refresh_and_build, not merely refresh_once.
                self.assertTrue(task.event.wait(1))
                self.assertIsNone(task.error)
                status, _, body = self.request()
                self.assertEqual(status, 200)
                self.assertIn(b'fresh-', body)
                self.assertNotIn(b'old-', body)
                self.assertEqual(refresh.call_count, 1)
        finally:
            release.set()


if __name__ == '__main__':
    unittest.main()
