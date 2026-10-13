import axios from 'axios';
import {checkRequestBoundary,attachOperationAbort,operationContext} from '../operation.js';
import {AsyncLocalStorage} from 'node:async_hooks';
import {HttpsProxyAgent} from 'https-proxy-agent';
import {getProxyForUrl} from 'proxy-from-env';
const context=new AsyncLocalStorage();
export const withReferenceContext=(env,fn)=>context.run(env,fn);
async function send(url,method,data,options={},redirects=0){
 const u=new URL(url);if(!['https:','http:'].includes(u.protocol)||u.username||u.password)throw Error('参考源请求地址无效');
 if(/\/cookie\//i.test(u.pathname))throw Error('此源需要你自己的登录会话，未导入参考订阅的共享Cookie');
 checkRequestBoundary(url,method,data);
 const env=context.getStore();if(!env)throw Error('参考源请求缺少运行上下文');
 const proxy=getProxyForUrl(url),agent=proxy?new HttpsProxyAgent(proxy):undefined,controller=new AbortController(),detach=attachOperationAbort(controller);env.controllers.add(controller);if(agent)env.controllers.agents.add(agent);
 try{const r=await (env.request||axios.request)({url,method,data,headers:options.headers||{},timeout:Math.min(Number(options.timeout)||15000,25000),responseType:options.responseType,maxRedirects:operationContext()?.readOnly?0:5,maxContentLength:16*1024*1024,maxBodyLength:8*1024*1024,validateStatus:options.validateStatus||((s)=>s>=200&&s<400),proxy:false,httpAgent:agent,httpsAgent:agent,signal:controller.signal,transformResponse:options.transformResponse});if(operationContext()?.readOnly&&[301,302,303,307,308].includes(r.status)&&r.headers?.location){if(redirects>=5)throw Error('只读检查重定向次数过多');const next=new URL(r.headers.location,u),headers={...(options.headers||{})};if(next.origin!==u.origin)for(const key of Object.keys(headers))if(/^(authorization|cookie|proxy-authorization)$/i.test(key))delete headers[key];const toGet=r.status===303||(method==='POST'&&[301,302].includes(r.status));if(toGet)for(const key of Object.keys(headers))if(/^content-/i.test(key))delete headers[key];return await send(next.href,toGet?'GET':method,toGet?undefined:data,{...options,headers},redirects+1);}return r;}finally{detach();env.controllers.delete(controller);if(agent){agent.destroy();env.controllers.agents.delete(agent);}}
}
export const t0={get:(u,o)=>send(u,'GET',undefined,o),post:(u,d,o)=>send(u,'POST',d,o),request:o=>send(o.url,o.method||'GET',o.data,o)};
export const U=()=>{};
export const P0=(classes=[],filters={},list)=>({class:classes,filters,...(list?{list}:{})});
export const Me=(r={})=>({page:1,pagecount:1,list:[],...r});
export const l0=(list=[])=>({list});
export const E0=(r={})=>({parse:0,url:'',...r});
export const Ei=(name,id)=>String(name??'').replace(/[$#]/g,' ')+'$'+String(id??'');
export const zn=(name,items)=>({name:String(name??'').replace(/[$#]/g,' '),urls:items.filter(Boolean).map(x=>typeof x==='string'?x:Ei(x.name,x.id)).join('#')});
export const xa=groups=>({vod_play_from:groups.filter(x=>x?.name&&x.urls).map(x=>x.name).join('$$$'),vod_play_url:groups.filter(x=>x?.name&&x.urls).map(x=>x.urls).join('$$$')});
const fields={id:'vod_id',name:'vod_name',pic:'vod_pic',remarks:'vod_remarks',year:'vod_year',area:'vod_area',actor:'vod_actor',director:'vod_director',content:'vod_content',tag:'vod_tag',typeName:'type_name'};
export function b0(r={}){const out={};for(const [key,v] of Object.entries(r))if(v!=null&&key!=='sources')out[fields[key]||key]=v;if(r.sources)Object.assign(out,xa(r.sources));return out;}
export const u0=b0;
t0.create=(defaults={})=>({get:(u,o)=>send(u,'GET',undefined,{...defaults,...o}),post:(u,d,o)=>send(u,'POST',d,{...defaults,...o}),request:o=>send(o.url,o.method||'GET',o.data,{...defaults,...o})});
