import {makeContext,errorMessage} from './runtime.js';

function bad(message){const e=new Error(message);e.statusCode=400;return e;}
function text(value){return String(value??'').replace(/[\x00-\x1f]/g,' ').trim();}
function label(value){return text(value).replace(/[$#]/g,' · ');}
function page(value){const parsed=Number(value??1),n=parsed===0?1:parsed;if(!Number.isSafeInteger(n)||n<1||n>2000)throw bad('页码无效');return n;}
function defaults(params){return Object.fromEntries((params||[]).filter(p=>p.value!==undefined).map(p=>[p.name,p.value]));}
function options(params){return (params||[]).filter(p=>p.type==='enumeration'&&p.enumOptions?.length);}
function checked(params,values){if(!values||typeof values!=='object'||Array.isArray(values))throw bad('筛选参数无效');const out={};for(const [key,value] of Object.entries(values)){const p=(params||[]).find(p=>p.name===key);if(!p||p.type!=='enumeration'||!p.enumOptions.some(e=>String(e.value)===String(value)))throw bad('筛选值不在原模块选项内');out[key]=String(value);}return out;}
function filter(params,prefix=''){return options(params).map(p=>({key:prefix+p.name,name:(prefix?'播放：':'')+p.title,init:String(p.value??p.enumOptions[0].value),value:p.enumOptions.map(v=>({n:v.title,v:String(v.value)}))}));}
function encode(key,url,play){return 'cp1.'+Buffer.from(JSON.stringify({k:key,u:url,p:play})).toString('base64url');}
function decode(key,id,stream){if(typeof id!=='string'||id.length>24000||!/^cp1\.[A-Za-z0-9_-]+$/.test(id))throw bad('请从此猫爪源选择影片或分集');let data;try{data=JSON.parse(Buffer.from(id.slice(4),'base64url').toString());}catch(e){throw bad('影片标识无效');}if(!data||data.k!==key||typeof data.u!=='string'||data.u.length>12000||Object.keys(data).some(k=>!['k','u','p'].includes(k)))throw bad('影片与所选源不匹配');return {link:data.u,play:checked(stream.params,data.p||{})};}
function signature(items){return items.map(v=>v.link||v.id).join('\n');}

export function createAdapter(source,storage,config={},request,controllers=new Set()){
  const c=makeContext(source,storage,request,controllers),meta=c.WidgetMetadata,stream=meta.modules.find(m=>m.type==='stream');
  if(!stream||typeof c.loadDetail!=='function')throw Error('原模块缺少播放或详情接口');
  const classes=meta.modules.filter(m=>m.type!=='stream'&&!['search','configureSession','loadHotSearch'].includes(m.functionName)&&m.id!=='searchList');
  const cache=new Map();
  const playDefaults=()=>({...defaults(stream.params),...checked(stream.params,config.streamOptions?.[source.prefix]||{})});
  function tokenPlay(play){return Object.fromEntries(options(stream.params).map(p=>[p.name,String(play[p.name]??p.value??p.enumOptions[0].value)]));}
  function card(v,play){const link=v.link||v.id;if(typeof link!=='string'||!link)throw Error('原模块影片地址缺失');return {vod_id:encode(source.key,link,tokenPlay(play)),vod_name:text(v.title),vod_pic:v.coverUrl||v.posterPath||'',vod_remarks:text(v.description||v.genreTitle||'')};}
  function merged(m,values={}){const listValues={},playValues={};for(const [k,v] of Object.entries(values)){if(k.startsWith('play.'))playValues[k.slice(5)]=v;else listValues[k]=v;}const params={...defaults(m.params),...checked(m.params,config.listOptions?.[source.prefix]?.[m.id]||{}),...checked(m.params,listValues)},play={...playDefaults(),...checked(stream.params,playValues)};return {params,play};}
  async function invoke(m,params){const key=m.functionName+'|'+JSON.stringify(params),old=cache.get(key);if(old&&Date.now()-old.at<30000)return old.promise;const promise=Promise.resolve().then(()=>c[m.functionName](params)).then(items=>{if(!Array.isArray(items))throw Error('原模块未返回片单');return items;});cache.set(key,{at:Date.now(),promise});promise.catch(()=>cache.delete(key));while(cache.size>64)cache.delete(cache.keys().next().value);return promise;}
  async function listing(m,params,play,n){const pageParam=m.params?.find(p=>p.type==='page');if(!pageParam&&n>1)return {page:n,pagecount:n,list:[]};const current={...params,...(pageParam?{[pageParam.name]:String(n)}:{})},items=await invoke(m,current),list=items.map(v=>card(v,play));let pagecount=n,msg='';
    // Advertise another page only after reading real, distinct results. This is
    // a confirmed lower bound, not an invented total from the original array.
    if(pageParam&&items.length)try{let timer;const next=await Promise.race([invoke(m,{...current,[pageParam.name]:String(n+1)}),new Promise(resolve=>{timer=setTimeout(()=>resolve(null),500);})]).finally(()=>clearTimeout(timer));if(next===null)msg='当前页已加载；下一页仍在检查，稍后刷新可确认翻页';else if(next.length&&signature(next)!==signature(items))pagecount=n+1;else if(next.length)msg='原站下一页重复，已停止继续翻页';}catch(e){msg='下一页未确认：'+errorMessage(e);}
    return {page:n,pagecount,list,...(msg?{msg}:{})};
  }
  function vod(v,id,play){const result={...card(v,play),vod_id:id,type_name:text(v.genreTitle),vod_year:text(v.releaseDate).slice(0,4),vod_content:text(v.description),vod_play_from:'',vod_play_url:''},groups=new Map();const add=(name,title,link)=>{if(!groups.has(name))groups.set(name,[]);groups.get(name).push(label(title)+'$'+encode(source.key,link,tokenPlay(play)));};
    const episodes=Array.isArray(v.episodeItems)?v.episodeItems:[];if(episodes.length>10000)throw Error('分集数量异常');for(const ep of episodes){const link=ep.link||ep.id;if(!link)throw Error('原模块分集地址缺失');add('推荐线路',ep.title,link);const seen=new Set();for(const choice of ep.childItems||[]){const u=choice.link||choice.id;if(!u||seen.has(u))continue;seen.add(u);const parts=text(choice.title).split(' · '),name=label(parts.length>1?parts.shift():'备用线路');add(name,parts.length?parts.join(' · '):ep.title,u);}}
    result.vod_play_from=[...groups.keys()].join('$$$');result.vod_play_url=[...groups.values()].map(episodes=>episodes.join('#')).join('$$$');if(v.childItems?.length)result.likes=v.childItems.map(v=>card(v,play));return result;
  }
  return {meta,c,
    async init(){return {};},
    async home(){const filters={};for(const m of classes)filters[m.id]=[...filter(m.params),...filter(stream.params,'play.')];return {class:classes.map(m=>({type_id:m.id,type_name:m.title})),filters};},
    async homeVod(){const m=classes.find(m=>m.id==='home')||classes[0];if(!m)return {list:[]};const {params,play}=merged(m);return {list:(await invoke(m,params)).map(v=>card(v,play))};},
    async category(body={}){const m=classes.find(m=>m.id===String(body.id));if(!m)throw bad('分类不属于此源');const {params,play}=merged(m,body.filters||{});return listing(m,params,play,page(body.page));},
    async search(body={}){const q=text(body.wd);if(!q)return {page:page(body.page),pagecount:page(body.page),list:[]};if(q.length>60)throw bad('关键词最多60字');if(!meta.search)throw bad('此源不支持搜索');const m=meta.search,{params,play}=merged(m,body.filters||{}),input=m.params?.find(p=>p.type==='input');if(!input)throw Error('搜索接口缺少关键词');params[input.name]=q;return listing(m,params,play,page(body.page));},
    async detail(body={}){const ids=Array.isArray(body.id)?body.id:[body.id];if(!ids.length||ids.length>5)throw bad('详情每次需为1–5个影片');const list=[];for(const id of ids){const item=decode(source.key,id,stream),data=await c.loadDetail(item.link);list.push(vod(data,id,{...playDefaults(),...item.play}));}return {list};},
    async play(body={}){const item=decode(source.key,body.id,stream),resources=await c[stream.functionName]({...playDefaults(),...item.play,link:item.link});if(!Array.isArray(resources)||!resources.length)throw Error('原模块未返回可播放媒体');const first=resources[0],headers=first.customHeaders||{},same=resources.filter(r=>JSON.stringify(r.customHeaders||{})===JSON.stringify(headers));const urls=[];for(const r of same){const u=new URL(r.url);if(!['https:','http:'].includes(u.protocol)||u.username||u.password)throw Error('原模块媒体地址异常');urls.push(text(r.name)||'原站媒体',r.url);}return {parse:0,url:same.length===1?same[0].url:urls,header:headers};},
  };
}
