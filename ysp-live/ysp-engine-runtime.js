'use strict';

// Runtime and transport use only Node built-ins; protocol/WASM stays in ysp-engine.js.
const http = require('http');
const https = require('https');
const dns = require('dns');
const net = require('net');
const { Transform, pipeline } = require('stream');
const { performance } = require('perf_hooks');

const ALLOWED_SUFFIXES = Object.freeze([
  '.cctv.cn', '.cctv.com', '.cctvpic.com', '.citvc.com', '.yangshipin.cn',
  '.cntv.cn', '.cntv.com', '.myqcloud.com', '.qqlive.com', '.gtimg.cn',
  '.smtcdns.net', '.smtcdns.com', '.tcdnlive.com', '.alicdn.com', '.alikunlun.com',
  '.wscdns.com', '.chinanetcenter.com', '.bdydns.com', '.ksyungslb.com', '.ks-cdn.com'
]);
const UA = 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/148.0.0.0 Safari/537.36';
const MEDIA_HEADERS = Object.freeze({ 'User-Agent': UA, Referer: 'https://www.yangshipin.cn/', 'Accept-Encoding': 'identity' });
const clock = () => performance.now();

class EngineError extends Error {
  constructor(message, statusCode = 502) {
    super(message);
    this.name = 'EngineError';
    this.statusCode = statusCode;
  }
}

function envNumber(env, key, fallback, min, max) {
  const value = Number(env[key]);
  if (env[key] === undefined || env[key] === '') return fallback;
  if (!Number.isSafeInteger(value) || value < min || value > max) throw new Error(`invalid ${key}`);
  return value;
}

function configFromEnv(env = process.env) {
  return {
    host: env.YSP_ENGINE_HOST || env.HOST || '127.0.0.1',
    maxRequests: envNumber(env, 'YSP_ENGINE_MAX_REQUESTS', 64, 1, 1024),
    maxConnections: envNumber(env, 'YSP_ENGINE_MAX_CONNECTIONS', 128, 1, 2048),
    maxUpstream: envNumber(env, 'YSP_ENGINE_MAX_UPSTREAM', 24, 1, 256),
    maxQueue: envNumber(env, 'YSP_ENGINE_MAX_QUEUE', 64, 0, 1024),
    timeoutMs: envNumber(env, 'YSP_ENGINE_TIMEOUT_MS', 10000, 100, 120000),
    resolveTimeoutMs: envNumber(env, 'YSP_ENGINE_RESOLVE_TIMEOUT_MS', 25000, 100, 180000),
    segmentTimeoutMs: envNumber(env, 'YSP_ENGINE_SEGMENT_TIMEOUT_MS', 30000, 100, 180000),
    maxPlaylistBytes: envNumber(env, 'YSP_ENGINE_MAX_PLAYLIST_BYTES', 2 * 1024 * 1024, 1024, 16 * 1024 * 1024),
    maxSegmentBytes: envNumber(env, 'YSP_ENGINE_MAX_SEGMENT_BYTES', 35 * 1024 * 1024, 1024, 256 * 1024 * 1024),
    stallMs: envNumber(env, 'YSP_ENGINE_STALL_MS', 45000, 5000, 300000),
    shutdownMs: envNumber(env, 'YSP_ENGINE_SHUTDOWN_MS', 5000, 100, 30000)
  };
}

function publicIpv4(address) {
  const p = address.split('.').map(Number);
  if (p.length !== 4 || p.some(n => !Number.isInteger(n) || n < 0 || n > 255)) return false;
  const [a, b, c] = p;
  return !(a === 0 || a === 10 || a === 127 || a >= 224 ||
    (a === 100 && b >= 64 && b <= 127) || (a === 169 && b === 254) ||
    (a === 172 && b >= 16 && b <= 31) || (a === 192 && (b === 168 || b === 0 || (b === 88 && c === 99))) ||
    (a === 198 && (b === 18 || b === 19 || (b === 51 && c === 100))) || (a === 203 && b === 0 && c === 113));
}

