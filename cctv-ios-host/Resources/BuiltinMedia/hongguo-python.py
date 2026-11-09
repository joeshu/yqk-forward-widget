# -*- coding: utf-8 -*-
"""HGTV 1.0.5 source adapted for CCTVHost's Python Spider and media proxy."""
import argparse
import ast
import copy
import email.utils
import http.cookiejar
import json
import math
import random
import re
import socket
import ssl
import struct
import sys
import threading
import time
from collections import OrderedDict
from concurrent.futures import ThreadPoolExecutor
from html.parser import HTMLParser
from urllib.error import HTTPError, URLError
from urllib.parse import urlsplit, parse_qs, urlencode
from urllib.request import Request, build_opener, HTTPCookieProcessor, HTTPRedirectHandler

VERSION = '1.0.5-cctvhost-r5'
ORIGIN = 'https://hongguoduanju.com'
COMPAT_PATH = '/api/video/protected/fallback-play-info'
UA_WEB = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36'

_TRACE_LOCK = threading.RLock()

def _trace(event, **fields):
    # CCTVHost retains stderr even when it replaces a source's empty result
    # with NO_MEDIA. Never include media URLs, headers, cookies or error bodies.
    allowed = ('series_id', 'episode_id', 'preview', 'status', 'failure_stage',
               'error_code', 'retryable', 'elapsed_ms', 'quality', 'width', 'height',
               'target_level_idc', 'patched_fields')
    record = {'event': event, 'source_version': VERSION}
    record.update((key, fields[key]) for key in allowed if key in fields)
    try:
        with _TRACE_LOCK:
            print('[HGTV] ' + json.dumps(record, ensure_ascii=False), file=sys.stderr, flush=True)
    except Exception:
        pass

class SourceError(Exception):
    def __init__(self, message, status=0, stage='', code='', retryable=False):
        super().__init__(message)
        self.status = status
        self.stage, self.code, self.retryable = stage, code, retryable

def _stage_error(error, stage, code):
    if isinstance(error, SourceError):
        return SourceError(str(error), error.status, error.stage or stage,
                           error.code or code, error.retryable)
    return SourceError('播放处理发生异常（%s）' % type(error).__name__, stage=stage, code=code)

def _public_error_message(error):
    message = re.sub(r'https?://[^\s]+', '[地址已隐藏]', str(error), flags=re.I)[:300]
    return re.sub(r'(?i)\b(?:cookie|authorization|(?:access_)?token|signature|password)\s*[:=][^\r\n]*',
                  '[凭据已隐藏]', message)

class _Flight:
    def __init__(self):
        self.event = threading.Event()
        self.value = None
        self.error = None

class BoundedCache:
    def __init__(self, max_items=32, max_bytes=16 * 1024 * 1024, clock=time.monotonic):
        self.max_items, self.max_bytes, self.clock = max_items, max_bytes, clock
        self.entries, self.flights = OrderedDict(), {}
        self.bytes = 0
        self.lock = threading.RLock()
        self.hits = self.misses = self.shared = 0

    def _purge(self):
        now = self.clock()
        for key, (_, expiry, weight) in list(self.entries.items()):
            if expiry <= now:
                self.entries.pop(key)
                self.bytes -= weight

    def load(self, key, loader, ttl=300, wait_timeout=25):
        with self.lock:
            self._purge()
            if key in self.entries:
                self.hits += 1
                value, expiry, weight = self.entries[key]
                self.entries.move_to_end(key)
                return value
            flight = self.flights.get(key)
            owner = flight is None
            if owner:
                flight = self.flights[key] = _Flight()
                self.misses += 1
            else:
                self.shared += 1
        if not owner:
            if not flight.event.wait(wait_timeout):
                raise SourceError('等待相同请求超时，请重试')
            if flight.error:
                raise _stage_error(flight.error, 'shared_request', 'shared_request_failed')
            return flight.value
        try:
            value = loader()
            weight = getattr(value, 'weight', None)
            if weight is None:
                weight = len(json.dumps(value, ensure_ascii=False).encode('utf-8'))
            ttl = ttl(value) if callable(ttl) else ttl
            flight.value = value
            with self.lock:
                self._purge()
                if weight <= self.max_bytes and ttl > 0:
                    previous = self.entries.pop(key, None)
                    if previous:
                        self.bytes -= previous[2]
                    self.entries[key] = (value, self.clock() + ttl, weight)
                    self.bytes += weight
                    while len(self.entries) > self.max_items or self.bytes > self.max_bytes:
                        _, (_, _, removed) = self.entries.popitem(last=False)
                        self.bytes -= removed
            return value
        except Exception as error:
            flight.error = error
            raise
        finally:
            with self.lock:
                self.flights.pop(key, None)
            flight.event.set()

class _Page:
    def __init__(self, html, router, weight):
        self.html, self.router, self.weight = html, router, weight

class _CheckedRedirect(HTTPRedirectHandler):
    def __init__(self, check):
        self.check = check
    def redirect_request(self, request, fp, code, message, headers, newurl):
        if getattr(request, '_bounded_probe', False):
            # urllib otherwise drains the redirect body outside our read limit.
            if fp is not None: fp.close()
            raise SourceError('视频分段检查不接受重定向，请重新获取播放地址')
        method = request.get_method()
        if code in (301, 302, 303) and method == 'POST':
            method = 'GET'
        self.check(newurl, method)
        return super().redirect_request(request, fp, code, message, headers, newurl)

class PublicHTTP:
    def __init__(self, cache=None, timeout=6, retry_budget=18, attempts=2):
        self.cache = cache or BoundedCache()
        self.timeout, self.retry_budget, self.attempts = timeout, retry_budget, attempts
        self.local = threading.local()
        self.count_lock = threading.Lock()
        self.request_count = 0

    def _opener(self):
        if not hasattr(self.local, 'opener'):
            # Thread-local opener/cookie jar: ordinary cookies persist without
            # sharing mutable session state between simultaneous catalogue calls.
            self.local.opener = build_opener(_CheckedRedirect(self._check), HTTPCookieProcessor(http.cookiejar.CookieJar()))
        return self.local.opener

    @staticmethod
    def permitted(url, method):
        u = urlsplit(url)
        # 本地解密服务（签名兜底时返回的 127.0.0.1 流）——只放行 GET /play/<数字>
        if (u.scheme == 'http' and u.hostname in ('127.0.0.1', 'localhost')
                and u.port == _DEC_PORT and not u.username and not u.password):
            return method == 'GET' and bool(re.fullmatch(r'/play/[0-9]{1,24}', u.path))
        if u.scheme != 'https' or u.username or u.password or u.port:
            return False
        if u.netloc == 'hongguoduanju.com':
            if method == 'POST':
                return u.path == COMPAT_PATH and not u.query
            return method == 'GET' and (u.path in ('/', '/detail') or bool(re.fullmatch(r'/category/[a-z0-9/-]{1,180}|/player/[0-9/]{1,60}|/video/public/[0-9]{1,24}/360p\.mp4', u.path)))
        return method == 'GET' and bool(re.fullmatch(r'v[0-9]+-(?:reading|hgweb)\.qznovelvod\.com', u.netloc, re.I))

    def _once(self, url, method, headers, payload, limit, require_range, deadline):
        self._check(url, method)
        request = Request(url, data=payload, headers=headers, method=method)
        request._bounded_probe = require_range
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise SourceError('请求预算已用完', code='request_timeout', retryable=True)
        with self.count_lock:
            self.request_count += 1
        with self._opener().open(request, timeout=min(self.timeout, remaining)) as response:
            self._check(response.geturl(), method)
            status = response.getcode()
            response_headers = {key.lower(): value for key, value in response.headers.items()}
            # Abort before reading if the server ignored Range. This prevents a
            # nominal header probe from downloading the complete media file.
            if require_range and status != 206:
                raise SourceError('服务器没有提供分段读取', status)
            size = response_headers.get('content-length')
            if size and size.isdigit() and int(size) > limit:
                raise SourceError('响应超过大小限制')
            chunks, total = [], 0
            reader = getattr(response, 'read1', None) or response.read
            while True:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise SourceError('响应读取超时', code='request_timeout', retryable=True)
                transport_socket = getattr(getattr(getattr(response, 'fp', None), 'raw', None), '_sock', None)
                if transport_socket is not None:
                    transport_socket.settimeout(min(self.timeout, remaining))
                read_limit = limit - total if require_range else limit + 1 - total
                block = reader(min(65536, read_limit))
                if not block:
                    break
                total += len(block)
                if total > limit:
                    raise SourceError('响应超过大小限制')
                chunks.append(block)
                if require_range and total == limit:
                    break
            return status, response_headers, b''.join(chunks)

    def _check(self, url, method):
        try:
            valid = self.permitted(url, method)
        except (ValueError, TypeError, AttributeError):
            valid = False
        if not valid:
            raise SourceError('不支持的公开资源地址')

    def request(self, url, method='GET', headers=None, payload=None, limit=3500000, require_range=False, deadline=None):
        self._check(url, method)
        fields = {'User-Agent': UA_WEB, 'Accept-Language': 'zh-CN,zh;q=0.9', 'Accept': '*/*', 'Accept-Encoding': 'identity'}
        fields.update(headers or {})
        # A probe shares one deadline and byte budget across all its ranges.
        # Retrying a partially read range would spend that byte budget twice.
        attempts = 1 if require_range and deadline is not None else self.attempts
        deadline = min(deadline, time.monotonic() + self.retry_budget) if deadline is not None else time.monotonic() + self.retry_budget
        last = None
        for attempt in range(attempts):
            wait = 0.2 * (2 ** attempt) + random.random() * 0.05
            try:
                return self._once(url, method, fields, payload, limit, require_range, deadline)
            except HTTPError as error:
                status = error.code
                retry_after = error.headers.get('Retry-After', '')
                error.close()
                transient = status in (408, 425, 429) or status >= 500
                last = SourceError('站点返回 HTTP %d' % status, status, code='http_error', retryable=transient)
                if status not in (408, 425, 429) and status < 500:
                    raise last
                if retry_after:
                    try:
                        wait = max(0, float(retry_after))
                    except ValueError:
                        try:
                            wait = max(0, email.utils.parsedate_to_datetime(retry_after).timestamp() - time.time())
                        except Exception:
                            raise last
                    if wait > 2:
                        raise last
            except (ssl.SSLError, SourceError):
                raise
            except (URLError, socket.timeout, OSError) as error:
                if isinstance(getattr(error, 'reason', None), ssl.SSLError):
                    raise SourceError('TLS 证书校验失败', code='tls_error')
                last = SourceError('网络连接失败，请稍后重试', code='network_error', retryable=True)
            if attempt + 1 >= attempts or time.monotonic() + wait >= deadline:
                break
            time.sleep(wait)
        raise last or SourceError('请求失败')

    def _page(self, path):
        if not isinstance(path, str) or not path.startswith('/') or path.startswith('//'):
            raise SourceError('页面路径无效')
        def fetch_page():
            _, _, raw = self.request(ORIGIN + path, headers={'Accept': 'text/html,application/xhtml+xml'})
            try:
                html = raw.decode('utf-8')
            except UnicodeDecodeError:
                raise SourceError('页面不是有效 UTF-8')
            router = parse_router_data(html)
            validate_page(router, path)
            return _Page(html, router, len(raw) + len(json.dumps(router, ensure_ascii=False).encode('utf-8')))
        return self.cache.load(('page', path), fetch_page, 30 if path.startswith('/player/') else 300)

    def page(self, path):
        return self._page(path).html

    def router(self, path):
        return self._page(path).router

    def compat(self, sid, vid):
        referer = ORIGIN + ('/player/%s/%s' % (sid, vid) if sid else '/')
        try:
            _, _, raw = self.request(ORIGIN + COMPAT_PATH, method='POST', headers={'Content-Type': 'application/json', 'Accept': 'application/json', 'Origin': ORIGIN, 'Referer': referer}, payload=json.dumps({'item_id': vid}).encode(), limit=256000)
        except SourceError as error:
            if error.status == 403:
                raise SourceError('官网兼容接口拒绝本集请求（HTTP 403），未返回可播放地址', 403,
                                  'resolve_api', 'provider_http_forbidden', False)
            if error.status == 404:
                raise SourceError('官网兼容接口未找到本次请求的资源（HTTP 404），未返回可播放地址', 404,
                                  'resolve_api', 'provider_http_not_found', False)
            raise _stage_error(error, 'resolve_api', 'provider_request_failed')
        try:
            data = json.loads(raw.decode('utf-8'))
        except (ValueError, UnicodeDecodeError):
            raise SourceError('播放接口返回无效 JSON')
        if not isinstance(data, dict) or not isinstance(data.get('base_resp'), dict) or str(data['base_resp'].get('StatusCode')) != '0':
            raise SourceError('播放接口结构变化或返回失败')
        url = data.get('main_url')
        self._check(url or '', 'GET')
        if urlsplit(url).hostname == 'hongguoduanju.com' or data.get('format') == 'dash' or data.get('encrypted') or data.get('audio'):
            raise SourceError('没有返回系统播放器可用的兼容媒体')
        expiry = data.get('url_expire')
        try:
            expiry = float(expiry)
            if not math.isfinite(expiry): expiry = None
            elif expiry > 1e12: expiry /= 1000
        except (ValueError, TypeError):
            expiry = None
        if expiry is not None and expiry <= time.time() + 3:
            raise SourceError('播放地址已过期或临近过期，请重试')
        return url, referer, expiry

    def _probe_range(self, url, headers, start, end, deadline, expected_total=None):
        if time.monotonic() >= deadline:
            raise SourceError('视频初始化检查超时', code='probe_timeout', retryable=True)
        fields = {key: value for key, value in (headers or {}).items() if key.lower() != 'range'}
        fields['Range'] = 'bytes=%d-%d' % (start, end)
        status, response_headers, body = self.request(url, headers=fields, limit=end - start + 1, require_range=True, deadline=deadline)
        match = re.fullmatch(r'bytes ([0-9]{1,20})-([0-9]{1,20})/([0-9]{1,20})', response_headers.get('content-range', ''), re.I)
        if status != 206 or not match:
            raise SourceError('无效的分段响应')
        actual_start, actual_end, total = (int(value) for value in match.groups())
        if not (actual_start == start <= actual_end < total and actual_end == min(end, total - 1) and len(body) == actual_end - start + 1):
            raise SourceError('分段正文长度或范围不匹配')
        if expected_total is not None and total != expected_total:
            raise SourceError('视频在分段检查期间发生变化')
        content_type = response_headers.get('content-type', '').lower()
        encoding = response_headers.get('content-encoding', '').lower()
        if 'text/' in content_type or 'json' in content_type or 'xml' in content_type or encoding not in ('', 'identity'):
            raise SourceError('返回的是网页或压缩响应，而非原始视频字节')
        if time.monotonic() >= deadline:
            raise SourceError('视频初始化检查超时', code='probe_timeout', retryable=True)
        return body, total

    def probe(self, url, headers=None):
        deadline, byte_limit = time.monotonic() + 20, 1024 * 1024
        prefix, total = self._probe_range(url, headers, 0, 65535, deadline)
        windows, transferred, requests = [(0, prefix)], len(prefix), 1

        def read_at(start, length, read_ahead=False):
            nonlocal transferred, requests
            if start + length > total:
                raise SourceError('MP4 初始化信息不完整，无法确认视频轨')
            pieces, at = [], start
            while at < start + length:
                if time.monotonic() >= deadline:
                    raise SourceError('视频初始化检查超时', code='probe_timeout', retryable=True)
                window = next(((offset, data) for offset, data in windows if offset <= at < offset + len(data)), None)
                if window:
                    offset, data = window
                    count = min(start + length - at, offset + len(data) - at)
                    pieces.append(data[at - offset:at - offset + count])
                    at += count
                    continue
                needed = start + length - at
                count = min(max(needed, 65536) if read_ahead else needed, total - at, byte_limit - transferred)
                if requests >= 4 or count < needed:
                    raise SourceError('MP4 初始化信息不完整：已达到元数据检查预算')
                data, _ = self._probe_range(url, headers, at, at + count - 1, deadline, total)
                windows.append((at, data))
                transferred += len(data)
                requests += 1
            return b''.join(pieces)

        # Follow top-level box sizes; never search media payload for box names.
        at, ftyp, moov = 0, None, None
        for _ in range(512):
            if at >= total:
                break
            head = read_at(at, 8, True)
            size, kind = struct.unpack('>I4s', head)
            header_size = 8
            if size == 1:
                size = struct.unpack_from('>Q', read_at(at, 16), 8)[0]
                header_size = 16
            elif size == 0:
                size = total - at
            if size < header_size or at + size > total:
                raise SourceError('MP4 初始化信息不完整：文件结构或长度无效')
            if kind in (b'ftyp', b'moov'):
                if size > byte_limit:
                    raise SourceError('MP4 初始化信息不完整：元数据超过检查预算')
                box = read_at(at, size)
                # A zero-sized terminal box was read to the known file end.
                if head[:4] == b'\0\0\0\0':
                    box = struct.pack('>I', size) + box[4:]
                if kind == b'ftyp': ftyp = box
                else: moov = box
            at += size
            if ftyp is not None and moov is not None:
                break
        if ftyp is None:
            raise SourceError('媒体不是有效的 MP4 文件')
        if moov is None:
            raise SourceError('MP4 初始化信息不完整：没有取得完整 moov')
        # Only complete metadata boxes are joined, never disjoint media bytes.
        info = inspect_mp4(ftyp + moov)
        if not info['mp4'] or not info['initialization_complete']:
            raise SourceError('MP4 初始化信息不完整，无法确认视频轨')
        if info['encrypted']:
            raise SourceError('媒体包含加密样本，无法直接播放')
        if not info['has_video']:
            raise SourceError('MP4 没有具有非零画面尺寸的视频轨，可能仅含音频')
        if time.monotonic() >= deadline:
            raise SourceError('视频初始化检查超时', code='probe_timeout', retryable=True)
        return info


