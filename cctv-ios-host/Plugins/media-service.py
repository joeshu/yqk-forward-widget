#!/usr/bin/env python3
"""Bounded loopback HTTP transport for local JS and Python media packages."""
import argparse
import builtins
import json
import os
import threading
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from host_media_runtime import MediaRuntime, MediaError, NativeJS, PythonSpider, playback
from host_media_relay import MediaRelay


class Server(ThreadingHTTPServer):
    daemon_threads = True
    block_on_close = False
    allow_reuse_address = True

    def __init__(self, address, runtime):
        self.runtime = runtime
        self.relay = MediaRelay()
        self.slots = threading.BoundedSemaphore(6)
        super().__init__(address, Handler)

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

    def do_HEAD(self):
        path = urllib.parse.urlsplit(self.path).path
        if path.startswith('/media/'):
            self.server.relay.serve(self, path.rsplit('/', 1)[-1], True)
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

    def route(self, post):
        runtime = self.server.runtime
        try:
            parts = urllib.parse.urlsplit(self.path)
            if parts.path.startswith('/media/'):
                self.server.relay.serve(self, parts.path.rsplit('/', 1)[-1])
                return
            if parts.path == '/proxy':
                args = {key: values[-1] for key, values in urllib.parse.parse_qs(parts.query).items()}
                result = runtime.call('proxy', args)
                if not isinstance(result, (list, tuple)) or len(result) < 3:
                    raise MediaError('INVALID_PROXY', '来源未返回有效代理响应')
                body = result[2].encode() if isinstance(result[2], str) else result[2]
                if not isinstance(body, bytes) or len(body) > 8 * 1024 * 1024:
                    raise MediaError('RESULT_TOO_LARGE', '来源代理响应超过 8 MB')
                self.send_response(int(result[0]))
                self.send_header('Content-Type', str(result[1]))
                self.send_header('Content-Length', str(len(body)))
                self.send_header('Connection', 'close')
                self.end_headers()
                self.wfile.write(body)
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
                if result['headers']:
                    url = f'http://127.0.0.1:{self.server.server_port}/media/' + self.server.relay.register(url, result['headers'])
                self.send_response(302)
                self.send_header('Location', url)
                self.send_header('Content-Length', '0')
                self.send_header('Connection', 'close')
                self.end_headers()
                return
            if parts.path in ('/', '/health'):
                self.send(200 if not runtime.stopping.is_set() else 503,
                          {'ok': not runtime.stopping.is_set(), 'media': True})
                return
            if not parts.path.startswith('/api/v1/'):
                raise MediaError('NOT_FOUND', '没有此接口')
            operation = parts.path.rsplit('/', 1)[-1]
            if operation not in ('capabilities', 'home', 'category', 'search', 'detail', 'play', 'providers', 'catalog', 'resolve', 'epg'):
                raise MediaError('NOT_FOUND', '没有此接口')
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
            result = runtime.call(operation, args)
            if operation == 'play' and result.get('headers') and not result.get('parse'):
                token = self.server.relay.register(result['url'], result['headers'])
                result = dict(result, originalURL=result['url'],
                              url=f'http://127.0.0.1:{self.server.server_port}/media/{token}')
            self.send(200, {'ok': True, 'data': result})
        except (Exception, SystemExit) as error:
            code = getattr(error, 'code', 'PLUGIN_ERROR')
            status = 404 if code == 'NOT_FOUND' else 503 if code in ('BUSY', 'STOPPING') else 502
            self.send(status, {'ok': False, 'error': {'code': code, 'message': str(error),
                                                    'retryable': bool(getattr(error, 'retryable', False))}})


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
    if manifest['runtime'] == 'python':
        engine = PythonSpider(args.package, manifest['entry'], manifest.get('options'),
                              f'http://127.0.0.1:{args.port}/proxy')
    else:
        engine = NativeJS(args.package, dict(manifest, dataDirectory=args.data_dir, proxyURL=f'http://127.0.0.1:{args.port}/proxy'), node=manifest['runtime'] == 'node')
    runtime = MediaRuntime(engine)
    server = Server((args.bind, args.port), runtime)
    def stop():
        runtime.stopping.set()
        server.relay.close()
        server.shutdown()
        server.server_close()
        runtime.close()
        return True
    builtins._cctvhost_stop_service = stop
    try:
        print('[影视] 本机资源已就绪:', manifest.get('name', manifest['entry']))
        server.serve_forever(poll_interval=.1)
    finally:
        server.relay.close()
        server.server_close()
        runtime.close()


if __name__ == '__main__':
    main()
