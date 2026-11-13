/* Standalone RSA-1024 PKCS#1 response fallback, ES5 + arrays only.
 * All arithmetic limbs are base 65536. Each multiply/accumulate stays below
 * 2^33, so integer precision is exact in JavaScript's Number representation.
 * No BigInt, require, native crypto, typed arrays, or external resources.
 * API: DSXRSAFallback.decryptBlocks(ciphertextBytes, crtHex) -> plaintextBytes
 * crtHex contains p,q,dp,dq,qi as hexadecimal strings.
 */
var DSXRSAFallback = (function () {
    var B = 65536;
    var cached = null;
    function zeros(n) { var a = []; for (var i = 0; i < n; i++) a[i] = 0; return a; }
    function trim(a) { while (a.length > 1 && a[a.length - 1] === 0) a.pop(); return a; }
    function copy(a) { return a.slice(0); }
    function cmp(a, b) {
        var al = a.length, bl = b.length;
        while (al > 1 && a[al - 1] === 0) al--;
        while (bl > 1 && b[bl - 1] === 0) bl--;
        if (al !== bl) return al < bl ? -1 : 1;
        for (var i = al - 1; i >= 0; i--) if (a[i] !== b[i]) return a[i] < b[i] ? -1 : 1;
        return 0;
    }
    // Requires a >= b. Inputs are never mutated.
    function sub(a, b) {
        var out = [], borrow = 0;
        for (var i = 0; i < a.length; i++) {
            var v = a[i] - (b[i] || 0) - borrow;
            if (v < 0) { v += B; borrow = 1; } else borrow = 0;
            out[i] = v;
        }
        if (borrow) throw new Error('RSA limb subtraction underflow');
        return trim(out);
    }
    function add(a, b) {
        var n = Math.max(a.length, b.length), out = [], carry = 0;
        for (var i = 0; i < n; i++) {
            var v = (a[i] || 0) + (b[i] || 0) + carry;
            out[i] = v % B; carry = Math.floor(v / B);
        }
        if (carry) out.push(carry);
        return trim(out);
    }
    function mul(a, b) {
        var t = zeros(a.length + b.length + 1);
        for (var i = 0; i < a.length; i++) {
            var carry = 0;
            for (var j = 0; j < b.length; j++) {
                var v = t[i+j] + a[i] * b[j] + carry;
                t[i+j] = v % B; carry = Math.floor(v / B);
            }
            var at = i + b.length;
            while (carry) {
                var q = t[at] + carry; t[at] = q % B;
                carry = Math.floor(q / B); at++;
            }
        }
        return trim(t);
    }
    function fromHex(s) {
        if (typeof s !== 'string' || !/^[0-9a-fA-F]+$/.test(s)) throw new Error('RSA CRT hex is invalid');
        var a = [];
        for (var i = s.length; i > 0; i -= 4) a.push(parseInt(s.slice(Math.max(0, i - 4), i), 16));
        return trim(a);
    }
    function fromBytes(bytes) {
        var out = [];
        for (var i = bytes.length; i > 0; i -= 2) out.push(bytes[i-1] + (i > 1 ? bytes[i-2] * 256 : 0));
        return trim(out.length ? out : [0]);
    }
    function toBytes(a, length) {
        var out = zeros(length);
        for (var i = 0; i < a.length; i++) {
            var at = length - i * 2 - 1;
            if (at < 0) { if (a[i]) throw new Error('RSA block overflow'); continue; }
            out[at] = a[i] % 256;
            if (at > 0) out[at-1] = Math.floor(a[i] / 256);
            else if (a[i] >= 256) throw new Error('RSA block overflow');
        }
        return out;
    }
    // Binary long division used for setup and reducing incoming 1024-bit c.
    function mod(a, n) {
        if (n.length === 1 && n[0] === 0) throw new Error('RSA modulus is zero');
        var r = [0];
        for (var i = a.length - 1; i >= 0; i--) {
            for (var bit = 15; bit >= 0; bit--) {
                var carry = (a[i] >>> bit) & 1;
                for (var j = 0; j < r.length; j++) {
                    var v = r[j] * 2 + carry;
                    r[j] = v % B; carry = Math.floor(v / B);
                }
                if (carry) r.push(carry);
                if (cmp(r, n) >= 0) r = sub(r, n);
            }
        }
        return trim(r);
    }
    function context(n) {
        n = trim(copy(n));
        if (!(n[0] & 1) || cmp(n, [1]) <= 0) throw new Error('RSA requires an odd modulus >1');
        var inv = 1;
        // Newton inverse mod 2^16; temporary magnitude <2^49.
        for (var i = 0; i < 4; i++) inv = ((inv * (2 - n[0] * inv)) % B + B) % B;
        var r2 = zeros(2 * n.length + 1); r2[r2.length - 1] = 1;
        return {n:n, k:n.length, negInv:(B-inv)%B, r2:mod(r2,n)};
    }
    // REDC(a*b); a,b < modulus. Product accumulation <2^33.
    function mont(a, b, ctx) {
        var k = ctx.k, n = ctx.n, t = zeros(2*k+2);
        for (var i = 0; i < k; i++) {
            var carry = 0, ai = a[i] || 0;
            for (var j = 0; j < k; j++) {
                var v = t[i+j] + ai * (b[j] || 0) + carry;
                t[i+j] = v % B; carry = Math.floor(v / B);
            }
            var at = i+k;
            while (carry) { var w = t[at]+carry; t[at] = w%B; carry = Math.floor(w/B); at++; }
        }
        for (var i = 0; i < k; i++) {
            var m = (t[i] * ctx.negInv) % B, carry = 0;
            for (var j = 0; j < k; j++) {
                var v = t[i+j] + m*n[j] + carry;
                t[i+j] = v%B; carry = Math.floor(v/B);
            }
            var at = i+k;
            while (carry) { var w = t[at]+carry; t[at] = w%B; carry = Math.floor(w/B); at++; }
        }
        var out = trim(t.slice(k));
        if (cmp(out,n) >= 0) out = sub(out,n);
        return out;
    }
    function powmod(base, exponent, ctx) {
        var x = mont(mod(base,ctx.n),ctx.r2,ctx), out = mont([1],ctx.r2,ctx);
        for (var i = exponent.length-1; i >= 0; i--) {
            for (var bit = 15; bit >= 0; bit--) {
                out = mont(out,out,ctx);
                if ((exponent[i] >>> bit) & 1) out = mont(out,x,ctx);
            }
        }
        return mont(out,[1],ctx);
    }
    function prepare(crt) {
        if (!crt || typeof crt !== 'object') throw new Error('RSA CRT parameters missing');
        var signature = [crt.p,crt.q,crt.dp,crt.dq,crt.qi].join('|');
        if (cached && cached.signature === signature) return cached;
        var p = fromHex(crt.p), q = fromHex(crt.q), qi = fromHex(crt.qi), pc = context(p), qc = context(q);
        if (p.length > 32 || q.length > 32) throw new Error('RSA fallback supports 1024-bit blocks');
        var key = {signature:signature,p:p,q:q,dp:fromHex(crt.dp),dq:fromHex(crt.dq),
            pc:pc,qc:qc,n:mul(p,q),qiMont:mont(mod(qi,p),pc.r2,pc)};
        // Check the coefficient independently before decrypting responses.
        if (cmp(mod(mul(q,qi),p),[1]) !== 0) throw new Error('RSA CRT coefficient invalid');
        cached = key;
        return key;
    }
    function decryptBlocks(bytes, crt) {
        if (!bytes || !bytes.length || bytes.length%128 || bytes.length>8192) throw new Error('RSA ciphertext block size invalid');
        for (var i = 0; i < bytes.length; i++) if (typeof bytes[i] !== 'number' || bytes[i] < 0 || bytes[i] > 255 || bytes[i] !== Math.floor(bytes[i])) throw new Error('RSA input is not bytes');
        var key = prepare(crt), out = [];
        for (var at = 0; at < bytes.length; at += 128) {
            var c = fromBytes(bytes.slice(at,at+128));
            if (cmp(c,key.n) >= 0) throw new Error('RSA ciphertext out of range');
            var a = powmod(c,key.dp,key.pc), b = powmod(c,key.dq,key.qc), bp = mod(b,key.p);
            var h = cmp(a,bp) >= 0 ? sub(a,bp) : sub(key.p,sub(bp,a));
            h = mont(mont(h,key.pc.r2,key.pc),key.qiMont,key.pc);
            h = mont(h,[1],key.pc);
            var block = toBytes(add(b,mul(key.q,h)),128);
            if (block[0] !== 0 || (block[1] !== 1 && block[1] !== 2)) throw new Error('RSA PKCS1 padding header invalid');
            var end = 2;
            while (end < 128 && block[end] !== 0) {
                if (block[1] === 1 && block[end] !== 255) throw new Error('RSA PKCS1 type1 padding invalid');
                end++;
            }
            if (end < 10 || end >= 128) throw new Error('RSA PKCS1 padding too short');
            for (var i = end+1; i < 128; i++) out.push(block[i]);
        }
        return out;
    }
    return {decryptBlocks:decryptBlocks};
})();

