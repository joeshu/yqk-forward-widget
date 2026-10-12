import * as referenceBuiltin11 from 'zlib';
import * as referenceBuiltin10 from 'url';
import * as referenceBuiltin9 from 'node:zlib';
import * as referenceBuiltin8 from 'node:stream';
import * as referenceBuiltin7 from 'node:path';
import * as referenceBuiltin6 from 'node:https';
import * as referenceBuiltin5 from 'node:http';
import * as referenceBuiltin4 from 'node:fs';
import * as referenceBuiltin3 from 'node:crypto';
import * as referenceBuiltin2 from 'node:buffer';
import * as referenceBuiltin1 from 'https';
import * as referenceBuiltin0 from 'crypto';
// Adapted selected non-cloud factories from https://9280.kstore.vip/cat/index.js, MD5 0e89531f459dc4bb6f6abbbbf7392493.
import {t0,P0,Me,b0,u0,l0,E0,Ei,zn,xa,U} from './support.js';
const C0=x=>({...x,default:x});
const H=(f,c)=>()=>{if(!c){c={exports:{}};f(c.exports,c);}return c.exports;};
const Qe=(f,v)=>()=>{if(f){const g=f;f=null;v=g();}return v;};
function Lc(e9 = {}) {
  return { ...e9 };
}
function Qa(e9 = {}) {
  return u0({ ...e9, tag: "folder" });
}
var Rn0 = C0(referenceBuiltin5, 1);
var Cn0 = C0(referenceBuiltin6, 1);
var uTt = t0.create({ httpAgent: new Rn0.default.Agent({ keepAlive: true }), httpsAgent: new Cn0.default.Agent({ keepAlive: true, rejectUnauthorized: true }), timeout: 1e4, validateStatus: (e9) => e9 < 500 });
var F0 = uTt;
var Ey = "https://frodo.douban.com/api/v2";
var Yg = "apikey=0ac44ae016490db2204ce0a042db2916";
var so0 = "https://cdn.waimaimingtang.com/file/images/bwc/20260414181247-ae51abfbfe.txt";
var xo0 = "Mozilla/5.0 (Windows NT 6.1; WOW64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/53.0.2785.143 Safari/537.36 MicroMessenger/7.0.9.501 NetType/WIFI MiniProgramEnv/Windows WindowsWechat";
var bCt = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36";
var co0 = [{ type_id: "hot_gaia", type_name: "\u70ED\u95E8\u7535\u5F71" }, { type_id: "tv_hot", type_name: "\u70ED\u64AD\u5267\u96C6" }, { type_id: "show_hot", type_name: "\u70ED\u64AD\u7EFC\u827A" }, { type_id: "movie", type_name: "\u7535\u5F71\u7B5B\u9009" }, { type_id: "tv", type_name: "\u7535\u89C6\u7B5B\u9009" }, { type_id: "rank_list_movie", type_name: "\u7535\u5F71\u699C\u5355" }, { type_id: "rank_list_tv", type_name: "\u7535\u89C6\u5267\u699C\u5355" }];
function uo0(e9 = {}) {
  let t = e9.config?.douban || {}, n = { extend: t.extend || t.ext || so0, filters: null };
  return { meta: { key: "douban", name: "\u8C46\u74E3|\u9996\u9875", type: 3, indexs: 1 }, async init(s) {
    let c = s?.body || {};
    return (c.extend || c.ext) && (n.extend = c.extend || c.ext, n.filters = null), {};
  }, async home(s) {
    let c = `http://api.douban.com/api/v2/subject_collection/subject_real_time_hotest/items?${Yg}`, d = (await io0(c)).subject_collection_items || [];
    return P0(co0, await ACt(n), no0(d, oo0(s)));
  }, async category(s) {
    let c = s.body || {}, l = c.id || c.tid || "hot_gaia", d = wCt(c.page || c.pg, 1), m = c.filters || c.extend || {}, g = (d - 1) * 20, { url: y, itemKey: v } = yCt(l, g, m), w = await io0(y), T = no0(w[v] || [], oo0(s)), I = Number(w.total || Number.MAX_SAFE_INTEGER), N = Number.isFinite(I) && I > 0 ? Math.ceil(I / 20) : Number.MAX_SAFE_INTEGER;
    return Me({ page: d, pagecount: N, limit: 20, total: I, list: T });
  }, async detail() {
    return {};
  }, async play() {
    return {};
  }, async search() {
    return {};
  } };
}
function yCt(e9, t, n = {}) {
  let s = n.sort || "T", c = "items", l;
  switch (e9) {
    case "hot_gaia": {
      s = n.sort || "recommend";
      let d = n.area || "\u5168\u90E8";
      l = `${Ey}/movie/hot_gaia?${Yg}&sort=${s}&area=${encodeURIComponent(d)}&start=${t}&count=20`;
      break;
    }
    case "tv_hot": {
      let d = n.type || "tv_hot";
      l = `${Ey}/subject_collection/${encodeURIComponent(d)}/items?${Yg}&start=${t}&count=20`, c = "subject_collection_items";
      break;
    }
    case "show_hot": {
      let d = n.type || "show_hot";
      l = `${Ey}/subject_collection/${encodeURIComponent(d)}/items?${Yg}&start=${t}&count=20`, c = "subject_collection_items";
      break;
    }
    case "tv":
      l = `${Ey}/tv/recommend?${Yg}&sort=${encodeURIComponent(s)}&tags=${encodeURIComponent(ao0(n))}&start=${t}&count=20`;
      break;
    case "rank_list_movie": {
      let d = n.\u699C\u5355 || "movie_real_time_hotest";
      l = `${Ey}/subject_collection/${encodeURIComponent(d)}/items?${Yg}&start=${t}&count=20`, c = "subject_collection_items";
      break;
    }
    case "rank_list_tv": {
      let d = n.\u699C\u5355 || "tv_real_time_hotest";
      l = `${Ey}/subject_collection/${encodeURIComponent(d)}/items?${Yg}&start=${t}&count=20`, c = "subject_collection_items";
      break;
    }
    default:
      l = `${Ey}/movie/recommend?${Yg}&sort=${encodeURIComponent(s)}&tags=${encodeURIComponent(ao0(n))}&start=${t}&count=20`;
      break;
  }
  return { url: l, itemKey: c };
}
function no0(e9 = [], t = "") {
  return e9.map((n) => {
    let s = SCt(n.title), c = n?.pic?.normal || "";
    return !s || !c ? null : u0({ id: `msearch:${n.id || ""}`, name: s, pic: vCt(t, c), remarks: _Ct(n) });
  }).filter(Boolean);
}
async function ACt(e9) {
  if (e9.filters) return e9.filters;
  e9.filters = {};
  try {
    let t = await kCt(e9.extend || so0);
    for (let n of co0) {
      let s = t?.[n.type_id];
      Array.isArray(s) && (e9.filters[n.type_id] = s.map((c) => ({ key: c.key, name: c.name, init: c.init ?? "", value: Array.isArray(c.value) ? c.value : [] })).filter((c) => c.key && c.name));
    }
  } catch (t) {
    console.warn(`[NewDouBan] filter config load failed: ${t.message}`);
  }
  return e9.filters;
}
async function io0(e9) {
  return (await t0.get(e9, { responseType: "json", timeout: 15e3, headers: { Host: new URL(e9).hostname.includes("douban.com") ? "frodo.douban.com" : void 0, Connection: "Keep-Alive", Referer: "https://servicewechat.com/wx2f9b06c1de1ccfca/84/page-frame.html", "User-Agent": xo0 } })).data || {};
}
async function kCt(e9) {
  return (await t0.get(e9, { responseType: "json", timeout: 15e3, headers: { "User-Agent": xo0 } })).data || {};
}
function ao0(e9 = {}) {
  return Object.entries(e9).filter(([t, n]) => t !== "sort" && n !== void 0 && n !== null && String(n).trim() !== "").map(([, t]) => String(t).trim()).join(",");
}
function vCt(e9, t) {
  let n = new URLSearchParams({ url: t, cache: "86400", customHeaders: JSON.stringify({ Referer: "https://movie.douban.com/", "User-Agent": bCt }) });
  return `${e9}/imageProxy?${n}`;
}
function oo0(e9) {
  let t = e9.headers?.["x-forwarded-proto"] || "http", n = e9.headers?.host || `127.0.0.1:${e9.server?.server?.address?.()?.port || 9988}`;
  return `${t}://${n}`;
}
function _Ct(e9 = {}) {
  let t = e9.rating?.value;
  return t ? `\u8BC4\u5206\uFF1A${t}` : "";
}
function wCt(e9, t) {
  let n = Number(e9 || t);
  return Number.isFinite(n) && n > 0 ? Math.floor(n) : t;
}
function SCt(e9) {
  return String(e9 || "").trim();
}
var DCt = { xml: false, decodeEntities: true };
var ZR = DCt;
var yo0 = { _useHtmlParser2: true, xmlMode: true };
function KR(e9) {
  return e9?.xml ? typeof e9.xml == "boolean" ? yo0 : { ...yo0, ...e9.xml } : e9 ?? void 0;
}
var Xg = {};
var Ii;
(function(e9) {
  e9.Root = "root", e9.Text = "text", e9.Directive = "directive", e9.Comment = "comment", e9.Script = "script", e9.Style = "style", e9.Tag = "tag", e9.CDATA = "cdata", e9.Doctype = "doctype";
})(Ii || (Ii = {}));
function Ao0(e9) {
  return e9.type === Ii.Tag || e9.type === Ii.Script || e9.type === Ii.Style;
}
var ko0 = Ii.Root;
var vo0 = Ii.Text;
var _o0 = Ii.Directive;
var wo0 = Ii.Comment;
var So0 = Ii.Script;
var Eo0 = Ii.Style;
var To0 = Ii.Tag;
var Io0 = Ii.CDATA;
var Ro0 = Ii.Doctype;
var jG = class {
  constructor() {
    this.parent = null, this.prev = null, this.next = null, this.startIndex = null, this.endIndex = null;
  }
  get parentNode() {
    return this.parent;
  }
  set parentNode(t) {
    this.parent = t;
  }
  get previousSibling() {
    return this.prev;
  }
  set previousSibling(t) {
    this.prev = t;
  }
  get nextSibling() {
    return this.next;
  }
  set nextSibling(t) {
    this.next = t;
  }
  cloneNode(t = false) {
    return tC(this, t);
  }
};
var JR = class extends jG {
  constructor(t) {
    super(), this.data = t;
  }
  get nodeValue() {
    return this.data;
  }
  set nodeValue(t) {
    this.data = t;
  }
};
var v1 = class extends JR {
  constructor() {
    super(...arguments), this.type = Ii.Text;
  }
  get nodeType() {
    return 3;
  }
};
var Ty = class extends JR {
  constructor() {
    super(...arguments), this.type = Ii.Comment;
  }
  get nodeType() {
    return 8;
  }
};
var Iy = class extends JR {
  constructor(t, n) {
    super(n), this.name = t, this.type = Ii.Directive;
  }
  get nodeType() {
    return 1;
  }
};
var XR = class extends jG {
  constructor(t) {
    super(), this.children = t;
  }
  get firstChild() {
    var t;
    return (t = this.children[0]) !== null && t !== void 0 ? t : null;
  }
  get lastChild() {
    return this.children.length > 0 ? this.children[this.children.length - 1] : null;
  }
  get childNodes() {
    return this.children;
  }
  set childNodes(t) {
    this.children = t;
  }
};
var eC = class extends XR {
  constructor() {
    super(...arguments), this.type = Ii.CDATA;
  }
  get nodeType() {
    return 4;
  }
};
var rf = class extends XR {
  constructor() {
    super(...arguments), this.type = Ii.Root;
  }
  get nodeType() {
    return 9;
  }
};
var Ry = class extends XR {
  constructor(t, n, s = [], c = t === "script" ? Ii.Script : t === "style" ? Ii.Style : Ii.Tag) {
    super(s), this.name = t, this.attribs = n, this.type = c;
  }
  get nodeType() {
    return 1;
  }
  get tagName() {
    return this.name;
  }
  set tagName(t) {
    this.name = t;
  }
  get attributes() {
    return Object.keys(this.attribs).map((t) => {
      var n, s;
      return { name: t, value: this.attribs[t], namespace: (n = this["x-attribsNamespace"]) === null || n === void 0 ? void 0 : n[t], prefix: (s = this["x-attribsPrefix"]) === null || s === void 0 ? void 0 : s[t] };
    });
  }
};
function yr(e9) {
  return Ao0(e9);
}
function Wv(e9) {
  return e9.type === Ii.CDATA;
}
function rl(e9) {
  return e9.type === Ii.Text;
}
function Cy(e9) {
  return e9.type === Ii.Comment;
}
function GG(e9) {
  return e9.type === Ii.Directive;
}
function F2(e9) {
  return e9.type === Ii.Root;
}
function tC(e9, t = false) {
  let n;
  if (rl(e9)) n = new v1(e9.data);
  else if (Cy(e9)) n = new Ty(e9.data);
  else if (yr(e9)) {
    let s = t ? ade(e9.children) : [], c = new Ry(e9.name, { ...e9.attribs }, s);
    s.forEach((l) => l.parent = c), e9.namespace != null && (c.namespace = e9.namespace), e9["x-attribsNamespace"] && (c["x-attribsNamespace"] = { ...e9["x-attribsNamespace"] }), e9["x-attribsPrefix"] && (c["x-attribsPrefix"] = { ...e9["x-attribsPrefix"] }), n = c;
  } else if (Wv(e9)) {
    let s = t ? ade(e9.children) : [], c = new eC(s);
    s.forEach((l) => l.parent = c), n = c;
  } else if (F2(e9)) {
    let s = t ? ade(e9.children) : [], c = new rf(s);
    s.forEach((l) => l.parent = c), e9["x-mode"] && (c["x-mode"] = e9["x-mode"]), n = c;
  } else if (GG(e9)) {
    let s = new Iy(e9.name, e9.data);
    e9["x-name"] != null && (s["x-name"] = e9["x-name"], s["x-publicId"] = e9["x-publicId"], s["x-systemId"] = e9["x-systemId"]), n = s;
  } else throw new Error(`Not implemented yet: ${e9.type}`);
  return n.startIndex = e9.startIndex, n.endIndex = e9.endIndex, e9.sourceCodeLocation != null && (n.sourceCodeLocation = e9.sourceCodeLocation), n;
}
function ade(e9) {
  let t = e9.map((n) => tC(n, true));
  for (let n = 1; n < t.length; n++) t[n].prev = t[n - 1], t[n - 1].next = t[n];
  return t;
}
var No0 = { withStartIndices: false, withEndIndices: false, xmlMode: false };
var Vv = class {
  constructor(t, n, s) {
    this.dom = [], this.root = new rf(this.dom), this.done = false, this.tagStack = [this.root], this.lastNode = null, this.parser = null, typeof n == "function" && (s = n, n = No0), typeof t == "object" && (n = t, t = void 0), this.callback = t ?? null, this.options = n ?? No0, this.elementCB = s ?? null;
  }
  onparserinit(t) {
    this.parser = t;
  }
  onreset() {
    this.dom = [], this.root = new rf(this.dom), this.done = false, this.tagStack = [this.root], this.lastNode = null, this.parser = null;
  }
  onend() {
    this.done || (this.done = true, this.parser = null, this.handleCallback(null));
  }
  onerror(t) {
    this.handleCallback(t);
  }
  onclosetag() {
    this.lastNode = null;
    let t = this.tagStack.pop();
    this.options.withEndIndices && (t.endIndex = this.parser.endIndex), this.elementCB && this.elementCB(t);
  }
  onopentag(t, n) {
    let s = this.options.xmlMode ? Ii.Tag : void 0, c = new Ry(t, n, void 0, s);
    this.addNode(c), this.tagStack.push(c);
  }
  ontext(t) {
    let { lastNode: n } = this;
    if (n && n.type === Ii.Text) n.data += t, this.options.withEndIndices && (n.endIndex = this.parser.endIndex);
    else {
      let s = new v1(t);
      this.addNode(s), this.lastNode = s;
    }
  }
  oncomment(t) {
    if (this.lastNode && this.lastNode.type === Ii.Comment) {
      this.lastNode.data += t;
      return;
    }
    let n = new Ty(t);
    this.addNode(n), this.lastNode = n;
  }
  oncommentend() {
    this.lastNode = null;
  }
  oncdatastart() {
    let t = new v1(""), n = new eC([t]);
    this.addNode(n), t.parent = n, this.lastNode = t;
  }
  oncdataend() {
    this.lastNode = null;
  }
  onprocessinginstruction(t, n) {
    let s = new Iy(t, n);
    this.addNode(s);
  }
  handleCallback(t) {
    if (typeof this.callback == "function") this.callback(t, this.dom);
    else if (t) throw t;
  }
  addNode(t) {
    let n = this.tagStack[this.tagStack.length - 1], s = n.children[n.children.length - 1];
    this.options.withStartIndices && (t.startIndex = this.parser.startIndex), this.options.withEndIndices && (t.endIndex = this.parser.endIndex), n.children.push(t), s && (t.prev = s, s.next = t), t.parent = n, this.lastNode = null;
  }
};
var HG = new Uint16Array('\u1D41<\xD5\u0131\u028A\u049D\u057B\u05D0\u0675\u06DE\u07A2\u07D6\u080F\u0A4A\u0A91\u0DA1\u0E6D\u0F09\u0F26\u10CA\u1228\u12E1\u1415\u149D\u14C3\u14DF\u1525\0\0\0\0\0\0\u156B\u16CD\u198D\u1C12\u1DDD\u1F7E\u2060\u21B0\u228D\u23C0\u23FB\u2442\u2824\u2912\u2D08\u2E48\u2FCE\u3016\u32BA\u3639\u37AC\u38FE\u3A28\u3A71\u3AE0\u3B2E\u0800EMabcfglmnoprstu\\bfms\x7F\x84\x8B\x90\x95\x98\xA6\xB3\xB9\xC8\xCFlig\u803B\xC6\u40C6P\u803B&\u4026cute\u803B\xC1\u40C1reve;\u4102\u0100iyx}rc\u803B\xC2\u40C2;\u4410r;\uC000\u{1D504}rave\u803B\xC0\u40C0pha;\u4391acr;\u4100d;\u6A53\u0100gp\x9D\xA1on;\u4104f;\uC000\u{1D538}plyFunction;\u6061ing\u803B\xC5\u40C5\u0100cs\xBE\xC3r;\uC000\u{1D49C}ign;\u6254ilde\u803B\xC3\u40C3ml\u803B\xC4\u40C4\u0400aceforsu\xE5\xFB\xFE\u0117\u011C\u0122\u0127\u012A\u0100cr\xEA\xF2kslash;\u6216\u0176\xF6\xF8;\u6AE7ed;\u6306y;\u4411\u0180crt\u0105\u010B\u0114ause;\u6235noullis;\u612Ca;\u4392r;\uC000\u{1D505}pf;\uC000\u{1D539}eve;\u42D8c\xF2\u0113mpeq;\u624E\u0700HOacdefhilorsu\u014D\u0151\u0156\u0180\u019E\u01A2\u01B5\u01B7\u01BA\u01DC\u0215\u0273\u0278\u027Ecy;\u4427PY\u803B\xA9\u40A9\u0180cpy\u015D\u0162\u017Aute;\u4106\u0100;i\u0167\u0168\u62D2talDifferentialD;\u6145leys;\u612D\u0200aeio\u0189\u018E\u0194\u0198ron;\u410Cdil\u803B\xC7\u40C7rc;\u4108nint;\u6230ot;\u410A\u0100dn\u01A7\u01ADilla;\u40B8terDot;\u40B7\xF2\u017Fi;\u43A7rcle\u0200DMPT\u01C7\u01CB\u01D1\u01D6ot;\u6299inus;\u6296lus;\u6295imes;\u6297o\u0100cs\u01E2\u01F8kwiseContourIntegral;\u6232eCurly\u0100DQ\u0203\u020FoubleQuote;\u601Duote;\u6019\u0200lnpu\u021E\u0228\u0247\u0255on\u0100;e\u0225\u0226\u6237;\u6A74\u0180git\u022F\u0236\u023Aruent;\u6261nt;\u622FourIntegral;\u622E\u0100fr\u024C\u024E;\u6102oduct;\u6210nterClockwiseContourIntegral;\u6233oss;\u6A2Fcr;\uC000\u{1D49E}p\u0100;C\u0284\u0285\u62D3ap;\u624D\u0580DJSZacefios\u02A0\u02AC\u02B0\u02B4\u02B8\u02CB\u02D7\u02E1\u02E6\u0333\u048D\u0100;o\u0179\u02A5trahd;\u6911cy;\u4402cy;\u4405cy;\u440F\u0180grs\u02BF\u02C4\u02C7ger;\u6021r;\u61A1hv;\u6AE4\u0100ay\u02D0\u02D5ron;\u410E;\u4414l\u0100;t\u02DD\u02DE\u6207a;\u4394r;\uC000\u{1D507}\u0100af\u02EB\u0327\u0100cm\u02F0\u0322ritical\u0200ADGT\u0300\u0306\u0316\u031Ccute;\u40B4o\u0174\u030B\u030D;\u42D9bleAcute;\u42DDrave;\u4060ilde;\u42DCond;\u62C4ferentialD;\u6146\u0470\u033D\0\0\0\u0342\u0354\0\u0405f;\uC000\u{1D53B}\u0180;DE\u0348\u0349\u034D\u40A8ot;\u60DCqual;\u6250ble\u0300CDLRUV\u0363\u0372\u0382\u03CF\u03E2\u03F8ontourIntegra\xEC\u0239o\u0274\u0379\0\0\u037B\xBB\u0349nArrow;\u61D3\u0100eo\u0387\u03A4ft\u0180ART\u0390\u0396\u03A1rrow;\u61D0ightArrow;\u61D4e\xE5\u02CAng\u0100LR\u03AB\u03C4eft\u0100AR\u03B3\u03B9rrow;\u67F8ightArrow;\u67FAightArrow;\u67F9ight\u0100AT\u03D8\u03DErrow;\u61D2ee;\u62A8p\u0241\u03E9\0\0\u03EFrrow;\u61D1ownArrow;\u61D5erticalBar;\u6225n\u0300ABLRTa\u0412\u042A\u0430\u045E\u047F\u037Crrow\u0180;BU\u041D\u041E\u0422\u6193ar;\u6913pArrow;\u61F5reve;\u4311eft\u02D2\u043A\0\u0446\0\u0450ightVector;\u6950eeVector;\u695Eector\u0100;B\u0459\u045A\u61BDar;\u6956ight\u01D4\u0467\0\u0471eeVector;\u695Fector\u0100;B\u047A\u047B\u61C1ar;\u6957ee\u0100;A\u0486\u0487\u62A4rrow;\u61A7\u0100ct\u0492\u0497r;\uC000\u{1D49F}rok;\u4110\u0800NTacdfglmopqstux\u04BD\u04C0\u04C4\u04CB\u04DE\u04E2\u04E7\u04EE\u04F5\u0521\u052F\u0536\u0552\u055D\u0560\u0565G;\u414AH\u803B\xD0\u40D0cute\u803B\xC9\u40C9\u0180aiy\u04D2\u04D7\u04DCron;\u411Arc\u803B\xCA\u40CA;\u442Dot;\u4116r;\uC000\u{1D508}rave\u803B\xC8\u40C8ement;\u6208\u0100ap\u04FA\u04FEcr;\u4112ty\u0253\u0506\0\0\u0512mallSquare;\u65FBerySmallSquare;\u65AB\u0100gp\u0526\u052Aon;\u4118f;\uC000\u{1D53C}silon;\u4395u\u0100ai\u053C\u0549l\u0100;T\u0542\u0543\u6A75ilde;\u6242librium;\u61CC\u0100ci\u0557\u055Ar;\u6130m;\u6A73a;\u4397ml\u803B\xCB\u40CB\u0100ip\u056A\u056Fsts;\u6203onentialE;\u6147\u0280cfios\u0585\u0588\u058D\u05B2\u05CCy;\u4424r;\uC000\u{1D509}lled\u0253\u0597\0\0\u05A3mallSquare;\u65FCerySmallSquare;\u65AA\u0370\u05BA\0\u05BF\0\0\u05C4f;\uC000\u{1D53D}All;\u6200riertrf;\u6131c\xF2\u05CB\u0600JTabcdfgorst\u05E8\u05EC\u05EF\u05FA\u0600\u0612\u0616\u061B\u061D\u0623\u066C\u0672cy;\u4403\u803B>\u403Emma\u0100;d\u05F7\u05F8\u4393;\u43DCreve;\u411E\u0180eiy\u0607\u060C\u0610dil;\u4122rc;\u411C;\u4413ot;\u4120r;\uC000\u{1D50A};\u62D9pf;\uC000\u{1D53E}eater\u0300EFGLST\u0635\u0644\u064E\u0656\u065B\u0666qual\u0100;L\u063E\u063F\u6265ess;\u62DBullEqual;\u6267reater;\u6AA2ess;\u6277lantEqual;\u6A7Eilde;\u6273cr;\uC000\u{1D4A2};\u626B\u0400Aacfiosu\u0685\u068B\u0696\u069B\u069E\u06AA\u06BE\u06CARDcy;\u442A\u0100ct\u0690\u0694ek;\u42C7;\u405Eirc;\u4124r;\u610ClbertSpace;\u610B\u01F0\u06AF\0\u06B2f;\u610DizontalLine;\u6500\u0100ct\u06C3\u06C5\xF2\u06A9rok;\u4126mp\u0144\u06D0\u06D8ownHum\xF0\u012Fqual;\u624F\u0700EJOacdfgmnostu\u06FA\u06FE\u0703\u0707\u070E\u071A\u071E\u0721\u0728\u0744\u0778\u078B\u078F\u0795cy;\u4415lig;\u4132cy;\u4401cute\u803B\xCD\u40CD\u0100iy\u0713\u0718rc\u803B\xCE\u40CE;\u4418ot;\u4130r;\u6111rave\u803B\xCC\u40CC\u0180;ap\u0720\u072F\u073F\u0100cg\u0734\u0737r;\u412AinaryI;\u6148lie\xF3\u03DD\u01F4\u0749\0\u0762\u0100;e\u074D\u074E\u622C\u0100gr\u0753\u0758ral;\u622Bsection;\u62C2isible\u0100CT\u076C\u0772omma;\u6063imes;\u6062\u0180gpt\u077F\u0783\u0788on;\u412Ef;\uC000\u{1D540}a;\u4399cr;\u6110ilde;\u4128\u01EB\u079A\0\u079Ecy;\u4406l\u803B\xCF\u40CF\u0280cfosu\u07AC\u07B7\u07BC\u07C2\u07D0\u0100iy\u07B1\u07B5rc;\u4134;\u4419r;\uC000\u{1D50D}pf;\uC000\u{1D541}\u01E3\u07C7\0\u07CCr;\uC000\u{1D4A5}rcy;\u4408kcy;\u4404\u0380HJacfos\u07E4\u07E8\u07EC\u07F1\u07FD\u0802\u0808cy;\u4425cy;\u440Cppa;\u439A\u0100ey\u07F6\u07FBdil;\u4136;\u441Ar;\uC000\u{1D50E}pf;\uC000\u{1D542}cr;\uC000\u{1D4A6}\u0580JTaceflmost\u0825\u0829\u082C\u0850\u0863\u09B3\u09B8\u09C7\u09CD\u0A37\u0A47cy;\u4409\u803B<\u403C\u0280cmnpr\u0837\u083C\u0841\u0844\u084Dute;\u4139bda;\u439Bg;\u67EAlacetrf;\u6112r;\u619E\u0180aey\u0857\u085C\u0861ron;\u413Ddil;\u413B;\u441B\u0100fs\u0868\u0970t\u0500ACDFRTUVar\u087E\u08A9\u08B1\u08E0\u08E6\u08FC\u092F\u095B\u0390\u096A\u0100nr\u0883\u088FgleBracket;\u67E8row\u0180;BR\u0899\u089A\u089E\u6190ar;\u61E4ightArrow;\u61C6eiling;\u6308o\u01F5\u08B7\0\u08C3bleBracket;\u67E6n\u01D4\u08C8\0\u08D2eeVector;\u6961ector\u0100;B\u08DB\u08DC\u61C3ar;\u6959loor;\u630Aight\u0100AV\u08EF\u08F5rrow;\u6194ector;\u694E\u0100er\u0901\u0917e\u0180;AV\u0909\u090A\u0910\u62A3rrow;\u61A4ector;\u695Aiangle\u0180;BE\u0924\u0925\u0929\u62B2ar;\u69CFqual;\u62B4p\u0180DTV\u0937\u0942\u094CownVector;\u6951eeVector;\u6960ector\u0100;B\u0956\u0957\u61BFar;\u6958ector\u0100;B\u0965\u0966\u61BCar;\u6952ight\xE1\u039Cs\u0300EFGLST\u097E\u098B\u0995\u099D\u09A2\u09ADqualGreater;\u62DAullEqual;\u6266reater;\u6276ess;\u6AA1lantEqual;\u6A7Dilde;\u6272r;\uC000\u{1D50F}\u0100;e\u09BD\u09BE\u62D8ftarrow;\u61DAidot;\u413F\u0180npw\u09D4\u0A16\u0A1Bg\u0200LRlr\u09DE\u09F7\u0A02\u0A10eft\u0100AR\u09E6\u09ECrrow;\u67F5ightArrow;\u67F7ightArrow;\u67F6eft\u0100ar\u03B3\u0A0Aight\xE1\u03BFight\xE1\u03CAf;\uC000\u{1D543}er\u0100LR\u0A22\u0A2CeftArrow;\u6199ightArrow;\u6198\u0180cht\u0A3E\u0A40\u0A42\xF2\u084C;\u61B0rok;\u4141;\u626A\u0400acefiosu\u0A5A\u0A5D\u0A60\u0A77\u0A7C\u0A85\u0A8B\u0A8Ep;\u6905y;\u441C\u0100dl\u0A65\u0A6FiumSpace;\u605Flintrf;\u6133r;\uC000\u{1D510}nusPlus;\u6213pf;\uC000\u{1D544}c\xF2\u0A76;\u439C\u0480Jacefostu\u0AA3\u0AA7\u0AAD\u0AC0\u0B14\u0B19\u0D91\u0D97\u0D9Ecy;\u440Acute;\u4143\u0180aey\u0AB4\u0AB9\u0ABEron;\u4147dil;\u4145;\u441D\u0180gsw\u0AC7\u0AF0\u0B0Eative\u0180MTV\u0AD3\u0ADF\u0AE8ediumSpace;\u600Bhi\u0100cn\u0AE6\u0AD8\xEB\u0AD9eryThi\xEE\u0AD9ted\u0100GL\u0AF8\u0B06reaterGreate\xF2\u0673essLes\xF3\u0A48Line;\u400Ar;\uC000\u{1D511}\u0200Bnpt\u0B22\u0B28\u0B37\u0B3Areak;\u6060BreakingSpace;\u40A0f;\u6115\u0680;CDEGHLNPRSTV\u0B55\u0B56\u0B6A\u0B7C\u0BA1\u0BEB\u0C04\u0C5E\u0C84\u0CA6\u0CD8\u0D61\u0D85\u6AEC\u0100ou\u0B5B\u0B64ngruent;\u6262pCap;\u626DoubleVerticalBar;\u6226\u0180lqx\u0B83\u0B8A\u0B9Bement;\u6209ual\u0100;T\u0B92\u0B93\u6260ilde;\uC000\u2242\u0338ists;\u6204reater\u0380;EFGLST\u0BB6\u0BB7\u0BBD\u0BC9\u0BD3\u0BD8\u0BE5\u626Fqual;\u6271ullEqual;\uC000\u2267\u0338reater;\uC000\u226B\u0338ess;\u6279lantEqual;\uC000\u2A7E\u0338ilde;\u6275ump\u0144\u0BF2\u0BFDownHump;\uC000\u224E\u0338qual;\uC000\u224F\u0338e\u0100fs\u0C0A\u0C27tTriangle\u0180;BE\u0C1A\u0C1B\u0C21\u62EAar;\uC000\u29CF\u0338qual;\u62ECs\u0300;EGLST\u0C35\u0C36\u0C3C\u0C44\u0C4B\u0C58\u626Equal;\u6270reater;\u6278ess;\uC000\u226A\u0338lantEqual;\uC000\u2A7D\u0338ilde;\u6274ested\u0100GL\u0C68\u0C79reaterGreater;\uC000\u2AA2\u0338essLess;\uC000\u2AA1\u0338recedes\u0180;ES\u0C92\u0C93\u0C9B\u6280qual;\uC000\u2AAF\u0338lantEqual;\u62E0\u0100ei\u0CAB\u0CB9verseElement;\u620CghtTriangle\u0180;BE\u0CCB\u0CCC\u0CD2\u62EBar;\uC000\u29D0\u0338qual;\u62ED\u0100qu\u0CDD\u0D0CuareSu\u0100bp\u0CE8\u0CF9set\u0100;E\u0CF0\u0CF3\uC000\u228F\u0338qual;\u62E2erset\u0100;E\u0D03\u0D06\uC000\u2290\u0338qual;\u62E3\u0180bcp\u0D13\u0D24\u0D4Eset\u0100;E\u0D1B\u0D1E\uC000\u2282\u20D2qual;\u6288ceeds\u0200;EST\u0D32\u0D33\u0D3B\u0D46\u6281qual;\uC000\u2AB0\u0338lantEqual;\u62E1ilde;\uC000\u227F\u0338erset\u0100;E\u0D58\u0D5B\uC000\u2283\u20D2qual;\u6289ilde\u0200;EFT\u0D6E\u0D6F\u0D75\u0D7F\u6241qual;\u6244ullEqual;\u6247ilde;\u6249erticalBar;\u6224cr;\uC000\u{1D4A9}ilde\u803B\xD1\u40D1;\u439D\u0700Eacdfgmoprstuv\u0DBD\u0DC2\u0DC9\u0DD5\u0DDB\u0DE0\u0DE7\u0DFC\u0E02\u0E20\u0E22\u0E32\u0E3F\u0E44lig;\u4152cute\u803B\xD3\u40D3\u0100iy\u0DCE\u0DD3rc\u803B\xD4\u40D4;\u441Eblac;\u4150r;\uC000\u{1D512}rave\u803B\xD2\u40D2\u0180aei\u0DEE\u0DF2\u0DF6cr;\u414Cga;\u43A9cron;\u439Fpf;\uC000\u{1D546}enCurly\u0100DQ\u0E0E\u0E1AoubleQuote;\u601Cuote;\u6018;\u6A54\u0100cl\u0E27\u0E2Cr;\uC000\u{1D4AA}ash\u803B\xD8\u40D8i\u016C\u0E37\u0E3Cde\u803B\xD5\u40D5es;\u6A37ml\u803B\xD6\u40D6er\u0100BP\u0E4B\u0E60\u0100ar\u0E50\u0E53r;\u603Eac\u0100ek\u0E5A\u0E5C;\u63DEet;\u63B4arenthesis;\u63DC\u0480acfhilors\u0E7F\u0E87\u0E8A\u0E8F\u0E92\u0E94\u0E9D\u0EB0\u0EFCrtialD;\u6202y;\u441Fr;\uC000\u{1D513}i;\u43A6;\u43A0usMinus;\u40B1\u0100ip\u0EA2\u0EADncareplan\xE5\u069Df;\u6119\u0200;eio\u0EB9\u0EBA\u0EE0\u0EE4\u6ABBcedes\u0200;EST\u0EC8\u0EC9\u0ECF\u0EDA\u627Aqual;\u6AAFlantEqual;\u627Cilde;\u627Eme;\u6033\u0100dp\u0EE9\u0EEEuct;\u620Fortion\u0100;a\u0225\u0EF9l;\u621D\u0100ci\u0F01\u0F06r;\uC000\u{1D4AB};\u43A8\u0200Ufos\u0F11\u0F16\u0F1B\u0F1FOT\u803B"\u4022r;\uC000\u{1D514}pf;\u611Acr;\uC000\u{1D4AC}\u0600BEacefhiorsu\u0F3E\u0F43\u0F47\u0F60\u0F73\u0FA7\u0FAA\u0FAD\u1096\u10A9\u10B4\u10BEarr;\u6910G\u803B\xAE\u40AE\u0180cnr\u0F4E\u0F53\u0F56ute;\u4154g;\u67EBr\u0100;t\u0F5C\u0F5D\u61A0l;\u6916\u0180aey\u0F67\u0F6C\u0F71ron;\u4158dil;\u4156;\u4420\u0100;v\u0F78\u0F79\u611Cerse\u0100EU\u0F82\u0F99\u0100lq\u0F87\u0F8Eement;\u620Builibrium;\u61CBpEquilibrium;\u696Fr\xBB\u0F79o;\u43A1ght\u0400ACDFTUVa\u0FC1\u0FEB\u0FF3\u1022\u1028\u105B\u1087\u03D8\u0100nr\u0FC6\u0FD2gleBracket;\u67E9row\u0180;BL\u0FDC\u0FDD\u0FE1\u6192ar;\u61E5eftArrow;\u61C4eiling;\u6309o\u01F5\u0FF9\0\u1005bleBracket;\u67E7n\u01D4\u100A\0\u1014eeVector;\u695Dector\u0100;B\u101D\u101E\u61C2ar;\u6955loor;\u630B\u0100er\u102D\u1043e\u0180;AV\u1035\u1036\u103C\u62A2rrow;\u61A6ector;\u695Biangle\u0180;BE\u1050\u1051\u1055\u62B3ar;\u69D0qual;\u62B5p\u0180DTV\u1063\u106E\u1078ownVector;\u694FeeVector;\u695Cector\u0100;B\u1082\u1083\u61BEar;\u6954ector\u0100;B\u1091\u1092\u61C0ar;\u6953\u0100pu\u109B\u109Ef;\u611DndImplies;\u6970ightarrow;\u61DB\u0100ch\u10B9\u10BCr;\u611B;\u61B1leDelayed;\u69F4\u0680HOacfhimoqstu\u10E4\u10F1\u10F7\u10FD\u1119\u111E\u1151\u1156\u1161\u1167\u11B5\u11BB\u11BF\u0100Cc\u10E9\u10EEHcy;\u4429y;\u4428FTcy;\u442Ccute;\u415A\u0280;aeiy\u1108\u1109\u110E\u1113\u1117\u6ABCron;\u4160dil;\u415Erc;\u415C;\u4421r;\uC000\u{1D516}ort\u0200DLRU\u112A\u1134\u113E\u1149ownArrow\xBB\u041EeftArrow\xBB\u089AightArrow\xBB\u0FDDpArrow;\u6191gma;\u43A3allCircle;\u6218pf;\uC000\u{1D54A}\u0272\u116D\0\0\u1170t;\u621Aare\u0200;ISU\u117B\u117C\u1189\u11AF\u65A1ntersection;\u6293u\u0100bp\u118F\u119Eset\u0100;E\u1197\u1198\u628Fqual;\u6291erset\u0100;E\u11A8\u11A9\u6290qual;\u6292nion;\u6294cr;\uC000\u{1D4AE}ar;\u62C6\u0200bcmp\u11C8\u11DB\u1209\u120B\u0100;s\u11CD\u11CE\u62D0et\u0100;E\u11CD\u11D5qual;\u6286\u0100ch\u11E0\u1205eeds\u0200;EST\u11ED\u11EE\u11F4\u11FF\u627Bqual;\u6AB0lantEqual;\u627Dilde;\u627FTh\xE1\u0F8C;\u6211\u0180;es\u1212\u1213\u1223\u62D1rset\u0100;E\u121C\u121D\u6283qual;\u6287et\xBB\u1213\u0580HRSacfhiors\u123E\u1244\u1249\u1255\u125E\u1271\u1276\u129F\u12C2\u12C8\u12D1ORN\u803B\xDE\u40DEADE;\u6122\u0100Hc\u124E\u1252cy;\u440By;\u4426\u0100bu\u125A\u125C;\u4009;\u43A4\u0180aey\u1265\u126A\u126Fron;\u4164dil;\u4162;\u4422r;\uC000\u{1D517}\u0100ei\u127B\u1289\u01F2\u1280\0\u1287efore;\u6234a;\u4398\u0100cn\u128E\u1298kSpace;\uC000\u205F\u200ASpace;\u6009lde\u0200;EFT\u12AB\u12AC\u12B2\u12BC\u623Cqual;\u6243ullEqual;\u6245ilde;\u6248pf;\uC000\u{1D54B}ipleDot;\u60DB\u0100ct\u12D6\u12DBr;\uC000\u{1D4AF}rok;\u4166\u0AE1\u12F7\u130E\u131A\u1326\0\u132C\u1331\0\0\0\0\0\u1338\u133D\u1377\u1385\0\u13FF\u1404\u140A\u1410\u0100cr\u12FB\u1301ute\u803B\xDA\u40DAr\u0100;o\u1307\u1308\u619Fcir;\u6949r\u01E3\u1313\0\u1316y;\u440Eve;\u416C\u0100iy\u131E\u1323rc\u803B\xDB\u40DB;\u4423blac;\u4170r;\uC000\u{1D518}rave\u803B\xD9\u40D9acr;\u416A\u0100di\u1341\u1369er\u0100BP\u1348\u135D\u0100ar\u134D\u1350r;\u405Fac\u0100ek\u1357\u1359;\u63DFet;\u63B5arenthesis;\u63DDon\u0100;P\u1370\u1371\u62C3lus;\u628E\u0100gp\u137B\u137Fon;\u4172f;\uC000\u{1D54C}\u0400ADETadps\u1395\u13AE\u13B8\u13C4\u03E8\u13D2\u13D7\u13F3rrow\u0180;BD\u1150\u13A0\u13A4ar;\u6912ownArrow;\u61C5ownArrow;\u6195quilibrium;\u696Eee\u0100;A\u13CB\u13CC\u62A5rrow;\u61A5own\xE1\u03F3er\u0100LR\u13DE\u13E8eftArrow;\u6196ightArrow;\u6197i\u0100;l\u13F9\u13FA\u43D2on;\u43A5ing;\u416Ecr;\uC000\u{1D4B0}ilde;\u4168ml\u803B\xDC\u40DC\u0480Dbcdefosv\u1427\u142C\u1430\u1433\u143E\u1485\u148A\u1490\u1496ash;\u62ABar;\u6AEBy;\u4412ash\u0100;l\u143B\u143C\u62A9;\u6AE6\u0100er\u1443\u1445;\u62C1\u0180bty\u144C\u1450\u147Aar;\u6016\u0100;i\u144F\u1455cal\u0200BLST\u1461\u1465\u146A\u1474ar;\u6223ine;\u407Ceparator;\u6758ilde;\u6240ThinSpace;\u600Ar;\uC000\u{1D519}pf;\uC000\u{1D54D}cr;\uC000\u{1D4B1}dash;\u62AA\u0280cefos\u14A7\u14AC\u14B1\u14B6\u14BCirc;\u4174dge;\u62C0r;\uC000\u{1D51A}pf;\uC000\u{1D54E}cr;\uC000\u{1D4B2}\u0200fios\u14CB\u14D0\u14D2\u14D8r;\uC000\u{1D51B};\u439Epf;\uC000\u{1D54F}cr;\uC000\u{1D4B3}\u0480AIUacfosu\u14F1\u14F5\u14F9\u14FD\u1504\u150F\u1514\u151A\u1520cy;\u442Fcy;\u4407cy;\u442Ecute\u803B\xDD\u40DD\u0100iy\u1509\u150Drc;\u4176;\u442Br;\uC000\u{1D51C}pf;\uC000\u{1D550}cr;\uC000\u{1D4B4}ml;\u4178\u0400Hacdefos\u1535\u1539\u153F\u154B\u154F\u155D\u1560\u1564cy;\u4416cute;\u4179\u0100ay\u1544\u1549ron;\u417D;\u4417ot;\u417B\u01F2\u1554\0\u155BoWidt\xE8\u0AD9a;\u4396r;\u6128pf;\u6124cr;\uC000\u{1D4B5}\u0BE1\u1583\u158A\u1590\0\u15B0\u15B6\u15BF\0\0\0\0\u15C6\u15DB\u15EB\u165F\u166D\0\u1695\u169B\u16B2\u16B9\0\u16BEcute\u803B\xE1\u40E1reve;\u4103\u0300;Ediuy\u159C\u159D\u15A1\u15A3\u15A8\u15AD\u623E;\uC000\u223E\u0333;\u623Frc\u803B\xE2\u40E2te\u80BB\xB4\u0306;\u4430lig\u803B\xE6\u40E6\u0100;r\xB2\u15BA;\uC000\u{1D51E}rave\u803B\xE0\u40E0\u0100ep\u15CA\u15D6\u0100fp\u15CF\u15D4sym;\u6135\xE8\u15D3ha;\u43B1\u0100ap\u15DFc\u0100cl\u15E4\u15E7r;\u4101g;\u6A3F\u0264\u15F0\0\0\u160A\u0280;adsv\u15FA\u15FB\u15FF\u1601\u1607\u6227nd;\u6A55;\u6A5Clope;\u6A58;\u6A5A\u0380;elmrsz\u1618\u1619\u161B\u161E\u163F\u164F\u1659\u6220;\u69A4e\xBB\u1619sd\u0100;a\u1625\u1626\u6221\u0461\u1630\u1632\u1634\u1636\u1638\u163A\u163C\u163E;\u69A8;\u69A9;\u69AA;\u69AB;\u69AC;\u69AD;\u69AE;\u69AFt\u0100;v\u1645\u1646\u621Fb\u0100;d\u164C\u164D\u62BE;\u699D\u0100pt\u1654\u1657h;\u6222\xBB\xB9arr;\u637C\u0100gp\u1663\u1667on;\u4105f;\uC000\u{1D552}\u0380;Eaeiop\u12C1\u167B\u167D\u1682\u1684\u1687\u168A;\u6A70cir;\u6A6F;\u624Ad;\u624Bs;\u4027rox\u0100;e\u12C1\u1692\xF1\u1683ing\u803B\xE5\u40E5\u0180cty\u16A1\u16A6\u16A8r;\uC000\u{1D4B6};\u402Amp\u0100;e\u12C1\u16AF\xF1\u0288ilde\u803B\xE3\u40E3ml\u803B\xE4\u40E4\u0100ci\u16C2\u16C8onin\xF4\u0272nt;\u6A11\u0800Nabcdefiklnoprsu\u16ED\u16F1\u1730\u173C\u1743\u1748\u1778\u177D\u17E0\u17E6\u1839\u1850\u170D\u193D\u1948\u1970ot;\u6AED\u0100cr\u16F6\u171Ek\u0200ceps\u1700\u1705\u170D\u1713ong;\u624Cpsilon;\u43F6rime;\u6035im\u0100;e\u171A\u171B\u623Dq;\u62CD\u0176\u1722\u1726ee;\u62BDed\u0100;g\u172C\u172D\u6305e\xBB\u172Drk\u0100;t\u135C\u1737brk;\u63B6\u0100oy\u1701\u1741;\u4431quo;\u601E\u0280cmprt\u1753\u175B\u1761\u1764\u1768aus\u0100;e\u010A\u0109ptyv;\u69B0s\xE9\u170Cno\xF5\u0113\u0180ahw\u176F\u1771\u1773;\u43B2;\u6136een;\u626Cr;\uC000\u{1D51F}g\u0380costuvw\u178D\u179D\u17B3\u17C1\u17D5\u17DB\u17DE\u0180aiu\u1794\u1796\u179A\xF0\u0760rc;\u65EFp\xBB\u1371\u0180dpt\u17A4\u17A8\u17ADot;\u6A00lus;\u6A01imes;\u6A02\u0271\u17B9\0\0\u17BEcup;\u6A06ar;\u6605riangle\u0100du\u17CD\u17D2own;\u65BDp;\u65B3plus;\u6A04e\xE5\u1444\xE5\u14ADarow;\u690D\u0180ako\u17ED\u1826\u1835\u0100cn\u17F2\u1823k\u0180lst\u17FA\u05AB\u1802ozenge;\u69EBriangle\u0200;dlr\u1812\u1813\u1818\u181D\u65B4own;\u65BEeft;\u65C2ight;\u65B8k;\u6423\u01B1\u182B\0\u1833\u01B2\u182F\0\u1831;\u6592;\u65914;\u6593ck;\u6588\u0100eo\u183E\u184D\u0100;q\u1843\u1846\uC000=\u20E5uiv;\uC000\u2261\u20E5t;\u6310\u0200ptwx\u1859\u185E\u1867\u186Cf;\uC000\u{1D553}\u0100;t\u13CB\u1863om\xBB\u13CCtie;\u62C8\u0600DHUVbdhmptuv\u1885\u1896\u18AA\u18BB\u18D7\u18DB\u18EC\u18FF\u1905\u190A\u1910\u1921\u0200LRlr\u188E\u1890\u1892\u1894;\u6557;\u6554;\u6556;\u6553\u0280;DUdu\u18A1\u18A2\u18A4\u18A6\u18A8\u6550;\u6566;\u6569;\u6564;\u6567\u0200LRlr\u18B3\u18B5\u18B7\u18B9;\u655D;\u655A;\u655C;\u6559\u0380;HLRhlr\u18CA\u18CB\u18CD\u18CF\u18D1\u18D3\u18D5\u6551;\u656C;\u6563;\u6560;\u656B;\u6562;\u655Fox;\u69C9\u0200LRlr\u18E4\u18E6\u18E8\u18EA;\u6555;\u6552;\u6510;\u650C\u0280;DUdu\u06BD\u18F7\u18F9\u18FB\u18FD;\u6565;\u6568;\u652C;\u6534inus;\u629Flus;\u629Eimes;\u62A0\u0200LRlr\u1919\u191B\u191D\u191F;\u655B;\u6558;\u6518;\u6514\u0380;HLRhlr\u1930\u1931\u1933\u1935\u1937\u1939\u193B\u6502;\u656A;\u6561;\u655E;\u653C;\u6524;\u651C\u0100ev\u0123\u1942bar\u803B\xA6\u40A6\u0200ceio\u1951\u1956\u195A\u1960r;\uC000\u{1D4B7}mi;\u604Fm\u0100;e\u171A\u171Cl\u0180;bh\u1968\u1969\u196B\u405C;\u69C5sub;\u67C8\u016C\u1974\u197El\u0100;e\u1979\u197A\u6022t\xBB\u197Ap\u0180;Ee\u012F\u1985\u1987;\u6AAE\u0100;q\u06DC\u06DB\u0CE1\u19A7\0\u19E8\u1A11\u1A15\u1A32\0\u1A37\u1A50\0\0\u1AB4\0\0\u1AC1\0\0\u1B21\u1B2E\u1B4D\u1B52\0\u1BFD\0\u1C0C\u0180cpr\u19AD\u19B2\u19DDute;\u4107\u0300;abcds\u19BF\u19C0\u19C4\u19CA\u19D5\u19D9\u6229nd;\u6A44rcup;\u6A49\u0100au\u19CF\u19D2p;\u6A4Bp;\u6A47ot;\u6A40;\uC000\u2229\uFE00\u0100eo\u19E2\u19E5t;\u6041\xEE\u0693\u0200aeiu\u19F0\u19FB\u1A01\u1A05\u01F0\u19F5\0\u19F8s;\u6A4Don;\u410Ddil\u803B\xE7\u40E7rc;\u4109ps\u0100;s\u1A0C\u1A0D\u6A4Cm;\u6A50ot;\u410B\u0180dmn\u1A1B\u1A20\u1A26il\u80BB\xB8\u01ADptyv;\u69B2t\u8100\xA2;e\u1A2D\u1A2E\u40A2r\xE4\u01B2r;\uC000\u{1D520}\u0180cei\u1A3D\u1A40\u1A4Dy;\u4447ck\u0100;m\u1A47\u1A48\u6713ark\xBB\u1A48;\u43C7r\u0380;Ecefms\u1A5F\u1A60\u1A62\u1A6B\u1AA4\u1AAA\u1AAE\u65CB;\u69C3\u0180;el\u1A69\u1A6A\u1A6D\u42C6q;\u6257e\u0261\u1A74\0\0\u1A88rrow\u0100lr\u1A7C\u1A81eft;\u61BAight;\u61BB\u0280RSacd\u1A92\u1A94\u1A96\u1A9A\u1A9F\xBB\u0F47;\u64C8st;\u629Birc;\u629Aash;\u629Dnint;\u6A10id;\u6AEFcir;\u69C2ubs\u0100;u\u1ABB\u1ABC\u6663it\xBB\u1ABC\u02EC\u1AC7\u1AD4\u1AFA\0\u1B0Aon\u0100;e\u1ACD\u1ACE\u403A\u0100;q\xC7\xC6\u026D\u1AD9\0\0\u1AE2a\u0100;t\u1ADE\u1ADF\u402C;\u4040\u0180;fl\u1AE8\u1AE9\u1AEB\u6201\xEE\u1160e\u0100mx\u1AF1\u1AF6ent\xBB\u1AE9e\xF3\u024D\u01E7\u1AFE\0\u1B07\u0100;d\u12BB\u1B02ot;\u6A6Dn\xF4\u0246\u0180fry\u1B10\u1B14\u1B17;\uC000\u{1D554}o\xE4\u0254\u8100\xA9;s\u0155\u1B1Dr;\u6117\u0100ao\u1B25\u1B29rr;\u61B5ss;\u6717\u0100cu\u1B32\u1B37r;\uC000\u{1D4B8}\u0100bp\u1B3C\u1B44\u0100;e\u1B41\u1B42\u6ACF;\u6AD1\u0100;e\u1B49\u1B4A\u6AD0;\u6AD2dot;\u62EF\u0380delprvw\u1B60\u1B6C\u1B77\u1B82\u1BAC\u1BD4\u1BF9arr\u0100lr\u1B68\u1B6A;\u6938;\u6935\u0270\u1B72\0\0\u1B75r;\u62DEc;\u62DFarr\u0100;p\u1B7F\u1B80\u61B6;\u693D\u0300;bcdos\u1B8F\u1B90\u1B96\u1BA1\u1BA5\u1BA8\u622Arcap;\u6A48\u0100au\u1B9B\u1B9Ep;\u6A46p;\u6A4Aot;\u628Dr;\u6A45;\uC000\u222A\uFE00\u0200alrv\u1BB5\u1BBF\u1BDE\u1BE3rr\u0100;m\u1BBC\u1BBD\u61B7;\u693Cy\u0180evw\u1BC7\u1BD4\u1BD8q\u0270\u1BCE\0\0\u1BD2re\xE3\u1B73u\xE3\u1B75ee;\u62CEedge;\u62CFen\u803B\xA4\u40A4earrow\u0100lr\u1BEE\u1BF3eft\xBB\u1B80ight\xBB\u1BBDe\xE4\u1BDD\u0100ci\u1C01\u1C07onin\xF4\u01F7nt;\u6231lcty;\u632D\u0980AHabcdefhijlorstuwz\u1C38\u1C3B\u1C3F\u1C5D\u1C69\u1C75\u1C8A\u1C9E\u1CAC\u1CB7\u1CFB\u1CFF\u1D0D\u1D7B\u1D91\u1DAB\u1DBB\u1DC6\u1DCDr\xF2\u0381ar;\u6965\u0200glrs\u1C48\u1C4D\u1C52\u1C54ger;\u6020eth;\u6138\xF2\u1133h\u0100;v\u1C5A\u1C5B\u6010\xBB\u090A\u016B\u1C61\u1C67arow;\u690Fa\xE3\u0315\u0100ay\u1C6E\u1C73ron;\u410F;\u4434\u0180;ao\u0332\u1C7C\u1C84\u0100gr\u02BF\u1C81r;\u61CAtseq;\u6A77\u0180glm\u1C91\u1C94\u1C98\u803B\xB0\u40B0ta;\u43B4ptyv;\u69B1\u0100ir\u1CA3\u1CA8sht;\u697F;\uC000\u{1D521}ar\u0100lr\u1CB3\u1CB5\xBB\u08DC\xBB\u101E\u0280aegsv\u1CC2\u0378\u1CD6\u1CDC\u1CE0m\u0180;os\u0326\u1CCA\u1CD4nd\u0100;s\u0326\u1CD1uit;\u6666amma;\u43DDin;\u62F2\u0180;io\u1CE7\u1CE8\u1CF8\u40F7de\u8100\xF7;o\u1CE7\u1CF0ntimes;\u62C7n\xF8\u1CF7cy;\u4452c\u026F\u1D06\0\0\u1D0Arn;\u631Eop;\u630D\u0280lptuw\u1D18\u1D1D\u1D22\u1D49\u1D55lar;\u4024f;\uC000\u{1D555}\u0280;emps\u030B\u1D2D\u1D37\u1D3D\u1D42q\u0100;d\u0352\u1D33ot;\u6251inus;\u6238lus;\u6214quare;\u62A1blebarwedg\xE5\xFAn\u0180adh\u112E\u1D5D\u1D67ownarrow\xF3\u1C83arpoon\u0100lr\u1D72\u1D76ef\xF4\u1CB4igh\xF4\u1CB6\u0162\u1D7F\u1D85karo\xF7\u0F42\u026F\u1D8A\0\0\u1D8Ern;\u631Fop;\u630C\u0180cot\u1D98\u1DA3\u1DA6\u0100ry\u1D9D\u1DA1;\uC000\u{1D4B9};\u4455l;\u69F6rok;\u4111\u0100dr\u1DB0\u1DB4ot;\u62F1i\u0100;f\u1DBA\u1816\u65BF\u0100ah\u1DC0\u1DC3r\xF2\u0429a\xF2\u0FA6angle;\u69A6\u0100ci\u1DD2\u1DD5y;\u445Fgrarr;\u67FF\u0900Dacdefglmnopqrstux\u1E01\u1E09\u1E19\u1E38\u0578\u1E3C\u1E49\u1E61\u1E7E\u1EA5\u1EAF\u1EBD\u1EE1\u1F2A\u1F37\u1F44\u1F4E\u1F5A\u0100Do\u1E06\u1D34o\xF4\u1C89\u0100cs\u1E0E\u1E14ute\u803B\xE9\u40E9ter;\u6A6E\u0200aioy\u1E22\u1E27\u1E31\u1E36ron;\u411Br\u0100;c\u1E2D\u1E2E\u6256\u803B\xEA\u40EAlon;\u6255;\u444Dot;\u4117\u0100Dr\u1E41\u1E45ot;\u6252;\uC000\u{1D522}\u0180;rs\u1E50\u1E51\u1E57\u6A9Aave\u803B\xE8\u40E8\u0100;d\u1E5C\u1E5D\u6A96ot;\u6A98\u0200;ils\u1E6A\u1E6B\u1E72\u1E74\u6A99nters;\u63E7;\u6113\u0100;d\u1E79\u1E7A\u6A95ot;\u6A97\u0180aps\u1E85\u1E89\u1E97cr;\u4113ty\u0180;sv\u1E92\u1E93\u1E95\u6205et\xBB\u1E93p\u01001;\u1E9D\u1EA4\u0133\u1EA1\u1EA3;\u6004;\u6005\u6003\u0100gs\u1EAA\u1EAC;\u414Bp;\u6002\u0100gp\u1EB4\u1EB8on;\u4119f;\uC000\u{1D556}\u0180als\u1EC4\u1ECE\u1ED2r\u0100;s\u1ECA\u1ECB\u62D5l;\u69E3us;\u6A71i\u0180;lv\u1EDA\u1EDB\u1EDF\u43B5on\xBB\u1EDB;\u43F5\u0200csuv\u1EEA\u1EF3\u1F0B\u1F23\u0100io\u1EEF\u1E31rc\xBB\u1E2E\u0269\u1EF9\0\0\u1EFB\xED\u0548ant\u0100gl\u1F02\u1F06tr\xBB\u1E5Dess\xBB\u1E7A\u0180aei\u1F12\u1F16\u1F1Als;\u403Dst;\u625Fv\u0100;D\u0235\u1F20D;\u6A78parsl;\u69E5\u0100Da\u1F2F\u1F33ot;\u6253rr;\u6971\u0180cdi\u1F3E\u1F41\u1EF8r;\u612Fo\xF4\u0352\u0100ah\u1F49\u1F4B;\u43B7\u803B\xF0\u40F0\u0100mr\u1F53\u1F57l\u803B\xEB\u40EBo;\u60AC\u0180cip\u1F61\u1F64\u1F67l;\u4021s\xF4\u056E\u0100eo\u1F6C\u1F74ctatio\xEE\u0559nential\xE5\u0579\u09E1\u1F92\0\u1F9E\0\u1FA1\u1FA7\0\0\u1FC6\u1FCC\0\u1FD3\0\u1FE6\u1FEA\u2000\0\u2008\u205Allingdotse\xF1\u1E44y;\u4444male;\u6640\u0180ilr\u1FAD\u1FB3\u1FC1lig;\u8000\uFB03\u0269\u1FB9\0\0\u1FBDg;\u8000\uFB00ig;\u8000\uFB04;\uC000\u{1D523}lig;\u8000\uFB01lig;\uC000fj\u0180alt\u1FD9\u1FDC\u1FE1t;\u666Dig;\u8000\uFB02ns;\u65B1of;\u4192\u01F0\u1FEE\0\u1FF3f;\uC000\u{1D557}\u0100ak\u05BF\u1FF7\u0100;v\u1FFC\u1FFD\u62D4;\u6AD9artint;\u6A0D\u0100ao\u200C\u2055\u0100cs\u2011\u2052\u03B1\u201A\u2030\u2038\u2045\u2048\0\u2050\u03B2\u2022\u2025\u2027\u202A\u202C\0\u202E\u803B\xBD\u40BD;\u6153\u803B\xBC\u40BC;\u6155;\u6159;\u615B\u01B3\u2034\0\u2036;\u6154;\u6156\u02B4\u203E\u2041\0\0\u2043\u803B\xBE\u40BE;\u6157;\u615C5;\u6158\u01B6\u204C\0\u204E;\u615A;\u615D8;\u615El;\u6044wn;\u6322cr;\uC000\u{1D4BB}\u0880Eabcdefgijlnorstv\u2082\u2089\u209F\u20A5\u20B0\u20B4\u20F0\u20F5\u20FA\u20FF\u2103\u2112\u2138\u0317\u213E\u2152\u219E\u0100;l\u064D\u2087;\u6A8C\u0180cmp\u2090\u2095\u209Dute;\u41F5ma\u0100;d\u209C\u1CDA\u43B3;\u6A86reve;\u411F\u0100iy\u20AA\u20AErc;\u411D;\u4433ot;\u4121\u0200;lqs\u063E\u0642\u20BD\u20C9\u0180;qs\u063E\u064C\u20C4lan\xF4\u0665\u0200;cdl\u0665\u20D2\u20D5\u20E5c;\u6AA9ot\u0100;o\u20DC\u20DD\u6A80\u0100;l\u20E2\u20E3\u6A82;\u6A84\u0100;e\u20EA\u20ED\uC000\u22DB\uFE00s;\u6A94r;\uC000\u{1D524}\u0100;g\u0673\u061Bmel;\u6137cy;\u4453\u0200;Eaj\u065A\u210C\u210E\u2110;\u6A92;\u6AA5;\u6AA4\u0200Eaes\u211B\u211D\u2129\u2134;\u6269p\u0100;p\u2123\u2124\u6A8Arox\xBB\u2124\u0100;q\u212E\u212F\u6A88\u0100;q\u212E\u211Bim;\u62E7pf;\uC000\u{1D558}\u0100ci\u2143\u2146r;\u610Am\u0180;el\u066B\u214E\u2150;\u6A8E;\u6A90\u8300>;cdlqr\u05EE\u2160\u216A\u216E\u2173\u2179\u0100ci\u2165\u2167;\u6AA7r;\u6A7Aot;\u62D7Par;\u6995uest;\u6A7C\u0280adels\u2184\u216A\u2190\u0656\u219B\u01F0\u2189\0\u218Epro\xF8\u209Er;\u6978q\u0100lq\u063F\u2196les\xF3\u2088i\xED\u066B\u0100en\u21A3\u21ADrtneqq;\uC000\u2269\uFE00\xC5\u21AA\u0500Aabcefkosy\u21C4\u21C7\u21F1\u21F5\u21FA\u2218\u221D\u222F\u2268\u227Dr\xF2\u03A0\u0200ilmr\u21D0\u21D4\u21D7\u21DBrs\xF0\u1484f\xBB\u2024il\xF4\u06A9\u0100dr\u21E0\u21E4cy;\u444A\u0180;cw\u08F4\u21EB\u21EFir;\u6948;\u61ADar;\u610Firc;\u4125\u0180alr\u2201\u220E\u2213rts\u0100;u\u2209\u220A\u6665it\xBB\u220Alip;\u6026con;\u62B9r;\uC000\u{1D525}s\u0100ew\u2223\u2229arow;\u6925arow;\u6926\u0280amopr\u223A\u223E\u2243\u225E\u2263rr;\u61FFtht;\u623Bk\u0100lr\u2249\u2253eftarrow;\u61A9ightarrow;\u61AAf;\uC000\u{1D559}bar;\u6015\u0180clt\u226F\u2274\u2278r;\uC000\u{1D4BD}as\xE8\u21F4rok;\u4127\u0100bp\u2282\u2287ull;\u6043hen\xBB\u1C5B\u0AE1\u22A3\0\u22AA\0\u22B8\u22C5\u22CE\0\u22D5\u22F3\0\0\u22F8\u2322\u2367\u2362\u237F\0\u2386\u23AA\u23B4cute\u803B\xED\u40ED\u0180;iy\u0771\u22B0\u22B5rc\u803B\xEE\u40EE;\u4438\u0100cx\u22BC\u22BFy;\u4435cl\u803B\xA1\u40A1\u0100fr\u039F\u22C9;\uC000\u{1D526}rave\u803B\xEC\u40EC\u0200;ino\u073E\u22DD\u22E9\u22EE\u0100in\u22E2\u22E6nt;\u6A0Ct;\u622Dfin;\u69DCta;\u6129lig;\u4133\u0180aop\u22FE\u231A\u231D\u0180cgt\u2305\u2308\u2317r;\u412B\u0180elp\u071F\u230F\u2313in\xE5\u078Ear\xF4\u0720h;\u4131f;\u62B7ed;\u41B5\u0280;cfot\u04F4\u232C\u2331\u233D\u2341are;\u6105in\u0100;t\u2338\u2339\u621Eie;\u69DDdo\xF4\u2319\u0280;celp\u0757\u234C\u2350\u235B\u2361al;\u62BA\u0100gr\u2355\u2359er\xF3\u1563\xE3\u234Darhk;\u6A17rod;\u6A3C\u0200cgpt\u236F\u2372\u2376\u237By;\u4451on;\u412Ff;\uC000\u{1D55A}a;\u43B9uest\u803B\xBF\u40BF\u0100ci\u238A\u238Fr;\uC000\u{1D4BE}n\u0280;Edsv\u04F4\u239B\u239D\u23A1\u04F3;\u62F9ot;\u62F5\u0100;v\u23A6\u23A7\u62F4;\u62F3\u0100;i\u0777\u23AElde;\u4129\u01EB\u23B8\0\u23BCcy;\u4456l\u803B\xEF\u40EF\u0300cfmosu\u23CC\u23D7\u23DC\u23E1\u23E7\u23F5\u0100iy\u23D1\u23D5rc;\u4135;\u4439r;\uC000\u{1D527}ath;\u4237pf;\uC000\u{1D55B}\u01E3\u23EC\0\u23F1r;\uC000\u{1D4BF}rcy;\u4458kcy;\u4454\u0400acfghjos\u240B\u2416\u2422\u2427\u242D\u2431\u2435\u243Bppa\u0100;v\u2413\u2414\u43BA;\u43F0\u0100ey\u241B\u2420dil;\u4137;\u443Ar;\uC000\u{1D528}reen;\u4138cy;\u4445cy;\u445Cpf;\uC000\u{1D55C}cr;\uC000\u{1D4C0}\u0B80ABEHabcdefghjlmnoprstuv\u2470\u2481\u2486\u248D\u2491\u250E\u253D\u255A\u2580\u264E\u265E\u2665\u2679\u267D\u269A\u26B2\u26D8\u275D\u2768\u278B\u27C0\u2801\u2812\u0180art\u2477\u247A\u247Cr\xF2\u09C6\xF2\u0395ail;\u691Barr;\u690E\u0100;g\u0994\u248B;\u6A8Bar;\u6962\u0963\u24A5\0\u24AA\0\u24B1\0\0\0\0\0\u24B5\u24BA\0\u24C6\u24C8\u24CD\0\u24F9ute;\u413Amptyv;\u69B4ra\xEE\u084Cbda;\u43BBg\u0180;dl\u088E\u24C1\u24C3;\u6991\xE5\u088E;\u6A85uo\u803B\xAB\u40ABr\u0400;bfhlpst\u0899\u24DE\u24E6\u24E9\u24EB\u24EE\u24F1\u24F5\u0100;f\u089D\u24E3s;\u691Fs;\u691D\xEB\u2252p;\u61ABl;\u6939im;\u6973l;\u61A2\u0180;ae\u24FF\u2500\u2504\u6AABil;\u6919\u0100;s\u2509\u250A\u6AAD;\uC000\u2AAD\uFE00\u0180abr\u2515\u2519\u251Drr;\u690Crk;\u6772\u0100ak\u2522\u252Cc\u0100ek\u2528\u252A;\u407B;\u405B\u0100es\u2531\u2533;\u698Bl\u0100du\u2539\u253B;\u698F;\u698D\u0200aeuy\u2546\u254B\u2556\u2558ron;\u413E\u0100di\u2550\u2554il;\u413C\xEC\u08B0\xE2\u2529;\u443B\u0200cqrs\u2563\u2566\u256D\u257Da;\u6936uo\u0100;r\u0E19\u1746\u0100du\u2572\u2577har;\u6967shar;\u694Bh;\u61B2\u0280;fgqs\u258B\u258C\u0989\u25F3\u25FF\u6264t\u0280ahlrt\u2598\u25A4\u25B7\u25C2\u25E8rrow\u0100;t\u0899\u25A1a\xE9\u24F6arpoon\u0100du\u25AF\u25B4own\xBB\u045Ap\xBB\u0966eftarrows;\u61C7ight\u0180ahs\u25CD\u25D6\u25DErrow\u0100;s\u08F4\u08A7arpoon\xF3\u0F98quigarro\xF7\u21F0hreetimes;\u62CB\u0180;qs\u258B\u0993\u25FAlan\xF4\u09AC\u0280;cdgs\u09AC\u260A\u260D\u261D\u2628c;\u6AA8ot\u0100;o\u2614\u2615\u6A7F\u0100;r\u261A\u261B\u6A81;\u6A83\u0100;e\u2622\u2625\uC000\u22DA\uFE00s;\u6A93\u0280adegs\u2633\u2639\u263D\u2649\u264Bppro\xF8\u24C6ot;\u62D6q\u0100gq\u2643\u2645\xF4\u0989gt\xF2\u248C\xF4\u099Bi\xED\u09B2\u0180ilr\u2655\u08E1\u265Asht;\u697C;\uC000\u{1D529}\u0100;E\u099C\u2663;\u6A91\u0161\u2669\u2676r\u0100du\u25B2\u266E\u0100;l\u0965\u2673;\u696Alk;\u6584cy;\u4459\u0280;acht\u0A48\u2688\u268B\u2691\u2696r\xF2\u25C1orne\xF2\u1D08ard;\u696Bri;\u65FA\u0100io\u269F\u26A4dot;\u4140ust\u0100;a\u26AC\u26AD\u63B0che\xBB\u26AD\u0200Eaes\u26BB\u26BD\u26C9\u26D4;\u6268p\u0100;p\u26C3\u26C4\u6A89rox\xBB\u26C4\u0100;q\u26CE\u26CF\u6A87\u0100;q\u26CE\u26BBim;\u62E6\u0400abnoptwz\u26E9\u26F4\u26F7\u271A\u272F\u2741\u2747\u2750\u0100nr\u26EE\u26F1g;\u67ECr;\u61FDr\xEB\u08C1g\u0180lmr\u26FF\u270D\u2714eft\u0100ar\u09E6\u2707ight\xE1\u09F2apsto;\u67FCight\xE1\u09FDparrow\u0100lr\u2725\u2729ef\xF4\u24EDight;\u61AC\u0180afl\u2736\u2739\u273Dr;\u6985;\uC000\u{1D55D}us;\u6A2Dimes;\u6A34\u0161\u274B\u274Fst;\u6217\xE1\u134E\u0180;ef\u2757\u2758\u1800\u65CAnge\xBB\u2758ar\u0100;l\u2764\u2765\u4028t;\u6993\u0280achmt\u2773\u2776\u277C\u2785\u2787r\xF2\u08A8orne\xF2\u1D8Car\u0100;d\u0F98\u2783;\u696D;\u600Eri;\u62BF\u0300achiqt\u2798\u279D\u0A40\u27A2\u27AE\u27BBquo;\u6039r;\uC000\u{1D4C1}m\u0180;eg\u09B2\u27AA\u27AC;\u6A8D;\u6A8F\u0100bu\u252A\u27B3o\u0100;r\u0E1F\u27B9;\u601Arok;\u4142\u8400<;cdhilqr\u082B\u27D2\u2639\u27DC\u27E0\u27E5\u27EA\u27F0\u0100ci\u27D7\u27D9;\u6AA6r;\u6A79re\xE5\u25F2mes;\u62C9arr;\u6976uest;\u6A7B\u0100Pi\u27F5\u27F9ar;\u6996\u0180;ef\u2800\u092D\u181B\u65C3r\u0100du\u2807\u280Dshar;\u694Ahar;\u6966\u0100en\u2817\u2821rtneqq;\uC000\u2268\uFE00\xC5\u281E\u0700Dacdefhilnopsu\u2840\u2845\u2882\u288E\u2893\u28A0\u28A5\u28A8\u28DA\u28E2\u28E4\u0A83\u28F3\u2902Dot;\u623A\u0200clpr\u284E\u2852\u2863\u287Dr\u803B\xAF\u40AF\u0100et\u2857\u2859;\u6642\u0100;e\u285E\u285F\u6720se\xBB\u285F\u0100;s\u103B\u2868to\u0200;dlu\u103B\u2873\u2877\u287Bow\xEE\u048Cef\xF4\u090F\xF0\u13D1ker;\u65AE\u0100oy\u2887\u288Cmma;\u6A29;\u443Cash;\u6014asuredangle\xBB\u1626r;\uC000\u{1D52A}o;\u6127\u0180cdn\u28AF\u28B4\u28C9ro\u803B\xB5\u40B5\u0200;acd\u1464\u28BD\u28C0\u28C4s\xF4\u16A7ir;\u6AF0ot\u80BB\xB7\u01B5us\u0180;bd\u28D2\u1903\u28D3\u6212\u0100;u\u1D3C\u28D8;\u6A2A\u0163\u28DE\u28E1p;\u6ADB\xF2\u2212\xF0\u0A81\u0100dp\u28E9\u28EEels;\u62A7f;\uC000\u{1D55E}\u0100ct\u28F8\u28FDr;\uC000\u{1D4C2}pos\xBB\u159D\u0180;lm\u2909\u290A\u290D\u43BCtimap;\u62B8\u0C00GLRVabcdefghijlmoprstuvw\u2942\u2953\u297E\u2989\u2998\u29DA\u29E9\u2A15\u2A1A\u2A58\u2A5D\u2A83\u2A95\u2AA4\u2AA8\u2B04\u2B07\u2B44\u2B7F\u2BAE\u2C34\u2C67\u2C7C\u2CE9\u0100gt\u2947\u294B;\uC000\u22D9\u0338\u0100;v\u2950\u0BCF\uC000\u226B\u20D2\u0180elt\u295A\u2972\u2976ft\u0100ar\u2961\u2967rrow;\u61CDightarrow;\u61CE;\uC000\u22D8\u0338\u0100;v\u297B\u0C47\uC000\u226A\u20D2ightarrow;\u61CF\u0100Dd\u298E\u2993ash;\u62AFash;\u62AE\u0280bcnpt\u29A3\u29A7\u29AC\u29B1\u29CCla\xBB\u02DEute;\u4144g;\uC000\u2220\u20D2\u0280;Eiop\u0D84\u29BC\u29C0\u29C5\u29C8;\uC000\u2A70\u0338d;\uC000\u224B\u0338s;\u4149ro\xF8\u0D84ur\u0100;a\u29D3\u29D4\u666El\u0100;s\u29D3\u0B38\u01F3\u29DF\0\u29E3p\u80BB\xA0\u0B37mp\u0100;e\u0BF9\u0C00\u0280aeouy\u29F4\u29FE\u2A03\u2A10\u2A13\u01F0\u29F9\0\u29FB;\u6A43on;\u4148dil;\u4146ng\u0100;d\u0D7E\u2A0Aot;\uC000\u2A6D\u0338p;\u6A42;\u443Dash;\u6013\u0380;Aadqsx\u0B92\u2A29\u2A2D\u2A3B\u2A41\u2A45\u2A50rr;\u61D7r\u0100hr\u2A33\u2A36k;\u6924\u0100;o\u13F2\u13F0ot;\uC000\u2250\u0338ui\xF6\u0B63\u0100ei\u2A4A\u2A4Ear;\u6928\xED\u0B98ist\u0100;s\u0BA0\u0B9Fr;\uC000\u{1D52B}\u0200Eest\u0BC5\u2A66\u2A79\u2A7C\u0180;qs\u0BBC\u2A6D\u0BE1\u0180;qs\u0BBC\u0BC5\u2A74lan\xF4\u0BE2i\xED\u0BEA\u0100;r\u0BB6\u2A81\xBB\u0BB7\u0180Aap\u2A8A\u2A8D\u2A91r\xF2\u2971rr;\u61AEar;\u6AF2\u0180;sv\u0F8D\u2A9C\u0F8C\u0100;d\u2AA1\u2AA2\u62FC;\u62FAcy;\u445A\u0380AEadest\u2AB7\u2ABA\u2ABE\u2AC2\u2AC5\u2AF6\u2AF9r\xF2\u2966;\uC000\u2266\u0338rr;\u619Ar;\u6025\u0200;fqs\u0C3B\u2ACE\u2AE3\u2AEFt\u0100ar\u2AD4\u2AD9rro\xF7\u2AC1ightarro\xF7\u2A90\u0180;qs\u0C3B\u2ABA\u2AEAlan\xF4\u0C55\u0100;s\u0C55\u2AF4\xBB\u0C36i\xED\u0C5D\u0100;r\u0C35\u2AFEi\u0100;e\u0C1A\u0C25i\xE4\u0D90\u0100pt\u2B0C\u2B11f;\uC000\u{1D55F}\u8180\xAC;in\u2B19\u2B1A\u2B36\u40ACn\u0200;Edv\u0B89\u2B24\u2B28\u2B2E;\uC000\u22F9\u0338ot;\uC000\u22F5\u0338\u01E1\u0B89\u2B33\u2B35;\u62F7;\u62F6i\u0100;v\u0CB8\u2B3C\u01E1\u0CB8\u2B41\u2B43;\u62FE;\u62FD\u0180aor\u2B4B\u2B63\u2B69r\u0200;ast\u0B7B\u2B55\u2B5A\u2B5Flle\xEC\u0B7Bl;\uC000\u2AFD\u20E5;\uC000\u2202\u0338lint;\u6A14\u0180;ce\u0C92\u2B70\u2B73u\xE5\u0CA5\u0100;c\u0C98\u2B78\u0100;e\u0C92\u2B7D\xF1\u0C98\u0200Aait\u2B88\u2B8B\u2B9D\u2BA7r\xF2\u2988rr\u0180;cw\u2B94\u2B95\u2B99\u619B;\uC000\u2933\u0338;\uC000\u219D\u0338ghtarrow\xBB\u2B95ri\u0100;e\u0CCB\u0CD6\u0380chimpqu\u2BBD\u2BCD\u2BD9\u2B04\u0B78\u2BE4\u2BEF\u0200;cer\u0D32\u2BC6\u0D37\u2BC9u\xE5\u0D45;\uC000\u{1D4C3}ort\u026D\u2B05\0\0\u2BD6ar\xE1\u2B56m\u0100;e\u0D6E\u2BDF\u0100;q\u0D74\u0D73su\u0100bp\u2BEB\u2BED\xE5\u0CF8\xE5\u0D0B\u0180bcp\u2BF6\u2C11\u2C19\u0200;Ees\u2BFF\u2C00\u0D22\u2C04\u6284;\uC000\u2AC5\u0338et\u0100;e\u0D1B\u2C0Bq\u0100;q\u0D23\u2C00c\u0100;e\u0D32\u2C17\xF1\u0D38\u0200;Ees\u2C22\u2C23\u0D5F\u2C27\u6285;\uC000\u2AC6\u0338et\u0100;e\u0D58\u2C2Eq\u0100;q\u0D60\u2C23\u0200gilr\u2C3D\u2C3F\u2C45\u2C47\xEC\u0BD7lde\u803B\xF1\u40F1\xE7\u0C43iangle\u0100lr\u2C52\u2C5Ceft\u0100;e\u0C1A\u2C5A\xF1\u0C26ight\u0100;e\u0CCB\u2C65\xF1\u0CD7\u0100;m\u2C6C\u2C6D\u43BD\u0180;es\u2C74\u2C75\u2C79\u4023ro;\u6116p;\u6007\u0480DHadgilrs\u2C8F\u2C94\u2C99\u2C9E\u2CA3\u2CB0\u2CB6\u2CD3\u2CE3ash;\u62ADarr;\u6904p;\uC000\u224D\u20D2ash;\u62AC\u0100et\u2CA8\u2CAC;\uC000\u2265\u20D2;\uC000>\u20D2nfin;\u69DE\u0180Aet\u2CBD\u2CC1\u2CC5rr;\u6902;\uC000\u2264\u20D2\u0100;r\u2CCA\u2CCD\uC000<\u20D2ie;\uC000\u22B4\u20D2\u0100At\u2CD8\u2CDCrr;\u6903rie;\uC000\u22B5\u20D2im;\uC000\u223C\u20D2\u0180Aan\u2CF0\u2CF4\u2D02rr;\u61D6r\u0100hr\u2CFA\u2CFDk;\u6923\u0100;o\u13E7\u13E5ear;\u6927\u1253\u1A95\0\0\0\0\0\0\0\0\0\0\0\0\0\u2D2D\0\u2D38\u2D48\u2D60\u2D65\u2D72\u2D84\u1B07\0\0\u2D8D\u2DAB\0\u2DC8\u2DCE\0\u2DDC\u2E19\u2E2B\u2E3E\u2E43\u0100cs\u2D31\u1A97ute\u803B\xF3\u40F3\u0100iy\u2D3C\u2D45r\u0100;c\u1A9E\u2D42\u803B\xF4\u40F4;\u443E\u0280abios\u1AA0\u2D52\u2D57\u01C8\u2D5Alac;\u4151v;\u6A38old;\u69BClig;\u4153\u0100cr\u2D69\u2D6Dir;\u69BF;\uC000\u{1D52C}\u036F\u2D79\0\0\u2D7C\0\u2D82n;\u42DBave\u803B\xF2\u40F2;\u69C1\u0100bm\u2D88\u0DF4ar;\u69B5\u0200acit\u2D95\u2D98\u2DA5\u2DA8r\xF2\u1A80\u0100ir\u2D9D\u2DA0r;\u69BEoss;\u69BBn\xE5\u0E52;\u69C0\u0180aei\u2DB1\u2DB5\u2DB9cr;\u414Dga;\u43C9\u0180cdn\u2DC0\u2DC5\u01CDron;\u43BF;\u69B6pf;\uC000\u{1D560}\u0180ael\u2DD4\u2DD7\u01D2r;\u69B7rp;\u69B9\u0380;adiosv\u2DEA\u2DEB\u2DEE\u2E08\u2E0D\u2E10\u2E16\u6228r\xF2\u1A86\u0200;efm\u2DF7\u2DF8\u2E02\u2E05\u6A5Dr\u0100;o\u2DFE\u2DFF\u6134f\xBB\u2DFF\u803B\xAA\u40AA\u803B\xBA\u40BAgof;\u62B6r;\u6A56lope;\u6A57;\u6A5B\u0180clo\u2E1F\u2E21\u2E27\xF2\u2E01ash\u803B\xF8\u40F8l;\u6298i\u016C\u2E2F\u2E34de\u803B\xF5\u40F5es\u0100;a\u01DB\u2E3As;\u6A36ml\u803B\xF6\u40F6bar;\u633D\u0AE1\u2E5E\0\u2E7D\0\u2E80\u2E9D\0\u2EA2\u2EB9\0\0\u2ECB\u0E9C\0\u2F13\0\0\u2F2B\u2FBC\0\u2FC8r\u0200;ast\u0403\u2E67\u2E72\u0E85\u8100\xB6;l\u2E6D\u2E6E\u40B6le\xEC\u0403\u0269\u2E78\0\0\u2E7Bm;\u6AF3;\u6AFDy;\u443Fr\u0280cimpt\u2E8B\u2E8F\u2E93\u1865\u2E97nt;\u4025od;\u402Eil;\u6030enk;\u6031r;\uC000\u{1D52D}\u0180imo\u2EA8\u2EB0\u2EB4\u0100;v\u2EAD\u2EAE\u43C6;\u43D5ma\xF4\u0A76ne;\u660E\u0180;tv\u2EBF\u2EC0\u2EC8\u43C0chfork\xBB\u1FFD;\u43D6\u0100au\u2ECF\u2EDFn\u0100ck\u2ED5\u2EDDk\u0100;h\u21F4\u2EDB;\u610E\xF6\u21F4s\u0480;abcdemst\u2EF3\u2EF4\u1908\u2EF9\u2EFD\u2F04\u2F06\u2F0A\u2F0E\u402Bcir;\u6A23ir;\u6A22\u0100ou\u1D40\u2F02;\u6A25;\u6A72n\u80BB\xB1\u0E9Dim;\u6A26wo;\u6A27\u0180ipu\u2F19\u2F20\u2F25ntint;\u6A15f;\uC000\u{1D561}nd\u803B\xA3\u40A3\u0500;Eaceinosu\u0EC8\u2F3F\u2F41\u2F44\u2F47\u2F81\u2F89\u2F92\u2F7E\u2FB6;\u6AB3p;\u6AB7u\xE5\u0ED9\u0100;c\u0ECE\u2F4C\u0300;acens\u0EC8\u2F59\u2F5F\u2F66\u2F68\u2F7Eppro\xF8\u2F43urlye\xF1\u0ED9\xF1\u0ECE\u0180aes\u2F6F\u2F76\u2F7Approx;\u6AB9qq;\u6AB5im;\u62E8i\xED\u0EDFme\u0100;s\u2F88\u0EAE\u6032\u0180Eas\u2F78\u2F90\u2F7A\xF0\u2F75\u0180dfp\u0EEC\u2F99\u2FAF\u0180als\u2FA0\u2FA5\u2FAAlar;\u632Eine;\u6312urf;\u6313\u0100;t\u0EFB\u2FB4\xEF\u0EFBrel;\u62B0\u0100ci\u2FC0\u2FC5r;\uC000\u{1D4C5};\u43C8ncsp;\u6008\u0300fiopsu\u2FDA\u22E2\u2FDF\u2FE5\u2FEB\u2FF1r;\uC000\u{1D52E}pf;\uC000\u{1D562}rime;\u6057cr;\uC000\u{1D4C6}\u0180aeo\u2FF8\u3009\u3013t\u0100ei\u2FFE\u3005rnion\xF3\u06B0nt;\u6A16st\u0100;e\u3010\u3011\u403F\xF1\u1F19\xF4\u0F14\u0A80ABHabcdefhilmnoprstux\u3040\u3051\u3055\u3059\u30E0\u310E\u312B\u3147\u3162\u3172\u318E\u3206\u3215\u3224\u3229\u3258\u326E\u3272\u3290\u32B0\u32B7\u0180art\u3047\u304A\u304Cr\xF2\u10B3\xF2\u03DDail;\u691Car\xF2\u1C65ar;\u6964\u0380cdenqrt\u3068\u3075\u3078\u307F\u308F\u3094\u30CC\u0100eu\u306D\u3071;\uC000\u223D\u0331te;\u4155i\xE3\u116Emptyv;\u69B3g\u0200;del\u0FD1\u3089\u308B\u308D;\u6992;\u69A5\xE5\u0FD1uo\u803B\xBB\u40BBr\u0580;abcfhlpstw\u0FDC\u30AC\u30AF\u30B7\u30B9\u30BC\u30BE\u30C0\u30C3\u30C7\u30CAp;\u6975\u0100;f\u0FE0\u30B4s;\u6920;\u6933s;\u691E\xEB\u225D\xF0\u272El;\u6945im;\u6974l;\u61A3;\u619D\u0100ai\u30D1\u30D5il;\u691Ao\u0100;n\u30DB\u30DC\u6236al\xF3\u0F1E\u0180abr\u30E7\u30EA\u30EEr\xF2\u17E5rk;\u6773\u0100ak\u30F3\u30FDc\u0100ek\u30F9\u30FB;\u407D;\u405D\u0100es\u3102\u3104;\u698Cl\u0100du\u310A\u310C;\u698E;\u6990\u0200aeuy\u3117\u311C\u3127\u3129ron;\u4159\u0100di\u3121\u3125il;\u4157\xEC\u0FF2\xE2\u30FA;\u4440\u0200clqs\u3134\u3137\u313D\u3144a;\u6937dhar;\u6969uo\u0100;r\u020E\u020Dh;\u61B3\u0180acg\u314E\u315F\u0F44l\u0200;ips\u0F78\u3158\u315B\u109Cn\xE5\u10BBar\xF4\u0FA9t;\u65AD\u0180ilr\u3169\u1023\u316Esht;\u697D;\uC000\u{1D52F}\u0100ao\u3177\u3186r\u0100du\u317D\u317F\xBB\u047B\u0100;l\u1091\u3184;\u696C\u0100;v\u318B\u318C\u43C1;\u43F1\u0180gns\u3195\u31F9\u31FCht\u0300ahlrst\u31A4\u31B0\u31C2\u31D8\u31E4\u31EErrow\u0100;t\u0FDC\u31ADa\xE9\u30C8arpoon\u0100du\u31BB\u31BFow\xEE\u317Ep\xBB\u1092eft\u0100ah\u31CA\u31D0rrow\xF3\u0FEAarpoon\xF3\u0551ightarrows;\u61C9quigarro\xF7\u30CBhreetimes;\u62CCg;\u42DAingdotse\xF1\u1F32\u0180ahm\u320D\u3210\u3213r\xF2\u0FEAa\xF2\u0551;\u600Foust\u0100;a\u321E\u321F\u63B1che\xBB\u321Fmid;\u6AEE\u0200abpt\u3232\u323D\u3240\u3252\u0100nr\u3237\u323Ag;\u67EDr;\u61FEr\xEB\u1003\u0180afl\u3247\u324A\u324Er;\u6986;\uC000\u{1D563}us;\u6A2Eimes;\u6A35\u0100ap\u325D\u3267r\u0100;g\u3263\u3264\u4029t;\u6994olint;\u6A12ar\xF2\u31E3\u0200achq\u327B\u3280\u10BC\u3285quo;\u603Ar;\uC000\u{1D4C7}\u0100bu\u30FB\u328Ao\u0100;r\u0214\u0213\u0180hir\u3297\u329B\u32A0re\xE5\u31F8mes;\u62CAi\u0200;efl\u32AA\u1059\u1821\u32AB\u65B9tri;\u69CEluhar;\u6968;\u611E\u0D61\u32D5\u32DB\u32DF\u332C\u3338\u3371\0\u337A\u33A4\0\0\u33EC\u33F0\0\u3428\u3448\u345A\u34AD\u34B1\u34CA\u34F1\0\u3616\0\0\u3633cute;\u415Bqu\xEF\u27BA\u0500;Eaceinpsy\u11ED\u32F3\u32F5\u32FF\u3302\u330B\u330F\u331F\u3326\u3329;\u6AB4\u01F0\u32FA\0\u32FC;\u6AB8on;\u4161u\xE5\u11FE\u0100;d\u11F3\u3307il;\u415Frc;\u415D\u0180Eas\u3316\u3318\u331B;\u6AB6p;\u6ABAim;\u62E9olint;\u6A13i\xED\u1204;\u4441ot\u0180;be\u3334\u1D47\u3335\u62C5;\u6A66\u0380Aacmstx\u3346\u334A\u3357\u335B\u335E\u3363\u336Drr;\u61D8r\u0100hr\u3350\u3352\xEB\u2228\u0100;o\u0A36\u0A34t\u803B\xA7\u40A7i;\u403Bwar;\u6929m\u0100in\u3369\xF0nu\xF3\xF1t;\u6736r\u0100;o\u3376\u2055\uC000\u{1D530}\u0200acoy\u3382\u3386\u3391\u33A0rp;\u666F\u0100hy\u338B\u338Fcy;\u4449;\u4448rt\u026D\u3399\0\0\u339Ci\xE4\u1464ara\xEC\u2E6F\u803B\xAD\u40AD\u0100gm\u33A8\u33B4ma\u0180;fv\u33B1\u33B2\u33B2\u43C3;\u43C2\u0400;deglnpr\u12AB\u33C5\u33C9\u33CE\u33D6\u33DE\u33E1\u33E6ot;\u6A6A\u0100;q\u12B1\u12B0\u0100;E\u33D3\u33D4\u6A9E;\u6AA0\u0100;E\u33DB\u33DC\u6A9D;\u6A9Fe;\u6246lus;\u6A24arr;\u6972ar\xF2\u113D\u0200aeit\u33F8\u3408\u340F\u3417\u0100ls\u33FD\u3404lsetm\xE9\u336Ahp;\u6A33parsl;\u69E4\u0100dl\u1463\u3414e;\u6323\u0100;e\u341C\u341D\u6AAA\u0100;s\u3422\u3423\u6AAC;\uC000\u2AAC\uFE00\u0180flp\u342E\u3433\u3442tcy;\u444C\u0100;b\u3438\u3439\u402F\u0100;a\u343E\u343F\u69C4r;\u633Ff;\uC000\u{1D564}a\u0100dr\u344D\u0402es\u0100;u\u3454\u3455\u6660it\xBB\u3455\u0180csu\u3460\u3479\u349F\u0100au\u3465\u346Fp\u0100;s\u1188\u346B;\uC000\u2293\uFE00p\u0100;s\u11B4\u3475;\uC000\u2294\uFE00u\u0100bp\u347F\u348F\u0180;es\u1197\u119C\u3486et\u0100;e\u1197\u348D\xF1\u119D\u0180;es\u11A8\u11AD\u3496et\u0100;e\u11A8\u349D\xF1\u11AE\u0180;af\u117B\u34A6\u05B0r\u0165\u34AB\u05B1\xBB\u117Car\xF2\u1148\u0200cemt\u34B9\u34BE\u34C2\u34C5r;\uC000\u{1D4C8}tm\xEE\xF1i\xEC\u3415ar\xE6\u11BE\u0100ar\u34CE\u34D5r\u0100;f\u34D4\u17BF\u6606\u0100an\u34DA\u34EDight\u0100ep\u34E3\u34EApsilo\xEE\u1EE0h\xE9\u2EAFs\xBB\u2852\u0280bcmnp\u34FB\u355E\u1209\u358B\u358E\u0480;Edemnprs\u350E\u350F\u3511\u3515\u351E\u3523\u352C\u3531\u3536\u6282;\u6AC5ot;\u6ABD\u0100;d\u11DA\u351Aot;\u6AC3ult;\u6AC1\u0100Ee\u3528\u352A;\u6ACB;\u628Alus;\u6ABFarr;\u6979\u0180eiu\u353D\u3552\u3555t\u0180;en\u350E\u3545\u354Bq\u0100;q\u11DA\u350Feq\u0100;q\u352B\u3528m;\u6AC7\u0100bp\u355A\u355C;\u6AD5;\u6AD3c\u0300;acens\u11ED\u356C\u3572\u3579\u357B\u3326ppro\xF8\u32FAurlye\xF1\u11FE\xF1\u11F3\u0180aes\u3582\u3588\u331Bppro\xF8\u331Aq\xF1\u3317g;\u666A\u0680123;Edehlmnps\u35A9\u35AC\u35AF\u121C\u35B2\u35B4\u35C0\u35C9\u35D5\u35DA\u35DF\u35E8\u35ED\u803B\xB9\u40B9\u803B\xB2\u40B2\u803B\xB3\u40B3;\u6AC6\u0100os\u35B9\u35BCt;\u6ABEub;\u6AD8\u0100;d\u1222\u35C5ot;\u6AC4s\u0100ou\u35CF\u35D2l;\u67C9b;\u6AD7arr;\u697Bult;\u6AC2\u0100Ee\u35E4\u35E6;\u6ACC;\u628Blus;\u6AC0\u0180eiu\u35F4\u3609\u360Ct\u0180;en\u121C\u35FC\u3602q\u0100;q\u1222\u35B2eq\u0100;q\u35E7\u35E4m;\u6AC8\u0100bp\u3611\u3613;\u6AD4;\u6AD6\u0180Aan\u361C\u3620\u362Drr;\u61D9r\u0100hr\u3626\u3628\xEB\u222E\u0100;o\u0A2B\u0A29war;\u692Alig\u803B\xDF\u40DF\u0BE1\u3651\u365D\u3660\u12CE\u3673\u3679\0\u367E\u36C2\0\0\0\0\0\u36DB\u3703\0\u3709\u376C\0\0\0\u3787\u0272\u3656\0\0\u365Bget;\u6316;\u43C4r\xEB\u0E5F\u0180aey\u3666\u366B\u3670ron;\u4165dil;\u4163;\u4442lrec;\u6315r;\uC000\u{1D531}\u0200eiko\u3686\u369D\u36B5\u36BC\u01F2\u368B\0\u3691e\u01004f\u1284\u1281a\u0180;sv\u3698\u3699\u369B\u43B8ym;\u43D1\u0100cn\u36A2\u36B2k\u0100as\u36A8\u36AEppro\xF8\u12C1im\xBB\u12ACs\xF0\u129E\u0100as\u36BA\u36AE\xF0\u12C1rn\u803B\xFE\u40FE\u01EC\u031F\u36C6\u22E7es\u8180\xD7;bd\u36CF\u36D0\u36D8\u40D7\u0100;a\u190F\u36D5r;\u6A31;\u6A30\u0180eps\u36E1\u36E3\u3700\xE1\u2A4D\u0200;bcf\u0486\u36EC\u36F0\u36F4ot;\u6336ir;\u6AF1\u0100;o\u36F9\u36FC\uC000\u{1D565}rk;\u6ADA\xE1\u3362rime;\u6034\u0180aip\u370F\u3712\u3764d\xE5\u1248\u0380adempst\u3721\u374D\u3740\u3751\u3757\u375C\u375Fngle\u0280;dlqr\u3730\u3731\u3736\u3740\u3742\u65B5own\xBB\u1DBBeft\u0100;e\u2800\u373E\xF1\u092E;\u625Cight\u0100;e\u32AA\u374B\xF1\u105Aot;\u65ECinus;\u6A3Alus;\u6A39b;\u69CDime;\u6A3Bezium;\u63E2\u0180cht\u3772\u377D\u3781\u0100ry\u3777\u377B;\uC000\u{1D4C9};\u4446cy;\u445Brok;\u4167\u0100io\u378B\u378Ex\xF4\u1777head\u0100lr\u3797\u37A0eftarro\xF7\u084Fightarrow\xBB\u0F5D\u0900AHabcdfghlmoprstuw\u37D0\u37D3\u37D7\u37E4\u37F0\u37FC\u380E\u381C\u3823\u3834\u3851\u385D\u386B\u38A9\u38CC\u38D2\u38EA\u38F6r\xF2\u03EDar;\u6963\u0100cr\u37DC\u37E2ute\u803B\xFA\u40FA\xF2\u1150r\u01E3\u37EA\0\u37EDy;\u445Eve;\u416D\u0100iy\u37F5\u37FArc\u803B\xFB\u40FB;\u4443\u0180abh\u3803\u3806\u380Br\xF2\u13ADlac;\u4171a\xF2\u13C3\u0100ir\u3813\u3818sht;\u697E;\uC000\u{1D532}rave\u803B\xF9\u40F9\u0161\u3827\u3831r\u0100lr\u382C\u382E\xBB\u0957\xBB\u1083lk;\u6580\u0100ct\u3839\u384D\u026F\u383F\0\0\u384Arn\u0100;e\u3845\u3846\u631Cr\xBB\u3846op;\u630Fri;\u65F8\u0100al\u3856\u385Acr;\u416B\u80BB\xA8\u0349\u0100gp\u3862\u3866on;\u4173f;\uC000\u{1D566}\u0300adhlsu\u114B\u3878\u387D\u1372\u3891\u38A0own\xE1\u13B3arpoon\u0100lr\u3888\u388Cef\xF4\u382Digh\xF4\u382Fi\u0180;hl\u3899\u389A\u389C\u43C5\xBB\u13FAon\xBB\u389Aparrows;\u61C8\u0180cit\u38B0\u38C4\u38C8\u026F\u38B6\0\0\u38C1rn\u0100;e\u38BC\u38BD\u631Dr\xBB\u38BDop;\u630Eng;\u416Fri;\u65F9cr;\uC000\u{1D4CA}\u0180dir\u38D9\u38DD\u38E2ot;\u62F0lde;\u4169i\u0100;f\u3730\u38E8\xBB\u1813\u0100am\u38EF\u38F2r\xF2\u38A8l\u803B\xFC\u40FCangle;\u69A7\u0780ABDacdeflnoprsz\u391C\u391F\u3929\u392D\u39B5\u39B8\u39BD\u39DF\u39E4\u39E8\u39F3\u39F9\u39FD\u3A01\u3A20r\xF2\u03F7ar\u0100;v\u3926\u3927\u6AE8;\u6AE9as\xE8\u03E1\u0100nr\u3932\u3937grt;\u699C\u0380eknprst\u34E3\u3946\u394B\u3952\u395D\u3964\u3996app\xE1\u2415othin\xE7\u1E96\u0180hir\u34EB\u2EC8\u3959op\xF4\u2FB5\u0100;h\u13B7\u3962\xEF\u318D\u0100iu\u3969\u396Dgm\xE1\u33B3\u0100bp\u3972\u3984setneq\u0100;q\u397D\u3980\uC000\u228A\uFE00;\uC000\u2ACB\uFE00setneq\u0100;q\u398F\u3992\uC000\u228B\uFE00;\uC000\u2ACC\uFE00\u0100hr\u399B\u399Fet\xE1\u369Ciangle\u0100lr\u39AA\u39AFeft\xBB\u0925ight\xBB\u1051y;\u4432ash\xBB\u1036\u0180elr\u39C4\u39D2\u39D7\u0180;be\u2DEA\u39CB\u39CFar;\u62BBq;\u625Alip;\u62EE\u0100bt\u39DC\u1468a\xF2\u1469r;\uC000\u{1D533}tr\xE9\u39AEsu\u0100bp\u39EF\u39F1\xBB\u0D1C\xBB\u0D59pf;\uC000\u{1D567}ro\xF0\u0EFBtr\xE9\u39B4\u0100cu\u3A06\u3A0Br;\uC000\u{1D4CB}\u0100bp\u3A10\u3A18n\u0100Ee\u3980\u3A16\xBB\u397En\u0100Ee\u3992\u3A1E\xBB\u3990igzag;\u699A\u0380cefoprs\u3A36\u3A3B\u3A56\u3A5B\u3A54\u3A61\u3A6Airc;\u4175\u0100di\u3A40\u3A51\u0100bg\u3A45\u3A49ar;\u6A5Fe\u0100;q\u15FA\u3A4F;\u6259erp;\u6118r;\uC000\u{1D534}pf;\uC000\u{1D568}\u0100;e\u1479\u3A66at\xE8\u1479cr;\uC000\u{1D4CC}\u0AE3\u178E\u3A87\0\u3A8B\0\u3A90\u3A9B\0\0\u3A9D\u3AA8\u3AAB\u3AAF\0\0\u3AC3\u3ACE\0\u3AD8\u17DC\u17DFtr\xE9\u17D1r;\uC000\u{1D535}\u0100Aa\u3A94\u3A97r\xF2\u03C3r\xF2\u09F6;\u43BE\u0100Aa\u3AA1\u3AA4r\xF2\u03B8r\xF2\u09EBa\xF0\u2713is;\u62FB\u0180dpt\u17A4\u3AB5\u3ABE\u0100fl\u3ABA\u17A9;\uC000\u{1D569}im\xE5\u17B2\u0100Aa\u3AC7\u3ACAr\xF2\u03CEr\xF2\u0A01\u0100cq\u3AD2\u17B8r;\uC000\u{1D4CD}\u0100pt\u17D6\u3ADCr\xE9\u17D4\u0400acefiosu\u3AF0\u3AFD\u3B08\u3B0C\u3B11\u3B15\u3B1B\u3B21c\u0100uy\u3AF6\u3AFBte\u803B\xFD\u40FD;\u444F\u0100iy\u3B02\u3B06rc;\u4177;\u444Bn\u803B\xA5\u40A5r;\uC000\u{1D536}cy;\u4457pf;\uC000\u{1D56A}cr;\uC000\u{1D4CE}\u0100cm\u3B26\u3B29y;\u444El\u803B\xFF\u40FF\u0500acdefhiosw\u3B42\u3B48\u3B54\u3B58\u3B64\u3B69\u3B6D\u3B74\u3B7A\u3B80cute;\u417A\u0100ay\u3B4D\u3B52ron;\u417E;\u4437ot;\u417C\u0100et\u3B5D\u3B61tr\xE6\u155Fa;\u43B6r;\uC000\u{1D537}cy;\u4436grarr;\u61DDpf;\uC000\u{1D56B}cr;\uC000\u{1D4CF}\u0100jn\u3B85\u3B87;\u600Dj;\u600C'.split("").map((e9) => e9.charCodeAt(0)));
var qG = new Uint16Array("\u0200aglq	\x1B\u026D\0\0p;\u4026os;\u4027t;\u403Et;\u403Cuot;\u4022".split("").map((e9) => e9.charCodeAt(0)));
var ode;
var PCt = /* @__PURE__ */ new Map([[0, 65533], [128, 8364], [130, 8218], [131, 402], [132, 8222], [133, 8230], [134, 8224], [135, 8225], [136, 710], [137, 8240], [138, 352], [139, 8249], [140, 338], [142, 381], [145, 8216], [146, 8217], [147, 8220], [148, 8221], [149, 8226], [150, 8211], [151, 8212], [152, 732], [153, 8482], [154, 353], [155, 8250], [156, 339], [158, 382], [159, 376]]);
var jv = (ode = String.fromCodePoint) !== null && ode !== void 0 ? ode : function(e9) {
  let t = "";
  return e9 > 65535 && (e9 -= 65536, t += String.fromCharCode(e9 >>> 10 & 1023 | 55296), e9 = 56320 | e9 & 1023), t += String.fromCharCode(e9), t;
};
function rC(e9) {
  var t;
  return e9 >= 55296 && e9 <= 57343 || e9 > 1114111 ? 65533 : (t = PCt.get(e9)) !== null && t !== void 0 ? t : e9;
}
var _d;
(function(e9) {
  e9[e9.VALUE_LENGTH = 49152] = "VALUE_LENGTH", e9[e9.BRANCH_LENGTH = 16256] = "BRANCH_LENGTH", e9[e9.JUMP_TABLE = 127] = "JUMP_TABLE";
})(_d || (_d = {}));
function xde(e9, t, n, s) {
  let c = (t & _d.BRANCH_LENGTH) >> 7, l = t & _d.JUMP_TABLE;
  if (c === 0) return l !== 0 && s === l ? n : -1;
  if (l) {
    let g = s - l;
    return g < 0 || g >= c ? -1 : e9[n + g] - 1;
  }
  let d = n, m = d + c - 1;
  for (; d <= m; ) {
    let g = d + m >>> 1, y = e9[g];
    if (y < s) d = g + 1;
    else if (y > s) m = g - 1;
    else return e9[g + c];
  }
  return -1;
}
var cde = /["&'<>$\x80-\uFFFF]/g;
var Do0 = /* @__PURE__ */ new Map([[34, "&quot;"], [38, "&amp;"], [39, "&apos;"], [60, "&lt;"], [62, "&gt;"]]);
var Po0 = String.prototype.codePointAt != null ? (e9, t) => e9.codePointAt(t) : (e9, t) => (e9.charCodeAt(t) & 64512) === 55296 ? (e9.charCodeAt(t) - 55296) * 1024 + e9.charCodeAt(t + 1) - 56320 + 65536 : e9.charCodeAt(t);
function nC(e9) {
  let t = "", n = 0, s;
  for (; (s = cde.exec(e9)) !== null; ) {
    let c = s.index, l = e9.charCodeAt(c), d = Do0.get(l);
    d !== void 0 ? (t += e9.substring(n, c) + d, n = c + 1) : (t += `${e9.substring(n, c)}&#x${Po0(e9, c).toString(16)};`, n = cde.lastIndex += +((l & 64512) === 55296));
  }
  return t + e9.substr(n);
}
function ude(e9, t) {
  return function(s) {
    let c, l = 0, d = "";
    for (; c = e9.exec(s); ) l !== c.index && (d += s.substring(l, c.index)), d += t.get(c[0].charCodeAt(0)), l = c.index + 1;
    return d + s.substring(l);
  };
}
var QG = ude(/["&\u00A0]/g, /* @__PURE__ */ new Map([[34, "&quot;"], [38, "&amp;"], [160, "&nbsp;"]]));
var ZG = ude(/[&<>\u00A0]/g, /* @__PURE__ */ new Map([[38, "&amp;"], [60, "&lt;"], [62, "&gt;"], [160, "&nbsp;"]]));
var Fo0 = new Map(["altGlyph", "altGlyphDef", "altGlyphItem", "animateColor", "animateMotion", "animateTransform", "clipPath", "feBlend", "feColorMatrix", "feComponentTransfer", "feComposite", "feConvolveMatrix", "feDiffuseLighting", "feDisplacementMap", "feDistantLight", "feDropShadow", "feFlood", "feFuncA", "feFuncB", "feFuncG", "feFuncR", "feGaussianBlur", "feImage", "feMerge", "feMergeNode", "feMorphology", "feOffset", "fePointLight", "feSpecularLighting", "feSpotLight", "feTile", "feTurbulence", "foreignObject", "glyphRef", "linearGradient", "radialGradient", "textPath"].map((e9) => [e9.toLowerCase(), e9]));
var Wo0 = new Map(["definitionURL", "attributeName", "attributeType", "baseFrequency", "baseProfile", "calcMode", "clipPathUnits", "diffuseConstant", "edgeMode", "filterUnits", "glyphRef", "gradientTransform", "gradientUnits", "kernelMatrix", "kernelUnitLength", "keyPoints", "keySplines", "keyTimes", "lengthAdjust", "limitingConeAngle", "markerHeight", "markerUnits", "markerWidth", "maskContentUnits", "maskUnits", "numOctaves", "pathLength", "patternContentUnits", "patternTransform", "patternUnits", "pointsAtX", "pointsAtY", "pointsAtZ", "preserveAlpha", "preserveAspectRatio", "primitiveUnits", "refX", "refY", "repeatCount", "repeatDur", "requiredExtensions", "requiredFeatures", "specularConstant", "specularExponent", "spreadMethod", "startOffset", "stdDeviation", "stitchTiles", "surfaceScale", "systemLanguage", "tableValues", "targetX", "targetY", "textLength", "viewBox", "viewTarget", "xChannelSelector", "yChannelSelector", "zoomAndPan"].map((e9) => [e9.toLowerCase(), e9]));
var WCt = /* @__PURE__ */ new Set(["style", "script", "xmp", "iframe", "noembed", "noframes", "plaintext", "noscript"]);
function VCt(e9) {
  return e9.replace(/"/g, "&quot;");
}
function jCt(e9, t) {
  var n;
  if (!e9) return;
  let s = ((n = t.encodeEntities) !== null && n !== void 0 ? n : t.decodeEntities) === false ? VCt : t.xmlMode || t.encodeEntities !== "utf8" ? nC : QG;
  return Object.keys(e9).map((c) => {
    var l, d;
    let m = (l = e9[c]) !== null && l !== void 0 ? l : "";
    return t.xmlMode === "foreign" && (c = (d = Wo0.get(c)) !== null && d !== void 0 ? d : c), !t.emptyAttrs && !t.xmlMode && m === "" ? c : `${c}="${s(m)}"`;
  }).join(" ");
}
var Vo0 = /* @__PURE__ */ new Set(["area", "base", "basefont", "br", "col", "command", "embed", "frame", "hr", "img", "input", "isindex", "keygen", "link", "meta", "param", "source", "track", "wbr"]);
function dde(e9, t = {}) {
  let n = "length" in e9 ? e9 : [e9], s = "";
  for (let c = 0; c < n.length; c++) s += GCt(n[c], t);
  return s;
}
var KG = dde;
function GCt(e9, t) {
  switch (e9.type) {
    case ko0:
      return dde(e9.children, t);
    case Ro0:
    case _o0:
      return YCt(e9);
    case wo0:
      return KCt(e9);
    case Io0:
      return ZCt(e9);
    case So0:
    case Eo0:
    case To0:
      return zCt(e9, t);
    case vo0:
      return QCt(e9, t);
  }
}
var HCt = /* @__PURE__ */ new Set(["mi", "mo", "mn", "ms", "mtext", "annotation-xml", "foreignObject", "desc", "title"]);
var qCt = /* @__PURE__ */ new Set(["svg", "math"]);
function zCt(e9, t) {
  var n;
  t.xmlMode === "foreign" && (e9.name = (n = Fo0.get(e9.name)) !== null && n !== void 0 ? n : e9.name, e9.parent && HCt.has(e9.parent.name) && (t = { ...t, xmlMode: false })), !t.xmlMode && qCt.has(e9.name) && (t = { ...t, xmlMode: "foreign" });
  let s = `<${e9.name}`, c = jCt(e9.attribs, t);
  return c && (s += ` ${c}`), e9.children.length === 0 && (t.xmlMode ? t.selfClosingTags !== false : t.selfClosingTags && Vo0.has(e9.name)) ? (t.xmlMode || (s += " "), s += "/>") : (s += ">", e9.children.length > 0 && (s += dde(e9.children, t)), (t.xmlMode || !Vo0.has(e9.name)) && (s += `</${e9.name}>`)), s;
}
function YCt(e9) {
  return `<${e9.data}>`;
}
function QCt(e9, t) {
  var n;
  let s = e9.data || "";
  return ((n = t.encodeEntities) !== null && n !== void 0 ? n : t.decodeEntities) !== false && !(!t.xmlMode && e9.parent && WCt.has(e9.parent.name)) && (s = t.xmlMode || t.encodeEntities !== "utf8" ? nC(s) : ZG(s)), s;
}
function ZCt(e9) {
  return `<![CDATA[${e9.children[0].data}]]>`;
}
function KCt(e9) {
  return `<!--${e9.data}-->`;
}
function Um(e9) {
  if (e9.prev && (e9.prev.next = e9.next), e9.next && (e9.next.prev = e9.prev), e9.parent) {
    let t = e9.parent.children, n = t.lastIndexOf(e9);
    n >= 0 && t.splice(n, 1);
  }
  e9.next = null, e9.prev = null, e9.parent = null;
}
function nf(e9) {
  return e9.cheerio != null;
}
var Oy;
(function(e9) {
  e9[e9.LowerA = 97] = "LowerA", e9[e9.LowerZ = 122] = "LowerZ", e9[e9.UpperA = 65] = "UpperA", e9[e9.UpperZ = 90] = "UpperZ", e9[e9.Exclamation = 33] = "Exclamation";
})(Oy || (Oy = {}));
function aC(e9) {
  let t = e9.indexOf("<");
  if (t < 0 || t > e9.length - 3) return false;
  let n = e9.charCodeAt(t + 1);
  return (n >= Oy.LowerA && n <= Oy.LowerZ || n >= Oy.UpperA && n <= Oy.UpperZ || n === Oy.Exclamation) && e9.includes(">", t + 2);
}
function Gs0(e9) {
  return function(n, s, c, l) {
    if (typeof Buffer < "u" && Buffer.isBuffer(n) && (n = n.toString()), typeof n == "string") return e9(n, s, c, l);
    let d = n;
    if (!Array.isArray(d) && F2(d)) return d;
    let m = new rf([]);
    return t7(d, m), m;
  };
}
function t7(e9, t) {
  let n = Array.isArray(e9) ? e9 : [e9];
  t ? t.children = n : t = null;
  for (let s = 0; s < n.length; s++) {
    let c = n[s];
    c.parent && c.parent.children !== n && Um(c), t ? (c.prev = n[s - 1] || null, c.next = n[s + 1] || null) : c.prev = c.next = null, c.parent = t;
  }
  return t;
}
var n7 = class {
  constructor(t, n, s) {
    if (this.length = 0, this.options = s, this._root = n, t) {
      for (let c = 0; c < t.length; c++) this[c] = t[c];
      this.length = t.length;
    }
  }
};
function Ks0(e9, t) {
  return function n(s, c, l = true) {
    if (s == null) throw new Error("cheerio.load() expects a string");
    let d = { ...ZR, ...KR(c) }, m = e9(s, d, l, null);
    class g extends n7 {
      _make(w, T) {
        let I = y(w, T);
        return I.prevObject = this, I;
      }
      _parse(w, T, I, N) {
        return e9(w, T, I, N);
      }
      _render(w) {
        return t(w, this.options);
      }
    }
    function y(v, w, T = m, I) {
      if (v && nf(v)) return v;
      let N = { ...d, ...KR(I) }, C = typeof T == "string" ? [e9(T, N, false, null)] : "length" in T ? T : [T], B = nf(C) ? C : new g(C, null, N);
      if (B._root = B, !v) return new g(void 0, B, N);
      let L = typeof v == "string" && aC(v) ? e9(v, N, false, null).children : dDt(v) ? [v] : Array.isArray(v) ? v : void 0, q = new g(L, B, N);
      if (L) return q;
      if (typeof v != "string") throw new Error("Unexpected type of selector");
      let W = v, F = w ? typeof w == "string" ? aC(w) ? new g([e9(w, N, false, null)], B, N) : (W = `${w} ${W}`, B) : nf(w) ? w : new g(Array.isArray(w) ? w : [w], B, N) : B;
      return F ? F.find(W) : q;
    }
    return Object.assign(y, Xg, { load: n, _root: m, _options: d, fn: g.prototype, prototype: g.prototype }), y;
  };
}
function dDt(e9) {
  return !!e9.name || e9.type === "root" || e9.type === "text" || e9.type === "comment";
}
var pDt = /* @__PURE__ */ new Set([65534, 65535, 131070, 131071, 196606, 196607, 262142, 262143, 327678, 327679, 393214, 393215, 458750, 458751, 524286, 524287, 589822, 589823, 655358, 655359, 720894, 720895, 786430, 786431, 851966, 851967, 917502, 917503, 983038, 983039, 1048574, 1048575, 1114110, 1114111]);
var Ka = "\uFFFD";
var Ne;
(function(e9) {
  e9[e9.EOF = -1] = "EOF", e9[e9.NULL = 0] = "NULL", e9[e9.TABULATION = 9] = "TABULATION", e9[e9.CARRIAGE_RETURN = 13] = "CARRIAGE_RETURN", e9[e9.LINE_FEED = 10] = "LINE_FEED", e9[e9.FORM_FEED = 12] = "FORM_FEED", e9[e9.SPACE = 32] = "SPACE", e9[e9.EXCLAMATION_MARK = 33] = "EXCLAMATION_MARK", e9[e9.QUOTATION_MARK = 34] = "QUOTATION_MARK", e9[e9.AMPERSAND = 38] = "AMPERSAND", e9[e9.APOSTROPHE = 39] = "APOSTROPHE", e9[e9.HYPHEN_MINUS = 45] = "HYPHEN_MINUS", e9[e9.SOLIDUS = 47] = "SOLIDUS", e9[e9.DIGIT_0 = 48] = "DIGIT_0", e9[e9.DIGIT_9 = 57] = "DIGIT_9", e9[e9.SEMICOLON = 59] = "SEMICOLON", e9[e9.LESS_THAN_SIGN = 60] = "LESS_THAN_SIGN", e9[e9.EQUALS_SIGN = 61] = "EQUALS_SIGN", e9[e9.GREATER_THAN_SIGN = 62] = "GREATER_THAN_SIGN", e9[e9.QUESTION_MARK = 63] = "QUESTION_MARK", e9[e9.LATIN_CAPITAL_A = 65] = "LATIN_CAPITAL_A", e9[e9.LATIN_CAPITAL_Z = 90] = "LATIN_CAPITAL_Z", e9[e9.RIGHT_SQUARE_BRACKET = 93] = "RIGHT_SQUARE_BRACKET", e9[e9.GRAVE_ACCENT = 96] = "GRAVE_ACCENT", e9[e9.LATIN_SMALL_A = 97] = "LATIN_SMALL_A", e9[e9.LATIN_SMALL_Z = 122] = "LATIN_SMALL_Z";
})(Ne || (Ne = {}));
var cu = { DASH_DASH: "--", CDATA_START: "[CDATA[", DOCTYPE: "doctype", SCRIPT: "script", PUBLIC: "public", SYSTEM: "system" };
function AH(e9) {
  return e9 >= 55296 && e9 <= 57343;
}
function Js0(e9) {
  return e9 >= 56320 && e9 <= 57343;
}
function Xs0(e9, t) {
  return (e9 - 55296) * 1024 + 9216 + t;
}
function kH(e9) {
  return e9 !== 32 && e9 !== 10 && e9 !== 13 && e9 !== 9 && e9 !== 12 && e9 >= 1 && e9 <= 31 || e9 >= 127 && e9 <= 159;
}
function vH(e9) {
  return e9 >= 64976 && e9 <= 65007 || pDt.has(e9);
}
var I0;
(function(e9) {
  e9.controlCharacterInInputStream = "control-character-in-input-stream", e9.noncharacterInInputStream = "noncharacter-in-input-stream", e9.surrogateInInputStream = "surrogate-in-input-stream", e9.nonVoidHtmlElementStartTagWithTrailingSolidus = "non-void-html-element-start-tag-with-trailing-solidus", e9.endTagWithAttributes = "end-tag-with-attributes", e9.endTagWithTrailingSolidus = "end-tag-with-trailing-solidus", e9.unexpectedSolidusInTag = "unexpected-solidus-in-tag", e9.unexpectedNullCharacter = "unexpected-null-character", e9.unexpectedQuestionMarkInsteadOfTagName = "unexpected-question-mark-instead-of-tag-name", e9.invalidFirstCharacterOfTagName = "invalid-first-character-of-tag-name", e9.unexpectedEqualsSignBeforeAttributeName = "unexpected-equals-sign-before-attribute-name", e9.missingEndTagName = "missing-end-tag-name", e9.unexpectedCharacterInAttributeName = "unexpected-character-in-attribute-name", e9.unknownNamedCharacterReference = "unknown-named-character-reference", e9.missingSemicolonAfterCharacterReference = "missing-semicolon-after-character-reference", e9.unexpectedCharacterAfterDoctypeSystemIdentifier = "unexpected-character-after-doctype-system-identifier", e9.unexpectedCharacterInUnquotedAttributeValue = "unexpected-character-in-unquoted-attribute-value", e9.eofBeforeTagName = "eof-before-tag-name", e9.eofInTag = "eof-in-tag", e9.missingAttributeValue = "missing-attribute-value", e9.missingWhitespaceBetweenAttributes = "missing-whitespace-between-attributes", e9.missingWhitespaceAfterDoctypePublicKeyword = "missing-whitespace-after-doctype-public-keyword", e9.missingWhitespaceBetweenDoctypePublicAndSystemIdentifiers = "missing-whitespace-between-doctype-public-and-system-identifiers", e9.missingWhitespaceAfterDoctypeSystemKeyword = "missing-whitespace-after-doctype-system-keyword", e9.missingQuoteBeforeDoctypePublicIdentifier = "missing-quote-before-doctype-public-identifier", e9.missingQuoteBeforeDoctypeSystemIdentifier = "missing-quote-before-doctype-system-identifier", e9.missingDoctypePublicIdentifier = "missing-doctype-public-identifier", e9.missingDoctypeSystemIdentifier = "missing-doctype-system-identifier", e9.abruptDoctypePublicIdentifier = "abrupt-doctype-public-identifier", e9.abruptDoctypeSystemIdentifier = "abrupt-doctype-system-identifier", e9.cdataInHtmlContent = "cdata-in-html-content", e9.incorrectlyOpenedComment = "incorrectly-opened-comment", e9.eofInScriptHtmlCommentLikeText = "eof-in-script-html-comment-like-text", e9.eofInDoctype = "eof-in-doctype", e9.nestedComment = "nested-comment", e9.abruptClosingOfEmptyComment = "abrupt-closing-of-empty-comment", e9.eofInComment = "eof-in-comment", e9.incorrectlyClosedComment = "incorrectly-closed-comment", e9.eofInCdata = "eof-in-cdata", e9.absenceOfDigitsInNumericCharacterReference = "absence-of-digits-in-numeric-character-reference", e9.nullCharacterReference = "null-character-reference", e9.surrogateCharacterReference = "surrogate-character-reference", e9.characterReferenceOutsideUnicodeRange = "character-reference-outside-unicode-range", e9.controlCharacterReference = "control-character-reference", e9.noncharacterCharacterReference = "noncharacter-character-reference", e9.missingWhitespaceBeforeDoctypeName = "missing-whitespace-before-doctype-name", e9.missingDoctypeName = "missing-doctype-name", e9.invalidCharacterSequenceAfterDoctypeName = "invalid-character-sequence-after-doctype-name", e9.duplicateAttribute = "duplicate-attribute", e9.nonConformingDoctype = "non-conforming-doctype", e9.missingDoctype = "missing-doctype", e9.misplacedDoctype = "misplaced-doctype", e9.endTagWithoutMatchingOpenElement = "end-tag-without-matching-open-element", e9.closingOfElementWithOpenChildElements = "closing-of-element-with-open-child-elements", e9.disallowedContentInNoscriptInHead = "disallowed-content-in-noscript-in-head", e9.openElementsLeftAfterEof = "open-elements-left-after-eof", e9.abandonedHeadElementChild = "abandoned-head-element-child", e9.misplacedStartTagForHeadElement = "misplaced-start-tag-for-head-element", e9.nestedNoscriptInHead = "nested-noscript-in-head", e9.eofInElementThatCanContainOnlyText = "eof-in-element-that-can-contain-only-text";
})(I0 || (I0 = {}));
var hDt = 65536;
var _H = class {
  constructor(t) {
    this.handler = t, this.html = "", this.pos = -1, this.lastGapPos = -2, this.gapStack = [], this.skipNextNewLine = false, this.lastChunkWritten = false, this.endOfChunkHit = false, this.bufferWaterline = hDt, this.isEol = false, this.lineStartPos = 0, this.droppedBufferSize = 0, this.line = 1, this.lastErrOffset = -1;
  }
  get col() {
    return this.pos - this.lineStartPos + +(this.lastGapPos !== this.pos);
  }
  get offset() {
    return this.droppedBufferSize + this.pos;
  }
  getError(t, n) {
    let { line: s, col: c, offset: l } = this, d = c + n, m = l + n;
    return { code: t, startLine: s, endLine: s, startCol: d, endCol: d, startOffset: m, endOffset: m };
  }
  _err(t) {
    this.handler.onParseError && this.lastErrOffset !== this.offset && (this.lastErrOffset = this.offset, this.handler.onParseError(this.getError(t, 0)));
  }
  _addGap() {
    this.gapStack.push(this.lastGapPos), this.lastGapPos = this.pos;
  }
  _processSurrogate(t) {
    if (this.pos !== this.html.length - 1) {
      let n = this.html.charCodeAt(this.pos + 1);
      if (Js0(n)) return this.pos++, this._addGap(), Xs0(t, n);
    } else if (!this.lastChunkWritten) return this.endOfChunkHit = true, Ne.EOF;
    return this._err(I0.surrogateInInputStream), t;
  }
  willDropParsedChunk() {
    return this.pos > this.bufferWaterline;
  }
  dropParsedChunk() {
    this.willDropParsedChunk() && (this.html = this.html.substring(this.pos), this.lineStartPos -= this.pos, this.droppedBufferSize += this.pos, this.pos = 0, this.lastGapPos = -2, this.gapStack.length = 0);
  }
  write(t, n) {
    this.html.length > 0 ? this.html += t : this.html = t, this.endOfChunkHit = false, this.lastChunkWritten = n;
  }
  insertHtmlAtCurrentPos(t) {
    this.html = this.html.substring(0, this.pos + 1) + t + this.html.substring(this.pos + 1), this.endOfChunkHit = false;
  }
  startsWith(t, n) {
    if (this.pos + t.length > this.html.length) return this.endOfChunkHit = !this.lastChunkWritten, false;
    if (n) return this.html.startsWith(t, this.pos);
    for (let s = 0; s < t.length; s++) if ((this.html.charCodeAt(this.pos + s) | 32) !== t.charCodeAt(s)) return false;
    return true;
  }
  peek(t) {
    let n = this.pos + t;
    if (n >= this.html.length) return this.endOfChunkHit = !this.lastChunkWritten, Ne.EOF;
    let s = this.html.charCodeAt(n);
    return s === Ne.CARRIAGE_RETURN ? Ne.LINE_FEED : s;
  }
  advance() {
    if (this.pos++, this.isEol && (this.isEol = false, this.line++, this.lineStartPos = this.pos), this.pos >= this.html.length) return this.endOfChunkHit = !this.lastChunkWritten, Ne.EOF;
    let t = this.html.charCodeAt(this.pos);
    return t === Ne.CARRIAGE_RETURN ? (this.isEol = true, this.skipNextNewLine = true, Ne.LINE_FEED) : t === Ne.LINE_FEED && (this.isEol = true, this.skipNextNewLine) ? (this.line--, this.skipNextNewLine = false, this._addGap(), this.advance()) : (this.skipNextNewLine = false, AH(t) && (t = this._processSurrogate(t)), this.handler.onParseError === null || t > 31 && t < 127 || t === Ne.LINE_FEED || t === Ne.CARRIAGE_RETURN || t > 159 && t < 64976 || this._checkForProblematicCharacters(t), t);
  }
  _checkForProblematicCharacters(t) {
    kH(t) ? this._err(I0.controlCharacterInInputStream) : vH(t) && this._err(I0.noncharacterInInputStream);
  }
  retreat(t) {
    for (this.pos -= t; this.pos < this.lastGapPos; ) this.lastGapPos = this.gapStack.pop(), this.pos--;
    this.isEol = false;
  }
};
var ki;
(function(e9) {
  e9[e9.CHARACTER = 0] = "CHARACTER", e9[e9.NULL_CHARACTER = 1] = "NULL_CHARACTER", e9[e9.WHITESPACE_CHARACTER = 2] = "WHITESPACE_CHARACTER", e9[e9.START_TAG = 3] = "START_TAG", e9[e9.END_TAG = 4] = "END_TAG", e9[e9.COMMENT = 5] = "COMMENT", e9[e9.DOCTYPE = 6] = "DOCTYPE", e9[e9.EOF = 7] = "EOF", e9[e9.HIBERNATION = 8] = "HIBERNATION";
})(ki || (ki = {}));
function wH(e9, t) {
  for (let n = e9.attrs.length - 1; n >= 0; n--) if (e9.attrs[n].name === t) return e9.attrs[n].value;
  return null;
}
var SH = new Uint16Array('\u1D41<\xD5\u0131\u028A\u049D\u057B\u05D0\u0675\u06DE\u07A2\u07D6\u080F\u0A4A\u0A91\u0DA1\u0E6D\u0F09\u0F26\u10CA\u1228\u12E1\u1415\u149D\u14C3\u14DF\u1525\0\0\0\0\0\0\u156B\u16CD\u198D\u1C12\u1DDD\u1F7E\u2060\u21B0\u228D\u23C0\u23FB\u2442\u2824\u2912\u2D08\u2E48\u2FCE\u3016\u32BA\u3639\u37AC\u38FE\u3A28\u3A71\u3AE0\u3B2E\u0800EMabcfglmnoprstu\\bfms\x7F\x84\x8B\x90\x95\x98\xA6\xB3\xB9\xC8\xCFlig\u803B\xC6\u40C6P\u803B&\u4026cute\u803B\xC1\u40C1reve;\u4102\u0100iyx}rc\u803B\xC2\u40C2;\u4410r;\uC000\u{1D504}rave\u803B\xC0\u40C0pha;\u4391acr;\u4100d;\u6A53\u0100gp\x9D\xA1on;\u4104f;\uC000\u{1D538}plyFunction;\u6061ing\u803B\xC5\u40C5\u0100cs\xBE\xC3r;\uC000\u{1D49C}ign;\u6254ilde\u803B\xC3\u40C3ml\u803B\xC4\u40C4\u0400aceforsu\xE5\xFB\xFE\u0117\u011C\u0122\u0127\u012A\u0100cr\xEA\xF2kslash;\u6216\u0176\xF6\xF8;\u6AE7ed;\u6306y;\u4411\u0180crt\u0105\u010B\u0114ause;\u6235noullis;\u612Ca;\u4392r;\uC000\u{1D505}pf;\uC000\u{1D539}eve;\u42D8c\xF2\u0113mpeq;\u624E\u0700HOacdefhilorsu\u014D\u0151\u0156\u0180\u019E\u01A2\u01B5\u01B7\u01BA\u01DC\u0215\u0273\u0278\u027Ecy;\u4427PY\u803B\xA9\u40A9\u0180cpy\u015D\u0162\u017Aute;\u4106\u0100;i\u0167\u0168\u62D2talDifferentialD;\u6145leys;\u612D\u0200aeio\u0189\u018E\u0194\u0198ron;\u410Cdil\u803B\xC7\u40C7rc;\u4108nint;\u6230ot;\u410A\u0100dn\u01A7\u01ADilla;\u40B8terDot;\u40B7\xF2\u017Fi;\u43A7rcle\u0200DMPT\u01C7\u01CB\u01D1\u01D6ot;\u6299inus;\u6296lus;\u6295imes;\u6297o\u0100cs\u01E2\u01F8kwiseContourIntegral;\u6232eCurly\u0100DQ\u0203\u020FoubleQuote;\u601Duote;\u6019\u0200lnpu\u021E\u0228\u0247\u0255on\u0100;e\u0225\u0226\u6237;\u6A74\u0180git\u022F\u0236\u023Aruent;\u6261nt;\u622FourIntegral;\u622E\u0100fr\u024C\u024E;\u6102oduct;\u6210nterClockwiseContourIntegral;\u6233oss;\u6A2Fcr;\uC000\u{1D49E}p\u0100;C\u0284\u0285\u62D3ap;\u624D\u0580DJSZacefios\u02A0\u02AC\u02B0\u02B4\u02B8\u02CB\u02D7\u02E1\u02E6\u0333\u048D\u0100;o\u0179\u02A5trahd;\u6911cy;\u4402cy;\u4405cy;\u440F\u0180grs\u02BF\u02C4\u02C7ger;\u6021r;\u61A1hv;\u6AE4\u0100ay\u02D0\u02D5ron;\u410E;\u4414l\u0100;t\u02DD\u02DE\u6207a;\u4394r;\uC000\u{1D507}\u0100af\u02EB\u0327\u0100cm\u02F0\u0322ritical\u0200ADGT\u0300\u0306\u0316\u031Ccute;\u40B4o\u0174\u030B\u030D;\u42D9bleAcute;\u42DDrave;\u4060ilde;\u42DCond;\u62C4ferentialD;\u6146\u0470\u033D\0\0\0\u0342\u0354\0\u0405f;\uC000\u{1D53B}\u0180;DE\u0348\u0349\u034D\u40A8ot;\u60DCqual;\u6250ble\u0300CDLRUV\u0363\u0372\u0382\u03CF\u03E2\u03F8ontourIntegra\xEC\u0239o\u0274\u0379\0\0\u037B\xBB\u0349nArrow;\u61D3\u0100eo\u0387\u03A4ft\u0180ART\u0390\u0396\u03A1rrow;\u61D0ightArrow;\u61D4e\xE5\u02CAng\u0100LR\u03AB\u03C4eft\u0100AR\u03B3\u03B9rrow;\u67F8ightArrow;\u67FAightArrow;\u67F9ight\u0100AT\u03D8\u03DErrow;\u61D2ee;\u62A8p\u0241\u03E9\0\0\u03EFrrow;\u61D1ownArrow;\u61D5erticalBar;\u6225n\u0300ABLRTa\u0412\u042A\u0430\u045E\u047F\u037Crrow\u0180;BU\u041D\u041E\u0422\u6193ar;\u6913pArrow;\u61F5reve;\u4311eft\u02D2\u043A\0\u0446\0\u0450ightVector;\u6950eeVector;\u695Eector\u0100;B\u0459\u045A\u61BDar;\u6956ight\u01D4\u0467\0\u0471eeVector;\u695Fector\u0100;B\u047A\u047B\u61C1ar;\u6957ee\u0100;A\u0486\u0487\u62A4rrow;\u61A7\u0100ct\u0492\u0497r;\uC000\u{1D49F}rok;\u4110\u0800NTacdfglmopqstux\u04BD\u04C0\u04C4\u04CB\u04DE\u04E2\u04E7\u04EE\u04F5\u0521\u052F\u0536\u0552\u055D\u0560\u0565G;\u414AH\u803B\xD0\u40D0cute\u803B\xC9\u40C9\u0180aiy\u04D2\u04D7\u04DCron;\u411Arc\u803B\xCA\u40CA;\u442Dot;\u4116r;\uC000\u{1D508}rave\u803B\xC8\u40C8ement;\u6208\u0100ap\u04FA\u04FEcr;\u4112ty\u0253\u0506\0\0\u0512mallSquare;\u65FBerySmallSquare;\u65AB\u0100gp\u0526\u052Aon;\u4118f;\uC000\u{1D53C}silon;\u4395u\u0100ai\u053C\u0549l\u0100;T\u0542\u0543\u6A75ilde;\u6242librium;\u61CC\u0100ci\u0557\u055Ar;\u6130m;\u6A73a;\u4397ml\u803B\xCB\u40CB\u0100ip\u056A\u056Fsts;\u6203onentialE;\u6147\u0280cfios\u0585\u0588\u058D\u05B2\u05CCy;\u4424r;\uC000\u{1D509}lled\u0253\u0597\0\0\u05A3mallSquare;\u65FCerySmallSquare;\u65AA\u0370\u05BA\0\u05BF\0\0\u05C4f;\uC000\u{1D53D}All;\u6200riertrf;\u6131c\xF2\u05CB\u0600JTabcdfgorst\u05E8\u05EC\u05EF\u05FA\u0600\u0612\u0616\u061B\u061D\u0623\u066C\u0672cy;\u4403\u803B>\u403Emma\u0100;d\u05F7\u05F8\u4393;\u43DCreve;\u411E\u0180eiy\u0607\u060C\u0610dil;\u4122rc;\u411C;\u4413ot;\u4120r;\uC000\u{1D50A};\u62D9pf;\uC000\u{1D53E}eater\u0300EFGLST\u0635\u0644\u064E\u0656\u065B\u0666qual\u0100;L\u063E\u063F\u6265ess;\u62DBullEqual;\u6267reater;\u6AA2ess;\u6277lantEqual;\u6A7Eilde;\u6273cr;\uC000\u{1D4A2};\u626B\u0400Aacfiosu\u0685\u068B\u0696\u069B\u069E\u06AA\u06BE\u06CARDcy;\u442A\u0100ct\u0690\u0694ek;\u42C7;\u405Eirc;\u4124r;\u610ClbertSpace;\u610B\u01F0\u06AF\0\u06B2f;\u610DizontalLine;\u6500\u0100ct\u06C3\u06C5\xF2\u06A9rok;\u4126mp\u0144\u06D0\u06D8ownHum\xF0\u012Fqual;\u624F\u0700EJOacdfgmnostu\u06FA\u06FE\u0703\u0707\u070E\u071A\u071E\u0721\u0728\u0744\u0778\u078B\u078F\u0795cy;\u4415lig;\u4132cy;\u4401cute\u803B\xCD\u40CD\u0100iy\u0713\u0718rc\u803B\xCE\u40CE;\u4418ot;\u4130r;\u6111rave\u803B\xCC\u40CC\u0180;ap\u0720\u072F\u073F\u0100cg\u0734\u0737r;\u412AinaryI;\u6148lie\xF3\u03DD\u01F4\u0749\0\u0762\u0100;e\u074D\u074E\u622C\u0100gr\u0753\u0758ral;\u622Bsection;\u62C2isible\u0100CT\u076C\u0772omma;\u6063imes;\u6062\u0180gpt\u077F\u0783\u0788on;\u412Ef;\uC000\u{1D540}a;\u4399cr;\u6110ilde;\u4128\u01EB\u079A\0\u079Ecy;\u4406l\u803B\xCF\u40CF\u0280cfosu\u07AC\u07B7\u07BC\u07C2\u07D0\u0100iy\u07B1\u07B5rc;\u4134;\u4419r;\uC000\u{1D50D}pf;\uC000\u{1D541}\u01E3\u07C7\0\u07CCr;\uC000\u{1D4A5}rcy;\u4408kcy;\u4404\u0380HJacfos\u07E4\u07E8\u07EC\u07F1\u07FD\u0802\u0808cy;\u4425cy;\u440Cppa;\u439A\u0100ey\u07F6\u07FBdil;\u4136;\u441Ar;\uC000\u{1D50E}pf;\uC000\u{1D542}cr;\uC000\u{1D4A6}\u0580JTaceflmost\u0825\u0829\u082C\u0850\u0863\u09B3\u09B8\u09C7\u09CD\u0A37\u0A47cy;\u4409\u803B<\u403C\u0280cmnpr\u0837\u083C\u0841\u0844\u084Dute;\u4139bda;\u439Bg;\u67EAlacetrf;\u6112r;\u619E\u0180aey\u0857\u085C\u0861ron;\u413Ddil;\u413B;\u441B\u0100fs\u0868\u0970t\u0500ACDFRTUVar\u087E\u08A9\u08B1\u08E0\u08E6\u08FC\u092F\u095B\u0390\u096A\u0100nr\u0883\u088FgleBracket;\u67E8row\u0180;BR\u0899\u089A\u089E\u6190ar;\u61E4ightArrow;\u61C6eiling;\u6308o\u01F5\u08B7\0\u08C3bleBracket;\u67E6n\u01D4\u08C8\0\u08D2eeVector;\u6961ector\u0100;B\u08DB\u08DC\u61C3ar;\u6959loor;\u630Aight\u0100AV\u08EF\u08F5rrow;\u6194ector;\u694E\u0100er\u0901\u0917e\u0180;AV\u0909\u090A\u0910\u62A3rrow;\u61A4ector;\u695Aiangle\u0180;BE\u0924\u0925\u0929\u62B2ar;\u69CFqual;\u62B4p\u0180DTV\u0937\u0942\u094CownVector;\u6951eeVector;\u6960ector\u0100;B\u0956\u0957\u61BFar;\u6958ector\u0100;B\u0965\u0966\u61BCar;\u6952ight\xE1\u039Cs\u0300EFGLST\u097E\u098B\u0995\u099D\u09A2\u09ADqualGreater;\u62DAullEqual;\u6266reater;\u6276ess;\u6AA1lantEqual;\u6A7Dilde;\u6272r;\uC000\u{1D50F}\u0100;e\u09BD\u09BE\u62D8ftarrow;\u61DAidot;\u413F\u0180npw\u09D4\u0A16\u0A1Bg\u0200LRlr\u09DE\u09F7\u0A02\u0A10eft\u0100AR\u09E6\u09ECrrow;\u67F5ightArrow;\u67F7ightArrow;\u67F6eft\u0100ar\u03B3\u0A0Aight\xE1\u03BFight\xE1\u03CAf;\uC000\u{1D543}er\u0100LR\u0A22\u0A2CeftArrow;\u6199ightArrow;\u6198\u0180cht\u0A3E\u0A40\u0A42\xF2\u084C;\u61B0rok;\u4141;\u626A\u0400acefiosu\u0A5A\u0A5D\u0A60\u0A77\u0A7C\u0A85\u0A8B\u0A8Ep;\u6905y;\u441C\u0100dl\u0A65\u0A6FiumSpace;\u605Flintrf;\u6133r;\uC000\u{1D510}nusPlus;\u6213pf;\uC000\u{1D544}c\xF2\u0A76;\u439C\u0480Jacefostu\u0AA3\u0AA7\u0AAD\u0AC0\u0B14\u0B19\u0D91\u0D97\u0D9Ecy;\u440Acute;\u4143\u0180aey\u0AB4\u0AB9\u0ABEron;\u4147dil;\u4145;\u441D\u0180gsw\u0AC7\u0AF0\u0B0Eative\u0180MTV\u0AD3\u0ADF\u0AE8ediumSpace;\u600Bhi\u0100cn\u0AE6\u0AD8\xEB\u0AD9eryThi\xEE\u0AD9ted\u0100GL\u0AF8\u0B06reaterGreate\xF2\u0673essLes\xF3\u0A48Line;\u400Ar;\uC000\u{1D511}\u0200Bnpt\u0B22\u0B28\u0B37\u0B3Areak;\u6060BreakingSpace;\u40A0f;\u6115\u0680;CDEGHLNPRSTV\u0B55\u0B56\u0B6A\u0B7C\u0BA1\u0BEB\u0C04\u0C5E\u0C84\u0CA6\u0CD8\u0D61\u0D85\u6AEC\u0100ou\u0B5B\u0B64ngruent;\u6262pCap;\u626DoubleVerticalBar;\u6226\u0180lqx\u0B83\u0B8A\u0B9Bement;\u6209ual\u0100;T\u0B92\u0B93\u6260ilde;\uC000\u2242\u0338ists;\u6204reater\u0380;EFGLST\u0BB6\u0BB7\u0BBD\u0BC9\u0BD3\u0BD8\u0BE5\u626Fqual;\u6271ullEqual;\uC000\u2267\u0338reater;\uC000\u226B\u0338ess;\u6279lantEqual;\uC000\u2A7E\u0338ilde;\u6275ump\u0144\u0BF2\u0BFDownHump;\uC000\u224E\u0338qual;\uC000\u224F\u0338e\u0100fs\u0C0A\u0C27tTriangle\u0180;BE\u0C1A\u0C1B\u0C21\u62EAar;\uC000\u29CF\u0338qual;\u62ECs\u0300;EGLST\u0C35\u0C36\u0C3C\u0C44\u0C4B\u0C58\u626Equal;\u6270reater;\u6278ess;\uC000\u226A\u0338lantEqual;\uC000\u2A7D\u0338ilde;\u6274ested\u0100GL\u0C68\u0C79reaterGreater;\uC000\u2AA2\u0338essLess;\uC000\u2AA1\u0338recedes\u0180;ES\u0C92\u0C93\u0C9B\u6280qual;\uC000\u2AAF\u0338lantEqual;\u62E0\u0100ei\u0CAB\u0CB9verseElement;\u620CghtTriangle\u0180;BE\u0CCB\u0CCC\u0CD2\u62EBar;\uC000\u29D0\u0338qual;\u62ED\u0100qu\u0CDD\u0D0CuareSu\u0100bp\u0CE8\u0CF9set\u0100;E\u0CF0\u0CF3\uC000\u228F\u0338qual;\u62E2erset\u0100;E\u0D03\u0D06\uC000\u2290\u0338qual;\u62E3\u0180bcp\u0D13\u0D24\u0D4Eset\u0100;E\u0D1B\u0D1E\uC000\u2282\u20D2qual;\u6288ceeds\u0200;EST\u0D32\u0D33\u0D3B\u0D46\u6281qual;\uC000\u2AB0\u0338lantEqual;\u62E1ilde;\uC000\u227F\u0338erset\u0100;E\u0D58\u0D5B\uC000\u2283\u20D2qual;\u6289ilde\u0200;EFT\u0D6E\u0D6F\u0D75\u0D7F\u6241qual;\u6244ullEqual;\u6247ilde;\u6249erticalBar;\u6224cr;\uC000\u{1D4A9}ilde\u803B\xD1\u40D1;\u439D\u0700Eacdfgmoprstuv\u0DBD\u0DC2\u0DC9\u0DD5\u0DDB\u0DE0\u0DE7\u0DFC\u0E02\u0E20\u0E22\u0E32\u0E3F\u0E44lig;\u4152cute\u803B\xD3\u40D3\u0100iy\u0DCE\u0DD3rc\u803B\xD4\u40D4;\u441Eblac;\u4150r;\uC000\u{1D512}rave\u803B\xD2\u40D2\u0180aei\u0DEE\u0DF2\u0DF6cr;\u414Cga;\u43A9cron;\u439Fpf;\uC000\u{1D546}enCurly\u0100DQ\u0E0E\u0E1AoubleQuote;\u601Cuote;\u6018;\u6A54\u0100cl\u0E27\u0E2Cr;\uC000\u{1D4AA}ash\u803B\xD8\u40D8i\u016C\u0E37\u0E3Cde\u803B\xD5\u40D5es;\u6A37ml\u803B\xD6\u40D6er\u0100BP\u0E4B\u0E60\u0100ar\u0E50\u0E53r;\u603Eac\u0100ek\u0E5A\u0E5C;\u63DEet;\u63B4arenthesis;\u63DC\u0480acfhilors\u0E7F\u0E87\u0E8A\u0E8F\u0E92\u0E94\u0E9D\u0EB0\u0EFCrtialD;\u6202y;\u441Fr;\uC000\u{1D513}i;\u43A6;\u43A0usMinus;\u40B1\u0100ip\u0EA2\u0EADncareplan\xE5\u069Df;\u6119\u0200;eio\u0EB9\u0EBA\u0EE0\u0EE4\u6ABBcedes\u0200;EST\u0EC8\u0EC9\u0ECF\u0EDA\u627Aqual;\u6AAFlantEqual;\u627Cilde;\u627Eme;\u6033\u0100dp\u0EE9\u0EEEuct;\u620Fortion\u0100;a\u0225\u0EF9l;\u621D\u0100ci\u0F01\u0F06r;\uC000\u{1D4AB};\u43A8\u0200Ufos\u0F11\u0F16\u0F1B\u0F1FOT\u803B"\u4022r;\uC000\u{1D514}pf;\u611Acr;\uC000\u{1D4AC}\u0600BEacefhiorsu\u0F3E\u0F43\u0F47\u0F60\u0F73\u0FA7\u0FAA\u0FAD\u1096\u10A9\u10B4\u10BEarr;\u6910G\u803B\xAE\u40AE\u0180cnr\u0F4E\u0F53\u0F56ute;\u4154g;\u67EBr\u0100;t\u0F5C\u0F5D\u61A0l;\u6916\u0180aey\u0F67\u0F6C\u0F71ron;\u4158dil;\u4156;\u4420\u0100;v\u0F78\u0F79\u611Cerse\u0100EU\u0F82\u0F99\u0100lq\u0F87\u0F8Eement;\u620Builibrium;\u61CBpEquilibrium;\u696Fr\xBB\u0F79o;\u43A1ght\u0400ACDFTUVa\u0FC1\u0FEB\u0FF3\u1022\u1028\u105B\u1087\u03D8\u0100nr\u0FC6\u0FD2gleBracket;\u67E9row\u0180;BL\u0FDC\u0FDD\u0FE1\u6192ar;\u61E5eftArrow;\u61C4eiling;\u6309o\u01F5\u0FF9\0\u1005bleBracket;\u67E7n\u01D4\u100A\0\u1014eeVector;\u695Dector\u0100;B\u101D\u101E\u61C2ar;\u6955loor;\u630B\u0100er\u102D\u1043e\u0180;AV\u1035\u1036\u103C\u62A2rrow;\u61A6ector;\u695Biangle\u0180;BE\u1050\u1051\u1055\u62B3ar;\u69D0qual;\u62B5p\u0180DTV\u1063\u106E\u1078ownVector;\u694FeeVector;\u695Cector\u0100;B\u1082\u1083\u61BEar;\u6954ector\u0100;B\u1091\u1092\u61C0ar;\u6953\u0100pu\u109B\u109Ef;\u611DndImplies;\u6970ightarrow;\u61DB\u0100ch\u10B9\u10BCr;\u611B;\u61B1leDelayed;\u69F4\u0680HOacfhimoqstu\u10E4\u10F1\u10F7\u10FD\u1119\u111E\u1151\u1156\u1161\u1167\u11B5\u11BB\u11BF\u0100Cc\u10E9\u10EEHcy;\u4429y;\u4428FTcy;\u442Ccute;\u415A\u0280;aeiy\u1108\u1109\u110E\u1113\u1117\u6ABCron;\u4160dil;\u415Erc;\u415C;\u4421r;\uC000\u{1D516}ort\u0200DLRU\u112A\u1134\u113E\u1149ownArrow\xBB\u041EeftArrow\xBB\u089AightArrow\xBB\u0FDDpArrow;\u6191gma;\u43A3allCircle;\u6218pf;\uC000\u{1D54A}\u0272\u116D\0\0\u1170t;\u621Aare\u0200;ISU\u117B\u117C\u1189\u11AF\u65A1ntersection;\u6293u\u0100bp\u118F\u119Eset\u0100;E\u1197\u1198\u628Fqual;\u6291erset\u0100;E\u11A8\u11A9\u6290qual;\u6292nion;\u6294cr;\uC000\u{1D4AE}ar;\u62C6\u0200bcmp\u11C8\u11DB\u1209\u120B\u0100;s\u11CD\u11CE\u62D0et\u0100;E\u11CD\u11D5qual;\u6286\u0100ch\u11E0\u1205eeds\u0200;EST\u11ED\u11EE\u11F4\u11FF\u627Bqual;\u6AB0lantEqual;\u627Dilde;\u627FTh\xE1\u0F8C;\u6211\u0180;es\u1212\u1213\u1223\u62D1rset\u0100;E\u121C\u121D\u6283qual;\u6287et\xBB\u1213\u0580HRSacfhiors\u123E\u1244\u1249\u1255\u125E\u1271\u1276\u129F\u12C2\u12C8\u12D1ORN\u803B\xDE\u40DEADE;\u6122\u0100Hc\u124E\u1252cy;\u440By;\u4426\u0100bu\u125A\u125C;\u4009;\u43A4\u0180aey\u1265\u126A\u126Fron;\u4164dil;\u4162;\u4422r;\uC000\u{1D517}\u0100ei\u127B\u1289\u01F2\u1280\0\u1287efore;\u6234a;\u4398\u0100cn\u128E\u1298kSpace;\uC000\u205F\u200ASpace;\u6009lde\u0200;EFT\u12AB\u12AC\u12B2\u12BC\u623Cqual;\u6243ullEqual;\u6245ilde;\u6248pf;\uC000\u{1D54B}ipleDot;\u60DB\u0100ct\u12D6\u12DBr;\uC000\u{1D4AF}rok;\u4166\u0AE1\u12F7\u130E\u131A\u1326\0\u132C\u1331\0\0\0\0\0\u1338\u133D\u1377\u1385\0\u13FF\u1404\u140A\u1410\u0100cr\u12FB\u1301ute\u803B\xDA\u40DAr\u0100;o\u1307\u1308\u619Fcir;\u6949r\u01E3\u1313\0\u1316y;\u440Eve;\u416C\u0100iy\u131E\u1323rc\u803B\xDB\u40DB;\u4423blac;\u4170r;\uC000\u{1D518}rave\u803B\xD9\u40D9acr;\u416A\u0100di\u1341\u1369er\u0100BP\u1348\u135D\u0100ar\u134D\u1350r;\u405Fac\u0100ek\u1357\u1359;\u63DFet;\u63B5arenthesis;\u63DDon\u0100;P\u1370\u1371\u62C3lus;\u628E\u0100gp\u137B\u137Fon;\u4172f;\uC000\u{1D54C}\u0400ADETadps\u1395\u13AE\u13B8\u13C4\u03E8\u13D2\u13D7\u13F3rrow\u0180;BD\u1150\u13A0\u13A4ar;\u6912ownArrow;\u61C5ownArrow;\u6195quilibrium;\u696Eee\u0100;A\u13CB\u13CC\u62A5rrow;\u61A5own\xE1\u03F3er\u0100LR\u13DE\u13E8eftArrow;\u6196ightArrow;\u6197i\u0100;l\u13F9\u13FA\u43D2on;\u43A5ing;\u416Ecr;\uC000\u{1D4B0}ilde;\u4168ml\u803B\xDC\u40DC\u0480Dbcdefosv\u1427\u142C\u1430\u1433\u143E\u1485\u148A\u1490\u1496ash;\u62ABar;\u6AEBy;\u4412ash\u0100;l\u143B\u143C\u62A9;\u6AE6\u0100er\u1443\u1445;\u62C1\u0180bty\u144C\u1450\u147Aar;\u6016\u0100;i\u144F\u1455cal\u0200BLST\u1461\u1465\u146A\u1474ar;\u6223ine;\u407Ceparator;\u6758ilde;\u6240ThinSpace;\u600Ar;\uC000\u{1D519}pf;\uC000\u{1D54D}cr;\uC000\u{1D4B1}dash;\u62AA\u0280cefos\u14A7\u14AC\u14B1\u14B6\u14BCirc;\u4174dge;\u62C0r;\uC000\u{1D51A}pf;\uC000\u{1D54E}cr;\uC000\u{1D4B2}\u0200fios\u14CB\u14D0\u14D2\u14D8r;\uC000\u{1D51B};\u439Epf;\uC000\u{1D54F}cr;\uC000\u{1D4B3}\u0480AIUacfosu\u14F1\u14F5\u14F9\u14FD\u1504\u150F\u1514\u151A\u1520cy;\u442Fcy;\u4407cy;\u442Ecute\u803B\xDD\u40DD\u0100iy\u1509\u150Drc;\u4176;\u442Br;\uC000\u{1D51C}pf;\uC000\u{1D550}cr;\uC000\u{1D4B4}ml;\u4178\u0400Hacdefos\u1535\u1539\u153F\u154B\u154F\u155D\u1560\u1564cy;\u4416cute;\u4179\u0100ay\u1544\u1549ron;\u417D;\u4417ot;\u417B\u01F2\u1554\0\u155BoWidt\xE8\u0AD9a;\u4396r;\u6128pf;\u6124cr;\uC000\u{1D4B5}\u0BE1\u1583\u158A\u1590\0\u15B0\u15B6\u15BF\0\0\0\0\u15C6\u15DB\u15EB\u165F\u166D\0\u1695\u169B\u16B2\u16B9\0\u16BEcute\u803B\xE1\u40E1reve;\u4103\u0300;Ediuy\u159C\u159D\u15A1\u15A3\u15A8\u15AD\u623E;\uC000\u223E\u0333;\u623Frc\u803B\xE2\u40E2te\u80BB\xB4\u0306;\u4430lig\u803B\xE6\u40E6\u0100;r\xB2\u15BA;\uC000\u{1D51E}rave\u803B\xE0\u40E0\u0100ep\u15CA\u15D6\u0100fp\u15CF\u15D4sym;\u6135\xE8\u15D3ha;\u43B1\u0100ap\u15DFc\u0100cl\u15E4\u15E7r;\u4101g;\u6A3F\u0264\u15F0\0\0\u160A\u0280;adsv\u15FA\u15FB\u15FF\u1601\u1607\u6227nd;\u6A55;\u6A5Clope;\u6A58;\u6A5A\u0380;elmrsz\u1618\u1619\u161B\u161E\u163F\u164F\u1659\u6220;\u69A4e\xBB\u1619sd\u0100;a\u1625\u1626\u6221\u0461\u1630\u1632\u1634\u1636\u1638\u163A\u163C\u163E;\u69A8;\u69A9;\u69AA;\u69AB;\u69AC;\u69AD;\u69AE;\u69AFt\u0100;v\u1645\u1646\u621Fb\u0100;d\u164C\u164D\u62BE;\u699D\u0100pt\u1654\u1657h;\u6222\xBB\xB9arr;\u637C\u0100gp\u1663\u1667on;\u4105f;\uC000\u{1D552}\u0380;Eaeiop\u12C1\u167B\u167D\u1682\u1684\u1687\u168A;\u6A70cir;\u6A6F;\u624Ad;\u624Bs;\u4027rox\u0100;e\u12C1\u1692\xF1\u1683ing\u803B\xE5\u40E5\u0180cty\u16A1\u16A6\u16A8r;\uC000\u{1D4B6};\u402Amp\u0100;e\u12C1\u16AF\xF1\u0288ilde\u803B\xE3\u40E3ml\u803B\xE4\u40E4\u0100ci\u16C2\u16C8onin\xF4\u0272nt;\u6A11\u0800Nabcdefiklnoprsu\u16ED\u16F1\u1730\u173C\u1743\u1748\u1778\u177D\u17E0\u17E6\u1839\u1850\u170D\u193D\u1948\u1970ot;\u6AED\u0100cr\u16F6\u171Ek\u0200ceps\u1700\u1705\u170D\u1713ong;\u624Cpsilon;\u43F6rime;\u6035im\u0100;e\u171A\u171B\u623Dq;\u62CD\u0176\u1722\u1726ee;\u62BDed\u0100;g\u172C\u172D\u6305e\xBB\u172Drk\u0100;t\u135C\u1737brk;\u63B6\u0100oy\u1701\u1741;\u4431quo;\u601E\u0280cmprt\u1753\u175B\u1761\u1764\u1768aus\u0100;e\u010A\u0109ptyv;\u69B0s\xE9\u170Cno\xF5\u0113\u0180ahw\u176F\u1771\u1773;\u43B2;\u6136een;\u626Cr;\uC000\u{1D51F}g\u0380costuvw\u178D\u179D\u17B3\u17C1\u17D5\u17DB\u17DE\u0180aiu\u1794\u1796\u179A\xF0\u0760rc;\u65EFp\xBB\u1371\u0180dpt\u17A4\u17A8\u17ADot;\u6A00lus;\u6A01imes;\u6A02\u0271\u17B9\0\0\u17BEcup;\u6A06ar;\u6605riangle\u0100du\u17CD\u17D2own;\u65BDp;\u65B3plus;\u6A04e\xE5\u1444\xE5\u14ADarow;\u690D\u0180ako\u17ED\u1826\u1835\u0100cn\u17F2\u1823k\u0180lst\u17FA\u05AB\u1802ozenge;\u69EBriangle\u0200;dlr\u1812\u1813\u1818\u181D\u65B4own;\u65BEeft;\u65C2ight;\u65B8k;\u6423\u01B1\u182B\0\u1833\u01B2\u182F\0\u1831;\u6592;\u65914;\u6593ck;\u6588\u0100eo\u183E\u184D\u0100;q\u1843\u1846\uC000=\u20E5uiv;\uC000\u2261\u20E5t;\u6310\u0200ptwx\u1859\u185E\u1867\u186Cf;\uC000\u{1D553}\u0100;t\u13CB\u1863om\xBB\u13CCtie;\u62C8\u0600DHUVbdhmptuv\u1885\u1896\u18AA\u18BB\u18D7\u18DB\u18EC\u18FF\u1905\u190A\u1910\u1921\u0200LRlr\u188E\u1890\u1892\u1894;\u6557;\u6554;\u6556;\u6553\u0280;DUdu\u18A1\u18A2\u18A4\u18A6\u18A8\u6550;\u6566;\u6569;\u6564;\u6567\u0200LRlr\u18B3\u18B5\u18B7\u18B9;\u655D;\u655A;\u655C;\u6559\u0380;HLRhlr\u18CA\u18CB\u18CD\u18CF\u18D1\u18D3\u18D5\u6551;\u656C;\u6563;\u6560;\u656B;\u6562;\u655Fox;\u69C9\u0200LRlr\u18E4\u18E6\u18E8\u18EA;\u6555;\u6552;\u6510;\u650C\u0280;DUdu\u06BD\u18F7\u18F9\u18FB\u18FD;\u6565;\u6568;\u652C;\u6534inus;\u629Flus;\u629Eimes;\u62A0\u0200LRlr\u1919\u191B\u191D\u191F;\u655B;\u6558;\u6518;\u6514\u0380;HLRhlr\u1930\u1931\u1933\u1935\u1937\u1939\u193B\u6502;\u656A;\u6561;\u655E;\u653C;\u6524;\u651C\u0100ev\u0123\u1942bar\u803B\xA6\u40A6\u0200ceio\u1951\u1956\u195A\u1960r;\uC000\u{1D4B7}mi;\u604Fm\u0100;e\u171A\u171Cl\u0180;bh\u1968\u1969\u196B\u405C;\u69C5sub;\u67C8\u016C\u1974\u197El\u0100;e\u1979\u197A\u6022t\xBB\u197Ap\u0180;Ee\u012F\u1985\u1987;\u6AAE\u0100;q\u06DC\u06DB\u0CE1\u19A7\0\u19E8\u1A11\u1A15\u1A32\0\u1A37\u1A50\0\0\u1AB4\0\0\u1AC1\0\0\u1B21\u1B2E\u1B4D\u1B52\0\u1BFD\0\u1C0C\u0180cpr\u19AD\u19B2\u19DDute;\u4107\u0300;abcds\u19BF\u19C0\u19C4\u19CA\u19D5\u19D9\u6229nd;\u6A44rcup;\u6A49\u0100au\u19CF\u19D2p;\u6A4Bp;\u6A47ot;\u6A40;\uC000\u2229\uFE00\u0100eo\u19E2\u19E5t;\u6041\xEE\u0693\u0200aeiu\u19F0\u19FB\u1A01\u1A05\u01F0\u19F5\0\u19F8s;\u6A4Don;\u410Ddil\u803B\xE7\u40E7rc;\u4109ps\u0100;s\u1A0C\u1A0D\u6A4Cm;\u6A50ot;\u410B\u0180dmn\u1A1B\u1A20\u1A26il\u80BB\xB8\u01ADptyv;\u69B2t\u8100\xA2;e\u1A2D\u1A2E\u40A2r\xE4\u01B2r;\uC000\u{1D520}\u0180cei\u1A3D\u1A40\u1A4Dy;\u4447ck\u0100;m\u1A47\u1A48\u6713ark\xBB\u1A48;\u43C7r\u0380;Ecefms\u1A5F\u1A60\u1A62\u1A6B\u1AA4\u1AAA\u1AAE\u65CB;\u69C3\u0180;el\u1A69\u1A6A\u1A6D\u42C6q;\u6257e\u0261\u1A74\0\0\u1A88rrow\u0100lr\u1A7C\u1A81eft;\u61BAight;\u61BB\u0280RSacd\u1A92\u1A94\u1A96\u1A9A\u1A9F\xBB\u0F47;\u64C8st;\u629Birc;\u629Aash;\u629Dnint;\u6A10id;\u6AEFcir;\u69C2ubs\u0100;u\u1ABB\u1ABC\u6663it\xBB\u1ABC\u02EC\u1AC7\u1AD4\u1AFA\0\u1B0Aon\u0100;e\u1ACD\u1ACE\u403A\u0100;q\xC7\xC6\u026D\u1AD9\0\0\u1AE2a\u0100;t\u1ADE\u1ADF\u402C;\u4040\u0180;fl\u1AE8\u1AE9\u1AEB\u6201\xEE\u1160e\u0100mx\u1AF1\u1AF6ent\xBB\u1AE9e\xF3\u024D\u01E7\u1AFE\0\u1B07\u0100;d\u12BB\u1B02ot;\u6A6Dn\xF4\u0246\u0180fry\u1B10\u1B14\u1B17;\uC000\u{1D554}o\xE4\u0254\u8100\xA9;s\u0155\u1B1Dr;\u6117\u0100ao\u1B25\u1B29rr;\u61B5ss;\u6717\u0100cu\u1B32\u1B37r;\uC000\u{1D4B8}\u0100bp\u1B3C\u1B44\u0100;e\u1B41\u1B42\u6ACF;\u6AD1\u0100;e\u1B49\u1B4A\u6AD0;\u6AD2dot;\u62EF\u0380delprvw\u1B60\u1B6C\u1B77\u1B82\u1BAC\u1BD4\u1BF9arr\u0100lr\u1B68\u1B6A;\u6938;\u6935\u0270\u1B72\0\0\u1B75r;\u62DEc;\u62DFarr\u0100;p\u1B7F\u1B80\u61B6;\u693D\u0300;bcdos\u1B8F\u1B90\u1B96\u1BA1\u1BA5\u1BA8\u622Arcap;\u6A48\u0100au\u1B9B\u1B9Ep;\u6A46p;\u6A4Aot;\u628Dr;\u6A45;\uC000\u222A\uFE00\u0200alrv\u1BB5\u1BBF\u1BDE\u1BE3rr\u0100;m\u1BBC\u1BBD\u61B7;\u693Cy\u0180evw\u1BC7\u1BD4\u1BD8q\u0270\u1BCE\0\0\u1BD2re\xE3\u1B73u\xE3\u1B75ee;\u62CEedge;\u62CFen\u803B\xA4\u40A4earrow\u0100lr\u1BEE\u1BF3eft\xBB\u1B80ight\xBB\u1BBDe\xE4\u1BDD\u0100ci\u1C01\u1C07onin\xF4\u01F7nt;\u6231lcty;\u632D\u0980AHabcdefhijlorstuwz\u1C38\u1C3B\u1C3F\u1C5D\u1C69\u1C75\u1C8A\u1C9E\u1CAC\u1CB7\u1CFB\u1CFF\u1D0D\u1D7B\u1D91\u1DAB\u1DBB\u1DC6\u1DCDr\xF2\u0381ar;\u6965\u0200glrs\u1C48\u1C4D\u1C52\u1C54ger;\u6020eth;\u6138\xF2\u1133h\u0100;v\u1C5A\u1C5B\u6010\xBB\u090A\u016B\u1C61\u1C67arow;\u690Fa\xE3\u0315\u0100ay\u1C6E\u1C73ron;\u410F;\u4434\u0180;ao\u0332\u1C7C\u1C84\u0100gr\u02BF\u1C81r;\u61CAtseq;\u6A77\u0180glm\u1C91\u1C94\u1C98\u803B\xB0\u40B0ta;\u43B4ptyv;\u69B1\u0100ir\u1CA3\u1CA8sht;\u697F;\uC000\u{1D521}ar\u0100lr\u1CB3\u1CB5\xBB\u08DC\xBB\u101E\u0280aegsv\u1CC2\u0378\u1CD6\u1CDC\u1CE0m\u0180;os\u0326\u1CCA\u1CD4nd\u0100;s\u0326\u1CD1uit;\u6666amma;\u43DDin;\u62F2\u0180;io\u1CE7\u1CE8\u1CF8\u40F7de\u8100\xF7;o\u1CE7\u1CF0ntimes;\u62C7n\xF8\u1CF7cy;\u4452c\u026F\u1D06\0\0\u1D0Arn;\u631Eop;\u630D\u0280lptuw\u1D18\u1D1D\u1D22\u1D49\u1D55lar;\u4024f;\uC000\u{1D555}\u0280;emps\u030B\u1D2D\u1D37\u1D3D\u1D42q\u0100;d\u0352\u1D33ot;\u6251inus;\u6238lus;\u6214quare;\u62A1blebarwedg\xE5\xFAn\u0180adh\u112E\u1D5D\u1D67ownarrow\xF3\u1C83arpoon\u0100lr\u1D72\u1D76ef\xF4\u1CB4igh\xF4\u1CB6\u0162\u1D7F\u1D85karo\xF7\u0F42\u026F\u1D8A\0\0\u1D8Ern;\u631Fop;\u630C\u0180cot\u1D98\u1DA3\u1DA6\u0100ry\u1D9D\u1DA1;\uC000\u{1D4B9};\u4455l;\u69F6rok;\u4111\u0100dr\u1DB0\u1DB4ot;\u62F1i\u0100;f\u1DBA\u1816\u65BF\u0100ah\u1DC0\u1DC3r\xF2\u0429a\xF2\u0FA6angle;\u69A6\u0100ci\u1DD2\u1DD5y;\u445Fgrarr;\u67FF\u0900Dacdefglmnopqrstux\u1E01\u1E09\u1E19\u1E38\u0578\u1E3C\u1E49\u1E61\u1E7E\u1EA5\u1EAF\u1EBD\u1EE1\u1F2A\u1F37\u1F44\u1F4E\u1F5A\u0100Do\u1E06\u1D34o\xF4\u1C89\u0100cs\u1E0E\u1E14ute\u803B\xE9\u40E9ter;\u6A6E\u0200aioy\u1E22\u1E27\u1E31\u1E36ron;\u411Br\u0100;c\u1E2D\u1E2E\u6256\u803B\xEA\u40EAlon;\u6255;\u444Dot;\u4117\u0100Dr\u1E41\u1E45ot;\u6252;\uC000\u{1D522}\u0180;rs\u1E50\u1E51\u1E57\u6A9Aave\u803B\xE8\u40E8\u0100;d\u1E5C\u1E5D\u6A96ot;\u6A98\u0200;ils\u1E6A\u1E6B\u1E72\u1E74\u6A99nters;\u63E7;\u6113\u0100;d\u1E79\u1E7A\u6A95ot;\u6A97\u0180aps\u1E85\u1E89\u1E97cr;\u4113ty\u0180;sv\u1E92\u1E93\u1E95\u6205et\xBB\u1E93p\u01001;\u1E9D\u1EA4\u0133\u1EA1\u1EA3;\u6004;\u6005\u6003\u0100gs\u1EAA\u1EAC;\u414Bp;\u6002\u0100gp\u1EB4\u1EB8on;\u4119f;\uC000\u{1D556}\u0180als\u1EC4\u1ECE\u1ED2r\u0100;s\u1ECA\u1ECB\u62D5l;\u69E3us;\u6A71i\u0180;lv\u1EDA\u1EDB\u1EDF\u43B5on\xBB\u1EDB;\u43F5\u0200csuv\u1EEA\u1EF3\u1F0B\u1F23\u0100io\u1EEF\u1E31rc\xBB\u1E2E\u0269\u1EF9\0\0\u1EFB\xED\u0548ant\u0100gl\u1F02\u1F06tr\xBB\u1E5Dess\xBB\u1E7A\u0180aei\u1F12\u1F16\u1F1Als;\u403Dst;\u625Fv\u0100;D\u0235\u1F20D;\u6A78parsl;\u69E5\u0100Da\u1F2F\u1F33ot;\u6253rr;\u6971\u0180cdi\u1F3E\u1F41\u1EF8r;\u612Fo\xF4\u0352\u0100ah\u1F49\u1F4B;\u43B7\u803B\xF0\u40F0\u0100mr\u1F53\u1F57l\u803B\xEB\u40EBo;\u60AC\u0180cip\u1F61\u1F64\u1F67l;\u4021s\xF4\u056E\u0100eo\u1F6C\u1F74ctatio\xEE\u0559nential\xE5\u0579\u09E1\u1F92\0\u1F9E\0\u1FA1\u1FA7\0\0\u1FC6\u1FCC\0\u1FD3\0\u1FE6\u1FEA\u2000\0\u2008\u205Allingdotse\xF1\u1E44y;\u4444male;\u6640\u0180ilr\u1FAD\u1FB3\u1FC1lig;\u8000\uFB03\u0269\u1FB9\0\0\u1FBDg;\u8000\uFB00ig;\u8000\uFB04;\uC000\u{1D523}lig;\u8000\uFB01lig;\uC000fj\u0180alt\u1FD9\u1FDC\u1FE1t;\u666Dig;\u8000\uFB02ns;\u65B1of;\u4192\u01F0\u1FEE\0\u1FF3f;\uC000\u{1D557}\u0100ak\u05BF\u1FF7\u0100;v\u1FFC\u1FFD\u62D4;\u6AD9artint;\u6A0D\u0100ao\u200C\u2055\u0100cs\u2011\u2052\u03B1\u201A\u2030\u2038\u2045\u2048\0\u2050\u03B2\u2022\u2025\u2027\u202A\u202C\0\u202E\u803B\xBD\u40BD;\u6153\u803B\xBC\u40BC;\u6155;\u6159;\u615B\u01B3\u2034\0\u2036;\u6154;\u6156\u02B4\u203E\u2041\0\0\u2043\u803B\xBE\u40BE;\u6157;\u615C5;\u6158\u01B6\u204C\0\u204E;\u615A;\u615D8;\u615El;\u6044wn;\u6322cr;\uC000\u{1D4BB}\u0880Eabcdefgijlnorstv\u2082\u2089\u209F\u20A5\u20B0\u20B4\u20F0\u20F5\u20FA\u20FF\u2103\u2112\u2138\u0317\u213E\u2152\u219E\u0100;l\u064D\u2087;\u6A8C\u0180cmp\u2090\u2095\u209Dute;\u41F5ma\u0100;d\u209C\u1CDA\u43B3;\u6A86reve;\u411F\u0100iy\u20AA\u20AErc;\u411D;\u4433ot;\u4121\u0200;lqs\u063E\u0642\u20BD\u20C9\u0180;qs\u063E\u064C\u20C4lan\xF4\u0665\u0200;cdl\u0665\u20D2\u20D5\u20E5c;\u6AA9ot\u0100;o\u20DC\u20DD\u6A80\u0100;l\u20E2\u20E3\u6A82;\u6A84\u0100;e\u20EA\u20ED\uC000\u22DB\uFE00s;\u6A94r;\uC000\u{1D524}\u0100;g\u0673\u061Bmel;\u6137cy;\u4453\u0200;Eaj\u065A\u210C\u210E\u2110;\u6A92;\u6AA5;\u6AA4\u0200Eaes\u211B\u211D\u2129\u2134;\u6269p\u0100;p\u2123\u2124\u6A8Arox\xBB\u2124\u0100;q\u212E\u212F\u6A88\u0100;q\u212E\u211Bim;\u62E7pf;\uC000\u{1D558}\u0100ci\u2143\u2146r;\u610Am\u0180;el\u066B\u214E\u2150;\u6A8E;\u6A90\u8300>;cdlqr\u05EE\u2160\u216A\u216E\u2173\u2179\u0100ci\u2165\u2167;\u6AA7r;\u6A7Aot;\u62D7Par;\u6995uest;\u6A7C\u0280adels\u2184\u216A\u2190\u0656\u219B\u01F0\u2189\0\u218Epro\xF8\u209Er;\u6978q\u0100lq\u063F\u2196les\xF3\u2088i\xED\u066B\u0100en\u21A3\u21ADrtneqq;\uC000\u2269\uFE00\xC5\u21AA\u0500Aabcefkosy\u21C4\u21C7\u21F1\u21F5\u21FA\u2218\u221D\u222F\u2268\u227Dr\xF2\u03A0\u0200ilmr\u21D0\u21D4\u21D7\u21DBrs\xF0\u1484f\xBB\u2024il\xF4\u06A9\u0100dr\u21E0\u21E4cy;\u444A\u0180;cw\u08F4\u21EB\u21EFir;\u6948;\u61ADar;\u610Firc;\u4125\u0180alr\u2201\u220E\u2213rts\u0100;u\u2209\u220A\u6665it\xBB\u220Alip;\u6026con;\u62B9r;\uC000\u{1D525}s\u0100ew\u2223\u2229arow;\u6925arow;\u6926\u0280amopr\u223A\u223E\u2243\u225E\u2263rr;\u61FFtht;\u623Bk\u0100lr\u2249\u2253eftarrow;\u61A9ightarrow;\u61AAf;\uC000\u{1D559}bar;\u6015\u0180clt\u226F\u2274\u2278r;\uC000\u{1D4BD}as\xE8\u21F4rok;\u4127\u0100bp\u2282\u2287ull;\u6043hen\xBB\u1C5B\u0AE1\u22A3\0\u22AA\0\u22B8\u22C5\u22CE\0\u22D5\u22F3\0\0\u22F8\u2322\u2367\u2362\u237F\0\u2386\u23AA\u23B4cute\u803B\xED\u40ED\u0180;iy\u0771\u22B0\u22B5rc\u803B\xEE\u40EE;\u4438\u0100cx\u22BC\u22BFy;\u4435cl\u803B\xA1\u40A1\u0100fr\u039F\u22C9;\uC000\u{1D526}rave\u803B\xEC\u40EC\u0200;ino\u073E\u22DD\u22E9\u22EE\u0100in\u22E2\u22E6nt;\u6A0Ct;\u622Dfin;\u69DCta;\u6129lig;\u4133\u0180aop\u22FE\u231A\u231D\u0180cgt\u2305\u2308\u2317r;\u412B\u0180elp\u071F\u230F\u2313in\xE5\u078Ear\xF4\u0720h;\u4131f;\u62B7ed;\u41B5\u0280;cfot\u04F4\u232C\u2331\u233D\u2341are;\u6105in\u0100;t\u2338\u2339\u621Eie;\u69DDdo\xF4\u2319\u0280;celp\u0757\u234C\u2350\u235B\u2361al;\u62BA\u0100gr\u2355\u2359er\xF3\u1563\xE3\u234Darhk;\u6A17rod;\u6A3C\u0200cgpt\u236F\u2372\u2376\u237By;\u4451on;\u412Ff;\uC000\u{1D55A}a;\u43B9uest\u803B\xBF\u40BF\u0100ci\u238A\u238Fr;\uC000\u{1D4BE}n\u0280;Edsv\u04F4\u239B\u239D\u23A1\u04F3;\u62F9ot;\u62F5\u0100;v\u23A6\u23A7\u62F4;\u62F3\u0100;i\u0777\u23AElde;\u4129\u01EB\u23B8\0\u23BCcy;\u4456l\u803B\xEF\u40EF\u0300cfmosu\u23CC\u23D7\u23DC\u23E1\u23E7\u23F5\u0100iy\u23D1\u23D5rc;\u4135;\u4439r;\uC000\u{1D527}ath;\u4237pf;\uC000\u{1D55B}\u01E3\u23EC\0\u23F1r;\uC000\u{1D4BF}rcy;\u4458kcy;\u4454\u0400acfghjos\u240B\u2416\u2422\u2427\u242D\u2431\u2435\u243Bppa\u0100;v\u2413\u2414\u43BA;\u43F0\u0100ey\u241B\u2420dil;\u4137;\u443Ar;\uC000\u{1D528}reen;\u4138cy;\u4445cy;\u445Cpf;\uC000\u{1D55C}cr;\uC000\u{1D4C0}\u0B80ABEHabcdefghjlmnoprstuv\u2470\u2481\u2486\u248D\u2491\u250E\u253D\u255A\u2580\u264E\u265E\u2665\u2679\u267D\u269A\u26B2\u26D8\u275D\u2768\u278B\u27C0\u2801\u2812\u0180art\u2477\u247A\u247Cr\xF2\u09C6\xF2\u0395ail;\u691Barr;\u690E\u0100;g\u0994\u248B;\u6A8Bar;\u6962\u0963\u24A5\0\u24AA\0\u24B1\0\0\0\0\0\u24B5\u24BA\0\u24C6\u24C8\u24CD\0\u24F9ute;\u413Amptyv;\u69B4ra\xEE\u084Cbda;\u43BBg\u0180;dl\u088E\u24C1\u24C3;\u6991\xE5\u088E;\u6A85uo\u803B\xAB\u40ABr\u0400;bfhlpst\u0899\u24DE\u24E6\u24E9\u24EB\u24EE\u24F1\u24F5\u0100;f\u089D\u24E3s;\u691Fs;\u691D\xEB\u2252p;\u61ABl;\u6939im;\u6973l;\u61A2\u0180;ae\u24FF\u2500\u2504\u6AABil;\u6919\u0100;s\u2509\u250A\u6AAD;\uC000\u2AAD\uFE00\u0180abr\u2515\u2519\u251Drr;\u690Crk;\u6772\u0100ak\u2522\u252Cc\u0100ek\u2528\u252A;\u407B;\u405B\u0100es\u2531\u2533;\u698Bl\u0100du\u2539\u253B;\u698F;\u698D\u0200aeuy\u2546\u254B\u2556\u2558ron;\u413E\u0100di\u2550\u2554il;\u413C\xEC\u08B0\xE2\u2529;\u443B\u0200cqrs\u2563\u2566\u256D\u257Da;\u6936uo\u0100;r\u0E19\u1746\u0100du\u2572\u2577har;\u6967shar;\u694Bh;\u61B2\u0280;fgqs\u258B\u258C\u0989\u25F3\u25FF\u6264t\u0280ahlrt\u2598\u25A4\u25B7\u25C2\u25E8rrow\u0100;t\u0899\u25A1a\xE9\u24F6arpoon\u0100du\u25AF\u25B4own\xBB\u045Ap\xBB\u0966eftarrows;\u61C7ight\u0180ahs\u25CD\u25D6\u25DErrow\u0100;s\u08F4\u08A7arpoon\xF3\u0F98quigarro\xF7\u21F0hreetimes;\u62CB\u0180;qs\u258B\u0993\u25FAlan\xF4\u09AC\u0280;cdgs\u09AC\u260A\u260D\u261D\u2628c;\u6AA8ot\u0100;o\u2614\u2615\u6A7F\u0100;r\u261A\u261B\u6A81;\u6A83\u0100;e\u2622\u2625\uC000\u22DA\uFE00s;\u6A93\u0280adegs\u2633\u2639\u263D\u2649\u264Bppro\xF8\u24C6ot;\u62D6q\u0100gq\u2643\u2645\xF4\u0989gt\xF2\u248C\xF4\u099Bi\xED\u09B2\u0180ilr\u2655\u08E1\u265Asht;\u697C;\uC000\u{1D529}\u0100;E\u099C\u2663;\u6A91\u0161\u2669\u2676r\u0100du\u25B2\u266E\u0100;l\u0965\u2673;\u696Alk;\u6584cy;\u4459\u0280;acht\u0A48\u2688\u268B\u2691\u2696r\xF2\u25C1orne\xF2\u1D08ard;\u696Bri;\u65FA\u0100io\u269F\u26A4dot;\u4140ust\u0100;a\u26AC\u26AD\u63B0che\xBB\u26AD\u0200Eaes\u26BB\u26BD\u26C9\u26D4;\u6268p\u0100;p\u26C3\u26C4\u6A89rox\xBB\u26C4\u0100;q\u26CE\u26CF\u6A87\u0100;q\u26CE\u26BBim;\u62E6\u0400abnoptwz\u26E9\u26F4\u26F7\u271A\u272F\u2741\u2747\u2750\u0100nr\u26EE\u26F1g;\u67ECr;\u61FDr\xEB\u08C1g\u0180lmr\u26FF\u270D\u2714eft\u0100ar\u09E6\u2707ight\xE1\u09F2apsto;\u67FCight\xE1\u09FDparrow\u0100lr\u2725\u2729ef\xF4\u24EDight;\u61AC\u0180afl\u2736\u2739\u273Dr;\u6985;\uC000\u{1D55D}us;\u6A2Dimes;\u6A34\u0161\u274B\u274Fst;\u6217\xE1\u134E\u0180;ef\u2757\u2758\u1800\u65CAnge\xBB\u2758ar\u0100;l\u2764\u2765\u4028t;\u6993\u0280achmt\u2773\u2776\u277C\u2785\u2787r\xF2\u08A8orne\xF2\u1D8Car\u0100;d\u0F98\u2783;\u696D;\u600Eri;\u62BF\u0300achiqt\u2798\u279D\u0A40\u27A2\u27AE\u27BBquo;\u6039r;\uC000\u{1D4C1}m\u0180;eg\u09B2\u27AA\u27AC;\u6A8D;\u6A8F\u0100bu\u252A\u27B3o\u0100;r\u0E1F\u27B9;\u601Arok;\u4142\u8400<;cdhilqr\u082B\u27D2\u2639\u27DC\u27E0\u27E5\u27EA\u27F0\u0100ci\u27D7\u27D9;\u6AA6r;\u6A79re\xE5\u25F2mes;\u62C9arr;\u6976uest;\u6A7B\u0100Pi\u27F5\u27F9ar;\u6996\u0180;ef\u2800\u092D\u181B\u65C3r\u0100du\u2807\u280Dshar;\u694Ahar;\u6966\u0100en\u2817\u2821rtneqq;\uC000\u2268\uFE00\xC5\u281E\u0700Dacdefhilnopsu\u2840\u2845\u2882\u288E\u2893\u28A0\u28A5\u28A8\u28DA\u28E2\u28E4\u0A83\u28F3\u2902Dot;\u623A\u0200clpr\u284E\u2852\u2863\u287Dr\u803B\xAF\u40AF\u0100et\u2857\u2859;\u6642\u0100;e\u285E\u285F\u6720se\xBB\u285F\u0100;s\u103B\u2868to\u0200;dlu\u103B\u2873\u2877\u287Bow\xEE\u048Cef\xF4\u090F\xF0\u13D1ker;\u65AE\u0100oy\u2887\u288Cmma;\u6A29;\u443Cash;\u6014asuredangle\xBB\u1626r;\uC000\u{1D52A}o;\u6127\u0180cdn\u28AF\u28B4\u28C9ro\u803B\xB5\u40B5\u0200;acd\u1464\u28BD\u28C0\u28C4s\xF4\u16A7ir;\u6AF0ot\u80BB\xB7\u01B5us\u0180;bd\u28D2\u1903\u28D3\u6212\u0100;u\u1D3C\u28D8;\u6A2A\u0163\u28DE\u28E1p;\u6ADB\xF2\u2212\xF0\u0A81\u0100dp\u28E9\u28EEels;\u62A7f;\uC000\u{1D55E}\u0100ct\u28F8\u28FDr;\uC000\u{1D4C2}pos\xBB\u159D\u0180;lm\u2909\u290A\u290D\u43BCtimap;\u62B8\u0C00GLRVabcdefghijlmoprstuvw\u2942\u2953\u297E\u2989\u2998\u29DA\u29E9\u2A15\u2A1A\u2A58\u2A5D\u2A83\u2A95\u2AA4\u2AA8\u2B04\u2B07\u2B44\u2B7F\u2BAE\u2C34\u2C67\u2C7C\u2CE9\u0100gt\u2947\u294B;\uC000\u22D9\u0338\u0100;v\u2950\u0BCF\uC000\u226B\u20D2\u0180elt\u295A\u2972\u2976ft\u0100ar\u2961\u2967rrow;\u61CDightarrow;\u61CE;\uC000\u22D8\u0338\u0100;v\u297B\u0C47\uC000\u226A\u20D2ightarrow;\u61CF\u0100Dd\u298E\u2993ash;\u62AFash;\u62AE\u0280bcnpt\u29A3\u29A7\u29AC\u29B1\u29CCla\xBB\u02DEute;\u4144g;\uC000\u2220\u20D2\u0280;Eiop\u0D84\u29BC\u29C0\u29C5\u29C8;\uC000\u2A70\u0338d;\uC000\u224B\u0338s;\u4149ro\xF8\u0D84ur\u0100;a\u29D3\u29D4\u666El\u0100;s\u29D3\u0B38\u01F3\u29DF\0\u29E3p\u80BB\xA0\u0B37mp\u0100;e\u0BF9\u0C00\u0280aeouy\u29F4\u29FE\u2A03\u2A10\u2A13\u01F0\u29F9\0\u29FB;\u6A43on;\u4148dil;\u4146ng\u0100;d\u0D7E\u2A0Aot;\uC000\u2A6D\u0338p;\u6A42;\u443Dash;\u6013\u0380;Aadqsx\u0B92\u2A29\u2A2D\u2A3B\u2A41\u2A45\u2A50rr;\u61D7r\u0100hr\u2A33\u2A36k;\u6924\u0100;o\u13F2\u13F0ot;\uC000\u2250\u0338ui\xF6\u0B63\u0100ei\u2A4A\u2A4Ear;\u6928\xED\u0B98ist\u0100;s\u0BA0\u0B9Fr;\uC000\u{1D52B}\u0200Eest\u0BC5\u2A66\u2A79\u2A7C\u0180;qs\u0BBC\u2A6D\u0BE1\u0180;qs\u0BBC\u0BC5\u2A74lan\xF4\u0BE2i\xED\u0BEA\u0100;r\u0BB6\u2A81\xBB\u0BB7\u0180Aap\u2A8A\u2A8D\u2A91r\xF2\u2971rr;\u61AEar;\u6AF2\u0180;sv\u0F8D\u2A9C\u0F8C\u0100;d\u2AA1\u2AA2\u62FC;\u62FAcy;\u445A\u0380AEadest\u2AB7\u2ABA\u2ABE\u2AC2\u2AC5\u2AF6\u2AF9r\xF2\u2966;\uC000\u2266\u0338rr;\u619Ar;\u6025\u0200;fqs\u0C3B\u2ACE\u2AE3\u2AEFt\u0100ar\u2AD4\u2AD9rro\xF7\u2AC1ightarro\xF7\u2A90\u0180;qs\u0C3B\u2ABA\u2AEAlan\xF4\u0C55\u0100;s\u0C55\u2AF4\xBB\u0C36i\xED\u0C5D\u0100;r\u0C35\u2AFEi\u0100;e\u0C1A\u0C25i\xE4\u0D90\u0100pt\u2B0C\u2B11f;\uC000\u{1D55F}\u8180\xAC;in\u2B19\u2B1A\u2B36\u40ACn\u0200;Edv\u0B89\u2B24\u2B28\u2B2E;\uC000\u22F9\u0338ot;\uC000\u22F5\u0338\u01E1\u0B89\u2B33\u2B35;\u62F7;\u62F6i\u0100;v\u0CB8\u2B3C\u01E1\u0CB8\u2B41\u2B43;\u62FE;\u62FD\u0180aor\u2B4B\u2B63\u2B69r\u0200;ast\u0B7B\u2B55\u2B5A\u2B5Flle\xEC\u0B7Bl;\uC000\u2AFD\u20E5;\uC000\u2202\u0338lint;\u6A14\u0180;ce\u0C92\u2B70\u2B73u\xE5\u0CA5\u0100;c\u0C98\u2B78\u0100;e\u0C92\u2B7D\xF1\u0C98\u0200Aait\u2B88\u2B8B\u2B9D\u2BA7r\xF2\u2988rr\u0180;cw\u2B94\u2B95\u2B99\u619B;\uC000\u2933\u0338;\uC000\u219D\u0338ghtarrow\xBB\u2B95ri\u0100;e\u0CCB\u0CD6\u0380chimpqu\u2BBD\u2BCD\u2BD9\u2B04\u0B78\u2BE4\u2BEF\u0200;cer\u0D32\u2BC6\u0D37\u2BC9u\xE5\u0D45;\uC000\u{1D4C3}ort\u026D\u2B05\0\0\u2BD6ar\xE1\u2B56m\u0100;e\u0D6E\u2BDF\u0100;q\u0D74\u0D73su\u0100bp\u2BEB\u2BED\xE5\u0CF8\xE5\u0D0B\u0180bcp\u2BF6\u2C11\u2C19\u0200;Ees\u2BFF\u2C00\u0D22\u2C04\u6284;\uC000\u2AC5\u0338et\u0100;e\u0D1B\u2C0Bq\u0100;q\u0D23\u2C00c\u0100;e\u0D32\u2C17\xF1\u0D38\u0200;Ees\u2C22\u2C23\u0D5F\u2C27\u6285;\uC000\u2AC6\u0338et\u0100;e\u0D58\u2C2Eq\u0100;q\u0D60\u2C23\u0200gilr\u2C3D\u2C3F\u2C45\u2C47\xEC\u0BD7lde\u803B\xF1\u40F1\xE7\u0C43iangle\u0100lr\u2C52\u2C5Ceft\u0100;e\u0C1A\u2C5A\xF1\u0C26ight\u0100;e\u0CCB\u2C65\xF1\u0CD7\u0100;m\u2C6C\u2C6D\u43BD\u0180;es\u2C74\u2C75\u2C79\u4023ro;\u6116p;\u6007\u0480DHadgilrs\u2C8F\u2C94\u2C99\u2C9E\u2CA3\u2CB0\u2CB6\u2CD3\u2CE3ash;\u62ADarr;\u6904p;\uC000\u224D\u20D2ash;\u62AC\u0100et\u2CA8\u2CAC;\uC000\u2265\u20D2;\uC000>\u20D2nfin;\u69DE\u0180Aet\u2CBD\u2CC1\u2CC5rr;\u6902;\uC000\u2264\u20D2\u0100;r\u2CCA\u2CCD\uC000<\u20D2ie;\uC000\u22B4\u20D2\u0100At\u2CD8\u2CDCrr;\u6903rie;\uC000\u22B5\u20D2im;\uC000\u223C\u20D2\u0180Aan\u2CF0\u2CF4\u2D02rr;\u61D6r\u0100hr\u2CFA\u2CFDk;\u6923\u0100;o\u13E7\u13E5ear;\u6927\u1253\u1A95\0\0\0\0\0\0\0\0\0\0\0\0\0\u2D2D\0\u2D38\u2D48\u2D60\u2D65\u2D72\u2D84\u1B07\0\0\u2D8D\u2DAB\0\u2DC8\u2DCE\0\u2DDC\u2E19\u2E2B\u2E3E\u2E43\u0100cs\u2D31\u1A97ute\u803B\xF3\u40F3\u0100iy\u2D3C\u2D45r\u0100;c\u1A9E\u2D42\u803B\xF4\u40F4;\u443E\u0280abios\u1AA0\u2D52\u2D57\u01C8\u2D5Alac;\u4151v;\u6A38old;\u69BClig;\u4153\u0100cr\u2D69\u2D6Dir;\u69BF;\uC000\u{1D52C}\u036F\u2D79\0\0\u2D7C\0\u2D82n;\u42DBave\u803B\xF2\u40F2;\u69C1\u0100bm\u2D88\u0DF4ar;\u69B5\u0200acit\u2D95\u2D98\u2DA5\u2DA8r\xF2\u1A80\u0100ir\u2D9D\u2DA0r;\u69BEoss;\u69BBn\xE5\u0E52;\u69C0\u0180aei\u2DB1\u2DB5\u2DB9cr;\u414Dga;\u43C9\u0180cdn\u2DC0\u2DC5\u01CDron;\u43BF;\u69B6pf;\uC000\u{1D560}\u0180ael\u2DD4\u2DD7\u01D2r;\u69B7rp;\u69B9\u0380;adiosv\u2DEA\u2DEB\u2DEE\u2E08\u2E0D\u2E10\u2E16\u6228r\xF2\u1A86\u0200;efm\u2DF7\u2DF8\u2E02\u2E05\u6A5Dr\u0100;o\u2DFE\u2DFF\u6134f\xBB\u2DFF\u803B\xAA\u40AA\u803B\xBA\u40BAgof;\u62B6r;\u6A56lope;\u6A57;\u6A5B\u0180clo\u2E1F\u2E21\u2E27\xF2\u2E01ash\u803B\xF8\u40F8l;\u6298i\u016C\u2E2F\u2E34de\u803B\xF5\u40F5es\u0100;a\u01DB\u2E3As;\u6A36ml\u803B\xF6\u40F6bar;\u633D\u0AE1\u2E5E\0\u2E7D\0\u2E80\u2E9D\0\u2EA2\u2EB9\0\0\u2ECB\u0E9C\0\u2F13\0\0\u2F2B\u2FBC\0\u2FC8r\u0200;ast\u0403\u2E67\u2E72\u0E85\u8100\xB6;l\u2E6D\u2E6E\u40B6le\xEC\u0403\u0269\u2E78\0\0\u2E7Bm;\u6AF3;\u6AFDy;\u443Fr\u0280cimpt\u2E8B\u2E8F\u2E93\u1865\u2E97nt;\u4025od;\u402Eil;\u6030enk;\u6031r;\uC000\u{1D52D}\u0180imo\u2EA8\u2EB0\u2EB4\u0100;v\u2EAD\u2EAE\u43C6;\u43D5ma\xF4\u0A76ne;\u660E\u0180;tv\u2EBF\u2EC0\u2EC8\u43C0chfork\xBB\u1FFD;\u43D6\u0100au\u2ECF\u2EDFn\u0100ck\u2ED5\u2EDDk\u0100;h\u21F4\u2EDB;\u610E\xF6\u21F4s\u0480;abcdemst\u2EF3\u2EF4\u1908\u2EF9\u2EFD\u2F04\u2F06\u2F0A\u2F0E\u402Bcir;\u6A23ir;\u6A22\u0100ou\u1D40\u2F02;\u6A25;\u6A72n\u80BB\xB1\u0E9Dim;\u6A26wo;\u6A27\u0180ipu\u2F19\u2F20\u2F25ntint;\u6A15f;\uC000\u{1D561}nd\u803B\xA3\u40A3\u0500;Eaceinosu\u0EC8\u2F3F\u2F41\u2F44\u2F47\u2F81\u2F89\u2F92\u2F7E\u2FB6;\u6AB3p;\u6AB7u\xE5\u0ED9\u0100;c\u0ECE\u2F4C\u0300;acens\u0EC8\u2F59\u2F5F\u2F66\u2F68\u2F7Eppro\xF8\u2F43urlye\xF1\u0ED9\xF1\u0ECE\u0180aes\u2F6F\u2F76\u2F7Approx;\u6AB9qq;\u6AB5im;\u62E8i\xED\u0EDFme\u0100;s\u2F88\u0EAE\u6032\u0180Eas\u2F78\u2F90\u2F7A\xF0\u2F75\u0180dfp\u0EEC\u2F99\u2FAF\u0180als\u2FA0\u2FA5\u2FAAlar;\u632Eine;\u6312urf;\u6313\u0100;t\u0EFB\u2FB4\xEF\u0EFBrel;\u62B0\u0100ci\u2FC0\u2FC5r;\uC000\u{1D4C5};\u43C8ncsp;\u6008\u0300fiopsu\u2FDA\u22E2\u2FDF\u2FE5\u2FEB\u2FF1r;\uC000\u{1D52E}pf;\uC000\u{1D562}rime;\u6057cr;\uC000\u{1D4C6}\u0180aeo\u2FF8\u3009\u3013t\u0100ei\u2FFE\u3005rnion\xF3\u06B0nt;\u6A16st\u0100;e\u3010\u3011\u403F\xF1\u1F19\xF4\u0F14\u0A80ABHabcdefhilmnoprstux\u3040\u3051\u3055\u3059\u30E0\u310E\u312B\u3147\u3162\u3172\u318E\u3206\u3215\u3224\u3229\u3258\u326E\u3272\u3290\u32B0\u32B7\u0180art\u3047\u304A\u304Cr\xF2\u10B3\xF2\u03DDail;\u691Car\xF2\u1C65ar;\u6964\u0380cdenqrt\u3068\u3075\u3078\u307F\u308F\u3094\u30CC\u0100eu\u306D\u3071;\uC000\u223D\u0331te;\u4155i\xE3\u116Emptyv;\u69B3g\u0200;del\u0FD1\u3089\u308B\u308D;\u6992;\u69A5\xE5\u0FD1uo\u803B\xBB\u40BBr\u0580;abcfhlpstw\u0FDC\u30AC\u30AF\u30B7\u30B9\u30BC\u30BE\u30C0\u30C3\u30C7\u30CAp;\u6975\u0100;f\u0FE0\u30B4s;\u6920;\u6933s;\u691E\xEB\u225D\xF0\u272El;\u6945im;\u6974l;\u61A3;\u619D\u0100ai\u30D1\u30D5il;\u691Ao\u0100;n\u30DB\u30DC\u6236al\xF3\u0F1E\u0180abr\u30E7\u30EA\u30EEr\xF2\u17E5rk;\u6773\u0100ak\u30F3\u30FDc\u0100ek\u30F9\u30FB;\u407D;\u405D\u0100es\u3102\u3104;\u698Cl\u0100du\u310A\u310C;\u698E;\u6990\u0200aeuy\u3117\u311C\u3127\u3129ron;\u4159\u0100di\u3121\u3125il;\u4157\xEC\u0FF2\xE2\u30FA;\u4440\u0200clqs\u3134\u3137\u313D\u3144a;\u6937dhar;\u6969uo\u0100;r\u020E\u020Dh;\u61B3\u0180acg\u314E\u315F\u0F44l\u0200;ips\u0F78\u3158\u315B\u109Cn\xE5\u10BBar\xF4\u0FA9t;\u65AD\u0180ilr\u3169\u1023\u316Esht;\u697D;\uC000\u{1D52F}\u0100ao\u3177\u3186r\u0100du\u317D\u317F\xBB\u047B\u0100;l\u1091\u3184;\u696C\u0100;v\u318B\u318C\u43C1;\u43F1\u0180gns\u3195\u31F9\u31FCht\u0300ahlrst\u31A4\u31B0\u31C2\u31D8\u31E4\u31EErrow\u0100;t\u0FDC\u31ADa\xE9\u30C8arpoon\u0100du\u31BB\u31BFow\xEE\u317Ep\xBB\u1092eft\u0100ah\u31CA\u31D0rrow\xF3\u0FEAarpoon\xF3\u0551ightarrows;\u61C9quigarro\xF7\u30CBhreetimes;\u62CCg;\u42DAingdotse\xF1\u1F32\u0180ahm\u320D\u3210\u3213r\xF2\u0FEAa\xF2\u0551;\u600Foust\u0100;a\u321E\u321F\u63B1che\xBB\u321Fmid;\u6AEE\u0200abpt\u3232\u323D\u3240\u3252\u0100nr\u3237\u323Ag;\u67EDr;\u61FEr\xEB\u1003\u0180afl\u3247\u324A\u324Er;\u6986;\uC000\u{1D563}us;\u6A2Eimes;\u6A35\u0100ap\u325D\u3267r\u0100;g\u3263\u3264\u4029t;\u6994olint;\u6A12ar\xF2\u31E3\u0200achq\u327B\u3280\u10BC\u3285quo;\u603Ar;\uC000\u{1D4C7}\u0100bu\u30FB\u328Ao\u0100;r\u0214\u0213\u0180hir\u3297\u329B\u32A0re\xE5\u31F8mes;\u62CAi\u0200;efl\u32AA\u1059\u1821\u32AB\u65B9tri;\u69CEluhar;\u6968;\u611E\u0D61\u32D5\u32DB\u32DF\u332C\u3338\u3371\0\u337A\u33A4\0\0\u33EC\u33F0\0\u3428\u3448\u345A\u34AD\u34B1\u34CA\u34F1\0\u3616\0\0\u3633cute;\u415Bqu\xEF\u27BA\u0500;Eaceinpsy\u11ED\u32F3\u32F5\u32FF\u3302\u330B\u330F\u331F\u3326\u3329;\u6AB4\u01F0\u32FA\0\u32FC;\u6AB8on;\u4161u\xE5\u11FE\u0100;d\u11F3\u3307il;\u415Frc;\u415D\u0180Eas\u3316\u3318\u331B;\u6AB6p;\u6ABAim;\u62E9olint;\u6A13i\xED\u1204;\u4441ot\u0180;be\u3334\u1D47\u3335\u62C5;\u6A66\u0380Aacmstx\u3346\u334A\u3357\u335B\u335E\u3363\u336Drr;\u61D8r\u0100hr\u3350\u3352\xEB\u2228\u0100;o\u0A36\u0A34t\u803B\xA7\u40A7i;\u403Bwar;\u6929m\u0100in\u3369\xF0nu\xF3\xF1t;\u6736r\u0100;o\u3376\u2055\uC000\u{1D530}\u0200acoy\u3382\u3386\u3391\u33A0rp;\u666F\u0100hy\u338B\u338Fcy;\u4449;\u4448rt\u026D\u3399\0\0\u339Ci\xE4\u1464ara\xEC\u2E6F\u803B\xAD\u40AD\u0100gm\u33A8\u33B4ma\u0180;fv\u33B1\u33B2\u33B2\u43C3;\u43C2\u0400;deglnpr\u12AB\u33C5\u33C9\u33CE\u33D6\u33DE\u33E1\u33E6ot;\u6A6A\u0100;q\u12B1\u12B0\u0100;E\u33D3\u33D4\u6A9E;\u6AA0\u0100;E\u33DB\u33DC\u6A9D;\u6A9Fe;\u6246lus;\u6A24arr;\u6972ar\xF2\u113D\u0200aeit\u33F8\u3408\u340F\u3417\u0100ls\u33FD\u3404lsetm\xE9\u336Ahp;\u6A33parsl;\u69E4\u0100dl\u1463\u3414e;\u6323\u0100;e\u341C\u341D\u6AAA\u0100;s\u3422\u3423\u6AAC;\uC000\u2AAC\uFE00\u0180flp\u342E\u3433\u3442tcy;\u444C\u0100;b\u3438\u3439\u402F\u0100;a\u343E\u343F\u69C4r;\u633Ff;\uC000\u{1D564}a\u0100dr\u344D\u0402es\u0100;u\u3454\u3455\u6660it\xBB\u3455\u0180csu\u3460\u3479\u349F\u0100au\u3465\u346Fp\u0100;s\u1188\u346B;\uC000\u2293\uFE00p\u0100;s\u11B4\u3475;\uC000\u2294\uFE00u\u0100bp\u347F\u348F\u0180;es\u1197\u119C\u3486et\u0100;e\u1197\u348D\xF1\u119D\u0180;es\u11A8\u11AD\u3496et\u0100;e\u11A8\u349D\xF1\u11AE\u0180;af\u117B\u34A6\u05B0r\u0165\u34AB\u05B1\xBB\u117Car\xF2\u1148\u0200cemt\u34B9\u34BE\u34C2\u34C5r;\uC000\u{1D4C8}tm\xEE\xF1i\xEC\u3415ar\xE6\u11BE\u0100ar\u34CE\u34D5r\u0100;f\u34D4\u17BF\u6606\u0100an\u34DA\u34EDight\u0100ep\u34E3\u34EApsilo\xEE\u1EE0h\xE9\u2EAFs\xBB\u2852\u0280bcmnp\u34FB\u355E\u1209\u358B\u358E\u0480;Edemnprs\u350E\u350F\u3511\u3515\u351E\u3523\u352C\u3531\u3536\u6282;\u6AC5ot;\u6ABD\u0100;d\u11DA\u351Aot;\u6AC3ult;\u6AC1\u0100Ee\u3528\u352A;\u6ACB;\u628Alus;\u6ABFarr;\u6979\u0180eiu\u353D\u3552\u3555t\u0180;en\u350E\u3545\u354Bq\u0100;q\u11DA\u350Feq\u0100;q\u352B\u3528m;\u6AC7\u0100bp\u355A\u355C;\u6AD5;\u6AD3c\u0300;acens\u11ED\u356C\u3572\u3579\u357B\u3326ppro\xF8\u32FAurlye\xF1\u11FE\xF1\u11F3\u0180aes\u3582\u3588\u331Bppro\xF8\u331Aq\xF1\u3317g;\u666A\u0680123;Edehlmnps\u35A9\u35AC\u35AF\u121C\u35B2\u35B4\u35C0\u35C9\u35D5\u35DA\u35DF\u35E8\u35ED\u803B\xB9\u40B9\u803B\xB2\u40B2\u803B\xB3\u40B3;\u6AC6\u0100os\u35B9\u35BCt;\u6ABEub;\u6AD8\u0100;d\u1222\u35C5ot;\u6AC4s\u0100ou\u35CF\u35D2l;\u67C9b;\u6AD7arr;\u697Bult;\u6AC2\u0100Ee\u35E4\u35E6;\u6ACC;\u628Blus;\u6AC0\u0180eiu\u35F4\u3609\u360Ct\u0180;en\u121C\u35FC\u3602q\u0100;q\u1222\u35B2eq\u0100;q\u35E7\u35E4m;\u6AC8\u0100bp\u3611\u3613;\u6AD4;\u6AD6\u0180Aan\u361C\u3620\u362Drr;\u61D9r\u0100hr\u3626\u3628\xEB\u222E\u0100;o\u0A2B\u0A29war;\u692Alig\u803B\xDF\u40DF\u0BE1\u3651\u365D\u3660\u12CE\u3673\u3679\0\u367E\u36C2\0\0\0\0\0\u36DB\u3703\0\u3709\u376C\0\0\0\u3787\u0272\u3656\0\0\u365Bget;\u6316;\u43C4r\xEB\u0E5F\u0180aey\u3666\u366B\u3670ron;\u4165dil;\u4163;\u4442lrec;\u6315r;\uC000\u{1D531}\u0200eiko\u3686\u369D\u36B5\u36BC\u01F2\u368B\0\u3691e\u01004f\u1284\u1281a\u0180;sv\u3698\u3699\u369B\u43B8ym;\u43D1\u0100cn\u36A2\u36B2k\u0100as\u36A8\u36AEppro\xF8\u12C1im\xBB\u12ACs\xF0\u129E\u0100as\u36BA\u36AE\xF0\u12C1rn\u803B\xFE\u40FE\u01EC\u031F\u36C6\u22E7es\u8180\xD7;bd\u36CF\u36D0\u36D8\u40D7\u0100;a\u190F\u36D5r;\u6A31;\u6A30\u0180eps\u36E1\u36E3\u3700\xE1\u2A4D\u0200;bcf\u0486\u36EC\u36F0\u36F4ot;\u6336ir;\u6AF1\u0100;o\u36F9\u36FC\uC000\u{1D565}rk;\u6ADA\xE1\u3362rime;\u6034\u0180aip\u370F\u3712\u3764d\xE5\u1248\u0380adempst\u3721\u374D\u3740\u3751\u3757\u375C\u375Fngle\u0280;dlqr\u3730\u3731\u3736\u3740\u3742\u65B5own\xBB\u1DBBeft\u0100;e\u2800\u373E\xF1\u092E;\u625Cight\u0100;e\u32AA\u374B\xF1\u105Aot;\u65ECinus;\u6A3Alus;\u6A39b;\u69CDime;\u6A3Bezium;\u63E2\u0180cht\u3772\u377D\u3781\u0100ry\u3777\u377B;\uC000\u{1D4C9};\u4446cy;\u445Brok;\u4167\u0100io\u378B\u378Ex\xF4\u1777head\u0100lr\u3797\u37A0eftarro\xF7\u084Fightarrow\xBB\u0F5D\u0900AHabcdfghlmoprstuw\u37D0\u37D3\u37D7\u37E4\u37F0\u37FC\u380E\u381C\u3823\u3834\u3851\u385D\u386B\u38A9\u38CC\u38D2\u38EA\u38F6r\xF2\u03EDar;\u6963\u0100cr\u37DC\u37E2ute\u803B\xFA\u40FA\xF2\u1150r\u01E3\u37EA\0\u37EDy;\u445Eve;\u416D\u0100iy\u37F5\u37FArc\u803B\xFB\u40FB;\u4443\u0180abh\u3803\u3806\u380Br\xF2\u13ADlac;\u4171a\xF2\u13C3\u0100ir\u3813\u3818sht;\u697E;\uC000\u{1D532}rave\u803B\xF9\u40F9\u0161\u3827\u3831r\u0100lr\u382C\u382E\xBB\u0957\xBB\u1083lk;\u6580\u0100ct\u3839\u384D\u026F\u383F\0\0\u384Arn\u0100;e\u3845\u3846\u631Cr\xBB\u3846op;\u630Fri;\u65F8\u0100al\u3856\u385Acr;\u416B\u80BB\xA8\u0349\u0100gp\u3862\u3866on;\u4173f;\uC000\u{1D566}\u0300adhlsu\u114B\u3878\u387D\u1372\u3891\u38A0own\xE1\u13B3arpoon\u0100lr\u3888\u388Cef\xF4\u382Digh\xF4\u382Fi\u0180;hl\u3899\u389A\u389C\u43C5\xBB\u13FAon\xBB\u389Aparrows;\u61C8\u0180cit\u38B0\u38C4\u38C8\u026F\u38B6\0\0\u38C1rn\u0100;e\u38BC\u38BD\u631Dr\xBB\u38BDop;\u630Eng;\u416Fri;\u65F9cr;\uC000\u{1D4CA}\u0180dir\u38D9\u38DD\u38E2ot;\u62F0lde;\u4169i\u0100;f\u3730\u38E8\xBB\u1813\u0100am\u38EF\u38F2r\xF2\u38A8l\u803B\xFC\u40FCangle;\u69A7\u0780ABDacdeflnoprsz\u391C\u391F\u3929\u392D\u39B5\u39B8\u39BD\u39DF\u39E4\u39E8\u39F3\u39F9\u39FD\u3A01\u3A20r\xF2\u03F7ar\u0100;v\u3926\u3927\u6AE8;\u6AE9as\xE8\u03E1\u0100nr\u3932\u3937grt;\u699C\u0380eknprst\u34E3\u3946\u394B\u3952\u395D\u3964\u3996app\xE1\u2415othin\xE7\u1E96\u0180hir\u34EB\u2EC8\u3959op\xF4\u2FB5\u0100;h\u13B7\u3962\xEF\u318D\u0100iu\u3969\u396Dgm\xE1\u33B3\u0100bp\u3972\u3984setneq\u0100;q\u397D\u3980\uC000\u228A\uFE00;\uC000\u2ACB\uFE00setneq\u0100;q\u398F\u3992\uC000\u228B\uFE00;\uC000\u2ACC\uFE00\u0100hr\u399B\u399Fet\xE1\u369Ciangle\u0100lr\u39AA\u39AFeft\xBB\u0925ight\xBB\u1051y;\u4432ash\xBB\u1036\u0180elr\u39C4\u39D2\u39D7\u0180;be\u2DEA\u39CB\u39CFar;\u62BBq;\u625Alip;\u62EE\u0100bt\u39DC\u1468a\xF2\u1469r;\uC000\u{1D533}tr\xE9\u39AEsu\u0100bp\u39EF\u39F1\xBB\u0D1C\xBB\u0D59pf;\uC000\u{1D567}ro\xF0\u0EFBtr\xE9\u39B4\u0100cu\u3A06\u3A0Br;\uC000\u{1D4CB}\u0100bp\u3A10\u3A18n\u0100Ee\u3980\u3A16\xBB\u397En\u0100Ee\u3992\u3A1E\xBB\u3990igzag;\u699A\u0380cefoprs\u3A36\u3A3B\u3A56\u3A5B\u3A54\u3A61\u3A6Airc;\u4175\u0100di\u3A40\u3A51\u0100bg\u3A45\u3A49ar;\u6A5Fe\u0100;q\u15FA\u3A4F;\u6259erp;\u6118r;\uC000\u{1D534}pf;\uC000\u{1D568}\u0100;e\u1479\u3A66at\xE8\u1479cr;\uC000\u{1D4CC}\u0AE3\u178E\u3A87\0\u3A8B\0\u3A90\u3A9B\0\0\u3A9D\u3AA8\u3AAB\u3AAF\0\0\u3AC3\u3ACE\0\u3AD8\u17DC\u17DFtr\xE9\u17D1r;\uC000\u{1D535}\u0100Aa\u3A94\u3A97r\xF2\u03C3r\xF2\u09F6;\u43BE\u0100Aa\u3AA1\u3AA4r\xF2\u03B8r\xF2\u09EBa\xF0\u2713is;\u62FB\u0180dpt\u17A4\u3AB5\u3ABE\u0100fl\u3ABA\u17A9;\uC000\u{1D569}im\xE5\u17B2\u0100Aa\u3AC7\u3ACAr\xF2\u03CEr\xF2\u0A01\u0100cq\u3AD2\u17B8r;\uC000\u{1D4CD}\u0100pt\u17D6\u3ADCr\xE9\u17D4\u0400acefiosu\u3AF0\u3AFD\u3B08\u3B0C\u3B11\u3B15\u3B1B\u3B21c\u0100uy\u3AF6\u3AFBte\u803B\xFD\u40FD;\u444F\u0100iy\u3B02\u3B06rc;\u4177;\u444Bn\u803B\xA5\u40A5r;\uC000\u{1D536}cy;\u4457pf;\uC000\u{1D56A}cr;\uC000\u{1D4CE}\u0100cm\u3B26\u3B29y;\u444El\u803B\xFF\u40FF\u0500acdefhiosw\u3B42\u3B48\u3B54\u3B58\u3B64\u3B69\u3B6D\u3B74\u3B7A\u3B80cute;\u417A\u0100ay\u3B4D\u3B52ron;\u417E;\u4437ot;\u417C\u0100et\u3B5D\u3B61tr\xE6\u155Fa;\u43B6r;\uC000\u{1D537}cy;\u4436grarr;\u61DDpf;\uC000\u{1D56B}cr;\uC000\u{1D4CF}\u0100jn\u3B85\u3B87;\u600Dj;\u600C'.split("").map((e9) => e9.charCodeAt(0)));
var Yde;
var bDt = /* @__PURE__ */ new Map([[0, 65533], [128, 8364], [130, 8218], [131, 402], [132, 8222], [133, 8230], [134, 8224], [135, 8225], [136, 710], [137, 8240], [138, 352], [139, 8249], [140, 338], [142, 381], [145, 8216], [146, 8217], [147, 8220], [148, 8221], [149, 8226], [150, 8211], [151, 8212], [152, 732], [153, 8482], [154, 353], [155, 8250], [156, 339], [158, 382], [159, 376]]);
function Qde(e9) {
  var t;
  return e9 >= 55296 && e9 <= 57343 || e9 > 1114111 ? 65533 : (t = bDt.get(e9)) !== null && t !== void 0 ? t : e9;
}
var wx;
(function(e9) {
  e9[e9.NUM = 35] = "NUM", e9[e9.SEMI = 59] = "SEMI", e9[e9.EQUALS = 61] = "EQUALS", e9[e9.ZERO = 48] = "ZERO", e9[e9.NINE = 57] = "NINE", e9[e9.LOWER_A = 97] = "LOWER_A", e9[e9.LOWER_F = 102] = "LOWER_F", e9[e9.LOWER_X = 120] = "LOWER_X", e9[e9.LOWER_Z = 122] = "LOWER_Z", e9[e9.UPPER_A = 65] = "UPPER_A", e9[e9.UPPER_F = 70] = "UPPER_F", e9[e9.UPPER_Z = 90] = "UPPER_Z";
})(wx || (wx = {}));
var ADt = 32;
var i7;
(function(e9) {
  e9[e9.VALUE_LENGTH = 49152] = "VALUE_LENGTH", e9[e9.BRANCH_LENGTH = 16256] = "BRANCH_LENGTH", e9[e9.JUMP_TABLE = 127] = "JUMP_TABLE";
})(i7 || (i7 = {}));
function Zde(e9) {
  return e9 >= wx.ZERO && e9 <= wx.NINE;
}
function kDt(e9) {
  return e9 >= wx.UPPER_A && e9 <= wx.UPPER_F || e9 >= wx.LOWER_A && e9 <= wx.LOWER_F;
}
function vDt(e9) {
  return e9 >= wx.UPPER_A && e9 <= wx.UPPER_Z || e9 >= wx.LOWER_A && e9 <= wx.LOWER_Z || Zde(e9);
}
function _Dt(e9) {
  return e9 === wx.EQUALS || vDt(e9);
}
var _x;
(function(e9) {
  e9[e9.EntityStart = 0] = "EntityStart", e9[e9.NumericStart = 1] = "NumericStart", e9[e9.NumericDecimal = 2] = "NumericDecimal", e9[e9.NumericHex = 3] = "NumericHex", e9[e9.NamedEntity = 4] = "NamedEntity";
})(_x || (_x = {}));
var w1;
(function(e9) {
  e9[e9.Legacy = 0] = "Legacy", e9[e9.Strict = 1] = "Strict", e9[e9.Attribute = 2] = "Attribute";
})(w1 || (w1 = {}));
var EH = class {
  constructor(t, n, s) {
    this.decodeTree = t, this.emitCodePoint = n, this.errors = s, this.state = _x.EntityStart, this.consumed = 1, this.result = 0, this.treeIndex = 0, this.excess = 1, this.decodeMode = w1.Strict;
  }
  startEntity(t) {
    this.decodeMode = t, this.state = _x.EntityStart, this.result = 0, this.treeIndex = 0, this.excess = 1, this.consumed = 1;
  }
  write(t, n) {
    switch (this.state) {
      case _x.EntityStart:
        return t.charCodeAt(n) === wx.NUM ? (this.state = _x.NumericStart, this.consumed += 1, this.stateNumericStart(t, n + 1)) : (this.state = _x.NamedEntity, this.stateNamedEntity(t, n));
      case _x.NumericStart:
        return this.stateNumericStart(t, n);
      case _x.NumericDecimal:
        return this.stateNumericDecimal(t, n);
      case _x.NumericHex:
        return this.stateNumericHex(t, n);
      case _x.NamedEntity:
        return this.stateNamedEntity(t, n);
    }
  }
  stateNumericStart(t, n) {
    return n >= t.length ? -1 : (t.charCodeAt(n) | ADt) === wx.LOWER_X ? (this.state = _x.NumericHex, this.consumed += 1, this.stateNumericHex(t, n + 1)) : (this.state = _x.NumericDecimal, this.stateNumericDecimal(t, n));
  }
  addToNumericResult(t, n, s, c) {
    if (n !== s) {
      let l = s - n;
      this.result = this.result * Math.pow(c, l) + Number.parseInt(t.substr(n, l), c), this.consumed += l;
    }
  }
  stateNumericHex(t, n) {
    let s = n;
    for (; n < t.length; ) {
      let c = t.charCodeAt(n);
      if (Zde(c) || kDt(c)) n += 1;
      else return this.addToNumericResult(t, s, n, 16), this.emitNumericEntity(c, 3);
    }
    return this.addToNumericResult(t, s, n, 16), -1;
  }
  stateNumericDecimal(t, n) {
    let s = n;
    for (; n < t.length; ) {
      let c = t.charCodeAt(n);
      if (Zde(c)) n += 1;
      else return this.addToNumericResult(t, s, n, 10), this.emitNumericEntity(c, 2);
    }
    return this.addToNumericResult(t, s, n, 10), -1;
  }
  emitNumericEntity(t, n) {
    var s;
    if (this.consumed <= n) return (s = this.errors) === null || s === void 0 || s.absenceOfDigitsInNumericCharacterReference(this.consumed), 0;
    if (t === wx.SEMI) this.consumed += 1;
    else if (this.decodeMode === w1.Strict) return 0;
    return this.emitCodePoint(Qde(this.result), this.consumed), this.errors && (t !== wx.SEMI && this.errors.missingSemicolonAfterCharacterReference(), this.errors.validateNumericCharacterReference(this.result)), this.consumed;
  }
  stateNamedEntity(t, n) {
    let { decodeTree: s } = this, c = s[this.treeIndex], l = (c & i7.VALUE_LENGTH) >> 14;
    for (; n < t.length; n++, this.excess++) {
      let d = t.charCodeAt(n);
      if (this.treeIndex = wDt(s, c, this.treeIndex + Math.max(1, l), d), this.treeIndex < 0) return this.result === 0 || this.decodeMode === w1.Attribute && (l === 0 || _Dt(d)) ? 0 : this.emitNotTerminatedNamedEntity();
      if (c = s[this.treeIndex], l = (c & i7.VALUE_LENGTH) >> 14, l !== 0) {
        if (d === wx.SEMI) return this.emitNamedEntityData(this.treeIndex, l, this.consumed + this.excess);
        this.decodeMode !== w1.Strict && (this.result = this.treeIndex, this.consumed += this.excess, this.excess = 0);
      }
    }
    return -1;
  }
  emitNotTerminatedNamedEntity() {
    var t;
    let { result: n, decodeTree: s } = this, c = (s[n] & i7.VALUE_LENGTH) >> 14;
    return this.emitNamedEntityData(n, c, this.consumed), (t = this.errors) === null || t === void 0 || t.missingSemicolonAfterCharacterReference(), this.consumed;
  }
  emitNamedEntityData(t, n, s) {
    let { decodeTree: c } = this;
    return this.emitCodePoint(n === 1 ? c[t] & ~i7.VALUE_LENGTH : c[t + 1], s), n === 3 && this.emitCodePoint(c[t + 2], s), s;
  }
  end() {
    var t;
    switch (this.state) {
      case _x.NamedEntity:
        return this.result !== 0 && (this.decodeMode !== w1.Attribute || this.result === this.treeIndex) ? this.emitNotTerminatedNamedEntity() : 0;
      case _x.NumericDecimal:
        return this.emitNumericEntity(0, 2);
      case _x.NumericHex:
        return this.emitNumericEntity(0, 3);
      case _x.NumericStart:
        return (t = this.errors) === null || t === void 0 || t.absenceOfDigitsInNumericCharacterReference(this.consumed), 0;
      case _x.EntityStart:
        return 0;
    }
  }
};
function wDt(e9, t, n, s) {
  let c = (t & i7.BRANCH_LENGTH) >> 7, l = t & i7.JUMP_TABLE;
  if (c === 0) return l !== 0 && s === l ? n : -1;
  if (l) {
    let g = s - l;
    return g < 0 || g >= c ? -1 : e9[n + g] - 1;
  }
  let d = n, m = d + c - 1;
  for (; d <= m; ) {
    let g = d + m >>> 1, y = e9[g];
    if (y < s) d = g + 1;
    else if (y > s) m = g - 1;
    else return e9[g + c];
  }
  return -1;
}
var TH = {};
var G0;
(function(e9) {
  e9.HTML = "http://www.w3.org/1999/xhtml", e9.MATHML = "http://www.w3.org/1998/Math/MathML", e9.SVG = "http://www.w3.org/2000/svg", e9.XLINK = "http://www.w3.org/1999/xlink", e9.XML = "http://www.w3.org/XML/1998/namespace", e9.XMLNS = "http://www.w3.org/2000/xmlns/";
})(G0 || (G0 = {}));
var S1;
(function(e9) {
  e9.TYPE = "type", e9.ACTION = "action", e9.ENCODING = "encoding", e9.PROMPT = "prompt", e9.NAME = "name", e9.COLOR = "color", e9.FACE = "face", e9.SIZE = "size";
})(S1 || (S1 = {}));
var $c;
(function(e9) {
  e9.NO_QUIRKS = "no-quirks", e9.QUIRKS = "quirks", e9.LIMITED_QUIRKS = "limited-quirks";
})($c || ($c = {}));
var d0;
(function(e9) {
  e9.A = "a", e9.ADDRESS = "address", e9.ANNOTATION_XML = "annotation-xml", e9.APPLET = "applet", e9.AREA = "area", e9.ARTICLE = "article", e9.ASIDE = "aside", e9.B = "b", e9.BASE = "base", e9.BASEFONT = "basefont", e9.BGSOUND = "bgsound", e9.BIG = "big", e9.BLOCKQUOTE = "blockquote", e9.BODY = "body", e9.BR = "br", e9.BUTTON = "button", e9.CAPTION = "caption", e9.CENTER = "center", e9.CODE = "code", e9.COL = "col", e9.COLGROUP = "colgroup", e9.DD = "dd", e9.DESC = "desc", e9.DETAILS = "details", e9.DIALOG = "dialog", e9.DIR = "dir", e9.DIV = "div", e9.DL = "dl", e9.DT = "dt", e9.EM = "em", e9.EMBED = "embed", e9.FIELDSET = "fieldset", e9.FIGCAPTION = "figcaption", e9.FIGURE = "figure", e9.FONT = "font", e9.FOOTER = "footer", e9.FOREIGN_OBJECT = "foreignObject", e9.FORM = "form", e9.FRAME = "frame", e9.FRAMESET = "frameset", e9.H1 = "h1", e9.H2 = "h2", e9.H3 = "h3", e9.H4 = "h4", e9.H5 = "h5", e9.H6 = "h6", e9.HEAD = "head", e9.HEADER = "header", e9.HGROUP = "hgroup", e9.HR = "hr", e9.HTML = "html", e9.I = "i", e9.IMG = "img", e9.IMAGE = "image", e9.INPUT = "input", e9.IFRAME = "iframe", e9.KEYGEN = "keygen", e9.LABEL = "label", e9.LI = "li", e9.LINK = "link", e9.LISTING = "listing", e9.MAIN = "main", e9.MALIGNMARK = "malignmark", e9.MARQUEE = "marquee", e9.MATH = "math", e9.MENU = "menu", e9.META = "meta", e9.MGLYPH = "mglyph", e9.MI = "mi", e9.MO = "mo", e9.MN = "mn", e9.MS = "ms", e9.MTEXT = "mtext", e9.NAV = "nav", e9.NOBR = "nobr", e9.NOFRAMES = "noframes", e9.NOEMBED = "noembed", e9.NOSCRIPT = "noscript", e9.OBJECT = "object", e9.OL = "ol", e9.OPTGROUP = "optgroup", e9.OPTION = "option", e9.P = "p", e9.PARAM = "param", e9.PLAINTEXT = "plaintext", e9.PRE = "pre", e9.RB = "rb", e9.RP = "rp", e9.RT = "rt", e9.RTC = "rtc", e9.RUBY = "ruby", e9.S = "s", e9.SCRIPT = "script", e9.SEARCH = "search", e9.SECTION = "section", e9.SELECT = "select", e9.SOURCE = "source", e9.SMALL = "small", e9.SPAN = "span", e9.STRIKE = "strike", e9.STRONG = "strong", e9.STYLE = "style", e9.SUB = "sub", e9.SUMMARY = "summary", e9.SUP = "sup", e9.TABLE = "table", e9.TBODY = "tbody", e9.TEMPLATE = "template", e9.TEXTAREA = "textarea", e9.TFOOT = "tfoot", e9.TD = "td", e9.TH = "th", e9.THEAD = "thead", e9.TITLE = "title", e9.TR = "tr", e9.TRACK = "track", e9.TT = "tt", e9.U = "u", e9.UL = "ul", e9.SVG = "svg", e9.VAR = "var", e9.WBR = "wbr", e9.XMP = "xmp";
})(d0 || (d0 = {}));
var Z;
(function(e9) {
  e9[e9.UNKNOWN = 0] = "UNKNOWN", e9[e9.A = 1] = "A", e9[e9.ADDRESS = 2] = "ADDRESS", e9[e9.ANNOTATION_XML = 3] = "ANNOTATION_XML", e9[e9.APPLET = 4] = "APPLET", e9[e9.AREA = 5] = "AREA", e9[e9.ARTICLE = 6] = "ARTICLE", e9[e9.ASIDE = 7] = "ASIDE", e9[e9.B = 8] = "B", e9[e9.BASE = 9] = "BASE", e9[e9.BASEFONT = 10] = "BASEFONT", e9[e9.BGSOUND = 11] = "BGSOUND", e9[e9.BIG = 12] = "BIG", e9[e9.BLOCKQUOTE = 13] = "BLOCKQUOTE", e9[e9.BODY = 14] = "BODY", e9[e9.BR = 15] = "BR", e9[e9.BUTTON = 16] = "BUTTON", e9[e9.CAPTION = 17] = "CAPTION", e9[e9.CENTER = 18] = "CENTER", e9[e9.CODE = 19] = "CODE", e9[e9.COL = 20] = "COL", e9[e9.COLGROUP = 21] = "COLGROUP", e9[e9.DD = 22] = "DD", e9[e9.DESC = 23] = "DESC", e9[e9.DETAILS = 24] = "DETAILS", e9[e9.DIALOG = 25] = "DIALOG", e9[e9.DIR = 26] = "DIR", e9[e9.DIV = 27] = "DIV", e9[e9.DL = 28] = "DL", e9[e9.DT = 29] = "DT", e9[e9.EM = 30] = "EM", e9[e9.EMBED = 31] = "EMBED", e9[e9.FIELDSET = 32] = "FIELDSET", e9[e9.FIGCAPTION = 33] = "FIGCAPTION", e9[e9.FIGURE = 34] = "FIGURE", e9[e9.FONT = 35] = "FONT", e9[e9.FOOTER = 36] = "FOOTER", e9[e9.FOREIGN_OBJECT = 37] = "FOREIGN_OBJECT", e9[e9.FORM = 38] = "FORM", e9[e9.FRAME = 39] = "FRAME", e9[e9.FRAMESET = 40] = "FRAMESET", e9[e9.H1 = 41] = "H1", e9[e9.H2 = 42] = "H2", e9[e9.H3 = 43] = "H3", e9[e9.H4 = 44] = "H4", e9[e9.H5 = 45] = "H5", e9[e9.H6 = 46] = "H6", e9[e9.HEAD = 47] = "HEAD", e9[e9.HEADER = 48] = "HEADER", e9[e9.HGROUP = 49] = "HGROUP", e9[e9.HR = 50] = "HR", e9[e9.HTML = 51] = "HTML", e9[e9.I = 52] = "I", e9[e9.IMG = 53] = "IMG", e9[e9.IMAGE = 54] = "IMAGE", e9[e9.INPUT = 55] = "INPUT", e9[e9.IFRAME = 56] = "IFRAME", e9[e9.KEYGEN = 57] = "KEYGEN", e9[e9.LABEL = 58] = "LABEL", e9[e9.LI = 59] = "LI", e9[e9.LINK = 60] = "LINK", e9[e9.LISTING = 61] = "LISTING", e9[e9.MAIN = 62] = "MAIN", e9[e9.MALIGNMARK = 63] = "MALIGNMARK", e9[e9.MARQUEE = 64] = "MARQUEE", e9[e9.MATH = 65] = "MATH", e9[e9.MENU = 66] = "MENU", e9[e9.META = 67] = "META", e9[e9.MGLYPH = 68] = "MGLYPH", e9[e9.MI = 69] = "MI", e9[e9.MO = 70] = "MO", e9[e9.MN = 71] = "MN", e9[e9.MS = 72] = "MS", e9[e9.MTEXT = 73] = "MTEXT", e9[e9.NAV = 74] = "NAV", e9[e9.NOBR = 75] = "NOBR", e9[e9.NOFRAMES = 76] = "NOFRAMES", e9[e9.NOEMBED = 77] = "NOEMBED", e9[e9.NOSCRIPT = 78] = "NOSCRIPT", e9[e9.OBJECT = 79] = "OBJECT", e9[e9.OL = 80] = "OL", e9[e9.OPTGROUP = 81] = "OPTGROUP", e9[e9.OPTION = 82] = "OPTION", e9[e9.P = 83] = "P", e9[e9.PARAM = 84] = "PARAM", e9[e9.PLAINTEXT = 85] = "PLAINTEXT", e9[e9.PRE = 86] = "PRE", e9[e9.RB = 87] = "RB", e9[e9.RP = 88] = "RP", e9[e9.RT = 89] = "RT", e9[e9.RTC = 90] = "RTC", e9[e9.RUBY = 91] = "RUBY", e9[e9.S = 92] = "S", e9[e9.SCRIPT = 93] = "SCRIPT", e9[e9.SEARCH = 94] = "SEARCH", e9[e9.SECTION = 95] = "SECTION", e9[e9.SELECT = 96] = "SELECT", e9[e9.SOURCE = 97] = "SOURCE", e9[e9.SMALL = 98] = "SMALL", e9[e9.SPAN = 99] = "SPAN", e9[e9.STRIKE = 100] = "STRIKE", e9[e9.STRONG = 101] = "STRONG", e9[e9.STYLE = 102] = "STYLE", e9[e9.SUB = 103] = "SUB", e9[e9.SUMMARY = 104] = "SUMMARY", e9[e9.SUP = 105] = "SUP", e9[e9.TABLE = 106] = "TABLE", e9[e9.TBODY = 107] = "TBODY", e9[e9.TEMPLATE = 108] = "TEMPLATE", e9[e9.TEXTAREA = 109] = "TEXTAREA", e9[e9.TFOOT = 110] = "TFOOT", e9[e9.TD = 111] = "TD", e9[e9.TH = 112] = "TH", e9[e9.THEAD = 113] = "THEAD", e9[e9.TITLE = 114] = "TITLE", e9[e9.TR = 115] = "TR", e9[e9.TRACK = 116] = "TRACK", e9[e9.TT = 117] = "TT", e9[e9.U = 118] = "U", e9[e9.UL = 119] = "UL", e9[e9.SVG = 120] = "SVG", e9[e9.VAR = 121] = "VAR", e9[e9.WBR = 122] = "WBR", e9[e9.XMP = 123] = "XMP";
})(Z || (Z = {}));
var SDt = /* @__PURE__ */ new Map([[d0.A, Z.A], [d0.ADDRESS, Z.ADDRESS], [d0.ANNOTATION_XML, Z.ANNOTATION_XML], [d0.APPLET, Z.APPLET], [d0.AREA, Z.AREA], [d0.ARTICLE, Z.ARTICLE], [d0.ASIDE, Z.ASIDE], [d0.B, Z.B], [d0.BASE, Z.BASE], [d0.BASEFONT, Z.BASEFONT], [d0.BGSOUND, Z.BGSOUND], [d0.BIG, Z.BIG], [d0.BLOCKQUOTE, Z.BLOCKQUOTE], [d0.BODY, Z.BODY], [d0.BR, Z.BR], [d0.BUTTON, Z.BUTTON], [d0.CAPTION, Z.CAPTION], [d0.CENTER, Z.CENTER], [d0.CODE, Z.CODE], [d0.COL, Z.COL], [d0.COLGROUP, Z.COLGROUP], [d0.DD, Z.DD], [d0.DESC, Z.DESC], [d0.DETAILS, Z.DETAILS], [d0.DIALOG, Z.DIALOG], [d0.DIR, Z.DIR], [d0.DIV, Z.DIV], [d0.DL, Z.DL], [d0.DT, Z.DT], [d0.EM, Z.EM], [d0.EMBED, Z.EMBED], [d0.FIELDSET, Z.FIELDSET], [d0.FIGCAPTION, Z.FIGCAPTION], [d0.FIGURE, Z.FIGURE], [d0.FONT, Z.FONT], [d0.FOOTER, Z.FOOTER], [d0.FOREIGN_OBJECT, Z.FOREIGN_OBJECT], [d0.FORM, Z.FORM], [d0.FRAME, Z.FRAME], [d0.FRAMESET, Z.FRAMESET], [d0.H1, Z.H1], [d0.H2, Z.H2], [d0.H3, Z.H3], [d0.H4, Z.H4], [d0.H5, Z.H5], [d0.H6, Z.H6], [d0.HEAD, Z.HEAD], [d0.HEADER, Z.HEADER], [d0.HGROUP, Z.HGROUP], [d0.HR, Z.HR], [d0.HTML, Z.HTML], [d0.I, Z.I], [d0.IMG, Z.IMG], [d0.IMAGE, Z.IMAGE], [d0.INPUT, Z.INPUT], [d0.IFRAME, Z.IFRAME], [d0.KEYGEN, Z.KEYGEN], [d0.LABEL, Z.LABEL], [d0.LI, Z.LI], [d0.LINK, Z.LINK], [d0.LISTING, Z.LISTING], [d0.MAIN, Z.MAIN], [d0.MALIGNMARK, Z.MALIGNMARK], [d0.MARQUEE, Z.MARQUEE], [d0.MATH, Z.MATH], [d0.MENU, Z.MENU], [d0.META, Z.META], [d0.MGLYPH, Z.MGLYPH], [d0.MI, Z.MI], [d0.MO, Z.MO], [d0.MN, Z.MN], [d0.MS, Z.MS], [d0.MTEXT, Z.MTEXT], [d0.NAV, Z.NAV], [d0.NOBR, Z.NOBR], [d0.NOFRAMES, Z.NOFRAMES], [d0.NOEMBED, Z.NOEMBED], [d0.NOSCRIPT, Z.NOSCRIPT], [d0.OBJECT, Z.OBJECT], [d0.OL, Z.OL], [d0.OPTGROUP, Z.OPTGROUP], [d0.OPTION, Z.OPTION], [d0.P, Z.P], [d0.PARAM, Z.PARAM], [d0.PLAINTEXT, Z.PLAINTEXT], [d0.PRE, Z.PRE], [d0.RB, Z.RB], [d0.RP, Z.RP], [d0.RT, Z.RT], [d0.RTC, Z.RTC], [d0.RUBY, Z.RUBY], [d0.S, Z.S], [d0.SCRIPT, Z.SCRIPT], [d0.SEARCH, Z.SEARCH], [d0.SECTION, Z.SECTION], [d0.SELECT, Z.SELECT], [d0.SOURCE, Z.SOURCE], [d0.SMALL, Z.SMALL], [d0.SPAN, Z.SPAN], [d0.STRIKE, Z.STRIKE], [d0.STRONG, Z.STRONG], [d0.STYLE, Z.STYLE], [d0.SUB, Z.SUB], [d0.SUMMARY, Z.SUMMARY], [d0.SUP, Z.SUP], [d0.TABLE, Z.TABLE], [d0.TBODY, Z.TBODY], [d0.TEMPLATE, Z.TEMPLATE], [d0.TEXTAREA, Z.TEXTAREA], [d0.TFOOT, Z.TFOOT], [d0.TD, Z.TD], [d0.TH, Z.TH], [d0.THEAD, Z.THEAD], [d0.TITLE, Z.TITLE], [d0.TR, Z.TR], [d0.TRACK, Z.TRACK], [d0.TT, Z.TT], [d0.U, Z.U], [d0.UL, Z.UL], [d0.SVG, Z.SVG], [d0.VAR, Z.VAR], [d0.WBR, Z.WBR], [d0.XMP, Z.XMP]]);
function a7(e9) {
  var t;
  return (t = SDt.get(e9)) !== null && t !== void 0 ? t : Z.UNKNOWN;
}
var xt = Z;
var Kde = { [G0.HTML]: /* @__PURE__ */ new Set([xt.ADDRESS, xt.APPLET, xt.AREA, xt.ARTICLE, xt.ASIDE, xt.BASE, xt.BASEFONT, xt.BGSOUND, xt.BLOCKQUOTE, xt.BODY, xt.BR, xt.BUTTON, xt.CAPTION, xt.CENTER, xt.COL, xt.COLGROUP, xt.DD, xt.DETAILS, xt.DIR, xt.DIV, xt.DL, xt.DT, xt.EMBED, xt.FIELDSET, xt.FIGCAPTION, xt.FIGURE, xt.FOOTER, xt.FORM, xt.FRAME, xt.FRAMESET, xt.H1, xt.H2, xt.H3, xt.H4, xt.H5, xt.H6, xt.HEAD, xt.HEADER, xt.HGROUP, xt.HR, xt.HTML, xt.IFRAME, xt.IMG, xt.INPUT, xt.LI, xt.LINK, xt.LISTING, xt.MAIN, xt.MARQUEE, xt.MENU, xt.META, xt.NAV, xt.NOEMBED, xt.NOFRAMES, xt.NOSCRIPT, xt.OBJECT, xt.OL, xt.P, xt.PARAM, xt.PLAINTEXT, xt.PRE, xt.SCRIPT, xt.SECTION, xt.SELECT, xt.SOURCE, xt.STYLE, xt.SUMMARY, xt.TABLE, xt.TBODY, xt.TD, xt.TEMPLATE, xt.TEXTAREA, xt.TFOOT, xt.TH, xt.THEAD, xt.TITLE, xt.TR, xt.TRACK, xt.UL, xt.WBR, xt.XMP]), [G0.MATHML]: /* @__PURE__ */ new Set([xt.MI, xt.MO, xt.MN, xt.MS, xt.MTEXT, xt.ANNOTATION_XML]), [G0.SVG]: /* @__PURE__ */ new Set([xt.TITLE, xt.FOREIGN_OBJECT, xt.DESC]), [G0.XLINK]: /* @__PURE__ */ new Set(), [G0.XML]: /* @__PURE__ */ new Set(), [G0.XMLNS]: /* @__PURE__ */ new Set() };
var r_ = /* @__PURE__ */ new Set([xt.H1, xt.H2, xt.H3, xt.H4, xt.H5, xt.H6]);
var EDt = /* @__PURE__ */ new Set([d0.STYLE, d0.SCRIPT, d0.XMP, d0.IFRAME, d0.NOEMBED, d0.NOFRAMES, d0.PLAINTEXT]);
function Jde(e9, t) {
  return EDt.has(e9) || t && e9 === d0.NOSCRIPT;
}
var Fe;
(function(e9) {
  e9[e9.DATA = 0] = "DATA", e9[e9.RCDATA = 1] = "RCDATA", e9[e9.RAWTEXT = 2] = "RAWTEXT", e9[e9.SCRIPT_DATA = 3] = "SCRIPT_DATA", e9[e9.PLAINTEXT = 4] = "PLAINTEXT", e9[e9.TAG_OPEN = 5] = "TAG_OPEN", e9[e9.END_TAG_OPEN = 6] = "END_TAG_OPEN", e9[e9.TAG_NAME = 7] = "TAG_NAME", e9[e9.RCDATA_LESS_THAN_SIGN = 8] = "RCDATA_LESS_THAN_SIGN", e9[e9.RCDATA_END_TAG_OPEN = 9] = "RCDATA_END_TAG_OPEN", e9[e9.RCDATA_END_TAG_NAME = 10] = "RCDATA_END_TAG_NAME", e9[e9.RAWTEXT_LESS_THAN_SIGN = 11] = "RAWTEXT_LESS_THAN_SIGN", e9[e9.RAWTEXT_END_TAG_OPEN = 12] = "RAWTEXT_END_TAG_OPEN", e9[e9.RAWTEXT_END_TAG_NAME = 13] = "RAWTEXT_END_TAG_NAME", e9[e9.SCRIPT_DATA_LESS_THAN_SIGN = 14] = "SCRIPT_DATA_LESS_THAN_SIGN", e9[e9.SCRIPT_DATA_END_TAG_OPEN = 15] = "SCRIPT_DATA_END_TAG_OPEN", e9[e9.SCRIPT_DATA_END_TAG_NAME = 16] = "SCRIPT_DATA_END_TAG_NAME", e9[e9.SCRIPT_DATA_ESCAPE_START = 17] = "SCRIPT_DATA_ESCAPE_START", e9[e9.SCRIPT_DATA_ESCAPE_START_DASH = 18] = "SCRIPT_DATA_ESCAPE_START_DASH", e9[e9.SCRIPT_DATA_ESCAPED = 19] = "SCRIPT_DATA_ESCAPED", e9[e9.SCRIPT_DATA_ESCAPED_DASH = 20] = "SCRIPT_DATA_ESCAPED_DASH", e9[e9.SCRIPT_DATA_ESCAPED_DASH_DASH = 21] = "SCRIPT_DATA_ESCAPED_DASH_DASH", e9[e9.SCRIPT_DATA_ESCAPED_LESS_THAN_SIGN = 22] = "SCRIPT_DATA_ESCAPED_LESS_THAN_SIGN", e9[e9.SCRIPT_DATA_ESCAPED_END_TAG_OPEN = 23] = "SCRIPT_DATA_ESCAPED_END_TAG_OPEN", e9[e9.SCRIPT_DATA_ESCAPED_END_TAG_NAME = 24] = "SCRIPT_DATA_ESCAPED_END_TAG_NAME", e9[e9.SCRIPT_DATA_DOUBLE_ESCAPE_START = 25] = "SCRIPT_DATA_DOUBLE_ESCAPE_START", e9[e9.SCRIPT_DATA_DOUBLE_ESCAPED = 26] = "SCRIPT_DATA_DOUBLE_ESCAPED", e9[e9.SCRIPT_DATA_DOUBLE_ESCAPED_DASH = 27] = "SCRIPT_DATA_DOUBLE_ESCAPED_DASH", e9[e9.SCRIPT_DATA_DOUBLE_ESCAPED_DASH_DASH = 28] = "SCRIPT_DATA_DOUBLE_ESCAPED_DASH_DASH", e9[e9.SCRIPT_DATA_DOUBLE_ESCAPED_LESS_THAN_SIGN = 29] = "SCRIPT_DATA_DOUBLE_ESCAPED_LESS_THAN_SIGN", e9[e9.SCRIPT_DATA_DOUBLE_ESCAPE_END = 30] = "SCRIPT_DATA_DOUBLE_ESCAPE_END", e9[e9.BEFORE_ATTRIBUTE_NAME = 31] = "BEFORE_ATTRIBUTE_NAME", e9[e9.ATTRIBUTE_NAME = 32] = "ATTRIBUTE_NAME", e9[e9.AFTER_ATTRIBUTE_NAME = 33] = "AFTER_ATTRIBUTE_NAME", e9[e9.BEFORE_ATTRIBUTE_VALUE = 34] = "BEFORE_ATTRIBUTE_VALUE", e9[e9.ATTRIBUTE_VALUE_DOUBLE_QUOTED = 35] = "ATTRIBUTE_VALUE_DOUBLE_QUOTED", e9[e9.ATTRIBUTE_VALUE_SINGLE_QUOTED = 36] = "ATTRIBUTE_VALUE_SINGLE_QUOTED", e9[e9.ATTRIBUTE_VALUE_UNQUOTED = 37] = "ATTRIBUTE_VALUE_UNQUOTED", e9[e9.AFTER_ATTRIBUTE_VALUE_QUOTED = 38] = "AFTER_ATTRIBUTE_VALUE_QUOTED", e9[e9.SELF_CLOSING_START_TAG = 39] = "SELF_CLOSING_START_TAG", e9[e9.BOGUS_COMMENT = 40] = "BOGUS_COMMENT", e9[e9.MARKUP_DECLARATION_OPEN = 41] = "MARKUP_DECLARATION_OPEN", e9[e9.COMMENT_START = 42] = "COMMENT_START", e9[e9.COMMENT_START_DASH = 43] = "COMMENT_START_DASH", e9[e9.COMMENT = 44] = "COMMENT", e9[e9.COMMENT_LESS_THAN_SIGN = 45] = "COMMENT_LESS_THAN_SIGN", e9[e9.COMMENT_LESS_THAN_SIGN_BANG = 46] = "COMMENT_LESS_THAN_SIGN_BANG", e9[e9.COMMENT_LESS_THAN_SIGN_BANG_DASH = 47] = "COMMENT_LESS_THAN_SIGN_BANG_DASH", e9[e9.COMMENT_LESS_THAN_SIGN_BANG_DASH_DASH = 48] = "COMMENT_LESS_THAN_SIGN_BANG_DASH_DASH", e9[e9.COMMENT_END_DASH = 49] = "COMMENT_END_DASH", e9[e9.COMMENT_END = 50] = "COMMENT_END", e9[e9.COMMENT_END_BANG = 51] = "COMMENT_END_BANG", e9[e9.DOCTYPE = 52] = "DOCTYPE", e9[e9.BEFORE_DOCTYPE_NAME = 53] = "BEFORE_DOCTYPE_NAME", e9[e9.DOCTYPE_NAME = 54] = "DOCTYPE_NAME", e9[e9.AFTER_DOCTYPE_NAME = 55] = "AFTER_DOCTYPE_NAME", e9[e9.AFTER_DOCTYPE_PUBLIC_KEYWORD = 56] = "AFTER_DOCTYPE_PUBLIC_KEYWORD", e9[e9.BEFORE_DOCTYPE_PUBLIC_IDENTIFIER = 57] = "BEFORE_DOCTYPE_PUBLIC_IDENTIFIER", e9[e9.DOCTYPE_PUBLIC_IDENTIFIER_DOUBLE_QUOTED = 58] = "DOCTYPE_PUBLIC_IDENTIFIER_DOUBLE_QUOTED", e9[e9.DOCTYPE_PUBLIC_IDENTIFIER_SINGLE_QUOTED = 59] = "DOCTYPE_PUBLIC_IDENTIFIER_SINGLE_QUOTED", e9[e9.AFTER_DOCTYPE_PUBLIC_IDENTIFIER = 60] = "AFTER_DOCTYPE_PUBLIC_IDENTIFIER", e9[e9.BETWEEN_DOCTYPE_PUBLIC_AND_SYSTEM_IDENTIFIERS = 61] = "BETWEEN_DOCTYPE_PUBLIC_AND_SYSTEM_IDENTIFIERS", e9[e9.AFTER_DOCTYPE_SYSTEM_KEYWORD = 62] = "AFTER_DOCTYPE_SYSTEM_KEYWORD", e9[e9.BEFORE_DOCTYPE_SYSTEM_IDENTIFIER = 63] = "BEFORE_DOCTYPE_SYSTEM_IDENTIFIER", e9[e9.DOCTYPE_SYSTEM_IDENTIFIER_DOUBLE_QUOTED = 64] = "DOCTYPE_SYSTEM_IDENTIFIER_DOUBLE_QUOTED", e9[e9.DOCTYPE_SYSTEM_IDENTIFIER_SINGLE_QUOTED = 65] = "DOCTYPE_SYSTEM_IDENTIFIER_SINGLE_QUOTED", e9[e9.AFTER_DOCTYPE_SYSTEM_IDENTIFIER = 66] = "AFTER_DOCTYPE_SYSTEM_IDENTIFIER", e9[e9.BOGUS_DOCTYPE = 67] = "BOGUS_DOCTYPE", e9[e9.CDATA_SECTION = 68] = "CDATA_SECTION", e9[e9.CDATA_SECTION_BRACKET = 69] = "CDATA_SECTION_BRACKET", e9[e9.CDATA_SECTION_END = 70] = "CDATA_SECTION_END", e9[e9.CHARACTER_REFERENCE = 71] = "CHARACTER_REFERENCE", e9[e9.AMBIGUOUS_AMPERSAND = 72] = "AMBIGUOUS_AMPERSAND";
})(Fe || (Fe = {}));
var Fc = { DATA: Fe.DATA, RCDATA: Fe.RCDATA, RAWTEXT: Fe.RAWTEXT, SCRIPT_DATA: Fe.SCRIPT_DATA, PLAINTEXT: Fe.PLAINTEXT, CDATA_SECTION: Fe.CDATA_SECTION };
function TDt(e9) {
  return e9 >= Ne.DIGIT_0 && e9 <= Ne.DIGIT_9;
}
function dC(e9) {
  return e9 >= Ne.LATIN_CAPITAL_A && e9 <= Ne.LATIN_CAPITAL_Z;
}
function IDt(e9) {
  return e9 >= Ne.LATIN_SMALL_A && e9 <= Ne.LATIN_SMALL_Z;
}
function o7(e9) {
  return IDt(e9) || dC(e9);
}
function tx0(e9) {
  return o7(e9) || TDt(e9);
}
function IH(e9) {
  return e9 + 32;
}
function nx0(e9) {
  return e9 === Ne.SPACE || e9 === Ne.LINE_FEED || e9 === Ne.TABULATION || e9 === Ne.FORM_FEED;
}
function rx0(e9) {
  return nx0(e9) || e9 === Ne.SOLIDUS || e9 === Ne.GREATER_THAN_SIGN;
}
function RDt(e9) {
  return e9 === Ne.NULL ? I0.nullCharacterReference : e9 > 1114111 ? I0.characterReferenceOutsideUnicodeRange : AH(e9) ? I0.surrogateCharacterReference : vH(e9) ? I0.noncharacterCharacterReference : kH(e9) || e9 === Ne.CARRIAGE_RETURN ? I0.controlCharacterReference : null;
}
var pC = class {
  constructor(t, n) {
    this.options = t, this.handler = n, this.paused = false, this.inLoop = false, this.inForeignNode = false, this.lastStartTagName = "", this.active = false, this.state = Fe.DATA, this.returnState = Fe.DATA, this.entityStartPos = 0, this.consumedAfterSnapshot = -1, this.currentCharacterToken = null, this.currentToken = null, this.currentAttr = { name: "", value: "" }, this.preprocessor = new _H(n), this.currentLocation = this.getCurrentLocation(-1), this.entityDecoder = new EH(SH, (s, c) => {
      this.preprocessor.pos = this.entityStartPos + c - 1, this._flushCodePointConsumedAsCharacterReference(s);
    }, n.onParseError ? { missingSemicolonAfterCharacterReference: () => {
      this._err(I0.missingSemicolonAfterCharacterReference, 1);
    }, absenceOfDigitsInNumericCharacterReference: (s) => {
      this._err(I0.absenceOfDigitsInNumericCharacterReference, this.entityStartPos - this.preprocessor.pos + s);
    }, validateNumericCharacterReference: (s) => {
      let c = RDt(s);
      c && this._err(c, 1);
    } } : void 0);
  }
  _err(t, n = 0) {
    var s, c;
    (c = (s = this.handler).onParseError) === null || c === void 0 || c.call(s, this.preprocessor.getError(t, n));
  }
  getCurrentLocation(t) {
    return this.options.sourceCodeLocationInfo ? { startLine: this.preprocessor.line, startCol: this.preprocessor.col - t, startOffset: this.preprocessor.offset - t, endLine: -1, endCol: -1, endOffset: -1 } : null;
  }
  _runParsingLoop() {
    if (!this.inLoop) {
      for (this.inLoop = true; this.active && !this.paused; ) {
        this.consumedAfterSnapshot = 0;
        let t = this._consume();
        this._ensureHibernation() || this._callState(t);
      }
      this.inLoop = false;
    }
  }
  pause() {
    this.paused = true;
  }
  resume(t) {
    if (!this.paused) throw new Error("Parser was already resumed");
    this.paused = false, !this.inLoop && (this._runParsingLoop(), this.paused || t?.());
  }
  write(t, n, s) {
    this.active = true, this.preprocessor.write(t, n), this._runParsingLoop(), this.paused || s?.();
  }
  insertHtmlAtCurrentPos(t) {
    this.active = true, this.preprocessor.insertHtmlAtCurrentPos(t), this._runParsingLoop();
  }
  _ensureHibernation() {
    return this.preprocessor.endOfChunkHit ? (this.preprocessor.retreat(this.consumedAfterSnapshot), this.consumedAfterSnapshot = 0, this.active = false, true) : false;
  }
  _consume() {
    return this.consumedAfterSnapshot++, this.preprocessor.advance();
  }
  _advanceBy(t) {
    this.consumedAfterSnapshot += t;
    for (let n = 0; n < t; n++) this.preprocessor.advance();
  }
  _consumeSequenceIfMatch(t, n) {
    return this.preprocessor.startsWith(t, n) ? (this._advanceBy(t.length - 1), true) : false;
  }
  _createStartTagToken() {
    this.currentToken = { type: ki.START_TAG, tagName: "", tagID: Z.UNKNOWN, selfClosing: false, ackSelfClosing: false, attrs: [], location: this.getCurrentLocation(1) };
  }
  _createEndTagToken() {
    this.currentToken = { type: ki.END_TAG, tagName: "", tagID: Z.UNKNOWN, selfClosing: false, ackSelfClosing: false, attrs: [], location: this.getCurrentLocation(2) };
  }
  _createCommentToken(t) {
    this.currentToken = { type: ki.COMMENT, data: "", location: this.getCurrentLocation(t) };
  }
  _createDoctypeToken(t) {
    this.currentToken = { type: ki.DOCTYPE, name: t, forceQuirks: false, publicId: null, systemId: null, location: this.currentLocation };
  }
  _createCharacterToken(t, n) {
    this.currentCharacterToken = { type: t, chars: n, location: this.currentLocation };
  }
  _createAttr(t) {
    this.currentAttr = { name: t, value: "" }, this.currentLocation = this.getCurrentLocation(0);
  }
  _leaveAttrName() {
    var t, n;
    let s = this.currentToken;
    if (wH(s, this.currentAttr.name) === null) {
      if (s.attrs.push(this.currentAttr), s.location && this.currentLocation) {
        let c = (t = (n = s.location).attrs) !== null && t !== void 0 ? t : n.attrs = /* @__PURE__ */ Object.create(null);
        c[this.currentAttr.name] = this.currentLocation, this._leaveAttrValue();
      }
    } else this._err(I0.duplicateAttribute);
  }
  _leaveAttrValue() {
    this.currentLocation && (this.currentLocation.endLine = this.preprocessor.line, this.currentLocation.endCol = this.preprocessor.col, this.currentLocation.endOffset = this.preprocessor.offset);
  }
  prepareToken(t) {
    this._emitCurrentCharacterToken(t.location), this.currentToken = null, t.location && (t.location.endLine = this.preprocessor.line, t.location.endCol = this.preprocessor.col + 1, t.location.endOffset = this.preprocessor.offset + 1), this.currentLocation = this.getCurrentLocation(-1);
  }
  emitCurrentTagToken() {
    let t = this.currentToken;
    this.prepareToken(t), t.tagID = a7(t.tagName), t.type === ki.START_TAG ? (this.lastStartTagName = t.tagName, this.handler.onStartTag(t)) : (t.attrs.length > 0 && this._err(I0.endTagWithAttributes), t.selfClosing && this._err(I0.endTagWithTrailingSolidus), this.handler.onEndTag(t)), this.preprocessor.dropParsedChunk();
  }
  emitCurrentComment(t) {
    this.prepareToken(t), this.handler.onComment(t), this.preprocessor.dropParsedChunk();
  }
  emitCurrentDoctype(t) {
    this.prepareToken(t), this.handler.onDoctype(t), this.preprocessor.dropParsedChunk();
  }
  _emitCurrentCharacterToken(t) {
    if (this.currentCharacterToken) {
      switch (t && this.currentCharacterToken.location && (this.currentCharacterToken.location.endLine = t.startLine, this.currentCharacterToken.location.endCol = t.startCol, this.currentCharacterToken.location.endOffset = t.startOffset), this.currentCharacterToken.type) {
        case ki.CHARACTER: {
          this.handler.onCharacter(this.currentCharacterToken);
          break;
        }
        case ki.NULL_CHARACTER: {
          this.handler.onNullCharacter(this.currentCharacterToken);
          break;
        }
        case ki.WHITESPACE_CHARACTER: {
          this.handler.onWhitespaceCharacter(this.currentCharacterToken);
          break;
        }
      }
      this.currentCharacterToken = null;
    }
  }
  _emitEOFToken() {
    let t = this.getCurrentLocation(0);
    t && (t.endLine = t.startLine, t.endCol = t.startCol, t.endOffset = t.startOffset), this._emitCurrentCharacterToken(t), this.handler.onEof({ type: ki.EOF, location: t }), this.active = false;
  }
  _appendCharToCurrentCharacterToken(t, n) {
    if (this.currentCharacterToken) if (this.currentCharacterToken.type === t) {
      this.currentCharacterToken.chars += n;
      return;
    } else this.currentLocation = this.getCurrentLocation(0), this._emitCurrentCharacterToken(this.currentLocation), this.preprocessor.dropParsedChunk();
    this._createCharacterToken(t, n);
  }
  _emitCodePoint(t) {
    let n = nx0(t) ? ki.WHITESPACE_CHARACTER : t === Ne.NULL ? ki.NULL_CHARACTER : ki.CHARACTER;
    this._appendCharToCurrentCharacterToken(n, String.fromCodePoint(t));
  }
  _emitChars(t) {
    this._appendCharToCurrentCharacterToken(ki.CHARACTER, t);
  }
  _startCharacterReference() {
    this.returnState = this.state, this.state = Fe.CHARACTER_REFERENCE, this.entityStartPos = this.preprocessor.pos, this.entityDecoder.startEntity(this._isCharacterReferenceInAttribute() ? w1.Attribute : w1.Legacy);
  }
  _isCharacterReferenceInAttribute() {
    return this.returnState === Fe.ATTRIBUTE_VALUE_DOUBLE_QUOTED || this.returnState === Fe.ATTRIBUTE_VALUE_SINGLE_QUOTED || this.returnState === Fe.ATTRIBUTE_VALUE_UNQUOTED;
  }
  _flushCodePointConsumedAsCharacterReference(t) {
    this._isCharacterReferenceInAttribute() ? this.currentAttr.value += String.fromCodePoint(t) : this._emitCodePoint(t);
  }
  _callState(t) {
    switch (this.state) {
      case Fe.DATA: {
        this._stateData(t);
        break;
      }
      case Fe.RCDATA: {
        this._stateRcdata(t);
        break;
      }
      case Fe.RAWTEXT: {
        this._stateRawtext(t);
        break;
      }
      case Fe.SCRIPT_DATA: {
        this._stateScriptData(t);
        break;
      }
      case Fe.PLAINTEXT: {
        this._statePlaintext(t);
        break;
      }
      case Fe.TAG_OPEN: {
        this._stateTagOpen(t);
        break;
      }
      case Fe.END_TAG_OPEN: {
        this._stateEndTagOpen(t);
        break;
      }
      case Fe.TAG_NAME: {
        this._stateTagName(t);
        break;
      }
      case Fe.RCDATA_LESS_THAN_SIGN: {
        this._stateRcdataLessThanSign(t);
        break;
      }
      case Fe.RCDATA_END_TAG_OPEN: {
        this._stateRcdataEndTagOpen(t);
        break;
      }
      case Fe.RCDATA_END_TAG_NAME: {
        this._stateRcdataEndTagName(t);
        break;
      }
      case Fe.RAWTEXT_LESS_THAN_SIGN: {
        this._stateRawtextLessThanSign(t);
        break;
      }
      case Fe.RAWTEXT_END_TAG_OPEN: {
        this._stateRawtextEndTagOpen(t);
        break;
      }
      case Fe.RAWTEXT_END_TAG_NAME: {
        this._stateRawtextEndTagName(t);
        break;
      }
      case Fe.SCRIPT_DATA_LESS_THAN_SIGN: {
        this._stateScriptDataLessThanSign(t);
        break;
      }
      case Fe.SCRIPT_DATA_END_TAG_OPEN: {
        this._stateScriptDataEndTagOpen(t);
        break;
      }
      case Fe.SCRIPT_DATA_END_TAG_NAME: {
        this._stateScriptDataEndTagName(t);
        break;
      }
      case Fe.SCRIPT_DATA_ESCAPE_START: {
        this._stateScriptDataEscapeStart(t);
        break;
      }
      case Fe.SCRIPT_DATA_ESCAPE_START_DASH: {
        this._stateScriptDataEscapeStartDash(t);
        break;
      }
      case Fe.SCRIPT_DATA_ESCAPED: {
        this._stateScriptDataEscaped(t);
        break;
      }
      case Fe.SCRIPT_DATA_ESCAPED_DASH: {
        this._stateScriptDataEscapedDash(t);
        break;
      }
      case Fe.SCRIPT_DATA_ESCAPED_DASH_DASH: {
        this._stateScriptDataEscapedDashDash(t);
        break;
      }
      case Fe.SCRIPT_DATA_ESCAPED_LESS_THAN_SIGN: {
        this._stateScriptDataEscapedLessThanSign(t);
        break;
      }
      case Fe.SCRIPT_DATA_ESCAPED_END_TAG_OPEN: {
        this._stateScriptDataEscapedEndTagOpen(t);
        break;
      }
      case Fe.SCRIPT_DATA_ESCAPED_END_TAG_NAME: {
        this._stateScriptDataEscapedEndTagName(t);
        break;
      }
      case Fe.SCRIPT_DATA_DOUBLE_ESCAPE_START: {
        this._stateScriptDataDoubleEscapeStart(t);
        break;
      }
      case Fe.SCRIPT_DATA_DOUBLE_ESCAPED: {
        this._stateScriptDataDoubleEscaped(t);
        break;
      }
      case Fe.SCRIPT_DATA_DOUBLE_ESCAPED_DASH: {
        this._stateScriptDataDoubleEscapedDash(t);
        break;
      }
      case Fe.SCRIPT_DATA_DOUBLE_ESCAPED_DASH_DASH: {
        this._stateScriptDataDoubleEscapedDashDash(t);
        break;
      }
      case Fe.SCRIPT_DATA_DOUBLE_ESCAPED_LESS_THAN_SIGN: {
        this._stateScriptDataDoubleEscapedLessThanSign(t);
        break;
      }
      case Fe.SCRIPT_DATA_DOUBLE_ESCAPE_END: {
        this._stateScriptDataDoubleEscapeEnd(t);
        break;
      }
      case Fe.BEFORE_ATTRIBUTE_NAME: {
        this._stateBeforeAttributeName(t);
        break;
      }
      case Fe.ATTRIBUTE_NAME: {
        this._stateAttributeName(t);
        break;
      }
      case Fe.AFTER_ATTRIBUTE_NAME: {
        this._stateAfterAttributeName(t);
        break;
      }
      case Fe.BEFORE_ATTRIBUTE_VALUE: {
        this._stateBeforeAttributeValue(t);
        break;
      }
      case Fe.ATTRIBUTE_VALUE_DOUBLE_QUOTED: {
        this._stateAttributeValueDoubleQuoted(t);
        break;
      }
      case Fe.ATTRIBUTE_VALUE_SINGLE_QUOTED: {
        this._stateAttributeValueSingleQuoted(t);
        break;
      }
      case Fe.ATTRIBUTE_VALUE_UNQUOTED: {
        this._stateAttributeValueUnquoted(t);
        break;
      }
      case Fe.AFTER_ATTRIBUTE_VALUE_QUOTED: {
        this._stateAfterAttributeValueQuoted(t);
        break;
      }
      case Fe.SELF_CLOSING_START_TAG: {
        this._stateSelfClosingStartTag(t);
        break;
      }
      case Fe.BOGUS_COMMENT: {
        this._stateBogusComment(t);
        break;
      }
      case Fe.MARKUP_DECLARATION_OPEN: {
        this._stateMarkupDeclarationOpen(t);
        break;
      }
      case Fe.COMMENT_START: {
        this._stateCommentStart(t);
        break;
      }
      case Fe.COMMENT_START_DASH: {
        this._stateCommentStartDash(t);
        break;
      }
      case Fe.COMMENT: {
        this._stateComment(t);
        break;
      }
      case Fe.COMMENT_LESS_THAN_SIGN: {
        this._stateCommentLessThanSign(t);
        break;
      }
      case Fe.COMMENT_LESS_THAN_SIGN_BANG: {
        this._stateCommentLessThanSignBang(t);
        break;
      }
      case Fe.COMMENT_LESS_THAN_SIGN_BANG_DASH: {
        this._stateCommentLessThanSignBangDash(t);
        break;
      }
      case Fe.COMMENT_LESS_THAN_SIGN_BANG_DASH_DASH: {
        this._stateCommentLessThanSignBangDashDash(t);
        break;
      }
      case Fe.COMMENT_END_DASH: {
        this._stateCommentEndDash(t);
        break;
      }
      case Fe.COMMENT_END: {
        this._stateCommentEnd(t);
        break;
      }
      case Fe.COMMENT_END_BANG: {
        this._stateCommentEndBang(t);
        break;
      }
      case Fe.DOCTYPE: {
        this._stateDoctype(t);
        break;
      }
      case Fe.BEFORE_DOCTYPE_NAME: {
        this._stateBeforeDoctypeName(t);
        break;
      }
      case Fe.DOCTYPE_NAME: {
        this._stateDoctypeName(t);
        break;
      }
      case Fe.AFTER_DOCTYPE_NAME: {
        this._stateAfterDoctypeName(t);
        break;
      }
      case Fe.AFTER_DOCTYPE_PUBLIC_KEYWORD: {
        this._stateAfterDoctypePublicKeyword(t);
        break;
      }
      case Fe.BEFORE_DOCTYPE_PUBLIC_IDENTIFIER: {
        this._stateBeforeDoctypePublicIdentifier(t);
        break;
      }
      case Fe.DOCTYPE_PUBLIC_IDENTIFIER_DOUBLE_QUOTED: {
        this._stateDoctypePublicIdentifierDoubleQuoted(t);
        break;
      }
      case Fe.DOCTYPE_PUBLIC_IDENTIFIER_SINGLE_QUOTED: {
        this._stateDoctypePublicIdentifierSingleQuoted(t);
        break;
      }
      case Fe.AFTER_DOCTYPE_PUBLIC_IDENTIFIER: {
        this._stateAfterDoctypePublicIdentifier(t);
        break;
      }
      case Fe.BETWEEN_DOCTYPE_PUBLIC_AND_SYSTEM_IDENTIFIERS: {
        this._stateBetweenDoctypePublicAndSystemIdentifiers(t);
        break;
      }
      case Fe.AFTER_DOCTYPE_SYSTEM_KEYWORD: {
        this._stateAfterDoctypeSystemKeyword(t);
        break;
      }
      case Fe.BEFORE_DOCTYPE_SYSTEM_IDENTIFIER: {
        this._stateBeforeDoctypeSystemIdentifier(t);
        break;
      }
      case Fe.DOCTYPE_SYSTEM_IDENTIFIER_DOUBLE_QUOTED: {
        this._stateDoctypeSystemIdentifierDoubleQuoted(t);
        break;
      }
      case Fe.DOCTYPE_SYSTEM_IDENTIFIER_SINGLE_QUOTED: {
        this._stateDoctypeSystemIdentifierSingleQuoted(t);
        break;
      }
      case Fe.AFTER_DOCTYPE_SYSTEM_IDENTIFIER: {
        this._stateAfterDoctypeSystemIdentifier(t);
        break;
      }
      case Fe.BOGUS_DOCTYPE: {
        this._stateBogusDoctype(t);
        break;
      }
      case Fe.CDATA_SECTION: {
        this._stateCdataSection(t);
        break;
      }
      case Fe.CDATA_SECTION_BRACKET: {
        this._stateCdataSectionBracket(t);
        break;
      }
      case Fe.CDATA_SECTION_END: {
        this._stateCdataSectionEnd(t);
        break;
      }
      case Fe.CHARACTER_REFERENCE: {
        this._stateCharacterReference();
        break;
      }
      case Fe.AMBIGUOUS_AMPERSAND: {
        this._stateAmbiguousAmpersand(t);
        break;
      }
      default:
        throw new Error("Unknown state");
    }
  }
  _stateData(t) {
    switch (t) {
      case Ne.LESS_THAN_SIGN: {
        this.state = Fe.TAG_OPEN;
        break;
      }
      case Ne.AMPERSAND: {
        this._startCharacterReference();
        break;
      }
      case Ne.NULL: {
        this._err(I0.unexpectedNullCharacter), this._emitCodePoint(t);
        break;
      }
      case Ne.EOF: {
        this._emitEOFToken();
        break;
      }
      default:
        this._emitCodePoint(t);
    }
  }
  _stateRcdata(t) {
    switch (t) {
      case Ne.AMPERSAND: {
        this._startCharacterReference();
        break;
      }
      case Ne.LESS_THAN_SIGN: {
        this.state = Fe.RCDATA_LESS_THAN_SIGN;
        break;
      }
      case Ne.NULL: {
        this._err(I0.unexpectedNullCharacter), this._emitChars(Ka);
        break;
      }
      case Ne.EOF: {
        this._emitEOFToken();
        break;
      }
      default:
        this._emitCodePoint(t);
    }
  }
  _stateRawtext(t) {
    switch (t) {
      case Ne.LESS_THAN_SIGN: {
        this.state = Fe.RAWTEXT_LESS_THAN_SIGN;
        break;
      }
      case Ne.NULL: {
        this._err(I0.unexpectedNullCharacter), this._emitChars(Ka);
        break;
      }
      case Ne.EOF: {
        this._emitEOFToken();
        break;
      }
      default:
        this._emitCodePoint(t);
    }
  }
  _stateScriptData(t) {
    switch (t) {
      case Ne.LESS_THAN_SIGN: {
        this.state = Fe.SCRIPT_DATA_LESS_THAN_SIGN;
        break;
      }
      case Ne.NULL: {
        this._err(I0.unexpectedNullCharacter), this._emitChars(Ka);
        break;
      }
      case Ne.EOF: {
        this._emitEOFToken();
        break;
      }
      default:
        this._emitCodePoint(t);
    }
  }
  _statePlaintext(t) {
    switch (t) {
      case Ne.NULL: {
        this._err(I0.unexpectedNullCharacter), this._emitChars(Ka);
        break;
      }
      case Ne.EOF: {
        this._emitEOFToken();
        break;
      }
      default:
        this._emitCodePoint(t);
    }
  }
  _stateTagOpen(t) {
    if (o7(t)) this._createStartTagToken(), this.state = Fe.TAG_NAME, this._stateTagName(t);
    else switch (t) {
      case Ne.EXCLAMATION_MARK: {
        this.state = Fe.MARKUP_DECLARATION_OPEN;
        break;
      }
      case Ne.SOLIDUS: {
        this.state = Fe.END_TAG_OPEN;
        break;
      }
      case Ne.QUESTION_MARK: {
        this._err(I0.unexpectedQuestionMarkInsteadOfTagName), this._createCommentToken(1), this.state = Fe.BOGUS_COMMENT, this._stateBogusComment(t);
        break;
      }
      case Ne.EOF: {
        this._err(I0.eofBeforeTagName), this._emitChars("<"), this._emitEOFToken();
        break;
      }
      default:
        this._err(I0.invalidFirstCharacterOfTagName), this._emitChars("<"), this.state = Fe.DATA, this._stateData(t);
    }
  }
  _stateEndTagOpen(t) {
    if (o7(t)) this._createEndTagToken(), this.state = Fe.TAG_NAME, this._stateTagName(t);
    else switch (t) {
      case Ne.GREATER_THAN_SIGN: {
        this._err(I0.missingEndTagName), this.state = Fe.DATA;
        break;
      }
      case Ne.EOF: {
        this._err(I0.eofBeforeTagName), this._emitChars("</"), this._emitEOFToken();
        break;
      }
      default:
        this._err(I0.invalidFirstCharacterOfTagName), this._createCommentToken(2), this.state = Fe.BOGUS_COMMENT, this._stateBogusComment(t);
    }
  }
  _stateTagName(t) {
    let n = this.currentToken;
    switch (t) {
      case Ne.SPACE:
      case Ne.LINE_FEED:
      case Ne.TABULATION:
      case Ne.FORM_FEED: {
        this.state = Fe.BEFORE_ATTRIBUTE_NAME;
        break;
      }
      case Ne.SOLIDUS: {
        this.state = Fe.SELF_CLOSING_START_TAG;
        break;
      }
      case Ne.GREATER_THAN_SIGN: {
        this.state = Fe.DATA, this.emitCurrentTagToken();
        break;
      }
      case Ne.NULL: {
        this._err(I0.unexpectedNullCharacter), n.tagName += Ka;
        break;
      }
      case Ne.EOF: {
        this._err(I0.eofInTag), this._emitEOFToken();
        break;
      }
      default:
        n.tagName += String.fromCodePoint(dC(t) ? IH(t) : t);
    }
  }
  _stateRcdataLessThanSign(t) {
    t === Ne.SOLIDUS ? this.state = Fe.RCDATA_END_TAG_OPEN : (this._emitChars("<"), this.state = Fe.RCDATA, this._stateRcdata(t));
  }
  _stateRcdataEndTagOpen(t) {
    o7(t) ? (this.state = Fe.RCDATA_END_TAG_NAME, this._stateRcdataEndTagName(t)) : (this._emitChars("</"), this.state = Fe.RCDATA, this._stateRcdata(t));
  }
  handleSpecialEndTag(t) {
    if (!this.preprocessor.startsWith(this.lastStartTagName, false)) return !this._ensureHibernation();
    this._createEndTagToken();
    let n = this.currentToken;
    switch (n.tagName = this.lastStartTagName, this.preprocessor.peek(this.lastStartTagName.length)) {
      case Ne.SPACE:
      case Ne.LINE_FEED:
      case Ne.TABULATION:
      case Ne.FORM_FEED:
        return this._advanceBy(this.lastStartTagName.length), this.state = Fe.BEFORE_ATTRIBUTE_NAME, false;
      case Ne.SOLIDUS:
        return this._advanceBy(this.lastStartTagName.length), this.state = Fe.SELF_CLOSING_START_TAG, false;
      case Ne.GREATER_THAN_SIGN:
        return this._advanceBy(this.lastStartTagName.length), this.emitCurrentTagToken(), this.state = Fe.DATA, false;
      default:
        return !this._ensureHibernation();
    }
  }
  _stateRcdataEndTagName(t) {
    this.handleSpecialEndTag(t) && (this._emitChars("</"), this.state = Fe.RCDATA, this._stateRcdata(t));
  }
  _stateRawtextLessThanSign(t) {
    t === Ne.SOLIDUS ? this.state = Fe.RAWTEXT_END_TAG_OPEN : (this._emitChars("<"), this.state = Fe.RAWTEXT, this._stateRawtext(t));
  }
  _stateRawtextEndTagOpen(t) {
    o7(t) ? (this.state = Fe.RAWTEXT_END_TAG_NAME, this._stateRawtextEndTagName(t)) : (this._emitChars("</"), this.state = Fe.RAWTEXT, this._stateRawtext(t));
  }
  _stateRawtextEndTagName(t) {
    this.handleSpecialEndTag(t) && (this._emitChars("</"), this.state = Fe.RAWTEXT, this._stateRawtext(t));
  }
  _stateScriptDataLessThanSign(t) {
    switch (t) {
      case Ne.SOLIDUS: {
        this.state = Fe.SCRIPT_DATA_END_TAG_OPEN;
        break;
      }
      case Ne.EXCLAMATION_MARK: {
        this.state = Fe.SCRIPT_DATA_ESCAPE_START, this._emitChars("<!");
        break;
      }
      default:
        this._emitChars("<"), this.state = Fe.SCRIPT_DATA, this._stateScriptData(t);
    }
  }
  _stateScriptDataEndTagOpen(t) {
    o7(t) ? (this.state = Fe.SCRIPT_DATA_END_TAG_NAME, this._stateScriptDataEndTagName(t)) : (this._emitChars("</"), this.state = Fe.SCRIPT_DATA, this._stateScriptData(t));
  }
  _stateScriptDataEndTagName(t) {
    this.handleSpecialEndTag(t) && (this._emitChars("</"), this.state = Fe.SCRIPT_DATA, this._stateScriptData(t));
  }
  _stateScriptDataEscapeStart(t) {
    t === Ne.HYPHEN_MINUS ? (this.state = Fe.SCRIPT_DATA_ESCAPE_START_DASH, this._emitChars("-")) : (this.state = Fe.SCRIPT_DATA, this._stateScriptData(t));
  }
  _stateScriptDataEscapeStartDash(t) {
    t === Ne.HYPHEN_MINUS ? (this.state = Fe.SCRIPT_DATA_ESCAPED_DASH_DASH, this._emitChars("-")) : (this.state = Fe.SCRIPT_DATA, this._stateScriptData(t));
  }
  _stateScriptDataEscaped(t) {
    switch (t) {
      case Ne.HYPHEN_MINUS: {
        this.state = Fe.SCRIPT_DATA_ESCAPED_DASH, this._emitChars("-");
        break;
      }
      case Ne.LESS_THAN_SIGN: {
        this.state = Fe.SCRIPT_DATA_ESCAPED_LESS_THAN_SIGN;
        break;
      }
      case Ne.NULL: {
        this._err(I0.unexpectedNullCharacter), this._emitChars(Ka);
        break;
      }
      case Ne.EOF: {
        this._err(I0.eofInScriptHtmlCommentLikeText), this._emitEOFToken();
        break;
      }
      default:
        this._emitCodePoint(t);
    }
  }
  _stateScriptDataEscapedDash(t) {
    switch (t) {
      case Ne.HYPHEN_MINUS: {
        this.state = Fe.SCRIPT_DATA_ESCAPED_DASH_DASH, this._emitChars("-");
        break;
      }
      case Ne.LESS_THAN_SIGN: {
        this.state = Fe.SCRIPT_DATA_ESCAPED_LESS_THAN_SIGN;
        break;
      }
      case Ne.NULL: {
        this._err(I0.unexpectedNullCharacter), this.state = Fe.SCRIPT_DATA_ESCAPED, this._emitChars(Ka);
        break;
      }
      case Ne.EOF: {
        this._err(I0.eofInScriptHtmlCommentLikeText), this._emitEOFToken();
        break;
      }
      default:
        this.state = Fe.SCRIPT_DATA_ESCAPED, this._emitCodePoint(t);
    }
  }
  _stateScriptDataEscapedDashDash(t) {
    switch (t) {
      case Ne.HYPHEN_MINUS: {
        this._emitChars("-");
        break;
      }
      case Ne.LESS_THAN_SIGN: {
        this.state = Fe.SCRIPT_DATA_ESCAPED_LESS_THAN_SIGN;
        break;
      }
      case Ne.GREATER_THAN_SIGN: {
        this.state = Fe.SCRIPT_DATA, this._emitChars(">");
        break;
      }
      case Ne.NULL: {
        this._err(I0.unexpectedNullCharacter), this.state = Fe.SCRIPT_DATA_ESCAPED, this._emitChars(Ka);
        break;
      }
      case Ne.EOF: {
        this._err(I0.eofInScriptHtmlCommentLikeText), this._emitEOFToken();
        break;
      }
      default:
        this.state = Fe.SCRIPT_DATA_ESCAPED, this._emitCodePoint(t);
    }
  }
  _stateScriptDataEscapedLessThanSign(t) {
    t === Ne.SOLIDUS ? this.state = Fe.SCRIPT_DATA_ESCAPED_END_TAG_OPEN : o7(t) ? (this._emitChars("<"), this.state = Fe.SCRIPT_DATA_DOUBLE_ESCAPE_START, this._stateScriptDataDoubleEscapeStart(t)) : (this._emitChars("<"), this.state = Fe.SCRIPT_DATA_ESCAPED, this._stateScriptDataEscaped(t));
  }
  _stateScriptDataEscapedEndTagOpen(t) {
    o7(t) ? (this.state = Fe.SCRIPT_DATA_ESCAPED_END_TAG_NAME, this._stateScriptDataEscapedEndTagName(t)) : (this._emitChars("</"), this.state = Fe.SCRIPT_DATA_ESCAPED, this._stateScriptDataEscaped(t));
  }
  _stateScriptDataEscapedEndTagName(t) {
    this.handleSpecialEndTag(t) && (this._emitChars("</"), this.state = Fe.SCRIPT_DATA_ESCAPED, this._stateScriptDataEscaped(t));
  }
  _stateScriptDataDoubleEscapeStart(t) {
    if (this.preprocessor.startsWith(cu.SCRIPT, false) && rx0(this.preprocessor.peek(cu.SCRIPT.length))) {
      this._emitCodePoint(t);
      for (let n = 0; n < cu.SCRIPT.length; n++) this._emitCodePoint(this._consume());
      this.state = Fe.SCRIPT_DATA_DOUBLE_ESCAPED;
    } else this._ensureHibernation() || (this.state = Fe.SCRIPT_DATA_ESCAPED, this._stateScriptDataEscaped(t));
  }
  _stateScriptDataDoubleEscaped(t) {
    switch (t) {
      case Ne.HYPHEN_MINUS: {
        this.state = Fe.SCRIPT_DATA_DOUBLE_ESCAPED_DASH, this._emitChars("-");
        break;
      }
      case Ne.LESS_THAN_SIGN: {
        this.state = Fe.SCRIPT_DATA_DOUBLE_ESCAPED_LESS_THAN_SIGN, this._emitChars("<");
        break;
      }
      case Ne.NULL: {
        this._err(I0.unexpectedNullCharacter), this._emitChars(Ka);
        break;
      }
      case Ne.EOF: {
        this._err(I0.eofInScriptHtmlCommentLikeText), this._emitEOFToken();
        break;
      }
      default:
        this._emitCodePoint(t);
    }
  }
  _stateScriptDataDoubleEscapedDash(t) {
    switch (t) {
      case Ne.HYPHEN_MINUS: {
        this.state = Fe.SCRIPT_DATA_DOUBLE_ESCAPED_DASH_DASH, this._emitChars("-");
        break;
      }
      case Ne.LESS_THAN_SIGN: {
        this.state = Fe.SCRIPT_DATA_DOUBLE_ESCAPED_LESS_THAN_SIGN, this._emitChars("<");
        break;
      }
      case Ne.NULL: {
        this._err(I0.unexpectedNullCharacter), this.state = Fe.SCRIPT_DATA_DOUBLE_ESCAPED, this._emitChars(Ka);
        break;
      }
      case Ne.EOF: {
        this._err(I0.eofInScriptHtmlCommentLikeText), this._emitEOFToken();
        break;
      }
      default:
        this.state = Fe.SCRIPT_DATA_DOUBLE_ESCAPED, this._emitCodePoint(t);
    }
  }
  _stateScriptDataDoubleEscapedDashDash(t) {
    switch (t) {
      case Ne.HYPHEN_MINUS: {
        this._emitChars("-");
        break;
      }
      case Ne.LESS_THAN_SIGN: {
        this.state = Fe.SCRIPT_DATA_DOUBLE_ESCAPED_LESS_THAN_SIGN, this._emitChars("<");
        break;
      }
      case Ne.GREATER_THAN_SIGN: {
        this.state = Fe.SCRIPT_DATA, this._emitChars(">");
        break;
      }
      case Ne.NULL: {
        this._err(I0.unexpectedNullCharacter), this.state = Fe.SCRIPT_DATA_DOUBLE_ESCAPED, this._emitChars(Ka);
        break;
      }
      case Ne.EOF: {
        this._err(I0.eofInScriptHtmlCommentLikeText), this._emitEOFToken();
        break;
      }
      default:
        this.state = Fe.SCRIPT_DATA_DOUBLE_ESCAPED, this._emitCodePoint(t);
    }
  }
  _stateScriptDataDoubleEscapedLessThanSign(t) {
    t === Ne.SOLIDUS ? (this.state = Fe.SCRIPT_DATA_DOUBLE_ESCAPE_END, this._emitChars("/")) : (this.state = Fe.SCRIPT_DATA_DOUBLE_ESCAPED, this._stateScriptDataDoubleEscaped(t));
  }
  _stateScriptDataDoubleEscapeEnd(t) {
    if (this.preprocessor.startsWith(cu.SCRIPT, false) && rx0(this.preprocessor.peek(cu.SCRIPT.length))) {
      this._emitCodePoint(t);
      for (let n = 0; n < cu.SCRIPT.length; n++) this._emitCodePoint(this._consume());
      this.state = Fe.SCRIPT_DATA_ESCAPED;
    } else this._ensureHibernation() || (this.state = Fe.SCRIPT_DATA_DOUBLE_ESCAPED, this._stateScriptDataDoubleEscaped(t));
  }
  _stateBeforeAttributeName(t) {
    switch (t) {
      case Ne.SPACE:
      case Ne.LINE_FEED:
      case Ne.TABULATION:
      case Ne.FORM_FEED:
        break;
      case Ne.SOLIDUS:
      case Ne.GREATER_THAN_SIGN:
      case Ne.EOF: {
        this.state = Fe.AFTER_ATTRIBUTE_NAME, this._stateAfterAttributeName(t);
        break;
      }
      case Ne.EQUALS_SIGN: {
        this._err(I0.unexpectedEqualsSignBeforeAttributeName), this._createAttr("="), this.state = Fe.ATTRIBUTE_NAME;
        break;
      }
      default:
        this._createAttr(""), this.state = Fe.ATTRIBUTE_NAME, this._stateAttributeName(t);
    }
  }
  _stateAttributeName(t) {
    switch (t) {
      case Ne.SPACE:
      case Ne.LINE_FEED:
      case Ne.TABULATION:
      case Ne.FORM_FEED:
      case Ne.SOLIDUS:
      case Ne.GREATER_THAN_SIGN:
      case Ne.EOF: {
        this._leaveAttrName(), this.state = Fe.AFTER_ATTRIBUTE_NAME, this._stateAfterAttributeName(t);
        break;
      }
      case Ne.EQUALS_SIGN: {
        this._leaveAttrName(), this.state = Fe.BEFORE_ATTRIBUTE_VALUE;
        break;
      }
      case Ne.QUOTATION_MARK:
      case Ne.APOSTROPHE:
      case Ne.LESS_THAN_SIGN: {
        this._err(I0.unexpectedCharacterInAttributeName), this.currentAttr.name += String.fromCodePoint(t);
        break;
      }
      case Ne.NULL: {
        this._err(I0.unexpectedNullCharacter), this.currentAttr.name += Ka;
        break;
      }
      default:
        this.currentAttr.name += String.fromCodePoint(dC(t) ? IH(t) : t);
    }
  }
  _stateAfterAttributeName(t) {
    switch (t) {
      case Ne.SPACE:
      case Ne.LINE_FEED:
      case Ne.TABULATION:
      case Ne.FORM_FEED:
        break;
      case Ne.SOLIDUS: {
        this.state = Fe.SELF_CLOSING_START_TAG;
        break;
      }
      case Ne.EQUALS_SIGN: {
        this.state = Fe.BEFORE_ATTRIBUTE_VALUE;
        break;
      }
      case Ne.GREATER_THAN_SIGN: {
        this.state = Fe.DATA, this.emitCurrentTagToken();
        break;
      }
      case Ne.EOF: {
        this._err(I0.eofInTag), this._emitEOFToken();
        break;
      }
      default:
        this._createAttr(""), this.state = Fe.ATTRIBUTE_NAME, this._stateAttributeName(t);
    }
  }
  _stateBeforeAttributeValue(t) {
    switch (t) {
      case Ne.SPACE:
      case Ne.LINE_FEED:
      case Ne.TABULATION:
      case Ne.FORM_FEED:
        break;
      case Ne.QUOTATION_MARK: {
        this.state = Fe.ATTRIBUTE_VALUE_DOUBLE_QUOTED;
        break;
      }
      case Ne.APOSTROPHE: {
        this.state = Fe.ATTRIBUTE_VALUE_SINGLE_QUOTED;
        break;
      }
      case Ne.GREATER_THAN_SIGN: {
        this._err(I0.missingAttributeValue), this.state = Fe.DATA, this.emitCurrentTagToken();
        break;
      }
      default:
        this.state = Fe.ATTRIBUTE_VALUE_UNQUOTED, this._stateAttributeValueUnquoted(t);
    }
  }
  _stateAttributeValueDoubleQuoted(t) {
    switch (t) {
      case Ne.QUOTATION_MARK: {
        this.state = Fe.AFTER_ATTRIBUTE_VALUE_QUOTED;
        break;
      }
      case Ne.AMPERSAND: {
        this._startCharacterReference();
        break;
      }
      case Ne.NULL: {
        this._err(I0.unexpectedNullCharacter), this.currentAttr.value += Ka;
        break;
      }
      case Ne.EOF: {
        this._err(I0.eofInTag), this._emitEOFToken();
        break;
      }
      default:
        this.currentAttr.value += String.fromCodePoint(t);
    }
  }
  _stateAttributeValueSingleQuoted(t) {
    switch (t) {
      case Ne.APOSTROPHE: {
        this.state = Fe.AFTER_ATTRIBUTE_VALUE_QUOTED;
        break;
      }
      case Ne.AMPERSAND: {
        this._startCharacterReference();
        break;
      }
      case Ne.NULL: {
        this._err(I0.unexpectedNullCharacter), this.currentAttr.value += Ka;
        break;
      }
      case Ne.EOF: {
        this._err(I0.eofInTag), this._emitEOFToken();
        break;
      }
      default:
        this.currentAttr.value += String.fromCodePoint(t);
    }
  }
  _stateAttributeValueUnquoted(t) {
    switch (t) {
      case Ne.SPACE:
      case Ne.LINE_FEED:
      case Ne.TABULATION:
      case Ne.FORM_FEED: {
        this._leaveAttrValue(), this.state = Fe.BEFORE_ATTRIBUTE_NAME;
        break;
      }
      case Ne.AMPERSAND: {
        this._startCharacterReference();
        break;
      }
      case Ne.GREATER_THAN_SIGN: {
        this._leaveAttrValue(), this.state = Fe.DATA, this.emitCurrentTagToken();
        break;
      }
      case Ne.NULL: {
        this._err(I0.unexpectedNullCharacter), this.currentAttr.value += Ka;
        break;
      }
      case Ne.QUOTATION_MARK:
      case Ne.APOSTROPHE:
      case Ne.LESS_THAN_SIGN:
      case Ne.EQUALS_SIGN:
      case Ne.GRAVE_ACCENT: {
        this._err(I0.unexpectedCharacterInUnquotedAttributeValue), this.currentAttr.value += String.fromCodePoint(t);
        break;
      }
      case Ne.EOF: {
        this._err(I0.eofInTag), this._emitEOFToken();
        break;
      }
      default:
        this.currentAttr.value += String.fromCodePoint(t);
    }
  }
  _stateAfterAttributeValueQuoted(t) {
    switch (t) {
      case Ne.SPACE:
      case Ne.LINE_FEED:
      case Ne.TABULATION:
      case Ne.FORM_FEED: {
        this._leaveAttrValue(), this.state = Fe.BEFORE_ATTRIBUTE_NAME;
        break;
      }
      case Ne.SOLIDUS: {
        this._leaveAttrValue(), this.state = Fe.SELF_CLOSING_START_TAG;
        break;
      }
      case Ne.GREATER_THAN_SIGN: {
        this._leaveAttrValue(), this.state = Fe.DATA, this.emitCurrentTagToken();
        break;
      }
      case Ne.EOF: {
        this._err(I0.eofInTag), this._emitEOFToken();
        break;
      }
      default:
        this._err(I0.missingWhitespaceBetweenAttributes), this.state = Fe.BEFORE_ATTRIBUTE_NAME, this._stateBeforeAttributeName(t);
    }
  }
  _stateSelfClosingStartTag(t) {
    switch (t) {
      case Ne.GREATER_THAN_SIGN: {
        let n = this.currentToken;
        n.selfClosing = true, this.state = Fe.DATA, this.emitCurrentTagToken();
        break;
      }
      case Ne.EOF: {
        this._err(I0.eofInTag), this._emitEOFToken();
        break;
      }
      default:
        this._err(I0.unexpectedSolidusInTag), this.state = Fe.BEFORE_ATTRIBUTE_NAME, this._stateBeforeAttributeName(t);
    }
  }
  _stateBogusComment(t) {
    let n = this.currentToken;
    switch (t) {
      case Ne.GREATER_THAN_SIGN: {
        this.state = Fe.DATA, this.emitCurrentComment(n);
        break;
      }
      case Ne.EOF: {
        this.emitCurrentComment(n), this._emitEOFToken();
        break;
      }
      case Ne.NULL: {
        this._err(I0.unexpectedNullCharacter), n.data += Ka;
        break;
      }
      default:
        n.data += String.fromCodePoint(t);
    }
  }
  _stateMarkupDeclarationOpen(t) {
    this._consumeSequenceIfMatch(cu.DASH_DASH, true) ? (this._createCommentToken(cu.DASH_DASH.length + 1), this.state = Fe.COMMENT_START) : this._consumeSequenceIfMatch(cu.DOCTYPE, false) ? (this.currentLocation = this.getCurrentLocation(cu.DOCTYPE.length + 1), this.state = Fe.DOCTYPE) : this._consumeSequenceIfMatch(cu.CDATA_START, true) ? this.inForeignNode ? this.state = Fe.CDATA_SECTION : (this._err(I0.cdataInHtmlContent), this._createCommentToken(cu.CDATA_START.length + 1), this.currentToken.data = "[CDATA[", this.state = Fe.BOGUS_COMMENT) : this._ensureHibernation() || (this._err(I0.incorrectlyOpenedComment), this._createCommentToken(2), this.state = Fe.BOGUS_COMMENT, this._stateBogusComment(t));
  }
  _stateCommentStart(t) {
    switch (t) {
      case Ne.HYPHEN_MINUS: {
        this.state = Fe.COMMENT_START_DASH;
        break;
      }
      case Ne.GREATER_THAN_SIGN: {
        this._err(I0.abruptClosingOfEmptyComment), this.state = Fe.DATA;
        let n = this.currentToken;
        this.emitCurrentComment(n);
        break;
      }
      default:
        this.state = Fe.COMMENT, this._stateComment(t);
    }
  }
  _stateCommentStartDash(t) {
    let n = this.currentToken;
    switch (t) {
      case Ne.HYPHEN_MINUS: {
        this.state = Fe.COMMENT_END;
        break;
      }
      case Ne.GREATER_THAN_SIGN: {
        this._err(I0.abruptClosingOfEmptyComment), this.state = Fe.DATA, this.emitCurrentComment(n);
        break;
      }
      case Ne.EOF: {
        this._err(I0.eofInComment), this.emitCurrentComment(n), this._emitEOFToken();
        break;
      }
      default:
        n.data += "-", this.state = Fe.COMMENT, this._stateComment(t);
    }
  }
  _stateComment(t) {
    let n = this.currentToken;
    switch (t) {
      case Ne.HYPHEN_MINUS: {
        this.state = Fe.COMMENT_END_DASH;
        break;
      }
      case Ne.LESS_THAN_SIGN: {
        n.data += "<", this.state = Fe.COMMENT_LESS_THAN_SIGN;
        break;
      }
      case Ne.NULL: {
        this._err(I0.unexpectedNullCharacter), n.data += Ka;
        break;
      }
      case Ne.EOF: {
        this._err(I0.eofInComment), this.emitCurrentComment(n), this._emitEOFToken();
        break;
      }
      default:
        n.data += String.fromCodePoint(t);
    }
  }
  _stateCommentLessThanSign(t) {
    let n = this.currentToken;
    switch (t) {
      case Ne.EXCLAMATION_MARK: {
        n.data += "!", this.state = Fe.COMMENT_LESS_THAN_SIGN_BANG;
        break;
      }
      case Ne.LESS_THAN_SIGN: {
        n.data += "<";
        break;
      }
      default:
        this.state = Fe.COMMENT, this._stateComment(t);
    }
  }
  _stateCommentLessThanSignBang(t) {
    t === Ne.HYPHEN_MINUS ? this.state = Fe.COMMENT_LESS_THAN_SIGN_BANG_DASH : (this.state = Fe.COMMENT, this._stateComment(t));
  }
  _stateCommentLessThanSignBangDash(t) {
    t === Ne.HYPHEN_MINUS ? this.state = Fe.COMMENT_LESS_THAN_SIGN_BANG_DASH_DASH : (this.state = Fe.COMMENT_END_DASH, this._stateCommentEndDash(t));
  }
  _stateCommentLessThanSignBangDashDash(t) {
    t !== Ne.GREATER_THAN_SIGN && t !== Ne.EOF && this._err(I0.nestedComment), this.state = Fe.COMMENT_END, this._stateCommentEnd(t);
  }
  _stateCommentEndDash(t) {
    let n = this.currentToken;
    switch (t) {
      case Ne.HYPHEN_MINUS: {
        this.state = Fe.COMMENT_END;
        break;
      }
      case Ne.EOF: {
        this._err(I0.eofInComment), this.emitCurrentComment(n), this._emitEOFToken();
        break;
      }
      default:
        n.data += "-", this.state = Fe.COMMENT, this._stateComment(t);
    }
  }
  _stateCommentEnd(t) {
    let n = this.currentToken;
    switch (t) {
      case Ne.GREATER_THAN_SIGN: {
        this.state = Fe.DATA, this.emitCurrentComment(n);
        break;
      }
      case Ne.EXCLAMATION_MARK: {
        this.state = Fe.COMMENT_END_BANG;
        break;
      }
      case Ne.HYPHEN_MINUS: {
        n.data += "-";
        break;
      }
      case Ne.EOF: {
        this._err(I0.eofInComment), this.emitCurrentComment(n), this._emitEOFToken();
        break;
      }
      default:
        n.data += "--", this.state = Fe.COMMENT, this._stateComment(t);
    }
  }
  _stateCommentEndBang(t) {
    let n = this.currentToken;
    switch (t) {
      case Ne.HYPHEN_MINUS: {
        n.data += "--!", this.state = Fe.COMMENT_END_DASH;
        break;
      }
      case Ne.GREATER_THAN_SIGN: {
        this._err(I0.incorrectlyClosedComment), this.state = Fe.DATA, this.emitCurrentComment(n);
        break;
      }
      case Ne.EOF: {
        this._err(I0.eofInComment), this.emitCurrentComment(n), this._emitEOFToken();
        break;
      }
      default:
        n.data += "--!", this.state = Fe.COMMENT, this._stateComment(t);
    }
  }
  _stateDoctype(t) {
    switch (t) {
      case Ne.SPACE:
      case Ne.LINE_FEED:
      case Ne.TABULATION:
      case Ne.FORM_FEED: {
        this.state = Fe.BEFORE_DOCTYPE_NAME;
        break;
      }
      case Ne.GREATER_THAN_SIGN: {
        this.state = Fe.BEFORE_DOCTYPE_NAME, this._stateBeforeDoctypeName(t);
        break;
      }
      case Ne.EOF: {
        this._err(I0.eofInDoctype), this._createDoctypeToken(null);
        let n = this.currentToken;
        n.forceQuirks = true, this.emitCurrentDoctype(n), this._emitEOFToken();
        break;
      }
      default:
        this._err(I0.missingWhitespaceBeforeDoctypeName), this.state = Fe.BEFORE_DOCTYPE_NAME, this._stateBeforeDoctypeName(t);
    }
  }
  _stateBeforeDoctypeName(t) {
    if (dC(t)) this._createDoctypeToken(String.fromCharCode(IH(t))), this.state = Fe.DOCTYPE_NAME;
    else switch (t) {
      case Ne.SPACE:
      case Ne.LINE_FEED:
      case Ne.TABULATION:
      case Ne.FORM_FEED:
        break;
      case Ne.NULL: {
        this._err(I0.unexpectedNullCharacter), this._createDoctypeToken(Ka), this.state = Fe.DOCTYPE_NAME;
        break;
      }
      case Ne.GREATER_THAN_SIGN: {
        this._err(I0.missingDoctypeName), this._createDoctypeToken(null);
        let n = this.currentToken;
        n.forceQuirks = true, this.emitCurrentDoctype(n), this.state = Fe.DATA;
        break;
      }
      case Ne.EOF: {
        this._err(I0.eofInDoctype), this._createDoctypeToken(null);
        let n = this.currentToken;
        n.forceQuirks = true, this.emitCurrentDoctype(n), this._emitEOFToken();
        break;
      }
      default:
        this._createDoctypeToken(String.fromCodePoint(t)), this.state = Fe.DOCTYPE_NAME;
    }
  }
  _stateDoctypeName(t) {
    let n = this.currentToken;
    switch (t) {
      case Ne.SPACE:
      case Ne.LINE_FEED:
      case Ne.TABULATION:
      case Ne.FORM_FEED: {
        this.state = Fe.AFTER_DOCTYPE_NAME;
        break;
      }
      case Ne.GREATER_THAN_SIGN: {
        this.state = Fe.DATA, this.emitCurrentDoctype(n);
        break;
      }
      case Ne.NULL: {
        this._err(I0.unexpectedNullCharacter), n.name += Ka;
        break;
      }
      case Ne.EOF: {
        this._err(I0.eofInDoctype), n.forceQuirks = true, this.emitCurrentDoctype(n), this._emitEOFToken();
        break;
      }
      default:
        n.name += String.fromCodePoint(dC(t) ? IH(t) : t);
    }
  }
  _stateAfterDoctypeName(t) {
    let n = this.currentToken;
    switch (t) {
      case Ne.SPACE:
      case Ne.LINE_FEED:
      case Ne.TABULATION:
      case Ne.FORM_FEED:
        break;
      case Ne.GREATER_THAN_SIGN: {
        this.state = Fe.DATA, this.emitCurrentDoctype(n);
        break;
      }
      case Ne.EOF: {
        this._err(I0.eofInDoctype), n.forceQuirks = true, this.emitCurrentDoctype(n), this._emitEOFToken();
        break;
      }
      default:
        this._consumeSequenceIfMatch(cu.PUBLIC, false) ? this.state = Fe.AFTER_DOCTYPE_PUBLIC_KEYWORD : this._consumeSequenceIfMatch(cu.SYSTEM, false) ? this.state = Fe.AFTER_DOCTYPE_SYSTEM_KEYWORD : this._ensureHibernation() || (this._err(I0.invalidCharacterSequenceAfterDoctypeName), n.forceQuirks = true, this.state = Fe.BOGUS_DOCTYPE, this._stateBogusDoctype(t));
    }
  }
  _stateAfterDoctypePublicKeyword(t) {
    let n = this.currentToken;
    switch (t) {
      case Ne.SPACE:
      case Ne.LINE_FEED:
      case Ne.TABULATION:
      case Ne.FORM_FEED: {
        this.state = Fe.BEFORE_DOCTYPE_PUBLIC_IDENTIFIER;
        break;
      }
      case Ne.QUOTATION_MARK: {
        this._err(I0.missingWhitespaceAfterDoctypePublicKeyword), n.publicId = "", this.state = Fe.DOCTYPE_PUBLIC_IDENTIFIER_DOUBLE_QUOTED;
        break;
      }
      case Ne.APOSTROPHE: {
        this._err(I0.missingWhitespaceAfterDoctypePublicKeyword), n.publicId = "", this.state = Fe.DOCTYPE_PUBLIC_IDENTIFIER_SINGLE_QUOTED;
        break;
      }
      case Ne.GREATER_THAN_SIGN: {
        this._err(I0.missingDoctypePublicIdentifier), n.forceQuirks = true, this.state = Fe.DATA, this.emitCurrentDoctype(n);
        break;
      }
      case Ne.EOF: {
        this._err(I0.eofInDoctype), n.forceQuirks = true, this.emitCurrentDoctype(n), this._emitEOFToken();
        break;
      }
      default:
        this._err(I0.missingQuoteBeforeDoctypePublicIdentifier), n.forceQuirks = true, this.state = Fe.BOGUS_DOCTYPE, this._stateBogusDoctype(t);
    }
  }
  _stateBeforeDoctypePublicIdentifier(t) {
    let n = this.currentToken;
    switch (t) {
      case Ne.SPACE:
      case Ne.LINE_FEED:
      case Ne.TABULATION:
      case Ne.FORM_FEED:
        break;
      case Ne.QUOTATION_MARK: {
        n.publicId = "", this.state = Fe.DOCTYPE_PUBLIC_IDENTIFIER_DOUBLE_QUOTED;
        break;
      }
      case Ne.APOSTROPHE: {
        n.publicId = "", this.state = Fe.DOCTYPE_PUBLIC_IDENTIFIER_SINGLE_QUOTED;
        break;
      }
      case Ne.GREATER_THAN_SIGN: {
        this._err(I0.missingDoctypePublicIdentifier), n.forceQuirks = true, this.state = Fe.DATA, this.emitCurrentDoctype(n);
        break;
      }
      case Ne.EOF: {
        this._err(I0.eofInDoctype), n.forceQuirks = true, this.emitCurrentDoctype(n), this._emitEOFToken();
        break;
      }
      default:
        this._err(I0.missingQuoteBeforeDoctypePublicIdentifier), n.forceQuirks = true, this.state = Fe.BOGUS_DOCTYPE, this._stateBogusDoctype(t);
    }
  }
  _stateDoctypePublicIdentifierDoubleQuoted(t) {
    let n = this.currentToken;
    switch (t) {
      case Ne.QUOTATION_MARK: {
        this.state = Fe.AFTER_DOCTYPE_PUBLIC_IDENTIFIER;
        break;
      }
      case Ne.NULL: {
        this._err(I0.unexpectedNullCharacter), n.publicId += Ka;
        break;
      }
      case Ne.GREATER_THAN_SIGN: {
        this._err(I0.abruptDoctypePublicIdentifier), n.forceQuirks = true, this.emitCurrentDoctype(n), this.state = Fe.DATA;
        break;
      }
      case Ne.EOF: {
        this._err(I0.eofInDoctype), n.forceQuirks = true, this.emitCurrentDoctype(n), this._emitEOFToken();
        break;
      }
      default:
        n.publicId += String.fromCodePoint(t);
    }
  }
  _stateDoctypePublicIdentifierSingleQuoted(t) {
    let n = this.currentToken;
    switch (t) {
      case Ne.APOSTROPHE: {
        this.state = Fe.AFTER_DOCTYPE_PUBLIC_IDENTIFIER;
        break;
      }
      case Ne.NULL: {
        this._err(I0.unexpectedNullCharacter), n.publicId += Ka;
        break;
      }
      case Ne.GREATER_THAN_SIGN: {
        this._err(I0.abruptDoctypePublicIdentifier), n.forceQuirks = true, this.emitCurrentDoctype(n), this.state = Fe.DATA;
        break;
      }
      case Ne.EOF: {
        this._err(I0.eofInDoctype), n.forceQuirks = true, this.emitCurrentDoctype(n), this._emitEOFToken();
        break;
      }
      default:
        n.publicId += String.fromCodePoint(t);
    }
  }
  _stateAfterDoctypePublicIdentifier(t) {
    let n = this.currentToken;
    switch (t) {
      case Ne.SPACE:
      case Ne.LINE_FEED:
      case Ne.TABULATION:
      case Ne.FORM_FEED: {
        this.state = Fe.BETWEEN_DOCTYPE_PUBLIC_AND_SYSTEM_IDENTIFIERS;
        break;
      }
      case Ne.GREATER_THAN_SIGN: {
        this.state = Fe.DATA, this.emitCurrentDoctype(n);
        break;
      }
      case Ne.QUOTATION_MARK: {
        this._err(I0.missingWhitespaceBetweenDoctypePublicAndSystemIdentifiers), n.systemId = "", this.state = Fe.DOCTYPE_SYSTEM_IDENTIFIER_DOUBLE_QUOTED;
        break;
      }
      case Ne.APOSTROPHE: {
        this._err(I0.missingWhitespaceBetweenDoctypePublicAndSystemIdentifiers), n.systemId = "", this.state = Fe.DOCTYPE_SYSTEM_IDENTIFIER_SINGLE_QUOTED;
        break;
      }
      case Ne.EOF: {
        this._err(I0.eofInDoctype), n.forceQuirks = true, this.emitCurrentDoctype(n), this._emitEOFToken();
        break;
      }
      default:
        this._err(I0.missingQuoteBeforeDoctypeSystemIdentifier), n.forceQuirks = true, this.state = Fe.BOGUS_DOCTYPE, this._stateBogusDoctype(t);
    }
  }
  _stateBetweenDoctypePublicAndSystemIdentifiers(t) {
    let n = this.currentToken;
    switch (t) {
      case Ne.SPACE:
      case Ne.LINE_FEED:
      case Ne.TABULATION:
      case Ne.FORM_FEED:
        break;
      case Ne.GREATER_THAN_SIGN: {
        this.emitCurrentDoctype(n), this.state = Fe.DATA;
        break;
      }
      case Ne.QUOTATION_MARK: {
        n.systemId = "", this.state = Fe.DOCTYPE_SYSTEM_IDENTIFIER_DOUBLE_QUOTED;
        break;
      }
      case Ne.APOSTROPHE: {
        n.systemId = "", this.state = Fe.DOCTYPE_SYSTEM_IDENTIFIER_SINGLE_QUOTED;
        break;
      }
      case Ne.EOF: {
        this._err(I0.eofInDoctype), n.forceQuirks = true, this.emitCurrentDoctype(n), this._emitEOFToken();
        break;
      }
      default:
        this._err(I0.missingQuoteBeforeDoctypeSystemIdentifier), n.forceQuirks = true, this.state = Fe.BOGUS_DOCTYPE, this._stateBogusDoctype(t);
    }
  }
  _stateAfterDoctypeSystemKeyword(t) {
    let n = this.currentToken;
    switch (t) {
      case Ne.SPACE:
      case Ne.LINE_FEED:
      case Ne.TABULATION:
      case Ne.FORM_FEED: {
        this.state = Fe.BEFORE_DOCTYPE_SYSTEM_IDENTIFIER;
        break;
      }
      case Ne.QUOTATION_MARK: {
        this._err(I0.missingWhitespaceAfterDoctypeSystemKeyword), n.systemId = "", this.state = Fe.DOCTYPE_SYSTEM_IDENTIFIER_DOUBLE_QUOTED;
        break;
      }
      case Ne.APOSTROPHE: {
        this._err(I0.missingWhitespaceAfterDoctypeSystemKeyword), n.systemId = "", this.state = Fe.DOCTYPE_SYSTEM_IDENTIFIER_SINGLE_QUOTED;
        break;
      }
      case Ne.GREATER_THAN_SIGN: {
        this._err(I0.missingDoctypeSystemIdentifier), n.forceQuirks = true, this.state = Fe.DATA, this.emitCurrentDoctype(n);
        break;
      }
      case Ne.EOF: {
        this._err(I0.eofInDoctype), n.forceQuirks = true, this.emitCurrentDoctype(n), this._emitEOFToken();
        break;
      }
      default:
        this._err(I0.missingQuoteBeforeDoctypeSystemIdentifier), n.forceQuirks = true, this.state = Fe.BOGUS_DOCTYPE, this._stateBogusDoctype(t);
    }
  }
  _stateBeforeDoctypeSystemIdentifier(t) {
    let n = this.currentToken;
    switch (t) {
      case Ne.SPACE:
      case Ne.LINE_FEED:
      case Ne.TABULATION:
      case Ne.FORM_FEED:
        break;
      case Ne.QUOTATION_MARK: {
        n.systemId = "", this.state = Fe.DOCTYPE_SYSTEM_IDENTIFIER_DOUBLE_QUOTED;
        break;
      }
      case Ne.APOSTROPHE: {
        n.systemId = "", this.state = Fe.DOCTYPE_SYSTEM_IDENTIFIER_SINGLE_QUOTED;
        break;
      }
      case Ne.GREATER_THAN_SIGN: {
        this._err(I0.missingDoctypeSystemIdentifier), n.forceQuirks = true, this.state = Fe.DATA, this.emitCurrentDoctype(n);
        break;
      }
      case Ne.EOF: {
        this._err(I0.eofInDoctype), n.forceQuirks = true, this.emitCurrentDoctype(n), this._emitEOFToken();
        break;
      }
      default:
        this._err(I0.missingQuoteBeforeDoctypeSystemIdentifier), n.forceQuirks = true, this.state = Fe.BOGUS_DOCTYPE, this._stateBogusDoctype(t);
    }
  }
  _stateDoctypeSystemIdentifierDoubleQuoted(t) {
    let n = this.currentToken;
    switch (t) {
      case Ne.QUOTATION_MARK: {
        this.state = Fe.AFTER_DOCTYPE_SYSTEM_IDENTIFIER;
        break;
      }
      case Ne.NULL: {
        this._err(I0.unexpectedNullCharacter), n.systemId += Ka;
        break;
      }
      case Ne.GREATER_THAN_SIGN: {
        this._err(I0.abruptDoctypeSystemIdentifier), n.forceQuirks = true, this.emitCurrentDoctype(n), this.state = Fe.DATA;
        break;
      }
      case Ne.EOF: {
        this._err(I0.eofInDoctype), n.forceQuirks = true, this.emitCurrentDoctype(n), this._emitEOFToken();
        break;
      }
      default:
        n.systemId += String.fromCodePoint(t);
    }
  }
  _stateDoctypeSystemIdentifierSingleQuoted(t) {
    let n = this.currentToken;
    switch (t) {
      case Ne.APOSTROPHE: {
        this.state = Fe.AFTER_DOCTYPE_SYSTEM_IDENTIFIER;
        break;
      }
      case Ne.NULL: {
        this._err(I0.unexpectedNullCharacter), n.systemId += Ka;
        break;
      }
      case Ne.GREATER_THAN_SIGN: {
        this._err(I0.abruptDoctypeSystemIdentifier), n.forceQuirks = true, this.emitCurrentDoctype(n), this.state = Fe.DATA;
        break;
      }
      case Ne.EOF: {
        this._err(I0.eofInDoctype), n.forceQuirks = true, this.emitCurrentDoctype(n), this._emitEOFToken();
        break;
      }
      default:
        n.systemId += String.fromCodePoint(t);
    }
  }
  _stateAfterDoctypeSystemIdentifier(t) {
    let n = this.currentToken;
    switch (t) {
      case Ne.SPACE:
      case Ne.LINE_FEED:
      case Ne.TABULATION:
      case Ne.FORM_FEED:
        break;
      case Ne.GREATER_THAN_SIGN: {
        this.emitCurrentDoctype(n), this.state = Fe.DATA;
        break;
      }
      case Ne.EOF: {
        this._err(I0.eofInDoctype), n.forceQuirks = true, this.emitCurrentDoctype(n), this._emitEOFToken();
        break;
      }
      default:
        this._err(I0.unexpectedCharacterAfterDoctypeSystemIdentifier), this.state = Fe.BOGUS_DOCTYPE, this._stateBogusDoctype(t);
    }
  }
  _stateBogusDoctype(t) {
    let n = this.currentToken;
    switch (t) {
      case Ne.GREATER_THAN_SIGN: {
        this.emitCurrentDoctype(n), this.state = Fe.DATA;
        break;
      }
      case Ne.NULL: {
        this._err(I0.unexpectedNullCharacter);
        break;
      }
      case Ne.EOF: {
        this.emitCurrentDoctype(n), this._emitEOFToken();
        break;
      }
      default:
    }
  }
  _stateCdataSection(t) {
    switch (t) {
      case Ne.RIGHT_SQUARE_BRACKET: {
        this.state = Fe.CDATA_SECTION_BRACKET;
        break;
      }
      case Ne.EOF: {
        this._err(I0.eofInCdata), this._emitEOFToken();
        break;
      }
      default:
        this._emitCodePoint(t);
    }
  }
  _stateCdataSectionBracket(t) {
    t === Ne.RIGHT_SQUARE_BRACKET ? this.state = Fe.CDATA_SECTION_END : (this._emitChars("]"), this.state = Fe.CDATA_SECTION, this._stateCdataSection(t));
  }
  _stateCdataSectionEnd(t) {
    switch (t) {
      case Ne.GREATER_THAN_SIGN: {
        this.state = Fe.DATA;
        break;
      }
      case Ne.RIGHT_SQUARE_BRACKET: {
        this._emitChars("]");
        break;
      }
      default:
        this._emitChars("]]"), this.state = Fe.CDATA_SECTION, this._stateCdataSection(t);
    }
  }
  _stateCharacterReference() {
    let t = this.entityDecoder.write(this.preprocessor.html, this.preprocessor.pos);
    if (t < 0) if (this.preprocessor.lastChunkWritten) t = this.entityDecoder.end();
    else {
      this.active = false, this.preprocessor.pos = this.preprocessor.html.length - 1, this.consumedAfterSnapshot = 0, this.preprocessor.endOfChunkHit = true;
      return;
    }
    t === 0 ? (this.preprocessor.pos = this.entityStartPos, this._flushCodePointConsumedAsCharacterReference(Ne.AMPERSAND), this.state = !this._isCharacterReferenceInAttribute() && tx0(this.preprocessor.peek(1)) ? Fe.AMBIGUOUS_AMPERSAND : this.returnState) : this.state = this.returnState;
  }
  _stateAmbiguousAmpersand(t) {
    tx0(t) ? this._flushCodePointConsumedAsCharacterReference(t) : (t === Ne.SEMICOLON && this._err(I0.unknownNamedCharacterReference), this.state = this.returnState, this._callState(t));
  }
};
var sx0 = /* @__PURE__ */ new Set([Z.DD, Z.DT, Z.LI, Z.OPTGROUP, Z.OPTION, Z.P, Z.RB, Z.RP, Z.RT, Z.RTC]);
var ix0 = /* @__PURE__ */ new Set([...sx0, Z.CAPTION, Z.COLGROUP, Z.TBODY, Z.TD, Z.TFOOT, Z.TH, Z.THEAD, Z.TR]);
var RH = /* @__PURE__ */ new Set([Z.APPLET, Z.CAPTION, Z.HTML, Z.MARQUEE, Z.OBJECT, Z.TABLE, Z.TD, Z.TEMPLATE, Z.TH]);
var CDt = /* @__PURE__ */ new Set([...RH, Z.OL, Z.UL]);
var NDt = /* @__PURE__ */ new Set([...RH, Z.BUTTON]);
var ax0 = /* @__PURE__ */ new Set([Z.ANNOTATION_XML, Z.MI, Z.MN, Z.MO, Z.MS, Z.MTEXT]);
var ox0 = /* @__PURE__ */ new Set([Z.DESC, Z.FOREIGN_OBJECT, Z.TITLE]);
var ODt = /* @__PURE__ */ new Set([Z.TR, Z.TEMPLATE, Z.HTML]);
var DDt = /* @__PURE__ */ new Set([Z.TBODY, Z.TFOOT, Z.THEAD, Z.TEMPLATE, Z.HTML]);
var PDt = /* @__PURE__ */ new Set([Z.TABLE, Z.TEMPLATE, Z.HTML]);
var BDt = /* @__PURE__ */ new Set([Z.TD, Z.TH]);
var CH = class {
  get currentTmplContentOrNode() {
    return this._isInTemplate() ? this.treeAdapter.getTemplateContent(this.current) : this.current;
  }
  constructor(t, n, s) {
    this.treeAdapter = n, this.handler = s, this.items = [], this.tagIDs = [], this.stackTop = -1, this.tmplCount = 0, this.currentTagId = Z.UNKNOWN, this.current = t;
  }
  _indexOf(t) {
    return this.items.lastIndexOf(t, this.stackTop);
  }
  _isInTemplate() {
    return this.currentTagId === Z.TEMPLATE && this.treeAdapter.getNamespaceURI(this.current) === G0.HTML;
  }
  _updateCurrentElement() {
    this.current = this.items[this.stackTop], this.currentTagId = this.tagIDs[this.stackTop];
  }
  push(t, n) {
    this.stackTop++, this.items[this.stackTop] = t, this.current = t, this.tagIDs[this.stackTop] = n, this.currentTagId = n, this._isInTemplate() && this.tmplCount++, this.handler.onItemPush(t, n, true);
  }
  pop() {
    let t = this.current;
    this.tmplCount > 0 && this._isInTemplate() && this.tmplCount--, this.stackTop--, this._updateCurrentElement(), this.handler.onItemPop(t, true);
  }
  replace(t, n) {
    let s = this._indexOf(t);
    this.items[s] = n, s === this.stackTop && (this.current = n);
  }
  insertAfter(t, n, s) {
    let c = this._indexOf(t) + 1;
    this.items.splice(c, 0, n), this.tagIDs.splice(c, 0, s), this.stackTop++, c === this.stackTop && this._updateCurrentElement(), this.current && this.currentTagId !== void 0 && this.handler.onItemPush(this.current, this.currentTagId, c === this.stackTop);
  }
  popUntilTagNamePopped(t) {
    let n = this.stackTop + 1;
    do
      n = this.tagIDs.lastIndexOf(t, n - 1);
    while (n > 0 && this.treeAdapter.getNamespaceURI(this.items[n]) !== G0.HTML);
    this.shortenToLength(Math.max(n, 0));
  }
  shortenToLength(t) {
    for (; this.stackTop >= t; ) {
      let n = this.current;
      this.tmplCount > 0 && this._isInTemplate() && (this.tmplCount -= 1), this.stackTop--, this._updateCurrentElement(), this.handler.onItemPop(n, this.stackTop < t);
    }
  }
  popUntilElementPopped(t) {
    let n = this._indexOf(t);
    this.shortenToLength(Math.max(n, 0));
  }
  popUntilPopped(t, n) {
    let s = this._indexOfTagNames(t, n);
    this.shortenToLength(Math.max(s, 0));
  }
  popUntilNumberedHeaderPopped() {
    this.popUntilPopped(r_, G0.HTML);
  }
  popUntilTableCellPopped() {
    this.popUntilPopped(BDt, G0.HTML);
  }
  popAllUpToHtmlElement() {
    this.tmplCount = 0, this.shortenToLength(1);
  }
  _indexOfTagNames(t, n) {
    for (let s = this.stackTop; s >= 0; s--) if (t.has(this.tagIDs[s]) && this.treeAdapter.getNamespaceURI(this.items[s]) === n) return s;
    return -1;
  }
  clearBackTo(t, n) {
    let s = this._indexOfTagNames(t, n);
    this.shortenToLength(s + 1);
  }
  clearBackToTableContext() {
    this.clearBackTo(PDt, G0.HTML);
  }
  clearBackToTableBodyContext() {
    this.clearBackTo(DDt, G0.HTML);
  }
  clearBackToTableRowContext() {
    this.clearBackTo(ODt, G0.HTML);
  }
  remove(t) {
    let n = this._indexOf(t);
    n >= 0 && (n === this.stackTop ? this.pop() : (this.items.splice(n, 1), this.tagIDs.splice(n, 1), this.stackTop--, this._updateCurrentElement(), this.handler.onItemPop(t, false)));
  }
  tryPeekProperlyNestedBodyElement() {
    return this.stackTop >= 1 && this.tagIDs[1] === Z.BODY ? this.items[1] : null;
  }
  contains(t) {
    return this._indexOf(t) > -1;
  }
  getCommonAncestor(t) {
    let n = this._indexOf(t) - 1;
    return n >= 0 ? this.items[n] : null;
  }
  isRootHtmlElementCurrent() {
    return this.stackTop === 0 && this.tagIDs[0] === Z.HTML;
  }
  hasInDynamicScope(t, n) {
    for (let s = this.stackTop; s >= 0; s--) {
      let c = this.tagIDs[s];
      switch (this.treeAdapter.getNamespaceURI(this.items[s])) {
        case G0.HTML: {
          if (c === t) return true;
          if (n.has(c)) return false;
          break;
        }
        case G0.SVG: {
          if (ox0.has(c)) return false;
          break;
        }
        case G0.MATHML: {
          if (ax0.has(c)) return false;
          break;
        }
      }
    }
    return true;
  }
  hasInScope(t) {
    return this.hasInDynamicScope(t, RH);
  }
  hasInListItemScope(t) {
    return this.hasInDynamicScope(t, CDt);
  }
  hasInButtonScope(t) {
    return this.hasInDynamicScope(t, NDt);
  }
  hasNumberedHeaderInScope() {
    for (let t = this.stackTop; t >= 0; t--) {
      let n = this.tagIDs[t];
      switch (this.treeAdapter.getNamespaceURI(this.items[t])) {
        case G0.HTML: {
          if (r_.has(n)) return true;
          if (RH.has(n)) return false;
          break;
        }
        case G0.SVG: {
          if (ox0.has(n)) return false;
          break;
        }
        case G0.MATHML: {
          if (ax0.has(n)) return false;
          break;
        }
      }
    }
    return true;
  }
  hasInTableScope(t) {
    for (let n = this.stackTop; n >= 0; n--) if (this.treeAdapter.getNamespaceURI(this.items[n]) === G0.HTML) switch (this.tagIDs[n]) {
      case t:
        return true;
      case Z.TABLE:
      case Z.HTML:
        return false;
    }
    return true;
  }
  hasTableBodyContextInTableScope() {
    for (let t = this.stackTop; t >= 0; t--) if (this.treeAdapter.getNamespaceURI(this.items[t]) === G0.HTML) switch (this.tagIDs[t]) {
      case Z.TBODY:
      case Z.THEAD:
      case Z.TFOOT:
        return true;
      case Z.TABLE:
      case Z.HTML:
        return false;
    }
    return true;
  }
  hasInSelectScope(t) {
    for (let n = this.stackTop; n >= 0; n--) if (this.treeAdapter.getNamespaceURI(this.items[n]) === G0.HTML) switch (this.tagIDs[n]) {
      case t:
        return true;
      case Z.OPTION:
      case Z.OPTGROUP:
        break;
      default:
        return false;
    }
    return true;
  }
  generateImpliedEndTags() {
    for (; this.currentTagId !== void 0 && sx0.has(this.currentTagId); ) this.pop();
  }
  generateImpliedEndTagsThoroughly() {
    for (; this.currentTagId !== void 0 && ix0.has(this.currentTagId); ) this.pop();
  }
  generateImpliedEndTagsWithExclusion(t) {
    for (; this.currentTagId !== void 0 && this.currentTagId !== t && ix0.has(this.currentTagId); ) this.pop();
  }
};
var V2;
(function(e9) {
  e9[e9.Marker = 0] = "Marker", e9[e9.Element = 1] = "Element";
})(V2 || (V2 = {}));
var xx0 = { type: V2.Marker };
var NH = class {
  constructor(t) {
    this.treeAdapter = t, this.entries = [], this.bookmark = null;
  }
  _getNoahArkConditionCandidates(t, n) {
    let s = [], c = n.length, l = this.treeAdapter.getTagName(t), d = this.treeAdapter.getNamespaceURI(t);
    for (let m = 0; m < this.entries.length; m++) {
      let g = this.entries[m];
      if (g.type === V2.Marker) break;
      let { element: y } = g;
      if (this.treeAdapter.getTagName(y) === l && this.treeAdapter.getNamespaceURI(y) === d) {
        let v = this.treeAdapter.getAttrList(y);
        v.length === c && s.push({ idx: m, attrs: v });
      }
    }
    return s;
  }
  _ensureNoahArkCondition(t) {
    if (this.entries.length < 3) return;
    let n = this.treeAdapter.getAttrList(t), s = this._getNoahArkConditionCandidates(t, n);
    if (s.length < 3) return;
    let c = new Map(n.map((d) => [d.name, d.value])), l = 0;
    for (let d = 0; d < s.length; d++) {
      let m = s[d];
      m.attrs.every((g) => c.get(g.name) === g.value) && (l += 1, l >= 3 && this.entries.splice(m.idx, 1));
    }
  }
  insertMarker() {
    this.entries.unshift(xx0);
  }
  pushElement(t, n) {
    this._ensureNoahArkCondition(t), this.entries.unshift({ type: V2.Element, element: t, token: n });
  }
  insertElementAfterBookmark(t, n) {
    let s = this.entries.indexOf(this.bookmark);
    this.entries.splice(s, 0, { type: V2.Element, element: t, token: n });
  }
  removeEntry(t) {
    let n = this.entries.indexOf(t);
    n !== -1 && this.entries.splice(n, 1);
  }
  clearToLastMarker() {
    let t = this.entries.indexOf(xx0);
    t === -1 ? this.entries.length = 0 : this.entries.splice(0, t + 1);
  }
  getElementEntryInScopeWithTagName(t) {
    let n = this.entries.find((s) => s.type === V2.Marker || this.treeAdapter.getTagName(s.element) === t);
    return n && n.type === V2.Element ? n : null;
  }
  getElementEntry(t) {
    return this.entries.find((n) => n.type === V2.Element && n.element === t);
  }
};
var Td = { createDocument() {
  return { nodeName: "#document", mode: $c.NO_QUIRKS, childNodes: [] };
}, createDocumentFragment() {
  return { nodeName: "#document-fragment", childNodes: [] };
}, createElement(e9, t, n) {
  return { nodeName: e9, tagName: e9, attrs: n, namespaceURI: t, childNodes: [], parentNode: null };
}, createCommentNode(e9) {
  return { nodeName: "#comment", data: e9, parentNode: null };
}, createTextNode(e9) {
  return { nodeName: "#text", value: e9, parentNode: null };
}, appendChild(e9, t) {
  e9.childNodes.push(t), t.parentNode = e9;
}, insertBefore(e9, t, n) {
  let s = e9.childNodes.indexOf(n);
  e9.childNodes.splice(s, 0, t), t.parentNode = e9;
}, setTemplateContent(e9, t) {
  e9.content = t;
}, getTemplateContent(e9) {
  return e9.content;
}, setDocumentType(e9, t, n, s) {
  let c = e9.childNodes.find((l) => l.nodeName === "#documentType");
  if (c) c.name = t, c.publicId = n, c.systemId = s;
  else {
    let l = { nodeName: "#documentType", name: t, publicId: n, systemId: s, parentNode: null };
    Td.appendChild(e9, l);
  }
}, setDocumentMode(e9, t) {
  e9.mode = t;
}, getDocumentMode(e9) {
  return e9.mode;
}, detachNode(e9) {
  if (e9.parentNode) {
    let t = e9.parentNode.childNodes.indexOf(e9);
    e9.parentNode.childNodes.splice(t, 1), e9.parentNode = null;
  }
}, insertText(e9, t) {
  if (e9.childNodes.length > 0) {
    let n = e9.childNodes[e9.childNodes.length - 1];
    if (Td.isTextNode(n)) {
      n.value += t;
      return;
    }
  }
  Td.appendChild(e9, Td.createTextNode(t));
}, insertTextBefore(e9, t, n) {
  let s = e9.childNodes[e9.childNodes.indexOf(n) - 1];
  s && Td.isTextNode(s) ? s.value += t : Td.insertBefore(e9, Td.createTextNode(t), n);
}, adoptAttributes(e9, t) {
  let n = new Set(e9.attrs.map((s) => s.name));
  for (let s = 0; s < t.length; s++) n.has(t[s].name) || e9.attrs.push(t[s]);
}, getFirstChild(e9) {
  return e9.childNodes[0];
}, getChildNodes(e9) {
  return e9.childNodes;
}, getParentNode(e9) {
  return e9.parentNode;
}, getAttrList(e9) {
  return e9.attrs;
}, getTagName(e9) {
  return e9.tagName;
}, getNamespaceURI(e9) {
  return e9.namespaceURI;
}, getTextNodeContent(e9) {
  return e9.value;
}, getCommentNodeContent(e9) {
  return e9.data;
}, getDocumentTypeNodeName(e9) {
  return e9.name;
}, getDocumentTypeNodePublicId(e9) {
  return e9.publicId;
}, getDocumentTypeNodeSystemId(e9) {
  return e9.systemId;
}, isTextNode(e9) {
  return e9.nodeName === "#text";
}, isCommentNode(e9) {
  return e9.nodeName === "#comment";
}, isDocumentTypeNode(e9) {
  return e9.nodeName === "#documentType";
}, isElementNode(e9) {
  return Object.prototype.hasOwnProperty.call(e9, "tagName");
}, setNodeSourceCodeLocation(e9, t) {
  e9.sourceCodeLocation = t;
}, getNodeSourceCodeLocation(e9) {
  return e9.sourceCodeLocation;
}, updateNodeSourceCodeLocation(e9, t) {
  e9.sourceCodeLocation = { ...e9.sourceCodeLocation, ...t };
} };
var ux0 = "html";
var LDt = "about:legacy-compat";
var MDt = "http://www.ibm.com/data/dtd/v11/ibmxhtml1-transitional.dtd";
var lx0 = ["+//silmaril//dtd html pro v0r11 19970101//", "-//as//dtd html 3.0 aswedit + extensions//", "-//advasoft ltd//dtd html 3.0 aswedit + extensions//", "-//ietf//dtd html 2.0 level 1//", "-//ietf//dtd html 2.0 level 2//", "-//ietf//dtd html 2.0 strict level 1//", "-//ietf//dtd html 2.0 strict level 2//", "-//ietf//dtd html 2.0 strict//", "-//ietf//dtd html 2.0//", "-//ietf//dtd html 2.1e//", "-//ietf//dtd html 3.0//", "-//ietf//dtd html 3.2 final//", "-//ietf//dtd html 3.2//", "-//ietf//dtd html 3//", "-//ietf//dtd html level 0//", "-//ietf//dtd html level 1//", "-//ietf//dtd html level 2//", "-//ietf//dtd html level 3//", "-//ietf//dtd html strict level 0//", "-//ietf//dtd html strict level 1//", "-//ietf//dtd html strict level 2//", "-//ietf//dtd html strict level 3//", "-//ietf//dtd html strict//", "-//ietf//dtd html//", "-//metrius//dtd metrius presentational//", "-//microsoft//dtd internet explorer 2.0 html strict//", "-//microsoft//dtd internet explorer 2.0 html//", "-//microsoft//dtd internet explorer 2.0 tables//", "-//microsoft//dtd internet explorer 3.0 html strict//", "-//microsoft//dtd internet explorer 3.0 html//", "-//microsoft//dtd internet explorer 3.0 tables//", "-//netscape comm. corp.//dtd html//", "-//netscape comm. corp.//dtd strict html//", "-//o'reilly and associates//dtd html 2.0//", "-//o'reilly and associates//dtd html extended 1.0//", "-//o'reilly and associates//dtd html extended relaxed 1.0//", "-//sq//dtd html 2.0 hotmetal + extensions//", "-//softquad software//dtd hotmetal pro 6.0::19990601::extensions to html 4.0//", "-//softquad//dtd hotmetal pro 4.0::19971010::extensions to html 4.0//", "-//spyglass//dtd html 2.0 extended//", "-//sun microsystems corp.//dtd hotjava html//", "-//sun microsystems corp.//dtd hotjava strict html//", "-//w3c//dtd html 3 1995-03-24//", "-//w3c//dtd html 3.2 draft//", "-//w3c//dtd html 3.2 final//", "-//w3c//dtd html 3.2//", "-//w3c//dtd html 3.2s draft//", "-//w3c//dtd html 4.0 frameset//", "-//w3c//dtd html 4.0 transitional//", "-//w3c//dtd html experimental 19960712//", "-//w3c//dtd html experimental 970421//", "-//w3c//dtd w3 html//", "-//w3o//dtd w3 html 3.0//", "-//webtechs//dtd mozilla html 2.0//", "-//webtechs//dtd mozilla html//"];
var UDt = [...lx0, "-//w3c//dtd html 4.01 frameset//", "-//w3c//dtd html 4.01 transitional//"];
var $Dt = /* @__PURE__ */ new Set(["-//w3o//dtd w3 html strict 3.0//en//", "-/w3c/dtd html 4.0 transitional/en", "html"]);
var fx0 = ["-//w3c//dtd xhtml 1.0 frameset//", "-//w3c//dtd xhtml 1.0 transitional//"];
var FDt = [...fx0, "-//w3c//dtd html 4.01 frameset//", "-//w3c//dtd html 4.01 transitional//"];
function cx0(e9, t) {
  return t.some((n) => e9.startsWith(n));
}
function dx0(e9) {
  return e9.name === ux0 && e9.publicId === null && (e9.systemId === null || e9.systemId === LDt);
}
function px0(e9) {
  if (e9.name !== ux0) return $c.QUIRKS;
  let { systemId: t } = e9;
  if (t && t.toLowerCase() === MDt) return $c.QUIRKS;
  let { publicId: n } = e9;
  if (n !== null) {
    if (n = n.toLowerCase(), $Dt.has(n)) return $c.QUIRKS;
    let s = t === null ? UDt : lx0;
    if (cx0(n, s)) return $c.QUIRKS;
    if (s = t === null ? fx0 : FDt, cx0(n, s)) return $c.LIMITED_QUIRKS;
  }
  return $c.NO_QUIRKS;
}
var mx0 = { TEXT_HTML: "text/html", APPLICATION_XML: "application/xhtml+xml" };
var VDt = "definitionurl";
var jDt = "definitionURL";
var GDt = new Map(["attributeName", "attributeType", "baseFrequency", "baseProfile", "calcMode", "clipPathUnits", "diffuseConstant", "edgeMode", "filterUnits", "glyphRef", "gradientTransform", "gradientUnits", "kernelMatrix", "kernelUnitLength", "keyPoints", "keySplines", "keyTimes", "lengthAdjust", "limitingConeAngle", "markerHeight", "markerUnits", "markerWidth", "maskContentUnits", "maskUnits", "numOctaves", "pathLength", "patternContentUnits", "patternTransform", "patternUnits", "pointsAtX", "pointsAtY", "pointsAtZ", "preserveAlpha", "preserveAspectRatio", "primitiveUnits", "refX", "refY", "repeatCount", "repeatDur", "requiredExtensions", "requiredFeatures", "specularConstant", "specularExponent", "spreadMethod", "startOffset", "stdDeviation", "stitchTiles", "surfaceScale", "systemLanguage", "tableValues", "targetX", "targetY", "textLength", "viewBox", "viewTarget", "xChannelSelector", "yChannelSelector", "zoomAndPan"].map((e9) => [e9.toLowerCase(), e9]));
var HDt = /* @__PURE__ */ new Map([["xlink:actuate", { prefix: "xlink", name: "actuate", namespace: G0.XLINK }], ["xlink:arcrole", { prefix: "xlink", name: "arcrole", namespace: G0.XLINK }], ["xlink:href", { prefix: "xlink", name: "href", namespace: G0.XLINK }], ["xlink:role", { prefix: "xlink", name: "role", namespace: G0.XLINK }], ["xlink:show", { prefix: "xlink", name: "show", namespace: G0.XLINK }], ["xlink:title", { prefix: "xlink", name: "title", namespace: G0.XLINK }], ["xlink:type", { prefix: "xlink", name: "type", namespace: G0.XLINK }], ["xml:lang", { prefix: "xml", name: "lang", namespace: G0.XML }], ["xml:space", { prefix: "xml", name: "space", namespace: G0.XML }], ["xmlns", { prefix: "", name: "xmlns", namespace: G0.XMLNS }], ["xmlns:xlink", { prefix: "xmlns", name: "xlink", namespace: G0.XMLNS }]]);
var qDt = new Map(["altGlyph", "altGlyphDef", "altGlyphItem", "animateColor", "animateMotion", "animateTransform", "clipPath", "feBlend", "feColorMatrix", "feComponentTransfer", "feComposite", "feConvolveMatrix", "feDiffuseLighting", "feDisplacementMap", "feDistantLight", "feFlood", "feFuncA", "feFuncB", "feFuncG", "feFuncR", "feGaussianBlur", "feImage", "feMerge", "feMergeNode", "feMorphology", "feOffset", "fePointLight", "feSpecularLighting", "feSpotLight", "feTile", "feTurbulence", "foreignObject", "glyphRef", "linearGradient", "radialGradient", "textPath"].map((e9) => [e9.toLowerCase(), e9]));
var zDt = /* @__PURE__ */ new Set([Z.B, Z.BIG, Z.BLOCKQUOTE, Z.BODY, Z.BR, Z.CENTER, Z.CODE, Z.DD, Z.DIV, Z.DL, Z.DT, Z.EM, Z.EMBED, Z.H1, Z.H2, Z.H3, Z.H4, Z.H5, Z.H6, Z.HEAD, Z.HR, Z.I, Z.IMG, Z.LI, Z.LISTING, Z.MENU, Z.META, Z.NOBR, Z.OL, Z.P, Z.PRE, Z.RUBY, Z.S, Z.SMALL, Z.SPAN, Z.STRONG, Z.STRIKE, Z.SUB, Z.SUP, Z.TABLE, Z.TT, Z.U, Z.UL, Z.VAR]);
function hx0(e9) {
  let t = e9.tagID;
  return t === Z.FONT && e9.attrs.some(({ name: s }) => s === S1.COLOR || s === S1.SIZE || s === S1.FACE) || zDt.has(t);
}
function Xde(e9) {
  for (let t = 0; t < e9.attrs.length; t++) if (e9.attrs[t].name === VDt) {
    e9.attrs[t].name = jDt;
    break;
  }
}
function e2e(e9) {
  for (let t = 0; t < e9.attrs.length; t++) {
    let n = GDt.get(e9.attrs[t].name);
    n != null && (e9.attrs[t].name = n);
  }
}
function OH(e9) {
  for (let t = 0; t < e9.attrs.length; t++) {
    let n = HDt.get(e9.attrs[t].name);
    n && (e9.attrs[t].prefix = n.prefix, e9.attrs[t].name = n.name, e9.attrs[t].namespace = n.namespace);
  }
}
function gx0(e9) {
  let t = qDt.get(e9.tagName);
  t != null && (e9.tagName = t, e9.tagID = a7(e9.tagName));
}
function YDt(e9, t) {
  return t === G0.MATHML && (e9 === Z.MI || e9 === Z.MO || e9 === Z.MN || e9 === Z.MS || e9 === Z.MTEXT);
}
function QDt(e9, t, n) {
  if (t === G0.MATHML && e9 === Z.ANNOTATION_XML) {
    for (let s = 0; s < n.length; s++) if (n[s].name === S1.ENCODING) {
      let c = n[s].value.toLowerCase();
      return c === mx0.TEXT_HTML || c === mx0.APPLICATION_XML;
    }
  }
  return t === G0.SVG && (e9 === Z.FOREIGN_OBJECT || e9 === Z.DESC || e9 === Z.TITLE);
}
function bx0(e9, t, n, s) {
  return (!s || s === G0.HTML) && QDt(e9, t, n) || (!s || s === G0.MATHML) && YDt(e9, t);
}
var ZDt = "hidden";
var KDt = 8;
var JDt = 3;
var Ze;
(function(e9) {
  e9[e9.INITIAL = 0] = "INITIAL", e9[e9.BEFORE_HTML = 1] = "BEFORE_HTML", e9[e9.BEFORE_HEAD = 2] = "BEFORE_HEAD", e9[e9.IN_HEAD = 3] = "IN_HEAD", e9[e9.IN_HEAD_NO_SCRIPT = 4] = "IN_HEAD_NO_SCRIPT", e9[e9.AFTER_HEAD = 5] = "AFTER_HEAD", e9[e9.IN_BODY = 6] = "IN_BODY", e9[e9.TEXT = 7] = "TEXT", e9[e9.IN_TABLE = 8] = "IN_TABLE", e9[e9.IN_TABLE_TEXT = 9] = "IN_TABLE_TEXT", e9[e9.IN_CAPTION = 10] = "IN_CAPTION", e9[e9.IN_COLUMN_GROUP = 11] = "IN_COLUMN_GROUP", e9[e9.IN_TABLE_BODY = 12] = "IN_TABLE_BODY", e9[e9.IN_ROW = 13] = "IN_ROW", e9[e9.IN_CELL = 14] = "IN_CELL", e9[e9.IN_SELECT = 15] = "IN_SELECT", e9[e9.IN_SELECT_IN_TABLE = 16] = "IN_SELECT_IN_TABLE", e9[e9.IN_TEMPLATE = 17] = "IN_TEMPLATE", e9[e9.AFTER_BODY = 18] = "AFTER_BODY", e9[e9.IN_FRAMESET = 19] = "IN_FRAMESET", e9[e9.AFTER_FRAMESET = 20] = "AFTER_FRAMESET", e9[e9.AFTER_AFTER_BODY = 21] = "AFTER_AFTER_BODY", e9[e9.AFTER_AFTER_FRAMESET = 22] = "AFTER_AFTER_FRAMESET";
})(Ze || (Ze = {}));
var XDt = { startLine: -1, startCol: -1, startOffset: -1, endLine: -1, endCol: -1, endOffset: -1 };
var _x0 = /* @__PURE__ */ new Set([Z.TABLE, Z.TBODY, Z.TFOOT, Z.THEAD, Z.TR]);
var Ax0 = { scriptingEnabled: true, sourceCodeLocationInfo: false, treeAdapter: Td, onParseError: null };
var n_ = class {
  constructor(t, n, s = null, c = null) {
    this.fragmentContext = s, this.scriptHandler = c, this.currentToken = null, this.stopped = false, this.insertionMode = Ze.INITIAL, this.originalInsertionMode = Ze.INITIAL, this.headElement = null, this.formElement = null, this.currentNotInHTML = false, this.tmplInsertionModeStack = [], this.pendingCharacterTokens = [], this.hasNonWhitespacePendingCharacterToken = false, this.framesetOk = true, this.skipNextNewLine = false, this.fosterParentingEnabled = false, this.options = { ...Ax0, ...t }, this.treeAdapter = this.options.treeAdapter, this.onParseError = this.options.onParseError, this.onParseError && (this.options.sourceCodeLocationInfo = true), this.document = n ?? this.treeAdapter.createDocument(), this.tokenizer = new pC(this.options, this), this.activeFormattingElements = new NH(this.treeAdapter), this.fragmentContextID = s ? a7(this.treeAdapter.getTagName(s)) : Z.UNKNOWN, this._setContextModes(s ?? this.document, this.fragmentContextID), this.openElements = new CH(this.document, this.treeAdapter, this);
  }
  static parse(t, n) {
    let s = new this(n);
    return s.tokenizer.write(t, true), s.document;
  }
  static getFragmentParser(t, n) {
    let s = { ...Ax0, ...n };
    t ?? (t = s.treeAdapter.createElement(d0.TEMPLATE, G0.HTML, []));
    let c = s.treeAdapter.createElement("documentmock", G0.HTML, []), l = new this(s, c, t);
    return l.fragmentContextID === Z.TEMPLATE && l.tmplInsertionModeStack.unshift(Ze.IN_TEMPLATE), l._initTokenizerForFragmentParsing(), l._insertFakeRootElement(), l._resetInsertionMode(), l._findFormInFragmentContext(), l;
  }
  getFragment() {
    let t = this.treeAdapter.getFirstChild(this.document), n = this.treeAdapter.createDocumentFragment();
    return this._adoptNodes(t, n), n;
  }
  _err(t, n, s) {
    var c;
    if (!this.onParseError) return;
    let l = (c = t.location) !== null && c !== void 0 ? c : XDt, d = { code: n, startLine: l.startLine, startCol: l.startCol, startOffset: l.startOffset, endLine: s ? l.startLine : l.endLine, endCol: s ? l.startCol : l.endCol, endOffset: s ? l.startOffset : l.endOffset };
    this.onParseError(d);
  }
  onItemPush(t, n, s) {
    var c, l;
    (l = (c = this.treeAdapter).onItemPush) === null || l === void 0 || l.call(c, t), s && this.openElements.stackTop > 0 && this._setContextModes(t, n);
  }
  onItemPop(t, n) {
    var s, c;
    if (this.options.sourceCodeLocationInfo && this._setEndLocation(t, this.currentToken), (c = (s = this.treeAdapter).onItemPop) === null || c === void 0 || c.call(s, t, this.openElements.current), n) {
      let l, d;
      this.openElements.stackTop === 0 && this.fragmentContext ? (l = this.fragmentContext, d = this.fragmentContextID) : { current: l, currentTagId: d } = this.openElements, this._setContextModes(l, d);
    }
  }
  _setContextModes(t, n) {
    let s = t === this.document || t && this.treeAdapter.getNamespaceURI(t) === G0.HTML;
    this.currentNotInHTML = !s, this.tokenizer.inForeignNode = !s && t !== void 0 && n !== void 0 && !this._isIntegrationPoint(n, t);
  }
  _switchToTextParsing(t, n) {
    this._insertElement(t, G0.HTML), this.tokenizer.state = n, this.originalInsertionMode = this.insertionMode, this.insertionMode = Ze.TEXT;
  }
  switchToPlaintextParsing() {
    this.insertionMode = Ze.TEXT, this.originalInsertionMode = Ze.IN_BODY, this.tokenizer.state = Fc.PLAINTEXT;
  }
  _getAdjustedCurrentElement() {
    return this.openElements.stackTop === 0 && this.fragmentContext ? this.fragmentContext : this.openElements.current;
  }
  _findFormInFragmentContext() {
    let t = this.fragmentContext;
    for (; t; ) {
      if (this.treeAdapter.getTagName(t) === d0.FORM) {
        this.formElement = t;
        break;
      }
      t = this.treeAdapter.getParentNode(t);
    }
  }
  _initTokenizerForFragmentParsing() {
    if (!(!this.fragmentContext || this.treeAdapter.getNamespaceURI(this.fragmentContext) !== G0.HTML)) switch (this.fragmentContextID) {
      case Z.TITLE:
      case Z.TEXTAREA: {
        this.tokenizer.state = Fc.RCDATA;
        break;
      }
      case Z.STYLE:
      case Z.XMP:
      case Z.IFRAME:
      case Z.NOEMBED:
      case Z.NOFRAMES:
      case Z.NOSCRIPT: {
        this.tokenizer.state = Fc.RAWTEXT;
        break;
      }
      case Z.SCRIPT: {
        this.tokenizer.state = Fc.SCRIPT_DATA;
        break;
      }
      case Z.PLAINTEXT: {
        this.tokenizer.state = Fc.PLAINTEXT;
        break;
      }
      default:
    }
  }
  _setDocumentType(t) {
    let n = t.name || "", s = t.publicId || "", c = t.systemId || "";
    if (this.treeAdapter.setDocumentType(this.document, n, s, c), t.location) {
      let d = this.treeAdapter.getChildNodes(this.document).find((m) => this.treeAdapter.isDocumentTypeNode(m));
      d && this.treeAdapter.setNodeSourceCodeLocation(d, t.location);
    }
  }
  _attachElementToTree(t, n) {
    if (this.options.sourceCodeLocationInfo) {
      let s = n && { ...n, startTag: n };
      this.treeAdapter.setNodeSourceCodeLocation(t, s);
    }
    if (this._shouldFosterParentOnInsertion()) this._fosterParentElement(t);
    else {
      let s = this.openElements.currentTmplContentOrNode;
      this.treeAdapter.appendChild(s ?? this.document, t);
    }
  }
  _appendElement(t, n) {
    let s = this.treeAdapter.createElement(t.tagName, n, t.attrs);
    this._attachElementToTree(s, t.location);
  }
  _insertElement(t, n) {
    let s = this.treeAdapter.createElement(t.tagName, n, t.attrs);
    this._attachElementToTree(s, t.location), this.openElements.push(s, t.tagID);
  }
  _insertFakeElement(t, n) {
    let s = this.treeAdapter.createElement(t, G0.HTML, []);
    this._attachElementToTree(s, null), this.openElements.push(s, n);
  }
  _insertTemplate(t) {
    let n = this.treeAdapter.createElement(t.tagName, G0.HTML, t.attrs), s = this.treeAdapter.createDocumentFragment();
    this.treeAdapter.setTemplateContent(n, s), this._attachElementToTree(n, t.location), this.openElements.push(n, t.tagID), this.options.sourceCodeLocationInfo && this.treeAdapter.setNodeSourceCodeLocation(s, null);
  }
  _insertFakeRootElement() {
    let t = this.treeAdapter.createElement(d0.HTML, G0.HTML, []);
    this.options.sourceCodeLocationInfo && this.treeAdapter.setNodeSourceCodeLocation(t, null), this.treeAdapter.appendChild(this.openElements.current, t), this.openElements.push(t, Z.HTML);
  }
  _appendCommentNode(t, n) {
    let s = this.treeAdapter.createCommentNode(t.data);
    this.treeAdapter.appendChild(n, s), this.options.sourceCodeLocationInfo && this.treeAdapter.setNodeSourceCodeLocation(s, t.location);
  }
  _insertCharacters(t) {
    let n, s;
    if (this._shouldFosterParentOnInsertion() ? ({ parent: n, beforeElement: s } = this._findFosterParentingLocation(), s ? this.treeAdapter.insertTextBefore(n, t.chars, s) : this.treeAdapter.insertText(n, t.chars)) : (n = this.openElements.currentTmplContentOrNode, this.treeAdapter.insertText(n, t.chars)), !t.location) return;
    let c = this.treeAdapter.getChildNodes(n), l = s ? c.lastIndexOf(s) : c.length, d = c[l - 1];
    if (this.treeAdapter.getNodeSourceCodeLocation(d)) {
      let { endLine: g, endCol: y, endOffset: v } = t.location;
      this.treeAdapter.updateNodeSourceCodeLocation(d, { endLine: g, endCol: y, endOffset: v });
    } else this.options.sourceCodeLocationInfo && this.treeAdapter.setNodeSourceCodeLocation(d, t.location);
  }
  _adoptNodes(t, n) {
    for (let s = this.treeAdapter.getFirstChild(t); s; s = this.treeAdapter.getFirstChild(t)) this.treeAdapter.detachNode(s), this.treeAdapter.appendChild(n, s);
  }
  _setEndLocation(t, n) {
    if (this.treeAdapter.getNodeSourceCodeLocation(t) && n.location) {
      let s = n.location, c = this.treeAdapter.getTagName(t), l = n.type === ki.END_TAG && c === n.tagName ? { endTag: { ...s }, endLine: s.endLine, endCol: s.endCol, endOffset: s.endOffset } : { endLine: s.startLine, endCol: s.startCol, endOffset: s.startOffset };
      this.treeAdapter.updateNodeSourceCodeLocation(t, l);
    }
  }
  shouldProcessStartTagTokenInForeignContent(t) {
    if (!this.currentNotInHTML) return false;
    let n, s;
    return this.openElements.stackTop === 0 && this.fragmentContext ? (n = this.fragmentContext, s = this.fragmentContextID) : { current: n, currentTagId: s } = this.openElements, t.tagID === Z.SVG && this.treeAdapter.getTagName(n) === d0.ANNOTATION_XML && this.treeAdapter.getNamespaceURI(n) === G0.MATHML ? false : this.tokenizer.inForeignNode || (t.tagID === Z.MGLYPH || t.tagID === Z.MALIGNMARK) && s !== void 0 && !this._isIntegrationPoint(s, n, G0.HTML);
  }
  _processToken(t) {
    switch (t.type) {
      case ki.CHARACTER: {
        this.onCharacter(t);
        break;
      }
      case ki.NULL_CHARACTER: {
        this.onNullCharacter(t);
        break;
      }
      case ki.COMMENT: {
        this.onComment(t);
        break;
      }
      case ki.DOCTYPE: {
        this.onDoctype(t);
        break;
      }
      case ki.START_TAG: {
        this._processStartTag(t);
        break;
      }
      case ki.END_TAG: {
        this.onEndTag(t);
        break;
      }
      case ki.EOF: {
        this.onEof(t);
        break;
      }
      case ki.WHITESPACE_CHARACTER: {
        this.onWhitespaceCharacter(t);
        break;
      }
    }
  }
  _isIntegrationPoint(t, n, s) {
    let c = this.treeAdapter.getNamespaceURI(n), l = this.treeAdapter.getAttrList(n);
    return bx0(t, c, l, s);
  }
  _reconstructActiveFormattingElements() {
    let t = this.activeFormattingElements.entries.length;
    if (t) {
      let n = this.activeFormattingElements.entries.findIndex((c) => c.type === V2.Marker || this.openElements.contains(c.element)), s = n === -1 ? t - 1 : n - 1;
      for (let c = s; c >= 0; c--) {
        let l = this.activeFormattingElements.entries[c];
        this._insertElement(l.token, this.treeAdapter.getNamespaceURI(l.element)), l.element = this.openElements.current;
      }
    }
  }
  _closeTableCell() {
    this.openElements.generateImpliedEndTags(), this.openElements.popUntilTableCellPopped(), this.activeFormattingElements.clearToLastMarker(), this.insertionMode = Ze.IN_ROW;
  }
  _closePElement() {
    this.openElements.generateImpliedEndTagsWithExclusion(Z.P), this.openElements.popUntilTagNamePopped(Z.P);
  }
  _resetInsertionMode() {
    for (let t = this.openElements.stackTop; t >= 0; t--) switch (t === 0 && this.fragmentContext ? this.fragmentContextID : this.openElements.tagIDs[t]) {
      case Z.TR: {
        this.insertionMode = Ze.IN_ROW;
        return;
      }
      case Z.TBODY:
      case Z.THEAD:
      case Z.TFOOT: {
        this.insertionMode = Ze.IN_TABLE_BODY;
        return;
      }
      case Z.CAPTION: {
        this.insertionMode = Ze.IN_CAPTION;
        return;
      }
      case Z.COLGROUP: {
        this.insertionMode = Ze.IN_COLUMN_GROUP;
        return;
      }
      case Z.TABLE: {
        this.insertionMode = Ze.IN_TABLE;
        return;
      }
      case Z.BODY: {
        this.insertionMode = Ze.IN_BODY;
        return;
      }
      case Z.FRAMESET: {
        this.insertionMode = Ze.IN_FRAMESET;
        return;
      }
      case Z.SELECT: {
        this._resetInsertionModeForSelect(t);
        return;
      }
      case Z.TEMPLATE: {
        this.insertionMode = this.tmplInsertionModeStack[0];
        return;
      }
      case Z.HTML: {
        this.insertionMode = this.headElement ? Ze.AFTER_HEAD : Ze.BEFORE_HEAD;
        return;
      }
      case Z.TD:
      case Z.TH: {
        if (t > 0) {
          this.insertionMode = Ze.IN_CELL;
          return;
        }
        break;
      }
      case Z.HEAD: {
        if (t > 0) {
          this.insertionMode = Ze.IN_HEAD;
          return;
        }
        break;
      }
    }
    this.insertionMode = Ze.IN_BODY;
  }
  _resetInsertionModeForSelect(t) {
    if (t > 0) for (let n = t - 1; n > 0; n--) {
      let s = this.openElements.tagIDs[n];
      if (s === Z.TEMPLATE) break;
      if (s === Z.TABLE) {
        this.insertionMode = Ze.IN_SELECT_IN_TABLE;
        return;
      }
    }
    this.insertionMode = Ze.IN_SELECT;
  }
  _isElementCausesFosterParenting(t) {
    return _x0.has(t);
  }
  _shouldFosterParentOnInsertion() {
    return this.fosterParentingEnabled && this.openElements.currentTagId !== void 0 && this._isElementCausesFosterParenting(this.openElements.currentTagId);
  }
  _findFosterParentingLocation() {
    for (let t = this.openElements.stackTop; t >= 0; t--) {
      let n = this.openElements.items[t];
      switch (this.openElements.tagIDs[t]) {
        case Z.TEMPLATE: {
          if (this.treeAdapter.getNamespaceURI(n) === G0.HTML) return { parent: this.treeAdapter.getTemplateContent(n), beforeElement: null };
          break;
        }
        case Z.TABLE: {
          let s = this.treeAdapter.getParentNode(n);
          return s ? { parent: s, beforeElement: n } : { parent: this.openElements.items[t - 1], beforeElement: null };
        }
        default:
      }
    }
    return { parent: this.openElements.items[0], beforeElement: null };
  }
  _fosterParentElement(t) {
    let n = this._findFosterParentingLocation();
    n.beforeElement ? this.treeAdapter.insertBefore(n.parent, t, n.beforeElement) : this.treeAdapter.appendChild(n.parent, t);
  }
  _isSpecialElement(t, n) {
    let s = this.treeAdapter.getNamespaceURI(t);
    return Kde[s].has(n);
  }
  onCharacter(t) {
    if (this.skipNextNewLine = false, this.tokenizer.inForeignNode) {
      RBt(this, t);
      return;
    }
    switch (this.insertionMode) {
      case Ze.INITIAL: {
        mC(this, t);
        break;
      }
      case Ze.BEFORE_HTML: {
        gC(this, t);
        break;
      }
      case Ze.BEFORE_HEAD: {
        bC(this, t);
        break;
      }
      case Ze.IN_HEAD: {
        yC(this, t);
        break;
      }
      case Ze.IN_HEAD_NO_SCRIPT: {
        AC(this, t);
        break;
      }
      case Ze.AFTER_HEAD: {
        kC(this, t);
        break;
      }
      case Ze.IN_BODY:
      case Ze.IN_CAPTION:
      case Ze.IN_CELL:
      case Ze.IN_TEMPLATE: {
        Sx0(this, t);
        break;
      }
      case Ze.TEXT:
      case Ze.IN_SELECT:
      case Ze.IN_SELECT_IN_TABLE: {
        this._insertCharacters(t);
        break;
      }
      case Ze.IN_TABLE:
      case Ze.IN_TABLE_BODY:
      case Ze.IN_ROW: {
        t2e(this, t);
        break;
      }
      case Ze.IN_TABLE_TEXT: {
        Nx0(this, t);
        break;
      }
      case Ze.IN_COLUMN_GROUP: {
        PH(this, t);
        break;
      }
      case Ze.AFTER_BODY: {
        BH(this, t);
        break;
      }
      case Ze.AFTER_AFTER_BODY: {
        DH(this, t);
        break;
      }
      default:
    }
  }
  onNullCharacter(t) {
    if (this.skipNextNewLine = false, this.tokenizer.inForeignNode) {
      IBt(this, t);
      return;
    }
    switch (this.insertionMode) {
      case Ze.INITIAL: {
        mC(this, t);
        break;
      }
      case Ze.BEFORE_HTML: {
        gC(this, t);
        break;
      }
      case Ze.BEFORE_HEAD: {
        bC(this, t);
        break;
      }
      case Ze.IN_HEAD: {
        yC(this, t);
        break;
      }
      case Ze.IN_HEAD_NO_SCRIPT: {
        AC(this, t);
        break;
      }
      case Ze.AFTER_HEAD: {
        kC(this, t);
        break;
      }
      case Ze.TEXT: {
        this._insertCharacters(t);
        break;
      }
      case Ze.IN_TABLE:
      case Ze.IN_TABLE_BODY:
      case Ze.IN_ROW: {
        t2e(this, t);
        break;
      }
      case Ze.IN_COLUMN_GROUP: {
        PH(this, t);
        break;
      }
      case Ze.AFTER_BODY: {
        BH(this, t);
        break;
      }
      case Ze.AFTER_AFTER_BODY: {
        DH(this, t);
        break;
      }
      default:
    }
  }
  onComment(t) {
    if (this.skipNextNewLine = false, this.currentNotInHTML) {
      r2e(this, t);
      return;
    }
    switch (this.insertionMode) {
      case Ze.INITIAL:
      case Ze.BEFORE_HTML:
      case Ze.BEFORE_HEAD:
      case Ze.IN_HEAD:
      case Ze.IN_HEAD_NO_SCRIPT:
      case Ze.AFTER_HEAD:
      case Ze.IN_BODY:
      case Ze.IN_TABLE:
      case Ze.IN_CAPTION:
      case Ze.IN_COLUMN_GROUP:
      case Ze.IN_TABLE_BODY:
      case Ze.IN_ROW:
      case Ze.IN_CELL:
      case Ze.IN_SELECT:
      case Ze.IN_SELECT_IN_TABLE:
      case Ze.IN_TEMPLATE:
      case Ze.IN_FRAMESET:
      case Ze.AFTER_FRAMESET: {
        r2e(this, t);
        break;
      }
      case Ze.IN_TABLE_TEXT: {
        hC(this, t);
        break;
      }
      case Ze.AFTER_BODY: {
        oPt(this, t);
        break;
      }
      case Ze.AFTER_AFTER_BODY:
      case Ze.AFTER_AFTER_FRAMESET: {
        sPt(this, t);
        break;
      }
      default:
    }
  }
  onDoctype(t) {
    switch (this.skipNextNewLine = false, this.insertionMode) {
      case Ze.INITIAL: {
        xPt(this, t);
        break;
      }
      case Ze.BEFORE_HEAD:
      case Ze.IN_HEAD:
      case Ze.IN_HEAD_NO_SCRIPT:
      case Ze.AFTER_HEAD: {
        this._err(t, I0.misplacedDoctype);
        break;
      }
      case Ze.IN_TABLE_TEXT: {
        hC(this, t);
        break;
      }
      default:
    }
  }
  onStartTag(t) {
    this.skipNextNewLine = false, this.currentToken = t, this._processStartTag(t), t.selfClosing && !t.ackSelfClosing && this._err(t, I0.nonVoidHtmlElementStartTagWithTrailingSolidus);
  }
  _processStartTag(t) {
    this.shouldProcessStartTagTokenInForeignContent(t) ? CBt(this, t) : this._startTagOutsideForeignContent(t);
  }
  _startTagOutsideForeignContent(t) {
    switch (this.insertionMode) {
      case Ze.INITIAL: {
        mC(this, t);
        break;
      }
      case Ze.BEFORE_HTML: {
        cPt(this, t);
        break;
      }
      case Ze.BEFORE_HEAD: {
        lPt(this, t);
        break;
      }
      case Ze.IN_HEAD: {
        j2(this, t);
        break;
      }
      case Ze.IN_HEAD_NO_SCRIPT: {
        pPt(this, t);
        break;
      }
      case Ze.AFTER_HEAD: {
        hPt(this, t);
        break;
      }
      case Ze.IN_BODY: {
        Wc(this, t);
        break;
      }
      case Ze.IN_TABLE: {
        i_(this, t);
        break;
      }
      case Ze.IN_TABLE_TEXT: {
        hC(this, t);
        break;
      }
      case Ze.IN_CAPTION: {
        fBt(this, t);
        break;
      }
      case Ze.IN_COLUMN_GROUP: {
        o2e(this, t);
        break;
      }
      case Ze.IN_TABLE_BODY: {
        UH(this, t);
        break;
      }
      case Ze.IN_ROW: {
        $H(this, t);
        break;
      }
      case Ze.IN_CELL: {
        mBt(this, t);
        break;
      }
      case Ze.IN_SELECT: {
        Px0(this, t);
        break;
      }
      case Ze.IN_SELECT_IN_TABLE: {
        gBt(this, t);
        break;
      }
      case Ze.IN_TEMPLATE: {
        yBt(this, t);
        break;
      }
      case Ze.AFTER_BODY: {
        kBt(this, t);
        break;
      }
      case Ze.IN_FRAMESET: {
        vBt(this, t);
        break;
      }
      case Ze.AFTER_FRAMESET: {
        wBt(this, t);
        break;
      }
      case Ze.AFTER_AFTER_BODY: {
        EBt(this, t);
        break;
      }
      case Ze.AFTER_AFTER_FRAMESET: {
        TBt(this, t);
        break;
      }
      default:
    }
  }
  onEndTag(t) {
    this.skipNextNewLine = false, this.currentToken = t, this.currentNotInHTML ? NBt(this, t) : this._endTagOutsideForeignContent(t);
  }
  _endTagOutsideForeignContent(t) {
    switch (this.insertionMode) {
      case Ze.INITIAL: {
        mC(this, t);
        break;
      }
      case Ze.BEFORE_HTML: {
        uPt(this, t);
        break;
      }
      case Ze.BEFORE_HEAD: {
        fPt(this, t);
        break;
      }
      case Ze.IN_HEAD: {
        dPt(this, t);
        break;
      }
      case Ze.IN_HEAD_NO_SCRIPT: {
        mPt(this, t);
        break;
      }
      case Ze.AFTER_HEAD: {
        gPt(this, t);
        break;
      }
      case Ze.IN_BODY: {
        MH(this, t);
        break;
      }
      case Ze.TEXT: {
        rBt(this, t);
        break;
      }
      case Ze.IN_TABLE: {
        vC(this, t);
        break;
      }
      case Ze.IN_TABLE_TEXT: {
        hC(this, t);
        break;
      }
      case Ze.IN_CAPTION: {
        dBt(this, t);
        break;
      }
      case Ze.IN_COLUMN_GROUP: {
        pBt(this, t);
        break;
      }
      case Ze.IN_TABLE_BODY: {
        n2e(this, t);
        break;
      }
      case Ze.IN_ROW: {
        Dx0(this, t);
        break;
      }
      case Ze.IN_CELL: {
        hBt(this, t);
        break;
      }
      case Ze.IN_SELECT: {
        Bx0(this, t);
        break;
      }
      case Ze.IN_SELECT_IN_TABLE: {
        bBt(this, t);
        break;
      }
      case Ze.IN_TEMPLATE: {
        ABt(this, t);
        break;
      }
      case Ze.AFTER_BODY: {
        Mx0(this, t);
        break;
      }
      case Ze.IN_FRAMESET: {
        _Bt(this, t);
        break;
      }
      case Ze.AFTER_FRAMESET: {
        SBt(this, t);
        break;
      }
      case Ze.AFTER_AFTER_BODY: {
        DH(this, t);
        break;
      }
      default:
    }
  }
  onEof(t) {
    switch (this.insertionMode) {
      case Ze.INITIAL: {
        mC(this, t);
        break;
      }
      case Ze.BEFORE_HTML: {
        gC(this, t);
        break;
      }
      case Ze.BEFORE_HEAD: {
        bC(this, t);
        break;
      }
      case Ze.IN_HEAD: {
        yC(this, t);
        break;
      }
      case Ze.IN_HEAD_NO_SCRIPT: {
        AC(this, t);
        break;
      }
      case Ze.AFTER_HEAD: {
        kC(this, t);
        break;
      }
      case Ze.IN_BODY:
      case Ze.IN_TABLE:
      case Ze.IN_CAPTION:
      case Ze.IN_COLUMN_GROUP:
      case Ze.IN_TABLE_BODY:
      case Ze.IN_ROW:
      case Ze.IN_CELL:
      case Ze.IN_SELECT:
      case Ze.IN_SELECT_IN_TABLE: {
        Rx0(this, t);
        break;
      }
      case Ze.TEXT: {
        nBt(this, t);
        break;
      }
      case Ze.IN_TABLE_TEXT: {
        hC(this, t);
        break;
      }
      case Ze.IN_TEMPLATE: {
        Lx0(this, t);
        break;
      }
      case Ze.AFTER_BODY:
      case Ze.IN_FRAMESET:
      case Ze.AFTER_FRAMESET:
      case Ze.AFTER_AFTER_BODY:
      case Ze.AFTER_AFTER_FRAMESET: {
        a2e(this, t);
        break;
      }
      default:
    }
  }
  onWhitespaceCharacter(t) {
    if (this.skipNextNewLine && (this.skipNextNewLine = false, t.chars.charCodeAt(0) === Ne.LINE_FEED)) {
      if (t.chars.length === 1) return;
      t.chars = t.chars.substr(1);
    }
    if (this.tokenizer.inForeignNode) {
      this._insertCharacters(t);
      return;
    }
    switch (this.insertionMode) {
      case Ze.IN_HEAD:
      case Ze.IN_HEAD_NO_SCRIPT:
      case Ze.AFTER_HEAD:
      case Ze.TEXT:
      case Ze.IN_COLUMN_GROUP:
      case Ze.IN_SELECT:
      case Ze.IN_SELECT_IN_TABLE:
      case Ze.IN_FRAMESET:
      case Ze.AFTER_FRAMESET: {
        this._insertCharacters(t);
        break;
      }
      case Ze.IN_BODY:
      case Ze.IN_CAPTION:
      case Ze.IN_CELL:
      case Ze.IN_TEMPLATE:
      case Ze.AFTER_BODY:
      case Ze.AFTER_AFTER_BODY:
      case Ze.AFTER_AFTER_FRAMESET: {
        wx0(this, t);
        break;
      }
      case Ze.IN_TABLE:
      case Ze.IN_TABLE_BODY:
      case Ze.IN_ROW: {
        t2e(this, t);
        break;
      }
      case Ze.IN_TABLE_TEXT: {
        Cx0(this, t);
        break;
      }
      default:
    }
  }
};
function ePt(e9, t) {
  let n = e9.activeFormattingElements.getElementEntryInScopeWithTagName(t.tagName);
  return n ? e9.openElements.contains(n.element) ? e9.openElements.hasInScope(t.tagID) || (n = null) : (e9.activeFormattingElements.removeEntry(n), n = null) : Ix0(e9, t), n;
}
function tPt(e9, t) {
  let n = null, s = e9.openElements.stackTop;
  for (; s >= 0; s--) {
    let c = e9.openElements.items[s];
    if (c === t.element) break;
    e9._isSpecialElement(c, e9.openElements.tagIDs[s]) && (n = c);
  }
  return n || (e9.openElements.shortenToLength(Math.max(s, 0)), e9.activeFormattingElements.removeEntry(t)), n;
}
function rPt(e9, t, n) {
  let s = t, c = e9.openElements.getCommonAncestor(t);
  for (let l = 0, d = c; d !== n; l++, d = c) {
    c = e9.openElements.getCommonAncestor(d);
    let m = e9.activeFormattingElements.getElementEntry(d), g = m && l >= JDt;
    !m || g ? (g && e9.activeFormattingElements.removeEntry(m), e9.openElements.remove(d)) : (d = nPt(e9, m), s === t && (e9.activeFormattingElements.bookmark = m), e9.treeAdapter.detachNode(s), e9.treeAdapter.appendChild(d, s), s = d);
  }
  return s;
}
function nPt(e9, t) {
  let n = e9.treeAdapter.getNamespaceURI(t.element), s = e9.treeAdapter.createElement(t.token.tagName, n, t.token.attrs);
  return e9.openElements.replace(t.element, s), t.element = s, s;
}
function iPt(e9, t, n) {
  let s = e9.treeAdapter.getTagName(t), c = a7(s);
  if (e9._isElementCausesFosterParenting(c)) e9._fosterParentElement(n);
  else {
    let l = e9.treeAdapter.getNamespaceURI(t);
    c === Z.TEMPLATE && l === G0.HTML && (t = e9.treeAdapter.getTemplateContent(t)), e9.treeAdapter.appendChild(t, n);
  }
}
function aPt(e9, t, n) {
  let s = e9.treeAdapter.getNamespaceURI(n.element), { token: c } = n, l = e9.treeAdapter.createElement(c.tagName, s, c.attrs);
  e9._adoptNodes(t, l), e9.treeAdapter.appendChild(t, l), e9.activeFormattingElements.insertElementAfterBookmark(l, c), e9.activeFormattingElements.removeEntry(n), e9.openElements.remove(n.element), e9.openElements.insertAfter(t, l, c.tagID);
}
function i2e(e9, t) {
  for (let n = 0; n < KDt; n++) {
    let s = ePt(e9, t);
    if (!s) break;
    let c = tPt(e9, s);
    if (!c) break;
    e9.activeFormattingElements.bookmark = s;
    let l = rPt(e9, c, s.element), d = e9.openElements.getCommonAncestor(s.element);
    e9.treeAdapter.detachNode(l), d && iPt(e9, d, l), aPt(e9, c, s);
  }
}
function r2e(e9, t) {
  e9._appendCommentNode(t, e9.openElements.currentTmplContentOrNode);
}
function oPt(e9, t) {
  e9._appendCommentNode(t, e9.openElements.items[0]);
}
function sPt(e9, t) {
  e9._appendCommentNode(t, e9.document);
}
function a2e(e9, t) {
  if (e9.stopped = true, t.location) {
    let n = e9.fragmentContext ? 0 : 2;
    for (let s = e9.openElements.stackTop; s >= n; s--) e9._setEndLocation(e9.openElements.items[s], t);
    if (!e9.fragmentContext && e9.openElements.stackTop >= 0) {
      let s = e9.openElements.items[0], c = e9.treeAdapter.getNodeSourceCodeLocation(s);
      if (c && !c.endTag && (e9._setEndLocation(s, t), e9.openElements.stackTop >= 1)) {
        let l = e9.openElements.items[1], d = e9.treeAdapter.getNodeSourceCodeLocation(l);
        d && !d.endTag && e9._setEndLocation(l, t);
      }
    }
  }
}
function xPt(e9, t) {
  e9._setDocumentType(t);
  let n = t.forceQuirks ? $c.QUIRKS : px0(t);
  dx0(t) || e9._err(t, I0.nonConformingDoctype), e9.treeAdapter.setDocumentMode(e9.document, n), e9.insertionMode = Ze.BEFORE_HTML;
}
function mC(e9, t) {
  e9._err(t, I0.missingDoctype, true), e9.treeAdapter.setDocumentMode(e9.document, $c.QUIRKS), e9.insertionMode = Ze.BEFORE_HTML, e9._processToken(t);
}
function cPt(e9, t) {
  t.tagID === Z.HTML ? (e9._insertElement(t, G0.HTML), e9.insertionMode = Ze.BEFORE_HEAD) : gC(e9, t);
}
function uPt(e9, t) {
  let n = t.tagID;
  (n === Z.HTML || n === Z.HEAD || n === Z.BODY || n === Z.BR) && gC(e9, t);
}
function gC(e9, t) {
  e9._insertFakeRootElement(), e9.insertionMode = Ze.BEFORE_HEAD, e9._processToken(t);
}
function lPt(e9, t) {
  switch (t.tagID) {
    case Z.HTML: {
      Wc(e9, t);
      break;
    }
    case Z.HEAD: {
      e9._insertElement(t, G0.HTML), e9.headElement = e9.openElements.current, e9.insertionMode = Ze.IN_HEAD;
      break;
    }
    default:
      bC(e9, t);
  }
}
function fPt(e9, t) {
  let n = t.tagID;
  n === Z.HEAD || n === Z.BODY || n === Z.HTML || n === Z.BR ? bC(e9, t) : e9._err(t, I0.endTagWithoutMatchingOpenElement);
}
function bC(e9, t) {
  e9._insertFakeElement(d0.HEAD, Z.HEAD), e9.headElement = e9.openElements.current, e9.insertionMode = Ze.IN_HEAD, e9._processToken(t);
}
function j2(e9, t) {
  switch (t.tagID) {
    case Z.HTML: {
      Wc(e9, t);
      break;
    }
    case Z.BASE:
    case Z.BASEFONT:
    case Z.BGSOUND:
    case Z.LINK:
    case Z.META: {
      e9._appendElement(t, G0.HTML), t.ackSelfClosing = true;
      break;
    }
    case Z.TITLE: {
      e9._switchToTextParsing(t, Fc.RCDATA);
      break;
    }
    case Z.NOSCRIPT: {
      e9.options.scriptingEnabled ? e9._switchToTextParsing(t, Fc.RAWTEXT) : (e9._insertElement(t, G0.HTML), e9.insertionMode = Ze.IN_HEAD_NO_SCRIPT);
      break;
    }
    case Z.NOFRAMES:
    case Z.STYLE: {
      e9._switchToTextParsing(t, Fc.RAWTEXT);
      break;
    }
    case Z.SCRIPT: {
      e9._switchToTextParsing(t, Fc.SCRIPT_DATA);
      break;
    }
    case Z.TEMPLATE: {
      e9._insertTemplate(t), e9.activeFormattingElements.insertMarker(), e9.framesetOk = false, e9.insertionMode = Ze.IN_TEMPLATE, e9.tmplInsertionModeStack.unshift(Ze.IN_TEMPLATE);
      break;
    }
    case Z.HEAD: {
      e9._err(t, I0.misplacedStartTagForHeadElement);
      break;
    }
    default:
      yC(e9, t);
  }
}
function dPt(e9, t) {
  switch (t.tagID) {
    case Z.HEAD: {
      e9.openElements.pop(), e9.insertionMode = Ze.AFTER_HEAD;
      break;
    }
    case Z.BODY:
    case Z.BR:
    case Z.HTML: {
      yC(e9, t);
      break;
    }
    case Z.TEMPLATE: {
      Py(e9, t);
      break;
    }
    default:
      e9._err(t, I0.endTagWithoutMatchingOpenElement);
  }
}
function Py(e9, t) {
  e9.openElements.tmplCount > 0 ? (e9.openElements.generateImpliedEndTagsThoroughly(), e9.openElements.currentTagId !== Z.TEMPLATE && e9._err(t, I0.closingOfElementWithOpenChildElements), e9.openElements.popUntilTagNamePopped(Z.TEMPLATE), e9.activeFormattingElements.clearToLastMarker(), e9.tmplInsertionModeStack.shift(), e9._resetInsertionMode()) : e9._err(t, I0.endTagWithoutMatchingOpenElement);
}
function yC(e9, t) {
  e9.openElements.pop(), e9.insertionMode = Ze.AFTER_HEAD, e9._processToken(t);
}
function pPt(e9, t) {
  switch (t.tagID) {
    case Z.HTML: {
      Wc(e9, t);
      break;
    }
    case Z.BASEFONT:
    case Z.BGSOUND:
    case Z.HEAD:
    case Z.LINK:
    case Z.META:
    case Z.NOFRAMES:
    case Z.STYLE: {
      j2(e9, t);
      break;
    }
    case Z.NOSCRIPT: {
      e9._err(t, I0.nestedNoscriptInHead);
      break;
    }
    default:
      AC(e9, t);
  }
}
function mPt(e9, t) {
  switch (t.tagID) {
    case Z.NOSCRIPT: {
      e9.openElements.pop(), e9.insertionMode = Ze.IN_HEAD;
      break;
    }
    case Z.BR: {
      AC(e9, t);
      break;
    }
    default:
      e9._err(t, I0.endTagWithoutMatchingOpenElement);
  }
}
function AC(e9, t) {
  let n = t.type === ki.EOF ? I0.openElementsLeftAfterEof : I0.disallowedContentInNoscriptInHead;
  e9._err(t, n), e9.openElements.pop(), e9.insertionMode = Ze.IN_HEAD, e9._processToken(t);
}
function hPt(e9, t) {
  switch (t.tagID) {
    case Z.HTML: {
      Wc(e9, t);
      break;
    }
    case Z.BODY: {
      e9._insertElement(t, G0.HTML), e9.framesetOk = false, e9.insertionMode = Ze.IN_BODY;
      break;
    }
    case Z.FRAMESET: {
      e9._insertElement(t, G0.HTML), e9.insertionMode = Ze.IN_FRAMESET;
      break;
    }
    case Z.BASE:
    case Z.BASEFONT:
    case Z.BGSOUND:
    case Z.LINK:
    case Z.META:
    case Z.NOFRAMES:
    case Z.SCRIPT:
    case Z.STYLE:
    case Z.TEMPLATE:
    case Z.TITLE: {
      e9._err(t, I0.abandonedHeadElementChild), e9.openElements.push(e9.headElement, Z.HEAD), j2(e9, t), e9.openElements.remove(e9.headElement);
      break;
    }
    case Z.HEAD: {
      e9._err(t, I0.misplacedStartTagForHeadElement);
      break;
    }
    default:
      kC(e9, t);
  }
}
function gPt(e9, t) {
  switch (t.tagID) {
    case Z.BODY:
    case Z.HTML:
    case Z.BR: {
      kC(e9, t);
      break;
    }
    case Z.TEMPLATE: {
      Py(e9, t);
      break;
    }
    default:
      e9._err(t, I0.endTagWithoutMatchingOpenElement);
  }
}
function kC(e9, t) {
  e9._insertFakeElement(d0.BODY, Z.BODY), e9.insertionMode = Ze.IN_BODY, LH(e9, t);
}
function LH(e9, t) {
  switch (t.type) {
    case ki.CHARACTER: {
      Sx0(e9, t);
      break;
    }
    case ki.WHITESPACE_CHARACTER: {
      wx0(e9, t);
      break;
    }
    case ki.COMMENT: {
      r2e(e9, t);
      break;
    }
    case ki.START_TAG: {
      Wc(e9, t);
      break;
    }
    case ki.END_TAG: {
      MH(e9, t);
      break;
    }
    case ki.EOF: {
      Rx0(e9, t);
      break;
    }
    default:
  }
}
function wx0(e9, t) {
  e9._reconstructActiveFormattingElements(), e9._insertCharacters(t);
}
function Sx0(e9, t) {
  e9._reconstructActiveFormattingElements(), e9._insertCharacters(t), e9.framesetOk = false;
}
function bPt(e9, t) {
  e9.openElements.tmplCount === 0 && e9.treeAdapter.adoptAttributes(e9.openElements.items[0], t.attrs);
}
function yPt(e9, t) {
  let n = e9.openElements.tryPeekProperlyNestedBodyElement();
  n && e9.openElements.tmplCount === 0 && (e9.framesetOk = false, e9.treeAdapter.adoptAttributes(n, t.attrs));
}
function APt(e9, t) {
  let n = e9.openElements.tryPeekProperlyNestedBodyElement();
  e9.framesetOk && n && (e9.treeAdapter.detachNode(n), e9.openElements.popAllUpToHtmlElement(), e9._insertElement(t, G0.HTML), e9.insertionMode = Ze.IN_FRAMESET);
}
function kPt(e9, t) {
  e9.openElements.hasInButtonScope(Z.P) && e9._closePElement(), e9._insertElement(t, G0.HTML);
}
function vPt(e9, t) {
  e9.openElements.hasInButtonScope(Z.P) && e9._closePElement(), e9.openElements.currentTagId !== void 0 && r_.has(e9.openElements.currentTagId) && e9.openElements.pop(), e9._insertElement(t, G0.HTML);
}
function _Pt(e9, t) {
  e9.openElements.hasInButtonScope(Z.P) && e9._closePElement(), e9._insertElement(t, G0.HTML), e9.skipNextNewLine = true, e9.framesetOk = false;
}
function wPt(e9, t) {
  let n = e9.openElements.tmplCount > 0;
  (!e9.formElement || n) && (e9.openElements.hasInButtonScope(Z.P) && e9._closePElement(), e9._insertElement(t, G0.HTML), n || (e9.formElement = e9.openElements.current));
}
function SPt(e9, t) {
  e9.framesetOk = false;
  let n = t.tagID;
  for (let s = e9.openElements.stackTop; s >= 0; s--) {
    let c = e9.openElements.tagIDs[s];
    if (n === Z.LI && c === Z.LI || (n === Z.DD || n === Z.DT) && (c === Z.DD || c === Z.DT)) {
      e9.openElements.generateImpliedEndTagsWithExclusion(c), e9.openElements.popUntilTagNamePopped(c);
      break;
    }
    if (c !== Z.ADDRESS && c !== Z.DIV && c !== Z.P && e9._isSpecialElement(e9.openElements.items[s], c)) break;
  }
  e9.openElements.hasInButtonScope(Z.P) && e9._closePElement(), e9._insertElement(t, G0.HTML);
}
function EPt(e9, t) {
  e9.openElements.hasInButtonScope(Z.P) && e9._closePElement(), e9._insertElement(t, G0.HTML), e9.tokenizer.state = Fc.PLAINTEXT;
}
function TPt(e9, t) {
  e9.openElements.hasInScope(Z.BUTTON) && (e9.openElements.generateImpliedEndTags(), e9.openElements.popUntilTagNamePopped(Z.BUTTON)), e9._reconstructActiveFormattingElements(), e9._insertElement(t, G0.HTML), e9.framesetOk = false;
}
function IPt(e9, t) {
  let n = e9.activeFormattingElements.getElementEntryInScopeWithTagName(d0.A);
  n && (i2e(e9, t), e9.openElements.remove(n.element), e9.activeFormattingElements.removeEntry(n)), e9._reconstructActiveFormattingElements(), e9._insertElement(t, G0.HTML), e9.activeFormattingElements.pushElement(e9.openElements.current, t);
}
function RPt(e9, t) {
  e9._reconstructActiveFormattingElements(), e9._insertElement(t, G0.HTML), e9.activeFormattingElements.pushElement(e9.openElements.current, t);
}
function CPt(e9, t) {
  e9._reconstructActiveFormattingElements(), e9.openElements.hasInScope(Z.NOBR) && (i2e(e9, t), e9._reconstructActiveFormattingElements()), e9._insertElement(t, G0.HTML), e9.activeFormattingElements.pushElement(e9.openElements.current, t);
}
function NPt(e9, t) {
  e9._reconstructActiveFormattingElements(), e9._insertElement(t, G0.HTML), e9.activeFormattingElements.insertMarker(), e9.framesetOk = false;
}
function OPt(e9, t) {
  e9.treeAdapter.getDocumentMode(e9.document) !== $c.QUIRKS && e9.openElements.hasInButtonScope(Z.P) && e9._closePElement(), e9._insertElement(t, G0.HTML), e9.framesetOk = false, e9.insertionMode = Ze.IN_TABLE;
}
function Ex0(e9, t) {
  e9._reconstructActiveFormattingElements(), e9._appendElement(t, G0.HTML), e9.framesetOk = false, t.ackSelfClosing = true;
}
function Tx0(e9) {
  let t = wH(e9, S1.TYPE);
  return t != null && t.toLowerCase() === ZDt;
}
function DPt(e9, t) {
  e9._reconstructActiveFormattingElements(), e9._appendElement(t, G0.HTML), Tx0(t) || (e9.framesetOk = false), t.ackSelfClosing = true;
}
function PPt(e9, t) {
  e9._appendElement(t, G0.HTML), t.ackSelfClosing = true;
}
function BPt(e9, t) {
  e9.openElements.hasInButtonScope(Z.P) && e9._closePElement(), e9._appendElement(t, G0.HTML), e9.framesetOk = false, t.ackSelfClosing = true;
}
function LPt(e9, t) {
  t.tagName = d0.IMG, t.tagID = Z.IMG, Ex0(e9, t);
}
function MPt(e9, t) {
  e9._insertElement(t, G0.HTML), e9.skipNextNewLine = true, e9.tokenizer.state = Fc.RCDATA, e9.originalInsertionMode = e9.insertionMode, e9.framesetOk = false, e9.insertionMode = Ze.TEXT;
}
function UPt(e9, t) {
  e9.openElements.hasInButtonScope(Z.P) && e9._closePElement(), e9._reconstructActiveFormattingElements(), e9.framesetOk = false, e9._switchToTextParsing(t, Fc.RAWTEXT);
}
function $Pt(e9, t) {
  e9.framesetOk = false, e9._switchToTextParsing(t, Fc.RAWTEXT);
}
function kx0(e9, t) {
  e9._switchToTextParsing(t, Fc.RAWTEXT);
}
function FPt(e9, t) {
  e9._reconstructActiveFormattingElements(), e9._insertElement(t, G0.HTML), e9.framesetOk = false, e9.insertionMode = e9.insertionMode === Ze.IN_TABLE || e9.insertionMode === Ze.IN_CAPTION || e9.insertionMode === Ze.IN_TABLE_BODY || e9.insertionMode === Ze.IN_ROW || e9.insertionMode === Ze.IN_CELL ? Ze.IN_SELECT_IN_TABLE : Ze.IN_SELECT;
}
function WPt(e9, t) {
  e9.openElements.currentTagId === Z.OPTION && e9.openElements.pop(), e9._reconstructActiveFormattingElements(), e9._insertElement(t, G0.HTML);
}
function VPt(e9, t) {
  e9.openElements.hasInScope(Z.RUBY) && e9.openElements.generateImpliedEndTags(), e9._insertElement(t, G0.HTML);
}
function jPt(e9, t) {
  e9.openElements.hasInScope(Z.RUBY) && e9.openElements.generateImpliedEndTagsWithExclusion(Z.RTC), e9._insertElement(t, G0.HTML);
}
function GPt(e9, t) {
  e9._reconstructActiveFormattingElements(), Xde(t), OH(t), t.selfClosing ? e9._appendElement(t, G0.MATHML) : e9._insertElement(t, G0.MATHML), t.ackSelfClosing = true;
}
function HPt(e9, t) {
  e9._reconstructActiveFormattingElements(), e2e(t), OH(t), t.selfClosing ? e9._appendElement(t, G0.SVG) : e9._insertElement(t, G0.SVG), t.ackSelfClosing = true;
}
function vx0(e9, t) {
  e9._reconstructActiveFormattingElements(), e9._insertElement(t, G0.HTML);
}
function Wc(e9, t) {
  switch (t.tagID) {
    case Z.I:
    case Z.S:
    case Z.B:
    case Z.U:
    case Z.EM:
    case Z.TT:
    case Z.BIG:
    case Z.CODE:
    case Z.FONT:
    case Z.SMALL:
    case Z.STRIKE:
    case Z.STRONG: {
      RPt(e9, t);
      break;
    }
    case Z.A: {
      IPt(e9, t);
      break;
    }
    case Z.H1:
    case Z.H2:
    case Z.H3:
    case Z.H4:
    case Z.H5:
    case Z.H6: {
      vPt(e9, t);
      break;
    }
    case Z.P:
    case Z.DL:
    case Z.OL:
    case Z.UL:
    case Z.DIV:
    case Z.DIR:
    case Z.NAV:
    case Z.MAIN:
    case Z.MENU:
    case Z.ASIDE:
    case Z.CENTER:
    case Z.FIGURE:
    case Z.FOOTER:
    case Z.HEADER:
    case Z.HGROUP:
    case Z.DIALOG:
    case Z.DETAILS:
    case Z.ADDRESS:
    case Z.ARTICLE:
    case Z.SEARCH:
    case Z.SECTION:
    case Z.SUMMARY:
    case Z.FIELDSET:
    case Z.BLOCKQUOTE:
    case Z.FIGCAPTION: {
      kPt(e9, t);
      break;
    }
    case Z.LI:
    case Z.DD:
    case Z.DT: {
      SPt(e9, t);
      break;
    }
    case Z.BR:
    case Z.IMG:
    case Z.WBR:
    case Z.AREA:
    case Z.EMBED:
    case Z.KEYGEN: {
      Ex0(e9, t);
      break;
    }
    case Z.HR: {
      BPt(e9, t);
      break;
    }
    case Z.RB:
    case Z.RTC: {
      VPt(e9, t);
      break;
    }
    case Z.RT:
    case Z.RP: {
      jPt(e9, t);
      break;
    }
    case Z.PRE:
    case Z.LISTING: {
      _Pt(e9, t);
      break;
    }
    case Z.XMP: {
      UPt(e9, t);
      break;
    }
    case Z.SVG: {
      HPt(e9, t);
      break;
    }
    case Z.HTML: {
      bPt(e9, t);
      break;
    }
    case Z.BASE:
    case Z.LINK:
    case Z.META:
    case Z.STYLE:
    case Z.TITLE:
    case Z.SCRIPT:
    case Z.BGSOUND:
    case Z.BASEFONT:
    case Z.TEMPLATE: {
      j2(e9, t);
      break;
    }
    case Z.BODY: {
      yPt(e9, t);
      break;
    }
    case Z.FORM: {
      wPt(e9, t);
      break;
    }
    case Z.NOBR: {
      CPt(e9, t);
      break;
    }
    case Z.MATH: {
      GPt(e9, t);
      break;
    }
    case Z.TABLE: {
      OPt(e9, t);
      break;
    }
    case Z.INPUT: {
      DPt(e9, t);
      break;
    }
    case Z.PARAM:
    case Z.TRACK:
    case Z.SOURCE: {
      PPt(e9, t);
      break;
    }
    case Z.IMAGE: {
      LPt(e9, t);
      break;
    }
    case Z.BUTTON: {
      TPt(e9, t);
      break;
    }
    case Z.APPLET:
    case Z.OBJECT:
    case Z.MARQUEE: {
      NPt(e9, t);
      break;
    }
    case Z.IFRAME: {
      $Pt(e9, t);
      break;
    }
    case Z.SELECT: {
      FPt(e9, t);
      break;
    }
    case Z.OPTION:
    case Z.OPTGROUP: {
      WPt(e9, t);
      break;
    }
    case Z.NOEMBED:
    case Z.NOFRAMES: {
      kx0(e9, t);
      break;
    }
    case Z.FRAMESET: {
      APt(e9, t);
      break;
    }
    case Z.TEXTAREA: {
      MPt(e9, t);
      break;
    }
    case Z.NOSCRIPT: {
      e9.options.scriptingEnabled ? kx0(e9, t) : vx0(e9, t);
      break;
    }
    case Z.PLAINTEXT: {
      EPt(e9, t);
      break;
    }
    case Z.COL:
    case Z.TH:
    case Z.TD:
    case Z.TR:
    case Z.HEAD:
    case Z.FRAME:
    case Z.TBODY:
    case Z.TFOOT:
    case Z.THEAD:
    case Z.CAPTION:
    case Z.COLGROUP:
      break;
    default:
      vx0(e9, t);
  }
}
function qPt(e9, t) {
  if (e9.openElements.hasInScope(Z.BODY) && (e9.insertionMode = Ze.AFTER_BODY, e9.options.sourceCodeLocationInfo)) {
    let n = e9.openElements.tryPeekProperlyNestedBodyElement();
    n && e9._setEndLocation(n, t);
  }
}
function zPt(e9, t) {
  e9.openElements.hasInScope(Z.BODY) && (e9.insertionMode = Ze.AFTER_BODY, Mx0(e9, t));
}
function YPt(e9, t) {
  let n = t.tagID;
  e9.openElements.hasInScope(n) && (e9.openElements.generateImpliedEndTags(), e9.openElements.popUntilTagNamePopped(n));
}
function QPt(e9) {
  let t = e9.openElements.tmplCount > 0, { formElement: n } = e9;
  t || (e9.formElement = null), (n || t) && e9.openElements.hasInScope(Z.FORM) && (e9.openElements.generateImpliedEndTags(), t ? e9.openElements.popUntilTagNamePopped(Z.FORM) : n && e9.openElements.remove(n));
}
function ZPt(e9) {
  e9.openElements.hasInButtonScope(Z.P) || e9._insertFakeElement(d0.P, Z.P), e9._closePElement();
}
function KPt(e9) {
  e9.openElements.hasInListItemScope(Z.LI) && (e9.openElements.generateImpliedEndTagsWithExclusion(Z.LI), e9.openElements.popUntilTagNamePopped(Z.LI));
}
function JPt(e9, t) {
  let n = t.tagID;
  e9.openElements.hasInScope(n) && (e9.openElements.generateImpliedEndTagsWithExclusion(n), e9.openElements.popUntilTagNamePopped(n));
}
function XPt(e9) {
  e9.openElements.hasNumberedHeaderInScope() && (e9.openElements.generateImpliedEndTags(), e9.openElements.popUntilNumberedHeaderPopped());
}
function eBt(e9, t) {
  let n = t.tagID;
  e9.openElements.hasInScope(n) && (e9.openElements.generateImpliedEndTags(), e9.openElements.popUntilTagNamePopped(n), e9.activeFormattingElements.clearToLastMarker());
}
function tBt(e9) {
  e9._reconstructActiveFormattingElements(), e9._insertFakeElement(d0.BR, Z.BR), e9.openElements.pop(), e9.framesetOk = false;
}
function Ix0(e9, t) {
  let n = t.tagName, s = t.tagID;
  for (let c = e9.openElements.stackTop; c > 0; c--) {
    let l = e9.openElements.items[c], d = e9.openElements.tagIDs[c];
    if (s === d && (s !== Z.UNKNOWN || e9.treeAdapter.getTagName(l) === n)) {
      e9.openElements.generateImpliedEndTagsWithExclusion(s), e9.openElements.stackTop >= c && e9.openElements.shortenToLength(c);
      break;
    }
    if (e9._isSpecialElement(l, d)) break;
  }
}
function MH(e9, t) {
  switch (t.tagID) {
    case Z.A:
    case Z.B:
    case Z.I:
    case Z.S:
    case Z.U:
    case Z.EM:
    case Z.TT:
    case Z.BIG:
    case Z.CODE:
    case Z.FONT:
    case Z.NOBR:
    case Z.SMALL:
    case Z.STRIKE:
    case Z.STRONG: {
      i2e(e9, t);
      break;
    }
    case Z.P: {
      ZPt(e9);
      break;
    }
    case Z.DL:
    case Z.UL:
    case Z.OL:
    case Z.DIR:
    case Z.DIV:
    case Z.NAV:
    case Z.PRE:
    case Z.MAIN:
    case Z.MENU:
    case Z.ASIDE:
    case Z.BUTTON:
    case Z.CENTER:
    case Z.FIGURE:
    case Z.FOOTER:
    case Z.HEADER:
    case Z.HGROUP:
    case Z.DIALOG:
    case Z.ADDRESS:
    case Z.ARTICLE:
    case Z.DETAILS:
    case Z.SEARCH:
    case Z.SECTION:
    case Z.SUMMARY:
    case Z.LISTING:
    case Z.FIELDSET:
    case Z.BLOCKQUOTE:
    case Z.FIGCAPTION: {
      YPt(e9, t);
      break;
    }
    case Z.LI: {
      KPt(e9);
      break;
    }
    case Z.DD:
    case Z.DT: {
      JPt(e9, t);
      break;
    }
    case Z.H1:
    case Z.H2:
    case Z.H3:
    case Z.H4:
    case Z.H5:
    case Z.H6: {
      XPt(e9);
      break;
    }
    case Z.BR: {
      tBt(e9);
      break;
    }
    case Z.BODY: {
      qPt(e9, t);
      break;
    }
    case Z.HTML: {
      zPt(e9, t);
      break;
    }
    case Z.FORM: {
      QPt(e9);
      break;
    }
    case Z.APPLET:
    case Z.OBJECT:
    case Z.MARQUEE: {
      eBt(e9, t);
      break;
    }
    case Z.TEMPLATE: {
      Py(e9, t);
      break;
    }
    default:
      Ix0(e9, t);
  }
}
function Rx0(e9, t) {
  e9.tmplInsertionModeStack.length > 0 ? Lx0(e9, t) : a2e(e9, t);
}
function rBt(e9, t) {
  var n;
  t.tagID === Z.SCRIPT && ((n = e9.scriptHandler) === null || n === void 0 || n.call(e9, e9.openElements.current)), e9.openElements.pop(), e9.insertionMode = e9.originalInsertionMode;
}
function nBt(e9, t) {
  e9._err(t, I0.eofInElementThatCanContainOnlyText), e9.openElements.pop(), e9.insertionMode = e9.originalInsertionMode, e9.onEof(t);
}
function t2e(e9, t) {
  if (e9.openElements.currentTagId !== void 0 && _x0.has(e9.openElements.currentTagId)) switch (e9.pendingCharacterTokens.length = 0, e9.hasNonWhitespacePendingCharacterToken = false, e9.originalInsertionMode = e9.insertionMode, e9.insertionMode = Ze.IN_TABLE_TEXT, t.type) {
    case ki.CHARACTER: {
      Nx0(e9, t);
      break;
    }
    case ki.WHITESPACE_CHARACTER: {
      Cx0(e9, t);
      break;
    }
  }
  else _C(e9, t);
}
function iBt(e9, t) {
  e9.openElements.clearBackToTableContext(), e9.activeFormattingElements.insertMarker(), e9._insertElement(t, G0.HTML), e9.insertionMode = Ze.IN_CAPTION;
}
function aBt(e9, t) {
  e9.openElements.clearBackToTableContext(), e9._insertElement(t, G0.HTML), e9.insertionMode = Ze.IN_COLUMN_GROUP;
}
function oBt(e9, t) {
  e9.openElements.clearBackToTableContext(), e9._insertFakeElement(d0.COLGROUP, Z.COLGROUP), e9.insertionMode = Ze.IN_COLUMN_GROUP, o2e(e9, t);
}
function sBt(e9, t) {
  e9.openElements.clearBackToTableContext(), e9._insertElement(t, G0.HTML), e9.insertionMode = Ze.IN_TABLE_BODY;
}
function xBt(e9, t) {
  e9.openElements.clearBackToTableContext(), e9._insertFakeElement(d0.TBODY, Z.TBODY), e9.insertionMode = Ze.IN_TABLE_BODY, UH(e9, t);
}
function cBt(e9, t) {
  e9.openElements.hasInTableScope(Z.TABLE) && (e9.openElements.popUntilTagNamePopped(Z.TABLE), e9._resetInsertionMode(), e9._processStartTag(t));
}
function uBt(e9, t) {
  Tx0(t) ? e9._appendElement(t, G0.HTML) : _C(e9, t), t.ackSelfClosing = true;
}
function lBt(e9, t) {
  !e9.formElement && e9.openElements.tmplCount === 0 && (e9._insertElement(t, G0.HTML), e9.formElement = e9.openElements.current, e9.openElements.pop());
}
function i_(e9, t) {
  switch (t.tagID) {
    case Z.TD:
    case Z.TH:
    case Z.TR: {
      xBt(e9, t);
      break;
    }
    case Z.STYLE:
    case Z.SCRIPT:
    case Z.TEMPLATE: {
      j2(e9, t);
      break;
    }
    case Z.COL: {
      oBt(e9, t);
      break;
    }
    case Z.FORM: {
      lBt(e9, t);
      break;
    }
    case Z.TABLE: {
      cBt(e9, t);
      break;
    }
    case Z.TBODY:
    case Z.TFOOT:
    case Z.THEAD: {
      sBt(e9, t);
      break;
    }
    case Z.INPUT: {
      uBt(e9, t);
      break;
    }
    case Z.CAPTION: {
      iBt(e9, t);
      break;
    }
    case Z.COLGROUP: {
      aBt(e9, t);
      break;
    }
    default:
      _C(e9, t);
  }
}
function vC(e9, t) {
  switch (t.tagID) {
    case Z.TABLE: {
      e9.openElements.hasInTableScope(Z.TABLE) && (e9.openElements.popUntilTagNamePopped(Z.TABLE), e9._resetInsertionMode());
      break;
    }
    case Z.TEMPLATE: {
      Py(e9, t);
      break;
    }
    case Z.BODY:
    case Z.CAPTION:
    case Z.COL:
    case Z.COLGROUP:
    case Z.HTML:
    case Z.TBODY:
    case Z.TD:
    case Z.TFOOT:
    case Z.TH:
    case Z.THEAD:
    case Z.TR:
      break;
    default:
      _C(e9, t);
  }
}
function _C(e9, t) {
  let n = e9.fosterParentingEnabled;
  e9.fosterParentingEnabled = true, LH(e9, t), e9.fosterParentingEnabled = n;
}
function Cx0(e9, t) {
  e9.pendingCharacterTokens.push(t);
}
function Nx0(e9, t) {
  e9.pendingCharacterTokens.push(t), e9.hasNonWhitespacePendingCharacterToken = true;
}
function hC(e9, t) {
  let n = 0;
  if (e9.hasNonWhitespacePendingCharacterToken) for (; n < e9.pendingCharacterTokens.length; n++) _C(e9, e9.pendingCharacterTokens[n]);
  else for (; n < e9.pendingCharacterTokens.length; n++) e9._insertCharacters(e9.pendingCharacterTokens[n]);
  e9.insertionMode = e9.originalInsertionMode, e9._processToken(t);
}
var Ox0 = /* @__PURE__ */ new Set([Z.CAPTION, Z.COL, Z.COLGROUP, Z.TBODY, Z.TD, Z.TFOOT, Z.TH, Z.THEAD, Z.TR]);
function fBt(e9, t) {
  let n = t.tagID;
  Ox0.has(n) ? e9.openElements.hasInTableScope(Z.CAPTION) && (e9.openElements.generateImpliedEndTags(), e9.openElements.popUntilTagNamePopped(Z.CAPTION), e9.activeFormattingElements.clearToLastMarker(), e9.insertionMode = Ze.IN_TABLE, i_(e9, t)) : Wc(e9, t);
}
function dBt(e9, t) {
  let n = t.tagID;
  switch (n) {
    case Z.CAPTION:
    case Z.TABLE: {
      e9.openElements.hasInTableScope(Z.CAPTION) && (e9.openElements.generateImpliedEndTags(), e9.openElements.popUntilTagNamePopped(Z.CAPTION), e9.activeFormattingElements.clearToLastMarker(), e9.insertionMode = Ze.IN_TABLE, n === Z.TABLE && vC(e9, t));
      break;
    }
    case Z.BODY:
    case Z.COL:
    case Z.COLGROUP:
    case Z.HTML:
    case Z.TBODY:
    case Z.TD:
    case Z.TFOOT:
    case Z.TH:
    case Z.THEAD:
    case Z.TR:
      break;
    default:
      MH(e9, t);
  }
}
function o2e(e9, t) {
  switch (t.tagID) {
    case Z.HTML: {
      Wc(e9, t);
      break;
    }
    case Z.COL: {
      e9._appendElement(t, G0.HTML), t.ackSelfClosing = true;
      break;
    }
    case Z.TEMPLATE: {
      j2(e9, t);
      break;
    }
    default:
      PH(e9, t);
  }
}
function pBt(e9, t) {
  switch (t.tagID) {
    case Z.COLGROUP: {
      e9.openElements.currentTagId === Z.COLGROUP && (e9.openElements.pop(), e9.insertionMode = Ze.IN_TABLE);
      break;
    }
    case Z.TEMPLATE: {
      Py(e9, t);
      break;
    }
    case Z.COL:
      break;
    default:
      PH(e9, t);
  }
}
function PH(e9, t) {
  e9.openElements.currentTagId === Z.COLGROUP && (e9.openElements.pop(), e9.insertionMode = Ze.IN_TABLE, e9._processToken(t));
}
function UH(e9, t) {
  switch (t.tagID) {
    case Z.TR: {
      e9.openElements.clearBackToTableBodyContext(), e9._insertElement(t, G0.HTML), e9.insertionMode = Ze.IN_ROW;
      break;
    }
    case Z.TH:
    case Z.TD: {
      e9.openElements.clearBackToTableBodyContext(), e9._insertFakeElement(d0.TR, Z.TR), e9.insertionMode = Ze.IN_ROW, $H(e9, t);
      break;
    }
    case Z.CAPTION:
    case Z.COL:
    case Z.COLGROUP:
    case Z.TBODY:
    case Z.TFOOT:
    case Z.THEAD: {
      e9.openElements.hasTableBodyContextInTableScope() && (e9.openElements.clearBackToTableBodyContext(), e9.openElements.pop(), e9.insertionMode = Ze.IN_TABLE, i_(e9, t));
      break;
    }
    default:
      i_(e9, t);
  }
}
function n2e(e9, t) {
  let n = t.tagID;
  switch (t.tagID) {
    case Z.TBODY:
    case Z.TFOOT:
    case Z.THEAD: {
      e9.openElements.hasInTableScope(n) && (e9.openElements.clearBackToTableBodyContext(), e9.openElements.pop(), e9.insertionMode = Ze.IN_TABLE);
      break;
    }
    case Z.TABLE: {
      e9.openElements.hasTableBodyContextInTableScope() && (e9.openElements.clearBackToTableBodyContext(), e9.openElements.pop(), e9.insertionMode = Ze.IN_TABLE, vC(e9, t));
      break;
    }
    case Z.BODY:
    case Z.CAPTION:
    case Z.COL:
    case Z.COLGROUP:
    case Z.HTML:
    case Z.TD:
    case Z.TH:
    case Z.TR:
      break;
    default:
      vC(e9, t);
  }
}
function $H(e9, t) {
  switch (t.tagID) {
    case Z.TH:
    case Z.TD: {
      e9.openElements.clearBackToTableRowContext(), e9._insertElement(t, G0.HTML), e9.insertionMode = Ze.IN_CELL, e9.activeFormattingElements.insertMarker();
      break;
    }
    case Z.CAPTION:
    case Z.COL:
    case Z.COLGROUP:
    case Z.TBODY:
    case Z.TFOOT:
    case Z.THEAD:
    case Z.TR: {
      e9.openElements.hasInTableScope(Z.TR) && (e9.openElements.clearBackToTableRowContext(), e9.openElements.pop(), e9.insertionMode = Ze.IN_TABLE_BODY, UH(e9, t));
      break;
    }
    default:
      i_(e9, t);
  }
}
function Dx0(e9, t) {
  switch (t.tagID) {
    case Z.TR: {
      e9.openElements.hasInTableScope(Z.TR) && (e9.openElements.clearBackToTableRowContext(), e9.openElements.pop(), e9.insertionMode = Ze.IN_TABLE_BODY);
      break;
    }
    case Z.TABLE: {
      e9.openElements.hasInTableScope(Z.TR) && (e9.openElements.clearBackToTableRowContext(), e9.openElements.pop(), e9.insertionMode = Ze.IN_TABLE_BODY, n2e(e9, t));
      break;
    }
    case Z.TBODY:
    case Z.TFOOT:
    case Z.THEAD: {
      (e9.openElements.hasInTableScope(t.tagID) || e9.openElements.hasInTableScope(Z.TR)) && (e9.openElements.clearBackToTableRowContext(), e9.openElements.pop(), e9.insertionMode = Ze.IN_TABLE_BODY, n2e(e9, t));
      break;
    }
    case Z.BODY:
    case Z.CAPTION:
    case Z.COL:
    case Z.COLGROUP:
    case Z.HTML:
    case Z.TD:
    case Z.TH:
      break;
    default:
      vC(e9, t);
  }
}
function mBt(e9, t) {
  let n = t.tagID;
  Ox0.has(n) ? (e9.openElements.hasInTableScope(Z.TD) || e9.openElements.hasInTableScope(Z.TH)) && (e9._closeTableCell(), $H(e9, t)) : Wc(e9, t);
}
function hBt(e9, t) {
  let n = t.tagID;
  switch (n) {
    case Z.TD:
    case Z.TH: {
      e9.openElements.hasInTableScope(n) && (e9.openElements.generateImpliedEndTags(), e9.openElements.popUntilTagNamePopped(n), e9.activeFormattingElements.clearToLastMarker(), e9.insertionMode = Ze.IN_ROW);
      break;
    }
    case Z.TABLE:
    case Z.TBODY:
    case Z.TFOOT:
    case Z.THEAD:
    case Z.TR: {
      e9.openElements.hasInTableScope(n) && (e9._closeTableCell(), Dx0(e9, t));
      break;
    }
    case Z.BODY:
    case Z.CAPTION:
    case Z.COL:
    case Z.COLGROUP:
    case Z.HTML:
      break;
    default:
      MH(e9, t);
  }
}
function Px0(e9, t) {
  switch (t.tagID) {
    case Z.HTML: {
      Wc(e9, t);
      break;
    }
    case Z.OPTION: {
      e9.openElements.currentTagId === Z.OPTION && e9.openElements.pop(), e9._insertElement(t, G0.HTML);
      break;
    }
    case Z.OPTGROUP: {
      e9.openElements.currentTagId === Z.OPTION && e9.openElements.pop(), e9.openElements.currentTagId === Z.OPTGROUP && e9.openElements.pop(), e9._insertElement(t, G0.HTML);
      break;
    }
    case Z.HR: {
      e9.openElements.currentTagId === Z.OPTION && e9.openElements.pop(), e9.openElements.currentTagId === Z.OPTGROUP && e9.openElements.pop(), e9._appendElement(t, G0.HTML), t.ackSelfClosing = true;
      break;
    }
    case Z.INPUT:
    case Z.KEYGEN:
    case Z.TEXTAREA:
    case Z.SELECT: {
      e9.openElements.hasInSelectScope(Z.SELECT) && (e9.openElements.popUntilTagNamePopped(Z.SELECT), e9._resetInsertionMode(), t.tagID !== Z.SELECT && e9._processStartTag(t));
      break;
    }
    case Z.SCRIPT:
    case Z.TEMPLATE: {
      j2(e9, t);
      break;
    }
    default:
  }
}
function Bx0(e9, t) {
  switch (t.tagID) {
    case Z.OPTGROUP: {
      e9.openElements.stackTop > 0 && e9.openElements.currentTagId === Z.OPTION && e9.openElements.tagIDs[e9.openElements.stackTop - 1] === Z.OPTGROUP && e9.openElements.pop(), e9.openElements.currentTagId === Z.OPTGROUP && e9.openElements.pop();
      break;
    }
    case Z.OPTION: {
      e9.openElements.currentTagId === Z.OPTION && e9.openElements.pop();
      break;
    }
    case Z.SELECT: {
      e9.openElements.hasInSelectScope(Z.SELECT) && (e9.openElements.popUntilTagNamePopped(Z.SELECT), e9._resetInsertionMode());
      break;
    }
    case Z.TEMPLATE: {
      Py(e9, t);
      break;
    }
    default:
  }
}
function gBt(e9, t) {
  let n = t.tagID;
  n === Z.CAPTION || n === Z.TABLE || n === Z.TBODY || n === Z.TFOOT || n === Z.THEAD || n === Z.TR || n === Z.TD || n === Z.TH ? (e9.openElements.popUntilTagNamePopped(Z.SELECT), e9._resetInsertionMode(), e9._processStartTag(t)) : Px0(e9, t);
}
function bBt(e9, t) {
  let n = t.tagID;
  n === Z.CAPTION || n === Z.TABLE || n === Z.TBODY || n === Z.TFOOT || n === Z.THEAD || n === Z.TR || n === Z.TD || n === Z.TH ? e9.openElements.hasInTableScope(n) && (e9.openElements.popUntilTagNamePopped(Z.SELECT), e9._resetInsertionMode(), e9.onEndTag(t)) : Bx0(e9, t);
}
function yBt(e9, t) {
  switch (t.tagID) {
    case Z.BASE:
    case Z.BASEFONT:
    case Z.BGSOUND:
    case Z.LINK:
    case Z.META:
    case Z.NOFRAMES:
    case Z.SCRIPT:
    case Z.STYLE:
    case Z.TEMPLATE:
    case Z.TITLE: {
      j2(e9, t);
      break;
    }
    case Z.CAPTION:
    case Z.COLGROUP:
    case Z.TBODY:
    case Z.TFOOT:
    case Z.THEAD: {
      e9.tmplInsertionModeStack[0] = Ze.IN_TABLE, e9.insertionMode = Ze.IN_TABLE, i_(e9, t);
      break;
    }
    case Z.COL: {
      e9.tmplInsertionModeStack[0] = Ze.IN_COLUMN_GROUP, e9.insertionMode = Ze.IN_COLUMN_GROUP, o2e(e9, t);
      break;
    }
    case Z.TR: {
      e9.tmplInsertionModeStack[0] = Ze.IN_TABLE_BODY, e9.insertionMode = Ze.IN_TABLE_BODY, UH(e9, t);
      break;
    }
    case Z.TD:
    case Z.TH: {
      e9.tmplInsertionModeStack[0] = Ze.IN_ROW, e9.insertionMode = Ze.IN_ROW, $H(e9, t);
      break;
    }
    default:
      e9.tmplInsertionModeStack[0] = Ze.IN_BODY, e9.insertionMode = Ze.IN_BODY, Wc(e9, t);
  }
}
function ABt(e9, t) {
  t.tagID === Z.TEMPLATE && Py(e9, t);
}
function Lx0(e9, t) {
  e9.openElements.tmplCount > 0 ? (e9.openElements.popUntilTagNamePopped(Z.TEMPLATE), e9.activeFormattingElements.clearToLastMarker(), e9.tmplInsertionModeStack.shift(), e9._resetInsertionMode(), e9.onEof(t)) : a2e(e9, t);
}
function kBt(e9, t) {
  t.tagID === Z.HTML ? Wc(e9, t) : BH(e9, t);
}
function Mx0(e9, t) {
  var n;
  if (t.tagID === Z.HTML) {
    if (e9.fragmentContext || (e9.insertionMode = Ze.AFTER_AFTER_BODY), e9.options.sourceCodeLocationInfo && e9.openElements.tagIDs[0] === Z.HTML) {
      e9._setEndLocation(e9.openElements.items[0], t);
      let s = e9.openElements.items[1];
      s && !(!((n = e9.treeAdapter.getNodeSourceCodeLocation(s)) === null || n === void 0) && n.endTag) && e9._setEndLocation(s, t);
    }
  } else BH(e9, t);
}
function BH(e9, t) {
  e9.insertionMode = Ze.IN_BODY, LH(e9, t);
}
function vBt(e9, t) {
  switch (t.tagID) {
    case Z.HTML: {
      Wc(e9, t);
      break;
    }
    case Z.FRAMESET: {
      e9._insertElement(t, G0.HTML);
      break;
    }
    case Z.FRAME: {
      e9._appendElement(t, G0.HTML), t.ackSelfClosing = true;
      break;
    }
    case Z.NOFRAMES: {
      j2(e9, t);
      break;
    }
    default:
  }
}
function _Bt(e9, t) {
  t.tagID === Z.FRAMESET && !e9.openElements.isRootHtmlElementCurrent() && (e9.openElements.pop(), !e9.fragmentContext && e9.openElements.currentTagId !== Z.FRAMESET && (e9.insertionMode = Ze.AFTER_FRAMESET));
}
function wBt(e9, t) {
  switch (t.tagID) {
    case Z.HTML: {
      Wc(e9, t);
      break;
    }
    case Z.NOFRAMES: {
      j2(e9, t);
      break;
    }
    default:
  }
}
function SBt(e9, t) {
  t.tagID === Z.HTML && (e9.insertionMode = Ze.AFTER_AFTER_FRAMESET);
}
function EBt(e9, t) {
  t.tagID === Z.HTML ? Wc(e9, t) : DH(e9, t);
}
function DH(e9, t) {
  e9.insertionMode = Ze.IN_BODY, LH(e9, t);
}
function TBt(e9, t) {
  switch (t.tagID) {
    case Z.HTML: {
      Wc(e9, t);
      break;
    }
    case Z.NOFRAMES: {
      j2(e9, t);
      break;
    }
    default:
  }
}
function IBt(e9, t) {
  t.chars = Ka, e9._insertCharacters(t);
}
function RBt(e9, t) {
  e9._insertCharacters(t), e9.framesetOk = false;
}
function Ux0(e9) {
  for (; e9.treeAdapter.getNamespaceURI(e9.openElements.current) !== G0.HTML && e9.openElements.currentTagId !== void 0 && !e9._isIntegrationPoint(e9.openElements.currentTagId, e9.openElements.current); ) e9.openElements.pop();
}
function CBt(e9, t) {
  if (hx0(t)) Ux0(e9), e9._startTagOutsideForeignContent(t);
  else {
    let n = e9._getAdjustedCurrentElement(), s = e9.treeAdapter.getNamespaceURI(n);
    s === G0.MATHML ? Xde(t) : s === G0.SVG && (gx0(t), e2e(t)), OH(t), t.selfClosing ? e9._appendElement(t, s) : e9._insertElement(t, s), t.ackSelfClosing = true;
  }
}
function NBt(e9, t) {
  if (t.tagID === Z.P || t.tagID === Z.BR) {
    Ux0(e9), e9._endTagOutsideForeignContent(t);
    return;
  }
  for (let n = e9.openElements.stackTop; n > 0; n--) {
    let s = e9.openElements.items[n];
    if (e9.treeAdapter.getNamespaceURI(s) === G0.HTML) {
      e9._endTagOutsideForeignContent(t);
      break;
    }
    let c = e9.treeAdapter.getTagName(s);
    if (c.toLowerCase() === t.tagName) {
      t.tagName = c, e9.openElements.shortenToLength(n);
      break;
    }
  }
}
function $x0(e9, t) {
  return function(s) {
    let c, l = 0, d = "";
    for (; c = e9.exec(s); ) l !== c.index && (d += s.substring(l, c.index)), d += t.get(c[0].charCodeAt(0)), l = c.index + 1;
    return d + s.substring(l);
  };
}
var Fx0 = $x0(/["&\u00A0]/g, /* @__PURE__ */ new Map([[34, "&quot;"], [38, "&amp;"], [160, "&nbsp;"]]));
var Wx0 = $x0(/[&<>\u00A0]/g, /* @__PURE__ */ new Map([[38, "&amp;"], [60, "&lt;"], [62, "&gt;"], [160, "&nbsp;"]]));
var OBt = /* @__PURE__ */ new Set([d0.AREA, d0.BASE, d0.BASEFONT, d0.BGSOUND, d0.BR, d0.COL, d0.EMBED, d0.FRAME, d0.HR, d0.IMG, d0.INPUT, d0.KEYGEN, d0.LINK, d0.META, d0.PARAM, d0.SOURCE, d0.TRACK, d0.WBR]);
function DBt(e9, t) {
  return t.treeAdapter.isElementNode(e9) && t.treeAdapter.getNamespaceURI(e9) === G0.HTML && OBt.has(t.treeAdapter.getTagName(e9));
}
var PBt = { treeAdapter: Td, scriptingEnabled: true };
function s2e(e9, t) {
  let n = { ...PBt, ...t };
  return Vx0(e9, n);
}
function BBt(e9, t) {
  let n = "", s = t.treeAdapter.isElementNode(e9) && t.treeAdapter.getTagName(e9) === d0.TEMPLATE && t.treeAdapter.getNamespaceURI(e9) === G0.HTML ? t.treeAdapter.getTemplateContent(e9) : e9, c = t.treeAdapter.getChildNodes(s);
  if (c) for (let l of c) n += Vx0(l, t);
  return n;
}
function Vx0(e9, t) {
  return t.treeAdapter.isElementNode(e9) ? LBt(e9, t) : t.treeAdapter.isTextNode(e9) ? UBt(e9, t) : t.treeAdapter.isCommentNode(e9) ? $Bt(e9, t) : t.treeAdapter.isDocumentTypeNode(e9) ? FBt(e9, t) : "";
}
function LBt(e9, t) {
  let n = t.treeAdapter.getTagName(e9);
  return `<${n}${MBt(e9, t)}>${DBt(e9, t) ? "" : `${BBt(e9, t)}</${n}>`}`;
}
function MBt(e9, { treeAdapter: t }) {
  let n = "";
  for (let s of t.getAttrList(e9)) {
    if (n += " ", s.namespace) switch (s.namespace) {
      case G0.XML: {
        n += `xml:${s.name}`;
        break;
      }
      case G0.XMLNS: {
        s.name !== "xmlns" && (n += "xmlns:"), n += s.name;
        break;
      }
      case G0.XLINK: {
        n += `xlink:${s.name}`;
        break;
      }
      default:
        n += `${s.prefix}:${s.name}`;
    }
    else n += s.name;
    n += `="${Fx0(s.value)}"`;
  }
  return n;
}
function UBt(e9, t) {
  let { treeAdapter: n } = t, s = n.getTextNodeContent(e9), c = n.getParentNode(e9), l = c && n.isElementNode(c) && n.getTagName(c);
  return l && n.getNamespaceURI(c) === G0.HTML && Jde(l, t.scriptingEnabled) ? s : Wx0(s);
}
function $Bt(e9, { treeAdapter: t }) {
  return `<!--${t.getCommentNodeContent(e9)}-->`;
}
function FBt(e9, { treeAdapter: t }) {
  return `<!DOCTYPE ${t.getDocumentTypeNodeName(e9)}>`;
}
function jx0(e9, t) {
  return n_.parse(e9, t);
}
function Gx0(e9, t, n) {
  typeof e9 == "string" && (n = t, t = e9, e9 = null);
  let s = n_.getFragmentParser(e9, n);
  return s.tokenizer.write(t, true), s.getFragment();
}
function Hx0(e9) {
  let t = e9.includes('"') ? "'" : '"';
  return t + e9 + t;
}
function WBt(e9, t, n) {
  let s = "!DOCTYPE ";
  return e9 && (s += e9), t ? s += ` PUBLIC ${Hx0(t)}` : n && (s += " SYSTEM"), n && (s += ` ${Hx0(n)}`), s;
}
var Wm = { isCommentNode: Cy, isElementNode: yr, isTextNode: rl, createDocument() {
  let e9 = new rf([]);
  return e9["x-mode"] = TH.DOCUMENT_MODE.NO_QUIRKS, e9;
}, createDocumentFragment() {
  return new rf([]);
}, createElement(e9, t, n) {
  let s = /* @__PURE__ */ Object.create(null), c = /* @__PURE__ */ Object.create(null), l = /* @__PURE__ */ Object.create(null);
  for (let m = 0; m < n.length; m++) {
    let g = n[m].name;
    s[g] = n[m].value, c[g] = n[m].namespace, l[g] = n[m].prefix;
  }
  let d = new Ry(e9, s, []);
  return d.namespace = t, d["x-attribsNamespace"] = c, d["x-attribsPrefix"] = l, d;
}, createCommentNode(e9) {
  return new Ty(e9);
}, createTextNode(e9) {
  return new v1(e9);
}, appendChild(e9, t) {
  let n = e9.children[e9.children.length - 1];
  n && (n.next = t, t.prev = n), e9.children.push(t), t.parent = e9;
}, insertBefore(e9, t, n) {
  let s = e9.children.indexOf(n), { prev: c } = n;
  c && (c.next = t, t.prev = c), n.prev = t, t.next = n, e9.children.splice(s, 0, t), t.parent = e9;
}, setTemplateContent(e9, t) {
  Wm.appendChild(e9, t);
}, getTemplateContent(e9) {
  return e9.children[0];
}, setDocumentType(e9, t, n, s) {
  let c = WBt(t, n, s), l = e9.children.find((d) => GG(d) && d.name === "!doctype");
  l ? l.data = c ?? null : (l = new Iy("!doctype", c), Wm.appendChild(e9, l)), l["x-name"] = t, l["x-publicId"] = n, l["x-systemId"] = s;
}, setDocumentMode(e9, t) {
  e9["x-mode"] = t;
}, getDocumentMode(e9) {
  return e9["x-mode"];
}, detachNode(e9) {
  if (e9.parent) {
    let t = e9.parent.children.indexOf(e9), { prev: n, next: s } = e9;
    e9.prev = null, e9.next = null, n && (n.next = s), s && (s.prev = n), e9.parent.children.splice(t, 1), e9.parent = null;
  }
}, insertText(e9, t) {
  let n = e9.children[e9.children.length - 1];
  n && rl(n) ? n.data += t : Wm.appendChild(e9, Wm.createTextNode(t));
}, insertTextBefore(e9, t, n) {
  let s = e9.children[e9.children.indexOf(n) - 1];
  s && rl(s) ? s.data += t : Wm.insertBefore(e9, Wm.createTextNode(t), n);
}, adoptAttributes(e9, t) {
  for (let n = 0; n < t.length; n++) {
    let s = t[n].name;
    e9.attribs[s] === void 0 && (e9.attribs[s] = t[n].value, e9["x-attribsNamespace"][s] = t[n].namespace, e9["x-attribsPrefix"][s] = t[n].prefix);
  }
}, getFirstChild(e9) {
  return e9.children[0];
}, getChildNodes(e9) {
  return e9.children;
}, getParentNode(e9) {
  return e9.parent;
}, getAttrList(e9) {
  return e9.attributes;
}, getTagName(e9) {
  return e9.name;
}, getNamespaceURI(e9) {
  return e9.namespace;
}, getTextNodeContent(e9) {
  return e9.data;
}, getCommentNodeContent(e9) {
  return e9.data;
}, getDocumentTypeNodeName(e9) {
  var t;
  return (t = e9["x-name"]) !== null && t !== void 0 ? t : "";
}, getDocumentTypeNodePublicId(e9) {
  var t;
  return (t = e9["x-publicId"]) !== null && t !== void 0 ? t : "";
}, getDocumentTypeNodeSystemId(e9) {
  var t;
  return (t = e9["x-systemId"]) !== null && t !== void 0 ? t : "";
}, isDocumentTypeNode(e9) {
  return GG(e9) && e9.name === "!doctype";
}, setNodeSourceCodeLocation(e9, t) {
  t && (e9.startIndex = t.startOffset, e9.endIndex = t.endOffset), e9.sourceCodeLocation = t;
}, getNodeSourceCodeLocation(e9) {
  return e9.sourceCodeLocation;
}, updateNodeSourceCodeLocation(e9, t) {
  t.endOffset != null && (e9.endIndex = t.endOffset), e9.sourceCodeLocation = { ...e9.sourceCodeLocation, ...t };
} };
function qx0(e9, t, n, s) {
  let c = { scriptingEnabled: typeof t.scriptingEnabled == "boolean" ? t.scriptingEnabled : true, treeAdapter: Wm, sourceCodeLocationInfo: t.sourceCodeLocationInfo };
  return n ? jx0(e9, c) : Gx0(s, e9, c);
}
var VBt = { treeAdapter: Wm };
function zx0(e9) {
  let t = "length" in e9 ? e9 : [e9];
  for (let s = 0; s < t.length; s += 1) {
    let c = t[s];
    F2(c) && Array.prototype.splice.call(t, s, 1, ...c.children);
  }
  let n = "";
  for (let s = 0; s < t.length; s += 1) {
    let c = t[s];
    n += s2e(c, VBt);
  }
  return n;
}
var er;
(function(e9) {
  e9[e9.Tab = 9] = "Tab", e9[e9.NewLine = 10] = "NewLine", e9[e9.FormFeed = 12] = "FormFeed", e9[e9.CarriageReturn = 13] = "CarriageReturn", e9[e9.Space = 32] = "Space", e9[e9.ExclamationMark = 33] = "ExclamationMark", e9[e9.Number = 35] = "Number", e9[e9.Amp = 38] = "Amp", e9[e9.SingleQuote = 39] = "SingleQuote", e9[e9.DoubleQuote = 34] = "DoubleQuote", e9[e9.Dash = 45] = "Dash", e9[e9.Slash = 47] = "Slash", e9[e9.Zero = 48] = "Zero", e9[e9.Nine = 57] = "Nine", e9[e9.Semi = 59] = "Semi", e9[e9.Lt = 60] = "Lt", e9[e9.Eq = 61] = "Eq", e9[e9.Gt = 62] = "Gt", e9[e9.Questionmark = 63] = "Questionmark", e9[e9.UpperA = 65] = "UpperA", e9[e9.LowerA = 97] = "LowerA", e9[e9.UpperF = 70] = "UpperF", e9[e9.LowerF = 102] = "LowerF", e9[e9.UpperZ = 90] = "UpperZ", e9[e9.LowerZ = 122] = "LowerZ", e9[e9.LowerX = 120] = "LowerX", e9[e9.OpeningSquareBracket = 91] = "OpeningSquareBracket";
})(er || (er = {}));
var q0;
(function(e9) {
  e9[e9.Text = 1] = "Text", e9[e9.BeforeTagName = 2] = "BeforeTagName", e9[e9.InTagName = 3] = "InTagName", e9[e9.InSelfClosingTag = 4] = "InSelfClosingTag", e9[e9.BeforeClosingTagName = 5] = "BeforeClosingTagName", e9[e9.InClosingTagName = 6] = "InClosingTagName", e9[e9.AfterClosingTagName = 7] = "AfterClosingTagName", e9[e9.BeforeAttributeName = 8] = "BeforeAttributeName", e9[e9.InAttributeName = 9] = "InAttributeName", e9[e9.AfterAttributeName = 10] = "AfterAttributeName", e9[e9.BeforeAttributeValue = 11] = "BeforeAttributeValue", e9[e9.InAttributeValueDq = 12] = "InAttributeValueDq", e9[e9.InAttributeValueSq = 13] = "InAttributeValueSq", e9[e9.InAttributeValueNq = 14] = "InAttributeValueNq", e9[e9.BeforeDeclaration = 15] = "BeforeDeclaration", e9[e9.InDeclaration = 16] = "InDeclaration", e9[e9.InProcessingInstruction = 17] = "InProcessingInstruction", e9[e9.BeforeComment = 18] = "BeforeComment", e9[e9.CDATASequence = 19] = "CDATASequence", e9[e9.InSpecialComment = 20] = "InSpecialComment", e9[e9.InCommentLike = 21] = "InCommentLike", e9[e9.BeforeSpecialS = 22] = "BeforeSpecialS", e9[e9.SpecialStartSequence = 23] = "SpecialStartSequence", e9[e9.InSpecialTag = 24] = "InSpecialTag", e9[e9.BeforeEntity = 25] = "BeforeEntity", e9[e9.BeforeNumericEntity = 26] = "BeforeNumericEntity", e9[e9.InNamedEntity = 27] = "InNamedEntity", e9[e9.InNumericEntity = 28] = "InNumericEntity", e9[e9.InHexEntity = 29] = "InHexEntity";
})(q0 || (q0 = {}));
function Vm(e9) {
  return e9 === er.Space || e9 === er.NewLine || e9 === er.Tab || e9 === er.FormFeed || e9 === er.CarriageReturn;
}
function FH(e9) {
  return e9 === er.Slash || e9 === er.Gt || Vm(e9);
}
function Yx0(e9) {
  return e9 >= er.Zero && e9 <= er.Nine;
}
function jBt(e9) {
  return e9 >= er.LowerA && e9 <= er.LowerZ || e9 >= er.UpperA && e9 <= er.UpperZ;
}
function GBt(e9) {
  return e9 >= er.UpperA && e9 <= er.UpperF || e9 >= er.LowerA && e9 <= er.LowerF;
}
var G2;
(function(e9) {
  e9[e9.NoValue = 0] = "NoValue", e9[e9.Unquoted = 1] = "Unquoted", e9[e9.Single = 2] = "Single", e9[e9.Double = 3] = "Double";
})(G2 || (G2 = {}));
var ol = { Cdata: new Uint8Array([67, 68, 65, 84, 65, 91]), CdataEnd: new Uint8Array([93, 93, 62]), CommentEnd: new Uint8Array([45, 45, 62]), ScriptEnd: new Uint8Array([60, 47, 115, 99, 114, 105, 112, 116]), StyleEnd: new Uint8Array([60, 47, 115, 116, 121, 108, 101]), TitleEnd: new Uint8Array([60, 47, 116, 105, 116, 108, 101]) };
var a_ = class {
  constructor({ xmlMode: t = false, decodeEntities: n = true }, s) {
    this.cbs = s, this.state = q0.Text, this.buffer = "", this.sectionStart = 0, this.index = 0, this.baseState = q0.Text, this.isSpecial = false, this.running = true, this.offset = 0, this.currentSequence = void 0, this.sequenceIndex = 0, this.trieIndex = 0, this.trieCurrent = 0, this.entityResult = 0, this.entityExcess = 0, this.xmlMode = t, this.decodeEntities = n, this.entityTrie = t ? qG : HG;
  }
  reset() {
    this.state = q0.Text, this.buffer = "", this.sectionStart = 0, this.index = 0, this.baseState = q0.Text, this.currentSequence = void 0, this.running = true, this.offset = 0;
  }
  write(t) {
    this.offset += this.buffer.length, this.buffer = t, this.parse();
  }
  end() {
    this.running && this.finish();
  }
  pause() {
    this.running = false;
  }
  resume() {
    this.running = true, this.index < this.buffer.length + this.offset && this.parse();
  }
  getIndex() {
    return this.index;
  }
  getSectionStart() {
    return this.sectionStart;
  }
  stateText(t) {
    t === er.Lt || !this.decodeEntities && this.fastForwardTo(er.Lt) ? (this.index > this.sectionStart && this.cbs.ontext(this.sectionStart, this.index), this.state = q0.BeforeTagName, this.sectionStart = this.index) : this.decodeEntities && t === er.Amp && (this.state = q0.BeforeEntity);
  }
  stateSpecialStartSequence(t) {
    let n = this.sequenceIndex === this.currentSequence.length;
    if (!(n ? FH(t) : (t | 32) === this.currentSequence[this.sequenceIndex])) this.isSpecial = false;
    else if (!n) {
      this.sequenceIndex++;
      return;
    }
    this.sequenceIndex = 0, this.state = q0.InTagName, this.stateInTagName(t);
  }
  stateInSpecialTag(t) {
    if (this.sequenceIndex === this.currentSequence.length) {
      if (t === er.Gt || Vm(t)) {
        let n = this.index - this.currentSequence.length;
        if (this.sectionStart < n) {
          let s = this.index;
          this.index = n, this.cbs.ontext(this.sectionStart, n), this.index = s;
        }
        this.isSpecial = false, this.sectionStart = n + 2, this.stateInClosingTagName(t);
        return;
      }
      this.sequenceIndex = 0;
    }
    (t | 32) === this.currentSequence[this.sequenceIndex] ? this.sequenceIndex += 1 : this.sequenceIndex === 0 ? this.currentSequence === ol.TitleEnd ? this.decodeEntities && t === er.Amp && (this.state = q0.BeforeEntity) : this.fastForwardTo(er.Lt) && (this.sequenceIndex = 1) : this.sequenceIndex = +(t === er.Lt);
  }
  stateCDATASequence(t) {
    t === ol.Cdata[this.sequenceIndex] ? ++this.sequenceIndex === ol.Cdata.length && (this.state = q0.InCommentLike, this.currentSequence = ol.CdataEnd, this.sequenceIndex = 0, this.sectionStart = this.index + 1) : (this.sequenceIndex = 0, this.state = q0.InDeclaration, this.stateInDeclaration(t));
  }
  fastForwardTo(t) {
    for (; ++this.index < this.buffer.length + this.offset; ) if (this.buffer.charCodeAt(this.index - this.offset) === t) return true;
    return this.index = this.buffer.length + this.offset - 1, false;
  }
  stateInCommentLike(t) {
    t === this.currentSequence[this.sequenceIndex] ? ++this.sequenceIndex === this.currentSequence.length && (this.currentSequence === ol.CdataEnd ? this.cbs.oncdata(this.sectionStart, this.index, 2) : this.cbs.oncomment(this.sectionStart, this.index, 2), this.sequenceIndex = 0, this.sectionStart = this.index + 1, this.state = q0.Text) : this.sequenceIndex === 0 ? this.fastForwardTo(this.currentSequence[0]) && (this.sequenceIndex = 1) : t !== this.currentSequence[this.sequenceIndex - 1] && (this.sequenceIndex = 0);
  }
  isTagStartChar(t) {
    return this.xmlMode ? !FH(t) : jBt(t);
  }
  startSpecial(t, n) {
    this.isSpecial = true, this.currentSequence = t, this.sequenceIndex = n, this.state = q0.SpecialStartSequence;
  }
  stateBeforeTagName(t) {
    if (t === er.ExclamationMark) this.state = q0.BeforeDeclaration, this.sectionStart = this.index + 1;
    else if (t === er.Questionmark) this.state = q0.InProcessingInstruction, this.sectionStart = this.index + 1;
    else if (this.isTagStartChar(t)) {
      let n = t | 32;
      this.sectionStart = this.index, !this.xmlMode && n === ol.TitleEnd[2] ? this.startSpecial(ol.TitleEnd, 3) : this.state = !this.xmlMode && n === ol.ScriptEnd[2] ? q0.BeforeSpecialS : q0.InTagName;
    } else t === er.Slash ? this.state = q0.BeforeClosingTagName : (this.state = q0.Text, this.stateText(t));
  }
  stateInTagName(t) {
    FH(t) && (this.cbs.onopentagname(this.sectionStart, this.index), this.sectionStart = -1, this.state = q0.BeforeAttributeName, this.stateBeforeAttributeName(t));
  }
  stateBeforeClosingTagName(t) {
    Vm(t) || (t === er.Gt ? this.state = q0.Text : (this.state = this.isTagStartChar(t) ? q0.InClosingTagName : q0.InSpecialComment, this.sectionStart = this.index));
  }
  stateInClosingTagName(t) {
    (t === er.Gt || Vm(t)) && (this.cbs.onclosetag(this.sectionStart, this.index), this.sectionStart = -1, this.state = q0.AfterClosingTagName, this.stateAfterClosingTagName(t));
  }
  stateAfterClosingTagName(t) {
    (t === er.Gt || this.fastForwardTo(er.Gt)) && (this.state = q0.Text, this.baseState = q0.Text, this.sectionStart = this.index + 1);
  }
  stateBeforeAttributeName(t) {
    t === er.Gt ? (this.cbs.onopentagend(this.index), this.isSpecial ? (this.state = q0.InSpecialTag, this.sequenceIndex = 0) : this.state = q0.Text, this.baseState = this.state, this.sectionStart = this.index + 1) : t === er.Slash ? this.state = q0.InSelfClosingTag : Vm(t) || (this.state = q0.InAttributeName, this.sectionStart = this.index);
  }
  stateInSelfClosingTag(t) {
    t === er.Gt ? (this.cbs.onselfclosingtag(this.index), this.state = q0.Text, this.baseState = q0.Text, this.sectionStart = this.index + 1, this.isSpecial = false) : Vm(t) || (this.state = q0.BeforeAttributeName, this.stateBeforeAttributeName(t));
  }
  stateInAttributeName(t) {
    (t === er.Eq || FH(t)) && (this.cbs.onattribname(this.sectionStart, this.index), this.sectionStart = -1, this.state = q0.AfterAttributeName, this.stateAfterAttributeName(t));
  }
  stateAfterAttributeName(t) {
    t === er.Eq ? this.state = q0.BeforeAttributeValue : t === er.Slash || t === er.Gt ? (this.cbs.onattribend(G2.NoValue, this.index), this.state = q0.BeforeAttributeName, this.stateBeforeAttributeName(t)) : Vm(t) || (this.cbs.onattribend(G2.NoValue, this.index), this.state = q0.InAttributeName, this.sectionStart = this.index);
  }
  stateBeforeAttributeValue(t) {
    t === er.DoubleQuote ? (this.state = q0.InAttributeValueDq, this.sectionStart = this.index + 1) : t === er.SingleQuote ? (this.state = q0.InAttributeValueSq, this.sectionStart = this.index + 1) : Vm(t) || (this.sectionStart = this.index, this.state = q0.InAttributeValueNq, this.stateInAttributeValueNoQuotes(t));
  }
  handleInAttributeValue(t, n) {
    t === n || !this.decodeEntities && this.fastForwardTo(n) ? (this.cbs.onattribdata(this.sectionStart, this.index), this.sectionStart = -1, this.cbs.onattribend(n === er.DoubleQuote ? G2.Double : G2.Single, this.index), this.state = q0.BeforeAttributeName) : this.decodeEntities && t === er.Amp && (this.baseState = this.state, this.state = q0.BeforeEntity);
  }
  stateInAttributeValueDoubleQuotes(t) {
    this.handleInAttributeValue(t, er.DoubleQuote);
  }
  stateInAttributeValueSingleQuotes(t) {
    this.handleInAttributeValue(t, er.SingleQuote);
  }
  stateInAttributeValueNoQuotes(t) {
    Vm(t) || t === er.Gt ? (this.cbs.onattribdata(this.sectionStart, this.index), this.sectionStart = -1, this.cbs.onattribend(G2.Unquoted, this.index), this.state = q0.BeforeAttributeName, this.stateBeforeAttributeName(t)) : this.decodeEntities && t === er.Amp && (this.baseState = this.state, this.state = q0.BeforeEntity);
  }
  stateBeforeDeclaration(t) {
    t === er.OpeningSquareBracket ? (this.state = q0.CDATASequence, this.sequenceIndex = 0) : this.state = t === er.Dash ? q0.BeforeComment : q0.InDeclaration;
  }
  stateInDeclaration(t) {
    (t === er.Gt || this.fastForwardTo(er.Gt)) && (this.cbs.ondeclaration(this.sectionStart, this.index), this.state = q0.Text, this.sectionStart = this.index + 1);
  }
  stateInProcessingInstruction(t) {
    (t === er.Gt || this.fastForwardTo(er.Gt)) && (this.cbs.onprocessinginstruction(this.sectionStart, this.index), this.state = q0.Text, this.sectionStart = this.index + 1);
  }
  stateBeforeComment(t) {
    t === er.Dash ? (this.state = q0.InCommentLike, this.currentSequence = ol.CommentEnd, this.sequenceIndex = 2, this.sectionStart = this.index + 1) : this.state = q0.InDeclaration;
  }
  stateInSpecialComment(t) {
    (t === er.Gt || this.fastForwardTo(er.Gt)) && (this.cbs.oncomment(this.sectionStart, this.index, 0), this.state = q0.Text, this.sectionStart = this.index + 1);
  }
  stateBeforeSpecialS(t) {
    let n = t | 32;
    n === ol.ScriptEnd[3] ? this.startSpecial(ol.ScriptEnd, 4) : n === ol.StyleEnd[3] ? this.startSpecial(ol.StyleEnd, 4) : (this.state = q0.InTagName, this.stateInTagName(t));
  }
  stateBeforeEntity(t) {
    this.entityExcess = 1, this.entityResult = 0, t === er.Number ? this.state = q0.BeforeNumericEntity : t === er.Amp || (this.trieIndex = 0, this.trieCurrent = this.entityTrie[0], this.state = q0.InNamedEntity, this.stateInNamedEntity(t));
  }
  stateInNamedEntity(t) {
    if (this.entityExcess += 1, this.trieIndex = xde(this.entityTrie, this.trieCurrent, this.trieIndex + 1, t), this.trieIndex < 0) {
      this.emitNamedEntity(), this.index--;
      return;
    }
    this.trieCurrent = this.entityTrie[this.trieIndex];
    let n = this.trieCurrent & _d.VALUE_LENGTH;
    if (n) {
      let s = (n >> 14) - 1;
      if (!this.allowLegacyEntity() && t !== er.Semi) this.trieIndex += s;
      else {
        let c = this.index - this.entityExcess + 1;
        c > this.sectionStart && this.emitPartial(this.sectionStart, c), this.entityResult = this.trieIndex, this.trieIndex += s, this.entityExcess = 0, this.sectionStart = this.index + 1, s === 0 && this.emitNamedEntity();
      }
    }
  }
  emitNamedEntity() {
    if (this.state = this.baseState, this.entityResult === 0) return;
    switch ((this.entityTrie[this.entityResult] & _d.VALUE_LENGTH) >> 14) {
      case 1: {
        this.emitCodePoint(this.entityTrie[this.entityResult] & ~_d.VALUE_LENGTH);
        break;
      }
      case 2: {
        this.emitCodePoint(this.entityTrie[this.entityResult + 1]);
        break;
      }
      case 3:
        this.emitCodePoint(this.entityTrie[this.entityResult + 1]), this.emitCodePoint(this.entityTrie[this.entityResult + 2]);
    }
  }
  stateBeforeNumericEntity(t) {
    (t | 32) === er.LowerX ? (this.entityExcess++, this.state = q0.InHexEntity) : (this.state = q0.InNumericEntity, this.stateInNumericEntity(t));
  }
  emitNumericEntity(t) {
    let n = this.index - this.entityExcess - 1;
    n + 2 + +(this.state === q0.InHexEntity) !== this.index && (n > this.sectionStart && this.emitPartial(this.sectionStart, n), this.sectionStart = this.index + Number(t), this.emitCodePoint(rC(this.entityResult))), this.state = this.baseState;
  }
  stateInNumericEntity(t) {
    t === er.Semi ? this.emitNumericEntity(true) : Yx0(t) ? (this.entityResult = this.entityResult * 10 + (t - er.Zero), this.entityExcess++) : (this.allowLegacyEntity() ? this.emitNumericEntity(false) : this.state = this.baseState, this.index--);
  }
  stateInHexEntity(t) {
    t === er.Semi ? this.emitNumericEntity(true) : Yx0(t) ? (this.entityResult = this.entityResult * 16 + (t - er.Zero), this.entityExcess++) : GBt(t) ? (this.entityResult = this.entityResult * 16 + ((t | 32) - er.LowerA + 10), this.entityExcess++) : (this.allowLegacyEntity() ? this.emitNumericEntity(false) : this.state = this.baseState, this.index--);
  }
  allowLegacyEntity() {
    return !this.xmlMode && (this.baseState === q0.Text || this.baseState === q0.InSpecialTag);
  }
  cleanup() {
    this.running && this.sectionStart !== this.index && (this.state === q0.Text || this.state === q0.InSpecialTag && this.sequenceIndex === 0 ? (this.cbs.ontext(this.sectionStart, this.index), this.sectionStart = this.index) : (this.state === q0.InAttributeValueDq || this.state === q0.InAttributeValueSq || this.state === q0.InAttributeValueNq) && (this.cbs.onattribdata(this.sectionStart, this.index), this.sectionStart = this.index));
  }
  shouldContinue() {
    return this.index < this.buffer.length + this.offset && this.running;
  }
  parse() {
    for (; this.shouldContinue(); ) {
      let t = this.buffer.charCodeAt(this.index - this.offset);
      switch (this.state) {
        case q0.Text: {
          this.stateText(t);
          break;
        }
        case q0.SpecialStartSequence: {
          this.stateSpecialStartSequence(t);
          break;
        }
        case q0.InSpecialTag: {
          this.stateInSpecialTag(t);
          break;
        }
        case q0.CDATASequence: {
          this.stateCDATASequence(t);
          break;
        }
        case q0.InAttributeValueDq: {
          this.stateInAttributeValueDoubleQuotes(t);
          break;
        }
        case q0.InAttributeName: {
          this.stateInAttributeName(t);
          break;
        }
        case q0.InCommentLike: {
          this.stateInCommentLike(t);
          break;
        }
        case q0.InSpecialComment: {
          this.stateInSpecialComment(t);
          break;
        }
        case q0.BeforeAttributeName: {
          this.stateBeforeAttributeName(t);
          break;
        }
        case q0.InTagName: {
          this.stateInTagName(t);
          break;
        }
        case q0.InClosingTagName: {
          this.stateInClosingTagName(t);
          break;
        }
        case q0.BeforeTagName: {
          this.stateBeforeTagName(t);
          break;
        }
        case q0.AfterAttributeName: {
          this.stateAfterAttributeName(t);
          break;
        }
        case q0.InAttributeValueSq: {
          this.stateInAttributeValueSingleQuotes(t);
          break;
        }
        case q0.BeforeAttributeValue: {
          this.stateBeforeAttributeValue(t);
          break;
        }
        case q0.BeforeClosingTagName: {
          this.stateBeforeClosingTagName(t);
          break;
        }
        case q0.AfterClosingTagName: {
          this.stateAfterClosingTagName(t);
          break;
        }
        case q0.BeforeSpecialS: {
          this.stateBeforeSpecialS(t);
          break;
        }
        case q0.InAttributeValueNq: {
          this.stateInAttributeValueNoQuotes(t);
          break;
        }
        case q0.InSelfClosingTag: {
          this.stateInSelfClosingTag(t);
          break;
        }
        case q0.InDeclaration: {
          this.stateInDeclaration(t);
          break;
        }
        case q0.BeforeDeclaration: {
          this.stateBeforeDeclaration(t);
          break;
        }
        case q0.BeforeComment: {
          this.stateBeforeComment(t);
          break;
        }
        case q0.InProcessingInstruction: {
          this.stateInProcessingInstruction(t);
          break;
        }
        case q0.InNamedEntity: {
          this.stateInNamedEntity(t);
          break;
        }
        case q0.BeforeEntity: {
          this.stateBeforeEntity(t);
          break;
        }
        case q0.InHexEntity: {
          this.stateInHexEntity(t);
          break;
        }
        case q0.InNumericEntity: {
          this.stateInNumericEntity(t);
          break;
        }
        default:
          this.stateBeforeNumericEntity(t);
      }
      this.index++;
    }
    this.cleanup();
  }
  finish() {
    this.state === q0.InNamedEntity && this.emitNamedEntity(), this.sectionStart < this.index && this.handleTrailingData(), this.cbs.onend();
  }
  handleTrailingData() {
    let t = this.buffer.length + this.offset;
    this.state === q0.InCommentLike ? this.currentSequence === ol.CdataEnd ? this.cbs.oncdata(this.sectionStart, t, 0) : this.cbs.oncomment(this.sectionStart, t, 0) : this.state === q0.InNumericEntity && this.allowLegacyEntity() ? this.emitNumericEntity(false) : this.state === q0.InHexEntity && this.allowLegacyEntity() ? this.emitNumericEntity(false) : this.state === q0.InTagName || this.state === q0.BeforeAttributeName || this.state === q0.BeforeAttributeValue || this.state === q0.AfterAttributeName || this.state === q0.InAttributeName || this.state === q0.InAttributeValueSq || this.state === q0.InAttributeValueDq || this.state === q0.InAttributeValueNq || this.state === q0.InClosingTagName || this.cbs.ontext(this.sectionStart, t);
  }
  emitPartial(t, n) {
    this.baseState !== q0.Text && this.baseState !== q0.InSpecialTag ? this.cbs.onattribdata(t, n) : this.cbs.ontext(t, n);
  }
  emitCodePoint(t) {
    this.baseState !== q0.Text && this.baseState !== q0.InSpecialTag ? this.cbs.onattribentity(t) : this.cbs.ontextentity(t);
  }
};
var o_ = /* @__PURE__ */ new Set(["input", "option", "optgroup", "select", "button", "datalist", "textarea"]);
var Ta = /* @__PURE__ */ new Set(["p"]);
var Qx0 = /* @__PURE__ */ new Set(["thead", "tbody"]);
var Zx0 = /* @__PURE__ */ new Set(["dd", "dt"]);
var Kx0 = /* @__PURE__ */ new Set(["rt", "rp"]);
var HBt = /* @__PURE__ */ new Map([["tr", /* @__PURE__ */ new Set(["tr", "th", "td"])], ["th", /* @__PURE__ */ new Set(["th"])], ["td", /* @__PURE__ */ new Set(["thead", "th", "td"])], ["body", /* @__PURE__ */ new Set(["head", "link", "script"])], ["li", /* @__PURE__ */ new Set(["li"])], ["p", Ta], ["h1", Ta], ["h2", Ta], ["h3", Ta], ["h4", Ta], ["h5", Ta], ["h6", Ta], ["select", o_], ["input", o_], ["output", o_], ["button", o_], ["datalist", o_], ["textarea", o_], ["option", /* @__PURE__ */ new Set(["option"])], ["optgroup", /* @__PURE__ */ new Set(["optgroup", "option"])], ["dd", Zx0], ["dt", Zx0], ["address", Ta], ["article", Ta], ["aside", Ta], ["blockquote", Ta], ["details", Ta], ["div", Ta], ["dl", Ta], ["fieldset", Ta], ["figcaption", Ta], ["figure", Ta], ["footer", Ta], ["form", Ta], ["header", Ta], ["hr", Ta], ["main", Ta], ["nav", Ta], ["ol", Ta], ["pre", Ta], ["section", Ta], ["table", Ta], ["ul", Ta], ["rt", Kx0], ["rp", Kx0], ["tbody", Qx0], ["tfoot", Qx0]]);
var qBt = /* @__PURE__ */ new Set(["area", "base", "basefont", "br", "col", "command", "embed", "frame", "hr", "img", "input", "isindex", "keygen", "link", "meta", "param", "source", "track", "wbr"]);
var Jx0 = /* @__PURE__ */ new Set(["math", "svg"]);
var Xx0 = /* @__PURE__ */ new Set(["mi", "mo", "mn", "ms", "mtext", "annotation-xml", "foreignobject", "desc", "title"]);
var zBt = /\s|\//;
var wC = class {
  constructor(t, n = {}) {
    var s, c, l, d, m;
    this.options = n, this.startIndex = 0, this.endIndex = 0, this.openTagStart = 0, this.tagname = "", this.attribname = "", this.attribvalue = "", this.attribs = null, this.stack = [], this.foreignContext = [], this.buffers = [], this.bufferOffset = 0, this.writeIndex = 0, this.ended = false, this.cbs = t ?? {}, this.lowerCaseTagNames = (s = n.lowerCaseTags) !== null && s !== void 0 ? s : !n.xmlMode, this.lowerCaseAttributeNames = (c = n.lowerCaseAttributeNames) !== null && c !== void 0 ? c : !n.xmlMode, this.tokenizer = new ((l = n.Tokenizer) !== null && l !== void 0 ? l : a_)(this.options, this), (m = (d = this.cbs).onparserinit) === null || m === void 0 || m.call(d, this);
  }
  ontext(t, n) {
    var s, c;
    let l = this.getSlice(t, n);
    this.endIndex = n - 1, (c = (s = this.cbs).ontext) === null || c === void 0 || c.call(s, l), this.startIndex = n;
  }
  ontextentity(t) {
    var n, s;
    let c = this.tokenizer.getSectionStart();
    this.endIndex = c - 1, (s = (n = this.cbs).ontext) === null || s === void 0 || s.call(n, jv(t)), this.startIndex = c;
  }
  isVoidElement(t) {
    return !this.options.xmlMode && qBt.has(t);
  }
  onopentagname(t, n) {
    this.endIndex = n;
    let s = this.getSlice(t, n);
    this.lowerCaseTagNames && (s = s.toLowerCase()), this.emitOpenTag(s);
  }
  emitOpenTag(t) {
    var n, s, c, l;
    this.openTagStart = this.startIndex, this.tagname = t;
    let d = !this.options.xmlMode && HBt.get(t);
    if (d) for (; this.stack.length > 0 && d.has(this.stack[this.stack.length - 1]); ) {
      let m = this.stack.pop();
      (s = (n = this.cbs).onclosetag) === null || s === void 0 || s.call(n, m, true);
    }
    this.isVoidElement(t) || (this.stack.push(t), Jx0.has(t) ? this.foreignContext.push(true) : Xx0.has(t) && this.foreignContext.push(false)), (l = (c = this.cbs).onopentagname) === null || l === void 0 || l.call(c, t), this.cbs.onopentag && (this.attribs = {});
  }
  endOpenTag(t) {
    var n, s;
    this.startIndex = this.openTagStart, this.attribs && ((s = (n = this.cbs).onopentag) === null || s === void 0 || s.call(n, this.tagname, this.attribs, t), this.attribs = null), this.cbs.onclosetag && this.isVoidElement(this.tagname) && this.cbs.onclosetag(this.tagname, true), this.tagname = "";
  }
  onopentagend(t) {
    this.endIndex = t, this.endOpenTag(false), this.startIndex = t + 1;
  }
  onclosetag(t, n) {
    var s, c, l, d, m, g;
    this.endIndex = n;
    let y = this.getSlice(t, n);
    if (this.lowerCaseTagNames && (y = y.toLowerCase()), (Jx0.has(y) || Xx0.has(y)) && this.foreignContext.pop(), this.isVoidElement(y)) !this.options.xmlMode && y === "br" && ((c = (s = this.cbs).onopentagname) === null || c === void 0 || c.call(s, "br"), (d = (l = this.cbs).onopentag) === null || d === void 0 || d.call(l, "br", {}, true), (g = (m = this.cbs).onclosetag) === null || g === void 0 || g.call(m, "br", false));
    else {
      let v = this.stack.lastIndexOf(y);
      if (v !== -1) if (this.cbs.onclosetag) {
        let w = this.stack.length - v;
        for (; w--; ) this.cbs.onclosetag(this.stack.pop(), w !== 0);
      } else this.stack.length = v;
      else !this.options.xmlMode && y === "p" && (this.emitOpenTag("p"), this.closeCurrentTag(true));
    }
    this.startIndex = n + 1;
  }
  onselfclosingtag(t) {
    this.endIndex = t, this.options.xmlMode || this.options.recognizeSelfClosing || this.foreignContext[this.foreignContext.length - 1] ? (this.closeCurrentTag(false), this.startIndex = t + 1) : this.onopentagend(t);
  }
  closeCurrentTag(t) {
    var n, s;
    let c = this.tagname;
    this.endOpenTag(t), this.stack[this.stack.length - 1] === c && ((s = (n = this.cbs).onclosetag) === null || s === void 0 || s.call(n, c, !t), this.stack.pop());
  }
  onattribname(t, n) {
    this.startIndex = t;
    let s = this.getSlice(t, n);
    this.attribname = this.lowerCaseAttributeNames ? s.toLowerCase() : s;
  }
  onattribdata(t, n) {
    this.attribvalue += this.getSlice(t, n);
  }
  onattribentity(t) {
    this.attribvalue += jv(t);
  }
  onattribend(t, n) {
    var s, c;
    this.endIndex = n, (c = (s = this.cbs).onattribute) === null || c === void 0 || c.call(s, this.attribname, this.attribvalue, t === G2.Double ? '"' : t === G2.Single ? "'" : t === G2.NoValue ? void 0 : null), this.attribs && !Object.prototype.hasOwnProperty.call(this.attribs, this.attribname) && (this.attribs[this.attribname] = this.attribvalue), this.attribvalue = "";
  }
  getInstructionName(t) {
    let n = t.search(zBt), s = n < 0 ? t : t.substr(0, n);
    return this.lowerCaseTagNames && (s = s.toLowerCase()), s;
  }
  ondeclaration(t, n) {
    this.endIndex = n;
    let s = this.getSlice(t, n);
    if (this.cbs.onprocessinginstruction) {
      let c = this.getInstructionName(s);
      this.cbs.onprocessinginstruction(`!${c}`, `!${s}`);
    }
    this.startIndex = n + 1;
  }
  onprocessinginstruction(t, n) {
    this.endIndex = n;
    let s = this.getSlice(t, n);
    if (this.cbs.onprocessinginstruction) {
      let c = this.getInstructionName(s);
      this.cbs.onprocessinginstruction(`?${c}`, `?${s}`);
    }
    this.startIndex = n + 1;
  }
  oncomment(t, n, s) {
    var c, l, d, m;
    this.endIndex = n, (l = (c = this.cbs).oncomment) === null || l === void 0 || l.call(c, this.getSlice(t, n - s)), (m = (d = this.cbs).oncommentend) === null || m === void 0 || m.call(d), this.startIndex = n + 1;
  }
  oncdata(t, n, s) {
    var c, l, d, m, g, y, v, w, T, I;
    this.endIndex = n;
    let N = this.getSlice(t, n - s);
    this.options.xmlMode || this.options.recognizeCDATA ? ((l = (c = this.cbs).oncdatastart) === null || l === void 0 || l.call(c), (m = (d = this.cbs).ontext) === null || m === void 0 || m.call(d, N), (y = (g = this.cbs).oncdataend) === null || y === void 0 || y.call(g)) : ((w = (v = this.cbs).oncomment) === null || w === void 0 || w.call(v, `[CDATA[${N}]]`), (I = (T = this.cbs).oncommentend) === null || I === void 0 || I.call(T)), this.startIndex = n + 1;
  }
  onend() {
    var t, n;
    if (this.cbs.onclosetag) {
      this.endIndex = this.startIndex;
      for (let s = this.stack.length; s > 0; this.cbs.onclosetag(this.stack[--s], true)) ;
    }
    (n = (t = this.cbs).onend) === null || n === void 0 || n.call(t);
  }
  reset() {
    var t, n, s, c;
    (n = (t = this.cbs).onreset) === null || n === void 0 || n.call(t), this.tokenizer.reset(), this.tagname = "", this.attribname = "", this.attribs = null, this.stack.length = 0, this.startIndex = 0, this.endIndex = 0, (c = (s = this.cbs).onparserinit) === null || c === void 0 || c.call(s, this), this.buffers.length = 0, this.bufferOffset = 0, this.writeIndex = 0, this.ended = false;
  }
  parseComplete(t) {
    this.reset(), this.end(t);
  }
  getSlice(t, n) {
    for (; t - this.bufferOffset >= this.buffers[0].length; ) this.shiftBuffer();
    let s = this.buffers[0].slice(t - this.bufferOffset, n - this.bufferOffset);
    for (; n - this.bufferOffset > this.buffers[0].length; ) this.shiftBuffer(), s += this.buffers[0].slice(0, n - this.bufferOffset);
    return s;
  }
  shiftBuffer() {
    this.bufferOffset += this.buffers[0].length, this.writeIndex--, this.buffers.shift();
  }
  write(t) {
    var n, s;
    if (this.ended) {
      (s = (n = this.cbs).onerror) === null || s === void 0 || s.call(n, new Error(".write() after done!"));
      return;
    }
    this.buffers.push(t), this.tokenizer.running && (this.tokenizer.write(t), this.writeIndex++);
  }
  end(t) {
    var n, s;
    if (this.ended) {
      (s = (n = this.cbs).onerror) === null || s === void 0 || s.call(n, new Error(".end() after done!"));
      return;
    }
    t && this.write(t), this.ended = true, this.tokenizer.end();
  }
  pause() {
    this.tokenizer.pause();
  }
  resume() {
    for (this.tokenizer.resume(); this.tokenizer.running && this.writeIndex < this.buffers.length; ) this.tokenizer.write(this.buffers[this.writeIndex++]);
    this.ended && this.tokenizer.end();
  }
  parseChunk(t) {
    this.write(t);
  }
  done(t) {
    this.end(t);
  }
};
function ec0(e9, t) {
  let n = new Vv(void 0, t);
  return new wC(n, t).end(e9), n.root;
}
var YBt = Gs0((e9, t, n, s) => t.xmlMode || t._useHtmlParser2 ? ec0(e9, t) : qx0(e9, t, n, s));
var Pr = Ks0(YBt, (e9, t) => t.xmlMode || t._useHtmlParser2 ? KG(e9, t) : zx0(e9));
var Cq = C0(referenceBuiltin3, 1);
var yf0 = "https://hxqapi.hiyun.tv";
var RWt = "HanjuTV/6.8 (V2238A; Android 12; Scale/2.00)";
var v6e = "6.8";
var CWt = "a_8260";
var NWt = "vivo";
var OWt = 12096e5;
var Af0 = "34F9Q53w/HJW8E6Q";
var DWt = "2E159Q/Z8979WckQ";
var PWt = "f349wghhe784tqwh";
var BWt = "d3w8hf94fidk38lk";
var LWt = "FishHxq@Transit!";
var MWt = ["HxqSpiderConfig!", "Hxqfish20260000!"];
var UWt = "GIpxY0JPylRx";
var $Wt = [["\u84DD\u5149HDR", "11", "1"], ["\u84DD\u51491080P", "10", "1"], ["\u9AD8\u6E05720P", "2", "0"], ["\u6807\u6E05480P", "1", "0"]];
function kf0(e9 = {}) {
  let t = gf0(e9.config?.hanxiaoquan?.url || yf0), n = /* @__PURE__ */ new Map();
  return { meta: { key: "hanxiaoquan", name: "\u97E9\u5267|\u79D2\u64AD", type: 3 }, async init() {
    return Object.assign(t, gf0(t.host)), {};
  }, async home() {
    let s = await v_(t, "/api/series2/arrange/cate", { stype: "1", page: "1" }), c = await v_(t, "/api/index/recommend_v5", { page: "1" }).catch(() => null), l = y6e(c);
    return P0(VWt(s?.groups), jWt(s), l.length ? l : p6e(s?.seriesList));
  }, async category(s) {
    let c = s.body || {}, l = c.extend || {}, d = bf0(c.page || c.pg || 1), m = { stype: String(c.id || c.tid || "1"), page: String(d) };
    g6e(m, "cid", l.cid ?? l.cates, "-1"), g6e(m, "sort", l.sort ?? l.sorts, ""), g6e(m, "year", l.year ?? l.years, "-1");
    let g = await v_(t, "/api/series2/arrange/cate", m), y = p6e(g?.seriesList);
    return Me({ page: d, pagecount: Number(g?.more || 0) > 0 || y.length >= 30 ? d + 1 : d, limit: Math.max(y.length, 1), total: 0, list: y });
  }, async search(s) {
    let c = s.body || {}, l = String(c.wd || c.key || "").trim();
    if (!l) return Me({ list: [] });
    let d = bf0(c.page || c.pg || 1), m = await v_(t, "/api/search/s4", { srefer: "search", type: "0", page: String(d), k: l });
    return Me({ page: d, pagecount: Number(m?.more || 0) > 0 ? d + 1 : d, limit: 20, total: 0, list: p6e(m?.seriesList) });
  }, async detail(s) {
    let c = Array.isArray(s.body?.id) ? s.body.id : [s.body?.id], l = [];
    for (let d of c.filter(Boolean)) l.push(await FWt(t, n, String(d)));
    return l0(l);
  }, async play(s) {
    let c = s.body || {}, l = await WWt(t, n, String(c.id || ""), nVt(s)), d = E0({ parse: 0, ...l });
    return l.episodeName && (d.episodeName = l.episodeName), d;
  }, async proxy(s, c) {
    let l = String(s.params?.sessionId || s.query?.url || ""), d = Ef0(l);
    if (!d) return c.code(400).type("text/plain; charset=utf-8"), "Missing url";
    let m = await eVt(d, wf0()), g = d.indexOf(".m3u8"), y = g >= 0 ? d.slice(g + 5) : "";
    return c.type("application/x-mpegURL; charset=utf-8"), m.replaceAll("/m3u8/", "http://piccc.cdn.51touxiang.com/m3u8/").replace(/\.ts/g, `.ts${y}`);
  } };
}
async function FWt(e9, t, n) {
  let s = await v_(e9, "/api/series2/detail/normal", { sid: n }), c = s?.series || {}, l = Array.isArray(s?.playItems) ? s.playItems : [], d = String(l[0]?.pid || ""), m = d ? await vf0(e9, d) : "", y = GWt(c).map((v) => zn(v[0], l.map((w, T) => {
    let I = String(w?.pid || ""), N = String(w?.serialNo || T + 1), C = String(w?.title || "") ? `\u3010${N}\u3011${w.title}` : `\u7B2C${N}\u96C6`;
    return Ei(C, [n, I, I && I === d ? m : "", v[1], v[2], Sf0(C)].join("|||"));
  })));
  return b0({ id: n, name: String(c.name || ""), pic: w6e(c), remarks: KWt(c), typeName: JWt(Number(c.category || 0)), year: String(c.year || ""), area: "\u97E9\u56FD", actor: String(c.crew || ""), director: "", content: tVt(c.intro || c.shorthand || ""), ...xa(y) });
}
async function WWt(e9, t, n, s) {
  let c = n.split("|||"), l = c[1] || "", d = c[2] || "", m = c[3] || "10", g = c[4] || "0", y = Ef0(c[5] || "");
  if (!l) throw new Error("\u97E9\u5C0F\u5708\u64AD\u653E\u53C2\u6570\u65E0\u6548");
  if (d || (d = await vf0(e9, l)), !d) throw new Error("\u97E9\u5C0F\u5708\u64AD\u653E\u6E90\u83B7\u53D6\u5931\u8D25");
  let v = await HWt(e9, t, l);
  if (!v) throw new Error("\u97E9\u5C0F\u5708\u64AD\u653E\u51ED\u8BC1\u83B7\u53D6\u5931\u8D25");
  let w = Math.floor(Date.now() / 1e3), T = zWt(e9, l, d, m, g, v, w), I = await _6e(`${e9.host}/api/series/rslvV4`, { version: v6e, uuid: e9.deviceId, t: String(w), sq: m, scid: d, re: g, pid: l, dt: "android", ttk: v, sign: T }, Rq(e9));
  if (!I || Number(I.rescode ?? -1) !== 0) throw new Error("\u97E9\u5C0F\u5708\u64AD\u653E\u5730\u5740\u83B7\u53D6\u5931\u8D25");
  let N = Array.isArray(I.datas) ? I.datas : [];
  if (!N.length) throw new Error("\u97E9\u5C0F\u5708\u64AD\u653E\u5730\u5740\u4E3A\u7A7A");
  let C = [], B = [];
  for (let L of N) {
    let q = YWt(e9, String(L?.data || ""));
    q && (C.push(ZWt(q)), B.push(Number(L?.duration || 0)));
  }
  if (!C.length) throw new Error("\u97E9\u5C0F\u5708\u64AD\u653E\u5730\u5740\u4E3A\u7A7A");
  if (C.length === 1) {
    let L = C[0];
    return L.includes(".m3u8") ? { url: `${s}/proxy/hxq/${Sf0(L)}`, header: hf0(), episodeName: y } : { url: L, header: hf0(), episodeName: y };
  }
  return { url: QWt(C, B), header: wf0(), episodeName: y };
}
async function v_(e9, t, n) {
  let s = await _6e(`${e9.host}${t}`, n, Rq(e9));
  return !s || Number(s.rescode ?? -1) !== 0 ? null : b6e(e9, s);
}
async function _6e(e9, t, n) {
  let s = await t0.get(XWt(e9, t), { headers: n, timeout: 15e3, validateStatus: () => true });
  return typeof s.data == "string" ? JSON.parse(s.data) : s.data;
}
function b6e(e9, t) {
  try {
    let n = String(t?.data || "");
    if (!n || n.length <= 20) return t;
    let s = zm(`${e9.uid}${t.ts || ""}`), c = zm(`${s}${Af0}`), l = _f0(k6e(n, c.slice(0, 16), c.slice(16, 32)));
    return l ? JSON.parse(l) : null;
  } catch {
    return null;
  }
}
function Rq(e9) {
  let t = Date.now(), n = zm(e9.uid), s = { emu: 0, ou: 0, it: e9.installTime, iit: e9.installTime, bs: 0, uid: e9.uid, pc: 0, tm: 81, d8m: "0,0,0,0,0,0,0,4", md: "V2238A", maker: "vivo", osv: "12", br: 95, rpc: 0, scc: 2, plc: 6, toc: 19, tsc: 10, ts: t, pa: 1, crec: 0, nw: 2, px: "0", isp: "", ai: e9.said, oa: e9.oa, dpc: 0, dsc: 0, qpc: 0, apad: 0, pk: "com.babycloud.hanju" };
  return { app: "hj", ch: NWt, said: e9.said, uk: A6e(e9.uid, PWt, BWt), vn: v6e, sign: A6e(JSON.stringify(s), n.slice(0, 16), n.slice(16, 32)), "User-Agent": RWt, vc: CWt, "Accept-Encoding": "gzip", Connection: "Keep-Alive" };
}
function VWt(e9) {
  return (Array.isArray(e9) ? e9 : []).map((t) => ({ type_id: String(t?.stype || ""), type_name: String(t?.name || "") })).filter((t) => t.type_id && t.type_name);
}
function jWt(e9) {
  let t = {};
  for (let n of Array.isArray(e9?.groups) ? e9.groups : []) {
    let s = [], c = d6e(n?.cates, true);
    c.length && s.push({ key: "cid", name: "\u7C7B\u578B", value: c });
    let l = d6e(e9?.sorts, false);
    l.length && s.push({ key: "sort", name: "\u6392\u5E8F", value: l });
    let d = d6e(e9?.years, true);
    d.length && s.push({ key: "year", name: "\u5E74\u4EFD", value: d }), n?.stype && (t[String(n.stype)] = s);
  }
  return t;
}
function d6e(e9, t) {
  let n = t ? [{ n: "\u5168\u90E8", v: "-1" }] : [];
  for (let s of Array.isArray(e9) ? e9 : []) n.push({ n: String(s?.name || ""), v: String(s?.value || "") });
  return n.filter((s) => s.n && s.v);
}
function p6e(e9) {
  return (Array.isArray(e9) ? e9 : []).map((t) => u0({ id: t?.sid, name: t?.name, pic: w6e(t), remarks: t?.conerMemo || t?.detailMemo || t?.shorthand || "" })).filter((t) => t.vod_id && t.vod_name);
}
function y6e(e9, t = []) {
  if (Array.isArray(e9)) for (let n of e9) y6e(n, t);
  else if (e9 && typeof e9 == "object") if (e9.sid && e9.name) t.push(u0({ id: e9.sid, name: e9.name, pic: w6e(e9), remarks: e9.conerMemo || e9.detailMemo || e9.shorthand || "" }));
  else for (let n of Object.values(e9)) y6e(n, t);
  return t;
}
function GWt(e9) {
  let t = [];
  for (let n of Array.isArray(e9?.scopeQualities) ? e9.scopeQualities : []) {
    let s = `${n?.name || ""}${n?.resolution || ""}`, c = String(n?.value || ""), l = String(n?.vtype ?? "0");
    s && c && t.push([s, c, l]);
  }
  return t.length ? t : $Wt;
}
async function vf0(e9, t) {
  try {
    let s = (await v_(e9, "/api/series2/episode/detail", { pid: t }))?.playItem?.sources;
    return Array.isArray(s) && s[0] ? String(s[0].scid || "") : "";
  } catch {
    return "";
  }
}
async function HWt(e9, t, n) {
  let s = t.get(n);
  if (s && Date.now() < s.expireAt) return s.token;
  let c = await _6e(`${e9.host}/api/carp/reward/v2`, { scene: "ad_series_play" }, Rq(e9)), l = String(c?.traceId || "");
  if (!l) {
    let N = b6e(e9, c);
    l = String(N?.traceId || "");
  }
  if (!l) return "";
  let d = qWt(e9, n, l), m = { ...Rq(e9), "Content-Type": "application/json", aps: zm(`${d}${UWt}`) }, g = await t0.post(`${e9.host}/api/carp/reward/rp/v2`, d, { headers: m, timeout: 15e3, validateStatus: () => true }), y = typeof g.data == "string" ? JSON.parse(g.data) : g.data;
  if (Number(y?.rescode ?? -1) !== 0) return "";
  let w = b6e(e9, y)?.rewardTokenInfo || {}, T = String(w.token || ""), I = Number(w.expireTime || w.expires || 21600);
  return T && t.set(n, { token: T, expireAt: Date.now() + Math.max(60, I - 60) * 1e3 }), T;
}
function qWt(e9, t, n) {
  let s = zm(e9.uid), c = JSON.stringify({ pid: t, scene: "ad_series_play", traceId: n });
  return JSON.stringify({ data: A6e(c, s.slice(0, 16), s.slice(16, 32)) });
}
function zWt(e9, t, n, s, c, l, d) {
  return zm(`&version=${v6e}&uuid=${e9.deviceId}&udid=${zm(e9.uid)}&ttk=${l}&t=${d}&sq=${s}&scid=${n}&re=${c}&pid=${t}&dt=android&${DWt}`);
}
function YWt(e9, t) {
  if (!t) return "";
  if (/^https?:\/\//i.test(t)) return t;
  for (let c of MWt) {
    let l = k6e(t, LWt, c).trim();
    if (m6e(l)) return h6e(l);
  }
  let n = zm(`${zm(e9.uid)}${Af0}`), s = k6e(t, n.slice(0, 16), n.slice(16, 32)).trim();
  if (m6e(s)) return h6e(s);
  try {
    let c = Buffer.from(t, "base64").toString("utf8").trim();
    if (m6e(c)) return h6e(c);
  } catch {
  }
  return "";
}
function m6e(e9) {
  return !!e9 && (/^https?:\/\//i.test(e9) || e9.startsWith("{"));
}
function h6e(e9) {
  if (!e9.startsWith("{")) return e9;
  try {
    let t = JSON.parse(_f0(e9));
    return String(t.playUrl || t.url || "");
  } catch {
    return e9;
  }
}
function QWt(e9, t) {
  return e9.map((n, s) => `${n}|||${Number(t[s] || 0)}000`).join("***");
}
function ZWt(e9) {
  let t = String(e9 || "");
  if (!t.includes("51touxiang.com")) return t;
  if (t.includes("voldn") || t.includes("hwcpicc") || !t.startsWith("http://")) {
    let n = t.indexOf("://"), s = n >= 0 ? t.indexOf("/", n + 3) : -1;
    if (s >= 0) return `http://piccc.cdn.51touxiang.com${t.slice(s)}`;
  }
  return t;
}
function w6e(e9 = {}) {
  let t = e9.image;
  return t && typeof t == "object" ? String(t.url || t.thumb || "") : typeof t == "string" ? t : String(e9.poster || e9.thumb || "");
}
function KWt(e9 = {}) {
  let t = Number(e9.count || 0);
  return t ? e9.isFinished ? `${t}\u96C6\u5168` : `\u66F4\u65B0\u81F3${t}\u96C6` : "";
}
function JWt(e9) {
  return e9 === 1 ? "\u97E9\u5267" : e9 === 2 ? "\u7EFC\u827A" : e9 === 3 ? "\u7535\u5F71" : "";
}
function XWt(e9, t = {}) {
  let n = new URL(e9);
  for (let [s, c] of Object.entries(t || {})) n.searchParams.set(s, String(c ?? ""));
  return n.toString();
}
async function eVt(e9, t) {
  let n = await t0.get(e9, { headers: t, responseType: "text", transformResponse: [(s) => s], timeout: 15e3, validateStatus: () => true });
  return String(n.data || "");
}
function A6e(e9, t, n) {
  let s = Cq.default.createCipheriv("aes-128-cbc", Buffer.from(t), Buffer.from(n));
  return Buffer.concat([s.update(String(e9), "utf8"), s.final()]).toString("base64");
}
function k6e(e9, t, n) {
  try {
    let s = Cq.default.createDecipheriv("aes-128-cbc", Buffer.from(t), Buffer.from(n));
    return Buffer.concat([s.update(String(e9), "base64"), s.final()]).toString("utf8");
  } catch {
    return "";
  }
}
function _f0(e9) {
  let t = String(e9 || "").trim(), n = Math.max(t.lastIndexOf("}"), t.lastIndexOf("]"));
  return n >= 0 ? t.slice(0, n + 1) : t;
}
function tVt(e9) {
  return String(e9 || "").replace(/<br\s*\/?>/gi, `
`).replace(/<\/?(p|div|h[1-6]|ul|li|ol|section|article)[^>]*>/gi, `
`).replace(/<[^>]*>/g, "").replace(/&nbsp;/g, " ").replace(/&amp;/g, "&").replace(/\s+/g, " ").trim();
}
function g6e(e9, t, n, s) {
  let c = String(n ?? "").trim();
  c && c !== s && (e9[t] = c);
}
function hf0() {
  return { "User-Agent": "tdc.8260" };
}
function wf0() {
  return { "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36" };
}
function zm(e9) {
  return Cq.default.createHash("md5").update(String(e9 || "")).digest("hex");
}
function Iq(e9, t) {
  let n = "";
  for (let s = 0; s < t; s++) n += e9[Math.floor(Math.random() * e9.length)];
  return n;
}
function gf0(e9) {
  return { host: rVt(e9 || yf0), uid: Iq("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz", 20), said: Iq("0123456789abcdef", 16), oa: Iq("0123456789abcdef", 16), installTime: Date.now() - OWt, deviceId: Iq("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ", 32) };
}
function rVt(e9) {
  return String(e9 || "").replace(/\/+$/, "");
}
function bf0(e9) {
  let t = Number.parseInt(e9, 10);
  return Number.isFinite(t) && t > 0 ? t : 1;
}
function nVt(e9) {
  let t = e9.headers?.["x-forwarded-proto"] || "http", n = e9.headers?.host || "127.0.0.1", s = String(e9.url || "").split("?")[0].replace(/\/play$/, "");
  return `${t}://${n}${s}`;
}
function Sf0(e9) {
  return Buffer.from(String(e9 || ""), "utf8").toString("base64url");
}
function Ef0(e9) {
  try {
    return Buffer.from(String(e9 || ""), "base64url").toString("utf8");
  } catch {
    return "";
  }
}
var R1 = C0(referenceBuiltin3, 1);
var Of0 = ["https://apinew.uozvr.com", "https://sdapi.e2wu4ht.com", "https://api.w32z7vtd.com", "https://api.6a7nnf7.com", "https://api.umygrx3.com", "https://api.rmedphk.com"];
var iVt = "MIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQDUM5+/y8sPsWkd1/RQS64X259EUwxFXFE5HlA65MqrxnPs0JqoSRojSDy5QhwvROlaD6TwRQHKMY2OAZ6SnQeUJsChTEFIR9qUkwrs3/MVUMxjsv6JS6Oe/juclyJGTgVmDhB55EafXsD0SQYVj/QXXsxR6ewR5E2kL52yAAD4yQIDAQAB";
var aVt = `-----BEGIN RSA PRIVATE KEY-----
MIICdgIBADANBgkqhkiG9w0BAQEFAASCAmAwggJcAgEAAoGAe6hKrWLi1zQmjTT1
ozbE4QdFeJGNxubxld6GrFGximxfMsMB6BpJhpcTouAqywAFppiKetUBBbXwYsYU
1wNr648XVmPmCMCy4rY8vdliFnbMUj086DU6Z+/oXBdWU3/b1G0DN3E9wULRSwcK
ZT3wj/cCI1vsCm3gj2R5SqkA9Y0CAwEAAQKBgAJH+4CxV0/zBVcLiBCHvSANm0l7
HetybTh/j2p0Y1sTXro4ALwAaCTUeqdBjWiLSo9lNwDHFyq8zX90+gNxa7c5EqcW
V9FmlVXr8VhfBzcZo1nXeNdXFT7tQ2yah/odtdcx+vRMSGJd1t/5k5bDd9wAvYdI
DblMAg+wiKKZ5KcdAkEA1cCakEN4NexkF5tHPRrR6XOY/XHfkqXxEhMqmNbB9U34
saTJnLWIHC8IXys6Qmzz30TtzCjuOqKRRy+FMM4TdwJBAJQZFPjsGC+RqcG5UvVM
iMPhnwe/bXEehShK86yJK/g/UiKrO87h3aEu5gcJqBygTq3BBBoH2md3pr/W+hUM
WBsCQQChfhTIrdDinKi6lRxrdBnn0Ohjg2cwuqK5zzU9p/N+S9x7Ck8wUI53DKm8
jUJE8WAG7WLj/oCOWEh+ic6NIwTdAkEAj0X8nhx6AXsgCYRql1klbqtVmL8+95KZ
K7PnLWG/IfjQUy3pPGoSaZ7fdquG8bq8oyf5+dzjE/oTXcByS+6XRQJAP/5ciy1b
L3NhUhsaOVy55MHXnPjdcTX0FaLi+ybXZIfIQ2P4rb19mVq1feMbCXhz+L1rG8oa
t5lYKFpe8k83ZA==
-----END RSA PRIVATE KEY-----`;
var Df0 = "aLFBMWpxBrIDAD1Si/KVvm41";
var Pf0 = "/guazi/auth";
var oVt = "*&zvdvdvddbfikkkumtmdwqppp?|4Y!s!2br";
var Tf0 = "3.0.4.8";
var sVt = "2606029";
var xVt = "com.v54f07a912.t4ee50f184.dbb1e7669f20260721";
var cVt = "GZ0313";
var Nq = 30;
var uVt = 1800;
var lVt = ["3840", "2160", "1080", "720", "480", "360", "240"];
function Bf0(e9 = {}) {
  let t = pVt(e9.config?.guazi?.hosts || e9.config?.guazi?.url || Of0), n = { db: e9.db, apiHosts: t, siteUrl: t[0], remoteWexConfig: e9.remoteWexConfig, auth: {}, loaded: false, hostIndex: 0, playRef: "http://WJiZxLXA2.com/", playRefLoaded: false };
  return { meta: { key: "guazi", name: "\u74DC\u5B50|\u79D2\u64AD", type: 3 }, async init() {
    return await __(n), await u7(n).catch((s) => console.warn(`[WexAiGuaZi] init auth failed: ${s.message}`)), {};
  }, async home() {
    await __(n), await u7(n);
    let s = await l7(n, "/App/IndexList/index", { ns: "", nt: f7(), pid: "1" }), c = [], l = Array.isArray(s?.list) ? s.list : [];
    for (let d = 1; d < l.length; d++) c.push(...S6e(l[d]?.list));
    return P0(AVt(), kVt(), c);
  }, async category(s) {
    await __(n), await u7(n);
    let c = s.body || {}, l = String(c.id || c.tid || "1"), d = Nf0(c.page || c.pg || 1), m = c.extend || c.filters || {}, g = { area: E6e(m.area, "0"), sub: String(m.sub || m.class || TVt(l)), year: E6e(m.year, "0"), pageSize: String(Nq), sort: E6e(m.sort, "d_id"), page: String(d), tid: l }, y = S6e((await l7(n, "/App/IndexList/indexList", g))?.list);
    return Me({ page: d, pagecount: y.length >= Nq ? d + 1 : d, limit: Nq, total: 0, list: y });
  }, async detail(s) {
    await __(n), await u7(n);
    let c = Array.isArray(s.body?.id) ? s.body.id : [s.body?.id], l = [];
    for (let d of c.filter(Boolean)) l.push(await fVt(n, String(d).split("|")[0]));
    return l0(l);
  }, async play(s) {
    await __(n), await u7(n);
    let c = String(s.body?.id || ""), l = vVt(c);
    if (!Object.keys(l).length) throw new Error("\u74DC\u5B50\u64AD\u653E\u53C2\u6570\u9519\u8BEF");
    let d = l.vod_d_id;
    d && (delete l.vod_d_id, l.vod_id = d), l._client_ts = String(process.hrtime.bigint()), l.mobile_time = String(f7()), l.rand = String(Math.abs(T6e())), l.resolution || (l.resolution = _Vt(c, l.resolution)), l.type = "play";
    let m = await l7(n, "/App/Resource/VurlDetail/showOne", l), g = String(m?.url || "").trim();
    if (!g) throw new Error("\u74DC\u5B50\u64AD\u653E\u5730\u5740\u4E3A\u7A7A");
    await SVt(n);
    let y = await Rf0(n, g);
    if (y === 403 && (await EVt(n), await Dq(n), await Mf0(n), l._client_ts = String(process.hrtime.bigint()), l.mobile_time = String(f7()), l.rand = String(Math.abs(T6e())), m = await l7(n, "/App/Resource/VurlDetail/showOne", l), g = String(m?.url || "").trim(), y = await Rf0(n, g)), !g) throw new Error("\u74DC\u5B50\u64AD\u653E\u5730\u5740\u4E3A\u7A7A");
    return E0({ parse: 0, url: g, header: Uf0(n), format: g.toLowerCase().includes(".m3u8") ? "application/vnd.apple.mpegurl" : void 0 });
  }, async search(s) {
    await __(n), await u7(n);
    let c = s.body || {}, l = String(c.wd || c.key || "").trim();
    if (!l) return Me({ list: [] });
    let d = await l7(n, "/App/Index/findMoreVod", { keywords: l, ns: "", nt: f7(), order_val: "1" }, { useCache: false });
    return Me({ page: Nf0(c.page || c.pg || 1), pagecount: 1, limit: Nq, total: 0, list: S6e(d?.list) });
  } };
}
async function fVt(e9, t) {
  let s = (await l7(e9, "/App/IndexPlay/playInfo", { token_id: e9.auth.token_id || "", vod_id: t, mobile_time: f7(), token: await gVt(e9) }))?.vodInfo || {};
  if (!s.vod_name) throw new Error("\u74DC\u5B50\u8BE6\u60C5\u83B7\u53D6\u5931\u8D25");
  let c = await l7(e9, "/App/Resource/Vurl/show", { vurl_cloud_id: "2", vod_d_id: t }), l = [];
  for (let [m, g] of (Array.isArray(c?.list) ? c.list : []).entries()) {
    let y = g?.play || {}, v = String(g?.title || "") || `\u7B2C${m + 1}\u96C6`, w = "", T = [];
    for (let N of lVt) {
      let C = y[N];
      if (!C || String(C.show_type || "") === "2") continue;
      let B = String(C.param || "");
      B && (T.push(N), w || (w = B));
    }
    if (!w) continue;
    let I = `${w}&_client_ts=${process.hrtime.bigint()}`;
    T.length && (I += `||${T.join("@")}`), l.push(Ei(v, I));
  }
  let d = l.length ? [zn(dVt(e9.remoteWexConfig, "\u74DC\u5B50"), l)] : [];
  return b0({ id: t, name: s.vod_name || "", pic: s.vod_pic || "", year: s.vod_year || "", actor: s.vod_actor || "", director: s.vod_director || "", content: s.vod_use_content || "", ...xa(d) });
}
function dVt(e9, t) {
  return String(e9?.Wexconfig?.vodfrom || e9?.snapshot?.()?.vodfrom || t).trim() || t;
}
function pVt(e9) {
  let n = (Array.isArray(e9) ? e9 : String(e9 || "").split(/[\s,，|]+/)).map(PVt).filter(Boolean);
  return [...new Set(n.length ? n : Of0)];
}
async function __(e9) {
  e9.loaded || (e9.loaded = true, e9.db && (e9.auth = await e9.db.get(Pf0, {})), (!e9.auth || typeof e9.auth != "object") && (e9.auth = {}), e9.auth.device_key || (e9.auth.device_key = $f0(20), e9.auth.token = "", e9.auth.token_id = "", e9.auth.registered = false, e9.auth.token_refreshed_at = 0, await eN(e9)), e9.auth.device_id || (e9.auth.device_id = String(86415006e7 + Math.floor(Math.random() * 1e4)), await eN(e9)));
}
async function u7(e9, t = false) {
  let n = f7();
  return e9.auth.token && !t && n - Number(e9.auth.token_refreshed_at || 0) < uVt || e9.auth.token && await hVt(e9) ? true : If0(e9);
}
async function If0(e9) {
  let t = null, n = e9.hostIndex || 0;
  for (let s = 0; s < e9.apiHosts.length; s++) {
    e9.hostIndex = (n + s) % e9.apiHosts.length, e9.siteUrl = e9.apiHosts[e9.hostIndex], e9.auth.token = "", e9.auth.token_id = "";
    try {
      return await Dq(e9);
    } catch (c) {
      t = c, e9.auth.token = "", e9.auth.token_id = "";
    }
  }
  throw t || new Error("\u74DC\u5B50\u767B\u5F55\u5931\u8D25");
}
async function Lf0(e9) {
  let t = await tN(e9, "/App/Authentication/Device/signIn", rN(e9, "", { new_key: e9.auth.device_key, old_key: Df0 }));
  return Pq(e9, t);
}
async function Dq(e9) {
  if (e9.auth.token) return true;
  try {
    return await Lf0(e9);
  } catch (t) {
    return console.warn(`[WexAiGuaZi] signIn failed, try signUp: ${t.message}`), mVt(e9);
  }
}
async function mVt(e9) {
  try {
    let t = await tN(e9, "/App/Authentication/Device/signUp", rN(e9, "", { new_key: e9.auth.device_key, old_key: Df0, phone_type: 1, code: "" }));
    return Pq(e9, t);
  } catch (t) {
    if (/用户已经存在|设备号登入/.test(String(t?.message || t))) return e9.auth.registered = true, await eN(e9), Lf0(e9);
    throw t;
  }
}
async function hVt(e9) {
  try {
    let t = await tN(e9, "/App/Authentication/Authenticator/refresh", rN(e9, e9.auth.token || "", {}));
    return Pq(e9, t);
  } catch (t) {
    return console.warn(`[WexAiGuaZi] token refresh failed: ${t.message}`), false;
  }
}
async function Mf0(e9) {
  e9.auth.token || await Dq(e9);
  let t = await tN(e9, "/App/Authentication/Authenticator/refresh", rN(e9, e9.auth.token || "", {}));
  return Pq(e9, t);
}
function Pq(e9, t) {
  if (!t?.token) throw new Error(`\u74DC\u5B50\u8BA4\u8BC1\u672A\u8FD4\u56DE token: ${JSON.stringify(t || {}).slice(0, 200)}`);
  return e9.auth.token = String(t.token || ""), e9.auth.token_id = String(t.app_user_id || e9.auth.token_id || ""), e9.auth.registered = true, e9.auth.token_refreshed_at = f7(), eN(e9).then(() => true);
}
async function eN(e9) {
  e9.db && await e9.db.set(Pf0, e9.auth);
}
async function gVt(e9) {
  return e9.auth.token || await u7(e9), e9.auth.token || "";
}
async function l7(e9, t, n, s = {}) {
  t.startsWith("/App/Authentication/") || await u7(e9);
  let c = null;
  for (let l = 0; l < 3; l++) {
    let d = e9.hostIndex || 0;
    for (let g = 0; g < e9.apiHosts.length; g++) {
      e9.hostIndex = (d + g) % e9.apiHosts.length, e9.siteUrl = e9.apiHosts[e9.hostIndex];
      try {
        return await tN(e9, t, rN(e9, e9.auth.token || "", n), s);
      } catch (y) {
        c = y;
      }
    }
    e9.auth.token = "", e9.auth.token_id = "";
    let m = false;
    for (let g = 0; g < e9.apiHosts.length && !m; g++) {
      e9.hostIndex = g, e9.siteUrl = e9.apiHosts[g];
      try {
        await Dq(e9), await Mf0(e9), m = true;
      } catch (y) {
        c = y, e9.auth.token = "", e9.auth.token_id = "";
      }
    }
  }
  throw new Error(`\u74DC\u5B50\u63A5\u53E3\u8BF7\u6C42\u5931\u8D25\uFF1A${c?.message || c || t}`);
}
async function tN(e9, t, n) {
  let s = await t0.post(`${e9.siteUrl}${t}`, new URLSearchParams(n), { headers: wVt(e9), timeout: 15e3, validateStatus: () => true }), c = typeof s.data == "string" ? JSON.parse(s.data) : s.data;
  if (Object.prototype.hasOwnProperty.call(c || {}, "code") && Number(c?.code) !== 200) throw new Error(`\u74DC\u5B50\u63A5\u53E3\u5931\u8D25 ${t}: ${c?.msg || s.status}`);
  let l = c?.data;
  if (!l?.keys || !l?.response_key) throw new Error(`\u74DC\u5B50\u63A5\u53E3\u65E0\u6570\u636E\uFF1A${t}`);
  return JSON.parse(yVt(l));
}
function rN(e9, t, n) {
  let s = String(f7()), c = Cf0(16), l = Cf0(16), d = IVt(JSON.stringify(n || {}), c, l), m = CVt(JSON.stringify({ iv: l, key: c })), g = { token_id: "", token: String(t || ""), phone_type: "1", request_key: d, app_id: "1", time: s, keys: m, phone_model: DVt(), ad_version: "1" };
  return g.signature = bVt(g), g;
}
function bVt(e9) {
  return OVt(`token_id=${e9.token_id || ""},token=${e9.token || ""},phone_type=${e9.phone_type || ""},request_key=${e9.request_key || ""},app_id=${e9.app_id || ""},time=${e9.time || ""},keys=${e9.keys || ""}${oVt}`);
}
function yVt(e9) {
  let t = NVt(e9.keys), n = JSON.parse(t);
  return RVt(e9.response_key, n.key, n.iv);
}
function AVt() {
  return [{ type_id: "1", type_name: "\u7535\u5F71" }, { type_id: "2", type_name: "\u7535\u89C6\u5267" }, { type_id: "3", type_name: "\u52A8\u6F2B" }, { type_id: "4", type_name: "\u7EFC\u827A" }, { type_id: "64", type_name: "\u77ED\u5267" }, { type_id: "72", type_name: "\u97F3\u4E50" }, { type_id: "74", type_name: "AI\u6F2B\u5267" }, { type_id: "73", type_name: "\u7535\u5F71\u89E3\u8BF4" }, { type_id: "71", type_name: "\u4F53\u80B2\u89E3\u8BF4" }, { type_id: "70", type_name: "\u7535\u7ADE\u89E3\u8BF4" }];
}
function kVt() {
  return { 1: [Oq("\u7C7B\u578B", "\u52A8\u4F5C\u7247:5,\u60AC\u7591\u7247:29,\u559C\u5267\u7247:6,\u7231\u60C5\u7247:7,\u79D1\u5E7B\u7247:8,\u6050\u6016\u7247:9,\u5267\u60C5\u7247:10,\u6218\u4E89\u7247:11,\u52A8\u753B\u7247:36,\u7EAA\u5F55\u7247:20,\u707E\u96BE\u7247:38,\u72AF\u7F6A\u7247:61")], 2: [Oq("\u7C7B\u578B", "\u56FD\u4EA7\u5267:12,\u9999\u6E2F\u5267:13,\u53F0\u6E7E\u5267:14,\u6B27\u7F8E\u5267:15,\u65E5\u672C\u5267:16,\u97E9\u56FD\u5267:17,\u6D77\u5916\u5267:18,\u6CF0\u56FD\u5267:19,\u65B0\u52A0\u5761\u5267:69")], 3: [Oq("\u7C7B\u578B", "\u4E2D\u56FD\u52A8\u6F2B:30,\u65E5\u672C\u52A8\u6F2B:31,\u6B27\u7F8E\u52A8\u6F2B:33")], 4: [Oq("\u7C7B\u578B", "\u5927\u9646\u7EFC\u827A:22,\u6E2F\u53F0\u7EFC\u827A:23,\u65E5\u97E9\u7EFC\u827A:24,\u6B27\u7F8E\u7EFC\u827A:25")] };
}
function Oq(e9, t) {
  return { key: "sub", name: e9, value: t.split(",").map((n) => {
    let [s, c = ""] = n.split(":");
    return { n: s, v: c };
  }) };
}
function S6e(e9) {
  return (Array.isArray(e9) ? e9 : []).map((t) => u0({ id: t?.vod_id, name: t?.vod_name, pic: t?.vod_pic, remarks: t?.vod_scroe || t?.vod_score || t?.vod_continu || "" })).filter((t) => t.vod_id && t.vod_name);
}
function vVt(e9) {
  let t = {}, n = String(e9 || "").split("||", 1)[0];
  for (let s of n.split("&")) {
    let c = s.indexOf("=");
    c <= 0 || (t[s.slice(0, c)] = s.slice(c + 1));
  }
  return t;
}
function _Vt(e9, t = "") {
  let n = String(e9 || "").split("||", 2);
  if (!n[1]) return t || "1080";
  let s = "", c = -1;
  for (let l of n[1].split("@")) {
    let d = Number.parseInt(String(l || "").replace(/\D+/g, ""), 10) || 0;
    d > c && (c = d, s = l);
  }
  return s || t || "1080";
}
function wVt(e9) {
  return { "User-Agent": "okhttp/3.12.0", "Content-Type": "application/x-www-form-urlencoded; charset=UTF-8", Ver: Tf0, Version: sVt, "api-ver": Tf0, PackageName: xVt, code: cVt, deviceId: e9.auth.device_id || "", lang: "zh_cn", "Cache-Control": "no-cache", Referer: e9.siteUrl };
}
function Uf0(e9) {
  return { "User-Agent": "Lavf/57.83.100", Referer: e9?.playRef || "http://WJiZxLXA2.com/" };
}
async function SVt(e9, t = false) {
  if (e9.playRefLoaded && !t) return e9.playRef;
  try {
    let n = await l7(e9, "/App/UserInfo/getUserInfo", {}), s = String(n?.playRef || "").trim();
    /^https?:\/\//i.test(s) && (e9.playRef = s), e9.playRefLoaded = true;
  } catch (n) {
    console.warn(`[WexAiGuaZi] load playRef failed: ${n.message}`);
  }
  return e9.playRef;
}
async function Rf0(e9, t) {
  if (!t) return 0;
  try {
    let n = await t0.get(t, { headers: Uf0(e9), timeout: 1e4, maxRedirects: 0, validateStatus: () => true });
    return Number(n.status || 0);
  } catch (n) {
    return console.warn(`[WexAiGuaZi] play check failed: ${n.message}`), 0;
  }
}
async function EVt(e9) {
  e9.auth.token = "", e9.auth.token_id = "", e9.auth.device_key = $f0(20), e9.auth.registered = false, e9.auth.token_refreshed_at = 0, await eN(e9), console.log("[WexAiGuaZi] play resetAuth");
}
function E6e(e9, t) {
  return e9 == null || e9 === "" ? t : String(e9);
}
function TVt(e9) {
  return String(e9) === "1" ? "5" : String(e9) === "2" ? "12" : String(e9) === "3" ? "30" : String(e9) === "4" ? "22" : "";
}
function IVt(e9, t, n) {
  let s = R1.default.createCipheriv("aes-128-cbc", Buffer.from(t), Buffer.from(n));
  return Buffer.concat([s.update(String(e9), "utf8"), s.final()]).toString("hex").toUpperCase();
}
function RVt(e9, t, n) {
  let s = R1.default.createDecipheriv("aes-128-cbc", Buffer.from(t), Buffer.from(n));
  return Buffer.concat([s.update(Buffer.from(String(e9 || ""), "hex")), s.final()]).toString("utf8");
}
function CVt(e9) {
  let t = `-----BEGIN PUBLIC KEY-----
${iVt}
-----END PUBLIC KEY-----`;
  return R1.default.publicEncrypt({ key: t, padding: R1.default.constants.RSA_PKCS1_PADDING }, Buffer.from(String(e9), "utf8")).toString("base64");
}
function NVt(e9) {
  return R1.default.privateDecrypt({ key: aVt, padding: R1.default.constants.RSA_PKCS1_PADDING }, Buffer.from(String(e9 || ""), "base64")).toString("utf8");
}
function OVt(e9) {
  return R1.default.createHash("md5").update(String(e9 || "")).digest("hex").toUpperCase();
}
function $f0(e9) {
  return R1.default.randomBytes(e9).toString("hex").toUpperCase();
}
function Cf0(e9) {
  let t = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789", n = "";
  for (let s = 0; s < e9; s++) n += t[T6e(t.length)];
  return n;
}
function T6e(e9 = 2147483647) {
  return R1.default.randomInt(0, e9);
}
function DVt() {
  return "xiaomi-22081212c";
}
function f7() {
  return Math.floor(Date.now() / 1e3);
}
function PVt(e9) {
  return String(e9 || "").replace(/\/+$/, "");
}
function Nf0(e9) {
  let t = Number.parseInt(e9, 10);
  return Number.isFinite(t) && t > 0 ? t : 1;
}
var Mq = C0(referenceBuiltin3, 1);
var YVt = "https://u.yyxdmn.com/api";
var QVt = "aZ9$kU5%qI7=yC2=zH2#gM0@pX7^wF3a";
var ZVt = "hY2&tN3]kF7,dL7=";
var KVt = "zD9[bM4~sF4~uY2)";
var JVt = "IysJHCZ2Z7HBEoPPKC8nXIibjGHkKNrc";
var O6e = "lt.ruxiangsuisu.cn";
var XVt = "\u60A6\u60A6";
var qf0 = 20;
var ejt = "14";
var tjt = "Pixel 7";
var rjt = "Google";
var njt = "tjsp_sp01";
var ijt = "tianjishipin";
var ajt = "51000";
var ojt = "com.wfighter.zmz";
function Qf0(e9 = {}) {
  let t = { host: Cjt(e9.config?.wexYueYue?.url || YVt), db: e9.db, remoteWexConfig: e9.remoteWexConfig, token: "", deviceId: wjt(e9.config, e9.remoteWexConfig), deviceIdPromise: null, ua: String(e9.config?.wexYueYue?.ua || ""), channelCode: njt, appId: ijt, badci: "", initPromise: null };
  return { meta: { key: "wexYueYue", name: "\u60A6\u60A6|\u79D2\u64AD", type: 3 }, async init() {
    return await Gy(t), {};
  }, async home() {
    await Gy(t);
    let n = await S_(t, "/new_type/list_v2", "");
    return fjt(n);
  }, async category(n) {
    await Gy(t);
    let s = n.body || {}, c = s.extend || s.filters || {}, l = Yf0(s.page || s.pg || 1), d = oN(c.class || c.type), m = await S_(t, "/new_search/screen_v2", { area: oN(c.area), sort: oN(c.sort), type: d, year: oN(c.year), pn: String(l), type_id: oN(c.cateId, s.id || s.tid || "") });
    return Me({ page: l, pagecount: l + 1, limit: qf0, total: 0, list: zf0(m) });
  }, async detail(n) {
    await Gy(t);
    let s = Array.isArray(n.body?.id) ? n.body.id : [n.body?.id], c = [];
    for (let l of s.filter(Boolean)) c.push(await sjt(t, String(l)));
    return l0(c);
  }, async play(n) {
    await Gy(t);
    let s = String(n.body?.id || "").split("|||");
    if (s.length < 4) throw new Error("\u60A6\u60A6\u64AD\u653E\u53C2\u6570\u9519\u8BEF");
    let c = await S_(t, "/new_video/collection_v2", { sig: "", nc_token: "", code: "", phone: "", session_id: "", vod_id: s[3], collection_id: s[0], vod_token: s[1], cur_time: s[2] }), l = xN(c)?.result || {};
    if (Rjt(l)) {
      let T = String(l.check_page_url || "").trim();
      throw console.warn(`[WexAiYueYue] play verify required, vodId=${s[3]}, collectionId=${s[0]}, checkUrl=${T}`), new Error("\u60A6\u60A6\u89E6\u53D1\u6ED1\u5757\u6821\u9A8C\uFF0C\u5F53\u524D\u8BBE\u5907ID\u9700\u8981\u9A8C\u8BC1");
    }
    let d = String(l.vod_url || "").trim(), m = String(l.ck || "").trim();
    if (!d || !m) throw new Error("\u60A6\u60A6\u64AD\u653E\u5730\u5740\u4E3A\u7A7A");
    let g = new URL(d), y = `${g.protocol}//${g.host}`, v = g.search ? `&extra=${d7(g.search.slice(1))}` : "", w = `${yjt(n)}/proxy/yueyue/m3u8?domain=${d7(y)}&path=${d7(g.pathname)}${v}&ck=${encodeURIComponent(m)}&type=wexfnw.m3u8`;
    return console.log(`[WexAiYueYue] play proxy ckLen=${m.length}, path=${g.pathname}`), E0({ parse: 0, url: w, header: Zf0(t) });
  }, async search(n) {
    await Gy(t);
    let s = n.body || {}, c = String(s.wd || s.key || "").trim();
    if (!c) return Me({ list: [] });
    let l = Yf0(s.page || s.pg || 1), d = await S_(t, "/new_search/result_v2", { kw: c, pn: String(l) });
    return Me({ page: l, pagecount: l + 1, limit: qf0, total: 0, list: zf0(d) });
  }, async proxy(n, s) {
    return ujt(t, n, s);
  } };
}
async function sjt(e9, t) {
  let n = await S_(e9, "/new_video/result_v2", { sig: "", nc_token: "", code: "", phone: "", session_id: "", vod_id: t }), s = xN(n)?.result;
  if (!s) throw new Error("\u60A6\u60A6\u8BE6\u60C5\u83B7\u53D6\u5931\u8D25");
  let c = [];
  for (let l of sN(s.vod_collection)) {
    let d = String(l?.title || "").trim(), m = String(l?.id || "").trim();
    !d || !m || c.push(Ei(d, `${m}|||${l?.vod_token || ""}|||${l?.cur_time || ""}|||${t}`));
  }
  return b0({ id: t, name: s.vod_name || "", pic: s.vod_pic || "", year: s.vod_year || "", area: s.vod_area || "", tag: s.vod_tag || "", content: _jt(s.vod_blurb || ""), actor: s.vod_actor || "", director: s.vod_director || "", ...xa([zn(bjt(e9.remoteWexConfig, XVt), c)]) });
}
async function Gy(e9) {
  e9.token && e9.badci || (e9.initPromise || (e9.initPromise = xjt(e9).finally(() => {
    e9.initPromise = null;
  })), await e9.initPromise);
}
async function xjt(e9) {
  try {
    await mjt(e9);
    let t = await S_(e9, "/new_public/init_v2", { invited_by: "", ua: e9.ua, is_install: "0" }, { skipInit: true }), s = (xN(t)?.result || {}).user_info || {};
    e9.token = String(s.token || e9.token || ""), e9.appId = String(s.app_id || e9.appId), e9.channelCode = String(s.channel_code || e9.channelCode), e9.badci = P6e("10"), console.log(`[WexAiYueYue] init ok token=${e9.token ? "yes" : "no"}, appId=${e9.appId}, channel=${e9.channelCode}`);
  } catch (t) {
    console.warn(`[WexAiYueYue] init failed: ${t.message}`), e9.badci = e9.badci || P6e("10");
  }
}
async function S_(e9, t, n, s = {}) {
  !s.skipInit && !e9.badci && await Gy(e9);
  let c = await t0.post(`${e9.host}${t}`, cjt(n), { headers: pjt(e9), timeout: 15e3, responseType: "text", transformResponse: [(d) => d], validateStatus: (d) => d >= 200 && d < 500 });
  if (c.status >= 400) throw new Error(`\u60A6\u60A6\u8BF7\u6C42\u5931\u8D25 ${c.status}`);
  let l = gjt(String(c.data || ""), QVt, ZVt);
  if (!l) {
    let d = String(c.data || "");
    throw console.warn("[WexAiYueYue] decrypt failed", JSON.stringify({ host: e9.host, path: t, status: c.status, contentType: c.headers?.["content-type"] || "", length: d.length, preview: d.slice(0, 200) })), new Error("\u60A6\u60A6\u914D\u7F6E\u89E3\u5BC6\u5931\u8D25");
  }
  return l;
}
function cjt(e9) {
  if (!e9 || typeof e9 != "object") return String(e9 ?? "");
  if (e9 instanceof URLSearchParams) return e9.toString();
  let t = new URLSearchParams();
  for (let [n, s] of Object.entries(e9)) t.set(n, String(s ?? ""));
  return t.toString();
}
async function ujt(e9, t, n) {
  let s = t.query || {}, c = String(s.type || t.params?.sessionId || ""), l = D6e(s.domain), d = D6e(s.path), m = D6e(s.extra), g = kjt(s.ck);
  if (!l || !d || !g) return n.code(400).type("text/plain; charset=utf-8"), "\u60A6\u60A6\u4EE3\u7406\u53C2\u6570\u9519\u8BEF";
  let y = ljt(l, d, g, m);
  if (c.includes("wexfnw.m3u8") || c.includes("m3u8")) {
    let v = await t0.get(y, { headers: Zf0(e9), timeout: 15e3, responseType: "text", transformResponse: [(C) => C] }), w = d.includes("/") ? d.slice(0, d.lastIndexOf("/") + 1) : "/", T = 0, I = Ajt(t), N = String(v.data || "").split(/\r?\n/).map((C) => {
      let B = C.trim();
      if (!B || B.startsWith("#")) return C;
      try {
        let L = new URL(B, `${l}${w}`), q = `${L.protocol}//${L.host}`, W = L.search ? `&extra=${d7(L.search.slice(1))}` : "";
        return `${I}/proxy/yueyue/${T++}?domain=${d7(q)}&path=${d7(L.pathname)}${W}&ck=${encodeURIComponent(g)}&type=ts`;
      } catch {
        let L = `${w}${B.split("?")[0]}`;
        return `${I}/proxy/yueyue/${T++}?domain=${d7(l)}&path=${d7(L)}&ck=${encodeURIComponent(g)}&type=ts`;
      }
    });
    return n.type("application/vnd.apple.mpegurl; charset=utf-8"), N.join(`
`);
  }
  return n.code(302).header("Location", y).type("text/plain; charset=utf-8"), "302";
}
function ljt(e9, t, n, s = "") {
  let c = Math.floor(Date.now() / 1e3).toString(16).toLowerCase(), l = B6e(`${JVt}${t}${c}`), d = [s, n, `wsSecret=${l}`, `wsTime=${c}`].filter(Boolean).join("&");
  return `${hjt(e9)}${t}?${d}`;
}
function fjt(e9) {
  let t = xN(e9), n = [], s = {};
  for (let c of sN(t?.result)) {
    let l = String(c?.id || "").trim(), d = String(c?.name || "").trim();
    if (!l || !d) continue;
    n.push({ type_id: l, type_name: d });
    let m = [];
    for (let g of sN(c?.msg)) {
      let y = djt(g);
      y && m.push(y);
    }
    m.length && (s[l] = m);
  }
  return P0(n, s);
}
function djt(e9) {
  let t = String(e9?.name || ""), s = { type: ["class", "\u7C7B\u578B"], area: ["area", "\u5730\u533A"], year: ["year", "\u5E74\u4EFD"], sort: ["sort", "\u6392\u5E8F"] }[t];
  if (!s) return null;
  let c = sN(e9?.data).map((l) => String(l || "").trim()).filter((l) => l && l !== "\u5168\u90E8" && l !== "\u6392\u5E8F").map((l) => ({ n: l, v: l }));
  return c.length ? { key: s[0], name: s[1], value: c } : null;
}
function zf0(e9) {
  return sN(xN(e9)?.result).map((t) => u0({ id: t?.id, name: t?.vod_name, pic: t?.vod_pic, remarks: t?.remarks || "" })).filter((t) => t.vod_id && t.vod_name);
}
function pjt(e9) {
  let t = String(Date.now());
  return { "User-Agent": "okhttp/4.9.0", sys_platform: "2", device_id: e9.deviceId, sysrelease: ejt, sign: B6e(`${KVt}${e9.deviceId}${t}`).toUpperCase(), cur_time: t, channel_code: e9.channelCode, mobmodel: tjt, version: ajt, token: e9.token, "log-header": "I am the log request header.", mob_mfr: rjt, package_name: ojt, app_id: e9.appId, "Content-Type": "application/x-www-form-urlencoded" };
}
async function mjt(e9) {
  return e9.deviceId ? e9.deviceId : (e9.deviceIdPromise || (e9.deviceIdPromise = Sjt(e9.db).then((t) => (e9.deviceId = t, t)).finally(() => {
    e9.deviceIdPromise = null;
  })), e9.deviceIdPromise);
}
function Zf0(e9) {
  return { "User-Agent": "Mozi", Accept: "*/*", Badci: e9.badci || P6e("10") };
}
function hjt(e9) {
  if (!O6e) return e9;
  try {
    let t = new URL(e9);
    return t.protocol = "http:", t.host = O6e, t.origin;
  } catch {
    return `http://${O6e}`;
  }
}
function gjt(e9, t, n) {
  try {
    let s = Mq.default.createDecipheriv("aes-256-cbc", Buffer.from(t, "utf8"), Buffer.from(n, "utf8"));
    return Buffer.concat([s.update(Buffer.from(String(e9 || ""), "base64")), s.final()]).toString("utf8");
  } catch {
    return "";
  }
}
function P6e(e9) {
  let t = Date.now(), n = t % 1e3 * 1e3, s = Math.floor(Math.random() * 2047483647) + 1e8, c = Math.floor(Math.random() * 8e3) + 7e3, l = n + c;
  return B6e(`${e9}-${s}-${Math.floor(t / 1e3)}-${n}-${Math.floor(t / 1e3)}-${l}-${Math.floor(t / 1e3)}-${l + c}`);
}
function B6e(e9) {
  return Mq.default.createHash("md5").update(String(e9 || ""), "utf8").digest("hex");
}
function bjt(e9, t) {
  return String(e9?.Wexconfig?.vodfrom || e9?.snapshot?.()?.vodfrom || t).trim() || t;
}
function yjt(e9) {
  let t = Kf0(e9);
  return `${t.origin}${t.pathname.replace(/\/play$/, "")}`;
}
function Ajt(e9) {
  let t = "/proxy/", n = Kf0(e9), s = n.pathname.indexOf(t);
  return `${n.origin}${s >= 0 ? n.pathname.slice(0, s) : n.pathname}`;
}
function Kf0(e9) {
  let t = e9.headers?.["x-forwarded-proto"] || "http", n = e9.headers?.host || "127.0.0.1", s = String(e9.url || "/");
  if (/^https?:\/\//i.test(s)) {
    let l = new URL(s);
    return { origin: l.origin, pathname: l.pathname };
  }
  let c = s.split("?")[0] || "/";
  return { origin: `${t}://${n}`, pathname: c.startsWith("/") ? c : `/${c}` };
}
function d7(e9) {
  return Buffer.from(String(e9 || ""), "utf8").toString("base64url");
}
function D6e(e9) {
  try {
    return Buffer.from(String(e9 || ""), "base64url").toString("utf8");
  } catch {
    return "";
  }
}
function kjt(e9) {
  try {
    let t = decodeURIComponent(String(e9 || ""));
    return vjt(t) || t;
  } catch {
    return String(e9 || "");
  }
}
function vjt(e9) {
  let t = String(e9 || "").trim();
  if (!t) return "";
  for (let n of ["base64url", "base64"]) try {
    let s = Buffer.from(t, n).toString("utf8");
    if (/^[\x09\x0a\x0d\x20-\x7e]+$/.test(s) && s.includes("=")) return s;
  } catch {
  }
  return "";
}
function xN(e9) {
  if (e9 && typeof e9 == "object") return e9;
  try {
    return JSON.parse(String(e9 || "{}"));
  } catch {
    return {};
  }
}
function sN(e9) {
  return Array.isArray(e9) ? e9 : [];
}
function Yf0(e9, t = 1) {
  let n = Number.parseInt(e9, 10);
  return Number.isFinite(n) && n > 0 ? n : t;
}
function oN(e9, t = "") {
  return e9 == null ? String(t || "") : String(e9);
}
function _jt(e9) {
  return String(e9 || "").replace(/<[^>]*>/g, "").trim();
}
function Lq(e9) {
  let t = String(e9 || "").trim().toLowerCase();
  return /^[0-9a-f]{16}$/.test(t) ? t : "";
}
function wjt(e9, t) {
  let n = Lq(e9?.wexYueYue?.deviceId || e9?.yueyueDeviceId);
  if (n) return n;
  let s = t?.Wexconfig || t?.snapshot?.() || {};
  return Lq(s.yueyueDeviceId || s.yueyue_device_id || s.yydeviceid || s.yueyueid);
}
async function Sjt(e9) {
  let t = Lq(process.env.ANDROID_ID || process.env.WEX_YUEYUE_ANDROID_ID);
  if (t) return t;
  let n = Lq(await Ejt(e9));
  return n || Tjt(e9);
}
async function Ejt(e9) {
  try {
    return e9?.get ? await e9.get("/spider/wexYueYue/deviceId", "") : "";
  } catch {
    return "";
  }
}
async function Tjt(e9) {
  let t = Ijt(16);
  try {
    await e9?.set?.("/spider/wexYueYue/deviceId", t, { notify: false });
  } catch {
  }
  return t;
}
function Ijt(e9) {
  let t = "0123456789abcdef", n = Mq.default.randomBytes(e9), s = "";
  for (let c = 0; c < e9; c++) s += t[n[c] % t.length];
  return s;
}
function Rjt(e9) {
  if (!e9 || typeof e9 != "object") return false;
  let t = Number(e9.vid), n = String(e9.check_page_url || "").trim(), s = String(e9.vod_url || "").trim();
  return t === 1 && n || /\/2023\/03\/301159\/xl01\/index2\.m3u8/i.test(s);
}
function Cjt(e9) {
  return String(e9 || "").replace(/\/+$/, "");
}
var U6e = C0(referenceBuiltin3, 1);
var Njt = "https://www.sizhengxt.com";
var Ojt = "cb808529bae6b6be45ecfab29a4889bc";
var Xf0 = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/118.0.0.0 Safari/537.36";
var Djt = 20;
function ed0(e9 = {}) {
  let t = { site: Hjt(e9.config?.wencai?.url || Njt), remoteWexConfig: e9.remoteWexConfig, deviceId: jjt() };
  return { meta: { key: "wencai", name: "\u6587\u91C7|\u79D2\u64AD", type: 3 }, async init() {
    return {};
  }, async home() {
    let n = await cN(t, "/api/mw-movie/anonymous/home/hotSearch");
    return P0(Ujt(), {}, L6e(n?.data));
  }, async category(n) {
    let s = n.body || {}, c = s.extend || s.filters || {}, l = Jf0(s.page || s.pg || 1), d = M6e(c.cateId, s.id || s.tid || ""), m = M6e(c.area), g = M6e(c.year), y = rd0({ area: m, pageNum: l, type1: d, year: g }), v = await cN(t, "/api/mw-movie/anonymous/video/list", y), w = L6e(v?.data?.list);
    return Me({ page: l, pagecount: w.length >= Djt ? l + 1 : l, limit: Math.max(w.length, 1), total: 0, list: w });
  }, async detail(n) {
    let s = Array.isArray(n.body?.id) ? n.body.id : [n.body?.id], c = [];
    for (let l of s.filter(Boolean)) c.push(await Pjt(t, String(l)));
    return l0(c);
  }, async play(n) {
    let c = String(n.body?.id || "").split("|||");
    if (c.length < 2) throw new Error("\u6587\u91C7\u64AD\u653E\u53C2\u6570\u9519\u8BEF");
    let l = await cN(t, "/api/mw-movie/anonymous/v2/video/episode/url", { id: c[1], nid: c[0] }), d = $6e(l?.data?.list)[0]?.url || "";
    if (!d) throw new Error("\u6587\u91C7\u64AD\u653E\u5730\u5740\u4E3A\u7A7A");
    return E0({ parse: 0, url: d, header: Mjt(t), format: String(d).toLowerCase().includes(".m3u8") ? "application/vnd.apple.mpegurl" : void 0 });
  }, async search(n) {
    let s = n.body || {}, c = String(s.wd || s.key || "").trim();
    if (!c) return Me({ list: [] });
    let l = Jf0(s.page || s.pg || 1), d = await cN(t, "/api/mw-movie/anonymous/video/searchByWord", { keyword: c, pageNum: l, pageSize: 8 });
    return Me({ page: l, pagecount: 1, limit: 8, total: 0, list: L6e(d?.data?.result?.list) });
  } };
}
async function Pjt(e9, t) {
  let s = (await cN(e9, "/api/mw-movie/anonymous/video/detail", { id: t }))?.data;
  if (!s) throw new Error("\u6587\u91C7\u8BE6\u60C5\u83B7\u53D6\u5931\u8D25");
  let c = [];
  for (let [l, d] of $6e(s.episodeList).entries()) {
    let m = String(d?.name || "").trim() || `\u7B2C${l + 1}\u96C6`;
    c.push(Ei(m, `${d?.nid || ""}|||${t}|||${m}`));
  }
  return b0({ id: t, name: s.vodName || "", pic: s.vodPic || "", year: s.vodYear || "", content: s.vodContent || "", actor: s.vodActor || "", director: s.vodDirector || "", ...xa([zn($jt(e9.remoteWexConfig, "\u6587\u91C7"), c)]) });
}
async function cN(e9, t, n = {}) {
  let s = td0(n), c = `${e9.site}${t}${s ? `?${s}` : ""}`, l = await Bjt(c, Ljt(e9, n));
  return JSON.parse(l);
}
async function Bjt(e9, t) {
  let n = await t0.get(e9, { headers: t, timeout: 15e3, responseType: "text", transformResponse: [(s) => s], validateStatus: (s) => s >= 200 && s < 500 });
  if (n.status >= 400) throw new Error(`\u6587\u91C7\u8BF7\u6C42\u5931\u8D25 ${n.status}`);
  return typeof n.data == "string" ? n.data : JSON.stringify(n.data);
}
function Ljt(e9, t = {}) {
  let n = Gjt();
  return { "User-Agent": Xf0, Accept: "application/json, text/plain, */*", "client-type": "1", authorization: "", deviceId: e9.deviceId, t: n, sign: Fjt(t, n), Referer: `${e9.site}/` };
}
function Mjt(e9) {
  return { "User-Agent": Xf0, Referer: e9.site };
}
function Ujt() {
  return [{ type_id: "1", type_name: "\u7535\u5F71" }, { type_id: "2", type_name: "\u7535\u89C6\u5267" }, { type_id: "3", type_name: "\u7EFC\u827A" }, { type_id: "4", type_name: "\u52A8\u6F2B" }];
}
function L6e(e9) {
  return $6e(e9).map((t) => u0({ id: t?.vodId, name: t?.vodName, pic: t?.vodPic, remarks: t?.vodRemarks || "" })).filter((t) => t.vod_id && t.vod_name);
}
function $jt(e9, t) {
  return String(e9?.Wexconfig?.vodfrom || e9?.snapshot?.()?.vodfrom || t).trim() || t;
}
function Fjt(e9, t) {
  let n = td0(e9, false), s = `${n ? `${n}&` : ""}key=${Ojt}&t=${t}`;
  return Vjt(Wjt(s));
}
function td0(e9, t = true) {
  return Object.keys(rd0(e9)).sort().map((n) => `${n}=${t ? encodeURIComponent(e9[n]) : e9[n]}`).join("&");
}
function rd0(e9) {
  let t = {};
  for (let [n, s] of Object.entries(e9 || {})) {
    let c = String(s ?? "");
    !c || c === "undefined" || c === "null" || (t[n] = c);
  }
  return t;
}
function Wjt(e9) {
  return U6e.default.createHash("md5").update(String(e9 || ""), "utf8").digest("hex");
}
function Vjt(e9) {
  return U6e.default.createHash("sha1").update(String(e9 || ""), "utf8").digest("hex");
}
function jjt() {
  return "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx".replace(/[xy]/g, (e9) => {
    let t = Math.floor(Math.random() * 16);
    return (e9 === "x" ? t : t & 3 | 8).toString(16);
  });
}
function Gjt() {
  return String(Date.now());
}
function $6e(e9) {
  return Array.isArray(e9) ? e9 : [];
}
function Jf0(e9, t = 1) {
  let n = Number.parseInt(e9, 10);
  return Number.isFinite(n) && n > 0 ? n : t;
}
function M6e(e9, t = "") {
  return e9 == null ? String(t || "") : String(e9);
}
function Hjt(e9) {
  return String(e9 || "").replace(/\/+$/, "");
}
function Uq() {
  let e9 = ["WQZdKCkqmhjRWP3dVq", "y0RdHH5nWRmpWPjd", "WOqDWONcIqi", "WQ7dGYe", "m8k6WRLXW7u", "W7lcHx7dPW", "W7aPxGKDg8otga", "m8kwWQvVW6C", "bCoTh1JcSKBcMW", "qZpcQKxcSa", "W6hdU0i4WOC", "crqMkX8", "DgRdMhSv", "WO1dhCkAWPK", "tLfRsfNdKaX4kx/cR2/dVq", "W4RdGX0QEq", "wv8o", "omoAjqxcMa", "W5ZcL8kyWPb2", "W6pdV1e6WOu", "AWldT8oU", "EKRcI0FcVG", "W5lcGmkuWQf6", "W7vwjCkAWRii", "WRVdRaOqpspdOd3dOG", "tCk/WPzjW70", "WRZcRmoWW67dPCkB", "xrdcN8kZW74", "W7FdPsuUvq", "W4CtW6bXWRe", "emoDkJhcOW", "k8k0WQm9", "W4BdIcxcIG", "WODADKrFyeFdJ2LfWO/dUcG", "kXRcHGTK", "xrCfWPldUq", "WRxcMgmVcW", "EfhcONNcQq", "W6VdMCoTWRtcIG", "WQfMc8kGWOa", "nspdNJC", "WPVdUCo7Cq", "ph/dKMVdP8kOWQuioGy", "W7tdTeThWR9TW5akbLFdKCoIW4a", "W78wWQLtm2TwWO0", "zZq8WPVdGa", "W7ldValcMGDx", "DqxcGWq", "AJtdLSo8WQO", "W64OW4HLWOS", "WPlcHCo0W6/cKa", "hvbAWOvstKKHWQFdMmkngaa", "WPVdTmkTvHrEiL3dNCoR", "BeLBWOex", "WQldQmkyuZe", "W4ZdKJZcVmo+", "W4FcGmkrWQzz", "WR8lWPBcVJa", "fsCUkt0", "pCoaW5SHWQ1rWOGxw3utWOi", "tHJdRSo1WPSP", "CmoPj1FcLq", "W583W4T9WPu", "W77dVHShDG", "tbldQCoHWOO", "WQ7cOqWgW4i6WOehoxS", "WRVcLCokW4/cNG", "WQZcQmoZW6FcSSomWOm", "Et3cImkNW5i", "WQxdSCkuEZS", "W5xdIHOUAfa", "gmo4ea", "W77dLCoPWPFcQG", "WQJcMwqufa", "W4pcHSk8e1W", "juVdHdmY", "omkaWOXUW5q", "ygHmWOWg", "CIpcJCkMFW", "W6FdU38", "osFcI1lcM8k8W4yc", "zhVcJw3cP8kI", "W7/cJ8oLWPZdGa", "WQtdSbWrW6HNWOmdjvC", "W5RdPCoQWPlcVW", "yJCg", "W7ZdGbdcO8o2", "WQBcQf7cNcL6rv3cUG", "WRlcQmoTW6ZcP8oh", "Ew8JW79L", "W4lcHhahWQO", "BCo8nLFcSG", "qxdcGMlcHq", "W7BcHmkxjePB", "W4KUAJ8l", "WPFdGaBcL2a", "W6C+W7DIWQi", "jmoanthcMq", "bx52WRhdQSkmEmkCv8owW48K", "BWBcLCkyW4q", "nmkGWQu", "WOddKmk2DZC", "xmkRWRLNW64", "W6tdPmo7WQlcTG", "W5bTaSoKWQxcT2VcQG", "w8o+jxJcRa", "FL1NWQCp", "W5mWrZKU", "W4ZcPCkZegK", "W43dN8otWRBcJa", "WO3cILS4fa", "W77cJmo+WRhdVq", "WQpdHsWKWQRcPY3cVmoQ", "W57cRSkRbw8", "j8oeoW7cVq", "uSoUkW", "W4xdVhmgWR8", "WRpdMIxcSeq", "WOpdVCoX", "WR/dIxqSWOrKgW", "W6VdR3zUWOr9ySkfWPBcLa", "WO58iSkwWO4", "sreEW7Wk", "WRLOWQFdRXmOWQDWwmk1", "z2mKW6Hv", "ztBdHCoWWQy", "nCk6WRG6WR8", "W7hdRbG", "yr/cJq", "rIpcR8kzW6i", "W7/cJmodWPFdJW", "WRZcUID/WPmMj8otWOpdGa", "W6i5mbWz", "EmouffNcIq", "WO7cVmoNW5lcTq", "EXFdJSo+WRS", "luFcPSoVA8kbWQ9X", "WQFcJ282na", "DWJcIa", "WPNcJb3dNq", "W5NdUXVcMIy", "qeP5", "WPBcSvWoaSooD1CefG", "EIBcT8kJWQu", "se17WQ8", "WQtcSHaF", "WR/cQ8oMWRi", "W57cR8odWRtdPSoPf2WUyq", "BJRcKa", "BGVdHSoWWQa", "krRcGW", "WQ7cPrevW788", "W6uXW5ffWPq", "WRldKZZcV0avWRK", "ltmlhcq", "gZW9nXW", "FCkPWOL3W4W", "W7tcHXKqW70GWRW", "b1BdLW", "WPJdKKP5aCkyW43dVwPV", "EfqaW7TSomkVWQXfWRi", "ErpdSSkXkG", "WRz3oeXws8oCjSkJW75yWQu", "WOa7d8okyG", "beBdJryIWQ4", "W6ZdVSkJW6/cSSoBWOFcGmkaW7G", "n8kWWR8UWQ7dPW", "WPpcKg3dGmkLn8ovW5eWeN3cGG", "WO3cJWCSBfL7WORdKmo8", "W604W7xcV0jZWQmGxmkW", "kKBcQCoIBCoVW4L6C8k3uG", "W7uKW7rsWPK", "W6CMW79ZWRnls8k+W7DB", "qXhdRmo9WOW", "WQRcNwmijG", "gvfAWOzrruqtWRFdK8kdmay", "lIldU8o1W5BdNdiJWOey", "W6BcUvWnlYy", "oJ3cMZvF", "EIRdTmoRWR8", "W5ldRSoqqJJdNmoW", "WPJdMIObsa", "W64tFtGj", "WRFdMs3cGuW", "WQZdKYlcTfuE", "W5ddLZVcMtO", "WPH3WP8GW5ldKL/cNmkAWRXd", "WQJdTWuHrq", "cSkSWRiqWPC", "WQhdMIdcVei", "W7tdHXmlEa", "pCkNWR4K", "E3lcIMNcTG", "nCkGWRWRWR/dVq", "WRhcUmo3", "BbFdPG", "WQSgF8olW7fsWQ3cRttcRuxdHh0", "W57cVwm6WO8", "WRNcGmovWRtcQH8tWRK", "WOldOu1osa", "oq7dJCkwWPpdUmodW4ddG34", "W7eYA0u", "WOK/emo3va", "W4RdIKJcNq"];
  return Uq = function() {
    return e9;
  }, Uq();
}
var Ex = z2;
(function(e9, t) {
  let n = z2, s = e9();
  for (; ; ) try {
    if (-parseInt(n(538, "*V)b")) / 1 * (-parseInt(n(545, "K(nn")) / 2) + -parseInt(n(517, "6xL6")) / 3 * (-parseInt(n(452, "]](C")) / 4) + -parseInt(n(491, "e^dk")) / 5 + -parseInt(n(373, "VEc#")) / 6 * (-parseInt(n(509, "P%dc")) / 7) + parseInt(n(450, "IOS$")) / 8 + -parseInt(n(434, "!w#y")) / 9 * (-parseInt(n(421, "kN$K")) / 10) + -parseInt(n(424, "qqF9")) / 11 * (parseInt(n(482, "(0af")) / 12) === t) break;
    s.push(s.shift());
  } catch {
    s.push(s.shift());
  }
})(Uq, 803149);
var nd0 = [6195 + 1 * -6091, 64, 9878 + -1 * -9305 + -3 * 6371, 166, 7789 + -5 * -266 + -8929 * 1, 3895 + -1 * 3727, -8485 * 1 + -1 * 4835 + -1 * -13463, -4894 + -563 * -10 + -606, -3065 * 1 + 8312 + -5022, 254, -7932 + -8183 * -1, -4190 + -9 * 849 + 12048, -4077 * 1 + 7015 + 6 * -457, -13545 + 13579 * 1, -4914 + 4 * 629 + 349 * 7, 3296 * -3 + -3 * -1523 + 5379, -3679 + 6 * 618, -1 * -1231 + 478 * -17 + -15 * -461, 735 + 5779 * -1 + -5147 * -1, 3 * -866 + -3390 + 6093];
var qjt = [19 * -316 + -9298 + 15436, 4980 + 859 * 3 + -7374, 239, 195, -5183 + -1 * 3909 + -2 * -4673, -7532 + -1273 * -5 + 1201, -48 + 1 * -1002 + 1110, 6 * 1129 + 3 * -1851 + -1211, 50, -869 * -3 + 5120 * 1 + 5 * -1522, 13989 + 6956 * -2];
var zjt = [[Ex(500, "*V)b") + Ex(390, "qqF9"), 1618 + -1226 * -7 + -10151], 803 * 8 + 723 * -11 + 1529, [Ex(430, "mh2(") + Ex(423, "2[ps") + "ac", 567 * 9 + 3495 * -1 + -1536], -650 + -3429 * 2 + -7509 * -1, [Ex(454, "JiCu") + Ex(413, "b3uq") + Ex(396, "kkEM"), -1055 * -3 + 3 * -2001 + 7 * 419], -8615 * 1 + 6574 + 2043, [Ex(385, "VEc#") + Ex(541, "aEvA") + Ex(377, "2[ps"), 3598 + -435 * 8], 3, [Ex(400, "o0s@"), 141]];
function Yjt(e9) {
  let t = Ex, n = { NJQgI: function(s, c) {
    return s(c);
  }, woaRm: function(s, c) {
    return s || c;
  }, eXIDM: t(576, "!w#y") };
  return Buffer[t(398, "bHfy")](n[t(486, "PaWB")](String, n[t(437, "5S5G")](e9, "")), n[t(524, "o0s@")]);
}
function z2(e9, t) {
  e9 = e9 - (-2 * 2377 + 6039 + -912);
  let n = Uq(), s = n[e9];
  if (z2.KsZhfq === void 0) {
    var c = function(y) {
      let v = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789+/=", w = "", T = "";
      for (let I = 0, N, C, B = 0; C = y.charAt(B++); ~C && (N = I % 4 ? N * 64 + C : C, I++ % 4) ? w += String.fromCharCode(255 & N >> (-2 * I & 6)) : 0) C = v.indexOf(C);
      for (let I = 0, N = w.length; I < N; I++) T += "%" + ("00" + w.charCodeAt(I).toString(16)).slice(-2);
      return decodeURIComponent(T);
    };
    let g = function(y, v) {
      let w = [], T = 0, I, N = "";
      y = c(y);
      let C;
      for (C = 0; C < 256; C++) w[C] = C;
      for (C = 0; C < 256; C++) T = (T + w[C] + v.charCodeAt(C % v.length)) % 256, I = w[C], w[C] = w[T], w[T] = I;
      C = 0, T = 0;
      for (let B = 0; B < y.length; B++) C = (C + 1) % 256, T = (T + w[C]) % 256, I = w[C], w[C] = w[T], w[T] = I, N += String.fromCharCode(y.charCodeAt(B) ^ w[(w[C] + w[T]) % 256]);
      return N;
    };
    z2.OfdZHw = g, z2.mwsOrj = {}, z2.KsZhfq = true;
  }
  let l = n[-643 * 3 + 8 * 716 + -1 * 3799], d = e9 + l, m = z2.mwsOrj[d];
  return m ? s = m : (z2.ICHoPP === void 0 && (z2.ICHoPP = true), s = z2.OfdZHw(s, t), z2.mwsOrj[d] = s), s;
}
function Qjt(e9, t) {
  let n = Ex, s = { nRWiO: function(c, l) {
    return c & l;
  }, przSs: function(c, l) {
    return c ^ l;
  }, bZaOp: function(c, l) {
    return c & l;
  }, XWtyP: function(c, l) {
    return c + l;
  }, YaFuM: function(c, l) {
    return c * l;
  } };
  return s[n(456, "zep]")](s[n(469, "t7^k")](e9, s[n(409, "t7^k")](s[n(433, "E9B!")](167, s[n(476, "c@1V")](t, 10274 + 2051 * -5)), -7759 + -1 * 6835 + 31 * 479)), 255);
}
function Zjt(e9) {
  let t = Ex, n = { GRIEe: t(474, "z]*p"), gVHTy: function(m, g) {
    return m < g;
  }, UrMXs: function(m, g) {
    return m ^ g;
  }, huPvu: function(m, g) {
    return m & g;
  }, SzfDY: function(m, g) {
    return m + g;
  }, QACOn: function(m, g) {
    return m * g;
  }, RMHzr: t(478, "qqF9") }, [s, c] = e9, l = Buffer[t(399, "aEvA")](s, n[t(540, "S$V]")]), d = Buffer[t(441, "q&sF")](l[t(518, "E9B!")]);
  for (let m = -6211 * -1 + 1 * 5794 + -5 * 2401; n[t(417, "zep]")](m, l[t(528, "PaWB")]); m++) d[m] = n[t(531, "b3uq")](l[m], n[t(468, "VEc#")](n[t(485, "JiCu")](c, n[t(435, "q&sF")](m, 4650 + -715 * 3 + 1 * -2498)), 608 * -7 + 2 * -2040 + 8591));
  return d[t(502, "&6iJ")](n[t(555, "A&Ck")]);
}
function Kjt(e9) {
  let t = Ex, n = { BNxYi: function(c, l) {
    return c % l;
  }, YKYNp: function(c, l) {
    return c & l;
  }, BvOCb: function(c, l) {
    return c ^ l;
  }, wWqPu: function(c, l) {
    return c & l;
  }, qeUPL: function(c, l) {
    return c + l;
  }, PoFlK: function(c, l) {
    return c * l;
  } }, s = n[t(483, "6xL6")](e9, nd0[t(546, "o0s@")]);
  return n[t(462, "JsbV")](n[t(511, "bHfy")](n[t(514, "c@1V")](nd0[s], n[t(526, "JiCu")](n[t(530, "]](C")](-421 + 1 * 511, n[t(512, "0r[t")](s, 6 * -842 + -7 * 437 + 8124)), 2 * 3286 + -5623 * 1 + 694 * -1)), 821 * -3 + 333 * 27 + -6443), 6107 * -1 + 1635 * -3 + 11267);
}
function Jjt(e9, t) {
  let n = Ex, s = { HUUee: function(c, l) {
    return c < l;
  }, bezeD: function(c, l, d) {
    return c(l, d);
  }, LHwdC: function(c, l) {
    return c & l;
  }, LvFbO: function(c, l) {
    return c + l;
  }, rWhHM: function(c, l) {
    return c + l;
  }, Booqj: function(c, l) {
    return c === l;
  }, MhgBd: function(c, l) {
    return c & l;
  }, InahV: function(c, l) {
    return c - l;
  }, LraHM: function(c, l) {
    return c(l);
  }, HIVnE: function(c, l) {
    return c - l;
  }, YcSFx: function(c, l) {
    return c + l;
  }, aFoJH: function(c, l) {
    return c * l;
  }, GQoNj: function(c, l) {
    return c | l;
  }, bupLl: function(c, l) {
    return c << l;
  }, rXggX: function(c, l) {
    return c >>> l;
  }, WvJDA: function(c, l) {
    return c & l;
  }, kTGeP: function(c, l) {
    return c ^ l;
  }, jUpEf: function(c, l) {
    return c | l;
  }, YgEPb: function(c, l) {
    return c & l;
  }, fPWzH: function(c, l) {
    return c - l;
  }, YjNlT: function(c, l, d) {
    return c(l, d);
  }, diQsl: function(c, l) {
    return c === l;
  }, NWXNs: function(c, l) {
    return c % l;
  }, DORFQ: function(c, l) {
    return c === l;
  }, brNtj: function(c, l) {
    return c & l;
  }, QUnFm: function(c, l) {
    return c === l;
  }, bRPgF: n(447, "2[P9"), iuiOj: function(c, l) {
    return c(l);
  } };
  for (let c = 0; s[n(547, "z]*p")](c, e9[n(431, "(0af")]); c++) switch (s[n(397, "mh2(")](Qjt, e9[c], c)) {
    case 2189 + 2 * -1088:
      t[n(380, "2[P9")] = s[n(451, "OogG")](s[n(403, "E9B!")](s[n(559, "0r[t")](t[n(522, "E9B!")] || -7355 * 1 + -2441 * 1 + 9796, c), t.i || -4157 * -1 + -6006 + 1849), -105837 + 634 * -22 + 1640 * 113);
      break;
    case 2579 * -1 + -1 * 6381 + 8993:
      t.r0 = s[n(508, "o0s@")](t[n(404, "VstS")][t.i], -8988 + 9 * 1027);
      break;
    case 5940 + 3127 * 1 + -1 * 9033:
      t.r1 = s[n(507, "Neo^")](t.i, -610 * 11 + 919 * 1 + 5791 * 1) ? 500 * -2 + -3189 * 1 + 4298 : s[n(375, "Nhba")](t[n(449, "qqF9")][s[n(550, "*V)b")](t.i, 1)], -319 + -638 * -3 + -1340);
      break;
    case -9919 * -1 + 8894 + 9389 * -2:
      t.r2 = s[n(519, "^JN1")](Kjt, t.i);
      break;
    case -2063 * 4 + 1 * -7524 + 15812:
      t.r3 = s[n(444, "PaWB")](s[n(383, "JiCu")](s[n(425, "Neo^")](t.r0, -8686 + -713 * 7 + -4 * -3473), s[n(432, "VstS")](11, t.i)), -1917 * -3 + 24 * -278 + 1176);
      break;
    case -1110 + -3 * -1561 + -3536:
      t.r4 = s[n(533, "!&mc")](s[n(384, "S$V]")](s[n(376, "P%dc")](t.r3, 3), s[n(410, "6xL6")](t.r3, -6664 + 8 * 675 + 1269)), -8857 + 536 * 17);
      break;
    case 1759 * 3 + -6800 + 1561:
      t.r5 = s[n(527, "0r[t")](~s[n(487, "Neo^")](t.r2, t.r1), -11593 + -2962 * -4);
      break;
    case -4318 + 2 * 2307 + -257 * 1:
      t.r6 = s[n(521, "PaWB")](s[n(565, "57f6")](t.r5, -383 * 17 + 184 + 6381 * 1), s[n(552, "57f6")](s[n(553, "5S5G")](~t.r5, 3298 * -2 + -5509 + 12360), 201)), t.r7 = s[n(436, "57f6")](s[n(428, "b3uq")](s[n(465, "JsbV")](~t.r4, -2197 + -3394 * 2 + 660 * 14), -3086 + -500 * -9 + 5 * -272), s[n(532, "^b8V")](t.r4, -1122 + 1 * 898 + 425));
      break;
    case 4382 + -2171 * 2:
      t[n(381, "K(nn")][t.i] = s[n(480, "c@1V")](s[n(561, "]](C")](t.r6, t.r7), 255);
      break;
    case 5880 + -1163 * 5:
      t[n(489, "2[P9")] = t[n(568, "b3uq")][s[n(506, "E9B!")](s[n(488, "A&Ck")](t[n(453, "kkEM")][n(518, "E9B!")], -9387 * -1 + 1 * -8479 + 1 * -907), t.i)] || "";
      break;
    case -2833 + 4 * 542 + 731:
      t[n(543, "sE5w")] = s[n(389, "E9B!")](parseInt, t[n(499, "!w#y")][n(407, "5S5G")]("0x", ""), -20 * 346 + 5375 + 1555);
      break;
    case 1547 * -1 + 18 * 426 + 3027 * -2:
      s[n(496, "]](C")](s[n(544, "kN$K")](t.i, 1), -5997 + -9 * 265 + 762 * 11) ? t[n(543, "sE5w")] -= -2 * 2636 + -2 * -2447 + -1 * -389 : s[n(567, "]](C")](s[n(471, "Nhba")](t.i, 2369 + 4727 * -1 + 787 * 3), -2892 + 1379 * 5 + 1 * -4003) ? t[n(529, "A&Ck")] -= -4 * -1186 + 322 + -5062 : s[n(387, "^JN1")](s[n(475, "A&Ck")](t.i, 6), -1 * -2111 + 8324 + -10435) ? t[n(573, "^JN1")] -= -10353 + 1727 * 6 : s[n(571, "^b8V")](s[n(535, "bHfy")](t.i, 7715 + -3 * 2570), -7 * -981 + 6961 + 4 * -3457) ? t[n(461, "5S5G")] -= 2 : t[n(395, "bHfy")] -= -1721 + -1724 * -1;
      break;
    case -1 * -2149 + -9489 * -1 + -11570:
      t[n(402, "n8(P")] += String[n(401, "S$V]") + "de"](s[n(497, "Nhba")](t[n(537, "VEc#")], 255));
      break;
    case 97: {
      let l = zjt[t.i++];
      t[n(382, "JiCu")] += s[n(493, "sE5w")](typeof l, s[n(515, "2[ps")]) ? s[n(574, "VEc#")](String, t[n(393, "t2PS")][l] ?? "") : s[n(513, "kN$K")](Zjt, l);
      break;
    }
    default:
      throw new Error(n(374, "VEc#") + n(505, "liB^") + e9[c] + ":" + c);
  }
  return t;
}
function F6e(e9) {
  let t = Ex, n = { pOAsz: function(l, d) {
    return l <= d;
  }, IvvQu: function(l, d) {
    return l(d);
  }, VDJSW: function(l, d) {
    return l < d;
  }, SZWwz: function(l, d, m) {
    return l(d, m);
  } };
  if (!e9 || n[t(495, "*V)b")](e9[t(539, "*V)b")], 171 + -722 * 3 + -1 * -1999)) return Buffer[t(443, "5S5G")](-4826 + 2 * 2413);
  let s = n[t(406, "Neo^")](Yjt, e9[t(446, "*V)b")](964 * -8 + 4193 + 1 * 3523)), c = { raw: s, out: Buffer[t(557, "JiCu")](s[t(405, "aEvA")]), i: 0 };
  for (c.i = 1861 * -5 + -5658 + 14963; n[t(566, "^b8V")](c.i, s[t(481, "IOS$")]); c.i++) n[t(560, "6xL6")](Jjt, qjt, c);
  return c[t(412, "!&mc")];
}
var $q = C0(referenceBuiltin9, 1);
var ad0 = "AppV7Dsx";
var Fq = class {
  constructor({ remoteWexConfig: t } = {}) {
    this.remoteWexConfig = t, this.config = null, this.cryptoUrl = "", this.initError = null;
  }
  async init(t = "") {
    let n = W6e(typeof t == "string" ? t : JSON.stringify(t || {})), s = V6e(n.ext) ? n.ext : {}, c = rGt(t, n, s);
    this.cryptoUrl = Ia(n.crypto || s.crypto);
    try {
      this.config = await eGt(c, await this.baseCryptoUrl()), this.initError = null;
    } catch (l) {
      throw this.config = null, this.initError = l, new Error(`AppV7 config not found: ${c}, ${l?.message || l}`);
    }
  }
  key() {
    return this.config?.key || "";
  }
  name() {
    return this.config?.name || "";
  }
  host() {
    return this.config?.host || "";
  }
  async nav() {
    return this.request("nav", this.data());
  }
  async videoList(t, n, s = {}) {
    return this.request("video_list", { token: "", pg: uN(t, 1), tid: uN(n, 1), class: Ia(s.class), area: Ia(s.area), lang: Ia(s.lang), year: Ia(s.year), order: Ia(s.order) || "\u6700\u65B0" });
  }
  async search(t, n) {
    return this.request("search", { token: "", pg: uN(n, 1), text: Ia(t) });
  }
  async detail(t) {
    return this.ensureInit(), this.request("video_detail", { token: "", id: uN(t, 0), sign_md5: this.config.signMd5, apk_path: this.apkPath(), apk_length: uN(this.config.apkLength, 0) });
  }
  async secretParseApiUrl(t, n) {
    let s = await this.request("secret_parse_api_url", { token: "", url: Ia(t), player_code: iGt(t, n) });
    return Ia(s?.data);
  }
  async request(t, n = null) {
    this.ensureInit();
    let s = { method: t, data: n || this.data(), csrf: Date.now() }, c = Ia((await this.crypto("encrypt", JSON.stringify(s)))?.body);
    if (!c) throw new Error(`${this.key()} encrypt empty`);
    let l = await this.postText(this.logsUrl(), c, this.appHeaders(c.length)), d = W6e(l);
    if (Object.keys(d).length) return d;
    let m = await this.crypto("decrypt", l);
    if (V6e(m?.data)) return m.data;
    let g = W6e(m?.text);
    if (Object.keys(g).length) return g;
    throw new Error(`${this.key()} ${t} decrypt empty`);
  }
  async parse(t, n) {
    return !t || String(t).trim().toLowerCase() === "null" || !n ? "" : this.parseUrl(`${t}${n}`);
  }
  async parseUrl(t) {
    try {
      let n = (await this.getText(t, nGt(t, this.config?.userAgent))).trim();
      if (n.startsWith("{") || n.startsWith("[") || n.startsWith("http")) return n;
      let s = await this.crypto("parse_decrypt", n);
      return Ia(s?.text) || n;
    } catch {
      return "";
    }
  }
  logsUrl() {
    return `${this.host().replace(/\/+$/g, "")}/v7/logs`;
  }
  async crypto(t, n) {
    let s = await F0.post(this.cryptoUrlFor(t), { key: this.key(), raw: n == null ? "" : String(n) }, { headers: { "content-type": "application/json", accept: "application/json" }, timeout: 2e4, validateStatus: () => true });
    if (s.status < 200 || s.status >= 300) throw new Error(`crypto ${t} failed: ${s.status}`);
    if (s.data?.error) throw new Error(s.data.error);
    return s.data || {};
  }
  async getText(t, n) {
    let s = await F0.get(t, { headers: n, responseType: "arraybuffer", timeout: 2e4, maxRedirects: 0, validateStatus: (c) => c >= 200 && c < 400 });
    return id0(Buffer.from(s.data || []), s.headers?.["content-encoding"]);
  }
  async postText(t, n, s) {
    let c = await F0.post(t, n, { headers: s, responseType: "arraybuffer", timeout: 2e4, maxRedirects: 0, validateStatus: (l) => l >= 200 && l < 400, transformRequest: [(l) => l], transformResponse: [(l) => l] });
    return id0(Buffer.from(c.data || []), c.headers?.["content-encoding"]);
  }
  appHeaders(t) {
    let n = { ...this.config?.headers || {} };
    return n.host = od0(this.logsUrl()), n["content-length"] = String(t), n;
  }
  data() {
    return { token: "" };
  }
  apkPath() {
    return `/data/app/~~mLGfF_Nezy4R4TqUevJVlg==/${this.config.pkId}-NlNuzFF6p4657CBJv-ue4Q==/base.apk`;
  }
  cryptoUrlFor(t) {
    let n = this.cryptoUrl.includes("?") ? "&" : "?";
    return `${this.cryptoUrl}${n}action=${encodeURIComponent(t)}`;
  }
  async baseCryptoUrl() {
    if (this.cryptoUrl) return this.cryptoUrl;
    let t = this.remoteWexConfig?.ready ? this.remoteWexConfig : await this.remoteWexConfig?.requireReady?.(), n = t?.snapshot?.() || {}, s = aGt(t?.wexSiteUrl || t?.Wexsiteurl || n.wexSiteUrl || n.Wexsiteurl || "");
    if (!s) throw new Error("\u8FDC\u7A0B siteurl \u672A\u5C31\u7EEA\uFF0C\u65E0\u6CD5\u83B7\u53D6 appv7/crypto.php");
    return this.cryptoUrl = `${s}/appv7/crypto.php`, this.cryptoUrl;
  }
  ensureInit() {
    if (this.config?.host) return;
    let t = new Error("AppV7 not initialized");
    throw this.initError && (t.cause = this.initError), t;
  }
};
async function eGt(e9, t) {
  let n = t.includes("?") ? "&" : "?", s = `${t}${n}action=config&key=${encodeURIComponent(e9 || ad0)}`, c = await F0.get(s, { responseType: "json", timeout: 15e3, validateStatus: () => true });
  if (c.status < 200 || c.status >= 300) throw new Error(`config request failed: ${c.status}`);
  if (c.data?.error) throw new Error(c.data.error);
  let l = tGt(c.data?.data);
  if (!l?.host) throw new Error(`AppV7 config empty: ${e9}`);
  return l;
}
function tGt(e9) {
  if (!V6e(e9)) return null;
  let t = { key: Ia(e9.key), name: Ia(e9.name), homeUrl: Ia(e9.home_url), host: Ia(e9.host), version: Ia(e9.version), versionNumber: Ia(e9.version_number), pkId: Ia(e9.pk_id), buildTime: Ia(e9.build_time), signMd5: Ia(e9.sign_md5), apkLength: Ia(e9.apk_length), parseKey: Ia(e9.parse_key), platform: Ia(e9.platform) || "android", platformVersion: Ia(e9.platform_version) || "TP1A.220624.014", userAgent: Ia(e9.user_agent) || "Dart/3.11 (dart:io)" };
  return t.headers = { "user-agent": t.userAgent, version: t.version, "accept-encoding": "gzip", "version-number": t.versionNumber, "content-type": "text/plain", "pk-id": t.pkId, "build-time": t.buildTime, platform: t.platform, "platform-version": t.platformVersion }, t;
}
function rGt(e9, t, n) {
  let s = Ia(t.config || n.config);
  return !s && typeof e9 == "string" && e9.trim() && !e9.trim().startsWith("{") && (s = e9.trim()), s || ad0;
}
function nGt(e9, t) {
  let n = { "user-agent": t || "Dart/3.11 (dart:io)", "accept-encoding": "gzip", connection: "Keep-Alive" }, s = od0(e9);
  return s && (n.host = s), n;
}
function iGt(e9, t) {
  let n = Ia(e9), s = n.indexOf("-");
  if (s > 0 && !n.slice(0, s).includes("://")) return n.slice(0, s);
  let c = n.toLowerCase();
  return c.includes("v.qq.com") || c.includes("qq.com") ? "qq" : c.includes("iqiyi.com") || c.includes("qiyi.com") ? "qiyi" : c.includes("youku.com") ? "youku" : c.includes("mgtv.com") ? "mgtv" : c.includes("bilibili.com") || c.includes("b23.tv") ? "bilibili" : Ia(t);
}
function id0(e9, t) {
  if (!e9?.length) return "";
  let n = String(t || "").toLowerCase();
  return n.includes("gzip") || e9[0] === 31 && e9[1] === 139 ? $q.default.gunzipSync(e9).toString("utf8") : n.includes("deflate") ? $q.default.inflateSync(e9).toString("utf8") : n.includes("br") ? $q.default.brotliDecompressSync(e9).toString("utf8") : e9.toString("utf8");
}
function od0(e9) {
  try {
    return new URL(e9).host;
  } catch {
    return "";
  }
}
function W6e(e9) {
  try {
    let t = String(e9 ?? "").trim();
    return t.startsWith("{") ? JSON.parse(t) : {};
  } catch {
    return {};
  }
}
function aGt(e9) {
  return String(e9 || "").trim().replace(/\/+$/g, "");
}
function Ia(e9) {
  let t = String(e9 ?? "").trim();
  return t.toLowerCase() === "null" ? "" : t;
}
function uN(e9, t = 1) {
  let n = Number.parseInt(e9, 10);
  return Number.isFinite(n) ? n : t;
}
function V6e(e9) {
  return e9 && typeof e9 == "object" && !Array.isArray(e9);
}
var j6e = C0(referenceBuiltin3, 1);
var sd0 = Buffer.from("0123456789abcdef", "utf8");
function xd0(e9 = {}) {
  let t = JSON.stringify({ name: Xx(e9.name), code: Xx(e9.code), url: Xx(e9.url), parse_api: Xx(e9.parseApi ?? e9.parse_api), extra_parse_api: Xx(e9.extraParseApi ?? e9.extra_parse_api), parse_secret: !!(e9.parseSecret ?? e9.parse_secret), headers: Xx(e9.headers), link_features: Xx(e9.linkFeatures ?? e9.link_features), un_link_features: Xx(e9.unLinkFeatures ?? e9.un_link_features), core_params: ud0(e9.coreParams ?? e9.core_params) }), n = j6e.default.createCipheriv("aes-128-ecb", sd0, null);
  return n.setAutoPadding(true), Buffer.concat([n.update(t, "utf8"), n.final()]).toString("base64");
}
function cd0(e9) {
  try {
    let t = j6e.default.createDecipheriv("aes-128-ecb", sd0, null);
    t.setAutoPadding(true);
    let n = Buffer.concat([t.update(Buffer.from(String(e9 || ""), "base64")), t.final()]).toString("utf8"), s = JSON.parse(n);
    return { name: Xx(s.name), code: Xx(s.code), url: Xx(s.url), parseApi: Xx(s.parse_api), extraParseApi: Xx(s.extra_parse_api), parseSecret: !!s.parse_secret, headers: Xx(s.headers), linkFeatures: Xx(s.link_features), unLinkFeatures: Xx(s.un_link_features), coreParams: ud0(s.core_params) };
  } catch {
    return null;
  }
}
function lu(e9) {
  return Xx(e9);
}
function ud0(e9) {
  if (Array.isArray(e9)) return e9;
  if (!e9) return [];
  try {
    let t = JSON.parse(String(e9));
    return Array.isArray(t) ? t : [];
  } catch {
    return [];
  }
}
function Xx(e9) {
  let t = String(e9 ?? "").trim();
  return t.toLowerCase() === "null" ? "" : t;
}
var ld0 = "$$$";
var fd0 = "#";
var G6e = "$";
var oGt = [{ key: "appv7dashixiong", name: "\u5E08\u5144|\u79D2\u64AD", configKey: "AppV7Dsx" }, { key: "appv7fenzhu", name: "\u7C89\u732A|\u79D2\u64AD", configKey: "AppV7Fz" }, { key: "appv7xianyu", name: "\u54B8\u9C7C|\u79D2\u64AD", configKey: "AppV7Xy" }, { key: "appv7zhuijudaren", name: "\u8FFD\u5267|\u79D2\u64AD", configKey: "AppV7Zjdr" }, { key: "appv7xiaoyouzi", name: "\u67DA\u5B50|\u79D2\u64AD", configKey: "AppV7Xyz" }, { key: "appv7xiaoningmeng", name: "\u67E0\u6AAC|\u79D2\u64AD", configKey: "AppV7Xnm" }, { key: "appv7mengtaiqi", name: "\u592A\u5947|\u79D2\u64AD", configKey: "AppV7Mtq" }, { key: "appv7linglingqi", name: "\u96F6\u4E03|\u79D2\u64AD", configKey: "AppV7Llq" }, { key: "appv7xiaoshizi", name: "\u67FF\u5B50|\u79D2\u64AD", configKey: "AppV7Xsz" }, { key: "appv7xiaohuangren", name: "\u9EC4\u4EBA|\u79D2\u64AD", configKey: "AppV7Xhr" }];
function sGt(e9 = {}, t = {}) {
  let n = { configKey: t.configKey || "AppV7Dsx", key: t.key || "appv7dashixiong", name: t.name || "V7|\u5927\u5E08\u5144", ext: t.ext || "", client: new Fq({ remoteWexConfig: e9.remoteWexConfig }), parseApis: /* @__PURE__ */ new Map(), extraParseApis: /* @__PURE__ */ new Map(), initPromise: null, initError: null };
  return { meta: { key: n.key, name: n.name, type: 3, searchable: 1, quickSearch: 1, filterable: 1, changeable: 0 }, async init(s = {}) {
    let c = s.body || {}, l = c.ext || c.extend || n.ext || { config: n.configKey };
    return await md0(n, l), { config: n.client.key(), siteUrl: n.client.host() };
  }, async home() {
    await lN(n);
    let s = await n.client.nav();
    return P0(mGt(s), hGt(s), []);
  }, async category(s) {
    await lN(n);
    let c = s.body || {}, l = Vq(c.page || c.pg || 1, 1), d = c.id || c.tid || "1", m = c.extend || c.filters || {}, g = await n.client.videoList(l, d, m);
    return Me({ page: l, pagecount: Vq(g?.pagecount, 999999), limit: 21, total: 999999, list: dd0(g?.data) });
  }, async detail(s) {
    await lN(n);
    let c = Array.isArray(s.body?.id) ? s.body.id : [s.body?.id], l = [];
    for (let d of c.filter(Boolean)) l.push(await xGt(n, String(d)));
    return l0(l);
  }, async search(s) {
    await lN(n);
    let c = s.body || {}, l = String(c.wd || c.key || "").trim();
    if (!l) return Me({ list: [] });
    let d = Vq(c.page || c.pg || 1, 1), m = await n.client.search(l, d);
    return Me({ page: d, pagecount: Vq(m?.pagecount, 999999), limit: 21, total: 999999, list: dd0(m?.data) });
  }, async play(s) {
    await lN(n);
    let c = s.body || {}, l = String(c.flag || ""), d = String(c.id || ""), m = cd0(d), g = m ? lu(m.url) : d, y = m ? lu(m.parseApi) : lu(n.parseApis.get(l)), v = m ? lu(m.extraParseApi) : lu(n.extraParseApis.get(l)), w = m && m.code ? m.code : l;
    if (!y && !v) return g.startsWith("http") ? E0({ parse: 0, url: g }) : { msg: "\u7F3A\u5C11parse_api\u4E14\u64AD\u653E\u5730\u5740\u4E0D\u662Fhttp" };
    let T = await fGt(n, w, g), I = y ? await n.client.parse(y, T) : "", N = H6e(I);
    return N || v && v !== y && (I = await n.client.parse(v, T), N = H6e(I), N || (I = await dGt(n, I), N = H6e(I), N)) ? N : { msg: q6e(I)?.msg || "\u89E3\u6790\u5931\u8D25" };
  } };
}
async function md0(e9, t) {
  e9.initPromise || (e9.initPromise = e9.client.init(t).then(() => {
    e9.initError = null;
  }).catch((n) => {
    throw e9.initError = n, n;
  }).finally(() => {
    e9.initPromise = null;
  })), await e9.initPromise;
}
async function lN(e9) {
  e9.client.host() || await md0(e9, e9.ext || { config: e9.configKey });
}
async function xGt(e9, t) {
  let s = (await e9.client.detail(t))?.data?.vod_info || {}, c = gGt(s);
  return c.vod_id = c.vod_id || t, cGt(e9, c, Array.isArray(s.vod_url_with_player) ? s.vod_url_with_player : []), c;
}
function cGt(e9, t, n) {
  e9.parseApis.clear(), e9.extraParseApis.clear();
  let s = [], c = [];
  for (let l of n) {
    let d = lGt(l), m = lu(d.name);
    m && (s.push(m), c.push(uGt(d)), e9.parseApis.set(m, lu(d.parseApi)), e9.extraParseApis.set(m, lu(d.extraParseApi)));
  }
  t.vod_play_from = s.join(ld0), t.vod_play_url = c.join(ld0);
}
function uGt(e9) {
  let t = [], n = lu(e9.url);
  for (let s of n.split(fd0)) {
    if (!s) continue;
    let c = s.split(G6e), l = c.length > 1 ? c.shift() : "", d = c.length > 0 ? c.join(G6e) : s, m = { ...e9, url: d };
    t.push(`${l}${G6e}${xd0(m)}`);
  }
  return t.join(fd0);
}
function lGt(e9 = {}) {
  return { name: e9.name, code: e9.code, url: e9.url, parseApi: e9.parse_api, extraParseApi: e9.extra_parse_api, parseSecret: !!e9.parse_secret, headers: e9.headers, linkFeatures: e9.link_features, unLinkFeatures: e9.un_link_features, coreParams: Array.isArray(e9.core_params) ? e9.core_params : [] };
}
async function fGt(e9, t, n) {
  if (!n) return n;
  try {
    return await e9.client.secretParseApiUrl(n, t) || n;
  } catch {
    return n;
  }
}
async function dGt(e9, t) {
  try {
    let n = yGt(lu(q6e(t)?.data));
    return n.startsWith("http") ? await e9.client.parseUrl(n) : t;
  } catch {
    return t;
  }
}
function H6e(e9) {
  let t = pGt(e9);
  return t ? E0({ parse: 0, url: t }) : null;
}
function pGt(e9) {
  let t = q6e(e9), n = lu(t.url);
  if (n) return n;
  let s = String(e9 ?? "").trim();
  return s.startsWith("http") ? s : "";
}
function mGt(e9) {
  let t = [];
  for (let n of Array.isArray(e9?.data) ? e9.data : []) {
    let s = lu(n?.type_id), c = lu(n?.type_name);
    s && c && t.push({ type_id: s, type_name: c });
  }
  return t;
}
function hGt(e9) {
  let t = {};
  for (let n of Array.isArray(e9?.data) ? e9.data : []) {
    let s = lu(n?.type_id);
    if (!s) continue;
    let c = n?.type_extend && typeof n.type_extend == "object" ? n.type_extend : {}, l = [];
    Wq(l, "class", "\u7C7B\u578B", c.class), Wq(l, "area", "\u5730\u533A", c.area), Wq(l, "lang", "\u8BED\u8A00", c.lang), Wq(l, "year", "\u5E74\u4EFD", c.year), l.push({ key: "order", name: "\u6392\u5E8F", value: ["\u6700\u65B0", "\u6700\u70ED", "\u8BC4\u5206"].map((d) => ({ n: d, v: d })) }), l.length && (t[s] = l);
  }
  return t;
}
function Wq(e9, t, n, s) {
  let c = bGt(s);
  c.length && e9.push({ key: t, name: n, value: [{ n: "\u5168\u90E8", v: "" }, ...c.map((l) => ({ n: l, v: l }))] });
}
function dd0(e9) {
  return (Array.isArray(e9) ? e9 : []).map((t) => u0({ id: t?.vod_id, name: t?.vod_name, pic: t?.vod_pic, remarks: t?.vod_remarks || "" })).filter((t) => t.vod_id && t.vod_name);
}
function gGt(e9 = {}) {
  return b0({ id: e9.vod_id, name: e9.vod_name, pic: e9.vod_pic, remarks: e9.vod_remarks, year: e9.vod_year, area: e9.vod_area, actor: e9.vod_actor, director: e9.vod_director, content: e9.vod_content });
}
function q6e(e9) {
  try {
    let t = String(e9 ?? "").trim();
    return t.startsWith("{") ? JSON.parse(t) : {};
  } catch {
    return {};
  }
}
function bGt(e9) {
  return String(e9 || "").split(",").map((t) => t.trim()).filter(Boolean);
}
function Vq(e9, t = 1) {
  let n = Number.parseInt(e9, 10);
  return Number.isFinite(n) && n >= 0 ? n : t;
}
function yGt(e9) {
  if (!e9.includes("%")) return e9;
  try {
    return decodeURIComponent(e9.replace(/\+/g, "%2B"));
  } catch {
    return e9;
  }
}
var vd0 = C0(referenceBuiltin3, 1);
var OGt = "http://v.rbotv.cn";
var DGt = "7gp0bnd2sr85ydii2j32pcypscoc4w6c7g5spl";
var z6e = "5c6034f2-670b-4fc0-87dd-ea23926c731b";
function _d0() {
  return { meta: { key: "rebo", name: "\u70ED\u64AD|\u79D2\u64AD", type: 3 }, async init() {
    return {};
  }, async home() {
    let e9 = await qq("/v3/type/top_type", zq({ "": "" }));
    return P0(...UGt(e9));
  }, async category(e9) {
    let t = e9.body || {}, n = t.extend || t.filters || {}, s = GGt(t.page || t.pg || 1), c = await qq("/v3/home/type_search", zq({ area: gN(n.area), year: gN(n.year), type_id: gN(t.id || t.tid), page: String(s), lang: gN(n.lang), class: gN(n.class) })), l = Hy(c?.data?.list).map(kd0).filter(Boolean);
    return Me({ page: s, pagecount: 9999, limit: l.length, total: 999999, list: l });
  }, async detail(e9) {
    let t = Array.isArray(e9.body?.id) ? e9.body.id : [e9.body?.id], n = [];
    for (let s of t.filter(Boolean)) n.push(await PGt(String(s)));
    return l0(n);
  }, async play(e9) {
    let t = String(e9.body?.id || "");
    if (!t.includes("=")) return Y6e(t);
    let n = await BGt(t, wd0());
    return String(n?.msg || "").includes("\u9519\u8BEF") ? Y6e($Gt(t)) : Y6e(n?.url || "");
  }, async search(e9) {
    let t = e9.body || {}, n = String(t.wd || t.key || "").trim();
    if (!n) return Me({ list: [] });
    let s = await qq("/v3/home/search", zq({ keyword: n }));
    return Me({ page: 1, pagecount: 1, list: Hy(s?.data?.list).map(kd0).filter(Boolean) });
  } };
}
async function PGt(e9) {
  let n = (await qq("/v3/home/vod_details", zq({ vod_id: e9 })))?.data || {}, s = [];
  for (let c of Hy(n.vod_play_list)) {
    let l = [], d = FGt(Hy(c.parse_urls));
    for (let m of Hy(c.urls)) {
      let g = String(m?.name || "").trim(), y = String(m?.url || "").trim();
      !g || !y || l.push(Ei(g, d ? `${d}${encodeURIComponent(y)}` : y));
    }
    l.length && s.push(zn(c.title || "\u64AD\u653E", l));
  }
  return b0({ id: e9, name: n.vod_name || "", pic: n.vod_pic || "", year: n.vod_year || "", area: n.vod_area || "", tag: n.vod_class || "", content: jGt(n.vod_content || ""), actor: n.vod_actor || "", director: n.vod_director || "", ...xa(s) });
}
function Y6e(e9) {
  return E0({ parse: 0, url: e9, header: wd0(), format: String(e9).toLowerCase().includes(".m3u8") ? "application/vnd.apple.mpegurl" : void 0 });
}
async function qq(e9, t) {
  let { body: n, headers: s } = LGt(t), c = await t0.post(`${OGt}${e9}`, n, { headers: { ...s, ...MGt() }, timeout: 15e3, validateStatus: (l) => l < 500 });
  if (c.status >= 400) throw new Error(`\u70ED\u64AD\u8BF7\u6C42\u5931\u8D25 ${c.status}`);
  return typeof c.data == "string" ? JSON.parse(c.data) : c.data;
}
async function BGt(e9, t) {
  let n = await t0.get(e9, { headers: t, timeout: 15e3, validateStatus: (s) => s < 500 });
  if (n.status >= 400) throw new Error(`\u70ED\u64AD\u64AD\u653E\u8BF7\u6C42\u5931\u8D25 ${n.status}`);
  return typeof n.data == "string" ? JSON.parse(n.data) : n.data;
}
function zq(e9 = {}) {
  let t = VGt();
  return { ...e9, sign: WGt(`${DGt}${t}`), timestamp: t };
}
function LGt(e9) {
  let t = [];
  for (let [s, c] of Object.entries(e9)) t.push(`--${z6e}`), t.push(`Content-Disposition: form-data; name="${s}"`), t.push(""), t.push(String(c ?? ""));
  return t.push(`--${z6e}--`), t.push(""), { body: t.join(`\r
`), headers: { "Content-Type": `multipart/form-data; boundary=${z6e}` } };
}
function MGt() {
  return { "User-Agent": "okhttp-okgo/jeasonlzy" };
}
function wd0() {
  return { "User-Agent": "Mozilla/5.0 (Linux; Android 12; V2055A Build/SP1A.210812.003; wv) AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 Chrome/118.0.0.0 Mobile Safari/537.36" };
}
function UGt(e9) {
  let t = [], n = {};
  for (let s of Hy(e9?.data?.list)) {
    let c = String(s?.type_id || ""), l = String(s?.type_name || "");
    if (!c || !l) continue;
    t.push({ type_id: c, type_name: l });
    let d = [];
    Hq(d, "class", "\u5267\u60C5", "\u5168\u90E8\u5267\u60C5", s.extend), Hq(d, "area", "\u5730\u533A", "\u5168\u90E8\u5730\u533A", s.area), Hq(d, "lang", "\u8BED\u8A00", "\u5168\u90E8\u8BED\u8A00", s.lang), Hq(d, "year", "\u65F6\u95F4", "\u5168\u90E8\u65F6\u95F4", s.year), n[c] = d;
  }
  return [t, n];
}
function Hq(e9, t, n, s, c) {
  let l = [{ n: s, v: "" }];
  for (let d of Hy(c)) {
    let m = String(d || "").trim();
    m && m !== "\u5168\u90E8" && l.push({ n: m, v: m });
  }
  e9.push({ key: t, name: n, value: l });
}
function kd0(e9) {
  let t = String(e9?.vod_name || "").trim();
  return t ? u0({ id: e9?.vod_id, name: t, pic: e9?.vod_pic, remarks: e9?.vod_remarks || "" }) : null;
}
function $Gt(e9) {
  try {
    return decodeURIComponent(new URL(e9).searchParams.get("url") || e9);
  } catch {
    return e9;
  }
}
function FGt(e9) {
  return e9.length ? String(e9[0] || "") : "";
}
function WGt(e9) {
  return vd0.default.createHash("md5").update(String(e9), "utf8").digest("hex");
}
function VGt() {
  return String(Math.floor(Date.now() / 1e3));
}
function jGt(e9) {
  return String(e9 || "").replace(/<[^>]*>/g, "").trim();
}
function Hy(e9) {
  return Array.isArray(e9) ? e9 : [];
}
function GGt(e9, t = 1) {
  let n = Number.parseInt(e9, 10);
  return Number.isFinite(n) && n > 0 ? n : t;
}
function gN(e9, t = "") {
  return e9 == null ? String(t || "") : String(e9);
}
var I_ = "https://vip.wwgz.cn:5200/";
var HGt = "https://api.wwgz.cn:520/webcloud/m3u8.php?url=";
var qGt = "https://api.wwgz.cn:520/webcloud/nmm3.php?url=";
var zGt = "Mozilla/5.0 (iPhone; CPU iPhone OS 15_2 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/15.1 Mobile/15E148 Safari/604.1";
function Id0(e9 = {}) {
  let t = { remoteWexConfig: e9.remoteWexConfig, parseUrl: "" };
  return { meta: { key: "bobo", name: "\u6CE2\u6CE2|\u79D2\u64AD", type: 3 }, async init() {
    return t.parseUrl = await Sd0(t).catch(() => ""), {};
  }, async home() {
    let n = await bN(I_), s = [];
    return n("ul.resize_list").each((c, l) => {
      let d = n(l);
      (d.find("li:nth-child(2)").length ? d.find("li:nth-child(2)") : d.find("li:nth-child(1)")).each((g, y) => {
        let v = n(y), w = v.find("a").attr("title") || "";
        w && s.push(u0({ id: v.find("a").attr("href"), name: w, pic: Z6e(v.find("a > div > img").attr("src")), remarks: "" }));
      });
    }), P0(KGt(), ZGt(), s);
  }, async category(n) {
    let s = n.body || {}, c = s.extend || s.filters || {}, l = Td0(s.page || s.pg || 1), d = Yq(c.cateId, s.id || s.tid || "1"), m = `${I_}index.php?m=vod-list-id-${d}-pg-${l}-order--by-${Yq(c.by)}-class-0-year-${Yq(c.year)}-letter--area-${Yq(c.area)}-lang-.html`, g = QGt(await bN(m));
    return Me({ page: l, pagecount: g.length < 24 ? l : l + 1, limit: 24, total: 999999, list: g });
  }, async detail(n) {
    let s = Array.isArray(n.body?.id) ? n.body.id : [n.body?.id], c = [];
    for (let l of s.filter(Boolean)) c.push(await YGt(t, String(l)));
    return l0(c);
  }, async play(n) {
    let s = String(n.body?.id || "");
    if (!s) throw new Error("\u6CE2\u6CE2\u64AD\u653E\u53C2\u6570\u4E3A\u7A7A");
    if (s.startsWith("dJj")) t.parseUrl || (t.parseUrl = await Sd0(t).catch(() => "")), t.parseUrl && (s = AN(await yN(`${t.parseUrl}${encodeURIComponent(s)}`, Q6e(t.parseUrl)).then((c) => c.replace(/\s+/g, "")), /video:\{url:'(.*?)',/));
    else if (s.startsWith("aFHBRI09")) {
      let c = `${HGt}${encodeURIComponent(s)}`;
      s = AN((await yN(c, Q6e(c))).replace(/\s+/g, ""), /url='(.*?)';/);
    } else if (s.startsWith("bFWBFI09Z7X3J1pHYeWlwlvocW")) {
      let c = `${qGt}${encodeURIComponent(s)}`;
      s = AN((await yN(c, Q6e(c))).replace(/\s+/g, ""), /url='(.*?)';/);
    }
    if (!s) throw new Error("\u6CE2\u6CE2\u89E3\u6790\u64AD\u653E\u5730\u5740\u4E3A\u7A7A");
    return E0({ parse: 0, url: s, format: s.toLowerCase().includes(".m3u8") ? "application/vnd.apple.mpegurl" : void 0 });
  }, async search(n) {
    let s = n.body || {}, c = String(s.wd || s.key || "").trim();
    if (!c) return Me({ list: [] });
    let l = Td0(s.page || s.pg || 1), d = await bN(`${I_}vod-search-pg-${l}-wd-${encodeURIComponent(c)}.html`), m = [];
    return d(".ulPicTxt.clearfix > li").each((g, y) => {
      let v = d(y), w = v.find("div.txt.txtHeight > span.sTit").text().trim();
      w && m.push(u0({ id: v.find("div.pic > a").attr("href"), name: w, pic: Z6e(v.find("div.pic > a > img").attr("src")), remarks: "" }));
    }), Me({ page: l, pagecount: 1, list: m });
  } };
}
async function YGt(e9, t) {
  let n = await bN(`${I_}${Ed0(t)}`), s = b0({ id: t, name: n("section.page-bd > h1 > a").text().trim(), pic: "", director: "", actor: "", content: n("section.mod > div.mod-bd > div > article > p").text().trim() }), c = n(".numList ul li").first().find("a").attr("href");
  if (c) {
    let d = (await bN(`${I_}${Ed0(c)}`))("body > section.content > section > div > script:nth-child(1)").toString(), m = AN(d, /mac_url='(.*?)';/), g = AN(d, /mac_from='(.*?)'/) || XGt(e9.remoteWexConfig, "\u6CE2\u6CE2");
    s.vod_play_from = g, s.vod_play_url = JGt(m);
  }
  return s;
}
function QGt(e9) {
  let t = [];
  return e9("section.mod-bd.clearfix > div > ul > li").each((n, s) => {
    let c = e9(s), l = c.find("a").attr("title") || "";
    l && t.push(u0({ id: c.find("a").attr("href"), name: l, pic: Z6e(c.find("a img").attr("src")), remarks: "" }));
  }), t;
}
async function Sd0(e9) {
  let t = e9.remoteWexConfig;
  if (!t) return "";
  t.requireReady && await t.requireReady();
  let n = eHt(t.Wexsiteurl || t.wexSiteUrl || "");
  return n ? yN(`${n}/bobo/caonidie.php`) : "";
}
function ZGt() {
  let e9 = p7("year", "\u5E74\u4EFD", [["\u5168\u90E8", ""], ...["2024", "2023", "2022", "2021", "2020", "2019", "2018", "2017", "2016", "2015", "2014", "2013", "2012", "2011", "2010"].map((s) => [s, s])]), t = p7("area", "\u5730\u533A", [["\u5168\u90E8", ""], ["\u5927\u9646", "\u5927\u9646"], ["\u9999\u6E2F", "\u9999\u6E2F"], ["\u53F0\u6E7E", "\u53F0\u6E7E"], ["\u7F8E\u56FD", "\u7F8E\u56FD"], ["\u97E9\u56FD", "\u97E9\u56FD"], ["\u65E5\u672C", "\u65E5\u672C"], ["\u6CF0\u56FD", "\u6CF0\u56FD"], ["\u65B0\u52A0\u5761", "\u65B0\u52A0\u5761"], ["\u9A6C\u6765\u897F\u4E9A", "\u9A6C\u6765\u897F\u4E9A"], ["\u5370\u5EA6", "\u5370\u5EA6"], ["\u82F1\u56FD", "\u82F1\u56FD"], ["\u6CD5\u56FD", "\u6CD5\u56FD"], ["\u52A0\u62FF\u5927", "\u52A0\u62FF\u5927"]]), n = p7("by", "\u6392\u5E8F", [["\u5168\u90E8", ""], ["\u65F6\u95F4", "time"], ["\u4EBA\u6C14", "hits"], ["\u8BC4\u5206", "score"]]);
  return { 1: [p7("cateId", "\u7C7B\u578B", [["\u5168\u90E8", "1"], ["\u52A8\u4F5C\u7247", "5"], ["\u559C\u5267\u7247", "6"], ["\u7231\u60C5\u7247", "7"], ["\u79D1\u5E7B\u7247", "8"], ["\u6050\u6016\u7247", "9"], ["\u5267\u60C5\u7247", "10"], ["\u6218\u4E89\u7247", "11"], ["\u60CA\u609A\u7247", "16"], ["\u5947\u5E7B\u7247", "17"]]), e9, t, n], 2: [p7("cateId", "\u7C7B\u578B", [["\u5168\u90E8", "2"], ["\u56FD\u4EA7\u5267", "12"], ["\u6E2F\u53F0\u5267", "13"], ["\u65E5\u97E9\u5267", "14"], ["\u6B27\u7F8E\u5267", "15"]]), e9, t, n], 3: [p7("cateId", "\u7C7B\u578B", [["\u5168\u90E8", "3"]]), e9, t, n], 4: [p7("cateId", "\u7C7B\u578B", [["\u5168\u90E8", "4"], ["\u52A8\u6F2B\u5267", "18"], ["\u52A8\u6F2B\u7247", "19"]]), e9, t, n], 26: [p7("cateId", "\u7C7B\u578B", [["\u5168\u90E8", "26"]]), e9, t, n] };
}
function KGt() {
  return [{ type_id: "1", type_name: "\u7535\u5F71" }, { type_id: "2", type_name: "\u7535\u89C6\u5267" }, { type_id: "3", type_name: "\u7EFC\u827A" }, { type_id: "4", type_name: "\u52A8\u6F2B" }, { type_id: "26", type_name: "\u77ED\u5267" }];
}
function p7(e9, t, n) {
  return { key: e9, name: t, value: n.map(([s, c]) => ({ n: s, v: c })) };
}
async function bN(e9) {
  return Pr(await yN(e9));
}
async function yN(e9, t = Rd0()) {
  let n = await t0.get(e9, { headers: t, responseType: "text", transformResponse: [(s) => s], timeout: 15e3 });
  return String(n.data || "");
}
function Rd0() {
  return { "User-Agent": zGt };
}
function Q6e(e9) {
  return { ...Rd0(), referer: e9 };
}
function AN(e9, t) {
  let n = String(e9 || "").match(t);
  return n ? n[1] : "";
}
function JGt(e9) {
  return String(e9 || "").split("$$$").map((t) => t.split("#").filter((n) => n.includes("$")).join("#")).join("$$$");
}
function XGt(e9, t) {
  return String(e9?.Wexconfig?.vodfrom || e9?.snapshot?.()?.vodfrom || t).trim() || t;
}
function Z6e(e9) {
  return e9 ? e9.startsWith("http") ? e9 : new URL(e9, I_).toString() : "";
}
function eHt(e9) {
  return String(e9 || "").replace(/\/+$/, "");
}
function Ed0(e9) {
  return String(e9 || "").replace(/^\/+/, "");
}
function Yq(e9, t = "") {
  return e9 == null || e9 === "" ? t : String(e9);
}
function Td0(e9, t = 1) {
  let n = Number.parseInt(e9, 10);
  return Number.isFinite(n) && n > 0 ? n : t;
}
var Md0 = C0(referenceBuiltin6, 1);
var lHt = ["https://www.maihaolian.com", "http://www.maihaolian.com", "https://maihaolian.com", "http://maihaolian.com"];
var n1e = "https://www.maihaolian.com";
var Ud0 = "Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.0 Mobile/15E148 Safari/604.1";
var fHt = [{ type_id: "1", type_name: "\u7535\u5F71" }, { type_id: "2", type_name: "\u7535\u89C6\u5267" }, { type_id: "3", type_name: "\u7EFC\u827A" }, { type_id: "4", type_name: "\u52A8\u6F2B" }, { type_id: "5", type_name: "\u70ED\u95E8\u77ED\u5267" }, { type_id: "qq", type_name: "\u817E\u8BAFSVIP" }, { type_id: "youku", type_name: "\u4F18\u9177SVIP" }, { type_id: "bli", type_name: "B\u7AD9SVIP" }, { type_id: "duanju", type_name: "\u7EA2\u679C\u77ED\u5267" }];
var $d0 = /* @__PURE__ */ new Set(["1", "2", "3", "4", "5", "6"]);
var dHt = { JD4K: "https://fgsrg.hzqingshan.com/player/", JD2K: "https://fgsrg.hzqingshan.com/player/", co: "https://zzrs.mfdyvip.com/player/", BBA: "https://zzrs.mfdyvip.com/player/", YYNB: "https://zzrs.mfdyvip.com/player/", youku: "https://zzrs.mfdyvip.com/player/", qq: "https://zzrs.mfdyvip.com/player/", bilibili: "https://zzrs.mfdyvip.com/player/", qiyi: "https://zzrs.mfdyvip.com/player/" };
var Fd0 = new Md0.default.Agent({ rejectUnauthorized: true });
function Wd0() {
  let e9 = { siteUrl: n1e };
  return { meta: { key: "wexfengye4k", name: "\u67AB\u53F6|\u79D2\u64AD", type: 3 }, async init() {
    return e9.siteUrl = await pHt(e9.siteUrl), Lc({ siteUrl: e9.siteUrl });
  }, async home() {
    return await R_(e9), P0(fHt, {}, t1e(await Yy(e9, "/"), e9.siteUrl));
  }, async homeVideo() {
    await R_(e9);
    let t = t1e(await Yy(e9, "/"), e9.siteUrl);
    return Me({ page: 1, pagecount: 1, limit: t.length, total: t.length, list: t });
  }, async category(t) {
    await R_(e9);
    let n = t.body || {}, s = Qy(n.id || n.tid || "1"), c = vN(n.page || n.pg || 1);
    if (/^\d+$/.test(s)) {
      let y = await Ld0(e9, `/index.php/ajax/data?mid=1&tid=${encodeURIComponent(s)}&page=${c}&limit=24`);
      if (y?.code === 1 && Array.isArray(y.list)) return Me({ page: c, pagecount: Math.max(vN(y.pagecount, c), c), limit: 24, total: vN(y.total, 0), list: y.list.map((v) => u0({ id: v?.vod_id, name: v?.vod_name, pic: Kq(e9, v?.vod_pic), remarks: v?.vod_remarks })).filter((v) => v.vod_id && v.vod_name) });
    }
    let l = /^\d+$/.test(s) ? `/type/${s}` : `/label/${s}`, d = c === 1 ? `${l}.html` : `${l}/page/${c}.html`, m = await Yy(e9, d), g = t1e(m, e9.siteUrl);
    return Me({ page: c, pagecount: Math.max(AHt(m, c), g.length >= 20 ? c + 1 : c), limit: Math.max(g.length, 20), total: g.length, list: g });
  }, async detail(t) {
    await R_(e9);
    let n = Array.isArray(t.body?.id) ? t.body.id : [t.body?.id], s = [];
    for (let c of n.filter(Boolean)) {
      let l = await mHt(e9, String(c));
      l && s.push(l);
    }
    return l0(s);
  }, async play(t) {
    await R_(e9);
    let n = await gHt(e9, Qy(t.body?.id));
    return E0(n);
  }, async search(t) {
    await R_(e9);
    let n = t.body || {}, s = Qy(n.wd || n.key).trim(), c = vN(n.page || n.pg || 1);
    if (!s || c > 1) return Me({ page: c, pagecount: 1, limit: 20, total: 0, list: [] });
    let l = await Ld0(e9, `/index.php/ajax/suggest?mid=1&wd=${encodeURIComponent(s)}`, { minLength: 1 }), d = Array.isArray(l?.list) ? l.list.map((m) => u0({ id: m?.id, name: m?.name, pic: Kq(e9, m?.pic), remarks: "" })).filter((m) => m.vod_id && m.vod_name) : [];
    return Me({ page: c, pagecount: 1, limit: 20, total: d.length, list: d });
  }, async test(t) {
    let n = t.server.prefix, s = await t.server.inject().post(`${n}/init`), c = await t.server.inject().post(`${n}/search`).payload({ wd: "\u85CF\u6D77\u4F20", page: 1 }), l = c.json()?.list?.[0]?.vod_id, d = l ? await t.server.inject().post(`${n}/detail`).payload({ id: l }) : null, m = d?.json?.()?.list?.[0]?.vod_play_url?.split("$$$")?.[0]?.split("#")?.[0]?.split("$")?.[1], g = m ? await t.server.inject().post(`${n}/play`).payload({ id: m }) : null;
    return { init: s.json(), search: c.json(), detail: d?.json?.() || null, play: g?.json?.() || null };
  } };
}
async function R_(e9) {
  e9.siteUrl || (e9.siteUrl = n1e);
}
async function pHt(e9) {
  for (let t of kHt([e9, ...lHt])) if ((await i1e(t, "/", { minLength: 500 }).catch(() => "")).includes("\u67AB\u53F6\u5F71\u9662")) return console.log(`[WexFengYe4K] init host=${t}`), t;
  return e9 || n1e;
}
async function mHt(e9, t) {
  let n = t.match(/(\d+)/)?.[1] || "";
  if (!n) return null;
  let s = await Yy(e9, `/detail/${n}.html`);
  if (!s) return null;
  let c = Pr(s), l = zy(c(".slide-info-title").first().text()) || c('img[alt*="\u300A"]').first().attr("alt")?.match(/《([^》]+)》/)?.[1] || "", d = b0({ id: n, name: l, pic: Kq(e9, c("img[data-src],img[src]").first().attr("data-src") || c("img[data-src],img[src]").first().attr("src")), typeName: kN(s, "\u7C7B\u578B"), actor: kN(s, "\u6F14\u5458"), director: kN(s, "\u5BFC\u6F14"), year: kN(s, "\u5E74\u4EFD"), remarks: kN(s, "\u8FDE\u8F7D"), content: zy(c("#height_limit").text()).replace(/^简介[:：]?\s*/, "").slice(0, 500) }), m = [...s.matchAll(/aria-label="(\d+)\s*\/\s*\d+"[^>]*>(.*?)<\/a>/gis)], g = [...s.matchAll(new RegExp(`href="(/play/${n}-(\\d+)-(\\d+)\\.html)"[^>]*>([^<]+)</a>`, "gi"))], y = /* @__PURE__ */ new Map();
  for (let I of g) {
    let [, N, C, B, L] = I;
    y.has(C) || y.set(C, []), y.get(C).push({ nid: Number(B), name: zy(L), url: N });
  }
  let v = [], w = [], T = /* @__PURE__ */ new Map();
  for (let I of m) {
    let N = I[1];
    if (!$d0.has(N) || !y.has(N)) continue;
    let C = y.get(N).sort((L, q) => L.nid - q.nid);
    if (!C.length) continue;
    let B = zy(r1e(I[2])).replace(/\s*\(\d+\)$/g, "") || `\u7EBF\u8DEF${N}`;
    v.push(hHt(T, B)), w.push(C.map((L) => `${L.name || L.nid}$${L.url}`).join("#"));
  }
  return d.vod_play_from = v.join("$$$"), d.vod_play_url = w.join("$$$"), d;
}
function hHt(e9, t) {
  let n = (e9.get(t) || 0) + 1;
  return e9.set(t, n), n === 1 ? t : `${t}-${n}`;
}
async function gHt(e9, t) {
  let n = Qy(t);
  if (/^https?:\/\//i.test(n) && /\.(m3u8|mp4)(?:\?|$)/i.test(n)) return { parse: 0, url: n, header: Ym(e9) };
  n.startsWith("/") || (n = `/${n}`);
  let s = await Yy(e9, n, { minLength: 1 }), c = await Bd0(e9, s);
  if (c.url) return c;
  let l = n.match(/^\/play\/(\d+)-(\d+)-(\d+)\.html$/);
  if (l) for (let m of [...$d0].sort()) {
    if (m === l[2]) continue;
    let g = await Yy(e9, `/play/${l[1]}-${m}-${l[3]}.html`, { minLength: 1 }).catch(() => "");
    if (c = await Bd0(e9, g), c.url) return c;
  }
  return { parse: 0, url: s.match(/(https?:\/\/[^\s"'<>]+\.m3u8[^\s"'<>]*)/i)?.[1] || "", header: Ym(e9) };
}
async function Bd0(e9, t) {
  let n = String(t || "").match(/player_aaaa=(\{.*?\})\s*<\/script>/s);
  if (!n) return { parse: 0, url: "", header: Ym(e9) };
  try {
    let s = JSON.parse(n[1]), c = Qy(s.url);
    if (/^https?:\/\//i.test(c)) return { parse: 0, url: c, header: Ym(e9) };
    let l = dHt[Qy(s.from)];
    if (c && l) {
      let d = await bHt(e9, l, c);
      if (d) return { parse: 0, url: d, header: Ym(e9) };
    }
  } catch {
  }
  return { parse: 0, url: "", header: Ym(e9) };
}
async function bHt(e9, t, n) {
  let c = (await i1e(t, `?url=${encodeURIComponent(n)}`, { headers: { ...Ym(e9), Referer: `${e9.siteUrl}/` }, minLength: 1 }).catch(() => "")).match(/data-te="([^"]+)"/)?.[1] || "";
  if (!c) return "";
  let l = await t0.post(`${t}mplayer.php`, new URLSearchParams({ url: n, token: c }).toString(), { timeout: 15e3, responseType: "json", httpsAgent: Fd0, headers: { ...Ym(e9), Referer: t, "Content-Type": "application/x-www-form-urlencoded" }, validateStatus: () => true });
  return l.data?.code === 200 ? Qy(l.data?.url) : "";
}
function t1e(e9, t) {
  let n = [], s = /* @__PURE__ */ new Set(), c = String(e9 || "");
  for (let l of c.matchAll(/<a[^>]+href="(\/detail\/(\d+)\.html)"[^>]*>(.*?)<\/a>/gis)) {
    let [, d, m, g] = l;
    if (s.has(m)) continue;
    let y = zy(g.match(/alt="([^"]+)"/i)?.[1] || g.match(/<span[^>]*>([^<]+)<\/span>/i)?.[1] || r1e(g)).replace(/\s+/g, "");
    if (!y || y.length > 100) continue;
    let v = g.match(/data-src="([^"]+)"/i)?.[1] || g.match(/src="([^"]+)"/i)?.[1] || g.match(/background-image:\s*url\(([^)]+)\)/i)?.[1] || "", w = zy(r1e(g)).replace(y, "").replace(/^\|+|\|+$/g, "").slice(0, 20);
    s.add(m), n.push(u0({ id: m, name: y.slice(0, 50), pic: Kq({ siteUrl: t }, v), remarks: w }));
  }
  return n;
}
async function Yy(e9, t, n = {}) {
  let s = await i1e(e9.siteUrl, t, { headers: Ym(e9), ...n });
  return !s || s.includes("\u7CFB\u7EDF\u5B89\u5168\u9A8C\u8BC1") || s.startsWith("403") ? "" : s;
}
async function Ld0(e9, t, n = {}) {
  let s = await Yy(e9, t, n);
  try {
    return JSON.parse(s);
  } catch {
    return {};
  }
}
async function i1e(e9, t, n = {}) {
  let s = /^https?:\/\//i.test(t) ? t : `${Vd0(e9)}${t.startsWith("/") ? t : `/${t}`}`, c = await t0.get(s, { timeout: n.timeout || 15e3, responseType: "text", httpsAgent: Fd0, headers: n.headers || { "User-Agent": Ud0 }, transformResponse: [(d) => d], validateStatus: () => true }), l = yHt(String(c.data || ""));
  return c.status >= 400 || l.length < (n.minLength ?? 500) ? "" : l;
}
function yHt(e9) {
  let t = String(e9 || "").trim();
  if (!t.startsWith('"') || !t.endsWith('"')) return e9;
  try {
    let n = JSON.parse(t);
    return typeof n == "string" ? n : e9;
  } catch {
    return e9;
  }
}
function Kq(e9, t) {
  let n = t == null ? "" : String(t).replace(/\\/g, "").replace(/&amp;/g, "&").trim();
  if (!n) return "";
  if (n.startsWith("//") && (n = `https:${n}`), /^https?:\/\//i.test(n) || (n = `${e9.siteUrl}${n.startsWith("/") ? n : `/${n}`}`), n.includes("gimg0.baidu.com")) return n;
  let s = n.match(/^https?:\/\/([^/]+)(\/.*)$/i);
  return s && s[1].includes("hzqingshan.com") ? `https://gimg0.baidu.com/gimg/app=2001&n=0&g=0n&fmt=jpeg&src=${s[1]}${s[2]}` : n;
}
function kN(e9, t) {
  return zy(String(e9 || "").match(new RegExp(`<strong class="r6">${vHt(t)}:</strong>([^<]*)<`, "i"))?.[1] || "");
}
function AHt(e9, t = 1) {
  let n = t;
  for (let s of String(e9 || "").matchAll(/\/(?:type|label)\/[^/]+\/page\/(\d+)\.html/gi)) n = Math.max(n, vN(s[1], t));
  return n;
}
function Ym(e9) {
  return { "User-Agent": Ud0, Referer: `${e9.siteUrl}/`, Connection: "close" };
}
function kHt(e9) {
  let t = [], n = /* @__PURE__ */ new Set();
  for (let s of e9.map(Vd0)) !s || n.has(s) || (n.add(s), t.push(s));
  return t;
}
function Vd0(e9) {
  return String(e9 || "").trim().replace(/\/+$/, "");
}
function r1e(e9) {
  return String(e9 || "").replace(/<[^>]+>/g, " ");
}
function zy(e9) {
  return String(e9 || "").replace(/&nbsp;/gi, " ").replace(/&amp;/gi, "&").replace(/\s+/g, " ").trim();
}
function Qy(e9, t = "") {
  return e9 == null || e9 === "" ? t : String(e9);
}
function vN(e9, t = 1) {
  let n = Number.parseInt(e9, 10);
  return Number.isFinite(n) && n > 0 ? n : t;
}
function vHt(e9) {
  return String(e9).replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}
var a1e = C0(referenceBuiltin0, 1);
function C_(e9, t = "0123456789abcdef") {
  let n = a1e.default.createCipheriv("aes-128-ecb", Buffer.from(t, "utf8"), null), s = n.update(String(e9 || ""), "utf8", "base64");
  return s += n.final("base64"), s;
}
function m7(e9, t = "0123456789abcdef") {
  let n = String(e9 || "").trim();
  if (!n) return "";
  let s = a1e.default.createDecipheriv("aes-128-ecb", Buffer.from(t, "utf8"), null), c = s.update(n, "base64", "utf8");
  return c += s.final("utf8"), c;
}
function Jq(e9, t = "0123456789abcdef") {
  let n = typeof e9 == "string" ? e9.trim() : String(e9 || "").trim();
  return n.length >= 2 && n.startsWith('"') && n.endsWith('"') && (n = n.slice(1, -1)), n = n.replace(/\\\//g, "/").replace(/\\n/g, "").replace(/\\r/g, "").replace(/\\"/g, '"'), m7(n, t);
}
var _Ht = "http://dh.baicanuc.cn:3000";
var o1e = "0123456789abcdef";
var wHt = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/109.0.0.0 Safari/537.36";
function Gd0() {
  let e9 = { filters: RHt() };
  return { meta: { key: "huya", name: "\u864E\u7259|\u76F4\u64AD", type: 3 }, async init() {
    return {};
  }, async home() {
    return P0(IHt(), e9.filters, []);
  }, async category(t) {
    let n = t.body || {}, s = n.extend || n.filters || {}, c = String(n.id || n.tid || "1"), l = h7(s.type, NHt(e9.filters, c) || c), d = jd0(n.page || n.pg || 1), m = await SHt(l, d);
    return Me({ page: d, pagecount: Number.MAX_SAFE_INTEGER, limit: 120, total: Number.MAX_SAFE_INTEGER, list: m });
  }, async detail(t) {
    let n = Array.isArray(t.body?.id) ? t.body.id : [t.body?.id], s = [];
    for (let c of n.filter(Boolean)) s.push(await THt(OHt(String(c), "huya_")));
    return l0(s);
  }, async play(t) {
    let n = String(t.body?.id || "");
    if (!n) throw new Error("\u864E\u7259\u64AD\u653E\u5730\u5740\u4E3A\u7A7A");
    let s = m7(n, o1e);
    if (!s) throw new Error("\u864E\u7259\u64AD\u653E\u5730\u5740\u89E3\u5BC6\u5931\u8D25");
    return E0({ parse: 0, url: s, header: s1e() });
  }, async search(t) {
    let n = t.body || {}, s = String(n.wd || n.key || "").trim(), c = jd0(n.page || n.pg || 1);
    if (!s || c > 1) return Me({ page: c, pagecount: 1, list: [] });
    let l = await EHt(s);
    return Me({ page: c, pagecount: 1, list: l });
  } };
}
async function SHt(e9, t) {
  let n = await CHt(`https://live.huya.com/liveHttpUI/getLiveList?iGid=${encodeURIComponent(e9)}&iPageNo=${t}&iPageSize=120`, s1e());
  return (n?.vList || n?.data?.vList || []).map((c) => {
    let l = h7(c.lProfileRoom);
    return l ? u0({ id: `huya_${l}`, name: h7(c.sIntroduction), pic: h7(c.sScreenshot), remarks: h7(c.sNick) }) : null;
  }).filter((c) => c?.vod_id && c?.vod_name);
}
async function EHt(e9) {
  let t = await Hd0(`https://www.huya.com/search?hsk=${encodeURIComponent(e9)}`, s1e()), n = Pr(t), s = [];
  return n(".game-live-item>a.title.new-clickstat").each((c, l) => {
    let d = n(l), m = DHt(d.attr("href"), /https:\/\/www\.huya\.com\/(\d+)/), g = d.next().find("img");
    !m || !g.length || s.push(u0({ id: `huya_${m}`, name: d.text().trim(), pic: g.attr("src") || "", remarks: "" }));
  }), s;
}
async function THt(e9) {
  let t = await Hd0(`${_Ht}/getHuyaData?rid=${encodeURIComponent(e9)}`);
  if (!t) throw new Error("\u864E\u7259\u76F4\u64AD\u63A5\u53E3\u8FD4\u56DE\u4E3A\u7A7A");
  let n = JSON.parse(m7(t, o1e)), s = n.roomInfo || {}, c = b0({ ...s, id: s.vod_id || `huya_${e9}`, name: s.vod_name, pic: s.vod_pic, content: `https://www.huya.com/${e9}`, remarks: "huya" });
  c.vod_remarks = "huya";
  let l = [], d = [];
  for (let m of n.data || []) {
    l.push(h7(m.name));
    let g = [];
    for (let y of m.urls || []) {
      let v = h7(y.url);
      v && g.push(`${h7(y.displayName)}$${C_(v, o1e)}`);
    }
    d.push(g.join("#"));
  }
  return c.vod_play_from = l.join("$$$"), c.vod_play_url = d.join("$$$"), c;
}
function IHt() {
  return [{ type_id: "1", type_name: "\u7F51\u6E38\u7ADE\u6280" }, { type_id: "2", type_name: "\u5355\u673A\u70ED\u8EAB" }, { type_id: "8", type_name: "\u5A31\u4E50\u5929\u5730" }, { type_id: "3", type_name: "\u624B\u6E38\u4F11\u95F2" }];
}
function RHt() {
  return { 1: [Xq([["\u82F1\u96C4\u8054\u76DF", "1"], ["CS2", "862"], ["\u65E0\u754F\u5951\u7EA6", "5937"], ["lol\u4E91\u9876\u4E4B\u5F08", "5485"], ["\u7A7F\u8D8A\u706B\u7EBF", "4"], ["\u7089\u77F3\u4F20\u8BF4", "393"], ["\u9006\u6218", "135"], ["DOTA2", "7"], ["\u5730\u4E0B\u57CE\u4E0E\u52C7\u58EB", "2"], ["\u9B54\u517D\u4E89\u97383", "4615"], ["\u5766\u514B\u4E16\u754C", "802"], ["\u7F51\u6E38\u7ADE\u6280", "100023"], ["\u66B4\u96EA\u4E13\u533A", "100043"], ["\u5C04\u51FB\u7EFC\u5408\u6E38\u620F", "100141"], ["\u68CB\u724C\u4F11\u95F2", "100301"], ["\u5251\u7075", "897"], ["\u9B54\u517D\u4E16\u754C", "8"], ["\u5192\u9669\u5C9B", "2243"], ["\u4F20\u5947", "983"], ["\u684C\u6E38", "100305"], ["\u8BDB\u4ED93", "1646"], ["QQ\u98DE\u8F66", "9"], ["\u95EE\u9053", "107"], ["NBA2KOL\u7CFB\u5217", "3959"]])], 2: [Xq([["\u5929\u5929\u5403\u9E21", "2793"], ["\u4E3B\u673A\u6E38\u620F", "100032"], ["\u9ED1\u795E\u8BDD\uFF1A\u609F\u7A7A", "6111"], ["\u6211\u7684\u4E16\u754C", "1732"], ["\u65B9\u821F", "1997"], ["\u9003\u79BB\u5854\u79D1\u592B", "3493"], ["\u5355\u673A\u70ED\u6E38", "100002"], ["\u4E92\u52A8\u70B9\u64AD", "5907"], ["\u6C38\u52AB\u65E0\u95F4", "6219"], ["\u90E8\u843D\uFF1A\u4E0A\u53E4", "1318"], ["\u6050\u6016\u6E38\u620F", "9453"], ["\u6218\u5730\u98CE\u4E916", "4371"], ["\u6000\u65E7\u6E38\u620F", "100125"], ["\u4E92\u52A8\u5267\u6E38", "6919"], ["Dread Hunger", "7601"], ["Among Us", "6163"], ["\u602A\u7269\u730E\u4EBA", "6479"], ["\u535A\u5FB7\u4E4B\u95E83", "6147"], ["Apex\u82F1\u96C4", "5011"], ["FIFA\u8DB3\u7403", "1888"]])], 8: [Xq([["\u6237\u5916", "2165"], ["\u661F\u79C0", "1663"], ["\u539F\u521B", "6861"], ["\u4F53\u80B2", "2356"], ["\u4E00\u8D77\u770B", "2135"], ["\u4EA4\u53CB", "4079"], ["\u4E8C\u6B21\u5143", "2633"], ["\u989C\u503C", "2168"], ["\u5A31\u4E50", "100022"], ["\u4E00\u8D77\u73A9", "6613"], ["\u5403\u559D\u73A9\u4E50", "100044"], ["\u4E92\u52A8\u7EC4\u961F", "5367"], ["\u864E\u7259\u6587\u5316", "4089"], ["\u97F3\u4E50", "3793"], ["\u79D1\u6280", "2408"], ["\u65C5\u6E38", "6791"]])], 3: [Xq([["\u738B\u8005\u8363\u8000", "2336"], ["\u65E0\u754F\u5951\u7EA6\uFF1A\u6E90\u80FD\u884C\u52A8", "62639"], ["\u4E09\u89D2\u6D32\u884C\u52A8", "9449"], ["\u548C\u5E73\u7CBE\u82F1", "3203"], ["\u91D1\u94F2\u94F2\u4E4B\u6218", "7185"], ["\u738B\u8005\u6A21\u62DF\u6218", "5699"], ["\u7EFC\u5408\u624B\u6E38", "100029"], ["\u4E09\u56FD\u6740", "1669"], ["\u65B0\u6E38\u5E7F\u573A", "100052"], ["\u82F1\u96C4\u8054\u76DF\u624B\u6E38", "6203"], ["DNF\u624B\u6E38", "4921"], ["\u9006\u6C34\u5BD2\u624B\u6E38", "7725"], ["CF\u624B\u6E38", "2413"], ["QQ\u98DE\u8F66\u624B\u6E38", "2928"], ["\u624B\u6E38\u4F11\u95F2", "100004"], ["\u539F\u795E", "5489"], ["\u5D29\u574F\uFF1A\u661F\u7A79\u94C1\u9053", "7349"], ["\u660E\u65E5\u65B9\u821F", "4925"], ["\u7EDD\u533A\u96F6", "7711"], ["COD\u624B\u6E38", "4769"]])] };
}
function Xq(e9) {
  return { key: "type", name: "\u7B5B\u9009", value: e9.map(([t, n]) => ({ n: t, v: n })) };
}
function s1e() {
  return { "User-Agent": wHt, referer: "https://www.huya.com/" };
}
async function CHt(e9, t = {}) {
  return (await t0.get(e9, { headers: t, responseType: "json", timeout: 15e3 })).data || {};
}
async function Hd0(e9, t = {}) {
  let n = await t0.get(e9, { headers: t, responseType: "text", transformResponse: [(s) => s], timeout: 15e3 });
  return String(n.data || "");
}
function NHt(e9, t) {
  return e9?.[t]?.[0]?.value?.[0]?.v || "";
}
function OHt(e9, t) {
  return e9.startsWith(t) ? e9.slice(t.length) : e9;
}
function DHt(e9, t) {
  let n = String(e9 || "").match(t);
  return n ? n[1] : "";
}
function h7(e9, t = "") {
  return e9 == null || e9 === "" ? t : String(e9);
}
function jd0(e9, t = 1) {
  let n = Number.parseInt(e9, 10);
  return Number.isFinite(n) && n > 0 ? n : t;
}
var Jd0 = C0(referenceBuiltin0, 1);
var qd0 = "http://dh.baicanuc.cn:3000";
var ez = "0123456789abcdef";
var Xd0 = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/132.0.0.0 Safari/537.36";
var zd0 = "7cd084941338484aae1ad9425b84077c";
var Yd0 = "4932caff0ff746eab6f01bf08b70ac45";
function e20(e9 = {}) {
  let t = { remoteWexConfig: e9.remoteWexConfig, cookie: "", filters: null, defaults: {} };
  return { meta: { key: "bililive", name: "\u54D4\u54E9|\u76F4\u64AD", type: 3 }, async init() {
    return t.cookie = await VHt(t.remoteWexConfig).catch((n) => (console.warn(`[LiveAiBiLi] bili cookie load failed: ${n.message}`), "")), {};
  }, async home() {
    let n = await Qd0(t.cookie), s = PHt(n);
    return t.filters = Zd0(n, t), P0(s, t.filters, []);
  }, async category(n) {
    let s = n.body || {}, c = s.extend || s.filters || {};
    if (!t.filters) {
      let y = await Qd0(t.cookie);
      t.filters = Zd0(y, t);
    }
    let l = String(s.id || s.tid || Object.keys(t.filters || {})[0] || "1"), d = ec(c.type, t.defaults[l] || l), m = Kd0(s.page || s.pg || 1), g = await BHt(l, d, m, t.cookie);
    return Me({ page: m, pagecount: Number.MAX_SAFE_INTEGER, limit: 40, total: Number.MAX_SAFE_INTEGER, list: g });
  }, async detail(n) {
    let s = Array.isArray(n.body?.id) ? n.body.id : [n.body?.id], c = [];
    for (let l of s.filter(Boolean)) c.push(await MHt(QHt(String(l), "bilibili_"), t.cookie));
    return l0(c);
  }, async play(n) {
    let s = String(n.body?.id || "");
    if (!s) throw new Error("\u54D4\u54E9\u76F4\u64AD\u64AD\u653E\u53C2\u6570\u4E3A\u7A7A");
    let c = m7(s, ez), l = c.includes("|||") ? c.split("|||", 2)[1] : c;
    if (!l) throw new Error("\u54D4\u54E9\u76F4\u64AD\u64AD\u653E\u5730\u5740\u4E3A\u7A7A");
    return UHt(l, t.cookie);
  }, async search(n) {
    let s = n.body || {}, c = String(s.wd || s.key || "").trim();
    if (!c) return Me({ list: [] });
    let l = Kd0(s.page || s.pg || 1), d = await LHt(c, l, t.cookie);
    return Me({ page: l, pagecount: Number.MAX_SAFE_INTEGER, limit: 42, total: Number.MAX_SAFE_INTEGER, list: d });
  } };
}
async function Qd0(e9) {
  let t = await wN("https://api.live.bilibili.com/xlive/web-interface/v1/index/getWebAreaList?source_id=2", g7(e9));
  if (!t?.data?.data) throw new Error("\u54D4\u54E9\u76F4\u64AD\u5206\u7C7B\u63A5\u53E3\u8FD4\u56DE\u4E3A\u7A7A");
  return t;
}
function PHt(e9) {
  return (e9?.data?.data || []).map((t) => ({ type_id: ec(t.id), type_name: ec(t.name) })).filter((t) => t.type_id && t.type_name);
}
function Zd0(e9, t) {
  let n = {};
  t.defaults = {};
  for (let s of e9?.data?.data || []) {
    let c = ec(s.id), l = [];
    for (let d of s.list || []) {
      let m = ec(d.name), g = ec(d.id);
      !m || !g || (t.defaults[c] || (t.defaults[c] = g), l.push({ n: m, v: g }));
    }
    n[c] = [{ key: "type", name: "\u7B5B\u9009", value: l }];
  }
  return n;
}
async function BHt(e9, t, n, s) {
  let c = await $Ht(e9, t, n, s), l = [];
  return c && (l = (await wN(c, g7(s)))?.data?.list || []), l.length || (l = (await wN(`https://api.live.bilibili.com/room/v3/area/getRoomList?platform=web&parent_area_id=${encodeURIComponent(e9)}&area_id=${encodeURIComponent(t)}&page=${n}&page_size=40&sort_type=online`, g7(s)))?.data?.list || []), l.map((d) => {
    let m = ec(d.roomid);
    return m ? u0({ id: `bilibili_${m}`, name: ec(d.title), pic: ec(d.system_cover), remarks: ec(d.area_name) }) : null;
  }).filter((d) => d?.vod_id && d?.vod_name);
}
async function LHt(e9, t, n) {
  let s = `https://api.bilibili.com/x/web-interface/wbi/search/type?search_type=live&page=${t}&page_size=42&order=online&keyword=${encodeURIComponent(e9)}`;
  return ((await wN(s, g7(n)))?.data?.result?.live_room || []).map((d) => {
    let m = ec(d.roomid);
    if (!m) return null;
    let g = ec(d.uface);
    return g && !g.startsWith("http") && (g = `https:${g}`), u0({ id: `bilibili_${m}`, name: qHt(d.title), pic: g, remarks: "" });
  }).filter((d) => d?.vod_id && d?.vod_name);
}
async function MHt(e9, t) {
  let n = await tz(`${qd0}/getBilibiliData?rid=${encodeURIComponent(e9)}&type=getRoomInfo`, g7(t));
  if (!n) throw new Error("\u54D4\u54E9\u76F4\u64AD\u623F\u95F4\u63A5\u53E3\u8FD4\u56DE\u4E3A\u7A7A");
  let s = JSON.parse(m7(n, ez)), c = s.roomInfo || {}, l = b0({ ...c, id: c.vod_id || `bilibili_${e9}`, name: c.vod_name, pic: c.vod_pic, content: `https://live.bilibili.com/${e9}` });
  l.vod_remarks = "bilibili";
  let d = [], m = [];
  for (let g of s.acceptQn || []) {
    let y = ec(g.desc), v = ec(g.qn);
    if (!y || !v) continue;
    d.push(y);
    let w = await tz(`${qd0}/getBilibiliData?rid=${encodeURIComponent(e9)}&type=getPlayUrl&qn=${encodeURIComponent(v)}`, g7(t));
    if (!w) {
      m.push("");
      continue;
    }
    let T = JSON.parse(m7(w, ez)), I = [];
    T.forEach((N, C) => {
      let B = ec(N.url);
      B && I.push(`\u64AD\u653E\u5730\u5740_${String(C + 1).padStart(2, "0")}$${C_(`bilibili|||${B}`, ez)}`);
    }), m.push(I.join("#"));
  }
  return l.vod_play_from = d.join("$$$"), l.vod_play_url = m.join("$$$"), l;
}
async function UHt(e9, t) {
  let n = { "user-agent": Xd0 };
  t && (n.cookie = t);
  try {
    let s = await t0.get(e9, { headers: n, responseType: "stream", timeout: 8e3, validateStatus: () => true });
    s.data?.destroy?.(), s.status === 403 && (n.referer = "https://live.bilibili.com");
  } catch {
  }
  return E0({ parse: 0, url: e9, header: n, extra: { nodanmu: true } });
}
async function $Ht(e9, t, n, s) {
  for (let c = 0; c < 5; c++) try {
    let l = await FHt(e9, t, s), d = `platform=web&parent_area_id=${e9}&area_id=${t}&sort_type=&page=${n}&vajra_business_key=&web_location=${l.location || ""}&w_webid=${l.webid || ""}&wts=${l.time || ""}`, m = jHt(d), g = await WHt(s), y = GHt(`${g.imgKey}${g.subKey}`), v = Object.keys(m).sort().map((T) => `${T}=${HHt(m[T])}`).join("&"), w = zHt(`${v}${y}`);
    return `https://api.live.bilibili.com/xlive/web-interface/v1/second/getList?${d}&w_rid=${w}`;
  } catch {
  }
  return "";
}
async function FHt(e9, t, n) {
  let s = await tz(`https://live.bilibili.com/p/eden/area-tags?parentAreaId=${encodeURIComponent(e9)}&areaId=${encodeURIComponent(t)}`, g7(n)), c = _N(s, /"access_id":"(.*?)"/), l = "";
  try {
    l = Buffer.from(c, "base64").toString("utf8");
  } catch {
    l = "";
  }
  return { webid: c, time: _N(l, /"created_at":(.*?),/), location: _N(l, /"spm_id":"(.*?)"/) };
}
async function WHt(e9) {
  try {
    let n = (await wN("https://api.bilibili.com/x/web-interface/nav", g7(e9)))?.data?.wbi_img || {};
    return { imgKey: _N(ec(n.img_url), /wbi\/(.*?).png/) || zd0, subKey: _N(ec(n.sub_url), /wbi\/(.*?).png/) || Yd0 };
  } catch {
    return { imgKey: zd0, subKey: Yd0 };
  }
}
async function VHt(e9) {
  if (!e9) return "";
  e9.requireReady && await e9.requireReady();
  let t = YHt(e9.Wexsiteurl || e9.wexSiteUrl || "");
  return t ? (await tz(`${t}/cookie/bili.php`)).trim() : "";
}
function g7(e9 = "") {
  let t = { "User-Agent": Xd0, Referer: "https://live.bilibili.com/" };
  return e9 && (t.cookie = e9), t;
}
async function wN(e9, t = {}) {
  return (await t0.get(e9, { headers: t, responseType: "json", timeout: 15e3 })).data || {};
}
async function tz(e9, t = {}) {
  let n = await t0.get(e9, { headers: t, responseType: "text", transformResponse: [(s) => s], timeout: 15e3 });
  return String(n.data || "");
}
function jHt(e9) {
  let t = {};
  for (let n of String(e9 || "").split("&")) {
    let s = n.indexOf("=");
    t[s < 0 ? n : n.slice(0, s)] = s < 0 ? "" : n.slice(s + 1);
  }
  return t;
}
function GHt(e9) {
  let t = [46, 47, 18, 2, 53, 8, 23, 32, 15, 50, 10, 31, 58, 3, 45, 35, 27, 43, 5, 49, 33, 9, 42, 19, 29, 28, 14, 39, 12, 38, 41, 13, 37, 48, 7, 16, 24, 55, 40, 61, 26, 17, 0, 1, 60, 51, 30, 4, 22, 25, 54, 21, 56, 59, 6, 63, 57, 62, 11, 36, 20, 34, 44, 52], n = "";
  for (let s of t) s < e9.length && (n += e9[s]);
  return n.slice(0, 32);
}
function HHt(e9) {
  return String(e9 || "").replace(/[!'()*]/g, "");
}
function qHt(e9) {
  return String(e9 || "").replace(/<[^>]*>/g, "").trim();
}
function zHt(e9) {
  return Jd0.default.createHash("md5").update(String(e9 || ""), "utf8").digest("hex");
}
function YHt(e9) {
  return String(e9 || "").replace(/\/+$/, "");
}
function QHt(e9, t) {
  return e9.startsWith(t) ? e9.slice(t.length) : e9;
}
function _N(e9, t) {
  let n = String(e9 || "").match(t);
  return n ? n[1] : "";
}
function ec(e9, t = "") {
  return e9 == null || e9 === "" ? t : String(e9);
}
function Kd0(e9, t = 1) {
  let n = Number.parseInt(e9, 10);
  return Number.isFinite(n) && n > 0 ? n : t;
}
var t20 = "http://dh.baicanuc.cn:3000";
var rz = "0123456789abcdef";
var ZHt = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/109.0.0.0 Safari/537.36";
var i20 = ["4", "5", "6", "20"];
var KHt = ["\u7F51\u9875\u7ADE\u6280", "\u5355\u673A\u6E38\u620F", "\u624B\u6E38\u6E38\u620F", "\u5A31\u4E50"];
function a20() {
  let e9 = { filters: null, defaults: {} };
  return { meta: { key: "douyu", name: "\u6597\u9C7C|\u76F4\u64AD", type: 3 }, async init() {
    return {};
  }, async home() {
    return e9.filters = await r20(e9), P0(tqt(), e9.filters, []);
  }, async category(t) {
    let n = t.body || {}, s = n.extend || n.filters || {}, c = String(n.id || n.tid || "4");
    await r20(e9);
    let l = fu(s.type, e9.defaults[c] || c), d = n20(n.page || n.pg || 1), m = await JHt(l, d);
    return Me({ page: d, pagecount: Number.MAX_SAFE_INTEGER, limit: 120, total: Number.MAX_SAFE_INTEGER, list: m });
  }, async detail(t) {
    let n = Array.isArray(t.body?.id) ? t.body.id : [t.body?.id], s = [];
    for (let c of n.filter(Boolean)) s.push(await eqt(rqt(String(c), "douyu_")));
    return l0(s);
  }, async play(t) {
    let n = String(t.body?.id || "");
    if (!n) throw new Error("\u6597\u9C7C\u64AD\u653E\u53C2\u6570\u4E3A\u7A7A");
    let s = Jq(`"${n}"`, rz);
    if (!s) throw new Error("\u6597\u9C7C\u64AD\u653E\u53C2\u6570\u89E3\u5BC6\u5931\u8D25");
    let c = await o20(s);
    if (!c) throw new Error("\u6597\u9C7C\u64AD\u653E\u63A5\u53E3\u8FD4\u56DE\u4E3A\u7A7A");
    let l = JSON.parse(Jq(c, rz)), d = fu(l.url);
    if (!d) throw new Error("\u6597\u9C7C\u64AD\u653E\u5730\u5740\u4E3A\u7A7A");
    return E0({ parse: 0, url: d, extra: { nodanmu: true } });
  }, async search(t) {
    let n = t.body || {}, s = String(n.wd || n.key || "").trim();
    if (!s) return Me({ list: [] });
    let c = n20(n.page || n.pg || 1), l = await XHt(s, c);
    return Me({ page: c, pagecount: Number.MAX_SAFE_INTEGER, limit: 28, total: Number.MAX_SAFE_INTEGER, list: l });
  } };
}
async function r20(e9) {
  if (e9.filters) return e9.filters;
  let t = {};
  return e9.defaults = {}, await Promise.all(i20.map(async (n) => {
    let s = [];
    try {
      let c = await c1e(`https://www.douyu.com/japi/weblist/apinc/getC2List?customClassId=${n}&offset=0&limit=200`, x1e());
      for (let l of c?.data?.list || []) {
        let d = fu(l.cname2), m = fu(l.cid2);
        !d || !m || (e9.defaults[n] || (e9.defaults[n] = m), s.push({ n: d, v: m }));
      }
    } catch {
    }
    t[n] = [{ key: "type", name: "\u7B5B\u9009", value: s }];
  })), e9.filters = t, t;
}
async function JHt(e9, t) {
  return ((await c1e(`https://www.douyu.com/gapi/rkc/directory/mixList/2_${encodeURIComponent(e9)}/${t}`, x1e()))?.data?.rl || []).map((s) => {
    let c = fu(s.rid);
    return c ? u0({ id: `douyu_${c}`, name: fu(s.rn), pic: fu(s.rs1), remarks: fu(s.nn) }) : null;
  }).filter((s) => s?.vod_id && s?.vod_name);
}
async function XHt(e9, t) {
  return ((await c1e(`https://www.douyu.com/japi/search/api/searchShow?page=${t}&pageSize=28&kw=${encodeURIComponent(e9)}`, x1e()))?.data?.relateShow || []).map((s) => {
    let c = fu(s.rid);
    return c ? u0({ id: `douyu_${c}`, name: fu(s.roomName), pic: fu(s.roomSrc), remarks: "" }) : null;
  }).filter((s) => s?.vod_id && s?.vod_name);
}
async function eqt(e9) {
  let t = await o20(`${t20}/getDouyuData?rid=${encodeURIComponent(e9)}`);
  if (!t) throw new Error("\u6597\u9C7C\u76F4\u64AD\u63A5\u53E3\u8FD4\u56DE\u4E3A\u7A7A");
  let n = JSON.parse(Jq(t, rz)), s = n.roomInfo || {}, c = b0({ id: `douyu_${e9}`, name: s.roomName, actor: s.nickname, type_name: s.cate2Name, pic: s.roomSrc, area: s.hn, content: `https://www.douyu.com/${e9}` });
  c.type_name = fu(s.cate2Name), c.vod_remarks = "douyu";
  let l = [], d = [];
  return (n.cdnsWithName || []).forEach((m, g) => {
    l.push(`\u64AD\u653E\u5730\u5740_${String(g + 1).padStart(2, "0")}`);
    let y = [];
    for (let v of n.multirates || []) {
      let w = fu(v.rate, "-1"), T = `${t20}/getDouyuData?rid=${encodeURIComponent(e9)}&rate=${encodeURIComponent(w || "-1")}&cdn=${encodeURIComponent(fu(m.cdn))}`;
      y.push(`${fu(v.name)}$${C_(T, rz)}`);
    }
    d.push(y.join("#"));
  }), c.vod_play_from = l.join("$$$"), c.vod_play_url = d.join("$$$"), c;
}
function tqt() {
  return i20.map((e9, t) => ({ type_id: e9, type_name: KHt[t] }));
}
function x1e() {
  return { "User-Agent": ZHt, referer: "https://www.douyu.com/" };
}
async function c1e(e9, t = {}) {
  return (await t0.get(e9, { headers: t, responseType: "json", timeout: 15e3 })).data || {};
}
async function o20(e9, t = {}) {
  let n = await t0.get(e9, { headers: t, responseType: "text", transformResponse: [(s) => s], timeout: 15e3 });
  return String(n.data || "");
}
function rqt(e9, t) {
  return e9.startsWith(t) ? e9.slice(t.length) : e9;
}
function fu(e9, t = "") {
  return e9 == null || e9 === "" ? t : String(e9);
}
function n20(e9, t = 1) {
  let n = Number.parseInt(e9, 10);
  return Number.isFinite(n) && n > 0 ? n : t;
}
var xz = C0(referenceBuiltin3, 1);
var N1 = C0(referenceBuiltin4, 1);
var EN = C0(referenceBuiltin7, 1);
var _20 = referenceBuiltin8;
var N_ = referenceBuiltin2;
var h20 = "jsjiami.com.v7";
(function(e9, t, n, s, c, l, d) {
  return e9 = e9 >> 5, l = "hs", d = "hs", (function(m, g, y, v, w) {
    let T = tc;
    v = "tfi", l = v + l, w = "up", d += w, l = y(l), d = y(d), y = 0;
    let I = m();
    for (; --s + g; ) try {
      v = -parseInt(T(516, "*4y]")) / 1 + parseInt(T(590, "W^8G")) / 2 + -parseInt(T(533, "tLLA")) / 3 + parseInt(T(539, "%&I6")) / 4 + -parseInt(T(606, "FAWa")) / 5 + -parseInt(T(505, "L1R3")) / 6 * (-parseInt(T(440, "Z[e3")) / 7) + -parseInt(T(477, "]dr7")) / 8;
    } catch {
      v = y;
    } finally {
      if (w = I[l](), e9 <= s) y ? c ? v = w : c = w : y = w;
      else if (y == c.replace(/[KxwyYSIdRFJnQhWNMe=]/g, "")) {
        if (v === g) {
          I["un" + l](w);
          break;
        }
        I[d](w);
      }
    }
  })(n, t, function(m, g, y, v, w, T, I) {
    return g = "split", m = arguments[0], m = m[g](""), y = "reverse", m = m[y]("v"), v = "join", m[v]("");
  });
})(6208, 636932, SN, 196), SN && (h20 = "yc");
function g20(e9, t) {
  let n = tc, s = { fsZWz: function(y, v) {
    return y(v);
  }, oFRJn: function(y, v) {
    return y || v;
  }, KmEop: function(y, v) {
    return y(v);
  }, IhSvN: function(y, v) {
    return y(v);
  } }, c = s[n(507, "@]Gm")](String, s[n(583, "9%J[")](e9, ""))[n(540, "!2#d")]()[n(495, "A@rC")](), l = s[n(468, "!g]r")](String, t || "")[n(604, "L1R3")]();
  if (!c) throw new Error(n(487, "]dr7"));
  if (!l) throw new Error(n(471, "yd)B"));
  let d = s[n(491, "SljA")](d20, l);
  if (d) return d;
  let { payload: m } = yqt(l), g = s.KmEop(d20, m);
  if (g) return g;
  throw new Error("unsupported spade_a payload: kid=" + c + n(459, "W^8G") + m[n(433, "d&fD")]);
}
function yqt(e9) {
  let t = tc, n = { KAIXE: function(C, B) {
    return C(B);
  }, RgSQI: function(C, B) {
    return C || B;
  }, PGrfA: t(597, "mLdj"), zLdRX: function(C, B) {
    return C < B;
  }, iRMod: function(C, B) {
    return C ^ B;
  }, VAuFn: function(C, B) {
    return C ^ B;
  }, HnhRI: function(C, B) {
    return C - B;
  }, cOqTz: function(C, B) {
    return C + B;
  }, UFeCn: function(C, B) {
    return C < B;
  }, kDDSc: function(C, B) {
    return C > B;
  }, QGPuT: function(C, B) {
    return C - B;
  }, tRRmP: function(C, B) {
    return C - B;
  }, lCoBv: function(C, B) {
    return C - B;
  }, WrObd: function(C, B) {
    return C - B;
  }, bSShI: function(C, B) {
    return C + B;
  }, PBUOb: function(C, B) {
    return C - B;
  }, NAbVc: t(519, "cgK["), FxMUS: function(C, B) {
    return C === B;
  }, KGxbO: function(C, B) {
    return C < B;
  }, dhvrw: function(C, B) {
    return C < B;
  }, rRmuq: function(C, B) {
    return C - B;
  }, keiMX: function(C, B) {
    return C - B;
  }, jgAoL: function(C, B) {
    return C > B;
  }, mHBjm: function(C, B) {
    return C % B;
  }, gBpcd: function(C, B) {
    return C + B;
  }, mcrHy: function(C, B) {
    return C ^ B;
  }, goifw: function(C, B) {
    return C(B);
  }, cVYxp: function(C, B) {
    return C & B;
  }, SYIlV: function(C, B) {
    return C ^ B;
  }, vVece: function(C, B) {
    return C - B;
  }, QUgxc: function(C, B) {
    return C < B;
  }, khozs: function(C, B) {
    return C + B;
  }, jafRD: function(C, B) {
    return C < B;
  }, Qrsgv: function(C, B) {
    return C - B;
  }, kjZvj: t(465, "YuMB"), CKGtF: t(467, "W^8G"), OhQWd: function(C, B) {
    return C - B;
  }, qobgd: function(C, B) {
    return C - B;
  }, sVCnI: function(C, B) {
    return C + B;
  }, xJMKX: function(C, B) {
    return C === B;
  }, IqXVh: "app_v2", owtCr: function(C, B) {
    return C === B;
  }, FCfhj: t(559, "XCTr"), LoqVX: function(C, B) {
    return C(B);
  }, iHbji: function(C, B) {
    return C < B;
  }, OKiDo: function(C, B) {
    return C !== B;
  }, RFaHO: "AVHNq", MpUFN: function(C, B) {
    return C - B;
  }, CWnRM: function(C, B) {
    return C - B;
  }, pObuT: function(C, B) {
    return C + B;
  }, ijSRz: function(C, B) {
    return C + B;
  }, uvnjL: function(C, B) {
    return C === B;
  }, AXvCa: t(576, "7Z2#"), abYwK: function(C, B) {
    return C + B;
  } }, s = N_.Buffer[t(429, "hacN")](n[t(430, "9%J[")](String, n[t(518, "!nR*")](e9, "")).trim(), n[t(511, "tLLA")]);
  if (s[t(433, "d&fD")] < 5) throw new Error("spade_a decoded data too short: " + s[t(565, "cgK[")]);
  let c = n[t(548, "0di6")](n.SYIlV(s[0] ^ s[1], s[2]), 255), l = n[t(607, "%&I6")](c, 48), d = n[t(431, "9%J[")](n[t(450, "RG[(")](s[t(463, "C*VM")], c), 47);
  if (n[t(538, "FAWa")](l, 1) || n.QUgxc(d, 1) || n[t(553, "7Z2#")](n.khozs(1, d), s[t(502, "*%(d")]) || n[t(497, "yd)B")](n.Qrsgv(n[t(476, "c0SR")](s[t(498, "mLdj")], l), 2), 0)) if (n.FxMUS(n[t(458, "L1R3")], n.CKGtF)) {
    let C = _0x45c427[t(544, "mLdj")](n.KAIXE(_0x1e99eb, n.RgSQI(_0x3bba1d, "")).trim(), n.PGrfA);
    if (n.zLdRX(C[t(591, "tLLA")], 5)) throw new _0x163109("spade_a decoded data too short: " + C[t(485, "@]Gm")]);
    let B = n[t(496, "dL(7")](n[t(512, "Z[e3")](C[0], C[1]), C[2]) & 255, L = n.HnhRI(B, 48), q = n.cOqTz(C[t(436, "yd)B")] - B, 47);
    if (n[t(572, "1p83")](L, 1) || q < 1 || n[t(499, "($53")](n.cOqTz(1, q), C[t(577, "&K]m")]) || n.zLdRX(n[t(526, "UCDI")](n[t(432, "yd)B")](C[t(601, "P4U1")], L), 2), 0)) throw new _0x26a994(t(474, "1p83") + B + " type_len=" + L + " data_len=" + q + t(483, "cgK[") + C.length);
    let W = n[t(513, "J0IL")](C[n[t(563, "FAWa")](n.lCoBv(C[t(549, "*4y]")], L), 2)], C[n[t(480, "7Z2#")](C[t(486, "Z[e3")], L) - 1]), F = _0x3d28e1[t(461, "@]Gm")](L);
    for (let he = 0; n.zLdRX(he, L); he++) F[he] = W ^ C[n[t(600, "7W80")](n.PBUOb(C.length, L), he)];
    let J = _0x4fe615[t(484, "5M9N")](C.subarray(1, 1 + q)), ee = F[t(562, "W^8G")](n[t(453, "&K]m")]);
    _0x4cae59(J, n[t(589, "npYG")](ee, t(556, "hacN")) || n.FxMUS(ee, "web_v2"), 0);
    let ne = n.KAIXE(_0x1c4816, J[0]);
    if (n[t(566, ")]8i")](ne, 0) || n[t(557, "npYG")](q - ne, 2)) throw new _0x1e1546(t(542, "QaA@") + J[0][t(501, "tLLA")](16) + t(456, "npYG") + ee);
    let re = n[t(481, "&K]m")](n.keiMX(q, ne), 1), ae = 1, se = q - ne;
    if (n[t(547, "ZrJI")](n[t(595, "XCTr")](ae, re), J[t(545, "c0SR")]) || n[t(527, "tLLA")](se, ne) > J[t(460, "SljA")]) throw new _0x34f43c(t(550, "tLLA") + q + t(500, "@]Gm") + ne);
    return { payload: J.subarray(ae, n[t(521, "5%ht")](ae, re))[t(504, "5M9N")]("utf8"), type: J[t(478, "SljA")](se, se + ne)[t(439, "d&fD")](t(517, "C*VM")) };
  } else throw new Error(t(489, "%&I6") + c + " type_len=" + l + " data_len=" + d + t(570, "eVpN") + s[t(433, "d&fD")]);
  let m = s[n[t(514, "UCDI")](s[t(554, "ZrJI")] - l, 2)] ^ s[n.qobgd(s.length - l, 1)], g = N_.Buffer[t(506, "*%(d")](l);
  for (let C = 0; C < l; C++) g[C] = m ^ s[n[t(510, "yd)B")](s[t(442, "oiE#")], l) + C];
  let y = N_.Buffer[t(574, "1p83")](s[t(587, "C*VM")](1, n[t(529, "7W80")](1, d))), v = g[t(551, "dL(7")](n[t(457, "!2#d")]);
  Aqt(y, n.xJMKX(v, n.IqXVh) || n[t(475, "#DBd")](v, n[t(598, "YuMB")]), 0);
  let w = n[t(567, "eVpN")](kqt, y[0]);
  if (w < 0 || n[t(555, "P4U1")](d - w, 2)) throw n[t(472, "($53")]("Pjvfu", n[t(451, "dL(7")]) ? new Error(t(534, "!nR*") + y[0].toString(16) + t(528, "c0SR") + v) : new _0x409f63("invalid spade_a payload prefix: first=0x" + _0x2bc807[0][t(551, "dL(7")](16) + t(593, "UCDI") + _0x4f0c57);
  let T = n[t(445, "1p83")](d - w, 1), I = 1, N = n[t(454, "($53")](d, w);
  if (n[t(466, "atF*")](n[t(532, "dL(7")](I, T), y[t(545, "c0SR")]) || n[t(473, "yd)B")](N, w) > y.length) {
    if (n[t(479, "YuMB")](n.AXvCa, t(494, "c0SR"))) throw new Error(t(441, "Z[e3") + d + t(515, "SljA") + w);
    {
      let C = _0x5f16b9[_0x36b555], B = n.KAIXE(_0x3b9bd5, _0x589259), L = _0x4b0132 === 0 ? -21 - B : n[t(447, "5M9N")](B, 21), q = _0x4010ec;
      n.FxMUS(n[t(488, "!g]r")](_0x28035e, 2), 0) ? _0x2addff = C : (q = _0x4ef2f7, _0x36f707 = C), _0x722b2a[_0x34f599] = n[t(558, "5M9N")](n[t(503, "9%J[")](q, C), L);
    }
  }
  return { payload: y[t(592, "0di6")](I, n[t(435, "W^8G")](I, T))[t(573, "YuMB")](n[t(568, "UCDI")]), type: y[t(571, "5M9N")](N, N + w)[t(482, "FAWa")](t(608, "QaA@")) };
}
function tc(e9, t) {
  let n = SN();
  return tc = function(s, c) {
    s = s - 429;
    let l = n[s];
    if (tc.qcPigq === void 0) {
      var d = function(w) {
        let T = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789+/=", I = "", N = "";
        for (let C = 0, B, L, q = 0; L = w.charAt(q++); ~L && (B = C % 4 ? B * 64 + L : L, C++ % 4) ? I += String.fromCharCode(255 & B >> (-2 * C & 6)) : 0) L = T.indexOf(L);
        for (let C = 0, B = I.length; C < B; C++) N += "%" + ("00" + I.charCodeAt(C).toString(16)).slice(-2);
        return decodeURIComponent(N);
      };
      let v = function(w, T) {
        let I = [], N = 0, C, B = "";
        w = d(w);
        let L;
        for (L = 0; L < 256; L++) I[L] = L;
        for (L = 0; L < 256; L++) N = (N + I[L] + T.charCodeAt(L % T.length)) % 256, C = I[L], I[L] = I[N], I[N] = C;
        L = 0, N = 0;
        for (let q = 0; q < w.length; q++) L = (L + 1) % 256, N = (N + I[L]) % 256, C = I[L], I[L] = I[N], I[N] = C, B += String.fromCharCode(w.charCodeAt(q) ^ I[(I[L] + I[N]) % 256]);
        return B;
      };
      tc.brZMnC = v, e9 = arguments, tc.qcPigq = true;
    }
    let m = n[0], g = s + m, y = e9[g];
    return y ? l = y : (tc.ukGAfJ === void 0 && (tc.ukGAfJ = true), l = tc.brZMnC(l, c), e9[g] = l), l;
  }, tc(e9, t);
}
function Aqt(e9, t, n) {
  let s = tc, c = { tjjPP: function(l, d) {
    return l(d);
  }, zTEnB: function(l, d) {
    return l || d;
  }, rFEUI: function(l, d) {
    return l(d);
  }, gLXWG: s(452, "*4y]"), Hqqul: function(l, d) {
    return l === d;
  }, XdqIq: function(l, d) {
    return l % d;
  }, jFSwz: function(l, d) {
    return l + d;
  }, TIkYq: function(l, d) {
    return l ^ d;
  }, IXpkK: function(l, d) {
    return l(d);
  }, dHaxd: function(l, d) {
    return l < d;
  }, YbAbv: s(541, "7Z2#"), axKhG: function(l, d) {
    return l(d);
  }, KtqmC: function(l, d) {
    return l - d;
  }, rkjLh: function(l, d) {
    return l % d;
  }, yvHyu: function(l, d) {
    return l % d;
  }, pkdKW: function(l, d) {
    return l + d;
  }, ktopk: function(l, d) {
    return l ^ d;
  }, NMuhc: function(l, d) {
    return l(d);
  } };
  if (!t) {
    let l = 85, d = 250;
    for (let m = 0; m < e9[s(525, "dL(7")]; m++) {
      let g = e9[m], y = m20(m), v = c[s(585, ")]8i")](n, 0) ? -21 - y : y + 21, w = d;
      c[s(536, "($53")](m, 2) === 0 ? d = g : (w = l, l = g), e9[m] = c[s(599, "($53")](c[s(564, "QaA@")](w, g), v);
    }
    return;
  }
  c[s(605, "5%ht")](f20, e9);
  for (let l = 0; c[s(535, "]dr7")](l, e9[s(463, "C*VM")]); l++) if (s(586, "hacN") === c[s(581, "npYG")]) {
    let d = c[s(561, "!g]r")](_0x7dafea, c.zTEnB(_0x1cc1bd, ""))[s(449, "d&fD")]().toLowerCase(), m = c[s(464, "0di6")](_0x1f7c85, c.zTEnB(_0x4472f8, ""))[s(560, "XCTr")]();
    if (!d) throw new _0x18bca4(c[s(520, "J0IL")]);
    if (!m) throw new _0x37aab4("missing spade_a");
    let g = c[s(437, "YuMB")](_0x1a0197, m);
    if (g) return g;
    let { payload: y } = _0x2c68a4(m), v = _0x604d6b(y);
    if (v) return v;
    throw new _0x4902a5(s(552, "ZrJI") + d + s(546, "*%(d") + y[s(602, "npYG")]);
  } else {
    let d = e9[l], m = c[s(537, "d&fD")](m20, l), g = n === 0 ? c[s(443, "yd)B")](-21, m) : m + 21, y = c[s(455, "5M9N")](c[s(523, "cgK[")](l, 2), 0) ? 250 : 85, v = c[s(580, "tLLA")](c[s(543, "]dr7")](l, 2), 0) ? 85 : 250;
    e9[l] = c[s(470, "P4U1")](c.ktopk(y, d) - v, g);
  }
  c[s(438, "atF*")](f20, e9);
}
function SN() {
  let e9 = (function() {
    return [h20, "nFYyjWsjKiFINaIdwmhhRiQxx.WceMohmdS.WJv7==", "WPTkauH8", "adpcNmkcpW", "WQuqWP7cS0C", "zmokW5qzwW", "gmousINcPCoxgY4", "nmooW7u", "kfpdRW86", "wwXShImpzSoAW5f8jmkFWQW", "q3mDWONdKCkN", "kqpcNCkcb8oJWPCY", "WRlcH8krW51lW4C", "WQBcUqhcKCkO", "W6lcTveJtq", "pmkLW44QWRO", "WRJdKYJdLCkhaq", "WQvbW4DzBG", "uGJdRszG", "fSoGW7jhW6O", "rqZdGmocjCob", "aK7dJd0DhW", "g3OyBv44W61CW7f0WO4dWPa", "hCkAWRpdVG", "DsLHC0S", "oSkviciRWORcV8oMwbVdG1BdSa", "WR/dOfldMmkX", "WRlcPJFdKW", "CComW7C7", "WPnJoMrL", "WPzFagPB", "DdLwu3m", "mmooW6pdQSkXW6y", "WRZdH0ddLSkW", "cJ0gwLS", "srTOqvpcOq", "WPDOW4THva", "m8kJoNtcLW", "kmoeW57dUCk3W6FdG8kh", "x3zSp8o8WRar", "awHcgmo7WRy8W6lcItFdNCoyW77cGCkrW5RcPYixxCkxCmo2W4ldTmkWW7P+WPire2a", "i8o8wr/dQJW", "BGP3s2q", "tcVdJsu", "CmoWW5r3mW", "WRldHd/cNfO/lCkQW4RdN8keWR0q", "FNVcTXTp", "iSkTWQldGqa", "kmozW6tdOa", "WRf/nMjv", "W4ZcLCoXiX4", "WQldRHFdN8kMW6FdSsbNaSo3", "WPJcRCoXW5ri", "EXNdKanx", "vfNcLqzQ", "tL/dMYOmsG", "bSkYW40jW7S", "aSkcWOddPqK", "sY8+vhXyn8oXW5Pygmk6W7u", "W4pdSIffWQfv", "W5VcHSkgl8oL"].concat((function() {
      return ["dZ7dPHDXW7ldJW", "b8oerI/cO8on", "kddcUSk2pa", "WPPoW5vdAG", "fSkQc0/cLW", "krqBx0G", "W73dOmkGWOmo", "emkuW4aiWP4", "wqldISoUbG", "sbD1vu7cP8oJmCkqW6OSWO8tW7yE", "DWxdLXv1", "tbrvDf0", "vmoUW7Dqexz9DZhdImkMp8oHwmkmW5qxWR3cLCoUECk2W5VdJf8ulSkVr1tcGqq", "W47dKbBcLSou", "FKtdKWldKq", "WO/dHwBcVxZcTcNdNSooa8ktWR/cUW", "W5ZdOI1dWQDpW6JcMa", "WPz0W49Bsa", "W7LSsq3cVW", "WQtcVSo+W7DA", "FmomrMfHW5hdOCos", "WQpcJ2RdMtXLFmkCWP4", "ELRcIX4", "W5BcJ8kej8oYca", "bgnAhSoJWRC", "W5dcMc3dVYZdRh7cTmodamkY", "W5VdHCkNWOyt", "WQddMehdMSk4W5DAm8oPWRBdMZJcQSkWqmobFGLtzw/dV8kklxivl8o+W5xcL8kRWRy", "WRFcI8obW4zT", "W6BdVXXuWPS", "pSkAlcWKWO7cT8odDcZdUuNdKa", "u2ZdKXldNa", "uw/dTrxdOq", "WOTXW7tdQmkCWRddSMe4ESkR", "W7FcGCoDbdu", "tX9GDgm", "WRBdLZxdL8ofxq", "uWRdUGj5", "WPRcMSkyjCoGcx7cTCk+W5Krca", "w3KGWPRdL8kMaSkw", "iSk7W4H9W4/dLq", "WPLViuPR", "AeFcTWD0WOBdIsK", "x8orW6pcQLqMWOFdQCoEhmkDW4Tm", "l8kYW4P1W5G", "W5ZcMCkWf8o8", "W4BdVw3cGN0YW4vdW7tcOCoOuW", "eCklixVcGmot", "usXus3C", "F1ebWOJdPa", "pKDbp8o5", "WPNcMrpdLc4", "W53cM8k5W7Pk", "WO/dPZ1hWRnuW7hcVSocWPhcLmoF", "W7NcSvFcLCo4WRRdU0r4kSoQsG", "hSovtNa", "dCoLwCo5yW", "W7BcIw3cLG", "WPFcHWBdRa0", "xZ5GthO", "xbJcKwLAt8k0WRxcQJhcNhxdRW"].concat(/* @__PURE__ */ (function() {
        return ["W7hcLMhdOGS", "udRdQsfT", "W7lcTSo+dcxdNW", "W4pcTmk4W5H6", "tfKcWRRdNW", "culdPrddKmkf", "b8oLW6jbW6O", "W5hcLdddQZhdQG", "eSobW45c", "W67cNmoYhGu", "hszbW5FcLCo8wCkCuCkyW6i0W7W", "nSoSFmojrJq0WQ7cVL/cJ1NcOL7dLuiEFcxcT8kQW69+b11hWOpcNtZdQaNcPLtcLSkXiSoKsmkOja", "W5NcUt/dTce", "ycRdJXHR", "pCotW4BdPCkc", "CSoVCuDl", "W7JcJWpcICoTWOGks8oZWOZdIJFcUW", "pmkbW4yY", "W5X6tcBcRG", "WQ7cVcFcISkWg2dcTKNcKSofWPZdUsqUxSo+ibJdQ8kcW6r5rLZdUSoHFSo1aslcPSozW69Ft8oOWQmBFa", "W4tcHXBdTta", "WRZdGdtdNq", "rvpdSGFdGCoq", "BSkUW4DJW5FdKGPqt8kLW7fBbG", "W61NWPX7cG", "osdcPSkBbq", "WQpdOGRdI8k7W6e", "rNGfWO/dICkMcmorsSkEW4aHW54zcCkJW5hcUCoBWQxdKmkLW6ldP8k3cMWwWODmf8oQ", "W6RcVmodhYpdNH8M", "W7jUWQ5HnSo2xuLCoSoaxSoIo8orWR5fiCkeW7aRWOa0aanLWRpcJSoxWOPXW4hcJq", "W4r5rWdcLW", "W6TLWRnZmSoU", "qchdJmopoa", "DSooW6GjESon", "cKpdLcGE", "E2RcLbbI", "W7BcN0iOqv4", "W7xcIeKA", "W4ldP8kpWRWU", "hZamwwjEomoY", "FmoXr3Hd", "WPpcMZRcSSkT", "W6/cMgxdIrDH", "WQyMWPFcPgq", "CIFdJ1L8", "W5ZcSSkkW7Tn", "DWTAyuu", "hJRdN3H7W4TppqC", "B13cHHj0WP3dHJC", "AmogW6rYeW", "WPDTW7jfDIlcLsy", "w8oYW65C", "cNJcI2yIWQ/cTIBdImoIySoVpW", "W5zhBXRcJW", "WRRcICo9W6vFW4C", "oSktjYWJWOVcUSoyDZ/dQMhdVa", "wdRdKwi", "z2CcWPVdIq", "n0NdOZGF", "W7tdPCkmWQKq"];
      })());
    })());
  })();
  return SN = function() {
    return e9;
  }, SN();
}
function f20(e9) {
  let t = tc, n = { kvTqC: function(s, c) {
    return s + c;
  }, PEVVR: function(s, c) {
    return s + c;
  }, UdGmg: function(s, c) {
    return s + c;
  } };
  for (let s = 0; n.kvTqC(s, 1) < e9[t(460, "SljA")]; s += 2) {
    let c = e9[s];
    e9[s] = e9[n.PEVVR(s, 1)], e9[n.UdGmg(s, 1)] = c;
  }
}
function kqt(e9) {
  let t = tc, n = { ExtHW: function(s, c) {
    return s - c;
  }, ZEcaJ: function(s, c) {
    return s >= c;
  }, CVyfV: function(s, c) {
    return s + c;
  }, uqwmd: function(s, c) {
    return s - c;
  } };
  return e9 >= 48 && e9 <= 57 ? n.ExtHW(e9, 48) : n[t(584, "0di6")](e9, 97) && e9 <= 122 ? n.CVyfV(n[t(434, "%&I6")](e9, 97), 10) : -1;
}
function d20(e9) {
  let t = tc, n = { DEYRS: function(c, l) {
    return c || l;
  }, KzKyE: t(588, "d&fD"), htWpw: function(c, l) {
    return c(l);
  } }, s = String(n[t(469, "]Wr3")](e9, "")).trim();
  if (/^[0-9a-f]+$/i[t(444, "($53")](s)) {
    let c = N_.Buffer[t(531, "7W80")](s, n[t(569, "5%ht")]);
    if (n[t(524, "($53")](p20, c[t(530, "]dr7")])) return c;
  }
  try {
    let c = N_.Buffer[t(579, "eVpN")](s, "base64");
    if (n[t(596, "]Wr3")](p20, c[t(509, "atF*")])) return c;
  } catch {
  }
  return null;
}
function p20(e9) {
  return e9 === 16 || { agRDF: function(s, c) {
    return s === c;
  } }[tc(490, "&K]m")](e9, 24) || e9 === 32;
}
function m20(e9) {
  let t = tc, n = { KExRc: function(c, l) {
    return c & l;
  }, zZOri: function(c, l) {
    return c + l;
  }, BhiEn: function(c, l) {
    return c >>> l;
  }, akPzt: function(c, l) {
    return c * l;
  } }, s = e9 >>> 0;
  return s -= n[t(448, "L1R3")](s >>> 1, 1431655765), s = n[t(493, "c0SR")](n.KExRc(s, 858993459), s >>> 2 & 858993459), n[t(582, "!g]r")](n[t(594, "QaA@")](n.KExRc(s + (s >>> 4), 252645135), 16843009), 24);
}
var w20 = EN.default.join(process.env.NODE_PATH || process.cwd(), "vod_cache_hongguo");
var b20 = 100 * 1024 * 1024;
var vqt = 600 * 1e3;
var _qt = 10800 * 1e3;
var wqt = 16;
var S20 = 32 * 1024 * 1024;
var Sqt = [4, 8, 16, 32].map((e9) => e9 * 1024 * 1024);
var sz = /* @__PURE__ */ new Map();
var Zy = /* @__PURE__ */ new Map();
var Eqt = N1.default.promises.rm(w20, { recursive: true, force: true }).catch(() => {
});
async function cz(e9, t) {
  await Eqt, Xqt(), T20();
  let n = String(e9.query?.src || "").trim(), s = String(e9.query?.kid || "").trim().toLowerCase(), c = String(e9.query?.spade_a || "").trim();
  if (!n || !s || !c) return t.code(400), { error: "missing src, kid or spade_a" };
  if (!/^https?:\/\//i.test(n)) return t.code(400), { error: "invalid src URL" };
  if (!/^[0-9a-f]{32}$/i.test(s)) return t.code(400), { error: "kid must be 16-byte hex" };
  let l = g20(s, c), d = await Tqt({ src: n, kid: s, spadeA: c, key: l, request: e9 }), m = tzt(e9.headers.range, d.plan.total);
  if (m.unsatisfiable) return t.code(416), t.header("content-range", `bytes */${d.plan.total}`), t.header("accept-ranges", "bytes"), { error: "range not satisfiable" };
  let g = m.end - m.start + 1;
  return t.code(m.partial ? 206 : 200).header("content-type", "video/mp4").header("accept-ranges", "bytes").header("cache-control", "no-store").header("content-length", String(g)), m.partial && t.header("content-range", `bytes ${m.start}-${m.end}/${d.plan.total}`), Nqt({ request: e9, session: d, start: m.start, end: m.end, thread: v20(e9.query?.thread, 1, 4, 4), chunkSize: v20(e9.query?.chunk, 128, 1024, 512) * 1024 });
}
async function Tqt({ src: e9, kid: t, spadeA: n, key: s, request: c }) {
  let l = s.toString("hex"), d = izt(`${e9}
${t}
${n}
${l}`).slice(0, 32), m = sz.get(d);
  if (m && m.src === e9 && m.kid === t) return m.lastAccess = Date.now(), m.headers = oz(c.headers), m;
  m && await I20(m);
  let g = await Iqt({ sessionKey: d, src: e9, kid: t, headers: oz(c.headers) }), y = EN.default.join(w20, d), v = { key: d, src: e9, kid: t, keyBytes: s, plan: g, cacheDir: y, headers: oz(c.headers), chunks: /* @__PURE__ */ new Map(), inflight: /* @__PURE__ */ new Map(), cacheBytes: 0, lastAccess: Date.now(), ready: N1.default.promises.mkdir(y, { recursive: true }) };
  return sz.set(d, v), await v.ready, v;
}
async function Iqt({ sessionKey: e9, src: t, kid: n, headers: s }) {
  let c = `${e9}:plan`, l = Zy.get(c);
  if (l && l.expiresAt > Date.now()) return l.lastAccess = Date.now(), l.plan;
  let d = await Rqt(t, n, s);
  return Yqt(c, d), d;
}
async function Rqt(e9, t, n) {
  let s = null;
  for (let c of Sqt) try {
    let l = await F0.get(e9, { responseType: "arraybuffer", timeout: 3e4, headers: { ...n, Range: `bytes=0-${c - 1}` }, validateStatus: (g) => g === 200 || g === 206 }), d = Buffer.from(l.data || []), m = rzt(l.headers?.["content-range"], Number(l.headers?.["content-length"] || d.length));
    return Cqt(d, m, t);
  } catch (l) {
    s = l;
  }
  throw s || new Error("\u7EA2\u679C CENC \u5143\u6570\u636E\u89E3\u6790\u5931\u8D25");
}
function Cqt(e9, t, n) {
  let s = C1(e9, Lqt(e9), "moov");
  if (!s) throw new Error(`metadata probe \u7F3A\u5C11\u5B8C\u6574 moov\uFF0Cprobe=${e9.length}`);
  let c = [];
  for (let l of Mqt(e9, s, "trak")) {
    let d = C1(e9, l, "mdia"), m = d ? C1(e9, d, "minf") : null, g = m ? C1(e9, m, "stbl") : null;
    if (!g) continue;
    let y = jqt(e9, g);
    if (!y || y.kid !== n) continue;
    let v = C1(e9, g, "stsz"), w = C1(e9, g, "stsc"), T = C1(e9, g, "stco") || C1(e9, g, "co64"), I = C1(e9, g, "senc");
    if (!v || !w || !T || !I) continue;
    let N = Uqt(e9, v), C = T.typ === "co64" ? Fqt(e9, T) : $qt(e9, T), B = Wqt(e9, w), L = Vqt(e9, I, y.ivSize), q = Gqt(B, C, N);
    if (q.length !== N.length || L.length !== N.length) throw new Error(`sample \u6570\u91CF\u4E0D\u5339\u914D offsets=${q.length} sizes=${N.length} senc=${L.length}`);
    for (let W = 0; W < N.length; W++) c.push({ off: q[W], size: N[W], iv: L[W].iv, subSamp: L[W].subSamp });
  }
  if (!c.length) throw new Error(`\u6CA1\u6709\u627E\u5230\u5339\u914D KID \u7684 CENC \u8F68\u9053: ${n}`);
  return { total: t, samples: c, patches: Hqt(e9) };
}
function Nqt({ request: e9, session: t, start: n, end: s, thread: c, chunkSize: l }) {
  let d = new _20.PassThrough(), m = Math.floor(n / l), g = Math.floor(s / l), y = Math.max(2, c * 2), v = /* @__PURE__ */ new Map(), w = m + 1, T = m, I = false, N = true;
  return d.on("close", () => {
    I = true;
  }), B(), d;
  function C() {
    for (; !I && w <= g && v.size < y; ) {
      let L = w++;
      v.set(L, y20(t, L, l, e9.headers));
    }
  }
  async function B() {
    try {
      if (T > g || I) {
        d.end();
        return;
      }
      if (!N) {
        setTimeout(() => {
          B();
        }, 5);
        return;
      }
      T > m && C();
      let L = T * l, q = Math.min(t.plan.total - 1, (T + 1) * l - 1), W = Math.max(n, L) - L, F = Math.min(s, q) - L, J = await (v.get(T) || y20(t, T, l, e9.headers));
      if (v.delete(T), I || !J) return;
      let ee = await ezt(J, W, F);
      N = d.write(ee), N || d.once("drain", () => {
        N = true;
      }), T += 1, t.lastAccess = Date.now(), C(), setTimeout(() => {
        B();
      }, 5);
    } catch (L) {
      d.destroy(L);
    }
  }
}
async function y20(e9, t, n, s) {
  let c = await Zqt(e9, t);
  if (c?.file) return c.file;
  let l = e9.inflight.get(t);
  if (l) return l;
  let d = Oqt(e9, t, n, s).finally(() => e9.inflight.delete(t));
  return e9.inflight.set(t, d), d;
}
async function Oqt(e9, t, n, s) {
  let c = t * n, l = Math.min(e9.plan.total - 1, (t + 1) * n - 1), d = EN.default.join(e9.cacheDir, `${t}.p`), m = EN.default.join(e9.cacheDir, `${t}.${xz.default.randomUUID()}.dl`), g = await F0.get(e9.src, { responseType: "arraybuffer", timeout: 9e4, headers: { ...e9.headers, ...oz(s), Range: `bytes=${c}-${l}` }, validateStatus: (w) => w === 206 || c === 0 && w === 200 }), y = Buffer.from(g.data || []), v = l - c + 1;
  if (y.length !== v && g.status === 206) throw new Error(`range short read start=${c} end=${l} got=${y.length}`);
  if (Dqt(y, c, e9.keyBytes, e9.plan), await N1.default.promises.writeFile(m, y), await N1.default.promises.rename(m, d).catch(async () => {
    await N1.default.promises.rm(m, { force: true }).catch(() => {
    });
  }), !await R20(d)) throw new Error(`chunk ${t} cache write failed`);
  return Kqt(e9, t, d, y.length), e9.lastAccess = Date.now(), await Jqt(e9), d;
}
function Dqt(e9, t, n, s) {
  let c = t + e9.length;
  for (let l of s.patches) l.off >= t && l.off + 4 <= c && e9.write(l.to, l.off - t, 4, "ascii");
  for (let l of s.samples) l.off >= c || l.off + l.size <= t || Pqt(e9, t, n, l);
}
function Pqt(e9, t, n, s) {
  if (!s.subSamp.length) {
    A20(e9, t, n, s.iv, s.off, s.off + s.size, 0);
    return;
  }
  let c = 0, l = 0;
  for (let d of s.subSamp) {
    c += d.clear;
    let m = s.off + c, g = m + d.enc;
    A20(e9, t, n, s.iv, m, g, l), l += d.enc, c += d.enc;
  }
}
function A20(e9, t, n, s, c, l, d) {
  let m = t + e9.length, g = Math.max(t, c), y = Math.min(m, l);
  if (y <= g) return;
  let v = d + (g - c), w = e9.subarray(g - t, y - t), T = xz.default.createCipheriv(`aes-${n.length * 8}-ctr`, n, Bqt(s, v)), I = v % 16;
  I && T.update(Buffer.alloc(I)), Buffer.concat([T.update(w), T.final()]).copy(w);
}
function Bqt(e9, t) {
  let n = Buffer.alloc(16);
  Buffer.from(e9 || []).copy(n);
  let s = Math.floor(t / 16);
  for (let c = n.length - 1; c >= 0 && s > 0; c--) {
    let l = n[c] + (s & 255);
    n[c] = l & 255, s = (s >>> 8) + (l >>> 8);
  }
  return n;
}
function Lqt(e9) {
  return { off: 0, start: 0, end: e9.length, typ: "root", size: e9.length };
}
function TN(e9, t, n) {
  if (t + 8 > n || t + 8 > e9.length) return null;
  let s = e9.readUInt32BE(t), c = e9.toString("ascii", t + 4, t + 8), l = 8;
  if (s === 1) {
    if (t + 16 > n || t + 16 > e9.length) return null;
    let d = e9.readBigUInt64BE(t + 8);
    if (d > BigInt(Number.MAX_SAFE_INTEGER)) return null;
    s = Number(d), l = 16;
  } else s === 0 && (s = n - t);
  return s < l || t + s > n || t + s > e9.length ? null : { off: t, size: s, typ: c, hdr: l, start: t + l, end: t + s };
}
function E20(e9, t) {
  let n = t.start + (t.typ === "meta" ? 4 : 0), s = [];
  for (; n + 8 <= t.end; ) {
    let c = TN(e9, n, t.end);
    if (!c) break;
    s.push(c), n = c.end;
  }
  return s;
}
function C1(e9, t, n) {
  return E20(e9, t).find((s) => s.typ === n) || null;
}
function Mqt(e9, t, n) {
  return E20(e9, t).filter((s) => s.typ === n);
}
function IN(e9, t) {
  if (t.start + 4 > t.end) throw new Error(`${t.typ} fullbox \u592A\u77ED`);
  return { flags: e9[t.start + 1] << 16 | e9[t.start + 2] << 8 | e9[t.start + 3], p: t.start + 4 };
}
function Uqt(e9, t) {
  let { p: n } = IN(e9, t), s = e9.readUInt32BE(n), c = e9.readUInt32BE(n + 4);
  if (n += 8, s) return Array.from({ length: c }, () => s);
  let l = [];
  for (let d = 0; d < c; d++) l.push(e9.readUInt32BE(n + d * 4));
  return l;
}
function $qt(e9, t) {
  let { p: n } = IN(e9, t), s = e9.readUInt32BE(n);
  n += 4;
  let c = [];
  for (let l = 0; l < s; l++) c.push(e9.readUInt32BE(n + l * 4));
  return c;
}
function Fqt(e9, t) {
  let { p: n } = IN(e9, t), s = e9.readUInt32BE(n);
  n += 4;
  let c = [];
  for (let l = 0; l < s; l++) c.push(Number(e9.readBigUInt64BE(n + l * 8)));
  return c;
}
function Wqt(e9, t) {
  let { p: n } = IN(e9, t), s = e9.readUInt32BE(n);
  n += 4;
  let c = [];
  for (let l = 0; l < s; l++) {
    let d = n + l * 12;
    c.push({ firstChunk: e9.readUInt32BE(d), samplesPerChunk: e9.readUInt32BE(d + 4), sampleDescIndex: e9.readUInt32BE(d + 8) });
  }
  return c;
}
function Vqt(e9, t, n) {
  let { flags: s, p: c } = IN(e9, t), l = c, d = e9.readUInt32BE(l);
  l += 4;
  let m = [];
  for (let g = 0; g < d; g++) {
    let y = Buffer.from(e9.subarray(l, l + n));
    l += n;
    let v = [];
    if (s & 2) {
      let w = e9.readUInt16BE(l);
      l += 2;
      for (let T = 0; T < w; T++) v.push({ clear: e9.readUInt16BE(l), enc: e9.readUInt32BE(l + 2) }), l += 6;
    }
    m.push({ iv: y, subSamp: v });
  }
  return m;
}
function jqt(e9, t) {
  let n = C1(e9, t, "stsd");
  if (!n) return null;
  let s = n.start + 8;
  for (; s + 8 <= n.end; ) {
    let c = TN(e9, s, n.end);
    if (!c) break;
    let l = c.start;
    for (; l < c.end; ) {
      let d = e9.indexOf("tenc", l, "ascii");
      if (d < 0 || d >= c.end) break;
      let m = d - 4;
      if (m >= c.start) {
        let g = TN(e9, m, c.end);
        if (g?.typ === "tenc" && g.start + 24 <= g.end) {
          let y = g.start + 4;
          return { isProtected: e9[y + 2], ivSize: e9[y + 3], kid: e9.subarray(y + 4, y + 20).toString("hex") };
        }
      }
      l = d + 4;
    }
    s = c.end;
  }
  return null;
}
function Gqt(e9, t, n) {
  let s = [], c = 0;
  for (let l = 1; l <= t.length; l++) {
    let d = e9[0];
    for (let g = 0; g < e9.length; g++) {
      let y = g + 1 < e9.length ? e9[g + 1].firstChunk : 4294967295;
      if (e9[g].firstChunk <= l && l < y) {
        d = e9[g];
        break;
      }
    }
    let m = t[l - 1];
    for (let g = 0; g < d.samplesPerChunk && c < n.length; g++) s.push(m), m += n[c++];
  }
  return s;
}
function Hqt(e9) {
  let t = [];
  t.push(...qqt(e9));
  for (let [n, s] of Object.entries({ sinf: "free", senc: "free", saiz: "free", saio: "free" })) {
    let c = 0;
    for (; c + 4 <= e9.length; ) {
      let l = e9.indexOf(n, c, "ascii");
      if (l < 0) break;
      t.push({ off: l, to: s }), c = l + 4;
    }
  }
  return t;
}
function qqt(e9) {
  let t = [];
  for (let n of ["encv", "enca"]) {
    let s = 0;
    for (; s + 4 <= e9.length; ) {
      let c = e9.indexOf(n, s, "ascii");
      if (c < 0) break;
      if (c < 4) {
        s = c + 4;
        continue;
      }
      let l = TN(e9, c - 4, e9.length), d = l?.typ === n ? zqt(e9, l) : "";
      d && t.push({ off: c, to: d }), s = c + 4;
    }
  }
  return t;
}
function zqt(e9, t) {
  for (let n of k20(e9, t, "sinf")) for (let s of k20(e9, n, "frma")) if (s.start + 4 <= s.end) {
    let c = e9.toString("ascii", s.start, s.start + 4);
    if (/^[\x20-\x7e]{4}$/.test(c)) return c;
  }
  return "";
}
function k20(e9, t, n) {
  let s = [], c = t.start;
  for (; c + 4 <= t.end; ) {
    let l = e9.indexOf(n, c, "ascii");
    if (l < 0 || l >= t.end) break;
    if (l < 4) {
      c = l + 4;
      continue;
    }
    let d = TN(e9, l - 4, t.end);
    d?.typ === n && s.push(d), c = l + 4;
  }
  return s;
}
function Yqt(e9, t) {
  let n = Qqt(t), s = Date.now();
  n > S20 / 2 || (Zy.set(e9, { plan: t, bytes: n, lastAccess: s, expiresAt: s + _qt }), T20());
}
function T20() {
  let e9 = Date.now(), t = 0;
  for (let [n, s] of Zy) s.expiresAt <= e9 ? Zy.delete(n) : t += s.bytes || 0;
  for (; Zy.size > wqt || t > S20; ) {
    let n = [...Zy.entries()].sort((s, c) => s[1].lastAccess - c[1].lastAccess)[0];
    if (!n) break;
    t -= n[1].bytes || 0, Zy.delete(n[0]);
  }
}
function Qqt(e9) {
  let t = 64 + e9.samples.length * 72 + e9.patches.length * 32;
  for (let n of e9.samples) t += n.iv.length + n.subSamp.length * 8;
  return t;
}
async function Zqt(e9, t) {
  let n = e9.chunks.get(t);
  return n?.file ? await R20(n.file) ? (n.lastAccess = Date.now(), e9.lastAccess = Date.now(), n) : (e9.cacheBytes = Math.max(0, e9.cacheBytes - (n.size || 0)), e9.chunks.delete(t), null) : null;
}
function Kqt(e9, t, n, s) {
  let c = e9.chunks.get(t);
  e9.cacheBytes = Math.max(0, e9.cacheBytes - (c?.size || 0)) + s, e9.chunks.set(t, { file: n, size: s, lastAccess: Date.now() });
}
async function Jqt(e9) {
  if (e9.cacheBytes <= b20) return;
  let t = [...e9.chunks.entries()].sort((n, s) => n[1].lastAccess - s[1].lastAccess);
  for (let [n, s] of t) {
    if (e9.cacheBytes <= b20 * 0.8) break;
    e9.chunks.delete(n), e9.cacheBytes = Math.max(0, e9.cacheBytes - (s.size || 0)), await N1.default.promises.rm(s.file, { force: true }).catch(() => {
    });
  }
}
function Xqt() {
  let e9 = Date.now();
  for (let t of sz.values()) e9 - t.lastAccess > vqt && !t.inflight.size && I20(t);
}
async function I20(e9) {
  sz.delete(e9.key), e9.chunks.clear(), e9.inflight.clear(), await N1.default.promises.rm(e9.cacheDir, { recursive: true, force: true }).catch(() => {
  });
}
async function ezt(e9, t, n) {
  let s = Math.max(0, n - t + 1), c = Buffer.alloc(s), l = await N1.default.promises.open(e9, "r");
  try {
    await l.read(c, 0, s, t);
  } finally {
    await l.close();
  }
  return c;
}
function tzt(e9, t) {
  if (!e9) return { start: 0, end: Math.max(0, t - 1), partial: false };
  let n = String(e9).trim(), s = /^bytes=-(\d+)$/.exec(n);
  if (s) {
    let m = Number(s[1]);
    return !Number.isFinite(m) || m <= 0 || t <= 0 ? { start: 0, end: 0, partial: true, unsatisfiable: true } : { start: Math.max(0, t - m), end: t - 1, partial: true };
  }
  let c = /^bytes=(\d+)-(\d*)$/.exec(n);
  if (!c) return { start: 0, end: Math.max(0, t - 1), partial: false };
  let l = Number(c[1]), d = c[2] ? Number(c[2]) : t - 1;
  return !Number.isFinite(l) || l >= t || d < l ? { start: 0, end: 0, partial: true, unsatisfiable: true } : { start: Math.max(0, l), end: Number.isFinite(d) ? Math.min(t - 1, d) : t - 1, partial: true };
}
function rzt(e9, t) {
  let n = String(e9 || ""), s = /\/(\d+)$/.exec(n)?.[1];
  return Number(s || t || 0);
}
function oz(e9 = {}) {
  let t = {};
  for (let n of ["user-agent", "cookie", "referer", "origin", "authorization"]) {
    let s = e9[n] || e9[n.toLowerCase()];
    s && (t[nzt(n)] = s);
  }
  return t["User-Agent"] || (t["User-Agent"] = "Mozilla/5.0 NewWex-Hongguo/1.0"), t["Accept-Encoding"] = "identity", t;
}
function nzt(e9) {
  return e9.split("-").map((t) => t.charAt(0).toUpperCase() + t.slice(1)).join("-");
}
function v20(e9, t, n, s) {
  let c = Number.parseInt(e9, 10);
  return Number.isFinite(c) ? Math.max(t, Math.min(n, c)) : s;
}
function izt(e9) {
  return xz.default.createHash("sha256").update(e9).digest("hex");
}
async function R20(e9) {
  try {
    return await N1.default.promises.access(e9), true;
  } catch {
    return false;
  }
}
var uz = C0(referenceBuiltin0, 1);
var D_ = "https://djapi.999888456.xyz";
var azt = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36";
var C20 = "20260916";
var ozt = "c6f2a9e7d1b84c03f5a6719e2d8b0c47a13f6e9d52c8b7a4061d3e9f75b2c8a1";
var RN = 2147483647;
var N20 = 999;
function Cd(e9 = {}, t = {}) {
  let { key: n, name: s, api: c, limit: l, directPlay: d = false, categoryUrl: m, categoryOverride: g, homeVideo: y } = e9, v = { remoteWexConfig: t.remoteWexConfig };
  return { meta: { key: n, name: s, type: 3, \u7C7B\u578B: "\u77ED\u5267" }, async init() {
    return {};
  }, async home() {
    let w = await rc(`${D_}/api/${c}/home?filter=1`);
    return { class: Array.isArray(w.class) ? w.class : [], filters: w.filters || {}, ...Array.isArray(w.list) ? { list: O_(w.list) } : {} };
  }, async homeVideo() {
    return typeof y == "function" ? y({ api: c, limit: l, requestJson: rc, parseVodList: O_ }) : {};
  }, async category(w) {
    let T = w.body || {}, I = { ...T.extend || T.filters || {} }, N = String(T.id || T.tid || ""), C = Zm(I.cateId, N), B = D20(T.page || T.pg || 1);
    if (typeof g == "function") {
      let W = await g({ cateId: C, page: B, ext: I, limit: l, requestJson: rc, parseVodList: O_ });
      if (W) return W;
    }
    let L = typeof m == "function" ? m({ api: c, cateId: C, page: B, ext: I }) : h1e(c, C, B, I), q = await rc(L);
    return Me({ page: B, pagecount: RN, limit: l, total: RN, list: O_(q.list || []) });
  }, async detail(w) {
    let T = Array.isArray(w.body?.id) ? w.body.id : [w.body?.id], I = [];
    for (let N of T.filter(Boolean)) I.push(await szt(c, String(N), v));
    return l0(I);
  }, async play(w) {
    let T = String(w.body?.id || "");
    if (!T) throw new Error("\u6F2B\u5267\u64AD\u653E\u53C2\u6570\u4E3A\u7A7A");
    return d ? E0({ parse: 0, url: T, extra: { nodanmu: true } }) : pzt(await rc(`${D_}/api/${c}/play?id=${encodeURIComponent(T)}`));
  }, async search(w) {
    let T = w.body || {}, I = String(T.wd || T.key || "").trim();
    if (!I) return Me({ list: [] });
    let N = D20(T.page || T.pg || 1);
    return { ...await rc(`${D_}/api/${c}/search?wd=${encodeURIComponent(I)}&pg=${N}`), parse: 0, jx: 0, pagecount: N20, total: N20 };
  } };
}
async function szt(e9, t, n) {
  let c = (await rc(`${D_}/api/${e9}/detail?id=${encodeURIComponent(t)}`))?.list?.[0];
  if (!c) throw new Error("\u6F2B\u5267\u8BE6\u60C5\u4E3A\u7A7A");
  let l = b0({ id: t, name: c.vod_name, pic: c.vod_pic, content: c.vod_content, actor: "", director: "", vod_play_from: czt(n.remoteWexConfig), vod_play_url: c.vod_play_url || "" });
  return l.vod_remarks = c.vod_remarks || "", l.type_name = c.type_name || "", l;
}
async function rc(e9) {
  let t = await t0.get(e9, { headers: uzt(e9, "GET"), responseType: "text", transformResponse: [(n) => n], family: 4, timeout: 3e4 });
  return JSON.parse(xzt(String(t.data || "")));
}
function xzt(e9) {
  let t = String(e9 || "");
  if (!t.startsWith("v2.")) return t;
  let n = t.split(".");
  if (n.length < 3) return t;
  let s = F6e(n[1]);
  if (s.length < 32) throw new Error("\u6F2B\u5267\u52A0\u5BC6 key/iv \u65E0\u6548");
  let c = uz.default.createDecipheriv("aes-128-cbc", s.subarray(0, 16), s.subarray(16, 32));
  return Buffer.concat([c.update(Buffer.from(n[2], "base64")), c.final()]).toString("utf8");
}
function O_(e9 = []) {
  return (Array.isArray(e9) ? e9 : []).map((t) => {
    let n = Zm(t.vod_id), s = Zm(t.vod_name);
    if (!n || !s) return null;
    let c = { id: n, name: s, pic: t.vod_pic || "", remarks: t.vod_remarks || "" };
    return t.vod_tag === "folder" || n.startsWith("rank_folder:") ? Qa({ ...c, style: { type: "list" } }) : u0(c);
  }).filter(Boolean);
}
function h1e(e9, t, n, s = {}) {
  let c = new URLSearchParams({ tid: t, pg: String(n) });
  for (let [l, d] of Object.entries(s)) l === "cateId" || d === void 0 || d === null || d === "" || c.set(l, String(d));
  return `${D_}/api/${e9}/category?${c.toString()}`;
}
function czt(e9) {
  return String(e9?.Wexconfig?.vodfrom || e9?.snapshot?.()?.vodfrom || "\u64AD\u653E").trim() || "\u64AD\u653E";
}
function uzt(e9, t = "GET") {
  let n = { "User-Agent": azt };
  return lzt(e9) && Object.assign(n, fzt(t, e9)), n;
}
function lzt(e9) {
  try {
    return new URL(String(e9)).hostname === new URL(D_).hostname;
  } catch {
    return false;
  }
}
function fzt(e9, t) {
  let n = new URL(String(t)), s = String(Date.now()), c = uz.default.randomBytes(8).toString("hex"), l = dzt(n), d = [String(e9).toUpperCase(), n.pathname, l, s, c, C20].join(`
`), m = uz.default.createHmac("sha256", ozt).update(d, "utf8").digest("hex");
  return { "X-Huolong-Client": C20, "X-Huolong-Time": s, "X-Huolong-Nonce": c, "X-Huolong-Sign": m };
}
function dzt(e9) {
  let t = [];
  for (let [n, s] of e9.searchParams.entries()) n !== "__h" && t.push([n, s]);
  return t.sort((n, s) => O20(n[0], s[0]) || O20(n[1], s[1])), t.map(([n, s]) => `${n}=${s}`).join("&");
}
function O20(e9, t) {
  return e9 === t ? 0 : e9 < t ? -1 : 1;
}
function Zm(e9, t = "") {
  return e9 == null || e9 === "" ? t : String(e9);
}
function D20(e9, t = 1) {
  let n = Number.parseInt(e9, 10);
  return Number.isFinite(n) && n > 0 ? n : t;
}
function pzt(e9) {
  return !e9 || typeof e9 != "object" ? e9 : { ...e9, extra: { ...e9.extra || {}, nodanmu: true } };
}
var mzt = "rank_home";
var hzt = "rank_folder:";
var gzt = "https://cac.opple.com/yc-media/getFile?id=fa81d1107fe344028799301f85745982#.png";
var bzt = [["rank_recommend", "\u5168\u90E8-\u63A8\u8350\u699C"], ["rank_hot", "\u5168\u90E8-\u70ED\u64AD\u699C"], ["rank_zhenguo", "\u5168\u90E8-\u81FB\u679C\u699C"], ["rank_new", "\u5168\u90E8-\u65B0\u5267\u699C"], ["rank_search", "\u5168\u90E8-\u70ED\u641C\u699C"], ["rank_must_watch", "\u5168\u90E8-\u5FC5\u770B\u699C"], ["rank_collect", "\u5168\u90E8-\u6536\u85CF\u699C"], ["rank_human_recommend", "\u771F\u4EBA\u5267-\u63A8\u8350\u699C"], ["rank_human_hot", "\u771F\u4EBA\u5267-\u70ED\u64AD\u699C"], ["rank_human_new", "\u771F\u4EBA\u5267-\u65B0\u5267\u699C"], ["rank_human_search", "\u771F\u4EBA\u5267-\u70ED\u641C\u699C"], ["rank_human_must_watch", "\u771F\u4EBA\u5267-\u5FC5\u770B\u699C"], ["rank_human_collect", "\u771F\u4EBA\u5267-\u6536\u85CF\u699C"], ["rank_comic_recommend", "\u6F2B\u5267-\u63A8\u8350\u699C"], ["rank_comic_hot", "\u6F2B\u5267-\u70ED\u64AD\u699C"], ["rank_comic_new", "\u6F2B\u5267-\u65B0\u5267\u699C"], ["rank_comic_search", "\u6F2B\u5267-\u70ED\u641C\u699C"], ["rank_ai_recommend", "AI\u5267-\u63A8\u8350\u699C"], ["rank_ai_hot", "AI\u5267-\u70ED\u64AD\u699C"], ["rank_ai_new", "AI\u5267-\u65B0\u5267\u699C"], ["rank_ai_search", "AI\u5267-\u70ED\u641C\u699C"], ["rank_ai_must_watch", "AI\u5267-\u5FC5\u770B\u699C"], ["rank_ai_collect", "AI\u5267-\u6536\u85CF\u699C"]];
function B20(e9 = {}) {
  return { ...Cd({ key: "manjuhongguo", name: "\u6F2B\u5267|\u5C0F\u7EA2", api: "hongguo", limit: 18, categoryUrl: ({ api: n, cateId: s, page: c, ext: l }) => h1e(n, s, c, l), categoryOverride: ({ cateId: n }) => {
    if (n !== mzt) return null;
    let s = bzt.map(([c, l]) => Qa({ id: `${hzt}${c}`, name: l, pic: gzt, remarks: "", style: { type: "list" } }));
    return Me({ page: 1, pagecount: 1, limit: s.length, total: s.length, list: s });
  } }, e9), async play(n) {
    let s = String(n.body?.id || "");
    if (!s) throw new Error("\u7EA2\u679C\u64AD\u653E\u53C2\u6570\u4E3A\u7A7A");
    let c = await rc(`https://djapi.999888456.xyz/api/hongguo/play?id=${encodeURIComponent(s)}`), l = Array.isArray(c?.key_urls) ? c.key_urls : [];
    if (l.length) {
      let m = [];
      for (let g of l) {
        let y = P20(n, g);
        y && m.push(String(g?.name || "").trim() || "\u7EA2\u679C", y);
      }
      if (m.length) return E0({ parse: 0, url: m, extra: { nodanmu: true } });
    }
    let d = P20(n, c);
    if (!d) throw new Error("\u7EA2\u679C\u64AD\u653E\u53C2\u6570\u4E3A\u7A7A");
    return E0({ parse: 0, url: d, extra: { nodanmu: true } });
  }, async proxy(n, s) {
    return yzt(n) ? cz(n, s) : (s.code(404), { error: "unsupported hongguo proxy" });
  } };
}
function P20(e9, t = {}) {
  let n = String(t?.src || "").trim(), s = String(t?.kid || "").trim(), c = String(t?.spade_a || "").trim();
  if (!n || !s || !c) return "";
  let l = new URLSearchParams({ src: n, kid: s, spade_a: c, thread: "4", chunk: "512" });
  return `${Azt(e9)}/proxy/cenc?${l.toString()}`;
}
function yzt(e9) {
  let t = String(e9.params?.provider || "").trim(), n = String(e9.params?.["*"] || "").trim();
  return t === "cenc" || n === "cenc" || n.startsWith("cenc/");
}
function Azt(e9) {
  let t = e9.headers?.["x-forwarded-proto"] || "http", n = e9.headers?.host || "127.0.0.1", s = "/proxy", l = String(e9.url || "").split("?")[0], d = l.indexOf(s);
  return `${t}://${n}${d >= 0 ? l.slice(0, d) : "/spider/manjuhongguo/3"}`;
}
function L20(e9 = {}) {
  return Cd({ key: "manjuhuolong", name: "\u6F2B\u5267|\u5C0F\u9F99", api: "huolong", limit: 15, categoryUrl: ({ cateId: t, page: n, ext: s }) => `https://djapi.999888456.xyz/api/huolong/category?${new URLSearchParams({ tid: t, pg: String(n), itype: Zm(s.itype, "-1"), setting: Zm(s.setting, "-1"), attraction: Zm(s.attraction, "-1"), item: Zm(s.item, "-1"), sort: Zm(s.sort, "-1") }).toString()}` }, e9);
}
function M20(e9 = {}) {
  return Cd({ key: "manjuqimao", name: "\u6F2B\u5267|\u5C0F\u732B", api: "qimao", limit: 26, directPlay: true }, e9);
}
function U20(e9 = {}) {
  return Cd({ key: "manjuxifan", name: "\u6F2B\u5267|\u5C0F\u559C", api: "xifan", limit: 18, homeVideo: async () => {
    let t = await rc("https://djapi.999888456.xyz/api/xifan/category?tid=all&pg=1");
    return Me({ page: 1, pagecount: RN, limit: 18, total: RN, list: O_(t.list || []) });
  } }, e9);
}
var lz = C0(referenceBuiltin3, 1);
function fz() {
  let e9 = ["W7yYzrZcLGBcSbhdSN3cTmoAaG", "psvWW4bRnq", "WQK0W6ddK2rp", "WQ3cQCkjoa", "WO9/kmoWEWbSWRrYs8kNW6C", "W57dJCkMWPtcGCo0cCoB", "ubXjWOPF", "F0HjW5dcUq", "dSoZl8kwgSoVWOu", "ySkTFwNdMdm", "W5yNWR/cL8os", "W4K5lmkyga", "wmkRW5exWQXZcIBdMCke", "WRrKW73dJYRcKG", "pSoMW63cSmoq", "yCkfyhBdKq", "bSo0BtpdRW", "FSkUurnjW5NcLYuTWOK", "nSo7WRVcNcS", "WQaKvI9fW6iFW7K", "W6n8a08hWRzCW6lcMmo0sX3cGG", "W64Ae8kJAW", "owfzrtzOW7VdSXJcJ3qI", "W6VdS1hcTemn", "WPm6dINcLa", "dqtcH8koW7aE", "ouVdPSkGfCohWRZcTMmV", "iSkkdgKojCklDCklWQW", "W5RdLM5BW5e", "W6VdTI0ZzCk2FbKvv2JdOa", "qSkdW4X3ja", "fmoZWQhcMaZcL8os", "iv8EaSkpW7yVWRjBW7W2a8oC", "W5ldRefDW5S", "zGTfvSoB", "bmoWzg8", "n8oWWRVcPb4", "pvZdT8kcfmoqWORcTM4Y", "WQ0qcqFcMH4", "kuhdOCklcCoBWQFdQW", "W5GtW6mZWPv2usK", "W7ldVGqUoSk7W57cSgNcTW", "W6fZbKTRW6SNW6lcKmoq", "fCo0WQGRna", "WRCGrJfEW60zW6u", "aSk/dLHY", "w8o9fCoRwSkXW5KBb8oY", "wITnv8os", "WPFdLmkPpf3cSM/cJG", "WP99W6VdICkXW4TequeAWQDLWPW", "qCkepv8rpSkC", "y8kGW6hdIhpdI8ksWOyzWQlcV1BdLG", "ASkRWR0CWQ/dRSkYW4tdN8kWz8o8", "CZqqeg8/W6K", "mSoSWPu2nW", "WQdcQN1Poa", "bIn7W6yzimoOpmkWrW", "W4K2WRpcJa", "W5DttSk8WQtcQ8oI", "W4CWomobprL6W796WRa", "W4JdJwLx", "teZdKCoyWRvic8oyjvT6WPxcMq", "W6ldSca9b8oQqreyAG", "W5ddUxVcQNO", "ogbwtt5OW7NdGrZcNKWk", "mCo7W7HiWQNdRG", "W5RdMwpcQKq", "W7eYzXRcLq3dOatdGfhcTSoo", "WPJcLf5AnG", "WPi+W4RdJv0", "W5KPBSkdpvPiWOPsAa", "F8k5sJ0", "WPuRW7tdRxS", "W48xW7mKWObJrG", "WQu1vH1fW6y", "d8kvW4VcVa", "xCo6cmkFmG", "xJW/W4ZcPW", "yZGohxWL", "WO5NC8oisSkkWRdcU8kunXtcLa"];
  return fz = function() {
    return e9;
  }, fz();
}
var Ky = Nd;
(function(e9, t) {
  let n = Nd, s = e9();
  for (; ; ) try {
    if (-parseInt(n(415, "vj1J")) / 1 + -parseInt(n(385, "#zeJ")) / 2 + -parseInt(n(357, "u5Qv")) / 3 + -parseInt(n(356, "qc&g")) / 4 * (parseInt(n(367, "K3pa")) / 5) + parseInt(n(370, "lmp@")) / 6 + parseInt(n(355, "lrTC")) / 7 + -parseInt(n(390, "dcc5")) / 8 * (-parseInt(n(348, "7RZb")) / 9) === t) break;
    s.push(s.shift());
  } catch {
    s.push(s.shift());
  }
})(fz, 548 * 1069 + -1 * 1258229 + -96109 * -14);
var kzt = { getCurrentDateKey() {
  let e9 = Nd, t = { gbnYY: function(d, m) {
    return d(m);
  }, HOXOg: function(d, m) {
    return d + m;
  } }, n = /* @__PURE__ */ new Date(), s = n[e9(376, "dcc5") + "r"](), c = t[e9(342, "u5Qv")](String, t[e9(407, "6L)[")](n[e9(350, "7RZb")](), 1811 * 3 + -4 * -1249 + -3476 * 3))[e9(346, "4$bQ")](2, "0"), l = t[e9(382, "TwWG")](String, n[e9(379, "4$bQ")]())[e9(405, "7RZb")](-4841 + -1160 * -1 + 3683, "0");
  return ("" + s + c + l + e9(391, "Rw5F"))[e9(340, "#Ov4")](0, 6492 + -1847 * -3 + -12017);
}, iv: (Ky(413, "qc&g") + Ky(395, "Vb]m"))[Ky(361, "vj1J")](828 + 4485 * 2 + -9798, 2878 * 2 + 4260 + -2500 * 4), encrypt(e9) {
  let t = Ky, n = { wpodi: t(352, "TwWG") + "c", OLabl: t(389, "ZUKR"), KbOlP: t(384, "lmp@"), KZcOz: t(387, "$7pu") }, s = lz.default[t(347, "L&cQ") + t(363, "lrTC")](n[t(402, "YJEN")], this[t(412, "93gv") + t(337, "u5Qv")](), this.iv), c = s[t(411, "K3pa")](e9, n[t(353, "#Ov4")], n[t(369, "](1]")]);
  return c += s[t(414, "G*hM")](n[t(416, "sf$E")]), Buffer[t(377, "1w*z")](c, n[t(375, "x9zM")])[t(354, "ye&O")](n[t(410, "e0fU")]);
}, decrypt(e9, t) {
  let n = Ky, s = { Mygyq: n(365, "6L)[") + "c", zcemU: function(m, g) {
    return m(g);
  }, KRJPk: n(371, "%(rX"), ABWln: n(381, "3&Hi") }, c = t ? (t + n(345, "93gv"))[n(397, "#zeJ")](-1 * 7850 + -1718 + 9568, -4 * -2439 + -8790 + -950) : this[n(403, "1w*z") + n(364, "p1zu")](), l = lz.default[n(398, "a&lV") + n(409, "](1]")](s[n(349, "7Agg")], c, this.iv), d = l[n(380, "7RZb")](s[n(396, "lrTC")]($20, e9), s[n(374, "vj1J")], s[n(372, "](1]")]);
  return d += l[n(404, "u5Qv")](s[n(393, "lOQ7")]), d;
}, wexdecrypt(e9, t, n) {
  let s = Ky, c = { jaZdr: s(362, "^l7E") + "c", vXlpY: function(m, g) {
    return m(g);
  }, LwqLv: s(399, "b^13"), MIxlw: s(341, "YJEN") }, l = lz.default[s(343, "93gv") + s(388, "x9zM")](c[s(360, "7Agg")], t, n), d = l[s(344, "e0fU")](c[s(383, "f314")]($20, e9), c[s(378, "x9zM")], c[s(351, "jWh4")]);
  return d += l[s(400, "XEhv")](c[s(392, "Mb(V")]), d;
} };
function Nd(e9, t) {
  e9 = e9 - 337;
  let n = fz(), s = n[e9];
  if (Nd.ItsiTF === void 0) {
    var c = function(y) {
      let v = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789+/=", w = "", T = "";
      for (let I = 0, N, C, B = 0; C = y.charAt(B++); ~C && (N = I % 4 ? N * 64 + C : C, I++ % 4) ? w += String.fromCharCode(255 & N >> (-2 * I & 6)) : 0) C = v.indexOf(C);
      for (let I = 0, N = w.length; I < N; I++) T += "%" + ("00" + w.charCodeAt(I).toString(16)).slice(-2);
      return decodeURIComponent(T);
    };
    let g = function(y, v) {
      let w = [], T = 0, I, N = "";
      y = c(y);
      let C;
      for (C = 0; C < 256; C++) w[C] = C;
      for (C = 0; C < 256; C++) T = (T + w[C] + v.charCodeAt(C % v.length)) % 256, I = w[C], w[C] = w[T], w[T] = I;
      C = 0, T = 0;
      for (let B = 0; B < y.length; B++) C = (C + 1) % 256, T = (T + w[C]) % 256, I = w[C], w[C] = w[T], w[T] = I, N += String.fromCharCode(y.charCodeAt(B) ^ w[(w[C] + w[T]) % 256]);
      return N;
    };
    Nd.NFdQwO = g, Nd.fjrnXI = {}, Nd.ItsiTF = true;
  }
  let l = n[0], d = e9 + l, m = Nd.fjrnXI[d];
  return m ? s = m : (Nd.HRFxJF === void 0 && (Nd.HRFxJF = true), s = Nd.NFdQwO(s, t), Nd.fjrnXI[d] = s), s;
}
function $20(e9) {
  let t = Ky, n = { nSAgf: function(s, c) {
    return s(c);
  }, jLtza: function(s, c) {
    return s || c;
  } };
  return n[t(339, "G*hM")](String, n[t(401, "Vb]m")](e9, ""))[t(359, "lmp@")](/^\uFEFF/, "")[t(366, "G*hM")]();
}
var dz = kzt;
var j20 = "https://freevideo.zqqds.cn";
var vzt = `${j20}/free-video-portal/portal/`;
var _zt = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36";
var G20 = { version: "3.7.0", pname: "com.dz.hmjc", channelCode: "HMJC1000000", utdidTmp: "A20260716161211528mStog5", utdid: "45a078a3e0a0c07e9da15cc1bd98041a", userId: "", installTime: 1784189517540, boxId: "" };
function H20(e9 = {}) {
  let t = { remoteWexConfig: e9.remoteWexConfig, signServer: "", config: { ...G20 } };
  return { meta: { key: "hema", name: "\u77ED\u6F2B|\u5C0F\u9A6C", type: 3, \u7C7B\u578B: "\u77ED\u5267" }, async init(n = {}) {
    return Szt(t, n.body?.extend || n.body || {}), await q20(t), {};
  }, async home() {
    return P0(Izt(), Rzt());
  }, async homeVod(n) {
    return this.category({ ...n, body: { id: "drama_all", page: 1, extend: {} } });
  }, async homeVideo(n) {
    return this.homeVod(n);
  }, async category(n) {
    let s = n.body || {}, c = String(s.id || s.tid || "drama_all"), l = NN(s.page || s.pg || 1), d = s.extend || s.filters || {}, m = await pz(t, "1125", Nzt(c, d)), g = F20(m);
    return Me({ page: l, pagecount: Number.MAX_SAFE_INTEGER, limit: Math.max(g.length, 1), total: Number.MAX_SAFE_INTEGER, list: g });
  }, async search(n) {
    let s = n.body || {}, c = String(s.wd || s.key || "").trim(), l = NN(s.page || s.pg || 1);
    if (!c) return Me({ page: l, list: [] });
    let d = await pz(t, "1802", { keyword: c, guessReserveSwitch: 0, reservationSwitch: true, guessNewStyleSwitch: 1, guessStyle: 0 }), m = F20(d);
    return Me({ page: l, pagecount: Number.MAX_SAFE_INTEGER, limit: Math.max(m.length, 1), total: Number.MAX_SAFE_INTEGER, list: m });
  }, async detail(n) {
    let s = Array.isArray(n.body?.id) ? n.body.id : [n.body?.id], c = [];
    for (let l of s.filter(Boolean)) {
      let d = String(l), m = await pz(t, "1131", Ozt(d));
      c.push(Dzt(d, m, t));
    }
    return l0(c);
  }, async play(n) {
    let s = String(n.body?.id || "").split("|||"), c = s[0] || "", l = s[1] || "", d = s[2] || l;
    if (!c || !l) throw new Error("bad play id");
    let m = await pz(t, "1139", { bookId: c, chapterIds: [l], unClockType: "load", chapterId: d, omap: {}, tierPlaySource: { firstTierPlaySource: "\u5267\u573A", secondTierPlaySource: "\u5267\u573A-\u70ED\u64AD", thirdTierPlaySource: "\u70ED\u64AD-\u7CBE\u9009" }, resolutionRate: "720P", preview: 1, playPercentage: 0, continuousAd: 0, commentType: 2 }), g = A1e(m), y = Lzt(g, l);
    if (y || (y = mz(g)), y || (y = y1e(g, ["mp4Url", "playUrl", "videoUrl", "url", "chapterUrl"])), !y) throw new Error("play url not found");
    return E0({ parse: 0, url: y, header: Wzt(), extra: { nodanmu: true } });
  } };
}
async function q20(e9) {
  if (e9.signServer) return e9.signServer;
  let t = e9.remoteWexConfig;
  t?.requireReady && await t.requireReady();
  let n = jzt(t?.Wexsiteurl || t?.wexSiteUrl || "");
  if (!n) throw new Error("\u8377\u9A6C\u8FDC\u7A0B\u7B7E\u540D\u5730\u5740\u672A\u521D\u59CB\u5316");
  return e9.signServer = `${n}/hema/hema_sign.php`, console.log(`[ManJuAiHeMa] signServer=${e9.signServer}`), e9.signServer;
}
async function pz(e9, t, n) {
  await q20(e9);
  let s = { apiId: t, url: `${vzt}${t}`, body: JSON.stringify(n || {}), config: wzt(e9) }, c = await t0.post(e9.signServer, JSON.stringify(s), { timeout: 3e4, responseType: "text", transformResponse: [(l) => l], headers: { "Content-Type": "application/json; charset=utf-8" } });
  return Tzt(Ezt(c.data));
}
function wzt(e9) {
  return { version: e9.config.version, pname: e9.config.pname, channelCode: e9.config.channelCode, utdidTmp: e9.config.utdidTmp, utdid: e9.config.utdid, userId: e9.config.userId, installTime: e9.config.installTime, boxId: e9.config.boxId };
}
function Szt(e9, t) {
  let n = typeof t == "string" && t.trim().startsWith("{") ? Y20(t, {}) : t;
  if (!(!n || typeof n != "object")) for (let s of Object.keys(G20)) n[s] === void 0 || n[s] === null || n[s] === "" || (e9.config[s] = s === "installTime" ? Number(n[s] || e9.config[s]) : String(n[s]));
}
function Ezt(e9) {
  if (e9 && typeof e9 == "object") return e9;
  let t = String(e9 || "").trim();
  if (!t) return "";
  let n = Y20(t, null);
  if (n) return n;
  try {
    return JSON.parse(dz.decrypt(t));
  } catch {
    return t;
  }
}
function Tzt(e9) {
  if (!e9) return "";
  let n = (typeof e9 == "string" ? JSON.parse(e9) : e9)?.data;
  return n && typeof n == "object" ? JSON.stringify(n) : n != null && String(n) ? String(n) : typeof e9 == "string" ? e9 : JSON.stringify(e9);
}
function Izt() {
  return [{ type_id: "drama_all", type_name: "\u77ED\u5267" }, { type_id: "manju_all", type_name: "\u6F2B\u5267" }, { type_id: "rank_hot", type_name: "\u70ED\u64AD\u699C" }, { type_id: "rank_rise", type_name: "\u98D9\u5347\u699C" }, { type_id: "rank_new", type_name: "\u65B0\u5267\u699C" }, { type_id: "rank_search", type_name: "\u70ED\u641C\u699C" }];
}
function Rzt() {
  return { drama_all: [Czt()], manju_all: [], rank_hot: [], rank_rise: [], rank_new: [], rank_search: [] };
}
function Czt() {
  return { key: "channelId", name: "\u5206\u7C7B", value: [["\u5168\u90E8", ""], ["\u7CBE\u9009", "959"], ["\u7A7F\u8D8A", "964"], ["\u91CD\u751F", "961"], ["\u53E4\u88C5", "960"], ["\u8A00\u60C5", "963"], ["\u5F3A\u8005\u56DE\u5F52", "965"], ["\u840C\u5B9D", "967"], ["\u4F26\u7406", "962"], ["\u8D85\u80FD", "969"], ["\u540E\u6094\u6D41", "966"], ["\u4FEE\u4ED9", "968"], ["\u5E74\u4EE3", "971"], ["\u60AC\u7591", "972"], ["\u5947\u5E7B", "970"]].map(([e9, t]) => ({ n: e9, v: t })) };
}
function Nzt(e9 = "drama_all", t = {}) {
  let n = { recSwitch: true, kingKongSwitch: false, storePageId: 10002, audioBook: 1, theaterSubscriptSwitch: true, needPlayLink: 1, isOldAgeMode: false, resolutionRate: "720P", preview: 1 };
  if (e9.startsWith("rank_")) n.channelGroupId = "14", n.channelId = Uzt(e9), n.channelName = $zt(e9);
  else if (e9 === "manju_all") n.channelGroupId = "78";
  else {
    n.channelGroupId = "157";
    let s = CN(t.channelId);
    s || (s = e9.startsWith("drama_") ? e9.slice(6) : ""), s && s !== "all" && (n.channelId = NN(s, 0), n.channelName = Fzt(s));
  }
  return n;
}
function Ozt(e9) {
  return { bookId: e9, needNextChapter: 0, isNeedAlias: "", bookAlias: "", playSourceL1: "\u5267\u573A", playSourceL2: "\u5267\u573A-\u70ED\u64AD", playSourceL3: "\u70ED\u64AD-\u7CBE\u9009", resolutionRate: "720P", preview: 1, commentType: 2, excludeInfo: 0, screenClearType: 3, bottomStyle: 2, showOriginNovel: 0, interacPop: 0 };
}
function F20(e9) {
  let t = [];
  return g1e(A1e(e9), t), t;
}
function Dzt(e9, t, n) {
  let s = A1e(t), c = hz(s, "bookId", e9);
  return c || (c = gz(s, ["bookName", "bookId", "chapterList", "chapters"])), !c && O1(s) && (c = s), b0({ id: e9, name: xl(c, ["bookName", "name", "title", "bookAlias"]), pic: z20(c, ["coverWap", "cover", "coverUrl", "image", "pic"]), remarks: xl(c, ["chapterInfo", "serialCount", "latestChapterName", "status", "remark"]), content: xl(c, ["intro", "introduction", "summary", "desc", "description"]), actor: "", director: "", vod_play_from: Vzt(n.remoteWexConfig), vod_play_url: Pzt(e9, s, c) });
}
function g1e(e9, t) {
  if (Array.isArray(e9)) {
    e9.forEach((c) => g1e(c, t));
    return;
  }
  if (!O1(e9)) return;
  let n = xl(e9, ["bookId", "id", "book_id", "novelId"]), s = xl(e9, ["bookName", "name", "title", "bookAlias"]);
  if (n && s) {
    t.push(u0({ id: n, name: s, pic: z20(e9, ["coverWap", "cover", "coverUrl", "image", "pic"]), remarks: xl(e9, ["chapterInfo", "serialCount", "latestChapterName", "categoryName", "desc"]) }));
    return;
  }
  Object.values(e9).forEach((c) => g1e(c, t));
}
function Pzt(e9, t, n) {
  let s = [];
  return b1e(e9, t, s, /* @__PURE__ */ new Set()), s.length <= 1 && Bzt(e9, n, s), s.join("#");
}
function b1e(e9, t, n, s) {
  if (Array.isArray(t)) {
    t.forEach((l) => b1e(e9, l, n, s));
    return;
  }
  if (!O1(t)) return;
  let c = xl(t, ["chapterId", "chapter_id", "id"]);
  if (c && !s.has(c) && Mzt(t)) {
    s.add(c);
    let l = xl(t, ["chapterName", "name", "title"]) || String(n.length + 1), d = xl(t, ["preChapterId", "prevChapterId"]) || c;
    n.push(`${l}$${e9}|||${c}|||${d}`);
  }
  Object.values(t).forEach((l) => b1e(e9, l, n, s));
}
function Bzt(e9, t, n) {
  if (!O1(t)) return;
  let s = NN(t.updateNum, 0), c = NN(t.chapterIndex, 1), l = xl(t, ["chapterId"]);
  if (s <= 1 || !l) return;
  let d = Number(l) - Math.max(c - 1, 0);
  if (Number.isFinite(d)) {
    n.length = 0;
    for (let m = 1; m <= s; m++) {
      let g = String(d + m - 1);
      n.push(`\u7B2C${m}\u96C6$${e9}|||${g}|||${g}`);
    }
  }
}
function Lzt(e9, t) {
  let n = hz(e9, "chapterId", t), s = W20(n);
  if (s) return s;
  let c = gz(e9, ["mp4Url", "mp4SwitchUrl"]);
  return s = W20(c), s || P_(xl(c, ["mp4Url", "playUrl", "videoUrl", "url"]));
}
function W20(e9) {
  if (!O1(e9)) return "";
  let t = e9.content, n = P_(xl(t, ["mp4Url", "playUrl", "videoUrl", "url"]));
  return n || (n = P_(V20(t?.mp4SwitchUrl)), n) || (n = P_(xl(e9, ["mp4Url", "playUrl", "videoUrl", "url"])), n) ? n : P_(V20(e9.mp4SwitchUrl));
}
function mz(e9) {
  if (Array.isArray(e9)) {
    for (let s of e9) {
      let c = mz(s);
      if (c) return c;
    }
    return "";
  }
  if (O1(e9)) {
    for (let s of Object.values(e9)) {
      let c = mz(s);
      if (c) return c;
    }
    return "";
  }
  let t = CN(e9), n = P_(t);
  if (n) return n;
  if (t.startsWith("{") || t.startsWith("[")) try {
    return mz(JSON.parse(t));
  } catch {
    return "";
  }
  return "";
}
function hz(e9, t, n) {
  if (Array.isArray(e9)) {
    for (let s of e9) {
      let c = hz(s, t, n);
      if (c) return c;
    }
    return null;
  }
  if (!O1(e9)) return null;
  if (String(e9[t] ?? "") === String(n)) return e9;
  for (let s of Object.values(e9)) {
    let c = hz(s, t, n);
    if (c) return c;
  }
  return null;
}
function gz(e9, t) {
  if (Array.isArray(e9)) {
    for (let n of e9) {
      let s = gz(n, t);
      if (s) return s;
    }
    return null;
  }
  if (!O1(e9)) return null;
  if (t.some((n) => Object.prototype.hasOwnProperty.call(e9, n))) return e9;
  for (let n of Object.values(e9)) {
    let s = gz(n, t);
    if (s) return s;
  }
  return null;
}
function y1e(e9, t) {
  if (Array.isArray(e9)) {
    for (let n of e9) {
      let s = y1e(n, t);
      if (s) return s;
    }
    return "";
  }
  if (!O1(e9)) return "";
  for (let n of t) {
    let s = e9[n];
    if (s != null && String(s) && String(s) !== "null") return String(s);
  }
  for (let n of Object.values(e9)) {
    let s = y1e(n, t);
    if (s) return s;
  }
  return "";
}
function xl(e9, t) {
  if (!O1(e9)) return "";
  for (let n of t) {
    let s = e9[n];
    if (s != null && String(s) && String(s) !== "null") return String(s);
  }
  return "";
}
function z20(e9, t) {
  for (let n of t) {
    let s = xl(e9, [n]);
    if (s.startsWith("http")) return s;
  }
  return "";
}
function V20(e9) {
  if (!Array.isArray(e9)) return "";
  for (let t of e9) if (CN(t)) return CN(t);
  return "";
}
function P_(e9) {
  let t = CN(e9);
  if (!t.startsWith("http")) return "";
  let n = t.toLowerCase(), s = n.includes(".m3u8") || n.includes(".mp4"), c = n.includes(".jpg") || n.includes(".jpeg") || n.includes(".png") || n.includes(".webp");
  return s && !c ? t : "";
}
function Mzt(e9) {
  return !!(e9?.chapterId || e9?.chapterName || e9?.duration || e9?.videoId || e9?.playUrl);
}
function Uzt(e9) {
  return e9 === "rank_rise" ? 69 : e9 === "rank_new" ? 70 : e9 === "rank_search" ? 71 : 68;
}
function $zt(e9) {
  return e9 === "rank_rise" ? "\u98D9\u5347\u699C" : e9 === "rank_new" ? "\u65B0\u5267\u699C" : e9 === "rank_search" ? "\u70ED\u641C\u699C" : "\u70ED\u64AD\u699C";
}
function Fzt(e9) {
  return { 959: "\u7CBE\u9009", 964: "\u7A7F\u8D8A", 961: "\u91CD\u751F", 960: "\u53E4\u88C5", 963: "\u8A00\u60C5", 965: "\u5F3A\u8005\u56DE\u5F52", 967: "\u840C\u5B9D", 962: "\u4F26\u7406", 969: "\u8D85\u80FD", 966: "\u540E\u6094\u6D41", 968: "\u4FEE\u4ED9", 971: "\u5E74\u4EE3", 972: "\u60AC\u7591", 970: "\u5947\u5E7B" }[String(e9)] || "";
}
function Wzt() {
  return { "User-Agent": _zt, Referer: `${j20}/` };
}
function Vzt(e9) {
  return String(e9?.Wexconfig?.vodfrom || e9?.snapshot?.()?.vodfrom || "\u64AD\u653E").trim() || "\u64AD\u653E";
}
function A1e(e9) {
  if (!e9) return {};
  if (typeof e9 != "string") return e9;
  let t = e9.trim();
  return t ? JSON.parse(t) : {};
}
function O1(e9) {
  return e9 && typeof e9 == "object" && !Array.isArray(e9);
}
function Y20(e9, t) {
  try {
    return JSON.parse(e9);
  } catch {
    return t;
  }
}
function jzt(e9) {
  return String(e9 || "").replace(/\/+$/, "");
}
function CN(e9, t = "") {
  return e9 == null || e9 === "" ? t : String(e9);
}
function NN(e9, t = 1) {
  let n = Number.parseInt(e9, 10);
  return Number.isFinite(n) ? n : t;
}
var S1e = C0(referenceBuiltin0, 1);
var b60 = C0(referenceBuiltin11, 1);
var y60 = "http://45.145.75.220:8762";
var SYt = "https://huazi-1252056561.cos.ap-chengdu.myqcloud.com/dm.json";
var EYt = "238e1518-9df9-4b68-bd92-9c9bc95e7a61";
var TYt = "Dart/2.19 (dart:io)";
var IYt = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36";
var A60 = "f66xQmdOG8Dt8d7swC7jApWiPnproYbiRWSbqZJEP0rUFag5zOELq24CAVrD6o5xxD/TpU0F7wAnOZ7PZh0M9Kcv6bOMLttQKpB81CaGe3Ly/LsoKtbU9prUhAfXpgRyPV5e9Mm5/GsNUnR0eFXCpg==";
var E1e = "f66xQmdOG8Dt8d7swC7jApWiPnproYbiRWSbqZJEP0oflJGlJbl8xj0OH0vWpOR813NHx4t7sfOTfO1h/OL7glTMoopE3wXhPC3eoUYOUK81w/KeamHsOoiVwLM7LvnYgRHJJ7viUy68e0VlNTBcew==";
var RYt = "2d3faadd756109f2d7297cf02e39d31dad5ad2d7b581bd75959f8e9386582d53";
var CYt = "7a867a250fe5454585728b784c51c1d5507942a5355d6da804dfb3b128af3f3b";
var NYt = "49994546e0041330d2e84368fb2adfd4ffedc8d73db722a16120f4ff61d6fda6";
var OYt = "b3a9d90746b367473ff0842e51c867286500b80b1662c0f62dbcd327d24953eb";
var DYt = "84ebd431c1fc30f7f791efd6dbd5fec341fa4099caeeb4b4e7908a244bfd26fb";
var PYt = Buffer.from("d37d815ee526de961752ba9f0d261b13", "utf8");
var BYt = Buffer.from("386333f2e6a448b6", "utf8");
function k60(e9 = {}) {
  let t = { remoteWexConfig: e9.remoteWexConfig, signApi: "", appConfig: null, filterConfig: {}, parsingConfig: {}, classList: [] };
  return { meta: { key: "animehuazi", name: "\u82B1\u5B50|\u52A8\u6F2B", type: 3 }, async init() {
    try {
      await v60(t);
      let n = await KYt(SYt, wz());
      n?.domain && (y60 = n.domain), await _60(t);
    } catch (n) {
      console.warn(`[AnimeAiHuazi] init failed, fallback config: ${n.message}`), w60(t);
    }
    return {};
  }, async home() {
    return await LN(t), P0(t.classList.length ? t.classList : T1e(), t.filterConfig);
  }, async category(n) {
    await LN(t);
    let s = n.body || {}, c = s.extend || s.filters || {}, l = g60(s.page || s.pg || 1), d = { type_id: String(s.id || s.tid || ""), year: ya(c.year), order: ya(c.order, "time"), type_name: ya(c.type_name), page: String(l), pageSize: "21" }, m = await _z(t, "/apptov5/v1/vod/lists", d, CYt, A60);
    return Me({ page: l, pagecount: Number.MAX_SAFE_INTEGER, limit: 21, total: Number(m?.total || Number.MAX_SAFE_INTEGER), list: p60(m?.data) });
  }, async detail(n) {
    await LN(t);
    let s = Array.isArray(n.body?.id) ? n.body.id : [n.body?.id], c = [];
    for (let l of s.filter(Boolean)) c.push(await WYt(t, String(l)));
    return l0(c);
  }, async play(n) {
    await LN(t);
    let [s, c, l] = qYt(n.body?.id || ""), d = ya(l, I1e(t, s));
    try {
      let m = await VYt(t, c, d, s), g = ya(m?.url, c);
      return E0({ parse: 0, url: g, header: m60(t, s, d, m) });
    } catch (m) {
      return console.warn(`[AnimeAiHuazi] play proxy failed, return raw url: ${m.message}`), E0({ parse: 0, url: c, header: m60(t, s, d, null) });
    }
  }, async search(n) {
    await LN(t);
    let s = g60(n.body?.page || n.body?.pg || 1), c = await _z(t, "/apptov5/v1/search/lists", { wd: ya(n.body?.wd || n.body?.key), page: String(s), type: "" }, OYt, E1e);
    return Me({ page: s, pagecount: 1, limit: 21, total: Number(c?.total || 0), list: p60(c?.data) });
  } };
}
async function v60(e9) {
  if (e9.signApi) return e9.signApi;
  let t = e9.remoteWexConfig;
  t?.requireReady && await t.requireReady();
  let n = XYt(t?.Wexsiteurl || t?.wexSiteUrl || "");
  if (!n) throw new Error("\u82B1\u5B50\u8FDC\u7A0B\u7B7E\u540D\u5730\u5740\u672A\u521D\u59CB\u5316");
  return e9.signApi = `${n}/huazi/huazi_sign.php`, console.log(`[AnimeAiHuazi] signApi=${e9.signApi}`), e9.signApi;
}
async function LN(e9) {
  if (!e9.appConfig) try {
    await _60(e9);
  } catch (t) {
    console.warn(`[AnimeAiHuazi] config failed, fallback: ${t.message}`), w60(e9);
  }
}
async function _60(e9) {
  let t = await _z(e9, "/apptov5/v1/config/get", { p: "android" }, RYt, A60);
  if (!t?.get_parsing) throw new Error("bad config");
  e9.appConfig = t, LYt(e9, t), MYt(e9, t);
}
function w60(e9) {
  e9.appConfig = {}, e9.classList = T1e(), e9.filterConfig = {}, e9.parsingConfig = {};
}
function T1e() {
  return [{ type_id: "20", type_name: "\u8FDE\u8F7D\u52A8\u753B" }, { type_id: "1", type_name: "TV\u52A8\u753B" }, { type_id: "2", type_name: "\u5267\u573A\u7248" }, { type_id: "3", type_name: "\u7279\u6444" }, { type_id: "4", type_name: "\u7F8E\u6F2B" }];
}
function LYt(e9, t) {
  e9.parsingConfig = {};
  for (let n of t?.get_parsing?.lists || []) {
    if (!n || n.state === false) continue;
    let s = ya(n.key);
    s && (e9.parsingConfig[s] = n);
  }
}
function MYt(e9, t) {
  e9.classList = [], e9.filterConfig = {};
  let n = Array.isArray(t?.get_home_cate) ? t.get_home_cate : [];
  for (let s of n) {
    let c = ya(s?.cate), l = cf(s?.title);
    if (!c || !l || c === "22" || l === "\u97E9\u5267") continue;
    e9.classList.push({ type_id: c, type_name: l });
    let d = UYt(s);
    d.length && (e9.filterConfig[c] = d);
  }
  e9.classList.length || (e9.classList = T1e());
}
function UYt(e9) {
  let t = [], n = e9?.extend || {};
  return e9?.is_show_extend_cate && $Yt(t, n.types), e9?.is_show_extend_area && w1e(t, "area", "\u5730\u533A", n.area_list), e9?.is_show_extend_lang && w1e(t, "lang", "\u8BED\u8A00", n.lang_list), e9?.is_show_extend_year && w1e(t, "year", "\u5E74\u4EFD", n.year_list), e9?.is_show_extend_order && FYt(t), t;
}
function $Yt(e9, t) {
  if (!Array.isArray(t) || !t.length) return;
  let n = [{ n: "\u5168\u90E8", v: "" }];
  for (let s of t) {
    let c = cf(s?.type_name);
    c && n.push({ n: c, v: c });
  }
  e9.push({ key: "type_name", name: "\u7C7B\u578B", value: n });
}
function w1e(e9, t, n, s) {
  if (!Array.isArray(s) || !s.length) return;
  let c = [{ n: "\u5168\u90E8", v: "" }];
  for (let l of s) {
    let d = cf(l);
    d && c.push({ n: d, v: d });
  }
  e9.push({ key: t, name: n, value: c });
}
function FYt(e9) {
  e9.push({ key: "order", name: "\u6392\u5E8F", value: [{ n: "\u6700\u65B0", v: "time" }, { n: "\u6700\u70ED", v: "hits" }, { n: "\u8BC4\u5206", v: "score" }] });
}
async function WYt(e9, t) {
  let n = await _z(e9, "/apptov5/v1/vod/getVod", { id: t }, NYt, E1e), s = [], c = [];
  (Array.isArray(n?.vod_play_list) ? n.vod_play_list : []).forEach((m, g) => {
    let y = m?.player_info || {}, v = ya(y.from), w = cf(y.show || `Line${g + 1}`), T = [];
    (Array.isArray(m?.urls) ? m.urls : []).forEach((N, C) => {
      let B = ya(N?.url);
      if (!B) return;
      let L = ya(N?.from, v), q = cf(N?.name || `EP${C + 1}`);
      T.push(`${q}$${HYt(L, B, I1e(e9, L))}`);
    }), T.length && (s.push(w), c.push(T.join("#")));
  });
  let d = b0({ id: t, name: cf(n?.vod_name), pic: ya(n?.vod_pic), year: ya(n?.vod_year), area: cf(n?.vod_area), actor: cf(n?.vod_actor), director: cf(n?.vod_director), content: JYt(cf(n?.vod_content || n?.vod_blurb)), vod_play_from: s.join("$$$"), vod_play_url: c.join("$$$") });
  return d.vod_remarks = cf(n?.vod_remarks), d;
}
async function _z(e9, t, n, s, c) {
  let l = await S60(e9, t, n, s, c), d = await t0.get(l, { headers: wz(), responseType: "json", timeout: 2e4 });
  return E60(d.data || {});
}
async function VYt(e9, t, n, s) {
  let c = await S60(e9, "/apptov5/v1/parsing/proxy", {}, DYt, E1e), l = zYt({ play_url: t, label: ya(n, I1e(e9, s)), key: ya(s, "yunjie") }), d = await t0.post(c, l.body, { headers: { ...wz(), "Content-Type": l.contentType }, responseType: "json", timeout: 2e4, transformRequest: [(m) => m] });
  return E60(d.data || {});
}
async function S60(e9, t, n, s, c) {
  let l = await jYt(e9, n, s, c), d = new URLSearchParams();
  for (let [m, g] of Object.entries(n || {})) d.append(m, ya(g));
  return d.append("__platform", "android"), d.append("sign", l), `${y60}${t}?${d.toString()}`;
}
async function jYt(e9, t, n, s) {
  await v60(e9);
  let c = { __deviceId: n, __brand: "OPPO", __model: "PMT110/BP2A.250605.015", __time: String(Math.floor(Date.now() / 1e3)), __ic: s, params: t || {} }, l = await t0.post(e9.signApi, JSON.stringify(c), { headers: { ...wz(), "Content-Type": "application/json; charset=utf-8" }, responseType: "json", timeout: 15e3, transformRequest: [(m) => m] }), d = ya(l.data?.sign);
  if (!d) throw new Error(`remote sign empty: ${JSON.stringify(l.data).slice(0, 200)}`);
  return d;
}
function E60(e9) {
  let t = e9?.data;
  return typeof t == "string" && t.startsWith("##d") ? JSON.parse(GYt(t)) : t && typeof t == "object" ? t : e9 || {};
}
function GYt(e9) {
  let t = Buffer.from(e9.slice(3), "base64"), n = b60.default.inflateRawSync(t.subarray(1)), s = Buffer.from(n.toString("utf8"), "base64"), c = S1e.default.createDecipheriv("aes-256-cbc", PYt, BYt);
  return Buffer.concat([c.update(s), c.final()]).toString("utf8");
}
function p60(e9) {
  return Array.isArray(e9) ? e9.map((t) => u0({ id: t?.vod_id, name: cf(t?.vod_name), pic: t?.vod_pic, remarks: cf(t?.vod_remarks) })).filter((t) => t.vod_id && t.vod_name) : [];
}
function I1e(e9, t) {
  let n = e9.parsingConfig[ya(t)]?.config || [];
  if (!Array.isArray(n) || !n.length) return "1";
  let s = n.find((c) => c?.enabled !== false);
  return ya((s || n[0])?.label, "1");
}
function HYt(e9, t, n) {
  return Buffer.from(`${ya(e9)}	${ya(t)}	${ya(n, "1")}`, "utf8").toString("base64");
}
function qYt(e9) {
  try {
    let t = Buffer.from(String(e9 || ""), "base64").toString("utf8").split("	");
    return [t[0] || "", t[1] || e9, t[2] || "1"];
  } catch {
    return ["", e9, "1"];
  }
}
function zYt(e9) {
  let t = `----AnimeHuazi${S1e.default.randomBytes(12).toString("hex")}`, n = [];
  for (let [s, c] of Object.entries(e9)) n.push(`--${t}\r
`), n.push(`Content-Disposition: form-data; name="${s}"\r
\r
`), n.push(`${ya(c)}\r
`);
  return n.push(`--${t}--\r
`), { body: n.join(""), contentType: `multipart/form-data; boundary=${t}` };
}
function m60(e9, t, n, s) {
  let c = { "User-Agent": IYt };
  return YYt(e9, c, t, n), QYt(c, s), c;
}
function YYt(e9, t, n, s) {
  let l = (e9.parsingConfig[ya(n)]?.config || []).find((d) => ya(d?.label) === ya(s));
  l && T60(t, l.headers);
}
function QYt(e9, t) {
  if (!t) return;
  let n = t.headers;
  if (n && !Array.isArray(n) && typeof n == "object") for (let [s, c] of Object.entries(n)) MN(e9, s, c);
  T60(e9, n), MN(e9, "User-Agent", t["user-agent"] || t["User-Agent"]), MN(e9, "Referer", t.referer || t.Referer), MN(e9, "Origin", t.origin || t.Origin);
}
function T60(e9, t) {
  if (Array.isArray(t)) for (let n of t) MN(e9, n?.key, n?.value);
}
function MN(e9, t, n) {
  !t || !n || (e9[ZYt(t)] = String(n));
}
function ZYt(e9) {
  return /^user-agent$/i.test(e9) ? "User-Agent" : /^referer$/i.test(e9) ? "Referer" : /^origin$/i.test(e9) ? "Origin" : e9;
}
function wz() {
  return { "User-Agent": TYt, "appto-local-uuid": EYt };
}
async function KYt(e9, t) {
  return (await t0.get(e9, { headers: t, responseType: "json", timeout: 15e3 })).data || {};
}
function JYt(e9) {
  return ya(e9).replace(/<[^>]+>/g, "").replace(/&nbsp;/g, " ").trim();
}
function cf(e9) {
  let t = ya(e9);
  if (!t) return "";
  try {
    let n = Buffer.from(t, "binary").toString("utf8");
    return h60(n) < h60(t) ? n : t;
  } catch {
    return t;
  }
}
function h60(e9) {
  let t = 0, n = "\u5A06\u6D63\u9422\u95C6\u699B\u8930\u7ECF\u7EE0\u6769\u934A\u9354\u72B2\u6FC2";
  for (let s of ya(e9)) n.includes(s) && t++;
  return t;
}
function XYt(e9) {
  return String(e9 || "").replace(/\/+$/, "");
}
function ya(e9, t = "") {
  return e9 == null || e9 === "" ? t : String(e9);
}
function g60(e9, t = 1) {
  let n = Number.parseInt(e9, 10);
  return Number.isFinite(n) && n > 0 ? n : t;
}
var eQt = "https://www.mdzyapi.com/api.php/provide/vod";
var tQt = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36";
function R60(e9 = {}) {
  let t = { remoteWexConfig: e9.remoteWexConfig };
  return { meta: { key: "animemodu", name: "\u9B54\u90FD|\u52A8\u6F2B", type: 3, \u7C7B\u578B: "\u52A8\u6F2B" }, async init() {
    return {};
  }, async home() {
    return { ...P0([{ type_id: "1", type_name: "\u56FD\u4EA7\u52A8\u6F2B" }, { type_id: "2", type_name: "\u65E5\u97E9\u52A8\u6F2B" }, { type_id: "3", type_name: "\u6B27\u7F8E\u52A8\u6F2B" }, { type_id: "4", type_name: "\u6E2F\u53F0\u52A8\u6F2B" }, { type_id: "5", type_name: "\u52A8\u6F2B\u7535\u5F71" }], {}) };
  }, async category(n) {
    let s = n.body || {}, c = s.extend || {}, l = M_(s.page || s.pg || 1), d = Sz(c.cateId || s.id || s.tid), m = await R1e(`?ac=detail&t=${encodeURIComponent(d)}&pg=${l}`);
    return Me({ page: M_(m.page, l), pagecount: M_(m.pagecount, Number.MAX_SAFE_INTEGER), limit: M_(m.limit, 20), total: M_(m.total, Number.MAX_SAFE_INTEGER), list: I60(m) });
  }, async detail(n) {
    let s = Array.isArray(n.body?.id) ? n.body.id : [n.body?.id], c = [];
    for (let l of s.filter(Boolean)) c.push(await rQt(t, String(l)));
    return l0(c);
  }, async play(n) {
    return E0({ parse: 0, url: Sz(n.body?.id), header: C60() });
  }, async search(n) {
    let s = Sz(n.body?.wd || n.body?.key), c = M_(n.body?.page || n.body?.pg || 1);
    if (!s) return Me({ page: c, pagecount: 1, list: [] });
    let l = await R1e(`?ac=detail&pg=${c}&wd=${encodeURIComponent(s)}`);
    return Me({ page: c, pagecount: 1, list: I60(l) });
  } };
}
async function rQt(e9, t) {
  let n = await R1e(`?ac=detail&ids=${encodeURIComponent(t)}`), s = Array.isArray(n?.list) ? n.list[0] : null;
  if (!s) throw new Error("\u9B54\u90FD\u52A8\u6F2B\u8BE6\u60C5\u4E3A\u7A7A");
  return b0({ id: t, name: s.vod_name, pic: s.vod_pic, year: s.vod_year, content: s.vod_content, director: s.vod_director, actor: s.vod_actor, vod_play_from: nQt(e9), vod_play_url: s.vod_play_url });
}
async function R1e(e9) {
  return (await t0.get(`${eQt}${e9}`, { headers: C60(), responseType: "json", timeout: 2e4 })).data || {};
}
function I60(e9) {
  return (Array.isArray(e9?.list) ? e9.list : []).map((n) => u0({ id: n?.vod_id, name: n?.vod_name, pic: n?.vod_pic, remarks: n?.vod_remarks })).filter((n) => n.vod_id && n.vod_name);
}
function nQt(e9) {
  return Sz(e9.remoteWexConfig?.Wexconfig?.vodfrom) || "\u64AD\u653E";
}
function C60() {
  return { "User-Agent": tQt };
}
function Sz(e9, t = "") {
  return e9 == null || e9 === "" ? t : String(e9);
}
function M_(e9, t = 1) {
  let n = Number.parseInt(e9, 10);
  return Number.isFinite(n) && n > 0 ? n : t;
}
var Ez = C0(referenceBuiltin0, 1);
var U_ = Od;
(function(e9, t) {
  let n = Od, s = e9();
  for (; ; ) try {
    if (-parseInt(n(438, "SdTD")) / 1 + parseInt(n(480, "SVsR")) / 2 * (parseInt(n(495, "[0Un")) / 3) + parseInt(n(497, "poiM")) / 4 + -parseInt(n(496, "0)I(")) / 5 * (parseInt(n(442, "w%aO")) / 6) + parseInt(n(505, "5t!1")) / 7 * (-parseInt(n(460, "$xiS")) / 8) + -parseInt(n(469, "q!Se")) / 9 * (-parseInt(n(511, "poiM")) / 10) + parseInt(n(462, "i]1)")) / 11 * (parseInt(n(453, "oPe6")) / 12) === t) break;
    s.push(s.shift());
  } catch {
    s.push(s.shift());
  }
})(Tz, 690578);
function Tz() {
  let e9 = ["WRxcVCoOB8kPW6TIWPddNmk/WRux", "f8oEW7TQdSkJ", "FSkFW4FcVmoKW5XJdw0AdmoujG", "W4GpWP7cSa9yW7FcQspdJq", "BCkgmICr", "WOjAWPCexufYyhldSCkLbeG", "ySk/W6VdUSopkYP4CuO", "dCkMWQ3cKwK", "W7BdV8kSWObN", "WO0mW5jPjGGj", "W5bCW7vveN1yqmkYEW", "W7VcVSotuW", "wCk0W7/cKCo2rmkJW4y", "fuVdMSkZDJFdICkPoSoxs8omW6C", "DmoWW53cLu3dHW", "shaxlmoc", "bCkDysaG", "FqyFl3S", "WOZdTSkwWRdcJG", "bmo+W7ydE0q8", "m8ojva8vW4lcIrOAW5qWWRq", "FCkzW4ddJmkrWOaGfwe", "kmkIes8TWR0p", "WQnwW7FcItK", "WOtdMCkRpqq", "tCkPW6NcMmoRt8koWPVdH8kC", "DmoMWOuShCkjcHa+W43cMSo+", "W7K0fmocWPiPBwRcG2VcLG", "W5xcRJzHAJaoW7BcSSov", "W6hcOJOpWOi", "W5rbdfrjoG", "W54nWP/cSa9y", "o8ogWOBdOSk+WOyZEW", "z3u/a8oZ", "umkia1Tr", "cqDCEIZdGCkb", "W7mKW6mpsmk6WQG", "WRVdRNXVW6FcTmkssmkBWQjJWQpcRG", "mCoEW7XQC8oYWO8", "W5mmW5D3hrqUtfhdOG", "W77dVmoPW67cLq", "WQtcQConzH3dShq", "rmohoNv2W6PSW78AALhcRmk0", "jCo4W6ZdH20", "W5pdPmkOW5q", "W6tdPgBcTfaDnN1f", "W4qbW4zdaq4", "A8ofdwSeW47cH1dcNSoo", "W6PQyHJcVgClD2RcQW", "W44pWPlcPW", "js7dKLGk", "WR/dPxPOW6xcV8ksDCkTWQPpWQVcRa", "WRldN8kNmce", "WQz2uCkyW7e", "WRzpW6vnBW", "WRfqW4RcNcCmWPrG", "CszLW6hdR8kHbSkQ", "W5jlW6mzvYOKcmkYCa", "W5KasIRdGLOfgSopW4iq", "WOn7WR57yW", "c8o/W4NdI20", "k8omWOhdH8k4WOyUkW", "qSkmWRa7cSkNW4ddSmookGi1WPS", "W4HvavbvpG", "qCotW5u7ru8elG", "W67cSZOzWRhdSSoh", "ub4wFa", "smkYW6lcMmoZ", "W69MEdRcU2W", "W7ipW5i1WONdVa", "vWZcHmk/", "a8kbBciXWRS", "jmkPWPZdGKZdGCoHCSkYb8o8WO1s", "WQ3cQCouW5BcGYK1va", "WRLVtmkwW4i", "C8oVe8klCa", "W7BcKwFcOI/dLsZdOSkRW5jEWO0", "eSoAW7XmtCoLWOtdGCo5fa", "qCoduq42WR8pW4K", "W5nyW7uDfxS"];
  return Tz = function() {
    return e9;
  }, Tz();
}
function Od(e9, t) {
  e9 = e9 - (-2192 * -2 + -9795 + 5849);
  let n = Tz(), s = n[e9];
  if (Od.IfSZDm === void 0) {
    var c = function(y) {
      let v = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789+/=", w = "", T = "";
      for (let I = 0, N, C, B = 0; C = y.charAt(B++); ~C && (N = I % 4 ? N * 64 + C : C, I++ % 4) ? w += String.fromCharCode(255 & N >> (-2 * I & 6)) : 0) C = v.indexOf(C);
      for (let I = 0, N = w.length; I < N; I++) T += "%" + ("00" + w.charCodeAt(I).toString(16)).slice(-2);
      return decodeURIComponent(T);
    };
    let g = function(y, v) {
      let w = [], T = 0, I, N = "";
      y = c(y);
      let C;
      for (C = 0; C < 256; C++) w[C] = C;
      for (C = 0; C < 256; C++) T = (T + w[C] + v.charCodeAt(C % v.length)) % 256, I = w[C], w[C] = w[T], w[T] = I;
      C = 0, T = 0;
      for (let B = 0; B < y.length; B++) C = (C + 1) % 256, T = (T + w[C]) % 256, I = w[C], w[C] = w[T], w[T] = I, N += String.fromCharCode(y.charCodeAt(B) ^ w[(w[C] + w[T]) % 256]);
      return N;
    };
    Od.bVJqry = g, Od.yQgAgg = {}, Od.IfSZDm = true;
  }
  let l = n[0], d = e9 + l, m = Od.yQgAgg[d];
  return m ? s = m : (Od.nJFbly === void 0 && (Od.nJFbly = true), s = Od.bVJqry(s, t), Od.yQgAgg[d] = s), s;
}
var iQt = { getCurrentDateKey() {
  let e9 = Od, t = { lutmV: function(d, m) {
    return d(m);
  }, EGKwP: function(d, m) {
    return d + m;
  } }, n = /* @__PURE__ */ new Date(), s = n[e9(499, "q!Se") + "r"](), c = t[e9(439, "c3GC")](String, t[e9(478, "aKbP")](n[e9(441, "i]1)")](), -271 * -31 + 1209 + -9609))[e9(444, "rg$]")](2, "0"), l = t[e9(513, "spv4")](String, n[e9(445, "poiM")]())[e9(516, "6NZX")](2, "0");
  return ("" + s + c + l + e9(492, "i]1)"))[e9(476, "B45J")](-948 * -3 + 8203 + -1 * 11047, 8094 + -1 * 8078);
}, iv: (U_(466, "3#9m") + U_(443, "rUuG"))[U_(464, "#^RP")](5075 * -1 + -2 * -1005 + 3065, 13931 + -605 * 23), encrypt(e9) {
  let t = U_, n = { dgdue: t(470, "4mpP") + "c", httRR: t(504, "WAH1"), Xlokb: t(448, "IoRj"), xIJaP: t(474, "#hXE") }, s = this[t(457, "w%aO") + t(498, "w%aO")](), c = Ez.default[t(463, "#aOE") + t(509, "#aOE")](n[t(500, "oPe6")], s, this.iv), l = c[t(451, "B45J")](e9, n[t(489, "poiM")], n[t(493, "(0Ug")]);
  return l += c[t(484, "7$[f")](n[t(467, "6#^r")]), Buffer[t(471, "9bJ*")](l, n[t(477, "iu*C")])[t(515, "(Dcn")](n[t(514, "bqPZ")]);
}, decrypt(e9, t) {
  let n = U_, s = { pCnYj: n(507, "q$8y") + "c", yuBau: n(461, "w%aO"), PoblI: n(450, "Qsb^") }, c = t ? (t + n(472, "*@ss"))[n(454, "spv4")](-3938 + 1 * -3169 + 2369 * 3, 16) : this[n(508, "IoRj") + n(498, "w%aO")](), l = Ez.default[n(517, "4mpP") + n(506, "q!Se")](s[n(455, "t%9u")], c, this.iv), d = l[n(491, "#aOE")](e9, s[n(440, "P3g7")], s[n(468, "WAH1")]);
  return d += l[n(483, "(Dcn")](s[n(512, "7$[f")]), d;
}, wexdecrypt(e9, t, n) {
  let s = U_, c = { iDBlY: s(488, "iZZU") + "c", wiGDS: s(459, "4mpP"), Wrgmu: s(446, "iu*C") }, l = Ez.default[s(485, "*@ss") + s(449, "2Xzf")](c[s(510, "L5z%")], t, n), d = l[s(490, "rUuG")](e9, c[s(475, "(0Ug")], c[s(494, "SVsR")]);
  return d += l[s(447, "*@ss")](c[s(503, "P3g7")]), d;
} };
var $_ = iQt;
var Jy = 20;
var aQt = "libmpv";
var P1e = "https://www.cycani.org";
function B1e(e9 = {}) {
  return mQt({ key: "animexifan", name: "\u7A00\u996D|\u52A8\u6F2B", dohHost: "appa.xifandm.net", signSite: "xifan" }, e9);
}
function mQt(e9 = {}, t = {}) {
  let n = { remoteWexConfig: t.remoteWexConfig, baseUrl: "", signServer: "", baseHeaders: EQt(e9.appVersion || "5.4.4"), jxPrefix: [] };
  return { meta: { key: e9.key, name: e9.name, type: 3, \u7C7B\u578B: "\u52A8\u6F2B" }, async init() {
    return await B60(n, e9), {};
  }, async home() {
    await UN(n, e9);
    let s = await F_(n, e9, "/index/nav", {}), c = [], l = {};
    for (let d of du(Ki(s, ["data", 3, "3", 1]))) {
      if (!Dd(d)) continue;
      let m = Ar(Ki(d, ["type_id", 1, "1"])).trim(), g = Ar(Ki(d, ["type_name", 2, "2"])).trim();
      !m || !g || g === "[object Object]" || (c.push({ type_id: m, type_name: g }), l[m] = vQt(Ki(d, ["filters", 3, "3"])));
    }
    return P0(c, l);
  }, async homeVideo() {
    await UN(n, e9);
    let s = await F_(n, e9, "/index/video", {}), c = [];
    for (let l of du(Ki(s, ["data", 3, "3", 1]))) if (Dd(l)) for (let d of du(Ki(l, ["list", 5, "5"]))) {
      let m = O1e(d, ["remarks", 5, "5"]);
      m && c.push(m);
    }
    return Me({ page: 1, pagecount: 1, list: c });
  }, async category(s) {
    await UN(n, e9);
    let c = s.body || {}, l = c.extend || c.filters || {}, d = V_(c.page || c.pg || 1), m = { tid: Ar(c.id || c.tid), page: String(d), limit: String(Jy), order: "time", ...M60(l) }, g = await F_(n, e9, "/v2/video/query", m), { total: y, list: v } = kQt(g);
    return Me({ page: d, pagecount: y > 0 ? Math.ceil(y / Jy) : 1, limit: Jy, total: y, list: v });
  }, async detail(s) {
    await UN(n, e9);
    let c = Array.isArray(s.body?.id) ? s.body.id : [s.body?.id], l = [];
    for (let d of c.map(Ar).filter(Boolean)) l.push(await hQt(n, e9, d));
    return l0(l);
  }, async play(s) {
    let [c, l = "0"] = Ar(s.body?.id).split("@@"), d = c, m = n.jxPrefix.find((g) => d.startsWith(g));
    if (l === "1" || m) try {
      let g = await t0.get(d, { responseType: "json", timeout: 15e3, transformResponse: [(y) => U60(y)] });
      d = Ar(g.data?.url, m ? d.replace(m, "") : d);
    } catch {
      m && (d = d.replace(m, ""));
    }
    return E0({ parse: 0, url: d, header: { "User-Agent": aQt } });
  }, async search(s) {
    await UN(n, e9);
    let c = Ar(s.body?.wd || s.body?.key), l = V_(s.body?.page || s.body?.pg || 1);
    if (!c) return Me({ page: l, pagecount: 1, limit: Jy, total: 0, list: [] });
    let d = await F_(n, e9, "/v2/video/search", { text: c, pg: String(l), type_id: "0", limit: String(Jy) }), m = D1e(Ki(d, ["total", 3, 1, "3", "1"])), g = Ki(d, ["data", 4, 3, "4", "3"]), y = du(g).map((v) => O1e(v, ["remarks", 8, 5, "8", "5"])).filter(Boolean);
    return Me({ page: l, pagecount: m > 0 ? Math.ceil(m / Jy) : 1, limit: Jy, total: m, list: y });
  } };
}
async function hQt(e9, t, n) {
  let s = await F_(e9, t, `/v2/video/info/${encodeURIComponent(n)}`, {}), c = Ki(s, ["data", 3, "3"]), l = [], d = [];
  if (Dd(c)) for (let m of du(Ki(c, ["vod_play_from", 24, 20, "24", "20"]))) {
    if (!Dd(m)) continue;
    let g = Ar(Ki(m, ["code", 1, "1"])).trim(), y = Ar(Ki(m, ["name", 2, "2"]), g).trim();
    if (!g || g === "null") continue;
    (!y || y === "null") && (y = g);
    let v = await F_(e9, t, "/video/play_url", { id: n, from: g, index: "-1" }), w = du(Ki(v, ["data", 3, "3"])).map((T) => {
      if (!Dd(T)) return "";
      let I = Ar(Ki(T, ["name", 1, "1"])), N = Ar(Ki(T, ["url", "play_url", 2, "2"])), C = Ar(Ki(T, ["parse", 3, "3"]), "0");
      return N && N !== "null" ? `${I}$${N}@@${C}` : "";
    }).filter(Boolean);
    w.length && (l.push(y), d.push(w.join("#")));
  }
  return b0({ id: n, name: Ar(Ki(c, ["vod_name", 2, "2"])), pic: Ar(Ki(c, ["vod_pic", 4, "4"])), content: Ar(Ki(c, ["vod_content", 15, "15"])), typeName: Ar(Ki(c, ["vod_class", 6, "6"])), vod_play_from: l.join("$$$"), vod_play_url: d.join("$$$") });
}
async function UN(e9, t) {
  if (!e9.baseUrl && (await B60(e9, t), !e9.baseUrl)) throw new Error(`${t.name}\u5730\u5740\u521D\u59CB\u5316\u5931\u8D25`);
}
async function B60(e9, t) {
  try {
    e9.baseUrl = "", e9.signServer = await gQt(e9), e9.jxPrefix = [];
    let n = await bQt(t.dohHost);
    for (let s of n) if (await yQt(s, e9.baseHeaders)) {
      e9.baseUrl = Cz(s);
      break;
    }
    console.log(`[${t.key}] baseUrl=${e9.baseUrl || "-"}, signServer=${e9.signServer}`);
  } catch (n) {
    e9.baseUrl = "", console.warn(`[${t.key}] init failed: ${Nz(n)}`);
  }
}
async function gQt(e9) {
  let t = e9.remoteWexConfig;
  t?.requireReady && await t.requireReady();
  let n = Cz(t?.Wexsiteurl || t?.wexSiteUrl || "");
  if (!n) throw new Error("\u8FDC\u7A0B\u7B7E\u540D\u5730\u5740\u672A\u521D\u59CB\u5316");
  return `${n}/ciyuancheng/cyc_sign.php`;
}
async function bQt(e9) {
  let t = await t0.get(`https://doh.pub/dns-query?name=${encodeURIComponent(e9)}&type=txt`, { headers: { "User-Agent": "okhttp/5.1.0", Accept: "application/dns-json" }, responseType: "json", timeout: 15e3 }), n = [];
  for (let s of t.data?.Answer || []) {
    if (Number(s?.type) !== 16) continue;
    let c = Ar(s?.data).replace(/["']/g, "");
    for (let l of c.replace(/,/g, " ").split(/\s+/)) /^https?:\/\//i.test(l) && n.push(l);
  }
  return n;
}
async function yQt(e9, t) {
  try {
    let n = await t0.get(Cz(e9), { headers: t, timeout: 8e3, validateStatus: () => true });
    return n.status >= 200 && n.status < 300;
  } catch {
    return false;
  }
}
async function F_(e9, t, n, s) {
  let c = M60(s), l = await AQt(e9, t, n, c), d = new URLSearchParams();
  for (let [v, w] of Object.entries(c)) Ar(w) && d.append(v, Ar(w));
  d.append("timestamp", l.timestamp);
  let m = await t0.get(`${e9.baseUrl}${n}?${d.toString()}`, { headers: { ...e9.baseHeaders, "x-cyc-auth": l.auth }, responseType: "arraybuffer", timeout: 2e4, validateStatus: (v) => v >= 200 && v < 300 }), g = String(m.headers?.["content-type"] || "").toLowerCase(), y = Buffer.from(m.data || []);
  return g.includes("application/protobuf") ? _Qt(y) : U60(y.toString("utf8"));
}
async function AQt(e9, t, n, s) {
  let c = { site: t.signSite, path: n, params: Object.entries(s).map(([y, v]) => [y, Ar(v)]) }, l = await t0.post(e9.signServer, JSON.stringify(c), { headers: { "Content-Type": "application/json; charset=utf-8" }, responseType: "text", transformResponse: [(y) => y], timeout: 15e3 }), d = Ar(l.data).trim();
  if (!d) throw new Error("Cyc sign response is empty");
  let m = Ar($_.decrypt(d)).trim(), g = m.split(":");
  if (g.length < 3 || g[0] !== "v3" || !g[1] || !g.slice(2).join(":")) throw new Error("Cyc sign decode failed");
  return { timestamp: g[1], auth: m };
}
function kQt(e9) {
  let t = [], n = D1e(Ki(e9, ["total", 1, "1"])), s = Ki(e9, ["data", 3, "3"]);
  if (Dd(s)) n || (n = D1e(Ki(s, ["total", 1, "1"]))), t.push(...du(Ki(s, ["list", 2, "2"])));
  else if (Array.isArray(s)) {
    let c = s[0];
    if (Dd(c) && TQt(c, ["vod_id", 1, "1", "name", 2, "2"])) t.push(...s);
    else for (let l of s) Dd(l) && t.push(...du(Ki(l, ["list", 5, "5"])));
  }
  return t.length || t.push(...du(Ki(e9, ["list", 2, "2"]))), { total: n, list: t.map((c) => O1e(c, ["remarks", 8, 5, "8", "5"])).filter(Boolean) };
}
function O1e(e9, t) {
  if (!Dd(e9)) return null;
  let n = Ar(Ki(e9, ["vod_id", 1, "1"])).trim(), s = Ar(Ki(e9, ["name", 2, "2"])).trim();
  return !n || n === "null" || !s ? null : u0({ id: n, name: s, pic: Ar(Ki(e9, ["pic", 3, 4, "3", "4"])), remarks: Ar(Ki(e9, t)) });
}
function vQt(e9) {
  let t = [];
  return Dd(e9) && (Rz(t, e9, "class", "\u7C7B\u578B", [1, "1"]), Rz(t, e9, "area", "\u5730\u533A", [2, "2"]), Rz(t, e9, "lang", "\u8BED\u8A00", [3, "3"]), Rz(t, e9, "year", "\u5E74\u4EFD", [4, "4"])), t.push({ key: "order", name: "\u6392\u5E8F", init: "time", value: [{ n: "\u6700\u65B0", v: "time" }, { n: "\u70ED\u5EA6", v: "hits" }, { n: "\u597D\u8BC4", v: "score" }] }), t;
}
function Rz(e9, t, n, s, c) {
  let l = Ar(Ki(t, [n, ...c])).trim();
  l && e9.push({ key: n, name: s, init: "", value: [{ n: "\u5168\u90E8", v: "" }, ...l.split(",").map((d) => d.trim()).filter(Boolean).map((d) => ({ n: d, v: d }))] });
}
function _Qt(e9) {
  return L60(e9, 0, e9.length);
}
function L60(e9, t, n) {
  let s = /* @__PURE__ */ new Map(), c = t, l = t + n;
  for (; c < l; ) try {
    let m = W_(e9, c), g = m.value;
    if (c = m.pos, c > l || g === 0) break;
    let y = g & 7, v = g >> 3, w;
    if (y === 0) {
      let T = W_(e9, c);
      w = T.value, c = T.pos;
    } else if (y === 1) c += 8;
    else if (y === 2) {
      let T = W_(e9, c), I = T.value;
      c = T.pos, w = wQt(e9.subarray(c, c + I)), c += I;
    } else if (y === 5) c += 4;
    else break;
    if (w !== void 0) {
      let T = String(v);
      s.has(T) || s.set(T, []), s.get(T).push(w);
    }
  } catch {
    break;
  }
  let d = {};
  for (let [m, g] of s) d[m] = g.length === 1 ? g[0] : g;
  return d;
}
function W_(e9, t) {
  let n = 0, s = 0;
  for (; t < e9.length; ) {
    let c = e9[t++];
    if (n += (c & 127) * 2 ** s, s += 7, (c & 128) === 0) break;
  }
  return { value: n, pos: t };
}
function wQt(e9) {
  if (!e9 || !e9.length) return "";
  let t = e9.toString("utf8");
  if (Buffer.from(t, "utf8").equals(e9) && IQt(t)) return t;
  if (SQt(e9)) {
    let n = L60(e9, 0, e9.length);
    if (Object.keys(n).length) return n;
  }
  return e9.toString("hex");
}
function SQt(e9) {
  let t = 0;
  for (; t < e9.length; ) try {
    let n = W_(e9, t), s = n.value;
    if (t = n.pos, t > e9.length || s === 0) return false;
    let c = s & 7;
    if (!(s >> 3)) return false;
    if (c === 0) t = W_(e9, t).pos;
    else if (c === 1) t += 8;
    else if (c === 2) {
      let d = W_(e9, t);
      t = d.pos + d.value;
    } else if (c === 5) t += 4;
    else return false;
  } catch {
    return false;
  }
  return t === e9.length && e9.length > 0;
}
function EQt(e9) {
  return { "User-Agent": `Dalvik/2.1.0 (Linux; U; Android 17; Pixel 10 Build/TQ3A.260701.001); cycdm-android/${e9}`, Accept: "application/json,application/protobuf", "accept-charset": "UTF-8" };
}
function M60(e9) {
  let t = {};
  for (let [n, s] of Object.entries(e9 || {})) t[n] = Ar(s);
  return t;
}
function Ki(e9, t, n = void 0) {
  if (!Dd(e9)) return n;
  for (let s of t) if (Object.prototype.hasOwnProperty.call(e9, s) && e9[s] !== void 0 && e9[s] !== null) return e9[s];
  return n;
}
function TQt(e9, t) {
  return t.some((n) => Object.prototype.hasOwnProperty.call(e9, n));
}
function du(e9) {
  return e9 == null ? [] : Array.isArray(e9) ? e9 : [e9];
}
function U60(e9) {
  if (e9 && typeof e9 == "object") return e9;
  try {
    return JSON.parse(String(e9 || "{}"));
  } catch {
    return {};
  }
}
function Dd(e9) {
  return e9 && typeof e9 == "object" && !Array.isArray(e9);
}
function IQt(e9) {
  return !/[^\x09\x0a\x0d\x20-\x7e\u0080-\uffff]/.test(e9) && e9.length > 0;
}
function Ar(e9, t = "") {
  return e9 == null || e9 === "" ? t : String(e9);
}
function V_(e9, t = 1) {
  let n = Number.parseInt(e9, 10);
  return Number.isFinite(n) && n > 0 ? n : t;
}
function D1e(e9) {
  let t = Number.parseInt(e9, 10);
  return Number.isFinite(t) ? t : 0;
}
function Cz(e9) {
  return String(e9 || "").trim().replace(/\/+$/, "");
}
function Nz(e9) {
  return String(e9?.message || e9 || "unknown").slice(0, 180);
}
var RQt = "http://117.72.112.234:8090/config/tingchina2025.txt";
var $60 = "https://app.365ting.com/listen/Apitzg2025/";
var CQt = "TingShiJie/1.8.8 (m.i275.com)";
var NQt = "listen/1.8.9 (Linux;Android 12) ExoPlayerLib/2.8.4";
function V60(e9 = {}) {
  let t = { siteUrl: $60, remoteWexConfig: e9.remoteWexConfig };
  return { meta: { key: "bookaishijie", name: "\u4E16\u754C|\u542C\u4E66", type: 3 }, async init() {
    t.siteUrl = $60;
    try {
      let n = String(await F60(RQt)).trim();
      n && (t.siteUrl = MQt(n)), console.log(`[BookAiShiJie] siteUrl=${t.siteUrl}`);
    } catch (n) {
      console.warn(`[BookAiShiJie] config failed, use default: ${n.message}`);
    }
    return {};
  }, async home() {
    return P0([{ type_id: "6", type_name: "\u7384\u5E7B\u5947\u5E7B" }, { type_id: "7", type_name: "\u90FD\u5E02\u8A00\u60C5" }, { type_id: "8", type_name: "\u5BAB\u6597\u5973\u9891" }, { type_id: "9", type_name: "\u5B98\u573A\u5546\u6218" }, { type_id: "10", type_name: "\u6B66\u4FA0\u4ED9\u4FA0" }, { type_id: "11", type_name: "\u5211\u4FA6\u63A8\u7406" }, { type_id: "12", type_name: "\u63A2\u9669\u79D1\u5E7B" }, { type_id: "13", type_name: "\u91CD\u751F\u7A7F\u8D8A" }, { type_id: "14", type_name: "\u6050\u6016\u60CA\u609A" }, { type_id: "15", type_name: "\u6587\u5B66\u5386\u53F2" }, { type_id: "49", type_name: "\u4E24\u6027\u60C5\u611F" }], {});
  }, async category(n) {
    let s = n.body || {}, c = s.extend || {}, l = W60(s.page || s.pg || 1), d = Xy(c.cateId || s.id || s.tid), m = await L1e(t, `categoryList?size=10&page=${l}&categoryId=${encodeURIComponent(d)}`), g = DQt(m);
    return Me({ page: l, pagecount: g.length < 10 ? l : l + 1, limit: 10, total: 0, list: g });
  }, async detail(n) {
    let s = Array.isArray(n.body?.id) ? n.body.id : [n.body?.id], c = [];
    for (let l of s.filter(Boolean)) c.push(await OQt(t, String(l)));
    return l0(c);
  }, async play(n) {
    let s = Xy(n.body?.id);
    if (!s) throw new Error("\u542C\u4E16\u754C\u64AD\u653E\u53C2\u6570\u4E3A\u7A7A");
    let c = s.split("|||");
    if (c.length < 2) throw new Error("\u542C\u4E16\u754C\u64AD\u653E\u53C2\u6570\u9519\u8BEF");
    let [l, d] = c, m = String(Date.now()), g = UQt(await PQt(t)), y = String(await F60(`${g}/275tingshu/play.php?time=${m}`)).trim(), v = `${t.siteUrl}AppGetChapterUrl2023?timeStamp=${m}&uid=&chapterId=${encodeURIComponent(l)}&addItParapet=${encodeURIComponent(y)}&bookId=${encodeURIComponent(d)}`, w = await M1e(v), T = Xy(w?.src);
    if (!T) throw new Error("\u542C\u4E16\u754C\u64AD\u653E\u5730\u5740\u4E3A\u7A7A");
    return E0({ parse: 0, url: T, header: LQt(), extra: { danmaku: "", nodanmu: true } });
  }, async search(n) {
    let s = Xy(n.body?.wd || n.body?.key);
    if (!s) return Me({ page: 1, pagecount: 1, list: [] });
    let c = `${t.siteUrl}appSearch?client=babala-android&search=${encodeURIComponent(s)}&app_token=abcSEARCH-2025`, l = await M1e(c), d = Array.isArray(l?.data?.bookData) ? l.data.bookData : [];
    return Me({ page: W60(n.body?.page || n.body?.pg || 1), pagecount: 1, list: d.map(j60).filter((m) => m.vod_id && m.vod_name) });
  } };
}
async function OQt(e9, t) {
  let s = (await L1e(e9, `book?bookId=${encodeURIComponent(t)}`))?.data?.bookData || {}, c = await L1e(e9, `chapter?size=9999&page=1&sort=asc&bookId=${encodeURIComponent(t)}`), d = (Array.isArray(c?.data?.list) ? c.data.list : []).map((m) => {
    let g = Xy(m?.title), y = Xy(m?.chapterId);
    return g && y ? `${g}$${y}|||${t}` : "";
  }).filter(Boolean);
  return b0({ id: t, name: s.bookTitle, pic: s.bookImage, typeName: s.categoryName, content: s.bookDesc, director: s.bookAnchor, actor: s.bookAnchor, vod_play_from: d.length ? BQt(e9) : "", vod_play_url: d.join("#") });
}
async function L1e(e9, t) {
  return M1e(e9.siteUrl + t);
}
async function M1e(e9) {
  return (await t0.get(e9, { headers: G60(), responseType: "json", timeout: 2e4 })).data || {};
}
async function F60(e9) {
  return (await t0.get(e9, { headers: G60(), responseType: "text", transformResponse: [(n) => n], timeout: 15e3 })).data || "";
}
function DQt(e9) {
  return (Array.isArray(e9?.data?.list) ? e9.data.list : []).map(j60).filter((n) => n.vod_id && n.vod_name);
}
function j60(e9) {
  return u0({ id: e9?.id, name: e9?.bookTitle, pic: e9?.bookImage, remarks: e9?.bookAnchor });
}
async function PQt(e9) {
  let t = e9.remoteWexConfig;
  t?.requireReady && await t.requireReady();
  let n = t?.Wexsiteurl || t?.wexSiteUrl || "";
  if (!n) throw new Error("\u8FDC\u7A0B\u914D\u7F6E\u672A\u521D\u59CB\u5316");
  return n;
}
function BQt(e9) {
  return Xy(e9.remoteWexConfig?.Wexconfig?.vodfrom) || "\u64AD\u653E";
}
function G60() {
  return { "User-Agent": CQt };
}
function LQt() {
  return { "User-Agent": NQt };
}
function MQt(e9) {
  return String(e9 || "").trim().replace(/\/+$/, "") + "/";
}
function UQt(e9) {
  return String(e9 || "").trim().replace(/\/+$/, "");
}
function Xy(e9, t = "") {
  return e9 == null || e9 === "" ? t : String(e9);
}
function W60(e9, t = 1) {
  let n = Number.parseInt(e9, 10);
  return Number.isFinite(n) && n > 0 ? n : t;
}
var J60 = C0(referenceBuiltin1, 1);
var X60 = referenceBuiltin10;
var Lz = C0(referenceBuiltin0, 1);
function Ra(e9, t = new Uint8Array(4), n = 0) {
  return t[n + 0] = e9 >>> 0, t[n + 1] = e9 >>> 8, t[n + 2] = e9 >>> 16, t[n + 3] = e9 >>> 24, t;
}
function U1e(e9, t = new Uint8Array(8), n = 0) {
  return Ra(e9 >>> 0, t, n), Ra(e9 / 4294967296 >>> 0, t, n + 4), t;
}
function Ko(e9) {
  for (let t = 0; t < e9.length; t++) e9[t] = 0;
  return e9;
}
var FQt = 20;
function WQt(e9, t, n) {
  let s = 1634760805, c = 857760878, l = 2036477234, d = 1797285236, m = n[3] << 24 | n[2] << 16 | n[1] << 8 | n[0], g = n[7] << 24 | n[6] << 16 | n[5] << 8 | n[4], y = n[11] << 24 | n[10] << 16 | n[9] << 8 | n[8], v = n[15] << 24 | n[14] << 16 | n[13] << 8 | n[12], w = n[19] << 24 | n[18] << 16 | n[17] << 8 | n[16], T = n[23] << 24 | n[22] << 16 | n[21] << 8 | n[20], I = n[27] << 24 | n[26] << 16 | n[25] << 8 | n[24], N = n[31] << 24 | n[30] << 16 | n[29] << 8 | n[28], C = t[3] << 24 | t[2] << 16 | t[1] << 8 | t[0], B = t[7] << 24 | t[6] << 16 | t[5] << 8 | t[4], L = t[11] << 24 | t[10] << 16 | t[9] << 8 | t[8], q = t[15] << 24 | t[14] << 16 | t[13] << 8 | t[12], W = s, F = c, J = l, ee = d, ne = m, re = g, ae = y, se = v, he = w, be = T, ke = I, Se = N, Je = C, Ye = B, Ue = L, o0 = q;
  for (let f0 = 0; f0 < FQt; f0 += 2) W = W + ne | 0, Je ^= W, Je = Je >>> 16 | Je << 16, he = he + Je | 0, ne ^= he, ne = ne >>> 20 | ne << 12, F = F + re | 0, Ye ^= F, Ye = Ye >>> 16 | Ye << 16, be = be + Ye | 0, re ^= be, re = re >>> 20 | re << 12, J = J + ae | 0, Ue ^= J, Ue = Ue >>> 16 | Ue << 16, ke = ke + Ue | 0, ae ^= ke, ae = ae >>> 20 | ae << 12, ee = ee + se | 0, o0 ^= ee, o0 = o0 >>> 16 | o0 << 16, Se = Se + o0 | 0, se ^= Se, se = se >>> 20 | se << 12, J = J + ae | 0, Ue ^= J, Ue = Ue >>> 24 | Ue << 8, ke = ke + Ue | 0, ae ^= ke, ae = ae >>> 25 | ae << 7, ee = ee + se | 0, o0 ^= ee, o0 = o0 >>> 24 | o0 << 8, Se = Se + o0 | 0, se ^= Se, se = se >>> 25 | se << 7, F = F + re | 0, Ye ^= F, Ye = Ye >>> 24 | Ye << 8, be = be + Ye | 0, re ^= be, re = re >>> 25 | re << 7, W = W + ne | 0, Je ^= W, Je = Je >>> 24 | Je << 8, he = he + Je | 0, ne ^= he, ne = ne >>> 25 | ne << 7, W = W + re | 0, o0 ^= W, o0 = o0 >>> 16 | o0 << 16, ke = ke + o0 | 0, re ^= ke, re = re >>> 20 | re << 12, F = F + ae | 0, Je ^= F, Je = Je >>> 16 | Je << 16, Se = Se + Je | 0, ae ^= Se, ae = ae >>> 20 | ae << 12, J = J + se | 0, Ye ^= J, Ye = Ye >>> 16 | Ye << 16, he = he + Ye | 0, se ^= he, se = se >>> 20 | se << 12, ee = ee + ne | 0, Ue ^= ee, Ue = Ue >>> 16 | Ue << 16, be = be + Ue | 0, ne ^= be, ne = ne >>> 20 | ne << 12, J = J + se | 0, Ye ^= J, Ye = Ye >>> 24 | Ye << 8, he = he + Ye | 0, se ^= he, se = se >>> 25 | se << 7, ee = ee + ne | 0, Ue ^= ee, Ue = Ue >>> 24 | Ue << 8, be = be + Ue | 0, ne ^= be, ne = ne >>> 25 | ne << 7, F = F + ae | 0, Je ^= F, Je = Je >>> 24 | Je << 8, Se = Se + Je | 0, ae ^= Se, ae = ae >>> 25 | ae << 7, W = W + re | 0, o0 ^= W, o0 = o0 >>> 24 | o0 << 8, ke = ke + o0 | 0, re ^= ke, re = re >>> 25 | re << 7;
  Ra(W + s | 0, e9, 0), Ra(F + c | 0, e9, 4), Ra(J + l | 0, e9, 8), Ra(ee + d | 0, e9, 12), Ra(ne + m | 0, e9, 16), Ra(re + g | 0, e9, 20), Ra(ae + y | 0, e9, 24), Ra(se + v | 0, e9, 28), Ra(he + w | 0, e9, 32), Ra(be + T | 0, e9, 36), Ra(ke + I | 0, e9, 40), Ra(Se + N | 0, e9, 44), Ra(Je + C | 0, e9, 48), Ra(Ye + B | 0, e9, 52), Ra(Ue + L | 0, e9, 56), Ra(o0 + q | 0, e9, 60);
}
function $N(e9, t, n, s, c = 0) {
  if (e9.length !== 32) throw new Error("ChaCha: key size must be 32 bytes");
  if (s.length < n.length) throw new Error("ChaCha: destination is shorter than source");
  let l, d;
  if (c === 0) {
    if (t.length !== 8 && t.length !== 12) throw new Error("ChaCha nonce must be 8 or 12 bytes");
    l = new Uint8Array(16), d = l.length - t.length, l.set(t, d);
  } else {
    if (t.length !== 16) throw new Error("ChaCha nonce with counter must be 16 bytes");
    l = t, d = c;
  }
  let m = new Uint8Array(64);
  for (let g = 0; g < n.length; g += 64) {
    WQt(m, l, e9);
    for (let y = g; y < g + 64 && y < n.length; y++) s[y] = n[y] ^ m[y - g];
    VQt(l, 0, d);
  }
  return Ko(m), c === 0 && Ko(l), s;
}
function $1e(e9, t, n, s = 0) {
  return Ko(n), $N(e9, t, n, n, s);
}
function VQt(e9, t, n) {
  let s = 1;
  for (; n--; ) s = s + (e9[t] & 255) | 0, e9[t] = s & 255, s >>>= 8, t++;
  if (s > 0) throw new Error("ChaCha: counter overflow");
}
var jQt = 20;
function F1e(e9, t, n) {
  let s = 1634760805, c = 857760878, l = 2036477234, d = 1797285236, m = e9[3] << 24 | e9[2] << 16 | e9[1] << 8 | e9[0], g = e9[7] << 24 | e9[6] << 16 | e9[5] << 8 | e9[4], y = e9[11] << 24 | e9[10] << 16 | e9[9] << 8 | e9[8], v = e9[15] << 24 | e9[14] << 16 | e9[13] << 8 | e9[12], w = e9[19] << 24 | e9[18] << 16 | e9[17] << 8 | e9[16], T = e9[23] << 24 | e9[22] << 16 | e9[21] << 8 | e9[20], I = e9[27] << 24 | e9[26] << 16 | e9[25] << 8 | e9[24], N = e9[31] << 24 | e9[30] << 16 | e9[29] << 8 | e9[28], C = t[3] << 24 | t[2] << 16 | t[1] << 8 | t[0], B = t[7] << 24 | t[6] << 16 | t[5] << 8 | t[4], L = t[11] << 24 | t[10] << 16 | t[9] << 8 | t[8], q = t[15] << 24 | t[14] << 16 | t[13] << 8 | t[12], W = s, F = c, J = l, ee = d, ne = m, re = g, ae = y, se = v, he = w, be = T, ke = I, Se = N, Je = C, Ye = B, Ue = L, o0 = q;
  for (let f0 = 0; f0 < jQt; f0 += 2) W = W + ne | 0, Je ^= W, Je = Je >>> 16 | Je << 16, he = he + Je | 0, ne ^= he, ne = ne >>> 20 | ne << 12, F = F + re | 0, Ye ^= F, Ye = Ye >>> 16 | Ye << 16, be = be + Ye | 0, re ^= be, re = re >>> 20 | re << 12, J = J + ae | 0, Ue ^= J, Ue = Ue >>> 16 | Ue << 16, ke = ke + Ue | 0, ae ^= ke, ae = ae >>> 20 | ae << 12, ee = ee + se | 0, o0 ^= ee, o0 = o0 >>> 16 | o0 << 16, Se = Se + o0 | 0, se ^= Se, se = se >>> 20 | se << 12, J = J + ae | 0, Ue ^= J, Ue = Ue >>> 24 | Ue << 8, ke = ke + Ue | 0, ae ^= ke, ae = ae >>> 25 | ae << 7, ee = ee + se | 0, o0 ^= ee, o0 = o0 >>> 24 | o0 << 8, Se = Se + o0 | 0, se ^= Se, se = se >>> 25 | se << 7, F = F + re | 0, Ye ^= F, Ye = Ye >>> 24 | Ye << 8, be = be + Ye | 0, re ^= be, re = re >>> 25 | re << 7, W = W + ne | 0, Je ^= W, Je = Je >>> 24 | Je << 8, he = he + Je | 0, ne ^= he, ne = ne >>> 25 | ne << 7, W = W + re | 0, o0 ^= W, o0 = o0 >>> 16 | o0 << 16, ke = ke + o0 | 0, re ^= ke, re = re >>> 20 | re << 12, F = F + ae | 0, Je ^= F, Je = Je >>> 16 | Je << 16, Se = Se + Je | 0, ae ^= Se, ae = ae >>> 20 | ae << 12, J = J + se | 0, Ye ^= J, Ye = Ye >>> 16 | Ye << 16, he = he + Ye | 0, se ^= he, se = se >>> 20 | se << 12, ee = ee + ne | 0, Ue ^= ee, Ue = Ue >>> 16 | Ue << 16, be = be + Ue | 0, ne ^= be, ne = ne >>> 20 | ne << 12, J = J + se | 0, Ye ^= J, Ye = Ye >>> 24 | Ye << 8, he = he + Ye | 0, se ^= he, se = se >>> 25 | se << 7, ee = ee + ne | 0, Ue ^= ee, Ue = Ue >>> 24 | Ue << 8, be = be + Ue | 0, ne ^= be, ne = ne >>> 25 | ne << 7, F = F + ae | 0, Je ^= F, Je = Je >>> 24 | Je << 8, Se = Se + Je | 0, ae ^= Se, ae = ae >>> 25 | ae << 7, W = W + re | 0, o0 ^= W, o0 = o0 >>> 24 | o0 << 8, ke = ke + o0 | 0, re ^= ke, re = re >>> 25 | re << 7;
  return Ra(W, n, 0), Ra(F, n, 4), Ra(J, n, 8), Ra(ee, n, 12), Ra(Je, n, 16), Ra(Ye, n, 20), Ra(Ue, n, 24), Ra(o0, n, 28), n;
}
function GQt(e9, t) {
  if (e9.length !== t.length) return 0;
  let n = 0;
  for (let s = 0; s < e9.length; s++) n |= e9[s] ^ t[s];
  return 1 & n - 1 >>> 8;
}
function W1e(e9, t) {
  return e9.length === 0 || t.length === 0 ? false : GQt(e9, t) !== 0;
}
var HQt = 16;
var Oz = class {
  digestLength = HQt;
  _buffer = new Uint8Array(16);
  _r = new Uint16Array(10);
  _h = new Uint16Array(10);
  _pad = new Uint16Array(8);
  _leftover = 0;
  _fin = 0;
  _finished = false;
  constructor(t) {
    let n = t[0] | t[1] << 8;
    this._r[0] = n & 8191;
    let s = t[2] | t[3] << 8;
    this._r[1] = (n >>> 13 | s << 3) & 8191;
    let c = t[4] | t[5] << 8;
    this._r[2] = (s >>> 10 | c << 6) & 7939;
    let l = t[6] | t[7] << 8;
    this._r[3] = (c >>> 7 | l << 9) & 8191;
    let d = t[8] | t[9] << 8;
    this._r[4] = (l >>> 4 | d << 12) & 255, this._r[5] = d >>> 1 & 8190;
    let m = t[10] | t[11] << 8;
    this._r[6] = (d >>> 14 | m << 2) & 8191;
    let g = t[12] | t[13] << 8;
    this._r[7] = (m >>> 11 | g << 5) & 8065;
    let y = t[14] | t[15] << 8;
    this._r[8] = (g >>> 8 | y << 8) & 8191, this._r[9] = y >>> 5 & 127, this._pad[0] = t[16] | t[17] << 8, this._pad[1] = t[18] | t[19] << 8, this._pad[2] = t[20] | t[21] << 8, this._pad[3] = t[22] | t[23] << 8, this._pad[4] = t[24] | t[25] << 8, this._pad[5] = t[26] | t[27] << 8, this._pad[6] = t[28] | t[29] << 8, this._pad[7] = t[30] | t[31] << 8;
  }
  _blocks(t, n, s) {
    let c = this._fin ? 0 : 2048, l = this._h[0], d = this._h[1], m = this._h[2], g = this._h[3], y = this._h[4], v = this._h[5], w = this._h[6], T = this._h[7], I = this._h[8], N = this._h[9], C = this._r[0], B = this._r[1], L = this._r[2], q = this._r[3], W = this._r[4], F = this._r[5], J = this._r[6], ee = this._r[7], ne = this._r[8], re = this._r[9];
    for (; s >= 16; ) {
      let ae = t[n + 0] | t[n + 1] << 8;
      l += ae & 8191;
      let se = t[n + 2] | t[n + 3] << 8;
      d += (ae >>> 13 | se << 3) & 8191;
      let he = t[n + 4] | t[n + 5] << 8;
      m += (se >>> 10 | he << 6) & 8191;
      let be = t[n + 6] | t[n + 7] << 8;
      g += (he >>> 7 | be << 9) & 8191;
      let ke = t[n + 8] | t[n + 9] << 8;
      y += (be >>> 4 | ke << 12) & 8191, v += ke >>> 1 & 8191;
      let Se = t[n + 10] | t[n + 11] << 8;
      w += (ke >>> 14 | Se << 2) & 8191;
      let Je = t[n + 12] | t[n + 13] << 8;
      T += (Se >>> 11 | Je << 5) & 8191;
      let Ye = t[n + 14] | t[n + 15] << 8;
      I += (Je >>> 8 | Ye << 8) & 8191, N += Ye >>> 5 | c;
      let Ue = 0, o0 = Ue;
      o0 += l * C, o0 += d * (5 * re), o0 += m * (5 * ne), o0 += g * (5 * ee), o0 += y * (5 * J), Ue = o0 >>> 13, o0 &= 8191, o0 += v * (5 * F), o0 += w * (5 * W), o0 += T * (5 * q), o0 += I * (5 * L), o0 += N * (5 * B), Ue += o0 >>> 13, o0 &= 8191;
      let f0 = Ue;
      f0 += l * B, f0 += d * C, f0 += m * (5 * re), f0 += g * (5 * ne), f0 += y * (5 * ee), Ue = f0 >>> 13, f0 &= 8191, f0 += v * (5 * J), f0 += w * (5 * F), f0 += T * (5 * W), f0 += I * (5 * q), f0 += N * (5 * L), Ue += f0 >>> 13, f0 &= 8191;
      let O0 = Ue;
      O0 += l * L, O0 += d * B, O0 += m * C, O0 += g * (5 * re), O0 += y * (5 * ne), Ue = O0 >>> 13, O0 &= 8191, O0 += v * (5 * ee), O0 += w * (5 * J), O0 += T * (5 * F), O0 += I * (5 * W), O0 += N * (5 * q), Ue += O0 >>> 13, O0 &= 8191;
      let tt = Ue;
      tt += l * q, tt += d * L, tt += m * B, tt += g * C, tt += y * (5 * re), Ue = tt >>> 13, tt &= 8191, tt += v * (5 * ne), tt += w * (5 * ee), tt += T * (5 * J), tt += I * (5 * F), tt += N * (5 * W), Ue += tt >>> 13, tt &= 8191;
      let ct = Ue;
      ct += l * W, ct += d * q, ct += m * L, ct += g * B, ct += y * C, Ue = ct >>> 13, ct &= 8191, ct += v * (5 * re), ct += w * (5 * ne), ct += T * (5 * ee), ct += I * (5 * J), ct += N * (5 * F), Ue += ct >>> 13, ct &= 8191;
      let h0 = Ue;
      h0 += l * F, h0 += d * W, h0 += m * q, h0 += g * L, h0 += y * B, Ue = h0 >>> 13, h0 &= 8191, h0 += v * C, h0 += w * (5 * re), h0 += T * (5 * ne), h0 += I * (5 * ee), h0 += N * (5 * J), Ue += h0 >>> 13, h0 &= 8191;
      let Lt = Ue;
      Lt += l * J, Lt += d * F, Lt += m * W, Lt += g * q, Lt += y * L, Ue = Lt >>> 13, Lt &= 8191, Lt += v * B, Lt += w * C, Lt += T * (5 * re), Lt += I * (5 * ne), Lt += N * (5 * ee), Ue += Lt >>> 13, Lt &= 8191;
      let mt = Ue;
      mt += l * ee, mt += d * J, mt += m * F, mt += g * W, mt += y * q, Ue = mt >>> 13, mt &= 8191, mt += v * L, mt += w * B, mt += T * C, mt += I * (5 * re), mt += N * (5 * ne), Ue += mt >>> 13, mt &= 8191;
      let wt = Ue;
      wt += l * ne, wt += d * ee, wt += m * J, wt += g * F, wt += y * W, Ue = wt >>> 13, wt &= 8191, wt += v * q, wt += w * L, wt += T * B, wt += I * C, wt += N * (5 * re), Ue += wt >>> 13, wt &= 8191;
      let at = Ue;
      at += l * re, at += d * ne, at += m * ee, at += g * J, at += y * F, Ue = at >>> 13, at &= 8191, at += v * W, at += w * q, at += T * L, at += I * B, at += N * C, Ue += at >>> 13, at &= 8191, Ue = (Ue << 2) + Ue | 0, Ue = Ue + o0 | 0, o0 = Ue & 8191, Ue = Ue >>> 13, f0 += Ue, l = o0, d = f0, m = O0, g = tt, y = ct, v = h0, w = Lt, T = mt, I = wt, N = at, n += 16, s -= 16;
    }
    this._h[0] = l, this._h[1] = d, this._h[2] = m, this._h[3] = g, this._h[4] = y, this._h[5] = v, this._h[6] = w, this._h[7] = T, this._h[8] = I, this._h[9] = N;
  }
  finish(t, n = 0) {
    let s = new Uint16Array(10), c, l, d, m;
    if (this._leftover) {
      for (m = this._leftover, this._buffer[m++] = 1; m < 16; m++) this._buffer[m] = 0;
      this._fin = 1, this._blocks(this._buffer, 0, 16);
    }
    for (c = this._h[1] >>> 13, this._h[1] &= 8191, m = 2; m < 10; m++) this._h[m] += c, c = this._h[m] >>> 13, this._h[m] &= 8191;
    for (this._h[0] += c * 5, c = this._h[0] >>> 13, this._h[0] &= 8191, this._h[1] += c, c = this._h[1] >>> 13, this._h[1] &= 8191, this._h[2] += c, s[0] = this._h[0] + 5, c = s[0] >>> 13, s[0] &= 8191, m = 1; m < 10; m++) s[m] = this._h[m] + c, c = s[m] >>> 13, s[m] &= 8191;
    for (s[9] -= 8192, l = (c ^ 1) - 1, m = 0; m < 10; m++) s[m] &= l;
    for (l = ~l, m = 0; m < 10; m++) this._h[m] = this._h[m] & l | s[m];
    for (this._h[0] = (this._h[0] | this._h[1] << 13) & 65535, this._h[1] = (this._h[1] >>> 3 | this._h[2] << 10) & 65535, this._h[2] = (this._h[2] >>> 6 | this._h[3] << 7) & 65535, this._h[3] = (this._h[3] >>> 9 | this._h[4] << 4) & 65535, this._h[4] = (this._h[4] >>> 12 | this._h[5] << 1 | this._h[6] << 14) & 65535, this._h[5] = (this._h[6] >>> 2 | this._h[7] << 11) & 65535, this._h[6] = (this._h[7] >>> 5 | this._h[8] << 8) & 65535, this._h[7] = (this._h[8] >>> 8 | this._h[9] << 5) & 65535, d = this._h[0] + this._pad[0], this._h[0] = d & 65535, m = 1; m < 8; m++) d = (this._h[m] + this._pad[m] | 0) + (d >>> 16) | 0, this._h[m] = d & 65535;
    return t[n + 0] = this._h[0] >>> 0, t[n + 1] = this._h[0] >>> 8, t[n + 2] = this._h[1] >>> 0, t[n + 3] = this._h[1] >>> 8, t[n + 4] = this._h[2] >>> 0, t[n + 5] = this._h[2] >>> 8, t[n + 6] = this._h[3] >>> 0, t[n + 7] = this._h[3] >>> 8, t[n + 8] = this._h[4] >>> 0, t[n + 9] = this._h[4] >>> 8, t[n + 10] = this._h[5] >>> 0, t[n + 11] = this._h[5] >>> 8, t[n + 12] = this._h[6] >>> 0, t[n + 13] = this._h[6] >>> 8, t[n + 14] = this._h[7] >>> 0, t[n + 15] = this._h[7] >>> 8, this._finished = true, this;
  }
  update(t) {
    let n = 0, s = t.length, c;
    if (this._leftover) {
      c = 16 - this._leftover, c > s && (c = s);
      for (let l = 0; l < c; l++) this._buffer[this._leftover + l] = t[n + l];
      if (s -= c, n += c, this._leftover += c, this._leftover < 16) return this;
      this._blocks(this._buffer, 0, 16), this._leftover = 0;
    }
    if (s >= 16 && (c = s - s % 16, this._blocks(t, n, c), n += c, s -= c), s) {
      for (let l = 0; l < s; l++) this._buffer[this._leftover + l] = t[n + l];
      this._leftover += s;
    }
    return this;
  }
  digest() {
    if (this._finished) throw new Error("Poly1305 was finished");
    let t = new Uint8Array(16);
    return this.finish(t), t;
  }
  clean() {
    return Ko(this._buffer), Ko(this._r), Ko(this._h), Ko(this._pad), this._leftover = 0, this._fin = 0, this._finished = true, this;
  }
};
var qQt = 32;
var zQt = 12;
var YQt = 16;
var H60 = new Uint8Array(16);
var FN = class {
  nonceLength = zQt;
  tagLength = YQt;
  _key;
  constructor(t) {
    if (t.length !== qQt) throw new Error("ChaCha20Poly1305 needs 32-byte key");
    this._key = new Uint8Array(t);
  }
  seal(t, n, s, c) {
    if (t.length > 16) throw new Error("ChaCha20Poly1305: incorrect nonce length");
    let l = new Uint8Array(16);
    l.set(t, l.length - t.length);
    let d = new Uint8Array(32);
    $1e(this._key, l, d, 4);
    let m = n.length + this.tagLength, g;
    if (c) {
      if (c.length !== m) throw new Error("ChaCha20Poly1305: incorrect destination length");
      g = c;
    } else g = new Uint8Array(m);
    return $N(this._key, l, n, g, 4), this._authenticate(g.subarray(g.length - this.tagLength, g.length), d, g.subarray(0, g.length - this.tagLength), s), Ko(l), g;
  }
  open(t, n, s, c) {
    if (t.length > 16) throw new Error("ChaCha20Poly1305: incorrect nonce length");
    if (n.length < this.tagLength) return null;
    let l = new Uint8Array(16);
    l.set(t, l.length - t.length);
    let d = new Uint8Array(32);
    $1e(this._key, l, d, 4);
    let m = new Uint8Array(this.tagLength);
    if (this._authenticate(m, d, n.subarray(0, n.length - this.tagLength), s), !W1e(m, n.subarray(n.length - this.tagLength, n.length))) return null;
    let g = n.length - this.tagLength, y;
    if (c) {
      if (c.length !== g) throw new Error("ChaCha20Poly1305: incorrect destination length");
      y = c;
    } else y = new Uint8Array(g);
    return $N(this._key, l, n.subarray(0, n.length - this.tagLength), y, 4), Ko(l), y;
  }
  clean() {
    return Ko(this._key), this;
  }
  _authenticate(t, n, s, c) {
    let l = new Oz(n);
    c && (l.update(c), c.length % 16 > 0 && l.update(H60.subarray(c.length % 16))), l.update(s), s.length % 16 > 0 && l.update(H60.subarray(s.length % 16));
    let d = new Uint8Array(8);
    c && U1e(c.length, d), l.update(d), U1e(s.length, d), l.update(d);
    let m = l.digest();
    for (let g = 0; g < m.length; g++) t[g] = m[g];
    l.clean(), Ko(m), Ko(d);
  }
};
var QQt = 32;
var ZQt = 24;
var KQt = 16;
var Dz = class {
  nonceLength = ZQt;
  tagLength = KQt;
  _key;
  constructor(t) {
    if (t.length !== QQt) throw new Error("ChaCha20Poly1305 needs 32-byte key");
    this._key = new Uint8Array(t);
  }
  seal(t, n, s, c) {
    if (t.length !== 24) throw new Error("XChaCha20Poly1305: incorrect nonce length");
    let l = F1e(this._key, t.subarray(0, 16), new Uint8Array(32)), d = new Uint8Array(12);
    d.set(t.subarray(16), 4);
    let m = new FN(l), g = m.seal(d, n, s, c);
    return Ko(l), Ko(d), m.clean(), g;
  }
  open(t, n, s, c) {
    if (t.length !== 24) throw new Error("XChaCha20Poly1305: incorrect nonce length");
    if (n.length < this.tagLength) return null;
    let l = F1e(this._key, t.subarray(0, 16), new Uint8Array(32)), d = new Uint8Array(12);
    d.set(t.subarray(16), 4);
    let m = new FN(l), g = m.open(d, n, s, c);
    return Ko(l), Ko(d), m.clean(), g;
  }
  clean() {
    return Ko(this._key), this;
  }
};
var JQt = "ea9d9d4f9a983fe6f6382f29c7b46b8d6dc47abc6da36662e6ddff8c78902f65";
var q60 = Buffer.from(JQt, "hex");
var XQt = 41;
var Pz = [214, 144, 233, 254, 204, 225, 61, 183, 22, 182, 20, 194, 40, 251, 44, 5, 43, 103, 154, 118, 42, 190, 4, 195, 170, 68, 19, 38, 73, 134, 6, 153, 156, 66, 80, 244, 145, 239, 152, 122, 51, 84, 11, 67, 237, 207, 172, 98, 228, 179, 28, 169, 201, 8, 232, 149, 128, 223, 148, 250, 117, 143, 63, 166, 71, 7, 167, 252, 243, 115, 23, 186, 131, 89, 60, 25, 230, 133, 79, 168, 104, 107, 129, 178, 113, 100, 218, 139, 248, 235, 15, 75, 112, 86, 157, 53, 30, 36, 14, 94, 99, 88, 209, 162, 37, 34, 124, 59, 1, 33, 120, 135, 212, 0, 70, 87, 159, 211, 39, 82, 76, 54, 2, 231, 160, 196, 200, 158, 234, 191, 138, 210, 64, 199, 56, 181, 163, 247, 242, 206, 249, 97, 21, 161, 224, 174, 93, 164, 155, 52, 26, 85, 173, 147, 50, 48, 245, 140, 177, 227, 29, 246, 226, 46, 130, 102, 202, 96, 192, 41, 35, 171, 13, 83, 78, 111, 213, 219, 55, 69, 222, 253, 142, 47, 3, 255, 106, 114, 109, 108, 91, 81, 141, 27, 175, 146, 187, 221, 188, 127, 17, 217, 92, 65, 31, 16, 90, 216, 10, 193, 49, 136, 165, 205, 123, 189, 45, 116, 208, 18, 184, 229, 180, 176, 137, 105, 151, 74, 12, 150, 119, 126, 101, 185, 241, 9, 197, 110, 198, 132, 24, 240, 125, 236, 58, 220, 77, 32, 121, 238, 95, 62, 215, 203, 57, 72];
var eZt = [2746333894, 1453994832, 1736282519, 2993693404];
var tZt = [462357, 472066609, 943670861, 1415275113, 1886879365, 2358483617, 2830087869, 3301692121, 3773296373, 4228057617, 404694573, 876298825, 1347903077, 1819507329, 2291111581, 2762715833, 3234320085, 3705924337, 4177462797, 337322537, 808926789, 1280531041, 1752135293, 2223739545, 2695343797, 3166948049, 3638552301, 4110090761, 269950501, 741554753, 1213159005, 1684763257];
function z60(e9) {
  let t = xZt(e9);
  if (t.length < XQt) throw new Error("\u60A6\u542C\u5BC6\u6587\u957F\u5EA6\u4E0D\u8DB3");
  let n = t[0] & 255, s = t.subarray(1, 25), c = Buffer.from(t.subarray(25));
  n === 2 && (c = Buffer.from(c).reverse());
  let d = new Dz(q60).open(s, c, new Uint8Array(0));
  if (!d) throw new Error("\u60A6\u542C XChaCha20-Poly1305 \u6821\u9A8C\u5931\u8D25");
  return Buffer.from(d).toString("utf8");
}
function V1e(e9) {
  let t = Lz.default.randomBytes(12), n = Lz.default.createCipheriv("aes-256-gcm", q60, t, { authTagLength: 16 }), s = Buffer.concat([n.update(String(e9), "utf8"), n.final()]);
  return Buffer.concat([Buffer.from([1]), t, s, n.getAuthTag()]).toString("hex");
}
function Y60(e9) {
  let t = cZt(), s = Lz.default.createHash("sha256").update(`fa317cd29b|${t}`, "utf8").digest().subarray(0, 16), c = `1a60ec86|212b95ee|4ec312a9||${e9}|Asia/Shanghai`, l = rZt(Buffer.from(c, "utf8"), s).toString("base64");
  return `f-${Number.parseInt(t, 10).toString(36)}:f-${l}`;
}
function j1e() {
  let e9 = process.hrtime.bigint(), t = 130 + Number(e9 % 5n), n = Number(e9 % 2000n), s = Number(e9 % 100n);
  return `Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/${t}.0.${n}.${s} Safari/537.36`;
}
function rZt(e9, t) {
  let n = nZt(t), s = sZt(e9, 16), c = Buffer.alloc(s.length);
  for (let l = 0; l < s.length; l += 16) iZt(s, l, c, l, n);
  return c;
}
function nZt(e9) {
  let t = Array(36).fill(0);
  for (let s = 0; s < 4; s++) t[s] = Z60(e9, s * 4) ^ eZt[s] | 0;
  let n = [];
  for (let s = 0; s < 32; s++) t[s + 4] = t[s] ^ oZt(t[s + 1] ^ t[s + 2] ^ t[s + 3] ^ tZt[s] | 0) | 0, n[s] = t[s + 4];
  return n;
}
function iZt(e9, t, n, s, c) {
  let l = Array(36).fill(0);
  for (let d = 0; d < 4; d++) l[d] = Z60(e9, t + d * 4);
  for (let d = 0; d < 32; d++) l[d + 4] = l[d] ^ aZt(l[d + 1] ^ l[d + 2] ^ l[d + 3] ^ c[d] | 0) | 0;
  Bz(n, s, l[35]), Bz(n, s + 4, l[34]), Bz(n, s + 8, l[33]), Bz(n, s + 12, l[32]);
}
function aZt(e9) {
  let t = Q60(e9);
  return t ^ j_(t, 2) ^ j_(t, 10) ^ j_(t, 18) ^ j_(t, 24) | 0;
}
function oZt(e9) {
  let t = Q60(e9);
  return t ^ j_(t, 13) ^ j_(t, 23) | 0;
}
function Q60(e9) {
  return Pz[e9 >>> 24 & 255] << 24 | Pz[e9 >>> 16 & 255] << 16 | Pz[e9 >>> 8 & 255] << 8 | Pz[e9 & 255] | 0;
}
function sZt(e9, t) {
  let n = t - (e9.length % t || t) || t;
  return Buffer.concat([e9, Buffer.alloc(n, n)]);
}
function Z60(e9, t) {
  return e9[t] << 24 | e9[t + 1] << 16 | e9[t + 2] << 8 | e9[t + 3] | 0;
}
function Bz(e9, t, n) {
  e9[t] = n >>> 24 & 255, e9[t + 1] = n >>> 16 & 255, e9[t + 2] = n >>> 8 & 255, e9[t + 3] = n & 255;
}
function j_(e9, t) {
  return e9 << t | e9 >>> 32 - t | 0;
}
function xZt(e9) {
  let t = String(e9 || "").trim().replace(/\s/g, "");
  if ((t.length & 1) !== 0) throw new Error("hex length");
  return Buffer.from(t, "hex");
}
function cZt() {
  let e9 = /* @__PURE__ */ new Date(), t = new Intl.DateTimeFormat("en-CA", { timeZone: "Asia/Shanghai", year: "numeric", month: "2-digit", day: "2-digit" }).formatToParts(e9), n = Object.fromEntries(t.map((s) => [s.type, s.value]));
  return `${n.year}${n.month}${n.day}`;
}
var Mz = "https://json.tingyou8.vip/azybk/json_v1";
var G1e = "https://tingyou.fm/api";
var uZt = "zybk/1.0.6";
function e10(e9 = {}) {
  let t = { remoteWexConfig: e9.remoteWexConfig, userAgent: j1e() };
  return { meta: { key: "bookaiyueting", name: "\u60A6\u542C|\u542C\u4E66", type: 3 }, async init() {
    return t.userAgent = j1e(), {};
  }, async home() {
    return P0([{ type_id: "2", type_name: "\u5C0F\u8BF4" }, { type_id: "1", type_name: "\u8BC4\u4E66" }], pZt());
  }, async category(n) {
    let s = n.body || {}, c = s.extend || s.filters || {}, l = q1e(s.page || s.pg || 1), d = Jm(c.class), m = Jm(c.cateId || s.id || s.tid), g = d ? `${Mz}/types/${encodeURIComponent(d)}/comprehensive/p${l}` : `${Mz}/categories/${encodeURIComponent(m)}/comprehensive/p${l}`, y = await z1e(g), v = K60(y?.data);
    return Me({ page: l, pagecount: v.length < 20 ? l : l + 1, limit: 20, total: 0, list: v });
  }, async detail(n) {
    let s = Array.isArray(n.body?.id) ? n.body.id : [n.body?.id], c = [];
    for (let l of s.filter(Boolean)) c.push(await lZt(t, String(l)));
    return l0(c);
  }, async play(n) {
    let s = Jm(n.body?.id);
    if (!s) throw new Error("\u60A6\u542C\u64AD\u653E\u53C2\u6570\u4E3A\u7A7A");
    let c = s.split("|||");
    if (c.length < 2) throw new Error("\u60A6\u542C\u64AD\u653E\u53C2\u6570\u9519\u8BEF");
    let l = Jm(c[0]), d = q1e(c[1], 0), m = Y60(t.userAgent).replace(/\n/g, "");
    await fZt(`${G1e}/me`, "", H1e(t.userAgent, m));
    let g = V1e(JSON.stringify({ album_id: mZt(l), chapter_idx: d })), y = await Q1e(`${G1e}/play_token`, g, H1e(t.userAgent, m)), v = Y1e(y), w = Jm(v?.play_url);
    if (!w) throw new Error("\u60A6\u542C\u64AD\u653E\u5730\u5740\u4E3A\u7A7A");
    return E0({ parse: 0, url: w, header: H1e(t.userAgent, m), extra: { danmaku: "", nodanmu: true } });
  }, async search(n) {
    let s = Jm(n.body?.wd || n.body?.key), c = q1e(n.body?.page || n.body?.pg || 1);
    if (!s) return Me({ page: c, pagecount: 1, list: [] });
    let l = V1e(JSON.stringify({ keyword: s, page: c })), d = await Q1e(`${G1e}/search`, l, t10()), m = Y1e(d);
    return Me({ page: c, pagecount: 1, list: K60(m?.results) });
  } };
}
async function lZt(e9, t) {
  let n = await z1e(`${Mz}/album_info/${encodeURIComponent(t)}`), s = await z1e(`${Mz}/album_chapters/${encodeURIComponent(t)}`), l = (Array.isArray(s?.chapters) ? s.chapters : []).map((d) => {
    let m = Jm(d?.title), g = Jm(d?.index);
    return m ? `${m}$${t}|||${g}` : "";
  }).filter(Boolean);
  return b0({ id: t, name: n?.title, pic: n?.cover_url, typeName: n?.cat, content: n?.title, director: n?.teller, actor: n?.author, vod_play_from: l.length ? dZt(e9) : "", vod_play_url: l.join("#") });
}
async function z1e(e9) {
  let t = await t0.get(e9, { headers: t10(), responseType: "json", timeout: 2e4 });
  return Y1e(t.data || {});
}
function Y1e(e9) {
  return JSON.parse(z60(e9?.payload || ""));
}
function K60(e9) {
  return Array.isArray(e9) ? e9.map((t) => u0({ id: t?.id, name: t?.title, pic: t?.cover_url, remarks: t?.teller })).filter((t) => t.vod_id && t.vod_name) : [];
}
function fZt(e9, t, n) {
  return Q1e(e9, t, n);
}
function Q1e(e9, t, n = {}) {
  return new Promise((s, c) => {
    let l = new X60.URL(e9), d = {};
    for (let [g, y] of Object.entries(n || {})) g.toLowerCase().includes("content-type") || (d[g] = y);
    let m = J60.default.request({ hostname: l.hostname, port: l.port || 443, path: l.pathname + l.search, method: "POST", headers: { ...d, Connection: "close" }, timeout: 2e4 }, (g) => {
      let y = "";
      g.setEncoding("utf8"), g.on("data", (v) => {
        y += v;
      }), g.on("end", () => {
        try {
          s(JSON.parse(y || "{}"));
        } catch {
          s(y);
        }
      });
    });
    m.on("error", c), m.on("timeout", () => m.destroy(new Error(`POST timeout: ${e9}`))), m.write(typeof t == "string" ? t : JSON.stringify(t || "")), m.end();
  });
}
function t10() {
  return { "User-Agent": uZt };
}
function H1e(e9, t) {
  return { "User-Agent": e9, Cookie: `dfp=${t}` };
}
function dZt(e9) {
  return Jm(e9.remoteWexConfig?.Wexconfig?.vodfrom) || "\u64AD\u653E";
}
function pZt() {
  return { 2: [{ key: "class", name: "\u7C7B\u578B", value: [{ n: "\u6240\u6709\u7C7B\u578B", v: "" }, { n: "\u7384\u5E7B\u5947\u5E7B", v: "46" }, { n: "\u6B66\u4FA0\u5C0F\u8BF4", v: "11" }, { n: "\u8A00\u60C5\u901A\u4FD7", v: "19" }, { n: "\u76F8\u58F0\u5C0F\u54C1", v: "21" }, { n: "\u6050\u6016\u60CA\u609A", v: "14" }, { n: "\u5B98\u573A\u5546\u6218", v: "17" }, { n: "\u5386\u53F2\u519B\u4E8B", v: "15" }, { n: "\u767E\u5BB6\u8BB2\u575B", v: "9" }, { n: "\u5211\u4FA6\u53CD\u8150", v: "16" }, { n: "\u6709\u58F0\u6587\u5B66", v: "10" }, { n: "\u4EBA\u7269\u7EAA\u5B9E", v: "18" }, { n: "\u5E7F\u64AD\u5267", v: "36" }, { n: "\u82F1\u6587\u8BFB\u7269", v: "22" }, { n: "\u8F7B\u97F3\u6E05\u5FC3", v: "23" }, { n: "\u4E8C\u4EBA\u8F6C", v: "31" }, { n: "\u5065\u5EB7\u517B\u751F", v: "33" }, { n: "\u7EFC\u827A\u5A31\u4E50", v: "34" }, { n: "\u5934\u6761", v: "40" }, { n: "\u620F\u66F2", v: "38" }, { n: "\u8131\u53E3\u79C0", v: "41" }, { n: "\u7AE5\u8BDD\u5BD3\u8A00", v: "20" }, { n: "\u4EB2\u5B50\u6559\u80B2", v: "43" }, { n: "\u6559\u80B2\u57F9\u8BAD", v: "44" }] }], 1: [{ key: "class", name: "\u7C7B\u578B", value: [{ n: "\u6240\u6709\u7C7B\u578B", v: "" }, { n: "\u5355\u7530\u82B3", v: "1" }, { n: "\u5218\u5170\u82B3", v: "2" }, { n: "\u7530\u8FDE\u5143", v: "3" }, { n: "\u8881\u9614\u6210", v: "4" }, { n: "\u8FDE\u4E3D\u5982", v: "5" }, { n: "\u5B59\u4E00", v: "8" }, { n: "\u738B\u5B50\u5C01\u81E3", v: "30" }, { n: "\u9A6C\u957F\u8F89", v: "25" }, { n: "\u660A\u5112\u4E66\u573A", v: "26" }, { n: "\u738B\u519B", v: "27" }, { n: "\u738B\u73A5\u6CE2", v: "28" }, { n: "\u77F3\u8FDE\u541B", v: "29" }, { n: "\u7CA4\u8BED\u8BC4\u4E66", v: "12" }, { n: "\u5173\u6C38\u8D85", v: "35" }, { n: "\u5F20\u5C11\u4F50", v: "6" }, { n: "\u7530\u6218\u4E49", v: "7" }, { n: "\u5176\u4ED6\u8BC4\u4E66", v: "13" }] }] };
}
function Jm(e9, t = "") {
  return e9 == null || e9 === "" ? t : String(e9);
}
function mZt(e9) {
  let t = Number(e9);
  return Number.isFinite(t) ? t : 0;
}
function q1e(e9, t = 1) {
  let n = Number.parseInt(e9, 10);
  return Number.isFinite(n) && n >= 0 ? n : t;
}
var Z1e = "hema";
var r10 = 20;
function n10(e9 = {}) {
  let t = Cd({ key: "bookhema", name: "\u5C0F\u9A6C|\u542C\u4E66", api: Z1e, limit: r10, categoryUrl: ({ api: n, cateId: s, page: c, ext: l }) => i10(n, s, c, l), homeVideo: ({ parseVodList: n }) => hZt(n) }, e9);
  return { ...t, meta: { ...t.meta, \u7C7B\u578B: "\u542C\u4E66" }, async play(n) {
    let s = String(n.body?.id || "").trim();
    if (!s) throw new Error("\u6CB3\u9A6C\u542C\u4E66\u64AD\u653E\u53C2\u6570\u4E3A\u7A7A");
    let c = await rc(`https://djapi.999888456.xyz/api/${Z1e}/play?id=${encodeURIComponent(s)}`), l = String(c?.url || "").trim();
    if (!l) throw new Error("\u6CB3\u9A6C\u542C\u4E66\u64AD\u653E\u5730\u5740\u4E3A\u7A7A");
    return E0({ parse: Number(c?.parse || 0), jx: Number(c?.jx || 0), url: l, header: gZt(c?.header), extra: { nodanmu: true } });
  } };
}
async function hZt(e9) {
  let t = await rc(i10(Z1e, "", 1, {}));
  return { page: 1, pagecount: 999, limit: r10, total: 999, list: e9(t?.list || []) };
}
function i10(e9, t, n, s = {}) {
  let c = new URLSearchParams({ pg: String(n || 1) }), l = String(t || "").trim();
  l && c.set("tid", l);
  for (let [d, m] of Object.entries(s || {})) d === "cateId" || m === void 0 || m === null || m === "" || c.set(d, String(m));
  return `https://djapi.999888456.xyz/api/${e9}/category?${c.toString()}`;
}
function gZt(e9) {
  if (!e9 || typeof e9 != "object" || Array.isArray(e9)) return;
  let t = {};
  for (let [n, s] of Object.entries(e9)) {
    let c = String(n || "").trim(), l = String(s || "").trim();
    c && l && (t[c] = l);
  }
  return Object.keys(t).length ? t : void 0;
}
var J1e = "hongguobook";
var o10 = 20;
var bZt = [4, 8, 16].map((e9) => e9 * 1024 * 1024);
function s10(e9 = {}) {
  let t = Cd({ key: "bookhongguo", name: "\u5C0F\u7EA2|\u542C\u4E66", api: J1e, limit: o10, categoryUrl: ({ api: n, cateId: s, page: c, ext: l }) => x10(n, s, c, l), homeVideo: ({ parseVodList: n }) => yZt(n) }, e9);
  return { ...t, meta: { ...t.meta, \u7C7B\u578B: "\u542C\u4E66" }, async play(n) {
    let s = String(n.body?.id || "").trim();
    if (!s) throw new Error("\u7EA2\u679C\u542C\u4E66\u64AD\u653E\u53C2\u6570\u4E3A\u7A7A");
    let c = await rc(`https://djapi.999888456.xyz/api/${J1e}/play?id=${encodeURIComponent(s)}`), l = vZt(c?.header), d = Array.isArray(c?.key_urls) ? c.key_urls : [];
    if (d.length) {
      let y = [];
      for (let v of d) {
        let w = await a10(n, v, l);
        w && y.push(String(v?.name || "").trim() || "\u7EA2\u679C\u542C\u4E66", w);
      }
      if (y.length) return E0({ parse: 0, url: y, header: l, extra: { nodanmu: true } });
    }
    let m = await a10(n, c, l);
    if (m) return E0({ parse: 0, url: m, header: l, extra: { nodanmu: true } });
    let g = String(c?.url || "").trim();
    if (!g) throw new Error("\u7EA2\u679C\u542C\u4E66\u64AD\u653E\u5730\u5740\u4E3A\u7A7A");
    return E0({ parse: Number(c?.parse || 0), jx: Number(c?.jx || 0), url: g, header: l, extra: { nodanmu: true } });
  }, async proxy(n, s) {
    return _Zt(n) ? cz(n, s) : (s.code(404), { error: "unsupported hongguo book proxy" });
  } };
}
async function yZt(e9) {
  let t = await rc(x10(J1e, "", 1, {}));
  return { page: 1, pagecount: 999, limit: o10, total: 999, list: e9(t?.list || []) };
}
function x10(e9, t, n, s = {}) {
  let c = new URLSearchParams({ pg: String(n || 1) }), l = String(t || "").trim();
  l && c.set("tid", l);
  for (let [d, m] of Object.entries(s || {})) d === "cateId" || m === void 0 || m === null || m === "" || c.set(d, String(m));
  return `https://djapi.999888456.xyz/api/${e9}/category?${c.toString()}`;
}
async function a10(e9, t = {}, n = {}) {
  let s = K1e(t, ["src", "source_url", "url"]), c = K1e(t, ["spade_a", "encryption_key"]), l = K1e(t, ["kid"]);
  if (!s || !c || (l || (l = await AZt(s, n)), !l)) return "";
  let d = new URLSearchParams({ src: s, kid: l, spade_a: c, thread: "4", chunk: "512" });
  return `${wZt(e9)}/proxy/cenc?${d.toString()}`;
}
async function AZt(e9, t = {}) {
  for (let n of bZt) try {
    let s = await F0.get(e9, { responseType: "arraybuffer", timeout: 3e4, headers: { ...t, Range: `bytes=0-${n - 1}`, "Accept-Encoding": "identity" }, validateStatus: (l) => l === 200 || l === 206 }), c = kZt(Buffer.from(s.data || []));
    if (c) return c;
  } catch {
  }
  return "";
}
function kZt(e9) {
  if (!Buffer.isBuffer(e9) || e9.length < 32) return "";
  for (let t = 4; t + 28 <= e9.length; t++) {
    if (e9[t] !== 116 || e9[t + 1] !== 101 || e9[t + 2] !== 110 || e9[t + 3] !== 99) continue;
    let n = e9.readUInt32BE(t - 4);
    if (n < 28 || t - 4 + n > e9.length) continue;
    let s = t + 12, c = s + 16;
    if (!(c > e9.length)) return e9.subarray(s, c).toString("hex");
  }
  return "";
}
function K1e(e9, t) {
  for (let n of t) {
    let s = String(e9?.[n] || "").trim();
    if (s) return s;
  }
  return "";
}
function vZt(e9) {
  if (!e9 || typeof e9 != "object" || Array.isArray(e9)) return;
  let t = {};
  for (let [n, s] of Object.entries(e9)) {
    let c = String(n || "").trim(), l = String(s || "").trim();
    c && l && (t[c] = l);
  }
  return Object.keys(t).length ? t : void 0;
}
function _Zt(e9) {
  let t = String(e9.params?.provider || "").trim(), n = String(e9.params?.["*"] || "").trim();
  return t === "cenc" || n === "cenc" || n.startsWith("cenc/");
}
function wZt(e9) {
  let t = e9.headers?.["x-forwarded-proto"] || "http", n = e9.headers?.host || "127.0.0.1", s = "/proxy", l = String(e9.url || "").split("?")[0], d = l.indexOf(s);
  return `${t}://${n}${d >= 0 ? l.slice(0, d) : "/spider/bookhongguo/3"}`;
}
var u10 = C0(referenceBuiltin0, 1);
var SZt = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36";
function G_(e9 = {}, t = {}) {
  let n = { remoteWexConfig: t.remoteWexConfig, siteUrl: "", lastPageCount: 0 };
  return { meta: { key: e9.key, name: e9.name, type: 3, \u7C7B\u578B: "\u5C11\u513F" }, async init() {
    let s = n.remoteWexConfig;
    s?.requireReady && await s.requireReady();
    let c = d10(s?.Wexsiteurl || s?.wexSiteUrl || "");
    if (!c) throw new Error(`${e9.name}\u8FDC\u7A0B\u914D\u7F6E\u672A\u521D\u59CB\u5316`);
    return n.siteUrl = `${c}${e9.path}`, console.log(`[${e9.key}] siteUrl=${n.siteUrl}`), {};
  }, async home() {
    return P0(e9.typeIds.map((s, c) => ({ type_id: s, type_name: e9.typeNames[c] || s })), {});
  }, async category(s) {
    await X1e(n, e9);
    let c = s.body || {}, l = c.extend || c.filters || {}, d = EZt(c.page || c.pg || 1), m = jc(l.cateId || c.id || c.tid);
    n.lastPageCount = 0;
    let g = e9.parseList(await Uz(n, e9.listUrl(n.siteUrl, m, String(d))), n);
    return Me({ page: d, pagecount: e9.pageCount ? e9.pageCount(d, g, n) : RZt(d, g, e9.pageSize || 30), limit: e9.pageSize || 30, total: 0, list: g });
  }, async detail(s) {
    await X1e(n, e9);
    let c = Array.isArray(s.body?.id) ? s.body.id : [s.body?.id], l = [];
    for (let d of c.filter(Boolean)) l.push(e9.parseDetail(String(d), await Uz(n, e9.detailUrl(n.siteUrl, String(d))), n, e9));
    return l0(l);
  }, async play(s) {
    await X1e(n, e9);
    let c = jc(s.body?.id);
    if (!c) throw new Error(`${epe(n)}\u64AD\u653E\u53C2\u6570\u4E3A\u7A7A`);
    if (e9.play) return e9.play(n, e9, c);
    let l = TZt(await Uz(n, e9.playUrl(n.siteUrl, c)));
    if (e9.resolvePlay && (l = await e9.resolvePlay(l, n, e9, c)), !l) throw new Error(`${epe(n)}\u64AD\u653E\u5730\u5740\u4E3A\u7A7A`);
    return E0({ parse: 0, url: l, header: WN(), extra: { danmaku: "", nodanmu: true } });
  }, async search() {
    return "";
  } };
}
function H_({ id: e9, name: t, pic: n, content: s, items: c, state: l }) {
  return b0({ id: e9, name: t, pic: n, content: s, vod_play_from: c?.length ? epe(l) : "", vod_play_url: (c || []).join("#") });
}
async function l10(e9) {
  let t = CZt(`3c0a32a3-dc15-461f-baaf-8b8c548c875aa100420240503142629b1*pc@s$9@${e9}`), n = `https://cp.bz.mgtv.com/a1004/${e9}?_support=10100001&device=ASUS_I003DD&osVersion=7.1.2&appVersion=6.1.1.2&ticket=&userId=0&mac=i867414555572929&osType=android&channel=a1004&uuid=&endType=mgtvapp&androidid=9343b8f933355c7f&imei=867414555572929&macaddress=32%3Aba%3A65%3A28%3Ab8%3A16&seqId=i867414555572929.1714717589250&version=5.2&type=10&abroad=0&src=mgtv&uid=&phonetype=ASUS_I003DD&testversion=&c=3c0a32a3-dc15-461f-baaf-8b8c548c875a&t=20240503142629&s=${t}&ch_token=`, c = (await c10(n))?.data?.videoSources?.[0]?.url;
  if (!c) return "";
  let l = await c10(`http://disp.titan.mgtv.com${c}`);
  return jc(l?.info);
}
function epe(e9) {
  return String(e9.remoteWexConfig?.Wexconfig?.vodfrom || e9.remoteWexConfig?.snapshot?.()?.vodfrom || "\u64AD\u653E").trim() || "\u64AD\u653E";
}
function WN() {
  return { "User-Agent": SZt };
}
function jc(e9, t = "") {
  return e9 == null || e9 === "" ? t : String(e9);
}
function EZt(e9, t = 1) {
  let n = Number.parseInt(e9, 10);
  return Number.isFinite(n) && n > 0 ? n : t;
}
function D1(e9) {
  return e9 && typeof e9 == "object" ? e9 : JSON.parse(String(e9 || "{}"));
}
function q_(e9, t, n, s = "") {
  return u0({ id: e9, name: t, pic: n, remarks: s });
}
async function f10(e9, t) {
  return Uz(e9, t);
}
async function X1e(e9, t) {
  if (e9.siteUrl) return;
  let n = e9.remoteWexConfig;
  n?.requireReady && await n.requireReady();
  let s = d10(n?.Wexsiteurl || n?.wexSiteUrl || "");
  if (!s) throw new Error(`${t.name}\u8FDC\u7A0B\u914D\u7F6E\u672A\u521D\u59CB\u5316`);
  e9.siteUrl = `${s}${t.path}`;
}
async function Uz(e9, t) {
  let n = await t0.get(t, { headers: WN(), responseType: "text", transformResponse: [(s) => s], timeout: 2e4 });
  return IZt(n.data);
}
async function c10(e9) {
  return (await t0.get(e9, { headers: WN(), responseType: "json", timeout: 2e4 })).data || {};
}
function TZt(e9) {
  let t = D1(e9);
  return t?.Data && typeof t.Data == "object" ? jc(t.Data.PlayUrl) : jc(t?.data);
}
function IZt(e9) {
  let t = String(e9 || "").replace(/^\uFEFF/, "").trim();
  if (/^[\[{]/.test(t) || t.includes("|||")) return t;
  try {
    return $_.decrypt(t);
  } catch (n) {
    throw new Error(`\u5C11\u513F\u63A5\u53E3\u89E3\u5BC6\u5931\u8D25\uFF1A${n?.message || n}`);
  }
}
function RZt(e9, t, n) {
  return t.length < n ? e9 : e9 + 1;
}
function d10(e9) {
  return String(e9 || "").trim().replace(/\/+$/, "");
}
function CZt(e9) {
  return u10.default.createHash("md5").update(String(e9), "utf8").digest("hex");
}
function p10(e9 = {}) {
  return G_({ key: "childrenaitutu", name: "\u5154\u5154|\u5C11\u513F", path: "/tutu", typeIds: ["1", "2", "3", "4", "5", "6"], typeNames: ["\u5154\u5154\u513F\u6B4C", "\u5154\u5154\u6545\u4E8B", "\u5154\u5154\u5B66\u5802", "\u5154\u5154\u56FD\u5B66", "\u5154\u5154\u542F\u8499", "\u76CA\u667A\u73A9\u5177"], pageSize: 20, listUrl: (t, n, s) => `${t}/list.php?typeid=${encodeURIComponent(n)}&pg=${encodeURIComponent(s)}`, detailUrl: (t, n) => {
    let s = String(n).split("|||");
    return `${t}/detail.php?typeid=${encodeURIComponent(s[1] || "")}&vodid=${encodeURIComponent(s[0] || n)}`;
  }, playUrl: (t, n) => `${t}/play.php?playid=${encodeURIComponent(n)}`, parseList(t, n) {
    let s = D1(t);
    return n.lastPageCount = Number(s?._meta?.pageCount || 0), (Array.isArray(s?.data) ? s.data : []).map((c) => q_(`${jc(c?.album_id)}|||${jc(c?.category_id)}`, c?.name, c?.image)).filter((c) => c.vod_id && c.vod_name);
  }, parseDetail(t, n, s) {
    let c = D1(n)?.data || {}, l = (Array.isArray(c?.items) ? c.items : []).map((d) => `${jc(d?.name)}$${jc(d?.video_id)}`).filter((d) => !d.endsWith("$"));
    return H_({ id: t, name: c.name, pic: c.image, items: l, state: s });
  }, pageCount(t, n, s) {
    return s.lastPageCount > 0 ? s.lastPageCount : n.length < 20 ? t : t + 1;
  } }, e9);
}
function m10(e9 = {}) {
  return G_({ key: "childrenaibaobao", name: "\u5B9D\u5B9D|\u5C11\u513F", path: "/baobao", typeIds: ["1", "3", "2", "5", "7", "4", "6"], typeNames: ["\u5B9D\u5B9D\u7231\u770B", "\u7ECF\u5178\u513F\u6B4C", "\u52A8\u753B\u7CBE\u9009", "\u77E5\u8BC6\u767E\u79D1", "\u4E60\u60EF\u57F9\u517B", "\u827A\u672F\u542F\u8499", "\u82F1\u6587\u513F\u6B4C"], listUrl: (t, n, s) => `${t}/list.php?typeid=${encodeURIComponent(n)}&pg=${encodeURIComponent(s)}`, detailUrl: (t, n) => `${t}/detail.php?vodid=${encodeURIComponent(n)}`, playUrl: (t, n) => `${t}/play.php?playid=${encodeURIComponent(n)}`, parseList(t) {
    let n = D1(t);
    return (Array.isArray(n?.Data) ? n.Data : []).map((s) => q_(s?.ID, s?.Name, s?.Img)).filter((s) => s.vod_id && s.vod_name);
  }, parseDetail(t, n, s) {
    let c = D1(n)?.Data || {}, l = (Array.isArray(c?.list) ? c.list : []).map((d) => `${jc(d?.Name)}$${jc(d?.ID)}`).filter((d) => !d.endsWith("$"));
    return H_({ id: t, name: c.Name, pic: c.Img, content: c.Info, items: l, state: s });
  }, async resolvePlay(t) {
    return String(t || "").startsWith("http") ? t : l10(t);
  } }, e9);
}
function h10(e9 = {}) {
  return G_({ key: "childrenaibeiwa", name: "\u8D1D\u74E6|\u5C11\u513F", path: "/beiwa", typeIds: ["1", "2", "3", "4", "5", "6", "7", "8", "9", "10", "11", "12", "13", "14", "15", "16", "17", "18"], typeNames: ["VIP\u7CBE\u9009", "\u513F\u6B4C\u52A8\u753B", "\u82F1\u8BED\u542F\u8499", "\u6570\u7406\u903B\u8F91", "\u65E9\u6559\u542F\u8499", "\u56FD\u5B66\u77E5\u8BC6", "\u79D1\u5B66\u8BA4\u77E5", "\u60C5\u5546\u57F9\u517B", "\u821E\u8E48\u5F8B\u52A8", "\u827A\u672F\u7D20\u517B", "\u6210\u957F\u76CA\u667A", "\u73A9\u5177\u4E1B\u6797", "\u5E7D\u9ED8\u641E\u7B11", "\u5192\u9669\u63A2\u79D8", "\u7F8E\u98DF\u5929\u5802", "\u4EA4\u901A\u5DE5\u5177", "\u8D85\u7EA7\u82F1\u96C4", "\u795E\u5947\u52A8\u7269"], listUrl: (t, n) => `${t}/list.php?typeid=${encodeURIComponent(n)}`, detailUrl: (t, n) => `${t}/detail.php?vid=${encodeURIComponent(n)}`, playUrl: (t, n) => `${t}/play.php?playid=${encodeURIComponent(n)}`, parseList(t) {
    let n = D1(t);
    return (Array.isArray(n?.node_relation_children) ? n.node_relation_children : []).map((s) => {
      let c = s?.node_object_data || {};
      return q_(c.item_id, c.title, c.picture_hori);
    }).filter((s) => s.vod_id && s.vod_name);
  }, parseDetail(t, n, s) {
    let c = D1(n)?.data || {}, l = c?.node_object_data || {}, d = (Array.isArray(c?.node_relation_children) ? c.node_relation_children : []).map((m) => {
      let g = m?.node_object_data || {};
      return `${jc(g?.title)}$${jc(g?.res_identifier)}`;
    }).filter((m) => !m.endsWith("$"));
    return H_({ id: t, name: l.title, pic: l.picture_hori, content: l.category_tag, items: d, state: s });
  }, async play(t, n, s) {
    let l = (await f10(t, n.playUrl(t.siteUrl, s))).split("|||"), d = String(s).length > 16 ? ["1080p", l[0] || "", "720p", l[1] || ""] : ["720p", l[0] || "", "480p", l[1] || ""];
    return E0({ parse: 0, url: d, header: WN(), extra: { danmaku: "", nodanmu: true } });
  } }, e9);
}
var Y2 = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36";
function Pd(e9 = {}) {
  return { "User-Agent": Y2, ...e9 };
}
async function z_(e9, t, n) {
  let s = e9.remoteWexConfig;
  s?.requireReady && await s.requireReady();
  let c = NZt(s?.Wexsiteurl || s?.wexSiteUrl || "");
  if (!c) throw new Error(`${n}\u8FDC\u7A0B\u914D\u7F6E\u672A\u521D\u59CB\u5316`);
  e9.siteUrl = `${c}${t}`, console.log(`[${e9.key}] siteUrl=${e9.siteUrl}`);
}
async function cl(e9) {
  let t = await t0.get(e9, { headers: Pd(), responseType: "text", transformResponse: [(s) => s], timeout: 2e4 }), n = String(t.data || "").replace(/^\uFEFF/, "").trim();
  if (!n) return "{}";
  if (/^[\[{]/.test(n) || /^https?:\/\//i.test(n)) return n;
  try {
    return $_.decrypt(n);
  } catch (s) {
    throw new Error(`\u97F3\u4E50\u63A5\u53E3\u89E3\u5BC6\u5931\u8D25\uFF1A${s?.message || s}`);
  }
}
function Wn(e9, t = "\u64AD\u653E") {
  return String(e9?.Wexconfig?.vodfrom || e9?.snapshot?.()?.vodfrom || t).trim() || t;
}
function ve(e9, t = "") {
  return e9 == null || e9 === "" ? t : String(e9);
}
function en(e9, t = 1) {
  let n = Number.parseInt(e9, 10);
  return Number.isFinite(n) && n > 0 ? n : t;
}
function ul(e9, t = {}) {
  if (e9 && typeof e9 == "object") return e9;
  try {
    return JSON.parse(String(e9 || ""));
  } catch {
    return t;
  }
}
function NZt(e9) {
  return String(e9 || "").replace(/^\uFEFF/, "").trim().replace(/\/+$/, "");
}
function po(e9, t = {}, n = "") {
  let s = DZt(t), c = Array.isArray(e9?.list) ? e9.list : [];
  for (let l of c) l?.vod_pic && (l.vod_pic = OZt(s, l.vod_pic, n));
  return e9;
}
function OZt(e9, t, n = "") {
  let s = String(t || "").trim();
  if (!s || !/^https?:\/\//i.test(s) || s.includes("/imageProxy?")) return s;
  let c = { "User-Agent": Y2 };
  n && (c.Referer = n);
  let l = new URLSearchParams({ url: s, cache: "86400", customHeaders: JSON.stringify(c) });
  return `${e9}/imageProxy?${l}`;
}
function DZt(e9 = {}) {
  let t = e9.headers?.["x-forwarded-proto"] || "http", n = e9.headers?.host || `127.0.0.1:${e9.server?.server?.address?.()?.port || 9988}`;
  return `${t}://${n}`;
}
var PZt = "http://ottphoto.daoran.tv/HD/";
var BZt = MZt();
function g10(e9 = {}) {
  let t = { key: "musicailiyuan", remoteWexConfig: e9.remoteWexConfig, siteUrl: "" };
  return { meta: { key: t.key, name: "\u68A8\u56ED|\u620F\u66F2", type: 3 }, async init() {
    return await z_(t, "/liyuan", "\u68A8\u56ED"), {};
  }, async home() {
    return P0([{ type_id: "1", type_name: "\u620F\u66F2\u5927\u5168" }, { type_id: "2", type_name: "\u540D\u5BB6\u5927\u8155" }], BZt);
  }, async category(n) {
    await $z(t);
    let s = n.body || {}, c = s.extend || {}, l = ve(s.id || s.tid, "1"), d = en(s.page || s.pg || 1), m = ve(c.cateId, l), g = ve(c.class, "jingju"), y, v, w = 50;
    l === "1" ? (y = await cl(`${t.siteUrl}/vodlist.php?type=${encodeURIComponent(g)}&pg=${d}`), v = tpe(y)) : l === "2" ? (y = await cl(`${t.siteUrl}/namelist.php?type=${encodeURIComponent(g)}&pg=${d}`), v = LZt(y)) : (y = await cl(`${t.siteUrl}/nameidlist.php?nameid=${encodeURIComponent(m)}&pg=${d}`), v = tpe(y), w = 16);
    let T = ul(y)?.pb || {};
    return Me({ page: d, pagecount: en(T.totalCount, d), limit: w, total: 0, list: v });
  }, async detail(n) {
    await $z(t);
    let s = ve(Array.isArray(n.body?.id) ? n.body.id[0] : n.body?.id);
    if (!s) throw new Error("\u68A8\u56ED\u53C2\u6570\u4E3A\u7A7A");
    let c = ul(await cl(`${t.siteUrl}/detail.php?vodid=${encodeURIComponent(s)}`)), l = c.album || {}, d = npe(c?.pb?.dataList).map((m) => `${ve(m?.name)}$${ve(m?.code)}`).filter((m) => !m.endsWith("$"));
    return l0([b0({ id: s, name: l.name, pic: rpe(l.img), content: l.des, actor: l.artistName, vod_play_from: d.length ? Wn(t.remoteWexConfig) : "", vod_play_url: d.join("#") })]);
  }, async play(n) {
    await $z(t);
    let s = ve(n.body?.id), c = ul(await cl(`${t.siteUrl}/play.php?vodid=${encodeURIComponent(s)}`)), l = ve(c?.playres?.playurl);
    if (!l) throw new Error("\u68A8\u56ED\u64AD\u653E\u5730\u5740\u4E3A\u7A7A");
    return E0({ parse: 0, url: l, header: Pd(), extra: { danmaku: "", nodanmu: true } });
  }, async search(n) {
    await $z(t);
    let s = n.body || {}, c = ve(s.wd || s.key), l = en(s.page || s.pg || 1), d = await cl(`${t.siteUrl}/so.php?key=${encodeURIComponent(c)}&pg=${l}`);
    return { list: tpe(d) };
  } };
}
function LZt(e9) {
  return npe(ul(e9)?.pb?.dataList).map((t) => Qa({ id: ve(t?.code), name: t?.name, pic: rpe(t?.image) })).filter((t) => t.vod_id && t.vod_name);
}
function tpe(e9) {
  return npe(ul(e9)?.pb?.dataList).map((t) => u0({ id: ve(t?.code), name: t?.name, pic: rpe(t?.img) })).filter((t) => t.vod_id && t.vod_name);
}
async function $z(e9) {
  e9.siteUrl || await z_(e9, "/liyuan", "\u68A8\u56ED");
}
function rpe(e9) {
  let t = ve(e9);
  return /^https?:\/\//i.test(t) ? t : `${PZt}${t}`;
}
function npe(e9) {
  return Array.isArray(e9) ? e9 : [];
}
function MZt() {
  let t = [{ key: "class", name: "\u5267\u79CD", value: [["\u5415\u5267", "lvjv"], ["\u4EAC\u5267", "jingju"], ["\u8D8A\u5267", "yueju"], ["\u6CB3\u5317\u6886\u5B50", "hbbz"], ["\u8D63\u5267", "gj"], ["\u8BC4\u5267", "pingju"], ["\u8BC4\u4E66", "pingshu"], ["\u9EC4\u6885\u620F", "hmx"], ["\u8C6B\u5267", "yuju"], ["\u7CA4\u5267", "gddx"], ["\u76F8\u58F0", "xiang"], ["\u5760\u5B50", "hnzz"], ["\u4E8C\u5939\u5F26", "ejx"], ["\u66F2\u5267", "quju"], ["\u6CB3\u5357\u5927\u9F13\u4E66", "hndgs"], ["\u6CB3\u5357\u7434\u4E66", "hnqs"], ["\u4EAC\u97F5\u5927\u9F13", "jydg"], ["\u6606\u66F2", "kunqu"], ["\u8D8A\u8C03", "yued"], ["\u7ECD\u5267", "shaojv"], ["\u6CAA\u5267", "huju"], ["\u5E90\u5267", "luju"], ["\u79E6\u8154", "qinq"], ["\u664B\u5267", "jinju"], ["\u6F6E\u5267", "chaoju"], ["\u9521\u5267", "xiju"], ["\u5DDD\u5267", "chuanju"], ["\u82B1\u9F13\u620F", "huagx"], ["\u6DEE\u5267", "huaiju"], ["\u5409\u5267", "jiju"], ["\u5929\u6D25\u65F6\u8C03", "tjsd"], ["\u4FDD\u5B9A\u8001\u8C03", "bdld"], ["\u8BDD\u5267", "huaju"], ["\u626C\u5267", "yangju"], ["\u6EC7\u5267", "dianju"], ["\u5A7A\u5267", "wuju"], ["\u5B9B\u6886", "wb"], ["\u56DB\u5E73\u8C03", "spd"], ["\u4E50\u8154", "lq"], ["\u592A\u5EB7\u9053\u60C5", "tkdq"], ["\u5927\u5E73\u8C03", "dpd"], ["\u5355\u5F26", "danxian"], ["\u6B63\u5B57\u620F", "zzx"], ["\u5F69\u8C03", "caidiao"], ["\u5176\u4ED6", "other"], ["\u6C49\u5267", "hj"], ["\u897F\u79E6\u620F", "xqx"], ["\u8386\u4ED9\u620F", "pxx"], ["\u767D\u5B57\u620F", "bzx"], ["\u84B2\u5267", "pujv"], ["\u6885\u82B1\u5927\u9F13", "mhdg"], ["\u897F\u6CB3\u5927\u9F13", "xhdg"], ["\u695A\u5267", "chuju"], ["\u67F3\u7434\u620F", "liuqx"], ["\u4E8C\u4EBA\u53F0", "ERT"]].map(([n, s]) => ({ n, v: s })) }];
  return { 1: t, 2: t };
}
var UZt = "https://www.qtfm.cn";
var $Zt = ["217", "99", "3", "5", "7", "83", "19", "31", "44", "59", "69", "85", "111", "129", "139", "151", "169", "187", "202", "239", "254", "257", "259", "281", "291", "316", "327", "351", "357", "308", "342", "433", "442", "429", "439", "432", "441", "430", "431", "440", "438", "435", "436", "434"];
var FZt = ["\u5E7F\u4E1C", "\u6D59\u6C5F", "\u5317\u4EAC", "\u5929\u6D25", "\u6CB3\u5317", "\u4E0A\u6D77", "\u5C71\u897F", "\u5185\u8499\u53E4", "\u8FBD\u5B81", "\u5409\u6797", "\u9ED1\u9F99\u6C5F", "\u6C5F\u82CF", "\u5B89\u5FBD", "\u798F\u5EFA", "\u6C5F\u897F", "\u5C71\u4E1C", "\u6CB3\u5357", "\u6E56\u5317", "\u6E56\u5357", "\u5E7F\u897F", "\u6D77\u5357", "\u91CD\u5E86", "\u56DB\u5DDD", "\u8D35\u5DDE", "\u4E91\u5357", "\u9655\u897F", "\u7518\u8083", "\u5B81\u590F", "\u65B0\u7586", "\u897F\u85CF", "\u9752\u6D77", "\u8D44\u8BAF", "\u97F3\u4E50", "\u4EA4\u901A", "\u7ECF\u6D4E", "\u6587\u827A", "\u90FD\u5E02", "\u4F53\u80B2", "\u53CC\u8BED", "\u7EFC\u5408", "\u751F\u6D3B", "\u65C5\u6E38", "\u66F2\u827A", "\u65B9\u8A00"];
function A10(e9 = {}) {
  let t = e9.remoteWexConfig;
  return { meta: { key: "musicaiqingting", name: "\u873B\u8713|\u7535\u53F0", type: 3, \u7C7B\u578B: "\u97F3\u4E50" }, async init() {
    return {};
  }, async home() {
    return P0($Zt.map((n, s) => ({ type_id: n, type_name: FZt[s] || n })), {});
  }, async category(n) {
    let s = n.body || {}, c = s.extend || {}, l = en(s.page || s.pg || 1), d = ve(c.cateId || s.id || s.tid, "217"), m = await b10(`{
    radioPage(cid:${d}, page:${l}){
      contents
    }
  }`), g = y10(m?.data?.radioPage?.contents?.items, false);
    return Me({ page: l, pagecount: g.length < 12 ? l : l + 1, limit: 12, total: 0, list: g });
  }, async detail(n) {
    let s = ve(Array.isArray(n.body?.id) ? n.body.id[0] : n.body?.id);
    if (!s) throw new Error("\u9752\u542C\u53C2\u6570\u4E3A\u7A7A");
    let l = (await t0.get(`https://webapi.qtfm.cn/api/pc/radio/${encodeURIComponent(s)}`, { headers: ipe(), responseType: "json", timeout: 2e4 })).data?.album || {}, d = [`${ve(l.title)}$${ve(l.id)}`].filter((m) => !m.endsWith("$"));
    return l0([b0({ id: s, name: l.title, pic: l.cover, content: l.description, vod_play_from: d.length ? Wn(t) : "", vod_play_url: d.join("#") })]);
  }, async play(n) {
    let s = ve(n.body?.id);
    return E0({ parse: 0, url: `https://lhttp-hw.qtfm.cn/live/${encodeURIComponent(s)}/64k.mp3`, header: ipe(), extra: { danmaku: "", nodanmu: true } });
  }, async search(n) {
    let s = n.body || {}, c = ve(s.wd || s.key), l = en(s.page || s.pg || 1), d = await b10(`{
        searchResultsPage(keyword:${JSON.stringify(c)}, page:${l}, include:"channel_live" ) {
          tdk,
          searchData,
          numFound
        }
      }`);
    return { page: l, pagecount: 1, list: y10(d?.data?.searchResultsPage?.searchData, true) };
  } };
}
async function b10(e9) {
  return (await t0.post("https://webbff.qtfm.cn/www", { query: e9 }, { headers: ipe({ "Content-Type": "application/json" }), responseType: "json", timeout: 2e4 })).data || {};
}
function y10(e9, t) {
  return Array.isArray(e9) ? e9.map((n) => {
    let s = ve(t ? n?.cover : n?.imgUrl);
    return s.startsWith("//") && (s = `https:${s}`), u0({ id: n?.id, name: n?.title, pic: s, remarks: t ? n?.description : n?.desc });
  }).filter((n) => n.vod_id && n.vod_name) : [];
}
function ipe(e9 = {}) {
  return Pd({ Referer: UZt, ...e9 });
}
var WZt = "http://bimg.tangdou.com";
var VZt = { 1471610743: [{ key: "cateId", name: "\u7C7B\u578B", value: [{ n: "\u5F39\u8DF3\u821E", v: "1471610743" }, { n: "\u6B65\u5B50\u821E", v: "1471610739" }, { n: "\u53CC\u4EBA\u821E", v: "1471610742" }, { n: "\u5065\u8EAB\u821E", v: "1471610738" }, { n: "\u6D41\u884C\u821E", v: "1471610748" }, { n: "\u9B3C\u6B65\u821E", v: "1471610757" }, { n: "\u6C34\u5175\u821E", v: "1471610758" }, { n: "\u6C11\u65CF\u98CE", v: "1471610746" }] }] };
function v10(e9 = {}) {
  let t = { key: "musicaitangdou", remoteWexConfig: e9.remoteWexConfig, siteUrl: "" };
  return { meta: { key: t.key, name: "\u7CD6\u8C46|\u821E\u8E48", type: 3 }, async init() {
    return await z_(t, "/tangdou", "\u7CD6\u8C46"), {};
  }, async home() {
    let n = ["1471610743", "11", "2", "20", "18", "5"], s = ["\u5E7F\u573A\u821E+\u821E\u8E48", "\u540D\u5E08", "\u5065\u8EAB", "\u4E50\u827A\u5385", "\u70ED\u699C", "\u5973\u795E\u5FC5\u5907"];
    return P0(n.map((c, l) => ({ type_id: c, type_name: s[l] })), VZt);
  }, async category(n) {
    await ape(t);
    let s = n.body || {}, c = s.extend || {}, l = en(s.page || s.pg || 1), d = ve(s.id || s.tid, "1471610743"), m = ve(c.cateId, d), g;
    return m === "11" || m === "18" ? g = k10(await cl(`${t.siteUrl}/gettab.php?tab_id=${encodeURIComponent(m)}`), "2", true) : m === "2" || m === "20" || m === "5" ? g = k10(await cl(`${t.siteUrl}/gettab.php?tab_id=${encodeURIComponent(m)}`), "1", false) : g = jZt(await cl(`${t.siteUrl}/getlist.php?pid=${encodeURIComponent(m)}`)), Me({ page: l, pagecount: 1, limit: 999, total: 0, list: g });
  }, async detail(n) {
    await ape(t);
    let s = ve(Array.isArray(n.body?.id) ? n.body.id[0] : n.body?.id);
    if (!s) throw new Error("\u7CD6\u8C46\u53C2\u6570\u4E3A\u7A7A");
    let c = ul(await cl(`${t.siteUrl}/detail.php?vid=${encodeURIComponent(s)}`))?.datas || {}, l = await cl(`${t.siteUrl}/play.php?vid=${encodeURIComponent(s)}`), d = await GZt(`https://aa.tangdou.com:12308/tv_api.php?${l}`), m = Y_(d?.datas?.hd);
    m.length || (m = Y_(d?.datas?.sd));
    let g = m.map((y) => `${ve(y?.cdn_source)}$${ve(y?.url)}`).filter((y) => !y.endsWith("$"));
    return l0([b0({ id: s, name: c.title, pic: Fz(c.pic), content: c.content_from, vod_play_from: g.length ? Wn(t.remoteWexConfig) : "", vod_play_url: g.join("#") })]);
  }, async play(n) {
    let s = ve(n.body?.id);
    return E0({ parse: 0, url: s, header: Pd(), extra: { danmaku: "", nodanmu: true } });
  }, async search(n) {
    await ape(t);
    let s = n.body || {}, c = ve(s.wd || s.key), l = en(s.page || s.pg || 1), d = ul(await cl(`${t.siteUrl}/so.php?search_key=${encodeURIComponent(c)}&pg=${l}`));
    return { list: Y_(d?.datas).map((m) => u0({ id: m?.vid, name: m?.title, pic: Fz(m?.pic) })).filter((m) => m.vod_id && m.vod_name) };
  } };
}
function k10(e9, t, n) {
  let s = Y_(ul(e9)?.datas?.block), c = [];
  for (let l of s) if (ve(l?.stype).includes(t)) for (let d of Y_(l?.videos)) {
    let m = ve(n ? d?.pid : d?.vid);
    m && c.push((n ? Qa : u0)({ id: m, name: d?.title, pic: Fz(d?.pic) }));
  }
  return c.filter((l) => l.vod_id && l.vod_name);
}
function jZt(e9) {
  return Y_(ul(e9)?.datas?.videos).map((t) => u0({ id: t?.vid, name: t?.title, pic: Fz(t?.pic) })).filter((t) => t.vod_id && t.vod_name);
}
async function GZt(e9) {
  return (await t0.get(e9, { headers: Pd(), responseType: "json", timeout: 2e4 })).data || {};
}
async function ape(e9) {
  e9.siteUrl || await z_(e9, "/tangdou", "\u7CD6\u8C46");
}
function Fz(e9) {
  let t = ve(e9);
  return /^https?:\/\//i.test(t) ? t : `${WZt}${t}`;
}
function Y_(e9) {
  return Array.isArray(e9) ? e9 : [];
}
var Wz = "https://www.dj92.cc";
var HZt = /token:\s*'([^']+)'/;
function w10(e9 = {}) {
  let t = e9.remoteWexConfig;
  return { meta: { key: "musicailunhui", name: "\u8F6E\u56DE|\u821E\u66F2", type: 3, \u7C7B\u578B: "\u97F3\u4E50" }, async init() {
    return {};
  }, async home() {
    let n = ["1", "2", "3", "4", "5", "7", "8"], s = ["\u7535\u97F3House", "\u4E2D\u6587\u821E\u66F2", "\u5916\u6587\u821E\u66F2", "\u9152\u5427\u98CE\u683C", "\u4E32\u70E7\u821E\u66F2", "\u79C1\u6539\u821E\u66F2", "\u5927\u8D5B\u4F5C\u54C1"];
    return P0(n.map((c, l) => ({ type_id: c, type_name: s[l] })), {});
  }, async category(n) {
    let s = n.body || {}, c = s.extend || {}, l = en(s.page || s.pg || 1), d = ve(c.cateId || s.id || s.tid, "1"), m = _10(await ope(`${Wz}/djlist/${encodeURIComponent(d)}/${l}.html`));
    return Me({ page: l, pagecount: m.length < 20 ? l : l + 1, limit: 20, total: 0, list: m });
  }, async detail(n) {
    let s = ve(Array.isArray(n.body?.id) ? n.body.id[0] : n.body?.id);
    if (!s) throw new Error("\u8F6E\u56DE\u53C2\u6570\u4E3A\u7A7A");
    let c = await ope(`${Wz}${s}`), d = Pr(c)("div.music-info-box > div.music-play-box > h3 > span.name").text().trim(), m = zZt(c), g = "";
    if (m) {
      let v = await qZt(m);
      g = ve(v?.playurl), g && !/^https?:\/\//i.test(g) && (g = `https:${g}`);
    }
    let y = g ? [`\u70B9\u51FB\u64AD\u653E$${g}`] : [];
    return l0([b0({ id: s, name: d, vod_play_from: y.length ? Wn(t) : "", vod_play_url: y.join("#") })]);
  }, async play(n) {
    let s = ve(n.body?.id);
    return E0({ parse: 0, url: s, header: spe(), extra: { danmaku: "", nodanmu: true } });
  }, async search(n) {
    let s = n.body || {}, c = ve(s.wd || s.key), l = en(s.page || s.pg || 1);
    return { list: _10(await ope(`${Wz}/search.html?key=${encodeURIComponent(c)}&page=${l}`)) };
  } };
}
function _10(e9) {
  let t = Pr(e9 || ""), n = [];
  return t("div.layui-col-md8 > div > div.music-body > ul > li").each((s, c) => {
    let l = t(c), d = l.find("div.center > span.name > a").first(), m = l.find("div.user > a > img").first(), g = l.find("div.center > span.nickname > a").first(), y = ve(d.attr("href")), v = ve(m.attr("src"));
    v.startsWith("//") && (v = `https:${v}`);
    let w = ve(d.attr("title"), d.text().trim()), T = ve(g.attr("title"), g.text().trim());
    !y || !w || !v || !T || n.push(u0({ id: y, name: w, pic: v, remarks: T }));
  }), n;
}
async function ope(e9) {
  let t = await t0.get(e9, { headers: spe(), responseType: "text", transformResponse: [(n) => n], timeout: 2e4 });
  return String(t.data || "");
}
async function qZt(e9) {
  let t = new URLSearchParams();
  return t.set("token", e9), (await t0.post(`${Wz}/ajax/info`, t.toString(), { headers: spe({ "Content-Type": "application/x-www-form-urlencoded; charset=UTF-8" }), responseType: "json", timeout: 2e4 })).data || {};
}
function zZt(e9) {
  return HZt.exec(String(e9 || ""))?.[1] || "";
}
function spe(e9 = {}) {
  return Pd(e9);
}
var E10 = C0(referenceBuiltin3, 1);
function Vz(e9 = {}, t = {}) {
  let n = { cookie: "", lrcCache: /* @__PURE__ */ new Map(), remoteWexConfig: t.remoteWexConfig };
  return { meta: { key: e9.key, name: e9.name, type: 3, \u7C7B\u578B: "\u97F3\u4E50" }, async init() {
    return await XZt(n, e9.site), {};
  }, async home() {
    return P0([{ type_id: "singerlist", type_name: "\u6B4C\u624B" }, { type_id: e9.playlistTid, type_name: "\u6B4C\u5355" }, { type_id: "list", type_name: "\u699C\u5355" }, { type_id: "albumlist", type_name: "\u65B0\u789F" }], {});
  }, async category(s) {
    let c = s.body || {}, l = c.extend || c.filters || {}, d = en(c.page || c.pg || 1), m = ve(c.id || c.tid, "singerlist"), g = ve(l.cateId, m), y = ve(l.classid, "index"), v = ve(l.diqu, "index"), w = ve(l.xingbie, "index"), T = ve(l.zimu, "index"), I, N;
    return g.includes(".htm") ? (I = ZZt(await e5(n, e9.site, `${e9.site}${g}`)), N = 960) : g === "list" ? (I = QZt(await e5(n, e9.site, `${e9.site}/list/top.html`)), N = 960) : g === e9.playlistTid || g === "albumlist" ? (I = YZt(await e5(n, e9.site, `${e9.site}/${g}/${encodeURIComponent(y)}/${d}.html`)), N = 30) : g === "singerlist" ? (I = S10(await e5(n, e9.site, `${e9.site}/singerlist/${encodeURIComponent(v)}/${encodeURIComponent(w)}/${encodeURIComponent(T)}/${d}.html`)), N = 96) : (I = S10(await e5(n, e9.site, `${e9.site}/djlist/${encodeURIComponent(g)}/${d}.html`)), N = 20), Me({ page: d, pagecount: I.length < N ? d : d + 1, limit: N, total: 0, list: I });
  }, async detail(s) {
    let c = ve(Array.isArray(s.body?.id) ? s.body.id[0] : s.body?.id);
    if (!c) throw new Error(`${Wn(n.remoteWexConfig)}\u53C2\u6570\u4E3A\u7A7A`);
    if (c.includes("|||")) return l0([JZt(c, n.remoteWexConfig)]);
    let l = await e5(n, e9.site, `${e9.site}${c}`), d = [];
    return l("div.play_list > ul > li").each((m, g) => {
      let y = l(g).find("div > a").first(), v = y.text().trim(), w = ve(y.attr("href"));
      v && w && d.push(`${v}$${w}`);
    }), l0([b0({ id: c, name: l("div.list_r > h1").text().trim(), vod_play_from: d.length ? Wn(n.remoteWexConfig) : "", vod_play_url: d.join("#") })]);
  }, async play(s) {
    let c = ve(s.body?.id), l = sKt(c), d = await eKt(n, e9, l), m = ve(d.url);
    if (m && !/^https?:\/\//i.test(m) && (m = `https:${m}`), !m) throw new Error(`${Wn(n.remoteWexConfig)}\u64AD\u653E\u5730\u5740\u4E3A\u7A7A`);
    let g = await tKt(n, e9, { cid: ve(d.lkid || d.wyid, l), directLrc: ve(d.lrc), baseUrl: xKt(s) });
    return E0({ parse: 0, url: m, header: iKt(n, e9), lyric: g, extra: { danmaku: "", nodanmu: true } });
  }, async lrcproxy(s, c) {
    let l = ve(s.params?.token).replace(/\.lrc$/i, "");
    return nKt(n, l, c);
  }, async search(s) {
    let c = s.body || {}, l = ve(c.wd || c.key), d = en(c.page || c.pg || 1), m = await e5(n, e9.site, `${e9.site}/so/${encodeURIComponent(l)}/${d}.html`);
    return { list: KZt(m) };
  } };
}
function YZt(e9) {
  let t = [];
  return e9("div.video_list > ul > li").each((n, s) => {
    let c = e9(s), l = c.find("div.name > a").first(), d = c.find("div.pic > a > img").first(), m = ve(l.attr("title"), l.text().trim()), g = ve(l.attr("href")), y = ve(d.attr("src"));
    g && m && y && t.push(u0({ id: g, name: m, pic: y, style: { type: "rect", ratio: 1 } }));
  }), t;
}
function S10(e9) {
  let t = [];
  return e9("div.singer_list > ul > li").each((n, s) => {
    let c = e9(s), l = c.find("div.name > a").first(), d = c.find("div.pic > a > img").first(), m = ve(l.attr("title"), l.text().trim()), g = ve(l.attr("href")), y = ve(d.attr("src"));
    g && m && y && t.push(u0({ id: g, name: m, pic: y }));
  }), t;
}
function QZt(e9) {
  let t = [];
  return e9("div.ilingku_fl > li").each((n, s) => {
    let c = e9(s).find("a").first(), l = c.text().trim(), d = ve(c.attr("href"));
    d && l && t.push(u0({ id: d, name: l, pic: "", style: { type: "oval" } }));
  }), t;
}
function ZZt(e9) {
  let t = [];
  return e9("div.play_list > ul > li").each((n, s) => {
    let c = e9(s).find("div > a").first(), l = c.text().trim(), d = ve(c.attr("href"));
    l && d && t.push(u0({ id: `${I10(l)}|||${d}`, name: l, pic: "", style: { type: "list" } }));
  }), t;
}
function KZt(e9) {
  let t = [];
  return e9("div.play_list > ul > li").each((n, s) => {
    let c = e9(s), l = c.find("div.name > a").first();
    l.length || (l = c.find("div > a").first());
    let d = l.text().trim(), m = ve(l.attr("href"));
    d && m && t.push(u0({ id: `${I10(d)}|||${m}`, name: d, pic: "" }));
  }), t;
}
function JZt(e9, t) {
  let n = e9.split("|||"), s = cKt(n[0] || ""), c = n[1] || e9;
  return b0({ id: c, name: s, vod_play_from: Wn(t), vod_play_url: `${s}$${c}` });
}
async function XZt(e9, t) {
  let n = await t0.get(t, { headers: Q_(e9, t), responseType: "text", transformResponse: [(c) => c], timeout: 2e4, validateStatus: () => true });
  e9.cookie = aKt(n.headers?.["set-cookie"]);
  let s = oKt(n.data);
  if (s) {
    let c = new URLSearchParams();
    c.set("human_check", "on"), c.set("csrf_token", s), await t0.post(t, c.toString(), { headers: Q_(e9, t, { "Content-Type": "application/x-www-form-urlencoded; charset=UTF-8" }), timeout: 2e4, validateStatus: () => true });
  }
}
async function e5(e9, t, n) {
  let s = await t0.get(n, { headers: Q_(e9, t), responseType: "text", transformResponse: [(c) => c], timeout: 2e4 });
  return Pr(String(s.data || ""));
}
async function eKt(e9, t, n) {
  let s = new URLSearchParams();
  for (let [l, d] of Object.entries(t.playBody(n))) s.set(l, d);
  let c = await t0.post(`${t.site}${t.playPath}`, s.toString(), { headers: Q_(e9, t.site, { "Content-Type": "application/x-www-form-urlencoded; charset=UTF-8" }), responseType: "text", transformResponse: [(l) => l], timeout: 2e4 });
  return ul(c.data, {});
}
async function tKt(e9, t, n = {}) {
  let s = ve(n.cid);
  try {
    let c = ve(n.directLrc).trim() || await rKt(e9, t, s);
    if (!c) return;
    T10(e9);
    let l = E10.default.createHash("md5").update(`${t.key}:${s}:${Date.now()}:${Math.random()}`).digest("hex");
    return e9.lrcCache.set(l, { text: c, createdAt: Date.now(), lastAccess: Date.now() }), `${n.baseUrl}/spider/${encodeURIComponent(t.key)}/3/lrcproxy/${l}.lrc`;
  } catch {
    return;
  }
}
async function rKt(e9, t, n) {
  if (typeof t.lyricUrl != "function" || !n) return "";
  let s = await t0.get(t.lyricUrl(n), { headers: Q_(e9, t.site), responseType: "text", transformResponse: [(l) => l], timeout: 2e4 }), c = ul(s.data, {});
  return ve(c?.lrc).trim();
}
function nKt(e9, t, n) {
  T10(e9);
  let s = e9.lrcCache.get(t);
  return s ? (s.lastAccess = Date.now(), n.header("cache-control", "no-store"), n.type("text/plain; charset=utf-8"), s.text) : (n.code(404), "\u6B4C\u8BCD\u5DF2\u8FC7\u671F");
}
function T10(e9) {
  let t = Date.now(), n = 1800 * 1e3;
  for (let [c, l] of e9.lrcCache.entries()) t - l.lastAccess > n && e9.lrcCache.delete(c);
  if (e9.lrcCache.size <= 128) return;
  let s = [...e9.lrcCache.entries()].sort((c, l) => c[1].lastAccess - l[1].lastAccess);
  for (let [c] of s.slice(0, e9.lrcCache.size - 128)) e9.lrcCache.delete(c);
}
function Q_(e9, t, n = {}) {
  return Pd({ Cookie: e9.cookie || "", referer: t, ...n });
}
function iKt(e9, t) {
  return typeof t.playHeader == "function" ? t.playHeader(e9) : Q_(e9, t.site);
}
function aKt(e9) {
  return Array.isArray(e9) ? e9.map((t) => String(t).split(";")[0]).join("; ") : String(e9 || "").split(";")[0];
}
function oKt(e9) {
  return /name="csrf_token"\s+value="([0-9a-f]{32})"/.exec(String(e9 || ""))?.[1] || "";
}
function sKt(e9) {
  let t = ve(e9).trim();
  return /.*\/([^.]+)\..*/.exec(t)?.[1] || /.*\/([^/]+)/.exec(t)?.[1] || t;
}
function xKt(e9 = {}) {
  let t = e9.headers?.["x-forwarded-proto"] || "http", n = e9.headers?.host || "127.0.0.1:9988";
  return `${t}://${n}`;
}
function I10(e9) {
  return Buffer.from(String(e9 || ""), "utf8").toString("base64");
}
function cKt(e9) {
  try {
    return Buffer.from(String(e9 || ""), "base64").toString("utf8");
  } catch {
    return "";
  }
}
function R10(e9 = {}) {
  return Vz({ key: "musicaikuwo", name: "\u9177\u542C|\u97F3\u4E50", site: "https://www.45hk.com", playlistTid: "playtype", playPath: "/js/play.php", playHeader() {
    return { "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36" };
  }, playBody(t) {
    return { id: t, type: "music" };
  }, lyricUrl(t) {
    return `https://js.eev3.com/lrc.php?cid=${encodeURIComponent(t)}`;
  } }, e9);
}
var N10 = C0(referenceBuiltin3, 1);
var upe = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36";
var uKt = "Mozilla/5.0 (Linux; Android 10)";
var lKt = [["1", "\u534E\u8BED\u7537"], ["2", "\u534E\u8BED\u5973"], ["3", "\u534E\u8BED\u7EC4\u5408"], ["4", "\u65E5\u97E9\u7537"], ["5", "\u65E5\u97E9\u5973"], ["6", "\u65E5\u97E9\u7EC4\u5408"], ["7", "\u6B27\u7F8E\u7537"], ["8", "\u6B27\u7F8E\u5973"], ["9", "\u6B27\u7F8E\u7EC4\u5408"], ["0", "\u5176\u4ED6"]];
function O10(e9 = {}) {
  let t = e9.remoteWexConfig, n = /* @__PURE__ */ new Map(), s = { key: "musicaikuwoa", name: "\u5C0F\u9177|\u97F3\u4E50", type: 3, \u7C7B\u578B: "\u97F3\u4E50" };
  return { meta: s, async init() {
    return {};
  }, async home() {
    return P0(lKt.map(([c, l]) => ({ type_id: c, type_name: l })), {});
  }, async homeVod() {
    return this.category({ body: { id: "1", page: 1 } });
  }, async category(c) {
    let l = c.body || {}, d = en(l.page || l.pg || 1), m = ve(l.extend?.cateId || l.id || l.tid, "1"), g = `http://wapi.kuwo.cn/api/www/artist/artistInfo?category=${k7(m)}&prefix=&pn=${k7(d)}&rn=30`, y = await Z_(g, jz()), w = (Array.isArray(y?.data?.artistList) ? y.data.artistList : []).map((T) => u0({ id: T?.id, name: T?.name, pic: cpe(T?.pic300, T?.pic, T?.pic120) })).filter((T) => T.vod_id && T.vod_name);
    return Me({ page: d, pagecount: Number.MAX_SAFE_INTEGER, limit: 30, total: Number.MAX_SAFE_INTEGER, list: w });
  }, async detail(c) {
    let l = ve(Array.isArray(c.body?.id) ? c.body.id[0] : c.body?.id);
    if (!l) throw new Error("\u7F3A\u5C11\u6B4C\u624BID");
    let m = (await Z_(`http://wapi.kuwo.cn/api/www/artist/artist?artistid=${k7(l)}`, jz()))?.data || {}, g = ve(m.name, l), y = await hKt(l), v = y.map((I) => {
      let N = C10(I?.name), C = ve(I?.rid), B = C10(I?.album);
      return !N || !C ? "" : `${B ? `${N} - ${B}` : N}$${C}`;
    }).filter(Boolean), w = AKt(ve(m.info)).replace(/&nbsp;/g, " ").replace(/\r\n/g, `
`).replace(/\r/g, `
`).trim(), T = b0({ id: l, name: g, pic: cpe(m.pic300, m.pic), content: w || "\u6682\u65E0\u6B4C\u624B\u7B80\u4ECB", actor: g, vod_play_from: v.length ? Wn(t) : "", vod_play_url: v.join("#") });
    return T.vod_remarks = `\u6B4C\u66F2 : ${y.length}\u9996`, l0([T]);
  }, async play(c) {
    let l = ve(c.body?.id);
    if (!l) throw new Error("\u7F3A\u5C11\u6B4C\u66F2ID");
    let d = [];
    await xpe(d, "\u65E0\u635FFLAC", l, 2e3, "flac"), await xpe(d, "\u9AD8\u54C1\u8D28320K", l, 320, "mp3"), await xpe(d, "\u6807\u51C6128K", l, 128, "mp3");
    let m = await fKt(n, l, yKt(c), s.key);
    return E0({ parse: 0, url: d.length ? d : "", header: bKt(), lyric: m, extra: { danmaku: "", nodanmu: true } });
  }, async proxy(c, l) {
    return l.code(404), { error: "unsupported music proxy" };
  }, async lrcproxy(c, l) {
    let d = ve(c.params?.token).replace(/\.lrc$/i, "");
    return dKt(n, d, l);
  }, async search(c) {
    let l = c.body || {}, d = ve(l.wd || l.key), m = en(l.page || l.pg || 1), y = `https://search.kuwo.cn/r.s?client=kt&pn=${Math.max(0, m - 1) * 30}&rn=30&all=${k7(d)}&vipver=1&ft=artist&encoding=utf8&rformat=json&mobi=1`, v = await Z_(y, jz()), w = Array.isArray(v?.abslist) ? v.abslist : [], T = ve(v?.BASEPICPATH, "http://img1.kuwo.cn/star/starheads/"), I = w.map((N) => {
      let C = ve(N?.hts_PICPATH);
      return !C && N?.PICPATH && (C = `${T}${N.PICPATH}`), u0({ id: cpe(N?.ARTISTID, N?.DC_TARGETID), name: N?.ARTIST, pic: C, remarks: `\u6B4C\u66F2 : ${Number.parseInt(N?.SONGNUM, 10) || 0}\u9996` });
    }).filter((N) => N.vod_id && N.vod_name);
    return Me({ page: m, pagecount: Number.MAX_SAFE_INTEGER, limit: 30, total: Number.MAX_SAFE_INTEGER, list: I });
  } };
}
async function fKt(e9, t, n, s) {
  try {
    let c = await pKt(t);
    if (!c) return;
    D10(e9);
    let l = N10.default.createHash("md5").update(`${t}:${Date.now()}:${Math.random()}`).digest("hex");
    return e9.set(l, { text: c, createdAt: Date.now(), lastAccess: Date.now() }), `${n}/spider/${encodeURIComponent(s)}/3/lrcproxy/${l}.lrc`;
  } catch {
    return;
  }
}
function dKt(e9, t, n) {
  D10(e9);
  let s = e9.get(t);
  return s ? (s.lastAccess = Date.now(), n.header("cache-control", "no-store"), n.type("text/plain; charset=utf-8"), s.text) : (n.code(404), "\u6B4C\u8BCD\u5DF2\u8FC7\u671F");
}
async function pKt(e9) {
  let t = await Z_(`https://kuwo.cn/openapi/v1/www/lyric/getlyric?musicId=${k7(e9)}`, { "User-Agent": upe, Referer: "https://www.kuwo.cn/" });
  return (Array.isArray(t?.data?.lrclist) ? t.data.lrclist : []).map((s) => {
    let c = ve(s?.lineLyric);
    return c ? `[${mKt(Number(s?.time || 0))}]${c}` : "";
  }).filter(Boolean).join(`
`);
}
function D10(e9) {
  let t = Date.now(), n = 1800 * 1e3;
  for (let [c, l] of e9.entries()) t - l.lastAccess > n && e9.delete(c);
  if (e9.size <= 128) return;
  let s = [...e9.entries()].sort((c, l) => c[1].lastAccess - l[1].lastAccess);
  for (let [c] of s.slice(0, e9.size - 128)) e9.delete(c);
}
function mKt(e9) {
  let t = Number.isFinite(e9) && e9 > 0 ? e9 : 0, n = Math.floor(t / 60), s = t - n * 60;
  return `${String(n).padStart(2, "0")}:${s.toFixed(2).padStart(5, "0")}`;
}
async function hKt(e9) {
  let t = [];
  for (let n = 1; n <= 10 && t.length < 300; n++) try {
    let s = `http://wapi.kuwo.cn/api/www/artist/artistMusic?artistid=${k7(e9)}&pn=${n}&rn=30`, c = await Z_(s, jz());
    if (Number(c?.code) !== 200) continue;
    let l = Array.isArray(c?.data?.list) ? c.data.list : [];
    if (!l.length) break;
    for (let d of l) {
      if (t.length >= 300) break;
      d?.name && t.push(d);
    }
  } catch {
  }
  return t;
}
async function xpe(e9, t, n, s, c) {
  try {
    let l = `https://nmobi.kuwo.cn/mobi.s?f=web&user=0&source=kwplayer_ar_4.4.2.7_B_nuoweida_vh.apk&type=convert_url_with_sign&rid=${k7(n)}&bitrate=${s}&format=${k7(c)}`, d = await Z_(l, gKt()), m = ve(d?.data?.url);
    Number(d?.code) === 200 && m && e9.push(t, m);
  } catch {
  }
}
async function Z_(e9, t) {
  return (await t0.get(e9, { headers: t, responseType: "json", timeout: 2e4 })).data || {};
}
function jz() {
  return { "User-Agent": upe, Referer: "http://www.kuwo.cn/" };
}
function gKt() {
  return { "User-Agent": uKt, Referer: "https://www.kuwo.cn/" };
}
function bKt() {
  return { "User-Agent": upe, Referer: "https://www.kuwo.cn/" };
}
function yKt(e9 = {}) {
  let t = e9.headers?.["x-forwarded-proto"] || "http", n = e9.headers?.host || "127.0.0.1:9988";
  return `${t}://${n}`;
}
function C10(e9) {
  return ve(e9).replace(/\$/g, "").replace(/#/g, "").trim();
}
function cpe(...e9) {
  for (let t of e9) {
    let n = ve(t).trim();
    if (n) return n;
  }
  return "";
}
function k7(e9) {
  return encodeURIComponent(ve(e9)).replace(/\+/g, "%20");
}
function AKt(e9) {
  return ve(e9).replace(/<[^>]+>/g, "");
}
var L10 = C0(referenceBuiltin3, 1);
var kKt = "http://mobilecdnbj.kugou.com/api/v3/rank/list?version=9108&plat=0&showtype=2&parentid=0&apiver=6&area_code=1&withsong=0&with_res_tag=0";
var vKt = "https://songsearch.kugou.com/song_search_v2";
var _Kt = "http://msearch.kugou.com/api/v3/search/album";
var wKt = "http://mobilecdn.kugou.com/api/v3/album/song";
var SKt = "http://mobilecdn.kugou.com/api/v3/search/special";
var EKt = "http://mobilecdn.kugou.com/api/v3/special/info";
var TKt = "http://mobilecdn.kugou.com/api/v3/special/song";
var IKt = "https://music.haitangw.cc/kgqq1/kg.php";
var RKt = "https://musicapi.haitangw.net/music/kg_song_kw.php";
var CKt = "http://mcp.nianxinxz.com/share/ceshi/kg.php";
var NKt = "http://lyrics.kugou.com/search";
var OKt = "http://lyrics.kugou.com/download";
var P1 = 30;
var VN = 10;
var ppe = 100;
var lpe = 2e3;
var mpe = 30;
var hpe = 100;
var fpe = 2e3;
var DKt = "\u70ED\u6B4C";
var P10 = { type_id: "sheet", type_name: "\u6B4C\u5355" };
var dpe = { type_id: "rank", type_name: "\u699C\u5355" };
var gpe = 100;
var Gz = 2e3;
var bpe = [{ type_id: "8888", type_name: "TOP500" }, { type_id: "6666", type_name: "\u98D9\u5347\u699C" }, { type_id: "23784", type_name: "\u70ED\u6B4C\u699C" }, { type_id: "31308", type_name: "\u65B0\u6B4C\u699C" }, { type_id: "22603", type_name: "\u7F51\u7EDC\u7EA2\u6B4C\u699C" }, { type_id: "33160", type_name: "DJ\u70ED\u6B4C\u699C" }, { type_id: "33161", type_name: "\u5F71\u89C6\u91D1\u66F2\u699C" }];
var PKt = [{ name: "HiRes", level: "hires", pick: ["HiFileHash", "high_hash"] }, { name: "\u65E0\u635FFLAC", level: "lossless", pick: ["SQFileHash", "sqhash"] }, { name: "\u9AD8\u54C1\u8D28320K", level: "exhigh", pick: ["HQFileHash", "FileHash", "320hash", "hash"] }, { name: "\u6807\u51C6128K", level: "standard", pick: ["FileHash", "hash"] }];
function M10(e9 = {}) {
  let t = e9.remoteWexConfig, n = /* @__PURE__ */ new Map(), s = { key: "musicaikg", name: "\u5C0F\u72D7|\u97F3\u4E50", type: 3, \u7C7B\u578B: "\u97F3\u4E50" };
  return { meta: s, async init() {
    return {};
  }, async home() {
    return P0([P10, dpe], {});
  }, async homeVod() {
    return this.category({ body: { id: dpe.type_id, page: 1 } });
  }, async category(c) {
    let l = c.body || {}, d = en(l.page || l.pg || 1), m = ve(l.extend?.rankId || l.id || l.tid, "8888");
    if (m === P10.type_id) {
      let y = ve(l.extend?.keyword || l.wd || l.key, DKt), v = await $10(y, d);
      return po(Me({ page: d, pagecount: v.length < mpe ? d : d + 1, limit: mpe, total: 0, list: v }), c, "https://www.kugou.com/");
    }
    if (m === dpe.type_id) {
      let y = await BKt(), v = (d - 1) * P1, w = y.slice(v, v + P1).map(GKt).filter(Boolean);
      return po(Me({ page: d, pagecount: v + P1 >= y.length ? d : d + 1, limit: P1, total: y.length, list: w }), c, "https://www.kugou.com/");
    }
    let g = await LKt(m, d);
    return po(Me({ page: d, pagecount: g.length < P1 ? d : d + 1, limit: P1, total: 0, list: g }), c, "https://www.kugou.com/");
  }, async detail(c) {
    let l = ve(Array.isArray(c.body?.id) ? c.body.id[0] : c.body?.id);
    if (!l) throw new Error("\u7F3A\u5C11\u6B4C\u66F2\u53C2\u6570");
    let d = V10(l);
    if (d.type === "sheet") return po(l0([await qKt(d, t)]), c, "https://www.kugou.com/");
    if (d.type === "rank") return po(l0([await zKt(d, t)]), c, "https://www.kugou.com/");
    if (d.type === "album") return po(l0([await HKt(d, t)]), c, "https://www.kugou.com/");
    let m = j10(d.song || d), g = K_(m), y = m.hash ? [`${g}$${Bd({ type: "song", song: m })}`] : [], v = b0({ id: l, name: g, pic: Xm(m), actor: ve(m.singer), content: ve(m.album, g), vod_play_from: y.length ? Wn(t) : "", vod_play_url: y.join("#") });
    return v.vod_remarks = ve(m.remark || m.album), po(l0([v]), c, "https://www.kugou.com/");
  }, async play(c) {
    let l = cJt(ve(c.body?.id)), d = await iJt(l);
    if (!d.length) throw new Error("\u9177\u72D7\u64AD\u653E\u5730\u5740\u4E3A\u7A7A");
    let m = await aJt(n, l, fJt(c), s.key);
    return E0({ parse: 0, url: d, header: lJt(), lyric: m, extra: { danmaku: "", nodanmu: true } });
  }, async lrcproxy(c, l) {
    let d = ve(c.params?.token).replace(/\.lrc$/i, "");
    return sJt(n, d, l);
  }, async search(c) {
    let l = c.body || {}, d = ve(l.wd || l.key), m = en(l.page || l.pg || 1), g = await UKt(d, m);
    return po(Me({ page: m, pagecount: g.length < P1 ? m : m + 1, limit: P1, total: 0, list: g }), c, "https://www.kugou.com/");
  } };
}
async function BKt() {
  try {
    let e9 = await uf(kKt, lf()), t = Array.isArray(e9?.data?.info) ? e9.data.info : [], n = [];
    for (let s of t) U10(s, n);
    return n.length ? n : bpe.map((s) => ({ id: s.type_id, name: s.type_name }));
  } catch {
    return bpe.map((e9) => ({ id: e9.type_id, name: e9.type_name }));
  }
}
function U10(e9, t) {
  let n = ve(e9?.rankid), s = Vn(e9?.rankname || e9?.name);
  n && s && t.push({ id: n, name: s, pic: ve(e9?.imgurl), content: Vn(e9?.intro) });
  let c = Array.isArray(e9?.children) ? e9.children : Array.isArray(e9?.child) ? e9.child : [];
  for (let l of c) U10(l, t);
}
async function LKt(e9, t) {
  let n = `http://mobilecdnbj.kugou.com/api/v3/rank/song?version=9108&ranktype=0&plat=0&pagesize=${P1}&area_code=1&page=${Hz(t)}&volid=35050&rankid=${Hz(e9)}&with_res_tag=0`, s = await uf(n, lf());
  return (Array.isArray(s?.data?.info) ? s.data.info : []).map((l) => WKt(l, { rankId: e9, page: t })).filter(Boolean);
}
async function MKt(e9, t) {
  if (!e9) return [];
  let n = { keyword: e9, page: t, pagesize: P1, userid: "-1", clientver: "", platform: "WebFilter", tag: "em", filter: "2", iscorrection: "1", privilege_filter: "0" }, s = await uf(vKt, lf(), { params: n });
  return (Array.isArray(s?.data?.lists) ? s.data.lists : []).map(FKt).filter(Boolean).sort((l, d) => B10(d, e9) - B10(l, e9));
}
async function UKt(e9, t) {
  if (!e9) return [];
  let [n, s, c] = await Promise.all([MKt(e9, t).catch(() => []), $Kt(e9, t).catch(() => []), $10(e9, t, VN).catch(() => [])]);
  return [...n.slice(0, VN), ...s.slice(0, VN), ...c.slice(0, VN)];
}
async function $Kt(e9, t) {
  let n = await uf(_Kt, lf(), { params: { version: 9108, iscorrection: 1, highlight: "em", plat: 0, keyword: e9, pagesize: VN, page: t, sver: 2, with_res_tag: 0 } });
  return (Array.isArray(n?.data?.info) ? n.data.info : []).map(jKt).filter(Boolean);
}
async function $10(e9, t, n = mpe) {
  let s = await uf(SKt, lf(), { params: { format: "json", keyword: e9, page: t, pagesize: n, showtype: 1 } });
  return (Array.isArray(s?.data?.info) ? s.data.info : []).map(VKt).filter(Boolean);
}
function FKt(e9) {
  let t = tJt(e9);
  return !t.title || !t.hash ? null : u0({ id: Bd({ type: "song", song: t }), name: K_(t), pic: Xm(t), remarks: t.remark, style: { type: "list" } });
}
function WKt(e9, t = {}) {
  let n = ype(e9);
  return !n.title || !n.hash ? null : u0({ id: Bd({ type: "rank", rankId: t.rankId, page: t.page, song: n }), name: K_(n), pic: Xm(n), remarks: n.remark, style: { type: "list" } });
}
function VKt(e9) {
  let t = ve(e9?.specialid), n = Vn(e9?.specialname);
  return !t || !n ? null : u0({ id: Bd({ type: "sheet", sheetId: t, page: 1, name: n, pic: ve(e9?.imgurl), author: Vn(e9?.nickname), content: Vn(e9?.intro), count: en(e9?.songcount, 0) }), name: n, pic: Xm({ cover: e9?.imgurl }), remarks: `${en(e9?.songcount, 0)}\u9996` });
}
function jKt(e9) {
  let t = ve(e9?.albumid || e9?.album_id), n = Vn(e9?.albumname || e9?.album_name);
  return !t || !n ? null : u0({ id: Bd({ type: "album", albumId: t, name: n, pic: ve(e9?.imgurl), author: Vn(e9?.singername), content: Vn(e9?.intro), date: ve(e9?.publishtime).slice(0, 10) }), name: n, pic: Xm({ cover: e9?.imgurl }), remarks: Vn(e9?.singername) ? `\u4E13\u8F91 \xB7 ${Vn(e9.singername)}` : "\u4E13\u8F91" });
}
function GKt(e9) {
  let t = ve(e9?.id), n = Vn(e9?.name);
  return !t || !n ? null : u0({ id: Bd({ type: "rank", rankId: t, name: n, pic: ve(e9?.pic), content: Vn(e9?.content) }), name: n, pic: Xm({ cover: e9?.pic }), remarks: "\u699C\u5355" });
}
async function HKt(e9, t) {
  let n = ve(e9.albumId), s = await JKt(n, e9), c = Vn(e9.name || `\u4E13\u8F91${n}`);
  return b0({ id: Bd({ type: "album", albumId: n, name: c }), name: c, pic: Xm({ cover: e9.pic }), actor: Vn(e9.author), content: Vn(e9.content || e9.date), vod_play_from: s.length ? Wn(t) : "", vod_play_url: s.map((l) => `${K_(l)}$${Bd({ type: "song", song: l })}`).join("#") });
}
async function qKt(e9, t) {
  let n = ve(e9.sheetId), [s, c] = await Promise.all([YKt(n), ZKt(n)]), l = Vn(s?.specialname || e9.name || `\u6B4C\u5355${n}`);
  return b0({ id: Bd({ ...e9, sheetId: n }), name: l, pic: Xm({ cover: s?.imgurl || e9.pic }), actor: Vn(s?.nickname || e9.author), content: Vn(s?.intro || e9.content), vod_play_from: c.length ? Wn(t) : "", vod_play_url: c.map((d) => `${K_(d)}$${Bd({ type: "song", song: d })}`).join("#") });
}
async function zKt(e9, t) {
  let n = ve(e9.rankId, "8888"), s = await eJt(n), c = Vn(e9.name || uJt(n) || "\u699C\u5355");
  return b0({ id: Bd({ type: "rank", rankId: n, name: c }), name: c, pic: Xm({ cover: e9.pic }), actor: c, content: Vn(e9.content || `\u6700\u591A\u52A0\u8F7D${Gz}\u9996`), vod_play_from: s.length ? Wn(t) : "", vod_play_url: s.map((l) => `${K_(l)}$${Bd({ type: "song", song: l })}`).join("#") });
}
async function YKt(e9) {
  return (await uf(EKt, lf(), { params: { format: "json", specialid: e9 } }))?.data || {};
}
async function QKt(e9, t) {
  let n = await uf(TKt, lf(), { params: { format: "json", specialid: e9, page: t, pagesize: hpe } });
  return (Array.isArray(n?.data?.info) ? n.data.info : []).map(ype).filter((c) => c.title && c.hash);
}
async function ZKt(e9) {
  let t = [], n = /* @__PURE__ */ new Set(), s = Math.ceil(fpe / hpe);
  for (let c = 1; c <= s && t.length < fpe; c++) {
    let l = await QKt(e9, c);
    if (!l.length) break;
    for (let d of l) if (!(!d.title || !d.hash || n.has(d.hash)) && (n.add(d.hash), t.push(d), t.length >= fpe)) break;
    if (l.length < hpe) break;
  }
  return t;
}
async function KKt(e9, t) {
  let n = await uf(wKt, lf(), { params: { version: 9108, albumid: e9, plat: 0, pagesize: ppe, area_code: 1, page: t, with_res_tag: 0 } });
  return Array.isArray(n?.data?.info) ? n.data.info : [];
}
async function JKt(e9, t = {}) {
  let n = [], s = /* @__PURE__ */ new Set(), c = Math.ceil(lpe / ppe);
  for (let l = 1; l <= c && n.length < lpe; l++) {
    let d = await KKt(e9, l);
    if (!d.length) break;
    for (let m of d) {
      let g = rJt(m, t);
      if (!(!g.title || !g.hash || s.has(g.hash)) && (s.add(g.hash), n.push(g), n.length >= lpe)) break;
    }
    if (d.length < ppe) break;
  }
  return n;
}
async function XKt(e9, t) {
  let n = `http://mobilecdnbj.kugou.com/api/v3/rank/song?version=9108&ranktype=0&plat=0&pagesize=${gpe}&area_code=1&page=${Hz(t)}&volid=35050&rankid=${Hz(e9)}&with_res_tag=0`, s = await uf(n, lf());
  return Array.isArray(s?.data?.info) ? s.data.info : [];
}
async function eJt(e9) {
  let t = [], n = /* @__PURE__ */ new Set(), s = Math.ceil(Gz / gpe);
  for (let c = 1; c <= s && t.length < Gz; c++) {
    let l = await XKt(e9, c);
    if (!l.length) break;
    for (let d of l) {
      let m = ype(d);
      if (!(!m.title || !m.hash || n.has(m.hash)) && (n.add(m.hash), t.push(m), t.length >= Gz)) break;
    }
    if (l.length < gpe) break;
  }
  return t;
}
function tJt(e9 = {}) {
  return { title: Vn(e9.SongName || e9.songname || e9.FileName), singer: Vn(e9.SingerName || e9.singername), album: Vn(e9.AlbumName || e9.album_name), duration: en(e9.Duration || e9.duration, 0), hash: ve(e9.FileHash || e9.hash), HQFileHash: ve(e9.HQFileHash || e9["320hash"]), SQFileHash: ve(e9.SQFileHash || e9.sqhash), HiFileHash: ve(e9.HiFileHash || e9.ResFileHash), cover: ve(e9.Image || e9.AlbumPrivilege?.Image), albumId: ve(e9.AlbumID || e9.album_id), remark: Vn(e9.AlbumName || e9.album_name || e9.SingerName) };
}
function ype(e9 = {}) {
  let t = Vn(e9.songname || e9.filename), n = Vn(e9.singername || F10(e9.filename).singer);
  return { title: t, singer: n, album: Vn(e9.album_name), duration: en(e9.duration, 0), hash: ve(e9.hash), HQFileHash: ve(e9["320hash"] || e9.hqhash), SQFileHash: ve(e9.sqhash), HiFileHash: ve(e9.high_hash || e9.HiFileHash), cover: ve(e9.album_sizable_cover || e9.sizable_cover || e9.imgurl), albumId: ve(e9.album_id), remark: n || Vn(e9.album_name) };
}
function rJt(e9 = {}, t = {}) {
  let n = F10(e9.filename);
  return { title: Vn(e9.songname || n.title), singer: Vn(e9.singername || n.singer || t.author), album: Vn(e9.album_name || t.name), duration: en(e9.duration, 0), hash: ve(e9.hash), HQFileHash: ve(e9.HQFileHash || e9["320hash"] || e9.hqhash), SQFileHash: ve(e9.SQFileHash || e9.sqhash), HiFileHash: ve(e9.high_hash || e9.HiFileHash), cover: ve(e9.album_sizable_cover || e9.sizable_cover || e9.imgurl || t.pic), albumId: ve(e9.album_id || t.albumId), remark: Vn(e9.album_name || t.name) };
}
function F10(e9) {
  let t = Vn(e9), n = t.split(/\s+-\s+/);
  return n.length < 2 ? { singer: "", title: t } : { singer: n[0], title: n.slice(1).join(" - ") };
}
async function nJt(e9, t) {
  let n = await uf(RKt, lf(), { params: { id: e9, type: "json", level: t } }).catch(() => null);
  if (ve(n?.data?.url || n?.url)) return n;
  let s = await uf(IKt, lf(), { params: { id: e9, type: "json", level: t } }).catch(() => null);
  return ve(s?.data?.url || s?.url) ? s : { url: `${CKt}?id=${encodeURIComponent(e9)}&level=${encodeURIComponent(t)}&type=mp3` };
}
async function iJt(e9) {
  let t = [], n = /* @__PURE__ */ new Set();
  for (let s of PKt) {
    let c = xJt(e9, s);
    if (!c) continue;
    let l = s.level, d = `${c}:${l}`;
    if (!n.has(d)) {
      n.add(d);
      try {
        let m = await nJt(c, l), g = ve(m?.data?.url || m?.url);
        g && t.push(s.name, g);
      } catch {
      }
    }
  }
  return t;
}
async function aJt(e9, t, n, s) {
  try {
    let c = await oJt(t);
    if (!c) return;
    W10(e9);
    let l = L10.default.createHash("md5").update(`${s}:${t.hash}:${Date.now()}:${Math.random()}`).digest("hex");
    return e9.set(l, { text: c, createdAt: Date.now(), lastAccess: Date.now() }), `${n}/spider/${encodeURIComponent(s)}/3/lrcproxy/${l}.lrc`;
  } catch {
    return;
  }
}
async function oJt(e9) {
  let t = [e9.singer, e9.title].filter(Boolean).join(" - ") || e9.title, n = await uf(NKt, lf(), { params: { ver: 1, man: "yes", client: "pc", keyword: t, hash: e9.hash, timelength: Number(e9.duration || 0) * 1e3 } }), c = (Array.isArray(n?.candidates) ? n.candidates : [])[0], l = ve(c?.id), d = ve(c?.accesskey);
  if (!l || !d) return "";
  let m = await uf(OKt, lf(), { params: { ver: 1, client: "pc", id: l, accesskey: d, fmt: "lrc", charset: "utf8" } }), g = ve(m?.content);
  return g ? Buffer.from(g, "base64").toString("utf8").replace(/^\uFEFF/, "").trim() : "";
}
function sJt(e9, t, n) {
  W10(e9);
  let s = e9.get(t);
  return s ? (s.lastAccess = Date.now(), n.header("cache-control", "no-store"), n.type("text/plain; charset=utf-8"), s.text) : (n.code(404), "\u6B4C\u8BCD\u5DF2\u8FC7\u671F");
}
function W10(e9) {
  let t = Date.now(), n = 1800 * 1e3;
  for (let [c, l] of e9.entries()) t - l.lastAccess > n && e9.delete(c);
  if (e9.size <= 128) return;
  let s = [...e9.entries()].sort((c, l) => c[1].lastAccess - l[1].lastAccess);
  for (let [c] of s.slice(0, e9.size - 128)) e9.delete(c);
}
async function uf(e9, t, n = {}) {
  return (await t0.get(e9, { headers: t, responseType: "json", timeout: 2e4, ...n })).data || {};
}
function xJt(e9, t) {
  for (let n of t.pick) {
    let s = ve(e9?.[n]);
    if (s) return s;
  }
  return "";
}
function Xm(e9) {
  let t = ve(e9?.cover);
  return t ? t.replace(/\{size\}/g, "400").replace(/\{([a-z_]+)\}/gi, "400") : "";
}
function K_(e9) {
  let t = Vn(e9?.title), n = Vn(e9?.singer);
  return n && t && !t.includes(n) ? `${n} - ${t}` : t || n;
}
function Vn(e9) {
  return ve(e9).replace(/<\/?em>/gi, "").replace(/<[^>]+>/g, "").replace(/\$/g, "").replace(/#/g, "").replace(/\s+/g, " ").trim();
}
function cJt(e9) {
  let t = V10(e9);
  return j10(t.song || t);
}
function Bd(e9) {
  return Buffer.from(JSON.stringify(e9), "utf8").toString("base64url");
}
function V10(e9) {
  try {
    return JSON.parse(Buffer.from(ve(e9), "base64url").toString("utf8"));
  } catch {
    return {};
  }
}
function j10(e9 = {}) {
  return { title: Vn(e9.title), singer: Vn(e9.singer), album: Vn(e9.album), duration: en(e9.duration, 0), hash: ve(e9.hash || e9.FileHash), HQFileHash: ve(e9.HQFileHash || e9["320hash"]), SQFileHash: ve(e9.SQFileHash || e9.sqhash), HiFileHash: ve(e9.HiFileHash || e9.high_hash), cover: ve(e9.cover), albumId: ve(e9.albumId || e9.album_id), remark: Vn(e9.remark) };
}
function B10(e9, t) {
  let n = Vn(t).toLowerCase(), s = Vn(e9?.vod_name).toLowerCase();
  return n ? s === n ? 100 : s.endsWith(` - ${n}`) ? 90 : s.includes(n) ? 50 : 0 : 0;
}
function uJt(e9) {
  return bpe.find((t) => t.type_id === String(e9))?.type_name || "";
}
function lf() {
  return { "User-Agent": Y2, Referer: "https://www.kugou.com/" };
}
function lJt() {
  return { "User-Agent": Y2, Referer: "https://www.kugou.com/" };
}
function fJt(e9 = {}) {
  let t = e9.headers?.["x-forwarded-proto"] || "http", n = e9.headers?.host || "127.0.0.1:9988";
  return `${t}://${n}`;
}
function Hz(e9) {
  return encodeURIComponent(ve(e9));
}
var q10 = C0(referenceBuiltin3, 1);
var vpe = "https://u.y.qq.com/cgi-bin/musicu.fcg";
var dJt = "https://u6.y.qq.com/cgi-bin/musicu.fcg";
var pJt = "https://api.xunhuisi.store/API/QQMusic/Song.php";
var v7 = 948168827;
var z10 = "Q_H_L_5FBMRs-uicpIQo8Ymt3v0w1f0DAyJwQMdLJPVKmmOQZRQZkuz8AfB1Q";
var mJt = "Mozilla/5.0 (compatible; MSIE 9.0; Windows NT 6.1; WOW64; Trident/5.0)";
var hJt = 20;
var Ape = 10;
var t5 = 30;
var jN = 20;
var J_ = 2e3;
var kpe = 100;
var G10 = { type_id: "sheet", type_name: "\u6B4C\u5355" };
var qz = { type_id: "rank", type_name: "\u699C\u5355" };
var gJt = [{ name: "\u65E0\u635FFLAC", quality: "high", prefix: "F000", suffix: ".flac" }, { name: "\u9AD8\u54C1\u8D28320K", quality: "standard", prefix: "M800", suffix: ".mp3" }, { name: "\u6807\u51C6128K", quality: "low", prefix: "M500", suffix: ".mp3" }];
function Y10(e9 = {}) {
  let t = e9.remoteWexConfig, n = /* @__PURE__ */ new Map(), s = { key: "musicaiqq", name: "\u5C0F\u79CB|\u97F3\u4E50", type: 3, \u7C7B\u578B: "\u97F3\u4E50" };
  return { meta: s, async init() {
    return {};
  }, async home() {
    return P0([G10, qz], {});
  }, async homeVod() {
    return this.category({ body: { id: qz.type_id, page: 1 } });
  }, async category(c) {
    let l = c.body || {}, d = en(l.page || l.pg || 1), m = ve(l.extend?.cateId || l.id || l.tid, qz.type_id);
    if (m === G10.type_id) {
      let { list: g, total: y } = await OJt(d);
      return po(Me({ page: d, pagecount: y ? Math.max(1, Math.ceil(y / jN)) : g.length < jN ? d : d + 1, limit: jN, total: y, list: g }), c, "https://y.qq.com/");
    }
    if (m === qz.type_id) {
      let g = await CJt(), y = (d - 1) * t5, v = g.slice(y, y + t5).map(wJt).filter(Boolean), w = Math.max(1, Math.ceil(g.length / t5));
      return po(Me({ page: d, pagecount: w, limit: t5, total: g.length, list: v }), c, "https://y.qq.com/");
    }
    return Me({ page: d, pagecount: 1, limit: t5, total: 0, list: [] });
  }, async detail(c) {
    let l = ve(Array.isArray(c.body?.id) ? c.body.id[0] : c.body?.id);
    if (!l) throw new Error("\u7F3A\u5C11\u6B4C\u66F2\u53C2\u6570");
    let d = J10(l);
    if (d.type === "sheet") return po(l0([await EJt(d, t)]), c, "https://y.qq.com/");
    if (d.type === "rank") return po(l0([await TJt(d, t)]), c, "https://y.qq.com/");
    if (d.type === "album") return po(l0([await SJt(d, t)]), c, "https://y.qq.com/");
    let m = wpe(d.song || d), g = GN(m), y = b0({ id: l, name: g, pic: K10(m), actor: m.singer, content: m.album || g, vod_play_from: m.songmid ? Wn(t) : "", vod_play_url: m.songmid ? `${g}$${Q2({ type: "song", song: m })}` : "" });
    return y.vod_remarks = m.album || m.remark, po(l0([y]), c, "https://y.qq.com/");
  }, async play(c) {
    let l = jJt(ve(c.body?.id)), d = await DJt(l);
    if (!d.length) throw new Error("QQ\u64AD\u653E\u5730\u5740\u4E3A\u7A7A");
    let m = await FJt(n, l, HJt(c), s.key);
    return E0({ parse: 0, url: d, header: GJt(), lyric: m, extra: { danmaku: "", nodanmu: true } });
  }, async lrcproxy(c, l) {
    let d = ve(c.params?.token).replace(/\.lrc$/i, "");
    return VJt(n, d, l);
  }, async search(c) {
    let l = c.body || {}, d = ve(l.wd || l.key), m = en(l.page || l.pg || 1), g = await bJt(d, m);
    return po(Me({ page: m, pagecount: g.length < t5 ? m : m + 1, limit: t5, total: 0, list: g }), c, "https://y.qq.com/");
  } };
}
async function bJt(e9, t) {
  if (!e9) return [];
  let [n, s, c] = await Promise.all([yJt(e9, t).catch(() => []), AJt(e9, t).catch(() => []), kJt(e9, t).catch(() => [])]);
  return [...n.slice(0, Ape), ...s.slice(0, Ape), ...c.slice(0, Ape)];
}
async function _pe(e9, t, n) {
  return (await t0.post(vpe, { req_1: { method: "DoSearchForQQMusicDesktop", module: "music.search.SearchCgiService", param: { num_per_page: hJt, page_num: t, query: e9, search_type: n } } }, { headers: Tpe(), responseType: "json", timeout: 2e4 })).data?.req_1?.data?.body || {};
}
async function yJt(e9, t) {
  let n = await _pe(e9, t, 0);
  return (Array.isArray(n?.song?.list) ? n.song.list : []).map((c) => vJt(zz(c))).filter(Boolean).sort((c, l) => H10(l, e9) - H10(c, e9));
}
async function AJt(e9, t) {
  let n = await _pe(e9, t, 2);
  return (Array.isArray(n?.album?.list) ? n.album.list : []).map(_Jt).filter(Boolean);
}
async function kJt(e9, t) {
  let n = await _pe(e9, t, 3);
  return (Array.isArray(n?.songlist?.list) ? n.songlist.list : []).map(Q10).filter(Boolean);
}
function vJt(e9) {
  return !e9.title || !e9.songmid ? null : u0({ id: Q2({ type: "song", song: e9 }), name: GN(e9), pic: K10(e9), remarks: e9.album, style: { type: "list" } });
}
function _Jt(e9) {
  let t = ve(e9?.albumMID || e9?.album_mid), n = ve(e9?.albumID || e9?.albumid), s = Aa(e9?.albumName || e9?.album_name);
  if (!t && !n || !s) return null;
  let c = Aa(e9?.singerName || e9?.singer_name);
  return u0({ id: Q2({ type: "album", albumId: n, albumMID: t, name: s, pic: ve(e9?.albumPic), author: c, content: Aa(e9?.desc), date: ve(e9?.publicTime || e9?.pub_time) }), name: s, pic: Epe(t, e9?.albumPic), remarks: c ? `\u4E13\u8F91 \xB7 ${c}` : "\u4E13\u8F91" });
}
function Q10(e9) {
  let t = ve(e9?.dissid || e9?.id), n = Aa(e9?.dissname || e9?.title);
  if (!t || !n) return null;
  let s = en(e9?.song_count || e9?.worksNums || e9?.songnum, 0);
  return u0({ id: Q2({ type: "sheet", sheetId: t, name: n, pic: ve(e9?.imgurl || e9?.artwork), author: Aa(e9?.creator?.name || e9?.artist), content: Aa(e9?.introduction || e9?.description), count: s }), name: n, pic: ve(e9?.imgurl || e9?.artwork), remarks: s ? `${s}\u9996` : "\u6B4C\u5355" });
}
function wJt(e9) {
  let t = ve(e9?.id), n = Aa(e9?.name);
  return !t || !n ? null : u0({ id: Q2({ type: "rank", rankId: t, period: ve(e9.period), name: n, pic: ve(e9.pic), content: Aa(e9.content) }), name: n, pic: ve(e9.pic), remarks: "\u699C\u5355" });
}
async function SJt(e9, t) {
  let n = await IJt(e9), s = Aa(e9.name || "\u4E13\u8F91");
  return b0({ id: Q2({ type: "album", albumId: e9.albumId, albumMID: e9.albumMID, name: s }), name: s, pic: Epe(e9.albumMID, e9.pic), actor: Aa(e9.author), content: Aa(e9.content || e9.date), vod_play_from: n.length ? Wn(t) : "", vod_play_url: n.map((c) => `${GN(c)}$${Q2({ type: "song", song: c })}`).join("#") });
}
async function EJt(e9, t) {
  let n = await RJt(e9.sheetId), s = Aa(e9.name || `\u6B4C\u5355${e9.sheetId}`);
  return b0({ id: Q2({ type: "sheet", sheetId: e9.sheetId, name: s }), name: s, pic: ve(e9.pic), actor: Aa(e9.author), content: Aa(e9.content), vod_play_from: n.length ? Wn(t) : "", vod_play_url: n.map((c) => `${GN(c)}$${Q2({ type: "song", song: c })}`).join("#") });
}
async function TJt(e9, t) {
  let n = await NJt(e9.rankId, e9.period), s = Aa(e9.name || "\u699C\u5355");
  return b0({ id: Q2({ type: "rank", rankId: e9.rankId, period: e9.period, name: s }), name: s, pic: ve(e9.pic), actor: s, content: Aa(e9.content || `\u6700\u591A\u52A0\u8F7D${J_}\u9996`), vod_play_from: n.length ? Wn(t) : "", vod_play_url: n.map((c) => `${GN(c)}$${Q2({ type: "song", song: c })}`).join("#") });
}
async function IJt(e9) {
  let t = await Yz(`${vpe}?g_tk=5381&format=json&inCharset=utf8&outCharset=utf-8`, { data: JSON.stringify({ comm: { ct: 24, cv: 1e4 }, albumSonglist: { method: "GetAlbumSongList", module: "music.musichallAlbum.AlbumSongList", param: { albumMid: ve(e9.albumMID), albumID: 0, begin: 0, num: J_, order: 2 } } }) });
  return (Array.isArray(t?.albumSonglist?.data?.songList) ? t.albumSonglist.data.songList : []).slice(0, J_).map((s) => zz(s.songInfo || s)).filter((s) => s.title && s.songmid);
}
async function RJt(e9) {
  let t = await t0.get(`http://i.y.qq.com/qzone/fcg-bin/fcg_ucc_getcdinfo_byids_cp.fcg?type=1&utf8=1&disstid=${qJt(e9)}&loginUin=0`, { headers: { Referer: "https://y.qq.com/n/yqq/playlist", Cookie: "uin=" }, responseType: "text", transformResponse: [(c) => c], timeout: 2e4 }), n = Spe(t.data);
  return (Array.isArray(n?.cdlist?.[0]?.songlist) ? n.cdlist[0].songlist : []).slice(0, J_).map(zz).filter((c) => c.title && c.songmid);
}
async function CJt() {
  let e9 = await Yz("https://u.y.qq.com/cgi-bin/musicu.fcg?_=1577086820633&data=%7B%22comm%22%3A%7B%22g_tk%22%3A5381%2C%22uin%22%3A123456%2C%22format%22%3A%22json%22%2C%22inCharset%22%3A%22utf-8%22%2C%22outCharset%22%3A%22utf-8%22%2C%22notice%22%3A0%2C%22platform%22%3A%22h5%22%2C%22needNewCode%22%3A1%2C%22ct%22%3A23%2C%22cv%22%3A0%7D%2C%22topList%22%3A%7B%22module%22%3A%22musicToplist.ToplistInfoServer%22%2C%22method%22%3A%22GetAll%22%2C%22param%22%3A%7B%7D%7D%7D"), t = Array.isArray(e9?.topList?.data?.group) ? e9.topList.data.group : [], n = [];
  for (let s of t) {
    let c = Array.isArray(s?.toplist) ? s.toplist : [];
    for (let l of c) {
      let d = ve(l.topId), m = Aa(l.title);
      !d || !m || n.push({ id: d, name: m, period: ve(l.period), pic: ve(l.frontPicUrl || l.picUrl), content: Aa(l.intro) });
    }
  }
  return n;
}
async function NJt(e9, t = "") {
  let n = [], s = /* @__PURE__ */ new Set();
  for (let c = 0; c < J_; c += kpe) {
    let l = await Yz(`${vpe}?g_tk=5381`, { data: JSON.stringify({ detail: { module: "musicToplist.ToplistInfoServer", method: "GetDetail", param: { topId: Number(e9), offset: c, num: kpe, period: ve(t) } }, comm: { ct: 24, cv: 0 } }) }), d = Array.isArray(l?.detail?.data?.songInfoList) ? l.detail.data.songInfoList : [];
    if (!d.length) break;
    for (let m of d) {
      let g = zz(m);
      if (!(!g.title || !g.songmid || s.has(g.songmid)) && (s.add(g.songmid), n.push(g), n.length >= J_)) break;
    }
    if (d.length < kpe) break;
  }
  return n;
}
async function OJt(e9) {
  let t = await t0.get("https://c.y.qq.com/splcloud/fcgi-bin/fcg_get_diss_by_tag.fcg", { headers: { referer: "https://y.qq.com/" }, params: { inCharset: "utf8", outCharset: "utf-8", sortId: 5, categoryId: "10000000", sin: jN * (e9 - 1), ein: e9 * jN - 1 }, responseType: "text", transformResponse: [(c) => c], timeout: 2e4 }), n = Spe(t.data), s = Array.isArray(n?.data?.list) ? n.data.list : [];
  return { total: en(n?.data?.sum, 0), list: s.map(Q10).filter(Boolean) };
}
async function DJt(e9) {
  let t = await PJt(e9).catch(() => null);
  if (t?.url) return [BJt(t.quality), t.url];
  let n = [], s = /* @__PURE__ */ new Set();
  for (let c of gJt) try {
    let l = await LJt(e9, c);
    l && !s.has(l) && (s.add(l), n.push(c.name, l));
  } catch {
  }
  return n;
}
async function PJt(e9) {
  if (!e9.songmid) return null;
  let t = await Yz(pJt, { mid: e9.songmid }), n = ve(t?.music_url || t?.url || t?.data?.url);
  return n ? { url: n, quality: ve(t?.quality || t?.data?.quality) } : null;
}
function BJt(e9) {
  let t = ve(e9);
  return /hi-?res|hires/i.test(t) ? "HiRes" : /flac|无损/i.test(t) ? "\u65E0\u635FFLAC" : /320|高品质|m4a|aac/i.test(t) ? "\u9AD8\u54C1\u8D28AAC" : /128|标准/i.test(t) ? "\u6807\u51C6128K" : "QQ\u89E3\u6790";
}
async function LJt(e9, t) {
  let n = ve(e9.songmid), s = ve(e9.strMediaMid || e9.mediaMid || n);
  if (!n || !s) return "";
  let c = String(Math.floor(Math.random() * 1e7)), l = `${t.prefix}${s}${t.suffix}`, d = await MJt({ module: "vkey.GetVkeyServer", method: "CgiGetVkey", param: { guid: c, platform: "20", filename: [l], songmid: [n], songtype: [0], uin: v7, loginflag: 1 } }), m = Array.isArray(d?.midurlinfo) ? d.midurlinfo[0] : null, g = ve(m?.purl);
  return g ? `${(Array.isArray(d?.sip) ? ve(d.sip[0]) : "") || "https://isure.stream.qqmusic.qq.com/"}${g}` : "";
}
async function MJt(e9) {
  let t = UJt(e9), s = (await t0.post(dJt, JSON.stringify(t), { headers: $Jt(), responseType: "json", timeout: 2e4 })).data || {};
  return s?.data?.data || s?.data || {};
}
function UJt(e9) {
  let t = { comm: { cv: String(v7), ct: "11", format: "json", inCharset: "utf-8", outCharset: "utf-8", notice: 0, platform: "yqq.json", needNewCode: 1, uin: v7, g_tk_new_20200303: v7, g_tk: v7, tmeAppID: "qqmusiclight", nettype: "NETWORK_WIFI", tmeLoginType: "2", devicelevel: "31", os_ver: "11", v: String(v7), qq: String(v7), authst: z10, tmeLoginMethod: "1", fPersonality: "0", phonetype: "0" }, data: e9 };
  return e9?.method === "CgiGetVkey" && delete t.comm.tmeAppID, t;
}
function $Jt() {
  return { Referer: "https://y.qq.com/", "User-Agent": mJt, Cookie: `qm_keyst=${z10}; uin=${v7}` };
}
async function FJt(e9, t, n, s) {
  try {
    let c = await WJt(t);
    if (!c) return;
    Z10(e9);
    let l = q10.default.createHash("md5").update(`${s}:${t.songmid}:${Date.now()}:${Math.random()}`).digest("hex");
    return e9.set(l, { text: c, createdAt: Date.now(), lastAccess: Date.now() }), `${n}/spider/${encodeURIComponent(s)}/3/lrcproxy/${l}.lrc`;
  } catch {
    return;
  }
}
async function WJt(e9) {
  if (!e9.songmid) return "";
  let t = await t0.get("http://c.y.qq.com/lyric/fcgi-bin/fcg_query_lyric_new.fcg", { params: { songmid: e9.songmid, pcachetime: Date.now(), g_tk: 5381, loginUin: 0, hostUin: 0, inCharset: "utf8", outCharset: "utf-8", notice: 0, platform: "yqq", needNewCode: 0 }, headers: Tpe(), responseType: "text", transformResponse: [(c) => c], timeout: 2e4 }), n = Spe(t.data), s = ve(n?.lyric);
  return s ? Buffer.from(s, "base64").toString("utf8").replace(/^\uFEFF/, "").trim() : "";
}
function VJt(e9, t, n) {
  Z10(e9);
  let s = e9.get(t);
  return s ? (s.lastAccess = Date.now(), n.header("cache-control", "no-store"), n.type("text/plain; charset=utf-8"), s.text) : (n.code(404), "\u6B4C\u8BCD\u5DF2\u8FC7\u671F");
}
function Z10(e9) {
  let t = Date.now(), n = 1800 * 1e3;
  for (let [c, l] of e9.entries()) t - l.lastAccess > n && e9.delete(c);
  if (e9.size <= 128) return;
  let s = [...e9.entries()].sort((c, l) => c[1].lastAccess - l[1].lastAccess);
  for (let [c] of s.slice(0, e9.size - 128)) e9.delete(c);
}
function zz(e9 = {}) {
  let t = e9.album || {}, n = e9.file || {}, s = Array.isArray(e9.singer) ? e9.singer : [], c = ve(e9.albummid || t.mid);
  return wpe({ id: ve(e9.id || e9.songid), songmid: ve(e9.mid || e9.songmid), strMediaMid: ve(n.media_mid || e9.strMediaMid || e9.media_mid), title: Aa(e9.title || e9.songname || e9.name), singer: s.map((l) => Aa(l?.name)).filter(Boolean).join(", "), album: Aa(e9.albumname || t.title || t.name), cover: Epe(c), albumId: ve(e9.albumid || t.id), albumMID: c, rawLrc: ve(e9.lyric) });
}
function wpe(e9 = {}) {
  return { id: ve(e9.id), songmid: ve(e9.songmid || e9.mid), title: Aa(e9.title || e9.songname || e9.name), singer: Aa(e9.singer || e9.artist), album: Aa(e9.album), cover: ve(e9.cover || e9.artwork), albumId: ve(e9.albumId || e9.albumid), albumMID: ve(e9.albumMID || e9.albummid), strMediaMid: ve(e9.strMediaMid || e9.strMediaMID || e9.mediaMid || e9.media_mid), remark: Aa(e9.remark), rawLrc: ve(e9.rawLrc) };
}
async function Yz(e9, t = {}) {
  return (await t0.get(e9, { headers: Tpe(), params: t, responseType: "json", timeout: 2e4 })).data || {};
}
function Spe(e9) {
  let t = ve(e9).trim().replace(/^(?:callback|MusicJsonCallback|jsonCallback)\(/, "").replace(/\)$/, "");
  try {
    return JSON.parse(t);
  } catch {
    return {};
  }
}
function K10(e9) {
  return ve(e9?.cover || e9?.pic || e9?.artwork);
}
function Epe(e9, t = "") {
  let n = ve(e9);
  return n ? `https://y.gtimg.cn/music/photo_new/T002R800x800M000${n}.jpg` : ve(t);
}
function GN(e9) {
  let t = Aa(e9?.title), n = Aa(e9?.singer);
  return n && t && !t.includes(n) ? `${n} - ${t}` : t || n;
}
function Aa(e9) {
  return ve(e9).replace(/<\/?em>/gi, "").replace(/<[^>]+>/g, "").replace(/\$/g, "").replace(/#/g, "").replace(/\s+/g, " ").trim();
}
function Q2(e9) {
  return Buffer.from(JSON.stringify(e9), "utf8").toString("base64url");
}
function J10(e9) {
  try {
    return JSON.parse(Buffer.from(ve(e9), "base64url").toString("utf8"));
  } catch {
    return {};
  }
}
function jJt(e9) {
  let t = J10(e9);
  return wpe(t.song || t);
}
function H10(e9, t) {
  let n = Aa(t).toLowerCase(), s = Aa(e9?.vod_name).toLowerCase();
  return n ? s === n ? 100 : s.endsWith(` - ${n}`) ? 90 : s.includes(n) ? 50 : 0 : 0;
}
function Tpe() {
  return { referer: "https://y.qq.com", "user-agent": Y2, Cookie: "uin=" };
}
function GJt() {
  return { "User-Agent": Y2, Referer: "https://y.qq.com/" };
}
function HJt(e9 = {}) {
  let t = e9.headers?.["x-forwarded-proto"] || "http", n = e9.headers?.host || "127.0.0.1:9988";
  return `${t}://${n}`;
}
function qJt(e9) {
  return encodeURIComponent(ve(e9));
}
var ip0 = C0(referenceBuiltin3, 1);
var zJt = "https://music.163.com/api/search/get/web?csrf_token=";
var YJt = "https://music.haitangw.cc/music/wy.php";
var eh = 30;
var HN = 10;
var Zz = 30;
var X_ = 2e3;
var X10 = 40;
var QJt = "\u70ED\u6B4C";
var ep0 = { type_id: "sheet", type_name: "\u6B4C\u5355" };
var Qz = { type_id: "rank", type_name: "\u699C\u5355" };
var tp0 = [{ id: "3778678", name: "\u70ED\u6B4C\u699C" }, { id: "19723756", name: "\u98D9\u5347\u699C" }, { id: "3779629", name: "\u65B0\u6B4C\u699C" }, { id: "2884035", name: "\u539F\u521B\u699C" }];
var ZJt = [{ name: "\u65E0\u635FFLAC", level: "lossless" }, { name: "\u9AD8\u54C1\u8D28320K", level: "exhigh" }, { name: "\u6807\u51C6128K", level: "standard" }];
function ap0(e9 = {}) {
  let t = e9.remoteWexConfig, n = /* @__PURE__ */ new Map(), s = { key: "musicaiwy", name: "\u5C0F\u6613|\u97F3\u4E50", type: 3, \u7C7B\u578B: "\u97F3\u4E50" };
  return { meta: s, async init() {
    return {};
  }, async home() {
    return P0([ep0, Qz], {});
  }, async homeVod() {
    return this.category({ body: { id: Qz.type_id, page: 1 } });
  }, async category(c) {
    let l = c.body || {}, d = en(l.page || l.pg || 1), m = ve(l.extend?.cateId || l.id || l.tid, Qz.type_id);
    if (m === ep0.type_id) {
      let g = await op0(QJt, d, Zz);
      return po(Me({ page: d, pagecount: g.length < Zz ? d : d + 1, limit: Zz, total: 0, list: g }), c, "https://music.163.com/");
    }
    if (m === Qz.type_id) {
      let g = await sXt(), y = (d - 1) * eh, v = g.slice(y, y + eh).map(nXt).filter(Boolean);
      return po(Me({ page: d, pagecount: y + eh >= g.length ? d : d + 1, limit: eh, total: g.length, list: v }), c, "https://music.163.com/");
    }
    return Me({ page: d, pagecount: 1, limit: eh, total: 0, list: [] });
  }, async detail(c) {
    let l = ve(Array.isArray(c.body?.id) ? c.body.id[0] : c.body?.id);
    if (!l) throw new Error("\u7F3A\u5C11\u6B4C\u66F2\u53C2\u6570");
    let d = cp0(l);
    if (d.type === "sheet") return po(l0([await rp0(d, t)]), c, "https://music.163.com/");
    if (d.type === "rank") return po(l0([await rp0({ ...d, sheetId: d.rankId }, t)]), c, "https://music.163.com/");
    if (d.type === "album") return po(l0([await iXt(d, t)]), c, "https://music.163.com/");
    let m = Rpe(d.song || d), g = Jz(m);
    return po(l0([b0({ id: l, name: g, pic: xp0(m), actor: m.singer, content: m.album || g, vod_play_from: m.id ? Wn(t) : "", vod_play_url: m.id ? `${g}$${th({ type: "song", song: m })}` : "" })]), c, "https://music.163.com/");
  }, async play(c) {
    let l = fXt(ve(c.body?.id)), d = await xXt(l);
    if (!d.length) throw new Error("\u7F51\u6613\u64AD\u653E\u5730\u5740\u4E3A\u7A7A");
    let m = await cXt(n, l, mXt(c), s.key);
    return E0({ parse: 0, url: d, header: pXt(), lyric: m, extra: { danmaku: "", nodanmu: true } });
  }, async lrcproxy(c, l) {
    let d = ve(c.params?.token).replace(/\.lrc$/i, "");
    return lXt(n, d, l);
  }, async search(c) {
    let l = c.body || {}, d = ve(l.wd || l.key), m = en(l.page || l.pg || 1), g = await KJt(d, m);
    return po(Me({ page: m, pagecount: g.length < eh ? m : m + 1, limit: eh, total: 0, list: g }), c, "https://music.163.com/");
  } };
}
async function KJt(e9, t) {
  if (!e9) return [];
  let [n, s, c] = await Promise.all([JJt(e9, t).catch(() => []), XJt(e9, t).catch(() => []), op0(e9, t, HN).catch(() => [])]);
  return [...n.slice(0, HN), ...s.slice(0, HN), ...c.slice(0, HN)];
}
async function Ipe(e9, t, n, s = eh) {
  return (await ew(zJt, { s: e9, type: n, offset: (t - 1) * s, total: "true", limit: s }))?.result || {};
}
async function JJt(e9, t) {
  let n = await Ipe(e9, t, 1, eh);
  return (Array.isArray(n?.songs) ? n.songs : []).map((c) => eXt(Kz(c))).filter(Boolean).sort((c, l) => np0(l, e9) - np0(c, e9));
}
async function XJt(e9, t) {
  let n = await Ipe(e9, t, 10, HN);
  return (Array.isArray(n?.albums) ? n.albums : []).map(tXt).filter(Boolean);
}
async function op0(e9, t, n = Zz) {
  let s = await Ipe(e9, t, 1e3, n);
  return (Array.isArray(s?.playlists) ? s.playlists : []).map(rXt).filter(Boolean);
}
function eXt(e9) {
  return !e9.title || !e9.id ? null : u0({ id: th({ type: "song", song: e9 }), name: Jz(e9), pic: xp0(e9), remarks: e9.album, style: { type: "list" } });
}
function tXt(e9) {
  let t = ve(e9?.id), n = Ao(e9?.name);
  if (!t || !n) return null;
  let s = Ao(e9?.artist?.name || e9?.artists?.[0]?.name);
  return u0({ id: th({ type: "album", albumId: t, name: n, pic: ve(e9?.picUrl || e9?.blurPicUrl), author: s, content: Ao(e9?.description), date: e9?.publishTime ? dXt(e9.publishTime) : "" }), name: n, pic: ve(e9?.picUrl || e9?.blurPicUrl), remarks: s ? `\u4E13\u8F91 \xB7 ${s}` : "\u4E13\u8F91" });
}
function rXt(e9) {
  let t = ve(e9?.id), n = Ao(e9?.name);
  if (!t || !n) return null;
  let s = en(e9?.trackCount, 0);
  return u0({ id: th({ type: "sheet", sheetId: t, name: n, pic: ve(e9?.coverImgUrl), author: Ao(e9?.creator?.nickname), content: Ao(e9?.description), count: s }), name: n, pic: ve(e9?.coverImgUrl), remarks: s ? `${s}\u9996` : "\u6B4C\u5355" });
}
function nXt(e9) {
  let t = ve(e9?.id), n = Ao(e9?.name);
  return !t || !n ? null : u0({ id: th({ type: "rank", rankId: t, name: n, pic: ve(e9.pic), content: Ao(e9.content) }), name: n, pic: ve(e9.pic), remarks: "\u699C\u5355" });
}
async function iXt(e9, t) {
  let n = await ew(`https://music.163.com/api/v1/album/${lp0(e9.albumId)}`), s = n?.album || {}, c = (Array.isArray(n?.songs) ? n.songs : []).slice(0, X_).map(Kz).filter((d) => d.title && d.id), l = Ao(s?.name || e9.name || "\u4E13\u8F91");
  return b0({ id: th({ type: "album", albumId: e9.albumId, name: l }), name: l, pic: ve(s?.picUrl || e9.pic), actor: Ao(s?.artist?.name || e9.author), content: Ao(s?.description || e9.content || e9.date), vod_play_from: c.length ? Wn(t) : "", vod_play_url: c.map((d) => `${Jz(d)}$${th({ type: "song", song: d })}`).join("#") });
}
async function rp0(e9, t) {
  let { info: n, songs: s } = await aXt(e9.sheetId), c = n || {}, l = Ao(c.name || e9.name || `\u6B4C\u5355${e9.sheetId}`);
  return b0({ id: th({ type: "sheet", sheetId: e9.sheetId, name: l }), name: l, pic: ve(c.coverImgUrl || e9.pic), actor: Ao(c.creator?.nickname || e9.author), content: Ao(c.description || e9.content || `\u6700\u591A\u52A0\u8F7D${X_}\u9996`), vod_play_from: s.length ? Wn(t) : "", vod_play_url: s.map((d) => `${Jz(d)}$${th({ type: "song", song: d })}`).join("#") });
}
async function aXt(e9) {
  let n = (await ew("https://music.163.com/api/v3/playlist/detail", { id: e9, n: 5e3 }))?.playlist || {}, s = Array.isArray(n.tracks) ? n.tracks.map(Kz).filter((c) => c.title && c.id) : [];
  if (s.length < Math.min(en(n.trackCount, 0), X_)) {
    let c = (Array.isArray(n.trackIds) ? n.trackIds : []).map((l) => l.id).filter(Boolean).slice(0, X_);
    s = await oXt(c);
  } else s = s.slice(0, X_);
  return { info: n, songs: s };
}
async function oXt(e9) {
  let t = [];
  for (let n = 0; n < e9.length && t.length < X_; n += X10) {
    let s = e9.slice(n, n + X10), c = await ew("https://music.163.com/api/song/detail/", { ids: `[${s.join(",")}]` }), l = Array.isArray(c?.songs) ? c.songs : [];
    for (let d of l) {
      let m = Kz(d);
      m.title && m.id && t.push(m);
    }
  }
  return t;
}
async function sXt() {
  try {
    let e9 = await t0.get("https://music.163.com/discover/toplist", { headers: up0(), responseType: "text", transformResponse: [(s) => s], timeout: 2e4 }), t = Pr(String(e9.data || "")), n = [];
    return t(".n-minelst li").each((s, c) => {
      let l = t(c), d = ve(l.find("a").first().attr("href")), m = /id=(\d+)/.exec(d)?.[1] || "", g = Ao(l.find("p.name").text() || l.find("a").first().text()), y = ve(l.find("img").attr("src"));
      m && g && n.push({ id: m, name: g, pic: y });
    }), n.length ? n : tp0;
  } catch {
    return tp0;
  }
}
async function xXt(e9) {
  let t = [];
  for (let n of ZJt) try {
    let s = await ew(YJt, { id: e9.id, level: n.level }), c = ve(s?.data?.url || s?.url);
    c && t.push(n.name, c);
  } catch {
  }
  return !t.length && e9.id && t.push("\u6807\u51C6128K", `https://share.duanx.cn/url/wy/${lp0(e9.id)}/128k`), t;
}
async function cXt(e9, t, n, s) {
  try {
    let c = await uXt(t);
    if (!c) return;
    sp0(e9);
    let l = ip0.default.createHash("md5").update(`${s}:${t.id}:${Date.now()}:${Math.random()}`).digest("hex");
    return e9.set(l, { text: c, createdAt: Date.now(), lastAccess: Date.now() }), `${n}/spider/${encodeURIComponent(s)}/3/lrcproxy/${l}.lrc`;
  } catch {
    return;
  }
}
async function uXt(e9) {
  if (!e9.id) return "";
  let t = await ew("https://music.163.com/api/song/lyric", { id: e9.id, lv: -1, kv: -1, tv: -1 });
  return ve(t?.lrc?.lyric).replace(/^\uFEFF/, "").trim();
}
function lXt(e9, t, n) {
  sp0(e9);
  let s = e9.get(t);
  return s ? (s.lastAccess = Date.now(), n.header("cache-control", "no-store"), n.type("text/plain; charset=utf-8"), s.text) : (n.code(404), "\u6B4C\u8BCD\u5DF2\u8FC7\u671F");
}
function sp0(e9) {
  let t = Date.now(), n = 1800 * 1e3;
  for (let [c, l] of e9.entries()) t - l.lastAccess > n && e9.delete(c);
  if (e9.size <= 128) return;
  let s = [...e9.entries()].sort((c, l) => c[1].lastAccess - l[1].lastAccess);
  for (let [c] of s.slice(0, e9.size - 128)) e9.delete(c);
}
function Kz(e9 = {}) {
  let t = e9.al || e9.album || {}, n = Array.isArray(e9.ar) ? e9.ar : Array.isArray(e9.artists) ? e9.artists : [];
  return Rpe({ id: e9.id, title: e9.name, singer: n.map((s) => Ao(s?.name)).filter(Boolean).join(", "), album: t.name, cover: t.picUrl || e9.picUrl || e9.coverImgUrl, duration: e9.dt || e9.duration });
}
function Rpe(e9 = {}) {
  return { id: ve(e9.id), title: Ao(e9.title || e9.name), singer: Ao(e9.singer || e9.artist), album: Ao(e9.album), cover: ve(e9.cover || e9.artwork), duration: en(e9.duration, 0), remark: Ao(e9.remark) };
}
async function ew(e9, t = {}) {
  return (await t0.get(e9, { headers: up0(), params: t, responseType: "json", timeout: 2e4 })).data || {};
}
function xp0(e9) {
  return ve(e9?.cover || e9?.pic || e9?.artwork);
}
function Jz(e9) {
  let t = Ao(e9?.title), n = Ao(e9?.singer);
  return n && t && !t.includes(n) ? `${n} - ${t}` : t || n;
}
function Ao(e9) {
  return ve(e9).replace(/<\/?em>/gi, "").replace(/<[^>]+>/g, "").replace(/\$/g, "").replace(/#/g, "").replace(/\s+/g, " ").trim();
}
function th(e9) {
  return Buffer.from(JSON.stringify(e9), "utf8").toString("base64url");
}
function cp0(e9) {
  try {
    return JSON.parse(Buffer.from(ve(e9), "base64url").toString("utf8"));
  } catch {
    return {};
  }
}
function fXt(e9) {
  let t = cp0(e9);
  return Rpe(t.song || t);
}
function np0(e9, t) {
  let n = Ao(t).toLowerCase(), s = Ao(e9?.vod_name).toLowerCase();
  return n ? s === n ? 100 : s.endsWith(` - ${n}`) ? 90 : s.includes(n) ? 50 : 0 : 0;
}
function dXt(e9) {
  let t = new Date(Number(e9));
  return Number.isNaN(t.getTime()) ? "" : t.toISOString().slice(0, 10);
}
function up0() {
  return { "User-Agent": Y2, Referer: "https://music.163.com/" };
}
function pXt() {
  return { "User-Agent": Y2, Referer: "https://music.163.com/" };
}
function mXt(e9 = {}) {
  let t = e9.headers?.["x-forwarded-proto"] || "http", n = e9.headers?.host || "127.0.0.1:9988";
  return `${t}://${n}`;
}
function lp0(e9) {
  return encodeURIComponent(ve(e9));
}
function fp0(e9 = {}) {
  return Vz({ key: "musicai163", name: "\u6613\u542C|\u97F3\u4E50", site: "https://www.4c44.com", playlistTid: "playlists", playPath: "/js/play.php", playBody(t) {
    return { id: t, type: "music", key: hXt() };
  } }, e9);
}
function hXt() {
  let e9 = /* @__PURE__ */ new Date(), t = (n) => String(n).padStart(2, "0");
  return `${e9.getFullYear()}${t(e9.getMonth() + 1)}${t(e9.getDate())}${t(e9.getHours())}${t(e9.getMinutes())}4c44`;
}
var Cpe = C0(referenceBuiltin0, 1);
var gXt = "https://api.46d5umpk.com";
var pp0 = "KANGEQIU@8868!~.";
var mp0 = "0200010900030207";
function hp0(e9 = {}) {
  let t = e9.remoteWexConfig;
  return { meta: { key: "sportaiguazi", name: "\u74DC\u5B50|\u4F53\u80B2", type: 3 }, async init() {
    return {};
  }, async home() {
    return P0([{ type_id: "hot", type_name: "\u70ED\u95E8" }, { type_id: "nba", type_name: "NBA" }, { type_id: "football", type_name: "\u8DB3\u7403" }, { type_id: "basketball", type_name: "\u7BEE\u7403" }], {});
  }, async category(n) {
    let s = n.body || {}, c = en(s.page || s.pg || 1);
    if (c !== 1) return Me({ page: c, pagecount: 1, limit: 999, total: 0, list: [] });
    let l = ve(s.id || s.tid, "hot"), d = await dp0("/gz/live/sports?parameter=key", bXt(l), []), m = Date.now() - 24 * 3600 * 1e3, g = [];
    for (let y of d) {
      let v = Number(y?.match_time || 0) * 1e3;
      if (v < m || Number(y?.m_status || 0) >= 2) continue;
      let w = y?.home || {}, T = y?.visiting || {}, I = `${ve(y?.event_name)} ${_Xt(v)} ${ve(y?.match_status_info)}`.trim(), N = Number(w?.score || 0), C = Number(T?.score || 0);
      (N > 0 || C > 0) && (I += ` \u6BD4\u5206${N}-${C}`), g.push(u0({ id: ve(y?.mid), name: `${ve(w?.name)} vs ${ve(T?.name)}`, pic: w?.logo, remarks: I }));
    }
    return Me({ page: 1, pagecount: 1, limit: 999, total: g.length, list: g });
  }, async detail(n) {
    let s = ve(Array.isArray(n.body?.id) ? n.body.id[0] : n.body?.id);
    if (!s) throw new Error("\u74DC\u5B50\u4F53\u80B2\u53C2\u6570\u4E3A\u7A7A");
    let c = await dp0("/gz/live/detail?parameter=key", JSON.stringify({ mid: s }), {}), l = c?.home || {}, d = c?.visiting || {}, m = ve(c?.match_status_info), g = Number(l?.score || 0), y = Number(d?.score || 0);
    (g > 0 || y > 0) && (m += ` \u6BD4\u5206${g}-${y}`);
    let v = [], w = Array.isArray(c?.live_line) ? c.live_line : [];
    for (let T = 0; T < w.length; T++) {
      let I = w[T] || {}, N = ve(I.m3u8);
      N && v.push(`${ve(I.name, `\u7EBF\u8DEF${T + 1}`)}$${N}`);
    }
    if (!v.length) throw new Error("\u74DC\u5B50\u4F53\u80B2\u6682\u65E0\u76F4\u64AD\u6E90");
    return l0([b0({ id: s, name: `${ve(l?.name)} vs ${ve(d?.name)}`, pic: l?.logo, remarks: m, content: `${m}\u4E0D\u8981\u76F8\u4FE1\u89C6\u9891\u4E2D\u7684\u4EFB\u4F55\u5E7F\u544A\uFF01\uFF01\uFF01\uFF01\uFF01\uFF01\uFF01\uFF01`, vod_play_from: Wn(t), vod_play_url: v.join("#") })]);
  }, async play(n) {
    let s = ve(n.body?.id);
    if (!s) throw new Error("\u74DC\u5B50\u4F53\u80B2\u64AD\u653E\u5730\u5740\u4E3A\u7A7A");
    return E0({ parse: 0, url: s, header: AXt(), extra: { danmaku: "", nodanmu: true } });
  }, async search() {
    return "";
  } };
}
async function dp0(e9, t, n) {
  let s = new URLSearchParams();
  s.set("parameter", kXt(t));
  let l = (await t0.post(`${gXt}${e9}`, s.toString(), { headers: yXt(), responseType: "json", timeout: 2e4 })).data?.data;
  return l ? JSON.parse(vXt(l)) : n;
}
function bXt(e9) {
  let t = { hot: '{"frame":"0","hot":"1","tag":"0","type":"0"}', nba: '{"frame":"0","hot":"0","tag":"37","type":"0"}', football: '{"frame":"0","hot":"0","tag":"0","type":"1"}', basketball: '{"frame":"0","hot":"0","tag":"0","type":"2"}' };
  return t[e9] || t.hot;
}
function yXt() {
  return { "User-Agent": "okhttp/3.12.0", "content-type": "application/x-www-form-urlencoded", "user-platform": "null", "client-version": "3.0.1.1", "client-channel": "", token: "" };
}
function AXt() {
  return { "User-Agent": "Lavf/57.83.100", Referer: "http://WJiZxLXA2.com/" };
}
function kXt(e9) {
  let t = Cpe.default.createCipheriv("aes-128-cbc", Buffer.from(pp0, "utf8"), Buffer.from(mp0, "utf8"));
  return Buffer.concat([t.update(String(e9), "utf8"), t.final()]).toString("base64").replace(/\s+/g, "");
}
function vXt(e9) {
  let t = Cpe.default.createDecipheriv("aes-128-cbc", Buffer.from(pp0, "utf8"), Buffer.from(mp0, "utf8"));
  return Buffer.concat([t.update(String(e9), "base64"), t.final()]).toString("utf8");
}
function _Xt(e9) {
  let t = new Date(e9), n = (s) => String(s).padStart(2, "0");
  return `${n(t.getMonth() + 1)}-${n(t.getDate())} ${n(t.getHours())}:${n(t.getMinutes())}`;
}
var Dpe = "https://www.kafeizhibo.cc";
var gp0 = `${Dpe}/api/v1`;
var Npe = 30;
function yp0(e9 = {}) {
  let t = e9.remoteWexConfig;
  return { meta: { key: "sportaikafei", name: "\u5496\u5561|\u4F53\u80B2", type: 3 }, async init() {
    return {};
  }, async home() {
    return P0([{ type_id: "all", type_name: "\u5168\u90E8" }, { type_id: "hot", type_name: "\u70ED\u95E8" }, { type_id: "1", type_name: "\u8DB3\u7403" }, { type_id: "2", type_name: "\u7BEE\u7403" }], {});
  }, async category(n) {
    let s = n.body || {}, c = ve(s.id || s.tid, "all"), l = en(s.page || s.pg || 1), d = await bp0(`${gp0}/schedule?size=${Npe}&page=${l}&type=${encodeURIComponent(c)}&platform=h5`), m = Array.isArray(d?.data) ? d.data : [], g = [];
    for (let v of m) {
      let w = v?.archor || {}, T = ve(w.room_id || v?.room_id);
      if (!T) continue;
      let I = ve(v?.league_name);
      ve(v?.status) === "live" ? I += `${ve(v?.home_score)}:${ve(v?.away_score)} \u76F4\u64AD\u4E2D` : I += `${ve(v?.start_time)} \u672A\u5F00\u8D5B`, g.push(u0({ id: T, name: `${ve(v?.home_team)} vs ${ve(v?.away_team)}`, pic: v?.home_team_logo, remarks: I }));
    }
    let y = Number.isFinite(Number(d?.total)) ? Number(d.total) : g.length;
    return Me({ page: l, pagecount: Math.max(1, Math.ceil(y / Npe)), limit: Npe, total: y, list: g });
  }, async detail(n) {
    let s = ve(Array.isArray(n.body?.id) ? n.body.id[0] : n.body?.id);
    if (!s) throw new Error("\u5496\u5561\u4F53\u80B2\u53C2\u6570\u4E3A\u7A7A");
    let l = (await bp0(`${gp0}/room/${encodeURIComponent(s)}`))?.data || {}, d = l.room_info || {}, m = [];
    if (Ope(m, l.signals), Ope(m, l.external_signals), Ope(m, l.external_signals_h5), !m.length) throw new Error("\u5496\u5561\u4F53\u80B2\u6682\u65E0\u76F4\u64AD\u6E90");
    return l0([b0({ id: s, name: ve(d.title), pic: wXt(d.avatar), content: "\u4E0D\u8981\u76F8\u4FE1\u89C6\u9891\u4E2D\u7684\u4EFB\u4F55\u5E7F\u544A\uFF01\uFF01\uFF01\uFF01\uFF01\uFF01\uFF01\uFF01", vod_play_from: Wn(t), vod_play_url: m.join("#") })]);
  }, async play(n) {
    let s = ve(n.body?.id);
    if (!s) throw new Error("\u5496\u5561\u4F53\u80B2\u64AD\u653E\u5730\u5740\u4E3A\u7A7A");
    return E0({ parse: 0, url: s, header: Ap0(), extra: { danmaku: "", nodanmu: true } });
  }, async search() {
    return "";
  } };
}
async function bp0(e9) {
  return (await t0.get(e9, { headers: Ap0(), responseType: "json", timeout: 2e4 })).data || {};
}
function Ope(e9, t) {
  if (Array.isArray(t)) for (let n of t) {
    let s = ve(n?.stream_url || n?.url);
    s && e9.push(`${ve(n?.name, `\u7EBF\u8DEF${e9.length + 1}`)}$${s}`);
  }
}
function wXt(e9) {
  let t = ve(e9);
  return t ? /^https?:\/\//i.test(t) ? t : t.startsWith("/") ? `${Dpe}${t}` : t : "";
}
function Ap0() {
  return { "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/148.0.0.0 Safari/537.36 Edg/148.0.0.0", referer: `${Dpe}/` };
}
var eY = C0(referenceBuiltin0, 1);
var kp0 = "zNuZTzWqOliEgJAL";
var vp0 = "zNuZTzWqOliEgJAL";
var SXt = "http://api.j9y5m8k8w7q9h8a.xyz";
function _p0(e9 = {}) {
  let t = e9.remoteWexConfig, n = { siteUrl: SXt, imei: "", base: "", playApi: "", readyPromise: null };
  return { meta: { key: "sportaifeiqiu", name: "\u98DE\u7403|\u4F53\u80B2", type: 3 }, async init() {
    return await wp0(n), {};
  }, async home() {
    return P0([{ type_id: "1", type_name: "\u8DB3\u7403" }, { type_id: "2", type_name: "\u7BEE\u7403" }, { type_id: "101", type_name: "\u7535\u7ADE" }, { type_id: "3", type_name: "\u5176\u4ED6" }], {});
  }, async category(s) {
    await Ppe(n);
    let c = s.body || {}, l = ve(c.id || c.tid, "1"), d = en(c.page || c.pg || 1), m = zN(JSON.stringify({ sport_id: l, tab: "0", hot: "0" })), g = await YN(`${n.siteUrl}/v220/schedule?data=${encodeURIComponent(m)}`, qN(n)), y = TXt(g);
    return Me({ page: d, pagecount: 1, limit: 999, total: y.length, list: y });
  }, async detail(s) {
    await Ppe(n);
    let c = ve(Array.isArray(s.body?.id) ? s.body.id[0] : s.body?.id);
    if (!c) throw new Error("\u98DE\u7403\u53C2\u6570\u4E3A\u7A7A");
    let l = c.split("|||");
    if (l.length < 2) throw new Error("\u98DE\u7403\u53C2\u6570\u9519\u8BEF");
    let [d, m] = l, g = zN(JSON.stringify({ sport_id: m, match_id: d, page: "0", page_size: "18" })), y = await YN(`${n.siteUrl}/v171/matchs_live?data=${encodeURIComponent(g)}`, qN(n)), v = QN(Xz(y), {}), w = Array.isArray(v?.data) ? v.data : [];
    if (!w.length) throw new Error("\u98DE\u7403\u6682\u65E0\u76F4\u64AD\u6E90");
    let T = w[0] || {}, I = [];
    for (let N of w) {
      let C = ve(N?.chatroom_id);
      C && I.push(`${ve(N?.user_nickname, "\u6BD4\u8D5B\u539F\u58F0")}$${C}|||${c}`);
    }
    if (!I.length) throw new Error("\u98DE\u7403\u6682\u65E0\u76F4\u64AD\u6E90");
    return l0([b0({ id: d, name: ve(T.room_title), content: "\u4E0D\u8981\u76F8\u4FE1\u89C6\u9891\u4E2D\u7684\u4EFB\u4F55\u5E7F\u544A\uFF01\uFF01\uFF01\uFF01\uFF01\uFF01\uFF01\uFF01", vod_play_from: Wn(t), vod_play_url: I.join("#") })]);
  }, async play(s) {
    await Ppe(n);
    let l = ve(s.body?.id).split("|||");
    if (l.length < 3) throw new Error("\u98DE\u7403\u64AD\u653E\u53C2\u6570\u9519\u8BEF");
    let [d, m, g] = l, y = zN(JSON.stringify({ room_id: d, sport_id: g, match_id: m }));
    await YN(`${n.siteUrl}/v131/room?data=${encodeURIComponent(y)}`, qN(n));
    let v = zN(JSON.stringify({ room_id: d, sport_id: g, match_id: m, code_id: "gqzm" })), w = new URLSearchParams();
    w.set("data", v);
    let T = await EXt(`${n.playApi}/v230/play/url`, w, { ...qN(n), "Content-Type": "application/x-www-form-urlencoded" }), I = QN(Xz(T), {}), N = ve(I?.data?.play_url);
    if (!N) throw new Error("\u98DE\u7403\u64AD\u653E\u5730\u5740\u4E3A\u7A7A");
    return E0({ parse: 0, url: N, header: Bpe(), extra: { danmaku: "", nodanmu: true } });
  }, async search() {
    return "";
  } };
}
async function Ppe(e9) {
  e9.playApi && e9.base && e9.imei || (e9.readyPromise || (e9.readyPromise = wp0(e9).finally(() => {
    e9.readyPromise = null;
  })), await e9.readyPromise);
}
async function wp0(e9) {
  let t = await YN("https://pullcfg.butueaa.cn/domain/master/raw/18", Bpe()), n = QN(Xz(t), []);
  Array.isArray(n) && n.length && (e9.siteUrl = ve(n[0], e9.siteUrl)), e9.imei = eY.default.randomUUID(), e9.base = zN(JSON.stringify({ "api-version": "11", "im-uid": "", "invit-code": "", version: "2.3.6", "os-ver": "9", imid: "", "phone-model": "22081212C", imtoken: "", "dun-imei": "", imei: e9.imei, device: "1" }));
  let s = await YN(`${e9.siteUrl}/v191/domain`, qN(e9)), c = QN(Xz(s), {});
  if (e9.playApi = ve(c?.data?.openim_zb_api_list?.[0]), !e9.playApi) throw new Error("\u98DE\u7403\u64AD\u653E\u57DF\u540D\u521D\u59CB\u5316\u5931\u8D25");
  console.log(`[SportAiFeiQiu] siteUrl=${e9.siteUrl}, playApi=${e9.playApi}`);
}
async function YN(e9, t) {
  let n = await t0.get(e9, { headers: t, responseType: "text", transformResponse: [(s) => s], timeout: 2e4 });
  return typeof n.data == "string" ? n.data : JSON.stringify(n.data || {});
}
async function EXt(e9, t, n) {
  let s = await t0.post(e9, t.toString(), { headers: n, responseType: "text", transformResponse: [(c) => c], timeout: 2e4 });
  return typeof s.data == "string" ? s.data : JSON.stringify(s.data || {});
}
function TXt(e9) {
  let t = QN(e9, {}), n = Array.isArray(t?.data?.list) ? t.data.list : [], s = [];
  for (let c of n) {
    let l = ve(c?.tab), d = Array.isArray(c?.list) ? c.list : [];
    for (let m of d) {
      let g = `${ve(m?.match_id)}|||${ve(m?.sport_id)}`;
      if (g === "|||") continue;
      let y = l.includes("matching") ? `${ve(m?.alias_name)}${ve(m?.home_score)}:${ve(m?.away_score)} \u76F4\u64AD\u4E2D` : `${ve(m?.alias_name)}${ve(m?.match_date)} \u672A\u5F00\u8D5B`;
      s.push(u0({ id: g, name: `${ve(m?.home_name)} vs ${ve(m?.away_name)}`, pic: m?.home_logo, remarks: y }));
    }
  }
  return s;
}
function qN(e9) {
  return { ...Bpe(), imei: e9.imei, device: "1", platform: "fqzb", base: e9.base };
}
function Bpe() {
  return { "User-Agent": "okhttp/4.2.2" };
}
function zN(e9) {
  let t = eY.default.createCipheriv("aes-128-cbc", Buffer.from(kp0, "utf8"), Buffer.from(vp0, "utf8"));
  return Buffer.concat([t.update(String(e9), "utf8"), t.final()]).toString("base64").replace(/\s+/g, "");
}
function Xz(e9) {
  let t = String(e9 || "").replace(/\\/g, "").trim(), n = eY.default.createDecipheriv("aes-128-cbc", Buffer.from(kp0, "utf8"), Buffer.from(vp0, "utf8"));
  return Buffer.concat([n.update(Buffer.from(t, "base64")), n.final()]).toString("utf8");
}
function QN(e9, t) {
  if (e9 && typeof e9 == "object") return e9;
  try {
    return JSON.parse(String(e9 || ""));
  } catch {
    return t;
  }
}
var Sp0 = "https://aapi20.xbncs.com/api";
var Lpe = 30;
var IXt = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36";
function Ip0(e9 = {}) {
  let t = e9.remoteWexConfig;
  return { meta: { key: "sportaikanqiutong", name: "\u7403\u901A|\u4F53\u80B2", type: 3 }, async init() {
    return {};
  }, async home() {
    return P0([{ type_id: "-1", type_name: "\u5168\u90E8" }, { type_id: "1", type_name: "\u8DB3\u7403" }, { type_id: "2", type_name: "\u7BEE\u7403" }], {});
  }, async category(n) {
    let s = n.body || {}, c = ve(s.id || s.tid, "-1"), l = en(s.page || s.pg || 1), m = `${Sp0}/room/page?roomType=&navId=${encodeURIComponent(c === "-1" ? "" : c)}&roomId=&word=&page=${l}&pageSize=${Lpe}&channelId=3&platform=1`, y = (await Ep0(m))?.data || {}, v = Array.isArray(y.list) ? y.list : [], w = [];
    for (let N of v) {
      let C = ve(N?.roomId);
      C && w.push(u0({ id: C, name: ve(N?.title), pic: N?.cover, remarks: ve(N?.navName) }));
    }
    let T = Number.isFinite(Number(y.total)) ? Number(y.total) : w.length, I = Number.isFinite(Number(y.pages)) ? Number(y.pages) : Math.max(1, Math.ceil(T / Lpe));
    return Me({ page: l, pagecount: I, limit: Lpe, total: T, list: w });
  }, async detail(n) {
    let s = ve(Array.isArray(n.body?.id) ? n.body.id[0] : n.body?.id);
    if (!s) throw new Error("\u770B\u7403\u901A\u53C2\u6570\u4E3A\u7A7A");
    let l = (await Ep0(`${Sp0}/room/info?roomId=${encodeURIComponent(s)}&channelId=3&platform=1`))?.data || {}, d = [], m = ve(l.pushUrl), g = ve(l.pullUrl);
    if (m && d.push(`flv$${Tp0(m)}`), g && d.push(`m3u8$${Tp0(g)}`), !d.length) throw new Error("\u770B\u7403\u901A\u6682\u65E0\u64AD\u653E\u6570\u636E");
    return l0([b0({ id: s, name: ve(l.title), pic: l.cover, director: ve(l.nickName), content: "\u4E0D\u8981\u76F8\u4FE1\u89C6\u9891\u4E2D\u7684\u4EFB\u4F55\u5E7F\u544A\uFF01\uFF01\uFF01\uFF01\uFF01\uFF01\uFF01\uFF01", vod_play_from: Wn(t), vod_play_url: d.join("#") })]);
  }, async play(n) {
    let s = RXt(ve(n.body?.id));
    if (!s) throw new Error("\u770B\u7403\u901A\u64AD\u653E\u5730\u5740\u4E3A\u7A7A");
    return E0({ parse: 0, url: s, header: Rp0(), extra: { danmaku: "", nodanmu: true } });
  }, async search() {
    return "";
  } };
}
async function Ep0(e9) {
  return (await t0.get(e9, { headers: Rp0(), responseType: "json", timeout: 2e4 })).data || {};
}
function Rp0() {
  return { "User-Agent": IXt };
}
function Tp0(e9) {
  return Buffer.from(String(e9 || ""), "utf8").toString("base64");
}
function RXt(e9) {
  try {
    return Buffer.from(String(e9 || ""), "base64").toString("utf8");
  } catch {
    return "";
  }
}
var CXt = "http://www.88kanqiu.us";
var NXt = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36";
var OXt = "https://pic.imgdb.cn/item/657673d6c458853aeff94ab9.jpg";
var DXt = "ABCDEFGHIJKLMNOPQRSTUVWX";
function Dp0(e9 = {}) {
  let t = e9.remoteWexConfig, n = { siteUrl: CXt };
  return { meta: { key: "sportaikanqiu", name: "\u770B\u7403|\u4F53\u80B2", type: 3 }, async init(s = {}) {
    let c = ve(s.body?.extend || s.extend || s.ext);
    return c && (n.siteUrl = $Xt(c)), {};
  }, async home() {
    return P0([{ type_id: "", type_name: "\u5168\u90E8\u76F4\u64AD" }, { type_id: "1", type_name: "\u7BEE\u7403\u76F4\u64AD" }, { type_id: "8", type_name: "\u8DB3\u7403\u76F4\u64AD" }, { type_id: "21", type_name: "\u5176\u4ED6\u76F4\u64AD" }], PXt());
  }, async category(s) {
    let c = s.body || {}, l = c.extend || {}, d = ve(c.id || c.tid), m = ve(l.cateId || c.cateId || d), g = m ? `${n.siteUrl}/match/${encodeURIComponent(m)}/live` : n.siteUrl, y = await tY(g), v = Pr(y), w = [];
    return v(".list-group-item").each((T, I) => {
      let N = v(I), C = N.find(".btn.btn-primary").first().length ? N.find(".btn.btn-primary").first() : N.find(".btn").first(), B = C.attr("href"), L = Cp0(n.siteUrl, B);
      if (!L) return;
      let q = rY(N.find(".row.d-none").text());
      q || (q = rY(N.text()));
      let W = N.find(".col-xs-1").eq(0).find("img").attr("data-src") || "";
      W = W ? Cp0(n.siteUrl, W) : OXt;
      let F = rY(C.text());
      F || (F = rY(N.find(".btn.btn-default").text())), w.push(u0({ id: L, name: q, pic: W, remarks: F, style: { type: "list" } }));
    }), Me({ page: 1, pagecount: 1, limit: 0, total: w.length, list: w });
  }, async detail(s) {
    let c = ve(Array.isArray(s.body?.id) ? s.body.id[0] : s.body?.id);
    if (!c) throw new Error("\u770B\u7403\u53C2\u6570\u4E3A\u7A7A");
    if (c === n.siteUrl) throw new Error("\u6BD4\u8D5B\u5C1A\u672A\u5F00\u59CB");
    let l = await tY(c.replace("play", "source")), d = Upe(l, {})?.data, m = LXt(BXt(d)), g = Upe(m, {})?.links, y = [];
    if (Array.isArray(g)) for (let v = 0; v < g.length; v++) {
      let w = g[v] || {}, T = ve(w.url);
      T && y.push(`${ve(w.name, `\u7EBF\u8DEF${v + 1}`)}$${T}`);
    }
    if (!y.length) throw new Error("\u770B\u7403\u6682\u65E0\u64AD\u653E\u6570\u636E");
    return l0([b0({ id: c, content: "\u4E0D\u8981\u76F8\u4FE1\u89C6\u9891\u4E2D\u7684\u4EFB\u4F55\u5E7F\u544A\uFF01\uFF01\uFF01\uFF01\uFF01\uFF01\uFF01\uFF01", vod_play_from: Wn(t), vod_play_url: y.join("#") })]);
  }, async play(s) {
    let c = ve(s.body?.id);
    if (c.includes("?url=")) {
      let l = decodeURIComponent(c.split("?url=", 2)[1]);
      return E0({ parse: 0, url: l, header: nY(), extra: { danmaku: "", nodanmu: true } });
    }
    if (c.includes("?id=")) {
      let l = await tY(c), d = Mpe(l, /encodedStr = '(.*?)'/);
      if (!d) {
        let m = Mpe(l, /src='(.*?)"\+id/);
        if (m) {
          let g = c.split("?id=", 2)[1].split("&", 2)[0], y = c.substring(0, c.indexOf("/", 8));
          l = await tY(`${y}${m}${g}`), d = Mpe(l, /encodedStr = '(.*?)'/);
        }
      }
      if (d) {
        let m = MXt(Buffer.from(d, "base64"), DXt), g = ve(Upe(m, {})?.url);
        if (g) return E0({ parse: 0, url: g, header: nY(), extra: { danmaku: "", nodanmu: true } });
      }
    }
    return E0({ parse: 1, url: c, header: nY(), extra: { danmaku: "", nodanmu: true } });
  }, async search() {
    return "";
  } };
}
async function tY(e9) {
  let t = await t0.get(e9, { headers: nY(), responseType: "text", transformResponse: [(n) => n], timeout: 2e4 });
  return typeof t.data == "string" ? t.data : JSON.stringify(t.data || {});
}
function nY() {
  return { "User-Agent": NXt };
}
function PXt() {
  return { 1: [{ key: "cateId", name: "\u7C7B\u578B", value: [{ n: "NBA", v: "1" }, { n: "CBA", v: "2" }, { n: "\u7BEE\u7403\u7EFC\u5408", v: "4" }, { n: "\u7EAC\u6765\u4F53\u80B2", v: "21" }] }], 8: [{ key: "cateId", name: "\u7C7B\u578B", value: [{ n: "\u82F1\u8D85", v: "8" }, { n: "\u897F\u7532", v: "9" }, { n: "\u610F\u7532", v: "10" }, { n: "\u6B27\u51A0", v: "12" }, { n: "\u6B27\u8054", v: "13" }, { n: "\u5FB7\u7532", v: "14" }, { n: "\u6CD5\u7532", v: "15" }, { n: "\u6B27\u56FD\u8054", v: "16" }, { n: "\u8DB3\u603B\u676F", v: "27" }, { n: "\u56FD\u738B\u676F", v: "33" }, { n: "\u4E2D\u8D85", v: "7" }, { n: "\u4E9A\u51A0", v: "11" }, { n: "\u8DB3\u7403\u7EFC\u5408", v: "23" }, { n: "\u6B27\u534F\u8054", v: "28" }, { n: "\u7F8E\u804C\u8054", v: "26" }] }], 29: [{ key: "cateId", name: "\u7C7B\u578B", value: [{ n: "\u7F51\u7403", v: "29" }, { n: "\u65AF\u6D1B\u514B", v: "30" }, { n: "MLB", v: "38" }, { n: "UFC", v: "32" }, { n: "NFL", v: "25" }, { n: "CCTV5", v: "18" }] }] };
}
function Cp0(e9, t) {
  let n = ve(t);
  return n ? /^https?:\/\//i.test(n) ? n : n.startsWith("//") ? `http:${n}` : n.startsWith("/") ? `${e9}${n}` : `${e9}/${n}` : "";
}
function BXt(e9) {
  let t = ve(e9);
  return t ? t.length > 8 && t.startsWith("jsonp(") || t.length > 8 ? t.substring(6, t.length - 2) : t : "";
}
function LXt(e9) {
  try {
    return Buffer.from(String(e9 || ""), "base64").toString("utf8");
  } catch {
    return "";
  }
}
function Mpe(e9, t) {
  let n = String(e9 || "").match(t);
  return n ? ve(n[1]) : "";
}
function MXt(e9, t) {
  if (!e9 || !e9.length) return null;
  let n = Op0(e9, false), s = Op0(Buffer.from(t, "utf8"), false);
  if (n.length < 2) return null;
  s.length < 4 && (s = [...s, 0, 0, 0, 0].slice(0, 4));
  let c = n.length - 1, l, d, m, g, y, v = Math.floor(6 + 52 / (c + 1));
  for (m = tw(v * 2654435769), l = n[0]; m !== 0; ) {
    for (g = m >>> 2 & 3, y = c; y > 0; y--) d = n[y - 1], l = n[y] = tw(n[y] - Np0(m, l, d, y, g, s));
    d = n[c], l = n[0] = tw(n[0] - Np0(m, l, d, 0, g, s)), m = tw(m - 2654435769);
  }
  return UXt(n, true);
}
function Np0(e9, t, n, s, c, l) {
  return tw((n >>> 5 ^ t << 2) + (t >>> 3 ^ n << 4) ^ (e9 ^ t) + (l[s & 3 ^ c] ^ n));
}
function Op0(e9, t) {
  let n = (e9.length & 3) === 0 ? e9.length >>> 2 : (e9.length >>> 2) + 1, s = new Array(t ? n + 1 : n).fill(0);
  t && (s[n] = e9.length);
  for (let c = 0; c < e9.length; c++) s[c >>> 2] = tw(s[c >>> 2] | (255 & e9[c]) << ((c & 3) << 3));
  return s;
}
function UXt(e9, t) {
  let n = e9.length << 2;
  if (t) {
    let c = e9[e9.length - 1];
    if (n -= 4, c < n - 3 || c > n) return null;
    n = c;
  }
  let s = Buffer.alloc(n);
  for (let c = 0; c < n; c++) s[c] = e9[c >>> 2] >>> ((c & 3) << 3);
  return s.toString("utf8");
}
function tw(e9) {
  return e9 | 0;
}
function Upe(e9, t) {
  if (e9 && typeof e9 == "object") return e9;
  try {
    return JSON.parse(String(e9 || ""));
  } catch {
    return t;
  }
}
function $Xt(e9) {
  return ve(e9).replace(/\/+$/, "");
}
function rY(e9) {
  return ve(e9).replace(/\s+/g, " ").trim();
}
var Pp0 = "https://mp.weixin.qq.com/mp/appmsgalbum?action=paging&__biz=MzAwMzAzMzU2OA==&album_id=";
var FXt = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/132.0.0.0 Safari/537.36 NetType/WIFI MicroMessenger/7.0.20.1781(0x6700143B) WindowsWechat(0x63090a13) UnifiedPCWindowsWechat(0xf2541412) XWEB/17043 Flue";
function Mp0(e9 = {}) {
  let t = e9.remoteWexConfig, n = { nextnumByCate: /* @__PURE__ */ new Map() };
  return { meta: { key: "sportaiwwe", name: "WWE|\u4F53\u80B2", type: 3 }, async init() {
    return {};
  }, async home() {
    return P0([{ type_id: "3857770410167123977", type_name: "WWE-SD" }, { type_id: "3857775501129433090", type_name: "WWE-PPV" }, { type_id: "3857769598401527818", type_name: "WWE-RAW" }, { type_id: "3857771305349038097", type_name: "WWE-NXT" }, { type_id: "3857773297022681089", type_name: "AEW" }, { type_id: "3857774468558897159", type_name: "TNA" }], {});
  }, async category(s) {
    let c = s.body || {}, l = c.extend || {}, d = ve(l.cateId || c.cateId || c.id || c.tid), m = Number.parseInt(c.page || c.pg || 1, 10) || 1, g = n.nextnumByCate.get(d) || "", y = m === 1 ? `${Pp0}${encodeURIComponent(d)}` : `${Pp0}${encodeURIComponent(d)}&count=10&begin_msgid=${encodeURIComponent(g)}&begin_itemidx=1`, v = await WXt(y), w = jXt(v, s, n, d);
    return Me({ page: m, pagecount: w.length < 10 ? m : m + 1, limit: 10, total: 0, list: w });
  }, async detail(s) {
    let c = ve(Array.isArray(s.body?.id) ? s.body.id[0] : s.body?.id);
    if (!c) throw new Error("WWE\u53C2\u6570\u4E3A\u7A7A");
    let l = c.split("|||"), d = ve(l[0]), m = ve(l.slice(1).join("|||"));
    if (!d || !m) throw new Error("WWE\u53C2\u6570\u9519\u8BEF");
    let g = await VXt(m), y = Pr(g), v = zXt(y("#js_video_page_title").text()), w = GXt(g), T = [];
    for (let I = 0; I < w.length; I++) {
      let N = w[I] || {}, C = ve(N.url);
      C && T.push(`${ve(N.qualityWording, `\u7EBF\u8DEF${I + 1}`)}$${C}&vid=${d}`);
    }
    if (!T.length) throw new Error("WWE\u6682\u65E0\u64AD\u653E\u6570\u636E");
    return l0([b0({ id: d, name: v, pic: "", content: v, director: "", actor: "", vod_play_from: Wn(t), vod_play_url: T.join("#") })]);
  }, async play(s) {
    let c = ve(s.body?.id);
    if (!c) throw new Error("WWE\u64AD\u653E\u5730\u5740\u4E3A\u7A7A");
    return E0({ parse: 0, url: c, header: iY(), extra: { danmaku: "", nodanmu: true } });
  }, async search() {
    return "";
  } };
}
async function WXt(e9) {
  return (await t0.get(e9, { headers: iY(), responseType: "json", timeout: 2e4 })).data || {};
}
async function VXt(e9) {
  let t = await t0.get(e9, { headers: iY(), responseType: "text", transformResponse: [(n) => n], timeout: 2e4 });
  return typeof t.data == "string" ? t.data : JSON.stringify(t.data || {});
}
function jXt(e9, t, n, s) {
  let c = Array.isArray(e9?.getalbum_resp?.article_list) ? e9.getalbum_resp.article_list : [], l = qXt(t), d = [];
  for (let m of c) {
    let g = `${ve(m?.vid)}|||${ve(m?.url)}`;
    if (g === "|||") continue;
    let y = HXt(l, ve(m?.cover_img_1_1));
    d.push(u0({ id: g, name: ve(m?.title), pic: y, remarks: ve(m?.msgid) }));
  }
  return c.length === 10 && d.length && n.nextnumByCate.set(s, ve(d[d.length - 1].vod_remarks)), d;
}
function GXt(e9) {
  let t = [], n = Bp0(e9, /mp_video_trans_info:\s*\[([\s\S]*?)\]/);
  if (n || (n = Bp0(e9, /"mp_video_trans_info"\s*:\s*\[([\s\S]*?)\]/)), !n) return t;
  let s = n.replace(/\r|\n|\t/g, "").replace(/(['"]?\w+['"]?)\s*\*\s*1/g, "$1").replace(/JsDecode\(['"](.*?)['"]\)/g, "$1").replace(/\\x26amp;/g, "&").replace(/&amp;/g, "&").replace(/(?<!\\)\\(?![\\/bfnrtu"])/g, "").replace(/'/g, '"').replace(/([{,])\s*(\w+)\s*:/g, '$1"$2":').replace(/,\s*(?=[}\]])/g, "").replace(/[\x00-\x1F\x7F]/g, "").trim();
  s.startsWith("[") || (s = `[${s}`), s.endsWith("]") || (s = `${s}]`), s = s.replace(/\[+/g, "[").replace(/\]+/g, "]").replace(/\[,/g, "[").replace(/,\]/g, "]");
  let c = Lp0(s, null);
  if (Array.isArray(c) || (c = Lp0(`[${n.replace(/'/g, '"').replace(/([{,])\s*(\w+)\s*:/g, '$1"$2":')}]`, [])), !Array.isArray(c)) return t;
  for (let l = 0; l < c.length; l++) {
    let d = c[l] || {}, m = ve(d.url).replace(/\\\//g, "/").replace(/\\/g, "");
    m && t.push({ url: m, qualityWording: `${ve(d.video_quality_wording)}${l + 1}`, formatId: ve(d.format_id), width: ve(d.width), height: ve(d.height), duration: ve(d.duration), fileSize: ve(d.filesize), qualityLevel: ve(d.video_quality_level) });
  }
  return t;
}
function HXt(e9, t) {
  let n = ve(t);
  if (!n || !e9) return n;
  let s = new URLSearchParams({ url: n, cache: "86400", customHeaders: JSON.stringify(iY()) });
  return `${e9}/imageProxy?${s}`;
}
function qXt(e9 = {}) {
  let t = e9.headers?.["x-forwarded-proto"] || "http", n = e9.headers?.host || "";
  return n ? `${t}://${n}` : "";
}
function iY() {
  return { "User-Agent": FXt, Referer: "https://mp.weixin.qq.com/" };
}
function Bp0(e9, t) {
  let n = String(e9 || "").match(t);
  return n ? ve(n[1]) : "";
}
function Lp0(e9, t) {
  if (e9 && typeof e9 == "object") return e9;
  try {
    return JSON.parse(String(e9 || ""));
  } catch {
    return t;
  }
}
function zXt(e9) {
  return ve(e9).replace(/\s+/g, " ").trim();
}
var Vpe = C0(referenceBuiltin3, 1);
var aer = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36";
var oer = "https://www.bilibili.com";
var ser = [46, 47, 18, 2, 53, 8, 23, 32, 15, 50, 10, 31, 58, 3, 45, 35, 27, 43, 5, 49, 33, 9, 42, 19, 29, 28, 14, 39, 12, 38, 41, 13, 37, 48, 7, 16, 24, 55, 40, 61, 26, 17, 0, 1, 60, 51, 30, 4, 22, 25, 54, 21, 56, 59, 6, 63, 57, 62, 11, 36, 20, 34, 44, 52];
var rw = class {
  constructor({ db: t } = {}) {
    this.db = t, this.cookie = "", this.login = false, this.vip = false, this.mid = "", this.wbi = null;
  }
  async refreshCookie() {
    return this.cookie = String(await this.db?.get?.("/siteCookie/bili/cookie", "") || "").trim(), this.cookie;
  }
  headers(t = true) {
    let n = { "User-Agent": aer, Referer: oer };
    return t && this.cookie && (n.Cookie = this.cookie), n;
  }
  async checkLogin() {
    await this.refreshCookie();
    try {
      let n = (await this.json("https://api.bilibili.com/x/web-interface/nav"))?.data || {};
      this.login = !!n.isLogin, this.vip = !!(n.vipStatus || n.is_vip), this.mid = fr(n.mid), this.wbi = der(n.wbi_img);
    } catch {
      this.login = false, this.vip = false, this.mid = "", this.wbi = null;
    }
    return { login: this.login, vip: this.vip, mid: this.mid };
  }
  async json(t, { cookie: n = true, timeout: s = 15e3 } = {}) {
    return (await t0.get(t, { headers: this.headers(n), responseType: "json", timeout: s, validateStatus: (l) => l < 500 })).data || {};
  }
  async text(t, { cookie: n = true, timeout: s = 15e3 } = {}) {
    let c = await t0.get(t, { headers: this.headers(n), responseType: "text", transformResponse: [(l) => l], timeout: s, validateStatus: (l) => l < 500 });
    return String(c.data || "");
  }
  async signedQuery(t = {}) {
    this.wbi || await this.checkLogin();
    let n = { ...t };
    if (!this.wbi?.mixinKey) return mer(n);
    n.wts = Math.floor(Date.now() / 1e3);
    let s = Object.keys(n).sort().map((c) => `${encodeURIComponent(c)}=${rm0(n[c])}`).join("&");
    return `${s}&w_rid=${her(`${s}${this.wbi.mixinKey}`)}`;
  }
  async searchVideos(t, n = 1, s = {}) {
    let c = { qv_id: ger(32), search_type: "video", web_location: "1430654", page_size: 42, keyword: t, order: s.order || "totalrank", duration: s.duration || "0", page: n }, l = await this.json(`https://api.bilibili.com/x/web-interface/wbi/search/type?${await this.signedQuery(c)}`, { cookie: false }), d = (l?.data?.result || []).map(Yp0).filter(Boolean), m = Number(l?.data?.numResults || l?.data?.numPages * 42 || d.length || 0);
    return { list: d, total: m };
  }
  async upVideos(t, n = 1) {
    let s = await this.signedQuery({ mid: t, pn: n, ps: 50 }), l = (await this.json(`https://api.bilibili.com/x/space/wbi/arc/search?${s}`))?.data || {}, d = (l?.list?.vlist || []).map(Yp0).filter(Boolean), m = Number(l?.page?.count || d.length || 0);
    return { list: d, total: m };
  }
  async videoDetail(t, n) {
    let s = String(n).startsWith("BV") ? `bvid=${encodeURIComponent(n)}` : `aid=${encodeURIComponent(n)}`, c = await this.json(`https://api.bilibili.com/x/web-interface/view?${s}`);
    if (Number(c?.code || 0) !== 0) throw new Error(c?.message || "B\u7AD9\u8BE6\u60C5\u63A5\u53E3\u5931\u8D25");
    let l = c.data || {}, d = fr(l.aid), m = fr(l.bvid), g = await this.playData({ aid: d, bvid: m, cid: fr(l.cid), qn: "127" }), y = tm0(g?.accept_quality || [], g?.accept_description || [], this.login, this.vip), v = y.map((L) => L.qn).join(":"), w = y.map((L) => Jp0(L.name)).join(":"), T = (l.pages || []).map((L, q) => `${ll(L.part) || `P${fr(L.page)}` || q}$${d}+${fr(L.cid)}+${v}+${w}`).filter(Boolean), I = await this.related(m, y).catch(() => []), N = T.join("#"), C = "B\u7AD9", B = N;
    return { vod_id: t, vod_name: ll(l.title), vod_pic: rh(l.pic), type_name: fr(l.tname), vod_year: l.pubdate ? yer(l.pubdate) : void 0, vod_actor: ll(l.owner?.name), vod_content: fr(l.desc), vod_play_from: C, vod_play_url: B };
  }
  async related(t, n) {
    return t ? ((await this.json(`https://api.bilibili.com/x/web-interface/archive/related?bvid=${encodeURIComponent(t)}`))?.data || []).map((c) => {
      let l = fr(c.cid), d = fr(c.aid), m = fr(c.bvid);
      if (!l || !d && !m) return null;
      let g = n.map((v) => v.qn).join(":"), y = n.map((v) => Jp0(v.name)).join(":");
      return `${ll(c.title)}$${d}+${l}+${g}+${y}`;
    }).filter(Boolean) : [];
  }
  async playData({ bvid: t = "", aid: n = "", cid: s = "", media: c = false, qn: l = "127" }) {
    let d;
    if (c && n) {
      d = `https://api.bilibili.com/x/player/playurl?avid=${encodeURIComponent(n)}&cid=${encodeURIComponent(s)}&qn=${encodeURIComponent(l)}&fnval=4048&fourk=1`;
      let m = Qp0(await this.json(d));
      if (m?.dash || m?.accept_quality?.length) return m;
    }
    return c ? d = `https://api.bilibili.com/pgc/player/web/playurl?cid=${encodeURIComponent(s)}&bvid=${encodeURIComponent(t)}&qn=${encodeURIComponent(l)}&fnval=4048&fnver=0&fourk=1` : n ? d = `https://api.bilibili.com/x/player/playurl?avid=${encodeURIComponent(n)}&cid=${encodeURIComponent(s)}&qn=${encodeURIComponent(l)}&fnval=4048&fourk=1` : d = `https://api.bilibili.com/x/player/playurl?cid=${encodeURIComponent(s)}&bvid=${encodeURIComponent(t)}&qn=${encodeURIComponent(l)}&fourk=1&fnval=4048&fnver=0`, Qp0(await this.json(d));
  }
  async mpd(t = {}) {
    let n = await this.playData(t);
    if (!n?.dash) throw new Error("B\u7AD9 dash \u4E3A\u7A7A");
    return xer(n.dash, t.qn || "", t.proxyBaseUrl || "");
  }
};
function oY(e9) {
  try {
    return JSON.parse(Buffer.from(String(e9), "base64url").toString("utf8"));
  } catch {
    try {
      return JSON.parse(String(e9 || "{}"));
    } catch {
      return {};
    }
  }
}
function Xp0(e9) {
  return Buffer.from(JSON.stringify(e9), "utf8").toString("base64url");
}
function em0(e9, t, n) {
  return tm0(e9?.accept_quality || [], e9?.accept_description || [], t, n);
}
function ll(e9) {
  return String(e9 || "").replace(/<[^>]*>/g, "").replace(/[#$/]/g, "|").trim();
}
function rh(e9) {
  let t = fr(e9);
  return t ? t.startsWith("//") ? `https:${t}` : /^https?:\/\//i.test(t) ? t : `https://${t.replace(/^:+/, "").replace(/^\/+/, "")}` : "";
}
function fr(e9, t = "") {
  return e9 == null ? t : String(e9);
}
function rO(e9) {
  let t = Math.max(0, Number(e9 || 0)), n = Math.floor(t / 3600), s = Math.floor(t % 3600 / 60), c = Math.floor(t % 60);
  return n ? `${n}:${String(s).padStart(2, "0")}:${String(c).padStart(2, "0")}` : `${s}:${String(c).padStart(2, "0")}`;
}
function Yp0(e9 = {}) {
  let t = fr(e9.bvid), n = fr(e9.aid);
  return !t && !n ? null : { vod_id: `${t || n}@${n || ""}`, vod_name: ll(e9.title), vod_pic: rh(e9.pic || e9.cover), vod_remarks: e9.duration ? ber(e9.duration) : fr(e9.length || e9.index_show), style: { type: "rect", ratio: 1.33 } };
}
function tm0(e9, t, n, s) {
  let c = [];
  for (let l = 0; l < e9.length; l++) {
    let d = Number(e9[l]);
    !n && d > 32 || !s && d > 80 || c.push({ qn: String(d), name: fr(t[l], String(d)) });
  }
  return c.length || c.push({ qn: "80", name: "\u9ED8\u8BA4" }), c;
}
function Qp0(e9) {
  return e9?.result || e9?.data || {};
}
function xer(e9 = {}, t = "", n = "") {
  let s = cer(e9.video || [], t).map((m) => Zp0(m, n)).filter(Boolean).join(`
`), c = (e9.audio || []).map((m) => Zp0(m, n)).filter(Boolean).join(`
`), l = e9.duration || 0, d = e9.minBufferTime || e9.min_buffer_time || 1.5;
  return `<MPD xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xmlns="urn:mpeg:dash:schema:mpd:2011" xsi:schemaLocation="urn:mpeg:dash:schema:mpd:2011 DASH-MPD.xsd" type="static" mediaPresentationDuration="PT${pu(l)}S" minBufferTime="PT${pu(d)}S" profiles="urn:mpeg:dash:profile:isoff-on-demand:2011">
<Period duration="PT${pu(l)}S" start="PT0S">
${s}
${c}
</Period>
</MPD>`;
}
function cer(e9, t) {
  let n = t ? e9.filter((m) => String(m.id) === String(t)) : e9.slice(), s = n.length ? n : e9.slice(), c = s.find((m) => String(m.codecs || "").startsWith("avc1")), l = s.find((m) => /^(hev1|hvc1)/.test(String(m.codecs || ""))), d = s.find((m) => String(m.codecs || "").startsWith("av01"));
  return [c || l || d || s[0]].filter(Boolean);
}
function Zp0(e9 = {}, t = "") {
  let n = e9.segment_base || e9.segmentBase, s = uer(e9), c = fr(e9.mime_type || e9.mimeType);
  if (!n || !s || !c) return "";
  let l = c.split("/")[0], d = l === "video" ? `height="${pu(e9.height)}" width="${pu(e9.width)}" frameRate="${pu(e9.frame_rate || e9.frameRate || "")}" sar="${pu(e9.sar || "")}"` : 'numChannels="2" sampleRate="44100"', m = `${fr(e9.id)}_${fr(e9.codecid || e9.codec_id || e9.codecId)}`, g = t ? `${t}/${Buffer.from(s, "utf8").toString("base64url")}.m4s` : s;
  return `<AdaptationSet>
<ContentComponent contentType="${pu(l)}"/>
<Representation id="${pu(m)}" bandwidth="${pu(e9.bandwidth || e9.bandWidth || "")}" codecs="${pu(e9.codecs || "")}" mimeType="${pu(c)}" ${d} startWithSAP="${pu(e9.start_with_sap || e9.startWithSap || "")}">
<BaseURL><![CDATA[${g.replace(/&/g, "&amp;")}]]></BaseURL>
<SegmentBase indexRange="${pu(n.index_range || n.indexRange || "")}">
<Initialization range="${pu(n.initialization || "")}"/>
</SegmentBase>
</Representation>
</AdaptationSet>`;
}
function uer(e9 = {}) {
  let t = [...fer(e9.backup_url || e9.backupUrl), fr(e9.base_url || e9.baseUrl)].filter(Boolean);
  for (let n of t) if (!ler(n)) return n;
  return t[0] || "";
}
function ler(e9) {
  try {
    return !!new URL(e9).port;
  } catch {
    return false;
  }
}
function fer(e9) {
  if (Array.isArray(e9)) return e9.map((n) => fr(n)).filter(Boolean);
  let t = fr(e9);
  return t ? [t] : [];
}
function der(e9 = {}) {
  let t = Kp0(fr(e9.img_url), /wbi\/(.*?).png/), n = Kp0(fr(e9.sub_url), /wbi\/(.*?).png/);
  return !t || !n ? null : { imgKey: t, subKey: n, mixinKey: per(`${t}${n}`) };
}
function per(e9) {
  return ser.map((t) => e9[t] || "").join("").slice(0, 32);
}
function mer(e9) {
  return Object.keys(e9).map((t) => `${encodeURIComponent(t)}=${rm0(e9[t])}`).join("&");
}
function rm0(e9) {
  return encodeURIComponent(String(e9 ?? "").replace(/[!'()*]/g, ""));
}
function her(e9) {
  return Vpe.default.createHash("md5").update(e9).digest("hex");
}
function ger(e9) {
  return Vpe.default.randomBytes(e9).toString("hex").slice(0, e9);
}
function Kp0(e9, t) {
  let n = String(e9 || "").match(t);
  return n ? n[1] : "";
}
function ber(e9) {
  let t = fr(e9);
  return /^\d+$/.test(t) ? rO(Number(t)) : t;
}
function Jp0(e9) {
  return Buffer.from(String(e9 || ""), "utf8").toString("base64");
}
function yer(e9) {
  let t = new Date(Number(e9) * 1e3);
  return Number.isNaN(t.getTime()) ? "" : `${t.getFullYear()}-${String(t.getMonth() + 1).padStart(2, "0")}-${String(t.getDate()).padStart(2, "0")}`;
}
function pu(e9) {
  return String(e9 ?? "").replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
}
var Aer = "B\u7AD9";
function om0(e9 = {}) {
  let t = new rw({ db: e9.db }), n = /* @__PURE__ */ new Map();
  return { meta: { key: "biliys", name: "\u54D4\u54E9|\u5F71\u89C6", type: 3 }, async init() {
    return await t.checkLogin(), {};
  }, async home() {
    await t.checkLogin();
    let s = [];
    t.login && (s.push(nh(nc("\u52A8\u6001", "\u52A8\u6001"), "\u52A8\u6001")), s.push(nh(nc("\u6536\u85CF\u5939", "\u6536\u85CF\u5939"), "\u6536\u85CF\u5939")), s.push(nh(nc("\u5386\u53F2\u8BB0\u5F55", "\u5386\u53F2\u8BB0\u5F55"), "\u5386\u53F2\u8BB0\u5F55"))), s.push(nh(nc("\u756A\u5267", "1"), "\u756A\u5267")), s.push(nh(nc("\u756A\u5267", "4"), "\u56FD\u521B")), s.push(nh(nc("\u756A\u5267", "2"), "\u7535\u5F71")), s.push(nh(nc("\u756A\u5267", "5"), "\u5267\u96C6")), s.push(nh(nc("\u756A\u5267", "7"), "\u7EFC\u827A")), s.push(nh(nc("\u756A\u5267", "3"), "\u7EAA\u5F55\u7247"));
    let c = {};
    for (let l of s) String(l.type_id).includes('"\u756A\u5267"') && (c[l.type_id] = ker());
    return P0(s, c);
  }, async category(s) {
    await t.checkLogin();
    let c = s.body || {}, l = nm0(c.id || c.tid), d = fr(l.cate), m = im0(c.page || c.pg || 1);
    return d === "\u52A8\u6001" ? ver(t, n, m) : d === "\u6536\u85CF\u5939" ? _er(t, fr(l.id), m) : d === "\u5386\u53F2\u8BB0\u5F55" ? wer(t, m) : d === "\u756A\u5267" ? Ser(t, fr(l.id), m, c.extend || c.filters || {}) : d === "UP\u4E3B" ? Eer(t, l, m) : Ter(t, fr(l.id), m);
  }, async detail(s) {
    await t.checkLogin();
    let c = Array.isArray(s.body?.id) ? s.body.id : [s.body?.id], l = [];
    for (let d of c.filter(Boolean)) {
      let m = nm0(d);
      m.cate === "\u756A\u5267" ? l.push(await Ier(t, String(d), fr(m.id))) : l.push(await Rer(t, String(d), fr(m.id || m.bvid || d)));
    }
    return l0(l);
  }, async play(s) {
    await t.checkLogin();
    let c = String(s.body?.id || ""), l = Oer(c) || oY(c), d = l.qualities || em0(await t.playData(l), t.login, t.vip), m = am0(s), g = [];
    for (let y of d) if (l.aid && l.cid && !l.media) g.push(y.name, `${m}/spider/biliys/3/proxy/mpd/${encodeURIComponent(l.aid)}/${encodeURIComponent(l.cid)}/${encodeURIComponent(y.qn)}/.bin`);
    else {
      let v = encodeURIComponent(JSON.stringify({ ...l, qn: y.qn }));
      g.push(y.name, `${m}/spider/biliys/3/proxy/mpd/0?id=${v}`);
    }
    if (!g.length) {
      let y = encodeURIComponent(JSON.stringify({ ...l, qn: "80" }));
      g.push("\u9ED8\u8BA4", `${m}/spider/biliys/3/proxy/mpd/0?id=${y}`);
    }
    return E0({ parse: 0, url: g, header: Ber(), extra: { danmaku: l.cid ? `https://api.bilibili.com/x/v1/dm/list.so?oid=${l.cid}` : void 0 } });
  }, async search(s) {
    await t.checkLogin();
    let c = s.body || {}, l = fr(c.wd || c.key).trim();
    if (!l) return Me({ list: [] });
    let d = im0(c.page || c.pg || 1), m = [], g = 0;
    for (let [y, v] of [["media_ft", "\u5F71\u89C6"], ["media_bangumi", "\u756A\u5267"]]) {
      let T = (await Cer(t, l, d, y))?.data || {};
      g += Math.max(0, Number(T.numResults || 0)), m.push(...Ner(T, v));
    }
    return Me({ page: d, pagecount: g > d * 20 ? d + 1 : d, limit: 20, total: g || m.length, list: m });
  }, async proxy(s, c) {
    if (Ler(s)) return Mer(t, s, c);
    let l = Der(s);
    l.proxyBaseUrl = `${am0(s)}/spider/biliys/3/proxy/seg`;
    let d = await t.mpd(l);
    return c.header("content-type", "application/dash+xml; charset=utf-8"), d;
  } };
}
function nh(e9, t) {
  return { type_id: e9, type_name: t, style: { type: "rect", ratio: 1.33 } };
}
function nc(e9, t, n = "", s = "") {
  let c = { cate: e9, id: t };
  return n && (c.type = n), s && (c.name = s), JSON.stringify(c);
}
function ker() {
  return [{ key: "order", name: "\u6392\u5E8F", value: [{ n: "\u66F4\u65B0\u65F6\u95F4", v: "0" }, { n: "\u64AD\u653E\u6570\u91CF", v: "2" }, { n: "\u6700\u9AD8\u8BC4\u5206", v: "4" }, { n: "\u5F00\u64AD\u65F6\u95F4", v: "5" }] }, { key: "season_status", name: "\u4ED8\u8D39", value: [{ n: "\u5168\u90E8", v: "" }, { n: "\u514D\u8D39", v: "1" }, { n: "\u4ED8\u8D39", v: "2,6" }, { n: "\u5927\u4F1A\u5458", v: "4,6" }] }, { key: "is_finish", name: "\u72B6\u6001", value: [{ n: "\u5168\u90E8", v: "" }, { n: "\u8FDE\u8F7D", v: "0" }, { n: "\u5B8C\u7ED3", v: "1" }] }, { key: "season_month", name: "\u5B63\u5EA6", value: [{ n: "\u5168\u90E8", v: "" }, { n: "1\u6708", v: "1" }, { n: "4\u6708", v: "4" }, { n: "7\u6708", v: "7" }, { n: "10\u6708", v: "10" }] }, { key: "year", name: "\u5E74\u4EFD", value: [{ n: "\u5168\u90E8", v: "" }, { n: "2026", v: "2026" }, { n: "2025", v: "2025" }, { n: "2024", v: "2024" }, { n: "2023", v: "2023" }, { n: "2022", v: "2022" }, { n: "2021", v: "2021" }, { n: "2020", v: "2020" }] }];
}
async function ver(e9, t, n) {
  let s = `https://api.bilibili.com/x/polymer/web-dynamic/v1/feed/all?timezone_offset=-480&type=all&page=${n}`;
  n > 1 && t.has("dynamic") && (s += `&offset=${encodeURIComponent(t.get("dynamic"))}`);
  let l = (await e9.json(s))?.data || {}, d = [];
  for (let m of l.items || []) {
    if (m.type !== "DYNAMIC_TYPE_AV") continue;
    let g = m.modules?.module_dynamic?.major?.archive || {};
    g.bvid && d.push(u0({ id: nc("\u5176\u4ED6", g.bvid), name: ll(g.title), pic: rh(g.cover), remarks: fr(g.duration_text), style: { type: "rect", ratio: 1.33 } }));
  }
  return l.offset && t.set("dynamic", l.offset), Me({ page: n, pagecount: l.has_more ? n + 1 : n, limit: d.length, total: d.length, list: d });
}
async function _er(e9, t, n) {
  let s = [];
  if (t === "\u6536\u85CF\u5939") {
    let l = e9.mid || (await e9.checkLogin()).mid, d = await e9.json(`https://api.bilibili.com/x/v3/fav/folder/created/list-all?up_mid=${encodeURIComponent(l)}&jsonp=jsonp`);
    for (let m of d?.data?.list || []) s.push(Qa({ id: nc("\u6536\u85CF\u5939", m.id), name: ll(m.title), remarks: fr(m.media_count), style: { type: "rect", ratio: 1.33 } }));
    return Me({ page: n, pagecount: n, limit: s.length, total: s.length, list: s });
  }
  let c = await e9.json(`https://api.bilibili.com/x/v3/fav/resource/list?media_id=${encodeURIComponent(t)}&pn=${n}&ps=20&platform=web&type=0`);
  for (let l of c?.data?.medias || []) s.push(u0({ id: nc("\u5176\u4ED6", l.bvid), name: ll(l.title), pic: rh(l.cover), remarks: rO(l.duration), style: { type: "rect", ratio: 1.33 } }));
  return Me({ page: n, pagecount: c?.data?.has_more ? n + 1 : n, limit: 20, total: s.length, list: s });
}
async function wer(e9, t) {
  let n = await e9.json(`https://api.bilibili.com/x/v2/history?pn=${t}`), s = Array.isArray(n?.data) ? n.data : [];
  s.length || (n = await e9.json("https://api.bilibili.com/x/web-interface/history/cursor?max=0&view_at=0&business=archive&ps=20"), s = n?.data?.list || []);
  let c = s.map((l) => {
    let d = l.history || {}, m = l.bvid || d.bvid;
    return m ? u0({ id: nc("\u5176\u4ED6", m), name: ll(l.title), pic: rh(l.pic), remarks: `${rO(l.progress)}|${rO(l.duration)}`, style: { type: "rect", ratio: 1.33 } }) : null;
  }).filter(Boolean);
  return Me({ page: t, pagecount: t, limit: c.length, total: c.length, list: c });
}
async function Ser(e9, t, n, s) {
  let c = new URLSearchParams({ pagesize: "20", type: "1", st: t, season_type: t, page: String(n), sort: s.order || "0" });
  for (let [g, y] of Object.entries(s || {})) g !== "order" && y && c.set(g, y);
  let d = (await e9.json(`https://api.bilibili.com/pgc/season/index/result?${c}`))?.data || {}, m = (d.list || []).map((g) => u0({ id: nc("\u756A\u5267", g.season_id), name: ll(g.title), pic: rh(g.cover), remarks: fr(g.index_show), style: { type: "rect", ratio: 1.33 } }));
  return Me({ page: n, pagecount: Number(d.has_next) === 1 ? n + 1 : n, limit: 20, total: m.length, list: m });
}
async function Eer(e9, t, n) {
  let s = fr(t.id), c = fr(t.type);
  if (c === "\u5168\u90E8") {
    let l = [Qa({ id: nc("UP\u4E3B", s, "\u89C6\u9891", t.name), name: "\u89C6\u9891", style: { type: "rect", ratio: 1.33 } }), Qa({ id: nc("UP\u4E3B", s, "\u5408\u96C6", t.name), name: "\u5408\u96C6", style: { type: "rect", ratio: 1.33 } })];
    return Me({ page: n, pagecount: n, list: l });
  }
  if (c === "\u89C6\u9891" || !c) {
    let { list: l, total: d } = await e9.upVideos(s, n);
    return Me({ page: n, pagecount: d > n * 50 ? n + 1 : n, limit: 50, total: d, list: l });
  }
  return Me({ page: n, list: [] });
}
async function Ter(e9, t, n) {
  let { list: s, total: c } = await e9.searchVideos(t, n, {});
  return Me({ page: n, pagecount: c > n * 42 ? n + 1 : n, limit: 42, total: c, list: s });
}
async function Ier(e9, t, n) {
  let c = (await e9.json(`https://api.bilibili.com/pgc/view/web/season?season_id=${encodeURIComponent(n)}`))?.result || {}, l = [];
  for (let d of c.episodes || []) !d.bvid || !d.cid || l.push(`${ll(d.share_copy || d.title || d.long_title)}$${Xp0({ bvid: d.bvid, aid: fr(d.aid), cid: fr(d.cid), media: true })}`);
  return b0({ id: t, name: ll(c.title), pic: rh(c.cover), content: fr(c.evaluate), type_name: fr(c.share_sub_title).replace(/，/g, "|"), vod_play_from: Aer, vod_play_url: l.join("#") });
}
async function Rer(e9, t, n) {
  let [s, c] = String(n || "").split("@"), l = await e9.videoDetail(t, s || c);
  return b0(l);
}
async function Cer(e9, t, n, s) {
  let c = await e9.signedQuery({ page: n, keyword: t, search_type: s });
  return e9.json(`https://api.bilibili.com/x/web-interface/wbi/search/type?${c}`);
}
function Ner(e9, t) {
  return (e9.result || []).map((n) => {
    if (!n.season_id) return null;
    let s = n.index_show ? `${t}|${n.index_show}` : t;
    return u0({ id: nc("\u756A\u5267", n.season_id), name: ll(n.title), pic: rh(n.cover), remarks: s, style: { type: "rect", ratio: 1.33 } });
  }).filter(Boolean);
}
function nm0(e9) {
  try {
    return JSON.parse(String(e9 || "{}"));
  } catch {
    return { cate: "\u5176\u4ED6", id: String(e9 || "") };
  }
}
function im0(e9, t = 1) {
  let n = Number(e9);
  return Number.isFinite(n) && n > 0 ? Math.floor(n) : t;
}
function am0(e9) {
  let t = e9.headers?.["x-forwarded-proto"] || "http", n = e9.headers?.host || "127.0.0.1:9988";
  return `${t}://${n}`;
}
function Oer(e9) {
  let t = String(e9 || "").split("+");
  if (t.length < 4) return null;
  let [n, s, c, l] = t, d = c.split(":").filter(Boolean), m = l.split(":").map(Per);
  return { aid: n, cid: s, media: false, qualities: d.map((g, y) => ({ qn: g, name: m[y] || g })) };
}
function Der(e9) {
  let t = fr(e9.params?.["*"]);
  if (t) {
    let n = t.split("/").filter((s) => s && s !== ".bin");
    if (n[0] === "mpd" && n.length >= 4) return { aid: n[1], cid: n[2], qn: n[3], media: false };
  }
  return e9.query?.id ? JSON.parse(fr(e9.query.id, "{}")) : {};
}
function Per(e9) {
  try {
    return Buffer.from(String(e9 || ""), "base64").toString("utf8") || String(e9 || "");
  } catch {
    return String(e9 || "");
  }
}
function Ber() {
  return { Referer: "https://www.bilibili.com", "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36" };
}
function Ler(e9) {
  return fr(e9.params?.provider) === "seg" || fr(e9.params?.["*"]).split("/")[0] === "seg";
}
async function Mer(e9, t, n) {
  let s = Uer(t);
  if (!s) return n.code(400), "missing segment url";
  let c = Buffer.from(s, "base64url").toString("utf8"), l = e9.headers(true);
  t.headers?.range && (l.Range = t.headers.range);
  let d = await t0.get(c, { headers: l, responseType: "stream", timeout: 3e4, validateStatus: () => true });
  n.code(d.status);
  for (let m of ["content-type", "content-length", "content-range", "accept-ranges"]) d.headers[m] && n.header(m, d.headers[m]);
  return d.data;
}
function Uer(e9) {
  let t = fr(e9.query?.url);
  if (t) return t;
  let n = fr(e9.params?.sessionId);
  if (n) return n.replace(/\.m4s$/i, "");
  let c = fr(e9.params?.["*"]).split("/").filter(Boolean);
  return c[0] === "seg" ? fr(c[1]).replace(/\.m4s$/i, "") : "";
}
var cm0 = [{ key: "order", name: "\u6392\u5E8F", value: [{ n: "\u7EFC\u5408\u6392\u5E8F", v: "totalrank" }, { n: "\u6700\u591A\u70B9\u51FB", v: "click" }, { n: "\u6700\u65B0\u53D1\u5E03", v: "pubdate" }, { n: "\u6700\u591A\u5F39\u5E55", v: "dm" }, { n: "\u6700\u591A\u6536\u85CF", v: "stow" }] }, { key: "duration", name: "\u65F6\u957F", value: [{ n: "\u5168\u90E8\u65F6\u957F", v: "0" }, { n: "60\u5206\u949F\u4EE5\u4E0A", v: "4" }, { n: "30~60\u5206\u949F", v: "3" }, { n: "10~30\u5206\u949F", v: "2" }, { n: "10\u5206\u949F\u4EE5\u4E0B", v: "1" }] }];
function $er(e9 = {}, t = {}) {
  let n = new rw({ db: e9.db }), s = { key: t.key, name: t.name, type: 3, searchable: t.searchable ?? 1, quickSearch: t.quickSearch ?? 1, filterable: t.filterable ?? 1, changeable: t.changeable, style: t.style }, c = { remoteHome: null };
  return { meta: s, async init() {
    return await n.checkLogin(), {};
  }, async home() {
    if (await n.checkLogin(), t.extJson) return c.remoteHome = await Fer(n, t.extJson), c.remoteHome;
    let d = String(t.type || "").split("#").map((g) => g.trim()).filter(Boolean).map((g) => ({ type_id: g, type_name: g, style: t.style || { type: "rect", ratio: 1.33 } })), m = {};
    for (let g of d) m[g.type_id] = cm0;
    return P0(d, m);
  }, async category(l) {
    await n.checkLogin();
    let d = l.body || {}, m = fr(d.id || d.tid), g = sm0(d.page || d.pg || 1), y = d.extend || d.filters || {};
    if (m.endsWith("/{pg}")) {
      let I = m.split("/")[0], { list: N, total: C } = await n.upVideos(I, g);
      return Me({ page: g, pagecount: C > g * 50 ? g + 1 : g, limit: 50, total: C, list: N });
    }
    let v = y.tid ? `${m} ${y.tid}` : m, { list: w, total: T } = await n.searchVideos(v, g, y);
    return Me({ page: g, pagecount: T > g * 42 ? g + 1 : g, limit: 42, total: T, list: w });
  }, async detail(l) {
    await n.checkLogin();
    let d = Array.isArray(l.body?.id) ? l.body.id : [l.body?.id], m = [];
    for (let g of d.filter(Boolean)) {
      let [y, v] = String(g).split("@");
      m.push(b0(await n.videoDetail(String(g), y || v)));
    }
    return l0(m);
  }, async play(l) {
    await n.checkLogin();
    let d = String(l.body?.id || ""), m = Ver(d) || oY(d), g = m.qualities || [{ qn: m.qn || "80", name: "\u9ED8\u8BA4" }], y = xm0(l), v = [];
    for (let w of g) v.push(w.name, `${y}/spider/${encodeURIComponent(s.key)}/3/proxy/mpd/${encodeURIComponent(m.aid)}/${encodeURIComponent(m.cid)}/${encodeURIComponent(w.qn)}/.bin`);
    return E0({ parse: 0, url: v, header: Wer(), extra: { danmaku: m.cid ? `https://api.bilibili.com/x/v1/dm/list.so?oid=${m.cid}` : void 0 } });
  }, async search(l) {
    await n.checkLogin();
    let d = l.body || {}, m = fr(d.wd || d.key).trim();
    if (!m) return Me({ list: [] });
    let g = sm0(d.page || d.pg || 1), { list: y, total: v } = await n.searchVideos(m, g, {});
    return Me({ page: g, pagecount: v > g * 42 ? g + 1 : g, limit: 42, total: v, list: y });
  }, async proxy(l, d) {
    if (Ger(l)) return Her(n, l, d);
    let m = jer(l);
    m.proxyBaseUrl = `${xm0(l)}/spider/${encodeURIComponent(s.key)}/3/proxy/seg`;
    let g = await n.mpd(m);
    return d.header("content-type", "application/dash+xml; charset=utf-8"), d.header("cache-control", "no-cache"), g;
  } };
}
async function Fer(e9, t) {
  let n = await e9.text(t, { cookie: false, timeout: 2e4 }), s = JSON.parse(n);
  if (s?.class && !s.filters) {
    let c = {};
    for (let l of s.class || []) c[l.type_id] = cm0;
    s.filters = c;
  }
  return s;
}
function sm0(e9, t = 1) {
  let n = Number(e9);
  return Number.isFinite(n) && n > 0 ? Math.floor(n) : t;
}
function xm0(e9) {
  let t = e9.headers?.["x-forwarded-proto"] || "http", n = e9.headers?.host || "127.0.0.1:9988";
  return `${t}://${n}`;
}
function Wer() {
  return { Referer: "https://www.bilibili.com", "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36" };
}
function Ver(e9) {
  let t = String(e9 || "").split("+");
  if (t.length < 4) return null;
  let [n, s, c, l] = t, d = c.split(":").filter(Boolean), m = l.split(":").map(zer);
  return { aid: n, cid: s, media: false, qualities: d.map((g, y) => ({ qn: g, name: m[y] || g })) };
}
function jer(e9) {
  let t = fr(e9.params?.["*"]);
  if (t) {
    let n = t.split("/").filter((s) => s && s !== ".bin");
    if (n[0] === "mpd" && n.length >= 4) return { aid: n[1], cid: n[2], qn: n[3], media: false };
  }
  return e9.query?.id ? JSON.parse(fr(e9.query.id, "{}")) : {};
}
function Ger(e9) {
  return fr(e9.params?.provider) === "seg" || fr(e9.params?.["*"]).split("/")[0] === "seg";
}
async function Her(e9, t, n) {
  let s = qer(t);
  if (!s) return n.code(400), "missing segment url";
  let c = Buffer.from(s, "base64url").toString("utf8"), l = e9.headers(true);
  t.headers?.range && (l.Range = t.headers.range);
  let d = await t0.get(c, { headers: l, responseType: "stream", timeout: 3e4, validateStatus: () => true });
  n.code(d.status);
  for (let m of ["content-type", "content-length", "content-range", "accept-ranges"]) d.headers[m] && n.header(m, d.headers[m]);
  return d.data;
}
function qer(e9) {
  let t = fr(e9.query?.url);
  if (t) return t;
  let n = fr(e9.params?.sessionId);
  if (n) return n.replace(/\.m4s$/i, "");
  let c = fr(e9.params?.["*"]).split("/").filter(Boolean);
  return c[0] === "seg" ? fr(c[1]).replace(/\.m4s$/i, "") : "";
}
function zer(e9) {
  try {
    return Buffer.from(String(e9 || ""), "base64").toString("utf8") || String(e9 || "");
  } catch {
    return String(e9 || "");
  }
}
var Yer = [{ key: "bilibili", name: "\u54D4\u54E9|\u5408\u96C6", extJson: "https://support-chat.rongcloud.cn/rails/active_storage/blobs/redirect/eyJfcmFpbHMiOnsibWVzc2FnZSI6IkJBaHBBYkE9IiwiZXhwIjpudWxsLCJwdXIiOiJibG9iX2lkIn19--47a8ff0e68559a89a9a75b37d09a2b0854dc5a8a/bili001.txt" }, { key: "bilixiqu", name: "\u54D4\u54E9|\u620F\u66F2", extJson: "https://storage.7x24cc.com/storage-server/presigned/ss1/a6-online-fileupload/newMediaImage/183E562_773_xiqu_20251130182006749newMediaImage.txt" }, { key: "biliych", name: "\u54D4\u54E9|\u6B4C\u66F2", extJson: "https://support-chat.rongcloud.cn/rails/active_storage/blobs/redirect/eyJfcmFpbHMiOnsibWVzc2FnZSI6IkJBaHBBYkU9IiwiZXhwIjpudWxsLCJwdXIiOiJibG9iX2lkIn19--3083f43a14e6b59f4bfe248478a3a8765b34bfdd/bilisong.txt" }, { key: "\u5C11\u513F\u6559\u80B2", name: "\u5C11\u513F|\u6559\u80B2", extJson: "https://storage.7x24cc.com/storage-server/presigned/ss1/a6-online-fileupload/newMediaImage/3C3AB7A_773_ertong_20250828171550247newMediaImage.txt" }, { key: "\u5C0F\u5B66\u8BFE\u5802", name: "\u5C0F\u5B66|\u8BFE\u5802", extJson: "https://storage.7x24cc.com/storage-server/presigned/ss1/a6-online-fileupload/newMediaImage/4A3AA71_773_xiaoxue_20250828171535645newMediaImage.txt" }, { key: "\u521D\u4E2D\u8BFE\u5802", name: "\u521D\u4E2D|\u8BFE\u5802", extJson: "https://storage.7x24cc.com/storage-server/presigned/ss1/a6-online-fileupload/newMediaImage/19B1839_773_chuzhong_20250828171521929newMediaImage.txt" }, { key: "\u9AD8\u4E2D\u6559\u80B2", name: "\u9AD8\u4E2D|\u8BFE\u5802", extJson: "https://storage.7x24cc.com/storage-server/presigned/ss1/a6-online-fileupload/newMediaImage/345A587_773_gaozhong_20250828171449997newMediaImage.txt" }];
var k0r = "http://caiji.dyttzyapi.com/api.php/provide/vod/";
var v0r = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36";
function Cm0(e9 = {}) {
  let t = { classes: [], remoteWexConfig: e9.remoteWexConfig };
  return { meta: { key: "wexaitiantang", name: "\u5929\u5802|\u91C7\u96C6", type: 3 }, async init() {
    return await Im0(t), {};
  }, async home() {
    return await Im0(t), P0(t.classes, {});
  }, async category(n) {
    let s = n.body || {}, c = s.extend || {}, l = J2(s.page || s.pg || 1), d = T7(c.cateId || s.id || s.tid), m = d ? `?ac=detail&t=${encodeURIComponent(d)}&pg=${l}` : `?ac=detail&pg=${l}`, g = await dY(m);
    return Me({ page: J2(g.page, l), pagecount: J2(g.pagecount, Number.MAX_SAFE_INTEGER), limit: J2(g.limit, 20), total: J2(g.total, Number.MAX_SAFE_INTEGER), list: Rm0(g) });
  }, async detail(n) {
    let s = Array.isArray(n.body?.id) ? n.body.id : [n.body?.id], c = [];
    for (let l of s.filter(Boolean)) c.push(await _0r(t, String(l)));
    return l0(c);
  }, async play(n) {
    return E0({ parse: 0, url: T7(n.body?.id), header: Nm0() });
  }, async search(n) {
    let s = T7(n.body?.wd || n.body?.key), c = J2(n.body?.page || n.body?.pg || 1);
    if (!s) return Me({ page: c, pagecount: 1, list: [] });
    let l = await dY(`?ac=detail&pg=${c}&wd=${encodeURIComponent(s)}`);
    return Me({ page: J2(l.page, c), pagecount: J2(l.pagecount, 1), limit: J2(l.limit, 20), total: J2(l.total, 0), list: Rm0(l) });
  } };
}
async function Im0(e9) {
  if (e9.classes.length) return;
  let t = await dY("?ac=list"), n = Array.isArray(t?.class) ? t.class : [];
  e9.classes = n.filter((s) => J2(s?.type_pid, 0) > 0).map((s) => ({ type_id: T7(s?.type_id), type_name: T7(s?.type_name) })).filter((s) => s.type_id && s.type_name);
}
async function _0r(e9, t) {
  let n = await dY(`?ac=detail&ids=${encodeURIComponent(t)}`), s = Array.isArray(n?.list) ? n.list[0] : null;
  if (!s) throw new Error("\u5929\u5802\u5F71\u89C6\u8BE6\u60C5\u4E3A\u7A7A");
  let c = E0r(s.vod_play_from, s.vod_play_url);
  return b0({ id: t, name: s.vod_name, pic: s.vod_pic, year: s.vod_year, area: s.vod_area, content: T0r(s.vod_content || s.vod_blurb), director: s.vod_director, actor: s.vod_actor, vod_play_from: w0r(e9, c.from), vod_play_url: c.url });
}
async function dY(e9) {
  return (await t0.get(`${k0r}${e9}`, { headers: Nm0(), responseType: "json", timeout: 2e4 })).data || {};
}
function Rm0(e9) {
  return (Array.isArray(e9?.list) ? e9.list : []).map((n) => u0({ id: n?.vod_id, name: n?.vod_name, pic: n?.vod_pic, remarks: n?.vod_remarks || n?.vod_time, typeName: n?.type_name })).filter((n) => n.vod_id && n.vod_name);
}
function w0r(e9, t) {
  let n = T7(e9.remoteWexConfig?.Wexconfig?.vodfrom);
  return n ? t ? S0r(t).map(() => n).join("$$$") : n : t || "\u64AD\u653E";
}
function S0r(e9) {
  return String(e9 || "").split("$$$").filter(Boolean);
}
function E0r(e9, t) {
  let n = String(e9 || "").split("$$$"), s = String(t || "").split("$$$"), c = n.findIndex((l) => T7(l).toLowerCase().includes("m3u8"));
  return c >= 0 && s[c] ? { from: n[c], url: s[c] } : { from: e9, url: t };
}
function Nm0() {
  return { "User-Agent": v0r };
}
function T0r(e9) {
  return T7(e9).replace(/<br\s*\/?>/gi, `
`).replace(/<[^>]+>/g, "").replace(/&nbsp;/gi, " ").replace(/&amp;/gi, "&").trim();
}
function T7(e9, t = "") {
  return e9 == null || e9 === "" ? t : String(e9);
}
function J2(e9, t = 1) {
  let n = Number.parseInt(e9, 10);
  return Number.isFinite(n) && n > 0 ? n : t;
}
var LZ0 = "jsjiami.com.v7";
var Wi = Sp;
(function(e9, t, n, s, c, l, d) {
  return e9 = e9 >> 8, l = "hs", d = "hs", (function(m, g, y, v, w) {
    let T = Sp;
    v = "tfi", l = v + l, w = "up", d += w, l = y(l), d = y(d), y = 0;
    let I = m();
    for (; --s + g; ) try {
      v = -parseInt(T(608, "eEa&")) / 1 + parseInt(T(539, "*bug")) / 2 * (parseInt(T(527, "ID5C")) / 3) + -parseInt(T(567, "[@RP")) / 4 + -parseInt(T(383, "8kJg")) / 5 * (-parseInt(T(601, "coDu")) / 6) + parseInt(T(586, "g*bE")) / 7 * (-parseInt(T(560, "0NI1")) / 8) + parseInt(T(596, "1RNE")) / 9 + parseInt(T(558, "ZNM^")) / 10;
    } catch {
      v = y;
    } finally {
      if (w = I[l](), e9 <= s) y ? c ? v = w : c = w : y = w;
      else if (y == c.replace(/[MrheFEXVgHwPfbGnYSB=]/g, "")) {
        if (v === g) {
          I["un" + l](w);
          break;
        }
        I[d](w);
      }
    }
  })(n, t, function(m, g, y, v, w, T, I) {
    return g = "split", m = arguments[0], m = m[g](""), y = "reverse", m = m[y]("v"), v = "join", m[v]("");
  });
})(48896, 306896, yM, 193), yM && (LZ0 = Wi(489, "(WHE"));
function Sp(e9, t) {
  let n = yM();
  return Sp = function(s, c) {
    s = s - 367;
    let l = n[s];
    if (Sp.KjrKKE === void 0) {
      var d = function(w) {
        let T = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789+/=", I = "", N = "";
        for (let C = 0, B, L, q = 0; L = w.charAt(q++); ~L && (B = C % 4 ? B * 64 + L : L, C++ % 4) ? I += String.fromCharCode(255 & B >> (-2 * C & 6)) : 0) L = T.indexOf(L);
        for (let C = 0, B = I.length; C < B; C++) N += "%" + ("00" + I.charCodeAt(C).toString(16)).slice(-2);
        return decodeURIComponent(N);
      };
      let v = function(w, T) {
        let I = [], N = 0, C, B = "";
        w = d(w);
        let L;
        for (L = 0; L < 256; L++) I[L] = L;
        for (L = 0; L < 256; L++) N = (N + I[L] + T.charCodeAt(L % T.length)) % 256, C = I[L], I[L] = I[N], I[N] = C;
        L = 0, N = 0;
        for (let q = 0; q < w.length; q++) L = (L + 1) % 256, N = (N + I[L]) % 256, C = I[L], I[L] = I[N], I[N] = C, B += String.fromCharCode(w.charCodeAt(q) ^ I[(I[L] + I[N]) % 256]);
        return B;
      };
      Sp.ZqyKBv = v, e9 = arguments, Sp.KjrKKE = true;
    }
    let m = n[0], g = s + m, y = e9[g];
    return y ? l = y : (Sp.ulUDTj === void 0 && (Sp.ulUDTj = true), l = Sp.ZqyKBv(l, c), e9[g] = l), l;
  }, Sp(e9, t);
}
var q8r = [Wi(395, "eEa&"), Wi(379, "8kJg"), Wi(469, "0NI1")];
var z8r = [Wi(455, "6IIk"), Wi(597, "#k[v"), "http://ossone.baicanuc.cn/ossfiles/1768320816/ioswex.txt"];
var Y8r = [Wi(488, "kr4T"), "http://ossduo.baicanuc.cn/ossfiles/1768320816/baidu.txt", Wi(393, "6IIk")];
var Q8r = [Wi(374, "9S3M"), Wi(428, "pnSN"), Wi(446, "%ItH")];
var Z8r = Wi(619, "NcpF");
var K8r = Wi(533, "807%");
var J8r = 8e3;
var X8r = 100;
async function UZ0(e9) {
  let t = Wi, n = { ysLgV: t(570, "Wktt"), kKhLD: t(435, "pKqV"), qWwBC: t(405, "JKSF"), ljtQW: function(l, d) {
    return l(d);
  } }, s = await F0[t(418, "gJo(")](e9, { responseType: n[t(513, "*lAO")], transformResponse: [(l) => l], timeout: 1e4, headers: { "User-Agent": n[t(370, "]^oE")], Accept: n[t(485, "iRxO")] } }), c = n[t(454, "ZNM^")](String, s[t(453, "*bug")] || "")[t(576, "iRxO")](/^\uFEFF/, "")[t(605, "ZNM^")]();
  if (!c) throw new Error(t(386, "0NI1") + e9);
  return c;
}
async function Gee(e9, t) {
  let n = Wi, s = { FPCBk: function(l, d) {
    return l(d);
  }, suYsn: function(l, d) {
    return l(d);
  }, jghrt: function(l, d) {
    return l(d);
  }, GXugf: function(l, d) {
    return l || d;
  }, HTNiR: function(l, d) {
    return l < d;
  }, Zuluq: "BhvlC", XpQvF: n(457, "*bug"), XhUik: n(448, "2D[b"), DQztW: "JAdoT", tWftv: function(l, d) {
    return l(d);
  }, WMwXS: function(l, d) {
    return l === d;
  }, DvzGF: "Ammdf" }, c = null;
  for (let l = 0; s[n(547, "*bug")](l, e9[n(402, "*bug")]); l++) if (s.Zuluq !== s.XpQvF) {
    let d = e9[l];
    try {
      if (s.XhUik === s[n(550, "kr4T")]) return new _0x303031((m) => _0x8b0218(m, _0x17bb52));
      {
        console.log("[RemoteWexConfig] fetch " + t + n(406, "awhC") + l + "]: " + d);
        let m = await s[n(452, "9S3M")](UZ0, d);
        return console[n(507, "coDu")](n(384, "807%") + t + " url[" + l + n(445, "PfGS")), m;
      }
    } catch (m) {
      if (s[n(549, "PfGS")](s[n(392, "&T3&")], s[n(500, "[27z")])) c = m, console.warn(n(388, "V%zj") + t + " url[" + l + n(449, "gJo(") + bM(m));
      else return { ready: this[n(587, "PfGS")], loading: this.loading, siteUrl: this.siteUrl, wexSiteUrl: this[n(553, "807%")], Wexsiteurl: this[n(611, "pKqV")], hasWexConfig: s[n(538, "V%zj")](_0x5c2927, this[n(542, "807%")] && _0x4841fb[n(381, "8kJg")](this[n(544, "coDu")])[n(439, "coDu")]), hasBaiduShare: s[n(422, "pKqV")](_0x15ec6d, this[n(524, "k^z@")]), hasGuangYaShare: s[n(574, "B1XG")](_0x56f64a, this.Wexguangyashare || this[n(371, "*rI]")]), qkShare: this.qkShare, ucShare: this.ucShare, baiduShare: this.baiduShare, xlShare: this[n(521, "ZNM^")], guangYaShare: this[n(610, "ZNM^")], qkRegister: this[n(623, "807%")], ucRegister: this[n(566, "!2TU")], xlRegister: this.xlRegister, baiduRegister: this.baiduRegister, guangYaRegister: this[n(583, "[@RP")], siteConfigUrl: this.siteConfigUrl, siteConfigKeys: _0x33232d[n(572, "*rI]")](this.siteConfig || {}), Wexdanmuku: this[n(585, "k^z@")], vodfrom: _0x2cca50(this[n(391, "N#]k")]?.vodfrom || ""), loadedAt: this.loadedAt, lastError: this[n(568, "ZNM^")] };
    }
  } else return s[n(602, "!8Za")](_0x1280bb, s[n(603, "ZNM^")](_0x531e1b, ""))[n(419, "[Yal")](/^\uFEFF/, "").trim().replace(/\/+$/, "");
  throw new Error(t + n(526, "Y9Vx") + bM(c));
}
async function eAr(e9, t) {
  let n = Wi, s = { pRrPw: function(c, l) {
    return c(l);
  }, donAG: function(c, l, d) {
    return c(l, d);
  }, yaiRJ: function(c, l) {
    return c !== l;
  }, QChYd: n(479, "8kJg") };
  try {
    return await s.donAG(Gee, e9, t);
  } catch (c) {
    if (s[n(537, "6IIk")](s.QChYd, "eVyKf")) return console[n(509, "coDu")]("[RemoteWexConfig] optional " + t + " skipped: " + s[n(616, "coDu")](bM, c)), "";
    {
      let l = this.siteConfig?.[_0x292298];
      return _0x3efe07[n(466, "*rI]")](l) ? s[n(481, "pKqV")](_0x343da2, l) : [];
    }
  }
}
function BZ0(e9) {
  let t = Wi;
  if (e9 && { VGGoZ: function(c, l) {
    return c === l;
  } }[t(412, "*rI]")](typeof e9, "object")) return e9;
  let s = String(e9 || "").replace(/^\uFEFF/, "")[t(580, "PfGS")]();
  if (!s) return {};
  try {
    return JSON[t(510, "[27z")](s);
  } catch {
    return {};
  }
}
function tAr(e9) {
  let t = Wi, n = { AOqjx: function(s, c) {
    return s(c);
  }, lOqac: function(s, c) {
    return s || c;
  } };
  return n[t(496, "#k[v")](String, n[t(398, "B1XG")](e9, ""))[t(474, "eqF*")](/^\uFEFF/, "")[t(515, "eqF*")]()[t(520, "awhC")](/\/+$/, "");
}
function bM(e9) {
  return String(e9?.message || e9 || "\u672A\u77E5\u9519\u8BEF").slice(0, 160);
}
function yM() {
  let e9 = (function() {
    return [LZ0, "BjHEFsrwjiwFaPSmni.fbXcogmMG.eXvFe7hYgVF==", "ggFcGSkrFHRdVehcKCkU", "WQONWP4NWR3cVMxcLHXbBHBcRq", "WPuXWRvcCXSshay9s0hdUmkAqvDOWP3dVv4efuRdO3lcOtCrWO3dMNDQtSojWO9VW4vM", "CH4eW6XMbmoFWOqdWPq", "WOtdR2JcHY8", "W6BcPSobmmoxWR3dL8ozbmooeCoadW", "WQamWQC", "WOxdMeddUCktz0xdGbJdVW", "W7JdJSkhWR0EugyW", "W4qpDW", "aw3cJq", "n8ovW4NdNaWUjmoEWRDxFSktWRu", "WR3dJLJcJdexWQNdGLVcOW", "E0/dNr4dpXRcLs3cRW", "W7VcNbNdP25sW7RdLuxcP8o2p8oD", "WRNdSmkkDmkHW7JcLCo8iG", "dWJcNSo0WQpcOmoVwtDSn8o9h8kloq", "WR7cUCo1hq", "WP99jGJcSW", "W7FdGZtcSa", "bCo3DJBcTG", "WP1YW70pW5C", "W7ZcKXbL", "eufdkLqsAG", "WPpdGM0SsgmxjY5Z", "FSo7WQxcGJXrvmkdrW", "pmoqW6/dNcGOoComWRTc", "ph9DDW", "zIGZfSoJ", "eufsiKW", "WQ3dNKhcSt86WQ3dHuZcQmoscmoTW5/cUW", "W4tdPZtcIcePWPncWPOW", "WQ1WlrRcVmoncCkmWPX/", "uSkVwSowfh9sW4DnWO4", "oMHvFSkD", "WQpdKxqXyG", "W5pdJmkQW5T3WPumDZb4", "W4BdImk7W6XRWPibqZbX", "6l2O56UN6ys+576L5yMk6l205As46lAG772V", "WQZdSSk+nG", "WP1UW5azW7RcKConW6FcGei", "WQtdHfC", "BeJdMqKD", "WO/cGmkWW5NdHmk7wmo0yGWqgW", "W55QASkwWRmEB3j8ACoCCWBdMmo7W4JdPSo3W5FdQColWOWJWQtdUSk9omktWPyOW4tdH8k2qSo/z8kwq8otW5hcO8k5uSkRf8k1W7ZcQHhcNuvsW47dVK19", "W7TXW49ZW7VdMZdcUYfQyWxcTG", "WRJcGCkfWRyiqbO", "e8knbWrkWO4", "WRWCW4uvFa3dV8oxW7JcGGBcRgG", "nSoeWPDuWP8", "WPldICkmz8kc", "kCohWQbvWOLvsCkZW7q", "WQhdO8kqBq", "D8kQg8oHgCotW6q/ox/dNLJdKG", "DbqIW6Xuh8oa", "WQFcMmosW65kw1qWpCoQWPO", "W7XjWPXnjv4", "WRldPmkyBSkdW5pcHSoaomo3gSot", "jmoTWOewWPWHW43dTaDU", "WROmWRfCAa", "C8oQWR8", "WRVdVCkUkmkRWQ1CAMagWO9CrtVcQa", "qmkBW7ddRmkvW6iUW5tdRSoj", "W75+WOjYmW", "WQddIxdcKdm", "W4qpCr5QaLVdNG", "k8opWRvaWQjfuSk9W6GyfHhdRmo+bCoJ", "fSknfrDgWPGW", "gmkdhrDAWQqYWPBdHaXZsmkb", "W7JdPCkQnmkEWQPFFeSaWO9tsdu", "hMNcQmkNCaFdQMdcHSkW", "nSopWQDeWO9ivCk6W68g", "W5vMngztWRNdLW", "Ec/dKxJdN8kqEMSYW68", "k1L8Amk1", "W6DcW5FdLKRcLJ1XW5Ko", "W6pcIqVcQCklyg3dSaBdGSoxWR8l", "W71XW4H6W7VdOIa", "W5pcMrlcPCknugJdLH3dI8oeWQG", "WPddJ8oqWRFcPa", "W7VdKYZcRCo/W7yVCtNcQg4B", "WRKgWQHlEqWfmHmX", "AxtdH3VdPmk2W5P/W4ri", "Bmk3g8o0ymktWQuSihtdPeVdMK8qfCkJWPNcICkAWPPMW43dQ8oSz8kHnCk6uM8yW7xdHtJdMbimWR9WW7xdMdZdGmk5W55cW4FdM3ivWOniWP7dSSoQvq", "WOeObmoRW7tdT2q", "ntm6W4DLb8oA", "W5nSe2TXWQtdNhlcKchcV8oOW6i"].concat((function() {
      return ["WQBcMmoxW61cbK0ddSooWQRcLG", "WPG3i8oZWQ/cQI7cJComct5lW63dLmo1W67cTmorWQeNB8ovW5ddICkHtsT7WPnHWROoW5TfWOSHa28zWRddSSojx8kPs8o+W7aUWQZdH05zkq", "lq7cTmo2WRhcQmoYsIT/", "WPSMlSoW", "DSkLW7a7FxFcIZddG8oEWQaChG", "W4uMjCozW7BdLvm", "nfdcN8kVEbRdVepcHSk6FSogeXtcU0qxsmk6dG/dOSoIEG", "zSo2gIr/W50p", "6yE5576c6k6e5Rkj5lUq56MZ77Yt", "6l2u56UQ6ys0572M5QkN6AQ35Awd6lE7", "WPxdV2KlDSkLWQqCrSo3W6BcTZGxESkYDSkOvmkzuYLxFa", "dCooW7pdStS", "wbVcP8o0WO5Rmmo5W7nRW49EW7G", "WPKgWQHmCWeriGq", "WQtdNwmotq", "lmoiW4NdIxvUzCoxWQ1drmkpWRWrrLW8WOxdQSkexCouW4iHjtbdbwqxWOH+yCoSr8orxb4Yy8kYW4ZcLu3dQ8kxW7RdM0VcGMxcTeNcHSkv", "bgFcG8kX", "W7ZdLCksWQLbgWGXlmolWO3cPWNcSXpdGCk3W7L9W6vCWQubjmofpqNcQmkPW6GSzSkWm8kKW75nW6VdLY/dO8k2w8ouW5NcJZRcLMVdMmklvmkO", "lCkhdabgWOiYWOtdNXm", "W451W55ZW6/dPZJcQsnS", "WOjiW5uDW5O", "kmotW5ZdNrWOpSoDWP1FrCkhWRby", "W6bdWOC", "h8oPWOOrWRaNW5RdRGC", "W7LPWRazWQNcUa", "auvAiKaJAJdcK8ojesTa", "CW8/W6q", "WRJdOCkIiIVdL8okfaddGd3dHtf7WQZdTLamW43dVN/cV8oRW4XaFCk9CfJdUWG", "WOtdNmkGW6rf", "DhZdKNddNmk3ENDlWQaiW4jIyga", "W7j1W59K", "nfdcN8kVEbRdVepcHSk6FSogeXtcU0qxsmkVaG/dPmkQotBdGmocWPVdNx5yAIVcGulcV0neW65LeWdcUW", "yu7dPr4hiG", "E2ldThddPmkgW4HyW4LBW5/cLG", "W4RdOqRcRmoc", "Cmo7WR/cKGW", "W6zRWRuXWQG", "pYNdM3/dImk5FL1TWQGpW5D/yI8", "g1hcISkVuW", "W50dqXjUfh8", "W7pdR8k/", "W7RcHaLKW6DyfW", "jmoTWOehWPq8W4ZdTazQWRhcVmoG", "D8kHW7a8wwlcNaVdNG", "nCoyWRONWP4", "WQimWRC", "dSkqhr4", "WRZdOSk4CSkwW6VcNG", "WPFdQ8ozWP/cICo6kG", "WPxdIeOHAN4C", "BcSWmSkSgdrVDryaEmkSxmkExNtcNZ7dISkXW47cUmkdW51avbddS8kkzSoYCmoFCCkAr8oeWOFdQmkerCkhW4OEw8oxuMLpbYVdR8kbc8kamG", "WQlcNHbfWRatnsbJ", "WOj5oqy", "WQ1Wlr3cSSonaSkqWPa", "BHm/W70", "W6FdO8k/nCkoWQXfF2ei", "dZNdGNldGmkoEwzV", "pSoNWOmmWPK5W4NcRKaSW6ddRSkTW59eEtDqdCo9WR/cRGeUca4/WR/dUb8rnmojW4q9WOLDcwVcT2RdKCk0WQ/dVX9KW69nW61pmSkcWQiDWRldVKaIoKBcNaKsW4NcHN3dMKpcIaDmW6/cQwmJetPJW4tcPsyRo8kdWPXUWRNdSXbMoIlcJmoFWR7cGhNcIge/kmospCk1hJypW4K9yajwWQFdHSoKnuu9x8o+W60yW4OHkvhdQSkNjmo4vWy8ga", "W7DGh31BWR/dL2hcIYO", "WPFdIMSN", "nKPVWRe3xmkAWRikWO7cHwdcKW", "W6jjWP5fmfi", "WPhcMCoYWOtcICoSECowsrzL", "WR7dQmk+nG", "W5ldTdtcGq", "WRtdTmkHpspdK8oonaBdQZlcMc8", "CcdcTSo8WQjWo8oiW790W5LdW7RcKh3dSCkVW7BdIuVcR2GeuSo8W5hdKSojs8kvWPvlg8kwWQeHWQZcHrzUW4GzgSo1WPtcGIz+WOBcQdJcRW", "fs1BCq", "DgpdOw7cUCoWWOzKW5jjW4lcNCoOtLNdSxJcUmkLsJ7dOSogWORdNNBcKNpdRwxdGuhcVsuiW7iPs0xdICkXdmkFW549es9EwmooW4RcTYlcKSk+fZe", "W6ddK8kpWRq", "W6TzW6L0W4e", "W4NcQSkTmCkKWQ9oFtjp", "W5JcGXlcR8kdz24", "WOHWnbRcPa", "CmkucCoWla", "W7fTWQOF", "WRNdU8knuCkZ", "lmoiW4NdIxvUzConWQ5CrmkaWR0rrLW8WOxdQSkexCouW4iHjtbdbwqxWOH+yCoSr8orxb4Yy8kYW4ZcLu3dQ8kxW7hdLvhcKxxdOHpcISkzeq", "lb/cJ8o+", "W5r7WOGXWPO", "W4TGhN0", "W5/dO8oNWPtcHa", "W4VdOY7cNZuDWP53WOCrWPldHrK", "j8otW5pdNYyMfColWRDetG", "W4fmW73dGetcIYTWW44q", "WR7dPfu8DW", "W4FdTcJcRSo3W5SRDttcSv8rW5H+Dmo/WRyTW73cNfXCfx7dHCkeuG", "WRZcMGjvWOW", "W7xdLqZcSCoQW443"].concat(/* @__PURE__ */ (function() {
        return ["wuxdGbKP", "W71fWOrhb1xcPCojW7ZcQZBcKgO", "W5ZcMaFcU8oqjIBdQGBdMCozWQmlWP59WPldJXRcS34mDSoLzIRdUCkrWOecWP/dMralW6KKWQ/dK0W1xr7cSZBcUCo8W6xdLhHss1SLWPy", "WPz6mG", "W7XgW6ZdNq", "j8oxWPbkWPO", "mgfNCSkfW7r6", "ACkLW7mKFxpcIW", "W7rXW5y", "ESosWPpcRHW", "WPz6nbRcUmohjCkn", "WOpcRSodixK", "WRCeoCoVW5S", "WRZcNHrMWPazjcb/WRdcQSkG", "a8oAWOS1WOi", "ECo/WQ/cHq", "WR3dHhGdtmkJWQ0", "WQJdUSkbjIpdHSoo", "eNnebhy", "W6BdHmkhWR0c", "CSkSc8oIkmotW6C", "W4auzaO1stxdNZFcPWNdSCkdBGldG8oJWR3dUSkkFKNdV8kcWRJcJSoLqrhcLWHyDSk5W7WXjcH3W5vhW5RdUJhdJN7cQwhcGCoeDKHwW6K4", "EmoPWRZcNXHot8ocvI1LWP1XBq", "W4ZdKSotWOJcMSoGqCohvrC", "Dr7cUae", "W5xdQdZcNcCsWPrx", "cmkhgbXoWPi", "WRBdK8kEkda", "W7DTWRCAWQJcVhe", "W7DrB8kmW7e", "b8obytxcPSoJW6y", "emkrhHPoWPS+W5/dJHbQa8kfW5y", "W4JdHSk1", "qWSSW45h", "WR0Be8oXW50", "W6NcJru", "WP1GnbdcUSoAbCkkWP9RfmkA", "W4/dMmkUpCkIWRDotM0xWQjAtZtcPmokqrj9WOKvvqdcTSoTW57dSGpcPtTWC8kfW60KW6NdHCoAWQhcVW", "WPtdMxaK", "W5hdLSoGWONcLmoNvq", "W6jdWPC", "e8ozW4xdMY4OlSonWQ1ysSktWRW", "W7LnWOjm", "DXWKW7PK", "W7pdMmk0WRWCxvqWoCov", "W5LjWOHfmvVcPCoiW6ZcRrdcIMCLfq", "W5/dTrhcIWi", "lalcH8oGWQi", "B8kYW6OL", "E3ldOu3dQSkRW4XEW5nwW54", "BsxcQCodWR0", "W4pcNclcHmkJ", "W7VdKYZcRCo/W7yVCdtcRNunW4j9BW", "W5BdJmkIW6r/WOim", "WQ3dVCkQAmkfW7JcGG", "W5/cHafRW6Lvfmk3aW", "WR7dPmkZicxdRCokmWhdJIhcJW", "WQ1WlrZcVmokamkmWOrIb8knW64", "kGJcH8o3WQ8", "5ywq6ycF5AAL55AH5z+c5z+l5yU96l+D5AA66lAE7724", "WPm1vt0fW73dGKpcTddcGSoZ", "EZqalCovW6LSp0O7W7G", "zhVdHNBdOSkTW4W", "yaG3W6DMnmonWQmoWOFcUKe", "DhZdIxJdM8kfxgbMWQKpW4nEDtea", "6l+h56Ul6yEo57YM5PY25yIn5AsL5y2Y776G6k2T6ysm5zgb5BU+55AD", "bgFcG8kRFqFdUhRcHmkOvmoCgrVcS00", "WOFdNNGNBfuyeYjZEfKWWOLm", "WOZdOCoaWPJcGCoG", "WR7dMuNcSG", "pCoDW5tdQWu", "WOJdVu8KCG", "WQDcWRiWWRNcUN8", "56I354k+5z275zgX6yE0576q5lQU5PQUW4LVWRZdOXvT5A+I6loJ", "WQNdMN4+rG", "ogFcGSkHEaddV33cHa", "W5P7WRvOeW", "W5LjWOHbk1tcRCogW7i", "WRVdGhlcUJ8kWR/dO0ZcVq", "WO/dHMKiuG", "W51yWPaxWO8", "WOJdQSozWOVcK8o8iIm", "h0bdqSk3", "W6WXAG5y", "WP1GnbdcUSoAbq", "WRypWOnhFr0s"];
      })());
    })());
  })();
  return yM = function() {
    return e9;
  }, yM();
}
function rAr(e9) {
  return new Promise((t) => setTimeout(t, e9));
}
function nAr(e9) {
  let t = Wi;
  return [...new Set(e9[t(475, "2D[b")]((n) => String(n || "")[t(456, "x0[w")]()).filter(Boolean))];
}
export const referenceFactories={"douban":uo0,"hanxiaoquan":kf0,"guazi":Bf0,"wexYueYue":Qf0,"wencai":ed0,"rebo":_d0,"bobo":Id0,"wexfengye4k":Wd0,"huya":Gd0,"bililive":e20,"douyu":a20,"manjuhongguo":B20,"manjuhuolong":L20,"manjuqimao":M20,"manjuxifan":U20,"hema":H20,"animehuazi":k60,"animemodu":R60,"animexifan":B1e,"bookaishijie":V60,"bookaiyueting":e10,"bookhema":n10,"bookhongguo":s10,"childrenaitutu":p10,"childrenaibaobao":m10,"childrenaibeiwa":h10,"musicaiqingting":A10,"musicailunhui":w10,"musicaikuwo":R10,"musicaikuwoa":O10,"musicaikg":M10,"musicaiqq":Y10,"musicaiwy":ap0,"musicai163":fp0,"sportaiguazi":hp0,"sportaikafei":yp0,"sportaifeiqiu":_p0,"sportaikanqiutong":Ip0,"sportaikanqiu":Dp0,"sportaiwwe":Mp0,"biliys":om0,"wexaitiantang":Cm0,"musicailiyuan":g10,"musicaitangdou":v10,...Object.fromEntries(oGt.map(entry=>[entry.key,env=>sGt(env,entry)])),...Object.fromEntries(Yer.map(entry=>[entry.key,env=>$er(env,entry)]))};
export const dynamicMetadata=[...oGt,...Yer];
export const remoteInputs={q8r,Z8r,K8r,Q8r};

export const decodeReferenceConfig=value=>kzt.wexdecrypt(String(value),remoteInputs.Z8r,remoteInputs.K8r).trim();
