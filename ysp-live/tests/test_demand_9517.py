"""Playback demand must stop obsolete work without interrupting other viewers.

All refreshes are local functions; the HTTP checks bind loopback only.
"""
import contextlib
import http.client
import importlib.util
from pathlib import Path
import sys
import threading
import time
import unittest
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('ysp_demand_9517', ROOT / 'ysp-live-v9.5.18.py')
live = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = live
spec.loader.exec_module(live)


def media(sequence=1):
    return ('#EXTM3U\n#EXT-X-TARGETDURATION:6\n#EXT-X-MEDIA-SEQUENCE:%s\n'
            '#EXTINF:6,\nhttps://media.cctv.cn/%s.ts\n' % (sequence, sequence))


@contextlib.contextmanager
def local_server():
    server = live.BoundedHTTPServer(('127.0.0.1', 0), live.Handler)
    server.access_token = ''
    server.trust_proxy = False
    server.public_base_url = ''
    worker = threading.Thread(target=server.serve_forever, daemon=True)
    worker.start()
    try:
        yield server
    finally:
        server.shutdown()
        server.server_close()
        worker.join(2)


def request(server, method='GET'):
    with contextlib.closing(http.client.HTTPConnection('127.0.0.1', server.server_port, timeout=2)) as connection:
        connection.request(method, '/cctv1.m3u8')
        response = connection.getresponse()
        return response.status, response.read()


