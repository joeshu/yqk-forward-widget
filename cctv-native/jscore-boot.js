// Original Emscripten host hook; original downloaded JS and WASM are unchanged.
var __module = CNTVModule({
    instantiateWasm: function(imports, receive) {
        var instance = new WebAssembly.Instance(new WebAssembly.Module(__wasm), imports);
        receive(instance);
        return instance.exports;
    },
    print: function(){}, printErr: function(){},
    onAbort: function(){ __state.error = 'sdk-aborted'; },
    onRuntimeInitialized: function() {
        setTimeout(function() {
            CNTVH5PlayerModule = __module;
            var name = new Uint8Array([99,99,116,118,45,110,97,116,105,118,101,45,112,108,97,121,101,114]);
            var pointer = __module._jsmalloc(name.length + 2048);
            if (!pointer) throw Error('runtime-allocation-failed');
            __module.HEAPU8.fill(0, pointer, pointer + name.length + 2048);
            __module.HEAPU8.set(name, pointer);
            try { __module._CNTV_InitPlayer(pointer); __state.init = true; }
            finally { __module._jsfree(pointer); }
        }, 0);
    }
});
