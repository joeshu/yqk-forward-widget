#!/usr/bin/env python3
"""Migu dynamic service 0.3.0. Standalone Python 3.10+, standard library only."""
from __future__ import annotations

# Bounded transport and HLS validation: migu/core.py
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from email.utils import parsedate_to_datetime
import hashlib
from http.client import HTTPException
import json
import re
import socket
import ssl
import time
import unicodedata
from urllib.error import HTTPError, URLError
from urllib.parse import unquote, urljoin, urlsplit
from urllib.request import HTTPRedirectHandler, Request, build_opener

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
    if role == "epg":
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


class HttpClient:
    def __init__(self, role="source", attempts=3, timeout=10, budget=45):
        self.role, self.attempts, self.timeout, self.budget = role, attempts, timeout, budget
        self.redirector = RestrictedRedirect(role)
        self.opener = build_opener(self.redirector)  # Inherit proxies and TLS trust.

    def get(self, url, *, headers=None, limit=MAX_BYTES):
        validate_url(url, self.role)
        self.last_url = url
        deadline = time.monotonic() + self.budget
        self.redirector.deadline = deadline
        request_headers = {"User-Agent": "MiguLive/0.3", "Accept-Encoding": "identity"}
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
from queue import Queue, Empty, Full
import threading


class BoundedExecutor:
    def __init__(self, max_workers, thread_name_prefix='migu', max_pending=8):
        self.max_workers, self.prefix = max_workers, thread_name_prefix
        self.queue, self.lock = Queue(max_pending), threading.Lock()
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
                        try: self.queue.get_nowait()[0].cancel()
                        except Empty: break
                    raise
        return future

    def _run(self):
        while True:
            try:
                future, function, args, kwargs = self.queue.get(timeout=.2)
            except Empty:
                if self.closed:
                    return
                continue
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
                    future, _, _, _ = self.queue.get_nowait()
                    future.cancel()
                except Empty:
                    break
        if wait:
            for thread in self.threads:
                if thread is not threading.current_thread():
                    thread.join()

# migu/native.py
from collections import OrderedDict
from concurrent.futures import TimeoutError as FutureTimeout
from dataclasses import dataclass
import hashlib
import json
import re
import threading
import time
from types import MappingProxyType
from urllib.parse import parse_qs, urlsplit


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


