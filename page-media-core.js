// Shared public-page/media helpers. Builds embed these in each independent widget.
var PM_UA='Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 Mobile/15E148';
function pmText(x){return String(x==null?'':x).replace(/<[^>]*>/g,'').replace(/\s+/g,' ').trim();}
function pmUrl(u){if(typeof u!=='string'||u.length>8192||/[\s\x00-\x1f\\]/.test(u)||!/^https:\/\/[^/@?#]+(?:[/?#]|$)/i.test(u))throw new Error('资源地址无效或不是HTTPS');return u;}
function pmHeaders(site,path){return {'User-Agent':PM_UA,Referer:site+(path||'/'),Accept:'text/html,application/xhtml+xml'};}
function pmStatus(r){var s=Number(r.statusCode||r.status);if(s===429){var e=new Error('请求过于频繁，请稍后重试');e.code='RATE_LIMIT';throw e;}if(s!==200)throw new Error('原站暂不可用（HTTP '+s+'）');return r.data;}
async function pmHtml(url,headers){var r;try{r=await Widget.http.get(url,{headers:headers,allow_redirects:false});}catch(e){if(/TLS|SSL|secure|安全连接|证书|-120[0-6]/i.test(String(e.message||e)))throw new Error('原站HTTPS连接失败，请检查网络或代理');throw e;}var s=pmStatus(r);if(typeof s!=='string'||s.length>8*1024*1024)throw new Error('页面格式异常');if(/<title>[^<]*(?:系统安全验证|Just a moment)|name=["'](?:verify|vdcode|validate)["']/i.test(s)){var e=new Error('原站要求安全验证，模块暂不能取得此页面');e.code='CHALLENGE';throw e;}if(!/<html|<!doctype/i.test(s))throw new Error('原站未返回HTML页面');return s;}
function pmCover(site,u){u=u||'';if(u.slice(0,2)==='//')u='https:'+u;else if(u[0]==='/')u=site+u;try{return u?pmUrl(u):'';}catch(e){return '';}}
function pmLiteral(s,start){var first=s[start];if(first!=='{'&&first!=='[')throw new Error('数据不是JSON字面量');var depth=0,quoted=false,escape=false;for(var i=start;i<s.length;i++){var c=s[i];if(quoted){if(escape)escape=false;else if(c==='\\')escape=true;else if(c==='"')quoted=false;}else if(c==='"')quoted=true;else if(c==='{'||c==='[')depth++;else if((c==='}'||c===']')&&--depth===0)return JSON.parse(s.slice(start,i+1));}throw new Error('JSON数据不完整');}
function pmEpisodeKey(e){var t=pmText(e.title),m=t.match(/^第?0*(\d+)(?:集|话)?(?:已完结)?$/);return m?'episode:'+Number(m[1]):'title:'+t+'|'+e.index;}
var pmFlight=Object.create(null);
function pmOnce(key,fn){if(pmFlight[key])return pmFlight[key];var p=Promise.resolve().then(fn);pmFlight[key]=p;function done(){if(pmFlight[key]===p)delete pmFlight[key];}p.then(done,done);return p;}
function pmSha1(s){var a=unescape(encodeURIComponent(s)),words=[],len=a.length;for(var i=0;i<len;i++)words[i>>2]=(words[i>>2]||0)|a.charCodeAt(i)<<(24-(i%4)*8);words[len>>2]=(words[len>>2]||0)|128<<(24-(len%4)*8);var size=(((len+8)>>6)+1)*16;for(var i=0;i<size;i++)words[i]=words[i]||0;words[size-1]=len*8;var h=[0x67452301,0xefcdab89,0x98badcfe,0x10325476,0xc3d2e1f0],w=[];function rot(n,s){return n<<s|n>>>(32-s);}for(var off=0;off<size;off+=16){for(var i=0;i<80;i++)w[i]=i<16?words[off+i]:rot(w[i-3]^w[i-8]^w[i-14]^w[i-16],1);var a=h[0],b=h[1],c=h[2],d=h[3],e=h[4];for(var i=0;i<80;i++){var f,k;if(i<20){f=b&c|~b&d;k=0x5a827999;}else if(i<40){f=b^c^d;k=0x6ed9eba1;}else if(i<60){f=b&c|b&d|c&d;k=0x8f1bbcdc;}else{f=b^c^d;k=0xca62c1d6;}var t=(rot(a,5)+f+e+k+w[i])|0;e=d;d=c;c=rot(b,30);b=a;a=t;}h=[(h[0]+a)|0,(h[1]+b)|0,(h[2]+c)|0,(h[3]+d)|0,(h[4]+e)|0];}return h.map(function(n){return ('00000000'+(n>>>0).toString(16)).slice(-8);}).join('');}

function pmMd5(text) {
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

// Bounded HLS inspection; keep external audio and subtitle groups intact.
function pmRelative(base,ref){if(/^https?:\/\//i.test(ref))return pmUrl(ref);if(/^\/\//.test(ref))return pmUrl(base.split(':')[0]+':'+ref);if(/^[a-z][a-z\d+.-]*:/i.test(ref)||/[\s\\]/.test(ref))throw new Error('播放清单地址无效');var m=base.match(/^(https?:\/\/[^/]+)(\/[^?#]*)?/i);if(!m)throw new Error('播放清单地址无效');if(ref.charAt(0)==='?')return m[1]+(m[2]||'/')+ref;var path=ref.charAt(0)==='/'?ref:(m[2]||'/').replace(/[^/]*$/,'')+ref,parts=[];path.split('/').forEach(function(p){if(p==='..')parts.pop();else if(p!=='.')parts.push(p);});return pmUrl(m[1]+parts.join('/'));}
async function pmHls(url,headers,preference,budget){var seen=Object.create(null),reads=0;
 async function read(u,depth,keep){if(depth>=3||++reads>5||seen[u])throw new Error('播放清单检查达到上限');seen[u]=true;if(budget){if(budget.reads>=budget.maxReads)throw new Error('播放清单检查达到总请求上限');budget.reads++;}var r=await Widget.http.get(u,{headers:headers}),s=Number(r.statusCode||r.status);if(s===429){var e=new Error('播放线路请求过于频繁，请稍后重试');e.code='RATE_LIMIT';throw e;}var text=r.data;if(s!==200)throw new Error('原站媒体清单暂不可用（HTTP '+s+'）');if(typeof text!=='string'||text.length>1024*1024||!/^\s*#EXTM3U/.test(text))throw new Error('原站线路返回了非HLS媒体清单');var lines=text.split(/\r?\n/).map(function(l){return l.trim();});if(!/#EXT-X-STREAM-INF:/.test(text)){if(!/#EXTINF:/.test(text)||!lines.some(function(l){return l&&l[0]!=='#';}))throw new Error('播放清单为空');return {url:u};}
 var external=/(?:[:,])(?:AUDIO|SUBTITLES|VIDEO|CLOSED-CAPTIONS)=(?!NONE(?:,|\r?\n|$))/.test(text),variants=[];
 for(var i=0;i<lines.length;i++)if(/^#EXT-X-STREAM-INF:/.test(lines[i])){var res=lines[i].match(/RESOLUTION=(\d+)x(\d+)/),bw=lines[i].match(/(?:[:,])BANDWIDTH=(\d+)/);for(var j=i+1;j<lines.length;j++){if(/^#EXT-X-STREAM-INF:/.test(lines[j]))break;if(lines[j]&&lines[j][0]!=='#'){variants.push({url:pmRelative(u,lines[j]),width:res?Number(res[1]):0,height:res?Number(res[2]):0,bw:bw?Number(bw[1]):0});break;}}}
 variants.sort(function(a,b){return b.width*b.height-a.width*a.height||b.bw-a.bw;});var last;
 for(var v=0;v<Math.min(variants.length,2);v++)try{var chosen=variants[v],child=await read(chosen.url,depth+1,keep||external),fixed=preference==='fixed'&&!keep&&!external&&!child.retained;
 if(v===0&&child.url===chosen.url){return {url:fixed?child.url:u,width:chosen.width,height:chosen.height,fixed:fixed,retained:external||keep||child.retained};}
 if(keep||external)throw new Error('备用清单有独立音轨或字幕，请选择其他来源');return {url:child.url,width:chosen.width,height:chosen.height,fixed:fixed,retained:child.retained};}catch(e){if(e.code==='RATE_LIMIT')throw e;last=e;}
 throw last||new Error('播放子清单不可用');
 }return read(url,0,false);
}

async function pmMp4(url,headers){if(typeof Widget.http.request!=='function')throw new Error('当前App不支持MP4媒体检查，请更新App');var r=await Widget.http.request({url:url,method:'HEAD',headers:headers||{}}),status=Number(r.statusCode||r.status),ct='';if(status===429){var e=new Error('原站线路请求过于频繁，请稍后重试');e.code='RATE_LIMIT';throw e;}Object.keys(r.headers||{}).forEach(function(k){if(k.toLowerCase()==='content-type')ct=String(r.headers[k]);});if(status!==200||!/^video\/mp4(?:;|$)/i.test(ct))throw new Error('原站线路未返回有效MP4媒体');return {url:url};}
