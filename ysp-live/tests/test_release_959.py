"""Regression scenarios for the six v9.5.9 improvements; all HTTP origins are local."""
import concurrent.futures
import contextlib
import dataclasses
import errno
import gzip
import http.client
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import importlib.util
import io
import json
import os
from pathlib import Path
import stat
import sys
import tempfile
import threading
import time
from types import SimpleNamespace
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('ysp_release_959', ROOT / 'ysp-live-v9.5.17.py')
live = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = live
spec.loader.exec_module(live)


def args(directory):
    return SimpleNamespace(timeout=1, insecure_tls=False, meta_json=str(Path(directory) / 'meta.json'),
        device_json=str(Path(directory) / 'device.json'), heartbeat_interval=30, heartbeat_ttl_guard=60,
        background_refresh_queue_limit=16, refresh_interval=0, control_step_jitter_min_ms=0,
        control_step_jitter_max_ms=0, session_ttl=3600, stale_while_refresh_ttl=0,
        refresh_error_cooldown=2, identity_reset_error_threshold=0, identity_reset_cooldown=300,
        links_per_device=6, playlist_cache_ttl=2, cache_ttl=600, http_workers=8,
        http_queue_limit=16, zap_debounce=10, foreground_wait=.05)


def entry():
    return live.ChannelEntry(channel='cctv1', final_url='https://media.cctv.cn/index.m3u8',
        android_id='test', generation=20, session_generation=4, refreshed_at=time.time(), expires_at=time.time() + 600)


def window(start, count):
    return '#EXTM3U\n#EXT-X-TARGETDURATION:6\n#EXT-X-MEDIA-SEQUENCE:' + str(start) + '\n' + ''.join(
        '#EXTINF:6,\nhttps://media.cctv.cn/' + str(n) + '.ts\n' for n in range(start, start + count))


@contextlib.contextmanager
def server(handler, server_class=ThreadingHTTPServer):
    srv = server_class(('127.0.0.1', 0), handler)
    worker = threading.Thread(target=srv.serve_forever, daemon=True)
    worker.start()
    try:
        yield srv
    finally:
        srv.shutdown()
        srv.server_close()
        worker.join(2)


class StateAndDebounceTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.args = args(self.directory.name)
        self.resolver = live.Resolver(self.args)
        self.addCleanup(self.resolver.close)

    def test_prefetch_rechecks_interest_after_waiting_for_protocol_lock(self):
        r = self.resolver
        queued, release = threading.Event(), threading.Event()
        class Gate:
            def __enter__(self):
                queued.set()
                if not release.wait(3):
                    raise AssertionError('test did not release protocol queue')
            def __exit__(self, *args):
                pass
        r.control_lock = Gate()
        r.state.zap_generations['cctv1'] = 1
        r.state.zap_pending_channels.add('cctv1')
        r._zap_interest['cctv1'] = {'since': time.monotonic() - 10,
                                  'last': time.monotonic(), 'samples': 2}
        with mock.patch.object(r, 'refresh_channel_controlled') as upstream, \
             mock.patch.object(r, 'rotate_device_on_400') as rotate, \
             mock.patch.object(r, 'write_meta') as persist:
            worker = threading.Thread(target=r._zap_resolve_worker, args=('cctv1', 1, 0))
            worker.start()
            try:
                self.assertTrue(queued.wait(2))
                with r.state_lock:
                    r._zap_interest['cctv1']['last'] -= 60
            finally:
                release.set()
                worker.join(3)
            self.assertFalse(worker.is_alive())
            upstream.assert_not_called()
            rotate.assert_not_called()
            persist.assert_not_called()
        self.assertFalse(r.state.channel_failures)
        self.assertFalse(r._channel_flights)
        self.assertNotIn('cctv1', r.state.zap_pending_channels)
        self.assertEqual(r._stats['zap_skipped_inactive'], 1)

    def test_active_prefetch_and_explicit_foreground_keep_high_quality_resolution(self):
        r = self.resolver
        r.state.zap_generations['cctv1'] = 1
        r._zap_interest['cctv1'] = {'since': time.monotonic() - 10,
                                  'last': time.monotonic(), 'samples': 2}
        with mock.patch.object(r, 'refresh_channel_controlled', return_value=entry()) as upstream, \
             mock.patch.object(r, 'write_meta'):
            r._zap_resolve_worker('cctv1', 1, 0)
            upstream.assert_called_once_with('cctv1')
            r._zap_interest.clear()
            r.ensure_channel('cctv1')
            self.assertEqual(upstream.call_count, 2)

    def test_400_rotation_purges_disk_cache_and_preserves_restart_budget(self):
        r = self.resolver
        r.state.cache['cctv1'] = entry()
        r.state.generation, r.state.session_generation = 20, 4
        r.write_meta()
        self.assertIn('cctv1', live.load_cache(r.args.meta_json))
        self.assertTrue(r.rotate_device_on_400('HTTP 400'))
        self.assertFalse(live.load_cache(r.args.meta_json))
        self.assertTrue(Path(r.args.device_json).is_file())
        restarted = live.Resolver(self.args)
        self.addCleanup(restarted.close)
        self.assertEqual(restarted.state.device_wipe_count, 1)
        self.assertEqual((restarted.state.generation, restarted.state.session_generation), (20, 4))
        self.assertFalse(restarted.rotate_device_on_400('HTTP 400 again'))

    def test_metadata_write_failure_does_not_claim_or_start_identity_rotation(self):
        r = self.resolver
        r.state.cache['cctv1'] = entry()
        with mock.patch.object(live, 'atomic_json_write', side_effect=OSError('disk full')), \
             mock.patch.object(live, 'create_and_save_new_device') as create:
            self.assertFalse(r.rotate_device_on_400('HTTP 400'))
        create.assert_not_called()
        self.assertIn('cctv1', r.state.cache)

    def test_device_save_failure_is_reported_and_old_disk_urls_stay_retired(self):
        r = self.resolver
        r.state.cache['cctv1'] = entry()
        with mock.patch.object(live, 'save_device_state', side_effect=OSError('read only')):
            with self.assertRaises(OSError):
                live.create_and_save_new_device(r.args.device_json)
            self.assertFalse(r.rotate_device_on_400('HTTP 400'))
        self.assertFalse(live.load_cache(r.args.meta_json))
        self.assertFalse(r.state.cache)
        self.assertIn('persistence', r._worker_error)

    def test_one_invalid_cache_entry_does_not_discard_healthy_entries(self):
        good = dataclasses.asdict(entry())
        bad = dict(good, channel='cctv2', expires_at=float('nan'))
        live.atomic_json_write(self.args.meta_json, {'cache_detail': {'cctv1': good, 'cctv2': bad}})
        self.assertEqual(list(live.load_cache(self.args.meta_json)), ['cctv1'])

    def test_successful_retry_clears_persistence_error(self):
        with mock.patch.object(live.os, 'replace', side_effect=OSError('disk full')):
            with self.assertRaises(OSError):
                live.atomic_json_write(self.args.meta_json, {'v': 1})
        self.assertIn(self.args.meta_json, live.persistence_status())
        live.atomic_json_write(self.args.meta_json, {'v': 2})
        self.assertNotIn(self.args.meta_json, live.persistence_status())
        self.assertEqual(json.loads(Path(self.args.meta_json).read_text()), {'v': 2})

    def test_unsupported_directory_fsync_does_not_misreport_completed_write(self):
        fsync = os.fsync
        def platform_fsync(fd):
            if stat.S_ISDIR(os.fstat(fd).st_mode):
                raise OSError(errno.EINVAL, 'unsupported directory fsync')
            return fsync(fd)
        with mock.patch.object(live.os, 'fsync', side_effect=platform_fsync):
            live.atomic_json_write(self.args.meta_json, {'v': 1})
        self.assertEqual(json.loads(Path(self.args.meta_json).read_text()), {'v': 1})

    def test_abandoned_single_request_never_resolves_a_high_rate_source(self):
        r = self.resolver
        r.note_channel_interest('cctv1')
        r.state.zap_generations['cctv1'] = 1
        r.state.zap_pending_channels.add('cctv1')
        r.ensure_channel = mock.Mock()
        r._zap_resolve_worker('cctv1', 1, 0)
        r.ensure_channel.assert_not_called()
        self.assertNotIn('cctv1', r.state.zap_pending_channels)

    def test_active_channel_reuses_cache_instead_of_forcing_new_resolution(self):
        r = self.resolver
        r.note_channel_interest('cctv1')
        r._zap_interest['cctv1']['samples'] = 2
        r.state.zap_generations['cctv1'] = 1
        r.ensure_channel = mock.Mock()
        r._zap_resolve_worker('cctv1', 1, 0)
        r.ensure_channel.assert_called_once_with('cctv1', interest_generation=1)

    def test_old_debounce_worker_cannot_clear_new_pending_task(self):
        r = self.resolver
        r.state.zap_generations['cctv1'] = 2
        r.state.zap_pending_channels.add('cctv1')
        r._zap_resolve_worker('cctv1', 1, 0)
        self.assertIn('cctv1', r.state.zap_pending_channels)

    def test_duplicate_internal_observations_do_not_count_as_continuous_viewing(self):
        r = self.resolver
        with mock.patch.object(live.time, 'monotonic', side_effect=[100, 100.01, 101]):
            r.note_channel_interest('cctv1')
            r.note_channel_interest('cctv1')
            self.assertEqual(r._zap_interest['cctv1']['samples'], 1)
            r.note_channel_interest('cctv1')
        self.assertEqual(r._zap_interest['cctv1']['samples'], 2)

    def test_wall_clock_jump_does_not_end_monotonic_debounce_early(self):
        r = self.resolver
        r._zap_interest['cctv1'] = {'since': 100, 'last': 104, 'samples': 2}
        with mock.patch.object(live.time, 'monotonic', return_value=104), \
             mock.patch.object(live.time, 'time', return_value=time.time() + 86400), \
             mock.patch.object(live.threading.Thread, 'start'):
            self.assertTrue(r.zap_debounced('cctv1'))


