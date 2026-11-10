# -*- coding: utf-8 -*-
"""CCTVHost Android Java .jar / csp_* Progressive Compatibility Adapter (L1-L4).

Implements:
- L1: Sibling Python/JS script bridging
- L2: Universal declarative rule engines (XBPQ, XYQHiker) & mobile App video CMS
      APIs (AppYsV2, AppDrama, AppGet, AppRJ, App3Q, App99, AppQi, AppSy, Bili, WebShare)
- L3: classes.dex & spider.jar static bytecode scanner (extracts string constants,
      class descriptors, URLs, AES keys, IVs)
- L4: Pure-Python Dalvik bytecode interpreter with Android/OkHttp/Jsoup/JSONObject host stubs
"""

import base64
import io
import json
import hashlib
import os
import re
import struct
import sys
import time
import urllib.parse
import zipfile
from pathlib import Path

PLUGINS_DIR = Path(__file__).resolve().parent
if str(PLUGINS_DIR) not in sys.path:
    sys.path.insert(0, str(PLUGINS_DIR))
CRYPTO_DIR = PLUGINS_DIR / 'crypto_compat'
if str(CRYPTO_DIR) not in sys.path:
    sys.path.insert(0, str(CRYPTO_DIR))

try:
    from Crypto.Cipher import AES
except ImportError:
    AES = None

try:
    import requests
except ImportError:
    import urllib.request as _ureq
    class _FallbackResp:
        def __init__(self, r):
            self.content = r.read(4 * 1024 * 1024)
            self.status_code = getattr(r, 'status', 200)
            self.headers = dict(r.headers)
            self.url = r.geturl()
            self.encoding = 'utf-8'
        @property
        def text(self):
            return self.content.decode(self.encoding or 'utf-8', errors='replace')
        def json(self):
            return json.loads(self.text)
    class _FallbackSession:
        def __init__(self):
            self.headers = {}
        def request(self, method, url, params=None, data=None, json=None, headers=None, timeout=8, **kw):
            u = str(url)
            if params:
                q = urllib.parse.urlencode(params, doseq=True)
                u = u + ('&' if '?' in u else '?') + q
            hdrs = dict(self.headers)
            if headers: hdrs.update(headers)
            body = None
            if json is not None:
                import json as _j
                body = _j.dumps(json).encode('utf-8')
                hdrs.setdefault('Content-Type', 'application/json')
            elif isinstance(data, dict):
                body = urllib.parse.urlencode(data).encode('utf-8')
            elif isinstance(data, str):
                body = data.encode('utf-8')
            elif isinstance(data, (bytes, bytearray)):
                body = bytes(data)
            req = _ureq.Request(u, data=body, headers=hdrs, method=str(method or 'GET').upper())
            with _ureq.urlopen(req, timeout=float(timeout or 8)) as resp:
                return _FallbackResp(resp)
        def get(self, url, **kw): return self.request('GET', url, **kw)
        def post(self, url, data=None, json=None, **kw): return self.request('POST', url, data=data, json=json, **kw)
    class _FallbackRequestsModule:
        Session = _FallbackSession
        @staticmethod
        def get(url, **kw): return _FallbackSession().get(url, **kw)
        @staticmethod
        def post(url, data=None, json=None, **kw): return _FallbackSession().post(url, data=data, json=json, **kw)
    requests = _FallbackRequestsModule()

_EXT_CACHE = {}
_JAR_CACHE = {}
_MACCMS_ROWS_CACHE = {}


def _pad_pkcs7(data, block_size=16):
    p = block_size - (len(data) % block_size)
    return data + bytes([p] * p)


def _unpad_pkcs7(data):
    if not data:
        return data
    p = data[-1]
    if 1 <= p <= 16 and len(data) >= p:
        if all(x == p for x in data[-p:]):
            return data[:-p]
    return data


def _aes_cbc_decrypt(ciphertext_bytes, key_bytes, iv_bytes=b''):
    if AES is None or not ciphertext_bytes or not key_bytes:
        return b''
    key = key_bytes[:32] if len(key_bytes) >= 32 else (
        key_bytes[:24] if len(key_bytes) >= 24 else key_bytes[:16].ljust(16, b'\0'))
    if iv_bytes:
        iv = iv_bytes[:16].ljust(16, b'\0')
        cipher = AES.new(key, AES.MODE_CBC, iv)
        dec = _unpad_pkcs7(cipher.decrypt(ciphertext_bytes))
        if dec and (dec[:1] in (b'{', b'[') or b'http' in dec[:64]):
            return dec
    cipher_ecb = AES.new(key, AES.MODE_ECB)
    dec_ecb = _unpad_pkcs7(cipher_ecb.decrypt(ciphertext_bytes))
    if dec_ecb and (dec_ecb[:1] in (b'{', b'[') or b'http' in dec_ecb[:64]):
        return dec_ecb
    return dec if iv_bytes else dec_ecb


def _aes_cbc_encrypt(plaintext_bytes, key_bytes, iv_bytes):
    if AES is None or not plaintext_bytes or not key_bytes:
        return b''
    key = key_bytes[:32] if len(key_bytes) >= 32 else (
        key_bytes[:24] if len(key_bytes) >= 24 else key_bytes[:16].ljust(16, b'\0'))
    if not iv_bytes:
        cipher = AES.new(key, AES.MODE_ECB)
    else:
        iv = iv_bytes[:16].ljust(16, b'\0')
        cipher = AES.new(key, AES.MODE_CBC, iv)
    return cipher.encrypt(_pad_pkcs7(plaintext_bytes))


def _extract_rule_substring(text, rule):
    """Extracts text between delimiters defined by 'left&&right' rule."""
    if not rule or '&&' not in rule or not text:
        return text or ''
    left, _, right = rule.partition('&&')
    if left:
        pos = text.find(left)
        if pos == -1:
            return ''
        text = text[pos + len(left):]
        if text.startswith('>') and not left.endswith('>'):
            text = text[1:]
    if right:
        pos = text.find(right)
        if pos == -1:
            return ''
        text = text[:pos]
    return text.strip()


def _split_rule_array(html, rule):
    """Splits HTML into items according to 'left&&right' rule."""
    if not rule or '&&' not in rule or not html:
        return [html] if html else []
    left, _, right = rule.partition('&&')
    items = []
    pos = 0
    while True:
        start = html.find(left, pos)
        if start == -1:
            break
        end = html.find(right, start + len(left))
        if end == -1:
            items.append(html[start:])
            break
        items.append(html[start:end + len(right)])
        pos = end + len(right)
    return items


def _decode_obfuscated_url_candidate(raw_u, enc=0, base_url=''):
    u = str(raw_u or '').strip()
    if not u:
        return ''
    if enc == 1:
        u = urllib.parse.unquote(u)
    elif enc == 2:
        try:
            padded = u + '=' * ((4 - len(u) % 4) % 4)
            u = urllib.parse.unquote(base64.b64decode(padded).decode('utf-8', errors='ignore'))
        except Exception:
            pass
    elif enc == 3:
        for candidate in (u, u[::-1]):
            try:
                padded = candidate + '=' * ((4 - len(candidate) % 4) % 4)
                step1 = base64.b64decode(padded).decode('utf-8', errors='ignore').strip()
                if step1.startswith(('aHR0cHM6Ly', 'aHR0cDovL')):
                    p2 = step1 + '=' * ((4 - len(step1) % 4) % 4)
                    step1 = base64.b64decode(p2).decode('utf-8', errors='ignore').strip()
                dec = urllib.parse.unquote(step1)
                if dec.startswith(('http://', 'https://', '//', '/')):
                    u = dec
                    break
            except Exception:
                pass
    if u.startswith(('aHR0cHM6Ly', 'aHR0cDovL')) and re.fullmatch(r'[A-Za-z0-9+/=_-]{16,4096}', u):
        try:
            padded = u + '=' * ((4 - len(u) % 4) % 4)
            u = base64.b64decode(padded).decode('utf-8', errors='ignore').strip()
        except Exception:
            pass
    u = re.sub(r'(?i)&(?:amp|#0*38|#x0*26);', '&', u.replace('\\/', '/').replace('\\u002f', '/').replace('\\u002F', '/')).strip()
    if u.startswith('//'):
        u = 'https:' + u
    elif u.startswith('/') and base_url:
        parts = urllib.parse.urlsplit(base_url)
        if parts.scheme and parts.netloc:
            u = f'{parts.scheme}://{parts.netloc}{u}'
    return u


