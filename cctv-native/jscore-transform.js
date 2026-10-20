function failure(s){return Error(s);}
  function allocate(bytes, extra = 2048) {
    const pointer = __module._jsmalloc(bytes.length + extra);
    if (!Number.isInteger(pointer) || pointer <= 0) throw failure('runtime-allocation-failed');
    __module.HEAPU8.fill(0, pointer, pointer + bytes.length + extra);
    __module.HEAPU8.set(bytes, pointer);
    return pointer;
  }

  // Match the official caller's ownership: each API operation gets a fresh
  // player-name buffer, and only the dispatcher chain shares that buffer.
  function playerOperation(method) {
    // moduleActive reserves its 2048-byte workspace; moduleDecData below
    // separately uses only the null-terminated player-name buffer.
    const pointer = allocate(new Uint8Array([99,99,116,118,45,110,97,116,105,118,101,45,112,108,97,121,101,114]));
    try { return __module[method](pointer); }
    finally { __module._jsfree(pointer); }
  }

  let liveDecode = false;
  function transformNAL(input) {
    const type = input[0] & 31;
    const tag = playerOperation('_CNTV_UpdatePlayer');
    if (tag !== null && tag !== undefined && tag !== 0) {
      globalThis.vmpTag = tag.toString(16).padStart(8, '0');
    }
    if (![1, 5, 7].includes(type)) return input;
    if (type === 7) {
      if (input.length < 3) throw failure('invalid-sps');
      liveDecode = liveDecode || [1, 2].includes(input[2] & 3);
    }
    if (!liveDecode) return input;

    // Reserve scratch headroom separately from the logical input length.
    // A 2 KiB tail allowed real IDR processing to overwrite the adjacent
    // player-name allocation; the larger bounded buffer preserves that ABI.
    const pointer = allocate(input, Math.max(65536, input.length));
    let playerPointer = 0;
    try {
      playerPointer = allocate(new Uint8Array([99,99,116,118,45,110,97,116,105,118,101,45,112,108,97,121,101,114]), 1);
      let addressLength = 0;
      if (globalThis.activeURL && !globalThis.signalUrlSend) {
        const address = new Uint8Array(Array.from(globalThis.activeURL).map(c=>c.charCodeAt(0)));
        addressLength = address.length;
        __module.HEAPU8.set(address, pointer + input.length);
      }
      const dispatch = globalThis.vmpTag;
      for (let index = 0; index < dispatch.length; index++) {
        if ('0123456'.includes(dispatch[index])) {
          __module['_CNTV_jsdecLive' + (7 - index)](
            playerPointer, pointer, input.length, addressLength);
        }
      }
      const length = __module._CNTV_jsdecLive8(
        playerPointer, pointer, input.length, addressLength);
      if (!Number.isInteger(length) || length <= 0 || length > input.length) {
        throw failure('runtime-media-length-invalid');
      }
      if (__module.HEAPU8[pointer] !== input[0]) {
        throw failure('runtime-media-header-changed');
      }
      if (type === 7) {
        // The official caller uses SPS to initialize the runtime, then clears
        // this marker in the original SPS before passing it to the decoder.
        const output = new Uint8Array(input);
        output[2] = 0;
        return output;
      }
      return new Uint8Array(__module.HEAPU8.subarray(pointer, pointer + length));
    } finally {
      __module._jsfree(pointer);
      if (playerPointer) __module._jsfree(playerPointer);
    }
  }


function __transform(values){return JSON.stringify(values.map(v=>{var b=atob(v),u=new Uint8Array(b.length);for(var i=0;i<b.length;i++)u[i]=b.charCodeAt(i);var out=transformNAL(u),s="";for(var x of out)s+=String.fromCharCode(x);return btoa(s);}));}