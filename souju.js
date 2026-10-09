// Public web protocol observed on ai.baipiaozhe.com, 2026-10-10.
// Uses the site's normal anonymous visitor session. No account credentials.
var WidgetMetadata={id:'joeshu.souju',title:'搜剧AI',author:'joeshu',site:'https://ai.baipiaozhe.com',version:'0.1.0',requiredVersion:'0.0.1',description:'首页推荐、分类片库、片名搜索、分集与访客直连播放。',detailCacheDuration:0,
 modules:[{id:'home',title:'首页推荐',functionName:'loadHome',cacheDuration:300,params:[]},
 {id:'catalog',title:'分类片库',functionName:'loadCatalog',cacheDuration:60,params:[{name:'kind',title:'分类',type:'enumeration',value:'movie',enumOptions:[{title:'电影',value:'movie'},{title:'电视剧',value:'series'},{title:'动漫',value:'anime'},{title:'综艺',value:'variety'},{title:'短剧',value:'short_drama'},{title:'纪录片',value:'documentary'}]},{name:'page',title:'页码',type:'page',value:'1'}]},
 {id:'searchList',title:'搜索影片',functionName:'search',cacheDuration:0,params:[{name:'keyword',title:'片名',type:'input',description:'例如：流浪地球、庆余年'},{name:'page',title:'页码',type:'page',value:'1'}]},
 {id:'loadResource',title:'播放线路',type:'stream',functionName:'loadResource',cacheDuration:0,params:[]}],
 search:{title:'搜剧AI搜索',functionName:'search',params:[{name:'keyword',title:'片名',type:'input'},{name:'page',title:'页码',type:'page',value:'1'}]}};
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
function sjItem(c){if(!c||!c.title)throw new Error('搜剧AI影片数据不完整');var link=sjLink(c.id),cover=/^https?:\/\//.test(c.poster_url||'')?c.poster_url:'';
 return {id:link,type:'url',link:link,title:sjText(c.title),coverUrl:cover,posterPath:cover,mediaType:c.content_kind==='movie'?'movie':'tv',releaseDate:c.year?String(c.year):'',genreTitle:(c.genres||[]).map(sjText).join(' / '),description:[sjText(c.description),c.year,sjText(c.area),sjText(c.remarks)].filter(Boolean).join(' · ')};
}
function sjCards(cards){if(!Array.isArray(cards))throw new Error('搜剧AI片单格式异常');var seen={};return cards.filter(function(c){if(!c||!c.id||seen[c.id]||c.availability&&(c.availability.disabled||c.availability.playable===false))return false;seen[c.id]=true;return true;}).map(sjItem);}
function sjPage(p){var n=Number(p||1);if(!Number.isSafeInteger(n)||n<1||n>500)throw new Error('页码无效');return n;}
async function loadHome(){var d=await sjApi('/v1/feed/home?scope=public&mode=preview&sections=3&cards=10');if(!Array.isArray(d.sections))throw new Error('搜剧AI首页数据异常');var cards=[];d.sections.forEach(function(s){if(!Array.isArray(s.cards))throw new Error('推荐片单异常');cards=cards.concat(s.cards);});return sjCards(cards);}
async function loadCatalog(params){params=params||{};var kind=params.kind||'movie';if(['movie','series','anime','variety','short_drama','documentary'].indexOf(kind)<0)throw new Error('分类无效');return sjCards((await sjApi('/v1/browse/catalog?kind='+kind+'&page='+sjPage(params.page)+'&limit=20')).cards);}
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
  out.push({name:sjText(l.display_label||l.label||l.provider_name||'播放线路'),url:l.url,customHeaders:headers});
 });if(!out.length)throw new Error('此分集暂无访客直连线路，请在原站查看可用播放方式');return out;
}
