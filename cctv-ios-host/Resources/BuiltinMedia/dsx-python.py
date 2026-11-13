# -*- coding: utf-8 -*-
"""大师兄原生 CCTVHost 单文件站源，Python 3.8+。
只需此文件，无同目录模块、无 pip 依赖；base.spider 由宿主提供。
内嵌 AES-128-CBC / PKCS7、原生接口和配置响应解码。
保留原生播放源，内置 RSA 解析、备用解析和按需媒体头验证。
响应封装偏移已验证至49项，未知范围明确报错。
"""
import base64
import hashlib
import html
import json
import os
import re
import time
import urllib.error
import urllib.parse
import urllib.request

try:
    from base.spider import Spider as BaseSpider
except ImportError:
    BaseSpider = object

DEFAULT_BUILD = '1793438963909'
DEFAULT_PACKAGE = 'com.dsxys.app'
DEFAULT_BASE = 'http://app2.dsx.ac'
_PREFIX_MASK = (11,3,11,4,11,2,11,3,11,4,11,3,11,3,11,4,11,3,11,3,11,4,11,3,
                11,2,11,4,11,3,11,3,11,4,11,2,11,3,11,4,11,3,11,3,11,4,11,3,11)


def _gmul(a, b):
    p = 0
    for _ in range(8):
        if b & 1: p ^= a
        a = ((a << 1) ^ (0x11b if a & 128 else 0)) & 255
        b >>= 1
    return p


def _make_tables():
    sb = []
    for n in range(256):
        # Multiplicative inverse in GF(2^8), with 0 mapped to 0.
        v, a, e = 1, n, 254
        if n:
            while e:
                if e & 1: v = _gmul(v, a)
                a = _gmul(a, a)
                e >>= 1
        else: v = 0
        x = v
        for r in (1, 2, 3, 4): x ^= ((v << r) | (v >> (8-r))) & 255
        sb.append(x ^ 0x63)
    inv = [0]*256
    for i, v in enumerate(sb): inv[v] = i
    return sb, inv, {n: [_gmul(v, n) for v in range(256)] for n in (2,3,9,11,13,14)}


_SBOX, _INVBOX, _MUL = _make_tables()


def _expand(key):
    if len(key) != 16: raise ValueError('AES-128 key must be 16 bytes')
    out = list(key)
    rc = 1
    while len(out) < 176:
        t = out[-4:]
        if len(out) % 16 == 0:
            t = [_SBOX[t[1]] ^ rc, _SBOX[t[2]], _SBOX[t[3]], _SBOX[t[0]]]
            rc = _gmul(rc, 2)
        for v in t: out.append(out[-16] ^ v)
    return out


def _shift(s, inverse=False):
    direction = -1 if inverse else 1
    return [s[4*((c+direction*r) % 4)+r] for c in range(4) for r in range(4)]


def _mix(s, inverse=False):
    matrix = ((14,11,13,9),(9,14,11,13),(13,9,14,11),(11,13,9,14)) if inverse else ((2,3,1,1),(1,2,3,1),(1,1,2,3),(3,1,1,2))
    out = []
    for c in range(4):
        for row in matrix:
            v = 0
            for j, factor in enumerate(row):
                b = s[c*4+j]
                v ^= b if factor == 1 else _MUL[factor][b]
            out.append(v)
    return out


def _block(block, keys, inverse=False):
    if len(block) != 16: raise ValueError('AES block must be 16 bytes')
    if inverse:
        s = [v ^ keys[160+i] for i,v in enumerate(block)]
        for rnd in range(9, -1, -1):
            s = [_INVBOX[v] for v in _shift(s, True)]
            s = [v ^ keys[16*rnd+i] for i,v in enumerate(s)]
            if rnd: s = _mix(s, True)
    else:
        s = [v ^ keys[i] for i,v in enumerate(block)]
        for rnd in range(1, 11):
            s = _shift([_SBOX[v] for v in s])
            if rnd != 10: s = _mix(s)
            s = [v ^ keys[16*rnd+i] for i,v in enumerate(s)]
    return bytes(s)


