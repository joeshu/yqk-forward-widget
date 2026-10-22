"""Real ARM invocations for WASM compare/string hooks; no media or license."""
import json
import os
import unittest
from test_bridge import standalone
from bootstrap_nojdk import prepare
from wasm_sdk import WasmSDK


class WasmCompareHooks(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cache = os.environ.get('CCTV_SDK_CACHE')
        if not cache:
            raise unittest.SkipTest('Set CCTV_SDK_CACHE to verified SDK cache for integration checks')
        config = prepare(standalone.JS_SOURCES['koo_vm.js'], cache_dir=cache,
                         jscore_library=os.environ.get('CCTV_JSC_LIBRARY'))
        cls.sdk = WasmSDK(config)

    @classmethod
    def tearDownClass(cls):
        cls.sdk.close()

    def test_memcmp_unsigned_bytes_signed_return_zero_and_late_difference(self):
        self.assertTrue(self.sdk.features()['wasm_compare_hooks'])
        row = json.loads(self.sdk.host.evaluate('''(()=>{
            const vm=__vm,p=vm.allocate(8192),q=vm.allocate(8192);
            const before=vm.memoryBackend.compares(),js=vm.counts.memcmp||0;
            try {
                vm.write(p,new Uint8Array(8192));vm.write(q,new Uint8Array(8192));
                const results=[vm.invoke(vm.importAddresses.memcmp,[0,0,0])];
                vm.write(p,new Uint8Array([0]));vm.write(q,new Uint8Array([255]));
                results.push(vm.invoke(vm.importAddresses.memcmp,[p,q,1]));
                results.push(vm.invoke(vm.importAddresses.memcmp,[q,p,1]));
                vm.write(p,new Uint8Array(8192));vm.write(q,new Uint8Array(8192));
                vm.write(p+4097,new Uint8Array([128]));
                vm.write(q+4097,new Uint8Array([129]));
                results.push(vm.invoke(vm.importAddresses.memcmp,[p,q,4097]));
                results.push(vm.invoke(vm.importAddresses.memcmp,[p,q,8192]));
                return JSON.stringify({results,fast:vm.memoryBackend.compares()-before,
                    js:(vm.counts.memcmp||0)-js});
            } finally {vm.free(p);vm.free(q);}
        })()'''))
        self.assertEqual(row['results'], [0, -255, 255, 0, -1])
        self.assertGreaterEqual(row['fast'], 5)
        self.assertEqual(row['js'], 0)

    def test_memcmp_unmapped_tail_fails_even_when_first_byte_differs(self):
        # A separate synthetic mapped page gives an exact unmapped boundary;
        # allocations in the normal VM heap all share a larger mapped region.
        result = self.sdk.host.evaluate('''(()=>{
            const vm=__vm,address=0x60000000,q=vm.allocate(64);
            vm.e.mem_map(address,4096,vm.uc.PROT_ALL);
            try {
                vm.write(address+4080,new Uint8Array(16));
                vm.write(q,new Uint8Array(64).fill(255));
                let failed=false;
                try {vm.invoke(vm.importAddresses.memcmp,[address+4080,q,32]);}
                catch(e) {if(!String(e).includes('WASM memory hook failed'))throw e;failed=true;}
                if(!failed)throw Error('unmapped comparison reported success');
                if(vm.invoke(vm.importAddresses.memcmp,[q,q,64])!==0)throw Error('failed to recover');
                return 'ok';
            } finally {vm.e.mem_unmap(address,4096);vm.free(q);}
        })()''')
        self.assertEqual(result, 'ok')

    def test_strlen_crosses_pages_and_does_not_consume_unused_registers(self):
        self.assertTrue(self.sdk.features()['wasm_strlen_hooks'])
        row = json.loads(self.sdk.host.evaluate('''(()=>{
            const vm=__vm,p=vm.allocate(16384),start=p+7;
            const before=vm.memoryBackend.lengths(),js=vm.counts.strlen||0;
            try {
                vm.write(start,new Uint8Array(8194).fill(97));
                vm.write(start+8193,new Uint8Array([0]));
                vm.e.reg_write_i64(vm.uc.ARM64_REG_X1,0xffffffffffffffffn);
                vm.e.reg_write_i64(vm.uc.ARM64_REG_X2,0xffffffffffffffffn);
                const length=vm.invoke(vm.importAddresses.strlen,[start]);
                const empty=vm.invoke(vm.importAddresses.strlen,[start+8193]);
                return JSON.stringify({length,empty,fast:vm.memoryBackend.lengths()-before,
                    js:(vm.counts.strlen||0)-js});
            } finally {vm.free(p);}
        })()'''))
        self.assertEqual((row['length'], row['empty']), (8193, 0))
        self.assertGreaterEqual(row['fast'], 2)
        self.assertEqual(row['js'], 0)

    def test_strlen_page_end_null_does_not_read_next_unmapped_page(self):
        result = self.sdk.host.evaluate('''(()=>{
            const vm=__vm,address=0x60000000;
            vm.e.mem_map(address,4096,vm.uc.PROT_ALL);
            try {
                vm.write(address+4090,new Uint8Array([97,98,99,100,101,0]));
                return vm.invoke(vm.importAddresses.strlen,[address+4090]);
            } finally {vm.e.mem_unmap(address,4096);}
        })()''')
        self.assertEqual(result, '5')

    def test_strlen_null_and_unterminated_limit_fail_then_recover(self):
        with self.assertRaisesRegex(RuntimeError, 'WASM memory hook failed'):
            self.sdk.host.evaluate('__vm.invoke(__vm.importAddresses.strlen,[0])')
        result = self.sdk.host.evaluate('''(()=>{
            const vm=__vm,p=vm.allocate(1048592);
            try {
                vm.write(p,new Uint8Array(1048576).fill(97));
                vm.write(p+1048576,new Uint8Array([0]));
                let failed=false;
                try {vm.invoke(vm.importAddresses.strlen,[p]);}
                catch(e) {if(!String(e).includes('WASM memory hook failed'))throw e;failed=true;}
                if(!failed)throw Error('string cap was not enforced');
                vm.write(p,new Uint8Array([0]));
                return vm.invoke(vm.importAddresses.strlen,[p]);
            } finally {vm.free(p);}
        })()''')
        self.assertEqual(result, '0')
