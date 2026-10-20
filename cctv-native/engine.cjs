#!/usr/bin/env node
'use strict';

// Host the unchanged public CCTV player runtime. This file implements its
// browser API dependencies; it does not patch the runtime or its WebAssembly.
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { createRequire } = require('node:module');
const { pathToFileURL } = require('node:url');

const MAX_MESSAGE = 24 * 1024 * 1024;
const MAX_NAL = 4 * 1024 * 1024;
const MAX_NALS = 16384;
const PROCESS_TIMEOUT = 15000;
const INIT_TIMEOUT = 20000;
const SOURCE = 'https://tv.cctv.com/live/cctv2/m/index.shtml';
const PLAYER_NAME = Buffer.from('cctv-native-player');

function option(name) {
  const index = process.argv.indexOf(name);
  if (index < 0 || !process.argv[index + 1]) throw failure('missing-' + name.slice(2));
  return path.resolve(process.argv[index + 1]);
}

function failure(code) {
  const error = new Error(code);
  error.code = code;
  return error;
}

function send(value) {
  process.stdout.write(JSON.stringify(value) + '\n');
}

function report(code) {
  process.stderr.write('[cctv-native] ' + code + '\n');
}

// The SDK's console/print output must never enter the NDJSON stream. Avoid
// forwarding SDK messages because future versions might log signed addresses.
const silent = () => {};
for (const name of ['log', 'debug', 'info', 'warn', 'error']) console[name] = silent;

function proxyFor(target) {
  const url = new URL(target);
  const noProxy = process.env.NO_PROXY || process.env.no_proxy || '';
  const port = url.port || (url.protocol === 'https:' ? '443' : '80');
  for (let item of noProxy.split(',')) {
    item = item.trim().toLowerCase();
    if (!item) continue;
    if (item === '*') return null;
    const match = /^(.*?)(?::(\d+))?$/.exec(item);
    const host = match[1].replace(/^\*?\./, '');
    if (match[2] && match[2] !== port) continue;
    if (url.hostname === host || url.hostname.endsWith('.' + host)) return null;
  }
  if (url.protocol === 'https:') {
    return process.env.HTTPS_PROXY || process.env.https_proxy ||
      process.env.HTTP_PROXY || process.env.http_proxy || null;
  }
  return process.env.HTTP_PROXY || process.env.http_proxy || null;
}

