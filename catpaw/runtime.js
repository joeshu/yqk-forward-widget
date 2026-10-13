import vm from 'node:vm';
import fs from 'node:fs/promises';
import path from 'node:path';
import https from 'node:https';
import axios from 'axios';
import {HttpsProxyAgent} from 'https-proxy-agent';
import {getProxyForUrl} from 'proxy-from-env';
import {load} from 'cheerio';

export class PersistentStorage {
  constructor(file){this.file=file;this.data=Object.create(null);this.queue=Promise.resolve();}
  async init(){try{this.data=JSON.parse(await fs.readFile(this.file,'utf8'));if(!this.data||typeof this.data!=='object'||Array.isArray(this.data))throw Error('storage format');}catch(e){if(e.code!=='ENOENT')throw Error('猫爪本机存储读取失败；未重置游客身份');}return this;}
  get(key){const v=this.data[key];return v===undefined?undefined:JSON.parse(JSON.stringify(v));}
  async set(key,value){this.data[key]=JSON.parse(JSON.stringify(value));await this.save();}
  async remove(key){delete this.data[key];await this.save();}
  save(){this.queue=this.queue.then(async()=>{await fs.mkdir(path.dirname(this.file),{recursive:true});const text=JSON.stringify(this.data),tmp=this.file+'.tmp';await fs.writeFile(tmp,text,{mode:0o600});await fs.rename(tmp,this.file);});return this.queue;}
  flush(){return this.queue;}
}
export function errorMessage(error){return String(error?.message||error).replace(/https?:\/\/\S+/g,'[资源地址]').replace(/(?:cookie|authorization|token)\s*[:=]\s*\S+/gi,'[会话字段]').slice(0,500);}
export const TLS_EXCEPTION_HOSTS=Object.freeze(['yz250907.hzkeka49.com','ai.baipiaozhe.com','www.4kvms.org']);
export function isTlsExceptionHost(hostname){return TLS_EXCEPTION_HOSTS.includes(String(hostname).toLowerCase().replace(/\.$/,''));}
export function makeWidget(key,storage,request=axios.request,controllers=new Set()){
  const agents=new Map();controllers.agents=controllers.agents||new Set();
  function selectAgent(url){const u=new URL(url),proxy=getProxyForUrl(url),strict=process.env.CATPAW_STRICT_TLS==='1'||!isTlsExceptionHost(u.hostname),cacheKey=(proxy||'direct')+'|'+strict;if(proxy&&!/^https?:\/\//i.test(proxy))throw Error('当前Node环境只支持HTTP/HTTPS代理');if(!agents.has(cacheKey)){const agent=proxy?new HttpsProxyAgent(proxy,{rejectUnauthorized:strict}):new https.Agent({rejectUnauthorized:strict});agent.options.rejectUnauthorized=strict;if(proxy&&new URL(proxy).protocol==='https:')agent.connectOpts.rejectUnauthorized=true;agents.set(cacheKey,agent);controllers.agents.add(agent);}return agents.get(cacheKey);}
  async function send(url,method,data,options={}){
    let current=new URL(url),currentMethod=method,currentData=data,headers={...(options.headers||{})},redirects=0;
    while(true){if(current.protocol!=='https:'||current.username||current.password)throw Error('模块请求必须使用有效HTTPS地址');
      const controller=new AbortController();controllers.add(controller);let r;
      try{r=await request({url:current.href,method:currentMethod,data:currentData,headers,timeout:25000,maxRedirects:0,maxContentLength:16*1024*1024,maxBodyLength:8*1024*1024,validateStatus:()=>true,proxy:false,httpAgent:selectAgent(current.href),httpsAgent:selectAgent(current.href),signal:controller.signal,responseType:options.responseType||undefined});}
      finally{controllers.delete(controller);}
      const responseHeaders=r.headers?.toJSON?r.headers.toJSON():r.headers||{},location=responseHeaders.location||responseHeaders.Location;
      if(options.allow_redirects===false||![301,302,303,307,308].includes(r.status)||!location)return {status:r.status,statusCode:r.status,headers:responseHeaders,data:r.data};
      if(redirects++>=5)throw Error('模块请求重定向次数过多');const next=new URL(location,current);if(next.protocol!=='https:'||next.username||next.password)throw Error('模块请求拒绝非HTTPS重定向');
      if(next.origin!==current.origin)for(const name of Object.keys(headers))if(/^(authorization|cookie|proxy-authorization)$/i.test(name))delete headers[name];
      if((r.status===303&&currentMethod!=='HEAD')||((r.status===301||r.status===302)&&currentMethod==='POST')){currentMethod='GET';currentData=undefined;for(const name of Object.keys(headers))if(/^(content-|transfer-encoding$)/i.test(name))delete headers[name];}
      current=next;
    }
  }
  return {html:{load:async s=>load(s)},storage:{get:k=>storage.get(key+'/'+k),set:(k,v)=>storage.set(key+'/'+k,v),remove:k=>storage.remove(key+'/'+k)},http:{get:(u,o)=>send(u,'GET',undefined,o),post:(u,d,o)=>send(u,'POST',d,o),request:o=>send(o.url,o.method||'GET',o.body??o.data,o)}};
}
export function makeContext(source,storage,request,controllers){const c=vm.createContext({Widget:makeWidget(source.key,storage,request,controllers),console:{log(){},warn(){},error(){}},setTimeout,clearTimeout,URL,Buffer,atob:s=>Buffer.from(s,'base64').toString('binary'),btoa:s=>Buffer.from(s,'binary').toString('base64')});new vm.Script(source.code,{filename:source.key+'.js'}).runInContext(c,{timeout:2000});return c;}
