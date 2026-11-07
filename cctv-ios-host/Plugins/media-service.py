#!/usr/bin/env python3
"""Bounded loopback HTTP transport for local JS and Python media packages."""
import argparse
import base64
import builtins
import collections
import hmac
import json
import os
import re
import stat
import threading
import time
import uuid
import urllib.error
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from host_media_runtime import MediaRuntime, MediaError, NativeJS, PythonSpider, playback, report_runtime_stage
from host_media_relay import MediaRelay, safe_error_summary


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, response, code, message, headers, new_url):
        return None


def is_direct_media_url(url):
    raw = str(url or '').lower()
    path = urllib.parse.urlsplit(raw).path
    if path.endswith(('.m3u8', '.m3u', '.mp4', '.m4v', '.mov', '.m4a', '.mp3',
                      '.aac', '.ts', '.mpd', '.flv', '.mkv', '.avi', '.webm', '.wmv', '.rmvb')):
        return True
    return any(tok in raw for tok in ('.m3u8', '.mp4', '.flv', '.mpd'))


def is_hls_url(url):
    raw = str(url or '').lower()
    path = urllib.parse.urlsplit(raw).path
    return path.endswith(('.m3u8', '.m3u')) or '.m3u8' in raw


def is_declared_hls(result, url):
    if is_hls_url(url):
        return True
    if not isinstance(result, dict):
        return False
    media_format = str(result.get('format') or result.get('mediaType') or
                       result.get('playbackType') or '').strip().lower()
    content_type = str(result.get('contentType') or result.get('content_type') or
                       result.get('mimeType') or result.get('mime') or '').split(';', 1)[0].strip().lower()
    return media_format in {'hls', 'm3u8', 'm3u', 'mpegurl'} or content_type in {
        'application/vnd.apple.mpegurl', 'application/x-mpegurl', 'audio/mpegurl'}


def is_dash_media(result, url):
    if urllib.parse.urlsplit(str(url or '')).path.lower().endswith('.mpd'):
        return True
    if not isinstance(result, dict):
        return False
    media_format = str(result.get('format') or result.get('mediaType') or
                       result.get('playbackType') or '').strip().lower()
    content_type = str(result.get('contentType') or result.get('content_type') or
                       result.get('mimeType') or result.get('mime') or '').split(';', 1)[0].strip().lower()
    return media_format in {'mpd', 'dash', 'mpeg-dash', 'application/dash+xml'} or content_type == 'application/dash+xml'


def is_extensionless_url(url):
    path = urllib.parse.urlsplit(str(url or '')).path
    name = path.rsplit('/', 1)[-1]
    return bool(name) and '.' not in name


