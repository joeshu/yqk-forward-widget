import 'core-js/actual/array/at.js'
import 'core-js/actual/object/has-own.js'
import 'core-js/actual/url/index.js'
import 'core-js/actual/url-search-params/index.js'
import { Buffer } from 'buffer'

const g = globalThis
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
    const headers = new Map(Object.entries(result.headers || {}).map(([key, value]) => [key.toLowerCase(), String(value)]))
    resolve({
      status: result.status, ok: result.status >= 200 && result.status < 300, url: result.url,
      headers: { get: key => headers.get(String(key).toLowerCase()) || null },
      text: async () => bytes.toString('utf8'), json: async () => JSON.parse(bytes.toString('utf8')),
      arrayBuffer: async () => bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength),
      body: { cancel: async () => {} },
    })
  })
  if (signal?.aborted && !settled) abort()
})
