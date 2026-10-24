/* One Node.js Mobile instance per app process; individual plugins are disposable.
 * This host is a lifecycle boundary, not an OS security/process sandbox.
 */
'use strict'
const http=require('node:http'),https=require('node:https'),net=require('node:net')
const fs=require('node:fs'),path=require('node:path'),vm=require('node:vm')
const bundledFetch=fs.existsSync(path.join(__dirname,'node-fetch.bundle.cjs'))?path.join(__dirname,'node-fetch.bundle.cjs'):path.join(__dirname,'../GeneratedJS/node-fetch.bundle.cjs')
const nativeFetch=require(bundledFetch)
global.fetch=nativeFetch;global.Headers=nativeFetch.Headers;global.Request=nativeFetch.Request;global.Response=nativeFetch.Response
const {pathToFileURL}=require('node:url')
const {AsyncLocalStorage}=require('node:async_hooks')
const scope=new AsyncLocalStorage()
const owners=new Map()
const closedLogs=new Map()
const hostLogs=[]
function scopedGlobal(name){let fallback=global[name];Object.defineProperty(global,name,{configurable:true,enumerable:true,get(){const owner=scope.getStore();return owner&&Object.prototype.hasOwnProperty.call(owner.globals,name)?owner.globals[name]:fallback},set(value){const owner=scope.getStore();if(owner)owner.globals[name]=value;else fallback=value}})}
for(const name of ['Pans','local','req','request','net','getProxy','getProxyUrl'])scopedGlobal(name)
let baseEnvironment=process.env
try{Object.defineProperty(process,'env',{configurable:true,enumerable:true,get(){return scope.getStore()?.env||baseEnvironment},set(value){const owner=scope.getStore();if(owner)owner.env=value;else baseEnvironment=value}})}catch{}
const original={setTimeout,clearTimeout,setInterval,clearInterval,setImmediate,clearImmediate}
const infoPath=process.argv[2],token=process.argv[3],allowedRoot=fs.realpathSync(process.argv[4])
const nativeCwd=process.cwd.bind(process)
process.cwd=()=>scope.getStore()?.cwd||nativeCwd()
process.chdir=directory=>{const owner=scope.getStore();if(!owner)throw Error('宿主不允许改变 App 的进程工作目录');const resolved=fs.realpathSync(path.resolve(owner.cwd,directory));if(resolved!==owner.data && !resolved.startsWith(owner.data+path.sep))throw Error('插件工作目录超出资源数据目录');owner.cwd=resolved}
function fsPath(value){const owner=scope.getStore();return owner && typeof value==='string' && !path.isAbsolute(value)?path.resolve(owner.cwd,value):value}
for(const name of ['access','appendFile','chmod','chown','exists','lstat','mkdir','open','opendir','readFile','readdir','readlink','realpath','rm','rmdir','stat','truncate','unlink','utimes','watch','watchFile','writeFile']){
  for(const key of [name,name+'Sync'])if(typeof fs[key]==='function'){const operation=fs[key];fs[key]=Object.assign(function(file,...args){return operation.call(this,fsPath(file),...args)},operation)}
  if(typeof fs.promises[name]==='function'){const operation=fs.promises[name];fs.promises[name]=function(file,...args){return operation.call(this,fsPath(file),...args)}}
}
for(const name of ['copyFile','cp','link','rename','symlink']){
  for(const key of [name,name+'Sync'])if(typeof fs[key]==='function'){const operation=fs[key];fs[key]=function(from,to,...args){return operation.call(this,fsPath(from),fsPath(to),...args)}}
  if(typeof fs.promises[name]==='function'){const operation=fs.promises[name];fs.promises[name]=function(from,to,...args){return operation.call(this,fsPath(from),fsPath(to),...args)}}
}
for(const key of ['createReadStream','createWriteStream']){const operation=fs[key];fs[key]=function(file,...args){const stream=operation.call(this,fsPath(file),...args),owner=scope.getStore();if(owner){owner.streams.add(stream);stream.once('close',()=>owner.streams.delete(stream))}return stream}}
let inflight=0
function appendLog(owner,line){const lines=owner?.logs||hostLogs;lines.push(String(line).slice(0,1024));if(lines.length>64)lines.shift()}
function drainLogs(identifier){const owner=owners.get(identifier),lines=owner?.logs||closedLogs.get(identifier)||hostLogs,result=lines.splice(0,20);if(!lines.length)closedLogs.delete(identifier);return result}
for(const key of ['log','info','warn','error','debug'])console[key]=(...args)=>{const owner=scope.getStore();appendLog(owner,args.map(value=>{try{return typeof value==='string'?value:JSON.stringify(value)}catch{return '[无法显示日志对象]'}}).join(' '))}
process.exit=()=>{throw Error('插件不能退出 CCTVHost 进程')}
process.kill=()=>{throw Error('插件不能终止 CCTVHost 进程')}
process.abort=()=>{throw Error('插件不能中止 CCTVHost 进程')}
for(const name of ['spawn','spawnSync','fork','exec','execSync','execFile','execFileSync'])require('node:child_process')[name]=()=>{throw Error('iPhone 插件不支持创建外部进程')}
require('node:worker_threads').Worker=class{constructor(){throw Error('当前本机插件宿主不支持独立 Worker 线程')}}