function isPublicAddress(address) {
  if (net.isIP(address) === 4) return publicIpv4(address);
  if (net.isIP(address) !== 6 || address.includes('%')) return false;
  // URL canonicalizes IPv4-mapped IPv6 and compresses zero groups for us.
  const normalized = new URL(`http://[${address}]/`).hostname.slice(1, -1);
  const parts = normalized.split('::');
  const left = parts[0] ? parts[0].split(':') : [];
  const right = parts[1] ? parts[1].split(':') : [];
  const groups = parts.length === 2 ? [...left, ...Array(8 - left.length - right.length).fill('0'), ...right] : left;
  const words = groups.map(x => parseInt(x, 16));
  if (words.length !== 8 || words.some(x => !Number.isFinite(x))) return false;
  if (words.slice(0, 5).every(x => x === 0) && words[5] === 0xffff) {
    return publicIpv4(`${words[6] >> 8}.${words[6] & 255}.${words[7] >> 8}.${words[7] & 255}`);
  }
  return (words[0] & 0xe000) === 0x2000 &&
    !(words[0] === 0x2001 && (words[1] < 0x200 || words[1] === 0xdb8)) && words[0] !== 0x2002;
}

function validateTarget(target, options = {}) {
  let parsed;
  try { parsed = new URL(target); } catch { throw new EngineError('invalid upstream URL', 400); }
  const hostname = parsed.hostname.replace(/^\[|\]$/g, '').toLowerCase();
  if (!['http:', 'https:'].includes(parsed.protocol) || parsed.username || parsed.password || parsed.hash ||
      (!options.allowPrivate && parsed.port && parsed.port !== (parsed.protocol === 'https:' ? '443' : '80'))) {
    throw new EngineError('forbidden upstream URL', 403);
  }
  if (!options.allowPrivate && !ALLOWED_SUFFIXES.some(s => hostname === s.slice(1) || hostname.endsWith(s))) {
    throw new EngineError('forbidden upstream host', 403);
  }
  if (!options.allowPrivate && net.isIP(hostname) && !isPublicAddress(hostname)) throw new EngineError('forbidden upstream address', 403);
  return parsed;
}

class Limiter {
  constructor(limit, maxQueue) { this.limit = limit; this.maxQueue = maxQueue; this.active = 0; this.queue = []; this.closed = false; }
  acquire(deadline, signal) {
    if (this.closed) return Promise.reject(new EngineError('engine shutting down', 503));
    if (signal && signal.aborted) return Promise.reject(new EngineError('request cancelled', 499));
    if (clock() >= deadline) return Promise.reject(new EngineError('upstream deadline exceeded', 504));
    if (this.active < this.limit) { this.active++; return Promise.resolve(this.releaseOnce()); }
    if (this.queue.length >= this.maxQueue) return Promise.reject(new EngineError('upstream busy', 503));
    return new Promise((resolve, reject) => {
      const item = { resolve, reject, timer: null, abort: null, signal };
      const remove = error => {
        const idx = this.queue.indexOf(item);
        if (idx < 0) return;
        this.queue.splice(idx, 1); this.cleanup(item); reject(error);
      };
      item.timer = setTimeout(() => remove(new EngineError('upstream queue timeout', 504)), Math.max(1, deadline - clock()));
      item.abort = () => remove(new EngineError('request cancelled', 499));
      if (signal) signal.addEventListener('abort', item.abort, { once: true });
      this.queue.push(item);
    });
  }
  cleanup(item) { clearTimeout(item.timer); if (item.signal) item.signal.removeEventListener('abort', item.abort); }
  releaseOnce() {
    let done = false;
    return () => { if (done) return; done = true; this.active--; this.drain(); };
  }
  drain() {
    while (!this.closed && this.active < this.limit && this.queue.length) {
      const item = this.queue.shift(); this.cleanup(item); this.active++; item.resolve(this.releaseOnce());
    }
  }
  close() {
    this.closed = true;
    for (const item of this.queue.splice(0)) { this.cleanup(item); item.reject(new EngineError('engine shutting down', 503)); }
  }
}

