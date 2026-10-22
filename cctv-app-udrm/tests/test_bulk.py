"""Bulk host memory adapter preserves bytes and rejects failed native reads."""
import json
import os
from pathlib import Path
import unittest
from test_allocator import entry,JSCHost,APPLE

class BulkTests(unittest.TestCase):
 def test_growth_roundtrip_failed_reads_and_bounds(self):
  library=os.environ.get('CCTV_JSC_LIBRARY',APPLE)
  if not Path(library).exists():self.skipTest('JavaScriptCore unavailable')
  host=JSCHost(library)
  try:
   host.evaluate(entry.JS_SOURCES['koo_vm.js'])
   result=json.loads(host.evaluate('''
var memory=new WebAssembly.Memory({initial:1,maximum:16}),guest=new Uint8Array(200000),next=16,frees=0;
var v=Object.create(KooVM.prototype);v.bulk=null;v.e={handle_ptr:8};
v.uc={ERR_OK:0,getValue:function(){return 123;},_free:function(){frees++;},
_malloc:function(n){var p=next;next+=n;while(memory.buffer.byteLength<next)memory.grow(1);return p;},
ccall:function(name,result,types,args){var offset=Number(args[1]),p=args[2],n=Number(args[3]);
 if(offset<0||offset+n>guest.length)return 6;
 if(name==='uc_mem_read')new Uint8Array(memory.buffer,p,n).set(guest.subarray(offset,offset+n));
 else guest.set(new Uint8Array(memory.buffer,p,n),offset);return 0;}};
v.installBulkMemory(memory);
var small=new Uint8Array([1,3,5,7]);v.e.mem_write(0,small);var original=v.e.mem_read(0,4);
var large=new Uint8Array(150000);for(var i=0;i<large.length;i++)large[i]=(i*11)&255;
v.e.mem_write(32,large);var out=v.e.mem_read(32,large.length),equal=out.every((x,i)=>x===large[i]);
var originalUnchanged=original.join(',')==='1,3,5,7',rejected=false,bounded=false;
try{v.e.mem_read(199999,2);}catch(error){rejected=true;}
try{v.e.mem_read(0,16777217);}catch(error){bounded=true;}
JSON.stringify({equal,originalUnchanged,rejected,bounded,grown:memory.buffer.byteLength>65536,frees});
'''))
   for flag in ['equal','originalUnchanged','rejected','bounded','grown']:self.assertTrue(result[flag],flag)
   self.assertGreaterEqual(result['frees'],1)
  finally:host.close()

 def test_raw_exports_are_used_without_ccall_when_available(self):
  library=os.environ.get('CCTV_JSC_LIBRARY',APPLE)
  if not Path(library).exists():self.skipTest('JavaScriptCore unavailable')
  host=JSCHost(library)
  try:
   host.evaluate(entry.JS_SOURCES['koo_vm.js'])
   row=json.loads(host.evaluate('''(()=>{
    const memory=new WebAssembly.Memory({initial:2}),guest=new Uint8Array(1024);let next=32,calls=0;
    const vm=Object.create(KooVM.prototype);vm.e={handle_ptr:8};vm.uc={ERR_OK:0,getValue:()=>123,_malloc:n=>{const p=next;next+=n;return p;},_free:()=>{},ccall:()=>{throw Error('unexpected marshalling');},
     _uc_mem_read:(h,a,p,n)=>{calls++;a=Number(a);n=Number(n);if(a+n>guest.length)return 6;new Uint8Array(memory.buffer,p,n).set(guest.subarray(a,a+n));return 0;},
     _uc_mem_write:(h,a,p,n)=>{calls++;a=Number(a);n=Number(n);if(a+n>guest.length)return 7;guest.set(new Uint8Array(memory.buffer,p,n),a);return 0;}};
    vm.installBulkMemory(memory);vm.e.mem_write(0,new Uint8Array([0,255,13]));const bytes=Array.from(vm.e.mem_read(0,3));let failed=false;
    try{vm.e.mem_read(1023,2);}catch(e){failed=true;}
    return JSON.stringify({raw:vm.bulk.rawMemoryApi,bytes,calls,failed});
   })()'''))
   self.assertTrue(row['raw']);self.assertTrue(row['failed']);self.assertEqual(row['bytes'],[0,255,13]);self.assertEqual(row['calls'],3)
  finally:host.close()
