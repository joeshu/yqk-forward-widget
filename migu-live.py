#!/usr/bin/env python3
"""Migu dynamic service 0.8.4. Standalone Python 3.10+, standard library only."""
from __future__ import annotations

# Edit only this block for protocol settings and your own credentials.
# Environment MIGU_USER_ID / MIGU_USER_TOKEN override the two account fields.
# Default Android provider settings:
ANDROID_OPTIONS = {
    "user_id": "", "token": "", "rate_type": 3,
    "hdr": True, "h265": True, "client_dispatch": True,
    "app_version": "2600037000", "app_code": "miguvideo_default_android",
    "client_channel_id": "2600037000-99000-200300220100002",
}

# Optional native provider settings:
NATIVE_SETTINGS = {
    "app_version": "2600000900",
    "client_channel": "2600037000-99000-200300220100002",
    "sign_salt": "66666601",
    "sign_suffix": "770fafdf5ba04d279a59ef1600baae98migu6666",
    "rate_type": 3,
    "user_id": "",       # Or environment MIGU_USER_ID
    "user_token": "",    # Or environment MIGU_USER_TOKEN
    "dd_keys": "0123456789",
    "dd_anonymous_word": "e",
    "dd_timestamp_index": 6,
    "dd_program_index": 2,
    "dd_tail": "0",
    "dd_suffix": "",
    "app_code": "",
}

# Bounded transport and HLS validation: migu/core.py
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from email.utils import parsedate_to_datetime
import hashlib
from http.client import HTTPException, HTTPConnection, HTTPSConnection
import json
import re
import socket
import ssl
import time
import threading
from concurrent.futures import TimeoutError as FutureTimeout, CancelledError
import unicodedata
from urllib.error import HTTPError, URLError
from urllib.parse import unquote, urljoin, urlsplit
from urllib.request import HTTPRedirectHandler, HTTPHandler, HTTPSHandler, Request, build_opener

MAX_BYTES = 8 * 1024 * 1024
MAX_LINE = 16 * 1024
CHINA = timezone(timedelta(hours=8))
RETRY_STATUS = {408, 429, 500, 502, 503, 504}
NON_ASCII_PRINTABLE = re.compile(r'[^\x20-\x7e]')



class UpdateError(ValueError):
    """Safe messages must never contain remote URLs, response bodies or tokens."""


class FetchError(UpdateError):
    def __init__(self, code, retryable=False, retry_after=None):
        super().__init__(code)
        self.code, self.retryable, self.retry_after = code, retryable, retry_after


def utcnow():
    return datetime.now(timezone.utc)


def iso(value):
    return value.astimezone(timezone.utc).isoformat(timespec="seconds")


def digest(raw):
    return hashlib.sha256(raw).hexdigest()


def clean_text(value):
    # Scan ASCII in C; only inspect Unicode categories for non-printable/non-ASCII characters.
    return not any(unicodedata.category(match[0]) in {"Cc", "Cf", "Cs"} for match in NON_ASCII_PRINTABLE.finditer(value))


def validate_url(url, role):
    """Validate catalogue URLs and every redirect against a fixed trust set."""
    if len(url) > MAX_LINE or not clean_text(url) or any(ch.isspace() for ch in url):
        raise UpdateError("URL_CONTROL_OR_WHITESPACE")
    if any(ch in url for ch in ('|', '\\', '"', '<', '>')) or not clean_text(unquote(url)):
        raise UpdateError("URL_UNSAFE_CHARACTER")
    try:
        parts = urlsplit(url)
        port = parts.port
    except ValueError:
        raise UpdateError("URL_INVALID") from None
    host = (parts.hostname or "").lower()
    if parts.scheme not in {"http", "https"} or not host or parts.username is not None or parts.password is not None or parts.fragment:
        raise UpdateError("URL_SCHEME_OR_AUTHORITY")
    if role == "catalogue":
        allowed = url in {
            "https://raw.githubusercontent.com/joeshu/yqk-forward-widget/main/migu.m3u8",
            "http://www.52top.com.cn:678/downloads/migu.txt",
        }
    elif role == "epg":
        allowed = parts.scheme == "https" and host == "program-sc.miguvideo.com" and port in {None, 443} and re.fullmatch(r"/live/v2/tv-programs-data/[0-9]{6,20}/[0-9]{8}", parts.path) is not None and not parts.query
    elif role == "api":
        allowed = parts.scheme == "https" and host == "play.miguvideo.com" and port in {None, 443} and parts.path == "/playurl/v1/play/playurl"
    elif role in {"stream", "media"}:
        # The live GSLB redirects to hlszymgsplive.miguvideo.com:8080.
        allowed_ports = {None, 80, 443, 8080} if role == "media" else {None, 80, 443}
        allowed = any(host == domain or host.endswith("." + domain) for domain in ("miguvideo.com", "cmvideo.cn")) and port in allowed_ports
        if role == "stream":
            allowed = allowed and parts.path.endswith(".m3u8")
    elif role == "logo":
        allowed = host == "wapx.cmvideo.cn" and port in {None, 80, 443, 8080}
    else:
        raise UpdateError("URL_UNKNOWN_ROLE")
    if not allowed:
        raise UpdateError("URL_HOST_OR_PORT_NOT_ALLOWED")
    return parts


@dataclass(frozen=True)
class Channel:
    id: str
    name: str
    display: str
    group: str
    logo: str
    url: str
    signed_at: datetime


class RestrictedRedirect(HTTPRedirectHandler):
    max_redirections = 4
    max_repeats = 2

    def __init__(self, role):
        self.role = role
        self.deadline = None

    def http_error_302(self, req, fp, code, msg, headers):
        # urllib's default implementation drains redirect bodies without a size limit.
        # Close instead; apply our deadline before opening each redirected connection.
        try:
            location = headers.get("Location") or headers.get("URI")
            if location is None:
                raise FetchError("REDIRECT_WITHOUT_LOCATION")
            newurl = urljoin(req.full_url, location)
            redirected = self.redirect_request(req, fp, code, msg, headers, newurl)
            if redirected is None:
                raise FetchError("REDIRECT_METHOD_NOT_ALLOWED")
            visited = dict(getattr(req, "redirect_dict", {}))
            if visited.get(newurl, 0) >= self.max_repeats or sum(visited.values()) >= self.max_redirections:
                raise FetchError("REDIRECT_LIMIT")
            visited[newurl] = visited.get(newurl, 0) + 1
            redirected.redirect_dict = visited
            remaining = self.deadline - time.monotonic() if self.deadline is not None else req.timeout
            if remaining <= 0:
                raise FetchError("FETCH_BUDGET_EXCEEDED")
        finally:
            fp.close()
        return self.parent.open(redirected, timeout=min(req.timeout, remaining))

    http_error_301 = http_error_303 = http_error_307 = http_error_308 = http_error_302

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        validate_url(newurl, self.role)
        if urlsplit(req.full_url).scheme == "https" and urlsplit(newurl).scheme != "https":
            raise FetchError("HTTPS_DOWNGRADE_BLOCKED")
        redirected = super().redirect_request(req, fp, code, msg, headers, newurl)
        if redirected is not None and urlsplit(req.full_url).netloc != urlsplit(newurl).netloc:
            for key in ("If-none-match", "If-modified-since"):
                redirected.remove_header(key)
        return redirected


def retry_delay(value):
    if not value:
        return None
    try:
        result = float(value)
        return max(0.0, result) if result < float("inf") else None
    except ValueError:
        try:
            return max(0.0, (parsedate_to_datetime(value) - utcnow()).total_seconds())
        except (ValueError, TypeError, OverflowError):
            return None


class DeadlineGuard:
    def __init__(self, deadline):
        self.deadline, self.lock, self.sockets = deadline, threading.Lock(), []
        self.expired = False
        self.timer = threading.Timer(max(0,deadline-time.monotonic()), self.abort)
        self.timer.daemon = True
        self.timer.start()

    def watch(self, sock):
        with self.lock:
            self.sockets.append(sock)
            expired = self.expired or time.monotonic() >= self.deadline
        if expired:
            self.abort()
            raise FetchError('FETCH_BUDGET_EXCEEDED')

    def abort(self):
        with self.lock:
            self.expired = True
            sockets = list(self.sockets)
        for sock in sockets:
            try: sock.shutdown(socket.SHUT_RDWR)
            except OSError: pass
            try: sock.close()
            except OSError: pass

    def close(self):
        self.timer.cancel()
        with self.lock: sockets = list(self.sockets)
        for sock in sockets:
            try: sock.close()
            except OSError: pass


class GuardedHTTPConnection(HTTPConnection):
    def __init__(self, host, guard, **kwargs):
        self.guard = guard
        super().__init__(host, **kwargs)

    def connect(self):
        super().connect()
        self.guard.watch(self.sock)


class GuardedHTTPSConnection(HTTPSConnection):
    def __init__(self, host, guard, **kwargs):
        self.guard = guard
        super().__init__(host, **kwargs)

    def _tunnel(self):
        self.guard.watch(self.sock)
        return super()._tunnel()

    def connect(self):
        super().connect()
        self.guard.watch(self.sock)


class GuardedHTTPHandler(HTTPHandler):
    def __init__(self, guard):
        super().__init__()
        self.guard = guard

    def http_open(self, request):
        return self.do_open(lambda host, **kw: GuardedHTTPConnection(host, self.guard, **kw), request)


class GuardedHTTPSHandler(HTTPSHandler):
    def __init__(self, guard):
        super().__init__()
        self.guard = guard

    def https_open(self, request):
        return self.do_open(lambda host, **kw: GuardedHTTPSConnection(host, self.guard, **kw), request, context=self._context)


_transport_lock = threading.Lock()
_transport_workers = None


def network_workers():
    global _transport_workers
    with _transport_lock:
        if _transport_workers is None:
            _transport_workers = BoundedExecutor(8, thread_name_prefix='migu-network', max_pending=24)
        return _transport_workers


class HttpClient:
    def __init__(self, role='api', attempts=1, timeout=6, budget=10):
        self.role, self.attempts, self.timeout, self.budget = role, attempts, timeout, budget
        self.last_url = None

    def _run(self, url, headers, limit, deadline):
        if time.monotonic() >= deadline:
            raise FetchError('FETCH_BUDGET_EXCEEDED')
        guard = DeadlineGuard(deadline)
        try:
            transport = BoundedTransport(self.role, self.attempts, self.timeout, self.budget, guard)
            raw, response_headers = transport.get(url, headers=headers, limit=limit, deadline=deadline)
            return raw, response_headers, transport.last_url
        finally:
            guard.close()

    def get(self, url, *, headers=None, limit=MAX_BYTES):
        validate_url(url, self.role)
        deadline = time.monotonic()+self.budget
        try:
            future = network_workers().submit(self._run, url, dict(headers or {}), limit, deadline)
        except RuntimeError:
            raise FetchError('FETCH_CAPACITY') from None
        try:
            raw, response_headers, final_url = future.result(timeout=max(0,deadline-time.monotonic()))
        except (FutureTimeout, CancelledError):
            future.cancel()
            raise FetchError('FETCH_BUDGET_EXCEEDED') from None
        except (OSError, ValueError) as failure:
            if time.monotonic() >= deadline:
                raise FetchError('FETCH_BUDGET_EXCEEDED') from None
            raise failure
        if time.monotonic() >= deadline:
            raise FetchError('FETCH_BUDGET_EXCEEDED')
        self.last_url = final_url
        return raw, response_headers


class BoundedTransport:
    def __init__(self, role, attempts, timeout, budget, guard):
        self.role, self.attempts, self.timeout, self.budget = role, attempts, timeout, budget
        self.redirector = RestrictedRedirect(role)
        self.opener = build_opener(self.redirector, GuardedHTTPHandler(guard), GuardedHTTPSHandler(guard))  # Inherit proxies and TLS trust.

    def get(self, url, *, headers=None, limit=MAX_BYTES, deadline=None):
        validate_url(url, self.role)
        self.last_url = url
        deadline = deadline if deadline is not None else time.monotonic() + self.budget
        self.redirector.deadline = deadline
        request_headers = {"User-Agent": "MiguLive/0.4", "Accept-Encoding": "identity"}
        request_headers.update(headers or {})
        for attempt in range(self.attempts):
            try:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise FetchError("FETCH_BUDGET_EXCEEDED")
                with self.opener.open(Request(url, headers=request_headers), timeout=min(self.timeout, remaining)) as response:
                    validate_url(response.geturl(), self.role)
                    self.last_url = response.geturl()
                    if response.status != 200 or response.headers.get("Content-Encoding", "identity").lower() != "identity":
                        raise FetchError("RESPONSE_STATUS_OR_ENCODING")
                    if "text/html" in response.headers.get("Content-Type", "").lower():
                        raise FetchError("RESPONSE_IS_HTML")
                    try:
                        size = int(response.headers.get("Content-Length", "0"))
                    except ValueError:
                        raise FetchError("CONTENT_LENGTH_INVALID") from None
                    if size < 0 or size > limit:
                        raise FetchError("RESPONSE_TOO_LARGE")
                    chunks, total = [], 0
                    reader = getattr(response, "read1", response.read)
                    while True:
                        if time.monotonic() >= deadline:
                            raise FetchError("FETCH_BUDGET_EXCEEDED")
                        chunk = reader(min(65536, limit + 1 - total))
                        if not chunk:
                            break
                        total += len(chunk)
                        if total > limit:
                            raise FetchError("RESPONSE_TOO_LARGE")
                        chunks.append(chunk)
                    if size and total != size:
                        raise FetchError("RESPONSE_TRUNCATED", retryable=True)
                    return b"".join(chunks), dict(response.headers)
            except HTTPError as error:
                code, after = error.code, error.headers.get("Retry-After")
                error.close()
                if code == 304:
                    return None, {}
                failure = FetchError("HTTP_" + str(code), code in RETRY_STATUS, retry_delay(after))
            except (ssl.SSLError, ssl.CertificateError):
                raise FetchError("TLS_ERROR") from None
            except (URLError, TimeoutError, socket.timeout, OSError, HTTPException) as error:
                reason = getattr(error, "reason", error)
                failure = FetchError("TLS_ERROR" if isinstance(reason, ssl.SSLError) else "NETWORK_ERROR", not isinstance(reason, ssl.SSLError))
            except FetchError as error:
                failure = error
            if not failure.retryable or attempt + 1 >= self.attempts:
                raise failure from None
            delay = failure.retry_after if failure.retry_after is not None else 2 ** attempt
            if delay > 10 or time.monotonic() + delay >= deadline:
                raise failure from None
            time.sleep(delay)
        raise FetchError("FETCH_FAILED")


