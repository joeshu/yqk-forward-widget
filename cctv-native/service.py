"""CCTV-2 webpage-source local HLS. Node hosts the unchanged official runtime."""
from __future__ import annotations
import argparse
import base64
from collections import OrderedDict
from dataclasses import replace
from concurrent.futures import ThreadPoolExecutor
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from http.client import IncompleteRead
import json
import math
import os
from pathlib import Path
import queue
import random
import re
import shutil
import signal
import ssl
import subprocess
import sys
import threading
import time
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode, urljoin, urlsplit
from urllib.request import Request, HTTPRedirectHandler, HTTPSHandler, build_opener
import uuid
from cctv_native_ts import inspect_ts, transform_pes_nals, boundary_proven_by, TSFormatError

RUNTIME_URL = 'https://js.player.cntv.cn/creator/live.worker.js'
RUNTIME_SHA = 'ad9fd2d188015074e59632cedecf13eda29f2c76ea92f17b5f00bc799451bc13'
PACKAGES = ['fake-indexeddb@6.2.6', 'xhr2@0.2.1', 'http-proxy-agent@9.1.0', 'https-proxy-agent@9.1.0']
UA = 'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 Chrome/130.0.0.0 Mobile Safari/537.36'
REFERER = 'https://tv.cctv.com/live/cctv2/m/index.shtml'
CDNS = ('.cntv.cn', '.cctv.com', '.cdn20.com', '.kcdnvip.com', '.bdydns.com',
        '.myalicdn.com', '.myqcloud.com', '.myhwcdn.cn', '.volcfcdn.com')
# Replaced by the single-file build; source checkout uses the adjacent engine.
ENGINE_SOURCE = None


class NativeError(Exception):
    pass


def transport_error_code(error):
    """Describe network failures without URLs, paths, certificate text or tokens."""
    if isinstance(error, HTTPError):
        return f'http-{error.code}'
    code = type(error).__name__
    reason = error.reason if isinstance(error, URLError) else error
    if isinstance(error, URLError) and isinstance(reason, BaseException):
        code += ':'+type(reason).__name__
    if isinstance(reason, OSError) and isinstance(reason.errno, int):
        code += ':errno-'+str(reason.errno)
    if isinstance(reason, ssl.SSLCertVerificationError) and isinstance(getattr(reason, 'verify_code', None), int):
        code += ':verify-'+str(reason.verify_code)
    if isinstance(reason, ssl.SSLError):
        for attribute in ('library', 'reason'):
            value = getattr(reason, attribute, None)
            if isinstance(value, str) and re.fullmatch(r'[A-Z0-9_]{1,100}', value):
                code += ':'+attribute+'-'+value
    return code


def validate_source(url):
    parsed = urlsplit(url)
    if (parsed.scheme != 'https' or not parsed.hostname or parsed.username or parsed.password
            or parsed.port not in (None, 443)
            or not any(parsed.hostname == suffix[1:] or parsed.hostname.endswith(suffix) for suffix in CDNS)):
        raise NativeError('unsupported-source-host')


