import assert from 'node:assert/strict'
import vm from 'node:vm'
import { readFileSync } from 'node:fs'
import { createCKey } from './yangshipin/upstream/ckey.js'
import { randomBytes, randomUUID } from 'node:crypto'
const timers = new Map(), requests = new Map(), calls = []
let next = 1, clock = Date.now(), sequence = 100
const media = () => `#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:6\n#EXT-X-MEDIA-SEQUENCE:${sequence}\n#EXT-QQHLS-SEGMENT_RANGE:${sequence-5}-${sequence+2}\n${[0,1,2].map(i=>`#EXTINF:6,\n${sequence+i}.ts?token=one\n`).join('')}`
const sandbox = {
  __hostLog() {}, __hostUUID: randomUUID, __hostRandomBytes: n => [...randomBytes(n)],
  __hostSetTimeout(fn, ms) { const key = next++; timers.set(key, setTimeout(() => { timers.delete(key); fn() }, ms)); return key },
  __hostClearTimeout(key) { clearTimeout(timers.get(key)); timers.delete(key) },
  __hostAbortFetch(key) { const item = requests.get(key); if(item) {clearTimeout(item.timer);requests.delete(key);item.callback({error:'AbortError'})} },
  __hostFetch(url, rawOptions, callback) {
    calls.push({url, options:JSON.parse(rawOptions)});const key=next++
    const timer = setTimeout(() => {
      requests.delete(key)
      let body, status = 200
      if (url.startsWith('https://bkliveinfo.ysp.cctv.cn/')) body=JSON.stringify({iretcode:0,playurl:'https://test.cctv.cn/master.m3u8'})
      else if(url.endsWith('/master.m3u8')) body='#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1000000\nlive/index.m3u8\n'
      else if(url.endsWith('/live/index.m3u8')) body=media()
      else {status=404;body='not found'}
      callback({status,url,headers:{'Content-Type':'application/vnd.apple.mpegurl'},base64:Buffer.from(body).toString('base64')})
    },0)
    requests.set(key,{timer,callback});return key
  },
}
const context=vm.createContext(sandbox)
vm.runInContext('Date.now = () => __clock()', context)
sandbox.__clock=()=>clock
vm.runInContext(readFileSync(new URL('../GeneratedJS/yangshipin.bundle.js',import.meta.url),'utf8'),context)
const invoke=(name,payload={})=>new Promise(resolve=>sandbox.__cctvInvoke(name,payload,raw=>resolve(JSON.parse(raw))))
try {
  const catalog=(await invoke('catalog')).result
  assert.equal(catalog.length,63)
  assert.equal((await invoke('start')).result.browser,false)
  const options={now:1700000000000,guid:'0123456789abcdef0123456789abcdef',uid:'ABCDEF12',randomBytes:n=>Buffer.alloc(n,0x11)}
  const expected=createCKey('2024078201',options)
  const actual=vm.runInContext(`CCTVHostJS.ckey({channelId:'2024078201',options:{now:1700000000000,guid:'0123456789abcdef0123456789abcdef',uid:'ABCDEF12',randomBytes:n=>new Uint8Array(n).fill(0x11)}})`,context)
  assert.equal(actual.cKey,expected.cKey,'original Node cKey and bundled JS cKey agree byte-for-byte')
  const first=await invoke('resolve',{ref:'ysp-cctv1',userAgent:'CCTVHost/1'})
  assert.equal(first.ok,true)
  assert.match(first.result.manifestText,/https:\/\/test\.cctv\.cn\/live\/100\.ts/)
  assert.equal(calls.filter(x=>x.url.startsWith('https://bkliveinfo')).length,1)
  const query=new URL(calls[0].url).searchParams
  assert.equal(query.get('cnlid'),'2024078201');assert.equal(query.get('livepid'),'600001859');assert.equal(query.get('spvcode'),Buffer.from('H(30:1080,60:1080|30:1080,60:1080)').toString('base64'))
  clock+=6000;sequence=103
  const second=await invoke('resolve',{ref:'ysp-cctv1',userAgent:'CCTVHost/1'})
  assert.match(second.result.manifestText,/105\.ts/)
  assert.notEqual(first.result.manifestText,second.result.manifestText,'live manifest advances without re-signing every reload')
  assert.equal(calls.filter(x=>x.url.startsWith('https://bkliveinfo')).length,1)
  const before=calls.length
  const vip=await invoke('resolve',{ref:'ysp-vip-cctvsjdl'})
  assert.equal(vip.ok,false);assert.equal(calls.length,before,'unsupported browser branch does not make fake anonymous requests')
  await invoke('stop')
  assert.equal(timers.size,0,'stop clears original resolver refresh timers')
  console.log('PASS: original JS modules execute without Node globals; 63-channel catalog, exact cKey, fetch/URL/Buffer, HLS master/media, advancing manifests, VIP capability boundary, timer shutdown')
} finally {
  sandbox.CCTVHostJS.stop()
  for(const timer of timers.values())clearTimeout(timer)
  for(const request of requests.values())clearTimeout(request.timer)
}