def json_bytes(value):
    return (json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True) + "\n").encode("utf-8")

def hls_references(raw, base):
    try:
        text = raw.decode("utf-8-sig").replace("\r\n", "\n")
    except UnicodeError:
        raise UpdateError("HLS_NOT_UTF8") from None
    if not clean_text(text.replace("\n", "")):
        raise UpdateError("HLS_CONTROL_CHARACTER")
    lines = [line.strip() for line in text.split("\n") if line.strip()]
    if not lines or lines[0] != "#EXTM3U" or any(len(line) > MAX_LINE for line in lines):
        raise UpdateError("HLS_HEADER_INVALID")
    master = any(line.startswith("#EXT-X-STREAM-INF:") for line in lines)
    media = any(line.startswith("#EXTINF:") for line in lines)
    if master and media:
        raise UpdateError("HLS_MIXED_PLAYLIST")
    references = []
    if master:
        for index, line in enumerate(lines):
            if line.startswith("#EXT-X-STREAM-INF:"):
                if index + 1 >= len(lines) or lines[index + 1].startswith("#"):
                    raise UpdateError("HLS_VARIANT_MISSING")
                references.append(urljoin(base, lines[index + 1]))
    elif media:
        if not any(re.fullmatch(r"#EXT-X-TARGETDURATION:[1-9]\d*", line) for line in lines):
            raise UpdateError("HLS_TARGET_DURATION_MISSING")
        pending = False
        for line in lines:
            if line.startswith("#EXTINF:"):
                if pending:
                    raise UpdateError("HLS_SEGMENT_MISSING")
                try:
                    duration = float(line[len("#EXTINF:"):].split(",", 1)[0])
                except ValueError:
                    raise UpdateError("HLS_DURATION_INVALID") from None
                if not 0 < duration < float("inf"):
                    raise UpdateError("HLS_DURATION_INVALID")
                pending = True
            elif not line.startswith("#"):
                if not pending:
                    raise UpdateError("HLS_SEGMENT_WITHOUT_DURATION")
                references.append(urljoin(base, line))
                pending = False
        if pending:
            raise UpdateError("HLS_SEGMENT_MISSING")
    if not references:
        raise UpdateError("HLS_EMPTY_PLAYLIST")
    for reference in references:
        validate_url(reference, "media")
    return "master" if master else "media", references

from types import SimpleNamespace as _SharedNamespace
m = _SharedNamespace(**{key: value for key, value in globals().copy().items() if not key.startswith("__")})


# migu/workers.py
from concurrent.futures import Future
from queue import Queue, LifoQueue, Empty, Full
import threading


class BoundedExecutor:
    def __init__(self, max_workers, thread_name_prefix='migu', max_pending=8, lifo=False):
        self.max_workers, self.prefix = max_workers, thread_name_prefix
        self.queue, self.lock = (LifoQueue if lifo else Queue)(max(max_pending,max_workers)), threading.Lock()
        self.threads, self.closed = [], False

    def submit(self, function, *args, **kwargs):
        future = Future()
        with self.lock:
            if self.closed:
                raise RuntimeError('Executor already stopped')
            try:
                self.queue.put_nowait((future, function, args, kwargs))
            except Full:
                raise RuntimeError('Executor queue full') from None
            if len(self.threads) < self.max_workers:
                thread = threading.Thread(target=self._run, daemon=True, name=f'{self.prefix}-{len(self.threads)+1}')
                self.threads.append(thread)
                try:
                    thread.start()
                except BaseException:
                    self.threads.remove(thread)
                    self.closed = True
                    while True:
                        try:
                            queued = self.queue.get_nowait()
                            if queued is not None: queued[0].cancel()
                        except Empty: break
                    for _ in self.threads:
                        self.queue.put_nowait(None)
                    raise
        return future

    def _run(self):
        while True:
            item = self.queue.get()
            if item is None:
                return
            future, function, args, kwargs = item
            item = None
            if self.closed:
                future.cancel()
            elif future.set_running_or_notify_cancel():
                try:
                    result = function(*args, **kwargs)
                except BaseException as failure:
                    future.set_exception(failure)
                else:
                    future.set_result(result)
            # Release arguments/results before waiting for another task.
            future = function = args = kwargs = result = None
            if self.closed:
                return

    def shutdown(self, wait=False, cancel_futures=True):
        with self.lock:
            self.closed = True
            while True:
                try:
                    queued = self.queue.get_nowait()
                    if queued is not None: queued[0].cancel()
                except Empty:
                    break
            for _ in self.threads:
                self.queue.put_nowait(None)
        if wait:
            for thread in self.threads:
                if thread is not threading.current_thread():
                    thread.join()

# migu/native.py
from collections import OrderedDict
from concurrent.futures import TimeoutError as FutureTimeout
from dataclasses import dataclass, field
import hashlib
import json
import os
import re
import threading
import time
from types import MappingProxyType
from urllib.parse import parse_qs, urlsplit, urlencode


BUILTIN_CHANNELS = (
    ('608807420', 'CCTV1综合', '央视'),
    ('631780532', 'CCTV2财经', '央视'),
    ('624878271', 'CCTV3综艺', '央视'),
    ('631780421', 'CCTV4中文国际', '央视'),
    ('641886683', 'CCTV5体育', '央视'),
    ('641886773', 'CCTV5+体育赛事', '央视'),
    ('624878396', 'CCTV6电影', '央视'),
    ('673168121', 'CCTV7国防军事', '央视'),
    ('624878356', 'CCTV8电视剧', '央视'),
    ('673168140', 'CCTV9纪录', '央视'),
    ('624878405', 'CCTV10科教', '央视'),
    ('667987558', 'CCTV11戏曲', '央视'),
    ('673168185', 'CCTV12社会与法', '央视'),
    ('608807423', 'CCTV13新闻', '央视'),
    ('624878440', 'CCTV14少儿', '央视'),
    ('673168223', 'CCTV15音乐', '央视'),
    ('673168256', 'CCTV17农业农村', '央视'),
    ('608807419', 'CCTV4欧洲', '央视'),
    ('608807416', 'CCTV4美洲', '央视'),
    ('609006487', 'CGTN外语纪录', '央视'),
    ('609154345', 'CGTN阿拉伯语', '央视'),
    ('609006450', 'CGTN西班牙语', '央视'),
    ('609006476', 'CGTN法语', '央视'),
    ('609006446', 'CGTN俄语', '央视'),
    ('884121956', '老故事', '央视'),
    ('624878970', '发现之旅', '央视'),
    ('708869532', '中学生', '央视'),
    ('609017205', 'CGTN', '央视'),
    ('646596895', '赛事最经典', '体育'),
    ('629943305', '体坛名栏汇', '体育'),
    ('637444975', '四海钓鱼', '体育'),
    ('956909356', '陕西体育休闲频道', '体育'),
    ('915512915', '24小时城市联赛轮播台', '体育'),
    ('958475359', '武术世界', '体育'),
    ('961930263', '快乐垂钓', '体育'),
    ('651632648', '东方卫视', '卫视'),
    ('623899368', '江苏卫视', '卫视'),
    ('608831231', '广东卫视', '卫视'),
    ('630287636', '北京卫视', '卫视'),
    ('630291707', '辽宁卫视', '卫视'),
    ('962042070', '河北卫视', '卫视'),
    ('783847495', '江西卫视', '卫视'),
    ('790187291', '河南卫视', '卫视'),
    ('738910838', '陕西卫视', '卫视'),
    ('608917627', '大湾区卫视', '卫视'),
    ('947472496', '湖北卫视', '卫视'),
    ('947472500', '吉林卫视', '卫视'),
    ('947472506', '青海卫视', '卫视'),
    ('849116810', '东南卫视', '卫视'),
    ('947472502', '海南卫视', '卫视'),
    ('849119120', '海峡卫视', '卫视'),
    ('956904896', '中国农林卫视', '卫视'),
    ('956923145', '兵团卫视', '卫视'),
    ('738910535', '宁夏卫视', '卫视'),
    ('738910914', '重庆卫视', '卫视'),
    ('961023778', '三沙卫视', '卫视'),
    ('738906901', '黑龙江卫视', '卫视'),
    ('651632657', '上视新闻综合', '地方'),
    ('617290047', '上视东方影视', '地方'),
    ('608780988', '上海第一财经', '地方'),
    ('838109047', '南京新闻综合频道', '地方'),
    ('838153729', '南京教科频道', '地方'),
    ('838151753', '南京十八频道', '地方'),
    ('626064707', '体育休闲频道', '地方'),
    ('626064714', '江苏城市频道', '地方'),
    ('626064674', '江苏国际', '地方'),
    ('628008321', '江苏教育', '地方'),
    ('626064697', '江苏影视频道', '地方'),
    ('626065193', '江苏综艺频道', '地方'),
    ('626064693', '公共新闻频道', '地方'),
    ('639731825', '盐城新闻综合', '地方'),
    ('639731826', '淮安新闻综合', '地方'),
    ('639731818', '泰州新闻综合', '地方'),
    ('639731715', '连云港新闻综合', '地方'),
    ('639731832', '宿迁新闻综合', '地方'),
    ('639731747', '徐州新闻综合', '地方'),
    ('626064703', '优漫卡通频道', '地方'),
    ('955227985', '南通新闻综合', '地方'),
    ('955227996', '宜兴新闻综合', '地方'),
    ('639737327', '溧水新闻综合', '地方'),
    ('956909362', '陕西银龄频道', '地方'),
    ('956909358', '陕西都市青春频道', '地方'),
    ('956909303', '陕西秦腔频道', '地方'),
    ('956909289', '陕西新闻资讯频道', '地方'),
    ('956923159', '财富天下', '地方'),
    ('639731783', '镇江新闻综合', '地方'),
    ('962067517', '海南广播电视总台新闻频道', '地方'),
    ('962045226', '海南广播电视总台自贸频道', '地方'),
    ('962045223', '海南广播电视总台社会与法频道', '地方'),
    ('962067526', '海南广播电视总台文旅频道', '地方'),
    ('962067523', '海南广播电视总台少儿频道', '地方'),
    ('639731952', '广东珠江频道', '地方'),
    ('713600957', '建党105周年巡礼', '影视'),
    ('625703337', '经典香港电影', '影视'),
    ('619495952', '新片放映厅', '影视'),
    ('952383261', 'CHC影迷电影', '影视'),
    ('644368714', 'CHC动作电影', '影视'),
    ('644368373', 'CHC家庭影院', '影视'),
    ('713591450', '和美乡途轮播台', '影视'),
    ('614961829', '南方影视', '影视'),
    ('959986621', '中国天气', '新闻'),
    ('923287154', 'CETV1', '教育'),
    ('923287211', 'CETV2', '教育'),
    ('923287339', 'CETV4', '教育'),
    ('609154353', '山东教育', '教育'),
    ('609158151', '熊猫频道01高清', '熊猫'),
    ('608933610', '熊猫频道1', '熊猫'),
    ('608933640', '熊猫频道2', '熊猫'),
    ('608934619', '熊猫频道3', '熊猫'),
    ('608934721', '熊猫频道4', '熊猫'),
    ('608935104', '熊猫频道5', '熊猫'),
    ('608935797', '熊猫频道6', '熊猫'),
    ('609169286', '熊猫频道7', '熊猫'),
    ('609169287', '熊猫频道8', '熊猫'),
    ('609169226', '熊猫频道9', '熊猫'),
    ('609169285', '熊猫频道10', '熊猫'),
    ('629942228', '最强综艺趴', '综艺'),
    ('614952364', '嘉佳卡通', '少儿'),
    ('629942219', '经典动画大集合', '少儿'),
    ('713589837', '新动力量创一流', '纪实'),
    ('959986618', '中华特产', '纪实'),
    ('958475356', '环球旅游', '纪实'),
    ('961930369', '梨园频道', '纪实'),
)


class MiguApiError(m.FetchError):
    def __init__(self, code, details=None):
        super().__init__(code)
        self.details = {key: value for key, value in (details or {}).items()
            if key in {'channel_id','api_code','rid','auth_result','logged_in','has_play_url','returned_quality'}
            and (type(value) is bool or value is None or (isinstance(value,str) and re.fullmatch(r'[A-Z0-9_]{1,80}', value)))}


def api_status(data, pid):
    body = data.get('body') or {}
    auth, info = body.get('auth') or {}, body.get('urlInfo') or {}
    def tag(value):
        value = str(value) if value is not None else ''
        return value if re.fullmatch(r'[A-Z0-9_]{1,80}', value) else 'UNKNOWN'
    return {'channel_id': pid, 'api_code': tag(data.get('code')), 'rid': tag(data.get('rid')),
            'auth_result': tag(auth.get('authResult')), 'logged_in': auth.get('logined') if type(auth.get('logined')) is bool else None,
            'has_play_url': isinstance(info.get('url'), str) and bool(info.get('url')), 'returned_quality': tag(info.get('rateType'))}


# Editable settings are at the top of the generated single-file release.
# Protocol constants are not account entitlements. Never commit real credentials.
# NATIVE_SETTINGS is defined at the top of this file.