def _cbc_encrypt(plain, key, iv):
    n = 16 - len(plain) % 16
    plain += bytes([n])*n
    keys, prev, out = _expand(key), iv, bytearray()
    for i in range(0, len(plain), 16):
        prev = _block(bytes(a ^ b for a,b in zip(plain[i:i+16], prev)), keys)
        out.extend(prev)
    return bytes(out)


def _cbc_decrypt(raw, key):
    if len(raw) < 32 or len(raw) % 16: raise ValueError('Invalid IV/ciphertext length')
    keys, prev, out = _expand(key), raw[:16], bytearray()
    for i in range(16, len(raw), 16):
        current = raw[i:i+16]
        out.extend(a ^ b for a,b in zip(_block(current, keys, True), prev))
        prev = current
    n = out[-1]
    if not 1 <= n <= 16 or out[-n:] != bytes([n])*n: raise ValueError('Invalid PKCS7 padding')
    return bytes(out[:-n])


def derive_key(build_time=DEFAULT_BUILD, package=DEFAULT_PACKAGE):
    return hashlib.md5((str(build_time)+'^~!@#[-'+package).encode('utf-8')).digest()


def _no_constant(value): raise ValueError('Invalid JSON constant: '+value)


def _json(text): return json.loads(text, parse_constant=_no_constant)


def encrypt_request(method, data=None, csrf=None, iv=None, build_time=DEFAULT_BUILD, package=DEFAULT_PACKAGE):
    if not isinstance(method,str) or not method: raise ValueError('Invalid method')
    if data is not None and not isinstance(data,dict): raise ValueError('data must be an object')
    if csrf is None: csrf = time.time_ns() // 1000000
    if type(csrf) is not int or csrf < 0: raise ValueError('Invalid csrf')
    iv = os.urandom(16) if iv is None else iv
    if not isinstance(iv,bytes) or len(iv) != 16: raise ValueError('Invalid IV')
    params = dict(data or {})
    params.setdefault('token','')
    plain = json.dumps({'method':method,'data':params,'csrf':csrf},ensure_ascii=False,separators=(',',':'),allow_nan=False).encode('utf-8')
    return base64.urlsafe_b64encode(iv+_cbc_encrypt(plain,derive_key(build_time,package),iv)).decode('ascii').rstrip('=')


def decrypt_request(body, build_time=DEFAULT_BUILD, package=DEFAULT_PACKAGE):
    if isinstance(body,bytes): body = body.decode('ascii')
    if not isinstance(body,str) or not re.fullmatch(r'[A-Za-z0-9_-]+={0,2}',body): raise ValueError('Invalid Base64url')
    bare = body.rstrip('=')
    if len(bare)%4 == 1: raise ValueError('Invalid Base64url length')
    canonical = bare+'='*(-len(bare)%4)
    if '=' in body and body != canonical: raise ValueError('Invalid Base64 padding')
    raw = base64.b64decode(canonical,altchars=b'-_',validate=True)
    if base64.urlsafe_b64encode(raw).decode('ascii').rstrip('=') != bare: raise ValueError('Noncanonical Base64')
    payload = _json(_cbc_decrypt(raw,derive_key(build_time,package)).decode('utf-8'))
    if not isinstance(payload,dict) or not isinstance(payload.get('method'),str) or not payload['method'] or not isinstance(payload.get('data'),dict) or type(payload.get('csrf')) is not int or payload['csrf']<0: raise ValueError('Invalid request JSON')
    return payload


