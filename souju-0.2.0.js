// Public web protocol observed on ai.baipiaozhe.com, 2026-10-10.
// Uses the site's normal anonymous visitor session. No account credentials.
var WidgetMetadata={id:'joeshu.souju',title:'搜剧AI',author:'joeshu',site:'https://ai.baipiaozhe.com',version:'0.2.0',requiredVersion:'0.0.1',description:'首页推荐、分类片库、片名搜索、分集与访客直连播放。',detailCacheDuration:0,
 modules:[{id:'home',title:'首页推荐',functionName:'loadHome',cacheDuration:300,params:[]},
 {id:'catalog',title:'分类片库',functionName:'loadCatalog',cacheDuration:60,params:[{name:'kind',title:'分类',type:'enumeration',value:'movie',enumOptions:[{title:'电影',value:'movie'},{title:'电视剧',value:'series'},{title:'动漫',value:'anime'},{title:'综艺',value:'variety'},{title:'短剧',value:'short_drama'},{title:'纪录片',value:'documentary'}]},{name:'page',title:'页码',type:'page',value:'1'}]},
 {id:'searchList',title:'搜索影片',functionName:'search',cacheDuration:0,params:[{name:'keyword',title:'片名',type:'input',description:'例如：流浪地球、庆余年'},{name:'page',title:'页码',type:'page',value:'1'}]},
 {id:'loadResource',title:'播放线路',type:'stream',functionName:'loadResource',cacheDuration:0,params:[]}],
 search:{title:'搜剧AI搜索',functionName:'search',params:[{name:'keyword',title:'片名',type:'input'},{name:'page',title:'页码',type:'page',value:'1'}]}};
// Menus are per-content-kind; original module IDs remain stable.
var SjKinds=[['movie','电影'],['series','电视剧'],['anime','动漫'],['variety','综艺'],['short_drama','短剧'],['documentary','纪录片']];
var SjGenres={movie:['动作','喜剧','爱情','科幻','悬疑','犯罪','恐怖','惊悚','冒险','战争','剧情','动画'],series:['剧情','爱情','喜剧','悬疑','犯罪','古装','家庭','战争'],anime:['动作','奇幻','冒险','科幻','喜剧'],variety:['真人秀','音乐','脱口秀'],short_drama:['爱情','古装','悬疑','剧情'],documentary:['自然','历史','人文']};
var SjAreas=['中国大陆','中国香港','中国台湾','美国','英国','韩国','日本','泰国'];
function sjOptions(values){return [{title:'全部',value:''}].concat(values.map(function(v){return {title:v,value:v};}));}
function sjFilterParams(kind){return [{name:'kind',title:'分类',type:'constant',value:kind},
 {name:'genre',title:'类型',type:'enumeration',value:'',enumOptions:sjOptions(SjGenres[kind])},
 {name:'area',title:'地区',type:'enumeration',value:'',enumOptions:sjOptions(SjAreas)},
 {name:'year',title:'年份',type:'enumeration',value:'',enumOptions:[{title:'全部',value:''},{title:'今年',value:'current'},{title:'去年',value:'previous'},{title:'前年',value:'twoYearsAgo'}]},
 {name:'sort',title:'排序',type:'enumeration',value:'updated_desc',enumOptions:[{title:'资源更新',value:'updated_desc'},{title:'热度优先',value:'heat_desc'}]},
 {name:'page',title:'页码',type:'page',value:'1'}];}
