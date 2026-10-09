var WidgetMetadata = {
  id: "joeshu.yqk", title: "一起看", author: "joeshu",
  description: "首页精选、电影/电视剧/动漫/综艺、搜索、热搜、分集与访客播放资源。",
  site: "https://m.yqk3hxe.com", version: "0.5.1", requiredVersion: "0.0.1",
  detailCacheDuration: 60,
  modules: [
    { id: "home", title: "首页精选", functionName: "loadHome", cacheDuration: 300, params: [] },
    { id: "category", title: "分类片单", description: "选择电影、电视剧、动漫或综艺，再翻页浏览。", functionName: "loadCategory", cacheDuration: 0,
      params: [
        { name: "parentChannelId", title: "分类", type: "enumeration", value: "2",
          enumOptions: [{ title: "电影", value: "2" }, { title: "电视剧", value: "3" },
            { title: "动漫", value: "8" }, { title: "综艺", value: "10" }] },
        { name: "childChannelId", title: "子分类", type: "constant", value: "" },
        { name: "page", title: "页码", type: "page", value: "1" }
      ] },
    { id: "searchList", title: "搜索影片", description: "进入栏目后填写片名；未输入关键词时不请求网站。", functionName: "search", cacheDuration: 0,
      params: [{ name: "keyword", title: "片名或关键词", description: "例如：流浪地球、庆余年", type: "input" }, { name: "page", title: "页码", type: "page", value: "1" }] },
    { id: "hotSearch", title: "热搜榜", functionName: "loadHotSearch", cacheDuration: 300,
      params: [{ name: "channelId", title: "榜单分类", type: "enumeration", value: "0",
        enumOptions: [{ title: "综合", value: "0" }, { title: "电影", value: "2" }, { title: "电视剧", value: "3" }, { title: "动漫", value: "8" }, { title: "综艺", value: "10" }] }] },
    { id: "loadResource", title: "获取播放线路", type: "stream", functionName: "loadResource", cacheDuration: 0, params: [] }
  ],
  search: { title: "一起看搜索", functionName: "search", params: [
    { name: "keyword", title: "片名或关键词", description: "例如：流浪地球、庆余年", type: "input" }, { name: "page", title: "页码", type: "page", value: "1" }
  ] }
};

// Public H5 application constants extracted from the site's entry.34539261.js.
// No account token is embedded or accepted. Keep these synchronized with site updates.
var YQK = {
  site: "https://m.yqk3hxe.com", appId: "e6ddefe09e0349739874563459f56c54", appKey: "3359de478f8d45638125e446a10ec541",
  version: "1.2.7.190", pageSize: 15, maxPage: 30, detailTTL: 60000,
  apiOverride: "", // Optional HTTPS origin of a verified API host, not the website origin.
  fallbackBases: ["https://yz250907.hzkeka49.com", "https://yz1018.6vh3qyu9x.com",
    "https://yz1018.goi6lhmry.com", "https://yzy0916.q8nsderug.com", "https://yz1018.o5r52at9v.com", "https://yz1018.tgs2hl4ut.com"]
};

