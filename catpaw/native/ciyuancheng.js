import {makeWidget} from '../runtime.js';
import {bad,page,card,detail,encode,decode,ids,keyword,media,checkedFilters,cachedListing} from './common.js';

const SITE='https://www.cycani.org',API=SITE+'/api',PAGE_SIZE=20,SECTION_SIZE=100;
const HEADERS={'User-Agent':'Mozilla/5.0 (iPhone; CPU iPhone OS 18_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.5 Mobile/15E148 Safari/604.1','Accept':'application/json','X-App-Name':'cyc_web','X-App-Version':'cycweb','X-Time-Zone':'Asia/Shanghai','Referer':SITE+'/'};
function list(v){return Array.isArray(v)?v:[];}
function label(v){return String(v??'').replace(/[\x00-\x1f]/g,' ').trim();}

export function createCiyuancheng(source,storage,request,controllers){
 const w=makeWidget(source.key,storage,request,controllers);
 async function json(path,params={}){
  const url=new URL(API+path);for(const [k,v] of Object.entries(params))if(v!==''&&v!=null)url.searchParams.set(k,String(v));
  const r=await w.http.get(url.href,{headers:HEADERS});if(r.status<200||r.status>=300)throw Error('次元城原站请求失败：HTTP '+r.status);
  const data=typeof r.data==='string'?JSON.parse(r.data):r.data;if(!data||typeof data!=='object'||Number(data.code)!==0)throw Error(label(data?.msg)||'次元城原站响应异常');return data.data||{};
 }
 function rows(v){return list(v).map(x=>card(source,{id:x?.video_id??x?.id,name:x?.title,pic:x?.cover_url,remarks:x?.remarks||x?.year})).filter(Boolean);}
 function makeFilters(zone){const f=[];for(const [key,name,values] of [['tag','题材',zone?.categories],['area','地区',zone?.areas],['language','语言',zone?.languages],['year','年份',zone?.years]]){const opts=list(values).map(label).filter(Boolean);if(opts.length)f.push({key,name,value:opts.map(v=>({n:v,v}))});}f.push({key:'order_by',name:'排序',value:[{n:'更新时间',v:'update_time'},{n:'热度',v:'hits'},{n:'评分',v:'score'}]});return f;}
 function total(data,count){const n=Number(data?.pager?.total);if(!Number.isSafeInteger(n)||n<0)throw Error('次元城原站分页总数异常');return n||count;}
 const listing=cachedListing(async(n,o)=>{const data=await json('/videos',{zone_id:o.id,page:n,page_size:PAGE_SIZE,tag:o.filter.tag,area:o.filter.area,language:o.filter.language,year:o.filter.year,order_by:o.filter.order_by||'update_time'});const result=rows(data.list);if(!Array.isArray(data.list))throw Error('次元城原站片单格式异常');return result;});
 async function zones(){const data=await json('/video-zones'),out=list(data.list).filter(x=>x&&x.id!=null&&label(x.name)).map(x=>({type_id:String(x.id),type_name:label(x.name)}));if(!out.length)throw Error('次元城原站分类为空');return {class:out,filters:Object.fromEntries(list(data.list).filter(x=>x&&x.id!=null).map(x=>[String(x.id),makeFilters(x.filters)]))};}
 return {
  async init(){return {};},
  async home(){return zones();},
  async homeVod(){const z=await zones(),first=z.class[0];if(!first)return {list:[]};return {list:(await listing(1,{id:first.type_id,filter:{}})).list};},
  async category(body={}){const p=page(body.page),z=await zones(),id=String(body.id||'');if(!z.class.some(x=>x.type_id===id))throw bad('分类不属于此源');const filter=checkedFilters(body.filters||body.extend||{},z.filters[id]||[]);return listing(p,{id,filter});},
  async search(body={}){const q=keyword(body),p=page(body.page);if(!q)return {page:p,pagecount:1,total:0,list:[]};const data=await json('/videos/search',{q,page:p,page_size:PAGE_SIZE}),items=rows(data.list),count=total(data,items.length);return {page:p,pagecount:Math.max(1,Math.ceil(count/PAGE_SIZE)),total:count,list:items};},
  async detail(body={}){const out=[];for(const id of ids(body)){const videoId=decode(source.key,'vod',id);if(videoId.length>120)throw bad('次元城影片标识无效');const data=await json('/videos/'+encodeURIComponent(videoId)),lines=[];for(const player of list(data.play_from)){const code=label(player?.code),lineName=label(player?.title)||code;if(!code)continue;const eps=[];let found=0,expected=null;for(let p=1;p<=50;p++){const part=await json('/videos/'+encodeURIComponent(videoId)+'/sections',{player_code:code,page:p,page_size:SECTION_SIZE});if(!Array.isArray(part.list))throw Error('次元城分集格式异常');if(expected===null)expected=total(part,part.list.length);if(!part.list.length){if(found<expected)throw Error('次元城分集分页不完整，已停止返回残缺列表');break;}for(const ep of part.list){const sectionId=label(ep?.id),name=label(ep?.title)||`第${found+1}集`;if(!sectionId)throw Error('次元城分集标识缺失');eps.push({name,id:sectionId});found++;}if(found>=expected)break;}if(expected!==null&&found!==expected)throw Error('次元城分集数量与原站不一致');if(eps.length)lines.push({name:lineName,episodes:eps});}out.push(detail(source,id,{name:data.title,pic:data.cover_url,remarks:data.remarks,year:data.year,content:data.description,actor:list(data.actor).map(label).join(','),director:list(data.director).map(label).join(',')},lines));}return {list:out};},
  async play(body={}){const sectionId=decode(source.key,'episode',body.id);if(sectionId.length>120)throw bad('次元城分集标识无效');const data=await json('/v2/sections/'+encodeURIComponent(sectionId)+'/play-url');return {parse:0,url:media(data.url),header:{...HEADERS,Accept:'*/*'}};}
 };
}
