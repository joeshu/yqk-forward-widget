import assert from 'node:assert/strict'
import {readFileSync} from 'node:fs'
import vm from 'node:vm'
import {randomBytes,randomUUID} from 'node:crypto'
const source=readFileSync(new URL('../../Resources/BuiltinMedia/dsx-drpy.js',import.meta.url),'utf8')
const manifest='#EXTM3U\n#EXT-X-TARGETDURATION:6\n#EXTINF:6,\nsegment.ts\n'
let errorPage=false
const context=vm.createContext({__hostLog(){},__hostUUID:randomUUID,__hostRandomBytes:n=>[...randomBytes(n)],__hostStorage(){return null},__hostListPackageFiles:()=>['rule.js'],__hostReadPackageFile:()=>source,
 __hostFetchSync(url){if(url.includes('/logs'))return {code:200,headers:{},content:JSON.stringify({code:1,data:[]})};return {code:errorPage?403:200,headers:{'Content-Type':errorPage?'text/html':'application/vnd.apple.mpegurl'},content:errorPage?'<html>denied</html>':manifest,url}},
 __hostSetTimeout:setTimeout,__hostClearTimeout:clearTimeout})
vm.runInContext(readFileSync(new URL('../../GeneratedJS/js-runtime.bundle.js',import.meta.url),'utf8'),context)
const invoke=(op,payload={})=>new Promise(resolve=>context.__cctvInvoke(op,payload,raw=>resolve(JSON.parse(raw))))
let result=await invoke('start',{entry:'rule.js',moduleType:'script',protocol:'drpy'})
assert.equal(result.ok,true,JSON.stringify(result))
const meta={v:1,u:'https://fixture.test/stream?sig=a%2Bb',c:'',p:[],h:{Referer:'https://fixture.test/'},s:false,m:'auto'}
const token='dsxplay:'+Buffer.from(JSON.stringify(meta)).toString('base64url')
result=await invoke('play',{id:token,lineId:'fixture'})
if(typeof result.result==='string')result.result=JSON.parse(result.result);assert.equal(result.ok,true,JSON.stringify(result));assert.equal(result.result.url,meta.u);assert.equal(result.result.format,'hls');assert.equal(result.result.header.Referer,meta.h.Referer)
errorPage=true
meta.u='https://fixture.test/error.m3u8';meta.p=['https://fixture.test/parser?url=']
result=await invoke('play',{id:'dsxplay:'+Buffer.from(JSON.stringify(meta)).toString('base64url'),lineId:'fixture'})
if(typeof result.result==='string')result.result=JSON.parse(result.result)
assert.ok(!result.ok||!result.result.url||result.result.parse===1,JSON.stringify(result))
console.log('DSX drpy runtime playback passed')
