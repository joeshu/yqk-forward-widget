// WeBox native ONE source, ported from ONE.js by YG. Site algorithms remain in this file.
WeBox.define({
 api:'1.1',id:'user.one',name:'ONE一个',version:'3.0.0',requires:['crypto'],
 cache:{list:120,detail:30,filters:3600},
 settings:{fields:[]},
 async filters(){return [{key:'category',label:'栏目',type:'select',default:'newest',options:[
  {label:'最新视频',value:'newest'},{label:'热门视频',value:'hot'},
  {label:'日本',value:'jp'},{label:'国产',value:'cn'},{label:'欧美',value:'us'},{label:'ONE 直播',value:'live'}]}];},
 async list(ctx,req){return oneClient(ctx).list(req);},
 async search(ctx,req){return oneClient(ctx).search(req);},
 async detail(ctx,req){return oneClient(ctx).detail(req);},
 async play(ctx,req){return oneClient(ctx).play(req);}
});
let oneRuntime;
function oneClient(ctx){
 const key=JSON.stringify([ctx.settings,ctx.cache?ctx.cache.generation:0]);
 if(!oneRuntime||oneRuntime.key!==key)oneRuntime={key,value:createOne(ctx)};
 return oneRuntime.value;
}
function createOne(ctx){
 function md5Hex(s){return ctx.crypto.md5(s);}
 function aesEncryptCbcBase64(k,iv,s){return ctx.crypto.aesEncrypt(s,k,iv,{inputEncoding:'utf8',outputEncoding:'base64'});}
 function aesDecryptCbc(k,iv,s){return ctx.crypto.aesDecrypt(s,k,iv,{inputEncoding:'base64',outputEncoding:'utf8'});}
var APP_KEY = "l*bv%Ziq000Biaog";
var APP_IV = "8597506002939249";
var SIGN_SALT = "m4n2hjPeYWkD6tFpqKF^3HO^h24P@idT";
var APP_VERSION = "1.6.0";
var UA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36";
var SEED_HOSTS = [
  "https://api.2b37894.com",
  "https://api.35a46dd.com",
  "https://api.43b8477.com",
  "https://api.5ce3771.com",
  "https://api.61c76a0.com",
  "https://api.632d809.com",
  "https://api.3459381.com",
  "https://api.em1oifd0.com",
  "https://api.j7y675.com"
];
var SES_KEY = "one:session:v2";
var S = null;          // 运行时会话

function clean(s) {
  return String(s === null || s === undefined ? "" : s)
    .replace(/<[^>]*>/g, " ")
    .replace(/&nbsp;/g, " ")
    .replace(/&amp;/g, "&")
    .replace(/&quot;/g, '"')
    .replace(/&#39;/g, "'")
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">")
    .replace(/\s+/g, " ")
    .trim();
}
function pick() {
  for (var i = 0; i < arguments.length; i++) {
    var v = arguments[i];
    if (v !== undefined && v !== null && String(v).trim() !== "") return v;
  }
  return "";
}
function encQuery(params) {
  if (!params) return "";
  var parts = [];
  var keys = Object.keys(params);
  for (var i = 0; i < keys.length; i++) {
    var k = keys[i];
    var v = params[k];
    if (v === undefined || v === null || v === "") continue;
    parts.push(encodeURIComponent(k) + "=" + encodeURIComponent(String(v)));
  }
  return parts.join("&");
}
function todayStr() {
  var d = new Date();
  var p = function (n) { return (n < 10 ? "0" : "") + n; };
  return d.getFullYear() + "-" + p(d.getMonth() + 1) + "-" + p(d.getDate());
}
function makeUuid() {
  var hex = [];
  for (var i = 0; i < 32; i++) hex.push("0123456789abcdef".charAt(Math.floor(Math.random() * 16)));
  var s = hex.join("");
  return s.slice(0, 8) + "-" + s.slice(8, 12) + "-4" + s.slice(13, 16) + "-a" + s.slice(17, 20) + "-" + s.slice(20, 32);
}
var PLAIN_HOSTS = ["https://imgpw807.s7n7ue8.com", "https://imgpw807.2u7qzt7.com",
  "https://img807.hkq57tt.com", "https://imgsu807.hkq57tt.com"];
var ENC_HOSTS = ["gdliren123.com", "u3wwetf.com", "m6qzbb4.com", "bdsy56.com", "gzjsqx.com", "k8b3rsp.com"];
var BAD_HOSTS = ["imgsu807.hkq57tt.com"];
function imgHosts() {
  var list = [];
  function add(arr) {
    if (!arr) return;
    for (var i = 0; i < arr.length; i++) {
      var h = String(arr[i] || "").replace(/\/+$/, "");
      if (!h || list.indexOf(h) >= 0) continue;
      if (hostIsBad(h)) continue;
      list.push(h);
    }
  }
  if (S) { add(S.fimg); add(S.resource); }
  add(PLAIN_HOSTS);
  return list;
}
function pathOf(url) {
  var m = String(url || "").match(/^https?:\/\/[^\/]+(\/.*)$/);
  return m ? m[1] : String(url || "");
}
function pickImgHost(p) {
  var hosts = imgHosts();
  if (!hosts.length) return "https://img807.hkq57tt.com";
  var h = 0;
  for (var i = 0; i < p.length; i++) h = (h * 31 + p.charCodeAt(i)) >>> 0;
  return hosts[h % hosts.length];
}
function absImage(path) {
  if (!path) return "";
  var p = String(path);
  if (/^https?:\/\//.test(p)) {
    for (var i = 0; i < ENC_HOSTS.length; i++) {
      if (p.indexOf(ENC_HOSTS[i]) >= 0) return pickImgHost(pathOf(p)) + pathOf(p);
    }
    return p;
  }
  return pickImgHost(p) + (p.charAt(0) === "/" ? "" : "/") + p;
}

function usableImage(url) {
  return !!url;
}
var IMG_PROXY = "https://wsrv.nl/?url=";
function gifToJpeg(url) {
  if (!/\.gif(\?|$)/i.test(String(url))) return url;
  return IMG_PROXY + encodeURIComponent(url) + "&output=jpg&w=520";
}
function fillCovers(items) {
  for (var i = 0; i < items.length; i++) {
    var it = items[i];
    if (it && it.posterPath && /\.gif(\?|$)/i.test(it.posterPath)) withImages(it, gifToJpeg(it.posterPath));
  }
  return items;
}
function bestImage(a) {
  if (!a) return "";
  var cands = [a.thumbnail, a.thumb, a.video_cover, a.cover, a.thumb_tiny];
  if (a.multi_pic_thumbnail && a.multi_pic_thumbnail.length) cands = cands.concat(a.multi_pic_thumbnail);
  if (a.thumbnail_list && a.thumbnail_list.length) cands = cands.concat(a.thumbnail_list);
  var gif = "";
  for (var i = 0; i < cands.length; i++) {
    var u = absImage(cands[i]);
    if (!usableImage(u)) continue;
    if (/\.gif(\?|$)/i.test(u)) { if (!gif) gif = u; continue; }
    return u;
  }
  return gif ? gifToJpeg(gif) : "";
}
function absVideo(path, kind) {
  if (!path) return "";
  var p = String(path);
  if (/^https?:\/\//.test(p)) return p;
  var hosts = kind === "hls" ? (S && S.video_hls) : kind === "audio" ? (S && S.audio) : (S && S.video);
  if (!hosts || !hosts.length) hosts = ["https://46e9nz.mfpt8g.com"];
  return hosts[0] + (p.charAt(0) === "/" ? "" : "/") + p;
}
function withImages(item,url){if(url)item.posterPath=gifToJpeg(url);return item;}
function stripLiveTag(title) {
  var t = String(title || "");
  var m = t.match(/^\[(ONE\s*直播[^\]]*)\]\s*/i);
  if (!m) return { title: t, live: false };
  return { title: t.slice(m[0].length).trim(), live: true };
}
function sizeLabel(v) {
  var t = String(v == null ? "" : v).trim();
  if (!t) return "";
  return /^\d+(\.\d+)?\s*(KB|MB|GB|TB)$/i.test(t) ? t : "";
}
function durationSeconds(a) {
  if (!a) return 0;
  var vl = parseInt(a.video_length, 10) || 0;
  if (vl > 0) return vl;
  var len = String(a.length || a.duration || "").trim();
  if (!len) return 0;
  var hms = len.match(/^(\d{1,2}):(\d{2})(?::(\d{2}))?$/);
  if (hms) {
    return hms[3] ? (+hms[1]) * 3600 + (+hms[2]) * 60 + (+hms[3]) : (+hms[1]) * 60 + (+hms[2]);
  }
  var mins = len.match(/(\d+(?:\.\d+)?)\s*(?:分钟|分|min)/i);
  if (mins) return Math.round(parseFloat(mins[1]) * 60);
  var hrs = len.match(/(\d+(?:\.\d+)?)\s*(?:小时|h)/i);
  if (hrs) return Math.round(parseFloat(hrs[1]) * 3600);
  var secs = len.match(/(\d+)\s*(?:秒|s)$/i);
  if (secs) return parseInt(secs[1], 10);
  return 0;
}
function secondsToText(sec) {
  var s = parseInt(sec, 10) || 0;
  if (s <= 0) return "";
  var h = Math.floor(s / 3600), m = Math.floor((s % 3600) / 60), ss = s % 60;
  var p = function (n) { return (n < 10 ? "0" : "") + n; };
  return h > 0 ? h + ":" + p(m) + ":" + p(ss) : m + ":" + p(ss);
}

async function loadSession() {
  if (S) return S;
  var raw = null;
  try { raw = await ctx.store.get(SES_KEY); } catch (e) { raw = null; }
  if (typeof raw === "string" && raw) {
    try {
      var saved = JSON.parse(raw);
      if (saved && saved.token) { S = saved; return S; }
    } catch (e) {}
  }
  S = { uuid: makeUuid(), host: "", token: "", api: [], image: [], resource: [], fimg: [], video: [], video_hls: [], audio: [], vplay: [], vdl: [], audl: [], ts: 0 };
  return S;
}
var savedSessionText='';
async function saveSession(){const text=JSON.stringify(S);if(text!==savedSessionText){await ctx.store.set(SES_KEY,text);savedSessionText=text;}}
function applyDomains(domain) {
  if (!domain) return;
  if (domain.api && domain.api.length) S.api = domain.api.slice();
  if (domain.image && domain.image.length) S.image = domain.image.slice();
  if (domain.resource && domain.resource.length) S.resource = domain.resource.slice();
  if (domain.flutter_img && domain.flutter_img.length) S.fimg = domain.flutter_img.slice();
  if (domain.video && domain.video.length) S.video = domain.video.slice();
  if (domain.video_hls && domain.video_hls.length) S.video_hls = domain.video_hls.slice();
  if (domain.audio && domain.audio.length) S.audio = domain.audio.slice();
  if (domain.flutter_video_play && domain.flutter_video_play.length) S.vplay = domain.flutter_video_play.slice();
  if (domain.flutter_video_download && domain.flutter_video_download.length) S.vdl = domain.flutter_video_download.slice();
  if (domain.audio_download && domain.audio_download.length) S.audl = domain.audio_download.slice();
}
function hostCandidates() {
  var list = [];
  if (S && S.host) list.push(S.host);
  if (S && S.api) for (var i = 0; i < S.api.length; i++) if (list.indexOf(S.api[i]) < 0) list.push(S.api[i]);
  for (var j = 0; j < SEED_HOSTS.length; j++) if (list.indexOf(SEED_HOSTS[j]) < 0) list.push(SEED_HOSTS[j]);
  return list;
}
function buildHeaders(token) {
  var ts = Math.floor(Date.now() / 1000);
  var sign = md5Hex(md5Hex("0.0.0.0.3." + ts + ".." + S.uuid) + SIGN_SALT);
  return {
    "platform": "3",
    "uuid": S.uuid,
    "timestamp": String(ts),
    "token": token === undefined ? (S.token || "") : token,
    "app-version": APP_VERSION,
    "sign": sign,
    "user-key": "",
    "ip": "0.0.0.0",
    "User-Agent": UA,
    "Accept": "*/*",
    "Content-Type": "application/x-www-form-urlencoded"
  };
}
function parsePayload(text) {
  if (text === null || text === undefined) return null;
  var str = typeof text === "string" ? text : JSON.stringify(text);
  str = str.trim();
  if (!str) return null;
  if (str.charAt(0) === "{") {
    try { return JSON.parse(str); } catch (e) { return null; }
  }
  var plain = "";
  try { plain = aesDecryptCbc(APP_KEY, APP_IV, str); } catch (e) { plain = ""; }
  if (!plain) return null;
  try { return JSON.parse(plain); } catch (e) { return null; }
}
async function postRaw(host, path, params, token) {
  var body = "";
  var qs = encQuery(params);
  if (qs) body = aesEncryptCbcBase64(APP_KEY, APP_IV, qs);
  var url = host + "/v2.5/" + path;
  var resp = await ctx.http.post(url,{text:body,headers:buildHeaders(token),responseType:'text',timeoutMs:path==='bootstrap'?4000:12000});
  var text = resp && (resp.data !== undefined ? resp.data : resp);
  return parsePayload(text);
}
async function call(path,params,opts){
 await loadSession();let refreshed=false;
 for(;;){let last=null;
  for(const host of hostCandidates()){
   ctx.signal.throwIfAborted();let data;
   try{data=await postRaw(host,path,params,opts&&opts.tokenOverride);}
   catch(e){ctx.signal.throwIfAborted();last=e;continue;}
   if(!data){last=Error('ONE 响应无法解析');continue;}
   if(Number(data.code)===200){if(S.host!==host){S.host=host;await saveSession();}return data.data;}
   if(Number(data.code)===401){last=Error('认证失效');break;}
   if([403,450].includes(Number(data.code)))ctx.fail('AUTH_REQUIRED','当前账号没有此内容的访问权限');
   ctx.fail('INVALID_RESPONSE','ONE 接口返回错误（'+String(data.code)+')');
  }
  if(last&&last.message==='认证失效'&&!refreshed){refreshed=true;await bootstrap(true);continue;}
  ctx.signal.throwIfAborted();ctx.fail('NETWORK','ONE 暂时无法响应，请稍后重试');
 }
}
async function bootstrap(force){await loadSession();if(!force&&S.token&&S.host)return S;return await doBootstrap();}
async function doBootstrap() {
  var hosts = hostCandidates();
  var lastErr = null;
  for (var i = 0; i < hosts.length; i++) {
    try {
      var json = await postRaw(hosts[i], "bootstrap", null, "");
      if (json && json.code === 200 && json.data) {
        var user = json.data.user || {};
        S.host = hosts[i];
        S.token = user.token || "";
        applyDomains(json.data.domain);
        S.ts = Date.now();
        await saveSession();
        return S;
      }
      lastErr = new Error("bootstrap " + (json && json.code));
    } catch (e) { lastErr = e; }
  }
  throw lastErr || new Error("ONE 初始化失败");
}

function modelName(mid) {
  var m = parseInt(mid, 10);
  if (m === 1) return "图集";
  if (m === 2) return "视频";
  if (m === 3) return "视频";
  if (m === 4) return "图文";
  if (m === 5) return "音频";
  if (m === 6) return "长视频";
  return "内容";
}
function articleLink(id) { return "one://a/" + id; }
function seriesLink(kind, id) { return "one://s/" + kind + "/" + id; }
function actorLink(id) { return "one://p/" + id; }
function tagLink(id, title) { return "one://t/" + id + "/" + encodeURIComponent(String(title || "")); }

var VIDEO_MODELS = [6, 3];
var TILE_TAGS = [1, 2, 3];
var PARTITIONS = [
  { id: "jp", tag: 2, title: "日本" },
  { id: "cn", tag: 3, title: "国产" },
  { id: "us", tag: 1, title: "欧美" },
  { id: "live", tag: 4, title: "ONE 直播" }
];
var PCOVER = {};

function partitionById(pid) {
  var key = String(pid || "").toLowerCase();
  for (var i = 0; i < PARTITIONS.length; i++) {
    if (PARTITIONS[i].id === key) return PARTITIONS[i];
  }
  return null;
}
function partitionByTag(tag) {
  var t = parseInt(tag, 10);
  for (var i = 0; i < PARTITIONS.length; i++) {
    if (PARTITIONS[i].tag === t) return PARTITIONS[i];
  }
  return null;
}
function monthStart(offset) {
  var d = new Date();
  d.setDate(1);
  d.setMonth(d.getMonth() - (parseInt(offset, 10) || 0));
  var m = d.getMonth() + 1;
  return d.getFullYear() + "-" + (m < 10 ? "0" + m : "" + m) + "-01";
}
function monthLabel(offset) {
  var d = new Date();
  d.setDate(1);
  d.setMonth(d.getMonth() - (parseInt(offset, 10) || 0));
  return d.getFullYear() + "年" + (d.getMonth() + 1) + "月";
}

var TAG_US = /^(欧美|美国|英国|德国|法国|意大利|西班牙|荷兰|瑞典|瑞士|奥地利|波兰|捷克|匈牙利|罗马尼亚|保加利亚|俄罗斯|乌克兰|白俄罗斯|拉脱维亚|立陶宛|爱沙尼亚|巴西|墨西哥|阿根廷|哥伦比亚|秘鲁|智利|古巴|委内瑞拉|拉美|拉丁|加拿大|澳洲|澳大利亚|新西兰|印度|泰国|越南|菲律宾|印尼|马来西亚|阿拉伯|异域|土耳其|迪拜|以色列|伊朗|黑人|金发|白人|碧眼|西方|外国|欧美无码|欧美精品)$/;
var TAG_JP = /^(日本|日系|日韩|日本无码|日本精品)$/;
var TAG_CN = /^(国产|国语|华语|国产精品|国产无码|港台|台湾|香港|新加坡)$/;
function tagList(a) {
  var arr = (a && a.tags) || [];
  var out = [];
  for (var i = 0; i < arr.length; i++) {
    var t = arr[i];
    var v = typeof t === "string" ? t : (t && (t.slug || t.name || t.title || t.tag_name)) || "";
    v = String(v).replace(/\s+/g, " ").trim();
    if (v) out.push(v);
  }
  return out;
}
function regionByTags(a) {
  var tags = tagList(a);
  var us = 0;
  var jp = 0;
  var cn = 0;
  for (var i = 0; i < tags.length; i++) {
    var t = tags[i];
    if (TAG_US.test(t)) us++;
    else if (TAG_JP.test(t)) jp++;
    else if (TAG_CN.test(t)) cn++;
  }
  if (us && us >= jp && us >= cn) return "us";
  if (jp && jp >= cn) return "jp";
  if (cn) return "cn";
  return "";
}
function classifyByText(a) {
  var title = String(pick(a.title, a.video_name, "") || "");
  var t = title + " " + String(a.author || "");
  var low = t.toLowerCase();
  if (/[\u3040-\u30ff]/.test(t)) return "jp";
  if (/(p站|pornhub|onlyfans|fansly|faphouse|pjgirls|deeper|tushy|vixen|blacked|brazzers|realitykings|naught(y|iamerica)|bangbros|teamskeet|mylf|chaturbate|cb站|推特|x站|洋马|白人|金发|碧眼|欧美|美国|英国|德国|法国|俄罗斯|乌克兰|巴西|拉美|拉丁|大洋马|洋妞|老外|外国|bbc|bwc|尼哥|黑大炮|捷克|西班牙|意大利|加拿大|澳洲|印度|泰国|越南|菲律宾|印尼|马来西亚|阿拉伯|异域|土耳其|迪拜|以色列|韩国|韩系|波兰|匈牙利|罗马尼亚|latina|ebony|russian|blonde)/i.test(low)) return "us";
  if (/\b[a-z]{2,5}[-_]\d{2,5}\b/.test(low)) return "jp";
  if (/(无码|有码|人妻|女优|痴女|素人|日系|日本|和服|风俗|fc2|heyzo|jav|myfans|oppai|s1|sod|falen|moodyz|prestige|ideapocket|ipx|ssni|miaa|madonna|ダスッ|カリビアン|加勒比|一本道|天然むすめ|tokyo\s*hot|10musume|heydouga|无修正|中文字幕|熟女|女教师|痴汉|电车|东京|大阪|温泉)/i.test(t)) return "jp";
  if (/(ai短剧|短剧|探花|门事件|绿播|福利姬|网红|主播|大秀|微密圈|抖音|快手|b站|私拍|旗袍|学生妹|御姐|大圈|传媒|天美|麻豆|星空|糖心|91|抖阴|杏吧|蜜桃|精东|国产|国语|华语|coser|cosplay|推特福利|私人订制|定制合集)/i.test(t)) return "cn";
  var cjk = (t.match(/[\u3400-\u9fff]/g) || []).length;
  var lat = (t.match(/[a-z]/gi) || []).length;
  if (lat > cjk * 1.5 && lat > 6) return "us";
  return "cn";
}
var STRONG_US = /(p站|onlyfans|fansly|faphouse|pjgirls|deeper|tushy|vixen|blacked|brazzers|realitykings|bangbros|teamskeet|mylf|chaturbate|cb站|推特|fansone|manyvids)/i;
var STRONG_CN = /(ai短剧|短剧|探花|门事件|绿播|微密圈|抖音|快手|b站|91|抖阴|杏吧|麻豆|天美|糖心|精东|国语|华语|国产精品)/i;
function classifyPart(a) {
  var title = String(pick(a.title, a.video_name, "") || "");
  if (title.indexOf("[ONE直播") >= 0) return "live";
  if (/直播回放/.test(title) && /one直播/i.test(title)) return "live";
  if (STRONG_US.test(title)) return "us";
  if (STRONG_CN.test(title)) return "cn";
  if (/[\u3040-\u30ff]/.test(title)) return "jp";
  if (/\b[a-z]{2,5}[-_]\d{2,5}\b/i.test(title)) return "jp";
  var byTag = regionByTags(a);
  if (byTag) return byTag;
  return classifyByText(a);
}

var MONTH_CACHE = {};
var PART_CACHE = {};
var MONTH_TTL = 2 * 60 * 1000;
var MONTH_TTL_OLD = 12 * 60 * 60 * 1000;
var ONE_PAGE_SIZE = 24;
var ONE_PAGES = {};
var ONE_PAGE_CACHE_BYTES = 0;
var ONE_PAGE_CACHE_LIMIT = 4 * 1024 * 1024;
function compactCatalogArticle(a) {
  var out = {};
  var keys = ["id", "model_id", "title", "video_name", "author", "published_at", "views", "like_number",
    "description", "subtitle", "video_length", "length", "duration", "size",
    "thumbnail", "thumb", "video_cover", "cover", "thumb_tiny", "multi_pic_thumbnail", "thumbnail_list",
    "video_download", "video_file", "preview_video"];
  for (var i = 0; i < keys.length; i++) if (a[keys[i]] !== undefined) out[keys[i]] = a[keys[i]];
  out.tags = tagList(a);
  return out;
}
function trimCatalogPages() {
  var keys = Object.keys(ONE_PAGES).filter(function (key) { return ONE_PAGES[key].bytes !== undefined; });
  keys.sort(function (a, b) { return ONE_PAGES[a].used - ONE_PAGES[b].used; });
  while (ONE_PAGE_CACHE_BYTES > ONE_PAGE_CACHE_LIMIT && keys.length) {
    var key = keys.shift();
    ONE_PAGE_CACHE_BYTES -= ONE_PAGES[key].bytes;
    delete ONE_PAGES[key];
  }
}
function monthTtl(offset) {
  return (parseInt(offset, 10) || 0) <= 1 ? MONTH_TTL : MONTH_TTL_OLD;
}
async function fetchMonthPage(model, offset, page, size, sortMode) {
  await bootstrap(false);
  var arr = await call("article/discovery", {
    model_id: model, published_at: monthStart(offset), page: page,
    size: size, sort: sortMode || "published_at"
  });
  if (arr == null) return [];
  if (!Array.isArray(arr)) throw new Error("ONE 目录返回格式不正确，请重试");
  return arr.map(compactCatalogArticle);
}
async function cachedMonthPage(model,offset,page,sortMode){
 const key=monthStart(offset)+':'+model+':'+sortMode+':'+page,ttl=ctx.cache?ctx.cache.seconds(monthTtl(offset)/1000)*1000:monthTtl(offset);
 const entry=ONE_PAGES[key];if(ttl>0&&entry&&Date.now()-entry.ts<ttl)return entry.rows;
 const rows=await fetchMonthPage(model,offset,page,ONE_PAGE_SIZE,sortMode);
 if(ttl>0){const rec={rows,ts:Date.now(),used:Date.now(),bytes:JSON.stringify(rows).length*2};if(entry)ONE_PAGE_CACHE_BYTES-=entry.bytes;ONE_PAGES[key]=rec;ONE_PAGE_CACHE_BYTES+=rec.bytes;trimCatalogPages();}
 return rows;
}
function articleOrder(a, b, sortMode) {
  if (sortMode === "like_number") return (parseInt(b.like_number, 10) || 0) - (parseInt(a.like_number, 10) || 0);
  return String(b.published_at || "").localeCompare(String(a.published_at || ""));
}
function monthCursor(offset, sortMode) {
  return { offset: offset, sort: sortMode, streams: VIDEO_MODELS.map(function (model) {
    return { model: model, page: 1, queue: [], at: 0, done: false, previous: "" };
  }) };
}
async function nextMonthArticle(cursor) {
  var missing = cursor.streams.filter(function (stream) { return !stream.done && stream.at >= stream.queue.length; });
  var pages = await Promise.all(missing.map(function (stream) {
    return cachedMonthPage(stream.model, cursor.offset, stream.page, cursor.sort);
  }));
  for (var check = 0; check < missing.length; check++) {
    var signature = JSON.stringify(pages[check].map(function (item) { return String(item.id); }));
    if (pages[check].length && missing[check].previous === signature) throw new Error("ONE 接口重复返回同一页，请稍后重试");
  }
  for (var i = 0; i < missing.length; i++) {
    var stream = missing[i], raw = pages[i];
    stream.previous = JSON.stringify(raw.map(function (item) { return String(item.id); }));
    stream.queue = raw.slice().sort(function (a, b) { return articleOrder(a, b, cursor.sort); });
    stream.at = 0;
    stream.page++;
    stream.done = raw.length === 0;
  }
  var chosen = null;
  cursor.streams.forEach(function (stream) {
    if (stream.at < stream.queue.length && (!chosen || articleOrder(stream.queue[stream.at], chosen.queue[chosen.at], cursor.sort) < 0)) chosen = stream;
  });
  return chosen ? chosen.queue[chosen.at++] : null;
}
async function completeMonth(offset, sortMode) {
  var cursor = monthCursor(offset, sortMode), result = [], seen = {};
  while (true) {
    var article = await nextMonthArticle(cursor);
    if (!article) break;
    var key = String(article.id);
    if (!seen[key] && !isPreviewOnly(article)) { seen[key] = true; result.push(article); }
  }
  return result;
}
async function monthFeed(offset) { return await completeMonth(offset, "published_at"); }
async function partitionFeed(part, offset) {
  return (await monthFeed(offset)).filter(function (article) { return classifyPart(article) === part.id; });
}

async function liveItems(part,page,size){
 const rows=await call('article/search',{keyword:'ONE直播',model_id:0,series_category:0,page,size});
 if(!Array.isArray(rows))ctx.fail('INVALID_RESPONSE','回放目录格式无效');
 return fillCovers(rows.map(a=>articleItem(a)));
}
function freshFeed(previous, start, sortMode, page) {
  var stamp = monthStart(0), now = Date.now();
  if (previous && page > 1) {
    if (previous.stamp !== stamp) {
      var old = previous.stamp.split("-"), current = stamp.split("-");
      var shift = (parseInt(current[0], 10) - parseInt(old[0], 10)) * 12 + parseInt(current[1], 10) - parseInt(old[1], 10);
      previous.off += shift;
      if (previous.cursor) previous.cursor.offset += shift;
      previous.stamp = stamp;
    }
    return previous;
  }
  if (previous && previous.stamp === stamp && now - previous.ts < (ctx.cache?ctx.cache.seconds(MONTH_TTL/1000)*1000:MONTH_TTL)) return previous;
  return { items: [], seen: {}, off: start || 0, emptyRun: 0, done: false, cover: "",
    cursor: null, monthFound: 0, stamp: stamp, ts: now, sort: sortMode };
}
async function feedPage(state, page, size, part) {
  var need = page * size;
  while (state.items.length < need && !state.done && state.off < 400) {
    if (!state.cursor) state.cursor = monthCursor(state.off, state.sort);
    var article = await nextMonthArticle(state.cursor);
    if (!article) {
      state.emptyRun = state.monthFound ? 0 : state.emptyRun + 1;
      state.monthFound = 0;
      state.off++;
      state.cursor = null;
      if (state.emptyRun >= 8) state.done = true;
      continue;
    }
    state.monthFound++;
    if (part && classifyPart(article) !== part.id) continue;
    var key = String(article.id);
    if (state.seen[key]) continue;
    var cover = bestImage(article);
    if (!state.cover && cover) { state.cover = cover; if (part) PCOVER[part.id] = cover; }
    var item = articleItem(article, part ? state.cover : "");
    item.description = monthLabel(state.off) + (state.sort === "like_number" ? " 热门" : "") + " · " + item.description;
    state.seen[key] = true;
    state.items.push(item);
  }
  return fillCovers(state.items.slice((page - 1) * size, page * size));
}
async function readFeedPage(state,page,size,part){return await feedPage(state,page,size,part);}
var PALL = {};
async function regionItems(part, page, size, startOff) {
  await bootstrap(false);
  var start = Math.max(0, parseInt(startOff, 10) || 0);
  var key = part.id + ":" + start;
  PALL[key] = freshFeed(PALL[key], start, "published_at", page);
  return await readFeedPage(PALL[key], page, size, part);
}
async function partitionItems(part, page, size, startOff) {
  page = Math.max(1, parseInt(page, 10) || 1);
  size = Math.max(4, parseInt(size, 10) || 24);
  if (part.id === "live") return await liveItems(part, page, size);
  return await regionItems(part, page, size, startOff);
}
var NEWEST = null;
async function newestItems(page, size) {
  await bootstrap(false);
  NEWEST = freshFeed(NEWEST, 0, "published_at", page);
  return await readFeedPage(NEWEST, page, size, null);
}
var HOTMONTH = {};
var HOT_TTL = 30 * 60 * 1000;
async function hotMonth(offset) { return await completeMonth(offset, "like_number"); }
var HOT = null;
async function hotItems(page, size) {
  await bootstrap(false);
  HOT = freshFeed(HOT, 0, "like_number", page);
  return await readFeedPage(HOT, page, size, null);
}
async function partitionCover(part) { return PCOVER[part.id] || ""; }


function articleItem(a, fallbackCover) {
  var id = a.id;
  var cover = bestImage(a) || (fallbackCover || "");
  var liveInfo = stripLiveTag(clean(pick(a.title, a.video_name, "ONE #" + id)));
  var title = liveInfo.title;
  var bits = [];
  bits.push(liveInfo.live ? "直播回放" : modelName(a.model_id));
  if (a.author) bits.push(clean(a.author));
  if (a.published_at) bits.push(String(a.published_at).slice(0, 10));
  if (a.views) bits.push("观看 " + a.views);
  if (a.like_number) bits.push("赞 " + a.like_number);
  var item = {
    id: String(id),
    type: "detail",
    mediaType: "movie",
    title: title,
    link: articleLink(id),
    description: bits.join(" · "),
    duration: 0,
    overview: clean(pick(a.description, a.subtitle))
  };
  var sec = durationSeconds(a);
  if (sec > 0) { item.duration = sec; item.durationText = secondsToText(sec); }
  if (sizeLabel(a.size)) bits.push(sizeLabel(a.size));
  item.description = bits.join(" · ");
  return withImages(item, cover);
}
function isPreviewOnly(a) {
  if (!a) return true;
  if (String(a.video_download || "")) return false;
  var file = String(a.video_file || "");
  if (!file) {
    if (!String(a.preview_video || "")) return false;
    return true;
  }
  if (String(a.preview_video || "") === file) return true;
  if (/preview|sample|_pr\.mp4|-pr\.mp4/i.test(file)) return true;
  return false;
}
function hostIsBad(h) {
  for (var i = 0; i < BAD_HOSTS.length; i++) if (String(h).indexOf(BAD_HOSTS[i]) >= 0) return true;
  return false;
}
function videoHosts() {
  var list = [];
  function add(arr) {
    if (!arr) return;
    for (var i = 0; i < arr.length; i++) {
      var h = String(arr[i] || "").replace(/\/+$/, "");
      if (!h || list.indexOf(h) >= 0 || hostIsBad(h)) continue;
      list.push(h);
    }
  }
  if (S) { add(S.video); add(S.vdl); add(S.vplay); add(S.audl); add(S.audio); }
  if (!list.length) list = ["https://46e9nz.mfpt8g.com", "https://f86xxm.upmf83.com"];
  return list;
}
function videoLines(a) {
  var lines = [];
  var hosts = videoHosts();
  function pushMp4(path, label, desc) {
    if (!path) return;
    var p = String(path);
    for (var i = 0; i < hosts.length && i < (/^https?:\/\//.test(p)?1:5); i++) {
      var url = /^https?:\/\//.test(p) ? p : hosts[i] + (p.charAt(0) === "/" ? "" : "/") + p;
      lines.push({
        name: label + " · 线路 " + (i + 1) + (/h265/i.test(p) ? "（H.265）" : ""),
        description: desc,
        url: url
      });
    }
  }
  var previewOnly = isPreviewOnly(a);
  pushMp4(a.video_download, "MP4", "ONE 直连 · 支持拖动");
  if (!previewOnly && a.video_file && String(a.video_file) !== String(a.video_download || "")) {
    pushMp4(a.video_file, "MP4", "ONE 直连 · 支持拖动");
  } else if (previewOnly) {
    pushMp4(a.video_file, "预告 MP4", "ONE 直连 · 预告片（非完整版）");
  }
  if (!lines.length || previewOnly) {
    if (a.video_hls) {
      lines.push({ name: "HLS 备用", description: "ONE HLS · 加密清单，可能无法直接播放", url: absVideo(a.video_hls, "hls") });
    }
    if (a.video_hls_h265) {
      lines.push({ name: "HLS H.265 备用", description: "ONE HLS · 加密清单，可能无法直接播放", url: absVideo(a.video_hls_h265, "hls") });
    }
  }
  if (a.audio_file) {
    lines.push({ name: "音频", description: "ONE FM", url: absVideo(a.audio_file, "audio") });
  }
  if (a.audio_hls) {
    lines.push({ name: "音频 HLS", description: "ONE FM · HLS", url: absVideo(a.audio_hls, "hls") });
  }
  if (!lines.length && a.preview_video) {
    lines.push({ name: "预览", description: "ONE 预览片段", url: absVideo(a.preview_video) });
  }
  return lines;
}
 function numeric(value){if(typeof value!=='string'||!/^\d+$/.test(value))ctx.fail('NOT_FOUND','内容标识无效');return value;}
 function number(cursor){if(cursor===null)return 1;if(typeof cursor!=='string'||!/^\d+$/.test(cursor)||!Number.isSafeInteger(Number(cursor))||Number(cursor)<1)ctx.fail('INVALID_RESPONSE','分页游标无效');return Number(cursor);}
 function resetPages(){ONE_PAGES={};ONE_PAGE_CACHE_BYTES=0;NEWEST=null;HOT=null;PALL={};}
 function card(x){numeric(String(x.id));return {id:String(x.id),title:clean(x.title),kind:'unknown',poster:x.posterPath||'',subtitle:x.description||''};}
 async function list(req){
  const page=number(req.cursor),category=req.filters.category||'newest';if(req.refresh||(page===1&&ctx.cache&&ctx.cache.seconds(120)===0))resetPages();await bootstrap(false);
  const rows=category==='newest'?await newestItems(page,24):category==='hot'?await hotItems(page,24):await partitionItems(partitionById(category)||ctx.fail('INVALID_RESPONSE','分类无效'),page,24);
  return {items:rows.map(card),nextCursor:rows.length===24?String(page+1):null};
 }
 async function search(req){
  const q=String(req.query||'').trim();if(!q)return {items:[],nextCursor:null};await bootstrap(false);
  const page=number(req.cursor),rows=await call('article/search',{keyword:q,model_id:0,series_category:0,page,size:24});
  if(!Array.isArray(rows))ctx.fail('INVALID_RESPONSE','搜索格式无效');
  return {items:rows.map(a=>card(articleItem(a))),nextCursor:rows.length===24?String(page+1):null};
 }
 async function article(id){numeric(id);await bootstrap(false);const a=await call('article/detail',{id});if(!a||typeof a!=='object'||Array.isArray(a))ctx.fail('NOT_FOUND','内容不存在');return a;}
 function episodes(a){
  if(Array.isArray(a.collection_list)&&a.collection_list.length){const seen=new Set();return a.collection_list.map(ep=>{
   const id=numeric(String(ep.id));if(seen.has(id))ctx.fail('INVALID_RESPONSE','选集标识重复');seen.add(id);
   return {id,name:clean(ep.video_name||ep.title)||'第 '+String(ep.episode||seen.size)+' 场'};
  });}
  return videoLines(a).length?[{id:numeric(String(a.id)),name:isPreviewOnly(a)?'预览':'正片'}]:[];
 }
 async function detail(req){const id=numeric(req.id),a=await article(id),eps=episodes(a);
  return {id,...(stripLiveTag(clean(a.title||a.video_name)).title?{title:stripLiveTag(clean(a.title||a.video_name)).title}:{}),kind:eps.length>1?'series':'unknown',poster:bestImage(a),summary:clean(a.description||a.video_name),groups:eps.length?[{id:'main',name:'播放',episodes:eps}]:[]};
 }
 async function play(req){
  if(req.groupId!=='main')ctx.fail('NOT_FOUND','线路已变化');const parent=await article(numeric(req.contentId)),eps=episodes(parent);
  if(!eps.some(e=>e.id===req.episodeId))ctx.fail('NOT_FOUND','选集已变化，请重新打开详情');
  const a=req.episodeId===req.contentId?parent:await article(numeric(req.episodeId));
  const seen=new Set(),lines=videoLines(a).filter(l=>{if(seen.has(l.url))return false;seen.add(l.url);return true;});
  if(lines.length&&lines.every(l=>/\/encry\//i.test(l.url)))ctx.fail('UNSUPPORTED','此内容仅返回加密清单，暂未提供标准播放线路');
  return {sources:lines.filter(l=>! /\/encry\//i.test(l.url)).map(l=>({id:ctx.crypto.md5(l.name.replace(/ · 线路 \d+/,'')+'|'+ctx.url.origin(l.url)),name:l.name,url:l.url,mime:/\.m3u8(?:$|[?#])/i.test(l.url)?'application/vnd.apple.mpegurl':/音频/.test(l.name)?'audio/mpeg':'video/mp4'}))};
 }
 return {list,search,detail,play};
}
