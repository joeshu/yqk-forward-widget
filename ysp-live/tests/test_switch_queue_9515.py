"""Switching must not queue deferral or fresh device playlists behind network work."""
import concurrent.futures
import contextlib
import http.client
import importlib.util
from pathlib import Path
import sys
import tempfile
import threading
import time
import unittest
from unittest import mock

from test_release_959 import args, entry, server

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('ysp_switch_queue_9515', ROOT / 'ysp-live-v9.5.15.py')
live = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = live
spec.loader.exec_module(live)


def media(seq=1):
    return f'#EXTM3U\n#EXT-X-TARGETDURATION:6\n#EXT-X-MEDIA-SEQUENCE:{seq}\n#EXTINF:6,\nhttps://media.cctv.cn/{seq}.ts\n'


class QueueTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.r = live.Resolver(args(directory.name))
        self.addCleanup(self.r.close)
        self.r.args.foreground_wait = 2

    @contextlib.contextmanager
    def saturated(self):
        release, entered = threading.Event(), threading.Barrier(5)
        def occupied():
            entered.wait(3)
            release.wait(5)
        futures = [self.r._foreground_pool.submit(occupied) for _ in range(4)]
        entered.wait(3)
        try:
            yield
        finally:
            release.set()
            for future in futures:
                future.result(3)

    def test_debounced_request_never_waits_for_a_busy_pool(self):
        with self.saturated(), mock.patch.object(self.r, 'fetch_channel_playlist') as upstream:
            start = time.monotonic()
            self.assertIsNone(self.r.fetch_channel_playlist_bounded('cctv1', 'local'))
            self.assertLess(time.monotonic() - start, .2)
            upstream.assert_not_called()
            self.assertFalse(self.r._foreground_flights)
        self.assertEqual(self.r._stats['foreground_deferred'], 1)

    def test_fresh_device_cache_bypasses_pool_and_keeps_its_quality(self):
        e = entry()
        self.r.state.cache['cctv1'] = e
        now = time.monotonic()
        self.r._playlist_raw['cctv1'] = live.RawPlaylist(self.r._playlist_source_key(e), media(),
            'application/vnd.apple.mpegurl', now, now + 10, now + 20)
        with self.saturated(), mock.patch.object(self.r, 'fetch_channel_playlist') as upstream:
            start = time.monotonic()
            body = self.r.fetch_channel_playlist_bounded('cctv1', 'local')
            self.assertIn('#EXTINF:', body)
            self.assertIn('/proxy', body)
            self.assertLess(time.monotonic() - start, .2)
            upstream.assert_not_called()
        self.assertEqual(self.r._stats['foreground_cache_hit'], 1)

    def test_device_cache_never_crosses_generation_or_failure(self):
        self.r.args.zap_debounce = 0
        e = entry()
        self.r.state.cache['cctv1'] = e
        now = time.monotonic()
        self.r._playlist_raw['cctv1'] = live.RawPlaylist(self.r._playlist_source_key(e), media(), 'x', now, now+10, now+20)
        replacement = live.dataclasses.replace(e, generation=e.generation + 1)
        self.r.state.cache['cctv1'] = replacement
        self.assertFalse(self.r.has_cached_channel_playlist('cctv1'))
        self.assertIsNone(self.r.cached_channel_playlist('cctv1', 'local'))
        self.r.state.cache['cctv1'] = e
        self.r.state.channel_failures['cctv1'] = (time.time(), 'real failure', 1)
        self.assertFalse(self.r.has_cached_channel_playlist('cctv1'))

    def test_true_4k_does_not_get_ordinary_deferral_shortcut(self):
        with mock.patch.object(self.r, 'fetch_channel_playlist', return_value=media()) as upstream:
            self.assertIn('#EXTINF:', self.r.fetch_channel_playlist_bounded('cctv4k', 'local'))
            upstream.assert_called_once()


class PreparationTests(unittest.TestCase):
    def request(self, srv, slug):
        with contextlib.closing(http.client.HTTPConnection('127.0.0.1', srv.server_port, timeout=3)) as connection:
            connection.request('GET', '/' + slug + '.m3u8')
            response = connection.getresponse()
            return response.status, response.getheader('X-Source'), response.read()

    def run_loaders(self, slug='cctv1', cached=False, prepare_error=False, ongoing=False):
        ch = live.Channel(slug, slug, 'sid', 'pid', 'best')
        if ongoing:
            ch.last_access = time.time()
            live.channel_selector(ch).commit('device')
        prepared = threading.Event()
        def prepare():
            prepared.set()
            if prepare_error:
                raise RuntimeError('no prefetch capacity')
        backup = mock.Mock(return_value=(media(), 'backup:bk', {}))
        backup.prepare = mock.Mock(side_effect=prepare)
        def device():
            if slug not in live.TRUE_4K_CHANNELS and not cached and not prepare_error and not ongoing:
                if not prepared.wait(.5):
                    raise AssertionError('backup not started before device wait')
            return media(), 'device', {}
        backend = mock.Mock()
        backend.has_cached_channel_playlist.return_value = cached
        with mock.patch.object(live, 'CHANNEL_MAP', {slug: ch}), \
             mock.patch.object(live, 'resolver', backend), \
             mock.patch.object(live, 'source_loaders', return_value={'device': device, 'backup': backup}), \
             server(live.Handler) as srv:
            srv.access_token = ''
            response = self.request(srv, slug)
        self.assertEqual(response[:2], (200, 'device'))
        self.assertEqual(ch.selector.selected, 'device')
        backup.assert_not_called()
        return backup.prepare

    def test_preparation_overlaps_device_wait_but_does_not_select_backup(self):
        self.run_loaders().assert_called_once()

    def test_cached_device_and_true_4k_do_not_trigger_backup_preparation(self):
        self.run_loaders(cached=True).assert_not_called()
        self.run_loaders(slug='cctv4k').assert_not_called()

    def test_ongoing_device_viewing_does_not_keep_prefetching_backup(self):
        self.run_loaders(ongoing=True).assert_not_called()

    def test_optional_preparation_error_does_not_break_preferred_source(self):
        self.run_loaders(prepare_error=True).assert_called_once()


if __name__ == '__main__':
    unittest.main()