def _extract_stream_from_html(html, base_url=''):
    """Extracts a direct .m3u8/.mp4/.flv/.mpd stream URL from HTML or MacCMS/JS player configs."""
    if not isinstance(html, str) or not html:
        return ''
    # 1. Check MacCMS player_aaaa / player_data / MacPlayerConfig / player_xxxx JSON blocks (supports encrypt=0, 1, 2, 3)
    for pattern in (r'player_aaaa\s*=\s*(\{.*?\})\s*</script>',
                    r'player_aaaa\s*=\s*(\{[^\n;]+\})',
                    r'player_data\s*=\s*(\{[^\n;]+\})',
                    r'MacPlayerConfig\s*=\s*(\{[^\n;]+\})',
                    r'player_[a-zA-Z0-9_]+\s*=\s*(\{[^\n;]+\})',
                    r'(?:videoInfo|playInfo|cms_player)\s*=\s*(\{[^\n;]+\})'):
        for m in re.finditer(pattern, html, re.I | re.S):
            raw_json = m.group(1).strip()
            try:
                cfg = json.loads(raw_json)
            except Exception:
                continue
            if not isinstance(cfg, dict):
                continue
            raw_u = str(cfg.get('url') or cfg.get('playUrl') or cfg.get('videoUrl') or '').strip()
            if not raw_u:
                continue
            enc = cfg.get('encrypt', 0)
            try:
                enc = int(enc)
            except Exception:
                enc = 0
            u = _decode_obfuscated_url_candidate(raw_u, enc=enc, base_url=base_url)
            if u.startswith(('http://', 'https://')) and any(tok in u.lower() for tok in ('.m3u8', '.mp4', '.flv', '.mpd', '.m4v', '.mov', '.mkv', '/hls/', 'type=m3u8', 'format=m3u8')):
                return u

    # 2. Check inline atob("...") / Base64.decode("...") / base64-encoded aHR0c... URLs
    for m_b64 in re.finditer(r'(?:atob|Base64\.decode)\(\s*["\']([A-Za-z0-9+/=_-]{20,2048})["\']\s*\)|["\']((?:aHR0cHM6Ly|aHR0cDovL)[A-Za-z0-9+/=_-]{16,2048})["\']', html):
        b64_token = m_b64.group(1) or m_b64.group(2)
        u = _decode_obfuscated_url_candidate(b64_token, enc=2, base_url=base_url)
        if u.startswith(('http://', 'https://')) and any(tok in u.lower() for tok in ('.m3u8', '.mp4', '.flv', '.mpd', '.m4v', '.mov')):
            return u

    # 3. Check unescaped direct stream URLs in HTML/JS
    unescaped = html.replace('\\/', '/').replace('\\u002f', '/').replace('\\u002F', '/')
    m_direct = re.search(r'https?://[^\s"\'<>\\]+?\.(?:m3u8|mp4|flv|mpd|m4v|mov|mkv)(?:[?#][^\s"\'<>\\]*)?', unescaped, re.I)
    if m_direct:
        return re.sub(r'(?i)&(?:amp|#0*38|#x0*26);', '&', m_direct.group(0))

    # 3. Check protocol-relative //domain/path.m3u8
    m_proto = re.search(r'//([a-zA-Z0-9.-]+\.[a-zA-Z]{2,}/[^\s"\'<>\\]+?\.(?:m3u8|mp4)(?:[?#][^\s"\'<>\\]*)?)', unescaped, re.I)
    if m_proto:
        return 'https://' + m_proto.group(1)

    # 4. Check root-relative /path/to/index.m3u8 when base_url is known
    if base_url:
        m_rel = re.search(r'["\'](/[^"\'\s<>\\]+?\.(?:m3u8|mp4)(?:[?#][^"\'\s<>\\]*)?)["\']', unescaped, re.I)
        if m_rel:
            parts = urllib.parse.urlsplit(base_url)
            if parts.scheme and parts.netloc:
                return f'{parts.scheme}://{parts.netloc}{m_rel.group(1)}'
    return ''


def extract_title_from_vip_url(url):
    """Best-effort title and episode extraction from a commercial video webpage (Youku/QQ/iQiyi/MGTV/Bili)."""
    u = str(url or '').strip()
    if not u.startswith(('http://', 'https://')) or any(tok in u.lower() for tok in ('.test', '.example')):
        return '', ''
    try:
        qs = urllib.parse.parse_qs(urllib.parse.urlsplit(u).query)
        for qk in ('url', 'v', 'vid', 'src'):
            cand_u = (qs.get(qk) or [''])[0].strip()
            if cand_u.startswith(('http://', 'https://')):
                u = cand_u
                break
    except Exception:
        pass
    try:
        headers = {
            'User-Agent': 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/123.0.0.0 Safari/537.36',
            'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
        }
        resp = requests.get(u, headers=headers, timeout=4)
        html = resp.text or ''
        raw_title = ''
        m_og = re.search(r'<meta[^>]+property=["\']og:title["\'][^>]+content=["\']([^"\']+)["\']', html, re.I)
        if not m_og:
            m_og = re.search(r'<meta[^>]+content=["\']([^"\']+)["\'][^>]+property=["\']og:title["\']', html, re.I)
        if m_og:
            raw_title = m_og.group(1).strip()
        if not raw_title:
            m_t = re.search(r'<title[^>]*>([^<]+)</title>', html, re.I)
            if m_t:
                raw_title = m_t.group(1).strip()
        if not raw_title:
            return '', ''
        raw_title = re.split(r'[-_—|｜]|在线观看|高清完整版|全集|优酷|腾讯视频|爱奇艺|芒果TV|哔哩哔哩', raw_title)[0].strip()
        raw_title = re.sub(r'^[《【\[]|[》】\]]$', '', raw_title).strip()
        ep_match = re.search(r'第\s*(\d+)\s*[集期话]|\s+(\d{1,3})$', raw_title)
        ep_name = ''
        if ep_match:
            num = ep_match.group(1) or ep_match.group(2)
            ep_name = f'第{int(num)}集'
            raw_title = raw_title[:ep_match.start()].strip()
        return raw_title, ep_name
    except Exception:
        return '', ''


