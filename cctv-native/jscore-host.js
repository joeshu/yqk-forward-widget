var self=globalThis,window=globalThis,parent=globalThis,top=globalThis;
var location={href:'https://tv.cctv.com/live/cctv2/m/index.shtml',host:'tv.cctv.com',hostname:'tv.cctv.com',origin:'https://tv.cctv.com',protocol:'https:',pathname:'/live/cctv2/m/index.shtml',search:'',hash:'',port:''};
var origin=location.origin,activeURL=origin,signalUrlSend=false,vmpTag='';
var document={URL:location.href,location:location,currentScript:{src:'https://js.player.cntv.cn/creator/live.worker.js'}};
var navigator={userAgent:'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 Chrome/130.0.0.0 Mobile Safari/537.36',platform:'Linux armv8l',language:'zh-CN'};
var console={log:function(){},debug:function(){},warn:function(){},error:function(){},info:function(){}};
var __state={},__timers=[],__timerId=0,__requests=[],__xhr={},__xhrId=0;
function setTimeout(f,delay){var id=++__timerId;__timers.push({id:id,fn:f,due:Date.now()+(Number(delay)||0),args:Array.prototype.slice.call(arguments,2)});return id;}
function clearTimeout(id){__timers=__timers.filter(t=>t.id!==id);}
function setImmediate(f){return setTimeout.apply(null,[f,0].concat(Array.prototype.slice.call(arguments,1)));}
function __tick(){var now=Date.now(),ready=__timers.filter(t=>t.due<=now);__timers=__timers.filter(t=>t.due>now);for(var t of ready)t.fn.apply(null,t.args);}
var __alphabet='ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
function atob(s){var out='',bits=0,v=0;for(var ch of s.replace(/=+$/,'')){var n=__alphabet.indexOf(ch);if(n<0)throw Error('invalid-base64');v=(v<<6)|n;bits+=6;if(bits>=8){bits-=8;out+=String.fromCharCode((v>>bits)&255);}}return out;}
function btoa(s){var out='';for(var i=0;i<s.length;i+=3){var a=s.charCodeAt(i),b=s.charCodeAt(i+1),c=s.charCodeAt(i+2);out+=__alphabet[a>>2]+__alphabet[((a&3)<<4)|(b>>4||0)]+(i+1<s.length?__alphabet[((b&15)<<2)|(c>>6||0)]:'=')+(i+2<s.length?__alphabet[c&63]:'=');}return out;}
class DOMException extends Error {constructor(message,name){super(message);this.name=name||'Error';}}
function structuredClone(v,seen){if(v===null||typeof v!=='object')return v;seen=seen||new Map();if(seen.has(v))return seen.get(v);var out;
 if(v instanceof ArrayBuffer)return v.slice(0);if(ArrayBuffer.isView(v))return v instanceof DataView?new DataView(v.buffer.slice(v.byteOffset,v.byteOffset+v.byteLength)):new v.constructor(v);
 if(v instanceof Date)return new Date(v.getTime());if(v instanceof RegExp)return new RegExp(v.source,v.flags);
 out=Array.isArray(v)?[]:v instanceof Map?new Map():v instanceof Set?new Set():{};seen.set(v,out);
 if(v instanceof Map){v.forEach((x,k)=>out.set(structuredClone(k,seen),structuredClone(x,seen)));}else if(v instanceof Set){v.forEach(x=>out.add(structuredClone(x,seen)));}else for(var k of Object.keys(v))out[k]=structuredClone(v[k],seen);return out;}
class XMLHttpRequest {
 constructor(){this.listeners={};this.headers={};this.readyState=0;this.status=0;this.responseType='';this.response=null;this.responseText='';this.id=++__xhrId;}
 open(method,url,async){if(async===false)throw Error('sync-http-unsupported');this.method=method;this.url=url;this.readyState=1;}
 setRequestHeader(k,v){this.headers[k]=v;}
 overrideMimeType(){}
 addEventListener(k,fn){(this.listeners[k]||(this.listeners[k]=[])).push(fn);}
 emit(k){var e={type:k,target:this,loaded:this.response?this.response.byteLength:0,lengthComputable:false};if(typeof this['on'+k]==='function')this['on'+k](e);for(var f of this.listeners[k]||[])f(e);}
 send(body){__xhr[this.id]=this;var raw='';if(body){var a=new Uint8Array(body.buffer||body,body.byteOffset||0,body.byteLength);for(var b of a)raw+=String.fromCharCode(b);}__requests.push({id:this.id,url:this.url,method:this.method,headers:this.headers,body:btoa(raw)});}
 abort(){delete __xhr[this.id];this.emit('abort');}
 getAllResponseHeaders(){return '';}
}
function __respond(id,status,encoded){var x=__xhr[id];if(!x)return;delete __xhr[id];var text=atob(encoded),a=new Uint8Array(text.length);for(var i=0;i<text.length;i++)a[i]=text.charCodeAt(i);x.status=status;x.readyState=4;x.response=x.responseType==='arraybuffer'?a.buffer:text;x.responseText=text;x.emit('readystatechange');x.emit(status?'load':'error');if(status>=200&&status<300&&x.url.indexOf('/Library/H5player.json')>=0)__state.config=true;x.emit('loadend');}
