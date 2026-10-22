"""Synthetic JSC API-failure checks; no emulator, SDK, media or network."""
import json
import os
from pathlib import Path
import unittest
from test_bridge import standalone
from jsc_host import JSCHost, APPLE


class WasmHookCleanup(unittest.TestCase):
    def run_js(self, source):
        library = os.environ.get('CCTV_JSC_LIBRARY', APPLE)
        if not Path(library).exists():
            self.skipTest('system JavaScriptCore unavailable in this test environment')
        host = JSCHost(library)
        try:
            host.evaluate(standalone.JS_SOURCES['koo_vm.js'])
            return json.loads(host.evaluate(source))
        finally:
            host.close()

    def test_missing_getvalue_returns_no_hooks_without_touching_backend(self):
        row = self.run_js('''(()=>{
            const vm=Object.create(KooVM.prototype),events=[];
            vm.uc={};vm.e={handle_ptr:77};vm.bulk={directWasmImports:true};
            vm.memoryBackend={init(){events.push('init');throw Error('must not initialize');},close(){events.push('close');}};
            return JSON.stringify({hooks:vm.installMemoryHooks(),events});
        })()''')
        self.assertEqual(row, {'hooks': [], 'events': []})

    def test_failed_rollback_does_not_remove_live_callback_or_free_backend(self):
        row = self.run_js('''(()=>{
            const vm=Object.create(KooVM.prototype),events=[];let count=0;
            vm.uc={ERR_OK:0,HOOK_CODE:4,
                getValue(p){return p===77?99:123;},
                addFunction(){events.push('addFunction');return 7;},
                removeFunction(){events.push('removeFunction');},
                _malloc(){return 100;},_free(){events.push('free_storage');},
                _uc_hook_add(){events.push('hook_add');return ++count===1?0:9;},
                _uc_hook_del(h,hook){events.push('hook_del');return 8;}};
            vm.e={handle_ptr:77};vm.bulk={directWasmImports:true};
            vm.importAddresses={memcpy:0x20000000,memmove:0x20000008};
            vm.memoryBackend={hook(){},init(){return 0;},close(){events.push('backend.close');}};
            let error='';try{vm.installMemoryHooks();}catch(e){error=String(e);}
            return JSON.stringify({error,events});
        })()''')
        self.assertIn('WASM hook rollback failed 8', row['error'])
        self.assertIn('hook_del', row['events'])
        self.assertNotIn('removeFunction', row['events'])
        self.assertNotIn('backend.close', row['events'])

    def test_successful_rollback_removes_hooks_before_callback_and_backend(self):
        row = self.run_js('''(()=>{
            const vm=Object.create(KooVM.prototype),events=[];let count=0;
            vm.uc={ERR_OK:0,HOOK_CODE:4,
                getValue(p){return p===77?99:123;},
                addFunction(){return 7;},removeFunction(){events.push('removeFunction');},
                _malloc(){return 100;},_free(){},
                _uc_hook_add(){return ++count===1?0:9;},
                _uc_hook_del(){events.push('hook_del');return 0;}};
            vm.e={handle_ptr:77};vm.bulk={directWasmImports:true};
            vm.importAddresses={memcpy:0x20000000,memmove:0x20000008};
            vm.memoryBackend={hook(){},init(){return 0;},close(){events.push('backend.close');}};
            return JSON.stringify({hooks:vm.installMemoryHooks(),events,enabled:vm.bulk.wasmMemoryHooks});
        })()''')
        self.assertEqual(row['hooks'], [])
        self.assertEqual(row['events'], ['hook_del', 'removeFunction', 'backend.close'])
        self.assertFalse(row['enabled'])

    def test_close_rejects_hook_removal_failure_before_freeing_callback(self):
        row = self.run_js('''(()=>{
            const vm=Object.create(KooVM.prototype),events=[];
            vm.uc={ERR_OK:0,getValue(){return 99;},
                _uc_hook_del(){events.push('hook_del');return 8;},
                removeFunction(){events.push('removeFunction');}};
            vm.e={handle_ptr:77,close(){events.push('engine.close');}};
            vm.fastMemoryHooks={installed:[{hook:123}],callback:7};
            vm.memoryBackend={close(){events.push('backend.close');}};
            vm.bulk={};let error='';try{vm.close();}catch(e){error=String(e);}
            return JSON.stringify({error,events});
        })()''')
        self.assertIn('WASM hook removal failed 8', row['error'])
        self.assertEqual(row['events'], ['hook_del'])