class TimelineAndHLSTests(unittest.TestCase):
    def channel(self):
        return live.Channel('test', 'Test', 'sid', 'pid', 'best')

    def test_cold_channel_tries_backup_after_first_jce_failure(self):
        ch = self.channel()
        with mock.patch.object(live, 'jce_refresh', side_effect=OSError('offline')) as jce, \
             mock.patch.object(live, 'bk_refresh', return_value=True) as bk:
            self.assertTrue(live.refresh_once(ch))
        jce.assert_called_once()
        bk.assert_called_once()
        self.assertEqual(ch.mode, 'bk')

    def test_warm_channel_retains_jce_grace_period_on_temporary_failure(self):
        ch = self.channel()
        ch.segments['existing'] = [1, 6, '', 'https://media.cctv.cn/1.ts']
        with mock.patch.object(live, 'jce_refresh', side_effect=OSError('temporary')), \
             mock.patch.object(live, 'bk_refresh') as bk:
            self.assertFalse(live.refresh_once(ch))
        bk.assert_not_called()
        self.assertEqual(ch.mode, 'jce')

    def test_initial_omitted_segments_without_pdt_are_never_appended_as_new(self):
        ch = self.channel()
        fetched = live._FetchedSegments(window(0, 31))
        with mock.patch.object(live, 'jce_fetch', return_value=fetched):
            live.jce_refresh(ch)
            before = ch.seq
            live.jce_refresh(ch)
        self.assertEqual(ch.seq, before)
        self.assertEqual(len(ch.order), 25)

    def test_older_unknown_prefix_without_pdt_does_not_move_edge_backwards(self):
        ch = self.channel()
        with mock.patch.object(live, 'jce_fetch', side_effect=[live._FetchedSegments(window(100, 5)),
                live._FetchedSegments(window(98, 7)), live._FetchedSegments(window(104, 3))]):
            live.jce_refresh(ch)
            live.jce_refresh(ch)
            self.assertEqual(ch.seq, 5)
            live.jce_refresh(ch)
        self.assertEqual(ch.seq, 7)
        self.assertEqual([s.source_sequence for s in ch.segment_models.values()], list(range(100, 107)))

    def test_gzip_bom_and_decompression_budget(self):
        body = b'\xef\xbb\xbf' + window(1, 1).encode()
        self.assertTrue(live.decode_hls_bytes(gzip.compress(body)).startswith('#EXTM3U'))
        with self.assertRaises(live.ProxyError):
            live.decode_hls_bytes(gzip.compress(b'x' * 20000), limit=512)

    def test_invalid_sequence_range_and_implicit_map_are_not_rewritten(self):
        for text in [window(1, 1).replace('#EXTINF', '#EXT-X-DISCONTINUITY-SEQUENCE:-1\n#EXTINF'),
                     window(1, 1).replace('#EXTINF:6,', '#EXTINF:6,\n#EXT-X-BYTERANGE:0@0')]:
            with self.assertRaises(live.UnsafePlaylist):
                live.parse_media(text)
        media = live.parse_media(window(1, 1).replace('#EXTINF', '#EXT-X-MAP:URI="init.mp4",BYTERANGE="20"\n#EXTINF'))
        self.assertTrue(media.unsafe)
        with self.assertRaises(live.UnsafePlaylist):
            live.render_media(media)

    def test_inline_data_key_is_preserved_in_proxy_playlists(self):
        text = '#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI="data:application/octet-stream;base64,YWJj"\n#EXTINF:6,\na.ts\n'
        result = live.render_media_playlist(text, 'https://media.cctv.cn/list.m3u8')
        self.assertIn('URI="data:application/octet-stream;base64,YWJj"', result)
        self.assertIn('/proxy?resource=', result)

    def test_real_redirect_gzip_master_retains_best_quality_and_final_relative_base(self):
        calls = []
        class Origin(BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass
            def do_GET(self):
                calls.append(self.path)
                targets = {'/start': '/final/master.m3u8', '/final/high.m3u8': '/cdn/media.m3u8'}
                if self.path in targets:
                    self.send_response(308)
                    self.send_header('Location', targets[self.path])
                    self.end_headers()
                    return
                if self.path == '/final/master.m3u8':
                    text = '#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1,RESOLUTION=1920x1080\nlow.m3u8\n#EXT-X-STREAM-INF:BANDWIDTH=2,RESOLUTION=3840x2160\nhigh.m3u8\n'
                else:
                    text = '\ufeff#EXTM3U\n#EXT-X-TARGETDURATION:6\n#EXT-X-KEY:METHOD=AES-128,URI="key.bin"\n#EXTINF:6,\nseg.ts\n'
                body = gzip.compress(text.encode())
                self.send_response(200)
                self.send_header('Content-Encoding', 'GZip')
                self.send_header('Content-Length', str(len(body)))
                self.end_headers()
                self.wfile.write(body)
        with server(Origin) as srv, mock.patch.dict(os.environ, {'NO_PROXY': '127.0.0.1', 'no_proxy': '127.0.0.1'}):
            base = 'http://127.0.0.1:' + str(srv.server_port)
            text = live.fetch_abs_playlist(base + '/start', quality='best')
        self.assertIn(base + '/cdn/seg.ts', text)
        self.assertIn('URI="' + base + '/cdn/key.bin"', text)
        self.assertNotIn('/final/low.m3u8', calls)
        self.assertEqual(live.analyze_playlist(text).profile.height, 2160)


class CacheAndProxyTests(unittest.TestCase):
    def setUp(self):
        policy = SimpleNamespace(resolve=lambda url: None)
        self.proxy = live.SharedMediaProxy(policy=policy, max_cache_bytes=128)
        self.addCleanup(self.proxy.close)

    def task(self, name, payload=b'x' * 64):
        task = live._Transfer('https://media.cctv.cn/' + name, {})
        self.addCleanup(task.file.close)
        live._write_at(task, payload, 0)
        task.status, task.size, task.headers = 200, len(payload), {'content-type': 'video/mp2t'}
        return task

    def store(self, task):
        self.proxy._store_cache(self.proxy._key(task.url, {}), task)

    def test_full_cache_hit_updates_lru_instead_of_fifo(self):
        a, b, c = [self.task(name) for name in ['a.ts', 'b.ts', 'c.ts']]
        self.store(a)
        self.store(b)
        handler = SimpleNamespace(headers={}, close_connection=False, send_response=lambda *a: None,
            send_header=lambda *a: None, end_headers=lambda: None)
        with mock.patch.object(live, '_client_write'):
            self.assertEqual(self.proxy.serve(handler, a.url), 200)
        self.store(c)
        self.assertEqual([key[0] for key in self.proxy.cache], [a.url, c.url])

    def test_prefix_probe_also_updates_lru(self):
        a, b, c = [self.task(name) for name in ['a.ts', 'b.ts', 'c.ts']]
        self.store(a)
        self.store(b)
        self.assertEqual(self.proxy.cached_prefix(a.url, {}), b'x' * 64)
        self.store(c)
        self.assertNotIn(self.proxy._key(b.url, {}), self.proxy.cache)

    def test_cache_copy_releases_global_lock_and_reserves_its_memory(self):
        a, b = self.task('a.ts'), self.task('b.ts')
        self.store(b)
        entered, release = threading.Event(), threading.Event()
        original = live._read_at
        def delayed(task, *args):
            if task is a:
                entered.set()
                release.wait(2)
            return original(task, *args)
        with mock.patch.object(live, '_read_at', side_effect=delayed), concurrent.futures.ThreadPoolExecutor(2) as pool:
            future = pool.submit(self.store, a)
            try:
                self.assertTrue(entered.wait(1))
                self.assertEqual(pool.submit(self.proxy.cached_prefix, b.url, {}).result(.5), b'x' * 64)
                self.assertEqual(self.proxy.cache_build_bytes, 64)
                self.assertLessEqual(self.proxy.cache_bytes + self.proxy.cache_build_bytes, 128)
            finally:
                release.set()
            future.result(2)
        self.assertEqual(self.proxy.cache_build_bytes, 0)

    def test_parallel_cache_builds_never_exceed_reserved_ram_budget(self):
        self.proxy.max_cache_bytes = 64
        a, b = self.task('a.ts'), self.task('b.ts')
        entered, release = threading.Event(), threading.Event()
        original = live._read_at
        copied = []
        def delayed(task, *args):
            copied.append(task.url)
            if task is a:
                entered.set()
                release.wait(2)
            return original(task, *args)
        with mock.patch.object(live, '_read_at', side_effect=delayed), concurrent.futures.ThreadPoolExecutor(1) as pool:
            future = pool.submit(self.store, a)
            try:
                self.assertTrue(entered.wait(1))
                self.store(b)
                self.assertNotIn(b.url, copied)
                self.assertEqual(self.proxy.cache_build_bytes, 64)
            finally:
                release.set()
            future.result(2)
        self.assertEqual(self.proxy.cache_bytes, 64)
        self.assertEqual(self.proxy.cache_build_bytes, 0)

    def test_gzip_proxy_playlist_is_rewritten_with_correct_response_headers(self):
        payload = gzip.compress(window(1, 1).replace('https://media.cctv.cn/1.ts', 'seg.ts').encode())
        class Origin(BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass
            def do_GET(self):
                self.send_response(200)
                self.send_header('Content-Type', 'application/vnd.apple.mpegurl')
                self.send_header('Content-Encoding', 'GZip')
                self.send_header('Content-Length', str(len(payload)))
                self.end_headers()
                self.wfile.write(payload)
        with server(Origin) as srv, mock.patch.dict(os.environ, {'NO_PROXY': '127.0.0.1', 'no_proxy': '127.0.0.1'}):
            proxy = live.SharedMediaProxy(policy=live.URLPolicy(('127.0.0.1',), allow_private=True), max_cache_bytes=0)
            self.addCleanup(proxy.close)
            url = f'http://127.0.0.1:{srv.server_port}/final/list.m3u8'
            task = live._Transfer(url, {}, subscribers=1)
            self.addCleanup(task.file.close)
            key = proxy._key(url, {})
            proxy.tasks[key] = task
            self.assertTrue(proxy.slots.acquire(blocking=False))
            proxy._produce(key, task)
            self.assertIsNone(task.error)
            body = live._read_at(task, task.size, 0)
            self.assertTrue(body.startswith(b'#EXTM3U'))
            self.assertIn(b'/proxy?resource=', body)
            self.assertNotIn('content-encoding', task.headers)
            self.assertEqual(int(task.headers['content-length']), len(body))
            token = body.decode().split('/proxy?resource=', 1)[1].splitlines()[0]
            self.assertEqual(live.resolve_resource(token).url, f'http://127.0.0.1:{srv.server_port}/final/seg.ts')
            task.subscribers = 0
            proxy._cleanup(key, task)
            self.assertEqual(proxy.inflight_bytes, 0)

    def test_failed_copy_releases_memory_reservation(self):
        with mock.patch.object(live, '_read_at', side_effect=OSError('read failed')):
            with self.assertRaises(OSError):
                self.store(self.task('a.ts'))
        self.assertEqual(self.proxy.cache_build_bytes, 0)
        self.assertFalse(self.proxy.cache)

    def test_close_during_cache_copy_never_repopulates_cache(self):
        entered, release = threading.Event(), threading.Event()
        original = live._read_at
        def delayed(*args):
            entered.set()
            release.wait(2)
            return original(*args)
        with mock.patch.object(live, '_read_at', side_effect=delayed), concurrent.futures.ThreadPoolExecutor(1) as pool:
            future = pool.submit(self.store, self.task('a.ts'))
            self.assertTrue(entered.wait(1))
            self.proxy.close()
            release.set()
            future.result(2)
        self.assertFalse(self.proxy.cache)
        self.assertEqual(self.proxy.cache_build_bytes, 0)

    def test_host_validation_and_catchup_limits(self):
        for authority in ['a:bad', 'a:0', 'a:65536', 'user@a', 'a/b', 'a\tb', 'a#fragment']:
            with self.subTest(authority=authority), self.assertRaises(ValueError):
                live.validate_public_authority(authority)
        self.assertEqual(live.validate_public_authority('[2001:db8::1]:8443'), '[2001:db8::1]:8443')
        now = int(time.time())
        self.assertEqual(live.parse_catchup_query(f'start={now-60}&end={now+5}'), (now-60, now))
        with self.assertRaises(live.CatchupError):
            live.parse_catchup_query(f'start={now}&end={now+5}')
        with self.assertRaises(ValueError):
            live.parse_catchup_query('&'.join('k'+str(i)+'=x' for i in range(40)))

    def test_trusted_forwarded_headers_generate_https_public_subscription(self):
        with server(live.Handler, live.BoundedHTTPServer) as srv:
            srv.trust_proxy, srv.access_token, srv.public_base_url = True, '', ''
            def request(headers):
                with contextlib.closing(http.client.HTTPConnection('127.0.0.1', srv.server_port, timeout=2)) as connection:
                    connection.request('GET', '/all.m3u', headers=headers)
                    response = connection.getresponse()
                    return response.status, response.read().decode()
            status, body = request({'Host': 'internal:8767', 'Forwarded': 'for=192.0.2.1;proto=https;host="tv.example.com:443"'})
            self.assertEqual(status, 200)
            self.assertIn('https://tv.example.com:443/cctv1.m3u8', body)
            srv.trust_proxy = False
            status, body = request({'Host': 'internal:8767', 'Forwarded': 'proto=https;host="spoof.example"'})
            self.assertEqual(status, 200)
            self.assertIn('http://internal:8767/cctv1.m3u8', body)
            self.assertNotIn('spoof.example', body)
            srv.trust_proxy = True
            status, body = request({'Host': 'internal', 'X-Forwarded-Host': '[2001:db8::1]:8443', 'X-Forwarded-Proto': 'https'})
            self.assertEqual(status, 200)
            self.assertIn('https://[2001:db8::1]:8443/cctv1.m3u8', body)

    def test_duplicate_host_and_excessive_query_fields_are_rejected(self):
        with server(live.Handler, live.BoundedHTTPServer) as srv:
            srv.trust_proxy, srv.access_token, srv.public_base_url = False, '', ''
            with contextlib.closing(http.client.HTTPConnection('127.0.0.1', srv.server_port, timeout=2)) as connection:
                connection.putrequest('GET', '/all.m3u', skip_host=True)
                connection.putheader('Host', 'one.example')
                connection.putheader('Host', 'two.example')
                connection.endheaders()
                response = connection.getresponse()
                self.assertEqual(response.status, 400)
                response.read()
            with contextlib.closing(http.client.HTTPConnection('127.0.0.1', srv.server_port, timeout=2)) as connection:
                connection.request('GET', '/all.m3u?' + '&'.join('k'+str(i)+'=x' for i in range(80)))
                response = connection.getresponse()
                self.assertEqual(response.status, 400)
                response.read()


if __name__ == '__main__':
    unittest.main()
