/**
 * 红果短剧 · CCTVHost JS 源（Node.js Mobile 运行时）
 *
 * 为什么用 require()：规范里写明「CommonJS require() 默认走 Node.js Mobile」，
 * 一旦 require 就切到完整 Node（18.20.4），从而拿到原生 AES-CTR、文件和网络接口。
 *
 * 链路：
 *   签名 multi_video_model（x-gorgon/x-ladon/x-argus/x-helios）
 *   → 解 spade URL（AES-128-CBC）
 *   → 派生 CENC key
 *   → 下载 + 原生 AES-CTR 逐样本解密 + 改写 moov
 *   → CCTVHost localProxy 按 Range 从资源数据目录交付给播放器
 */
'use strict';

const http = require('node:http');
const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');

// ---------------- 配置 ----------------
const SITE = 'https://hongguoduanju.com';
const VIDEO_API = 'https://api5-normal-sinfonlineb.fqnovel.com/novel/player/multi_video_model/v1/';
const UA_WEB = 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148';
const UA_APP = 'com.phoenix.read/74132 (iPhone; iOS 27.0.1; zh_CN; iPhone 12; Build/21A342)';

// 真实 iOS 设备参数（从 App 的 fallback_api URL 提取；失效时改这里）
const DEVICE = {
  device_id: '780019670991881',
  user_id: '3594769438086775',
  aid: '8662',
  app_name: 'novelread',
  version_code: '74132',
  version_name: '7.4.1.32',
  manifest_version_code: '74132',
  update_version_code: '74132',
  device_platform: 'iphone',
  os: 'ios',
  os_version: '27.0.1',
  os_api: '27',
  device_type: 'iPhone 12',
  device_brand: 'Apple',
  language: 'zh',
  resolution: '1170*2532',
  dpi: '460',
  host_abi: 'arm64',
  channel: 'App Store',
  ac: 'wifi',
  ssmix: 'a',
  pv_player: '74132',
  compliance_status: '0',
  need_personal_recommend: '1',
  player_so_load: '1',
};

const SPADE_CONST = Buffer.from(
  '4dd4c2e6b83162090e52b3c7a6733ba41cb2462b829ab58a196b39db57177524' +
  'f49baf7f08e8d68d26a72e37c1a95a2f1f05a51892aef2949732b62a38aadd58', 'hex');

const CACHE_DIR = path.join(process.cwd(), 'hgtv-js-cache');
const QORDER = ['1080p', '720p', '540p', '480p', '360p'];

const modelCache = new Map();     // vid -> {t, vm}
const decryptFlights = new Map(); // vid + quality -> Promise<path|null>
const MODEL_TTL = 300 * 1000;

