import * as cheerio from 'cheerio/lib/slim'
import {Buffer} from 'buffer'

function selectPart($, selection, rawPart){
  let part=String(rawPart||'').trim()
  if(!part)return selection
  const eqRegex=/:eq\((-?\d+)\)/g
  let match,lastIndex=0, hasEq=false
  let current=selection
  while((match=eqRegex.exec(part))!==null){
    hasEq=true
    const subSelector=part.slice(lastIndex,match.index).trim()
    if(subSelector)current=current.find(subSelector)
    current=current.eq(Number(match[1]))
    lastIndex=eqRegex.lastIndex
  }
  if(!hasEq)return current.find(part)
  const tail=part.slice(lastIndex).trim()
  return tail?current.find(tail):current
}

function parser(html,expression,array=false){
  const $=cheerio.load(String(html||'')),parts=String(expression||'').replace(/^(?:jsp|jq):/,'').split('&&')
  const attr=array?null:parts.pop()
  let selection=$.root()
  for(const part of parts)if(part)selection=selectPart($,selection,part)
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
    if(options.redirect===0||options.redirect===false)request.redirect=false
    let body=options.body??options.data
    const postType=String(options.postType||'').toLowerCase()
    if(body && typeof body==='object'){
      const json=postType==='json'||(postType!=='form'&&Object.entries(headers).some(([k,v])=>k.toLowerCase()==='content-type'&&String(v).includes('json')))
      if(json){body=JSON.stringify(body);headers['Content-Type']??='application/json'}
      else{body=new URLSearchParams(Object.entries(body).map(([k,v])=>[k,v==null?'':String(v)])).toString();headers['Content-Type']??='application/x-www-form-urlencoded'}
    }
    if(body!=null)request.body=String(body)
    const reply=g.__hostFetchSync(String(url),JSON.stringify(request))
    if(reply.error)throw new Error(reply.error)
    if(options.buffer===1)reply.content=reply.base64
    if(options.buffer===2)reply.content=Array.from(Buffer.from(reply.base64,'base64'))
    return reply
  }
  g.$js={toString:fn=>'js:('+String(fn)+')();'}
  g.request=(url,options={})=>{
    const reply=g.req(url,options)
    return options.withHeaders?JSON.stringify({body:reply.content,statusCode:reply.code,headers:reply.headers||{},url:reply.url||String(url)}):reply.content
  }
}
