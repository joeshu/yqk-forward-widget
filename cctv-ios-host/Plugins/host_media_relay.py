"""Bounded streaming relay for source-supplied playback HTTP headers.

HLS children and key/map URIs inherit the source's headers. No stream is downloaded
in full, no TS cache is created, and arbitrary client-provided target URLs are not
accepted: every target must have been registered by a playback/manifest result.
"""
import base64
import collections
import http.client
import json
import re
import socket
import ssl
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from host_media_url import http_url
from host_dash import DashSession
import uuid
import zlib


def ll_hls_upstream_url(url, request_path):
    """Forward current LL-HLS delivery directives, preserving signed query bytes."""
    if not isinstance(request_path, str):
        return url
    incoming = urllib.parse.parse_qs(urllib.parse.urlsplit(request_path).query, max_num_fields=32)
    controls = {}
    for name in ('_HLS_msn', '_HLS_part', '_HLS_skip'):
        values = incoming.get(name)
        if not values:
            continue
        if len(values) != 1 or len(values[0]) > 20:
            raise ValueError('invalid_ll_hls_directive')
        value = values[0]
        if (name == '_HLS_skip' and value not in ('YES', 'v2')) or (name != '_HLS_skip' and not value.isascii()) or (name != '_HLS_skip' and not value.isdigit()):
            raise ValueError('invalid_ll_hls_directive')
        controls[name] = value
    parts = urllib.parse.urlsplit(url)
    delivery_controls = ('_HLS_msn', '_HLS_part', '_HLS_skip')
    # A manifest URL may itself contain directives from a previous reload.
    # Drop all three before adding this request's current set, otherwise stale
    # part/skip values can conflict with the newer media sequence.
    query = '&'.join(item for item in parts.query.split('&') if item and urllib.parse.unquote(item.split('=', 1)[0]) not in delivery_controls)
    if controls:
        query += ('&' if query else '') + urllib.parse.urlencode(controls)
    if query == parts.query:
        return url
    return urllib.parse.urlunsplit(parts._replace(query=query))


_CROSS_ORIGIN_SAFE_HEADERS = frozenset((
    'accept', 'accept-encoding', 'accept-language', 'cache-control',
    'if-range', 'range', 'user-agent',
))


def _origin_identity(value):
    """Return an effective HTTP origin, including default-port normalization."""
    if isinstance(value, tuple) and len(value) == 2:
        scheme, authority = value
        parsed = urllib.parse.urlsplit(str(scheme) + '://' + str(authority))
    elif isinstance(value, str):
        parsed = urllib.parse.urlsplit(value)
    else:
        return None
    scheme = parsed.scheme.lower()
    host = (parsed.hostname or '').lower()
    try:
        port = parsed.port
    except ValueError:
        return None
    if port is None:
        port = {'http': 80, 'https': 443}.get(scheme)
    return (scheme, host, port) if scheme and host else None


def scoped_headers(headers, origin, url):
    """Keep source-specific headers on their origin and safe transport headers elsewhere."""
    if _origin_identity(origin) == _origin_identity(url):
        return dict(headers)
    return {name: value for name, value in headers.items()
            if name.lower() in _CROSS_ORIGIN_SAFE_HEADERS}


class ScopedRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, response, code, message, headers, new_url):
        new_url = http_url(new_url)
        redirected = super().redirect_request(request, response, code, message, headers, new_url)
        # urllib creates a fresh Request without a method on redirects, which
        # turns HEAD into GET and can download the media during a probe.
        if redirected is not None and request.get_method() == 'HEAD':
            redirected.method = 'HEAD'
        if redirected is not None and _origin_identity(request.full_url) != _origin_identity(new_url):
            for name in list(redirected.headers):
                if name.lower() not in _CROSS_ORIGIN_SAFE_HEADERS:
                    redirected.remove_header(name)
        return redirected


class RelayClientDisconnected(Exception):
    pass


class RelayFailure(Exception):
    def __init__(self, stage):
        super().__init__(stage)
        self.stage = stage


def _transient_open_timeout(error):
    if isinstance(error, urllib.error.HTTPError):
        return False
    reason = error.reason if isinstance(error, urllib.error.URLError) else error
    if isinstance(reason, (TimeoutError, socket.timeout)):
        return True
    return isinstance(reason, ssl.SSLError) and 'timed out' in str(reason).lower()


def _retry_request(request):
    headers = dict(request.header_items())
    headers.update(getattr(request, 'unredirected_hdrs', {}))
    return urllib.request.Request(
        request.full_url, data=request.data, headers=headers,
        origin_req_host=request.origin_req_host, unverifiable=request.unverifiable,
        method=request.get_method())


def _configure_tolerant_ssl_context(ctx):
    for flag_name in ('OP_IGNORE_UNEXPECTED_EOF', 'OP_LEGACY_SERVER_CONNECT'):
        flag = getattr(ssl, flag_name, 0)
        if flag:
            try:
                ctx.options |= flag
            except Exception:
                pass
    return ctx


_DEFAULT_SSL_CONTEXT = _configure_tolerant_ssl_context(ssl.create_default_context())


def _tune_raw_socket(sock):
    if sock is None:
        return
    try:
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 524288)
        sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
    except (OSError, AttributeError):
        pass


class UpstreamConnectionPool:
    """Thread-safe HTTP/1.1 Keep-Alive connection pool keyed by (scheme, host, timeout)."""

    def __init__(self, max_per_host=6, idle_timeout=45.0):
        self._lock = threading.Lock()
        self._pools = collections.defaultdict(collections.deque)
        self._max_per_host = max(1, int(max_per_host))
        self._idle_timeout = float(idle_timeout)
        self.reused_count = 0
        self.created_count = 0

    @staticmethod
    def _is_socket_ready(conn):
        sock = getattr(conn, 'sock', None)
        if sock is None:
            return False
        try:
            if sock.fileno() < 0:
                return False
        except Exception:
            return False
        return getattr(conn, '_HTTPConnection__response', None) is None

    def acquire(self, scheme, host, http_class, timeout, http_conn_args):
        ctx_id = id(http_conn_args.get('context')) if http_conn_args and 'context' in http_conn_args else 0
        key = (scheme.lower(), host.lower(), ctx_id)
        eff_timeout = None if timeout is socket._GLOBAL_DEFAULT_TIMEOUT else timeout
        now = time.monotonic()
        with self._lock:
            bucket = self._pools.get(key)
            while bucket:
                conn, ts = bucket.pop()
                if now - ts < self._idle_timeout and self._is_socket_ready(conn):
                    conn.timeout = timeout
                    if getattr(conn, 'sock', None) is not None:
                        try:
                            conn.sock.settimeout(eff_timeout)
                        except Exception:
                            pass
                    self.reused_count += 1
                    return conn, True, key
                try:
                    conn.close()
                except Exception:
                    pass
        conn = http_class(host, timeout=timeout, **http_conn_args)
        self.created_count += 1
        return conn, False, key

    def release(self, key, conn):
        if conn is None or not self._is_socket_ready(conn):
            try:
                if conn is not None:
                    conn.close()
            except Exception:
                pass
            return
        with self._lock:
            bucket = self._pools[key]
            while len(bucket) >= self._max_per_host:
                old, _ = bucket.popleft()
                try:
                    old.close()
                except Exception:
                    pass
            bucket.append((conn, time.monotonic()))

    def clear(self):
        with self._lock:
            pools = list(self._pools.values())
            self._pools.clear()
        for bucket in pools:
            while bucket:
                conn, _ = bucket.popleft()
                try:
                    conn.close()
                except Exception:
                    pass


_UPSTREAM_POOL = UpstreamConnectionPool()


def _attach_pooled_lifecycle(response, conn, pool_key, pool, method):
    orig_close_conn = response._close_conn
    orig_close = response.close
    state = {'released': False, 'aborted': False}

    def pooled_close_conn():
        can_reuse = (
            not state['aborted']
            and not getattr(response, 'will_close', True)
            and (
                method == 'HEAD'
                or getattr(response, 'length', None) == 0
                or (getattr(response, 'chunked', False) and getattr(response, 'chunk_left', None) == 0)
            )
        )
        orig_close_conn()
        if not state['released']:
            state['released'] = True
            if can_reuse:
                # Clear http.client internal response pointer so the connection can send again.
                try:
                    conn._HTTPConnection__response = None
                    conn._HTTPConnection__state = http.client._CS_IDLE
                except Exception:
                    pass
                pool.release(pool_key, conn)
            else:
                try:
                    conn.close()
                except Exception:
                    pass

    def pooled_close():
        if getattr(response, 'fp', None) is not None and getattr(response, 'length', None) not in (0, None):
            state['aborted'] = True
        try:
            orig_close()
        finally:
            if not state['released']:
                state['released'] = True
                try:
                    conn.close()
                except Exception:
                    pass

    response._close_conn = pooled_close_conn
    response.close = pooled_close
    return response


