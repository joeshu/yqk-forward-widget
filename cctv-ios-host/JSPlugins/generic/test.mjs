import assert from 'node:assert/strict'
import {readFileSync} from 'node:fs'
import {randomBytes,randomUUID,createHash} from 'node:crypto'
import vm from 'node:vm'

let files={}
const timers=new Map(),requests=[]
const storage=new Map()
let next=1
const host={
  __hostLog(){},__hostUUID:randomUUID,__hostRandomBytes:n=>[...randomBytes(n)],
  __hostListPackageFiles:()=>Object.keys(files),__hostReadPackageFile:path=>{if(!Object.hasOwn(files,path))throw Error('missing '+path);return files[path]},
  __hostStorage(action,key,value){if(action==='get')return storage.get(key)||null;if(action==='remove')storage.delete(key);else storage.set(key,value);return value},
  __hostFetchSync(url,options){return {code:200,url,headers:{'Content-Type':'text/html'},content:'<div class="list"><a href="/detail/1"><img src="https://fixture.test/p.jpg"><span class="remark">HD</span>Rule movie</a></div>'}},
  __hostSetTimeout(fn,ms){const id=next++;timers.set(id,setTimeout(()=>{timers.delete(id);fn()},ms));return id},
  __hostClearTimeout(id){clearTimeout(timers.get(id));timers.delete(id)},__hostAbortFetch(){},
  __hostFetch(url,options,callback){const request={url,...JSON.parse(options)};if(request.bodyBase64)request.body=Buffer.from(request.bodyBase64,'base64').toString();requests.push(request);const headers={'Content-Type':'application/json'};if(url.endsWith('/login'))headers['Set-Cookie']='sid=fixture; Path=/; HttpOnly';setTimeout(()=>callback({status:200,url,headers,base64:Buffer.from(JSON.stringify({received:request.body,cookie:request.headers?.Cookie||request.headers?.cookie||''})).toString('base64')}),0);return next++},
}
const context=vm.createContext(host)
vm.runInContext(readFileSync(new URL('../../GeneratedJS/js-runtime.bundle.js',import.meta.url),'utf8'),context)
const invoke=(op,payload={})=>new Promise(resolve=>host.__cctvInvoke(op,payload,raw=>resolve(JSON.parse(raw))))
try{
  files={
    'index.js':`import {label} from './helpers/names.js';import {createHash} from 'node:crypto';import * as cheerio from 'cheerio';
      export default {async init(){const r=await fetch('https://fixture.test/init',{method:'POST',headers:{'X-Test':'yes'},body:'original-js'});this.ready=(await r.json()).received},
        home(){return {categories:[{id:'movies',name:label}],items:[{id:'one',name:cheerio.load('<p>Film</p>')('p').text()}]}},
        search({keyword,page}){return {page,pagecount:3,list:[{id:createHash('sha256').update(keyword).digest('hex'),name:this.ready}]}},
        detail({id}){return {id,name:label,lines:[{id:'main',name:'Main',episodes:[{id:'opaque?$value',name:'First'}]}]}},
        play({id,lineId}){return {url:'https://fixture.test/'+id,headers:{Referer:lineId}}}}
    `,
    'helpers/names.js':`export const label='中文影视'`,
  }
  let reply=await invoke('start',{entry:'index.js',moduleType:'esm',protocol:'cctvhost.media/1'})
  assert.equal(reply.ok,true,JSON.stringify(reply))
  assert.deepEqual(requests[0],{url:'https://fixture.test/init',method:'POST',headers:{'X-Test':'yes'},body:'original-js'})
  assert.equal((await invoke('home')).result.items[0].name,'Film')
  reply=await invoke('search',{keyword:'hello',page:2})
  assert.equal(reply.result.page,2)
  assert.equal(reply.result.list[0].id,createHash('sha256').update('hello').digest('hex'))
  assert.equal(reply.result.list[0].name,'original-js')
  assert.equal((await invoke('detail',{id:'movie'})).result.lines[0].episodes[0].id,'opaque?$value')
  await invoke('stop')
  files={
    'index.cjs':`const prefix=require('./names.json').prefix;module.exports={home(){return {class:[{type_id:'1',type_name:prefix}]}},category(tid,pg){return {page:pg,list:[{vod_id:tid, vod_name:prefix}]}},search(key,quick,pg){return {page:pg,list:[{vod_id:key,vod_name:prefix}]}},detail(ids){return {list:[{vod_id:ids[0],vod_play_from:'line',vod_play_url:'First$id'}]}},play(flag,id){return {parse:0,url:'https://fixture.test/'+flag+'/'+id}}}`,
    'names.json':`{"prefix":"CommonJS"}`,
  }
  assert.equal((await invoke('start',{entry:'index.cjs',moduleType:'commonjs',protocol:'catvod-js'})).ok,true)
  assert.equal((await invoke('category',{categoryId:'cat',page:3})).result.page,'3')
  assert.equal((await invoke('search',{keyword:'word',page:2})).result.list[0].vod_id,'word')
  assert.equal((await invoke('play',{lineId:'line',id:'opaque'})).result.url,'https://fixture.test/line/opaque')
  await invoke('stop')
  files={'index.cjs':`module.exports=require('../../escape.js')`}
  assert.equal((await invoke('start',{entry:'index.cjs',moduleType:'commonjs'})).ok,false)
  files={'rule.js':`var rule={title:'Rule fixture',host:'https://fixture.test',homeUrl:'/',url:'/list/fyclass/fypage',class_name:'电影&剧集',class_url:'movies&series',searchUrl:'/search?wd=**&page=fypage',推荐:'.list&&a;a&&Text;img&&src;.remark&&Text;a&&href',一级:'.list&&a;a&&Text;img&&src;.remark&&Text;a&&href',二级:'js:VOD={vod_id:input,vod_name:"Rule movie",vod_play_from:"line",vod_play_url:"First$https://fixture.test/movie.mp4"}',搜索:'*',lazy:'js:input={parse:0,url:input}'};`}
  reply=await invoke('start',{entry:'rule.js',moduleType:'script',protocol:'drpy'})
  assert.equal(reply.ok,true,JSON.stringify(reply))
  reply=await invoke('home')
  assert.equal(reply.ok,true,JSON.stringify(reply))
  const home=typeof reply.result==='string'?JSON.parse(reply.result):reply.result
  assert.equal(home.class[0].type_name,'电影')
  reply=await invoke('category',{categoryId:'movies',page:1})
  assert.equal(reply.ok,true,JSON.stringify(reply))
  const category=typeof reply.result==='string'?JSON.parse(reply.result):reply.result
  assert.ok(category.list.length>0,JSON.stringify(category))
  reply=await invoke('search',{keyword:'rule',page:2})
  assert.equal(reply.ok,true,JSON.stringify(reply))
  const searched=typeof reply.result==='string'?JSON.parse(reply.result):reply.result
  assert.ok(searched.list.length>0,JSON.stringify(searched))
  reply=await invoke('detail',{id:'https://fixture.test/detail/1'})
  assert.equal(reply.ok,true,JSON.stringify(reply))
  const detailed=typeof reply.result==='string'?JSON.parse(reply.result):reply.result
  assert.equal(detailed.list[0].vod_play_url,'First$https://fixture.test/movie.mp4')
  reply=await invoke('play',{lineId:'line',id:'https://fixture.test/movie.mp4'})
  assert.equal(reply.ok,true,JSON.stringify(reply))
  const played=typeof reply.result==='string'?JSON.parse(reply.result):reply.result
  assert.equal(played.url,'https://fixture.test/movie.mp4')
  await invoke('stop')
  files={'spider/video/source.js':`import req from '../../util/req.js';import {jsoup} from '../../util/htmlParser.js';import {getHomeCache,setHomeCache,buildHomeCacheKey} from '../../util/home-cache.js';import iconv from 'iconv-lite';import http2 from 'http2';import jpeg from 'jpeg-js';import {Readable} from 'node:stream';
    export default function createSpider(name,config){const checkHttp2=()=>new Promise((resolve,reject)=>{const client=http2.connect('https://fixture.test'),stream=client.request({':path':'/h2',':method':'POST'});stream.setEncoding('utf8');let status=0,body='';stream.on('response',headers=>status=headers[':status']);stream.on('data',chunk=>body+=chunk);stream.on('error',error=>{client.close();reject(error)});stream.on('end',()=>{client.close();resolve(status===200&&body.includes('http2-fixture'))});stream.end('http2-fixture')});return {meta:{key:'catpaw_fixture',name:'CatPaw fixture',type:3},api:async fastify=>{
      fastify.post('/init',async()=>{local.set('fixture','ready','yes');return {ready:true}});
      fastify.post('/home',async request=>{const key=buildHomeCacheKey('fixture',{});setHomeCache(key,'cached');const gbk=iconv.decode(Buffer.from([0xd6,0xd0,0xce,0xc4]),'gbk'),h2=await checkHttp2();await req.get('https://fixture.test/login');await req.get('https://fixture.test/me');req.saveCookies();req.clearAllCookies();req.loadCookies();const auth=await req.get('https://fixture.test/me');const cookie=auth.data.cookie==='sid=fixture';const image=jpeg.decode(jpeg.encode({data:new Uint8Array([255,0,0,255]),width:1,height:1}).data),streamText=await new Promise(resolve=>{const chunks=[];Readable.from(['stream','-ok']).on('data',chunk=>chunks.push(chunk)).on('end',()=>resolve(chunks.join('')))});return {class:[{type_id:'movie',type_name:'电影'}],filters:{movie:[]},list:[{vod_id:'one',vod_name:req.get&&local.get('fixture','ready')==='yes'&&getHomeCache(key)==='cached'&&h2&&cookie&&image.width===1&&streamText==='stream-ok'?jsoup().pq('<b>'+gbk+'片</b>')('b').text():'compat error'}]}});
      fastify.post('/category',async request=>({page:Number(request.body.page),pagecount:2,filters:request.body.filters,list:[{vod_id:request.body.id,vod_name:'分类结果'}]}));
      fastify.post('/search',async request=>({page:Number(request.body.page),pagecount:1,list:[{vod_id:request.body.wd,vod_name:request.body.wd}]}));
      fastify.post('/detail',async request=>({list:[{vod_id:request.body.id[0],vod_name:'详情',vod_play_from:'线路A$$$线路B',vod_play_url:'第一集$opaque1$$$正片$opaque2'}]}));
      fastify.post('/play',async request=>({parse:1,url:'https://fixture.test/watch/'+request.body.id,header:{Referer:request.server.prefix}}));
      fastify.get('/proxy/:file',async(request,reply)=>reply.type('application/vnd.apple.mpegurl').send('#EXTM3U\\n'+request.params.file));
      fastify.get('/compat/post',async()=>{const catpaw=await req.post('https://fixture.test/post',{data:{value:'catpaw'},headers:{'X-Post-Style':'catpaw'}});const axiosStyle=await req.post('https://fixture.test/post',{value:'axios'},{headers:{'X-Post-Style':'axios'}});const form=await req.post('https://fixture.test/post',new URLSearchParams({word:'猫爪'}),{headers:{'Content-Type':'application/x-www-form-urlencoded','X-Post-Style':'form'}});return {catpaw:catpaw.data.received,axios:axiosStyle.data.received,form:form.data.received}});
    }}}`}
  reply=await invoke('start',{entry:'spider/video/source.js',moduleType:'esm',protocol:'catvod-spider',name:'Spider fixture'})
  assert.equal(reply.ok,true,JSON.stringify(reply));assert.equal(reply.result.protocol,'catvod-spider')
  reply=await invoke('home');assert.equal(reply.ok,true,JSON.stringify(reply));assert.equal(reply.result.list[0].vod_name,'中文片')
  assert.ok(requests.some(request=>request.url==='https://fixture.test/h2'))
  assert.equal((await invoke('category',{categoryId:'movie',page:2,filters:{area:'大陆'}})).result.page,2)
  assert.equal((await invoke('search',{keyword:'关键词',page:1})).result.list[0].vod_id,'关键词')
  assert.equal((await invoke('detail',{id:'movie/one'})).result.list[0].vod_play_url,'第一集$opaque1$$$正片$opaque2')
  reply=await invoke('play',{lineId:'线路A',id:'opaque1'});assert.equal(reply.ok,true,JSON.stringify(reply));assert.equal(reply.result.parse,1)
  reply=await invoke('route',{method:'GET',path:'/spider/catpaw_fixture/3/proxy/index.m3u8',host:'127.0.0.1:18780'})
  assert.equal(reply.ok,true,JSON.stringify(reply));assert.equal(reply.result.body,'#EXTM3U\nindex.m3u8');assert.equal(reply.result.headers['content-type'],'application/vnd.apple.mpegurl')
  reply=await invoke('route',{method:'GET',path:'/spider/catpaw_fixture/3/compat/post',host:'127.0.0.1:18780'})
  assert.equal(reply.ok,true,JSON.stringify(reply));assert.deepEqual(reply.result.body,{catpaw:'{"value":"catpaw"}',axios:'{"value":"axios"}',form:'word=%E7%8C%AB%E7%88%AA'})
  assert.equal(requests.at(-3).headers['X-Post-Style'],'catpaw');assert.equal(requests.at(-2).headers['X-Post-Style'],'axios');assert.equal(requests.at(-1).headers['Content-Type'],'application/x-www-form-urlencoded')
  await invoke('stop')
  files={'quickjs/spider.mjs':`export default function createSpider(site){return {async init(ext){local.set('saved-ext',ext)},async home(filter){const remote=await net.json('https://fixture.test/qjs');return {class:[{type_id:'movie',type_name:'电影'}],list:[{vod_id:site.key,vod_name:site.name+':'+local.get('saved-ext')+':'+remote.cookie}]}},async homeVod(){return {list:[]}},async category(tid,pg,filter,extend){return {page:Number(pg),list:[{vod_id:tid,vod_name:JSON.stringify(extend)}]}},async search(key,quick,pg){return {page:Number(pg),list:[{vod_id:key,vod_name:key}]}},async detail(id){return {list:[{vod_id:id,vod_name:id,vod_play_from:'线路',vod_play_url:'第一集$'+id}]}},async play(flag,id,vipFlags){return {parse:0,url:'https://fixture.test/'+id,header:{Referer:'https://fixture.test/'}}}}}`}
  reply=await invoke('start',{entry:'quickjs/spider.mjs',moduleType:'esm',protocol:'catvod-js',name:'QuickJS fixture',options:{key:'qjs_fixture',name:'QuickJS fixture',type:3,ext:'extension-value'}})
  assert.equal(reply.ok,true,JSON.stringify(reply));assert.equal(reply.result.protocol,'catvod-js')
  reply=await invoke('home');assert.equal(reply.ok,true,JSON.stringify(reply));assert.equal(reply.result.list[0].vod_name,'QuickJS fixture:extension-value:')
  assert.equal((await invoke('category',{categoryId:'movie',page:2,filters:{area:'大陆'}})).result.list[0].vod_name,'{"area":"大陆"}')
  assert.equal((await invoke('search',{keyword:'影视',page:3})).result.list[0].vod_id,'影视')
  assert.equal((await invoke('detail',{id:'opaque/id'})).result.list[0].vod_id,'opaque/id')
  assert.equal((await invoke('play',{lineId:'线路',id:'opaque/id'})).result.url,'https://fixture.test/opaque/id')
  await invoke('stop')
  console.log('PASS: original imported ESM/CommonJS, relative and JSON dependencies, CryptoJS hash, Cheerio, POST, CatVod methods, opaque IDs and package path boundary')
}finally{for(const timer of timers.values())clearTimeout(timer)}
