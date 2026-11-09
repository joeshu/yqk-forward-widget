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
function patchLegacyPluginSource(rawText){
  let text=String(rawText??'')
  if(typeof g.__cctvTransformSource==='function'){
    try{text=g.__cctvTransformSource(text,config?.moduleType||'',config?.protocol||'')}catch(_e){}
  }
  if(text.includes('joeshu.yqk')&&text.includes('function parseLink(link)')&&!text.includes('__cctv_yqk_norm')){
    const norm=text.includes('yqk:')
      ? 'function parseLink(link) { var __cctv_yqk_norm = 1; if (link && typeof link === "object") link = link.link || link.id || link.vod_id || ""; link = String(link || "").trim(); var __m = link.match(new RegExp("(?:^|/play/|yqk://vod/)([0-9]+)(?:[?]([^#]*))?$", "i")); if (__m) link = "yqk://vod/" + __m[1] + (__m[2] ? ("?" + __m[2]) : "");'
      : 'function parseLink(link) { var __cctv_yqk_norm = 1; if (link && typeof link === "object") link = link.link || link.id || link.vod_id || ""; link = String(link || "").trim(); var __yqkSite = (typeof YQK === "object" && YQK && YQK.site) ? YQK.site : "https://m.yqk3hxe.com"; var __m = link.match(new RegExp("(?:^|/play/|yqk://vod/)([0-9]+)(?:[?]([^#]*))?$", "i")); if (__m) link = __yqkSite + "/play/" + __m[1] + (__m[2] ? ("?" + __m[2]) : "");'
    text=text.replace('function parseLink(link) {',norm)
    text=text.replace(/Math\.min\(20000,/g,'Math.min(5000,')
    text=text.replace(
      'async function yqkProbeHls(url,headers,budget,depth){',
      'async function yqkProbeHls(url,headers,budget,depth){if(new RegExp("^https?://","i").test(String(url||""))&&new RegExp("[.](?:m3u8|mp4)(?:[?#]|$)","i").test(String(url||""))){try{var rFast=await CCTVHttp.get(url,{timeout:3500,headers:headers});var stFast=Number(rFast.statusCode||rFast.status||0),bdFast=String(rFast.data||"");if(stFast===200&&bdFast.trim().startsWith("#EXTM3U"))return url;if(stFast===0||stFast===403||stFast>=500)return url;}catch(_e){return url;}}'
    )
  }
  if(text.includes('user.4kvm')&&text.includes('KVM_WASM_PATH')){
    text=text.replace(
      'const wasm = moduleUrl === KVM_ORIGIN + KVM_WASM_PATH ? KVM_WASM_BASE64 :\n      (await kvmHttp(ctx, moduleUrl, { responseType: "base64" })).data;',
      'const wasm = "";'
    )
    text=text.replace(
      'headers: { "User-Agent": KVM_UA }',
      'headers: { "User-Agent": KVM_UA, Referer: page.url }'
    )
  }
  return text
}
const read=p=>patchLegacyPluginSource(g.__hostReadPackageFile(normalize(p)))
const fs={readFileSync:(p,encoding)=>{const name=normalize(p);if(files.has(name)){const value=read(name);return encoding?value:Buffer.from(value)}const bytes=virtualFiles.get(name);if(!bytes)throw new Error('文件不存在：'+name);return encoding?bytes.toString(typeof encoding==='string'?encoding:encoding.encoding||'utf8'):Buffer.from(bytes)},writeFileSync:(p,value,options={})=>{const name=normalize(p),bytes=Buffer.from(value,typeof options==='string'?options:options.encoding||'utf8');if(bytes.length>1024*1024)throw new Error('JS 临时文件超过 1MB');virtualFiles.set(name,bytes)},appendFileSync:(p,value,options={})=>{const name=normalize(p),bytes=Buffer.from(value,typeof options==='string'?options:options.encoding||'utf8');const current=virtualFiles.get(name)||Buffer.alloc(0);if(current.length+bytes.length>1024*1024)throw new Error('JS 临时文件超过 1MB');virtualFiles.set(name,Buffer.concat([current,bytes]))},unlinkSync:p=>virtualFiles.delete(normalize(p)),existsSync:p=>files.has(normalize(p))||virtualFiles.has(normalize(p)),mkdirSync:()=>{}}
function urlJoin(base,value){try{return new URL(String(value||''),String(base||'')).toString()}catch{return String(value||'')}}
async function axiosRequest(input={}){
  const options=typeof input==='string'?{url:input}:input||{}, method=String(options.method||'GET').toUpperCase()
  let target=new URL(options.url||options.uri||'',options.baseURL||undefined)
  if(options.params&&typeof options.params==='object')for(const [key,value] of Object.entries(options.params))if(value!=null)target.searchParams.set(key,String(value))
  const headers={...(options.headers||{})};let body=options.data??options.body
  if(body instanceof URLSearchParams){body=body.toString();if(!Object.keys(headers).some(key=>key.toLowerCase()==='content-type'))headers['Content-Type']='application/x-www-form-urlencoded;charset=UTF-8'}
  else if(body&&typeof body==='object'&&!Buffer.isBuffer(body)&&!(body instanceof ArrayBuffer)&&!(body instanceof Uint8Array)){const form=Object.entries(headers).some(([key,value])=>key.toLowerCase()==='content-type'&&/application\/x-www-form-urlencoded/i.test(String(value)));body=form?new URLSearchParams(body).toString():JSON.stringify(body);headers['Content-Type']??=form?'application/x-www-form-urlencoded;charset=UTF-8':'application/json'}
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
async function netHTTP(url,options={}){const request={...(options||{})};const method=String(request.method||'GET').toUpperCase(),headers={...(request.headers||{})};if(!Object.keys(headers).some(key=>key.toLowerCase()==='cookie')){const cookie=cookieHeader(String(url));if(cookie)headers.Cookie=cookie}let body=request.body??request.data;if(body&&typeof body==='object'&&!Buffer.isBuffer(body)&&!(body instanceof ArrayBuffer)&&!(body instanceof Uint8Array)){body=JSON.stringify(body);headers['Content-Type']??='application/json'}if(body instanceof Uint8Array||body instanceof ArrayBuffer)body=Buffer.from(body);const controller=new AbortController(),timeout=Math.min(Math.max(Number(request.timeout)||15000,100),30000),timer=setTimeout(()=>controller.abort(),timeout);try{const response=await fetch(String(url),{method,headers,body:['GET','HEAD'].includes(method)?undefined:body,signal:controller.signal,redirect:request.redirect===false?'manual':'follow'}),bytes=Buffer.from(await response.arrayBuffer()),responseHeaders=Object.fromEntries(response.headers),contentType=String(response.headers.get('content-type')||''),binaryResponse=/^(?:application\/(?:octet-stream|stream)|(?:image|audio|video)\/)/i.test(contentType);acceptCookies(response.url||String(url),responseHeaders);let content;if(request.buffer===1||(request.buffer==null&&request.encoding==null&&binaryResponse))content=bytes.toString('base64');else if(request.buffer===2)content=[...bytes];else content=bytes.toString(request.encoding||'utf8');const value={code:response.status,headers:responseHeaders,content,url:response.url||String(url)};if(typeof request.complete==='function')request.complete(value);return value}catch(error){const value={code:'',headers:{},content:'',error:error?.message||String(error)};if(typeof request.complete==='function')request.complete(value);return value}finally{clearTimeout(timer)}}
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
const requestOptionKeys=new Set(['baseURL','data','headers','maxRedirects','method','params','responseType','timeout','url','validateStatus'])
function requestWithBody(url,data,options,method){
  // CatPawOpen's req helper accepts req.post(url, {data, headers, timeout}).
  // Keep the regular axios form req.post(url, data, options) as well.
  const keys=data&&typeof data==='object'&&!Buffer.isBuffer(data)&&!(data instanceof ArrayBuffer)&&!(data instanceof Uint8Array)?Object.keys(data):[]
  const helperOptions=keys.length>0&&keys.every(key=>requestOptionKeys.has(key))&&keys.some(key=>key!=='data'||Object.hasOwn(data,'headers')||Object.hasOwn(data,'timeout')||Object.hasOwn(data,'params')||Object.hasOwn(data,'responseType')||Object.hasOwn(data,'validateStatus')||Object.hasOwn(data,'maxRedirects'))
  return helperOptions?requestWithCookies({...data,url,method}):requestWithCookies({...options,url,data,method})
}
for(const method of ['post','put','patch'])req[method]=(url,data,options={})=>requestWithBody(url,data,options,method.toUpperCase())
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
function compatibilityImport(id){const value=String(id).replaceAll('\\','/');if(value.startsWith('assets://js/lib/cat.js')||value==='cat.js'||value==='underscore'||value==='lodash')return 'catvod-cat';if(value.startsWith('assets://js/lib/cheerio'))return 'cheerio';if(value.startsWith('assets://js/lib/crypto-js'))return 'crypto-js';if(/(?:^|\/)util\/req\.js$/.test(value))return 'catpaw-req';if(/(?:^|\/)util\/htmlParser\.js$/.test(value))return 'catpaw-html-parser';if(/(?:^|\/)util\/home-cache\.js$/.test(value))return 'catpaw-home-cache';if(/(?:^|\/)util\/concurrency-limiter\.js$/.test(value))return 'catpaw-concurrency-limiter';if(/(?:^|\/)util\/misc\.js$/.test(value))return 'catpaw-misc';if(/(?:^|\/)util\/lru-cache\.js$/.test(value))return 'catpaw-lru-cache';if(/(?:^|\/)util\/pan\.js$/.test(value))return 'catpaw-pan';if(/(?:^|\/)core\/runtime-context\.js$/.test(value))return 'catpaw-runtime-context';return null}
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
  for(const candidate of [base,`${base}.js`,`${base}.hjs`,`${base}.mjs`,`${base}.cjs`,`${base}.json`])if(files.has(candidate))return candidate
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
    const recommended=await callSpiderRoute('POST','/homeVod',{body:{filter:true},host:payload.host}),recommendedValue=result(recommended.value);if(recommended.statusCode<400&&recommendedValue&&typeof recommendedValue==='object')value={...value,list:Array.isArray(recommendedValue)?recommendedValue:(recommendedValue.list||[])}
  }
  return value
}
function result(value){if(typeof value==='string'){try{return JSON.parse(value)}catch{}}return value}
function items(value){value=result(value);return Array.isArray(value)?value:(value?.list||value?.items||[])}
function videos(value){return items(value).map(row=>({id:String(row.id??row.vod_id??''),name:cleanDisplayString(row.name??row.vod_name??''),poster:cleanDisplayString(row.poster??row.vod_pic??''),remarks:cleanDisplayString(row.remarks??row.vod_remarks??'')})).filter(row=>row.id&&row.name)}
function media(value){value=result(value);if(typeof value==='string')return {url:value};if(!value||typeof value.url!=='string'||!value.url.trim())throw new Error(value?.message||'插件未返回可播放 URL');if(!/^https?:\/\//i.test(value.url))throw new Error('插件返回的播放地址不是 HTTP/HTTPS');return {...value,parse:Number(value.parse)>0?1:0,headers:value.headers||value.header||{}}}

let weboxDefinedSpec=null
function cleanDisplayString(val){
  if(val==null)return ''
  if(typeof val==='string'){
    const s=val.replace(/\[object\s+[^\]]+\]/gi,'').trim()
    return ['null','undefined','nan','[object object]','{}','[]'].includes(s.toLowerCase())?'':s
  }
  if(typeof val==='number'||typeof val==='boolean')return String(val)
  if(Array.isArray(val))return val.map(cleanDisplayString).filter(Boolean).join(' / ')
  if(typeof val==='object'){
    for(const k of ['name','title','label','text','value','vod_name','remarks'])if(typeof val[k]==='string'&&val[k].trim())return cleanDisplayString(val[k])
  }
  return ''
}
function parseAsn1Integers(der){
  const ints=[]
  function walk(buf,offset,end){
    while(offset<end){
      const tag=buf[offset++];if(offset>=end)break
      let len=buf[offset++]
      if(len&0x80){const nBytes=len&0x7f;len=0;for(let i=0;i<nBytes;i++)len=(len<<8)|buf[offset++]}
      const contentEnd=Math.min(end,offset+len)
      if(tag===0x02){
        let slice=buf.subarray(offset,contentEnd)
        while(slice.length>1&&slice[0]===0x00)slice=slice.subarray(1)
        ints.push({bytes:slice,value:BigInt('0x'+(Buffer.from(slice).toString('hex')||'0'))})
      }else if((tag&0x20)||tag===0x04||tag===0x03){
        walk(buf,tag===0x03?offset+1:offset,contentEnd)
      }
      offset=contentEnd
    }
  }
  walk(der,0,der.length)
  return ints
}
function bigIntModPow(base,exp,mod){
  let result=1n;base=((base%mod)+mod)%mod
  while(exp>0n){if(exp&1n)result=(result*base)%mod;exp>>=1n;base=(base*base)%mod}
  return result
}
function pemToDerBuffer(pem){
  return Buffer.from(String(pem||'').replace(/-----[^-]+-----/g,'').replace(/\s+/g,''),'base64')
}
function weboxRsaEncrypt(plainText,publicKeyPem){
  const ints=parseAsn1Integers(pemToDerBuffer(publicKeyPem))
  const bigInts=ints.filter(x=>x.bytes.length>=32)
  const nObj=bigInts[0],eObj=ints[ints.indexOf(nObj)+1]
  const k=nObj.bytes.length,maxChunk=k-11,data=Buffer.from(String(plainText??''),'utf8'),out=[]
  for(let off=0;off<data.length||(data.length===0&&off===0);off+=maxChunk){
    const chunk=data.subarray(off,Math.min(data.length,off+maxChunk)),padLen=k-3-chunk.length,block=Buffer.alloc(k)
    block[0]=0x00;block[1]=0x02
    for(let i=0;i<padLen;i++){let r=0;while(r===0)r=Math.floor(Math.random()*255)+1;block[2+i]=r}
    block[2+padLen]=0x00;chunk.copy(block,3+padLen)
    const c=bigIntModPow(BigInt('0x'+block.toString('hex')),eObj.value,nObj.value)
    out.push(Buffer.from(c.toString(16).padStart(k*2,'0'),'hex'))
    if(data.length===0)break
  }
  return Buffer.concat(out).toString('base64')
}
function weboxRsaDecrypt(base64Cipher,privateKeyPem){
  const ints=parseAsn1Integers(pemToDerBuffer(privateKeyPem))
  const bigInts=ints.filter(x=>x.bytes.length>=64)
  const nObj=bigInts[0],dObj=bigInts[1],k=nObj.bytes.length
  const raw=Buffer.from(String(base64Cipher||'').replace(/\s+/g,''),'base64'),out=[]
  for(let off=0;off<raw.length;off+=k){
    const slice=raw.subarray(off,Math.min(raw.length,off+k))
    const m=bigIntModPow(BigInt('0x'+slice.toString('hex')),dObj.value,nObj.value)
    const block=Buffer.from(m.toString(16).padStart(k*2,'0'),'hex')
    if(block[0]===0x00&&(block[1]===0x02||block[1]===0x01)){
      let sep=2;while(sep<block.length&&block[sep]!==0x00)sep++
      if(sep<block.length)out.push(block.subarray(sep+1))
    }
  }
  return Buffer.concat(out).toString('utf8')
}
function weboxBuild4kvmPlayUrl(input){
  const dataid=String(input?.dataid??'').trim(),episodeId=String(input?.episodeId??'').trim(),quality=String(input?.quality??'').trim(),playKey=String(input?.playKey??'').trim()
  const now=Date.now(),st=Number(input?.serverTime),plt=Number(input?.loadedAt)
  const t=String(Math.floor((Number.isFinite(st)&&st>0&&Number.isFinite(plt)&&plt>0)?(st+(now-plt)):now))
  const msg=`${dataid}:${t}:${episodeId}`
  const s=CryptoJS.HmacSHA256(CryptoJS.enc.Utf8.parse(msg),CryptoJS.enc.Utf8.parse(episodeId)).toString(CryptoJS.enc.Hex).slice(0,32)
  const secret='nbmovie2024secretkey',pkBytes=Buffer.from(playKey,'utf8'),xored=Buffer.alloc(pkBytes.length)
  for(let i=0;i<pkBytes.length;i++)xored[i]=pkBytes[i]^secret.charCodeAt(i%secret.length)
  const k=xored.toString('base64').replace(/\+/g,'-').replace(/\//g,'_')
  return {url:`/video/play?p=${dataid}&v=${episodeId}&q=${quality}&s=${s}&t=${t}&k=${k}`}
}
function createWeBoxContext(spec,payload){
  const settings={}
  if(Array.isArray(spec?.settings?.fields)){
    for(const f of spec.settings.fields)if(f&&f.key)settings[f.key]=f.default??''
  }
  if(payload?.options&&typeof payload.options==='object'&&!Array.isArray(payload.options))Object.assign(settings,payload.options)
  else if(typeof payload?.options==='string'&&payload.options.trim().startsWith('{')){try{Object.assign(settings,JSON.parse(payload.options))}catch{}}
  const storeNs='webox:'+String(spec?.id||payload?.serviceID||payload?.name||payload?.entry||'default')
  async function weboxHttp(method,url,options={}){
    let target=new URL(String(url))
    if(options.query&&typeof options.query==='object'){
      for(const [k,v] of Object.entries(options.query))if(v!=null&&v!=='')target.searchParams.set(k,String(v))
    }
    const headers={...(options.headers||{})}
    if(!Object.keys(headers).some(k=>k.toLowerCase()==='cookie')){
      const c=cookieHeader(target.toString());if(c)headers.Cookie=c
    }
    let body=undefined
    if(!['GET','HEAD'].includes(method)){
      if(options.json!==undefined){body=JSON.stringify(options.json);if(!Object.keys(headers).some(k=>k.toLowerCase()==='content-type'))headers['Content-Type']='application/json'}
      else if(options.text!==undefined)body=String(options.text)
      else if(options.body!==undefined)body=options.body
    }
    const totalTimeout=Math.min(Math.max(Number(options.timeoutMs||options.timeout)||15000,1000),30000)
    const canRetry=['GET','HEAD'].includes(method)&&!options._retried&&totalTimeout>=8000
    const timeout=canRetry?Math.min(totalTimeout,6500):totalTimeout
    const controller=new AbortController(),timer=setTimeout(()=>controller.abort(),timeout)
    try{
      const response=await fetch(target.toString(),{method,headers,body,signal:controller.signal,redirect:'follow'})
      const bytes=Buffer.from(await response.arrayBuffer())
      const responseHeaders=Object.fromEntries(response.headers)
      acceptCookies(response.url||target.toString(),responseHeaders)
      const rType=String(options.responseType||'text').toLowerCase()
      const data=rType==='base64'?bytes.toString('base64'):rType==='json'?JSON.parse(bytes.toString('utf8')):bytes.toString('utf8')
      return {status:response.status,url:response.url||target.toString(),headers:responseHeaders,data}
    }catch(err){
      if(canRetry&&(err?.name==='AbortError'||/abort|timeout|network/i.test(String(err?.message||err)))){
        return weboxHttp(method,url,{...options,_retried:true,timeoutMs:Math.max(4000,totalTimeout-timeout)})
      }
      if(err?.name==='AbortError'||String(err?.message||err)==='AbortError'){
        const host=target.hostname||String(url)
        const timeoutErr=new Error(`连接站点 ${host} 超时（远端响应过慢或受当前网络环境限制），请稍后重试或切换站点`)
        timeoutErr.code='TIMEOUT'
        throw timeoutErr
      }
      throw err
    }finally{clearTimeout(timer)}
  }
  return {
    settings,
    fail(code,message,extra){const err=new Error(String(message||code||'WeBox Error'));err.code=String(code||'PLUGIN_ERROR');if(extra&&typeof extra==='object')Object.assign(err,extra);throw err},
    signal:{aborted:false,throwIfAborted(){}},
    cache:{generation:1,seconds(def){const n=Number(def);return Number.isFinite(n)&&n>=0?n:60}},
    url:{
      resolve(raw,base){return new URL(String(raw??''),String(base??'')).toString()},
      origin(u){return new URL(String(u??'')).origin}
    },
    http:{
      get:(url,options={})=>weboxHttp('GET',url,options),
      post:(url,options={})=>weboxHttp('POST',url,options)
    },
    html:{load:(html,opts)=>cheerio.load(String(html??''),opts)},
    store:{
      async get(key){const raw=g.__hostStorage('get',storeNs+':'+String(key||''));if(!raw)return null;try{return JSON.parse(raw)}catch{return raw}},
      async set(key,val){g.__hostStorage('set',storeNs+':'+String(key||''),JSON.stringify(val));return val}
    },
    crypto:{
      md5:s=>CryptoJS.MD5(CryptoJS.enc.Utf8.parse(String(s??''))).toString(CryptoJS.enc.Hex),
      base64Encode:s=>Buffer.from(String(s??''),'utf8').toString('base64'),
      base64Decode:s=>Buffer.from(String(s??'').replace(/\s+/g,''),'base64').toString('utf8'),
      aesEncrypt(data,key,iv,options={}){
        const inEnc=String(options.inputEncoding||'utf8').toLowerCase(),outEnc=String(options.outputEncoding||'base64').toLowerCase()
        const wordData=inEnc==='hex'?CryptoJS.enc.Hex.parse(String(data??'')):inEnc==='base64'?CryptoJS.enc.Base64.parse(String(data??'')):CryptoJS.enc.Utf8.parse(String(data??''))
        const encrypted=CryptoJS.AES.encrypt(wordData,CryptoJS.enc.Utf8.parse(String(key??'')),{iv:CryptoJS.enc.Utf8.parse(String(iv??'')),mode:CryptoJS.mode.CBC,padding:CryptoJS.pad.Pkcs7})
        return outEnc==='hex'?encrypted.ciphertext.toString(CryptoJS.enc.Hex):encrypted.ciphertext.toString(CryptoJS.enc.Base64)
      },
      aesDecrypt(data,key,iv,options={}){
        const inEnc=String(options.inputEncoding||'base64').toLowerCase(),outEnc=String(options.outputEncoding||'utf8').toLowerCase()
        const cipherParams=CryptoJS.lib.CipherParams.create({ciphertext:inEnc==='hex'?CryptoJS.enc.Hex.parse(String(data??'')):CryptoJS.enc.Base64.parse(String(data??'').replace(/\s+/g,''))})
        const decrypted=CryptoJS.AES.decrypt(cipherParams,CryptoJS.enc.Utf8.parse(String(key??'')),{iv:CryptoJS.enc.Utf8.parse(String(iv??'')),mode:CryptoJS.mode.CBC,padding:CryptoJS.pad.Pkcs7})
        return outEnc==='hex'?decrypted.toString(CryptoJS.enc.Hex):outEnc==='base64'?decrypted.toString(CryptoJS.enc.Base64):decrypted.toString(CryptoJS.enc.Utf8)
      },
      rsaEncrypt:weboxRsaEncrypt,
      rsaDecrypt:weboxRsaDecrypt
    },
    compute:{
      async run(options={}){
        const {code,input,binaries}=options
        if(input&&input.dataid!==undefined&&input.playKey!==undefined)return weboxBuild4kvmPlayUrl(input)
        if(typeof g.WebAssembly!=='undefined'&&g.WebAssembly&&typeof g.WebAssembly.instantiate==='function'&&code){
          try{
            const decodedBins={}
            for(const [k,v] of Object.entries(binaries||{}))decodedBins[k]=typeof v==='string'?Uint8Array.from(Buffer.from(v,'base64')):v
            const fn=new Function('input','binaries',`return (${code})(input, binaries);`)
            return await fn(input,decodedBins)
          }catch(_e){}
        }
        throw new Error('当前运行环境不支持 WebAssembly 动态计算')
      }
    },
    binary:{
      size:h=>h?Number(h.byteLength??h.length??0):0,
      read:(h,offset,length)=>Uint8Array.from(Buffer.from(h).subarray(offset,offset+length)),
      slice:(h,offset,length)=>Buffer.from(Buffer.from(h).subarray(offset,offset+length)),
      write:(h,offset,bytes)=>{const copy=Buffer.from(h);Buffer.from(bytes).copy(copy,offset);return copy},
      concat:list=>Buffer.concat((list||[]).map(x=>Buffer.from(x)))
    }
  }
}
const weboxEpisodePrefix='webox:'
function createWeBoxPlugin(spec,payload){
  const ctx=createWeBoxContext(spec,payload)
  const cursors=new Map()
  let cachedFilterFields=null,primaryCategoryKey='category',defaultFilters={}
  async function ensureFilterFields(){
    if(cachedFilterFields)return cachedFilterFields
    cachedFilterFields=typeof spec.filters==='function'?await spec.filters(ctx,{}):[]
    if(!Array.isArray(cachedFilterFields))cachedFilterFields=[]
    defaultFilters={}
    for(const f of cachedFilterFields){
      if(f&&f.key)defaultFilters[f.key]=f.default!==undefined?String(f.default):String(f.options?.[0]?.value??'')
    }
    const catField=cachedFilterFields.find(f=>f&&f.key==='category')||cachedFilterFields[0]
    primaryCategoryKey=catField?.key||'category'
    return cachedFilterFields
  }
  function mapWeBoxItems(list){
    return (Array.isArray(list)?list:[]).filter(x=>x&&typeof x==='object'&&x.id!=null).map(x=>({
      id:String(x.id),
      name:cleanDisplayString(x.title||x.name||x.id),
      poster:cleanDisplayString(x.poster||x.pic||''),
      remarks:cleanDisplayString(x.subtitle||x.rating||x.remarks||'')
    })).filter(x=>x.id&&x.name)
  }
  return {
    name:spec.name||payload?.name||'WeBox 影视源',
    meta:{name:spec.name||payload?.name||'WeBox 影视源',key:spec.id||'webox'},
    async home(args={}){
      const fields=await ensureFilterFields()
      const catField=fields.find(f=>f&&f.key===primaryCategoryKey)
      const categories=Array.isArray(catField?.options)?catField.options.map(o=>({id:String(o.value??''),name:cleanDisplayString(o.label||o.name||o.value||'全部')})):[{id:'all',name:'全部'}]
      const filters={}
      for(const cat of categories){
        const catFilters=[]
        for(const f of fields){
          if(!f||!f.key||f.key===primaryCategoryKey||!Array.isArray(f.options))continue
          if(f.showWhen&&f.showWhen.key===primaryCategoryKey&&String(f.showWhen.equals)!==String(cat.id))continue
          catFilters.push({key:String(f.key),name:cleanDisplayString(f.label||f.name||f.key),value:f.options.map(o=>({n:cleanDisplayString(o.label??o.name??o.value??'全部'),v:String(o.value??'')}))})
        }
        if(catFilters.length)filters[cat.id]=catFilters
      }
      const reqFilters={...defaultFilters}
      const res=await spec.list(ctx,{cursor:null,filters:reqFilters,refresh:Boolean(args?.refresh)})
      const cursorKey=JSON.stringify(reqFilters)
      if(res?.nextCursor)cursors.set(cursorKey+'|2',String(res.nextCursor))
      return {categories,filters,items:mapWeBoxItems(res?.items)}
    },
    async category(args={}){
      await ensureFilterFields()
      const page=Math.max(1,Number(args?.page)||1)
      const reqFilters={...defaultFilters,...(args?.filters||{})}
      if(args?.categoryId!==undefined&&primaryCategoryKey)reqFilters[primaryCategoryKey]=String(args.categoryId)
      const cursorKey=JSON.stringify(reqFilters)
      const cursor=page<=1?null:(cursors.get(cursorKey+'|'+page)||String(page))
      const res=await spec.list(ctx,{cursor,filters:reqFilters,refresh:Boolean(args?.refresh)})
      if(res?.nextCursor)cursors.set(cursorKey+'|'+(page+1),String(res.nextCursor))
      return {page,items:mapWeBoxItems(res?.items),hasMore:Boolean(res?.nextCursor)}
    },
    async search(args={}){
      if(typeof spec.search!=='function')return {page:1,items:[],hasMore:false}
      await ensureFilterFields()
      const page=Math.max(1,Number(args?.page)||1)
      const query=String(args?.keyword||args?.wd||args?.query||'').trim()
      if(!query)return {page:1,items:[],hasMore:false}
      const cursorKey='search:'+query
      const cursor=page<=1?null:(cursors.get(cursorKey+'|'+page)||String(page))
      const res=await spec.search(ctx,{query,cursor,filters:{...defaultFilters,...(args?.filters||{})}})
      if(res?.nextCursor)cursors.set(cursorKey+'|'+(page+1),String(res.nextCursor))
      return {page,items:mapWeBoxItems(res?.items),hasMore:Boolean(res?.nextCursor)}
    },
    async detail(args={}){
      const contentId=String(args?.id??args?.itemId??'')
      const det=await spec.detail(ctx,{id:contentId})
      const groups=Array.isArray(det?.groups)?det.groups:[]
      const lines=groups.map((grp,idx)=>({
        id:String(grp?.id??`line-${idx+1}`),
        name:cleanDisplayString(grp?.name||`线路 ${idx+1}`),
        episodes:(Array.isArray(grp?.episodes)?grp.episodes:[]).filter(ep=>ep&&ep.id!=null).map((ep,epIdx)=>({
          id:weboxEpisodePrefix+encodeURIComponent(JSON.stringify({contentId:String(det?.id??contentId),groupId:String(grp?.id??'main'),episodeId:String(ep.id)})),
          name:cleanDisplayString(ep.name||ep.title||`第 ${epIdx+1} 集`)
        }))
      })).filter(l=>l.episodes.length)
      return {
        id:String(det?.id??contentId),
        name:cleanDisplayString(det?.title||det?.name||contentId),
        poster:cleanDisplayString(det?.poster||''),
        description:cleanDisplayString(det?.summary||det?.description||''),
        remarks:cleanDisplayString(det?.subtitle||det?.rating||''),
        lines
      }
    },
    async play(args={}){
      let contentId=String(args?.contentId||args?.id||''),groupId=String(args?.lineId||args?.groupId||'main'),episodeId=String(args?.episodeId||args?.id||'')
      if(typeof args?.id==='string'&&args.id.startsWith(weboxEpisodePrefix)){
        try{
          const parsed=JSON.parse(decodeURIComponent(args.id.slice(weboxEpisodePrefix.length)))
          contentId=String(parsed.contentId||contentId)
          groupId=String(args?.lineId||parsed.groupId||groupId)
          episodeId=String(parsed.episodeId||episodeId)
        }catch{}
      }
      const res=await spec.play(ctx,{contentId,groupId,episodeId,purpose:'playback',refresh:Boolean(args?.refresh)})
      const sources=Array.isArray(res?.sources)?res.sources:[]
      if(!sources.length)throw new Error('WeBox 插件未返回可播放线路')
      const mapped=sources.map((s,idx)=>{
        const headers=s?.headers&&typeof s.headers==='object'?s.headers:{}
        if(typeof s?.manifest==='string'&&s.manifest.trim().startsWith('#EXTM3U')){
          return {
            name:cleanDisplayString(s.name||`线路 ${idx+1}`),
            url:String(s.baseUrl||'https://localhost/playlist.m3u8').trim(),
            manifestText:s.manifest,
            baseUrl:String(s.baseUrl||'https://localhost/playlist.m3u8').trim(),
            headers,
            format:'hls',
            contentType:'application/vnd.apple.mpegurl',
            directMedia:true,
            nativePlayable:true
          }
        }
        const url=String(s?.url||'').trim()
        const isHls=/mpegurl/i.test(String(s?.mime||''))||/\.m3u8(?:$|[?#])/i.test(url)
        return {
          name:cleanDisplayString(s?.name||`线路 ${idx+1}`),
          url,
          headers,
          contentType:String(s?.mime||(isHls?'application/vnd.apple.mpegurl':'video/mp4')),
          ...(isHls?{format:'hls'}:{}),
          directMedia:true,
          nativePlayable:true
        }
      }).filter(s=>s.url||s.manifestText)
      if(!mapped.length)throw new Error('WeBox 插件未返回有效播放地址')
      return {...mapped[0],alternates:mapped.slice(1)}
    }
  }
}

let hamoDefinedSpec=null
const hamoEpisodePrefix='hamo-v3:'
function hamoGlobals(payload){
  g.$http=req
  hamoDefinedSpec=null
  g.Hawk={define(spec){hamoDefinedSpec=spec;return spec}}
  g.Hamo={define(spec){hamoDefinedSpec=spec;return spec}}
  const namespace='hamo-v3:'+String(payload.serviceID||payload.name||payload.entry||'default')
  g.$cache={
    async get(key){const stored=g.local.get(namespace,String(key||''));if(!stored)return undefined;try{const row=JSON.parse(stored);if(row.expires&&row.expires<=Date.now()){g.local.delete(namespace,String(key||''));return undefined}return row.value}catch{return undefined}},
    async set(key,value,options={}){key=String(key||'');if(!key||key.length>1024)return value;const seconds=Math.max(0,Math.min(Number(options?.ttl)||0,30*86400)),row={value,expires:seconds?Date.now()+seconds*1000:0};g.local.set(namespace,key,JSON.stringify(row));return value},
    async delete(key){return g.local.delete(namespace,String(key||''))},
  }
  g.$crypto={
    encode(value,options={}){const input=String(options.input||'utf8').toLowerCase(),output=String(options.output||'base64').toLowerCase();let bytes;if(input==='base64')bytes=Buffer.from(String(value||''),'base64');else if(input==='hex')bytes=Buffer.from(String(value||''),'hex');else bytes=Buffer.from(String(value??''),'utf8');if(output==='utf8'||output==='utf-8')return bytes.toString('utf8');if(output==='base64')return bytes.toString('base64');if(output==='hex')return bytes.toString('hex');throw new Error('Hamo crypto 不支持此输出编码')},
    decode(value,options={}){return g.$crypto.encode(value,{input:options.input||'base64',output:options.output||'utf8'})},
    md5:s=>crypto.createHash('md5').update(String(s??'')).digest('hex'),
    sha1:s=>crypto.createHash('sha1').update(String(s??'')).digest('hex'),
    sha256:s=>crypto.createHash('sha256').update(String(s??'')).digest('hex'),
    hmacSha256:(s,k)=>crypto.createHmac('sha256',String(k??'')).update(String(s??'')).digest('hex'),
    base64Encode:s=>Buffer.from(String(s??''),'utf8').toString('base64'),
    base64Decode:s=>Buffer.from(String(s??''),'base64').toString('utf8'),
  }
}
function hamoRows(value){return items(value).filter(row=>row&&typeof row==='object').map((row,index)=>{const id=String(row.id??row.itemId??row.vod_id??row.url??'');return {...row,id,name:cleanDisplayString(row.name||row.title||row.vod_name||id||`影视内容 ${index+1}`),poster:cleanDisplayString(row.poster??row.cover??row.pic??row.vod_pic??''),remarks:cleanDisplayString(row.remarks??row.subtitle??row.status??row.year??row.summary??row.vod_remarks??'')}})}
function hamoHome(value){value=result(value)||{};const categories=Array.isArray(value.categories)?value.categories:(Array.isArray(value.class)?value.class:(Array.isArray(value.tabs)?value.tabs:[])),filters={};for(const category of categories){const id=String(category?.id??category?.type_id??category?.value??'');if(!id||!Array.isArray(category?.filters))continue;filters[id]=category.filters.filter(group=>group&&typeof group==='object').map(group=>({key:String(group.key||''),name:String(group.name||group.key||''),value:(Array.isArray(group.options)?group.options:[]).filter(option=>option&&typeof option==='object').map(option=>({n:String(option.name??option.label??option.value??''),v:option.value??''}))})).filter(group=>group.key)}return {...value,categories:categories.map((category,index)=>({id:String(category?.id??category?.type_id??category?.value??index),name:String(category?.name??category?.title??category?.type_name??`分类 ${index+1}`)})),filters,items:hamoRows(value)}}
function hamoListing(value){value=result(value)||{};return {...value,items:hamoRows(value)}}
function hamoEpisodeID(itemId,line,episode){const rawRef=episode?.ref??episode?.url??episode?.playUrl??episode?.id;const ref=rawRef&&typeof rawRef==='object'?rawRef:(rawRef?{playPath:String(rawRef),url:String(rawRef)}:{});return hamoEpisodePrefix+encodeURIComponent(JSON.stringify({itemId:String(itemId||''),lineId:String(line?.id||''),episodeId:String(episode?.id??episode?.url??''),ref}))}
function hamoDetail(value,args){value=result(value)||{};if(Array.isArray(value.list)&&value.list.length&&typeof value.list[0]==='object')value=value.list[0];const itemId=String(value.id??value.vod_id??args.id??args.itemId??'');let rawSources=Array.isArray(value.sources)?value.sources:(Array.isArray(value.lines)?value.lines:(Array.isArray(value.groups)?value.groups:[]));if(!rawSources.length&&Array.isArray(value.episodes)&&value.episodes.length)rawSources=[{id:'default',name:'默认线路',episodes:value.episodes}];if(!rawSources.length&&(value.url||value.playUrl))rawSources=[{id:'default',name:'默认线路',episodes:[{id:String(value.url||value.playUrl),name:'正片',url:String(value.url||value.playUrl)}]}];const lines=rawSources.map((line,lineIndex)=>({id:String(line?.id??lineIndex),name:String(line?.name??`线路 ${lineIndex+1}`),episodes:(Array.isArray(line?.episodes)?line.episodes:[]).filter(episode=>episode&&typeof episode==='object').map((episode,epIndex)=>({id:hamoEpisodeID(itemId,line,episode),name:String(episode.name??episode.title??episode.id??`第 ${epIndex+1} 集`)}))})).filter(line=>line.episodes.length);const actors=Array.isArray(value.actors)?value.actors.join(' / '):String(value.actors??value.vod_actor??'');const genres=Array.isArray(value.genres)?value.genres.join(' / '):String(value.genres??value.vod_class??'');return {...value,id:itemId,name:String(value.name||value.title||value.vod_name||itemId),poster:String(value.poster??value.cover??value.vod_pic??''),description:String(value.description??value.summary??value.content??value.vod_content??''),actor:actors,type:genres,lines}}
async function hamoPlay(args){let episode={itemId:String(args.id||''),lineId:String(args.lineId||''),episodeId:String(args.id||''),ref:{playPath:String(args.id||''),url:String(args.id||'')}};if(typeof args.id==='string'&&args.id.startsWith(hamoEpisodePrefix)){try{episode=JSON.parse(decodeURIComponent(args.id.slice(hamoEpisodePrefix.length)))}catch{throw new Error('Hamo 分集引用格式无效')}}const resolveFn=typeof plugin.resolve==='function'?plugin.resolve:plugin.play;if(typeof resolveFn!=='function'){const fallbackUrl=episode.ref?.url||episode.ref?.playPath||episode.episodeId;if(typeof fallbackUrl==='string'&&/^https?:\/\//i.test(fallbackUrl))return {url:fallbackUrl};throw new Error('Hamo 来源未定义 resolve/play 方法')}const resolved=result(await resolveFn.call(plugin,{id:String(episode.episodeId||''),itemId:String(episode.itemId||''),lineId:String(args.lineId||episode.lineId||''),episodeId:String(episode.episodeId||''),url:String(episode.ref?.url||episode.ref?.playPath||episode.episodeId||''),ref:episode.ref&&typeof episode.ref==='object'?episode.ref:{}},{lineId:String(args.lineId||episode.lineId||'')}));if(typeof resolved==='string')return {url:resolved};if(!resolved||typeof resolved!=='object')throw new Error('Hamo 来源未返回播放结果');const finalUrl=resolved.url||resolved.playUrl||(Array.isArray(resolved.sources)&&resolved.sources[0]?.url)||'';return {...resolved,...(finalUrl?{url:finalUrl}:{}),requiresWebPlayback:resolved.requiresWebPlayback??resolved.webPlayback??String(resolved.type||'').toLowerCase()==='web'}}
async function load(payload){
  config={...payload,api:payload.api||(isCatVodProtocol(payload.protocol)?'catvod':'standard')};files=new Set(g.__hostListPackageFiles());virtualFiles.clear();cookieJar.clear();netCache.clear();cache.clear();cacheStore.clear();inflight.clear();concurrencyGroups.clear();spiderRoutes=new Map();spiderPrefix='';modernCatVod=false
  if(!builtins['catvod-cat']&&typeof g.__cctvImport==='function')builtins['catvod-cat']=g.__cctvImport('assets://js/lib/cat.js')
  g.__cctvBuiltins=builtins;g.__cctvRequire=requireFile;g.__cctvActiveOptions=payload.options;g.__cctvActiveModuleType=payload.moduleType||'';g.__cctvActiveProtocol=payload.protocol||'';g.__JS_SPIDER__=null
  g.Buffer=Buffer;g.CryptoJS=CryptoJS;g.cheerio=cheerio;g.global=g;g.window=g;g.self=g
  g.process={env:{},platform:'ios',nextTick:(fn,...args)=>Promise.resolve().then(()=>fn(...args))}
  g.req=async(url,options={})=>{
    const method=String(options.method||'GET').toUpperCase(),headers={...(options.headers||{})}
    let body=options.body??options.data
    const postType=String(options.postType||'').toLowerCase()
    if(body&&typeof body==='object'&&!Buffer.isBuffer(body)&&!(body instanceof ArrayBuffer)&&!(body instanceof Uint8Array)){
      if(postType==='form'||/application\/x-www-form-urlencoded/i.test(String(headers['Content-Type']||headers['content-type']||''))){
        body=new URLSearchParams(Object.entries(body).map(([k,v])=>[k,v==null?'':String(v)])).toString()
        headers['Content-Type']??='application/x-www-form-urlencoded'
      }else{
        body=JSON.stringify(body)
        headers['Content-Type']??='application/json'
      }
    }
    const redirect=(options.redirect===0||options.redirect===false)?'manual':'follow'
    const response=await fetch(url,{...options,method,headers,body:['GET','HEAD'].includes(method)?undefined:body,redirect})
    const bytes=Buffer.from(await response.arrayBuffer())
    const headerMap=Object.fromEntries(response.headers)
    Object.defineProperty(headerMap,'get',{value:name=>response.headers.get(name),enumerable:false})
    const content=options.buffer===2?[...bytes]:options.buffer===1?bytes.toString('base64'):bytes.toString(options.encoding||'utf8')
    return {content,code:response.status,headers:headerMap}
  }
  g.request=async(...args)=>(await g.req(...args)).content
  const localScope='catvod:'+String(payload.dataDirectory||payload.packageRoot||payload.name||'default')
  g.local=isCatVodProtocol(payload.protocol)?{get:(key,fallback=null)=>g.__hostStorage('get',localScope+':'+String(key||''))??fallback,set:(key,value)=>g.__hostStorage('set',localScope+':'+String(key||''),String(value??'')),delete:key=>g.__hostStorage('remove',localScope+':'+String(key||''))}:{get:(namespace,key)=>g.__hostStorage('get',String(namespace||'')+':'+String(key||''))||'',set:(namespace,key,value)=>g.__hostStorage('set',String(namespace||'')+':'+String(key||''),String(value??'')),delete:(namespace,key)=>g.__hostStorage('remove',String(namespace||'')+':'+String(key||''))}
  weboxDefinedSpec=null;g.WeBox={define(spec){weboxDefinedSpec=spec;return spec}}
  if(payload.protocol==='hamo-source-v3')hamoGlobals(payload)
  g.net=net;g.getProxy=()=>payload.proxyURL||'';g.getProxyUrl=proxyURL
  g.crypto={getRandomValues:array=>{const bytes=new Uint8Array(array.buffer,array.byteOffset,array.byteLength);bytes.set(crypto.randomBytes(bytes.length));return array},randomUUID:crypto.randomUUID}
  const entry=find(normalize(payload.entry||'index.js'))
  const type=payload.moduleType||'esm'
  let module
  if(payload.protocol==='drpy'){const helpers=await import('../drpy/globals.mjs');helpers.prepareGlobals(payload);const engine=await import('../drpy/adapter.mjs');module=engine.load(read(entry),payload.options);config.api='catvod'}
  else if(type==='commonjs')module=requireFile(entry)
  else if(type==='script')module=new Function(`var module={exports:{}},exports=module.exports,__JS_SPIDER__=globalThis.__JS_SPIDER__||null;\n${read(entry)}\nreturn typeof __jsEvalReturn==='function'?__jsEvalReturn():typeof plugin!=='undefined'&&plugin?plugin:typeof spider!=='undefined'&&spider?spider:(typeof __JS_SPIDER__!=='undefined'&&__JS_SPIDER__?__JS_SPIDER__:(globalThis.__JS_SPIDER__?globalThis.__JS_SPIDER__:(typeof hawk!=='undefined'&&hawk?hawk:(typeof hamo!=='undefined'&&hamo?hamo:(typeof source!=='undefined'&&source&&typeof source==='object'?source:(module.exports&&Object.keys(module.exports).length?module.exports:(typeof rule!=='undefined'?rule:{${['init','home','homeContent','homeVideoContent','category','categoryContent','search','searchContent','detail','detailContent','play','playerContent','channels','catalog','resolve','epg','destroy'].map(key=>`${key}:typeof ${key}==='function'?${key}:undefined`).join(',')}})))))));`)()
  else module=await esm(entry)
  plugin=weboxDefinedSpec?createWeBoxPlugin(weboxDefinedSpec,payload):(hamoDefinedSpec||g.__JS_SPIDER__||(module?.default||module))
  if(plugin&&typeof plugin.__jsEvalReturn==='function'&&!plugin.home&&!plugin.homeContent)plugin=await plugin.__jsEvalReturn()
  if(plugin&&plugin.api==='1.1'&&typeof plugin.list==='function'&&!weboxDefinedSpec)plugin=createWeBoxPlugin(plugin,payload)
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
  if(plugin&&(plugin.homeContent||plugin.playerContent||plugin.detailContent)&&typeof plugin.resolve!=='function'&&config.api!=='catvod'){
    config.protocol='catvod-js';config.api='catvod'
  }
  for(const [key,alias] of Object.entries({home:'getHome',category:'getCategory',search:'getSearch',detail:'getDetail',play:'getPlay'}))if(typeof plugin[key]!=='function'&&typeof plugin[alias]==='function')plugin[key]=plugin[alias]
  if(typeof plugin.home!=='function'&&typeof plugin.list==='function'){
    plugin.home=async(args)=>plugin.list(args||{})
    if(typeof plugin.category!=='function')plugin.category=async(args)=>plugin.list(args||{})
  }
  if(config.api==='catvod'){
    modernCatVod=typeof plugin.home==='function'&&!plugin.homeContent&&typeof plugin.category==='function'&&typeof plugin.detail==='function'&&typeof plugin.play==='function'
    if(!modernCatVod)for(const [key,alias] of Object.entries({home:'homeContent',homeVod:'homeVideoContent',category:'categoryContent',search:'searchContent',detail:'detailContent',play:'playerContent'}))if(!plugin[key]&&plugin[alias])plugin[key]=plugin[alias]
    if(!plugin.homeVod&&plugin.homeVideoContent)plugin.homeVod=plugin.homeVideoContent
  }
  const hasMediaMethod=['home','category','search','detail','play','channels','catalog','resolve'].some(key=>typeof plugin[key]==='function')
  if(!hasMediaMethod&&(plugin.rule||plugin.一级||plugin.二级||plugin.分类url||plugin.class_name||(plugin.host&&(plugin.url||plugin.headers||plugin.搜索url)))){
    const helpers=await import('../drpy/globals.mjs');helpers.prepareGlobals(payload);const engine=await import('../drpy/adapter.mjs');plugin=engine.load(plugin.rule&&typeof plugin.rule==='object'?plugin.rule:plugin,payload.options);config.protocol='drpy';config.api='catvod'
  }
  if((plugin.rule&&!hasMediaMethod) || !['home','category','search','detail','play','channels','catalog','resolve'].some(key=>plugin[key]))throw new Error('此文件像是规则配置，需要随 ZIP 提供对应规则引擎/适配器；并非独立可运行插件')
  if(typeof plugin.init==='function')await plugin.init(config.api==='catvod'?tvboxExt(payload,tvboxSite(payload)):(payload.options||{}))
  const capabilities=['home','category','search','detail','play','providers','epg'].filter(key=>typeof plugin[key]==='function');if(payload.protocol==='hamo-source-v3'&&typeof plugin.resolve==='function'&&!capabilities.includes('play'))capabilities.push('play');return {engine:'JavaScriptCore',protocol:payload.protocol||'cctvhost.media/1',capabilities:capabilities.concat((plugin.channels||plugin.catalog)&&plugin.resolve?['live']:[]),name:payload.name||plugin.meta?.name||plugin.name||'JS 插件'}
}
const api={
  start:load,
  providers:async()=>typeof plugin.providers==='function'?plugin.providers():[],
  home:async(args)=>{
    if(config.protocol==='catvod-spider')return invokeSpider('home',args)
    if(config.protocol==='hamo-source-v3')return hamoHome(await plugin.home(args||{},{}))
    const value=typeof plugin.home==='function'?result(await plugin.home(config.api==='catvod'?true:args)):{}
    if(!items(value).length && (plugin.homeVod||plugin.homeVideo))return {...value,list:items(await (plugin.homeVod||plugin.homeVideo).call(plugin))}
    return value
  },
  category:async(args)=>config.protocol==='catvod-spider'?invokeSpider('category',args):(config.protocol==='hamo-source-v3'?hamoListing(await plugin.category(args||{},{})):(config.api==='catvod'?plugin.category(String(args.categoryId||''),String(args.page||1),true,args.filters||{}):plugin.category(args))),
  catalog:async()=>{const fn=plugin.channels||plugin.catalog;const data=typeof fn==='function'?await fn.call(plugin):fn||[];return items(data).map(row=>({...row,id:String(row.id),ref:String(row.ref||row.id),name:String(row.name||row.id),logo:String(row.logo||'')}))},
  resolve:async({ref,...context})=>plugin.resolve({id:ref,ref,...context}),
  search:async(args)=>config.protocol==='catvod-spider'?invokeSpider('search',args):(config.protocol==='hamo-source-v3'?hamoListing(await plugin.search(args||{},{})):(config.api==='catvod'?plugin.search(args.keyword||'',false,String(args.page||1)):plugin.search(args))),
  detail:async(args)=>config.protocol==='catvod-spider'?invokeSpider('detail',args):(config.protocol==='hamo-source-v3'?hamoDetail(await plugin.detail({...args,itemId:String(args.id??args.itemId??'')},{}),args):(config.api==='catvod'?(modernCatVod?plugin.detail(String(args.id||'')):plugin.detail([args.id])):plugin.detail(args))),
  play:async(args)=>config.protocol==='catvod-spider'?invokeSpider('play',args):(config.protocol==='hamo-source-v3'?hamoPlay(args||{}):(config.api==='catvod'?plugin.play(args.lineId||'',args.id,[]):plugin.play(args))),
  epg:async(payload)=>typeof plugin.epg==='function'?plugin.epg(payload):[],
  proxy:async(payload)=>{const value=await plugin.proxy(payload);if(Array.isArray(value))return value;if(value&&typeof value==='object'){const code=value.code??value.statusCode??value.status,body=value.content??value.body;if(code!=null&&body!=null)return [code,value.headers||{},body]}return value},
  route:async(args)=>config.protocol==='catvod-spider'?invokeSpider('route',args):{statusCode:404,body:'Not Found'},
  stop:async()=>{const close=plugin?.close||plugin?.destroy;if(typeof close==='function')await close.call(plugin);plugin=null;modernCatVod=false;spiderRoutes.clear();spiderPrefix='';cookieJar.clear();netCache.clear();cache.clear();cacheStore.clear();inflight.clear();concurrencyGroups.clear();return true},
}
g.CCTVHostJS=api
g.__cctvInvoke=(operation,payload,complete)=>Promise.resolve().then(()=>{if(!Object.hasOwn(api,operation))throw new Error('不支持的插件操作');return api[operation](payload||{})}).then(value=>complete(JSON.stringify({ok:true,result:value})),error=>complete(JSON.stringify({ok:false,error:String(error?.message||error)})))