def decode_response(text, key):
    if not isinstance(text,str): raise ValueError('Response must be text')
    text = text.lstrip('\ufeff').strip()
    try: obj = _json(text)
    except ValueError:
        marker = base64.b64encode(b'xddappsecretkey').decode('ascii')
        pos = text.rfind(marker)
        if pos < 0: raise ValueError('Unknown response encoding')
        trailer = base64.b64decode(text[pos:],validate=True)
        if not re.fullmatch(rb'xddappsecretkey[0-9]+',trailer): raise ValueError('Invalid response marker')
        split = int(trailer[15:])
        if split <= 0 or split % 4 or split >= pos: raise ValueError('Invalid response boundary')
        table = base64.b64decode(text[:split],validate=True).decode('ascii')
        if not re.fullmatch(r'(?:0x[0-9]+)+',table): raise ValueError('Invalid response table')
        ns = [int(x,10) for x in table.split('0x')[1:]][::-1]
        if len(ns) > len(_PREFIX_MASK): raise ValueError('Unknown response prefix: >49 items')
        values = [n-_PREFIX_MASK[i] for i,n in enumerate(ns)]
        if any(n < 0 or n > 255 for n in values): raise ValueError('Invalid response prefix')
        raw = bytes(values)+base64.b64decode(text[split:pos],validate=True)
        obj = _json(_cbc_decrypt(raw,key).decode('utf-8'))
    if not isinstance(obj,dict): raise ValueError('Response JSON must be object')
    return obj


def request_headers():
    return {'User-Agent':'Dart/3.13 (dart:io)','Content-Type':'text/plain',
            'version':'1.0.7','version-number':'17','pk-id':DEFAULT_PACKAGE,
            'build-time':DEFAULT_BUILD,'platform':'ios',
            'platform-version':'Version 27.0.1 (Build 24A446)','Accept-Encoding':'identity'}


class NativeAPIError(RuntimeError): pass


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self,req,fp,code,msg,headers,newurl): return None


class NativeClient:
    def __init__(self, base_url=DEFAULT_BASE, timeout=20):
        self.base_url, self.timeout = base_url.rstrip('/'), timeout
    def call(self, method, data=None):
        req = urllib.request.Request(self.base_url+'/ndsx.php/v7/logs',
              data=encrypt_request(method,data).encode('ascii'),headers=request_headers(),method='POST')
        try:
            with urllib.request.build_opener(_NoRedirect()).open(req,timeout=self.timeout) as r:
                raw = r.read(32*1024*1024+1)
            if len(raw)>32*1024*1024: raise ValueError('Response too large')
            obj = decode_response(raw.decode('utf-8-sig'),derive_key())
        except (OSError,ValueError,UnicodeError) as e: raise NativeAPIError(str(e)) from e
        if str(obj.get('code')) != '1': raise NativeAPIError('API %s: %s'%(obj.get('code'),obj.get('msg','')))
        return obj
    def nav(self): return self.call('nav')
    def home(self): return self.call('index_recommend')
    def search(self, text, page=1): return self.call('search',{'text':text,'pg':int(page)})
    def video_list(self, tid, page=1, **filters):
        data = {'pg':int(page),'tid':int(tid),'class':'','area':'','lang':'','year':'','order':'最新'}
        data.update(filters)
        return self.call('video_list',data)
    def detail(self, vod_id): return self.call('video_detail',{'id':int(vod_id),'sign_md5':'','apk_path':'','apk_length':0})


def _direct_url(url):
    try:
        parsed = urllib.parse.urlsplit(url)
        return parsed.scheme in ('http','https') and bool(parsed.netloc) and bool(re.search(r'\.(?:m3u8|mp4)$',parsed.path,re.I))
    except (ValueError,TypeError): return False

# Public same-protocol parser CRT; verified against captured parser responses.
_RSA_CRT = {'p': 'fbc7ab9d75533e39971e41b554990a57149ea3d115298d9d17630138a40f315339b7a69c6254dde2ffed520f5ad8c48fd2ef18ffd6c97ea0ca8d7329cf0146d5',
 'q': 'f36bda059d298c1cf92fae597fcccc5ccb715e3935b485cb4185d20c6c19a3249ca195f4e604ebf1c26f08f75174e72764499d722ee2e10232f16e3aacd9f0fb',
 'dp': '7f28e1d0bd6f944eabb6d942c67e208dc85932ad273dfc4aa984141ad228e6257d51f670a6ecebbf78b81828af1e296fe5fd61a7dc87994f85dd189bb5f3941d',
 'dq': '6d86a9a2bd0464b6e4a83f9aa596509db02c6268fb712e8236093069c67a029e069bee0d333223b7b3f4a1e42612a3af65c079c756b15eecce5f3369d33c7ce1',
 'qi': '88911352f605c0254a3464d8333520eefdd06e5a985c1f88873714dfbb0764e9fa6b8e95e5e24369d6af22fb849a8c491d64f26e2fb566437b2de514838ca50b'}

