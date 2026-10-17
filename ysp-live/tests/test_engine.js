'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const http = require('node:http');
const { once } = require('node:events');
const { createEngine, createTransport, EngineError, Limiter, validateTarget, isPublicAddress, rewritePlaylist, clock } = require('../ysp-engine-runtime');

async function upstream(t, handler) {
  const server = http.createServer(handler);
  server.listen(0, '127.0.0.1'); await once(server, 'listening');
  t.after(async () => { server.closeAllConnections(); await new Promise(resolve => server.close(resolve)); });
  return `http://127.0.0.1:${server.address().port}`;
}
async function engine(t, options = {}) {
  const app = createEngine({ channels: { demo: { name: 'Demo' } }, aliases: { alias: 'demo' }, allowPrivate: true,
    shutdownMs: 100, resolvePlaylist: async () => ({ text: '#EXTM3U\n#EXT-X-TARGETDURATION:4\n#EXT-X-MEDIA-SEQUENCE:1\n#EXTINF:4,\nhttps://media.cctv.com/1.ts\n', url: 'https://media.cctv.com/live.m3u8' }), ...options });
  await app.listen(0, '127.0.0.1');
  t.after(() => app.close());
  return { app, base: `http://127.0.0.1:${app.server.address().port}` };
}
function get(target, options = {}) {
  return new Promise((resolve, reject) => {
    const req = http.request(target, options, res => {
      const chunks = []; res.on('data', chunk => chunks.push(chunk));
      res.on('end', () => resolve({ status: res.statusCode, headers: res.headers, body: Buffer.concat(chunks).toString() }));
      res.on('error', reject);
    });
    req.on('error', reject); req.end();
  });
}
const delay = ms => new Promise(resolve => setTimeout(resolve, ms));

test('requiring protocol module has no listener or process handler side effects', () => {
  const before = process.listenerCount('SIGTERM');
  const exported = require('../ysp-engine');
  assert.equal(typeof exported.buildEngine, 'function');
  assert.ok(exported.CHANNELS.cctv1);
  assert.equal(process.listenerCount('SIGTERM'), before);
});

test('production targets reject private literals, credentials, invalid schemes, ports and suffix confusion', () => {
  for (const target of ['http://127.0.0.1/a.ts', 'http://[::1]/a.ts', 'file:///etc/a.ts', 'https://user:pass@media.cctv.com/a.ts', 'https://media.cctv.com:8443/a.ts', 'https://media.cctv.com.attacker.test/a.ts']) {
    assert.throws(() => validateTarget(target), error => error.statusCode === 403);
  }
  assert.equal(validateTarget('https://media.cctv.com/a.ts').hostname, 'media.cctv.com');
  for (const address of ['127.0.0.1', '10.1.2.3', '100.64.0.1', '169.254.169.254', '172.31.1.1', '192.168.1.1', '198.18.0.1', '203.0.113.1', '::1', 'fc00::1', 'fe80::1', '::ffff:127.0.0.1', '2001:db8::1', '2002:7f00:1::']) assert.equal(isPublicAddress(address), false, address);
  for (const address of ['1.1.1.1', '8.8.8.8', '2606:4700:4700::1111', '2001:4860:4860::8888']) assert.equal(isPublicAddress(address), true, address);
});

test('DNS validation rejects private and mixed answers before opening sockets', async t => {
  for (const addresses of [[{ address: '127.0.0.1', family: 4 }], [{ address: '8.8.8.8', family: 4 }, { address: '::1', family: 6 }]]) {
    const transport = createTransport({ lookup: async () => addresses }); t.after(() => transport.close());
    await assert.rejects(transport.get('https://media.cctv.com/live.m3u8'), error => error.statusCode === 403);
    assert.deepEqual(transport.stats(), { active: 0, queued: 0 });
  }
});

test('redirects use final URL and reject unsafe protocol on each hop', async t => {
  const base = await upstream(t, (req, res) => {
    if (req.url === '/start') { res.writeHead(302, { Location: '/new/list.m3u8' }); res.end(); }
    else if (req.url === '/bad') { res.writeHead(302, { Location: 'file:///etc/passwd' }); res.end(); }
    else if (req.url === '/loop') { res.writeHead(302, { Location: '/loop' }); res.end(); }
    else { res.end('#EXTM3U\nsegment.ts\n'); }
  });
  const transport = createTransport({ allowPrivate: true }); t.after(() => transport.close());
  assert.equal((await transport.get(base + '/start')).url, base + '/new/list.m3u8');
  await assert.rejects(transport.get(base + '/bad'), error => error.statusCode === 403);
  await assert.rejects(transport.get(base + '/loop'), /too many upstream redirects/);
});

