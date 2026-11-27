import assert from 'node:assert/strict'
import {readFileSync} from 'node:fs'
import {randomBytes,randomUUID,createHash,createHmac} from 'node:crypto'
import {gzipSync} from 'node:zlib'
import vm from 'node:vm'
import CryptoJS from 'crypto-js'

let files={}
const timers=new Map(),requests=[],fetchFixtures=new Map()
const storage=new Map()
let next=1
const binaryKey='0123456789abcdef',binaryIV='fedcba9876543210'
const encryptedFixture=CryptoJS.AES.encrypt('{"code":200,"message":"decrypted binary"}',CryptoJS.enc.Utf8.parse(binaryKey),{iv:CryptoJS.enc.Utf8.parse(binaryIV),mode:CryptoJS.mode.CBC,padding:CryptoJS.pad.Pkcs7}).ciphertext.toString(CryptoJS.enc.Base64)
const host={
  __hostLog(){},__hostUUID:randomUUID,__hostRandomBytes:n=>[...randomBytes(n)],
  __hostListPackageFiles:()=>Object.keys(files),__hostReadPackageFile:path=>{if(!Object.hasOwn(files,path))throw Error('missing '+path);return files[path]},
  __hostStorage(action,key,value){if(action==='get')return storage.get(key)||null;if(action==='remove')storage.delete(key);else storage.set(key,value);return value},
  __hostFetchSync(url,options){return {code:200,url,headers:{'Content-Type':'text/html'},content:'<div class="list"><a href="/detail/1"><img src="https://fixture.test/p.jpg"><span class="remark">HD</span>Rule movie</a></div>'}},
  __hostSetTimeout(fn,ms){const id=next++;timers.set(id,setTimeout(()=>{timers.delete(id);fn()},ms));return id},
  __hostClearTimeout(id){clearTimeout(timers.get(id));timers.delete(id)},__hostAbortFetch(){},
  __hostFetch(url,options,callback){const request={url,...JSON.parse(options)};if(request.bodyBase64)request.body=Buffer.from(request.bodyBase64,'base64').toString();requests.push(request);const headers={'Content-Type':'application/json'};let status=200,finalURL=url,body=Buffer.from(JSON.stringify({received:request.body,cookie:request.headers?.Cookie||request.headers?.cookie||''}));const fixture=fetchFixtures.get(url);if(fixture){status=fixture.status??200;finalURL=fixture.finalURL||url;Object.assign(headers,fixture.headers||{});body=Buffer.from(String(fixture.body??''))}if(url.endsWith('/binary-stream')){status=400;headers['Content-Type']='application/stream';body=Buffer.from('{"code":40105,"message":"sign error"}')}if(url.endsWith('/encrypted-stream')){headers['Content-Type']='application/stream';body=Buffer.from(encryptedFixture,'base64')}if(url.endsWith('/login'))headers['Set-Cookie']='sid=fixture; Path=/; HttpOnly';setTimeout(()=>callback({status,url:finalURL,headers,base64:body.toString('base64')}),0);return next++},
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
  assert.equal(vm.runInContext('self===window',context),true)
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
  files={'hamo.js':`async function home(params){const response=await $http.get('https://fixture.test/hamo',{responseType:'text'});await $cache.set('host','https://fixture.test',{ttl:60});return {categories:[{id:'movie',name:'电影',filters:[{key:'year',name:'年代',options:[{name:'2025',value:'2025'}]}]}],items:[{id:'home-1',title:'Home title',poster:'https://fixture.test/poster.jpg'}],remarks:String(response.status)+':'+(await $cache.get('host'))+':'+$crypto.encode('SGVsbG8=',{input:'base64',output:'utf8'})}}
    async function category(params){return {page:params.page,items:[{id:'cat-1',title:'Category title'}]}}
    async function search(params){return {page:params.page,items:[{id:'search-1',title:params.keyword}]}}
    async function detail(params){return {id:params.itemId,title:'Detail title',poster:'https://fixture.test/detail.jpg',summary:'Fixture summary',genres:['电影'],sources:[{id:'main',name:'Main line',episodes:[{id:'ep-1',name:'第一集',ref:{playPath:'/movie/1'}}]}]}}
    async function resolve(params){return {url:'https://fixture.test/watch?item='+params.itemId+'&path='+encodeURIComponent(params.ref.playPath),type:'web',headers:{Referer:'https://fixture.test/'}}}
    var hawk={apiVersion:3,type:'source',meta:{name:'Hamo fixture'},capabilities:['home','category','search','detail','resolve'],home,category,search,detail,resolve};`}
  reply=await invoke('start',{entry:'hamo.js',moduleType:'script',protocol:'hamo-source-v3',name:'Hamo fixture',serviceID:'hamo-fixture'})
  assert.equal(reply.ok,true,JSON.stringify(reply));assert.ok(reply.result.capabilities.includes('play'))
  reply=await invoke('home');assert.equal(reply.ok,true,JSON.stringify(reply));assert.equal(reply.result.items[0].name,'Home title');assert.equal(reply.result.remarks,'200:https://fixture.test:Hello');assert.equal(reply.result.filters.movie[0].value[0].v,'2025')
  assert.equal((await invoke('category',{categoryId:'movie',page:2})).result.items[0].name,'Category title')
  assert.equal((await invoke('search',{keyword:'Hamo title',page:1})).result.items[0].name,'Hamo title')
  reply=await invoke('detail',{id:'movie-1'});assert.equal(reply.ok,true,JSON.stringify(reply));assert.equal(reply.result.name,'Detail title');assert.equal(reply.result.lines[0].episodes[0].name,'第一集')
  reply=await invoke('play',{lineId:'main',id:reply.result.lines[0].episodes[0].id});assert.equal(reply.ok,true,JSON.stringify(reply));assert.equal(reply.result.requiresWebPlayback,true);assert.equal(reply.result.url,'https://fixture.test/watch?item=movie-1&path=%2Fmovie%2F1')
  await invoke('stop')
  files={'index.cjs':`module.exports={async home(){const raw=await net.http('https://fixture.test/binary-stream'),text=await net.http('https://fixture.test/binary-stream',{encoding:'utf8'}),bytes=await net.http('https://fixture.test/binary-stream',{buffer:2}),encrypted=await net.http('https://fixture.test/encrypted-stream'),ciphertext=CryptoJS.enc.Base64.parse(encrypted.content),clear=CryptoJS.AES.decrypt({ciphertext},CryptoJS.enc.Utf8.parse('${binaryKey}'),{iv:CryptoJS.enc.Utf8.parse('${binaryIV}'),mode:CryptoJS.mode.CBC,padding:CryptoJS.pad.Pkcs7}).toString(CryptoJS.enc.Utf8);return {list:[{vod_id:'binary',vod_name:[Buffer.from(raw.content,'base64').toString('utf8'),text.content,Buffer.from(bytes.content).toString('utf8'),clear].join('|')}]}}}`}
  reply=await invoke('start',{entry:'index.cjs',moduleType:'commonjs',protocol:'catvod-js',name:'Binary fixture'})
  assert.equal(reply.ok,true,JSON.stringify(reply))
  reply=await invoke('home');assert.equal(reply.ok,true,JSON.stringify(reply))
  const expected='{"code":40105,"message":"sign error"}'
  assert.equal(reply.result.list[0].vod_name,[expected,expected,expected,'{"code":200,"message":"decrypted binary"}'].join('|'),'application/stream defaults to base64 while explicit text/byte-array modes and AES-CBC decoding remain available')
  await invoke('stop')
  files={'idj/main.js':`async function home(){host.storage.set('token','saved');const response=await host.http.request({url:'https://fixture.test/idj',method:'POST',headers:{'Content-Type':'application/json'},body:'{"ok":true}',timeout:5000});const decoded=host.crypto.aes({op:'decrypt',mode:'cbc',key:'${binaryKey}',keyEncoding:'utf8',iv:'${binaryIV}',ivEncoding:'utf8',data:'${encryptedFixture}',in:'base64',out:'utf8'});return {categories:[{id:'film',name:'电影'}],items:[{id:'home-1',title:'IDJ 首页',cover:'https://fixture.test/poster.jpg',episodeText:'更新至 4 集'}],meta:{http:response.status+':'+JSON.parse(response.body).received,crypto:decoded,hash:host.crypto.md5('abc',{in:'utf8',out:'hex'}),hmac:host.crypto.hmac('sha256','key','message',{keyEncoding:'utf8',in:'utf8',out:'hex'}),gzip:host.codec.gunzip('${gzipSync(Buffer.from('gzip fixture')).toString('base64')}'),storage:host.storage.get('token'),allowed:host.http.allowed('https://fixture.test/a'),wildcard:host.http.allowed('https://cdn.sub.fixture.test/a'),badWildcard:host.http.allowed('https://badsub.fixture.test/a')}}}async function category(arg){if(arg.deny)await host.http.get('https://notfixture.test/private');return {page:arg.page,selected:arg.id,items:[{id:'cat-1',title:'分类结果'}]}}async function search(arg){return {page:arg.page,items:[{id:'search-1',title:arg.keyword}]}}async function detail(arg){return {id:arg.id,title:'IDJ 详情',cover:'https://fixture.test/detail.jpg',summary:'简介',genres:['电影'],lines:[{id:'main',name:'主线',episodes:[{id:'episode-original',name:'第一集',ref:{url:'https://fixture.test/watch/1'}}]}]}}async function play(arg){return {streams:[{url:'https://fixture.test/stream.m3u8',format:'hls',name:'高清',headers:{Referer:'https://fixture.test/'}},{url:'https://fixture.test/backup.mp4',format:'mp4',name:'备用'}],received:{id:arg.id,itemId:arg.itemId,lineId:arg.lineId,line:arg.line}}}export default {home,category,search,detail,play};`}
  reply=await invoke('start',{entry:'idj/main.js',moduleType:'esm',protocol:'idj1',serviceID:'idj-fixture',idjManifest:{schema:1,id:'com.fixture.idj',name:'IDJ fixture',version:'1',type:'video',permissions:{http:['fixture.test','*.sub.fixture.test'],media:[],storage:true},capabilities:['home','category','search','detail','play']}})
  assert.equal(reply.ok,true,JSON.stringify(reply));assert.equal(reply.result.protocol,'idj1')
  reply=await invoke('home');assert.equal(reply.ok,true,JSON.stringify(reply));assert.equal(reply.result.items[0].name,'IDJ 首页');assert.equal(reply.result.items[0].poster,'https://fixture.test/poster.jpg');assert.equal(reply.result.items[0].remarks,'更新至 4 集')
  assert.equal(reply.result.meta.http,'200:{"ok":true}');assert.equal(reply.result.meta.crypto,'{"code":200,"message":"decrypted binary"}');assert.equal(reply.result.meta.hash,createHash('md5').update('abc').digest('hex'));assert.equal(reply.result.meta.hmac,createHmac('sha256','key').update('message').digest('hex'));assert.equal(reply.result.meta.gzip,'gzip fixture');assert.equal(reply.result.meta.storage,'saved');assert.equal(reply.result.meta.allowed,true);assert.equal(reply.result.meta.wildcard,true);assert.equal(reply.result.meta.badWildcard,false)
  assert.equal(requests.at(-1).method,'POST');assert.equal(requests.at(-1).headers['Content-Type'],'application/json');assert.equal(requests.at(-1).body,'{"ok":true}')
  reply=await invoke('category',{deny:true});assert.equal(reply.ok,false);assert.match(reply.error,/E_PERMISSION/)
  reply=await invoke('category',{categoryId:'film',page:2});assert.equal(reply.result.items[0].name,'分类结果');assert.equal(reply.result.selected,'film');assert.equal((await invoke('search',{keyword:'short drama',page:1})).result.items[0].name,'short drama')
  reply=await invoke('detail',{id:'movie-1'});assert.equal(reply.ok,true,JSON.stringify(reply));assert.equal(reply.result.name,'IDJ 详情');assert.equal(reply.result.lines[0].episodes[0].name,'第一集')
  reply=await invoke('play',{lineId:'main',id:reply.result.lines[0].episodes[0].id});assert.equal(reply.ok,true,JSON.stringify(reply));assert.equal(reply.result.url,'https://fixture.test/stream.m3u8');assert.equal(reply.result.alternates.length,2);assert.deepEqual(reply.result.received,{id:'episode-original',itemId:'movie-1',lineId:'main',line:'main'})
  await invoke('stop')
  const playRegex=Buffer.from('"url":"(https[^"]+)"').toString('base64')
  const listHTML='<ul class="cards"><li><a href="/detail/1" data-image="/poster/1.jpg"><h4><a href="/detail/1">第一部</a></h4></a><span class="remark">高清</span></li><li><a href="/detail/2" data-image="/poster/2.jpg"><h4><a href="/detail/2">第二部</a></h4></a></li></ul>'
  const detailHTML='<html><head><title>影片详情 - 站点</title><meta property="og:image" content="/cover.jpg"><meta name="description" content="影片简介"></head><body><ul class="playlist"><li><a href="/play/ep1">第一集</a></li><li><a href="/play/ep2">第二集</a></li></ul></body></html>'
  fetchFixtures.set('https://catalog.fixture.test/type/1',{body:listHTML});fetchFixtures.set('https://catalog.fixture.test/type/1-2',{body:listHTML});fetchFixtures.set('https://catalog.fixture.test/search?q=%E7%8C%AB',{body:listHTML});fetchFixtures.set('https://catalog.fixture.test/detail/1',{body:detailHTML});fetchFixtures.set('https://catalog.fixture.test/play/ep1',{body:'{"url":"https://stream.fixture.test/video.m3u8"}'})
  files={'index.js':'export default {};','rule.json':JSON.stringify({title:'iPlayr fixture',referer:'https://catalog.fixture.test/',user_agent:'Fixture/1.0',category:[{title:'电影',url0:'https://catalog.fixture.test/type/1',url1:'https://catalog.fixture.test/type/1-{pg}'}],vod_node:"//ul[contains(@class, 'cards')]//li",vod_info:"//span[contains(@class, 'remark')]",vod_score:'',vod_title:'//h4/a',vod_image_id:'//a/@data-image',vod_image_regex:'',vod_image_url:'{id}',vod_link_id:'//h4/a/@href',vod_link_url:'https://catalog.fixture.test{id}',play_regex:playRegex,play_url:'{id}',playlist_flag:true,playlist_group_node:"//ul[contains(@class, 'playlist')]",playlist_title:'//li/a',playlist_link_id:'//li/a/@href',playlist_link_url:'https://catalog.fixture.test{id}',playlist_info:'//meta[@name="description"]/@content',search_flag:true,search_url_first_page:'https://catalog.fixture.test/search?q={wd}',search_url_other_page:'https://catalog.fixture.test/search?page={pg}&q={wd}',search_vod_node:"//ul[contains(@class, 'cards')]//li",search_vod_title:'//h4/a',search_vod_image_id:'//a/@data-image',search_vod_image_regex:'',search_vod_image_url:'{id}',search_vod_link_id:'//h4/a/@href',search_vod_link_url:'https://catalog.fixture.test{id}'})}
  reply=await invoke('start',{entry:'index.js',moduleType:'esm',protocol:'iplayr-rule',name:'iPlayr fixture'});assert.equal(reply.ok,true,JSON.stringify(reply));assert.equal(reply.result.protocol,'iplayr-rule')
  reply=await invoke('home');assert.equal(reply.ok,true,JSON.stringify(reply));assert.equal(reply.result.categories[0].name,'电影');assert.equal(reply.result.items.length,2);assert.equal(reply.result.items[0].name,'第一部');assert.equal(reply.result.items[1].poster,'https://catalog.fixture.test/poster/2.jpg')
  reply=await invoke('category',{categoryId:'0',page:2});assert.equal(reply.ok,true,JSON.stringify(reply));assert.equal(reply.result.page,2);assert.equal(requests.at(-1).url,'https://catalog.fixture.test/type/1-2')
  reply=await invoke('search',{keyword:'猫',page:1});assert.equal(reply.ok,true,JSON.stringify(reply));assert.equal(requests.at(-1).url,'https://catalog.fixture.test/search?q=%E7%8C%AB')
  reply=await invoke('detail',{id:'https://catalog.fixture.test/detail/1'});assert.equal(reply.ok,true,JSON.stringify(reply));assert.equal(reply.result.name,'影片详情');assert.equal(reply.result.description,'影片简介');assert.equal(reply.result.lines[0].episodes.length,2);assert.equal(reply.result.lines[0].episodes[0].id,'https://catalog.fixture.test/play/ep1')
  reply=await invoke('play',{lineId:'0',id:'https://catalog.fixture.test/play/ep1'});assert.equal(reply.ok,true,JSON.stringify(reply));assert.equal(reply.result.url,'https://stream.fixture.test/video.m3u8');assert.equal(reply.result.format,'hls')
  await invoke('stop')
  console.log('PASS: ESM/CommonJS/CatVod, Hamo, iDuanJu host permissions/HTTP/storage/crypto/codec, WeBox XPath rules, listing/detail/play mapping, package boundaries')
}finally{for(const timer of timers.values())clearTimeout(timer)}
