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

# Four-second H.264 Baseline color bars with a magenta block, so a successful
# first-frame check cannot pass on a deliberately all-black movie.
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

    def log_message(self, format, *args):
        print(f"{time.monotonic():.3f} HTTP {format % args}", flush=True)

    def do_POST(self):
        args = json.loads(self.rfile.read(int(self.headers.get('Content-Length', 0))) or b'{}')
        operation = self.path.rsplit('/', 1)[-1]
        print(f"{time.monotonic():.3f} POST {operation} request_id={self.headers.get('X-CCTVHost-Request-ID', '')}", flush=True)
        base = f'http://127.0.0.1:{self.server.server_port}'
        card = lambda value: {'id': value, 'name': '测试电影 ' + value, 'poster': base + '/poster.png', 'remarks': 'HD'}
        if operation == 'capabilities':
            data = {'capabilities': ['home', 'category', 'search', 'detail', 'play', 'providers', 'configuration']}
        elif operation == 'invalidate':
            data={'invalidated':True}
        elif operation == 'configuration':
            data={'url':base+'/source-config','configurationPage':True,'headers':{'Cookie':'web_token=fixture-ui'}}
        elif operation == 'providers':
            data = [{'id': 'primary', 'name': '主平台'}, {'id': 'secondary', 'name': '备用平台'}]
        elif operation == 'home':
            data = {'categories': [{'id': 'movies', 'name': '电影'}],
                    'items': [card('home'), card('feature-2'), card('feature-3'), card('feature-4')], 'filters': {}}
        elif operation in ('category', 'search'):
            page = int(args.get('page', 1))
            data = {'page': page, 'pagecount': 2, 'hasMore': page < 2, 'items': [card(str(args.get('keyword', 'category')) + str(page))]}
        elif operation == 'detail':
            data = {'id': args['id'], 'name': '测试影片详情', 'description': '验证多线路和不透明播放 ID。通过季切换浏览不同季集数，再用底部续播入口播放当前集。', 'actor': '演员甲、演员乙', 'lines': [{'id': 'line', 'name': '主线路', 'episodes': [{'id': 'opaque?$id', 'name': '第一集'}, {'id': 'slow-episode', 'name': '慢线路待切换'}, {'id': 'fast-episode', 'name': '快速切换'}]}, {'id': 'backup', 'name': '备用', 'episodes': [{'id': 'second', 'name': '正片'}]}], 'seasons': [{'id': 's1', 'name': '第 1 季', 'episodes': [{'id': 'opaque?$id', 'name': '第一集'}, {'id': 'slow-episode', 'name': '慢线路待切换'}, {'id': 'fast-episode', 'name': '快速切换'}]}, {'id': 's2', 'name': '第 2 季', 'episodes': [{'id': 'opaque?$id', 'name': '第一集'}, {'id': 'slow-episode', 'name': '慢线路待切换'}, {'id': 'fast-episode', 'name': '快速切换'}]}]}
        elif operation == 'play':
            identifier = str(args.get('id', ''))
            if identifier == 'slow-episode':
                time.sleep(3.0)
            if identifier == 'second':
                play_url = base + '/hls/live.m3u8'
                data = {'url': play_url, 'originalURL': play_url, 'parse': 1, 'jx': 0,
                        'format': 'hls', 'contentType': 'application/vnd.apple.mpegurl',
                        'headers': {'Referer': 'https://fixture.test/watch',
                                    'X-Fixture-Playback': 'required'}}
                body = json.dumps({'ok': True, 'data': data}, ensure_ascii=False).encode()
                self.send_response(200)
                self.send_header('Content-Type', 'application/json')
                self.send_header('Content-Length', str(len(body)))
                self.end_headers()
                try:
                    self.wfile.write(body)
                except (BrokenPipeError, ConnectionResetError):
                    pass
                return
            play_url = base + '/video.mp4?play=' + ('slow' if identifier == 'slow-episode' else 'fast' if identifier == 'fast-episode' else 'initial')
            data = {'url': play_url, 'alternates': [{'name': '当前清晰度', 'url': play_url}, {'name': '流畅', 'url': base + '/video.mp4?quality=low'}], 'headers': {'Referer': 'https://fixture.test/watch', 'X-Fixture-Playback': 'required'}, 'parse': 0}
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
        if self.path == '/source-config':
            content_type='text/html; charset=utf-8'
            data=b'<html><head><title>Source configuration fixture</title></head><body>Account settings</body></html>'
        elif self.path == '/native-resolver-dynamic':
            # The media URL is deliberately absent as a literal so a regex-only
            # HTTP reader cannot pass the background WebKit execution check.
            content_type = 'text/html; charset=utf-8'
            target = f'http://127.0.0.1:{self.server.server_port}/native-resolver-video.mp4?case=dynamic'
            encoded = ','.join(str(ord(char)) for char in target)
            data = ("<!doctype html><html><head><title>Dynamic native resolver fixture</title></head>"
                    "<body><main id='episode'></main><script>setTimeout(function(){"
                    "const video=document.createElement('video');video.id='main-video';video.muted=true;"
                    f"video.src=String.fromCharCode({encoded});"
                    "document.querySelector('main').appendChild(video);},350);</script></body></html>").encode()
        elif self.path == '/native-resolver-fake.m3u8':
            content_type = 'text/html; charset=utf-8'
            data = b'<!doctype html><html><head><title>Unavailable fixture</title></head><body>No media is available.</body></html>'
        elif self.path == '/native-resolver-unavailable':
            status = 503
            content_type = 'text/plain; charset=utf-8'
            data = b'fixture unavailable'
        elif self.path == '/native-resolver-unauthorized':
            status = 401
            content_type = 'text/plain; charset=utf-8'
            data = b'fixture login required'
        elif self.path == '/native-resolver-json':
            content_type = 'application/json'
            target = f'http://localhost:{self.server.server_port}/native-resolver-header-video.mp4'
            data = json.dumps({'url': target, 'headers': {
                'Referer': 'https://provider.example/watch',
                'Authorization': 'Bearer media-token'}}).encode()
        elif self.path == '/native-resolver-slow':
            time.sleep(2.0)
            content_type = 'text/html; charset=utf-8'
            data = b'<!doctype html><html><body>Cancelled episode fixture.</body></html>'
        elif self.path == '/image-stats':
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
            if self.path.split('?', 1)[0] == '/slow-logo.png':
                time.sleep(1.5)
            content_type = 'image/png'
            data = LOGO
        elif self.path == "/health":
            type(self).health_count += 1
            data = json.dumps({"ok": type(self).health_count >= 3}).encode()
        elif self.path in ("/all.m3u", "/replacement.m3u"):
            content_type = "audio/x-mpegurl"
            data = (f'#EXTM3U\n#EXTINF:-1 tvg-id="cctv1",Startup Test\n'
                    f'http://127.0.0.1:{self.server.server_port}/video.mp4\n').encode()
        elif self.path.startswith("/hls/"):
            name = self.path.split("?", 1)[0].removeprefix("/hls/")
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
        elif self.path.split("?", 1)[0] == "/native-resolver-header-video.mp4":
            if (self.headers.get("Referer") != "https://provider.example/watch" or
                    self.headers.get("Authorization") != "Bearer media-token" or
                    self.headers.get("X-Page-Authorization") is not None):
                self.send_response(403)
                self.send_header("Content-Length", "0")
                self.end_headers()
                return
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
        elif self.path.split("?", 1)[0] in ("/video.mp4", "/native-resolver-video.mp4"):
            if self.path.startswith('/video.mp4?') and (self.headers.get("Referer") != "https://fixture.test/watch" or self.headers.get("X-Fixture-Playback") != "required"):
                self.send_response(403)
                self.send_header("Content-Length", "0")
                self.end_headers()
                return
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