# Playback metadata is self-contained, so selection still works after host reload.
_PLAY_PREFIX = 'dsxplay:'


def _http_url(value):
    try:
        p = urllib.parse.urlsplit(value)
        return isinstance(value,str) and p.scheme.lower() in ('http','https') and bool(p.netloc) and not any(c in value for c in '\r\n')
    except (ValueError,TypeError): return False


def _headers(value):
    result = {}
    if isinstance(value,str):
        try: value = _json(value)
        except ValueError:
            value = dict(line.split(':',1) for line in value.replace('\\n','\n').splitlines() if ':' in line)
    if isinstance(value,dict):
        for name,val in value.items():
            name = str(name).strip()
            if (re.fullmatch(r'[A-Za-z0-9!#$%&\'*+.^_`|~-]+',name) and name.lower() not in ('host','content-length','connection','transfer-encoding')
                    and isinstance(val,(str,int,float)) and not any(c in str(val) for c in '\r\n')):
                result[name] = str(val).strip()
    return result


def _merge_headers(*values):
    out = {}
    for value in values:
        for key,val in _headers(value).items():
            for old in list(out):
                if old.lower() == key.lower(): del out[old]
            out[key] = val
    return out


def _source_apis(source):
    values = [source.get('parse_api') or '']
    extra = source.get('extra_parse_api') or ''
    values += extra if isinstance(extra,list) else str(extra).replace('\\n','\n').splitlines()
    return list(dict.fromkeys(x.strip() for x in values if isinstance(x,str) and _http_url(x.strip())))[:5]


def _is_true(value): return value is True or str(value).lower() in ('1','true','yes')


def _pack_play(value):
    return _PLAY_PREFIX+base64.urlsafe_b64encode(json.dumps(value,ensure_ascii=False,separators=(',',':'),allow_nan=False).encode()).decode().rstrip('=')


def _unpack_play(value):
    if not isinstance(value,str) or not value.startswith(_PLAY_PREFIX) or len(value)>60000: raise ValueError('播放描述符无效')
    encoded = value[len(_PLAY_PREFIX):]
    if not re.fullmatch(r'[A-Za-z0-9_-]+',encoded): raise ValueError('播放描述符编码无效')
    obj = _json(base64.b64decode(encoded+'='*(-len(encoded)%4),altchars=b'-_',validate=True).decode('utf-8'))
    if not isinstance(obj,dict) or obj.get('v') != 1 or not isinstance(obj.get('u'),str) or not obj['u'] or len(obj['u'])>16384: raise ValueError('播放描述符内容无效')
    if not isinstance(obj.get('p',[]),list): raise ValueError('解析地址列表无效')
    obj['p'] = list(dict.fromkeys(x for x in obj.get('p',[]) if isinstance(x,str) and _http_url(x)))[:5]
    obj['h'] = _headers(obj.get('h',{}))
    return obj


def _video_id(value):
    if isinstance(value,(list,tuple)):
        if not value: raise ValueError('影片ID为空')
        value = value[0]
    text = str(value)
    if text.isdigit() and int(text)>0: return int(text)
    match = re.search(r'[?&](?:id|vod_id)=(\d+)(?:[&#]|$)',text)
    if not match: match = re.search(r'(?:/|\$)(\d+)(?:[?#].*)?$',text)
    if not match or int(match.group(1))<=0: raise ValueError('影片ID无效')
    return int(match.group(1))


