import vm from 'node:vm';
import fs from 'node:fs/promises';
import path from 'node:path';
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
export function makeWidget(key,storage,request=axios.request,controllers=new Set()){
  const agents=new Map();controllers.agents=controllers.agents||new Set();
  function selectAgent(url){const proxy=getProxyForUrl(url);if(!proxy)return undefined;if(!/^https?:\/\//i.test(proxy))throw Error('当前Node环境只支持HTTP/HTTPS代理');if(!agents.has(proxy)){const agent=new HttpsProxyAgent(proxy);agents.set(proxy,agent);controllers.agents.add(agent);}return agents.get(proxy);}
  async function send(url,method,data,options={}){
    const u=new URL(url);if(u.protocol!=='https:'||u.username||u.password)throw Error('模块请求必须使用有效HTTPS地址');
    const agent=selectAgent(url),controller=new AbortController();controllers.add(controller);
    try{const r=await request({url,method,data,headers:options.headers||{},timeout:25000,maxRedirects:options.allow_redirects===false?0:5,maxContentLength:16*1024*1024,maxBodyLength:8*1024*1024,validateStatus:()=>true,proxy:false,httpAgent:agent,httpsAgent:agent,signal:controller.signal,responseType:options.responseType||undefined});return {status:r.status,statusCode:r.status,headers:r.headers?.toJSON?r.headers.toJSON():r.headers||{},data:r.data};}
    finally{controllers.delete(controller);}
  }
  return {html:{load:async s=>load(s)},storage:{get:k=>storage.get(key+'/'+k),set:(k,v)=>storage.set(key+'/'+k,v),remove:k=>storage.remove(key+'/'+k)},http:{get:(u,o)=>send(u,'GET',undefined,o),post:(u,d,o)=>send(u,'POST',d,o),request:o=>send(o.url,o.method||'GET',o.body??o.data,o)}};
}
export function makeContext(source,storage,request,controllers){const c=vm.createContext({Widget:makeWidget(source.key,storage,request,controllers),console:{log(){},warn(){},error(){}},setTimeout,clearTimeout,URL,Buffer,atob:s=>Buffer.from(s,'base64').toString('binary'),btoa:s=>Buffer.from(s,'binary').toString('base64')});new vm.Script(source.code,{filename:source.key+'.js'}).runInContext(c,{timeout:2000});return c;}
