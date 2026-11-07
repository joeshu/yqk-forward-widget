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

import requests

_EXT_CACHE = {}
_JAR_CACHE = {}


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


def _aes_cbc_decrypt(ciphertext_bytes, key_bytes, iv_bytes):
    if AES is None or not ciphertext_bytes or not key_bytes:
        return b''
    key = key_bytes[:32] if len(key_bytes) >= 32 else (
        key_bytes[:24] if len(key_bytes) >= 24 else key_bytes[:16].ljust(16, b'\0'))
    if not iv_bytes:
        cipher = AES.new(key, AES.MODE_ECB)
    else:
        iv = iv_bytes[:16].ljust(16, b'\0')
        cipher = AES.new(key, AES.MODE_CBC, iv)
    decrypted = cipher.decrypt(ciphertext_bytes)
    return _unpad_pkcs7(decrypted)


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


def _first_valid_http_url(candidate):
    """Extracts the first valid http/https URL from a string, comma-separated list, or array."""
    if isinstance(candidate, list):
        for item in candidate:
            u = _first_valid_http_url(item)
            if u:
                return u
        return ''
    if not isinstance(candidate, str):
        return ''
    for part in re.split(r'[,;\s\r\n]+', candidate.strip()):
        part = part.strip().rstrip('/')
        if part.startswith(('http://', 'https://')):
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
            # Try sniffing player_aaaa or direct stream from the episode page
            html = self._get(raw_id)
            if html:
                html = html.replace("\\/", "/")
                m = re.search(r'https?://[^\s"\'<>\\]+?\.(?:m3u8|mp4)(?:[?#][^\s"\'<>\\]*)?', html, re.I)
                if m:
                    found_url = m.group(0).replace('\\/', '/')
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

        raw_base = self.config.get('url') or self.config.get('host') or self.config.get('site') or ''
        self.base_url = _first_valid_http_url(raw_base)
        self.key = (self.config.get('dataKey') or self.config.get('siteKey') or '1234567887654321').encode('utf-8')
        self.iv = (self.config.get('dataIv') or self.config.get('listKey') or self.config.get('dataKey') or '1234567887654321').encode('utf-8')
        self.session = requests.Session()
        self.headers = {
            'User-Agent': self.config.get('ua') or 'Mozilla/5.0 (Linux; Android 13; V2049A) AppleWebKit/537.36 Chrome/116.0.0.0 Mobile Safari/537.36',
            'Accept': 'application/json, text/plain, */*',
        }

    def _resolve_txt_mirror_if_needed(self):
        if self.base_url.lower().endswith('.txt'):
            cached = _EXT_CACHE.get(self.base_url)
            if cached:
                self.base_url = cached
                return
            try:
                resp = self.session.get(self.base_url, headers=self.headers, timeout=6)
                resolved = _first_valid_http_url(resp.text)
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

    def _request_json(self, path, params=None):
        self._resolve_txt_mirror_if_needed()
        if not self.base_url:
            return {}
        sep = '' if path.startswith('/') else '/'
        full_url = f"{self.base_url}{sep}{path}"
        try:
            resp = self.session.get(full_url, params=params, headers=self.headers, timeout=8)
            return self._decrypt_payload(resp.text)
        except Exception:
            return {}

    def homeContent(self, filter=True):
        for candidate_path in ('api.php/app/nav', 'api.php/app/index_video', 'api.php/v1.vod/types', 'api.php/provide/vod/'):
            data = self._request_json(candidate_path)
            if data and (data.get('list') or data.get('data') or data.get('class')):
                break
        else:
            data = {}
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
        if not classes:
            classes = [{'type_id': '1', 'type_name': '电影'}, {'type_id': '2', 'type_name': '电视剧'},
                       {'type_id': '3', 'type_name': '综艺'}, {'type_id': '4', 'type_name': '动漫'}]
        return {'class': classes, 'list': items}

    def categoryContent(self, tid, pg, filter, extend):
        params = {'tid': str(tid), 'type': str(tid), 't': str(tid), 'pg': str(pg), 'page': str(pg), 'limit': '20', 'ac': 'videolist'}
        for candidate_path in ('api.php/app/video', 'api.php/v1.vod', 'api.php/provide/vod/'):
            data = self._request_json(candidate_path, params=params)
            if data and (data.get('list') or data.get('data')):
                break
        else:
            data = {}
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
        for candidate_path in ('api.php/app/video_detail', 'api.php/v1.vod/detail', 'api.php/provide/vod/'):
            data = self._request_json(candidate_path, params={'id': vid, 'vod_id': vid, 'ids': vid, 'ac': 'detail'})
            if data and (data.get('data') or data.get('list')):
                break
        else:
            data = {}
        item = data.get('data') if isinstance(data.get('data'), dict) else (
            data['list'][0] if isinstance(data.get('list'), list) and data['list'] else data)
        if not isinstance(item, dict) or not item.get('vod_name'):
            item = {'vod_id': vid, 'vod_name': '影片'}
        return {'list': [item]}

    def searchContent(self, key, quick, pg='1'):
        params = {'text': str(key), 'wd': str(key), 'pg': str(pg), 'page': str(pg), 'ac': 'videolist'}
        for candidate_path in ('api.php/app/video', 'api.php/app/search', 'api.php/v1.vod', 'api.php/provide/vod/'):
            data = self._request_json(candidate_path, params=params)
            if data and (data.get('list') or data.get('data')):
                break
        else:
            data = {}
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
        vid = str(id or '')
        if any(tok in vid.lower() for tok in ('.m3u8', '.mp4', '.flv', '.mpd')) and vid.startswith(('http://', 'https://')):
            return {'parse': 0, 'url': vid, 'header': self.headers}
        data = self._request_json('api.php/app/video_url', params={'url': vid, 'id': vid})
        url = data.get('url') if isinstance(data, dict) else None
        if not url and isinstance(data.get('data'), dict):
            url = data['data'].get('url')
        final_url = str(url or vid)
        is_direct = any(tok in final_url.lower() for tok in ('.m3u8', '.mp4', '.flv', '.mpd'))
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
