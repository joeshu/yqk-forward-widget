"""CCTV-2 webpage-source local HLS. Node hosts the unchanged official runtime."""
from __future__ import annotations
import argparse
import base64
from collections import OrderedDict
from dataclasses import dataclass, replace
from concurrent.futures import ThreadPoolExecutor, TimeoutError as FutureTimeoutError
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from http.client import (IncompleteRead, HTTPSConnection, RemoteDisconnected,
                         CannotSendRequest, ResponseNotReady)
import json
import math
import os
from pathlib import Path
import queue
import random
import re
import shutil
import signal
import ssl
import subprocess
import sys
import threading
import time
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode, urljoin, urlsplit
from urllib.request import Request, HTTPRedirectHandler, HTTPSHandler, build_opener
import uuid
from cctv_native_ts import inspect_boundary_prefix, inspect_ts, transform_pes_nals, boundary_proven_by, TSFormatError

RUNTIME_URL = 'https://js.player.cntv.cn/creator/live.worker.js'
RUNTIME_SHA = 'ad9fd2d188015074e59632cedecf13eda29f2c76ea92f17b5f00bc799451bc13'
PACKAGES = ['fake-indexeddb@6.2.6', 'xhr2@0.2.1', 'http-proxy-agent@9.1.0', 'https-proxy-agent@9.1.0']
UA = 'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 Chrome/130.0.0.0 Mobile Safari/537.36'
REFERER = 'https://tv.cctv.com/live/cctv2/m/index.shtml'
CDNS = ('.cntv.cn', '.cctv.com', '.cdn20.com', '.kcdnvip.com', '.bdydns.com',
        '.myalicdn.com', '.myqcloud.com', '.myhwcdn.cn', '.volcfcdn.com')
# Exact website CDN observed in the user's 2026-10-20 official dispatch log.
EXACT_CDNS = frozenset({'ldocctvwbcdcnc.v.wscdns.com'})
# Replaced by the single-file build; source checkout uses the adjacent engine.
ENGINE_SOURCE = None


class NativeError(Exception):
    pass


def transport_error_code(error):
    """Describe network failures without URLs, paths, certificate text or tokens."""
    if isinstance(error, HTTPError):
        return f'http-{error.code}'
    code = type(error).__name__
    reason = error.reason if isinstance(error, URLError) else error
    if isinstance(error, URLError) and isinstance(reason, BaseException):
        code += ':'+type(reason).__name__
    if isinstance(reason, OSError) and isinstance(reason.errno, int):
        code += ':errno-'+str(reason.errno)
    if isinstance(reason, ssl.SSLCertVerificationError) and isinstance(getattr(reason, 'verify_code', None), int):
        code += ':verify-'+str(reason.verify_code)
    if isinstance(reason, ssl.SSLError):
        for attribute in ('library', 'reason'):
            value = getattr(reason, attribute, None)
            if isinstance(value, str) and re.fullmatch(r'[A-Z0-9_]{1,100}', value):
                code += ':'+attribute+'-'+value
    return code


class ResumePreparation(Exception):
    """Owner-thread signal: discard in-flight input after a cached resume."""
    def __init__(self, reset_sequence=False):
        self.reset_sequence = reset_sequence


class UnsupportedSource(NativeError):
    def __init__(self, url):
        super().__init__('unsupported-source-host')
        # Never retain/print the path, query, credentials or original URL.
        try:
            parsed = urlsplit(url)
            host = parsed.hostname or ''
            self.details = {'scheme': parsed.scheme if parsed.scheme in ('http', 'https') else 'other',
                            'host': host if re.fullmatch(r'[A-Za-z0-9.-]{1,253}', host) else 'invalid'}
        except ValueError:
            self.details = {'scheme': 'invalid', 'host': 'invalid'}


def validate_source(url):
    try:
        parsed = urlsplit(url)
        allowed = (parsed.scheme == 'https' and parsed.hostname and not parsed.username and not parsed.password
                   and parsed.port in (None, 443)
                   and (parsed.hostname in EXACT_CDNS or
                        any(parsed.hostname == suffix[1:] or parsed.hostname.endswith(suffix) for suffix in CDNS)))
    except ValueError:
        allowed = False
    if not allowed:
        raise UnsupportedSource(url)