def inspect_mp4(data):
    if not isinstance(data, bytes) or len(data) > 1024 * 1024:
        raise SourceError('无效的媒体探针大小')
    result = {'mp4': False, 'encrypted': False, 'duration': None, 'tracks': [],
              'initialization_complete': False, 'has_video': None,
              'codecs': [], 'dimensions': [], 'encryption_known': False}
    result['video_codecs'], result['video_dimensions'] = result['codecs'], result['dimensions']
    budget = [2048]

    def boxes(start, end):
        nodes, at = [], start
        while at < end:
            budget[0] -= 1
            if budget[0] < 0 or at + 8 > end:
                raise ValueError('incomplete box or metadata budget exhausted')
            size, kind = struct.unpack_from('>I4s', data, at)
            header = 8
            if size == 1:
                if at + 16 > end: raise ValueError('incomplete extended box')
                size, header = struct.unpack_from('>Q', data, at + 8)[0], 16
            if size < header or at + size > end:
                raise ValueError('invalid or incomplete child box')
            nodes.append((kind, at + header, at + size))
            at += size
        return nodes

    def one(nodes, kind, required=True):
        found = [node for node in nodes if node[0] == kind]
        if len(found) > 1 or (required and not found):
            raise ValueError('missing or duplicate initialization box')
        return found[0] if found else None

    def movie_header(node):
        _, start, end = node
        if start + 4 > end: raise ValueError('incomplete movie header')
        version = data[start]
        if version == 0 and start + 20 <= end:
            scale, duration = struct.unpack_from('>II', data, start + 12)
        elif version == 1 and start + 32 <= end:
            scale = struct.unpack_from('>I', data, start + 20)[0]
            duration = struct.unpack_from('>Q', data, start + 24)[0]
        else:
            raise ValueError('unsupported or incomplete movie header')
        if not scale: raise ValueError('invalid movie timescale')
        return duration / scale

    def track(node):
        _, start, end = node
        mdia = one(boxes(start, end), b'mdia')
        children = boxes(mdia[1], mdia[2])
        hdlr = one(children, b'hdlr')
        if hdlr[1] + 24 > hdlr[2]: raise ValueError('incomplete media handler')
        handler = data[hdlr[1] + 8:hdlr[1] + 12]
        minf = one(children, b'minf', handler in (b'vide', b'soun'))
        if minf is None: return [], [], [], False
        stbl = one(boxes(minf[1], minf[2]), b'stbl', handler in (b'vide', b'soun'))
        if stbl is None: return [], [], [], False
        stsd = one(boxes(stbl[1], stbl[2]), b'stsd', handler in (b'vide', b'soun'))
        if stsd is None: return [], [], [], False
        start, end = stsd[1:]
        if start + 8 > end or data[start] != 0:
            raise ValueError('incomplete or unsupported sample description')
        count = struct.unpack_from('>I', data, start + 4)[0]
        entries = boxes(start + 8, end)
        if len(entries) != count: raise ValueError('sample description count mismatch')
        tracks, codecs, dimensions, encrypted = [], [], [], False
        for kind, payload, stop in entries:
            if payload + 8 > stop: raise ValueError('incomplete sample entry')
            codec = kind.decode('ascii', 'replace')
            tracks.append(codec)
            encrypted |= kind in (b'encv', b'enca')
            if handler == b'vide':
                if kind not in (b'avc1', b'avc2', b'avc3', b'avc4', b'hvc1', b'hev1', b'av01', b'vp08', b'vp09', b'mp4v', b's263', b'jpeg', b'encv'):
                    raise ValueError('unsupported visual sample entry')
                if payload + 78 > stop: raise ValueError('incomplete visual sample entry')
                width, height = struct.unpack_from('>HH', data, payload + 24)
                codecs.append(codec)
                if width and height:
                    dimensions.append({'width': width, 'height': height})
        return tracks, codecs, dimensions, encrypted

    at, moov_seen = 0, False
    while at + 8 <= len(data):
        size, kind = struct.unpack_from('>I4s', data, at)
        header = 8
        if size == 1:
            if at + 16 > len(data): break
            size, header = struct.unpack_from('>Q', data, at + 8)[0], 16
        # A bare prefix cannot establish the end of a zero-sized box.
        if size < header or at + size > len(data): break
        if kind == b'ftyp' and size >= header + 8:
            result['mp4'] = True
        elif kind == b'moov':
            if moov_seen:
                result['initialization_complete'] = result['encryption_known'] = False
                result['has_video'] = None
                break
            moov_seen = True
            try:
                nodes = boxes(at + header, at + size)
                duration = movie_header(one(nodes, b'mvhd'))
                tracks, codecs, dimensions, encrypted = [], [], [], False
                for node in nodes:
                    if node[0] != b'trak': continue
                    descriptions, video_codecs, sizes, protected = track(node)
                    tracks.extend(descriptions)
                    codecs.extend(video_codecs)
                    dimensions.extend(sizes)
                    encrypted |= protected
                result.update(duration=duration, tracks=tracks, codecs=codecs, dimensions=dimensions,
                              video_codecs=codecs, video_dimensions=dimensions, encrypted=encrypted,
                              initialization_complete=True, encryption_known=True, has_video=bool(dimensions))
            except (ValueError, struct.error):
                result['has_video'] = None
        at += size
    return result


def validate_page(router, path):
    data = router['loaderData']
    u = urlsplit(path)
    if path == '/':
        payload = data.get('page')
        valid = isinstance(payload, dict) and any(isinstance(payload.get(key), list) for key in ('mBannerList', 'bannerList', 'banner_list', 'homeSections', 'home_sections', 'sections'))
    elif u.path.startswith('/category/'):
        payload = data.get('category_$') or data.get('category_page')
        valid = isinstance(payload, dict) and any(isinstance(payload.get(key), list) for key in ('recommendList', 'video_list', 'videoList', 'list'))
    elif u.path == '/detail':
        payload = data.get('detail_page') or data.get('detail_$')
        item = (payload.get('seriesDetail') or payload.get('series_detail')) if isinstance(payload, dict) else None
        expected = parse_qs(u.query).get('series_id', [''])[0]
        valid = isinstance(item, dict) and str(item.get('series_id') or item.get('seriesId')) == expected and bool(item.get('vid_list') or item.get('video_list') or item.get('videoList') or item.get('episodes'))
    else:
        payload = next((value for key, value in data.items() if 'player' in key and isinstance(value, dict) and 'publicVideoSeo' in value), None)
        valid = isinstance(payload, dict)
    if not valid or payload.get('isSuccess') is False:
        raise SourceError('页面结构变化或站点暂未返回有效数据')


# Bounded SSR parsing. Playback sources below are unresolved directory entries;
# the presence of an episode ID alone says nothing about media availability.
MAX_HTML_BYTES = 3_500_000
MAX_ROUTER_BYTES = 2_500_000
MAX_JSON_DEPTH = 128
MAX_PAGES = 10_000
_ID_RE = re.compile(r"[0-9]{1,24}\Z")
_SLUG_RE = re.compile(r"[a-z0-9-]{1,80}\Z", re.ASCII)
_ASSIGN_RE = re.compile(r"(?:(?:window|globalThis)\s*\.\s*)?_ROUTER_DATA\s*=")
_CATEGORIES = (
    ("real-drama", "真人短剧"),
    ("comic-drama", "漫剧"),
    ("ai-drama", "AI 短剧"),
    ("comic", "漫画"),
)


class CatalogError(ValueError):
    """The requested path, SSR data, or public catalogue shape is invalid."""


class _Scripts(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=False)
        self.scripts = []
        self._parts = None

    def handle_starttag(self, tag, attrs):
        if tag == "script":
            self._parts = []

    def handle_data(self, data):
        if self._parts is not None:
            self._parts.append(data)

    def handle_endtag(self, tag):
        if tag == "script" and self._parts is not None:
            self.scripts.append("".join(self._parts))
            self._parts = None


def _assignment_start(script):
    """Find a real assignment token, ignoring JS strings and comments."""
    index, length = 0, len(script)
    while index < length:
        char = script[index]
        if char in "\"'`":
            quote = char
            index += 1
            while index < length:
                if script[index] == "\\":
                    index += 2
                elif script[index] == quote:
                    index += 1
                    break
                else:
                    index += 1
            continue
        if script.startswith("//", index):
            newline = script.find("\n", index + 2)
            index = length if newline < 0 else newline + 1
            continue
        if script.startswith("/*", index):
            end = script.find("*/", index + 2)
            index = length if end < 0 else end + 2
            continue
        previous = script[index - 1] if index else ""
        if char in "wg_" and not (previous and (previous.isalnum() or previous in "_.$")):
            match = _ASSIGN_RE.match(script, index)
            if match:
                start = match.end()
                while start < length and script[start].isspace():
                    start += 1
                if start >= length or script[start] != "{":
                    raise CatalogError("_ROUTER_DATA must be a literal JSON object")
                return start
        index += 1
    return None


def _json_object(script, start):
    stack, in_string, escaped = [], False, False
    for index in range(start, min(len(script), start + MAX_ROUTER_BYTES + 1)):
        if index - start >= MAX_ROUTER_BYTES:
            raise CatalogError("router JSON exceeds its size limit")
        char = script[index]
        if in_string:
            if escaped:
                escaped = False
            elif char == "\\":
                escaped = True
            elif char == '"':
                in_string = False
            continue
        if char == '"':
            in_string = True
        elif char in "{[":
            stack.append(char)
            if len(stack) > MAX_JSON_DEPTH:
                raise CatalogError("router JSON exceeds its nesting limit")
        elif char in "}]":
            expected = "{" if char == "}" else "["
            if not stack or stack.pop() != expected:
                raise CatalogError("router JSON has mismatched brackets")
            if not stack:
                value = script[start:index + 1]
                if len(value.encode("utf-8")) > MAX_ROUTER_BYTES:
                    raise CatalogError("router JSON exceeds its size limit")
                tail = script[index + 1:].lstrip()
                if tail and not tail.startswith((";", "//", "/*")):
                    raise CatalogError("router assignment is not plain JSON")
                return value
    raise CatalogError("router JSON is incomplete")


def _reject_constant(value):
    raise CatalogError("non-finite JSON number: " + value)


def _bounded_int(value):
    if len(value.lstrip("-")) > 64:
        raise CatalogError("JSON integer exceeds its digit limit")
    return int(value)


def _finite_float(value):
    if len(value) > 128:
        raise CatalogError("JSON number exceeds its digit limit")
    number = float(value)
    if not math.isfinite(number):
        raise CatalogError("JSON number exceeds finite range")
    return number


def _unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise CatalogError("duplicate JSON object key")
        result[key] = value
    return result


def parse_router_data(html):
    """Extract a size/depth-bounded literal _ROUTER_DATA object without eval."""
    if isinstance(html, bytes):
        if len(html) > MAX_HTML_BYTES:
            raise CatalogError("HTML exceeds its size limit")
        try:
            html = html.decode("utf-8")
        except UnicodeDecodeError as error:
            raise CatalogError("HTML is not UTF-8") from error
    if not isinstance(html, str) or len(html) > MAX_HTML_BYTES:
        raise CatalogError("HTML must be bounded text")
    try:
        if len(html.encode("utf-8")) > MAX_HTML_BYTES:
            raise CatalogError("HTML exceeds its size limit")
        parser = _Scripts()
        parser.feed(html)
        parser.close()
        for script in parser.scripts:
            start = _assignment_start(script)
            if start is None:
                continue
            router = json.loads(_json_object(script, start),
                                parse_constant=_reject_constant,
                                parse_int=_bounded_int,
                                parse_float=_finite_float,
                                object_pairs_hook=_unique_object)
            if not isinstance(router, dict) or not isinstance(router.get("loaderData"), dict):
                raise CatalogError("router data has no loaderData object")
            return router
    except CatalogError:
        raise
    except (UnicodeError, RecursionError, ValueError) as error:
        raise CatalogError("invalid router JSON") from error
    raise CatalogError("HTML contains no literal _ROUTER_DATA assignment")


def _array(data, *keys):
    for key in keys:
        if isinstance(data.get(key), list):
            return data[key]
    return []


def _identifier(value):
    if isinstance(value, bool) or not isinstance(value, (str, int)):
        return ""
    text = str(value)
    return text if _ID_RE.fullmatch(text) else ""


def _text(value, limit=500):
    return value.strip()[:limit] if isinstance(value, str) else ""


def _natural(value, maximum=1_000_000):
    text = _identifier(value)
    if not text:
        return None
    number = int(text)
    return number if number <= maximum else None


def _first(data, *keys):
    for key in keys:
        if data.get(key) is not None:
            return data[key]
    return None


def _image(value):
    if not isinstance(value, str) or len(value) > 4096 or any(ord(char) < 33 for char in value):
        return ""
    try:
        url = urlsplit(value)
        if url.scheme == "https" and url.hostname and not url.username and not url.password:
            _ = url.port
            return value
    except ValueError:
        pass
    return ""


def _movie(row):
    if not isinstance(row, dict):
        return None
    series_id = _identifier(_first(row, "series_id", "seriesId", "id"))
    title = _text(_first(row, "series_name", "seriesName", "series_title", "title"))
    if not series_id or not title:
        return None
    return {"id": series_id, "title": title,
            "cover": _image(_first(row, "series_cover", "cover", "image", "cover_url")),
            "count": _natural(_first(row, "episode_cnt", "episodeCount", "episode_count"))}


def _movies(rows):
    unique = OrderedDict()
    for row in rows:
        item = _movie(row)
        if item is not None:
            unique[item["id"]] = item
    return list(unique.values())


def _page_number(value):
    number = _natural(value, MAX_PAGES)
    if number is None or number < 1:
        raise CatalogError("page must be an integer from 1 to %d" % MAX_PAGES)
    return number


class Catalog:
    """Public SSR directory plus a bounded, explicitly local search index."""

    def __init__(self, http, max_catalog=2000, search_page_size=24):
        if not callable(getattr(http, "page", None)):
            raise TypeError("http.page(path) is required")
        self.http = http
        self.max_catalog = _natural(max_catalog, 100_000)
        self.search_page_size = _natural(search_page_size, 1000)
        if not self.max_catalog or not self.search_page_size:
            raise ValueError("catalog and page sizes must be positive bounded integers")
        self._catalog = OrderedDict()
        self._paths = OrderedDict()
        self._evictions = 0
        self._paths_trimmed = False
        self._lock = threading.RLock()

    def _route(self, path, kind):
        loader = (self.http.router(path) if callable(getattr(self.http, "router", None)) else parse_router_data(self.http.page(path)))["loaderData"]
        keys = {"home": ("page",), "category": ("category_$", "category_page"),
                "detail": ("detail_page", "detail_$")}[kind]
        for key in keys:
            data = loader.get(key)
            if isinstance(data, dict):
                if data.get("isSuccess") is False:
                    raise CatalogError("site returned an unsuccessful %s page" % kind)
                return data
        raise CatalogError("site %s loader structure has changed" % kind)

    def _remember(self, path, items):
        with self._lock:
            self._paths[path] = None
            self._paths.move_to_end(path)
            while len(self._paths) > 64:
                self._paths.popitem(last=False)
                self._paths_trimmed = True
            for item in items:
                self._catalog[item["id"]] = dict(item)
                self._catalog.move_to_end(item["id"])
                while len(self._catalog) > self.max_catalog:
                    self._catalog.popitem(last=False)
                    self._evictions += 1

    def categories(self):
        return [{"id": slug, "title": title} for slug, title in _CATEGORIES]

    def home(self):
        data = self._route("/", "home")
        if not any(isinstance(data.get(key), list) for key in
                   ("mBannerList", "bannerList", "banner_list", "homeSections", "home_sections", "sections")):
            raise CatalogError("site home catalogue structure has changed")
        sections = []
        banners = _movies(_array(data, "mBannerList", "bannerList", "banner_list"))
        if banners:
            sections.append({"title": "红果精选短剧", "items": banners})
        for section in _array(data, "homeSections", "home_sections", "sections"):
            if not isinstance(section, dict):
                continue
            items = _movies(_array(section, "video_list", "videoList", "list"))
            if items:
                sections.append({"title": _text(_first(section, "tab_name", "tabName", "title")) or "红果短剧",
                                 "items": items})
        unique = OrderedDict((item["id"], item) for section in sections for item in section["items"])
        items = list(unique.values())
        self._remember("/", items)
        return {"items": items, "sections": sections}

    def category(self, slug, page=1, topic=None):
        page = _page_number(page)
        if not isinstance(slug, str):
            raise CatalogError("category must be a known slug")
        parts = slug.split("/")
        if len(parts) > 2 or parts[0] not in dict(_CATEGORIES):
            raise CatalogError("unknown category")
        if len(parts) == 2:
            if topic is not None:
                raise CatalogError("topic was supplied twice")
            topic = parts[1]
        if topic is not None and (not isinstance(topic, str) or not _SLUG_RE.fullmatch(topic)):
            raise CatalogError("invalid category topic")
        category_slug = parts[0] + (("/" + topic) if topic else "")
        path = "/category/" + category_slug + "?" + urlencode({"page": page})
        try:
            data = self._route(path, "category")
        except Exception:
            if parts[0] == "comic" and topic is None:
                path = "/category/comic-drama?" + urlencode({"page": page})
                data = self._route(path, "category")
            else:
                raise
        if not any(isinstance(data.get(key), list) for key in ("recommendList", "video_list", "videoList", "list")):
            raise CatalogError("site category catalogue structure has changed")
        items = _movies(_array(data, "recommendList", "video_list", "videoList", "list"))
        if parts[0] == "comic" and topic is None and (not items or self.http is _SHARED_HTTP):
            try:
                cd_path = "/category/comic-drama?" + urlencode({"page": page})
                cd_data = self._route(cd_path, "category")
                cd_items = _movies(_array(cd_data, "recommendList", "video_list", "videoList", "list"))
                if cd_items:
                    merged = OrderedDict((it["id"], it) for it in cd_items)
                    for it in items:
                        merged.setdefault(it["id"], it)
                    items = list(merged.values())
                    if not data.get("pagination") and cd_data.get("pagination"):
                        data = cd_data
            except Exception:
                pass
        pagination = data.get("pagination") or data.get("page_info") or {}
        pagination = pagination if isinstance(pagination, dict) else {}
        total = _natural(_first(pagination, "total", "totalCount", "total_count"), 100_000_000)
        pages = _natural(_first(pagination, "totalPages", "total_pages", "pageCount", "page_count"), MAX_PAGES)
        page_size = _natural(_first(pagination, "pageSize", "page_size")) or _natural(data.get("pageSize"))
        if not pages and total is not None and page_size:
            pages = min(MAX_PAGES, max(1, math.ceil(total / page_size)))
        selectors = []
        for index, row in enumerate(_array(data, "selectorList", "selector_list", "selectors"), 1):
            if not isinstance(row, dict):
                continue
            options = OrderedDict()
            for option in _array(row, "items", "list"):
                if not isinstance(option, dict):
                    continue
                option_id = _first(option, "selector_item_id", "selectorItemId", "id")
                option_id = str(option_id) if isinstance(option_id, int) and not isinstance(option_id, bool) else option_id
                title = _text(_first(option, "show_name", "showName", "name", "title"))
                if isinstance(option_id, str) and _SLUG_RE.fullmatch(option_id) and title:
                    options[option_id] = {"id": option_id, "title": title,
                                          "path": parts[0] + "/" + option_id}
            if options:
                selectors.append({"id": _text(_first(row, "selector_id", "selectorId", "id")) or str(index),
                                  "title": _text(_first(row, "show_name", "showName", "name", "title")) or "题材",
                                  "items": list(options.values())})
        self._remember(path, items)
        return {"items": items, "page": page, "pagecount": pages or page,
                "total": total, "pagination_known": bool(pages), "selectors": selectors}

    def detail(self, series_id):
        series_id = _identifier(series_id)
        if not series_id:
            raise CatalogError("invalid series ID")
        path = "/detail?" + urlencode({"series_id": series_id})
        data = self._route(path, "detail")
        series = data.get("seriesDetail") or data.get("series_detail")
        if not isinstance(series, dict):
            raise CatalogError("site detail catalogue structure has changed")
        movie = _movie(series)
        if movie is None or movie["id"] != series_id:
            raise CatalogError("detail series ID or title does not match the request")
        episodes, seen, invalid, duplicates = [], set(), 0, 0
        for item in _array(series, "vid_list", "video_list", "videoList", "episodes"):
            raw_id = _first(item, "vid", "video_id", "videoId", "item_id", "id") if isinstance(item, dict) else item
            video_id = _identifier(raw_id)
            if not video_id:
                invalid += 1
                continue
            if video_id in seen:
                duplicates += 1
                continue
            seen.add(video_id)
            number = len(episodes) + 1
            title = _text(_first(item, "title", "name")) if isinstance(item, dict) else ""
            episodes.append({"id": video_id, "title": title or "第%d集" % number, "number": number})
        if not episodes:
            raise CatalogError("detail contains no valid episode IDs")
        expected = movie["count"]
        complete = None if expected is None else expected == len(episodes) and not invalid and not duplicates
        sources = {kind: [{**episode, "preview": preview, "availability": "unresolved"}
                          for episode in episodes]
                   for kind, preview in (("full", False), ("preview", True))}
        self._remember(path, [movie])
        return {**movie, "episodes": episodes, "episode_count": len(episodes),
                "catalog_complete": complete, "invalid_episode_entries": invalid,
                "duplicate_episode_entries": duplicates, "sources": sources,
                "source_names": {"full": "官网完整播放", "preview": "官网公开试看"},
                "playback_verified": False,
                "description": _text(_first(series, "series_intro", "seriesIntro", "description"), 20_000)}

    def search(self, keyword, page=1):
        """Search retained titles only. This method never performs HTTP requests."""
        page = _page_number(page)
        query = _text(keyword, 200).casefold()
        with self._lock:
            matches = [dict(item) for item in self._catalog.values()
                       if query and query in item["title"].casefold()]
            scope = {"catalog_size": len(self._catalog), "max_catalog_items": self.max_catalog,
                     "eviction_events": self._evictions, "recent_paths": list(self._paths),
                     "recent_paths_limited": self._paths_trimmed}
        total = len(matches)
        offset = (page - 1) * self.search_page_size
        return {"items": matches[offset:offset + self.search_page_size], "page": page,
                "pagecount": max(1, math.ceil(total / self.search_page_size)), "total": total,
                "scope": "local_catalog",
                "scope_description": "仅搜索本次实例已抓取并保留的目录标题，非全站搜索；未命中不表示全站无结果。",
                **scope}