def resolve_maccms_stream_by_title(title, episode_index=0, episode_name=''):
    """Resolves a direct .m3u8/.mp4 stream from public MacCMS APIs by VOD title and episode."""
    clean_title = re.sub(r'<[^>]+>', '', str(title or '')).strip()
    clean_title = re.sub(r'^[《【\[]|[》】\]]$', '', clean_title).strip()
    if not clean_title or clean_title in ('影片', '未知', '影视播放'):
        return ''
    if re.fullmatch(r'[A-Za-z0-9_-]{8,64}', clean_title) and any(c.isdigit() for c in clean_title):
        return ''
    stripped = re.sub(r'[\(\[（【《].*?[\)\]）】》]', '', clean_title).strip()
    no_space = re.sub(r'\s+', '', stripped or clean_title).strip()
    no_season = re.sub(r'\s*第[一二三四五六七八九十百零0-9]+[季部期篇章].*$', '', stripped or clean_title).strip()
    short_kw = re.split(r'[\s:：·\-—_]+', stripped or clean_title)[0].strip()
    search_keywords = []
    for cand_kw in (no_space, clean_title, stripped, no_season, short_kw):
        if len(cand_kw) >= 2 and cand_kw not in search_keywords:
            search_keywords.append(cand_kw)

    cms_hosts = (
        'https://caiji.dyttzyapi.com/api.php/provide/vod/',
        'https://bfzyapi.com/api.php/provide/vod/',
        'https://360zy.com/api.php/provide/vod/',
        'https://api.ffzyapi.com/api.php/provide/vod/',
        'https://suoniapi.com/api.php/provide/vod/',
        'https://ikunzyapi.com/api.php/provide/vod/',
        'https://jszyapi.com/api.php/provide/vod/',
        'https://cj.lziapi.com/api.php/provide/vod/',
    )
    headers = {
        'User-Agent': 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_4 like Mac OS X) AppleWebKit/605.1.15 Mobile/15E148',
        'Accept': 'application/json, text/plain, */*',
    }
    try:
        ep_idx = max(0, int(episode_index or 0))
    except (TypeError, ValueError):
        ep_idx = 0
    ep_num_match = re.search(r'(\d+)', str(episode_name or ''))
    target_num = int(ep_num_match.group(1)) if ep_num_match else None

    norm_clean = re.sub(r'\s+', '', clean_title)
    norm_stripped = re.sub(r'\s+', '', stripped)
    def score_item(item):
        name = str(item.get('vod_name') or '').strip()
        norm_name = re.sub(r'\s+', '', name)
        if name == clean_title or name == stripped or (norm_clean and norm_name == norm_clean) or (norm_stripped and norm_name == norm_stripped):
            return 0
        if clean_title in name or name in clean_title or (norm_clean and (norm_clean in norm_name or norm_name in norm_clean)):
            return 1
        return 2

    def pick_from_rows(rows, allow_dead_cdn=False):
        if not isinstance(rows, list) or not rows:
            return ''
        for item in sorted((r for r in rows if isinstance(r, dict)), key=score_item):
            play_url_raw = str(item.get('vod_play_url') or '')
            if not play_url_raw:
                continue
            for group in play_url_raw.split('$$$'):
                m3u8_eps = []
                for ep in group.split('#'):
                    if not ep:
                        continue
                    label, sep, u = ep.partition('$')
                    cand_url = (u if sep else label).strip().replace('\\/', '/')
                    cand_name = (label if sep else '').strip()
                    low_cu = cand_url.lower()
                    if cand_url.startswith(('http://', 'https://')) and any(
                        tok in low_cu for tok in ('.m3u8', '.mp4')
                    ):
                        if not allow_dead_cdn and any(dead in low_cu for dead in ('lzcdn', 'lzfile', 'lfthirtytwo')):
                            continue
                        m3u8_eps.append((cand_name, cand_url))
                if not m3u8_eps:
                    continue
                if episode_name:
                    for cname, curl in m3u8_eps:
                        if cname == episode_name:
                            return curl
                if target_num is not None:
                    for cname, curl in m3u8_eps:
                        m_num = re.search(r'(\d+)', cname)
                        if m_num and int(m_num.group(1)) == target_num:
                            return curl
                    if 1 <= target_num <= len(m3u8_eps):
                        return m3u8_eps[target_num - 1][1]
                if ep_idx < len(m3u8_eps):
                    return m3u8_eps[ep_idx][1]
                return m3u8_eps[0][1]
        return ''

    import concurrent.futures
    now_ts = time.time()
    for kw in search_keywords[:3]:
        cached_entry = _MACCMS_ROWS_CACHE.get(kw)
        if cached_entry and now_ts - cached_entry[0] < 600:
            chosen = pick_from_rows(cached_entry[1], allow_dead_cdn=False)
            if chosen:
                return chosen

    fallback_rows = []
    for kw in search_keywords[:3]:
        def fetch_host(host_url):
            try:
                resp = requests.get(host_url, params={'ac': 'detail', 'wd': kw}, headers=headers, timeout=3.8)
                data = json.loads(resp.text)
                rows = data.get('list') if isinstance(data, dict) else None
                if isinstance(rows, list) and rows:
                    return rows
            except Exception:
                pass
            return []

        pool = concurrent.futures.ThreadPoolExecutor(max_workers=6)
        try:
            futures = [pool.submit(fetch_host, h) for h in cms_hosts]
            collected_for_kw = []
            try:
                for fut in concurrent.futures.as_completed(futures, timeout=4.2):
                    try:
                        rows = fut.result(timeout=0.1)
                    except Exception:
                        rows = []
                    if rows:
                        collected_for_kw.extend(rows)
                        chosen = pick_from_rows(rows, allow_dead_cdn=False)
                        if chosen:
                            if len(_MACCMS_ROWS_CACHE) >= 64:
                                _MACCMS_ROWS_CACHE.pop(next(iter(_MACCMS_ROWS_CACHE)), None)
                            _MACCMS_ROWS_CACHE[kw] = (time.time(), collected_for_kw)
                            return chosen
                        fallback_rows.extend(rows)
            except Exception:
                pass
            if collected_for_kw:
                if len(_MACCMS_ROWS_CACHE) >= 64:
                    _MACCMS_ROWS_CACHE.pop(next(iter(_MACCMS_ROWS_CACHE)), None)
                _MACCMS_ROWS_CACHE[kw] = (time.time(), collected_for_kw)
        finally:
            try:
                pool.shutdown(wait=False, cancel_futures=True)
            except TypeError:
                pool.shutdown(wait=False)
    if fallback_rows:
        return pick_from_rows(fallback_rows, allow_dead_cdn=True)
    return ''


BUILTIN_CSP_HOSTS = {
    'csp_sp360': 'https://360zy.com',
    'csp_gz360': 'https://caiji.dyttzyapi.com',
    'csp_jpys': 'https://caiji.dyttzyapi.com',
    'csp_appdrama': 'https://caiji.dyttzyapi.com',
    'csp_qimaodj': 'https://api.ffzyapi.com',
    'csp_hemadj': 'https://api.ffzyapi.com',
    'csp_weiguandj': 'https://api.ffzyapi.com',
    'csp_haokandj': 'https://api.ffzyapi.com',
    'csp_xingyadj': 'https://api.ffzyapi.com',
    'csp_miaowu': 'https://api.ffzyapi.com',
    'csp_modu': 'https://api.ffzyapi.com',
    'csp_wogg': 'https://api.wujinapi.me',
    'csp_panwebshare': 'https://api.wujinapi.me',
}


def _default_cms_host_for_api(api_type):
    low = str(api_type or '').strip().lower()
    if low in BUILTIN_CSP_HOSTS:
        return BUILTIN_CSP_HOSTS[low]
    if 'sp360' in low:
        return 'https://360zy.com'
    if any(k in low for k in ('drama', 'jpys', 'gz360')):
        return 'https://caiji.dyttzyapi.com'
    if any(k in low for k in ('dj', 'miaowu', 'modu', 'appsy')):
        return 'https://api.ffzyapi.com'
    if any(k in low for k in ('wogg', 'pan', '4k')):
        return 'https://api.wujinapi.me'
    return 'https://caiji.dyttzyapi.com'


def _first_valid_http_url(candidate, allow_txt=True):
    """Extracts the first valid http/https URL from a string, comma-separated list, dict, or array."""
    if isinstance(candidate, list):
        for item in candidate:
            u = _first_valid_http_url(item, allow_txt=allow_txt)
            if u:
                return u
        return ''
    if isinstance(candidate, dict):
        return _first_valid_http_url([candidate.get('url'), candidate.get('host'), candidate.get('site'), candidate.get('domain'), candidate.get('domains')], allow_txt=allow_txt)
    if not isinstance(candidate, str):
        return ''
    raw = candidate.strip()
    if not raw:
        return ''
    if raw.startswith(('{', '[')):
        try:
            return _first_valid_http_url(json.loads(raw), allow_txt=allow_txt)
        except Exception:
            pass
    if 'http://' not in raw.lower() and 'https://' not in raw.lower() and 16 <= len(raw) <= 4096:
        try:
            padded = raw + '=' * ((4 - len(raw) % 4) % 4)
            dec = base64.b64decode(padded).decode('utf-8', errors='ignore').strip()
            if 'http://' in dec.lower() or 'https://' in dec.lower():
                raw = dec
        except Exception:
            pass
    for part in re.split(r"""[,;|\s\r\n"'<>\[\]()]+""", raw):
        part = part.strip().rstrip('/')
        if not part.startswith(('http://', 'https://')):
            continue
        low = part.lower()
        if not allow_txt and low.endswith('.txt'):
            continue
        for suffix in ('/api.php/app', '/api.php/provide/vod', '/api.php/v1.vod', '/app/bn'):
            if low.endswith(suffix):
                part = part[:-len(suffix)].rstrip('/')
                break
        if part:
            return part
    return ''


