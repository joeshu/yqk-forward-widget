const assert = require('node:assert/strict');
const { test, after } = require('node:test');
const http = require('http');
const dns = require('dns');
const { once } = require('events');
const engine = require('../ysp-engine.js');

after(() => engine.server.close());

test('blocks local, mapped, reserved and private addresses', () => {
  for (const ip of ['127.0.0.1', '10.0.0.1', '169.254.169.254', '100.64.0.1', '192.168.0.1', '224.0.0.1', '::1', '::ffff:127.0.0.1', 'fc00::1', '2001:db8::1', '2002:0808:0808::1']) {
    assert.equal(engine.isPublicIP(ip), false, ip);
  }
  for (const ip of ['8.8.8.8', '1.1.1.1', '2606:4700:4700::1111']) assert.equal(engine.isPublicIP(ip), true, ip);
});

test('validates protocol, hostname, credentials and ports', () => {
  assert.equal(engine.validateSegmentTarget('https://cdn.cctv.cn/a.ts').hostname, 'cdn.cctv.cn');
  for (const target of ['http://127.0.0.1/a.ts', 'file:///etc/passwd', 'https://cdn.cctv.cn.evil.example/a.ts', 'https://user:pass@cdn.cctv.cn/a.ts', 'http://cdn.cctv.cn:8000/a.ts']) {
    assert.throws(() => engine.validateSegmentTarget(target));
  }
});

test('DNS validation rejects mixed public/private answers', async () => {
  const original = dns.lookup;
  dns.lookup = (host, opts, callback) => callback(null, [{ address: '8.8.8.8', family: 4 }, { address: '127.0.0.1', family: 4 }]);
  try {
    await assert.rejects(new Promise((resolve, reject) => engine.safeLookup('cdn.cctv.cn', {}, (error, result) => error ? reject(error) : resolve(result))));
  } finally { dns.lookup = original; }
});

test('DNS selection supplies checked addresses without another lookup', async () => {
  const original = dns.lookup;
  dns.lookup = (host, opts, callback) => callback(null, [{ address: '8.8.8.8', family: 4 }]);
  try {
    const addresses = await new Promise((resolve, reject) => engine.safeLookup('cdn.cctv.cn', { all: true }, (error, result) => error ? reject(error) : resolve(result)));
    assert.deepEqual(addresses, [{ address: '8.8.8.8', family: 4 }]);
  } finally { dns.lookup = original; }
});

test('streams bytes with Range and HEAD, validates redirects, bounds size and cancels disconnects', async () => {
  const previousDirect = process.env.YSP_DIRECT;
  process.env.YSP_DIRECT = '1';
  let seenRange, aborted = false;
  const upstream = http.createServer((req, res) => {
    if (req.url === '/redirect') {
      res.writeHead(302, { Location: 'http://127.0.0.1/private' }); res.end(); return;
    }
    if (req.url === '/large') {
      res.writeHead(200, { 'Content-Length': 36 * 1024 * 1024 }); res.end(); return;
    }
    if (req.url === '/slow') {
      res.writeHead(200, { 'Content-Type': 'video/mp2t' });
      const timer = setInterval(() => res.write(Buffer.alloc(4096)), 10);
      res.on('close', () => { aborted = true; clearInterval(timer); });
      return;
    }
    seenRange = req.headers.range;
    res.writeHead(seenRange ? 206 : 200, { 'Content-Type': 'video/mp2t', 'Content-Length': 7 });
    res.end(req.method === 'HEAD' ? undefined : 'payload');
  });
  upstream.listen(0, '127.0.0.1'); await once(upstream, 'listening');
  const original = http.request;
  // Route only this test's validated CDN request to the local fixture.
  http.request = function(target, options, callback) {
    if (target instanceof URL && target.hostname === 'cdn.cctv.cn') {
      const local = new URL(target.pathname, `http://127.0.0.1:${upstream.address().port}`);
      return original.call(http, local, { ...options, agent: false }, callback);
    }
    return original.apply(http, arguments);
  };
  const proxy = http.createServer(async (req, res) => {
    try { await engine.streamSegment(req, res, 'http://cdn.cctv.cn' + req.url); }
    catch (_) { if (res.headersSent) res.destroy(); else { res.writeHead(502); res.end(); } }
  });
  proxy.listen(0, '127.0.0.1'); await once(proxy, 'listening');
  function fetch(path, method = 'GET', headers = {}) {
    return new Promise((resolve, reject) => {
      const request = original.call(http, `http://127.0.0.1:${proxy.address().port}${path}`, { method, headers, agent: false }, response => {
        const chunks = [];
        response.on('data', data => chunks.push(data));
        response.on('end', () => resolve({ status: response.statusCode, data: Buffer.concat(chunks) }));
        response.on('error', reject);
      });
      request.on('error', reject); request.end();
    });
  }
  try {
    assert.equal((await fetch('/a.ts')).data.toString(), 'payload');
    assert.equal((await fetch('/a.ts', 'HEAD')).data.length, 0);
    assert.equal((await fetch('/a.ts', 'GET', { Range: 'bytes=0-6' })).status, 206);
    assert.equal(seenRange, 'bytes=0-6');
    assert.equal((await fetch('/redirect')).status, 502);
    assert.equal((await fetch('/large')).status, 502);
    await new Promise((resolve, reject) => {
      const request = original.call(http, `http://127.0.0.1:${proxy.address().port}/slow`, { agent: false }, response => {
        response.once('data', () => { response.destroy(); resolve(); });
      });
      request.on('error', reject); request.end();
    });
    await new Promise(resolve => setTimeout(resolve, 100));
    assert.equal(aborted, true);
  } finally {
    http.request = original;
    if (previousDirect === undefined) delete process.env.YSP_DIRECT; else process.env.YSP_DIRECT = previousDirect;
    proxy.closeAllConnections(); upstream.closeAllConnections();
    await Promise.all([new Promise(resolve => proxy.close(resolve)), new Promise(resolve => upstream.close(resolve))]);
  }
});
