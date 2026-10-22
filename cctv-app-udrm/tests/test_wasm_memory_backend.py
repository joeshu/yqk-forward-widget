"""Exercise the new WASM hook through real ARM64 emulation, never media or license."""
import os,json,unittest,re
from pathlib import Path
from test_bridge import standalone
from bootstrap_nojdk import prepare
from wasm_sdk import WasmSDK
class WasmMemoryBackend(unittest.TestCase):
 @classmethod
 def setUpClass(cls):
  cache=os.environ.get('CCTV_SDK_CACHE')
  if not cache:raise unittest.SkipTest('Set CCTV_SDK_CACHE to verified SDK cache for integration checks')
  cls.config=prepare(standalone.JS_SOURCES['koo_vm.js'],cache_dir=cache,jscore_library=os.environ.get('CCTV_JSC_LIBRARY'))
  cls.sdk=WasmSDK(cls.config)
 @classmethod
 def tearDownClass(cls):cls.sdk.close()
 def test_backend_is_direct_wasm_and_bypasses_js_import_dispatch(self):
  self.assertTrue(self.sdk.features()['wasm_memory_hooks']);self.assertTrue(self.sdk.features()['direct_wasm_imports'])
  result=json.loads(self.sdk.host.evaluate('''(()=>{const vm=__vm,p=vm.allocate(32),q=vm.allocate(32),before=vm.counts.memcpy||0;try{vm.invoke(vm.importAddresses.memset,[p,171,32]);vm.invoke(vm.importAddresses.memcpy,[q,p,32]);return JSON.stringify({bytes:Array.from(vm.read(q,32)),js_dispatches:(vm.counts.memcpy||0)-before});}finally{vm.free(p);vm.free(q);}})()'''))
  self.assertEqual(result['bytes'],[171]*32);self.assertEqual(result['js_dispatches'],0)
 def test_overlap_zero_page_crossing_and_large_copy_match_snapshot_semantics(self):
  result=self.sdk.host.evaluate('''(()=>{const vm=__vm,p=vm.allocate(131072);try{for(const n of [0,1,17,4096,65537]){for(const offset of [0,7,4095]){const input=Uint8Array.from({length:131072},(_,i)=>(i*17+3)&255);vm.write(p,input);const expected=input.slice();expected.set(input.slice(0,n),offset);vm.invoke(vm.importAddresses.memmove,[p+offset,p,n]);const actual=vm.read(p,131072);if(actual.some((x,i)=>x!==expected[i]))throw Error('copy mismatch');}}return 'ok';}finally{vm.free(p);}})()''')
  self.assertEqual(result,'ok')
 def test_unmapped_guest_memory_and_oversize_fail_without_returning_success(self):
  for args in ['[1,0,16]','[0x30000000,0,16777217]']:
   with self.assertRaisesRegex(RuntimeError,'WASM memory hook failed'):self.sdk.host.evaluate('__vm.invoke(__vm.importAddresses.memcpy,'+args+')')
  # Next call must clear the prior error and still work.
  self.assertEqual(self.sdk.host.evaluate('__vm.invoke(__vm.importAddresses.memset,[0x30000000,0,0])'),'805306368')

 def test_explicit_compatibility_mode_uses_original_js_dispatch(self):
  sdk=WasmSDK(dict(self.config,wasm_memory_ops=False))
  try:
   self.assertFalse(sdk.features()['wasm_memory_hooks']);self.assertFalse(sdk.features()['wasm_memory_ops'])
   self.assertEqual(sdk.host.evaluate('__vm.invoke(__vm.importAddresses.memset,[0x30000000,0,0])'),'805306368')
   self.assertGreater(sdk.counts().get('memset',0),0)
  finally:sdk.close()
 def test_invalid_backend_module_falls_back_without_disabling_official_sdk(self):
  source=self.config['vm_source']
  source=re.sub(r"const bytes=Uint8Array.from\(atob\('[^']+'\)","const bytes=Uint8Array.from(atob('AA==')",source,count=1)
  sdk=WasmSDK(dict(self.config,vm_source=source))
  try:
   self.assertFalse(sdk.features()['wasm_memory_ops'])
   self.assertEqual(sdk.host.evaluate('__vm.invoke(__vm.importAddresses.memset,[0x30000000,0,0])'),'805306368')
  finally:sdk.close()

 def test_failed_hook_installation_restores_generic_dispatch(self):
  prefix="var __originalHookAdd=__uc._uc_hook_add;var __failedOnce=false;__uc._uc_hook_add=function(...a){if(!__failedOnce){__failedOnce=true;return 99;}return __originalHookAdd(...a);};\n"
  sdk=WasmSDK(dict(self.config,vm_source=prefix+self.config['vm_source']))
  try:
   self.assertTrue(sdk.features()['wasm_memory_ops']);self.assertFalse(sdk.features()['wasm_memory_hooks'])
   self.assertEqual(sdk.host.evaluate('__vm.invoke(__vm.importAddresses.memset,[0x30000000,0,0])'),'805306368')
   self.assertGreater(sdk.counts().get('memset',0),0)
  finally:sdk.close()