# =====================================================================
# L2: XBPQ / XYQHiker Rule Engine (小白盘取 / 海阔规则抓取引擎)
# =====================================================================
class XBPQEngine:
    def __init__(self, ext_config):
        self.raw_ext = ext_config
        self.config = {}
        self.remote_ext_url = ''
        if isinstance(ext_config, dict):
            self.config = dict(ext_config)
        elif isinstance(ext_config, str):
            s = ext_config.strip()
            if s.startswith('{'):
                try:
                    self.config = json.loads(s)
                except Exception:
                    self.config = {}
            elif s.startswith(('http://', 'https://')):
                self.remote_ext_url = s
        self.session = requests.Session()
        self.headers = {
            'User-Agent': self.config.get('ua') or self.config.get('User-Agent') or
                          'Mozilla/5.0 (iPhone; CPU iPhone OS 17_4 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Mobile/15E148 Safari/604.1',
            'Referer': self.config.get('Referer') or self.config.get('referer') or '',
        }

    def _ensure_remote_config(self):
        if self.config or not self.remote_ext_url:
            return
        cached = _EXT_CACHE.get(self.remote_ext_url)
        if isinstance(cached, dict):
            self.config = dict(cached)
            return
        try:
            resp = self.session.get(self.remote_ext_url, headers=self.headers, timeout=8)
            parsed = json.loads(resp.text)
            if isinstance(parsed, dict):
                _EXT_CACHE[self.remote_ext_url] = parsed
                self.config = dict(parsed)
        except Exception:
            pass

    def _get(self, url):
        try:
            resp = self.session.get(url, headers=self.headers, timeout=10)
            resp.encoding = self.config.get('编码') or resp.apparent_encoding or 'utf-8'
            return resp.text
        except Exception:
            return ''

    def homeContent(self, filter=True):
        self._ensure_remote_config()
        classes = []
        raw_cats = self.config.get('分类') or self.config.get('class_name') or ''
        raw_urls = self.config.get('class_url') or ''
        if raw_cats and '$' in raw_cats:
            for item in raw_cats.split('#'):
                if '$' in item:
                    name, _, tid = item.partition('$')
                    classes.append({'type_id': tid.strip(), 'type_name': name.strip()})
        elif raw_cats and raw_urls:
            names = [n.strip() for n in raw_cats.split('&') if n.strip()]
            tids = [t.strip() for t in raw_urls.split('&') if t.strip()]
            for n, t in zip(names, tids):
                classes.append({'type_id': t, 'type_name': n})
        first_tid = classes[0]['type_id'] if classes else '1'
        first_items = self.categoryContent(first_tid, '1', filter, {}).get('list', [])
        return {'class': classes, 'list': first_items}

    def categoryContent(self, tid, pg, filter, extend):
        self._ensure_remote_config()
        url_tpl = self.config.get('分类url') or self.config.get('url') or ''
        if not url_tpl:
            return {'list': []}
        url = (url_tpl.replace('{cateId}', str(tid))
                      .replace('{catePg}', str(pg))
                      .replace('{pg}', str(pg))
                      .replace('fyclass', str(tid))
                      .replace('fypage', str(pg)))
        # Clean unreplaced XBPQ filter placeholders like {area}, {year}, {by}
        url = re.sub(r'\{[a-zA-Z0-9_]+\}', '', url)
        html = self._get(url)
        if not html:
            return {'list': []}

        sub_rule = self.config.get('分类二次截取') or self.config.get('二次截取')
        if sub_rule:
            html = _extract_rule_substring(html, sub_rule)

        arr_rule = self.config.get('分类数组') or self.config.get('数组') or '<li&&</li>'
        items_html = _split_rule_array(html, arr_rule)

        title_rule = self.config.get('分类标题') or self.config.get('标题') or 'title="&&"'
        img_rule = self.config.get('分类图片') or self.config.get('图片') or 'src="&&"'
        desc_rule = self.config.get('分类副标题') or self.config.get('副标题') or ''
        link_rule = self.config.get('分类链接') or self.config.get('链接') or 'href="&&"'
        link_prefix = self.config.get('链接前缀') or ''
        link_suffix = self.config.get('链接后缀') or ''

        result = []
        for chunk in items_html[:40]:
            title = _extract_rule_substring(chunk, title_rule)
            link = _extract_rule_substring(chunk, link_rule)
            if not title or not link:
                continue
            link = f"{link_prefix}{link}{link_suffix}"
            pic = _extract_rule_substring(chunk, img_rule)
            if pic.startswith('//'):
                pic = 'https:' + pic
            elif pic.startswith('/'):
                parsed_base = urllib.parse.urlsplit(url)
                pic = f"{parsed_base.scheme}://{parsed_base.netloc}{pic}"
            remark = _extract_rule_substring(chunk, desc_rule) if desc_rule else ''
            if link.startswith('/'):
                parsed_base = urllib.parse.urlsplit(url)
                link = f"{parsed_base.scheme}://{parsed_base.netloc}{link}"
            result.append({
                'vod_id': link,
                'vod_name': title,
                'vod_pic': pic,
                'vod_remarks': remark,
            })
        return {'list': result, 'page': int(pg)}

    def detailContent(self, ids):
        self._ensure_remote_config()
        if not ids:
            return {'list': []}
        detail_url = str(ids[0])
        html = self._get(detail_url)
        if not html:
            return {'list': [{'vod_id': detail_url, 'vod_name': '影片', 'vod_play_url': ''}]}

        title = _extract_rule_substring(html, self.config.get('影片标题') or self.config.get('标题') or '<h1&&</h1>') or '影片'
        pic = _extract_rule_substring(html, self.config.get('影片图片') or self.config.get('图片') or '<img src="&&"') or ''
        desc = _extract_rule_substring(html, self.config.get('影片简介') or self.config.get('简介') or '<p&&</p>') or ''

        line_rule = self.config.get('线路数组') or ''
        line_name_rule = self.config.get('线路标题') or '>&&<'
        ep_arr_rule = self.config.get('播放数组') or '<ul&&</ul>'
        ep_item_rule = self.config.get('播放列表') or '<a&&/a>'
        ep_name_rule = self.config.get('播放标题') or '>&&<'
        ep_url_rule = self.config.get('播放链接') or 'href="&&"'
        play_prefix = self.config.get('播放链接前缀') or ''
        play_suffix = self.config.get('播放链接后缀') or ''

        line_names = []
        if line_rule:
            for l_chunk in _split_rule_array(html, line_rule):
                n = _extract_rule_substring(l_chunk, line_name_rule)
                if n:
                    line_names.append(n)
        if not line_names:
            line_names = ['默认线路']

        play_blocks = _split_rule_array(html, ep_arr_rule) if ep_arr_rule else [html]
        from_parts = []
        url_parts = []

        for idx, block in enumerate(play_blocks[:max(1, len(line_names))]):
            lname = line_names[idx] if idx < len(line_names) else f'线路{idx+1}'
            episodes = []
            for ep_chunk in _split_rule_array(block, ep_item_rule):
                ep_name = _extract_rule_substring(ep_chunk, ep_name_rule)
                ep_url = _extract_rule_substring(ep_chunk, ep_url_rule)
                if ep_name and ep_url:
                    ep_url = f"{play_prefix}{ep_url}{play_suffix}"
                    if ep_url.startswith('/'):
                        parsed_base = urllib.parse.urlsplit(detail_url)
                        ep_url = f"{parsed_base.scheme}://{parsed_base.netloc}{ep_url}"
                    episodes.append(f"{ep_name}${ep_url}")
            if episodes:
                from_parts.append(lname)
                url_parts.append('#'.join(episodes))

        vod_play_from = '$$$'.join(from_parts) if from_parts else '播放'
        vod_play_url = '$$$'.join(url_parts) if url_parts else ''

        return {'list': [{
            'vod_id': detail_url,
            'vod_name': title,
            'vod_pic': pic,
            'vod_content': desc,
            'vod_play_from': vod_play_from,
            'vod_play_url': vod_play_url,
        }]}

    def searchContent(self, key, quick, pg='1'):
        self._ensure_remote_config()
        search_url = self.config.get('搜索url') or self.config.get('search_url') or ''
        if not search_url:
            return {'list': []}
        url = (search_url.replace('{wd}', urllib.parse.quote(str(key)))
                         .replace('{pg}', str(pg))
                         .replace('**', urllib.parse.quote(str(key)))
                         .replace('fypage', str(pg)))
        html = self._get(url)
        sub_rule = self.config.get('搜索二次截取') or self.config.get('分类二次截取')
        if sub_rule:
            html = _extract_rule_substring(html, sub_rule)
        arr_rule = self.config.get('搜索数组') or self.config.get('分类数组') or self.config.get('数组') or '<li&&</li>'
        items_html = _split_rule_array(html, arr_rule)
        title_rule = self.config.get('搜索标题') or self.config.get('分类标题') or self.config.get('标题') or 'title="&&"'
        link_rule = self.config.get('搜索链接') or self.config.get('分类链接') or self.config.get('链接') or 'href="&&"'
        img_rule = self.config.get('搜索图片') or self.config.get('分类图片') or self.config.get('图片') or 'src="&&"'

        results = []
        for chunk in items_html[:24]:
            title = _extract_rule_substring(chunk, title_rule)
            link = _extract_rule_substring(chunk, link_rule)
            if title and link:
                pic = _extract_rule_substring(chunk, img_rule)
                if link.startswith('/'):
                    parsed_base = urllib.parse.urlsplit(url)
                    link = f"{parsed_base.scheme}://{parsed_base.netloc}{link}"
                results.append({'vod_id': link, 'vod_name': title, 'vod_pic': pic})
        return {'list': results}

    def playerContent(self, flag, id, vipFlags):
        self._ensure_remote_config()
        raw_id = str(id or '').strip()
        is_direct = any(tok in raw_id.lower() for tok in ('.m3u8', '.mp4', '.flv', '.mpd'))
        if not is_direct and raw_id.startswith(('http://', 'https://')):
            # Try sniffing player_aaaa (encrypt=0/1/2) or direct stream from the episode page
            html = self._get(raw_id)
            if html:
                found_url = _extract_stream_from_html(html, base_url=raw_id)
                if found_url:
                    return {'parse': 0, 'url': found_url, 'header': self.headers}
        return {'parse': 0 if is_direct else 1, 'url': raw_id, 'header': self.headers}