_SHARED_HTTP = PublicHTTP()

def _label(value):
    return re.sub(r'[$#\r\n]+', ' ', str(value or ''))[:160].strip()

def _card(item):
    return {'vod_id': item['id'], 'vod_name': item['title'], 'vod_pic': item['cover'], 'vod_remarks': ('全%d集' % item['count']) if item.get('count') else ''}



########## 签名取流 + CENC 解密 ##########
########## 签名取流 + CENC 解密 ##########
# 通过进程内匿名设备注册（service/2/device_register，ttEncrypt 加密体）
# 获取 device_id + iid，再用 multi_video_model/v1 + x-medusa 签名获取 5 档 video_model，
# 由 spade 解密 CDN 地址、派生 CENC 密钥并在本地完成 AES-CTR 解密交付。
# 设备身份仅在进程内有效，不跨重启复用；空响应时换备用域名重试一次。
import base64 as _b64
import binascii as _binascii
import gzip as _gzip
import hashlib as _hashlib
import json as _json
import os as _os
import random as _random
import re as _re
import shutil as _shutil
import subprocess as _subprocess
import threading as _threading
import time as _time
import urllib.request as _ureq
import uuid as _uuid
from http.server import BaseHTTPRequestHandler as _BHTTPH, ThreadingHTTPServer as _THS
from urllib.parse import quote as _quote

_DEVICE_REGISTER_API = ("https://log5-applog-lf.fqnovel.com/service/2/device_register/"
                        "?tt_data=a&cronet_version=8d40f833_2026-03-03"
                        "&ttnet_version=4.2.243.31-douyin&use_store_region_cookie=1")
_VIDEO_MODEL_HOST = "api5-normal-sinfonlineb.fqnovel.com"
_VIDEO_MODEL_ALT_HOST = "api5-normal-hl.fqnovel.com"
_VIDEO_MODEL_PATH = "/novel/player/multi_video_model/v1/"
_PLAYBACK_UA = ("com.phoenix.read/71532 (Linux; U; Android 9; SM-N9860; "
                "Build/PQ3A.190705.10241111;tt-ok/3.12.13.20)")
_REGISTER_UA = ("com.phoenix.read/72232 (Linux; U; Android 16; zh_CN; 25053RT47C; "
                "Build/BP2A.250605.031.A3)")
# 播放请求 query 用的设备画像（与参考 JS 的 DEVICE 一致：7.1.3.32 / 71332）。
_PLAYBACK_DEVICE = {
    "ac": "wifi", "channel": "update_64", "aid": "8662", "app_name": "novelread",
    "version_code": "71332", "version_name": "7.1.3.32", "device_platform": "android",
    "os": "android", "ssmix": "a", "device_type": "25053RT47C", "device_brand": "Redmi",
    "language": "zh", "os_api": "36", "os_version": "16",
    "manifest_version_code": "71332", "resolution": "1280*2772", "dpi": "520",
    "update_version_code": "71332", "host_abi": "arm64-v8a", "dragon_device_type": "phone",
    "pv_player": "71332", "compliance_status": "0", "need_personal_recommend": "1",
    "player_so_load": "1", "is_android_pad_screen": "0",
}
_SPADE_CONST = _binascii.unhexlify(
    "4dd4c2e6b83162090e52b3c7a6733ba41cb2462b829ab58a196b39db57177524"
    "f49baf7f08e8d68d26a72e37c1a95a2f1f05a51892aef2949732b62a38aadd58"
)
_SIGN_CACHE = {}
_SIGN_CACHE_TTL = 300
_DEVICE_SESSION = None
_DEVICE_LOCK = _threading.RLock()
_PROCESS_NONCE = _b64.urlsafe_b64encode(_os.urandom(18)).rstrip(b"=").decode("ascii")
_PROCESS_STARTED = int(_time.time() * 1000)
_DEC_DIR = _os.path.join(_os.path.dirname(_os.path.abspath(__file__)), "decrypt_cache")
_DEC_SRV = None
_DEC_PORT = int(_os.environ.get("HGTV_DEC_PORT", "8789"))
_QORDER = ["1080p", "720p", "540p", "480p", "360p"]


def _u32(value):
    return int(value) & 0xFFFFFFFF


def _rol32(value, count):
    n = int(count) & 31
    x = _u32(value)
    if n == 0:
        return x
    return ((x << n) | (x >> (32 - n))) & 0xFFFFFFFF


def _ror32(value, count):
    n = int(count) & 31
    x = _u32(value)
    if n == 0:
        return x
    return ((x >> n) | (x << (32 - n))) & 0xFFFFFFFF


def _md5_bytes(b):
    if isinstance(b, str):
        b = b.encode()
    return _hashlib.md5(b).digest()


def _be32(v):
    return (int(v) & 0xFFFFFFFF).to_bytes(4, "big")


def _le32(v):
    return (int(v) & 0xFFFFFFFF).to_bytes(4, "little")


def _revbits(v):
    r = 0
    for i in range(8):
        r = ((r << 1) | ((v >> i) & 1)) & 0xFF
    return r


def _rc4_gorgon(data, key):
    # 与参考 JS 的 rc4Gorgon 逐行一致：KSA 只做 s[i] = s[j]（不换回），
    # PRGA 同样不交换，只用 s[(y + y) & 255] 输出。不要换成标准 RC4。
    s = list(range(256))
    j = 0
    for i in range(256):
        j = (j + s[i] + key[i % len(key)]) & 0xFF
        s[i] = s[j]
    out = bytearray()
    i = j = 0
    for v in data:
        i += 1
        x = s[i]
        j += x
        y = s[j & 0xFF]
        s[i] = y
        out.append(v ^ s[(y + y) & 0xFF])
    return bytes(out)


def _x_gorgon(query, body, ts, rnd):
    sdk = (67503104).to_bytes(4, "little")
    payload = _md5_bytes(query)[:4] + (_md5_bytes(body)[:4] if body else b"\0" * 4) \
        + b"\0" * 4 + sdk + _be32(ts)
    key = [0x4A, 0x40, 0x16, (rnd >> 8) & 0xFF, 0x47, 0x6C, 0x01, rnd & 0xFF]
    out = bytearray(_rc4_gorgon(payload, key))
    n = len(out)
    for i in range(n):
        v = ((out[i] >> 4) | (out[i] << 4)) & 0xFF
        nxt = out[i + 1] if i + 1 < n else out[0]
        out[i] = (~(_revbits((nxt ^ v) & 0xFF) ^ 20)) & 0xFF
    return (bytes([0x84, 0x04, rnd & 0xFF, (rnd >> 8) & 0xFF, 0x40, 0x01]) + bytes(out)).hex()


_M64 = (1 << 64) - 1


def _ror64(x, n):
    x &= _M64
    return ((x >> n) | (x << (64 - n))) & _M64