def _build_play_groups(video):
    video = dict(video)
    names,groups,used = [],[],set()
    for source in video.get('vod_url_with_player') or []:
        if not isinstance(source,dict): continue
        code = str(source.get('code') or '')
        apis = _source_apis(source)
        secret = _is_true(source.get('parse_secret'))
        headers = _headers(source.get('headers') or source.get('header') or {})
        normal,backup,seen = [],[],set()
        for part in str(source.get('url') or '').split('#'):
            label,sep,origin = part.partition('$')
            if not sep or not origin or origin in seen: continue
            # Unknown opaque values without a resolver cannot be played.
            if not (_http_url(origin) or apis or secret): continue
            seen.add(origin)
            label = re.sub(r'[$#\r\n]','',label).strip() or str(len(normal)+1)
            meta = {'v':1,'u':origin,'c':code,'p':apis,'h':headers,'s':secret,'m':'auto'}
            normal.append(label+'$'+_pack_play(meta))
            if _direct_url(origin) and (apis or secret):
                backup.append(label+'$'+_pack_play(dict(meta,m='parse')))
        if not normal: continue
        name = re.sub(r'[$#\r\n]','',str(source.get('name') or code or '线路')).strip()
        if name in used: name += '·'+(code or str(len(names)+1))
        while name in used: name += '·备用'
        used.add(name);names.append(name);groups.append('#'.join(normal))
        if backup:
            name += '·解析备用'
            while name in used: name += '·备用'
            used.add(name);names.append(name);groups.append('#'.join(backup))
    video['vod_play_from'],video['vod_play_url'] = '$$$'.join(names),'$$$'.join(groups)
    return video


def _rsa_decode(text):
    raw = str(text).strip().replace('-','+').replace('_','/')
    if not re.fullmatch(r'[A-Za-z0-9+/]+={0,2}',raw): raise ValueError('解析响应不是Base64')
    raw = base64.b64decode(raw+'='*(-len(raw)%4),validate=True)
    if not raw or len(raw)%128 or len(raw)>8192: raise ValueError('RSA响应块大小无效')
    keys = {k:int(v,16) for k,v in _RSA_CRT.items()}
    out = bytearray()
    for i in range(0,len(raw),128):
        c = int.from_bytes(raw[i:i+128],'big')
        if c >= keys['p']*keys['q']: raise ValueError('RSA值超出模数')
        a,b = pow(c,keys['dp'],keys['p']),pow(c,keys['dq'],keys['q'])
        m = b+keys['q']*((a-b)*keys['qi']%keys['p'])
        block = m.to_bytes(128,'big')
        if block[:2] not in (b'\0\1',b'\0\2'): raise ValueError('RSA填充类型无效')
        end = block.find(b'\0',2)
        if end < 10 or (block[1] == 1 and block[2:end] != b'\xff'*(end-2)): raise ValueError('RSA填充无效')
        out.extend(block[end+1:])
    return out.decode('utf-8')


def _parser_reply(text, target=''):
    text = text.lstrip('\ufeff').strip()
    try: return _json(text)
    except ValueError: pass
    if _http_url(text): return {'code':200,'url':text}
    if text.startswith('#EXTM3U') and _http_url(target): return {'code':200,'url':target,'type':'m3u8'}
    return _json(_rsa_decode(text))


def _play_data(obj, inherited=None, depth=0):
    if depth>5: return None
    if isinstance(obj,list):
        for entry in obj:
            found = _play_data(entry,inherited,depth+1)
            if found: return found
        return None
    if isinstance(obj,str): return {'url':obj,'header':_headers(inherited),'type':''} if _http_url(obj) else None
    if not isinstance(obj,dict): return None
    if obj.get('code') is not None and str(obj['code']) not in ('1','200'): return None
    headers = _merge_headers(inherited,obj.get('header'),obj.get('headers'))
    ua = obj.get('UA') or obj.get('ua') or obj.get('user_agent')
    if ua: headers = _merge_headers(headers,{'User-Agent':ua})
    referer = obj.get('referer') or obj.get('Referer')
    if referer: headers = _merge_headers(headers,{'Referer':referer})
    if _http_url(obj.get('url')): return {'url':obj['url'],'header':headers,'type':str(obj.get('type') or '')}
    return _play_data(obj.get('data'),headers,depth+1)


def _parser_target(api, origin):
    escaped = urllib.parse.quote(origin,safe='')
    return api.replace('{url}',escaped) if '{url}' in api else api+escaped