class _KeepAliveHandlerMixin:
    _scheme = 'http'

    def do_open(self, http_class, req, **http_conn_args):
        host = req.host
        if not host:
            raise urllib.error.URLError('no host given')
        headers = dict(req.unredirected_hdrs)
        headers.update({k: v for k, v in req.headers.items() if k not in headers})
        headers['Connection'] = 'keep-alive'
        headers = {name.title(): val for name, val in headers.items()}
        method = req.get_method().upper()
        for attempt in range(2):
            conn, reused, pool_key = _UPSTREAM_POOL.acquire(
                self._scheme, host, http_class, req.timeout, http_conn_args)
            conn.set_debuglevel(self._debuglevel)
            if req._tunnel_host:
                tunnel_headers = {}
                proxy_auth_hdr = 'Proxy-Authorization'
                if proxy_auth_hdr in headers:
                    tunnel_headers[proxy_auth_hdr] = headers.pop(proxy_auth_hdr)
                conn.set_tunnel(req._tunnel_host, headers=tunnel_headers)
            try:
                conn.request(req.get_method(), req.selector, req.data, headers,
                             encode_chunked=req.has_header('Transfer-encoding'))
                r = conn.getresponse()
                _tune_raw_socket(getattr(conn, 'sock', None))
                break
            except (http.client.RemoteDisconnected, BrokenPipeError, ConnectionResetError,
                    http.client.CannotSendRequest, http.client.ResponseNotReady, OSError) as err:
                try:
                    conn.close()
                except Exception:
                    pass
                if reused and attempt == 0:
                    continue
                if isinstance(err, OSError):
                    raise urllib.error.URLError(err) from err
                raise
            except BaseException:
                try:
                    conn.close()
                except Exception:
                    pass
                raise
        _attach_pooled_lifecycle(r, conn, pool_key, _UPSTREAM_POOL, method)
        r.url = req.get_full_url()
        r.msg = r.reason
        return r


class KeepAliveHTTPHandler(_KeepAliveHandlerMixin, urllib.request.HTTPHandler):
    _scheme = 'http'


class KeepAliveHTTPSHandler(_KeepAliveHandlerMixin, urllib.request.HTTPSHandler):
    _scheme = 'https'

    def __init__(self, debuglevel=0, context=None, check_hostname=None):
        super().__init__(debuglevel=debuglevel, context=context, check_hostname=check_hostname)


_ORIG_BUILD_OPENER = urllib.request.build_opener
_DEFAULT_OPENER = _ORIG_BUILD_OPENER(
    ScopedRedirect(),
    KeepAliveHTTPHandler(),
    KeepAliveHTTPSHandler(context=_DEFAULT_SSL_CONTEXT),
)


def _tune_response_socket(resp):
    try:
        raw_fp = getattr(getattr(resp, 'fp', None), 'raw', None)
        sock = getattr(raw_fp, '_sock', None)
        if sock is not None:
            sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 524288)
            sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
    except (OSError, AttributeError):
        pass
    return resp


def _open_with_timeout_retry(request, diagnostic_id=''):
    """Retry a transient GET/HEAD timeout once, preserving TLS verification."""
    method = request.get_method().upper()
    use_cached_opener = urllib.request.build_opener is _ORIG_BUILD_OPENER
    opener = _DEFAULT_OPENER if use_cached_opener else urllib.request.build_opener(
        ScopedRedirect(), urllib.request.HTTPSHandler(context=_DEFAULT_SSL_CONTEXT))
    try:
        return _tune_response_socket(opener.open(request, timeout=8))
    except (TimeoutError, socket.timeout, urllib.error.URLError) as error:
        if method not in ('GET', 'HEAD') or not _transient_open_timeout(error):
            raise
        parsed = urllib.parse.urlsplit(request.full_url)
        print('[CCTVHostMediaRelay] ' + json.dumps({
            'event': 'media_relay_retry',
            'request_id': diagnostic_id or uuid.uuid4().hex,
            'stage': 'upstream_timeout',
            'attempt': 2,
            'retry_timeout_ms': 2000,
            'method': method,
            'upstream_host': parsed.hostname or '',
        }, separators=(',', ':')))
        time.sleep(0.15)
        retry_opener = _DEFAULT_OPENER if use_cached_opener else urllib.request.build_opener(
            ScopedRedirect(), urllib.request.HTTPSHandler(context=_DEFAULT_SSL_CONTEXT))
        return _tune_response_socket(retry_opener.open(_retry_request(request), timeout=2))


def safe_error_summary(error):
    text = str(error or '')
    text = re.sub(r'(?i)https?://[^\s\"\'<>]+', '[URL redacted]', text)
    text = re.sub(r'(?i)([?&][^=&#\s]*(?:access[_-]?token|refresh[_-]?token|token|auth|signature|sign|ticket|api[_-]?key|secret|password|cookie|session|credential)[^=&#\s]*=)[^&#\s]*', r'\1[redacted]', text)
    text = re.sub(r'(?i)(/(?:live|movie|series)/)[^/?#\s]+/[^/?#\s]+/', r'\1[redacted]/[redacted]/', text)
    text = re.sub(r'(?i)/(?:private/var|var/mobile|Users)/[^\s,;]+', '[path redacted]', text)
    return text[:180]