class PlaybackDemandTests(unittest.TestCase):
    def setUp(self):
        self.channels = {
            slug: live.Channel(slug, slug, slug, 'pid', 'best')
            for slug in ('cctv1', 'cctv2')
        }
        self.stop = threading.Event()
        patches = (
            mock.patch.object(live, 'CHANNEL_MAP', self.channels),
            mock.patch.object(live, 'shutdown_event', self.stop),
            mock.patch.object(live, 'resolver', None),
            mock.patch.object(live, 'engine_enabled', False),
            mock.patch.object(live, 'media_probe_manager', None),
            mock.patch.object(live, 'REFRESH_INTERVAL', .01),
        )
        for patch in patches:
            patch.start()
            self.addCleanup(patch.stop)
        self.addCleanup(self.close_loops)

    def close_loops(self):
        self.stop.set()
        for ch in self.channels.values():
            worker = ch.thread
            if worker is not None:
                worker.join(2)
                self.assertFalse(worker.is_alive())
        with live._inflight_lock:
            tasks = list(live._inflight_refresh.values())
        for task in tasks:
            self.assertTrue(task.event.wait(2), 'shared refresh survived test cleanup')

    def test_demand_expiry_tracks_media_duration_without_changing_cache_lifetime(self):
        ch = self.channels['cctv1']
        with mock.patch.object(live.time, 'time', return_value=1000):
            self.assertFalse(live.channel_has_recent_demand(ch))
            ch.last_access = 980
            self.assertFalse(live.channel_has_recent_demand(ch))
            ch.media_target_duration = 12
            self.assertTrue(live.channel_has_recent_demand(ch))
            ch.last_access = 960
            self.assertFalse(live.channel_has_recent_demand(ch))
            ch.media_target_duration = 2
            ch.last_access = 986
            self.assertTrue(live.channel_has_recent_demand(ch))
        self.assertEqual(live.IDLE_TIMEOUT, 120)

    def test_real_refresh_loops_skip_abandoned_a_and_continue_active_b(self):
        abandoned, watched = self.channels.values()
        abandoned.last_access = time.time() - 60
        watched.last_access = time.time()
        abandoned.last_ok = watched.last_ok = time.time()
        abandoned.bk_playlist = media(21)
        abandoned.seq = 25
        publication = {'snapshot': media(21), 'source': 'backup:bk'}
        abandoned._publication = publication
        refreshed = threading.Event()
        calls = []

        def refresh(ch):
            calls.append(ch.slug)
            # A real active refresh runs once, then its viewer also leaves.
            ch.last_access = time.time() - 60
            refreshed.set()
            return True

        with mock.patch.object(live, '_refresh_and_build', side_effect=refresh):
            loops = []
            for ch in (abandoned, watched):
                ch.thread = threading.Thread(target=live.refresh_loop, args=(ch,), daemon=True)
                loops.append(ch.thread)
                loops[-1].start()
            self.assertTrue(refreshed.wait(1))
            for worker in loops:
                worker.join(1)
                self.assertFalse(worker.is_alive())
        self.assertEqual(calls, ['cctv2'])
        self.assertEqual(abandoned.bk_playlist, media(21))
        self.assertEqual(abandoned.seq, 25)
        self.assertIs(abandoned._publication, publication)

    def test_new_get_restarts_stopped_loop_without_clearing_fresh_cached_media(self):
        ch = self.channels['cctv1']
        ch.last_access = time.time() - 60
        ch.last_ok = ch.last_fetch_success_at = time.time()
        ch.mode = 'bk'
        ch.bk_playlist = media(11)
        ch.seq = 12
        publication = {'snapshot': media(11), 'source': 'backup:bk'}
        ch._publication = publication
        old_loop = threading.Thread(target=live.refresh_loop, args=(ch,), daemon=True)
        ch.thread = old_loop
        old_loop.start()
        old_loop.join(1)
        self.assertFalse(old_loop.is_alive())
        with mock.patch.object(live, '_refresh_and_build', side_effect=AssertionError('fresh cached media must not refetch')):
            live.ensure_channel(ch)
            self.assertIsNot(ch.thread, old_loop)
            self.assertTrue(ch.thread.is_alive())
            self.assertTrue(live.channel_has_recent_demand(ch))
            self.assertEqual(ch.bk_playlist, media(11))
            self.assertEqual(ch.seq, 12)
            self.assertIs(ch._publication, publication)
            worker = ch.thread
            self.stop.set()
            worker.join(1)

    def test_get_during_old_threads_exit_window_starts_replacement_refresh_loop(self):
        ch = self.channels['cctv1']
        ch.last_access = time.time() - 60
        ch.last_ok = ch.last_fetch_success_at = time.time()
        ch.mode = 'bk'
        ch.bk_playlist = media(9)
        retired, release_old_thread = threading.Event(), threading.Event()

        def exiting_worker():
            live.refresh_loop(ch)
            # Hold the retired thread alive after its refresh loop returns.
            # A new viewer must get a replacement even during this exit window.
            retired.set()
            release_old_thread.wait(3)

        old_worker = threading.Thread(target=exiting_worker, daemon=True)
        ch.thread = old_worker
        old_worker.start()
        replacement = None
        try:
            self.assertTrue(retired.wait(1))
            self.assertTrue(old_worker.is_alive())
            with mock.patch.object(live, '_refresh_and_build', side_effect=AssertionError('fresh media must be retained')):
                live.ensure_channel(ch)
                replacement = ch.thread
                self.assertIsNot(replacement, old_worker)
                self.assertIsNotNone(replacement)
                self.assertTrue(replacement.is_alive())
                self.assertEqual(ch.bk_playlist, media(9))
                self.stop.set()
                replacement.join(1)
        finally:
            release_old_thread.set()
            old_worker.join(1)
            if replacement is not None:
                replacement.join(1)
        self.assertFalse(old_worker.is_alive())

    @contextlib.contextmanager
    def queued_probe(self):
        release, occupied = threading.Event(), threading.Event()
        pool = live.ThreadPoolExecutor(max_workers=1, max_queue=8)

        def occupy():
            occupied.set()
            release.wait(3)

        pool.submit(occupy)
        self.assertTrue(occupied.wait(1))
        clock = [100.0]
        selector = live.SourceSelector(clock=lambda: clock[0])
        selector.channel = 'cctv1'
        selector.commit('backup')
        clock[0] += 31
        self.channels['cctv1'].selector = selector
        loader = mock.Mock(return_value=(media(), 'device', {}))
        loader.probe = loader
        try:
            with mock.patch.object(live, 'feature_pool', pool):
                live.schedule_source_probe(selector, {'device': loader})
                self.assertTrue(selector.states['device']['probing'])
                yield selector, loader, release, pool
        finally:
            release.set()
            pool.shutdown(wait=True, cancel_futures=True)

    def test_queued_probe_expiring_before_execution_never_fetches_or_marks_failure(self):
        ch = self.channels['cctv1']
        ch.last_access = time.time()
        with self.queued_probe() as (selector, loader, release, pool):
            ch.last_access = time.time() - 60
            release.set()
            pool.submit(lambda: None).result(1)
            loader.assert_not_called()
            state = selector.states['device']
            self.assertFalse(state['probing'])
            self.assertEqual(state['failures'], 0)
            self.assertEqual(state['successes'], 0)
            self.assertEqual(state['retry_at'], 0)

    def test_another_viewers_get_renews_same_channel_and_preserves_queued_probe(self):
        ch = self.channels['cctv1']
        ch.last_access = time.time()
        with self.queued_probe() as (selector, loader, release, pool):
            ch.last_access = time.time() - 60
            backup = lambda: (media(), 'backup:jce', {})
            with local_server() as server, \
                 mock.patch.object(live, 'source_loaders', return_value={'backup': backup}), \
                 mock.patch.object(live, 'schedule_source_probe'):
                self.assertEqual(request(server)[0], 200)
            self.assertTrue(live.channel_has_recent_demand(ch))
            release.set()
            pool.submit(lambda: None).result(1)
            loader.assert_called_once()
            self.assertFalse(selector.states['device']['probing'])
            self.assertEqual(selector.states['device']['failures'], 0)

    def test_head_cannot_renew_expired_demand_or_restart_refresh(self):
        ch = self.channels['cctv1']
        old_access = time.time() - 60
        ch.last_access = old_access
        with local_server() as server, \
             mock.patch.object(live, 'source_loaders', side_effect=AssertionError('HEAD must stay passive')):
            self.assertEqual(request(server, method='HEAD'), (200, b''))
        self.assertEqual(ch.last_access, old_access)
        self.assertFalse(live.channel_has_recent_demand(ch))
        self.assertIsNone(ch.thread)
        self.assertIsNone(ch._publication)

    def test_idle_channel_background_backup_paths_do_not_start_upstream_refresh(self):
        ch = self.channels['cctv1']
        ch.last_access = time.time() - 60
        ch.last_ok = time.time()
        ch.mode = 'bk'
        ch.bk_playlist = media(4)
        with mock.patch.object(live, '_refresh_and_build') as upstream:
            live.trigger_background_refresh(ch)
            # A recovery probe may reuse cache, but must not revive demand.
            live.source_loaders(ch, 'http://127.0.0.1:18767')['backup'].probe()
            with live._inflight_lock:
                pending = live._inflight_refresh.get(ch.slug)
            if pending is not None:
                self.assertTrue(pending.event.wait(1))
            upstream.assert_not_called()
        self.assertFalse(live.channel_has_recent_demand(ch))
        self.assertIsNone(ch.thread)

if __name__ == '__main__':
    unittest.main()
