import crypto from 'node:crypto';
import {bad,card,client,detail,encode,decode,ids,keyword,page,text} from './common.js';

const API='https://aleig4ah.yiys05.com/vod-app';
const PUBLIC_KEY=`-----BEGIN PUBLIC KEY-----
MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAw4qpeOgv+MeXi57MVPqZ
F7SRmHR3FUelCTfrvI6vZ8kgTPpe1gMyP/8ZTvedTYjTDMqZBmn8o8Ym98yTx3zH
askPpmDR80e+rcRciPoYZcWNpwpFkrHp1l6Pjs9xHLXzf3U+N3a8QneY+jSMvgMb
r00DC4XfvamfrkPMXQ+x9t3gNcP5YtuRhGFREBKP2q20gP783MCOBFwyxhZTIAsF
iXrLkgZ97uaUAtqW6wtKR4HWpeaN+RLLxhBdnVjuMc9jaBl6sHMdSvTJgAajBTAd
6LLA9cDmbGTxH7RGp//iZU86kFhxGl5yssZvBcx/K95ADeTmLKCsabexZVZ0Fu3d
DQIDAQAB
-----END PUBLIC KEY-----`;
const arr=v=>Array.isArray(v)?v:[],clean=v=>text(v),form=v=>new URLSearchParams(Object.entries(v).map(([k,x])=>[k,String(x??'')])).toString(),signData=v=>Object.entries(v).map(([k,x])=>`${k}=${x??''}`).join('&');