test('bounded control reads reject Content-Length and chunked overflow', async t => {
  const base = await upstream(t, (req, res) => {
    if (req.url === '/length') { res.writeHead(200, { 'Content-Length': 10000 }); res.end('x'.repeat(10000)); }
    else { res.write('x'.repeat(700)); res.end('y'.repeat(700)); }
  });
  const transport = createTransport({ allowPrivate: true }); t.after(() => transport.close());
  for (const path of ['/length', '/chunked']) await assert.rejects(transport.get(base + path, {}, { maxBytes: 1024 }), /size limit/);
});

test('total deadline stops a trickling upstream despite continuing activity', async t => {
  const base = await upstream(t, (_req, res) => {
    res.write('x'); const timer = setInterval(() => res.write('x'), 10);
    res.once('close', () => clearInterval(timer));
  });
  const transport = createTransport({ allowPrivate: true, timeoutMs: 500 }); t.after(() => transport.close());
  const start = clock();
  await assert.rejects(transport.get(base, {}, { deadline: clock() + 80 }));
  assert.ok(clock() - start < 400);
  await delay(10); assert.equal(transport.stats().active, 0);
});

test('HLS rewrite covers keys, maps, byte ranges and child lists at redirected base', () => {
  const text = '#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI="keys/key.bin"\n#EXT-X-MAP:URI="init.mp4",BYTERANGE="32@0"\n#EXT-X-BYTERANGE:10@32\nsegment.mp4\n#EXT-X-MEDIA:TYPE=AUDIO,URI="audio.m3u8"\n';
  const out = rewritePlaylist(text, 'https://media.cctv.com/redirected/list.m3u8', 'http://127.0.0.1:8787');
  assert.ok(out.includes(encodeURIComponent('https://media.cctv.com/redirected/keys/key.bin')));
  assert.ok(out.includes(encodeURIComponent('https://media.cctv.com/redirected/init.mp4')));
  assert.ok(out.includes('#EXT-X-BYTERANGE:10@32'));
  assert.ok(out.includes(encodeURIComponent('https://media.cctv.com/redirected/audio.m3u8')));
  assert.throws(() => rewritePlaylist('#EXTM3U\nhttp://127.0.0.1/a.ts\n', 'https://media.cctv.com/list.m3u8', 'http://127.0.0.1:8787'), /forbidden/);
});

test('channel aliases and simultaneous first requests share one resolve', async t => {
  let count = 0;
  const { app, base } = await engine(t, { resolvePlaylist: async () => { count++; await delay(25); return { text: '#EXTM3U\n#EXT-X-MEDIA-SEQUENCE:5\n5.ts\n', url: 'https://media.cctv.com/live.m3u8' }; } });
  const responses = await Promise.all(Array.from({ length: 8 }, (_, index) => get(base + (index % 2 ? '/alias.m3u8' : '/live/demo.m3u8'))));
  assert.equal(count, 1); assert.ok(responses.every(r => r.status === 200));
  assert.equal(await app.resolve('unknown'), null);
  assert.ok(responses[0].body.includes(encodeURIComponent('https://media.cctv.com/5.ts')));
});

test('shared failure increments backoff once and immediate retries do not call upstream', async t => {
  let calls = 0, now = 1000;
  const { app } = await engine(t, { clock: () => now, resolvePlaylist: async () => { calls++; await delay(15); throw new EngineError('mock failed'); } });
  const results = await Promise.allSettled(Array.from({ length: 6 }, () => app.resolve('demo')));
  assert.ok(results.every(result => result.status === 'rejected')); assert.equal(calls, 1);
  await assert.rejects(app.resolve('demo'), error => error.statusCode === 503); assert.equal(calls, 1);
  now += 1001; await assert.rejects(app.resolve('demo')); assert.equal(calls, 2);
  now += 1001; await assert.rejects(app.resolve('demo'), error => error.statusCode === 503); assert.equal(calls, 2);
});

