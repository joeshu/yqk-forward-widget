import base64
import contextlib
import http.client
import importlib.util
import io
from pathlib import Path
import socket
import sys
import threading
import time
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('gateway', ROOT / 'ysp-live-v9.5.py')
g = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = g
spec.loader.exec_module(g)
URL = 'https://cdn.cctv.cn/live/segment.ts?key=example'

class SecurityTests(unittest.TestCase):
    def test_signed_token_roundtrip_tamper_expiry_and_legacy(self):
        with patch.object(g.time, 'time', return_value=1000):
            token = g.encode_proxy_ts_url(URL)
            self.assertEqual(g.decode_proxy_ts_url(token), URL)
            with self.assertRaises(g.YsptpError):
                g.decode_proxy_ts_url(token[:-1] + ('0' if token[-1] != '0' else '1'))
        with patch.object(g.time, 'time', return_value=2000):
            with self.assertRaises(g.YsptpError):
                g.decode_proxy_ts_url(token)
        legacy = base64.urlsafe_b64encode(URL.encode()).decode()
        with self.assertRaises(g.YsptpError):
            g.decode_proxy_ts_url(legacy)

    def test_reject_unsafe_targets(self):
        for target in ['http://127.0.0.1/a.ts', 'http://169.254.169.254/a.ts',
                       'file:///etc/passwd', 'http://cdn.cctv.cn:8080/a.ts',
                       'https://cdn.cctv.cn.evil.example/a.ts',
                       'https://user:password@cdn.cctv.cn/a.ts', 'http://cdn.cctv.cn:bad/a.ts']:
            with self.subTest(target=target), self.assertRaises(g.YsptpError):
                g.validate_proxy_target(target)

    def test_dns_rejects_private_and_mixed_answers(self):
        for addresses in [['127.0.0.1'], ['10.0.0.1'], ['169.254.169.254'], ['::ffff:127.0.0.1'], ['8.8.8.8', '192.168.1.1']]:
            replies = [(socket.AF_INET6 if ':' in address else socket.AF_INET, socket.SOCK_STREAM, 6, '', (address, 443)) for address in addresses]
            with patch.object(g.socket, 'getaddrinfo', return_value=replies), self.assertRaises(g.YsptpError):
                g._proxy_addresses(g.validate_proxy_target(URL))

    def test_rebinding_uses_pinned_socket_and_tls_hostname(self):
        parsed = g.validate_proxy_target(URL)
        replies = [(socket.AF_INET, socket.SOCK_STREAM, 6, '', ('8.8.8.8', 443))]
        with patch.object(g.socket, 'socket') as sock, patch.object(g.ssl, 'create_default_context') as tls:
            conn = g._PinnedHTTPConnection(parsed, replies)
            conn.connect()
            sock.return_value.connect.assert_called_once_with(('8.8.8.8', 443))
            tls.return_value.wrap_socket.assert_called_once_with(sock.return_value, server_hostname='cdn.cctv.cn')

    def test_redirect_revalidated_before_connect(self):
        class Redirect:
            status = 302
            def getheader(self, name): return 'http://127.0.0.1/private.ts'
        with patch.object(g, 'configured_proxy', return_value=None), patch.object(g, '_proxy_addresses', return_value=[]), patch.object(g, '_PinnedHTTPConnection') as connection:
            connection.return_value.getresponse.return_value = Redirect()
            with self.assertRaises(g.YsptpError):
                with g.open_proxy_upstream(URL): pass
            self.assertEqual(connection.call_count, 1)

    def test_engine_loopback_exception_is_narrow(self):
        target = f'http://127.0.0.1:{g.engine_port}/segment?url=' + g.urllib.parse.quote(URL, safe='')
        self.assertEqual(g.validate_proxy_target(target, True).hostname, '127.0.0.1')
        for bad in [target.replace('/segment?', '/other?'), target.replace('8787', '9999'), target.replace('url=', 'wrong=')]:
            with self.assertRaises(g.YsptpError): g.validate_proxy_target(bad, True)

