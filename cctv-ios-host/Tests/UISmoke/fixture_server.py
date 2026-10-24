"""Loopback HTTP fixture used only by the simulator UI checks."""
import base64
import http.server
import json
import io
import threading
import time
import zipfile
import pathlib
import sys
import struct
import zlib

VIDEO = base64.b64decode(pathlib.Path(__file__).with_name("video_fixture.b64").read_text())


HLS_ZIP = zipfile.ZipFile(io.BytesIO(base64.b64decode(pathlib.Path(__file__).with_name("hls_fixture.b64").read_text())))
HLS_FILES = {name: HLS_ZIP.read(name) for name in HLS_ZIP.namelist()}

def png_chunk(kind, data):
    return struct.pack('!I', len(data)) + kind + data + struct.pack('!I', zlib.crc32(kind + data) & 0xffffffff)

LOGO = (b'\x89PNG\r\n\x1a\n' + png_chunk(b'IHDR', struct.pack('!2I5B', 1024, 1024, 8, 6, 0, 0, 0))
        + png_chunk(b'IDAT', zlib.compress((b'\0' + b'\xff\x40\x80\xff' * 1024) * 1024)) + png_chunk(b'IEND', b''))


class Handler(http.server.BaseHTTPRequestHandler):
    health_count = 0
    segment_lock = threading.Lock()
    segment_delayed = False
    image_counts = {}

    def log_message(self, *_):
        pass

    def do_POST(self):
        args = json.loads(self.rfile.read(int(self.headers.get('Content-Length', 0))) or b'{}')
        operation = self.path.rsplit('/', 1)[-1]
        base = f'http://127.0.0.1:{self.server.server_port}'
        card = lambda value: {'id': value, 'name': '测试电影 ' + value, 'poster': base + '/poster.png', 'remarks': 'HD'}
        if operation == 'capabilities':
            data = {'capabilities': ['home', 'category', 'search', 'detail', 'play']}
        elif operation == 'home':
            data = {'categories': [{'id': 'movies', 'name': '电影'}], 'items': [card('home')], 'filters': {}}
        elif operation in ('category', 'search'):
            page = int(args.get('page', 1))
            data = {'page': page, 'pagecount': 2, 'hasMore': page < 2, 'items': [card(str(args.get('keyword', 'category')) + str(page))]}
        elif operation == 'detail':
            data = {'id': args['id'], 'name': '测试影片详情', 'description': '验证多线路和不透明播放 ID', 'lines': [{'id': 'line', 'name': '主线路', 'episodes': [{'id': 'opaque?$id', 'name': '第一集'}, {'id': 'slow-episode', 'name': '慢线路待切换'}, {'id': 'fast-episode', 'name': '快速切换'}]}, {'id': 'backup', 'name': '备用', 'episodes': [{'id': 'second', 'name': '正片'}]}]}
        elif operation == 'play':
            identifier = str(args.get('id', ''))
            if identifier == 'slow-episode':
                time.sleep(3.0)
            data = {'url': base + '/video.mp4?play=' + ('slow' if identifier == 'slow-episode' else 'fast' if identifier == 'fast-episode' else 'initial'), 'headers': {}, 'parse': 0}
        else:
            self.send_error(404)
            return
        body = json.dumps({'ok': True, 'data': data}, ensure_ascii=False).encode()
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        try:
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def do_GET(self):
        print("GET", self.path, flush=True)
        status = 200
        content_type = "application/json"
        if self.path == '/image-stats':
            with type(self).segment_lock:
                data = json.dumps(type(self).image_counts).encode()
        elif self.path.endswith('.png'):
            with type(self).segment_lock:
                type(self).image_counts[self.path] = type(self).image_counts.get(self.path, 0) + 1
            if self.path == '/oversize.png':
                self.send_response(200)
                self.send_header('Content-Length', str(3 * 1024 * 1024))
                self.end_headers()
                return
            if self.path == '/slow-logo.png':
                time.sleep(1.5)
            content_type = 'image/png'
            data = LOGO
        elif self.path == "/health":
            type(self).health_count += 1
            data = json.dumps({"ok": type(self).health_count >= 3}).encode()
        elif self.path == "/all.m3u":
            content_type = "audio/x-mpegurl"
            data = (f'#EXTM3U\n#EXTINF:-1 tvg-id="cctv1",Startup Test\n'
                    f'http://127.0.0.1:{self.server.server_port}/video.mp4\n').encode()
        elif self.path.startswith("/hls/"):
            name = self.path.removeprefix("/hls/")
            if name not in HLS_FILES:
                self.send_error(404)
                return
            content_type = "application/vnd.apple.mpegurl" if name.endswith(".m3u8") else "video/mp2t"
            data = HLS_FILES[name]
            with type(self).segment_lock:
                delay = name == "seg06.ts" and not type(self).segment_delayed
                if delay:
                    type(self).segment_delayed = True
            if delay:
                print("HLS segment delay begin", flush=True)
                time.sleep(8)
                print("HLS segment delay complete", flush=True)
        elif self.path.split("?", 1)[0] == "/video.mp4":
            content_type = "video/mp4"
            data = VIDEO
            requested = self.headers.get("Range")
            if requested and requested.startswith("bytes="):
                start, _, end = requested[6:].partition("-")
                first = int(start or 0)
                last = min(int(end) if end else len(VIDEO) - 1, len(VIDEO) - 1)
                if first >= len(VIDEO):
                    self.send_error(416)
                    return
                data = VIDEO[first:last + 1]
                status = 206
            else:
                first, last = 0, len(VIDEO) - 1
        else:
            data = b'{"ok":true}'
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Accept-Ranges", "bytes")
        if status == 206:
            self.send_header("Content-Range", f"bytes {first}-{last}/{len(VIDEO)}")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        try:
            self.wfile.write(data)
        except (BrokenPipeError, ConnectionResetError):
            pass


server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
pathlib.Path(sys.argv[1]).write_text(str(server.server_port))
server.serve_forever()
