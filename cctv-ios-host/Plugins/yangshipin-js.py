#!/usr/bin/env python3
"""CCTVHost HTTP adapter. Extraction, signing and manifest refresh run in original JS.
Requires CCTVHost's native JavaScriptCore bridge; this file does not port JS to Python.
"""
import argparse
import base64
import builtins
import datetime
import json
import threading
import urllib.parse
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from xml.sax.saxutils import escape


class JSAdapter:
    def __init__(self, bridge=None):
        self.bridge = bridge or getattr(builtins, '_cctvhost_js_call', None)
        if not self.bridge:
            raise RuntimeError('需要包含 JavaScriptCore 桥接的 CCTVHost；此文件仅为 HTTP 适配器')
        self.session = uuid.uuid4().hex
        self.stopping = threading.Event()
        self.epg_lock = threading.Lock()
        self.epg = {}
        self.epg_pending = set()
        self.epg_slots = threading.BoundedSemaphore(1)
        self.call('start')
        try:
            self.channels = self.call('catalog')
            self.by_id = {channel['id']: channel for channel in self.channels}
        except BaseException:
            self.call('stop')
            raise
        self.server = None

    def call(self, operation, **payload):
        if self.stopping.is_set() and operation != 'stop':
            raise RuntimeError('JS 服务正在停止')
        payload['session'] = self.session
        answer = json.loads(self.bridge(operation, json.dumps(payload, ensure_ascii=False)))
        if not answer.get('ok'):
            raise RuntimeError(answer.get('error') or 'JS 提取器调用失败')
        return answer.get('result')

    def subscription(self, base):
        lines = [f'#EXTM3U x-tvg-url="{base}/epg.xml"']
        for channel in self.channels:
            group = '央视频 JS · 央视' if channel['id'].startswith(('cctv', 'cgtn', 'cetv')) else '央视频 JS · 卫视'
            lines += [f'#EXTINF:-1 tvg-id="{channel["ref"]}" tvg-name="{channel["name"]}" tvg-logo="{channel["logo"]}" group-title="{group}" catchup="none",{channel["name"]}',
                      f'{base}/{channel["id"]}.m3u8']
        return '\n'.join(lines) + '\n'

    def refresh_epg(self, channel):
        day = datetime.datetime.now(datetime.timezone(datetime.timedelta(hours=8))).strftime('%Y%m%d')
        key = (channel['ref'], day)
        with self.epg_lock:
            if key in self.epg or key in self.epg_pending or not self.epg_slots.acquire(blocking=False):
                return
            self.epg_pending.add(key)
        def run():
            try:
                rows = self.call('epg', ref=channel['ref'], day=day)
                if not self.stopping.is_set():
                    with self.epg_lock:
                        self.epg = {k: v for k, v in self.epg.items() if k[1] == day}
                        self.epg[key] = rows
            except Exception as error:
                if not self.stopping.is_set():
                    print('[JS EPG] 暂不可用:', error)
            finally:
                with self.epg_lock:
                    self.epg_pending.discard(key)
                self.epg_slots.release()
        try:
            threading.Thread(target=run, daemon=True, name='js-epg').start()
        except BaseException:
            with self.epg_lock:
                self.epg_pending.discard(key)
            self.epg_slots.release()
            raise

    def xmltv(self):
        def stamp(ms):
            return datetime.datetime.fromtimestamp(ms / 1000, datetime.timezone.utc).strftime('%Y%m%d%H%M%S +0000')
        lines = ['<?xml version="1.0" encoding="UTF-8"?><tv generator-info-name="CCTVHost JS">']
        for channel in self.channels:
            lines.append(f'<channel id="{channel["ref"]}"><display-name>{escape(channel["name"])}</display-name></channel>')
        with self.epg_lock:
            snapshot = list(self.epg.items())
        for (ref, _), rows in snapshot:
            for row in rows:
                lines.append(f'<programme channel="{ref}" start="{stamp(row["start"])}" stop="{stamp(row["stop"])}"><title lang="zh">{escape(row["title"])}</title></programme>')
        return ''.join(lines) + '</tv>'

    def stop(self):
        if self.stopping.is_set():
            return True
        self.stopping.set()
        try:
            self.call('stop')  # Cancels JS fetches/timers and wakes pending HTTP workers.
        finally:
            if self.server:
                self.server.shutdown()
                self.server.server_close()
        return True


