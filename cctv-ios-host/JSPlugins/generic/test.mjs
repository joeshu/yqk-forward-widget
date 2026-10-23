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
  __hostFetch(url,options,callback){const request={url,...JSON.parse(options)};requests.push(request);setTimeout(()=>callback({status:200,url,headers:{'Content-Type':'application/json'},base64:Buffer.from(JSON.stringify({received:request.body})).toString('base64')}),0);return next++},
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
  reply=await invoke('play',{lineId:'line',id:'https://fixture.test/movie.mp4'})
  assert.equal(reply.ok,true,JSON.stringify(reply))
  await invoke('stop')
  console.log('PASS: original imported ESM/CommonJS, relative and JSON dependencies, CryptoJS hash, Cheerio, POST, CatVod methods, opaque IDs and package path boundary')
}finally{for(const timer of timers.values())clearTimeout(timer)}