def native_play_url(pid, client_factory=m.HttpClient):
    if pid not in {item[0] for item in BUILTIN_CHANNELS}:
        raise m.FetchError("MIGU_UNKNOWN_CHANNEL")
    timestamp = str(int(time.time() * 1000))
    payload = hashlib.md5((timestamp + pid + "26000370").encode()).hexdigest()
    signature = hashlib.md5((payload + "3ce941cc3cbc40528bfd1c64f9fdf6c0migu0123").encode()).hexdigest()
    endpoint = ("https://play.miguvideo.com/playurl/v1/play/playurl"
                f"?contId={pid}&rateType=2&timestamp={timestamp}&salt=1230024&sign={signature}")
    headers = {"AppVersion": "2600037000", "TerminalId": "android",
               "X-UP-CLIENT-CHANNEL-ID": "2600037000-99000-200300220100002"}
    # Do not request FLV, H265, HDR or higher paid quality profiles.
    if pid not in {"641886683", "641886773"}:
        headers["appCode"] = "miguvideo_default_android"
    raw, _ = client_factory("api", attempts=1, timeout=8, budget=10).get(endpoint, headers=headers, limit=256 * 1024)
    try:
        data = json.loads(raw)
        body = data.get("body") or {}
        info = body.get("urlInfo") or {}
        reason = data.get("rid", "")
        if reason == "COPYRIGHT_AREA_INVALID":
            raise m.FetchError("MIGU_REGION_RESTRICTED")
        if reason in {"TIPS_NEED_MEMBER", "NEED_LOGIN", "USER_NOT_LOGIN"} or (body.get("auth") or {}).get("authResult") == "FAIL":
            raise m.FetchError("MIGU_LOGIN_OR_MEMBERSHIP_REQUIRED")
        if str(data.get("code")) != "200":
            raise m.FetchError("MIGU_API_REJECTED")
        url = info.get("url")
        if not isinstance(url, str) or not url:
            raise m.FetchError("MIGU_PLAY_URL_MISSING")
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
        keys = "cdabyzwxkl"
        extra = {1: "v", 2: keys[int(str(m.utcnow().astimezone(m.CHINA).year)[0])], 3: keys[int(pid[6])], 4: "a"}
        proof = "".join(seed[-i-1] + seed[i] + extra.get(i, "") for i in range((len(seed)+1)//2))
        return url + "&ddCalcu=" + proof + "&sv=10004&ct=android"
    except (TypeError, AttributeError, IndexError, json.JSONDecodeError):
        raise m.FetchError("MIGU_API_FORMAT_CHANGED") from None


@dataclass(frozen=True)
class NativeSnapshot:
    playlist: object
    channels: object


class NativeStore:
    """Built-in metadata; bounded, coalesced on-demand resolution, memory only."""
    provider = "migu"

    def __init__(self, resolver=native_play_url, clock=time.monotonic):
        self.resolver, self.clock = resolver, clock
        self.pool = BoundedExecutor(max_workers=4, thread_name_prefix="migu-api")
        self.lock = threading.RLock()
        self.flights, self.entries = {}, OrderedDict()
        self.closed, self.last_error, self.fetches = False, None, 0
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
            url, error = "", str(failure) if isinstance(failure, m.UpdateError) else "MIGU_API_ERROR"
        with self.lock:
            if self.closed or self.flights.get(key) is not future:
                return
            del self.flights[key]
            self.last_error = error
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
                    raise m.FetchError(cached[2])
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
                    "source_transport": "https", "last_error": self.last_error, "api_requests": self.fetches,
                    "playback_verified": False, "quality": "anonymous-SD", "storage": "memory"}

    def close(self):
        with self.lock:
            self.closed = True
        self.pool.shutdown(wait=False, cancel_futures=True)

# migu/epg.py
from concurrent.futures import TimeoutError as FutureTimeout, CancelledError, as_completed
from datetime import datetime, timedelta, timezone
import json
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
    def __init__(self, client_factory=m.HttpClient, clock=time.monotonic, enabled=True):
        self.client_factory, self.clock, self.enabled = client_factory, clock, enabled
        self.lock, self.ready = threading.RLock(), threading.Event()
        self.pool = BoundedExecutor(1, thread_name_prefix='migu-epg-refresh', max_pending=1)
        self.downloads = BoundedExecutor(4, thread_name_prefix='migu-epg', max_pending=4)
        self.future, self.closed, self.data = None, False, None
        self.details, self.latest, self.last_error, self.updated = {}, None, None, None
        self.fresh_until, self.retry_at, self.valid_until = 0, 0, 0
        self.rows, self.day = {}, None
        self.attempts = {}
        self.upstream_error = None

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

    def _refresh(self, day):
        try:
            if self.day != day:
                self.rows, self.attempts, self.day = {}, {}, day
            failures = 0
            deadline = time.monotonic() + 120
            pending = [pid for pid, _, _ in BUILTIN_CHANNELS if self.clock() >= self.attempts.get(pid, 0)]
            for index in range(0, len(pending), 4):
                if self.closed or time.monotonic() >= deadline:
                    break
                batch = {self.downloads.submit(self._fetch, pid, day): pid for pid in pending[index:index+4]}
                completed = set()
                try:
                    for future in as_completed(batch, timeout=8):
                        pid = batch[future]
                        completed.add(future)
                        try:
                            rows = future.result()
                            self.rows[pid] = rows
                            self.attempts[pid] = self.clock() + (6*3600 if rows else 15*60)
                            if self.data is None and rows:
                                try:
                                    self._publish()  # A slow sibling must not hide ready programmes.
                                except m.UpdateError:
                                    pass
                        except Exception as failure:
                            failures += 1
                            with self.lock:
                                self.upstream_error = str(failure) if isinstance(failure, m.UpdateError) else 'EPG_FETCH_ERROR'
                            self.attempts[pid] = self.clock() + 15*60
                except FutureTimeout:
                    for future in set(batch)-completed:
                        future.cancel()
                        self.attempts[batch[future]] = self.clock() + 15*60
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
            return {'enabled': self.enabled, 'source': 'migu-official', 'ready': self._usable(),
                    'refreshing': self.future is not None, 'updated_utc': self.updated,
                    'last_error': self.last_error, 'upstream_error': self.upstream_error, **self.details}

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


VERSION = "0.3.0"
DEFAULT_PORT = 18768
TOKEN_PATTERN = re.compile(r"[A-Za-z0-9_-]{32,128}")
EVENT_MESSAGES = {
    "HTTP_SERVER_STARTED": "本地 HTTP 服务已启动",
    "MIGU_REGION_RESTRICTED": "咪咕限制当前出口地区",
    "MIGU_LOGIN_OR_MEMBERSHIP_REQUIRED": "当前匿名模式没有所需登录或会员权限",
    "MIGU_API_FORMAT_CHANGED": "咪咕接口格式变化，需要更新适配",
    "MIGU_PLAY_URL_FORMAT_CHANGED": "播放地址格式变化，需要更新适配",
    "NETWORK_ERROR": "网络连接失败或请求超时",
    "TLS_ERROR": "TLS 证书校验失败",
    "EPG_LOADING": "节目单正在后台加载，请稍后刷新",
    "EPG_EMPTY_OR_UNAVAILABLE": "暂未取得有效节目单，请查看节目单状态",
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

    def record(self, code):
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
            self.events.append(line)
        try:
            print(f"[{line['time_utc']}] {code} {line['message']}", flush=True)
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
        self.pool = BoundedExecutor(max_workers=4, thread_name_prefix="migu-manifest")
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
        self.runtime = {"python": sys.version.split()[0], "platform": sys.platform,
                        "main_thread": threading.current_thread() is threading.main_thread()}

    def catalogue(self, snapshot):
        suffix = "?token=" + self.token if self.require_token else ""
        epg_url = f'{self.public_base}/epg.xml{suffix}'
        header = '#EXTM3U' + (f' x-tvg-url="{epg_url}"' if self.epg.enabled else '')
        lines = [header]
        for key, channel in snapshot.channels.items():
            lines.append(f'#EXTINF:-1 tvg-id="{key}" tvg-name="{channel.name}" group-title="{channel.group}",{channel.display}')
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
            if "playbackbegin" in query or "playbackend" in query:
                raise ServiceError("CATCHUP_UNAVAILABLE", 400)
            url = service.store.resolve(key)
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
            service.diagnostics.record(str(error))
            code = str(error)
            status = 404 if code == "EPG_DISABLED" else 503 if code in {"EPG_LOADING", "EPG_UNAVAILABLE", "MIGU_API_LOADING", "MIGU_API_CAPACITY"} or code.startswith("EPG_") else 502
            self.send_body(status, m.json_bytes({"error": code}), **({"Retry_After": "3"} if status == 503 else {}))
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
    parser.add_argument("--mode", choices=("redirect", "manifest"), default="redirect")
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
        stage = "provider"
        service = Service(NativeStore(), token, base, args.mode, require_token=require_token, epg=EpgStore(enabled=not args.no_epg))
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
                print(f"migu-live {VERSION}; provider=official-api; mode={args.mode}; listening={args.bind}:{args.port}", flush=True)
                print(f"[环境] Python {service.runtime['python']}; system={service.runtime['platform']}; main_thread={threading.current_thread() is threading.main_thread()}", flush=True)
                print(f"[系统] HTTP 服务启动成功；内置频道 {len(service.store.get().channels)} 个，官方取源按需进行。", flush=True)
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