def _helios(ts):
    rnd = int(_random.random() * 0x100000000)
    digest = _md5_bytes(_le32(rnd) + b"8662")
    ascii_hex = digest.hex().encode("ascii")
    words = [int.from_bytes(ascii_hex[i:i + 8], "little") for i in (0, 8, 16, 24)]
    table = [words[0]]
    b0, b8 = words[0], words[1]
    words = words[2:]
    for i in range(34):
        x8 = (_ror64(b8, 8) + b0) & _M64
        x8 ^= i
        words.append(x8)
        x8 = (x8 ^ _ror64(b0, 61)) & _M64
        table.append(x8)
        b0, b8 = x8, words.pop(0)
    text = ("%d-1588093228-8662" % ts).encode()
    total = ((len(text) + 1 + 15) // 16) * 16
    pad = bytearray([16 - (len(text) % 16)] * total)
    pad[:len(text)] = text
    out = bytearray(_le32(rnd))
    for at in range(0, total, 16):
        a = int.from_bytes(pad[at:at + 8], "little")
        b = int.from_bytes(pad[at + 8:at + 16], "little")
        for i in range(34):
            b = (table[i] ^ ((a + _ror64(b, 8)) & _M64)) & _M64
            a = (b ^ _ror64(a, 61)) & _M64
        out += a.to_bytes(8, "little") + b.to_bytes(8, "little")
    return _b64.b64encode(bytes(out)).decode()


def _get_iv(iv, data):
    v = iv & 0xFFFFFFFF
    for i, b in enumerate(data):
        if (i & 1) == 0:
            v = ((v >> 4) ^ v ^ ((v << 6) & 0xFFFFFFFF) ^ b) & 0xFFFFFFFF
        else:
            v = (~(((v >> 7) ^ v ^ (b | ((v << 12) & 0xFFFFFFFF))) & 0xFFFFFFFF)) & 0xFFFFFFFF
    return v


def _sum_md5(data):
    check = 0x20220420
    for i in range(12):
        if (i & 1) == 0:
            temp = ((check >> 3) ^ check) & 0xFFFFFFFF
            check = (data[i] ^ ((check << 7) & 0xFFFFFFFF)) & 0xFFFFFFFF
        else:
            temp = ((check >> 5) ^ check) & 0xFFFFFFFF
            check = (data[i] | ((check << 11) & 0xFFFFFFFF)) & 0xFFFFFFFF
            check = (~check) & 0xFFFFFFFF
        check = (check ^ temp) & 0xFFFFFFFF
    return ((check | 4) ^ 0x1000000) & 0xFFFFFFFF


def _sm3(b):
    if isinstance(b, str):
        b = b.encode()
    h = _hashlib.new("sm3")
    h.update(b)
    return h.digest()


def _branch_of(url, body, ts):
    q_part = url.split("?", 1)[1] if "?" in url else ""
    q = _sm3(q_part.encode())
    bm = _md5_bytes(body) if body else b"\0" * 16
    iv = _get_iv(_get_iv(_get_iv(0x20230928, q), bm), _le32(ts))
    low = iv & 15
    return low - ((low * 171) >> 9) * 3


def _pct(s):
    # 与参考 JS 的 pythonUrlEncode 一致：encodeURIComponent，之后再把 ! ' ( )
    # 编成 %XX；* 保持不编码；非 ASCII 按 UTF-8 字节编码。
    encoded = _quote(str(s), safe="-_.!~*'()")
    return "".join(("%%%02X" % ord(ch)) if ch in "!\'()" else ch for ch in encoded)


def _varint(value):
    n = int(value)
    out = bytearray()
    while n > 127:
        out.append((n & 127) | 128)
        n >>= 7
    out.append(n)
    return bytes(out)


def _zigzag(value):
    n = int(value)
    return (-n) * 2 - 1 if n < 0 else n * 2


def _proto_field(tag, value, typ="string"):
    if value is None or value == "":
        return b""
    if typ in ("bytes", "string", "message"):
        if typ == "bytes":
            body = bytes(value)
        elif typ == "message":
            body = bytes(value)
        else:
            body = str(value).encode("utf-8")
        return _varint((int(tag) << 3) | 2) + _varint(len(body)) + body
    if typ == "float":
        return _varint((int(tag) << 3) | 5) + struct.pack("<f", float(value))
    return _varint(int(tag) << 3) + _varint(_zigzag(value) if typ == "sint" else value)


def _proto(fields):
    out = []
    for field in fields:
        tag, value = field[0], field[1]
        typ = field[2] if len(field) > 2 else "string"
        out.append(_proto_field(tag, value, typ))
    return b"".join(out)


_BRANCH2_SV = [0xa7aefe20, 0x7149f1d6, 0x47e4ca07, 0xe9b58f67, 0x93b924de, 0xc614d0f5, 0x38afe0ef, 0xb2bbad73, 0xe24444c3, 0x9d3aec9b, 0xdf7b37e4, 0xd8b16d40, 0xf8ac31b8, 0x76b9a90b, 0x31d833ee, 0x953fce64, 0x353595a4, 0x4609c13b, 0x36925008, 0x8c6d0925, 0x5df5c177, 0x1cfbf52b, 0x8a4fa7f0, 0x114ca35e, 0x8193f984, 0x7a7a8733, 0x316ab4d5, 0x3c20cfc9, 0xa6d84453, 0x3a18500c, 0x798ec47a, 0x97a76b28, 0x66c4ff96, 0x51716443, 0xdd2fc3b, 0xb5696da7, 0xbbeb3ac5, 0x5c53d204, 0xd32608ce, 0x7279b9ec, 0xf4188ecf, 0xf7d793db, 0x332cc491, 0xab76ae15, 0x9bebe727, 0x18a01384, 0x5be9f8a7, 0x5f90a754, 0x39b663c0, 0x36673c83, 0x7c92f514, 0x9d7d94d7, 0xe2e8d9aa, 0x5f7e9ea9, 0x7abd4551, 0x569e05da, 0x40a25632, 0x3df5a9a5, 0xbab37d80, 0x454286dc, 0x3f5d4e78, 0x3d7b75d, 0xb1fe4af7, 0xa5ab26a3]
_BRANCH2_ORDERS = bytes.fromhex("0f0704000908030a060b050d0e010c020f05080c0009020103070e060b0a0d04060500070c000a04080f010b0d09020e060b02050403080101070a000d0c090e0d070e0f0b0208030c0509010004060a0d0902060f0b0a040807000c0503010e0c090f07060f030e020d0405010b0a000c050a090e0802040407030f01060b000b0f0408020a0700090d06010e03050c0b060a0508020c03070f0e090d0001040906080f050800040a0b030d01020c0e090d0c0604070a03030f00080105020e01000d0f090a0b0e0402080703060c0501080a0c0f0905060b000304020e070d04080f000c0f0e0d0a01060207090503040205080d0b0a0606000e0f070c09030a08040f000b01060d0c0709030e05020a070b050f00020e0108030d0c0609040d070f08050f06040b0a0e0c090002030d0c020704010b0e0e08060f09050003")


def _md5_v3_step(kind, a, b, c, d, m, shift, constant):
    if kind == 0:
        f = (b & c) | ((~b) & d)
    elif kind == 1:
        f = (b & d) | (c & (~d))
    elif kind == 2:
        f = b ^ c ^ d
    else:
        f = c ^ (b | (~d))
    f &= 0xFFFFFFFF
    return (b + _rol32((a + f + m + constant) & 0xFFFFFFFF, shift)) & 0xFFFFFFFF


def _md5_sum_v3(message, count_v2, orders, count_v1):
    sv = [_ror32(v, count_v1) for v in _BRANCH2_SV]
    start = [_ror32(0x79e0f2fb, count_v2), _ror32(0xc8b52570, count_v2),
             _ror32(0xebc2f8cd, count_v2), _ror32(0x7c104d93, count_v2)]
    end_count = (count_v2 + 6) & 0xFF
    end = [_ror32(0x19be4866, end_count), _ror32(0xe85986b4, end_count),
           _ror32(0xe19b326e, end_count), _ror32(0x71d1d7d4, end_count)]
    m = [int.from_bytes(message[i * 4:(i + 1) * 4], "little") for i in range(16)]
    a, b, c, d = start

    def run(kind, shifts, offset):
        nonlocal a, b, c, d
        for i in range(16):
            phase = i & 3
            if phase == 0:
                a = _md5_v3_step(kind, a, b, c, d, m[orders[offset + i]], shifts[i], sv[offset + i])
            elif phase == 1:
                d = _md5_v3_step(kind, d, a, b, c, m[orders[offset + i]], shifts[i], sv[offset + i])
            elif phase == 2:
                c = _md5_v3_step(kind, c, d, a, b, m[orders[offset + i]], shifts[i], sv[offset + i])
            else:
                b = _md5_v3_step(kind, b, c, d, a, m[orders[offset + i]], shifts[i], sv[offset + i])

    run(0, [7, 12, 17, 22] * 4, 0)
    run(1, [5, 9, 14, 20] * 4, 16)
    run(2, [4, 11, 16, 23] * 4, 32)
    run(3, [6, 10, 15, 21] * 4, 48)
    ret = b"".join((((start[i] + value) & 0xFFFFFFFF) ^ end[i]).to_bytes(4, "little")
                    for i, value in enumerate([a, b, c, d]))
    return ret + _le32(_sum_md5(ret))


def _branch2_f13(iv, query_sm3, body_md5, ts_bytes, khronos):
    v = (iv & 13) * 86
    iv_v0 = ((v >> 15) & 0xFF) + ((v >> 8) & 0xFF)
    n1 = [0x8980f29b, 0xeb549c7f, 0xb08726db, 0xd40cb5e6, 0xe8f559e4][iv_v0]
    count_v1 = (n1 + khronos + 1) & 0xFF
    count_v2 = (n1 + khronos) & 0xFFFFFFFF
    shift = (count_v2 + 5) & 7
    seed = [0x84, 0x96, 0x77, 0x9d, 0xd4, 0x15, 0x0b, 0xf8]
    pad = bytes(((value | (value << 8)) >> shift) & 0xFF for value in seed)
    data = query_sm3 + body_md5 + ts_bytes + pad + bytes.fromhex("a0010000")
    return _md5_sum_v3(data, count_v2, _BRANCH2_ORDERS[iv_v0 * 64:(iv_v0 + 1) * 64], count_v1)


def _hash_f13(query_sm3, body_md5, ts_bytes, khronos):
    iv = _get_iv(_get_iv(_get_iv(0x20230928, query_sm3), body_md5), ts_bytes)
    low = iv & 15
    iv_v0 = (low * 171) >> 9
    branch = low - iv_v0 * 3
    if branch == 2:
        return _branch2_f13(iv, query_sm3, body_md5, ts_bytes, khronos)
    if branch != 0:
        return query_sm3[:16] + body_md5 + _le32(_sum_md5(query_sm3 + body_md5))
    iv_v1 = [0xc4a78580, 0xb3c0fd39, 0xc58c5686, 0xc9aa3ba7, 0xf5a7adf2, 0x963c2ed1][iv_v0]
    count_v1 = (iv_v1 + khronos + 1) & 0xFF
    count_v2 = (iv_v1 + khronos) & 0xFFFFFFFF
    tt02 = [0xebb64faf, 0x7aadcc2, 0xcf3187bf, 0xe01138ff, 0x6d0bfcff, 0x5a30a3be, 0xb41ad638, 0x34180eb8, 0xf233eb6f, 0xb1a584cc, 0xccc30dc7, 0x47d1db51, 0xd55653de, 0x70a84fa1, 0x57473c12, 0xf76f0288, 0x2c077f0a, 0xda0dcad0, 0xfbb86f6c, 0xfdc4cf00, 0x688a020d, 0xe676c6a6, 0x8cd6338b, 0x1a3c8d0e, 0xcce8b06b, 0x6ad0ed0b, 0xa0522717, 0xdc71ac83, 0x2285db71, 0xd5b4dda6, 0x736f8650, 0x6560306c, 0x617ce2a6, 0xe423417e, 0xa40e143, 0x544e4032, 0x88dffb2a, 0x716c1ae0, 0x4c467a88, 0x5b23bb3, 0xe1d0b866, 0xbaa3dcb8, 0xae3374d3, 0xc3381a50, 0x1702f75b, 0xfe6da368, 0xf0b4cf48, 0x4e0ffbb8, 0x72aad10d, 0x26c53a3d, 0xf2bce0f6, 0xb4557581, 0x4a257fdd, 0x8c3182a2, 0xab0b3b86, 0x3d5dfb14, 0x4f103634, 0xd37b52d7, 0x444eff16, 0xeb0a33d1, 0x6ca86f6e, 0x284ba7, 0x8387cfa, 0x5fb37586]
    tt = [_ror32(value, count_v1) for value in tt02]
    n0 = (count_v2 + 2) & 7
    seed = [0xFA, 0x45, 0x61, 0xD7]
    pad = bytes(((value | (value << 8)) >> n0) & 0xFF for value in seed)
    data = query_sm3 + body_md5 + ts_bytes + pad + bytes.fromhex("00000000000001a0")
    di = [int.from_bytes(data[i:i + 4], "big") for i in range(0, len(data), 4)]
    di0 = di[0]
    for i in range(112):
        di1 = di[i + 1]
        di14 = di[i + 14]
        r1 = _rol32(di1, 14) ^ _rol32(di1, 25) ^ (di1 >> 3)
        r2 = _rol32(di14, 13) ^ _rol32(di14, 15) ^ (di14 >> 10)
        di.append((di0 + di[i + 9] + r1 + r2) & 0xFFFFFFFF)
        di0 = di1
    init = [_ror32(value, count_v2 & 31) for value in
            [0x7aba4fc8, 0x67166507, 0x6403fa00, 0x340f512f,
             984304912, 3005047866, 2874125293, 2152413264]]
    chosen = [[101,5,7,6,3,2,1,0,5,4,3],[96,0,6,7,5,3,2,1,5,4,4],[96,7,6,2,1,4,0,5,4,3,5],[99,3,6,2,4,5,1,0,0,7,6],[96,0,5,6,7,3,1,2,5,4,4],[100,2,0,3,5,4,6,7,2,1,5]][iv_v0]
    d = list(init)
    for i in range(chosen[0]):
        base = iv_v1 + i
        n0v = di[base & 127]
        n1 = ((d[chosen[3]] ^ d[chosen[4]]) & d[chosen[1]]) ^ d[chosen[3]]
        n2 = _rol32(d[chosen[1]], 26) ^ _rol32(d[chosen[1]], 21) ^ _rol32(d[chosen[1]], 7)
        n4 = (n0v + n1 + n2 + tt[base & 63] + d[chosen[5]]) & 0xFFFFFFFF
        n5 = _rol32(d[chosen[2]], 30) ^ _rol32(d[chosen[2]], 19) ^ _rol32(d[chosen[2]], 10)
        n6 = (d[chosen[2]] & d[chosen[6]]) | ((d[chosen[2]] | d[chosen[6]]) & d[chosen[7]])
        n7 = (n5 + n6) & 0xFFFFFFFF
        old = d[chosen[9]]
        d.insert(0, d.pop())
        d[chosen[10]] = (n7 + n4) & 0xFFFFFFFF
        d[chosen[8]] = (old + n4) & 0xFFFFFFFF
    ret = bytearray(32)
    for i in range(8):
        ret[i * 4:(i + 1) * 4] = ((d[i] + init[i]) & 0xFFFFFFFF).to_bytes(4, "big")
    folded = bytes(a ^ b for a, b in zip(ret[:16], ret[16:]))
    ret[:16] = folded
    return bytes(ret[:16]) + _le32(_sum_md5(bytes(ret[:16])))


_SBOX = _b64.b64decode("+n0Ia5xZs0sEXznQOEqRmQBnpiCf9U2Ccybu3xhmgzOAAxn72f6uqqmwUsYL83klTni0NqxdGieeiNu9PGPsSRXBMB/cuFbUbM3KCUPINaPvHvSW0vwOcnuUhNHqRVpiAj/TEoE0K91+5ijypUYTATsh9mE3KSoN7Yyvv51cuyR2D3XkU4nhmI2xmmVwT1RMWKtub4sjxAcRDLrPoKSO2AU9FLLadMPX577Wf95IFj6FkKFVt3dCIsmGUC4X+WQxLJvxbRxEaOPpqJOXyzJX6+Vxaq3AzMfF/WAdoi1Hp+JRaV56zgpBtpWP97mH4DoGEIq1+FvV8LyS/3wvwugbQOwb2r26mJEMsiuDQTRn+wrYdrVGBVlhI3WQhyrjUBVMrLF5667llUcEaPCGPVGLD8qO5LlO8hKCvA7V9+8oJc9bXelqVQLhM76T5/WtnT45JKji+hdX0HoNCDDWuKON/QeaxB5uImSX0h2wv0VmP2zd2yeApxHcpsVS+MC2yFwAc2B7oBkTqsk1SEvTpM2fmfMQREBUfin0Bh+iq6EvPPavhWI2IX9e3yAas7Tm/3KEj2UmlFp36kN4x0rMLBRrxuh0U/zUHM4xcAMYjJY4MonxOl/X+alpt2M3WMI7w3HLnpIBigtNiJu7T21v4P6lSd5WFgntnMEt7oF92XzRLkJbTcGmXepE/UVOG6E/0YnhfS+q26utWcuxzpooyeD2cDlK1/8w9d28VzsRjbLuALbmGlp8+d7EzS6Au7lMpZ+ECMZvQmzwJ+eLOpxR+2chdUExp8ogQyq3v9l68rX4jCwjg0+PYKAEEzcU4wHFY2ZcdIHfWL1okD3SszT0GZMyKdZJrg1L2AeerB4tC0C4crp2EHGo5FYdSP7lwkeR2ocmnR+Ia8CYviUJlzOjhRZef9xuVOn3qcjow3fQgivsAmKKkg4+sA8F8/GWeDiGNhg8JM8KtFPMYWWkx5TVFX5t73kiNRJqjlIGVXtGZFCV4gzt0xcDopuZ6xz8r9Rzafpf9ywev8jh8592gHFIqpStZPuJxmDDMrNN0uBE3V+oscdoIzTJbRJ/t+sVvqnReJOgDJKk10fjisJwqyZBmnmn2BSFj8BvVtCMEbkuPOKdzw7eA11GPs04Qw8zWtkaZWwiO/wwpojqN6K0jY5RnNZA7vn4hPSul+nKCkVnVwQvg1zVxcSCtqORmB9KrJaBbssbCQivGJVJfVTt+hYxOtq4ZvWl8f4QAQZ0zGPffCgl9s6yT4vlvIdpu4YhBwA25wtQWZsc6GJYGWHyvSdeuh3mmUI9DSq13Fsp8C1MU3tqc04/df9LoTUXVXI5INOw/e8C7Hd+5CvbkMEFnnrUUmskEw==")


def _xor_bytes(a, b):
    return bytes(x ^ b[i % len(b)] for i, x in enumerate(a))


def _matrix(value):
    return [[value[i * 4 + j] for j in range(4)] for i in range(4)]


def _flat(rows):
    return bytes(v for row in rows for v in row)


def _aes_mix(rows):
    for i in range(4):
        t = rows[0][i] ^ rows[1][i] ^ rows[2][i] ^ rows[3][i]
        u = rows[0][i]

        def xt(x):
            return ((x << 1) ^ (0x1B if (x & 128) else 0)) & 0xFF

        rows[0][i] ^= t ^ xt(rows[0][i] ^ rows[1][i])
        rows[1][i] ^= t ^ xt(rows[1][i] ^ rows[2][i])
        rows[2][i] ^= t ^ xt(rows[2][i] ^ rows[3][i])
        rows[3][i] ^= t ^ xt(rows[3][i] ^ u)


class _AesV3:
    # 自定义 AES 变体，与参考 JS 的 AesV3 逐行一致（SBOX 分段、key 扩展、
    # sub/shift/shiftCon/aesMix 的轮次顺序都不要“修正”为标准 AES）。
    def __init__(self, key, khronos):
        self.word_size = khronos & 3
        self.box = _SBOX[self.word_size * 256:(self.word_size + 1) * 256]
        self.con = [[1, 0, 2, 3], [1, 3, 0, 2], [0, 1, 3, 2], [1, 0, 2, 3]][self.word_size]
        self.con2 = [[1, 0, 2, 3], [2, 0, 3, 1], [0, 1, 3, 2], [1, 0, 2, 3]][self.word_size]
        self.order = [[0, 9, 14, 11, 4, 13, 2, 7, 8, 1, 6, 15, 12, 5, 10, 3],
                      [0, 9, 14, 15, 4, 13, 2, 7, 8, 1, 6, 3, 12, 5, 10, 11],
                      [0, 9, 14, 7, 4, 13, 2, 11, 8, 1, 6, 3, 12, 5, 10, 15],
                      [0, 9, 14, 11, 4, 13, 2, 7, 8, 1, 6, 15, 12, 5, 10, 3]][self.word_size]
        init = [0xca025ddc, 0x823dc546, 0xc9420583, 0xc298225f][self.word_size]
        initial = b"".join(init.to_bytes(4, "little") for _ in range(4))
        mk = _xor_bytes(initial, key)
        expanded = bytearray(mk + b"\0" * 32)
        rounds = 8
        for i in range(4, 12):
            at = 4 * (i - 1)
            a, b, c, d = expanded[at], expanded[at + 1], expanded[at + 2], expanded[at + 3]
            if (i & 3) == 0:
                init_signed = init - (1 << 32) if init >= (1 << 31) else init
                t = (((init_signed >> (rounds & 24)) & 0xFFFFFFFF) ^ self.box[b]) & 0xFF
                b, c, d, a = self.box[c], self.box[d], self.box[a], t
            rounds += 2
            expanded[at + 4] = a ^ expanded[at - 12]
            expanded[at + 5] = b ^ expanded[at - 11]
            expanded[at + 6] = c ^ expanded[at - 10]
            expanded[at + 7] = d ^ expanded[at - 9]
        self.keys = [list(expanded[i * 4:(i + 1) * 4]) for i in range(12)]

    def _add(self, rows, key):
        for i in range(4):
            for j in range(4):
                rows[i][j] ^= key[i][j]

    def _add_con(self, rows, keys):
        for i in range(4):
            for j in range(4):
                rows[i][j] ^= keys[i][self.con2[j]]

    def _sub(self, rows):
        for i in range(4):
            for j in range(4):
                rows[i][j] = self.box[rows[i][j]]
        old = [row[:] for row in rows]
        for i in range(4):
            rows[i] = old[self.con2[i]][:]

    def _shift(self, rows):
        b = _flat(rows)
        for i in range(16):
            rows[i // 4][i % 4] = b[self.order[i]]

    def _shift_con(self, rows):
        old = [row[:] for row in rows]
        for i in range(4):
            rows[i] = [old[i][x] for x in self.con2]

    def _block(self, value):
        rows = _matrix(value)
        self._add_con(rows, self.keys[0:4])
        for i in (1, 2):
            self._sub(rows)
            self._shift(rows)
            if i == 1:
                self._shift_con(rows)
                _aes_mix(rows)
            self._add_con(rows, self.keys[i * 4:])
        self._add(rows, self.keys[4:])
        return _flat(rows)

    def encrypt(self, data, iv):
        source = bytes(data)
        plaintext = bytearray(32)
        for i in range(31):
            at = i * 8
            n0 = (source[at] >> 4) & 2
            n1 = n0 | (source[at + 1] & 64)
            n2 = n1 | ((source[at + 2] >> 2) & 1)
            n3 = n2 | ((source[at + 3] << 3) & 128)
            n4 = n3 | ((source[at + 4] >> 1) & 4)
            n5 = n4 | ((source[at + 5] << 3) & 16)
            n6 = n5 | ((source[at + 6] << 5) & 32)
            plaintext[i] = n6 | ((source[at + 7] >> 4) & 8)
        plaintext[31] = 1
        blocks = []
        previous = bytes(iv)
        for i in range(0, len(plaintext), 16):
            value = self._block(_xor_bytes(bytes(plaintext[i:i + 16]), previous))
            blocks.append(value)
            previous = value
        key = b"".join(blocks)
        out = bytearray(source)
        for i in range(31):
            at = i * 8
            k = key[i]
            out[at] &= 0xDF
            out[at] |= (k << 4) & 32
            out[at + 1] &= 0xBF
            out[at + 1] |= k & 64
            out[at + 2] &= 0xFB
            out[at + 2] |= (k << 2) & 4
            out[at + 3] &= 0xEF
            out[at + 3] |= (k >> 3) & 16
            out[at + 4] &= 0xF7
            out[at + 4] |= (k + k) & 8
            out[at + 5] &= 0xFD
            out[at + 5] |= (k >> 3) & 2
            out[at + 6] &= 0xFE
            out[at + 6] |= (k >> 5) & 1
            out[at + 7] &= 0x7F
            out[at + 7] |= (k << 4) & 128
        return key[-1:] + bytes(out)


def _xmxor(data, key):
    encoded = bytearray(len(data))
    for i in range(len(data)):
        at = (i * 4) & 28
        d0, d1 = key[at], key[at + 1]
        d2 = ((((data[i] << 4) | (data[i] >> 4)) & 0xFF) + d0)
        d2 = (~d2) ^ d1
        d2 = ((((d2 & 0xFF) << 3) | ((d2 & 0xFF) >> 5)) & 0xFF)
        d2 = (d2 + d1) & 0xFF
        d2 = (d2 ^ d0) & 0xFF
        encoded[len(data) - i - 1] = (~d2) & 0xFF
    last = encoded[-1] ^ encoded[-2]
    first = encoded[0]
    encoded[0] = (~last + first) & 0xFF
    encoded[1] = ((encoded[0] ^ encoded[-1] ^ 254) + encoded[1]) & 0xFF
    encoded[2] = (encoded[2] + ((last - first) ^ (((encoded[1] << 3) | (encoded[1] >> 5)) & 0xFF) ^ 2)) & 0xFF
    for i in range(len(encoded) - 4):
        temp = (((encoded[i + 2] << 3) | (encoded[i + 2] >> 5)) & 0xFF) ^ encoded[i + 1] ^ (i + 3)
        encoded[i + 3] = (~temp + encoded[i + 3]) & 0xFF
    encoded[-1] ^= encoded[-2]
    total = 0
    for i in range(len(encoded) - 1):
        total += encoded[i + 1]
    encoded[0] = ((encoded[0] ^ encoded[1]) + total) & 0xFF
    return bytes(encoded)


def _key_hash(sign_key, rnd):
    digest = _sm3(bytes(sign_key) + _le32(rnd) + bytes(sign_key))
    d1 = (rnd >> 16) & 0xFF
    d2 = ((d1 << 11) | (rnd >> 24)) ^ (d1 >> 5) ^ d1
    d2 = (~d2) & 0xFFFFFFFF
    return digest, _le32(d2)


def _device_proto(device_id):
    started = _PROCESS_STARTED
    return _proto([
        (1, 1, "sint"), (2, 2, "sint"), (3, "8662"), (4, str(device_id)),
        (5, _PROCESS_NONCE), (6, "!noperm!"), (7, -888888, "sint"), (8, -888888, "sint"),
        (9, 3, "sint"), (10, -888888, "sint"), (11, "!notset!"), (12, "Asia/Shanghai,8"),
        (13, "zh_CN"), (14, 4, "sint"), (16, 0, "float"), (17, 0, "float"),
        (18, 0, "float"), (19, 0, "float"), (20, 0, "float"), (21, 0, "float"),
        (22, "16"), (23, 41, "sint"), (24, 36, "sint"),
        (25, started, "sint"), (26, started, "sint"), (27, started, "sint"), (28, started, "sint"),
        (29, -1, "sint"), (30, "25053RT47C"), (31, "Redmi"), (32, "25053RT47C"),
        (33, "25053RT47C"), (34, "Xiaomi"), (35, "Redmi"), (36, "Redmi"), (38, 31, "sint"),
    ])


def _build_medusa(url, body, khronos, device):
    body_md5 = _md5_bytes(body) if body else b"\0" * 16
    query = url.split("?", 1)[1] if "?" in url else ""
    query_sm3 = _sm3(query.encode("utf-8"))
    ts = _le32(khronos)
    query_body_ts = _hash_f13(query_sm3, body_md5, ts, khronos)
    nested = _proto([(1, 111, "sint"), (2, 10, "sint"), (3, 694367, "sint"), (5, 586952199, "sint")])
    message_rand = int(_random.random() * 0x100000000)
    env_launch = int(_random.random() * 21) + 100
    env_pid = int(_random.random() * 2000) + 10001
    env = _proto([
        (1, env_launch, "sint"), (2, 146331399, "sint"), (3, 146331396, "sint"),
        (5, 7, "sint"), (6, "v04.06.04.03-bugfix"), (7, env_pid, "sint"),
        (12, _device_proto(device["device_id"]), "message"),
        (13, _proto([(1, int(_time.time()), "sint"), (2, -2, "sint"), (4, 200, "sint")]), "message"),
        (14, str(device["version_name"])),
    ])
    query_hash = _sm3(query.encode("utf-8") + body_md5 + b"none")
    message = _proto([
        (1, bytes.fromhex("f7e85ffad7d7dc3bd62ac87057cf6118"), "bytes"),
        (2, 3, "sint"), (3, message_rand, "sint"), (4, "8662"),
        (5, str(device["device_id"])), (6, "1588093228"), (7, str(device["version_name"])),
        (8, "v04.06.04-ml-android"), (9, 67503104, "sint"),
        (10, bytes.fromhex("4001000000000000"), "bytes"),
        (12, khronos, "sint"), (13, query_body_ts, "bytes"),
        (14, query_sm3[:6], "bytes"), (15, nested, "message"),
        (16, _PROCESS_NONCE), (17, khronos, "sint"), (19, query_hash, "bytes"),
        (20, "none"), (21, 312, "sint"), (23, env, "message"),
        (24, '{"cmr":16777216,"cmr2":16777216,"un_h":1879194040,"vpn":0,"kd":0,"fkd":3672518972,"pd":-1872573247,"dyn":"","do":0,"tk":true}'),
    ])
    rnd = int(_random.random() * 0x100000000)
    sign_key = bytes.fromhex("8ebdfa3806ecc5cee79423e6029ed82540bc2218bb7eaef71cb691f7aa8aa2f5")
    digest, seed = _key_hash(sign_key, rnd)
    transformed = _xmxor(message, digest)
    transformed = bytes.fromhex("4001000000000000") + transformed
    transformed = transformed[::-1]
    transformed = bytes(b ^ seed[(~i) & 3] for i, b in enumerate(transformed))
    check = ((query_sm3[0] & 63) << 14) | 0x18000001 | ((query_body_ts[0] & 63) << 8)
    xm_rand = int(_random.random() * 0x100000000)
    packed = b"\x35" + _le32(xm_rand) + _le32(check) + transformed + bytes([(rnd >> 16) & 0xFF, (rnd >> 24) & 0xFF])
    encrypted = _AesV3(bytes.fromhex("f1593376766ea98d34f31b057a9d5be4"), khronos).encrypt(
        packed, bytes.fromhex("1fe109a4125283f418de9e051a969e12"))
    version = bytes.fromhex("03000000f7e85ffad7d7dc3bd62ac87057cf6118")
    prefix = b"".join(((int.from_bytes(version[i:i + 4], "little") ^ khronos) & 0xFFFFFFFF).to_bytes(4, "little")
                      for i in range(0, 20, 4))
    return _b64.b64encode(prefix + bytes([rnd & 0xFF, (rnd >> 8) & 0xFF, 0, 1]) + encrypted).decode("ascii")


def _random_uuid():
    return str(_uuid.uuid4())


def _random_openudid():
    return "%016x" % _random.getrandbits(64)


def _valid_device_identity(session):
    if not isinstance(session, dict):
        return False
    did = str(session.get("device_id") or "")
    iid = str(session.get("iid") or session.get("install_id") or "")
    return bool(_re.fullmatch(r"[1-9]\d{5,23}", did) and _re.fullmatch(r"[1-9]\d{5,23}", iid))


def _new_device_seed():
    return {
        "cdid": _random_uuid(),
        "openudid": _random_openudid(),
        "clientudid": _random_uuid(),
        "req_id": _random_uuid(),
        "key_register_ts": int(_time.time()),
    }


def _select_signed_url(base_url, vals, body, ts):
    # hash 分支必须严格等于 0（128 次尝试）；分支 2 的签名与服务端期望不一致。
    base_ms = int(_time.time() * 1000)
    query = ""
    url = ""
    for off in range(128):
        vals["_rticket"] = str(base_ms + off)
        query = "&".join("%s=%s" % (_pct(k), _pct(v)) for k, v in vals.items())
        url = base_url + "?" + query
        if _branch_of(url, body, ts) == 0:
            return url, query, vals["_rticket"]
    raise ValueError("无法生成播放请求签名")


def _build_signed_headers(query, body, ts, rticket, url, device):
    rnd = int(_random.random() * 65536)
    body_bytes = body.encode("utf-8") if isinstance(body, str) else (body or b"")
    return {
        "User-Agent": _PLAYBACK_UA,
        "Accept": "application/json; charset=utf-8,application/x-protobuf",
        "Content-Type": "application/json; charset=UTF-8",
        "x-ss-req-ticket": str(rticket),
        "sdk-version": "2",
        "x-xs-from-web": "0",
        "x-khronos": str(ts),
        "x-gorgon": _x_gorgon(query, body_bytes, ts, rnd),
        "x-ladon": _b64.b64encode(_be32(ts)).decode(),
        "x-argus": _b64.b64encode(_le32(ts)).decode(),
        "x-helios": _helios(ts),
        "x-medusa": _build_medusa(url, body_bytes, ts, device),
        "x-tt-dt": "",
        "x-tt-store-region": "cn",
        "x-tt-store-region-src": "did",
    }


def _tt_encrypt(payload):
    # ttEncrypt：gzip 压缩后 AES-128-CBC 加密；
    # 体 = 746305100000 + 32 字节随机数 + AES-CBC(SHA512(压缩体) || 压缩体)，PKCS7 填充。
    compressed = _gzip.compress(payload, compresslevel=6)
    rnd = _os.urandom(32)
    derived = _hashlib.sha512(_hashlib.sha512(rnd).digest() + _SPADE_CONST).digest()
    from Crypto.Cipher import AES
    cipher = AES.new(derived[:16], AES.MODE_CBC, derived[16:32])
    plaintext = _hashlib.sha512(compressed).digest() + compressed
    pad_len = 16 - (len(plaintext) % 16)
    ciphertext = cipher.encrypt(plaintext + bytes([pad_len]) * pad_len)
    return bytes.fromhex("746305100000") + rnd + ciphertext


def _device_register_request(seed=None):
    s = seed if isinstance(seed, dict) else _new_device_seed()
    now_ms = int(_time.time() * 1000)
    header = {
        "display_name": "红果免费短剧",
        "update_version_code": 73932,
        "manifest_version_code": 73932,
        "app_version_minor": "7.3.9.32",
        "aid": 8662,
        "channel": "update_64",
        "package": "com.phoenix.read",
        "app_version": "7.3.9.32",
        "version_code": 73932,
        "sdk_version": "3.7.0-rc.34-fanqie-xiaoshuo",
        "sdk_target_version": 29,
        "git_hash": "3a88f4e",
        "os": "Android",
        "os_version": "16",
        "os_api": 36,
        "device_model": "25053RT47C",
        "device_brand": "Redmi",
        "device_manufacturer": "Redmi",
        "cpu_abi": "arm64-v8a",
        "release_build": "b5e187f",
        "density_dpi": 520,
        "display_density": "mdpi",
        "resolution": "1280x2772",
        "language": "zh",
        "timezone": 8,
        "access": "wifi",
        "not_request_sender": 0,
        "carrier": "CHINA MOBILE",
        "mcc_mnc": "46000",
        "rom": "eng.root.20231116.160340",
        "rom_version": "W528JS release-keys",
        "cdid": s["cdid"],
        "sig_hash": "56a962410c494bbaf0b58dba20cae56f",
        "openudid": s["openudid"],
        "clientudid": s["clientudid"],
        "ipv6_list": [],
        "region": "CN",
        "tz_name": "Asia/Shanghai",
        "tz_offset": 28800,
        "sim_region": "cn",
        "sim_serial_number": [],
        "oaid_may_support": False,
        "req_id": s.get("req_id") or _random_uuid(),
        "device_platform": "android",
        "custom": {"account_region_src": "fallback", "account_region": "cn",
                   "host_bit": 64, "dragon_device_type": "phone"},
        "pre_installed_channel": "",
        "apk_first_install_time": now_ms,
        "is_system_app": 0,
        "sdk_flavor": "china",
        "guest_mode": 0,
    }
    payload = {"magic_tag": "ss_app_log", "header": header, "_gen_time": now_ms}
    body = _json.dumps(payload, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
    data = _tt_encrypt(body)
    headers = {
        "User-Agent": _REGISTER_UA,
        "Accept": "application/json",
        "Content-Type": "application/octet-stream;tt-data=a",
        "log-encode-type": "gzip",
        "x-ss-dp": "8662",
        "x-ss-req-ticket": str(now_ms),
        "x-vc-bdturing-sdk-version": "4.0.3.cn",
        "lc": "101",
        "sdk-version": "2",
        "passport-sdk-version": "5051452",
        "x-neptune": "-8|50:51:59:30:40:47:49:39",
        "x-ss-stub": _md5_bytes(data).hex().upper(),
    }
    return _DEVICE_REGISTER_API, headers, data, s


def _post_bytes(url, body, headers, timeout, max_bytes=8 * 1024 * 1024):
    """POST and return the (gzip-decoded) response body.

    Prefers requests (keep-alive): urllib forces `Connection: close` on
    every request, which the overseas CDN path intermittently resets or
    truncates mid-body (IncompleteRead / RemoteDisconnected). Falls back
    to urllib when requests is unavailable.
    """
    try:
        import requests as _requests
    except Exception:
        _requests = None
    if _requests is not None:
        resp = _requests.post(url, data=body, headers=headers, timeout=timeout)
        resp.raise_for_status()
        if len(resp.content) > max_bytes:
            raise ValueError("response exceeds size limit")
        return resp.content
    req = _ureq.Request(url, data=body, headers=headers, method="POST")
    with _ureq.urlopen(req, timeout=timeout) as r:
        raw = r.read(max_bytes + 1)
        encoding = str(r.headers.get("Content-Encoding", "") or "").strip().lower()
    if len(raw) > max_bytes:
        raise ValueError("response exceeds size limit")
    if encoding == "gzip":
        return _gzip.decompress(raw)
    return raw


def _register_device():
    global _DEVICE_SESSION
    url, headers, body, seed = _device_register_request()
    headers = dict(headers)
    # 注册响应只有约 384 字节：用 identity 编码（gzip 响应在该链路上反而更易截断）。
    headers["Accept-Encoding"] = "identity"
    last_err = None
    raw = b""
    for attempt in range(3):
        try:
            raw = _post_bytes(url, body, headers, 20, max_bytes=1024 * 1024)
            break
        except Exception as e:
            last_err = e
            if attempt < 2:
                _time.sleep(0.3 * (attempt + 1))
    else:
        raise ValueError("device_register request failed: %s" % type(last_err).__name__)
    if not raw or len(raw) > 1024 * 1024:
        raise ValueError("empty or oversized device_register response")
    j = _json.loads(raw.decode("utf-8", "replace"))
    if not isinstance(j, dict):
        raise ValueError("invalid device_register JSON")
    code = j.get("code", j.get("Code", 0))
    try:
        code = int(code)
    except (TypeError, ValueError):
        code = -1
    if code != 0:
        raise ValueError("device_register rejected the request")
    data = j.get("data") if isinstance(j.get("data"), dict) else {}
    did = str(j.get("device_id_str") or j.get("device_id") or data.get("device_id_str") or data.get("device_id") or "")
    iid = str(j.get("install_id_str") or j.get("install_id") or j.get("iid") or data.get("install_id_str") or data.get("install_id") or data.get("iid") or "")
    session = {
        "device_id": did,
        "iid": iid,
        "cdid": seed["cdid"],
        "openudid": seed["openudid"],
        "clientudid": seed["clientudid"],
        "key_register_ts": int(_time.time()),
        "registered_at": _time.time(),
    }
    if not _valid_device_identity(session):
        raise ValueError("device_register returned invalid device identity")
    _DEVICE_SESSION = session
    return session


def _ensure_device(force_refresh=False):
    global _DEVICE_SESSION
    with _DEVICE_LOCK:
        if not force_refresh and _valid_device_identity(_DEVICE_SESSION):
            return _DEVICE_SESSION
        return _register_device()


def _signed_single_request(vid, content_type=1, device=None, host=_VIDEO_MODEL_HOST):
    """Build a signed POST request to /novel/player/video_model/v1/ for comic-drama/long series."""
    ts = int(_time.time())
    dev = device if _valid_device_identity(device) else _ensure_device(False)
    payload = {
        "biz_param": {
            "detail_page_version": 0,
            "device_level": 3,
            "need_all_video_definition": True,
            "need_mp4_align": False,
            "use_os_player": False,
            "video_platform": 1024,
        },
        "content_type": int(content_type),
        "video_id": str(vid),
    }
    body = _json.dumps(payload, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
    vals = dict(_PLAYBACK_DEVICE)
    vals.update({
        "device_id": str(dev["device_id"]),
        "iid": str(dev["iid"]),
        "cdid": str(dev.get("cdid") or _random_uuid()),
        "ts": str(ts),
    })
    base_url = "https://%s/novel/player/video_model/v1/" % host
    url, query, rticket = _select_signed_url(base_url, vals, body, ts)
    headers = _build_signed_headers(query, body, ts, rticket, url, {
        "device_id": str(dev["device_id"]),
        "version_name": _PLAYBACK_DEVICE["version_name"],
    })
    return url, headers, body


def _extract_fallback_api_url(vm, ent=None, data=None):
    for container in (vm, ent, data):
        if not isinstance(container, dict):
            continue
        fb = container.get("fallback_api")
        if isinstance(fb, str) and fb.strip():
            s = fb.strip()
            if s.startswith(("http://", "https://")):
                return s
            try:
                parsed = _json.loads(s)
                if isinstance(parsed, dict) and isinstance(parsed.get("fallback_api"), str):
                    return parsed["fallback_api"].strip()
            except Exception:
                pass
        elif isinstance(fb, dict) and isinstance(fb.get("fallback_api"), str):
            return fb["fallback_api"].strip()
        elif isinstance(fb, list) and fb and isinstance(fb[0], str):
            return fb[0].strip()
    return ""


def _fetch_fallback_video_model(fb_url, seed_hint=""):
    if not isinstance(fb_url, str) or not fb_url.startswith(("http://", "https://")):
        return None
    req = _ureq.Request(fb_url, headers={"User-Agent": _PLAYBACK_UA, "Accept": "application/json"})
    with _ureq.urlopen(req, timeout=15) as r:
        raw = r.read(4 * 1024 * 1024)
    j = _json.loads(raw.decode("utf-8", "replace"))
    if not isinstance(j, dict):
        return None
    vi = j.get("video_info") if isinstance(j.get("video_info"), dict) else j
    vdata = vi.get("data") if isinstance(vi.get("data"), dict) else vi
    if not isinstance(vdata, dict):
        return None
    dyn = vdata.get("dynamic_video") if isinstance(vdata.get("dynamic_video"), dict) else {}
    lst = vdata.get("video_list") or vdata.get("dynamic_video_list") or dyn.get("dynamic_video_list") or dyn.get("video_list")
    if isinstance(lst, list):
        videos = {}
        for i, item in enumerate(lst):
            if isinstance(item, dict):
                q = _video_quality(item, str(i))
                videos[q if q and q not in videos else str(i)] = item
        lst = videos
    if not isinstance(lst, dict) or not lst:
        return None
    return {
        "video_list": lst,
        "key_seed": str(vdata.get("key_seed") or vi.get("key_seed") or j.get("key_seed") or seed_hint or ""),
    }


def _signed_request(vid, device=None, host=_VIDEO_MODEL_HOST):
    """Build a signed POST request to novel/player/multi_video_model/v1/ (JS playbackRequest)."""
    ts = int(_time.time())
    dev = device if _valid_device_identity(device) else _ensure_device(False)
    payload = {
        "biz_param": {
            "detail_page_version": 0,
            "device_level": 3,
            "disable_digg_stat": False,
            "need_all_video_definition": True,
            "need_mp4_align": False,
            "use_os_player": False,
            "use_server_dns": False,
            "video_platform": 1024,
        },
        "mixed_video_id_map": {"1004": [str(vid)]},
    }
    body = _json.dumps(payload, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
    vals = dict(_PLAYBACK_DEVICE)
    vals.update({
        "device_id": str(dev["device_id"]),
        "iid": str(dev["iid"]),
        "cdid": str(dev.get("cdid") or _random_uuid()),
        "ts": str(ts),
    })
    base_url = "https://%s%s" % (host, _VIDEO_MODEL_PATH)
    url, query, rticket = _select_signed_url(base_url, vals, body, ts)
    headers = _build_signed_headers(query, body, ts, rticket, url, {
        "device_id": str(dev["device_id"]),
        "version_name": _PLAYBACK_DEVICE["version_name"],
    })
    return url, headers, body


def _decrypt_spade(value, seed):
    from Crypto.Cipher import AES
    raw = _b64.b64decode(value + "=" * (-len(value) % 4))
    if len(raw) < 5 or raw[0] != 0xA8 or raw[2] != 0x01 or raw[3] != 0x00:
        return None
    n = (len(raw) - 4) // 16 * 16
    if not n:
        return None
    h1 = _hashlib.sha512(seed).digest()
    h2 = _hashlib.sha512(h1 + _SPADE_CONST).digest()
    pt = AES.new(h2[:16], AES.MODE_CBC, h2[16:32]).decrypt(raw[4:4 + n])
    if pt:
        p = pt[-1]
        if 1 <= p <= 16 and p <= len(pt):
            pt = pt[:-p]
    pt = pt.rstrip(b"\0")
    try:
        s = pt.decode("utf-8")
    except UnicodeDecodeError:
        return None
    return s if s.startswith("http") else None


def _resolve_media_url(it, vm):
    if not isinstance(it, dict):
        return None
    seed_s = (vm.get("key_seed") if isinstance(vm, dict) else "") or it.get("key_seed") or ""
    seed = _b64.b64decode(seed_s + "=" * (-len(seed_s) % 4)) if seed_s else b""
    for key in ("main_url", "backup_url_1", "backup_url_2", "backup_url"):
        raw_url = it.get(key)
        if not isinstance(raw_url, str) or not raw_url:
            continue
        if raw_url.startswith(("http://", "https://")):
            return raw_url
        if seed:
            dec = _decrypt_spade(raw_url, seed)
            if dec:
                return dec
        try:
            plain = _b64.b64decode(raw_url + "=" * (-len(raw_url) % 4)).decode("utf-8").strip()
            if plain.startswith(("http://", "https://")):
                return plain
        except Exception:
            pass
    return None


def _content_key(spade_a):
    s = spade_a.replace("-", "+").replace("_", "/")
    raw = _b64.b64decode(s + "=" * (-len(s) % 4))
    if len(raw) < 3:
        return None
    n = min(len(raw) - (raw[0] ^ raw[1] ^ raw[2]) + 47, len(raw) - 1)
    if n < 33:
        return None
    work = bytearray(raw[1:1 + n])
    a, b = 85, 246
    for i in range(n):
        old = work[i]
        prev = a if (i & 1) else b
        if i & 1:
            a = old
        else:
            b = old
        work[i] = (-21 - bin(i).count("1") + (prev ^ old)) & 0xFF
    try:
        return bytes(work[1:33]).decode("ascii")
    except UnicodeDecodeError:
        return None


def _parse_video_model_response(j, vid):
    if not isinstance(j, dict):
        raise ValueError("video model API rejected the request")
    code = j.get("code", j.get("Code", 0))
    try:
        code = int(code)
    except (TypeError, ValueError):
        code = -1
    if code != 0:
        raise ValueError("video model API rejected the request")
    data = j.get("data")
    if isinstance(data, str):
        try:
            data = _json.loads(data)
        except Exception:
            pass
    if isinstance(data, list):
        matching = next((x for x in data if isinstance(x, dict) and str(x.get("item_id") or x.get("id") or x.get("vid")) == str(vid)), None)
        data = matching or (data[0] if data and isinstance(data[0], dict) else {})
    elif not isinstance(data, dict):
        data = j if isinstance(j, dict) else {}

    models = data.get("video_model_data") if isinstance(data, dict) else None
    ent = None
    if isinstance(models, list):
        matching = next((x for x in models if isinstance(x, dict) and str(x.get("item_id") or x.get("id") or x.get("vid")) == str(vid)), None)
        ent = matching or (models[0] if models and isinstance(models[0], dict) else None)
    elif isinstance(models, dict):
        ent = models.get(str(vid))
        if ent is None:
            ent = next((value for value in models.values() if isinstance(value, dict)), None)
    if not isinstance(ent, dict) and isinstance(data.get(str(vid)), dict):
        ent = data.get(str(vid))
    if not isinstance(ent, dict):
        ent = data
    vm = ent.get("video_model") if isinstance(ent, dict) else None
    if vm is None and isinstance(data, dict):
        vm = data.get("video_model")
    if vm is None and isinstance(j, dict):
        vm = j.get("video_model")
    if isinstance(vm, str):
        try:
            vm = _json.loads(vm)
        except Exception:
            vm = None
    if isinstance(vm, dict) and isinstance(vm.get("video_model"), (dict, str)):
        inner = vm.get("video_model")
        if isinstance(inner, str):
            try:
                inner = _json.loads(inner)
            except Exception:
                inner = None
        if isinstance(inner, dict):
            vm = inner
    if not isinstance(vm, dict) and isinstance(data, dict) and (
            data.get("video_list") or data.get("dynamic_video_list") or data.get("dynamic_video")):
        vm = dict(data)
    if not isinstance(vm, dict) and isinstance(ent, dict) and (
            ent.get("video_list") or ent.get("dynamic_video_list") or ent.get("dynamic_video")):
        vm = dict(ent)
    if not isinstance(vm, dict):
        raise ValueError("video model API returned no model")
    if not vm.get("key_seed"):
        if isinstance(ent, dict) and ent.get("key_seed"):
            vm["key_seed"] = ent["key_seed"]
        elif isinstance(data, dict) and data.get("key_seed"):
            vm["key_seed"] = data["key_seed"]
    dyn = vm.get("dynamic_video") if isinstance(vm.get("dynamic_video"), dict) else {}
    lst = vm.get("video_list") or vm.get("dynamic_video_list") or dyn.get("dynamic_video_list") or dyn.get("video_list")
    if isinstance(lst, list):
        videos = {}
        for i, item in enumerate(lst):
            if isinstance(item, dict):
                q = _video_quality(item, str(i))
                videos[q if q and q not in videos else str(i)] = item
        vm["video_list"] = videos
    elif isinstance(lst, dict):
        vm["video_list"] = lst
    if not isinstance(vm.get("video_list"), dict) or not vm["video_list"]:
        fb_url = _extract_fallback_api_url(vm, ent, data)
        if fb_url:
            fb_vm = _fetch_fallback_video_model(fb_url, seed_hint=str(vm.get("key_seed") or ""))
            if isinstance(fb_vm, dict) and fb_vm.get("video_list"):
                return fb_vm
        raise ValueError("video model has no video qualities")
    return vm


def _signed_model(vid):
    """Fetch a signed 5-tier video model using a registered anonymous device session."""
    ent = _SIGN_CACHE.get(str(vid))
    if ent and _time.time() - ent[0] < _SIGN_CACHE_TTL:
        return ent[1]
    deadline = _time.monotonic() + 15
    last_err = None
    dev = None
    for attempt in range(3):
        retryable = False
        try:
            if dev is None:
                dev = _ensure_device(False)
            host = _VIDEO_MODEL_HOST if attempt % 2 == 0 else _VIDEO_MODEL_ALT_HOST
            payload_url, headers, body = _signed_request(vid, dev, host=host)
            if attempt:
                headers["Connection"] = "close"
            # gzip 响应体更小，在海外中转链路上不易被截断；服务端支持 gzip。
            headers["Accept-Encoding"] = "gzip"
            raw = _post_bytes(payload_url, body, headers, 25)
            if len(raw) > 8 * 1024 * 1024:
                raise ValueError("video model response exceeds 8 MiB")
            if not raw:
                raise ValueError("video model API returned an empty response")
        except Exception as e:
            last_err = e
            retryable = True
        else:
            try:
                j = _json.loads(raw.decode("utf-8", "replace"))
            except Exception as e:
                last_err = e
                retryable = True
            else:
                try:
                    vm = _parse_video_model_response(j, vid)
                except Exception as e:
                    last_err = e
                    retryable = True
                else:
                    _SIGN_CACHE[str(vid)] = (_time.time(), vm)
                    return vm
        if not retryable or attempt == 2:
            break
        # 空响应/截断/损坏：预算充足时重新注册设备，换域名重试。
        if deadline - _time.monotonic() >= 3:
            try:
                dev = _ensure_device(force_refresh=True)
            except Exception:
                dev = None
        if deadline - _time.monotonic() < 0.5:
            break
        _time.sleep(0.3)
    # Fallback to /novel/player/video_model/v1/ (content_type 1 / 1001) for comic-drama / comic episodes
    if dev is not None and _valid_device_identity(dev):
        for ct in (1, 1001):
            try:
                s_url, s_headers, s_body = _signed_single_request(vid, content_type=ct, device=dev, host=_VIDEO_MODEL_HOST)
                s_headers["Accept-Encoding"] = "gzip"
                raw = _post_bytes(s_url, s_body, s_headers, 15)
                if raw:
                    vm = _parse_video_model_response(_json.loads(raw.decode("utf-8", "replace")), vid)
                    if vm and vm.get("video_list"):
                        _SIGN_CACHE[str(vid)] = (_time.time(), vm)
                        return vm
            except Exception as e:
                last_err = e
    _trace("hgtv_signed_model_error", episode_id=vid,
           err=(type(last_err).__name__ if last_err else "request failed"))
    return None


def _video_metadata(item):
    """Parse the provider's Python-dict video_meta string safely."""
    if not isinstance(item, dict):
        return {}
    value = item.get("video_meta") or item.get("videoMeta") or item.get("meta")
    if isinstance(value, dict):
        return value
    if not isinstance(value, str) or len(value) > 65536:
        return {}
    try:
        parsed = _json.loads(value)
    except (ValueError, TypeError):
        try:
            parsed = ast.literal_eval(value)
        except (ValueError, SyntaxError, TypeError, MemoryError, RecursionError):
            return {}
    return parsed if isinstance(parsed, dict) else {}


def _video_quality(item, fallback=""):
    metadata = _video_metadata(item)
    for candidate in (item.get("definition"), metadata.get("definition"),
                      item.get("quality_name"), metadata.get("quality_name"),
                      item.get("quality"), metadata.get("quality")):
        if candidate is None:
            continue
        quality = str(candidate).strip().lower().replace(" ", "")
        if quality.isdigit():
            quality += "p"
        if quality in _QORDER:
            return quality
    gear = str(item.get("gear_des_key") or "")
    match = _re.search(r"(?:^|\|)4:(1080p|720p|540p|480p|360p)(?=\||$)", gear, _re.I)
    if match:
        return match.group(1).lower()
    try:
        w = int(item.get("vwidth") or metadata.get("vwidth") or 0)
        h = int(item.get("vheight") or metadata.get("vheight") or 0)
        short_side = min(w, h) if (w > 0 and h > 0) else 0
        if short_side in (360, 480, 540, 720, 1080):
            return "%dp" % short_side
    except (ValueError, TypeError):
        pass
    fallback = str(fallback).strip().lower()
    return fallback if fallback in _QORDER else fallback


def _pick_best(vm, want):
    """挑可解的最高档（bvc2 排后）。"""
    vl = (vm or {}).get("video_list") or {}
    cands = []
    for k, it in vl.items():
        q = _video_quality(it, str(k))
        gear = str(it.get("gear_des_key") or "")
        metadata = _video_metadata(it)
        bad = 1 if ("bytevc2" in gear or "bvc2" in gear) else 0
        if str(metadata.get("vtype") or it.get("vtype") or "").lower() in ("bytevc2", "bvc2"):
            bad = 1
        order = _QORDER.index(q) if q in _QORDER else 99
        cands.append((bad, order, q, it))
    if not cands:
        return None
    cands.sort(key=lambda x: (x[0], x[1]))
    if want:
        for c in cands:
            if c[2] == want and c[0] == 0:
                return c[3], c[2]
        return None
    usable = [c for c in cands if c[0] == 0]
    return (usable[0][3], usable[0][2]) if usable else None


########## 纯 Python CENC 解密（宿主无 ffmpeg 时使用） ##########
# 移植自 drpys hongguo.cjs：解析 MP4 样本表 + senc 的每样本 IV，
# 用 AES-CTR 逐样本解密 mdat，并把 moov 里的 encv/enca/sinf 改写掉。
import struct as _struct

try:
    from Crypto.Cipher import AES as _AES
    from Crypto.Util import Counter as _Counter
    _HAS_CRYPTO = True
except Exception:
    _HAS_CRYPTO = False
try:
    import hostcrypto as _HOSTCRYPTO
except Exception:
    _HOSTCRYPTO = None


def _rd_box(data, off):
    if off < 0 or off + 8 > len(data):
        return None
    size = _struct.unpack_from(">I", data, off)[0]
    typ = data[off + 4:off + 8].decode("latin1", "replace")
    header = 8
    if size == 1:
        if off + 16 > len(data):
            return None
        size = _struct.unpack_from(">Q", data, off + 8)[0]
        header = 16
    elif size == 0:
        size = len(data) - off
    if size < header or off + size > len(data):
        return None
    return {"offset": off, "size": size, "type": typ, "header": header, "body": off + header}


def _fd_box(data, typ, start=0):
    off = max(0, start)
    n = len(data)
    while off + 8 <= n:
        b = _rd_box(data, off)
        if b and b["type"] == typ:
            return b
        off += 1
    return None


def _bx_body(data, typ, start=0):
    b = _fd_box(data, typ, start)
    return None if not b else data[b["body"]:b["offset"] + b["size"]]


def _u32b(d, o):
    return _struct.unpack_from(">I", d, o)[0]


def _u64b(d, o):
    return _struct.unpack_from(">Q", d, o)[0]


def _parse_track(moov, track):
    stbl = _fd_box(moov, "stbl", track["body"])
    if not stbl:
        return None
    stsz = _bx_body(moov, "stsz", stbl["body"])
    stsc = _bx_body(moov, "stsc", stbl["body"])
    chunk = _fd_box(moov, "stco", stbl["body"]) or _fd_box(moov, "co64", stbl["body"])
    saiz = _bx_body(moov, "saiz", stbl["body"])
    saio = _bx_body(moov, "saio", stbl["body"])
    if not (stsz and stsc and chunk and saiz and saio):
        return None
    if len(stsz) < 12 or len(stsc) < 8 or len(saiz) < 9 or len(saio) < 12:
        return None
    dsize = _u32b(stsz, 4)
    scount = _u32b(stsz, 8)
    sizes = [dsize] * scount if dsize else []
    if not dsize:
        for i in range(scount):
            at = 12 + i * 4
            if at + 4 > len(stsz):
                return None
            sizes.append(_u32b(stsz, at))
    if len(sizes) != scount:
        return None
    is64 = chunk["type"] == "co64"
    ccount = _u32b(moov, chunk["body"] + 4)
    offs = []
    for i in range(ccount):
        at = chunk["body"] + 8 + i * (8 if is64 else 4)
        if at + (8 if is64 else 4) > chunk["offset"] + chunk["size"]:
            return None
        offs.append(_u64b(moov, at) if is64 else _u32b(moov, at))
    ecount = _u32b(stsc, 4)
    entries = []
    for i in range(ecount):
        at = 8 + i * 12
        if at + 8 > len(stsc):
            return None
        entries.append((_u32b(stsc, at), _u32b(stsc, at + 4)))
    spc = []
    for idx in range(len(offs)):
        sel = 0
        for first, per in entries:
            if first <= idx + 1:
                sel = per
        spc.append(sel)
    aux_default = saiz[4]
    aux_count = _u32b(saiz, 5)
    aux_sizes = [aux_default] * aux_count if aux_default else []
    if not aux_default:
        at = 9
        for _i in range(aux_count):
            if at + 1 > len(saiz):
                break
            aux_sizes.append(saiz[at])
            at += 1
    sver = saio[0]
    aux_offset = (_u64b(saio, 8) if len(saio) >= 16 else -1) if sver == 1 else (_u32b(saio, 8) if len(saio) >= 12 else -1)
    return {"sizes": sizes, "offsets": offs, "spc": spc, "auxOffset": aux_offset,
            "auxSizes": aux_sizes, "sampleCount": scount}


def _build_samples(data, tracks):
    out = []
    for tr in tracks:
        idx = 0
        apos = 0
        atotal = sum(max(s, 8) for s in tr["auxSizes"])
        if tr["auxOffset"] < 0 or tr["auxOffset"] + atotal > len(data):
            raise ValueError("aux out of range")
        aux = data[tr["auxOffset"]:tr["auxOffset"] + atotal]
        for ci in range(len(tr["offsets"])):
            if idx >= tr["sampleCount"]:
                break
            off = tr["offsets"][ci]
            cnt = tr["spc"][ci] if ci < len(tr["spc"]) else 0
            for _x in range(cnt):
                if idx >= tr["sampleCount"]:
                    break
                size = tr["sizes"][idx]
                asz = max(tr["auxSizes"][idx] if idx < len(tr["auxSizes"]) else 8, 8)
                if apos + asz > len(aux):
                    raise ValueError("sample index out of range")
                iv = bytearray(16)
                take = min(8, asz)
                iv[:take] = aux[apos:apos + take]
                out.append((off, off + size, bytes(iv)))
                off += size
                idx += 1
                apos += asz
    out.sort(key=lambda x: x[0])
    return out


def _replace_sinf(header):
    pos = 0
    while True:
        pos = header.find(b"sinf", pos)
        if pos < 0:
            break
        if pos < 4:
            pos += 4
            continue
        size = _struct.unpack_from(">I", header, pos - 4)[0]
        end = pos - 4 + size
        if 8 <= size < 50000 and end <= len(header):
            header[pos:pos + 4] = b"free"
            for i in range(pos + 4, end):
                header[i] = 0
            pos = end
        else:
            pos += 4


def _clear_aux_boxes(header):
    """Remove CENC auxiliary metadata while preserving every MP4 box offset."""
    for kind in (b"senc", b"saiz", b"saio", b"sgpd", b"sbgp"):
        pos = 0
        while True:
            pos = header.find(kind, pos)
            if pos < 0:
                break
            if pos < 4:
                pos += 4
                continue
            start = pos - 4
            size = _struct.unpack_from(">I", header, start)[0]
            end = start + size
            if kind in (b"sgpd", b"sbgp") and (
                    pos + 12 > end or header[pos + 8:pos + 12] != b"seig"):
                pos += 4
                continue
            if 8 <= size and end <= len(header):
                header[pos:pos + 4] = b"free"
                header[start + 8:end] = b"\0" * (size - 8)
                pos = end
            else:
                pos += 4


def _replace_fourcc(data, old, new):
    ob = old.encode()
    pos = 0
    while True:
        pos = data.find(ob, pos)
        if pos < 0:
            break
        data[pos:pos + 4] = new.encode()
        pos += 4


def _iter_mp4_boxes(data, start, end):
    """Iterate bounded child boxes without scanning into a sibling box."""
    offset = start
    while offset + 8 <= end:
        item = _rd_box(data, offset)
        if not item or item["offset"] + item["size"] > end:
            return
        yield item
        offset = item["offset"] + item["size"]


def _mp4_child(data, parent, kind):
    if not parent:
        return None
    for item in _iter_mp4_boxes(data, parent["body"], parent["offset"] + parent["size"]):
        if item["type"] == kind:
            return item
    return None


def _hevc_entries(data, moov):
    """Yield each HEVC config record and its coded dimensions from stsd."""
    if not moov:
        return
    for trak in _iter_mp4_boxes(data, moov["body"], moov["offset"] + moov["size"]):
        if trak["type"] != "trak":
            continue
        mdia = _mp4_child(data, trak, "mdia")
        minf = _mp4_child(data, mdia, "minf")
        stbl = _mp4_child(data, minf, "stbl")
        stsd = _mp4_child(data, stbl, "stsd")
        if not stsd or stsd["offset"] + stsd["size"] - stsd["body"] < 8:
            continue
        pos = stsd["body"] + 8  # full-box header and entry_count
        end = stsd["offset"] + stsd["size"]
        while pos + 8 <= end:
            entry = _rd_box(data, pos)
            if not entry or entry["offset"] + entry["size"] > end:
                break
            if entry["type"] in ("hvc1", "hev1", "encv") and entry["size"] >= entry["header"] + 78:
                width, height = _struct.unpack_from(">HH", data, entry["body"] + 24)
                child_start = entry["body"] + 78
                for child in _iter_mp4_boxes(data, child_start, entry["offset"] + entry["size"]):
                    if child["type"] == "hvcC":
                        yield child, width, height, entry["type"]
            pos = entry["offset"] + entry["size"]


def _restore_protected_entries(header, moov):
    """Recover each sample codec from sinf/frma before clearing protection."""
    def visit(parent):
        for child in _iter_mp4_boxes(header, parent['body'], parent['offset'] + parent['size']):
            if child['type'] in ('moov', 'trak', 'mdia', 'minf', 'stbl'):
                visit(child)
            elif child['type'] == 'stsd':
                for entry in _iter_mp4_boxes(header, child['body'] + 8, child['offset'] + child['size']):
                    if entry['type'] not in ('encv', 'enca'):
                        continue
                    prefix = 78 if entry['type'] == 'encv' else 28
                    for box in _iter_mp4_boxes(header, entry['body'] + prefix, entry['offset'] + entry['size']):
                        if box['type'] != 'sinf':
                            continue
                        original = _mp4_child(header, box, 'frma')
                        if not original or original['size'] < original['header'] + 4:
                            raise ValueError('protected sample entry has no original codec')
                        codec = bytes(header[original['body']:original['body'] + 4])
                        header[entry['offset'] + 4:entry['offset'] + 8] = codec
                        break
                    else:
                        raise ValueError('protected sample entry has no sinf')
    visit(moov)


def _validate_clear_moov(data):
    """Strict box boundaries: FFmpeg scanning alone misses broken stsd boxes."""
    video_count = 0
    def boxes(start, end):
        offset = start
        while offset < end:
            item = _rd_box(data, offset)
            if not item or offset + item['size'] > end:
                raise ValueError('invalid MP4 child box size')
            yield item
            offset += item['size']
        if offset != end:
            raise ValueError('incomplete MP4 children')
    def visit(parent):
        nonlocal video_count
        for child in boxes(parent['body'], parent['offset'] + parent['size']):
            if child['type'] in ('moov', 'trak', 'mdia', 'minf', 'stbl', 'edts', 'dinf'):
                visit(child)
            elif child['type'] == 'stsd':
                if child['size'] < child['header'] + 8:
                    raise ValueError('truncated stsd')
                entries = list(boxes(child['body'] + 8, child['offset'] + child['size']))
                if len(entries) != _u32b(data, child['body'] + 4):
                    raise ValueError('stsd entry count mismatch')
                for entry in entries:
                    kind = entry['type']
                    if kind in ('encv', 'enca'):
                        raise ValueError('encrypted sample entry remains')
                    if kind in ('hvc1', 'hev1', 'avc1', 'avc3', 'av01', 'vp09', 'mp4v'):
                        if entry['size'] < entry['header'] + 78:
                            raise ValueError('truncated visual sample entry')
                        children = list(boxes(entry['body'] + 78, entry['offset'] + entry['size']))
                        if any(box['type'] == 'sinf' for box in children):
                            raise ValueError('protection metadata remains')
                        required = 'hvcC' if kind in ('hvc1', 'hev1') else 'avcC' if kind in ('avc1', 'avc3') else None
                        if required and not any(box['type'] == required for box in children):
                            raise ValueError('missing video codec configuration')
                        video_count += 1
    moov = _rd_box(data, 0)
    if not moov or moov['type'] != 'moov' or moov['size'] != len(data):
        raise ValueError('invalid moov')
    visit(moov)
    return video_count > 0


def _cenc_decrypt(src, dst, key):
    """CENC(AES-CTR) 解密，无需 ffmpeg。key 为 bytes(16)。"""
    if not _HAS_CRYPTO and _HOSTCRYPTO is None:
        raise RuntimeError("pycryptodome 不可用")
    with open(src, "rb") as source_file:
        data = source_file.read()
    ftyp = _u32b(data, 0)
    moov = _rd_box(data, ftyp)
    if not moov or moov["type"] != "moov":
        raise ValueError("invalid moov")
    mb = data[moov["body"]:moov["offset"] + moov["size"]]
    tracks = []
    cur = 0
    while True:
        tr = _fd_box(mb, "trak", cur)
        if not tr:
            break
        tracks.append(tr)
        cur = tr["offset"] + tr["size"]
    parsed = [p for p in (_parse_track(mb, t) for t in tracks) if p]
    samples = _build_samples(data, parsed) if parsed else []
    if not samples:
        raise ValueError("CENC sample table is empty")
    out = bytearray(data)
    header = bytearray(data[:moov["offset"] + moov["size"]])
    _restore_protected_entries(header, moov)
    _replace_sinf(header)
    _clear_aux_boxes(header)
    out[:len(header)] = header
    for start, end, iv in samples:
        if start >= len(out):
            continue
        end = min(end, len(out))
        counter_block = bytes(iv[:16]).ljust(16, b"\0")
        encrypted = bytes(out[start:end])
        if _HOSTCRYPTO is not None:
            cipher = _HOSTCRYPTO.AES_CTR(key, counter_block)
            try:
                out[start:end] = cipher.update(encrypted)
            finally:
                cipher.close()
        else:
            # Keep the bundled PyCryptodome-compatible implementation as the
            # fallback for desktop runners and older host builds.
            cnt = int.from_bytes(counter_block, "big")
            cipher = _AES.new(key, _AES.MODE_CTR, counter=_Counter.new(128, initial_value=cnt))
            out[start:end] = cipher.decrypt(encrypted)
    with open(dst, "wb") as f:
        f.write(bytes(out))
    return dst


_FFMPEG = None


def _ffmpeg_path():
    """探测 ffmpeg；宿主（iOS App 内 Python）通常没有，缓存结果。"""
    global _FFMPEG
    if _FFMPEG is None:
        try:
            _FFMPEG = _shutil.which("ffmpeg") or ""
        except Exception:
            _FFMPEG = ""
        _trace("hgtv_ffmpeg_probe", available=bool(_FFMPEG), path=_FFMPEG[:80])
    return _FFMPEG


def _verify_mp4(path, min_bytes=8192):
    """Validate clear video descriptions and every relevant MP4 box boundary."""
    try:
        size = _os.path.getsize(path)
        if size < min_bytes:
            return False
        with open(path, 'rb') as media:
            offset, ftyp, moov = 0, False, None
            while offset + 8 <= size:
                media.seek(offset)
                prefix = media.read(16)
                length, kind = _struct.unpack_from('>I4s', prefix)
                if length == 1:
                    length = _struct.unpack_from('>Q', prefix, 8)[0]
                elif length == 0:
                    length = size - offset
                if length < 8 or offset + length > size:
                    return False
                if kind == b'ftyp':
                    ftyp = True
                if kind == b'moov':
                    if length > 16 * 1024 * 1024:
                        return False
                    media.seek(offset)
                    moov = media.read(length)
                offset += length
            return offset == size and ftyp and moov is not None and _validate_clear_moov(moov)
    except (OSError, ValueError, IndexError, _struct.error):
        return False


def _is_encrypted(it):
    ei = it.get("encrypt_info") or {}
    if ei.get("encrypt"):
        return True
    return "1:encrypt" in str(it.get("gear_des_key") or "")


def _transcode_h264(ff, src, dst):
    """HEVC -> H.264（老播放器兼容）。返回是否成功。"""
    pr = _subprocess.run(
        [ff, "-y", "-v", "error", "-i", src,
         "-c:v", "libx264", "-preset", "veryfast", "-crf", "24",
         "-c:a", "aac", "-b:a", "128k", "-movflags", "+faststart", "-f", "mp4", dst],
        capture_output=True, text=True, timeout=1800)
    return pr.returncode == 0 and _os.path.exists(dst) and _verify_mp4(dst)


def _decrypt_to_file(vid, want):
    _os.makedirs(_DEC_DIR, exist_ok=True)
    vm = _signed_model(vid)
    if not vm:
        return None
    selected = _pick_best(vm, want)
    if not selected:
        return None
    it, q = selected
    _trace("hgtv_quality_selected", episode_id=vid, quality=q)
    dst = _os.path.join(_DEC_DIR, "%s_%s.mp4" % (vid, q))

    # 顺手清掉同一集的其它无效缓存（修复前留下的加密档/截断档）
    try:
        for f in _os.listdir(_DEC_DIR):
            if f.startswith(str(vid) + "_") and f.endswith(".mp4"):
                fp = _os.path.join(_DEC_DIR, f)
                if not _verify_mp4(fp):
                    _os.remove(fp)
                    _trace("hgtv_cache_purged", file=f)
    except OSError:
        pass

    # 命中缓存也要校验
    if _os.path.exists(dst):
        if _verify_mp4(dst):
            return dst
        try:
            _os.remove(dst)
            _trace("hgtv_cache_invalid", episode_id=vid, quality=q)
        except OSError:
            pass

    url = _resolve_media_url(it, vm)
    if not url:
        return None

    _sa = it.get("spade_a") or (it.get("encrypt_info") or {}).get("spade_a")
    key = _content_key(_sa) if _sa else None

    # 加密档但拿不到密钥：绝不落盘（否则就是黑屏源）
    if _is_encrypted(it) and not key:
        _trace("hgtv_signed_no_key", episode_id=vid, quality=q)
        return None

    tmp = dst + ".tmp.mp4"
    req = _ureq.Request(url, headers={"User-Agent": _PLAYBACK_UA})
    _cur_th = _threading.current_thread()
    _prev_stream_flag = getattr(_cur_th, "_host_media_stream_read", False)
    _cur_th._host_media_stream_read = True
    try:
        with _ureq.urlopen(req, timeout=60) as r, open(tmp, "wb") as f:
            _total_dl = 0
            while True:
                _chunk = r.read(65536)
                if not _chunk:
                    break
                _total_dl += len(_chunk)
                if _total_dl > 32 * 1024 * 1024:
                    raise ValueError("CENC MP4 exceeds 32 MB limit")
                f.write(_chunk)
    finally:
        _cur_th._host_media_stream_read = _prev_stream_flag

    ff = _ffmpeg_path()
    if key and _is_encrypted(it) and not ff:
        # 宿主没有 ffmpeg -> 纯 Python CENC 解密
        enc = dst + ".enc.mp4"
        _os.replace(tmp, enc)
        try:
            t0 = _time.time()
            _cenc_decrypt(enc, tmp, bytes.fromhex(key))
            _trace("hgtv_pure_cenc_ok", episode_id=vid, elapsed_ms=round((_time.time() - t0) * 1000))
        except Exception as e:
            _trace("hgtv_pure_cenc_failed", episode_id=vid, err=str(e)[:140])
            try:
                _os.remove(enc)
            except OSError:
                pass
            return None
        try:
            _os.remove(enc)
        except OSError:
            pass
    if key and _is_encrypted(it) and ff:
        enc = dst + ".enc.mp4"
        _os.replace(tmp, enc)
        try:
            pr = _subprocess.run([ff, "-y", "-v", "error", "-decryption_key", key,
                                  "-i", enc, "-c", "copy", "-movflags", "+faststart",
                                  "-f", "mp4", tmp], capture_output=True, text=True, timeout=600)
        except Exception as e:
            _trace("hgtv_ffmpeg_exec_failed", episode_id=vid, err=str(e)[:120])
            try:
                _os.remove(enc)
            except OSError:
                pass
            return None
        try:
            _os.remove(enc)
        except OSError:
            pass
        if pr.returncode != 0 or not _os.path.exists(tmp):
            _trace("hgtv_signed_decrypt_failed", episode_id=vid, err=(pr.stderr or "")[:160])
            return None

    # 可选：HEVC -> H.264（老播放器黑屏时用 HGTV_TRANSCODE=1）
    if _os.environ.get("HGTV_TRANSCODE") == "1" and ff:
        h264 = dst + ".h264.mp4"
        t0 = _time.time()
        if _transcode_h264(ff, tmp, h264):
            _os.replace(h264, tmp)
            _trace("hgtv_transcoded", episode_id=vid, elapsed_ms=round((_time.time() - t0) * 1000))
        else:
            try:
                _os.remove(h264)
            except OSError:
                pass

    if not _verify_mp4(tmp):
        _trace("hgtv_signed_verify_failed", episode_id=vid, quality=q)
        try:
            _os.remove(tmp)
        except OSError:
            pass
        return None

    _os.replace(tmp, dst)
    return dst


class _DecHandler(_BHTTPH):
    def log_message(self, fmt, *a):
        pass

    def do_GET(self):
        m = _re.match(r"^/play/(\d+)", self.path)
        if not m:
            self.send_response(404)
            self.end_headers()
            return
        vid = m.group(1)
        qm = _re.search(r"[?&]q=([0-9]+p)", self.path)
        q = qm.group(1) if qm else None
        try:
            fp = _decrypt_to_file(vid, q)
        except Exception as e:
            _trace("hgtv_signed_decrypt_error", vid=vid, err=str(e)[:120])
            fp = None
        if not fp:
            self.send_response(404)
            self.end_headers()
            return
        size = _os.path.getsize(fp)
        start, end, code = 0, size - 1, 200
        rng = self.headers.get("Range")
        if rng:
            mm = _re.match(r"bytes=(\d*)-(\d*)", rng)
            if mm:
                if mm.group(1):
                    start = int(mm.group(1))
                if mm.group(2):
                    end = min(int(mm.group(2)), size - 1)
                code = 206
        length = end - start + 1
        self.send_response(code)
        self.send_header("Content-Type", "video/mp4")
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("Content-Length", str(length))
        if code == 206:
            self.send_header("Content-Range", "bytes %d-%d/%d" % (start, end, size))
        self.end_headers()
        try:
            with open(fp, "rb") as f:
                f.seek(start)
                left = length
                while left > 0:
                    chunk = f.read(min(262144, left))
                    if not chunk:
                        break
                    self.wfile.write(chunk)
                    left -= len(chunk)
        except (BrokenPipeError, ConnectionResetError):
            pass


def ensure_signed_service():
    """本地解密服务（懒启动）；端口被占（如宿主 relay）时自动顺延。"""
    global _DEC_SRV, _DEC_PORT
    if _DEC_SRV is not None:
        return True
    base = _DEC_PORT
    for port in (base, base + 1, base + 2, base + 3):
        try:
            srv = _THS(("127.0.0.1", port), _DecHandler)
        except OSError as e:
            _trace("hgtv_signed_service_port_busy", port=port, err=str(e)[:60])
            continue
        _DEC_SRV = srv
        _DEC_PORT = port
        _threading.Thread(target=srv.serve_forever, daemon=True).start()
        _trace("hgtv_signed_service_started", port=port)
        return True
    return False


def resolve_signed(sid, vid, preview=False, host_proxy=False, want=None):
    """无公开档时走签名接口；宿主模式延迟到代理请求时下载和解密。"""
    if host_proxy:
        vm = _signed_model(vid)
        if not vm:
            raise SourceError("签名接口未返回该集数据", stage="resolve_api", code="provider_signed_unavailable", retryable=False)
        selected = _pick_best(vm, want or ("360p" if preview else None))
        if not selected:
            raise SourceError("签名接口没有可播放画质", stage="resolve_api", code="provider_video_unavailable", retryable=False)
        _item, quality = selected
        _trace("hgtv_signed_queued", episode_id=vid, quality=quality)
        return ("cenc://%s?q=%s" % (vid, quality), ORIGIN + "/", None)
    if not ensure_signed_service():
        raise SourceError("本地解密服务启动失败", stage="resolve_api", code="signed_service_unavailable", retryable=False)
    vm = _signed_model(vid)
    if not vm:
        raise SourceError("签名接口未返回该集数据", stage="resolve_api", code="provider_signed_unavailable", retryable=False)
    # 同步解密：否则后面的 probe 会因 127.0.0.1 还在下载/解密而超时
    t0 = _time.time()
    fp = _decrypt_to_file(vid, None)
    if not fp:
        raise SourceError("加密档解密失败（缺 ffmpeg 或编码不支持）",
                          stage="resolve_api", code="signed_decrypt_failed", retryable=False)
    _trace("hgtv_signed_ready", episode_id=vid, elapsed_ms=round((_time.time() - t0) * 1000))
    return ("http://127.0.0.1:%d/play/%s" % (_DEC_PORT, vid), ORIGIN + "/", None)

########## 签名取流 END ##########


class Spider:
    def __init__(self, http=None):
        self.http = http or _SHARED_HTTP
        self.catalog = Catalog(self.http)
        self.cache = self.http.cache
        self.extend = ''
        self._warm_key = object()

    def init(self, extend=''):
        self.extend = extend or ''
        data_dir = getattr(self, '_cctvhost_data_dir', '')
        if data_dir:
            global _DEC_DIR
            _DEC_DIR = _os.path.join(_os.path.realpath(data_dir), 'hgtv-python-cache')
        _trace('hgtv_init')

    def homeContent(self, filter=False):
        return {'class': [{'type_id': item['id'], 'type_name': item['title']} for item in self.catalog.categories()], 'filters': {}}

    def homeVideoContent(self):
        try:
            return {'list': [_card(item) for item in self.catalog.home()['items']]}
        except Exception as error:
            return {'list': [], 'msg': str(error)}

    def categoryContent(self, tid, pg, filter=False, extend=None):
        try:
            topic = (extend or {}).get('topic') if isinstance(extend, dict) else None
            data = self.catalog.category(str(tid), pg, topic)
            return {'list': [_card(item) for item in data['items']], 'page': data['page'], 'pagecount': data['pagecount'], 'limit': 24, 'total': data['total'] if data['total'] is not None else len(data['items']), 'total_known': data['total'] is not None, 'pagination_known': data['pagination_known'], 'selectors': data['selectors']}
        except Exception as error:
            return {'list': [], 'page': 1, 'pagecount': 1, 'limit': 24, 'total': 0, 'msg': str(error)}

    def detailContent(self, ids):
        try:
            sid = ids[0] if isinstance(ids, (list, tuple)) and ids else ids
            if isinstance(sid, (list, tuple)) or not _identifier(sid):
                raise SourceError('影片 ID 无效')
            data = self.catalog.detail(sid)
            entries = '#'.join('%s$%s~%s' % (_label(episode['title']), data['id'], episode['id']) for episode in data['episodes'])
            movie = _card(data)
            movie.update({'vod_content': data['description'], 'vod_play_from': '官网完整播放$$$公开试看（片段）', 'vod_play_url': entries + '$$$' + entries, 'catalog_complete': data['catalog_complete'], 'episode_count': data['episode_count'], 'playback_verified': False})
            return {'list': [movie]}
        except Exception as error:
            return {'list': [], 'msg': str(error)}

    def _warm_search(self):
        def warm():
            failures = []
            with ThreadPoolExecutor(max_workers=3) as pool:
                calls = [pool.submit(self.catalog.home)] + [pool.submit(self.catalog.category, item['id'], 1) for item in self.catalog.categories()]
                for call in calls:
                    try: call.result()
                    except Exception as error: failures.append(str(error))
            if failures:
                raise SourceError('部分公开目录暂未加载；本地搜索结果可能不完整')
            return True
        self.cache.load(('search-warm', self._warm_key), warm, 300, wait_timeout=45)

    def searchContent(self, key, quick=False, pg='1'):
        try:
            page = _page_number(pg)
            if not isinstance(key, str) or len(key) > 200:
                raise SourceError('搜索词无效或过长')
            warning = ''
            if key.strip():
                try: self._warm_search()
                except SourceError as error: warning = str(error)
            data = self.catalog.search(key, page)
            result = {'list': [_card(item) for item in data['items']], 'page': data['page'], 'pagecount': data['pagecount'], 'limit': 24, 'total': data['total'], 'scope': data['scope'], 'msg': data['scope_description']}
            if warning: result['msg'] = warning + '；' + result['msg']
            return result
        except Exception as error:
            return {'list': [], 'page': 1, 'pagecount': 1, 'total': 0, 'msg': str(error)}

    def localProxy(self, params):
        """Host-managed decrypted MP4 response with byte-range support."""
        if not isinstance(params, dict):
            return [400, {'Content-Type': 'text/plain; charset=utf-8'}, b'invalid proxy parameters']
        try:
            request_url = urlsplit(str(params.get('url') or ''))
            if request_url.scheme.lower() != 'cenc':
                return [400, {'Content-Type': 'text/plain; charset=utf-8'}, b'unsupported media scheme']
            vid = (request_url.netloc + request_url.path).strip('/')
            if not _identifier(vid):
                return [404, {'Content-Type': 'text/plain; charset=utf-8'}, b'unknown episode']
            values = parse_qs(request_url.query, keep_blank_values=False)
            quality = (values.get('q') or [None])[0]
            if quality is not None and quality not in _QORDER and not _re.fullmatch(r'[0-9]{1,3}', quality):
                return [400, {'Content-Type': 'text/plain; charset=utf-8'}, b'invalid quality']
            method = str(params.get('method') or 'GET').upper()
            if method not in ('GET', 'HEAD'):
                return [405, {'Allow': 'GET, HEAD'}, b'']
            fp = _decrypt_to_file(vid, quality)
            if not fp or not _verify_mp4(fp):
                return [502, {'Content-Type': 'text/plain; charset=utf-8'}, b'media download or CENC decryption failed']
            size = _os.path.getsize(fp)
            if size <= 0:
                return [502, {'Content-Type': 'text/plain; charset=utf-8'}, b'decrypted media is empty']
            request_headers = params.get('headers') if isinstance(params.get('headers'), dict) else {}
            range_value = str(params.get('range') or request_headers.get('Range') or '').strip()
            start, end, partial = 0, size - 1, False
            if range_value:
                match = _re.fullmatch(r'bytes=(\d*)-(\d*)', range_value, _re.I)
                if not match or ',' in range_value:
                    return [416, {'Content-Range': 'bytes */%d' % size,
                                  'Accept-Ranges': 'bytes', 'Content-Type': 'video/mp4'}, b'']
                left, right = match.groups()
                if not left and not right:
                    return [416, {'Content-Range': 'bytes */%d' % size,
                                  'Accept-Ranges': 'bytes', 'Content-Type': 'video/mp4'}, b'']
                if left:
                    start = int(left)
                    end = min(int(right), size - 1) if right else size - 1
                else:
                    suffix = int(right)
                    if suffix <= 0:
                        return [416, {'Content-Range': 'bytes */%d' % size,
                                      'Accept-Ranges': 'bytes', 'Content-Type': 'video/mp4'}, b'']
                    start = max(0, size - suffix)
                if start >= size or end < start:
                    return [416, {'Content-Range': 'bytes */%d' % size,
                                  'Accept-Ranges': 'bytes', 'Content-Type': 'video/mp4'}, b'']
                partial = True
            length = end - start + 1
            if length > 16 * 1024 * 1024 and not getattr(self, '_cctvhost_file_proxy_supported', False):
                return [413, {'Content-Type': 'text/plain; charset=utf-8'},
                        b'request a smaller byte range']
            headers = {'Content-Type': 'video/mp4', 'Accept-Ranges': 'bytes',
                       'Content-Length': str(length)}
            if partial:
                headers['Content-Range'] = 'bytes %d-%d/%d' % (start, end, size)
            if getattr(self, '_cctvhost_file_proxy_supported', False):
                return [206 if partial else 200, headers,
                        {'__cctvhostFileResponse': True, 'path': _os.path.realpath(fp),
                         'offset': start, 'length': length}]
            if method == 'HEAD':
                body = b''
            else:
                with open(fp, 'rb') as media_file:
                    media_file.seek(start)
                    body = media_file.read(length)
                if len(body) != length:
                    return [502, {'Content-Type': 'text/plain; charset=utf-8'}, b'decrypted media cache is truncated']
            return [206 if partial else 200, headers, body]
        except Exception as error:
            _trace('hgtv_proxy_failed', episode_id='')
            return [502, {'Content-Type': 'text/plain; charset=utf-8'},
                    ('media proxy failed: ' + type(error).__name__).encode('utf-8')]

    def playerContent(self, flag, id, vipFlags=None):
        preview = '试看' in str(flag) or 'preview' in str(flag).lower()
        started, sid, vid = time.monotonic(), '', ''
        empty = {'parse': 0, 'playUrl': '', 'url': '', 'header': {}, 'format': 'video/mp4',
                 'contentType': 'video/mp4', 'preview': preview, 'playback_verified': False,
                 'source_version': VERSION, 'failure_stage': '', 'error_code': '', 'retryable': False}
        try:
            parts = str(id or '').strip().split('~')
            if len(parts) == 1:
                sid, vid = '', parts[0]
            elif len(parts) == 2:
                sid, vid = parts
                if not _identifier(sid): raise SourceError('剧 ID 无效', stage='validate_input', code='invalid_series_id')
            else:
                raise SourceError('选集 ID 无效', stage='validate_input', code='invalid_episode_id')
            if not _identifier(vid): raise SourceError('选集 ID 无效', stage='validate_input', code='invalid_episode_id')
            _trace('hgtv_play_start', series_id=sid, episode_id=vid, preview=preview)
            def resolve_public():
                if preview:
                    url, referer, expiry = ORIGIN + '/video/public/' + vid + '/360p.mp4', ORIGIN + '/', None
                    try:
                        self.http.probe(url, {'User-Agent': UA_WEB, 'Referer': ORIGIN + '/'})
                    except Exception:
                        raise SourceError('本集没有公开试看片段，请选择官网完整播放',
                                          stage='resolve_api', code='public_preview_unavailable')
                else:
                    try:
                        url, referer, expiry = resolve_signed(sid, vid, False,
                            host_proxy=bool(getattr(self, '_cctvhost_proxy_url', '')))
                        _trace('hgtv_play_signed_resolved', series_id=sid, episode_id=vid)
                    except Exception as error:
                        try:
                            url, referer, expiry = self.http.compat(sid, vid)
                        except Exception:
                            raise _stage_error(error, 'resolve_api', 'provider_request_failed')
                playback_headers = ({} if url.startswith('cenc://') else
                    {'User-Agent': UA_WEB, 'Referer': referer, 'Accept': '*/*', 'Accept-Encoding': 'identity'})
                preflight_error = None
                if url.startswith(('http://127.0.0.1', 'cenc://')):
                    # 本地解密流：不走 probe（inspect_mp4 对 CENC 解出的 AAC 帧校验过严，
                    # 且服务端已保证是完整 mp4；直接交给播放器，失败时它自己会重试）
                    info = {'duration': None, 'initialization_complete': False}
                else:
                  try:
                    info = self.http.probe(url, playback_headers)
                  except Exception as error:
                    error = _stage_error(error, 'media_probe', 'media_initialization_failed')
                    transient = error.status in (408, 425, 429) or error.status >= 500 or (
                        error.status == 0 and error.code in ('network_error', 'request_timeout', 'probe_timeout'))
                    if preview or not error.retryable or not transient:
                        raise error
                    # A normal compatibility API URL has already been obtained.
                    # A temporary probe failure must not discard it before the
                    # native player can make its own request. Nothing is marked
                    # as initialized or decoded, and this result is not cached.
                    preflight_error = error
                    info = {'duration': None, 'initialization_complete': False}
                    _trace('hgtv_preflight_deferred', series_id=sid, episode_id=vid, preview=False,
                           status=error.status, failure_stage='media_probe', error_code=error.code,
                           retryable=True, elapsed_ms=round((time.monotonic() - started) * 1000))
                if expiry is not None and expiry <= time.time() + 2:
                    raise SourceError('播放地址在预检期间过期，请重试', stage='media_probe', code='media_url_expired', retryable=True)
                result = dict(empty, url=url, header=playback_headers, status=200,
                            series_id=sid, episode_id=vid, expires_at=expiry, duration=info['duration'],
                            initialization_complete=info.get('initialization_complete', False),
                            video_codecs=info.get('video_codecs', []),
                            video_dimensions=info.get('video_dimensions', []),
                            verification='signed-cenc-local-proxy' if url.startswith('cenc://') else 'mp4-video-initialization-only',
                            msg='公开试看片段，非整集' if preview else '官网兼容播放；已检查视频轨初始化，未验证客户端完整解码/播放')
                if url.startswith('cenc://'):
                    vm = _signed_model(vid)
                    alternatives = []
                    for quality in _QORDER:
                        if _pick_best(vm, quality):
                            alternatives.append({'name': quality, 'url': 'cenc://%s?q=%s' % (vid, quality),
                                                 'proxy': 1, 'format': 'mp4', 'contentType': 'video/mp4'})
                    result.update(proxy=1, alternates=alternatives,
                                  msg='已解析完整视频；默认最高可用画质，解码结果由播放器确认')
                if preflight_error:
                    result.update(verification='compatibility-api-only',
                                  preflight_warning=_public_error_message(preflight_error),
                                  preflight_failure_stage='media_probe', preflight_code=preflight_error.code,
                                  preflight_status=preflight_error.status,
                                  msg='已取得官网兼容地址；媒体预检暂时失败，交给播放器继续请求，尚未确认视频轨')
                return result
            ttl = lambda result: 0 if result.get('verification') == 'compatibility-api-only' else (
                10 if preview else max(0, min(10, result['expires_at'] - time.time() - 2)) if result.get('expires_at') else 0)
            # Resolution can use an 18s API budget plus a 20s media probe. A
            # concurrent caller must not time out before that owner can finish.
            result = copy.deepcopy(self.cache.load(('play', preview, sid, vid), resolve_public, ttl, wait_timeout=45))
            _trace('hgtv_play_resolved', series_id=sid, episode_id=vid, preview=preview,
                   status=200, failure_stage='', error_code='', retryable=False,
                   elapsed_ms=round((time.monotonic() - started) * 1000))
            return result
        except Exception as error:
            error = _stage_error(error, 'validate_input' if not _identifier(vid) else 'playback', 'playback_failed')
            safe_sid, safe_vid = _identifier(sid) or '', _identifier(vid) or ''
            # The actual host reads msg but discards extra error fields. Include
            # essential context there as well as in structured, URL-free logs.
            context = 'HGTV %s · %s · 剧 %s · 集 %s · HTTP %s' % (
                VERSION, error.stage, safe_sid or '-', safe_vid or '-', error.status or '-')
            message = _public_error_message(error)
            _trace('hgtv_play_failed', series_id=safe_sid, episode_id=safe_vid, preview=preview,
                   status=error.status, failure_stage=error.stage, error_code=error.code,
                   retryable=error.retryable, elapsed_ms=round((time.monotonic() - started) * 1000))
            return dict(empty, msg=message + ' [' + context + ']', status=error.status,
                        series_id=safe_sid, episode_id=safe_vid, failure_stage=error.stage,
                        error_code=error.code, retryable=error.retryable)


def _cli(argv=None):
    parser = argparse.ArgumentParser(description='HGTV 公开/官网兼容版；不包含受保护媒体处理')
    subs = parser.add_subparsers(dest='command')
    test = subs.add_parser('selftest', help='检查目录和地址/文件头，不代表完整解码')
    test.add_argument('--series', default='7690961604636052505')
    test.add_argument('--all', action='store_true', help='逐集检查；任一集不可用就返回非零')
    detail_cmd = subs.add_parser('detail')
    detail_cmd.add_argument('series')
    search_cmd = subs.add_parser('search')
    search_cmd.add_argument('keyword')
    search_cmd.add_argument('--page', default='1')
    play_cmd = subs.add_parser('play')
    play_cmd.add_argument('episode', help='视频 ID 或 剧ID~视频ID')
    play_cmd.add_argument('--preview', action='store_true')
    args = parser.parse_args(argv)
    sp = Spider()
    command = args.command or 'selftest'
    if command == 'search':
        data = sp.searchContent(args.keyword, pg=args.page)
        print(json.dumps(data, ensure_ascii=False, indent=2))
        return 1 if not data['list'] else 0
    if command == 'detail':
        data = sp.detailContent([args.series])
        print(json.dumps(data, ensure_ascii=False, indent=2))
        return 0 if data['list'] else 1
    if command == 'play':
        data = sp.playerContent('preview' if args.preview else 'full', args.episode)
        print(json.dumps(data, ensure_ascii=False, indent=2))
        return 0 if data['url'] else 1
    sid = getattr(args, 'series', '7690961604636052505')
    result = {'version': VERSION, 'scope': '目录、地址和 MP4 初始化；不代表完整播放或全集播放验证', 'full_playback_verified': False, 'all_episodes_playback_verified': False}
    try:
        data = sp.catalog.detail(sid)
        targets = data['episodes'] if getattr(args, 'all', False) else data['episodes'][:1]
        if len(targets) > 500:
            raise SourceError('单次自检最多检查 500 集，请按需逐集使用 play')
        def inspect_episode(episode):
            r = sp.playerContent('full', data['id'] + '~' + episode['id'])
            return {'episode': episode['number'], 'available': bool(r['url']), 'duration': r.get('duration'),
                    'initialization_complete': r.get('initialization_complete', False),
                    'video_codecs': r.get('video_codecs', []), 'video_dimensions': r.get('video_dimensions', []),
                    'preflight_code': r.get('preflight_code', ''), 'preflight_status': r.get('preflight_status'),
                    'message': r.get('msg'), 'status': r.get('status', 200)}
        if getattr(args, 'all', False):
            with ThreadPoolExecutor(max_workers=3) as pool:
                rows = list(pool.map(inspect_episode, targets))
        else:
            rows = [inspect_episode(episode) for episode in targets]
        result.update(catalogue_count=data['episode_count'], catalogue_complete=data['catalog_complete'], checked_count=len(rows), episodes=rows)
        passed = bool(rows) and data['catalog_complete'] is not False and all(
            row['available'] and row['initialization_complete'] for row in rows)
    except Exception as error:
        result['error'], passed = str(error), False
    print(json.dumps(result, ensure_ascii=False, indent=2))
    return 0 if passed else 1

if __name__ == '__main__':
    raise SystemExit(_cli())
