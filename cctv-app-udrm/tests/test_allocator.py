"""JSC host allocator regression without loading SDK code or making requests."""
import importlib.util
import json
import os
from pathlib import Path
import unittest
ROOT=Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('allocator_entry',ROOT/'cctv-app-udrm.py')
entry=importlib.util.module_from_spec(spec);spec.loader.exec_module(entry);entry.load_modules()
from jsc_host import JSCHost,APPLE

class AllocatorTests(unittest.TestCase):
    def test_variable_frames_reuse_and_coalesce_heap(self):
        library=os.environ.get('CCTV_JSC_LIBRARY',APPLE)
        if not Path(library).exists():self.skipTest('system JavaScriptCore unavailable in this test environment')
        context=JSCHost(library)
        try:
            context.evaluate(entry.JS_SOURCES['koo_vm.js'])
            result=json.loads(context.evaluate('''
var v=Object.create(KooVM.prototype);v.heap=0x100000;v.bump=v.heap;
v.allocations=new Map();v.freeBlocks=[];
v.write=function(){};
var state=v.allocate(1024),peak=v.bump;
for(var i=0;i<10000;i++){
 var a=v.allocate(1024+(i*7919)%200000),b=v.allocate(128+(i*83)%4096);
 v.free(a);var c=v.allocate(512+(i*191)%8192);v.free(b);v.free(c);
 peak=Math.max(peak,v.bump);
}
v.free(state);
JSON.stringify({iterations:10000,remaining:v.allocations.size,finalOffset:v.bump-v.heap,peakOffset:peak-v.heap});
'''))
            self.assertEqual(result['remaining'],0);self.assertEqual(result['finalOffset'],0)
            self.assertLess(result['peakOffset'],1024*1024)
        finally:context.close()
if __name__=='__main__':unittest.main()