class MediaRelay:
    def __init__(self, limit=256, segment_limit=16384, stream_media=False, speculative_warmup=None):
        self.limit = limit
        self.stream_media = bool(stream_media)
        self.speculative_warmup = speculative_warmup
        self.targets = collections.OrderedDict()
        self.segments = collections.OrderedDict()
        self.segment_index = {}
        self.segment_limit = max(1, min(int(segment_limit), 16384))
        self.lock = threading.Lock()
        self.refreshing = {}
        # Share only an in-progress declared-HLS fetch, never a retained live
        # playlist. The exact token/URL/headers/server isolate playback scopes.
        self.manifest_flights = {}
        self.refreshFailures = {}
        self.diagnosed_manifests = set()
        self.diagnosed_resources = collections.OrderedDict()
        self.inline_keys = collections.OrderedDict()
        self.remote_key_cache = collections.OrderedDict()
        self.remote_map_cache = collections.OrderedDict()
        self.prefetched_segment_streams = collections.OrderedDict()
        self.inline_manifests = collections.OrderedDict()
        self.dash_playlists = collections.OrderedDict()
        self.responses = set()
        self.stopping = threading.Event()

    @staticmethod
    def _normalize_hls_key_bytes(raw):
        if not isinstance(raw, (bytes, bytearray)):
            return b''
        data = bytes(raw)
        if len(data) == 16:
            return data
        stripped = data.strip()
        if stripped.startswith(b'{') and stripped.endswith(b'}'):
            try:
                obj = json.loads(stripped.decode('utf-8', errors='ignore'))
                if isinstance(obj, dict):
                    cand = obj.get('key') or obj.get('data') or obj.get('k') or ''
                    if isinstance(cand, str) and cand:
                        stripped = cand.strip().encode('ascii', errors='ignore')
            except Exception:
                pass
        if stripped.lower().startswith(b'0x'):
            stripped = stripped[2:]
        if len(stripped) == 32 and re.fullmatch(rb'[0-9a-fA-F]{32}', stripped):
            try:
                return bytes.fromhex(stripped.decode('ascii'))
            except Exception:
                pass
        if 20 <= len(stripped) <= 28:
            try:
                padded = stripped + b'=' * ((4 - len(stripped) % 4) % 4)
                dec = base64.urlsafe_b64decode(padded) if (b'-' in stripped or b'_' in stripped) else base64.b64decode(padded)
                if len(dec) == 16:
                    return dec
            except Exception:
                pass
        return data

    @classmethod
    def _decode_inline_hls_key_uri(cls, uri):
        if not isinstance(uri, str):
            return None
        s = uri.strip()
        low = s.lower()
        if low.startswith('data:'):
            _, sep, payload = s.partition(',')
            if not sep or not payload:
                return None
            if ';base64' in low.partition(',')[0]:
                try:
                    raw = base64.b64decode( urllib.parse.unquote(payload) )
                    norm = cls._normalize_hls_key_bytes(raw)
                    return norm if len(norm) == 16 else None
                except Exception:
                    return None
            norm = cls._normalize_hls_key_bytes(urllib.parse.unquote_to_bytes(payload))
            return norm if len(norm) == 16 else None
        if low.startswith('base64:'):
            norm = cls._normalize_hls_key_bytes(s[7:].strip().encode('ascii', errors='ignore'))
            return norm if len(norm) == 16 else None
        if low.startswith('hex:'):
            norm = cls._normalize_hls_key_bytes(s[4:].strip().encode('ascii', errors='ignore'))
            return norm if len(norm) == 16 else None
        return None

    def register_inline_key(self, key_bytes, diagnostic_id=None, resource_scope=None):
        raw = self._normalize_hls_key_bytes(key_bytes)
        with self.lock:
            if self.stopping.is_set():
                raise RuntimeError('媒体代理正在停止')
            token = uuid.uuid4().hex
            self.inline_keys[token] = (raw, str(diagnostic_id or '')[:96], str(resource_scope or '')[:96])
            while len(self.inline_keys) > 256:
                self.inline_keys.popitem(last=False)
            return token

    def register_inline_manifest(self, manifest_text, base_url, headers=None, diagnostic_id=None, resource_scope=None):
        text = str(manifest_text or '').lstrip('\ufeff').lstrip()
        if not text.startswith('#EXTM3U'):
            raise ValueError('无效的内联 HLS 清单')
        base_str = str(base_url or 'https://localhost/playlist.m3u8').strip()
        parsed = urllib.parse.urlsplit(base_str)
        if parsed.scheme.lower() not in ('http', 'https') or not parsed.hostname:
            base_str = 'https://localhost/playlist.m3u8'
            parsed = urllib.parse.urlsplit(base_str)
        origin = (parsed.scheme.lower(), parsed.netloc.lower())
        safe_headers = self._safe_refresh_headers(headers or {})
        with self.lock:
            if self.stopping.is_set():
                raise RuntimeError('媒体代理正在停止')
            token = uuid.uuid4().hex
            self.inline_manifests[token] = (
                text, base_str, safe_headers, origin,
                str(diagnostic_id or '')[:96], str(resource_scope or diagnostic_id or '')[:96]
            )
            while len(self.inline_manifests) > 64:
                self.inline_manifests.popitem(last=False)
            return token

    @staticmethod
    def _unwrap_rou_png_bytes(data):
        if not data or len(data) < 20 or data[:8] != b'\x89PNG\r\n\x1a\n':
            return None
        offset = 8
        size = len(data)
        found = None
        for _ in range(4096):
            if offset + 12 > size:
                break
            length = int.from_bytes(data[offset:offset + 4], 'big')
            if length > size - offset - 12:
                break
            chunk_type = data[offset + 4:offset + 8]
            if chunk_type == b'roUd' and length >= 2:
                flags = data[offset + 8]
                payload = data[offset + 9:offset + 8 + length]
                if flags == 0:
                    found = payload
                elif flags == 1:
                    # Bound decoded bytes as well as downloaded PNG bytes. A
                    # tiny compressed chunk can otherwise exhaust App memory.
                    for candidate in (payload, payload[3:]):
                        try:
                            decoder = zlib.decompressobj()
                            decoded = decoder.decompress(candidate, 16 * 1024 * 1024 + 1)
                            if len(decoded) > 16 * 1024 * 1024 or not decoder.eof:
                                return None
                            found = decoded
                            break
                        except zlib.error:
                            continue
                    else:
                        return None
            offset += length + 12
            if chunk_type == b'IEND':
                return found
        return found

    @staticmethod
    def _strip_disguised_ts_prefix(chunk):
        if not chunk or len(chunk) < 380:
            return chunk
        if chunk[0] == 0x47:
            return chunk
        if chunk[:3] == b'ID3' or chunk[:2] in (b'\xff\xf1', b'\xff\xf9') or chunk[:7] == b'#EXTM3U':
            return chunk
        if len(chunk) >= 8 and chunk[4:8] in (b'ftyp', b'styp', b'moof', b'moov', b'sidx', b'emsg', b'free', b'skip', b'mdat'):
            return chunk
        limit = min(len(chunk) - 376, 16384)
        pos = chunk.find(0x47, 1, limit)
        while 0 < pos < limit:
            if chunk[pos + 188] == 0x47 and chunk[pos + 376] == 0x47:
                return chunk[pos:]
            pos = chunk.find(0x47, pos + 1, limit)
        return chunk

    def register(self, url, headers, origin=None, diagnostic_id=None, fallback_url=None,
                 refresh=None, refresh_after=0, refresh_interval=0, refresh_relative=None,
                 expected_hls=False, segment=False, resource_kind="media", resource_scope=None):
        url = http_url(url)
        if fallback_url:
            fallback_url = http_url(fallback_url)
        parsed = urllib.parse.urlsplit(url)
        if parsed.scheme.lower() not in ('http', 'https') or not parsed.hostname or parsed.username or parsed.password:
            raise ValueError('不支持的媒体地址')
        if fallback_url:
            fallback = urllib.parse.urlsplit(fallback_url)
            if (fallback.scheme.lower() not in ('http', 'https') or not fallback.hostname or
                    fallback.username or fallback.password or
                    (fallback.scheme.lower(), fallback.netloc.lower()) !=
                    (parsed.scheme.lower(), parsed.netloc.lower())):
                fallback_url = None
        diagnostic_id = str(diagnostic_id or '')[:96]
        if not re.fullmatch(r'[A-Za-z0-9._-]{1,96}', diagnostic_id):
            diagnostic_id = ''
        resource_scope = str(resource_scope or diagnostic_id)[:96]
        if resource_scope and not re.fullmatch(r"[A-Za-z0-9._-]{1,96}", resource_scope): resource_scope = ""
        origin = origin or (parsed.scheme.lower(), parsed.netloc.lower())
        key = (url, tuple(sorted(headers.items())), origin, fallback_url, diagnostic_id,
               bool(expected_hls), resource_kind if resource_kind in ("key", "map", "media") else "media", resource_scope)
        refresh = refresh if callable(refresh) else None
        refresh_after = float(refresh_after or 0)
        refresh_interval = max(0.0, min(float(refresh_interval or 0), 3600.0))
        refresh_relative = str(refresh_relative)[:2048] if isinstance(refresh_relative, str) else None
        with self.lock:
            if self.stopping.is_set():
                raise RuntimeError('媒体代理正在停止')
            if segment:
                existing = self.segment_index.get(key)
                if existing in self.segments:
                    self.segments.move_to_end(existing)
                    return existing
                token = uuid.uuid4().hex
                self.segments[token] = (key, time.monotonic(), diagnostic_id, None, 0, 0, None)
                self.segment_index[key] = token
                while len(self.segments) > self.segment_limit:
                    removed, old = self.segments.popitem(last=False)
                    self.segment_index.pop(old[0], None)
                return token
            for token, record in self.targets.items():
                if record[0] == key:
                    self.targets[token] = (key, record[1], diagnostic_id,
                        refresh or record[3], refresh_after or record[4],
                        refresh_interval or record[5], refresh_relative or record[6])
                    self.targets.move_to_end(token)
                    return token
            token = uuid.uuid4().hex
            self.targets[token] = (key, time.monotonic(), diagnostic_id, refresh,
                                   refresh_after, refresh_interval, refresh_relative)
            while len(self.targets) > self.limit:
                removed, _ = self.targets.popitem(last=False)
                self.refreshFailures.pop(removed, None)
                self.diagnosed_manifests.discard(removed)
            return token

    def register_dash(self, url, headers, diagnostic_id='', resource_scope='', validate=True):
        session = DashSession(self, url, headers, diagnostic_id, resource_scope)
        # Validate before returning HLS metadata. Unsupported MPDs can still be
        # handed to the original DASH engine by the caller.
        if validate:
            session.load()
        token = uuid.uuid4().hex
        with self.lock:
            if self.stopping.is_set():
                raise ValueError('dash_service_stopping')
            self.dash_playlists[token] = (session, None)
            while len(self.dash_playlists) > 256:
                self.dash_playlists.popitem(last=False)
        return token

    def dash_track_url(self, session, track_id, base):
        with self.lock:
            if self.stopping.is_set():
                raise ValueError('dash_service_stopping')
            token = session.tokens.get(track_id)
            if token not in self.dash_playlists:
                token = uuid.uuid4().hex
                session.tokens[track_id] = token
                self.dash_playlists[token] = (session, track_id)
                while len(self.dash_playlists) > 256:
                    self.dash_playlists.popitem(last=False)
            else:
                self.dash_playlists.move_to_end(token)
        return base + '/media/' + token

    def read_dash_manifest(self, url, headers, diagnostic_id):
        headers = {k: v for k, v in headers.items() if k.lower() not in ('range', 'accept-encoding')}
        request = urllib.request.Request(http_url(url), headers={**headers, 'Accept-Encoding': 'identity'})
        response = _open_with_timeout_retry(request, diagnostic_id)
        with self.lock:
            if self.stopping.is_set():
                response.close()
                raise ValueError('dash_service_stopping')
            self.responses.add(response)
        try:
            data = response.read(2 * 1024 * 1024 + 1)
            return data, response.geturl()
        finally:
            with self.lock:
                self.responses.discard(response)
            response.close()

    @staticmethod
    def _same_origin(left, right):
        return (left.scheme.lower(), left.netloc.lower()) == (right.scheme.lower(), right.netloc.lower())

    @staticmethod
    def _with_query(url, query):
        parts = urllib.parse.urlsplit(url)
        return urllib.parse.urlunsplit((parts.scheme, parts.netloc, parts.path, query, parts.fragment))

    def rewrite(self, text, url, headers, origin, base, diagnostic_id=None,
                refresh=None, refresh_after=0, refresh_interval=0,
                refresh_relative_base=None, resource_scope=None):
        parent = urllib.parse.urlsplit(url)
        # Delivery directives apply to manifest reloads, not media/key requests.
        inherited_query = '&'.join(item for item in parent.query.split('&') if item and urllib.parse.unquote(item.split('=', 1)[0]) not in ('_HLS_msn', '_HLS_part', '_HLS_skip'))
        segment_count = 0
        warmup_key_token = None
        warmup_map_token = None
        warmup_segment_token = None

        def local(value, manifest=False, resource_kind="media"):
            nonlocal segment_count, warmup_key_token, warmup_map_token, warmup_segment_token
            if isinstance(value, str):
                value = re.sub(r'(?i)&(?:amp|#0*38|#x0*26);', '&', value.strip())
            if resource_kind == "key":
                inline_key = self._decode_inline_hls_key_uri(value)
                if inline_key is not None:
                    token = self.register_inline_key(inline_key, diagnostic_id, resource_scope)
                    return base + '/media/' + token
            target = urllib.parse.urljoin(url, value)
            resolved = urllib.parse.urlsplit(target)
            # Preserve signed query parameters for same-origin HLS children.
            # Cross-origin references and children with their own query keep
            # their source-authored URL unchanged to avoid credential leaks.
            fallback_url = None
            if inherited_query and not resolved.query and self._same_origin(parent, resolved):
                fallback_url = target
                target = self._with_query(target, inherited_query)
            if resolved.scheme.lower() not in ('http', 'https') or not resolved.hostname:
                return value
            is_manifest=manifest or resolved.path.lower().endswith(('.m3u8','.m3u'))
            if not is_manifest:
                segment_count += 1
                if segment_count > self.segment_limit:
                    raise RelayFailure('manifest_entries_exceeded')
            relative=value if is_manifest and not urllib.parse.urlsplit(value).scheme and not value.startswith('//') else None
            if relative and refresh_relative_base:
                relative=urllib.parse.urljoin(refresh_relative_base,relative)
            token = self.register(target, headers, origin, diagnostic_id, fallback_url,
                refresh=refresh if is_manifest else None,
                refresh_after=refresh_after if is_manifest else 0,
                refresh_interval=refresh_interval if is_manifest else 0,
                refresh_relative=relative, expected_hls=is_manifest, segment=not is_manifest, resource_kind=resource_kind, resource_scope=resource_scope)
            if not is_manifest:
                if resource_kind == 'key' and warmup_key_token is None:
                    warmup_key_token = token
                elif resource_kind == 'map' and warmup_map_token is None:
                    warmup_map_token = token
                elif resource_kind == 'media' and warmup_segment_token is None:
                    warmup_segment_token = token
            return base + '/media/' + token
        lines = []
        variant_pending = False
        for line in text.splitlines():
            if line.startswith('#'):
                # HLS identifies playlists by tag semantics, not URL suffix.
                # Keys/maps/parts remain byte resources even on PHP endpoints.
                tag = line.split(':', 1)[0]
                uri_manifest = tag in ('#EXT-X-MEDIA', '#EXT-X-I-FRAME-STREAM-INF',
                                       '#EXT-X-IMAGE-STREAM-INF', '#EXT-X-RENDITION-REPORT')
                res_kind = ("key" if tag in ("#EXT-X-KEY", "#EXT-X-SESSION-KEY")
                            else "map" if (tag == "#EXT-X-MAP" or (tag == "#EXT-X-PRELOAD-HINT" and "TYPE=MAP" in line))
                            else "media")
                line = re.sub(r'\bURI=(?:"([^"]+)"|\x27([^\x27]+)\x27)', lambda match: 'URI="' + local(match[1] or match[2], uri_manifest, res_kind) + '"', line)
                if tag == '#EXT-X-STREAM-INF':
                    variant_pending = True
            elif line.strip():
                line = local(line.strip(), variant_pending)
                variant_pending = False
            lines.append(line)
        if (warmup_key_token or warmup_map_token or warmup_segment_token) and self._should_speculative_warmup(parent.hostname):
            threading.Thread(
                target=self.warmup_manifest_assets,
                args=(warmup_key_token, warmup_map_token, warmup_segment_token),
                name='cctvhost-hls-warmup',
                daemon=True,
            ).start()
        return '\n'.join(lines) + '\n'

    @staticmethod
    def _safe_refresh_headers(values):
        if not isinstance(values,dict):
            return {}
        output={}
        banned={'host','content-length','connection','transfer-encoding','keep-alive','upgrade'}
        for name,value in list(values.items())[:64]:
            key,text=str(name),str(value)
            if (not re.fullmatch(r"[A-Za-z0-9!#$%&'*+.^_|~-]{1,128}",key) or len(text)>8192 or
                    '\r' in text or '\n' in text or key.lower() in banned):
                continue
            output[key]=text
        return output

    def _refresh_record(self, token, force=False):
        with self.lock:
            record=self.targets.get(token) or self.segments.get(token)
            if not record or not record[3] or self.stopping.is_set():
                return record
            failure=self.refreshFailures.get(token)
            if failure and time.monotonic()<failure[1]:
                raise RelayFailure('media_refresh_backoff')
            if not force and (not record[4] or time.time()<record[4]):
                return record
            flight=self.refreshing.get(token)
            owner=flight is None
            if owner:
                flight={'event':threading.Event(),'error':None}
                self.refreshing[token]=flight
        if not owner:
            if not flight['event'].wait(15):
                raise RelayFailure('media_refresh_timeout')
            if flight['error'] is not None:
                raise flight['error']
            with self.lock:
                return self.targets.get(token)
        try:
            value=record[3]()
            if not isinstance(value,dict) or not isinstance(value.get('url'),str):
                raise RelayFailure('media_refresh_invalid')
            base_url=value['url']
            base=urllib.parse.urlsplit(base_url)
            if base.scheme.lower() not in ('http','https') or not base.hostname or base.username or base.password:
                raise RelayFailure('media_refresh_invalid')
            refreshed_url=base_url
            relative=record[6]
            if relative:
                refreshed_url=urllib.parse.urljoin(base_url,relative)
                child=urllib.parse.urlsplit(refreshed_url)
                if self._same_origin(base,child) and base.query and not child.query:
                    refreshed_url=self._with_query(refreshed_url,base.query)
            target=urllib.parse.urlsplit(refreshed_url)
            if target.scheme.lower() not in ('http','https') or not target.hostname or target.username or target.password:
                raise RelayFailure('media_refresh_invalid')
            headers=self._safe_refresh_headers(value.get('headers',{}))
            origin=(base.scheme.lower(),base.netloc.lower())
            key=(refreshed_url,tuple(sorted(headers.items())),origin,None,record[2],
                 record[0][5] if len(record[0]) > 5 else False, record[0][6] if len(record[0]) > 6 else "media", record[0][7] if len(record[0]) > 7 else record[2])
            interval=max(0.0,min(float(value.get('refreshInterval') or record[5] or 0),3600.0))
            next_refresh=float(value.get('refreshAfter') or (time.time()+interval if interval else 0))
            updated=(key,record[1],record[2],record[3],next_refresh,interval,relative)
            with self.lock:
                if token in self.targets and not self.stopping.is_set():
                    self.targets[token]=updated
                    self.targets.move_to_end(token)
                    self.refreshFailures.pop(token,None)
                    return updated
                return None
        except RelayFailure as error:
            flight['error']=RelayFailure(error.stage)
            with self.lock:
                if token in self.targets and not self.stopping.is_set():
                    attempts=self.refreshFailures.get(token,(0,0))[0]+1
                    self.refreshFailures[token]=(attempts,time.monotonic()+min(60.0,2.0**min(attempts,6)))
            raise
        except Exception as error:
            failure=RelayFailure('media_refresh_failed')
            flight['error']=failure
            with self.lock:
                if token in self.targets and not self.stopping.is_set():
                    attempts=self.refreshFailures.get(token,(0,0))[0]+1
                    self.refreshFailures[token]=(attempts,time.monotonic()+min(60.0,2.0**min(attempts,6)))
            raise failure from error
        finally:
            with self.lock:
                event=self.refreshing.pop(token,None)
                if event:
                    event['event'].set()

    def _failed(self, handler, stage, diagnostic_id, url, status=502, error=None, upstream_status=0, sent=False):
        parsed = urllib.parse.urlsplit(url)
        record = {
            'event': 'media_relay_failed', 'request_id': diagnostic_id or uuid.uuid4().hex,
            'stage': stage, 'upstream_status': int(upstream_status or 0),
            'upstream_host': parsed.hostname or '', 'scheme': parsed.scheme.lower(),
            'media_extension': parsed.path.rsplit('.', 1)[-1].lower()[:12] if '.' in parsed.path else '',
        }
        if error is not None:
            record['error_type'] = type(error).__name__
            record['error_summary'] = safe_error_summary(error)
        print('[CCTVHostMediaRelay] ' + json.dumps(record, ensure_ascii=False, separators=(',', ':')))
        if sent:
            return
        body = json.dumps({'ok': False, 'error': stage, 'request_id': record['request_id']},
                          ensure_ascii=False, separators=(',', ':')).encode('utf-8')
        try:
            handler.send_response(status)
            handler.send_header('Content-Type', 'application/json; charset=utf-8')
            handler.send_header('Content-Length', str(len(body)))
            handler.send_header('Cache-Control', 'no-store')
            handler.send_header('X-CCTVHost-Relay-Stage', stage)
            handler.send_header('X-CCTVHost-Request-ID', record['request_id'])
            handler.send_header('Connection', 'close')
            handler.end_headers()
            if handler.command != 'HEAD':
                handler.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError, OSError):
            pass

    def _join_manifest_fetch(self, identity):
        with self.lock:
            if self.stopping.is_set():
                raise RelayFailure('media_service_stopping')
            flight = self.manifest_flights.get(identity)
            if flight is not None:
                return flight, False
            # A playlist is bounded to 2 MiB, and rewritten data is shared by
            # reference. Limit concurrent coalesced fetches on memory-limited iOS.
            if len(self.manifest_flights) >= 4:
                return None, True
            flight = {'event': threading.Event(), 'body': None, 'error': None}
            self.manifest_flights[identity] = flight
            return flight, True

    def _finish_manifest_fetch(self, identity, flight, body=None, error=None):
        if flight is None:
            return
        with self.lock:
            if self.manifest_flights.get(identity) is not flight:
                return
            self.manifest_flights.pop(identity)
            flight['body'], flight['error'] = body, error
            flight['event'].set()

    def _send_manifest(self, handler, body):
        handler.send_response(200)
        handler.send_header('Content-Type', 'application/vnd.apple.mpegurl')
        handler.send_header('Content-Length', str(len(body)))
        handler.send_header('Cache-Control', 'no-store')
        handler.send_header('Connection', 'close')
        handler.end_headers()
        self._write_client(handler, body)

    @staticmethod
    def _write_client(handler, data):
        try:
            handler.wfile.write(data)
        except (BrokenPipeError, ConnectionResetError) as error:
            raise RelayClientDisconnected(type(error).__name__) from error

    @staticmethod
    def sniff_container_magic(data):
        if not data:
            return None
        if data[0] == 0x47 and (len(data) < 189 or data[188] == 0x47):
            return 'video/mp2t'
        if data.startswith(b'FLV\x01'):
            return 'video/x-flv'
        if data.startswith(b'\x1a\x45\xdf\xa3'):
            return 'video/x-matroska'
        if len(data) >= 8 and data[4:8] in (b'ftyp', b'styp', b'moof', b'moov', b'sidx', b'emsg'):
            return 'video/mp4'
        head = data.lstrip(b'\xef\xbb\xbf \t\r\n')[:256]
        if head.startswith(b'#EXTM3U'):
            return 'application/vnd.apple.mpegurl'
        if head.startswith((b'<?xml', b'<MPD')) and b'<MPD' in head:
            return 'application/dash+xml'
        return None

    @staticmethod
    def _is_clean_media_head(data):
        return (not data or data[0] == 0x47 or
                data.startswith((b'FLV\x01', b'\x1a\x45\xdf\xa3')) or
                (len(data) >= 8 and data[4:8] in
                 (b'ftyp', b'styp', b'moof', b'moov', b'sidx', b'emsg')) or
                data[:3] == b'ID3' or data[:2] in (b'\xff\xf1', b'\xff\xf9'))

    def _should_speculative_warmup(self, hostname):
        if self.speculative_warmup is not None:
            return bool(self.speculative_warmup)
        host = (hostname or '').lower()
        return bool(host) and host not in ('127.0.0.1', 'localhost', '::1')

    def _evict_expired_prefetched_streams_locked(self, now=None):
        now = time.monotonic() if now is None else now
        expired = [k for k, v in self.prefetched_segment_streams.items() if now - v[2] >= 10.0]
        for k in expired:
            entry = self.prefetched_segment_streams.pop(k, None)
            if entry and entry[0]:
                try:
                    entry[0].close()
                except Exception:
                    pass

    def warmup_manifest_assets(self, key_token=None, map_token=None, segment_token=None):
        if self.stopping.is_set():
            return
        for tok, kind in ((key_token, 'key'), (map_token, 'map'), (segment_token, 'media')):
            if not tok or self.stopping.is_set():
                continue
            with self.lock:
                record = self.segments.get(tok) or self.targets.get(tok)
            if not record or record[3]:
                continue
            key = record[0]
            url, pairs, origin = key[:3]
            diagnostic_id = record[2]
            cache_key = (url, pairs)
            if kind == 'key':
                with self.lock:
                    if cache_key in self.remote_key_cache:
                        continue
            elif kind == 'map':
                with self.lock:
                    if cache_key in self.remote_map_cache:
                        continue
            elif kind == 'media':
                with self.lock:
                    self._evict_expired_prefetched_streams_locked()
                    if cache_key in self.prefetched_segment_streams:
                        continue
            parsed = urllib.parse.urlsplit(url)
            headers = scoped_headers(dict(pairs), origin, url)
            headers['Accept-Encoding'] = 'identity'
            req = urllib.request.Request(http_url(url), headers=headers, method='GET')
            resp = None
            try:
                resp = _open_with_timeout_retry(req, diagnostic_id)
                if getattr(resp, 'status', 0) != 200:
                    resp.close()
                    continue
                if kind == 'key':
                    raw_key = resp.read(4096)
                    resp.close()
                    norm_key = self._normalize_hls_key_bytes(raw_key)
                    if len(norm_key) == 16:
                        with self.lock:
                            if not self.stopping.is_set():
                                self.remote_key_cache[cache_key] = norm_key
                                self.remote_key_cache.move_to_end(cache_key)
                                while len(self.remote_key_cache) > 256:
                                    self.remote_key_cache.popitem(last=False)
                elif kind == 'map':
                    raw_map = resp.read(262145)
                    resp.close()
                    if 0 < len(raw_map) <= 262144:
                        mime = resp.headers.get('Content-Type', 'video/mp4')
                        map_ct = 'video/mp4' if (len(raw_map) >= 8 and raw_map[4:8] in (b'ftyp', b'styp', b'moof', b'moov')) else mime
                        with self.lock:
                            if not self.stopping.is_set():
                                self.remote_map_cache[cache_key] = (raw_map, map_ct)
                                self.remote_map_cache.move_to_end(cache_key)
                                while len(self.remote_map_cache) > 32:
                                    self.remote_map_cache.popitem(last=False)
                elif kind == 'media':
                    reader = resp.read1 if callable(getattr(type(resp), 'read1', None)) else resp.read
                    prefix_chunk = reader(65536)
                    if not prefix_chunk:
                        resp.close()
                        continue
                    with self.lock:
                        if self.stopping.is_set() or cache_key in self.prefetched_segment_streams:
                            resp.close()
                        else:
                            self._evict_expired_prefetched_streams_locked()
                            while len(self.prefetched_segment_streams) >= 4:
                                _, old_entry = self.prefetched_segment_streams.popitem(last=False)
                                try:
                                    old_entry[0].close()
                                except Exception:
                                    pass
                            self.prefetched_segment_streams[cache_key] = (resp, prefix_chunk, time.monotonic())
                            resp = None
            except Exception:
                if resp is not None:
                    try:
                        resp.close()
                    except Exception:
                        pass

    def serve(self, handler, token, head=False):
        with self.lock:
            dash = self.dash_playlists.get(token) if not self.stopping.is_set() else None
            if dash:
                self.dash_playlists.move_to_end(token)
        if dash:
            session, track_id = dash
            try:
                body = session.playlist(track_id, f'http://127.0.0.1:{handler.server.server_port}').encode('utf-8')
                handler.send_response(200)
                handler.send_header('Content-Type', 'application/vnd.apple.mpegurl')
                handler.send_header('Content-Length', str(len(body)))
                handler.send_header('Cache-Control', 'no-store')
                handler.send_header('Connection', 'close')
                handler.end_headers()
                if not head:
                    self._write_client(handler, body)
            except RelayClientDisconnected:
                pass
            except Exception as error:
                stage = str(error) if str(error).startswith('dash_') else 'dash_manifest_failed'
                self._failed(handler, stage, session.diagnostic_id, session.url, error=error)
            return
        with self.lock:
            inline_key_entry = self.inline_keys.get(token)
            if inline_key_entry is not None and not self.stopping.is_set():
                self.inline_keys.move_to_end(token)
        if inline_key_entry is not None and not self.stopping.is_set():
            key_data = inline_key_entry[0]
            handler.send_response(200)
            handler.send_header('Content-Type', 'application/octet-stream')
            handler.send_header('Content-Length', str(len(key_data)))
            handler.send_header('Cache-Control', 'no-store')
            handler.send_header('Connection', 'close')
            handler.end_headers()
            if not head:
                self._write_client(handler, key_data)
            return
        with self.lock:
            inline_manifest_entry = self.inline_manifests.get(token)
            if inline_manifest_entry is not None and not self.stopping.is_set():
                self.inline_manifests.move_to_end(token)
        if inline_manifest_entry is not None and not self.stopping.is_set():
            m_text, m_base_url, m_headers, m_origin, m_diag, m_scope = inline_manifest_entry
            rewritten = self.rewrite(
                m_text, m_base_url, dict(m_headers), m_origin,
                f'http://127.0.0.1:{handler.server.server_port}', m_diag,
                resource_scope=m_scope
            ).encode('utf-8')
            handler.send_response(200)
            handler.send_header('Content-Type', 'application/vnd.apple.mpegurl')
            handler.send_header('Content-Length', str(len(rewritten)))
            handler.send_header('Cache-Control', 'no-store')
            handler.send_header('Connection', 'close')
            handler.end_headers()
            if not head:
                self._write_client(handler, rewritten)
            return
        with self.lock:
            pool = self.targets if token in self.targets else self.segments
            record = pool.get(token)
            stopping = self.stopping.is_set()
            if record and not stopping:
                pool.move_to_end(token)
        # A slow/disconnected client must not hold the registry lock while
        # reporting an expired session. Distinguish this local 404 from an
        # upstream media-not-found response without exposing the opaque token.
        if stopping or not record:
            self._failed(handler, 'media_service_stopping' if stopping else 'media_session_expired',
                         record[2] if record else None, record[0][0] if record else '', status=404)
            return
        key=record[0];url=key[0];diagnostic_id=record[2]
        response = None
        sent = False
        resource_started = time.perf_counter()
        resource_kind = key[6] if len(key) > 6 else 'media'
        resource_scope = key[7] if len(key) > 7 else diagnostic_id
        monitor = False
        with self.lock:
            identity = (resource_scope or token, resource_kind)
            if not head and token in self.segments and identity not in self.diagnosed_resources:
                self.diagnosed_resources[identity] = True
                while len(self.diagnosed_resources) > 256: self.diagnosed_resources.popitem(last=False)
                monitor = True
        def resource_event(suffix, count=0):
            if monitor:
                print('[CCTVHostMediaRelay] ' + json.dumps({
                    'event': 'media_relay_first_resource_' + suffix,
                    'request_id': diagnostic_id, 'play_request_id': resource_scope, 'resource_kind': resource_kind,
                    'upstream_host': urllib.parse.urlsplit(url).hostname or '',
                    'elapsed_ms': max(0, int((time.perf_counter()-resource_started)*1000)),
                    'response_bytes': count,
                    'upstream_status': getattr(response, 'status', 0) if response is not None else 0,
                }, separators=(',', ':')))
        resource_event('requested')
        manifest_identity = None
        manifest_flight = None
        manifest_owner = True
        def fail(stage, status=502, error=None, upstream_status=0):
            if manifest_owner:
                self._finish_manifest_fetch(manifest_identity, manifest_flight,
                                            error=(stage, status))
            self._failed(handler, stage, diagnostic_id, url, status=status,
                         error=error, upstream_status=upstream_status, sent=sent)
        try:
            refreshed=self._refresh_record(token)
            if refreshed is None:
                if self.stopping.is_set():
                    return
                raise RelayFailure('media_session_expired')
            record=refreshed
            key, _, diagnostic_id = record[:3]
            url, pairs, origin, fallback_url, _ = key[:5]
            expected_hls = bool(key[5]) if len(key) > 5 else False
            headers = scoped_headers(dict(pairs), origin, url)
            parsed = urllib.parse.urlsplit(url)
            with self.lock:
                first_manifest = not head and (expected_hls or parsed.path.lower().endswith(('.m3u8', '.m3u'))) and token not in self.diagnosed_manifests
                if first_manifest:
                    self.diagnosed_manifests.add(token)
            if first_manifest:
                print('[CCTVHostMediaRelay] ' + json.dumps({'event': 'media_relay_manifest_requested',
                    'request_id': diagnostic_id, 'upstream_host': parsed.hostname or '',
                    'scheme': parsed.scheme.lower()}, separators=(',', ':')))
            headers['Accept-Encoding'] = 'identity'
            manifest_request = expected_hls or parsed.path.lower().endswith(('.m3u8', '.m3u'))
            if manifest_request:
                url = ll_hls_upstream_url(url, getattr(handler, 'path', ''))
            if manifest_request:
                # Rewritten playlists have different byte offsets. Fetch the
                # full source manifest; range requests still apply to media.
                headers = {k: v for k, v in headers.items() if k.lower() != 'range'}
            elif handler.headers.get('Range'):
                headers['Range'] = handler.headers['Range']
            if expected_hls and not head:
                manifest_identity = (token, url, tuple(sorted(headers.items())),
                                     handler.server.server_port)
                manifest_flight, manifest_owner = self._join_manifest_fetch(manifest_identity)
                if not manifest_owner:
                    joined_at = time.perf_counter()
                    if not manifest_flight['event'].wait(20):
                        raise RelayFailure('manifest_request_timeout')
                    if manifest_flight['error'] is not None:
                        stage, status = manifest_flight['error']
                        fail(stage, status=status)
                        return
                    if manifest_flight['body'] is None or self.stopping.is_set():
                        raise RelayFailure('media_service_stopping')
                    print('[CCTVHostMediaRelay] ' + json.dumps({
                        'event': 'media_relay_manifest_coalesced', 'request_id': diagnostic_id,
                        'elapsed_ms': max(0, int((time.perf_counter()-joined_at)*1000)),
                        'manifest_bytes': len(manifest_flight['body']),
                        'upstream_host': parsed.hostname or '',
                    }, separators=(',', ':')))
                    sent = True
                    self._send_manifest(handler, manifest_flight['body'])
                    return
            if resource_kind == 'key' and not head and not record[3]:
                with self.lock:
                    cached_norm_key = self.remote_key_cache.get((url, pairs))
                    if cached_norm_key is not None:
                        self.remote_key_cache.move_to_end((url, pairs))
                if cached_norm_key is not None:
                    resource_event('headers')
                    resource_event('byte', len(cached_norm_key))
                    handler.send_response(200)
                    handler.send_header('Content-Type', 'application/octet-stream')
                    handler.send_header('Content-Length', str(len(cached_norm_key)))
                    handler.send_header('Cache-Control', 'no-store')
                    handler.send_header('Connection', 'close')
                    handler.end_headers()
                    sent = True
                    self._write_client(handler, cached_norm_key)
                    resource_event('completed', len(cached_norm_key))
                    return
            if resource_kind == 'map' and not head and not record[3] and not handler.headers.get('Range'):
                with self.lock:
                    cached_map = self.remote_map_cache.get((url, pairs))
                    if cached_map is not None:
                        self.remote_map_cache.move_to_end((url, pairs))
                if cached_map is not None:
                    map_bytes, map_ct = cached_map
                    resource_event('headers')
                    resource_event('byte', len(map_bytes))
                    handler.send_response(200)
                    handler.send_header('Content-Type', map_ct)
                    handler.send_header('Content-Length', str(len(map_bytes)))
                    handler.send_header('Cache-Control', 'no-store')
                    handler.send_header('Connection', 'close')
                    handler.end_headers()
                    sent = True
                    self._write_client(handler, map_bytes)
                    resource_event('completed', len(map_bytes))
                    return
            prefetched_prefix = b''
            if resource_kind == 'media' and not head and not record[3] and not handler.headers.get('Range') and not expected_hls:
                with self.lock:
                    self._evict_expired_prefetched_streams_locked()
                    warm_entry = self.prefetched_segment_streams.pop((url, pairs), None)
                if warm_entry is not None:
                    response, prefetched_prefix, _ = warm_entry
            request = urllib.request.Request(http_url(url), headers=headers, method='HEAD' if head else 'GET')
            try:
                if response is None:
                    response = _open_with_timeout_retry(request, diagnostic_id)
            except urllib.error.HTTPError as upstream_error:
                if fallback_url and upstream_error.code in (401, 403):
                    upstream_error.close()
                    fallback_request = urllib.request.Request(http_url(fallback_url), headers=headers,
                        method='HEAD' if head else 'GET')
                    response = _open_with_timeout_retry(fallback_request, diagnostic_id)
                elif upstream_error.code in (401,403) and record[3]:
                    upstream_error.close()
                    record=self._refresh_record(token,force=True)
                    if not record:raise RelayFailure('media_refresh_invalid')
                    key, _, diagnostic_id = record[:3]
                    url, pairs, origin, fallback_url, _ = key[:5]
                    expected_hls = bool(key[5]) if len(key) > 5 else False
                    headers=scoped_headers(dict(pairs), origin, url)
                    parsed=urllib.parse.urlsplit(url)
                    headers['Accept-Encoding']='identity'
                    manifest_request = expected_hls or parsed.path.lower().endswith(('.m3u8', '.m3u'))
                    if manifest_request:headers={k:v for k,v in headers.items() if k.lower()!='range'}
                    elif handler.headers.get('Range'):headers['Range']=handler.headers['Range']
                    refreshed_request=urllib.request.Request(http_url(url),headers=headers,method='HEAD' if head else 'GET')
                    response=_open_with_timeout_retry(refreshed_request, diagnostic_id)
                elif upstream_error.code == 403 and any(k.lower() in ('referer', 'origin') for k in headers):
                    upstream_error.close()
                    stripped_headers = {k: v for k, v in headers.items() if k.lower() not in ('referer', 'origin')}
                    stripped_request = urllib.request.Request(http_url(url), headers=stripped_headers, method='HEAD' if head else 'GET')
                    response = _open_with_timeout_retry(stripped_request, diagnostic_id)
                else:
                    raise
            with self.lock:
                if self.stopping.is_set():
                    response.close()
                    return
                self.responses.add(response)
            resource_event('headers')
            mime = response.headers.get('Content-Type', 'application/octet-stream')
            raw_length = response.headers.get('Content-Length', '')
            expected_bytes = int(raw_length) if re.fullmatch(r'[0-9]{1,18}', raw_length) else None
            final_url = response.geturl()
            is_hls = 'mpegurl' in mime.lower() or urllib.parse.urlsplit(final_url).path.lower().endswith(('.m3u8', '.m3u'))
            prefix = prefetched_prefix
            # Some providers serve HLS from extensionless/PHP endpoints or
            # return a generic MIME type. Honor declared HLS and sniff those
            # responses before returning opaque bytes to AVPlayer.
            mime_type = mime.split(';', 1)[0].strip().lower()
            generic_mime = mime_type in ('', 'application/octet-stream', 'binary/octet-stream', 'text/plain')
            extensionless = not urllib.parse.urlsplit(final_url).path.rsplit('/', 1)[-1].count('.') or '.m3u8' in final_url.lower()
            is_segment_resource = (token in self.segments and resource_kind in ('media', 'key', 'map') and not expected_hls)
            if not head and not is_hls and not is_segment_resource and (expected_hls or generic_mime or extensionless):
                prefix = response.read(64)
                is_hls = prefix.lstrip(b'\xef\xbb\xbf \t\r\n').startswith(b'#EXTM3U')
                if expected_hls and not is_hls:
                    raise RelayFailure('manifest_invalid')
            if is_hls and not head:
                body = prefix + response.read(2 * 1024 * 1024 + 1 - len(prefix))
                if len(body) > 2 * 1024 * 1024:
                    raise RelayFailure('manifest_too_large')
                if expected_bytes is not None and len(body) < expected_bytes:
                    raise RelayFailure('upstream_body_truncated')
                text = body.decode('utf-8-sig')
                if not text.lstrip().startswith('#EXTM3U'):
                    raise RelayFailure('manifest_invalid')
                if not urllib.parse.urlsplit(final_url).query:
                    original = urllib.parse.urlsplit(url)
                    final = urllib.parse.urlsplit(final_url)
                    if original.query and self._same_origin(original, final):
                        final_url = self._with_query(final_url, original.query)
                if first_manifest:
                    print('[CCTVHostMediaRelay] ' + json.dumps({'event': 'media_relay_manifest_readable',
                        'request_id': diagnostic_id, 'upstream_host': urllib.parse.urlsplit(final_url).hostname or '',
                        'upstream_status': response.status, 'manifest_bytes': len(body),
                        'elapsed_ms': max(0, int((time.perf_counter()-resource_started)*1000))}, separators=(',', ':')))
                body = self.rewrite(text, final_url, dict(pairs), origin,
                                    f'http://127.0.0.1:{handler.server.server_port}', diagnostic_id,
                                    refresh=record[3],refresh_after=record[4],
                                    refresh_interval=record[5],
                                    refresh_relative_base=record[6],resource_scope=resource_scope).encode()
                self._finish_manifest_fetch(manifest_identity, manifest_flight, body=body)
                sent = True
                self._send_manifest(handler, body)
                return
            if resource_kind == 'key' and not head and response.status == 200:
                raw_key = prefix + response.read(4096)
                norm_key = self._normalize_hls_key_bytes(raw_key)
                if len(norm_key) == 16 and not record[3]:
                    with self.lock:
                        self.remote_key_cache[(url, pairs)] = norm_key
                        self.remote_key_cache.move_to_end((url, pairs))
                        while len(self.remote_key_cache) > 256:
                            self.remote_key_cache.popitem(last=False)
                resource_event('byte', len(norm_key))
                handler.send_response(200)
                handler.send_header('Content-Type', 'application/octet-stream')
                handler.send_header('Content-Length', str(len(norm_key)))
                handler.send_header('Cache-Control', 'no-store')
                handler.send_header('Connection', 'close')
                handler.end_headers()
                sent = True
                self._write_client(handler, norm_key)
                resource_event('completed', len(norm_key))
                return
            if resource_kind == 'map' and not head and response.status == 200 and not handler.headers.get('Range') and (expected_bytes is None or expected_bytes <= 262144):
                raw_map = prefix + response.read(262145 - len(prefix))
                if len(raw_map) <= 262144 and (expected_bytes is None or len(raw_map) == expected_bytes):
                    map_ct = 'video/mp4' if (len(raw_map) >= 8 and raw_map[4:8] in (b'ftyp', b'styp', b'moof', b'moov')) else mime
                    if not record[3]:
                        with self.lock:
                            self.remote_map_cache[(url, pairs)] = (raw_map, map_ct)
                            self.remote_map_cache.move_to_end((url, pairs))
                            while len(self.remote_map_cache) > 32:
                                self.remote_map_cache.popitem(last=False)
                    resource_event('byte', len(raw_map))
                    handler.send_response(200)
                    handler.send_header('Content-Type', map_ct)
                    handler.send_header('Content-Length', str(len(raw_map)))
                    handler.send_header('Cache-Control', 'no-store')
                    handler.send_header('Connection', 'close')
                    handler.end_headers()
                    sent = True
                    self._write_client(handler, raw_map)
                    resource_event('completed', len(raw_map))
                    return
                prefix = raw_map
            def read_stream_chunk(size=65536):
                reader = response.read1 if callable(getattr(type(response), 'read1', None)) else response.read
                thread = threading.current_thread()
                previous_stream_read = getattr(thread, '_host_media_stream_read', None)
                if self.stream_media: thread._host_media_stream_read = True
                try:
                    return reader(size)
                finally:
                    if self.stream_media:
                        if previous_stream_read is None:
                            try: del thread._host_media_stream_read
                            except AttributeError: pass
                        else:
                            thread._host_media_stream_read = previous_stream_read

            first_chunk = b''
            received_bytes = len(prefix)
            stripped_diff = 0
            override_ct = None
            # A partial response is already a selection of source bytes. Any
            # prefix removal/unwrapping would corrupt BYTERANGE offsets and
            # contradict Content-Range; transformations apply only to full GETs.
            if not head and token in self.segments and resource_kind == 'media' and response.status == 200:
                first_chunk = prefix + read_stream_chunk(65536) if not prefix else prefix
                prefix = b''
                received_bytes = len(first_chunk)
                if first_chunk.startswith(b'\x89PNG\r\n\x1a\n') and (b'roUd' in first_chunk[:256] or 'rou.video' in final_url.lower()):
                    raw_png = first_chunk + response.read(16 * 1024 * 1024 + 1 - len(first_chunk))
                    unwrapped = self._unwrap_rou_png_bytes(raw_png) if len(raw_png) <= 16 * 1024 * 1024 else None
                    if unwrapped is not None:
                        resource_event('byte', len(unwrapped))
                        u_mime = 'video/mp2t' if (len(unwrapped) > 376 and unwrapped[0] == 0x47 and unwrapped[188] == 0x47) else ('video/mp4' if unwrapped[4:8] in (b'ftyp', b'styp', b'moof', b'moov') else 'application/octet-stream')
                        handler.send_response(200)
                        handler.send_header('Content-Type', u_mime)
                        handler.send_header('Content-Length', str(len(unwrapped)))
                        handler.send_header('Cache-Control', 'no-store')
                        handler.send_header('Connection', 'close')
                        handler.end_headers()
                        sent = True
                        self._write_client(handler, unwrapped)
                        resource_event('completed', len(unwrapped))
                        return
                    first_chunk = raw_png
                    received_bytes = len(first_chunk)
                is_clean_media_head = self._is_clean_media_head(first_chunk)
                may_be_disguised = (
                    not is_clean_media_head and (
                        expected_bytes is None or
                        expected_bytes >= 4096 or
                        first_chunk.startswith((b'\x89PNG', b'\xff\xd8\xff', b'GIF8', b'BM', b'RIFF'))
                    )
                )
                if may_be_disguised:
                    need_more_probe = first_chunk.startswith((b'\x89PNG', b'\xff\xd8\xff', b'GIF8', b'BM', b'RIFF')) or len(first_chunk) < 512
                    # TCP/TLS can split an ordinary fMP4 header before its box
                    # type. Stop probing as soon as later bytes identify clean
                    # media instead of waiting for 16 KiB or the whole fragment.
                    while (need_more_probe and len(first_chunk) < 16384 and
                           not self._is_clean_media_head(first_chunk) and
                           self._strip_disguised_ts_prefix(first_chunk) is first_chunk):
                        more = read_stream_chunk(16384)
                        if not more:
                            break
                        first_chunk += more
                        received_bytes += len(more)
                    stripped_chunk = self._strip_disguised_ts_prefix(first_chunk)
                    stripped_diff = len(first_chunk) - len(stripped_chunk)
                    first_chunk = stripped_chunk
                if first_chunk and first_chunk[0] == 0x47:
                    override_ct = 'video/mp2t'
                elif first_chunk and generic_mime:
                    sniffed_ct = self.sniff_container_magic(first_chunk)
                    if sniffed_ct:
                        override_ct = sniffed_ct
            handler.send_response(response.status)
            for key in ('Content-Type', 'Content-Length', 'Content-Range', 'Accept-Ranges'):
                val = response.headers.get(key)
                if key == 'Content-Type' and override_ct:
                    val = override_ct
                elif key == 'Content-Length' and stripped_diff > 0 and expected_bytes is not None:
                    val = str(max(0, expected_bytes - stripped_diff))
                if val:
                    handler.send_header(key, val)
            handler.send_header('Connection', 'close')
            handler.end_headers()
            sent = True
            if not head:
                first_byte = False
                if prefix:
                    first_byte = True
                    resource_event('byte', len(prefix))
                    self._write_client(handler, prefix)
                elif first_chunk:
                    first_byte = True
                    resource_event('byte', received_bytes)
                    self._write_client(handler, first_chunk)
                while not self.stopping.is_set():
                    chunk = read_stream_chunk(65536)
                    if not chunk:
                        break
                    received_bytes += len(chunk)
                    if not first_byte:
                        first_byte = True
                        if token in self.segments and resource_kind == 'media' and response.status == 200:
                            chunk = self._strip_disguised_ts_prefix(chunk)
                        resource_event('byte', received_bytes)
                    self._write_client(handler, chunk)
                if not self.stopping.is_set() and expected_bytes is not None and received_bytes < expected_bytes:
                    raise RelayFailure('upstream_body_truncated')
                if not self.stopping.is_set(): resource_event('completed', received_bytes)
        except RelayClientDisconnected as error:
            # Disconnection does not prove playback success or upstream failure.
            print('[CCTVHostMediaRelay] ' + json.dumps({
                'event': 'media_relay_client_disconnected',
                'request_id': diagnostic_id or uuid.uuid4().hex,
                'stage': 'client_write', 'error_type': str(error),
            }, separators=(',', ':')))
        except urllib.error.HTTPError as error:
            status = error.code if 400 <= error.code <= 599 else 502
            fail('upstream_http_error', status=status, error=error, upstream_status=error.code)
            error.close()
        except http.client.IncompleteRead:
            # Partial bytes may contain media or credentials. Record only the
            # failure stage; never serialize the exception's partial payload.
            fail('upstream_body_truncated')
        except (TimeoutError, socket.timeout) as error:
            fail('upstream_timeout', status=504, error=error)
        except urllib.error.URLError as error:
            reason = getattr(error, 'reason', None)
            if isinstance(reason, (TimeoutError, socket.timeout)):
                stage = 'upstream_timeout'
            elif isinstance(reason, socket.gaierror):
                stage = 'upstream_dns_error'
            elif isinstance(reason, ssl.SSLError):
                stage = 'upstream_tls_error'
            elif isinstance(reason, ConnectionRefusedError):
                stage = 'upstream_connect_error'
            else:
                stage = 'upstream_network_error'
            fail(stage, status=504 if stage == 'upstream_timeout' else 502, error=error)
        except UnicodeDecodeError as error:
            fail('manifest_encoding_invalid', error=error)
        except RelayFailure as error:
            fail(error.stage, error=error)
        except ValueError as error:
            stage = 'manifest_invalid' if '清单' in str(error) else 'media_response_invalid'
            fail(stage, error=error)
        except (BrokenPipeError, ConnectionResetError, OSError) as error:
            fail('client_or_upstream_stream_interrupted', error=error)
        except Exception as error:
            fail('relay_internal_error', error=error)
        finally:
            if manifest_owner:
                self._finish_manifest_fetch(manifest_identity, manifest_flight,
                                            error=('manifest_request_failed', 502))
            if response:
                with self.lock:
                    self.responses.discard(response)
                response.close()

    def close(self):
        self.stopping.set()
        with self.lock:
            responses = list(self.responses)
            flights = list(self.refreshing.values())
            manifest_flights = list(self.manifest_flights.values())
            self.refreshing.clear()
            self.manifest_flights.clear()
            self.targets.clear()
            self.segments.clear()
            self.segment_index.clear()
            self.diagnosed_manifests.clear()
            self.diagnosed_resources.clear()
            self.refreshFailures.clear()
            warm_streams = [entry[0] for entry in self.prefetched_segment_streams.values() if entry and entry[0]]
            self.prefetched_segment_streams.clear()
            self.inline_keys.clear()
            self.inline_manifests.clear()
            self.remote_key_cache.clear()
            self.remote_map_cache.clear()
            self.dash_playlists.clear()
        for event in flights:
            event['event'].set()
        for flight in manifest_flights:
            flight['error'] = ('media_service_stopping', 503)
            flight['event'].set()
        for response in list(responses) + warm_streams:
            try:
                response.close()
            except OSError:
                pass
