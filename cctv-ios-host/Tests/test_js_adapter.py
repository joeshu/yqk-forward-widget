import http.client
import importlib.util
import json
from pathlib import Path
import threading
import time
import unittest
from unittest import mock

PATH = Path(__file__).resolve().parents[1] / 'Plugins/yangshipin-js.py'
SPEC = importlib.util.spec_from_file_location('yangshipin_js_adapter', PATH)
adapter_module = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(adapter_module)
MANIFEST = '#EXTM3U\n#EXT-X-TARGETDURATION:6\n#EXT-X-MEDIA-SEQUENCE:100\n#EXTINF:6,\nhttps://fixture.cctv.cn/100.ts\n'


class JSAdapterTests(unittest.TestCase):
    def setUp(self):
        self.calls = []
        self.upstream_failure = False
        def bridge(operation, payload):
            data = json.loads(payload)
            self.calls.append((operation, data))
            result = True
            if operation == 'catalog':
                result = [{'id': 'cctv1', 'ref': 'ysp-cctv1', 'name': 'CCTV1综合', 'logo': ''}]
            elif operation == 'resolve':
                if self.upstream_failure:
                    result = {'url': '', 'desc': '官方暂不提供直播信号'}
                else:
                    result = {'url': 'https://fixture.cctv.cn/index.m3u8', 'manifestText': MANIFEST}
            elif operation == 'epg':
                result = [{'title': '节目 & 测试', 'start': 1700000000000, 'stop': 1700003600000}]
            return json.dumps({'ok': True, 'result': result}, ensure_ascii=False)
        self.adapter = adapter_module.JSAdapter(bridge)
        self.server = adapter_module.Server(('127.0.0.1', 0), self.adapter)
        self.adapter.server = self.server
        self.worker = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.worker.start()

    def tearDown(self):
        self.adapter.stop()
        self.worker.join(2)

    def request(self, path, method='GET'):
        client = http.client.HTTPConnection('127.0.0.1', self.server.server_port, timeout=3)
        try:
            client.request(method, path, headers={'Host': 'malicious.invalid'})
            response = client.getresponse()
            return response.status, response.read().decode('utf-8'), dict(response.getheaders())
        finally:
            client.close()

    def test_subscription_and_head_probes_never_request_a_ticket(self):
        for path in ['/', '/m3u', '/all.m3u', '/all.m3u8']:
            status, body, _ = self.request(path)
            self.assertEqual(status, 200)
            self.assertIn(f'http://127.0.0.1:{self.server.server_port}/cctv1.m3u8', body)
            self.assertIn('tvg-id="ysp-cctv1"', body)
            self.assertNotIn('malicious.invalid', body)
        self.assertEqual(self.request('/cctv1.m3u8', 'HEAD')[:2], (200, ''))
        self.assertFalse(any(op == 'resolve' for op, _ in self.calls))
        self.assertEqual(json.loads(self.request('/health')[1])['engine'], 'JavaScriptCore')

    def test_manifest_is_returned_from_js_without_python_reimplementation(self):
        status, body, headers = self.request('/cctv1.m3u8')
        self.assertEqual((status, body), (200, MANIFEST))
        self.assertEqual(int(headers['Content-Length']), len(body.encode()))
        deadline = time.monotonic() + 1
        while not self.adapter.epg and time.monotonic() < deadline:
            time.sleep(.005)
        status, xml, _ = self.request('/epg.xml')
        self.assertEqual(status, 200)
        self.assertIn('节目 &amp; 测试', xml)
        self.assertTrue(all(data['session'] == self.adapter.session for _, data in self.calls))

    def test_js_upstream_refusal_is_not_a_fake_successful_playlist(self):
        self.upstream_failure = True
        status, body, _ = self.request('/cctv1.m3u8')
        self.assertEqual(status, 502)
        self.assertIn('官方暂不提供', body)
        self.assertEqual(self.request('/unknown.m3u8')[0], 404)

    def test_optional_epg_failure_does_not_append_a_second_http_response(self):
        with mock.patch.object(self.adapter, 'refresh_epg', side_effect=RuntimeError('thread unavailable')):
            self.assertEqual(self.request('/cctv1.m3u8')[:2], (200, MANIFEST))

    def test_partial_start_failure_attempts_cleanup_and_preserves_original_error(self):
        operations = []
        def broken(operation, payload):
            operations.append(operation)
            raise RuntimeError('start error' if operation == 'start' else 'stop error')
        with self.assertRaisesRegex(RuntimeError, 'start error'):
            adapter_module.JSAdapter(broken)
        self.assertEqual(operations, ['start', 'stop'])

    def test_stop_closes_native_js_session_and_http_server(self):
        self.assertTrue(self.adapter.stop())
        self.worker.join(2)
        self.assertFalse(self.worker.is_alive())
        self.assertEqual(self.calls[-1][0], 'stop')
        with self.assertRaisesRegex(RuntimeError, '正在停止'):
            self.adapter.call('resolve')
