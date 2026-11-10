"""Real loopback HTTP coverage for concurrent HLS bootstrap requests.

Live playlists are shared only while their exact scoped fetch is in progress.
No result survives to suppress the next live-playlist reload.
"""
from concurrent.futures import ThreadPoolExecutor
import http.client
import http.server
from pathlib import Path
import sys
import threading
import time
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'Plugins'))
import host_media_relay as relay_module


class ManifestCoalescingTests(unittest.TestCase):
    upstream_server_class = http.server.ThreadingHTTPServer
    upstream_delay = 0

    def setUp(self):
        self.release = threading.Event()
        self.condition = threading.Condition()
        self.upstream_calls = []
        self.joined = 0
        self.status = 200
        owner = self

        class Upstream(http.server.BaseHTTPRequestHandler):
            def log_message(self, *_):
                pass

            def do_GET(self):
                self.respond(False)

            def do_HEAD(self):
                self.respond(True)

            def respond(self, head):
                if owner.upstream_delay:
                    time.sleep(owner.upstream_delay)
                with owner.condition:
                    sequence = len(owner.upstream_calls) + 1
                    owner.upstream_calls.append((self.path, dict(self.headers), self.command))
                    status = owner.status
                    owner.condition.notify_all()
                owner.release.wait(3)
                body = (f'#EXTM3U\n#EXT-X-TARGETDURATION:4\n#EXT-X-MEDIA-SEQUENCE:{sequence}\n'
                        f'#EXTINF:4,\nsegment-{sequence}.ts\n').encode()
                content_type = 'application/vnd.apple.mpegurl'
                content_range = None
                if self.path.startswith('/segment.ts'):
                    body = bytes(range(256)) * 4
                    content_type = 'video/mp2t'
                    if self.headers.get('Range'):
                        first, last = self.headers['Range'].removeprefix('bytes=').split('-')
                        start, end = int(first), int(last)
                        content_range = f'bytes {start}-{end}/{len(body)}'
                        body = body[start:end + 1]
                        status = 206
                self.send_response(status)
                self.send_header('Content-Type', content_type)
                self.send_header('Content-Length', str(len(body)))
                if content_range:
                    self.send_header('Content-Range', content_range)
                self.end_headers()
                try:
                    if not head:
                        self.wfile.write(body)
                except (BrokenPipeError, ConnectionResetError):
                    pass

        self.relay = relay_module.MediaRelay(stream_media=True)
        original_join = self.relay._join_manifest_fetch

        def joined(identity):
            result = original_join(identity)
            with self.condition:
                self.joined += 1
                self.condition.notify_all()
            return result

        self.join_patch = mock.patch.object(self.relay, '_join_manifest_fetch', side_effect=joined)
        self.join_patch.start()

        class Handler(http.server.BaseHTTPRequestHandler):
            def log_message(self, *_):
                pass

            def do_GET(self):
                owner.relay.serve(self, self.path.rsplit('/', 1)[-1])

            def do_HEAD(self):
                owner.relay.serve(self, self.path.rsplit('/', 1)[-1], head=True)

        self.upstream = self.upstream_server_class(('127.0.0.1', 0), Upstream)
        self.server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        self.threads = [threading.Thread(target=server.serve_forever,
                                        kwargs={'poll_interval': .01}, daemon=True)
                        for server in (self.upstream, self.server)]
        for thread in self.threads:
            thread.start()
        self.log_patch = mock.patch.object(relay_module, 'print', create=True)
        self.log_patch.start()
        self.executor = ThreadPoolExecutor(max_workers=8)

    def tearDown(self):
        self.release.set()
        self.relay.close()
        self.executor.shutdown(wait=True)
        for server in (self.upstream, self.server):
            server.shutdown()
            server.server_close()
        for thread in self.threads:
            thread.join(2)
        self.join_patch.stop()
        self.log_patch.stop()

    def token(self, scope='play-1'):
        return self.relay.register(
            f'http://127.0.0.1:{self.upstream.server_port}/live.m3u8?sig=fixture',
            {'Referer': 'https://source.example/', 'Cookie': 'fixture=1'},
            expected_hls=True, resource_scope=scope)

    def fetch(self, token, method='GET', headers=None):
        client = http.client.HTTPConnection('127.0.0.1', self.server.server_port, timeout=4)
        try:
            client.request(method, '/media/' + token, headers=headers or {})
            response = client.getresponse()
            return response.status, dict(response.getheaders()), response.read()
        finally:
            client.close()

    def wait_for(self, predicate):
        with self.condition:
            self.assertTrue(self.condition.wait_for(predicate, timeout=2),
                            f'upstream calls={len(self.upstream_calls)}, joins={self.joined}')

    def test_four_parallel_bootstrap_gets_share_one_fetch_and_rewrite_without_live_cache(self):
        token = self.token()
        with mock.patch.object(self.relay, 'rewrite', wraps=self.relay.rewrite) as rewrite:
            futures = [self.executor.submit(self.fetch, token) for _ in range(4)]
            self.wait_for(lambda: self.joined == 4 and len(self.upstream_calls) == 1)
            self.release.set()
            responses = [future.result(timeout=3) for future in futures]
            self.assertTrue(all(status == 200 for status, _, _ in responses))
            self.assertEqual(len({body for _, _, body in responses}), 1)
            self.assertEqual(rewrite.call_count, 1)
            self.assertEqual(len(self.upstream_calls), 1)
            self.assertEqual(self.upstream_calls[0][1]['Cookie'], 'fixture=1')
            self.assertFalse(self.relay.manifest_flights)
            # A later reload must see the advancing live media sequence.
            _, headers, next_body = self.fetch(token)
            self.assertIn(b'#EXT-X-MEDIA-SEQUENCE:2', next_body)
            self.assertNotEqual(next_body, responses[0][2])
            self.assertEqual(headers['Cache-Control'], 'no-store')
            self.assertEqual((len(self.upstream_calls), rewrite.call_count), (2, 2))

    def test_same_address_and_headers_in_distinct_playback_scopes_are_not_shared(self):
        tokens = [self.token(scope) for scope in ('play-a', 'play-b')]
        futures = [self.executor.submit(self.fetch, token) for token in tokens for _ in range(2)]
        self.wait_for(lambda: self.joined == 4 and len(self.upstream_calls) == 2)
        self.release.set()
        responses = [future.result(timeout=3) for future in futures]
        self.assertTrue(all(status == 200 for status, _, _ in responses))
        self.assertEqual(responses[0][2], responses[1][2])
        self.assertEqual(responses[2][2], responses[3][2])
        self.assertNotEqual(responses[0][2], responses[2][2])
        self.assertEqual(len(self.upstream_calls), 2)

    def test_shared_failure_preserves_upstream_status_and_allows_a_fresh_retry(self):
        self.status = 404
        token = self.token()
        futures = [self.executor.submit(self.fetch, token) for _ in range(3)]
        self.wait_for(lambda: self.joined == 3 and len(self.upstream_calls) == 1)
        self.release.set()
        responses = [future.result(timeout=3) for future in futures]
        self.assertTrue(all(status == 404 for status, _, _ in responses))
        self.assertTrue(all(headers['X-CCTVHost-Relay-Stage'] == 'upstream_http_error'
                            for _, headers, _ in responses))
        self.assertFalse(self.relay.manifest_flights)
        self.status = 200
        status, _, body = self.fetch(token)
        self.assertEqual(status, 200)
        self.assertIn(b'#EXT-X-MEDIA-SEQUENCE:2', body)

    def test_head_probe_does_not_join_a_get_and_media_ranges_keep_their_bytes(self):
        token = self.token()
        get = self.executor.submit(self.fetch, token)
        self.wait_for(lambda: self.joined == 1 and len(self.upstream_calls) == 1)
        head = self.executor.submit(self.fetch, token, 'HEAD')
        self.wait_for(lambda: len(self.upstream_calls) == 2)
        self.release.set()
        self.assertEqual(get.result(timeout=3)[0], 200)
        self.assertEqual(head.result(timeout=3)[2], b'')
        self.assertEqual({call[2] for call in self.upstream_calls}, {'HEAD', 'GET'})
        token = self.relay.register(
            f'http://127.0.0.1:{self.upstream.server_port}/segment.ts', {}, segment=True)
        futures = [self.executor.submit(self.fetch, token, headers={'Range': value})
                   for value in ('bytes=0-31', 'bytes=64-127')]
        responses = [future.result(timeout=3) for future in futures]
        self.assertEqual(responses[0][::2], (206, bytes(range(32))))
        self.assertEqual(responses[1][::2], (206, bytes(range(64, 128))))
        self.assertEqual(responses[0][1]['Content-Range'], 'bytes 0-31/1024')
        self.assertEqual(responses[1][1]['Content-Range'], 'bytes 64-127/1024')
        self.assertEqual(self.joined, 1)
        self.assertEqual(len(self.upstream_calls), 4)

    def test_close_unblocks_waiters_before_the_upstream_returns(self):
        token = self.token()
        owner = self.executor.submit(self.fetch, token)
        self.wait_for(lambda: self.joined == 1 and len(self.upstream_calls) == 1)
        waiter = self.executor.submit(self.fetch, token)
        self.wait_for(lambda: self.joined == 2)
        self.relay.close()
        status, headers, _ = waiter.result(timeout=1)
        self.assertEqual(status, 503)
        self.assertEqual(headers['X-CCTVHost-Relay-Stage'], 'media_service_stopping')
        self.assertFalse(self.relay.manifest_flights)
        self.release.set()
        # The cancelled owner may return no response because service shutdown
        # closes its resource; consume that local disconnect explicitly.
        try:
            owner.result(timeout=3)
        except http.client.RemoteDisconnected:
            pass

    def test_concurrent_distinct_manifest_registry_is_bounded(self):
        self.join_patch.stop()
        for index in range(4):
            flight, is_owner = self.relay._join_manifest_fetch(('token', index))
            self.assertIsNotNone(flight)
            self.assertTrue(is_owner)
        bypass, is_owner = self.relay._join_manifest_fetch(('another-token', 4))
        self.assertIsNone(bypass)
        self.assertTrue(is_owner)
        self.assertEqual(len(self.relay.manifest_flights), 4)