test('synchronous resolver exceptions remain retryable after backoff', async t => {
  let calls = 0, now = 1000;
  const { app } = await engine(t, { clock: () => now, resolvePlaylist: () => { calls++; throw new EngineError('sync failure'); } });
  await assert.rejects(app.resolve('demo')); now += 1001;
  await assert.rejects(app.resolve('demo')); assert.equal(calls, 2);
});

test('readiness tracks media progression and does not renew frozen signed URLs', async t => {
  let now = 1000, calls = 0;
  const { app, base } = await engine(t, { clock: () => now, stallMs: 6000, resolvePlaylist: async () => ({ text: `#EXTM3U\n#EXT-X-TARGETDURATION:2\n#EXT-X-MEDIA-SEQUENCE:9\nsegment.ts?signature=${++calls}\n`, url: 'https://media.cctv.com/list.m3u8' }) });
  assert.equal((await get(base + '/livez')).status, 200);
  assert.equal((await get(base + '/health')).status, 503);
  await app.resolve('demo'); assert.equal((await get(base + '/health')).status, 200);
  now += 2000; await app.resolve('demo'); now += 5000;
  await assert.rejects(app.resolve('demo'), /stalled/);
  assert.equal((await get(base + '/health')).status, 503);
});

test('HEAD never downloads a GET and Range preserves 206/416 metadata', async t => {
  const seen = [];
  const origin = await upstream(t, (req, res) => {
    seen.push([req.method, req.headers.range]);
    if (req.headers.range === 'bytes=999-') { res.writeHead(416, { 'Content-Range': 'bytes */10' }); res.end(); }
    else if (req.headers.range) { res.writeHead(206, { 'Content-Type': 'video/mp2t', 'Content-Length': 3, 'Content-Range': 'bytes 2-4/10', 'Accept-Ranges': 'bytes' }); res.end('234'); }
    else { res.writeHead(200, { 'Content-Length': 10, 'Content-Type': 'video/mp2t' }); res.end(req.method === 'HEAD' ? undefined : '0123456789'); }
  });
  const { base } = await engine(t);
  const target = base + '/segment?url=' + encodeURIComponent(origin + '/a.ts');
  const head = await get(target, { method: 'HEAD' });
  assert.equal(head.status, 200); assert.equal(head.body, ''); assert.deepEqual(seen, [['HEAD', undefined]]);
  const part = await get(target, { headers: { Range: 'bytes=2-4' } });
  assert.equal(part.status, 206); assert.equal(part.body, '234'); assert.equal(part.headers['content-range'], 'bytes 2-4/10');
  const invalid = await get(target, { headers: { Range: 'bytes=999-' } });
  assert.equal(invalid.status, 416); assert.equal(invalid.headers['content-range'], 'bytes */10');
});

test('nested playlists are rewritten and upstream status is not reported as success', async t => {
  const origin = await upstream(t, (req, res) => {
    if (req.url === '/missing.ts') { res.writeHead(404); res.end('private details'); }
    else { res.setHeader('Content-Type', 'application/vnd.apple.mpegurl'); res.end('#EXTM3U\n#EXT-X-MAP:URI="init.mp4"\nsegment.m4s\n'); }
  });
  const { base } = await engine(t);
  const good = await get(base + '/segment?url=' + encodeURIComponent(origin + '/child.m3u8'));
  assert.equal(good.status, 200); assert.ok(good.body.includes(encodeURIComponent(origin + '/init.mp4'))); assert.ok(good.body.includes(encodeURIComponent(origin + '/segment.m4s')));
  const bad = await get(base + '/segment?url=' + encodeURIComponent(origin + '/missing.ts'));
  assert.equal(bad.status, 404); assert.ok(!bad.body.includes('private details'));
});

test('request and upstream queues are bounded and release on cancellation', async t => {
  const limiter = new Limiter(1, 1);
  const release = await limiter.acquire(clock() + 1000);
  const controller = new AbortController();
  const queued = limiter.acquire(clock() + 1000, controller.signal);
  await assert.rejects(limiter.acquire(clock() + 1000), error => error.statusCode === 503);
  controller.abort(); await assert.rejects(queued, error => error.statusCode === 499);
  release(); assert.equal(limiter.active, 0); assert.equal(limiter.queue.length, 0);
  let unblock;
  const { base } = await engine(t, { maxRequests: 1, resolvePlaylist: () => new Promise(resolve => { unblock = () => resolve({ text: '#EXTM3U\n1.ts\n', url: 'https://media.cctv.com/a.m3u8' }); }) });
  const first = get(base + '/demo.m3u8');
  while (!unblock) await delay(2);
  assert.equal((await get(base + '/demo.m3u8')).status, 503);
  assert.equal((await get(base + '/livez')).status, 200);
  unblock(); assert.equal((await first).status, 200);
});

