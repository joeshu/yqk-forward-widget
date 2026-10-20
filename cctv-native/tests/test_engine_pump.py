"""JSC host startup paths preserve turns, bytes and native safety gates."""
import base64
import json
import os
from pathlib import Path
import threading
import unittest
from unittest import mock
from test_jscore_service import load_service


class TestJSContextVoidExecution(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if not os.environ.get('CCTV_JSCORE_TEST_LIBRARY'):
            raise unittest.SkipTest('system JSC test library not configured')

    def setUp(self):
        self.module=load_service()
        # Test the adjacent source even before the parent rebuilds the bundle.
        path=Path(__file__).resolve().parents[1]/'jscore_engine.py'
        exec(compile(path.read_text(),str(path),'exec'),self.module.__dict__)
        self.context=self.module.JSContext(os.environ['CCTV_JSCORE_TEST_LIBRARY'])
        self.addCleanup(self.context.close)
        self.context.execute(self.module.JSCORE_HOST)
        self.engine=self.module.Engine.__new__(self.module.Engine)
        self.engine.context=self.context

    def test_void_execution_ignores_result_but_preserves_exception_and_owner_checks(self):
        self.assertIsNone(self.context.execute('globalThis.value=42;value'))
        self.assertEqual(self.context.evaluate('value'),'42')
        with self.assertRaisesRegex(self.module.NativeError,'script-failed'):
            self.context.execute('throw Error("test")')
        errors=[]
        def wrong_thread():
            try:self.context.execute('value=1')
            except Exception as e:errors.append(e)
        thread=threading.Thread(target=wrong_thread);thread.start();thread.join(1)
        self.assertEqual(len(errors),1)
        self.assertIsInstance(errors[0],self.module.NativeError)
        self.assertEqual(self.context.evaluate('value'),'42')

    def test_void_execution_retains_native_execution_timeout(self):
        with self.assertRaisesRegex(self.module.NativeError,'timed-out'):
            self.context.execute('while(true){}',timeout=.02)

    def test_pump_retains_microtask_checkpoints_between_timer_turns(self):
        self.context.execute('''
            var trace=[],tickCount=0,originalTick=__tick;
            __tick=function(){tickCount++;originalTick();};
            setTimeout(function(){
                trace.push('timer-1');
                Promise.resolve().then(function(){
                    trace.push('microtask-1');
                    setTimeout(function(){trace.push('timer-2');},0);
                });
            },0);
        ''')
        self.assertEqual(self.engine.pump(),{'pending':0})
        self.assertEqual(json.loads(self.context.evaluate('JSON.stringify(trace)')),
                         ['timer-1','microtask-1','timer-2'])
        self.assertEqual(self.context.evaluate('tickCount'),'5')

    def test_pump_processes_ordinary_verified_xhr_before_returning_ready_state(self):
        self.context.execute('''
            var testXHR=new XMLHttpRequest();
            testXHR.open('GET','/Library/H5player.json');
            testXHR.onload=function(){__state.observed=JSON.parse(testXHR.responseText).ok;};
            testXHR.send();
        ''')
        with mock.patch.object(self.module,'get',return_value=(b'{"ok":true}',self.module.REFERER)) as get:
            state=self.engine.pump()
        self.assertTrue(state['observed']);self.assertTrue(state['config']);self.assertEqual(state['pending'],0)
        self.assertEqual(get.call_count,1)
        self.assertEqual(get.call_args.args[0],'https://tv.cctv.com/Library/H5player.json')
        self.assertEqual(get.call_args.kwargs['limit'],4*1024*1024)
        self.assertEqual(get.call_args.kwargs['timeout'],8)

    def test_native_and_fallback_wasm_upload_preserve_every_public_input_byte(self):
        if not self.context.buffer_api:self.skipTest('native media buffer API unavailable')
        # A valid public miniature WASM module plus all byte values exercises
        # upload only; Engine still instantiates the pinned official binary.
        data=bytes.fromhex('0061736d01000000')+bytes(range(256))*4
        encoded=base64.b64encode(data)
        for native in (True,False):
            self.context.buffer_api=native
            self.engine._install_wasm(encoded)
            value=json.loads(self.context.evaluate('JSON.stringify(Array.from(__wasm))'))
            self.assertEqual(bytes(value),data)
            if native:self.assertEqual(self.context.evaluate('__mediaInput===null'),'true')
        self.context.buffer_api=True
