import crypto from 'node:crypto';
import {makeWidget} from '../runtime.js';
import {bad,page,card,detail,decode,ids,keyword,media,checkedFilters,cachedListing} from './common.js';

const API='https://app.whjzjx.cn',LOGIN='https://u.shytkjgs.com/user/v3/account/login',LOGIN_KEY='B@ecf920Od8A4df7',PACKAGE='com.jz.xydj',PAGE_SIZE=24;
const UA='okhttp/4.10.0';
function md5(v){return crypto.createHash('md5').update(String(v),'utf8').digest('hex');}
function crypt(v){const c=crypto.createCipheriv('aes-128-ecb',Buffer.from(LOGIN_KEY,'utf8'),null);return Buffer.concat([c.update(String(v),'utf8'),c.final()]).toString('base64');}
function requestHeaders(token=''){return {'User-Agent':UA,platform:'1',version_name:'3.9.2',...(token?{Authorization:token}:{})};}
function listOf(v){return Array.isArray(v)?v:[];}

export function createXingya(source,storage,request,controllers){
 const w=makeWidget(source.key,storage,request,controllers);let tokenPromise;
 async function jsonResponse(r){if(r.status<200||r.status>=300)throw Error('星芽原站请求失败：HTTP '+r.status);const d=typeof r.data==='string'?JSON.parse(r.data):r.data;if(!d||typeof d!=='object')throw Error('星芽原站响应格式异常');return d;}
 async function post(url,data,token=''){return jsonResponse(await w.http.post(url,typeof data==='string'?data:JSON.stringify(data),{headers:{...requestHeaders(token),'Content-Type':'application/json; charset=utf-8'}}));}
 async function get(url,token=''){return jsonResponse(await w.http.get(url,{headers:requestHeaders(token)}));}
 async function login(){if(!tokenPromise)tokenPromise=(async()=>{const now=Date.now(),body={device:md5(String(now)),package_name:PACKAGE,install_first_open:true,first_install_time:now,last_update_time:now,timestamp:now};const r=await post(LOGIN,crypt(JSON.stringify(body)));const t=String(r?.data?.token||'');if(!t)throw Error('星芽游客初始化失败');return t;})().catch(e=>{tokenPromise=null;throw e;});return tokenPromise;}
 async function auth(){return tokenPromise||login();}
 function normalize(raw){return listOf(raw).filter(x=>x&&x.id!=null&&x.class_name).map(x=>({type_id:String(x.id),type_name:String(x.class_name)})).filter(x=>!/bookstore/i.test(x.type_name));}
 function filters(raw){const out={};for(const x of listOf(raw)){const id=String(x.id||''),name=String(x.class_name||'');if(!id||!name)continue;out[id]=[{key:'class',name,value:listOf(x.alg_class).map(c=>({n:String(c.class_name||''),v:String(c.id||'')})).filter(c=>c.n&&c.v)}];if(Array.isArray(x.first_level_ranking))out[id]=[{key:'rank',name,value:x.first_level_ranking.map(c=>({n:String(c.name||''),v:String(c.id||'')})).filter(c=>c.n&&c.v)}];}return out;}
 function cards(rows){return listOf(rows).map(x=>card(source,{id:x.id,name:x.title,pic:x.cover_url,remarks:x.total?`${x.total}集`:x.score_str||''})).filter(Boolean);}
 async function classes(){const t=await auth(),r=await get(`${API}/cloud/v2/theater/classes`,t),raw=listOf(r?.data?.list),items=normalize(raw);if(!items.length)throw Error('星芽分类为空');return {class:items,filters:filters(raw)};}
 const listing=cachedListing(async(n,o)=>{const t=await auth();let rows;if(o.id==='9'){if(n>1)return [];const r=await get(`${API}/cloud/v1/first_level_ranking/detail?id=${encodeURIComponent(o.filter.rank||'1')}`,t);rows=listOf(r?.data?.list);}else{const url=`${API}/cloud/v2/theater/home_page?theater_class_id=${encodeURIComponent(o.id)}&class2_ids=${encodeURIComponent(o.filter.class||'0')}&type=1&page_num=${n}&page_size=${PAGE_SIZE}`;const r=await get(url,t);rows=listOf(r?.data?.list).map(x=>x?.theater).filter(Boolean);}return cards(rows);});
 return {
  async init(){await classes();return {};},
  async home(){return classes();},
  async homeVod(){const h=await classes();return {list:(await listing(1,{id:h.class[0].type_id,filter:{}})).list};},
  async category(body={}){const n=page(body.page),h=await classes(),id=String(body.id||'');if(!h.class.some(x=>x.type_id===id))throw bad('分类不属于此源');const values=checkedFilters(body.filters||body.extend||{},h.filters[id]||[]);return listing(n,{id,filter:values});},
  async search(body={}){const q=keyword(body);if(!q)return {page:1,pagecount:1,list:[]};const t=await auth(),r=await post(`${API}/v3/search`,{text:q},t),rows=listOf(r?.data?.theater?.search_data);return {page:1,pagecount:1,list:cards(rows)};},
  async detail(body={}){const t=await auth(),out=[];for(const id of ids(body)){const raw=decode(source.key,'vod',id);if(!/^\d+$/.test(raw))throw bad('星芽影片标识无效');const r=await get(`${API}/v2/theater_parent/detail?theater_parent_id=${encodeURIComponent(raw)}`,t),data=r?.data||{},eps=listOf(data.theaters).filter(x=>x?.son_video_url).map((x,i)=>({name:String(x.num||i+1),id:media(x.son_video_url)}));out.push(detail(source,id,{name:data.title,pic:data.cover_url,content:data.introduction,remarks:`${eps.length}集`},[{name:'星芽原站',episodes:eps}]));}return {list:out};},
  async play(body={}){return {parse:0,url:media(decode(source.key,'episode',body.id)),extra:{nodanmu:true}};}
 };
}