class SourceRedirect(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        try:
            validate_source(newurl)
        except NativeError:
            if fp is not None:
                fp.close()
            raise
        return super().redirect_request(req, fp, code, msg, headers, newurl)


_API_TLS12_PREFERRED = False
_API_LEGACY_PREFERRED = False
_API_LEGACY_ENABLED = True


def _legacy_source_error(error):
    reason = getattr(error, 'reason', None)
    return (isinstance(reason, ssl.SSLError)
            and not isinstance(reason, ssl.SSLCertVerificationError)
            and getattr(reason, 'reason', None) == 'UNSAFE_LEGACY_RENEGOTIATION_DISABLED')


class LegacyAPIRedirect(SourceRedirect):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        parsed = urlsplit(newurl)
        if parsed.hostname != 'vdnx.live.cntv.cn' or parsed.path != '/api/v3/vdn/live':
            if fp is not None:
                fp.close()
            raise NativeError('source-api-legacy-redirect-denied')
        return super().redirect_request(req, fp, code, msg, headers, newurl)


class HTTPSConnectionPool:
    """Bounded idle connections; checked-out connections belong to one request."""
    def __init__(self, max_idle=6, idle_seconds=15):
        self.lock = threading.Lock()
        self.idle = OrderedDict()
        self.max_idle, self.idle_seconds = max_idle, idle_seconds
        self.created = self.reused = self.stale_retries = 0

    def take(self, key, create):
        with self.lock:
            now = time.monotonic()
            for token, (saved_key, conn, saved_at) in list(self.idle.items()):
                if now-saved_at >= self.idle_seconds:
                    self.idle.pop(token)
                    conn.close()
            for token in reversed(self.idle):
                saved_key, conn, _ = self.idle[token]
                if saved_key == key:
                    self.idle.pop(token)
                    self.reused += 1
                    return conn, True
            self.created += 1
        return create(), False

    def put(self, key, conn):
        with self.lock:
            self.idle[id(conn)] = (key, conn, time.monotonic())
            while len(self.idle) > self.max_idle:
                _, (_, old, _) = self.idle.popitem(last=False)
                old.close()

    def clear(self):
        with self.lock:
            saved = list(self.idle.values())
            self.idle.clear()
        for _, conn, _ in saved:
            conn.close()

    def snapshot(self):
        with self.lock:
            return {'enabled': _HTTP_REUSE_ENABLED, 'created': self.created,
                    'reused': self.reused, 'stale_retries': self.stale_retries,
                    'idle_connections': len(self.idle), 'max_idle_connections': self.max_idle}


_HTTP_REUSE_ENABLED = True
_HTTP_POOL = HTTPSConnectionPool()
_TLS_CONTEXTS = {}
_TLS_CONTEXT_LOCK = threading.Lock()


def source_tls_context(tls12=False, legacy=False):
    if legacy and (not getattr(ssl,'OP_LEGACY_SERVER_CONNECT',0)
                   or not getattr(ssl,'OP_NO_RENEGOTIATION',0)):
        raise NativeError('source-api-legacy-tls-unavailable')
    key = (tls12, legacy)
    with _TLS_CONTEXT_LOCK:
        if key not in _TLS_CONTEXTS:
            context = ssl.create_default_context()
            if tls12:
                context.minimum_version = ssl.TLSVersion.TLSv1_2
                context.maximum_version = ssl.TLSVersion.TLSv1_2
            if legacy:
                context.options |= ssl.OP_LEGACY_SERVER_CONNECT | ssl.OP_NO_RENEGOTIATION
            _TLS_CONTEXTS[key] = context
        return _TLS_CONTEXTS[key]


class PooledHTTPResponse:
    def __init__(self, response, connection, key, pool, url, keep_alive=True):
        self.response, self.connection, self.key, self.pool = response, connection, key, pool
        self.url = url
        self.status = self.code = response.status
        self.reason = self.msg = response.reason
        self.headers = response.headers
        self.closed = False
        self.failed = False
        self.keep_alive = keep_alive

    def info(self):
        return self.headers

    def geturl(self):
        return self.url

    def getcode(self):
        return self.code

    def read(self, amount=None):
        try:
            # urllib drains redirect bodies with read() before closing them.
            # Give that operation the same finite upper bound as media reads.
            unbounded = amount is None or amount < 0
            requested = 8*1024*1024+1 if unbounded else amount
            expected = self.response.length
            data = self.response.read(requested)
            if expected is not None and len(data) < min(expected, requested):
                raise IncompleteRead(data, expected-len(data))
            if unbounded and len(data) > 8*1024*1024:
                raise NativeError('response-too-large')
            if self.response.isclosed() and self.response.length not in (None, 0):
                raise IncompleteRead(data, self.response.length)
            return data
        except BaseException:
            self.failed = True
            self.close()
            raise

    def close(self):
        if self.closed:
            return
        self.closed = True
        reusable = (self.keep_alive and not self.failed and not self.response.will_close
                    and self.response.isclosed() and self.response.length in (None, 0)
                    and self.connection.sock is not None)
        self.response.close()
        if reusable:
            self.pool.put(self.key, self.connection)
        else:
            self.connection.close()

    def __enter__(self):
        return self

    def __exit__(self, *_exc):
        self.close()


class PooledHTTPSHandler(HTTPSHandler):
    def https_open(self, req):
        # ProxyHandler already selected the inherited proxy and CONNECT target.
        # A tunnel, TLS policy or proxy credential change must select another
        # connection. No per-request signed URL or origin headers are cached.
        headers = dict(req.unredirected_hdrs)
        headers.update({k:v for k,v in req.headers.items() if k not in headers})
        headers = {name.title(): value for name,value in headers.items()}
        tunnel = req._tunnel_host
        proxy_auth = headers.pop('Proxy-Authorization', '') if tunnel else ''
        headers.setdefault('Connection', 'keep-alive')
        key = (req.host, tunnel, id(self._context), hashlib.sha256(proxy_auth.encode()).digest())

        def create():
            conn = HTTPSConnection(req.host, timeout=req.timeout, context=self._context)
            if tunnel:
                conn.set_tunnel(tunnel, headers={'Proxy-Authorization':proxy_auth} if proxy_auth else {})
            return conn

        for attempt in range(2):
            conn, reused = _HTTP_POOL.take(key, create)
            try:
                conn.timeout = req.timeout
                if conn.sock is not None:
                    conn.sock.settimeout(req.timeout)
                conn.request(req.get_method(), req.selector, req.data, headers,
                             encode_chunked=req.has_header('Transfer-encoding'))
                response = conn.getresponse()
                return PooledHTTPResponse(response, conn, key, _HTTP_POOL, req.get_full_url(),
                                          keep_alive=headers['Connection'].lower() != 'close')
            except (RemoteDisconnected, BrokenPipeError, ConnectionResetError,
                    ConnectionAbortedError, CannotSendRequest, ResponseNotReady, ssl.SSLEOFError) as error:
                conn.close()
                if not reused or attempt or req.get_method() != 'GET':
                    raise URLError(error) from None
                with _HTTP_POOL.lock:
                    _HTTP_POOL.stale_retries += 1
            except OSError as error:
                conn.close()
                raise URLError(error) from None
            except BaseException:
                conn.close()
                raise


def get(url, *, headers=None, limit=8*1024*1024, timeout=12, response_info=False):
    global _API_TLS12_PREFERRED, _API_LEGACY_PREFERRED
    validate_source(url)
    req = Request(url, headers={'User-Agent': UA, 'Referer': REFERER, **(headers or {})})
    parsed = urlsplit(url)
    source_api = parsed.hostname == 'vdnx.live.cntv.cn' and parsed.path == '/api/v3/vdn/live'

    def read_response(tls12=False, legacy=False):
        handlers = [LegacyAPIRedirect() if legacy else SourceRedirect()]
        if _HTTP_REUSE_ENABLED:
            handlers.append(PooledHTTPSHandler(context=source_tls_context(tls12,legacy)))
        elif tls12:
            handlers.append(HTTPSHandler(context=source_tls_context(tls12,legacy)))
        try:
            response = build_opener(*handlers).open(req, timeout=timeout)
        except HTTPError as error:
            error.close()
            raise
        with response:
            body = response.read(limit + 1)
            if len(body) > limit:
                raise NativeError('response-too-large')
            validate_source(response.url)
            if legacy:
                target = urlsplit(response.url)
                if target.hostname != parsed.hostname or target.path != parsed.path:
                    raise NativeError('source-api-legacy-redirect-denied')
            if response_info:
                return body, response.url, {'status': response.status,
                    'content_range': response.headers.get('Content-Range', '')}
            return body, response.url

    preferred_legacy = source_api and _API_LEGACY_ENABLED and _API_LEGACY_PREFERRED
    preferred = source_api and (_API_TLS12_PREFERRED or preferred_legacy)
    try:
        return read_response(preferred,preferred_legacy)
    except URLError as error:
        reason = error.reason
        if (not source_api or not isinstance(reason, ssl.SSLError)
                or isinstance(reason, ssl.SSLCertVerificationError)):
            raise
        mode = not preferred
        print('[cctv-native] source-api TLS failure='+transport_error_code(error)+
              '; retrying verified '+('TLSv1.2' if mode else 'default TLS'), flush=True)
        try:
            result = read_response(mode)
        except URLError as second:
            if (preferred_legacy or not _API_LEGACY_ENABLED or not _legacy_source_error(second)
                    or not getattr(ssl,'OP_LEGACY_SERVER_CONNECT',0)
                    or not getattr(ssl,'OP_NO_RENEGOTIATION',0)):
                raise
            # A protocol-version change did not resolve the confirmed legacy
            # handshake failure. Never enable this for generic/certificate errors.
            print('[cctv-native] source-api confirmed legacy handshake; '
                  'trying verified TLSv1.2 legacy-server-connect, renegotiation disabled',flush=True)
            result = read_response(True,True)
            _API_TLS12_PREFERRED, _API_LEGACY_PREFERRED = True, True
            return result
        # Learn only after a verified request succeeds.
        _API_TLS12_PREFERRED, _API_LEGACY_PREFERRED = mode, False
        return result


WEBSITE_CHANNELS = (
    ('cctv1', 'CCTV-1 综合'), ('cctv2', 'CCTV-2 财经'),
    ('cctv3', 'CCTV-3 综艺'), ('cctv4', 'CCTV-4 中文国际'),
    ('cctv5', 'CCTV-5 体育'), ('cctv5plus', 'CCTV-5+ 体育赛事'),
    ('cctv6', 'CCTV-6 电影'), ('cctv7', 'CCTV-7 国防军事'),
    ('cctv8', 'CCTV-8 电视剧'), ('cctvjilu', 'CCTV-9 纪录'),
    ('cctv10', 'CCTV-10 科教'), ('cctv11', 'CCTV-11 戏曲'),
    ('cctv12', 'CCTV-12 社会与法'), ('cctv13', 'CCTV-13 新闻'),
    ('cctvchild', 'CCTV-14 少儿'), ('cctv15', 'CCTV-15 音乐'),
    ('cctv16', 'CCTV-16 奥林匹克'), ('cctv17', 'CCTV-17 农业农村'),
    ('cctveurope', 'CCTV-4 欧洲'), ('cctvamerica', 'CCTV-4 美洲'),
    ('cctv9', 'CCTV-NEWS 英语新闻'), ('cctvdoc', 'CCTV-9 纪录（英）'),
    ('cctvxiyu', 'CCTV-Español'), ('cctvfrench', 'CCTV-Français'),
    ('cctvarabic', 'CCTV-العربية'), ('cctvrussian', 'CCTV-Русский'),
)


def source_url(channel_id='cctv2'):
    if channel_id not in dict(WEBSITE_CHANNELS):
        raise NativeError('unknown-channel')
    stamp, nonce = int(time.time()*1000), random.randint(100, 1000)
    signature = hashlib.md5(f'{channel_id}{stamp}{nonce}4f779c20f6974ccba20e28d63529d0ef'.encode()).hexdigest()
    query = urlencode({'channel': channel_id, 'vn': '1000', 'pdrm': '1', 'uid': '', 'hbss': stamp})
    raw, _ = get('https://vdnx.live.cntv.cn/api/v3/vdn/live?' + query,
                 headers={'auth-key': f'{stamp}-{nonce}-{signature}'}, limit=1024*1024)
    data = json.loads(raw)
    if str(data.get('play')) != '1':
        raise NativeError('official-playback-not-permitted')
    url = data.get('manifest', {}).get('hls_cdrm')
    if not isinstance(url, str) or not url.startswith('https://'):
        raise NativeError('official-stream-unavailable')
    return url


def parse_playlist(text, base):
    if not text.lstrip('\ufeff').startswith('#EXTM3U'):
        raise NativeError('invalid-playlist')
    lines = [line.strip() for line in text.splitlines() if line.strip()]
    sequence, duration, discontinuity, variants, entries, bandwidth = 0, None, False, [], [], None
    for line in lines:
        if line.startswith('#EXT-X-MEDIA-SEQUENCE:'):
            sequence = int(line.split(':', 1)[1])
        elif line.startswith('#EXT-X-STREAM-INF:'):
            match = re.search(r'BANDWIDTH=(\d+)', line)
            bandwidth = int(match[1]) if match else 0
        elif line.startswith('#EXT-X-KEY:') and 'METHOD=NONE' not in line:
            raise NativeError('unsupported-extra-encryption')
        elif line.startswith('#EXT-X-MAP:'):
            raise NativeError('unsupported-media-container')
        elif line == '#EXT-X-DISCONTINUITY':
            discontinuity = True
        elif line.startswith('#EXTINF:'):
            duration = float(line.split(':', 1)[1].split(',', 1)[0])
            if not math.isfinite(duration) or not 0 < duration <= 30:
                raise NativeError('invalid-segment-duration')
        elif not line.startswith('#'):
            if bandwidth is not None:
                variants.append((bandwidth, urljoin(base, line)))
                bandwidth = None
            elif duration is not None:
                entries.append({'seq': sequence, 'duration': duration, 'url': urljoin(base, line),
                                'discontinuity': discontinuity})
                sequence += 1
                duration, discontinuity = None, False
    if variants:
        return {'variant': max(variants)[1]}
    if not entries or len(entries) > 64:
        raise NativeError('empty-or-oversized-playlist')
    return {'entries': entries}


def media_playlist(url):
    for _ in range(4):
        raw, final = get(url, limit=1024*1024)
        parsed = parse_playlist(raw.decode('utf-8-sig'), final)
        if 'entries' in parsed:
            return parsed['entries'], final
        url = parsed['variant']
    raise NativeError('playlist-nesting-exceeded')


def cache_paths(args):
    root = Path(args.cache_dir).expanduser().resolve()
    return root, root / 'node' / 'node_modules', root / ('runtime-' + RUNTIME_SHA[:12] + '.js')


def setup(args):
    root, modules, runtime = cache_paths(args)
    root.mkdir(parents=True, exist_ok=True, mode=0o700)
    npm = shutil.which('npm.cmd' if os.name == 'nt' else 'npm')
    if not npm:
        raise NativeError('npm-not-found')
    subprocess.run([npm, 'install', '--prefix', str(modules.parent), '--ignore-scripts', '--no-audit',
                    '--no-fund', '--save-exact', *PACKAGES], check=True)
    raw, _ = get(RUNTIME_URL, limit=4*1024*1024)
    if hashlib.sha256(raw).hexdigest() != RUNTIME_SHA:
        raise NativeError('official-runtime-version-changed')
    temporary = runtime.with_suffix('.tmp')
    temporary.write_bytes(raw)
    os.chmod(temporary, 0o600)
    temporary.replace(runtime)
    print('运行时已安装到独立缓存目录。未安装Chromium或FFmpeg。')


class Engine:
    def __init__(self, args):
        root, modules, runtime = cache_paths(args)
        if not runtime.is_file() or hashlib.sha256(runtime.read_bytes()).hexdigest() != RUNTIME_SHA:
            raise NativeError('runtime-missing-or-changed-run-setup')
        if not (modules / 'fake-indexeddb').is_dir():
            raise NativeError('dependencies-missing-run-setup')
        engine_path = Path(__file__).with_name('engine.cjs')
        if ENGINE_SOURCE is not None:
            engine_path = root / 'engine.cjs'
            temp = root / ('engine-' + uuid.uuid4().hex + '.tmp')
            temp.write_text(ENGINE_SOURCE, encoding='utf-8')
            temp.replace(engine_path)
        env = os.environ.copy()
        ca = ssl.get_default_verify_paths().cafile
        if ca and Path(ca).is_file():
            env.setdefault('NODE_EXTRA_CA_CERTS', ca)
        self.process = subprocess.Popen([args.node, str(engine_path), '--runtime', str(runtime),
                                         '--modules', str(modules)], stdin=subprocess.PIPE,
                                        stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, env=env)
        self.messages = queue.Queue(maxsize=4)
        self.counter = 0
        self.closed = False
        self.close_lock = threading.Lock()
        def read():
            try:
                while True:
                    line = self.process.stdout.readline(32*1024*1024 + 1)
                    if not line or len(line) > 32*1024*1024:
                        break
                    self.messages.put(json.loads(line), timeout=2)
            except Exception:
                pass
            finally:
                try:
                    self.messages.put_nowait({'error': 'engine-closed'})
                except queue.Full:
                    pass
        self.reader = threading.Thread(target=read, daemon=True)
        self.reader.start()
        try:
            if self.receive(25).get('ready') is not True:
                raise NativeError('engine-initialization-failed')
        except Exception:
            self.close()
            raise

    def receive(self, timeout):
        try:
            result = self.messages.get(timeout=timeout)
        except queue.Empty:
            raise NativeError('engine-timeout') from None
        if result.get('error'):
            raise NativeError(str(result['error']))
        return result

    def transform(self, units):
        self.counter += 1
        line = json.dumps({'id': self.counter, 'nals': [base64.b64encode(x).decode() for x in units]})
        if len(line) > 24*1024*1024:
            raise NativeError('engine-message-too-large')
        expired = threading.Event()
        def abort():
            expired.set()
            try:
                self.process.kill()
            except OSError:
                pass
        watchdog = threading.Timer(20, abort)
        watchdog.daemon = True
        watchdog.start()
        try:
            self.process.stdin.write(line.encode() + b'\n')
            self.process.stdin.flush()
            result = self.receive(20)
        except (OSError, ValueError, NativeError) as error:
            if expired.is_set():
                raise NativeError('engine-timeout') from None
            if isinstance(error, NativeError):
                raise
            # Engine pipe failures are not upstream transport failures and
            # must never enter the CDN retry loop.
            raise NativeError('engine-io-failed') from None
        finally:
            watchdog.cancel()
        if result.get('id') != self.counter or result.get('ok') is not True:
            raise NativeError('engine-response-invalid')
        output = [base64.b64decode(x, validate=True) for x in result['nals']]
        if len(output) != len(units):
            raise NativeError('engine-response-count')
        return output

    def close(self):
        with self.close_lock:
            if self.closed:
                return
            self.closed = True
            if self.process.poll() is None:
                self.process.terminate()
                try:
                    self.process.wait(3)
                except subprocess.TimeoutExpired:
                    self.process.kill()
                    self.process.wait()
            self.reader.join(2)
            self.process.stdin.close()
            self.process.stdout.close()


class SourceEntityChanged(NativeError):
    def __init__(self):
        super().__init__('source-entity-changed')


@dataclass(frozen=True)
class BoundaryPrefix:
    """Verified boundary-only bytes: never eligible to publish or transform."""
    data: bytes
    analysis: object
    range_data: bytes
    total_bytes: int


class Channel:
    def __init__(self, args):
        self.args = args
        self.channel_id = getattr(args, 'channel_id', 'cctv2')
        self.condition = threading.Condition(threading.RLock())
        self.stop = threading.Event()
        self.thread = None
        self.engine = None
        self.state, self.error, self.generation = 'idle', '', ''
        self.ring = OrderedDict()
        self.size = self.counter = self.requests = self.processed = 0
        self.discarded_discontinuities = 0
        self.source_gaps = 0
        self.transport_retries = 0
        self.last_transport_error = ''
        self.last_source_rejection = {}
        self.last_request = 0
        self.failed_at = 0
        self.waiters = 0
        self.input_tasks = set()
        self.timings = {}
        self.started_at = 0
        self.last_published_at = 0
        self.operation = 'idle'
        self.operation_started = 0
        self.seen_operations = set()
        self.playlist_entries = 0
        self.last_segment_bytes = 0
        self.preparation_phase = 'disabled'
        self.last_segment_timing = {}
        self.boundary_prefix_hits = self.boundary_prefix_fallbacks = 0
        self.boundary_prefix_saved_bytes = 0

    def checkpoint(self):
        return not self.stop.is_set()

    def native_context_closed(self):
        """Called by the VM owner after native teardown, before I/O joins."""

    def operation_phase(self, value):
        with self.condition:
            self.operation = value
            self.operation_started = time.monotonic()
            if value not in self.seen_operations:
                self.seen_operations.add(value)
                print('[cctv-native] phase='+value+' channel='+self.channel_id, flush=True)

    def note_client_request(self, kind):
        with self.condition:
            if not self.started_at or kind in self.timings:
                return
            elapsed = round(time.monotonic()-self.started_at,3)
            self.timings[kind] = elapsed
            print('[cctv-native] '+kind+' seconds='+str(elapsed)+' channel='+self.channel_id,flush=True)

    def stage(self, stage):
        with self.condition:
            self.state = stage
            self.timings.setdefault(stage, round(time.monotonic() - self.started_at, 3))
            self.condition.notify_all()

    def retry_cooldown(self):
        return 3 if self.error in ('source-media-stalled', 'TimeoutError', 'URLError',
                                   'ConnectionError', 'IncompleteRead', 'RemoteDisconnected') else 30

    def demand(self, start=True):
        with self.condition:
            self.last_request = time.monotonic()
            if not start or self.stop.is_set() or self.thread and self.thread.is_alive():
                return
            if self.state == 'error' and time.monotonic()-self.failed_at < self.retry_cooldown():
                return
            self.generation = uuid.uuid4().hex
            self.ring.clear()
            self.size = self.counter = self.processed = self.requests = 0
            self.discarded_discontinuities = 0
            self.source_gaps = 0
            self.transport_retries = 0
            self.last_transport_error = ''
            self.last_source_rejection = {}
            self.operation, self.operation_started = 'initializing', 0
            self.seen_operations.clear()
            self.preparation_phase = 'disabled'
            self.last_segment_timing = {}
            self.boundary_prefix_hits = self.boundary_prefix_fallbacks = 0
            self.boundary_prefix_saved_bytes = 0
            self.playlist_entries = self.last_segment_bytes = 0
            self.error, self.state, self.timings = '', 'initializing', {}
            self.started_at = time.monotonic()
            self.last_published_at = 0
            self.thread = threading.Thread(target=self.run, daemon=True, name='cctv-native')
            self.thread.start()

    def publish(self, body, entry, discontinuity):
        with self.condition:
            index = self.counter
            self.counter += 1
            self.processed += 1
            self.last_published_at = time.monotonic()
            self.last_transport_error = ''
            self.ring[index] = (body, entry['duration'], discontinuity)
            self.size += len(body)
            while len(self.ring) > 10 or self.size > self.args.buffer_mb*1024*1024:
                _, old = self.ring.popitem(last=False)
                self.size -= len(old[0])
                self.discarded_discontinuities += bool(old[2])
            if len(self.ring) >= getattr(self.args, 'startup_segments', 2):
                first_ready = self.state != 'ready'
                self.stage('ready')
                if first_ready and not getattr(self, 'resumed_at', 0):
                    print('[cctv-native] media-ready startup_seconds='+str(self.timings['ready'])+' channel='+self.channel_id, flush=True)
            self.condition.notify_all()

    def playlist(self):
        with self.condition:
            if len(self.ring) < getattr(self.args, 'startup_segments', 2) or self.state != 'ready':
                return None
            entries = list(self.ring.items())[-6:]
            target = max(math.ceil(value[1]) for _, value in entries)
            discontinuities = self.discarded_discontinuities + sum(
                bool(value[2]) for index, value in self.ring.items() if index < entries[0][0])
            lines = ['#EXTM3U', '#EXT-X-VERSION:3', f'#EXT-X-TARGETDURATION:{target}',
                     f'#EXT-X-MEDIA-SEQUENCE:{entries[0][0]}',
                     f'#EXT-X-DISCONTINUITY-SEQUENCE:{discontinuities}']
            for index, (_, duration, discontinuity) in entries:
                if discontinuity:
                    lines.append('#EXT-X-DISCONTINUITY')
                lines.extend([f'#EXTINF:{duration:.6f},', f'media/{self.generation}/{index}.ts'])
            return '\n'.join(lines)+'\n'

    def snapshot(self):
        with self.condition:
            return {'state': self.state, 'error': self.error, 'source': 'tv.cctv.com/'+self.channel_id,
                    'mode': 'official-runtime-original-ts', 'processed_segments': self.processed,
                    'buffer_bytes': self.size, 'buffer_segments': len(self.ring),
                    'pending_input_tasks': len(self.input_tasks),
                    'retry_after_seconds': max(0, round(self.retry_cooldown()-(time.monotonic()-self.failed_at),1)) if self.state == 'error' else 0,
                    'startup_segments': getattr(self.args, 'startup_segments', 2),
                    'source_gaps': self.source_gaps,
                    'transport_retries': self.transport_retries,
                    'last_transport_error': self.last_transport_error,
                    'last_source_rejection': dict(self.last_source_rejection),
                    'http_connections': _HTTP_POOL.snapshot(),
                    'operation': self.operation,
                    'parallel_preparation': bool(getattr(self.args,'parallel_prepare',False)),
                    'preparation_phase': self.preparation_phase,
                    'operation_seconds': round(time.monotonic()-self.operation_started, 3) if self.operation_started else 0,
                    'playlist_entries': self.playlist_entries, 'last_segment_bytes': self.last_segment_bytes,
                    'last_segment_timing': dict(self.last_segment_timing),
                    'prefix_lookahead': bool(getattr(self.args,'prefix_lookahead',False)),
                    'boundary_prefix_hits': self.boundary_prefix_hits,
                    'boundary_prefix_fallbacks': self.boundary_prefix_fallbacks,
                    'startup_lookahead_saved_bytes': self.boundary_prefix_saved_bytes,
                    'media_transfer': ('typed-array' if getattr(getattr(self.engine, 'context', None), 'buffer_api', False) else 'base64'),
                    'stage_seconds': dict(self.timings), 'media_ready': self.playlist() is not None}

    def _await_future(self, task):
        while True:
            if not self.checkpoint():
                raise ResumePreparation()
            try:
                return task.result(timeout=.2)
            except FutureTimeoutError:
                # A socket timeout is a real transport failure; a wait timeout
                # only gives the owner a chance to park or close its native VM.
                if task.done():
                    return task.result()

    def _download_segment(self, url):
        raw, final = get(url)
        # Parse only media bytes on an I/O worker. ctypes releases the GIL
        # during native JSC work, so the next input can be validated meanwhile.
        # Invalid media is rechecked by the owner to retain its boundary error.
        analysis = None
        if not self.stop.is_set() and not getattr(self, 'parked_at', 0):
            try:
                analysis = inspect_ts(raw, _map_bytes=False, _retain_packets=True)
            except TSFormatError:
                pass
        return raw, final, analysis

    def _cancel_inputs(self):
        # Running sockets retain their timeouts; never close another thread's
        # connection. Cancel work that has not started and guard queued calls.
        with self.condition:
            for task in tuple(self.input_tasks):
                task.cancel()

    def _submit_input(self, pool, function, *args):
        def guarded():
            if self.stop.is_set() or getattr(self, 'parked_at', 0):
                raise ResumePreparation()
            return function(*args)
        def finished(task):
            with self.condition:
                self.input_tasks.discard(task)
        with self.condition:
            task = pool.submit(guarded)
            self.input_tasks.add(task)
            task.add_done_callback(finished)
            return task

    def _submit_segment(self, pool, url):
        worker = self._download_segment if getattr(self.args, 'parallel_prepare', False) else get
        return self._submit_input(pool, worker, url)

    def _download_boundary(self, url):
        # Only the third startup input needs a boundary, not playable media.
        # Its full body can overlap SDK work after the first two inputs finish.
        count = 128*1024
        try:
            raw, final, info = get(url, headers={'Range':f'bytes=0-{count-1}',
                'Accept-Encoding':'identity'}, response_info=True, timeout=8)
        except HTTPError as error:
            if error.code not in (400, 405, 416, 501):
                raise
        else:
            status, content_range = info['status'], info['content_range']
            if status == 200 and not content_range:
                # Some CDNs ignore Range. Reuse that already complete download.
                try:
                    analysis = inspect_ts(raw, _map_bytes=False, _retain_packets=True)
                except TSFormatError:
                    analysis = None
                with self.condition:
                    self.boundary_prefix_fallbacks += 1
                return raw, final, analysis
            match = (re.fullmatch(r'bytes 0-(\d+)/(\d+)', content_range)
                     if status == 206 and isinstance(content_range,str) and len(content_range) <= 100 else None)
            if match:
                end, total = map(int, match.groups())
                if len(raw) == end+1 and 0 <= end < count and end < total <= 8*1024*1024:
                    if total == len(raw):
                        try:
                            analysis = inspect_ts(raw, _map_bytes=False, _retain_packets=True)
                        except TSFormatError:
                            analysis = None
                        with self.condition:
                            self.boundary_prefix_fallbacks += 1
                        return raw, final, analysis
                    proved = inspect_boundary_prefix(raw)
                    if proved is not None:
                        prefix, analysis = proved
                        with self.condition:
                            self.boundary_prefix_hits += 1
                            self.boundary_prefix_saved_bytes += total-len(raw)
                        print('[cctv-native] startup-lookahead=prefix channel='+self.channel_id+
                              ' fetched_bytes='+str(len(raw))+' complete_prefix_bytes='+str(len(prefix))+
                              ' full_bytes='+str(total), flush=True)
                        return BoundaryPrefix(prefix, analysis, raw, total)
        if self.stop.is_set():
            raise ResumePreparation()
        with self.condition:
            self.boundary_prefix_fallbacks += 1
        return self._download_segment(url)

    def _upgrade_boundary(self, url, boundary):
        raw, final, analysis = self._download_segment(url)
        # Signed HLS resources should be immutable. Even without ETag support,
        # retain and compare every ranged byte before consuming the full third.
        if len(raw) != boundary.total_bytes or not raw.startswith(boundary.range_data):
            raise SourceEntityChanged()
        return raw, final, analysis

    def _submit_inputs(self, pool, entries, cached, *, startup=False, upgrades=None):
        for index, entry in enumerate(entries):
            seq = entry['seq']
            task = cached.get(seq)
            if task is None:
                if startup and len(entries) == 3 and index == 2:
                    cached[seq] = self._submit_input(pool, self._download_boundary, entry['url'])
                else:
                    cached[seq] = self._submit_segment(pool, entry['url'])
            elif index < len(entries)-1 and task.done() and not task.cancelled() and task.exception() is None:
                value = task.result()
                if isinstance(value, BoundaryPrefix):
                    if upgrades is not None and seq in upgrades:
                        cached[seq] = upgrades[seq]
                    else:
                        cached[seq] = self._submit_input(pool, self._upgrade_boundary, entry['url'], value)
                        if upgrades is not None:
                            upgrades[seq] = cached[seq]

    def _start_boundary_upgrades(self, pool, entries, cached, upgrades):
        # Called only after the first two full inputs are downloaded. Extra
        # network work can then overlap native SDK work without delaying them.
        for entry in entries:
            seq = entry['seq']
            task = cached.get(seq)
            if seq in upgrades or task is None or not task.done() or task.cancelled() or task.exception() is not None:
                continue
            value = task.result()
            if isinstance(value, BoundaryPrefix):
                upgrades[seq] = self._submit_input(pool, self._upgrade_boundary, entry['url'], value)

    def _prepare_initial(self, pool, cancel):
        """Independent HTTPS work; never touches the thread-owned native VM."""
        def cancelled():
            return self.stop.is_set() or cancel.is_set()
        if cancelled():
            return None
        self.preparation_phase = 'source-api'
        url = source_url() if self.channel_id == 'cctv2' else source_url(self.channel_id)
        refreshed = time.monotonic()
        if cancelled():
            return None
        self.preparation_phase = 'media-playlist'
        entries, final = media_playlist(url)
        if cancelled():
            return None
        self.preparation_phase = 'segment-download'
        downloads = {}
        self._submit_inputs(pool, entries[:3], downloads,
                            startup=bool(getattr(self.args,'prefix_lookahead',False)))
        return entries, final, downloads, refreshed, time.monotonic()

    def run(self):
        # The native engine is created and released on this owner thread;
        # bounded I/O workers can fetch independently while it initializes.
        with ThreadPoolExecutor(max_workers=3) as pool:
            self._run_owned(pool)

    def _run_owned(self, pool):
        engine = None
        preparation = None
        cancel_preparation = threading.Event()
        upgrades = {}
        try:
            if getattr(self.args,'parallel_prepare',False):
                print('[cctv-native] source-preparation=parallel channel='+self.channel_id,flush=True)
                self.preparation_phase = 'source-api'
                preparation = self._submit_input(pool, self._prepare_initial,pool,cancel_preparation)
            self.operation_phase('engine-initialization')
            engine = Engine(self.args)
            with self.condition:
                self.engine = engine
            if self.stop.is_set():
                return
            self.stage('source')
            url, refreshed, failures = None, 0, 0
            current_source, last_seq, last_progress = None, None, time.monotonic()
            pending_discontinuity = False
            cached, analyses = {}, {}
            rejected_sources = 0
            while not self.stop.is_set():
                if not self.waiters and time.monotonic()-self.last_request > self.args.idle_timeout:
                    self.state = 'idle'
                    break
                if time.monotonic()-last_progress > 30:
                    raise NativeError('source-media-stalled')
                try:
                    if not self.checkpoint():
                        break
                    initial_downloads = {}
                    if preparation is not None:
                        pending, preparation = preparation, None
                        self.operation_phase(self.preparation_phase if self.preparation_phase != 'disabled' else 'source-api')
                        try:
                            prepared = self._await_future(pending)
                        except Exception:
                            self.operation_phase(self.preparation_phase)
                            raise
                        if prepared is None or self.stop.is_set():
                            break
                        entries, final, initial_downloads, refreshed, prepared_at = prepared
                        pending = prepared = None
                        url = final
                        if time.monotonic()-prepared_at > 8:
                            # A slow SDK initialization must not start playback
                            # from an obsolete live window just to reuse work.
                            for task in initial_downloads.values():
                                task.cancel()
                            initial_downloads = {}
                            self.operation_phase('media-playlist')
                            entries, final = media_playlist(url)
                    else:
                        if url is None or time.monotonic()-refreshed > 120:
                            self.operation_phase('source-api')
                            url, refreshed = (source_url() if self.channel_id == 'cctv2' else source_url(self.channel_id)), time.monotonic()
                            if not self.checkpoint():
                                break
                        self.operation_phase('media-playlist')
                        entries, final = media_playlist(url)
                    if not self.checkpoint():
                        break
                    self.playlist_entries = len(entries)
                    # Resolve the master only once per source refresh.
                    url = final
                    self.requests += 1
                    source = (urlsplit(final).hostname, urlsplit(final).path)
                    changed = current_source is not None and source != current_source
                    pending_discontinuity = pending_discontinuity or changed
                    if source != current_source:
                        last_seq, cached, analyses = None, {}, {}
                        for task in upgrades.values():
                            task.cancel()
                        upgrades = {}
                        current_source = source
                    if last_seq is not None and entries[0]['seq'] > last_seq+1:
                        # A live window can move past a slow download. Drop
                        # that gap, then prove boundaries within the new
                        # window; never join bytes across missing segments.
                        self.source_gaps += 1
                        last_seq, cached, analyses, pending_discontinuity = None, {}, {}, True
                        for task in upgrades.values():
                            task.cancel()
                        upgrades = {}
                    cached.update(initial_downloads)
                    initial_downloads = {}
                    wanted = [e for e in entries if last_seq is None or e['seq'] > last_seq][:3]
                    self._submit_inputs(pool, wanted, cached, startup=(self.counter == 0 and
                                        bool(getattr(self.args,'prefix_lookahead',False))), upgrades=upgrades)
                    for e, following in zip(wanted, wanted[1:]):
                        if not self.checkpoint():
                            break
                        if following['seq'] != e['seq']+1 or following['discontinuity']:
                            raise NativeError('source-boundary-not-proven')
                        self.operation_phase('segment-download')
                        download_started = time.perf_counter()
                        current_download = self._await_future(cached[e['seq']])
                        next_download = self._await_future(cached[following['seq']])
                        if isinstance(current_download, BoundaryPrefix):
                            if e['seq'] not in upgrades:
                                upgrades[e['seq']] = self._submit_input(pool, self._upgrade_boundary, e['url'], current_download)
                            cached[e['seq']] = upgrades[e['seq']]
                            current_download = self._await_future(upgrades[e['seq']])
                        raw = current_download[0]
                        boundary_only = isinstance(next_download, BoundaryPrefix)
                        lookahead = next_download.data if boundary_only else next_download[0]
                        if not self.checkpoint():
                            break
                        self._start_boundary_upgrades(pool, wanted, cached, upgrades)
                        download_wait = time.perf_counter()-download_started
                        self.last_segment_bytes = len(raw)
                        self.operation_phase('ts-analysis')
                        analysis_started = time.perf_counter()
                        analysis = current_download[2] if len(current_download) == 3 else analyses.get(e['seq'])
                        if analysis is None or analysis._source is not raw:
                            analysis = inspect_ts(raw, _map_bytes=False, _retain_packets=True)
                        next_analysis = (next_download.analysis if boundary_only else
                                         next_download[2] if len(next_download) == 3 else analyses.get(following['seq']))
                        if next_analysis is None or next_analysis._source is not lookahead:
                            try:
                                next_analysis = inspect_ts(lookahead, program_number=analysis.program_number,
                                                           video_pid=analysis.video_pid, _map_bytes=False,
                                                           _retain_packets=True)
                            except TSFormatError:
                                raise NativeError('source-boundary-not-proven') from None
                        if not boundary_proven_by(lookahead, program_number=analysis.program_number,
                                                  video_pid=analysis.video_pid, _prepared=next_analysis):
                            raise NativeError('source-boundary-not-proven')
                        if not boundary_only:
                            analyses[following['seq']] = next_analysis
                        # The lookahead proved the final boundary above. Only
                        # its completeness bit changes; reuse the parsed TS.
                        analysis = replace(analysis, nals=analysis.nals[:-1]+(
                            replace(analysis.nals[-1], complete=True),))
                        if not self.checkpoint():
                            break
                        analysis_seconds = time.perf_counter()-analysis_started
                        self.operation_phase('sdk-transform')
                        sdk_started = time.perf_counter()
                        processed = engine.transform([analysis.nal_bytes(n) for n in analysis.nals])
                        if not self.checkpoint():
                            break
                        sdk_seconds = time.perf_counter()-sdk_started
                        converted = {n.payload_offset: value for n, value in zip(analysis.nals, processed)}
                        self.operation_phase('ts-repack')
                        repack_started = time.perf_counter()
                        output, _ = transform_pes_nals(raw, lambda n, _data: converted[n.payload_offset],
                                                   nal_types=(1, 5, 7), final_nal_complete=True, _prepared=analysis)
                        if not self.checkpoint():
                            break
                        timing = {'download_wait': round(download_wait,3),
                                  'owner_analysis': round(analysis_seconds,3),
                                  'sdk_transform': round(sdk_seconds,3),
                                  'ts_repack': round(time.perf_counter()-repack_started,3)}
                        self.publish(output, e, pending_discontinuity or e['discontinuity'])
                        with self.condition:
                            self.last_segment_timing = timing
                            first_segments = self.counter <= 2
                        if first_segments:
                            print('[cctv-native] segment-timing channel='+self.channel_id+' '+
                                  json.dumps(timing), flush=True)
                        rejected_sources = 0
                        pending_discontinuity, last_seq, last_progress = False, e['seq'], time.monotonic()
                    if not self.checkpoint():
                        break
                    cached = {k:v for k,v in cached.items() if last_seq is None or k > last_seq}
                    # Two full outputs are now ready; complete the retained
                    # boundary input in parallel with the player's first reads.
                    if self.counter >= 2:
                        by_sequence = {entry['seq']:entry for entry in entries}
                        for seq, task in list(cached.items()):
                            if task.done() and not task.cancelled() and task.exception() is None:
                                value = task.result()
                                if isinstance(value, BoundaryPrefix) and seq in by_sequence:
                                    if seq not in upgrades:
                                        upgrades[seq] = self._submit_input(pool, self._upgrade_boundary, by_sequence[seq]['url'], value)
                                    cached[seq] = upgrades[seq]
                    analyses = {k:v for k,v in analyses.items() if k in cached}
                    upgrades = {k:v for k,v in upgrades.items() if k in cached}
                    if time.monotonic()-last_progress > 30:
                        raise NativeError('source-media-stalled')
                    failures, self.last_transport_error = 0, ''
                except SourceEntityChanged:
                    for task in upgrades.values():
                        task.cancel()
                    upgrades = {}
                    for task in cached.values():
                        task.cancel()
                    cached, analyses = {}, {}
                    url, current_source, last_seq, pending_discontinuity = None, None, None, True
                    self.source_gaps += 1
                    print('[cctv-native] source-entity-changed channel='+self.channel_id+
                          '; refreshing official source', flush=True)
                    continue
                except ResumePreparation as resumed:
                    for task in upgrades.values():
                        task.cancel()
                    upgrades = {}
                    for task in cached.values():
                        task.cancel()
                    cached, analyses = {}, {}
                    if resumed.reset_sequence:
                        last_seq, current_source, pending_discontinuity = None, None, True
                    # Time spent parked is not an upstream progress failure.
                    last_progress = time.monotonic()
                    continue
                except UnsupportedSource as error:
                    self.last_source_rejection = dict(error.details)
                    print('[cctv-native] source-rejected channel='+self.channel_id+' '+
                          json.dumps(error.details, ensure_ascii=True), flush=True)
                    # Refuse the address, but let the ordinary official API
                    # dispatch again. Never fetch the rejected host, downgrade
                    # HTTPS or retry an explicit official play denial.
                    if rejected_sources >= 2 or time.monotonic()-last_progress > 30:
                        raise
                    rejected_sources += 1
                    self.transport_retries += 1
                    self.last_transport_error = 'unsupported-source-host'
                    url = None
                    self.stop.wait(.15 * rejected_sources)
                    continue
                except (HTTPError, URLError, TimeoutError, ConnectionError, IncompleteRead) as error:
                    if isinstance(error, HTTPError):
                        if error.code in (401, 403, 404):
                            url = None
                        elif error.code not in (408, 429) and not 500 <= error.code < 600:
                            raise
                    code = transport_error_code(error)
                    self.transport_retries += 1
                    self.last_transport_error = code
                    print('[cctv-native] retry='+str(self.transport_retries)+' operation='+self.operation+' cause='+code, flush=True)
                    failures += 1
                    # A failed Future must be evicted or every subsequent
                    # poll would replay the same exception without a GET.
                    cached = {key: value for key, value in cached.items()
                              if not value.cancelled() and (not value.done() or value.exception() is None)}
                    upgrades = {key: value for key, value in upgrades.items()
                                if not value.cancelled() and (not value.done() or value.exception() is None)}
                    if time.monotonic()-last_progress > 30:
                        raise NativeError('source-media-stalled') from None
                    delay = min(4, 0.8 * 2**min(failures-1, 3))
                    reason = getattr(error, 'reason', None)
                    if (self.operation == 'source-api' and failures <= 2
                            and isinstance(reason, ssl.SSLError)
                            and getattr(reason, 'reason', None) == 'UNSAFE_LEGACY_RENEGOTIATION_DISABLED'):
                        # Two short initial retries for this immediate handshake
                        # failure; persistent failure still uses normal backoff
                        # and the same no-progress deadline/certificate policy.
                        delay = 0.15 * failures
                    self.stop.wait(delay)
                    continue
                if time.monotonic()-last_progress > 30:
                    raise NativeError('source-media-stalled')
                self.stop.wait(0.8)
        except Exception as error:
            self.error = str(error) if isinstance(error, NativeError) else (
                'transport-stream-unsupported' if isinstance(error, TSFormatError) else type(error).__name__)
            self.state, self.failed_at = 'error', time.monotonic()
            print('[cctv-native] '+self.error, flush=True)
            print('[cctv-native] diagnostics='+json.dumps(self.snapshot(), ensure_ascii=False), flush=True)
        finally:
            cancel_preparation.set()
            self._cancel_inputs()
            for task in upgrades.values():
                task.cancel()
            if engine:
                engine.close()
            self.native_context_closed()
            with self.condition:
                self.engine = None
                self.ring.clear()
                self.size = 0
                self.condition.notify_all()


class Handler(BaseHTTPRequestHandler):
    server_version = 'CCTVNative/0.1-experimental'
    def log_message(self, *_args):
        pass
    def send(self, status, body='', mime='text/plain; charset=utf-8'):
        if isinstance(body, str):
            body = body.encode()
        self.send_response(status)
        self.send_header('Content-Type', mime)
        self.send_header('Content-Length', str(len(body)))
        self.send_header('Cache-Control', 'max-age=5' if status == 200 and mime == 'video/mp2t' else 'no-store')
        if status == 503:
            self.send_header('Retry-After', '3')
        self.end_headers()
        if self.command != 'HEAD':
            try:
                self.wfile.write(body)
            except (OSError, TimeoutError):
                pass
    def do_HEAD(self):
        self.do_GET()
    def do_POST(self):
        self.send(405, 'GET/HEAD only')
    def do_GET(self):
        self.connection.settimeout(65)
        ch = self.server.channel
        path = urlsplit(self.path).path
        if path in ('/', '/all.m3u'):
            host = self.headers.get('Host', '')
            if not re.fullmatch(r'(?:\[[0-9A-Fa-f:.]+\]|[A-Za-z0-9][A-Za-z0-9.-]*)(?::\d{1,5})?', host):
                return self.send(400, 'invalid-host')
            try:
                parsed_host = urlsplit('//'+host)
                if parsed_host.port is not None and not 1 <= parsed_host.port <= 65535:
                    return self.send(400, 'invalid-host')
            except ValueError:
                return self.send(400, 'invalid-host')
            if self.command == 'GET' and self.server.args.warmup:
                ch.demand()
            return self.send(200, '#EXTM3U\n#EXTINF:-1 tvg-id="CCTV2" group-title="央视网页原分片",CCTV-2 财经\n'
                             +f'http://{host}/cctv2.m3u8\n', 'audio/x-mpegurl; charset=utf-8')
        if path == '/status':
            return self.send(200, json.dumps(ch.snapshot(), ensure_ascii=False), 'application/json; charset=utf-8')
        if path == '/cctv2.m3u8':
            if self.command == 'HEAD':
                return self.send(200, mime='application/vnd.apple.mpegurl')
            with ch.condition:
                ch.waiters += 1
            try:
                ch.demand()
                ch.note_client_request('playlist_requested')
                deadline = time.monotonic()+50
                with ch.condition:
                    while time.monotonic() < deadline and not ch.stop.is_set():
                        body = ch.playlist()
                        if body:
                            ch.note_client_request('playlist_available')
                            return self.send(200, body, 'application/vnd.apple.mpegurl')
                        if ch.state == 'error':
                            break
                        ch.demand()
                        ch.condition.wait(0.5)
                return self.send(503, json.dumps(ch.snapshot()), 'application/json; charset=utf-8')
            finally:
                with ch.condition:
                    ch.waiters -= 1
                    ch.last_request = time.monotonic()
                    ch.condition.notify_all()
        match = re.fullmatch(r'/media/([0-9a-f]{32})/(\d+)\.ts', path)
        if match:
            with ch.condition:
                if match[1] != ch.generation or ch.state != 'ready':
                    return self.send(410, 'expired-media')
                item = ch.ring.get(int(match[2]))
                if item is None:
                    return self.send(410, 'expired-media')
            if self.command != 'HEAD':
                ch.demand(start=False)
                ch.note_client_request('first_media_requested')
            return self.send(200, item[0], 'video/mp2t')
        self.send(404, 'not-found')


def main(argv=None):
    global _API_LEGACY_ENABLED, _HTTP_REUSE_ENABLED
    parser = argparse.ArgumentParser(description='CCTV-2 网页同源原分片订阅（Python + Node，无浏览器/转码）')
    parser.add_argument('port', type=int, nargs='?', default=18768)
    parser.add_argument('--bind', default='127.0.0.1')
    parser.add_argument('--node', default=shutil.which('node') or 'node')
    parser.add_argument('--cache-dir', default=str(Path.home()/'.cache'/'cctv-native'))
    parser.add_argument('--setup', action='store_true', help='安装独立Node依赖并缓存官方运行时后退出')
    parser.add_argument('--no-legacy-source-tls',action='store_true',help='关闭官方取源接口旧服务器握手兼容')
    parser.add_argument('--no-http-reuse', action='store_true', help='关闭上游 HTTPS 连接复用')
    parser.add_argument('--warmup', action='store_true', help='GET订阅时后台提前取源')
    parser.add_argument('--buffer-mb', type=int, default=64)
    parser.add_argument('--idle-timeout', type=int, default=120)
    args = parser.parse_args(argv)
    _API_LEGACY_ENABLED = not args.no_legacy_source_tls
    _HTTP_REUSE_ENABLED = not args.no_http_reuse
    if not 1 <= args.port <= 65535 or not 16 <= args.buffer_mb <= 256 or not 30 <= args.idle_timeout <= 3600:
        parser.error('invalid port/buffer/idle timeout')
    if not shutil.which(args.node):
        parser.error('需要 Node.js 20+；不需要 Chromium、Playwright 或 FFmpeg')
    major = subprocess.check_output([args.node, '--version'], text=True).strip().lstrip('v').split('.')[0]
    if int(major) < 20:
        parser.error('需要 Node.js 20+')
    if args.setup:
        setup(args)
        return
    root, modules, runtime = cache_paths(args)
    if not modules.is_dir() or not runtime.is_file():
        parser.error('首次请运行：python cctv-native.py --setup')
    channel = Channel(args)
    server = ThreadingHTTPServer((args.bind, args.port), Handler)
    server.daemon_threads = True
    server.channel, server.args = channel, args
    def stop(_signum, _frame):
        channel.stop.set()
        with channel.condition:
            channel.condition.notify_all()
        threading.Thread(target=server.shutdown, daemon=True).start()
    signal.signal(signal.SIGINT, stop)
    signal.signal(signal.SIGTERM, stop)
    print(f'央视网页原分片实验版：http://127.0.0.1:{args.port}/all.m3u；状态：/status', flush=True)
    try:
        server.serve_forever(poll_interval=0.2)
    finally:
        channel.stop.set()
        server.server_close()
        if channel.engine:
            channel.engine.close()
        if channel.thread:
            channel.thread.join(35)
        _HTTP_POOL.clear()


if __name__ == '__main__':
    main()
