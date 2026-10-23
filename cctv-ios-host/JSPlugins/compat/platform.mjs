import 'core-js/actual/array/at.js'
import 'core-js/actual/object/has-own.js'
import 'core-js/actual/url/index.js'
import 'core-js/actual/url-search-params/index.js'
import { Buffer } from 'buffer'

const g = globalThis
g.TextEncoder = class { encode(value='') { return new Uint8Array(Buffer.from(String(value),'utf8')) } }
g.TextDecoder = class { constructor(encoding='utf-8'){if(!['utf-8','utf8','ascii','latin1'].includes(encoding.toLowerCase()))throw Error('TextDecoder 不支持编码：'+encoding);this.encoding=encoding.toLowerCase()==='utf-8'?'utf8':encoding.toLowerCase()} decode(bytes=new Uint8Array()){return Buffer.from(bytes instanceof ArrayBuffer?new Uint8Array(bytes):bytes).toString(this.encoding)} }
g.Headers = class {
  constructor(init={}){this.values=new Map();if(init && typeof init.entries==='function')for(const [key,value] of init.entries())this.append(key,value);else if(Array.isArray(init))for(const [key,value] of init)this.append(key,value);else for(const [key,value] of Object.entries(init))this.set(key,value)}
  set(key,value){this.values.set(String(key).toLowerCase(),String(value))} get(key){return this.values.get(String(key).toLowerCase())??null} has(key){return this.values.has(String(key).toLowerCase())} delete(key){this.values.delete(String(key).toLowerCase())}
  append(key,value){this.set(key,this.has(key)?this.get(key)+', '+value:value)} entries(){return this.values.entries()} keys(){return this.values.keys()} forEach(fn){this.values.forEach((value,key)=>fn(value,key,this))} [Symbol.iterator](){return this.entries()}
}
if (!g.console) g.console = {}
for (const name of ['log', 'warn', 'error', 'info', 'debug']) g.console[name] = (...items) => g.__hostLog(items.map(String).join(' '))
g.setTimeout = (callback, delay = 0, ...args) => g.__hostSetTimeout(() => callback(...args), Number(delay))
g.clearTimeout = handle => g.__hostClearTimeout(handle)
g.setInterval = (callback, delay = 0, ...args) => {
  const handle = { active: true, next: null }
  const tick = () => { if (!handle.active) return; callback(...args); if (handle.active) handle.next = g.setTimeout(tick, delay) }
  handle.next = g.setTimeout(tick, delay)
  return handle
}
g.clearInterval = handle => { if (!handle) return; handle.active = false; g.clearTimeout(handle.next) }
class Signal {
  constructor() { this.aborted = false; this.listeners = new Set(); this.reason = undefined }
  addEventListener(type, callback) { if (type === 'abort') this.listeners.add(callback) }
  removeEventListener(type, callback) { if (type === 'abort') this.listeners.delete(callback) }
  throwIfAborted() { if (this.aborted) throw this.reason }
}
g.AbortController = class {
  constructor() { this.signal = new Signal() }
  abort(reason) {
    if (this.signal.aborted) return
    this.signal.aborted = true
    this.signal.reason = reason || Object.assign(new Error('请求已取消'), { name: 'AbortError' })
    for (const callback of this.signal.listeners) callback()
    this.signal.listeners.clear()
  }
}
g.AbortSignal = Signal
g.AbortSignal.timeout = milliseconds => {const controller=new g.AbortController();g.setTimeout(()=>controller.abort(Object.assign(new Error('请求超时'),{name:'TimeoutError'})),Math.min(Math.max(Number(milliseconds)||0,0),120000));return controller.signal}
g.fetch = (input, options = {}) => new Promise((resolve, reject) => {
  const signal = options.signal
  if (signal?.aborted) return reject(signal.reason)
  let key, settled = false
  const abort = () => { if (key != null) g.__hostAbortFetch(key) }
  signal?.addEventListener('abort', abort)
  let headers=options.headers||{}
  if(typeof headers.entries==='function')headers=Object.fromEntries(headers.entries())
  const body=options.body
  const request={method:String(options.method||'GET').toUpperCase(),headers}
  if(body!=null){if(typeof body==='string')request.body=body;else if(body instanceof ArrayBuffer||ArrayBuffer.isView(body))request.bodyBase64=Buffer.from(body instanceof ArrayBuffer?new Uint8Array(body):new Uint8Array(body.buffer,body.byteOffset,body.byteLength)).toString('base64');else request.body=String(body)}
  key = g.__hostFetch(String(input), JSON.stringify(request), result => {
    if (settled) return
    settled = true
    signal?.removeEventListener('abort', abort)
    if (result.error) return reject(Object.assign(new Error(result.error), { name: result.error === 'AbortError' ? 'AbortError' : 'Error' }))
    const bytes = Buffer.from(result.base64 || '', 'base64')
    const headers = new g.Headers(result.headers || {})
    resolve({
      status: result.status, ok: result.status >= 200 && result.status < 300, url: result.url,
      headers,
      text: async () => bytes.toString('utf8'), json: async () => JSON.parse(bytes.toString('utf8')),
      arrayBuffer: async () => bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength),
      body: { cancel: async () => {} },
    })
  })
  if (signal?.aborted && !settled) abort()
})
