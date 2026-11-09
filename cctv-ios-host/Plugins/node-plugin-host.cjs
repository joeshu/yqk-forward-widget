/* One Node.js Mobile instance per app process; individual plugins are disposable.
 * This host is a lifecycle boundary, not an OS security/process sandbox.
 */
'use strict'
const http=require('node:http'),https=require('node:https'),net=require('node:net'),nodeCrypto=require('node:crypto'),zlib=require('node:zlib')
const fs=require('node:fs'),path=require('node:path'),vm=require('node:vm')
const {Readable}=require('node:stream')
function createPureJSWebTransport(){
  class Headers{
    constructor(init){this._map=new Map();this._raw=new Map();if(init){if(init instanceof Headers){for(const [k,v] of init.entries())this.set(k,v);if(init._raw)for(const [k,arr] of init._raw.entries())this._raw.set(k,[...arr])}else if(Array.isArray(init)){for(const [k,v] of init)this.append(k,v)}else if(typeof init==='object'){for(const [k,v] of Object.entries(init))if(v!==undefined){if(Array.isArray(v))for(const item of v)this.append(k,item);else this.set(k,v)}}}}
    _key(name){return String(name).toLowerCase()}
    get(name){const k=this._key(name);return this._map.has(k)?this._map.get(k):null}
    set(name,value){const k=this._key(name),v=String(value);this._map.set(k,v);this._raw.set(k,[v])}
    append(name,value){const k=this._key(name),v=String(value);const prev=this._map.get(k);this._map.set(k,prev!==undefined?prev+', '+v:v);const arr=this._raw.get(k)||[];arr.push(v);this._raw.set(k,arr)}
    has(name){return this._map.has(this._key(name))}
    delete(name){const k=this._key(name);this._map.delete(k);this._raw.delete(k)}
    entries(){return this._map.entries()}
    keys(){return this._map.keys()}
    values(){return this._map.values()}
    forEach(cb,thisArg){for(const [k,v] of this._map.entries())cb.call(thisArg,v,k,this)}
    raw(){return Object.fromEntries(this._raw.entries())}
    [Symbol.iterator](){return this._map.entries()}
  }
  class Blob{
    constructor(parts=[],options={}){const chunks=[];for(const p of parts){if(Buffer.isBuffer(p))chunks.push(p);else if(p instanceof Blob)chunks.push(p._buffer);else if(ArrayBuffer.isView(p))chunks.push(Buffer.from(p.buffer,p.byteOffset,p.byteLength));else if(p instanceof ArrayBuffer)chunks.push(Buffer.from(p));else chunks.push(Buffer.from(String(p??''),'utf8'))}this._buffer=Buffer.concat(chunks);this.size=this._buffer.length;this.type=String(options.type||'').toLowerCase()}
    async arrayBuffer(){return this._buffer.buffer.slice(this._buffer.byteOffset,this._buffer.byteOffset+this._buffer.byteLength)}
    async text(){return this._buffer.toString('utf8')}
    slice(start=0,end=this.size,type=''){return new Blob([this._buffer.subarray(start,end)],{type})}
  }
  class File extends Blob{
    constructor(parts,name,options={}){super(parts,options);this.name=String(name??'');this.lastModified=Number(options.lastModified??Date.now())}
  }
  class FormData{
    constructor(){this._entries=[]}
    append(name,value,filename){const k=String(name);if(value instanceof Blob&&!(value instanceof File))value=new File([value],filename||'blob',{type:value.type});else if(!(value instanceof File))value=String(value??'');this._entries.push([k,value])}
    set(name,value,filename){const k=String(name);this.delete(k);this.append(k,value,filename)}
    get(name){const k=String(name);const found=this._entries.find(([key])=>key===k);return found?found[1]:null}
    getAll(name){const k=String(name);return this._entries.filter(([key])=>key===k).map(([,v])=>v)}
    has(name){const k=String(name);return this._entries.some(([key])=>key===k)}
    delete(name){const k=String(name);this._entries=this._entries.filter(([key])=>key!==k)}
    *entries(){yield* this._entries}
    *keys(){for(const [k] of this._entries)yield k}
    *values(){for(const [,v] of this._entries)yield v}
    forEach(cb,thisArg){for(const [k,v] of this._entries)cb.call(thisArg,v,k,this)}
    [Symbol.iterator](){return this.entries()}
  }
  class Request{
    constructor(input,init={}){if(input instanceof Request){this.url=input.url;this.method=init.method||input.method||'GET';this.headers=new Headers(init.headers||input.headers);this.body=init.body!==undefined?init.body:input.body;this.signal=init.signal||input.signal||null;this.redirect=init.redirect||input.redirect||'follow'}else{this.url=String(input instanceof URL?input.href:input);this.method=String(init.method||'GET').toUpperCase();this.headers=new Headers(init.headers);this.body=init.body!==undefined?init.body:null;this.signal=init.signal||null;this.redirect=init.redirect||'follow'}}
  }
  class Response{
    constructor(body=null,init={}){this.status=init.status!==undefined?Number(init.status):200;this.statusText=String(init.statusText||'');this.ok=this.status>=200&&this.status<300;this.headers=new Headers(init.headers);this.url=String(init.url||'');this.redirected=Boolean(init.redirected);if(body===null||body===undefined)this.body=null;else if(body instanceof Readable)this.body=body;else if(Buffer.isBuffer(body))this.body=Readable.from([body]);else this.body=Readable.from([Buffer.from(String(body),'utf8')])}
    async _bytes(){if(!this.body)return Buffer.alloc(0);const chunks=[];for await(const chunk of this.body)chunks.push(Buffer.isBuffer(chunk)?chunk:Buffer.from(chunk));return Buffer.concat(chunks)}
    async buffer(){return this._bytes()}
    async arrayBuffer(){const b=await this._bytes();return b.buffer.slice(b.byteOffset,b.byteOffset+b.byteLength)}
    async text(){return (await this._bytes()).toString('utf8')}
    async json(){return JSON.parse(await this.text())}
  }
  function makeAbortError(msg='The operation was aborted.'){const err=new Error(msg);err.name='AbortError';return err}
  async function pureFetch(input,init={}){
    const reqObj=input instanceof Request?new Request(input,init):new Request(input,init)
    let currentURL=new URL(reqObj.url),method=String(reqObj.method||'GET').toUpperCase(),headers=new Headers(reqObj.headers),body=reqObj.body,redirected=false
    if(body!=null&&!Buffer.isBuffer(body)){
      if(typeof body==='string')body=Buffer.from(body,'utf8')
      else if(body instanceof URLSearchParams){body=Buffer.from(body.toString(),'utf8');if(!headers.has('content-type'))headers.set('content-type','application/x-www-form-urlencoded;charset=UTF-8')}
      else if(body instanceof Blob)body=body._buffer
      else if(ArrayBuffer.isView(body))body=Buffer.from(body.buffer,body.byteOffset,body.byteLength)
      else if(body instanceof ArrayBuffer)body=Buffer.from(body)
      else body=Buffer.from(String(body),'utf8')
    }
    if(['GET','HEAD'].includes(method))body=null
    for(let redirects=0;redirects<=20;redirects++){
      if(reqObj.signal?.aborted)throw makeAbortError()
      const reqHeaders=Object.fromEntries(headers.entries())
      if(!headers.has('accept-encoding'))reqHeaders['accept-encoding']='gzip, deflate, br'
      if(body&&!headers.has('content-length'))reqHeaders['content-length']=String(body.length)
      const transport=currentURL.protocol==='https:'?https:http
      const incoming=await new Promise((resolve,reject)=>{
        let settled=false,req
        const onAbort=()=>{if(settled)return;settled=true;try{req?.destroy()}catch{};reject(makeAbortError())}
        if(reqObj.signal){if(reqObj.signal.aborted)return onAbort();reqObj.signal.addEventListener('abort',onAbort,{once:true})}
        const cleanup=()=>{if(reqObj.signal)try{reqObj.signal.removeEventListener('abort',onAbort)}catch{}}
        req=transport.request(currentURL,{method,headers:reqHeaders},res=>{if(settled)return;settled=true;cleanup();resolve(res)})
        req.on('error',err=>{if(settled)return;settled=true;cleanup();reject(err)})
        if(body&&body.length)req.write(body)
        req.end()
      })
      const status=incoming.statusCode||200
      const respHeaders=new Headers()
      for(const [k,v] of Object.entries(incoming.headers||{})){if(Array.isArray(v))for(const item of v)respHeaders.append(k,item);else if(v!==undefined)respHeaders.set(k,v)}
      if([301,302,303,307,308].includes(status)){
        if(reqObj.redirect==='manual'){incoming.resume();return new Response(null,{status,statusText:incoming.statusMessage||'',headers:respHeaders,url:currentURL.href,redirected})}
        if(reqObj.redirect==='error'){incoming.resume();throw new TypeError('uri requested responds with a redirect, redirect mode is set to error')}
        const location=respHeaders.get('location')
        if(!location)return new Response(incoming,{status,statusText:incoming.statusMessage||'',headers:respHeaders,url:currentURL.href,redirected})
        incoming.resume()
        if(redirects===20)throw new TypeError('maximum redirect reached')
        const nextURL=new URL(location,currentURL)
        if(nextURL.origin!==currentURL.origin){headers.delete('authorization');headers.delete('cookie');headers.delete('host')}
        if(status===303||((status===301||status===302)&&method==='POST')){method='GET';body=null;headers.delete('content-length');headers.delete('content-type')}
        currentURL=nextURL;redirected=true;continue
      }
      let stream=incoming
      const enc=String(respHeaders.get('content-encoding')||'').toLowerCase()
      if(method!=='HEAD'&&status!==204&&status!==304){
        if(enc==='gzip'||enc==='x-gzip')stream=incoming.pipe(zlib.createGunzip())
        else if(enc==='deflate')stream=incoming.pipe(zlib.createInflate())
        else if(enc==='br')stream=incoming.pipe(zlib.createBrotliDecompress())
      }
      if(reqObj.signal){
        const onStreamAbort=()=>{try{incoming.destroy(makeAbortError());stream.destroy?.(makeAbortError())}catch{}}
        if(reqObj.signal.aborted)onStreamAbort()
        else{reqObj.signal.addEventListener('abort',onStreamAbort,{once:true});stream.once('close',()=>{try{reqObj.signal.removeEventListener('abort',onStreamAbort)}catch{}})}
      }
      return new Response(stream,{status,statusText:incoming.statusMessage||'',headers:respHeaders,url:currentURL.href,redirected})
    }
  }
  return {default:pureFetch,Headers,Request,Response,FormData,Blob,File}
}
const bundledFetchCandidates=[path.join(__dirname,'node-fetch.bundle.cjs'),path.join(__dirname,'../GeneratedJS/node-fetch.bundle.cjs')]
const bundledFetch=bundledFetchCandidates.find(candidate=>fs.existsSync(candidate))
const fetchExports=bundledFetch?require(bundledFetch):createPureJSWebTransport(),nativeFetch=fetchExports.default||fetchExports
// Accessing Node's lazy native FormData/File getters can initialize undici's
// WASM parser even when fetch itself has been replaced. Install the complete
// pure JS web transport family without invoking those native getters.
for(const [name,value] of Object.entries({fetch:nativeFetch,Headers:fetchExports.Headers,Request:fetchExports.Request,Response:fetchExports.Response,FormData:fetchExports.FormData,Blob:fetchExports.Blob,File:fetchExports.File}))if(value)Object.defineProperty(global,name,{value,writable:true,configurable:true,enumerable:true})
const {pathToFileURL}=require('node:url')
const {AsyncLocalStorage}=require('node:async_hooks')
const scope=new AsyncLocalStorage()
const owners=new Map()
const closedLogs=new Map()
const hostLogs=[]
function scopedGlobal(name){let fallback=global[name];Object.defineProperty(global,name,{configurable:true,enumerable:true,get(){const owner=scope.getStore();return owner&&Object.prototype.hasOwnProperty.call(owner.globals,name)?owner.globals[name]:fallback},set(value){const owner=scope.getStore();if(owner)owner.globals[name]=value;else fallback=value}})}
for(const name of ['Pans','local','req','request','net','getProxy','getProxyUrl','catServerFactory','catDartServerPort','getPanName','getPanEnabled','messageToDart','websiteBundle','danmuBundle','webBundle','webHtml','webStyle','__CAT_JS_UTIL','__EXPORTED_SPIDER__','lastDanmuProxyName'])scopedGlobal(name)
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
const watch=fs.watch
fs.watch=function(...args){const owner=scope.getStore();if(owner&&(owner.closed||owner.watchers.size>=32))throw Error('插件文件监听超过限制或已停止');const watcher=watch.apply(this,args);if(owner){owner.watchers.add(watcher);watcher.once('close',()=>owner.watchers.delete(watcher))}return watcher}
let inflight=0
function appendLog(owner,line){const lines=owner?.logs||hostLogs;lines.push(String(line).slice(0,1024));if(lines.length>64)lines.shift()}
const nativeHTTPSRequest=https.request
const nativeHTTPRequest=http.request
const certificateErrors=/^(?:CERT_|ERR_TLS_CERT|DEPTH_ZERO_SELF_SIGNED_CERT|SELF_SIGNED_CERT_IN_CHAIN|UNABLE_TO_VERIFY_LEAF_SIGNATURE|UNABLE_TO_GET_ISSUER_CERT|ERR_TLS_SERVER_CERT_CHANGED|ERR_SSL_(?:CERTIFICATE_VERIFY_FAILED|BAD_CERTIFICATE|PEER_DID_NOT_RETURN_A_CERTIFICATE|EE_KEY_TOO_SMALL|CA_MD_TOO_WEAK|NO_CERTIFICATE_ASSIGNED))/
const recoverableHTTPSErrors=new Set(['ECONNRESET','ECONNREFUSED','ECONNABORTED','ETIMEDOUT','EHOSTUNREACH','ENETUNREACH','EAI_AGAIN','ENOTFOUND','ERR_SSL_UNEXPECTED_EOF_WHILE_READING'])
function recoverableHTTPSError(error){const code=String(error?.code||'');if(!code||error?.authorizationError||certificateErrors.test(code))return false;return recoverableHTTPSErrors.has(code)||code==='ERR_TLS_HANDSHAKE_TIMEOUT'||code.startsWith('ERR_SSL_')}
function nodeHTTPSRequestDetails(args,request){
  const first=args[0],fromURL=first instanceof URL||typeof first==='string'
  let base=null,options={}
  if(fromURL){try{base=new URL(first instanceof URL?first.href:first)}catch{return null}if(args[1]&&typeof args[1]==='object'&&!(args[1] instanceof URL))options=args[1]}
  else if(first&&typeof first==='object')options=first
  const protocol=String(options.protocol||base?.protocol||'https:').toLowerCase()
  if(protocol!=='https:')return null
  const hostname=String(options.hostname||options.host||base?.hostname||'')
  if(!hostname||hostname.includes('/')||hostname.includes('@'))return null
  const tlsOptions=['agent','ca','cert','key','pfx','passphrase','ciphers','sigalgs','ecdhCurve','dhparam','secureOptions','secureProtocol','checkServerIdentity','rejectUnauthorized','servername','session','secureContext']
  if(tlsOptions.some(key=>Object.prototype.hasOwnProperty.call(options,key)&&options[key]!=null&&!(key==='agent'&&(options[key]===https.globalAgent||options[key]===false))))return null
  const host=hostname.includes(':')&&!hostname.startsWith('[')?'['+hostname+']':hostname
  const port=options.port??base?.port
  let authority=host
  if(port)authority+=':'+String(port)
  let target
  try{target=base?new URL(base.href):new URL('https://'+authority+'/')}catch{return null}
  if(options.hostname||options.host){try{target=new URL('https://'+authority+(port?'/':''))}catch{return null}}
  const requestPath=options.path??(base?base.pathname+base.search:'/')
  if(typeof requestPath!=='string'||requestPath.length>8192||/^https?:\/\//i.test(requestPath))return null
  try{target=new URL(requestPath||'/',target);if(target.protocol!=='https:'||target.username||target.password)return null;target.hash=''}catch{return null}
  const method=String(options.method||'GET').toUpperCase()
  if(!['GET','HEAD','POST'].includes(method))return null
  return {target,method,timeoutMs:Number(options.timeout)||15000}
}
function hostFetchEndpoint(owner){
  if(!owner||owner.closed||typeof owner.payload.hostFetchURL!=='string'||typeof owner.payload.hostFetchToken!=='string')return null
  try{const endpoint=new URL(owner.payload.hostFetchURL);if(endpoint.protocol!=='http:'||!['127.0.0.1','localhost','[::1]'].includes(endpoint.hostname)||endpoint.username||endpoint.password||endpoint.pathname!=='/_cctvhost/host-fetch'||endpoint.search||endpoint.hash)return null;return endpoint}catch{return null}
}
function requestHeadersForHost(request){
  let source={};try{source=request.getHeaders()}catch{}
  const output={};for(const [name,value] of Object.entries(source)){if(value==null)continue;const text=Buffer.isBuffer(value)?value.toString('utf8'):Array.isArray(value)?value.map(item=>String(item)).join(', '):String(value);if(text.length<=8192&&!/[\r\n]/.test(text))output[name]=text}
  return output
}
function hostFetchResponse(request,incoming,target){
  const response=new Readable({read(){}}),headers={},rawHeaders=Array.isArray(incoming.rawHeaders)?incoming.rawHeaders.slice(0,256):[]
  for(const [name,value] of Object.entries(incoming.headers||{}))headers[String(name).toLowerCase()]=Array.isArray(value)?value.slice():value
  response.statusCode=incoming.statusCode||502;response.statusMessage=String(incoming.statusMessage||'').slice(0,128);response.headers=headers;response.rawHeaders=rawHeaders
  response.httpVersion='1.1';response.httpVersionMajor=1;response.httpVersionMinor=1;response.complete=true;response.aborted=false
  response.trailers={};response.rawTrailers=[];response.req=request;response.socket=request.socket;response.connection=request.socket;response.url=target.pathname+target.search
  return response
}
function fetchHTTPSWithHost(owner,request,details,body=Buffer.alloc(0)){
  return new Promise((resolve,reject)=>{
    const endpoint=hostFetchEndpoint(owner);if(!endpoint)return reject(Error('本机 HTTPS 回退服务不可用'))
    const payload=Buffer.from(JSON.stringify({url:details.target.href,method:details.method,headers:requestHeadersForHost(request),timeoutMs:Math.max(1000,Math.min(details.timeoutMs,120000)),...(body.length?{bodyBase64:body.toString('base64')}:{})}))
    if(payload.length>2*1024*1024)return reject(Error('本机 HTTPS 回退请求超过限制'))
    let settled=false,length=0;const chunks=[];let bridge
    const finish=(error,value)=>{if(settled)return;settled=true;original.clearTimeout(timer);if(error)reject(error);else resolve(value)}
    const timer=original.setTimeout(()=>bridge?.destroy(Error('本机 HTTPS 回退超时')),Math.max(1000,Math.min(details.timeoutMs,120000)))
    bridge=nativeHTTPRequest(endpoint,{method:'POST',headers:{'X-CCTVHost-Host-Fetch':owner.payload.hostFetchToken,'Content-Type':'application/json','Content-Length':String(payload.length),'Connection':'close'}},incoming=>{
      incoming.on('data',chunk=>{length+=chunk.length;if(length>32*1024*1024){incoming.destroy(Error('本机 HTTPS 回退响应超过限制'));return}chunks.push(Buffer.from(chunk))})
      incoming.on('error',error=>finish(error))
      incoming.on('end',()=>finish(null,{incoming,body:Buffer.concat(chunks)}))
    })
    bridge.on('error',error=>finish(error));bridge.end(payload)
  })
}
https.request=function(...args){
  const owner=scope.getStore(),details=nodeHTTPSRequestDetails(args)
  if(!owner||!details||!hostFetchEndpoint(owner))return nativeHTTPSRequest.apply(this,args)
  const request=nativeHTTPSRequest.apply(this,args),nativeEmit=request.emit
  let wroteBody=false,bodyReplayable=true,bodySize=0,bodyChunks=[],fallbackStarted=false,fallbackClosed=false,pendingClose=false,responseSeen=false
  const originalWrite=request.write,originalEnd=request.end
  const hasData=chunk=>chunk!=null&&typeof chunk!=='function'&&(Buffer.isBuffer(chunk)?chunk.length:typeof chunk==='string'?Buffer.byteLength(chunk):ArrayBuffer.isView(chunk)?chunk.byteLength:1)>0
  const captureBody=(chunk,encoding)=>{
    if(!hasData(chunk))return
    wroteBody=true
    if(details.method!=='POST'||!bodyReplayable){bodyReplayable=false;return}
    let value
    try{value=Buffer.isBuffer(chunk)?Buffer.from(chunk):typeof chunk==='string'?Buffer.from(chunk,typeof encoding==='string'?encoding:'utf8'):ArrayBuffer.isView(chunk)?Buffer.from(chunk.buffer,chunk.byteOffset,chunk.byteLength):null}catch{}
    if(!value||bodySize+value.length>1024*1024){bodyReplayable=false;bodyChunks.length=0;return}
    bodySize+=value.length;bodyChunks.push(value)
  }
  request.write=function(chunk,...rest){captureBody(chunk,rest[0]);return originalWrite.call(this,chunk,...rest)}
  request.end=function(chunk,...rest){captureBody(chunk,rest[0]);return originalEnd.call(this,chunk,...rest)}
  request.emit=function(event,...values){
    if(event==='response')responseSeen=true
    if(event==='close'&&fallbackStarted&&!fallbackClosed){pendingClose=true;return true}
    if(event==='error'&&!responseSeen&&!fallbackStarted&&(!wroteBody||(details.method==='POST'&&bodyReplayable))&&recoverableHTTPSError(values[0])){
      fallbackStarted=true
      const fallbackDetails={...details,timeoutMs:Number(request.timeout)||details.timeoutMs}
      fetchHTTPSWithHost(owner,request,fallbackDetails,bodySize?Buffer.concat(bodyChunks,bodySize):Buffer.alloc(0)).then(({incoming,body})=>{
        const response=hostFetchResponse(request,incoming,details.target)
        response.once('close',()=>{fallbackClosed=true;if(pendingClose)nativeEmit.call(request,'close')})
        request.res=response
        appendLog(owner,'Node HTTPS 宿主回退成功：'+details.target.hostname)
        nativeEmit.call(request,'response',response)
        response.push(body);response.push(null);response.resume()
      },error=>{
        appendLog(owner,'Node HTTPS 宿主回退失败（'+details.target.hostname+'）：'+String(error?.code||'网络错误'))
        fallbackClosed=true;nativeEmit.call(request,'error',values[0])
        if(pendingClose)nativeEmit.call(request,'close')
      })
      return true
    }
    return nativeEmit.call(this,event,...values)
  }
  return request
}
https.get=function(...args){const request=https.request(...args);request.end();return request}
try{require('node:module').syncBuiltinESMExports()}catch{}
function failOwner(owner,context,error){const message=String(error?.message||error||'未知错误').slice(0,512),diagnostic=baseEnvironment.CCTVHOST_TEST_DIAGNOSTICS==='1'&&error?.stack?'\n'+String(error.stack).slice(0,2048):'';appendLog(owner,context+message+diagnostic);if(owner&&!owner.closed){owner.failure=message;cancelHandles(owner)}}
function drainLogs(identifier){const owner=owners.get(identifier),lines=owner?.logs||closedLogs.get(identifier)||hostLogs,result=lines.splice(0,20);if(!lines.length)closedLogs.delete(identifier);return result}
for(const key of ['log','info','warn','error','debug'])console[key]=(...args)=>{const owner=scope.getStore();appendLog(owner,args.map(value=>{try{return typeof value==='string'?value:JSON.stringify(value)}catch{return '[无法显示日志对象]'}}).join(' '))}
process.exit=()=>{throw Error('插件不能退出 CCTVHost 进程')}
process.kill=()=>{throw Error('插件不能终止 CCTVHost 进程')}
process.abort=()=>{throw Error('插件不能中止 CCTVHost 进程')}
const processOn=process.on,processOnce=process.once,processRemove=process.removeListener,processRemoveAll=process.removeAllListeners
for(const name of ['on','addListener','once'])process[name]=function(event,listener){const owner=scope.getStore();if(!owner)return (name==='once'?processOnce:processOn).call(this,event,listener);if(owner.closed||owner.listeners.length>=64)throw Error('插件进程监听超过限制或已停止');const wrapped=(...args)=>{if(name==='once'){processRemove.call(this,event,wrapped);owner.listeners=owner.listeners.filter(item=>item.wrapped!==wrapped)}if(!owner.closed)return scope.run(owner,()=>listener(...args))};owner.listeners.push({event,listener,wrapped});return processOn.call(this,event,wrapped)}
process.removeListener=process.off=function(event,listener){const owner=scope.getStore(),entry=owner?.listeners.find(item=>item.event===event&&item.listener===listener);if(entry)owner.listeners=owner.listeners.filter(item=>item!==entry);return processRemove.call(this,event,entry?.wrapped||listener)}
process.removeAllListeners=function(event){const owner=scope.getStore();if(!owner)return processRemoveAll.apply(this,arguments);for(const entry of owner.listeners.filter(item=>event===undefined||item.event===event)){processRemove.call(this,entry.event,entry.wrapped);owner.listeners=owner.listeners.filter(item=>item!==entry)}return this}
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
  if(owner?.protocol==='catpaw-http'&&args[0]&&typeof args[0]==='object')args[0]={...args[0],host:'127.0.0.1'}
  if(owner){if(owner.closed)throw Error('插件已停止');if(owner.servers.size>=4)throw Error('插件监听服务超过 4 个');owner.servers.add(this);this.on('connection',socket=>{owner.sockets.add(socket);socket.once('close',()=>owner.sockets.delete(socket))});this.once('close',()=>owner.servers.delete(this))}
  return listen.apply(this,args)
}
function cancelHandles(owner,closeServers=true){
  if(closeServers){for(const {event,wrapped} of owner.listeners)processRemove.call(process,event,wrapped);owner.listeners.length=0;for(const watcher of owner.watchers){try{watcher.close()}catch{}}owner.watchers.clear()}
  for(const controller of owner.nanoControllers||[]){try{controller.abort()}catch{}}owner.nanoControllers?.clear();owner.nanoMediaSessions?.clear()
  for(const [timer,clear] of owner.timers){try{original[clear](timer)}catch(error){appendLog(owner,'定时器清理失败：'+(error?.message||String(error)))}}
  owner.timers.clear()
  for(const stream of owner.streams){try{stream.destroy()}catch(error){appendLog(owner,'流清理失败：'+(error?.message||String(error)))}}
  for(const socket of owner.sockets){try{socket.destroy()}catch(error){appendLog(owner,'连接清理失败：'+(error?.message||String(error)))}}
  if(closeServers)for(const server of owner.servers){try{server.closeAllConnections?.();if(server.listening)server.close()}catch(error){appendLog(owner,'监听清理失败：'+(error?.message||String(error)))}}
}
function deadline(promise,ms,label){let timer;return Promise.race([promise,new Promise((_,reject)=>{timer=original.setTimeout(()=>reject(Error(label)),ms)})]).finally(()=>original.clearTimeout(timer))}
function readableRoot(value){const root=fs.realpathSync(value);if(!root.startsWith(allowedRoot+path.sep))throw Error('Node 资源不在已安装目录中');return root}
function entryPath(root,entry){const value=fs.realpathSync(path.resolve(root,entry));if(!value.startsWith(root+path.sep))throw Error('Node 入口超出资源目录');return value}
async function readLimited(response,limit=2*1024*1024){if(!response?.body)return Buffer.alloc(0);let length=0,chunks=[];for await(const chunk of response.body){length+=chunk.length;if(length>limit)throw Error('Node 来源响应超过大小限制');chunks.push(Buffer.from(chunk))}return Buffer.concat(chunks)}
function safeWidgetURL(value){try{const url=new URL(String(value||''));return ['http:','https:'].includes(url.protocol)&&url.hostname&&!url.username&&!url.password&&url.href.length<=8192?url.href:''}catch{return ''}}
function pluginHTTPURL(value){const url=new URL(String(value||''));if(!['http:','https:'].includes(url.protocol)||!url.hostname||url.username||url.password||url.href.length>8192)throw Error('插件 HTTP 仅支持有效的 HTTP/HTTPS 地址');return url}
function nanoDeclaration(source){
  const match=/\/\*\s*nanoTV-declaration\s*([\s\S]*?)\s*\*\//.exec(source)
  if(!match)return null
  let declaration
  try{declaration=JSON.parse(match[1])}catch{throw Error('NanoTV 声明头不是有效 JSON')}
  const manifest=declaration?.manifest
  const validHosts=value=>Array.isArray(value)&&value.length>0&&value.length<=64&&value.every(host=>typeof host==='string'&&host.length<=255&&/^\.?(?:[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?)(?:\.(?:[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?))*$/.test(host))
  if(declaration?.declarationVersion!==1||manifest?.apiVersion!==2||typeof manifest.id!=='string'||!manifest.id.length||manifest.id.length>128||!Array.isArray(manifest.capabilities)||!manifest.capabilities.length||manifest.capabilities.length>32||!manifest.capabilities.every(value=>typeof value==='string'&&value.length<=64)||!manifest.capabilities.includes('http')||!validHosts(manifest.networkHosts)||(['mediaHosts','mediaCredentialHosts'].some(key=>manifest[key]!==undefined&&!validHosts(manifest[key]))))throw Error('NanoTV 服务声明版本或字段不受支持')
  return {declaration,manifest}
}
function nanoHost(owner,manifest){
  const hostAllowed=(value,field='networkHosts')=>{
    let target
    try{target=pluginHTTPURL(value)}catch{return false}
    const roots=manifest[field]||manifest.networkHosts||[]
    return roots.some(root=>{const suffix=String(root||'').replace(/^\./,'').toLowerCase();return suffix&&((target.hostname.toLowerCase()===suffix)||target.hostname.toLowerCase().endsWith('.'+suffix))})
  }
  const safeLog=value=>String(value??'').replace(/https?:\/\/[^\s"'<>]+/gi,url=>{try{const parsed=new URL(url);return parsed.origin+'/[redacted]'}catch{return '[URL redacted]'}}).replace(/\b(cKey|flowid|APPSIGN|token|sig|signature|cookie|authorization|fingerprint)\s*[=:]\s*[^\s,;]+/gi,'$1=[redacted]').replace(/[\u0000-\u001f\u007f]+/g,' ').slice(0,512)
  const statePath=path.join(owner.data,'nanotv-storage.json')
  let state={};try{state=JSON.parse(fs.readFileSync(statePath,'utf8'))}catch{}
  if(!state||typeof state!=='object'||Array.isArray(state))state={}
  const save=()=>{const text=JSON.stringify(state);if(Buffer.byteLength(text)>512*1024)throw Error('NanoTV 插件存储超过 512 KB');const temp=statePath+'.tmp';fs.writeFileSync(temp,text,{mode:0o600});fs.renameSync(temp,statePath)}
  const mediaHeaders=input=>widgetHeaders(input)
  const mediaSessions=owner.nanoMediaSessions=new Map(),controllers=owner.nanoControllers=new Set(),schedulers=owner.nanoSchedulers=new Map()
  const request=async options=>{
    if(!options||typeof options!=='object')throw Error('NanoTV HTTP 请求参数无效')
    let url=pluginHTTPURL(options.url),method=String(options.method||'GET').toUpperCase()
    if(!['GET','POST','PUT','PATCH','DELETE','HEAD','OPTIONS'].includes(method))throw Error('NanoTV HTTP 方法不受支持')
    let headers=widgetHeaders(options.headers),body=options.body
    if(options.bodyEncoding==='base64'&&typeof body==='string')body=Buffer.from(body,'base64')
    else if(options.bodyEncoding==='hex'&&typeof body==='string'){if(body.length%2||!/^[0-9a-f]*$/i.test(body))throw Error('NanoTV 请求体不是有效十六进制');body=Buffer.from(body,'hex')}
    else if(body!=null&&!Buffer.isBuffer(body)&&!(body instanceof Uint8Array))body=Buffer.from(String(body),'utf8')
    if(body&&body.length>2*1024*1024)throw Error('NanoTV HTTP 请求体超过 2 MB')
    const timeout=Math.max(1000,Math.min(Number(options.timeoutSeconds)*1000||15000,30000))
    let response,bytes
    for(let redirects=0;redirects<=5;redirects++){
      if(!hostAllowed(url.href))throw Error('NanoTV 网络地址不在声明的 networkHosts 中')
      const controller=new AbortController();controllers.add(controller)
      const timer=original.setTimeout(()=>controller.abort(),timeout)
      let redirected=false
      try{
        response=await fetch(url.href,{method,headers,body:['GET','HEAD'].includes(method)?undefined:body,redirect:'manual',signal:controller.signal})
        if([301,302,303,307,308].includes(response.status)){
          const location=response.headers.get('location')
          if(!location||redirects===5)throw Error('NanoTV HTTP 重定向无效或次数过多')
          const next=new URL(location,url)
          if(!hostAllowed(next.href))throw Error('NanoTV 重定向目标不在声明的 networkHosts 中')
          if(next.origin!==url.origin){delete headers.authorization;delete headers.Authorization;delete headers.cookie;delete headers.Cookie}
          if(response.status===303||((response.status===301||response.status===302)&&method==='POST')){method='GET';body=undefined}
          url=next;redirected=true
        }else bytes=await readLimited(response,8*1024*1024)
      }catch(error){if(error?.name==='AbortError')throw Error('NanoTV 网络请求超时');throw Error(safeLog(error?.message||error))}
      finally{original.clearTimeout(timer);controllers.delete(controller)}
      if(redirected)continue
      break
    }
    const encoding=String(options.responseEncoding||'utf8').toLowerCase()
    const content=encoding==='base64'?bytes.toString('base64'):encoding==='hex'?bytes.toString('hex'):bytes.toString('utf8')
    return {status:response.status,ok:response.status>=200&&response.status<300,body:content,headers:Object.fromEntries(response.headers),url:url.href}
  }
  const convert=(value,from,to)=>{
    const source=String(from||'utf8').toLowerCase(),target=String(to||'utf8').toLowerCase()
    let bytes
    if(Array.isArray(value)||value instanceof Uint8Array)bytes=Buffer.from(value)
    else if(source==='base64')bytes=Buffer.from(String(value||''),'base64')
    else if(source==='hex'){const text=String(value||'');if(text.length%2||!/^[0-9a-f]*$/i.test(text))throw Error('NanoTV 字节转换输入无效');bytes=Buffer.from(text,'hex')}
    else bytes=Buffer.from(String(value??''),'utf8')
    if(target==='base64')return bytes.toString('base64')
    if(target==='hex')return bytes.toString('hex')
    if(target==='bytes'||target==='uint8array')return [...bytes]
    if(target==='utf8'||target==='utf-8')return bytes.toString('utf8')
    throw Error('NanoTV 字节转换编码不支持')
  }
  const crypto={
    digest:(algorithm,value)=>nodeCrypto.createHash(String(algorithm).toLowerCase()).update(Buffer.from(String(value??''),'utf8')).digest('hex'),
    seal:({key,data})=>{const secret=Buffer.from(String(key||''),'base64'),plain=Buffer.from(String(data||''),'base64');if(secret.length!==32||plain.length>1024*1024)throw Error('NanoTV AES-GCM 参数无效');const nonce=nodeCrypto.randomBytes(12),cipher=nodeCrypto.createCipheriv('aes-256-gcm',secret,nonce),encrypted=Buffer.concat([cipher.update(plain),cipher.final()]);return Buffer.concat([nonce,encrypted,cipher.getAuthTag()]).toString('base64')},
    open:({key,data})=>{const secret=Buffer.from(String(key||''),'base64'),combined=Buffer.from(String(data||''),'base64');if(secret.length!==32||combined.length<28||combined.length>1024*1024)throw Error('NanoTV AES-GCM 参数无效');const decipher=nodeCrypto.createDecipheriv('aes-256-gcm',secret,combined.subarray(0,12));decipher.setAuthTag(combined.subarray(-16));return Buffer.concat([decipher.update(combined.subarray(12,-16)),decipher.final()]).toString('base64')},
    rsaEncrypt:({publicKey,data})=>{const der=Buffer.from(String(publicKey||''),'base64'),pem='-----BEGIN PUBLIC KEY-----\n'+der.toString('base64').match(/.{1,64}/g).join('\n')+'\n-----END PUBLIC KEY-----';return nodeCrypto.publicEncrypt({key:pem,padding:nodeCrypto.constants.RSA_PKCS1_PADDING},Buffer.from(String(data||''),'base64')).toString('base64')},
    gzip:value=>zlib.gzipSync(Buffer.from(String(value||''),'base64'),{level:6}).toString('base64'),
    gunzip:value=>zlib.gunzipSync(Buffer.from(String(value||''),'base64'),{maxOutputLength:8*1024*1024}).toString('base64')
  }
  const scheduler={
    every:(name,interval,callback)=>{const key=String(name||'timer');const prior=schedulers.get(key);if(prior)clearInterval(prior);if(schedulers.size>=16&&!prior)throw Error('NanoTV 定时任务超过 16 个');const timer=setInterval(()=>{if(owner.closed)return;try{const result=callback();if(result&&typeof result.catch==='function')result.catch(error=>appendLog(owner,'NanoTV 定时任务失败：'+safeLog(error?.message||error)))}catch(error){appendLog(owner,'NanoTV 定时任务失败：'+safeLog(error?.message||error))}},Math.max(1000,Math.min(Number(interval)||1000,3600000)));schedulers.set(key,timer);return key},
    sleep:milliseconds=>new Promise(resolve=>setTimeout(resolve,Math.max(0,Math.min(Number(milliseconds)||0,120000))))
  }
  const refreshHLS=async id=>{
    const session=mediaSessions.get(String(id||''))
    if(!session||typeof session.refresh!=='function')throw Error('NanoTV HLS 会话没有可用的刷新回调')
    if(!session.refreshPromise)session.refreshPromise=(async()=>{
      const value=await session.refresh()
      const url=String(value?.manifestURL||value?.url||'')
      if(!hostAllowed(url,'mediaHosts'))throw Error('NanoTV HLS 刷新地址不在声明的 mediaHosts 中')
      const headers=mediaHeaders(value.headers||session.headers)
      if(Object.keys(headers).length&&!hostAllowed(url,'mediaCredentialHosts'))throw Error('NanoTV 媒体凭据地址不在声明的 mediaCredentialHosts 中')
      const expiresAt=Number(value.expiresAt)||session.expiresAt||0
      const now=Date.now()/1000
      const interval=session.liveWindow?Math.max(5,Math.min(Number(session.liveWindow.minPollSeconds)||5,300)):
        (expiresAt?Math.max(5,Math.min(300,expiresAt-now-8)):0)
      Object.assign(session,{url,headers,expiresAt,refreshInterval:interval})
      return {url,headers,expiresAt,refreshInterval:interval,refreshAfter:interval?now+interval:0}
    })()
    try{return await session.refreshPromise}finally{session.refreshPromise=null}
  }
  return {
    http:{request},
    crypto,
    bytes:{convert},
    storage:{get:key=>state[String(key)]===undefined?null:JSON.parse(JSON.stringify(state[String(key)])),set:(key,value)=>{const text=JSON.stringify(value);if(text===undefined||text.length>65536)throw Error('NanoTV 单项存储超过 64 KB');state[String(key)]=JSON.parse(text);save()},remove:key=>{delete state[String(key)];save()}},
    scheduler,
    media:{
      isOpen:id=>mediaSessions.has(String(id)),
      openHLS:options=>{
        const url=String(options?.manifestURL||'')
        if(!hostAllowed(url,'mediaHosts'))throw Error('NanoTV HLS 地址不在声明的 mediaHosts 中')
        const headers=mediaHeaders(options?.headers)
        if(Object.keys(headers).length&&!hostAllowed(url,'mediaCredentialHosts'))throw Error('NanoTV 媒体凭据地址不在声明的 mediaCredentialHosts 中')
        const expiresAt=Number(options.expiresAt)||0,now=Date.now()/1000
        const liveWindow=options.liveWindow&&typeof options.liveWindow==='object'?options.liveWindow:null
        const refreshInterval=liveWindow?Math.max(5,Math.min(Number(liveWindow.minPollSeconds)||5,300)):(expiresAt?Math.max(5,Math.min(300,expiresAt-now-8)):0)
        const sessionID=nodeCrypto.randomUUID()
        mediaSessions.set(sessionID,{url,headers,expiresAt,liveWindow,channelID:String(options.channelID||''),refreshInterval,refresh:typeof options.refresh==='function'?options.refresh:null})
        while(mediaSessions.size>64)mediaSessions.delete(mediaSessions.keys().next().value)
        return {sessionID,url,headers,expiresAt,refreshInterval,refreshAfter:refreshInterval?now+refreshInterval:0}
      },
      refreshHLS,
      info:id=>{const value=mediaSessions.get(String(id||''));return value?{sessionID:String(id),channelID:String(value.channelID||'')}:null}
    },
    now:()=>Date.now(),
    randomHex:bytes=>nodeCrypto.randomBytes(Math.max(0,Math.min(4096,Number(bytes)||0))).toString('hex'),
    log:value=>appendLog(owner,safeLog(value)),
    native:{
      randomHex:bytes=>nodeCrypto.randomBytes(Math.max(0,Math.min(4096,Number(bytes)||0))).toString('hex'),
      log:value=>appendLog(owner,safeLog(value)),
      http:(raw,callback)=>{let options;try{options=JSON.parse(raw)}catch{callback(JSON.stringify({ok:false,error:'NanoTV native.http 参数不是 JSON'}));return}request(options).then(value=>callback(JSON.stringify(value)),error=>callback(JSON.stringify({ok:false,error:safeLog(error?.message||error)})))}
    },
    status:()=>({mediaSessions:mediaSessions.size,scheduledTasks:schedulers.size})
  }
}
function boundedTimeout(value,fallback,maximum=20000){const requested=Number(value);return Math.max(1000,Math.min(Number.isFinite(requested)&&requested>0?requested:fallback,maximum))}
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
async function sourceJSON(url,body,requestHeaders={}){
  const target=new URL(url)
  if(!['http:','https:'].includes(target.protocol)||!['127.0.0.1','localhost','[::1]'].includes(target.hostname)||target.username||target.password)throw Error('Node 本机服务地址无效')
  const transport=target.protocol==='https:'?https:http,payload=body===undefined?null:Buffer.from(JSON.stringify(body))
  return new Promise((resolve,reject)=>{
    let settled=false,length=0;const chunks=[];let request
    const finish=(error,value)=>{if(settled)return;settled=true;original.clearTimeout(timer);if(error)reject(error);else resolve(value)}
    const timer=original.setTimeout(()=>request?.destroy(Error('Node 本机服务响应超时')),20000)
    const headers={...requestHeaders,...(payload?{'Content-Type':'application/json','Content-Length':String(payload.length)}:{})}
    request=transport.request(target,{method:payload?'POST':'GET',headers},response=>{
      response.on('data',chunk=>{length+=chunk.length;if(length>2*1024*1024){response.destroy(Error('Node 来源响应超过 2 MB'));return}chunks.push(Buffer.from(chunk))})
      response.on('error',error=>finish(error))
      response.on('end',()=>{
        if(response.statusCode<200||response.statusCode>=300){
          let detail='';try{const parsed=JSON.parse(Buffer.concat(chunks).toString('utf8'));detail=[parsed.message,parsed.msg,parsed.error,parsed.error?.message,parsed.data?.message].find(value=>typeof value==='string')||''}catch{}
          const error=Error('Node 来源 HTTP '+response.statusCode+' · '+target.pathname.split('/').pop()+(detail?' · '+detail.slice(0,512):''));error.statusCode=response.statusCode;finish(error);return
        }
        try{finish(null,JSON.parse(Buffer.concat(chunks).toString('utf8')))}catch(error){finish(Error('Node 来源返回无效 JSON：'+error.message))}
      })
    })
    request.on('error',error=>finish(error))
    if(payload)request.write(payload)
    request.end()
  })
}
async function catpawConfig(owner,options){
  try{return await sourceJSON(owner.base+'/config')}catch(error){if(error.statusCode!==401)throw error}
  const status=await sourceJSON(owner.base+'/website/auth/status')
  if(status.code!==0||typeof status.data?.hasPassword!=='boolean')throw Error('猫源要求本机登录；此包未提供兼容的登录接口')
  const secretFile=path.join(owner.data,'catpaw-auth.json')
  let password=typeof options.password==='string'?options.password:''
  if(!password){try{password=JSON.parse(fs.readFileSync(secretFile,'utf8')).password||''}catch{}}
  const setup=!status.data.hasPassword
  if(setup&&!password)password=require('node:crypto').randomBytes(24).toString('base64url')
  if(!password)throw Error('猫源已有本机密码，请在资源的“插件参数”中填写 password 后重新启用')
  if(setup){fs.writeFileSync(secretFile+'.tmp',JSON.stringify({password}),{mode:0o600});fs.renameSync(secretFile+'.tmp',secretFile)}
  const auth=await sourceJSON(owner.base+'/website/auth/'+(setup?'setup':'login'),{password})
  const token=auth?.data?.token
  if(auth.code!==0||typeof token!=='string'||!token.length||token.length>4096||/[\r\n;]/.test(token))throw Error('猫源本机登录失败，请检查插件参数中的 password；未自动重试')
  owner.authHeaders={Cookie:'web_token='+token}
  return sourceJSON(owner.base+'/config',undefined,owner.authHeaders)
}

function createLiteCheerio(htmlText){
  const rawHtml=String(htmlText??'')
  function decodeEntities(s){
    return String(s??'').replace(/&nbsp;/gi,' ').replace(/&amp;/gi,'&').replace(/&lt;/gi,'<').replace(/&gt;/gi,'>').replace(/&quot;/gi,'"').replace(/&#39;/gi,"'").replace(/&#x([0-9a-f]+);/gi,(_,h)=>String.fromCodePoint(parseInt(h,16))).replace(/&#(\d+);/g,(_,d)=>String.fromCodePoint(parseInt(d,10)))
  }
  function parseAttrs(attrStr){
    const attrs={};const re=/([a-zA-Z0-9_:-]+)(?:\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'=<>`]+)))?/g;let m
    while((m=re.exec(attrStr))!==null)attrs[m[1].toLowerCase()]=decodeEntities(m[2]??m[3]??m[4]??'')
    return attrs
  }
  const voidTags=new Set(['area','base','br','col','embed','hr','img','input','link','meta','param','source','track','wbr'])
  function parseTree(html){
    const root={tag:'root',attrs:{},children:[],parent:null,html:''}
    const stack=[root]
    const tokenRe=/<!--([\s\S]*?)-->|<script\b([^>]*)>([\s\S]*?)<\/script>|<style\b([^>]*)>([\s\S]*?)<\/style>|<(\/?)([a-zA-Z0-9_:-]+)([^>]*?)(\/?)>|([^<]+)/gi
    let m
    while((m=tokenRe.exec(html))!==null){
      if(m[1]!==undefined)continue
      const cur=stack[stack.length-1]
      if(m[2]!==undefined||m[4]!==undefined){
        const isScript=m[2]!==undefined
        const node={tag:isScript?'script':'style',attrs:parseAttrs(isScript?m[2]:m[4]),children:[{type:'text',text:isScript?m[3]:m[5]}],parent:cur,innerHtml:isScript?m[3]:m[5]}
        cur.children.push(node)
        continue
      }
      if(m[9]!==undefined){
        cur.children.push({type:'text',text:decodeEntities(m[9]),parent:cur})
        continue
      }
      const closing=m[6]==='/',tag=String(m[7]||'').toLowerCase(),attrStr=m[8]||'',selfClose=m[8]?.trim().endsWith('/')||voidTags.has(tag)
      if(closing){
        for(let i=stack.length-1;i>0;i--){if(stack[i].tag===tag){stack.length=i;break}}
      }else{
        const node={tag,attrs:parseAttrs(attrStr),children:[],parent:cur}
        cur.children.push(node)
        if(!selfClose)stack.push(node)
      }
    }
    return root
  }
  const root=parseTree(rawHtml)
  function allDescendants(node,out=[]){
    if(!node||!Array.isArray(node.children))return out
    for(const c of node.children){if(c.tag){out.push(c);allDescendants(c,out)}}
    return out
  }
  function nodeText(node){
    if(!node)return ''
    if(node.type==='text')return node.text||''
    return (node.children||[]).map(nodeText).join('')
  }
  function nodeHtml(node){
    if(!node)return ''
    if(typeof node.innerHtml==='string')return node.innerHtml
    return (node.children||[]).map(c=>c.type==='text'?c.text:`<${c.tag}>${nodeHtml(c)}</${c.tag}>`).join('')
  }
  function matchesSimple(node,part){
    if(!node||!node.tag)return false
    let s=part.trim()
    if(!s)return true
    let notSel=null
    const notMatch=s.match(/:not\(([^)]+)\)/)
    if(notMatch){notSel=notMatch[1];s=s.replace(notMatch[0],'')}
    if(notSel&&matchesSimple(node,notSel))return false
    const attrMatches=[...s.matchAll(/\[\s*([a-zA-Z0-9_:-]+)(?:\s*([*^$|~!]?=)\s*(?:"([^"]*)"|'([^']*)'|([^\]]*)))?\s*\]/g)]
    for(const am of attrMatches){
      const k=am[1].toLowerCase(),op=am[2],val=am[3]??am[4]??am[5]??''
      const actual=node.attrs?.[k]
      if(!op){if(actual===undefined)return false}
      else if(op==='='){if(actual!==val)return false}
      else if(op==='*='){if(typeof actual!=='string'||!actual.includes(val))return false}
      else if(op==='^='){if(typeof actual!=='string'||!actual.startsWith(val))return false}
      else if(op==='$='){if(typeof actual!=='string'||!actual.endsWith(val))return false}
    }
    s=s.replace(/\[[^\]]*\]/g,'')
    const idMatch=s.match(/#([a-zA-Z0-9_-]+)/)
    if(idMatch&&node.attrs?.id!==idMatch[1])return false
    s=s.replace(/#[a-zA-Z0-9_-]+/g,'')
    const classes=[...s.matchAll(/\.([a-zA-Z0-9_-]+)/g)].map(m=>m[1])
    if(classes.length){
      const nodeClasses=String(node.attrs?.class||'').split(/\s+/).filter(Boolean)
      for(const cls of classes)if(!nodeClasses.includes(cls))return false
    }
    s=s.replace(/\.[a-zA-Z0-9_-]+/g,'').trim().toLowerCase()
    if(s&&s!=='*'&&node.tag!==s)return false
    return true
  }
  function queryUnder(bases,selector){
    const groups=String(selector||'').split(',').map(s=>s.trim()).filter(Boolean)
    const matched=new Set()
    for(const grp of groups){
      const parts=grp.split(/\s+/).filter(Boolean)
      let current=bases
      for(const part of parts){
        const next=[]
        for(const b of current){
          for(const d of allDescendants(b))if(matchesSimple(d,part)&&!next.includes(d))next.push(d)
        }
        current=next
      }
      for(const item of current)matched.add(item)
    }
    return [...matched]
  }
  function wrap(nodes){
    const arr=Array.isArray(nodes)?nodes:(nodes?[nodes]:[])
    const obj={
      length:arr.length,
      each(fn){arr.forEach((n,i)=>fn.call(n,i,n));return obj},
      map(fn){const res=[];arr.forEach((n,i)=>{const v=fn.call(n,i,n);if(v!=null)res.push(v)});return {get:()=>res,toArray:()=>res}},
      filter(fn){return wrap(arr.filter((n,i)=>typeof fn==='function'?fn.call(n,i,n):matchesSimple(n,String(fn))))},
      find(sel){return wrap(queryUnder(arr,sel))},
      first(){return wrap(arr.slice(0,1))},
      last(){return wrap(arr.slice(-1))},
      eq(i){return wrap(arr[i]?[arr[i]]:[])},
      parent(){return wrap(arr[0]?.parent?[arr[0].parent]:[])},
      children(sel){const c=(arr[0]?.children||[]).filter(x=>x.tag);return wrap(sel?c.filter(x=>matchesSimple(x,sel)):c)},
      prev(sel){const p=arr[0]?.parent;if(!p)return wrap([]);const siblings=p.children.filter(x=>x.tag);const idx=siblings.indexOf(arr[0]);for(let i=idx-1;i>=0;i--)if(!sel||matchesSimple(siblings[i],sel))return wrap([siblings[i]]);return wrap([])},
      next(sel){const p=arr[0]?.parent;if(!p)return wrap([]);const siblings=p.children.filter(x=>x.tag);const idx=siblings.indexOf(arr[0]);for(let i=idx+1;i<siblings.length;i++)if(!sel||matchesSimple(siblings[i],sel))return wrap([siblings[i]]);return wrap([])},
      attr(name){return arr[0]?.attrs?.[String(name||'').toLowerCase()]},
      text(){return arr.map(nodeText).join('')},
      html(){return arr[0]?nodeHtml(arr[0]):''},
      toArray(){return arr.slice()},
      get(i){return i===undefined?arr.slice():arr[i]}
    }
    arr.forEach((n,i)=>{obj[i]=n})
    return obj
  }
  const $=selector=>{
    if(!selector)return wrap([])
    if(typeof selector==='object'&&selector.tag)return wrap([selector])
    return wrap(queryUnder([root],String(selector)))
  }
  $.html=()=>rawHtml
  return $
}
function weboxNodeBuild4kvmPlayUrl(input){
  const dataid=String(input?.dataid??'').trim(),episodeId=String(input?.episodeId??'').trim(),quality=String(input?.quality??'').trim(),playKey=String(input?.playKey??'').trim()
  const now=Date.now(),st=Number(input?.serverTime),plt=Number(input?.loadedAt)
  const t=String(Math.floor((Number.isFinite(st)&&st>0&&Number.isFinite(plt)&&plt>0)?(st+(now-plt)):now))
  const msg=`${dataid}:${t}:${episodeId}`
  const s=nodeCrypto.createHmac('sha256',Buffer.from(episodeId,'utf8')).update(Buffer.from(msg,'utf8')).digest('hex').slice(0,32)
  const secret='nbmovie2024secretkey',pkBytes=Buffer.from(playKey,'utf8'),xored=Buffer.alloc(pkBytes.length)
  for(let i=0;i<pkBytes.length;i++)xored[i]=pkBytes[i]^secret.charCodeAt(i%secret.length)
  const k=xored.toString('base64').replace(/\+/g,'-').replace(/\//g,'_')
  return {url:`/video/play?p=${dataid}&v=${episodeId}&q=${quality}&s=${s}&t=${t}&k=${k}`}
}
function createNodeWeBoxPlugin(owner,spec){
  const settings={}
  if(Array.isArray(spec?.settings?.fields)){
    for(const f of spec.settings.fields)if(f&&f.key)settings[f.key]=f.default??''
  }
  const payload=owner.payload||{}
  if(payload.options&&typeof payload.options==='object'&&!Array.isArray(payload.options))Object.assign(settings,payload.options)
  else if(typeof payload.options==='string'&&payload.options.trim().startsWith('{')){try{Object.assign(settings,JSON.parse(payload.options))}catch{}}
  const storeNs='webox:'+String(spec?.id||payload.serviceID||payload.name||payload.entry||'default')
  async function weboxHttp(method,url,options={}){
    let target=new URL(String(url))
    if(options.query&&typeof options.query==='object'){
      for(const [k,v] of Object.entries(options.query))if(v!=null&&v!=='')target.searchParams.set(k,String(v))
    }
    const headers=widgetHeaders(options.headers||{})
    let body=undefined
    if(!['GET','HEAD'].includes(method)){
      if(options.json!==undefined){body=JSON.stringify(options.json);if(!Object.keys(headers).some(k=>k.toLowerCase()==='content-type'))headers['Content-Type']='application/json'}
      else if(options.text!==undefined)body=String(options.text)
      else if(options.body!==undefined)body=options.body
    }
    const totalTimeout=boundedTimeout(options.timeoutMs||options.timeout,15000,30000)
    const canRetry=['GET','HEAD'].includes(method)&&!options._retried&&totalTimeout>=8000
    const timeout=canRetry?Math.min(totalTimeout,6500):totalTimeout
    try{
      const response=await fetch(pluginHTTPURL(target.toString()),{method,headers,body,redirect:'follow',signal:AbortSignal.timeout(timeout)})
      const bytes=await readLimited(response)
      const outHeaders=Object.fromEntries(response.headers)
      const rType=String(options.responseType||'text').toLowerCase()
      const data=rType==='base64'?bytes.toString('base64'):rType==='json'?JSON.parse(bytes.toString('utf8')):bytes.toString('utf8')
      return {status:response.status,url:response.url||target.toString(),headers:outHeaders,data}
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
    }
  }
  const ctx={
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
    html:{load:html=>createLiteCheerio(html)},
    store:{
      async get(key){const raw=global.local?.get(storeNs,String(key||''));if(!raw)return null;try{return JSON.parse(raw)}catch{return raw}},
      async set(key,val){global.local?.set(storeNs,String(key||''),JSON.stringify(val));return val}
    },
    crypto:{
      md5:s=>nodeCrypto.createHash('md5').update(String(s??''),'utf8').digest('hex'),
      base64Encode:s=>Buffer.from(String(s??''),'utf8').toString('base64'),
      base64Decode:s=>Buffer.from(String(s??'').replace(/\s+/g,''),'base64').toString('utf8'),
      aesEncrypt(data,key,iv,options={}){
        const inEnc=String(options.inputEncoding||'utf8').toLowerCase(),outEnc=String(options.outputEncoding||'base64').toLowerCase()
        const keyBuf=Buffer.from(String(key??''),'utf8'),ivBuf=Buffer.from(String(iv??''),'utf8')
        const alg=keyBuf.length===32?'aes-256-cbc':keyBuf.length===24?'aes-192-cbc':'aes-128-cbc'
        const cipher=nodeCrypto.createCipheriv(alg,keyBuf,ivBuf)
        const inputBuf=Buffer.from(String(data??''),inEnc==='hex'?'hex':inEnc==='base64'?'base64':'utf8')
        const outBuf=Buffer.concat([cipher.update(inputBuf),cipher.final()])
        return outBuf.toString(outEnc==='hex'?'hex':outEnc==='base64'?'base64':'utf8')
      },
      aesDecrypt(data,key,iv,options={}){
        const inEnc=String(options.inputEncoding||'base64').toLowerCase(),outEnc=String(options.outputEncoding||'utf8').toLowerCase()
        const keyBuf=Buffer.from(String(key??''),'utf8'),ivBuf=Buffer.from(String(iv??''),'utf8')
        const alg=keyBuf.length===32?'aes-256-cbc':keyBuf.length===24?'aes-192-cbc':'aes-128-cbc'
        const decipher=nodeCrypto.createDecipheriv(alg,keyBuf,ivBuf)
        const inputBuf=Buffer.from(String(data??'').replace(/\s+/g,''),inEnc==='hex'?'hex':'base64')
        const outBuf=Buffer.concat([decipher.update(inputBuf),decipher.final()])
        return outBuf.toString(outEnc==='hex'?'hex':outEnc==='base64'?'base64':'utf8')
      },
      rsaEncrypt(plainText,publicKeyPem){
        return nodeCrypto.publicEncrypt({key:String(publicKeyPem),padding:nodeCrypto.constants.RSA_PKCS1_PADDING},Buffer.from(String(plainText??''),'utf8')).toString('base64')
      },
      rsaDecrypt(base64Cipher,privateKeyPem){
        return nodeCrypto.privateDecrypt({key:String(privateKeyPem),padding:nodeCrypto.constants.RSA_PKCS1_PADDING},Buffer.from(String(base64Cipher??'').replace(/\s+/g,''),'base64')).toString('utf8')
      }
    },
    compute:{
      async run(options={}){
        const {code,input,binaries}=options
        if(input&&input.dataid!==undefined&&input.playKey!==undefined)return weboxNodeBuild4kvmPlayUrl(input)
        if(typeof globalThis.WebAssembly!=='undefined'&&globalThis.WebAssembly&&typeof globalThis.WebAssembly.instantiate==='function'&&code){
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
  const cursors=new Map()
  let cachedFilterFields=null,primaryCategoryKey='category',defaultFilters={}
  async function ensureFilterFields(){
    if(cachedFilterFields)return cachedFilterFields
    cachedFilterFields=typeof spec.filters==='function'?await spec.filters(ctx,{}):[]
    if(!Array.isArray(cachedFilterFields))cachedFilterFields=[]
    defaultFilters={}
    for(const f of cachedFilterFields)if(f&&f.key)defaultFilters[f.key]=f.default!==undefined?String(f.default):String(f.options?.[0]?.value??'')
    const catField=cachedFilterFields.find(f=>f&&f.key==='category')||cachedFilterFields[0]
    primaryCategoryKey=catField?.key||'category'
    return cachedFilterFields
  }
  const cleanStr=v=>v==null?'':typeof v==='string'?v.replace(/\[object\s+[^\]]+\]/gi,'').trim():String(v)
  const mapItems=list=>(Array.isArray(list)?list:[]).filter(x=>x&&typeof x==='object'&&x.id!=null).map(x=>({id:String(x.id),name:cleanStr(x.title||x.name||x.id),poster:cleanStr(x.poster||x.pic||''),remarks:cleanStr(x.subtitle||x.rating||x.remarks||'')})).filter(x=>x.id&&x.name)
  return {
    name:spec.name||payload.name||'WeBox 影视源',
    async home(args={}){
      const fields=await ensureFilterFields()
      const catField=fields.find(f=>f&&f.key===primaryCategoryKey)
      const categories=Array.isArray(catField?.options)?catField.options.map(o=>({id:String(o.value??''),name:cleanStr(o.label||o.name||o.value||'全部')})):[{id:'all',name:'全部'}]
      const filters={}
      for(const cat of categories){
        const catFilters=[]
        for(const f of fields){
          if(!f||!f.key||f.key===primaryCategoryKey||!Array.isArray(f.options))continue
          if(f.showWhen&&f.showWhen.key===primaryCategoryKey&&String(f.showWhen.equals)!==String(cat.id))continue
          catFilters.push({key:String(f.key),name:cleanStr(f.label||f.name||f.key),value:f.options.map(o=>({n:cleanStr(o.label??o.name??o.value??'全部'),v:String(o.value??'')}))})
        }
        if(catFilters.length)filters[cat.id]=catFilters
      }
      const reqFilters={...defaultFilters}
      const res=await spec.list(ctx,{cursor:null,filters:reqFilters,refresh:Boolean(args?.refresh)})
      if(res?.nextCursor)cursors.set(JSON.stringify(reqFilters)+'|2',String(res.nextCursor))
      return {categories,filters,items:mapItems(res?.items)}
    },
    async category(args={}){
      await ensureFilterFields()
      const page=Math.max(1,Number(args?.page)||1),reqFilters={...defaultFilters,...(args?.filters||{})}
      if(args?.categoryId!==undefined&&primaryCategoryKey)reqFilters[primaryCategoryKey]=String(args.categoryId)
      const key=JSON.stringify(reqFilters),cursor=page<=1?null:(cursors.get(key+'|'+page)||String(page))
      const res=await spec.list(ctx,{cursor,filters:reqFilters,refresh:Boolean(args?.refresh)})
      if(res?.nextCursor)cursors.set(key+'|'+(page+1),String(res.nextCursor))
      return {page,items:mapItems(res?.items),hasMore:Boolean(res?.nextCursor)}
    },
    async search(args={}){
      if(typeof spec.search!=='function')return {page:1,items:[],hasMore:false}
      await ensureFilterFields()
      const page=Math.max(1,Number(args?.page)||1),query=String(args?.keyword||args?.wd||args?.query||'').trim()
      if(!query)return {page:1,items:[],hasMore:false}
      const key='search:'+query,cursor=page<=1?null:(cursors.get(key+'|'+page)||String(page))
      const res=await spec.search(ctx,{query,cursor,filters:{...defaultFilters,...(args?.filters||{})}})
      if(res?.nextCursor)cursors.set(key+'|'+(page+1),String(res.nextCursor))
      return {page,items:mapItems(res?.items),hasMore:Boolean(res?.nextCursor)}
    },
    async detail(args={}){
      const contentId=String(args?.id??args?.itemId??''),det=await spec.detail(ctx,{id:contentId})
      const groups=Array.isArray(det?.groups)?det.groups:[]
      const lines=groups.map((grp,idx)=>({
        id:String(grp?.id??`line-${idx+1}`),
        name:cleanStr(grp?.name||`线路 ${idx+1}`),
        episodes:(Array.isArray(grp?.episodes)?grp.episodes:[]).filter(ep=>ep&&ep.id!=null).map((ep,epIdx)=>({
          id:'webox:'+encodeURIComponent(JSON.stringify({contentId:String(det?.id??contentId),groupId:String(grp?.id??'main'),episodeId:String(ep.id)})),
          name:cleanStr(ep.name||ep.title||`第 ${epIdx+1} 集`)
        }))
      })).filter(l=>l.episodes.length)
      return {id:String(det?.id??contentId),name:cleanStr(det?.title||det?.name||contentId),poster:cleanStr(det?.poster||''),description:cleanStr(det?.summary||det?.description||''),remarks:cleanStr(det?.subtitle||det?.rating||''),lines}
    },
    async play(args={}){
      let contentId=String(args?.contentId||args?.id||''),groupId=String(args?.lineId||args?.groupId||'main'),episodeId=String(args?.episodeId||args?.id||'')
      if(typeof args?.id==='string'&&args.id.startsWith('webox:')){
        try{const parsed=JSON.parse(decodeURIComponent(args.id.slice(6)));contentId=String(parsed.contentId||contentId);groupId=String(args?.lineId||parsed.groupId||groupId);episodeId=String(parsed.episodeId||episodeId)}catch{}
      }
      const res=await spec.play(ctx,{contentId,groupId,episodeId,purpose:'playback',refresh:Boolean(args?.refresh)})
      const sources=Array.isArray(res?.sources)?res.sources:[]
      if(!sources.length)throw new Error('WeBox 插件未返回可播放线路')
      const mapped=sources.map((s,idx)=>{
        const headers=s?.headers&&typeof s.headers==='object'?s.headers:{}
        if(typeof s?.manifest==='string'&&s.manifest.trim().startsWith('#EXTM3U')){
          return {name:cleanStr(s.name||`线路 ${idx+1}`),url:String(s.baseUrl||'https://localhost/playlist.m3u8').trim(),manifestText:s.manifest,baseUrl:String(s.baseUrl||'https://localhost/playlist.m3u8').trim(),headers,format:'hls',contentType:'application/vnd.apple.mpegurl',directMedia:true,nativePlayable:true}
        }
        const url=String(s?.url||'').trim(),isHls=/mpegurl/i.test(String(s?.mime||''))||/\.m3u8(?:$|[?#])/i.test(url)
        return {name:cleanStr(s?.name||`线路 ${idx+1}`),url,headers,contentType:String(s?.mime||(isHls?'application/vnd.apple.mpegurl':'video/mp4')),...(isHls?{format:'hls'}:{}),directMedia:true,nativePlayable:true}
      }).filter(s=>s.url||s.manifestText)
      if(!mapped.length)throw new Error('WeBox 插件未返回有效播放地址')
      return {...mapped[0],alternates:mapped.slice(1)}
    }
  }
}

function installCatvodGlobals(owner){
  owner.weboxSpec=null;global.WeBox={define(spec){owner.weboxSpec=spec;return spec}};
  const file=path.join(owner.data,'js-storage.json')
  let storage={};try{storage=JSON.parse(fs.readFileSync(file,'utf8'))}catch{}
  const save=()=>{const text=JSON.stringify(storage);if(text.length>1024*1024)throw Error('插件存储超过 1 MB');fs.writeFileSync(file+'.tmp',text);fs.renameSync(file+'.tmp',file)}
  global.local={get:function(namespace,key){if(isCatVodProtocol(owner.protocol))return (storage.__catvod||{})[namespace]??(arguments.length>1?key:'');return arguments.length===1?(storage.__catvod||{})[namespace]??'':storage[namespace]?.[key]??''},set:function(namespace,key,value){if(arguments.length===2){storage.__catvod??={};storage.__catvod[namespace]=key}else{storage[namespace]??={};storage[namespace][key]=value}save()},delete:function(namespace,key){if(arguments.length===1){if(storage.__catvod)delete storage.__catvod[namespace]}else if(storage[namespace])delete storage[namespace][key];save()}}
  global.req=async(url,options={})=>{
    let body=options.body??options.data,headers={...(options.headers||{})}
    const postType=String(options.postType||'').toLowerCase()
    if(body && typeof body==='object' && !Buffer.isBuffer(body)){
      if(postType==='form'||/application\/x-www-form-urlencoded/i.test(String(headers['Content-Type']||headers['content-type']||''))){
        body=new URLSearchParams(Object.entries(body).map(([k,v])=>[k,v==null?'':String(v)])).toString()
        headers['Content-Type']??='application/x-www-form-urlencoded'
      }else{
        body=JSON.stringify(body)
        headers['Content-Type']??='application/json'
      }
    }
    const method=String(options.method||'GET').toUpperCase()
    const redirect=(options.redirect===0||options.redirect===false)?'manual':'follow'
    const response=await fetch(pluginHTTPURL(url),{method,headers,body:['GET','HEAD'].includes(method)?undefined:body,redirect,signal:AbortSignal.timeout(boundedTimeout(options.timeout,12000))})
    const bytes=await readLimited(response)
    const outHeaders=Object.fromEntries(response.headers)
    if(typeof response.headers.raw==='function'){const setCookie=response.headers.raw()['set-cookie'];if(Array.isArray(setCookie)&&setCookie.length)outHeaders['set-cookie']=setCookie}
    return {code:response.status,headers:outHeaders,content:options.buffer===2?[...bytes]:options.buffer===1?bytes.toString('base64'):bytes.toString('utf8')}
  }
  global.request=async(...args)=>(await global.req(...args)).content
  global.getProxy=()=>owner.payload.proxyURL||''
  global.getProxyUrl=params=>{const base=owner.payload.proxyURL;if(!base)return '';const target=new URL(base);for(const [key,value] of Object.entries(params||{}))if(value!=null)target.searchParams.set(key,String(value));return target.toString()}
  const netHTTP=async(url,options={})=>{const headers={...(options.headers||{})};let body=options.body??options.data;if(body&&typeof body==='object'&&!Buffer.isBuffer(body)){body=JSON.stringify(body);headers['Content-Type']??='application/json'}const response=await fetch(pluginHTTPURL(url),{method:options.method||'GET',headers,body:['GET','HEAD'].includes(String(options.method||'GET').toUpperCase())?undefined:body,signal:AbortSignal.timeout(boundedTimeout(options.timeout,15000))}),bytes=await readLimited(response),contentType=String(response.headers.get('content-type')||''),binaryResponse=/^(?:application\/(?:octet-stream|stream)|(?:image|audio|video)\/)/i.test(contentType),content=options.buffer===1||(options.buffer==null&&binaryResponse)?bytes.toString('base64'):options.buffer===2?[...bytes]:bytes.toString(options.encoding||'utf8'),value={code:response.status,headers:Object.fromEntries(response.headers),content,url:response.url||url};options.complete?.(value);return value}
  global.net={http:netHTTP,req:netHTTP,json:async(url,options={})=>{if(options.buffer)throw Error('JSON 请求不能使用 buffer');const result=await netHTTP(url,options);if(result.code<200||result.code>=300)throw Error('HTTP '+result.code);return JSON.parse(result.content)},sleep:ms=>new Promise(resolve=>setTimeout(resolve,Math.max(0,Number(ms)||0))),getUserAgent:()=>global.navigator?.userAgent||'CCTVHost/1',cached:async(_key,_options,loader)=>loader(),map:async(items,mapper)=>Promise.all(items.map(mapper)),batch:async(items)=>Promise.all(items.map(item=>netHTTP(item.url,item.options)))}
}
function catVodSite(payload){const options=payload.options&&typeof payload.options==='object'?payload.options:{},site=options.site&&typeof options.site==='object'?{...options.site}:{...options};delete site.site;site.key||=String(payload.name||payload.entry||'local_source').replace(/[^A-Za-z0-9_-]/g,'_');site.name||=payload.name||'本机影视源';site.type||=3;if(options.api&&!site.api)site.api=options.api;if(site.ext===undefined)site.ext=options.ext??(typeof payload.options==='string'?payload.options:JSON.stringify(payload.options||{}));return site}
function catVodExt(payload,site){const options=payload.options;if(typeof options==='string')return options;if(options&&typeof options==='object')return options.ext??options.extend??site?.ext??JSON.stringify(options);return site?.ext||''}
const isCatVodProtocol=value=>['catvod-js','tvbox-js','catvod-open-js','catvod-quickjs'].includes(String(value||''))
function mergeCatpawConfiguration(base,overrides,depth=0){
  if(depth>16)throw Error('猫源配置嵌套超过限制')
  const plain=value=>value&&typeof value==='object'&&!Array.isArray(value)&&[Object.prototype,null].includes(Object.getPrototypeOf(value))
  const result={}
  for(const [key,value] of Object.entries(base||{}))if(!['__proto__','prototype','constructor'].includes(key))result[key]=value
  for(const [key,value] of Object.entries(overrides||{})){
    if(['__proto__','prototype','constructor'].includes(key))throw Error('猫源配置包含无效字段')
    result[key]=plain(result[key])&&plain(value)?mergeCatpawConfiguration(result[key],value,depth+1):value
  }
  return result
}
async function catpawConfigurationPage(owner){
  const url=owner.base+'/website'
  const probe=method=>new Promise(resolve=>{
    let done=false,length=0,request
    const finish=value=>{if(done)return;done=true;original.clearTimeout(timer);resolve(value)}
    const timer=original.setTimeout(()=>{request?.destroy();finish(false)},3000)
    request=http.request(url,{method,headers:owner.authHeaders||{}},response=>{
      const html=response.statusCode===200&&String(response.headers['content-type']||'').toLowerCase().includes('text/html')
      if(method==='HEAD'&&[404,405].includes(response.statusCode)){response.resume();finish('get');return}
      response.on('data',chunk=>{length+=chunk.length;if(length>256*1024){response.destroy();finish(false)}})
      response.on('error',()=>finish(false));response.on('end',()=>finish(html));response.resume()
    });request.on('error',()=>finish(false));request.end()
  })
  let valid=await probe('HEAD');if(valid==='get')valid=await probe('GET')
  return valid===true?url:null
}
function catpawProviders(config,base){
  const sites=Array.isArray(config?.video?.sites)?config.video.sites:[]
  return sites.filter(site=>{if(!site||typeof site.api!=='string'||!site.api.startsWith('/spider/')||site.api.includes('..'))return false;try{const url=new URL(site.api,base);return url.origin===base&&!url.search&&!url.hash&&site.key!=null}catch{return false}}).map(site=>({id:String(site.key),name:String(site.name||site.key),api:site.api.replace(/\/$/,''),...(site.searchable!=null?{searchable:![false,0,'0'].includes(site.searchable)}:{})}))
}
function catpawMediaAddresses(value,base,authHeaders={},depth=0,playback=false){
  if(depth>16||!value||typeof value!=='object')return value
  if(Array.isArray(value))return value.map(item=>catpawMediaAddresses(item,base,authHeaders,depth+1,playback))
  const out={...value}
  for(const [key,item] of Object.entries(out)){
    if(['url','vod_pic','poster','image',...(playback?['playUrl','playurl','play_url','videoUrl','video_url','mediaUrl','src','value']:[])].includes(key)&&typeof item==='string'&&/^(?:\/|\.\.?\/)/.test(item))out[key]=new URL(item,base).href
    else if(item&&typeof item==='object')out[key]=catpawMediaAddresses(item,base,authHeaders,depth+1,playback)
    if(['vod_pic','poster'].includes(key)&&typeof out[key]==='string'){try{if(new URL(out[key]).origin===base&&Object.keys(authHeaders).length)out.posterHeaders={...authHeaders}}catch{}}
  }
  for(const key of ['url','playUrl','playurl','play_url','videoUrl','video_url','mediaUrl','src','value']) {
    if(playback&&['url','playUrl','playurl','play_url','videoUrl','video_url','mediaUrl','src','value'].includes(key)&&typeof out[key]==='string'){try{if(new URL(out[key]).origin===base&&Object.keys(authHeaders).length){out.header={...(out.header||{}),...authHeaders};out.headers={...(out.headers||{}),...authHeaders}}}catch{}}
  }
  return out
}
async function start(payload){
  const existing=owners.get(payload.session);if(existing){if(existing.stopPromise)throw Error('Node 插件正在停止');if(!existing.closed)return existing.ready?await existing.ready:existing.metadata;owners.delete(payload.session)}
  const root=readableRoot(payload.packageRoot),entry=entryPath(root,payload.entry)
  const data=readableRoot(payload.dataDirectory)
  let resolveReady,rejectReady
  const ready=new Promise((resolve,reject)=>{resolveReady=resolve;rejectReady=reject})
  ready.catch(()=>{})
  const owner={session:payload.session,serviceID:payload.serviceID||payload.session,root,data,cwd:data,payload,protocol:payload.protocol,timers:new Map(),sockets:new Set(),servers:new Set(),streams:new Set(),watchers:new Set(),listeners:[],closed:false,stopPromise:null,stopHookAttempted:false,providers:[],globals:{},env:{...baseEnvironment},logs:[],ready,resolveReady,rejectReady,metadata:null}
  owners.set(owner.session,owner)
  try{const metadata=await scope.run(owner,async()=>{
    process.env.CATPAW_DATA_DIR=data;process.env.NODE_PATH=data;process.env.DEV_HTTP_PORT='0'
    if(owner.protocol==='catpaw-http'){
      process.env.CATVOD_DISABLE_AUTOSTART='1'
      process.env.NODE_ENV='development' // Bundled pino workers cannot run in iOS.
      global.catServerFactory=handler=>{const server=http.createServer(handler);owner.applicationServer=server;return server}
      global.catDartServerPort=()=>0 // There is no Dart UI companion in CCTVHost.
    }
    installCatvodGlobals(owner)
    if(owner.protocol==='widget-extractor'){
      const source=fs.readFileSync(entry,'utf8')
      if(Buffer.byteLength(source,'utf8')>8*1024*1024)throw Error('Widget 脚本超过 8 MB')
      const sandbox={URL,URLSearchParams,TextEncoder,TextDecoder,console,crypto:require('node:crypto').webcrypto,Widget:{http:{
        get:(url,options={})=>widgetHTTP('GET',url,undefined,options),
        post:(url,body,options={})=>widgetHTTP('POST',url,body,options)
      }}}
      const loadResource=widgetSource(sandbox,source)
      owner.module={loadResource};owner.widgetItems=new Map();owner.widgetSearchToken=0
      owner.metadata={engine:'Node.js Mobile',protocol:'widget-extractor',capabilities:['search','detail','play']}
      return owner.metadata
    }
    if(owner.protocol==='nanotv-service-v2'){
      const source=fs.readFileSync(entry,'utf8')
      if(Buffer.byteLength(source,'utf8')>8*1024*1024)throw Error('NanoTV 服务脚本超过 8 MB')
      const declared=nanoDeclaration(source),host=nanoHost(owner,declared.manifest)
      const sandbox={URL,URLSearchParams,TextEncoder,TextDecoder,Buffer,native:host.native,console:{
        log:(...values)=>host.log(values.join(' ')),info:(...values)=>host.log(values.join(' ')),
        warn:(...values)=>host.log(values.join(' ')),error:(...values)=>host.log(values.join(' '))
      }}
      sandbox.globalThis=sandbox
      vm.createContext(sandbox)
      vm.runInContext(source,sandbox,{timeout:5000,displayErrors:true,filename:payload.entry||'nanotv-service.js'})
      const service=sandbox.nanoService
      if(!service||service.manifest?.apiVersion!==2||typeof service.start!=='function'||typeof service.channels!=='function'||typeof service.resolve!=='function'||typeof service.stop!=='function')throw Error('NanoTV 入口未提供 apiVersion 2 的 start/channels/resolve/stop 接口')
      if(service.manifest.id!==declared.manifest.id)throw Error('NanoTV 代码声明与头部 manifest 不一致')
      owner.nanoService=service;owner.nanoHost=host
      await service.start(host)
      owner.module={
        channels:()=>service.channels(),
        resolve:request=>service.resolve({channelID:String(request.ref||request.id||request.channelID||''),query:request.query&&typeof request.query==='object'?request.query:{},rate:String(request.rate||request.query?.rate||'36p')},host),
        refreshMedia:payload=>{const info=host.media.info(payload.sessionID);if(info&&typeof service.mediaActivity==='function')service.mediaActivity({kind:'activity',...info});return host.media.refreshHLS(payload.sessionID)},
        status:()=>typeof service.status==='function'?service.status():{},
        stop:()=>service.stop(host)
      }
      const channels=await service.channels()
      if(!Array.isArray(channels)||channels.length>512||channels.some(row=>!row||typeof row.id!=='string'||!row.id||typeof row.name!=='string'))throw Error('NanoTV channels() 返回格式无效或超过 512 个频道')
      owner.metadata={engine:'Node.js Mobile',version:process.versions.node,protocol:'nanotv-service-v2',pluginVersion:String(service.manifest.version||declared.manifest.version||''),capabilities:['live','resolve','device-registration','hls',...(channels.some(row=>row.catchup)?['catchup']:[])]}
      return owner.metadata
    }
    let module
    if(payload.moduleType==='esm')module=await import(pathToFileURL(entry).href+'?session='+encodeURIComponent(payload.session))
    else{
      for(const name of Object.keys(require.cache))if(name===entry||name.startsWith(root+path.sep))delete require.cache[name]
      try{module=require(entry)}catch(reqErr){
        if(reqErr?.code==='ERR_REQUIRE_ESM'||/Cannot use import statement|Unexpected token 'export'|Unexpected identifier/i.test(String(reqErr?.message||''))){
          module=await import(pathToFileURL(entry).href+'?session='+encodeURIComponent(payload.session))
        }else throw reqErr
      }
    }
    owner.module=owner.weboxSpec?createNodeWeBoxPlugin(owner,owner.weboxSpec):(module.default||module)
    if(owner.module&&typeof owner.module.__jsEvalReturn==='function'&&!owner.module.home&&!owner.module.homeContent)owner.module=await owner.module.__jsEvalReturn()
    if(owner.module&&owner.module.api==='1.1'&&typeof owner.module.list==='function'&&!owner.weboxSpec)owner.module=createNodeWeBoxPlugin(owner,owner.module)
    if(owner.protocol==='catpaw-http'){
      let options=payload.options&&typeof payload.options==='object'&&!Array.isArray(payload.options)?payload.options:{}
      let hasConfiguration=Object.keys(options).some(key=>key!=='password')
      if(payload.configEntry){
        const config=entryPath(root,payload.configEntry)
        const source=fs.readFileSync(config,'utf8')
        let loaded
        if(/\bmodule\s*\.\s*exports\s*=|\bexports\s*\./.test(source)){
          const Module=require('node:module'),configurationModule=new Module(config)
          configurationModule.filename=config;configurationModule.paths=Module._nodeModulePaths(path.dirname(config));configurationModule._compile(source,config);loaded=configurationModule.exports
        }else loaded=await import(pathToFileURL(config).href+'?session='+encodeURIComponent(payload.session))
        const value=loaded.default||loaded
        if(!value||typeof value!=='object'||Array.isArray(value))throw Error('猫源配套配置必须导出配置对象')
        options=mergeCatpawConfiguration(value,options);hasConfiguration=true
      }
      if(typeof owner.module.start==='function'){const {password,...serviceOptions}=options;await owner.module.start(hasConfiguration?serviceOptions:undefined)}
      else {
        // CatPaw's bundled local application exposes its configured Fastify
        // instance as globalThis.Pans; the host owns binding its loopback port.
        const app=globalThis.Pans
        if(!app || app===owner.previousPans || typeof app.listen!=='function')throw Error('Node 服务未导出 start()，也没有提供 CatPaw 本机服务实例')
        owner.module=app
        if(!owner.servers.size && !app.server?.listening)await app.listen({host:'127.0.0.1',port:0})
      }
      // Fastify start() may return before its callback-based listen completes.
      const listeningDeadline=Date.now()+10000
      const applicationServer=()=>owner.applicationServer||owner.module.server||[...owner.servers].find(server=>server.listening&&server.address()?.port)
      while(!applicationServer()?.listening&&Date.now()<listeningDeadline&&!owner.failure)await new Promise(resolve=>original.setTimeout(resolve,20))
      const listening=applicationServer()
      if(!listening?.listening||!listening.address()?.port)throw Error('Node 服务未开启可用的本机 HTTP 监听')
      owner.base='http://127.0.0.1:'+listening.address().port
      const config=await catpawConfig(owner,options)
      owner.providers=catpawProviders(config,owner.base)
      owner.configurationURL=await catpawConfigurationPage(owner)
      owner.metadata={engine:'Node.js Mobile',version:process.versions.node,protocol:'catpaw-http',capabilities:['providers','home','category','search','detail','play',...(owner.configurationURL?['configuration']:[])]}
    }else{
      if(isCatVodProtocol(owner.protocol)&&typeof owner.module==='function')owner.module=await owner.module(catVodSite(payload))
      else if(typeof owner.module==='function')owner.module=await owner.module(payload.options||{})
      if(!owner.module || typeof owner.module!=='object')throw Error('Node 入口未导出插件对象')
      owner.modernCatVod=isCatVodProtocol(owner.protocol)&&typeof owner.module.home==='function'&&!owner.module.homeContent&&typeof owner.module.category==='function'&&typeof owner.module.detail==='function'&&typeof owner.module.play==='function'
      if(isCatVodProtocol(owner.protocol)){if(!owner.modernCatVod)for(const [key,alias] of Object.entries({home:'homeContent',homeVod:'homeVideoContent',category:'categoryContent',search:'searchContent',detail:'detailContent',play:'playerContent'}))if(!owner.module[key]&&typeof owner.module[alias]==='function')owner.module[key]=owner.module[alias];if(!owner.module.homeVod&&owner.module.homeVideoContent)owner.module.homeVod=owner.module.homeVideoContent}
      if(typeof owner.module.init==='function')await owner.module.init(isCatVodProtocol(owner.protocol)?catVodExt(payload,catVodSite(payload)):(payload.options||{}))
      owner.metadata={engine:'Node.js Mobile',version:process.versions.node,protocol:owner.protocol,capabilities:['home','category','search','detail','play','providers','proxy'].filter(key=>key==='proxy'?(typeof owner.module.localProxy==='function'||typeof owner.module.proxy==='function'):typeof owner.module[key]==='function').concat((owner.module.channels||owner.module.catalog||(owner.protocol==='iptv-extractor'&&owner.module.fetch))&&owner.module.resolve?['live']:[])}
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
    if(operation==='capabilities')value=owner.metadata
    else if(operation==='proxy'){
      const proxy=typeof owner.module?.localProxy==='function'?owner.module.localProxy:owner.module?.proxy
      if(typeof proxy!=='function')throw Error('Node 模块未提供 localProxy(params)')
      value=await proxy.call(owner.module,payload)
    }
    else if(owner.protocol==='catpaw-http'){
      if(operation==='configuration'){if(!owner.configurationURL)throw Error('此猫源未提供可用的本机配置页面');return {url:owner.configurationURL,headers:owner.authHeaders||{},configurationPage:true}}
      if(operation==='providers'){owner.providers=catpawProviders(await sourceJSON(owner.base+'/config',undefined,owner.authHeaders),owner.base);return owner.providers.map(({id,name,searchable})=>({id,name,...(searchable!=null?{searchable}:{})}))}
      const provider=payload.provider?owner.providers.find(item=>item.id===payload.provider):owner.providers[0]
      if(payload.provider&&!provider)throw Error('所选站点已失效，请刷新站点列表后重新选择')
      if(!provider)throw Error('Node 服务未提供影视来源')
      if(operation==='search'&&provider.searchable===false)throw Error('此站点声明不支持搜索，请使用分类浏览')
      const args=operation==='search'?{wd:payload.keyword,key:payload.keyword,quick:false,pg:payload.page||1,page:payload.page||1}:operation==='category'?{id:payload.categoryId,tid:payload.categoryId,pg:payload.page||1,page:payload.page||1,filter:true,filters:payload.filters||{},extend:payload.filters||{}}:operation==='detail'?{id:payload.id,ids:[payload.id]}:operation==='play'?{flag:payload.lineId||'',id:payload.id,flags:[]}:{filter:true}
      value=await sourceJSON(owner.base+provider.api+'/'+operation,args,owner.authHeaders)
      if(operation==='home' && !value.list?.length){try{const recommended=await sourceJSON(owner.base+provider.api+'/homeVod',{},owner.authHeaders);value={...value,list:recommended.list||[]}}catch(error){if(![404,405].includes(error.statusCode)){if(!Array.isArray(value.class)||!value.class.length)throw error;appendLog(owner,JSON.stringify({event:'catpaw_recommendations_failed',provider_id:provider.id,http_status:error.statusCode||null,categories_available:true}));value={...value,recommendationsUnavailable:true}}}}
      value=catpawMediaAddresses(value,owner.base,owner.authHeaders||{},0,operation==='play')
    }else if(owner.protocol==='nanotv-service-v2'){
      if(operation==='catalog')value=await owner.module.channels()
      else if(operation==='resolve')value=await owner.module.resolve(payload)
      else if(operation==='status')value=owner.module.status()
      else if(operation==='refreshMedia')value=await owner.module.refreshMedia(payload)
      else throw Error('NanoTV 服务不支持 '+operation)
    }else if(owner.protocol==='widget-extractor'){
      if(operation==='home')value={class:[],list:[]}
      else if(operation==='search'){
        if(typeof owner.module.loadResource!=='function')throw Error('Widget 脚本已失效')
        const searchToken=++owner.widgetSearchToken
        const result=await owner.module.loadResource({seriesName:String(payload.keyword||payload.seriesName||''),title:String(payload.keyword||payload.title||''),episode:Math.max(1,Math.min(9999,Math.floor(Number(payload.episode)||1))),season:Math.max(1,Math.min(999,Math.floor(Number(payload.season)||1))),year:payload.year||'',mediaType:payload.mediaType||''})
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
      else if(operation==='home'){
        let rawHome=typeof module.home==='function'?await module.home(catvod?true:payload):{}
        if(typeof rawHome==='string'){try{rawHome=JSON.parse(rawHome)}catch{rawHome={}}}
        value=(rawHome&&typeof rawHome==='object'&&!Array.isArray(rawHome))?rawHome:{list:Array.isArray(rawHome)?rawHome:[]}
        if(!value.list?.length && typeof module.homeVod==='function'){
          let hv=await module.homeVod()
          if(typeof hv==='string'){try{hv=JSON.parse(hv)}catch{hv={}}}
          const hvList=Array.isArray(hv)?hv:(hv?.list||[])
          value={...value,list:hvList}
        }
      }
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
    await Promise.resolve()
    if(owner.ready&&!owner.metadata){try{await owner.ready}catch{return true}}
    if(owner.closed)return true
    // Let an owned Fastify/server close hook release its listener cleanly.
    // Timers and client work stop first; any listener left behind is force
    // closed in finally, including plugins with no cooperative close hook.
    cancelHandles(owner,false)
    let closeError=null
    try{
      const close=owner.stopHookAttempted?null:(owner.module?.stop||owner.module?.close||owner.module?.destroy)
      owner.stopHookAttempted=true
      if(typeof close==='function')await deadline(Promise.resolve(scope.run(owner,()=>close.call(owner.module))),2000,'Node 插件关闭回调超时')
    }catch(error){closeError=error;appendLog(owner,'插件关闭回调失败，将强制清理：'+(error?.message||String(error)))}
    finally{cancelHandles(owner)}
    if([...owner.servers].some(server=>server.listening)){
      owner.stopPromise=null
      throw Error('Node 插件仍有监听端口，强制关闭后可重试停止')
    }
    if(closeError)appendLog(owner,'插件已停止；关闭回调未完成，受宿主管理的句柄已清理')
    owner.closed=true
    closedLogs.set(owner.session,owner.logs.slice(-20))
    for(const name of Object.keys(require.cache))if(name.startsWith(owner.root+path.sep))delete require.cache[name]
    owners.delete(owner.session)
    return true
  })()
  return deadline(owner.stopPromise,2500,'Node 插件停止超时，仍保留真实运行状态')
}
process.on('unhandledRejection',error=>{
  const owner=scope.getStore()
  if(owner)failOwner(owner,'插件未处理的 Promise 异常：',error)
  else appendLog(null,'Node 宿主未归属的 Promise 异常：'+String(error?.message||error||'未知错误').slice(0,512))
})
process.on('uncaughtException',error=>failOwner(scope.getStore(),'插件回调异常：',error))
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
