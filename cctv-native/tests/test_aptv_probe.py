import builtins
import http.client
import importlib.util
from pathlib import Path
import threading
import unittest
from unittest import mock


def load_probe():
    spec = importlib.util.spec_from_file_location(
        'aptv_runtime_probe', Path(__file__).resolve().parents[1] / 'aptv-probe.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class TestAPTVProbe(unittest.TestCase):
    def test_reporting_does_not_import_native_or_process_runtimes(self):
        original = builtins.__import__
        blocked = {'subprocess', 'ctypes', '_ctypes', 'quickjs', 'wasmtime', 'pywasm', 'js2py'}
        def guarded(name, *args, **kwargs):
            if name.split('.')[0] in blocked:
                raise AssertionError('probe imported unavailable runtime: '+name)
            return original(name, *args, **kwargs)
        with mock.patch('builtins.__import__', side_effect=guarded):
            probe = load_probe()
            value = probe.report()
        self.assertFalse(value['subprocess_required'])
        self.assertFalse(value['external_requests'])
        self.assertIn('not-a-tv-playlist', value['purpose'])
        self.assertTrue(all(state in ('loaded', 'visible', 'absent', 'unknown')
                            for state in value['candidate_modules'].values()))

    def test_http_report_is_uncached_and_never_claims_a_playable_subscription(self):
        probe = load_probe()
        server = probe.ThreadingHTTPServer(('127.0.0.1', 0), probe.Handler)
        server.report = probe.report()
        server.daemon_threads = True
        thread = threading.Thread(target=lambda: server.serve_forever(poll_interval=0.01), daemon=True)
        thread.start()
        try:
            for method, path, status in [('GET', '/status', 200), ('HEAD', '/', 200),
                                         ('GET', '/all.m3u', 503), ('GET', '/unknown', 404)]:
                connection = http.client.HTTPConnection(*server.server_address, timeout=2)
                connection.request(method, path)
                response = connection.getresponse()
                body = response.read()
                self.assertEqual(response.status, status)
                self.assertEqual(response.getheader('Cache-Control'), 'no-store')
                self.assertNotIn(b'#EXTM3U', body)
                if method == 'HEAD':
                    self.assertEqual(body, b'')
                connection.close()
        finally:
            server.shutdown()
            server.server_close()
            thread.join(2)
