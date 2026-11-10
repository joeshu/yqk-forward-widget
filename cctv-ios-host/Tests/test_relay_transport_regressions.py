"""Offline HTTP regression coverage for media byte ranges and HEAD redirects."""
import http.client
import http.server
from pathlib import Path
import ssl
import struct
import sys
import threading
import unittest
from unittest import mock
import urllib.error
import urllib.request
import zlib

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'Plugins'))
import host_media_relay as relay_module


class RelayTransportTests(unittest.TestCase):
    def setUp(self):
        self.seen = []
        # Plausible image disguise followed by three or more aligned TS packets.
        self.payload = b'\x89PNG\r\n\x1a\n' + b'prefix' * 7 + (b'\x47' + b'x' * 187) * 32
        owner = self

        class Upstream(http.server.BaseHTTPRequestHandler):
            def log_message(self, *_):
                pass

            def do_HEAD(self):
                self.respond(True)

            def do_GET(self):
                self.respond(False)

            def respond(self, head):
                owner.seen.append((self.command, self.path, dict(self.headers)))
                if self.path.startswith('/redirect/'):
                    self.send_response(int(self.path.rsplit('/', 1)[1]))
                    # Host change also exercises credential scoping on redirect.
                    self.send_header('Location', f'http://localhost:{self.server.server_port}/media.ts')
                    self.send_header('Content-Length', '0')
                    self.end_headers()
                    return
                selected = owner.payload
                status = 200
                if self.headers.get('Range'):
                    first, last = self.headers['Range'].removeprefix('bytes=').split('-', 1)
                    start, end = int(first), int(last)
                    selected = owner.payload[start:end + 1]
                    status = 206
                self.send_response(status)
                self.send_header('Content-Type', 'application/octet-stream')
                self.send_header('Content-Length', str(len(selected)))
                self.send_header('Accept-Ranges', 'bytes')
                if status == 206:
                    self.send_header('Content-Range', f'bytes {start}-{end}/{len(owner.payload)}')
                self.end_headers()
                if not head:
                    self.wfile.write(selected)

        self.relay = relay_module.MediaRelay(stream_media=True)

        class RelayHandler(http.server.BaseHTTPRequestHandler):
            def log_message(self, *_):
                pass

            def do_HEAD(self):
                owner.relay.serve(self, self.path.rsplit('/', 1)[1], head=True)

            def do_GET(self):
                owner.relay.serve(self, self.path.rsplit('/', 1)[1])

        self.upstream = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Upstream)
        self.server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), RelayHandler)
        self.threads = [threading.Thread(target=server.serve_forever, kwargs={'poll_interval': .01}, daemon=True)
                        for server in (self.upstream, self.server)]
        for thread in self.threads:
            thread.start()
        self.log = mock.patch.object(relay_module, 'print', create=True)
        self.log.start()

    def tearDown(self):
        self.relay.close()
        for server in (self.upstream, self.server):
            server.shutdown()
            server.server_close()
        for thread in self.threads:
            thread.join(2)
        self.log.stop()

    def fetch(self, token, method='GET', headers=None):
        client = http.client.HTTPConnection('127.0.0.1', self.server.server_port, timeout=3)
        try:
            client.request(method, '/media/' + token, headers=headers or {})
            response = client.getresponse()
            return response.status, dict(response.getheaders()), response.read()
        finally:
            client.close()

    def test_head_retains_method_across_all_redirects_and_drops_cross_origin_credentials(self):
        for status in (301, 302, 303, 307, 308):
            with self.subTest(status=status):
                self.seen.clear()
                token = self.relay.register(f'http://127.0.0.1:{self.upstream.server_port}/redirect/{status}',
                                            {'Cookie': 'private', 'Authorization': 'Bearer private'})
                actual_status, headers, body = self.fetch(token, 'HEAD')
                self.assertEqual((actual_status, body), (200, b''))
                self.assertEqual(headers['Content-Length'], str(len(self.payload)))
                self.assertEqual([call[0] for call in self.seen], ['HEAD', 'HEAD'])
                self.assertNotIn('Cookie', self.seen[-1][2])
                self.assertNotIn('Authorization', self.seen[-1][2])

    def test_partial_media_keeps_original_bytes_and_offsets(self):
        token = self.relay.register(f'http://127.0.0.1:{self.upstream.server_port}/media.ts', {}, segment=True)
        for start, end in ((0, len(self.payload) - 1), (3, len(self.payload) - 2)):
            with self.subTest(start=start):
                status, headers, body = self.fetch(token, headers={'Range': f'bytes={start}-{end}'})
                self.assertEqual(status, 206)
                self.assertEqual(body, self.payload[start:end + 1])
                self.assertEqual(headers['Content-Range'], f'bytes {start}-{end}/{len(self.payload)}')
                self.assertEqual(int(headers['Content-Length']), len(body))
        # Full requests retain the existing disguise-removal compatibility.
        status, headers, body = self.fetch(token)
        self.assertEqual((status, body), (200, (b'\x47' + b'x' * 187) * 32))
        self.assertEqual(int(headers['Content-Length']), len(body))
        self.assertEqual(headers['Content-Type'], 'video/mp2t')


class RelayTLSVerificationTests(unittest.TestCase):
    def test_tls_failures_never_retry_with_verification_disabled_or_cache_the_host(self):
        for cause in (ssl.SSLCertVerificationError(1, 'certificate verify failed'),
                      ssl.SSLError(8, 'UNEXPECTED_EOF_WHILE_READING')):
            with self.subTest(error=type(cause).__name__):
                opener = mock.Mock()
                opener.open.side_effect = urllib.error.URLError(cause)
                with mock.patch.object(urllib.request, 'build_opener', return_value=opener) as build, \
                     mock.patch.object(relay_module.time, 'sleep') as sleep:
                    for _ in range(2):
                        with self.assertRaises(urllib.error.URLError):
                            relay_module._open_with_timeout_retry(
                                urllib.request.Request('https://invalid-cert.example/video.mp4'))
                    self.assertEqual(opener.open.call_count, 2)
                    self.assertEqual(build.call_count, 2)
                    for call in build.call_args_list:
                        contexts = [handler._context for handler in call.args
                                    if isinstance(handler, urllib.request.HTTPSHandler)]
                        self.assertEqual(len(contexts), 1)
                        self.assertEqual(contexts[0].verify_mode, ssl.CERT_REQUIRED)
                        self.assertTrue(contexts[0].check_hostname)
                    sleep.assert_not_called()


class RelayMemoryBoundsTests(unittest.TestCase):
    def test_compressed_png_payload_has_a_decoded_size_limit(self):
        payload = zlib.compress(b'x' * (16 * 1024 * 1024 + 1))
        chunk = b'\x01' + payload
        png = (b'\x89PNG\r\n\x1a\n' + struct.pack('>I', len(chunk)) + b'roUd' + chunk + b'\x00' * 4
               + b'\x00' * 4 + b'IEND' + b'\x00' * 4)
        self.assertIsNone(relay_module.MediaRelay._unwrap_rou_png_bytes(png))

    def test_close_releases_inline_manifests_and_keys(self):
        relay = relay_module.MediaRelay()
        relay.register_inline_key(b'x' * 16)
        relay.register_inline_manifest('#EXTM3U\nsegment.ts', 'https://fixture.test/index.m3u8')
        relay.close()
        self.assertFalse(relay.inline_keys)
        self.assertFalse(relay.inline_manifests)


if __name__ == '__main__':
    unittest.main()