async function main() {
  const runtime = option('--runtime');
  const modules = option('--modules');
  if (!fs.statSync(runtime).isFile() || !fs.statSync(modules).isDirectory()) {
    throw failure('runtime-files-missing');
  }
  const dependencies = createRequire(path.join(modules, '..', 'package.json'));
  dependencies('fake-indexeddb/auto');
  const NativeXHR = dependencies('xhr2');
  // The pinned proxy agents are ESM. Dynamic import also works on the early
  // Node 20/22 releases that cannot synchronously require an ES module.
  const [{ HttpsProxyAgent }, { HttpProxyAgent }] = await Promise.all([
    import(pathToFileURL(dependencies.resolve('https-proxy-agent')).href),
    import(pathToFileURL(dependencies.resolve('http-proxy-agent')).href)
  ]);

  let configurationSucceeded = false;
  let initReturned = false;
  let initialized = false;
  let resolveNetwork;
  let rejectNetwork;
  const pending = new Set();
  const networkReady = new Promise((resolve, reject) => {
    resolveNetwork = resolve;
    rejectNetwork = reject;
  });
  // Attach the rejection handler immediately; network failure can precede
  // onRuntimeInitialized resolving.
  networkReady.catch(silent);
  function checkNetwork() {
    if (initReturned && configurationSucceeded && pending.size === 0) resolveNetwork();
  }

  class PlayerXHR extends NativeXHR {
    open(method, address, ...args) {
      let target;
      try {
        target = new URL(address, SOURCE);
      } catch (_) {
        throw failure('runtime-invalid-network-address');
      }
      if (!['https:', 'http:'].includes(target.protocol)) {
        throw failure('runtime-unsupported-network-protocol');
      }
      const proxy = proxyFor(target.href);
      if (proxy) {
        this.nodejsSet(target.protocol === 'https:' ?
          { httpsAgent: new HttpsProxyAgent(proxy) } :
          { httpAgent: new HttpProxyAgent(proxy) });
      }
      this._configurationRequest = target.origin === 'https://tv.cctv.com' &&
        target.pathname === '/Library/H5player.json';
      const result = super.open(method, target.href, ...args);
      this.addEventListener('loadend', () => {
        pending.delete(this);
        if (this.status < 200 || this.status >= 300) {
          rejectNetwork(failure('runtime-network-failed'));
          return;
        }
        if (this._configurationRequest) configurationSucceeded = true;
        // loadend follows the SDK's load callback. Yield once more so its
        // IndexedDB callbacks can complete before processing media.
        setImmediate(checkNetwork);
      });
      return result;
    }

    send(data) {
      pending.add(this);
      try {
        return super.send(data);
      } catch (error) {
        pending.delete(this);
        rejectNetwork(failure('runtime-network-failed'));
        throw error;
      }
    }
  }

  global.self = global;
  global.origin = 'https://tv.cctv.com';
  global.location = new URL(SOURCE);
  global.XMLHttpRequest = PlayerXHR;
  global.activeURL = global.origin;
  global.signalUrlSend = false;
  global.vmpTag = '';

  const factory = require(runtime);
  if (typeof factory !== 'function') throw failure('runtime-invalid-factory');
  let module;
  let runtimeTimer;

  function allocate(bytes, extra = 2048) {
    const pointer = module._jsmalloc(bytes.length + extra);
    if (!Number.isInteger(pointer) || pointer <= 0) throw failure('runtime-allocation-failed');
    module.HEAPU8.fill(0, pointer, pointer + bytes.length + extra);
    module.HEAPU8.set(bytes, pointer);
    return pointer;
  }

  // Match the official caller's ownership: each API operation gets a fresh
  // player-name buffer, and only the dispatcher chain shares that buffer.
  function playerOperation(method) {
    // moduleActive reserves its 2048-byte workspace; moduleDecData below
    // separately uses only the null-terminated player-name buffer.
    const pointer = allocate(PLAYER_NAME);
    try { return module[method](pointer); }
    finally { module._jsfree(pointer); }
  }

  const runtimeReady = new Promise((resolve, reject) => {
    runtimeTimer = setTimeout(() => reject(failure('runtime-initialization-timeout')), INIT_TIMEOUT);
    module = factory({
      print: silent,
      printErr: silent,
      onAbort: () => reject(failure('runtime-aborted')),
      onRuntimeInitialized: () => setImmediate(() => {
        try {
          global.window = global;
          global.parent = global;
          global.top = global;
          global.document = { URL: SOURCE, location: global.location };
          Object.defineProperty(global, 'navigator', {
            value: {
              userAgent: 'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 ' +
                'Chrome/130.0.0.0 Mobile Safari/537.36',
              platform: 'Linux armv8l', language: 'zh-CN'
            }, configurable: true
          });
          global.CNTVH5PlayerModule = module;
          playerOperation('_CNTV_InitPlayer');
          initReturned = true;
          checkNetwork();
          resolve();
        } catch (_) {
          reject(failure('runtime-player-initialization-failed'));
        }
      })
    });
  });
  try {
    await Promise.race([
      Promise.all([runtimeReady, networkReady]),
      new Promise((_, reject) => {
        const timer = setTimeout(() => reject(failure('runtime-network-timeout')), INIT_TIMEOUT);
        timer.unref();
      })
    ]);
  } finally {
    clearTimeout(runtimeTimer);
  }
  initialized = true;

  function cleanUp() {
    if (initialized) {
      initialized = false;
      try { playerOperation('_CNTV_UnInitPlayer'); } catch (_) {}
    }
  }
  process.once('exit', cleanUp);
  for (const signal of ['SIGINT', 'SIGTERM']) {
    process.once(signal, () => process.exit(0));
  }

  let liveDecode = false;
  function transformNAL(input) {
    const type = input[0] & 31;
    const tag = playerOperation('_CNTV_UpdatePlayer');
    if (tag !== null && tag !== undefined && tag !== 0) {
      global.vmpTag = tag.toString(16).padStart(8, '0');
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
      playerPointer = allocate(PLAYER_NAME, 1);
      let addressLength = 0;
      if (global.activeURL && !global.signalUrlSend) {
        const address = Buffer.from(global.activeURL);
        addressLength = address.length;
        module.HEAPU8.set(address, pointer + input.length);
      }
      const dispatch = global.vmpTag;
      for (let index = 0; index < dispatch.length; index++) {
        if ('0123456'.includes(dispatch[index])) {
          module['_CNTV_jsdecLive' + (7 - index)](
            playerPointer, pointer, input.length, addressLength);
        }
      }
      const length = module._CNTV_jsdecLive8(
        playerPointer, pointer, input.length, addressLength);
      if (!Number.isInteger(length) || length <= 0 || length > input.length) {
        throw failure('runtime-media-length-invalid');
      }
      if (module.HEAPU8[pointer] !== input[0]) {
        throw failure('runtime-media-header-changed');
      }
      if (type === 7) {
        // The official caller uses SPS to initialize the runtime, then clears
        // this marker in the original SPS before passing it to the decoder.
        const output = Buffer.from(input);
        output[2] = 0;
        return output;
      }
      return Buffer.from(module.HEAPU8.subarray(pointer, pointer + length));
    } finally {
      module._jsfree(pointer);
      if (playerPointer) module._jsfree(playerPointer);
    }
  }

  function transformMessage(request) {
    if (!request || typeof request !== 'object' || !Array.isArray(request.nals) ||
        request.nals.length > MAX_NALS) throw failure('invalid-request');
    const nals = [];
    let total = 0;
    for (const value of request.nals) {
      if (typeof value !== 'string' || value.length > Math.ceil(MAX_NAL / 3) * 4 ||
          value.length % 4 !== 0) {
        throw failure('invalid-nal-base64');
      }
      const padding = value.endsWith('==') ? 2 : value.endsWith('=') ? 1 : 0;
      // Do not use a repeated four-character regex group here: V8's regexp
      // stack can overflow on a valid multi-megabyte NAL.
      if (/[^A-Za-z0-9+/]/.test(value.slice(0, value.length - padding))) {
        throw failure('invalid-nal-base64');
      }
      const input = Buffer.from(value, 'base64');
      if (!input.length || input.length > MAX_NAL) throw failure('invalid-nal-size');
      if (input.toString('base64') !== value) throw failure('invalid-nal-base64');
      total += input.length;
      if (total > MAX_MESSAGE) throw failure('media-message-too-large');
      nals.push(input);
    }
    let shortened = 0;
    const output = nals.map(nal => {
      const transformed = transformNAL(nal);
      if (transformed.length < nal.length) shortened++;
      return transformed.toString('base64');
    });
    return { id: request.id ?? null, ok: true,
      nals: output, shortened_nals: shortened };
  }

  function consume(line) {
    let request;
    try {
      request = JSON.parse(line);
      const result = vm.runInNewContext('run()', {
        run: () => transformMessage(request)
      }, { timeout: PROCESS_TIMEOUT });
      send(result);
    } catch (error) {
      const code = error.code === 'ERR_SCRIPT_EXECUTION_TIMEOUT' ?
        'runtime-processing-timeout' : (error.code || 'runtime-processing-failed');
      send({ id: request?.id ?? null, ok: false, error: code });
      // A timeout or an SDK failure may leave its persistent player state
      // incomplete. Let the Python host restart a fresh engine.
      if (code.startsWith('runtime-')) finish(1);
    }
  }

  function finish(code) {
    process.stdin.pause();
    // Allow a complete large NDJSON response to reach the pipe before EOF.
    process.stdout.write('', () => process.exit(code));
  }

  send({ ready: true });
  let pendingInput = Buffer.alloc(0);
  process.stdin.on('data', chunk => {
    pendingInput = Buffer.concat([pendingInput, chunk]);
    let newline;
    while ((newline = pendingInput.indexOf(10)) !== -1) {
      if (newline > MAX_MESSAGE) {
        report('message-too-large');
        process.exit(1);
      }
      const line = pendingInput.subarray(0, newline).toString('utf8').trim();
      pendingInput = pendingInput.subarray(newline + 1);
      if (line) consume(line);
    }
    if (pendingInput.length > MAX_MESSAGE) {
      report('message-too-large');
      process.exit(1);
    }
  });
  process.stdin.on('end', () => {
    if (pendingInput.length) consume(pendingInput.toString('utf8'));
    finish(0);
  });
  process.stdin.on('error', () => process.exit(1));
  process.stdin.resume();
}

main().catch(error => {
  report(error.code || 'engine-initialization-failed');
  process.exit(1);
});
