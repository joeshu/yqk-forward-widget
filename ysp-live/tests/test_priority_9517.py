"""Real-thread scheduling regressions; no public upstream requests.

These tests exercise the release's shared refresh admission and actual limiter,
including demand that expires while a worker is waiting for permission to send.
"""
import importlib.util
from pathlib import Path
import sys
import threading
import time
import unittest
from unittest import mock
import uuid


ROOT = Path(__file__).resolve().parents[1]


class Priority9517Tests(unittest.TestCase):
    def setUp(self):
        self.module_name = 'ysp_priority_9517_' + uuid.uuid4().hex
        spec = importlib.util.spec_from_file_location(
            self.module_name, ROOT / 'ysp-live-v9.5.19.py')
        self.live = importlib.util.module_from_spec(spec)
        sys.modules[self.module_name] = self.live
        spec.loader.exec_module(self.live)
        self.workers = []
        self.release_events = []
        self.addCleanup(self.cleanup)

    def cleanup(self):
        for event in self.release_events:
            event.set()
        self.live.shutdown_event.set()
        for worker in self.workers:
            worker.join(2)
        self.wait_for(lambda: not self.inflight(), 'shared refresh workers did not stop')
        self.live.feature_pool.shutdown(wait=True, cancel_futures=True)
        self.live.diagnostic_pool.shutdown(wait=True, cancel_futures=True)
        sys.modules.pop(self.module_name, None)
        self.assertTrue(all(not worker.is_alive() for worker in self.workers))

    def inflight(self):
        with self.live._inflight_lock:
            return dict(self.live._inflight_refresh)

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

    def test_six_background_refreshes_leave_two_foreground_places(self):
        release = threading.Event()
        self.release_events.append(release)
        entered = {}
        calls = []
        calls_lock = threading.Lock()

        def fetch(slug):
            with calls_lock:
                calls.append(slug)
            entered[slug].set()
            if not release.wait(2):
                raise AssertionError('test did not release upstream worker')
            return slug

        for i in range(6):
            slug = 'background-' + str(i)
            entered[slug] = threading.Event()
            self.assertIsNone(self.live.coalesce_refresh(
                slug, lambda slug=slug: fetch(slug), timeout=0,
                background=True, active=lambda: True))
            self.assertTrue(entered[slug].wait(1))
        self.assertIs(self.live.coalesce_refresh(
            'background-overflow', lambda: self.fail('background overflow ran'),
            timeout=0, background=True, active=lambda: True), False)

        for i in range(2):
            slug = 'foreground-' + str(i)
            entered[slug] = threading.Event()
            self.assertIsNone(self.live.coalesce_refresh(
                slug, lambda slug=slug: fetch(slug), timeout=0))
            self.assertTrue(entered[slug].wait(1))
        self.assertEqual(len(self.inflight()), 8)
        self.assertIs(self.live.coalesce_refresh(
            'foreground-overflow', lambda: self.fail('total overflow ran'), timeout=0), False)
        self.assertIsNone(self.live.coalesce_refresh(
            'background-0', lambda: self.fail('full capacity duplicated shared work'), timeout=0))
        self.assertEqual(len(self.inflight()), 8)
        release.set()
        self.wait_for(lambda: not self.inflight(), 'refresh capacity was not released')
        self.assertEqual(len(calls), 8)
        self.assertEqual(self.live.coalesce_refresh('after-release', lambda: 'reused', timeout=1), 'reused')

    def test_foreground_join_keeps_shared_background_work_alive(self):
        active, release, entered, completed = (threading.Event() for _ in range(4))
        active.set()
        self.release_events.append(release)
        limiter = self.live.ApiFlowLimiter(80, 0)
        calls = []

        def upstream():
            entered.set()
            if not release.wait(2):
                raise AssertionError('test did not release shared task')
            # With no explicit arguments this inherits the shared task's demand.
            limiter.wait_slot()
            calls.append('one request')
            completed.set()
            return 'playlist'

        self.assertIsNone(self.live.coalesce_refresh(
            'shared', upstream, timeout=0, background=True, active=active.is_set))
        self.assertTrue(entered.wait(1))
        self.assertIsNone(self.live.coalesce_refresh(
            'shared', lambda: self.fail('foreground started a duplicate'), timeout=0))
        task = self.inflight()['shared']
        active.clear()
        release.set()
        self.assertTrue(task.event.wait(1))
        self.assertTrue(completed.is_set(), 'expired background demand cancelled a foreground-shared task')
        self.assertEqual((task.result, task.error), ('playlist', None))
        self.assertEqual(calls, ['one request'])

    def test_foreground_precedes_queued_background_without_bypassing_throttle(self):
        limiter = self.live.ApiFlowLimiter(80, 0)
        limiter.wait_slot(background=False)
        first = time.monotonic()
        granted = []
        lock = threading.Lock()

        def take_slot(label, background):
            limiter.wait_slot(background=background, active=lambda: True)
            with lock:
                granted.append((label, time.monotonic()))

        background = self.start_worker(lambda: take_slot('background', True))
        self.wait_for(lambda: limiter.snapshot()['background_waiters'] == 1,
                      'background did not enter limiter queue')
        foreground = self.start_worker(lambda: take_slot('foreground', False))
        self.wait_for(lambda: limiter.snapshot()['foreground_waiters'] == 1,
                      'foreground did not enter limiter queue')
        self.assertTrue(foreground[0].wait(1))
        self.assertTrue(background[0].wait(1))
        self.assertEqual(foreground[2] + background[2], [])
        self.assertEqual([label for label, _ in granted], ['foreground', 'background'])
        self.assertGreaterEqual(granted[0][1] - first, .075)
        self.assertGreaterEqual(granted[1][1] - granted[0][1], .075)
        state = limiter.snapshot()
        self.assertEqual((state['background_waiters'], state['foreground_waiters']), (0, 0))

    def test_background_expiring_in_limiter_never_sends_upstream(self):
        # This task must expire before its next grant. A long grant interval
        # avoids racing module/GC pauses against an 80ms scheduling window.
        limiter = self.live.ApiFlowLimiter(10000, 0)
        limiter.wait_slot(background=False)
        active = threading.Event()
        active.set()
        upstream_calls = []

        def send():
            limiter.wait_slot(background=True, active=active.is_set)
            upstream_calls.append('sent')

        done, _, errors = self.start_worker(send)
        self.wait_for(lambda: limiter.snapshot()['background_waiters'] == 1,
                      'background did not wait for throttle')
        active.clear()
        self.assertTrue(done.wait(1))
        self.assertEqual(upstream_calls, [])
        self.assertEqual(len(errors), 1)
        self.assertIsInstance(errors[0], self.live.RefreshObsolete)
        self.assertEqual(limiter.snapshot()['background_waiters'], 0)

    def test_already_obsolete_background_is_absorbed_without_calling_refresh(self):
        fetch = mock.Mock(side_effect=AssertionError('obsolete work reached upstream'))
        self.assertIsNone(self.live.coalesce_refresh(
            'obsolete-before-start', fetch, timeout=1, background=True, active=lambda: False))
        fetch.assert_not_called()
        self.wait_for(lambda: not self.inflight(), 'obsolete task retained refresh capacity')
        self.assertEqual(self.live.coalesce_refresh('valid-after-obsolete', lambda: True, timeout=1), True)

    def test_expiry_through_real_refresh_path_preserves_channel_failure_state(self):
        live = self.live
        limiter = live.ApiFlowLimiter(10000, 0)
        limiter.wait_slot(background=False)
        live.global_flow_limiter = limiter
        active = threading.Event()
        active.set()
        channel = live.Channel('obsolete-channel', 'Test', 'sid', 'pid', 'best')
        channel.last_ok = time.time()
        channel.last_error = 'previous diagnostic'
        channel._refresh_failures = 2
        before = (channel.last_ok, channel.last_error, channel._refresh_failures)
        with mock.patch.object(live, 'jce_timeshift_url', side_effect=AssertionError('obsolete JCE request')), \
             mock.patch.object(live, 'bk_refresh', side_effect=AssertionError('obsolete task fell through to BK')) as backup, \
             mock.patch.object(live, 'record_channel_issue') as issue:
            self.assertIsNone(live.coalesce_refresh(
                channel.slug, lambda: live._refresh_and_build(channel), timeout=0,
                background=True, active=active.is_set))
            task = self.inflight()[channel.slug]
            self.wait_for(lambda: limiter.snapshot()['background_waiters'] == 1,
                          'real JCE refresh did not enter throttle')
            active.clear()
            self.assertTrue(task.event.wait(1))
            self.assertIsNone(task.result)
            self.assertIsNone(task.error)
            backup.assert_not_called()
            issue.assert_not_called()
        self.assertEqual((channel.last_ok, channel.last_error, channel._refresh_failures), before)

    def test_obsolete_in_backup_mode_does_not_trigger_other_source_or_error(self):
        live = self.live
        channel = live.Channel('test', 'Test', 'sid', 'pid', 'best')
        channel.mode = 'bk'
        for probing in (True, False):
            with self.subTest(jce_probe=probing):
                channel._next_jce_probe = 0 if probing else time.monotonic() + 120
                previous_probe = channel._next_jce_probe
                channel.last_error = 'unchanged'
                with mock.patch.object(live, 'jce_refresh', side_effect=live.RefreshObsolete('demand expired')) as jce, \
                     mock.patch.object(live, 'bk_refresh', side_effect=live.RefreshObsolete('demand expired')) as backup, \
                     mock.patch.object(live, 'record_channel_issue') as issue:
                    with self.assertRaises(live.RefreshObsolete):
                        live.refresh_once(channel)
                    self.assertEqual(jce.call_count, int(probing))
                    self.assertEqual(backup.call_count, int(not probing))
                    issue.assert_not_called()
                self.assertEqual(channel.last_error, 'unchanged')
                self.assertEqual(channel._refresh_failures, 0)
                self.assertEqual(channel._next_jce_probe, previous_probe)

    def test_source_probe_expiring_during_loader_cannot_commit_success_or_failure(self):
        live = self.live
        for failed in (False, True):
            with self.subTest(loader_failed=failed):
                channel = live.Channel('test', 'Test', 'sid', 'pid', 'best')
                channel.last_access = time.time()
                clock = [100.0]
                selector = live.SourceSelector(clock=lambda: clock[0])
                selector.channel = channel.slug
                selector.commit('backup')
                clock[0] += 31
                entered, release = threading.Event(), threading.Event()
                self.release_events.append(release)

                def load():
                    entered.set()
                    if not release.wait(2):
                        raise AssertionError('test did not release probe loader')
                    if failed:
                        raise RuntimeError('obsolete loader error')
                    return ('#EXTM3U\n#EXT-X-TARGETDURATION:6\n'
                            '#EXT-X-MEDIA-SEQUENCE:1\n#EXTINF:6,\n'
                            'https://media.cctv.cn/1.ts\n', 'device', {})

                with mock.patch.object(live, 'CHANNEL_MAP', {channel.slug: channel}), \
                     mock.patch.object(live, 'media_probe_manager', None), \
                     mock.patch.object(live, 'record_channel_issue') as issue:
                    live.schedule_source_probe(selector, {'device': load})
                    self.assertTrue(entered.wait(1))
                    channel.last_access = time.time() - 60
                    release.set()
                    self.wait_for(lambda: not selector.states['device']['probing'],
                                  'obsolete source probe did not clean up')
                    state = selector.states['device']
                    self.assertEqual((state['successes'], state['failures'], state['retry_at']), (0, 0, 0))
                    self.assertEqual(selector.selected, 'backup')
                    issue.assert_not_called()


if __name__ == '__main__':
    unittest.main()