export function createYiyingshi(source,storage,request,controllers){
 let appId='',token='';const http=client(source,storage,request,controllers).http;
 async function call(path,data){const headers={...baseHeaders(),'X-Auth-Flow':'1'};const r=await http.request({method:'POST',url:`${API}${path}`,data:form(data),headers:{...headers,'Content-Type':'application/x-www-form-urlencoded'}});if(r.status<200||r.status>=300)throw Error(`伊影请求失败：HTTP ${r.status}`);let d=r.data;if(typeof d==='string')try{d=JSON.parse(d);}catch{throw Error('伊影返回格式异常');}return d||{};}
 function baseHeaders(){return {'User-Agent':'Android/OkHttp','APP-ID':appId,'Authorization':'','X-HASH-Data':''};}
 function signature(params,secret=''){return crypto.createHash('sha256').update(params+secret,'utf8').digest('hex');}
 function authorized(data){const h=baseHeaders();h['X-HASH-Data']=signature(signData(data)+token);return h;}
 async function send(path,data,method='POST'){const headers=authorized(data);let r;if(method==='GET')r=await request({method,url:`${API}${path}`,headers});else r=await request({method,url:`${API}${path}`,data:form(data),headers:{...headers,'Content-Type':'application/x-www-form-urlencoded'}});if(r.status<200||r.status>=300)throw Error(`伊影请求失败：HTTP ${r.status}`);let d=r.data;if(typeof d==='string')try{d=JSON.parse(d);}catch{throw Error('伊影返回格式异常');}return d||{};}
 async function init(){if(token)return;appId=crypto.randomBytes(8).toString('hex');const timestamp=String(Math.floor(Date.now()/1000)),d=await call('/index/getGenerateKey',{appID:appId,timestamp});try{const bytes=Buffer.from(String(d?.data||''),'base64');token='&token='+crypto.publicDecrypt({key:PUBLIC_KEY,padding:crypto.constants.RSA_PKCS1_PADDING},bytes).toString('utf8');}catch{throw Error('伊影游客令牌初始化失败');}if(token.length<10)throw Error('伊影游客令牌为空');}
 function headersFor(data){return authorized(data);}
 async function signed(path,data,method='POST'){await init();const headers=headersFor(data);let r;if(method==='GET')r=await http.request({method,url:`${API}${path}`,headers});else r=await http.request({method,url:`${API}${path}`,data:form(data),headers:{...headers,'Content-Type':'application/x-www-form-urlencoded'}});if(r.status<200||r.status>=300)throw Error(`伊影请求失败：HTTP ${r.status}`);let d=r.data;if(typeof d==='string')try{d=JSON.parse(d);}catch{throw Error('伊影返回格式异常');}return d||{};}
 const timestamp=()=>String(Math.floor(Date.now()/1000));
 function categories(raw){const list=[],filters={};for(const c of arr(raw?.data)){const id=String(c?.typeId||''),name=clean(c?.typeName);if(!id||!name)continue;list.push({type_id:id,type_name:name});const ext=c?.type_extend_obj||{},f=[];for(const k of ['class','area','lang','year']){const values=String(ext[k]||'').split(',').map(clean).filter(x=>x&&x!=='全部');if(values.length)f.push({key:k,name:({class:'类型',area:'地区',lang:'语言',year:'年份'})[k],value:[{n:'全部',v:''},...values.map(v=>({n:v,v}))]});}if(f.length)filters[id]=f;}return {class:list,filters};}
 function cards(raw){return arr(raw?.data?.data).map(x=>card(source,{id:String(x?.id||''),name:x?.name,pic:x?.vodPic,remarks:x?.vodRemarks})).filter(Boolean);}
 async function listing(body={},search=false){const n=page(body.page),f=body.filters||body.extend||{},q=search?keyword(body):'',ts=timestamp(),data=search?{key:q,limit:'20',page:String(n),timestamp:ts}:{area:String(f.area||''),by:'time',class:String(f.class||''),lang:String(f.lang||''),limit:'90',page:String(n),tid:String(f.cateId||body.id||''),timestamp:ts,year:String(f.year||'')};const d=await signed(search?'/vod/segSearch':'/vod/list',data);return {page:n,pagecount:search?n:(cards(d).length?9999:n),list:cards(d)};}
 return {
  async init(){await init();return {};},
  async home(){await init();const ts=timestamp(),d=await signed(`/type/list?timestamp=${ts}`,{timestamp:ts},'GET');return categories(d);},
  async homeVod(){await init();const h=await this.home(),id=h.class[0]?.type_id;if(!id)return {list:[]};const r=await listing({id,page:1});return {list:r.list};},
  async category(body={}){const h=await this.home();if(!h.class.some(c=>c.type_id===String(body.id)))throw bad('分类不属于此源');return listing(body);},
  async search(body={}){const q=keyword(body);if(!q)return {page:1,pagecount:1,list:[]};return listing(body,true);},
  async detail(body={}){await init();const out=[];for(const id of ids(body)){const vod=decode(source.key,'vod',id),req={tid:'',timestamp:timestamp(),vodId:vod},d=await signed('/vod/info',req),data=d?.data||{},lines=[];for(const sourceLine of arr(data.vodSources)){const code=String(sourceLine?.sourceCode||''),eps=arr(sourceLine?.vodPlayList?.urls).map(ep=>({name:clean(ep?.name),id:JSON.stringify({source:code,url:String(ep?.url||'')})})).filter(x=>x.name&&JSON.parse(x.id).url);if(eps.length)lines.push({name:clean(sourceLine?.sourceName||code),episodes:eps});}out.push(detail(source,id,{name:data.vodName,pic:data.vodPic,year:data.vodYear,remarks:data.vodRemarks,content:clean(data.vodContent),actor:data.vodActor,director:data.vodDirector},lines));}return {list:out};},
  async play(body={}){let x;try{x=JSON.parse(decode(source.key,'episode',body.id));}catch{throw bad('伊影播放编号无效');}if(!x?.source||!x?.url)throw bad('伊影播放编号无效');let url=x.url;if(!/^https?:\/\//i.test(url)){const d=await signed('/vod/playUrl',{sourceCode:x.source,timestamp:timestamp(),urlEncode:url});url=String(d?.data?.url||'');}if(!url)throw Error('伊影未返回播放地址');const u=new URL(url);if(u.protocol!=='https:'||u.username||u.password)throw Error('伊影播放地址无效');return {parse:0,url:u.href,header:{'User-Agent':'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 Chrome/116.0.0.0 Mobile Safari/537.36'}};}
 };
}
