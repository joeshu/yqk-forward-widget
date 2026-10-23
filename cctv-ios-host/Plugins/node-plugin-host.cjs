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
let active=null,inflight=0
const logLines=[]
for(const key of ['log','info','warn','error','debug'])console[key]=(...args)=>{logLines.push(args.map(value=>{try{return typeof value==='string'?value:JSON.stringify(value)}catch{return '[无法显示日志对象]'}}).join(' ').slice(0,1024));if(logLines.length>64)logLines.shift()}
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
function cancelHandles(owner){
  for(const [timer,clear] of owner.timers)original[clear](timer)
  owner.timers.clear()
  for(const stream of owner.streams)stream.destroy()
  for(const socket of owner.sockets)socket.destroy()
  for(const server of owner.servers){server.closeAllConnections?.();server.close()}
}
function deadline(promise,ms,label){let timer;return Promise.race([promise,new Promise((_,reject)=>{timer=original.setTimeout(()=>reject(Error(label)),ms)})]).finally(()=>original.clearTimeout(timer))}
function readableRoot(value){const root=fs.realpathSync(value);if(!root.startsWith(allowedRoot+path.sep))throw Error('Node 资源不在已安装目录中');return root}
function entryPath(root,entry){const value=fs.realpathSync(path.resolve(root,entry));if(!value.startsWith(root+path.sep))throw Error('Node 入口超出资源目录');return value}
async function readLimited(response){let length=0,chunks=[];for await(const chunk of response.body){length+=chunk.length;if(length>2*1024*1024)throw Error('Node 来源响应超过 2 MB');chunks.push(Buffer.from(chunk))}return Buffer.concat(chunks)}
async function sourceJSON(url,body){
  const response=await fetch(url,{method:body===undefined?'GET':'POST',headers:{'Content-Type':'application/json'},body:body===undefined?undefined:JSON.stringify(body),signal:AbortSignal.timeout(20000)})
  const text=(await readLimited(response)).toString('utf8')
  if(!response.ok)throw Error('Node 来源 HTTP '+response.status)
  return JSON.parse(text)
}
function installCatvodGlobals(owner){
  const file=path.join(owner.data,'js-storage.json')
  let storage={};try{storage=JSON.parse(fs.readFileSync(file,'utf8'))}catch{}
  global.local={get:(namespace,key)=>storage[namespace]?.[key]??'',set:(namespace,key,value)=>{storage[namespace]??={};storage[namespace][key]=value;const text=JSON.stringify(storage);if(text.length>1024*1024)throw Error('插件存储超过 1 MB');fs.writeFileSync(file+'.tmp',text);fs.renameSync(file+'.tmp',file)},delete:(namespace,key)=>{if(storage[namespace])delete storage[namespace][key]}}
  global.req=async(url,options={})=>{
    let body=options.body??options.data,headers={...(options.headers||{})}
    if(body && typeof body==='object'){body=JSON.stringify(body);headers['Content-Type']??='application/json'}
    const response=await fetch(url,{method:options.method||'GET',headers,body,signal:AbortSignal.timeout(Math.min(options.timeout||12000,20000))})
    const bytes=await readLimited(response)
    return {code:response.status,headers:Object.fromEntries(response.headers),content:options.buffer===2?[...bytes]:options.buffer===1?bytes.toString('base64'):bytes.toString('utf8')}
  }
  global.request=async(...args)=>(await global.req(...args)).content
  global.getProxy=()=>owner.payload.proxyURL||''
}
async function start(payload){
  if(active){if(active.session===payload.session)return active.metadata;throw Error('上一个 Node 插件尚未完全停止')}
  const root=readableRoot(payload.packageRoot),entry=entryPath(root,payload.entry)
  const data=readableRoot(payload.dataDirectory)
  const owner={session:payload.session,root,data,cwd:data,payload,protocol:payload.protocol,timers:new Map(),sockets:new Set(),servers:new Set(),streams:new Set(),closed:false,stopPromise:null,providers:[]}
  active=owner
  try{return await scope.run(owner,async()=>{
    process.env.CATPAW_DATA_DIR=data;process.env.NODE_PATH=data;process.env.DEV_HTTP_PORT='0'
    installCatvodGlobals(owner)
    let module=payload.moduleType==='esm'?await import(pathToFileURL(entry).href+'?session='+encodeURIComponent(payload.session)):require(entry)
    owner.module=module.default||module
    if(owner.protocol==='catpaw-http'){
      if(typeof owner.module.start!=='function')throw Error('Node 服务未导出 start()')
      await owner.module.start(payload.options||{})
      const server=[...owner.servers].find(server=>server.listening && server.address()?.port)
      if(!server)throw Error('Node 服务未开启可用的本机 HTTP 监听')
      owner.base='http://127.0.0.1:'+server.address().port
      const config=await sourceJSON(owner.base+'/config')
      owner.providers=(config.video?.sites||[]).filter(site=>typeof site.api==='string'&&site.api.startsWith('/spider/')).map(site=>({id:String(site.key),name:String(site.name),api:site.api}))
      owner.metadata={engine:'Node.js Mobile',version:process.versions.node,protocol:'catpaw-http',capabilities:['providers','home','category','search','detail','play']}
    }else{
      if(typeof owner.module==='function')owner.module=await owner.module(payload.options||{})
      if(!owner.module || typeof owner.module!=='object')throw Error('Node 入口未导出插件对象')
      if(owner.protocol==='catvod-js')for(const [key,alias] of Object.entries({home:'homeContent',homeVod:'homeVideoContent',category:'categoryContent',search:'searchContent',detail:'detailContent',play:'playerContent'}))if(!owner.module[key] && typeof owner.module[alias]==='function')owner.module[key]=owner.module[alias]
      if(typeof owner.module.init==='function')await owner.module.init(payload.options||{})
      owner.metadata={engine:'Node.js Mobile',version:process.versions.node,protocol:owner.protocol,capabilities:['home','category','search','detail','play','providers','proxy'].filter(key=>typeof owner.module[key]==='function').concat((owner.module.channels||owner.module.catalog||(owner.protocol==='iptv-extractor'&&owner.module.fetch))&&owner.module.resolve?['live']:[])}
    }
    return owner.metadata
  })}catch(error){cancelHandles(owner);owner.closed=true;active=null;throw error}
}
async function invoke(operation,payload){
  const owner=active
  if(!owner || owner.session!==payload.session || owner.closed)throw Error('Node 会话已经停止或不匹配')
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
    }else{
      const module=owner.module,catvod=owner.protocol==='catvod-js'
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
      else if(catvod){const args=operation==='category'?[String(payload.categoryId),String(payload.page||1),true,payload.filters||{}]:operation==='search'?[payload.keyword,false,String(payload.page||1)]:operation==='detail'?[[payload.id]]:operation==='play'?[payload.lineId||'',payload.id,[]]:[payload];value=await module[operation](...args)}
      else value=await module[operation](payload)
    }
    if(owner!==active || owner.closed)throw Error('旧 Node 会话结果已失效')
    return typeof value==='string'?(()=>{try{return JSON.parse(value)}catch{return value}})():value
  })
}
async function stop(payload){
  const owner=active
  if(!owner || owner.session!==payload.session)return true
  if(!owner.stopPromise)owner.stopPromise=(async()=>{
    cancelHandles(owner)
    try{const close=owner.module?.stop||owner.module?.close||owner.module?.destroy;if(typeof close==='function')await scope.run(owner,()=>close.call(owner.module))}
    finally{cancelHandles(owner)}
    owner.closed=true
    for(const name of Object.keys(require.cache))if(name.startsWith(owner.root+path.sep))delete require.cache[name]
    if(active===owner)active=null
    return true
  })()
  return deadline(owner.stopPromise,2500,'Node 插件停止超时，仍保留真实运行状态')
}
process.on('unhandledRejection',error=>console.error('插件异步错误:',error?.message||String(error)))
process.on('uncaughtException',error=>{console.error('插件回调异常:',error?.message||String(error));if(active){active.failure=error?.message||String(error);cancelHandles(active)}})
const server=http.createServer(async(req,res)=>{
  if(req.headers['x-cctvhost-token']!==token){res.writeHead(403);res.end();return}
  if(inflight>=8){res.writeHead(503);res.end();return}
  inflight++
  try{
    if(req.method==='GET'&&req.url==='/health'){res.setHeader('Content-Type','application/json');res.end(JSON.stringify({ok:true,node:process.versions.node}));return}
    if(req.method!=='POST'||req.url!=='/control'){res.writeHead(404);res.end();return}
    let size=0,chunks=[]
    for await(const chunk of req){size+=chunk.length;if(size>262144)throw Error('Node 控制请求过大');chunks.push(chunk)}
    const {operation,payload}=JSON.parse(Buffer.concat(chunks).toString('utf8'))
    const result=operation==='start'?await start(payload):operation==='stop'?await stop(payload):operation==='state'?{active:!!active,session:active?.session}:await invoke(operation,payload)
    const encoded=JSON.stringify({ok:true,result,logs:logLines.splice(0,20)})
    if(Buffer.byteLength(encoded)>2*1024*1024)throw Error('Node 结果超过 2 MB')
    res.setHeader('Content-Type','application/json');res.end(encoded)
  }catch(error){res.setHeader('Content-Type','application/json');res.end(JSON.stringify({ok:false,error:error?.message||String(error),logs:logLines.splice(0,20)}))}
  finally{inflight--}
})
server.requestTimeout=30000;server.headersTimeout=10000;server.maxConnections=12
server.listen(0,'127.0.0.1',()=>{fs.writeFileSync(infoPath+'.tmp',JSON.stringify({port:server.address().port}));fs.renameSync(infoPath+'.tmp',infoPath)})