class SourceRedirect(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        validate_source(newurl)
        return super().redirect_request(req, fp, code, msg, headers, newurl)


_API_TLS12_PREFERRED = False
_API_LEGACY_PREFERRED = False
_API_LEGACY_ENABLED = True


def _legacy_source_error(error):
    reason = getattr(error, 'reason', None)
    return (isinstance(reason, ssl.SSLError)
            and not isinstance(reason, ssl.SSLCertVerificationError)
            and getattr(reason, 'reason', None) == 'UNSAFE_LEGACY_RENEGOTIATION_DISABLED')


class LegacyAPIRedirect(SourceRedirect):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        parsed = urlsplit(newurl)
        if parsed.hostname != 'vdnx.live.cntv.cn' or parsed.path != '/api/v3/vdn/live':
            raise NativeError('source-api-legacy-redirect-denied')
        return super().redirect_request(req, fp, code, msg, headers, newurl)


def get(url, *, headers=None, limit=8*1024*1024, timeout=12):
    global _API_TLS12_PREFERRED, _API_LEGACY_PREFERRED
    validate_source(url)
    req = Request(url, headers={'User-Agent': UA, 'Referer': REFERER, **(headers or {})})
    parsed = urlsplit(url)
    source_api = parsed.hostname == 'vdnx.live.cntv.cn' and parsed.path == '/api/v3/vdn/live'

    def read_response(tls12=False, legacy=False):
        handlers = [LegacyAPIRedirect() if legacy else SourceRedirect()]
        if tls12:
            context = ssl.create_default_context()
            context.minimum_version = ssl.TLSVersion.TLSv1_2
            context.maximum_version = ssl.TLSVersion.TLSv1_2
            if legacy:
                connect = getattr(ssl,'OP_LEGACY_SERVER_CONNECT',0)
                no_renegotiation = getattr(ssl,'OP_NO_RENEGOTIATION',0)
                if not connect or not no_renegotiation:
                    raise NativeError('source-api-legacy-tls-unavailable')
                # Only a confirmed unpatched-server initial handshake receives
                # this compatibility option. Keep CA/hostname verification and
                # refuse later renegotiation; never apply to media/SDK hosts.
                context.options |= connect | no_renegotiation
            handlers.append(HTTPSHandler(context=context))
        with build_opener(*handlers).open(req, timeout=timeout) as response:
            body = response.read(limit + 1)
            if len(body) > limit:
                raise NativeError('response-too-large')
            validate_source(response.url)
            if legacy:
                target = urlsplit(response.url)
                if target.hostname != parsed.hostname or target.path != parsed.path:
                    raise NativeError('source-api-legacy-redirect-denied')
            return body, response.url

    preferred_legacy = source_api and _API_LEGACY_ENABLED and _API_LEGACY_PREFERRED
    preferred = source_api and (_API_TLS12_PREFERRED or preferred_legacy)
    try:
        return read_response(preferred,preferred_legacy)
    except URLError as error:
        reason = error.reason
        if (not source_api or not isinstance(reason, ssl.SSLError)
                or isinstance(reason, ssl.SSLCertVerificationError)):
            raise
        mode = not preferred
        print('[cctv-native] source-api TLS failure='+transport_error_code(error)+
              '; retrying verified '+('TLSv1.2' if mode else 'default TLS'), flush=True)
        try:
            result = read_response(mode)
        except URLError as second:
            if (preferred_legacy or not _API_LEGACY_ENABLED or not _legacy_source_error(second)
                    or not getattr(ssl,'OP_LEGACY_SERVER_CONNECT',0)
                    or not getattr(ssl,'OP_NO_RENEGOTIATION',0)):
                raise
            # A protocol-version change did not resolve the confirmed legacy
            # handshake failure. Never enable this for generic/certificate errors.
            print('[cctv-native] source-api confirmed legacy handshake; '
                  'trying verified TLSv1.2 legacy-server-connect, renegotiation disabled',flush=True)
            result = read_response(True,True)
            _API_TLS12_PREFERRED, _API_LEGACY_PREFERRED = True, True
            return result
        # Learn only after a verified request succeeds.
        _API_TLS12_PREFERRED, _API_LEGACY_PREFERRED = mode, False
        return result


WEBSITE_CHANNELS = (
    ('cctv1', 'CCTV-1 综合'), ('cctv2', 'CCTV-2 财经'),
    ('cctv3', 'CCTV-3 综艺'), ('cctv4', 'CCTV-4 中文国际'),
    ('cctv5', 'CCTV-5 体育'), ('cctv5plus', 'CCTV-5+ 体育赛事'),
    ('cctv6', 'CCTV-6 电影'), ('cctv7', 'CCTV-7 国防军事'),
    ('cctv8', 'CCTV-8 电视剧'), ('cctvjilu', 'CCTV-9 纪录'),
    ('cctv10', 'CCTV-10 科教'), ('cctv11', 'CCTV-11 戏曲'),
    ('cctv12', 'CCTV-12 社会与法'), ('cctv13', 'CCTV-13 新闻'),
    ('cctvchild', 'CCTV-14 少儿'), ('cctv15', 'CCTV-15 音乐'),
    ('cctv16', 'CCTV-16 奥林匹克'), ('cctv17', 'CCTV-17 农业农村'),
    ('cctveurope', 'CCTV-4 欧洲'), ('cctvamerica', 'CCTV-4 美洲'),
    ('cctv9', 'CCTV-NEWS 英语新闻'), ('cctvdoc', 'CCTV-9 纪录（英）'),
    ('cctvxiyu', 'CCTV-Español'), ('cctvfrench', 'CCTV-Français'),
    ('cctvarabic', 'CCTV-العربية'), ('cctvrussian', 'CCTV-Русский'),
)


def source_url(channel_id='cctv2'):
    if channel_id not in dict(WEBSITE_CHANNELS):
        raise NativeError('unknown-channel')
    stamp, nonce = int(time.time()*1000), random.randint(100, 1000)
    signature = hashlib.md5(f'{channel_id}{stamp}{nonce}4f779c20f6974ccba20e28d63529d0ef'.encode()).hexdigest()
    query = urlencode({'channel': channel_id, 'vn': '1000', 'pdrm': '1', 'uid': '', 'hbss': stamp})
    raw, _ = get('https://vdnx.live.cntv.cn/api/v3/vdn/live?' + query,
                 headers={'auth-key': f'{stamp}-{nonce}-{signature}'}, limit=1024*1024)
    data = json.loads(raw)
    if str(data.get('play')) != '1':
        raise NativeError('official-playback-not-permitted')
    url = data.get('manifest', {}).get('hls_cdrm')
    if not isinstance(url, str) or not url.startswith('https://'):
        raise NativeError('official-stream-unavailable')
    return url


def parse_playlist(text, base):
    if not text.lstrip('\ufeff').startswith('#EXTM3U'):
        raise NativeError('invalid-playlist')
    lines = [line.strip() for line in text.splitlines() if line.strip()]
    sequence, duration, discontinuity, variants, entries, bandwidth = 0, None, False, [], [], None
    for line in lines:
        if line.startswith('#EXT-X-MEDIA-SEQUENCE:'):
            sequence = int(line.split(':', 1)[1])
        elif line.startswith('#EXT-X-STREAM-INF:'):
            match = re.search(r'BANDWIDTH=(\d+)', line)
            bandwidth = int(match[1]) if match else 0
        elif line.startswith('#EXT-X-KEY:') and 'METHOD=NONE' not in line:
            raise NativeError('unsupported-extra-encryption')
        elif line.startswith('#EXT-X-MAP:'):
            raise NativeError('unsupported-media-container')
        elif line == '#EXT-X-DISCONTINUITY':
            discontinuity = True
        elif line.startswith('#EXTINF:'):
            duration = float(line.split(':', 1)[1].split(',', 1)[0])
            if not math.isfinite(duration) or not 0 < duration <= 30:
                raise NativeError('invalid-segment-duration')
        elif not line.startswith('#'):
            if bandwidth is not None:
                variants.append((bandwidth, urljoin(base, line)))
                bandwidth = None
            elif duration is not None:
                entries.append({'seq': sequence, 'duration': duration, 'url': urljoin(base, line),
                                'discontinuity': discontinuity})
                sequence += 1
                duration, discontinuity = None, False
    if variants:
        return {'variant': max(variants)[1]}
    if not entries or len(entries) > 64:
        raise NativeError('empty-or-oversized-playlist')
    return {'entries': entries}


def media_playlist(url):
    for _ in range(4):
        raw, final = get(url, limit=1024*1024)
        parsed = parse_playlist(raw.decode('utf-8-sig'), final)
        if 'entries' in parsed:
            return parsed['entries'], final
        url = parsed['variant']
    raise NativeError('playlist-nesting-exceeded')


def cache_paths(args):
    root = Path(args.cache_dir).expanduser().resolve()
    return root, root / 'node' / 'node_modules', root / ('runtime-' + RUNTIME_SHA[:12] + '.js')


def setup(args):
    root, modules, runtime = cache_paths(args)
    root.mkdir(parents=True, exist_ok=True, mode=0o700)
    npm = shutil.which('npm.cmd' if os.name == 'nt' else 'npm')
    if not npm:
        raise NativeError('npm-not-found')
    subprocess.run([npm, 'install', '--prefix', str(modules.parent), '--ignore-scripts', '--no-audit',
                    '--no-fund', '--save-exact', *PACKAGES], check=True)
    raw, _ = get(RUNTIME_URL, limit=4*1024*1024)
    if hashlib.sha256(raw).hexdigest() != RUNTIME_SHA:
        raise NativeError('official-runtime-version-changed')
    temporary = runtime.with_suffix('.tmp')
    temporary.write_bytes(raw)
    os.chmod(temporary, 0o600)
    temporary.replace(runtime)
    print('运行时已安装到独立缓存目录。未安装Chromium或FFmpeg。')


class Engine:
    def __init__(self, args):
        root, modules, runtime = cache_paths(args)
        if not runtime.is_file() or hashlib.sha256(runtime.read_bytes()).hexdigest() != RUNTIME_SHA:
            raise NativeError('runtime-missing-or-changed-run-setup')
        if not (modules / 'fake-indexeddb').is_dir():
            raise NativeError('dependencies-missing-run-setup')
        engine_path = Path(__file__).with_name('engine.cjs')
        if ENGINE_SOURCE is not None:
            engine_path = root / 'engine.cjs'
            temp = root / ('engine-' + uuid.uuid4().hex + '.tmp')
            temp.write_text(ENGINE_SOURCE, encoding='utf-8')
            temp.replace(engine_path)
        env = os.environ.copy()
        ca = ssl.get_default_verify_paths().cafile
        if ca and Path(ca).is_file():
            env.setdefault('NODE_EXTRA_CA_CERTS', ca)
        self.process = subprocess.Popen([args.node, str(engine_path), '--runtime', str(runtime),
                                         '--modules', str(modules)], stdin=subprocess.PIPE,
                                        stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, env=env)
        self.messages = queue.Queue(maxsize=4)
        self.counter = 0
        self.closed = False
        self.close_lock = threading.Lock()
        def read():
            try:
                while True:
                    line = self.process.stdout.readline(32*1024*1024 + 1)
                    if not line or len(line) > 32*1024*1024:
                        break
                    self.messages.put(json.loads(line), timeout=2)
            except Exception:
                pass
            finally:
                try:
                    self.messages.put_nowait({'error': 'engine-closed'})
                except queue.Full:
                    pass
        self.reader = threading.Thread(target=read, daemon=True)
        self.reader.start()
        try:
            if self.receive(25).get('ready') is not True:
                raise NativeError('engine-initialization-failed')
        except Exception:
            self.close()
            raise

    def receive(self, timeout):
        try:
            result = self.messages.get(timeout=timeout)
        except queue.Empty:
            raise NativeError('engine-timeout') from None
        if result.get('error'):
            raise NativeError(str(result['error']))
        return result

    def transform(self, units):
        self.counter += 1
        line = json.dumps({'id': self.counter, 'nals': [base64.b64encode(x).decode() for x in units]})
        if len(line) > 24*1024*1024:
            raise NativeError('engine-message-too-large')
        expired = threading.Event()
        def abort():
            expired.set()
            try:
                self.process.kill()
            except OSError:
                pass
        watchdog = threading.Timer(20, abort)
        watchdog.daemon = True
        watchdog.start()
        try:
            self.process.stdin.write(line.encode() + b'\n')
            self.process.stdin.flush()
            result = self.receive(20)
        except (OSError, ValueError, NativeError) as error:
            if expired.is_set():
                raise NativeError('engine-timeout') from None
            if isinstance(error, NativeError):
                raise
            # Engine pipe failures are not upstream transport failures and
            # must never enter the CDN retry loop.
            raise NativeError('engine-io-failed') from None
        finally:
            watchdog.cancel()
        if result.get('id') != self.counter or result.get('ok') is not True:
            raise NativeError('engine-response-invalid')
        output = [base64.b64decode(x, validate=True) for x in result['nals']]
        if len(output) != len(units):
            raise NativeError('engine-response-count')
        return output

    def close(self):
        with self.close_lock:
            if self.closed:
                return
            self.closed = True
            if self.process.poll() is None:
                self.process.terminate()
                try:
                    self.process.wait(3)
                except subprocess.TimeoutExpired:
                    self.process.kill()
                    self.process.wait()
            self.reader.join(2)
            self.process.stdin.close()
            self.process.stdout.close()


class Channel:
    def __init__(self, args):
        self.args = args
        self.channel_id = getattr(args, 'channel_id', 'cctv2')
        self.condition = threading.Condition(threading.RLock())
        self.stop = threading.Event()
        self.thread = None
        self.engine = None
        self.state, self.error, self.generation = 'idle', '', ''
        self.ring = OrderedDict()
        self.size = self.counter = self.requests = self.processed = 0
        self.discarded_discontinuities = 0
        self.source_gaps = 0
        self.transport_retries = 0
        self.last_transport_error = ''
        self.last_request = 0
        self.failed_at = 0
        self.waiters = 0
        self.timings = {}
        self.started_at = 0
        self.operation = 'idle'
        self.operation_started = 0
        self.seen_operations = set()
        self.playlist_entries = 0
        self.last_segment_bytes = 0
        self.preparation_phase = 'disabled'

    def operation_phase(self, value):
        with self.condition:
            self.operation = value
            self.operation_started = time.monotonic()
            if value not in self.seen_operations:
                self.seen_operations.add(value)
                print('[cctv-native] phase='+value+' channel='+self.channel_id, flush=True)

    def note_client_request(self, kind):
        with self.condition:
            if not self.started_at or kind in self.timings:
                return
            elapsed = round(time.monotonic()-self.started_at,3)
            self.timings[kind] = elapsed
            print('[cctv-native] '+kind+' seconds='+str(elapsed)+' channel='+self.channel_id,flush=True)

    def stage(self, stage):
        with self.condition:
            self.state = stage
            self.timings.setdefault(stage, round(time.monotonic() - self.started_at, 3))
            self.condition.notify_all()

    def demand(self, start=True):
        with self.condition:
            self.last_request = time.monotonic()
            if not start or self.stop.is_set() or self.thread and self.thread.is_alive():
                return
            if self.state == 'error' and time.monotonic()-self.failed_at < 30:
                return
            self.generation = uuid.uuid4().hex
            self.ring.clear()
            self.size = self.counter = self.processed = self.requests = 0
            self.discarded_discontinuities = 0
            self.source_gaps = 0
            self.transport_retries = 0
            self.last_transport_error = ''
            self.operation, self.operation_started = 'initializing', 0
            self.seen_operations.clear()
            self.preparation_phase = 'disabled'
            self.playlist_entries = self.last_segment_bytes = 0
            self.error, self.state, self.timings = '', 'initializing', {}
            self.started_at = time.monotonic()
            self.thread = threading.Thread(target=self.run, daemon=True, name='cctv-native')
            self.thread.start()

    def publish(self, body, entry, discontinuity):
        with self.condition:
            index = self.counter
            self.counter += 1
            self.processed += 1
            self.last_transport_error = ''
            self.ring[index] = (body, entry['duration'], discontinuity)
            self.size += len(body)
            while len(self.ring) > 10 or self.size > self.args.buffer_mb*1024*1024:
                _, old = self.ring.popitem(last=False)
                self.size -= len(old[0])
                self.discarded_discontinuities += bool(old[2])
            if len(self.ring) >= 2:
                first_ready = self.state != 'ready'
                self.stage('ready')
                if first_ready:
                    print('[cctv-native] media-ready startup_seconds='+str(self.timings['ready'])+' channel='+self.channel_id, flush=True)
            self.condition.notify_all()

    def playlist(self):
        with self.condition:
            if len(self.ring) < 2 or self.state != 'ready':
                return None
            entries = list(self.ring.items())[-6:]
            target = max(math.ceil(value[1]) for _, value in entries)
            discontinuities = self.discarded_discontinuities + sum(
                bool(value[2]) for index, value in self.ring.items() if index < entries[0][0])
            lines = ['#EXTM3U', '#EXT-X-VERSION:3', f'#EXT-X-TARGETDURATION:{target}',
                     f'#EXT-X-MEDIA-SEQUENCE:{entries[0][0]}',
                     f'#EXT-X-DISCONTINUITY-SEQUENCE:{discontinuities}']
            for index, (_, duration, discontinuity) in entries:
                if discontinuity:
                    lines.append('#EXT-X-DISCONTINUITY')
                lines.extend([f'#EXTINF:{duration:.6f},', f'media/{self.generation}/{index}.ts'])
            return '\n'.join(lines)+'\n'

    def snapshot(self):
        with self.condition:
            return {'state': self.state, 'error': self.error, 'source': 'tv.cctv.com/'+self.channel_id,
                    'mode': 'official-runtime-original-ts', 'processed_segments': self.processed,
                    'buffer_bytes': self.size, 'buffer_segments': len(self.ring),
                    'source_gaps': self.source_gaps,
                    'transport_retries': self.transport_retries,
                    'last_transport_error': self.last_transport_error,
                    'operation': self.operation,
                    'parallel_preparation': bool(getattr(self.args,'parallel_prepare',False)),
                    'preparation_phase': self.preparation_phase,
                    'operation_seconds': round(time.monotonic()-self.operation_started, 3) if self.operation_started else 0,
                    'playlist_entries': self.playlist_entries, 'last_segment_bytes': self.last_segment_bytes,
                    'media_transfer': ('typed-array' if getattr(getattr(self.engine, 'context', None), 'buffer_api', False) else 'base64'),
                    'stage_seconds': dict(self.timings), 'media_ready': self.playlist() is not None}

    def _prepare_initial(self, pool, cancel):
        """Independent HTTPS work; never touches the thread-owned native VM."""
        def cancelled():
            return self.stop.is_set() or cancel.is_set()
        if cancelled():
            return None
        self.preparation_phase = 'source-api'
        url = source_url() if self.channel_id == 'cctv2' else source_url(self.channel_id)
        refreshed = time.monotonic()
        if cancelled():
            return None
        self.preparation_phase = 'media-playlist'
        entries, final = media_playlist(url)
        if cancelled():
            return None
        self.preparation_phase = 'segment-download'
        downloads = {}
        for entry in entries[:3]:
            if cancelled():
                return None
            downloads[entry['seq']] = pool.submit(get,entry['url'])
        return entries, final, downloads, refreshed, time.monotonic()

    def run(self):
        # The native engine is created and released on this owner thread;
        # bounded I/O workers can fetch independently while it initializes.
        with ThreadPoolExecutor(max_workers=3) as pool:
            self._run_owned(pool)

    def _run_owned(self, pool):
        engine = None
        preparation = None
        cancel_preparation = threading.Event()
        try:
            if getattr(self.args,'parallel_prepare',False):
                print('[cctv-native] source-preparation=parallel channel='+self.channel_id,flush=True)
                self.preparation_phase = 'source-api'
                preparation = pool.submit(self._prepare_initial,pool,cancel_preparation)
            self.operation_phase('engine-initialization')
            engine = Engine(self.args)
            with self.condition:
                self.engine = engine
            if self.stop.is_set():
                return
            self.stage('source')
            url, refreshed, failures = None, 0, 0
            current_source, last_seq, last_progress = None, None, time.monotonic()
            pending_discontinuity = False
            cached = {}
            while not self.stop.is_set():
                if not self.waiters and time.monotonic()-self.last_request > self.args.idle_timeout:
                    self.state = 'idle'
                    break
                if time.monotonic()-last_progress > 30:
                    raise NativeError('source-media-stalled')
                try:
                    initial_downloads = {}
                    if preparation is not None:
                        pending, preparation = preparation, None
                        self.operation_phase(self.preparation_phase if self.preparation_phase != 'disabled' else 'source-api')
                        try:
                            prepared = pending.result()
                        except Exception:
                            self.operation_phase(self.preparation_phase)
                            raise
                        if prepared is None or self.stop.is_set():
                            break
                        entries, final, initial_downloads, refreshed, prepared_at = prepared
                        pending = prepared = None
                        url = final
                        if time.monotonic()-prepared_at > 8:
                            # A slow SDK initialization must not start playback
                            # from an obsolete live window just to reuse work.
                            for task in initial_downloads.values():
                                task.cancel()
                            initial_downloads = {}
                            self.operation_phase('media-playlist')
                            entries, final = media_playlist(url)
                    else:
                        if url is None or time.monotonic()-refreshed > 120:
                            self.operation_phase('source-api')
                            url, refreshed = (source_url() if self.channel_id == 'cctv2' else source_url(self.channel_id)), time.monotonic()
                            if self.stop.is_set():
                                break
                        self.operation_phase('media-playlist')
                        entries, final = media_playlist(url)
                    if self.stop.is_set():
                        break
                    self.playlist_entries = len(entries)
                    # Resolve the master only once per source refresh.
                    url = final
                    self.requests += 1
                    source = (urlsplit(final).hostname, urlsplit(final).path)
                    changed = current_source is not None and source != current_source
                    pending_discontinuity = pending_discontinuity or changed
                    if source != current_source:
                        last_seq, cached = None, {}
                        current_source = source
                    if last_seq is not None and entries[0]['seq'] > last_seq+1:
                        # A live window can move past a slow download. Drop
                        # that gap, then prove boundaries within the new
                        # window; never join bytes across missing segments.
                        self.source_gaps += 1
                        last_seq, cached, pending_discontinuity = None, {}, True
                    cached.update(initial_downloads)
                    initial_downloads = {}
                    wanted = [e for e in entries if last_seq is None or e['seq'] > last_seq][:3]
                    for e in wanted:
                        if e['seq'] not in cached:
                            cached[e['seq']] = pool.submit(get, e['url'])
                    for e, following in zip(wanted, wanted[1:]):
                        if self.stop.is_set():
                            break
                        if following['seq'] != e['seq']+1 or following['discontinuity']:
                            raise NativeError('source-boundary-not-proven')
                        self.operation_phase('segment-download')
                        raw = cached[e['seq']].result()[0]
                        lookahead = cached[following['seq']].result()[0]
                        if self.stop.is_set():
                            break
                        self.last_segment_bytes = len(raw)
                        self.operation_phase('ts-analysis')
                        analysis = inspect_ts(raw)
                        if not boundary_proven_by(lookahead, program_number=analysis.program_number,
                                                  video_pid=analysis.video_pid):
                            raise NativeError('source-boundary-not-proven')
                        # The lookahead proved the final boundary above. Only
                        # its completeness bit changes; reuse the parsed TS.
                        analysis = replace(analysis, nals=analysis.nals[:-1]+(
                            replace(analysis.nals[-1], complete=True),))
                        if self.stop.is_set():
                            break
                        self.operation_phase('sdk-transform')
                        processed = engine.transform([analysis.nal_bytes(n) for n in analysis.nals])
                        if self.stop.is_set():
                            break
                        converted = {n.payload_offset: value for n, value in zip(analysis.nals, processed)}
                        self.operation_phase('ts-repack')
                        output, _ = transform_pes_nals(raw, lambda n, _data: converted[n.payload_offset],
                                                   nal_types=(1, 5, 7), final_nal_complete=True, _prepared=analysis)
                        if self.stop.is_set():
                            break
                        self.publish(output, e, pending_discontinuity or e['discontinuity'])
                        pending_discontinuity, last_seq, last_progress = False, e['seq'], time.monotonic()
                    if self.stop.is_set():
                        break
                    cached = {k:v for k,v in cached.items() if last_seq is None or k > last_seq}
                    if time.monotonic()-last_progress > 30:
                        raise NativeError('source-media-stalled')
                    failures, self.last_transport_error = 0, ''
                except (HTTPError, URLError, TimeoutError, ConnectionError, IncompleteRead) as error:
                    if isinstance(error, HTTPError):
                        if error.code in (401, 403, 404):
                            url = None
                        elif error.code not in (408, 429) and not 500 <= error.code < 600:
                            raise
                    code = transport_error_code(error)
                    self.transport_retries += 1
                    self.last_transport_error = code
                    print('[cctv-native] retry='+str(self.transport_retries)+' operation='+self.operation+' cause='+code, flush=True)
                    failures += 1
                    # A failed Future must be evicted or every subsequent
                    # poll would replay the same exception without a GET.
                    cached = {key: value for key, value in cached.items()
                              if not value.cancelled() and (not value.done() or value.exception() is None)}
                    if time.monotonic()-last_progress > 30:
                        raise NativeError('source-media-stalled') from None
                    delay = min(4, 0.8 * 2**min(failures-1, 3))
                    reason = getattr(error, 'reason', None)
                    if (self.operation == 'source-api' and failures <= 2
                            and isinstance(reason, ssl.SSLError)
                            and getattr(reason, 'reason', None) == 'UNSAFE_LEGACY_RENEGOTIATION_DISABLED'):
                        # Two short initial retries for this immediate handshake
                        # failure; persistent failure still uses normal backoff
                        # and the same no-progress deadline/certificate policy.
                        delay = 0.15 * failures
                    self.stop.wait(delay)
                    continue
                if time.monotonic()-last_progress > 30:
                    raise NativeError('source-media-stalled')
                self.stop.wait(0.8)
        except Exception as error:
            self.error = str(error) if isinstance(error, NativeError) else (
                'transport-stream-unsupported' if isinstance(error, TSFormatError) else type(error).__name__)
            self.state, self.failed_at = 'error', time.monotonic()
            print('[cctv-native] '+self.error, flush=True)
            print('[cctv-native] diagnostics='+json.dumps(self.snapshot(), ensure_ascii=False), flush=True)
        finally:
            cancel_preparation.set()
            if engine:
                engine.close()
            with self.condition:
                self.engine = None
                self.ring.clear()
                self.size = 0
                self.condition.notify_all()


class Handler(BaseHTTPRequestHandler):
    server_version = 'CCTVNative/0.1-experimental'
    def log_message(self, *_args):
        pass
    def send(self, status, body='', mime='text/plain; charset=utf-8'):
        if isinstance(body, str):
            body = body.encode()
        self.send_response(status)
        self.send_header('Content-Type', mime)
        self.send_header('Content-Length', str(len(body)))
        self.send_header('Cache-Control', 'max-age=5' if status == 200 and mime == 'video/mp2t' else 'no-store')
        if status == 503:
            self.send_header('Retry-After', '3')
        self.end_headers()
        if self.command != 'HEAD':
            try:
                self.wfile.write(body)
            except (OSError, TimeoutError):
                pass
    def do_HEAD(self):
        self.do_GET()
    def do_POST(self):
        self.send(405, 'GET/HEAD only')
    def do_GET(self):
        self.connection.settimeout(65)
        ch = self.server.channel
        path = urlsplit(self.path).path
        if path in ('/', '/all.m3u'):
            host = self.headers.get('Host', '')
            if not re.fullmatch(r'(?:\[[0-9A-Fa-f:.]+\]|[A-Za-z0-9][A-Za-z0-9.-]*)(?::\d{1,5})?', host):
                return self.send(400, 'invalid-host')
            try:
                parsed_host = urlsplit('//'+host)
                if parsed_host.port is not None and not 1 <= parsed_host.port <= 65535:
                    return self.send(400, 'invalid-host')
            except ValueError:
                return self.send(400, 'invalid-host')
            if self.command == 'GET' and self.server.args.warmup:
                ch.demand()
            return self.send(200, '#EXTM3U\n#EXTINF:-1 tvg-id="CCTV2" group-title="央视网页原分片",CCTV-2 财经\n'
                             +f'http://{host}/cctv2.m3u8\n', 'audio/x-mpegurl; charset=utf-8')
        if path == '/status':
            return self.send(200, json.dumps(ch.snapshot(), ensure_ascii=False), 'application/json; charset=utf-8')
        if path == '/cctv2.m3u8':
            if self.command == 'HEAD':
                return self.send(200, mime='application/vnd.apple.mpegurl')
            with ch.condition:
                ch.waiters += 1
            try:
                ch.demand()
                ch.note_client_request('playlist_requested')
                deadline = time.monotonic()+50
                with ch.condition:
                    while time.monotonic() < deadline and not ch.stop.is_set():
                        body = ch.playlist()
                        if body:
                            ch.note_client_request('playlist_available')
                            return self.send(200, body, 'application/vnd.apple.mpegurl')
                        if ch.state == 'error':
                            break
                        ch.demand()
                        ch.condition.wait(0.5)
                return self.send(503, json.dumps(ch.snapshot()), 'application/json; charset=utf-8')
            finally:
                with ch.condition:
                    ch.waiters -= 1
                    ch.last_request = time.monotonic()
                    ch.condition.notify_all()
        match = re.fullmatch(r'/media/([0-9a-f]{32})/(\d+)\.ts', path)
        if match:
            with ch.condition:
                if match[1] != ch.generation or ch.state != 'ready':
                    return self.send(410, 'expired-media')
                item = ch.ring.get(int(match[2]))
                if item is None:
                    return self.send(410, 'expired-media')
            if self.command != 'HEAD':
                ch.demand(start=False)
                ch.note_client_request('first_media_requested')
            return self.send(200, item[0], 'video/mp2t')
        self.send(404, 'not-found')


def main(argv=None):
    global _API_LEGACY_ENABLED
    parser = argparse.ArgumentParser(description='CCTV-2 网页同源原分片订阅（Python + Node，无浏览器/转码）')
    parser.add_argument('port', type=int, nargs='?', default=18768)
    parser.add_argument('--bind', default='127.0.0.1')
    parser.add_argument('--node', default=shutil.which('node') or 'node')
    parser.add_argument('--cache-dir', default=str(Path.home()/'.cache'/'cctv-native'))
    parser.add_argument('--setup', action='store_true', help='安装独立Node依赖并缓存官方运行时后退出')
    parser.add_argument('--no-legacy-source-tls',action='store_true',help='关闭官方取源接口旧服务器握手兼容')
    parser.add_argument('--warmup', action='store_true', help='GET订阅时后台提前取源')
    parser.add_argument('--buffer-mb', type=int, default=64)
    parser.add_argument('--idle-timeout', type=int, default=120)
    args = parser.parse_args(argv)
    _API_LEGACY_ENABLED = not args.no_legacy_source_tls
    if not 1 <= args.port <= 65535 or not 16 <= args.buffer_mb <= 256 or not 30 <= args.idle_timeout <= 3600:
        parser.error('invalid port/buffer/idle timeout')
    if not shutil.which(args.node):
        parser.error('需要 Node.js 20+；不需要 Chromium、Playwright 或 FFmpeg')
    major = subprocess.check_output([args.node, '--version'], text=True).strip().lstrip('v').split('.')[0]
    if int(major) < 20:
        parser.error('需要 Node.js 20+')
    if args.setup:
        setup(args)
        return
    root, modules, runtime = cache_paths(args)
    if not modules.is_dir() or not runtime.is_file():
        parser.error('首次请运行：python cctv-native.py --setup')
    channel = Channel(args)
    server = ThreadingHTTPServer((args.bind, args.port), Handler)
    server.daemon_threads = True
    server.channel, server.args = channel, args
    def stop(_signum, _frame):
        channel.stop.set()
        with channel.condition:
            channel.condition.notify_all()
        threading.Thread(target=server.shutdown, daemon=True).start()
    signal.signal(signal.SIGINT, stop)
    signal.signal(signal.SIGTERM, stop)
    print(f'央视网页原分片实验版：http://127.0.0.1:{args.port}/all.m3u；状态：/status', flush=True)
    try:
        server.serve_forever(poll_interval=0.2)
    finally:
        channel.stop.set()
        server.server_close()
        if channel.engine:
            channel.engine.close()
        if channel.thread:
            channel.thread.join(35)


if __name__ == '__main__':
    main()
