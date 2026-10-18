"""Obsolete device requests leave queues without penalizing a playback source.

The real Resolver pools, channel flights, and control lock run against local
functions only. No test opens a network connection or writes persistent state.
"""
import contextlib
import importlib.util
from pathlib import Path
import sys
import tempfile
import threading
import time
from types import SimpleNamespace
import unittest
from unittest import mock
import uuid


ROOT = Path(__file__).resolve().parents[1]


class DeviceDemand9517Tests(unittest.TestCase):
    def setUp(self):
        self.module_name = 'ysp_device_demand_9517_' + uuid.uuid4().hex
        spec = importlib.util.spec_from_file_location(
            self.module_name, ROOT / 'ysp-live-v9.5.17.py')
        self.live = importlib.util.module_from_spec(spec)
        sys.modules[self.module_name] = self.live
        spec.loader.exec_module(self.live)
        self.directory = tempfile.TemporaryDirectory()
        self.workers = []
        self.releases = []
        self.addCleanup(self.cleanup)
        args = SimpleNamespace(
            timeout=1, insecure_tls=False,
            meta_json=str(Path(self.directory.name) / 'meta.json'),
            device_json=str(Path(self.directory.name) / 'device.json'),
            heartbeat_interval=30, heartbeat_ttl_guard=60,
            background_refresh_queue_limit=16, refresh_interval=0,
            control_step_jitter_min_ms=0, control_step_jitter_max_ms=0,
            session_ttl=3600, stale_while_refresh_ttl=0,
            refresh_error_cooldown=2, identity_reset_error_threshold=0,
            identity_reset_cooldown=300, links_per_device=6,
            playlist_cache_ttl=2, cache_ttl=600, http_workers=8,
            http_queue_limit=16, zap_debounce=0, foreground_wait=1,
        )
        self.r = self.live.Resolver(args)
        self.ch = self.live.Channel('cctv1', 'Test', 'sid', 'pid', 'best')
        self.live.CHANNEL_MAP = {'cctv1': self.ch}
        self.body = '#EXTM3U\n#EXT-X-TARGETDURATION:6\n#EXTINF:6,\nlocal.ts\n'
        self.entry = self.live.ChannelEntry(
            channel='cctv1', final_url='https://media.cctv.cn/index.m3u8',
            android_id='local-test', generation=1,
            refreshed_at=time.time(), expires_at=time.time() + 600,
        )
        self.r.write_meta = mock.Mock()
        self.r.refresh_channel_controlled = mock.Mock(side_effect=self.publish_entry)
        self.r.fetch_playlist = mock.Mock(return_value=(self.body, 'application/vnd.apple.mpegurl', None))
        self.r.rotate_device_on_400 = mock.Mock(side_effect=AssertionError('unexpected identity recovery'))
        self.live.fetch_playlist_http1 = mock.Mock(side_effect=AssertionError('unexpected network access'))
        self.r.state.last_error = 'previous diagnostic'
        self.r.state.last_error_at = 123

    def cleanup(self):
        for release in self.releases:
            release.set()
        self.r.close()
        for worker in self.workers:
            worker.join(2)
        self.r._foreground_pool.shutdown(wait=True, cancel_futures=True)
        self.r._playlist_pool.shutdown(wait=True, cancel_futures=True)
        self.live.feature_pool.shutdown(wait=True, cancel_futures=True)
        self.live.diagnostic_pool.shutdown(wait=True, cancel_futures=True)
        self.directory.cleanup()
        sys.modules.pop(self.module_name, None)
        self.assertTrue(all(not worker.is_alive() for worker in self.workers))
        self.live.fetch_playlist_http1.assert_not_called()

    def publish_entry(self, channel):
        self.assertEqual(channel, 'cctv1')
        with self.r.state_lock:
            self.r.state.cache[channel] = self.entry
        return self.entry

    def wait_for(self, predicate, message, timeout=2):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if predicate():
                return
            threading.Event().wait(.002)
        self.assertTrue(predicate(), message)

    def start_worker(self, callback):
        values, errors, done = [], [], threading.Event()

        def run():
            try:
                values.append(callback())
            except BaseException as error:
                errors.append(error)
            finally:
                done.set()

        worker = threading.Thread(target=run, daemon=True)
        self.workers.append(worker)
        worker.start()
        return done, values, errors

    def waiters(self):
        with self.r.state_lock:
            return self.r._foreground_waiters.get('cctv1', 0)

    def flight(self, host='local'):
        with self.r.state_lock:
            return self.r._foreground_flights[('cctv1', host, 'http')]

    def expire_interest(self):
        with self.r.state_lock:
            if 'cctv1' in self.r._zap_interest:
                self.r._zap_interest['cctv1']['last'] -= 60
            self.r.state.channel_last_access['cctv1'] = time.time() - 60
        self.ch.last_access = time.time() - 60

    def assert_no_source_failure(self):
        self.assertEqual(self.r.state.channel_failures, {})
        self.assertEqual(self.r._failure_mono, {})
        self.assertEqual((self.r.state.last_error, self.r.state.last_error_at),
                         ('previous diagnostic', 123))
        self.r.rotate_device_on_400.assert_not_called()

    def finish_obsolete(self, flight):
        try:
            self.assertIsNone(flight.result(2))
        except self.live.SourcePending:
            pass
        self.wait_for(lambda: not self.r._foreground_flights,
                      'obsolete device flight retained its queue entry')
        self.assertEqual(self.waiters(), 0)

    @contextlib.contextmanager
    def saturated_foreground_pool(self):
        entered = threading.Barrier(5)
        release = threading.Event()
        self.releases.append(release)

        def occupy():
            entered.wait(2)
            if not release.wait(3):
                raise AssertionError('test did not release occupied device workers')

        running = [self.r._foreground_pool.submit(occupy) for _ in range(4)]
        entered.wait(2)
        try:
            yield release
        finally:
            release.set()
            for flight in running:
                flight.result(2)

    def test_expired_queued_device_request_never_fetches_or_creates_cooldown(self):
        with self.saturated_foreground_pool() as release:
            self.assertIsNone(self.r.fetch_channel_playlist_bounded('cctv1', 'local', timeout=0))
            queued = self.flight()
            self.assertFalse(queued.running())
            self.expire_interest()
            self.assertEqual(self.waiters(), 0)
            release.set()
            self.finish_obsolete(queued)
        self.r.refresh_channel_controlled.assert_not_called()
        self.r.fetch_playlist.assert_not_called()
        self.r.write_meta.assert_not_called()
        self.assert_no_source_failure()

    def test_another_viewers_recent_interest_preserves_queued_device_request(self):
        with self.saturated_foreground_pool() as release:
            self.assertIsNone(self.r.fetch_channel_playlist_bounded('cctv1', 'local', timeout=0))
            queued = self.flight()
            self.expire_interest()
            self.r.note_channel_interest('cctv1')
            self.assertEqual(self.waiters(), 0)
            release.set()
            self.assertEqual(queued.result(2), self.body)
        self.r.refresh_channel_controlled.assert_called_once_with('cctv1')
        self.r.fetch_playlist.assert_called_once()
        self.assert_no_source_failure()

    def check_foreground_follower(self, follower_host):
        with self.saturated_foreground_pool() as release:
            self.assertIsNone(self.r.fetch_channel_playlist_bounded(
                'cctv1', 'local', timeout=0, _record_interest=False))
            queued = self.flight()
            done, values, errors = self.start_worker(lambda: self.r.fetch_channel_playlist_bounded(
                'cctv1', follower_host, timeout=2, _record_interest=False))
            self.wait_for(lambda: self.waiters() == 1, 'foreground follower did not join device waiters')
            release.set()
            self.assertEqual(queued.result(2), self.body)
            self.assertTrue(done.wait(2))
            self.assertEqual((values, errors), ([self.body], []))
        self.wait_for(lambda: self.waiters() == 0, 'foreground waiter count leaked')
        self.r.refresh_channel_controlled.assert_called_once_with('cctv1')
        self.assert_no_source_failure()

    def test_same_flight_foreground_follower_keeps_abandoned_leaders_work_alive(self):
        self.check_foreground_follower('local')
        self.assertEqual(self.r._stats['foreground_shared'], 1)
        self.r.fetch_playlist.assert_called_once()

    def test_other_origin_viewer_keeps_all_work_for_same_channel_alive(self):
        self.check_foreground_follower('another-viewer')
        self.assertEqual(self.r.fetch_playlist.call_count, 2)

    def test_control_lock_rechecks_expired_demand_outside_state_lock(self):
        active = threading.Event()
        active.set()
        checks = []

        def demand_check():
            # This deliberately takes the real non-reentrant lock: calling the
            # predicate while already holding state_lock would deadlock.
            with self.r.state_lock:
                checks.append(active.is_set())
                return active.is_set()

        self.r.control_lock.acquire()
        try:
            done, values, errors = self.start_worker(lambda: self.r.ensure_channel(
                'cctv1', demand_check=demand_check))
            self.wait_for(lambda: 'cctv1' in self.r._channel_flights,
                          'device request did not wait for protocol access')
            active.clear()
        finally:
            self.r.control_lock.release()
        self.assertTrue(done.wait(2), 'demand check deadlocked under state_lock')
        self.assertEqual(values, [])
        self.assertEqual(len(errors), 1)
        self.assertIsInstance(errors[0], self.live.SourcePending)
        self.assertIn(False, checks)
        self.r.refresh_channel_controlled.assert_not_called()
        self.r.write_meta.assert_not_called()
        self.assertEqual(self.r._channel_flights, {})
        self.assert_no_source_failure()

    def test_bounded_timeout_while_waiting_for_control_lock_does_not_resolve_source(self):
        self.r.control_lock.acquire()
        try:
            done, values, errors = self.start_worker(lambda: self.r.fetch_channel_playlist_bounded(
                'cctv1', 'local', timeout=.15, _record_interest=False))
            self.wait_for(lambda: 'cctv1' in self.r._channel_flights,
                          'bounded device request did not reach protocol queue')
            queued = self.flight()
            self.assertTrue(done.wait(1))
            self.assertEqual((values, errors), ([None], []))
            self.assertEqual(self.waiters(), 0)
        finally:
            self.r.control_lock.release()
        self.finish_obsolete(queued)
        self.r.refresh_channel_controlled.assert_not_called()
        self.r.fetch_playlist.assert_not_called()
        self.r.write_meta.assert_not_called()
        self.assert_no_source_failure()

    def test_background_zap_leader_survives_expiry_when_foreground_viewer_joins(self):
        with self.r.state_lock:
            self.r.state.zap_generations['cctv1'] = 1
            self.r.state.zap_pending_channels.add('cctv1')
            self.r._zap_interest['cctv1'] = {
                'since': time.monotonic() - 10, 'last': time.monotonic(), 'samples': 2}
        self.r.control_lock.acquire()
        try:
            background = self.start_worker(lambda: self.r._zap_resolve_worker('cctv1', 1, 0))
            self.wait_for(lambda: 'cctv1' in self.r._channel_flights,
                          'zap leader did not wait for protocol lock')
            self.expire_interest()
            with self.r.state_lock:
                self.r.state.zap_generations['cctv1'] = 2
            foreground = self.start_worker(lambda: self.r.fetch_channel_playlist_bounded(
                'cctv1', 'local', timeout=2, _record_interest=False))
            self.wait_for(lambda: self.r._stats['channel_shared'] == 1,
                          'foreground viewer did not join background channel flight')
            self.assertEqual(self.waiters(), 1)
        finally:
            self.r.control_lock.release()
        for done, _, errors in (background, foreground):
            self.assertTrue(done.wait(2))
            self.assertEqual(errors, [])
        self.assertEqual(foreground[1], [self.body])
        self.assertEqual(self.waiters(), 0)
        self.r.refresh_channel_controlled.assert_called_once_with('cctv1')
        self.r.fetch_playlist.assert_called_once()
        self.assert_no_source_failure()

    def test_demand_expiry_after_resolution_skips_playlist_fetch(self):
        active = threading.Event()
        active.set()

        def resolve(*args, **kwargs):
            active.clear()
            return self.entry

        with mock.patch.object(self.r, 'ensure_channel', side_effect=resolve):
            with self.assertRaises(self.live.SourcePending):
                self.r.fetch_channel_playlist('cctv1', 'local', _record_interest=False,
                                             _demand_check=active.is_set)
        self.r.fetch_playlist.assert_not_called()
        self.assert_no_source_failure()

    def test_demand_expiry_after_playlist_403_skips_forced_source_retry(self):
        active = threading.Event()
        active.set()
        self.r.state.cache['cctv1'] = self.entry

        def expired_playlist(*args, **kwargs):
            active.clear()
            raise self.live.YsptpError('playlist HTTP 403')

        with mock.patch.object(self.r, 'ensure_channel', wraps=self.r.ensure_channel) as resolve, \
             mock.patch.object(self.r, 'fetch_playlist', side_effect=expired_playlist) as playlist:
            with self.assertRaises(self.live.SourcePending):
                self.r.fetch_channel_playlist('cctv1', 'local', _record_interest=False,
                                             _demand_check=active.is_set)
        self.assertEqual(resolve.call_count, 1)
        playlist.assert_called_once()
        self.r.refresh_channel_controlled.assert_not_called()
        self.assert_no_source_failure()


if __name__ == '__main__':
    unittest.main()