def _read_url(url, headers, timeout=8, limit=2*1024*1024):
    req = urllib.request.Request(url,headers=_merge_headers({'User-Agent':'Dart/3.13 (dart:io)','Accept-Encoding':'identity'},headers))
    with urllib.request.urlopen(req,timeout=max(0.1,timeout)) as response:
        body = response.read(limit+1)
        if len(body)>limit: raise ValueError('解析响应过大')
        return response.status,dict(response.headers),body,response.url


def _sniff_media(body):
    stripped = body.lstrip(b'\xef\xbb\xbf \t\r\n')
    if stripped.startswith(b'#EXTM3U'): return 'm3u8'
    if stripped.startswith((b'<',b'{',b'[')): return ''
    offset = 0
    while offset+8 <= min(len(body),128):
        size = int.from_bytes(body[offset:offset+4],'big')
        kind = body[offset+4:offset+8]
        header = 8
        if size == 1:
            if offset+16 > len(body): break
            size,header = int.from_bytes(body[offset+8:offset+16],'big'),16
        if size < header: break
        if kind in (b'ftyp',b'styp') and size >= header+8: return 'mp4'
        if kind in (b'moof',b'moov',b'mdat',b'sidx'): return 'mp4'
        if kind not in (b'free',b'skip',b'wide') or offset+size > len(body): break
        offset += size
    if body.startswith(b'\x1aE\xdf\xa3'): return 'webm'
    if body.startswith(b'FLV'): return 'flv'
    if body.startswith(b'ID3') or (len(body)>1 and body[0]==255 and body[1]&246==240): return 'audio'
    for offset in range(max(0,min(188,len(body)-376))):
        if body[offset] == body[offset+188] == body[offset+376] == 71: return 'ts'
    return ''


def _probe_media(url, headers, timeout=4):
    # Limit the read even if the upstream ignores Range. Never fetch whole videos.
    req = urllib.request.Request(url,headers=_merge_headers(headers,{'Range':'bytes=0-1023','Accept-Encoding':'identity'}))
    with urllib.request.urlopen(req,timeout=max(0.1,timeout)) as response:
        body = response.read(2048)
        kind = _sniff_media(body)
        if not kind: raise ValueError('媒体探测未通过：未识别到播放列表或媒体头')
        return response.url,kind


