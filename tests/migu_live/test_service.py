from concurrent.futures import ThreadPoolExecutor
from contextlib import contextmanager
from datetime import timedelta
import http.client
import json
import os
from pathlib import Path
import tempfile
import threading
import time
import unittest
from unittest.mock import Mock, patch
from urllib.parse import urlsplit

import update_migu as m
import importlib.util
import sys
_spec = importlib.util.spec_from_file_location('migu_historical_service', Path('migu/migu-live-v0.2.1.py'))
s = importlib.util.module_from_spec(_spec)
sys.modules[_spec.name] = s
_spec.loader.exec_module(s)
s.m = m  # Test historical service behavior against the separately maintained updater.
from migu import service as current

TOKEN = 't' * 43


def catalogue(count=2, signed_at=None, catchup=False):
    timestamp = (signed_at or m.utcnow()).astimezone(m.CHINA).strftime('%Y%m%d%H%M%S')
    header = '#EXTM3U'
    if catchup:
        header += ' catchup="append" catchup-source="' + m.CATCHUP_SOURCE + '"'
    lines = [header]
    for i in range(count):
        lines += [f'#EXTINF:-1 tvg-id="测试{i}" tvg-name="测试{i}" group-title="央视",测试{i}', f'http://gslbmgsplive.miguvideo.com/live/ch{i}/index.m3u8?timestamp={timestamp}&ProgramID={100+i}&token=source-private']
    return ('\n'.join(lines) + '\n').encode()


class StoreTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)

    def store(self, client_factory=None, **kwargs):
        store = s.CatalogueStore(self.directory, min_channels=1, client_factory=client_factory or Mock(), **kwargs)
        self.addCleanup(store.close)
        return store

    def test_multiple_viewers_share_one_initial_catalogue_refresh(self):
        entered, release = threading.Event(), threading.Event()
        client = Mock()
        def fetch(*args, **kwargs):
            entered.set()
            release.wait(2)
            return catalogue(), {'ETag': '"one"'}
        client.get.side_effect = fetch
        store = self.store(Mock(return_value=client))
        with ThreadPoolExecutor(max_workers=10) as pool:
            futures = [pool.submit(store.get, 3) for _ in range(10)]
            self.assertTrue(entered.wait(1))
            release.set()
            snapshots = [future.result(3) for future in futures]
        self.assertEqual(client.get.call_count, 1)
        self.assertTrue(all(value is snapshots[0] for value in snapshots))
        self.assertNotIn('source-private', json.dumps(store.status()))
        if os.name != 'nt':
            self.assertEqual((self.directory/'catalogue.m3u8').stat().st_mode & 0o777, 0o600)

    def test_soft_expiry_serves_valid_snapshot_while_refresh_runs(self):
        now = [0]
        client = Mock()
        client.get.return_value = (catalogue(), {})
        store = self.store(Mock(return_value=client), clock=lambda: now[0], refresh_seconds=10)
        old = store.get(2)
        entered, release = threading.Event(), threading.Event()
        def slow(*args, **kwargs):
            entered.set()
            release.wait(2)
            return catalogue(), {}
        client.get.side_effect = slow
        now[0] = 11
        self.assertIs(store.get(0), old)
        self.assertTrue(entered.wait(1))
        self.assertIs(store.get(0), old)
        release.set()
        with store.lock:
            future = store.future
        if future:
            future.result(2)

    def test_failed_or_incomplete_refresh_keeps_previous_generation(self):
        client, now = Mock(), [0]
        client.get.return_value = (catalogue(), {})
        store = self.store(Mock(return_value=client), clock=lambda: now[0], refresh_seconds=10)
        previous = store.get(2)
        original = store.cache.read_bytes()
        client.get.return_value = (catalogue(1), {})
        now[0] = 11
        self.assertIs(store.get(0), previous)
        with store.lock:
            future = store.future
        if future:
            future.result(2)
        self.assertEqual(store.cache.read_bytes(), original)
        self.assertEqual(store.status()['last_error'], 'CHANNEL_RETENTION_TOO_LOW')
        calls = client.get.call_count
        self.assertIs(store.get(0), previous)
        self.assertEqual(client.get.call_count, calls)

    def test_304_does_not_rewrite_private_files_and_revalidates_absolute_age(self):
        client, now = Mock(), [0]
        client.get.return_value = (catalogue(), {'ETag': '"one"'})
        store = self.store(Mock(return_value=client), clock=lambda: now[0], refresh_seconds=10)
        store.get(2)
        times = (store.cache.stat().st_mtime_ns, store.meta_path.stat().st_mtime_ns)
        client.get.return_value = (None, {})
        now[0] = 11
        store.get(0)
        with store.lock:
            future = store.future
        if future:
            future.result(2)
        self.assertEqual(client.get.call_args.kwargs['headers'], {'If-None-Match': '"one"'})
        self.assertEqual(times, (store.cache.stat().st_mtime_ns, store.meta_path.stat().st_mtime_ns))
        with patch.object(m, 'utcnow', return_value=m.utcnow()+timedelta(hours=13)):
            self.assertFalse(store.status()['catalogue_ready'])
            now[0] = 30
            with self.assertRaises(s.ServiceError):
                store.get(2)

    def test_disk_failure_does_not_publish_candidate_in_memory(self):
        client = Mock()
        client.get.return_value = (catalogue(), {})
        store = self.store(Mock(return_value=client))
        with patch.object(s, 'private_write', side_effect=OSError('disk full')):
            with self.assertRaises(s.ServiceError):
                store.get(2)
        self.assertFalse(store.status()['catalogue_ready'])

    def test_channel_urls_are_stable_across_signature_and_display_name_changes(self):
        first = m.parse_playlist(catalogue())
        second = m.parse_playlist(catalogue(signed_at=m.utcnow()+timedelta(seconds=1)).replace('测试0'.encode(), '新显示名'.encode()))
        self.assertEqual(s.channel_key(first.channels[0]), s.channel_key(second.channels[0]))