function md5(text) {
  var bytes = unescape(encodeURIComponent(text)), length = bytes.length;
  var words = [], size = (((length + 8) >>> 6) + 1) * 16;
  for (var q = 0; q < size; q++) words[q] = 0;
  for (var j = 0; j < length; j++) words[j >>> 2] |= bytes.charCodeAt(j) << ((j % 4) * 8);
  words[length >>> 2] |= 0x80 << ((length % 4) * 8);
  words[size - 2] = (length * 8) | 0; words[size - 1] = Math.floor(length / 0x20000000);
  var a0 = 0x67452301, b0 = 0xefcdab89, c0 = 0x98badcfe, d0 = 0x10325476;
  var shifts = [[7,12,17,22], [5,9,14,20], [4,11,16,23], [6,10,15,21]];
  for (var off = 0; off < size; off += 16) {
    var a = a0, b = b0, c = c0, d = d0;
    for (var i = 0; i < 64; i++) {
      var f, g, round = i >>> 4;
      if (round === 0) { f = (b & c) | (~b & d); g = i; }
      else if (round === 1) { f = (d & b) | (~d & c); g = (5*i+1)%16; }
      else if (round === 2) { f = b ^ c ^ d; g = (3*i+5)%16; }
      else { f = c ^ (b | ~d); g = (7*i)%16; }
      var value = (a + f + (Math.floor(Math.abs(Math.sin(i+1))*4294967296)|0) + words[off+g]) | 0;
      var shift = shifts[round][i%4], oldD = d;
      d = c; c = b; b = (b + ((value << shift) | (value >>> (32-shift)))) | 0; a = oldD;
    }
    a0 = (a0+a)|0; b0 = (b0+b)|0; c0 = (c0+c)|0; d0 = (d0+d)|0;
  }
  return [a0,b0,c0,d0].map(function(n) {
    var s = ""; for (var k=0;k<4;k++) s += ("0"+((n >>> (k*8))&255).toString(16)).slice(-2); return s;
  }).join("");
}
function randomId() { return "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx".replace(/[xy]/g, function(c) { var n=Math.random()*16|0; return (c==="x"?n:(n&3|8)).toString(16); }); }
var yqkMemory = {};
var yqkMemoryOrder = [];
var yqkInFlight = {}, yqkQueues = {};
function runOnce(key, task) {
  if (yqkInFlight[key]) return yqkInFlight[key];
  var promise=Promise.resolve().then(task);
  yqkInFlight[key]=promise;
  function release(){if(yqkInFlight[key]===promise) delete yqkInFlight[key];}
  promise.then(release,release); return promise;
}
function serialize(key, task) {
  var previous=yqkQueues[key]||Promise.resolve();
  var promise=previous.catch(function(){}).then(task);
  yqkQueues[key]=promise;
  function release(){if(yqkQueues[key]===promise) delete yqkQueues[key];}
  promise.then(release,release); return promise;
}
async function getStored(key) {
  // The current session is newer than a failed/late persistent write.
  if (Object.prototype.hasOwnProperty.call(yqkMemory,key)) return yqkMemory[key];
  var value;
  try { value = await Widget.storage.get("yqk.v2."+key); } catch (_) { return yqkMemory[key]; }
  if (value==null) return yqkMemory[key];
  if (typeof value==="string") { try { return JSON.parse(value); } catch (_) { return undefined; } }
  return value;
}
async function setStored(key, value) {
  yqkMemory[key]=value;
  if (/^(cursor|detail)\./.test(key)) {
    yqkMemoryOrder=yqkMemoryOrder.filter(function(k){return k!==key;});
    yqkMemoryOrder.push(key);
    while(yqkMemoryOrder.length>80) delete yqkMemory[yqkMemoryOrder.shift()];
  }
  try { await Widget.storage.set("yqk.v2."+key, JSON.stringify(value)); } catch (_) { /* Session cache still works. */ }
}
async function makeBody(params) {
  var body = Object.assign({}, params), udid = await runOnce("udid",async function(){
    var value=await getStored("udid");
    if (typeof value!=="string" || value.length<16) { value=randomId()+"-"+Date.now().toString(16); await setStored("udid",value); }
    return value;
  });
  Object.assign(body, { appId: YQK.appId, reqDomain: YQK.site.replace(/^https:\/\//,""), deviceInfo: "iPhone",
    version: YQK.version, requestId: randomId().replace(/-/g,""), cus1tom: "aabbcc", udid: udid });
  var text = Object.keys(body).sort().filter(function(k) { return body[k] !== ""; }).map(function(k) { return k+"="+body[k]+"&"; }).join("");
  body.sign = md5(text+"appKey="+YQK.appKey); return body;
}
function origin(url) { if (!/^https:\/\/[a-z0-9.-]+(?::\d+)?\/?$/i.test(url)) throw new Error("接口地址必须为 HTTPS 域名"); return url.replace(/\/$/,""); }
async function apiBases(force) {
  return runOnce("bases."+YQK.site+"."+YQK.apiOverride+"."+!!force,function(){return discoverBases(force);});
}
async function discoverBases(force) {
  if (YQK.apiOverride) return [origin(YQK.apiOverride)];
  var cached = await getStored("bases");
  if (!force && cached && Number.isFinite(cached.time) && Date.now()>=cached.time && Date.now()-cached.time<3600000 && Array.isArray(cached.urls) && cached.urls.length) {
    try { return cached.urls.map(origin); } catch (_) { /* Recover corrupt/stale configuration. */ }
  }
  try {
    var response = await Widget.http.get(YQK.site+"/js/baseUrlList.js", { headers: { Referer: YQK.site+"/" } });
    var match = String(response.data).match(/(?:var|let|const)\s+baseApiList\s*=\s*(\[[\s\S]*?\])/);
    if (match) {
      var parsed=JSON.parse(match[1]);
      if (!Array.isArray(parsed)) throw new Error("地址列表格式不正确");
      var urls=parsed.map(origin).filter(function(url,i,all){return all.indexOf(url)===i;});
      if (urls.length) {
        // Known healthy origins first; retain every newly discovered origin for failover.
        var ordered=YQK.fallbackBases.filter(function(b){return urls.indexOf(b)>=0;});
        ordered=ordered.concat(urls.filter(function(b){return ordered.indexOf(b)<0;}));
        await setStored("bases", { time: Date.now(), urls: ordered }); return ordered;
      }
    }
  } catch (_) { /* Fall back only to API origins observed in the site's public configuration. */ }
  return YQK.fallbackBases;
}
async function api(path, params) {
  return runOnce("api."+md5(YQK.site+YQK.apiOverride+path+JSON.stringify(params)),function(){return apiRequest(path,params);});
}
async function apiRequest(path, params) {
  var bases = await apiBases(), errors = [], preferred = await getStored("lastBase");
  if (bases.indexOf(preferred)>=0) bases=[preferred].concat(bases.filter(function(b){return b!==preferred;}));
  var tried={};
  // Do not discard working origins just because the first three are obsolete.
  // If the cached list is obsolete, refresh once and try only newly discovered origins.
  for (var phase=0;phase<(YQK.apiOverride?1:2);phase++) {
  if (phase===1) bases=await apiBases(true);
  for (var i=0; i<bases.length; i++) {
    if (tried[bases[i]]) continue; tried[bases[i]]=true;
    var response;
    try {
      response = await Widget.http.post(bases[i]+path, await makeBody(params), { headers: {
        "Content-Type": "application/json;charset=UTF-8", Referer: YQK.site+"/", Origin: YQK.site,
        "User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 Mobile/15E148"
      } });
    } catch (_) { errors.push("网络请求失败"); continue; }
    var status = response.statusCode || response.status;
    if (Number(status)===429) { var limited=new Error("请求过于频繁，请稍后重试。此时不会继续请求其他接口。");limited.code="RATE_LIMIT";throw limited; }
    if (status && status>=400) { errors.push("HTTP "+status); continue; }
    var payload = response.data;
    if (typeof payload === "string") {
      try { payload=JSON.parse(payload); } catch (_) { errors.push("返回 HTML 或非 JSON，接口可能不可用"); continue; }
    }
    if (!payload || typeof payload.result!=="boolean") { errors.push("响应缺少 result，协议不匹配"); continue; }
    if (!payload.result) throw new Error("网站拒绝请求（代码 "+String(payload.operateCode || "未知")+"）；请检查网站是否要求登录、签名是否已更新。未记录凭据或原始响应。");
    await setStored("lastBase",bases[i]); return payload.data;
  }
  }
  var reasons=errors.filter(function(reason,i,all){return all.indexOf(reason)===i;});
  throw new Error("一起看暂时无法连接（已尝试 "+errors.length+" 个接口）："+reasons.join("；")+"。请检查手机网络后重试，仍失败可稍后更新组件。");
}
function integer(value, label, allowZero) {
  if (!/^\d+$/.test(String(value))) throw new Error(label+"必须为数字");
  var n=Number(value); if (!Number.isSafeInteger(n) || n<(allowZero?0:1)) throw new Error(label+"无效"); return n;
}
function clean(text) { return String(text || "").replace(/<[^>]*>/g,"").trim(); }
function image(value) {
  if (!value) return "";
  if (/^https?:\/\//.test(value)) return value;
  if (/^\/\//.test(value)) return "https:"+value;
  if (/^\//.test(value)) return YQK.site+value;
  return "";
}
function normalize(raw, mediaType) {
  if (!raw || raw.vodId==null || !raw.vodName) throw new Error("影片数据缺少 vodId/vodName，需核对真实响应");
  var link=YQK.site+"/play/"+integer(raw.vodId,"影片 ID",false);
  var item={ id: link, type: "url", link: link, title: clean(raw.vodName), coverUrl: image(raw.coverImg),
    description: clean(raw.intro), genreTitle: clean(raw.flags), rating: raw.score==null?"":String(raw.score) };
  var flags=String(raw.flags||"");
  if (mediaType==="tv" || mediaType==="movie") item.mediaType=mediaType;
  else if (/剧|综艺|动漫/.test(flags)) item.mediaType="tv";
  else if (/片/.test(flags)) item.mediaType="movie";
  return item;
}
async function paged(path, filters, page, mediaType) {
  page=integer(page==null?1:page,"页码",false);
  if (page>YQK.maxPage) throw new Error("最多支持 30 页，避免游标失效时大量重放请求");
  var key="cursor."+md5(path+JSON.stringify(filters));
  return runOnce(key+".page."+page,function(){return serialize(key,function(){return pagedRequest(path,filters,page,mediaType,key);});});
}
async function pagedRequest(path, filters, page, mediaType, key) {
  var state=await getStored(key);
  if (page===1 || !state || !state.cursors || state.cursors[1]!=="" || !Number.isFinite(state.time) || Date.now()<state.time || Date.now()-state.time>600000) state={time:Date.now(),cursors:{1:""},end:0};
  // Storage can return the same object as memory: never mutate committed state.
  state=JSON.parse(JSON.stringify(state));
  if (state.end && page>state.end) return [];
  var start=page;
  while (start>1 && state.cursors[start]===undefined) start--;
  var data;
  for (var current=start; current<=page; current++) {
    data=await api(path,Object.assign({},filters,{nextVal:state.cursors[current],nextCount:YQK.pageSize}));
    if (!data || !Array.isArray(data.items)) throw new Error("列表响应缺少 data.items 数组");
    var items=data.items.map(function(item){return normalize(item,mediaType);});
    if (data.hasNext===true) {
      if (data.nextVal===undefined || data.nextVal===null || data.nextVal==="" || JSON.stringify(data.nextVal)===JSON.stringify(state.cursors[current])) throw new Error("分页游标缺失或未推进");
      for (var previous=1;previous<=current;previous++) {
        if (JSON.stringify(data.nextVal)===JSON.stringify(state.cursors[previous])) throw new Error("分页游标形成循环，请从第一页刷新");
      }
      if (JSON.stringify(state.cursors[current+1])!==JSON.stringify(data.nextVal)) {
        Object.keys(state.cursors).forEach(function(k){if(Number(k)>current) delete state.cursors[k];});
        state.end=0;
      }
      state.cursors[current+1]=data.nextVal;
    } else if (data.hasNext===false) {
      state.end=current;
      Object.keys(state.cursors).forEach(function(k){if(Number(k)>current) delete state.cursors[k];});
    }
    else throw new Error("列表响应缺少 hasNext 布尔字段");
    await setStored(key,state);
    if (state.end && current<page) return [];
  }
  return items;
}
async function search(params) {
  params=params||{}; var keyword=String(params.keyword||"").replace(/[\u200B-\u200D\uFEFF]/g,"").replace(/\s+/g," ").trim();
  // Clients also execute this module while building the landing page.
  // An unset input is an idle state, not an API failure.
  if (!keyword) return [];
  return paged("/v1/api/search/search",{keyword:keyword},params.page);
}
async function loadCategory(params) {
  params=params||{}; var parent=integer(params.parentChannelId==null?2:params.parentChannelId,"父分类 ID",false), child=params.childChannelId||"";
  if (child!=="") child=integer(child,"子分类 ID",false);
  return paged("/v2/api/channel/getVodList",{parentChannelId:parent,childChannelId:child},params.page,parent===2?"movie":"tv");
}
async function loadHome() {
  var data=await api("/v2/api/home/body",{}), items=[], seen={};
  if (!data || !Array.isArray(data.vodTopicList)) throw new Error("首页响应缺少 vodTopicList");
  data.vodTopicList.forEach(function(topic){(topic.vodList||[]).forEach(function(raw){
    if (seen[raw.vodId]) return; seen[raw.vodId]=true; items.push(normalize(raw));
  });});
  return items;
}
async function loadHotSearch(params) {
  var data=await api("/v1/api/search/getRankList",{channelId:integer((params||{}).channelId||0,"频道 ID",true)});
  if (!Array.isArray(data)) throw new Error("热搜榜响应应为 data 数组，需核对真实响应");
  return data.map(function(item){return normalize(item);});
}
function parseLink(link) {
  var prefix=YQK.site.replace(/[.*+?^${}()|[\]\\]/g,"\\$&");
  var match=String(link).match(new RegExp("^"+prefix+"/play/(\\d+)(?:\\?epId=(\\d+))?$"));
  if (!match) throw new Error("详情链接必须来自已配置的一起看网站");
  return {vodId:integer(match[1],"影片 ID",false),epId:match[2]?integer(match[2],"分集 ID",false):null};
}
async function getVodDetail(vodId, force) {
  return runOnce("detail."+vodId+"."+!!force,async function(){
    var key="detail."+vodId, cached=await getStored(key);
    if (!force && YQK.detailTTL>0 && cached && Number.isFinite(cached.time) && Date.now()>=cached.time && Date.now()-cached.time<YQK.detailTTL && cached.data && Number(cached.data.vodId)===vodId && cached.data.vodName && Array.isArray(cached.data.playerList)) return cached.data;
    var data=await api("/v2/api/vodInfo/index",{vodId:vodId});
    if (!data || Number(data.vodId)!==vodId || !data.vodName || !Array.isArray(data.playerList)) throw new Error("详情响应与影片不匹配或缺少线路列表");
    // Only cache metadata. In particular, never retain player.checkM3u8 signed URLs.
    var metadata={};
    ["vodId","vodName","coverImg","score","year","intro","flags"].forEach(function(k){if(data[k]!=null) metadata[k]=data[k];});
    metadata.playerList=data.playerList.filter(function(p){return p && typeof p==="object";}).map(function(p){
      var seen={};
      return {playerName:clean(p.playerName),remark:clean(p.remark),
      epList:Array.isArray(p.epList)?p.epList.filter(function(ep){
        var id=ep && Number(ep.epId);
        if (!ep || !/^\d+$/.test(String(ep.epId)) || !Number.isSafeInteger(id) || id<1 || seen[id]) return false;
        seen[id]=true;return true;
      }).map(function(ep,i){return {epId:Number(ep.epId),epName:clean(ep.epName)||"第 "+(i+1)+" 集",labelKnown:!!clean(ep.epName)};}):[]};});
    if (YQK.detailTTL>0) await setStored(key,{time:Date.now(),data:metadata});
    return metadata;
  });
}
function selectPlayer(detail, ids) {
  var players=detail.playerList.filter(function(p){return p && Array.isArray(p.epList) && p.epList.length;});
  var selected=ids.epId?players.find(function(p){return p.epList.some(function(ep){return Number(ep.epId)===ids.epId;});}):players[0];
  if (ids.epId && !selected) { var error=new Error("此分集不属于当前影片或已经下架，请重新打开影片详情"); error.code="EPISODE_MISMATCH";throw error; }
  return {players:players,selected:selected};
}
async function resolveDetail(ids) {
  var data=await getVodDetail(ids.vodId);
  try {return {data:data,selection:selectPlayer(data,ids)};}
  catch(error) {
    if(error.code!=="EPISODE_MISMATCH") throw error;
    // Recheck the source once before treating a cached episode mismatch as removal.
    data=await getVodDetail(ids.vodId,true);
    return {data:data,selection:selectPlayer(data,ids)};
  }
}
async function loadDetail(link) {
  var ids=parseLink(link), resolved=await resolveDetail(ids),data=resolved.data;
  var item=normalize(Object.assign({},data,{vodId:ids.vodId}));
  item.link=String(link); item.id=item.link;
  var selection=resolved.selection,players=selection.players,selected=selection.selected;
  if (selected && selected.epList.length>1) item.mediaType="tv";
  var episodes=[], seen={};
  // Keep one coherent episode list; alternate sources are separate child items.
  // Otherwise a 36-episode show with 18 sources appears as hundreds of episodes.
  (selected?selected.epList:[]).forEach(function(ep){
    if (ep.epId==null || seen[ep.epId]) return;
    seen[ep.epId]=true;
    var epLink=YQK.site+"/play/"+ids.vodId+"?epId="+integer(ep.epId,"分集 ID",false);
    episodes.push({id:epLink,type:"url",link:epLink,title:clean(ep.epName),coverUrl:item.coverUrl,
      mediaType:item.mediaType});
  });
  if (episodes.length) item.episodeItems=episodes;
  var sources=[], sourceSeen={};
  players.forEach(function(p){
    var sourceLink=YQK.site+"/play/"+ids.vodId+"?epId="+integer(p.epList[0].epId,"分集 ID",false);
    if (sourceSeen[sourceLink]) return; sourceSeen[sourceLink]=true;
    sources.push({id:sourceLink,type:"url",link:sourceLink,title:clean(p.playerName||"线路")+(p===selected?"（当前）":""),
      description:[p.epList.length+" 集",clean(p.remark)].filter(Boolean).join(" · "),coverUrl:item.coverUrl,mediaType:item.mediaType});
  });
  if (sources.length>1) item.childItems=sources;
  return item;
}
async function loadResource(params) {
  params=params||{}; var ids=parseLink(params.link||params.id), epId=ids.epId;
  var selection=(await resolveDetail(ids)).selection, player=selection.selected;
  if (!player) throw new Error("网站未返回分集资源");
  if (!epId) {
    epId=integer(player.epList[0].epId,"分集 ID",false);
  }
  var wanted=player.epList.find(function(ep){return Number(ep.epId)===epId;});
  var feature=player.epList.length===1 && wanted && wanted.labelKnown!==false && featureLabel(wanted.epName);
  var candidates=[{player:player,epId:epId}];
  selection.players.forEach(function(p){
    if(p===player) return;
    var ep=feature && p.epList.length===1 && p.epList[0].labelKnown!==false && featureLabel(p.epList[0].epName)?p.epList[0]:p.epList.find(function(ep){
      return wanted && wanted.labelKnown!==false && ep.labelKnown!==false && episodeKey(ep.epName) && episodeKey(ep.epName)===episodeKey(wanted.epName);
    });
    if(ep) candidates.push({player:p,epId:Number(ep.epId)});
  });
  var lastError,attempts=0;
  // At most four matching sources. Never guess a series episode from list position.
  for(var i=0;i<Math.min(candidates.length,4);i++) {
    attempts++;
    try {return await resourcesForEpisode(candidates[i].epId,candidates[i].player,i>0);}
    catch(error){if(error.code==="RATE_LIMIT") throw error;lastError=error;}
  }
  throw new Error("已尝试 "+attempts+" 条同片同集线路，暂时无法播放。"+(lastError?lastError.message:"")+" 请稍后刷新或在详情选择其他线路。");
}
function episodeKey(name) {
  var value=clean(name), match=value.match(/^(?:第\s*)?0*(\d+)\s*(?:集|话|期)?$/);
  return match?"episode."+Number(match[1]):value;
}
function featureLabel(name) {
  return /^(?:正片|HD|BD|DVD|高清|超清|标清|蓝光|1080P|720P|4K)(?:[ ._-]*(?:高清|超清|标清|1080P|720P|4K|国语|粤语|英语|中英|双语|中字|字幕))*$/i.test(clean(name));
}
async function resourcesForEpisode(epId, player, alternate) {
  var choices=await api("/v2/api/vodInfo/epDetail",{vodEpId:epId});
  if (!Array.isArray(choices)) throw new Error("清晰度响应应为数组");
  var playable=choices.filter(function(c){return c && c.canPlay===true;});
  if (!playable.length) throw new Error("网站没有允许当前访客播放的资源；本组件未实现账号登录");
  playable=playable.filter(function(c){return c.defaultSelect===true;}).concat(playable.filter(function(c){return c.defaultSelect!==true;}));
  var resolutions={};
  playable=playable.filter(function(c){var key=String(c.vodResolution);if(resolutions[key]) return false;resolutions[key]=true;return true;});
  var resources=[], failures=0;
  for (var i=0;i<Math.min(playable.length,4);i++) {
    try {
    var c=playable[i]; if (c.vodResolution==null) throw new Error("清晰度数据缺少 vodResolution 字段");
    var data=await api("/v2/api/vodInfo/playUrl",{vodResolution:c.vodResolution,epId:epId});
    if (!data || !/^https?:\/\//.test(data.playUrl||"")) throw new Error("网站未返回有效播放 URL");
    var headers={Referer:YQK.site+"/", "User-Agent":"Mozilla/5.0"};
    // Only read small HLS manifests; never download/probe MP4 or media segments.
    if (/\.m3u8(?:[?#]|$)/i.test(data.playUrl)) {
      var manifest=await Widget.http.get(data.playUrl,{headers:headers}), status=manifest.statusCode||manifest.status;
      if(Number(status)===429) {var limited=new Error("播放线路请求过于频繁，请稍后重试");limited.code="RATE_LIMIT";throw limited;}
      if((status && Number(status)>=400) || !/^\s*#EXTM3U/.test(String(manifest.data))) throw new Error("播放清单不可用");
    }
    var quality=clean(c.showName)||"清晰度 "+c.vodResolution, source=clean(player.playerName)||"线路";
    resources.push({name:(alternate?source+" · ":"")+quality,description:source,url:data.playUrl,playerType:"app",customHeaders:headers});
    } catch (error) {if(error.code==="RATE_LIMIT") throw error; failures++;}
  }
  if (!resources.length) throw new Error("当前访客可选的 "+failures+" 个清晰度均获取失败，请刷新或选择其他线路");
  return resources;
}
