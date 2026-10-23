"""Bounded streaming relay for source-supplied playback HTTP headers.

HLS children and key/map URIs inherit the source's headers. No stream is downloaded
in full, no TS cache is created, and arbitrary client-provided target URLs are not
accepted: every target must have been registered by a playback/manifest result.
"""
import collections
import re
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid


class MediaRelay:
    def __init__(self, limit=256):
        self.limit = limit
        self.targets = collections.OrderedDict()
        self.lock = threading.Lock()
        self.responses = set()
        self.stopping = threading.Event()

    def register(self, url, headers, origin=None):
        parsed = urllib.parse.urlsplit(url)
        if parsed.scheme.lower() not in ('http', 'https') or not parsed.hostname:
            raise ValueError('不支持的媒体地址')
        origin = origin or parsed.hostname.lower()
        key = (url, tuple(sorted(headers.items())), origin)
        with self.lock:
            if self.stopping.is_set():
                raise RuntimeError('媒体代理正在停止')
            for token, record in self.targets.items():
                if record[0] == key:
                    self.targets.move_to_end(token)
                    return token
            token = uuid.uuid4().hex
            self.targets[token] = (key, time.monotonic())
            while len(self.targets) > self.limit:
                self.targets.popitem(last=False)
            return token

    def rewrite(self, text, url, headers, origin, base):
        def local(value):
            target = urllib.parse.urljoin(url, value)
            return base + '/media/' + self.register(target, headers, origin)
        lines = []
        for line in text.splitlines():
            if line.startswith('#'):
                line = re.sub(r'\bURI="([^"]+)"', lambda match: 'URI="' + local(match[1]) + '"', line)
            elif line.strip():
                line = local(line.strip())
            lines.append(line)
        return '\n'.join(lines) + '\n'

    def serve(self, handler, token, head=False):
        with self.lock:
            record = self.targets.get(token)
            if not record or self.stopping.is_set():
                handler.send_error(404, 'Expired media session')
                return
            (url, pairs, origin), _ = record
            self.targets.move_to_end(token)
        headers = dict(pairs)
        if urllib.parse.urlsplit(url).hostname.lower() != origin:
            headers = {k: v for k, v in headers.items() if k.lower() not in ('authorization', 'cookie')}
        headers['Accept-Encoding'] = 'identity'
        if handler.headers.get('Range'):
            headers['Range'] = handler.headers['Range']
        request = urllib.request.Request(url, headers=headers, method='HEAD' if head else 'GET')
        response = None
        sent = False
        try:
            response = urllib.request.urlopen(request, timeout=8)
            with self.lock:
                if self.stopping.is_set():
                    response.close()
                    return
                self.responses.add(response)
            mime = response.headers.get('Content-Type', 'application/octet-stream')
            final_url = response.geturl()
            is_hls = 'mpegurl' in mime.lower() or urllib.parse.urlsplit(final_url).path.lower().endswith(('.m3u8', '.m3u'))
            if is_hls and not head:
                body = response.read(2 * 1024 * 1024 + 1)
                if len(body) > 2 * 1024 * 1024:
                    raise ValueError('HLS 清单超过 2 MB')
                text = body.decode('utf-8-sig')
                if not text.lstrip().startswith('#EXTM3U'):
                    raise ValueError('来源未返回有效 HLS 清单')
                body = self.rewrite(text, final_url, dict(pairs), origin,
                                    f'http://127.0.0.1:{handler.server.server_port}').encode()
                handler.send_response(200)
                handler.send_header('Content-Type', 'application/vnd.apple.mpegurl')
                handler.send_header('Content-Length', str(len(body)))
                handler.send_header('Cache-Control', 'no-store')
                handler.send_header('Connection', 'close')
                handler.end_headers()
                sent = True
                handler.wfile.write(body)
                return
            handler.send_response(response.status)
            for key in ('Content-Type', 'Content-Length', 'Content-Range', 'Accept-Ranges'):
                if response.headers.get(key):
                    handler.send_header(key, response.headers[key])
            handler.send_header('Connection', 'close')
            handler.end_headers()
            sent = True
            if not head:
                while not self.stopping.is_set():
                    chunk = response.read(65536)
                    if not chunk:
                        break
                    handler.wfile.write(chunk)
        except (BrokenPipeError, ConnectionResetError, TimeoutError):
            if not sent:
                handler.send_error(504, 'Media upstream timeout')
        except Exception:
            if not sent:
                handler.send_error(502, 'Media upstream unavailable')
        finally:
            if response:
                with self.lock:
                    self.responses.discard(response)
                response.close()

    def close(self):
        self.stopping.set()
        with self.lock:
            responses = list(self.responses)
            self.targets.clear()
        for response in responses:
            try:
                response.close()
            except OSError:
                pass