class ManifestTests(unittest.TestCase):
    def test_final_response_base_audio_and_variant_signatures_are_preserved(self):
        raw = b'#EXTM3U\n#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="a",URI="audio.m3u8?sig=a%2Bb"\n#EXT-X-STREAM-INF:BANDWIDTH=800000,AUDIO="a"\nvideo.m3u8?sig=z%3D\n'
        result = current.rewrite_manifest(raw, 'http://hlszymgsplive.miguvideo.com:8080/cdn/master.m3u8?old=do-not-copy')
        self.assertIn(b'URI="http://hlszymgsplive.miguvideo.com:8080/cdn/audio.m3u8?sig=a%2Bb"', result)
        self.assertIn(b'http://hlszymgsplive.miguvideo.com:8080/cdn/video.m3u8?sig=z%3D', result)
        self.assertNotIn(b'do-not-copy', result)

    def test_encryption_map_range_and_media_timeline_are_not_repacked(self):
        raw = b'#EXTM3U\n#EXT-X-TARGETDURATION:6\n#EXT-X-MEDIA-SEQUENCE:42\n#EXT-X-KEY:METHOD=AES-128,URI="key.bin",IV=0x0001\n#EXT-X-MAP:URI="init.mp4",BYTERANGE="100@0"\n#EXT-X-DISCONTINUITY\n#EXTINF:6,\n#EXT-X-BYTERANGE:100@20\nsegment.ts\n'
        result = current.rewrite_manifest(raw, 'https://hlszymgsplive.miguvideo.com/a/media.m3u8')
        for marker in (b'METHOD=AES-128', b'IV=0x0001', b'#EXT-X-MEDIA-SEQUENCE:42', b'BYTERANGE="100@0"', b'#EXT-X-BYTERANGE:100@20', b'#EXT-X-DISCONTINUITY'):
            self.assertIn(marker, result)
        self.assertIn(b'URI="https://hlszymgsplive.miguvideo.com/a/key.bin"', result)

    def test_unsafe_key_uri_and_html_are_rejected(self):
        raw = b'#EXTM3U\n#EXT-X-TARGETDURATION:6\n#EXT-X-KEY:METHOD=AES-128,URI="http://127.0.0.1/private"\n#EXTINF:6,\nsegment.ts\n'
        for body in (raw, b'<html>error</html>'):
            with self.assertRaises(current.m.UpdateError):
                current.rewrite_manifest(body, 'http://hlszymgsplive.miguvideo.com/a/media.m3u8')

    def test_single_flight_and_completed_fetch_is_released_after_waiter_timeout(self):
        cache = current.ManifestCache()
        self.addCleanup(cache.close)
        entered, release = threading.Event(), threading.Event()
        def fetch(url):
            entered.set()
            release.wait(2)
            return b'manifest'
        with patch.object(cache, '_fetch', side_effect=fetch):
            with self.assertRaises(current.ServiceError):
                cache.get('http://gslbmgsplive.miguvideo.com/a/index.m3u8', wait=0.001)
            self.assertTrue(entered.wait(1))
            with cache.lock:
                future = next(iter(cache.flights.values()))
            release.set()
            future.result(2)
            # Done callbacks run after setting the Future result; acquiring the lock
            # and checking again below permits either legal callback ordering.
            for _ in range(100):
                with cache.lock:
                    if not cache.flights:
                        break
                time.sleep(0.001)
            self.assertFalse(cache.flights)
            self.assertEqual(cache.get('http://gslbmgsplive.miguvideo.com/a/index.m3u8'), b'manifest')
            self.assertEqual(cache.fetches, 1)

    def test_failure_has_short_cooldown_and_no_secret_in_error(self):
        cache = current.ManifestCache()
        self.addCleanup(cache.close)
        with patch.object(cache, '_fetch', side_effect=current.m.FetchError('HTTP_403')) as fetch:
            for _ in range(2):
                with self.assertRaisesRegex(current.ServiceError, 'HTTP_403'):
                    cache.get('http://gslbmgsplive.miguvideo.com/a/index.m3u8?secret=private')
            self.assertEqual(fetch.call_count, 1)

    def test_pending_capacity_is_bounded_and_recovers_after_timeouts(self):
        cache = current.ManifestCache()
        self.addCleanup(cache.close)
        release = threading.Event()
        def fetch(url):
            release.wait(3)
            return b'manifest'
        with patch.object(cache, '_fetch', side_effect=fetch):
            for i in range(8):
                with self.assertRaises(current.ServiceError):
                    cache.get(f'http://gslbmgsplive.miguvideo.com/{i}/index.m3u8',wait=0.001)
            with self.assertRaisesRegex(current.ServiceError, 'MANIFEST_CAPACITY'):
                cache.get('http://gslbmgsplive.miguvideo.com/overflow/index.m3u8',wait=0.001)
            with cache.lock:
                pending = list(cache.flights.values())
            release.set()
            for future in pending:
                future.result(2)
            for _ in range(100):
                with cache.lock:
                    if not cache.flights:
                        break
                time.sleep(0.001)
            self.assertFalse(cache.flights)

    def test_completed_cache_obeys_the_byte_budget(self):
        cache = current.ManifestCache()
        self.addCleanup(cache.close)
        with patch.object(cache, '_fetch', return_value=b'x'*(512*1024)):
            for i in range(20):
                cache.get(f'http://gslbmgsplive.miguvideo.com/{i}/index.m3u8')
        with cache.lock:
            self.assertLessEqual(cache.bytes,8*1024*1024)
            self.assertLessEqual(len(cache.entries),32)