class FragmentBootstrapStreamingTests(unittest.TestCase):
    def test_split_fmp4_header_reaches_player_before_remaining_fragment_arrives(self):
        relay = relay_module.MediaRelay(stream_media=True)
        first_probe = threading.Event()
        release_tail = threading.Event()
        initial = b'\x00\x00\x00\x18ftypisom'
        tail = b'x' * 20000
        original_strip = relay._strip_disguised_ts_prefix

        def observed_probe(data):
            if len(data) == 4:
                first_probe.set()
            return original_strip(data)

        class Upstream(http.server.BaseHTTPRequestHandler):
            def log_message(self, *_):
                pass

            def do_GET(self):
                self.send_response(200)
                self.send_header('Content-Type', 'video/mp4')
                self.send_header('Content-Length', str(len(initial) + len(tail)))
                self.end_headers()
                self.wfile.write(initial[:4])
                self.wfile.flush()
                first_probe.wait(2)
                self.wfile.write(initial[4:])
                self.wfile.flush()
                release_tail.wait(3)
                self.wfile.write(tail)

        class Handler(http.server.BaseHTTPRequestHandler):
            def log_message(self, *_):
                pass

            def do_GET(self):
                relay.serve(self, self.path.rsplit('/', 1)[-1])

        upstream = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Upstream)
        server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        threads = [threading.Thread(target=s.serve_forever, kwargs={'poll_interval': .01}, daemon=True)
                   for s in (upstream, server)]
        for thread in threads:
            thread.start()
        token = relay.register(f'http://127.0.0.1:{upstream.server_port}/fragment.m4s', {}, segment=True)
        client = http.client.HTTPConnection('127.0.0.1', server.server_port, timeout=4)

        def first_bytes():
            client.request('GET', '/media/' + token)
            response = client.getresponse()
            return response, response.read(len(initial))

        with ThreadPoolExecutor(max_workers=1) as executor, \
             mock.patch.object(relay, '_strip_disguised_ts_prefix', side_effect=observed_probe), \
             mock.patch.object(relay_module, 'print', create=True):
            try:
                pending = executor.submit(first_bytes)
                response, prefix = pending.result(timeout=1)
                self.assertEqual(response.status, 200)
                self.assertEqual(prefix, initial)
                self.assertFalse(release_tail.is_set(), 'bootstrap must not wait for the media tail')
                release_tail.set()
                self.assertEqual(prefix + response.read(), initial + tail)
            finally:
                release_tail.set()
                client.close()
                relay.close()
                for s in (server, upstream):
                    s.shutdown()
                    s.server_close()
                for thread in threads:
                    thread.join(2)


if __name__ == '__main__':
    unittest.main()
