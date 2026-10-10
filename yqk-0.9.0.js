var WidgetMetadata = {
  id: "joeshu.yqk", title: "一起看", author: "joeshu",
  description: "首页精选、电影/电视剧/动漫/综艺、搜索、热搜、分集与访客播放资源。",
  site: "https://m.yqk3hxe.com", version: "0.9.0", requiredVersion: "0.0.1",
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

// Names and IDs verified against the site's public category responses.
var YqkCategories = [
  {id:2,title:"电影",children:[[9,"科幻片"],[4,"动作片"],[12,"爱情片"],[13,"喜剧片"],[14,"恐怖片"],[27,"灾难片"],[15,"惊悚片"],[16,"剧情片"],[17,"冒险片"],[18,"战争片"],[19,"伦理片"],[20,"纪录片"],[21,"悬疑片"],[22,"动画片"],[23,"犯罪片"],[24,"奇幻片"],[25,"武侠片"],[26,"邵氏电影"]]},
  {id:3,title:"电视剧",children:[[11,"国产剧"],[38,"欧美剧"],[39,"韩国剧"],[40,"日本剧"],[41,"香港剧"],[42,"台湾剧"],[43,"泰国剧"],[44,"海外剧"]]},
  {id:8,title:"动漫",children:[[45,"国产动漫"],[46,"日韩动漫"],[47,"欧美动漫"],[48,"港台动漫"],[49,"海外动漫"]]},
  {id:10,title:"综艺",children:[[31,"大陆综艺"],[32,"日韩综艺"],[33,"港台综艺"],[34,"欧美综艺"]]},
  {id:50,title:"短剧",children:[[57,"最新短剧"]]}
];
var YqkTopics = [[93,"每日推荐"],[77,"抖音推荐电影"],[95,"抖音推荐电视剧"],[82,"48小时飙升榜"],[2,"爱优腾芒"],[20,"下饭短剧"],[74,"经典TVB剧"],[10,"美剧热播"],[76,"毒舌电影"],[58,"网络电影"],[52,"爆笑喜剧"],[6,"胆小误入"],[7,"拳拳到肉"],[48,"韩国高分电影"],[53,"情投意合"],[70,"刺激战场"],[81,"十年经典"],[75,"怀旧剧场"],[19,"悬疑剧场"],[45,"男人减速带"],[72,"热播日剧"],[57,"港片名导"],[44,"好莱坞影视"],[43,"梦幻迪士尼"],[42,"DC世界"],[40,"漫威宇宙"],[39,"灾难降临"]];
function topicOptions() {return YqkTopics.map(function(t){return {title:t[1],value:String(t[0])};});}
var homeModule=WidgetMetadata.modules[0];
homeModule.title="每日推荐";
homeModule.params=[{name:"topicId",title:"推荐专题",type:"enumeration",value:"93",enumOptions:[{title:"全部首页精选",value:"all"}].concat(topicOptions())}];
var categoryModules=YqkCategories.filter(function(c){return c.id!==50;}).map(function(c){return {
  id:"channel"+c.id,title:c.title,functionName:"loadCategory",cacheDuration:0,
  params:[{name:"parentChannelId",title:"频道",type:"constant",value:String(c.id)},
    {name:"childChannelId",title:"类型 / 地区",type:"enumeration",value:"",enumOptions:[{title:"全部",value:""}].concat(c.children.map(function(t){return {title:t[1],value:String(t[0])};}))},
    {name:"page",title:"页码",type:"page",value:"1"}]
};});
var oldModules=WidgetMetadata.modules;
WidgetMetadata.modules=[homeModule,oldModules[3]].concat(categoryModules,[
  {id:"shortDrama",title:"短剧",description:"原站下饭短剧专题",functionName:"loadTopic",cacheDuration:300,params:[{name:"topicId",title:"专题",type:"constant",value:"20"},{name:"page",title:"页码",type:"page",value:"1"}]},
  {id:"netflix",title:"奈飞 Netflix",functionName:"loadCollection",cacheDuration:300,params:[{name:"channelId",title:"频道",type:"constant",value:"65"},{name:"collection",title:"片单",type:"enumeration",value:"latest",enumOptions:[{title:"最新月份",value:"latest"},{title:"TOP100",value:"top100"}]},{name:"page",title:"页码",type:"page",value:"1"}]},
  {id:"korean",title:"高清韩剧",functionName:"loadCollection",cacheDuration:300,params:[{name:"channelId",title:"频道",type:"constant",value:"56"},{name:"collection",title:"片单",type:"enumeration",value:"latest",enumOptions:[{title:"新剧秒播",value:"latest"},{title:"热播 TOP100",value:"top100"},{title:"甜蜜清新",value:"60"},{title:"鬼怪来袭",value:"66"},{title:"层层迷雾",value:"62"},{title:"经典必看",value:"65"},{title:"家族那些事",value:"61"},{title:"宫廷之争",value:"64"}]},{name:"page",title:"页码",type:"page",value:"1"}]},
  {id:"topics",title:"专题片单",functionName:"loadTopic",cacheDuration:300,params:[{name:"topicId",title:"专题",type:"enumeration",value:"2",enumOptions:topicOptions()},{name:"page",title:"页码",type:"page",value:"1"}]},
  oldModules[1],oldModules[2],oldModules[4]
]);
WidgetMetadata.modules[WidgetMetadata.modules.length-1].params=[{name:"qualityPreference",title:"画质优先级",type:"enumeration",value:"highest",enumOptions:[{title:"最高画质（自适应）",value:"highest"},{title:"清晰优先（固定高画质）",value:"fixed"},{title:"站点默认",value:"default"}]}];
var yqkChannelOptions=[{title:"电影",value:"2"},{title:"电视剧",value:"3"},{title:"动漫",value:"8"},{title:"综艺",value:"10"},{title:"短剧",value:"50"},{title:"Netflix",value:"65"},{title:"高清韩剧",value:"56"}];
function yqkMenu(name,title,values,value){return {name:name,title:title,type:"enumeration",value:value||"",enumOptions:values.map(function(v){return {title:v[1],value:v[0]};})};}
var yqkFilterParams=[{name:"channelId",title:"频道",type:"enumeration",value:"2",enumOptions:yqkChannelOptions},
 yqkMenu("genre","题材",[["","全部"],["剧情","剧情"],["喜剧","喜剧"],["动作","动作"],["爱情","爱情"],["悬疑","悬疑"],["科幻","科幻"],["动画","动画"],["奇幻","奇幻"],["战争","战争"],["纪录片","纪录片"],["真人秀","真人秀"],["脱口秀","脱口秀"]]),
 yqkMenu("area","地区",[["","全部"],["大陆","大陆"],["美国","美国"],["韩国","韩国"],["香港","香港"],["日本","日本"],["台湾","台湾"],["英国","英国"],["泰国","泰国"],["印度","印度"],["其他","其他"]]),
 yqkMenu("year","年份",[["","全部"],["current","当年"],["previous","上一年"],["previous2","前两年"],["previous3","前三年"],["older","更早"]]),
 yqkMenu("sortType","排序",[["1","最新"],["2","人气"],["3","评分"],["4","热搜"]],"1"),{name:"page",title:"页码",type:"page",value:"1"}];
WidgetMetadata.modules.unshift({id:"latest",title:"最新片单",description:"按原站最新排序，非首映日期承诺；每分钟刷新。",functionName:"loadLatest",cacheDuration:60,params:[yqkFilterParams[0],yqkFilterParams[3],yqkFilterParams[5]]},
 {id:"filters",title:"多条件筛选",description:"题材、地区、年份组合筛选；题材编号随频道实时匹配。",functionName:"loadFiltered",cacheDuration:60,params:yqkFilterParams});
WidgetMetadata.modules.forEach(function(m){if(m.cacheDuration===300)m.cacheDuration=60;});
WidgetMetadata.modules.find(function(m){return m.id==="loadResource";}).params.push(
 yqkMenu("lineMode","线路模式",[["auto","自动回退"],["multiple","检查多条备用"],["manual","只用所选线路"]],"auto"),
 yqkMenu("sourceLimit","最大尝试线路",[["4","4 条（较快）"],["8","8 条（推荐）"],["12","12 条（更多回退）"]],"8"),
 {name:"checkBudget",title:"线路检查预算",description:"默认15秒，可选8/15/30秒；到时停止后续检查。当前请求的超时由客户端控制，可能超过此预算。",type:"enumeration",value:"15",enumOptions:[{title:"8秒（较快）",value:"8"},{title:"15秒（推荐）",value:"15"},{title:"30秒（更多检查）",value:"30"}]} );

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
async function api(path, params, budget) {
  if(budget)return apiRequest(path,params,budget);
  return runOnce("api."+md5(YQK.site+YQK.apiOverride+path+JSON.stringify(params)),function(){return apiRequest(path,params);});
}
async function apiRequest(path, params, budget) {
  var bases = await apiBases(), errors = [], preferred = await getStored("lastBase");
  if (bases.indexOf(preferred)>=0) bases=[preferred].concat(bases.filter(function(b){return b!==preferred;}));
  var tried={};
  // Do not discard working origins just because the first three are obsolete.
  // If the cached list is obsolete, refresh once and try only newly discovered origins.
  for (var phase=0;phase<(YQK.apiOverride?1:2);phase++) {
  yqkBudgetCheck(budget);
  if (phase===1) bases=await apiBases(true);
  for (var i=0; i<bases.length; i++) {
    yqkBudgetCheck(budget);
    if (tried[bases[i]]) continue; tried[bases[i]]=true;
    var response;
    try {
      var body=await makeBody(params);yqkBudgetCheck(budget);
      response = await Widget.http.post(bases[i]+path, body, { headers: {
        "Content-Type": "application/json;charset=UTF-8", Referer: YQK.site+"/", Origin: YQK.site,
        "User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 Mobile/15E148"
      } });
    } catch (error) { if(error.code==="PLAYBACK_BUDGET")throw error;errors.push("网络请求失败"); continue; }
    var status = response.statusCode || response.status;
    if (Number(status)===429) { var limited=new Error("请求过于频繁，请稍后重试。此时不会继续请求其他接口。");limited.code="RATE_LIMIT";throw limited; }
    yqkBudgetCheck(budget);
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
    description: [clean(raw.intro),clean(raw.flags),clean(raw.remark),clean(raw.watchingCountDesc)].filter(Boolean).join(" · "), genreTitle: clean(raw.flags), rating: raw.score==null||Number(raw.score)===0?"":String(raw.score) };
  item.posterPath=item.coverUrl;
  var year=String(raw.year||raw.flags||"").match(/(?:^|\s)(\d{4})(?:$|\s|\/)/);
  if(year) item.releaseDate=year[1];
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
  var category=YqkCategories.find(function(c){return c.id===parent;});
  if(!category || child!==""&&!category.children.some(function(c){return c[0]===child;})) throw new Error("子分类不属于所选频道，请重新选择分类");
  return paged("/v2/api/channel/getVodList",{parentChannelId:parent,childChannelId:child},params.page,parent===2?"movie":"tv");
}
async function yqkFilters(channel) {
  return runOnce("filters."+channel,async function(){
    var key="filters."+channel,stored=await getStored(key);
    if(stored&&stored.time<=Date.now()&&Date.now()-stored.time<600000&&stored.data&&Array.isArray(stored.data.filterList)&&Array.isArray(stored.data.sortList))return stored.data;
    var data=await api("/v1/api/search/getSearchFilter",{channelId:channel});
    if(!data||!Array.isArray(data.filterList)||!Array.isArray(data.sortList))throw new Error("筛选目录格式已变化，请稍后刷新");
    await setStored(key,{time:Date.now(),data:data});return data;
  });
}
async function loadFiltered(params) {
  params=params||{};var channel=integer(params.channelId==null?2:params.channelId,"频道 ID",false);
  if(!yqkChannelOptions.some(function(c){return Number(c.value)===channel;}))throw new Error("频道选择无效");
  var catalog=await yqkFilters(channel),queries=[{filerName:"channelId",filerValue:String(channel)}];
  function select(field,value,byName){
    if(!value)return;
    var list=catalog.filterList.find(function(f){return f.filterName===field;}),choice=list&&(list.filterValueList||[]).find(function(v){return String(byName?v.name:v.id)===String(value);});
    if(!choice)throw new Error("当前频道不支持所选"+({channelChildTypeId:"题材",areaId:"地区",year:"年份"}[field]||field)+"，请改选全部");
    queries.push({filerName:field,filerValue:String(choice.id)});
  }
  select("channelChildTypeId",params.genre,true);select("areaId",params.area,true);
  var year=params.year||"",now=new Date(Date.now()+8*3600000).getUTCFullYear();
  if(["current","previous","previous2","previous3"].indexOf(year)>=0){var offset={current:0,previous:1,previous2:2,previous3:3}[year];year=(now-offset)+"-"+(now-offset);}
  if(year==="older"){
    var years=catalog.filterList.find(function(f){return f.filterName==="year";});
    var older=years&&(years.filterValueList||[]).find(function(v){return /^\d{4}-\d{4}$/.test(v.id)&&Number(v.id.split("-")[0])<Number(v.id.split("-")[1]);});
    if(!older)throw new Error("原站暂无更早年份筛选，请改选全部");year=older.id;
  }
  select("year",year,false);var sort=integer(params.sortType==null?1:params.sortType,"排序",false);
  if(!catalog.sortList.some(function(s){return Number(s.sortType)===sort;}))throw new Error("原站不支持所选排序");
  return paged("/v1/api/search/queryNow",{queryValueJson:JSON.stringify(queries),sortType:sort},params.page,channel===2?"movie":channel===3||channel===8||channel===10||channel===50||channel===56?"tv":undefined);
}
async function loadLatest(params){return loadFiltered(Object.assign({},params,{sortType:1}));}
async function loadHome(params) {
  var data=await api("/v2/api/home/body",{}), items=[], seen={};
  if (!data || !Array.isArray(data.vodTopicList)) throw new Error("首页响应缺少 vodTopicList");
  var topicId=(params||{}).topicId;
  data.vodTopicList.forEach(function(topic){
    if(topicId && topicId!=="all" && String(topic.vodTopicId)!==String(topicId)) return;
    (topic.vodList||[]).forEach(function(raw){
    if (seen[raw.vodId]) return; seen[raw.vodId]=true; items.push(normalize(raw));
  });});
  return items;
}
async function loadTopic(params) {
  params=params||{};
  var page=integer(params.page==null?1:params.page,"页码",false);
  if(page>YQK.maxPage) throw new Error("最多支持 30 页");
  var data=await api("/v1/api/vodTopic/getVodList",{vodTopicId:integer(params.topicId==null?2:params.topicId,"专题 ID",false),pageIndex:page,pageSize:18});
  if(!data || !Array.isArray(data.items)) throw new Error("专题响应缺少 items");
  return data.items.map(function(raw){return normalize(raw);});
}
async function loadCollection(params) {
  params=params||{};
  var data=await api("/v2/api/channel/topicListView",{channelId:integer(params.channelId==null?65:params.channelId,"频道 ID",false)});
  if(!data || !Array.isArray(data.topicList)) throw new Error("频道响应缺少 topicList");
  var selected=data.topicList.find(function(t){return /^\d+$/.test(String(params.collection))?String(t.vodTopicId)===String(params.collection):params.collection==="top100"?/TOP100/i.test(t.topicName):!/TOP100/i.test(t.topicName);});
  if(!selected) return [];
  return loadTopic({topicId:selected.vodTopicId,page:params.page});
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
async function getVodDetail(vodId, force, budget) {
  var task=async function(){
    var key="detail."+vodId, cached=await getStored(key);
    yqkBudgetCheck(budget);
    if (!force && YQK.detailTTL>0 && cached && Number.isFinite(cached.time) && Date.now()>=cached.time && Date.now()-cached.time<YQK.detailTTL && cached.data && Number(cached.data.vodId)===vodId && cached.data.vodName && Array.isArray(cached.data.playerList)) return cached.data;
    var data=await api("/v2/api/vodInfo/index",{vodId:vodId},budget);yqkBudgetCheck(budget);
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
  };return budget?task():runOnce("detail."+vodId+"."+!!force,task);
}
function selectPlayer(detail, ids) {
  var players=detail.playerList.filter(function(p){return p && Array.isArray(p.epList) && p.epList.length;});
  var selected=ids.epId?players.find(function(p){return p.epList.some(function(ep){return Number(ep.epId)===ids.epId;});}):players[0];
  if (ids.epId && !selected) { var error=new Error("此分集不属于当前影片或已经下架，请重新打开影片详情"); error.code="EPISODE_MISMATCH";throw error; }
  return {players:players,selected:selected};
}
async function resolveDetail(ids, budget) {
  var data=await getVodDetail(ids.vodId,false,budget);
  try {return {data:data,selection:selectPlayer(data,ids)};}
  catch(error) {
    if(error.code!=="EPISODE_MISMATCH") throw error;
    // Recheck the source once before treating a cached episode mismatch as removal.
    data=await getVodDetail(ids.vodId,true,budget);
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
  var seconds=Number(params.checkBudget==null?15:params.checkBudget);if([8,15,30].indexOf(seconds)<0)throw new Error("线路检查预算无效");
  var budget={deadline:Date.now()+seconds*1000,seconds:seconds};
  var selection=(await resolveDetail(ids,budget)).selection, player=selection.selected;
  yqkBudgetCheck(budget);
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
  var mode=params.lineMode||"auto",limit=Number(params.sourceLimit||8);
  if(["auto","multiple","manual"].indexOf(mode)<0||[4,8,12].indexOf(limit)<0)throw new Error("线路选项无效");
  if(mode==="manual")candidates=candidates.slice(0,1);
  var hint=yqkLineHints[ids.vodId],recent=hint&&hint.time<=Date.now()&&Date.now()-hint.time<600000;
  // Honor explicit source selection. On root links reuse only the source identity,
  // not a signed URL. The matching episode and manifests are checked every time.
  if(recent&&mode!=="manual")candidates=candidates.map(function(c,i){return {c:c,i:i};}).sort(function(a,b){
    if(ids.epId&&(a.i===0||b.i===0))return a.i-b.i;
    return Number(b.c.player.epList[0].epId===hint.source)-Number(a.c.player.epList[0].epId===hint.source)||a.i-b.i;
  }).map(function(x){return x.c;});
  var lastError,attempts=0,found=[],cooled=0,budgetStopped=false;
  // Bound retries; never infer a series episode from list position.
  for(var i=0;i<candidates.length&&attempts<limit;i++) {
    if(Date.now()>=budget.deadline){budgetStopped=true;break;}
    var failureKey=ids.vodId+"|"+candidates[i].player.epList[0].epId+"|"+(wanted&&wanted.labelKnown!==false?episodeKey(wanted.epName):epId);
    if(mode!=="manual"&&!(ids.epId&&candidates[i].player===player)&&yqkLineCooling(failureKey)){cooled++;continue;}
    attempts++;
    try {
      var resources=await resourcesForEpisode(candidates[i].epId,candidates[i].player,candidates[i].player!==player||mode==="multiple",params.qualityPreference,budget);
      delete yqkLineFailures[failureKey];
      if(!found.length){yqkLineHints[ids.vodId]={time:Date.now(),source:candidates[i].player.epList[0].epId};var keys=Object.keys(yqkLineHints).sort(function(a,b){return yqkLineHints[b].time-yqkLineHints[a].time;});keys.slice(30).forEach(function(k){delete yqkLineHints[k];});}
      if(mode!=="multiple")return resources;
      if(!found.some(function(r){return r.url===resources[0].url;}))found.push(resources[0]);
      if(found.length===3)return found;
    }
    catch(error){if(error.code==="RATE_LIMIT") throw error;if(error.code==="PLAYBACK_BUDGET"){budgetStopped=true;break;}yqkRememberFailure(failureKey,error);lastError=error;}
  }
  if(found.length)return found;
  throw new Error("已尝试 "+attempts+" 条同片同集线路，暂时无法播放。"+(budgetStopped?"已达到 "+seconds+" 秒检查预算，停止后续请求。":"")+(cooled?"跳过 "+cooled+" 条近期失败线路；可用“只用所选线路”立即重试。":"")+(lastError?lastError.message:"")+" 请稍后刷新或在详情选择其他线路。");
}
var yqkLineHints={},yqkLineFailures={};
function yqkBudgetCheck(budget){if(budget&&Date.now()>=budget.deadline){var error=new Error("已达到 "+budget.seconds+" 秒线路检查预算，停止后续请求；当前请求超时由客户端控制");error.code="PLAYBACK_BUDGET";throw error;}}
function yqkLineCooling(key){var record=yqkLineFailures[key],now=Date.now();if(!record)return false;if(record.time>now||record.until<=now){delete yqkLineFailures[key];return false;}return true;}
function yqkRememberFailure(key,error){
 var reason=error.lineFailureReason,ttl=reason==="http404"?300000:reason==="http403"?120000:reason==="timeout"?60000:0;if(!ttl)return;
 var now=Date.now();yqkLineFailures[key]={time:now,until:now+ttl,reason:reason};
 var keys=Object.keys(yqkLineFailures).sort(function(a,b){return yqkLineFailures[b].time-yqkLineFailures[a].time;});keys.slice(200).forEach(function(k){delete yqkLineFailures[k];});
}
function yqkRelative(base,ref){
  if(/^https?:\/\//i.test(ref))return ref;if(/^\/\//.test(ref))return base.split(":")[0]+":"+ref;
  if(/^[a-z][a-z\d+.-]*:/i.test(ref))throw new Error("播放清单地址无效");
  var m=base.match(/^(https?:\/\/[^/]+)(\/[^?#]*)?/i);if(!m)throw new Error("播放清单地址无效");
  if(/^\?/.test(ref))return m[1]+(m[2]||"/")+ref;
  var path=ref.charAt(0)==="/"?ref:(m[2]||"/").replace(/[^/]*$/,"")+ref,parts=[];
  path.split("/").forEach(function(p){if(p==="..")parts.pop();else if(p!==".")parts.push(p);});return m[1]+parts.join("/");
}
async function yqkProbeHls(url,headers,budget,preference,info){var reads=0,seen={};info=info||{};
  async function read(url,depth,keepMaster){
    yqkBudgetCheck(budget);
    if(depth>=3||reads>=5||seen[url])throw new Error("播放清单检查达到上限");seen[url]=true;reads++;
    var r;try{r=await Widget.http.get(url,{headers:headers});}catch(error){if(/^(?:ETIMEDOUT|ESOCKETTIMEDOUT|ECONNABORTED|TIMEOUT)$/.test(error.code||'')||error.name==='TimeoutError')error.lineFailureReason='timeout';throw error;}
    var status=Number(r.statusCode||r.status);
    if(status===429){var limited=new Error("播放线路请求过于频繁，请稍后重试");limited.code="RATE_LIMIT";throw limited;}
    yqkBudgetCheck(budget);
    if(status!==200||typeof r.data!=="string"||r.data.length>1024*1024||!/^\s*#EXTM3U/.test(r.data)){var invalid=new Error("播放清单不可用");if(status===403||status===404)invalid.lineFailureReason='http'+status;throw invalid;}
    var lines=r.data.split(/\r?\n/).map(function(l){return l.trim();});
    if(!/#EXT-X-STREAM-INF:/.test(r.data)){
      if(!/#EXTINF:/.test(r.data)||!lines.some(function(l){return l&&l.charAt(0)!=="#";}))throw new Error("播放清单为空");
      // Keep a working master URL: separate audio/subtitle renditions may be linked there.
      return url;
    }
    var variants=[],external=/(?:[:,])(?:AUDIO|SUBTITLES|VIDEO|CLOSED-CAPTIONS)=(?!NONE(?:,|\r?\n|$))/.test(r.data);
    for(var i=0;i<lines.length;i++)if(/^#EXT-X-STREAM-INF:/.test(lines[i])){
      var res=lines[i].match(/RESOLUTION=(\d+)x(\d+)/),bw=lines[i].match(/(?:[:,])BANDWIDTH=(\d+)/);
      for(var j=i+1;j<lines.length;j++){if(/^#EXT-X-STREAM-INF:/.test(lines[j]))break;if(lines[j]&&lines[j][0]!=="#"){variants.push({url:yqkRelative(url,lines[j]),width:res?Number(res[1]):0,height:res?Number(res[2]):0,pixels:res?Number(res[1])*Number(res[2]):0,bw:bw?Number(bw[1]):0});break;}}
    }
    variants.sort(function(a,b){return b.pixels-a.pixels||b.bw-a.bw;});
    var variantError;
    for(var v=0;v<Math.min(variants.length,2);v++)try{
      var checked=await read(variants[v].url,depth+1,keepMaster||external);
      // RESOLUTION is a playlist declaration, not a measurement of decoded video.
      if(depth===0){info.width=variants[v].width;info.height=variants[v].height;info.bandwidth=variants[v].bw;}
      if(v===0&&checked===variants[v].url){
        if(preference==="fixed"&&!keepMaster&&!external&&!info.retainedRenditions){info.fixed=true;return checked;}
        if(preference==="fixed")info.retainedRenditions=true;
        return url;
      }
      if(external||keepMaster)throw new Error("备用子清单有独立音轨或字幕，请改用其他画质或线路");
      if(preference==="fixed"&&!info.retainedRenditions)info.fixed=true;
      return checked;
    }catch(e){if(e.code==="RATE_LIMIT"||e.code==="PLAYBACK_BUDGET")throw e;variantError=e;}
    var failed=new Error("子清单暂不可用");if(variantError)failed.lineFailureReason=variantError.lineFailureReason;throw failed;
  }return read(url,0,false);
}
function episodeKey(name) {
  var value=clean(name), match=value.match(/^(?:第\s*)?0*(\d+)\s*(?:集|话|期)?$/);
  return match?"episode."+Number(match[1]):value;
}
function featureLabel(name) {
  return /^(?:正片|HD|BD|DVD|高清|超清|标清|蓝光|1080P|720P|4K)(?:[ ._-]*(?:高清|超清|标清|1080P|720P|4K|国语|粤语|英语|中英|双语|中字|字幕))*$/i.test(clean(name));
}
function qualityRank(choice) {
  var name=clean(choice.showName).toUpperCase();
  if(/8K|4320/.test(name)) return 4320;
  if(/4K|2160|UHD/.test(name)) return 2160;
  var pixels=name.match(/(?:^|\D)(1080|720|480|360|240)(?:P|\D|$)/);
  if(pixels) return Number(pixels[1]);
  if(/蓝光|超清/.test(name)) return 1000;
  if(/高清/.test(name)) return 700;
  if(/标清/.test(name)) return 400;
  if(/流畅/.test(name)) return 200;
  return 0;
}
async function resourcesForEpisode(epId, player, alternate, preference, budget) {
  if(preference&&["highest","fixed","default"].indexOf(preference)<0)throw new Error("画质选项无效");
  yqkBudgetCheck(budget);
  var choices=await api("/v2/api/vodInfo/epDetail",{vodEpId:epId},budget);yqkBudgetCheck(budget);
  if (!Array.isArray(choices)) throw new Error("清晰度响应应为数组");
  var playable=choices.filter(function(c){return c && c.canPlay===true;});
  if (!playable.length) throw new Error("网站没有允许当前访客播放的资源；本组件未实现账号登录");
  playable=playable.filter(function(c){return c.defaultSelect===true;}).concat(playable.filter(function(c){return c.defaultSelect!==true;}));
  // Only rank the site's labels; resolution IDs are opaque, not pixel counts.
  if(preference!=="default") playable=playable.map(function(c,index){return {choice:c,index:index};}).sort(function(a,b){return qualityRank(b.choice)-qualityRank(a.choice)||a.index-b.index;}).map(function(x){return x.choice;});
  var resolutions={};
  playable=playable.filter(function(c){var key=String(c.vodResolution);if(resolutions[key]) return false;resolutions[key]=true;return true;});
  var resources=[], failures=0,lastFailure;
  for (var i=0;i<Math.min(playable.length,4);i++) {
    try {
    yqkBudgetCheck(budget);
    var c=playable[i]; if (c.vodResolution==null) throw new Error("清晰度数据缺少 vodResolution 字段");
    var data=await api("/v2/api/vodInfo/playUrl",{vodResolution:c.vodResolution,epId:epId},budget);yqkBudgetCheck(budget);
    if (!data || !/^https?:\/\//.test(data.playUrl||"")) throw new Error("网站未返回有效播放 URL");
    var headers={Referer:YQK.site+"/", "User-Agent":"Mozilla/5.0"},hlsInfo={};
    // Only read small HLS manifests; never download/probe MP4 or media segments.
    if (/\.m3u8(?:[?#]|$)/i.test(data.playUrl)) {
      data.playUrl=await yqkProbeHls(data.playUrl,headers,budget,preference,hlsInfo);
    }
    var quality=clean(c.showName)||"清晰度 "+c.vodResolution, source=clean(player.playerName)||"线路";
    if(hlsInfo.width&&hlsInfo.height)quality+=" · 清单 "+hlsInfo.width+"×"+hlsInfo.height;
    if(hlsInfo.fixed)quality+=" · 固定";
    else if(hlsInfo.retainedRenditions)quality+=" · 自适应（保留音轨/字幕）";
    resources.push({name:(alternate?source+" · ":"")+quality,description:source,url:data.playUrl,playerType:"app",customHeaders:headers});
    } catch (error) {if(error.code==="RATE_LIMIT") throw error;if(error.code==="PLAYBACK_BUDGET"){if(resources.length)return resources;throw error;}lastFailure=error;failures++;}
  }
  if (!resources.length){var error=new Error("当前访客可选的 "+failures+" 个清晰度均获取失败，请刷新或选择其他线路");if(lastFailure)error.lineFailureReason=lastFailure.lineFailureReason;throw error;}
  return resources;
}
