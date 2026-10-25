"""Bounded streaming relay for source-supplied playback HTTP headers.

HLS children and key/map URIs inherit the source's headers. No stream is downloaded
in full, no TS cache is created, and arbitrary client-provided target URLs are not
accepted: every target must have been registered by a playback/manifest result.
"""
import collections
import json
import re
import socket
import ssl
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid


class ScopedRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, response, code, message, headers, new_url):
        redirected = super().redirect_request(request, response, code, message, headers, new_url)
        if redirected is not None and (urllib.parse.urlsplit(request.full_url).scheme.lower(), urllib.parse.urlsplit(request.full_url).netloc.lower()) != (urllib.parse.urlsplit(new_url).scheme.lower(), urllib.parse.urlsplit(new_url).netloc.lower()):
            for name in list(redirected.headers):
                if name.lower() in ('authorization', 'cookie'):
                    redirected.remove_header(name)
        return redirected


class RelayFailure(Exception):
    def __init__(self, stage):
        super().__init__(stage)
        self.stage = stage


def safe_error_summary(error):
    text = str(error or '')
    text = re.sub(r'(?i)https?://[^\s\"\'<>]+', '[URL redacted]', text)
    text = re.sub(r'(?i)([?&][^=&#\s]*(?:access[_-]?token|refresh[_-]?token|token|auth|signature|sign|ticket|api[_-]?key|secret|password|cookie|session|credential)[^=&#\s]*=)[^&#\s]*', r'\1[redacted]', text)
    text = re.sub(r'(?i)/(?:private/var|var/mobile|Users)/[^\s,;]+', '[path redacted]', text)
    return text[:180]


class MediaRelay:
    def __init__(self, limit=256):
        self.limit = limit
        self.targets = collections.OrderedDict()
        self.lock = threading.Lock()
        self.responses = set()
        self.stopping = threading.Event()

    def register(self, url, headers, origin=None, diagnostic_id=None, fallback_url=None):
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
        origin = origin or (parsed.scheme.lower(), parsed.netloc.lower())
        key = (url, tuple(sorted(headers.items())), origin, fallback_url, diagnostic_id)
        with self.lock:
            if self.stopping.is_set():
                raise RuntimeError('媒体代理正在停止')
            for token, record in self.targets.items():
                if record[0] == key:
                    self.targets.move_to_end(token)
                    return token
            token = uuid.uuid4().hex
            self.targets[token] = (key, time.monotonic(), diagnostic_id)
            while len(self.targets) > self.limit:
                self.targets.popitem(last=False)
            return token

    @staticmethod
    def _same_origin(left, right):
        return (left.scheme.lower(), left.netloc.lower()) == (right.scheme.lower(), right.netloc.lower())

    @staticmethod
    def _with_query(url, query):
        parts = urllib.parse.urlsplit(url)
        return urllib.parse.urlunsplit((parts.scheme, parts.netloc, parts.path, query, parts.fragment))

    def rewrite(self, text, url, headers, origin, base, diagnostic_id=None):
        parent = urllib.parse.urlsplit(url)

        def local(value):
            target = urllib.parse.urljoin(url, value)
            resolved = urllib.parse.urlsplit(target)
            # Preserve signed query parameters for same-origin HLS children.
            # Cross-origin references and children with their own query keep
            # their source-authored URL unchanged to avoid credential leaks.
            fallback_url = None
            if parent.query and not resolved.query and self._same_origin(parent, resolved):
                fallback_url = target
                target = self._with_query(target, parent.query)
            if resolved.scheme.lower() not in ('http', 'https') or not resolved.hostname:
                return value
            token = self.register(target, headers, origin, diagnostic_id, fallback_url)
            return base + '/media/' + token
        lines = []
        for line in text.splitlines():
            if line.startswith('#'):
                line = re.sub(r'\bURI="([^"]+)"', lambda match: 'URI="' + local(match[1]) + '"', line)
            elif line.strip():
                line = local(line.strip())
            lines.append(line)
        return '\n'.join(lines) + '\n'

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

    def serve(self, handler, token, head=False):
        with self.lock:
            record = self.targets.get(token)
            if not record or self.stopping.is_set():
                handler.send_error(404, 'Expired media session')
                return
            key, _, diagnostic_id = record
            url, pairs, origin, fallback_url, _ = key
            self.targets.move_to_end(token)
        headers = dict(pairs)
        parsed = urllib.parse.urlsplit(url)
        if (parsed.scheme.lower(), parsed.netloc.lower()) != origin:
            headers = {k: v for k, v in headers.items() if k.lower() not in ('authorization', 'cookie')}
        headers['Accept-Encoding'] = 'identity'
        if handler.headers.get('Range'):
            headers['Range'] = handler.headers['Range']
        request = urllib.request.Request(url, headers=headers, method='HEAD' if head else 'GET')
        response = None
        sent = False
        try:
            try:
                response = urllib.request.build_opener(ScopedRedirect()).open(request, timeout=8)
            except urllib.error.HTTPError as upstream_error:
                if fallback_url and upstream_error.code in (401, 403):
                    upstream_error.close()
                    fallback_request = urllib.request.Request(fallback_url, headers=headers,
                        method='HEAD' if head else 'GET')
                    response = urllib.request.build_opener(ScopedRedirect()).open(fallback_request, timeout=8)
                else:
                    raise
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
                    raise RelayFailure('manifest_too_large')
                text = body.decode('utf-8-sig')
                if not text.lstrip().startswith('#EXTM3U'):
                    raise RelayFailure('manifest_invalid')
                if not urllib.parse.urlsplit(final_url).query:
                    original = urllib.parse.urlsplit(url)
                    final = urllib.parse.urlsplit(final_url)
                    if original.query and self._same_origin(original, final):
                        final_url = self._with_query(final_url, original.query)
                body = self.rewrite(text, final_url, dict(pairs), origin,
                                    f'http://127.0.0.1:{handler.server.server_port}', diagnostic_id).encode()
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
        except urllib.error.HTTPError as error:
            status = error.code if 400 <= error.code <= 599 else 502
            self._failed(handler, 'upstream_http_error', diagnostic_id, url, status=status,
                         error=error, upstream_status=error.code, sent=sent)
            error.close()
        except (TimeoutError, socket.timeout) as error:
            self._failed(handler, 'upstream_timeout', diagnostic_id, url, status=504, error=error, sent=sent)
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
            self._failed(handler, stage, diagnostic_id, url,
                         status=504 if stage == 'upstream_timeout' else 502, error=error, sent=sent)
        except UnicodeDecodeError as error:
            self._failed(handler, 'manifest_encoding_invalid', diagnostic_id, url, error=error, sent=sent)
        except RelayFailure as error:
            self._failed(handler, error.stage, diagnostic_id, url, error=error, sent=sent)
        except ValueError as error:
            stage = 'manifest_invalid' if '清单' in str(error) else 'media_response_invalid'
            self._failed(handler, stage, diagnostic_id, url, error=error, sent=sent)
        except (BrokenPipeError, ConnectionResetError, OSError) as error:
            self._failed(handler, 'client_or_upstream_stream_interrupted', diagnostic_id, url, error=error, sent=sent)
        except Exception as error:
            self._failed(handler, 'relay_internal_error', diagnostic_id, url, error=error, sent=sent)
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
