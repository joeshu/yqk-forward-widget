import '../compat/platform.mjs'
import { Buffer } from 'buffer'
import * as crypto from '../compat/crypto-node.mjs'
import CryptoJS from 'crypto-js'
import * as cheerio from 'cheerio/lib/slim'
import { rollup } from 'rollup/dist/rollup.browser.js'

const g=globalThis
let plugin=null, config=null, files=new Set(), cache=new Map()
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
const fs={readFileSync:(p,encoding)=>encoding?read(p):Buffer.from(read(p)),existsSync:p=>files.has(normalize(p))}
const builtins={'buffer':{Buffer},'crypto':crypto,'crypto-js':CryptoJS,'cheerio':cheerio,'url':{URL:g.URL,URLSearchParams:g.URLSearchParams},path,fs}
const builtinName=id=>String(id).replace(/^node:/,'')
function resolve(id, from='') {
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
  const keys=Object.keys(value||{}).filter(k=>k!=='default'&&/^[A-Za-z_$][\w$]*$/.test(k))
  return `const value=${expression};export default value;${keys.map(k=>`export const ${k}=value[${JSON.stringify(k)}];`).join('')}`
}
function result(value){if(typeof value==='string'){try{return JSON.parse(value)}catch{}}return value}
function items(value){value=result(value);return Array.isArray(value)?value:(value?.list||value?.items||[])}
function videos(value){return items(value).map(row=>({id:String(row.id??row.vod_id??''),name:String(row.name??row.vod_name??''),poster:String(row.poster??row.vod_pic??''),remarks:String(row.remarks??row.vod_remarks??'')})).filter(row=>row.id&&row.name)}
function media(value){value=result(value);if(typeof value==='string')return {url:value};if(!value||typeof value.url!=='string')throw new Error('插件未返回可播放 URL');if(Number(value.parse)>0)throw new Error('插件返回网页解析任务，尚未提供直接媒体 URL');return {...value,headers:value.headers||value.header||{}}}
async function load(payload){
  config={...payload,api:payload.api||(payload.protocol==='catvod-js'?'catvod':'standard')};files=new Set(g.__hostListPackageFiles());cache.clear()
  g.__cctvBuiltins=builtins;g.__cctvRequire=requireFile
  g.Buffer=Buffer;g.CryptoJS=CryptoJS;g.cheerio=cheerio;g.global=g;g.window=g
  g.process={env:{},platform:'ios',nextTick:(fn,...args)=>Promise.resolve().then(()=>fn(...args))}
  g.req=async(url,options={})=>{const response=await fetch(url,options);return {content:await response.text(),code:response.status,headers:{get:response.headers.get}}}
  g.request=async(...args)=>(await g.req(...args)).content
  g.crypto={getRandomValues:array=>{const bytes=new Uint8Array(array.buffer,array.byteOffset,array.byteLength);bytes.set(crypto.randomBytes(bytes.length));return array},randomUUID:crypto.randomUUID}
  const entry=find(normalize(payload.entry||'index.js'))
  const type=payload.moduleType||'esm'
  let module
  if(payload.protocol==='drpy'){const helpers=await import('../drpy/globals.mjs');helpers.prepareGlobals(payload);const engine=await import('../drpy/adapter.mjs');module=engine.load(read(entry),payload.options);config.api='catvod'}
  else if(type==='commonjs')module=requireFile(entry)
  else if(type==='script')module=new Function(`${read(entry)}\nreturn typeof plugin!=='undefined'?plugin:typeof spider!=='undefined'?spider:typeof rule!=='undefined'?rule:{${['init','home','homeContent','homeVideoContent','category','categoryContent','search','searchContent','detail','detailContent','play','playerContent','channels','catalog','resolve','epg','destroy'].map(key=>`${key}:typeof ${key}==='function'?${key}:undefined`).join(',')}};`)()
  else module=await esm(entry)
  plugin=module?.default||module
  if(typeof plugin==='function')plugin=await plugin()
  if(!plugin||typeof plugin!=='object')throw new Error('JS 入口未导出插件对象')
  if(config.api==='catvod'){for(const [key,alias] of Object.entries({home:'homeContent',homeVod:'homeVideoContent',category:'categoryContent',search:'searchContent',detail:'detailContent',play:'playerContent'}))if(!plugin[key]&&plugin[alias])plugin[key]=plugin[alias]}
  if(plugin.rule || !['home','category','search','detail','play','channels','catalog','resolve'].some(key=>plugin[key]))throw new Error('此文件像是规则配置，需要随 ZIP 提供对应规则引擎/适配器；并非独立可运行插件')
  if(typeof plugin.init==='function')await plugin.init(payload.options||{})
  return {engine:'JavaScriptCore',protocol:payload.protocol||'cctvhost.media/1',capabilities:['home','category','search','detail','play','providers','epg'].filter(key=>typeof plugin[key]==='function').concat((plugin.channels||plugin.catalog)&&plugin.resolve?['live']:[]),name:payload.name||plugin.name||'JS 插件'}
}
const api={
  start:load,
  providers:async()=>typeof plugin.providers==='function'?plugin.providers():[],
  home:async(args)=>{
    const value=typeof plugin.home==='function'?result(await plugin.home(config.api==='catvod'?true:args)):{}
    if(!items(value).length && (plugin.homeVod||plugin.homeVideo))return {...value,list:items(await (plugin.homeVod||plugin.homeVideo).call(plugin))}
    return value
  },
  category:async(args)=>config.api==='catvod'?plugin.category(String(args.categoryId||''),String(args.page||1),true,args.filters||{}):plugin.category(args),
  catalog:async()=>{const fn=plugin.channels||plugin.catalog;const data=typeof fn==='function'?await fn.call(plugin):fn||[];return items(data).map(row=>({...row,id:String(row.id),ref:String(row.ref||row.id),name:String(row.name||row.id),logo:String(row.logo||'')}))},
  resolve:async({ref,...context})=>plugin.resolve({id:ref,ref,...context}),
  search:async({keyword='',page=1})=>config.api==='catvod'?plugin.search(keyword,false,String(page)):plugin.search({keyword,page}),
  detail:async({id})=>config.api==='catvod'?plugin.detail([id]):plugin.detail({id}),
  play:async({id,lineId=''})=>config.api==='catvod'?plugin.play(lineId,id,[]):plugin.play({id,lineId}),
  epg:async(payload)=>typeof plugin.epg==='function'?plugin.epg(payload):[],
  proxy:async(payload)=>plugin.proxy(payload),
  stop:async()=>{const close=plugin?.close||plugin?.destroy;if(typeof close==='function')await close.call(plugin);plugin=null;cache.clear();return true},
}
g.CCTVHostJS=api
g.__cctvInvoke=(operation,payload,complete)=>Promise.resolve().then(()=>{if(!Object.hasOwn(api,operation))throw new Error('不支持的插件操作');return api[operation](payload||{})}).then(value=>complete(JSON.stringify({ok:true,result:value})),error=>complete(JSON.stringify({ok:false,error:String(error?.message||error)})))
