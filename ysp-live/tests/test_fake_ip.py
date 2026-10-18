"""Fake-IP compatibility: exercise target checks and real HTTP playlist/media reads."""
import importlib.util
from pathlib import Path
import socket
import sys
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('ysp_fake_ip_tests', ROOT / 'ysp-live-v9.5.13.py')
live = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = live
spec.loader.exec_module(live)


class FakeIPTests(unittest.TestCase):
    def resolve(self, addresses, enabled=False, target='http://media.cctv.cn/live.m3u8'):
        with mock.patch.object(live, 'bounded_dns_addresses', return_value=addresses):
            return live.URLPolicy(allow_fake_ip=enabled).resolve(target)[1]

    def test_default_rejects_fake_ip_with_actionable_message(self):
        with self.assertRaisesRegex(live.ProxyError, '--allow-fake-ip'):
            self.resolve(['198.18.0.1'])

    def test_opt_in_accepts_both_ends_of_fake_ip_range(self):
        addresses = ['198.18.0.1', '198.19.255.254']
        self.assertEqual(self.resolve(addresses, True), addresses)

    def test_opt_in_retains_public_ipv4_and_ipv6(self):
        addresses = ['8.8.8.8', '2606:4700:4700::1111']
        self.assertEqual(self.resolve(addresses, True), addresses)

    def test_opt_in_never_allows_other_nonpublic_addresses_or_mixed_answers(self):
        for address in ['127.0.0.1', '192.168.1.1', '10.0.0.1', '169.254.169.254',
                        '100.64.0.1', '192.0.2.1', '::1', 'fc00::1']:
            with self.subTest(address=address):
                with self.assertRaises(live.ProxyError):
                    self.resolve(['198.18.0.1', address], True)

    def test_opt_in_does_not_bypass_hostname_or_port_checks(self):
        for target in ['http://untrusted.example/stream.ts', 'http://198.18.0.1/a.ts',
                       'http://media.cctv.cn:8080/a.ts',
                       'http://127.0.0.1:8787/segment?url=http%3A%2F%2F192.168.1.1%2Fa.ts']:
            with self.subTest(target=target), self.assertRaises(live.ProxyError):
                self.resolve(['198.18.0.1'], True, target)

    def test_global_configuration_reaches_new_policies_with_explicit_override(self):
        with mock.patch.object(live, '_ALLOW_FAKE_IP_MEDIA', True):
            self.assertTrue(live.URLPolicy().allow_fake_ip)
            proxy = live.SharedMediaProxy(max_cache_bytes=0)
            try:
                self.assertTrue(proxy.policy.allow_fake_ip)
            finally:
                proxy.close()
            self.assertFalse(live.URLPolicy(allow_fake_ip=False).allow_fake_ip)

    def test_fake_ip_playlist_and_media_download_and_redirect_revalidation(self):
        payload = b'\x47' + b'\x00' * 187
        class Origin(BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass
            def do_GET(self):
                if self.path == '/redirect.m3u8':
                    self.send_response(302)
                    self.send_header('Location', 'http://untrusted.example/live.m3u8')
                    self.end_headers()
                    return
                body = payload if self.path == '/seg.ts' else b'#EXTM3U\n#EXT-X-TARGETDURATION:6\n#EXTINF:6,\nseg.ts\n'
                self.send_response(200)
                self.send_header('Content-Length', str(len(body)))
                self.end_headers()
                self.wfile.write(body)
        upstream = ThreadingHTTPServer(('127.0.0.1', 0), Origin)
        worker = threading.Thread(target=upstream.serve_forever, daemon=True)
        worker.start()
        connect = socket.create_connection
        destinations = []
        def route(address, *args, **kwargs):
            destinations.append(address)
            self.assertEqual(address, ('198.18.0.7', 80))
            return connect(('127.0.0.1', upstream.server_port), *args, **kwargs)
        try:
            with mock.patch.object(live, '_ALLOW_FAKE_IP_MEDIA', True), \
                 mock.patch.object(live, 'bounded_dns_addresses', return_value=['198.18.0.7']), \
                 mock.patch.object(live.urllib.request, 'getproxies', return_value={}), \
                 mock.patch.object(live.socket, 'create_connection', side_effect=route):
                _, _, data, _ = live.fetch_bytes('http://media.cctv.cn/live.m3u8')
                text = live.rewrite_playlist_urls(data.decode(), 'http://media.cctv.cn/live.m3u8')
                uri = live.parse_media(text).segments[0].uri
                self.assertEqual(uri, 'http://media.cctv.cn/seg.ts')
                status, _, body, _ = live.fetch_bytes(uri)
                self.assertEqual((status, body), (200, payload))
                with self.assertRaises(live.ProxyError):
                    live.fetch_bytes('http://media.cctv.cn/redirect.m3u8')
                self.assertEqual(len(destinations), 3)
        finally:
            upstream.shutdown()
            upstream.server_close()
            worker.join(2)


if __name__ == '__main__':
    unittest.main()