// ---------------- 工具 ----------------
function md5(b) {
  return crypto.createHash('md5').update(b).digest();
}
function sha512(b) {
  return crypto.createHash('sha512').update(b).digest();
}
function be32(v) {
  const b = Buffer.alloc(4);
  b.writeUInt32BE(Number(v) >>> 0);
  return b;
}
function le32(v) {
  const b = Buffer.alloc(4);
  b.writeUInt32LE(Number(v) >>> 0);
  return b;
}
function revbits(v) {
  let r = 0;
  for (let i = 0; i < 8; i++) r = ((r << 1) | ((v >> i) & 1)) & 0xFF;
  return r;
}
function rc4(data, key) {
  const s = new Uint8Array(256);
  for (let i = 0; i < 256; i++) s[i] = i;
  let j = 0;
  for (let i = 0; i < 256; i++) {
    j = (j + s[i] + key[i % key.length]) & 0xFF;
    const t = s[i]; s[i] = s[j]; s[j] = t;
  }
  const out = Buffer.alloc(data.length);
  let i = 0; j = 0;
  for (let k = 0; k < data.length; k++) {
    i = (i + 1) & 0xFF;
    const x = s[i];
    j = (j + x) & 0xFF;
    const y = s[j];
    s[i] = y;
    out[k] = data[k] ^ s[(y + y) & 0xFF];
  }
  return out;
}
function pct(s) {
  return encodeURIComponent(String(s)).replace(/[!'()]/g, c => '%' + c.charCodeAt(0).toString(16).toUpperCase());
}

// ---------------- 签名 ----------------
function xGorgon(query, body, ts, rnd) {
  const sdk = Buffer.alloc(4);
  sdk.writeUInt32LE(67503104);
  const input = Buffer.concat([
    md5(query).subarray(0, 4),
    body ? md5(body).subarray(0, 4) : Buffer.alloc(4),
    Buffer.alloc(4),
    sdk,
    be32(ts),
  ]);
  const key = [0x4A, 0x40, 0x16, (rnd >> 8) & 0xFF, 0x47, 0x6C, 0x01, rnd & 0xFF];
  const out = rc4(input, key);
  for (let i = 0; i < out.length; i++) {
    let v = ((out[i] >> 4) | (out[i] << 4)) & 0xFF;
    const nxt = i + 1 < out.length ? out[i + 1] : out[0];
    out[i] = (~(revbits((nxt ^ v) & 0xFF) ^ 20)) & 0xFF;
  }
  return Buffer.concat([Buffer.from('8404', 'hex'), Buffer.from([rnd & 0xFF, (rnd >> 8) & 0xFF, 0x40, 0x01]), out]).toString('hex');
}

function ror64(x, n) {
  const mask = (1n << 64n) - 1n;
  const v = BigInt.asUintN(64, x);
  const s = BigInt(n);
  return BigInt.asUintN(64, (v >> s) | (v << (64n - s))) & mask;
}

function helios(ts) {
  const rnd = crypto.randomInt(0, 0xFFFFFFFF);
  const digest = md5(Buffer.concat([le32(rnd), Buffer.from('8662')]));
  const ascii = Buffer.from(digest.toString('hex'), 'ascii');
  const words = [];
  for (let i = 0; i < 4; i++) words.push(ascii.readBigUInt64LE(i * 8));
  const table = [words[0]];
  let b0 = words[0], b8 = words[1];
  words.splice(0, 2);
  for (let i = 0; i < 34; i++) {
    let x8 = BigInt.asUintN(64, ror64(b8, 8) + b0);
    x8 = BigInt.asUintN(64, x8 ^ BigInt(i));
    words.push(x8);
    x8 = BigInt.asUintN(64, x8 ^ ror64(b0, 61));
    table.push(x8);
    b0 = x8; b8 = words.shift();
  }
  const text = Buffer.from(`${ts}-1588093228-8662`);
  const total = Math.ceil((text.length + 1) / 16) * 16;
  const pad = Buffer.alloc(total, 16 - (text.length % 16));
  text.copy(pad);
  const out = [le32(rnd)];
  for (let at = 0; at < total; at += 16) {
    let a = pad.readBigUInt64LE(at);
    let b = pad.readBigUInt64LE(at + 8);
    for (let i = 0; i < 34; i++) {
      b = BigInt.asUintN(64, table[i] ^ (a + ror64(b, 8)));
      a = BigInt.asUintN(64, b ^ ror64(a, 61));
    }
    const block = Buffer.alloc(16);
    block.writeBigUInt64LE(a, 0);
    block.writeBigUInt64LE(b, 8);
    out.push(block);
  }
  return Buffer.concat(out).toString('base64');
}

function getIv(iv, data) {
  let v = iv >>> 0;
  for (let i = 0; i < data.length; i++) {
    if ((i & 1) === 0) v = ((v >>> 4) ^ v ^ ((v << 6) >>> 0) ^ data[i]) >>> 0;
    else v = (~(((v >>> 7) ^ v ^ (data[i] | ((v << 12) >>> 0))) >>> 0)) >>> 0;
  }
  return v >>> 0;
}

function branchOf(url, body, ts) {
  const q = crypto.createHash('sm3').update(url.split('?')[1]).digest();
  const bm = body ? md5(body) : Buffer.alloc(16);
  const iv = getIv(getIv(getIv(0x20230928, q), bm), le32(ts));
  const low = iv & 15;
  return low - ((((low * 171) >>> 9) * 3));
}

function signedRequest(payload) {
  const ts = Math.floor(Date.now() / 1000);
  const body = Buffer.from(payload);
  const rnd = crypto.randomInt(0, 65536);
  const vals = Object.assign({}, DEVICE, { ts: String(ts) });
  const base = Date.now();
  let query = '', url = '';
  for (let off = 0; off < 32; off++) {
    vals._rticket = String(base + off);
    query = Object.keys(vals).map(k => `${pct(k)}=${pct(vals[k])}`).join('&');
    url = VIDEO_API + '?' + query;
    if (branchOf(url, body, ts) !== 1) break;
  }
  const headers = {
    'User-Agent': UA_APP,
    'Accept': 'application/json; charset=utf-8,application/x-protobuf',
    'Content-Type': 'application/json; charset=UTF-8',
    'x-xs-from-web': '0',
    'x-ss-req-ticket': vals._rticket,
    'x-tt-request-tag': 't=0;n=0',
    'sdk-version': '2',
    'passport-sdk-version': '50561',
    'x-vc-bdturing-sdk-version': '3.7.2.cn',
    'x-ss-stub': md5(body).toString('hex').toUpperCase(),
    'x-gorgon': xGorgon(query, body, ts, rnd),
    'x-khronos': String(ts),
    'x-ladon': be32(ts).toString('base64'),
    'x-argus': le32(ts).toString('base64'),
    'x-helios': helios(ts),
    'x-tt-dt': '',
  };
  return { url, headers, body };
}

// ---------------- HTTP 客户端 ----------------
function httpText(url, opts, redirects = 0) {
  opts = opts || {};
  return new Promise((resolve, reject) => {
    let u;
    try { u = new URL(url); } catch (error) { reject(Error('invalid HTTP URL')); return; }
    if (!['http:', 'https:'].includes(u.protocol) || u.username || u.password) {
      reject(Error('only credential-free HTTP/HTTPS URLs are supported')); return;
    }
    const mod = u.protocol === 'https:' ? require('node:https') : http;
    const method = String(opts.method || 'GET').toUpperCase();
    const headers = { ...(opts.headers || {}) };
    const body = opts.body;
    const req = mod.request({
      hostname: u.hostname,
      port: u.port || (u.protocol === 'https:' ? 443 : 80),
      path: u.pathname + u.search,
      method,
      headers,
      timeout: opts.timeout || 25000,
    }, res => {
      const location = res.headers.location;
      if ([301, 302, 303, 307, 308].includes(res.statusCode) && location) {
        res.resume();
        if (redirects >= 5) { reject(Error('too many HTTP redirects')); return; }
        let target;
        try { target = new URL(location, u); } catch (error) { reject(Error('invalid HTTP redirect')); return; }
        if (!['http:', 'https:'].includes(target.protocol) || target.username || target.password ||
            (u.protocol === 'https:' && target.protocol !== 'https:')) {
          reject(Error('unsafe HTTP redirect target')); return;
        }
        const nextHeaders = { ...headers };
        if (target.origin !== u.origin) {
          for (const key of Object.keys(nextHeaders)) {
            if (/^(authorization|cookie|proxy-authorization)$/i.test(key)) delete nextHeaders[key];
          }
        }
        const switchToGet = res.statusCode === 303 ||
          ((res.statusCode === 301 || res.statusCode === 302) && method === 'POST');
        if (switchToGet) {
          for (const key of Object.keys(nextHeaders)) {
            if (/^(content-type|content-length|transfer-encoding)$/i.test(key)) delete nextHeaders[key];
          }
        }
        httpText(target.toString(), {
          ...opts,
          method: switchToGet ? 'GET' : method,
          headers: nextHeaders,
          body: switchToGet ? undefined : body,
        }, redirects + 1).then(resolve, reject);
        return;
      }
      const chunks = [];
      let total = 0;
      res.on('data', c => {
        total += c.length;
        if (total > 32 * 1024 * 1024) {
          res.destroy(Error('HTTP response exceeds 32 MB'));
          return;
        }
        chunks.push(c);
      });
      res.on('error', reject);
      res.on('end', () => resolve({ status: res.statusCode, headers: res.headers, body: Buffer.concat(chunks) }));
    });
    req.on('timeout', () => { req.destroy(new Error('timeout')); });
    req.on('error', reject);
    if (body) req.write(body);
    req.end();
  });
}

// ---------------- 红果站点层 ----------------
async function siteHtml(pathOrUrl) {
  const url = pathOrUrl.startsWith('http') ? pathOrUrl : SITE + pathOrUrl;
  const r = await httpText(url, { headers: { 'User-Agent': UA_WEB, 'Accept-Language': 'zh-CN,zh;q=0.9' } });
  if (r.status !== 200) throw new Error('站点 HTTP ' + r.status);
  return r.body.toString('utf8');
}

function stripTags(s) {
  return String(s || '').replace(/<[^>]*>/g, '').replace(/&amp;/g, '&').replace(/&quot;/g, '"')
    .replace(/&#x27;/g, "'").replace(/&#39;/g, "'").replace(/&lt;/g, '<').replace(/&gt;/g, '>').trim();
}

function cardsFrom(html) {
  const re = /href="\/detail\?series_id=(\d+)"/g;
  const hits = [];
  let m;
  while ((m = re.exec(html))) hits.push({ sid: m[1], at: m.index });
  const out = [];
  const seen = new Set();
  for (let i = 0; i < hits.length; i++) {
    const sid = hits[i].sid;
    if (seen.has(sid)) continue;
    const end = i + 1 < hits.length ? hits[i + 1].at : Math.min(html.length, hits[i].at + 1500);
    const chunk = html.slice(hits[i].at, end);
    let title = '';
    const tm = chunk.match(/class="[^"]*(?:pc-title|m-title|title)[^"]*"[^>]*>(.*?)</s) || chunk.match(/title="([^"]{2,60})"/);
    if (tm) title = stripTags(tm[1]);
    if (!title) continue;
    seen.add(sid);
    const im = chunk.match(/(?:data-src|src)="(https?:\/\/[^"]+?\.(?:jpg|jpeg|png|webp))"/i);
    const ep = chunk.match(/class="[^"]*(?:pc-episode|m-episode|episode)[^"]*"[^>]*>(.*?)</s);
    out.push({
      vod_id: sid,
      vod_name: title,
      vod_pic: im ? im[1] : '',
      vod_remarks: ep ? stripTags(ep[1]) : '',
    });
  }
  return out;
}

async function parseEpisodes(sid) {
  const html = await siteHtml('/player/' + sid);
  const order = new Map();
  const re = /\/(?:player)\/\d+\/(\d{15,25})/g;
  let m, idx = 0;
  while ((m = re.exec(html))) {
    if (!order.has(m[1])) order.set(m[1], ++idx);
  }
  return Array.from(order.entries()).map(([eid, n]) => ({ name: '第' + n + '集', id: eid }));
}

// ---------------- 视频模型（签名接口） ----------------
async function fetchModel(vid) {
  const hit = modelCache.get(String(vid));
  if (hit && Date.now() - hit.t < MODEL_TTL) return hit.vm;
  const payload = JSON.stringify({
    biz_param: {
      detail_page_version: 0, device_level: 3, disable_digg_stat: false,
      need_all_video_definition: true, need_mp4_align: false,
      use_os_player: false, use_server_dns: false, video_platform: 1024,
    },
    mixed_video_id_map: { '1004': [String(vid)] },
  });
  for (let attempt = 0; attempt < 2; attempt++) {
    const s = signedRequest(payload);
    const r = await httpText(s.url, { method: 'POST', headers: s.headers, body: s.body });
    let j = null;
    try { j = JSON.parse(r.body.toString('utf8')); } catch (e) { }
    if (j && (j.code === 0 || j.code == null)) {
      const ent = (j.data || {})[String(vid)] || {};
      let vm = ent.video_model;
      if (typeof vm === 'string') { try { vm = JSON.parse(vm); } catch (e) { vm = null; } }
      if (vm && vm.video_list) {
        if (Array.isArray(vm.video_list)) {
          const m = {};
          vm.video_list.forEach((it, i) => { m[String(it.definition || i)] = it; });
          vm.video_list = m;
        }
        modelCache.set(String(vid), { t: Date.now(), vm });
        return vm;
      }
    }
    await new Promise(r2 => setTimeout(r2, 600));
  }
  return null;
}

// ---------------- 解密 ----------------
function decryptSpade(value, seed) {
  const raw = Buffer.from(value, 'base64');
  if (raw.length < 5 || raw[0] !== 0xA8 || raw[2] !== 0x01 || raw[3] !== 0x00) return null;
  const n = Math.floor((raw.length - 4) / 16) * 16;
  if (!n) return null;
  const h1 = sha512(seed);
  const h2 = sha512(Buffer.concat([h1, SPADE_CONST]));
  const dec = crypto.createDecipheriv('aes-128-cbc', h2.subarray(0, 16), h2.subarray(16, 32));
  dec.setAutoPadding(false);
  let pt = Buffer.concat([dec.update(raw.subarray(4, 4 + n)), dec.final()]);
  if (pt.length) {
    const pad = pt[pt.length - 1];
    if (pad >= 1 && pad <= 16 && pad <= pt.length) pt = pt.subarray(0, pt.length - pad);
  }
  while (pt.length && pt[pt.length - 1] === 0) pt = pt.subarray(0, pt.length - 1);
  const s = pt.toString('utf8');
  return s.startsWith('http') ? s : null;
}

function deriveContentKey(spadeA) {
  const raw = Buffer.from(String(spadeA).replace(/-/g, '+').replace(/_/g, '/'), 'base64');
  if (raw.length < 3) return null;
  let v8 = raw.length - (raw[0] ^ raw[1] ^ raw[2]) + 47;
  v8 = Math.min(v8, raw.length - 1);
  if (v8 < 33) return null;
  const work = Buffer.from(raw.subarray(1, 1 + v8));
  let a = 85, b = 246;
  for (let i = 0; i < v8; i++) {
    const old = work[i];
    const prev = (i & 1) ? a : b;
    if (i & 1) a = old; else b = old;
    let pop = 0;
    for (let x = i; x; x >>= 1) pop += x & 1;
    work[i] = (-21 - pop + (prev ^ old)) & 255;
  }
  return Buffer.from(work.subarray(1, 33).toString('ascii'), 'hex');
}

function pickBest(vm, want) {
  const vl = (vm && vm.video_list) || {};
  const cands = [];
  for (const k of Object.keys(vl)) {
    const it = vl[k] || {};
    const q = String(it.definition || k);
    const gear = String(it.gear_des_key || '');
    const bad = (/bytevc2|bvc2/.test(gear)) ? 1 : 0;
    const order = QORDER.indexOf(q) >= 0 ? QORDER.indexOf(q) : 99;
    cands.push({ bad, order, q, it });
  }
  if (!cands.length) return null;
  cands.sort((x, y) => (x.bad - y.bad) || (x.order - y.order));
  if (want) {
    const found = cands.find(c => c.q === want && c.bad === 0);
    if (found) return found;
  }
  return cands[0];
}

// ---------------- MP4 / CENC ----------------
function readBox(d, off) {
  if (off < 0 || off + 8 > d.length) return null;
  let size = d.readUInt32BE(off);
  const type = d.toString('ascii', off + 4, off + 8);
  let header = 8;
  if (size === 1) { size = Number(d.readBigUInt64BE(off + 8)); header = 16; }
  else if (size === 0) size = d.length - off;
  if (size < header || off + size > d.length) return null;
  return { offset: off, size, type, header, body: off + header };
}

function findBox(d, type, start) {
  let off = Math.max(0, start || 0);
  while (off + 8 <= d.length) {
    const b = readBox(d, off);
    if (b && b.type === type) return b;
    off += 1;
  }
  return null;
}

function boxBody(d, type, start) {
  const b = findBox(d, type, start);
  return b ? d.subarray(b.body, b.offset + b.size) : null;
}

function parseTrack(moov, track) {
  const stbl = findBox(moov, 'stbl', track.body);
  if (!stbl) return null;
  const stsz = boxBody(moov, 'stsz', stbl.body);
  const stsc = boxBody(moov, 'stsc', stbl.body);
  const chunk = findBox(moov, 'stco', stbl.body) || findBox(moov, 'co64', stbl.body);
  const saiz = boxBody(moov, 'saiz', stbl.body);
  const saio = boxBody(moov, 'saio', stbl.body);
  if (!stsz || !stsc || !chunk || !saiz || !saio) return null;
  if (stsz.length < 12 || stsc.length < 8 || saiz.length < 9 || saio.length < 12) return null;
  const dsize = stsz.readUInt32BE(4);
  const scount = stsz.readUInt32BE(8);
  const sizes = [];
  if (dsize) { for (let i = 0; i < scount; i++) sizes.push(dsize); }
  else { for (let i = 0; i < scount; i++) sizes.push(stsz.readUInt32BE(12 + i * 4)); }
  const is64 = chunk.type === 'co64';
  const ccount = moov.readUInt32BE(chunk.body + 4);
  const offs = [];
  for (let i = 0; i < ccount; i++) {
    const at = chunk.body + 8 + i * (is64 ? 8 : 4);
    offs.push(is64 ? Number(moov.readBigUInt64BE(at)) : moov.readUInt32BE(at));
  }
  const ecount = stsc.readUInt32BE(4);
  const entries = [];
  for (let i = 0; i < ecount; i++) {
    const at = 8 + i * 12;
    entries.push([stsc.readUInt32BE(at), stsc.readUInt32BE(at + 4)]);
  }
  const spc = offs.map((_v, i) => {
    let sel = 0;
    for (const [first, per] of entries) if (first <= i + 1) sel = per;
    return sel;
  });
  const auxDefault = saiz[4];
  const auxCount = saiz.readUInt32BE(5);
  const auxSizes = [];
  if (auxDefault) { for (let i = 0; i < auxCount; i++) auxSizes.push(auxDefault); }
  else { for (let i = 0; i < auxCount; i++) auxSizes.push(saiz[9 + i] || 0); }
  const sver = saio[0];
  const auxOffset = sver === 1 ? Number(saio.readBigUInt64BE(8)) : saio.readUInt32BE(8);
  return { sizes, offsets: offs, spc, auxOffset, auxSizes, sampleCount: scount };
}

function buildSamples(data, tracks) {
  const out = [];
  for (const tr of tracks) {
    let idx = 0, apos = 0;
    const atotal = tr.auxSizes.reduce((s, x) => s + Math.max(x, 8), 0);
    const aux = data.subarray(tr.auxOffset, tr.auxOffset + atotal);
    for (let ci = 0; ci < tr.offsets.length && idx < tr.sampleCount; ci++) {
      let off = tr.offsets[ci];
      const cnt = tr.spc[ci] || 0;
      for (let k = 0; k < cnt && idx < tr.sampleCount; k++) {
        const size = tr.sizes[idx];
        const asz = Math.max(tr.auxSizes[idx] || 8, 8);
        const iv = Buffer.alloc(16);
        aux.copy(iv, 0, apos, apos + Math.min(8, asz));
        out.push({ start: off, end: off + size, iv });
        off += size; idx += 1; apos += asz;
      }
    }
  }
  out.sort((a, b) => a.start - b.start);
  return out;
}

function replaceSinf(h) {
  let pos = 0;
  while (true) {
    pos = h.indexOf('sinf', pos, 'latin1');
    if (pos < 0) break;
    if (pos < 4) { pos += 4; continue; }
    const size = h.readUInt32BE(pos - 4);
    const end = pos - 4 + size;
    if (size >= 8 && size < 50000 && end <= h.length) {
      h.write('free', pos - 4, 'latin1');
      h.fill(0, pos, end);
      pos = end;
    } else pos += 4;
  }
}

function clearAuxBoxes(header) {
  for (const kind of ['senc', 'saiz', 'saio', 'sgpd', 'sbgp']) {
    let pos = 0;
    while ((pos = header.indexOf(kind, pos, 'latin1')) >= 0) {
      if (pos < 4) { pos += 4; continue; }
      const start = pos - 4;
      const size = header.readUInt32BE(start);
      const end = start + size;
      if ((kind === 'sgpd' || kind === 'sbgp') &&
          (pos + 12 > end || header.toString('latin1', pos + 8, pos + 12) !== 'seig')) {
        pos += 4;
        continue;
      }
      if (size >= 8 && end <= header.length) {
        header.write('free', pos, 'latin1');
        header.fill(0, start + 8, end);
        pos = end;
      } else pos += 4;
    }
  }
}

function replaceFourcc(buf, oldS, newS) {
  let pos = 0;
  while ((pos = buf.indexOf(oldS, pos, 'latin1')) >= 0) {
    buf.write(newS, pos, 'latin1');
    pos += 4;
  }
}

function decryptCenc(src, dst, key) {
  const data = fs.readFileSync(src);
  const ftypSize = data.readUInt32BE(0);
  const moov = readBox(data, ftypSize);
  if (!moov || moov.type !== 'moov') throw new Error('invalid moov');
  const mb = data.subarray(moov.body, moov.offset + moov.size);
  const tracks = [];
  let cur = 0;
  while (true) {
    const tr = findBox(mb, 'trak', cur);
    if (!tr) break;
    tracks.push(tr);
    cur = tr.offset + tr.size;
  }
  const parsed = tracks.map(t => parseTrack(mb, t)).filter(Boolean);
  const samples = buildSamples(data, parsed);
  if (!samples.length) throw new Error('CENC sample table is empty');
  const out = Buffer.from(data);
  const header = Buffer.from(data.subarray(0, moov.offset + moov.size));
  replaceFourcc(header, 'encv', 'hvc1');
  replaceFourcc(header, 'enca', 'mp4a');
  replaceSinf(header);
  clearAuxBoxes(header);
  header.copy(out, 0);
  for (const s of samples) {
    if (s.start >= out.length) continue;
    const end = Math.min(s.end, out.length);
    const dec = crypto.createDecipheriv('aes-128-ctr', key, s.iv);
    const plain = Buffer.concat([dec.update(out.subarray(s.start, end)), dec.final()]);
    plain.copy(out, s.start);
  }
  fs.writeFileSync(dst, out);
  return dst;
}

// ---------------- 解密产物 ----------------
function verifyMp4(p) {
  try {
    if (fs.statSync(p).size < 8192) return false;
    const fd = fs.openSync(p, 'r');
    const buf = Buffer.alloc(Math.min(3 * 1024 * 1024, fs.statSync(p).size));
    fs.readSync(fd, buf, 0, buf.length, 0);
    fs.closeSync(fd);
    const head = buf.toString('latin1');
    return head.indexOf('ftyp') >= 0 && head.indexOf('moov') >= 0 && head.indexOf('trak') >= 0;
  } catch (e) {
    return false;
  }
}

async function ensureDecrypted(vid, want) {
  const flightKey = `${vid}:${want || ''}`;
  if (decryptFlights.has(flightKey)) return decryptFlights.get(flightKey);
  const flight = decryptVideo(vid, want);
  decryptFlights.set(flightKey, flight);
  try { return await flight; }
  finally { if (decryptFlights.get(flightKey) === flight) decryptFlights.delete(flightKey); }
}

async function decryptVideo(vid, want) {
  fs.mkdirSync(CACHE_DIR, { recursive: true });
  const vm = await fetchModel(vid);
  if (!vm) return null;
  const pick = pickBest(vm, want);
  if (!pick) return null;
  const q = pick.q;
  const it = pick.it;
  const dst = path.join(CACHE_DIR, `${vid}_${q}.mp4`);
  if (fs.existsSync(dst) && verifyMp4(dst)) return dst;
  if (fs.existsSync(dst)) { try { fs.unlinkSync(dst); } catch (e) { } }

  const seedS = vm.key_seed || '';
  const seed = seedS ? Buffer.from(seedS, 'base64') : Buffer.alloc(0);
  let url = it.main_url || '';
  if (url && !url.startsWith('http') && seed.length) url = decryptSpade(url, seed);
  if (!url) return null;
  const encInfo = it.encrypt_info || {};
  const spadeA = it.spade_a || encInfo.spade_a;
  const key = spadeA ? deriveContentKey(spadeA) : null;
  const isEnc = !!encInfo.encrypt || /1:encrypt/.test(String(it.gear_des_key || ''));
  if (isEnc && !key) return null;

  const tmp = dst + '.tmp.mp4';
  const r = await httpText(url, { headers: { 'User-Agent': UA_APP }, timeout: 180000 });
  if (r.status !== 200) return null;
  fs.writeFileSync(tmp, r.body);
  if (key && isEnc) {
    const enc = dst + '.enc.mp4';
    fs.renameSync(tmp, enc);
    try {
      decryptCenc(enc, tmp, key);
    } finally {
      try { fs.unlinkSync(enc); } catch (e) { }
    }
  }
  if (!verifyMp4(tmp)) { try { fs.unlinkSync(tmp); } catch (e) { } return null; }
  fs.renameSync(tmp, dst);
  return dst;
}

function parseByteRange(value, size) {
  if (!value) return { start: 0, end: size - 1, partial: false };
  const match = /^bytes=(\d*)-(\d*)$/i.exec(String(value).trim());
  if (!match || String(value).includes(',')) return null;
  let start, end;
  if (match[1]) {
    start = Number(match[1]);
    end = match[2] ? Math.min(Number(match[2]), size - 1) : size - 1;
  } else if (match[2]) {
    const suffix = Number(match[2]);
    if (!Number.isSafeInteger(suffix) || suffix <= 0) return null;
    start = Math.max(0, size - suffix);
    end = size - 1;
  } else return null;
  if (!Number.isSafeInteger(start) || !Number.isSafeInteger(end) ||
      start < 0 || start >= size || end < start) return null;
  return { start, end, partial: true };
}

async function localProxy(params) {
  if (!params || typeof params !== 'object') return [400, {'Content-Type':'text/plain; charset=utf-8'}, 'invalid proxy parameters'];
  let parsed;
  try { parsed = new URL(String(params.url || '')); } catch (error) {
    return [400, {'Content-Type':'text/plain; charset=utf-8'}, 'invalid media URL'];
  }
  if (parsed.protocol !== 'cenc:' || parsed.username || parsed.password) {
    return [400, {'Content-Type':'text/plain; charset=utf-8'}, 'unsupported media scheme'];
  }
  const vid = `${parsed.hostname}${parsed.pathname}`.replace(/^\/+|\/+$/g, '');
  if (!/^\d{1,24}$/.test(vid)) return [404, {'Content-Type':'text/plain; charset=utf-8'}, 'unknown episode'];
  const want = parsed.searchParams.get('q') || '';
  if (want && !QORDER.includes(want)) return [400, {'Content-Type':'text/plain; charset=utf-8'}, 'invalid quality'];
  const method = String(params.method || 'GET').toUpperCase();
  if (method !== 'GET' && method !== 'HEAD') return [405, {Allow:'GET, HEAD'}, ''];
  try {
    const fp = await ensureDecrypted(vid, want || null);
    if (!fp || !verifyMp4(fp)) return [502, {'Content-Type':'text/plain; charset=utf-8'}, 'media download or CENC decryption failed'];
    const size = fs.statSync(fp).size;
    if (!Number.isSafeInteger(size) || size <= 0) return [502, {'Content-Type':'text/plain; charset=utf-8'}, 'decrypted media is empty'];
    const requestHeaders = params.headers && typeof params.headers === 'object' ? params.headers : {};
    const rangeValue = params.range || requestHeaders.Range || requestHeaders.range || '';
    const range = parseByteRange(rangeValue, size);
    if (!range) return [416, {'Content-Range':`bytes */${size}`,'Accept-Ranges':'bytes','Content-Type':'video/mp4'}, ''];
    const length = range.end - range.start + 1;
    if (length > 16 * 1024 * 1024) return [413, {'Content-Type':'text/plain; charset=utf-8'}, 'request a smaller byte range'];
    const headers = {'Content-Type':'video/mp4','Accept-Ranges':'bytes','Content-Length':String(length)};
    if (range.partial) headers['Content-Range'] = `bytes ${range.start}-${range.end}/${size}`;
    if (method === 'HEAD') {
      return [range.partial ? 206 : 200, headers, {
        __cctvhostFileResponse:true, path:fp, offset:range.start, length,
      }];
    }
    return [range.partial ? 206 : 200, headers, {
      __cctvhostFileResponse:true, path:fp, offset:range.start, length,
    }];
  } catch (error) {
    const message = String(error && error.message || 'source failure')
      .replace(/https?:\/\/\S+/gi, '[address hidden]').slice(0, 240);
    return [502, {'Content-Type':'text/plain; charset=utf-8'}, `media proxy failed: ${message}`];
  }
}

// ---------------- CCTVHost 站点接口 ----------------
const CATS = [
  { type_id: 'real-drama', type_name: '真人短剧' },
  { type_id: 'ai-drama', type_name: 'AI 短剧' },
  { type_id: 'comic-drama', type_name: '漫剧' },
  { type_id: 'comic', type_name: '漫画' },
  { type_id: 'real-drama/urban', type_name: '都市' },
  { type_id: 'real-drama/romance', type_name: '甜宠' },
];

const site = {
  init(ext) { return null; },

  async home(filter) {
    try {
      const html = await siteHtml('/');
      return { class: CATS, list: cardsFrom(html) };
    } catch (e) {
      return { class: CATS, list: [] };
    }
  },

  async homeVod() {
    try {
      const html = await siteHtml('/');
      return { list: cardsFrom(html) };
    } catch (e) {
      return { list: [] };
    }
  },

  async category(tid, pg, filter, extend) {
    const page = Math.max(1, parseInt(pg || '1', 10));
    try {
      const html = await siteHtml(`/category/${String(tid).replace(/^\/+|\/+$/g, '')}?page=${page}`);
      return { list: cardsFrom(html), page, pagecount: 99, limit: 24, total: 9999 };
    } catch (e) {
      return { list: [], page, pagecount: page, limit: 24, total: 0 };
    }
  },

  async search(key, quick, pg) {
    const page = Math.max(1, parseInt(pg || '1', 10));
    try {
      const r = await httpText(`${SITE}/api/search/result?query=${encodeURIComponent(key)}&page=${page}`, {
        headers: { 'User-Agent': UA_WEB, 'Accept': 'application/json' },
      });
      const j = JSON.parse(r.body.toString('utf8'));
      const rows = j.searchList || j.data || [];
      const list = [];
      for (const it of rows) {
        const vd = it.video_data || {};
        const sid = String(vd.series_id || it.keyword || '');
        if (!/^\d+$/.test(sid)) continue;
        const name = vd.series_title || it.name || '';
        if (!name) continue;
        list.push({
          vod_id: sid,
          vod_name: stripTags(name),
          vod_pic: vd.series_cover || vd.cover || '',
          vod_remarks: vd.episode_cnt ? ('全' + vd.episode_cnt + '集') : '',
        });
      }
      return { list, page, pagecount: 99, limit: 24, total: 9999 };
    } catch (e) {
      return { list: [], page, pagecount: page, limit: 24, total: 0 };
    }
  },

  async detail(id) {
    const sid = String(id).replace(/^.*?_/, '');
    const html = await siteHtml('/detail?series_id=' + sid);
    const title = (html.match(/property="og:title"\s+content="([^"]*)"/) || [])[1] || '';
    const cover = (html.match(/property="og:image"\s+content="([^"]*)"/) || [])[1] || '';
    const intro = (html.match(/property="og:description"\s+content="([^"]*)"/) || [])[1] || '';
    const eps = await parseEpisodes(sid);
    const playFrom = ['红果1080p', '红果720p', '红果360p'].join('$$$');
    const one = eps.map(e => `${e.name}$${e.id}`).join('#');
    return {
      list: [{
        vod_id: sid,
        vod_name: stripTags(title),
        vod_pic: cover,
        vod_content: stripTags(intro),
        vod_remarks: eps.length ? (eps.length + '集') : '',
        vod_play_from: playFrom,
        vod_play_url: [one, one, one].join('$$$'),
      }],
    };
  },

  async play(flag, id) {
    const vid = String(id).split('~').pop();
    if (!/^\d+$/.test(vid)) return { parse: 0, url: '' };
    let q = '1080p';
    const f = String(flag || '');
    if (f.indexOf('720') >= 0) q = '720p';
    else if (f.indexOf('360') >= 0) q = '360p';

    return {
      parse: 0,
      url: `cenc://${vid}?q=${q}`,
      proxy: 1,
      format: 'mp4',
      contentType: 'video/mp4',
      header: {},
    };
  },

  localProxy,

  destroy() {
    decryptFlights.clear();
    modelCache.clear();
  },
};

module.exports = site;