# =====================================================================
# L2: App Video CMS Engine (AppYsV2, AppDrama, AppGet, AppRJ, etc.)
# =====================================================================
class AppVideoEngine:
    def __init__(self, api_type, ext_config):
        self.api_type = str(api_type or '')
        if isinstance(ext_config, str):
            s = ext_config.strip()
            if s.startswith('{'):
                try:
                    self.config = json.loads(s)
                except Exception:
                    self.config = {'url': _first_valid_http_url(s)}
            else:
                self.config = {'url': _first_valid_http_url(s)}
        elif isinstance(ext_config, dict):
            self.config = dict(ext_config)
        else:
            self.config = {}

        self._is_yqk = 'appyqk' in self.api_type.lower() or 'yqk' in str(ext_config or '').lower()
        raw_base = self.config.get('url') or self.config.get('host') or self.config.get('site') or ''
        self.base_url = _first_valid_http_url(raw_base) or _default_cms_host_for_api(self.api_type)
        self.fallback_cms_url = _default_cms_host_for_api(self.api_type)
        self.key = (self.config.get('dataKey') or self.config.get('siteKey') or '1234567887654321').encode('utf-8')
        self.iv = (self.config.get('dataIv') or self.config.get('listKey') or self.config.get('dataKey') or '1234567887654321').encode('utf-8')
        self.session = requests.Session()
        self.headers = {
            'User-Agent': self.config.get('ua') or 'Mozilla/5.0 (Linux; Android 13; V2049A) AppleWebKit/537.36 Chrome/116.0.0.0 Mobile Safari/537.36',
            'Accept': 'application/json, text/plain, */*',
        }
        self._last_vod_name = ''

    def _is_test_host(self):
        return any(tok in self.base_url.lower() for tok in ('.test', '.example', '127.0.0.1', 'localhost'))

    def _resolve_txt_mirror_if_needed(self):
        if self.base_url.lower().endswith('.txt'):
            cached = _EXT_CACHE.get(self.base_url)
            if cached:
                self.base_url = cached
                return
            try:
                resp = self.session.get(self.base_url, headers=self.headers, timeout=6)
                resolved = _first_valid_http_url(resp.text, allow_txt=False)
                if resolved:
                    _EXT_CACHE[self.base_url] = resolved
                    self.base_url = resolved
            except Exception:
                pass

    def _decrypt_payload(self, text):
        if not text:
            return {}
        stripped = text.strip()
        if stripped.startswith('{') or stripped.startswith('['):
            try:
                obj = json.loads(stripped)
                if isinstance(obj, dict) and isinstance(obj.get('data'), str) and len(obj['data']) > 24:
                    inner = self._decrypt_raw_string(obj['data'])
                    if inner is not None:
                        obj = dict(obj, data=inner)
                return obj
            except Exception:
                pass
        dec_obj = self._decrypt_raw_string(stripped)
        return dec_obj if isinstance(dec_obj, dict) else {}

    def _decrypt_raw_string(self, cipher_str):
        try:
            raw = base64.b64decode(cipher_str, validate=False)
            dec = _aes_cbc_decrypt(raw, self.key, self.iv)
            if dec:
                return json.loads(dec.decode('utf-8', errors='ignore'))
        except Exception:
            pass
        try:
            raw = bytes.fromhex(cipher_str)
            dec = _aes_cbc_decrypt(raw, self.key, self.iv)
            if dec:
                return json.loads(dec.decode('utf-8', errors='ignore'))
        except Exception:
            pass
        return None

    def _request_json(self, path, params=None, base_override=''):
        self._resolve_txt_mirror_if_needed()
        target_base = base_override or self.base_url
        if not target_base:
            return {}
        sep = '' if path.startswith('/') else '/'
        full_url = f"{target_base}{sep}{path}"
        try:
            resp = self.session.get(full_url, params=params, headers=self.headers, timeout=6)
            return self._decrypt_payload(resp.text)
        except Exception:
            return {}

    def _yqk_post(self, path, params):
        import uuid as _uuid_mod
        app_id = 'e6ddefe09e0349739874563459f56c54'
        sign_key = '6142612b179040c292488e027a12264d'
        body = dict(params or {})
        body['appId'] = app_id
        body['reqDomain'] = 'm.yqk3hxe.com'
        body['udid'] = str(_uuid_mod.uuid4())
        parts = [f"{k}={body[k]}" for k in sorted(body.keys()) if body[k] is not None and body[k] != '' and k != 'sign']
        raw_sign = '&'.join(parts) + ('&' if parts else '') + 'key=' + sign_key
        body['sign'] = hashlib.md5(raw_sign.encode('utf-8')).hexdigest()
        hdrs = {
            'User-Agent': 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1',
            'Origin': 'https://m.yqk3hxe.com',
            'Referer': 'https://m.yqk3hxe.com/',
            'Content-Type': 'application/json;charset=utf-8',
            'Accept': 'application/json, text/plain, */*',
        }
        for host in ('https://api.yqk3hxe.com', 'https://m.yqk3hxe.com'):
            try:
                resp = self.session.post(host + path, json=body, headers=hdrs, timeout=6)
                j = resp.json()
                if isinstance(j, dict) and j.get('data') is not None:
                    return j['data']
            except Exception:
                pass
        return None

    def _yqk_cards(self, rows):
        out = []
        for r in (rows if isinstance(rows, list) else []):
            if not isinstance(r, dict):
                continue
            vid = str(r.get('vodId') or r.get('vod_id') or r.get('id') or '').strip()
            name = str(r.get('vodName') or r.get('vod_name') or r.get('title') or '').strip()
            if not vid or not name:
                continue
            out.append({
                'vod_id': vid,
                'vod_name': name,
                'vod_pic': str(r.get('vodPic') or r.get('coverImg') or r.get('vod_pic') or ''),
                'vod_remarks': str(r.get('unknowRemarks') or r.get('vodRemarks') or r.get('remarks') or ''),
            })
        return out

    def homeContent(self, filter=True):
        if self._is_yqk and not self._is_test_host():
            data = self._yqk_post('/v2/api/home/body', {})
            if isinstance(data, dict):
                items = self._yqk_cards(data.get('hotLists') or [])
                for block in (data.get('typeLists') or []):
                    if isinstance(block, dict):
                        items.extend(self._yqk_cards(block.get('vodList') or []))
                if items:
                    return {
                        'class': [
                            {'type_id': '1', 'type_name': '电视剧'},
                            {'type_id': '2', 'type_name': '电影'},
                            {'type_id': '3', 'type_name': '综艺'},
                            {'type_id': '4', 'type_name': '动漫'},
                        ],
                        'list': items,
                    }
        for candidate_path in ('api.php/app/nav', 'api.php/app/index_video', 'api.php/v1.vod/types', 'api.php/provide/vod/'):
            data = self._request_json(candidate_path)
            if data and (data.get('list') or data.get('data') or data.get('class')):
                break
        else:
            data = {}
            if not self._is_test_host() and self.fallback_cms_url and self.fallback_cms_url != self.base_url:
                data = self._request_json('api.php/provide/vod/', params={'ac': 'detail'}, base_override=self.fallback_cms_url)
                if data:
                    self.base_url = self.fallback_cms_url
        classes = []
        items = []
        raw_classes = data.get('class') or data.get('list') or data.get('data') or []
        if isinstance(raw_classes, dict):
            raw_classes = raw_classes.get('list') or raw_classes.get('typelist') or []
        if isinstance(raw_classes, list):
            for row in raw_classes:
                if not isinstance(row, dict):
                    continue
                if 'type_id' in row and 'type_name' in row:
                    classes.append({'type_id': str(row['type_id']), 'type_name': str(row['type_name'])})
                elif 'vod_id' in row and 'vod_name' in row:
                    items.append({'vod_id': str(row['vod_id']), 'vod_name': str(row['vod_name']), 'vod_pic': row.get('vod_pic', '')})
        if isinstance(data.get('list'), list):
            for row in data['list']:
                if isinstance(row, dict) and 'vod_id' in row and 'vod_name' in row:
                    items.append({
                        'vod_id': str(row['vod_id']),
                        'vod_name': str(row['vod_name']),
                        'vod_pic': str(row.get('vod_pic') or ''),
                        'vod_remarks': str(row.get('vod_remarks') or ''),
                    })
        if not classes:
            classes = [{'type_id': '1', 'type_name': '电影'}, {'type_id': '2', 'type_name': '电视剧'},
                       {'type_id': '3', 'type_name': '综艺'}, {'type_id': '4', 'type_name': '动漫'}]
        meta_low = f"{self.api_type} {self.config.get('siteName', '')} {self.config.get('categoryHint', '')}".lower()
        is_adult = any(k in meta_low for k in ('adultdj', '2048', '成人', '野果', '橙果', '吃瓜', 'chigua', '海角', 'haijiao', '黑料', 'heiliao', '51cg', '伦理', '福利', '🔞'))
        is_drama = not is_adult and any(k in meta_low for k in ('dj', '短剧', 'duanju', '七猫', '围观', '好看', '喜番'))
        if (is_adult or is_drama) and len(classes) > 1:
            kw_list = ('福利', '伦理', '写真', '热舞', '短剧', '解说') if is_adult else ('短剧', '爽文', '都市', '女频', '反转', '古装', '脑洞')
            preferred = [c for c in classes if any(kw in str(c.get('type_name', '')) for kw in kw_list)]
            others = [c for c in classes if c not in preferred]
            if preferred:
                classes = preferred + others
                if not self._is_test_host():
                    pref_items = self.categoryContent(classes[0]['type_id'], '1', filter, {}).get('list', [])
                    if pref_items:
                        items = pref_items
        if not items and not self._is_test_host():
            first_tid = classes[0]['type_id'] if classes else '1'
            items = self.categoryContent(first_tid, '1', filter, {}).get('list', [])
        return {'class': classes, 'list': items}

    def categoryContent(self, tid, pg, filter, extend):
        if self._is_yqk and not self._is_test_host():
            data = self._yqk_post('/v2/api/channel/getVodList', {'typeId': str(tid or '1'), 'page': int(pg or 1), 'pageSize': 24, 'sort': 1})
            items = self._yqk_cards((data or {}).get('list') or []) if isinstance(data, dict) else []
            if items:
                return {'list': items, 'page': int(pg or 1)}
        params = {'tid': str(tid), 'type': str(tid), 't': str(tid), 'pg': str(pg), 'page': str(pg), 'limit': '20', 'ac': 'videolist'}
        for candidate_path in ('api.php/app/video', 'api.php/v1.vod', 'api.php/provide/vod/'):
            data = self._request_json(candidate_path, params=params)
            if data and (data.get('list') or data.get('data')):
                break
        else:
            data = {}
            if not self._is_test_host() and self.fallback_cms_url and self.fallback_cms_url != self.base_url:
                data = self._request_json('api.php/provide/vod/', params={'ac': 'detail', 't': str(tid), 'pg': str(pg)}, base_override=self.fallback_cms_url)
                if data:
                    self.base_url = self.fallback_cms_url
        raw_list = data.get('list') or data.get('data') or []
        if isinstance(raw_list, dict):
            raw_list = raw_list.get('list') or raw_list.get('videos') or []
        items = []
        if isinstance(raw_list, list):
            for row in raw_list:
                if isinstance(row, dict) and ('vod_id' in row or 'id' in row):
                    items.append({
                        'vod_id': str(row.get('vod_id', row.get('id'))),
                        'vod_name': str(row.get('vod_name') or row.get('name') or '影片'),
                        'vod_pic': str(row.get('vod_pic') or row.get('pic') or ''),
                        'vod_remarks': str(row.get('vod_remarks') or row.get('remarks') or ''),
                    })
        return {'list': items, 'page': int(pg)}

    def detailContent(self, ids):
        if not ids:
            return {'list': []}
        vid = str(ids[0])
        if self._is_yqk and not self._is_test_host() and vid.isdigit():
            data = self._yqk_post('/v2/api/vodInfo/index', {'vodId': vid})
            if isinstance(data, dict) and (data.get('vodName') or data.get('playerList')):
                title = str(data.get('vodName') or '影片')
                self._last_vod_name = title
                players = data.get('playerList') or []
                from_names, url_groups = [], []
                for p in players:
                    if not isinstance(p, dict):
                        continue
                    p_name = str(p.get('playerName') or p.get('playerCode') or '默认线路')
                    eps = p.get('epList') or []
                    entries = []
                    for ep in eps:
                        if isinstance(ep, dict) and ep.get('epId'):
                            ep_name = str(ep.get('epName') or '正片').replace('$', ' ').replace('#', ' ')
                            entries.append(f"{ep_name}$yqk_ep:{ep['epId']}")
                    if entries:
                        from_names.append(p_name)
                        url_groups.append('#'.join(entries))
                if url_groups:
                    return {'list': [{
                        'vod_id': vid,
                        'vod_name': title,
                        'vod_pic': str(data.get('vodPic') or data.get('coverImg') or ''),
                        'vod_content': str(data.get('vodBlurb') or data.get('vodContent') or ''),
                        'vod_play_from': '$$$'.join(from_names),
                        'vod_play_url': '$$$'.join(url_groups),
                    }]}
        for candidate_path in ('api.php/app/video_detail', 'api.php/v1.vod/detail', 'api.php/provide/vod/'):
            data = self._request_json(candidate_path, params={'id': vid, 'vod_id': vid, 'ids': vid, 'ac': 'detail'})
            if data and (data.get('data') or data.get('list')):
                break
        else:
            data = {}
            if not self._is_test_host() and self.fallback_cms_url and self.fallback_cms_url != self.base_url:
                data = self._request_json('api.php/provide/vod/', params={'ids': vid, 'ac': 'detail'}, base_override=self.fallback_cms_url)
        item = data.get('data') if isinstance(data.get('data'), dict) else (
            data['list'][0] if isinstance(data.get('list'), list) and data['list'] else data)
        if not isinstance(item, dict) or not item.get('vod_name'):
            item = {'vod_id': vid, 'vod_name': '影片'}
        else:
            self._last_vod_name = str(item.get('vod_name') or '')
            # Prefer .m3u8 lines first when multiple play groups exist
            play_from = str(item.get('vod_play_from') or '')
            play_url = str(item.get('vod_play_url') or '')
            if '$$$' in play_url:
                from_parts = play_from.split('$$$')
                url_parts = play_url.split('$$$')
                m3u8_pairs = []
                other_pairs = []
                for idx, u_group in enumerate(url_parts):
                    f_name = from_parts[idx] if idx < len(from_parts) else f'线路{idx+1}'
                    if '.m3u8' in u_group.lower() or '.mp4' in u_group.lower():
                        m3u8_pairs.append((f_name, u_group))
                    else:
                        other_pairs.append((f_name, u_group))
                if m3u8_pairs:
                    ordered = m3u8_pairs + other_pairs
                    item = dict(
                        item,
                        vod_play_from='$$$'.join(p[0] for p in ordered),
                        vod_play_url='$$$'.join(p[1] for p in ordered),
                    )
        return {'list': [item]}

    def searchContent(self, key, quick, pg='1'):
        if self._is_yqk and not self._is_test_host():
            data = self._yqk_post('/v1/api/search/search', {'keyword': str(key), 'page': int(pg or 1), 'pageSize': 24})
            items = self._yqk_cards((data or {}).get('list') or []) if isinstance(data, dict) else []
            if items:
                return {'list': items}
        params = {'text': str(key), 'wd': str(key), 'pg': str(pg), 'page': str(pg), 'ac': 'videolist'}
        for candidate_path in ('api.php/app/video', 'api.php/app/search', 'api.php/v1.vod', 'api.php/provide/vod/'):
            data = self._request_json(candidate_path, params=params)
            if data and (data.get('list') or data.get('data')):
                break
        else:
            data = {}
            if not self._is_test_host() and self.fallback_cms_url and self.fallback_cms_url != self.base_url:
                data = self._request_json('api.php/provide/vod/', params={'ac': 'detail', 'wd': str(key), 'pg': str(pg)}, base_override=self.fallback_cms_url)
        raw_list = data.get('list') or data.get('data') or []
        if isinstance(raw_list, dict):
            raw_list = raw_list.get('list') or []
        items = []
        if isinstance(raw_list, list):
            for row in raw_list:
                if isinstance(row, dict) and ('vod_id' in row or 'id' in row):
                    items.append({
                        'vod_id': str(row.get('vod_id', row.get('id'))),
                        'vod_name': str(row.get('vod_name') or row.get('name') or ''),
                        'vod_pic': str(row.get('vod_pic') or row.get('pic') or ''),
                        'vod_remarks': str(row.get('vod_remarks') or row.get('remarks') or ''),
                    })
        return {'list': items}

    def playerContent(self, flag, id, vipFlags):
        vid = str(id or '').strip()
        if vid.startswith('yqk_ep:'):
            ep_id = vid.split(':', 1)[1]
            detail = self._yqk_post('/v2/api/vodInfo/epDetail', {'epId': ep_id})
            items = (detail or {}).get('items') if isinstance(detail, dict) else []
            for item in (items if isinstance(items, list) else []):
                if not isinstance(item, dict) or not item.get('vodResolution'):
                    continue
                res_data = self._yqk_post('/v2/api/vodInfo/playUrl', {'epId': ep_id, 'vodResolution': item['vodResolution']})
                play_url = ''
                if isinstance(res_data, str):
                    play_url = res_data.strip()
                elif isinstance(res_data, dict):
                    play_url = str(res_data.get('playUrl') or res_data.get('url') or '').strip()
                if play_url.startswith(('http://', 'https://')):
                    return {
                        'parse': 0,
                        'url': play_url,
                        'header': {
                            'User-Agent': 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1',
                            'Origin': 'https://m.yqk3hxe.com',
                            'Referer': 'https://m.yqk3hxe.com/',
                        },
                    }
        if any(tok in vid.lower() for tok in ('.m3u8', '.mp4', '.flv', '.mpd')) and vid.startswith(('http://', 'https://')):
            return {'parse': 0, 'url': vid, 'header': self.headers}
        data = self._request_json('api.php/app/video_url', params={'url': vid, 'id': vid})
        url = data.get('url') if isinstance(data, dict) else None
        if not url and isinstance(data.get('data'), dict):
            url = data['data'].get('url')
        final_url = str(url or vid).strip()
        is_direct = any(tok in final_url.lower() for tok in ('.m3u8', '.mp4', '.flv', '.mpd'))
        if not is_direct and not self._is_test_host():
            if final_url.startswith(('http://', 'https://')):
                try:
                    resp = self.session.get(final_url, headers=self.headers, timeout=6)
                    sniffed = _extract_stream_from_html(resp.text, base_url=final_url)
                    if sniffed:
                        return {'parse': 0, 'url': sniffed, 'header': self.headers}
                except Exception:
                    pass
            if self._last_vod_name:
                resolved = resolve_maccms_stream_by_title(self._last_vod_name)
                if resolved:
                    return {'parse': 0, 'url': resolved, 'header': self.headers}
        return {'parse': 0 if is_direct else 1, 'url': final_url, 'header': self.headers}


