#!/usr/bin/env python3
"""Bounded loopback HTTP transport for local JS and Python media packages."""
import argparse
import base64
import builtins
import json
import os
import re
import threading
import uuid
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from host_media_runtime import MediaRuntime, MediaError, NativeJS, PythonSpider, playback
from host_media_relay import MediaRelay, safe_error_summary


def is_direct_media_url(url):
    path = urllib.parse.urlsplit(str(url or '')).path.lower()
    return path.endswith(('.m3u8', '.m3u', '.mp4', '.m4v', '.mov', '.m4a', '.mp3'))


def is_hls_url(url):
    path = urllib.parse.urlsplit(str(url or '')).path.lower()
    return path.endswith(('.m3u8', '.m3u'))


class Server(ThreadingHTTPServer):
    daemon_threads = True
    block_on_close = False
    allow_reuse_address = True

    def __init__(self, address, runtime):
        self.runtime = runtime
        self.relay = MediaRelay()
        self.artwork_relay = MediaRelay()
        self.slots = threading.BoundedSemaphore(6)
        super().__init__(address, Handler)

    def server_close(self):
        self.artwork_relay.close()
        self.relay.close()
        super().server_close()

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
        if len(body) > 8 * 1024 * 1024:
            raise MediaError('RESULT_TOO_LARGE', '来源代理响应超过 8 MB')
        no_body_status = 100 <= status < 200 or status in (204, 304)
        if no_body_status:
            body = b''
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
            self.send_header('Content-Length', str(source_length if head and source_length is not None else len(body)))
        self.send_header('Connection', 'close')
        self.end_headers()
        if not head:
            self.wfile.write(body)

    def do_HEAD(self):
        path = urllib.parse.urlsplit(self.path).path
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
        if path == '/proxy':
            try:
                args = {key: values[-1] for key, values in urllib.parse.parse_qs(urllib.parse.urlsplit(self.path).query).items()}
                args.update({'method': 'HEAD', 'headers': {key: self.headers.get(key, '') for key in ('User-Agent', 'Range', 'Accept', 'Referer') if self.headers.get(key)}})
                self.send_proxy(self.server.runtime.call('proxy', args), True)
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
        result = self.server.runtime.call('route', args)
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
            if parts.path.startswith('/artwork/'):
                self.server.artwork_relay.serve(self, parts.path.rsplit('/', 1)[-1])
                return
            if parts.path.startswith('/media/'):
                self.server.relay.serve(self, parts.path.rsplit('/', 1)[-1])
                return
            if parts.path.startswith('/spider/'):
                self.route_plugin_path('POST' if post else 'GET')
                return
            if parts.path == '/proxy':
                args = {key: values[-1] for key, values in urllib.parse.parse_qs(parts.query).items()}
                args.update({'method': 'GET', 'headers': {key: self.headers.get(key, '') for key in ('User-Agent', 'Range', 'Accept', 'Referer') if self.headers.get(key)}})
                self.send_proxy(runtime.call('proxy', args))
                return
            if parts.path in ('/all.m3u', '/all.m3u8', '/m3u'):
                channels = runtime.call('catalog')
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
                result = runtime.call('resolve', {'ref': ref, 'id': ref, 'selfBase': f'http://127.0.0.1:{self.server.server_port}', 'userAgent': self.headers.get('User-Agent', '')})
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
                result = playback(result)
                if result['parse']:
                    raise MediaError('PARSER_REQUIRED', '此频道返回网页，请通过影视页面打开')
                url = result['url']
                if result['headers'] or is_hls_url(url):
                    url = f'http://127.0.0.1:{self.server.server_port}/media/' + self.server.relay.register(
                        url, result['headers'], diagnostic_id=correlation_id or request_id)
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
            result = runtime.call(operation, args)
            if operation in ('home', 'category', 'search', 'detail'):
                result = self.relay_artwork(result)
            if (operation == 'play' and (result.get('headers') or is_hls_url(result.get('url')))
                    and (not result.get('parse') or is_direct_media_url(result.get('url')))):
                headers = result.get('headers') or {}
                diagnostic_id = correlation_id or request_id
                def relay_media_url(address):
                    token = self.server.relay.register(address, headers, diagnostic_id=diagnostic_id)
                    return f'http://127.0.0.1:{self.server.server_port}/media/{token}'
                result = dict(result, originalURL=result['url'], url=relay_media_url(result['url']))
                alternates = result.get('alternates')
                if isinstance(alternates, list):
                    relayed = []
                    for alternate in alternates:
                        if not isinstance(alternate, dict) or not isinstance(alternate.get('url'), str):
                            continue
                        alternate = dict(alternate)
                        address = alternate['url']
                        if headers or is_hls_url(address):
                            alternate['originalURL'] = address
                            alternate['url'] = relay_media_url(address)
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
    def create_engine():
        if manifest['runtime'] == 'python':
            return PythonSpider(args.package, manifest['entry'], manifest.get('options'),
                                f'http://127.0.0.1:{args.port}/proxy')
        return NativeJS(args.package, dict(manifest, dataDirectory=args.data_dir,
                                           proxyURL=f'http://127.0.0.1:{args.port}/proxy'),
                        node=manifest['runtime'] == 'node')
    def initialization_failed(error):
        print('[影视] 资源初始化失败：%s: %s' % (type(error).__name__, error))
    runtime.start_initialization(create_engine, initialization_failed)
    print('[影视] 本机 HTTP 服务已监听，正在准备资源：', manifest.get('name', manifest['entry']))
    def stop():
        runtime.stopping.set()
        server.relay.close()
        server.shutdown()
        server.server_close()
        runtime.close()
        return True
    builtins._cctvhost_stop_service = stop
    try:
        server.serve_forever(poll_interval=.1)
    finally:
        server.relay.close()
        server.server_close()
        runtime.close()


if __name__ == '__main__':
    main()
