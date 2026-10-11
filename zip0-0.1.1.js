// ZIP0 public website adapter. SSR data is parsed as literals, never executed.
var ZipCategories=[['movie','电影'],['tv','电视剧'],['short','短剧'],['variety','综艺'],['documentary','纪录片'],['sports','体育']];
function zipMenu(){return [{name:'category',title:'分类',type:'enumeration',value:'movie',enumOptions:ZipCategories.map(function(x){return {value:x[0],title:x[1]};})},{name:'page',title:'页码',type:'page',value:'1'}];}
var WidgetMetadata={id:'joeshu.zip0',title:'ZIP0影视',author:'joeshu',site:'https://zip0.com',version:'0.1.1',requiredVersion:'0.0.1',description:'多来源搜索、六类片库、近期更新与完整分集。',detailCacheDuration:0,
 modules:[{id:'home',title:'近期电影更新',functionName:'loadHome',cacheDuration:60,params:[]},{id:'catalog',title:'分类片库',functionName:'loadCatalog',cacheDuration:60,params:zipMenu()},{id:'latest',title:'近期资源更新',functionName:'loadLatest',cacheDuration:60,params:zipMenu()},{id:'searchList',title:'搜索影片',functionName:'search',cacheDuration:0,params:[{name:'keyword',title:'片名',type:'input',description:'电影、剧集、动漫或综艺'},{name:'page',title:'页码',type:'page',value:'1'}]},{id:'loadResource',title:'获取播放线路',functionName:'loadResource',type:'stream',cacheDuration:0,params:[{name:'qualityPreference',title:'画质优先级',type:'enumeration',value:'highest',enumOptions:[{title:'最高画质（自适应）',value:'highest'},{title:'清晰优先（固定高画质）',value:'fixed'}]}]}],
 search:{title:'ZIP0搜索',functionName:'search',params:[{name:'keyword',title:'片名',type:'input'},{name:'page',title:'页码',type:'page',value:'1'}]}};