function createTransport(options = {}) {
  const config = { ...configFromEnv({}), ...options };
  const limiter = new Limiter(config.maxUpstream, config.maxQueue);
  const agentOptions = { keepAlive: true, maxSockets: config.maxUpstream, maxTotalSockets: config.maxUpstream, maxFreeSockets: Math.min(8, config.maxUpstream), timeout: config.timeoutMs };
  const agents = { 'http:': new http.Agent(agentOptions), 'https:': new https.Agent(agentOptions) };
  const active = new Set();
  const pendingLookups = new Set();
  let closed = false;
  const lookup = options.lookup || dns.promises.lookup.bind(dns.promises);

  async function pinnedLookup(parsed, deadline, signal) {
    if (closed) throw new EngineError('engine shutting down', 503);
    const host = parsed.hostname.replace(/^\[|\]$/g, '');
    if (net.isIP(host)) return [{ address: host, family: net.isIP(host) }];
    let timer, abort, cancel;
    try {
      const addresses = await Promise.race([
        lookup(host, { all: true, verbatim: true }),
        new Promise((_, reject) => {
          timer = setTimeout(() => reject(new EngineError('DNS deadline exceeded', 504)), Math.max(1, deadline - clock()));
          cancel = () => reject(new EngineError('engine shutting down', 503));
          pendingLookups.add(cancel);
          abort = () => reject(new EngineError('request cancelled', 499));
          if (signal) signal.addEventListener('abort', abort, { once: true });
        })
      ]);
      if (!addresses.length || (!config.allowPrivate && addresses.some(x => !isPublicAddress(x.address)))) throw new EngineError('forbidden DNS address', 403);
      return addresses;
    } finally { clearTimeout(timer); pendingLookups.delete(cancel); if (signal && abort) signal.removeEventListener('abort', abort); }
  }

  async function open(target, requestOptions = {}, redirects = 0) {
    const deadline = requestOptions.deadline || clock() + config.timeoutMs;
    const parsed = validateTarget(target, config);
    const release = await limiter.acquire(deadline, requestOptions.signal);
    let addresses;
    try { addresses = await pinnedLookup(parsed, deadline, requestOptions.signal); } catch (e) { release(); throw e; }
    if (clock() >= deadline || (requestOptions.signal && requestOptions.signal.aborted)) {
      release(); throw new EngineError('upstream deadline exceeded', 504);
    }
    const result = await new Promise((resolve, reject) => {
      let incoming, timer;
      let finished = false;
      const controller = requestOptions.signal;
      const done = () => {
        if (finished) return;
        finished = true; clearTimeout(timer); release(); active.delete(req);
        if (controller) controller.removeEventListener('abort', abort);
      };
      const abort = () => req.destroy(new EngineError('request cancelled', 499));
      const client = parsed.protocol === 'https:' ? https : http;
      const req = client.request(parsed, {
        method: requestOptions.method || 'GET', headers: { 'Accept-Encoding': 'identity', ...requestOptions.headers },
        agent: agents[parsed.protocol],
        lookup: (_host, lookupOptions, callback) => {
          if (lookupOptions && lookupOptions.all) callback(null, addresses);
          else callback(null, addresses[0].address, addresses[0].family);
        },
        maxHeaderSize: 16384
      }, res => {
        incoming = res;
        res.once('end', done); res.once('close', done); res.once('error', done);
        resolve({ response: res, request: req, url: parsed.toString(), deadline });
      });
      active.add(req);
      timer = setTimeout(() => req.destroy(new EngineError('upstream deadline exceeded', 504)), Math.max(1, deadline - clock()));
      req.setTimeout(Math.min(config.timeoutMs, Math.max(1, deadline - clock())), () => req.destroy(new EngineError('upstream idle timeout', 504)));
      req.once('error', error => { done(); if (incoming) incoming.destroy(error); reject(error); });
      if (controller) controller.addEventListener('abort', abort, { once: true });
      if (requestOptions.body !== undefined) req.write(requestOptions.body);
      req.end();
    });
    const location = result.response.headers.location;
    if ([301, 302, 303, 307, 308].includes(result.response.statusCode) && location) {
      // Hand the limiter slot back before the next hop, including a zero-size queue.
      await new Promise(resolveClose => { result.response.once('close', resolveClose); result.response.destroy(); });
      if (redirects >= 3) throw new EngineError('too many upstream redirects');
      const next = new URL(location, parsed).toString();
      validateTarget(next, config);
      const nextOptions = { ...requestOptions, deadline };
      if (new URL(next).origin !== parsed.origin) {
        if ((requestOptions.method || 'GET') !== 'GET' && requestOptions.method !== 'HEAD') throw new EngineError('cross-origin POST redirect refused');
        nextOptions.headers = Object.fromEntries(Object.entries(requestOptions.headers || {}).filter(([name]) => !['authorization', 'cookie', 'proxy-authorization'].includes(name.toLowerCase())));
      }
      if ((requestOptions.method || 'GET') === 'POST' && [301, 302, 303].includes(result.response.statusCode)) throw new EngineError('ambiguous POST redirect refused');
      return open(next, nextOptions, redirects + 1);
    }
    return result;
  }

  async function request(target, requestOptions = {}) {
    const opened = await open(target, requestOptions);
    const { response } = opened;
    const maxBytes = requestOptions.maxBytes || config.maxPlaylistBytes;
    const declared = response.headers['content-length'];
    if (declared && (!/^\d+$/.test(declared) || Number(declared) > maxBytes)) {
      response.destroy(); throw new EngineError('upstream response exceeds size limit');
    }
    const chunks = [];
    let size = 0;
    try {
      for await (const chunk of response) {
        size += chunk.length;
        if (size > maxBytes) throw new EngineError('upstream response exceeds size limit');
        chunks.push(chunk);
      }
    } catch (error) { response.destroy(); throw error; }
    return { statusCode: response.statusCode, headers: response.headers, data: Buffer.concat(chunks, size).toString('utf8'), url: opened.url };
  }

  return {
    open, request,
    get: (target, headers = {}, opts = {}) => request(target, { ...opts, headers }),
    post: (target, headers, body, opts = {}) => request(target, { ...opts, method: 'POST', headers: { ...headers, 'Content-Length': Buffer.byteLength(body) }, body }),
    stats: () => ({ active: limiter.active, queued: limiter.queue.length }),
    close() { closed = true; limiter.close(); for (const cancel of pendingLookups) cancel(); for (const req of active) req.destroy(new EngineError('engine shutting down', 503)); for (const agent of Object.values(agents)) agent.destroy(); }
  };
}

