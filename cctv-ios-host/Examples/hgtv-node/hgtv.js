/**
 * 红果短剧 · CCTVHost JS 源（Node.js Mobile 运行时）
 *
 * 为什么用 require()：规范里写明「CommonJS require() 默认走 Node.js Mobile」，
 * 一旦 require 就切到完整 Node（18.20.4），从而拿到原生 AES-CTR、文件和网络接口。
 *
 * 链路（1.0.5-cctvhost-r5）：
 *   匿名设备注册（log5-applog-lf device_register，ttEncrypt 加密体，进程内有效，
 *   不跨重启复用；同一进程内多次播放共享一次注册）
 *   → 签名请求当前播放接口（novel/player/multi_video_model/v1，
 *     mixed_video_id_map + x-medusa，哈希分支严格等于 0；空响应时换
 *     api5-normal-hl.fqnovel.com 备用域名重试一次）
 *   → 解析 5 档视频模型（1080p/720p/540p/480p/360p）+ 解 spade URL（AES-128-CBC）
 *   → 派生 CENC key
 *   → 下载 + 原生 AES-CTR 逐样本解密 + 改写 moov
 *   → CCTVHost localProxy 按 Range 从资源数据目录交付给播放器
 *
 * 兼容路（网页 fallback-play-info）是付费墙：只开放前 3 集，第 4 集起 403，
 * 仅作次要兜底，不当主路。
 */
'use strict';

const http = require('node:http');
const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');
const zlib = require('node:zlib');

// ---------------- 配置 ----------------
const VERSION = '1.0.5-cctvhost-r5';
const SITE = 'https://hongguoduanju.com';
const DEVICE_REGISTER_API = 'https://log5-applog-lf.fqnovel.com/service/2/device_register/?tt_data=a&cronet_version=8d40f833_2026-03-03&ttnet_version=4.2.243.31-douyin&use_store_region_cookie=1';
const VIDEO_MODEL_API = 'https://api5-normal-sinfonlineb.fqnovel.com/novel/player/multi_video_model/v1/';
const VIDEO_MODEL_ALT_HOST = 'api5-normal-hl.fqnovel.com';
const VIDEO_MODEL_MULTI_API = 'https://reading.snssdk.com/reading/bookapi/video_tab/multi_video_model/v1/';
const UA_WEB = 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148';
const UA_APP = 'com.phoenix.read/71532 (Linux; U; Android 9; SM-N9860; Build/PQ3A.190705.10241111;tt-ok/3.12.13.20)';

// App 播放请求公共设备参数（播放签名用 7.1.3.32 / 71332 档；匿名注册另用 7.3.9.32 / 73932 档）
const DEVICE = {
  ac: 'wifi', channel: 'update_64', aid: '8662', app_name: 'novelread',
  version_code: '71332', version_name: '7.1.3.32', device_platform: 'android', os: 'android',
  ssmix: 'a', device_type: '25053RT47C', device_brand: 'Redmi', language: 'zh',
  os_api: '36', os_version: '16', manifest_version_code: '71332', resolution: '1280*2772',
  dpi: '520', update_version_code: '71332', host_abi: 'arm64-v8a', dragon_device_type: 'phone',
  pv_player: '71332', compliance_status: '0', need_personal_recommend: '1',
  player_so_load: '1', is_android_pad_screen: '0',
};

const SPADE_CONST = Buffer.from(
  '4dd4c2e6b83162090e52b3c7a6733ba41cb2462b829ab58a196b39db57177524' +
  'f49baf7f08e8d68d26a72e37c1a95a2f1f05a51892aef2949732b62a38aadd58', 'hex');

let CACHE_DIR = path.join(process.cwd(), 'hgtv-js-cache');

const modelCache = new Map();     // vid -> {t, vm}
const decryptFlights = new Map(); // vid + quality -> Promise<path|null>
const MODEL_TTL = 300 * 1000;