@dataclass(frozen=True, repr=False)
class NativeAuth:
    app_version: str
    client_channel: str
    sign_salt: str
    sign_suffix: str
    rate_type: int
    user_id: str = field(repr=False)
    user_token: str = field(repr=False)
    dd_keys: str
    dd_anonymous_word: str
    dd_timestamp_index: int
    dd_program_index: int
    dd_tail: str
    dd_suffix: str
    app_code: str

    @classmethod
    def load(cls, settings=None, environ=None):
        values = dict(NATIVE_SETTINGS if settings is None else settings)
        env = os.environ if environ is None else environ
        for key, name in (("user_id", "MIGU_USER_ID"), ("user_token", "MIGU_USER_TOKEN"),
                          ("app_version", "MIGU_APP_VERSION"),
                          ("client_channel", "MIGU_CLIENT_CHANNEL_ID"),
                          ("app_code", "MIGU_APP_CODE")):
            if name in env:
                values[key] = env[name]
        if set(values) != set(cls.__dataclass_fields__):
            raise ValueError("MIGU_CONFIG_FIELDS_INVALID")
        for key, value in values.items():
            if key in {"rate_type", "dd_timestamp_index", "dd_program_index"}:
                if type(value) is not int:
                    raise ValueError("MIGU_CONFIG_NUMBER_INVALID")
            elif not isinstance(value, str) or len(value) > 4096 or any(not 33 <= ord(c) <= 126 for c in value):
                raise ValueError("MIGU_CONFIG_TEXT_INVALID")
        if not re.fullmatch(r"[0-9]{8,12}", values['app_version']) or not re.fullmatch(r"[0-9]{1,16}", values['sign_salt']):
            raise ValueError("MIGU_CONFIG_PROTOCOL_INVALID")
        if not values['client_channel'] or not values['sign_suffix'] or values['rate_type'] not in {2,3,4}:
            raise ValueError("MIGU_CONFIG_PROTOCOL_INVALID")
        if not 0 <= values['dd_timestamp_index'] <= 13 or not 0 <= values['dd_program_index'] <= 8:
            raise ValueError("MIGU_CONFIG_PROOF_INVALID")
        if len(values['dd_keys']) != 10 or len(values['dd_anonymous_word']) != 1 or len(values['dd_tail']) != 1:
            raise ValueError("MIGU_CONFIG_PROOF_INVALID")
        if bool(values['user_id']) != bool(values['user_token']):
            raise ValueError("MIGU_CREDENTIAL_PAIR_REQUIRED")
        if values['user_id'] and not re.fullmatch(r"[0-9]{4,32}", values['user_id']):
            raise ValueError("MIGU_USER_ID_INVALID")
        if values['dd_suffix'] not in {"", "&sv=10004&ct=android"} or values['app_code'] not in {"", "miguvideo_default_android", "miguvideo_android"}:
            raise ValueError("MIGU_CONFIG_PROTOCOL_INVALID")
        return cls(**values)


def native_request(pid, auth, timestamp):
    payload = hashlib.md5((timestamp + pid + auth.app_version[:8]).encode()).hexdigest()
    signature = hashlib.md5((payload + auth.sign_suffix).encode()).hexdigest()
    endpoint = "https://play.miguvideo.com/playurl/v1/play/playurl?" + urlencode({
        "contId": pid, "rateType": 2 if pid == "608831231" and auth.app_version == "2600000900" else auth.rate_type, "timestamp": timestamp,
        "salt": auth.sign_salt, "sign": signature})
    headers = {"AppVersion": auth.app_version, "TerminalId": "android",
               "X-UP-CLIENT-CHANNEL-ID": auth.client_channel}
    if auth.app_code and pid not in {"641886683", "641886773"}:
        headers["appCode"] = auth.app_code
    if auth.user_id:
        headers.update(UserId=auth.user_id, UserToken=auth.user_token)
    return endpoint, headers