var ZIP0={site:'https://zip0.com',maxBody:4*1024*1024},zipDetailFlight={};
function zipText(v){return String(v==null?'':v).replace(/<[^>]*>/g,'').trim();}
function zipPage(v){var n=Number(v||1);if(!Number.isSafeInteger(n)||n<1||n>1000)throw new Error('页码无效');return n;}
function zipUrl(u){if(typeof u!=='string'||u.length>8192||/[\s\x00-\x1f\\]/.test(u)||!/^https?:\/\/[^/@?#]+(?:[/?#]|$)/i.test(u))throw new Error('ZIP0返回了无效资源地址');return u;}
function zipLink(source,id,episode){if(!/^[a-zA-Z0-9_-]{1,40}$/.test(source)||!/^\d{1,20}$/.test(String(id)))throw new Error('ZIP0影片标识无效');return ZIP0.site+'/watch?source='+source+'&id='+id+'&episode='+(episode||1);}
function zipParse(link){var m=String(link).match(/^https:\/\/zip0\.com\/watch\?source=([a-zA-Z0-9_-]{1,40})&id=(\d{1,20})(?:&episode=(\d+))?$/);if(!m)throw new Error('请选择ZIP0组件内的影片');var ep=Number(m[3]||1);if(!Number.isSafeInteger(ep)||ep<1||ep>10000)throw new Error('分集编号无效');return {source:m[1],id:m[2],episode:ep};}
function zipHeaders(){return {Accept:'text/html,application/json','User-Agent':'Mozilla/5.0',Referer:ZIP0.site+'/'};}
async function zipGet(path,json){if(typeof path!=='string'||path.charAt(0)!=='/'||/^\/\//.test(path)||/[\r\n]/.test(path))throw new Error('接口路径无效');var r=await Widget.http.get(ZIP0.site+path,{headers:zipHeaders()}),status=Number(r.statusCode||r.status);
 if(status===429){var e=new Error('ZIP0请求过于频繁，请稍后重试');e.code='RATE_LIMIT';throw e;}
 if(status!==200)throw new Error('ZIP0暂不可用（HTTP '+status+'），请稍后重试');var d=r.data;
 if(typeof d==='string'&&d.length>ZIP0.maxBody)throw new Error('ZIP0页面数据过大');
 if(json){if(typeof d==='string'){try{d=JSON.parse(d);}catch(e){throw new Error('ZIP0接口数据格式已变化，请更新组件');}}if(!d||d.success!==true||!Array.isArray(d.data))throw new Error('ZIP0搜索暂不可用');return d;}
 if(typeof d!=='string')throw new Error('ZIP0页面格式异常');return d;
}
// Bounded grammar for the site's Seroval SSR literal objects: strings, numbers,
// booleans, null, void 0, arrays, objects and $R[index] assignments/references.
// No eval, Function, property access, calls or operators are accepted.
function zipLiteral(input,start){var pos=start||0,nodes=0,refs=Object.create(null);
 function fail(){throw new Error('ZIP0页面数据格式已变化，请更新组件');}
 function ws(){while(/\s/.test(input.charAt(pos))&&pos<input.length)pos++;}
 function str(){var begin=pos++;while(pos<input.length){var ch=input.charAt(pos++);if(ch==='\\'){pos++;continue;}if(ch==='"'){try{return JSON.parse(input.slice(begin,pos));}catch(e){fail();}}}fail();}
 function value(depth){if(depth>32||++nodes>30000)fail();ws();var ch=input.charAt(pos),m;
  if(input.slice(pos,pos+3)==='$R['){m=input.slice(pos,pos+128).match(/^\$R\[(\d+)\]/);if(!m)fail();pos+=m[0].length;ws();var key=m[1];if(input.charAt(pos)==='='){pos++;var v=value(depth+1);refs[key]=v;return v;}if(!Object.prototype.hasOwnProperty.call(refs,key))fail();return refs[key];}
  if(ch==='"')return str();
  if(ch==='['){pos++;var a=[];ws();if(input.charAt(pos)===']'){pos++;return a;}while(true){a.push(value(depth+1));ws();ch=input.charAt(pos++);if(ch===']')return a;if(ch!==',')fail();}}
  if(ch==='{'){pos++;var o=Object.create(null);ws();if(input.charAt(pos)==='}'){pos++;return o;}while(true){ws();var k;if(input.charAt(pos)==='"')k=str();else{m=input.slice(pos,pos+128).match(/^[A-Za-z_$][A-Za-z0-9_$]*/);if(!m)fail();k=m[0];pos+=k.length;}if(k==='__proto__'||k==='constructor'||k==='prototype')fail();ws();if(input.charAt(pos++)!==':')fail();o[k]=value(depth+1);ws();ch=input.charAt(pos++);if(ch==='}')return o;if(ch!==',')fail();}}
  m=input.slice(pos,pos+128).match(/^(true|false|!0|!1|null|void\s+0|undefined)(?=[,}\]\s]|$)/);if(m){pos+=m[0].length;return m[1]==='true'||m[1]==='!0'?true:m[1]==='false'||m[1]==='!1'?false:null;}
  m=input.slice(pos,pos+128).match(/^-?(?:0|[1-9]\d*)(?:\.\d+)?(?:[eE][+-]?\d+)?(?=[,}\]\s]|$)/);if(m){pos+=m[0].length;var num=Number(m[0]);if(!Number.isFinite(num))fail();return num;}fail();
 }return value(0);
}
function zipLoader(html,kind){if(typeof html!=='string'||html.length>ZIP0.maxBody)throw new Error('ZIP0页面格式异常');var pattern=kind==='detail'?/\bl:\$R\[\d+\]=(\{id:)/g:/\bl:\$R\[\d+\]=(\{initialResponse:)/g,m=pattern.exec(html);if(!m)throw new Error('ZIP0未提供影片数据，请刷新或更新组件');return zipLiteral(html,m.index+m[0].length-m[1].length);}
function zipItem(c){if(!c||!zipText(c.title))throw new Error('ZIP0影片数据不完整');var source=c.source,id=c.id,link=c.url;if(link){var parsed=zipParse(link);source=parsed.source;id=parsed.id;}link=zipLink(source,id,1);var cover=c.poster?zipUrl(c.poster):'',genre=zipText(c.category);
 return {id:link,type:'url',link:link,title:zipText(c.title),coverUrl:cover,posterPath:cover,mediaType:/电影|片$/.test(genre)&&!/纪录|动漫/.test(genre)?'movie':'tv',releaseDate:zipText(c.year),genreTitle:genre,description:[zipText(c.sourceName)||source,zipText(c.year),genre,zipText(c.area),zipText(c.remarks),c.updatedAt?'资源更新 '+zipText(c.updatedAt):''].filter(Boolean).join(' · ')};
}
function zipCards(items){if(!Array.isArray(items))throw new Error('ZIP0片单格式异常');var seen=Object.create(null);return items.map(zipItem).filter(function(c){if(seen[c.id])return false;seen[c.id]=true;return true;});}
async function loadCatalog(params){params=params||{};var kind=params.category||'movie',page=zipPage(params.page);if(!ZipCategories.some(function(x){return x[0]===kind;}))throw new Error('ZIP0分类无效');var data=zipLoader(await zipGet('/category/'+kind+(page>1?'?page='+page:'')),'catalog'),r=data.initialResponse;if(!r||!Array.isArray(r.items))throw new Error('ZIP0分类格式异常');var health=r.sourceHealth||r.sources;if(!r.items.length&&Array.isArray(health)&&health.length&&health.every(function(s){return s.status==='error'||s.status==='timeout';}))throw new Error('ZIP0分类来源暂不可用，请稍后重试');return zipCards(r.items);}
async function loadHome(){return loadCatalog({category:'movie',page:1});}
async function loadLatest(params){return loadCatalog(params);}
async function search(params){params=params||{};var q=zipText(params.keyword).replace(/[\u200b-\u200d\ufeff]/g,'').trim();if(!q)return [];if(q.length>60)throw new Error('搜索关键词最多60个字符');var page=zipPage(params.page),d=await zipGet('/api/videos/search?query='+encodeURIComponent(q)+'&page='+page+'&limit=20',true);if(!d.pagination||Number(d.pagination.page)!==page)throw new Error('ZIP0搜索页码不一致');if(!d.data.length&&d.sources&&Number(d.sources.total)>0&&Number(d.sources.completed)===0)throw new Error('ZIP0搜索来源暂不可用，请稍后重试');return zipCards(d.data);}
async function zipDetail(ids){var key=ids.source+'/'+ids.id;if(zipDetailFlight[key])return zipDetailFlight[key];zipDetailFlight[key]=(async function(){var d=zipLoader(await zipGet('/watch?source='+ids.source+'&id='+ids.id+'&episode=1'),'detail');if(d.source!==ids.source||String(d.id)!==ids.id||!zipText(d.title)||!Array.isArray(d.episodes)||!d.episodes.length)throw new Error('ZIP0详情与所选影片不匹配');if(d.episodes.length>10000)throw new Error('ZIP0分集数量异常');if(d.episodeCount!=null&&Number(d.episodeCount)!==d.episodes.length)throw new Error('ZIP0分集数量不完整，请刷新后重试');d.episodes.forEach(function(ep){if(!ep||!zipText(ep.name))throw new Error('ZIP0分集数据不完整');zipUrl(ep.url);});return d;})();try{return await zipDetailFlight[key];}finally{delete zipDetailFlight[key];}}
async function loadDetail(link){var ids=zipParse(link),d=await zipDetail(ids),item=zipItem(d);item.description=[zipText(d.description),zipText(d.sourceName)||d.source,'原站标注：'+zipText(d.remarks),'当前来源取得 '+d.episodes.length+' 个分集条目'].filter(Boolean).join('\n');item.episodeItems=d.episodes.map(function(ep,i){var url=zipLink(d.source,d.id,i+1);return {id:url,type:'url',link:url,title:zipText(ep.name),coverUrl:item.coverUrl,mediaType:item.mediaType};});return item;}
function zipRelative(base,ref){if(/^https?:\/\//i.test(ref))return zipUrl(ref);if(/^\/\//.test(ref))return zipUrl(base.split(':')[0]+':'+ref);if(/^[a-z][a-z\d+.-]*:/i.test(ref)||/[\s\\]/.test(ref))throw new Error('播放清单地址无效');var m=base.match(/^(https?:\/\/[^/]+)(\/[^?#]*)?/i);if(!m)throw new Error('播放清单地址无效');if(ref.charAt(0)==='?')return m[1]+(m[2]||'/')+ref;var path=ref.charAt(0)==='/'?ref:(m[2]||'/').replace(/[^/]*$/,'')+ref,parts=[];path.split('/').forEach(function(p){if(p==='..')parts.pop();else if(p!=='.')parts.push(p);});return zipUrl(m[1]+parts.join('/'));}
async function zipHls(url,headers,preference){var seen=Object.create(null),reads=0;
 async function read(u,depth,keep){if(depth>=3||++reads>5||seen[u])throw new Error('播放清单检查达到上限');seen[u]=true;var r=await Widget.http.get(u,{headers:headers}),s=Number(r.statusCode||r.status);if(s===429){var e=new Error('播放线路请求过于频繁，请稍后重试');e.code='RATE_LIMIT';throw e;}var text=r.data;if(s!==200||typeof text!=='string'||text.length>1024*1024||!/^\s*#EXTM3U/.test(text))throw new Error('ZIP0所选来源播放清单不可用，请在搜索结果选择其他来源');var lines=text.split(/\r?\n/).map(function(l){return l.trim();});if(!/#EXT-X-STREAM-INF:/.test(text)){if(!/#EXTINF:/.test(text)||!lines.some(function(l){return l&&l[0]!=='#';}))throw new Error('播放清单为空');return {url:u};}
 var external=/(?:[:,])(?:AUDIO|SUBTITLES|VIDEO|CLOSED-CAPTIONS)=(?!NONE(?:,|\r?\n|$))/.test(text),variants=[];
 for(var i=0;i<lines.length;i++)if(/^#EXT-X-STREAM-INF:/.test(lines[i])){var res=lines[i].match(/RESOLUTION=(\d+)x(\d+)/),bw=lines[i].match(/(?:[:,])BANDWIDTH=(\d+)/);for(var j=i+1;j<lines.length;j++){if(/^#EXT-X-STREAM-INF:/.test(lines[j]))break;if(lines[j]&&lines[j][0]!=='#'){variants.push({url:zipRelative(u,lines[j]),width:res?Number(res[1]):0,height:res?Number(res[2]):0,bw:bw?Number(bw[1]):0});break;}}}
 variants.sort(function(a,b){return b.width*b.height-a.width*a.height||b.bw-a.bw;});var last;
 for(var v=0;v<Math.min(variants.length,2);v++)try{var chosen=variants[v],child=await read(chosen.url,depth+1,keep||external),fixed=preference==='fixed'&&!keep&&!external&&!child.retained;
 if(v===0&&child.url===chosen.url){return {url:fixed?child.url:u,width:chosen.width,height:chosen.height,fixed:fixed,retained:external||keep||child.retained};}
 if(keep||external)throw new Error('备用清单有独立音轨或字幕，请选择其他来源');return {url:child.url,width:chosen.width,height:chosen.height,fixed:fixed,retained:child.retained};}catch(e){if(e.code==='RATE_LIMIT')throw e;last=e;}
 throw last||new Error('播放子清单不可用');
 }return read(url,0,false);
}
async function loadResource(params){params=typeof params==='string'?{link:params}:params||{};var preference=params.qualityPreference||'highest';if(['highest','fixed'].indexOf(preference)<0)throw new Error('画质选项无效');var ids=zipParse(params.link),d=await zipDetail(ids),ep=d.episodes[ids.episode-1];if(!ep)throw new Error('所选分集不存在，请刷新详情');var url=zipUrl(ep.url),info={url:url},headers={'User-Agent':'Mozilla/5.0',Referer:ZIP0.site+'/'};if(/\.m3u8(?:[?#]|$)/i.test(url))info=await zipHls(url,headers,preference);else if(!/\.mp4(?:[?#]|$)/i.test(url))throw new Error('所选来源需要网页播放器，暂无法提取直连资源，请换来源');var name=(zipText(d.sourceName)||d.source)+' · '+zipText(ep.name);if(info.width&&info.height)name+=' · 清单 '+info.width+'×'+info.height;if(info.fixed)name+=' · 固定';else if(info.retained&&preference==='fixed')name+=' · 自适应（保留音轨/字幕）';return [{name:name,description:'ZIP0 · '+d.source+' · 所选来源同集',url:info.url,playerType:'app',customHeaders:headers}];}

// BEGIN COLLECTION RUNTIME
var CollectionConfig={"description":"多来源片库 · 近期更新 · 完整分集","poster":"https://joeshu.github.io/yqk-forward-widget/collection-poster.png","guide":"多来源片库 · 近期更新 · 完整分集\n选择分集后再播放；画质以原站权限和实际资源为准。网络失败请稍后重试，遇安全验证需在原站处理。\n片单摘要为展示而缩短，详情保留全文；占位图仅表示暂无海报。新旧片以原站标注为准；旧片补录也可能出现在近期更新。","homeTitle":"电影更新"};
// Common presentation and request lifecycle. Site parsers and permissions remain in their adapters.
var CollectionCooldownUntil=0;
(function collectionInstall(root) {
  var meta=WidgetMetadata, config=CollectionConfig, pending=Object.create(null), last=null;
  var storeKey='collection.status.v1.'+meta.id, guideLink=meta.site.replace(/\/$/,'')+'/#joeshu-widget-guide';
  function text(value){return String(value==null?'':value).trim();}
  function scrub(value){return text(value).replace(/https?:\/\/\S+/g,'[地址]').replace(/(?:cookie|token|sessionSign|captcha_login_sign)\s*[:=]\s*\S+/gi,'[会话信息]').replace(/\b[a-f\d]{32,}\b/gi,'[标识]').slice(0,240);}
  function artwork(value){var s=text(value);if(/^\/\//.test(s))return 'https:'+s;if(/^https?:\/\/[^\s/@]+(?:[/?#]|$)/i.test(s)||/^data:image\//i.test(s))return s;return '';}
  function listItem(item){if(!item||typeof item!=='object')return item;var out=Object.assign({},item), cover=artwork(item.coverUrl)||artwork(item.posterPath);
    out.title=text(item.title);if(!cover&&/^\//.test(text(item.coverUrl)))cover=meta.site.replace(/\/$/,'')+text(item.coverUrl);
    if(!cover&&!text(item.posterPath)){cover=config.poster;out.description='暂无原站海报'+(item.description?' · '+text(item.description):'');}
    if(cover){out.coverUrl=cover;if(!item.posterPath)out.posterPath=cover;}
    var info=[],year=text(item.releaseDate).match(/^(?:19|20)\d{2}/), desc=text(out.description||item.description);
    if(year&&desc.indexOf(year[0])<0)info.push(year[0]);
    var genre=text(item.genreTitle);if(genre&&genre.length<=30&&desc.indexOf(genre)<0)info.push(genre);
    var summary=desc.replace(/\s+/g,' ');if(summary.length>150)summary=summary.slice(0,150)+'…';out.description=info.concat(summary?[summary]:[]).join(' · ');return out;
  }
  function resultList(items){if(!Array.isArray(items))throw new Error('片单格式异常，请更新模块后重试');var seen=Object.create(null),out=[];items.forEach(function(item){var key=item&&text(item.id||item.link);if(key&&seen[key])return;if(key)seen[key]=true;out.push(listItem(item));});return out;}
  function canonical(value,depth){if(depth>8)throw Error('deep');if(value===null||typeof value!=='object')return value;if(Array.isArray(value))return value.map(function(v){return canonical(v,depth+1);});var out={};Object.keys(value).sort().forEach(function(k){out[k]=canonical(value[k],depth+1);});return out;}
  function requestKey(name,args){try{var s=JSON.stringify(canonical(args,0));return s.length<=8192?name+'|'+s:null;}catch(e){return null;}}
  function errorHint(error){var e=new Error(),s=scrub(error&&error.message||error),status=Number(error&&error.status);
    if(/TLS|SSL|secure connection|安全连接|证书|-120[0-6]/i.test(s))s='HTTPS连接失败，请检查网络或代理后重试';
    else if(/timed out|timeout|超时|-1001/i.test(s))s='请求超时，请稍后重试或检查网络';
    if((error&&error.code==='RATE_LIMIT')||status===429){CollectionCooldownUntil=Date.now()+30000;s='原站请求过于频繁，30秒后重试；本次不再继续换线';}
    e.message=(s.indexOf(meta.title)===0?'':meta.title+'：')+s;
    ['code','status','apiCode','name'].forEach(function(k){if(error&&error[k]!=null)e[k]=error[k];});return e;
  }
  async function record(row){last={version:1,id:meta.id,at:Date.now(),stage:({loadDetail:'完整分集',loadResource:'线路检查',search:'搜索',loadHome:'首页推荐',loadLatest:'近期更新',loadCatalog:'分类片库',loadCategory:'分类片库',loadFiltered:'条件筛选'})[row.stage]||'片单加载',ok:row.ok,count:row.count==null?null:row.count,elapsedMs:row.elapsedMs,error:row.error||''};try{if(Widget.storage&&typeof Widget.storage.set==='function')await Widget.storage.set(storeKey,JSON.stringify(last));}catch(e){}}
  async function status(){var row=last;try{if(!row&&Widget.storage){var raw=await Widget.storage.get(storeKey);if(typeof raw==='string'&&raw.length<4096){var data=JSON.parse(raw);if(data.version===1&&data.id===meta.id&&typeof data.ok==='boolean'&&Number.isFinite(data.at)&&data.at>0&&data.at<=Date.now()+60000)row=data;}}}catch(e){}
    var title=meta.title+' · '+(row?(row.ok?'最近加载成功':'最近加载受阻'):'使用说明'),description=config.guide;
    if(row){var date=new Date(row.at+8*3600000).toISOString().slice(0,16).replace('T',' ');description='最近记录：北京时间 '+date+' · '+(row.stage||'加载')+' · '+Math.round(Number(row.elapsedMs)||0)+'毫秒'+(row.count!=null?' · '+row.count+'项':'')+'\n'+(!row.ok?scrub(row.error)+'\n':'')+description+'\n这是一条历史记录，不代表原站当前在线状态。';}
    return [{id:guideLink,type:'url',link:guideLink,title:title,description:description,coverUrl:config.poster}];
  }
  root.collectionStatus=status;
  var functions=Object.create(null);meta.modules.forEach(function(m){if(m.functionName&&!/^(?:configureSession|loadAiQuotaStatus|collectionStatus)$/.test(m.functionName))functions[m.functionName]=true;});if(meta.search)functions[meta.search.functionName]=true;functions.loadDetail=true;functions.loadResource=true;
  Object.keys(functions).forEach(function(name){var original=root[name];if(typeof original!=='function')return;root[name]=function(){var args=Array.prototype.slice.call(arguments),self=this;if(name==='search'&&!text(args[0]&&args[0].keyword).replace(/[\u200b-\u200d\ufeff]/g,''))return Promise.resolve([]);
    if(name==='loadDetail'&&args[0]===guideLink)return status().then(function(items){return items[0];});
    if(Date.now()<CollectionCooldownUntil){var e=new Error(meta.title+'：原站请求过于频繁，请在30秒后重试');e.code='RATE_LIMIT';return Promise.reject(e);}
    var key=requestKey(name,args);if(Object.keys(pending).length>=64)key=null;if(key&&pending[key])return pending[key];var start=Date.now();var promise=Promise.resolve().then(function(){return original.apply(self,args);}).then(function(value){return name==='loadDetail'||name==='loadResource'?value:resultList(value);}).then(async function(out){await record({stage:name,ok:true,count:Array.isArray(out)?out.length:null,elapsedMs:Date.now()-start});return out;},async function(error){var e=errorHint(error);await record({stage:name,ok:false,elapsedMs:Date.now()-start,error:e.message});throw e;});
    if(key){pending[key]=promise;function clean(){if(pending[key]===promise)delete pending[key];}promise.then(clean,clean);}return promise;
  };});
  meta.description=config.description;meta.detailCacheDuration=0;
  meta.modules.forEach(function(m){if(m.id==='latest')m.title=config.latestTitle||'近期更新';if(m.id==='home')m.title=config.homeTitle||'首页推荐';if(m.id==='catalog'||m.id==='category')m.title=config.catalogTitle||'分类片库';if(m.id==='searchList')m.title=meta.id==='joeshu.anime1'?'搜索动画':'搜索影片';if(m.type==='stream'){m.cacheDuration=0;m.title='播放线路';}else if(m.functionName==='search')m.cacheDuration=0;else if(!/^(?:configureSession|loadAiQuotaStatus)$/.test(m.functionName))m.cacheDuration=m.id==='latest'?30:60;});
  if(meta.search&&!meta.modules.some(function(m){return m.functionName===meta.search.functionName;}))meta.modules.push({id:'searchList',title:'搜索影片',functionName:meta.search.functionName,cacheDuration:0,params:meta.search.params});
  function order(m){if(m.id==='latest')return 0;if(m.id==='home')return 1;if(m.id==='newReleases')return 2;if(m.functionName==='configureSession')return meta.id==='joeshu.juyeye'?-1:8;if(m.functionName==='loadAiQuotaStatus')return 8;if(m.type==='stream')return 10;if(m.id==='searchList')return 7;return 3;}
  meta.modules=meta.modules.map(function(m,i){return {m:m,i:i};}).sort(function(a,b){return order(a.m)-order(b.m)||a.i-b.i;}).map(function(x){return x.m;});
  meta.modules.splice(meta.modules.findIndex(function(m){return m.type==='stream';})<0?meta.modules.length:meta.modules.findIndex(function(m){return m.type==='stream';}),0,{id:'collectionGuide',title:'使用说明与状态',functionName:'collectionStatus',cacheDuration:0,params:[]});
})(globalThis);
