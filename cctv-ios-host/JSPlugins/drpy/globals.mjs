import * as cheerio from 'cheerio/lib/slim'
import {Buffer} from 'buffer'

function parser(html,expression,array=false){
  const $=cheerio.load(String(html||'')),parts=String(expression||'').replace(/^(?:jsp|jq):/,'').split('&&')
  const attr=array?null:parts.pop()
  let selection=$.root()
  for(const part of parts)if(part)selection=selection.find(part)
  if(array)return selection.toArray().map(node=>$.html(node))
  if(attr==='Text')return selection.first().text().trim()
  if(attr==='Html')return selection.first().html()||''
  return selection.first().attr(attr)||''
}
export function prepareGlobals(payload){
  const g=globalThis
  g.navigator={userAgent:'CCTVHost/iOS',appName:'Netscape'}
  g.pdfa=(html,selector)=>parser(html,selector,true)
  g.pdfh=(html,selector)=>parser(html,selector)
  g.pd=(html,selector,base)=>{const value=parser(html,selector);try{return new URL(value,base).href}catch{return value}}
  g.joinUrl=(base,path)=>new URL(path,base).href
  g.local={get:(namespace,key)=>g.__hostStorage('get',JSON.stringify([namespace,key]),null)||'',set:(namespace,key,value)=>g.__hostStorage('set',JSON.stringify([namespace,key]),String(value)),delete:(namespace,key)=>g.__hostStorage('remove',JSON.stringify([namespace,key]),null)}
  g.getProxy=()=>payload.proxyURL||''
  g.req=(url,options={})=>{
    const headers={...(options.headers||{})},request={...options,headers}
    let body=options.body??options.data
    if(body && typeof body==='object'){const json=Object.entries(headers).some(([k,v])=>k.toLowerCase()==='content-type'&&String(v).includes('json'));body=json?JSON.stringify(body):new URLSearchParams(body).toString()}
    if(body!=null)request.body=String(body)
    const reply=g.__hostFetchSync(String(url),JSON.stringify(request))
    if(reply.error)throw new Error(reply.error)
    if(options.buffer===1)reply.content=reply.base64
    if(options.buffer===2)reply.content=Array.from(Buffer.from(reply.base64,'base64'))
    return reply
  }
  g.request=(url,options)=>(g.req(url,options)).content
}