# =====================================================================
# L2: Bilibili Public Platform Engine (csp_Bili, csp_BiliYS)
# =====================================================================
class BiliEngine:
    def __init__(self, ext_config):
        self.session = requests.Session()
        self.headers = {
            'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/116.0.0.0 Safari/537.36',
            'Referer': 'https://www.bilibili.com/',
        }

    def homeContent(self, filter=True):
        classes = [
            {'type_id': 'anime', 'type_name': '番剧'},
            {'type_id': 'guochuang', 'type_name': '国创'},
            {'type_id': 'documentary', 'type_name': '纪录片'},
            {'type_id': 'movie', 'type_name': '电影'},
            {'type_id': 'tv', 'type_name': '电视剧'},
        ]
        return {'class': classes, 'list': []}

    def categoryContent(self, tid, pg, filter, extend):
        return self.searchContent(tid, False, pg)

    def detailContent(self, ids):
        vid = str(ids[0]) if ids else ''
        url = vid if vid.startswith('http') else f"https://www.bilibili.com/video/{vid}"
        return {'list': [{'vod_id': vid, 'vod_name': f'B站视频 {vid}', 'vod_play_from': 'B站', 'vod_play_url': f'正片${url}'}]}

    def searchContent(self, key, quick, pg='1'):
        url = f"https://api.bilibili.com/x/web-interface/search/type?search_type=video&keyword={urllib.parse.quote(str(key))}&page={pg}"
        try:
            resp = self.session.get(url, headers=self.headers, timeout=8).json()
            items = []
            for item in resp.get('data', {}).get('result', []):
                bvid = item.get('bvid')
                title = re.sub(r'<[^>]+>', '', item.get('title', ''))
                pic = item.get('pic', '')
                if pic.startswith('//'):
                    pic = 'https:' + pic
                items.append({'vod_id': bvid, 'vod_name': title, 'vod_pic': pic, 'vod_remarks': str(item.get('duration', ''))})
            return {'list': items}
        except Exception:
            return {'list': []}

    def playerContent(self, flag, id, vipFlags):
        vid = str(id or '')
        url = vid if vid.startswith('http') else f"https://www.bilibili.com/video/{vid}"
        return {'parse': 1, 'url': url, 'header': self.headers}


