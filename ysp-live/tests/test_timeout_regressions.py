"""Reproduce v9.5.3/v9.5.10 differences, then assert cold-load recovery without long cooldowns."""
import contextlib
import http.client
import importlib.util
import io
from pathlib import Path
import sys
import threading
import time
from types import SimpleNamespace
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]


def load(version):
    name = 'ysp_timeout_' + version.replace('.', '_')
    spec = importlib.util.spec_from_file_location(name, ROOT / ('ysp-live-v' + version + '.py'))
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


live = load('9.5.18')
old = load('9.5.3')
broken = load('9.5.10')
MEDIA = '#EXTM3U\n#EXT-X-TARGETDURATION:6\n#EXT-X-MEDIA-SEQUENCE:1\n#EXTINF:6,\nhttps://media.cctv.cn/1.ts\n'


class TimeoutRegressionTests(unittest.TestCase):
    def test_failed_backup_cannot_pin_primary_for_120_seconds(self):
        outcomes = {}
        for module in (old, broken, live):
            ch = module.Channel('test', 'Test', 'sid', 'pid', 'best')
            with mock.patch.object(module, 'jce_refresh', side_effect=[OSError('temporary failure'), True]) as jce, \
                 mock.patch.object(module, 'bk_refresh', side_effect=OSError('backup unavailable')):
                self.assertFalse(module.refresh_once(ch))
                outcomes[module.__version__] = module.refresh_once(ch)
            if module is live:
                self.assertEqual(ch.mode, 'jce')
                self.assertEqual(jce.call_count, 2)
        self.assertTrue(outcomes['9.5.3-local'])
        self.assertFalse(outcomes['9.5.10-local'])
        self.assertTrue(outcomes['9.5.18-local'])

    def test_failed_current_backup_retries_primary_without_waiting_for_probe_interval(self):
        ch = live.Channel('test', 'Test', 'sid', 'pid', 'best')
        ch.mode, ch._next_jce_probe = 'bk', time.monotonic() + 120
        with mock.patch.object(live, 'bk_refresh', side_effect=OSError('backup unavailable')), \
             mock.patch.object(live, 'jce_refresh', return_value=True) as primary:
            self.assertTrue(live.refresh_once(ch))
        primary.assert_called_once()
        self.assertEqual(ch.mode, 'jce')

    def test_forced_backup_channels_do_not_gain_unintended_primary_probes(self):
        ch = live.Channel('cctv11', 'Test', 'sid', 'pid', 'best')
        ch.mode = 'bk'
        with mock.patch.object(live, 'bk_refresh', side_effect=OSError('offline')), \
             mock.patch.object(live, 'jce_refresh') as primary:
            self.assertFalse(live.refresh_once(ch))
        primary.assert_not_called()

    def test_primary_is_not_probed_twice_during_one_failed_refresh(self):
        ch = live.Channel('test', 'Test', 'sid', 'pid', 'best')
        ch.mode = 'bk'
        with mock.patch.object(live, 'bk_refresh', side_effect=OSError('offline')), \
             mock.patch.object(live, 'jce_refresh', side_effect=OSError('offline')) as primary:
            self.assertFalse(live.refresh_once(ch))
        primary.assert_called_once()

    def test_slow_three_level_master_uses_v953_per_request_urllib_timeout(self):
        # Three requests each take four simulated seconds: every request fits 10s,
        # but v9.5.10's accidental shared 10s budget rejects the third response.
        class Response:
            def __init__(self, body, url):
                self.buffer, self.url = io.BytesIO(body), url
                self.status, self.headers = 200, {}
            def __enter__(self): return self
            def __exit__(self, *args): self.buffer.close()
            def read(self, size=-1): return self.buffer.read(size)
            def read1(self, size=-1): return self.buffer.read(size)
            def geturl(self): return self.url
        for module in (old, broken, live):
            clock, timeouts = [100.0], []
            def upstream(request, timeout):
                timeouts.append(timeout)
                clock[0] += 4
                depth = int(request.full_url.rsplit('/', 1)[1][0])
                body = MEDIA if depth == 3 else '#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=10\n' + str(depth + 1) + '.m3u8\n'
                return Response(body.encode(), request.full_url)
            with self.subTest(version=module.__version__), \
                 mock.patch.object(module.time, 'monotonic', side_effect=lambda: clock[0]), \
                 mock.patch.object(module.urllib.request, 'urlopen', side_effect=upstream):
                if module is broken:
                    with self.assertRaises(module.ProxyError):
                        module.fetch_abs_playlist('https://media.cctv.cn/1.m3u8', quality='best')
                else:
                    self.assertIn('#EXTINF:', module.fetch_abs_playlist('https://media.cctv.cn/1.m3u8', quality='best'))
                    self.assertEqual(timeouts, [10, 10, 10])

    def test_pending_preserves_real_errors_and_old_epochs_cannot_clear_cooldown(self):
        selector = live.SourceSelector()
        epoch = selector.attempt_token('device')
        selector.failure('device', 'HTTP 403')
        selector.pending('device', 'still loading', expected_epoch=epoch)
        self.assertEqual(selector.states['device']['failures'], 1)
        self.assertGreater(selector.states['device']['retry_at'], selector.clock())
        self.assertFalse(selector.states['device']['pending_reason'])

    def test_running_backup_is_pending_even_when_previous_failure_is_recorded(self):
        ch = live.Channel('test', 'Test', 'sid', 'pid', 'best')
        ch.last_error = 'previous timeout'
        task = live._RefreshTask()
        with mock.patch.object(live, 'engine_enabled', False), \
             mock.patch.object(live, 'ensure_channel'), \
             mock.patch.dict(live._inflight_refresh, {'test': task}):
            loader = live.source_loaders(ch, 'http://localhost:18767')['backup']
            with self.assertRaises(live.SourcePending):
                loader()

    def test_pending_http_request_does_not_block_next_ready_request(self):
        ch = live.Channel('cctv1', 'CCTV1', 'sid', 'pid', 'best')
        backend = SimpleNamespace(is_channel_in_cooldown=lambda _: False,
            fetch_channel_playlist=mock.Mock(), fetch_channel_playlist_bounded=mock.Mock(return_value=None),
            note_channel_interest=mock.Mock())
        with contextlib.ExitStack() as stack:
            stack.enter_context(mock.patch.object(live, 'CHANNEL_MAP', {'cctv1': ch}))
            stack.enter_context(mock.patch.object(live, 'resolver', backend))
            stack.enter_context(mock.patch.object(live, 'resolver_ready', return_value=True))
            stack.enter_context(mock.patch.object(live, 'engine_enabled', False))
            loaders = live.source_loaders(ch, 'http://localhost:18767')
            stack.enter_context(mock.patch.object(live, 'source_loaders', return_value={'device': loaders['device']}))
            srv = live.BoundedHTTPServer(('127.0.0.1', 0), live.Handler)
            srv.access_token = ''
            worker = threading.Thread(target=srv.serve_forever, daemon=True)
            worker.start()
            try:
                def request():
                    with contextlib.closing(http.client.HTTPConnection('127.0.0.1', srv.server_port, timeout=2)) as connection:
                        connection.request('GET', '/cctv1.m3u8')
                        response = connection.getresponse()
                        return response.status, dict(response.getheaders()), response.read()
                first, headers, _ = request()
                self.assertEqual((first, headers['Retry-After']), (503, '1'))
                backend.fetch_channel_playlist_bounded.assert_called_with(
                    'cctv1', 'localhost:18767', 'http', _record_interest=False)
                state = ch.selector.states['device']
                self.assertEqual(state['failures'], 0)
                self.assertEqual(state['retry_at'], 0)
                self.assertTrue(state['pending_reason'])
                backend.fetch_channel_playlist_bounded.return_value = MEDIA
                self.assertEqual(request()[0], 200)
                self.assertEqual(state['failures'], 0)
                self.assertFalse(state['pending_reason'])
            finally:
                srv.shutdown()
                srv.server_close()
                worker.join(2)


if __name__ == '__main__':
    unittest.main()
