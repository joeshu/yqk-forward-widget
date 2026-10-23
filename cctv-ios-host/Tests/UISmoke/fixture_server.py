"""Loopback HTTP fixture used only by the simulator UI checks."""
import base64
import http.server
import json
import pathlib
import sys

VIDEO = base64.b64decode(pathlib.Path(__file__).with_name("video_fixture.b64").read_text())


class Handler(http.server.BaseHTTPRequestHandler):
    health_count = 0

    def log_message(self, *_):
        pass

    def do_GET(self):
        print("GET", self.path, flush=True)
        status = 200
        content_type = "application/json"
        if self.path == "/health":
            type(self).health_count += 1
            data = json.dumps({"ok": type(self).health_count >= 3}).encode()
        elif self.path == "/all.m3u":
            content_type = "audio/x-mpegurl"
            data = (f'#EXTM3U\n#EXTINF:-1 tvg-id="cctv1",Startup Test\n'
                    f'http://127.0.0.1:{self.server.server_port}/video.mp4\n').encode()
        elif self.path == "/video.mp4":
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
