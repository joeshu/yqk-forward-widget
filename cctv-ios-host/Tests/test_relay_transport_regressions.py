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
from urllib.parse import urlsplit
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
                if self.path.startswith('/stale.m3u8'):
                    self.send_response(401);self.send_header('Content-Length','0');self.end_headers();return
                if self.path.startswith('/fresh.m3u8'):
                    manifest=b'#EXTM3U\n#EXT-X-ENDLIST\n';self.send_response(200);self.send_header('Content-Type','application/vnd.apple.mpegurl');self.send_header('Content-Length',str(len(manifest)));self.end_headers()
                    if not head:self.wfile.write(manifest)
                    return
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
                owner.relay.serve(self, urlsplit(self.path).path.rsplit('/', 1)[1], head=True)

            def do_GET(self):
                owner.relay.serve(self, urlsplit(self.path).path.rsplit('/', 1)[1])

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

    def test_ll_hls_delivery_directives_survive_forced_manifest_refresh(self):
        base=f'http://127.0.0.1:{self.upstream.server_port}'
        token=self.relay.register(base+'/stale.m3u8',{},refresh=lambda:{'url':base+'/fresh.m3u8?sig=a%2Bb'},expected_hls=True)
        client=http.client.HTTPConnection('127.0.0.1',self.server.server_port,timeout=3)
        try:
            client.request('GET',f'/media/{token}?_HLS_msn=12&_HLS_part=3&_HLS_skip=v2')
            response=client.getresponse();body=response.read()
            self.assertEqual((response.status,body),(200,b'#EXTM3U\n#EXT-X-ENDLIST\n'))
        finally:client.close()
        refreshed=[path for _,path,_ in self.seen if urlsplit(path).path=='/fresh.m3u8']
        self.assertEqual(len(refreshed),1)
        self.assertEqual(refreshed[0],'/fresh.m3u8?sig=a%2Bb&_HLS_msn=12&_HLS_part=3&_HLS_skip=v2')

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



    def test_http11_keep_alive_pool_reuses_upstream_socket_across_segments(self):
        client_ports = []
        body_payload = (b'\x47' + b'a' * 187) * 8

        class KeepAliveUpstream(http.server.BaseHTTPRequestHandler):
            protocol_version = 'HTTP/1.1'

            def log_message(self, *_):
                pass

            def do_GET(self):
                client_ports.append(self.client_address[1])
                self.send_response(200)
                self.send_header('Content-Type', 'video/mp2t')
                self.send_header('Content-Length', str(len(body_payload)))
                self.send_header('Connection', 'keep-alive')
                self.end_headers()
                self.wfile.write(body_payload)

        relay_module._UPSTREAM_POOL.clear()
        ka_upstream = http.server.ThreadingHTTPServer(('127.0.0.1', 0), KeepAliveUpstream)
        ka_thread = threading.Thread(target=ka_upstream.serve_forever, kwargs={'poll_interval': .01}, daemon=True)
        ka_thread.start()
        try:
            for idx in range(3):
                tok = self.relay.register(
                    f'http://127.0.0.1:{ka_upstream.server_port}/seg-{idx}.ts', {}, segment=True)
                status, _, data = self.fetch(tok)
                self.assertEqual((status, data), (200, body_payload))
            self.assertEqual(len(client_ports), 3)
            self.assertEqual(len(set(client_ports)), 1, 'HTTP/1.1 upstream socket must be reused across sequential segments')
        finally:
            relay_module._UPSTREAM_POOL.clear()
            ka_upstream.shutdown()
            ka_upstream.server_close()
            ka_thread.join(2)

    def test_speculative_warmup_prefetches_key_map_and_first_segment_stream(self):
        requests = []
        key_bytes = b'0123456789abcdef'
        map_bytes = b'\x00\x00\x00\x18ftypmp42' + b'm' * 64
        seg_bytes = b'\x00\x00\x00\x18moofbox!' + b's' * 8192

        class WarmupUpstream(http.server.BaseHTTPRequestHandler):
            def log_message(self, *_):
                pass

            def do_GET(self):
                requests.append(self.path)
                if self.path == '/playlist.m3u8':
                    playlist = (
                        '#EXTM3U\n#EXT-X-VERSION:7\n'
                        '#EXT-X-KEY:METHOD=AES-128,URI="enc.key"\n'
                        '#EXT-X-MAP:URI="init.mp4"\n'
                        '#EXTINF:4.0,\nseg1.m4s\n'
                    ).encode('utf-8')
                    self.send_response(200)
                    self.send_header('Content-Type', 'application/vnd.apple.mpegurl')
                    self.send_header('Content-Length', str(len(playlist)))
                    self.end_headers()
                    self.wfile.write(playlist)
                elif self.path == '/enc.key':
                    self.send_response(200)
                    self.send_header('Content-Type', 'application/octet-stream')
                    self.send_header('Content-Length', str(len(key_bytes)))
                    self.end_headers()
                    self.wfile.write(key_bytes)
                elif self.path == '/init.mp4':
                    self.send_response(200)
                    self.send_header('Content-Type', 'video/mp4')
                    self.send_header('Content-Length', str(len(map_bytes)))
                    self.end_headers()
                    self.wfile.write(map_bytes)
                elif self.path == '/seg1.m4s':
                    self.send_response(200)
                    self.send_header('Content-Type', 'video/mp4')
                    self.send_header('Content-Length', str(len(seg_bytes)))
                    self.end_headers()
                    self.wfile.write(seg_bytes)

        w_upstream = http.server.ThreadingHTTPServer(('127.0.0.1', 0), WarmupUpstream)
        w_thread = threading.Thread(target=w_upstream.serve_forever, kwargs={'poll_interval': .01}, daemon=True)
        w_thread.start()
        self.relay.speculative_warmup = True
        try:
            m_tok = self.relay.register(
                f'http://127.0.0.1:{w_upstream.server_port}/playlist.m3u8', {}, expected_hls=True)
            status, _, m_body = self.fetch(m_tok)
            self.assertEqual(status, 200)
            import re as _re, time as _time
            tokens = _re.findall(r'/media/([0-9a-f]{32})', m_body.decode('utf-8'))
            self.assertEqual(len(tokens), 3)
            deadline = _time.monotonic() + 2.0
            while _time.monotonic() < deadline and (
                not self.relay.remote_key_cache or not self.relay.remote_map_cache or not self.relay.prefetched_segment_streams
            ):
                _time.sleep(0.02)
            self.assertTrue(self.relay.remote_key_cache)
            self.assertTrue(self.relay.remote_map_cache)
            self.assertTrue(self.relay.prefetched_segment_streams)
            before_count = len(requests)
            self.assertEqual(self.fetch(tokens[0])[2], key_bytes)
            self.assertEqual(self.fetch(tokens[1])[2], map_bytes)
            self.assertEqual(self.fetch(tokens[2])[2], seg_bytes)
            self.assertEqual(len(requests), before_count, 'warmed key, map, and first segment must not re-request upstream')
        finally:
            self.relay.speculative_warmup = None
            w_upstream.shutdown()
            w_upstream.server_close()
            w_thread.join(2)

    def test_extensionless_flv_and_mkv_magic_sets_content_type(self):
        self.assertEqual(relay_module.MediaRelay.sniff_container_magic(b'FLV\x01\x05\x00\x00\x00\x09'), 'video/x-flv')
        self.assertEqual(relay_module.MediaRelay.sniff_container_magic(b'\x1a\x45\xdf\xa3\x93\x42\x82\x88'), 'video/x-matroska')
        self.assertEqual(relay_module.MediaRelay.sniff_container_magic(b'\x00\x00\x00\x18ftypisom'), 'video/mp4')


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