class CacheTests(unittest.TestCase):
    def test_lru_and_byte_budget(self):
        cache = g.TsSegmentCache(max_mb=1)
        cache.set('a', b'a'*400000, {})
        cache.set('b', b'b'*400000, {})
        cache.get('a')
        cache.set('c', b'c'*400000, {})
        self.assertIsNone(cache.get('b'))
        self.assertIsNotNone(cache.get('a'))
        cache.set('a', b'x'*100, {})
        self.assertEqual(cache.curr_bytes, 400100)
        self.assertLessEqual(cache.curr_bytes, cache.max_bytes)

    def test_expiry_uses_monotonic_and_zero_disables(self):
        cache = g.TsSegmentCache(max_mb=1, max_age_sec=1)
        with patch.object(g.time, 'monotonic', return_value=1): cache.set('a', b'a', {})
        with patch.object(g.time, 'monotonic', return_value=3): self.assertIsNone(cache.get('a'))
        cache = g.TsSegmentCache(max_mb=0)
        cache.set('a', b'a', {})
        self.assertEqual(cache.curr_bytes, 0)
        self.assertIsNone(cache.get('a'))

class RefreshTests(unittest.TestCase):
    def test_cold_timeout_and_background_share_one_refresh(self):
        channel = g.Channel('test-review', 'test', '0', '0', 'fhd')
        entered, release = threading.Event(), threading.Event()
        calls = []
        def slow_refresh(ch):
            calls.append(ch.slug)
            entered.set()
            release.wait(3)
            ch.last_ok = time.time()
            return True
        original = g.coalesce_refresh
        def short_wait(slug, fn, timeout=None):
            return original(slug, fn, .05 if timeout is not None and timeout > 0 else timeout)
        with patch.object(g, 'refresh_once', slow_refresh), patch.object(g, 'coalesce_refresh', short_wait), patch.object(g, 'log'):
            try:
                g.ensure_channel(channel)
                self.assertTrue(entered.wait(1))
                g.trigger_background_refresh(channel)
                # The loop has started but must wait on the initial refresh.
                time.sleep(.1)
                self.assertEqual(len(calls), 1)
            finally:
                channel.last_access = 0
                release.set()

