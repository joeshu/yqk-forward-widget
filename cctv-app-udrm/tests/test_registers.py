"""Register fast path must preserve signed ABI values and fail closed."""
import json,os
from pathlib import Path
import unittest
from unittest.mock import patch
from test_allocator import entry,JSCHost,APPLE
from test_bridge import service

class RegisterTests(unittest.TestCase):
 def test_batch_scalar_and_failure_semantics(self):
  library=os.environ.get('CCTV_JSC_LIBRARY',APPLE)
  if not Path(library).exists():self.skipTest('JavaScriptCore unavailable')
  host=JSCHost(library)
  try:
   host.evaluate(entry.JS_SOURCES['koo_vm.js'])
   result=json.loads(host.evaluate('''
var memory=new WebAssembly.Memory({initial:4}),next=16,values=new Map(),fail=false;
var v=Object.create(KooVM.prototype);v.bulk=null;v.e={handle_ptr:8};
var m={ERR_OK:0,ARM64_REG_LR:30,getValue:()=>123,ccall:()=>0,_malloc:n=>{var p=next;next+=n;return p;},_free:()=>{}};
for(var i=0;i<8;i++)m['ARM64_REG_X'+i]=i;
m._uc_reg_read=(h,r,p)=>{if(fail)return 6;new DataView(memory.buffer).setBigInt64(p,values.get(r)||0n,true);return 0;};
m._uc_reg_write=(h,r,p)=>{if(fail)return 6;values.set(r,new DataView(memory.buffer).getBigInt64(p,true));return 0;};
m._uc_reg_read_batch=(h,ids,ptrs,n)=>{if(fail)return 6;var d=new DataView(memory.buffer);for(var i=0;i<n;i++)m._uc_reg_read(h,d.getInt32(ids+i*4,true),d.getUint32(ptrs+i*4,true));return 0;};
v.uc=m;v.installBulkMemory(memory);
var expected=[-1n,0n,4294967295n,4294967296n,-2147483648n,42n,7n,19n];
for(var i=0;i<8;i++)v.e.reg_write_i64(i,expected[i]);v.e.reg_write_i64(30,123456n);
var read=v.readNativeArguments(),equal=read.lr===123456&&read.args.every((x,i)=>x===Number(expected[i]));
var scalar=expected.every((x,i)=>v.e.reg_read_i64(i)===x),failures=0;fail=true;
for(var call of [()=>v.readNativeArguments(),()=>v.e.reg_read_i64(0),()=>v.e.reg_write_i64(0,1n)])try{call();}catch(error){failures++;}
JSON.stringify({equal,scalar,failures});
'''))
   self.assertTrue(result['equal']);self.assertTrue(result['scalar']);self.assertEqual(result['failures'],3)
  finally:host.close()
 def test_tls_eof_retries_once_with_same_limits(self):
  error=service.LiveError('Upstream transport URLError/SSLEOFError')
  with patch.object(service,'_fetch_once',side_effect=[error,(b'complete','https://example.test/a')]) as fetch:
   self.assertEqual(service.fetch('https://example.test/a',1024,5)[0],b'complete')
  self.assertEqual(fetch.call_count,2)
  self.assertEqual(fetch.call_args_list[0],fetch.call_args_list[1])
 def test_non_transient_failure_and_second_eof_are_not_retried_indefinitely(self):
  for reason,count in [('Upstream transport URLError/SSLCertVerificationError',1),('Upstream HTTP 403',1),('Incomplete upstream Content-Length',1),('Upstream transport TimeoutError',1),('Upstream transport SSLEOFError',2)]:
   with self.subTest(reason=reason),patch.object(service,'_fetch_once',side_effect=service.LiveError(reason)) as fetch:
    with self.assertRaises(service.LiveError):service.fetch('https://example.test/a',1024)
    self.assertEqual(fetch.call_count,count)

if __name__=='__main__':unittest.main()