test('segment streams bytes before whole upstream body and client cancellation closes upstream', async t => {
  let closed;
  const disconnected = new Promise(resolve => { closed = resolve; });
  const origin = await upstream(t, (_req, res) => {
    res.writeHead(200, { 'Content-Type': 'video/mp2t' }); res.write('first');
    const timer = setTimeout(() => res.end('last'), 1000);
    res.once('close', () => { clearTimeout(timer); closed(); });
  });
  const { base } = await engine(t);
  const begin = clock();
  await new Promise((resolve, reject) => {
    const req = http.get(base + '/segment?url=' + encodeURIComponent(origin + '/slow.ts'), res => {
      res.once('data', chunk => { assert.equal(chunk.toString(), 'first'); assert.ok(clock() - begin < 500); req.destroy(); resolve(); });
      res.on('error', () => {});
    }); req.on('error', reject);
  });
  await Promise.race([disconnected, delay(500).then(() => { throw new Error('upstream not cancelled'); })]);
});

test('media identity query changes count as progress and static master lists are not mistaken for frozen media', async t => {
  let now = 1000, sequence = 1;
  const { app } = await engine(t, { clock: () => now, stallMs: 5000,
    resolvePlaylist: async () => ({ text: `#EXTM3U\nsegment.ts?sequence=${sequence++}\n`, url: 'https://media.cctv.com/live.m3u8' }) });
  await app.resolve('demo'); now += 6000; await app.resolve('demo');
  const master = await engine(t, { clock: () => now, stallMs: 5000,
    resolvePlaylist: async () => ({ text: '#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1000\nchild.m3u8\n', url: 'https://media.cctv.com/master.m3u8' }) });
  await master.app.resolve('demo'); now += 6000; await master.app.resolve('demo');
});

test('resolver deadline and shutdown cancel shared work without leaving timers', async t => {
  const { app } = await engine(t, { resolveTimeoutMs: 40, resolvePlaylist: () => new Promise(() => {}) });
  await assert.rejects(app.resolve('demo'), error => error.statusCode === 504);
  const another = await engine(t, { resolveTimeoutMs: 10000, resolvePlaylist: () => new Promise(() => {}) });
  const task = another.app.resolve('demo');
  await another.app.close();
  await assert.rejects(task, error => error.statusCode === 504);
});

test('segment rejects declared oversize before forwarding and invalid range without opening upstream', async t => {
  let hits = 0;
  const origin = await upstream(t, (_req, res) => { hits++; res.writeHead(200, { 'Content-Length': 5000 }); res.end('x'.repeat(5000)); });
  const { base } = await engine(t, { maxSegmentBytes: 1024 });
  const target = base + '/segment?url=' + encodeURIComponent(origin + '/oversize.ts');
  assert.equal((await get(target, { headers: { Range: 'bytes=0-10,20-30' } })).status, 416); assert.equal(hits, 0);
  assert.equal((await get(target)).status, 502); assert.equal(hits, 1);
});

test('closing transport cancels pending DNS and releases capacity immediately', async () => {
  let started;
  const lookupStarted = new Promise(resolve => { started = resolve; });
  const transport = createTransport({ lookup: () => { started(); return new Promise(() => {}); } });
  const task = transport.get('https://media.cctv.com/live.m3u8');
  await lookupStarted;
  transport.close();
  await assert.rejects(task, error => error.statusCode === 503);
  assert.deepEqual(transport.stats(), { active: 0, queued: 0 });
});

test('redirect hands its capacity to the next hop even with one upstream slot and no queue', async t => {
  const origin = await upstream(t, (req, res) => {
    if (req.url === '/redirect') { res.writeHead(302, { Location: '/ok' }); res.end(); }
    else res.end('ok');
  });
  const transport = createTransport({ allowPrivate: true, maxUpstream: 1, maxQueue: 0 });
  t.after(() => transport.close());
  assert.equal((await transport.get(origin + '/redirect')).data, 'ok');
  assert.deepEqual(transport.stats(), { active: 0, queued: 0 });
});