var sjOldModules=WidgetMetadata.modules;
var sjKindOptions=[{title:'全部',value:''}].concat(SjKinds.map(function(k){return {title:k[1],value:k[0]};}));
var sjNewModules=[{id:'latest',title:'最新资源更新',description:'原站最新入库/更新片单，旧片补录也可能出现；本页按返回更新时间排序。',functionName:'loadLatest',cacheDuration:60,params:[{name:'kind',title:'分类',type:'enumeration',value:'',enumOptions:sjKindOptions},{name:'period',title:'范围',type:'constant',value:'updated'},{name:'page',title:'页码',type:'page',value:'1'}]},
 {id:'newReleases',title:'当年新片新剧',description:'年份随当前年份自动更新，不把未来年份条目当作已上映新片。',functionName:'loadLatest',cacheDuration:60,params:[{name:'kind',title:'分类',type:'enumeration',value:'movie',enumOptions:sjKindOptions},{name:'period',title:'范围',type:'enumeration',value:'current',enumOptions:[{title:'今年',value:'current'},{title:'去年',value:'previous'}]},{name:'page',title:'页码',type:'page',value:'1'}]},sjOldModules[0],
 {id:'trending',title:'今日热播',functionName:'loadTrending',cacheDuration:120,params:[{name:'kind',title:'分类',type:'enumeration',value:'',enumOptions:sjKindOptions},{name:'window',title:'榜单',type:'enumeration',value:'day',enumOptions:[{title:'今日',value:'day'},{title:'本周',value:'week'},{title:'本月',value:'month'}]},{name:'page',title:'页码',type:'page',value:'1'}]}];
WidgetMetadata.modules=sjNewModules.concat(SjKinds.map(function(k){return {id:'kind_'+k[0],title:k[1],functionName:'loadCatalog',cacheDuration:60,params:sjFilterParams(k[0])};}),[sjOldModules[1],sjOldModules[2],sjOldModules[3]]);
sjOldModules[0].cacheDuration=60;
var SjHomeTopics=[['tv_domestic','国产新剧'],['tv_american','美剧续看'],['tv_korean','韩剧在追'],['tv_japanese','日剧上新'],['tv_animation','动画连载'],['movie_hot','电影热播'],['movie_high_score','高分电影'],['movie_hidden_gems','冷门好片']];
sjOldModules[0].params=[{name:'topic',title:'推荐片单',type:'enumeration',value:'all',enumOptions:[{title:'全部推荐',value:'all'}].concat(SjHomeTopics.map(function(t){return {title:t[1],value:t[0]};}))}];
sjOldModules[3].params=[{name:'lineMode',title:'线路选择',type:'enumeration',value:'auto',enumOptions:[{title:'优先可用（自动检查）',value:'auto'},{title:'全部直连（手动切换）',value:'all'}]}];
WidgetMetadata.description='最新更新、当年新片、六类筛选、热播、搜索与自动检查直连线路。';
var SOUJU={site:'https://ai.baipiaozhe.com',
 // Public request-signing configuration distributed in the site's web bundle;
 // not an account token. Site changes may require updating this configuration.
 signingKey:'f39d73aa7a6426203cdee1ef17b31d3b7ea8c23f4c59c62a3a8aa0f39ee5e79d'};