class Server(ThreadingHTTPServer):
    daemon_threads = True
    block_on_close = False
    allow_reuse_address = True

    def __init__(self, address, runtime):
        self.runtime = runtime
        self.proxy_file_root = None
        # Older embedders/tests set the Node-only name directly.
        self.node_proxy_file_root = None
        self.relay = MediaRelay(stream_media=True)
        self.artwork_relay = MediaRelay()
        self.plugin_proxy_lock = threading.Lock()
        self.plugin_proxy_entries = collections.OrderedDict()
        self.host_fetch_token = uuid.uuid4().hex
        self.slots = threading.BoundedSemaphore(6)
        super().__init__(address, Handler)

    def server_close(self):
        self.artwork_relay.close()
        self.relay.close()
        with self.plugin_proxy_lock:
            self.plugin_proxy_entries.clear()
        super().server_close()

    def register_plugin_proxy(self, url, headers):
        token = uuid.uuid4().hex
        now = time.monotonic()
        with self.plugin_proxy_lock:
            for key in [key for key, value in self.plugin_proxy_entries.items()
                        if now - value['created'] > 3600]:
                self.plugin_proxy_entries.pop(key, None)
            while len(self.plugin_proxy_entries) >= 128:
                self.plugin_proxy_entries.popitem(last=False)
            self.plugin_proxy_entries[token] = {
                'url': str(url), 'upstreamHeaders': dict(headers or {}), 'created': now,
            }
        return f'http://127.0.0.1:{self.server_port}/proxy/{token}'

    def plugin_proxy(self, token):
        if not re.fullmatch(r'[0-9a-f]{32}', str(token or '')):
            return None
        now = time.monotonic()
        with self.plugin_proxy_lock:
            entry = self.plugin_proxy_entries.get(token)
            if entry and now - entry['created'] > 3600:
                self.plugin_proxy_entries.pop(token, None)
                return None
            if entry:
                entry['created'] = now
                self.plugin_proxy_entries.move_to_end(token)
                return dict(entry)
        return None

    def server_bind(self):
        import socketserver
        socketserver.TCPServer.server_bind(self)
        self.server_name, self.server_port = self.server_address[:2]

    def process_request(self, request, client_address):
        request.settimeout(10)
        if not self.slots.acquire(blocking=False):
            try:
                request.sendall(b'HTTP/1.0 503 Service Unavailable\r\nContent-Length: 0\r\nConnection: close\r\n\r\n')
            except OSError:
                pass
            self.shutdown_request(request)
            return
        try:
            super().process_request(request, client_address)
        except BaseException:
            self.slots.release()
            raise

    def process_request_thread(self, request, address):
        try:
            super().process_request_thread(request, address)
        finally:
            self.slots.release()


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def call_runtime(self, runtime, operation, args, request_id=None, correlation_id=None):
        """Attach request IDs to safe Python Spider queue diagnostics."""
        request_id = request_id or self.headers.get('X-CCTVHost-Request-ID', '')[:96]
        correlation_id = correlation_id or self.headers.get('X-CCTVHost-Correlation-ID', '')[:96]
        if not re.fullmatch(r'[A-Za-z0-9._-]{1,96}', request_id):
            request_id = uuid.uuid4().hex
        if not re.fullmatch(r'[A-Za-z0-9._-]{1,96}', correlation_id):
            correlation_id = ''
        thread = threading.current_thread()
        previous = getattr(thread, '_host_media_request_context', None)
        thread._host_media_request_context = {
            'request_id': request_id, 'correlation_id': correlation_id,
            'operation': str(operation or 'unknown')[:48],
        }
        phase = operation if operation in ('home', 'category', 'search', 'detail', 'play',
                    'capabilities', 'providers', 'configuration') else None
        if phase:
            report_runtime_stage('media_call_' + phase + '_started')
        try:
            result = runtime.call(operation, args)
            if phase:
                report_runtime_stage('media_call_' + phase + '_succeeded')
            return result
        except BaseException:
            if phase:
                report_runtime_stage('media_call_' + phase + '_failed')
            raise
        finally:
            if previous is None:
                try:
                    del thread._host_media_request_context
                except AttributeError:
                    pass
            else:
                thread._host_media_request_context = previous

    def send(self, status, value, head=False):
        body = json.dumps(value, ensure_ascii=False).encode()
        try:
            self.send_response(status)
            self.send_header('Content-Type', 'application/json; charset=utf-8')
            self.send_header('Content-Length', str(len(body)))
            self.send_header('Cache-Control', 'no-store')
            self.send_header('Connection', 'close')
            self.end_headers()
            if not head:
                self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError, TimeoutError):
            pass

    def send_proxy(self, result, head=False):
        if not isinstance(result, (list, tuple)) or len(result) < 3:
            raise MediaError('INVALID_PROXY', '来源未返回有效代理响应')
        try:
            status = int(result[0])
        except (ValueError, TypeError):
            raise MediaError('INVALID_PROXY', '代理状态码无效')
        if not 100 <= status <= 599:
            raise MediaError('INVALID_PROXY', '代理状态码超出范围')
        raw_headers = result[1]
        if isinstance(raw_headers, str):
            raw_headers = {'Content-Type': raw_headers}
        if isinstance(raw_headers, dict):
            raw_headers = {name: value for index, (name, value) in enumerate(raw_headers.items()) if index < 64}
        else:
            raw_headers = {}
        value = result[2]
        if isinstance(value, dict) and value.get('__cctvhostFileResponse') is True:
            self.send_proxy_file(status, raw_headers, value, head)
            return
        if isinstance(value, bytes):
            body = value
        elif isinstance(value, (bytearray, memoryview)):
            body = bytes(value)
        elif isinstance(value, str):
            body = value.encode('utf-8')
        elif isinstance(value, (dict, list)):
            body = json.dumps(value, ensure_ascii=False).encode('utf-8')
            if not any(str(name).lower() == 'content-type' for name in raw_headers):
                raw_headers['Content-Type'] = 'application/json; charset=utf-8'
        elif value is None:
            body = b''
        else:
            raise MediaError('INVALID_PROXY', '代理响应内容类型不受支持')
        if len(body) > 16 * 1024 * 1024:
            raise MediaError('RESULT_TOO_LARGE', '来源代理响应超过 16 MB；请按 Range 返回较小分片')
        no_body_status = 100 <= status < 200 or status in (204, 304)
        if no_body_status:
            body = b''
        self.send_proxy_headers(status, raw_headers, len(body), head)
        if not head:
            self.wfile.write(body)

    def send_proxy_headers(self, status, raw_headers, body_length, head=False, file_response=False):
        no_body_status = 100 <= status < 200 or status in (204, 304)
        self.send_response(status)
        has_type = False
        source_length = None
        blocked = {'connection', 'content-length', 'transfer-encoding', 'host', 'keep-alive', 'trailer', 'upgrade'}
        for name, value in raw_headers.items():
            name, value = str(name), str(value)
            if name.lower() == 'content-length' and len(value) <= 20 and value.isdigit():
                candidate_length = int(value)
                if candidate_length <= 9223372036854775807:
                    source_length = candidate_length
                continue
            if (len(name) > 128 or len(value) > 16384 or
                    not re.fullmatch(r"[!#$%&'*+.^_`|~0-9A-Za-z-]+", name) or
                    name.lower() in blocked or '\r' in value or '\n' in value):
                continue
            if name.lower() == 'content-type':
                has_type = True
            self.send_header(name, value)
        if not has_type:
            self.send_header('Content-Type', 'application/octet-stream')
        if not no_body_status:
            length = source_length if head and source_length is not None and not file_response else body_length
            self.send_header('Content-Length', str(length))
        self.send_header('Connection', 'close')
        self.end_headers()

    def send_proxy_file(self, status, headers, reference, head=False):
        """Stream a validated source-data file without expanding it into RAM/JSON."""
        root = self.server.proxy_file_root or self.server.node_proxy_file_root
        path = reference.get('path')
        offset, length = reference.get('offset'), reference.get('length')
        if not root or not isinstance(path, str) or not path or len(path) > 4096:
            raise MediaError('INVALID_PROXY', '媒体文件引用无效')
        if (isinstance(offset, bool) or not isinstance(offset, int) or
                not 0 <= offset <= 9223372036854775807 or
                isinstance(length, bool) or not isinstance(length, int) or
                not 0 <= length <= 9223372036854775807):
            raise MediaError('INVALID_PROXY', '媒体文件范围无效')
        media_file = None
        try:
            real_root = os.path.realpath(root)
            real_path = os.path.realpath(path)
            if os.path.commonpath((real_root, real_path)) != real_root or not os.path.isfile(real_path):
                raise ValueError('path outside source data directory')
            media_file = open(real_path, 'rb')
            details = os.fstat(media_file.fileno())
            if not stat.S_ISREG(details.st_mode) or offset > details.st_size or length > details.st_size - offset:
                raise ValueError('range outside regular file')
            media_file.seek(offset)
        except (OSError, ValueError, TypeError):
            if media_file is not None:
                media_file.close()
            raise MediaError('INVALID_PROXY', '媒体文件不可读或范围超出文件')
        with media_file:
            self.send_proxy_headers(status, headers, length, head, file_response=True)
            if head or 100 <= status < 200 or status in (204, 304):
                return
            remaining = length
            try:
                while remaining:
                    chunk = media_file.read(min(256 * 1024, remaining))
                    if not chunk:
                        # A cache truncated after validation must close this
                        # response; appending a JSON error would corrupt it.
                        self.close_connection = True
                        return
                    self.wfile.write(chunk)
                    remaining -= len(chunk)
            except (OSError, TimeoutError):
                self.close_connection = True

    def serve_plugin_proxy(self, method, path, query):
        args = {key: values[-1] for key, values in query.items()}
        if path.startswith('/proxy/'):
            entry = self.server.plugin_proxy(path[len('/proxy/'):])
            if not entry:
                self.send(404, {'ok': False, 'error': '本机代理会话已过期或不存在'}, method == 'HEAD')
                return
            args = {'url': entry['url'], 'upstreamHeaders': entry['upstreamHeaders']}
        headers = {}
        for name in ('User-Agent', 'Range', 'Accept', 'Referer', 'If-Range',
                     'If-None-Match', 'If-Modified-Since', 'Accept-Encoding'):
            value = self.headers.get(name)
            if value and len(value) <= 8192 and '\r' not in value and '\n' not in value:
                headers[name] = value
        args.update({'method': method, 'headers': headers,
                     'range': headers.get('Range', '')})
        result = self.call_runtime(self.server.runtime, 'proxy', args)
        try:
            self.send_proxy(result, method == 'HEAD')
        except (BrokenPipeError, ConnectionResetError, TimeoutError):
            # AVFoundation routinely cancels a probe or seeks while a response
            # is being delivered. Its closed socket is not a source failure.
            self.close_connection = True

    def serve_host_fetch(self):
        supplied = self.headers.get('X-CCTVHost-Host-Fetch', '')
        if not hmac.compare_digest(supplied, self.server.host_fetch_token):
            self.send_host_fetch_response(403, b'', reason='Forbidden')
            return
        try:
            length = int(self.headers.get('Content-Length', '0'))
            if not 0 <= length <= 2 * 1024 * 1024:
                raise ValueError('host HTTPS request payload exceeds 2 MB')
            payload = json.loads(self.rfile.read(length) or b'{}')
            if not isinstance(payload, dict):
                raise ValueError('host HTTPS request payload must be an object')
            url = payload.get('url')
            if not isinstance(url, str) or len(url) > 8192:
                raise ValueError('host HTTPS URL is invalid')
            parts = urllib.parse.urlsplit(url)
            parts.port
            if parts.scheme.lower() != 'https' or not parts.hostname or parts.username or parts.password:
                raise ValueError('host HTTPS fallback only accepts valid HTTPS URLs')
            method = str(payload.get('method') or 'GET').upper()
            if method not in ('GET', 'HEAD', 'POST', 'PUT', 'PATCH', 'DELETE', 'OPTIONS'):
                raise ValueError('host HTTPS method is unsupported')
            raw_body = payload.get('bodyBase64', '')
            if not isinstance(raw_body, str) or len(raw_body) > 2 * 1024 * 1024:
                raise ValueError('host HTTPS request body exceeds 1 MB')
            body = base64.b64decode(raw_body, validate=True) if raw_body else None
            if body and len(body) > 1024 * 1024:
                raise ValueError('host HTTPS request body exceeds 1 MB')
            raw_headers = payload.get('headers') if isinstance(payload.get('headers'), dict) else {}
            headers = {}
            blocked = {'content-length', 'connection', 'transfer-encoding',
                       'keep-alive', 'upgrade', 'proxy-authorization', 'proxy-connection'}
            for name, value in list(raw_headers.items())[:64]:
                name, value = str(name), str(value)
                if (1 <= len(name) <= 128 and len(value) <= 8192 and
                        re.fullmatch(r"[!#$%&'*+.^_`|~0-9A-Za-z-]+", name) and
                        '\r' not in value and '\n' not in value and name.lower() not in blocked):
                    headers[name] = value
            timeout_ms = payload.get('timeoutMs', 15000)
            if isinstance(timeout_ms, bool) or not isinstance(timeout_ms, (int, float)):
                timeout_ms = 15000
            timeout = max(1.0, min(float(timeout_ms) / 1000.0, 120.0))
            request = urllib.request.Request(url, data=body, headers=headers, method=method)
            opener = urllib.request.build_opener(NoRedirect())
            try:
                response = opener.open(request, timeout=timeout)
            except urllib.error.HTTPError as error:
                response = error
            try:
                status = int(response.getcode() or 502)
                raw_response_headers = response.headers
                response_body = b'' if method == 'HEAD' or status in (204, 304) else response.read(16 * 1024 * 1024 + 1)
                if len(response_body) > 16 * 1024 * 1024:
                    raise ValueError('host HTTPS response exceeds 16 MB')
                response_headers = list(raw_response_headers.raw_items()) if hasattr(raw_response_headers, 'raw_items') else list(raw_response_headers.items())
                reason = str(getattr(response, 'reason', '') or '')[:128]
            finally:
                response.close()
            self.send_host_fetch_response(status, response_body, response_headers, reason)
        except Exception as error:
            message = safe_error_summary(str(error)).encode('utf-8')[:2048]
            self.send_host_fetch_response(502, message, [('Content-Type', 'text/plain; charset=utf-8')], 'Bad Gateway')

    def send_host_fetch_response(self, status, body, headers=(), reason=''):
        status = max(100, min(599, int(status)))
        reason = re.sub(r'[\x00-\x1f\x7f]', '', str(reason or ''))[:128]
        no_body = 100 <= status < 200 or status in (204, 304)
        if no_body:
            body = b''
        source_length = None
        blocked = {'connection', 'content-length', 'transfer-encoding', 'host', 'keep-alive',
                   'trailer', 'upgrade', 'proxy-authenticate', 'proxy-authorization'}
        self.send_response(status, reason)
        for index, pair in enumerate(headers):
            if index >= 128:
                break
            name, value = str(pair[0]), str(pair[1])
            if name.lower() == 'content-length' and len(value) <= 20 and value.isdigit():
                source_length = int(value)
                continue
            if (len(name) > 128 or len(value) > 16384 or
                    not re.fullmatch(r"[!#$%&'*+.^_`|~0-9A-Za-z-]+", name) or
                    name.lower() in blocked or '\r' in value or '\n' in value):
                continue
            self.send_header(name, value)
        if not no_body:
            self.send_header('Content-Length', str(len(body)))
        elif source_length is not None and source_length <= 9223372036854775807:
            self.send_header('Content-Length', str(source_length))
        self.send_header('Connection', 'close')
        self.end_headers()
        if body:
            self.wfile.write(body)

    def do_HEAD(self):
        path = urllib.parse.urlsplit(self.path).path
        if path == '/_cctvhost/host-fetch':
            self.send_host_fetch_response(405, b'', [('Allow', 'POST')], 'Method Not Allowed')
            return
        if path.startswith('/artwork/'):
            self.server.artwork_relay.serve(self, path.rsplit('/', 1)[-1], True)
            return
        if path.startswith('/media/'):
            self.server.relay.serve(self, path.rsplit('/', 1)[-1], True)
            return
        if path.startswith('/spider/'):
            try:
                self.route_plugin_path('HEAD')
            except Exception as error:
                self.send(502, {'ok': False, 'error': str(error)}, True)
            return
        if path == '/proxy' or path.startswith('/proxy/'):
            try:
                parts = urllib.parse.urlsplit(self.path)
                query = urllib.parse.parse_qs(parts.query, max_num_fields=32)
                self.serve_plugin_proxy('HEAD', path, query)
            except Exception as error:
                self.send(502, {'ok': False, 'error': str(error)}, True)
            return
        if path.endswith(('.m3u', '.m3u8')) or path == '/m3u':
            self.send_response(200)
            self.send_header('Content-Type', 'application/vnd.apple.mpegurl')
            self.send_header('Content-Length', '0')
            self.send_header('Connection', 'close')
            self.end_headers()
            return
        # Probes never run source code or resolve a playback ticket.
        self.send(200, {'ok': not self.server.runtime.stopping.is_set()}, True)

    def do_GET(self):
        self.route(False)

    def do_POST(self):
        self.route(True)

    def route_plugin_path(self, method):
        parts = urllib.parse.urlsplit(self.path)
        headers = {key: self.headers.get(key, '') for key in ('User-Agent', 'Range', 'Accept', 'Referer') if self.headers.get(key)}
        args = {'method': method, 'path': parts.path, 'query': {key: values[-1] for key, values in urllib.parse.parse_qs(parts.query).items()},
                'headers': headers, 'host': f'127.0.0.1:{self.server.server_port}',
                'userAgent': self.headers.get('User-Agent', '')}
        if method not in ('GET', 'HEAD'):
            length = int(self.headers.get('Content-Length', '0'))
            if not 0 <= length <= 65536:
                raise MediaError('INVALID_INPUT', 'Spider 路由请求内容超过 64 KB')
            args['body'] = json.loads(self.rfile.read(length) or b'{}')
        result = self.call_runtime(self.server.runtime, 'route', args)
        if not isinstance(result, dict):
            raise MediaError('INVALID_PROXY', 'Spider 路由未返回有效响应')
        status = max(100, min(599, int(result.get('statusCode') or 200)))
        body = base64.b64decode(result['bodyBase64'], validate=True) if result.get('bodyBase64') else result.get('body', '')
        if not isinstance(body, bytes):
            body = body.encode('utf-8') if isinstance(body, str) else json.dumps(body, ensure_ascii=False).encode('utf-8')
        if len(body) > 8 * 1024 * 1024:
            raise MediaError('RESULT_TOO_LARGE', 'Spider 代理响应超过 8 MB')
        self.send_response(status)
        route_headers = result.get('headers') if isinstance(result.get('headers'), dict) else {}
        for name, value in route_headers.items():
            if str(name).lower() not in ('connection', 'content-length', 'transfer-encoding', 'host') and '\r' not in str(name) + str(value) and '\n' not in str(name) + str(value):
                self.send_header(str(name), str(value))
        if not any(str(name).lower() == 'content-type' for name in route_headers):
            self.send_header('Content-Type', 'application/json; charset=utf-8' if isinstance(result.get('body'), dict) else 'application/octet-stream')
        self.send_header('Content-Length', str(len(body)))
        self.send_header('Connection', 'close')
        self.end_headers()
        if method != 'HEAD':
            self.wfile.write(body)

    def relay_artwork(self, result):
        if not isinstance(result, dict):
            return result
        result = dict(result)
        headers = result.pop('posterHeaders', None)
        if headers and result.get('poster'):
            token = self.server.artwork_relay.register(result['poster'], headers)
            result['poster'] = f'http://127.0.0.1:{self.server.server_port}/artwork/{token}'
        if isinstance(result.get('items'), list):
            result['items'] = [self.relay_artwork(item) for item in result['items']]
        return result

    def route(self, post):
        runtime = self.server.runtime
        request_id = self.headers.get('X-CCTVHost-Request-ID', '')[:96]
        if not re.fullmatch(r'[A-Za-z0-9._-]{1,96}', request_id):
            request_id = uuid.uuid4().hex
        correlation_id = self.headers.get('X-CCTVHost-Correlation-ID', '')[:96]
        if not re.fullmatch(r'[A-Za-z0-9._-]{1,96}', correlation_id):
            correlation_id = ''
        operation = 'route'
        try:
            parts = urllib.parse.urlsplit(self.path)
            if parts.path == '/_cctvhost/host-fetch':
                if not post:
                    self.send_host_fetch_response(405, b'', [('Allow', 'POST')], 'Method Not Allowed')
                    return
                self.serve_host_fetch()
                return
            if parts.path.startswith('/artwork/'):
                self.server.artwork_relay.serve(self, parts.path.rsplit('/', 1)[-1])
                return
            if parts.path.startswith('/media/'):
                self.server.relay.serve(self, parts.path.rsplit('/', 1)[-1])
                return
            if parts.path.startswith('/spider/'):
                self.route_plugin_path('POST' if post else 'GET')
                return
            if parts.path == '/proxy' or parts.path.startswith('/proxy/'):
                query = urllib.parse.parse_qs(parts.query, max_num_fields=32)
                self.serve_plugin_proxy('GET', parts.path, query)
                return
            if parts.path in ('/all.m3u', '/all.m3u8', '/m3u'):
                channels = self.call_runtime(runtime, 'catalog', {}, request_id, correlation_id)
                def clean(value):
                    return str(value or '').replace('\r', ' ').replace('\n', ' ').replace('"', "'")
                lines = ['#EXTM3U']
                for channel in channels:
                    identifier = str(channel.get('ref', channel.get('id', '')))
                    if not identifier:
                        continue
                    lines += [f'#EXTINF:-1 tvg-name="{clean(channel.get("name"))}" tvg-logo="{clean(channel.get("logo"))}" group-title="{clean(channel.get("group", "本机插件"))}",{clean(channel.get("name", identifier))}',
                              f'http://127.0.0.1:{self.server.server_port}/live/{urllib.parse.quote(identifier, safe="")}.m3u8']
                body = ('\n'.join(lines) + '\n').encode()
                self.send_response(200)
                self.send_header('Content-Type', 'application/x-mpegURL; charset=utf-8')
                self.send_header('Content-Length', str(len(body)))
                self.send_header('Connection', 'close')
                self.end_headers()
                self.wfile.write(body)
                return
            if parts.path.startswith('/live/') and parts.path.endswith('.m3u8'):
                ref = urllib.parse.unquote(parts.path[len('/live/'):-len('.m3u8')])
                query = {key: values[-1] for key, values in urllib.parse.parse_qs(parts.query).items()}
                result = self.call_runtime(runtime, 'resolve', {'ref': ref, 'id': ref, 'query': query,
                    'selfBase': f'http://127.0.0.1:{self.server.server_port}', 'userAgent': self.headers.get('User-Agent', '')})
                manifest = result.get('manifestText') if isinstance(result, dict) else None
                if isinstance(manifest, str) and manifest.lstrip().startswith('#EXTM3U'):
                    body = manifest.encode()
                    self.send_response(200)
                    self.send_header('Content-Type', 'application/vnd.apple.mpegurl')
                    self.send_header('Content-Length', str(len(body)))
                    self.send_header('Connection', 'close')
                    self.end_headers()
                    self.wfile.write(body)
                    return
                session_id = result.get('sessionID') if isinstance(result, dict) else None
                refresh_interval = float(result.get('refreshInterval') or 0) if isinstance(result, dict) else 0
                refresh_after = float(result.get('refreshAfter') or 0) if isinstance(result, dict) else 0
                expires_at = float(result.get('expiresAt') or 0) if isinstance(result, dict) else 0
                refresh = None
                if isinstance(session_id, str) and session_id:
                    def refresh_media():
                        value = self.call_runtime(runtime, 'refreshMedia', {'sessionID': session_id}, request_id, correlation_id)
                        if not isinstance(value, dict) or not isinstance(value.get('url'), str):
                            raise MediaError('MEDIA_REFRESH_FAILED', '插件没有返回有效的媒体刷新结果', True)
                        return {'url': value['url'], 'headers': value.get('headers') or {},
                                'expiresAt': value.get('expiresAt') or expires_at,
                                'refreshInterval': value.get('refreshInterval') or refresh_interval,
                                'refreshAfter': value.get('refreshAfter') or 0}
                    refresh = refresh_media
                result = playback(result)
                if result['parse']:
                    raise MediaError('PARSER_REQUIRED', '此频道返回网页，请通过影视页面打开')
                url = result['url']
                if result['headers'] or is_hls_url(url) or is_extensionless_url(url):
                    url = f'http://127.0.0.1:{self.server.server_port}/media/' + self.server.relay.register(
                        url, result['headers'], diagnostic_id=correlation_id or request_id,
                        refresh=refresh,refresh_after=refresh_after,refresh_interval=refresh_interval)
                self.send_response(302)
                self.send_header('Location', url)
                self.send_header('Content-Length', '0')
                self.send_header('Connection', 'close')
                self.end_headers()
                return
            if parts.path in ('/', '/health'):
                health = runtime.health_status()
                self.send(200 if not runtime.stopping.is_set() else 503,
                          {'ok': not runtime.stopping.is_set(), 'media': True, **health})
                return
            if not parts.path.startswith('/api/v1/'):
                raise MediaError('NOT_FOUND', '没有此接口')
            operation = parts.path.rsplit('/', 1)[-1]
            if operation not in ('capabilities', 'home', 'category', 'search', 'detail', 'play', 'providers', 'catalog', 'resolve', 'epg', 'configuration', 'invalidate'):
                raise MediaError('NOT_FOUND', '没有此接口')
            if operation == 'invalidate' and not post:
                raise MediaError('NOT_FOUND', '刷新配置缓存需要 POST 请求')
            args = {key: values[-1] for key, values in urllib.parse.parse_qs(parts.query).items()}
            if post:
                length = int(self.headers.get('Content-Length', '0'))
                if not 0 <= length <= 65536:
                    raise MediaError('INVALID_INPUT', '请求内容超过 64 KB')
                args.update(json.loads(self.rfile.read(length) or b'{}'))
            if 'page' in args:
                args['page'] = max(1, min(10000, int(args['page'])))
            if isinstance(args.get('filters'), str):
                args['filters'] = json.loads(args['filters'])
            args.setdefault('host', f'127.0.0.1:{self.server.server_port}')
            result = self.call_runtime(runtime, operation, args, request_id, correlation_id)
            if operation in ('home', 'category', 'search', 'detail'):
                result = self.relay_artwork(result)
            if operation == 'play':
                headers = result.get('headers') or {}
                base_headers = result.get('baseHeaders') if isinstance(result.get('baseHeaders'), dict) else headers
                diagnostic_id = correlation_id or request_id
                def relay_media_url(address, request_headers, expected_hls=False):
                    token = self.server.relay.register(address, request_headers,
                        diagnostic_id=diagnostic_id, expected_hls=expected_hls, resource_scope=request_id)
                    return f'http://127.0.0.1:{self.server.server_port}/media/{token}'
                result = dict(result)
                direct_media = bool(result.get('directMedia') or is_direct_media_url(result.get('url')))
                alternate_proxy = any(isinstance(item, dict) and item.get('proxy')
                                      for item in result.get('alternates', []))
                if result.get('proxy') or alternate_proxy:
                    capabilities = self.call_runtime(runtime, 'capabilities', {}, request_id, correlation_id)
                    if not isinstance(capabilities, dict) or 'proxy' not in (capabilities.get('capabilities') or []):
                        raise MediaError('PROXY_UNSUPPORTED', '播放结果要求本机代理，但此来源没有提供 proxy/localProxy 方法')
                if result.get('proxy'):
                    result['originalURL'] = result['url']
                    result['url'] = self.server.register_plugin_proxy(result['url'], headers)
                    result['headers'] = {}
                    result['baseHeaders'] = {}
                    result['directMedia'] = True
                    result['nativePlayable'] = True
                can_relay_primary = (not result.get('proxy') and not is_dash_media(result, result.get('url')) and (headers or is_declared_hls(result, result.get('url'))
                                     or is_extensionless_url(result.get('url')))
                                     and (not result.get('parse') or direct_media))
                if can_relay_primary:
                    result['originalURL'] = result['url']
                    result['url'] = relay_media_url(result['url'], headers,
                                                    expected_hls=is_declared_hls(result, result.get('url')))
                alternates = result.get('alternates')
                if isinstance(alternates, list):
                    relayed = []
                    for alternate in alternates:
                        if not isinstance(alternate, dict) or not isinstance(alternate.get('url'), str):
                            continue
                        alternate = dict(alternate)
                        address = alternate['url']
                        alternate_headers = dict(base_headers)
                        alternate_headers.update(alternate.get('headers') or {})
                        if alternate.get('proxy') or result.get('proxy'):
                            if result.get('proxy') and not alternate.get('proxy'):
                                alternate['proxy'] = True
                            alternate['originalURL'] = address
                            alternate['url'] = self.server.register_plugin_proxy(address, alternate_headers)
                            alternate.pop('headers', None)
                            relayed.append(alternate)
                            continue
                        alternate_media = dict(alternate)
                        alternate_direct = bool(alternate_media.get('directMedia') or
                                                is_direct_media_url(address) or
                                                is_declared_hls(alternate_media, address))
                        if (not is_dash_media(alternate_media, address) and
                                (alternate_headers or is_declared_hls(alternate_media, address)
                             or is_extensionless_url(address))
                                and (not alternate_media.get('parse') or alternate_direct)):
                            alternate['originalURL'] = address
                            alternate['url'] = relay_media_url(address, alternate_headers,
                                expected_hls=is_declared_hls(alternate_media, address))
                        relayed.append(alternate)
                    result['alternates'] = relayed
            self.send(200, {'ok': True, 'data': result})
        except (Exception, SystemExit) as error:
            code = getattr(error, 'code', 'PLUGIN_ERROR')
            status = 404 if code == 'NOT_FOUND' else 503 if code in ('BUSY', 'STOPPING') else 502
            retryable = bool(getattr(error, 'retryable', False))
            print('[CCTVHostMediaAPI] ' + json.dumps({
                'event': 'media_api_failed', 'request_id': request_id,
                'correlation_id': correlation_id, 'operation': operation,
                'failure_stage': str(code).lower()[:64], 'error_type': type(error).__name__,
                'error_summary': safe_error_summary(error),
                'retryable': retryable,
            }, ensure_ascii=False, separators=(',', ':')))
            self.send(status, {'ok': False, 'error': {'code': code, 'message': str(error),
                                                    'retryable': retryable, 'request_id': request_id,
                                                    'stage': str(code).lower()[:64]}})


