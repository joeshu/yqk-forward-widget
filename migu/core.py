"""Minimal bounded transport and HLS/catalogue helpers for the native service."""
from __future__ import annotations
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
from migu.workers import BoundedExecutor
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