// Portable SHA-256/HMAC: Forward runtimes need neither Node nor Web Crypto.
function sjBytes(text){var s=unescape(encodeURIComponent(text));return Array.prototype.map.call(s,function(c){return c.charCodeAt(0);});}
function sjSha(bytes){
 var k=[1116352408,1899447441,3049323471,3921009573,961987163,1508970993,2453635748,2870763221,3624381080,310598401,607225278,1426881987,1925078388,2162078206,2614888103,3248222580,3835390401,4022224774,264347078,604807628,770255983,1249150122,1555081692,1996064986,2554220882,2821834349,2952996808,3210313671,3336571891,3584528711,113926993,338241895,666307205,773529912,1294757372,1396182291,1695183700,1986661051,2177026350,2456956037,2730485921,2820302411,3259730800,3345764771,3516065817,3600352804,4094571909,275423344,430227734,506948616,659060556,883997877,958139571,1322822218,1537002063,1747873779,1955562222,2024104815,2227730452,2361852424,2428436474,2756734187,3204031479,3329325298];
 var h=[1779033703,3144134277,1013904242,2773480762,1359893119,2600822924,528734635,1541459225],b=bytes.slice(),bits=b.length*8;
 b.push(128);while(b.length%64!==56)b.push(0);for(var i=7;i>=0;i--)b.push(Math.floor(bits/Math.pow(256,i))&255);
 function r(x,n){return (x>>>n)|(x<<(32-n));}
 for(var off=0;off<b.length;off+=64){var w=[];for(i=0;i<16;i++)w[i]=(b[off+i*4]<<24)|(b[off+i*4+1]<<16)|(b[off+i*4+2]<<8)|b[off+i*4+3];
  for(i=16;i<64;i++){var x=w[i-15],y=w[i-2];w[i]=(w[i-16]+(r(x,7)^r(x,18)^(x>>>3))+w[i-7]+(r(y,17)^r(y,19)^(y>>>10)))|0;}
  var a=h.slice();for(i=0;i<64;i++){var t1=(a[7]+(r(a[4],6)^r(a[4],11)^r(a[4],25))+((a[4]&a[5])^(~a[4]&a[6]))+k[i]+w[i])|0,t2=((r(a[0],2)^r(a[0],13)^r(a[0],22))+((a[0]&a[1])^(a[0]&a[2])^(a[1]&a[2])))|0;a=[(t1+t2)|0,a[0],a[1],a[2],(a[3]+t1)|0,a[4],a[5],a[6]];}
  for(i=0;i<8;i++)h[i]=(h[i]+a[i])|0;
 }var out=[];h.forEach(function(x){for(var n=3;n>=0;n--)out.push((x>>>(n*8))&255);});return out;
}
function sjHmac(key,text){var k=sjBytes(key);if(k.length>64)k=sjSha(k);while(k.length<64)k.push(0);return sjSha(k.map(function(x){return x^92;}).concat(sjSha(k.map(function(x){return x^54;}).concat(sjBytes(text))))).map(function(x){return ('0'+x.toString(16)).slice(-2);}).join('');}
var sjMemory={},sjSessionPromise=null;
async function sjGet(k){if(Object.prototype.hasOwnProperty.call(sjMemory,k))return sjMemory[k];try{var v=await Widget.storage.get('souju.'+k);if(v)return sjMemory[k]=JSON.parse(v);}catch(e){}return null;}
async function sjSet(k,v){sjMemory[k]=v;try{await Widget.storage.set('souju.'+k,JSON.stringify(v));}catch(e){}}
function sjNonce(){return 'xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx'.replace(/x/g,function(){return (Math.random()*16|0).toString(16);});}
function sjData(r){var s=r.statusCode||r.status;if(s===429)throw new Error('搜剧AI请求过于频繁，请稍后重试');var d=r.data;if(typeof d==='string'){try{d=JSON.parse(d);}catch(e){throw new Error('搜剧AI返回了无效数据，请稍后更新组件');}}if(s<200||s>=300||!d||d.error)throw new Error('搜剧AI接口暂不可用（HTTP '+s+'）');return d;}
async function sjRaw(path,body,cookie){
 if(!/^\/v1\//.test(path)||/[\r\n]/.test(path))throw new Error('无效接口路径');
 var method=body?'POST':'GET',ts=String(Date.now()),nonce=sjNonce();var headers={Accept:'application/json','Content-Type':'application/json',Referer:SOUJU.site+'/',Origin:SOUJU.site,'x-ai-movie-timestamp':ts,'x-ai-movie-nonce':nonce,'x-ai-movie-signature':sjHmac(SOUJU.signingKey,method+'\n'+path+'\n'+ts+'\n'+nonce)};
 if(cookie)headers.Cookie=cookie;
 return body?await Widget.http.post(SOUJU.site+path,body,{headers:headers}):await Widget.http.get(SOUJU.site+path,{headers:headers});
}
async function sjSession(){
 if(sjSessionPromise)return sjSessionPromise;
 sjSessionPromise=(async function(){var old=await sjGet('session');if(old&&old.cookie&&old.expires>Date.now()+60000)return old;
 var id=await sjGet('visitor');if(!id){id='web_'+sjNonce();await sjSet('visitor',id);}
 var r=await sjRaw('/v1/users/anonymous',{anonymous_id:id}),d=sjData(r),headers=r.headers||{},raw='';
 Object.keys(headers).forEach(function(k){if(k.toLowerCase()==='set-cookie')raw=String(headers[k]);});
 var m=raw.match(/(?:^|[,;]\s*)ai_movie_session=([^;,\s]+)/);
 if(!m)throw new Error('客户端未提供搜剧AI访客会话 Cookie，请更新 Forward/Rex 后重试');
 var expiry=Date.parse(d.expires_at);var session={cookie:'ai_movie_session='+m[1],expires:Number.isFinite(expiry)?expiry:Date.now()+3600000};await sjSet('session',session);return session;
 })();try{return await sjSessionPromise;}finally{sjSessionPromise=null;}
}
async function sjApi(path,body){var s=await sjSession(),r=await sjRaw(path,body,s.cookie);
 // Refresh once on actual session expiry; signature/permission failures must surface.
 var data=r.data;if(typeof data==='string'){try{data=JSON.parse(data);}catch(e){}}
 if((r.statusCode||r.status)===401&&data&&data.error&&/session|authentication|unauthorized/.test(data.error.code||'')){
  if((await sjGet('session'))===s)await sjSet('session',null);s=await sjSession();r=await sjRaw(path,body,s.cookie);
 }return sjData(r);
}
function sjText(s){return String(s||'').replace(/<[^>]*>/g,'').trim();}
function sjId(s){if(typeof s!=='string'||!/^av_[A-Za-z0-9_-]+$/.test(s))throw new Error('无效影片或分集标识');return s;}
function sjLink(id,offset){return SOUJU.site+'/player/'+sjId(id)+(offset?'?offset='+offset:'');}
function sjParse(link){var m=String(link).match(/^https:\/\/ai\.baipiaozhe\.com\/player\/(av_[A-Za-z0-9_-]+)(?:\/episode\/(av_[A-Za-z0-9_-]+))?(?:\?offset=(\d+))?$/);if(!m)throw new Error('请选择搜剧AI组件内的影片');var offset=Number(m[3]||0);if(!Number.isSafeInteger(offset)||offset>10000)throw new Error('分集页码无效');return {id:m[1],offset:offset};}
function sjUpdateLabel(value){var t=Date.parse(value);return Number.isFinite(t)?'资源更新 '+new Date(t+8*3600000).toISOString().slice(0,16).replace('T',' ')+'（北京时间）':'';}
function sjItem(c){if(!c||!c.title)throw new Error('搜剧AI影片数据不完整');var link=sjLink(c.id),cover=/^https?:\/\//.test(c.poster_url||'')?c.poster_url:'';
 return {id:link,type:'url',link:link,title:sjText(c.title),coverUrl:cover,posterPath:cover,mediaType:c.content_kind==='movie'?'movie':'tv',releaseDate:c.year?String(c.year):'',genreTitle:(c.genres||[]).map(sjText).join(' / '),description:[sjText(c.description),c.year,sjText(c.area),sjText(c.remarks),sjUpdateLabel(c.updated_at)].filter(Boolean).join(' · ')};
}
function sjCards(cards){if(!Array.isArray(cards))throw new Error('搜剧AI片单格式异常');var seen={};return cards.filter(function(c){if(!c||!c.id||seen[c.id]||c.availability&&(c.availability.disabled||c.availability.playable===false))return false;seen[c.id]=true;return true;}).map(sjItem);}
function sjPage(p){var n=Number(p||1);if(!Number.isSafeInteger(n)||n<1||n>500)throw new Error('页码无效');return n;}
async function loadHome(params){params=params||{};var topic=params.topic||'all';if(topic!=='all'){if(!SjHomeTopics.some(function(t){return t[0]===topic;}))throw new Error('推荐片单无效');return sjBrowse({hot_list_key:topic,page:1,limit:20},false);}var d=await sjApi('/v1/feed/home?scope=public&mode=preview&sections=11&cards=8');if(!Array.isArray(d.sections))throw new Error('搜剧AI首页数据异常');var cards=[];d.sections.forEach(function(s){if(!Array.isArray(s.cards))throw new Error('推荐片单异常');cards=cards.concat(s.cards);});return sjCards(cards);}
function sjYear(){return new Date(Date.now()+8*3600000).getUTCFullYear();}
function sjSelectedYear(value){if(!value)return '';var year=sjYear();if(value==='current')return year;if(value==='previous')return year-1;if(value==='twoYearsAgo')return year-2;var n=Number(value);if(!/^\d{4}$/.test(String(value))||n<1900||n>year)throw new Error('年份无效');return n;}
function sjQuery(values){return Object.keys(values).filter(function(k){return values[k]!==''&&values[k]!=null;}).map(function(k){return encodeURIComponent(k)+'='+encodeURIComponent(String(values[k]));}).join('&');}
function sjCheckKind(kind,allowAll){if((!kind&&allowAll)||SjKinds.some(function(k){return k[0]===kind;}))return;throw new Error('分类无效');}
async function sjBrowse(values,latest){var d=await sjApi('/v1/browse/catalog?'+sjQuery(values));if(!Array.isArray(d.cards))throw new Error('搜剧AI片单格式异常');var cards=d.cards.filter(function(c){if(!c)return false;if(values.kind&&c.content_kind!==values.kind)return false;if(values.genre&&!(c.genres||[]).some(function(g){return String(g).indexOf(values.genre)>=0;}))return false;if(values.area&&String(c.area||'').indexOf(values.area)<0)return false;if(values.year&&Number(c.year)!==Number(values.year))return false;return true;});
 if(latest){cards=cards.filter(function(c){return c&&(!c.year||Number(c.year)<=sjYear());});
  // Only sort the returned page; the site's snapshot defines global pagination.
  cards=cards.map(function(c,i){return {c:c,i:i};}).sort(function(a,b){var ta=Date.parse(a.c.updated_at)||0,tb=Date.parse(b.c.updated_at)||0;return tb-ta||a.i-b.i;}).map(function(x){return x.c;});}
 return sjCards(cards);
}
async function loadCatalog(params){params=params||{};var kind=params.kind||'movie';sjCheckKind(kind,false);var genre=String(params.genre||''),area=String(params.area||''),year=sjSelectedYear(params.year),sort=params.sort||'updated_desc';
 if(genre&&SjGenres[kind].indexOf(genre)<0)throw new Error('类型无效');if(area&&SjAreas.indexOf(area)<0)throw new Error('地区无效');if(['updated_desc','heat_desc'].indexOf(sort)<0)throw new Error('排序无效');
 return sjBrowse({kind:kind,genre:genre,area:area,year:year,sort:sort,page:sjPage(params.page),limit:20},sort==='updated_desc');
}
async function loadLatest(params){params=params||{};var kind=params.kind||'',period=params.period||'updated';sjCheckKind(kind,true);if(['updated','current','previous'].indexOf(period)<0)throw new Error('更新范围无效');return sjBrowse({kind:kind,intent:'latest_catalog',year:period==='updated'?'':sjSelectedYear(period),page:sjPage(params.page),limit:20},true);}
async function loadTrending(params){params=params||{};var kind=params.kind||'',window=params.window||'day';sjCheckKind(kind,true);if(['day','week','month'].indexOf(window)<0)throw new Error('榜单无效');return sjBrowse({kind:kind,sort:'trending',window:window,page:sjPage(params.page),limit:20},false);}
async function search(params){params=params||{};var keyword=String(params.keyword||'').replace(/[\u200B-\u200D\uFEFF]/g,'').replace(/\s+/g,' ').trim();if(!keyword)return [];if(keyword.length>200)throw new Error('片名过长');return sjCards((await sjApi('/v1/browse/catalog?q='+encodeURIComponent(keyword)+'&intent=catalog_search&page='+sjPage(params.page)+'&limit=20')).cards);}
async function sjEpisodes(id,offset){var d=await sjApi('/v1/catalog/'+sjId(id)+'/episodes?offset='+offset+'&limit=100&anchor=start');if(d.variant_id!==id||!Array.isArray(d.episodes)||!d.episode_pagination)throw new Error('搜剧AI分集数据异常');return d;}
function sjEpisodeLink(id,episode,offset){return SOUJU.site+'/player/'+sjId(id)+'/episode/'+sjId(episode)+'?offset='+offset;}
async function loadDetail(link){var p=sjParse(link),detail=await sjApi('/v1/catalog/'+p.id),page=await sjEpisodes(p.id,p.offset);if(detail.id!==p.id)throw new Error('影片详情不匹配');var item=sjItem(detail),seen={};item.link=link;item.id=link;
 item.episodeItems=page.episodes.filter(function(e){if(!e||!e.id||!e.token||seen[e.id])return false;seen[e.id]=true;return true;}).map(function(e){var l=sjEpisodeLink(p.id,e.id,p.offset);return {id:l,type:'url',link:l,title:sjText(e.display_name||e.title||'分集'),coverUrl:item.coverUrl,mediaType:item.mediaType};});
 item.childItems=[];var pagination=page.episode_pagination;
 if(pagination.has_more){var next=p.offset+page.episodes.length;if(!page.episodes.length||next>10000)throw new Error('分集分页未推进');var l=sjLink(p.id,next);item.childItems.push({id:l,type:'url',link:l,title:'后续分集（第 '+(next+1)+' 集起）',coverUrl:item.coverUrl});}
 (detail.variants||[]).forEach(function(v){if(v.id!==p.id&&v.has_playback){var l=sjLink(v.id);item.childItems.push({id:l,type:'url',link:l,title:sjText(v.season_label||v.title||'其他季'),coverUrl:item.coverUrl});}});
 return item;
}
async function loadResource(params){var link=String(params&&(params.link||params.id)||''),m=link.match(/^https:\/\/ai\.baipiaozhe\.com\/player\/(av_[A-Za-z0-9_-]+)\/episode\/(av_[A-Za-z0-9_-]+)\?offset=(\d+)$/),id,ep;
 if(m){id=m[1];ep=m[2];}else{id=sjParse(link).id;}
 // Find the exact episode within this title, refreshing tokens rather than caching URLs.
 var target=null,offset=m?Number(m[3]):sjParse(link).offset;
 if(!Number.isSafeInteger(offset)||offset>10000)throw new Error('分集页码无效');

 var page=await sjEpisodes(id,offset);target=ep?page.episodes.find(function(e){return e.id===ep;}):page.episodes[0];
 if(!target||!target.token)throw new Error('该影片中未找到所选分集，请重新进入详情');
 var resolved=await sjApi('/v1/playback/resolve/'+sjId(target.token));if(!resolved.current_episode||resolved.current_episode.id!==target.id||!Array.isArray(resolved.line_options))throw new Error('播放分集不匹配');var seen={},out=[];
 resolved.line_options.forEach(function(l){
  // Parser tickets may consume site quota; only expose visitor direct media.
  if(!l||l.minimum_user_level>0||l.resolve_required||l.resolved===false||l.resolve_mode==='parse'||!/^https?:\/\//.test(l.url||'')||seen[l.url])return;
  seen[l.url]=true;var headers={};Object.keys(l.headers||{}).forEach(function(k){if(!/^(cookie|authorization)$/i.test(k))headers[k]=String(l.headers[k]);});if(l.userAgent)headers['User-Agent']=String(l.userAgent);
  out.push({name:sjText(l.display_label||l.label||l.provider_name||'播放线路'),url:l.url,customHeaders:headers,_key:String(l.playback_source_id||l.provider_id||l.label||''),_hls:l.url_kind==='m3u8'||/\.m3u8(?:[?#]|$)/i.test(l.url)});
 });if(!out.length)throw new Error('此分集暂无访客直连线路，请在原站查看可用播放方式');return sjSelectLines(out,id+'|'+target.id,params.lineMode||'auto');
}

function sjPublicLine(line,verified){return {name:line.name,url:line.url,customHeaders:line.customHeaders,description:verified?'HLS 主/子清单已检查；不代表全部视频分片均可播放':'访客直连线路（未读取媒体内容）'};}
function sjRelative(base,ref){if(/^https?:\/\//i.test(ref))return ref;if(/^\/\//.test(ref))return base.split(':')[0]+':'+ref;var m=base.match(/^(https?:\/\/[^/]+)(\/[^?#]*)?/i);if(!m)throw new Error('播放清单地址无效');if(/^\?/.test(ref))return m[1]+(m[2]||'/')+ref;var path=ref.charAt(0)==='/'?ref:(m[2]||'/').replace(/[^/]*$/,'')+ref;var parts=path.split('/'),clean=[];parts.forEach(function(p){if(p==='..')clean.pop();else if(p!=='.')clean.push(p);});return m[1]+clean.join('/');}
async function sjProbeHls(line){var reads=0;
 async function read(url,depth){
  if(depth>=3||reads>=5)throw new Error('播放清单检查达到上限');reads++;
  var r=await Widget.http.get(url,{headers:line.customHeaders}),status=r.statusCode||r.status;
  if(status===429){var limited=new Error('播放线路请求过于频繁，请稍后重试');limited.code='RATE_LIMIT';throw limited;}
  if(status!==200||typeof r.data!=='string'||r.data.length>1024*1024||!/^\s*#EXTM3U/.test(r.data))throw new Error('播放清单不可用');
  if(!/#EXT-X-STREAM-INF:/.test(r.data)){if(!r.data.split(/\r?\n/).some(function(x){return x.trim()&&x.trim().charAt(0)!=='#';}))throw new Error('播放清单为空');return {url:url};}
  var lines=r.data.split(/\r?\n/),variants=[];for(var i=0;i<lines.length;i++){if(!/^#EXT-X-STREAM-INF:/.test(lines[i]))continue;var resolution=lines[i].match(/RESOLUTION=(\d+)x(\d+)/),bw=lines[i].match(/(?:^|,)BANDWIDTH=(\d+)/),ref='';for(var j=i+1;j<lines.length;j++){var next=lines[j].trim();if(next&&next.charAt(0)!=='#'){ref=next;break;}if(/^#EXT-X-STREAM-INF:/.test(next))break;}if(ref)variants.push({url:sjRelative(url,ref),pixels:resolution?Number(resolution[1])*Number(resolution[2]):0,bandwidth:bw?Number(bw[1]):0});}
  if(!variants.length)throw new Error('主清单未返回子清单');variants.sort(function(a,b){return b.pixels-a.pixels||b.bandwidth-a.bandwidth;});
  for(var v=0;v<Math.min(variants.length,2);v++){try{return await read(variants[v].url,depth+1);}catch(e){if(e.code==='RATE_LIMIT')throw e;}}
  throw new Error('子清单暂不可用');
 }return read(line.url,0);
}
var sjLineFlights={};
async function sjSelectLines(lines,key,mode){
 if(['auto','all'].indexOf(mode)<0)throw new Error('线路选择无效');if(mode==='all')return lines.map(function(l){return sjPublicLine(l,false);});
 if(sjLineFlights[key])return sjLineFlights[key];
 var task=(async function(){var hints=await sjGet('lineHints')||{},hint=hints[key];
 var ranked=lines.map(function(l,i){return {l:l,i:i};}).sort(function(a,b){var recent=hint&&hint.time>Date.now()-10*60000&&hint.time<=Date.now()+60000;return (recent&&b.l._key===hint.source?1:0)-(recent&&a.l._key===hint.source?1:0)||a.i-b.i;}).map(function(x){return x.l;});
 var candidates=ranked.filter(function(l){return l._hls;}).slice(0,6),good=[],limited=null;
 // At most two reads in flight and six candidate lines. No media/key downloads.
 for(var off=0;off<candidates.length&&good.length<3;off+=2){var batch=candidates.slice(off,off+2);var results=await Promise.all(batch.map(async function(l){var start=Date.now();try{var checked=await sjProbeHls(l);return {line:Object.assign({},l,{url:checked.url}),ms:Date.now()-start};}catch(e){if(e.code==='RATE_LIMIT')limited=e;return null;}}));if(limited)throw limited;results.forEach(function(x){if(x)good.push(x);});}
 if(good.length){good.sort(function(a,b){return a.ms-b.ms;});good=good.slice(0,3);hints[key]={source:good[0].line._key,time:Date.now()};var keys=Object.keys(hints).sort(function(a,b){return hints[b].time-hints[a].time;});keys.slice(30).forEach(function(k){delete hints[k];});await sjSet('lineHints',hints);return good.map(function(x){return sjPublicLine(x.line,true);});}
 var other=ranked.filter(function(l){return !l._hls;});if(other.length)return other.map(function(l){return sjPublicLine(l,false);});
 throw new Error('已检查的 '+candidates.length+' 条 HLS 线路暂不可用，可选择“全部直连”手动切换或稍后重试');
 })();sjLineFlights[key]=task;try{return await task;}finally{delete sjLineFlights[key];}
}
