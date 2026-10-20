"""CCTV-2 webpage-source local HLS. Node hosts the unchanged official runtime."""
from __future__ import annotations
import argparse
import base64
from collections import OrderedDict
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
from urllib.request import Request, HTTPRedirectHandler, build_opener
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


def get(url, *, headers=None, limit=8*1024*1024, timeout=12):
    validate_source(url)
    req = Request(url, headers={'User-Agent': UA, 'Referer': REFERER, **(headers or {})})
    with build_opener(SourceRedirect()).open(req, timeout=timeout) as response:
        body = response.read(limit + 1)
        if len(body) > limit:
            raise NativeError('response-too-large')
        validate_source(response.url)
        return body, response.url


def source_url():
    stamp, nonce = int(time.time()*1000), random.randint(100, 1000)
    signature = hashlib.md5(f'cctv2{stamp}{nonce}4f779c20f6974ccba20e28d63529d0ef'.encode()).hexdigest()
    query = urlencode({'channel': 'cctv2', 'vn': '1000', 'pdrm': '1', 'uid': '', 'hbss': stamp})
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

    def operation_phase(self, value):
        with self.condition:
            self.operation = value
            self.operation_started = time.monotonic()
            if value not in self.seen_operations:
                self.seen_operations.add(value)
                print('[cctv-native] phase='+value, flush=True)

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
            self.ring[index] = (body, entry['duration'], discontinuity)
            self.size += len(body)
            while len(self.ring) > 10 or self.size > self.args.buffer_mb*1024*1024:
                _, old = self.ring.popitem(last=False)
                self.size -= len(old[0])
                self.discarded_discontinuities += bool(old[2])
            if len(self.ring) >= 2:
                self.stage('ready')
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
            return {'state': self.state, 'error': self.error, 'source': 'tv.cctv.com/cctv2',
                    'mode': 'official-runtime-original-ts', 'processed_segments': self.processed,
                    'buffer_bytes': self.size, 'buffer_segments': len(self.ring),
                    'source_gaps': self.source_gaps,
                    'transport_retries': self.transport_retries,
                    'last_transport_error': self.last_transport_error,
                    'operation': self.operation,
                    'operation_seconds': round(time.monotonic()-self.operation_started, 3) if self.operation_started else 0,
                    'playlist_entries': self.playlist_entries, 'last_segment_bytes': self.last_segment_bytes,
                    'stage_seconds': dict(self.timings), 'media_ready': self.playlist() is not None}

    def run(self):
        engine = None
        try:
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
            with ThreadPoolExecutor(max_workers=3) as pool:
                while not self.stop.is_set():
                    if not self.waiters and time.monotonic()-self.last_request > self.args.idle_timeout:
                        self.state = 'idle'
                        break
                    if time.monotonic()-last_progress > 30:
                        raise NativeError('source-media-stalled')
                    try:
                        if url is None or time.monotonic()-refreshed > 120:
                            self.operation_phase('source-api')
                            url, refreshed = source_url(), time.monotonic()
                        self.operation_phase('media-playlist')
                        entries, final = media_playlist(url)
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
                        wanted = [e for e in entries if last_seq is None or e['seq'] > last_seq]
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
                            self.last_segment_bytes = len(raw)
                            self.operation_phase('ts-analysis')
                            analysis = inspect_ts(raw)
                            if not boundary_proven_by(lookahead, program_number=analysis.program_number,
                                                      video_pid=analysis.video_pid):
                                raise NativeError('source-boundary-not-proven')
                            analysis = inspect_ts(raw, final_nal_complete=True)
                            self.operation_phase('sdk-transform')
                            processed = engine.transform([analysis.nal_bytes(n) for n in analysis.nals])
                            converted = {n.payload_offset: value for n, value in zip(analysis.nals, processed)}
                            self.operation_phase('ts-repack')
                            output, _ = transform_pes_nals(raw, lambda n, _data: converted[n.payload_offset],
                                                       nal_types=(1, 5, 7), final_nal_complete=True)
                            self.publish(output, e, pending_discontinuity or e['discontinuity'])
                            pending_discontinuity, last_seq, last_progress = False, e['seq'], time.monotonic()
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
                        self.stop.wait(min(4, 0.8 * 2**min(failures-1, 3)))
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
                deadline = time.monotonic()+50
                with ch.condition:
                    while time.monotonic() < deadline and not ch.stop.is_set():
                        body = ch.playlist()
                        if body:
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
            return self.send(200, item[0], 'video/mp2t')
        self.send(404, 'not-found')


def main(argv=None):
    parser = argparse.ArgumentParser(description='CCTV-2 网页同源原分片订阅（Python + Node，无浏览器/转码）')
    parser.add_argument('port', type=int, nargs='?', default=18768)
    parser.add_argument('--bind', default='127.0.0.1')
    parser.add_argument('--node', default=shutil.which('node') or 'node')
    parser.add_argument('--cache-dir', default=str(Path.home()/'.cache'/'cctv-native'))
    parser.add_argument('--setup', action='store_true', help='安装独立Node依赖并缓存官方运行时后退出')
    parser.add_argument('--warmup', action='store_true', help='GET订阅时后台提前取源')
    parser.add_argument('--buffer-mb', type=int, default=64)
    parser.add_argument('--idle-timeout', type=int, default=120)
    args = parser.parse_args(argv)
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
