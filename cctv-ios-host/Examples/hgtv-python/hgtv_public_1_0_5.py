# -*- coding: utf-8 -*-
"""HGTV 1.0.5 source adapted for CCTVHost's Python Spider and media proxy."""
import argparse
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

VERSION = '1.0.5-cctvhost'
ORIGIN = 'https://hongguoduanju.com'
COMPAT_PATH = '/api/video/protected/fallback-play-info'
UA_WEB = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36'

_TRACE_LOCK = threading.RLock()

def _trace(event, **fields):
    # CCTVHost retains stderr even when it replaces a source's empty result
    # with NO_MEDIA. Never include media URLs, headers, cookies or error bodies.
    allowed = ('series_id', 'episode_id', 'preview', 'status', 'failure_stage',
               'error_code', 'retryable', 'elapsed_ms')
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
        payload = data.get('category_$')
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
        keys = {"home": ("page",), "category": ("category_$",),
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
        data = self._route(path, "category")
        if not any(isinstance(data.get(key), list) for key in ("recommendList", "video_list", "videoList", "list")):
            raise CatalogError("site category catalogue structure has changed")
        items = _movies(_array(data, "recommendList", "video_list", "videoList", "list"))
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



########## 签名取流 + CENC 解密（解决 public_fallback_unavailable） ##########
# 背景：/api/video/protected/fallback-play-info 只对「有公开档」的集返回 200，
#       新剧很多返回 {"error":"public_fallback_unavailable"}（HTTP 403）。
# 兜底：走 App 的 multi_video_model（需 x-gorgon 等四个签名头），拿到加密档后
#       用 spade 解 URL、派生 CENC 密钥、ffmpeg 解密，再由本地 HTTP 提供流。
import base64 as _b64
import binascii as _binascii
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
from http.server import BaseHTTPRequestHandler as _BHTTPH, ThreadingHTTPServer as _THS

_SIGN_API = "https://api5-normal-sinfonlineb.fqnovel.com/novel/player/multi_video_model/v1/"
_SIGN_UA = ("com.phoenix.read/74132 (iPhone; iOS 27.0.1; zh_CN; iPhone 12; Build/21A342)")
_SIGN_DEVICE = {
    "device_id": "780019670991881", "user_id": "3594769438086775", "aid": "8662",
    "app_name": "novelread", "version_code": "74132", "version_name": "7.4.1.32",
    "manifest_version_code": "74132", "update_version_code": "74132",
    "device_platform": "iphone", "os": "ios", "os_version": "27.0.1", "os_api": "27",
    "device_type": "iPhone 12", "device_brand": "Apple", "language": "zh",
    "resolution": "1170*2532", "dpi": "460", "host_abi": "arm64",
    "channel": "App Store", "ac": "wifi", "ssmix": "a", "pv_player": "74132",
    "compliance_status": "0", "need_personal_recommend": "1", "player_so_load": "1",
}
_SPADE_CONST = _binascii.unhexlify(
    "4dd4c2e6b83162090e52b3c7a6733ba41cb2462b829ab58a196b39db57177524"
    "f49baf7f08e8d68d26a72e37c1a95a2f1f05a51892aef2949732b62a38aadd58"
)
_SIGN_CACHE = {}
_SIGN_CACHE_TTL = 300
_DEC_DIR = _os.path.join(_os.path.dirname(_os.path.abspath(__file__)), "decrypt_cache")
_DEC_SRV = None
_DEC_PORT = int(_os.environ.get("HGTV_DEC_PORT", "8789"))
_QORDER = ["1080p", "720p", "540p", "480p", "360p"]


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


def _rc4(data, key):
    s = list(range(256))
    j = 0
    for i in range(256):
        j = (j + s[i] + key[i % len(key)]) & 0xFF
        s[i], s[j] = s[j], s[i]
    out = bytearray()
    i = j = 0
    for v in data:
        i = (i + 1) & 0xFF
        x = s[i]
        j = (j + x) & 0xFF
        y = s[j]
        s[i] = y
        out.append(v ^ s[(y + y) & 0xFF])
    return bytes(out)


def _x_gorgon(query, body, ts, rnd):
    sdk = (67503104).to_bytes(4, "little")
    payload = _md5_bytes(query)[:4] + (_md5_bytes(body)[:4] if body else b"\0" * 4) \
        + b"\0" * 4 + sdk + _be32(ts)
    key = [0x4A, 0x40, 0x16, (rnd >> 8) & 0xFF, 0x47, 0x6C, 0x01, rnd & 0xFF]
    out = bytearray(_rc4(payload, key))
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
    rnd = _random.randint(0, 0xFFFFFFFF)
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


def _sm3(b):
    if isinstance(b, str):
        b = b.encode()
    h = _hashlib.new("sm3")
    h.update(b)
    return h.digest()


def _branch_of(url, body, ts):
    q = _sm3(url.split("?", 1)[1].encode())
    bm = _md5_bytes(body) if body else b"\0" * 16
    iv = _get_iv(_get_iv(_get_iv(0x20230928, q), bm), _le32(ts))
    low = iv & 15
    return low - ((low * 171) >> 9) * 3


def _pct(s):
    return "".join(
        c if (c.isalnum() or c in "-_.~") else "%%%02X" % ord(c) for c in str(s))


def _signed_request(payload):
    ts = int(_time.time())
    body = payload.encode() if isinstance(payload, str) else payload
    rnd = _random.randint(0, 65535)
    vals = dict(_SIGN_DEVICE)
    vals["ts"] = str(ts)
    base = int(_time.time() * 1000)
    for off in range(32):
        vals["_rticket"] = str(base + off)
        query = "&".join("%s=%s" % (_pct(k), _pct(v)) for k, v in vals.items())
        url = _SIGN_API + "?" + query
        if _branch_of(url, body, ts) != 1:
            break
    headers = {
        "User-Agent": _SIGN_UA,
        "Accept": "application/json; charset=utf-8,application/x-protobuf",
        "Content-Type": "application/json; charset=UTF-8",
        "x-xs-from-web": "0",
        "x-ss-req-ticket": vals["_rticket"],
        "x-tt-request-tag": "t=0;n=0",
        "sdk-version": "2",
        "passport-sdk-version": "50561",
        "x-vc-bdturing-sdk-version": "3.7.2.cn",
        "x-ss-stub": _md5_bytes(body).hex().upper(),
        "x-gorgon": _x_gorgon(query, body, ts, rnd),
        "x-khronos": str(ts),
        "x-ladon": _b64.b64encode(_be32(ts)).decode(),
        "x-argus": _b64.b64encode(_le32(ts)).decode(),
        "x-helios": _helios(ts),
        "x-tt-dt": "",
    }
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


def _signed_model(vid):
    """签名取 video_model（带 5 分钟缓存）。"""
    ent = _SIGN_CACHE.get(str(vid))
    if ent and _time.time() - ent[0] < _SIGN_CACHE_TTL:
        return ent[1]
    payload = _json.dumps({
        "biz_param": {"detail_page_version": 0, "device_level": 3,
                      "disable_digg_stat": False, "need_all_video_definition": True,
                      "need_mp4_align": False, "use_os_player": False,
                      "use_server_dns": False, "video_platform": 1024},
        "mixed_video_id_map": {"1004": [str(vid)]},
    }, separators=(",", ":"))
    payload_url, headers, body = _signed_request(payload)
    j = None
    last_err = None
    for attempt in (0, 1):
        try:
            req = _ureq.Request(payload_url, data=body, headers=headers, method="POST")
            with _ureq.urlopen(req, timeout=25) as r:
                j = _json.loads(r.read().decode("utf-8", "replace"))
            break
        except Exception as e:
            last_err = e
            if attempt == 0:
                _time.sleep(0.6)
                # 重签一次（时间戳/rticket 可能刚好卡边界）
                payload_url, headers, body = _signed_request(payload)
    if j is None:
        _trace("hgtv_signed_model_error", episode_id=vid, err=str(last_err)[:160])
        return None
    if j.get("code") not in (0, None):
        _trace("hgtv_signed_rejected", episode_id=vid, code=j.get("code"),
               msg=str(j.get("message") or j.get("Message") or "")[:80])
        return None
    ent = (j.get("data") or {}).get(str(vid)) or {}
    vm = ent.get("video_model")
    if isinstance(vm, str):
        vm = _json.loads(vm)
    if not isinstance(vm, dict):
        return None
    lst = vm.get("video_list")
    if isinstance(lst, list):
        vm["video_list"] = {str(x.get("definition") or i): x for i, x in enumerate(lst)}
    _SIGN_CACHE[str(vid)] = (_time.time(), vm)
    return vm


def _pick_best(vm, want):
    """挑可解的最高档（bvc2 排后）。"""
    vl = (vm or {}).get("video_list") or {}
    cands = []
    for k, it in vl.items():
        q = str(it.get("definition") or k)
        gear = str(it.get("gear_des_key") or "")
        bad = 1 if ("bytevc2" in gear or "bvc2" in gear) else 0
        order = _QORDER.index(q) if q in _QORDER else 99
        cands.append((bad, order, q, it))
    if not cands:
        return None
    cands.sort(key=lambda x: (x[0], x[1]))
    if want:
        for c in cands:
            if c[2] == want and c[0] == 0:
                return c[3], c[2]
    return cands[0][3], cands[0][2]


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
            header[pos - 4:pos] = b"free"
            for i in range(pos, end):
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


def _hevc_compat_level(width, height):
    """Return a safe ≤60 fps HEVC level for the coded dimensions.

    HGTV's encrypted streams commonly label 360x640 video as level 6.2.
    That can exceed iPhone hardware decoder limits despite the tiny picture
    and make AVFoundation report no video track. Keep a conservative level
    that covers the picture and a 60 fps sample rate; leave larger streams
    untouched when a safe level cannot be inferred.
    """
    pixels = int(width) * int(height)
    if pixels <= 552960:       # Level 3.1: 33.18 Mpixel/s
        return 93
    if pixels <= 2228224:      # Level 4.1: 133.69 Mpixel/s
        return 123
    if pixels <= 8912896:      # Level 5.1: 534.77 Mpixel/s
        return 153
    return None


def _normalize_hevc_for_ios(header, moov):
    """Normalize over-reported HEVC levels and advertise the hvc1 brand.

    The CENC samples are already decrypted when this runs. We update both the
    HEVCDecoderConfigurationRecord and SPS NALUs in place, so MP4 chunk offsets
    and all media bytes remain unchanged.
    """
    entries = list(_hevc_entries(header, moov))
    if not entries:
        return
    brand = b"hvc1" if any(item[3] != "hev1" for item in entries) else b"hev1"
    ftyp = _rd_box(header, 0)
    if ftyp and ftyp["type"] == "ftyp" and ftyp["size"] >= 16:
        compatible_start = ftyp["body"] + 8
        compatible_end = ftyp["offset"] + ftyp["size"]
        compatible = [bytes(header[offset:offset + 4])
                      for offset in range(compatible_start, compatible_end - 3, 4)]
        if b"hvc1" not in compatible and b"hev1" not in compatible:
            header[ftyp["body"]:ftyp["body"] + 4] = brand

    for config, width, height, _sample_entry_type in entries:
        target = _hevc_compat_level(width, height)
        if target is None:
            continue
        record_start = config["body"]
        record_end = config["offset"] + config["size"]
        if record_end - record_start < 23:
            continue
        level_changes = 0
        if header[record_start + 12] > target:
            header[record_start + 12] = target
            level_changes += 1
        array_count = header[record_start + 22]
        pos = record_start + 23
        for _array in range(array_count):
            if pos + 3 > record_end:
                break
            nal_type = header[pos] & 0x3F
            nal_count = _struct.unpack_from(">H", header, pos + 1)[0]
            pos += 3
            for _nal in range(nal_count):
                if pos + 2 > record_end:
                    pos = record_end
                    break
                nal_length = _struct.unpack_from(">H", header, pos)[0]
                pos += 2
                nal_end = pos + nal_length
                if nal_end > record_end:
                    pos = record_end
                    break
                if nal_type == 33 and nal_length >= 15:  # SPS
                    rbsp_indices = []
                    zero_count = 0
                    for raw_index in range(pos + 2, nal_end):  # skip NAL header
                        byte = header[raw_index]
                        if zero_count >= 2 and byte == 3:  # emulation-prevention byte
                            continue
                        rbsp_indices.append(raw_index)
                        zero_count = min(2, zero_count + 1) if byte == 0 else 0
                    # general_level_idc is byte 12 of the SPS RBSP.
                    if len(rbsp_indices) > 12:
                        level_index = rbsp_indices[12]
                        if header[level_index] > target:
                            header[level_index] = target
                            level_changes += 1
                pos = nal_end
        if level_changes:
            _trace("hgtv_hevc_level_normalized", width=width, height=height,
                   target_level_idc=target, patched_fields=level_changes)


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
    _replace_fourcc(header, "encv", "hvc1")
    _replace_fourcc(header, "enca", "mp4a")
    _replace_sinf(header)
    _clear_aux_boxes(header)
    _normalize_hevc_for_ios(header, moov)
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
    """轻量校验：ftyp + moov + 至少一条 trak。防止把加密档/截断档当成成品缓存。"""
    try:
        if _os.path.getsize(path) < min_bytes:
            return False
        with open(path, "rb") as f:
            head = f.read(3 * 1024 * 1024)
        if b"ftyp" not in head[:128]:
            return False
        if b"moov" not in head:
            return False
        return head.count(b"trak") >= 1
    except OSError:
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
    it, q = _pick_best(vm, want)
    if not it:
        return None
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

    seed_s = vm.get("key_seed") or ""
    seed = _b64.b64decode(seed_s + "=" * (-len(seed_s) % 4)) if seed_s else b""
    url = it.get("main_url") or ""
    if url and not url.startswith("http") and seed:
        url = _decrypt_spade(url, seed)
    if not url:
        return None

    _sa = it.get("spade_a") or (it.get("encrypt_info") or {}).get("spade_a")
    key = _content_key(_sa) if _sa else None

    # 加密档但拿不到密钥：绝不落盘（否则就是黑屏源）
    if _is_encrypted(it) and not key:
        _trace("hgtv_signed_no_key", episode_id=vid, quality=q)
        return None

    tmp = dst + ".tmp.mp4"
    req = _ureq.Request(url, headers={"User-Agent": _SIGN_UA})
    with _ureq.urlopen(req, timeout=180) as r, open(tmp, "wb") as f:
        _shutil.copyfileobj(r, f)

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
        _trace("hgtv_signed_queued", episode_id=vid)
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
            if length > 16 * 1024 * 1024:
                return [413, {'Content-Type': 'text/plain; charset=utf-8'},
                        b'request a smaller byte range']
            headers = {'Content-Type': 'video/mp4', 'Accept-Ranges': 'bytes',
                       'Content-Length': str(length)}
            if partial:
                headers['Content-Range'] = 'bytes %d-%d/%d' % (start, end, size)
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
                    # 试看档同样可能不存在（public 360p 只对部分集开放）-> 不存在则走签名兜底
                    try:
                        self.http.probe(url, {'User-Agent': UA_WEB, 'Referer': ORIGIN + '/'})
                    except Exception:
                        try:
                            url, referer, expiry = resolve_signed(sid, vid, preview,
                                host_proxy=bool(getattr(self, '_cctvhost_proxy_url', '')))
                            _trace('hgtv_play_signed_fallback', series_id=sid, episode_id=vid, preview=True)
                        except Exception:
                            pass
                else:
                    try:
                        url, referer, expiry = self.http.compat(sid, vid)
                    except Exception as error:
                        # 公开档不可用（如 public_fallback_unavailable）时，走签名接口 + CENC 解密
                        try:
                            url, referer, expiry = resolve_signed(sid, vid, preview,
                                host_proxy=bool(getattr(self, '_cctvhost_proxy_url', '')))
                            _trace('hgtv_play_signed_fallback', series_id=sid, episode_id=vid)
                        except Exception as signed_error:
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
                    result.update(proxy=1, msg='签名视频已准备；首次播放会在本机解密并按需传输')
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
            _trace('hgtv_play_success', series_id=sid, episode_id=vid, preview=preview,
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