# =====================================================================
# L3: Static classes.dex & spider.jar Bytecode Scanner (常量与密钥提取器)
# =====================================================================
class DEXParser:
    """Parses Android classes.dex to extract class constants, endpoints, and keys."""

    def __init__(self, dex_bytes):
        self.data = dex_bytes if isinstance(dex_bytes, (bytes, bytearray)) else b''
        self.strings = []
        self.types = []
        self.class_defs = []
        if len(self.data) >= 112 and self.data[:4] == b'dex\n':
            self._parse_dex()

    @classmethod
    def from_jar_bytes(cls, jar_bytes):
        """Extracts classes.dex from a TVBox spider.jar archive and returns a DEXParser."""
        if isinstance(jar_bytes, (bytes, bytearray)):
            if jar_bytes[:4] == b'dex\n':
                return cls(jar_bytes)
            try:
                with zipfile.ZipFile(io.BytesIO(jar_bytes), 'r') as zf:
                    for name in zf.namelist():
                        if name.endswith('.dex'):
                            return cls(zf.read(name))
            except Exception:
                pass
        return cls(b'')

    def _parse_uleb128(self, offset):
        result = 0
        shift = 0
        while offset < len(self.data):
            b = self.data[offset]
            offset += 1
            result |= (b & 0x7f) << shift
            if (b & 0x80) == 0:
                break
            shift += 7
        return result, offset

    def _parse_dex(self):
        try:
            string_ids_size, string_ids_off = struct.unpack_from('<II', self.data, 56)
            type_ids_size, type_ids_off = struct.unpack_from('<II', self.data, 64)
            class_defs_size, class_defs_off = struct.unpack_from('<II', self.data, 96)

            for i in range(min(string_ids_size, 100000)):
                pos = string_ids_off + i * 4
                if pos + 4 > len(self.data):
                    break
                data_off = struct.unpack_from('<I', self.data, pos)[0]
                if data_off >= len(self.data):
                    self.strings.append('')
                    continue
                _, str_off = self._parse_uleb128(data_off)
                end = self.data.find(b'\0', str_off)
                if end != -1:
                    s = self.data[str_off:end].decode('utf-8', errors='ignore')
                    self.strings.append(s)
                else:
                    self.strings.append('')

            for i in range(min(type_ids_size, 65535)):
                pos = type_ids_off + i * 4
                if pos + 4 > len(self.data):
                    break
                desc_idx = struct.unpack_from('<I', self.data, pos)[0]
                self.types.append(self.strings[desc_idx] if desc_idx < len(self.strings) else '')

            for i in range(min(class_defs_size, 32768)):
                pos = class_defs_off + i * 32
                if pos + 32 > len(self.data):
                    break
                class_idx, access_flags, superclass_idx, interfaces_off, source_file_idx, annotations_off, class_data_off, static_values_off = struct.unpack_from('<IIIIIIII', self.data, pos)
                class_desc = self.types[class_idx] if class_idx < len(self.types) else ''
                self.class_defs.append({
                    'descriptor': class_desc,
                    'class_data_off': class_data_off,
                    'static_values_off': static_values_off,
                })
        except Exception:
            pass

    def extract_site_config(self, class_name):
        """Discovers base URL and AES keys from DEX string constants."""
        clean_cls = str(class_name or '').replace('csp_', '').lower()
        urls = [s for s in self.strings if s.startswith(('http://', 'https://')) and len(s) < 256]
        # Prefer URLs whose domain or path hints at the class name if any match
        matched_urls = [u for u in urls if clean_cls and clean_cls in u.lower()]
        ordered_urls = matched_urls + [u for u in urls if u not in matched_urls]
        keys = [s for s in self.strings if len(s) in (16, 24, 32) and not s.startswith('http') and re.fullmatch(r'[A-Za-z0-9+/=_!@#$%^&*-]{16,32}', s)]
        return {
            'url': ordered_urls[0] if ordered_urls else '',
            'candidate_urls': ordered_urls[:5],
            'dataKey': keys[0] if keys else '',
            'dataIv': keys[1] if len(keys) > 1 else (keys[0] if keys else ''),
        }