def native_proof(seed, pid, timestamp, auth, rate_type):
    if len(pid) <= auth.dd_program_index or not re.fullmatch(r"[0-9]{14}", timestamp):
        raise m.FetchError("MIGU_PLAY_URL_FORMAT_CHANGED")
    word = auth.dd_anonymous_word
    if auth.dd_keys != "0123456789" and rate_type != 2 and auth.user_id:
        word = "e" if len(auth.user_id) <= 8 else auth.dd_keys[int(auth.user_id[7])]
    extra = {1: word, 2: auth.dd_keys[int(timestamp[auth.dd_timestamp_index])],
             3: auth.dd_keys[int(pid[auth.dd_program_index])], 4: auth.dd_tail}
    proof = "".join(seed[-i-1] + seed[i] + extra.get(i, "") for i in range(len(seed)//2))
    return proof + (seed[len(seed)//2] if len(seed) % 2 else "")


def native_play_url(pid, client_factory=m.HttpClient, auth=None):
    if pid not in {item[0] for item in BUILTIN_CHANNELS}:
        raise m.FetchError("MIGU_UNKNOWN_CHANNEL")
    auth = auth or NativeAuth.load()
    endpoint, headers = native_request(pid, auth, str(int(time.time() * 1000)))
    raw, _ = client_factory("api", attempts=1, timeout=8, budget=10).get(endpoint, headers=headers, limit=256 * 1024)
    try:
        data = json.loads(raw)
        body = data.get("body") or {}
        info = body.get("urlInfo") or {}
        reason = data.get("rid", "")
        details = api_status(data, pid)
        if reason == "COPYRIGHT_AREA_INVALID":
            raise MiguApiError("MIGU_REGION_RESTRICTED", details)
        if reason == "TIPS_NEED_MEMBER":
            raise MiguApiError("MIGU_MEMBERSHIP_REQUIRED", details)
        if reason in {"NEED_LOGIN", "USER_NOT_LOGIN"}:
            raise MiguApiError("MIGU_LOGIN_REQUIRED", details)
        refusals = {"BLACK_APP_OR_TERMINAL": "MIGU_TERMINAL_BLOCKED", "COPYRIGHT_SHIELD_INVALID": "MIGU_COPYRIGHT_SHIELD", "WUDALIANSAI_FUFEI_VERSION_UPGRADE": "MIGU_CLIENT_VERSION_UPGRADE_REQUIRED"}
        if reason in refusals:
            raise MiguApiError(refusals[reason], details)
        if reason and reason != "SUCCESS":
            raise MiguApiError("MIGU_API_REJECTED", details)
        auth_result = (body.get("auth") or {}).get("authResult")
        if auth_result == "FAIL" and reason != "SUCCESS":
            raise MiguApiError("MIGU_AUTHORIZATION_REJECTED", details)
        if str(data.get("code")) != "200":
            raise MiguApiError("MIGU_API_REJECTED", details)
        url = info.get("url")
        if not isinstance(url, str) or not url:
            # No address and a failed authorization: report the real cause.
            if auth_result == "FAIL":
                raise MiguApiError("MIGU_AUTHORIZATION_REJECTED", details)
            raise MiguApiError("MIGU_PLAY_URL_MISSING", details)
        m.validate_url(url, "stream")
        content_pid = str((body.get("content") or {}).get("contId", pid))
        if content_pid != pid:
            raise m.FetchError("MIGU_CHANNEL_MISMATCH")
        query = parse_qs(urlsplit(url).query)
        # Already complete URLs are preserved byte for byte.
        if "ddCalcu" in query:
            return url
        seed = query.get("puData", [""])
        if len(seed) != 1 or re.fullmatch(r"[0-9a-fA-F]{16,128}", seed[0]) is None:
            raise m.FetchError("MIGU_PLAY_URL_FORMAT_CHANGED")
        seed = seed[0]
        try:
            returned_rate = int(info.get("rateType", auth.rate_type))
        except (TypeError, ValueError):
            raise m.FetchError("MIGU_API_FORMAT_CHANGED") from None
        if returned_rate not in {2,3,4}:
            raise m.FetchError("MIGU_API_FORMAT_CHANGED")
        timestamps = query.get("timestamp", [])
        if len(timestamps) != 1:
            raise m.FetchError("MIGU_PLAY_URL_FORMAT_CHANGED")
        proof = native_proof(seed, pid, timestamps[0], auth, returned_rate)
        return url + "&ddCalcu=" + proof + auth.dd_suffix
    except (TypeError, AttributeError, IndexError, json.JSONDecodeError):
        raise m.FetchError("MIGU_API_FORMAT_CHANGED") from None


@dataclass(frozen=True)
class NativeSnapshot:
    playlist: object
    channels: object


class NativeStore:
    """Built-in metadata; bounded, coalesced on-demand resolution, memory only."""
    provider = "migu"

    def __init__(self, resolver=native_play_url, clock=time.monotonic, auth=None):
        self.auth = auth or NativeAuth.load()
        self.resolver = (lambda pid: native_play_url(pid, auth=self.auth)) if resolver is native_play_url else resolver
        self.clock = clock
        self.pool = BoundedExecutor(max_workers=8, thread_name_prefix="migu-api")
        self.lock = threading.RLock()
        self.flights, self.entries = {}, OrderedDict()
        self.closed, self.last_error, self.fetches = False, None, 0
        self.last_upstream = None
        channels = {"p" + pid: m.Channel(name, name, name, group, "", "", m.utcnow()) for pid, name, group in BUILTIN_CHANNELS}
        self.snapshot = NativeSnapshot(None, MappingProxyType(channels))

    def get(self, wait=0):
        with self.lock:
            if self.closed:
                raise m.FetchError("SERVICE_STOPPING")
            return self.snapshot

    def _finish(self, key, future):
        try:
            url, error = future.result(), None
        except Exception as failure:
            url, error = "", (str(failure), dict(getattr(failure, "details", {}))) if isinstance(failure, m.UpdateError) else ("MIGU_API_ERROR", {})
        with self.lock:
            if self.closed or self.flights.get(key) is not future:
                return
            del self.flights[key]
            self.last_error = error[0] if error else None
            self.last_upstream = error[1] if error else None
            self.entries[key] = (self.clock() + (5 if error else 30), url, error)
            while len(self.entries) > 64:
                self.entries.popitem(last=False)

    def resolve(self, key, wait=9):
        with self.lock:
            if self.closed:
                raise m.FetchError("SERVICE_STOPPING")
            if key not in self.snapshot.channels:
                raise m.FetchError("MIGU_UNKNOWN_CHANNEL")
            cached = self.entries.get(key)
            if cached and cached[0] > self.clock():
                self.entries.move_to_end(key)
                if cached[2]:
                    raise MiguApiError(cached[2][0], cached[2][1])
                return cached[1]
            future = self.flights.get(key)
            if future is None:
                if len(self.flights) >= 8:
                    raise m.FetchError("MIGU_API_CAPACITY")
                future = self.pool.submit(self.resolver, key[1:])
                self.flights[key] = future
                self.fetches += 1
                future.add_done_callback(lambda done: self._finish(key, done))
        try:
            return future.result(timeout=wait)
        except FutureTimeout:
            raise m.FetchError("MIGU_API_LOADING") from None
        except m.UpdateError:
            raise
        except Exception:
            raise m.FetchError("MIGU_API_ERROR") from None

    def status(self):
        with self.lock:
            return {"provider": self.provider, "catalogue_ready": True, "channels": len(self.snapshot.channels),
                    "source_transport": "https", "last_error": self.last_error, "last_upstream": self.last_upstream, "api_requests": self.fetches,
                    "playback_verified": False, "quality": self.auth.rate_type, "storage": "memory",
                    "authorization": "configured-account" if self.auth.user_id else "anonymous",
                    "external_playlist": False, "client_version": self.auth.app_version}

    def close(self):
        with self.lock:
            self.closed = True
        self.pool.shutdown(wait=False, cancel_futures=True)

# migu/android.py
from collections import OrderedDict, deque
from concurrent.futures import TimeoutError as FutureTimeout, CancelledError
from dataclasses import dataclass
import hashlib
import json
import math
import os
import random
import re
import threading
import time
from types import MappingProxyType
from urllib.parse import parse_qs, urlsplit


ANDROID_KEYS = "cdabyzwxkl"
ANDROID_SUFFIX = "&sv=10004&ct=android"
LEGACY_APP_VERSION = "2600034600"
LEGACY_SUFFIX = "2cac4f2c6c3346a5b34e085725ef7e33migu"
MODERN_APP_VERSION = "2600037000"
MODERN_SUFFIX = "3ce941cc3cbc40528bfd1c64f9fdf6c0migu0123"
MODERN_SALT = "1230024"
FLV_DISABLED_PIDS = ("641886683", "641886773")
PLAYURL = "https://play.miguvideo.com/playurl/v1/play/playurl"
CACHE_SUCCESS = 5 * 60
CACHE_FAILURE = 60
CACHE_TRANSIENT = 3
TRANSIENT_FAILURES = {"NETWORK_ERROR", "FETCH_BUDGET_EXCEEDED", "MIGU_API_ERROR", "HTTP_408", "HTTP_429", "HTTP_500", "HTTP_502", "HTTP_503", "HTTP_504"}
BURST_WINDOW = 60.0
BURST_LIMIT = 30

RID_MESSAGES = {
    "COPYRIGHT_AREA_INVALID": "MIGU_REGION_RESTRICTED",
    "COPYRIGHT_SHIELD_INVALID": "MIGU_COPYRIGHT_SHIELD",
    "TIPS_NEED_MEMBER": "MIGU_MEMBERSHIP_REQUIRED",
    "TIPS_NEED_LOGIN": "MIGU_LOGIN_REQUIRED",
    "BLACK_APP_OR_TERMINAL": "MIGU_TERMINAL_BLOCKED",
    "WUDALIANSAI_FUFEI_VERSION_UPGRADE": "MIGU_CLIENT_VERSION_UPGRADE_REQUIRED",
}


class MiguRateLimitError(m.FetchError):
    def __init__(self, retry_after):
        super().__init__("MIGU_RESOLVE_BURST_LIMIT")
        self.retry_after = max(1, min(60, int(retry_after)))


def _md5(text):
    return hashlib.md5(text.encode("utf-8")).hexdigest()


def _date_string():
    return m.utcnow().astimezone(m.CHINA).strftime("%Y%m%d")


def _at(text, index):
    return text[index] if 0 <= index < len(text) else ""


def dd_calcu(pu_data, program_id, rate_type, user_id="", *, legacy=False, timestamp=None):
    """Build ddCalcu exactly as the reference implementation does.

    ``legacy`` selects the older 720p variant (fixed words, date digit 3).
    """
    if not pu_data or not program_id:
        return ""
    words = ["v", "a", "0", "a"]
    date = timestamp[:8] if timestamp and re.fullmatch(r"[0-9]{14}", timestamp) else _date_string()
    if legacy:
        words[0] = "v"
        date_index = 2
        program_index = 6
    else:
        if user_id:
            words[0] = _at(ANDROID_KEYS, int(user_id[7]) if len(user_id) > 7 and user_id[7].isdigit() else -1) or words[0]
        if str(rate_type) == "2":
            words[0] = "v"
        if 3 < len(user_id) <= 8:
            words[0] = "e"
        date_index = 0
        program_index = 6
    out = []
    i = 0
    while i < len(pu_data) // 2:
        out.append(pu_data[len(pu_data) - i - 1])
        out.append(pu_data[i])
        if i == 1:
            out.append(words[0])
        elif i == 2:
            out.append(_at(ANDROID_KEYS, int(date[date_index]) if date[date_index].isdigit() else -1))
        elif i == 3:
            program_char = _at(program_id, program_index)
            out.append(_at(ANDROID_KEYS, int(program_char)) if program_char.isdigit() else "")
        elif i == 4:
            out.append(words[3])
        i += 1
    if len(pu_data) % 2:
        out.append(pu_data[len(pu_data)//2])
    return "".join(out)


def _headers(pid, *, legacy, user_id, token, rate_type, settings=None):
    app_version = LEGACY_APP_VERSION if legacy else (settings.app_version if settings else MODERN_APP_VERSION)
    channel = (f"{app_version}-99000-201600010010028" if legacy
               else (settings.client_channel_id if settings else "2600037000-99000-200300220100002"))
    headers = {"AppVersion": app_version, "TerminalId": "android", "X-UP-CLIENT-CHANNEL-ID": channel,
               "User-Agent": "node-fetch", "Accept": "*/*"}
    if pid not in FLV_DISABLED_PIDS:
        headers["appCode"] = settings.app_code if settings else "miguvideo_default_android"
    # Reference: 标清 (rateType 2) always asks as a guest.
    if not legacy and str(rate_type) != "2" and token and user_id:
        headers["UserId"], headers["UserToken"] = user_id, token
    return headers


def playurl_request(pid, rate_type, user_id="", token="", *, legacy=False, hdr=True, h265=True, settings=None):
    """Return (url, headers) for one playurl call, preserving the reference query order."""
    timestamp = str(int(time.time() * 1000))
    if legacy:
        digest = _md5(timestamp + pid + LEGACY_APP_VERSION[:8])
        salt = str(random.randint(0, 999999)).zfill(6) + "25"
        sign = _md5(digest + LEGACY_SUFFIX + salt[:4])
        rate_type = 3
    else:
        digest = _md5(timestamp + pid + (settings.app_version if settings else MODERN_APP_VERSION)[:8])
        salt = MODERN_SALT
        sign = _md5(digest + MODERN_SUFFIX)
    query = (f"?sign={sign}&rateType={rate_type}&contId={pid}&timestamp={timestamp}"
             f"&salt={salt}&flvEnable=true&super4k=true")
    if h265:
        query += "&h265N=true"
    if hdr:
        query += "&4kvivid=true&2Kvivid=true&vivid=2"
    return PLAYURL + query, _headers(pid, legacy=legacy, user_id=user_id, token=token,
                                      rate_type=rate_type, settings=settings)


# ANDROID_OPTIONS is defined at the top of this file.


@dataclass(frozen=True, repr=False)
class AndroidSettings:
    user_id: str = ANDROID_OPTIONS["user_id"]
    token: str = ANDROID_OPTIONS["token"]
    rate_type: int = ANDROID_OPTIONS["rate_type"]
    hdr: bool = ANDROID_OPTIONS["hdr"]
    h265: bool = ANDROID_OPTIONS["h265"]
    client_dispatch: bool = ANDROID_OPTIONS["client_dispatch"]
    # Compatibility knobs.  Set these to the values of your own installed,
    # officially released client.  They are not a licence to impersonate another
    # terminal: the upstream server still decides whether that client is allowed.
    app_version: str = ANDROID_OPTIONS["app_version"]
    app_code: str = ANDROID_OPTIONS["app_code"]
    client_channel_id: str = ANDROID_OPTIONS["client_channel_id"]

    @classmethod
    def load(cls, environ=None):
        environ = os.environ if environ is None else environ
        user_id = environ.get("MIGU_USER_ID", ANDROID_OPTIONS["user_id"]).strip()
        token = environ.get("MIGU_USER_TOKEN", ANDROID_OPTIONS["token"]).strip()
        if bool(user_id) != bool(token):
            raise m.UpdateError("MIGU_CREDENTIALS_INCOMPLETE")
        for value in (user_id, token):
            if len(value) > 4096 or any(not 33 <= ord(ch) <= 126 for ch in value):
                raise m.UpdateError("MIGU_CREDENTIALS_INVALID")
        try:
            rate_type = int(environ.get("MIGU_RATE_TYPE", str(ANDROID_OPTIONS["rate_type"])))
        except ValueError:
            raise m.UpdateError("MIGU_RATE_TYPE_INVALID") from None
        if rate_type not in {2, 3, 4, 7, 8, 9}:
            raise m.UpdateError("MIGU_RATE_TYPE_INVALID")
        app_version = environ.get("MIGU_APP_VERSION", ANDROID_OPTIONS["app_version"]).strip()
        if re.fullmatch(r"[0-9]{6,12}", app_version) is None:
            raise m.UpdateError("MIGU_APP_VERSION_INVALID")
        if app_version == "26000370":
            app_version = "2600037000"
        if app_version[:8] in {"26000009", "26000346"}:
            raise m.UpdateError("MIGU_PROTOCOL_PROFILE_MISMATCH")
        app_code = environ.get("MIGU_APP_CODE", ANDROID_OPTIONS["app_code"]).strip()
        if re.fullmatch(r"[A-Za-z0-9_]{1,64}", app_code) is None:
            raise m.UpdateError("MIGU_APP_CODE_INVALID")
        channel_id = environ.get("MIGU_CLIENT_CHANNEL_ID", ANDROID_OPTIONS["client_channel_id"]).strip()
        if re.fullmatch(r"[A-Za-z0-9_-]{8,64}", channel_id) is None:
            raise m.UpdateError("MIGU_CLIENT_CHANNEL_ID_INVALID")
        if environ.get("MIGU_CLIENT_DISPATCH", "1" if ANDROID_OPTIONS["client_dispatch"] else "0") == "0":
            raise m.UpdateError("MIGU_SERVER_DISPATCH_UNSUPPORTED")
        return cls(user_id=user_id, token=token, rate_type=rate_type,
                   hdr=environ.get("MIGU_HDR", "1" if ANDROID_OPTIONS["hdr"] else "0") != "0",
                   h265=environ.get("MIGU_H265", "1" if ANDROID_OPTIONS["h265"] else "0") != "0",
                   client_dispatch=environ.get("MIGU_CLIENT_DISPATCH", "1" if ANDROID_OPTIONS["client_dispatch"] else "0") != "0",
                   app_version=app_version, app_code=app_code, client_channel_id=channel_id)


def _fetch_json(client, url, headers):
    raw, _ = client.get(url, headers=headers, limit=256 * 1024)
    if raw is None:
        raise MiguApiError("MIGU_UNEXPECTED_304")
    try:
        payload = json.loads(raw.decode("utf-8"))
    except (UnicodeError, json.JSONDecodeError):
        raise MiguApiError("MIGU_API_FORMAT_CHANGED") from None
    if not isinstance(payload, dict):
        raise MiguApiError("MIGU_API_FORMAT_CHANGED")
    body = payload.get("body")
    if body is not None:
        if not isinstance(body, dict) or any(body.get(key) is not None and not isinstance(body[key], dict) for key in ("urlInfo", "content", "auth")):
            raise MiguApiError("MIGU_API_FORMAT_CHANGED")
    return payload


def android_play_url(pid, settings, client_factory=m.HttpClient, observer=None):
    """Resolve one channel, mirroring the reference flow including tier fallback."""
    if pid not in {item[0] for item in BUILTIN_CHANNELS}:
        raise MiguApiError("MIGU_UNKNOWN_CHANNEL")
    client = client_factory("api", attempts=1, timeout=8, budget=12)
    legacy = settings.rate_type >= 3 and not (settings.user_id and settings.token)
    sends_account = bool(not legacy and settings.rate_type != 2 and settings.user_id and settings.token)
    deadline = time.monotonic() + 12
    attempted = set()

    def call(rate):
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise m.FetchError("FETCH_BUDGET_EXCEEDED")
        client.budget = remaining
        attempted.add(rate)
        url, headers = playurl_request(pid, rate, settings.user_id if sends_account else "",
                                       settings.token if sends_account else "",
                                       legacy=legacy, hdr=settings.hdr, h265=settings.h265,
                                       settings=settings)
        m.validate_url(url, "api")
        return _fetch_json(client, url, headers)

    payload = call(3 if legacy else settings.rate_type)
    # Only request a genuinely lower supported tier. Never repeat or upgrade on denial.
    for _ in range(2):
        if payload.get("rid") != "TIPS_NEED_MEMBER":
            break
        info = (payload.get("body") or {}).get("urlInfo") or {}
        try:
            offered = int(info.get("rateType", 0))
        except (TypeError, ValueError):
            offered = 0
        current = min(attempted)
        fallback = 4 if offered >= 4 and current > 4 else 3
        if fallback >= current or fallback in attempted:
            break
        payload = call(fallback)

    details = api_status(payload, pid)
    if observer is not None:
        info = (payload.get("body") or {}).get("urlInfo") or {}
        def number(key, maximum):
            value = info.get(key)
            try:
                parsed = int(value) if type(value) is int or (isinstance(value, str) and value.isascii() and value.isdigit()) else -1
            except ValueError:
                return None
            return parsed if 0 <= parsed <= maximum else None
        observer({**details, "account_sent": sends_account,
                  "requested_quality": 3 if legacy else settings.rate_type,
                  "actual_quality": number("rateType", 9),
                  "trial_seconds": number("trySeeDuration", 86400)})
    rid = payload.get("rid")
    if rid != "SUCCESS":
        raise MiguApiError(RID_MESSAGES.get(rid, "MIGU_API_REJECTED"),
                           details)
    code = payload.get("code")
    if code is not None and str(code) != "200":
        raise MiguApiError("MIGU_API_REJECTED", details)
    body = payload.get("body") or {}
    info = body.get("urlInfo") or {}
    if not isinstance(body, dict) or not isinstance(info, dict):
        raise MiguApiError("MIGU_API_FORMAT_CHANGED")
    url = info.get("url")
    if not isinstance(url, str) or not url:
        raise MiguApiError("MIGU_PLAY_URL_MISSING", details)
    m.validate_url(url, "stream")
    query = parse_qs(urlsplit(url).query, keep_blank_values=True)
    content = body.get("content") or {}
    if not isinstance(content, dict):
        raise MiguApiError("MIGU_API_FORMAT_CHANGED")
    program_id = str(content.get("contId") or pid)
    if program_id != pid or ("ProgramID" in query and query["ProgramID"] != [pid]):
        raise MiguApiError("MIGU_CHANNEL_MISMATCH")
    if "ddCalcu" in query:
        if len(query["ddCalcu"]) != 1 or not query["ddCalcu"][0]:
            raise MiguApiError("MIGU_PLAY_URL_FORMAT_CHANGED")
        return url
    seeds = query.get("puData", [])
    stamps = query.get("timestamp", [])
    if len(seeds) != 1 or re.fullmatch(r"[0-9a-fA-F]{6,128}", seeds[0]) is None or len(stamps) != 1 or re.fullmatch(r"[0-9]{14}", stamps[0]) is None:
        raise MiguApiError("MIGU_PLAY_URL_FORMAT_CHANGED")
    try:
        returned_rate = int(info.get("rateType", 3 if legacy else settings.rate_type))
    except (TypeError, ValueError):
        raise MiguApiError("MIGU_API_FORMAT_CHANGED") from None
    if returned_rate not in {2,3,4,7,8,9}:
        raise MiguApiError("MIGU_API_FORMAT_CHANGED")
    # The public client signs using its requested mode before replacing rateType
    # with the server's actual quality. Account -> guest downgrades depend on this.
    proof = dd_calcu(seeds[0], pid, 3 if legacy else settings.rate_type, settings.user_id if sends_account else "", legacy=legacy, timestamp=stamps[0])
    suffix = "&ddCalcu=" + proof
    for key, value in (("sv", "10004"), ("ct", "android")):
        if key in query and query[key] != [value]:
            raise MiguApiError("MIGU_PLAY_URL_FORMAT_CHANGED")
        if key not in query:
            suffix += "&" + key + "=" + value
    return url + suffix


@dataclass(frozen=True)
class AndroidSnapshot:
    playlist: object
    channels: object


class AndroidStore:
    """On-demand resolution with the reference cache windows and scan protection."""
    provider = "migu-android"

    def __init__(self, settings=None, resolver=android_play_url, clock=time.monotonic):
        self.settings = settings or AndroidSettings.load()
        self.resolver = (lambda pid: android_play_url(pid, self.settings, observer=self._observe)) if resolver is android_play_url else resolver
        self.clock = clock
        self.pool = BoundedExecutor(max_workers=8, thread_name_prefix="migu-android", max_pending=8, lifo=True)
        self.lock = threading.RLock()
        self.flights, self.entries = {}, OrderedDict()
        self.waiters, self.active = {}, 0
        self.closed, self.last_error, self.fetches, self.cache_hits = False, None, 0, 0
        self.last_upstream, self.recent = None, deque()
        self.upstream_observation = None
        self.resolve_samples = deque(maxlen=32)
        self.credential_state = "unchecked" if self.settings.user_id else "unconfigured"
        channels = {"p" + pid: m.Channel(name, name, name, group, "", "", m.utcnow()) for pid, name, group in BUILTIN_CHANNELS}
        self.snapshot = AndroidSnapshot(None, MappingProxyType(channels))

    def _observe(self, observation):
        # Only this store's configured account can change its account state.
        # No additional network request is made for diagnostics.
        with self.lock:
            if self.closed:
                return
            self.upstream_observation = dict(observation)
            if observation['account_sent']:
                logged_in = observation['logged_in']
                self.credential_state = "accepted" if logged_in is True else "not_recognized" if logged_in is False else "unknown"
            elif self.settings.user_id:
                self.credential_state = "not_sent"

    def _retry_after(self):
        now = self.clock()
        while self.recent and now - self.recent[0] >= BURST_WINDOW:
            self.recent.popleft()
        if len(self.recent) < BURST_LIMIT:
            return 0
        return max(1, min(60, math.ceil(BURST_WINDOW - (now - self.recent[0]))))

    def _burst_ok(self):
        if self._retry_after():
            return False
        self.recent.append(self.clock())
        return True

    def _run_resolver(self, pid):
        with self.lock:
            if self.closed:
                raise m.FetchError("SERVICE_STOPPING")
            if not self._burst_ok():
                raise MiguRateLimitError(self._retry_after())
            self.fetches += 1
            self.active += 1
        try:
            return self.resolver(pid)
        finally:
            with self.lock:
                self.active -= 1

    def _finish(self, key, future):
        cancelled, local_limit = future.cancelled(), False
        try:
            url, error = future.result(), None
        except Exception as failure:
            local_limit = isinstance(failure, MiguRateLimitError)
            url = ""
            error = ((str(failure), dict(getattr(failure, "details", {})))
                     if isinstance(failure, m.UpdateError) else ("MIGU_API_ERROR", {}))
        with self.lock:
            if self.closed or self.flights.get(key) is not future:
                return
            del self.flights[key]
            if cancelled:
                return
            self.last_error = error[0] if error else None
            self.last_upstream = error[1] if error else None
            if local_limit:
                return  # Local queue/rate rejection must never poison a channel cache.
            ttl = CACHE_TRANSIENT if error and error[0] in TRANSIENT_FAILURES else CACHE_FAILURE if error else CACHE_SUCCESS
            self.entries[key] = (self.clock() + ttl, url, error)
            while len(self.entries) > 64:
                self.entries.popitem(last=False)

    def get(self, wait=0):
        with self.lock:
            if self.closed:
                raise m.FetchError("SERVICE_STOPPING")
            return self.snapshot

    def resolve(self, key, wait=9):
        started, result = time.perf_counter(), "OK"
        try:
            return self._resolve(key, wait)
        except Exception as error:
            text = str(error)
            result = text if isinstance(error, m.UpdateError) and re.fullmatch(r"[A-Z0-9_]{1,80}", text) else "MIGU_API_ERROR"
            raise
        finally:
            elapsed = min(120000, max(0, round((time.perf_counter()-started)*1000)))
            sample = None
            with self.lock:
                if not self.closed and key in self.snapshot.channels:
                    sample = {"channel_id": key[1:], "elapsed_ms": elapsed, "result": result}
                    self.resolve_samples.append(sample)
            if sample and elapsed >= 1000:
                try:
                    print(f"[{m.iso(m.utcnow())}] MIGU_SLOW_RESOLVE 本地取源等待（不含播放器缓冲） " + json.dumps(sample, sort_keys=True), flush=True)
                except (OSError, ValueError):
                    pass

    def _resolve(self, key, wait=9):
        with self.lock:
            if self.closed:
                raise m.FetchError("SERVICE_STOPPING")
            if key not in self.snapshot.channels:
                raise m.FetchError("MIGU_UNKNOWN_CHANNEL")
            cached = self.entries.get(key)
            if cached and cached[0] > self.clock():
                self.entries.move_to_end(key)
                self.cache_hits += 1
                if cached[2]:
                    raise MiguApiError(cached[2][0], cached[2][1])
                return cached[1]
            future = self.flights.get(key)
            if future is None:
                if len(self.flights) >= 16:
                    raise m.FetchError("MIGU_API_CAPACITY")
                if self._retry_after():
                    raise MiguRateLimitError(self._retry_after())
                try:
                    future = self.pool.submit(self._run_resolver, key[1:])
                except RuntimeError:
                    raise m.FetchError("MIGU_API_CAPACITY") from None
                self.flights[key] = future
                future.add_done_callback(lambda done: self._finish(key, done))
            self.waiters[future] = self.waiters.get(future, 0) + 1
        try:
            return future.result(timeout=wait)
        except FutureTimeout:
            raise m.FetchError("MIGU_API_LOADING") from None
        except CancelledError:
            raise m.FetchError("MIGU_API_LOADING") from None
        except m.UpdateError:
            raise
        except Exception:
            raise m.FetchError("MIGU_API_ERROR") from None
        finally:
            with self.lock:
                remaining = self.waiters.get(future, 1) - 1
                if remaining:
                    self.waiters[future] = remaining
                else:
                    self.waiters.pop(future, None)
                    future.cancel()  # Only succeeds for work not started; shared/running work stays.

    def status(self):
        with self.lock:
            return {"provider": self.provider, "catalogue_ready": True, "channels": len(self.snapshot.channels),
                    "source_transport": "https", "last_error": self.last_error, "last_upstream": self.last_upstream,
                    "api_requests": self.fetches, "cache_hits": self.cache_hits,
                    "playback_verified": False, "quality": self.settings.rate_type, "storage": "memory",
                    "authorization": "configured-account" if self.settings.user_id else "anonymous",
                    "external_playlist": False, "client": "android",
                    "hdr": self.settings.hdr, "h265": self.settings.h265,
                    "client_dispatch": self.settings.client_dispatch,
                    "request_profile": "legacy720p" if self.settings.rate_type >= 3 and not self.settings.user_id else "modern",
                    "cache_success_seconds": CACHE_SUCCESS,
                    "transient_failure_seconds": CACHE_TRANSIENT,
                    "active_resolves": self.active,
                    "pending_resolves": max(0, len(self.flights)-self.active),
                    "credential_state": self.credential_state,
                    "rate_limit_retry_after_seconds": self._retry_after(),
                    "recent_resolves": list(self.resolve_samples),
                    "upstream_observation": dict(self.upstream_observation) if self.upstream_observation else None}

    def close(self):
        with self.lock:
            self.closed = True
        self.pool.shutdown(wait=False, cancel_futures=True)

# migu/source.py
from dataclasses import dataclass
from datetime import datetime, timedelta
from concurrent.futures import TimeoutError as FutureTimeout, CancelledError
import re
import threading
import time
from types import MappingProxyType
from urllib.parse import parse_qs, urlsplit

# Prefer the live signed catalogue.  The repository copy is a validated fallback
# when the upstream HTTP source is unavailable or fails freshness policy.
LIST_SOURCES = (
    'http://www.52top.com.cn:678/downloads/migu.txt',
    'https://raw.githubusercontent.com/joeshu/yqk-forward-widget/main/migu.m3u8',
)
CATCHUP_SOURCE = '&playbackbegin=${(b)yyyyMMddHHmmss}&playbackend=${(e)yyyyMMddHHmmss}'
EPG_ID_ALIASES = {'上视新闻综合': '上海新闻综合'}
ATTR = re.compile(r'([a-z][a-z0-9-]*)="([^"\r\n]*)"')
CHANNEL_ATTRS = {'tvg-id','tvg-name','tvg-logo','group-title','svg-id','svg-name'}

@dataclass(frozen=True)
class ListPlaylist:
    channels: tuple
    catchup: bool
    duplicates_removed: int = 0

@dataclass(frozen=True)
class ListSnapshot:
    playlist: ListPlaylist
    channels: object

def parse_list_attributes(value, channel=False):
    attrs, rest = {}, value.strip()
    while rest and not (channel and rest.startswith(",")):
        match = ATTR.match(rest)
        if match is None or match[1] in attrs:
            raise UpdateError("METADATA_INVALID_OR_DUPLICATE")
        attrs[match[1]] = match[2]
        rest = rest[match.end():]
        if rest and not rest[0].isspace() and not (channel and rest[0] == ","):
            raise UpdateError("METADATA_SEPARATOR")
        rest = rest.lstrip()
    if channel:
        if not rest.startswith(",") or not rest[1:].strip():
            raise UpdateError("CHANNEL_NAME_MISSING")
        return attrs, rest[1:].strip()
    return attrs

def parse_source_list(raw):
    if len(raw) > MAX_BYTES:
        raise UpdateError("PLAYLIST_TOO_LARGE")
    try:
        text = raw.decode("utf-8-sig").replace("\r\n", "\n")
    except UnicodeError:
        raise UpdateError("PLAYLIST_NOT_UTF8") from None
    if not clean_text(text.replace("\n", "")):
        raise UpdateError("PLAYLIST_CONTROL_CHARACTER")
    lines = text.split("\n")
    if any(len(line) > MAX_LINE for line in lines):
        raise UpdateError("PLAYLIST_LINE_TOO_LONG")
    if not lines or not (lines[0] == "#EXTM3U" or lines[0].startswith("#EXTM3U ")):
        raise UpdateError("PLAYLIST_HEADER_INVALID")
    header = parse_list_attributes(lines[0][7:])
    if set(header) - {"x-tvg-url", "tvg-url", "url-tvg", "catchup", "catchup-source"}:
        raise UpdateError("HEADER_ATTRIBUTE_NOT_ALLOWED")
    catchup = "catchup" in header or "catchup-source" in header
    if catchup and (header.get("catchup") != "append" or header.get("catchup-source") != CATCHUP_SOURCE):
        raise UpdateError("CATCHUP_TEMPLATE_NOT_ALLOWED")
    channels, seen, duplicates = [], set(), 0
    pending = None
    for line in lines[1:]:
        if not line:
            continue
        if line.startswith("#EXTINF:"):
            if pending is not None or not line.startswith("#EXTINF:-1 "):
                raise UpdateError("CHANNEL_METADATA_INVALID")
            attrs, display = parse_list_attributes(line[len("#EXTINF:-1"):], channel=True)
            if set(attrs) - CHANNEL_ATTRS:
                raise UpdateError("CHANNEL_ATTRIBUTE_NOT_ALLOWED")
            for suffix in ("id", "name"):
                standard, legacy = "tvg-" + suffix, "svg-" + suffix
                if standard in attrs and legacy in attrs and attrs[standard] != attrs[legacy]:
                    raise UpdateError("CHANNEL_ATTRIBUTE_CONFLICT")
                attrs.setdefault(standard, attrs.get(legacy, display))
            attrs["tvg-id"] = EPG_ID_ALIASES.get(attrs["tvg-id"], attrs["tvg-id"])
            if any(not attrs[key] or len(attrs[key]) > 256 for key in ("tvg-id", "tvg-name")) or len(display) > 256 or '"' in display:
                raise UpdateError("CHANNEL_NAME_INVALID")
            if attrs.get("tvg-logo"):
                validate_url(attrs["tvg-logo"], "logo")
            pending = (attrs, display)
        elif line.startswith("#"):
            raise UpdateError("PLAYLIST_DIRECTIVE_NOT_ALLOWED")
        else:
            if pending is None:
                raise UpdateError("URL_WITHOUT_CHANNEL")
            parts = validate_url(line, "stream")
            try:
                params = parse_qs(parts.query, keep_blank_values=True, max_num_fields=100)
            except ValueError:
                raise UpdateError("URL_TOO_MANY_PARAMETERS") from None
            timestamps = params.get("timestamp", [])
            if len(timestamps) != 1 or re.fullmatch(r"\d{14}", timestamps[0]) is None:
                raise UpdateError("SIGNATURE_TIMESTAMP_MISSING")
            try:
                signed_at = datetime.strptime(timestamps[0], "%Y%m%d%H%M%S").replace(tzinfo=CHINA)
            except ValueError:
                raise UpdateError("SIGNATURE_TIMESTAMP_INVALID") from None
            attrs, display = pending
            channel = Channel(attrs["tvg-id"], attrs["tvg-name"], display, attrs.get("group-title", ""), attrs.get("tvg-logo", ""), line, signed_at)
            if channel in seen:
                duplicates += 1
            else:
                seen.add(channel)
                channels.append(channel)
            if len(channels) > 2000:
                raise UpdateError("TOO_MANY_CHANNELS")
            pending = None
    if pending is not None or not channels:
        raise UpdateError("PLAYLIST_EMPTY_OR_TRUNCATED")
    return ListPlaylist(tuple(channels), catchup, duplicates)

def validate_list_candidate(candidate, previous=None, *, now=None, min_channels=100, min_retention=0.9, max_age_hours=12):
    now = now or utcnow()
    if len(candidate.channels) < min_channels:
        raise UpdateError("TOO_FEW_CHANNELS")
    # Publication policy, not an inferred token expiry time.
    for channel in candidate.channels:
        if channel.signed_at > now + timedelta(minutes=15):
            raise UpdateError("SIGNATURE_FROM_FUTURE")
        if channel.signed_at < now - timedelta(hours=max_age_hours):
            raise UpdateError("SOURCE_SNAPSHOT_TOO_OLD")
    if previous is not None:
        previous_ids = {channel.id for channel in previous.channels}
        candidate_ids = {channel.id for channel in candidate.channels}
        if len(candidate_ids & previous_ids) < len(previous_ids) * min_retention:
            raise UpdateError("CHANNEL_RETENTION_TOO_LOW")
        last_times = {}
        for channel in previous.channels:
            last_times[channel.id] = max(last_times.get(channel.id, channel.signed_at), channel.signed_at)
        if any(channel.id in last_times and channel.signed_at < last_times[channel.id] for channel in candidate.channels):
            raise UpdateError("SOURCE_SIGNATURE_ROLLBACK")

def source_key(channel):
    programme = parse_qs(urlsplit(channel.url).query).get('ProgramID', [''])[0]
    return 'p'+programme if re.fullmatch(r'[0-9]{1,20}',programme) else 'n'+m.digest(channel.id.encode())[:24]


def list_snapshot(playlist):
    channels = {}
    for channel in playlist.channels:
        key = source_key(channel)
        if key in channels and channels[key].id != channel.id:
            raise m.FetchError('LIST_CHANNEL_ID_COLLISION')
        channels.setdefault(key,channel)
    return ListSnapshot(playlist,MappingProxyType(channels))


def list_catchup(query):
    begin, end = query.get('playbackbegin'), query.get('playbackend')
    if begin is None and end is None:
        return ''
    if not begin or not end or any(re.fullmatch(r'[0-9]{14}',x) is None for x in (begin[0],end[0])):
        raise m.FetchError('CATCHUP_TIME_INVALID')
    try:
        first = datetime.strptime(begin[0],'%Y%m%d%H%M%S').replace(tzinfo=m.CHINA)
        last = datetime.strptime(end[0],'%Y%m%d%H%M%S').replace(tzinfo=m.CHINA)
    except ValueError:
        raise m.FetchError('CATCHUP_TIME_INVALID') from None
    now = m.utcnow()
    if not first < last or last-first > timedelta(days=1) or first < now-timedelta(days=7) or last > now+timedelta(minutes=5):
        raise m.FetchError('CATCHUP_TIME_OUT_OF_POLICY')
    return '&playbackbegin='+begin[0]+'&playbackend='+end[0]


class ListStore:
    provider = 'published-list'

    def __init__(self, source='auto', client_factory=m.HttpClient, clock=time.monotonic, min_channels=100):
        self.sources = LIST_SOURCES if source=='auto' else (LIST_SOURCES[1 if source=='github' else 0],)
        self.client_factory, self.clock, self.min_channels = client_factory, clock, min_channels
        self.lock = threading.RLock()
        self.pool = BoundedExecutor(1,thread_name_prefix='migu-list',max_pending=1)
        self.snapshot, self.future, self.closed = None,None,False
        self.fresh_until, self.retry_at, self.failures = 0,0,0
        self.last_error, self.updated, self.active_source = None,None,None
        # Validators are process-memory only; signed media URLs are never persisted.
        self.etags, self.not_modified = {}, 0
        self.fetches = 0

    def _usable(self):
        if self.snapshot is None:
            return False
        try:
            validate_list_candidate(self.snapshot.playlist,min_channels=self.min_channels)
            return True
        except m.UpdateError:
            return False

    def _refresh(self):
        try:
            with self.lock: previous=self.snapshot
            selected = None
            error = 'LIST_UNAVAILABLE'
            for source in self.sources:
                if self.closed:
                    return
                try:
                    with self.lock:
                        # A validator is usable only for the snapshot currently
                        # served from that same source; a fallback snapshot must
                        # never be treated as the body behind another source's 304.
                        etag = self.etags.get(source, '') if self.active_source == ('upstream-http' if source == LIST_SOURCES[0] else 'github') else ''
                    headers = {'If-None-Match': etag} if etag else None
                    raw, response_headers = self.client_factory('catalogue',attempts=1,timeout=5,budget=8).get(source,headers=headers,limit=m.MAX_BYTES)
                    if raw is None:
                        # A 304 only proves the selected source is unchanged.  It is
                        # safe only when the in-memory snapshot passed full validation.
                        if previous is None:
                            raise m.FetchError('LIST_UNEXPECTED_304')
                        validate_list_candidate(previous.playlist,min_channels=self.min_channels)
                        selected = previous
                        with self.lock:
                            self.not_modified += 1
                        break
                    playlist=parse_source_list(raw)
                    validate_list_candidate(playlist,previous.playlist if previous else None,min_channels=self.min_channels)
                    selected=list_snapshot(playlist)
                    returned_etag = response_headers.get('ETag', '')
                    if returned_etag and len(returned_etag) <= 256 and '\r' not in returned_etag and '\n' not in returned_etag:
                        with self.lock:
                            self.etags[source] = returned_etag
                    break
                except (ValueError,OSError) as failure:
                    error=str(failure) if isinstance(failure,m.UpdateError) else 'LIST_NETWORK_ERROR'
            if selected is None:
                raise m.FetchError(error)
            with self.lock:
                if self.closed:return
                self.snapshot=selected
                self.active_source='upstream-http' if source==LIST_SOURCES[0] else 'github'
                self.fresh_until=self.clock()+60
                self.retry_at,self.failures,self.last_error=0,0,None
                self.updated=m.iso(m.utcnow())
                self.fetches+=1
        except Exception as failure:
            with self.lock:
                if not self.closed:
                    self.failures+=1
                    self.retry_at=self.clock()+min(60,5*2**min(self.failures-1,4))
                    self.last_error=str(failure) if isinstance(failure,m.UpdateError) else 'LIST_REFRESH_ERROR'
        finally:
            with self.lock:self.future=None

    def get(self,wait=6):
        with self.lock:
            if self.closed:raise m.FetchError('SERVICE_STOPPING')
            usable=self._usable()
            if usable and self.clock()<self.fresh_until:return self.snapshot
            if self.future is None and self.clock()>=self.retry_at:self.future=self.pool.submit(self._refresh)
            if usable:return self.snapshot
            future=self.future
        if future:
            try:future.result(timeout=wait)
            except (FutureTimeout,CancelledError):pass
        with self.lock:
            if self._usable():return self.snapshot
            raise m.FetchError(self.last_error or 'LIST_LOADING')

    def resolve(self,key):
        channel=self.get().channels.get(key)
        if channel is None:raise m.FetchError('MIGU_UNKNOWN_CHANNEL')
        return channel.url

    def status(self):
        with self.lock:
            ready=self._usable()
            return {'provider':self.provider,'catalogue_ready':ready,'channels':len(self.snapshot.channels) if ready else 0,
                    'refreshing':self.future is not None,'source':self.active_source,'updated_utc':self.updated,
                    'last_error':self.last_error,'catalogue_refreshes':self.fetches,'catalogue_not_modified':self.not_modified,
                    'playback_verified':False,'quality':'source-provided','storage':'memory'}

    def close(self):
        with self.lock:self.closed=True
        self.pool.shutdown(wait=False)

# migu/epg.py
from concurrent.futures import TimeoutError as FutureTimeout, CancelledError, as_completed
from datetime import datetime, timedelta, timezone
import json
import os
from pathlib import Path
import tempfile
import threading
import time
import xml.etree.ElementTree as ET



def official_programmes(pid, raw, now=None):
    now = now or m.utcnow()
    if not isinstance(raw, bytes) or len(raw) > 512*1024:
        raise m.FetchError('EPG_RESPONSE_TOO_LARGE')
    try:
        payload = json.loads(raw)
        if str(payload.get('code')) != '200':
            raise m.FetchError('EPG_API_REJECTED')
        programmes = (payload.get('body') or {}).get('program') or []
        if not isinstance(programmes, list) or len(programmes) > 7:
            raise m.FetchError('EPG_API_FORMAT_CHANGED')
        rows = set()
        count = 0
        for group in programmes:
            for programme in group.get('content') or []:
                count += 1
                if count > 1000:
                    raise m.FetchError('EPG_TOO_MANY_PROGRAMMES')
                if str(programme.get('pID', pid)) != pid:
                    continue
                title = programme.get('contName')
                begin, end = programme.get('startTime'), programme.get('endTime')
                if not isinstance(title, str) or not title.strip() or len(title) > 512 or not m.clean_text(title):
                    continue
                if type(begin) not in {int, float} or type(end) not in {int, float}:
                    continue
                try:
                    start = datetime.fromtimestamp(begin/1000, timezone.utc)
                    stop = datetime.fromtimestamp(end/1000, timezone.utc)
                except (ValueError, OverflowError, OSError):
                    continue
                if not timedelta(0) < stop-start <= timedelta(days=2) or stop < now-timedelta(days=1) or start > now+timedelta(days=7):
                    continue
                rows.add((start, stop, title))
        return tuple(sorted(rows))
    except (ValueError, TypeError, AttributeError) as failure:
        if isinstance(failure, m.UpdateError):
            raise
        raise m.FetchError('EPG_API_FORMAT_CHANGED') from None


def render_epg(schedules, now=None):
    now = now or m.utcnow()
    root = ET.Element('tv', {'generator-info-name': 'migu-live'})
    matched, count, latest = set(), 0, None
    for pid, name, _ in BUILTIN_CHANNELS:
        channel = ET.SubElement(root, 'channel', {'id': 'p'+pid})
        ET.SubElement(channel, 'display-name', {'lang': 'zh'}).text = name
    for pid, _, _ in BUILTIN_CHANNELS:
        for start, stop, title in schedules.get(pid, ()):
            if stop < now-timedelta(days=1):
                continue
            count += 1
            if count > 10000:
                raise m.FetchError('EPG_TOO_MANY_PROGRAMMES')
            matched.add(pid)
            node = ET.SubElement(root, 'programme', {'channel': 'p'+pid,
                'start': start.astimezone(m.CHINA).strftime('%Y%m%d%H%M%S %z'),
                'stop': stop.astimezone(m.CHINA).strftime('%Y%m%d%H%M%S %z')})
            ET.SubElement(node, 'title', {'lang': 'zh'}).text = title
            latest = max(latest, stop) if latest else stop
    if latest is None or latest <= now:
        raise m.FetchError('EPG_EMPTY_OR_EXPIRED')
    raw = ET.tostring(root, encoding='utf-8', xml_declaration=True)
    if len(raw) > m.MAX_BYTES:
        raise m.FetchError('EPG_TOO_LARGE')
    return raw, {'programmes': count, 'matched_channels': len(matched),
                 'missing_channels': [name for pid, name, _ in BUILTIN_CHANNELS if pid not in matched]}, latest


class EpgStore:
    def __init__(self, client_factory=m.HttpClient, clock=time.monotonic, enabled=True, cache_path=None):
        self.client_factory, self.clock, self.enabled = client_factory, clock, enabled
        self.lock, self.ready = threading.RLock(), threading.Event()
        self.pool = BoundedExecutor(1, thread_name_prefix='migu-epg-refresh', max_pending=1)
        self.downloads = BoundedExecutor(8, thread_name_prefix='migu-epg', max_pending=8)
        self.future, self.closed, self.data = None, False, None
        self.details, self.latest, self.last_error, self.updated = {}, None, None, None
        self.fresh_until, self.retry_at, self.valid_until = 0, 0, 0
        self.rows, self.day = {}, None
        self.attempts = {}
        self.upstream_error = None
        self.failures, self.expires_wall = {}, {}
        self.cache_path = Path(cache_path) if cache_path else None
        self.cache_error, self.cache_digest, self.last_cache_write = None, None, -float('inf')
        self.storage = 'disk' if self.cache_path else 'memory'
        if self.cache_path:
            self._load_cache()

    def _backoff(self, pid):
        return min(6*3600, 15*60 * 2**min(self.failures.get(pid, 1)-1, 5))

    def _defer(self, pid, seconds):
        self.attempts[pid] = self.clock()+seconds
        self.expires_wall[pid] = int(m.utcnow().timestamp()+seconds)

    def _load_cache(self):
        try:
            if self.cache_path.is_symlink():
                raise ValueError('symlink')
            with self.cache_path.open('rb') as handle:
                raw = handle.read(m.MAX_BYTES+1)
            if len(raw) > m.MAX_BYTES:
                raise ValueError('size')
            saved = json.loads(raw)
            now = m.utcnow()
            age = now.timestamp()-saved['saved_at']
            if saved['version'] != 1 or not -300 <= age <= 36*3600:
                raise ValueError('age')
            body = saved['data']
            day = body['day']
            if not isinstance(day, str) or len(day) != 8 or not day.isdecimal():
                raise ValueError('day')
            channels = body['channels']
            allowed = {pid for pid, _, _ in BUILTIN_CHANNELS}
            if not isinstance(channels, dict) or set(channels)-allowed:
                raise ValueError('ids')
            rows, attempts, expires, failures = {}, {}, {}, {}
            total = 0
            for pid, entry in channels.items():
                total += len(entry['rows'])
                if total > 10000:
                    raise ValueError('count')
                parsed = []
                for start, stop, title in entry['rows']:
                    start, stop = datetime.fromisoformat(start), datetime.fromisoformat(stop)
                    if start.utcoffset() is None or stop.utcoffset() is None or not timedelta(0) < stop-start <= timedelta(days=2):
                        raise ValueError('time')
                    if not isinstance(title, str) or not title or len(title)>512 or not m.clean_text(title) or start>now+timedelta(days=7):
                        raise ValueError('title')
                    parsed.append((start, stop, title))
                expiry = entry['expires_at']
                if type(expiry) not in {int, float} or not now.timestamp()-36*3600 <= expiry <= now.timestamp()+6*3600+300:
                    raise ValueError('expiry')
                failed = entry.get('failures', 0)
                if type(failed) is not int or not 0 <= failed <= 100000:
                    raise ValueError('failures')
                rows[pid] = tuple(parsed)
                expires[pid], failures[pid] = expiry, failed
                attempts[pid] = self.clock()+max(0,expiry-now.timestamp())
            data, details, latest = render_epg(rows, now)
            self.rows, self.attempts, self.expires_wall, self.failures = rows, attempts, expires, failures
            self.day, self.data, self.details, self.latest = day, data, details, latest
            self.valid_until = self.clock()+max(0,36*3600-age)
            self.updated = m.iso(datetime.fromtimestamp(saved['saved_at'],timezone.utc))
            self.cache_digest = m.digest(m.json_bytes(body))
        except FileNotFoundError:
            pass
        except (OSError, ValueError, TypeError, KeyError, OverflowError):
            self.cache_error = 'EPG_CACHE_INVALID_OR_UNREADABLE'

    def _save_cache(self):
        if self.closed or self.cache_path is None or self.data is None:
            return
        temporary = None
        try:
            body = {'day': self.day, 'channels': {pid: {'rows': [(m.iso(a),m.iso(b),title) for a,b,title in rows],
                'expires_at': self.expires_wall.get(pid,0), 'failures': self.failures.get(pid,0)} for pid in sorted(self.attempts) for rows in [self.rows.get(pid,())]}}
            digest = m.digest(m.json_bytes(body))
            if digest == self.cache_digest:
                return
            raw = m.json_bytes({'version':1,'saved_at':m.utcnow().timestamp(),'data':body})
            if len(raw)>m.MAX_BYTES or self.cache_path.is_symlink():
                raise ValueError('cache')
            with tempfile.NamedTemporaryFile(dir=self.cache_path.parent,delete=False) as handle:
                temporary = Path(handle.name)
                handle.write(raw);handle.flush();os.fsync(handle.fileno())
            os.replace(temporary,self.cache_path)
            self.cache_digest, self.last_cache_write, self.cache_error = digest, self.clock(), None
        except (OSError, ValueError):
            self.cache_error, self.storage, self.cache_path = 'EPG_CACHE_WRITE_FAILED', 'memory-fallback', None
        finally:
            if temporary is not None:
                try: temporary.unlink(missing_ok=True)
                except OSError: pass

    def _usable(self):
        return self.data is not None and self.clock() < self.valid_until and self.latest > m.utcnow()

    def _fetch(self, pid, day):
        url = f'https://program-sc.miguvideo.com/live/v2/tv-programs-data/{pid}/{day}'
        raw, _ = self.client_factory('epg', attempts=1, timeout=5, budget=6).get(url, limit=512*1024)
        return official_programmes(pid, raw)

    def _publish(self):
        result = render_epg(self.rows)
        with self.lock:
            if self.closed:
                return
            self.data, self.details, self.latest = result
            self.valid_until = self.clock() + 36*3600
            self.updated = m.iso(m.utcnow())
            self.ready.set()
        if self.clock()-self.last_cache_write >= 30:
            self._save_cache()

    def _refresh(self, day):
        try:
            if self.day != day:
                self.rows, self.attempts, self.day = {}, {}, day
                self.failures, self.expires_wall = {}, {}
            failures = 0
            deadline = time.monotonic() + 120
            pending = [pid for pid, _, _ in BUILTIN_CHANNELS if self.clock() >= self.attempts.get(pid, 0)]
            pending.sort(key=lambda pid: (bool(self.rows.get(pid)), self.failures.get(pid, 0)))
            for index in range(0, len(pending), 8):
                if self.closed or time.monotonic() >= deadline:
                    break
                batch = {self.downloads.submit(self._fetch, pid, day): pid for pid in pending[index:index+8]}
                completed = set()
                try:
                    for future in as_completed(batch, timeout=8):
                        pid = batch[future]
                        completed.add(future)
                        try:
                            rows = future.result()
                            self.rows[pid] = rows
                            self.failures[pid] = 0 if rows else self.failures.get(pid, 0)+1
                            self._defer(pid, 6*3600 if rows else self._backoff(pid))
                            if self.data is None and rows:
                                try:
                                    self._publish()  # A slow sibling must not hide ready programmes.
                                except m.UpdateError:
                                    pass
                        except Exception as failure:
                            failures += 1
                            with self.lock:
                                self.upstream_error = str(failure) if isinstance(failure, m.UpdateError) else 'EPG_FETCH_ERROR'
                            self.failures[pid] = self.failures.get(pid, 0)+1
                            self._defer(pid, self._backoff(pid))
                except FutureTimeout:
                    for future in set(batch)-completed:
                        future.cancel()
                        self.failures[batch[future]] = self.failures.get(batch[future], 0)+1
                        self._defer(batch[future], self._backoff(batch[future]))
                        failures += 1
                if self.closed:
                    return
                try:
                    self._publish()  # Publish usable partial data; continue filling other channels.
                except m.UpdateError:
                    pass
            with self.lock:
                if not self.closed:
                    self.upstream_error = self.upstream_error if failures else None
                    self.last_error = 'EPG_REFRESH_PARTIAL_FAILURE' if failures else (None if self.details.get('matched_channels') == len(BUILTIN_CHANNELS) else 'EPG_PARTIAL_OR_FAILED')
                    self.fresh_until = self.clock() + (60 if len(self.attempts) < len(BUILTIN_CHANNELS) else 15*60)
                    self.retry_at = self.clock() + 60
                    if not self._usable():
                        self.last_error = 'EPG_EMPTY_OR_UNAVAILABLE'
                    self.ready.set()
        except Exception as failure:
            with self.lock:
                if not self.closed:
                    self.last_error = str(failure) if isinstance(failure, m.UpdateError) else 'EPG_REFRESH_ERROR'
                    self.retry_at = self.clock() + 60
                    self.ready.set()
        finally:
            self._save_cache()
            with self.lock:
                self.future = None

    def get(self, wait=5):
        with self.lock:
            if not self.enabled:
                raise m.FetchError('EPG_DISABLED')
            if self.closed:
                raise m.FetchError('SERVICE_STOPPING')
            day = m.utcnow().astimezone(m.CHINA).strftime('%Y%m%d')
            usable = self._usable()
            if usable and self.clock() < self.fresh_until and self.day == day:
                return self.data
            if self.future is None and (self.clock() >= self.retry_at or self.day != day):
                if not usable:
                    self.ready.clear()
                self.future = self.pool.submit(self._refresh, day)
            if usable:
                return self.data
            future = self.future
        if future is not None:
            try:
                future.result(timeout=wait)
            except (FutureTimeout, CancelledError):
                pass
        with self.lock:
            if self.closed:
                raise m.FetchError('SERVICE_STOPPING')
            if self._usable():
                return self.data
            raise m.FetchError(self.last_error or 'EPG_LOADING')

    def status(self):
        with self.lock:
            return {'enabled': self.enabled, 'source': 'migu-official', 'concurrency': 8, 'ready': self._usable(),
                    'refreshing': self.future is not None, 'updated_utc': self.updated,
                    'last_error': self.last_error, 'upstream_error': self.upstream_error, 'storage': self.storage, 'cache_error': self.cache_error, **self.details}

    def close(self):
        with self.lock:
            self.closed = True
            self.ready.set()
        self.pool.shutdown(wait=False)
        self.downloads.shutdown(wait=False)

# migu/service.py
import argparse
from collections import OrderedDict, deque
from concurrent.futures import CancelledError, TimeoutError as FutureTimeout
import socket
import hmac
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import ipaddress
import json
import os
from pathlib import Path
import re
import secrets
import signal
import sys
import tempfile
import threading
import time
from urllib.parse import parse_qs, urljoin, urlsplit


VERSION = "0.8.4"
DEFAULT_PORT = 18768
TOKEN_PATTERN = re.compile(r"[A-Za-z0-9_-]{32,128}")
EVENT_MESSAGES = {
    "HTTP_SERVER_STARTED": "本地 HTTP 服务已启动",
    "MIGU_REGION_RESTRICTED": "咪咕限制当前出口地区",
    "MIGU_LOGIN_OR_MEMBERSHIP_REQUIRED": "上游授权拒绝，需核对具体原因",
    "MIGU_AUTHORIZATION_REJECTED": "咪咕拒绝当前播放授权；不能仅凭此判定需要会员",
    "MIGU_LOGIN_REQUIRED": "咪咕明确要求登录",
    "MIGU_MEMBERSHIP_REQUIRED": "咪咕明确返回会员权限要求",
    "MIGU_API_FORMAT_CHANGED": "咪咕接口格式变化，需要更新适配",
    "MIGU_PLAY_URL_FORMAT_CHANGED": "播放地址格式变化，需要更新适配",
    "MIGU_TERMINAL_BLOCKED": "咪咕拒绝当前客户端/终端标识，需上游确认该客户端是否仍被允许",
    "MIGU_COPYRIGHT_SHIELD": "咪咕按节目版权临时屏蔽，节目结束后可能恢复",
    "MIGU_RESOLVE_BURST_LIMIT": "解析请求过于密集，已暂停，稍后重试",
    "NETWORK_ERROR": "网络连接失败或请求超时",
    "TLS_ERROR": "TLS 证书校验失败",
    "EPG_LOADING": "节目单正在后台加载，请稍后刷新",
    "EPG_EMPTY_OR_UNAVAILABLE": "暂未取得有效节目单，请查看节目单状态",
    "LIST_LOADING": "频道列表正在加载，请稍后重试",
    "SOURCE_SNAPSHOT_TOO_OLD": "频道快照已过期，正在尝试原始列表源",
    "EPG_DISABLED": "节目单已关闭",
}
URI_ATTRIBUTE = re.compile(r'(?<![\w-])URI="([^"\r\n]*)"')

class ServiceError(Exception):
    def __init__(self, code, status=503):
        super().__init__(code)
        self.code, self.status = code, status

class Diagnostics:
    """Small per-service ring; only fixed event codes, never exception text/URLs."""
    def __init__(self, clock=time.monotonic):
        self.clock, self.lock = clock, threading.Lock()
        self.events, self.last = deque(maxlen=120), OrderedDict()

    def record(self, code, details=None):
        if not isinstance(code, str) or re.fullmatch(r"[A-Z][A-Z0-9_]{0,79}", code) is None:
            code = "UNCLASSIFIED_ERROR"
        now = self.clock()
        with self.lock:
            if code in self.last and now - self.last[code] < 15:
                return
            self.last[code] = now
            self.last.move_to_end(code)
            while len(self.last) > 64:
                self.last.popitem(last=False)
            line = {"time_utc": m.iso(m.utcnow()), "code": code, "message": EVENT_MESSAGES.get(code, "")}
            if details:
                line['upstream'] = {key: value for key, value in details.items() if key in {'channel_id','api_code','rid','auth_result','logged_in','has_play_url','returned_quality'} and (type(value) is bool or value is None or (isinstance(value,str) and re.fullmatch(r'[A-Z0-9_]{1,80}',value)))}
            self.events.append(line)
        try:
            print(f"[{line['time_utc']}] {code} {line['message']}" + (" " + json.dumps(line["upstream"],ensure_ascii=False,sort_keys=True) if "upstream" in line else ""), flush=True)
        except (OSError, ValueError):
            pass  # A closed app console must not interrupt serving a player.

    def snapshot(self):
        with self.lock:
            return list(self.events)

def read_private(path, limit):
    if path.is_symlink():
        raise ServiceError("CACHE_SYMLINK_NOT_ALLOWED")
    with path.open("rb") as handle:
        raw = handle.read(limit + 1)
    if len(raw) > limit:
        raise ServiceError("CACHE_TOO_LARGE")
    return raw

def load_access_token(directory, variable=None):
    if variable:
        if re.fullmatch(r"[A-Z][A-Z0-9_]{0,63}", variable) is None:
            raise ServiceError("TOKEN_ENV_NAME_INVALID")
        token = os.environ.get(variable, "")
    else:
        path = directory / "access.token"
        try:
            token = read_private(path, 256).decode("ascii").strip()
            if os.name != "nt":
                os.chmod(path, 0o600)
        except FileNotFoundError:
            token = secrets.token_urlsafe(32)
            descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            with os.fdopen(descriptor, "w", encoding="ascii") as handle:
                handle.write(token + "\n")
                handle.flush()
                os.fsync(handle.fileno())
    if TOKEN_PATTERN.fullmatch(token) is None:
        raise ServiceError("TOKEN_MUST_BE_32_TO_128_URLSAFE_CHARACTERS")
    return token

def rewrite_manifest(raw, final_url):
    hls_references(raw, final_url)  # Reject HTML/empty/truncated or non-media catalogues.
    text = raw.decode("utf-8-sig").replace("\r\n", "\n")

    def absolute(value):
        resolved = urljoin(final_url, value)
        m.validate_url(resolved, "media")
        return resolved

    lines = []
    for line in text.splitlines():
        if line and not line.startswith("#"):
            line = absolute(line)
        elif line.startswith("#"):
            line = URI_ATTRIBUTE.sub(lambda match: 'URI="' + absolute(match[1]) + '"', line)
        lines.append(line)
    return ("\n".join(lines) + "\n").encode("utf-8")

class ManifestCache:
    """At most four fetches/eight pending keys; bounded shared results and failures."""
    def __init__(self, client_factory=m.HttpClient, clock=time.monotonic):
        self.client_factory, self.clock = client_factory, clock
        self.lock = threading.RLock()
        self.pool = BoundedExecutor(max_workers=8, thread_name_prefix="migu-manifest")
        self.flights, self.entries = {}, OrderedDict()
        self.closed, self.bytes, self.fetches = False, 0, 0

    def _fetch(self, url):
        client = self.client_factory("media", attempts=1, timeout=8, budget=12)
        raw, _ = client.get(url, limit=512 * 1024)
        if raw is None:
            raise ServiceError("UPSTREAM_UNEXPECTED_304", 502)
        return rewrite_manifest(raw, client.last_url)

    def _finish(self, key, future):
        try:
            data, error = future.result(), None
        except Exception as failure:
            data = b""
            error = str(failure) if isinstance(failure, (m.UpdateError, ServiceError)) else "UPSTREAM_ERROR"
        with self.lock:
            if self.closed or self.flights.get(key) is not future:
                return
            del self.flights[key]
            old = self.entries.pop(key, None)
            self.bytes -= len(old[1]) if old else 0
            self.entries[key] = (self.clock() + (3 if error else 1), data, error)
            self.bytes += len(data)
            while len(self.entries) > 32 or self.bytes > 8 * 1024 * 1024:
                _, removed = self.entries.popitem(last=False)
                self.bytes -= len(removed[1])

    def get(self, url, wait=9):
        key = m.digest(url.encode())
        with self.lock:
            if self.closed:
                raise ServiceError("SERVICE_STOPPING")
            entry = self.entries.get(key)
            if entry and entry[0] > self.clock():
                self.entries.move_to_end(key)
                if entry[2]:
                    raise ServiceError(entry[2], 502)
                return entry[1]
            future = self.flights.get(key)
            if future is None:
                if len(self.flights) >= 8:
                    raise ServiceError("MANIFEST_CAPACITY")
                future = self.pool.submit(self._fetch, url)
                self.flights[key] = future
                self.fetches += 1
                future.add_done_callback(lambda done: self._finish(key, done))
        try:
            data, error = future.result(timeout=wait), None
        except FutureTimeout:
            raise ServiceError("MANIFEST_LOADING") from None
        except CancelledError:
            raise ServiceError("SERVICE_STOPPING") from None
        except (OSError, ValueError, ServiceError) as failure:
            data = b""
            error = str(failure) if isinstance(failure, (m.UpdateError, ServiceError)) else "UPSTREAM_ERROR"
        if error:
            raise ServiceError(error, 502)
        return data

    def close(self):
        with self.lock:
            self.closed = True
        self.pool.shutdown(wait=False, cancel_futures=True)

class Service:
    def __init__(self, store, token, public_base, mode="redirect", manifests=None, require_token=True, epg=None):
        self.store, self.token, self.public_base, self.mode = store, token, public_base.rstrip("/"), mode
        self.manifests = manifests or ManifestCache()
        self.require_token = require_token
        self.diagnostics = Diagnostics()
        self.epg = epg or EpgStore()
        self.runtime = {"network_concurrency": 8, "python": sys.version.split()[0], "platform": sys.platform,
                        "main_thread": threading.current_thread() is threading.main_thread()}

    def catalogue(self, snapshot):
        suffix = "?token=" + self.token if self.require_token else ""
        epg_url = f'{self.public_base}/epg.xml{suffix}'
        header = '#EXTM3U' + (f' x-tvg-url="{epg_url}"' if self.epg.enabled else '')
        if getattr(snapshot.playlist, 'catchup', False):
            header += ' catchup="append" catchup-source="' + ('&' if self.require_token else '?') + CATCHUP_SOURCE[1:] + '"'
        lines = [header]
        for key, channel in snapshot.channels.items():
            logo = f' tvg-logo="{channel.logo}"' if channel.logo else ''
            lines.append(f'#EXTINF:-1 tvg-id="{key}" tvg-name="{channel.name}" group-title="{channel.group}"{logo},{channel.display}')
            lines.append(f'{self.public_base}/live/{key}.m3u8{suffix}')
        return ('\n'.join(lines)+'\n').encode('utf-8')

    def close(self):
        self.store.close()
        self.manifests.close()
        self.epg.close()

class Handler(BaseHTTPRequestHandler):
    server_version = "migu-live/" + VERSION
    sys_version = ""

    def log_message(self, *args):
        pass  # Query strings contain the access token; never use the default access log.

    def send_body(self, status, data=b"", mime="application/json; charset=utf-8", **headers):
        self.send_response(status)
        self.send_header("Content-Type", mime)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header("Connection", "close")
        for name, value in headers.items():
            self.send_header(name.replace("_", "-"), value)
        self.end_headers()
        self.close_connection = True
        if self.command != "HEAD":
            self.wfile.write(data)

    def do_HEAD(self):
        self.do_GET()

    def do_GET(self):
        service = self.server.service
        request_channel_id = None
        try:
            if len(self.path) > 4096:
                raise ServiceError("REQUEST_TOO_LONG", 414)
            parts = urlsplit(self.path)
            query = parse_qs(parts.query, keep_blank_values=True, max_num_fields=4)
            if parts.scheme or parts.netloc or parts.fragment or set(query) - {"token", "playbackbegin", "playbackend"} or any(len(values) != 1 for values in query.values()):
                raise ServiceError("REQUEST_INVALID", 400)
            hosts = self.headers.get_all("Host", [])
            if len(hosts) != 1:
                raise ServiceError("HOST_REQUIRED", 400)
            if not service.require_token:
                port = self.server.server_address[1]
                allowed_hosts = {f"127.0.0.1:{port}", f"localhost:{port}"}
                if port == 80:
                    allowed_hosts |= {"127.0.0.1", "localhost"}
                if hosts[0].lower() not in allowed_hosts:
                    raise ServiceError("LOCAL_HOST_REQUIRED", 403)
                origin = self.headers.get("Origin")
                if (origin and urlsplit(origin).netloc.lower() not in allowed_hosts) or self.headers.get("Sec-Fetch-Site") == "cross-site":
                    raise ServiceError("LOCAL_ORIGIN_REQUIRED", 403)
            authorization = self.headers.get_all("Authorization", [])
            if len(authorization) > 1:
                raise ServiceError("AUTH_REQUIRED", 401)
            bearer = authorization[0].removeprefix("Bearer ") if authorization and authorization[0].startswith("Bearer ") else ""
            query_token = query.get("token", [""])[0]
            supplied = query_token or bearer
            if service.require_token and (not TOKEN_PATTERN.fullmatch(supplied) or not hmac.compare_digest(service.token, supplied) or (bearer and query_token and not hmac.compare_digest(bearer, query_token))):
                raise ServiceError("AUTH_REQUIRED", 401)
            if parts.path == "/diag":
                self.send_body(200, m.json_bytes({"service": "migu-live", "version": VERSION,
                    "runtime": service.runtime, "status": {**service.store.status(), "epg": service.epg.status()}, "events": service.diagnostics.snapshot()}))
                return
            if parts.path in {"/", "/health", "/status"}:
                self.send_body(200, m.json_bytes({"service": "migu-live", "version": VERSION, "process_up": True, "mode": service.mode, "runtime": service.runtime, **service.store.status(), "epg": service.epg.status()}))
                return
            if parts.path == "/epg.xml":
                self.send_body(200, service.epg.get(), "application/xml; charset=utf-8")
                return
            if parts.path not in {"/all.m3u", "/migu.m3u8"} and re.fullmatch(r"/live/[pn][0-9a-f]{1,24}\.m3u8", parts.path) is None:
                raise ServiceError("NOT_FOUND", 404)
            snapshot = service.store.get()
            if parts.path in {"/all.m3u", "/migu.m3u8"}:
                self.send_body(200, service.catalogue(snapshot), "application/vnd.apple.mpegurl; charset=utf-8")
                return
            key = parts.path[len("/live/"):-len(".m3u8")]
            channel = snapshot.channels.get(key)
            if channel is None:
                raise ServiceError("CHANNEL_NOT_FOUND", 404)
            request_channel_id = key[1:] if key.startswith("p") else None
            suffix = ''
            if "playbackbegin" in query or "playbackend" in query:
                if not getattr(snapshot.playlist, 'catchup', False):
                    raise ServiceError("CATCHUP_UNAVAILABLE", 400)
                try:
                    suffix = list_catchup(query)
                except m.UpdateError as failure:
                    raise ServiceError(str(failure),400) from None
            url = service.store.resolve(key) + suffix
            m.validate_url(url, "media")
            if service.mode == "redirect":
                self.send_body(302, Location=url)
            else:
                self.send_body(200, service.manifests.get(url), "application/vnd.apple.mpegurl; charset=utf-8")
        except ServiceError as error:
            if error.status >= 500:
                service.diagnostics.record(error.code)
            self.send_body(error.status, m.json_bytes({"error": error.code}), **({"Retry_After": "3"} if error.status == 503 else {}))
        except m.UpdateError as error:
            details = getattr(error, "details", None)
            log_details = dict(details or {})
            if request_channel_id:
                log_details.setdefault("channel_id", request_channel_id)
            service.diagnostics.record(str(error), log_details)
            code = str(error)
            status = 403 if code in {"MIGU_AUTHORIZATION_REJECTED", "MIGU_LOGIN_REQUIRED", "MIGU_MEMBERSHIP_REQUIRED", "MIGU_REGION_RESTRICTED", "MIGU_TERMINAL_BLOCKED", "MIGU_COPYRIGHT_SHIELD", "MIGU_CLIENT_VERSION_UPGRADE_REQUIRED"} else 429 if code == "MIGU_RESOLVE_BURST_LIMIT" else 404 if code == "EPG_DISABLED" else 503 if code in {"EPG_LOADING", "EPG_UNAVAILABLE", "MIGU_API_LOADING", "MIGU_API_CAPACITY"} or (code.startswith("EPG_") or code.startswith("LIST_") or code in {"SOURCE_SNAPSHOT_TOO_OLD", "TOO_FEW_CHANNELS"}) else 502
            self.send_body(status, m.json_bytes({"error": code, **({"upstream": details} if details else {})}), **({"Retry_After": str(getattr(error, "retry_after", 60)) if status == 429 else "3"} if status in {429,503} else {}))
        except (ValueError, OSError):
            self.send_body(400, m.json_bytes({"error": "REQUEST_OR_IO_ERROR"}))

class BoundedServer(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True
    request_queue_size = 32

    def __init__(self, address, service, max_clients=32):
        if not service.require_token and address[0] != "127.0.0.1":
            raise ServiceError("NON_LOOPBACK_REQUIRES_TOKEN")
        self.service = service
        self.slots = threading.BoundedSemaphore(max_clients)
        self.connections, self.connection_lock = set(), threading.Lock()
        super().__init__(address, Handler)

    def get_request(self):
        sock, address = super().get_request()
        sock.settimeout(10)
        with self.connection_lock:
            self.connections.add(sock)
        return sock, address

    def shutdown_request(self, request):
        with self.connection_lock:
            self.connections.discard(request)
        super().shutdown_request(request)

    def server_close(self):
        super().server_close()
        with self.connection_lock:
            connections = list(self.connections)
            self.connections.clear()
        for connection in connections:
            try:
                connection.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
            connection.close()

    def process_request(self, request, client_address):
        if not self.slots.acquire(blocking=False):
            try:
                request.sendall(b"HTTP/1.1 503 Service Unavailable\r\nContent-Length: 0\r\nConnection: close\r\nRetry-After: 3\r\n\r\n")
            except OSError:
                pass
            self.shutdown_request(request)
            return
        try:
            super().process_request(request, client_address)
        except Exception:
            self.slots.release()
            raise

    def process_request_thread(self, request, client_address):
        try:
            super().process_request_thread(request, client_address)
        finally:
            self.slots.release()

    def handle_error(self, request, client_address):
        pass  # Socket errors must not print a traceback containing request context.

def stop_from_signal(*unused):
    raise KeyboardInterrupt()

def service_data_directory(explicit=None):
    """Never assume the app's current working directory is writable."""
    directory = explicit or Path.home() / ".cache" / "migu-live"
    if directory.is_symlink():
        raise ServiceError("DATA_DIRECTORY_SYMLINK_NOT_ALLOWED")
    directory.mkdir(mode=0o700, parents=True, exist_ok=True)
    with tempfile.TemporaryFile(dir=directory) as handle:
        handle.write(b"probe")
        handle.flush()
    return directory

def startup_error(stage, error):
    code = str(error) if isinstance(error, (ServiceError, m.UpdateError)) else type(error).__name__
    number = getattr(error, "errno", None)
    print(f"Startup failed [{stage}]: {code}" + (f" (errno={number}: {os.strerror(number)})" if number else ""), file=sys.stderr, flush=True)
    if stage == "bind":
        print("端口可能被占用，或当前 App 不允许本地监听；可尝试其他端口。", file=sys.stderr)
    elif stage in {"data-directory", "access-token"}:
        print("请检查访问令牌的可写目录；默认本机模式只使用内存。", file=sys.stderr)

def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("port", type=int, nargs="?", default=DEFAULT_PORT)
    parser.add_argument("--bind", default="127.0.0.1")
    parser.add_argument("--public-base", help="Fixed external HTTP(S) URL")
    parser.add_argument("--data-dir", type=Path, help="Only needed for a persistent service access token")
    parser.add_argument("--token-env", help="Environment variable holding the service access token")
    parser.add_argument("--require-token", action="store_true")
    parser.add_argument("--provider", choices=("list","native","android"), default="android", help="android: direct reference-compatible API (default); native: older API; list: explicit external catalogue")
    parser.add_argument("--list-source", choices=("auto","github","upstream"), default="auto")
    parser.add_argument("--mode", choices=("redirect", "manifest"), default="redirect")
    parser.add_argument("--epg-cache", action="store_true", help="Persist valid programme schedules; fall back to memory if unavailable")
    parser.add_argument("--no-epg", action="store_true", help="Disable the XMLTV feed")
    args = parser.parse_args(argv)
    stage = "configuration"
    try:
        address = ipaddress.IPv4Address(args.bind)
        if not 1 <= args.port <= 65535:
            parser.error("port must be between 1 and 65535")
        base = args.public_base or f"http://{args.bind}:{args.port}"
        parts = urlsplit(base)
        if parts.scheme not in {"http", "https"} or not parts.hostname or parts.username is not None or parts.password is not None or parts.query or parts.fragment or not m.clean_text(base) or any(ch.isspace() or ch in ('"', '<', '>', '\\') for ch in base):
            parser.error("public-base must be a fixed HTTP(S) URL without credentials/query/fragment")
        if not address.is_loopback and not args.public_base:
            parser.error("non-loopback bind requires an explicit --public-base")
        try:
            public_loopback = ipaddress.ip_address(parts.hostname).is_loopback
        except ValueError:
            public_loopback = parts.hostname == "localhost"
        require_token = args.require_token or bool(args.token_env) or not address.is_loopback or not public_loopback
        if require_token and not args.token_env:
            stage = "data-directory"
            args.data_dir = service_data_directory(args.data_dir)
        stage = "access-token"
        token = load_access_token(args.data_dir, args.token_env) if require_token else ""
        cache_path = None
        if args.epg_cache and not args.no_epg:
            try:
                directory = service_data_directory(args.data_dir)
                cache_path = directory / "epg-cache-v1.json"
            except (OSError, ValueError, ServiceError):
                print("[节目单] 缓存目录不可写，继续使用内存模式。", flush=True)
        stage = "provider"
        if args.provider == "list":
            store = ListStore(args.list_source)
        elif args.provider == "android":
            store = AndroidStore()
        else:
            store = NativeStore()
        service = Service(store, token, base, args.mode, require_token=require_token, epg=EpgStore(enabled=not args.no_epg, cache_path=cache_path))
        previous_signal = None
        try:
            stage = "bind"
            server = BoundedServer((args.bind, args.port), service)
            try:
                if threading.current_thread() is threading.main_thread():
                    try:
                        previous_signal = signal.signal(signal.SIGTERM, stop_from_signal)
                    except (OSError, ValueError, AttributeError):
                        print("[系统] 信号接口不可用，请使用 App 停止按钮。", flush=True)
                print(f"migu-live {VERSION}; provider={store.provider}; mode={args.mode}; listening={args.bind}:{args.port}", flush=True)
                print(f"[环境] Python {service.runtime['python']}; system={service.runtime['platform']}; main_thread={threading.current_thread() is threading.main_thread()}", flush=True)
                print("[系统] HTTP 服务启动成功；列表地址在首次订阅时加载，不调用官方匿名播放接口。" if args.provider == "list" else f"[系统] HTTP 服务启动成功；内置频道 {len(store.get().channels)} 个，官方取源按需进行。", flush=True)
                suffix = "?token=<access-token>" if require_token else ""
                for label, path in (("Subscription", "/all.m3u"), ("Diagnostics", "/diag")):
                    print(f"{label}: {base.rstrip('/')}{path}{suffix}", flush=True)
                if not args.no_epg:
                    print(f"EPG: {base.rstrip('/')}/epg.xml{suffix}", flush=True)
                if require_token:
                    print("Token: explicit environment variable" if args.token_env else f"Token file: {args.data_dir / 'access.token'}", flush=True)
                service.diagnostics.record("HTTP_SERVER_STARTED")
                stage = "serve"
                server.serve_forever(poll_interval=0.2)
            finally:
                server.server_close()
                if previous_signal is not None:
                    try:
                        signal.signal(signal.SIGTERM, previous_signal)
                    except (OSError, ValueError):
                        pass
        finally:
            service.close()
    except KeyboardInterrupt:
        print("[系统] 服务已停止，监听端口已释放。", flush=True)
        return 0
    except (OSError, ValueError, ServiceError, RuntimeError, ImportError) as error:
        startup_error(stage, error)
        return 1
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