// Track timers, outgoing sockets, requests and listeners created inside a plugin.
for(const [name,clear] of [['setTimeout','clearTimeout'],['setInterval','clearInterval'],['setImmediate','clearImmediate']]){
  global[name]=(fn,...args)=>{
    const owner=scope.getStore()
    if(!owner)return original[name](fn,...args)
    if(owner.closed)throw Error('插件已停止')
    if(owner.timers.size>=128)throw Error('插件定时器超过 128 个')
    let handle
    handle=original[name]((...values)=>{if(name!=='setInterval')owner.timers.delete(handle);if(!owner.closed)scope.run(owner,()=>fn(...values))},...args)
    owner.timers.set(handle,clear)
    return handle
  }
  global[clear]=handle=>{const owner=scope.getStore();owner?.timers.delete(handle);return original[clear](handle)}
}
const connect=net.Socket.prototype.connect
net.Socket.prototype.connect=function(...args){
  const owner=scope.getStore()
  if(owner){if(owner.closed)throw Error('插件已停止');if(owner.sockets.size>=24)throw Error('插件连接超过 24 个');owner.sockets.add(this);this.once('close',()=>owner.sockets.delete(this))}
  return connect.apply(this,args)
}
const listen=net.Server.prototype.listen
net.Server.prototype.listen=function(...args){
  const owner=scope.getStore()
  if(owner){if(owner.closed)throw Error('插件已停止');if(owner.servers.size>=4)throw Error('插件监听服务超过 4 个');owner.servers.add(this);this.on('connection',socket=>{owner.sockets.add(socket);socket.once('close',()=>owner.sockets.delete(socket))});this.once('close',()=>owner.servers.delete(this))}
  return listen.apply(this,args)
}
function cancelHandles(owner,closeServers=true){
  for(const [timer,clear] of owner.timers)original[clear](timer)
  owner.timers.clear()
  for(const stream of owner.streams)stream.destroy()
  for(const socket of owner.sockets)socket.destroy()
  if(closeServers)for(const server of owner.servers){server.closeAllConnections?.();server.close()}
}
function deadline(promise,ms,label){let timer;return Promise.race([promise,new Promise((_,reject)=>{timer=original.setTimeout(()=>reject(Error(label)),ms)})]).finally(()=>original.clearTimeout(timer))}
function readableRoot(value){const root=fs.realpathSync(value);if(!root.startsWith(allowedRoot+path.sep))throw Error('Node 资源不在已安装目录中');return root}
function entryPath(root,entry){const value=fs.realpathSync(path.resolve(root,entry));if(!value.startsWith(root+path.sep))throw Error('Node 入口超出资源目录');return value}
async function readLimited(response){let length=0,chunks=[];for await(const chunk of response.body){length+=chunk.length;if(length>2*1024*1024)throw Error('Node 来源响应超过 2 MB');chunks.push(Buffer.from(chunk))}return Buffer.concat(chunks)}
function safeWidgetURL(value){try{const url=new URL(String(value||''));return ['http:','https:'].includes(url.protocol)&&url.hostname&&!url.username&&!url.password&&url.href.length<=8192?url.href:''}catch{return ''}}
function widgetHeaders(input){const output={};if(!input||typeof input!=='object')return output;for(const [name,value] of Object.entries(input).slice(0,64)){const key=String(name),text=String(value);if(!/^[!#$%&'*+.^_`|~0-9A-Za-z-]{1,128}$/.test(key)||text.length>8192||/[\r\n]/.test(text)||/^(host|content-length|connection|transfer-encoding|keep-alive|upgrade)$/i.test(key))continue;output[key]=text}return output}
async function widgetHTTP(method,url,body,options={}){
  const target=safeWidgetURL(url);if(!target)throw Error('Widget HTTP 仅支持有效的 HTTP/HTTPS 地址')
  const headers=widgetHeaders(options.headers),hasBody=!['GET','HEAD'].includes(method)
  let requestBody=body
  if(hasBody&&requestBody!=null&&typeof requestBody!=='string'&&!Buffer.isBuffer(requestBody)){requestBody=JSON.stringify(requestBody);headers['Content-Type']??='application/json'}
  const timeout=Math.max(1000,Math.min(Number(options.timeout)||10000,15000))
  const response=await fetch(target,{method,headers,body:hasBody?requestBody:undefined,redirect:options.allow_redirects===false?'manual':'follow',signal:AbortSignal.timeout(timeout)})
  const bytes=await readLimited(response)
  return {statusCode:response.status,status:response.status,headers:Object.fromEntries(response.headers),data:options.base64Data?bytes.toString('base64'):bytes.toString('utf8')}
}
function widgetSource(sandbox,source){
  vm.runInNewContext(source,sandbox,{timeout:1500,displayErrors:true})
  if(typeof sandbox.loadResource!=='function')throw Error('Widget 脚本未提供 loadResource(params)')
  return sandbox.loadResource
}
function widgetRows(owner,value){
  const source=Array.isArray(value)?value:Array.isArray(value?.list)?value.list:[]
  owner.widgetItems=new Map();const stamp=Date.now().toString(36),items=[]
  for(const row of source.slice(0,24)){
    if(!row||typeof row!=='object')continue
    const url=safeWidgetURL(row.url||row.playUrl);if(!url)continue
    const id='widget-'+stamp+'-'+items.length.toString(36)
    owner.widgetItems.set(id,{...row,url})
    items.push({id,name:String(row.name||row.title||('播放线路 '+(items.length+1))).slice(0,256),poster:'',remarks:String(row.description||row.quality||'已解析，可直接播放').slice(0,512)})
  }
  return {page:1,pagecount:1,list:items}
}
async function sourceJSON(url,body){
  const response=await fetch(url,{method:body===undefined?'GET':'POST',headers:{'Content-Type':'application/json'},body:body===undefined?undefined:JSON.stringify(body),signal:AbortSignal.timeout(20000)})
  const text=(await readLimited(response)).toString('utf8')
  if(!response.ok)throw Error('Node 来源 HTTP '+response.status)
  return JSON.parse(text)
}
function installCatvodGlobals(owner){
  const file=path.join(owner.data,'js-storage.json')
  let storage={};try{storage=JSON.parse(fs.readFileSync(file,'utf8'))}catch{}
  const save=()=>{const text=JSON.stringify(storage);if(text.length>1024*1024)throw Error('插件存储超过 1 MB');fs.writeFileSync(file+'.tmp',text);fs.renameSync(file+'.tmp',file)}
  global.local={get:function(namespace,key){if(isCatVodProtocol(owner.protocol))return (storage.__catvod||{})[namespace]??(arguments.length>1?key:'');return arguments.length===1?(storage.__catvod||{})[namespace]??'':storage[namespace]?.[key]??''},set:function(namespace,key,value){if(arguments.length===2){storage.__catvod??={};storage.__catvod[namespace]=key}else{storage[namespace]??={};storage[namespace][key]=value}save()},delete:function(namespace,key){if(arguments.length===1){if(storage.__catvod)delete storage.__catvod[namespace]}else if(storage[namespace])delete storage[namespace][key];save()}}
  global.req=async(url,options={})=>{
    let body=options.body??options.data,headers={...(options.headers||{})}
    if(body && typeof body==='object'){body=JSON.stringify(body);headers['Content-Type']??='application/json'}
    const response=await fetch(url,{method:options.method||'GET',headers,body,signal:AbortSignal.timeout(Math.min(options.timeout||12000,20000))})
    const bytes=await readLimited(response)
    return {code:response.status,headers:Object.fromEntries(response.headers),content:options.buffer===2?[...bytes]:options.buffer===1?bytes.toString('base64'):bytes.toString('utf8')}
  }
  global.request=async(...args)=>(await global.req(...args)).content
  global.getProxy=()=>owner.payload.proxyURL||''
  global.getProxyUrl=params=>{const base=owner.payload.proxyURL;if(!base)return '';const target=new URL(base);for(const [key,value] of Object.entries(params||{}))if(value!=null)target.searchParams.set(key,String(value));return target.toString()}
  const netHTTP=async(url,options={})=>{const headers={...(options.headers||{})};let body=options.body??options.data;if(body&&typeof body==='object'&&!Buffer.isBuffer(body)){body=JSON.stringify(body);headers['Content-Type']??='application/json'}const response=await fetch(url,{method:options.method||'GET',headers,body:['GET','HEAD'].includes(String(options.method||'GET').toUpperCase())?undefined:body,signal:AbortSignal.timeout(Math.min(options.timeout||15000,20000))}),bytes=await readLimited(response),content=options.buffer===1?bytes.toString('base64'):options.buffer===2?[...bytes]:bytes.toString(options.encoding||'utf8'),value={code:response.status,headers:Object.fromEntries(response.headers),content,url:response.url||url};options.complete?.(value);return value}
  global.net={http:netHTTP,req:netHTTP,json:async(url,options={})=>{if(options.buffer)throw Error('JSON 请求不能使用 buffer');const result=await netHTTP(url,options);if(result.code<200||result.code>=300)throw Error('HTTP '+result.code);return JSON.parse(result.content)},sleep:ms=>new Promise(resolve=>setTimeout(resolve,Math.max(0,Number(ms)||0))),getUserAgent:()=>global.navigator?.userAgent||'CCTVHost/1',cached:async(_key,_options,loader)=>loader(),map:async(items,mapper)=>Promise.all(items.map(mapper)),batch:async(items)=>Promise.all(items.map(item=>netHTTP(item.url,item.options)))}
}
function catVodSite(payload){const options=payload.options&&typeof payload.options==='object'?payload.options:{},site=options.site&&typeof options.site==='object'?{...options.site}:{...options};delete site.site;site.key||=String(payload.name||payload.entry||'local_source').replace(/[^A-Za-z0-9_-]/g,'_');site.name||=payload.name||'本机影视源';site.type||=3;if(options.api&&!site.api)site.api=options.api;if(site.ext===undefined)site.ext=options.ext??(typeof payload.options==='string'?payload.options:JSON.stringify(payload.options||{}));return site}
function catVodExt(payload,site){const options=payload.options;if(typeof options==='string')return options;if(options&&typeof options==='object')return options.ext??options.extend??site?.ext??JSON.stringify(options);return site?.ext||''}
const isCatVodProtocol=value=>['catvod-js','tvbox-js','catvod-open-js','catvod-quickjs'].includes(String(value||''))
async function start(payload){
  const existing=owners.get(payload.session);if(existing){if(existing.stopPromise)throw Error('Node 插件正在停止');if(!existing.closed)return existing.ready?await existing.ready:existing.metadata;owners.delete(payload.session)}
  const root=readableRoot(payload.packageRoot),entry=entryPath(root,payload.entry)
  const data=readableRoot(payload.dataDirectory)
  let resolveReady,rejectReady
  const ready=new Promise((resolve,reject)=>{resolveReady=resolve;rejectReady=reject})
  ready.catch(()=>{})
  const owner={session:payload.session,serviceID:payload.serviceID||payload.session,root,data,cwd:data,payload,protocol:payload.protocol,timers:new Map(),sockets:new Set(),servers:new Set(),streams:new Set(),closed:false,stopPromise:null,providers:[],globals:{},env:{...baseEnvironment},logs:[],ready,resolveReady,rejectReady,metadata:null}
  owners.set(owner.session,owner)
  try{const metadata=await scope.run(owner,async()=>{
    process.env.CATPAW_DATA_DIR=data;process.env.NODE_PATH=data;process.env.DEV_HTTP_PORT='0'
    installCatvodGlobals(owner)
    if(owner.protocol==='widget-extractor'){
      const source=fs.readFileSync(entry,'utf8')
      if(Buffer.byteLength(source,'utf8')>8*1024*1024)throw Error('Widget 脚本超过 8 MB')
      const sandbox={URL,URLSearchParams,TextEncoder,TextDecoder,console,Widget:{http:{
        get:(url,options={})=>widgetHTTP('GET',url,undefined,options),
        post:(url,body,options={})=>widgetHTTP('POST',url,body,options)
      }}}
      const loadResource=widgetSource(sandbox,source)
      owner.module={loadResource};owner.widgetItems=new Map();owner.widgetSearchToken=0
      owner.metadata={engine:'Node.js Mobile',protocol:'widget-extractor',capabilities:['search','detail','play']}
      return owner.metadata
    }
    let module
    if(payload.moduleType==='esm')module=await import(pathToFileURL(entry).href+'?session='+encodeURIComponent(payload.session))
    else{for(const name of Object.keys(require.cache))if(name===entry||name.startsWith(root+path.sep))delete require.cache[name];module=require(entry)}
    owner.module=module.default||module
    if(owner.protocol==='catpaw-http'){
      if(typeof owner.module.start==='function')await owner.module.start(payload.options||{})
      else {
        // CatPaw's bundled local application exposes its configured Fastify
        // instance as globalThis.Pans; the host owns binding its loopback port.
        const app=globalThis.Pans
        if(!app || app===owner.previousPans || typeof app.listen!=='function')throw Error('Node 服务未导出 start()，也没有提供 CatPaw 本机服务实例')
        owner.module=app
        if(!owner.servers.size && !app.server?.listening)await app.listen({host:'127.0.0.1',port:0})
      }
      const server=[...owner.servers].find(server=>server.listening && server.address()?.port)
      if(!server && !owner.module.server?.listening)throw Error('Node 服务未开启可用的本机 HTTP 监听')
      const listening=server||owner.module.server
      owner.base='http://127.0.0.1:'+listening.address().port
      const config=await sourceJSON(owner.base+'/config')
      owner.providers=(config.video?.sites||[]).filter(site=>typeof site.api==='string'&&site.api.startsWith('/spider/')).map(site=>({id:String(site.key),name:String(site.name),api:site.api}))
      owner.metadata={engine:'Node.js Mobile',version:process.versions.node,protocol:'catpaw-http',capabilities:['providers','home','category','search','detail','play']}
    }else{
      if(isCatVodProtocol(owner.protocol)&&typeof owner.module==='function')owner.module=await owner.module(catVodSite(payload))
      else if(typeof owner.module==='function')owner.module=await owner.module(payload.options||{})
      if(!owner.module || typeof owner.module!=='object')throw Error('Node 入口未导出插件对象')
      owner.modernCatVod=isCatVodProtocol(owner.protocol)&&typeof owner.module.home==='function'&&!owner.module.homeContent&&typeof owner.module.category==='function'&&typeof owner.module.detail==='function'&&typeof owner.module.play==='function'
      if(isCatVodProtocol(owner.protocol)){if(!owner.modernCatVod)for(const [key,alias] of Object.entries({home:'homeContent',homeVod:'homeVideoContent',category:'categoryContent',search:'searchContent',detail:'detailContent',play:'playerContent'}))if(!owner.module[key]&&typeof owner.module[alias]==='function')owner.module[key]=owner.module[alias];if(!owner.module.homeVod&&owner.module.homeVideoContent)owner.module.homeVod=owner.module.homeVideoContent}
      if(typeof owner.module.init==='function')await owner.module.init(isCatVodProtocol(owner.protocol)?catVodExt(payload,catVodSite(payload)):(payload.options||{}))
      owner.metadata={engine:'Node.js Mobile',version:process.versions.node,protocol:owner.protocol,capabilities:['home','category','search','detail','play','providers','proxy'].filter(key=>typeof owner.module[key]==='function').concat((owner.module.channels||owner.module.catalog||(owner.protocol==='iptv-extractor'&&owner.module.fetch))&&owner.module.resolve?['live']:[])}
    }
    return owner.metadata
  });owner.metadata=metadata;owner.resolveReady(metadata);return metadata}catch(error){cancelHandles(owner);owner.closed=true;owners.delete(owner.session);closedLogs.set(owner.session,owner.logs.slice(-20));owner.rejectReady(error);throw error}
}
async function invoke(operation,payload){
  const owner=owners.get(payload.session)
  if(!owner || owner.session!==payload.session || owner.closed)throw Error('Node 会话已经停止或不匹配')
  if(owner.ready&&!owner.metadata)await owner.ready
  if(owner.failure)throw Error('Node 插件异常：'+owner.failure+'；请停止该资源')
  if(owner.stopPromise)throw Error('Node 插件正在停止')
  return scope.run(owner,async()=>{
    let value
    if(owner.protocol==='catpaw-http'){
      if(operation==='providers')return owner.providers.map(({id,name})=>({id,name}))
      const provider=owner.providers.find(item=>item.id===payload.provider)||owner.providers[0]
      if(!provider)throw Error('Node 服务未提供影视来源')
      const args=operation==='search'?{wd:payload.keyword,quick:false,pg:payload.page||1}:operation==='category'?{tid:payload.categoryId,pg:payload.page||1,filter:true,extend:payload.filters||{}}:operation==='detail'?{ids:[payload.id]}:operation==='play'?{flag:payload.lineId||'',id:payload.id,flags:[]}:{}
      value=await sourceJSON(owner.base+provider.api+'/'+operation,args)
      if(operation==='home' && !value.list?.length){const recommended=await sourceJSON(owner.base+provider.api+'/homeVod',{});value={...value,list:recommended.list||[]}}
    }else if(owner.protocol==='widget-extractor'){
      if(operation==='home')value={class:[],list:[]}
      else if(operation==='search'){
        if(typeof owner.module.loadResource!=='function')throw Error('Widget 脚本已失效')
        const searchToken=++owner.widgetSearchToken
        const result=await owner.module.loadResource({seriesName:String(payload.keyword||payload.seriesName||''),title:String(payload.keyword||payload.title||''),episode:Number(payload.episode)||1})
        if(owner!==owners.get(payload.session) || owner.closed)throw Error('旧 Widget 搜索已失效')
        if(searchToken!==owner.widgetSearchToken)throw Error('搜索结果已过期，请重新搜索')
        value=widgetRows(owner,result)
      }else if(operation==='detail'){
        const item=owner.widgetItems?.get(String(payload.id||''));if(!item)throw Error('解析结果已过期，请重新搜索')
        value={id:String(payload.id),name:String(item.name||item.title||'播放线路'),description:String(item.description||''),lines:[{id:'direct',name:String(item.name||'直连'),episodes:[{id:String(payload.id),name:'播放'}]}]}
      }else if(operation==='play'){
        const item=owner.widgetItems?.get(String(payload.id||''));if(!item)throw Error('解析结果已过期，请重新搜索')
        value={url:item.url||item.playUrl,headers:item.headers||item.header||item.customHeaders||{},parse:0}
      }else throw Error('Widget 影视脚本不支持 '+operation)
    }else{
      const module=owner.module,catvod=isCatVodProtocol(owner.protocol)
      if(operation==='catalog'){
        if(owner.protocol==='iptv-extractor'){
          const raw=await module.fetch(owner.payload.options||{});value=[]
          for(const group of raw.groups||[])for(const item of group.dataList||[]){const ref=item.deferredRef??item.pID??item.id;if(ref==null||!item.name)continue;const pictures=item.pics||{};value.push({id:String(ref),ref:String(ref),name:String(item.name),group:String(group.name||''),logo:typeof pictures==='string'?pictures:pictures.highResolution||pictures.lowResolution||pictures.icon||item.logo||''})}
        }else{const fn=module.channels||module.catalog;value=typeof fn==='function'?await fn.call(module):fn||[]}
      }
      else if(operation==='resolve'&&owner.protocol==='iptv-extractor'){const options=owner.payload.options||{};value=await module.resolve(payload.ref||payload.id,{...payload,config:options,account:{userId:options.userId||'',token:options.token||''}})}
      else if(operation==='providers')value=typeof module.providers==='function'?await module.providers():[]
      else if(operation==='home'){value=typeof module.home==='function'?await module.home(catvod?true:payload):{};if(!value.list?.length && module.homeVod)value={...value,list:(await module.homeVod()).list||[]}}
      else if(typeof module[operation]!=='function')throw Error('Node 模块不支持 '+operation)
      else if(catvod){const args=operation==='category'?[String(payload.categoryId),String(payload.page||1),true,payload.filters||{}]:operation==='search'?[payload.keyword,false,String(payload.page||1)]:operation==='detail'?[owner.modernCatVod?String(payload.id):[payload.id]]:operation==='play'?[payload.lineId||'',payload.id,[]]:[payload];value=await module[operation](...args)}
      else value=await module[operation](payload)
    }
    if(owner!==owners.get(payload.session) || owner.closed)throw Error('旧 Node 会话结果已失效')
    return typeof value==='string'?(()=>{try{return JSON.parse(value)}catch{return value}})():value
  })
}
async function stop(payload){
  const owner=owners.get(payload.session)
  if(!owner)return true
  if(!owner.stopPromise)owner.stopPromise=(async()=>{
    if(owner.ready&&!owner.metadata){try{await owner.ready}catch{return true}}
    if(owner.closed)return true
    // Let an owned Fastify/server close hook release its listener cleanly.
    // Timers and client work stop first; any listener left behind is force
    // closed in finally, including plugins with no cooperative close hook.
    cancelHandles(owner,false)
    try{const close=owner.module?.stop||owner.module?.close||owner.module?.destroy;if(typeof close==='function')await scope.run(owner,()=>close.call(owner.module))}
    finally{cancelHandles(owner)}
    owner.closed=true
    closedLogs.set(owner.session,owner.logs.slice(-20))
    for(const name of Object.keys(require.cache))if(name.startsWith(owner.root+path.sep))delete require.cache[name]
    owners.delete(owner.session)
    return true
  })()
  return deadline(owner.stopPromise,2500,'Node 插件停止超时，仍保留真实运行状态')
}
process.on('unhandledRejection',error=>console.error('插件异步错误:',error?.message||String(error)))
process.on('uncaughtException',error=>{const owner=scope.getStore();appendLog(owner,'插件回调异常: '+(error?.message||String(error)));if(owner){owner.failure=error?.message||String(error);cancelHandles(owner)}})
const server=http.createServer(async(req,res)=>{
  if(req.headers['x-cctvhost-token']!==token){res.writeHead(403);res.end();return}
  if(inflight>=8){res.writeHead(503);res.end();return}
  inflight++
  let payload={};let operation=''
  try{
    if(req.method==='GET'&&req.url==='/health'){res.setHeader('Content-Type','application/json');res.end(JSON.stringify({ok:true,node:process.versions.node}));return}
    if(req.method!=='POST'||req.url!=='/control'){res.writeHead(404);res.end();return}
    let size=0,chunks=[]
    for await(const chunk of req){size+=chunk.length;if(size>262144)throw Error('Node 控制请求过大');chunks.push(chunk)}
    const input=JSON.parse(Buffer.concat(chunks).toString('utf8'));operation=input.operation;payload=input.payload||{}
    const result=operation==='start'?await start(payload):operation==='stop'?await stop(payload):operation==='state'?{active:owners.size>0,sessions:[...owners.keys()]}:await invoke(operation,payload)
    const encoded=JSON.stringify({ok:true,result,logs:drainLogs(payload.session)})
    if(Buffer.byteLength(encoded)>2*1024*1024)throw Error('Node 结果超过 2 MB')
    res.setHeader('Content-Type','application/json');res.end(encoded)
  }catch(error){res.setHeader('Content-Type','application/json');res.end(JSON.stringify({ok:false,error:error?.message||String(error),logs:drainLogs(payload?.session)}))}
  finally{inflight--}
})
server.requestTimeout=30000;server.headersTimeout=10000;server.maxConnections=12
server.listen(0,'127.0.0.1',()=>{fs.writeFileSync(infoPath+'.tmp',JSON.stringify({port:server.address().port}));fs.renameSync(infoPath+'.tmp',infoPath)})