def main():
    report_runtime_stage('media_service_main_started')
    parser = argparse.ArgumentParser()
    parser.add_argument('port', type=int)
    parser.add_argument('--bind', default='127.0.0.1')
    parser.add_argument('--package', required=True)
    parser.add_argument('--manifest', required=True)
    parser.add_argument('--data-dir', required=True)
    args = parser.parse_args()
    manifest = json.loads(args.manifest)
    os.makedirs(args.data_dir, exist_ok=True)
    runtime = MediaRuntime()
    server = Server((args.bind, args.port), runtime)
    if manifest['runtime'] in ('python', 'node'):
        server.proxy_file_root = os.path.realpath(args.data_dir)
    report_runtime_stage('media_service_listener_bound')
    def create_engine():
        if manifest['runtime'] == 'python':
            if str(manifest.get('entry', '')).startswith('csp_') or manifest.get('protocol') == 'jar-bridge':
                from csp_adapter import CSPAdapter
                return CSPAdapter(manifest['entry'], manifest.get('options'))
            engine = PythonSpider(args.package, manifest['entry'], manifest.get('options'),
                                  f'http://127.0.0.1:{server.server_port}/proxy', args.data_dir)
            engine.spider._cctvhost_file_proxy_supported = True
            return engine
        if manifest['runtime'] in ('jar-bridge', 'csp'):
            from csp_adapter import CSPAdapter
            return CSPAdapter(manifest.get('entry') or manifest.get('api') or manifest.get('className'),
                              manifest.get('options') or manifest.get('ext') or '')
        node_manifest = dict(manifest, dataDirectory=args.data_dir,
                             proxyURL=f'http://127.0.0.1:{server.server_port}/proxy')
        if manifest['runtime'] == 'node':
            server.node_proxy_file_root = os.path.realpath(args.data_dir)
            node_manifest.update(
                hostFetchURL=f'http://127.0.0.1:{server.server_port}/_cctvhost/host-fetch',
                hostFetchToken=server.host_fetch_token)
        return NativeJS(args.package, node_manifest, node=manifest['runtime'] == 'node')
    def initialization_failed(error):
        print('[影视] 资源初始化失败：%s: %s' % (type(error).__name__, error))
    report_runtime_stage('media_engine_prepare_started')
    runtime.start_initialization(create_engine, initialization_failed)
    print('[影视] 本机 HTTP 服务已监听，正在准备资源：', manifest.get('name', manifest['entry']))
    def stop():
        report_runtime_stage('media_service_stop_requested')
        runtime.stopping.set()
        server.relay.close()
        server.shutdown()
        server.server_close()
        runtime.close()
        return True
    builtins._cctvhost_stop_service = stop
    try:
        report_runtime_stage('media_server_loop_started')
        server.serve_forever(poll_interval=.1)
    finally:
        report_runtime_stage('media_server_loop_exited')
        server.relay.close()
        server.server_close()
        report_runtime_stage('media_service_listener_closed')
        runtime.close()


if __name__ == '__main__':
    main()