class Spider(BaseSpider):
    def getName(self): return '大师兄原生（单文件）'
    def init(self, extend=''): self.client = NativeClient()
    def _api(self):
        if not hasattr(self,'client'): self.client = NativeClient()
        return self.client
    def _catalog_cached(self, key, loader, ttl=300):
        cache = self.__dict__.setdefault('_catalog_cache', {})
        saved = cache.get(key)
        now = time.monotonic()
        if saved and now-saved[0] < ttl:
            return saved[1]
        try:
            value = loader()
            cache[key] = (now, value)
            return value
        except Exception:
            # A stale catalog is useful when its metadata endpoint is unavailable.
            if saved:
                return saved[1]
            raise
    @staticmethod
    def _object_list(value):
        if not isinstance(value, list):
            raise ValueError('分类数据格式无效')
        return [x for x in value if isinstance(x, dict)]
    def _navigation(self):
        def load():
            return self._object_list(self._api().nav().get('data'))
        try:
            return self._catalog_cached('nav', load, 1800)
        except Exception:
            return [{'type_id':i, 'type_name':n, 'type_extend':{}}
                    for i,n in ((1,'电影'),(2,'剧集'),(3,'综艺'),(4,'动漫'),
                                (63,'短剧'),(64,'AI漫剧'),(62,'少儿'),(58,'直播'))]
    def _home_sections(self):
        def load():
            data = self._api().home().get('data')
            if not isinstance(data, dict):
                raise ValueError('首页板块格式无效')
            return self._object_list(data.get('videos'))
        return self._catalog_cached('home', load, 180)
    def _ranking_tabs(self):
        def load():
            return self._object_list(self._api().call('rank_list').get('data'))
        return self._catalog_cached('ranks', load, 1800)
    @staticmethod
    def _clean_text(value):
        return html.unescape(re.sub(r'<[^>]*>', '', str(value or ''))).strip()
    @classmethod
    def _cards(cls, rows):
        output, seen = [], set()
        for row in rows if isinstance(rows, list) else []:
            if not isinstance(row, dict) or row.get('vod_id') is None:
                continue
            key = str(row['vod_id'])
            if key in seen:
                continue
            seen.add(key)
            card = dict(row)
            for name in ('vod_name','vod_remarks','vod_blurb','type_name'):
                if name in card:
                    card[name] = cls._clean_text(card[name])
            output.append(card)
        return output
    @staticmethod
    def _filter_values(value):
        if isinstance(value, str):
            value = re.split(r'[,，\n|]', value)
        if not isinstance(value, (list,tuple)):
            return []
        output, seen = [], set()
        for item in value:
            item = str(item).strip()
            if item and item not in seen and item != '全部':
                seen.add(item)
                output.append({'n':item, 'v':item})
        return output
    @classmethod
    def _category_filters(cls, category):
        extend = category.get('type_extend') or {}
        if not isinstance(extend, dict):
            extend = {}
        filters = []
        for field, label in (('class','类型'),('area','地区'),('lang','语言'),('year','年份')):
            values = cls._filter_values(extend.get(field))
            if values:
                filters.append({'key':field, 'name':label,
                                'value':[{'n':'全部','v':''}]+values})
        # Only publish order values established by the native request captures.
        filters.append({'key':'order','name':'排序','value':[{'n':'最新','v':'最新'}]})
        return filters
    def homeContent(self, filter=False):
        categories, filters, seen = [], {}, set()
        for item in self._navigation():
            tid = str(item.get('type_id',''))
            if not tid.isdigit() or tid in seen:
                continue
            seen.add(tid)
            categories.append({'type_id':tid, 'type_name':self._clean_text(item.get('type_name')) or tid})
            filters[tid] = self._category_filters(item)
        # These are explicitly named views of real server lists, not invented taxonomies.
        for prefix, label, loader in (('rank','榜单·',self._ranking_tabs),
                                      ('home','推荐·',self._home_sections)):
            try:
                entries = loader()
            except Exception:
                entries = []
            for item in entries:
                ident = str(item.get('id',''))
                tid = prefix+':'+ident
                if not ident.isdigit() or tid in seen:
                    continue
                seen.add(tid)
                categories.append({'type_id':tid, 'type_name':label+self._clean_text(item.get('name') or ident)})
        result = {'class':categories}
        if filter:
            result['filters'] = filters
        return result
    def homeVideoContent(self):
        rows = []
        for section in self._home_sections():
            rows.extend(section.get('vlist') or [])
        return {'list':self._cards(rows)}
    @staticmethod
    def _positive_int(value, default=1):
        try:
            value = int(value)
            return value if value > 0 else default
        except (ValueError,TypeError):
            return default
    @classmethod
    def _page(cls, obj):
        rows = cls._cards(obj.get('data'))
        limit = cls._positive_int(obj.get('limit'), len(rows) or 20)
        total = max(len(rows), cls._positive_int(obj.get('total'), len(rows)))
        return {'list':rows,'page':cls._positive_int(obj.get('page')),
                'pagecount':cls._positive_int(obj.get('pagecount'), max(1,(total+limit-1)//limit)),
                'limit':limit,'total':total}
    @classmethod
    def _local_page(cls, rows, page, size=21):
        rows = cls._cards(rows)
        return {'list':rows[(page-1)*size:page*size], 'page':page,
                'pagecount':max(1,(len(rows)+size-1)//size), 'limit':size, 'total':len(rows)}
    def categoryContent(self, tid, pg, filter=False, extend=None):
        page = self._positive_int(pg)
        tid = str(tid)
        if tid.startswith('home:'):
            ident = tid.split(':',1)[1]
            sections = self._home_sections()
            rows = next((s.get('vlist') or [] for s in sections if str(s.get('id')) == ident), [])
            return self._local_page(rows, page)
        if tid.startswith('rank:'):
            ident = tid.split(':',1)[1]
            if not ident.isdigit():
                raise ValueError('榜单ID无效')
            def load():
                # rank_video_list pg is unverified; paginate the actual returned list locally.
                return self._object_list(self._api().call('rank_video_list',{'id':int(ident)}).get('data'))
            return self._local_page(self._catalog_cached('rank:'+ident, load, 120), page)
        if not tid.isdigit():
            raise ValueError('分类ID无效')
        filters = {k:v for k,v in (extend or {}).items() if k in ('class','area','lang','year','order')}
        return self._page(self._api().video_list(int(tid),page,**filters))
    def searchContent(self, key, quick=False, pg=1):
        return self._page(self._api().search(key,self._positive_int(pg)))
    def detailContent(self, ids):
        return {'list':[_build_play_groups(self._api().detail(_video_id(ids))['data']['vod_info'])]}
    def _resolve_play(self, meta):
        deadline = time.monotonic()+25
        origin = meta['u']
        headers = _merge_headers({'User-Agent':'Dart/3.13 (dart:io)'},meta.get('h'))
        failures = []
        def verified(play):
            remaining = deadline-time.monotonic()
            if remaining<=0: raise ValueError('解析达到总时限')
            merged = _merge_headers(headers,play.get('header'))
            url,kind = _probe_media(play['url'],merged,min(4,remaining))
            return {'parse':0,'playUrl':'','url':url,'header':merged,'type':kind,'format':'hls' if kind=='m3u8' else kind}
        if meta.get('m')!='parse' and _http_url(origin) and (_direct_url(origin) or not meta.get('p') and not _is_true(meta.get('s'))):
            try: return verified({'url':origin})
            except Exception as exc: failures.append(str(exc))
        if _is_true(meta.get('s')):
            try:
                reply = self._api().call('secret_parse_api_url',{'url':origin,'player_code':meta.get('c','')})
                play = _play_data(reply)
                if play: return verified(play)
                failures.append('原生解析未返回有效媒体地址')
            except Exception as exc: failures.append(str(exc))
        for api in meta.get('p',[])[:5]:
            remaining = deadline-time.monotonic()
            if remaining<=0: break
            try:
                target = _parser_target(api,origin)
                _,_,body,_ = _read_url(target,headers,min(8,remaining))
                play = _play_data(_parser_reply(body.decode('utf-8-sig'),target))
                if not play: raise ValueError('解析未返回有效媒体地址')
                return verified(play)
            except Exception as exc: failures.append(str(exc))
        if meta.get('m')=='parse' and _direct_url(origin):
            try: return verified({'url':origin})
            except Exception as exc: failures.append(str(exc))
        if not meta.get('p') and not _is_true(meta.get('s')) and _http_url(origin) and not _direct_url(origin):
            return {'parse':1,'playUrl':'','url':origin,'header':headers}
        raise ValueError('该线路当前未取得可验证的媒体，可切换其他线路。'+(' 最后错误：'+failures[-1][:160] if failures else ''))
    def playerContent(self, flag, pid, vipFlags=None):
        if not isinstance(pid,str) or not pid.startswith(_PLAY_PREFIX):
            if not _direct_url(pid): raise ValueError('播放地址无效')
            return {'parse':0,'playUrl':'','url':pid,'header':{'User-Agent':'Dart/3.13 (dart:io)'}}
        meta = _unpack_play(pid)
        cache = self.__dict__.setdefault('_play_cache',{})
        key = hashlib.sha256(pid.encode()).hexdigest()
        saved = cache.get(key)
        if saved and time.monotonic()-saved[0]<60: return dict(saved[1],header=dict(saved[1]['header']))
        result = self._resolve_play(meta)
        if len(cache)>=128: cache.clear()
        cache[key] = (time.monotonic(),dict(result,header=dict(result['header'])))
        return result
    def isVideoFormat(self,url): return isinstance(url,str) and (url.startswith(_PLAY_PREFIX) or _direct_url(url))
    def manualVideoCheck(self): return False
    def localProxy(self,param): return None
    def destroy(self): pass