class Server(ThreadingHTTPServer):
    daemon_threads = True
    block_on_close = False
    allow_reuse_address = True
    def __init__(self, address, adapter):
        self.adapter = adapter
        self.slots = threading.BoundedSemaphore(12)
        super().__init__(address, Handler)

    def server_bind(self):
        # Avoid reverse DNS even when this adapter is used outside the session manager.
        import socketserver
        socketserver.TCPServer.server_bind(self)
        self.server_name, self.server_port = self.server_address[:2]

    def process_request(self, request, address):
        request.settimeout(15)
        if not self.slots.acquire(blocking=False):
            try:
                request.sendall(b'HTTP/1.0 503 Service Unavailable\r\nRetry-After: 1\r\nContent-Length: 0\r\n\r\n')
            except OSError:
                pass
            self.shutdown_request(request)
            return
        try:
            super().process_request(request, address)
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

    def send_body(self, status, body=b'', content_type='text/plain; charset=utf-8', head=False):
        body = body.encode('utf-8') if isinstance(body, str) else body
        try:
            self.send_response(status)
            self.send_header('Content-Type', content_type)
            self.send_header('Content-Length', str(len(body)))
            self.send_header('Cache-Control', 'no-store')
            self.send_header('Access-Control-Allow-Origin', '*')
            self.send_header('Connection', 'close')
            if status >= 400:
                self.send_header('Retry-After', '5')
            self.end_headers()
            if not head:
                self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError, TimeoutError):
            pass

    def do_HEAD(self):
        self.route(True)

    def do_GET(self):
        self.route(False)

    def route(self, head):
        path = urllib.parse.urlsplit(self.path).path
        adapter = self.server.adapter
        # Use a local literal authority; arbitrary Host headers cannot rewrite subscriptions.
        base = f'http://127.0.0.1:{self.server.server_port}'
        if adapter.stopping.is_set():
            self.send_body(503, 'JS 服务正在停止', head=head)
        elif path in ('/health', '/diag'):
            self.send_body(200, json.dumps({'ok': True, 'engine': 'JavaScriptCore', 'channels': len(adapter.channels), 'browser': False}), 'application/json', head)
        elif path in ('/', '/all.m3u', '/all.m3u8', '/m3u'):
            self.send_body(200, adapter.subscription(base), 'application/x-mpegURL; charset=utf-8', head)
        elif path == '/epg.xml':
            self.send_body(200, adapter.xmltv(), 'application/xml; charset=utf-8', head)
        elif path == '/ysp-pad.ts':
            if head:
                self.send_body(200, content_type='video/mp2t', head=True)
            else:
                self.send_body(200, base64.b64decode(adapter.call('filler')['base64']), 'video/mp2t')
        elif path.endswith('.m3u8') and path[1:-5] in adapter.by_id:
            if head:  # Probes must never burn upstream tickets or start playback.
                self.send_body(200, content_type='application/vnd.apple.mpegurl', head=True)
                return
            channel = adapter.by_id[path[1:-5]]
            try:
                result = adapter.call('resolve', ref=channel['ref'], userAgent=self.headers.get('User-Agent', ''), selfBase=base)
                if not result.get('url') or not result.get('manifestText'):
                    self.send_body(502, result.get('desc', 'JS 提取器未返回可用直播清单'))
                    return
                self.send_body(200, result['manifestText'], 'application/vnd.apple.mpegurl')
                adapter.refresh_epg(channel)
            except Exception as error:
                self.send_body(502, str(error))
        else:
            self.send_body(404, '没有此接口', head=head)


def main():
    parser = argparse.ArgumentParser(description='央视频原版 JS 提取器 · CCTVHost JavaScriptCore')
    parser.add_argument('port', nargs='?', type=int, default=18770)
    parser.add_argument('--bind', default='127.0.0.1')
    parser.add_argument('--data-dir', default='')
    args = parser.parse_args()
    adapter = JSAdapter()
    builtins._cctvhost_stop_service = adapter.stop
    try:
        adapter.server = Server((args.bind, args.port), adapter)
        print(f'[JS] 央视频 JS 已运行：{len(adapter.channels)} 个公开频道，订阅 http://127.0.0.1:{args.port}/all.m3u')
        adapter.server.serve_forever(poll_interval=.1)
    finally:
        adapter.stopping.set()
        adapter.call('stop')
        if adapter.server:
            adapter.server.server_close()


if __name__ == '__main__':
    main()