let deviceSession = null;
let deviceRegisterFlight = null;

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
function randomUuid() {
  if (typeof crypto.randomUUID === 'function') return crypto.randomUUID();
  const b = crypto.randomBytes(16);
  b[6] = (b[6] & 0x0f) | 0x40;
  b[8] = (b[8] & 0x3f) | 0x80;
  const h = b.toString('hex');
  return `${h.slice(0, 8)}-${h.slice(8, 12)}-${h.slice(12, 16)}-${h.slice(16, 20)}-${h.slice(20, 32)}`;
}
// ---------------- 签名与匿名设备注册 ----------------
function xGorgon(query, body, ts, rnd) {
  const sdk = Buffer.alloc(4);
  sdk.writeUInt32LE(67503104);
  const bodyBuf = body ? (Buffer.isBuffer(body) ? body : Buffer.from(body)) : null;
  const input = Buffer.concat([
    md5(query).subarray(0, 4),
    bodyBuf && bodyBuf.length ? md5(bodyBuf).subarray(0, 4) : Buffer.alloc(4),
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
  const qPart = String(url).split('?')[1] || '';
  const q = crypto.createHash('sm3').update(qPart).digest();
  const bodyBuf = body ? (Buffer.isBuffer(body) ? body : Buffer.from(body)) : null;
  const bm = bodyBuf && bodyBuf.length ? md5(bodyBuf) : Buffer.alloc(16);
  const iv = getIv(getIv(getIv(0x20230928, q), bm), le32(ts));
  const low = iv & 15;
  return low - ((((low * 171) >>> 9) * 3));
}

function selectSignedUrl(baseUrl, vals, body, ts) {
  const baseMs = Date.now();
  let query = '';
  let url = '';
  // F13/medusa 哈希是分支相关的：分支必须严格等于 0，128 次尝试内找不到就报错。
  for (let off = 0; off < 128; off++) {
    vals._rticket = String(baseMs + off);
    query = Object.keys(vals).map(k => `${pct(k)}=${pct(vals[k])}`).join('&');
    url = baseUrl + '?' + query;
    if (branchOf(url, body, ts) === 0) return { url, query, rticket: vals._rticket };
  }
  throw Error('unable to sign request: no hash branch 0 ticket');
}

function buildSignedHeaders(query, body, ts, rticket, device, extraHeaders) {
  const rnd = crypto.randomInt(0, 65536);
  const bodyBuf = body ? (Buffer.isBuffer(body) ? body : Buffer.from(body)) : null;
  const headers = {
    'User-Agent': UA_APP,
    'Accept': 'application/json; charset=utf-8,application/x-protobuf',
    'Content-Type': 'application/json; charset=UTF-8',
    'x-xs-from-web': '0',
    'x-ss-req-ticket': String(rticket),
    'sdk-version': '2',
    'x-gorgon': xGorgon(query, bodyBuf, ts, rnd),
    'x-khronos': String(ts),
    'x-ladon': be32(ts).toString('base64'),
    'x-argus': le32(ts).toString('base64'),
    'x-helios': helios(ts),
    'x-medusa': buildMedusa(query, bodyBuf, ts, device),
    'x-tt-dt': '',
  };
  if (extraHeaders && typeof extraHeaders === 'object') {
    Object.assign(headers, extraHeaders);
  }
  return headers;
}

// ---------------- x-medusa 签名（F13，移植自已验证的参考实现） ----------------
// SM3 用 Node 原生实现（本地 branchOf 已在用）；其余与参考实现逐字一致，
// 仅 buildMedusa 改为直接接受 query 字符串（调用方手里只有 query，没有完整 URL）。
const PROCESS_NONCE = crypto.randomBytes(18).toString('base64url');
const PROCESS_STARTED = Date.now();
function sm3(input) {
  return crypto.createHash('sm3').update(Buffer.isBuffer(input) ? input : Buffer.from(input)).digest();
}
function u32(value) { return Number(value) >>> 0; }
function rol32(value, count) { const n = count & 31; const x = u32(value); return u32((x << n) | (x >>> (32 - n))); }
function ror32(value, count) { const n = count & 31; const x = u32(value); return u32((x >>> n) | (x << (32 - n))); }
function zigzag(value) { const n = BigInt(value); return n < 0n ? ((-n) * 2n - 1n) : n * 2n; }
function varint(value) { let n = BigInt(value); const out = []; while (n > 127n) { out.push(Number((n & 127n) | 128n)); n >>= 7n; } out.push(Number(n)); return Buffer.from(out); }
function protoField(tag, value, type = 'string') {
  if (value === undefined || value === null || value === '') return Buffer.alloc(0);
  if (type === 'bytes' || type === 'string' || type === 'message') {
    const body = type === 'bytes' ? Buffer.from(value) : type === 'message' ? value : Buffer.from(String(value));
    return Buffer.concat([varint((BigInt(tag) << 3n) | 2n), varint(body.length), body]);
  }
  if (type === 'float') { const body = Buffer.alloc(4); body.writeFloatLE(Number(value)); return Buffer.concat([varint((BigInt(tag) << 3n) | 5n), body]); }
  return Buffer.concat([varint(BigInt(tag) << 3n), varint(type === 'sint' ? zigzag(value) : value)]);
}
function proto(fields) { return Buffer.concat(fields.map(([tag, value, type]) => protoField(tag, value, type))); }
function sumMd5(data) { let check = 0x20220420; for (let i = 0; i < 12; i += 1) { const temp = (i & 1) === 0 ? (check >>> 3) ^ check : (check >>> 5) ^ check; check = (i & 1) === 0 ? data[i] ^ (check << 7) : data[i] | (check << 11); if ((i & 1) !== 0) check = ~check; check = u32(check ^ temp); } return u32((check | 4) ^ 0x1000000); }
const BRANCH2_SV = [0xa7aefe20,0x7149f1d6,0x47e4ca07,0xe9b58f67,0x93b924de,0xc614d0f5,0x38afe0ef,0xb2bbad73,0xe24444c3,0x9d3aec9b,0xdf7b37e4,0xd8b16d40,0xf8ac31b8,0x76b9a90b,0x31d833ee,0x953fce64,0x353595a4,0x4609c13b,0x36925008,0x8c6d0925,0x5df5c177,0x1cfbf52b,0x8a4fa7f0,0x114ca35e,0x8193f984,0x7a7a8733,0x316ab4d5,0x3c20cfc9,0xa6d84453,0x3a18500c,0x798ec47a,0x97a76b28,0x66c4ff96,0x51716443,0xdd2fc3b,0xb5696da7,0xbbeb3ac5,0x5c53d204,0xd32608ce,0x7279b9ec,0xf4188ecf,0xf7d793db,0x332cc491,0xab76ae15,0x9bebe727,0x18a01384,0x5be9f8a7,0x5f90a754,0x39b663c0,0x36673c83,0x7c92f514,0x9d7d94d7,0xe2e8d9aa,0x5f7e9ea9,0x7abd4551,0x569e05da,0x40a25632,0x3df5a9a5,0xbab37d80,0x454286dc,0x3f5d4e78,0x3d7b75d,0xb1fe4af7,0xa5ab26a3];
const BRANCH2_ORDERS = Buffer.from('0f0704000908030a060b050d0e010c020f05080c0009020103070e060b0a0d04060500070c000a04080f010b0d09020e060b02050403080101070a000d0c090e0d070e0f0b0208030c0509010004060a0d0902060f0b0a040807000c0503010e0c090f07060f030e020d0405010b0a000c050a090e0802040407030f01060b000b0f0408020a0700090d06010e03050c0b060a0508020c03070f0e090d0001040906080f050800040a0b030d01020c0e090d0c0604070a03030f00080105020e01000d0f090a0b0e0402080703060c0501080a0c0f0905060b000304020e070d04080f000c0f0e0d0a01060207090503040205080d0b0a0606000e0f070c09030a08040f000b01060d0c0709030e05020a070b050f00020e0108030d0c0609040d070f08050f06040b0a0e0c090002030d0c020704010b0e0e08060f09050003','hex');
function md5V3Step(kind, a, b, c, d, m, shift, constant) { let f; if (kind === 0) f = (b & c) | ((~b) & d); else if (kind === 1) f = (b & d) | (c & (~d)); else if (kind === 2) f = b ^ c ^ d; else f = c ^ (b | (~d)); return u32(b + rol32(u32(a + f + m + constant), shift)); }
function md5SumV3(message, countV2, orders, countV1) {
  const sv = BRANCH2_SV.map((value) => ror32(value, countV1)); const start = [ror32(0x79e0f2fb, countV2), ror32(0xc8b52570, countV2), ror32(0xebc2f8cd, countV2), ror32(0x7c104d93, countV2)]; const endCount = (countV2 + 6) & 255; const end = [ror32(0x19be4866, endCount), ror32(0xe85986b4, endCount), ror32(0xe19b326e, endCount), ror32(0x71d1d7d4, endCount)]; const m = []; for (let i = 0; i < 16; i += 1) m.push(message.readUInt32LE(i * 4)); let [a,b,c,d] = start;
  const run = (kind, order, shifts, offset) => { for (let i = 0; i < 16; i += 1) { const phase = i & 3; const next = phase === 0 ? md5V3Step(kind,a,b,c,d,m[orders[offset + i]],shifts[i],sv[offset + i]) : phase === 1 ? md5V3Step(kind,d,a,b,c,m[orders[offset + i]],shifts[i],sv[offset + i]) : phase === 2 ? md5V3Step(kind,c,d,a,b,m[orders[offset + i]],shifts[i],sv[offset + i]) : md5V3Step(kind,b,c,d,a,m[orders[offset + i]],shifts[i],sv[offset + i]); if (phase === 0) a = next; else if (phase === 1) d = next; else if (phase === 2) c = next; else b = next; } };
  run(0, orders, [7,12,17,22,7,12,17,22,7,12,17,22,7,12,17,22], 0);
  run(1, orders, [5,9,14,20,5,9,14,20,5,9,14,20,5,9,14,20], 16);
  run(2, orders, [4,11,16,23,4,11,16,23,4,11,16,23,4,11,16,23], 32);
  run(3, orders, [6,10,15,21,6,10,15,21,6,10,15,21,6,10,15,21], 48);
  const ret = Buffer.alloc(16); ret.writeUInt32LE(u32((start[0] + a) ^ end[0]), 0); ret.writeUInt32LE(u32((start[1] + b) ^ end[1]), 4); ret.writeUInt32LE(u32((start[2] + c) ^ end[2]), 8); ret.writeUInt32LE(u32((start[3] + d) ^ end[3]), 12); return Buffer.concat([ret, le32(sumMd5(ret))]);
}
function branch2F13(iv, querySm3, bodyMd5, tsBytes, khronos) { const v = (iv & 13) * 86; const ivV0 = ((v >>> 15) & 255) + ((v >>> 8) & 255); const n1 = [0x8980f29b,0xeb549c7f,0xb08726db,0xd40cb5e6,0xe8f559e4][ivV0]; const countV1 = (n1 + khronos + 1) & 255; const countV2 = u32(n1 + khronos); const shift = (countV2 + 5) & 7; const seed = [0x84,0x96,0x77,0x9d,0xd4,0x15,0x0b,0xf8]; const pad = Buffer.from(seed.map((value) => ((value | (value << 8)) >> shift) & 255)); const input = Buffer.concat([querySm3,bodyMd5,tsBytes,pad,Buffer.from('a0010000','hex')]); return md5SumV3(input,countV2,BRANCH2_ORDERS.subarray(ivV0 << 6,(ivV0 + 1) << 6),countV1); }
function bxor(a, b) { const out = Buffer.alloc(Math.min(a.length, b.length)); for (let i = 0; i < out.length; i += 1) out[i] = a[i] ^ b[i]; return out; }
function hashF13(querySm3, bodyMd5, tsBytes, khronos) {
  const iv = getIv(getIv(getIv(0x20230928, querySm3), bodyMd5), tsBytes); const low = iv & 15; const ivV0 = (low * 171) >> 9; const branch = low - ivV0 * 3;
  if (branch === 2) return branch2F13(iv, querySm3, bodyMd5, tsBytes, khronos);
  if (branch !== 0) return Buffer.concat([querySm3.subarray(0, 16), bodyMd5, le32(sumMd5(Buffer.concat([querySm3, bodyMd5]))) ]);
  const ivV1List = [0xc4a78580, 0xb3c0fd39, 0xc58c5686, 0xc9aa3ba7, 0xf5a7adf2, 0x963c2ed1]; const ivV1 = ivV1List[ivV0]; const countV1 = (ivV1 + khronos + 1) & 255; const countV2 = u32(ivV1 + khronos);
  const tt02 = [0xebb64faf,0x7aadcc2,0xcf3187bf,0xe01138ff,0x6d0bfcff,0x5a30a3be,0xb41ad638,0x34180eb8,0xf233eb6f,0xb1a584cc,0xccc30dc7,0x47d1db51,0xd55653de,0x70a84fa1,0x57473c12,0xf76f0288,0x2c077f0a,0xda0dcad0,0xfbb86f6c,0xfdc4cf00,0x688a020d,0xe676c6a6,0x8cd6338b,0x1a3c8d0e,0xcce8b06b,0x6ad0ed0b,0xa0522717,0xdc71ac83,0x2285db71,0xd5b4dda6,0x736f8650,0x6560306c,0x617ce2a6,0xe423417e,0xa40e143,0x544e4032,0x88dffb2a,0x716c1ae0,0x4c467a88,0x5b23bb3,0xe1d0b866,0xbaa3dcb8,0xae3374d3,0xc3381a50,0x1702f75b,0xfe6da368,0xf0b4cf48,0x4e0ffbb8,0x72aad10d,0x26c53a3d,0xf2bce0f6,0xb4557581,0x4a257fdd,0x8c3182a2,0xab0b3b86,0x3d5dfb14,0x4f103634,0xd37b52d7,0x444eff16,0xeb0a33d1,0x6ca86f6e,0x284ba7,0x8387cfa,0x5fb37586];
  const tt = tt02.map((value) => ror32(value, countV1)); const n0 = (countV2 + 2) & 7; const seed = [0xfa,0x45,0x61,0xd7]; const pad = Buffer.from(seed.map((value) => ((value | (value << 8)) >> n0) & 255));
  const data = Buffer.concat([querySm3, bodyMd5, tsBytes, pad, Buffer.from('00000000000001a0','hex')]); const di = []; for (let i = 0; i < data.length; i += 4) di.push(data.readUInt32BE(i)); let di0 = di[0]; for (let i = 0; i < 112; i += 1) { const di1 = di[i + 1]; const di14 = di[i + 14]; const r1 = rol32(di1, 14) ^ rol32(di1, 25) ^ (di1 >>> 3); const r2 = rol32(di14, 13) ^ rol32(di14, 15) ^ (di14 >>> 10); di.push(u32(di0 + di[i + 9] + r1 + r2)); di0 = di1; }
  const init = [0x7aba4fc8,0x67166507,0x6403fa00,0x340f512f,984304912,3005047866,2874125293,2152413264].map((v) => ror32(v, countV2 & 31)); const chosen = [[101,5,7,6,3,2,1,0,5,4,3],[96,0,6,7,5,3,2,1,5,4,4],[96,7,6,2,1,4,0,5,4,3,5],[99,3,6,2,4,5,1,0,0,7,6],[96,0,5,6,7,3,1,2,5,4,4],[100,2,0,3,5,4,6,7,2,1,5]][ivV0]; let d = init.slice(); for (let i = 0; i < chosen[0]; i += 1) { const base = ivV1 + i; const n0v = di[base & 127]; const n1 = ((d[chosen[3]] ^ d[chosen[4]]) & d[chosen[1]]) ^ d[chosen[3]]; const n2 = rol32(d[chosen[1]],26)^rol32(d[chosen[1]],21)^rol32(d[chosen[1]],7); const n4 = u32(n0v+n1+n2+tt[base&63]+d[chosen[5]]); const n5=rol32(d[chosen[2]],30)^rol32(d[chosen[2]],19)^rol32(d[chosen[2]],10); const n6=(d[chosen[2]]&d[chosen[6]])|((d[chosen[2]]|d[chosen[6]])&d[chosen[7]]); const n7=u32(n5+n6); const old=d[chosen[9]]; d.unshift(d.pop()); d[chosen[10]]=u32(n7+n4); d[chosen[8]]=u32(old+n4); }
  const ret = Buffer.alloc(32); for (let i = 0; i < 8; i += 1) ret.writeUInt32BE(u32(d[i]+init[i]), i*4); const folded = bxor(ret.subarray(0,16), ret.subarray(16)); folded.copy(ret,0); return Buffer.concat([ret.subarray(0,16), le32(sumMd5(ret.subarray(0,16)))]);
}
function deviceProto(deviceId) { return proto([[1,1,'sint'],[2,2,'sint'],[3,'8662'],[4,deviceId],[5,PROCESS_NONCE],[6,'!noperm!'],[7,-888888,'sint'],[8,-888888,'sint'],[9,3,'sint'],[10,-888888,'sint'],[11,'!notset!'],[12,'Asia/Shanghai,8'],[13,'zh_CN'],[14,4,'sint'],[16,0,'float'],[17,0,'float'],[18,0,'float'],[19,0,'float'],[20,0,'float'],[21,0,'float'],[22,'16'],[23,41,'sint'],[24,36,'sint'],[25,PROCESS_STARTED,'sint'],[26,PROCESS_STARTED,'sint'],[27,PROCESS_STARTED,'sint'],[28,PROCESS_STARTED,'sint'],[29,-1,'sint'],[30,'25053RT47C'],[31,'Redmi'],[32,'25053RT47C'],[33,'25053RT47C'],[34,'Xiaomi'],[35,'Redmi'],[36,'Redmi'],[38,31,'sint']]); }
const SBOX = Buffer.from('+n0Ia5xZs0sEXznQOEqRmQBnpiCf9U2Ccybu3xhmgzOAAxn72f6uqqmwUsYL83klTni0NqxdGieeiNu9PGPsSRXBMB/cuFbUbM3KCUPINaPvHvSW0vwOcnuUhNHqRVpiAj/TEoE0K91+5ijypUYTATsh9mE3KSoN7Yyvv51cuyR2D3XkU4nhmI2xmmVwT1RMWKtub4sjxAcRDLrPoKSO2AU9FLLadMPX577Wf95IFj6FkKFVt3dCIsmGUC4X+WQxLJvxbRxEaOPpqJOXyzJX6+Vxaq3AzMfF/WAdoi1Hp+JRaV56zgpBtpWP97mH4DoGEIq1+FvV8LyS/3wvwugbQOwb2r26mJEMsiuDQTRn+wrYdrVGBVlhI3WQhyrjUBVMrLF5667llUcEaPCGPVGLD8qO5LlO8hKCvA7V9+8oJc9bXelqVQLhM76T5/WtnT45JKji+hdX0HoNCDDWuKON/QeaxB5uImSX0h2wv0VmP2zd2yeApxHcpsVS+MC2yFwAc2B7oBkTqsk1SEvTpM2fmfMQREBUfin0Bh+iq6EvPPavhWI2IX9e3yAas7Tm/3KEj2UmlFp36kN4x0rMLBRrxuh0U/zUHM4xcAMYjJY4MonxOl/X+alpt2M3WMI7w3HLnpIBigtNiJu7T21v4P6lSd5WFgntnMEt7oF92XzRLkJbTcGmXepE/UVOG6E/0YnhfS+q26utWcuxzpooyeD2cDlK1/8w9d28VzsRjbLuALbmGlp8+d7EzS6Au7lMpZ+ECMZvQmzwJ+eLOpxR+2chdUExp8ogQyq3v9l68rX4jCwjg0+PYKAEEzcU4wHFY2ZcdIHfWL1okD3SszT0GZMyKdZJrg1L2AeerB4tC0C4crp2EHGo5FYdSP7lwkeR2ocmnR+Ia8CYviUJlzOjhRZef9xuVOn3qcjow3fQgivsAmKKkg4+sA8F8/GWeDiGNhg8JM8KtFPMYWWkx5TVFX5t73kiNRJqjlIGVXtGZFCV4gzt0xcDopuZ6xz8r9Rzafpf9ywev8jh8592gHFIqpStZPuJxmDDMrNN0uBE3V+oscdoIzTJbRJ/t+sVvqnReJOgDJKk10fjisJwqyZBmnmn2BSFj8BvVtCMEbkuPOKdzw7eA11GPs04Qw8zWtkaZWwiO/wwpojqN6K0jY5RnNZA7vn4hPSul+nKCkVnVwQvg1zVxcSCtqORmB9KrJaBbssbCQivGJVJfVTt+hYxOtq4ZvWl8f4QAQZ0zGPffCgl9s6yT4vlvIdpu4YhBwA25wtQWZsc6GJYGWHyvSdeuh3mmUI9DSq13Fsp8C1MU3tqc04/df9LoTUXVXI5INOw/e8C7Hd+5CvbkMEFnnrUUmskEw==','base64');
function xorBytes(a, b) { const out = Buffer.from(a); for (let i = 0; i < out.length; i += 1) out[i] ^= b[i % b.length]; return out; }
function matrix(bytes) { return Array.from({ length: 4 }, (_v, i) => Array.from(bytes.subarray(i * 4, i * 4 + 4))); }
function flat(rows) { return Buffer.from(rows.flat()); }
function aesMix(rows) { for (let i = 0; i < 4; i += 1) { const t=rows[0][i]^rows[1][i]^rows[2][i]^rows[3][i]; const u=rows[0][i]; const xt=(x)=>((x<<1)^((x&128)?0x1b:0))&255; rows[0][i]^=t^xt(rows[0][i]^rows[1][i]); rows[1][i]^=t^xt(rows[1][i]^rows[2][i]); rows[2][i]^=t^xt(rows[2][i]^rows[3][i]); rows[3][i]^=t^xt(rows[3][i]^u); } }
class AesV3 {
  constructor(key, khronos) { this.wordSize=khronos&3; this.box=SBOX.subarray(this.wordSize*256,(this.wordSize+1)*256); this.con=[[1,0,2,3],[1,3,0,2],[0,1,3,2],[1,0,2,3]][this.wordSize]; this.con2=[[1,0,2,3],[2,0,3,1],[0,1,3,2],[1,0,2,3]][this.wordSize]; this.order=[[0,9,14,11,4,13,2,7,8,1,6,15,12,5,10,3],[0,9,14,15,4,13,2,7,8,1,6,3,12,5,10,11],[0,9,14,7,4,13,2,11,8,1,6,3,12,5,10,15],[0,9,14,11,4,13,2,7,8,1,6,15,12,5,10,3]][this.wordSize]; const init=[0xca025ddc,0x823dc546,0xc9420583,0xc298225f][this.wordSize]; const initial=Buffer.alloc(16); for(let i=0;i<4;i+=1)initial.writeUInt32LE(init,i*4); const mk=xorBytes(initial,key); const expanded=Buffer.concat([mk,Buffer.alloc(32)]); let rounds=8; for(let i=4;i<12;i+=1){let at=4*(i-1);let a=expanded[at],b=expanded[at+1],c=expanded[at+2],d=expanded[at+3];if((i&3)===0){const t=(u32(init>>((rounds&24)))^this.box[b])&255;b=this.box[c];c=this.box[d];d=this.box[a];a=t;}rounds+=2;expanded[at+4]=a^expanded[at-12];expanded[at+5]=b^expanded[at-11];expanded[at+6]=c^expanded[at-10];expanded[at+7]=d^expanded[at-9];} this.keys=Array.from({length:12},(_v,i)=>Array.from(expanded.subarray(i*4,i*4+4))); }
  add(rows,key) { for(let i=0;i<4;i+=1) for(let j=0;j<4;j+=1) rows[i][j]^=key[i][j]; }
  addCon(rows, keys) { for(let i=0;i<4;i+=1) for(let j=0;j<4;j+=1) rows[i][j]^=keys[i][this.con2[j]]; }
  sub(rows) { for(let i=0;i<4;i+=1) for(let j=0;j<4;j+=1) rows[i][j]=this.box[rows[i][j]]; const old=rows.map((x)=>x.slice()); for(let i=0;i<4;i+=1) rows[i]=old[this.con2[i]]; }
  shift(rows) { const b=flat(rows); for(let i=0;i<16;i+=1) rows[Math.floor(i/4)][i%4]=b[this.order[i]]; }
  shiftCon(rows) { const old=rows.map((x)=>x.slice()); for(let i=0;i<4;i+=1) rows[i]=this.con2.map((x)=>old[i][x]); }
  block(value) { const rows=matrix(value); this.addCon(rows,this.keys.slice(0,4)); for(let i=1;i<3;i+=1){this.sub(rows);this.shift(rows);if(i===1){this.shiftCon(rows);aesMix(rows);}this.addCon(rows,this.keys.slice(i*4));}this.add(rows,this.keys.slice(4));return flat(rows); }
  encrypt(data, iv) { const source=Buffer.from(data); const plaintext=Buffer.alloc(32); for(let i=0;i<31;i+=1){const at=i*8;const n0=(source[at]>>4)&2;const n1=n0|(source[at+1]&64);const n2=n1|((source[at+2]>>2)&1);const n3=n2|((source[at+3]<<3)&128);const n4=n3|((source[at+4]>>1)&4);const n5=n4|((source[at+5]<<3)&16);const n6=n5|((source[at+6]<<5)&32);plaintext[i]=n6|((source[at+7]>>4)&8);} plaintext[31]=1; const blocks=[]; let previous=Buffer.from(iv); for(let i=0;i<plaintext.length;i+=16){const value=this.block(xorBytes(plaintext.subarray(i,i+16),previous));blocks.push(value);previous=value;} const key=Buffer.concat(blocks); const out=Buffer.from(source); for(let i=0;i<31;i+=1){const at=i*8; const k=key[i]; out[at]&=0xdf;out[at]|=(k<<4)&32;out[at+1]&=0xbf;out[at+1]|=k&64;out[at+2]&=0xfb;out[at+2]|=(k<<2)&4;out[at+3]&=0xef;out[at+3]|=(k>>3)&16;out[at+4]&=0xf7;out[at+4]|=(k+k)&8;out[at+5]&=0xfd;out[at+5]|=(k>>3)&2;out[at+6]&=0xfe;out[at+6]|=(k>>5)&1;out[at+7]&=0x7f;out[at+7]|=(k<<4)&128;} return Buffer.concat([key.subarray(-1),out]); }
}
function xmxor(data, key) { const encoded=Buffer.alloc(data.length); for(let i=0;i<data.length;i+=1){const at=(i*4)&28;const d0=key[at],d1=key[at+1];let d2=((((data[i]<<4)|(data[i]>>>4))&255)+d0);d2=(~d2)^d1;d2=((((d2&255)<<3)|((d2&255)>>>5))&255);d2=(d2+d1)&255;d2=(d2^d0)&255;encoded[data.length-i-1]=(~d2)&255;} let last=encoded[encoded.length-1]^encoded[encoded.length-2];const first=encoded[0];encoded[0]=(~last+first)&255;encoded[1]=((encoded[0]^encoded[encoded.length-1]^254)+encoded[1])&255;encoded[2]=(encoded[2]+((last-first)^(((encoded[1]<<3)|(encoded[1]>>>5))&255)^2))&255;for(let i=0;i<encoded.length-4;i+=1){const temp=(((encoded[i+2]<<3)|(encoded[i+2]>>>5))&255)^encoded[i+1]^(i+3);encoded[i+3]=(~temp+encoded[i+3])&255;}encoded[encoded.length-1]^=encoded[encoded.length-2];let sum=0;for(let i=0;i<encoded.length-1;i+=1)sum+=encoded[i+1];encoded[0]=((encoded[0]^encoded[1])+sum)&255;return encoded; }
function keyHash(signKey, random) { const input=Buffer.concat([signKey,le32(random),signKey]); const hash=sm3(input); const d1=(random>>16)&255; let d2=((d1<<11)|(random>>>24))^(d1>>5)^d1; d2=(~d2)>>>0; return [hash,le32(d2)]; }
function buildMedusa(query, body, khronos, device) {
  const bodyMd5=body?crypto.createHash('md5').update(body).digest():Buffer.alloc(16); const querySm3=sm3(query); const ts=le32(khronos); const queryBodyTs=hashF13(querySm3,bodyMd5,ts,khronos); const nested=proto([[1,111,'sint'],[2,10,'sint'],[3,694367,'sint'],[5,586952199,'sint']]); const messageRand=Math.floor(Math.random()*0x100000000); const envLaunch=Math.floor(Math.random()*21)+100; const envPid=Math.floor(Math.random()*2000)+10001; const env=proto([[1,envLaunch,'sint'],[2,146331399,'sint'],[3,146331396,'sint'],[5,7,'sint'],[6,'v04.06.04.03-bugfix'],[7,envPid,'sint'],[12,deviceProto(device.device_id),'message'],[13,proto([[1,Math.floor(Date.now()/1000),'sint'],[2,-2,'sint'],[4,200,'sint']]),'message'],[14,device.version_name]]); const queryHash=sm3(Buffer.concat([Buffer.from(query),bodyMd5,Buffer.from('none')])); const message=proto([[1,Buffer.from('f7e85ffad7d7dc3bd62ac87057cf6118','hex'),'bytes'],[2,3,'sint'],[3,messageRand,'sint'],[4,'8662'],[5,device.device_id],[6,'1588093228'],[7,device.version_name],[8,'v04.06.04-ml-android'],[9,67503104,'sint'],[10,Buffer.from('4001000000000000','hex'),'bytes'],[12,khronos,'sint'],[13,queryBodyTs,'bytes'],[14,querySm3.subarray(0,6),'bytes'],[15,nested,'message'],[16,PROCESS_NONCE],[17,khronos,'sint'],[19,queryHash,'bytes'],[20,'none'],[21,312,'sint'],[23,env,'message'],[24,'{"cmr":16777216,"cmr2":16777216,"un_h":1879194040,"vpn":0,"kd":0,"fkd":3672518972,"pd":-1872573247,"dyn":"","do":0,"tk":true}']]); const random=Math.floor(Math.random()*0x100000000); const [hash,seed]=keyHash(Buffer.from('8ebdfa3806ecc5cee79423e6029ed82540bc2218bb7eae f71cb691f7aa8aa2f5'.replace(/ /g,''),'hex'),random); let transformed=xmxor(message,hash); transformed=Buffer.concat([Buffer.from('4001000000000000','hex'),transformed]).reverse(); for(let i=0;i<transformed.length;i+=1)transformed[i]^=seed[(~i)&3]; const check=((querySm3[0]&63)<<14)|0x18000001|((queryBodyTs[0]&63)<<8); const xmRand=Math.floor(Math.random()*0x100000000); const packed=Buffer.concat([Buffer.from([0x35]),le32(xmRand),le32(check),transformed,Buffer.from([random>>16,random>>24])]); const encrypted=new AesV3(Buffer.from('f1593376766ea98d34f31b057a9d5be4','hex'),khronos).encrypt(packed,Buffer.from('1fe109a4125283f418de9e051a969e12','hex')); const version=Buffer.from('03000000f7e85ffad7d7dc3bd62ac87057cf6118','hex'); const prefix=Buffer.alloc(20); for(let i=0;i<20;i+=4) prefix.writeUInt32LE(u32(version.readUInt32LE(i)^khronos),i); return Buffer.concat([prefix,Buffer.from([random&255,(random>>8)&255,0,1]),encrypted]).toString('base64');
}

function validDeviceIdentity(session) {
  if (!session || typeof session !== 'object') return false;
  const did = String(session.device_id || '');
  const iid = String(session.iid || session.install_id || '');
  return /^[1-9]\d{5,23}$/.test(did) && /^[1-9]\d{5,23}$/.test(iid);
}

function newAnonymousDeviceSeed() {
  const nowSec = Math.floor(Date.now() / 1000);
  return {
    cdid: randomUuid(),
    openudid: crypto.randomBytes(8).toString('hex'),
    clientudid: randomUuid(),
    req_id: randomUuid(),
    key_register_ts: nowSec,
  };
}

// 注册响应里的设备号：优先 *_str 字符串，缺失时接受安全整数。
function responseId(obj, name) {
  if (!obj || typeof obj !== 'object') return '';
  const preferred = obj[name + '_str'];
  const value = preferred === undefined || preferred === null || preferred === '' ? obj[name] : preferred;
  if (typeof value === 'number') return Number.isSafeInteger(value) && value > 0 ? String(value) : '';
  return typeof value === 'string' && /^\d{1,30}$/.test(value) && /[1-9]/.test(value) ? value : '';
}

// ttEncrypt 注册：请求体 gzip 压缩后 AES-128-CBC 加密。
// 格式：746305100000 + 32 字节随机数 + AES-CBC(SHA512(压缩体)||压缩体)，
// 密钥/IV 由 SHA512(SHA512(随机数)||KDF_SALT) 派生（KDF_SALT 即 SPADE_CONST）。
// 设备身份仅进程内有效，不写盘、不跨重启复用。
function deviceRegisterRequest(seed) {
  const s = seed || newAnonymousDeviceSeed();
  const ts = Math.floor(Date.now() / 1000);
  const nowMs = Date.now();
  const header = {
    display_name: '红果免费短剧',
    update_version_code: 73932,
    manifest_version_code: 73932,
    app_version_minor: '7.3.9.32',
    aid: 8662,
    channel: 'update_64',
    package: 'com.phoenix.read',
    app_version: '7.3.9.32',
    version_code: 73932,
    sdk_version: '3.7.0-rc.34-fanqie-xiaoshuo',
    sdk_target_version: 29,
    git_hash: '3a88f4e',
    os: 'Android',
    os_version: '16',
    os_api: 36,
    device_model: '25053RT47C',
    device_brand: 'Redmi',
    device_manufacturer: 'Redmi',
    cpu_abi: 'arm64-v8a',
    release_build: 'b5e187f',
    density_dpi: 520,
    display_density: 'mdpi',
    resolution: '1280x2772',
    language: 'zh',
    timezone: 8,
    access: 'wifi',
    not_request_sender: 0,
    carrier: 'CHINA MOBILE',
    mcc_mnc: '46000',
    rom: 'eng.root.20231116.160340',
    rom_version: 'W528JS release-keys',
    cdid: s.cdid,
    sig_hash: '56a962410c494bbaf0b58dba20cae56f',
    openudid: s.openudid,
    clientudid: s.clientudid,
    ipv6_list: [],
    region: 'CN',
    tz_name: 'Asia/Shanghai',
    tz_offset: 28800,
    sim_region: 'cn',
    sim_serial_number: [],
    oaid_may_support: false,
    req_id: s.req_id || randomUuid(),
    device_platform: 'android',
    custom: {
      account_region_src: 'fallback',
      account_region: 'cn',
      host_bit: 64,
      dragon_device_type: 'phone',
    },
    pre_installed_channel: '',
    apk_first_install_time: nowMs,
    is_system_app: 0,
    sdk_flavor: 'china',
    guest_mode: 0,
  };
  const compressed = zlib.gzipSync(Buffer.from(JSON.stringify({ magic_tag: 'ss_app_log', header, _gen_time: nowMs }), 'utf8'));
  const random = crypto.randomBytes(32);
  const derived = sha512(Buffer.concat([sha512(random), SPADE_CONST]));
  const cipher = crypto.createCipheriv('aes-128-cbc', derived.subarray(0, 16), derived.subarray(16, 32));
  const plaintext = Buffer.concat([sha512(compressed), compressed]);
  const body = Buffer.concat([Buffer.from('746305100000', 'hex'), random, cipher.update(plaintext), cipher.final()]);
  const headers = {
    'User-Agent': 'com.phoenix.read/72232 (Linux; U; Android 16; zh_CN; 25053RT47C; Build/BP2A.250605.031.A3)',
    'Accept': 'application/json',
    'Content-Type': 'application/octet-stream;tt-data=a',
    'log-encode-type': 'gzip',
    'x-ss-dp': '8662',
    'x-ss-req-ticket': String(nowMs),
    'x-vc-bdturing-sdk-version': '4.0.3.cn',
    'lc': '101',
    'sdk-version': '2',
    'passport-sdk-version': '5051452',
    'x-neptune': '-8|50:51:59:30:40:47:49:39',
    'x-ss-stub': md5(body).toString('hex').toUpperCase(),
  };
  return { url: DEVICE_REGISTER_API, method: 'POST', headers, body, seed: s, ts };
}

async function registerDevice() {
  const req = deviceRegisterRequest();
  const r = await httpText(req.url, {
    method: req.method,
    headers: req.headers,
    body: req.body,
    timeout: 20000,
  });
  if (r.status < 200 || r.status >= 300 || !r.body.length) {
    throw Error('empty device_register response');
  }
  const j = JSON.parse(r.body.toString('utf8'));
  if (Number(j.code ?? j.Code ?? 0) !== 0) {
    throw Error('device_register rejected');
  }
  const data = (j && typeof j.data === 'object' && j.data) ? j.data : {};
  const did = responseId(j, 'device_id') || responseId(data, 'device_id');
  const iid = responseId(j, 'install_id') || responseId(data, 'install_id');
  const session = {
    device_id: did,
    iid,
    cdid: req.seed.cdid,
    openudid: req.seed.openudid,
    clientudid: req.seed.clientudid,
    key_register_ts: req.ts,
    registered_at: Date.now(),
  };
  if (!validDeviceIdentity(session)) {
    throw Error('device_register returned invalid device identity');
  }
  deviceSession = session;
  return session;
}

async function ensureDeviceSession(forceRefresh = false) {
  if (!forceRefresh && validDeviceIdentity(deviceSession)) return deviceSession;
  if (deviceRegisterFlight) return deviceRegisterFlight;
  deviceRegisterFlight = (async () => {
    try {
      return await registerDevice();
    } finally {
      deviceRegisterFlight = null;
    }
  })();
  return deviceRegisterFlight;
}

function signedRequest(vid, device, host, extraHeaders) {
  const ts = Math.floor(Date.now() / 1000);
  const dev = validDeviceIdentity(device) ? device : (validDeviceIdentity(deviceSession) ? deviceSession : null);
  if (!dev) throw Error('registered device identity is required before signing playback request');
  const payload = {
    biz_param: {
      detail_page_version: 0,
      device_level: 3,
      disable_digg_stat: false,
      need_all_video_definition: true,
      need_mp4_align: false,
      use_os_player: false,
      use_server_dns: false,
      video_platform: 1024,
    },
    mixed_video_id_map: { '1004': [String(vid)] },
  };
  const body = Buffer.from(JSON.stringify(payload), 'utf8');
  const merged = Object.assign({}, DEVICE, {
    iid: String(dev.iid),
    device_id: String(dev.device_id),
    cdid: String(dev.cdid || randomUuid()),
  });
  const vals = Object.assign({}, merged, { ts: String(ts) });
  const baseUrl = 'https://' + (host || new URL(VIDEO_MODEL_API).hostname) + '/novel/player/multi_video_model/v1/';
  const { url, query, rticket } = selectSignedUrl(baseUrl, vals, body, ts);
  const headers = buildSignedHeaders(query, body, ts, rticket, merged, Object.assign({
    'x-tt-store-region': 'cn',
    'x-tt-store-region-src': 'did',
  }, extraHeaders));
  return { url, method: 'POST', headers, body, device: dev };
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

function htmlAttributes(tag) {
  const attrs = {};
  const re = /([^\s=<>/]+)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))/g;
  let match;
  while ((match = re.exec(tag))) attrs[match[1].toLowerCase()] = match[2] ?? match[3] ?? match[4] ?? '';
  return attrs;
}

function cardCover(chunk) {
  const tags = chunk.match(/<(?:img|source)\b[^>]*>/gi) || [];
  const covers = [];
  for (const tag of tags) {
    const attrs = htmlAttributes(tag);
    const cls = attrs.class || '';
    const alt = attrs.alt || '';
    const candidates = [attrs['data-src'], attrs['data-original'], attrs['data-lazy-src'], attrs.src, attrs.srcset]
      .filter(Boolean);
    if (/\bempty\b|placeholder|loading/i.test(cls) || /empty_play/i.test(candidates.join(' '))) continue;
    const isImage = /^<img\b/i.test(tag);
    // Prefer a real img (usually JPEG) over its WebP <source>; skip generic
    // loading placeholders that appear before the actual cover in each card.
    covers.push({ score: isImage ? (alt ? 3 : 2) : 1, urls: candidates });
  }
  covers.sort((a, b) => b.score - a.score);
  for (const cover of covers) {
    for (const candidate of cover.urls) {
      const first = candidate.split(',')[0].trim().split(/\s+/)[0]
        .replace(/&amp;/g, '&').replace(/\\u0026/g, '&');
      const url = first.startsWith('//') ? 'https:' + first : first;
      if (/^https?:\/\//i.test(url) && !/empty_play|placeholder/i.test(url)) return url;
    }
  }
  return '';
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
    const cover = cardCover(chunk);
    const ep = chunk.match(/class="[^"]*(?:pc-episode|m-episode|episode)[^"]*"[^>]*>(.*?)</s);
    out.push({
      vod_id: sid,
      vod_name: title,
      vod_pic: cover,
      vod_remarks: ep ? stripTags(ep[1]) : '',
    });
  }
  return out;
}

function routerData(html) {
  const scripts = /<script\b[^>]*>([\s\S]*?)<\/script\s*>/gi;
  let match;
  while ((match = scripts.exec(html))) {
    const script = match[1];
    const assignment = /^\s*(?:(?:window|globalThis)\.)?_ROUTER_DATA\s*=\s*/.exec(script);
    if (!assignment || script[assignment[0].length] !== '{') continue;
    const start = assignment[0].length;
    let depth = 0, quoted = false, escaped = false;
    for (let i = start; i < script.length && i - start < 4 * 1024 * 1024; i++) {
      const ch = script[i];
      if (quoted) {
        if (escaped) escaped = false;
        else if (ch === '\\') escaped = true;
        else if (ch === '"') quoted = false;
      } else if (ch === '"') quoted = true;
      else if (ch === '{' || ch === '[') depth++;
      else if (ch === '}' || ch === ']') {
        if (--depth === 0) {
          try {
            const value = JSON.parse(script.slice(start, i + 1));
            if (value && value.loaderData && typeof value.loaderData === 'object') return value;
          } catch (error) { }
          break;
        }
      }
    }
  }
  return null;
}

function detailSeries(html, sid) {
  const router = routerData(html);
  for (const key of ['detail_page', 'detail_$']) {
    const page = router && router.loaderData[key];
    const series = page && (page.seriesDetail || page.series_detail);
    if (series && String(series.series_id || series.seriesId || series.id) === sid) return series;
  }
  return null;
}

function episodesFrom(html, sid) {
  const series = detailSeries(html, sid);
  const rows = series && (series.vid_list || series.video_list || series.videoList || series.episodes);
  if (Array.isArray(rows)) {
    const episodes = [], seen = new Set();
    for (const row of rows) {
      const item = row && typeof row === 'object' ? row : null;
      const raw = item ? (item.vid || item.video_id || item.videoId || item.item_id || item.id) : row;
      if (typeof raw !== 'string' && !Number.isSafeInteger(raw)) continue;
      const eid = String(raw);
      if (!/^\d{1,24}$/.test(eid) || seen.has(eid)) continue;
      seen.add(eid);
      const title = item && (item.title || item.name);
      episodes.push({ name: String(title || ('第' + (episodes.length + 1) + '集')).replace(/[$#\r\n]/g, ' '), id: eid });
    }
    if (episodes.length) return episodes;
  }
  const order = new Map();
  const re = new RegExp('/player/' + sid + '/(\\d{15,24})(?!\\d)', 'g');
  let m, idx = 0;
  while ((m = re.exec(html))) {
    if (!order.has(m[1])) order.set(m[1], ++idx);
  }
  return Array.from(order.entries()).map(([eid, n]) => ({ name: '第' + n + '集', id: eid }));
}

async function parseEpisodes(sid, html) {
  const series = detailSeries(html || '', sid);
  const hasRows = series && ['vid_list', 'video_list', 'videoList', 'episodes'].some(key => Array.isArray(series[key]));
  if (hasRows) {
    const episodes = episodesFrom(html, sid);
    if (episodes.length) return episodes;
  }
  // Detail pages show only a few navigation links when SSR data is absent.
  // Give the player catalogue a chance to supply the full list first.
  const playerEpisodes = episodesFrom(await siteHtml('/player/' + sid), sid);
  return playerEpisodes.length ? playerEpisodes : episodesFrom(html || '', sid);
}

// ---------------- 视频模型（签名接口） ----------------
function parseVideoModelResponse(j, vid) {
  if (!j || typeof j !== 'object') throw Error('invalid video model JSON');
  if (j.code !== 0 && j.code != null) throw Error('video model request rejected');
  let data = (j.data && typeof j.data === 'object') ? j.data : {};
  if (Array.isArray(data)) {
    const matching = data.find(x => x && typeof x === 'object' && String(x.item_id || x.id || x.vid) === String(vid));
    data = matching || (data[0] && typeof data[0] === 'object' ? data[0] : {});
  }
  const models = (data.video_model_data && typeof data.video_model_data === 'object') ? data.video_model_data : null;
  let ent = null;
  if (Array.isArray(models)) {
    const matching = models.find(x => x && typeof x === 'object' && String(x.item_id || x.id || x.vid) === String(vid));
    ent = matching || (models[0] && typeof models[0] === 'object' ? models[0] : null);
  } else if (models && typeof models === 'object') {
    ent = models[String(vid)] || Object.values(models).find(value => value && typeof value === 'object');
  }
  if (!ent && data[String(vid)] && typeof data[String(vid)] === 'object') ent = data[String(vid)];
  if (!ent) ent = data;
  let vm = ent && ent.video_model;
  if (typeof vm === 'string') {
    try { vm = JSON.parse(vm); } catch (error) { vm = null; }
  }
  if (!vm && typeof data.video_model === 'string') {
    try { vm = JSON.parse(data.video_model); } catch (error) { vm = null; }
  } else if (!vm && data.video_model && typeof data.video_model === 'object') {
    vm = data.video_model;
  }
  if (!vm && (data.video_list || data.dynamic_video_list || data.dynamic_video)) {
    vm = data;
  }
  if (!vm || typeof vm !== 'object') throw Error('video model missing');
  if (!vm.key_seed && ent && ent.key_seed) vm.key_seed = ent.key_seed;
  if (!vm.key_seed && data.key_seed) vm.key_seed = data.key_seed;
  const dyn = (vm.dynamic_video && typeof vm.dynamic_video === 'object') ? vm.dynamic_video : null;
  const rows = vm.video_list || vm.dynamic_video_list || (dyn && (dyn.dynamic_video_list || dyn.video_list));
  if (Array.isArray(rows)) {
    const normalized = {};
    rows.forEach((item, index) => {
      if (item && typeof item === 'object') normalized[String(index)] = item;
    });
    vm.video_list = normalized;
  } else if (rows && typeof rows === 'object') {
    vm.video_list = rows;
  }
  if (!vm.video_list || typeof vm.video_list !== 'object' || !Object.keys(vm.video_list).length) {
    throw Error('video model contains no qualities');
  }
  return vm;
}

async function fetchModel(vid) {
  const hit = modelCache.get(String(vid));
  if (hit && Date.now() - hit.t < MODEL_TTL) return hit.vm;
  let dev = null;
  // 最多两次：主域名一次；失败（空响应、解析失败或模型缺失）则重新注册设备，
  // 再到备用域名 api5-normal-hl.fqnovel.com 重试一次。
  for (let attempt = 0; attempt < 2; attempt++) {
    try {
      if (!dev) dev = await ensureDeviceSession(false);
      const host = attempt === 0 ? new URL(VIDEO_MODEL_API).hostname : VIDEO_MODEL_ALT_HOST;
      const s = signedRequest(vid, dev, host, attempt === 0 ? null : { 'Connection': 'close' });
      const r = await httpText(s.url, {
        method: s.method,
        headers: s.headers,
        body: s.body,
        timeout: 25000,
      });
      if (r.status < 200 || r.status >= 300 || !r.body.length) {
        throw Error('empty video model response');
      }
      const j = JSON.parse(r.body.toString('utf8'));
      const vm = parseVideoModelResponse(j, vid);
      modelCache.set(String(vid), { t: Date.now(), vm });
      return vm;
    } catch (error) {
      if (attempt === 0) {
        try { dev = await ensureDeviceSession(true); } catch (e) { dev = null; }
        await new Promise(resolve => setTimeout(resolve, 400));
        continue;
      }
      break;
    }
  }
  // 两次都失败：本次用的设备身份可能已被服务端静默丢弃，丢弃缓存，
  // 让下一次播放重新注册新设备，而不是反复用同一个失效身份请求。
  deviceSession = null;
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

function resolveMediaUrl(it, vm) {
  const seedS = (vm && vm.key_seed) || (it && it.key_seed) || '';
  const seed = seedS ? Buffer.from(seedS, 'base64') : Buffer.alloc(0);
  const candidates = [it && it.main_url, it && it.backup_url_1, it && it.backup_url_2, it && it.backup_url]
    .filter(u => typeof u === 'string' && u.length > 0);
  for (const rawUrl of candidates) {
    if (rawUrl.startsWith('http://') || rawUrl.startsWith('https://')) return rawUrl;
    if (seed.length) {
      const dec = decryptSpade(rawUrl, seed);
      if (dec) return dec;
    }
    try {
      const plain = Buffer.from(rawUrl, 'base64').toString('utf8').trim();
      if (plain.startsWith('http://') || plain.startsWith('https://')) return plain;
    } catch (error) { }
  }
  return null;
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

function videoMetadata(item) {
  const value = item.video_meta || item.videoMeta || item.meta;
  if (value && typeof value === 'object' && !Array.isArray(value)) return value;
  if (typeof value !== 'string' || value.length > 65536) return {};
  try {
    const parsed = JSON.parse(value);
    if (parsed && typeof parsed === 'object' && !Array.isArray(parsed)) return parsed;
  } catch (error) { }
  // Some App responses use Python dictionary syntax. Read only scalar fields;
  // never evaluate the response as JavaScript or Python code.
  const fields = {};
  const re = /(['"])(definition|quality_name|quality|vtype|vwidth|vheight)\1\s*:\s*(?:(['"])([^'"\\]*)\3|(-?\d+(?:\.\d+)?))(?=\s*[,}])/g;
  let match;
  while ((match = re.exec(value))) fields[match[2]] = match[4] === undefined ? Number(match[5]) : match[4];
  return fields;
}

function videoQuality(item, fallback) {
  const meta = videoMetadata(item);
  for (const value of [item.definition, meta.definition, item.quality_name, meta.quality_name, item.quality, meta.quality]) {
    if (value == null) continue;
    let q = String(value).toLowerCase().replace(/\s/g, '');
    if (/^\d+$/.test(q)) q += 'p';
    if (/^\d{3,4}p$/.test(q)) return q;
  }
  const gear = String(item.gear_des_key || '');
  const match = /(?:^|\|)4:(\d{3,4}p)(?=\||$)/i.exec(gear);
  if (match) return match[1].toLowerCase();
  const w = Number(item.vwidth || meta.vwidth || 0);
  const h = Number(item.vheight || meta.vheight || 0);
  const shortSide = (w > 0 && h > 0) ? Math.min(w, h) : 0;
  if ([360, 480, 540, 720, 1080].includes(shortSide)) return `${shortSide}p`;
  return String(fallback || '').toLowerCase();
}

function qualityCandidates(vm) {
  const vl = (vm && vm.video_list) || {};
  const cands = [];
  for (const k of Object.keys(vl)) {
    const it = vl[k] || {};
    const q = videoQuality(it, k);
    if (!/^(?:\d{1,4}|\d{3,4}p)$/.test(q)) continue;
    const gear = String(it.gear_des_key || '').toLowerCase();
    const meta = videoMetadata(it);
    const bad = (/bytevc2|bvc2/.test(gear + ' ' + String(meta.vtype || it.vtype || '').toLowerCase())) ? 1 : 0;
    const order = /^\d{3,4}p$/.test(q) ? -parseInt(q, 10) : 1;
    cands.push({ bad, order, q, it });
  }
  cands.sort((x, y) => (x.bad - y.bad) || (x.order - y.order));
  return cands.filter(c => c.bad === 0);
}

function pickBest(vm, want) {
  const cands = qualityCandidates(vm);
  return (want ? cands.find(c => c.q === want) : cands[0]) || null;
}

// ---------------- MP4 / CENC ----------------
function readBox(d, off) {
  if (off < 0 || off + 8 > d.length) return null;
  let size = d.readUInt32BE(off);
  const type = d.toString('ascii', off + 4, off + 8);
  let header = 8;
  if (size === 1) {
    if (off + 16 > d.length) return null;
    size = Number(d.readBigUInt64BE(off + 8)); header = 16;
  }
  else if (size === 0) size = d.length - off;
  if (!Number.isSafeInteger(size) || size < header || off + size > d.length) return null;
  return { offset: off, size, type, header, body: off + header };
}

function boxesIn(data, start, end) {
  const boxes = [];
  for (let pos = start; pos < end;) {
    const box = readBox(data, pos);
    if (!box || pos + box.size > end) return null;
    boxes.push(box);
    pos += box.size;
  }
  return boxes;
}

function childBox(data, parent, kind) {
  if (!parent) return null;
  return (boxesIn(data, parent.body, parent.offset + parent.size) || []).find(b => b.type === kind) || null;
}

function sampleEntries(data, moov) {
  const entries = [];
  for (const track of boxesIn(data, moov.body, moov.offset + moov.size) || []) {
    if (track.type !== 'trak') continue;
    const mdia = childBox(data, track, 'mdia');
    const minf = childBox(data, mdia, 'minf');
    const stbl = childBox(data, minf, 'stbl');
    const stsd = childBox(data, stbl, 'stsd');
    if (stsd && stsd.body + 8 <= stsd.offset + stsd.size) {
      entries.push(...(boxesIn(data, stsd.body + 8, stsd.offset + stsd.size) || []));
    }
  }
  return entries;
}

function sampleChildStart(data, entry) {
  if (['encv', 'hvc1', 'hev1', 'avc1', 'avc3', 'vp09', 'av01'].includes(entry.type)) return entry.body + 78;
  if (['enca', 'mp4a', 'ac-3', 'ec-3', 'Opus', 'alac'].includes(entry.type)) {
    if (entry.body + 28 > entry.offset + entry.size) return entry.offset + entry.size + 1;
    const version = data.readUInt16BE(entry.body + 8);
    return entry.body + 28 + (version === 1 ? 16 : version === 2 ? 36 : 0);
  }
  return null;
}

function restoreSampleFormats(header, moov) {
  for (const entry of sampleEntries(header, moov)) {
    if (entry.type !== 'encv' && entry.type !== 'enca') continue;
    const start = sampleChildStart(header, entry);
    const sinf = (boxesIn(header, start, entry.offset + entry.size) || []).find(b => b.type === 'sinf');
    const frma = childBox(header, sinf, 'frma');
    if (!frma || frma.size - frma.header !== 4) throw Error('encrypted sample entry has no original codec');
    header.copy(header, entry.offset + 4, frma.body, frma.body + 4);
  }
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
  // Keep searches inside this track so an unencrypted audio track cannot borrow
  // the following video track's sample/auxiliary tables.
  moov = moov.subarray(track.offset, track.offset + track.size);
  const stbl = findBox(moov, 'stbl', track.header);
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
      h.write('free', pos, 'latin1');
      h.fill(0, pos + 4, end);
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
  restoreSampleFormats(header, moov);
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
function validBoxTree(data, start, end, state, depth = 0) {
  if (depth > 24 || start > end) return false;
  const boxes = boxesIn(data, start, end);
  if (!boxes) return false;
  const containers = ['moov', 'trak', 'mdia', 'minf', 'stbl', 'edts', 'dinf', 'mvex', 'moof', 'traf', 'sinf', 'schi'];
  for (const box of boxes) {
    if (box.type === 'trak') state.tracks++;
    if (box.type === 'mdat') state.media++;
    if (box.type === 'encv' || box.type === 'enca') return false;
    const boxEnd = box.offset + box.size;
    if (containers.includes(box.type)) {
      if (!validBoxTree(data, box.body, boxEnd, state, depth + 1)) return false;
    } else if (box.type === 'stsd') {
      if (box.body + 8 > boxEnd) return false;
      const entries = boxesIn(data, box.body + 8, boxEnd);
      if (!entries || entries.length !== data.readUInt32BE(box.body + 4)) return false;
      state.descriptions += entries.length;
      for (const entry of entries) {
        if (entry.type === 'encv' || entry.type === 'enca') return false;
        const childStart = sampleChildStart(data, entry);
        if (childStart !== null && !validBoxTree(data, childStart, entry.offset + entry.size, state, depth + 1)) return false;
      }
    }
  }
  return true;
}

function verifyMp4(p) {
  try {
    const size = fs.statSync(p).size;
    if (size < 32 || size > 32 * 1024 * 1024) return false;
    const data = fs.readFileSync(p);
    const top = boxesIn(data, 0, data.length);
    if (!top || !top.length || top[0].type !== 'ftyp' || !top.some(b => b.type === 'moov')) return false;
    const state = { tracks: 0, media: 0, descriptions: 0 };
    return validBoxTree(data, 0, data.length, state) && state.tracks > 0 && state.media > 0 && state.descriptions > 0;
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
  if (!pick) throw Error(want ? `requested quality ${want} is unavailable for this episode` : 'no compatible video quality is available');
  const q = pick.q;
  const it = pick.it;
  const dst = path.join(CACHE_DIR, `${vid}_${q}.mp4`);
  if (fs.existsSync(dst) && verifyMp4(dst)) return dst;
  if (fs.existsSync(dst)) { try { fs.unlinkSync(dst); } catch (e) { } }

  const url = resolveMediaUrl(it, vm);
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
  if (want && !/^(?:\d{1,4}|\d{3,4}p)$/.test(want)) return [400, {'Content-Type':'text/plain; charset=utf-8'}, 'invalid quality'];
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
    const headers = {'Content-Type':'video/mp4','Accept-Ranges':'bytes','Content-Length':String(length)};
    if (range.partial) headers['Content-Range'] = `bytes ${range.start}-${range.end}/${size}`;
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
  init(ext) {
    if (ext && typeof ext === 'object' && ext.dataDir) {
      CACHE_DIR = path.join(String(ext.dataDir), 'hgtv-js-cache');
    }
    return null;
  },

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
    if (!/^\d{1,24}$/.test(sid)) throw Error('invalid series ID');
    const html = await siteHtml('/detail?series_id=' + sid);
    const series = detailSeries(html, sid) || {};
    const title = series.series_name || series.series_title || (html.match(/property="og:title"\s+content="([^"]*)"/) || [])[1] || '';
    const cover = series.series_cover || (html.match(/property="og:image"\s+content="([^"]*)"/) || [])[1] || '';
    const intro = series.series_intro || (html.match(/property="og:description"\s+content="([^"]*)"/) || [])[1] || '';
    const eps = await parseEpisodes(sid, html);
    const one = eps.map(e => `${e.name}$${sid}~${e.id}`).join('#');
    const expected = Number(series.episode_cnt || series.episode_count || (series.series_episode_info || {}).episode_total_cnt);
    return {
      list: [{
        vod_id: sid,
        vod_name: stripTags(title),
        vod_pic: cover,
        vod_content: stripTags(intro),
        vod_remarks: eps.length ? (eps.length + '集') : '',
        vod_play_from: '官网完整播放',
        vod_play_url: one,
        catalog_complete: Number.isSafeInteger(expected) && expected > 0 ? expected === eps.length : null,
      }],
    };
  },

  async play(flag, id) {
    const vid = String(id).split('~').pop();
    if (!/^\d+$/.test(vid)) return { parse: 0, url: '' };
    const f = String(flag || '');
    if (/试看|preview/i.test(f)) return { parse: 0, url: '', preview: true, msg: '此 JS 源未提供公开试看；请选择官网完整播放' };
    try {
      const vm = await fetchModel(vid);
      const requested = (f.match(/\d{3,4}p/i) || [])[0];
      const pick = pickBest(vm, requested && requested.toLowerCase());
      if (!pick) return { parse: 0, url: '', msg: requested ? `此集未提供 ${requested} 清晰度` : '此集暂无可用的兼容视频清晰度' };
      const seen = new Set();
      const alternates = qualityCandidates(vm).filter(c => {
        if (seen.has(c.q)) return false;
        seen.add(c.q); return true;
      }).map(c => ({ name: /^\d+$/.test(c.q) ? '档位 ' + c.q : c.q, url: `cenc://${vid}?q=${c.q}`, proxy: true, format: 'mp4', contentType: 'video/mp4' }));
      return {
        parse: 0,
        url: `cenc://${vid}?q=${pick.q}`,
        proxy: 1,
        format: 'mp4',
        contentType: 'video/mp4',
        header: {},
        preview: false,
        alternates,
      };
    } catch (error) {
      return { parse: 0, url: '', msg: '视频模型暂时不可用，请稍后重试' };
    }
  },

  localProxy,

  destroy() {
    decryptFlights.clear();
    modelCache.clear();
    deviceSession = null;
    deviceRegisterFlight = null;
  },
};

module.exports = site;
