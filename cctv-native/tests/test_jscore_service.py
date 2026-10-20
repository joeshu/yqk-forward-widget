"""Exercise real C API where a system test library is explicitly supplied."""
import ast
import builtins
import importlib.util
import os
import sys
from pathlib import Path
import threading
import time
import unittest
from unittest import mock

HERE = Path(__file__).resolve().parents[1]


def load_service():
    spec = importlib.util.spec_from_file_location('cctv_aptv_test', HERE.parent/'cctv-aptv.py')
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


class TestAPTVBuild(unittest.TestCase):
    def test_standalone_has_no_process_imports_and_matches_sources(self):
        spec = importlib.util.spec_from_file_location('build_aptv', HERE/'build_aptv.py')
        builder = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(builder)
        self.assertEqual((HERE.parent/'cctv-aptv.py').read_text(), builder.render())
        original = builtins.__import__
        def guarded(name, *args, **kwargs):
            if name.split('.')[0] in ('subprocess', 'shutil', 'signal'):
                raise AssertionError('APTV imported process-dependent module: '+name)
            return original(name, *args, **kwargs)
        with mock.patch('builtins.__import__', side_effect=guarded):
            module = load_service()
        self.assertTrue(callable(module.main))
        tree = ast.parse((HERE.parent/'cctv-aptv.py').read_text())
        definitions = {n.name for n in tree.body if isinstance(n, ast.FunctionDef)}
        self.assertIn('main', definitions)
        self.assertIn('start', definitions)
        self.assertFalse(any(isinstance(n,ast.Call) and isinstance(n.func,ast.Name)
                             and n.func.id in ('exec','compile') for n in ast.walk(tree)))
        self.assertFalse(hasattr(module, 'subprocess'))

    def test_generated_server_starts_before_sdk_download_and_provides_subscription(self):
        import http.client
        import types
        module = load_service()
        args = types.SimpleNamespace(warmup=False, buffer_mb=32,idle_timeout=120)
        server = module.ThreadingHTTPServer(('127.0.0.1',0), module.Handler)
        server.daemon_threads = True
        server.channel, server.args = module.Channel(args),args
        thread = threading.Thread(target=lambda:server.serve_forever(poll_interval=.01),daemon=True)
        thread.start()
        try:
            with mock.patch.object(module, 'get', side_effect=AssertionError('unexpected external request')):
                connection=http.client.HTTPConnection(*server.server_address,timeout=2)
                connection.request('GET','/all.m3u')
                response=connection.getresponse()
                self.assertEqual(response.status,200)
                self.assertIn(b'/cctv2.m3u8',response.read())
                connection.close()
                self.assertIsNone(server.channel.thread)
        finally:
            server.shutdown();server.server_close();thread.join(2)


class TestRuntimeMemoryCache(unittest.TestCase):
    def prepare(self):
        import hashlib
        module = load_service()
        raw = b'unit-test-runtime-bytes'
        module.RUNTIME_SHA = hashlib.sha256(raw).hexdigest()
        return module, raw

    def test_default_never_accesses_filesystem_and_reuses_verified_memory(self):
        module, raw = self.prepare()
        with mock.patch.object(module,'Path',side_effect=AssertionError('filesystem accessed')), \
             mock.patch.object(module,'get',return_value=(raw,module.RUNTIME_URL)) as fetch:
            self.assertEqual(module.load_runtime(),raw)
            self.assertEqual(module.load_runtime(),raw)
            fetch.assert_called_once()

    def test_unwritable_explicit_cache_does_not_prevent_playback(self):
        module,raw=self.prepare()
        with mock.patch.object(module.Path,'is_file',return_value=False), \
             mock.patch.object(module.Path,'mkdir',side_effect=PermissionError('sandbox path')), \
             mock.patch.object(module,'get',return_value=(raw,module.RUNTIME_URL)):
            self.assertEqual(module.load_runtime('/restricted/cache'),raw)
        self.assertEqual(module._RUNTIME_MEMORY,raw)

    def test_unreadable_explicit_cache_can_download_into_memory(self):
        module,raw=self.prepare()
        with mock.patch.object(module.Path,'is_file',return_value=True), \
             mock.patch.object(module.Path,'read_bytes',side_effect=PermissionError('sandbox path')), \
             mock.patch.object(module.Path,'mkdir',side_effect=PermissionError('sandbox path')), \
             mock.patch.object(module,'get',return_value=(raw,module.RUNTIME_URL)):
            self.assertEqual(module.load_runtime('/restricted/cache'),raw)

    def test_download_permission_error_reports_operation_without_private_path(self):
        module,_=self.prepare()
        with mock.patch.object(module,'get',side_effect=PermissionError('private path')):
            with self.assertRaisesRegex(module.NativeError,'^official-runtime-download-permission-denied$'):
                module.load_runtime()
        self.assertIsNone(module._RUNTIME_MEMORY)

    def test_changed_runtime_is_rejected_before_it_enters_memory_cache(self):
        module,_=self.prepare()
        with mock.patch.object(module,'get',return_value=(b'wrong',module.RUNTIME_URL)):
            with self.assertRaisesRegex(module.NativeError,'official-runtime-version-changed'):
                module.load_runtime()
        self.assertIsNone(module._RUNTIME_MEMORY)


@unittest.skipUnless(os.environ.get('CCTV_JSCORE_TEST_LIBRARY'), 'real JavaScriptCore library not configured')
class TestRealJSCore(unittest.TestCase):
    def setUp(self):
        self.module=load_service()
        self.context=self.module.JSContext(os.environ['CCTV_JSCORE_TEST_LIBRARY'])

    def tearDown(self):
        self.context.close()

    def test_persistent_context_and_wasm(self):
        self.context.evaluate('var saved=41;')
        self.assertEqual(self.context.evaluate('saved+1'),'42')
        self.assertEqual(self.context.evaluate('typeof WebAssembly'),'object')

    def test_infinite_script_is_terminated_by_native_time_limit(self):
        start=time.monotonic()
        with self.assertRaises(self.module.NativeError):
            self.context.evaluate('while(true){}',timeout=.05)
        self.assertLess(time.monotonic()-start,3)

    def test_context_rejects_cross_thread_use(self):
        result=[]
        def run():
            try:self.context.evaluate('1')
            except self.module.NativeError:result.append('rejected')
        thread=threading.Thread(target=run);thread.start();thread.join(2)
        self.assertEqual(result,['rejected'])

    def test_browser_storage_preserves_binary_and_transaction_callbacks(self):
        self.context.evaluate(self.module.JSCORE_HOST)
        self.context.evaluate(self.module.IDB_SOURCE)
        self.context.evaluate('''var __testResult=null;
            var r=indexedDB.open('test',1);
            r.onupgradeneeded=function(){r.result.createObjectStore('items');};
            r.onsuccess=function(){
                var db=r.result,t=db.transaction('items','readwrite');
                t.objectStore('items').put(new Uint8Array([0,255,42]).buffer,'x');
                t.oncomplete=function(){var t2=db.transaction('items');
                    var q=t2.objectStore('items').get('x');
                    q.onsuccess=function(){__testResult=Array.from(new Uint8Array(q.result));};};
            };''')
        for _ in range(30):
            self.context.evaluate('__tick()')
        self.assertEqual(self.context.evaluate('JSON.stringify(__testResult)'),'[0,255,42]')