class TransferTests(unittest.TestCase):
    def setUp(self):
        self.server = g.BoundedHTTPServer(('127.0.0.1', 0), g.Handler, max_requests=4)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.cache_patch = patch.object(g, 'global_ts_cache', g.TsSegmentCache(max_mb=1))
        self.cache_patch.start()
    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.cache_patch.stop()
    def request(self, method='GET', headers=None, token=None, path=None):
        connection = http.client.HTTPConnection(*self.server.server_address, timeout=3)
        try:
            connection.request(method, path or '/proxy.ts?=' + (token or g.encode_proxy_ts_url(URL)), headers=headers or {})
            response = connection.getresponse()
            return response.status, dict(response.getheaders()), response.read()
        finally: connection.close()
    def upstream(self, data=b'payload', status=200, passed=None):
        class Response(io.BytesIO):
            def getheader(self, name, default=None):
                return {'Content-Length': str(len(data)), 'Content-Type': 'video/mp2t', **(passed or {})}.get(name, default)
        result = Response(data)
        result.status = status
        return result
    def test_get_cache_hit_head_and_range(self):
        calls = []
        @contextlib.contextmanager
        def upstream(target, headers, method, **kwargs):
            calls.append((headers, method))
            yield self.upstream(status=206 if 'Range' in headers else 200)
        with patch.object(g, 'open_proxy_upstream', upstream):
            self.assertEqual(self.request()[2], b'payload')
            self.assertEqual(self.request()[1]['X-Cache'], 'HIT-RAM')
            self.assertEqual(self.request('HEAD')[2], b'')
            self.assertEqual(self.request(headers={'Range': 'bytes=0-6'})[0], 206)
        self.assertEqual(len(calls), 2)
    def test_engine_proxy_requires_signature_and_preserves_range(self):
        target = f'http://127.0.0.1:{g.engine_port}/segment?url=' + g.urllib.parse.quote(URL, safe='')
        calls = []
        @contextlib.contextmanager
        def upstream(url, headers, method, **kwargs):
            calls.append((url, headers, kwargs))
            yield self.upstream(status=206)
        with patch.object(g, 'open_proxy_upstream', upstream):
            unsigned = '/engine_proxy?url=' + g.urllib.parse.quote(target, safe='')
            self.assertEqual(self.request(path=unsigned)[0], 403)
            signed = '/engine_proxy?token=' + g.encode_proxy_ts_url(target)
            self.assertEqual(self.request(path=signed, headers={'Range': 'bytes=0-6'})[0], 206)
        self.assertEqual(len(calls), 1)
        self.assertTrue(calls[0][2]['allow_engine'])
        self.assertEqual(calls[0][1]['Range'], 'bytes=0-6')

    def test_high_rate_error_is_counted_once_and_returns_retry_hint(self):
        import types
        error = g.YsptpError('live/v1/01 HTTP 400')
        state = types.SimpleNamespace(cache={}, playlist_cache={}, channel_failures={})
        def fail(channel, *args):
            state.channel_failures[channel] = (g.now_f64(), str(error), 1)
            raise error
        resolver = types.SimpleNamespace(state=state, state_lock=threading.Lock(),
            is_channel_in_cooldown=lambda channel: False, fetch_channel_playlist=fail,
            get_channel_failure_info=lambda channel: state.channel_failures.get(channel))
        channel = g.Channel('cctv4k', 'test', '0', '0', 'fhd')
        with patch.object(g, 'resolver', resolver), patch.object(g, 'resolver_ready', return_value=True), patch.object(g, 'active_backend_channels', {'cctv4k'}), patch.object(g, 'get_channel_instance', return_value=channel), patch.object(g, 'ensure_channel'), patch.object(g, 'fetch_upstream_engine_playlist', return_value=None), patch.object(g, 'log'):
            status, headers, _ = self.request(path='/cctv4k.m3u8')
        self.assertEqual(status, 503)
        self.assertEqual(headers['Retry-After'], '2')
        self.assertEqual(state.channel_failures['cctv4k'][2], 1)

    def test_invalid_token_does_not_contact_upstream(self):
        with patch.object(g, 'open_proxy_upstream') as upstream:
            self.assertEqual(self.request(token='invalid')[0], 403)
            upstream.assert_not_called()
    def test_oversize_is_rejected_and_not_cached(self):
        @contextlib.contextmanager
        def upstream(*args, **kwargs):
            yield self.upstream(passed={'Content-Length': str(g.MAX_SEGMENT_BYTES+1)})
        with patch.object(g, 'open_proxy_upstream', upstream), patch.object(g, 'log'):
            self.assertEqual(self.request()[0], 502)
            self.assertEqual(g.global_ts_cache.curr_bytes, 0)
    def test_concurrent_requests_share_one_upstream(self):
        entered, release = threading.Event(), threading.Event()
        calls, results = [], []
        @contextlib.contextmanager
        def upstream(*args, **kwargs):
            calls.append(1); entered.set(); release.wait(2)
            yield self.upstream()
        with patch.object(g, 'open_proxy_upstream', upstream):
            threads = [threading.Thread(target=lambda: results.append(self.request())) for _ in range(2)]
            threads[0].start(); self.assertTrue(entered.wait(1)); threads[1].start()
            time.sleep(.1); release.set()
            for thread in threads: thread.join(3)
        self.assertEqual(len(calls), 1)
        self.assertEqual([result[0] for result in results], [200, 200])
    def test_request_overload_returns_503_without_starting_thread(self):
        for _ in range(4): self.assertTrue(self.server.request_slots.acquire(False))
        try: self.assertEqual(self.request(path='/health')[0], 503)
        finally:
            for _ in range(4): self.server.request_slots.release()

if __name__ == '__main__': unittest.main()
