import '../compat/platform.mjs'
import { Buffer } from 'buffer'
import * as crypto from '../compat/crypto-node.mjs'
import CryptoJS from 'crypto-js'
import iconvLite from 'iconv-lite'
import * as cheerio from 'cheerio/lib/slim'
import jpeg from 'jpeg-js'
import * as streamModule from 'node:stream'
import { rollup } from 'rollup/dist/rollup.browser.js'

const g=globalThis
let plugin=null, config=null, files=new Set(), virtualFiles=new Map(), cache=new Map(), spiderRoutes=new Map(), spiderPrefix='', modernCatVod=false
function normalize(path) {
  const parts=[]
  for(const piece of String(path).replaceAll('\\','/').split('/')){
    if(!piece||piece==='.')continue
    if(piece==='..'){if(!parts.length)throw new Error('模块路径超出 ZIP 包');parts.pop()}else parts.push(piece)
  }
  return parts.join('/')
}
const directory=p=>p.includes('/')?p.slice(0,p.lastIndexOf('/')):''
const path={join:(...p)=>normalize(p.join('/')),resolve:(...p)=>normalize(p.join('/')),dirname:directory,basename:p=>String(p).split('/').at(-1),extname:p=>String(p).match(/\.[^/.]+$/)?.[0]||'',sep:'/'}
const read=p=>g.__hostReadPackageFile(normalize(p))
const fs={readFileSync:(p,encoding)=>{const name=normalize(p);if(files.has(name)){const value=read(name);return encoding?value:Buffer.from(value)}const bytes=virtualFiles.get(name);if(!bytes)throw new Error('文件不存在：'+name);return encoding?bytes.toString(typeof encoding==='string'?encoding:encoding.encoding||'utf8'):Buffer.from(bytes)},writeFileSync:(p,value,options={})=>{const name=normalize(p),bytes=Buffer.from(value,typeof options==='string'?options:options.encoding||'utf8');if(bytes.length>1024*1024)throw new Error('JS 临时文件超过 1MB');virtualFiles.set(name,bytes)},appendFileSync:(p,value,options={})=>{const name=normalize(p),bytes=Buffer.from(value,typeof options==='string'?options:options.encoding||'utf8');const current=virtualFiles.get(name)||Buffer.alloc(0);if(current.length+bytes.length>1024*1024)throw new Error('JS 临时文件超过 1MB');virtualFiles.set(name,Buffer.concat([current,bytes]))},unlinkSync:p=>virtualFiles.delete(normalize(p)),existsSync:p=>files.has(normalize(p))||virtualFiles.has(normalize(p)),mkdirSync:()=>{}}
function urlJoin(base,value){try{return new URL(String(value||''),String(base||'')).toString()}catch{return String(value||'')}}
async function axiosRequest(input={}){
  const options=typeof input==='string'?{url:input}:input||{}, method=String(options.method||'GET').toUpperCase()
  let target=new URL(options.url||options.uri||'',options.baseURL||undefined)
  if(options.params&&typeof options.params==='object')for(const [key,value] of Object.entries(options.params))if(value!=null)target.searchParams.set(key,String(value))
  const headers={...(options.headers||{})};let body=options.data??options.body
  if(body&&typeof body==='object'&&!Buffer.isBuffer(body)&&!(body instanceof ArrayBuffer)&&!(body instanceof Uint8Array)){body=JSON.stringify(body);headers['Content-Type']??='application/json'}
  if(body instanceof Uint8Array||body instanceof ArrayBuffer)body=Buffer.from(body)
  const controller=new AbortController(), timeout=Number(options.timeout)||12000,timer=setTimeout(()=>controller.abort(),Math.max(100,Math.min(timeout,30000)))
  try{
    const response=await fetch(target.toString(),{method,headers,body:method==='GET'||method==='HEAD'?undefined:body,signal:controller.signal,redirect:options.maxRedirects===0?'manual':'follow'})
    let data
    if(options.responseType==='arraybuffer'||options.responseType==='buffer')data=Buffer.from(await response.arrayBuffer())
    else {const text=await response.text();if(options.responseType==='json')data=JSON.parse(text);else if(options.responseType==='text')data=text;else{try{data=JSON.parse(text)}catch{data=text}}}
    const result={data,status:response.status,statusText:response.statusText,headers:Object.fromEntries(response.headers),config:options,url:response.url||target.toString()}
    if(!response.ok&&typeof options.validateStatus==='function'&&!options.validateStatus(response.status))throw Object.assign(new Error('Request failed with status code '+response.status),{response:result})
    if(!response.ok&&options.validateStatus===undefined)throw Object.assign(new Error('Request failed with status code '+response.status),{response:result})
    return result
  }catch(error){if(error?.name==='AbortError')throw new Error('Request timeout after '+timeout+'ms');throw error}finally{clearTimeout(timer)}
}
const axios=Object.assign(options=>axiosRequest(options),{request:axiosRequest,create(defaults={}){const run=options=>axiosRequest({...defaults,...(typeof options==='string'?{url:options}:options||{}),headers:{...(defaults.headers||{}),...((typeof options==='object'&&options?.headers)||{})}});for(const method of ['get','delete','head','options'])run[method]=(url,options={})=>run({...options,url,method});for(const method of ['post','put','patch'])run[method]=(url,data,options={})=>run({...options,url,data,method});return run}})
for(const method of ['get','delete','head','options'])axios[method]=(url,options={})=>axiosRequest({...options,url,method})
for(const method of ['post','put','patch'])axios[method]=(url,data,options={})=>axiosRequest({...options,url,data,method})
function isCatVodProtocol(value){return ['catvod-js','tvbox-js','catvod-open-js','catvod-quickjs'].includes(String(value||''))}
function tvboxSite(payload){const options=payload.options&&typeof payload.options==='object'?payload.options:{},site=options.site&&typeof options.site==='object'?{...options.site}:{...options};delete site.site;site.key||=String(payload.name||payload.entry||'local_source').replace(/[^A-Za-z0-9_-]/g,'_');site.name||=payload.name||'本机影视源';site.type||=3;if(options.api&&!site.api)site.api=options.api;if(site.ext===undefined)site.ext=options.ext??(typeof payload.options==='string'?payload.options:JSON.stringify(payload.options||{}));return site}
function tvboxExt(payload,site){const options=payload.options;if(typeof options==='string')return options;if(options&&typeof options==='object')return options.ext??options.extend??site?.ext??JSON.stringify(options);return site?.ext||''}
async function netHTTP(url,options={}){const request={...(options||{})};const method=String(request.method||'GET').toUpperCase(),headers={...(request.headers||{})};if(!Object.keys(headers).some(key=>key.toLowerCase()==='cookie')){const cookie=cookieHeader(String(url));if(cookie)headers.Cookie=cookie}let body=request.body??request.data;if(body&&typeof body==='object'&&!Buffer.isBuffer(body)&&!(body instanceof ArrayBuffer)&&!(body instanceof Uint8Array)){body=JSON.stringify(body);headers['Content-Type']??='application/json'}if(body instanceof Uint8Array||body instanceof ArrayBuffer)body=Buffer.from(body);const controller=new AbortController(),timeout=Math.min(Math.max(Number(request.timeout)||15000,100),30000),timer=setTimeout(()=>controller.abort(),timeout);try{const response=await fetch(String(url),{method,headers,body:['GET','HEAD'].includes(method)?undefined:body,signal:controller.signal,redirect:request.redirect===false?'manual':'follow'}),bytes=Buffer.from(await response.arrayBuffer()),responseHeaders=Object.fromEntries(response.headers);acceptCookies(response.url||String(url),responseHeaders);let content;if(request.buffer===1)content=bytes.toString('base64');else if(request.buffer===2)content=[...bytes];else content=bytes.toString(request.encoding||'utf8');const value={code:response.status,headers:responseHeaders,content,url:response.url||String(url)};if(typeof request.complete==='function')request.complete(value);return value}catch(error){const value={code:'',headers:{},content:'',error:error?.message||String(error)};if(typeof request.complete==='function')request.complete(value);return value}finally{clearTimeout(timer)}}
async function netJSON(url,options={}){if(options?.buffer)throw new Error('JSON 请求不能使用 buffer');const value=await netHTTP(url,options);if(value.error)throw new Error(value.error);if(Number(value.code)<200||Number(value.code)>=300)throw new Error('HTTP '+value.code);return JSON.parse(value.content)}
const netCache=new Map()
const net={http:netHTTP,req:netHTTP,json:netJSON,sleep:ms=>new Promise(resolve=>setTimeout(resolve,Math.max(0,Number(ms)||0))),getUserAgent:()=>misc.IOS_UA,map:async(items,mapper,limit=4)=>{const output=new Array(items.length);let index=0;await Promise.all(Array.from({length:Math.min(Math.max(1,Number(limit)||1),items.length)},async()=>{while(index<items.length){const current=index++;output[current]=await mapper(items[current],current)}}));return output},batch:(items,limit=4)=>net.map(items,item=>net.http(item.url,item.options),limit),cached:async(key,options={},loader)=>{key=String(key);const row=netCache.get(key);if(row&&row.expires>Date.now())return row.value;const value=await loader();const ttl=Math.max(0,Number(options.ttl)||0);if(ttl)netCache.set(key,{value,expires:Date.now()+ttl*1000});while(netCache.size>128)netCache.delete(netCache.keys().next().value);return value},peek:key=>{const row=netCache.get(String(key));return row&&row.expires>Date.now()?row.value:null},clearCache:key=>key==null?netCache.clear():netCache.delete(String(key)),refresh:(key,options,loader)=>{net.cached(key,options,loader).catch(error=>g.__hostLog(error?.message||String(error)))},getCookie:url=>cookieHeader(url),setCookie:(url,cookie)=>{acceptCookies(url,{'set-cookie':cookie});return true}}
net.openStream=async(url,options={})=>{const response=await netHTTP(url,{...options,buffer:2});if(response.error)throw new Error(response.error);const bytes=Uint8Array.from(response.content);let offset=0,closed=false;return {code:response.code,headers:response.headers,contentType:response.headers['content-type']||'',read:async size=>{if(closed||offset>=bytes.length)return null;const end=Math.min(bytes.length,offset+Math.max(1,Number(size)||65536));const chunk=bytes.slice(offset,end);offset=end;return chunk.buffer},close:()=>{closed=true;return true}}}
net.stream=async(url,options={})=>{if(typeof url!=='string')return {code:200,headers:{},contentType:'application/octet-stream',stream:url};const response=await net.openStream(url,options);return {...response,stream:{async *[Symbol.asyncIterator](){let chunk;while((chunk=await response.read(65536))!==null)yield new Uint8Array(chunk)}}}}
function proxyURL(params={}){const base=String(config?.proxyURL||'');if(!base)return '';const target=new URL(base);for(const [key,value] of Object.entries(params||{}))if(value!=null)target.searchParams.set(key,String(value));return target.toString()}
net.getProxyUrl=proxyURL
function emitter(){const listeners=new Map();return {on(name,fn){if(typeof fn==='function'){if(!listeners.has(name))listeners.set(name,[]);listeners.get(name).push(fn)}return this},once(name,fn){const wrapped=(...args)=>{this.off(name,wrapped);fn(...args)};return this.on(name,wrapped)},off(name,fn){listeners.set(name,(listeners.get(name)||[]).filter(item=>item!==fn));return this},emit(name,...args){for(const fn of [...(listeners.get(name)||[])])try{fn(...args)}catch(error){g.__hostLog(error?.message||String(error))}return this}}}
const http2={connect(authority){const client=emitter();client.closed=false;client.request=(pseudo={})=>{const request=emitter();let chunks=[],encoding='',started=false;request.setEncoding=value=>{encoding=String(value||'');return request};request.write=value=>{if(started)throw new Error('HTTP/2 请求已发送');chunks.push(Buffer.isBuffer(value)?value:Buffer.from(String(value)));return true};request.setTimeout=(ms,callback)=>{request._timeout=setTimeout(()=>{request.emit('timeout');callback?.()},Math.max(0,Number(ms)||0));return request};request.end=value=>{if(started)return request;if(value!==undefined)request.write(value);started=true;if(client.closed){request.emit('error',new Error('HTTP/2 会话已关闭'));return request}const headers={...(pseudo||{})},path=headers[':path']||'/',method=String(headers[':method']||'GET').toUpperCase();for(const key of Object.keys(headers))if(key.startsWith(':'))delete headers[key];const body=chunks.length?Buffer.concat(chunks):undefined;const target=new URL(path,authority);fetch(target.toString(),{method,headers,body:method==='GET'||method==='HEAD'?undefined:body}).then(async response=>{clearTimeout(request._timeout);const replyHeaders=Object.fromEntries(response.headers);replyHeaders[':status']=response.status;request.emit('response',replyHeaders);const bytes=Buffer.from(await response.arrayBuffer());if(bytes.length)request.emit('data',encoding?bytes.toString(encoding):bytes);request.emit('end')}).catch(error=>{clearTimeout(request._timeout);request.emit('error',error)});return request};request.close=()=>request.emit('close');return request};client.close=()=>{client.closed=true;client.emit('close')};client.destroy=error=>{client.closed=true;if(error)client.emit('error',error);client.emit('close')};return client}}
const cookieJar=new Map()
function cookieHeader(url){const target=new URL(url),now=Date.now(),pairs=[];for(const [key,cookie] of cookieJar){if(cookie.expires&&cookie.expires<=now){cookieJar.delete(key);continue}if((target.hostname===cookie.domain||target.hostname.endsWith('.'+cookie.domain))&&target.pathname.startsWith(cookie.path)&&(!cookie.secure||target.protocol==='https:'))pairs.push(cookie.name+'='+cookie.value)}return pairs.join('; ')}
function acceptCookies(url,headers){const raw=headers?.['set-cookie']||headers?.['Set-Cookie'];if(!raw)return;const values=Array.isArray(raw)?raw:String(raw).split(/,(?=[^;,=\s]+=[^;,]*)/);let host;try{host=new URL(url).hostname.toLowerCase()}catch{return}for(const value of values){const pieces=String(value).split(';').map(item=>item.trim()),first=pieces.shift(),split=first.indexOf('=');if(split<=0)continue;const name=first.slice(0,split),content=first.slice(split+1);let domain=host,path='/',expires=0,secure=false,remove=false;for(const piece of pieces){const [rawKey,...tail]=piece.split('='),key=rawKey.toLowerCase(),attr=tail.join('=');if(key==='domain'&&attr)domain=attr.replace(/^\./,'').toLowerCase();else if(key==='path'&&attr.startsWith('/'))path=attr;else if(key==='max-age'){const seconds=Number(attr);if(Number.isFinite(seconds)){expires=Date.now()+seconds*1000;remove=seconds<=0}}else if(key==='expires'){const time=Date.parse(attr);if(Number.isFinite(time))expires=time}else if(key==='secure')secure=true}if(host!==domain&&!host.endsWith('.'+domain))continue;const key=domain+'|'+path+'|'+name;if(remove||(expires&&expires<=Date.now()))cookieJar.delete(key);else cookieJar.set(key,{domain,path,name,value:content,expires,secure})}while(cookieJar.size>256)cookieJar.delete(cookieJar.keys().next().value)}
function requestWithCookies(input={}){const options=typeof input==='string'?{url:input}:{...(input||{})},headers={...(options.headers||{})};if(!Object.keys(headers).some(key=>key.toLowerCase()==='cookie')){const cookie=cookieHeader(options.url||options.uri||'');if(cookie)headers.Cookie=cookie}options.headers=headers;return axiosRequest(options).then(response=>{acceptCookies(response.url||options.url||options.uri,response.headers);return response})}
const req=Object.assign(options=>requestWithCookies(options),{request:requestWithCookies,create:axios.create})
for(const method of ['get','delete','head','options'])req[method]=(url,options={})=>requestWithCookies({...options,url,method})
for(const method of ['post','put','patch'])req[method]=(url,data,options={})=>requestWithCookies({...options,url,data,method})
req.saveCookies=()=>g.local?.set('catpaw-req',String(plugin?.meta?.key||config?.id||config?.name||'default'),JSON.stringify([...cookieJar]))
req.loadCookies=()=>{try{const saved=g.local?.get('catpaw-req',String(plugin?.meta?.key||config?.id||config?.name||'default'));const rows=JSON.parse(saved||'[]');cookieJar.clear();for(const [key,value] of rows)if(typeof key==='string'&&value&&typeof value==='object')cookieJar.set(key,value);return cookieJar.size}catch{return 0}}
req.clearCookies=domain=>{const suffix='|'+String(domain||'').toLowerCase().replace(/^\./,'')+'|';for(const [key,value] of cookieJar)if(value.domain===String(domain||'').toLowerCase().replace(/^\./,'')||key.includes(suffix))cookieJar.delete(key)}
req.clearAllCookies=()=>cookieJar.clear()
req.getSharedAgents=()=>({})
function jsoup(){return {pq:html=>cheerio.load(String(html||''))}}
function jsonpath(value,path){const keys=String(path||'').replace(/^\$\.?/,'').match(/(?:[^.[\]]+)|\[(?:"([^"]+)"|'([^']+)'|(\d+))\]/g)||[];return keys.reduce((current,part)=>{const key=part.replace(/^\[(?:"([^"]+)"|'([^']+)'|(\d+))\]$/,'$1$2$3');return current?.[key]},value)}
const htmlParser={jsoup,jsonpath,urljoin:urlJoin}
const cacheStore=new Map()
const homeCache={getHomeCache:key=>{const entry=cacheStore.get(String(key));if(!entry)return null;if(entry.expires<=Date.now()){cacheStore.delete(String(key));return null}return entry.value},setHomeCache:(key,value,ttl=120000)=>{key=String(key);cacheStore.delete(key);cacheStore.set(key,{value,expires:Date.now()+Math.max(1000,Number(ttl)||120000)});while(cacheStore.size>64)cacheStore.delete(cacheStore.keys().next().value);return value},buildHomeCacheKey:(name,value)=>String(name)+':'+JSON.stringify(value||{}),HOME_CACHE_TTL:{semiStatic:120000,static:600000}}
const inflight=new Map(),concurrencyGroups=new Map()
const concurrency={withInflightDedup:(key,fn)=>{key=String(key);if(!inflight.has(key)){const promise=Promise.resolve().then(fn).finally(()=>inflight.delete(key));inflight.set(key,promise);while(inflight.size>128)inflight.delete(inflight.keys().next().value)}return inflight.get(key)},withConcurrencyControl:async(key,operation,_request,fn,options={})=>{const group=String(key)+':'+String(operation);let state=concurrencyGroups.get(group);if(!state){state={running:0,queue:[]};concurrencyGroups.set(group,state)}if(state.running>=4){if(state.queue.length>=32)throw new Error('Spider 请求队列已满');await new Promise(resolve=>state.queue.push(resolve))}state.running++;let timer;try{return await Promise.race([Promise.resolve().then(fn),new Promise((_,reject)=>{timer=setTimeout(()=>reject(new Error('Spider 请求超过等待时限')),Math.min(Math.max(Number(options.timeout)||30000,100),30000))})])}finally{clearTimeout(timer);state.running--;state.queue.shift()?.();if(!state.running&&!state.queue.length)concurrencyGroups.delete(group)}},buildRequestKey:(operation,value)=>String(operation)+':'+JSON.stringify(value||{})}
const misc={delay:ms=>new Promise(resolve=>setTimeout(resolve,Math.max(0,Number(ms)||0))),jsonParse:(value,fallback=null)=>{try{return typeof value==='string'?JSON.parse(value):value}catch{return fallback}},stripHtmlTag:value=>String(value||'').replace(/<[^>]*>/g,'').trim(),fixUrl:(value,base)=>urlJoin(base,value),IOS_UA:'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 Mobile/15E148'}
class LRUCache{constructor(options={}){this.max=Math.max(1,Number(typeof options==='number'?options:options.max)||128);this.values=new Map()}get(key){if(!this.values.has(key))return undefined;const value=this.values.get(key);this.values.delete(key);this.values.set(key,value);return value}set(key,value){this.values.delete(key);this.values.set(key,value);while(this.values.size>this.max)this.values.delete(this.values.keys().next().value);return this}has(key){return this.values.has(key)}delete(key){return this.values.delete(key)}clear(){this.values.clear()}get size(){return this.values.size}}
const pan={init:async()=>({}),getPanInfos:()=>[],detail:async()=>{throw new Error('iPhone 本机暂不包含 CatPaw 网盘解析配置')},play:async()=>{throw new Error('iPhone 本机暂不包含 CatPaw 网盘解析配置')},proxy:async()=>{throw new Error('iPhone 本机暂不包含 CatPaw 网盘解析配置')}}
const runtimeContext={getPans:()=>[],getPanName:name=>String(name||''),getPanEnabled:()=>false}
const iconv=iconvLite
const qs={stringify:value=>new URLSearchParams(value||{}).toString(),parse:value=>Object.fromEntries(new URLSearchParams(String(value||'')))}
const builtins={'buffer':{Buffer},'crypto':crypto,'crypto-js':CryptoJS,'cheerio':cheerio,'axios':axios,'iconv-lite':iconv,'jpeg-js':jpeg,'qs':qs,'http2':http2,'stream':streamModule,'url':{URL:g.URL,URLSearchParams:g.URLSearchParams},'path':path,fs,'catpaw-req':req,'catpaw-html-parser':htmlParser,'catpaw-home-cache':homeCache,'catpaw-concurrency-limiter':concurrency,'catpaw-misc':misc,'catpaw-lru-cache':LRUCache,'catpaw-pan':pan,'catpaw-runtime-context':runtimeContext}
const builtinName=id=>String(id).replace(/^node:/,'')
function compatibilityImport(id){const value=String(id).replaceAll('\\','/');if(/(?:^|\/)util\/req\.js$/.test(value))return 'catpaw-req';if(/(?:^|\/)util\/htmlParser\.js$/.test(value))return 'catpaw-html-parser';if(/(?:^|\/)util\/home-cache\.js$/.test(value))return 'catpaw-home-cache';if(/(?:^|\/)util\/concurrency-limiter\.js$/.test(value))return 'catpaw-concurrency-limiter';if(/(?:^|\/)util\/misc\.js$/.test(value))return 'catpaw-misc';if(/(?:^|\/)util\/lru-cache\.js$/.test(value))return 'catpaw-lru-cache';if(/(?:^|\/)util\/pan\.js$/.test(value))return 'catpaw-pan';if(/(?:^|\/)core\/runtime-context\.js$/.test(value))return 'catpaw-runtime-context';return null}
function resolve(id, from='') {
  const compatibility=compatibilityImport(id);if(compatibility)return `builtin:${compatibility}`
  if(Object.hasOwn(builtins,builtinName(id)))return `builtin:${builtinName(id)}`
  let base
  if(id.startsWith('.'))base=normalize(`${directory(from)}/${id}`)
  else if(id.startsWith('/'))throw new Error('禁止绝对模块路径')
  else {
    let dir=directory(from)
    for(;;){const candidate=normalize(`${dir}/node_modules/${id}`);try{return find(candidate)}catch{};if(!dir)break;dir=directory(dir)}
    base=normalize(id)
  }
  return find(base)
}
function find(base){
  for(const candidate of [base,`${base}.js`,`${base}.mjs`,`${base}.cjs`,`${base}.json`])if(files.has(candidate))return candidate
  if(files.has(`${base}/package.json`)){
    const meta=JSON.parse(read(`${base}/package.json`))
    const main=meta.module||meta.main
    if(typeof main==='string'&&main!=='.')try{return find(normalize(`${base}/${main}`))}catch{}
  }
  for(const candidate of [`${base}/index.js`,`${base}/index.mjs`,`${base}/index.cjs`])if(files.has(candidate))return candidate
  throw new Error(`ZIP 缺少依赖：${base}。请把 JS 依赖一同打包；不支持原生 .node 扩展或完整 Node.js。`)
}
function requireFile(id,from=''){
  const key=resolve(id,from)
  if(key.startsWith('builtin:'))return builtins[key.slice(8)]
  if(cache.has(key))return cache.get(key).exports
  const module={exports:{}};cache.set(key,module)
  try {
    const source=read(key)
    if(key.endsWith('.json'))module.exports=JSON.parse(source)
    else new Function('require','module','exports','__filename','__dirname',`${source}\n//# sourceURL=cctvhost-package/${key}`)(id=>requireFile(id,key),module,module.exports,key,directory(key))
    return module.exports
  }catch(error){cache.delete(key);throw error}
}
async function esm(entry){
  const build=await rollup({input:entry,onwarn:message=>console.warn(message.message),plugins:[{
    name:'cctvhost-package-files',
    resolveId(id,from){return files.has(id)?id:resolve(id,from||'')},
    load(id){
      if(id.startsWith('builtin:'))return exportsFor(builtins[id.slice(8)],`globalThis.__cctvBuiltins[${JSON.stringify(id.slice(8))}]`)
      if(id.endsWith('.json'))return `export default ${read(id)}`
      const source=read(id)
      if(id.endsWith('.cjs')||(!/\b(?:import\s|export\s)/.test(source)&&/\b(?:module\.exports|exports\.)/.test(source))){
        const value=requireFile(id)
        return exportsFor(value,`globalThis.__cctvRequire(${JSON.stringify(id)})`)
      }
      return source
    },
  }]})
  try{const {output}=await build.generate({format:'iife',name:'__cctvImported',exports:'named',inlineDynamicImports:true});return new Function(`${output[0].code}\nreturn __cctvImported;`)()}
  finally{await build.close()}
}
function exportsFor(value,expression){
  const reserved=new Set(['await','break','case','catch','class','const','continue','debugger','default','delete','do','else','enum','export','extends','false','finally','for','function','if','import','in','instanceof','let','new','null','return','super','switch','this','throw','true','try','typeof','var','void','while','with','yield'])
  const keys=Object.keys(value||{}).filter(k=>!reserved.has(k)&&/^[A-Za-z_$][\w$]*$/.test(k))
  return `const value=${expression};export default value;${keys.map(k=>`export const ${k}=value[${JSON.stringify(k)}];`).join('')}`
}
function routeMatch(pattern,path){
  const expected=String(pattern).split('/').filter(Boolean),actual=String(path).split('/').filter(Boolean),params={}
  if(expected.length!==actual.length)return null
  for(let i=0;i<expected.length;i++){
    if(expected[i][0]===':'){try{params[expected[i].slice(1)]=decodeURIComponent(actual[i])}catch{return null}}
    else if(expected[i]!==actual[i])return null
  }
  return params
}
function makeSpiderRouter(spider,payload){
  const key=String(spider?.meta?.key||payload.name||'local-spider').replace(/[^A-Za-z0-9_-]/g,'_')
  spiderPrefix='/spider/'+encodeURIComponent(key)+'/3';spiderRoutes=new Map()
  const add=(method,path,...handlers)=>{
    if(typeof path!=='string'||!path.startsWith('/')||path.startsWith('//'))throw new Error('Spider 路由必须是以 / 开头的相对路径')
    const handler=handlers.reverse().find(value=>typeof value==='function')
    if(!handler)throw new Error('Spider 路由没有处理函数：'+path)
    if(spiderRoutes.size>=128)throw new Error('Spider 注册路由超过 128 个')
    const routeKey=method.toUpperCase()+' '+path
    if(spiderRoutes.has(routeKey))throw new Error('Spider 路由重复：'+routeKey)
    spiderRoutes.set(routeKey,handler)
  }
  const router={server:{prefix:spiderPrefix},post:(path,...handlers)=>add('POST',path,...handlers),get:(path,...handlers)=>add('GET',path,...handlers),put:(path,...handlers)=>add('PUT',path,...handlers),delete:(path,...handlers)=>add('DELETE',path,...handlers),route:options=>{if(!options||typeof options!=='object')throw new Error('Spider route 参数无效');add(options.method||'GET',options.url||options.path,...(Array.isArray(options.preHandler)?options.preHandler:[]),options.handler)},addHook:()=>router}
  return router
}
async function callSpiderRoute(method,path,payload={}){
  let routePath=String(path||'/'),prefix=spiderPrefix
  if(routePath.startsWith(prefix))routePath=routePath.slice(prefix.length)||'/'
  if(!routePath.startsWith('/'))routePath='/'+routePath
  let match=null,handler=null,actualMethod=String(method||'POST').toUpperCase()
  for(const [key,value] of spiderRoutes){const [registeredMethod,registeredPath]=key.split(' ');if(registeredMethod!==actualMethod&&!(actualMethod==='HEAD'&&registeredMethod==='GET'))continue;const params=routeMatch(registeredPath,routePath);if(params){match={params,registeredPath};handler=value;break}}
  if(!handler)throw new Error('Spider 未注册路由：'+actualMethod+' '+routePath)
  const headers={host:String(payload.host||new URL(config.proxyURL||'http://127.0.0.1').host),'user-agent':String(payload.userAgent||'CCTVHost/1')}
  for(const [name,value] of Object.entries(payload.headers||{}))headers[String(name).toLowerCase()]=String(value)
  const queryText=new URLSearchParams(Object.entries(payload.query||{}).map(([key,value])=>[key,String(value)])).toString(),requestURL=prefix+routePath+(queryText?'?'+queryText:'')
  const request={method:actualMethod,url:requestURL,routerPath:match.registeredPath,protocol:'http',hostname:'127.0.0.1',headers,params:match.params,query:payload.query||{},body:payload.body||{},server:{prefix},raw:{url:requestURL,method:actualMethod,headers},log:{error:value=>g.__hostLog(String(value))}}
  const state={statusCode:200,headers:{},sent:false,body:undefined,redirectURL:''}
  const reply={sent:false,code(status){state.statusCode=Number(status)||200;return reply},status(status){return reply.code(status)},header(name,value){state.headers[String(name)]=String(value);return reply},headers(values){for(const [name,value] of Object.entries(values||{}))state.headers[name]=String(value);return reply},type(value){return reply.header('content-type',value)},send(value){state.sent=true;state.body=value;reply.sent=true;return reply},redirect(first,second){if(typeof second==='string'){state.statusCode=Number(first)||302;state.redirectURL=second}else{state.statusCode=302;state.redirectURL=String(first||'')}state.headers.location=state.redirectURL;state.sent=true;reply.sent=true;return reply},get statusCode(){return state.statusCode}}
  let returned=await handler(request,reply)
  let value=state.sent?state.body:returned
  if(state.redirectURL)value=state.redirectURL
  const headersOut={...state.headers}
  if(value===undefined)value={}
  let body=value,bodyBase64=''
  if(Buffer.isBuffer(value)||value instanceof Uint8Array){bodyBase64=Buffer.from(value).toString('base64');body=''}
  else if(typeof value!=='string'&&!(value instanceof ArrayBuffer)){if(!Object.hasOwn(headersOut,'content-type'))headersOut['content-type']='application/json; charset=utf-8'}
  else if(value instanceof ArrayBuffer){bodyBase64=Buffer.from(value).toString('base64');body=''}
  return {statusCode:state.statusCode,headers:headersOut,body,bodyBase64,value}
}
function spiderRequestBody(operation,payload){
  if(operation==='home')return {filter:true}
  if(operation==='category'){const filters=payload.filters||payload.extend||payload.ext||{};return {id:String(payload.categoryId||''),page:String(payload.page||1),filter:true,filters,extend:filters,ext:filters}}
  if(operation==='search')return {wd:String(payload.keyword||''),page:String(payload.page||1),quick:false}
  if(operation==='detail')return {id:[String(payload.id||'')]}
  if(operation==='play')return {flag:String(payload.lineId||''),id:String(payload.id||''),flags:[]}
  return {}
}
async function invokeSpider(operation,payload={}){
  if(operation==='route'){const {value,...response}=await callSpiderRoute(payload.method||'GET',payload.path||'/',payload);return response}
  if(operation==='providers')return []
  if(!['home','homeVod','category','search','detail','play'].includes(operation))throw new Error('本地 Spider 不支持 '+operation)
  const body=spiderRequestBody(operation,payload),response=await callSpiderRoute('POST','/'+operation,{body,host:payload.host})
  if(response.statusCode<200||response.statusCode>=400)throw new Error('Spider '+operation+' 返回 HTTP '+response.statusCode)
  let value=result(response.value)
  if(operation==='home'&&(!value?.list||!value.list.length)&&spiderRoutes.has('POST /homeVod')){
    const recommended=await callSpiderRoute('POST','/homeVod',{body:{filter:true},host:payload.host}),recommendedValue=result(recommended.value);if(recommended.statusCode<400&&recommendedValue&&typeof recommendedValue==='object')value={...value,list:recommendedValue.list||[]}
  }
  return value
}
function result(value){if(typeof value==='string'){try{return JSON.parse(value)}catch{}}return value}
function items(value){value=result(value);return Array.isArray(value)?value:(value?.list||value?.items||[])}
function videos(value){return items(value).map(row=>({id:String(row.id??row.vod_id??''),name:String(row.name??row.vod_name??''),poster:String(row.poster??row.vod_pic??''),remarks:String(row.remarks??row.vod_remarks??'')})).filter(row=>row.id&&row.name)}
function media(value){value=result(value);if(typeof value==='string')return {url:value};if(!value||typeof value.url!=='string'||!value.url.trim())throw new Error(value?.message||'插件未返回可播放 URL');if(!/^https?:\/\//i.test(value.url))throw new Error('插件返回的播放地址不是 HTTP/HTTPS');return {...value,parse:Number(value.parse)>0?1:0,headers:value.headers||value.header||{}}}
async function load(payload){
  config={...payload,api:payload.api||(isCatVodProtocol(payload.protocol)?'catvod':'standard')};files=new Set(g.__hostListPackageFiles());virtualFiles.clear();cookieJar.clear();netCache.clear();cache.clear();cacheStore.clear();inflight.clear();concurrencyGroups.clear();spiderRoutes=new Map();spiderPrefix='';modernCatVod=false
  g.__cctvBuiltins=builtins;g.__cctvRequire=requireFile
  g.Buffer=Buffer;g.CryptoJS=CryptoJS;g.cheerio=cheerio;g.global=g;g.window=g
  g.process={env:{},platform:'ios',nextTick:(fn,...args)=>Promise.resolve().then(()=>fn(...args))}
  g.req=async(url,options={})=>{const response=await fetch(url,options);return {content:await response.text(),code:response.status,headers:{get:response.headers.get}}}
  g.request=async(...args)=>(await g.req(...args)).content
  const localScope='catvod:'+String(payload.dataDirectory||payload.packageRoot||payload.name||'default')
  g.local=isCatVodProtocol(payload.protocol)?{get:(key,fallback=null)=>g.__hostStorage('get',localScope+':'+String(key||''))??fallback,set:(key,value)=>g.__hostStorage('set',localScope+':'+String(key||''),String(value??'')),delete:key=>g.__hostStorage('remove',localScope+':'+String(key||''))}:{get:(namespace,key)=>g.__hostStorage('get',String(namespace||'')+':'+String(key||''))||'',set:(namespace,key,value)=>g.__hostStorage('set',String(namespace||'')+':'+String(key||''),String(value??'')),delete:(namespace,key)=>g.__hostStorage('remove',String(namespace||'')+':'+String(key||''))}
  g.net=net;g.getProxy=()=>payload.proxyURL||'';g.getProxyUrl=proxyURL
  g.crypto={getRandomValues:array=>{const bytes=new Uint8Array(array.buffer,array.byteOffset,array.byteLength);bytes.set(crypto.randomBytes(bytes.length));return array},randomUUID:crypto.randomUUID}
  const entry=find(normalize(payload.entry||'index.js'))
  const type=payload.moduleType||'esm'
  let module
  if(payload.protocol==='drpy'){const helpers=await import('../drpy/globals.mjs');helpers.prepareGlobals(payload);const engine=await import('../drpy/adapter.mjs');module=engine.load(read(entry),payload.options);config.api='catvod'}
  else if(type==='commonjs')module=requireFile(entry)
  else if(type==='script')module=new Function(`${read(entry)}\nreturn typeof plugin!=='undefined'?plugin:typeof spider!=='undefined'?spider:typeof rule!=='undefined'?rule:{${['init','home','homeContent','homeVideoContent','category','categoryContent','search','searchContent','detail','detailContent','play','playerContent','channels','catalog','resolve','epg','destroy'].map(key=>`${key}:typeof ${key}==='function'?${key}:undefined`).join(',')}};`)()
  else module=await esm(entry)
  plugin=module?.default||module
  if(payload.protocol==='catvod-spider'){
    if(typeof plugin==='function')plugin=await plugin(payload.name||payload.entry||'本地影视源',payload.options||{})
  }else if(isCatVodProtocol(payload.protocol)&&typeof plugin==='function')plugin=await plugin(tvboxSite(payload))
  else if(typeof plugin==='function')plugin=await plugin()
  if(!plugin||typeof plugin!=='object')throw new Error('JS 入口未导出插件对象')
  if(payload.protocol==='catvod-spider'){
    if(typeof plugin.api!=='function')throw new Error('CatPaw Spider 未导出 api(fastify) 路由注册器')
    const router=makeSpiderRouter(plugin,payload);await plugin.api(router)
    for(const path of ['/init','/home','/category','/detail','/play','/search'])if(!spiderRoutes.has('POST '+path))throw new Error('CatPaw Spider 缺少必需路由 '+path)
    await callSpiderRoute('POST','/init',{body:{}})
    if(typeof plugin.check==='function'&&await plugin.check()===false)throw new Error('CatPaw Spider check() 未通过')
    return {engine:'JavaScriptCore',protocol:'catvod-spider',name:plugin.meta?.name||payload.name||'CatPaw Spider',capabilities:['home','category','search','detail','play','proxy']}
  }
  if(config.api==='catvod'){
    modernCatVod=typeof plugin.home==='function'&&!plugin.homeContent&&typeof plugin.category==='function'&&typeof plugin.detail==='function'&&typeof plugin.play==='function'
    if(!modernCatVod)for(const [key,alias] of Object.entries({home:'homeContent',homeVod:'homeVideoContent',category:'categoryContent',search:'searchContent',detail:'detailContent',play:'playerContent'}))if(!plugin[key]&&plugin[alias])plugin[key]=plugin[alias]
    if(!plugin.homeVod&&plugin.homeVideoContent)plugin.homeVod=plugin.homeVideoContent
  }
  if(plugin.rule || !['home','category','search','detail','play','channels','catalog','resolve'].some(key=>plugin[key]))throw new Error('此文件像是规则配置，需要随 ZIP 提供对应规则引擎/适配器；并非独立可运行插件')
  if(typeof plugin.init==='function')await plugin.init(config.api==='catvod'?tvboxExt(payload,tvboxSite(payload)):(payload.options||{}))
  return {engine:'JavaScriptCore',protocol:payload.protocol||'cctvhost.media/1',capabilities:['home','category','search','detail','play','providers','epg'].filter(key=>typeof plugin[key]==='function').concat((plugin.channels||plugin.catalog)&&plugin.resolve?['live']:[]),name:payload.name||plugin.name||'JS 插件'}
}
const api={
  start:load,
  providers:async()=>typeof plugin.providers==='function'?plugin.providers():[],
  home:async(args)=>{
    if(config.protocol==='catvod-spider')return invokeSpider('home',args)
    const value=typeof plugin.home==='function'?result(await plugin.home(config.api==='catvod'?true:args)):{}
    if(!items(value).length && (plugin.homeVod||plugin.homeVideo))return {...value,list:items(await (plugin.homeVod||plugin.homeVideo).call(plugin))}
    return value
  },
  category:async(args)=>config.protocol==='catvod-spider'?invokeSpider('category',args):(config.api==='catvod'?plugin.category(String(args.categoryId||''),String(args.page||1),true,args.filters||{}):plugin.category(args)),
  catalog:async()=>{const fn=plugin.channels||plugin.catalog;const data=typeof fn==='function'?await fn.call(plugin):fn||[];return items(data).map(row=>({...row,id:String(row.id),ref:String(row.ref||row.id),name:String(row.name||row.id),logo:String(row.logo||'')}))},
  resolve:async({ref,...context})=>plugin.resolve({id:ref,ref,...context}),
  search:async(args)=>config.protocol==='catvod-spider'?invokeSpider('search',args):(config.api==='catvod'?plugin.search(args.keyword||'',false,String(args.page||1)):plugin.search(args)),
  detail:async(args)=>config.protocol==='catvod-spider'?invokeSpider('detail',args):(config.api==='catvod'?(modernCatVod?plugin.detail(String(args.id||'')):plugin.detail([args.id])):plugin.detail(args)),
  play:async(args)=>config.protocol==='catvod-spider'?invokeSpider('play',args):(config.api==='catvod'?plugin.play(args.lineId||'',args.id,[]):plugin.play(args)),
  epg:async(payload)=>typeof plugin.epg==='function'?plugin.epg(payload):[],
  proxy:async(payload)=>{const value=await plugin.proxy(payload);if(Array.isArray(value))return value;if(value&&typeof value==='object'){const code=value.code??value.statusCode??value.status,body=value.content??value.body;if(code!=null&&body!=null)return [code,value.headers||{},body]}return value},
  route:async(args)=>config.protocol==='catvod-spider'?invokeSpider('route',args):{statusCode:404,body:'Not Found'},
  stop:async()=>{const close=plugin?.close||plugin?.destroy;if(typeof close==='function')await close.call(plugin);plugin=null;modernCatVod=false;spiderRoutes.clear();spiderPrefix='';cookieJar.clear();netCache.clear();cache.clear();cacheStore.clear();inflight.clear();concurrencyGroups.clear();return true},
}
g.CCTVHostJS=api
g.__cctvInvoke=(operation,payload,complete)=>Promise.resolve().then(()=>{if(!Object.hasOwn(api,operation))throw new Error('不支持的插件操作');return api[operation](payload||{})}).then(value=>complete(JSON.stringify({ok:true,result:value})),error=>complete(JSON.stringify({ok:false,error:String(error?.message||error)})))
