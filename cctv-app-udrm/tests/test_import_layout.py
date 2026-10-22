"""Real SDK relocation/import checks; no media or license exchanges."""
import json
import os
import unittest
from test_bridge import standalone
from bootstrap_nojdk import prepare
from elf_image import image_plan
from wasm_sdk import WasmSDK


class ImportLayout(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cache = os.environ.get('CCTV_SDK_CACHE')
        if not cache:
            raise unittest.SkipTest('Set CCTV_SDK_CACHE to verified SDK cache for integration checks')
        config = prepare(standalone.JS_SOURCES['koo_vm.js'], cache_dir=cache,
                         jscore_library=os.environ.get('CCTV_JSC_LIBRARY'))
        cls.sdk = WasmSDK(config)
        rows = [{k: item[k] for k in ('offset', 'addend', 'import')}
                for item in image_plan(config['sdk_bytes'])['relocations']
                if item.get('import') in {'memcpy', 'memmove', 'memset', 'memcmp', 'strlen'}]
        cls.sdk.host.install_json('__layoutRelocations', json.dumps(rows))

    @classmethod
    def tearDownClass(cls):
        cls.sdk.close()

    def test_active_fast_imports_form_one_contiguous_grouped_hook_range(self):
        row = json.loads(self.sdk.host.evaluate('''(()=>{
            const vm=__vm;
            if(!vm.fastMemoryHooks)throw Error('fast hooks unavailable');
            const imports=['memcpy','memmove','memset','memcmp','strlen']
                .filter(name=>vm.importAddresses[name]!==undefined)
                .map(name=>({name,address:vm.importAddresses[name]}))
                .sort((a,b)=>a.address-b.address);
            return JSON.stringify({imports,grouped:vm.fastMemoryHooks.grouped,
                installed:vm.fastMemoryHooks.installed.length});
        })()'''))
        rows = row['imports']
        self.assertGreaterEqual(len(rows), 3)
        self.assertEqual(len({item['address'] for item in rows}), len(rows))
        for previous, current in zip(rows, rows[1:]):
            self.assertEqual(current['address'], previous['address'] + 8)
        self.assertTrue(row['grouped'])
        self.assertEqual(row['installed'], 1)
        self.assertEqual(self.sdk.features()['code_hook_count'], 2)

    def test_every_import_still_resolves_by_name_and_reverse_mapping(self):
        row = json.loads(self.sdk.host.evaluate('''(()=>{
            const vm=__vm,failures=[];
            for(const [name,address] of Object.entries(vm.importAddresses)){
                const text=vm.cstring(name);
                try {
                    if(vm.invoke(vm.importAddresses.dlsym,[vm.base,text])!==address)
                        failures.push(name+':dlsym');
                    if(vm.addressImports[address]!==name)failures.push(name+':reverse');
                } finally {vm.free(text);}
            }
            return JSON.stringify({checked:Object.keys(vm.importAddresses).length,failures});
        })()'''))
        self.assertGreater(row['checked'], 0)
        self.assertEqual(row['failures'], [])

    def test_relocated_function_pointers_execute_copy_and_length(self):
        row = json.loads(self.sdk.host.evaluate('''(()=>{
            const vm=__vm,p=vm.allocate(32),q=vm.allocate(32),failures=[];
            const slots={};
            try {
                for(const item of __layoutRelocations){
                    const target=vm.read64(vm.base+item.offset);
                    if(target!==vm.importAddresses[item.import]+item.addend)
                        failures.push(item.import);
                    if(item.addend===0&&slots[item.import]===undefined)slots[item.import]=target;
                }
                if(slots.memcpy===undefined||slots.strlen===undefined)
                    throw Error('expected imported function relocation missing');
                const input=new Uint8Array([108,97,121,111,117,116,45,116,101,115,116,0]);
                vm.write(p,input);
                const returned=vm.invoke(slots.memcpy,[q,p,input.length]);
                return JSON.stringify({failures,length:vm.invoke(slots.strlen,[q]),
                    copied:Array.from(vm.read(q,input.length)),return_matches:returned===q});
            } finally {vm.free(p);vm.free(q);}
        })()'''))
        self.assertEqual(row['failures'], [])
        self.assertTrue(row['return_matches'])
        self.assertEqual(row['length'], 11)
        self.assertEqual(row['copied'], list(b'layout-test\0'))

    def test_grouped_hook_rejects_padding_entry_and_recovers(self):
        result = self.sdk.host.evaluate('''(()=>{
            const vm=__vm,p=vm.allocate(32);
            try {
                if(!vm.fastMemoryHooks.grouped)throw Error('grouped hook unavailable');
                let failed=false;
                try {vm.invoke(vm.importAddresses.memcpy+4,[p,p,0]);}
                catch(e) {
                    if(!String(e).includes('WASM memory hook failed -5'))throw e;
                    failed=true;
                }
                if(!failed)throw Error('padding entry reported success');
                if(vm.invoke(vm.importAddresses.memset,[p,0,0])!==p)
                    throw Error('valid entry failed after padding error');
                return 'ok';
            } finally {vm.free(p);}
        })()''')
        self.assertEqual(result, 'ok')