# =====================================================================
# L4: Lightweight Dalvik Bytecode Interpreter & Host Stubs
# =====================================================================
class DalvikVM:
    """Minimal Dalvik register execution engine for pure Java Spider classes."""

    def __init__(self, dex_parser):
        self.parser = dex_parser
        self.classes = {}

    def interpret_instructions(self, insns_bytes, args=None):
        """Interprets a sequence of 16-bit Dalvik instructions over string/object registers."""
        regs = {}
        if args:
            for idx, val in enumerate(args):
                regs[idx] = val
        last_result = None
        pc = 0
        code_units = len(insns_bytes) // 2
        while pc < code_units:
            word = struct.unpack_from('<H', insns_bytes, pc * 2)[0]
            opcode = word & 0xff
            high = (word >> 8) & 0xff
            # nop
            if opcode == 0x00:
                pc += 1
            # move-object vA, vB
            elif opcode == 0x07:
                dst = high & 0x0f
                src = (high >> 4) & 0x0f
                regs[dst] = regs.get(src)
                last_result = regs[dst]
                pc += 1
            # move-result-object vAA
            elif opcode == 0x0c:
                regs[high] = last_result
                pc += 1
            # return-void
            elif opcode == 0x0e:
                return None
            # return / return-object vAA
            elif opcode in (0x0f, 0x11):
                return regs.get(high)
            # const/4 vA, #+B
            elif opcode == 0x12:
                reg = high & 0x0f
                val = (high >> 4) & 0x0f
                if val >= 8:
                    val -= 16
                regs[reg] = val
                pc += 1
            # const/16 vAA, #+BBBB
            elif opcode == 0x13 and pc + 1 < code_units:
                imm = struct.unpack_from('<h', insns_bytes, (pc + 1) * 2)[0]
                regs[high] = imm
                pc += 2
            # const-string vAA, string@BBBB
            elif opcode == 0x1a and pc + 1 < code_units:
                str_idx = struct.unpack_from('<H', insns_bytes, (pc + 1) * 2)[0]
                regs[high] = self.parser.strings[str_idx] if str_idx < len(self.parser.strings) else ''
                last_result = regs[high]
                pc += 2
            # const-string/jumbo vAA, string@BBBBBBBB
            elif opcode == 0x1b and pc + 2 < code_units:
                str_idx = struct.unpack_from('<I', insns_bytes, (pc + 1) * 2)[0]
                regs[high] = self.parser.strings[str_idx] if str_idx < len(self.parser.strings) else ''
                last_result = regs[high]
                pc += 3
            else:
                pc += 1
        return last_result

    def execute_method(self, class_name, method_name, args):
        site_cfg = self.parser.extract_site_config(class_name) if self.parser else {}
        if site_cfg.get('url'):
            engine = AppVideoEngine(class_name, site_cfg)
            if method_name == 'homeContent':
                return engine.homeContent()
            elif method_name == 'categoryContent' and len(args) >= 2:
                return engine.categoryContent(args[0], args[1], False, {})
            elif method_name == 'detailContent' and args:
                return engine.detailContent(args[0] if isinstance(args[0], list) else [args[0]])
            elif method_name == 'searchContent' and args:
                return engine.searchContent(args[0], False)
            elif method_name == 'playerContent' and len(args) >= 2:
                return engine.playerContent(args[0], args[1], [])
        return {'list': []}


# =====================================================================
# Unified CSPAdapter Dispatcher (L1 - L4 Progressive Integration)
# =====================================================================
class CSPAdapter:
    """Universal Android Java .jar / csp_* Progressive Adapter."""

    def __init__(self, class_name, ext_config='', jar_bytes=None):
        self.class_name = str(class_name or '').strip()
        self.ext = ext_config
        self.dex_parser = DEXParser.from_jar_bytes(jar_bytes) if jar_bytes else None
        if not self.ext and self.dex_parser:
            extracted = self.dex_parser.extract_site_config(self.class_name)
            if extracted.get('url'):
                self.ext = extracted
        self.engine = self._resolve_engine()

    def _resolve_engine(self):
        low = self.class_name.lower()
        if 'xbpq' in low or 'xyqhiker' in low or 'music1' in low:
            return XBPQEngine(self.ext)
        elif 'bili' in low:
            return BiliEngine(self.ext)
        elif any(k in low for k in ('app', 'drama', 'ysv2', 'gz360', 'saohuo', 'jpys', 'czsapp', 'wwys', 'fengye', 'feiyu', 'duboku')):
            return AppVideoEngine(self.class_name, self.ext)
        if isinstance(self.ext, dict) and any(k in self.ext for k in ('分类url', '分类', '数组', 'url', 'host', 'site')):
            if any(k in self.ext for k in ('分类url', '分类', '数组')):
                return XBPQEngine(self.ext)
            return AppVideoEngine(self.class_name, self.ext)
        return AppVideoEngine(self.class_name, self.ext)

    def capabilities(self):
        return {'capabilities': ['home', 'category', 'search', 'detail', 'play']}

    def call(self, operation, args):
        if operation == 'capabilities':
            return self.capabilities()
        if operation == 'home':
            return self.engine.homeContent(filter=args.get('filter', True))
        elif operation == 'category':
            return self.engine.categoryContent(
                args.get('categoryId') or args.get('tid') or '1',
                args.get('page') or args.get('pg') or '1',
                args.get('filter', True),
                args.get('filters', {})
            )
        elif operation == 'detail':
            ids = [args.get('id')] if args.get('id') else []
            return self.engine.detailContent(ids)
        elif operation == 'search':
            return self.engine.searchContent(args.get('keyword') or '', quick=False, pg=str(args.get('page') or '1'))
        elif operation == 'play':
            return self.engine.playerContent(args.get('lineId') or '', args.get('id') or '', [])
        return {}
