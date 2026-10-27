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


class RelayClientDisconnected(Exception):
    pass


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
    def __init__(self, limit=256, segment_limit=16384):
        self.limit = limit
        self.targets = collections.OrderedDict()
        self.segments = collections.OrderedDict()
        self.segment_index = {}
        self.segment_limit = max(1, min(int(segment_limit), 16384))
        self.lock = threading.Lock()
        self.refreshing = {}
        self.refreshFailures = {}
        self.diagnosed_manifests = set()
        self.responses = set()
        self.stopping = threading.Event()

    def register(self, url, headers, origin=None, diagnostic_id=None, fallback_url=None,
                 refresh=None, refresh_after=0, refresh_interval=0, refresh_relative=None,
                 expected_hls=False, segment=False):
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
        key = (url, tuple(sorted(headers.items())), origin, fallback_url, diagnostic_id,
               bool(expected_hls))
        refresh = refresh if callable(refresh) else None
        refresh_after = float(refresh_after or 0)
        refresh_interval = max(0.0, min(float(refresh_interval or 0), 3600.0))
        refresh_relative = str(refresh_relative)[:2048] if isinstance(refresh_relative, str) else None
        with self.lock:
            if self.stopping.is_set():
                raise RuntimeError('媒体代理正在停止')
            if segment:
                existing = self.segment_index.get(key)
                if existing in self.segments:
                    self.segments.move_to_end(existing)
                    return existing
                token = uuid.uuid4().hex
                self.segments[token] = (key, time.monotonic(), diagnostic_id, None, 0, 0, None)
                self.segment_index[key] = token
                while len(self.segments) > self.segment_limit:
                    removed, old = self.segments.popitem(last=False)
                    self.segment_index.pop(old[0], None)
                return token
            for token, record in self.targets.items():
                if record[0] == key:
                    self.targets[token] = (key, record[1], diagnostic_id,
                        refresh or record[3], refresh_after or record[4],
                        refresh_interval or record[5], refresh_relative or record[6])
                    self.targets.move_to_end(token)
                    return token
            token = uuid.uuid4().hex
            self.targets[token] = (key, time.monotonic(), diagnostic_id, refresh,
                                   refresh_after, refresh_interval, refresh_relative)
            while len(self.targets) > self.limit:
                removed, _ = self.targets.popitem(last=False)
                self.refreshFailures.pop(removed, None)
                self.diagnosed_manifests.discard(removed)
            return token

    @staticmethod
    def _same_origin(left, right):
        return (left.scheme.lower(), left.netloc.lower()) == (right.scheme.lower(), right.netloc.lower())

    @staticmethod
    def _with_query(url, query):
        parts = urllib.parse.urlsplit(url)
        return urllib.parse.urlunsplit((parts.scheme, parts.netloc, parts.path, query, parts.fragment))

    def rewrite(self, text, url, headers, origin, base, diagnostic_id=None,
                refresh=None, refresh_after=0, refresh_interval=0,
                refresh_relative_base=None):
        parent = urllib.parse.urlsplit(url)
        segment_count = 0

        def local(value):
            nonlocal segment_count
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
            is_manifest=resolved.path.lower().endswith(('.m3u8','.m3u'))
            if not is_manifest:
                segment_count += 1
                if segment_count > self.segment_limit:
                    raise RelayFailure('manifest_entries_exceeded')
            relative=value if is_manifest and not urllib.parse.urlsplit(value).scheme and not value.startswith('//') else None
            if relative and refresh_relative_base:
                relative=urllib.parse.urljoin(refresh_relative_base,relative)
            token = self.register(target, headers, origin, diagnostic_id, fallback_url,
                refresh=refresh if is_manifest else None,
                refresh_after=refresh_after if is_manifest else 0,
                refresh_interval=refresh_interval if is_manifest else 0,
                refresh_relative=relative, expected_hls=is_manifest, segment=not is_manifest)
            return base + '/media/' + token
        lines = []
        for line in text.splitlines():
            if line.startswith('#'):
                line = re.sub(r'\bURI="([^"]+)"', lambda match: 'URI="' + local(match[1]) + '"', line)
            elif line.strip():
                line = local(line.strip())
            lines.append(line)
        return '\n'.join(lines) + '\n'

    @staticmethod
    def _safe_refresh_headers(values):
        if not isinstance(values,dict):
            return {}
        output={}
        banned={'host','content-length','connection','transfer-encoding','keep-alive','upgrade'}
        for name,value in list(values.items())[:64]:
            key,text=str(name),str(value)
            if (not re.fullmatch(r"[A-Za-z0-9!#$%&'*+.^_|~-]{1,128}",key) or len(text)>8192 or
                    '\r' in text or '\n' in text or key.lower() in banned):
                continue
            output[key]=text
        return output

    def _refresh_record(self, token, force=False):
        with self.lock:
            record=self.targets.get(token) or self.segments.get(token)
            if not record or not record[3] or self.stopping.is_set():
                return record
            failure=self.refreshFailures.get(token)
            if failure and time.monotonic()<failure[1]:
                raise RelayFailure('media_refresh_backoff')
            if not force and (not record[4] or time.time()<record[4]):
                return record
            flight=self.refreshing.get(token)
            owner=flight is None
            if owner:
                flight={'event':threading.Event(),'error':None}
                self.refreshing[token]=flight
        if not owner:
            if not flight['event'].wait(15):
                raise RelayFailure('media_refresh_timeout')
            if flight['error'] is not None:
                raise flight['error']
            with self.lock:
                return self.targets.get(token)
        try:
            value=record[3]()
            if not isinstance(value,dict) or not isinstance(value.get('url'),str):
                raise RelayFailure('media_refresh_invalid')
            base_url=value['url']
            base=urllib.parse.urlsplit(base_url)
            if base.scheme.lower() not in ('http','https') or not base.hostname or base.username or base.password:
                raise RelayFailure('media_refresh_invalid')
            refreshed_url=base_url
            relative=record[6]
            if relative:
                refreshed_url=urllib.parse.urljoin(base_url,relative)
                child=urllib.parse.urlsplit(refreshed_url)
                if self._same_origin(base,child) and base.query and not child.query:
                    refreshed_url=self._with_query(refreshed_url,base.query)
            target=urllib.parse.urlsplit(refreshed_url)
            if target.scheme.lower() not in ('http','https') or not target.hostname or target.username or target.password:
                raise RelayFailure('media_refresh_invalid')
            headers=self._safe_refresh_headers(value.get('headers',{}))
            origin=(base.scheme.lower(),base.netloc.lower())
            key=(refreshed_url,tuple(sorted(headers.items())),origin,None,record[2],
                 record[0][5] if len(record[0]) > 5 else False)
            interval=max(0.0,min(float(value.get('refreshInterval') or record[5] or 0),3600.0))
            next_refresh=float(value.get('refreshAfter') or (time.time()+interval if interval else 0))
            updated=(key,record[1],record[2],record[3],next_refresh,interval,relative)
            with self.lock:
                if token in self.targets and not self.stopping.is_set():
                    self.targets[token]=updated
                    self.targets.move_to_end(token)
                    self.refreshFailures.pop(token,None)
                    return updated
                return None
        except RelayFailure as error:
            flight['error']=RelayFailure(error.stage)
            with self.lock:
                if token in self.targets and not self.stopping.is_set():
                    attempts=self.refreshFailures.get(token,(0,0))[0]+1
                    self.refreshFailures[token]=(attempts,time.monotonic()+min(60.0,2.0**min(attempts,6)))
            raise
        except Exception as error:
            failure=RelayFailure('media_refresh_failed')
            flight['error']=failure
            with self.lock:
                if token in self.targets and not self.stopping.is_set():
                    attempts=self.refreshFailures.get(token,(0,0))[0]+1
                    self.refreshFailures[token]=(attempts,time.monotonic()+min(60.0,2.0**min(attempts,6)))
            raise failure from error
        finally:
            with self.lock:
                event=self.refreshing.pop(token,None)
                if event:
                    event['event'].set()

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

    @staticmethod
    def _write_client(handler, data):
        try:
            handler.wfile.write(data)
        except (BrokenPipeError, ConnectionResetError) as error:
            raise RelayClientDisconnected(type(error).__name__) from error

    def serve(self, handler, token, head=False):
        with self.lock:
            pool = self.targets if token in self.targets else self.segments
            record = pool.get(token)
            if not record or self.stopping.is_set():
                handler.send_error(404, 'Expired media session')
                return
            pool.move_to_end(token)
        key=record[0];url=key[0];diagnostic_id=record[2]
        response = None
        sent = False
        try:
            refreshed=self._refresh_record(token)
            if refreshed is None:
                if self.stopping.is_set():
                    return
                raise RelayFailure('media_session_expired')
            record=refreshed
            key, _, diagnostic_id = record[:3]
            url, pairs, origin, fallback_url, _ = key[:5]
            expected_hls = bool(key[5]) if len(key) > 5 else False
            headers = dict(pairs)
            parsed = urllib.parse.urlsplit(url)
            with self.lock:
                first_manifest = not head and (expected_hls or parsed.path.lower().endswith(('.m3u8', '.m3u'))) and token not in self.diagnosed_manifests
                if first_manifest:
                    self.diagnosed_manifests.add(token)
            if first_manifest:
                print('[CCTVHostMediaRelay] ' + json.dumps({'event': 'media_relay_manifest_requested',
                    'request_id': diagnostic_id, 'upstream_host': parsed.hostname or '',
                    'scheme': parsed.scheme.lower()}, separators=(',', ':')))
            if (parsed.scheme.lower(), parsed.netloc.lower()) != origin:
                headers = {k: v for k, v in headers.items() if k.lower() not in ('authorization', 'cookie')}
            headers['Accept-Encoding'] = 'identity'
            manifest_request = expected_hls or parsed.path.lower().endswith(('.m3u8', '.m3u'))
            if manifest_request:
                # Rewritten playlists have different byte offsets. Fetch the
                # full source manifest; range requests still apply to media.
                headers = {k: v for k, v in headers.items() if k.lower() != 'range'}
            elif handler.headers.get('Range'):
                headers['Range'] = handler.headers['Range']
            request = urllib.request.Request(url, headers=headers, method='HEAD' if head else 'GET')
            try:
                response = urllib.request.build_opener(ScopedRedirect()).open(request, timeout=8)
            except urllib.error.HTTPError as upstream_error:
                if fallback_url and upstream_error.code in (401, 403):
                    upstream_error.close()
                    fallback_request = urllib.request.Request(fallback_url, headers=headers,
                        method='HEAD' if head else 'GET')
                    response = urllib.request.build_opener(ScopedRedirect()).open(fallback_request, timeout=8)
                elif upstream_error.code in (401,403) and record[3]:
                    upstream_error.close()
                    record=self._refresh_record(token,force=True)
                    if not record:raise RelayFailure('media_refresh_invalid')
                    key, _, diagnostic_id = record[:3]
                    url, pairs, origin, fallback_url, _ = key[:5]
                    expected_hls = bool(key[5]) if len(key) > 5 else False
                    headers=dict(pairs)
                    parsed=urllib.parse.urlsplit(url)
                    if (parsed.scheme.lower(),parsed.netloc.lower())!=origin:
                        headers={k:v for k,v in headers.items() if k.lower() not in ('authorization','cookie')}
                    headers['Accept-Encoding']='identity'
                    manifest_request = expected_hls or parsed.path.lower().endswith(('.m3u8', '.m3u'))
                    if manifest_request:headers={k:v for k,v in headers.items() if k.lower()!='range'}
                    elif handler.headers.get('Range'):headers['Range']=handler.headers['Range']
                    refreshed_request=urllib.request.Request(url,headers=headers,method='HEAD' if head else 'GET')
                    response=urllib.request.build_opener(ScopedRedirect()).open(refreshed_request,timeout=8)
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
            prefix = b''
            # Some providers serve HLS from extensionless/PHP endpoints or
            # return a generic MIME type. Honor declared HLS and sniff those
            # responses before returning opaque bytes to AVPlayer.
            mime_type = mime.split(';', 1)[0].strip().lower()
            generic_mime = mime_type in ('', 'application/octet-stream', 'binary/octet-stream', 'text/plain')
            extensionless = not urllib.parse.urlsplit(final_url).path.rsplit('/', 1)[-1].count('.')
            if not head and not is_hls and (expected_hls or generic_mime or extensionless):
                prefix = response.read(64)
                is_hls = prefix.lstrip(b'\xef\xbb\xbf \t\r\n').startswith(b'#EXTM3U')
            if is_hls and not head:
                body = prefix + response.read(2 * 1024 * 1024 + 1 - len(prefix))
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
                if first_manifest:
                    print('[CCTVHostMediaRelay] ' + json.dumps({'event': 'media_relay_manifest_readable',
                        'request_id': diagnostic_id, 'upstream_host': urllib.parse.urlsplit(final_url).hostname or '',
                        'upstream_status': response.status, 'manifest_bytes': len(body)}, separators=(',', ':')))
                body = self.rewrite(text, final_url, dict(pairs), origin,
                                    f'http://127.0.0.1:{handler.server.server_port}', diagnostic_id,
                                    refresh=record[3],refresh_after=record[4],
                                    refresh_interval=record[5],
                                    refresh_relative_base=record[6]).encode()
                handler.send_response(200)
                handler.send_header('Content-Type', 'application/vnd.apple.mpegurl')
                handler.send_header('Content-Length', str(len(body)))
                handler.send_header('Cache-Control', 'no-store')
                handler.send_header('Connection', 'close')
                handler.end_headers()
                sent = True
                self._write_client(handler, body)
                return
            handler.send_response(response.status)
            for key in ('Content-Type', 'Content-Length', 'Content-Range', 'Accept-Ranges'):
                if response.headers.get(key):
                    handler.send_header(key, response.headers[key])
            handler.send_header('Connection', 'close')
            handler.end_headers()
            sent = True
            if not head:
                if prefix:
                    self._write_client(handler, prefix)
                while not self.stopping.is_set():
                    chunk = response.read(65536)
                    if not chunk:
                        break
                    self._write_client(handler, chunk)
        except RelayClientDisconnected as error:
            # Disconnection does not prove playback success or upstream failure.
            print('[CCTVHostMediaRelay] ' + json.dumps({
                'event': 'media_relay_client_disconnected',
                'request_id': diagnostic_id or uuid.uuid4().hex,
                'stage': 'client_write', 'error_type': str(error),
            }, separators=(',', ':')))
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
            flights = list(self.refreshing.values())
            self.refreshing.clear()
            self.targets.clear()
            self.segments.clear()
            self.segment_index.clear()
            self.diagnosed_manifests.clear()
            self.refreshFailures.clear()
        for event in flights:
            event['event'].set()
        for response in responses:
            try:
                response.close()
            except OSError:
                pass