class HttpTests(unittest.TestCase):
    @contextmanager
    def server(self, require_token=False, mode='redirect', catchup=False):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)
            source = path/'source.txt'
            source.write_bytes(catalogue(catchup=catchup))
            store = s.CatalogueStore(path, input_path=source, min_channels=1)
            store.get(2)
            service = s.Service(store, TOKEN, 'http://127.0.0.1:0', mode, require_token=require_token)
            server = s.BoundedServer(('127.0.0.1', 0), service)
            service.public_base = f'http://127.0.0.1:{server.server_address[1]}'
            thread = threading.Thread(target=server.serve_forever, kwargs={'poll_interval':0.01}, daemon=True)
            thread.start()
            try:
                yield server, service
            finally:
                server.shutdown()
                server.server_close()
                service.close()
                thread.join(2)

    def request(self, server, path, method='GET', headers=None):
        client = http.client.HTTPConnection('127.0.0.1', server.server_address[1], timeout=3)
        try:
            client.request(method, path, headers=headers or {})
            response = client.getresponse()
            return response.status, dict(response.getheaders()), response.read()
        finally:
            client.close()

    def test_exact_user_subscription_url_works_without_token_locally(self):
        with self.server() as (server, service):
            code, headers, body = self.request(server, '/all.m3u')
            self.assertEqual(code, 200)
            self.assertNotIn(b'token=', body)
            self.assertNotIn(b'source-private', body)
            self.assertIn((service.public_base+'/live/p100.m3u8').encode(), body)
            code, headers, _ = self.request(server, '/live/p100.m3u8')
            self.assertEqual(code, 302)
            self.assertIn('ProgramID=100', headers['Location'])
            self.assertEqual(headers['Cache-Control'], 'no-store')

    def test_local_dns_rebinding_cross_origin_and_forwarded_header_poisoning(self):
        with self.server() as (server, service):
            self.assertEqual(self.request(server, '/all.m3u', headers={'Host':'evil.example'})[0], 403)
            self.assertEqual(self.request(server, '/all.m3u', headers={'Origin':'https://evil.example'})[0], 403)
            self.assertEqual(self.request(server, '/all.m3u', headers={'Sec-Fetch-Site':'cross-site'})[0], 403)
            code, _, body = self.request(server, '/all.m3u', headers={'X-Forwarded-Host':'evil.example','X-Forwarded-Proto':'https'})
            self.assertEqual(code, 200)
            self.assertNotIn(b'evil.example', body)

    def test_authenticated_mode_supports_query_and_bearer_without_logging_tokens(self):
        with self.server(require_token=True) as (server, service):
            self.assertEqual(self.request(server, '/all.m3u')[0], 401)
            for path, headers in (('/all.m3u?token='+TOKEN, {}), ('/all.m3u', {'Authorization':'Bearer '+TOKEN})):
                code, _, body = self.request(server, path, headers=headers)
                self.assertEqual(code, 200)
                self.assertIn(('?token='+TOKEN).encode(), body)
            self.assertEqual(self.request(server, '/all.m3u?token='+TOKEN, headers={'Authorization':'Bearer '+('x'*43)})[0],401)

    def test_arbitrary_proxy_parameters_and_duplicate_tokens_are_rejected(self):
        with self.server() as (server, service):
            before = service.store.refreshes
            for path in ('/proxy?url=http://127.0.0.1/', '/all.m3u?url=http://evil.example', '/all.m3u?token=a&token=b', '/live/../../etc/passwd'):
                self.assertIn(self.request(server, path)[0], (400,404))
            self.assertEqual(service.store.refreshes, before)

    def test_health_does_not_claim_playback_verified_and_head_has_no_body(self):
        with self.server() as (server, service):
            code, _, body = self.request(server, '/health')
            self.assertEqual(code, 200)
            status = json.loads(body)
            self.assertTrue(status['catalogue_ready'])
            self.assertFalse(status['playback_verified'])
            self.assertNotIn('source-private', body.decode())
            code, headers, body = self.request(server, '/all.m3u', method='HEAD')
            self.assertEqual(code, 200)
            self.assertEqual(body, b'')
            self.assertGreater(int(headers['Content-Length']), 0)

    def test_catchup_template_matches_bare_local_route_and_validates_time(self):
        with self.server(catchup=True) as (server, service):
            _, _, body = self.request(server, '/all.m3u')
            self.assertIn(b'catchup-source="?playbackbegin=', body)
            begin = (m.utcnow()-timedelta(hours=1)).astimezone(m.CHINA).strftime('%Y%m%d%H%M%S')
            end = m.utcnow().astimezone(m.CHINA).strftime('%Y%m%d%H%M%S')
            code, headers, _ = self.request(server, '/live/p100.m3u8?playbackbegin='+begin+'&playbackend='+end)
            self.assertEqual(code, 302)
            self.assertIn('&playbackbegin='+begin, headers['Location'])
            self.assertEqual(self.request(server, '/live/p100.m3u8?playbackbegin=bad')[0],400)

    def test_manifest_mode_returns_real_rewritten_hls_not_a_redirect(self):
        with self.server(mode='manifest') as (server, service):
            with patch.object(service.manifests, 'get', return_value=b'#EXTM3U\n#EXT-X-TARGETDURATION:6\n#EXTINF:6,\nhttp://cdn.example/seg.ts\n'):
                code, headers, body = self.request(server, '/live/p100.m3u8')
            self.assertEqual(code, 200)
            self.assertIn('mpegurl', headers['Content-Type'])
            self.assertTrue(body.startswith(b'#EXTM3U'))

    def test_non_loopback_server_cannot_disable_token_authentication(self):
        service = Mock(require_token=False)
        with self.assertRaisesRegex(s.ServiceError,'NON_LOOPBACK_REQUIRES_TOKEN'):
            s.BoundedServer(('0.0.0.0',0), service)


class TokenTests(unittest.TestCase):
    def test_generated_token_is_private_and_stable_between_restarts(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)
            first = current.load_access_token(path)
            self.assertEqual(first, current.load_access_token(path))
            if os.name != 'nt':
                self.assertEqual((path/'access.token').stat().st_mode & 0o777, 0o600)

    def test_explicit_environment_token_is_never_written_to_disk(self):
        with tempfile.TemporaryDirectory() as directory, patch.dict(os.environ, {'MIGU_TEST_ACCESS_TOKEN':TOKEN}):
            self.assertEqual(current.load_access_token(Path(directory), 'MIGU_TEST_ACCESS_TOKEN'), TOKEN)
            self.assertEqual(list(Path(directory).iterdir()), [])


if __name__ == '__main__':
    unittest.main()
