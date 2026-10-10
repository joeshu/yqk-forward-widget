// Public web protocol observed on ai.baipiaozhe.com, 2026-10-10.
// Uses the site's normal anonymous visitor session. No account credentials.
var WidgetMetadata={id:'joeshu.souju',title:'搜剧AI',author:'joeshu',site:'https://ai.baipiaozhe.com',version:'0.6.0',requiredVersion:'0.0.1',description:'最新片单、分集完整性核对、AI额度状态与直连回退。',detailCacheDuration:0,
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
WidgetMetadata.modules.unshift({id:'aiQuotaStatus',title:'AI额度状态',description:'只读取本组件的北京时间用量记录，不请求或消耗AI解析；原站实际余额以原站为准。',functionName:'loadAiQuotaStatus',cacheDuration:0,params:[]});
sjOldModules[0].cacheDuration=60;
var SjHomeTopics=[['tv_domestic','国产新剧'],['tv_american','美剧续看'],['tv_korean','韩剧在追'],['tv_japanese','日剧上新'],['tv_animation','动画连载'],['movie_hot','电影热播'],['movie_high_score','高分电影'],['movie_hidden_gems','冷门好片']];
sjOldModules[0].params=[{name:'topic',title:'推荐片单',type:'enumeration',value:'all',enumOptions:[{title:'全部推荐',value:'all'}].concat(SjHomeTopics.map(function(t){return {title:t[1],value:t[0]};}))}];
sjOldModules[3].params=[{name:'lineMode',title:'线路选择',description:'AI官方线路可能消耗原站词元；组件按北京时间累计本组件用量，接近每日85万时暂停解析；每次仅解析所选一条。可选额度不足时改走同片同集直连。',type:'enumeration',value:'auto',enumOptions:[{title:'优先可用（自动检查）',value:'auto'},{title:'全部直连（手动切换）',value:'all'},{title:'AI / 官方线路',value:'ai'},{title:'AI优先（额度不足时直连）',value:'aiQuotaFallback'}]},
 {name:'aiSource',title:'AI官方源',description:'选择AI模式后生效；实际可用源随影片变化。',type:'enumeration',value:'recommended',enumOptions:[{title:'原站推荐',value:'recommended'},{title:'1080P 官方R',value:'official-r'},{title:'1080P 官方Z',value:'bytevod-lv2'},{title:'高清 官方B',value:'bytedance'},{title:'1080P 官方D',value:'dong'},{title:'海外 官方C',value:'bytevod-cloudflare'},{title:'4K海外 官方C',value:'bytevod-cloudflare-4k'}]}];
WidgetMetadata.description='最新更新、当年新片、六类筛选、热播、搜索、自动检查直连及AI官方线路，并保护每日词元额度。';
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
function sjData(r){var s=r.statusCode||r.status;if(s===429){var limited=new Error('搜剧AI请求过于频繁，请稍后重试');limited.code='RATE_LIMIT';throw limited;}var d=r.data;if(typeof d==='string'){try{d=JSON.parse(d);}catch(e){throw new Error('搜剧AI返回了无效数据，请稍后更新组件');}}if(s<200||s>=300||!d||d.error){var code=d&&(d.error&&d.error.code||d.code)||'',message=s===402||/token_insufficient|quota_exceeded/.test(code)?'AI线路词元额度不足，请在原站查看额度或选择直连线路':/level_required/.test(code)?'所选AI线路需要更高原站账号等级':s===401?'AI线路需要有效原站会话，请重新进入组件；账号专属线路暂不可用':'搜剧AI接口暂不可用（HTTP '+s+'）';var error=new Error(message);error.status=Number(s);error.apiCode=code;throw error;}return d;}
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
async function sjEpisodes(id,offset){var d=await sjApi('/v1/catalog/'+sjId(id)+'/episodes?offset='+offset+'&limit=100&anchor=start');if(d.variant_id!==id||!Array.isArray(d.episodes)||!d.episode_pagination||typeof d.episode_pagination.has_more!=='boolean')throw new Error('搜剧AI分集数据异常');return d;}
function sjEpisodeLink(id,episode,offset){return SOUJU.site+'/player/'+sjId(id)+'/episode/'+sjId(episode)+'?offset='+offset;}
async function sjAllEpisodes(id){var offset=0,out=[],seen={},reportedTotal=null;
 // Assemble a single coherent season; each episode keeps the API page offset
 // for one-page token refresh during playback. Never use planned episode totals.
 for(var pages=0;pages<100;pages++){
  var page=await sjEpisodes(id,offset),pagination=page.episode_pagination,added=0;
  if(pagination.offset!=null&&Number(pagination.offset)!==offset)throw new Error('搜剧AI分集分页位置不匹配');
  if(pagination.total_count!=null){var total=Number(pagination.total_count);if(!Number.isSafeInteger(total)||total<0||total>10000)throw new Error('搜剧AI分集数量异常');reportedTotal=reportedTotal==null?total:Math.max(reportedTotal,total);}
  page.episodes.forEach(function(e){if(!e||!e.id||!e.token||seen[e.id])return;seen[e.id]=true;added++;out.push({episode:e,offset:offset});});
  if(!pagination.has_more){
   if(reportedTotal!=null&&reportedTotal!==out.length){var error=new Error('分集接口报告 '+reportedTotal+' 集，但实际只取得 '+out.length+' 集；未展示不完整列表，请重新进入详情');error.code='EPISODES_INCOMPLETE';throw error;}
   out.reportedTotal=reportedTotal;return out;
  }
  if(!page.episodes.length||!added)throw new Error('分集分页未推进，请重新进入详情');
  offset+=page.episodes.length;if(offset>=10000)throw new Error('分集分页超出安全上限，未返回不完整选集');
 }
 throw new Error('分集分页超出安全上限，未返回不完整选集');
}
async function loadDetail(link){if(link===SOUJU.site+'/widget/ai-quota')return (await loadAiQuotaStatus())[0];var p=sjParse(link),detail=await sjApi('/v1/catalog/'+p.id);if(detail.id!==p.id)throw new Error('影片详情不匹配');var episodes;
 try{episodes=await sjAllEpisodes(p.id);}catch(error){if(error.code!=='EPISODES_INCOMPLETE')throw error;episodes=await sjAllEpisodes(p.id);}
 var item=sjItem(detail);item.link=link;item.id=link;
 var marked=sjText(detail.remarks).match(/更新至\s*(\d+)\s*[集话期]/),summary='当前季实际取得 '+episodes.length+' 集'+(episodes.reportedTotal!=null?'（已核对分集接口数量）':'（分集接口分页已结束，未提供总数）');
 if(marked){summary='原站标注更新至 '+marked[1]+' 集；'+summary;if(Number(marked[1])!==episodes.length)summary+='；标注与当前季数量不同，请检查其他季或稍后刷新';}
 item.description=(item.description?item.description+' · ':'')+summary;
 item.episodeItems=episodes.map(function(row){var e=row.episode,l=sjEpisodeLink(p.id,e.id,row.offset);return {id:l,type:'url',link:l,title:sjText(e.display_name||e.title||'分集'),coverUrl:item.coverUrl,mediaType:item.mediaType};});
 item.childItems=[];
 (detail.variants||[]).forEach(function(v){if(v.id!==p.id&&v.has_playback){var l=sjLink(v.id);item.childItems.push({id:l,type:'url',link:l,title:sjText(v.season_label||v.title||'其他季'),coverUrl:item.coverUrl});}});
 return item;
}
async function loadResource(params){params=params||{};var link=String(params.link||params.id||''),m=link.match(/^https:\/\/ai\.baipiaozhe\.com\/player\/(av_[A-Za-z0-9_-]+)\/episode\/(av_[A-Za-z0-9_-]+)\?offset=(\d+)$/),id,ep;
 if(m){id=m[1];ep=m[2];}else{id=sjParse(link).id;}
 // Find the exact episode within this title, refreshing tokens rather than caching URLs.
 var target=null,offset=m?Number(m[3]):sjParse(link).offset;
 if(!Number.isSafeInteger(offset)||offset>10000)throw new Error('分集页码无效');

 var page=await sjEpisodes(id,offset);target=ep?page.episodes.find(function(e){return e.id===ep;}):page.episodes[0];
 if(!target||!target.token)throw new Error('该影片中未找到所选分集，请重新进入详情');
 var resolved=await sjApi('/v1/playback/resolve/'+sjId(target.token));if(!resolved.current_episode||resolved.current_episode.id!==target.id||!Array.isArray(resolved.line_options))throw new Error('播放分集不匹配');var seen={},out=[];
 if(params.lineMode==='ai')return sjAiResource(resolved,target,params.aiSource||'recommended');
 resolved.line_options.forEach(function(l){
  // Parser tickets may consume site quota; only expose visitor direct media.
  if(!l||l.minimum_user_level>0||l.resolve_required||l.resolved===false||l.resolve_mode==='parse'||!/^https?:\/\//.test(l.url||'')||seen[l.url])return;
  seen[l.url]=true;var headers={};Object.keys(l.headers||{}).forEach(function(k){if(!/^(cookie|authorization)$/i.test(k))headers[k]=String(l.headers[k]);});if(l.userAgent)headers['User-Agent']=String(l.userAgent);
  out.push({name:sjText(l.display_label||l.label||l.provider_name||'播放线路'),url:l.url,customHeaders:headers,_key:String(l.playback_source_id||l.provider_id||l.label||''),_hls:l.url_kind==='m3u8'||/\.m3u8(?:[?#]|$)/i.test(l.url)});
 });
 if(params.lineMode==='aiQuotaFallback'){
  try{return await sjAiResource(resolved,target,params.aiSource||'recommended');}
  catch(error){
   if(!sjAiQuotaFallbackAllowed(error)||!out.length)throw error;
   var direct;
   try{direct=await sjSelectLines(out,id+'|'+target.id,'auto');}
   catch(directError){throw new Error('AI额度不足或额度保护已暂停解析，自动切换直连后也未找到可用线路：'+directError.message);}
   return direct.map(function(line){return Object.assign({},line,{name:'直连 · '+line.name,description:'AI额度不足或额度保护已拦截，已切换为同片同集直连；未重试AI解析。'+(line.description?'；'+line.description:'')});});
  }
 }
 if(!out.length)throw new Error('此分集暂无访客直连线路，请在原站查看可用播放方式');return sjSelectLines(out,id+'|'+target.id,params.lineMode||'auto');
}
var SjAiDailyLimit=850000,SjAiWarningAt=700000,SjAiReserve=100000,SjAiQuotaKey='souju.aiQuota.v1',sjAiQuotaQueue=Promise.resolve();
function sjAiQuotaDay(){return new Date(Date.now()+8*3600000).toISOString().slice(0,10);}
function sjAiQuotaDecode(raw){
 if(raw==null)return null;var state=raw;if(typeof raw==='string'){try{state=JSON.parse(raw);}catch(e){throw new Error('AI每日额度记录损坏，为避免超额已暂停解析，请选择直连线路');}}
 if(!state||typeof state!=='object'||state.version!==1||!/^\d{4}-\d{2}-\d{2}$/.test(state.day)||!Number.isSafeInteger(state.usedTokens)||state.usedTokens<0||!Number.isSafeInteger(state.reservedTokens)||state.reservedTokens<0||typeof state.blocked!=='boolean')throw new Error('AI每日额度记录无效，为避免超额已暂停解析，请选择直连线路');
 return {version:1,day:state.day,usedTokens:state.usedTokens,reservedTokens:state.reservedTokens,blocked:state.blocked};
}
async function sjAiQuotaRead(){
 if(!Widget.storage||typeof Widget.storage.get!=='function'||typeof Widget.storage.set!=='function')throw new Error('客户端不支持AI额度保护的持久记录，已暂停AI解析，请选择直连线路');
 try{return sjAiQuotaDecode(await Widget.storage.get(SjAiQuotaKey));}catch(e){if(/AI每日额度记录|客户端不支持/.test(e.message))throw e;throw new Error('无法读取AI每日额度记录，已暂停AI解析，请选择直连线路');}
}
async function sjAiQuotaWrite(state){
 try{await Widget.storage.set(SjAiQuotaKey,JSON.stringify(state));var check=sjAiQuotaDecode(await Widget.storage.get(SjAiQuotaKey));if(!check||check.version!==state.version||check.day!==state.day||check.usedTokens!==state.usedTokens||check.reservedTokens!==state.reservedTokens||check.blocked!==state.blocked)throw new Error('verify');}
 catch(e){throw new Error('AI每日额度记录无法可靠保存，已暂停解析，请选择直连线路');}
}
function sjAiQuotaFresh(day){return {version:1,day:day,usedTokens:0,reservedTokens:0,blocked:false};}
function sjAiQuotaTotal(state){return state.usedTokens+state.reservedTokens;}
function sjAiQuotaFormat(n){return String(n).replace(/\B(?=(\d{3})+(?!\d))/g,',');}
async function loadAiQuotaStatus(){
 var link=SOUJU.site+'/widget/ai-quota',day=sjAiQuotaDay(),item={id:link,type:'url',link:link,title:'AI额度状态',description:'',episodeItems:[]};
 try{
  var state=await sjAiQuotaRead();if(!state||state.day<day)state=sjAiQuotaFresh(day);
  var total=sjAiQuotaTotal(state),remaining=Math.max(0,SjAiDailyLimit-total),future=state.day>day;
  var reason=future?'设备日期与记录不一致，请校准日期':state.blocked?'原站已返回额度不足':remaining<SjAiReserve?'本地余量不足以预留下一次解析':'本地保护允许预留下一次解析';
  item.title+=' · '+(future||state.blocked||remaining<SjAiReserve?'已暂停':'可预留');
  item.description='北京时间 '+day+'；本组件已记录用量 '+sjAiQuotaFormat(state.usedTokens)+' 词元；未结算／保守预留 '+sjAiQuotaFormat(state.reservedTokens)+' 词元；本地保护上限 '+sjAiQuotaFormat(SjAiDailyLimit)+' 词元；本地可预留余量 '+sjAiQuotaFormat(remaining)+' 词元；每次预留 '+sjAiQuotaFormat(SjAiReserve)+' 词元；'+reason+'。仅统计本组件记录，其他设备及原站网页用量不在此记录中，实际额度以原站为准。';
  if(state.reservedTokens)item.description+=' 未结算预留仍占用本地余量，不代表原站已经实际扣除相同词元。';
 }catch(error){item.title+=' · 记录不可用';item.description=error.message+'。无法确定本地余量，AI解析保持暂停；可选择直连。实际额度以原站为准。';}
 return [item];
}
function sjAiQuotaStop(state,detail){var total=sjAiQuotaFormat(sjAiQuotaTotal(state));return new Error('搜剧AI今日本组件已记录 '+total+'/'+sjAiQuotaFormat(SjAiDailyLimit)+' 词元'+(detail||'')+'；已暂停AI解析，请切换直连线路。实际额度以原站为准。');}
function sjAiQuotaFallbackAllowed(error){return !!error&&(error.status===402||/token_insufficient|quota_exceeded|playback_token_insufficient/i.test(String(error.apiCode||''))||/每日额度|额度不足|余量不足|额度保护|额度记录|已暂停AI解析/.test(String(error.message||'')));}
async function sjAiQuotaReserve(){
 var day=sjAiQuotaDay(),state=await sjAiQuotaRead();if(!state)state=sjAiQuotaFresh(day);
 else if(state.day<day)state=sjAiQuotaFresh(day);else if(state.day>day)throw new Error('设备日期晚于AI额度记录日期，已暂停AI解析，请校准日期或选择直连线路');
 // A leftover reservation means the app stopped before recording the prior
 // result. Count it conservatively so a restart cannot silently reset usage.
 if(state.reservedTokens){state.usedTokens+=state.reservedTokens;state.reservedTokens=0;await sjAiQuotaWrite(state);}
 if(state.blocked)throw sjAiQuotaStop(state,'；原站已返回今日额度不足');
 if(sjAiQuotaTotal(state)+SjAiReserve>SjAiDailyLimit)throw sjAiQuotaStop(state,'；余量不足以预留下一次最多 '+sjAiQuotaFormat(SjAiReserve)+' 词元的解析');
 state.reservedTokens+=SjAiReserve;await sjAiQuotaWrite(state);return {day:day,tokens:SjAiReserve};
}
async function sjAiQuotaSettle(reservation,used,error){
 var state=await sjAiQuotaRead();if(!state||state.day!==reservation.day||state.reservedTokens<reservation.tokens)throw new Error('AI每日额度记录与本次解析不匹配，已暂停AI解析，请选择直连线路');
 state.reservedTokens-=reservation.tokens;
 if(error){
  if(error.status===402||/token_insufficient|quota_exceeded|playback_token_insufficient/.test(error.apiCode||'')){state.blocked=true;state.usedTokens=Math.max(state.usedTokens,SjAiDailyLimit);}
  else if(error.code==='RATE_LIMIT'||error.status===401||error.status===403){}
  else state.reservedTokens+=reservation.tokens; // Unknown failure: keep a full-cost reserve.
 }else if(Number.isSafeInteger(used)&&used>=0)state.usedTokens+=used;
 else state.reservedTokens+=reservation.tokens; // Missing cost: do not spend the allowance twice.
 await sjAiQuotaWrite(state);return state;
}
function sjAiQuotaLabel(state,usageKnown){var total=sjAiQuotaTotal(state),text='本组件今日累计 '+sjAiQuotaFormat(total)+'/'+sjAiQuotaFormat(SjAiDailyLimit)+' 词元（北京时间）';if(!usageKnown)text+='；本次用量未返回，已按 '+sjAiQuotaFormat(SjAiReserve)+' 词元预留';if(total>=SjAiWarningAt)text+='；已接近每日额度上限，建议改用直连线路';return text+'；实际额度以原站为准';}
function sjAiWithQuotaLock(task){var run=sjAiQuotaQueue.catch(function(){}).then(task);sjAiQuotaQueue=run.catch(function(){});return run;}
function sjAiTicket(line){var ticket=String(line.resolve_ticket||'').trim(),url=String(line.url||'');if(!ticket)ticket=url.indexOf('resolve://')===0?url.slice(10):line.url_kind==='resolve_ticket'?url:'';if(!ticket||ticket.length>4096)throw new Error('AI线路解析凭证无效，请重新进入影片详情');return ticket;}
async function sjAiResource(bundle,target,source){return sjAiWithQuotaLock(function(){return sjAiResourceOnce(bundle,target,source);});}
async function sjAiResourceOnce(bundle,target,source){
 var candidates=bundle.line_options.filter(function(l){return l&&(l.resolve_required===true||l.resolve_mode==='parse'||l.url_kind==='resolve_ticket');});
 var line=source==='recommended'?(candidates.find(function(l){return l.selected;})||candidates[0]):candidates.find(function(l){return l.provider_id===source;});
 if(!line)throw new Error('此分集没有所选AI官方线路，请改选原站推荐或直连线路');
 if(line.minimum_user_level>0)throw new Error('所选AI线路需要原站账号等级，当前组件使用访客会话');
 var ticket=sjAiTicket(line);
 var reservation=await sjAiQuotaReserve(),result,used=null,usageKnown=false,state;
 try{result=await sjApi('/v1/playback/resolve-line?view=compact',{ticket:ticket});}
 catch(error){await sjAiQuotaSettle(reservation,null,error);throw error;}
 var rawUsed=result&&result.quota_delta&&result.quota_delta.used_tokens;if(Number.isSafeInteger(rawUsed)&&rawUsed>=0){used=rawUsed;usageKnown=true;}else if(/^\d+$/.test(String(rawUsed==null?'':rawUsed))&&Number.isSafeInteger(Number(rawUsed))){used=Number(rawUsed);usageKnown=true;}
 state=await sjAiQuotaSettle(reservation,used,null);
 var actual=result&&result.line;
 if(!result||result.object!=='playback.line.resolve'||!result.current_episode||(result.current_episode.id||result.current_episode.episode_id)!==target.id||!actual||String(actual.playback_source_id||actual.id)!==String(line.playback_source_id||line.id))throw new Error('AI线路解析结果与所选分集或线路不匹配');
 if(actual.resolved!==true||actual.resolve_required===true||!/^https?:\/\//.test(actual.url||''))throw new Error('AI线路尚未返回可播放地址，请稍后重试或选择其他线路');
 var headers={};Object.keys(actual.headers||{}).forEach(function(k){if(!/^(cookie|authorization)$/i.test(k))headers[k]=String(actual.headers[k]);});if(actual.userAgent)headers['User-Agent']=String(actual.userAgent);
 var url=actual.url,hls=actual.url_kind==='m3u8'||/\.m3u8(?:[?#]|$)/i.test(url);
 if(hls)url=(await sjProbeHls({url:url,customHeaders:headers})).url;
 var label=sjText(actual.display_label||actual.label||line.display_label||line.label||'官方线路');
 return [{name:'AI · '+label,url:url,customHeaders:headers,playerType:'app',description:(hls?'HLS 主/子清单已检查':'原站解析返回的播放地址')+(usageKnown?'；本次原站消耗 '+sjAiQuotaFormat(used)+' 词元':'')+'；'+sjAiQuotaLabel(state,usageKnown)}];
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