/* 大师兄原生 · 单文件 drpy 站源
 * 内置 MD5 / AES-128-CBC / PKCS7 / Base64，不下载或加载其他 JS。
 * 宿主仍须提供 drpy 的 $js、request、VODS/VOD 等接口。
 * 动态节目分类/筛选、榜单与推荐；直链及原生解析线路（JSON/RSA）。
 * RSA 优先 BigInt，旧宿主使用内嵌数组运算回退；配置响应支持实证前缀 n<=49。
 */
var rule = {
 play_parse:true,title:'大师兄原生',host:'http://app2.dsx.ac',编码:'utf-8',搜索:2,quickSearch:0,filterable:1,limit:21,
 url:'/ndsx.php/v7/logs',searchUrl:'/ndsx.php/v7/logs',detailUrl:'/detail/fyid',
 class_name:'电影&剧集&综艺&动漫&短剧&AI漫剧&少儿&直播',class_url:'1&2&3&4&63&64&62&58',
 _codec:{
  build:'1793438963909',pkg:'com.dsxys.app',
  offsets:[11,3,11,4,11,2,11,3,11,4,11,3,11,3,11,4,11,3,11,3,11,4,11,3,11,2,11,4,11,3,11,3,11,4,11,2,11,3,11,4,11,3,11,3,11,4,11,3,11],
  utf8:function(s){var b=[],v=encodeURIComponent(s);for(var i=0;i<v.length;i++){if(v[i]==='%'){b.push(parseInt(v.slice(i+1,i+3),16));i+=2;}else b.push(v.charCodeAt(i));}return b;},
  text:function(b){var s='';for(var i=0;i<b.length;i++)s+='%'+('0'+b[i].toString(16)).slice(-2);return decodeURIComponent(s);},
  b64:function(b){var abc='ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/',s='';for(var i=0;i<b.length;i+=3){var n=(b[i]<<16)|((b[i+1]||0)<<8)|(b[i+2]||0);s+=abc[(n>>>18)&63]+abc[(n>>>12)&63]+(i+1<b.length?abc[(n>>>6)&63]:'=')+(i+2<b.length?abc[n&63]:'=');}return s;},
  unb64:function(s){if(typeof s!=='string'||!s.length||!/^[A-Za-z0-9+/_-]+={0,2}$/.test(s))throw new Error('Base64格式无效');s=s.replace(/-/g,'+').replace(/_/g,'/');var u=s.replace(/=+$/,'');if(u.length%4===1)throw new Error('Base64长度无效');var full=u+'==='.slice(0,(4-u.length%4)%4);if(s.indexOf('=')>=0&&s!==full)throw new Error('Base64填充无效');var abc='ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/',a=[],acc=0,bits=0;for(var i=0;i<u.length;i++){acc=(acc<<6)|abc.indexOf(u[i]);bits+=6;if(bits>=8){bits-=8;a.push((acc>>>bits)&255);}}if(this.b64(a).replace(/=+$/,'')!==u)throw new Error('Base64不是标准编码');return a;},
  md5:function(bytes){var a=bytes.slice(),bits=a.length*8;a.push(128);while(a.length%64!==56)a.push(0);for(var z=0;z<8;z++)a.push(Math.floor(bits/Math.pow(256,z))&255);var state=[0x67452301,0xefcdab89,0x98badcfe,0x10325476],shifts=[7,12,17,22,5,9,14,20,4,11,16,23,6,10,15,21];for(var o=0;o<a.length;o+=64){var w=[];for(var j=0;j<16;j++)w[j]=a[o+4*j]|(a[o+4*j+1]<<8)|(a[o+4*j+2]<<16)|(a[o+4*j+3]<<24);var A=state[0],B=state[1],C=state[2],D=state[3];for(var i=0;i<64;i++){var f,g,r=i>>>4;if(r===0){f=(B&C)|(~B&D);g=i;}else if(r===1){f=(D&B)|(~D&C);g=(5*i+1)%16;}else if(r===2){f=B^C^D;g=(3*i+5)%16;}else{f=C^(B|~D);g=(7*i)%16;}var n=(A+f+w[g]+Math.floor(Math.abs(Math.sin(i+1))*4294967296))|0,s=shifts[4*r+(i%4)],next=(B+((n<<s)|(n>>>(32-s))))|0;A=D;D=C;C=B;B=next;}state=[(state[0]+A)|0,(state[1]+B)|0,(state[2]+C)|0,(state[3]+D)|0];}var out=[];for(var k=0;k<4;k++)for(var p=0;p<4;p++)out.push((state[k]>>>(8*p))&255);return out;},
  mul:function(a,b){var r=0;while(b){if(b&1)r^=a;a=((a<<1)^((a&128)?0x11b:0))&255;b>>>=1;}return r;},
  init:function(){if(this.sb)return;var sb=[],ib=[],rot=function(x,n){return((x<<n)|(x>>>(8-n)))&255;};for(var x=0;x<256;x++){var inv=0;if(x){inv=1;var base=x,e=254;while(e){if(e&1)inv=this.mul(inv,base);base=this.mul(base,base);e>>>=1;}}var y=inv^rot(inv,1)^rot(inv,2)^rot(inv,3)^rot(inv,4)^99;sb[x]=y;ib[y]=x;}this.sb=sb;this.ib=ib;},
  expand:function(key){this.init();if(key.length!==16)throw new Error('AES需要16字节key');var r=key.slice(),rc=1;for(var i=16;i<176;i+=4){var t=r.slice(i-4,i);if(i%16===0){t=[this.sb[t[1]]^rc,this.sb[t[2]],this.sb[t[3]],this.sb[t[0]]];rc=this.mul(rc,2);}for(var j=0;j<4;j++)r[i+j]=r[i+j-16]^t[j];}return r;},
  block:function(b,keys,decrypt){var s=b.slice(),self=this;function add(round){for(var i=0;i<16;i++)s[i]^=keys[round*16+i];}function shift(back){var t=s.slice();for(var c=0;c<4;c++)for(var r=0;r<4;r++)s[4*c+r]=t[4*((c+(back?4-r:r))%4)+r];}function sub(back){var box=back?self.ib:self.sb;for(var i=0;i<16;i++)s[i]=box[s[i]];}function mix(back){var t=s.slice(),m=back?[14,11,13,9]:[2,3,1,1];for(var c=0;c<4;c++)for(var r=0;r<4;r++){var v=0;for(var k=0;k<4;k++)v^=self.mul(t[4*c+k],m[(k-r+4)%4]);s[4*c+r]=v;}}if(!decrypt){add(0);for(var r=1;r<=10;r++){sub(false);shift(false);if(r!==10)mix(false);add(r);}}else{add(10);for(var r=9;r>=0;r--){shift(true);sub(true);add(r);if(r)mix(true);}}return s;},
  cbc:function(bytes,key,iv,decrypt){if(iv.length!==16||bytes.length%16)throw new Error('AES块长度无效');var keys=this.expand(key),out=[],prev=iv.slice();for(var o=0;o<bytes.length;o+=16){var b=bytes.slice(o,o+16);if(decrypt){var p=this.block(b,keys,true);for(var j=0;j<16;j++)out.push(p[j]^prev[j]);prev=b;}else{for(var j=0;j<16;j++)b[j]^=prev[j];prev=this.block(b,keys,false);out=out.concat(prev);}}return out;},
  key:function(){return this.md5(this.utf8(this.build+'^~!@#[-'+this.pkg));},
  randomIV:function(){var a=[];if(typeof crypto!=='undefined'&&crypto.getRandomValues&&typeof Uint8Array!=='undefined'){var u=new Uint8Array(16);crypto.getRandomValues(u);for(var i=0;i<16;i++)a.push(u[i]);}else{for(var i=0;i<16;i++)a.push(Math.floor(Math.random()*256));}return a;},
  encodeRequest:function(method,data,csrf,iv){if(typeof method!=='string'||!method)throw new Error('method无效');var d={},src=data||{};Object.keys(src).forEach(function(k){d[k]=src[k];});if(!Object.prototype.hasOwnProperty.call(d,'token'))d.token='';if(csrf===undefined)csrf=Date.now();if(typeof csrf!=='number'||!isFinite(csrf)||csrf<0||Math.floor(csrf)!==csrf)throw new Error('csrf无效');var p=this.utf8(JSON.stringify({method:method,data:d,csrf:csrf})),n=16-p.length%16;for(var i=0;i<n;i++)p.push(n);iv=iv===undefined?this.randomIV():iv.slice();return this.b64(iv.concat(this.cbc(p,this.key(),iv,false))).replace(/\+/g,'-').replace(/\//g,'_').replace(/=+$/,'');},
  decodeResponse:function(text){if(typeof text!=='string')throw new Error('响应不是文本');text=text.replace(/^\uFEFF/,'').trim();if(text[0]==='{'||text[0]==='['){var direct=JSON.parse(text);if(!direct||Array.isArray(direct)||typeof direct!=='object')throw new Error('响应不是JSON对象');return direct;}var marker=this.b64(this.utf8('xddappsecretkey')),pos=text.lastIndexOf(marker);if(pos<0)throw new Error('未知响应封装');var trailer=this.text(this.unb64(text.slice(pos))),m=trailer.match(/^xddappsecretkey(\d+)$/);if(!m)throw new Error('响应标记无效');var n=Number(m[1]);if(n<=0||n%4||n>=pos)throw new Error('响应分段长度无效');var table=this.text(this.unb64(text.slice(0,n)));if(!/^(0x[0-9]+)+$/.test(table))throw new Error('响应数字表无效');var nums=table.split('0x').slice(1).reverse();if(nums.length>this.offsets.length)throw new Error('响应前缀超过49项已验证范围');var raw=[];for(var i=0;i<nums.length;i++){var v=Number(nums[i])-this.offsets[i];if(v<0||v>255||Math.floor(v)!==v)throw new Error('响应前缀与偏移不匹配');raw.push(v);}raw=raw.concat(this.unb64(text.slice(n,pos)));if(raw.length<32||raw.length%16)throw new Error('响应AES长度无效');var p=this.cbc(raw.slice(16),this.key(),raw.slice(0,16),true),pad=p[p.length-1];if(pad<1||pad>16)throw new Error('响应PKCS7无效');for(var i=p.length-pad;i<p.length;i++)if(p[i]!==pad)throw new Error('响应PKCS7无效');var obj=JSON.parse(this.text(p.slice(0,-pad)));if(!obj||Array.isArray(obj)||typeof obj!=='object')throw new Error('响应不是JSON对象');return obj;}
 },
 encodeRequest:function(method,data,csrf,iv){return this._codec.encodeRequest(method,data,csrf,iv);},
 decodeResponse:function(text){return this._codec.decodeResponse(text);},
 api:function(method,data){
  var body=rule.encodeRequest(method,data),text=request(rule.host+'/ndsx.php/v7/logs',{method:'POST',body:body,timeout:15000,headers:{'User-Agent':'Dart/3.13 (dart:io)','Content-Type':'text/plain',version:'1.0.7','version-number':'17','pk-id':rule._codec.pkg,'build-time':rule._codec.build,platform:'ios','platform-version':'Version 27.0.1 (Build 24A446)'}});
  var j=rule.decodeResponse(text);if(Number(j.code)!==1)throw new Error('原生接口 '+j.code+': '+(j.msg||''));return j;
 },
 _cache:{},
 cached:function(key,ttl,loader){var hit=this._cache[key],now=Date.now();if(hit&&now-hit.time<ttl)return hit.value;var value;try{value=loader();}catch(e){if(hit)return hit.value;throw e;}this._cache[key]={time:now,value:value};return value;},
 cleanText:function(value){return String(value==null?'':value).replace(/<[^>]*>/g,'').replace(/&(?:amp;)?nbsp;/gi,' ').replace(/&(?:amp;)?quot;/gi,'"').replace(/&(?:amp;)?apos;/gi,"'").replace(/&amp;/gi,'&').replace(/&lt;/gi,'<').replace(/&gt;/gi,'>').replace(/\s+/g,' ').trim();},
 cards:function(rows){var out=[],seen={};(Array.isArray(rows)?rows:[]).forEach(function(v){if(!v||v.vod_id==null||String(v.vod_id)==='')return;var id=String(v.vod_id);if(seen[id])return;seen[id]=true;var c={};Object.keys(v).forEach(function(k){c[k]=v[k];});['vod_name','vod_remarks','vod_blurb','vod_content'].forEach(function(k){if(c[k]!=null)c[k]=rule.cleanText(c[k]);});out.push(c);});return out;},
 choices:function(value){var rows=Array.isArray(value)?value:String(value||'').split(/[,，\n\r|]/),out=[{n:'全部',v:''}],seen={'':true};rows.forEach(function(x){var val=rule.cleanText(typeof x==='object'?(x.v==null?x.n:x.v):x);if(val&&!seen[val]){seen[val]=true;out.push({n:val,v:val});}});return out;},
 navData:function(){return this.cached('nav',600000,function(){return rule.api('nav').data||[];});},
 homeData:function(){return this.cached('home',60000,function(){return rule.api('index_recommend').data||{};});},
 rankData:function(){return this.cached('ranks',300000,function(){return rule.api('rank_list').data||[];});},
 refreshCatalog:function(){
  var nav=[],home={},ranks=[],errors=[];
  try{nav=this.navData();}catch(e){errors.push(String(e));nav=[{type_id:1,type_name:'电影'},{type_id:2,type_name:'剧集'},{type_id:3,type_name:'综艺'},{type_id:4,type_name:'动漫'},{type_id:63,type_name:'短剧'},{type_id:64,type_name:'AI漫剧'},{type_id:62,type_name:'少儿'},{type_id:58,type_name:'直播'}];}
  try{home=this.homeData();}catch(e){errors.push(String(e));}
  try{ranks=this.rankData();}catch(e){errors.push(String(e));}
  var classes=[],filters={},seen={};
  function add(id,name){id=String(id);if(id&&!seen[id]){seen[id]=true;classes.push({type_id:id,type_name:rule.cleanText(name).replace(/&/g,'＆')});}}
  (Array.isArray(nav)?nav:[]).forEach(function(x){
   if(!x||!/^\d+$/.test(String(x.type_id)))return;var id=String(x.type_id);add(id,x.type_name);var ext=x.type_extend||{},f=[];if(typeof ext==='string'){try{ext=JSON.parse(ext);}catch(e){ext={};}}
   [['class','类型'],['area','地区'],['lang','语言'],['year','年份']].forEach(function(k){var values=rule.choices(ext[k[0]]);if(values.length>1)f.push({key:k[0],name:k[1],value:values});});
   f.push({key:'order',name:'排序',value:[{n:'最新',v:'最新'}]});filters[id]=f;
  });
  (home.videos||[]).forEach(function(x){if(x&&x.id!=null&&Array.isArray(x.vlist)&&x.vlist.length)add('home:'+x.id,'推荐·'+x.name);});
  (Array.isArray(ranks)?ranks:[]).forEach(function(x){if(x&&/^\d+$/.test(String(x.id)))add('rank:'+x.id,'榜单·'+x.name);});
  this.class_name=classes.map(function(x){return x.type_name;}).join('&');this.class_url=classes.map(function(x){return x.type_id;}).join('&');this.filter=filters;
  this._catalog={class:classes,filters:filters,errors:errors};return this._catalog;
 },
 localPage:function(rows,page){rows=this.cards(rows);page=Math.max(1,Math.floor(Number(page)||1));var limit=21;return{list:rows.slice((page-1)*limit,page*limit),page:page,pagecount:Math.max(1,Math.ceil(rows.length/limit)),limit:limit,total:rows.length};},
 resultPage:function(j,page){var rows=this.cards(j.data),pg=Math.max(1,Math.floor(Number(j.page||page)||1)),limit=Math.max(1,Math.floor(Number(j.limit)||rows.length||21)),total=Math.max(0,Number(j.total)||0),count=Number(j.pagecount);return{list:rows,page:pg,pagecount:count>0?Math.ceil(count):(total?Math.ceil(total/limit):pg+(rows.length>=limit?1:0)),limit:limit,total:total};},
 categoryPage:function(tid,page,extend){
  tid=String(tid);page=Math.max(1,Math.floor(Number(page)||1));extend=extend||{};var m=tid.match(/^rank:(\d+)$/);
  if(m){var id=Number(m[1]),rank=this.cached('rank:'+id,60000,function(){return rule.api('rank_video_list',{id:id}).data||[];});return this.localPage(rank,page);}
  m=tid.match(/^(?:home|section):(\d+)$/);if(m){var rows=[],id=String(m[1]);(this.homeData().videos||[]).some(function(x){if(String(x.id)===id){rows=x.vlist||[];return true;}return false;});return this.localPage(rows,page);}
  if(!/^\d+$/.test(tid))throw new Error('未知节目分类');var data={tid:Number(tid),pg:page,class:'',area:'',lang:'',year:'',order:'最新'};
  ['class','area','lang','year','order'].forEach(function(k){if(extend[k]!=null&&extend[k]!=='')data[k]=String(extend[k]);});return this.resultPage(this.api('video_list',data),page);
 },
 searchPage:function(text,page){text=String(text||'').trim();if(!text)return this.localPage([],1);page=Math.max(1,Math.floor(Number(page)||1));return this.resultPage(this.api('search',{text:text,pg:page}),page);},
 headers:function(value){
  var out={};function add(key,val){key=String(key||'').trim();val=String(val==null?'':val).trim();if(/^[!#$%&'*+.^_`|~0-9A-Za-z-]+$/.test(key)&&!/[\r\n]/.test(val)&&!/^(host|content-length|connection|proxy-authorization)$/i.test(key))out[key]=val;}
  if(value&&typeof value==='object'&&!Array.isArray(value))Object.keys(value).forEach(function(k){add(k,value[k]);});
  else String(value||'').split(/\r?\n|\\n/).forEach(function(line){var at=line.indexOf(':');if(at>0)add(line.slice(0,at),line.slice(at+1));});return out;
 },
 mergeHeaders:function(a,b){var out={};[this.headers(a),this.headers(b)].forEach(function(h){Object.keys(h).forEach(function(k){Object.keys(out).forEach(function(old){if(old.toLowerCase()===k.toLowerCase())delete out[old];});out[k]=h[k];});});return out;},
 httpURL:function(value){return typeof value==='string'&&/^https?:\/\/[^\s/?#@]+(?:[/?#][^\s]*)?$/i.test(value);},
 directMedia:function(value){if(!this.httpURL(value))return false;var path=value.split(/[?#]/)[0];return /\.(?:m3u8|mp4|mkv|webm|mov|m4v|flv|ts)$/i.test(path);},
 parserList:function(source){var rows=[source.parse_api],extra=source.extra_parse_api;if(Array.isArray(extra))rows=rows.concat(extra);else rows=rows.concat(String(extra||'').split(/\r?\n/));var out=[],seen={};rows.forEach(function(x){x=String(x||'').trim();if(rule.httpURL(x)&&!seen[x]){seen[x]=true;out.push(x);}});return out.slice(0,5);},
 playToken:function(meta){return 'dsxplay:'+this._codec.b64(this._codec.utf8(JSON.stringify(meta))).replace(/\+/g,'-').replace(/\//g,'_').replace(/=+$/,'');},
 unpackPlay:function(value){if(typeof value!=='string'||value.indexOf('dsxplay:')!==0)throw new Error('未知播放数据');var m=JSON.parse(this._codec.text(this._codec.unb64(value.slice(8))));if(!m||m.v!==1||typeof m.u!=='string'||!m.u||m.u.length>131072||!Array.isArray(m.p)||m.p.length>5)throw new Error('播放数据格式无效');m.c=String(m.c||'');m.p=m.p.filter(function(p){return rule.httpURL(p);});m.h=this.headers(m.h);m.s=!!m.s;m.m=m.m==='parse'?'parse':'auto';return m;},
 mediaGroups:function(original){
  var v={};Object.keys(original||{}).forEach(function(k){v[k]=original[k];});var names=[],groups=[],used={};
  function add(name,eps){if(!eps.length)return;name=rule.cleanText(name||'线路').replace(/[$#]/g,' ').trim();var base=name,n=2;while(used[name])name=base+' ('+(n++)+')';used[name]=true;names.push(name);groups.push(eps.join('#'));}
  (v.vod_url_with_player||[]).forEach(function(s){
   var parsers=rule.parserList(s),h=rule.headers(s.headers||s.header),secret=s.parse_secret===true||s.parse_secret===1||s.parse_secret==='1',main=[],backup=[],seen={};
   (s.url||'').split('#').forEach(function(part){var at=part.indexOf('$');if(at<1)return;var label=rule.cleanText(part.slice(0,at)).replace(/[$#]/g,' '),u=part.slice(at+1).trim();if(!u||seen[label+'\n'+u])return;seen[label+'\n'+u]=true;var direct=rule.directMedia(u),http=rule.httpURL(u);if(!direct&&!http&&!parsers.length&&!secret)return;
    var meta={v:1,u:u,c:String(s.code||''),p:parsers.slice(),h:h,s:secret,m:'auto'};
    main.push(label+'$'+rule.playToken(meta));
    if(direct&&(parsers.length||secret)){var alt={v:1,u:u,c:meta.c,p:parsers.slice(),h:h,s:secret,m:'parse'};backup.push(label+'$'+rule.playToken(alt));}
   });
   var name=s.name||s.code||'线路';add(name,main);add(name+'·解析备用',backup);
  });v.vod_play_from=names.join('$$$');v.vod_play_url=groups.join('$$$');return v;
 },
 _rsaCRT:{
  p:'fbc7ab9d75533e39971e41b554990a57149ea3d115298d9d17630138a40f315339b7a69c6254dde2ffed520f5ad8c48fd2ef18ffd6c97ea0ca8d7329cf0146d5',
  q:'f36bda059d298c1cf92fae597fcccc5ccb715e3935b485cb4185d20c6c19a3249ca195f4e604ebf1c26f08f75174e72764499d722ee2e10232f16e3aacd9f0fb',
  dp:'7f28e1d0bd6f944eabb6d942c67e208dc85932ad273dfc4aa984141ad228e6257d51f670a6ecebbf78b81828af1e296fe5fd61a7dc87994f85dd189bb5f3941d',
  dq:'6d86a9a2bd0464b6e4a83f9aa596509db02c6268fb712e8236093069c67a029e069bee0d333223b7b3f4a1e42612a3af65c079c756b15eecce5f3369d33c7ce1',
  qi:'88911352f605c0254a3464d8333520eefdd06e5a985c1f88873714dfbb0764e9fa6b8e95e5e24369d6af22fb849a8c491d64f26e2fb566437b2de514838ca50b'
 },
 rsaReply:function(text){
  var bytes=this._codec.unb64(String(text).trim());if(!bytes.length||bytes.length%128||bytes.length>8192)throw new Error('RSA分块长度无效');if(typeof BigInt!=='function')return this._codec.text(DSXRSAFallback.decryptBlocks(bytes,this._rsaCRT));var k=this._rsaState;
  if(!k){k={};Object.keys(this._rsaCRT).forEach(function(n){k[n]=BigInt('0x'+rule._rsaCRT[n]);});this._rsaState=k;}
  var zero=BigInt(0),one=BigInt(1);function pow(a,e,m){var r=one;a%=m;while(e>zero){if((e&one)!==zero)r=r*a%m;e>>=one;if(e>zero)a=a*a%m;}return r;}
  var out=[];for(var off=0;off<bytes.length;off+=128){var hex='';for(var i=off;i<off+128;i++)hex+=('0'+bytes[i].toString(16)).slice(-2);var c=BigInt('0x'+hex);if(c>=k.p*k.q)throw new Error('RSA数值超出范围');var a=pow(c,k.dp,k.p),b=pow(c,k.dq,k.q),h=(a-b)*k.qi%k.p;if(h<zero)h+=k.p;var m=b+k.q*h,block=m.toString(16);while(block.length<256)block='0'+block;if(block.length!==256)throw new Error('RSA块长度无效');var buf=[];for(var j=0;j<256;j+=2)buf.push(parseInt(block.slice(j,j+2),16));if(buf[0]!==0||(buf[1]!==1&&buf[1]!==2))throw new Error('RSA填充头无效');var end=2;while(end<128&&buf[end]!==0){if(buf[1]===1&&buf[end]!==255)throw new Error('RSA类型1填充无效');end++;}if(end<10||end===128)throw new Error('RSA填充长度无效');out=out.concat(buf.slice(end+1));}
  return this._codec.text(out);
 },
 parserReply:function(text,target){
  if(text&&typeof text==='object')return text;text=String(text||'').replace(/^\uFEFF/,'').trim();if(this.httpURL(text))return{code:200,url:text};if(/^#EXTM3U(?:\s|$)/.test(text)&&this.httpURL(target))return{code:200,url:target,type:'m3u8'};
  try{return JSON.parse(text);}catch(e){return JSON.parse(this.rsaReply(text));}
 },
 playData:function(value,depth,inherited){
  depth=depth||0;inherited=this.headers(inherited);if(depth>8)return null;if(typeof value==='string')return this.httpURL(value)?{url:value,headers:inherited,type:''}:null;
  if(Array.isArray(value)){for(var i=0;i<value.length;i++){var row=this.playData(value[i],depth+1,inherited);if(row)return row;}return null;}
  if(!value||typeof value!=='object'||(value.code!=null&&[1,200].indexOf(Number(value.code))<0))return null;
  var hh=this.mergeHeaders(inherited,value.headers||value.header);if(value.UA||value.ua)hh=this.mergeHeaders(hh,{'User-Agent':value.UA||value.ua});
  if(typeof value.url==='string'&&this.httpURL(value.url))return{url:value.url,headers:hh,type:String(value.type||'')};
  return value.data&&value.data!==value?this.playData(value.data,depth+1,hh):null;
 },
 parserTarget:function(api,origin){var encoded=encodeURIComponent(origin);return api.indexOf('{url}')>=0?api.replace(/\{url\}/g,encoded):api+encoded;},
 probeMedia:function(url,headers,deadline){
  if(!this.httpURL(url))return{state:'error',note:'媒体地址无效'};
  var remaining=deadline-Date.now();if(remaining<=0)return{state:'error',note:'解析时限已到'};
  try{
   var response=request(url,{method:'GET',headers:this.mergeHeaders(headers,{Range:'bytes=0-1023'}),timeout:Math.min(4000,remaining),withHeaders:true}),body=response,status=0,h={};
   if(typeof response==='string'){try{var obj=JSON.parse(response);if(obj&&Object.prototype.hasOwnProperty.call(obj,'body'))response=obj;}catch(e){}}
   if(response&&typeof response==='object'&&!Array.isArray(response)){body=response.body;status=Number(response.statusCode||response.status)||0;h=response.headers||response.header||response;}
   if(status>=300)return{state:'error',note:'媒体HTTP '+status};var type='';Object.keys(h).forEach(function(k){if(k.toLowerCase()==='content-type')type=String(h[k]).toLowerCase();});
   if(/text\/html|application\/(?:json|xml)|image\/svg/.test(type))return{state:'error',note:'媒体返回错误正文类型'};
   if(typeof body==='string'){
    var start=body.slice(0,1024),trim=start.replace(/^\uFEFF/,'').trim();
    if(/^(?:<(?:!|\?|[a-z])|\{|\[)/i.test(trim))return{state:'error',note:'媒体实际为错误页面'};
    if(/^#EXTM3U/.test(trim))return{state:'ok',note:'HLS列表',format:'hls'};
    var at=0;for(var box=0;box<8&&at+8<=start.length;box++){
     var size=0,valid=true;for(var byte=0;byte<4;byte++){var code=start.charCodeAt(at+byte);if(code>255){valid=false;break;}size=size*256+code;}
     if(!valid||size<8)break;var kind=start.slice(at+4,at+8);
     if(/^(?:ftyp|styp)$/.test(kind)){if(size>=16&&size<=4096&&size%4===0)return{state:'ok',note:'MP4媒体头'};break;}
     if(/^(?:moof|moov|mdat)$/.test(kind))return{state:'ok',note:'MP4媒体头'};
     if(kind!=='free'&&kind!=='skip')break;if(at+size>start.length)break;at+=size;
    }
    if(/^FLV/.test(start))return{state:'ok',note:'FLV媒体头'};
    for(var i=0;i<Math.min(188,start.length-376);i++)if(start.charCodeAt(i)===71&&start.charCodeAt(i+188)===71&&start.charCodeAt(i+376)===71)return{state:'ok',note:'TS媒体头'};
    if(!trim)return{state:'error',note:'媒体正文为空'};
   }
   // Some drpy bridges expose decoded text but no binary data or status.
   // Preserve this as unknown; this is not a successful stream verification.
   return{state:'unknown',note:'宿主未提供可识别的媒体头'};
  }catch(e){if(/withHeaders.*(?:support|支持)|不支持.*withHeaders/i.test(String(e)))return{state:'unknown',note:'宿主不支持媒体头探测'};return{state:'error',note:String(e)};}
 },
 _playCache:{},
 resolvePlay:function(value){
  var meta,encoded=typeof value==='string'&&value.indexOf('dsxplay:')===0;
  if(encoded)meta=this.unpackPlay(value);else if(this.httpURL(value))meta={v:1,u:value,c:'',p:[],h:{},s:false,m:'auto'};else throw new Error('播放令牌缺少解析配置');
  var cached=this._playCache[value];if(cached&&Date.now()-cached.time<60000)return cached.value;
  var h=this.mergeHeaders({'User-Agent':'Dart/3.13 (dart:io)'},meta.h),direct=this.directMedia(meta.u),errors=[],deadline=Date.now()+25000;
  if(!encoded&&direct)return{parse:0,playUrl:'',url:meta.u,header:h};
  function finish(play,positive){
   if(!play||!rule.httpURL(play.url))return null;var headers=rule.mergeHeaders(h,play.headers),probe=rule.probeMedia(play.url,headers,deadline);rule._lastProbe=probe;if(probe.state==='error'||(positive&&probe.state!=='ok'))throw new Error(probe.note);
   var result={parse:0,playUrl:'',url:play.url,header:headers};if(probe.format)result.format=probe.format;rule._playCache[value]={time:Date.now(),value:result};var keys=Object.keys(rule._playCache);if(keys.length>64)delete rule._playCache[keys[0]];return result;
  }
  if(!direct&&!meta.p.length&&!meta.s&&this.httpURL(meta.u)){try{return finish({url:meta.u,headers:{}},true);}catch(e){return{parse:1,playUrl:'',url:meta.u,header:h};}}
  if(direct&&meta.m!=='parse'){try{return finish({url:meta.u,headers:{}});}catch(e){errors.push(String(e));}}
  if(meta.s&&Date.now()<deadline){try{var native=this.api('secret_parse_api_url',{url:meta.u,player_code:meta.c}),play=this.playData(native.data),ready=finish(play);if(ready)return ready;errors.push('原生解析未返回媒体地址');}catch(e){errors.push(String(e));}}
  for(var i=0;i<meta.p.length&&i<5&&Date.now()<deadline;i++){
   try{var target=this.parserTarget(meta.p[i],meta.u);if(!this.httpURL(target))throw new Error('无效解析地址');var reply=request(target,{method:'GET',timeout:Math.min(8000,Math.max(1,deadline-Date.now())),headers:h}),parsed=this.parserReply(reply,target),play=this.playData(parsed),result=finish(play);if(result)return result;throw new Error('解析服务未返回有效媒体地址');}catch(e){errors.push(String(e));}
  }
  if(direct&&meta.m==='parse'&&Date.now()<deadline){try{return finish({url:meta.u,headers:{}});}catch(e){errors.push(String(e));}}
  if(!direct&&!meta.p.length&&!meta.s&&this.httpURL(meta.u))return{parse:1,playUrl:'',url:meta.u,header:h};
  throw new Error('线路解析失败，请换线：'+errors.join('；').slice(0,240));
 },
 videoId:function(value){if(Array.isArray(value))value=value[0];var s=String(value);if(/^\d+$/.test(s))return Number(s);var m=s.match(/[?&](?:id|vod_id)=(\d+)(?:[&#]|$)/);if(!m)m=s.match(/(?:\/|\$)(\d+)(?:[?#].*)?$/);if(!m)throw new Error('无法识别影片ID');return Number(m[1]);},
 预处理:$js.toString(()=>{rule.refreshCatalog();}),
 推荐:$js.toString(()=>{var rows=[];(rule.homeData().videos||[]).forEach(function(section){rows=rows.concat(section.vlist||[]);});VODS=rule.cards(rows);}),
 一级:$js.toString(()=>{var p=rule.categoryPage(MY_CATE,MY_PAGE,typeof MY_FL==='undefined'?{}:MY_FL);rule._lastPage=p;VODS=p.list;}),
 搜索:$js.toString(()=>{var p=rule.searchPage(KEY,MY_PAGE);rule._lastPage=p;VODS=p.list;}),
 二级:$js.toString(()=>{VOD=rule.mediaGroups(rule.api('video_detail',{id:rule.videoId(input),sign_md5:'',apk_path:'',apk_length:0}).data.vod_info);}),
 lazy:$js.toString(()=>{input=rule.resolvePlay(input);})
};