function rewritePlaylist(text, upstreamUrl, localBase, options = {}) {
  if (!/^\s*#EXTM3U(?:\s|$)/.test(text)) throw new EngineError('invalid upstream playlist');
  const rewrite = value => {
    const target = new URL(value, upstreamUrl).toString();
    validateTarget(target, options);
    return new URL('/segment?url=' + encodeURIComponent(target), localBase).toString();
  };
  return text.split(/\r?\n/).map(line => {
    const trimmed = line.trim();
    if (!trimmed) return '';
    if (!trimmed.startsWith('#')) return rewrite(trimmed);
    return trimmed.replace(/\bURI=("([^"]*)"|([^,\s]*))/g, (_match, _raw, quoted, unquoted) => 'URI="' + rewrite(quoted === undefined ? unquoted : quoted) + '"');
  }).join('\n').replace(/\n*$/, '\n');
}

function playlistFingerprint(text) {
  // Keep query values that identify media (e.g. sequence=42); ignore only known
  // expiring credentials so signature renewal cannot hide a frozen window.
  const credentials = /^(?:sig|signature|sign|token|vkey|auth_key|authkey|wssecret|wstime|txsecret|txtime|expire|expires)$/i;
  return text.split(/\r?\n/).map(line => line.trim())
    .filter(line => /^#EXT-X-(?:MEDIA-SEQUENCE|PROGRAM-DATE-TIME)/.test(line) || (line && !line.startsWith('#')))
    .map(line => {
      if (line.startsWith('#')) return line;
      const parsed = new URL(line, 'https://fingerprint.invalid/');
      for (const key of [...parsed.searchParams.keys()]) if (credentials.test(key)) parsed.searchParams.delete(key);
      return parsed.toString();
    }).join('\n');
}

function createEngine(options) {
  if (!options || typeof options.resolvePlaylist !== 'function') throw new TypeError('resolvePlaylist is required');
  const config = { ...configFromEnv({}), ...options };
  const transport = options.transport || createTransport(config);
  const channels = options.channels || {};
  const aliases = options.aliases || {};
  const states = new Map();
  const sockets = new Set();
  const resolveControllers = new Set();
  let activeRequests = 0, shuttingDown = false, closePromise;
  const now = options.clock || clock;
  let server;
  const base = () => {
    if (config.publicBase) return config.publicBase;
    const addr = server.address();
    return 'http://127.0.0.1:' + (addr && typeof addr === 'object' ? addr.port : (config.port || 8787));
  };

  async function resolve(slug) {
    const canonical = aliases[slug] || slug;
    if (!Object.prototype.hasOwnProperty.call(channels, canonical)) return null;
    let state = states.get(canonical);
    if (!state) { state = { failures: 0, retryAt: 0, inflight: null, cache: null, progressedAt: 0, error: null }; states.set(canonical, state); }
    if (state.cache && now() - state.cache.fetchedAt < state.cache.ttl) return state.cache.playlist;
    if (state.inflight) return state.inflight;
    if (state.retryAt > now()) throw new EngineError('channel temporarily unavailable', 503);
    state.inflight = (async () => {
      const controller = new AbortController();
      resolveControllers.add(controller);
      const timer = setTimeout(() => controller.abort(), config.resolveTimeoutMs);
      try {
        const data = await Promise.race([
          Promise.resolve().then(() => options.resolvePlaylist(canonical, { transport, signal: controller.signal, deadline: clock() + config.resolveTimeoutMs })),
          new Promise((_, reject) => controller.signal.addEventListener('abort', () => reject(new EngineError('channel resolve deadline exceeded', 504)), { once: true }))
        ]);
        if (!data || typeof data.text !== 'string' || Buffer.byteLength(data.text) > config.maxPlaylistBytes) throw new EngineError('invalid upstream playlist');
        const playlist = rewritePlaylist(data.text, data.url, base(), config);
        const fingerprint = playlistFingerprint(data.text);
        if (!fingerprint || !data.text.split(/\r?\n/).some(line => line.trim() && !line.startsWith('#'))) throw new EngineError('empty upstream playlist');
        const masterPlaylist = /^#EXT-X-STREAM-INF:/m.test(data.text);
        if (masterPlaylist || !state.cache || fingerprint !== state.cache.fingerprint) state.progressedAt = now();
        else if (now() - state.progressedAt > config.stallMs) throw new EngineError('upstream media stalled', 503);
        const duration = Number((data.text.match(/^#EXT-X-TARGETDURATION:(\d+(?:\.\d+)?)/m) || [])[1]) || 4;
        state.cache = { playlist, fingerprint, fetchedAt: now(), ttl: Math.max(1000, Math.min(3000, duration * 500)) };
        state.failures = 0; state.retryAt = 0; state.error = null;
        return playlist;
      } catch (error) {
        state.failures++;
        state.retryAt = now() + Math.min(30000, 1000 * 2 ** Math.min(state.failures - 1, 5));
        state.error = error instanceof EngineError ? error.message : 'upstream request failed';
        throw error;
      } finally { clearTimeout(timer); resolveControllers.delete(controller); state.inflight = null; }
    })();
    return state.inflight;
  }

  const send = (req, res, status, body, headers = {}) => {
    if (res.destroyed) return;
    const data = Buffer.from(body);
    res.writeHead(status, { 'Content-Type': 'text/plain; charset=utf-8', 'Content-Length': data.length, ...headers });
    res.end(req.method === 'HEAD' ? undefined : data);
  };

  async function segment(req, res, parsed, signal) {
    const target = parsed.searchParams.get('url');
    if (!target) throw new EngineError('missing url', 400);
    validateTarget(target, config);
    const range = req.headers.range;
    if (range && (range.length > 100 || !/^bytes=(?:\d+-\d*|-\d+)$/.test(range))) throw new EngineError('invalid range', 416);
    const headers = { ...MEDIA_HEADERS };
    if (range) headers.Range = range;
    if (req.headers['if-range']) headers['If-Range'] = req.headers['if-range'];
    const opened = await transport.open(target, { method: req.method, headers, deadline: clock() + config.segmentTimeoutMs, signal });
    const upstream = opened.response;
    const cancel = () => { upstream.destroy(); opened.request.destroy(); };
    res.once('close', cancel);
    const outHeaders = { 'Cache-Control': 'no-store' };
    for (const name of ['content-type', 'content-length', 'content-range', 'accept-ranges', 'etag', 'last-modified']) {
      if (upstream.headers[name] !== undefined) outHeaders[name] = upstream.headers[name];
    }
    const status = upstream.statusCode || 502;
    if (status >= 400) {
      upstream.destroy(); res.removeListener('close', cancel);
      // Preserve 416 and its Content-Range so players can recover from a stale byte range.
      if (status !== 416) delete outHeaders['content-range'];
      delete outHeaders['content-length']; delete outHeaders['content-type'];
      send(req, res, status, `upstream returned ${status}\n`, outHeaders);
      return;
    }
    if (status !== 200 && status !== 206 && status !== 304) {
      upstream.destroy(); res.removeListener('close', cancel); throw new EngineError('unexpected upstream status');
    }
    const declared = upstream.headers['content-length'];
    const playlist = /(?:mpegurl|m3u8)/i.test(upstream.headers['content-type'] || '') || /\.m3u8$/i.test(new URL(opened.url).pathname);
    const maxBytes = playlist ? config.maxPlaylistBytes : config.maxSegmentBytes;
    if (declared && (!/^\d+$/.test(declared) || Number(declared) > maxBytes)) {
      upstream.destroy(); res.removeListener('close', cancel); throw new EngineError('upstream response exceeds size limit');
    }
    if (req.method === 'HEAD' || status === 304) {
      if (playlist) delete outHeaders['content-length'];
      res.writeHead(status, outHeaders); res.end(); upstream.resume(); return;
    }
    if (playlist && !range) {
      let size = 0; const chunks = [];
      try {
        for await (const chunk of upstream) {
          size += chunk.length;
          if (size > maxBytes) throw new EngineError('upstream playlist exceeds size limit');
          chunks.push(chunk);
        }
        const rewritten = rewritePlaylist(Buffer.concat(chunks, size).toString('utf8'), opened.url, base(), config);
        res.removeListener('close', cancel);
        send(req, res, status, rewritten, { 'Content-Type': 'application/vnd.apple.mpegurl; charset=utf-8', 'Cache-Control': 'no-store' });
      } catch (error) { upstream.destroy(); throw error; }
      return;
    }
    let bytes = 0;
    const bound = new Transform({ transform(chunk, _encoding, done) {
      bytes += chunk.length;
      if (bytes > maxBytes) done(new EngineError('upstream segment exceeds size limit'));
      else done(null, chunk);
    } });
    res.writeHead(status, { 'Content-Type': 'video/mp2t', ...outHeaders });
    await new Promise((resolve, reject) => pipeline(upstream, bound, res, error => {
      res.removeListener('close', cancel);
      if (error) { opened.request.destroy(); reject(error); } else resolve();
    }));
  }

  server = http.createServer({ maxHeaderSize: 16384, highWaterMark: 64 * 1024 }, async (req, res) => {
    res.setHeader('Access-Control-Allow-Origin', '*');
    res.setHeader('Cache-Control', 'no-store');
    let parsed;
    try { parsed = new URL(req.url, 'http://127.0.0.1'); } catch { send(req, res, 400, 'invalid request\n'); return; }
    if (!['GET', 'HEAD'].includes(req.method)) { send(req, res, 405, 'method not allowed\n', { Allow: 'GET, HEAD' }); return; }
    if (parsed.pathname === '/livez') { send(req, res, shuttingDown ? 503 : 200, JSON.stringify({ alive: !shuttingDown }), { 'Content-Type': 'application/json' }); return; }
    if (parsed.pathname === '/health') {
      const ready = [...states.values()].filter(s => s.cache && !s.error && now() - s.progressedAt <= config.stallMs && now() - s.cache.fetchedAt <= config.stallMs).length;
      const detail = { status: shuttingDown ? 'stopping' : ready ? 'ok' : 'not_ready', ready: !shuttingDown && ready > 0, version: options.version || '9.5.0', engine: 'ysp-engine', channels: states.size, readyChannels: ready, activeRequests, upstream: transport.stats() };
      send(req, res, detail.ready ? 200 : 503, JSON.stringify(detail), { 'Content-Type': 'application/json' }); return;
    }
    if (shuttingDown || activeRequests >= config.maxRequests) { send(req, res, 503, 'engine busy\n', { 'Retry-After': '1' }); return; }
    activeRequests++;
    let finished = false;
    const controller = new AbortController();
    const finish = () => { if (finished) return; finished = true; activeRequests--; clearTimeout(clientTimer); controller.abort(); };
    const clientTimer = setTimeout(() => res.destroy(), Math.max(config.resolveTimeoutMs, config.segmentTimeoutMs) + 1000);
    res.once('finish', finish); res.once('close', finish);
    res.setTimeout(Math.max(config.timeoutMs, config.resolveTimeoutMs), () => res.destroy());
    try {
      if (parsed.pathname === '/all.m3u') {
        const lines = ['#EXTM3U'];
        for (const [slug, meta] of Object.entries(channels)) {
          lines.push(`#EXTINF:-1 tvg-id="${slug}" tvg-name="${meta.name}" group-title="央视频",${meta.name}`);
          lines.push(new URL('/live/' + slug + '.m3u8', base()).toString());
        }
        send(req, res, 200, lines.join('\n') + '\n', { 'Content-Type': 'application/vnd.apple.mpegurl; charset=utf-8' });
      } else if (parsed.pathname === '/segment') await segment(req, res, parsed, controller.signal);
      else {
        const match = parsed.pathname.match(/^\/(?:live\/)?([\w-]+)\.m3u8$/);
        if (!match) { send(req, res, 404, 'not found\n'); return; }
        const playlist = await resolve(match[1]);
        if (!playlist) send(req, res, 404, 'unknown channel\n');
        else send(req, res, 200, playlist, { 'Content-Type': 'application/vnd.apple.mpegurl; charset=utf-8' });
      }
    } catch (error) {
      if (res.destroyed) return;
      if (res.headersSent) res.destroy();
      else send(req, res, error.statusCode >= 400 && error.statusCode <= 599 ? error.statusCode : 502,
        `${error instanceof EngineError ? error.message : 'upstream request failed'}\n`, error.statusCode === 503 ? { 'Retry-After': '1' } : {});
    }
  });
  server.maxConnections = config.maxConnections;
  server.maxRequestsPerSocket = 1000;
  server.headersTimeout = 10000;
  server.requestTimeout = 15000;
  server.keepAliveTimeout = 5000;
  server.on('connection', socket => { sockets.add(socket); socket.once('close', () => sockets.delete(socket)); });
  server.on('clientError', (_error, socket) => { if (socket.writable) socket.end('HTTP/1.1 400 Bad Request\r\nConnection: close\r\nContent-Length: 0\r\n\r\n'); });

  return {
    server, resolve, transport,
    listen(port = config.port || 8787, host = config.host) {
      return new Promise((resolveListen, reject) => {
        const onError = error => { server.removeListener('listening', onListen); reject(error); };
        const onListen = () => { server.removeListener('error', onError); resolveListen(server.address()); };
        server.once('error', onError); server.once('listening', onListen); server.listen(port, host);
      });
    },
    close() {
      if (closePromise) return closePromise;
      shuttingDown = true;
      for (const controller of resolveControllers) controller.abort();
      closePromise = new Promise(resolveClose => {
        const timer = setTimeout(() => { for (const socket of sockets) socket.destroy(); transport.close(); resolveClose(); }, config.shutdownMs);
        server.close(() => { clearTimeout(timer); transport.close(); resolveClose(); });
        if (server.closeIdleConnections) server.closeIdleConnections();
      });
      return closePromise;
    }
  };
}

module.exports = { ALLOWED_SUFFIXES, MEDIA_HEADERS, EngineError, Limiter, configFromEnv, isPublicAddress, validateTarget, createTransport, rewritePlaylist, playlistFingerprint, createEngine, clock };
